// RN preset — `RnBundleInput` (사용자 입력) → `BuildOptions` (ZTS NAPI build/watch
// 입력). 번개 napi-build.ts 의 RN 분기 (L74~L268) 와 동등 동작 + 번개 의존성 0.
//
// 자동 활성 필드 (RN platform 시): target=es5, flow=true, jsxInJs=true,
// configurableExports=true, strictExecutionOrder=true, workletTransform=true,
// resolveExtensions (ios/android prefix), mainFields (RN/browser/module/main),
// banner (RN prelude), define (__DEV__/process.env), polyfills/runBeforeMain/
// globalIdentifiers (resolveRnPolyfills + InitializeCore + RN_GLOBAL_IDENTIFIERS),
// loader (asset 확장자), plugins (asset/codegen/babel/require-context/[metro-resolve-request]).
//
// dev 시 추가: jsx=automatic-dev, devMode=true, reactRefresh=true,
// collectModuleCodes=true, footer (DevLoadingView hide).
//
// caller (번개 / RN 사용자) 가 input 으로 base config 전달 → preset 이 BuildOptions
// 빌드 → 마지막에 input.override 로 사용자 override 가능.

import { resolve } from "node:path";

import {
  build,
  type BuildOptions,
  type BuildResult,
  init,
  watch,
  type WatchHandle,
  type WatchReadyEvent,
  type WatchRebuildEvent,
  type ZtsPlugin,
} from "@zts/core";

import type { CustomResolver, MetroPlatform } from "./metro-resolver-types.ts";
import { createAssetPlugin } from "./plugins/asset.ts";
import { createBabelPlugin } from "./plugins/babel.ts";
import { createCodegenPlugin } from "./plugins/codegen.ts";
import { requireFromCli } from "./plugins/internal.ts";
import {
  createMetroResolveRequestPlugin,
  type MetroResolveRequestOptions,
} from "./plugins/metro-resolve-request.ts";
import { createRequireContextPlugin } from "./plugins/require-context.ts";
import { resolveRnPolyfills, RN_GLOBAL_IDENTIFIERS, tryResolve } from "./rn-constants.ts";

export interface RnBundleInput {
  /** 절대 경로 entry. */
  entry: string;
  /** 프로젝트 루트 — RN polyfill / InitializeCore / Reanimated worklets resolve 의 base. */
  projectRoot: string;
  /** RN platform — preset 의 default ext / mainFields / asset loaders 결정. */
  rnPlatform: "ios" | "android";
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
   * preset 의 default 가 ZTS RN 호환 보장 — array override 는 RN 동작 깨질
   * 위험 있음 (caller 가 의도적 변경 시만 사용).
   */
  override?: Partial<BuildOptions>;
  /** Metro 호환 추가 옵션 (caller 의 ResolvedConfig 에서 추출). */
  extra?: {
    watchFolders?: string[];
    blockList?: (RegExp | string)[];
    fallback?: Record<string, string | false>;
    /** RN 외 사용자 plugin (asset/babel/codegen/require-context/metro-resolve-request 외 추가). */
    additionalPlugins?: ZtsPlugin[];
    /** Custom Metro resolveRequest — Metro 시그니처 그대로. */
    metroResolveRequest?: CustomResolver;
    /** Metro 호환 babel transformer path (svg-transformer 등). */
    babelTransformerPath?: string;
    /** RN sourceExts override (default RN preset). */
    sourceExts?: string[];
    /** RN assetExts override (default RN preset). */
    assetExts?: string[];
  };
  /** RN prelude 끝에 append 할 사용자 banner string. */
  bannerExtras?: string;
  /** Reanimated worklets 의 jsVersion 검증용. 미지정 시 자동 resolve. */
  workletPluginVersion?: string;
}

const DEFAULT_SOURCE_EXTS = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json"];
const DEFAULT_ASSET_EXTS = [
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".svg",
  ".ttf",
  ".otf",
  ".mp3",
  ".mp4",
  ".m4a",
  ".m4v",
  ".pdf",
  ".html",
];

const NATIVE_AND_BASE = [
  ".native.ts",
  ".native.tsx",
  ".native.js",
  ".native.jsx",
  ".ts",
  ".tsx",
  ".js",
  ".jsx",
  ".json",
];

function buildResolveExtensions(rnPlatform: "ios" | "android"): string[] {
  if (rnPlatform === "ios") {
    return [".ios.ts", ".ios.tsx", ".ios.js", ".ios.jsx", ...NATIVE_AND_BASE];
  }
  return [".android.ts", ".android.tsx", ".android.js", ".android.jsx", ...NATIVE_AND_BASE];
}

function buildAssetLoaders(assetExts: readonly string[]): Record<string, string> {
  const loaders: Record<string, string> = {};
  for (const ext of assetExts) {
    loaders[ext.startsWith(".") ? ext : `.${ext}`] = "file";
  }
  return loaders;
}

function buildPrelude(input: RnBundleInput): string {
  const { dev, bannerExtras } = input;
  const lines = [
    `var __BUNDLE_START_TIME__=this.nativePerformanceNow?nativePerformanceNow():Date.now();`,
    `var __DEV__=${dev};`,
    `var __ZTS_RN_GLOBAL__=typeof globalThis!=='undefined'?globalThis:typeof global!=='undefined'?global:typeof window!=='undefined'?window:this;`,
    `if(typeof global==='undefined')var global=__ZTS_RN_GLOBAL__;`,
    `var process=__ZTS_RN_GLOBAL__.process||{};process.env=process.env||{};process.env.NODE_ENV=process.env.NODE_ENV||"${dev ? "development" : "production"}";`,
    `globalThis.__ZTS_RN_BUNDLER__=true;`,
  ];
  if (bannerExtras) lines.push(bannerExtras);
  return lines.join("");
}

function resolveWorkletPluginVersion(
  projectRoot: string,
  override: string | undefined,
): string | undefined {
  if (override) return override;
  try {
    const pkgPath = requireFromCli.resolve("react-native-worklets/package.json", {
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
      typeof existing === "object" &&
      !Array.isArray(existing) &&
      value &&
      typeof value === "object" &&
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

  // Plugin set — RN preset 기본 4 + (옵션) MetroResolveRequest + (옵션) additional.
  const plugins: ZtsPlugin[] = [
    createAssetPlugin({
      projectRoot,
      assetExts,
      rnPlatform,
      sourceExts,
      babelTransformerPath: extra?.babelTransformerPath,
    }),
    createCodegenPlugin({
      projectRoot,
      assetExts,
      rnPlatform,
      sourceExts,
    }),
    createBabelPlugin({
      projectRoot,
      assetExts,
      rnPlatform,
      sourceExts,
    }),
    createRequireContextPlugin(),
  ];
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

  const polyfills = resolveRnPolyfills(projectRoot);
  const runBeforeMain: string[] = [];
  const initCore = tryResolve("react-native/Libraries/Core/InitializeCore", projectRoot);
  if (initCore) runBeforeMain.push(initCore);

  const define: Record<string, string> = {
    global: "__ZTS_RN_GLOBAL__",
    __DEV__: String(dev),
    "process.env.NODE_ENV": `"${dev ? "development" : "production"}"`,
    // Expo Router 의 require.context 인자 정적 평가용 (Phase 2.6 import_scanner).
    "process.env.EXPO_ROUTER_APP_ROOT": '"./app"',
    "process.env.EXPO_ROUTER_IMPORT_MODE": '"sync"',
    "process.env.EXPO_OS": `"${rnPlatform}"`,
  };

  const baseLoader = buildAssetLoaders(assetExts);

  const preset: BuildOptions = {
    entryPoints: [resolve(projectRoot, entry)],
    platform: "react-native",
    sourcemap: sourcemap ?? dev,
    minify: minify ?? false,
    plugins,
    emitDiskSourcemap: !dev,
    target: "es5",
    flow: true,
    jsxInJs: true,
    configurableExports: true,
    strictExecutionOrder: true,
    workletTransform: true,
    resolveExtensions: buildResolveExtensions(rnPlatform),
    mainFields: ["react-native", "browser", "module", "main"],
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

  if (dev) {
    preset.jsx = "automatic-dev";
    preset.devMode = true;
    preset.reactRefresh = true;
    preset.collectModuleCodes = true;
    preset.footer = "setTimeout(function(){try{NativeModules.DevLoadingView.hide()}catch(e){}},0);";
  }

  if (extra?.watchFolders && extra.watchFolders.length > 0) {
    preset.watchFolders = extra.watchFolders.map((p) => resolve(projectRoot, p));
  }
  if (extra?.blockList && extra.blockList.length > 0) {
    preset.blockList = extra.blockList;
  }
  if (extra?.fallback && Object.keys(extra.fallback).length > 0) {
    preset.fallback = { ...extra.fallback };
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
  onRebuild?: (event: WatchRebuildEvent) => void;
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
