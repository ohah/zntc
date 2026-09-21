import {
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

import { loadEnv, prepareAppDevSync } from '@zntc/core';

import { applyHtmlEnvTokens } from './html-env.ts';

import {
  type BundleResult,
  injectAppDevBundleCssLinks,
  injectAppDevHmrClient,
  injectAppDevPipelineCssLinks,
  pruneAppDevCssLinks,
  injectAppDevReactRefreshPreamble,
} from './inject.ts';
import { buildReactRefreshPreamble } from './react-refresh-preamble.ts';
import {
  cssModuleGeneratedCssPath,
  cssModuleProxyPath,
  isCssModuleFile,
  transformCssModules,
} from './style/css-modules.ts';
import { type NodeRequire } from './style/loader.ts';
import { collectAppFiles, isSkippedDirName } from './style/loader.ts';
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
  /** React Fast Refresh preamble(`/__zntc_react_refresh__`) 을 HTML 에 주입할지.
   *  react 미설치(=비-React 앱)면 주입 자체를 스킵(404 노이즈 방지). */
  reactRefresh?: boolean | undefined;
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
  postcssOverride?: {
    plugins: unknown[];
    options?: Record<string, unknown>;
    /** issue #3851 — css({root}) override 가 controller path 로 전달될 때 type
     *  보존 (TS 사용자가 명시적으로 root 줄 수 있도록). runtime 은 prepare →
     *  runPostcssIfConfigured 가 동일 field name 으로 read. */
    root?: string;
  } | null;
  /** issue #3857 — css({root}) 단독 명시 시 findPostcssConfig search base.
   *  controller 가 prepareAppCssPipelineRoot 의 cssAutoDiscoverRoot 옵션으로
   *  forward. monorepo edge (app 이 sub-package, postcss.config 가 monorepo root). */
  cssAutoDiscoverRoot?: string | null;
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
  postcssOverride?: {
    plugins: unknown[];
    options?: Record<string, unknown>;
    /** issue #3851 — css({root}) override 의 postcss require base. 미지정 시
     *  root 인자 fallback. AppDevControllerOptions.postcssOverride.root 와 동일
     *  field — controller 가 forward. */
    root?: string;
  } | null;
  /** issue #3857 — css({root}) 단독 명시 (postcss override 없이) 시 root 가
   *  auto-discover path 의 findPostcssConfig 시작 base 로 사용되게 caller 가
   *  전달. monorepo edge: app 이 sub-package, postcss.config 가 monorepo root.
   *  미지정 시 root 인자 사용 — 기존 동작 유지. */
  cssAutoDiscoverRoot?: string | null;
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
/**
 * (#4675) 심볼릭 링크를 푼 절대경로. 풀 수 없으면(아직 없는 파일 등) 원본 그대로.
 * macOS 의 `/var` → `/private/var` 처럼, 같은 위치를 가리키는 두 철자를 맞추는 데 쓴다.
 */
function realPathOr(p: string): string {
  try {
    return realpathSync(p);
  } catch {
    return p;
  }
}

function mirrorFile(srcAbs: string, dstAbs: string): void {
  mkdirSync(dirname(dstAbs), { recursive: true });
  // (#4682) `cpSync` 는 대상을 **교체**한다(inode 가 바뀐다). macOS 의 파일 감시는
  // 경로가 아니라 inode 에 걸리므로, 그러면 우리가 우리 감시를 끊는다 — dev 가 CSS 한 번
  // 저장하고 멎던 원인이다. `copyFileSync` 는 제자리에 덮어써 inode 를 유지한다.
  copyFileSync(srcAbs, dstAbs);
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
/**
 * (#4674) 파이프라인이 **source 로 보지 않는** 디렉토리 — 단일 소스.
 *
 * 복사(`copyAppRootForPostcss`)와 탐색(`collectAppFiles`)이 **같은 목록**을 써야 한다.
 * 예전엔 복사만 `.zntc-dev` 를 제외하고 탐색은 `outdir` 하나만 제외해서, `zntc dev` 를
 * 한 번 돌린 프로젝트에서 `zntc build` 가 죽었다 — 탐색이 `.zntc-dev/x.module.css` 를
 * CSS Module 로 잡는데 복사본엔 그 파일이 없어 ENOENT.
 */
export function postcssExcludedDirs(root: string, outdir: string, extra?: string): string[] {
  const dirs = [
    outdir,
    join(root, 'node_modules'),
    join(root, '.git'),
    join(root, 'dist'),
    join(root, '.zntc-dev'),
  ];
  if (extra) dirs.push(extra);
  return dirs.map((d) => resolve(d));
}

function copyAppRootForPostcss(
  root: string,
  outdir: string,
  phase: string,
  cliNodeModules: string,
): string {
  const tempRoot = mkdtempSync(join(tmpdir(), `zntc-postcss-${phase}-`));
  registerPostcssTempRoot(tempRoot);
  const skip = new Set(postcssExcludedDirs(root, outdir, tempRoot));
  cpSync(root, tempRoot, {
    recursive: true,
    dereference: false,
    filter(source: string): boolean {
      const abs = resolve(source);
      if (abs === resolve(root)) return true;
      // (#4678) 탐색(`walkFiles`)과 **같은 이름 규칙**을 쓴다. 복사만 걸러내고 탐색이
      // 안 걸러내면 탐색만 잡은 파일을 복사본에서 열다 죽는다(#4674 가 그 사고였다).
      if (isSkippedDirName(basename(abs))) return false;
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
    cssAutoDiscoverRoot = null,
  } = options;
  const { fallbackRequire, cliNodeModules } = deps;
  // configPath 자동 발견은 override 없을 때만 필요. override 가 있으면 자동 발견 skip.
  // issue #3857 — cssAutoDiscoverRoot 가 있으면 그것을 findPostcssConfig 시작 base
  // 로 사용 (monorepo edge: app 이 sub-package, postcss.config 가 monorepo root).
  const configPath = postcssOverride ? null : findPostcssConfig(cssAutoDiscoverRoot ?? root);
  // /code-review max #2 — 사용자가 cssAutoDiscoverRoot 명시했는데 그 path 에서
  // postcss.config 발견 못 했을 때 silent skip 회피. issue #3857 의 silent ignore
  // 패턴 재발 차단 — typo (`css({root:'/wrong/path'})`) 진단 가시화.
  if (cssAutoDiscoverRoot && !configPath && !postcssOverride && logLevel !== 'silent') {
    console.error(
      `[postcss] css({root}) 명시 — ${cssAutoDiscoverRoot} 에서 postcss.config.* 발견 못함 — auto-discover skip`,
    );
  }
  // F1 cache: 이전 prep 의 stylePipelineFiles 를 재사용. 호출자가 구조 변화 (.scss/.module.css
  // 추가/삭제) 시 cache=null 로 무효화한다. 재사용이면 full tree walk 를 통째 회피.
  const stylePipelineFiles =
    cache?.stylePipelineFiles ??
    collectAppFiles(root, {
      // (#4674) 복사 제외와 **같은 목록**. 어긋나면 탐색만 잡은 파일을 복사본에서 열다 죽는다.
      skipDirs: postcssExcludedDirs(root, outdir),
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
  // 위해 사용. **postcssRelevant=false (incremental dirty=non-CSS)** 면 PostCSS
  // 호출 skip 후 undefined 반환 — controller 가 이전 prep 의 deps/dirDeps 를
  // carry-over (회귀 가드: /code-review max #1). prep 마다 빈 set 으로 reset
  // 하면 .ts 파일 1개 edit 만 해도 tailwind @source dir-dep 손실.
  let postcssDeps: Set<string> | undefined;
  let postcssDirDeps: Set<string> | undefined;
  if (postcssRelevant) {
    const postcssResult = await runPostcssIfConfigured(
      tempRoot,
      tempRoot,
      null,
      configEnv,
      logLevel,
      fallbackRequire,
      postcssOverride,
      cssAutoDiscoverRoot,
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
  /**
   * issue #3861 follow-up — drain (fs.watch) 의 CSS incremental path 가 PostCSS
   * 재실행 없이 tempRoot 만 raw root 와 동기시키기 위한 minimal sync. prepare 가
   * full pipeline (sync + PostCSS reprocess) 라 단일 CSS modify 시 전체 .css
   * reprocess 회귀. PostCSS 는 afterBundle 의 changedPath 분기가 incremental
   * 처리 — sync 만 충분. dirtyPaths 가 modify 면 cpSync, delete 면 rmSync
   * (sync flow 는 prepare 와 동일 invariant).
   */
  syncDirty(dirtyPaths: readonly string[]): void;
  afterBundle(options?: { changedPath?: string | null }): Promise<{
    deps: Set<string>;
    dirDeps: Set<string>;
    primaryHref: string | null;
    processed: number;
  }>;
  injectBundleCssLinks(bundleResult: BundleResult): void;
  /**
   * (#4675) 모듈 그래프에 들어온 CSS 소스(절대경로)에 `<link>` 를 건다.
   *
   * dev 에서 SCSS / CSS Modules 는 파이프라인이 생성 CSS 를 링크하지만 plain `.css` 는
   * 아무도 링크하지 않아 페이지에 도달하지 못했다. "디렉토리에서 발견한 CSS 를 전부
   * 링크" 하면 import 하지도 않은 파일까지 적용되므로, **번들러가 실제로 따라간 목록**
   * 을 받아 그것만 건다. 이미 주입된 href 는 주입기가 건너뛴다.
   */
  injectGraphCssLinks(absPaths: readonly string[]): void;
  /**
   * (#4671) 이번 주기에 주입한 CSS 링크 집합에 맞춰 HTML 의 **남은 링크를 지운다**.
   * 주입기는 추가만 하므로, JS 에서 `import './a.css'` 를 지워도 링크가 남아 스타일이
   * 계속 적용됐다. 주입이 끝난 뒤 호출한다.
   */
  reconcileCssLinks(): void;
  /** (#4671) 그래프 기준 CSS 링크 집합을 비운다 — CSS import 가 하나도 없을 때. */
  clearGraphCssLinks(): void;
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
  /** 변경된 CSS 에 대응하는 링크 href. 어느 링크인지 단정 못 하면 `null`(=전부 갱신). */
  hrefFor(absPath: string): string | null;
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
  // React Fast Refresh preamble 주입 여부 — reactRefresh on + react 설치(=React 앱)일 때만.
  // buildReactRefreshPreamble 가 react 미설치면 null → 주입 스킵(비-React 앱 404 노이즈 0).
  // 1회 계산(파일 resolve/read)해 afterBundle 마다 재계산 않음. runServe 의 서빙 게이트와
  // 동일 함수·동일 appRoot 라 결정 일관.
  const reactRefreshInject =
    opts.reactRefresh === true && buildReactRefreshPreamble(opts.appRoot ?? root) != null;
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
  /**
   * (#4672) **이 컨트롤러가 실제로 주입한** stylesheet href 집합.
   *
   * `css-update` 는 클라이언트에서 `href` pathname 이 일치하는 `<link>` 만 교체하고, 하나도
   * 못 맞추면 페이지를 통째로 reload 한다. 번들 CSS(`/main.css`)가 링크인데 변경 통지는
   * 소스 미러 경로(`/styles.css`)를 가리켜 매번 전체 리로드가 됐다. 무엇을 주입했는지
   * 기억해 두고, 변경된 소스가 그중 하나면 그 href 를, 아니면 `null`(=전부 갱신)을 준다.
   */
  const injectedCssHrefs = new Set<string>();
  /**
   * (#4671) 주입 출처별 **이번 주기의** href 집합.
   *
   * `injectedCssHrefs` 는 누적만 해서 CSS import 를 지워도 그대로 남았다. 출처마다 매번
   * 새로 채우고, `reconcileCssLinks` 가 그 합집합에 없는 링크를 HTML 에서 지운다.
   */
  let pipelineCssHrefs = new Set<string>();
  let graphCssHrefs = new Set<string>();
  let bundleCssHrefs = new Set<string>();
  let pipelineRoot: string | null = null;
  // F1+F2 cache (incremental prep 에서 재사용). 구조 변화 (스타일 파일 추가/삭제) 시
  // 무효화 — `prepareAppCssPipelineRoot` 가 cache miss 일 때 자체적으로 재수집한다.
  let pipelineCache: PipelineCache | null = null;
  // dev pipeline 이 SCSS / CSS Modules 결과 CSS 를 mirror + link inject 했는지 flag.
  // true 면 같은 SCSS source 가 bundler 의 CSS asset (`main.css`) 에도 합본돼 있어
  // 둘 다 link 하면 cascade 충돌 — sass incremental 은 pipeline 만 갱신하니 stale
  // main.css 가 이김. pipeline active 일 땐 bundle CSS link 는 skip한다.
  let hasPipelineCss = false;
  /**
   * (#4675) 모듈 그래프 기준 CSS 링크를 실제로 건 적이 있는가.
   *
   * 그 목록은 entry 가 import 한 **모든** CSS(plain / SCSS 산출 / CSS Modules 산출)를
   * 덮으므로, 번들 CSS(`main.css`)는 같은 내용의 합본이라 링크할 필요가 없다. 둘 다 걸면
   * 같은 규칙이 두 번 실리고, 생산자가 둘이 되어 한쪽만 갱신되는 순간이 생긴다.
   */
  let hasGraphCss = false;
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
      // issue #3857 — controller 가 cssAutoDiscoverRoot 도 prepare 로 forward.
      const cssAutoDiscoverRoot = opts.cssAutoDiscoverRoot ?? null;
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
              cssAutoDiscoverRoot,
            }
          : { sassReverseDep, postcssOverride, cssAutoDiscoverRoot },
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
      // **carry-over (review #1)**: pipeline.postcssDeps 가 undefined 면
      // PostCSS 호출 skip (incremental + non-CSS dirty) — 이전 prep 의 dirDeps
      // 보존. defined 면 새 값으로 overwrite.
      if (pipeline?.postcssDeps !== undefined) {
        preparePostcssDeps = pipeline.postcssDeps;
      }
      if (pipeline?.postcssDirDeps !== undefined) {
        preparePostcssDirDeps = pipeline.postcssDirDeps;
      }
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
      // React Fast Refresh preamble — 앱 번들보다 먼저 실행되도록 첫 <script> 앞에 주입.
      // prepareAppDevSync 가 HTML 을 매 cycle 덮어쓰므로 HMR client 와 똑같이 매번 재주입.
      if (reactRefreshInject) injectAppDevReactRefreshPreamble(outdir);
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
        // (#4672) 파이프라인이 넣은 링크도 기억한다 — 이걸 빠뜨리면 CSS Modules / SCSS
        // 수정 시 `hrefFor` 가 소스 경로(`/s.module.css`)를 돌려주는데 링크는 생성 CSS
        // (`/s.module.zntc.css`)라 매칭에 실패해 전체 리로드가 된다.
        pipelineCssHrefs = new Set(rels.map((rel) => joinUrl(base, rel.replaceAll(sep, '/'))));
        for (const h of pipelineCssHrefs) injectedCssHrefs.add(h);
      }
      return prepared;
    },
    syncDirty(dirtyPaths) {
      // issue #3861 follow-up — drain CSS incremental 의 PostCSS 재실행 회피.
      // prepare 의 syncDirtyFilesIntoTempRoot 와 동일 logic, PostCSS skip.
      // pipelineRoot 가 null (prepare 미경유) 시 noop — 그 경우 drain 의
      // rebuildAppDevCss 가 afterBundle 의 mirror 만 호출하면 충분.
      if (!pipelineRoot) return;
      syncDirtyFilesIntoTempRoot(root, pipelineRoot, dirtyPaths);
    },
    async afterBundle({ changedPath = null } = {}) {
      // RFC #3833 v3 D1a'' Phase 2: prepare 와 동일 override 를 afterBundle 에도
      // 전달. issue #3847: prepare 가 PostCSS 처리한 경우 skipPostcssRun=true 로
      // redundant pass 차단 (zero-config double-pass + caller-pre-warm 모두).
      // issue #3861 follow-up — changedPath 명시 시 single-file PostCSS dispatch.
      // skipPostcssRun=true 라도 changedPath 의 단일 .css 만 reprocess —
      // dev-hmr/postcss test 의 "processed 1 CSS file" incremental 만족 + 신규
      // .css 의 PostCSS 적용 보장. changedPath 없을 때만 skipPostcssRun 적용
      // (initial / bundler emit / full mirror cycle).
      const skipPostcssRun = preparePostcssApplied && !changedPath;
      const result = await runPostcssForAppDev({
        root,
        outdir,
        configEnv,
        logLevel: opts.logLevel,
        base,
        changedPath,
        fallbackRequire,
        postcssOverride: opts.postcssOverride ?? null,
        skipPostcssRun,
        // issue #3847 — mirror 의 source 가 prepare 의 tempRoot (PostCSS 처리됨)
        sourceRoot: pipelineRoot ?? root,
        // issue #3857 — auto-discover path 의 search base forward
        cssAutoDiscoverRoot: opts.cssAutoDiscoverRoot ?? null,
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
    clearGraphCssLinks() {
      // (#4671) 마지막 CSS import 를 지우면 그래프 목록이 빈다. 직전 주기의 집합을
      // 그대로 두면 `reconcileCssLinks` 가 옛 링크를 살려 둔다.
      graphCssHrefs = new Set();
    },
    reconcileCssLinks() {
      // (#4671) 이번 주기에 **실제로 주입한** href 만 남긴다. 사용자가 손으로 적은
      // 링크는 마커가 없어 대상이 아니다.
      const keep = new Set<string>([...pipelineCssHrefs, ...graphCssHrefs, ...bundleCssHrefs]);
      pruneAppDevCssLinks(outdir, keep);
      // `hrefFor` 가 지워진 링크를 지목하지 않도록 누적본도 맞춘다.
      for (const h of [...injectedCssHrefs]) {
        if (!keep.has(h)) injectedCssHrefs.delete(h);
      }
    },
    injectGraphCssLinks(absPaths) {
      if (absPaths.length === 0) return;
      // 경로는 번들러가 읽은 트리(= 파이프라인 temp root, 없으면 앱 루트) 기준이다.
      // dev 서버는 outdir 의 미러본을 서빙하므로 같은 rel path 가 그대로 href 가 된다.
      //
      // ⚠️ 심볼릭 링크를 풀어서 비교해야 한다. macOS 의 임시 디렉토리는 `/var/…` 인데
      // 번들러가 돌려주는 경로는 `/private/var/…` 라, 철자 그대로 빼면 `..` 로 시작하는
      // 상대경로가 나와 **전부 걸러진다**(실측에서 plain CSS 가 하나도 안 걸렸다).
      const graphRoot = realPathOr(pipelineRoot ?? root);
      const rels: string[] = [];
      for (const abs of absPaths) {
        const rel = relative(graphRoot, realPathOr(abs));
        // 트리 밖(node_modules 등)은 outdir 에 미러본이 없다 — 링크해도 404.
        if (!rel || rel.startsWith('..')) continue;
        rels.push(rel);
      }
      if (rels.length === 0) return;
      injectAppDevPipelineCssLinks(outdir, base, rels);
      graphCssHrefs = new Set(rels.map((rel) => joinUrl(base, rel.replaceAll(sep, '/'))));
      for (const h of graphCssHrefs) injectedCssHrefs.add(h);
      hasGraphCss = true;
    },
    injectBundleCssLinks(bundleResult: BundleResult) {
      // pipeline 이 SCSS / CSS Modules 의 생성 CSS 를 링크한 상태면, bundler 의 CSS
      // asset(`main.css`)은 같은 source 의 합본이라 중복이다. 생산자가 둘이 되면 한쪽만
      // 갱신되는 순간이 생기므로 하나만 링크한다.
      //
      // (#4675) 예전에는 여기서 plain `.css` 가 유실됐다 — 번들 CSS 를 통째로 건너뛰는데
      // 그 안에만 plain CSS 가 있었다. 지금은 `injectGraphCssLinks` 가 import 된 CSS 를
      // 전부 개별 링크하므로 그 구멍이 없다.
      if (hasPipelineCss) return;
      // (#4675) 그래프 기준 링크가 이미 import 된 CSS 를 전부 덮는다 — 번들 CSS 는 같은
      // 내용의 합본이라 중복이다.
      if (hasGraphCss) return;
      injectAppDevBundleCssLinks(outdir, base, bundleResult);
      bundleCssHrefs = new Set();
      for (const file of bundleResult?.outputFiles ?? []) {
        if (file?.path && /\.css$/i.test(file.path)) {
          const href = joinUrl(base, basename(file.path));
          bundleCssHrefs.add(href);
          injectedCssHrefs.add(href);
        }
      }
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
      if (absPath.endsWith('.css')) {
        const srcHref = joinUrl(base, relative(root, absPath).replaceAll(sep, '/'));
        // 소스 자체가 링크된 경우(파이프라인이 미러 CSS 를 그대로 링크) — 정확히 지목.
        if (injectedCssHrefs.has(srcHref)) return srcHref;
        // 번들 CSS 로 합쳐진 경우 — 어느 링크인지 단정할 수 없다. `null` 을 주면
        // 클라이언트가 **모든 stylesheet 를 갱신**한다(전체 리로드보다 훨씬 싸다).
        if (injectedCssHrefs.size > 0) return null;
        return srcHref;
      }
      return primaryHref ?? joinUrl(base, 'style.css');
    },
  };
}
