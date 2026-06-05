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

import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

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
// DISABLED: babel.config.js auto-detection/loading temporarily turned off (unstable).
// import { createBabelPlugin, detectCustomPlugins } from './plugins/babel.ts';
import { normalizeExt, requireFromCli } from './plugins/internal.ts';
import {
  createMetroResolveRequestPlugin,
  type MetroResolveRequestOptions,
} from './plugins/metro-resolve-request.ts';
import { createRequireContextPlugin } from './plugins/require-context.ts';
import type { InlineBabelConfig } from './plugins/types.ts';
import {
  resolveRnPolyfills,
  RN_GLOBAL_IDENTIFIERS,
  RN_SINGLETON_PACKAGES,
  tryResolve,
} from './rn-constants.ts';

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
  /** console.* 호출 제거. Metro production Babel plugin 과 같은 정책을 원하는 release 경로에서 사용. */
  dropConsole?: boolean;
  /** debugger statement 제거. */
  dropDebugger?: boolean;
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
    /**
     * Metro `resolver.disableHierarchicalLookup` 호환. true 면 entry 디렉토리
     * 외부의 `node_modules` walk-up 탐색을 차단 — monorepo 에서 dependency
     * hoisting 강제 또는 워크스페이스 외부 모듈 누수 방지에 사용.
     */
    disableHierarchicalLookup?: boolean;
    blockList?: (RegExp | string)[];
    fallback?: Record<string, string | false>;
    /** RN 외 사용자 plugin (asset/babel/codegen/require-context/metro-resolve-request 외 추가). */
    additionalPlugins?: ZntcPlugin[];
    /** Custom Metro resolveRequest — Metro 시그니처 그대로. */
    metroResolveRequest?: CustomResolver;
    /** Metro 호환 babel transformer path (svg-transformer 등). */
    babelTransformerPath?: string;
    /**
     * HMR 위상 보존 plugin 게이트 명시 override. 미지정(undefined)이면 preset 이 보수적으로
     * 판정한다 — 내장 plugin 만이면 true, additionalPlugins/metroResolveRequest/
     * babelTransformerPath 중 하나라도 있으면 false. 사용자가 "내 resolver/transformer 가
     * 결정적·모듈별 순수(같은 입력→같은 출력, 전역 상태 무의존)"임을 보장할 수 있으면 true 로
     * 명시해 보존을 강제(=HMR rebuild 가속)할 수 있다. 비결정이면 stale 번들 위험은 사용자 책임.
     * false 명시로 강제 비활성도 가능.
     */
    preserveSafePlugins?: boolean;
    /** RN sourceExts override (default RN preset). */
    sourceExts?: string[];
    /** RN assetExts override (default RN preset). */
    assetExts?: string[];
    /**
     * Metro `resolver.platforms` 호환. caller 가 인식 가능한 platform 이름 set.
     * `rnPlatform` 이 이 list 안에 있어야 하며, list 자체는 prefix 확장에는
     * 영향 없음 (Metro 동작과 동일 — current platform suffix 만 expand). 이
     * sugar 는 사용자가 자신의 platform list 를 명시했을 때 `rnPlatform`
     * 누락을 빌드 직전에 잡는 validation 용. 미래의 platform typing 확장
     * (e.g. `tvos`/`macos`) 의 placeholder.
     */
    platforms?: string[];
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
     * Metro `server.forwardClientLogs` 호환. RN core 의 HMRClient.log 경유 로그를
     * dev server 터미널로 forwarding. 기본 true.
     */
    forwardClientLogs?: boolean;
  };
  /** RN prelude 끝에 append 할 사용자 banner string. */
  bannerExtras?: string;
  /** Reanimated worklets 의 jsVersion 검증용. 미지정 시 자동 resolve. */
  workletPluginVersion?: string;
}

const DEFAULT_SOURCE_EXTS = ['.js', '.jsx', '.json', '.ts', '.tsx', '.mjs', '.cjs'];
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

function buildResolveExtensions(
  rnPlatform: 'ios' | 'android',
  sourceExts: readonly string[],
): string[] {
  const platformPrefix = `.${rnPlatform}`;
  const extensions: string[] = [];
  const seen = new Set<string>();

  for (const sourceExt of sourceExts) {
    const ext = normalizeExt(sourceExt);
    for (const candidate of [`${platformPrefix}${ext}`, `.native${ext}`, ext]) {
      if (!seen.has(candidate)) {
        seen.add(candidate);
        extensions.push(candidate);
      }
    }
  }

  return extensions;
}

function buildAssetLoaders(assetExts: readonly string[]): Record<string, string> {
  const loaders: Record<string, string> = {};
  for (const ext of assetExts) {
    loaders[normalizeExt(ext)] = 'file';
  }
  return loaders;
}

function tryResolvePackageRoot(packageName: string, projectRoot: string): string | null {
  const logicalRoot = resolve(projectRoot, 'node_modules', packageName);
  if (existsSync(resolve(logicalRoot, 'package.json'))) return logicalRoot;

  const pkgJson = tryResolve(`${packageName}/package.json`, projectRoot);
  return pkgJson ? dirname(pkgJson) : null;
}

function tryResolvePackageFile(
  packageName: string,
  relativePath: string,
  projectRoot: string,
): string | null {
  const packageRoot = tryResolvePackageRoot(packageName, projectRoot);
  if (packageRoot) {
    const file = resolve(packageRoot, relativePath);
    if (existsSync(file)) return file;
  }

  return tryResolve(`${packageName}/${relativePath}`, projectRoot);
}

function buildRnSingletonAliases(projectRoot: string): Record<string, string> {
  const aliases: Record<string, string> = {};
  for (const packageName of RN_SINGLETON_PACKAGES) {
    const packageRoot = tryResolvePackageRoot(packageName, projectRoot);
    if (packageRoot) aliases[packageName] = packageRoot;
  }
  return aliases;
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

const RN_GLOBAL_EXPR =
  "(function(g,t,w,s){return g&&(typeof g==='object'||typeof g==='function')?g:t&&(typeof t==='object'||typeof t==='function')?t:w&&(typeof w==='object'||typeof w==='function')?w:s;})(typeof global!=='undefined'?global:void 0,typeof globalThis!=='undefined'?globalThis:void 0,typeof window!=='undefined'?window:void 0,this)";

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
  //
  // RN 런타임 소스의 `global` 식별자는 Metro 에서 `metro-runtime/src/polyfills/require.js`
  // 가 module factory 에 넘기는 native global 과 동등해야 한다. 따라서 zntc 치환 대상인
  // `__ZNTC_RN_GLOBAL__` 도 `globalThis` 보다 native `global` 을 먼저 선택한다.
  const lines = [
    `var __BUNDLE_START_TIME__=this.nativePerformanceNow?nativePerformanceNow():Date.now();`,
    `var __DEV__=${dev};`,
    `var __ZNTC_RN_GLOBAL__=${RN_GLOBAL_EXPR};`,
    `if(typeof global==='undefined')global=__ZNTC_RN_GLOBAL__;`,
    `if(typeof __ZNTC_RN_GLOBAL__.hasOwnProperty!=='function')try{Object.defineProperty(__ZNTC_RN_GLOBAL__,'hasOwnProperty',{value:Object.prototype.hasOwnProperty,configurable:true,writable:true});}catch(_e){try{__ZNTC_RN_GLOBAL__.hasOwnProperty=Object.prototype.hasOwnProperty;}catch(_e2){}}`,
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
    `(function(g){g.__ZNTC_RN_BUNDLER__=true;})(${RN_GLOBAL_EXPR});`,
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
  const {
    entry,
    projectRoot,
    rnPlatform,
    dev,
    sourcemap,
    minify,
    dropConsole,
    dropDebugger,
    extra,
  } = input;

  if (extra?.platforms && !extra.platforms.includes(rnPlatform)) {
    throw new Error(
      `extra.platforms (${JSON.stringify(extra.platforms)}) does not include the active rnPlatform '${rnPlatform}'`,
    );
  }

  const sourceExts = extra?.sourceExts ?? DEFAULT_SOURCE_EXTS;
  const assetExts = extra?.assetExts ?? DEFAULT_ASSET_EXTS;

  // Plugin set — RN preset 기본 runtime/require-context + optional Babel compatibility
  // + optional MetroResolveRequest + optional additional.
  const plugins: ZntcPlugin[] = [];

  if (extra?.metroResolveRequest) {
    const opts: MetroResolveRequestOptions = {
      resolveRequest: extra.metroResolveRequest,
      // RN preset 의 rnPlatform (ios/android) 을 MetroPlatform 으로. caller 가
      // web 시나리오를 원하면 metro-resolve-request 를 직접 만들어 plugin 에 주입.
      platform: rnPlatform as MetroPlatform,
    };
    plugins.push(createMetroResolveRequestPlugin(opts));
  }

  plugins.push(
    createAssetPlugin({
      projectRoot,
      assetExts,
      rnPlatform,
      dev,
      sourceExts,
      babelTransformerPath: extra?.babelTransformerPath,
    }),
  );
  // Babel compatibility is opt-in by detection. Native RN preset/worklet/codegen
  // paths cover the default case, so projects with only native-equivalent Babel
  // config do not pay a per-file Babel pass.
  //
  // DISABLED: babel.config.js auto-detection/loading is currently too unstable.
  // Re-enable by uncommenting the block below once stabilized.
  // if (detectCustomPlugins(projectRoot, extra?.babel)) {
  //   plugins.push(
  //     createBabelPlugin({
  //       projectRoot,
  //       assetExts,
  //       rnPlatform,
  //       sourceExts,
  //       inlineBabel: extra?.babel,
  //     }),
  //   );
  // }

  plugins.push(createRequireContextPlugin());
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
  const initCore = tryResolvePackageFile(
    'react-native',
    'Libraries/Core/InitializeCore.js',
    projectRoot,
  );
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
    dropConsole: dropConsole ?? false,
    dropDebugger: dropDebugger ?? false,
    plugins,
    emitDiskSourcemap: !dev,
    target: 'es5',
    flow: true,
    jsxInJs: true,
    configurableExports: true,
    strictExecutionOrder: true,
    // RN/Hermes 번들은 파일 전체를 먼저 파싱하므로 실행되지 않는 분기라도
    // raw `import()` 문법이 남으면 릴리즈 빌드에서 실패한다.
    inlineDynamicImports: true,
    workletTransform: true,
    codegenTransform: true,
    // PR-3: RN preset 내장 plugin(asset/metro-resolve-request/require-context/codegen)은 전부
    // 결정적·모듈별 순수 → HMR 위상 보존 안전. 단 "사용자 임의 코드"가 주입되는 경로가 하나라도
    // 있으면 결정성(같은 입력→같은 출력)을 보장할 수 없어 false 로 강등(보존 끄고 종전 fallback):
    //   - additionalPlugins: 사용자 ZntcPlugin 배열
    //   - metroResolveRequest: 사용자 resolveRequest 함수(:414 에서 resolveId plugin 으로 래핑)
    //   - babelTransformerPath: 사용자 transformer 모듈(:424 asset plugin onLoad 가 실행)
    // 이들이 비결정이면 보존 경로가 unchanged 모듈을 재평가하지 않아 stale 번들이 될 수 있다.
    // 단 사용자가 extra.preserveSafePlugins 를 명시하면(true/false) 그 값이 우선 — "내 resolver/
    // transformer 는 결정적"이라는 책임 있는 opt-in(또는 명시 opt-out). `??` 라 false 도 존중.
    preserveSafePlugins:
      extra?.preserveSafePlugins ??
      !(
        (extra?.additionalPlugins && extra.additionalPlugins.length > 0) ||
        extra?.metroResolveRequest ||
        extra?.babelTransformerPath
      ),
    resolveExtensions: buildResolveExtensions(rnPlatform, sourceExts),
    mainFields: ['react-native', 'browser', 'main'],
    loader: baseLoader,
    // RN core package 는 singleton 이어야 한다. pnpm peer folder 에서
    // react-native/react 가 별도 module 로 들어오면 InitializeCore/DevTools 가
    // 다시 실행되어 Fabric 이 깨질 수 있다.
    alias: buildRnSingletonAliases(projectRoot),
    // Metro 설정과 맞춰 pnpm symlink 를 처리한다. resolver 는 표준 pnpm package
    // symlink 의 module identity 를 실제 .pnpm package path 로 정규화하되, workspace
    // symlink 는 logical path 를 유지한다.
    preserveSymlinks: true,
    // logical lookup 에 실패한 package-private/peer dependency 는 실제 pnpm package
    // 옆 node_modules 를 fallback 으로 탐색한다.
    resolveSymlinkSiblings: true,
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

  preset.jsx = dev ? 'automatic-dev' : 'automatic';

  if (dev) {
    preset.devMode = true;
    preset.reactRefresh = true;
    preset.collectModuleCodes = true;
  } else if (minify !== true) {
    // Metro release 와 같이 __DEV__ false 분기는 full minify 없이도 제거한다.
    // 공백 압축/식별자 축약은 유지하고 syntax pass 만 켜서 dev-only worklet 이
    // 릴리즈 번들에 남지 않게 한다.
    preset.minifySyntax = true;
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
  if (extra?.disableHierarchicalLookup === true) {
    preset.disableHierarchicalLookup = true;
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
