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

export { resolveRnPolyfills, RN_GLOBAL_IDENTIFIERS, tryResolve } from "./rn-constants.ts";
export type {
  CustomResolver,
  MetroPlatform,
  Resolution,
  ResolutionContext,
} from "./metro-resolver-types.ts";
export { escapeRegex } from "./plugins/escape-regex.ts";
export { HMR_CLIENT_SUFFIX, ZTS_HMR_CLIENT_CODE } from "./runtime-loader.ts";
