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
  | "es2023"
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
  /**
   * browserslist 쿼리 (예: "last 2 versions", ">1%, not dead").
   * 지정 시 target보다 우선. core 패키지에서만 해석됨 (browserslist 의존).
   */
  browserslist?: string | string[];
}

export interface TranspileResult {
  /** 변환된 JavaScript 코드 */
  code: string;
  /** 소스맵 JSON (sourcemap: true 시) */
  map?: string;
}

// ─── ES Target → UnsupportedFeatures bitmask ───

// compat.zig UnsupportedFeatures 비트 레이아웃:
//   0-10 = ES2015 features, 11 = ES2016, 12 = ES2017, 13 = ES2018,
//   14 = ES2019, 15-16 = ES2020, 17 = ES2021,
//   18-20 = ES2022 (class_static_block, class_private_method, class_private_field),
//   21 = ES2023 (hashbang), 22 = ES2025 (using).
// 타겟 T에 대해 "T 이후 도입된" 모든 feature 비트를 set한다.
export const ES_TARGET_BITS: Record<string, number> = {
  es5: 0x7fffff, // bit 0-22
  es2015: 0x7ff800, // bit 11-22
  es2016: 0x7ff000, // bit 12-22
  es2017: 0x7fe000, // bit 13-22
  es2018: 0x7fc000, // bit 14-22
  es2019: 0x7f8000, // bit 15-22
  es2020: 0x7e0000, // bit 17-22
  es2021: 0x7c0000, // bit 18-22
  es2022: 0x600000, // bit 21-22 (hashbang + using)
  es2023: 0x400000, // bit 22 (using only)
  es2024: 0x400000, // bit 22 (ES2024에 구문 변환 기능 없음)
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

// ─── browserslist → UnsupportedFeatures ───

export type { Engine, EngineVersion, Feature } from "./compat-engines";
export { computeUnsupportedFromEngines, FEATURES } from "./compat-engines";

import type { Engine, EngineVersion } from "./compat-engines";
import { computeUnsupportedFromEngines } from "./compat-engines";

/** browserslist 결과 문자열 ("chrome 100", "ios_saf 14.5") → EngineVersion. */
export function parseBrowserslistEntry(entry: string): EngineVersion | null {
  // 형식: "<name> <version>" — version은 "100", "14.1", "100-101" 등
  const m = entry.trim().match(/^(\S+)\s+([\d.]+)(?:-[\d.]+)?$/);
  if (!m) return null;
  const name = m[1].toLowerCase();
  const versionStr = m[2];
  const [majStr, minStr = "0"] = versionStr.split(".");
  const major = parseInt(majStr, 10);
  const minor = parseInt(minStr, 10);
  if (Number.isNaN(major)) return null;

  // browserslist 이름 → ZTS Engine 매핑
  // 미매핑 엔진(op_mini, samsung, and_chr 등)은 null 반환 → 호출자가 filter.
  const map: Record<string, Engine> = {
    chrome: "chrome",
    and_chr: "chrome", // Android Chrome
    firefox: "firefox",
    and_ff: "firefox",
    safari: "safari",
    ios_saf: "ios",
    edge: "edge",
    node: "node",
    deno: "deno",
    opera: "opera",
    op_mob: "opera",
    hermes: "hermes",
  };
  const engine = map[name];
  if (!engine) return null;
  return { engine, major, minor };
}

/**
 * browserslist가 반환한 문자열 배열 → unsupported bitmask.
 * 매핑 불가능한 엔진(samsung, kaios 등)은 무시 (ZTS가 타겟팅하지 않는 엔진).
 */
export function browserslistToUnsupported(entries: string[]): number {
  const engines: EngineVersion[] = [];
  for (const e of entries) {
    const parsed = parseBrowserslistEntry(e);
    if (parsed) engines.push(parsed);
  }
  if (engines.length === 0) return 0; // 매핑된 엔진 없음 → 보수적으로 esnext
  return computeUnsupportedFromEngines(engines);
}
