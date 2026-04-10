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
import { existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

export type { Target, Platform, TranspileOptions, TranspileResult } from "../shared/index";
import type { TranspileOptions, TranspileResult } from "../shared/index";
import { encodeFlags, ES_TARGET_BITS } from "../shared/index";

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
}

let native: NativeModule | null = null;

// ─── .node 경로 탐색 ───

function findAddon(): string {
  const __dirname = dirname(fileURLToPath(import.meta.url));

  const local = join(__dirname, "zts.node");
  if (existsSync(local)) return local;

  const zigOut = join(__dirname, "../../zig-out/lib/zts.node");
  if (existsSync(zigOut)) return zigOut;

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
export function transpile(source: string, options: TranspileOptions = {}): TranspileResult {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!source) throw new Error("@zts/core: empty source");

  const flags = encodeFlags(options);
  const unsupported = options.target ? (ES_TARGET_BITS[options.target] ?? 0) : 0;

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
  format?: "esm" | "cjs" | "iife";
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
  inject?: string[];
  jobs?: number;
  plugins?: ZtsPlugin[];
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
  };

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
    };
    plugin.setup(build);
  }

  // hookName → { filter 대상, 콜백 인자 } 매핑
  const argBuilders: Record<string, (arg1: string, arg2: string | null) => [string, unknown]> = {
    resolveId: (arg1, arg2) => [arg1, { path: arg1, importer: arg2 }],
    load: (arg1, _) => [arg1, { path: arg1 }],
    transform: (arg1, arg2) => [arg2 ?? "", { code: arg1, path: arg2 }],
  };

  return function dispatcher(hookName: string, arg1: string, arg2: string | null) {
    const hookList = hooks[hookName];
    const buildArgs = argBuilders[hookName];
    if (!hookList || !buildArgs) return null;

    const [filterTarget, cbArgs] = buildArgs(arg1, arg2);
    for (const h of hookList) {
      if (h.filter.test(filterTarget)) {
        const result = h.callback(cbArgs);
        if (result != null) return result;
      }
    }
    return null;
  };
}

/**
 * 번들링을 비동기적으로 실행한다. 이벤트 루프를 블로킹하지 않음.
 * JS 플러그인은 이 함수에서만 지원됨.
 */
export async function build(options: BuildOptions): Promise<BuildResult> {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.entryPoints?.length) throw new Error("@zts/core: entryPoints is required");

  const napiOptions: Record<string, unknown> = { ...options };

  if (options.plugins?.length) {
    napiOptions._pluginDispatcher = createPluginDispatcher(options.plugins);
    delete napiOptions.plugins;
  }

  return native.build(napiOptions);
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

  return native.buildSync(options as unknown as Record<string, unknown>);
}

/**
 * 리소스 해제 (NAPI 모듈은 프로세스 종료 시 자동 해제).
 * API 호환성을 위해 유지.
 */
export function close(): void {
  native = null;
}
