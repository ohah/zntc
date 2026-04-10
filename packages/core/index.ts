/**
 * @zts/core — ZTS TypeScript 트랜스파일러 네이티브 바인딩
 *
 * bun:ffi를 사용하여 네이티브 dylib을 in-process로 로드.
 * NAPI와 동일한 성능 특성 (프로세스 spawn 없음, 직렬화 없음).
 *
 * @example
 * ```ts
 * import { init, transpile } from "@zts/core";
 * init(); // 또는 init("/path/to/libzts.dylib")
 * const result = transpile("const x: number = 1;");
 * console.log(result.code);
 * ```
 */

import { dlopen, FFIType, ptr, toBuffer } from "bun:ffi";
import { existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

// ─── Types (packages/wasm과 동일) ───

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

// ─── FFI Instance ───

interface ZtsLib {
  symbols: {
    zts_transpile(
      srcPtr: number,
      srcLen: number,
      filePtr: number,
      fileLen: number,
      flags: number,
      unsupported: number,
      jsxFactoryPtr: number,
      jsxFactoryLen: number,
      jsxFragmentPtr: number,
      jsxFragmentLen: number,
      jsxImportSourcePtr: number,
      jsxImportSourceLen: number,
    ): number | null;
    zts_result_len(): number;
    zts_error_ptr(): number | null;
    zts_error_len(): number;
    zts_free_result(): void;
  };
  close(): void;
}

let lib: ZtsLib | null = null;

// ─── ES Target → UnsupportedFeatures bitmask ───

const ES_TARGET_BITS: Record<string, number> = {
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

// ─── 옵션 인코딩 (wasm/index.ts와 동일한 비트 레이아웃) ───

function encodeFlags(opts: TranspileOptions = {}): number {
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

// ─── dylib 경로 탐색 ───

function findDylib(): string {
  const __dirname = dirname(fileURLToPath(import.meta.url));

  // 1. 패키지 루트 (배포 시)
  const local = join(__dirname, "libzts.dylib");
  if (existsSync(local)) return local;

  // 2. zig-out (개발 시)
  const zigOut = join(__dirname, "../../zig-out/lib/libzts.dylib");
  if (existsSync(zigOut)) return zigOut;

  throw new Error("@zts/core: libzts.dylib not found. Run `zig build ffi` first.");
}

// ─── Public API ───

/**
 * 네이티브 FFI 라이브러리를 로드한다.
 * 이미 로드된 경우 무시한다.
 *
 * @param dylibPath - dylib 경로 (생략 시 자동 탐색)
 */
export function init(dylibPath?: string): void {
  if (lib) return;

  const path = dylibPath ?? findDylib();
  lib = dlopen(path, {
    zts_transpile: {
      args: [
        FFIType.ptr,
        FFIType.u32, // src
        FFIType.ptr,
        FFIType.u32, // file
        FFIType.u32, // flags
        FFIType.u32, // unsupported
        FFIType.ptr,
        FFIType.u32, // jsx_factory
        FFIType.ptr,
        FFIType.u32, // jsx_fragment
        FFIType.ptr,
        FFIType.u32, // jsx_import_source
      ],
      returns: FFIType.ptr,
    },
    zts_result_len: { args: [], returns: FFIType.u32 },
    zts_error_ptr: { args: [], returns: FFIType.ptr },
    zts_error_len: { args: [], returns: FFIType.u32 },
    zts_free_result: { args: [], returns: FFIType.void },
  }) as unknown as ZtsLib;
}

/**
 * TypeScript/JSX 소스 코드를 트랜스파일한다.
 *
 * @param source - 소스 코드 문자열
 * @param options - 트랜스파일 옵션
 * @returns 변환된 코드와 선택적 소스맵
 */
export function transpile(source: string, options: TranspileOptions = {}): TranspileResult {
  if (!lib) {
    throw new Error("@zts/core: not initialized. Call init() first.");
  }

  if (!source) {
    throw new Error("@zts/core: empty source");
  }

  const srcBuf = Buffer.from(source);
  const fileBuf = Buffer.from(options.filename ?? "input.ts");
  const flags = encodeFlags(options);
  const unsupported = options.target ? (ES_TARGET_BITS[options.target] ?? 0) : 0;

  // 문자열 옵션 (없으면 빈 Buffer → ptr=0, len=0)
  const factoryBuf = options.jsxFactory ? Buffer.from(options.jsxFactory) : null;
  const fragmentBuf = options.jsxFragment ? Buffer.from(options.jsxFragment) : null;
  const importSourceBuf = options.jsxImportSource ? Buffer.from(options.jsxImportSource) : null;

  const resultPtr = lib.symbols.zts_transpile(
    ptr(srcBuf),
    srcBuf.length,
    ptr(fileBuf),
    fileBuf.length,
    flags,
    unsupported,
    factoryBuf ? ptr(factoryBuf) : 0,
    factoryBuf?.length ?? 0,
    fragmentBuf ? ptr(fragmentBuf) : 0,
    fragmentBuf?.length ?? 0,
    importSourceBuf ? ptr(importSourceBuf) : 0,
    importSourceBuf?.length ?? 0,
  );

  if (resultPtr === null || resultPtr === 0) {
    const errLen = lib.symbols.zts_error_len();
    const errPtr = lib.symbols.zts_error_ptr();
    if (errPtr && errLen > 0) {
      const errMsg = Buffer.from(toBuffer(errPtr, 0, errLen)).toString();
      lib.symbols.zts_free_result();
      throw new Error(`@zts/core: ${errMsg}`);
    }
    lib.symbols.zts_free_result();
    throw new Error("@zts/core: transpile failed");
  }

  const len = lib.symbols.zts_result_len();
  const raw = Buffer.from(toBuffer(resultPtr, 0, len)).toString();
  lib.symbols.zts_free_result();

  // 소스맵이 있으면 \0 구분자로 분리
  const nullIdx = options.sourcemap ? raw.indexOf("\0") : -1;
  if (nullIdx !== -1) {
    return { code: raw.slice(0, nullIdx), map: raw.slice(nullIdx + 1) };
  }

  return { code: raw };
}

/**
 * FFI 라이브러리를 언로드한다.
 */
export function close(): void {
  if (lib) {
    lib.close();
    lib = null;
  }
}
