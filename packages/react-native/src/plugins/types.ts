// Plugin factory 들의 공통 config. asset / babel / codegen / require-context /
// metro-resolve-request 모두 RN-specific 환경 인자 동일 set 공유.

export interface PluginConfig {
  /** RN 프로젝트 root — Babel/codegen plugin resolve 의 base. */
  projectRoot: string;
  /** RN asset 확장자 (`.png` / `.jpg` / `.svg` 등). */
  assetExts: string[];
  /** RN runtime platform — codegen / asset 의 platform 분기. */
  rnPlatform: "ios" | "android";
  /** Source 확장자 (`.ts` / `.tsx` / `.js` / `.jsx` / `.svg` 등). */
  sourceExts: string[];
  /** Metro 호환 custom file transformer path (예: react-native-svg-transformer). */
  babelTransformerPath?: string;
}
