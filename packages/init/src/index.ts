export {
  PACKAGE_MANAGERS,
  detectPackageManager,
  type FileAction,
  type FileChange,
  type PackageManager,
  type PlannedFile,
} from './shared.ts';

export {
  DEFAULT_RN_ENTRY,
  DEFAULT_RN_PLATFORM,
  createReactNativeConfig,
  initReactNativeProject,
  planReactNativeInit,
  type InitReactNativeOptions,
  type InitReactNativeResult,
  type ReactNativePlatform,
} from './react-native.ts';

export {
  createViteConfig,
  initViteProject,
  planViteInit,
  type InitViteOptions,
  type InitViteResult,
} from './vite.ts';

export {
  createRspackConfig,
  initRspackProject,
  planRspackInit,
  type InitRspackOptions,
  type InitRspackResult,
  type RspackBundler,
} from './rspack.ts';

export {
  WEB_FRAMEWORKS,
  initWebProject,
  planWebInit,
  type InitWebOptions,
  type InitWebResult,
  type WebFramework,
} from './web.ts';
