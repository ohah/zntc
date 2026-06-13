/**
 * @zntc/shared — Types and utilities shared by @zntc/core and @zntc/wasm.
 */

// ─── Types ───

export type Target =
  | 'es5'
  | 'es2015'
  | 'es2016'
  | 'es2017'
  | 'es2018'
  | 'es2019'
  | 'es2020'
  | 'es2021'
  | 'es2022'
  | 'es2023'
  | 'es2024'
  | 'es2025'
  | 'esnext';

export type Platform = 'browser' | 'node' | 'neutral' | 'react-native';

export interface TranspileOptions {
  /** File path (used for extension detection, default: "input.ts"). */
  filename?: string;
  /** Generate a source map. */
  sourcemap?: boolean;
  /** Source map Debug ID (Sentry-compatible). */
  sourcemapDebugIds?: boolean;
  /** Include the original source in the source map (default: true). */
  sourcesContent?: boolean;
  /** Minify whitespace. */
  minifyWhitespace?: boolean;
  /** Minify identifiers. */
  minifyIdentifiers?: boolean;
  /** Minify syntax. */
  minifySyntax?: boolean;
  /** Full minification (whitespace + identifiers + syntax). */
  minify?: boolean;
  /** JSX runtime. `'preserve'` emits JSX unchanged — only TypeScript annotations
   * are stripped. Use this to delegate JSX handling to a downstream tool (e.g.
   * @vitejs/plugin-react, @preact/preset-vite, vite-plugin-solid). Equivalent to
   * tsc `"jsx": "preserve"`. */
  jsx?: 'classic' | 'automatic' | 'automatic-dev' | 'preserve';
  /** classic-mode JSX factory (default: "React.createElement"). */
  jsxFactory?: string;
  /** classic-mode Fragment factory (default: "React.Fragment"). */
  jsxFragment?: string;
  /** automatic-mode import source (default: "react"). */
  jsxImportSource?: string;
  /** Allow JSX in .js files as well. */
  jsxInJs?: boolean;
  /**
   * React Fast Refresh transform — registers components via
   * `$RefreshReg$(_c, "Name")`. Equivalent to the SWC builtin
   * `jsc.transform.react.refresh: true` / babel-plugin-react-refresh component
   * registration. Used by loaders (rspack-loader, webpack/vite plugin) when
   * enabled on the single-file transpile path.
   *
   * The default behavior is Metro-compatible (registration only, no hook
   * signatures). The babel/SWC-equivalent hook signature emit is opt-in via
   * `reactRefreshHookSignatures: true`. Defining the HMR runtime
   * ($RefreshReg$/$RefreshSig$) is the consumer's responsibility.
   */
  reactRefresh?: boolean;
  /**
   * On top of `reactRefresh: true`, adds hook signature emit
   * (`var _s = $RefreshSig$();` + `_s(Component, "sig")`). Equivalent to
   * babel-plugin-react-refresh. Default false — preserves the Metro policy
   * (no signatures).
   *
   * When enabled, the transformer scans hook calls inside function bodies to
   * build the signature string, then emits a `_s(Comp, "sig")` call right after
   * component registration. RN HMR keeps the default (false), so it is
   * unaffected.
   */
  reactRefreshHookSignatures?: boolean;
  /** Remove console.* calls. */
  dropConsole?: boolean;
  /** Remove debugger statements. */
  dropDebugger?: boolean;
  /** Escape non-ASCII to \uXXXX. */
  asciiOnly?: boolean;
  /** Do not escape non-ASCII. */
  charsetUtf8?: boolean;
  /** Strip Flow types. */
  flow?: boolean;
  /** legacy decorator transform. */
  experimentalDecorators?: boolean;
  /** decorator metadata emit */
  emitDecoratorMetadata?: boolean;
  /** Transform class fields → `constructor` this.x = v (default: true). */
  useDefineForClassFields?: boolean;
  /** verbatimModuleSyntax (TS 5.0+): when true, unused value imports are not elided. */
  verbatimModuleSyntax?: boolean;
  /**
   * Path to tsconfig.json (file or directory). When set, compilerOptions are
   * auto-loaded and merged. Fields set explicitly via JS options take
   * precedence — only unspecified fields are filled from the tsconfig values.
   * e.g. "./tsconfig.json" or "./project-dir".
   */
  tsconfigPath?: string;
  /**
   * Inline tsconfig JSON string (same meaning as esbuild's `tsconfigRaw`).
   * When set, both `tsconfigPath` and autodiscovery are ignored — raw is the
   * single source of truth. The Zig-side `tsconfig_merge` applies
   * compilerOptions such as jsx/target/decorators directly.
   */
  tsconfigRaw?: string;
  /** Module format. */
  format?: 'esm' | 'cjs';
  /** String quote style. */
  quotes?: 'double' | 'single' | 'preserve';
  /** Target platform. */
  platform?: Platform;
  /** ES downlevel target. */
  target?: Target;
  /**
   * browserslist query (e.g. "last 2 versions", ">1%, not dead").
   * Takes precedence over target when set. Resolved only in the core package
   * (depends on browserslist).
   */
  browserslist?: string | string[];
  /** The source map's sourceRoot field (default: empty string). */
  sourceRoot?: string;
  /**
   * Identifier substitution pairs. `value` is raw JSON (strings must include
   * the surrounding quotes).
   * e.g. `[{ key: "process.env.NODE_ENV", value: "\"production\"" }]`
   */
  define?: Array<{ key: string; value: string }>;
  /**
   * Pipeline early-exit point — for debug/profile. When set, all stages after
   * the given phase are skipped and empty output is returned. Useful combined
   * with `profile` to measure a specific phase's cost in isolation.
   *
   * - "scan": Scanner token drain only
   * - "parse": after Parser AST construction
   * - "semantic": after the Semantic analyzer
   * - "transform": after the Transformer
   * - "codegen": full run (same as the default behavior)
   */
  stopAfter?: 'scan' | 'parse' | 'semantic' | 'transform' | 'codegen';
}

export interface TranspileResult {
  /** Transformed JavaScript code. */
  code: string;
  /** Source map JSON (when sourcemap: true). */
  map?: string;
  /**
   * Full error text rendered in the same format as the CLI when semantic
   * errors are present. tsc-compatible policy: code is still returned even
   * when there are errors. Playgrounds/IDEs parse this field to display
   * markers.
   */
  errors?: string;
}

// ─── ES Target → UnsupportedFeatures bitmask ───

// compat.zig Feature enum 순서와 1:1 대응 (총 29 bits, src/transformer/compat.zig 참조):
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
//   28    ES2025 (regex_duplicate_named_groups)
//   29    ES2025 (regex_modifiers)
//
// 타겟 T 에 대해 "T 이후 도입된" 모든 feature 비트를 set 한다.
// Feature 추가 시 compat.zig 와 함께 갱신.
export const ES_TARGET_BITS: Record<string, number> = {
  es5: 0x3fffffff, // bits 0-29 (모든 feature)
  es2015: 0x36fff800, // bits 11-23, 25, 26, 28, 29 (ES2015/regex_sticky/unicode_brace_escape 제외)
  es2016: 0x36fff000, // bits 12-23, 25, 26, 28, 29
  es2017: 0x36ffe000, // bits 13-23, 25, 26, 28, 29
  es2018: 0x30ffc000, // bits 14-23, 28, 29 (ES2018 features 도 제외)
  es2019: 0x30ff8000, // bits 15-23, 28, 29
  es2020: 0x30fe0000, // bits 17-23, 28, 29
  es2021: 0x30fc0000, // bits 18-23, 28, 29
  es2022: 0x30c00000, // bits 22-23, 28, 29 (hashbang + using + regex dup-named + modifiers)
  es2023: 0x30800000, // bits 23, 28, 29
  es2024: 0x30800000, // bits 23, 28, 29 (ES2024 자체 구문 변환 기능 없음)
  es2025: 0x0,
  esnext: 0x0,
};

export function targetToUnsupported(target?: Target): number {
  if (!target) return 0;
  return ES_TARGET_BITS[target] ?? 0;
}

/**
 * Narrows whether `value` is a plain object (non-null, not an array).
 * Use this to narrow a value of unknown shape — such as a `JSON.parse` result
 * or a dynamic config object — to `Record<string, unknown>`. Shared across
 * functional config / workspace entries / tsconfigRaw validation, etc.
 */
export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * Pre-validates user-supplied `tsconfigRaw` input.
 *
 * NAPI (`napi_entry.zig` / `transpile.zig`) silently falls back to an empty
 * TsConfig on raw parse failure, so an invalid raw passed through looks to the
 * user as if the option were ignored. Called from both the CLI and JS API
 * entry points so they uniformly throw the same explicit error
 * (`failed to parse --tsconfig-raw: ...`). No-op when undefined.
 */
export function validateTsConfigRaw(raw: string | undefined): void {
  if (raw === undefined) return;
  let config: unknown;
  try {
    config = JSON.parse(raw);
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    throw new Error(`failed to parse --tsconfig-raw: ${reason}`);
  }
  if (!isPlainObject(config)) {
    throw new Error('failed to parse --tsconfig-raw: expected a JSON object');
  }
}

// ─── JSON payload 구성 (Zig optionsFromJson과 1:1 매핑) ───

/**
 * Serializes TranspileOptions into Zig `ConfigOptionsDto` JSON.
 *
 * - Default values are omitted (minimizes payload size).
 * - enum keys match the Zig enum name (e.g. "react-native" → "react_native").
 * - The browserslist resolution result can be injected as the
 *   `unsupportedOverride` number. When set, it takes precedence over the
 *   `target`-based fallback on the Zig side.
 * - `define` is serialized as a `[{ key, value }]` array (compatible with Zig
 *   DefineEntry).
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
  if (opts.reactRefresh) payload.reactRefresh = true;
  if (opts.reactRefreshHookSignatures) payload.reactRefreshHookSignatures = true;
  if (opts.jsx !== undefined) {
    // CLI vocab → Zig enum tag (kebab-case → snake_case): automatic-dev → automatic_dev.
    // 그 외 (`react-jsx` 등 tsconfig vocab, typo) 도 그대로 forward — NAPI / `optionsFromJson`
    // 이 strict 검증해 invalid 면 throw (silent drop 방지).
    payload.jsx = opts.jsx === 'automatic-dev' ? 'automatic_dev' : opts.jsx;
  }
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
  if (opts.tsconfigRaw) payload.tsconfigRaw = opts.tsconfigRaw;
  if (opts.format) payload.format = opts.format;
  if (opts.quotes) payload.quotes = opts.quotes;
  if (opts.platform === 'react-native') payload.platform = 'react_native';
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

export type { Engine, EngineVersion, Feature } from './compat-engines';
export { computeUnsupportedFromEngines, FEATURES } from './compat-engines';

import type { Engine, EngineVersion } from './compat-engines';
import { computeUnsupportedFromEngines } from './compat-engines';

/** browserslist result string ("chrome 100", "ios_saf 14.5") → EngineVersion. */
export function parseBrowserslistEntry(entry: string): EngineVersion | null {
  // 형식: "<name> <version>" — version은 "100", "14.1", "100-101" 등
  const m = entry.trim().match(/^(\S+)\s+([\d.]+)(?:-[\d.]+)?$/);
  if (!m) return null;
  const name = m[1].toLowerCase();
  const versionStr = m[2];
  const [majStr, minStr = '0'] = versionStr.split('.');
  const major = parseInt(majStr, 10);
  const minor = parseInt(minStr, 10);
  if (Number.isNaN(major)) return null;

  // browserslist 이름 → ZNTC Engine 매핑
  // 미매핑 엔진(op_mini, samsung, and_chr 등)은 null 반환 → 호출자가 filter.
  const map: Record<string, Engine> = {
    chrome: 'chrome',
    and_chr: 'chrome', // Android Chrome
    firefox: 'firefox',
    and_ff: 'firefox',
    safari: 'safari',
    ios_saf: 'ios',
    edge: 'edge',
    node: 'node',
    deno: 'deno',
    opera: 'opera',
    op_mob: 'opera',
    hermes: 'hermes',
  };
  const engine = map[name];
  if (!engine) return null;
  return { engine, major, minor };
}

/**
 * browserslist result string array → unsupported bitmask.
 * Unmappable engines (samsung, kaios, etc.) are ignored (engines ZNTC does not
 * target).
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
