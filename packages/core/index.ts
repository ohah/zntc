/**
 * @zts/core — ZTS TypeScript 트랜스파일러 네이티브 NAPI 바인딩
 *
 * Node.js, Bun, Deno 모두 지원하는 NAPI 네이티브 모듈.
 * 전역 상태 없이 JS 힙에 직접 결과를 반환한다.
 *
 * @example
 * ```ts
 * import { init, transpile } from "@zts/core";
 * init();
 * const result = transpile("const x: number = 1;", { filename: "input.ts" });
 * console.log(result.code);
 * ```
 */

import { createRequire } from "module";
import { existsSync, mkdirSync, writeFileSync } from "fs";
import { join, dirname, resolve } from "path";
import { fileURLToPath } from "url";

export type { Target, Platform, TranspileOptions, TranspileResult } from "../shared/index";
import type { TranspileOptions, TranspileResult } from "../shared/index";
import { buildOptionsJson, ES_TARGET_BITS, browserslistToUnsupported } from "../shared/index";

// ─── NAPI Module ───

interface OutputFile {
  path: string;
  text: string;
  /** code splitting 시 이 chunk 에 포함된 모듈 절대경로 (rolldown `chunk.moduleIds` 호환).
   * 단일 번들 / asset output 은 빈 배열. */
  moduleIds?: string[];
  /** 이 chunk 가 export 하는 심볼 이름 목록 (cross-chunk 검증용). */
  exports?: string[];
  /** 이 chunk 가 import 하는 다른 chunk 의 최종 filename 배열 (rolldown `chunk.imports` 호환).
   * content-hash 까지 확정된 경로. */
  imports?: string[];
}

interface Diagnostic {
  text: string;
  location?: { file: string };
}

interface NativeBuildResult {
  outputFiles: OutputFile[];
  errors: Diagnostic[];
  warnings: Diagnostic[];
  metafile?: string;
  moduleCodes?: Array<{ id: string; code: string }>;
  modulePaths?: string[];
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

interface NativeModule {
  transpile(
    source: string,
    filename: string,
    optionsJson: string,
  ): { code: string; map?: string; errors?: string };
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

function findAddon(): string {
  const __dirname = dirname(fileURLToPath(import.meta.url));

  // 1. zig-out 빌드 산출물 우선 (개발 시 항상 최신 바이너리 사용)
  const zigOut = join(__dirname, "../../zig-out/lib/zts.node");
  if (existsSync(zigOut)) return zigOut;

  // 2. dist에서 3단계 위 (packages/core/dist/ → zig-out/lib/)
  const zigOut2 = join(__dirname, "../../../zig-out/lib/zts.node");
  if (existsSync(zigOut2)) return zigOut2;

  // 3. 같은 디렉토리 (npm 배포 패키지)
  const local = join(__dirname, "zts.node");
  if (existsSync(local)) return local;

  // 4. 한 단계 위 (dist/index.js에서 사용 시)
  const parent = join(__dirname, "../zts.node");
  if (existsSync(parent)) return parent;

  throw new Error("@zts/core: zts.node not found. Run `zig build napi` first.");
}

// ─── Public API ───

/**
 * `zts.config.{ts,js}` 타입 체크/자동완성용 identity 헬퍼.
 *
 * 객체 또는 함수형 config 둘 다 지원:
 * ```ts
 * export default defineConfig({ format: "esm" });
 * export default defineConfig(({ command, mode, env }) => ({
 *   format: "esm",
 *   minify: command === "bundle",
 * }));
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
} from "./src/config-loader.ts";
export type {
  ConfigEnv,
  ModuleKind,
  UserConfig,
  UserConfigFn,
  UserConfigInput,
} from "./src/config-loader.ts";
export { envToDefine, loadEnv } from "./src/load-env.ts";
export { KNOWN_CONFIG_KEYS, suggestKey, warnUnknownKeys } from "./src/typo-suggest.ts";
export {
  defineWorkspace,
  filterWorkspaces,
  findWorkspacePath,
  identifyWorkspaceEntries,
  loadIdentifiedConfig,
  loadWorkspace,
  WORKSPACE_EXT_PRIORITY,
} from "./src/workspace.ts";
export type {
  IdentifiedWorkspace,
  Workspace,
  WorkspaceEntry,
  WorkspaceEntryInline,
  WorkspaceEntryPath,
  WorkspaceFn,
  WorkspaceInput,
} from "./src/workspace.ts";

import type { UserConfigInput } from "./src/config-loader.ts";

/**
 * NAPI 모듈을 로드한다.
 * 이미 로드된 경우 무시한다.
 */
export function init(addonPath?: string): void {
  if (native) return;
  const path = addonPath ?? findAddon();
  const require = createRequire(import.meta.url);
  native = require(path) as NativeModule;
}

/**
 * TypeScript/JSX 소스 코드를 트랜스파일한다.
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
    // 미설치여도 zts 자체는 로드 가능 (optional dep).
    const req = createRequire(import.meta.url);
    const name = "browserslist";
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
        "@zts/core: 'browserslist' option requires the 'browserslist' package. Install it: bun add browserslist",
      );
    }
    return browserslistToUnsupported(bl(options.browserslist));
  }
  return options.target ? (ES_TARGET_BITS[options.target] ?? 0) : 0;
}

export function transpile(source: string, options: TranspileOptions = {}): TranspileResult {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!source) throw new Error("@zts/core: empty source");

  const optionsJson = buildOptionsJson(options, resolveUnsupported(options));
  return native.transpile(source, options.filename ?? "input.js", optionsJson);
}

// ─── Build API ───

export type { OutputFile, Diagnostic };

/** Rollup `manualChunks(id, meta)` 의 `meta.getModuleInfo(id)` 반환. */
export interface ManualChunksModuleInfo {
  id: string;
  isEntry: boolean;
  /** `external` 패턴 매칭으로 번들에 포함되지 않는 모듈. AST/source 없음 — graph
   * traversal 1급 노드로만 노출됨. */
  isExternal: boolean;
  /** 모듈이 side effect 를 가질 수 있는지 (Rollup `hasModuleSideEffects` 호환).
   * `package.json` `sideEffects` 필드 또는 `treeShaking.moduleSideEffects` 옵션으로 결정.
   * `false` 면 unused 시 tree-shaker 가 제거 가능. */
  hasModuleSideEffects: boolean;
  /** 모듈 source 코드 (Rollup `code` 호환).
   * external / asset / 미파싱 모듈은 null. UTF-8 디코딩 실패 시도 null. */
  code: string | null;
  /** tree-shake 후 번들에 포함된 모듈인지 (Rollup `isIncluded` 호환).
   * `treeShaking: false` 일 땐 모든 모듈이 false 처럼 보일 수 있음 — Module 의 mirror flag 라
   * tree-shaker 가 안 돌면 기본값 그대로. */
  isIncluded: boolean;
  /** 이 모듈이 export 하는 이름 목록 (Rollup `exports` 호환). default / re-export 별표 모두 포함.
   * external 은 빈 배열 (graph 가 export 정보 없음). */
  exports: string[];
  /** Plugin 이 정의한 synthetic named exports (Rollup `syntheticNamedExports` 호환).
   * ZTS 는 plugin context API 확장 (#1880) 까지 항상 false. */
  syntheticNamedExports: boolean;
  /** `this.emitFile` 의 `implicitlyLoadedAfterOneOf` 옵션 결과 (Rollup 호환).
   * ZTS plugin context API (#1880) 까지 항상 빈 배열. */
  implicitlyLoadedAfterOneOf: string[];
  /** 위와 반대 방향 — 이 모듈을 implicitly 로드 후에 로드돼야 하는 모듈들. */
  implicitlyLoadedBefore: string[];
  /** 이 모듈을 static import 하는 모듈들. external 도 importer 목록에 포함됨
   * (자기 자신은 external 일 때 in-graph 모듈이 importer). */
  importers: string[];
  /** 이 모듈을 dynamic import (`import()`) 하는 모듈들. */
  dynamicImporters: string[];
  /** 이 모듈이 static import 하는 모듈들. external 모듈도 포함. */
  importedIds: string[];
  /** 이 모듈이 dynamic import (`import()`) 하는 모듈들. external 도 포함. */
  dynamicallyImportedIds: string[];
}

/** `manualChunks` 콜백의 두 번째 인자 — 모듈 그래프 토폴로지 조회. */
export interface ManualChunksMeta {
  /** `id` 로 모듈 정보 조회. 없으면 null. */
  getModuleInfo(id: string): ManualChunksModuleInfo | null;
}

/**
 * `compiler` 네임스페이스 — 라이브러리별 1st-party transform 설정 (`@next/swc` 호환 surface).
 *
 * 현재는 타입 stub. Zig transformer 가 아직 인식하지 않아 런타임 효과 없음.
 * 후속 epic 에서 styled-components / emotion 1st-party transform 도입 시 활성화.
 */
export interface CompilerOptions {
  /**
   * styled-components 1st-party transform.
   * `babel-plugin-styled-components` / `@swc/plugin-styled-components` 와 동일한 변환 의도.
   */
  styledComponents?: boolean | StyledComponentsOptions;
  /**
   * emotion 1st-party transform.
   * `@emotion/babel-plugin` / `@swc/plugin-emotion` 와 동일한 변환 의도.
   */
  emotion?: boolean | EmotionOptions;
}

/** styled-components transform 옵션 (`babel-plugin-styled-components` 호환). */
export interface StyledComponentsOptions {
  /** devtools 표시용 displayName 자동 부여 (default: NODE_ENV !== "production") */
  displayName?: boolean;
  /** SSR hydration 안정화용 결정론적 componentId hash (default: true) */
  ssr?: boolean;
  /** componentId 에 파일명 포함 (default: true) */
  fileName?: boolean;
  /** CSS 화이트스페이스 minify (default: true) */
  minify?: boolean;
  /** 모던 JS 로 다운레벨된 템플릿 리터럴 인식 (default: true) */
  transpileTemplateLiterals?: boolean;
  /** styled.X 가 부수효과 없음을 minifier 에 알림 (default: false) */
  pure?: boolean;
  /** displayName / componentId 의 namespace prefix — 다중 styled 인스턴스 격리 */
  namespace?: string;
  /**
   * basename 이 의미 없을 때 displayName prefix 를 parent dir 로 fallback 시키는 list
   * (default: `["index"]`). babel-plugin-styled-components 의 동일 옵션과 동등.
   */
  meaninglessFileNames?: string[];
  /**
   * vendored fork 인식할 import source 목록 (e.g. `@my-org/styled`, `@my-org/*`,
   * `@{my-org,co}/*`). picomatch 호환 glob — `*`, `?`, `[abc]`/`[a-z]`/`[!abc]`,
   * `{a,b}` (nested 가능).
   */
  topLevelImportPaths?: string[];
  /**
   * `<div css={...}>` JSX prop 을 module-level styled component 로 추출 (default: false).
   * babel-plugin-styled-components default true 와 다르게 ZTS 는 후속 PR 에서 단계별
   * transform 구현 — 현재는 옵션 surface 만, true 켜도 transform 미적용 (사용자 코드 안전).
   */
  cssProp?: boolean;
  /** [meta] 표시 (default: false) */
  meta?: boolean;
}

/** emotion transform 옵션 (`@emotion/babel-plugin` 호환). */
export interface EmotionOptions {
  /** sourceMap 생성 (default: true) */
  sourceMap?: boolean;
  /** 변수명을 CSS class label 로 자동 부여 (default: "dev-only"). `false` 는 autoLabel 을 끈다. */
  autoLabel?: "always" | "dev-only" | "never" | boolean;
  /** label format string. tokens: `[local]`, `[filename]`, `[dirname]` (default: "[local]") */
  labelFormat?: string;
  /** import 경로 alias — fork 또는 vendored emotion 사용 시 */
  importMap?: Record<string, Record<string, { canonicalImport: [string, string] }>>;
}

/** Vite-style dev server options used by `zts dev` / `zts --serve`. */
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

/**
 * Common build options shared by all platforms.
 * `platform` + `target` 조합은 `BuildOptions` 에서 discriminated union으로 제한됨.
 */
interface BuildOptionsCommon {
  entryPoints: string[];
  format?: "esm" | "cjs" | "iife" | "umd" | "amd";
  external?: string[];
  minify?: boolean;
  minifyWhitespace?: boolean;
  minifyIdentifiers?: boolean;
  minifySyntax?: boolean;
  splitting?: boolean;
  /** Rollup `output.inlineDynamicImports` — dynamic import target 을 importer 의 chunk 에
   * 흡수하고 `import("./x")` 호출을 `__esm` 래퍼 init/exports 호출로 재작성.
   * `splitting: true` 와 조합. 결과 번들은 단일 파일로 실행 가능.
   *
   * 보존 보장:
   * - namespace identity: `(await import("./x")) === (await import("./x"))`
   * - top-level side effect 1회 실행 (캐싱)
   * - live binding (모듈이 `export let` 을 mutate 하면 caller 측에서도 반영)
   */
  inlineDynamicImports?: boolean;
  sourcemap?: boolean;
  /**
   * sourcemap 출력 형식 (`sourcemap: true` 일 때만 의미). esbuild / rolldown 호환 (#2152).
   *  - `"linked"` (default): `.map` 파일 emit + `//# sourceMappingURL=<file>.map` 주석.
   *  - `"external"`: `.map` 파일 emit, URL 주석 없음 (Sentry/CI 표준 — 위치 비공개).
   *  - `"inline"`: `.map` 파일 미생성, JSON 을 base64 data URL 로 주석에 embed.
   *
   * watch / dev server 환경에서는 강제로 `linked` 적용 (HMR + DevTools 통합 보장).
   */
  sourcemapMode?: "linked" | "external" | "inline";
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
  banner?: string;
  footer?: string;
  globalName?: string;
  publicPath?: string;
  entryNames?: string;
  chunkNames?: string;
  assetNames?: string;
  /** Metro AssetRegistry 모듈 경로 (React Native 전용 레이어).
   * - `undefined`: 플랫폼 프리셋 결정 (`platform: "react-native"`이면 기본 경로 자동)
   * - `string`: 해당 경로의 registerAsset을 사용해 `module.exports = require(path).registerAsset({...})`로 래핑
   * - `false`: 비활성화 (웹과 동일한 URL 문자열 export)
   * 기본 경로: `"react-native/Libraries/Image/AssetRegistry"` */
  assetRegistry?: string | false;
  jsx?: "classic" | "automatic" | "automatic-dev";
  jsxFactory?: string;
  jsxFragment?: string;
  jsxImportSource?: string;
  /** 컴파일 타임 상수 치환 (esbuild `define` 호환).
   * 키는 식별자 또는 `obj.prop` 같은 멤버 표현식, 값은 JS 표현식 문자열.
   * 예: `{ "__DEV__": "false", "process.env.NODE_ENV": '"production"' }` */
  define?: Record<string, string>;
  /** Dev server defaults for `zts dev` / `zts --serve`. CLI flags still take precedence. */
  server?: DevServerOptions;
  /** Import 경로 별칭 — 두 형태 지원 (esbuild / Vite 호환):
   *
   * 1. **Object 형태** (esbuild `alias`): exact + prefix 매칭. 정해진 specifier 만 치환.
   *    예: `{ react: "preact/compat" }` — `react` 또는 `react/hooks` → `preact/compat[/hooks]`
   *
   * 2. **Array 형태** (Vite `resolve.alias`, #2153): `RegExp` find 지원. 매칭 순서대로 첫번째 적용.
   *    `find` 가 string 이면 prefix 매칭, RegExp 이면 host runtime 이 매칭 + `replacement` 로 치환.
   *    예: `[{ find: /^@\/(.*)$/, replacement: "./src/$1" }]`
   *
   * 일반 해석 **전에 무조건** 치환됨 — 설치된 실제 패키지가 있어도 무시.
   * Optional shim 용도로는 `fallback`을 쓸 것 (실패 시에만 적용).
   * Array 형태는 build() 만 지원 (host RegExp 위임 — buildSync 미지원). */
  alias?: Record<string, string> | Array<{ find: string | RegExp; replacement: string }>;
  /** Fallback resolution — 일반 해석이 **실패했을 때만** 적용됨 (webpack `resolve.fallback` / Metro `resolver.extraNodeModules` 호환).
   * 값이 문자열이면 해당 specifier로 재해석, `false`면 빈 모듈로 대체.
   * 예: `{ crypto: "crypto-browserify", fs: false }` */
  fallback?: Record<string, string | false>;
  /** 해석 차단 패턴 (Metro `resolver.blockList` / webpack `IgnorePlugin` 호환).
   * 매칭되는 절대 경로는 resolver가 해석 실패시켜 번들 그래프에 포함되지 않는다.
   * - `RegExp`: `.source`를 추출해 패턴으로 사용
   * - `string`: regex 문자열 그대로 사용
   *
   * 지원 구문: 리터럴, `.*`, `^`, `$`, `\x` 이스케이프. `|`, `[]`, `()`, `+?`, `\w\d`는 미지원.
   *
   * `platform: "react-native"` 시 Metro 기본 패턴들(`__tests__`, iOS/Android 빌드 폴더 등)이
   * 자동 prepend된다. 사용자 패턴은 그 뒤에 append. */
  blockList?: (RegExp | string)[];
  inject?: string[];
  jobs?: number;
  plugins?: ZtsPlugin[];
  /** 사용자 정의 청크 분할 — Rollup/rolldown `manualChunks` 호환 (#1027).
   * 모듈 id (절대경로) 를 받아 청크 이름을 반환하면 해당 모듈은 그 이름의 청크로 묶임.
   * null/undefined 반환 시 기존 자동 분배. transitive dependency 도 같은 청크로 따라감
   * (cross-chunk 순환 회피). dynamic import target 은 async chunk 대신 manual 우선.
   *
   * 두 번째 인자 `meta.getModuleInfo(id)` 는 그래프 토폴로지 조회 — Rollup 호환.
   *
   * 예:
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
  /** 확장자별 로더 오버라이드 (예: { ".png": "file", ".svg": "text" }) */
  loader?: Record<string, string>;
  /** package.json exports 커스텀 조건 */
  conditions?: string[];
  /** 확장자 탐색 순서 (예: [".ts", ".tsx", ".js"]) */
  resolveExtensions?: string[];
  /** package.json 필드 순서 (예: ["module", "main"]) */
  mainFields?: string[];
  /** 출력 디렉토리 (write: true 시 사용) */
  outdir?: string;
  /** 출력 파일 경로 (단일 엔트리 시, write: true 시 사용) */
  outfile?: string;
  /** 디스크 쓰기 여부 (기본: false, outdir/outfile 지정 시 자동 true) */
  write?: boolean;
  /** 출력 파일이 입력 파일을 덮어쓰는 것을 허용 */
  allowOverwrite?: boolean;
  /** 엔트리 포인트 공통 기준 경로 (출력 디렉토리 구조 결정) */
  outbase?: string;
  /** 모든 bare import를 external 처리 */
  packagesExternal?: boolean;
  /** symlink를 따라가지 않고 링크 경로로 해석 */
  preserveSymlinks?: boolean;
  /** @__PURE__, sideEffects 어노테이션 무시 */
  ignoreAnnotations?: boolean;
  /** 미사용 JSX를 tree-shake하지 않음 */
  jsxSideEffects?: boolean;
  /** 번들 분석 출력 (metafile 강제 활성화) */
  analyze?: boolean;
  /** 제거할 labeled statement의 라벨 이름 목록 */
  dropLabels?: string[];
  /** `console.*` 호출 expression statement 를 transformer 에서 제거 (#2155). bundle/transpile 동일 적용. */
  dropConsole?: boolean;
  /** `debugger;` statement 를 transformer 에서 제거 (#2155). bundle/transpile 동일 적용. */
  dropDebugger?: boolean;
  /** 순수 함수로 마킹할 글로벌 함수명 목록 */
  pure?: string[];
  /**
   * 진단 출력 레벨 (esbuild 호환, #2158). NAPI 가 build result 의 errors/warnings 배열을
   * 이 level 기준으로 필터링한다 — `result.errors` / `result.warnings` 에 포함되는 항목 자체가 줄어듦.
   *
   *  - `"silent"`: errors / warnings 둘 다 빈 배열 — fail 도 result 객체로 확인 (throw 안 함)
   *  - `"error"`: warnings 만 빈 배열, errors 는 그대로
   *  - `"warning"` (default): errors + warnings 둘 다 그대로
   *  - `"info"` / `"debug"` / `"verbose"`: warning 과 동일 (info-level 진단은 현재 emit 안 함)
   */
  logLevel?: "silent" | "error" | "warning" | "info" | "debug" | "verbose";
  /**
   * 진단 갯수 제한 (esbuild `logLimit`, #2158). 0 이면 무제한 (default).
   * errors / warnings 각 배열에 동일 limit 적용 — 초과 항목은 자동 truncate.
   */
  logLimit?: number;
  /**
   * CJS / UMD entry export 형식 (Rollup `output.exports` 호환, #2159). ESM 출력에서는 무시.
   *
   *  - `"auto"` (default): default-only → `module.exports = X`. named-only → `exports.X = X`
   *    (no `__esModule` flag). mixed → `exports.X = X` + `__esModule` flag.
   *  - `"named"`: 항상 named (`exports.X = X`). default 있으면 `__esModule` flag 자동 추가
   *    (rolldown `IfDefaultProp` 동작 — default 없을 때는 flag 없음).
   *  - `"default"`: `module.exports = X` 단일 — default-only 일 때만. named 섞이면 warning + 빈 출력.
   *  - `"none"`: export 출력 안 함.
   */
  outputExports?: "auto" | "named" | "default" | "none";
  /** tsconfig.json 인라인 JSON 오버라이드 */
  tsconfigRaw?: string;
  /**
   * tsconfig.json 경로 (파일 또는 디렉토리). 설정 시 compilerOptions 를 자동 로드해서 머지한다.
   * JS 옵션이 명시적으로 설정된 필드가 우선 — 미지정 필드만 tsconfig 값으로 채워진다.
   * 예) "./tsconfig.json" 또는 "./project-dir"
   */
  tsconfigPath?: string;
  /** NODE_PATH 추가 탐색 경로 */
  nodePaths?: string[];
  /** 줄 길이 제한 (0=무제한) */
  lineLimit?: number;
  /** 출력 파일 확장자 오버라이드 (예: ".mjs") */
  outExtension?: string;
  /** 소스맵 sourceRoot 필드 */
  sourceRoot?: string;
  /** 라이센스 주석 처리 ("none" | "inline" | "eof" | "linked") */
  legalComments?: "none" | "inline" | "eof" | "linked";
  /** 모듈별 개별 파일 출력 (라이브러리 빌드) */
  preserveModules?: boolean;
  /** preserve-modules 출력 디렉토리 구조 기준 경로 */
  preserveModulesRoot?: string;
  /**
   * 활성화할 profile category 목록 (ZTS_PROFILE env 와 합집합).
   * 예: `["all"]`, `["parse", "transform"]`, `["transform.jsx"]`.
   * Parent 를 지정하면 child 도 자동 활성 (e.g. "transform" → "transform.jsx"/"transform.ts_strip"/...).
   * 사용 가능한 category: docs/design/profile-infrastructure.md 참조.
   */
  profile?: string[];
  /**
   * Profile 상세도.
   * - "summary": phase 총합만 (기본)
   * - "detailed": sub-phase 포함
   * - "per-module": 모듈별 breakdown
   * - "per-pass": transformer visit 수준
   */
  profileLevel?: "summary" | "detailed" | "per-module" | "per-pass";
  /**
   * Profile 리포트 출력 포맷.
   * - "table": 사람 가독 (기본)
   * - "tree": parent/child 트리
   * - "json": 기계 판독
   * - "csv": 스프레드시트
   */
  profileFormat?: "table" | "tree" | "json" | "csv";
  /** dev mode: 모듈을 __zts_register() 팩토리로 래핑 + HMR 런타임 주입 */
  devMode?: boolean;
  /** dev mode 모듈 ID 기준 경로 */
  rootDir?: string;
  /** React Fast Refresh 활성화 */
  reactRefresh?: boolean;
  /** dev mode per-module codes 수집 (HMR rebuild용) */
  collectModuleCodes?: boolean;
  /** Object.defineProperty에 configurable: true 추가 (RN/Hermes 호환) */
  configurableExports?: boolean;
  /** ESM 실행 순서 보장 — 함수 선언을 factory 내부 assignment로 다운그레이드해 호이스팅 방지.
   * Rolldown의 strictExecutionOrder와 동일. React Native 플랫폼에서 자동 활성화. */
  strictExecutionOrder?: boolean;
  /** entry trigger (`init_X()` / `require_X()`) 호출을 try/catch + ErrorUtils.reportFatalError 로 wrap.
   * Metro `guardedLoadModule` (top-level `__r` wrapper) 와 동등 mechanism — module factory throw 가
   * 부팅을 막지 않고 RN 표준 LogBox 에 fatal 로 표시. ErrorUtils 미정의 환경 (test / browser) 에선
   * throw 그대로 re-throw. 발견 계기는 iOS 26.4 Hermes 가 `Location` 등 spec global 을 immutable
   * descriptor (`configurable: false`) 로 미리 등록 + expo-metro-runtime 의 가드 없는
   * `defineProperty` 시도 throw 였지만, mechanism 은 OS/엔진 무관 — 모든 module factory throw 케이스
   * 커버. React Native 플랫폼에서 자동 활성화. */
  entryErrorGuard?: boolean;
  /** Prologue 에 `console.error` setter intercept 주입 — RegExp source string 배열의 어느 하나라도
   * match 하는 console.error 호출은 silent swallow. `entryErrorGuard` 와 직교. consumer 가 환경
   * (e.g. expo) 감지 후 패턴 주입. 비어있거나 미지정 시 wrap 자체 emit 안 됨 → vanilla RN CLI 빌드는
   * dead code 0. RN preset 에서도 자동 활성화 안 함 (trigger 가 environment-specific 이므로).
   *
   * 예: `["^Failed to set polyfill\\.\\s+\\w+\\s+is not configurable\\.?$"]`
   * (expo `installGlobal.ts` + RN `polyfillObjectProperty` 의 native immutable global 충돌 메시지) */
  silentConsoleErrorPatterns?: string[];
  /** scope hoisting 활성화 (기본 true). 단일 chunk에서 모듈 경계를 제거하고 심볼을 평탄화. */
  scopeHoist?: boolean;
  /** Reanimated worklet 변환 — "worklet" 디렉티브 함수에 __workletHash/__closure/__initData 주입.
   * React Native 플랫폼에서 자동 활성화. */
  workletTransform?: boolean;
  /** worklet의 `__pluginVersion` 값 (Reanimated dev mode jsVersion 대조용).
   * 사용자 환경의 react-native-worklets 패키지 version을 전달해야 런타임 에러 없음. */
  workletPluginVersion?: string;
  /** scope hoisting 시 예약할 전역 식별자 */
  globalIdentifiers?: string[];
  /** 번들 시작 시 즉시 실행 폴리필 경로 */
  polyfills?: string[];
  /** 엔트리 모듈 직전에 실행할 모듈 경로 */
  runBeforeMain?: string[];
  /** 번들 그래프 밖의 디렉토리를 감시 루트에 추가 (Metro watchFolders 호환).
   * 절대/상대 경로 모두 허용. 지정된 경로는 재귀 스캔되어 감시 대상에 포함된다. */
  watchFolders?: string[];
  /** watchFolders 스캔 시 포함할 파일 glob 화이트리스트 (루트 기준 상대 경로). */
  watchInclude?: string[];
  /** watchFolders 스캔 시 제외할 파일 glob (루트 기준 상대 경로). */
  watchExclude?: string[];
  /** watch 모드 빌드 완료 콜백 */
  onReady?: (event: WatchReadyEvent) => void;
  /** watch 모드 리빌드 콜백 */
  onRebuild?: (event: WatchRebuildEvent) => void;
  /**
   * `.map` 파일을 디스크에 기록할지 여부 (Issue #1727 Phase B).
   *
   * - 기본 `true` — `bundle.js.map` 을 `output_filename + ".map"` 경로에 저장.
   * - `false` — 디스크 I/O 생략. bungae 같은 dev server 가
   *   {@link WatchHandle.getBundleSourceMap} / {@link WatchHandle.getHmrSourceMap}
   *   을 호출해 lazy 엔드포인트로 serve 하는 경우 권장.
   */
  emitDiskSourcemap?: boolean;
  /**
   * 라이브러리별 1st-party transform 설정 (`@next/swc` 의 `compiler` 와 호환 surface).
   *
   * 현재는 타입 stub — Zig transformer 가 아직 인식하지 않아 런타임 효과 없음.
   * 후속 epic 에서 styled-components / emotion 1st-party transform 도입 시 활성화.
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
 * BuildOptions: 사용자 공개 API.
 *
 * `platform === "react-native"` 일 때는 Hermes 호환 매트릭스가 강제되므로
 * `target` / `browserslist`를 전달할 수 없다 (런타임에서도 무시됨).
 */
export type BuildOptions =
  | (BuildOptionsCommon & {
      /** React Native (Hermes) 프리셋. target은 Hermes 매트릭스로 강제됨. */
      platform: Extract<import("../shared/index").Platform, "react-native">;
      target?: never;
      browserslist?: never;
    })
  | (BuildOptionsCommon & {
      platform?: Exclude<import("../shared/index").Platform, "react-native">;
      /** ES 다운레벨 타겟 ("es5" ~ "esnext") */
      target?: import("../shared/index").Target;
      /** browserslist 쿼리 (string 또는 string[]). 지정 시 target보다 우선. */
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
     * 모듈별 standalone source map (V3 JSON). sourcemap 옵션 활성화 시 채워진다.
     * HMR 클라이언트가 eval된 코드에 sourceMappingURL data URL로 부착하면
     * 전체 번들 sourcemap을 재생성하지 않고도 디버거 매핑이 유지된다 (Issue #1248).
     */
    map?: string;
  }>;
  bytes?: number;
  /**
   * 단계별 빌드 시간 (밀리초). 성공한 리빌드에서만 노출.
   *
   * **기본 phase** (항상 측정):
   * - `detect` / `parse` / `semantic` / `emit` / `delta` / `total`
   * 필드 이름과 실제 값이 정확히 일치. 2026-04-22 이전의 `parse` / `semantic` 은
   * 사실 각각 `graph` / `link+shake` 를 담았던 레거시 이름이었으며 제거됨.
   *
   * **Sub-phase** (`ZTS_PROFILE=<cat>` / `BUNGAE_HMR_PROFILE=1` / `profile: ["<cat>"]` 활성 시):
   * - `scan` / `parse` / `resolve` / `semantic` / `transform` / `codegen` / `metadata`
   * - 비활성 상태에선 모두 0. `parse` 는 이제 진짜 parser 시간, `semantic` 은 진짜 SemanticAnalyzer.
   */
  phaseDurations?: {
    // 기본 phase (항상 측정)

    /** 변경 감지 (mtime 스캔) */
    detect: number;
    /** Module graph build — resolve + parse + semantic + finalize */
    graph: number;
    /** Scope hoisting + linker */
    link: number;
    /** Tree shaking */
    shake: number;
    /** 코드 생성 (transform + codegen + emit) */
    emit: number;
    /** HMR delta 추출 */
    delta: number;
    /** 총 리빌드 시간 (detect → delta 합산) */
    total: number;

    // Sub-phase (profile 활성 시에만)

    /** Scanner tokenization */
    scan: number;
    /** Parser — 실제 parser 시간만 */
    parse: number;
    /** Dependency resolution */
    resolve: number;
    /** SemanticAnalyzer — 실제 semantic 분석 시간만 */
    semantic: number;
    /** Transformer 전체 */
    transform: number;
    /** Codegen 전체 */
    codegen: number;
    /** Linker metadata build */
    metadata: number;

    // Graph sub-phase (graph 내부 분해)

    /** `graph.build()` / `graph.buildIncremental()` — 모듈 그래프 구축 본체 */
    graphBuild: number;
    /** `new Worker(new URL(...))` 패턴 entry 별도 빌드 */
    graphWorker: number;
    /** Phase 1: 이벤트 큐 BFS 스캔 (모듈 발견 + 파싱 + resolve) */
    graphDiscover: number;
    /** Phase 2-4: DFS exec_index + ExportsKind 승격 + TLA 전파 */
    graphFinalize: number;

    // Emit sub-phase (bundler.zig 수준 분해)

    /** `--polyfill` 파일 내용 로딩 + Flow 트랜스파일 */
    emitPolyfill: number;
    /** React Refresh 런타임 preamble/epilogue 조립 (dev + 브라우저) */
    emitRefresh: number;
    /** `emitter.emitWithTreeShaking` / `emitChunks` — 번들 출력 생성 본체 */
    emitOutput: number;
    /** `--metafile` / `--analyze` JSON 생성 */
    emitMetafile: number;
    /** CSS 엔트리별 번들 + lightningcss 후처리 */
    emitCss: number;

    // emit_output 내부 (emitter.emitWithTreeShaking 분해)

    /** 포맷 prologue + polyfill IIFE + runtime helper 주입 */
    emitPrelude: number;
    /** Phase 1/1.5/2/2.5 — used_names + cache lookup + emitModule + cache put */
    emitModulePass: number;
    /** Phase 3: module concat + runtime helpers 합산 + renderChunk + epilogue */
    emitConcat: number;
    /** 소스맵 V3 JSON 생성 (VLQ encode + sources content + debugId) */
    emitSourcemapFinalize: number;
  };
  /** 증분 그래프에서 재파싱된 모듈 수. 캐시 미스된 모듈만 카운트. 전체 빌드에서는 미노출. */
  reparsedModules?: number;
}

export interface WatchHandle {
  stop(): void;
  /**
   * 최신 rebuild 의 번들 전체 sourcemap JSON 을 lazy 생성해 반환 (Issue #1727 Phase B).
   *
   * emit 단계에서 VLQ encode + sourcesContent 첨부를 건너뛰어 HMR latency 밖으로 빼낸
   * 비용을 요청 시점으로 지연시킨다. dev server 가 `/bundle.js.map` 요청을 받을 때 호출.
   *
   * - sourcemap 비활성 / 초기 빌드 전 / `stop()` 이후에는 `null`.
   * - Metro `_processSourceMapRequest` 패턴.
   */
  getBundleSourceMap(): string | null;
  /**
   * 최신 rebuild 의 모듈별 sourcemap JSON 을 lazy 생성해 반환.
   *
   * dev server 가 `/hmr-map/:moduleId` 요청을 받을 때 호출.
   * `moduleId` 가 이번 rebuild 에 포함되지 않았으면 `null`.
   */
  getHmrSourceMap(moduleId: string): string | null;
}

export interface ZtsPlugin {
  name: string;
  setup(build: PluginBuild): void;
}

/** 플러그인 훅 반환값: 동기/비동기 모두 허용. null/undefined로 패스스루. */
type HookResult<T> = T | null | undefined | Promise<T | null | undefined>;

export interface PluginBuild {
  onResolve(
    options: { filter: RegExp },
    callback: (args: { path: string; importer: string | null }) => HookResult<{
      path?: string;
      /** import 문을 그대로 유지 — 런타임이 해석 (esbuild 호환). */
      external?: boolean;
      /** 모듈을 빈 객체(`module.exports = {}`)로 대체.
       * Metro `resolveRequest`가 `{ type: 'empty' }` 반환할 때, webpack `resolve.fallback`이
       * `false`일 때 매핑용. `path` 생략 시 specifier가 식별자로 사용됨. */
      disabled?: boolean;
    }>,
  ): void;
  onLoad(
    options: { filter: RegExp },
    callback: (args: {
      path: string;
    }) => HookResult<{ contents: string | Uint8Array; loader?: string }>,
  ): void;
  onTransform(
    options: { filter: RegExp },
    callback: (args: { code: string; path: string }) => HookResult<{ code: string }>,
  ): void;
  onRenderChunk(
    options: { filter: RegExp },
    callback: (args: { code: string; chunk: string }) => HookResult<{ code: string }>,
  ): void;
  onGenerateBundle(callback: (outputs: OutputFile[]) => void | Promise<void>): void;
  /**
   * Bundle 시작 시 1회 호출. esbuild `onStart`, Rollup/Vite/rolldown `buildStart` 동일 (#2156).
   * watch 모드는 매 rebuild 마다 호출됨 (Rollup 5+ 정책과 동일).
   *
   * 인자는 없음 — esbuild `onStart` 와 동일. plugin 자체 setup 시 `BuildOptions` 가 이미 전달됨.
   */
  onBuildStart(callback: () => void | Promise<void>): void;
  /**
   * Bundle 종료 시 1회 호출. 성공/실패 모두 dispatch. 실패 시 fatal diagnostic 의 첫 항목을
   * `Error` 로 wrap 해서 전달 (#2156). watch 모드는 매 rebuild 마다 호출.
   *
   * `onCloseBundle` 보다 먼저 호출됨.
   */
  onBuildEnd(callback: (error?: Error) => void | Promise<void>): void;
  /**
   * Output 파일 결정 직후 1회 호출 (#2156). Rollup `closeBundle` 와 동일 — temp 파일 cleanup,
   * 외부 시스템에 빌드 완료 알림 등에 사용. watch 모드는 매 rebuild 마다 호출.
   */
  onCloseBundle(callback: () => void | Promise<void>): void;
  onAstFunction(
    options: { filter: RegExp },
    callback: (info: AstFunctionInfo) => HookResult<AstFunctionResult>,
  ): void;
  /**
   * `require.context(dir, recursive, filter, mode)` 의 매칭 결과를 호스트 런타임에서 채운다. (#1579)
   * ZTS 자체 regex executor 가 없어서 (#1771) host 의 RegExp 에 위임 — Node V8 / Bun JSC.
   *
   * `options.filter` 는 `dir` 에 적용 (예: `/^\.\/app/` 으로 특정 디렉토리만 처리).
   * 콜백 반환:
   *   - `{ context: string[] }` — 매칭된 파일 경로 배열 (빈 배열 = empty context)
   *   - `null`/`undefined` — 다음 plugin 시도 (모두 null 이면 graph 가 require_context_no_handler diagnostic)
   *
   * 콜백 인자 `filter` 는 require.context 의 정규식 본문 (slashes 없이),
   * `flags` 는 정규식 플래그. host 가 `new RegExp(filter, flags)` 로 컴파일 후 매칭.
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
  /**
   * 라이브러리별 1st-party transform (`@next/swc` 의 `compiler` 와 호환 surface).
   * BuildOptions 와 동일 의미 — bundle / app 빌드 양쪽에서 같은 옵션 표현 사용.
   */
  compiler?: CompilerOptions;
}

/**
 * Options for preparing a Vite-style application for the development server.
 */
export interface AppDevPrepareOptions {
  /** Application root directory used to resolve index.html, public/, and env files. */
  root?: string;
  /** Temporary output directory used by the dev server. Defaults to ".zts-dev". */
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
 * filter 없는 lifecycle/generate hook 의 callback 들을 sequential 로 실행하고 swallow.
 * Rollup 명세 — 한 plugin 의 실패가 다른 plugin 을 차단하지 않는다.
 */
async function runFireAndForget<T>(
  callbacks: Array<(arg: T) => void | Promise<void>>,
  arg: T,
): Promise<void> {
  for (const cb of callbacks) {
    try {
      await cb(arg);
    } catch {
      // pass
    }
  }
}

/**
 * plugins 배열을 처리하여 단일 dispatcher 함수를 생성한다.
 * dispatcher(hookName, arg1, arg2) → result | null
 */
function createPluginDispatcher(plugins: ZtsPlugin[]) {
  type HookEntry = { filter: RegExp; callback: (...args: any[]) => any };
  const hooks: Record<string, HookEntry[]> = {
    resolveId: [],
    load: [],
    transform: [],
    renderChunk: [],
    resolveContext: [],
  };
  const generateBundleCallbacks: Array<(outputs: OutputFile[]) => void | Promise<void>> = [];
  const buildStartCallbacks: Array<() => void | Promise<void>> = [];
  const buildEndCallbacks: Array<(error?: Error) => void | Promise<void>> = [];
  const closeBundleCallbacks: Array<() => void | Promise<void>> = [];
  const astFunctionHooks: HookEntry[] = [];

  for (const plugin of plugins) {
    const build: PluginBuild = {
      onResolve(opts, cb) {
        hooks.resolveId.push({ filter: opts.filter, callback: cb });
      },
      onLoad(opts, cb) {
        hooks.load.push({ filter: opts.filter, callback: cb });
      },
      onTransform(opts, cb) {
        hooks.transform.push({ filter: opts.filter, callback: cb });
      },
      onRenderChunk(opts, cb) {
        hooks.renderChunk.push({ filter: opts.filter, callback: cb });
      },
      onGenerateBundle(cb) {
        generateBundleCallbacks.push(cb);
      },
      onBuildStart(cb) {
        buildStartCallbacks.push(cb);
      },
      onBuildEnd(cb) {
        buildEndCallbacks.push(cb);
      },
      onCloseBundle(cb) {
        closeBundleCallbacks.push(cb);
      },
      onAstFunction(opts, cb) {
        astFunctionHooks.push({ filter: opts.filter, callback: cb });
      },
      onResolveContext(opts, cb) {
        hooks.resolveContext.push({ filter: opts.filter, callback: cb });
      },
    };
    plugin.setup(build);
  }

  // hookName → { filter 대상, 콜백 인자 } 매핑
  const argBuilders: Record<string, (arg1: string, arg2: string | null) => [string, unknown]> = {
    resolveId: (arg1, arg2) => [arg1, { path: arg1, importer: arg2 }],
    load: (arg1, _) => [arg1, { path: arg1 }],
    renderChunk: (arg1, arg2) => [arg2 ?? "", { code: arg1, chunk: arg2 }],
  };

  return async function dispatcher(hookName: string, arg1: unknown, arg2: string | null) {
    // astFunction: arg1이 JSON 직렬화된 FunctionInfo
    if (hookName === "astFunction") {
      if (astFunctionHooks.length === 0) return null;
      try {
        const info = JSON.parse(arg1 as string) as AstFunctionInfo;
        for (const h of astFunctionHooks) {
          if (h.filter.test(info.sourcePath)) {
            try {
              const result = await h.callback(info);
              if (result != null) return result;
            } catch {
              // 에러 시 해당 플러그인 건너뛰기
            }
          }
        }
      } catch {
        // JSON 파싱 실패
      }
      return null;
    }

    // resolveContext: arg1 = JSON({ dir, recursive, filter, flags, importer }), arg2 = null. (#1579 Phase 2.5)
    // 결과 형식: { context: string[] } — 매칭 파일 경로 배열. null/undefined 반환 시 graph 가
    // require_context_no_handler diagnostic emit.
    if (hookName === "resolveContext") {
      if (hooks.resolveContext.length === 0) return null;
      try {
        const args = JSON.parse(arg1 as string) as {
          dir: string;
          recursive: boolean;
          filter?: string;
          flags?: string;
          importer: string;
        };
        for (const h of hooks.resolveContext) {
          if (h.filter.test(args.dir)) {
            try {
              const result = await h.callback(args);
              if (result != null) return result;
            } catch {
              // 에러 시 다음 plugin 시도
            }
          }
        }
      } catch {
        // JSON 파싱 실패
      }
      return null;
    }

    // filter 없이 모든 callback 순차 호출 (Rollup sequential 명세). 한 plugin 실패가
    // 다른 plugin 차단 안 되도록 try/catch swallow.
    if (hookName === "generateBundle") {
      await runFireAndForget(generateBundleCallbacks, arg1 as OutputFile[]);
      return null;
    }
    if (hookName === "buildStart") {
      await runFireAndForget(buildStartCallbacks, undefined);
      return null;
    }
    if (hookName === "buildEnd") {
      // native 측이 fatal diagnostic message 를 string 으로 forward — 빈 문자열은 정상 build.
      const msg = arg1 as string;
      const err = msg && msg.length > 0 ? new Error(msg) : undefined;
      await runFireAndForget(buildEndCallbacks, err);
      return null;
    }
    if (hookName === "closeBundle") {
      await runFireAndForget(closeBundleCallbacks, undefined);
      return null;
    }

    const hookList = hooks[hookName];
    if (!hookList) return null;

    // transform/renderChunk: 체이닝 (이전 결과의 code가 다음 입력)
    if (hookName === "transform" || hookName === "renderChunk") {
      let currentCode = arg1 as string;
      let changed = false;
      for (const h of hookList) {
        if (h.filter.test(arg2 ?? "")) {
          try {
            const cbArgs =
              hookName === "transform"
                ? { code: currentCode, path: arg2 }
                : { code: currentCode, chunk: arg2 };
            const result = await h.callback(cbArgs);
            if (result != null) {
              const newCode = typeof result === "string" ? result : result.code;
              if (newCode != null) {
                currentCode = newCode;
                changed = true;
              }
            }
          } catch {
            // 에러 시 해당 플러그인 건너뛰고 다음으로
          }
        }
      }
      return changed ? { code: currentCode } : null;
    }

    // resolveId/load: 첫 번째 매칭 반환 (first 모드)
    const buildArgs = argBuilders[hookName];
    if (!buildArgs) return null;
    const [filterTarget, cbArgs] = buildArgs(arg1 as string, arg2);
    for (const h of hookList) {
      if (h.filter.test(filterTarget)) {
        try {
          const result = await h.callback(cbArgs);
          if (result != null) return result;
        } catch {
          return null;
        }
      }
    }
    return null;
  };
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
): ZtsPlugin {
  return {
    name: "zts:array-alias",
    setup(build) {
      build.onResolve({ filter: /.*/ }, (args) => {
        for (const { find, replacement } of aliasArray) {
          if (find instanceof RegExp) {
            // `String.search` 는 RegExp.test 와 달리 `g`/`y` flag 의 lastIndex 를
            // mutate 하지 않는다 — 같은 alias entry 가 여러 import 에 반복 적용돼도 안전.
            if (args.path.search(find) !== -1) {
              return { path: args.path.replace(find, replacement) };
            }
          } else if (args.path === find || args.path.startsWith(find + "/")) {
            return { path: args.path.replace(find, replacement) };
          }
        }
        return null;
      });
    },
  };
}

function isBrowserLikeBuildPlatform(platform: BuildOptions["platform"] | undefined): boolean {
  return platform === undefined || platform === "browser" || platform === "react-native";
}

function withDefaultBuildDefines(options: BuildOptions): Record<string, string> | undefined {
  const define = { ...options.define };
  const browserLike = isBrowserLikeBuildPlatform(options.platform) || options.minifySyntax === true;

  if (browserLike && define["process.env.NODE_ENV"] === undefined) {
    define["process.env.NODE_ENV"] = options.devMode ? '"development"' : '"production"';
  }
  if (options.platform === "react-native" && define.__DEV__ === undefined) {
    define.__DEV__ = options.devMode ? "true" : "false";
  }

  return Object.keys(define).length > 0 ? define : undefined;
}

function withDefaultAppBuildDefines(options: AppBuildOptions): Record<string, string> | undefined {
  const define = { ...options.define };
  if (define["process.env.NODE_ENV"] === undefined) {
    define["process.env.NODE_ENV"] =
      (options.mode ?? "production") === "production" ? '"production"' : '"development"';
  }
  return define;
}

function prepareNapiOptions(options: BuildOptions): Record<string, unknown> {
  const napiOptions: Record<string, unknown> = { ...options };
  const define = withDefaultBuildDefines(options);
  if (define) napiOptions.define = define;
  delete napiOptions.write;
  delete napiOptions.outdir;
  delete napiOptions.plugins;
  delete napiOptions.allowOverwrite;
  // Array 형태 alias 는 plugin 으로 위임 (build() 에서 처리). NAPI 로 전달하면 Zig 가
  // Record 형태만 받으므로 type mismatch — 명시 삭제.
  if (Array.isArray(napiOptions.alias)) delete napiOptions.alias;
  // manualChunks 는 `_manualChunks` 전용 슬롯으로 재전달 (plugin dispatcher 패턴).
  // napi_entry.zig 가 TSFN 으로 감싸 Zig resolver 로 변환.
  delete napiOptions.manualChunks;
  if (options.manualChunks) {
    napiOptions._manualChunks = options.manualChunks;
  }
  // blockList: RegExp는 .source로 추출해 string[]으로 넘긴다 (NAPI는 string만).
  if (options.blockList) {
    napiOptions.blockList = options.blockList.map((p) => {
      if (p instanceof RegExp) return p.source;
      if (typeof p === "string") return p;
      throw new TypeError(`blockList entries must be RegExp or string, got ${typeof p}`);
    });
  }
  // browserslist → unsupported bitmask. transpile과 동일한 resolveUnsupported 재사용.
  if (options.browserslist) {
    napiOptions.unsupported = resolveUnsupported({ browserslist: options.browserslist });
    delete napiOptions.browserslist;
  }
  // compiler.styledComponents / compiler.emotion → flat NAPI fields.
  // boolean 또는 객체 (세밀 제어 옵션). 현재 인식 객체 옵션: ssr.
  delete napiOptions.compiler;
  const sc = options.compiler?.styledComponents;
  if (sc !== undefined && sc !== false) {
    napiOptions.styledComponents = true;
    if (typeof sc === "object") {
      if (sc.ssr === false) napiOptions.styledComponentsSsr = false;
      if (sc.minify === true) napiOptions.styledComponentsMinify = true;
      if (sc.fileName === false) napiOptions.styledComponentsFileName = false;
      if (sc.pure === true) napiOptions.styledComponentsPure = true;
      if (typeof sc.namespace === "string" && sc.namespace.length > 0) {
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
    if (typeof em === "object") {
      // autoLabel: string ("never"|"always"|"dev-only") 또는 boolean (legacy false=never).
      // 누락 시 NAPI 측 default `.always`.
      if (em.autoLabel === false) {
        napiOptions.emotionAutoLabel = "never";
      } else if (em.autoLabel === true) {
        napiOptions.emotionAutoLabel = "always";
      } else if (typeof em.autoLabel === "string") {
        napiOptions.emotionAutoLabel = em.autoLabel;
      }
      if (em.sourceMap === true) napiOptions.emotionSourceMap = true;
      if (typeof em.labelFormat === "string" && em.labelFormat.length > 0) {
        napiOptions.emotionLabelFormat = em.labelFormat;
      }
      const extras = collectEmotionImportMapExtras(em.importMap);
      if (extras.css.length > 0) napiOptions.emotionExtraCssSources = extras.css;
      if (extras.styled.length > 0) napiOptions.emotionExtraStyledSources = extras.styled;
    }
  }
  return napiOptions;
}

/**
 * babel-plugin-emotion `importMap.canonicalImport[0]` 의 css 분류 패키지 목록.
 * Zig 측 `EMOTION_CSS_SOURCES` (`src/transformer/transformer/emotion.zig`) 와 동기화.
 */
const EMOTION_CSS_CANONICAL_SOURCES: ReadonlySet<string> = new Set([
  "@emotion/react",
  "@emotion/css",
  "@emotion/core",
  "@emotion/native",
  "@emotion/primitives",
  "@emotion/primitives-core",
]);

/**
 * babel-plugin-emotion `importMap` 의 vendored re-export 케이스를 ZTS 의 단순화된
 * `extraCssSources` / `extraStyledSources` array 로 collapse.
 *
 * 같은 source 안에 styled / css canonicalImport 가 섞여 있으면 양쪽에 모두 등록.
 * import 인식이 source 단위라 alias-by-alias 라우팅은 미지원 — 흔치 않은 케이스라 의도적
 * 단순화 (babel parity).
 */
function collectEmotionImportMapExtras(importMap: EmotionOptions["importMap"]): {
  css: string[];
  styled: string[];
} {
  const css = new Set<string>();
  const styled = new Set<string>();
  if (!importMap) return { css: [], styled: [] };
  for (const [source, locals] of Object.entries(importMap)) {
    for (const spec of Object.values(locals)) {
      const [pkg, exportName] = spec.canonicalImport;
      if (pkg === "@emotion/styled" && exportName === "default") {
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
    lcss = require("lightningcss");
  } catch {
    return; // lightningcss 미설치 — raw CSS 그대로 반환
  }

  for (const file of result.outputFiles) {
    if (!file.path.endsWith(".css")) continue;
    try {
      const transformed = lcss.transform({
        code: Buffer.from(file.text),
        minify: true,
        filename: file.path,
      });
      file.text = transformed.code.toString();
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
          `@zts/core: output file '${options.outfile}' would overwrite input file (set allowOverwrite: true to permit)`,
        );
      }
    }
  }

  const createdDirs = new Set<string>();
  const outfileResolved = options.outfile ? resolve(options.outfile) : null;

  for (const file of result.outputFiles) {
    let outPath: string;
    if (outfileResolved && file.path === "bundle.js") {
      // 메인 번들 → outfile 경로로 출력
      outPath = outfileResolved;
    } else if (outfileResolved && file.path.endsWith(".map")) {
      // 소스맵 → outfile 옆에 .map으로 출력
      outPath = outfileResolved + ".map";
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
    writeFileSync(outPath, file.text, "utf-8");
  }
}

/**
 * 번들링을 비동기적으로 실행한다. 이벤트 루프를 블로킹하지 않음.
 * JS 플러그인은 이 함수에서만 지원됨.
 *
 * Plugin lifecycle 호출 순서: buildStart → (NAPI build) → buildEnd → write → closeBundle.
 * `buildEnd` 는 NAPI 실패 시에도 호출되며 error 인자가 전달된다 (Rollup 동일).
 * `closeBundle` 은 write 성공 시에만 호출.
 */
export async function build(options: BuildOptions): Promise<BuildResult> {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.entryPoints?.length) throw new Error("@zts/core: entryPoints is required");

  const napiOptions = prepareNapiOptions(options);

  // Array 형태 alias (#2153) — onResolve plugin 으로 변환해 user plugins 앞에 prepend.
  // 다른 plugin 의 onResolve 보다 먼저 매칭되어 alias 치환이 우선 적용 (Vite 동작).
  const arrayAlias = Array.isArray(options.alias) ? options.alias : null;
  const userPlugins = options.plugins ?? [];
  const allPlugins = arrayAlias ? [arrayAliasToPlugin(arrayAlias), ...userPlugins] : userPlugins;
  const dispatcher = allPlugins.length ? createPluginDispatcher(allPlugins) : null;
  if (dispatcher) napiOptions._pluginDispatcher = dispatcher;

  // lifecycle hook (#2156): buildStart / buildEnd 는 native bundler 가 dispatch (single source).
  // JS 측에서 별도 호출 시 이중 발화. 단 closeBundle 은 Rollup 의미 ("write 완료 후") 보존을
  // 위해 writeOutputFiles 다음에 JS layer 가 직접 호출 — native bundle() 끝 시점은 contents
  // 결정 직후라 disk write *전* 이므로 closeBundle 자리 부적합.
  const result: BuildResult = await native.build(napiOptions);

  postProcessCssOutputs(result, options);
  writeOutputFiles(result, options);

  if (dispatcher) await dispatcher("closeBundle", undefined, null);
  return result;
}

/**
 * 번들링을 동기적으로 실행한다.
 * 주의: JS 플러그인은 build() (async)에서만 지원됨.
 */
export function buildSync(options: BuildOptions): BuildResult {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.entryPoints?.length) throw new Error("@zts/core: entryPoints is required");
  if (options.plugins?.length) {
    throw new Error(
      "@zts/core: plugins are only supported with build() (async). Use build() instead of buildSync().",
    );
  }
  // Array 형태 alias 는 host RegExp 위임이 plugin hook 기반이라 buildSync 미지원.
  if (Array.isArray(options.alias)) {
    throw new Error(
      "@zts/core: array-form alias (with RegExp / Vite-style) requires async build(). Use Record<string, string> form for buildSync, or call build() instead.",
    );
  }

  const napiOptions = prepareNapiOptions(options);
  const result: BuildResult = native.buildSync(napiOptions);
  postProcessCssOutputs(result, options);
  writeOutputFiles(result, options);
  return result;
}

export function buildAppSync(options: AppBuildOptions = {}): BuildResult {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  const { publicDir, compiler, ...rest } = options;
  return native.buildAppSync({
    ...rest,
    define: withDefaultAppBuildDefines(options),
    ...(publicDir === false
      ? { disablePublicDir: true }
      : publicDir !== undefined
        ? { publicDir }
        : {}),
    // compiler.* → flat NAPI fields. `prepareNapiOptions` 와 동일 변환을 한 곳에서.
    ...buildCompilerNapiFields(compiler),
  });
}

/// `compiler.styledComponents` / `compiler.emotion` (boolean / 객체 form) 를 평면 NAPI
/// 필드로 변환. `prepareNapiOptions` (buildSync) 와 `buildAppSync` 양쪽이 공유.
function buildCompilerNapiFields(compiler: AppBuildOptions["compiler"]): Record<string, unknown> {
  const out: Record<string, unknown> = {};

  const sc = compiler?.styledComponents;
  if (sc !== undefined && sc !== false) out.styledComponents = true;
  if (typeof sc === "object") {
    if (sc.ssr === false) out.styledComponentsSsr = false;
    if (sc.minify === true) out.styledComponentsMinify = true;
    if (sc.fileName === false) out.styledComponentsFileName = false;
    if (sc.pure === true) out.styledComponentsPure = true;
    if (typeof sc.namespace === "string" && sc.namespace.length > 0) {
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
  if (typeof em === "object") {
    if (em.autoLabel === false) out.emotionAutoLabel = "never";
    else if (em.autoLabel === true) out.emotionAutoLabel = "always";
    else if (typeof em.autoLabel === "string") out.emotionAutoLabel = em.autoLabel;
    if (em.sourceMap === true) out.emotionSourceMap = true;
    if (typeof em.labelFormat === "string" && em.labelFormat.length > 0) {
      out.emotionLabelFormat = em.labelFormat;
    }
    const extras = collectEmotionImportMapExtras(em.importMap);
    if (extras.css.length > 0) out.emotionExtraCssSources = extras.css;
    if (extras.styled.length > 0) out.emotionExtraStyledSources = extras.styled;
  }

  return out;
}

export function prepareAppDevSync(options: AppDevPrepareOptions = {}): AppDevPrepareResult {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  const { publicDir, ...rest } = options;
  return native.prepareAppDevSync({
    ...rest,
    ...(publicDir === false
      ? { disablePublicDir: true }
      : publicDir !== undefined
        ? { publicDir }
        : {}),
  });
}

/**
 * 리소스 해제 (NAPI 모듈은 프로세스 종료 시 자동 해제).
 * API 호환성을 위해 유지.
 */
export function close(): void {
  native = null;
}

// ─── Benchmark API (CLI `zts bench` 의 NAPI 대응) ───

/**
 * 벤치마크 옵션. `source` 또는 `file` 중 하나는 반드시 지정.
 */
export interface BenchmarkOptions {
  /** Source 코드 문자열 (file 과 둘 중 하나) */
  source?: string;
  /** 파일 경로 (source 와 둘 중 하나) */
  file?: string;
  /** filename (source 와 함께 사용, 확장자 감지) */
  filename?: string;
  /**
   * 측정할 profile category 목록 (required, non-empty).
   * 예: `["parse"]`, `["scan", "parse", "transform"]`, `["transform.jsx"]`.
   * `all` / `none` 은 허용되지 않음 — 구체적 phase 이름만.
   */
  phases: string[];
  /** 반복 횟수 (default 100) */
  iterations?: number;
  /** Warmup 반복 (default 10) */
  warmup?: number;
}

/**
 * Phase 하나의 통계 (모든 값 ms 단위).
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
 * 벤치마크 결과 — `phases` 옵션에 지정된 각 category 별 통계.
 */
export interface BenchmarkResult {
  phases: Record<string, BenchmarkPhaseStats>;
}

/**
 * 특정 phase 를 N 회 반복 실행하고 통계 (mean/median/p95/p99/stddev/min/max) 를 반환한다.
 *
 * CLI `zts bench --phase=...` 의 NAPI 대응 — 같은 engine 사용.
 *
 * @example
 * ```ts
 * import { init, benchmark } from "@zts/core";
 * init();
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
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.source && !options.file) {
    throw new Error("@zts/core.benchmark: 'source' or 'file' is required");
  }
  if (!Array.isArray(options.phases) || options.phases.length === 0) {
    throw new Error("@zts/core.benchmark: 'phases' must be a non-empty string array");
  }
  return native.benchmark({
    source: options.source,
    file: options.file,
    filename: options.filename ?? "input.js",
    phases: options.phases,
    iterations: options.iterations ?? 100,
    warmup: options.warmup ?? 10,
  });
}

// ─── Vite/Rollup 플러그인 어댑터 ───

/**
 * Rollup/Vite 스타일 플러그인을 ZTS 플러그인으로 변환한다.
 *
 * @example
 * ```ts
 * import { vitePlugin } from "@zts/core";
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

export interface RollupPlugin {
  name: string;
  resolveId?(
    source: string,
    importer?: string | null,
  ): MaybePromise<string | null | undefined | void | { id: string; external?: boolean }>;
  load?(
    id: string,
  ): MaybePromise<string | null | undefined | void | { code: string; map?: unknown }>;
  transform?(
    code: string,
    id: string,
  ): MaybePromise<string | null | undefined | void | { code: string; map?: unknown }>;
  renderChunk?(
    code: string,
    chunk: string,
  ): MaybePromise<string | null | undefined | void | { code: string }>;
  generateBundle?(outputs: OutputFile[]): MaybePromise<void>;
  /** Bundle 시작 시 1회. esbuild `onStart` / Rollup `buildStart` 호환 (#2156).
   *  ZTS 는 인자 없이 호출 (esbuild 스타일) — Rollup plugin 이 `options` 인자를 기대하면
   *  plugin 자체 closure 로 받아둘 것. `this` context 는 미지원. */
  buildStart?(): MaybePromise<void>;
  /** Bundle 종료 시 1회. Rollup `buildEnd` 호환 — error 가 있으면 빌드 실패. */
  buildEnd?(error?: Error): MaybePromise<void>;
  /** Output 파일 write 완료 후. Rollup `closeBundle` 호환. */
  closeBundle?(): MaybePromise<void>;
}

export function vitePlugin(rollupPlugin: RollupPlugin): ZtsPlugin {
  return {
    name: rollupPlugin.name,
    setup(build) {
      if (rollupPlugin.resolveId) {
        const hook = rollupPlugin.resolveId;
        build.onResolve({ filter: /.*/ }, async (args) => {
          const result = await hook(args.path, args.importer);
          if (result == null) return null;
          if (typeof result === "string") return { path: result };
          if (typeof result === "object" && "id" in result) {
            return { path: result.id, external: result.external };
          }
          return null;
        });
      }

      if (rollupPlugin.load) {
        const hook = rollupPlugin.load;
        build.onLoad({ filter: /.*/ }, async (args) => {
          const result = await hook(args.path);
          if (result == null) return null;
          if (typeof result === "string") return { contents: result };
          if (typeof result === "object" && "code" in result) {
            return { contents: result.code };
          }
          return null;
        });
      }

      if (rollupPlugin.transform) {
        const hook = rollupPlugin.transform;
        build.onTransform({ filter: /.*/ }, async (args) => {
          const result = await hook(args.code, args.path);
          if (result == null) return null;
          if (typeof result === "string") return { code: result };
          if (typeof result === "object" && "code" in result) {
            return { code: result.code };
          }
          return null;
        });
      }

      if (rollupPlugin.renderChunk) {
        const hook = rollupPlugin.renderChunk;
        build.onRenderChunk({ filter: /.*/ }, async (args) => {
          const result = await hook(args.code, args.chunk);
          if (result == null) return null;
          if (typeof result === "string") return { code: result };
          if (typeof result === "object" && "code" in result) {
            return { code: result.code };
          }
          return null;
        });
      }

      if (rollupPlugin.generateBundle) {
        const hook = rollupPlugin.generateBundle;
        build.onGenerateBundle(async (outputs) => {
          await hook(outputs);
        });
      }

      if (rollupPlugin.buildStart) {
        const hook = rollupPlugin.buildStart;
        build.onBuildStart(async () => {
          await hook();
        });
      }

      if (rollupPlugin.buildEnd) {
        const hook = rollupPlugin.buildEnd;
        build.onBuildEnd(async (err) => {
          await hook(err);
        });
      }

      if (rollupPlugin.closeBundle) {
        const hook = rollupPlugin.closeBundle;
        build.onCloseBundle(async () => {
          await hook();
        });
      }
    },
  };
}

/**
 * Watch 모드로 번들링한다. 파일 변경 시 incremental rebuild + HMR diff.
 * 초기 빌드 완료 시 onReady, 리빌드 시 onRebuild 콜백 호출.
 */
export function watch(options: BuildOptions): WatchHandle {
  if (!native) throw new Error("call init() first");

  const nativeOpts = prepareNapiOptions(options);

  if (options.plugins && options.plugins.length > 0) {
    nativeOpts._pluginDispatcher = createPluginDispatcher(options.plugins);
  }

  return native.watch(nativeOpts);
}
