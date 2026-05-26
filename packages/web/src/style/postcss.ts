import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';

import { joinUrl } from '../url.ts';
import { collectAppFiles, type NodeRequire, requireFromAppRoot } from './loader.ts';

// 순서는 zntc.mjs L892-902 와 동일 — postcss.config.* 이 .postcssrc.* 보다 우선.
// PR #5e 의 redirect 시점까지 양쪽 sync 유지 (#2539).
export const POSTCSS_CONFIG_NAMES: readonly string[] = [
  'postcss.config.mjs',
  'postcss.config.js',
  'postcss.config.cjs',
  'postcss.config.json',
  '.postcssrc',
  '.postcssrc.json',
  '.postcssrc.js',
  '.postcssrc.cjs',
  '.postcssrc.mjs',
];

export const isCssFile = (path: string): boolean => path.endsWith('.css');

export function isPostcssConfigFile(path: string): boolean {
  return POSTCSS_CONFIG_NAMES.includes(basename(path));
}

/** `root` 디렉토리에 postcss config 가 있으면 절대 path 반환, 없으면 null. */
export function findPostcssConfig(root: string): string | null {
  for (const name of POSTCSS_CONFIG_NAMES) {
    const path = join(root, name);
    if (existsSync(path)) return path;
  }
  return null;
}

export interface PostcssMessage {
  type?: string;
  file?: unknown;
  dir?: unknown;
  directory?: unknown;
}

/** postcss result.messages 에서 dep 트래킹용 file/dir 항목을 set 에 누적. */
export function collectPostcssMessages(
  messages: readonly PostcssMessage[] | null | undefined,
  deps: Set<string>,
  dirDeps: Set<string>,
): void {
  if (!messages) return;
  for (const message of messages) {
    if (message.type === 'dependency' && typeof message.file === 'string') {
      deps.add(resolve(message.file));
    }
    if (message.type === 'dir-dependency') {
      const dir =
        (typeof message.dir === 'string' && message.dir) ||
        (typeof message.directory === 'string' && message.directory);
      if (dir) dirDeps.add(resolve(dir));
    }
    if (message.type === 'context-dependency' && typeof message.file === 'string') {
      deps.add(resolve(message.file));
    }
  }
}

export function logPostcssProcessed(
  logLevel: string | undefined,
  count: number,
  configFile: string | null | undefined,
): void {
  if (logLevel === 'silent') return;
  console.error(
    `[postcss] processed ${count} CSS file(s) using ${basename(configFile ?? 'postcss config')}`,
  );
}

interface LoadedPostcss {
  postcss: (plugins: unknown[]) => {
    process: (input: string, options: unknown) => Promise<PostcssResult>;
  };
  plugins: unknown[];
  options: Record<string, unknown>;
  configFile: string | null;
}

interface PostcssResult {
  css: string;
  map?: { toString(): string };
  messages?: PostcssMessage[];
}

interface PostcssrcConfig {
  plugins?: unknown[];
  options?: Record<string, unknown>;
  file?: string;
}

interface ConfigEnv {
  mode: string;
}

/**
 * postcss + postcss-load-config 를 app-first / fallback-second 로 require 후
 * config 로드. config 없거나 plugin 0 이면 null.
 *
 * `fallbackRequire` 는 caller 의 CLI context — postcss/postcss-load-config 를
 * app 이 갖지 않을 때 fallback (e.g. ZNTC CLI 의 node_modules).
 */
export async function loadPostcssConfig(
  root: string,
  configEnv: ConfigEnv,
  fallbackRequire: NodeRequire,
  /** issue #3857 /code-review max #1 — postcss / postcss-load-config 의
   *  require base. config search 가 monorepo root 인 경우에도 module require
   *  는 app root 가 정상 (pnpm strict / nohoist 환경에서 monorepo root 에
   *  postcss 미설치 가능). 미지정 시 root 인자 사용 — 기존 동작 유지. */
  requireBase?: string,
): Promise<LoadedPostcss | null> {
  const reqBase = requireBase ?? root;
  const postcssrc = requireFromAppRoot(reqBase, fallbackRequire, 'postcss-load-config') as (
    env: { cwd: string; env: string },
    root: string,
  ) => Promise<PostcssrcConfig>;
  const postcssModule = requireFromAppRoot(reqBase, fallbackRequire, 'postcss') as {
    default?: LoadedPostcss['postcss'];
  } & LoadedPostcss['postcss'];
  const postcss = (postcssModule.default ?? postcssModule) as LoadedPostcss['postcss'];
  const config = await postcssrc({ cwd: root, env: configEnv.mode }, root).catch((err) => {
    if ((err as { message?: string })?.message?.includes('No PostCSS Config found')) return null;
    throw err;
  });
  if (!config) return null;
  const plugins = config.plugins ?? [];
  if (plugins.length === 0) return null;
  return {
    postcss,
    plugins,
    options: config.options ?? {},
    configFile: config.file ?? null,
  };
}

/**
 * `cssDir` 의 모든 CSS 파일 (skipDir 제외) 에 postcss 실행 → in-place 덮어쓰기.
 * postcss config 가 없으면 no-op. `runPostcssForAppDev` 와 달리 outdir 분리 안 함.
 *
 * `override` 가 truthy 면 자동 발견 skip — 사용자 explicit `plugins: [css({
 * postcss: {...override} })]` 의 caller-side pre-warm path (RFC #3833 v3 D1a'').
 * Vite parity: `override.plugins` 가 빈 배열이어도 explicit no-op 으로 처리
 * (auto-discover 로 fallback 안 함). `postcss` 자체는 동일 fallback chain 으로
 * require — 미설치 시 logLevel != silent 면 warn 출력 후 skip (override path
 * 가 silently no-op 안 되도록 가시성 확보).
 */
export interface RunPostcssIfConfiguredResult {
  /** issue #3850 — PostCSS message 의 dep tracking. tailwind @source 등의
   *  file dependency. caller (prepareAppCssPipelineRoot) 가 보존 후 dev path
   *  의 skipPostcssRun 가 watch trigger 정합 위해 사용. */
  deps: Set<string>;
  /** issue #3850 — PostCSS message 의 dir-dep tracking. tailwind v4 의
   *  @source "../html" 같은 directory watch. */
  dirDeps: Set<string>;
}

export async function runPostcssIfConfigured(
  root: string,
  cssDir: string,
  skipDir: string | null,
  configEnv: ConfigEnv,
  logLevel: string | undefined,
  fallbackRequire: NodeRequire,
  override?: {
    plugins: unknown[];
    options?: Record<string, unknown>;
    /** issue #3851 — css({root}) 의 root override. postcss module require 의
     *  base. 미지정 시 root 인자 사용. */
    root?: string;
  } | null,
  /** issue #3857 — css({root}) 단독 명시 시 auto-discover path 의 search base.
   *  override 없을 때 loadPostcssConfig(cssAutoDiscoverRoot ?? root) 로 호출 →
   *  postcss.config 가 monorepo root 에 있고 app 이 sub-package 인 시나리오 cover.
   *  미지정 시 root 인자 사용 — 기존 동작 유지. */
  cssAutoDiscoverRoot?: string | null,
): Promise<RunPostcssIfConfiguredResult> {
  const deps = new Set<string>();
  const dirDeps = new Set<string>();
  let loaded: LoadedPostcss | null;
  if (override) {
    // explicit override path. plugins 가 빈 배열이면 PostCSS process 자체 skip
    // (Vite 식 'explicit no-op' — auto-discover 로 fallback 안 함).
    if (override.plugins.length === 0) return { deps, dirDeps };
    // postcss 자체만 require (app-first / fallback-second).
    // issue #3851 — override.root 가 있으면 그것 use, 아니면 root.
    const requireBase = override.root ?? root;
    let postcssModule: { default?: LoadedPostcss['postcss'] } & LoadedPostcss['postcss'];
    try {
      postcssModule = requireFromAppRoot(
        requireBase,
        fallbackRequire,
        'postcss',
      ) as typeof postcssModule;
    } catch {
      // postcss 미설치. 자동 발견 path 는 silent skip 인데 override path 는
      // 사용자 explicit intent 라 silent 가 silent-bug 가능 — warn 후 skip.
      if (logLevel !== 'silent') {
        console.error('[postcss] override path: postcss require 실패 — skip');
      }
      return { deps, dirDeps };
    }
    const postcss = (postcssModule.default ?? postcssModule) as LoadedPostcss['postcss'];
    loaded = {
      postcss,
      plugins: override.plugins,
      options: override.options ?? {},
      configFile: null,
    };
  } else {
    // issue #3857 — auto-discover path 의 search base. cssAutoDiscoverRoot
    // (monorepo root 등) 가 있으면 그것 사용, 없으면 root 인자 (tempRoot).
    // /code-review max #1: require base 는 app root 유지 (pnpm strict 환경에서
    // monorepo root 에 postcss 미설치 가능 — module resolve 는 app root 기준).
    loaded = await loadPostcssConfig(cssAutoDiscoverRoot ?? root, configEnv, fallbackRequire, root);
  }
  if (!loaded) return { deps, dirDeps };
  const cssFiles = collectAppFiles(cssDir, { skipDir, predicate: isCssFile });
  await Promise.all(
    cssFiles.map(async (file) => {
      const input = readFileSync(file, 'utf8');
      const result = await loaded.postcss(loaded.plugins).process(input, {
        ...loaded.options,
        from: file,
        to: file,
      });
      writeFileSync(file, result.css);
      if (result.map) writeFileSync(`${file}.map`, result.map.toString());
      // issue #3850 — PostCSS message 의 deps/dirDeps 수집. tailwind @source
      // 등 dir-dep watch trigger 정합.
      collectPostcssMessages(result.messages, deps, dirDeps);
    }),
  );
  logPostcssProcessed(logLevel, cssFiles.length, loaded.configFile);
  return { deps, dirDeps };
}

export interface AppDevPostcssOptions {
  root: string;
  outdir: string;
  configEnv: ConfigEnv;
  logLevel: string | undefined;
  base: string | undefined;
  changedPath?: string | null;
  fallbackRequire: NodeRequire;
  /** caller-side pre-warm 으로 전달되는 PostCSS override (RFC #3833 v3 D1a''
   *  Phase 2). build path 의 `runPostcssIfConfigured` 와 동일 시맨틱 — truthy
   *  면 자동발견 skip, plugins.length === 0 면 explicit no-op. issue #3851:
   *  root override 도 routing (postcss require base). */
  postcssOverride?: {
    plugins: unknown[];
    options?: Record<string, unknown>;
    root?: string;
  } | null;
  /** dev path zero-config double-pass 회피 (issue #3847). controller 의
   *  prepare 가 PostCSS 처리 (auto-discover 또는 override) 했음을 caller 가
   *  알린 경우 true — runPostcssForAppDev 가 PostCSS 호출 skip + sourceRoot
   *  의 .css 를 outdir 로 mirror (PostCSS 미적용, 이미 처리된 결과 그대로).
   *  cssDeps 는 raw root path 로 유지 (watch trigger 정합). */
  skipPostcssRun?: boolean;
  /** skipPostcssRun=true 시 mirror 의 source root (prepare 의 tempRoot 또는
   *  raw root). 미지정 시 root 사용. controller 가 pipelineRoot 전달. */
  sourceRoot?: string;
  /** issue #3857 — auto-discover path 의 findPostcssConfig/loadPostcssConfig
   *  search base. monorepo edge: app 이 sub-package, postcss.config 가
   *  monorepo root. 미지정 시 root 인자 사용. */
  cssAutoDiscoverRoot?: string | null;
}

export interface AppDevPostcssResult {
  deps: Set<string>;
  dirDeps: Set<string>;
  primaryHref: string | null;
  processed: number;
}

/**
 * Dev 모드 — `root` 의 CSS 파일들을 `outdir` 의 같은 rel path 로 emit (postcss
 * pipeline 적용). config 없으면 첫 CSS 의 primaryHref 만 반환. 단일 변경 (.css)
 * 이면 해당 파일만 reprocess, 그 외엔 전체.
 */
export async function runPostcssForAppDev(
  options: AppDevPostcssOptions,
): Promise<AppDevPostcssResult> {
  const {
    root,
    outdir,
    configEnv,
    logLevel,
    base,
    changedPath = null,
    fallbackRequire,
    postcssOverride = null,
    skipPostcssRun = false,
    sourceRoot,
    cssAutoDiscoverRoot = null,
  } = options;
  // issue #3853 — skipPostcssRun=true 시 sourceRoot 명시 의무화. fallback (raw
  // root) 으로 silent 떨어지면 PostCSS 미적용 .css 가 outdir 로 copy → dev server
  // 응답 stale. early throw 로 미래 caller 의 silent regression 차단.
  if (skipPostcssRun && sourceRoot === undefined) {
    throw new Error(
      'runPostcssForAppDev: skipPostcssRun=true 시 sourceRoot 명시 필수 (issue #3853). ' +
        'prepare 의 tempRoot path 전달하지 않으면 raw root 의 PostCSS 미적용 .css 가 mirror 됨.',
    );
  }
  const mirrorRoot = sourceRoot ?? root;
  const deps = new Set<string>();
  const dirDeps = new Set<string>();
  let primaryHref: string | null = null;
  // issue #3847 — controller 의 prepare 가 이미 PostCSS 처리 (auto-discover
  // 또는 override) 했음을 caller 가 알린 경우 redundant PostCSS pass 차단.
  // 단 file mirror 는 유지 — 기존 runPostcssForAppDev 가 outdir 에 emit 하는
  // 역할 (dev server 가 outdir 에서 서빙). PostCSS 미적용 file copy 만.
  if (skipPostcssRun) {
    // mirror: mirrorRoot (= prepare 의 tempRoot) 의 .css → outdir. PostCSS
    // 미적용 (이미 prepare 가 처리한 결과). raw root 와 path 다른 경우 (caller
    // 가 pipelineRoot 명시) tempRoot 의 처리된 결과를 outdir 로 copy.
    const mirrorCssFiles = collectAppFiles(mirrorRoot, { skipDir: outdir, predicate: isCssFile });
    mkdirSync(outdir, { recursive: true });
    for (const f of mirrorCssFiles) {
      const outputRel = relative(mirrorRoot, f);
      const outputPath = join(outdir, outputRel);
      mkdirSync(dirname(outputPath), { recursive: true });
      const input = readFileSync(f, 'utf8');
      writeFileSync(outputPath, input);
    }
    // cssDeps: raw root 의 .css path — watch trigger 정합 (사용자 file edit 감지).
    const watchCssFiles = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile });
    for (const f of watchCssFiles) deps.add(resolve(f));
    if (watchCssFiles[0]) primaryHref = joinUrl(base, relative(root, watchCssFiles[0]));
    return { deps, dirDeps, primaryHref, processed: 0 };
  }
  // override 가 있으면 자동발견 skip. plugins.length === 0 면 explicit no-op
  // (build path 의 runPostcssIfConfigured 와 동일 시맨틱).
  // issue #3857 — auto-discover path 의 search base. cssAutoDiscoverRoot 가
  // 있으면 그것 사용 (monorepo edge).
  const configPath = postcssOverride ? null : findPostcssConfig(cssAutoDiscoverRoot ?? root);
  if (!configPath && !postcssOverride) {
    // #3858/#3861 — PostCSS config 없을 때도 mirror sourceRoot (또는 root) 의
    // .css 를 outdir 으로 copy. drain 의 rebuildAppDevCss 가 changedPath 명시 +
    // PostCSS no-op 시 outdir 갱신 보장 — 신규 raw .css 가 outdir 에 도달.
    const mirrorBase = sourceRoot ?? root;
    const allCssFiles = collectAppFiles(mirrorBase, { skipDir: outdir, predicate: isCssFile });
    const targets =
      changedPath && changedPath.endsWith('.css')
        ? allCssFiles.filter(
            (p) => p === changedPath || relative(root, p) === relative(root, changedPath),
          )
        : allCssFiles;
    mkdirSync(outdir, { recursive: true });
    for (const file of targets) {
      const outputRel = relative(mirrorBase, file);
      const outputPath = join(outdir, outputRel);
      mkdirSync(dirname(outputPath), { recursive: true });
      writeFileSync(outputPath, readFileSync(file, 'utf8'));
    }
    // cssDeps: raw root 의 .css path — watch trigger 정합 (사용자 file edit 감지).
    const watchCssFiles = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile });
    for (const f of watchCssFiles) deps.add(resolve(f));
    if (watchCssFiles[0]) primaryHref = joinUrl(base, relative(root, watchCssFiles[0]));
    return { deps, dirDeps, primaryHref, processed: 0 };
  }

  let loaded: LoadedPostcss | null;
  if (postcssOverride) {
    if (postcssOverride.plugins.length === 0) {
      // explicit no-op — primaryHref 만 첫 CSS 로 채워 link 유지. 단 watch deps
      // 는 모든 .css 파일 추가 — controller 의 isCssOnlyChange / cssDeps 가 변경
      // 감지에 사용. 빈 deps 반환 시 watch 가 reload trigger 누락 가능 (/code-review
      // max #3).
      const allCssFiles = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile });
      for (const f of allCssFiles) deps.add(resolve(f));
      if (allCssFiles[0]) primaryHref = joinUrl(base, relative(root, allCssFiles[0]));
      return { deps, dirDeps, primaryHref, processed: 0 };
    }
    // issue #3851 — override.root 가 있으면 그것 use, 아니면 root.
    const requireBase = postcssOverride.root ?? root;
    let postcssModule: { default?: LoadedPostcss['postcss'] } & LoadedPostcss['postcss'];
    try {
      postcssModule = requireFromAppRoot(
        requireBase,
        fallbackRequire,
        'postcss',
      ) as typeof postcssModule;
    } catch {
      if (logLevel !== 'silent') {
        console.error('[postcss] override path (dev): postcss require 실패 — skip');
      }
      return { deps, dirDeps, primaryHref, processed: 0 };
    }
    const postcss = (postcssModule.default ?? postcssModule) as LoadedPostcss['postcss'];
    loaded = {
      postcss,
      plugins: postcssOverride.plugins,
      options: postcssOverride.options ?? {},
      configFile: null,
    };
  } else {
    // issue #3857 — auto-discover path 의 search base. require base 는 app root.
    loaded = await loadPostcssConfig(cssAutoDiscoverRoot ?? root, configEnv, fallbackRequire, root);
  }
  if (!loaded) {
    // #3858/#3861 — postcss config 발견됐어도 plugins=[] / no-op 인 경우.
    // mirror sourceRoot 의 changedPath (또는 전체) 를 outdir 으로 copy —
    // drain 의 신규 .css 가 outdir 도달 보장. 위 `!configPath && !postcssOverride`
    // 분기 의 mirror logic 과 동형.
    const mirrorBase = sourceRoot ?? root;
    const allCssFiles = collectAppFiles(mirrorBase, { skipDir: outdir, predicate: isCssFile });
    // changedPath 는 raw root path, p 는 mirrorBase (tempRoot or root) path.
    // 같은 rel path 비교 — mirrorBase 기준 p 의 rel == root 기준 changedPath 의 rel.
    const changedRel =
      changedPath && changedPath.endsWith('.css') ? relative(root, changedPath) : null;
    const targets = changedRel
      ? allCssFiles.filter((p) => relative(mirrorBase, p) === changedRel)
      : allCssFiles;
    mkdirSync(outdir, { recursive: true });
    for (const file of targets) {
      const outputRel = relative(mirrorBase, file);
      const outputPath = join(outdir, outputRel);
      mkdirSync(dirname(outputPath), { recursive: true });
      writeFileSync(outputPath, readFileSync(file, 'utf8'));
    }
    const watchCssFiles = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile });
    for (const f of watchCssFiles) deps.add(resolve(f));
    if (watchCssFiles[0]) primaryHref = joinUrl(base, relative(root, watchCssFiles[0]));
    return { deps, dirDeps, primaryHref, processed: 0 };
  }
  if (loaded.configFile) deps.add(resolve(loaded.configFile));
  else if (configPath) deps.add(resolve(configPath));

  mkdirSync(outdir, { recursive: true });
  const allCssFiles = collectAppFiles(root, { skipDir: outdir, predicate: isCssFile });
  const targets =
    changedPath && changedPath.endsWith('.css') && allCssFiles.includes(changedPath)
      ? [changedPath]
      : allCssFiles;

  await Promise.all(
    targets.map(async (file) => {
      const outputRel = relative(root, file);
      const outputPath = join(outdir, outputRel);
      mkdirSync(dirname(outputPath), { recursive: true });
      const input = readFileSync(file, 'utf8');
      const result = await loaded.postcss(loaded.plugins).process(input, {
        ...loaded.options,
        from: file,
        to: outputPath,
      });
      writeFileSync(outputPath, result.css);
      if (result.map) writeFileSync(`${outputPath}.map`, result.map.toString());
      deps.add(resolve(file));
      collectPostcssMessages(result.messages, deps, dirDeps);
    }),
  );
  if (allCssFiles.length > 0) primaryHref = joinUrl(base, relative(root, allCssFiles[0]!));

  logPostcssProcessed(logLevel, targets.length, loaded.configFile);
  return { deps, dirDeps, primaryHref, processed: targets.length };
}
