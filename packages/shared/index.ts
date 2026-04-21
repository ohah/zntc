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
  /** verbatimModuleSyntax (TS 5.0+): true면 미사용 값 import를 elide하지 않음 */
  verbatimModuleSyntax?: boolean;
  /**
   * tsconfig.json 경로 (파일 또는 디렉토리). 설정 시 compilerOptions를 자동 로드해서 머지한다.
   * JS 옵션이 명시적으로 설정된 필드가 우선 — 미지정 필드만 tsconfig 값으로 채워진다.
   * 예) "./tsconfig.json" 또는 "./project-dir"
   */
  tsconfigPath?: string;
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
  /** 소스맵의 sourceRoot 필드 (기본: 빈 문자열) */
  sourceRoot?: string;
  /**
   * 식별자 치환 쌍. `value`는 raw JSON (문자열은 반드시 따옴표 포함).
   * 예: `[{ key: "process.env.NODE_ENV", value: "\"production\"" }]`
   */
  define?: Array<{ key: string; value: string }>;
  /**
   * 파이프라인 조기 종료 지점 — debug/profile 용. 지정 시 해당 phase 이후 단계는 skip 하고
   * 빈 output 을 반환. `profile` 과 조합해 특정 phase 비용을 격리 측정할 때 유용.
   *
   * - "scan": Scanner 토큰 drain 만
   * - "parse": Parser AST 생성 후
   * - "semantic": Semantic analyzer 후
   * - "transform": Transformer 후
   * - "codegen": 전체 실행 (기본 동작과 동일)
   */
  stopAfter?: "scan" | "parse" | "semantic" | "transform" | "codegen";
}

export interface TranspileResult {
  /** 변환된 JavaScript 코드 */
  code: string;
  /** 소스맵 JSON (sourcemap: true 시) */
  map?: string;
  /**
   * 시맨틱 에러가 있을 때 CLI와 동일한 포맷으로 렌더된 전체 에러 텍스트.
   * tsc 호환 정책: 에러가 있어도 code는 함께 반환된다.
   * 플레이그라운드/IDE는 이 필드를 파싱해 마커로 표시한다.
   */
  errors?: string;
}

// ─── ES Target → UnsupportedFeatures bitmask ───

// compat.zig Feature enum 순서와 1:1 대응 (총 28 bits, src/transformer/compat.zig 참조):
//   0-10  ES2015 (arrow, class, template_literal, destructuring, for_of, spread,
//                  object_extensions, default_params, block_scoping, generator, new_target)
//   11    ES2016 (exponentiation)
//   12    ES2017 (async_await)
//   13    ES2018 (object_spread)
//   14    ES2019 (optional_catch_binding)
//   15-16 ES2020 (nullish_coalescing, optional_chaining)
//   17    ES2021 (logical_assignment)
//   18-21 ES2022 (class_static_block, class_private_method, class_private_field, top_level_await)
//   22    ES2023 (hashbang)
//   23    ES2025 (using)
//   24    ES2015 (regex_sticky)
//   25-26 ES2018 (regex_dotall, regex_named_groups)
//   27    ES2015 (unicode_brace_escape)
//
// 타겟 T 에 대해 "T 이후 도입된" 모든 feature 비트를 set 한다.
// Feature 추가 시 compat.zig 와 함께 갱신.
export const ES_TARGET_BITS: Record<string, number> = {
  es5: 0x0fffffff, // bits 0-27 (모든 feature)
  es2015: 0x06fff800, // bits 11-23, 25, 26 (ES2015/regex_sticky/unicode_brace_escape 제외)
  es2016: 0x06fff000, // bits 12-23, 25, 26
  es2017: 0x06ffe000, // bits 13-23, 25, 26
  es2018: 0x00ffc000, // bits 14-23 (ES2018 features 도 제외)
  es2019: 0x00ff8000, // bits 15-23
  es2020: 0x00fe0000, // bits 17-23
  es2021: 0x00fc0000, // bits 18-23
  es2022: 0x00c00000, // bits 22-23 (hashbang + using)
  es2023: 0x00800000, // bit 23 (using only)
  es2024: 0x00800000, // ES2024 에 구문 변환 기능 없음
  es2025: 0x0,
  esnext: 0x0,
};

export function targetToUnsupported(target?: Target): number {
  if (!target) return 0;
  return ES_TARGET_BITS[target] ?? 0;
}

// ─── JSON payload 구성 (Zig optionsFromJson과 1:1 매핑) ───

/**
 * TranspileOptions를 Zig `TranspileOptionsDto` JSON으로 직렬화한다.
 *
 * - 기본값은 생략 (payload 크기 최소화)
 * - enum 키는 Zig enum name과 일치 (예: "react-native" → "react_native")
 * - browserslist 해석 결과는 `unsupportedOverride` 숫자로 주입 가능.
 *   지정 시 Zig에서 `target` 기반 fallback보다 우선.
 * - `define`은 `[{ key, value }]` 배열로 직렬화 (Zig DefineEntry와 호환).
 */
export function buildOptionsJson(
  opts: TranspileOptions = {},
  unsupportedOverride?: number,
): string {
  const payload: Record<string, unknown> = {};
  if (opts.target) payload.target = opts.target;
  if (unsupportedOverride !== undefined && unsupportedOverride !== 0)
    payload.unsupported = unsupportedOverride;
  if (opts.flow) payload.flow = true;
  if (opts.jsxInJs) payload.jsxInJs = true;
  if (opts.jsx === "automatic") payload.jsx = "automatic";
  else if (opts.jsx === "automatic-dev") payload.jsx = "automatic_dev";
  else if (opts.jsx === "classic") payload.jsx = "classic";
  if (opts.jsxFactory) payload.jsxFactory = opts.jsxFactory;
  if (opts.jsxFragment) payload.jsxFragment = opts.jsxFragment;
  if (opts.jsxImportSource) payload.jsxImportSource = opts.jsxImportSource;
  if (opts.dropConsole) payload.dropConsole = true;
  if (opts.dropDebugger) payload.dropDebugger = true;
  if (opts.asciiOnly) payload.asciiOnly = true;
  if (opts.charsetUtf8) payload.charsetUtf8 = true;
  if (opts.experimentalDecorators) payload.experimentalDecorators = true;
  if (opts.emitDecoratorMetadata) payload.emitDecoratorMetadata = true;
  if (opts.useDefineForClassFields === false) payload.useDefineForClassFields = false;
  // tsconfig 머지가 있는 필드들은 "JS 가 명시적으로 false" 와 "JS 미설정" 을 구분해야
  // JS > tsconfig 우선순위가 정확히 적용된다. `!== undefined` 체크로 양쪽 값을 모두 전달.
  if (opts.verbatimModuleSyntax !== undefined)
    payload.verbatimModuleSyntax = opts.verbatimModuleSyntax;
  if (opts.tsconfigPath) payload.tsconfigPath = opts.tsconfigPath;
  if (opts.format) payload.format = opts.format;
  if (opts.quotes) payload.quotes = opts.quotes;
  if (opts.platform === "react-native") payload.platform = "react_native";
  else if (opts.platform) payload.platform = opts.platform;
  if (opts.minifyWhitespace || opts.minify) payload.minifyWhitespace = true;
  if (opts.minifyIdentifiers || opts.minify) payload.minifyIdentifiers = true;
  if (opts.minifySyntax || opts.minify) payload.minifySyntax = true;
  if (opts.sourcemap) payload.sourcemap = true;
  if (opts.sourcemapDebugIds) payload.sourcemapDebugIds = true;
  // sourcesContent Zig 기본 true — false일 때만 명시 전달
  if (opts.sourcesContent === false) payload.sourcesContent = false;
  if (opts.sourceRoot) payload.sourceRoot = opts.sourceRoot;
  if (opts.define && opts.define.length > 0) payload.define = opts.define;
  if (opts.stopAfter) payload.stopAfter = opts.stopAfter;
  return JSON.stringify(payload);
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
