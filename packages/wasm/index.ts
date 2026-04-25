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
  // bundler 빌드 (wasi-musl) 가 dispatch 하는 모든 wasi_snapshot_preview1 fn stub 제공.
  // transpile 빌드는 일부 fn 만 호출 — 미호출 stub 은 link 영향 0.
  // 대부분 stub 은 0 (errno_success) 반환 — bundler 가 실제 OS 의존 호출 안 한다는 가정.
  const ok = () => 0;

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
      fd_read: ok,
      fd_seek: ok,
      fd_pwrite: ok,
      fd_pread: ok,
      fd_close: ok,
      fd_fdstat_get: ok,
      fd_fdstat_set_flags: ok,
      fd_filestat_get: ok,
      // EBADF (8) 반환 — wasi-musl libc 가 "valid fd 없음" 으로 처리 후 fallback. 0 반환
      // 시 musl 이 gibberish 메모리 read 시도 → panic. EBADF 가 안전.
      fd_prestat_get: () => 8,
      fd_prestat_dir_name: ok,
      fd_sync: ok,
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
      clock_res_get(_clock_id: number, ts_ptr: number): number {
        const mem = new DataView(memory().buffer);
        mem.setBigUint64(ts_ptr, 1_000_000n, true); // 1 ms resolution
        return 0;
      },
      // args/environ — bundler 는 명시적 옵션 전달, args/env 미사용.
      args_sizes_get(argc_ptr: number, argv_buf_size_ptr: number): number {
        const mem = new DataView(memory().buffer);
        mem.setUint32(argc_ptr, 0, true);
        mem.setUint32(argv_buf_size_ptr, 0, true);
        return 0;
      },
      args_get: ok,
      environ_sizes_get(envc_ptr: number, env_buf_size_ptr: number): number {
        const mem = new DataView(memory().buffer);
        mem.setUint32(envc_ptr, 0, true);
        mem.setUint32(env_buf_size_ptr, 0, true);
        return 0;
      },
      environ_get: ok,
      proc_exit(code: number): void {
        throw new Error(`zts-wasm: proc_exit(${code})`);
      },
      sched_yield: ok,
      poll_oneoff: ok,
      // path_* — bundler 는 fs.zig 의 zts_fs callback 통과, 정상 경로에선 wasi path_*
      // 미호출. 단 wasi-musl 의 일부 함수 (e.g. realpath) 가 path_filestat_get 호출
      // 시도 가능 → EBADF 로 fallback. ok 반환 (0) 하면 gibberish 메모리 read panic.
      path_open: () => 8,
      path_filestat_get: () => 8,
      path_unlink_file: ok,
      path_create_directory: ok,
      path_remove_directory: ok,
      path_rename: ok,
      path_link: ok,
      path_symlink: ok,
      path_readlink: () => 8,
    },
    // wasi-libc 의 pthread_create 가 dispatch — single-thread 환경 (Node/Bun) 에선
    // -1 (ENOSYS) 반환 → bundler 의 std.Thread.spawn 이 single-thread fallback.
    // Worker 활용은 Phase 3 (#1885).
    wasi: {
      "thread-spawn": () => -1,
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
  alloc(len: number): number;
  dealloc(ptr: number, len: number): void;
  bundler_version(): number;
  /// entry path + 옵션 JSON 으로 bundler.Bundler.init + bundle() 호출 후
  /// result.output (단일 파일 모드 번들 코드) 반환. 0 = error 또는 빈 출력.
  /// options_json_ptr=0 이면 기본 옵션 (esm/browser).
  build(
    entryPathPtr: number,
    entryPathLen: number,
    optionsJsonPtr: number,
    optionsJsonLen: number,
  ): bigint;
}

let bundler: BundlerExports | null = null;
let bundlerMemory: WebAssembly.Memory | null = null;
let bundlerVfs: VirtualFileSystem | null = null;

function readBundlerString(ptr: number, len: number): string {
  // bundlerMemory 는 SharedArrayBuffer (threads features 로 shared:true). 해당 view 를
  // 그대로 TextDecoder.decode 에 전달하면 브라우저가 거부 ("must not be shared") —
  // .slice() 로 새 ArrayBuffer 복사 후 decode.
  const view = new Uint8Array(bundlerMemory!.buffer, ptr, len);
  return decoder.decode(view.slice());
}

/// host 가 wasm 메모리에 buffer 확보 + 데이터 복사 → packed (ptr<<32 | len) 반환.
/// 0 = error sentinel (alloc 실패 또는 미존재).
function packBytes(data: Uint8Array): bigint {
  if (!bundler || !bundlerMemory) return 0n;
  const ptr = bundler.alloc(data.length);
  if (ptr === 0) return 0n;
  new Uint8Array(bundlerMemory.buffer, ptr, data.length).set(data);
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
        const view = new DataView(bundlerMemory!.buffer);
        view.setBigUint64(outSize, BigInt(data.length), true);
        new Uint8Array(bundlerMemory!.buffer, outKind, 1)[0] = 0; // file
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

  // wasm32-wasi + threads features → shared_memory 강제 → env.memory import 필요.
  // wasi-musl libc 가 stack/heap 위해 ~257 page 요구 — 1024 (64 MiB) initial 로 여유.
  // 65536 page = 4 GiB max (build.zig:max_memory 와 일치).
  const memory = new WebAssembly.Memory({
    initial: 1024,
    maximum: 65536,
    shared: true,
  });

  const bundlerImports = createBundlerImports(() => memory);
  const imports: WebAssembly.Imports = {
    ...bundlerImports,
    env: { memory },
  };
  const instance = await instantiateWasm(source, imports);

  bundler = instance.exports as unknown as BundlerExports;
  bundlerMemory = memory;
  bundlerVfs = vfs;
}

/// Bundler ABI version. host 가 호환성 체크용.
export function bundlerVersion(): number {
  if (!bundler) {
    throw new Error("zts-wasm: bundler not initialized. Call initBundler() first.");
  }
  return bundler.bundler_version();
}

export interface BundleResult {
  code: string;
}

/// build() 가 받는 옵션. ZTS bundler 의 BundleOptions 의 minimal subset —
/// 후속 PR 에서 sourcemap / target / jsx 등 추가.
export interface BundleOptionsInput {
  /// 출력 모듈 형식. 기본 "esm".
  format?: "esm" | "cjs" | "iife";
  /// 타겟 플랫폼. 기본 "browser". import.meta polyfill / Node 빌트인 처리 등 영향.
  platform?: "browser" | "node" | "neutral" | "react-native";
  /// 외부 처리할 모듈 specifier 목록 (와일드카드 `*` 지원).
  external?: string[];
  /// minify shorthand — true 면 whitespace/identifiers/syntax 모두 활성화.
  /// 개별 옵션이 명시되면 그게 우선.
  minify?: boolean;
  minifyWhitespace?: boolean;
  minifyIdentifiers?: boolean;
  minifySyntax?: boolean;
}

/// VFS entry path + 옵션으로 bundler 호출 후 단일 파일 번들 코드 반환.
/// 옵션 미전달 시 esm/browser 기본. 빈 출력 또는 실패 시 null.
export function build(entryPath: string, options?: BundleOptionsInput): BundleResult | null {
  if (!bundler || !bundlerMemory) {
    throw new Error("zts-wasm: bundler not initialized. Call initBundler() first.");
  }

  const entryBytes = encoder.encode(entryPath);
  const entryPtr = bundler.alloc(entryBytes.length);
  if (entryPtr === 0) throw new Error("zts-wasm: bundler alloc failed");
  new Uint8Array(bundlerMemory.buffer, entryPtr, entryBytes.length).set(entryBytes);

  let optsPtr = 0;
  let optsLen = 0;
  if (options) {
    // minify shorthand 펼치기 — 개별 옵션이 명시되어 있으면 그게 우선.
    const expanded = { ...options };
    if (expanded.minify) {
      expanded.minifyWhitespace = expanded.minifyWhitespace ?? true;
      expanded.minifyIdentifiers = expanded.minifyIdentifiers ?? true;
      expanded.minifySyntax = expanded.minifySyntax ?? true;
    }
    delete expanded.minify;
    const json = JSON.stringify(expanded);
    const optsBytes = encoder.encode(json);
    optsPtr = bundler.alloc(optsBytes.length);
    if (optsPtr === 0) {
      bundler.dealloc(entryPtr, entryBytes.length);
      throw new Error("zts-wasm: bundler alloc failed");
    }
    new Uint8Array(bundlerMemory.buffer, optsPtr, optsBytes.length).set(optsBytes);
    optsLen = optsBytes.length;
  }

  try {
    const packed = bundler.build(entryPtr, entryBytes.length, optsPtr, optsLen);
    if (packed === 0n) return null;

    const outPtr = Number(packed >> 32n);
    const outLen = Number(packed & 0xffffffffn);
    // SharedArrayBuffer view 는 TextDecoder.decode 가 거부 — .slice() 로 복사.
    const view = new Uint8Array(bundlerMemory.buffer, outPtr, outLen);
    const code = decoder.decode(view.slice());
    bundler.dealloc(outPtr, outLen);
    return { code };
  } finally {
    bundler.dealloc(entryPtr, entryBytes.length);
    if (optsPtr) bundler.dealloc(optsPtr, optsLen);
  }
}
