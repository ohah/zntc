import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve, sep } from 'node:path';

import { loadEnv, prepareAppDevSync } from '@zntc/core';

import { applyHtmlEnvTokens } from './html-env.ts';

import {
  type BundleResult,
  injectAppDevBundleCssLinks,
  injectAppDevHmrClient,
  injectAppDevPipelineCssLinks,
} from './inject.ts';
import {
  cssModuleGeneratedCssPath,
  cssModuleProxyPath,
  isCssModuleFile,
  transformCssModules,
} from './style/css-modules.ts';
import { type NodeRequire } from './style/loader.ts';
import { collectAppFiles } from './style/loader.ts';
import {
  findPostcssConfig,
  isCssFile,
  isPostcssConfigFile,
  runPostcssForAppDev,
  runPostcssIfConfigured,
} from './style/postcss.ts';
import {
  compileSassFile,
  cssPreprocessorOutputPath,
  cssPreprocessorProxyPath,
  isCssModulePreprocessorFile,
  isCssPreprocessorFile,
  isStyleReferenceSource,
  loadSassCompiler,
  transformCssPreprocessors,
} from './style/sass.ts';
import { joinUrl } from './url.ts';

// app 의 dev mode pipeline temp root 추적 — exit/SIGINT/SIGTERM 으로 cleanup.
const postcssTempRoots = new Set<string>();
let postcssCleanupRegistered = false;

interface ConfigEnv {
  mode: string;
  command?: string;
}

export interface AppDevControllerOptions {
  outdir?: string | undefined;
  base?: string | undefined;
  publicPath?: string | undefined;
  appRoot?: string | undefined;
  entryHtml?: string | undefined;
  publicDir?: string | false | undefined;
  envDir?: string | undefined;
  envPrefixes?: readonly string[] | undefined;
  logLevel?: string | undefined;
}

export interface AppDevControllerDeps {
  /** dev/build 의 NAPI sync wrapper — core 가 이미 세션에서 init 됐다고 가정. */
  fallbackRequire: NodeRequire;
  /** zntc CLI 의 node_modules — app 에 node_modules 가 없으면 symlink 대상. */
  cliNodeModules: string;
}

interface PipelineCache {
  stylePipelineFiles: string[];
  styleSourceFiles: string[];
}

export interface PrepareAppCssPipelineRootOptions {
  /** 이전 prep 의 tempRoot — incremental 재사용. null 이면 새로 mkdtemp. */
  existingTempRoot?: string | null;
  /** dirty 파일 path. existingTempRoot 와 함께 — 그 파일들만 sync. */
  dirtyPaths?: readonly string[] | null;
  /** 이전 prep 의 stylePipelineFiles + styleSourceFiles — 구조 변화 없으면 재사용. */
  cache?: PipelineCache | null;
}

export interface AppCssPipelineResult {
  tempRoot: string;
  generatedCssAbsPaths: string[];
  cache: PipelineCache;
}

function normalizeBase(base: string | undefined): string {
  if (!base) return '/';
  let normalized = base.startsWith('/') ? base : `/${base}`;
  if (!normalized.endsWith('/')) normalized = `${normalized}/`;
  return normalized;
}

/** 단일 파일 mirror — mkdir + cp 한 줄. dirty sync / pipeline outdir / scss fast-path 공용. */
function mirrorFile(srcAbs: string, dstAbs: string): void {
  mkdirSync(dirname(dstAbs), { recursive: true });
  cpSync(srcAbs, dstAbs);
}

/**
 * dev mode 의 sass / css-modules 컴파일 결과는 tempPipelineRoot 에만 있어 dev server
 * 가 서빙 못한다. 같은 rel path 로 outdir 에 복사해 `/<rel>` 로 fetch 가능하게.
 */
function mirrorPipelineCssToOutdir(
  pipelineRoot: string,
  outdir: string,
  absPaths: readonly string[],
): string[] {
  const rels: string[] = [];
  for (const abs of absPaths) {
    const rel = relative(pipelineRoot, abs);
    mirrorFile(abs, join(outdir, rel));
    rels.push(rel);
  }
  return rels;
}

/** Sass / CSS Modules 의 generated peer 산출물 path — 삭제된 source 의 stale orphan 정리용. */
function generatedPeerPaths(srcPath: string): string[] {
  if (isCssPreprocessorFile(srcPath)) {
    return [cssPreprocessorOutputPath(srcPath), cssPreprocessorProxyPath(srcPath)];
  }
  if (isCssModuleFile(srcPath)) {
    return [cssModuleGeneratedCssPath(srcPath), cssModuleProxyPath(srcPath)];
  }
  return [];
}

/**
 * Incremental: dirty 만 root → tempRoot 로 mirror. 비싼 cpSync 는 변경분만.
 * 삭제된 source 는 tempRoot 의 generated peer (sass/.module.css 산출물) 까지 함께 정리.
 */
function syncDirtyFilesIntoTempRoot(
  root: string,
  tempRoot: string,
  dirtyPaths: readonly string[],
): void {
  for (const abs of dirtyPaths) {
    const rel = relative(root, abs);
    if (!rel || rel.startsWith('..')) continue;
    const dst = join(tempRoot, rel);
    if (existsSync(abs)) {
      mirrorFile(abs, dst);
    } else if (existsSync(dst)) {
      rmSync(dst, { force: true });
      for (const peer of generatedPeerPaths(dst)) {
        if (existsSync(peer)) rmSync(peer, { force: true });
      }
    }
  }
}

function registerPostcssTempRoot(tempRoot: string): void {
  postcssTempRoots.add(tempRoot);
  if (postcssCleanupRegistered) return;
  postcssCleanupRegistered = true;
  const cleanupAll = (): void => {
    for (const root of postcssTempRoots) rmSync(root, { recursive: true, force: true });
    postcssTempRoots.clear();
  };
  process.once('exit', cleanupAll);
  process.once('SIGINT', () => {
    cleanupAll();
    process.exit(130);
  });
  process.once('SIGTERM', () => {
    cleanupAll();
    process.exit(143);
  });
}

export function cleanupPostcssTempRoot(tempRoot: string): void {
  postcssTempRoots.delete(tempRoot);
  rmSync(tempRoot, { recursive: true, force: true });
}

/**
 * App root 의 source 트리를 temp dir 로 cp + node_modules 는 symlink. 결과 tempRoot
 * 에서 sass / postcss / css-modules 가 mutable 하게 동작.
 */
function copyAppRootForPostcss(
  root: string,
  outdir: string,
  phase: string,
  cliNodeModules: string,
): string {
  const tempRoot = mkdtempSync(join(tmpdir(), `zntc-postcss-${phase}-`));
  registerPostcssTempRoot(tempRoot);
  const skip = new Set([
    resolve(outdir),
    resolve(tempRoot),
    resolve(join(root, 'node_modules')),
    resolve(join(root, '.git')),
    resolve(join(root, 'dist')),
    resolve(join(root, '.zntc-dev')),
  ]);
  cpSync(root, tempRoot, {
    recursive: true,
    dereference: false,
    filter(source: string): boolean {
      const abs = resolve(source);
      if (abs === resolve(root)) return true;
      for (const ignored of skip) {
        if (abs === ignored || abs.startsWith(`${ignored}${sep}`)) return false;
      }
      return true;
    },
  });
  const appNodeModules = join(root, 'node_modules');
  const nodeModulesTarget = existsSync(appNodeModules) ? appNodeModules : cliNodeModules;
  if (existsSync(nodeModulesTarget)) {
    symlinkSync(nodeModulesTarget, join(tempRoot, 'node_modules'), 'dir');
  }
  return tempRoot;
}

/**
 * postcss config + sass / css-modules 처리를 위한 temp root 준비. 입력 source 는
 * tempRoot 로 cp 되어 mutable, 출력 (`.css` / `.module.zntc.css` / `.css.js` proxy)
 * 도 같은 tempRoot 에 emit. 호출자가 generatedCssAbsPaths 를 받아 outdir mirror.
 *
 * Incremental — existingTempRoot + dirtyPaths 가 있으면 그 파일만 cp / 삭제 처리,
 * cache 가 있으면 stylePipelineFiles / styleSourceFiles tree walk 도 skip.
 */
export async function prepareAppCssPipelineRoot(
  root: string,
  outdir: string,
  configEnv: ConfigEnv,
  logLevel: string | undefined,
  phase: string,
  deps: AppDevControllerDeps,
  options: PrepareAppCssPipelineRootOptions = {},
): Promise<AppCssPipelineResult | null> {
  const { existingTempRoot = null, dirtyPaths = null, cache = null } = options;
  const { fallbackRequire, cliNodeModules } = deps;
  const configPath = findPostcssConfig(root);
  // F1 cache: 이전 prep 의 stylePipelineFiles 를 재사용. 호출자가 구조 변화 (.scss/.module.css
  // 추가/삭제) 시 cache=null 로 무효화한다. 재사용이면 full tree walk 를 통째 회피.
  const stylePipelineFiles =
    cache?.stylePipelineFiles ??
    collectAppFiles(root, {
      skipDir: outdir,
      predicate: (path) => isCssPreprocessorFile(path) || isCssModuleFile(path),
    });
  const preprocessorFiles = stylePipelineFiles.filter(isCssPreprocessorFile);
  const moduleFiles = stylePipelineFiles.filter(isCssModuleFile);
  const needsSource = preprocessorFiles.length > 0 || moduleFiles.length > 0;

  if (!configPath && !needsSource) return null;
  // Incremental: existing tempRoot 가 있으면 dirty 파일만 sync (BACKLOG #70). 초기 빌드는
  // 전체 cpSync. dirtyPaths 가 null 이면 안전쪽 fallback 으로 간주해 full sync.
  const tempRoot = existingTempRoot ?? copyAppRootForPostcss(root, outdir, phase, cliNodeModules);
  const isIncremental = existingTempRoot && dirtyPaths;
  if (isIncremental && dirtyPaths) {
    syncDirtyFilesIntoTempRoot(root, tempRoot, dirtyPaths);
  }

  const toTemp = (path: string): string => join(tempRoot, relative(root, path));
  // F2 cache: styleSourceFiles 도 cache 재사용 — 구조 변화 없으면 .html/.js/.ts 트리 walk 회피.
  // postcss-only 경로 (preprocessor/module 모두 없음) 면 dead 라 빈 배열.
  const styleSourceFiles = !needsSource
    ? []
    : (cache?.styleSourceFiles ?? collectAppFiles(tempRoot, { predicate: isStyleReferenceSource }));

  // Incremental 모드에서 transforms 가 다시 계산할 dirty 입력 set 을 미리 만든다.
  // — sass: dirty `.scss/.sass` 만 컴파일
  // — css-modules: dirty `.module.css` (또는 dirty `.module.scss` 의 sass 산출물) 만 scoping
  // — source rewriter: freshly cp 된 dirty source 만 (나머지는 이전 prep 의 rewrite 가 살아있음)
  // postcss 는 자체 changedPath 옵션이 있어 별도 호출 (afterBundle / runPostcssForAppDev) 가 처리.
  let dirtySassSet: Set<string> | null = null;
  let dirtyModuleSet: Set<string> | null = null;
  let dirtySourceList: string[] | null = null;
  if (isIncremental && dirtyPaths) {
    const dirtyTempPaths = dirtyPaths.map(toTemp);
    dirtySassSet = new Set(dirtyTempPaths.filter((p) => isCssPreprocessorFile(p)));
    dirtyModuleSet = new Set(dirtyTempPaths.filter((p) => isCssModuleFile(p)));
    // dirty `.module.scss` → sass 산출물 `.module.css` 도 css-modules dirty 입력에 포함.
    for (const sassDirty of dirtySassSet) {
      const cssOut = cssPreprocessorOutputPath(sassDirty);
      if (isCssModuleFile(cssOut)) dirtyModuleSet.add(cssOut);
    }
    dirtySourceList = dirtyTempPaths.filter((p) => isStyleReferenceSource(p) && existsSync(p));
  }

  // 파이프라인 순서 (유지 필수):
  //  1. Sass: `*.scss/.sass` → `*.css` (`.module.scss` 면 `.module.css` 가 새로 생김)
  //  2. PostCSS: 모든 `*.css` 에 변환 적용 (Tailwind 등이 `@apply` 같은 룰 주입)
  //  3. CSS Modules: postcss 가 주입한 `.injected` 같은 selector 까지 scoping
  // 순서가 바뀌면 postcss 가 추가한 selector 가 scoped 안 되거나 sass 미컴파일 상태로
  // postcss 가 돌아 깨진다 — 통합 테스트 `Sass output flows through PostCSS before CSS Modules scoping` 참고.
  const sassOutputs = transformCssPreprocessors(
    tempRoot,
    preprocessorFiles.map(toTemp),
    styleSourceFiles,
    logLevel,
    fallbackRequire,
    isIncremental ? { dirtyOnly: dirtySassSet, dirtySources: dirtySourceList } : undefined,
  );
  // Incremental 모드에서 dirty 가 모두 non-CSS 면 postcss prep 도 skip — 이미 이전 prep
  // 결과가 tempRoot 에 살아 있다. CSS / SCSS / postcss config 가 dirty 일 때만 재실행.
  const postcssRelevant =
    !isIncremental ||
    (dirtyPaths !== null &&
      dirtyPaths.some((p) => isCssFile(p) || isCssPreprocessorFile(p) || isPostcssConfigFile(p)));
  if (postcssRelevant) {
    await runPostcssIfConfigured(tempRoot, tempRoot, null, configEnv, logLevel, fallbackRequire);
  }
  // `*.module.scss` 는 위 sass 단계에서 `*.module.css` 가 새로 만들어지므로, 사전 walk
  // 가 본 모듈 리스트엔 빠져 있다. preprocessor 출력 경로를 재계산해 보강.
  const generatedModuleFiles = preprocessorFiles
    .map(cssPreprocessorOutputPath)
    .filter(isCssModuleFile);
  const moduleOutputs = transformCssModules(
    tempRoot,
    [...moduleFiles, ...generatedModuleFiles].map(toTemp),
    styleSourceFiles,
    logLevel,
    isIncremental ? { dirtyOnly: dirtyModuleSet, dirtySources: dirtySourceList } : undefined,
  );
  // dev mode 가 brwoser 까지 CSS 를 도달시키도록 outdir mirror 에 사용. build mode 는
  // bundler 가 entry 의 `import "./generated.css"` 를 따라 CSS chunk 를 emit 하므로
  // 별도로 mirror 할 필요 없음 (소비자가 결정).
  // `.module.scss` 의 sass 산출물 (`*.module.css`) 은 그 자체가 CSS Modules 입력으로
  // 다시 들어가 결국 `*.module.zntc.css` 로 emit 되므로 mirror 대상에서 제외.
  const moduleInputCssPaths = new Set(
    generatedModuleFiles.map((p) => join(tempRoot, relative(root, p))),
  );
  const generatedCssAbsPaths = [
    ...sassOutputs.filter((p) => !moduleInputCssPaths.has(p)),
    ...moduleOutputs,
  ];
  return {
    tempRoot,
    generatedCssAbsPaths,
    cache: { stylePipelineFiles, styleSourceFiles },
  };
}

export interface AppDevPrepareResult {
  entryPath: string;
}

export interface AppDevController {
  readonly root: string;
  readonly outdir: string;
  readonly base: string;
  prepare(dirtyPaths?: readonly string[] | null): Promise<AppDevPrepareResult>;
  afterBundle(options?: { changedPath?: string | null }): Promise<{
    deps: Set<string>;
    dirDeps: Set<string>;
    primaryHref: string | null;
    processed: number;
  }>;
  injectBundleCssLinks(bundleResult: BundleResult): void;
  isPostcssConfig(absPath: string): boolean;
  isCssOnlyChange(absPath: string): boolean;
  isSassOnlyChange(absPath: string): boolean;
  rebuildScssIncremental(absPath: string): Promise<string | null>;
  hrefFor(absPath: string): string;
}

/**
 * dev server 의 lifecycle controller — prepare / afterBundle / HMR-related dispatch.
 * runServe 가 watch debounce 후 controller 의 각 method 를 호출. 본 함수는 closure
 * 로 cssDeps / pipelineRoot / pipelineCache 등 state 를 hold.
 */
export function createAppDevController(
  opts: AppDevControllerOptions,
  root: string,
  configEnv: ConfigEnv,
  deps: AppDevControllerDeps,
): AppDevController {
  const { fallbackRequire } = deps;
  const outdir = resolve(opts.outdir || join(root, '.zntc-dev'));
  const base = normalizeBase(opts.base ?? opts.publicPath ?? '/');
  let cssDeps = new Set<string>();
  let cssDirDeps = new Set<string>();
  let primaryHref: string | null = null;
  let pipelineRoot: string | null = null;
  // F1+F2 cache (incremental prep 에서 재사용). 구조 변화 (스타일 파일 추가/삭제) 시
  // 무효화 — `prepareAppCssPipelineRoot` 가 cache miss 일 때 자체적으로 재수집한다.
  let pipelineCache: PipelineCache | null = null;
  // dev pipeline 이 SCSS / CSS Modules 결과 CSS 를 mirror + link inject 했는지 flag.
  // true 면 같은 SCSS source 가 bundler 의 CSS asset (`main.css`) 에도 합본돼 있어
  // 둘 다 link 하면 cascade 충돌 — sass incremental 은 pipeline 만 갱신하니 stale
  // main.css 가 이김. pipeline active 일 땐 bundle CSS link 는 skip한다.
  let hasPipelineCss = false;
  // HTML env (ZNTC_*) cache + warning dedupe. dev 세션 내 envDir 변경은 restartTriggers
  // 가 process 를 재시작하므로 메모이즈 안전. warning 은 같은 key 로 매 rebuild 마다
  // 출력되면 노이즈 — Set 으로 1회 limit.
  let htmlEnvCache: { mode: string; dir: string; env: Record<string, string> } | null = null;
  const warnedHtmlEnv = new Set<string>();

  return {
    root,
    outdir,
    base,
    async prepare(dirtyPaths = null) {
      const reuseRoot = pipelineRoot && dirtyPaths != null;
      if (pipelineRoot && !reuseRoot) {
        cleanupPostcssTempRoot(pipelineRoot);
        pipelineRoot = null;
        pipelineCache = null;
      }
      // 구조 변화 — 새 .scss/.module.css 가 추가됐거나 삭제됐을 가능성. cache 무효화.
      if (
        reuseRoot &&
        dirtyPaths &&
        dirtyPaths.some((p) => isCssPreprocessorFile(p) || isCssModuleFile(p))
      ) {
        pipelineCache = null;
      }
      const pipeline = await prepareAppCssPipelineRoot(
        root,
        outdir,
        configEnv,
        opts.logLevel,
        'dev',
        deps,
        reuseRoot
          ? { existingTempRoot: pipelineRoot, dirtyPaths, cache: pipelineCache }
          : undefined,
      );
      pipelineRoot = pipeline?.tempRoot ?? null;
      pipelineCache = pipeline?.cache ?? null;
      hasPipelineCss = (pipeline?.generatedCssAbsPaths.length ?? 0) > 0;
      const prepareRoot = pipelineRoot ?? root;
      const envDir = opts.envDir ? resolve(opts.envDir) : prepareRoot;
      const prepared = prepareAppDevSync({
        root: prepareRoot,
        outdir,
        entryHtml: opts.entryHtml ?? 'index.html',
        publicDir: opts.publicDir === undefined ? 'public' : opts.publicDir,
        base,
        mode: configEnv.mode,
        envDir,
        envPrefixes: opts.envPrefixes ? Array.from(opts.envPrefixes) : undefined,
      });
      const htmlEnv =
        htmlEnvCache && htmlEnvCache.mode === configEnv.mode && htmlEnvCache.dir === envDir
          ? htmlEnvCache.env
          : (htmlEnvCache = {
              mode: configEnv.mode,
              dir: envDir,
              env: loadEnv(configEnv.mode, envDir, ['ZNTC_']),
            }).env;
      const { warnings: htmlWarnings } = applyHtmlEnvTokens(outdir, htmlEnv);
      if (opts.logLevel !== 'silent') {
        for (const w of htmlWarnings) {
          if (warnedHtmlEnv.has(w)) continue;
          warnedHtmlEnv.add(w);
          console.error(`[html-env] ${w}`);
        }
      }
      injectAppDevHmrClient(outdir);
      // dev mode 한정 — bundler 가 dev splitting=false 라 CSS chunk 를 emit 하지
      // 않으므로 Sass / CSS Modules 결과를 outdir 로 mirror + `<link>` 주입.
      // mirror (cpSync) 는 sass/module 입력이 dirty 일 때만 — 그 외엔 outdir 의 직전 mirror
      // 본 그대로. inject 는 prepareAppDevSync 가 HTML 을 매번 덮어쓰므로 항상 필요.
      if (pipeline && pipeline.generatedCssAbsPaths.length > 0 && pipelineRoot) {
        const sassOrModuleDirty =
          !reuseRoot ||
          (dirtyPaths !== null &&
            dirtyPaths.some((p) => isCssPreprocessorFile(p) || isCssModuleFile(p)));
        const rels = sassOrModuleDirty
          ? mirrorPipelineCssToOutdir(pipelineRoot, outdir, pipeline.generatedCssAbsPaths)
          : pipeline.generatedCssAbsPaths.map((p) => relative(pipelineRoot ?? root, p));
        injectAppDevPipelineCssLinks(outdir, base, rels);
      }
      return prepared;
    },
    async afterBundle({ changedPath = null } = {}) {
      const result = await runPostcssForAppDev({
        root,
        outdir,
        configEnv,
        logLevel: opts.logLevel,
        base,
        changedPath,
        fallbackRequire,
      });
      cssDeps = result.deps;
      cssDirDeps = result.dirDeps;
      primaryHref = result.primaryHref;
      return result;
    },
    injectBundleCssLinks(bundleResult: BundleResult) {
      // pipeline 이 SCSS / CSS Modules generated CSS 를 inject 한 상태면 bundler 의
      // CSS asset (entry 의 모든 CSS import 가 합본된 main.css) 은 같은 source 의
      // 중복이라 cascade 마지막에서 stale 값으로 이긴다. pipeline 우선.
      // 알려진 제약: 같은 entry 가 SCSS + plain `.css` 를 모두 import 하면 bundle
      // main.css 의 plain CSS 부분이 누락 — pipeline 이 plain `.css` 까지 cover
      // 하도록 확장하거나 metafile inputs 기반 정밀 dedup 으로 follow-up.
      if (hasPipelineCss) return;
      injectAppDevBundleCssLinks(outdir, base, bundleResult);
    },
    isPostcssConfig(absPath) {
      return isPostcssConfigFile(absPath);
    },
    isCssOnlyChange(absPath) {
      // CSS Modules 는 class 이름 매핑이 변할 수 있어 JS proxy 도 같이 재생성 필요 →
      // CSS-only HMR 로 갈음할 수 없고 full reload 가 안전한 기본값. Sass module
      // variant (`*.module.scss/.sass`) 도 같은 이유로 제외.
      if (isCssModuleFile(absPath) || isCssModulePreprocessorFile(absPath)) return false;
      if (isCssFile(absPath) || isCssPreprocessorFile(absPath)) return true;
      if (cssDeps.has(absPath)) return true;
      for (const dir of cssDirDeps) {
        if (absPath === dir || absPath.startsWith(`${dir}${sep}`)) return true;
      }
      return false;
    },
    isSassOnlyChange(absPath) {
      // Sass fast-path 자격 — non-module `.scss/.sass` 단일 변경. import dep 추적 없으므로
      // 이 파일을 import 한 다른 sass 파일은 갱신 누락 가능 (BACKLOG #71 deps tracking).
      return isCssPreprocessorFile(absPath) && !isCssModulePreprocessorFile(absPath);
    },
    async rebuildScssIncremental(absPath) {
      // pipelineRoot 가 없으면 fast-path 진입 못함 (full reload 로 fallback).
      if (!pipelineRoot) return null;
      // postcss config 가 있으면 fast-path 가 부정확한 결과 (Tailwind/autoprefixer 등이
      // skip 됨) — full reload 로 fallback.
      if (findPostcssConfig(root)) return null;
      const srcTemp = join(pipelineRoot, relative(root, absPath));
      mirrorFile(absPath, srcTemp);
      const sass = loadSassCompiler(root, fallbackRequire);
      const result = compileSassFile(sass, srcTemp, pipelineRoot);
      const cssTempPath = cssPreprocessorOutputPath(srcTemp);
      writeFileSync(cssTempPath, result.css);
      // 컴파일된 CSS 도 outdir 에 mirror 해서 dev server 가 서빙 가능하게.
      const cssRel = relative(pipelineRoot, cssTempPath);
      mirrorFile(cssTempPath, join(outdir, cssRel));
      return joinUrl(base, cssRel.replaceAll(sep, '/'));
    },
    hrefFor(absPath) {
      if (absPath.endsWith('.css')) return joinUrl(base, relative(root, absPath));
      return primaryHref ?? joinUrl(base, 'style.css');
    },
  };
}
