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

// ─── Types ───

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

// ─── ES Target → UnsupportedFeatures bitmask ───
// compat.zig의 Feature enum/ESTarget과 동일한 비트 레이아웃

const ES_TARGET_BITS: Record<string, number> = {
  es5: 0x1fffff, // bit 0-20: 모든 feature unsupported
  es2015: 0x1ff800, // bit 11-20
  es2016: 0x1ff000, // bit 12-20
  es2017: 0x1fe000, // bit 13-20
  es2018: 0x1fc000, // bit 14-20
  es2019: 0x1f8000, // bit 15-20
  es2020: 0x1e0000, // bit 17-20
  es2021: 0x1c0000, // bit 18-20
  es2022: 0x100000, // bit 20 (using)
  es2024: 0x100000, // bit 20 (using) — es2022와 동일
  es2025: 0x0,
  esnext: 0x0,
};

function targetToUnsupported(target?: Target): number {
  if (!target) return 0;
  return ES_TARGET_BITS[target] ?? 0;
}

// ─── 옵션 인코딩 ───

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
  // useDefineForClassFields: 기본값 true, false일 때만 비트 0
  if (opts.useDefineForClassFields !== false) flags |= 1 << 16;
  if (opts.charsetUtf8) flags |= 1 << 17;
  // platform
  if (opts.platform === "node") flags |= 1 << 18;
  if (opts.platform === "neutral") flags |= 2 << 18;
  if (opts.platform === "react-native") flags |= 3 << 18;
  if (opts.jsxInJs) flags |= 1 << 20;
  if (opts.sourcemapDebugIds) flags |= 1 << 21;
  // sourcesContent: 기본값 true
  if (opts.sourcesContent !== false) flags |= 1 << 22;
  return flags;
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
    );

    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);

    if (outPtr === 0) {
      const errPtr = wasm.get_error_ptr();
      const errLen = wasm.get_error_len();
      const errMsg = errPtr ? readString(errPtr, errLen) : "unknown error";
      throw new Error(`zts-wasm: ${errMsg}`);
    }

    const raw = readString(outPtr, outLen);
    wasm.dealloc(outPtr, outLen);

    const nullIdx = options.sourcemap ? raw.indexOf("\0") : -1;
    if (nullIdx !== -1) {
      return { code: raw.slice(0, nullIdx), map: raw.slice(nullIdx + 1) };
    }

    return { code: raw };
  } finally {
    wasm.dealloc(srcPtr, srcLen);
    if (filePtr) wasm.dealloc(filePtr, fileLen);
    if (factoryPtr) wasm.dealloc(factoryPtr, factoryLen);
    if (fragmentPtr) wasm.dealloc(fragmentPtr, fragmentLen);
    if (importSourcePtr) wasm.dealloc(importSourcePtr, importSourceLen);
  }
}
