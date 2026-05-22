/**
 * @zntc/core — Native NAPI bindings for the ZNTC TypeScript transpiler.
 *
 * A NAPI native module that supports Node.js, Bun, and Deno.
 * Returns results directly on the JS heap with no global state.
 *
 * @example
 * ```ts
 * import { transpile } from "@zntc/core";
 * const result = transpile("const x: number = 1;", { filename: "input.ts" });
 * console.log(result.code);
 * ```
 */

import { createRequire } from 'module';
import { existsSync, mkdirSync, writeFileSync } from 'fs';
import { join, dirname, resolve } from 'path';
import { fileURLToPath } from 'url';
import { PLATFORMS, formatSupportedPlatforms, subPackageName } from './src/platforms.ts';

export type { Target, Platform, TranspileOptions, TranspileResult } from '../shared/index';
import type { TranspileOptions, TranspileResult } from '../shared/index';
import {
  buildOptionsJson,
  ES_TARGET_BITS,
  browserslistToUnsupported,
  isPlainObject,
  validateTsConfigRaw,
} from '../shared/index';
import {
  applyRuntimePolyfillsToNapiOptions,
  isEsTarget,
  type RuntimePolyfillOptions,
  type RuntimePolyfillsOption,
} from './src/runtime-polyfills.ts';

export { isPlainObject, validateTsConfigRaw };
export type { RuntimePolyfillOptions, RuntimePolyfillsOption };

// ─── NAPI Module ───

interface OutputFile {
  path: string;
  /** Raw byte content. Exposed by NAPI via `napi_create_buffer_copy` — avoids
   * the string copy + UTF-8 validation cost (safe for binary asset / CSS bundle
   * / source map alike). Equivalent to esbuild OutputFile.contents. */
  contents: Uint8Array;
  /** Lazy UTF-8 decode of `contents`. Decoded once on first access and cached.
   * Equivalent to esbuild OutputFile.text. */
  readonly text: string;
  /** When code splitting, the absolute paths of the modules in this chunk
   * (compatible with rolldown `chunk.moduleIds`). Empty array for a single
   * bundle / asset output. */
  moduleIds?: string[];
  /** The list of symbol names this chunk exports (for cross-chunk validation). */
  exports?: string[];
  /** The final filenames of the other chunks this chunk imports (compatible
   * with rolldown `chunk.imports`). Paths are resolved down to the
   * content-hash. */
  imports?: string[];
}

/** stateless. `attachTextGetter` 의 cache miss 마다 새 인스턴스를 만들지 않도록 module-level singleton. */
const UTF8_DECODER = new TextDecoder('utf-8');

/** NAPI 가 만든 raw OutputFile (`{path, contents}`) 에 lazy `text` getter 를 부착.
 * `text` 는 첫 access 시 `TextDecoder` 로 디코드한 후 캐시 — 대부분의 binary asset
 * (CSS bundle / worker chunk) 은 `text` 가 호출되지 않아 비용 0. `file.contents` 가
 * 후처리에서 reassign (예: `postProcessCssOutputs` 의 minify) 되면 reference 비교로
 * 자동 invalidate.
 *
 * `enumerable: false` — `for..in` / `Object.keys` / `JSON.stringify` 에서 text 를
 * 빼서 contents (Uint8Array → `{0:..,1:..}` 직렬화) 와의 페이로드 중복을 막는다.
 * (esbuild `OutputFile.text` 도 prototype getter 라 enumerable 아님.) */
function attachTextGetter(file: { path: string; contents: Uint8Array }): OutputFile {
  let cachedContents: Uint8Array | undefined;
  let cachedText: string | undefined;
  Object.defineProperty(file, 'text', {
    get(): string {
      if (cachedContents !== file.contents) {
        cachedContents = file.contents;
        cachedText = UTF8_DECODER.decode(cachedContents);
      }
      return cachedText!;
    },
    enumerable: false,
    configurable: true,
  });
  return file as OutputFile;
}

/** NAPI 가 반환한 raw build 결과의 모든 OutputFile 에 `text` getter 를 부착. build /
 * buildSync / buildAppSync 가 공유하는 단일 진입점 — 새 NAPI 진입점 추가 시 drift 방지. */
function wrapOutputFiles<T extends { outputFiles: Array<{ path: string; contents: Uint8Array }> }>(
  result: T,
): T {
  for (const file of result.outputFiles) attachTextGetter(file);
  return result;
}

interface Diagnostic {
  text: string;
  code?: string;
  location?: { file: string; line?: number; column?: number };
}

/**
 * RN AssetRegistry.registerAsset metadata — only exposes the fields actually
 * read by the `rn-asset-copy` release copy path. width/height/hash are passed
 * directly to the RN runtime via the in-bundle `registerAsset({...})` call, so
 * they are not duplicated on this side channel.
 */
export interface RnAssetMetadata {
  httpServerLocation: string;
  fileSystemLocation: string;
  name: string;
  type: string;
  scales: number[];
}

interface NativeBuildResult {
  outputFiles: OutputFile[];
  errors: Diagnostic[];
  warnings: Diagnostic[];
  metafile?: string;
  moduleCodes?: Array<{ id: string; code: string }>;
  modulePaths?: string[];
  rnAssetMetadata?: RnAssetMetadata[];
}

interface NativeWatchHandle {
  stop(): void;
  /**
   * 최신 rebuild 의 번들 전체 sourcemap JSON 을 lazy 생성해 반환 (Issue #1727 Phase B).
   * sourcemap 비활성이거나 초기 빌드 전/stop 이후에는 null.
   * dev server 가 `/bundle.js.map` 요청을 받을 때 호출.
   */
  getBundleSourceMap(): string | null;
  /**
   * 최신 rebuild 의 모듈별 sourcemap JSON 을 lazy 생성해 반환.
   * `moduleId` 가 이번 rebuild 에 포함되지 않았으면 null.
   * dev server 가 `/hmr-map/:moduleId` 요청을 받을 때 호출.
   */
  getHmrSourceMap(moduleId: string): string | null;
}

interface NativeTsconfigCacheHandle {
  clear(): void;
  size(): number;
}

export interface TokenizeToken {
  kind: string;
  text: string;
  start: number;
  end: number;
  line: number;
  column: number;
  hasNewlineBefore: boolean;
}

export interface TokenizeOptions {
  filename?: string;
}

interface NativeModule {
  transpile(
    source: string,
    filename: string,
    optionsJson: string,
    cache?: NativeTsconfigCacheHandle,
  ): { code: string; map?: string; errors?: string };
  tokenize(source: string, filename: string): TokenizeToken[];
  configureProfile(
    profile: string[],
    level?: 'summary' | 'detailed' | 'per-module' | 'per-pass',
  ): void;
  profileReport(format?: 'table' | 'tree' | 'json' | 'csv'): string;
  createTsconfigCache(): NativeTsconfigCacheHandle;
  buildSync(options: Record<string, unknown>): NativeBuildResult;
  buildAppSync(options: Record<string, unknown>): NativeBuildResult & { outputCount?: number };
  prepareAppDevSync(options: Record<string, unknown>): { entryPath: string; outputCount?: number };
  build(options: Record<string, unknown>): Promise<NativeBuildResult>;
  watch(options: Record<string, unknown>): NativeWatchHandle;
  benchmark(options: Record<string, unknown>): {
    phases: Record<
      string,
      {
        samples: number;
        mean_ms: number;
        median_ms: number;
        p95_ms: number;
        p99_ms: number;
        min_ms: number;
        max_ms: number;
        stddev_ms: number;
      }
    >;
  };
}

let native: NativeModule | null = null;

// ─── .node 경로 탐색 ───

// npm 의 `os`/`cpu`/`libc` 매칭으로 platform sub-package 가 자동 install 됨
// (메인 `@zntc/core` 의 optionalDependencies). 사용자 환경에 맞는 1개만 설치.
// PLATFORMS 는 ./src/platforms.ts 의 단일 source — bun build 가 inline.
//
// libc 검출: linux 에서 musl(Alpine) vs glibc(Debian/Ubuntu) 분기 — node 표준
// `process.report.getReport().header.glibcVersionRuntime` 사용 (napi-rs/esbuild
// 동일 패턴, dependency 불필요). glibc 마커가 없으면 musl 로 분류 — Alpine 의도
// 이며, Termux(bionic) 등 다른 비-glibc linux 도 musl 패키지로 떨어짐 (best-effort).
function detectLinuxLibc(): 'glibc' | 'musl' | undefined {
  if (process.platform !== 'linux') return undefined;
  try {
    // @types/node 의 `getReport(): object` 가 너무 좁아 header 접근 불가 →
    // 명시 narrow. 실제 shape 는 Node docs 의 ProcessReport 참고.
    const report = process.report?.getReport() as
      | { header?: { glibcVersionRuntime?: string } }
      | undefined;
    if (report?.header?.glibcVersionRuntime) return 'glibc';
  } catch {
    // process.report 미지원 런타임 → musl fallback
  }
  return 'musl';
}

function getPlatformPackage(): string | null {
  const { platform, arch } = process;
  const libc = detectLinuxLibc();
  const match = PLATFORMS.find(
    (p) => p.npmOs === platform && p.npmCpu === arch && p.npmLibc === libc,
  );
  return match ? subPackageName(match) : null;
}

function findAddon(): string {
  const __dirname = dirname(fileURLToPath(import.meta.url));
  const platformPkg = getPlatformPackage();

  // 1. zig-out 빌드 산출물 우선 (monorepo dev — 항상 최신 바이너리)
  const zigOut = join(__dirname, '../../zig-out/lib/zntc.node');
  if (existsSync(zigOut)) return zigOut;
  const zigOut2 = join(__dirname, '../../../zig-out/lib/zntc.node');
  if (existsSync(zigOut2)) return zigOut2;

  // 2. platform sub-package (npm install — production)
  if (platformPkg) {
    try {
      // CJS 빌드에서 ZNTC 가 import.meta.url → `require("url").pathToFileURL(__filename).href`
      // 로 inline 치환하므로, 같은 const 안에서 `require` 식별자 shadowing → TDZ
      // 회피용 rename. 동작은 동일.
      const nodeRequire = createRequire(import.meta.url);
      return nodeRequire.resolve(platformPkg);
    } catch {
      /* fall through */
    }
  }

  // 3. legacy fallback — 같은/한 단계 위 디렉토리 (구버전 단일 패키지 install 호환)
  const local = join(__dirname, 'zntc.node');
  if (existsSync(local)) return local;
  const parent = join(__dirname, '../zntc.node');
  if (existsSync(parent)) return parent;

  const expected = platformPkg ? ` (expected sub-package: ${platformPkg})` : '';
  throw new Error(
    `@zntc/core: native binary not found for ${process.platform}-${process.arch}${expected}. ` +
      `Supported: ${formatSupportedPlatforms()}. ` +
      'For development run `zig build napi`. ' +
      'If your platform should be supported, please open an issue.',
  );
}

// ─── Public API ───

/**
 * `zntc.config.{ts,js}` 의 타입 체크 / 자동완성을 위한 identity helper.
 *
 * 객체 config 와 함수형 config 를 모두 지원한다.
 *
 * @example
 * ```ts
 * import { defineConfig } from "@zntc/core";
 *
 * export default defineConfig({
 *   entryPoints: ["src/index.ts"],
 *   format: "esm",
 *   sourcemap: true,
 * });
 * ```
 *
 * @example
 * ```ts
 * import { defineConfig } from "@zntc/core";
 *
 * export default defineConfig(({ command, mode, env }) => {
 *   const production = command === "bundle" && mode === "production";
 *
 *   return {
 *     entryPoints: ["src/index.ts"],
 *     minify: production,
 *     define: {
 *       __APP_ENV__: JSON.stringify(env.ZNTC_APP_ENV ?? mode),
 *     },
 *   };
 * });
 * ```
 */
export function defineConfig<T extends UserConfigInput>(config: T): T {
  return config;
}

export {
  defaultConfigEnv,
  findConfigPath,
  findModeConfigPath,
  importAndResolveDefault,
  loadConfig,
  loadModuleDefault,
  mergeUserConfigs,
} from './src/config-loader.ts';
export type {
  ConfigEnv,
  ModuleKind,
  UserConfig,
  UserConfigFn,
  UserConfigInput,
} from './src/config-loader.ts';
export { envToDefine, loadEnv } from './src/load-env.ts';
export { KNOWN_CONFIG_KEYS, suggestKey, warnUnknownKeys } from './src/typo-suggest.ts';
export {
  defineWorkspace,
  filterWorkspaces,
  findWorkspacePath,
  identifyWorkspaceEntries,
  loadIdentifiedConfig,
  loadWorkspace,
  WORKSPACE_EXT_PRIORITY,
} from './src/workspace.ts';
export type {
  IdentifiedWorkspace,
  Workspace,
  WorkspaceEntry,
  WorkspaceEntryInline,
  WorkspaceEntryPath,
  WorkspaceFn,
  WorkspaceInput,
} from './src/workspace.ts';

import type { UserConfigInput } from './src/config-loader.ts';

/**
 * Loads the NAPI addon — called automatically on the first invocation of a
 * native API such as `transpile()`/`build()`/`watch()`, so calling it
 * explicitly is optional. Call it directly only when you need an addon path
 * override (e.g. a custom prebuild). No-op if already loaded.
 */
export function init(addonPath?: string): void {
  if (native) return;
  const path = addonPath ?? findAddon();
  // require shadowing 회피 — findAddon() 참고.
  const nodeRequire = createRequire(import.meta.url);
  native = nodeRequire(path) as NativeModule;
}

/**
 * native handle 을 반환. lazy auto-init 의 단일 진입점.
 * TS 가 module-level mutable `let native` 를 `asserts` 시그니처로도 narrowing 못 해
 * helper 한 곳에 `!` 를 격리. caller 들은 좁혀진 `NativeModule` 을 그대로 사용.
 */
function ensureNative(): NativeModule {
  init();
  return native!;
}

/**
 * Transpiles TypeScript/JSX source code.
 */
/**
 * browserslist 모듈 lazy-load 캐시.
 *
 * Bun/esbuild 같은 번들러는 `require("browserslist")`를 **정적 분석**해서
 * 의존성을 강제 해결하려 한다. browserslist는 optional이므로 (missing 시
 * target으로 graceful fallback) Function 생성자로 require를 감싸 정적
 * resolve를 회피한다. 사용자가 `browserslist` 옵션을 전달했지만 패키지가
 * 설치되어 있지 않으면 친절한 에러 throw.
 */
let _browserslist: ((q: string | string[]) => string[]) | null = null;
let _browserslistResolved = false;

function loadBrowserslist(): ((q: string | string[]) => string[]) | null {
  if (_browserslistResolved) return _browserslist;
  _browserslistResolved = true;
  try {
    // ESM 환경이라 Node/Bun의 createRequire로 런타임 require를 얻는다.
    // 동적 문자열 key를 넘겨 Bun 번들러의 정적 분석을 회피 → browserslist
    // 미설치여도 zntc 자체는 로드 가능 (optional dep).
    const req = createRequire(import.meta.url);
    const name = 'browserslist';
    _browserslist = req(name) as (q: string | string[]) => string[];
  } catch {
    _browserslist = null;
  }
  return _browserslist;
}

/**
 * target | browserslist → UnsupportedFeatures bitmask.
 * browserslist가 지정되면 우선. 둘 다 없으면 0 (esnext).
 */
function resolveUnsupported(options: TranspileOptions): number {
  if (options.browserslist) {
    const bl = loadBrowserslist();
    if (!bl) {
      throw new Error(
        "@zntc/core: 'browserslist' option requires the 'browserslist' package. Install it: bun add browserslist",
      );
    }
    return browserslistToUnsupported(bl(options.browserslist));
  }
  return options.target ? (ES_TARGET_BITS[options.target] ?? 0) : 0;
}

/**
 * Cache of tsconfig autodiscovery walk results (#2367). A NAPI consumer that
 * repeatedly transpiles many files in-process (Vite/Rollup plugin, etc.)
 * creates one instance and reuses it across transpile calls → saves 5–10 fs
 * syscalls per file.
 *
 * Passed via the `cache` option of `transpile()`. When `tsconfigPath` /
 * `tsconfigRaw` is specified, the cache is bypassed and the explicit value is
 * used. The instance is cleaned up automatically on GC — explicit dispose is
 * not required.
 *
 * Aligned with rolldown `TsconfigCache` (the design is an N-slot HashMap, not
 * a single slot).
 *
 * @example
 *   const cache = new TsconfigCache();
 *   for (const file of files) {
 *     transpile(source, { filename: file, cache });
 *   }
 */
export class TsconfigCache {
  /** @internal native handle — unwrapped and used by `transpile()`. Do not use externally. */
  private readonly _handle: NativeTsconfigCacheHandle;

  constructor() {
    this._handle = ensureNative().createTsconfigCache();
  }

  /** Reclaims all cache entries and internal string memory. The instance can be reused. */
  clear(): void {
    this._handle.clear();
  }

  /** Current number of cached entries (testing / debugging). */
  get size(): number {
    return this._handle.size();
  }

  /**
   * Explicit Resource Management (TC39 Stage 4) — `using cache = new TsconfigCache();`
   * automatically calls `clear()` on scope exit. The memory itself is reclaimed
   * by the GC finalizer, so this method only "empties the cache" (the instance
   * can be reused).
   */
  [Symbol.dispose](): void {
    this._handle.clear();
  }

  /** Used by transpile() to extract the native handle — do not use externally (private escape hatch). */
  /** @internal */
  static _unwrap(c: TsconfigCache): NativeTsconfigCacheHandle {
    return c._handle;
  }
}

export function transpile(
  source: string,
  options: TranspileOptions & { cache?: TsconfigCache } = {},
): TranspileResult {
  if (!source) throw new Error('@zntc/core: empty source');
  validateTsConfigRaw(options.tsconfigRaw);

  const optionsJson = buildOptionsJson(options, resolveUnsupported(options));
  return ensureNative().transpile(
    source,
    options.filename ?? 'input.js',
    optionsJson,
    options.cache ? TsconfigCache._unwrap(options.cache) : undefined,
  );
}

export function tokenize(source: string, options: TokenizeOptions = {}): TokenizeToken[] {
  if (!source) throw new Error('@zntc/core: empty source');
  return ensureNative().tokenize(source, options.filename ?? 'input.js');
}

export function configureProfile(
  profile: string[],
  level?: 'summary' | 'detailed' | 'per-module' | 'per-pass',
): void {
  ensureNative().configureProfile(profile, level);
}

export function profileReport(format: 'table' | 'tree' | 'json' | 'csv' = 'table'): string {
  return ensureNative().profileReport(format);
}

// ─── Build API ───

export type { OutputFile, Diagnostic };

/** Return value of `meta.getModuleInfo(id)` in Rollup `manualChunks(id, meta)`. */
export interface ManualChunksModuleInfo {
  id: string;
  isEntry: boolean;
  /** A module not included in the bundle because it matched an `external`
   * pattern. No AST/source — exposed only as a first-class graph traversal
   * node. */
  isExternal: boolean;
  /** Whether the module may have side effects (compatible with Rollup
   * `hasModuleSideEffects`). Determined by the `package.json` `sideEffects`
   * field or the `treeShaking.moduleSideEffects` option. When `false`, the
   * tree-shaker may remove it if unused. */
  hasModuleSideEffects: boolean;
  /** Module source code (compatible with Rollup `code`).
   * null for external / asset / unparsed modules. Also null if UTF-8 decoding
   * fails. */
  code: string | null;
  /** Whether the module is included in the bundle after tree-shaking
   * (compatible with Rollup `isIncluded`). When `treeShaking: false`, all
   * modules may appear false — it is a mirror flag on Module, so it stays at
   * its default if the tree-shaker does not run. */
  isIncluded: boolean;
  /** The list of names this module exports (compatible with Rollup `exports`).
   * Includes both default and re-export stars. Empty array for external (the
   * graph has no export info). */
  exports: string[];
  /** Synthetic named exports defined by a plugin (compatible with Rollup
   * `syntheticNamedExports`). Always false until the ZNTC plugin context API
   * extension (#1880). */
  syntheticNamedExports: boolean;
  /** Result of the `implicitlyLoadedAfterOneOf` option of `this.emitFile`
   * (Rollup-compatible). Always an empty array until the ZNTC plugin context
   * API (#1880). */
  implicitlyLoadedAfterOneOf: string[];
  /** The opposite direction — modules that must be loaded after this module is
   * implicitly loaded. */
  implicitlyLoadedBefore: string[];
  /** Modules that statically import this module. External modules are also
   * included in the importer list (when itself is external, an in-graph module
   * is the importer). */
  importers: string[];
  /** Modules that dynamically import (`import()`) this module. */
  dynamicImporters: string[];
  /** Modules that this module statically imports. Includes external modules. */
  importedIds: string[];
  /** Modules that this module dynamically imports (`import()`). Includes
   * external modules. */
  dynamicallyImportedIds: string[];
}

/** The second argument of the `manualChunks` callback — module graph topology lookup. */
export interface ManualChunksMeta {
  /** Look up module info by `id`. null if not found. */
  getModuleInfo(id: string): ManualChunksModuleInfo | null;
}

/**
 * The `compiler` namespace — per-library 1st-party transform settings
 * (`@next/swc`-compatible surface).
 *
 * The 1st-party counterpart to `babel-plugin-styled-components` /
 * `@emotion/babel-plugin`. Enabling the option alone, without registering a
 * plugin, produces the same transform result.
 */
export interface CompilerOptions {
  /**
   * styled-components 1st-party transform.
   * Same transform intent as `babel-plugin-styled-components` /
   * `@swc/plugin-styled-components`.
   */
  styledComponents?: boolean | StyledComponentsOptions;
  /**
   * emotion 1st-party transform.
   * Same transform intent as `@emotion/babel-plugin` / `@swc/plugin-emotion`.
   */
  emotion?: boolean | EmotionOptions;
}

/** styled-components transform options (`babel-plugin-styled-components`-compatible). */
export interface StyledComponentsOptions {
  /** Auto-assign a displayName for devtools display (default: NODE_ENV !== "production"). */
  displayName?: boolean;
  /** Deterministic componentId hash for stable SSR hydration (default: true). */
  ssr?: boolean;
  /** Include the file name in componentId (default: true). */
  fileName?: boolean;
  /** Minify CSS whitespace (default: true). */
  minify?: boolean;
  /** Recognize template literals downleveled to modern JS (default: true). */
  transpileTemplateLiterals?: boolean;
  /** Tell the minifier that styled.X is side-effect-free (default: false). */
  pure?: boolean;
  /** Namespace prefix for displayName / componentId — isolates multiple styled instances. */
  namespace?: string;
  /**
   * List that makes the displayName prefix fall back to the parent dir when
   * the basename is meaningless (default: `["index"]`). Equivalent to the
   * option of the same name in babel-plugin-styled-components.
   */
  meaninglessFileNames?: string[];
  /**
   * List of import sources to recognize as vendored forks (e.g. `@my-org/styled`,
   * `@my-org/*`, `@{my-org,co}/*`). picomatch-compatible glob — `*`, `?`,
   * `[abc]`/`[a-z]`/`[!abc]`, `{a,b}` (nesting allowed).
   */
  topLevelImportPaths?: string[];
  /**
   * Extract the `<div css={...}>` JSX prop into a module-level styled component
   * (default: false). Opt-in, unlike babel-plugin-styled-components which
   * defaults to true. Supports intrinsic / custom (including
   * jsx_member_expression) / `css\`\`` template / object form / `${expr}`
   * dynamic prop forwarding. On auto-inject, a `styled` binding collision is
   * automatically mangled to `_styled` / `_styled2`.
   */
  cssProp?: boolean;
  /** Emit the [meta] marker (default: false). */
  meta?: boolean;
}

/** emotion transform options (`@emotion/babel-plugin`-compatible). */
export interface EmotionOptions {
  /** Generate a sourceMap (default: true). */
  sourceMap?: boolean;
  /** Auto-assign the variable name as the CSS class label (default: "dev-only"). `false` disables autoLabel. */
  autoLabel?: 'always' | 'dev-only' | 'never' | boolean;
  /** label format string. tokens: `[local]`, `[filename]`, `[dirname]` (default: "[local]") */
  labelFormat?: string;
  /** Import path alias — for using a fork or vendored emotion. */
  importMap?: Record<string, Record<string, { canonicalImport: [string, string] }>>;
}

/** Vite-style dev server options used by `zntc dev` / `zntc --serve`. */
export interface DevServerOptions {
  /** Port to listen on. CLI `--port` overrides this value. */
  port?: number;
  /** Host to listen on. `true` means `0.0.0.0`, matching Vite. CLI `--host` overrides this value. */
  host?: string | boolean;
  /** Exit if the configured port is already in use instead of trying the next port. */
  strictPort?: boolean;
  /** Open the served URL in the browser after startup. CLI `--open` overrides this value. */
  open?: boolean;
}

type BuildTarget = import('../shared/index').Target | (string & {});

/**
 * Common build options shared by all platforms.
 * The `platform` + `target` combination is constrained as a discriminated
 * union in `BuildOptions`.
 */
/** Module Federation `shared` dependency options (a subset of MF2 `SharedConfig`, #3318). */
export interface MfSharedConfig {
  singleton?: boolean;
  requiredVersion?: string;
  strictVersion?: boolean;
  eager?: boolean;
}

/** Module Federation config block (#3318 P1-0). A record shape isomorphic to
 * the webpack/rspack `ModuleFederationPlugin` — targeting the
 * `@module-federation/runtime` contract. **P1-0 is zntc.config parsing &
 * validation only** (emit not wired up; consumed in P1-1+; build()/NAPI mf
 * extraction is also P1-1+). The `shared` array/boolean shorthand is P1-1+ —
 * P1-0 only supports record-of-object. */
export interface ModuleFederationConfig {
  /** remote identifier. Required when using `exposes`/`remotes`. */
  name?: string;
  /** Exposed modules: `{ "./Widget": "./src/Widget.tsx" }`. */
  exposes?: Record<string, string>;
  /** Consumed remotes: `{ remoteA: "remoteA@https://…/mf-manifest.json" }`. */
  remotes?: Record<string, string>;
  /** Shared dependencies: `{ react: { singleton: true, requiredVersion: "^18" } }`.
   * (P1-0: record-of-object only. boolean/array shorthand is P1-1+.) */
  shared?: Record<string, MfSharedConfig>;
  /** share scope name (default `"default"`). */
  shareScope?: string;
}

interface BuildOptionsCommon {
  entryPoints: string[];
  format?: 'esm' | 'cjs' | 'iife' | 'umd' | 'amd';
  external?: string[];
  minify?: boolean;
  minifyWhitespace?: boolean;
  minifyIdentifiers?: boolean;
  minifySyntax?: boolean;
  splitting?: boolean;
  /** Rollup `output.inlineDynamicImports` — absorbs the dynamic import target
   * into the importer's chunk and rewrites the `import("./x")` call into an
   * `__esm` wrapper init/exports call. Combine with `splitting: true`. The
   * resulting bundle is runnable as a single file.
   *
   * Preservation guarantees:
   * - namespace identity: `(await import("./x")) === (await import("./x"))`
   * - top-level side effects run once (cached)
   * - live bindings (if the module mutates an `export let`, the change is
   *   reflected on the caller side too)
   */
  inlineDynamicImports?: boolean;
  /** Like Rollup `output.experimentalMinChunkSize` — automatically merges a
   * small common chunk whose (estimated) total module source is under this
   * many bytes into a chunk whose reachability is a superset (no over-fetch).
   * entry/manual/dynamic chunks are preserved. 0/unspecified = disabled. */
  minChunkSize?: number;
  /** Module Federation config (#3318 P1-0). Parsing & validation only — emit
   * is a follow-up (P1-1+). Being a nested object, it is config/`build()`-only
   * (no CLI flag — the whole ecosystem is config-driven). MF2 contract
   * (`name`/`exposes`/`remotes`/`shared`/`shareScope`). */
  mf?: ModuleFederationConfig;
  sourcemap?: boolean;
  /**
   * Source map output format (only meaningful when `sourcemap: true`).
   * esbuild / rolldown-compatible (#2152).
   *  - `"linked"` (default): emit a `.map` file +
   *    `//# sourceMappingURL=<file>.map` comment.
   *  - `"external"`: emit a `.map` file, no URL comment (Sentry/CI standard —
   *    location not disclosed).
   *  - `"inline"`: no `.map` file, embed the JSON as a base64 data URL in a
   *    comment.
   *
   * In watch / dev server environments, `linked` is forced (guarantees
   * HMR + DevTools integration).
   */
  sourcemapMode?: 'linked' | 'external' | 'inline';
  sourcemapDebugIds?: boolean;
  sourcesContent?: boolean;
  treeShaking?: boolean;
  metafile?: boolean;
  keepNames?: boolean;
  shimMissingExports?: boolean;
  flow?: boolean;
  jsxInJs?: boolean;
  charsetUtf8?: boolean;
  useDefineForClassFields?: boolean;
  experimentalDecorators?: boolean;
  emitDecoratorMetadata?: boolean;
  /** `import { x } from 'mod'` cherry-pick decomposition mapping. The ZNTC
   * equivalent of babel-plugin-lodash and the like (#2393).
   * key = source module name (exact match), value = template (the `{name}`
   * placeholder is replaced with the specifier name).
   *
   * e.g. with `{ lodash: 'lodash/{name}' }`, `import { map } from 'lodash'`
   *      becomes `import map from 'lodash/map'`.
   *
   * Transform conditions (all must hold): named specifiers only, no alias, not
   * type-only. If not met, the original import is kept — a safety net for when
   * the library does not support path imports.
   */
  moduleSpecifierMap?: Record<string, string>;
  banner?: string;
  footer?: string;
  /** Rollup `output.intro`: text to insert before the code inside the format wrapper. */
  intro?: string;
  /** Rollup `output.outro`: text to insert after the code inside the format wrapper. */
  outro?: string;
  globalName?: string;
  /** Rollup `output.globals`: IIFE/UMD external specifier → global variable mapping */
  globals?: Record<string, string>;
  publicPath?: string;
  entryNames?: string;
  chunkNames?: string;
  assetNames?: string;
  /** Metro AssetRegistry module path (React Native-only layer).
   * - `undefined`: determined by the platform preset (with
   *   `platform: "react-native"`, the default path is used automatically)
   * - `string`: wrap with the registerAsset at that path as
   *   `module.exports = require(path).registerAsset({...})`
   * - `false`: disabled (export the same URL string as web)
   * Default path: `"react-native/Libraries/Image/AssetRegistry"` */
  assetRegistry?: string | false;
  /** JSX runtime mode. `'preserve'` emits JSX unchanged — only TS annotations
   * are stripped. Use this to delegate JSX handling to a downstream tool (e.g.
   * `@vitejs/plugin-react` / `@preact/preset-vite` / `vite-plugin-solid`).
   * Equivalent to tsc `"jsx": "preserve"`.
   * Known limitation — TS annotations inside an expression container within JSX
   * (e.g. `<Foo prop={value as Type}>`) are left raw, not stripped. */
  jsx?: 'classic' | 'automatic' | 'automatic-dev' | 'preserve';
  jsxFactory?: string;
  jsxFragment?: string;
  jsxImportSource?: string;
  /** Compile-time constant substitution (esbuild `define`-compatible).
   * Keys are identifiers or member expressions like `obj.prop`; values are JS
   * expression strings.
   * e.g. `{ "__DEV__": "false", "process.env.NODE_ENV": '"production"' }` */
  define?: Record<string, string>;
  /** Dev server defaults for `zntc dev` / `zntc --serve`. CLI flags still take precedence. */
  server?: DevServerOptions;
  /** Import path aliases — two forms supported (esbuild / Vite-compatible):
   *
   * 1. **Object form** (esbuild `alias`): exact + prefix matching. Only the
   *    given specifier is substituted.
   *    e.g. `{ react: "preact/compat" }` — `react` or `react/hooks` →
   *    `preact/compat[/hooks]`
   *
   * 2. **Array form** (Vite `resolve.alias`, #2153): supports `RegExp` find.
   *    The first match in order is applied. When `find` is a string it is
   *    prefix-matched; when a RegExp, the host runtime matches and substitutes
   *    via `replacement`.
   *    e.g. `[{ find: /^@\/(.*)$/, replacement: "./src/$1" }]`
   *
   * Substituted **unconditionally before** normal resolution — even an
   * actually-installed package is ignored. For an optional shim, use
   * `fallback` instead (applied only on failure). The array form is also
   * supported in buildSync(), which uses only sync hooks. */
  alias?: Record<string, string> | Array<{ find: string | RegExp; replacement: string }>;
  /** Fallback resolution — applied **only when** normal resolution fails
   * (webpack `resolve.fallback` / Metro `resolver.extraNodeModules`-compatible).
   * If the value is a string, re-resolve to that specifier; if `false`,
   * substitute an empty module.
   * e.g. `{ crypto: "crypto-browserify", fs: false }` */
  fallback?: Record<string, string | false>;
  /** Resolution-blocking patterns (Metro `resolver.blockList` / webpack
   * `IgnorePlugin`-compatible). Absolute paths that match are failed by the
   * resolver and not included in the bundle graph.
   * - `RegExp`: `.source` is extracted and used as the pattern
   * - `string`: used as the regex string as-is
   *
   * Supported syntax: literals, `.*`, `^`, `$`, `\x` escapes. `|`, `[]`, `()`,
   * `+?`, `\w\d` are not supported.
   *
   * With `platform: "react-native"`, Metro's default patterns (`__tests__`,
   * iOS/Android build folders, etc.) are auto-prepended. User patterns are
   * appended after them. */
  blockList?: (RegExp | string)[];
  inject?: string[];
  jobs?: number;
  plugins?: ZntcPlugin[];
  /** User-defined chunk splitting — Rollup/rolldown `manualChunks`-compatible
   * (#1027). Receives a module id (absolute path); returning a chunk name
   * groups that module into the chunk of that name. Returning null/undefined
   * uses the existing automatic distribution. Transitive dependencies follow
   * into the same chunk (avoids cross-chunk cycles). Dynamic import targets
   * prefer the manual chunk over an async chunk.
   *
   * The second argument `meta.getModuleInfo(id)` is a graph topology lookup —
   * Rollup-compatible.
   *
   * e.g.:
   * ```ts
   * manualChunks: (id, meta) => {
   *   const info = meta.getModuleInfo(id);
   *   if (info && info.importers.length >= 2) return 'shared';
   *   if (/node_modules\/react/.test(id)) return 'react';
   *   return null;
   * }
   * ```
   */
  manualChunks?: (id: string, meta: ManualChunksMeta) => string | null | undefined;
  /** Per-extension loader override (e.g. { ".png": "file", ".svg": "text" }). */
  loader?: Record<string, string>;
  /** Custom package.json exports conditions. */
  conditions?: string[];
  /** Extension resolution order (e.g. [".ts", ".tsx", ".js"]). */
  resolveExtensions?: string[];
  /** package.json field order (e.g. ["module", "main"]). */
  mainFields?: string[];
  /** Output directory (used when write: true). */
  outdir?: string;
  /** Output file path (for a single entry, used when write: true). */
  outfile?: string;
  /**
   * Multi-format emit (rolldown-style). 배열 길이 >= 2 시 같은 entry 로 각 format 별
   * build() 호출 후 BuildResult.outputsByFormat 에 결과 묶음. 사용자가 한 호출로
   * ESM+CJS 동시 출력. graph 재사용은 현재 미지원 (각 format 마다 graph 재빌드).
   */
  output?: OutputOptions[];
  /** Whether to write to disk (default: false, automatically true when outdir/outfile is set). */
  write?: boolean;
  /** Allow output files to overwrite input files. */
  allowOverwrite?: boolean;
  /** Common base path for entry points (determines the output directory structure). */
  outbase?: string;
  /** Treat all bare imports as external. */
  packagesExternal?: boolean;
  /** Resolve to the link path instead of following symlinks (esbuild/Node-compatible). */
  preserveSymlinks?: boolean;
  /**
   * When normal `node_modules` resolution fails, search once more in the
   * realpath directory of `source_dir`. Used as a fallback when an RN/pnpm
   * peer dependency exists only in a sibling `node_modules` beyond a symlink.
   * Orthogonal to `preserveSymlinks` — they are commonly enabled together.
   */
  resolveSymlinkSiblings?: boolean;
  /**
   * Metro `resolver.disableHierarchicalLookup`-compatible. When true, blocks
   * `node_modules` walk-up resolution outside the entry directory — used in a
   * monorepo to force dependency hoisting or to prevent leakage of modules
   * outside the workspace.
   */
  disableHierarchicalLookup?: boolean;
  /** Ignore @__PURE__ and sideEffects annotations. */
  ignoreAnnotations?: boolean;
  /** Do not tree-shake unused JSX. */
  jsxSideEffects?: boolean;
  /** Bundle analysis output (forces metafile on). */
  analyze?: boolean;
  /** List of label names of labeled statements to remove. */
  dropLabels?: string[];
  /** Remove `console.*` call expression statements in the transformer (#2155). Applied identically for bundle/transpile. */
  dropConsole?: boolean;
  /** Remove `debugger;` statements in the transformer (#2155). Applied identically for bundle/transpile. */
  dropDebugger?: boolean;
  /** List of global function names to mark as pure. */
  pure?: string[];
  /**
   * Diagnostic output level (esbuild-compatible, #2158). NAPI filters the
   * build result's errors/warnings arrays by this level — the items included
   * in `result.errors` / `result.warnings` themselves are reduced.
   *
   *  - `"silent"`: both errors / warnings are empty arrays — even a failure is
   *    observed via the result object (no throw)
   *  - `"error"`: only warnings is an empty array, errors as-is
   *  - `"warning"` (default): both errors + warnings as-is
   *  - `"info"` / `"debug"` / `"verbose"`: same as warning (info-level
   *    diagnostics are not emitted currently)
   */
  logLevel?: 'silent' | 'error' | 'warning' | 'info' | 'debug' | 'verbose';
  /**
   * Diagnostic count limit (esbuild `logLimit`, #2158). 0 means unlimited
   * (default). The same limit applies to each of the errors / warnings arrays
   * — excess items are auto-truncated.
   */
  logLimit?: number;
  /**
   * CJS / UMD entry export format (Rollup `output.exports`-compatible, #2159).
   * Ignored for ESM output.
   *
   *  - `"auto"` (default): default-only → `module.exports = X`. named-only → `exports.X = X`
   *    (no `__esModule` flag). mixed → `exports.X = X` + `__esModule` flag.
   *  - `"named"`: always named (`exports.X = X`). If a default exists, the
   *    `__esModule` flag is added automatically (rolldown `IfDefaultProp`
   *    behavior — no flag when there is no default).
   *  - `"default"`: single `module.exports = X` — only when default-only. If
   *    named is mixed in, warning + empty output.
   *  - `"none"`: no export output.
   */
  outputExports?: 'auto' | 'named' | 'default' | 'none';
  /**
   * Inline tsconfig JSON string (same meaning as esbuild's `tsconfigRaw`).
   * When set, both `tsconfigPath` and autodiscovery are ignored — raw is the
   * single source of truth. compilerOptions such as jsx/target/decorators are
   * applied by the Zig-side `tsconfig_merge`.
   *
   * @example
   *   tsconfigRaw: JSON.stringify({ compilerOptions: { jsx: "react-jsx", jsxImportSource: "preact" } })
   */
  tsconfigRaw?: string;
  /**
   * Path to tsconfig.json (file or directory). When set, compilerOptions are
   * auto-loaded and merged. Fields set explicitly via JS options take
   * precedence — only unspecified fields are filled from the tsconfig values.
   * e.g. "./tsconfig.json" or "./project-dir".
   */
  tsconfigPath?: string;
  /** Additional NODE_PATH resolution paths. */
  nodePaths?: string[];
  /** Line length limit (0=unlimited). */
  lineLimit?: number;
  /** Output file extension override (e.g. ".mjs"). */
  outExtension?: string;
  /** Source map sourceRoot field. */
  sourceRoot?: string;
  /** License comment handling ("none" | "inline" | "eof" | "linked"). */
  legalComments?: 'none' | 'inline' | 'eof' | 'linked';
  /** Emit a separate file per module (library build). */
  preserveModules?: boolean;
  /** Base path for the preserve-modules output directory structure. */
  preserveModulesRoot?: string;
  /**
   * List of profile categories to enable (union with the ZNTC_PROFILE env).
   * e.g. `["all"]`, `["parse", "transform"]`, `["transform.jsx"]`.
   * Specifying a parent auto-enables children too (e.g. "transform" →
   * "transform.jsx"/"transform.ts_strip"/...).
   * Available categories: see docs/design/profile-infrastructure.md.
   */
  profile?: string[];
  /**
   * Profile detail level.
   * - "summary": phase totals only (default)
   * - "detailed": includes sub-phases
   * - "per-module": per-module breakdown
   * - "per-pass": transformer visit level
   */
  profileLevel?: 'summary' | 'detailed' | 'per-module' | 'per-pass';
  /**
   * Profile report output format.
   * - "table": human-readable (default)
   * - "tree": parent/child tree
   * - "json": machine-readable
   * - "csv": spreadsheet
   */
  profileFormat?: 'table' | 'tree' | 'json' | 'csv';
  /** dev mode: wrap modules in a __zntc_register() factory + inject the HMR runtime. */
  devMode?: boolean;
  /** dev mode module ID base path. */
  rootDir?: string;
  /** Enable React Fast Refresh. */
  reactRefresh?: boolean;
  /** Collect dev mode per-module codes (for HMR rebuilds). */
  collectModuleCodes?: boolean;
  /** Add configurable: true to Object.defineProperty (RN/Hermes-compatible). */
  configurableExports?: boolean;
  /** Guarantee ESM execution order — downgrade function declarations to
   * assignments inside the factory to prevent hoisting. Same as Rolldown's
   * strictExecutionOrder. Auto-enabled on the React Native platform. */
  strictExecutionOrder?: boolean;
  /** Wrap entry trigger (`init_X()` / `require_X()`) calls in try/catch +
   * ErrorUtils.reportFatalError. Equivalent mechanism to Metro
   * `guardedLoadModule` (top-level `__r` wrapper) — a module factory throw is
   * shown as fatal in the standard RN LogBox instead of blocking boot. In
   * environments without ErrorUtils (test / browser), the throw is re-thrown
   * as-is. It was discovered when iOS 26.4 Hermes pre-registers spec globals
   * such as `Location` with an immutable descriptor (`configurable: false`)
   * and expo-metro-runtime's unguarded `defineProperty` attempt threw, but the
   * mechanism is OS/engine-agnostic — it covers every module factory throw
   * case. Auto-enabled on the React Native platform. */
  entryErrorGuard?: boolean;
  /** Inject a `console.error` setter intercept into the prologue — console.error
   * calls matching any one of the RegExp source string array are silently
   * swallowed. Orthogonal to `entryErrorGuard`. The consumer detects the
   * environment (e.g. expo) and injects the patterns. When empty or
   * unspecified, the wrap itself is not emitted → a vanilla RN CLI build has
   * zero dead code. Not auto-enabled even by the RN preset (the trigger is
   * environment-specific).
   *
   * e.g.: `["^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$"]`
   * (the native immutable global collision message of expo `installGlobal.ts`
   * + RN `polyfillObjectProperty`) */
  silentConsoleErrorPatterns?: string[];
  /** Enable scope hoisting (default true). Removes module boundaries within a single chunk and flattens symbols. */
  scopeHoist?: boolean;
  /** Reanimated worklet transform — injects __workletHash/__closure/__initData
   * into functions with the "worklet" directive. Auto-enabled on the React
   * Native platform. */
  workletTransform?: boolean;
  /** The worklet's `__pluginVersion` value (for cross-checking Reanimated dev
   * mode jsVersion). Must be passed the react-native-worklets package version
   * from the user's environment to avoid a runtime error. */
  workletPluginVersion?: string;
  /** RN view config codegen — replaces the `codegenNativeComponent` call in
   * `*NativeComponent.{js,ts}` with an inline view config (#2348). Auto-enabled
   * on the React Native platform. Same as the
   * `GenerateViewConfigJs.generate()` fileTemplate of `@react-native/codegen`.
   * Avoids the Fabric early-register race (`View config not found for
   * component 'X'`). */
  codegenTransform?: boolean;
  /** Global identifiers to reserve during scope hoisting. */
  globalIdentifiers?: string[];
  /** Paths of polyfills to run immediately at bundle start. */
  polyfills?: string[];
  /**
   * Auto-inject core-js-based runtime API polyfills.
   *
   * - `"off"` (default): no automatic runtime polyfills.
   * - `"auto"` / `"usage"`: after resolve/load/transform, detect the APIs
   *   actually used in the bundle graph and inject the modules unsupported by
   *   the target.
   * - `"entry"`: comprehensively inject the core-js ES/Web modules required by
   *   the target into the entry prelude.
   * - Target specification uses a Browserslist query array, like Rspack/SWC
   *   `env.targets`.
   */
  runtimePolyfills?: RuntimePolyfillsOption;
  /** core-js version used for the core-js-compat computation (e.g. `"3.49"`). Same role as `runtimePolyfills.coreJs`. */
  coreJs?: string;
  /** Paths of modules to run immediately before the entry module. */
  runBeforeMain?: string[];
  /** Add directories outside the bundle graph to the watch roots (Metro
   * watchFolders-compatible). Both absolute and relative paths are allowed.
   * The given paths are recursively scanned and included in the watch set. */
  watchFolders?: string[];
  /** File glob whitelist to include when scanning watchFolders (paths relative to the root). */
  watchInclude?: string[];
  /** File globs to exclude when scanning watchFolders (paths relative to the root). */
  watchExclude?: string[];
  /** watch-mode build-complete callback. */
  onReady?: (event: WatchReadyEvent) => void | Promise<void>;
  /** watch-mode rebuild callback. */
  onRebuild?: (event: WatchRebuildEvent) => void | Promise<void>;
  /**
   * Whether to write the `.map` file to disk (Issue #1727 Phase B).
   *
   * - Default `true` — save `bundle.js.map` to the `output_filename + ".map"`
   *   path.
   * - `false` — skip disk I/O. Recommended when a dev server such as bungae
   *   serves it from a lazy endpoint by calling
   *   {@link WatchHandle.getBundleSourceMap} /
   *   {@link WatchHandle.getHmrSourceMap}.
   */
  emitDiskSourcemap?: boolean;
  /**
   * Per-library 1st-party transform settings (`@next/swc` `compiler`-compatible
   * surface).
   *
   * Currently a type stub — no runtime effect since the Zig transformer does
   * not recognize it yet. Activated in a follow-up epic when the
   * styled-components / emotion 1st-party transforms are introduced.
   *
   * @example
   * ```ts
   * defineConfig({
   *   compiler: {
   *     styledComponents: true,
   *     emotion: { autoLabel: "dev-only" },
   *   },
   * });
   * ```
   */
  compiler?: CompilerOptions;
}

/**
 * BuildOptions: the user-facing public API.
 *
 * When `platform === "react-native"`, the Hermes compatibility matrix is
 * forced, so `target` / `browserslist` cannot be passed (they are ignored at
 * runtime too).
 */
export type BuildOptions =
  | (BuildOptionsCommon & {
      /** React Native (Hermes) preset. target is forced to the Hermes matrix. */
      platform: Extract<import('../shared/index').Platform, 'react-native'>;
      target?: BuildTarget;
      browserslist?: never;
    })
  | (BuildOptionsCommon & {
      platform?: Exclude<import('../shared/index').Platform, 'react-native'>;
      /** ES downlevel target. Rspack-style node/hermes target strings are accepted by the JS wrapper. */
      target?: BuildTarget;
      /** browserslist query (string or string[]). Takes precedence over target when set. */
      browserslist?: string | string[];
    });

export interface WatchReadyEvent {
  files: number;
  bytes: number;
}

export interface WatchRebuildEvent {
  success: boolean;
  error?: string;
  changed?: string[];
  graphChanged?: boolean;
  updates?: Array<{
    id: string;
    code: string;
    /**
     * Per-module standalone source map (V3 JSON). Populated when the sourcemap
     * option is enabled. When the HMR client attaches it to the eval'd code as
     * a sourceMappingURL data URL, debugger mapping is preserved without
     * regenerating the whole bundle sourcemap (Issue #1248).
     */
    map?: string;
  }>;
  bytes?: number;
  /**
   * Per-phase build time (milliseconds). Exposed only on a successful rebuild.
   *
   * **Base phases** (always measured):
   * - `detect` / `graph` / `link` / `shake` / `emit` / `delta` / `total`
   * Field names exactly match their actual values. The pre-2026-04-22 `parse` /
   * `semantic` were in fact legacy names that held `graph` / `link+shake`
   * respectively and have been removed — they are now exposed only as
   * sub-phases (the real parser / SemanticAnalyzer times).
   *
   * **Sub-phases** (when `ZNTC_PROFILE=<cat>` / `BUNGAE_HMR_PROFILE=1` /
   * `profile: ["<cat>"]` is active):
   * - `scan` / `parse` / `resolve` / `semantic` / `transform` / `codegen` / `metadata`
   * - All 0 when inactive. `parse` is now the real parser time, `semantic` the
   *   real SemanticAnalyzer.
   */
  phaseDurations?: {
    // 기본 phase (항상 측정)

    /** Change detection (mtime scan). */
    detect: number;
    /** Module graph build — resolve + parse + semantic + finalize */
    graph: number;
    /** Scope hoisting + linker */
    link: number;
    /** Tree shaking */
    shake: number;
    /** Code generation (transform + codegen + emit). */
    emit: number;
    /** HMR delta extraction. */
    delta: number;
    /** Total rebuild time (sum of detect → delta). */
    total: number;

    // Sub-phase (profile 활성 시에만)

    /** Scanner tokenization */
    scan: number;
    /** Parser — real parser time only. */
    parse: number;
    /** Dependency resolution */
    resolve: number;
    /** SemanticAnalyzer — real semantic analysis time only. */
    semantic: number;
    /** Transformer total. */
    transform: number;
    /** Codegen total. */
    codegen: number;
    /** Linker metadata build */
    metadata: number;

    // Graph sub-phase (graph 내부 분해)

    /** `graph.build()` / `graph.buildIncremental()` — the module graph construction body. */
    graphBuild: number;
    /** Separate build of the `new Worker(new URL(...))` pattern entry. */
    graphWorker: number;
    /** Phase 1: event queue BFS scan (module discovery + parsing + resolve). */
    graphDiscover: number;
    /** Phase 2-4: DFS exec_index + ExportsKind promotion + TLA propagation. */
    graphFinalize: number;

    // Emit sub-phase (bundler.zig 수준 분해)

    /** Loading `--polyfill` file contents + Flow transpilation. */
    emitPolyfill: number;
    /** Assembling the React Refresh runtime preamble/epilogue (dev + browser). */
    emitRefresh: number;
    /** `emitter.emitWithTreeShaking` / `emitChunks` — the bundle output generation body. */
    emitOutput: number;
    /** `--metafile` / `--analyze` JSON generation. */
    emitMetafile: number;
    /** Per-CSS-entry bundling + lightningcss post-processing. */
    emitCss: number;

    // emit_output 내부 (emitter.emitWithTreeShaking 분해)

    /** Format prologue + polyfill IIFE + runtime helper injection. */
    emitPrelude: number;
    /** Phase 1/1.5/2/2.5 — used_names + cache lookup + emitModule + cache put */
    emitModulePass: number;
    /** Phase 3: module concat + runtime helpers summation + renderChunk + epilogue. */
    emitConcat: number;
    /** Source map V3 JSON generation (VLQ encode + sources content + debugId). */
    emitSourcemapFinalize: number;
  };
  /** Number of modules reparsed in the incremental graph. Counts cache-missed
   * modules only. Not exposed for full builds. */
  reparsedModules?: number;
}

export interface WatchHandle {
  stop(): void;
  /**
   * Lazily generates and returns the full-bundle sourcemap JSON of the latest
   * rebuild (Issue #1727 Phase B).
   *
   * The emit step skips VLQ encoding + sourcesContent attachment, deferring
   * that cost out of HMR latency until request time. Called when the dev
   * server receives a `/bundle.js.map` request.
   *
   * - `null` when sourcemap is disabled / before the initial build / after
   *   `stop()`.
   * - Metro `_processSourceMapRequest` pattern.
   */
  getBundleSourceMap(): string | null;
  /**
   * Lazily generates and returns the per-module sourcemap JSON of the latest
   * rebuild.
   *
   * Called when the dev server receives a `/hmr-map/:moduleId` request.
   * `null` if `moduleId` was not included in this rebuild.
   */
  getHmrSourceMap(moduleId: string): string | null;
}

export interface ZntcPlugin {
  name: string;
  setup(build: PluginBuild): void;
}

/** Plugin hook return value: both sync and async allowed. null/undefined for pass-through. */
type HookResult<T> = T | null | undefined | Promise<T | null | undefined>;
type PluginFailureResult = {
  __zntcPluginFailure: true;
  pluginName: string;
  hookName: string;
  message: string;
  file?: string;
  line?: number;
  column?: number;
};

export interface PluginBuild {
  onResolve(
    options: { filter: RegExp },
    callback: (args: { path: string; importer: string | null }) => HookResult<{
      path?: string;
      /** Keep the import statement as-is — resolved at runtime (esbuild-compatible). */
      external?: boolean;
      /** Substitute the module with an empty object (`module.exports = {}`).
       * For mapping when Metro `resolveRequest` returns `{ type: 'empty' }`, or
       * when webpack `resolve.fallback` is `false`. If `path` is omitted, the
       * specifier is used as the identifier. */
      disabled?: boolean;
    }>,
  ): void;
  onLoad(
    options: { filter: RegExp },
    callback: (args: {
      path: string;
    }) => HookResult<{ contents: string | Uint8Array; loader?: string; map?: unknown }>,
  ): void;
  onTransform(
    options: { filter: RegExp },
    callback: (args: { code: string; path: string }) => HookResult<{ code: string; map?: unknown }>,
  ): void;
  onRenderChunk(
    options: { filter: RegExp },
    callback: (args: { code: string; chunk: string }) => HookResult<{ code: string }>,
  ): void;
  onGenerateBundle(callback: (outputs: OutputFile[]) => void | Promise<void>): void;
  /**
   * Called once at bundle start. Same as esbuild `onStart`,
   * Rollup/Vite/rolldown `buildStart` (#2156). In watch mode it is called for
   * the initial build and on every rebuild (same as the Rollup 5+ policy).
   *
   * No arguments — same as esbuild `onStart`. `BuildOptions` is already passed
   * during the plugin's own setup.
   */
  onBuildStart(callback: () => void | Promise<void>): void;
  /**
   * Called once at bundle end. Dispatched for both success and failure. On
   * failure, the first fatal diagnostic item is wrapped in an `Error` and
   * passed (#2156). In watch mode it is called for the initial build and on
   * every rebuild.
   *
   * Called before `onCloseBundle`.
   */
  onBuildEnd(callback: (error?: Error) => void | Promise<void>): void;
  /**
   * Called once after output files are written (#2156). Same as Rollup
   * `closeBundle` — used for temp file cleanup, notifying external systems of
   * build completion, etc. In watch mode it is called for the initial build
   * and on every rebuild.
   */
  onCloseBundle(callback: () => void | Promise<void>): void;
  onAstFunction(
    options: { filter: RegExp },
    callback: (info: AstFunctionInfo) => HookResult<AstFunctionResult>,
  ): void;
  /**
   * Fills in the match results of `require.context(dir, recursive, filter,
   * mode)` from the host runtime. (#1579) Since ZNTC has no regex executor of
   * its own (#1771), this is delegated to the host's RegExp — Node V8 / Bun
   * JSC.
   *
   * `options.filter` applies to `dir` (e.g. `/^\.\/app/` to process only a
   * specific directory).
   * Callback return:
   *   - `{ context: string[] }` — array of matched file paths (empty array =
   *     empty context)
   *   - `null`/`undefined` — try the next plugin (if all are null, the graph
   *     emits a require_context_no_handler diagnostic)
   *
   * The callback argument `filter` is the regex body of require.context
   * (without slashes), and `flags` are the regex flags. The host compiles it
   * with `new RegExp(filter, flags)` and then matches.
   */
  onResolveContext(
    options: { filter: RegExp },
    callback: (args: {
      dir: string;
      recursive: boolean;
      filter?: string;
      flags?: string;
      importer: string;
    }) => HookResult<{ context: string[] }>,
  ): void;
}

export interface AstFunctionInfo {
  name: string | null;
  directives: string[];
  closureVars: string[];
  params: string[];
  sourcePath: string;
  bodyText: string;
  flags: { async: boolean; generator: boolean };
}

export interface AstFunctionResult {
  stripDirective?: string;
  trailingCode?: string[];
}

export interface BuildResult {
  outputFiles: OutputFile[];
  errors: Diagnostic[];
  warnings: Diagnostic[];
  metafile?: string;
  outputCount?: number;
  rnAssetMetadata?: RnAssetMetadata[];
  /// Multi-format emit (`BuildOptions.output: OutputOptions[]`) 결과 — format 별로 묶음.
  /// 단일 build/format 모드에서는 undefined.
  outputsByFormat?: Array<{
    format: 'esm' | 'cjs' | 'iife' | 'umd' | 'amd';
    outputFiles: OutputFile[];
  }>;
}

/**
 * Options for building a Vite-style browser application from an HTML entry.
 */
export interface AppBuildOptions {
  /** Application root directory used to resolve index.html, public/, and env files. */
  root?: string;
  /** Output directory for the production app build. Defaults to "dist". */
  outdir?: string;
  /** HTML entry file to scan for module scripts, stylesheets, and static assets. */
  entryHtml?: string;
  /** Public assets directory to copy as-is, or false to disable public asset copying. */
  publicDir?: string | false;
  /** Base URL prefix used when rewriting HTML and emitted asset URLs. */
  base?: string;
  /** Environment mode used for .env resolution and import.meta.env defaults. */
  mode?: string;
  /** Directory to load .env files from. Defaults to the application root. */
  envDir?: string;
  /** Environment variable prefixes that are exposed to import.meta.env. */
  envPrefixes?: string[];
  /** Additional compile-time defines merged into the underlying bundle build. */
  define?: Record<string, string>;
  /** Minify emitted JavaScript and CSS when supported by the underlying builder. */
  minify?: boolean;
  /** Emit sourcemaps for bundled application assets. */
  sourcemap?: boolean;
  /** Enable code splitting for the application bundle. */
  splitting?: boolean;
  /** JSX runtime: "automatic" / "automatic-dev" / "classic" / "preserve". */
  jsx?: 'classic' | 'automatic' | 'automatic-dev' | 'preserve';
  /** JSX import source for the automatic runtime (e.g. "react", "@emotion/react"). */
  jsxImportSource?: string;
  /** Classic-runtime JSX factory (e.g. "React.createElement", "h"). */
  jsxFactory?: string;
  /** Classic-runtime JSX fragment (e.g. "React.Fragment"). */
  jsxFragment?: string;
  /**
   * Per-library 1st-party transform (`@next/swc` `compiler`-compatible
   * surface). Same meaning as in BuildOptions — both bundle / app builds use
   * the same option representation.
   */
  compiler?: CompilerOptions;
}

/**
 * Options for preparing a Vite-style application for the development server.
 */
export interface AppDevPrepareOptions {
  /** Application root directory used to resolve index.html, public/, and env files. */
  root?: string;
  /** Temporary output directory used by the dev server. Defaults to ".zntc-dev". */
  outdir?: string;
  /** HTML entry file to scan for module scripts, stylesheets, and static assets. */
  entryHtml?: string;
  /** Public assets directory to copy as-is, or false to disable public asset copying. */
  publicDir?: string | false;
  /** Base URL prefix used when rewriting dev HTML and asset URLs. */
  base?: string;
  /** Environment mode used for .env resolution. Defaults to "development". */
  mode?: string;
  /** Directory to load .env files from. Defaults to the application root. */
  envDir?: string;
  /** Environment variable prefixes that are exposed to import.meta.env. */
  envPrefixes?: string[];
}

/**
 * Result produced after preparing an application entry for dev-server bundling.
 */
export interface AppDevPrepareResult {
  /** Prepared JavaScript entry path that the dev server should bundle and serve. */
  entryPath: string;
  /** Number of files emitted while preparing the dev app, when available. */
  outputCount?: number;
}

/**
 * thrown 값을 PluginFailureResult 로 정규화한다. Error / RollupError-like / 문자열 / 기타를
 * 한 가지 모양으로 묶어 NAPI 경계 너머로 전달 가능하게 한다 (#1902).
 */
function normalizePluginFailure(
  pluginName: string,
  hookName: string,
  thrown: unknown,
  fallbackFile?: string | null,
): PluginFailureResult {
  let message = 'Plugin hook failed';
  let file = fallbackFile ?? undefined;
  let line: number | undefined;
  let column: number | undefined;

  if (typeof thrown === 'string') {
    message = thrown;
  } else if (thrown && typeof thrown === 'object') {
    const err = thrown as {
      message?: unknown;
      text?: unknown;
      id?: unknown;
      file?: unknown;
      fileName?: unknown;
      line?: unknown;
      lineNumber?: unknown;
      column?: unknown;
      columnNumber?: unknown;
      loc?: { file?: unknown; line?: unknown; column?: unknown };
    };
    if (typeof err.message === 'string') message = err.message;
    else if (typeof err.text === 'string') message = err.text;
    else message = String(thrown);

    const loc = err.loc;
    const fileCandidate = loc?.file ?? err.id ?? err.file ?? err.fileName;
    if (typeof fileCandidate === 'string' && fileCandidate.length > 0) file = fileCandidate;

    const lineCandidate = loc?.line ?? err.line ?? err.lineNumber;
    const columnCandidate = loc?.column ?? err.column ?? err.columnNumber;
    if (typeof lineCandidate === 'number' && Number.isFinite(lineCandidate)) line = lineCandidate;
    if (typeof columnCandidate === 'number' && Number.isFinite(columnCandidate)) {
      column = columnCandidate;
    }
  } else if (thrown != null) {
    message = String(thrown);
  }

  return {
    __zntcPluginFailure: true,
    pluginName,
    hookName,
    message,
    ...(file ? { file } : {}),
    ...(line !== undefined ? { line } : {}),
    ...(column !== undefined ? { column } : {}),
  };
}

function pluginFailureText(failure: PluginFailureResult): string {
  const location =
    failure.file && failure.line !== undefined
      ? ` (${failure.file}:${failure.line}:${failure.column ?? 0})`
      : failure.file
        ? ` (${failure.file})`
        : '';
  return `Plugin "${failure.pluginName}" failed in ${failure.hookName}: ${failure.message}${location}`;
}

function pluginFailureToDiagnostic(failure: PluginFailureResult): Diagnostic {
  return {
    code: 'plugin_error',
    text: pluginFailureText(failure),
    ...(failure.file
      ? { location: { file: failure.file, line: failure.line, column: failure.column } }
      : {}),
  };
}

function serializePluginSourceMap(map: unknown): string | null {
  if (map == null) return null;
  if (typeof map === 'string') {
    try {
      JSON.parse(map);
    } catch (err) {
      throw new Error(`Invalid sourcemap: ${err instanceof Error ? err.message : String(err)}`);
    }
    return map;
  }
  if (typeof map !== 'object') {
    throw new Error(`Invalid sourcemap: expected object, string, null, or undefined`);
  }
  try {
    return JSON.stringify(map);
  } catch (err) {
    throw new Error(`Invalid sourcemap: ${err instanceof Error ? err.message : String(err)}`);
  }
}

function isPromiseLike(value: unknown): value is PromiseLike<unknown> {
  return (
    value != null &&
    (typeof value === 'object' || typeof value === 'function') &&
    typeof (value as { then?: unknown }).then === 'function'
  );
}

function silenceUnsupportedSyncPromise(value: PromiseLike<unknown>): void {
  Promise.resolve(value).catch(() => {});
}

function syncPluginPromiseFailure(
  pluginName: string,
  hookName: string,
  file?: string | null,
): PluginFailureResult {
  return normalizePluginFailure(
    pluginName,
    hookName,
    new Error(
      'buildSync() does not support async plugin hooks. Return a synchronous value or use build() instead.',
    ),
    file,
  );
}

function isPluginFailureResult(value: unknown): value is PluginFailureResult {
  return Boolean(
    value &&
    typeof value === 'object' &&
    (value as { __zntcPluginFailure?: unknown }).__zntcPluginFailure === true,
  );
}

/**
 * `serializePluginSourceMap` 의 throw (invalid map JSON) 를 결과 객체로 wrap.
 * generator 본체는 runner 의 try/catch 밖에서 실행되므로 직접 normalize 가 필요하다.
 */
function safeSerializeSourceMap(
  map: unknown,
): { ok: true; map: string | null } | { ok: false; err: unknown } {
  try {
    return { ok: true, map: serializePluginSourceMap(map) };
  } catch (err) {
    return { ok: false, err };
  }
}

function mapMaybePromise<T, U>(value: T | PromiseLike<T>, mapper: (value: T) => U): U | Promise<U> {
  if (isPromiseLike(value)) return Promise.resolve(value).then(mapper);
  return mapper(value);
}

type HookEntry = { pluginName: string; filter: RegExp; callback: (...args: any[]) => any };
type PluginDispatcherLifecycle = {
  takeLifecycleFailures(): PluginFailureResult[];
  /** plugin hook 의 `this.warn(...)` 으로 수집된 경고를 꺼내 result.warnings 로 surfacing. */
  takePluginWarnings(): Diagnostic[];
};
type PluginDispatcher = ((
  hookName: string,
  arg1: unknown,
  arg2: string | null,
) => Promise<unknown>) &
  PluginDispatcherLifecycle;
type SyncPluginDispatcher = ((hookName: string, arg1: unknown, arg2: string | null) => unknown) &
  PluginDispatcherLifecycle;

type PluginRegistry = {
  hooks: Record<string, HookEntry[]>;
  generateBundleCallbacks: Array<{
    pluginName: string;
    callback: (outputs: OutputFile[]) => void | Promise<void>;
  }>;
  buildStartCallbacks: Array<{ pluginName: string; callback: () => void | Promise<void> }>;
  buildEndCallbacks: Array<{
    pluginName: string;
    callback: (error?: Error) => void | Promise<void>;
  }>;
  closeBundleCallbacks: Array<{ pluginName: string; callback: () => void | Promise<void> }>;
  astFunctionHooks: HookEntry[];
  lifecycleFailures: PluginFailureResult[];
  /** plugin 의 `this.warn(...)` 누적 — build/buildSync 가 result.warnings 로 옮긴다. */
  pluginWarnings: Diagnostic[];
  /** plugin 이름별 context(`this` 바인딩) 캐시 — 한 빌드 동안 동일 plugin 은 같은 context 를 본다. */
  contexts: Map<string, RollupPluginContext>;
};

function collectPluginRegistry(plugins: ZntcPlugin[]): PluginRegistry {
  const registry: PluginRegistry = {
    hooks: {
      resolveId: [],
      load: [],
      transform: [],
      renderChunk: [],
      resolveContext: [],
    },
    generateBundleCallbacks: [],
    buildStartCallbacks: [],
    buildEndCallbacks: [],
    closeBundleCallbacks: [],
    astFunctionHooks: [],
    lifecycleFailures: [],
    pluginWarnings: [],
    contexts: new Map(),
  };

  for (const plugin of plugins) {
    const build: PluginBuild = {
      onResolve(opts, cb) {
        registry.hooks.resolveId.push({
          pluginName: plugin.name,
          filter: opts.filter,
          callback: cb,
        });
      },
      onLoad(opts, cb) {
        registry.hooks.load.push({ pluginName: plugin.name, filter: opts.filter, callback: cb });
      },
      onTransform(opts, cb) {
        registry.hooks.transform.push({
          pluginName: plugin.name,
          filter: opts.filter,
          callback: cb,
        });
      },
      onRenderChunk(opts, cb) {
        registry.hooks.renderChunk.push({
          pluginName: plugin.name,
          filter: opts.filter,
          callback: cb,
        });
      },
      onGenerateBundle(cb) {
        registry.generateBundleCallbacks.push({ pluginName: plugin.name, callback: cb });
      },
      onBuildStart(cb) {
        registry.buildStartCallbacks.push({ pluginName: plugin.name, callback: cb });
      },
      onBuildEnd(cb) {
        registry.buildEndCallbacks.push({ pluginName: plugin.name, callback: cb });
      },
      onCloseBundle(cb) {
        registry.closeBundleCallbacks.push({ pluginName: plugin.name, callback: cb });
      },
      onAstFunction(opts, cb) {
        registry.astFunctionHooks.push({
          pluginName: plugin.name,
          filter: opts.filter,
          callback: cb,
        });
      },
      onResolveContext(opts, cb) {
        registry.hooks.resolveContext.push({
          pluginName: plugin.name,
          filter: opts.filter,
          callback: cb,
        });
      },
    };
    plugin.setup(build);
  }

  return registry;
}

// hookName → { filter 대상, 콜백 인자 } 매핑
const pluginArgBuilders: Record<string, (arg1: string, arg2: string | null) => [string, unknown]> =
  {
    resolveId: (arg1, arg2) => [arg1, { path: arg1, importer: arg2 }],
    load: (arg1, _) => [arg1, { path: arg1 }],
    renderChunk: (arg1, arg2) => [arg2 ?? '', { code: arg1, chunk: arg2 }],
  };

/**
 * Dispatcher 가 한 번에 실행하고 싶은 plugin hook 호출 단위. generator 가 yield 하면
 * runner (async/sync) 가 callback 을 실제 실행하고 결과 (또는 실패) 를 다시 보낸다.
 */
type HookCall = {
  callback: () => unknown;
  pluginName: string;
  hookName: string;
  fallbackFile?: string | null;
};

/** runner 가 generator 로 돌려보내는 값: 정상 결과 또는 normalize 된 실패. */
type DispatchedHookResult = unknown | PluginFailureResult;

/**
 * lifecycle hook (generateBundle / buildStart / buildEnd / closeBundle) 의 callback 배열,
 * arg, 실패를 lifecycleFailures 로 surfacing 할지 여부를 묶어서 반환. 매칭 안 되면 null.
 */
function lifecycleHookSpec(
  reg: PluginRegistry,
  hookName: string,
  arg1: unknown,
): {
  callbacks: Array<{ pluginName: string; callback: (arg: any) => unknown }>;
  arg: unknown;
  surfaceFailures: boolean;
} | null {
  switch (hookName) {
    case 'generateBundle': {
      // NAPI 는 raw `{path, contents}` 만 노출 — plugin callback 이 `outputs[i].text` 를 쓸 수
      // 있도록 main build entry 와 동일하게 lazy getter 부착.
      const outputs = arg1 as Array<{ path: string; contents: Uint8Array }>;
      for (const file of outputs) attachTextGetter(file);
      return {
        callbacks: reg.generateBundleCallbacks,
        arg: outputs as OutputFile[],
        surfaceFailures: false,
      };
    }
    case 'buildStart':
      return { callbacks: reg.buildStartCallbacks, arg: undefined, surfaceFailures: false };
    case 'buildEnd': {
      const msg = arg1 as string;
      return {
        callbacks: reg.buildEndCallbacks,
        arg: msg && msg.length > 0 ? new Error(msg) : undefined,
        surfaceFailures: true,
      };
    }
    case 'closeBundle':
      return { callbacks: reg.closeBundleCallbacks, arg: undefined, surfaceFailures: true };
    default:
      return null;
  }
}

/**
 * plugin hook 콜백의 `this` 로 바인딩할 context 를 plugin 이름별로 캐시해 반환.
 * `this.warn(...)` 은 `reg.pluginWarnings` 로 수집되고, `this.error(...)` 는 throw 되어
 * 기존 driveDispatch* 의 normalizePluginFailure 경로를 그대로 탄다. resolve/emitFile 는 아직
 * placeholder(throw), getModuleInfo 는 surface 미추가 — 후속 PR(#1880 PR3~5)에서 채운다.
 */
function getPluginContext(reg: PluginRegistry, pluginName: string): RollupPluginContext {
  let ctx = reg.contexts.get(pluginName);
  if (!ctx) {
    ctx = createRollupPluginContext(pluginName, (d) => reg.pluginWarnings.push(d));
    reg.contexts.set(pluginName, ctx);
  }
  return ctx;
}

/**
 * Dispatcher 본체를 generator 로 작성해서 async/sync runner 가 동일 body 를 driving 한다.
 * 분기별 (astFunction / resolveContext / lifecycle / transform-chain / first-match) 결정은
 * 여기서 한 번만 정의되고 callback 실행 / Promise 처리만 runner 로 위임된다.
 */
function* dispatchHook(
  reg: PluginRegistry,
  hookName: string,
  arg1: unknown,
  arg2: string | null,
): Generator<HookCall, unknown, DispatchedHookResult> {
  // astFunction: arg1 이 JSON 직렬화된 FunctionInfo. 첫 매칭 plugin 의 non-null 반환을 채택.
  if (hookName === 'astFunction') {
    if (reg.astFunctionHooks.length === 0) return null;
    let info: AstFunctionInfo;
    try {
      info = JSON.parse(arg1 as string) as AstFunctionInfo;
    } catch {
      return null;
    }
    for (const h of reg.astFunctionHooks) {
      if (!h.filter.test(info.sourcePath)) continue;
      const result = yield {
        callback: () => h.callback.call(getPluginContext(reg, h.pluginName), info),
        pluginName: h.pluginName,
        hookName: 'astFunction',
        fallbackFile: info.sourcePath,
      };
      if (isPluginFailureResult(result)) return result;
      if (result != null) return result;
    }
    return null;
  }

  // resolveContext: arg1 = JSON({ dir, recursive, filter, flags, importer }), arg2 = null. (#1579 Phase 2.5)
  // 결과 형식: { context: string[] } — 매칭 파일 경로 배열. null/undefined 반환 시 graph 가
  // require_context_no_handler diagnostic emit.
  if (hookName === 'resolveContext') {
    if (reg.hooks.resolveContext.length === 0) return null;
    let args: {
      dir: string;
      recursive: boolean;
      filter?: string;
      flags?: string;
      importer: string;
    };
    try {
      args = JSON.parse(arg1 as string);
    } catch {
      return null;
    }
    for (const h of reg.hooks.resolveContext) {
      if (!h.filter.test(args.dir)) continue;
      const result = yield {
        callback: () => h.callback.call(getPluginContext(reg, h.pluginName), args),
        pluginName: h.pluginName,
        hookName: 'resolveContext',
        fallbackFile: args.importer,
      };
      if (isPluginFailureResult(result)) return result;
      if (result != null) return result;
    }
    return null;
  }

  // generateBundle / buildStart / buildEnd / closeBundle: filter 없이 sequential 실행.
  // 한 plugin 실패가 다른 plugin 차단 안 되도록 첫 실패만 capture 후 나머지 계속 (#1902).
  // buildEnd / closeBundle 실패는 lifecycleFailures 로만 surfacing — return value 는 항상 null
  // (native bundler 가 lifecycle hook 의 PluginFailed 를 swallow 하므로 dual channel 의미 없음).
  {
    const spec = lifecycleHookSpec(reg, hookName, arg1);
    if (spec) {
      let firstFailure: PluginFailureResult | null = null;
      for (const { pluginName, callback } of spec.callbacks) {
        const result = yield {
          callback: () => callback.call(getPluginContext(reg, pluginName), spec.arg),
          pluginName,
          hookName,
        };
        if (isPluginFailureResult(result) && firstFailure == null) firstFailure = result;
      }
      if (spec.surfaceFailures) {
        if (firstFailure) reg.lifecycleFailures.push(firstFailure);
        return null;
      }
      return firstFailure;
    }
  }

  // transform/renderChunk: 체이닝 (이전 결과의 code가 다음 입력). transform 만 source map 누적.
  if (hookName === 'transform' || hookName === 'renderChunk') {
    const hookList = reg.hooks[hookName];
    if (!hookList) return null;
    let currentCode = arg1 as string;
    let changed = false;
    const sourceMaps: string[] = [];
    for (const h of hookList) {
      if (!h.filter.test(arg2 ?? '')) continue;
      const cbArgs =
        hookName === 'transform'
          ? { code: currentCode, path: arg2 }
          : { code: currentCode, chunk: arg2 };
      const result = yield {
        callback: () => h.callback.call(getPluginContext(reg, h.pluginName), cbArgs),
        pluginName: h.pluginName,
        hookName,
        fallbackFile: arg2,
      };
      if (isPluginFailureResult(result)) return result;
      if (result != null) {
        const obj = result as { code?: unknown; map?: unknown };
        const newCode = typeof result === 'string' ? result : obj.code;
        if (typeof newCode === 'string') {
          currentCode = newCode;
          changed = true;
        }
        if (hookName === 'transform' && typeof result === 'object' && 'map' in obj) {
          const r = safeSerializeSourceMap(obj.map);
          if (!r.ok) return normalizePluginFailure(h.pluginName, hookName, r.err, arg2);
          if (r.map != null) sourceMaps.push(r.map);
        }
      }
    }
    return changed
      ? { code: currentCode, ...(sourceMaps.length > 0 ? { maps: sourceMaps } : {}) }
      : null;
  }

  // resolveId/load: 첫 번째 매칭 plugin 의 non-null 반환을 채택.
  const hookList = reg.hooks[hookName];
  if (!hookList) return null;
  const buildArgs = pluginArgBuilders[hookName];
  if (!buildArgs) return null;
  const [filterTarget, cbArgs] = buildArgs(arg1 as string, arg2);
  for (const h of hookList) {
    if (!h.filter.test(filterTarget)) continue;
    const fallbackFile = hookName === 'resolveId' ? arg2 : filterTarget;
    const result = yield {
      callback: () => h.callback.call(getPluginContext(reg, h.pluginName), cbArgs),
      pluginName: h.pluginName,
      hookName,
      fallbackFile,
    };
    if (isPluginFailureResult(result)) return result;
    if (result != null) {
      if (hookName === 'load' && typeof result === 'object' && 'map' in (result as object)) {
        const r = safeSerializeSourceMap((result as { map?: unknown }).map);
        if (!r.ok) return normalizePluginFailure(h.pluginName, hookName, r.err, fallbackFile);
        return { ...(result as object), ...(r.map != null ? { map: r.map } : { map: undefined }) };
      }
      return result;
    }
  }
  return null;
}

/** async runner — callback 을 await 하고 throw 는 normalize 한다. */
async function driveDispatchAsync(
  gen: Generator<HookCall, unknown, DispatchedHookResult>,
): Promise<unknown> {
  let r = gen.next();
  while (!r.done) {
    const call = r.value;
    let value: DispatchedHookResult;
    try {
      value = await call.callback();
    } catch (err) {
      value = normalizePluginFailure(call.pluginName, call.hookName, err, call.fallbackFile);
    }
    r = gen.next(value);
  }
  return r.value;
}

/** sync runner — Promise/thenable 반환은 plugin_error 로 즉시 변환. */
function driveDispatchSync(gen: Generator<HookCall, unknown, DispatchedHookResult>): unknown {
  let r = gen.next();
  while (!r.done) {
    const call = r.value;
    let value: DispatchedHookResult;
    try {
      const raw = call.callback();
      if (isPromiseLike(raw)) {
        silenceUnsupportedSyncPromise(raw);
        value = syncPluginPromiseFailure(call.pluginName, call.hookName, call.fallbackFile);
      } else {
        value = raw;
      }
    } catch (err) {
      value = normalizePluginFailure(call.pluginName, call.hookName, err, call.fallbackFile);
    }
    r = gen.next(value);
  }
  return r.value;
}

/**
 * plugins 배열을 처리하여 단일 dispatcher 함수를 생성한다.
 * dispatcher(hookName, arg1, arg2) → result | null
 */
function createPluginDispatcher(plugins: ZntcPlugin[]): PluginDispatcher {
  const reg = collectPluginRegistry(plugins);
  // 외부 async wrap 제거 — driveDispatchAsync 가 이미 Promise 반환. async 한 겹 더 씌우면
  // 매 호출마다 Promise 가 한 번 더 할당된다.
  const dispatcher = function dispatcher(hookName: string, arg1: unknown, arg2: string | null) {
    return driveDispatchAsync(dispatchHook(reg, hookName, arg1, arg2));
  } as PluginDispatcher;
  dispatcher.takeLifecycleFailures = () => reg.lifecycleFailures.splice(0);
  dispatcher.takePluginWarnings = () => reg.pluginWarnings.splice(0);
  return dispatcher;
}

/**
 * buildSync() 전용 dispatcher. dispatchHook generator 를 sync runner 로 driving —
 * Promise/thenable 반환은 즉시 plugin_error payload 로 변환된다.
 */
function createSyncPluginDispatcher(plugins: ZntcPlugin[]): SyncPluginDispatcher {
  const reg = collectPluginRegistry(plugins);
  const dispatcher = function dispatcher(hookName: string, arg1: unknown, arg2: string | null) {
    return driveDispatchSync(dispatchHook(reg, hookName, arg1, arg2));
  } as SyncPluginDispatcher;
  dispatcher.takeLifecycleFailures = () => reg.lifecycleFailures.splice(0);
  dispatcher.takePluginWarnings = () => reg.pluginWarnings.splice(0);
  return dispatcher;
}

/**
 * JS-only 옵션을 제거하고 NAPI에 전달할 옵션 객체를 생성한다.
 * write/outdir는 JS에서 처리, plugins는 dispatcher로 변환되므로 제거.
 * target/outfile은 Zig가 파싱하므로 그대로 전달.
 */
/**
 * Array 형태 alias (Vite `resolve.alias`, #2153) 를 onResolve plugin 으로 변환.
 * Zig native 는 array/RegExp alias 를 모르므로 host JS 에서 plugin hook 으로 위임 —
 * #1579 require.context 가 host RegExp 에 위임하는 것과 동일 패턴.
 *
 * 매칭 순서: array 순서대로 첫 매치 사용 (Vite/Webpack 동일).
 * - `find` 가 string 이면 exact + prefix 매칭 (`react` 매치는 `react/hooks` 도)
 * - `find` 가 RegExp 이면 `String.prototype.replace` 로 치환 ($1 capture group 등)
 */
function arrayAliasToPlugin(
  aliasArray: ReadonlyArray<{ find: string | RegExp; replacement: string }>,
): ZntcPlugin {
  return {
    name: 'zntc:array-alias',
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        for (const { find, replacement } of aliasArray) {
          if (find instanceof RegExp) {
            // `String.search` 는 RegExp.test 와 달리 `g`/`y` flag 의 lastIndex 를
            // mutate 하지 않는다 — 같은 alias entry 가 여러 import 에 반복 적용돼도 안전.
            if (args.path.search(find) !== -1) {
              return { path: args.path.replace(find, replacement) };
            }
          } else if (args.path === find || args.path.startsWith(find + '/')) {
            return { path: args.path.replace(find, replacement) };
          }
        }
        return null;
      });
    },
  };
}

// Array 형태 alias (#2153) 는 onResolve plugin 으로 변환해 user plugins 앞에 prepend —
// 다른 plugin 보다 먼저 매칭돼 alias 치환이 우선 적용된다 (Vite 동작).
function resolveDispatcher(options: BuildOptions, mode: 'sync'): SyncPluginDispatcher | null;
function resolveDispatcher(options: BuildOptions, mode?: 'async'): PluginDispatcher | null;
function resolveDispatcher(options: BuildOptions, mode: 'async' | 'sync' = 'async') {
  const arrayAlias = Array.isArray(options.alias) ? options.alias : null;
  const userPlugins = options.plugins ?? [];
  const allPlugins = arrayAlias ? [arrayAliasToPlugin(arrayAlias), ...userPlugins] : userPlugins;
  if (allPlugins.length === 0) return null;
  return mode === 'sync'
    ? createSyncPluginDispatcher(allPlugins)
    : createPluginDispatcher(allPlugins);
}

function isBrowserLikeBuildPlatform(platform: BuildOptions['platform'] | undefined): boolean {
  return platform === undefined || platform === 'browser' || platform === 'react-native';
}

function withDefaultBuildDefines(options: BuildOptions): Record<string, string> | undefined {
  const define = { ...options.define };
  const browserLike = isBrowserLikeBuildPlatform(options.platform) || options.minifySyntax === true;

  if (browserLike && define['process.env.NODE_ENV'] === undefined) {
    define['process.env.NODE_ENV'] = options.devMode ? '"development"' : '"production"';
  }
  if (options.platform === 'react-native' && define.__DEV__ === undefined) {
    define.__DEV__ = options.devMode ? 'true' : 'false';
  }

  return Object.keys(define).length > 0 ? define : undefined;
}

function withDefaultAppBuildDefines(options: AppBuildOptions): Record<string, string> | undefined {
  const define = { ...options.define };
  if (define['process.env.NODE_ENV'] === undefined) {
    define['process.env.NODE_ENV'] =
      (options.mode ?? 'production') === 'production' ? '"production"' : '"development"';
  }
  return define;
}

function prepareNapiOptions(options: BuildOptions): {
  napiOptions: Record<string, unknown>;
  cleanup: () => void;
} {
  const napiOptions: Record<string, unknown> = { ...options };
  const define = withDefaultBuildDefines(options);
  if (define) napiOptions.define = define;
  delete napiOptions.write;
  delete napiOptions.outdir;
  delete napiOptions.plugins;
  delete napiOptions.allowOverwrite;
  // Array 형태 alias 는 plugin 으로 위임. NAPI 로 전달하면 Zig 가
  // Record 형태만 받으므로 type mismatch — 명시 삭제.
  if (Array.isArray(napiOptions.alias)) delete napiOptions.alias;
  // manualChunks 는 `_manualChunks` 전용 슬롯으로 재전달 (plugin dispatcher 패턴).
  // napi_entry.zig 가 TSFN 으로 감싸 Zig resolver 로 변환.
  delete napiOptions.manualChunks;
  if (options.manualChunks) {
    napiOptions._manualChunks = options.manualChunks;
  }
  // PR-plumb (#3318): Module Federation. nested record(name/exposes/remotes/
  // shared/shareScope/shareStrategy)를 NAPI 로 깊게 직렬화하는 대신 JSON
  // string `mfRaw` 로 전달(transport 는 `tsconfigRaw` 와 동형 — JSON string
  // over NAPI). Zig NAPI 는 native CLI(applyZntcConfigJson)와 **동일 단일
  // 소스**(`mf_options.fromDto` + std.json `MfConfigDto`/`validateMf`)로
  // 파싱 — silent drift 봉인.
  delete napiOptions.mf;
  if (options.mf) {
    napiOptions.mfRaw = JSON.stringify(options.mf);
  }
  // blockList: RegExp는 .source로 추출해 string[]으로 넘긴다 (NAPI는 string만).
  if (options.blockList) {
    napiOptions.blockList = options.blockList.map((p) => {
      if (p instanceof RegExp) return p.source;
      if (typeof p === 'string') return p;
      throw new TypeError(`blockList entries must be RegExp or string, got ${typeof p}`);
    });
  }
  // browserslist → unsupported bitmask. transpile과 동일한 resolveUnsupported 재사용.
  if (options.browserslist) {
    napiOptions.unsupported = resolveUnsupported({ browserslist: options.browserslist });
    delete napiOptions.browserslist;
  }
  if (options.target && !isEsTarget(options.target)) {
    delete napiOptions.target;
  }
  // compiler.styledComponents / compiler.emotion → flat NAPI fields.
  // boolean 또는 객체 (세밀 제어 옵션). 현재 인식 객체 옵션: ssr.
  delete napiOptions.compiler;
  const sc = options.compiler?.styledComponents;
  if (sc !== undefined && sc !== false) {
    napiOptions.styledComponents = true;
    if (typeof sc === 'object') {
      if (sc.ssr === false) napiOptions.styledComponentsSsr = false;
      if (sc.minify === true) napiOptions.styledComponentsMinify = true;
      if (sc.fileName === false) napiOptions.styledComponentsFileName = false;
      if (sc.pure === true) napiOptions.styledComponentsPure = true;
      if (typeof sc.namespace === 'string' && sc.namespace.length > 0) {
        napiOptions.styledComponentsNamespace = sc.namespace;
      }
      if (Array.isArray(sc.meaninglessFileNames)) {
        napiOptions.styledComponentsMeaninglessFileNames = sc.meaninglessFileNames;
      }
      if (Array.isArray(sc.topLevelImportPaths)) {
        napiOptions.styledComponentsTopLevelImportPaths = sc.topLevelImportPaths;
      }
      if (sc.cssProp === true) napiOptions.styledComponentsCssProp = true;
    }
  }
  const em = options.compiler?.emotion;
  if (em !== undefined && em !== false) {
    napiOptions.emotion = true;
    if (typeof em === 'object') {
      // autoLabel: string ("never"|"always"|"dev-only") 또는 boolean (legacy false=never).
      // 누락 시 NAPI 측 default `.always`.
      if (em.autoLabel === false) {
        napiOptions.emotionAutoLabel = 'never';
      } else if (em.autoLabel === true) {
        napiOptions.emotionAutoLabel = 'always';
      } else if (typeof em.autoLabel === 'string') {
        napiOptions.emotionAutoLabel = em.autoLabel;
      }
      if (em.sourceMap === true) napiOptions.emotionSourceMap = true;
      if (typeof em.labelFormat === 'string' && em.labelFormat.length > 0) {
        napiOptions.emotionLabelFormat = em.labelFormat;
      }
      const extras = collectEmotionImportMapExtras(em.importMap);
      if (extras.css.length > 0) napiOptions.emotionExtraCssSources = extras.css;
      if (extras.styled.length > 0) napiOptions.emotionExtraStyledSources = extras.styled;
    }
  }
  const runtimePolyfills = applyRuntimePolyfillsToNapiOptions(napiOptions, {
    entryPoints: options.entryPoints,
    platform: options.platform,
    target: options.target,
    browserslist: options.browserslist,
    runtimePolyfills: options.runtimePolyfills,
    coreJs: options.coreJs,
    runBeforeMain: options.runBeforeMain,
    resolveExtensions: options.resolveExtensions,
  });
  return { napiOptions, cleanup: runtimePolyfills.cleanup };
}

/**
 * babel-plugin-emotion `importMap.canonicalImport[0]` 의 css 분류 패키지 목록.
 * Zig 측 `EMOTION_CSS_SOURCES` (`src/transformer/transformer/emotion.zig`) 와 동기화.
 */
const EMOTION_CSS_CANONICAL_SOURCES: ReadonlySet<string> = new Set([
  '@emotion/react',
  '@emotion/css',
  '@emotion/core',
  '@emotion/native',
  '@emotion/primitives',
  '@emotion/primitives-core',
]);

/**
 * babel-plugin-emotion `importMap` 의 vendored re-export 케이스를 ZNTC 의 단순화된
 * `extraCssSources` / `extraStyledSources` array 로 collapse.
 *
 * 같은 source 안에 styled / css canonicalImport 가 섞여 있으면 양쪽에 모두 등록.
 * import 인식이 source 단위라 alias-by-alias 라우팅은 미지원 — 흔치 않은 케이스라 의도적
 * 단순화 (babel parity).
 */
function collectEmotionImportMapExtras(importMap: EmotionOptions['importMap']): {
  css: string[];
  styled: string[];
} {
  const css = new Set<string>();
  const styled = new Set<string>();
  if (!importMap) return { css: [], styled: [] };
  for (const [source, locals] of Object.entries(importMap)) {
    for (const spec of Object.values(locals)) {
      const [pkg, exportName] = spec.canonicalImport;
      if (pkg === '@emotion/styled' && exportName === 'default') {
        styled.add(source);
      } else if (EMOTION_CSS_CANONICAL_SOURCES.has(pkg)) {
        css.add(source);
      }
    }
  }
  return { css: [...css], styled: [...styled] };
}

/**
 * CSS 출력 파일을 Lightning CSS로 후처리한다 (minify, 프리픽스 등).
 * lightningcss가 설치되어 있지 않으면 원본 그대로 반환.
 */
function postProcessCssOutputs(result: BuildResult, options: BuildOptions): void {
  if (!options.minify) return;

  // lightningcss 는 optionalDependencies — 런타임에만 로드하므로 타입을 any 로.
  // `typeof import("lightningcss")` 를 쓰면 tsc strict 모드에서 모듈 resolution 이
  // 실패해 소비자측 `tsc --emitDeclarationOnly` 가 깨짐. 이 함수 내부만 영향.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let lcss: any;
  try {
    lcss = require('lightningcss');
  } catch {
    return; // lightningcss 미설치 — raw CSS 그대로 반환
  }

  for (const file of result.outputFiles) {
    if (!file.path.endsWith('.css')) continue;
    try {
      const transformed = lcss.transform({
        code: file.contents,
        minify: true,
        filename: file.path,
      });
      // lightningcss 결과는 Buffer (Uint8Array). attachTextGetter 가 reference
      // 비교로 cached text 를 자동 invalidate.
      file.contents = transformed.code;
    } catch {
      // CSS 변환 실패 시 원본 유지
    }
  }
}

/**
 * write/outdir/outfile 옵션에 따라 빌드 결과를 디스크에 기록한다.
 */
function writeOutputFiles(result: BuildResult, options: BuildOptions): void {
  const shouldWrite = options.write ?? (options.outdir != null || options.outfile != null);
  if (!shouldWrite) return;

  // allowOverwrite 체크: 입력 파일과 동일 경로에 출력 방지
  if (!options.allowOverwrite && options.outfile) {
    const outResolved = resolve(options.outfile);
    for (const entry of options.entryPoints) {
      if (resolve(entry) === outResolved) {
        throw new Error(
          `@zntc/core: output file '${options.outfile}' would overwrite input file (set allowOverwrite: true to permit)`,
        );
      }
    }
  }

  const createdDirs = new Set<string>();
  const outfileResolved = options.outfile ? resolve(options.outfile) : null;

  for (const file of result.outputFiles) {
    let outPath: string;
    if (outfileResolved && file.path === 'bundle.js') {
      // 메인 번들 → outfile 경로로 출력
      outPath = outfileResolved;
    } else if (outfileResolved && file.path.endsWith('.map')) {
      // 소스맵 → outfile 옆에 .map으로 출력
      outPath = outfileResolved + '.map';
    } else if (options.outdir) {
      outPath = join(resolve(options.outdir), file.path);
    } else {
      outPath = resolve(file.path);
    }
    const dir = dirname(outPath);
    if (!createdDirs.has(dir)) {
      mkdirSync(dir, { recursive: true });
      createdDirs.add(dir);
    }
    // file.contents 는 Uint8Array (NAPI buffer copy). Node fs.writeFileSync 는
    // Uint8Array/Buffer 를 그대로 syscall 로 전달 — utf-8 encode 비용 없음.
    writeFileSync(outPath, file.contents);
  }
}

/**
 * Runs bundling asynchronously. Does not block the event loop.
 * Promise/async hooks of JS plugins are supported in this function.
 *
 * Plugin lifecycle call order: buildStart → (NAPI build) → buildEnd → write →
 * closeBundle.
 * `buildEnd` is called even on NAPI failure, with the error argument passed
 * (same as Rollup).
 * `closeBundle` is called only on a successful write.
 */
export async function build(options: BuildOptions): Promise<BuildResult> {
  const n = ensureNative();
  if (!options.entryPoints?.length) throw new Error('@zntc/core: entryPoints is required');
  validateTsConfigRaw(options.tsconfigRaw);

  if (options.output && options.output.length >= 2) {
    return buildMultiFormat(options);
  }

  const { napiOptions, cleanup } = prepareNapiOptions(options);
  const dispatcher = resolveDispatcher(options);
  if (dispatcher) napiOptions._pluginDispatcher = dispatcher;

  // lifecycle hook (#2156): buildStart / buildEnd 는 native bundler 가 dispatch (single source).
  // JS 측에서 별도 호출 시 이중 발화. 단 closeBundle 은 Rollup 의미 ("write 완료 후") 보존을
  // 위해 writeOutputFiles 다음에 JS layer 가 직접 호출 — native bundle() 끝 시점은 contents
  // 결정 직후라 disk write *전* 이므로 closeBundle 자리 부적합.
  try {
    const result: BuildResult = wrapOutputFiles(await n.build(napiOptions));
    if (dispatcher) {
      for (const failure of dispatcher.takeLifecycleFailures()) {
        result.errors.push(pluginFailureToDiagnostic(failure));
      }
      for (const warning of dispatcher.takePluginWarnings()) {
        result.warnings.push(warning);
      }
    }

    postProcessCssOutputs(result, options);
    writeOutputFiles(result, options);

    if (dispatcher) {
      await dispatcher('closeBundle', undefined, null);
      for (const failure of dispatcher.takeLifecycleFailures()) {
        result.errors.push(pluginFailureToDiagnostic(failure));
      }
      for (const warning of dispatcher.takePluginWarnings()) {
        result.warnings.push(warning);
      }
    }
    return result;
  } finally {
    cleanup();
  }
}

/**
 * Runs bundling synchronously.
 * JS plugins support only sync hooks. Promise/async hooks fail with a
 * plugin_error.
 */
export function buildSync(options: BuildOptions): BuildResult {
  const n = ensureNative();
  if (!options.entryPoints?.length) throw new Error('@zntc/core: entryPoints is required');
  validateTsConfigRaw(options.tsconfigRaw);

  const { napiOptions, cleanup } = prepareNapiOptions(options);
  const dispatcher = resolveDispatcher(options, 'sync');
  if (dispatcher) napiOptions._pluginDispatcherSync = dispatcher;
  try {
    const result: BuildResult = wrapOutputFiles(n.buildSync(napiOptions));
    if (dispatcher) {
      for (const failure of dispatcher.takeLifecycleFailures()) {
        result.errors.push(pluginFailureToDiagnostic(failure));
      }
      for (const warning of dispatcher.takePluginWarnings()) {
        result.warnings.push(warning);
      }
    }
    postProcessCssOutputs(result, options);
    writeOutputFiles(result, options);
    if (dispatcher) {
      dispatcher('closeBundle', undefined, null);
      for (const failure of dispatcher.takeLifecycleFailures()) {
        result.errors.push(pluginFailureToDiagnostic(failure));
      }
      for (const warning of dispatcher.takePluginWarnings()) {
        result.warnings.push(warning);
      }
    }
    return result;
  } finally {
    cleanup();
  }
}

/// rollup-style per-output options. `BuildInstance.write/generate` 호출 시 input 옵션과
/// merge 되어 native 호출. 미지정 필드는 base BuildOptions 의 값을 사용.
export interface OutputOptions {
  format?: 'esm' | 'cjs' | 'iife' | 'umd' | 'amd';
  dir?: string;
  file?: string;
  /// IIFE/UMD/AMD external → factory param 이름. rollup `output.globals` 호환.
  globals?: Record<string, string>;
}

/// rollup/rolldown 스타일 build instance. `await zntc(options)` 로 생성, `.write(output)` /
/// `.generate(output)` 다회 호출 후 `.close()`. multi-format 빌드 패턴 우선, lifecycle
/// 훅 (watch/incremental 후속) 의 anchor.
///
/// 주의: 현재 native 측 graph cache 미보유 — `.write()` 매 호출이 graph 재빌드. multi-format
/// 효율 우선이면 `build({ output: [...] })` (esbuild-style) 사용.
export class BuildInstance {
  #base: BuildOptions;
  #closed: boolean = false;
  constructor(base: BuildOptions) {
    this.#base = base;
  }
  get closed(): boolean {
    return this.#closed;
  }
  async write(output: OutputOptions = {}): Promise<BuildResult> {
    this.#assertOpen();
    return build(mergeOutput(this.#base, output));
  }
  async generate(output: OutputOptions = {}): Promise<BuildResult> {
    this.#assertOpen();
    return build({ ...mergeOutput(this.#base, output), write: false } as BuildOptions);
  }
  async close(): Promise<void> {
    this.#closed = true;
  }
  #assertOpen(): void {
    if (this.#closed) throw new Error('@zntc/core: BuildInstance is closed');
  }
}

function mergeOutput(base: BuildOptions, out: OutputOptions): BuildOptions {
  const merged: any = { ...base };
  if (out.format !== undefined) merged.format = out.format;
  if (out.dir !== undefined) merged.outdir = out.dir;
  if (out.file !== undefined) merged.outfile = out.file;
  if (out.globals !== undefined) merged.globals = out.globals;
  return merged as BuildOptions;
}

/// rollup/rolldown 스타일 entry — `zntc(input).write(output).close()`. Graph 재사용은
/// 향후 native ScanStageCache 도입 시 추가 (현재는 매 write 가 graph 재빌드).
export async function zntc(options: BuildOptions): Promise<BuildInstance> {
  if (!options.entryPoints?.length) throw new Error('@zntc/core: entryPoints is required');
  validateTsConfigRaw(options.tsconfigRaw);
  return new BuildInstance(options);
}

/// esbuild-style `build({output:[...]})` sugar — internal 으로 format 별 build() N회 호출 후
/// outputsByFormat 으로 묶음. PR-I (#3561) 진입점. graph 재사용은 별도 epic.
async function buildMultiFormat(options: BuildOptions): Promise<BuildResult> {
  const outputs = options.output!;
  const { output: _omit, ...baseOpts } = options as BuildOptions & { output?: OutputOptions[] };

  const aggregated: BuildResult = {
    outputFiles: [],
    errors: [],
    warnings: [],
    outputsByFormat: [],
  };

  for (const cfg of outputs) {
    const r = await build(mergeOutput(baseOpts as BuildOptions, cfg));
    aggregated.errors.push(...r.errors);
    aggregated.warnings.push(...r.warnings);
    aggregated.outputsByFormat!.push({
      format: cfg.format ?? 'esm',
      outputFiles: r.outputFiles,
    });
  }

  // backward-compat: 첫 entry 의 결과를 outputFiles 에 alias.
  if (aggregated.outputsByFormat!.length > 0) {
    aggregated.outputFiles = aggregated.outputsByFormat![0].outputFiles;
  }

  return aggregated;
}

export function buildAppSync(options: AppBuildOptions = {}): BuildResult {
  const n = ensureNative();
  const { publicDir, compiler, ...rest } = options;
  return wrapOutputFiles(
    n.buildAppSync({
      ...rest,
      define: withDefaultAppBuildDefines(options),
      ...(publicDir === false
        ? { disablePublicDir: true }
        : publicDir !== undefined
          ? { publicDir }
          : {}),
      // compiler.* → flat NAPI fields. `prepareNapiOptions` 와 동일 변환을 한 곳에서.
      ...buildCompilerNapiFields(compiler),
    }),
  );
}

/// `compiler.styledComponents` / `compiler.emotion` (boolean / 객체 form) 를 평면 NAPI
/// 필드로 변환. `prepareNapiOptions` (buildSync) 와 `buildAppSync` 양쪽이 공유.
function buildCompilerNapiFields(compiler: AppBuildOptions['compiler']): Record<string, unknown> {
  const out: Record<string, unknown> = {};

  const sc = compiler?.styledComponents;
  if (sc !== undefined && sc !== false) out.styledComponents = true;
  if (typeof sc === 'object') {
    if (sc.ssr === false) out.styledComponentsSsr = false;
    if (sc.minify === true) out.styledComponentsMinify = true;
    if (sc.fileName === false) out.styledComponentsFileName = false;
    if (sc.pure === true) out.styledComponentsPure = true;
    if (typeof sc.namespace === 'string' && sc.namespace.length > 0) {
      out.styledComponentsNamespace = sc.namespace;
    }
    if (Array.isArray(sc.meaninglessFileNames)) {
      out.styledComponentsMeaninglessFileNames = sc.meaninglessFileNames;
    }
    if (Array.isArray(sc.topLevelImportPaths)) {
      out.styledComponentsTopLevelImportPaths = sc.topLevelImportPaths;
    }
    if (sc.cssProp === true) out.styledComponentsCssProp = true;
  }

  const em = compiler?.emotion;
  if (em !== undefined && em !== false) out.emotion = true;
  if (typeof em === 'object') {
    if (em.autoLabel === false) out.emotionAutoLabel = 'never';
    else if (em.autoLabel === true) out.emotionAutoLabel = 'always';
    else if (typeof em.autoLabel === 'string') out.emotionAutoLabel = em.autoLabel;
    if (em.sourceMap === true) out.emotionSourceMap = true;
    if (typeof em.labelFormat === 'string' && em.labelFormat.length > 0) {
      out.emotionLabelFormat = em.labelFormat;
    }
    const extras = collectEmotionImportMapExtras(em.importMap);
    if (extras.css.length > 0) out.emotionExtraCssSources = extras.css;
    if (extras.styled.length > 0) out.emotionExtraStyledSources = extras.styled;
  }

  return out;
}

export function prepareAppDevSync(options: AppDevPrepareOptions = {}): AppDevPrepareResult {
  const n = ensureNative();
  const { publicDir, ...rest } = options;
  return n.prepareAppDevSync({
    ...rest,
    ...(publicDir === false
      ? { disablePublicDir: true }
      : publicDir !== undefined
        ? { publicDir }
        : {}),
  });
}

/**
 * Releases resources (the NAPI module is released automatically on process
 * exit). Kept for API compatibility.
 */
export function close(): void {
  native = null;
}

// ─── Benchmark API (CLI `zntc bench` 의 NAPI 대응) ───

/**
 * Benchmark options. One of `source` or `file` must be specified.
 */
export interface BenchmarkOptions {
  /** Source code string (one of this or file). */
  source?: string;
  /** File path (one of this or source). */
  file?: string;
  /** filename (used together with source, for extension detection). */
  filename?: string;
  /**
   * List of profile categories to measure (required, non-empty).
   * e.g. `["parse"]`, `["scan", "parse", "transform"]`, `["transform.jsx"]`.
   * `all` / `none` are not allowed — concrete phase names only.
   */
  phases: string[];
  /** Number of iterations (default 100). */
  iterations?: number;
  /** Warmup iterations (default 10). */
  warmup?: number;
}

/**
 * Statistics for a single phase (all values in ms).
 */
export interface BenchmarkPhaseStats {
  samples: number;
  mean_ms: number;
  median_ms: number;
  p95_ms: number;
  p99_ms: number;
  min_ms: number;
  max_ms: number;
  stddev_ms: number;
}

/**
 * Benchmark result — statistics per category specified in the `phases` option.
 */
export interface BenchmarkResult {
  phases: Record<string, BenchmarkPhaseStats>;
}

/**
 * Runs a specific phase N times and returns statistics
 * (mean/median/p95/p99/stddev/min/max).
 *
 * The NAPI counterpart of CLI `zntc bench --phase=...` — uses the same engine.
 *
 * @example
 * ```ts
 * import { benchmark } from "@zntc/core";
 *
 * const result = benchmark({
 *   file: "./src/App.tsx",
 *   phases: ["parse"],
 *   iterations: 100,
 * });
 * console.log(result.phases.parse.mean_ms);  // 42.3
 * ```
 */
export function benchmark(options: BenchmarkOptions): BenchmarkResult {
  if (!options.source && !options.file) {
    throw new Error("@zntc/core.benchmark: 'source' or 'file' is required");
  }
  if (!Array.isArray(options.phases) || options.phases.length === 0) {
    throw new Error("@zntc/core.benchmark: 'phases' must be a non-empty string array");
  }
  return ensureNative().benchmark({
    source: options.source,
    file: options.file,
    filename: options.filename ?? 'input.js',
    phases: options.phases,
    iterations: options.iterations ?? 100,
    warmup: options.warmup ?? 10,
  });
}

// ─── Vite/Rollup 플러그인 어댑터 ───

/**
 * Converts a Rollup/Vite-style plugin into a ZNTC plugin.
 *
 * @example
 * ```ts
 * import { vitePlugin } from "@zntc/core";
 *
 * const result = await build({
 *   entryPoints: ["src/index.ts"],
 *   plugins: [
 *     vitePlugin({
 *       name: "my-rollup-plugin",
 *       resolveId(source) { ... },
 *       load(id) { ... },
 *       transform(code, id) { ... },
 *     }),
 *   ],
 * });
 * ```
 */

type MaybePromise<T> = T | Promise<T>;

/** vite 4+ 신형 hook object. plugin 작성자가 hook 단위로 filter 를 선언하는 형식.
 *  ZNTC 는 현재 filter 를 native 단계에서 활용하지 않고 handler 만 추출해 호출한다. */
type HookObject<F extends (...args: never[]) => unknown> = {
  filter?: unknown;
  order?: 'pre' | 'post' | null;
  handler: F;
};

type Hook<F extends (...args: never[]) => unknown> = F | HookObject<F>;

function extractHandler<F extends (...args: never[]) => unknown>(
  hook: Hook<F> | undefined,
): F | undefined {
  if (hook == null) return undefined;
  if (typeof hook === 'function') return hook;
  if (typeof hook === 'object' && typeof (hook as HookObject<F>).handler === 'function') {
    return (hook as HookObject<F>).handler;
  }
  return undefined;
}

export interface RollupPluginContext {
  /** Throw an error from within the plugin. Rollup `this.error`-compatible. */
  error(error: unknown): never;
  /** Print a warning to the console. Rollup `this.warn`-compatible — does not stop the build. */
  warn(message: unknown): void;
  /** Register an additional file to watch in watch mode. Currently a no-op (graph mutation not supported). */
  addWatchFile(id: string): void;
  /** Module resolve. Currently unsupported — throws an Error when called to notify the plugin author. */
  resolve(
    source: string,
    importer?: string | null,
    options?: unknown,
  ): Promise<{ id: string; external?: boolean } | null>;
  /** Emit an additional asset/chunk. Currently unsupported — throws an Error when called. */
  emitFile(file: unknown): string;
}

type ResolveIdResult = string | null | undefined | void | { id: string; external?: boolean };
type LoadResult = string | null | undefined | void | { code: string; map?: unknown };
type TransformResult = string | null | undefined | void | { code: string; map?: unknown };
type RenderChunkResult = string | null | undefined | void | { code: string };

export interface RollupPlugin {
  name: string;
  /** Rollup `resolveId`. Both a function and a vite 4+ new-style hook object `{ filter, handler }` are allowed. */
  resolveId?: Hook<
    (
      this: RollupPluginContext,
      source: string,
      importer?: string | null,
    ) => MaybePromise<ResolveIdResult>
  >;
  load?: Hook<(this: RollupPluginContext, id: string) => MaybePromise<LoadResult>>;
  transform?: Hook<
    (this: RollupPluginContext, code: string, id: string) => MaybePromise<TransformResult>
  >;
  renderChunk?: Hook<
    (this: RollupPluginContext, code: string, chunk: string) => MaybePromise<RenderChunkResult>
  >;
  generateBundle?: Hook<(this: RollupPluginContext, outputs: OutputFile[]) => MaybePromise<void>>;
  /** Once at bundle start. esbuild `onStart` / Rollup `buildStart`-compatible
   *  (#2156). ZNTC calls it with no arguments (esbuild style) — if a Rollup
   *  plugin expects the `options` argument, capture it in the plugin's own
   *  closure. */
  buildStart?: Hook<(this: RollupPluginContext) => MaybePromise<void>>;
  /** Once at bundle end. Rollup `buildEnd`-compatible — if there is an error, the build fails. */
  buildEnd?: Hook<(this: RollupPluginContext, error?: Error) => MaybePromise<void>>;
  /** After output files are written. Rollup `closeBundle`-compatible. */
  closeBundle?: Hook<(this: RollupPluginContext) => MaybePromise<void>>;
}

/** ZNTC native source-map parser 가 요구하는 V3 필드(version=3, sources array, mappings string)
 *  를 사전 검증한 후 `serializePluginSourceMap` 에 위임해 정규화. 일부 plugin (vue/svelte 등) 이
 *  `null` mappings · sources 누락된 sparse map 또는 `"3"` string version 을 반환할 수 있어
 *  V3 명세에 너그럽게 coerce 한다. 검증 실패 시 map 을 drop 하고 `onDrop` 으로 1회 알린다
 *  (조용히 drop 하면 plugin 작성자가 sourcemap 누락 원인을 추적 불가). */
function normalizeVitePluginSourceMap(
  map: unknown,
  onDrop: (reason: string) => void,
): string | undefined {
  if (map == null) return undefined;
  if (typeof map === 'object') {
    const obj = map as Record<string, unknown>;
    const ver = typeof obj.version === 'string' ? Number(obj.version) : obj.version;
    if (ver !== 3) {
      onDrop(`version=${String(obj.version)} (expected 3)`);
      return undefined;
    }
    if (!Array.isArray(obj.sources)) {
      onDrop(`missing sources array`);
      return undefined;
    }
    if (typeof obj.mappings !== 'string') {
      onDrop(`missing mappings string`);
      return undefined;
    }
  }
  try {
    return serializePluginSourceMap(map) ?? undefined;
  } catch (err) {
    onDrop(err instanceof Error ? err.message : String(err));
    return undefined;
  }
}

/**
 * @param onWarn `this.warn(...)` 을 받을 sink. native plugin dispatcher 는 이를 전달해
 *   경고를 `result.warnings` 로 surfacing 한다. 미전달 시(예: vitePlugin 어댑터) console.warn fallback.
 */
function createRollupPluginContext(
  pluginName: string,
  onWarn?: (diagnostic: Diagnostic) => void,
): RollupPluginContext {
  return {
    error(error: unknown): never {
      throw error;
    },
    warn(message: unknown): void {
      const text = `@zntc/core [${pluginName}]: ${typeof message === 'string' ? message : String(message)}`;
      if (onWarn) onWarn({ text });
      else console.warn(text);
    },
    addWatchFile(_id: string): void {
      // no-op: ZNTC 는 plugin 이 알려준 추가 watch 파일을 native watcher 에 전파하는 surface 가
      // 아직 없다. 대부분 transform 의 부수 dep 추적용이라 source change 자체로 잡힌다.
      // SFC 의 `<style src="./x.css">` 같은 *외부* 파일 변경은 stale 캐시 가능 — 회귀 시 별도
      // surface 필요.
    },
    resolve(_source, _importer, _options): Promise<never> {
      // tsc 가 `Promise<never>` declared return 에서 sync `this.error(...)` (never) 만 있을 때
      // reachable end point 검사를 통과시키지 못해 직접 throw 로 시그니처와 일치시킨다.
      throw new Error(
        `@zntc/core [${pluginName}]: this.resolve() is not supported by vitePlugin() adapter yet ` +
          `(graph mutation surface missing). Use alias config or another plugin's resolveId hook.`,
      );
    },
    emitFile(_file): never {
      throw new Error(
        `@zntc/core [${pluginName}]: this.emitFile() is not supported by vitePlugin() adapter yet.`,
      );
    },
  };
}

/** 동일 plugin 의 동일 sourcemap drop reason 은 한 번만 warn — vue/svelte SFC 처럼 모듈 N 개에서
 *  같은 메시지가 반복되면 콘솔이 노이즈로 가득 차 원인을 가린다. */
function createDropWarner(context: RollupPluginContext): (reason: string) => void {
  const seen = new Set<string>();
  return (reason) => {
    if (seen.has(reason)) return;
    seen.add(reason);
    context.warn(`sourcemap dropped: ${reason}`);
  };
}

export function vitePlugin(rollupPlugin: RollupPlugin): ZntcPlugin {
  return {
    name: rollupPlugin.name,
    setup(build) {
      const context = createRollupPluginContext(rollupPlugin.name);
      const onDropSourceMap = createDropWarner(context);
      const resolveId = extractHandler(rollupPlugin.resolveId);
      if (resolveId) {
        build.onResolve({ filter: /.*/ }, (args) => {
          const result = resolveId.call(context, args.path, args.importer);
          return mapMaybePromise(result, (result) => {
            if (result == null) return null;
            if (typeof result === 'string') return { path: result };
            if (typeof result === 'object' && 'id' in result) {
              return { path: result.id, external: result.external };
            }
            return null;
          });
        });
      }

      const load = extractHandler(rollupPlugin.load);
      if (load) {
        build.onLoad({ filter: /.*/ }, (args) => {
          const result = load.call(context, args.path);
          return mapMaybePromise(result, (result) => {
            if (result == null) return null;
            if (typeof result === 'string') return { contents: result };
            if (typeof result === 'object' && 'code' in result) {
              return {
                contents: result.code,
                map: normalizeVitePluginSourceMap(result.map, onDropSourceMap),
              };
            }
            return null;
          });
        });
      }

      const transform = extractHandler(rollupPlugin.transform);
      if (transform) {
        build.onTransform({ filter: /.*/ }, (args) => {
          const result = transform.call(context, args.code, args.path);
          return mapMaybePromise(result, (result) => {
            if (result == null) return null;
            if (typeof result === 'string') return { code: result };
            if (typeof result === 'object' && 'code' in result) {
              return {
                code: result.code,
                map: normalizeVitePluginSourceMap(result.map, onDropSourceMap),
              };
            }
            return null;
          });
        });
      }

      const renderChunk = extractHandler(rollupPlugin.renderChunk);
      if (renderChunk) {
        build.onRenderChunk({ filter: /.*/ }, (args) => {
          const result = renderChunk.call(context, args.code, args.chunk);
          return mapMaybePromise(result, (result) => {
            if (result == null) return null;
            if (typeof result === 'string') return { code: result };
            if (typeof result === 'object' && 'code' in result) {
              return { code: result.code };
            }
            return null;
          });
        });
      }

      const generateBundle = extractHandler(rollupPlugin.generateBundle);
      if (generateBundle) {
        build.onGenerateBundle((outputs) => generateBundle.call(context, outputs));
      }

      const buildStart = extractHandler(rollupPlugin.buildStart);
      if (buildStart) {
        build.onBuildStart(() => buildStart.call(context));
      }

      const buildEnd = extractHandler(rollupPlugin.buildEnd);
      if (buildEnd) {
        build.onBuildEnd((err) => buildEnd.call(context, err));
      }

      const closeBundle = extractHandler(rollupPlugin.closeBundle);
      if (closeBundle) {
        build.onCloseBundle(() => closeBundle.call(context));
      }
    },
  };
}

/**
 * Bundles in watch mode. On file changes: incremental rebuild + HMR diff.
 * Calls the onReady callback when the initial build completes, and onRebuild
 * on each rebuild.
 *
 * Plugin lifecycle call order: buildStart → (NAPI build/rebuild) → buildEnd
 * → onReady/onRebuild → closeBundle. closeBundle is called even if there is no
 * callback or it throws.
 */
export function watch(options: BuildOptions): WatchHandle {
  const n = ensureNative();

  const { napiOptions: nativeOpts, cleanup } = prepareNapiOptions(options);
  const dispatcher = resolveDispatcher(options);

  if (dispatcher) {
    nativeOpts._pluginDispatcher = dispatcher;

    // native 측은 onReady/onRebuild 결과 promise 를 await 하지 않으므로 모든 rejection 을
    // swallow — 그렇지 않으면 user callback throw 와 closeBundle dispatch 실패가
    // unhandledRejection 으로 샌다. build() 는 await 가능해 이 래핑이 필요 없다.
    const dispatchCloseBundle = () => {
      void dispatcher('closeBundle', undefined, null)
        .catch(() => {})
        .finally(() => {
          // watch 는 BuildResult 가 없어 plugin 의 this.warn 을 result.warnings 로 옮길 곳이 없다.
          // drain 하지 않으면 reg.pluginWarnings 가 rebuild 마다 무한 누적(누수)되고, onWarn sink
          // 때문에 console 에도 안 뜬다. rebuild 마다 비우면서 console 로 surfacing 한다.
          for (const w of dispatcher.takePluginWarnings()) console.warn(w.text);
        });
    };
    const wrapWatchCallback =
      <T>(callback?: (event: T) => void | Promise<void>) =>
      (event: T) => {
        void Promise.resolve()
          .then(() => callback?.(event))
          .finally(dispatchCloseBundle)
          .catch(() => {});
      };

    nativeOpts.onReady = wrapWatchCallback(options.onReady);
    nativeOpts.onRebuild = wrapWatchCallback(options.onRebuild);
  }

  let handle: WatchHandle;
  try {
    handle = n.watch(nativeOpts);
  } catch (err) {
    cleanup();
    throw err;
  }
  return {
    stop() {
      try {
        handle.stop();
      } finally {
        cleanup();
      }
    },
    getBundleSourceMap() {
      return handle.getBundleSourceMap();
    },
    getHmrSourceMap(moduleId: string) {
      return handle.getHmrSourceMap(moduleId);
    },
  };
}
