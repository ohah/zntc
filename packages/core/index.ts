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
 * const result = transpile("const x: number = 1;");
 * console.log(result.code);
 * ```
 */

import { createRequire } from "module";
import { existsSync, mkdirSync, writeFileSync } from "fs";
import { join, dirname, resolve } from "path";
import { fileURLToPath } from "url";

export type { Target, Platform, TranspileOptions, TranspileResult } from "../shared/index";
import type { TranspileOptions, TranspileResult } from "../shared/index";
import { encodeFlags, ES_TARGET_BITS, browserslistToUnsupported } from "../shared/index";

// ─── NAPI Module ───

interface OutputFile {
  path: string;
  text: string;
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
}

interface NativeModule {
  transpile(
    source: string,
    filename: string,
    flags: number,
    unsupported: number,
    jsxFactory: string,
    jsxFragment: string,
    jsxImportSource: string,
  ): { code: string; map?: string };
  buildSync(options: Record<string, unknown>): NativeBuildResult;
  build(options: Record<string, unknown>): Promise<NativeBuildResult>;
  watch(options: Record<string, unknown>): NativeWatchHandle;
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
 * browserslist 모듈 lazy-load 캐시. CJS require 캐시도 동작하지만
 * 매 transpile마다 require() 호출 자체를 피해 오버헤드 제거.
 */
let _browserslist: ((q: string | string[]) => string[]) | null = null;

/**
 * target | browserslist → UnsupportedFeatures bitmask.
 * browserslist가 지정되면 우선. 둘 다 없으면 0 (esnext).
 */
function resolveUnsupported(options: TranspileOptions): number {
  if (options.browserslist) {
    if (!_browserslist) {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      _browserslist = require("browserslist") as (q: string | string[]) => string[];
    }
    const entries = _browserslist(options.browserslist);
    return browserslistToUnsupported(entries);
  }
  return options.target ? (ES_TARGET_BITS[options.target] ?? 0) : 0;
}

export function transpile(source: string, options: TranspileOptions = {}): TranspileResult {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!source) throw new Error("@zts/core: empty source");

  const flags = encodeFlags(options);
  const unsupported = resolveUnsupported(options);

  return native.transpile(
    source,
    options.filename ?? "input.ts",
    flags,
    unsupported,
    options.jsxFactory ?? "",
    options.jsxFragment ?? "",
    options.jsxImportSource ?? "",
  );
}

// ─── Build API ───

export type { OutputFile, Diagnostic };

export interface BuildOptions {
  entryPoints: string[];
  format?: "esm" | "cjs" | "iife" | "umd" | "amd";
  platform?: "browser" | "node" | "neutral" | "react-native";
  external?: string[];
  minify?: boolean;
  minifyWhitespace?: boolean;
  minifyIdentifiers?: boolean;
  minifySyntax?: boolean;
  splitting?: boolean;
  sourcemap?: boolean;
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
  jsx?: "classic" | "automatic" | "automatic-dev";
  jsxFactory?: string;
  jsxFragment?: string;
  jsxImportSource?: string;
  define?: Record<string, string>;
  alias?: Record<string, string>;
  inject?: string[];
  jobs?: number;
  plugins?: ZtsPlugin[];
  /** 확장자별 로더 오버라이드 (예: { ".png": "file", ".svg": "text" }) */
  loader?: Record<string, string>;
  /** package.json exports 커스텀 조건 */
  conditions?: string[];
  /** 확장자 탐색 순서 (예: [".ts", ".tsx", ".js"]) */
  resolveExtensions?: string[];
  /** package.json 필드 순서 (예: ["module", "main"]) */
  mainFields?: string[];
  /** ES 다운레벨 타겟 ("es5" ~ "esnext") */
  target?: import("../shared/index").Target;
  // browserslist는 build API에서 아직 구현되지 않았다. transpile API에서만 사용 가능.
  // 구현 완료 후 이 위치에 필드를 추가한다.
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
  /** 순수 함수로 마킹할 글로벌 함수명 목록 */
  pure?: string[];
  /** tsconfig.json 인라인 JSON 오버라이드 */
  tsconfigRaw?: string;
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
  /** 파이프라인 단계별 타이밍 출력 */
  timing?: boolean;
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
  /** worklet의 `__pluginVersion` 값 (Reanimated dev mode jsVersion 대조용).
   * 사용자 환경의 react-native-worklets 패키지 version을 전달해야 런타임 에러 없음. */
  workletPluginVersion?: string;
  /** scope hoisting 시 예약할 전역 식별자 */
  globalIdentifiers?: string[];
  /** 번들 시작 시 즉시 실행 폴리필 경로 */
  polyfills?: string[];
  /** 엔트리 모듈 직전에 실행할 모듈 경로 */
  runBeforeMain?: string[];
  /** watch 모드 빌드 완료 콜백 */
  onReady?: (event: WatchReadyEvent) => void;
  /** watch 모드 리빌드 콜백 */
  onRebuild?: (event: WatchRebuildEvent) => void;
}

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
  /** 단계별 빌드 시간 (밀리초). 성공한 리빌드에서만 노출. */
  phaseDurations?: {
    /** 변경 감지 (mtime 스캔) */
    detect: number;
    /** 파싱 (resolve + parse + finalize) */
    parse: number;
    /** 의미 분석 (scope hoisting + linking + tree-shaking) */
    semantic: number;
    /** 코드 생성 (transform + codegen) */
    emit: number;
    /** HMR delta 추출 */
    delta: number;
    /** 총 리빌드 시간 (detect → delta 합산) */
    total: number;
  };
  /** 증분 그래프에서 재파싱된 모듈 수. 캐시 미스된 모듈만 카운트. 전체 빌드에서는 미노출. */
  reparsedModules?: number;
}

export interface WatchHandle {
  stop(): void;
}

export interface ZtsPlugin {
  name: string;
  setup(build: PluginBuild): void;
}

export interface PluginBuild {
  onResolve(
    options: { filter: RegExp },
    callback: (args: {
      path: string;
      importer: string | null;
    }) => { path: string; external?: boolean } | null | undefined,
  ): void;
  onLoad(
    options: { filter: RegExp },
    callback: (args: { path: string }) => { contents: string; loader?: string } | null | undefined,
  ): void;
  onTransform(
    options: { filter: RegExp },
    callback: (args: { code: string; path: string }) => { code: string } | null | undefined,
  ): void;
  onRenderChunk(
    options: { filter: RegExp },
    callback: (args: { code: string; chunk: string }) => { code: string } | null | undefined,
  ): void;
  onGenerateBundle(callback: (outputs: OutputFile[]) => void): void;
  onAstFunction(
    options: { filter: RegExp },
    callback: (
      info: AstFunctionInfo,
    ) => AstFunctionResult | null | undefined | Promise<AstFunctionResult | null | undefined>,
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
  };
  const generateBundleCallbacks: Array<(outputs: OutputFile[]) => void> = [];
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
      onAstFunction(opts, cb) {
        astFunctionHooks.push({ filter: opts.filter, callback: cb });
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

  return async function dispatcher(
    hookName: string,
    arg1: string | OutputFile[],
    arg2: string | null,
  ) {
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

    // generateBundle: arg1이 OutputFile[] 배열
    if (hookName === "generateBundle") {
      const outputs = arg1 as OutputFile[];
      for (const cb of generateBundleCallbacks) {
        try {
          await cb(outputs);
        } catch {
          // 에러 시 건너뛰기
        }
      }
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
function prepareNapiOptions(options: BuildOptions): Record<string, unknown> {
  const napiOptions: Record<string, unknown> = { ...options };
  delete napiOptions.write;
  delete napiOptions.outdir;
  delete napiOptions.plugins;
  delete napiOptions.allowOverwrite;
  return napiOptions;
}

/**
 * CSS 출력 파일을 Lightning CSS로 후처리한다 (minify, 프리픽스 등).
 * lightningcss가 설치되어 있지 않으면 원본 그대로 반환.
 */
function postProcessCssOutputs(result: BuildResult, options: BuildOptions): void {
  if (!options.minify) return;

  let lcss: typeof import("lightningcss") | null = null;
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
 */
export async function build(options: BuildOptions): Promise<BuildResult> {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.entryPoints?.length) throw new Error("@zts/core: entryPoints is required");

  const napiOptions = prepareNapiOptions(options);

  if (options.plugins?.length) {
    napiOptions._pluginDispatcher = createPluginDispatcher(options.plugins);
  }

  const result: BuildResult = await native.build(napiOptions);
  postProcessCssOutputs(result, options);
  writeOutputFiles(result, options);
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

  const napiOptions = prepareNapiOptions(options);
  const result: BuildResult = native.buildSync(napiOptions);
  postProcessCssOutputs(result, options);
  writeOutputFiles(result, options);
  return result;
}

/**
 * 리소스 해제 (NAPI 모듈은 프로세스 종료 시 자동 해제).
 * API 호환성을 위해 유지.
 */
export function close(): void {
  native = null;
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
