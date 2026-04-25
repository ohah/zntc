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
import { buildOptionsJson, targetToUnsupported } from "../shared/index";

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
    optsJsonPtr: number,
    optsJsonLen: number,
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
      // clock_id: 0=realtime(Date.now ms 해상도), 1/2/3=monotonic/cputime(performance.now).
      // precision 인자는 WASI spec 상 hint 일뿐 무시. 결과는 u64 ns LE 로 timestamp_ptr 기록.
      // 정확도는 호스트 브라우저의 reduced-precision 정책에 종속 (보통 100μs~1ms 단위).
      clock_time_get(clock_id: number, _precision: bigint, ts_ptr: number): number {
        const mem = new DataView(memory().buffer);
        const ns =
          clock_id === 0
            ? BigInt(Date.now()) * 1_000_000n
            : BigInt(Math.floor(performance.now() * 1_000_000));
        mem.setBigUint64(ts_ptr, ns, true);
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

/// 입력을 WebAssembly instantiate 가능한 source 로 정규화. undefined 면 default
/// .wasm 파일 (Node.js 환경) 을 동적으로 읽음.
async function resolveWasmSource(
  input: URL | string | Request | Response | BufferSource | WebAssembly.Module | undefined,
  defaultFile: string,
): Promise<BufferSource | WebAssembly.Module | Response> {
  if (input === undefined) {
    const fs = await import("fs");
    const path = await import("path");
    const url = await import("url");
    const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
    return fs.readFileSync(path.join(__dirname, defaultFile));
  }
  if (input instanceof WebAssembly.Module) return input;
  if (input instanceof Response) return input;
  if (input instanceof ArrayBuffer || ArrayBuffer.isView(input)) {
    return input as BufferSource;
  }
  return await fetch(input as string | URL | Request);
}

/// source + imports 로 WebAssembly instance 생성. Module/Response/BufferSource 분기 처리.
async function instantiateWasm(
  source: BufferSource | WebAssembly.Module | Response,
  imports: WebAssembly.Imports,
): Promise<WebAssembly.Instance> {
  if (source instanceof WebAssembly.Module) {
    return new WebAssembly.Instance(source, imports);
  }
  if (source instanceof Response) {
    const result = await WebAssembly.instantiateStreaming(source, imports);
    return result.instance;
  }
  const result = await WebAssembly.instantiate(source, imports);
  return result.instance;
}

export async function init(
  input?: URL | string | Request | Response | BufferSource | WebAssembly.Module,
): Promise<void> {
  if (wasm) return;
  const source = await resolveWasmSource(input, "zts.wasm");

  let memory: WebAssembly.Memory;
  const imports = createWasiImports(() => memory);
  const instance = await instantiateWasm(source, imports);

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
  const optsJson = buildOptionsJson(options, targetToUnsupported(options.target));
  const [optsPtr, optsLen] = writeString(optsJson);

  try {
    const packed = wasm.transpile(srcPtr, srcLen, filePtr, fileLen, optsPtr, optsLen);

    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);

    // tsc 호환: 시맨틱 에러는 code와 함께 반환되므로 성공 경로에서도 확인.
    // 핫패스(에러 없음)에서는 get_error_len 한 번만 호출 — 0이면 ptr/readString 스킵.
    const errLen = wasm.get_error_len();
    const errMsg = errLen === 0 ? "" : readString(wasm.get_error_ptr(), errLen);

    // outPtr=0 은 두 가지 의미를 갖는다:
    //   1. 빈 출력 성공 (type-only 파일, 빈 입력 등) — outLen=0, errLen=0
    //   2. 에러 (파싱/시맨틱 실패) — errLen>0
    // 빈 출력은 errors 없이 code=""로 반환하고, 에러 경로에서만 throw한다.
    if (outPtr === 0) {
      if (outLen === 0 && errLen === 0) return { code: "" };
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
    wasm.dealloc(optsPtr, optsLen);
  }
}

// ─── Bundler (#1885 Phase 2) ───
//
// 별도 wasm instance (zts-bundler.wasm, wasm32-wasi + threads). transpile-only
// (zts.wasm) 와 격리 — bundler 는 SharedArrayBuffer 필요 (COOP/COEP 헤더).

/// Host 가 제공하는 in-memory file system. bundler 가 fs syscall 시 host JS callback
/// 으로 위임 (zts_fs imports). path → bytes 매핑.
export class VirtualFileSystem {
  private files = new Map<string, Uint8Array>();

  set(path: string, content: string | Uint8Array): void {
    const bytes = typeof content === "string" ? encoder.encode(content) : content;
    this.files.set(path, bytes);
  }

  get(path: string): Uint8Array | undefined {
    return this.files.get(path);
  }

  has(path: string): boolean {
    return this.files.has(path);
  }

  delete(path: string): boolean {
    return this.files.delete(path);
  }

  paths(): IterableIterator<string> {
    return this.files.keys();
  }

  size(): number {
    return this.files.size;
  }

  clear(): void {
    this.files.clear();
  }
}

interface BundlerExports {
  memory: WebAssembly.Memory;
  alloc(len: number): number;
  dealloc(ptr: number, len: number): void;
  bundler_version(): number;
  // build() export 는 PR 6-2c
}

let bundler: BundlerExports | null = null;
let bundlerVfs: VirtualFileSystem | null = null;

function readBundlerString(ptr: number, len: number): string {
  return decoder.decode(new Uint8Array(bundler!.memory.buffer, ptr, len));
}

/// host 가 wasm 메모리에 buffer 확보 + 데이터 복사 → packed (ptr<<32 | len) 반환.
/// 0 = error sentinel (alloc 실패 또는 미존재).
function packBytes(data: Uint8Array): bigint {
  if (!bundler) return 0n;
  const ptr = bundler.alloc(data.length);
  if (ptr === 0) return 0n;
  new Uint8Array(bundler.memory.buffer, ptr, data.length).set(data);
  return (BigInt(ptr) << 32n) | BigInt(data.length);
}

function createBundlerImports(memory: () => WebAssembly.Memory) {
  const wasi = createWasiImports(memory);
  return {
    ...wasi,
    zts_fs: {
      readFile(pathPtr: number, pathLen: number, _maxBytes: number): bigint {
        const path = readBundlerString(pathPtr, pathLen);
        const data = bundlerVfs?.get(path);
        if (!data) return 0n;
        return packBytes(data);
      },

      statFile(
        pathPtr: number,
        pathLen: number,
        outSize: number,
        outKind: number,
        outMtimeLo: number,
        outMtimeHi: number,
      ): number {
        const path = readBundlerString(pathPtr, pathLen);
        const data = bundlerVfs?.get(path);
        if (!data) return 1; // NotFound
        const view = new DataView(bundler!.memory.buffer);
        view.setBigUint64(outSize, BigInt(data.length), true);
        new Uint8Array(bundler!.memory.buffer, outKind, 1)[0] = 0; // file
        view.setBigUint64(outMtimeLo, 0n, true);
        view.setBigUint64(outMtimeHi, 0n, true);
        return 0; // ok
      },

      access(pathPtr: number, pathLen: number): number {
        const path = readBundlerString(pathPtr, pathLen);
        return bundlerVfs?.has(path) ? 0 : 1;
      },

      realpath(pathPtr: number, pathLen: number): bigint {
        const path = readBundlerString(pathPtr, pathLen);
        if (!bundlerVfs?.has(path)) return 0n;
        // VFS 는 symlink 없음 — identity.
        return packBytes(encoder.encode(path));
      },

      listDir(_pathPtr: number, _pathLen: number): bigint {
        // PR 6-2c 후속 — Phase 2 minimal use case 에선 미사용.
        return 0n;
      },

      hostFreeBytes(ptr: number, len: number): void {
        bundler?.dealloc(ptr, len);
      },
    },
  };
}

/// Bundler WASM (zts-bundler.wasm) 초기화. transpile init 와 별도 instance.
/// vfs = host 가 제공하는 in-memory file system. bundler 가 fs syscall 시 위임.
export async function initBundler(
  vfs: VirtualFileSystem,
  input?: URL | string | Request | Response | BufferSource | WebAssembly.Module,
): Promise<void> {
  if (bundler) return;
  const source = await resolveWasmSource(input, "zts-bundler.wasm");

  let memory: WebAssembly.Memory;
  const imports = createBundlerImports(() => memory);
  const instance = await instantiateWasm(source, imports);

  memory = instance.exports.memory as WebAssembly.Memory;
  bundler = instance.exports as unknown as BundlerExports;
  bundlerVfs = vfs;
}

/// Bundler ABI version. host 가 호환성 체크용.
export function bundlerVersion(): number {
  if (!bundler) {
    throw new Error("zts-wasm: bundler not initialized. Call initBundler() first.");
  }
  return bundler.bundler_version();
}
