/**
 * @zts/wasm — ZTS TypeScript 트랜스파일러 WASM 바인딩
 *
 * @example
 * ```ts
 * import { init, transpile } from "@zts/wasm";
 * await init();
 * const result = transpile("const x: number = 1;", { target: "es5" });
 * console.log(result.code);
 * ```
 */

export type { Target, Platform, TranspileOptions, TranspileResult } from "../shared/index";
import type { TranspileOptions, TranspileResult } from "../shared/index";
import { encodeFlags, targetToUnsupported } from "../shared/index";

// ─── WASM Instance ───

interface WasmExports {
  memory: WebAssembly.Memory;
  alloc(len: number): number;
  dealloc(ptr: number, len: number): void;
  transpile(
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
    sourceRootPtr: number,
    sourceRootLen: number,
  ): bigint;
  get_error_ptr(): number;
  get_error_len(): number;
}

let wasm: WasmExports | null = null;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// ─── 최소 WASI shim ───

function createWasiImports(memory: () => WebAssembly.Memory) {
  return {
    wasi_snapshot_preview1: {
      fd_write(fd: number, iovs_ptr: number, iovs_len: number, nwritten_ptr: number): number {
        const mem = new DataView(memory().buffer);
        const bytes = new Uint8Array(memory().buffer);
        let written = 0;
        for (let i = 0; i < iovs_len; i++) {
          const ptr = mem.getUint32(iovs_ptr + i * 8, true);
          const len = mem.getUint32(iovs_ptr + i * 8 + 4, true);
          const chunk = bytes.slice(ptr, ptr + len);
          if (fd === 2) console.error(decoder.decode(chunk));
          written += len;
        }
        mem.setUint32(nwritten_ptr, written, true);
        return 0;
      },
      fd_read(): number {
        return 8;
      },
      fd_seek(): number {
        return 8;
      },
      fd_pwrite(): number {
        return 8;
      },
      fd_filestat_get(): number {
        return 8;
      },
      random_get(buf_ptr: number, buf_len: number): number {
        const bytes = new Uint8Array(memory().buffer, buf_ptr, buf_len);
        if (typeof globalThis.crypto !== "undefined") {
          crypto.getRandomValues(bytes);
        } else {
          for (let i = 0; i < buf_len; i++) bytes[i] = (Math.random() * 256) | 0;
        }
        return 0;
      },
    },
  };
}

// ─── 문자열 헬퍼 ───

function writeString(s: string): [number, number] {
  const bytes = encoder.encode(s);
  const ptr = wasm!.alloc(bytes.length);
  if (ptr === 0) throw new Error("zts-wasm: alloc failed");
  new Uint8Array(wasm!.memory.buffer, ptr, bytes.length).set(bytes);
  return [ptr, bytes.length];
}

function readString(ptr: number, len: number): string {
  return decoder.decode(new Uint8Array(wasm!.memory.buffer, ptr, len));
}

function writeOptionalString(s?: string): [number, number] {
  if (!s) return [0, 0];
  return writeString(s);
}

// ─── Public API ───

export async function init(
  input?: URL | string | Request | Response | BufferSource | WebAssembly.Module,
): Promise<void> {
  if (wasm) return;

  let source: BufferSource | WebAssembly.Module | Response;

  if (input === undefined) {
    const fs = await import("fs");
    const path = await import("path");
    const url = await import("url");
    const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
    source = fs.readFileSync(path.join(__dirname, "zts.wasm"));
  } else if (input instanceof WebAssembly.Module) {
    source = input;
  } else if (input instanceof Response) {
    source = input;
  } else if (input instanceof ArrayBuffer || ArrayBuffer.isView(input)) {
    source = input as BufferSource;
  } else {
    source = await fetch(input as string | URL | Request);
  }

  let instance: WebAssembly.Instance;
  let memory: WebAssembly.Memory;
  const imports = createWasiImports(() => memory);

  if (source instanceof WebAssembly.Module) {
    instance = new WebAssembly.Instance(source, imports);
  } else if (source instanceof Response) {
    const result = await WebAssembly.instantiateStreaming(source, imports);
    instance = result.instance;
  } else {
    const result = await WebAssembly.instantiate(source, imports);
    instance = result.instance;
  }

  memory = instance.exports.memory as WebAssembly.Memory;
  wasm = instance.exports as unknown as WasmExports;
}

export function initSync(input: WebAssembly.Module | BufferSource): void {
  if (wasm) return;

  let memory: WebAssembly.Memory;
  const imports = createWasiImports(() => memory);

  const mod =
    input instanceof WebAssembly.Module
      ? input
      : new WebAssembly.Module(
          input instanceof ArrayBuffer ? input : (input as ArrayBufferView).buffer,
        );

  const instance = new WebAssembly.Instance(mod, imports);
  memory = instance.exports.memory as WebAssembly.Memory;
  wasm = instance.exports as unknown as WasmExports;
}

export function transpile(source: string, options: TranspileOptions = {}): TranspileResult {
  if (!wasm) {
    throw new Error("zts-wasm: not initialized. Call init() or initSync() first.");
  }

  const [srcPtr, srcLen] = writeString(source);
  const [filePtr, fileLen] = options.filename ? writeString(options.filename) : [0, 0];
  const [factoryPtr, factoryLen] = writeOptionalString(options.jsxFactory);
  const [fragmentPtr, fragmentLen] = writeOptionalString(options.jsxFragment);
  const [importSourcePtr, importSourceLen] = writeOptionalString(options.jsxImportSource);
  const [sourceRootPtr, sourceRootLen] = writeOptionalString(options.sourceRoot);

  const flags = encodeFlags(options);
  const unsupported = targetToUnsupported(options.target);

  try {
    const packed = wasm.transpile(
      srcPtr,
      srcLen,
      filePtr,
      fileLen,
      flags,
      unsupported,
      factoryPtr,
      factoryLen,
      fragmentPtr,
      fragmentLen,
      importSourcePtr,
      importSourceLen,
      sourceRootPtr,
      sourceRootLen,
    );

    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);

    // tsc 호환: 시맨틱 에러는 code와 함께 반환되므로 성공 경로에서도 확인.
    // 핫패스(에러 없음)에서는 get_error_len 한 번만 호출 — 0이면 ptr/readString 스킵.
    const errLen = wasm.get_error_len();
    const errMsg = errLen === 0 ? "" : readString(wasm.get_error_ptr(), errLen);

    if (outPtr === 0) {
      throw new Error(`zts-wasm: ${errMsg || "unknown error"}`);
    }

    const raw = readString(outPtr, outLen);
    wasm.dealloc(outPtr, outLen);

    const nullIdx = options.sourcemap ? raw.indexOf("\0") : -1;
    const result: TranspileResult =
      nullIdx !== -1 ? { code: raw.slice(0, nullIdx), map: raw.slice(nullIdx + 1) } : { code: raw };

    if (errMsg) result.errors = errMsg;
    return result;
  } finally {
    wasm.dealloc(srcPtr, srcLen);
    if (filePtr) wasm.dealloc(filePtr, fileLen);
    if (factoryPtr) wasm.dealloc(factoryPtr, factoryLen);
    if (fragmentPtr) wasm.dealloc(fragmentPtr, fragmentLen);
    if (importSourcePtr) wasm.dealloc(importSourcePtr, importSourceLen);
    if (sourceRootPtr) wasm.dealloc(sourceRootPtr, sourceRootLen);
  }
}
