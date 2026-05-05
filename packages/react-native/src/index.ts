// @zts/react-native — RN platform layer (#2540).
// preset (buildRnBundleOptions / bundleRn / watchRn) + Metro HMR adapter + RN
// runtime (zts-hmr-client.js) + plugin factories (asset/babel/codegen/...).

// `@zts/server` 의 RN 측 표면을 단일 entry 로 재수출. server 는 private 이라
// react-native 의 dist 에 inline (npm install 시 별도 의존 불필요).
export {
  HMR_RN_MSG,
  type HmrRnErrorMessage,
  type HmrRnLogMessage,
  type HmrRnMessage,
  type HmrRnMessageType,
  type HmrRnReloadMessage,
  type HmrRnUpdateDoneMessage,
  type HmrRnUpdateMessage,
  type HmrRnUpdateModule,
  type HmrRnUpdateStartMessage,
} from "@zts/server";

export {
  type AssetResolverOptions,
  type Broadcast,
  buildRnDevServerOptions,
  createBaseMiddleware,
  createDevHttpServer,
  createHmrBridge,
  createPlatformState,
  type CliServerApi,
  type CliWebsocketEndpoint,
  type DevMiddleware,
  loadCliServerApi,
  loadDevMiddleware,
  type LoadCliServerApiOptions,
  type LoadDevMiddlewareOptions,
  createPlatformStateRegistry,
  type CustomizeFrame,
  type DevHttpServerDeps,
  type DevHttpServerHandle,
  type FrameInfo,
  getCachedSourceMap,
  type HmrBridge,
  type HmrBridgeOptions,
  applyCustomizeFrame,
  createSourceMapConsumer,
  extractCodeFrame,
  handleAssetRequest,
  handleBundleRequest,
  handleHmrMapRequest,
  handleIndexPage,
  handleMapRequest,
  handleSymbolicateRequest,
  isIndexRoute,
  isAssetRoute,
  isBundleRoute,
  isHmrMapRoute,
  isMapRoute,
  isSymbolicateRoute,
  normalizeFrame,
  symbolicateFrame,
  type SymbolicateCodeFrame,
  type SymbolicateRequest,
  type SymbolicateResponse,
  type Middleware,
  type MiddlewareEnhanceContext,
  type PlatformState,
  type PlatformStateCallbacks,
  type PlatformStateRegistry,
  postProcessSourceMap,
  resolveAssetPath,
  serveRn,
  setupTerminalActions,
  type TerminalActionsCallbacks,
  type TerminalActionsOptions,
  type RnDevServerHandle,
  type RnDevServerOptions,
  type RnDevServerOptionsInput,
  waitForBuild,
} from "./dev-server/index.ts";
export { createMetroHmrAdapter, type MetroHmrAdapter } from "./metro-hmr-adapter.ts";
export type {
  CustomResolver,
  MetroPlatform,
  Resolution,
  ResolutionContext,
} from "./metro-resolver-types.ts";
export { createAssetPlugin } from "./plugins/asset.ts";
export {
  createBabelPlugin,
  createBabelTransformer,
  detectCustomPlugins,
  isZtsNativePlugin,
  ZTS_NATIVE_PLUGIN_PATTERNS,
} from "./plugins/babel.ts";
export {
  CODEGEN_NATIVE_COMPONENT_MARKER,
  createCodegenPlugin,
  createCodegenTransformer,
} from "./plugins/codegen.ts";
export { escapeRegex } from "./plugins/escape-regex.ts";
export {
  createMetroResolveRequestPlugin,
  type MetroResolveRequestOptions,
} from "./plugins/metro-resolve-request.ts";
export { createRequireContextPlugin } from "./plugins/require-context.ts";
export type { PluginConfig } from "./plugins/types.ts";
export {
  buildRnBundleOptions,
  bundleRn,
  type RnBundleInput,
  type RnWatchInput,
  watchRn,
} from "./preset.ts";
export { resolveRnPolyfills, RN_GLOBAL_IDENTIFIERS, tryResolve } from "./rn-constants.ts";
export { HMR_CLIENT_SUFFIX, ZTS_HMR_CLIENT_CODE } from "./runtime-loader.ts";
