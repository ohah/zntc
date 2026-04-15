/**
 * Engine × Feature 지원 버전 테이블 (JS 미러).
 *
 * src/transformer/compat.zig의 compat_table을 거울 복사.
 * browserslist → UnsupportedFeatures bitmask 계산에 사용.
 *
 * **주의**: compat.zig를 수정하면 이 파일도 함께 업데이트.
 * 장기적으론 scripts/compat-from-kangax.ts를 확장해 자동 생성.
 *
 * Bit 레이아웃은 packages/shared/index.ts ES_TARGET_BITS와 동일 (0-27).
 */

export type Engine =
  | "chrome"
  | "firefox"
  | "safari"
  | "edge"
  | "node"
  | "deno"
  | "ios"
  | "opera"
  | "hermes";

/** compat.zig의 Feature enum과 동일 순서. bit 위치 = 배열 인덱스. */
export const FEATURES = [
  // ES2015 (bit 0-10)
  "arrow",
  "class",
  "template_literal",
  "destructuring",
  "for_of",
  "spread",
  "object_extensions",
  "default_params",
  "block_scoping",
  "generator",
  "new_target",
  // ES2016
  "exponentiation",
  // ES2017
  "async_await",
  // ES2018
  "object_spread",
  // ES2019
  "optional_catch_binding",
  // ES2020
  "nullish_coalescing",
  "optional_chaining",
  // ES2021
  "logical_assignment",
  // ES2022
  "class_static_block",
  "class_private_method",
  "class_private_field",
  "top_level_await",
  // ES2023
  "hashbang",
  // ES2025
  "using",
  // Regex / unicode escape (compat.zig 와 동일 후행 순서. esVersion 은 esbuild 대응)
  "regex_sticky", // ES2015
  "regex_dotall", // ES2018
  "regex_named_groups", // ES2018
  "unicode_brace_escape", // ES2015
] as const;

export type Feature = (typeof FEATURES)[number];

/**
 * feature × engine → 최소 지원 버전 [major, minor].
 * 엔진에 키가 없으면 "해당 엔진에서 미지원" (compat.zig의 보수적 해석).
 */
export const SUPPORT: Partial<Record<Feature, Partial<Record<Engine, [number, number]>>>> = {
  arrow: {
    chrome: [45, 0],
    firefox: [22, 0],
    safari: [10, 0],
    edge: [12, 0],
    node: [4, 0],
    deno: [1, 0],
    ios: [10, 0],
  },
  class: {
    chrome: [49, 0],
    firefox: [45, 0],
    safari: [10, 1],
    edge: [13, 0],
    node: [6, 0],
    deno: [1, 0],
    ios: [10, 3],
  },
  template_literal: {
    chrome: [41, 0],
    firefox: [34, 0],
    safari: [9, 0],
    edge: [12, 0],
    node: [4, 0],
    deno: [1, 0],
    ios: [9, 0],
  },
  destructuring: {
    chrome: [49, 0],
    firefox: [41, 0],
    safari: [8, 0],
    edge: [14, 0],
    node: [6, 0],
    deno: [1, 0],
    ios: [8, 0],
  },
  for_of: {
    chrome: [38, 0],
    firefox: [13, 0],
    safari: [7, 0],
    edge: [12, 0],
    node: [0, 12],
    deno: [1, 0],
    ios: [7, 0],
    hermes: [0, 7],
  },
  spread: {
    chrome: [46, 0],
    firefox: [27, 0],
    safari: [10, 0],
    edge: [13, 0],
    node: [5, 0],
    deno: [1, 0],
    ios: [10, 0],
    hermes: [0, 7],
  },
  object_extensions: {
    chrome: [43, 0],
    firefox: [34, 0],
    safari: [9, 0],
    edge: [12, 0],
    node: [4, 0],
    deno: [1, 0],
    ios: [9, 0],
    hermes: [0, 7],
  },
  default_params: {
    chrome: [49, 0],
    firefox: [15, 0],
    safari: [10, 0],
    edge: [14, 0],
    node: [6, 0],
    deno: [1, 0],
    ios: [10, 0],
  },
  block_scoping: {
    chrome: [49, 0],
    firefox: [51, 0],
    safari: [11, 0],
    edge: [14, 0],
    node: [6, 0],
    deno: [1, 0],
    ios: [11, 0],
  },
  generator: {
    chrome: [50, 0],
    firefox: [53, 0],
    safari: [10, 0],
    edge: [13, 0],
    node: [6, 0],
    deno: [1, 0],
    ios: [10, 0],
  },
  new_target: {
    chrome: [46, 0],
    firefox: [41, 0],
    safari: [10, 0],
    edge: [14, 0],
    node: [5, 0],
    deno: [1, 0],
    ios: [10, 0],
  },
  exponentiation: {
    chrome: [52, 0],
    firefox: [52, 0],
    safari: [10, 1],
    edge: [14, 0],
    node: [7, 0],
    deno: [1, 0],
    ios: [10, 3],
    hermes: [0, 7],
  },
  async_await: {
    chrome: [55, 0],
    firefox: [52, 0],
    safari: [11, 0],
    edge: [15, 0],
    node: [7, 6],
    deno: [1, 0],
    ios: [11, 0],
    // Hermes 미등재: kangax 0.12 데이터에서 core async는 통과하나 async arrow /
    // async class method에서 subtest fail. esbuild의 js_table.go도 동일 판정
    // ("Hermes failed 4 tests including: async arrow functions") — 보수적으로 제외.
  },
  object_spread: {
    chrome: [60, 0],
    firefox: [55, 0],
    safari: [11, 1],
    edge: [79, 0],
    node: [8, 3],
    deno: [1, 0],
    ios: [11, 3],
    hermes: [0, 7],
  },
  optional_catch_binding: {
    chrome: [66, 0],
    firefox: [58, 0],
    safari: [11, 1],
    edge: [79, 0],
    node: [10, 0],
    deno: [1, 0],
    ios: [11, 3],
    hermes: [0, 12],
  },
  nullish_coalescing: {
    chrome: [80, 0],
    firefox: [72, 0],
    safari: [13, 1],
    edge: [80, 0],
    node: [14, 0],
    deno: [1, 0],
    ios: [13, 4],
    hermes: [0, 7],
  },
  optional_chaining: {
    chrome: [91, 0],
    firefox: [74, 0],
    safari: [13, 1],
    edge: [91, 0],
    node: [16, 9],
    deno: [1, 9],
    ios: [13, 4],
    hermes: [0, 12],
  },
  logical_assignment: {
    chrome: [85, 0],
    firefox: [79, 0],
    safari: [14, 0],
    edge: [85, 0],
    node: [15, 0],
    deno: [1, 2],
    ios: [14, 0],
    hermes: [0, 7],
  },
  class_static_block: {
    chrome: [94, 0],
    firefox: [93, 0],
    safari: [16, 4],
    edge: [94, 0],
    node: [16, 11],
    deno: [1, 14],
    ios: [16, 4],
  },
  class_private_method: {
    chrome: [84, 0],
    firefox: [90, 0],
    safari: [15, 0],
    edge: [84, 0],
    node: [14, 6],
    deno: [1, 0],
    ios: [15, 0],
  },
  class_private_field: {
    chrome: [74, 0],
    firefox: [90, 0],
    safari: [14, 1],
    edge: [79, 0],
    node: [12, 0],
    deno: [1, 0],
    ios: [14, 5],
  },
  hashbang: {
    chrome: [74, 0],
    firefox: [67, 0],
    safari: [13, 1],
    edge: [79, 0],
    node: [12, 0],
    deno: [1, 0],
    ios: [13, 4],
    hermes: [0, 7],
  },
  using: {
    // ES2025 `using` / `await using` 선언. 2026-04 기준 어떤 엔진도 미지원이라
    // SUPPORT 테이블은 비어있고, computeUnsupported는 모든 엔진에서 비트를 set.
    // 엔진 지원이 시작되면 여기에 추가.
  },
};

/** a >= b (major, minor 순). */
function verGte(a: [number, number], b: [number, number]): boolean {
  if (a[0] !== b[0]) return a[0] > b[0];
  return a[1] >= b[1];
}

/** 특정 engine 버전에서 feature가 지원되는지. */
function isSupported(feature: Feature, engine: Engine, ver: [number, number]): boolean {
  const min = SUPPORT[feature]?.[engine];
  if (!min) return false;
  return verGte(ver, min);
}

export type EngineVersion = { engine: Engine; major: number; minor: number };

/**
 * 엔진 목록에 대해 unsupported feature bitmask 계산.
 * 하나라도 미지원인 feature는 set (가장 보수적).
 */
export function computeUnsupportedFromEngines(engines: EngineVersion[]): number {
  let bits = 0;
  for (let i = 0; i < FEATURES.length; i++) {
    const feature = FEATURES[i];
    let anyUnsupported = false;
    for (const ev of engines) {
      if (!isSupported(feature, ev.engine, [ev.major, ev.minor])) {
        anyUnsupported = true;
        break;
      }
    }
    if (anyUnsupported) bits |= 1 << i;
  }
  return bits;
}
