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
}

export interface BuildResult {
  outputFiles: OutputFile[];
  errors: Diagnostic[];
  warnings: Diagnostic[];
  metafile?: string;
}

/**
 * 번들링을 비동기적으로 실행한다. 이벤트 루프를 블로킹하지 않음.
 */
export async function build(options: BuildOptions): Promise<BuildResult> {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.entryPoints?.length) throw new Error("@zts/core: entryPoints is required");

  return native.build(options as unknown as Record<string, unknown>);
}

/**
 * 번들링을 동기적으로 실행한다.
 */
export function buildSync(options: BuildOptions): BuildResult {
  if (!native) throw new Error("@zts/core: not initialized. Call init() first.");
  if (!options.entryPoints?.length) throw new Error("@zts/core: entryPoints is required");

  return native.buildSync(options as unknown as Record<string, unknown>);
}

/**
 * 리소스 해제 (NAPI 모듈은 프로세스 종료 시 자동 해제).
 * API 호환성을 위해 유지.
 */
export function close(): void {
  native = null;
}
