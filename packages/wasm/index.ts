/**
 * @zts/wasm — ZTS TypeScript 트랜스파일러 WASM 바인딩
 *
 * 브라우저와 Node.js 양쪽에서 TypeScript → JavaScript 트랜스파일을 수행한다.
 *
 * @example
 * ```ts
 * import { init, transpile } from "@zts/wasm";
 * await init();
 * const result = transpile("const x: number = 1;");
 * console.log(result.code); // "const x = 1;"
 * ```
 */

// ─── Types ───

export interface TranspileOptions {
  /** 파일 경로 (확장자 감지용, 기본: "input.ts") */
  filename?: string;
  /** 소스맵 생성 */
  sourcemap?: boolean;
  /** 공백 축소 */
  minifyWhitespace?: boolean;
  /** 식별자 축소 */
  minifyIdentifiers?: boolean;
  /** 구문 축소 */
  minifySyntax?: boolean;
  /** 전체 축소 (whitespace + identifiers + syntax) */
  minify?: boolean;
  /** JSX 런타임 ("classic" | "automatic" | "automatic-dev") */
  jsx?: "classic" | "automatic" | "automatic-dev";
  /** console.* 호출 제거 */
  dropConsole?: boolean;
  /** debugger 문 제거 */
  dropDebugger?: boolean;
  /** non-ASCII를 \uXXXX로 이스케이프 */
  asciiOnly?: boolean;
  /** Flow 타입 스트리핑 */
  flow?: boolean;
  /** legacy decorator 변환 */
  experimentalDecorators?: boolean;
  /** decorator metadata emit */
  emitDecoratorMetadata?: boolean;
  /** 모듈 포맷 ("esm" | "cjs") */
  format?: "esm" | "cjs";
  /** 문자열 따옴표 스타일 */
  quotes?: "double" | "single" | "preserve";
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
  ): bigint;
  get_error_ptr(): number;
  get_error_len(): number;
}

let wasm: WasmExports | null = null;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// ─── 최소 WASI shim ───
// fd_write (stderr 출력)만 지원하는 최소 구현.
// WASI reactor 모드에서 std.debug.print 등이 동작하도록 한다.

function createWasiImports(memory: () => WebAssembly.Memory) {
  return {
    wasi_snapshot_preview1: {
      // fd_write: stderr 출력 지원
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
      // fd_read: no-op
      fd_read(): number {
        return 8; // __WASI_ERRNO_BADF
      },
      // fd_seek: no-op
      fd_seek(): number {
        return 8;
      },
      // fd_pwrite: no-op
      fd_pwrite(): number {
        return 8;
      },
      // fd_filestat_get: no-op
      fd_filestat_get(): number {
        return 8;
      },
      // random_get: 랜덤 바이트 (crypto.getRandomValues)
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

// ─── 옵션 인코딩 ───

function encodeFlags(opts: TranspileOptions = {}): number {
  let flags = 0;
  if (opts.sourcemap) flags |= 1 << 0;
  if (opts.minifyWhitespace || opts.minify) flags |= 1 << 1;
  if (opts.minifyIdentifiers || opts.minify) flags |= 1 << 2;
  if (opts.minifySyntax || opts.minify) flags |= 1 << 3;
  if (opts.jsx === "automatic") flags |= 1 << 4;
  if (opts.jsx === "automatic-dev") flags |= (1 << 4) | (1 << 5);
  if (opts.dropConsole) flags |= 1 << 6;
  if (opts.dropDebugger) flags |= 1 << 7;
  if (opts.asciiOnly) flags |= 1 << 8;
  if (opts.flow) flags |= 1 << 9;
  if (opts.experimentalDecorators) flags |= 1 << 10;
  if (opts.emitDecoratorMetadata) flags |= 1 << 11;
  if (opts.format === "cjs") flags |= 1 << 12;
  if (opts.quotes === "single") flags |= 1 << 14;
  if (opts.quotes === "preserve") flags |= 2 << 14;
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

// ─── Public API ───

/**
 * WASM 모듈을 비동기로 초기화한다 (브라우저용).
 * URL, fetch Response, 또는 ArrayBuffer를 받는다.
 *
 * @example
 * ```ts
 * await init(new URL("./zts.wasm", import.meta.url));
 * ```
 */
export async function init(
  input?: URL | string | Request | Response | BufferSource | WebAssembly.Module,
): Promise<void> {
  if (wasm) return;

  let source: BufferSource | WebAssembly.Module | Response;

  if (input === undefined) {
    // Node.js: 같은 디렉토리의 zts.wasm을 읽는다
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
    // URL or string — fetch
    source = await fetch(input as string | URL | Request);
  }

  let instance: WebAssembly.Instance;
  let memory: WebAssembly.Memory;

  // memory는 인스턴스 생성 후에야 접근 가능하므로 lazy getter 사용
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

/**
 * WASM 모듈을 동기적으로 초기화한다.
 * 미리 컴파일된 WebAssembly.Module 또는 ArrayBuffer를 받는다.
 */
export function initSync(input: WebAssembly.Module | BufferSource): void {
  if (wasm) return;

  let memory: WebAssembly.Memory;
  const imports = createWasiImports(() => memory);

  const mod =
    input instanceof WebAssembly.Module
      ? input
      : new WebAssembly.Module(input instanceof ArrayBuffer ? input : (input as Uint8Array).buffer);

  const instance = new WebAssembly.Instance(mod, imports);
  memory = instance.exports.memory as WebAssembly.Memory;
  wasm = instance.exports as unknown as WasmExports;
}

/**
 * TypeScript/JSX 소스를 JavaScript로 트랜스파일한다.
 *
 * @throws init()이 호출되지 않았으면 에러
 * @throws 파싱/변환 에러 시 에러
 */
export function transpile(source: string, options: TranspileOptions = {}): TranspileResult {
  if (!wasm) {
    throw new Error("zts-wasm: not initialized. Call init() or initSync() first.");
  }

  const [srcPtr, srcLen] = writeString(source);
  let filePtr = 0;
  let fileLen = 0;

  const filename = options.filename ?? "input.ts";
  [filePtr, fileLen] = writeString(filename);

  const flags = encodeFlags(options);

  try {
    const packed = wasm.transpile(srcPtr, srcLen, filePtr, fileLen, flags);

    // packed u64: 상위 32비트 = 포인터, 하위 32비트 = 길이
    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);

    if (outPtr === 0) {
      // 에러 발생
      const errPtr = wasm.get_error_ptr();
      const errLen = wasm.get_error_len();
      const errMsg = errPtr ? readString(errPtr, errLen) : "unknown error";
      throw new Error(`zts-wasm: ${errMsg}`);
    }

    const raw = readString(outPtr, outLen);
    wasm.dealloc(outPtr, outLen);

    // 소스맵이 있으면 \0으로 구분되어 있음
    const nullIdx = options.sourcemap ? raw.indexOf("\0") : -1;
    if (nullIdx !== -1) {
      return {
        code: raw.slice(0, nullIdx),
        map: raw.slice(nullIdx + 1),
      };
    }

    return { code: raw };
  } finally {
    wasm.dealloc(srcPtr, srcLen);
    if (filePtr) wasm.dealloc(filePtr, fileLen);
  }
}
