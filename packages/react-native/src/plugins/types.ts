// Plugin factory 들의 공통 config. asset / babel / codegen / require-context /
// metro-resolve-request 모두 RN-specific 환경 인자 동일 set 공유.

/** Inline babel config — Metro `transformer.babel` 호환. */
export interface InlineBabelConfig {
  presets?: (string | [string, Record<string, unknown>])[];
  plugins?: (string | [string, Record<string, unknown>])[];
}

export interface PluginConfig {
  /** RN 프로젝트 root — Babel/codegen plugin resolve 의 base. */
  projectRoot: string;
  /** RN asset 확장자 (`.png` / `.jpg` / `.svg` 등). */
  assetExts: string[];
  /** RN runtime platform — codegen / asset 의 platform 분기. */
  rnPlatform: 'ios' | 'android';
  /** Metro transformer dev flag. 미지정 시 기존 dev-server 기본값인 true. */
  dev?: boolean;
  /** Source 확장자 (`.ts` / `.tsx` / `.js` / `.jsx` / `.svg` 등). */
  sourceExts: string[];
  /** Metro 호환 custom file transformer path (예: react-native-svg-transformer). */
  babelTransformerPath?: string;
  /**
   * Inline babel preset / plugin (zntc.config.ts 의 `transformer.babel`). 사용자
   * babel.config.js 의 plugins 와 concat 되며 양쪽 모두 ZNTC native filter 통과
   * 후 babel pass 에 등록. TS/Flow strip 은 ZNTC native transform 이 처리한다.
   */
  inlineBabel?: InlineBabelConfig;
}
