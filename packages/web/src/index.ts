// @zts/web — dev server / postcss·sass·lightningcss / HMR overlay 가 자리잡는 패키지.
// 분리 진행: #2539.

export {
  type BundleResult,
  injectAppDevBundleCssLinks,
  injectAppDevHmrClient,
  injectAppDevPipelineCssLinks,
  injectIntoDevHtml,
  joinUrl,
} from "./inject.ts";
// dev-overlay-client 는 .mjs 라 별도 export — 브라우저 inject 용 string.
export { APP_DEV_HMR_CLIENT } from "../runtime/dev-overlay-client.mjs";
