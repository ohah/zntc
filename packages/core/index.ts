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

export type { Target, Platform, TranspileOptions, TranspileResult } from "../shared/index";
import type { TranspileOptions } from "../shared/index";
import { encodeFlags, ES_TARGET_BITS } from "../shared/index";

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
