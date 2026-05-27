const std = @import("std");
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

fn getLog() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
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
    root_dir: std.fs.Dir,
    root_path: []const u8,
    /// 실제 listen 중인 port. listen 전엔 init 시점 옵션값, listen 후엔 OS-assigned
    /// port (옵션이 0 이었던 경우) 포함 실제 값. NAPI `getDevServerPort` 가 이 필드 노출.
    port: u16,
    host: []const u8,
    open: bool,
    /// stderr 출력 silence. NAPI embed 등 외부 logger 가 있을 때 true.
    quiet: bool,
    tcp_server: ?std.net.Server,
    entry_point: ?[]const u8,
    abs_entry: ?[]const u8,
    ws_clients: WsClients = .{},
    sse_clients: SseClients = .{},
    /// 모노토닉 이벤트 시퀀스 (SSE payload의 id 필드).
    event_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// event_seq fallback 보호용 — 32-bit 타깃은 64-bit atomic 미지원이라
    /// `loadSeq`/`nextSeq`가 atomic 대신 이 mutex로 직렬화한다 (아래 헬퍼 참조).
    seq_mutex: std.Thread.Mutex = .{},
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
    plugins: []const plugin_mod.Plugin = &.{},
    proxy: []const ProxyRule = &.{},
    base_path: []const u8 = "/",
    define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
    jsx_runtime: @import("../codegen/codegen.zig").JsxRuntime = .classic,
    jsx_import_source: []const u8 = "react",
    jsx_factory: []const u8 = "React.createElement",
    jsx_fragment: []const u8 = "React.Fragment",
    sourcemap_cache: struct {
        mutex: std.Thread.Mutex = .{},
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

    pub fn init(allocator: std.mem.Allocator, options: Options) !DevServer {
        // init 의 진단 로그 — `quiet` 와 **무관** 하게 항상 stderr 출력. 사용자가
        // init failure 를 못 보면 NAPI throwError 의 generic 메시지만 받고 어느
        // 경로/cert/key 가 문제인지 진단 못 함. dev-time critical path 라 quiet 영향
        // 외 (start fatal / deinit UAF 경고도 같은 contract).
        const root_dir = std.fs.cwd().openDir(options.root_dir, .{ .iterate = true }) catch |err| {
            getLog().print("zntc: cannot open directory '{s}': {}\n", .{ options.root_dir, err }) catch {};
            return err;
        };
        // 이후 ! 반환은 모두 root_dir 을 닫아야 함 (open 직후 ownership 이 init 에
        // 있어 호출자가 deinit 못 호출). errdefer 한 줄로 통일해 향후 init 후반에
        // 추가될 fallible 자원이 leak 을 발생시키지 않도록 가드 (#2538 4-3 review).
        errdefer {
            var dir_copy = root_dir;
            dir_copy.close();
        }

        var abs_entry: ?[]const u8 = null;
        if (options.entry_point) |ep| {
            abs_entry = std.fs.cwd().realpathAlloc(allocator, ep) catch |err| {
                getLog().print("zntc: cannot resolve entry '{s}': {}\n", .{ ep, err }) catch {};
                return err;
            };
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
        };
    }

    pub fn deinit(self: *DevServer) void {
        // shutdown() 호출 — shutdown_requested set + self-connect trigger 로 blocking
        // accept() 를 깨움 (macOS/Linux 에서 listen socket close 만으론 accept 안 깨움).
        // 그 뒤 listen socket 정리.
        self.shutdown();
        if (self.tcp_server) |*s| s.deinit();
        // 살아있는 connection (handleConnection thread) 가 종료할 때까지 wait. 최대
        // 2초 (best-effort) — production 은 process exit 직전 deinit 라 그 시점엔
        // thread 종료된 상태가 일반적. 2초 넘어가면 log + 그대로 진행.
        const DEINIT_TIMEOUT_MS: u64 = 2000;
        const start_ns: u128 = @intCast(@max(0, std.time.nanoTimestamp()));
        const deadline_ns: u128 = start_ns + DEINIT_TIMEOUT_MS * std.time.ns_per_ms;
        while (true) {
            const count = self.active_connections.load(.acquire);
            if (count == 0) break;
            const now_ns: u128 = @intCast(@max(0, std.time.nanoTimestamp()));
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
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        if (self.abs_entry) |ae| self.allocator.free(ae);
        // overlay_client 는 init 에서 반드시 알록된 owned slice (default 미제공).
        self.allocator.free(self.overlay_client);
        if (self.tls_ctx) |*c| c.deinit();
        self.root_dir.close();
        self.error_state.deinit(self.allocator);
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

    pub fn start(self: *DevServer) !void {
        // host 바인딩: "localhost" → 127.0.0.1, "0.0.0.0" → 모든 인터페이스
        const bind_ip = if (std.mem.eql(u8, self.host, "localhost")) "127.0.0.1" else self.host;
        // **critical**: host parse / listen fail 은 dev server 가 출발 자체 못 함 —
        // quiet 와 무관하게 항상 stderr. NAPI 가 host=어디 port=얼마로 실패했는지
        // 진단 못 보면 caller 가 환경 문제 (port 사용 중 등) 추적 불가.
        const address = std.net.Address.parseIp4(bind_ip, self.port) catch {
            getLog().print("zntc: invalid host address: {s}\n", .{self.host}) catch {};
            return error.InvalidAddress;
        };
        self.tcp_server = address.listen(.{
            .reuse_address = true,
        }) catch |err| {
            getLog().print("zntc: failed to listen on {s}:{d}: {}\n", .{ self.host, self.port, err }) catch {};
            return err;
        };

        // port 0 (OS-assigned ephemeral) 였으면 실제 bound port 로 self.port 갱신
        // — caller (NAPI getDevServerPort 등) 가 실 값 조회 가능.
        if (self.tcp_server) |s| {
            self.port = s.listen_address.getPort();
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

        // entry가 있으면 watch 스레드 시작
        if (self.abs_entry != null) {
            const watch_thread = std.Thread.spawn(.{}, watchLoop, .{self}) catch |err| {
                // **critical**: watch thread spawn fail — HMR / file watch 자체 안 됨.
                // 사용자가 진단 봐야 함. quiet 와 무관 stderr.
                getLog().print("zntc: failed to start watch thread: {}\n", .{err}) catch {};
                return err;
            };
            watch_thread.detach();
        }

        self.acceptLoop();
    }

    /// HTTP 프록시: 클라이언트 요청을 백엔드 서버로 전달 (헤더+바디 포함)
    fn handleProxy(self: *DevServer, request: *http.Server.Request, rule: ProxyRule) !void {
        const allocator = self.allocator;

        const address = std.net.Address.parseIp4(rule.target_host, rule.target_port) catch
            return error.InvalidAddress;
        const backend = std.net.tcpConnectToAddress(address) catch
            return error.ConnectionRefused;
        defer backend.close();

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

        try backend.writeAll(req.items);

        // 백엔드 응답 읽기 (힙 할당, 동적 크기)
        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(allocator);

        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = backend.read(&read_buf) catch break;
            if (n == 0) break;
            try response.appendSlice(allocator, read_buf[0..n]);
        }

        if (response.items.len == 0) return error.EmptyResponse;

        // HTTP 응답 파싱: 헤더에서 Content-Type 추출 + 바디 분리
        const header_end = std.mem.indexOf(u8, response.items, "\r\n\r\n");
        if (header_end) |pos| {
            const body = response.items[pos + 4 ..];
            const headers_section = response.items[0..pos];
            var content_type: []const u8 = "application/json";
            var line_iter = std.mem.splitSequence(u8, headers_section, "\r\n");
            while (line_iter.next()) |line| {
                if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
                    content_type = std.mem.trimLeft(u8, line["content-type:".len..], " ");
                    break;
                }
            }

            const proxy_headers = cors_headers ++ [_]http.Header{
                .{ .name = "Content-Type", .value = content_type },
            };
            try request.respond(body, .{ .extra_headers = &proxy_headers });
        } else {
            try request.respond(response.items, .{ .extra_headers = &cors_headers });
        }
    }

    fn openBrowser(self: *DevServer) void {
        const scheme: []const u8 = if (self.tls_ctx != null) "https" else "http";
        const url_buf = std.fmt.allocPrint(self.allocator, "{s}://{s}:{d}/", .{ scheme, self.host, self.port }) catch return;
        defer self.allocator.free(url_buf);
        // macOS: open, Linux: xdg-open
        var child = std.process.Child.init(
            &.{ "open", url_buf },
            self.allocator,
        );
        child.spawn() catch {
            // Linux fallback
            var child2 = std.process.Child.init(
                &.{ "xdg-open", url_buf },
                self.allocator,
            );
            child2.spawn() catch {};
        };
    }

    fn acceptLoop(self: *DevServer) void {
        while (true) {
            if (self.shutdown_requested.load(.acquire)) return;
            const connection = self.tcp_server.?.accept() catch |err| {
                if (self.shutdown_requested.load(.acquire)) return;
                self.routineLog("zntc: accept failed: {}\n", .{err});
                continue;
            };
            // active_connections 를 spawn 전에 증가 — handleConnection 의 fetchAdd 가
            // OS scheduler 지연으로 늦게 실행되면 deinit 의 wait loop 가 counter=0 으로
            // 보고 일찍 통과 → UAF race window. 여기서 카운트 ownership 잡고 spawn
            // 실패 시만 즉시 감소. 성공 시 handleConnection 의 defer fetchSub 가 처리.
            _ = self.active_connections.fetchAdd(1, .acq_rel);
            const thread = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, handleConnection, .{ self, connection }) catch {
                _ = self.active_connections.fetchSub(1, .acq_rel);
                connection.stream.close();
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
        if (self.tcp_server) |*s| {
            const addr = s.listen_address;
            const stream = std.net.tcpConnectToAddress(addr) catch return;
            stream.close();
        }
    }

    fn handleConnection(self: *DevServer, connection: std.net.Server.Connection) void {
        // active_connections 의 fetchAdd 는 acceptLoop 가 이미 수행 (spawn 전 race
        // window 회피). 여기선 defer 로 fetchSub 만 — handleConnection 종료 시 한 번.
        defer _ = self.active_connections.fetchSub(1, .acq_rel);
        defer connection.stream.close();

        var send_buf: [8192]u8 = undefined;
        // recv_buf: 32KB stack alloc — typical HTTP request header + body 가 다 fit.
        // 이전 256KB heap 은 SSE/HMR WS 같은 long-lived connection 의 entire lifetime
        // 점유 → 100 tab × 2 connection × 256KB = 25MB unused 메모리 burden. 32KB
        // stack alloc 으로 memory 8× 절감 (32KB × 100 = 3.2MB) + heap alloc OOM 위험
        // 제거. 32KB 초과 single-frame 은 readSmallMessage 가 MessageTooBig.
        var recv_buf: [32 * 1024]u8 = undefined;

        if (self.tls_ctx) |*ctx| {
            // HTTPS path — SSL_accept handshake 후 TlsReader/TlsWriter 어댑터로 http.Server.
            var tls_conn = tls.TlsConnection.init(ctx, connection.stream.handle) catch |err| {
                self.routineLog("zntc: TLS handshake failed: {}\n", .{err});
                return;
            };
            defer tls_conn.deinit();

            var tls_reader = tls_conn.reader(&recv_buf);
            var tls_writer = tls_conn.writer(&send_buf);
            var server: http.Server = .init(&tls_reader.interface, &tls_writer.interface);
            self.serveOnConnection(&server, &tls_writer.interface);
        } else {
            // plain HTTP path.
            var conn_reader = connection.stream.reader(&recv_buf);
            var conn_writer = connection.stream.writer(&send_buf);
            var server: http.Server = .init(conn_reader.interface(), &conn_writer.interface);
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
        self.ws_clients.add(writer);
        defer self.ws_clients.remove(writer);

        ws.writeMessage("{\"type\":\"connected\"}", .text) catch {
            self.routineLog("  [ws] failed to send connected message\n", .{});
            return;
        };
        self.error_state.sendIfPresent(writer);

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
        const initial = inc_bundler.rebuild() catch return;
        var fallback_paths = [_][]const u8{abs_entry};
        const initial_paths: []const []const u8 = switch (initial) {
            .success => |r| r.paths,
            .build_error => |err_msg| blk: {
                self.error_state.setOwned(self.allocator, err_msg);
                break :blk fallback_paths[0..];
            },
            .fatal => return,
        };

        // OS 네이티브 파일 감시 (kqueue/inotify, 미지원 OS는 mtime 폴백)
        var watcher = FileWatcher.init(self.allocator) catch return;
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
        const root_real = std.fs.cwd().realpathAlloc(self.allocator, self.root_path) catch null;
        defer if (root_real) |r| self.allocator.free(r);
        if (root_real) |root| {
            collectCssFiles(self.allocator, self.root_dir, root, &css_paths);
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
        var css_path_set = std.StringHashMap(void).init(self.allocator);
        defer css_path_set.deinit();
        for (css_paths.items) |p| css_path_set.put(p, {}) catch {};

        self.routineLog("  [watch] watching {d} files for changes...\n", .{watcher.watchCount()});

        while (true) {
            const events = watcher.waitForChanges(watch_interval_ms) catch continue;

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
            var changed_set = std.StringHashMap(void).init(self.allocator);
            defer changed_set.deinit();
            var needs_rescan = false;
            for (events) |ev| {
                self.routineLog("  [watch] changed: {s}\n", .{std.fs.path.basename(ev.path)});
                if (root_real) |root| {
                    if (std.mem.eql(u8, ev.path, root)) {
                        needs_rescan = true;
                        continue; // dir entry event 는 changed_paths 에 넣지 않음 (caller 가 file path 만 처리).
                    }
                }
                const gop = changed_set.getOrPut(ev.path) catch continue;
                if (gop.found_existing) continue; // dedup
                changed_paths.append(self.allocator, ev.path) catch {};

                // SSE: watch_change 이벤트
                var ev_buf: [1024]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&ev_buf);
                const w = fbs.writer();
                w.writeAll("{\"type\":\"watch_change\",\"file\":\"") catch continue;
                writeJsonEscaped(w, ev.path) catch continue;
                w.writeAll("\"}") catch continue;
                self.publishEvent(EventType.watch_change, fbs.getWritten());
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
                collectCssFiles(self.allocator, self.root_dir, root, &new_css_paths);

                // new_css_paths set 으로 빠른 lookup
                var new_set = std.StringHashMap(void).init(self.allocator);
                defer new_set.deinit();
                for (new_css_paths.items) |p| new_set.put(p, {}) catch {};

                // (a) 신규 path detect — new_set 에 있으나 css_path_set 에 없음
                for (new_css_paths.items) |p| {
                    if (css_path_set.contains(p)) continue;
                    const path_owned = self.allocator.dupe(u8, p) catch continue;
                    css_paths.append(self.allocator, path_owned) catch {
                        self.allocator.free(path_owned);
                        continue;
                    };
                    css_path_set.put(path_owned, {}) catch {};
                    watcher.addPath(path_owned) catch {};
                    // synthetic event — caller 가 css-update broadcast 트리거하도록
                    if (changed_set.getOrPut(path_owned) catch null) |gop| {
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
                    if (changed_set.getOrPut(path_dupe) catch null) |gop| {
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
                    self.ws_clients.broadcast(css_msg);
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

            // 증분 재번들: 변경된 모듈만 diff하여 전송
            const build_start_ns = std.time.nanoTimestamp();
            const rebuild_result = inc_bundler.rebuild() catch continue;
            const build_duration_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - build_start_ns)) / std.time.ns_per_ms;
            switch (rebuild_result) {
                .success => |result| {
                    self.error_state.clear(self.allocator);
                    self.ws_clients.broadcast("{\"type\":\"clear-error\"}");

                    // bundle_build_done 이벤트
                    var done_buf: [256]u8 = undefined;
                    if (std.fmt.bufPrint(&done_buf, "{{\"type\":\"bundle_build_done\",\"id\":\"{d}\",\"totalModules\":{d},\"duration\":{d:.2}}}", .{ build_id, result.paths.len, build_duration_ms })) |json| {
                        self.publishEvent(EventType.bundle_build_done, json);
                    } else |_| {}

                    if (result.graph_changed) {
                        // 그래프 구조 변경 → full-reload (새 import 추가 등)
                        self.ws_clients.broadcast("{\"type\":\"full-reload\"}");
                        self.routineLog("  [hmr] graph changed, full-reload\n", .{});
                    } else if (result.changed_modules.len > 0) {
                        // 변경 모듈만 HMR update
                        self.ws_clients.broadcast("{\"type\":\"update-start\"}");
                        const hmr_msg = buildHmrUpdateFromModules(
                            self.allocator,
                            result.changed_modules,
                        );
                        if (hmr_msg) |msg| {
                            defer self.allocator.free(msg);
                            self.ws_clients.broadcast(msg);
                            self.routineLog("  [hmr] incremental update ({d} modules)\n", .{result.changed_modules.len});
                        } else {
                            self.ws_clients.broadcast("{\"type\":\"full-reload\"}");
                        }
                        self.ws_clients.broadcast("{\"type\":\"update-done\"}");
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
                    self.error_state.setCopy(self.allocator, err_msg) catch {};
                    self.ws_clients.broadcast(err_msg);
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

        var msg: std.ArrayList(u8) = .empty;
        errdefer msg.deinit(allocator);
        const w = msg.writer(allocator);

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
        return msg.toOwnedSlice(allocator) catch return null;
    }

    /// root_dir에서 .css 파일을 재귀 탐색하여 절대 경로 목록에 추가.
    fn collectCssFiles(allocator: std.mem.Allocator, dir: std.fs.Dir, dir_path: []const u8, out: *std.ArrayList([]const u8)) void {
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory) {
                if (std.mem.eql(u8, entry.name, "node_modules")) continue;
                if (entry.name.len > 0 and entry.name[0] == '.') continue;
                var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close();
                const sub_path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch continue;
                defer allocator.free(sub_path);
                collectCssFiles(allocator, sub_dir, sub_path, out);
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
        self.sse_clients.add(&sink);
        defer self.sse_clients.remove(&sink);

        // keep-alive: 30초마다 주석 전송. broadcast와 race 방지를 위해 sink mutex 사용.
        while (true) {
            std.Thread.sleep(30 * std.time.ns_per_s);
            self.sse_clients.mutex.lock();
            const ok = blk: {
                response.writer.writeAll(": keep-alive\n\n") catch break :blk false;
                response.writer.flush() catch break :blk false;
                response.flush() catch break :blk false;
                break :blk true;
            };
            self.sse_clients.mutex.unlock();
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
        self.sse_clients.broadcast(event_type, data_json);
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

        var result = try bundler.bundle();
        defer result.deinit(self.allocator);

        if (result.hasErrors()) {
            const diags = result.getDiagnostics();
            if (buildErrorJsonFromDiagnostics(self.allocator, diags)) |err_json| {
                defer self.allocator.free(err_json);
                self.error_state.setCopy(self.allocator, err_json) catch {};
                self.ws_clients.broadcast(err_json);
            } else |_| {}

            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(self.allocator);
            const w = msg.writer(self.allocator);
            try w.print("// ZNTC Bundle Error\n", .{});
            for (diags) |d| {
                try w.print("// [{s}] {s}: {s}\n", .{
                    @tagName(d.severity),
                    d.file_path,
                    d.message,
                });
            }
            try w.print("console.error('ZNTC: bundle failed, see server logs');\n", .{});

            try request.respond(msg.items, .{
                .status = .internal_server_error,
                .extra_headers = &js_headers,
            });

            self.routineLog("  500 {s} (bundle errors)\n", .{abs_entry});
            return;
        }
        self.error_state.clear(self.allocator);
        self.ws_clients.broadcast("{\"type\":\"clear-error\"}");

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
        const runtime_code = self.root_dir.readFileAlloc(
            self.allocator,
            "node_modules/react-refresh/runtime.js",
            max_file_size,
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
        const file = try self.root_dir.openFile(rel_path, .{});
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, max_file_size) catch |err| switch (err) {
            error.FileTooBig => {
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

test "collectCssFiles: .css만 수집하고 .js는 제외" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // tmpDir 생성
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // .css 파일 2개 + .js 파일 1개 생성
    tmp.dir.writeFile(.{ .sub_path = "a.css", .data = "" }) catch return error.TestUnexpectedResult;
    tmp.dir.writeFile(.{ .sub_path = "b.css", .data = "" }) catch return error.TestUnexpectedResult;
    tmp.dir.writeFile(.{ .sub_path = "c.js", .data = "" }) catch return error.TestUnexpectedResult;

    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    DevServer.collectCssFiles(allocator, tmp.dir, "/root", &out);

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
    tmp.dir.writeFile(.{ .sub_path = "style.css", .data = "" }) catch return error.TestUnexpectedResult;

    // node_modules/ 하위 .css — 제외되어야 함
    tmp.dir.makePath("node_modules/pkg") catch return error.TestUnexpectedResult;
    tmp.dir.writeFile(.{ .sub_path = "node_modules/pkg/lib.css", .data = "" }) catch return error.TestUnexpectedResult;

    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    DevServer.collectCssFiles(allocator, tmp.dir, "/root", &out);

    // node_modules 내 .css는 제외 → 1개만
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(std.mem.endsWith(u8, out.items[0], "style.css"));
}

test "collectCssFiles: 숨김 폴더(.git) 내 .css 제외" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    tmp.dir.writeFile(.{ .sub_path = "main.css", .data = "" }) catch return error.TestUnexpectedResult;

    // .git/ 하위 .css — 숨김 폴더이므로 제외되어야 함
    tmp.dir.makePath(".git/hooks") catch return error.TestUnexpectedResult;
    tmp.dir.writeFile(.{ .sub_path = ".git/hooks/style.css", .data = "" }) catch return error.TestUnexpectedResult;

    var out: std.ArrayList([]const u8) = .empty;
    defer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    DevServer.collectCssFiles(allocator, tmp.dir, "/root", &out);

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
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const result = DevServer.init(std.testing.allocator, .{
        .root_dir = dir_path,
        .cert_path = "/some/cert.pem",
        // key_path = null
    });
    try std.testing.expectError(error.TlsKeyMissing, result);
}

test "DevServer.init: key 만 set + cert 없음 → error.TlsKeyMissing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const result = DevServer.init(std.testing.allocator, .{
        .root_dir = dir_path,
        .key_path = "/some/key.pem",
        // cert_path = null
    });
    try std.testing.expectError(error.TlsKeyMissing, result);
}

test "DevServer.init: 둘 다 set + 존재하지 않는 파일 → CertLoadFailed (TlsContext init fail propagate)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    const result = DevServer.init(std.testing.allocator, .{
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
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var dev_server = try DevServer.init(std.testing.allocator, .{
        .root_dir = dir_path,
    });
    defer dev_server.deinit();
    try std.testing.expect(dev_server.tls_ctx == null);
}
