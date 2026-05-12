// RN preset — `RnBundleInput` (사용자 입력) → `BuildOptions` (ZNTC NAPI build/watch
// 입력). 번개 napi-build.ts 의 RN 분기 (L74~L268) 와 동등 동작 + 번개 의존성 0.
//
// 자동 활성 필드 (RN platform 시): target=es5, flow=true, jsxInJs=true,
// configurableExports=true, strictExecutionOrder=true, workletTransform=true,
// resolveExtensions (ios/android prefix), mainFields (RN/browser/main),
// banner (RN prelude), define (__DEV__/process.env), polyfills/runBeforeMain/
// globalIdentifiers (resolveRnPolyfills + InitializeCore + RN_GLOBAL_IDENTIFIERS),
// loader (asset 확장자), plugins (asset/codegen/babel/require-context/[metro-resolve-request]).
//
// dev 시 추가: jsx=automatic-dev, devMode=true, reactRefresh=true,
// collectModuleCodes=true, footer (DevLoadingView hide).
//
// caller (번개 / RN 사용자) 가 input 으로 base config 전달 → preset 이 BuildOptions
// 빌드 → 마지막에 input.override 로 사용자 override 가능.

import { resolve } from 'node:path';

import {
  build,
  type BuildOptions,
  type BuildResult,
  init,
  watch,
  type WatchHandle,
  type WatchReadyEvent,
  type WatchRebuildEvent,
  type ZntcPlugin,
} from '@zntc/core';

import type { CustomResolver, MetroPlatform } from './metro-resolver-types.ts';
import { createAssetPlugin } from './plugins/asset.ts';
import { createBabelPlugin, detectCustomPlugins } from './plugins/babel.ts';
import { normalizeExt, requireFromCli } from './plugins/internal.ts';
import {
  createMetroResolveRequestPlugin,
  type MetroResolveRequestOptions,
} from './plugins/metro-resolve-request.ts';
import { createRequireContextPlugin } from './plugins/require-context.ts';
import type { InlineBabelConfig } from './plugins/types.ts';
import { resolveRnPolyfills, RN_GLOBAL_IDENTIFIERS, tryResolve } from './rn-constants.ts';

export interface RnBundleInput {
  /** 절대 경로 entry. */
  entry: string;
  /** 프로젝트 루트 — RN polyfill / InitializeCore / Reanimated worklets resolve 의 base. */
  projectRoot: string;
  /** RN platform — preset 의 default ext / mainFields / asset loaders 결정. */
  rnPlatform: 'ios' | 'android';
  /** dev mode — banner / jsx / devMode / reactRefresh / footer 분기. */
  dev: boolean;
  /** sourcemap emit. dev 시 inline 권장. */
  sourcemap?: boolean;
  /** prod build 의 minify. */
  minify?: boolean;
  /**
   * preset 위에 user override. semantics:
   * - **Object dict** (`define` / `loader` / `alias` / `fallback` 등) — preset
   *   value 와 deep merge (key 단위 union, 충돌 시 override 우선)
   * - **Array** (`plugins` / `resolveExtensions` / `mainFields` 등) — replace
   *   (preset 의 array 무시)
   * - **Primitive** (`target` / `minify` 등) — replace
   *
   * preset 의 default 가 ZNTC RN 호환 보장 — array override 는 RN 동작 깨질
   * 위험 있음 (caller 가 의도적 변경 시만 사용).
   */
  override?: Partial<BuildOptions>;
  /** Metro 호환 추가 옵션 (caller 의 ResolvedConfig 에서 추출). */
  extra?: {
    watchFolders?: string[];
    /** Metro `resolver.nodeModulesPaths` 호환. bare import 추가 탐색 경로. */
    nodeModulesPaths?: string[];
    blockList?: (RegExp | string)[];
    fallback?: Record<string, string | false>;
    /** RN 외 사용자 plugin (asset/babel/codegen/require-context/metro-resolve-request 외 추가). */
    additionalPlugins?: ZntcPlugin[];
    /** Custom Metro resolveRequest — Metro 시그니처 그대로. */
    metroResolveRequest?: CustomResolver;
    /** Metro 호환 babel transformer path (svg-transformer 등). */
    babelTransformerPath?: string;
    /** RN sourceExts override (default RN preset). */
    sourceExts?: string[];
    /** RN assetExts override (default RN preset). */
    assetExts?: string[];
    /** 사용자 추가 polyfill (preset 의 RN polyfill 와 concat — Metro `serializer.polyfills` 호환). */
    polyfills?: string[];
    /**
     * 추가 global 변수 — banner 의 `var <key>=<JSON.stringify(value)>` 로 inject.
     * Metro `serializer.extraVars` 호환. zntc 의 `define` 과 의도가 다름:
     * `define` 은 source 의 식별자 substitution (compile-time), `extraVars` 는
     * runtime-time prelude 의 globals declaration (RN 코드 도착 전에 평가).
     */
    extraVars?: Record<string, unknown>;
    /**
     * Entry 전 실행할 module path (Metro `serializer.prelude` 호환). 절대 경로 또는
     * projectRoot 기준 상대 경로. preset 의 `runBeforeMain` (InitializeCore) 와 concat
     * 되어 RN runtime 부팅 직후 / entry 전에 실행. babel.config.js 같은 transform 영역
     * 이 아닌 **번들에 prepend 되는 module list**.
     */
    prelude?: string[];
    /**
     * 사용자 babel preset / plugin (Metro `transformer.babel` 호환). babel.config.js
     * 외에 zntc.config.ts 안에서 inline 으로 babel 설정. ZNTC native 처리 plugin (TS
     * strip / RN preset / Reanimated 등) 은 자동 제외 — 충돌 회피.
     *
     * 사용자 babel.config.js 의 plugins 와 concat 되며 양쪽 모두 ZNTC native filter
     * 통과 후 babel pass 에 forward. TS/Flow strip 은 ZNTC native transform 이 처리하므로
     * presets 는 사용자가 명시한 non-native 항목만 forward 됨.
     */
    babel?: InlineBabelConfig;
    /**
     * Sourcemap 을 bundle 에 inline 으로 embed (Metro `serializer.inlineSourceMap`
     * 호환). zntc core 의 `sourcemapMode='inline'` 으로 forward.
     */
    inlineSourceMap?: boolean;
    /**
     * Sourcemap 의 `sourceRoot` field (Metro `sourcemapSourcesRoot` 호환). 절대
     * 경로를 source 로 변환하는 base. zntc core 의 `sourceRoot` 으로 forward.
     */
    sourceRoot?: string;
    /**
     * `console.error` setter intercept 의 RegExp source string 배열 — match 시
     * silent swallow. zntc core 의 `silentConsoleErrorPatterns` 로 forward
     * (Metro `server.silentConsoleErrorPatterns` 호환). consumer (e.g.
     * `withExpo()`) 가 환경 감지 후 패턴 주입.
     */
    silentConsoleErrorPatterns?: string[];
    /**
     * Metro `server.forwardClientLogs` 호환. true면 RN runtime console.* 를 dev
     * server 터미널로 forwarding. 기본 false — RN 내부/devtool 로그 직렬화가 앱
     * 메모리를 계속 늘리는 시나리오를 피한다.
     */
    forwardClientLogs?: boolean;
  };
  /** RN prelude 끝에 append 할 사용자 banner string. */
  bannerExtras?: string;
  /** Reanimated worklets 의 jsVersion 검증용. 미지정 시 자동 resolve. */
  workletPluginVersion?: string;
}

const DEFAULT_SOURCE_EXTS = ['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.json'];
// Metro 호환 + RN 흔한 폰트/이미지 — bungae DEFAULT_RESOLVER.assetExts 와 동일.
// caller 가 `extra.assetExts` 로 override 하면 이 list 무시.
export const DEFAULT_ASSET_EXTS: string[] = [
  // 이미지
  '.bmp',
  '.gif',
  '.jpg',
  '.jpeg',
  '.png',
  '.psd',
  '.svg',
  '.webp',
  '.tiff',
  '.tif',
  '.xml',
  '.avif',
  '.ico',
  // 비디오
  '.m4v',
  '.mov',
  '.mp4',
  '.mpeg',
  '.mpg',
  '.webm',
  // 오디오
  '.aac',
  '.aiff',
  '.caf',
  '.m4a',
  '.mp3',
  '.wav',
  // 문서
  '.html',
  '.pdf',
  '.yaml',
  '.yml',
  // 폰트
  '.otf',
  '.ttf',
  '.woff',
  '.woff2',
];

const NATIVE_AND_BASE = [
  '.native.ts',
  '.native.tsx',
  '.native.js',
  '.native.jsx',
  '.ts',
  '.tsx',
  '.js',
  '.jsx',
  '.json',
];

function buildResolveExtensions(rnPlatform: 'ios' | 'android'): string[] {
  if (rnPlatform === 'ios') {
    return ['.ios.ts', '.ios.tsx', '.ios.js', '.ios.jsx', ...NATIVE_AND_BASE];
  }
  return ['.android.ts', '.android.tsx', '.android.js', '.android.jsx', ...NATIVE_AND_BASE];
}

function buildAssetLoaders(assetExts: readonly string[]): Record<string, string> {
  const loaders: Record<string, string> = {};
  for (const ext of assetExts) {
    loaders[normalizeExt(ext)] = 'file';
  }
  return loaders;
}

/**
 * prelude 가 이미 declare 한 식별자 — Hermes strict 모드에서 var 재선언 시
 * SyntaxError. caller 가 prelude 식별자를 override 할 의도면 `define` 사용.
 */
const PRELUDE_RESERVED = new Set([
  '__BUNDLE_START_TIME__',
  '__DEV__',
  '__ZNTC_RN_GLOBAL__',
  'global',
  'process',
]);

function formatExtraVars(extraVars: Record<string, unknown>): string {
  const out: string[] = [];
  for (const [key, value] of Object.entries(extraVars)) {
    if (PRELUDE_RESERVED.has(key)) continue;
    out.push(`var ${key}=${JSON.stringify(value)};`);
  }
  return out.join('');
}

function buildPrelude(input: RnBundleInput): string {
  const { dev, bannerExtras, extra } = input;
  // ⚠️ 중요: 이 prelude 에 **top-level `globalThis.X = ...` 또는 `globalThis.X = ...` 의 직접 assignment**
  // 를 두면 안 된다. iOS 26.4+ Hermes 가 parse 시점에 spec global (`Location`, `TextEncoderStream`
  // 등) placeholder 를 `configurable: false` 로 lazy 등록 → 그 후 Reanimated/Expo 의 가드 없는
  // `Object.defineProperty(globalThis, ...)` 시도 → throw → 부팅 실패. Metro bundle 도 모든
  // globalThis assignment 를 module factory 안 (nested scope) 에 두는 패턴이라 trigger 회피.
  // 추가 식별자가 필요하면 `__ZNTC_RN_BUNDLER__` 처럼 footer 의 IIFE 안에서 세팅.
  const lines = [
    `var __BUNDLE_START_TIME__=this.nativePerformanceNow?nativePerformanceNow():Date.now();`,
    `var __DEV__=${dev};`,
    `var __ZNTC_RN_GLOBAL__=typeof globalThis!=='undefined'?globalThis:typeof global!=='undefined'?global:typeof window!=='undefined'?window:this;`,
    `if(typeof global==='undefined')var global=__ZNTC_RN_GLOBAL__;`,
    `var process=__ZNTC_RN_GLOBAL__.process||{};process.env=process.env||{};process.env.NODE_ENV=process.env.NODE_ENV||"${dev ? 'development' : 'production'}";`,
  ];
  if (extra?.extraVars && Object.keys(extra.extraVars).length > 0) {
    const formatted = formatExtraVars(extra.extraVars);
    if (formatted) lines.push(formatted);
  }
  if (bannerExtras) lines.push(bannerExtras);
  return lines.join('');
}

/**
 * Footer 의 식별자 wrap — `globalThis.X = ...` 를 IIFE 안에서 실행해 iOS 26.4+ Hermes 의
 * spec global lazy registration trigger 를 회피. `buildPrelude` 의 주석 참조.
 */
function buildFooter(dev: boolean): string {
  const parts: string[] = [
    // __ZNTC_RN_BUNDLER__ flag — IIFE 안에서 set 해야 안전
    `(function(g){g.__ZNTC_RN_BUNDLER__=true;})(typeof globalThis!=='undefined'?globalThis:typeof global!=='undefined'?global:typeof window!=='undefined'?window:this);`,
  ];
  if (dev) {
    parts.push(`setTimeout(function(){try{NativeModules.DevLoadingView.hide()}catch(e){}},0);`);
  }
  return parts.join('');
}

function resolveWorkletPluginVersion(
  projectRoot: string,
  override: string | undefined,
): string | undefined {
  if (override) return override;
  try {
    const pkgPath = requireFromCli.resolve('react-native-worklets/package.json', {
      paths: [projectRoot],
    });
    const pkg = requireFromCli(pkgPath) as { version?: string };
    return pkg.version;
  } catch {
    return undefined;
  }
}

function deepMerge<T extends Record<string, unknown>>(base: T, override: Partial<T>): T {
  const result: Record<string, unknown> = { ...base };
  for (const [key, value] of Object.entries(override)) {
    if (value === undefined) continue;
    const existing = result[key];
    if (
      existing &&
      typeof existing === 'object' &&
      !Array.isArray(existing) &&
      value &&
      typeof value === 'object' &&
      !Array.isArray(value)
    ) {
      result[key] = deepMerge(
        existing as Record<string, unknown>,
        value as Record<string, unknown>,
      );
    } else {
      result[key] = value;
    }
  }
  return result as T;
}

/**
 * RN preset — RnBundleInput → BuildOptions. 번개 napi-build.ts L74-L268 의 RN
 * 분기와 동등 동작.
 */
export function buildRnBundleOptions(input: RnBundleInput): BuildOptions {
  const { entry, projectRoot, rnPlatform, dev, sourcemap, minify, extra } = input;

  const sourceExts = extra?.sourceExts ?? DEFAULT_SOURCE_EXTS;
  const assetExts = extra?.assetExts ?? DEFAULT_ASSET_EXTS;

  // Plugin set — RN preset 기본 runtime/require-context + optional Babel compatibility
  // + optional MetroResolveRequest + optional additional.
  const plugins: ZntcPlugin[] = [
    createAssetPlugin({
      projectRoot,
      assetExts,
      rnPlatform,
      sourceExts,
      babelTransformerPath: extra?.babelTransformerPath,
      forwardClientLogs: extra?.forwardClientLogs,
    }),
  ];

  // Babel compatibility is opt-in by detection. Native RN preset/worklet/codegen
  // paths cover the default case, so projects with only native-equivalent Babel
  // config do not pay a per-file Babel pass.
  if (detectCustomPlugins(projectRoot, extra?.babel)) {
    plugins.push(
      createBabelPlugin({
        projectRoot,
        assetExts,
        rnPlatform,
        sourceExts,
        inlineBabel: extra?.babel,
      }),
    );
  }

  plugins.push(createRequireContextPlugin());
  if (extra?.metroResolveRequest) {
    const opts: MetroResolveRequestOptions = {
      resolveRequest: extra.metroResolveRequest,
      // RN preset 의 rnPlatform (ios/android) 을 MetroPlatform 으로. caller 가
      // web 시나리오를 원하면 metro-resolve-request 를 직접 만들어 plugin 에 주입.
      platform: rnPlatform as MetroPlatform,
    };
    plugins.push(createMetroResolveRequestPlugin(opts));
  }
  if (extra?.additionalPlugins) {
    plugins.push(...extra.additionalPlugins);
  }

  const polyfills = [...resolveRnPolyfills(projectRoot)];
  if (extra?.polyfills && extra.polyfills.length > 0) {
    // 사용자 추가 polyfill — projectRoot 기준으로 절대화. Metro 가 절대 경로
    // 받는 것과 동일.
    for (const p of extra.polyfills) polyfills.push(resolve(projectRoot, p));
  }
  const runBeforeMain: string[] = [];
  const initCore = tryResolve('react-native/Libraries/Core/InitializeCore', projectRoot);
  if (initCore) runBeforeMain.push(initCore);
  if (extra?.prelude && extra.prelude.length > 0) {
    // 사용자 추가 prelude — InitializeCore 이후에 실행. 절대/상대 모두 projectRoot
    // 기준으로 정규화.
    for (const p of extra.prelude) runBeforeMain.push(resolve(projectRoot, p));
  }

  const define: Record<string, string> = {
    global: '__ZNTC_RN_GLOBAL__',
    __DEV__: String(dev),
    'process.env.NODE_ENV': `"${dev ? 'development' : 'production'}"`,
    // expo-router `_ctx.{ios,android,web}.js` 의 require.context 인자 정적 평가용
    // (Phase 2.6 import_scanner). 절대 경로 필수 — `_ctx` 가 node_modules 안에 있어
    // 상대 경로면 require-context 플러그인의 `resolve(dirname(importer), dir)` 가
    // `node_modules/expo-router/app/` 를 가리켜 ctx 매치 0.
    'process.env.EXPO_ROUTER_APP_ROOT': JSON.stringify(resolve(projectRoot, 'app')),
    'process.env.EXPO_ROUTER_IMPORT_MODE': '"sync"',
    'process.env.EXPO_OS': `"${rnPlatform}"`,
  };

  const baseLoader = buildAssetLoaders(assetExts);

  const preset: BuildOptions = {
    entryPoints: [resolve(projectRoot, entry)],
    platform: 'react-native',
    sourcemap: sourcemap ?? dev,
    minify: minify ?? false,
    plugins,
    emitDiskSourcemap: !dev,
    target: 'es5',
    flow: true,
    jsxInJs: true,
    configurableExports: true,
    strictExecutionOrder: true,
    workletTransform: true,
    codegenTransform: true,
    resolveExtensions: buildResolveExtensions(rnPlatform),
    mainFields: ['react-native', 'browser', 'main'],
    loader: baseLoader,
    alias: {},
    define,
    banner: buildPrelude(input),
    globalIdentifiers: [...RN_GLOBAL_IDENTIFIERS],
  };

  if (polyfills.length > 0) preset.polyfills = polyfills;
  if (runBeforeMain.length > 0) preset.runBeforeMain = runBeforeMain;

  // Reanimated worklets 의 jsVersion 검증 — Reanimated runtime 의 serializable.native.ts:464
  // 가 plugin 의 inject 와 mismatch 시 WorkletsError throw.
  const workletVersion = resolveWorkletPluginVersion(projectRoot, input.workletPluginVersion);
  if (workletVersion) preset.workletPluginVersion = workletVersion;

  // Footer 는 항상 — `__ZNTC_RN_BUNDLER__` flag 를 IIFE 로 wrap 해 iOS 26.4+ Hermes
  // spec global trigger 회피 (`buildPrelude` 의 주석 참조). dev 시 DevLoadingView
  // hide 도 추가.
  preset.footer = buildFooter(dev);

  if (dev) {
    preset.jsx = 'automatic-dev';
    preset.devMode = true;
    preset.reactRefresh = true;
    preset.collectModuleCodes = true;
  }

  if (extra?.watchFolders && extra.watchFolders.length > 0) {
    preset.watchFolders = extra.watchFolders.map((p) => resolve(projectRoot, p));
  }
  if (extra?.nodeModulesPaths && extra.nodeModulesPaths.length > 0) {
    preset.nodePaths = extra.nodeModulesPaths.map((p) => resolve(projectRoot, p));
  }
  if (extra?.blockList && extra.blockList.length > 0) {
    preset.blockList = extra.blockList;
  }
  if (extra?.fallback && Object.keys(extra.fallback).length > 0) {
    preset.fallback = { ...extra.fallback };
  }
  if (extra?.inlineSourceMap === true) {
    preset.sourcemapMode = 'inline';
  }
  if (extra?.sourceRoot) {
    preset.sourceRoot = extra.sourceRoot;
  }
  if (extra?.silentConsoleErrorPatterns && extra.silentConsoleErrorPatterns.length > 0) {
    preset.silentConsoleErrorPatterns = [...extra.silentConsoleErrorPatterns];
  }

  // user override 는 마지막 — define / loader / alias 같은 dict 는 deep merge,
  // 그 외 (plugins / banner 등) 는 replace.
  if (input.override) {
    return deepMerge(
      preset as unknown as Record<string, unknown>,
      input.override as unknown as Partial<Record<string, unknown>>,
    ) as unknown as BuildOptions;
  }
  return preset;
}

/**
 * One-shot wrapper — `init()` + `build(buildRnBundleOptions(input))`. caller 가
 * NAPI direct 호출이 아니라 단순 prod bundle 시나리오.
 *
 * `init()` 은 idempotent (core 의 module-cache `if (native) return`) — caller
 * 가 별도로 `init(path)` 호출 후 `bundleRn` 호출해도 안전 (앞선 path 가 우선).
 */
export async function bundleRn(input: RnBundleInput): Promise<BuildResult> {
  init();
  return build(buildRnBundleOptions(input));
}

export interface RnWatchInput extends RnBundleInput {
  outfile: string;
  onReady?: (event: WatchReadyEvent) => void;
  onRebuild?: (event: WatchRebuildEvent) => void | Promise<void>;
}

/**
 * Watch wrapper — `init()` + `watch(buildRnBundleOptions(input))` + outfile +
 * onReady/onRebuild wire-up. handle 반환 (caller 가 close). `init()` idempotent.
 */
export function watchRn(input: RnWatchInput): WatchHandle {
  init();
  const opts = buildRnBundleOptions(input);
  opts.outfile = input.outfile;
  opts.write = true;
  if (input.onReady) opts.onReady = input.onReady;
  if (input.onRebuild) opts.onRebuild = input.onRebuild;
  return watch(opts);
}
