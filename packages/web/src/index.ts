// @zntc/web — dev server / postcss·sass / HMR overlay 가 자리잡는 패키지 (#2539).
// lightningcss 는 @zntc/core 가 직접 사용 (CSS minify 후처리), web 영역 아님.

// `@zntc/server` 의 HMR / Watcher 표면을 web 사용자 (zntc.mjs CLI / RN bridge /
// future edge runtime) 가 단일 entry 로 받도록 재수출. server 는 private 패키지라
// web 의 dist 에 inline 되므로 consumer 는 별도 install 불필요.
export {
  APP_DEV_HMR_CLIENT_PATH,
  APP_DEV_HMR_WS_PATH,
  type BunHmrClient,
  createHmrChannel,
  createWatcher,
  type CreateWatcherOptions,
  HMR_MSG,
  type HmrChannel,
  type HmrConnectedMessage,
  type HmrCssUpdateMessage,
  type HmrError,
  type HmrErrorMessage,
  type HmrFullReloadMessage,
  type HmrMessage,
  type HmrMessageType,
  type WatchEventType,
  type WatchFn,
  type WatchListener,
  type WatcherHandle,
  type WatcherInstance,
} from '@zntc/server';
export {
  type BundleResult,
  injectAppDevBundleCssLinks,
  injectAppDevHmrClient,
  injectAppDevPipelineCssLinks,
  injectIntoDevHtml,
} from './inject.ts';
export {
  DEFAULT_HTML_ENV_PREFIX,
  type TransformHtmlEnvResult,
  applyHtmlEnvTokens,
  transformHtmlEnvTokens,
} from './html-env.ts';
export { joinUrl } from './url.ts';
export {
  isCssIdent,
  isCssIdentStart,
  skipCssString,
  skipCssUrl,
  startsWithCssIdent,
} from './style/css-parser.ts';
export {
  collectAppFiles,
  type CollectAppFilesOptions,
  requireFromAppOrFallback,
} from './style/loader.ts';
export {
  type AppDevPostcssOptions,
  type AppDevPostcssResult,
  collectPostcssMessages,
  findPostcssConfig,
  isCssFile,
  isPostcssConfigFile,
  loadPostcssConfig,
  logPostcssProcessed,
  type PostcssMessage,
  POSTCSS_CONFIG_NAMES,
  runPostcssForAppDev,
  runPostcssIfConfigured,
} from './style/postcss.ts';
export {
  buildCssPreprocessorProxy,
  CSS_PREPROCESSOR_EXTENSIONS,
  compileSassFile,
  cssPreprocessorOutputPath,
  cssPreprocessorProxyPath,
  isCssModulePreprocessorFile,
  isCssPreprocessorFile,
  isStyleReferenceSource,
  loadSassCompiler,
  rewriteSassReferences,
  transformCssPreprocessors,
  type TransformCssPreprocessorOptions,
} from './style/sass.ts';
export {
  buildCssModuleProxy,
  collectCssModuleClasses,
  type CssModuleClassToken,
  cssModuleGeneratedCssPath,
  cssModuleLocalName,
  cssModuleProxyPath,
  isCssModuleFile,
  isValidExportName,
  rewriteCssModuleClasses,
  rewriteCssModuleReferences,
  scanCssModuleClassTokens,
  transformCssModules,
  type TransformCssModulesOptions,
} from './style/css-modules.ts';
export {
  type AppCssPipelineResult,
  type AppDevController,
  type AppDevControllerDeps,
  type AppDevControllerOptions,
  cleanupPostcssTempRoot,
  createAppDevController,
  prepareAppCssPipelineRoot,
  type PrepareAppCssPipelineRootOptions,
} from './dev-controller.ts';
// dev-overlay-client 는 .mjs 라 별도 export — 브라우저 inject 용 string.
export { APP_DEV_HMR_CLIENT } from '../runtime/dev-overlay-client.mjs';
