const std = @import("std");
const spin = @import("../util/spin_lock.zig");
const builtin = @import("builtin");
const http = std.http;
const mime = @import("mime.zig");
const FileWatcher = @import("file_watcher.zig").FileWatcher;
const tls = @import("tls.zig");
const lib = @import("../root.zig");
const Bundler = lib.bundler.Bundler;
const BundleOptions = lib.bundler.BundleOptions;
const BundleResult = lib.bundler.BundleResult;
const IncrementalBundler = lib.bundler.IncrementalBundler;
const plugin_mod = lib.bundler.plugin;
const server_events = @import("events.zig");

const WsClients = server_events.WsClients;
const ErrorState = server_events.ErrorState;
pub const SseSink = server_events.SseSink;
const SseClients = server_events.SseClients;
pub const EventType = server_events.EventType;
const writeJsonEscaped = server_events.writeJsonEscaped;
const buildErrorJsonFromDiagnostics = server_events.buildErrorJsonFromDiagnostics;

/// 0.16: `std.fs.File.DeprecatedWriter` 제거. critical 진단/배너는 io 가 없는
/// 경로(thread 진입 전 init 등)에서도 찍어야 하므로, io 불필요한
/// `std.debug.print`(잠금 stderr) 로 위임하는 얇은 shim. `getLog().print(fmt, args)
/// catch {}` 호출 형태를 그대로 유지하려고 `print` 가 `!void` 를 반환한다.
const DebugLog = struct {
    pub fn print(_: DebugLog, comptime fmt: []const u8, args: anytype) error{}!void {
        std.debug.print(fmt, args);
    }
};
fn getLog() DebugLog {
    return .{};
}

// Windows 의 getsockname 은 libc 가 아니라 ws2_32 가 stdcall 규약으로 export 한다.
// `std.c.getsockname` 은 `extern "c"`(cdecl) 라 x86-windows-msvc(32-bit) 에서 심볼이
// `_getsockname` 으로 mangle 되는데 ws2_32 는 `_getsockname@12`(stdcall) 만 제공 →
// undefined symbol. (x64/arm64-windows 는 데코레이션이 없어 우연히 매칭돼 통과.)
// winapi(=x86 에서 stdcall) 규약으로 ws2_32 와 직접 매칭하는 선언을 둔다. Windows 의
// namelen 인자는 `int*`(i32) — POSIX 의 socklen_t 와 폭이 같아 값은 동일.
const ws2_32_getsockname = if (builtin.os.tag == .windows)
    struct {
        extern "ws2_32" fn getsockname(s: std.posix.fd_t, name: *std.c.sockaddr, namelen: *i32) callconv(.winapi) c_int;
    }.getsockname
else {};

/// listen 소켓의 실제 bound port 조회. 0.16 `std.Io.net.Server` 는 bound
/// address 를 노출하지 않아(listen_address 필드 제거), port 0 (OS-assigned
/// ephemeral) 케이스를 위해 `getsockname` 으로 직접 조회한다. 실패 시
/// fallback(옵션 지정 port) 을 그대로 반환 — 비-ephemeral 경로는 무영향.
fn socketBoundPort(handle: std.posix.fd_t, fallback: u16) u16 {
    var addr: std.c.sockaddr.in = undefined;
    if (builtin.os.tag == .windows) {
        var addrlen: i32 = @sizeOf(std.c.sockaddr.in);
        if (ws2_32_getsockname(handle, @ptrCast(&addr), &addrlen) != 0) return fallback;
    } else {
        var addrlen: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (std.c.getsockname(handle, @ptrCast(&addr), &addrlen) != 0) return fallback;
    }
    // sockaddr.in.port 는 network byte order(big-endian).
    return std.mem.bigToNative(u16, addr.port);
}

pub const DevServer = struct {
    /// Routine log helper — `quiet=true` 면 silent. instance method 안에서 사용.
    /// CLI 환경 (default quiet=false) 은 그대로 출력, NAPI embed 는 silent.
    ///
    /// ── CANONICAL SCOPE LIST ─────────────────────────────────────────────────
    /// quiet 가드되는 routine progress 카테고리 (단일 진실 소스):
    ///   1. request access (200/500)
    ///   2. HMR
    ///   3. WS
    ///   4. watcher
    ///   5. sse
    ///   6. bundle progress
    ///   7. cache reset
    ///
    /// 카테고리 추가/제거 시 본 리스트를 갱신 + 다음 사이트도 sync 필수:
    ///   - dev_server.zig `Options.quiet` field doc (직접 enumerate)
    ///   - packages/core/src/napi/serve_entry.zig napiStartDevServer 주석
    ///   - packages/core/index.ts `StartDevServerOptions.quiet` TSDoc
    /// 세 사이트는 본 canonical 리스트를 가리키는 "see" 참조만 유지.
    ///
    /// **scope 외 (quiet 와 무관 항상 stderr)**: critical 진단 — init failure (cert
    /// 로드/디렉토리/overlay sentinel), start fatal (host parse / listen fail / watch
    /// thread spawn), deinit UAF 경고. caller 가 직접 `getLog().print(...)` 호출. 사용자가
    /// quiet=true 줘도 진단 못 보면 NAPI throwError 의 generic 메시지로는 root cause
    /// 추적 불가.
    fn routineLog(self: *const DevServer, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet) return;
        getLog().print(fmt, args) catch {};
    }

    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    root_path: []const u8,
    /// 실제 listen 중인 port. listen 전엔 init 시점 옵션값, listen 후엔 OS-assigned
    /// port (옵션이 0 이었던 경우) 포함 실제 값. NAPI `getDevServerPort` 가 이 필드 노출.
    port: u16,
    host: []const u8,
    open: bool,
    /// stderr 출력 silence. NAPI embed 등 외부 logger 가 있을 때 true.
    quiet: bool,
    tcp_server: ?std.Io.net.Server,
    entry_point: ?[]const u8,
    abs_entry: ?[]const u8,
    ws_clients: WsClients = .{},
    sse_clients: SseClients = .{},
    /// 모노토닉 이벤트 시퀀스 (SSE payload의 id 필드).
    event_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// event_seq fallback 보호용 — 32-bit 타깃은 64-bit atomic 미지원이라
    /// `loadSeq`/`nextSeq`가 atomic 대신 이 mutex로 직렬화한다 (아래 헬퍼 참조).
    seq_mutex: spin.SpinLock = .{},
    error_state: ErrorState = .{},
    /// Control API `/reset-cache`가 설정; watchLoop가 다음 iteration에서 소비.
    cache_reset_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// shutdown() 호출 시 set; acceptLoop가 다음 iteration에서 종료.
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// listen 완료 + self.port 갱신 완료 신호 (release / acquire 로 cross-thread
    /// publish). `getDevServerPort` 가 acquire 로 읽기 — port 0 (OS-assigned) 의 실
    /// 값을 다른 thread 에서 안전 조회.
    listen_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 현재 살아있는 connection (handleConnection thread) 수. deinit 가 0 까지 wait —
    /// handleConnection 의 fetchAdd/Sub 가 path 분기 전이라 모든 connection (plain
    /// HTTP / SSE / HMR WS) 통일 카운팅.
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// entry 모드의 watch 스레드(`watchLoop`) 핸들. `start()` 가 채우고 `deinit()` 이 join.
    /// **#4063**: 예전엔 detach 라 deinit 이 frees 후에도 watchLoop 가 살아 self.* 를 건드려
    /// UAF(segfault 0xF0). 이제 핸들을 보관해 shutdown 신호 후 join → 모든 자원 해제 전에 종료 보장.
    watch_thread: ?std.Thread = null,
    /// **#4066**: 활성 connection 의 socket fd 레지스트리. `shutdown()` 이 이들을 SHUT_RDWR 해
    /// keep-alive 로 blocking read 중인 `handleConnection` 을 깨운다 — 안 그러면 listen close/
    /// self-connect 가 accept 만 깨우고 수립된 connection 은 2s deinit timeout 너머 잔존 → freed
    /// 자원 접근 UAF. register/deregister 는 `handleConnection` 이 `mutex` 안에서 수행.
    conn_registry: struct {
        mutex: spin.SpinLock = .{},
        streams: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    } = .{},
    plugins: []const plugin_mod.Plugin = &.{},
    proxy: []const ProxyRule = &.{},
    base_path: []const u8 = "/",
    define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
    jsx_import_source: []const u8 = "react",
    jsx_factory: []const u8 = "React.createElement",
    jsx_fragment: []const u8 = "React.Fragment",
    sourcemap_cache: struct {
        mutex: spin.SpinLock = .{},
        data: ?[]const u8 = null,
    } = .{},
    /// dev overlay client — raw template (overlay_client_template) 의 `__ZNTC_HMR_*__`
    /// sentinel 을 protocol 상수로 치환한 결과. init 에서 1회 생성, deinit 에서 free.
    /// JS 측 packages/web/runtime/dev-overlay-client.mjs 와 같은 source/치환표 사용 (#2538 4-3).
    /// default 미제공 — partial-init 인스턴스가 serveAppDevClient 로 빈 body 응답하는
    /// silent regression 차단.
    overlay_client: []u8,
    /// TLS context — `--certfile`/`--keyfile` 양쪽 다 설정된 경우만. null 이면 plain
    /// HTTP. dev server scope 라 1개 cert 만 — SNI multi-cert 는 별도 epic (#2538 4-2).
    tls_ctx: ?tls.TlsContext = null,
    /// PR-3b-iii: lazy compilation 활성 여부 (`Options.lazy_compilation` 사본). true 면
    /// serveBundle 이 dev_split(code_splitting+lazy)로 빌드해 *entry 청크만* 서빙하고,
    /// 동적 import 타겟은 `/<stem>-<pathhash>.js` 라우트에서 on-demand 컴파일한다(RFC A안 (B)).
    lazy_compilation: bool = false,
    /// lazy on-demand 상태 — entry 빌드가 수집한 seed 경로 + 컴파일된 청크 캐시.
    lazy_state: LazyState = .{},

    pub const ProxyRule = struct {
        /// 매칭할 경로 prefix (예: "/api")
        path: []const u8,
        /// 프록시 대상 (예: "http://localhost:8080")
        target: []const u8,
        /// target에서 추출한 host (예: "localhost")
        target_host: []const u8,
        /// target에서 추출한 port
        target_port: u16,
    };

    /// PR-3b-iii: lazy on-demand 컴파일 상태. entry 빌드가 채운 seed 경로 목록(역참조용)과
    /// 이미 컴파일한 청크 바이트 캐시를 보유한다. 모든 필드는 `mutex` 로 보호 — 여러
    /// connection thread 가 동시에 lazy 청크를 요청할 수 있다.
    pub const LazyState = struct {
        mutex: spin.SpinLock = .{},
        /// 마지막 entry 빌드의 미파싱 seed 절대경로(`BundleResult.lazy_seed_paths` 사본).
        /// 요청 청크 이름→seed 경로 역참조에 쓴다. allocator 소유.
        seed_paths: []const []const u8 = &.{},
        /// 컴파일된 lazy 청크 캐시: 요청 청크 이름 → 청크 바이트. key/value 모두 allocator 소유.
        chunk_cache: std.StringHashMapUnmanaged([]const u8) = .empty,
        /// PR-4-iii: 무효화 세대 카운터. `invalidateChunks` 마다 +1. on-demand 빌드는 빌드 *전*
        /// 이 값을 캡처하고, 캐시 insert 시 변하지 않았을 때만 저장한다 — 빌드 도중(락 밖) 다른
        /// thread 의 watch 무효화/entry rebuild 가 끼면 그 빌드 바이트는 stale 일 수 있으므로
        /// 빈 캐시를 *재오염* 하지 않게 막는다(TOCTOU staleness 가드).
        epoch: u64 = 0,

        /// seed 목록을 교체한다(이전 빌드 사본 해제 후 새 사본 보유). entry 가 rebuild 될
        /// 때마다 호출 — seed 집합이 바뀌었을 수 있다. `lazy_seed_paths` 는 중복을 포함할 수
        /// 있어(graph.lazy_seeds 가 미dedup) 여기서 dedup 한다(addSeedPaths 와 동일 불변).
        /// caller 가 `mutex` 보유 가정.
        fn setSeedPaths(self: *LazyState, allocator: std.mem.Allocator, paths: []const []const u8) !void {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer {
                for (list.items) |p| allocator.free(p);
                list.deinit(allocator);
            }
            for (paths) |p| {
                if (p.len == 0) continue;
                var seen = false;
                for (list.items) |q| if (std.mem.eql(u8, q, p)) {
                    seen = true;
                    break;
                };
                if (seen) continue;
                const d = try allocator.dupe(u8, p);
                list.append(allocator, d) catch |e| {
                    allocator.free(d); // append 실패 시 미등록 dupe 누수 방지
                    return e;
                };
            }
            const owned = try list.toOwnedSlice(allocator); // 이후 errdefer 는 빈 list 만 — owned 무관
            for (self.seed_paths) |p| allocator.free(p);
            if (self.seed_paths.len > 0) allocator.free(self.seed_paths);
            self.seed_paths = owned;
        }

        /// PR-4-ii (재귀 lazy): 기존 seed 목록에 `new_paths` 중 *아직 없는 것만* 추가(union+dedup).
        /// on-demand 빌드가 발견한 중첩 동적 import 타겟을 누적해 후속 요청이 역참조되게 한다.
        /// 기존 문자열 dupe 는 포인터째 이관(재dupe 안 함), 새 것만 dupe. caller 가 `mutex` 보유 가정.
        fn addSeedPaths(self: *LazyState, allocator: std.mem.Allocator, new_paths: []const []const u8) !void {
            var add_list: std.ArrayListUnmanaged([]const u8) = .empty;
            defer add_list.deinit(allocator);
            for (new_paths) |np| {
                if (np.len == 0) continue;
                var dup = false;
                for (self.seed_paths) |sp| if (std.mem.eql(u8, sp, np)) {
                    dup = true;
                    break;
                };
                if (!dup) for (add_list.items) |al| if (std.mem.eql(u8, al, np)) {
                    dup = true;
                    break;
                };
                if (dup) continue;
                try add_list.append(allocator, np);
            }
            if (add_list.items.len == 0) return;

            const merged = try allocator.alloc([]const u8, self.seed_paths.len + add_list.items.len);
            errdefer allocator.free(merged);
            @memcpy(merged[0..self.seed_paths.len], self.seed_paths); // 기존 포인터 이관
            var n = self.seed_paths.len;
            errdefer for (merged[self.seed_paths.len..n]) |p| allocator.free(p); // 새 dupe 만 롤백
            for (add_list.items) |np| {
                merged[n] = try allocator.dupe(u8, np);
                n += 1;
            }
            if (self.seed_paths.len > 0) allocator.free(self.seed_paths); // 외부 배열만 free(문자열은 이관됨)
            self.seed_paths = merged;
        }

        /// 컴파일된 청크 캐시를 비운다(파일 변경 등으로 stale 시). caller 가 `mutex` 보유 가정.
        /// `epoch` 를 올려 *진행 중* 인 on-demand 빌드가 stale 바이트로 캐시를 재오염하지 못하게 한다.
        fn invalidateChunks(self: *LazyState, allocator: std.mem.Allocator) void {
            var it = self.chunk_cache.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            self.chunk_cache.clearRetainingCapacity();
            self.epoch +%= 1;
        }

        fn deinit(self: *LazyState, allocator: std.mem.Allocator) void {
            for (self.seed_paths) |p| allocator.free(p);
            if (self.seed_paths.len > 0) allocator.free(self.seed_paths);
            self.seed_paths = &.{};
            self.invalidateChunks(allocator);
            self.chunk_cache.deinit(allocator);
            self.chunk_cache = .empty;
        }
    };

    pub const Options = struct {
        root_dir: []const u8 = ".",
        port: u16 = 12300,
        host: []const u8 = "localhost",
        open: bool = false,
        entry_point: ?[]const u8 = null,
        plugins: []const plugin_mod.Plugin = &.{},
        proxy: []const ProxyRule = &.{},
        base_path: []const u8 = "/",
        define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
        jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
        jsx_import_source: []const u8 = "react",
        jsx_factory: []const u8 = "React.createElement",
        jsx_fragment: []const u8 = "React.Fragment",
        /// TLS cert (PEM) 의 file path. `key_path` 와 함께 둘 다 set 되면 HTTPS 활성,
        /// 둘 다 null 이면 plain HTTP. 한쪽만 set 하면 init error (`error.TlsKeyMissing`).
        cert_path: ?[]const u8 = null,
        key_path: ?[]const u8 = null,
        /// banner + routine log silence. **critical** 진단 (init failure,
        /// host/listen fatal, deinit UAF 경고) 은 quiet 와 무관하게 항상 출력.
        /// CLI 기본 false, NAPI embed default true.
        ///
        /// quiet 가드되는 카테고리 전체 리스트는 `DevServer.routineLog` doc 의
        /// CANONICAL SCOPE LIST 참조 (단일 진실 소스).
        quiet: bool = false,
        /// Lazy compilation — 브라우저가 요청하는 청크만 온디맨드로 컴파일해 dev cold-start 단축.
        /// 현재는 스캐폴딩(미소비). 동작은 RFC `docs/RFC_LAZY_COMPILATION.md` 의 PR-2~ 에서 추가.
        lazy_compilation: bool = false,
    };

    const max_file_size: u64 = 50 * 1024 * 1024;
    const bundle_path = "/bundle.js";
    const hmr_path = "/__hmr";
    const app_dev_client_path = "/__zntc_app_dev_client__";
    const watch_interval_ms = 500;
    /// dev overlay client 의 raw template — `__ZNTC_HMR_*__` sentinel 들이 박힌 상태.
    /// 그대로는 동작하지 않음. init 의 substituteOverlayPlaceholders 가 치환한 결과를
    /// self.overlay_client 에 보유한다. 정본은 한 파일 — JS 측 (@zntc/web) 도 이
    /// 동일 raw 의 사본 (packages/web/runtime/dev-overlay-client.raw.js) 을 읽어
    /// 같은 치환을 적용한다 (#2538 4-3).
    const overlay_client_template = @embedFile("dev_overlay_client.js");

    const js_headers = cors_headers ++ [_]http.Header{
        .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
    };

    const html_headers = cors_headers ++ [_]http.Header{
        .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !DevServer {
        // init 의 진단 로그 — `quiet` 와 **무관** 하게 항상 stderr 출력. 사용자가
        // init failure 를 못 보면 NAPI throwError 의 generic 메시지만 받고 어느
        // 경로/cert/key 가 문제인지 진단 못 함. dev-time critical path 라 quiet 영향
        // 외 (start fatal / deinit UAF 경고도 같은 contract).
        const root_dir = std.Io.Dir.cwd().openDir(io, options.root_dir, .{ .iterate = true }) catch |err| {
            getLog().print("zntc: cannot open directory '{s}': {}\n", .{ options.root_dir, err }) catch {};
            return err;
        };
        // 이후 ! 반환은 모두 root_dir 을 닫아야 함 (open 직후 ownership 이 init 에
        // 있어 호출자가 deinit 못 호출). errdefer 한 줄로 통일해 향후 init 후반에
        // 추가될 fallible 자원이 leak 을 발생시키지 않도록 가드 (#2538 4-3 review).
        errdefer {
            var dir_copy = root_dir;
            dir_copy.close(io);
        }

        var abs_entry: ?[]const u8 = null;
        if (options.entry_point) |ep| {
            // 0.16: realPathFileAlloc 는 [:0]u8. ?[]const u8 필드로 free 시 sentinel 누락
            // size-mismatch → 정확 길이 dupe 후 원본 free (fs.realpath 패턴).
            const ep_z = std.Io.Dir.cwd().realPathFileAlloc(io, ep, allocator) catch |err| {
                getLog().print("zntc: cannot resolve entry '{s}': {}\n", .{ ep, err }) catch {};
                return err;
            };
            defer allocator.free(ep_z);
            abs_entry = allocator.dupe(u8, ep_z) catch return error.OutOfMemory;
        }
        errdefer if (abs_entry) |ae| allocator.free(ae);

        const overlay_client = substituteOverlayPlaceholders(allocator) catch |err| {
            getLog().print("zntc: failed to prepare dev overlay client: {}\n", .{err}) catch {};
            return err;
        };
        errdefer allocator.free(overlay_client);

        // TLS — cert + key 양쪽 다 set 일 때만 활성. 한쪽만 set 은 명백 misconfig 라
        // 명시적 error 로 빠르게 fail.
        var tls_ctx: ?tls.TlsContext = null;
        if (options.cert_path != null and options.key_path != null) {
            tls_ctx = tls.TlsContext.init(options.cert_path.?, options.key_path.?) catch |err| {
                getLog().print("zntc: TLS context init failed: {}\n", .{err}) catch {};
                return err;
            };
        } else if (options.cert_path != null or options.key_path != null) {
            getLog().print("zntc: --certfile 와 --keyfile 은 둘 다 필요 (한쪽만 지정됨)\n", .{}) catch {};
            return error.TlsKeyMissing;
        }
        errdefer if (tls_ctx) |*c| c.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .root_dir = root_dir,
            .root_path = options.root_dir,
            .port = options.port,
            .host = options.host,
            .open = options.open,
            .quiet = options.quiet,
            .tcp_server = null,
            .entry_point = options.entry_point,
            .abs_entry = abs_entry,
            .plugins = options.plugins,
            .proxy = options.proxy,
            .base_path = options.base_path,
            .define = options.define,
            .jsx_runtime = options.jsx_runtime,
            .jsx_import_source = options.jsx_import_source,
            .jsx_factory = options.jsx_factory,
            .jsx_fragment = options.jsx_fragment,
            .overlay_client = overlay_client,
            .tls_ctx = tls_ctx,
            .lazy_compilation = options.lazy_compilation,
        };
    }

    pub fn deinit(self: *DevServer) void {
        // shutdown() 호출 — shutdown_requested set + self-connect trigger 로 blocking
        // accept() 를 깨움 (macOS/Linux 에서 listen socket close 만으론 accept 안 깨움).
        // 그 뒤 listen socket 정리.
        self.shutdown();
        // #4063: watch 스레드를 *자원 해제 전* 에 join. shutdown_requested 를 본 watchLoop 가
        // 늦어도 한 폴링 주기(500ms) 안에 종료한다. join 후 watchLoop 의 inc_bundler/watcher
        // (self.allocator·self.io 사용) defer 정리도 끝나 있어, 아래 frees 와 충돌(UAF) 없음.
        // join 시점엔 abs_entry/lazy_state/root_dir 모두 아직 유효(아래에서 해제). watchLoop 가
        // 종료 직전 ws_clients.broadcast/lazy_state.mutex 를 잡아도 짧은 임계영역이라 join 지연은
        // 유한하고, deinit 스레드는 어떤 락도 안 쥐고 join 하므로 deadlock 불가.
        if (self.watch_thread) |t| {
            t.join();
            self.watch_thread = null; // 중복 deinit 시 재join(UB) 방지
        }
        if (self.tcp_server) |*s| s.deinit(self.io);
        // 살아있는 connection (handleConnection thread) 가 종료할 때까지 wait. 최대
        // 2초 (best-effort) — production 은 process exit 직전 deinit 라 그 시점엔
        // thread 종료된 상태가 일반적. 2초 넘어가면 log + 그대로 진행.
        // 0.16: std.time.nanoTimestamp 제거 → Io.Timestamp(awake 단조시계) + toNanoseconds.
        const DEINIT_TIMEOUT_MS: i128 = 2000;
        const start_ns: i128 = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
        const deadline_ns: i128 = start_ns + DEINIT_TIMEOUT_MS * std.time.ns_per_ms;
        var clean = false; // #4066: 좀비 connection 없이 깔끔히 종료됐는지
        while (true) {
            const count = self.active_connections.load(.acquire);
            if (count == 0) {
                clean = true;
                break;
            }
            const now_ns: i128 = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
            if (now_ns >= deadline_ns) {
                // 같은 load 결과 (count) 를 log — re-load 시 사이에 0 으로 떨어졌으면
                // "0 개 아직 살아있음 (UAF 위험)" 같은 모순적 메시지 (F4 retro).
                //
                // **critical**: UAF 가능성 경고 — quiet 와 무관하게 항상 stderr. 사용자가
                // 다음 단계 crash 진단 시 단서 필요 (PR-G4 review F3).
                getLog().print(
                    "  [deinit] connection thread {d} 개 아직 살아있음 — 2초 timeout, deinit 진행 (UAF 위험)\n",
                    .{count},
                ) catch {};
                break;
            }
            // 0.16: std.Thread.sleep 제거 → io.sleep(duration, clock).
            self.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
        }

        if (self.abs_entry) |ae| self.allocator.free(ae);
        self.lazy_state.deinit(self.allocator);
        // overlay_client 는 init 에서 반드시 알록된 owned slice (default 미제공).
        self.allocator.free(self.overlay_client);
        if (self.tls_ctx) |*c| c.deinit();
        self.root_dir.close(self.io);
        self.error_state.deinit(self.io, self.allocator);
        // #4066: clean(count==0, 모든 connection deregister 완료) 일 때만 레지스트리 free.
        // timeout 잔존 thread 가 deregister 로 freed 리스트 접근하는 것 차단 — leak 은 비정상
        // 경로(2s 안에 connection 미종료) 한정 + 미미(fd 몇 개분 capacity).
        if (clean) self.conn_registry.streams.deinit(self.allocator);
    }

    /// dev overlay client raw template 의 `__ZNTC_HMR_*__` sentinel 들을
    /// `@zntc/server/protocol` 의 실제 값으로 치환한다. JS 측
    /// `packages/web/runtime/dev-overlay-client.mjs` 의 PLACEHOLDERS 배열과
    /// 같은 표 — 양쪽이 같은 raw 를 같은 치환으로 변환해 같은 client 송신 (#2538 4-3).
    fn substituteOverlayPlaceholders(allocator: std.mem.Allocator) ![]u8 {
        const Sub = struct { token: []const u8, value: []const u8 };
        const subs = [_]Sub{
            .{ .token = "__ZNTC_HMR_WS_PATH__", .value = "/__hmr" },
            .{ .token = "__ZNTC_HMR_MSG_ERROR__", .value = "error" },
            .{ .token = "__ZNTC_HMR_MSG_CLEAR_ERROR__", .value = "clear-error" },
            .{ .token = "__ZNTC_HMR_MSG_UPDATE_START__", .value = "update-start" },
            .{ .token = "__ZNTC_HMR_MSG_UPDATE_DONE__", .value = "update-done" },
            .{ .token = "__ZNTC_HMR_MSG_UPDATE__", .value = "update" },
            .{ .token = "__ZNTC_HMR_MSG_FULL_RELOAD__", .value = "full-reload" },
            .{ .token = "__ZNTC_HMR_MSG_CSS_UPDATE__", .value = "css-update" },
        };

        var current = try allocator.dupe(u8, overlay_client_template);
        errdefer allocator.free(current);
        for (subs) |s| {
            const next_size = std.mem.replacementSize(u8, current, s.token, s.value);
            const next = try allocator.alloc(u8, next_size);
            const count = std.mem.replace(u8, current, s.token, s.value, next);
            // sentinel 이 정본에 없다 = subs 의 token 이 정본과 어긋남 (정본은
            // src/server/dev_overlay_client.js). 단위 test 가 결과를 검증하지만
            // 빌드/init 시점에 즉시 잡히면 디버깅이 명확.
            if (count == 0) {
                allocator.free(next);
                // substituteOverlayPlaceholders 는 init 보조 함수 — self 없음. 사용자
                // 환경 dev-side debug 라 항상 stderr (init failure).
                getLog().print(
                    "zntc: dev overlay client sentinel '{s}' 가 정본에 없음 — subs 표와 src/server/dev_overlay_client.js 동기 확인 필요\n",
                    .{s.token},
                ) catch {};
                return error.OverlaySentinelMissing;
            }
            allocator.free(current);
            current = next;
        }
        return current;
    }

    pub fn start(self: *DevServer, io: std.Io) !void {
        // 0.16: io 는 init 에서 이미 self.io 로 저장됨. caller API 일치를 위해 받되
        // 동일 io 로 재확인 (thread 진입 함수들이 self.io 를 참조).
        self.io = io;
        // host 바인딩: "localhost" → 127.0.0.1, "0.0.0.0" → 모든 인터페이스
        const bind_ip = if (std.mem.eql(u8, self.host, "localhost")) "127.0.0.1" else self.host;
        // **critical**: host parse / listen fail 은 dev server 가 출발 자체 못 함 —
        // quiet 와 무관하게 항상 stderr. NAPI 가 host=어디 port=얼마로 실패했는지
        // 진단 못 보면 caller 가 환경 문제 (port 사용 중 등) 추적 불가.
        // 0.16: std.net 제거 → std.Io.net.IpAddress + io 기반 listen.
        const address = std.Io.net.IpAddress.parseIp4(bind_ip, self.port) catch {
            getLog().print("zntc: invalid host address: {s}\n", .{self.host}) catch {};
            return error.InvalidAddress;
        };
        self.tcp_server = address.listen(io, .{
            .reuse_address = true,
        }) catch |err| {
            getLog().print("zntc: failed to listen on {s}:{d}: {}\n", .{ self.host, self.port, err }) catch {};
            return err;
        };

        // port 0 (OS-assigned ephemeral) 였으면 실제 bound port 로 self.port 갱신
        // — caller (NAPI getDevServerPort 등) 가 실 값 조회 가능. 0.16 std.Io.net.Server
        // 는 bound address accessor 가 없어 getsockname(libc) 으로 직접 조회.
        if (self.tcp_server) |s| {
            self.port = socketBoundPort(s.socket.handle, self.port);
        }
        // F1: atomic release — self.port 쓰기가 reader 의 acquire load 와 happens-
        // before relation 형성. ARM64 (Apple Silicon) 같은 weakly-ordered 환경에서
        // self.port 값이 reorder 되어 옵션 default (0) 로 읽히는 문제 차단.
        self.listen_ready.store(true, .release);

        if (!self.quiet) {
            const w = getLog();
            const scheme: []const u8 = if (self.tls_ctx != null) "https" else "http";
            w.print("\n  zntc dev server\n\n", .{}) catch {};
            w.print("  Local: {s}://{s}:{d}/\n", .{ scheme, self.host, self.port }) catch {};
            if (std.mem.eql(u8, self.host, "0.0.0.0")) {
                w.print("  Network: {s}://0.0.0.0:{d}/\n", .{ scheme, self.port }) catch {};
            }
            w.print("  Root:  {s}\n", .{self.root_path}) catch {};
            if (self.entry_point) |ep| {
                w.print("  Entry: {s}\n", .{ep}) catch {};
            }
            w.print("\n", .{}) catch {};
        }

        // --open: 브라우저 자동 열기
        if (self.open) {
            self.openBrowser();
        }

        // server_ready 이벤트 (SSE 구독자에게 시작 알림)
        {
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{{\"type\":\"server_ready\",\"host\":\"{s}\",\"port\":{d}}}", .{ self.host, self.port })) |json| {
                self.publishEvent(EventType.server_ready, json);
            } else |_| {}
        }

        // entry가 있으면 watch 스레드 시작. #4063: detach 대신 핸들을 self 에 보관 →
        // deinit 이 shutdown 신호 후 join 해 자원 해제 전에 종료 보장(UAF 차단).
        if (self.abs_entry != null) {
            self.watch_thread = std.Thread.spawn(.{}, watchLoop, .{self}) catch |err| {
                // **critical**: watch thread spawn fail — HMR / file watch 자체 안 됨.
                // 사용자가 진단 봐야 함. quiet 와 무관 stderr.
                getLog().print("zntc: failed to start watch thread: {}\n", .{err}) catch {};
                return err;
            };
        }

        self.acceptLoop();
    }

    /// HTTP 프록시: 클라이언트 요청을 백엔드 서버로 전달 (헤더+바디 포함)
    fn handleProxy(self: *DevServer, request: *http.Server.Request, rule: ProxyRule) !void {
        const allocator = self.allocator;

        // 0.16: std.net 제거 → std.Io.net. connect 는 mode 필수(.stream).
        const address = std.Io.net.IpAddress.parseIp4(rule.target_host, rule.target_port) catch
            return error.InvalidAddress;
        const backend = address.connect(self.io, .{ .mode = .stream }) catch
            return error.ConnectionRefused;
        defer backend.close(self.io);

        // 요청 구성 (힙 할당 — 스택 오버플로 방지)
        var req: std.ArrayList(u8) = .empty;
        defer req.deinit(allocator);

        const method_str = @tagName(request.head.method);
        // 요청 라인
        try req.appendSlice(allocator, method_str);
        try req.append(allocator, ' ');
        try req.appendSlice(allocator, request.head.target);
        try req.appendSlice(allocator, " HTTP/1.1\r\n");

        // Host 헤더
        try req.appendSlice(allocator, "Host: ");
        try req.appendSlice(allocator, rule.target_host);
        try req.append(allocator, ':');
        var port_buf: [5]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{rule.target_port}) catch unreachable;
        try req.appendSlice(allocator, port_str);
        try req.appendSlice(allocator, "\r\nConnection: close\r\n");

        // 원본 요청 헤더 전달 (Host, Connection 제외)
        var header_iter = request.iterateHeaders();
        while (header_iter.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
            try req.appendSlice(allocator, h.name);
            try req.appendSlice(allocator, ": ");
            try req.appendSlice(allocator, h.value);
            try req.appendSlice(allocator, "\r\n");
        }
        try req.appendSlice(allocator, "\r\n");

        // NOTE: POST/PUT 바디 전달은 Zig 0.15.2 HTTP Server API 제약으로 미지원.
        // GET/DELETE 프록시는 정상 동작.

        // 0.16: net.Stream 직접 writeAll/read 제거 → writer/reader 인터페이스.
        var backend_send_buf: [4096]u8 = undefined;
        var backend_writer = backend.writer(self.io, &backend_send_buf);
        try backend_writer.interface.writeAll(req.items);
        try backend_writer.interface.flush();

        // 백엔드 응답 읽기 — Connection: close 라 EOF 까지 allocRemaining (동적 크기).
        var backend_recv_buf: [4096]u8 = undefined;
        var backend_reader = backend.reader(self.io, &backend_recv_buf);
        const response_bytes = backend_reader.interface.allocRemaining(allocator, .unlimited) catch
            return error.EmptyResponse;
        defer allocator.free(response_bytes);

        if (response_bytes.len == 0) return error.EmptyResponse;

        // HTTP 응답 파싱: 헤더에서 Content-Type 추출 + 바디 분리
        const header_end = std.mem.indexOf(u8, response_bytes, "\r\n\r\n");
        if (header_end) |pos| {
            const body = response_bytes[pos + 4 ..];
            const headers_section = response_bytes[0..pos];
            var content_type: []const u8 = "application/json";
            var line_iter = std.mem.splitSequence(u8, headers_section, "\r\n");
            while (line_iter.next()) |line| {
                if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
                    content_type = std.mem.trimStart(u8, line["content-type:".len..], " ");
                    break;
                }
            }

            const proxy_headers = cors_headers ++ [_]http.Header{
                .{ .name = "Content-Type", .value = content_type },
            };
            try request.respond(body, .{ .extra_headers = &proxy_headers });
        } else {
            try request.respond(response_bytes, .{ .extra_headers = &cors_headers });
        }
    }

    fn openBrowser(self: *DevServer) void {
        const scheme: []const u8 = if (self.tls_ctx != null) "https" else "http";
        const url_buf = std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}/", .{ scheme, self.host, self.port }) catch return;
        defer self.allocator.free(url_buf);
        // macOS: open, Linux: xdg-open. 0.16: Child.init/spawn 제거 →
        // process.spawn(io, options). 반환 Child 는 무시(fire-and-forget) —
        // dev-time 브라우저 오픈은 best-effort, 프로세스 수명 짧음.
        _ = std.process.spawn(self.io, .{ .argv = &.{ "open", url_buf } }) catch {
            // Linux fallback
            _ = std.process.spawn(self.io, .{ .argv = &.{ "xdg-open", url_buf } }) catch {};
        };
    }

    fn acceptLoop(self: *DevServer) void {
        while (true) {
            if (self.shutdown_requested.load(.acquire)) return;
            // 0.16: accept 가 Connection 이 아닌 Stream 직접 반환 (io 인자 필요).
            const stream = self.tcp_server.?.accept(self.io) catch |err| {
                if (self.shutdown_requested.load(.acquire)) return;
                self.routineLog("zntc: accept failed: {}\n", .{err});
                continue;
            };
            // active_connections 를 spawn 전에 증가 — handleConnection 의 fetchAdd 가
            // OS scheduler 지연으로 늦게 실행되면 deinit 의 wait loop 가 counter=0 으로
            // 보고 일찍 통과 → UAF race window. 여기서 카운트 ownership 잡고 spawn
            // 실패 시만 즉시 감소. 성공 시 handleConnection 의 defer fetchSub 가 처리.
            _ = self.active_connections.fetchAdd(1, .acq_rel);
            const thread = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, handleConnection, .{ self, stream }) catch {
                _ = self.active_connections.fetchSub(1, .acq_rel);
                stream.close(self.io);
                continue;
            };
            thread.detach();
        }
    }

    /// 외부 (테스트 등)에서 acceptLoop을 종료시킨다.
    /// macOS/Linux에서 close()는 블로킹 중인 accept()를 깨우지 않으므로
    /// self-connect로 accept를 한 번 트리거 → acceptLoop가 다음 iteration에서
    /// shutdown_requested 플래그를 보고 종료. 실제 socket close는 deinit에서.
    pub fn shutdown(self: *DevServer) void {
        self.shutdown_requested.store(true, .release);
        // listen_ready 를 acquire-load 해 start() 워커스레드의 tcp_server/port 쓰기와
        // happens-before 형성 (0.16 은 Server.listen_address 제거로 self.port 를 self-connect
        // 에 쓰는데, 미동기화 시 weakly-ordered 에서 port 가 stale(0) 로 읽혀 엉뚱한 포트로
        // connect → blocking accept 미해제 위험). publish 전이면 self-connect 스킵(아직 listen
        // 안 했으니 깨울 accept 도 없음).
        if (self.tcp_server != null and self.listen_ready.load(.acquire)) {
            // 0.16: Server.listen_address 제거 → self.host/self.port 로 self-connect
            // 재구성해 blocking accept() 를 깨운다 (close 만으론 accept 안 깨움).
            const bind_ip = if (std.mem.eql(u8, self.host, "localhost")) "127.0.0.1" else self.host;
            const addr = std.Io.net.IpAddress.parseIp4(bind_ip, self.port) catch return;
            const stream = addr.connect(self.io, .{ .mode = .stream }) catch return;
            stream.close(self.io);
        }

        // #4066: 기존 keep-alive connection 의 blocking read 를 깨운다. listen close/self-connect
        // 는 accept 만 깨우고 이미 수립된 connection 은 못 깨운다. socket 을 SHUT_RDWR 하면 그 fd
        // 의 blocked read(receiveHead/ws/SSE)가 즉시 EOF/err 반환 → handleConnection 종료 →
        // deinit 의 active_connections wait 가 빠르게 통과(좀비 thread UAF 차단). close 가 아닌
        // shutdown 이라 fd reuse race 없음. mutex 안에서 수행해 owner 의 deregister+close 와
        // 직렬화(shutdown 이 mutex 보유 중엔 owner 가 그 fd 를 deregister·close 못 함).
        // 락을 syscall 들에 걸쳐 보유하지만 dev 서버 connection 수는 소규모(탭 몇 개)라 수용 —
        // 스냅샷 후 락 밖 shutdown 은 fd reuse race 를 되살리므로 일부러 안 함.
        self.conn_registry.mutex.lock();
        defer self.conn_registry.mutex.unlock();
        for (self.conn_registry.streams.items) |s| {
            s.shutdown(self.io, .both) catch {};
        }
    }

    /// #4066: 활성 connection 등록(handleConnection 진입). best-effort — append 실패해도
    /// 2s deinit timeout 이 폴백. caller 가 mutex 미보유.
    fn registerConn(self: *DevServer, stream: std.Io.net.Stream) void {
        self.conn_registry.mutex.lock();
        defer self.conn_registry.mutex.unlock();
        self.conn_registry.streams.append(self.allocator, stream) catch |err|
            self.routineLog("zntc: connection 등록 실패({}) — shutdown 시 못 깨워 2s timeout 폴백\n", .{err});
    }

    /// #4066: connection 등록 해제(handleConnection 종료, stream.close 보다 먼저 실행). socket
    /// handle 로 매칭 — 같은 fd 의 등록분 제거.
    fn deregisterConn(self: *DevServer, stream: std.Io.net.Stream) void {
        self.conn_registry.mutex.lock();
        defer self.conn_registry.mutex.unlock();
        for (self.conn_registry.streams.items, 0..) |s, i| {
            if (s.socket.handle == stream.socket.handle) {
                _ = self.conn_registry.streams.swapRemove(i);
                break;
            }
        }
    }

    fn handleConnection(self: *DevServer, stream: std.Io.net.Stream) void {
        // active_connections 의 fetchAdd 는 acceptLoop 가 이미 수행 (spawn 전 race
        // window 회피). 여기선 defer 로 fetchSub 만 — handleConnection 종료 시 한 번.
        defer _ = self.active_connections.fetchSub(1, .acq_rel);
        defer stream.close(self.io);

        // #4066: shutdown() 이 깨울 수 있도록 fd 등록. deregister 는 defer 역순(뒤에 선언 →
        // 먼저 실행)으로 stream.close *보다 먼저* 실행되어, shutdown 이 SHUT_RDWR 하는 fd 가
        // 아직 열려있음을 보장(닫힌/재사용 fd 오접근 방지).
        self.registerConn(stream);
        defer self.deregisterConn(stream);

        var send_buf: [8192]u8 = undefined;
        // recv_buf: 32KB stack alloc — typical HTTP request header + body 가 다 fit.
        // 이전 256KB heap 은 SSE/HMR WS 같은 long-lived connection 의 entire lifetime
        // 점유 → 100 tab × 2 connection × 256KB = 25MB unused 메모리 burden. 32KB
        // stack alloc 으로 memory 8× 절감 (32KB × 100 = 3.2MB) + heap alloc OOM 위험
        // 제거. 32KB 초과 single-frame 은 readSmallMessage 가 MessageTooBig.
        var recv_buf: [32 * 1024]u8 = undefined;

        if (self.tls_ctx) |*ctx| {
            // HTTPS path — SSL_accept handshake 후 TlsReader/TlsWriter 어댑터로 http.Server.
            // 0.16: net.Stream.handle → stream.socket.handle.
            var tls_conn = tls.TlsConnection.init(ctx, stream.socket.handle) catch |err| {
                self.routineLog("zntc: TLS handshake failed: {}\n", .{err});
                return;
            };
            defer tls_conn.deinit();

            var tls_reader = tls_conn.reader(&recv_buf);
            var tls_writer = tls_conn.writer(&send_buf);
            var server: http.Server = .init(&tls_reader.interface, &tls_writer.interface);
            self.serveOnConnection(&server, &tls_writer.interface);
        } else {
            // plain HTTP path. 0.16: net.Stream.reader/writer 는 io 인자 필요,
            // .interface 는 메서드가 아닌 필드.
            var conn_reader = stream.reader(self.io, &recv_buf);
            var conn_writer = stream.writer(self.io, &send_buf);
            var server: http.Server = .init(&conn_reader.interface, &conn_writer.interface);
            self.serveOnConnection(&server, &conn_writer.interface);
        }
    }

    /// HTTP loop — TLS / plain 양쪽 진입점. http.Server 와 ws upgrade 시 사용할
    /// `*Io.Writer` 만 추상화로 받음. 나머지는 기존 handleConnection 동일.
    fn serveOnConnection(self: *DevServer, server: *http.Server, writer: *std.Io.Writer) void {
        while (true) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => {
                    self.routineLog("zntc: receiveHead failed: {}\n", .{err});
                    return;
                },
            };

            switch (request.upgradeRequested()) {
                .websocket => |opt_key| {
                    const key = opt_key orelse {
                        self.routineLog("zntc: WebSocket upgrade missing key\n", .{});
                        return;
                    };

                    // 허용 path: /__hmr (HMR broadcast)
                    const target = request.head.target;
                    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
                    const ws_path = target[0..path_end];
                    if (!std.mem.eql(u8, ws_path, hmr_path)) {
                        request.respond("400 Bad Request", .{
                            .status = .bad_request,
                            .extra_headers = &cors_headers,
                        }) catch {};
                        return;
                    }

                    var ws = request.respondWebSocket(.{ .key = key }) catch {
                        self.routineLog("zntc: WebSocket handshake failed\n", .{});
                        return;
                    };
                    self.handleWebSocket(&ws, writer);
                    return;
                },
                .other => {
                    request.respond("400 Bad Request", .{
                        .status = .bad_request,
                        .extra_headers = &cors_headers,
                    }) catch {};
                    return;
                },
                .none => {},
            }

            self.handleRequest(&request) catch |err| {
                self.routineLog("zntc: request '{s}' failed: {}\n", .{ request.head.target, err });
                return;
            };
        }
    }

    fn handleWebSocket(self: *DevServer, ws: *http.Server.WebSocket, writer: *std.Io.Writer) void {
        self.routineLog("  [ws] client connected\n", .{});

        // broadcast 리스트에 등록
        self.ws_clients.add(self.io, writer);
        defer self.ws_clients.remove(self.io, writer);

        ws.writeMessage("{\"type\":\"connected\"}", .text) catch {
            self.routineLog("  [ws] failed to send connected message\n", .{});
            return;
        };
        self.error_state.sendIfPresent(self.io, writer);

        // 클라이언트 메시지 수신 루프 (ping/pong은 std.http가 자동 처리)
        while (true) {
            const msg = ws.readSmallMessage() catch |err| {
                switch (err) {
                    error.ConnectionClose => {},
                    else => self.routineLog("  [ws] read error: {}\n", .{err}),
                }
                break;
            };

            switch (msg.opcode) {
                .text => {
                    self.routineLog("  [ws] recv: {s}\n", .{msg.data});
                },
                .connection_close => break,
                else => {},
            }
        }

        self.routineLog("  [ws] client disconnected\n", .{});
    }

    fn watchLoop(self: *DevServer) void {
        const abs_entry = self.abs_entry orelse return;

        // 증분 번들러 초기화 (모듈 캐싱 + 변경 감지)
        var inc_bundler = IncrementalBundler.init(self.allocator, .{
            .entry_points = &.{abs_entry},
            .platform = .browser,
            .dev_mode = true,
            .react_refresh = true,
            .collect_module_codes = true,
            .plugins = self.plugins,
            .define = self.define,
            .jsx_runtime = self.jsx_runtime,
            .jsx_import_source = self.jsx_import_source,
            .jsx_factory = self.jsx_factory,
            .jsx_fragment = self.jsx_fragment,
        });
        defer inc_bundler.deinit();

        // 초기 번들
        const initial = inc_bundler.rebuild(self.io) catch return;
        var fallback_paths = [_][]const u8{abs_entry};
        const initial_paths: []const []const u8 = switch (initial) {
            .success => |r| r.paths,
            .build_error => |err_msg| blk: {
                self.error_state.setOwned(self.io, self.allocator, err_msg);
                break :blk fallback_paths[0..];
            },
            .fatal => return,
        };

        // OS 네이티브 파일 감시 (kqueue/inotify, 미지원 OS는 mtime 폴백)
        var watcher = FileWatcher.init(self.allocator, self.io) catch return;
        defer watcher.deinit();

        for (initial_paths) |p| {
            watcher.addPath(p) catch {};
        }

        // root_dir의 CSS 파일을 watch 대상에 추가
        var css_paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (css_paths.items) |p| self.allocator.free(p);
            css_paths.deinit(self.allocator);
        }
        // root_path의 realpath는 서버 실행 중 불변이므로 1회만 계산
        const root_real = std.Io.Dir.cwd().realPathFileAlloc(self.io, self.root_path, self.allocator) catch null;
        defer if (root_real) |r| self.allocator.free(r);
        if (root_real) |root| {
            collectCssFiles(self.allocator, self.io, self.root_dir, root, &css_paths);
            // issue #3858 — dev mode 중 신규 .css 추가/삭제 감지를 위해 root_dir
            // 자체도 watch. FileWatcher 의 dir-watch (PR-1) 가 dir entry 변화 시
            // ChangeEvent{path=root} emit → watchLoop 가 rescan + 신규 path
            // addPath + synthetic event 트리거.
            watcher.addPath(root) catch {};
        }
        for (css_paths.items) |p| {
            watcher.addPath(p) catch {};
        }

        // issue #3858 — rescan 시 빠른 중복 체크용 set. css_paths 의 path 와 동일
        // 인스턴스 참조 (소유 X — css_paths 가 owner).
        var css_path_set: std.StringHashMapUnmanaged(void) = .empty;
        defer css_path_set.deinit(self.allocator);
        for (css_paths.items) |p| css_path_set.put(self.allocator, p, {}) catch {};

        self.routineLog("  [watch] watching {d} files for changes...\n", .{watcher.watchCount()});

        // #4063: shutdown 시 종료. waitForChanges 는 watch_interval_ms(500ms) 타임아웃이라
        // shutdown 후 늦어도 한 폴링 주기 안에 루프 top 으로 와 빠져나간다(deinit join 이 그만큼만 대기).
        while (!self.shutdown_requested.load(.acquire)) {
            const events = watcher.waitForChanges(watch_interval_ms) catch continue;
            if (self.shutdown_requested.load(.acquire)) break; // 폴링 반환 직후 재확인 — rebuild 진입 회피

            // Control API 경유 캐시 리셋 요청 처리 — 파일 변경 없어도 다음 rebuild를 전체 빌드로.
            if (self.cache_reset_requested.swap(false, .acquire)) {
                inc_bundler.reset();
                self.publishEvent(EventType.cache_reset, "{\"type\":\"cache_reset\"}");
                self.routineLog("  [ctrl] cache reset via /reset-cache\n", .{});
            }

            if (events.len == 0) continue;

            var changed_paths: std.ArrayList([]const u8) = .empty;
            defer changed_paths.deinit(self.allocator);
            // issue #3858 — event 의 path 가 dir-watch (root_dir) 매치 시 rescan 트리거.
            // PR-1 의 inotify dir-watch 가 file event 와 dir entry event 양쪽 emit 할
            // 수 있어 dedup 가드 (StringHashMap 기반 set).
            var changed_set: std.StringHashMapUnmanaged(void) = .empty;
            defer changed_set.deinit(self.allocator);
            var needs_rescan = false;
            for (events) |ev| {
                self.routineLog("  [watch] changed: {s}\n", .{std.fs.path.basename(ev.path)});
                if (root_real) |root| {
                    if (std.mem.eql(u8, ev.path, root)) {
                        needs_rescan = true;
                        continue; // dir entry event 는 changed_paths 에 넣지 않음 (caller 가 file path 만 처리).
                    }
                }
                const gop = changed_set.getOrPut(self.allocator, ev.path) catch continue;
                if (gop.found_existing) continue; // dedup
                changed_paths.append(self.allocator, ev.path) catch {};

                // SSE: watch_change 이벤트. 0.16: std.io.fixedBufferStream 제거
                // → std.Io.Writer.fixed (고정 버퍼 writer, buffered() 로 결과 조회).
                var ev_buf: [1024]u8 = undefined;
                var w = std.Io.Writer.fixed(&ev_buf);
                w.writeAll("{\"type\":\"watch_change\",\"file\":\"") catch continue;
                writeJsonEscaped(&w, ev.path) catch continue;
                w.writeAll("\"}") catch continue;
                self.publishEvent(EventType.watch_change, w.buffered());
            }

            // issue #3858 — root_dir 의 dir entry 변화 시 rescan. collectCssFiles
            // 재호출 + 신규 .css 발견 시 watcher.addPath + synthetic event.
            // 삭제된 path 는 removePath + synthetic event (caller 가 정리).
            //
            // /code-review max #1 (HIGH UAF) fix: 삭제 path 를 free 하기 전에
            // changed_paths 에 dupe 추가. broadcast 루프 종료 후 iteration 끝의
            // defer 가 dupe 메모리 일괄 free.
            var deletion_dupes: std.ArrayList([]const u8) = .empty;
            defer {
                for (deletion_dupes.items) |d| self.allocator.free(d);
                deletion_dupes.deinit(self.allocator);
            }

            if (needs_rescan and root_real != null) {
                const root = root_real.?;
                var new_css_paths: std.ArrayList([]const u8) = .empty;
                defer {
                    for (new_css_paths.items) |p| self.allocator.free(p);
                    new_css_paths.deinit(self.allocator);
                }
                collectCssFiles(self.allocator, self.io, self.root_dir, root, &new_css_paths);

                // new_css_paths set 으로 빠른 lookup
                var new_set: std.StringHashMapUnmanaged(void) = .empty;
                defer new_set.deinit(self.allocator);
                for (new_css_paths.items) |p| new_set.put(self.allocator, p, {}) catch {};

                // (a) 신규 path detect — new_set 에 있으나 css_path_set 에 없음
                for (new_css_paths.items) |p| {
                    if (css_path_set.contains(p)) continue;
                    const path_owned = self.allocator.dupe(u8, p) catch continue;
                    css_paths.append(self.allocator, path_owned) catch {
                        self.allocator.free(path_owned);
                        continue;
                    };
                    css_path_set.put(self.allocator, path_owned, {}) catch {};
                    watcher.addPath(path_owned) catch {};
                    // synthetic event — caller 가 css-update broadcast 트리거하도록
                    if (changed_set.getOrPut(self.allocator, path_owned) catch null) |gop| {
                        if (!gop.found_existing) changed_paths.append(self.allocator, path_owned) catch {};
                    }
                    self.routineLog("  [watch] new file added: {s}\n", .{std.fs.path.basename(path_owned)});
                }

                // (b) 삭제 path detect — css_path_set 에 있으나 new_set 에 없음
                var to_remove: std.ArrayList([]const u8) = .empty;
                defer to_remove.deinit(self.allocator);
                var it = css_path_set.keyIterator();
                while (it.next()) |k| {
                    if (!new_set.contains(k.*)) to_remove.append(self.allocator, k.*) catch {};
                }
                for (to_remove.items) |p| {
                    watcher.removePath(p);
                    // /code-review max #1 fix: p 의 dupe 를 deletion_dupes 에 보관,
                    // changed_paths 에 dupe append. css_paths 의 원본 free 후에도
                    // broadcast 루프 (line 714+) 가 dupe 를 안전하게 read.
                    const path_dupe = self.allocator.dupe(u8, p) catch continue;
                    deletion_dupes.append(self.allocator, path_dupe) catch {
                        self.allocator.free(path_dupe);
                        continue;
                    };
                    if (changed_set.getOrPut(self.allocator, path_dupe) catch null) |gop| {
                        if (!gop.found_existing) changed_paths.append(self.allocator, path_dupe) catch {};
                    }
                    _ = css_path_set.remove(p);
                    // css_paths 에서도 제거 (owner 라 free) — swap-remove 효율
                    for (css_paths.items, 0..) |cp, i| {
                        if (std.mem.eql(u8, cp, p)) {
                            _ = css_paths.swapRemove(i);
                            self.allocator.free(cp);
                            break;
                        }
                    }
                    self.routineLog("  [watch] file removed: {s}\n", .{std.fs.path.basename(path_dupe)});
                }
            }

            // CSS 변경 → 번들 재빌드 없이 css-update 전송
            var has_css = false;
            for (changed_paths.items) |cp| {
                if (std.mem.endsWith(u8, cp, ".css")) {
                    has_css = true;
                    const rel = if (root_real) |root| blk: {
                        if (std.mem.startsWith(u8, cp, root)) {
                            var r = cp[root.len..];
                            if (r.len > 0 and r[0] == '/') r = r[1..];
                            break :blk r;
                        }
                        break :blk std.fs.path.basename(cp);
                    } else std.fs.path.basename(cp);

                    var msg_buf: [512]u8 = undefined;
                    const css_msg = std.fmt.bufPrint(&msg_buf, "{{\"type\":\"css-update\",\"file\":\"/{s}\"}}", .{rel}) catch continue;
                    self.ws_clients.broadcast(self.io, css_msg);
                    self.routineLog("  [hmr] css update: {s}\n", .{std.fs.path.basename(cp)});
                }
            }

            var has_non_css = false;
            for (changed_paths.items) |cp| {
                if (!std.mem.endsWith(u8, cp, ".css")) {
                    has_non_css = true;
                    break;
                }
            }
            if (has_css and !has_non_css) continue;

            // bundle_build_started 이벤트
            const build_id = self.loadSeq();
            {
                var buf: [128]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{{\"type\":\"bundle_build_started\",\"id\":\"{d}\"}}", .{build_id})) |json| {
                    self.publishEvent(EventType.bundle_build_started, json);
                } else |_| {}
            }

            // 증분 재번들: watcher 가 감지한 변경 path set 을 그대로 전달 →
            // IncrementalBundler 가 graph_discover 의 stat skip + dev_mode 패키지
            // (skip_bundle_output, sourcemap.lazy) 자동 적용. NAPI watch (watch.zig:1135-1142)
            // 와 동일 패턴. emit_concat (~38ms) + emit_sourcemap_finalize (~19ms) 절감.
            // 0.16: std.time.nanoTimestamp 제거 → Io.Timestamp(awake 단조시계).
            const build_start_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
            const rebuild_result = inc_bundler.rebuildWithChanges(self.io, &changed_set) catch continue;
            const build_duration_ms = @as(f64, @floatFromInt(std.Io.Timestamp.now(self.io, .awake).toNanoseconds() - build_start_ns)) / std.time.ns_per_ms;
            switch (rebuild_result) {
                .success => |result| {
                    self.error_state.clear(self.io, self.allocator);
                    self.ws_clients.broadcast(self.io, "{\"type\":\"clear-error\"}");

                    // PR-4-i: 코드 변경이 있으면 lazy on-demand 청크 캐시 무효화(stale 방지).
                    // graph_changed=full-reload(seed 도 다음 GET 에 갱신), changed_modules=HMR
                    // update(seed 불변, 청크 바이트만 stale) 둘 다 청크 캐시는 비워야 한다.
                    //
                    // **이 watch 빌드는 eager**(inc_bundler 에 lazy_compilation/code_splitting 없음).
                    // lazy defer 는 `dev_mode and code_splitting and lazy_compilation and dynamic_import`
                    // 게이트라(PR-3a-i), eager 빌드에선 동적 import 타겟(heavy.ts)도 normal addModule
                    // 로 *파싱·watch 대상* 이 된다. 따라서 lazy seed 모듈을 편집해도 여기 changed_modules
                    // 에 잡혀 무효화가 발동한다(React.lazy 라우트 HMR 이 성립하는 것과 같은 이유).
                    if (result.graph_changed or result.changed_modules.len > 0) {
                        self.invalidateLazyChunksOnRebuild();
                    }

                    // bundle_build_done 이벤트. RFC #3940 Sub-PR-L.0c — ZNTC_PROFILE
                    // 활성 시 profile snapshot 을 별도 JSON 으로 dump. profile 비활성 (default)
                    // 이면 result.profile_snapshot 가 null → 기존 짧은 JSON 그대로.
                    //
                    // /code-review max followup #1 (CRITICAL) fix: profile JSON 작성 실패 시
                    // unlabeled `break` 가 가장 가까운 loop (`while (true)` watchLoop) 로
                    // 빠져나가 watch thread 가 silent 종료되는 버그. labeled block + bool 반환
                    // 으로 emit 실패 시 short JSON fallback 사용, loop 는 그대로 유지.
                    const emit_ok: bool = if (result.profile_snapshot) |snap| blk: {
                        // profile 활성 path — 큰 JSON 가능. 0.16: ArrayList.writer 제거 →
                        // Io.Writer.Allocating (snapshotToJson 이 *Io.Writer 그대로 받음).
                        var aw: std.Io.Writer.Allocating = .init(self.allocator);
                        defer aw.deinit();
                        const w = &aw.writer;
                        w.print("{{\"type\":\"bundle_build_done\",\"id\":\"{d}\",\"totalModules\":{d},\"duration\":{d:.2},\"profile\":", .{ build_id, result.paths.len, build_duration_ms }) catch break :blk false;
                        const _profile = @import("../profile.zig");
                        _profile.snapshotToJson(snap, w, 0.1) catch break :blk false; // 0.1ms threshold — sub-100us noise skip
                        w.writeByte('}') catch break :blk false;
                        self.publishEvent(EventType.bundle_build_done, aw.writer.buffered());
                        break :blk true;
                    } else false;

                    if (!emit_ok) {
                        // profile 비활성 default 또는 profile JSON emit 실패 → 기존 짧은 JSON path
                        var done_buf: [256]u8 = undefined;
                        if (std.fmt.bufPrint(&done_buf, "{{\"type\":\"bundle_build_done\",\"id\":\"{d}\",\"totalModules\":{d},\"duration\":{d:.2}}}", .{ build_id, result.paths.len, build_duration_ms })) |json| {
                            self.publishEvent(EventType.bundle_build_done, json);
                        } else |_| {}
                    }

                    if (result.graph_changed) {
                        // 그래프 구조 변경 → full-reload (새 import 추가 등)
                        self.ws_clients.broadcast(self.io, "{\"type\":\"full-reload\"}");
                        self.routineLog("  [hmr] graph changed, full-reload\n", .{});
                    } else if (result.changed_modules.len > 0) {
                        // 변경 모듈만 HMR update
                        self.ws_clients.broadcast(self.io, "{\"type\":\"update-start\"}");
                        const hmr_msg = buildHmrUpdateFromModules(
                            self.allocator,
                            result.changed_modules,
                        );
                        if (hmr_msg) |msg| {
                            defer self.allocator.free(msg);
                            self.ws_clients.broadcast(self.io, msg);
                            self.routineLog("  [hmr] incremental update ({d} modules)\n", .{result.changed_modules.len});
                        } else {
                            self.ws_clients.broadcast(self.io, "{\"type\":\"full-reload\"}");
                        }
                        self.ws_clients.broadcast(self.io, "{\"type\":\"update-done\"}");
                    } else {
                        // 코드 diff 없음 (타입만 변경 등) → Vite와 동일하게 무시
                        self.routineLog("  [hmr] no code change, skipping\n", .{});
                    }

                    // free changed_modules (id/code/map 각각 dupe 소유권 이전됨 — freeAll 필수).
                    if (result.changed_modules.len > 0) {
                        BundleResult.ModuleDevCode.freeAll(result.changed_modules, self.allocator);
                    }

                    // watch 대상 갱신
                    // result.paths는 inc_bundler.last_paths를 가리키므로
                    // 다음 rebuild에서 해제될 수 있다. watcher에 경로를 등록하면
                    // watcher가 내부적으로 복사하므로 안전.
                    watcher.clearPaths();
                    for (result.paths) |p| {
                        watcher.addPath(p) catch {};
                    }
                    for (css_paths.items) |p| {
                        watcher.addPath(p) catch {};
                    }
                    self.routineLog("  [watch] watching {d} files for changes...\n", .{watcher.watchCount()});
                },
                .build_error => |err_msg| {
                    defer self.allocator.free(err_msg);
                    self.error_state.setCopy(self.io, self.allocator, err_msg) catch {};
                    self.ws_clients.broadcast(self.io, err_msg);
                    self.routineLog("  [watch] build error, overlay sent\n", .{});

                    // bundle_build_failed 이벤트 (err_msg는 이미 JSON)
                    var fail_buf: [256]u8 = undefined;
                    if (std.fmt.bufPrint(&fail_buf, "{{\"type\":\"bundle_build_failed\",\"id\":\"{d}\"}}", .{build_id})) |json| {
                        self.publishEvent(EventType.bundle_build_failed, json);
                    } else |_| {}
                },
                .fatal => {},
            }
        }
    }

    /// 변경 모듈 목록에서 HMR update JSON 메시지를 빌드한다.
    fn buildHmrUpdateFromModules(
        allocator: std.mem.Allocator,
        modules: []const BundleResult.ModuleDevCode,
    ) ?[]const u8 {
        if (modules.len == 0) return null;

        // 0.16: ArrayList.writer 제거 → Io.Writer.Allocating. defer deinit +
        // toOwnedSlice(성공 시 소유권 이관 → deinit no-op, catch-return-null 경로는 free).
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        w.print("{{\"type\":\"update\",\"modules\":[", .{}) catch return null;
        for (modules, 0..) |m, i| {
            if (i > 0) w.print(",", .{}) catch {};
            w.print("{{\"id\":\"", .{}) catch return null;
            writeJsonEscaped(w, m.id) catch return null;
            w.print("\",\"code\":\"", .{}) catch return null;
            writeJsonEscaped(w, m.code) catch return null;
            w.print("\"}}", .{}) catch return null;
        }
        w.print("]}}", .{}) catch return null;
        return aw.toOwnedSlice() catch return null;
    }

    /// root_dir에서 .css 파일을 재귀 탐색하여 절대 경로 목록에 추가.
    fn collectCssFiles(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, dir_path: []const u8, out: *std.ArrayList([]const u8)) void {
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .directory) {
                if (std.mem.eql(u8, entry.name, "node_modules")) continue;
                if (entry.name.len > 0 and entry.name[0] == '.') continue;
                var sub_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close(io);
                const sub_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
                defer allocator.free(sub_path);
                collectCssFiles(allocator, io, sub_dir, sub_path, out);
            } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".css")) {
                const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
                out.append(allocator, full_path) catch {};
            }
        }
    }

    /// `/sse/events` — Server-Sent Events 스트림.
    /// long-lived HTTP 응답으로 이벤트 수신자 등록, 연결 종료 시 제거.
    fn handleSse(self: *DevServer, request: *http.Server.Request) !void {
        const sse_headers = cors_headers ++ [_]http.Header{
            .{ .name = "Content-Type", .value = "text/event-stream" },
            .{ .name = "Cache-Control", .value = "no-cache" },
            .{ .name = "Connection", .value = "keep-alive" },
            .{ .name = "X-Accel-Buffering", .value = "no" },
        };

        // respondStreaming + chunked transfer encoding 명시 (Bun fetch 등 클라이언트 호환).
        var body_buf: [1024]u8 = undefined;
        var response = request.respondStreaming(&body_buf, .{
            .respond_options = .{
                .extra_headers = &sse_headers,
                .transfer_encoding = .chunked,
            },
        }) catch return;

        // 초기 ping
        response.writer.writeAll(": connected\n\n") catch return;
        response.writer.flush() catch return;
        response.flush() catch return;

        var sink: SseSink = .{ .writer = &response.writer, .body_writer = &response };
        self.sse_clients.add(self.io, &sink);
        defer self.sse_clients.remove(self.io, &sink);

        // keep-alive: 30초마다 주석 전송. broadcast와 race 방지를 위해 sink mutex 사용.
        // #4066: SSE 는 socket read 가 아니라 io.sleep 으로 대기 → shutdown(.both) 가 안 깨운다.
        // 30s 를 짧게(500ms) 쪼개 sleep 중에도 shutdown_requested 를 폴링 → shutdown 후 ≤500ms
        // 에 종료(안 그러면 connection thread 가 최대 30s 잔존 → 2s deinit timeout 너머 UAF).
        while (!self.shutdown_requested.load(.acquire)) {
            var slept_ms: u64 = 0;
            while (slept_ms < 30_000) {
                if (self.shutdown_requested.load(.acquire)) return;
                // 0.16: std.Thread.sleep 제거 → io.sleep(duration, clock).
                self.io.sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};
                slept_ms += 500;
            }
            self.sse_clients.mutex.lockUncancelable(self.io);
            const ok = blk: {
                response.writer.writeAll(": keep-alive\n\n") catch break :blk false;
                response.writer.flush() catch break :blk false;
                response.flush() catch break :blk false;
                break :blk true;
            };
            self.sse_clients.mutex.unlock(self.io);
            if (!ok) break;
        }
    }

    /// 이벤트를 SSE 구독자 전원에 브로드캐스트.
    /// event_seq 는 u64 라 32-bit 네이티브 타깃에서는 lock-free atomic 이 불가능하다
    /// ("expected 32-bit integer type or smaller"). 64-bit & 멀티스레드일 때만 atomic 을
    /// 쓰고, 그 외(32-bit 멀티스레드)는 mutex, single-thread 면 plain 접근으로 fallback —
    /// profile.zig 의 useAtomicCounter 와 동일한 전략이다.
    inline fn seqUsesAtomic() bool {
        return !builtin.single_threaded and
            !builtin.cpu.arch.isWasm() and
            @bitSizeOf(u64) <= @bitSizeOf(usize);
    }

    fn loadSeq(self: *DevServer) u64 {
        if (comptime seqUsesAtomic()) return self.event_seq.load(.monotonic);
        if (comptime !builtin.single_threaded) self.seq_mutex.lock();
        defer if (comptime !builtin.single_threaded) self.seq_mutex.unlock();
        return self.event_seq.raw;
    }

    fn nextSeq(self: *DevServer) u64 {
        if (comptime seqUsesAtomic()) return self.event_seq.fetchAdd(1, .monotonic) + 1;
        if (comptime !builtin.single_threaded) self.seq_mutex.lock();
        defer if (comptime !builtin.single_threaded) self.seq_mutex.unlock();
        self.event_seq.raw += 1;
        return self.event_seq.raw;
    }

    /// `data_json`은 유효한 JSON 오브젝트 문자열이어야 한다 (이스케이프 호출부 책임).
    pub fn publishEvent(self: *DevServer, event_type: []const u8, data_json: []const u8) void {
        _ = self.nextSeq();
        self.sse_clients.broadcast(self.io, event_type, data_json);
    }

    fn handleRequest(self: *DevServer, request: *http.Server.Request) !void {
        if (request.head.method == .OPTIONS) {
            try request.respond("", .{
                .status = .no_content,
                .extra_headers = &cors_headers,
            });
            return;
        }

        // 프록시 매칭: 경로 prefix가 일치하면 백엔드로 전달
        for (self.proxy) |rule| {
            if (std.mem.startsWith(u8, request.head.target, rule.path)) {
                self.handleProxy(request, rule) catch {
                    request.respond("502 Bad Gateway", .{
                        .status = .bad_gateway,
                        .extra_headers = &cors_headers,
                    }) catch {};
                };
                return;
            }
        }

        // 방법 제한 전에 검사하는 라우트 (POST 허용 Control API)
        {
            const target_early = request.head.target;
            const path_end_early = std.mem.indexOfScalar(u8, target_early, '?') orelse target_early.len;
            const raw_path_early = target_early[0..path_end_early];

            // /sse/events — GET (event-stream)
            if (std.mem.eql(u8, raw_path_early, "/sse/events")) {
                self.handleSse(request) catch {};
                return;
            }

            // Control API: /reset-cache — 모든 HTTP method 허용
            if (std.mem.eql(u8, raw_path_early, "/reset-cache")) {
                self.cache_reset_requested.store(true, .release);
                request.respond("{\"ok\":true,\"action\":\"reset_cache\"}", .{
                    .status = .ok,
                    .extra_headers = &json_headers,
                }) catch {};
                return;
            }
        }

        if (request.head.method != .GET and request.head.method != .HEAD) {
            try request.respond("405 Method Not Allowed", .{
                .status = .method_not_allowed,
                .extra_headers = &cors_headers,
            });
            return;
        }

        const target = request.head.target;
        const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const raw_path_with_base = target[0..path_end];
        const raw_path = self.stripBasePath(raw_path_with_base);

        const rel_path = sanitizePath(raw_path) orelse {
            try request.respond("403 Forbidden", .{
                .status = .forbidden,
                .extra_headers = &cors_headers,
            });
            return;
        };

        if (self.entry_point != null) {
            // /@react-refresh — react-refresh/runtime 가상 모듈 (Vite 방식)
            if (std.mem.eql(u8, raw_path, "/@react-refresh")) {
                self.serveReactRefresh(request) catch {};
                return;
            }

            if (std.mem.eql(u8, raw_path, app_dev_client_path)) {
                self.serveAppDevClient(request) catch {};
                return;
            }

            // /bundle.js.map — 캐시된 소스맵 반환
            if (std.mem.eql(u8, raw_path, "/bundle.js.map")) {
                self.serveSourceMap(request) catch {};
                return;
            }

            if (std.mem.eql(u8, raw_path, bundle_path)) {
                self.serveBundle(request) catch |err| {
                    self.routineLog("zntc: bundle failed: {}\n", .{err});
                    request.respond("500 Bundle Error", .{
                        .status = .internal_server_error,
                        .extra_headers = &cors_headers,
                    }) catch {};
                };
                return;
            }

            // PR-3b-iii: lazy on-demand 청크 라우트. `/<stem>-<pathhash>.js` 가 마지막 entry
            // 빌드의 seed 와 매칭되면 그 seed 를 force-parse 해 단일 청크로 컴파일·서빙한다.
            // 매칭 안 되면 (lazy 아님/일반 정적 파일) static fallback 으로 흘려보낸다.
            if (self.lazy_compilation and self.tryServeLazyChunk(request, rel_path)) {
                return;
            }

            if (std.mem.eql(u8, rel_path, "index.html")) {
                self.serveStaticFile(request, rel_path) catch |err| switch (err) {
                    error.FileNotFound => {
                        try self.serveAutoHtml(request);
                    },
                    else => return err,
                };
                return;
            }
        }

        self.serveStaticFile(request, rel_path) catch |err| switch (err) {
            error.FileNotFound => {
                // SPA 폴백: 확장자 없는 경로 → index.html (React Router 등)
                if (self.entry_point != null and std.fs.path.extension(rel_path).len == 0) {
                    self.serveStaticFile(request, "index.html") catch |e2| switch (e2) {
                        error.FileNotFound => try self.serveAutoHtml(request),
                        else => return e2,
                    };
                } else {
                    try request.respond("404 Not Found", .{
                        .status = .not_found,
                        .extra_headers = &cors_headers,
                    });
                }
            },
            else => return err,
        };
    }

    fn serveBundle(self: *DevServer, request: *http.Server.Request) !void {
        const abs_entry = self.abs_entry orelse unreachable;

        // PR-3b-iii: lazy 모드는 dev_split(code_splitting+lazy)로 빌드해 entry 청크만 서빙.
        if (self.lazy_compilation) return self.serveBundleLazy(request);

        var bundler = Bundler.init(self.allocator, .{
            .entry_points = &.{abs_entry},
            .platform = .browser,
            .dev_mode = true,
            .root_dir = self.root_path,
            .react_refresh = true,
            .plugins = self.plugins,
            .define = self.define,
            .jsx_runtime = self.jsx_runtime,
            .jsx_import_source = self.jsx_import_source,
            .jsx_factory = self.jsx_factory,
            .jsx_fragment = self.jsx_fragment,
        });
        defer bundler.deinit();

        var result = try bundler.bundle(self.io);
        defer result.deinit(self.allocator);

        if (result.hasErrors()) {
            const diags = result.getDiagnostics();
            if (buildErrorJsonFromDiagnostics(self.allocator, diags)) |err_json| {
                defer self.allocator.free(err_json);
                self.error_state.setCopy(self.io, self.allocator, err_json) catch {};
                self.ws_clients.broadcast(self.io, err_json);
            } else |_| {}

            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(self.allocator);
            // 0.16: ArrayList.writer 제거 → ArrayList.print(gpa, ...) 직접 사용.
            try msg.print(self.allocator, "// ZNTC Bundle Error\n", .{});
            for (diags) |d| {
                try msg.print(self.allocator, "// [{s}] {s}: {s}\n", .{
                    @tagName(d.severity),
                    d.file_path,
                    d.message,
                });
            }
            try msg.print(self.allocator, "console.error('ZNTC: bundle failed, see server logs');\n", .{});

            try request.respond(msg.items, .{
                .status = .internal_server_error,
                .extra_headers = &js_headers,
            });

            self.routineLog("  500 {s} (bundle errors)\n", .{abs_entry});
            return;
        }
        self.error_state.clear(self.io, self.allocator);
        self.ws_clients.broadcast(self.io, "{\"type\":\"clear-error\"}");

        // 소스맵 캐시 업데이트 (소유권 이전 — dupe 불필요)
        if (result.sourcemap) |sm| {
            self.sourcemap_cache.mutex.lock();
            defer self.sourcemap_cache.mutex.unlock();
            if (self.sourcemap_cache.data) |old| self.allocator.free(old);
            self.sourcemap_cache.data = sm;
            result.sourcemap = null; // deinit에서 이중 해제 방지
        }

        try request.respond(result.output, .{
            .extra_headers = &js_headers,
        });

        self.routineLog("  200 {s} (bundled)\n", .{bundle_path});
    }

    /// PR-3b-iii: serveBundle/serveLazyChunk 공용 — 빌드 에러를 진단 주석 JS 로 응답한다
    /// (브라우저가 console.error 로 표면화). overlay/WS 브로드캐스트도 수행.
    fn respondBuildError(self: *DevServer, request: *http.Server.Request, result: *BundleResult, label: []const u8) !void {
        const diags = result.getDiagnostics();
        if (buildErrorJsonFromDiagnostics(self.allocator, diags)) |err_json| {
            defer self.allocator.free(err_json);
            self.error_state.setCopy(self.io, self.allocator, err_json) catch {};
            self.ws_clients.broadcast(self.io, err_json);
        } else |_| {}

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.print(self.allocator, "// ZNTC Bundle Error\n", .{});
        for (diags) |d| {
            try msg.print(self.allocator, "// [{s}] {s}: {s}\n", .{ @tagName(d.severity), d.file_path, d.message });
        }
        try msg.print(self.allocator, "console.error('ZNTC: bundle failed, see server logs');\n", .{});
        try request.respond(msg.items, .{ .status = .internal_server_error, .extra_headers = &js_headers });
        self.routineLog("  500 {s} (bundle errors)\n", .{label});
    }

    /// chunk OutputFile 중 `wanted` 절대경로를 `module_ids` 에 포함한 첫 청크 인덱스.
    /// entry 청크(entry 모듈 포함) 또는 lazy 청크(seed 모듈 포함) 식별에 쓴다.
    fn findChunkContaining(outputs: []const lib.bundler.emitter.OutputFile, wanted: []const u8) ?usize {
        for (outputs, 0..) |o, i| {
            if (o.kind != .chunk) continue;
            for (o.module_ids) |mid| {
                if (std.mem.eql(u8, mid, wanted)) return i;
            }
        }
        return null;
    }

    /// 요청 청크 이름(`<stem>-<pathhash>.js`)을 seed 절대경로로 역참조한다. pathhash =
    /// `truncate(u32, Wyhash(0, seed_path))` 의 8자리 hex (chunk.zig 의 lazy_path_hash 와 동일
    /// 공식). **이름의 마지막 `-` 뒤(없으면 stem 전체) 세그먼트가 정확히 8 hex 이고** seed
    /// 의 hash 와 eql 일 때만 매칭 → `/vendor-deadbeef-styles.js` 같은 정적 자산 오탐 차단
    /// (substring 매칭이 아님). 매칭 없으면 null → static fallback. **순수 함수** — 단위 테스트 대상.
    fn resolveLazySeedPath(seed_paths: []const []const u8, requested_name: []const u8) ?[]const u8 {
        if (!std.mem.endsWith(u8, requested_name, ".js")) return null;
        const stem = requested_name[0 .. requested_name.len - ".js".len];
        // hash 세그먼트 = 마지막 '-' 뒤(stem 에 '-' 없으면 stem 전체). [name]-[hash] / [hash] 패턴 모두 수용.
        const seg = if (std.mem.lastIndexOfScalar(u8, stem, '-')) |i| stem[i + 1 ..] else stem;
        if (seg.len != 8) return null;
        for (seg) |c| if (!std.ascii.isHex(c)) return null;
        for (seed_paths) |sp| {
            var hash_buf: [8]u8 = undefined;
            const h: u32 = @truncate(std.hash.Wyhash.hash(0, sp));
            _ = std.fmt.bufPrint(&hash_buf, "{x:0>8}", .{h}) catch continue;
            if (std.mem.eql(u8, seg, &hash_buf)) return sp;
        }
        return null;
    }

    /// dev_split(code_splitting+lazy)로 빌드해 **entry 청크만** 서빙한다. 동적 import 타겟은
    /// 미파싱 seed 로 남아 emit-skip → 브라우저가 `__zntc_load_chunk("<stem>-<pathhash>.js")`
    /// 요청 시 `tryServeLazyChunk` 가 on-demand 컴파일. 빌드가 수집한 seed 경로를 lazy_state
    /// 에 저장(역참조용)하고, entry rebuild 라 stale 가능한 청크 캐시를 비운다.
    fn serveBundleLazy(self: *DevServer, request: *http.Server.Request) !void {
        const abs_entry = self.abs_entry orelse unreachable;
        const entries = [_][]const u8{abs_entry};

        var bundler = Bundler.init(self.allocator, .{
            .entry_points = &entries,
            .platform = .browser,
            .dev_mode = true,
            .root_dir = self.root_path,
            .react_refresh = true,
            .plugins = self.plugins,
            .define = self.define,
            .jsx_runtime = self.jsx_runtime,
            .jsx_import_source = self.jsx_import_source,
            .jsx_factory = self.jsx_factory,
            .jsx_fragment = self.jsx_fragment,
            .code_splitting = true,
            .lazy_compilation = true,
            // IIFE registry 모델: cross-chunk 참조가 `__zntc_require("entry.js")` 런타임
            // 조회(네트워크 fetch 아님) → entry 를 /bundle.js 로 서빙해도 정합. 동적 청크는
            // `__zntc_load_chunk("<stem>-<pathhash>.js")` 로 lazy 라우트를 fetch. (PR-3b-ii
            // node e2e 로 검증된 모델 — ESM 기본값은 `import "./entry.js"` 로 /entry.js 를
            // fetch 하려 해 깨짐.)
            .format = .iife,
        });
        defer bundler.deinit();

        var result = try bundler.bundle(self.io);
        defer result.deinit(self.allocator);

        if (result.hasErrors()) return self.respondBuildError(request, &result, abs_entry);
        self.error_state.clear(self.io, self.allocator);
        self.ws_clients.broadcast(self.io, "{\"type\":\"clear-error\"}");

        // seed 목록 갱신 + 청크 캐시 무효화 (entry rebuild → 이전 lazy 청크 stale 가능).
        // **MVP 범위**: 무효화는 *이 /bundle.js GET 시점* 에만 일어난다. 브라우저는 파일 변경
        // 시 HMR/full-reload 로 entry 를 다시 받으므로 일반 흐름에선 정합한다. 단 watch 가
        // /bundle.js 재요청 없이 백그라운드 rebuild 하는 경로는 캐시를 비우지 않아 stale 가능 —
        // watch 연동 무효화는 PR-4(HMR + 재귀 lazy) 범위. (RFC §4)
        {
            self.lazy_state.mutex.lock();
            defer self.lazy_state.mutex.unlock();
            self.lazy_state.invalidateChunks(self.allocator);
            try self.lazy_state.setSeedPaths(self.allocator, result.lazy_seed_paths orelse &.{});
        }

        const outputs = result.outputs orelse {
            // code_splitting 인데 outputs 가 없으면 비정상 — 단일 output 으로 폴백.
            try request.respond(result.output, .{ .extra_headers = &js_headers });
            self.routineLog("  200 {s} (lazy entry, single)\n", .{bundle_path});
            return;
        };

        const entry_idx = findChunkContaining(outputs, abs_entry) orelse {
            self.routineLog("  500 {s} (lazy: entry 청크 미발견)\n", .{abs_entry});
            try request.respond("500 Lazy entry chunk not found", .{
                .status = .internal_server_error,
                .extra_headers = &cors_headers,
            });
            return;
        };

        // entry 청크 소스맵 캐시 (소유권 이전).
        if (try outputs[entry_idx].getSourceMapJSON(self.allocator)) |sm| {
            self.sourcemap_cache.mutex.lock();
            defer self.sourcemap_cache.mutex.unlock();
            if (self.sourcemap_cache.data) |old| self.allocator.free(old);
            self.sourcemap_cache.data = sm;
        }

        try request.respond(outputs[entry_idx].contents, .{ .extra_headers = &js_headers });
        self.routineLog("  200 {s} (lazy entry, {d} seeds)\n", .{ bundle_path, self.lazy_state.seed_paths.len });
    }

    /// PR-4-i: watch 가 파일 변경으로 rebuild 했을 때 lazy on-demand 청크 캐시를 비운다.
    /// 이미 서빙·캐시된 lazy 청크(예: heavy.ts)가 편집되면 그 캐시 바이트가 stale 이므로
    /// **전체 무효화** → 다음 요청이 fresh 빌드. (dev 캐시라 over-invalidate 안전 — 변경
    /// 모듈→청크 역매핑 없이 단순·확실. per-chunk 정밀 무효화는 후속.) seed 목록은 건드리지
    /// 않는다: HMR update(코드만 변경)는 seed 집합 불변이고, graph 변경(import 추가/삭제)은
    /// full-reload→다음 /bundle.js GET 의 `serveBundleLazy.setSeedPaths` 가 seed 갱신.
    /// lazy_compilation 아니면 no-op. **HTTP 무관 — 단위 테스트 공용.**
    fn invalidateLazyChunksOnRebuild(self: *DevServer) void {
        if (!self.lazy_compilation) return;
        self.lazy_state.mutex.lock();
        defer self.lazy_state.mutex.unlock();
        self.lazy_state.invalidateChunks(self.allocator);
    }

    /// `/<stem>-<pathhash>.js` 요청을 처리한다. 마지막 entry 빌드의 seed 와 매칭되면 그
    /// seed 만 force-parse 해 단일 청크로 컴파일·서빙하고 `true` 반환. 매칭 안 되면(lazy
    /// 청크 아님) `false` 반환 → caller 가 static fallback. 응답 실패 등 내부 에러도 삼켜
    /// `true`(처리됨)로 반환 — 라우팅 일관성 유지.
    ///
    /// **동시성**: connection 마다 thread 라 다른 thread 의 `serveBundleLazy` 가 entry rebuild
    /// 로 `seed_paths`/`chunk_cache` 를 교체·해제할 수 있다. 그래서 락 안에서 캐시/seed 를
    /// *사본* 으로 떠내고 락 밖에서 응답·빌드한다(공유 슬라이스를 락 밖에서 잡지 않음 → UAF 차단).
    fn tryServeLazyChunk(self: *DevServer, request: *http.Server.Request, rel_path: []const u8) bool {
        const requested = std.fs.path.basename(rel_path);

        var cached_copy: ?[]u8 = null;
        var seed_copy: ?[]u8 = null;
        {
            self.lazy_state.mutex.lock();
            defer self.lazy_state.mutex.unlock();
            if (self.lazy_state.chunk_cache.get(requested)) |cached| {
                cached_copy = self.allocator.dupe(u8, cached) catch null; // null → 아래서 500
            } else if (resolveLazySeedPath(self.lazy_state.seed_paths, requested)) |sp| {
                seed_copy = self.allocator.dupe(u8, sp) catch null; // null → 아래서 500
            } else {
                return false; // lazy 청크 아님 → static fallback
            }
        }

        // 캐시 히트 — 사본으로 응답.
        if (cached_copy) |bytes| {
            defer self.allocator.free(bytes);
            request.respond(bytes, .{ .extra_headers = &js_headers }) catch {};
            self.routineLog("  200 /{s} (lazy cache)\n", .{requested});
            return true;
        }

        // 캐시 미스 — seed force-parse 빌드.
        if (seed_copy) |sp| {
            defer self.allocator.free(sp);
            self.serveLazyChunkBuild(request, requested, sp) catch |err| {
                self.routineLog("  500 /{s} (lazy build: {})\n", .{ requested, err });
                request.respond("500 Lazy chunk build error", .{
                    .status = .internal_server_error,
                    .extra_headers = &cors_headers,
                }) catch {};
            };
            return true;
        }

        // 여기 도달 = lazy 청크로 식별됐으나 dupe OOM. static fallback 말고 500(처리됨).
        request.respond("500 Lazy chunk OOM", .{
            .status = .internal_server_error,
            .extra_headers = &cors_headers,
        }) catch {};
        return true;
    }

    /// buildLazyChunkBytes 반환값 — 청크 바이트 + 이 빌드에서 발견한 미파싱 seed 경로(중첩
    /// 동적 import 포함). 둘 다 caller 소유. `deinitLazyChunkBuild` 로 해제.
    const LazyChunkBuild = struct {
        bytes: []u8,
        nested_seeds: []const []const u8,
    };

    fn deinitLazyChunkBuild(self: *DevServer, b: LazyChunkBuild) void {
        self.allocator.free(b.bytes);
        for (b.nested_seeds) |s| self.allocator.free(s);
        if (b.nested_seeds.len > 0) self.allocator.free(b.nested_seeds);
    }

    /// seed 를 force-parse 해 그 동적 청크 바이트 + 이 빌드의 미파싱 seed 목록을 **caller
    /// 소유**로 반환한다. force-parse 한 seed 가 자기 `import()` 를 가지면 그 중첩 타겟이
    /// `lazy_seed_paths` 에 새 seed 로 들어온다(재귀 lazy 입력). entry 는 결정론(shared-off
    /// + export-all, PR-3b-ii)이라 동적 청크는 `__zntc_require("entry.js")` 단방향 조회로 안전.
    /// HTTP 무관 — serveLazyChunkBuild 와 단위 테스트 공용.
    fn buildLazyChunkBytes(self: *DevServer, seed_path: []const u8) !LazyChunkBuild {
        const abs_entry = self.abs_entry orelse return error.NoEntryPoint;
        const entries = [_][]const u8{abs_entry};
        const force_parse = [_][]const u8{seed_path};

        var bundler = Bundler.init(self.allocator, .{
            .entry_points = &entries,
            .platform = .browser,
            .dev_mode = true,
            .root_dir = self.root_path,
            .react_refresh = true,
            .plugins = self.plugins,
            .define = self.define,
            .jsx_runtime = self.jsx_runtime,
            .jsx_import_source = self.jsx_import_source,
            .jsx_factory = self.jsx_factory,
            .jsx_fragment = self.jsx_fragment,
            .code_splitting = true,
            .lazy_compilation = true,
            .lazy_force_parse = &force_parse,
            // serveBundleLazy 와 동일 IIFE registry 모델(위 주석 참조).
            .format = .iife,
        });
        defer bundler.deinit();

        var result = try bundler.bundle(self.io);
        defer result.deinit(self.allocator);

        if (result.hasErrors()) return error.LazyChunkBuildFailed;
        const outputs = result.outputs orelse return error.LazyChunkNoOutputs;
        const chunk_idx = findChunkContaining(outputs, seed_path) orelse return error.LazyChunkNotFound;

        const bytes = try self.allocator.dupe(u8, outputs[chunk_idx].contents);
        errdefer self.allocator.free(bytes);

        // 이 빌드의 미파싱 seed 사본(중첩 동적 import 포함) — 재귀 lazy 누적용. 비면 alloc(0)
        // 대신 빈 슬라이스(deinit 의 len>0 가드와 정합).
        const src_seeds = result.lazy_seed_paths orelse &.{};
        const nested: []const []const u8 = if (src_seeds.len == 0) &.{} else blk: {
            const arr = try self.allocator.alloc([]const u8, src_seeds.len);
            errdefer self.allocator.free(arr);
            var n: usize = 0;
            errdefer for (arr[0..n]) |p| self.allocator.free(p);
            for (src_seeds) |s| {
                arr[n] = try self.allocator.dupe(u8, s);
                n += 1;
            }
            break :blk arr;
        };
        return .{ .bytes = bytes, .nested_seeds = nested };
    }

    /// `buildLazyChunkBytes` 로 컴파일한 청크를 서빙하고 `requested` 이름으로 캐시한다.
    /// 캐시에는 *독립 사본* 을 둔다. PR-4-ii: 빌드가 발견한 중첩 seed 를 `lazy_state` 에 누적
    /// (addSeedPaths) → 재귀 동적 import 타겟도 후속 요청에서 역참조된다.
    fn serveLazyChunkBuild(self: *DevServer, request: *http.Server.Request, requested: []const u8, seed_path: []const u8) !void {
        // 빌드 *전* 무효화 세대 캡처 — 빌드 도중(락 밖) watch 무효화/entry rebuild 가 끼면
        // 이 빌드 바이트는 stale 일 수 있으므로 캐시에 넣지 않는다(TOCTOU staleness 가드).
        self.lazy_state.mutex.lock();
        const start_epoch = self.lazy_state.epoch;
        self.lazy_state.mutex.unlock();

        const built = try self.buildLazyChunkBytes(seed_path);
        defer self.deinitLazyChunkBuild(built);

        try request.respond(built.bytes, .{ .extra_headers = &js_headers });

        // 캐시 저장(독립 사본) + 중첩 seed 누적. race 로 캐시에 이미 있으면 skip.
        self.lazy_state.mutex.lock();
        defer self.lazy_state.mutex.unlock();
        // best-effort: 실패해도 seed_paths 는 errdefer 로 무손상(이번 중첩만 미누적 → 후속 404).
        self.lazy_state.addSeedPaths(self.allocator, built.nested_seeds) catch |e|
            self.routineLog("  [lazy] nested seed 누적 실패({}) — 중첩 청크는 다음 entry 빌드 후 해소\n", .{e});
        // epoch 가 변했으면(빌드 도중 무효화) stale 가능 → 캐시 오염 방지 위해 *저장 skip*.
        // 이번 응답은 이미 보냈고(브라우저는 무효화 시 곧 reload), 다음 요청이 fresh 빌드한다.
        if (self.lazy_state.epoch == start_epoch and !self.lazy_state.chunk_cache.contains(requested)) {
            const key = try self.allocator.dupe(u8, requested);
            errdefer self.allocator.free(key);
            const val = try self.allocator.dupe(u8, built.bytes);
            errdefer self.allocator.free(val);
            try self.lazy_state.chunk_cache.put(self.allocator, key, val);
        }
        self.routineLog("  200 /{s} (lazy built, seed={s})\n", .{ requested, seed_path });
    }

    const sourcemap_headers = cors_headers ++ [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
    };

    fn serveSourceMap(self: *DevServer, request: *http.Server.Request) !void {
        self.sourcemap_cache.mutex.lock();
        defer self.sourcemap_cache.mutex.unlock();

        if (self.sourcemap_cache.data) |sm| {
            try request.respond(sm, .{
                .extra_headers = &sourcemap_headers,
            });
            self.routineLog("  200 /bundle.js.map\n", .{});
        } else {
            try request.respond("", .{
                .status = .not_found,
                .extra_headers = &cors_headers,
            });
        }
    }

    fn serveAppDevClient(self: *DevServer, request: *http.Server.Request) !void {
        try request.respond(self.overlay_client, .{
            .extra_headers = &js_headers,
        });
        self.routineLog("  200 {s}\n", .{app_dev_client_path});
    }

    /// /@react-refresh — react-refresh/runtime 가상 모듈 서빙.
    /// node_modules에서 react-refresh/runtime.js를 찾아 글로벌 바인딩 코드로 감싸서 반환.
    /// 설치되어 있지 않으면 noop 폴백을 반환한다.
    fn serveReactRefresh(self: *DevServer, request: *http.Server.Request) !void {
        // node_modules/react-refresh/runtime.js 탐색 (root_dir 기준)
        // 0.16: readFileAlloc(io, sub_path, gpa, limit) 인자 순서/형태 변경.
        const runtime_code = self.root_dir.readFileAlloc(
            self.io,
            "node_modules/react-refresh/runtime.js",
            self.allocator,
            std.Io.Limit.limited(max_file_size),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                // react-refresh 미설치 → noop 폴백
                const noop =
                    \\// react-refresh not installed — run: npm install react-refresh
                    \\window.__REACT_REFRESH_RUNTIME__ = undefined;
                ;
                try request.respond(noop, .{ .extra_headers = &js_headers });
                self.routineLog("  200 /@react-refresh (noop — not installed)\n", .{});
                return;
            },
            else => return err,
        };
        defer self.allocator.free(runtime_code);

        // react-refresh/runtime을 글로벌에 바인딩하는 래퍼 코드
        const preamble =
            \\(function() {
            \\var exports = {};
            \\var module = { exports: exports };
            \\
        ;
        const epilogue =
            \\
            \\window.__REACT_REFRESH_RUNTIME__ = module.exports;
            \\window.__REACT_REFRESH_RUNTIME__.injectIntoGlobalHook(window);
            \\})();
            \\
        ;

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try output.appendSlice(self.allocator, preamble);
        try output.appendSlice(self.allocator, runtime_code);
        try output.appendSlice(self.allocator, epilogue);

        try request.respond(output.items, .{ .extra_headers = &js_headers });
        self.routineLog("  200 /@react-refresh\n", .{});
    }

    fn serveAutoHtml(self: *DevServer, request: *http.Server.Request) !void {
        const html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head><meta charset="utf-8"><title>ZNTC Dev Server</title></head>
            \\<body>
            \\<div id="root"></div>
            \\<script src="/@react-refresh"></script>
            \\<script type="module" src="/__zntc_app_dev_client__"></script>
            \\<script type="module" src="/bundle.js"></script>
            \\</body>
            \\</html>
        ;

        try request.respond(html, .{
            .extra_headers = &html_headers,
        });

        self.routineLog("  200 / (auto html)\n", .{});
    }

    fn serveStaticFile(self: *DevServer, request: *http.Server.Request, rel_path: []const u8) !void {
        // 0.16: openFile + File.readToEndAlloc 제거 → Dir.readFileAlloc(io, ...).
        // 크기 초과 에러는 FileTooBig → StreamTooLong 로 명칭 변경.
        const content = self.root_dir.readFileAlloc(self.io, rel_path, self.allocator, std.Io.Limit.limited(max_file_size)) catch |err| switch (err) {
            error.StreamTooLong => {
                try request.respond("413 Payload Too Large", .{
                    .status = .payload_too_large,
                    .extra_headers = &cors_headers,
                });
                return;
            },
            else => return err,
        };
        defer self.allocator.free(content);

        const content_type = mime.fromExtension(rel_path);
        const headers = cors_headers ++ [_]http.Header{
            .{ .name = "Content-Type", .value = content_type },
        };

        if (self.entry_point != null and std.mem.eql(u8, rel_path, "index.html")) {
            const injected = try self.injectAppDevClient(content);
            defer self.allocator.free(injected);
            try request.respond(injected, .{
                .extra_headers = &headers,
            });
            self.routineLog("  200 {s}\n", .{rel_path});
            return;
        }

        try request.respond(content, .{
            .extra_headers = &headers,
        });

        self.routineLog("  200 {s}\n", .{rel_path});
    }

    fn injectAppDevClient(self: *DevServer, html: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, html, app_dev_client_path) != null) {
            return try self.allocator.dupe(u8, html);
        }

        const tag = "<script type=\"module\" src=\"" ++ app_dev_client_path ++ "\"></script>\n";
        const insert_at = std.mem.indexOf(u8, html, "</head>") orelse
            std.mem.indexOf(u8, html, "<script") orelse
            html.len;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, html[0..insert_at]);
        try out.appendSlice(self.allocator, tag);
        try out.appendSlice(self.allocator, html[insert_at..]);
        return try out.toOwnedSlice(self.allocator);
    }

    fn stripBasePath(self: *const DevServer, raw_path: []const u8) []const u8 {
        if (self.base_path.len == 0 or std.mem.eql(u8, self.base_path, "/")) return raw_path;
        if (!std.mem.startsWith(u8, raw_path, self.base_path)) return raw_path;
        const rest = raw_path[self.base_path.len..];
        if (rest.len == 0) return "/";
        if (rest[0] == '/') return rest;
        return raw_path;
    }

    const cors_headers = [_]http.Header{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        .{ .name = "Access-Control-Allow-Methods", .value = "GET, HEAD, OPTIONS" },
        .{ .name = "Access-Control-Allow-Headers", .value = "*" },
        .{ .name = "Cache-Control", .value = "no-cache, no-store, must-revalidate" },
    };

    const json_headers = cors_headers ++ [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
    };
};

/// URL path를 안전한 상대 경로로 변환한다.
/// `..` 세그먼트나 의심스러운 경로는 null을 반환한다.
/// `/` → `index.html`, `/foo/bar` → `foo/bar`
pub fn sanitizePath(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return "index.html";

    var path = raw;
    while (path.len > 0 and path[0] == '/') {
        path = path[1..];
    }

    if (path.len == 0) return "index.html";

    // null 바이트, 백슬래시 — path traversal 방지
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;

    // `..` 세그먼트 — 디렉토리 탈출 방지
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return null;
    }

    return path;
}

// ──────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────

// PR-3b-iii: lazy on-demand 라우트의 역참조 핵심. 요청 청크 이름의 pathhash 8-hex 가
// seed 경로의 truncate(Wyhash) 와 일치하면 그 seed 경로를 돌려준다(chunk_names 패턴 무관).
test "resolveLazySeedPath: 청크 이름의 pathhash 로 seed 역참조" {
    const testing = std.testing;
    const seeds = [_][]const u8{ "/abs/src/heavy.ts", "/abs/src/other.ts" };

    // heavy 의 기대 청크 이름 구성: "<stem>-<8hex>.js" (8hex = truncate(u32, Wyhash(path))).
    var hash_buf: [8]u8 = undefined;
    const h: u32 = @truncate(std.hash.Wyhash.hash(0, seeds[0]));
    _ = std.fmt.bufPrint(&hash_buf, "{x:0>8}", .{h}) catch unreachable;
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "heavy-{s}.js", .{hash_buf}) catch unreachable;

    const got = DevServer.resolveLazySeedPath(&seeds, name) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(seeds[0], got);

    // 매칭 seed 없는 8-hex → null (static fallback).
    try testing.expect(DevServer.resolveLazySeedPath(&seeds, "stranger-12345678.js") == null);
    // .js 확장자 아님 → null (정적 자산).
    try testing.expect(DevServer.resolveLazySeedPath(&seeds, "heavy-deadbeef.css") == null);
    // 빈 seed 목록 → 항상 null.
    try testing.expect(DevServer.resolveLazySeedPath(&.{}, name) == null);

    // **strict 매칭**: 정확한 hash 가 *마지막 세그먼트가 아니라 stem 중간* 에 있으면 오탐 금지.
    // (substring 매칭이었으면 hijack 됐을 정적 자산 `<hash>-styles.js` 케이스)
    var mid_buf: [64]u8 = undefined;
    const mid = std.fmt.bufPrint(&mid_buf, "{s}-styles.js", .{hash_buf}) catch unreachable; // seg="styles"
    try testing.expect(DevServer.resolveLazySeedPath(&seeds, mid) == null);
    // 마지막 세그먼트가 8자 아님(7 hex) → null.
    try testing.expect(DevServer.resolveLazySeedPath(&seeds, "heavy-deadbee.js") == null);
}

// PR-3b-iii: LazyState 라이프사이클 — setSeedPaths 가 이전 사본 해제+새 사본 보유,
// invalidateChunks 가 캐시 엔트리(key/value) 해제, deinit 이 전부 정리. testing.allocator
// 가 leak/double-free 를 검출한다.
test "LazyState: setSeedPaths/invalidateChunks/deinit 누수·이중해제 없음" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var st: DevServer.LazyState = .{};

    // 1차 seed 세팅. dedup: 중복 입력은 1개로(lazy_seed_paths 는 graph 에서 dup 가능).
    try st.setSeedPaths(alloc, &.{ "/a/x.ts", "/a/y.ts", "/a/x.ts" });
    try testing.expectEqual(@as(usize, 2), st.seed_paths.len); // x,y (중복 x 제거)
    try testing.expectEqualStrings("/a/x.ts", st.seed_paths[0]);

    // 2차 세팅 → 이전 사본 해제(누수 없음) + 교체.
    try st.setSeedPaths(alloc, &.{"/a/z.ts"});
    try testing.expectEqual(@as(usize, 1), st.seed_paths.len);
    try testing.expectEqualStrings("/a/z.ts", st.seed_paths[0]);

    // PR-4-ii addSeedPaths: union+dedup. 기존(/a/z.ts) + 새 2개, 이미 있는 z 는 skip,
    // 배치 내 중복(/a/w.ts x2)도 1개만.
    const old_z_ptr = st.seed_paths[0].ptr; // 포인터째 이관 확인용
    try st.addSeedPaths(alloc, &.{ "/a/z.ts", "/a/w.ts", "/a/w.ts", "/a/q.ts" });
    try testing.expectEqual(@as(usize, 3), st.seed_paths.len); // z(기존) + w + q
    try testing.expectEqualStrings("/a/z.ts", st.seed_paths[0]); // 기존 포인터 이관(앞에 유지)
    try testing.expectEqual(old_z_ptr, st.seed_paths[0].ptr); // 재dupe 안 함 — 같은 주소
    var saw_w = false;
    var saw_q = false;
    for (st.seed_paths) |p| {
        if (std.mem.eql(u8, p, "/a/w.ts")) saw_w = true;
        if (std.mem.eql(u8, p, "/a/q.ts")) saw_q = true;
    }
    try testing.expect(saw_w and saw_q);
    // 전부 기존이면 no-op(길이 불변).
    try st.addSeedPaths(alloc, &.{ "/a/z.ts", "/a/w.ts" });
    try testing.expectEqual(@as(usize, 3), st.seed_paths.len);

    // 청크 캐시에 엔트리 2개(key/value 모두 owned dupe).
    {
        const k1 = try alloc.dupe(u8, "heavy-00000001.js");
        const v1 = try alloc.dupe(u8, "chunk-bytes-1");
        try st.chunk_cache.put(alloc, k1, v1);
        const k2 = try alloc.dupe(u8, "heavy-00000002.js");
        const v2 = try alloc.dupe(u8, "chunk-bytes-2");
        try st.chunk_cache.put(alloc, k2, v2);
    }
    try testing.expectEqual(@as(usize, 2), st.chunk_cache.count());

    // 무효화 → 엔트리 해제 + 비움(capacity 유지). PR-4-iii: epoch +1(TOCTOU staleness 가드).
    const epoch_before = st.epoch;
    st.invalidateChunks(alloc);
    try testing.expectEqual(@as(usize, 0), st.chunk_cache.count());
    try testing.expectEqual(epoch_before +% 1, st.epoch); // 진행 중 빌드가 stale 캐시 못 넣게 함

    // 무효화 후 재사용 가능.
    {
        const k = try alloc.dupe(u8, "heavy-00000003.js");
        const v = try alloc.dupe(u8, "chunk-bytes-3");
        try st.chunk_cache.put(alloc, k, v);
    }
    try testing.expectEqual(@as(usize, 1), st.chunk_cache.count());

    st.deinit(alloc); // seed_paths + chunk_cache 전부 정리.
}

// PR-4-i: watch rebuild 시 lazy 청크 캐시 무효화. lazy_compilation=true 면 캐시를 비우고,
// false 면 no-op(비-lazy 서버는 lazy_state 미사용). seed_paths 는 보존(코드만 변경 케이스).
test "invalidateLazyChunksOnRebuild: lazy 면 청크 캐시 비우고 seed 보존, non-lazy 면 no-op" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    // ── lazy 서버: 캐시 + seed 채운 뒤 무효화 → 청크만 비고 seed 는 남음.
    {
        var server = try DevServer.init(testing.allocator, testing.io, .{
            .root_dir = tmp_path,
            .port = 0,
            .lazy_compilation = true,
        });
        defer server.deinit();
        server.shutdown();

        server.lazy_state.mutex.lock();
        try server.lazy_state.setSeedPaths(testing.allocator, &.{"/a/heavy.ts"});
        const k = try testing.allocator.dupe(u8, "heavy-00000001.js");
        const v = try testing.allocator.dupe(u8, "stale-bytes");
        try server.lazy_state.chunk_cache.put(testing.allocator, k, v);
        server.lazy_state.mutex.unlock();

        server.invalidateLazyChunksOnRebuild();
        try testing.expectEqual(@as(usize, 0), server.lazy_state.chunk_cache.count());
        try testing.expectEqual(@as(usize, 1), server.lazy_state.seed_paths.len); // seed 보존

        // 멱등: 이미 빈 캐시에 재호출해도 안전(no-op, seed 그대로).
        server.invalidateLazyChunksOnRebuild();
        try testing.expectEqual(@as(usize, 0), server.lazy_state.chunk_cache.count());
        try testing.expectEqual(@as(usize, 1), server.lazy_state.seed_paths.len);
    }

    // ── non-lazy 서버: invalidate 는 no-op (캐시 비어있고 lazy_state 미사용).
    {
        var server = try DevServer.init(testing.allocator, testing.io, .{
            .root_dir = tmp_path,
            .port = 0,
            .lazy_compilation = false,
        });
        defer server.deinit();
        server.shutdown();
        server.invalidateLazyChunksOnRebuild(); // gate 로 즉시 반환 — crash 없음.
        try testing.expectEqual(@as(usize, 0), server.lazy_state.chunk_cache.count());
    }
}

// PR-3b-iii: dev server on-demand 컴파일 end-to-end (HTTP 제외). seed(heavy)를 force-parse 해
// 동적 청크를 빌드하면 heavy 본문 + entry 로의 단방향 require(`__zntc_require`)가 들어있어야
// 한다 — entry 결정론(shared-off + export-all)이라 동적 청크가 entry 심볼을 단방향 조회.
test "buildLazyChunkBytes: seed force-parse → 동적 청크 (entry 단방향 require)" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "shared.ts", .data = "export const v = 'SHARED_V';" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "heavy.ts", .data = "import { v } from './shared';\nexport const h = 'HEAVY_' + v;" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "entry.ts", .data = "import { v as sv } from './shared';\nasync function go(){ const m = await import('./heavy'); console.log(m.h); }\nconsole.log(sv);\ngo();" });

    const entry_abs = try tmp.dir.realPathFileAlloc(testing.io, "entry.ts", testing.allocator);
    defer testing.allocator.free(entry_abs);
    const heavy_abs = try tmp.dir.realPathFileAlloc(testing.io, "heavy.ts", testing.allocator);
    defer testing.allocator.free(heavy_abs);

    var server = try DevServer.init(testing.allocator, testing.io, .{
        .root_dir = tmp_path,
        .entry_point = entry_abs,
        .port = 0,
        .lazy_compilation = true,
    });
    defer server.deinit();
    server.shutdown();

    const built = try server.buildLazyChunkBytes(heavy_abs);
    defer server.deinitLazyChunkBuild(built);
    const bytes = built.bytes;

    try testing.expect(std.mem.indexOf(u8, bytes, "HEAVY_") != null);
    // IIFE registry: heavy 는 "heavy.js" 로 등록하고 entry 를 단방향 require(네트워크 fetch
    // 아님). 역방향 정적 참조 없음 → entry 결정론과 정합.
    try testing.expect(std.mem.indexOf(u8, bytes, "__zntc_require(\"entry.js\")") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "__zntc_register") != null);

    // ── 루프 클로저: entry 가 부르는 __zntc_load_chunk("<name>") URL 이 reverse-lookup 으로
    // heavy seed 로 되돌아와야 한다(브라우저 요청 URL ↔ 라우트 매칭의 핵심 정합). entry 를
    // force-parse 없이 빌드(serveBundleLazy 와 같은 옵션) → load_chunk 이름 추출 → 역참조.
    {
        var bnd = Bundler.init(testing.allocator, .{
            .entry_points = &.{entry_abs},
            .platform = .browser,
            .dev_mode = true,
            .root_dir = tmp_path,
            .code_splitting = true,
            .lazy_compilation = true,
            .format = .iife,
        });
        defer bnd.deinit();
        var result = try bnd.bundle(testing.io);
        defer result.deinit(testing.allocator);
        const outs = result.outputs orelse return error.TestUnexpectedResult;
        const seeds = result.lazy_seed_paths orelse return error.TestUnexpectedResult;

        var chunk_name: ?[]const u8 = null;
        for (outs) |o| {
            const lc = std.mem.indexOf(u8, o.contents, "__zntc_load_chunk(\"") orelse continue;
            const start = lc + "__zntc_load_chunk(\"".len;
            const end = std.mem.indexOfScalarPos(u8, o.contents, start, '"') orelse continue;
            chunk_name = o.contents[start..end];
            break;
        }
        const name = chunk_name orelse return error.TestUnexpectedResult;
        const resolved = DevServer.resolveLazySeedPath(seeds, name) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(heavy_abs, resolved);
    }

    // ── PR-4-i 린치핀: watch loop 의 **eager** 빌드(lazy_compilation/code_splitting 없음)는
    // 동적 import 타겟(heavy.ts)도 normal addModule 로 파싱·watch 한다. 그래서 lazy seed
    // 모듈을 편집해도 watch rebuild 의 changed_modules 에 잡혀 무효화가 발동한다. eager 빌드의
    // module_paths 에 heavy 가 포함되는지로 증명(없으면 무효화 게이트가 영영 안 fire → 버그).
    {
        var bnd = Bundler.init(testing.allocator, .{
            .entry_points = &.{entry_abs},
            .platform = .browser,
            .dev_mode = true, // watch loop 와 동일 — code_splitting/lazy_compilation 없음(eager)
        });
        defer bnd.deinit();
        var result = try bnd.bundle(testing.io);
        defer result.deinit(testing.allocator);
        const paths = result.module_paths orelse return error.TestUnexpectedResult;
        var has_heavy = false;
        for (paths) |p| if (std.mem.eql(u8, p, heavy_abs)) {
            has_heavy = true;
        };
        try testing.expect(has_heavy); // eager watch 가 lazy seed 모듈을 본다 → 편집 시 무효화 발동
    }
}

// PR-4-ii: 재귀 lazy — heavy 가 자기 `import('./deeper')` 를 가질 때, heavy 를 on-demand
// 빌드(force-parse)하면 deeper 가 중첩 seed 로 `built.nested_seeds` 에 노출되어야 한다.
// dev server 가 이를 addSeedPaths 로 누적하면 deeper 도 후속 라우트로 역참조된다.
test "buildLazyChunkBytes: 중첩 import() 가 nested_seeds 로 노출(재귀 lazy)" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "deeper.ts", .data = "export const d = 'DEEPER';" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "heavy.ts", .data = "export async function load(){ const m = await import('./deeper'); return m.d; }" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "entry.ts", .data = "async function go(){ const m = await import('./heavy'); console.log(await m.load()); }\ngo();" });

    const entry_abs = try tmp.dir.realPathFileAlloc(testing.io, "entry.ts", testing.allocator);
    defer testing.allocator.free(entry_abs);
    const heavy_abs = try tmp.dir.realPathFileAlloc(testing.io, "heavy.ts", testing.allocator);
    defer testing.allocator.free(heavy_abs);
    const deeper_abs = try tmp.dir.realPathFileAlloc(testing.io, "deeper.ts", testing.allocator);
    defer testing.allocator.free(deeper_abs);

    var server = try DevServer.init(testing.allocator, testing.io, .{
        .root_dir = tmp_path,
        .entry_point = entry_abs,
        .port = 0,
        .lazy_compilation = true,
    });
    defer server.deinit();
    server.shutdown();

    const built = try server.buildLazyChunkBytes(heavy_abs);
    defer server.deinitLazyChunkBuild(built);

    var has_deeper = false;
    for (built.nested_seeds) |s| if (std.mem.eql(u8, s, deeper_abs)) {
        has_deeper = true;
    };
    try testing.expect(has_deeper); // 중첩 seed 노출 → addSeedPaths 누적으로 재귀 lazy 성립

    // 누적 검증: addSeedPaths 후 lazy_state.seed_paths 에 deeper 포함.
    server.lazy_state.mutex.lock();
    try server.lazy_state.addSeedPaths(testing.allocator, built.nested_seeds);
    var accumulated = false;
    for (server.lazy_state.seed_paths) |s| if (std.mem.eql(u8, s, deeper_abs)) {
        accumulated = true;
    };
    server.lazy_state.mutex.unlock();
    try testing.expect(accumulated);

    // ── 풀체인 루프 클로저: heavy 청크가 부르는 __zntc_load_chunk("deeper-<hash>.js") URL 이
    // 누적된 seed_paths 로 reverse-lookup 되어 deeper_abs 로 되돌아와야 한다. 이게 성립해야
    // 브라우저가 deeper 청크를 올바른 라우트로 요청 → 재귀 lazy 가 런타임에 실제로 동작.
    // (nested seed 경로가 절대경로 + Wyhash 정합임도 함께 증명.)
    {
        const lc = std.mem.indexOf(u8, built.bytes, "__zntc_load_chunk(\"") orelse return error.TestUnexpectedResult;
        const start = lc + "__zntc_load_chunk(\"".len;
        const end = std.mem.indexOfScalarPos(u8, built.bytes, start, '"') orelse return error.TestUnexpectedResult;
        const deeper_chunk_name = built.bytes[start..end];

        server.lazy_state.mutex.lock();
        const resolved = DevServer.resolveLazySeedPath(server.lazy_state.seed_paths, deeper_chunk_name);
        server.lazy_state.mutex.unlock();
        try testing.expectEqualStrings(deeper_abs, resolved orelse return error.TestUnexpectedResult);
    }
}

// PR-4-iii: 그래프 변경(동적 import 타겟 교체) → entry 재계산 시 seed 집합이 재산출되고
// PR-4-ii 로 누적됐던 stale nested seed 도 폐기되어야 한다. dev 서버는 /bundle.js GET 마다
// serveBundleLazy 가 fresh 빌드 + setSeedPaths(replace) 하므로 graph 변경은 이 경로로 정합
// (watchLoop graph_changed→full-reload→재GET). **범위**: 이 테스트는 그 핵심 불변(빌드→
// setSeedPaths 가 seed 집합을 재산출·stale 폐기)을 dev-server 레벨에서 고정한다 — watch→
// full-reload→브라우저 재GET 전체 파이프라인의 e2e 는 아님(브라우저 준수는 별도).
// entry 의 동적 import 를 heavy→other 로 바꿔 재빌드하면 seed_paths={other} (heavy/누적 stale 제거).
test "LazyCompilation PR-4-iii: 그래프 변경 시 entry 재빌드가 seed 집합 재산출 + stale 누적 폐기" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "heavy.ts", .data = "export const h = 'H';" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "other.ts", .data = "export const o = 'O';" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "entry.ts", .data = "async function go(){ const m = await import('./heavy'); console.log(m.h); }\ngo();" });

    const entry_abs = try tmp.dir.realPathFileAlloc(testing.io, "entry.ts", testing.allocator);
    defer testing.allocator.free(entry_abs);
    const heavy_abs = try tmp.dir.realPathFileAlloc(testing.io, "heavy.ts", testing.allocator);
    defer testing.allocator.free(heavy_abs);
    const other_abs = try tmp.dir.realPathFileAlloc(testing.io, "other.ts", testing.allocator);
    defer testing.allocator.free(other_abs);

    var server = try DevServer.init(testing.allocator, testing.io, .{
        .root_dir = tmp_path,
        .entry_point = entry_abs,
        .port = 0,
        .lazy_compilation = true,
    });
    defer server.deinit();
    server.shutdown();

    // serveBundleLazy 와 동일 옵션으로 entry 를 lazy 빌드해 seed 를 얻는 헬퍼.
    const buildSeeds = struct {
        fn run(srv: *DevServer, e: []const u8, st: *DevServer.LazyState, alloc: std.mem.Allocator, io: std.Io) !void {
            var bnd = Bundler.init(alloc, .{
                .entry_points = &.{e},
                .platform = .browser,
                .dev_mode = true,
                .root_dir = srv.root_path,
                .code_splitting = true,
                .lazy_compilation = true,
                .format = .iife,
            });
            defer bnd.deinit();
            var result = try bnd.bundle(io);
            defer result.deinit(alloc);
            st.mutex.lock();
            defer st.mutex.unlock();
            try st.setSeedPaths(alloc, result.lazy_seed_paths orelse &.{});
        }
    }.run;

    // 1) 초기 빌드: entry→import(heavy). + 누적 stale nested seed(other 를 흉내) 주입.
    try buildSeeds(&server, entry_abs, &server.lazy_state, testing.allocator, testing.io);
    server.lazy_state.mutex.lock();
    try server.lazy_state.addSeedPaths(testing.allocator, &.{"/stale/nested.ts"}); // PR-4-ii 누적 흉내
    server.lazy_state.mutex.unlock();
    {
        var has_heavy = false;
        var has_stale = false;
        for (server.lazy_state.seed_paths) |s| {
            if (std.mem.eql(u8, s, heavy_abs)) has_heavy = true;
            if (std.mem.eql(u8, s, "/stale/nested.ts")) has_stale = true;
        }
        try testing.expect(has_heavy and has_stale);
    }

    // 2) 그래프 변경: entry 의 동적 import 를 heavy→other 로 교체 후 재빌드(= 다음 /bundle.js GET).
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "entry.ts", .data = "async function go(){ const m = await import('./other'); console.log(m.o); }\ngo();" });
    try buildSeeds(&server, entry_abs, &server.lazy_state, testing.allocator, testing.io);

    // 3) seed 집합 재산출: other 만, heavy/누적 stale 둘 다 제거(setSeedPaths replace).
    var has_other = false;
    var has_heavy2 = false;
    var has_stale2 = false;
    for (server.lazy_state.seed_paths) |s| {
        if (std.mem.eql(u8, s, other_abs)) has_other = true;
        if (std.mem.eql(u8, s, heavy_abs)) has_heavy2 = true;
        if (std.mem.eql(u8, s, "/stale/nested.ts")) has_stale2 = true;
    }
    try testing.expect(has_other); // 새 동적 타겟 반영
    try testing.expect(!has_heavy2); // 옛 타겟 제거
    try testing.expect(!has_stale2); // 누적 stale nested 폐기
    try testing.expectEqual(@as(usize, 1), server.lazy_state.seed_paths.len); // 정확히 {other}
}

test "collectCssFiles: .css만 수집하고 .js는 제외" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // tmpDir 생성
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // .css 파일 2개 + .js 파일 1개 생성
    tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.css", .data = "" }) catch return error.TestUnexpectedResult;
    tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.css", .data = "" }) catch return error.TestUnexpectedResult;
    tmp.dir.writeFile(std.testing.io, .{ .sub_path = "c.js", .data = "" }) catch return error.TestUnexpectedResult;

    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    DevServer.collectCssFiles(allocator, std.testing.io, tmp.dir, "/root", &out);

    // .css 2개만 수집되어야 한다
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // 수집된 경로에 .css만 있는지 확인
    for (out.items) |p| {
        try testing.expect(std.mem.endsWith(u8, p, ".css"));
    }
}

test "collectCssFiles: node_modules 내 .css 제외" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // 일반 .css
    tmp.dir.writeFile(std.testing.io, .{ .sub_path = "style.css", .data = "" }) catch return error.TestUnexpectedResult;

    // node_modules/ 하위 .css — 제외되어야 함
    tmp.dir.createDirPath(std.testing.io, "node_modules/pkg") catch return error.TestUnexpectedResult;
    tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/pkg/lib.css", .data = "" }) catch return error.TestUnexpectedResult;

    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    DevServer.collectCssFiles(allocator, std.testing.io, tmp.dir, "/root", &out);

    // node_modules 내 .css는 제외 → 1개만
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.endsWith(u8, out.items[0], "style.css"));
}

test "collectCssFiles: 숨김 폴더(.git) 내 .css 제외" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main.css", .data = "" }) catch return error.TestUnexpectedResult;

    // .git/ 하위 .css — 숨김 폴더이므로 제외되어야 함
    tmp.dir.createDirPath(std.testing.io, ".git/hooks") catch return error.TestUnexpectedResult;
    tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git/hooks/style.css", .data = "" }) catch return error.TestUnexpectedResult;

    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    DevServer.collectCssFiles(allocator, std.testing.io, tmp.dir, "/root", &out);

    // .git 내 .css는 제외 → 1개만
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.endsWith(u8, out.items[0], "main.css"));
}

test "buildHmrUpdateFromModules: 모듈 0개 → null 반환" {
    const result = DevServer.buildHmrUpdateFromModules(
        std.testing.allocator,
        &.{},
    );
    try std.testing.expect(result == null);
}

test "buildHmrUpdateFromModules: 모듈 1개 → update JSON" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const modules = [_]BundleResult.ModuleDevCode{
        .{ .id = "src/app.ts", .code = "console.log(1)" },
    };

    const json = DevServer.buildHmrUpdateFromModules(allocator, &modules) orelse {
        return error.TestUnexpectedResult;
    };
    defer allocator.free(json);

    // "type":"update" 포함
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"update\"") != null);
    // "modules":[ 포함
    try testing.expect(std.mem.indexOf(u8, json, "\"modules\":[") != null);
    // 모듈 id 포함
    try testing.expect(std.mem.indexOf(u8, json, "src/app.ts") != null);
    // 모듈 code 포함
    try testing.expect(std.mem.indexOf(u8, json, "console.log(1)") != null);
}

test "buildHmrUpdateFromModules: 모듈 2개 → 콤마로 구분된 배열" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const modules = [_]BundleResult.ModuleDevCode{
        .{ .id = "a.ts", .code = "code_a" },
        .{ .id = "b.ts", .code = "code_b" },
    };

    const json = DevServer.buildHmrUpdateFromModules(allocator, &modules) orelse {
        return error.TestUnexpectedResult;
    };
    defer allocator.free(json);

    // 두 모듈 모두 포함
    try testing.expect(std.mem.indexOf(u8, json, "a.ts") != null);
    try testing.expect(std.mem.indexOf(u8, json, "b.ts") != null);

    // },{  패턴 → 콤마로 구분된 배열 항목
    try testing.expect(std.mem.indexOf(u8, json, "},{") != null);

    // 전체 JSON이 올바르게 닫히는지 확인
    try testing.expect(std.mem.endsWith(u8, json, "]}"));
}

test "substituteOverlayPlaceholders: raw sentinel 들이 protocol 값으로 치환됨" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = try DevServer.substituteOverlayPlaceholders(allocator);
    defer allocator.free(result);

    // 모든 sentinel 토큰이 사라져야 함.
    try testing.expect(std.mem.indexOf(u8, result, "__ZNTC_HMR_WS_PATH__") == null);
    try testing.expect(std.mem.indexOf(u8, result, "__ZNTC_HMR_MSG_ERROR__") == null);
    try testing.expect(std.mem.indexOf(u8, result, "__ZNTC_HMR_MSG_CLEAR_ERROR__") == null);
    try testing.expect(std.mem.indexOf(u8, result, "__ZNTC_HMR_MSG_UPDATE_START__") == null);
    try testing.expect(std.mem.indexOf(u8, result, "__ZNTC_HMR_MSG_UPDATE_DONE__") == null);
    try testing.expect(std.mem.indexOf(u8, result, "__ZNTC_HMR_MSG_UPDATE__") == null);
    try testing.expect(std.mem.indexOf(u8, result, "__ZNTC_HMR_MSG_FULL_RELOAD__") == null);
    try testing.expect(std.mem.indexOf(u8, result, "__ZNTC_HMR_MSG_CSS_UPDATE__") == null);

    // 치환된 protocol 값들이 본문 어딘가에 string literal 로 박혀야 함
    // (const 선언 라인 또는 사용처). @zntc/server/protocol 과 동기.
    try testing.expect(std.mem.indexOf(u8, result, "\"/__hmr\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"clear-error\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"update-start\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"update-done\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"update\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"full-reload\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"css-update\"") != null);

    // 핵심 분기 (update / css-update / __zntc_apply_update) 보존.
    try testing.expect(std.mem.indexOf(u8, result, "__zntc_apply_update") != null);
    try testing.expect(std.mem.indexOf(u8, result, "new WebSocket(") != null);
}

test "DevServer.init: cert 만 set + key 없음 → error.TlsKeyMissing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    const result = DevServer.init(std.testing.allocator, std.testing.io, .{
        .root_dir = dir_path,
        .cert_path = "/some/cert.pem",
        // key_path = null
    });
    try std.testing.expectError(error.TlsKeyMissing, result);
}

test "DevServer.init: key 만 set + cert 없음 → error.TlsKeyMissing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    const result = DevServer.init(std.testing.allocator, std.testing.io, .{
        .root_dir = dir_path,
        .key_path = "/some/key.pem",
        // cert_path = null
    });
    try std.testing.expectError(error.TlsKeyMissing, result);
}

test "DevServer.init: 둘 다 set + 존재하지 않는 파일 → CertLoadFailed (TlsContext init fail propagate)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    const result = DevServer.init(std.testing.allocator, std.testing.io, .{
        .root_dir = dir_path,
        .cert_path = "/nonexistent/cert.pem",
        .key_path = "/nonexistent/key.pem",
    });
    // tls.Error.CertLoadFailed 가 그대로 propagate
    try std.testing.expectError(error.CertLoadFailed, result);
}

test "DevServer.init: cert/key 둘 다 null → plain HTTP (tls_ctx null)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var dev_server = try DevServer.init(std.testing.allocator, std.testing.io, .{
        .root_dir = dir_path,
    });
    defer dev_server.deinit();
    try std.testing.expect(dev_server.tls_ctx == null);
}
