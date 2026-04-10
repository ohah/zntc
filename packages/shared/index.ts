/**
 * @zts/shared — @zts/core와 @zts/wasm에서 공유하는 타입 및 유틸리티
 */

// ─── Types ───

export type Target =
  | "es5"
  | "es2015"
  | "es2016"
  | "es2017"
  | "es2018"
  | "es2019"
  | "es2020"
  | "es2021"
  | "es2022"
  | "es2024"
  | "es2025"
  | "esnext";

export type Platform = "browser" | "node" | "neutral" | "react-native";

export interface TranspileOptions {
  /** 파일 경로 (확장자 감지용, 기본: "input.ts") */
  filename?: string;
  /** 소스맵 생성 */
  sourcemap?: boolean;
  /** 소스맵 Debug ID (Sentry 호환) */
  sourcemapDebugIds?: boolean;
  /** 소스맵에 원본 소스 포함 (기본: true) */
  sourcesContent?: boolean;
  /** 공백 축소 */
  minifyWhitespace?: boolean;
  /** 식별자 축소 */
  minifyIdentifiers?: boolean;
  /** 구문 축소 */
  minifySyntax?: boolean;
  /** 전체 축소 (whitespace + identifiers + syntax) */
  minify?: boolean;
  /** JSX 런타임 */
  jsx?: "classic" | "automatic" | "automatic-dev";
  /** classic 모드 JSX factory (기본: "React.createElement") */
  jsxFactory?: string;
  /** classic 모드 Fragment factory (기본: "React.Fragment") */
  jsxFragment?: string;
  /** automatic 모드 import source (기본: "react") */
  jsxImportSource?: string;
  /** JS 파일에서도 JSX 허용 */
  jsxInJs?: boolean;
  /** console.* 호출 제거 */
  dropConsole?: boolean;
  /** debugger 문 제거 */
  dropDebugger?: boolean;
  /** non-ASCII를 \uXXXX로 이스케이프 */
  asciiOnly?: boolean;
  /** non-ASCII를 이스케이프하지 않음 */
  charsetUtf8?: boolean;
  /** Flow 타입 스트리핑 */
  flow?: boolean;
  /** legacy decorator 변환 */
  experimentalDecorators?: boolean;
  /** decorator metadata emit */
  emitDecoratorMetadata?: boolean;
  /** class field → constructor this.x = v 변환 (기본: true) */
  useDefineForClassFields?: boolean;
  /** 모듈 포맷 */
  format?: "esm" | "cjs";
  /** 문자열 따옴표 스타일 */
  quotes?: "double" | "single" | "preserve";
  /** 타겟 플랫폼 */
  platform?: Platform;
  /** ES 다운레벨 타겟 */
  target?: Target;
}

export interface TranspileResult {
  /** 변환된 JavaScript 코드 */
  code: string;
  /** 소스맵 JSON (sourcemap: true 시) */
  map?: string;
}

// ─── ES Target → UnsupportedFeatures bitmask ───

export const ES_TARGET_BITS: Record<string, number> = {
  es5: 0x1fffff,
  es2015: 0x1ff800,
  es2016: 0x1ff000,
  es2017: 0x1fe000,
  es2018: 0x1fc000,
  es2019: 0x1f8000,
  es2020: 0x1e0000,
  es2021: 0x1c0000,
  es2022: 0x100000,
  es2024: 0x100000,
  es2025: 0x0,
  esnext: 0x0,
};

// ─── 옵션 인코딩 (Zig decodeFlags와 동일한 비트 레이아웃) ───

export function encodeFlags(opts: TranspileOptions = {}): number {
  let flags = 0;
  if (opts.sourcemap) flags |= 1 << 0;
  if (opts.minifyWhitespace || opts.minify) flags |= 1 << 1;
  if (opts.minifyIdentifiers || opts.minify) flags |= 1 << 2;
  if (opts.minifySyntax || opts.minify) flags |= 1 << 3;
  if (opts.jsx === "automatic") flags |= 1 << 4;
  if (opts.jsx === "automatic-dev") flags |= 1 << 5;
  if (opts.dropConsole) flags |= 1 << 6;
  if (opts.dropDebugger) flags |= 1 << 7;
  if (opts.asciiOnly) flags |= 1 << 8;
  if (opts.flow) flags |= 1 << 9;
  if (opts.experimentalDecorators) flags |= 1 << 10;
  if (opts.emitDecoratorMetadata) flags |= 1 << 11;
  if (opts.format === "cjs") flags |= 1 << 12;
  if (opts.quotes === "single") flags |= 1 << 14;
  if (opts.quotes === "preserve") flags |= 2 << 14;
  if (opts.useDefineForClassFields !== false) flags |= 1 << 16;
  if (opts.charsetUtf8) flags |= 1 << 17;
  if (opts.platform === "node") flags |= 1 << 18;
  if (opts.platform === "neutral") flags |= 2 << 18;
  if (opts.platform === "react-native") flags |= 3 << 18;
  if (opts.jsxInJs) flags |= 1 << 20;
  if (opts.sourcemapDebugIds) flags |= 1 << 21;
  if (opts.sourcesContent !== false) flags |= 1 << 22;
  return flags;
}

export function targetToUnsupported(target?: Target): number {
  if (!target) return 0;
  return ES_TARGET_BITS[target] ?? 0;
}
