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
import { fileURLToPath } from 'node:url';

import { loadEnv, prepareAppDevSync } from '@zntc/core';

import { applyHtmlEnvTokens } from './html-env.ts';

import {
  type BundleResult,
  injectAppDevBundleCssLinks,
  injectAppDevBundleCssLinksFromOutdir,
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
  /** caller-side pre-warm PostCSS override (RFC #3833 v3 D1a'' Phase 2). 사용자
   *  explicit `plugins: [css({postcss:{...override}})]` 의 옵션을 runAppDev 가
   *  추출해 controller 에 전달. prepare 의 `postcssOverride` + afterBundle 의
   *  `runPostcssForAppDev` override 둘 다에 동일 값. build path 와 dev path 의
   *  PostCSS plugin set 일치 (dev/build divergence 해소). */
  postcssOverride?: { plugins: unknown[]; options?: Record<string, unknown> } | null;
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
  /** sass @import reverse-dep 맵(tempRoot 기준 path): dep → 그 dep 을 import 한 파일들. dev 세션이
   *  소유하고 prep 마다 갱신/조회한다. dirty 한 sass 가 다른 root scss 의 dep 이면 그 root 도 재컴파일
   *  대상에 transitive 추가 — partial(`_x.scss`) 변경 시 stale CSS 방지 (#71). */
  sassReverseDep?: Map<string, Set<string>> | null;
  /** caller-side pre-warm 으로 전달되는 PostCSS override (RFC #3833 v3 D1a''). 사용자
   *  explicit `plugins: [css({ postcss: {...override} })]` 의 옵션을 runAppBuild 가
   *  추출해 prepareAppCssPipelineRoot 로 전달. truthy + plugins.length>0 면 자동 발견
   *  skip 후 override 직접 사용. sync dispatcher × async onLoad 충돌 회피용 path. */
  postcssOverride?: { plugins: unknown[]; options?: Record<string, unknown> } | null;
}

export interface AppCssPipelineResult {
  tempRoot: string;
  generatedCssAbsPaths: string[];
  cache: PipelineCache;
  /** issue #3850 — PostCSS message 의 deps/dirDeps 보존. afterBundle skipPostcssRun
   *  path 가 watch trigger 정합 위해 사용 (tailwind `@source` 같은 dir-dep). */
  postcssDeps?: Set<string>;
  postcssDirDeps?: Set<string>;
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
/** #71: sass `loadedUrls`(전이 @import, 자기 자신 포함)로 reverse-dep 맵(dep → 그것을 import 한
 *  파일들)을 갱신. self/비-file URL 제외. dep 맵은 누적 — 삭제된 import 의 stale entry 는 과잉
 *  재컴파일(느릴 뿐 correctness 안전)이라 정리하지 않는다. */
export function recordSassReverseDep(
  reverseDep: Map<string, Set<string>>,
  file: string,
  loadedUrls: readonly URL[],
): void {
  for (const url of loadedUrls) {
    let dep: string;
    try {
      dep = fileURLToPath(url);
    } catch {
      continue;
    }
    if (dep === file) continue;
    let set = reverseDep.get(dep);
    if (!set) {
      set = new Set();
      reverseDep.set(dep, set);
    }
    set.add(file);
  }
}

export async function prepareAppCssPipelineRoot(
  root: string,
  outdir: string,
  configEnv: ConfigEnv,
  logLevel: string | undefined,
  phase: string,
  deps: AppDevControllerDeps,
  options: PrepareAppCssPipelineRootOptions = {},
): Promise<AppCssPipelineResult | null> {
  const {
    existingTempRoot = null,
    dirtyPaths = null,
    cache = null,
    sassReverseDep = null,
    postcssOverride = null,
  } = options;
  const { fallbackRequire, cliNodeModules } = deps;
  // configPath 자동 발견은 override 없을 때만 필요. override 가 있으면 자동 발견 skip.
  const configPath = postcssOverride ? null : findPostcssConfig(root);
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

  // configPath 자동 발견 결과 + needsSource(sass/css-modules) + override 셋 중 하나라도
  // 있어야 prepare 진행. override 가 있으면 configPath 가 null 이어도 prepare 필요.
  if (!configPath && !needsSource && !postcssOverride) return null;
  // Incremental: existing tempRoot 가 있으면 dirty 파일만 sync (BACKLOG #70). 초기 빌드는
  // 전체 cpSync. dirtyPaths 가 null 이면 안전쪽 fallback 으로 간주해 full sync.
  const tempRoot = existingTempRoot ?? copyAppRootForPostcss(root, outdir, phase, cliNodeModules);
  const isIncremental = existingTempRoot && dirtyPaths;
  if (isIncremental && dirtyPaths) {
    syncDirtyFilesIntoTempRoot(root, tempRoot, dirtyPaths);
  }

  const toTemp = (path: string): string => join(tempRoot, relative(root, path));
  // #71: sass 컴파일이 보고한 전이 @import(loadedUrls)로 reverse-dep 맵을 갱신. null 이면 no-op.
  const recordSassDeps = (file: string, loadedUrls: readonly URL[]): void => {
    if (sassReverseDep) recordSassReverseDep(sassReverseDep, file, loadedUrls);
  };
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
    // #71: dirty sass 를 @import 한 root scss 도 재컴파일 대상에 transitive 추가(reverse-dep).
    // partial(`_vars.scss`)만 dirty 여도 그것을 쓰는 `style.scss` 가 stale 로 남지 않도록.
    if (sassReverseDep) {
      const queue = [...dirtySassSet];
      while (queue.length > 0) {
        const dep = queue.pop() as string;
        const dependents = sassReverseDep.get(dep);
        if (!dependents) continue;
        for (const dependent of dependents) {
          if (!dirtySassSet.has(dependent)) {
            dirtySassSet.add(dependent);
            queue.push(dependent);
          }
        }
      }
    }
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
    isIncremental
      ? { dirtyOnly: dirtySassSet, dirtySources: dirtySourceList, onDeps: recordSassDeps }
      : { onDeps: recordSassDeps },
  );
  // Incremental 모드에서 dirty 가 모두 non-CSS 면 postcss prep 도 skip — 이미 이전 prep
  // 결과가 tempRoot 에 살아 있다. CSS / SCSS / postcss config 가 dirty 일 때만 재실행.
  const postcssRelevant =
    !isIncremental ||
    (dirtyPaths !== null &&
      dirtyPaths.some((p) => isCssFile(p) || isCssPreprocessorFile(p) || isPostcssConfigFile(p)));
  // issue #3850 — runPostcssIfConfigured 의 deps/dirDeps 결과 보존. afterBundle
  // 의 skipPostcssRun path 가 tailwind @source 같은 dir-dep watch trigger 정합
  // 위해 사용. postcssRelevant 가 false 면 빈 set (이전 prep 결과 재사용 가정).
  let postcssDeps = new Set<string>();
  let postcssDirDeps = new Set<string>();
  if (postcssRelevant) {
    const postcssResult = await runPostcssIfConfigured(
      tempRoot,
      tempRoot,
      null,
      configEnv,
      logLevel,
      fallbackRequire,
      postcssOverride,
    );
    postcssDeps = postcssResult.deps;
    postcssDirDeps = postcssResult.dirDeps;
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
    postcssDeps,
    postcssDirDeps,
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
  /**
   * #3813 — outdir 의 `.css` 파일을 file system 스캔해 HTML `<link>` 주입.
   * `injectBundleCssLinks` 가 bundleResult 를 받는 것과 달리 native watch onRebuild 의
   * graphChanged 분기처럼 bundleResult 가 없는 경로용. JS 변경이 새 CSS import 추가했을 때
   * stale `<link>` 회귀 가드.
   */
  injectBundleCssLinksFromOutdir(): void;
  isPostcssConfig(absPath: string): boolean;
  isCssOnlyChange(absPath: string): boolean;
  isSassOnlyChange(absPath: string): boolean;
  /**
   * #3801 — drain else 분기의 CSS-derived 판정 단일 소스. inline literal endsWith 가
   * `.less` 같은 미지원 확장자나 `.styl/.pcss` 누락으로 drift 하던 회귀 방지. CSS / Sass /
   * postcss config / CSS Module / Sass Module 등 native watch graph 밖이라 incremental
   * update 가 트리거되지 않는 변경을 cover.
   */
  isCssLikeChange(absPath: string): boolean;
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
  // issue #3847 — prepare 가 PostCSS 처리 (auto-discover 또는 override) 한 경우
  // true. afterBundle 가 그 flag 보고 runPostcssForAppDev 의 redundant PostCSS
  // pass 차단 (zero-config double-pass 해소). prepare 의 pipeline 결과로 결정.
  let preparePostcssApplied = false;
  // issue #3850 — prepare 의 postcssDeps/postcssDirDeps 보존. afterBundle 가
  // skipPostcssRun path 에서 머지 (tailwind @source 같은 dir-dep watch trigger).
  let preparePostcssDeps = new Set<string>();
  let preparePostcssDirDeps = new Set<string>();
  // #71: sass @import reverse-dep 맵(tempRoot 기준 path). prepare(full pipeline) 와 fast-path
  // (rebuildScssIncremental) 가 갱신하고, isSassOnlyChange 가 조회해 dep 있는 파일은 fast-path
  // 박탈 → full pipeline 의 transitive 재컴파일로 dependents 까지 갱신. 세션 내내 누적.
  const sassReverseDep = new Map<string, Set<string>>();
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
        // #71: 새 tempRoot 가 mkdtemp 되므로 이전 tempRoot 기준의 reverse-dep 키는 모두 dead.
        // 정리하지 않으면 prepare(null) 가 반복될 때 누적된다(현재 watch 는 단일 tempRoot 라 무해하나
        // 방어적으로 clear — code-review max).
        sassReverseDep.clear();
      }
      // 구조 변화 — 새 .scss/.module.css 가 추가됐거나 삭제됐을 가능성. cache 무효화.
      if (
        reuseRoot &&
        dirtyPaths &&
        dirtyPaths.some((p) => isCssPreprocessorFile(p) || isCssModuleFile(p))
      ) {
        pipelineCache = null;
      }
      // RFC #3833 v3 D1a'' Phase 2: build path (runAppBuild) 와 동일하게 caller
      // (runAppDev) 의 explicit `css({postcss:{...override}})` 를 prepare 의
      // PostCSS 단계에 전달. dev/build divergence 해소.
      const postcssOverride = opts.postcssOverride ?? null;
      const pipeline = await prepareAppCssPipelineRoot(
        root,
        outdir,
        configEnv,
        opts.logLevel,
        'dev',
        deps,
        reuseRoot
          ? {
              existingTempRoot: pipelineRoot,
              dirtyPaths,
              cache: pipelineCache,
              sassReverseDep,
              postcssOverride,
            }
          : { sassReverseDep, postcssOverride },
      );
      pipelineRoot = pipeline?.tempRoot ?? null;
      pipelineCache = pipeline?.cache ?? null;
      hasPipelineCss = (pipeline?.generatedCssAbsPaths.length ?? 0) > 0;
      // issue #3847 — pipeline truthy = prepareAppCssPipelineRoot 진입 →
      // runPostcssIfConfigured 호출됨 (override 또는 자동발견 어느 path 든 PostCSS
      // 처리 가능). afterBundle 가 redundant pass 차단할 수 있도록 flag set.
      preparePostcssApplied = !!pipeline;
      // issue #3850 — prepare result 의 postcssDeps/postcssDirDeps 보존.
      // afterBundle skipPostcssRun path 가 watch trigger 정합 위해 사용.
      preparePostcssDeps = pipeline?.postcssDeps ?? new Set();
      preparePostcssDirDeps = pipeline?.postcssDirDeps ?? new Set();
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
      // RFC #3833 v3 D1a'' Phase 2: prepare 와 동일 override 를 afterBundle 에도
      // 전달. issue #3847: prepare 가 PostCSS 처리한 경우 skipPostcssRun=true 로
      // redundant pass 차단 (zero-config double-pass + caller-pre-warm 모두).
      const result = await runPostcssForAppDev({
        root,
        outdir,
        configEnv,
        logLevel: opts.logLevel,
        base,
        changedPath,
        fallbackRequire,
        postcssOverride: opts.postcssOverride ?? null,
        skipPostcssRun: preparePostcssApplied,
        // issue #3847 — mirror 의 source 가 prepare 의 tempRoot (PostCSS 처리됨)
        sourceRoot: pipelineRoot ?? root,
      });
      cssDeps = result.deps;
      cssDirDeps = result.dirDeps;
      // issue #3850 — skipPostcssRun path 의 result.dirDeps 가 빈 set 라
      // tailwind @source 같은 dir-dep watch trigger 누락. prepare 의 결과를
      // 머지 (preparePostcssDeps/Dirs) — controller 의 cssDeps/cssDirDeps 가
      // 양쪽 source 의 union 으로 watch 정합.
      if (preparePostcssApplied) {
        for (const d of preparePostcssDeps) cssDeps.add(d);
        for (const d of preparePostcssDirDeps) cssDirDeps.add(d);
      }
      primaryHref = result.primaryHref;
      return { ...result, deps: cssDeps, dirDeps: cssDirDeps };
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
    injectBundleCssLinksFromOutdir() {
      // #3813 — native watch onRebuild 의 graphChanged 분기처럼 bundleResult 가 없는 경로용.
      // pipeline CSS 우선 정책은 동일 — pipeline 이 inject 했으면 outdir scan skip.
      if (hasPipelineCss) return;
      injectAppDevBundleCssLinksFromOutdir(outdir, base);
    },
    isPostcssConfig(absPath) {
      return isPostcssConfigFile(absPath);
    },
    isCssLikeChange(absPath) {
      // #3801 — 단일 진실 소스. isCssFile (.css 만) / isCssPreprocessorFile (.scss/.sass)
      // / isCssModuleFile (*.module.css) / isCssModulePreprocessorFile (*.module.scss/.sass)
      // / postcss config 모두 cover. .less / .styl / .pcss 같이 코드베이스 미지원 확장자는
      // 명시적으로 false — 사용자가 third-party plugin 으로 처리해도 native watch 의 graph
      // 안에 있으면 자동 trigger 됨, graph 밖이면 별도 issue.
      if (isPostcssConfigFile(absPath)) return true;
      if (isCssFile(absPath) || isCssPreprocessorFile(absPath)) return true;
      if (isCssModuleFile(absPath) || isCssModulePreprocessorFile(absPath)) return true;
      return false;
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
      // Sass fast-path 자격 — non-module `.scss/.sass` 단일 변경.
      if (!isCssPreprocessorFile(absPath) || isCssModulePreprocessorFile(absPath)) return false;
      // #71: 다른 root scss 가 @import 하는 파일(reverse-dep 보유)은 fast-path 박탈 — 단일 파일만
      // 재컴파일하면 그것을 쓰는 root scss 가 stale 로 남는다. full pipeline 의 transitive 재컴파일로
      // dependents 까지 갱신하도록 false 반환. (reverseDep 은 tempRoot 기준이라 toTemp 로 조회.)
      if (pipelineRoot) {
        const temp = join(pipelineRoot, relative(root, absPath));
        if (sassReverseDep.has(temp)) return false;
      }
      return true;
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
      // #71: 이 파일이 새로 @import 하게 된 partial 을 reverse-dep 에 반영 — 다음 그 partial 변경
      // 시 fast-path 박탈되어 이 root 가 재컴파일된다.
      if (result.loadedUrls) recordSassReverseDep(sassReverseDep, srcTemp, result.loadedUrls);
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
