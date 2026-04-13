const std = @import("std");
const http = std.http;
const mime = @import("mime.zig");
const FileWatcher = @import("file_watcher.zig").FileWatcher;
const lib = @import("../root.zig");
const Bundler = lib.bundler.Bundler;
const BundleOptions = lib.bundler.BundleOptions;
const BundleResult = lib.bundler.BundleResult;
const IncrementalBundler = lib.bundler.IncrementalBundler;
const plugin_mod = lib.bundler.plugin;

fn getLog() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

/// WS 클라이언트 목록 — 여러 스레드에서 접근하므로 mutex로 보호
const WsClients = struct {
    mutex: std.Thread.Mutex = .{},
    /// WebSocket output writer 포인터 목록. handleWebSocket 스택에서 소유.
    items: [max_clients]*std.Io.Writer = undefined,
    len: usize = 0,

    const max_clients = 64;

    fn add(self: *WsClients, writer: *std.Io.Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len < max_clients) {
            self.items[self.len] = writer;
            self.len += 1;
        }
    }

    fn remove(self: *WsClients, writer: *std.Io.Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items[0..self.len], 0..) |item, i| {
            if (item == writer) {
                self.len -= 1;
                self.items[i] = self.items[self.len];
                return;
            }
        }
    }

    fn broadcast(self: *WsClients, data: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.len) {
            writeWsFrame(self.items[i], data) catch {
                // 전송 실패 → dead client 제거 (swap-remove)
                self.len -= 1;
                self.items[i] = self.items[self.len];
                continue;
            };
            i += 1;
        }
    }
};

/// 한 SSE 구독자 — `*std.Io.Writer`만 갖고는 chunked transfer-encoding의 chunk 종결을
/// underlying TCP까지 push할 수 없다. `body_writer`가 있으면 `BodyWriter.flush()`로
/// `http_protocol_output.flush()`까지 호출해 frame이 즉시 클라이언트에 도달.
/// 단위 테스트에서는 `body_writer = null`로 fixed buffer만 검증.
pub const SseSink = struct {
    writer: *std.Io.Writer,
    body_writer: ?*http.BodyWriter = null,

    fn writeFrame(self: *SseSink, event_type: []const u8, data_json: []const u8) !void {
        try self.writer.writeAll("event: ");
        try self.writer.writeAll(event_type);
        try self.writer.writeAll("\ndata: ");
        try self.writer.writeAll(data_json);
        try self.writer.writeAll("\n\n");
        // chunked encoding은 두 단계 flush 필요:
        // 1) writer.flush() — 버퍼를 chunk frame으로 인코딩하여 http_protocol_output에 push
        // 2) BodyWriter.flush() — http_protocol_output을 TCP로 push
        try self.writer.flush();
        if (self.body_writer) |bw| try bw.flush();
    }
};

/// SSE 클라이언트 목록 — `/sse/events`로 연결된 long-lived HTTP 응답 sink들.
/// WS와 병렬 운영; 빌드 이벤트는 SSE로 전송 (HMR은 WS 유지).
const SseClients = struct {
    mutex: std.Thread.Mutex = .{},
    items: [max_clients]*SseSink = undefined,
    len: usize = 0,

    const max_clients = 64;

    fn add(self: *SseClients, sink: *SseSink) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len < max_clients) {
            self.items[self.len] = sink;
            self.len += 1;
        }
    }

    fn remove(self: *SseClients, sink: *SseSink) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.items[0..self.len], 0..) |item, i| {
            if (item == sink) {
                self.len -= 1;
                self.items[i] = self.items[self.len];
                return;
            }
        }
    }

    /// `event: <type>\ndata: <json>\n\n` 형식으로 모든 구독자에 브로드캐스트.
    /// keep-alive 핸들러와 broadcast가 같은 sink를 동시 write하지 않도록 mutex로 직렬화.
    fn broadcast(self: *SseClients, event_type: []const u8, data_json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.len) {
            self.items[i].writeFrame(event_type, data_json) catch {
                self.len -= 1;
                self.items[i] = self.items[self.len];
                continue;
            };
            i += 1;
        }
    }
};

/// SSE 이벤트 타입 이름. publishEvent 호출부와 외부 소비자가 공유하는 단일 출처.
pub const EventType = struct {
    pub const server_ready = "server_ready";
    pub const watch_change = "watch_change";
    pub const bundle_build_started = "bundle_build_started";
    pub const bundle_build_done = "bundle_build_done";
    pub const bundle_build_failed = "bundle_build_failed";
    pub const cache_reset = "cache_reset";
};

/// 최근 이벤트 순환 버퍼 — MCP `get_build_events`에서 특정 시점 이후 이벤트 조회에 사용.
/// 고정 용량; 오래된 엔트리는 덮어쓰임. `seq`로 이벤트 순서 추적.
const EventRing = struct {
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    items: [capacity]Record = undefined,
    /// 다음 쓰기 위치 (`items[head % capacity]`).
    head: u64 = 0,

    const capacity: usize = 256;

    const Record = struct {
        seq: u64,
        event_type: []const u8, // owned
        data_json: []const u8, // owned
    };

    fn init(allocator: std.mem.Allocator) EventRing {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *EventRing) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(self.head, capacity);
        for (self.items[0..count]) |*r| {
            self.allocator.free(r.event_type);
            self.allocator.free(r.data_json);
        }
    }

    fn push(self: *EventRing, seq: u64, event_type: []const u8, data_json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const idx = self.head % capacity;
        if (self.head >= capacity) {
            self.allocator.free(self.items[idx].event_type);
            self.allocator.free(self.items[idx].data_json);
        }
        const t_dup = self.allocator.dupe(u8, event_type) catch return;
        const d_dup = self.allocator.dupe(u8, data_json) catch {
            self.allocator.free(t_dup);
            return;
        };
        self.items[idx] = .{ .seq = seq, .event_type = t_dup, .data_json = d_dup };
        self.head += 1;
    }

    /// `since_seq` 이후 이벤트들을 복사해 반환. caller가 free.
    fn snapshotSince(self: *EventRing, alloc: std.mem.Allocator, since_seq: u64) ![]Record {
        self.mutex.lock();
        defer self.mutex.unlock();
        const total = self.head;
        const start = if (total > capacity) total - capacity else 0;
        var out: std.ArrayList(Record) = .empty;
        errdefer {
            for (out.items) |r| {
                alloc.free(r.event_type);
                alloc.free(r.data_json);
            }
            out.deinit(alloc);
        }
        var i: u64 = start;
        while (i < total) : (i += 1) {
            const src = self.items[i % capacity];
            if (src.seq <= since_seq) continue;
            try out.append(alloc, .{
                .seq = src.seq,
                .event_type = try alloc.dupe(u8, src.event_type),
                .data_json = try alloc.dupe(u8, src.data_json),
            });
        }
        return try out.toOwnedSlice(alloc);
    }
};

/// WebSocket text frame을 직접 인코딩하여 writer에 쓴다.
/// std.http.Server.WebSocket.writeMessage와 동일한 형식이지만,
/// WebSocket 구조체 없이 raw writer로 전송할 수 있다.
fn writeWsFrame(writer: *std.Io.Writer, data: []const u8) !void {
    // FIN=1, opcode=text(1)
    try writer.writeByte(0x81);
    // payload length (mask=0, server→client이므로 mask 불필요)
    if (data.len < 126) {
        try writer.writeByte(@intCast(data.len));
    } else if (data.len <= 65535) {
        try writer.writeByte(126);
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(data.len))));
    } else {
        try writer.writeByte(127);
        try writer.writeAll(&std.mem.toBytes(std.mem.nativeToBig(u64, @intCast(data.len))));
    }
    try writer.writeAll(data);
    try writer.flush();
}

/// JSON 문자열 값 내부의 특수 문자를 이스케이프한다.
fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.print("\\\"", .{}),
            '\\' => try w.print("\\\\", .{}),
            '\n' => try w.print("\\n", .{}),
            '\r' => try w.print("\\r", .{}),
            '\t' => try w.print("\\t", .{}),
            else => try w.writeByte(c),
        }
    }
}

/// 임의의 std.json.Value를 JSON으로 직렬화 (MCP `id` 필드용 — string/integer/null만).
fn writeJsonValue(w: anytype, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| {
            try w.writeByte('"');
            try writeJsonEscaped(w, s);
            try w.writeByte('"');
        },
        else => try w.writeAll("null"),
    }
}

pub const DevServer = struct {
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    root_path: []const u8,
    port: u16,
    host: []const u8,
    open: bool,
    tcp_server: ?std.net.Server,
    entry_point: ?[]const u8,
    abs_entry: ?[]const u8,
    ws_clients: WsClients = .{},
    sse_clients: SseClients = .{},
    /// 모노토닉 이벤트 시퀀스 (SSE payload의 id 필드).
    event_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Control API `/reset-cache`가 설정; watchLoop가 다음 iteration에서 소비.
    cache_reset_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// MCP `get_build_events` 도구용 이벤트 히스토리 (최근 N개).
    event_ring: EventRing,
    /// shutdown() 호출 시 set; acceptLoop가 다음 iteration에서 종료.
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    plugins: []const plugin_mod.Plugin = &.{},
    proxy: []const ProxyRule = &.{},
    sourcemap_cache: struct {
        mutex: std.Thread.Mutex = .{},
        data: ?[]const u8 = null,
    } = .{},

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
    };

    const max_file_size: u64 = 50 * 1024 * 1024;
    const bundle_path = "/bundle.js";
    const hmr_path = "/__hmr";
    const watch_interval_ms = 500;

    const js_headers = cors_headers ++ [_]http.Header{
        .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
    };

    const html_headers = cors_headers ++ [_]http.Header{
        .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !DevServer {
        const root_dir = std.fs.cwd().openDir(options.root_dir, .{ .iterate = true }) catch |err| {
            getLog().print("zts: cannot open directory '{s}': {}\n", .{ options.root_dir, err }) catch {};
            return err;
        };

        var abs_entry: ?[]const u8 = null;
        if (options.entry_point) |ep| {
            abs_entry = std.fs.cwd().realpathAlloc(allocator, ep) catch |err| {
                getLog().print("zts: cannot resolve entry '{s}': {}\n", .{ ep, err }) catch {};
                var dir_copy = root_dir;
                dir_copy.close();
                return err;
            };
        }

        return .{
            .allocator = allocator,
            .root_dir = root_dir,
            .root_path = options.root_dir,
            .port = options.port,
            .host = options.host,
            .open = options.open,
            .tcp_server = null,
            .entry_point = options.entry_point,
            .abs_entry = abs_entry,
            .plugins = options.plugins,
            .proxy = options.proxy,
            .event_ring = EventRing.init(allocator),
        };
    }

    pub fn deinit(self: *DevServer) void {
        if (self.tcp_server) |*s| s.deinit();
        if (self.abs_entry) |ae| self.allocator.free(ae);
        self.root_dir.close();
        self.event_ring.deinit();
    }

    pub fn start(self: *DevServer) !void {
        // host 바인딩: "localhost" → 127.0.0.1, "0.0.0.0" → 모든 인터페이스
        const bind_ip = if (std.mem.eql(u8, self.host, "localhost")) "127.0.0.1" else self.host;
        const address = std.net.Address.parseIp4(bind_ip, self.port) catch {
            getLog().print("zts: invalid host address: {s}\n", .{self.host}) catch {};
            return error.InvalidAddress;
        };
        self.tcp_server = address.listen(.{
            .reuse_address = true,
        }) catch |err| {
            getLog().print("zts: failed to listen on {s}:{d}: {}\n", .{ self.host, self.port, err }) catch {};
            return err;
        };

        const w = getLog();
        w.print("\n  zts dev server\n\n", .{}) catch {};
        w.print("  Local: http://{s}:{d}/\n", .{ self.host, self.port }) catch {};
        if (std.mem.eql(u8, self.host, "0.0.0.0")) {
            w.print("  Network: http://0.0.0.0:{d}/\n", .{self.port}) catch {};
        }
        w.print("  Root:  {s}\n", .{self.root_path}) catch {};
        if (self.entry_point) |ep| {
            w.print("  Entry: {s}\n", .{ep}) catch {};
        }
        w.print("\n", .{}) catch {};

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
                getLog().print("zts: failed to start watch thread: {}\n", .{err}) catch {};
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
        const url_buf = std.fmt.allocPrint(self.allocator, "http://{s}:{d}/", .{ self.host, self.port }) catch return;
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
                getLog().print("zts: accept failed: {}\n", .{err}) catch {};
                continue;
            };
            const thread = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, handleConnection, .{ self, connection }) catch {
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
        defer connection.stream.close();

        var send_buf: [8192]u8 = undefined;
        var recv_buf: [8192]u8 = undefined;
        var conn_reader = connection.stream.reader(&recv_buf);
        var conn_writer = connection.stream.writer(&send_buf);
        var server: http.Server = .init(conn_reader.interface(), &conn_writer.interface);

        while (true) {
            var request = server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => return,
                else => {
                    getLog().print("zts: receiveHead failed: {}\n", .{err}) catch {};
                    return;
                },
            };

            switch (request.upgradeRequested()) {
                .websocket => |opt_key| {
                    const key = opt_key orelse {
                        getLog().print("zts: WebSocket upgrade missing key\n", .{}) catch {};
                        return;
                    };

                    // /__hmr 경로에서만 WebSocket 허용
                    const target = request.head.target;
                    const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
                    if (!std.mem.eql(u8, target[0..path_end], hmr_path)) {
                        request.respond("400 Bad Request", .{
                            .status = .bad_request,
                            .extra_headers = &cors_headers,
                        }) catch {};
                        return;
                    }

                    var ws = request.respondWebSocket(.{ .key = key }) catch {
                        getLog().print("zts: WebSocket handshake failed\n", .{}) catch {};
                        return;
                    };
                    self.handleWebSocket(&ws, &conn_writer.interface);
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
                getLog().print("zts: request '{s}' failed: {}\n", .{ request.head.target, err }) catch {};
                return;
            };
        }
    }

    fn handleWebSocket(self: *DevServer, ws: *http.Server.WebSocket, writer: *std.Io.Writer) void {
        getLog().print("  [ws] client connected\n", .{}) catch {};

        // broadcast 리스트에 등록
        self.ws_clients.add(writer);
        defer self.ws_clients.remove(writer);

        ws.writeMessage("{\"type\":\"connected\"}", .text) catch {
            getLog().print("  [ws] failed to send connected message\n", .{}) catch {};
            return;
        };

        // 클라이언트 메시지 수신 루프 (ping/pong은 std.http가 자동 처리)
        while (true) {
            const msg = ws.readSmallMessage() catch |err| {
                switch (err) {
                    error.ConnectionClose => {},
                    else => getLog().print("  [ws] read error: {}\n", .{err}) catch {},
                }
                break;
            };

            switch (msg.opcode) {
                .text => {
                    getLog().print("  [ws] recv: {s}\n", .{msg.data}) catch {};
                },
                .connection_close => break,
                else => {},
            }
        }

        getLog().print("  [ws] client disconnected\n", .{}) catch {};
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
        });
        defer inc_bundler.deinit();

        // 초기 번들
        const initial = inc_bundler.rebuild() catch return;
        const initial_paths: []const []const u8 = switch (initial) {
            .success => |r| r.paths,
            .build_error => |err_msg| {
                self.allocator.free(err_msg);
                return;
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
        }
        for (css_paths.items) |p| {
            watcher.addPath(p) catch {};
        }

        getLog().print("  [watch] watching {d} files for changes...\n", .{watcher.watchCount()}) catch {};

        while (true) {
            const events = watcher.waitForChanges(watch_interval_ms) catch continue;

            // Control API 경유 캐시 리셋 요청 처리 — 파일 변경 없어도 다음 rebuild를 전체 빌드로.
            if (self.cache_reset_requested.swap(false, .acquire)) {
                inc_bundler.reset();
                self.publishEvent(EventType.cache_reset, "{\"type\":\"cache_reset\"}");
                getLog().print("  [ctrl] cache reset via /reset-cache\n", .{}) catch {};
            }

            if (events.len == 0) continue;

            var changed_paths: std.ArrayList([]const u8) = .empty;
            defer changed_paths.deinit(self.allocator);
            for (events) |ev| {
                getLog().print("  [watch] changed: {s}\n", .{std.fs.path.basename(ev.path)}) catch {};
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
                    getLog().print("  [hmr] css update: {s}\n", .{std.fs.path.basename(cp)}) catch {};
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
            const build_id = self.event_seq.load(.monotonic);
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
                    // bundle_build_done 이벤트
                    var done_buf: [256]u8 = undefined;
                    if (std.fmt.bufPrint(&done_buf, "{{\"type\":\"bundle_build_done\",\"id\":\"{d}\",\"totalModules\":{d},\"duration\":{d:.2}}}", .{ build_id, result.paths.len, build_duration_ms })) |json| {
                        self.publishEvent(EventType.bundle_build_done, json);
                    } else |_| {}

                    if (result.graph_changed) {
                        // 그래프 구조 변경 → full-reload (새 import 추가 등)
                        self.ws_clients.broadcast("{\"type\":\"full-reload\"}");
                        getLog().print("  [hmr] graph changed, full-reload\n", .{}) catch {};
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
                            getLog().print("  [hmr] incremental update ({d} modules)\n", .{result.changed_modules.len}) catch {};
                        } else {
                            self.ws_clients.broadcast("{\"type\":\"full-reload\"}");
                        }
                        self.ws_clients.broadcast("{\"type\":\"update-done\"}");
                    } else {
                        // 코드 diff 없음 (타입만 변경 등) → Vite와 동일하게 무시
                        getLog().print("  [hmr] no code change, skipping\n", .{}) catch {};
                    }

                    // free changed_modules
                    if (result.changed_modules.len > 0) {
                        self.allocator.free(result.changed_modules);
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
                    getLog().print("  [watch] watching {d} files for changes...\n", .{watcher.watchCount()}) catch {};
                },
                .build_error => |err_msg| {
                    defer self.allocator.free(err_msg);
                    self.ws_clients.broadcast(err_msg);
                    getLog().print("  [watch] build error, overlay sent\n", .{}) catch {};

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

    /// MCP (Model Context Protocol) JSON-RPC 2.0 엔드포인트.
    /// 지원 method: initialize, tools/list, tools/call (reset_cache, get_build_events).
    fn handleMcp(self: *DevServer, request: *http.Server.Request) !void {
        if (request.head.method != .POST) {
            request.respond("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Use POST\"},\"id\":null}", .{
                .status = .method_not_allowed,
                .extra_headers = &json_headers,
            }) catch {};
            return;
        }

        // 요청 body 읽기 — Content-Length를 먼저 보고 64KB 초과 시 즉시 413.
        const max_body = 64 * 1024;
        if (request.head.content_length) |cl| {
            if (cl > max_body) {
                request.respond("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Request body too large (max 64KB)\"},\"id\":null}", .{
                    .status = .payload_too_large,
                    .extra_headers = &json_headers,
                }) catch {};
                return;
            }
        }
        const reader = request.readerExpectContinue(&.{}) catch |err| {
            getLog().print("  [mcp] body reader error: {}\n", .{err}) catch {};
            return;
        };
        var body_buf: [max_body + 1]u8 = undefined;
        var body_writer = std.Io.Writer.fixed(&body_buf);
        _ = reader.streamRemaining(&body_writer) catch |err| {
            if (body_writer.end > max_body) {
                request.respond("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Request body too large (max 64KB)\"},\"id\":null}", .{
                    .status = .payload_too_large,
                    .extra_headers = &json_headers,
                }) catch {};
                return;
            }
            getLog().print("  [mcp] body read error: {}\n", .{err}) catch {};
            return;
        };
        const body_len = body_writer.end;
        if (body_len > max_body) {
            request.respond("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Request body too large (max 64KB)\"},\"id\":null}", .{
                .status = .payload_too_large,
                .extra_headers = &json_headers,
            }) catch {};
            return;
        }
        const body = body_buf[0..body_len];

        // JSON 파싱
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            request.respond("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32700,\"message\":\"Parse error\"},\"id\":null}", .{
                .status = .ok,
                .extra_headers = &json_headers,
            }) catch {};
            return;
        };
        defer parsed.deinit();
        const root = parsed.value;

        const method = switch (root) {
            .object => |o| switch (o.get("method") orelse .null) {
                .string => |s| s,
                else => "",
            },
            else => "",
        };
        const id_val: std.json.Value = switch (root) {
            .object => |o| o.get("id") orelse .null,
            else => .null,
        };

        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(self.allocator);
        const w = resp.writer(self.allocator);

        try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
        try writeJsonValue(w, id_val);
        try w.writeAll(",");

        if (std.mem.eql(u8, method, "initialize")) {
            try w.writeAll(
                \\"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"zts-dev-server","version":"0.1.0"}}
            );
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try w.writeAll(
                \\"result":{"tools":[
                \\{"name":"reset_cache","description":"Clear the build cache. Next build will be a full rebuild.","inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
                \\{"name":"get_build_events","description":"Subscribe to bundler events for a duration and return collected events.","inputSchema":{"type":"object","properties":{"duration":{"type":"number","minimum":1000,"maximum":60000,"default":10000,"description":"milliseconds to listen"}},"additionalProperties":false}}
                \\]}
            );
        } else if (std.mem.eql(u8, method, "tools/call")) {
            try self.handleToolsCall(w, root);
        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
            // MCP 클라이언트 initialized 통지는 응답 없음 (notification)
            try w.writeAll("\"result\":{}");
        } else {
            try w.writeAll("\"error\":{\"code\":-32601,\"message\":\"Method not found\"}");
        }
        try w.writeAll("}");

        request.respond(resp.items, .{
            .status = .ok,
            .extra_headers = &json_headers,
        }) catch {};
    }

    fn handleToolsCall(self: *DevServer, w: anytype, root: std.json.Value) !void {
        const params: std.json.Value = switch (root) {
            .object => |o| o.get("params") orelse .null,
            else => .null,
        };
        const tool_name: []const u8 = switch (params) {
            .object => |o| switch (o.get("name") orelse .null) {
                .string => |s| s,
                else => "",
            },
            else => "",
        };
        const args: std.json.Value = switch (params) {
            .object => |o| o.get("arguments") orelse .null,
            else => .null,
        };

        if (std.mem.eql(u8, tool_name, "reset_cache")) {
            self.cache_reset_requested.store(true, .release);
            try w.writeAll(
                \\"result":{"content":[{"type":"text","text":"Cache reset requested; next build will be a full rebuild."}]}
            );
            return;
        }

        if (std.mem.eql(u8, tool_name, "get_build_events")) {
            var duration_ms: u64 = 10_000;
            switch (args) {
                .object => |o| switch (o.get("duration") orelse .null) {
                    .integer => |n| duration_ms = @intCast(@max(1000, @min(60000, n))),
                    .float => |f| duration_ms = @intFromFloat(@max(1000.0, @min(60000.0, f))),
                    else => {},
                },
                else => {},
            }
            const start_seq = self.event_seq.load(.monotonic);
            std.Thread.sleep(duration_ms * std.time.ns_per_ms);
            const records = self.event_ring.snapshotSince(self.allocator, start_seq) catch {
                try w.writeAll("\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"[]\"}]}");
                return;
            };
            defer {
                for (records) |r| {
                    self.allocator.free(r.event_type);
                    self.allocator.free(r.data_json);
                }
                self.allocator.free(records);
            }

            // 이벤트 JSON 배열을 별도 버퍼에 구축 (이중 이스케이프 회피)
            var inner: std.ArrayList(u8) = .empty;
            defer inner.deinit(self.allocator);
            const iw = inner.writer(self.allocator);
            try iw.writeAll("[");
            for (records, 0..) |r, i| {
                if (i > 0) try iw.writeAll(",");
                try std.fmt.format(iw, "{{\"seq\":{d},\"type\":\"", .{r.seq});
                try writeJsonEscaped(iw, r.event_type);
                try iw.writeAll("\",\"data\":");
                // data_json은 이미 JSON → 그대로 삽입
                try iw.writeAll(r.data_json);
                try iw.writeAll("}");
            }
            try iw.writeAll("]");

            try w.writeAll("\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"");
            try writeJsonEscaped(w, inner.items);
            try w.writeAll("\"}]}");
            return;
        }

        try w.writeAll("\"error\":{\"code\":-32602,\"message\":\"Unknown tool\"}");
    }

    /// 이벤트를 SSE 구독자 전원에 브로드캐스트.
    /// `data_json`은 유효한 JSON 오브젝트 문자열이어야 한다 (이스케이프 호출부 책임).
    pub fn publishEvent(self: *DevServer, event_type: []const u8, data_json: []const u8) void {
        const seq = self.event_seq.fetchAdd(1, .monotonic) + 1;
        self.event_ring.push(seq, event_type, data_json);
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

            // MCP JSON-RPC 서버 — POST /mcp
            if (std.mem.eql(u8, raw_path_early, "/mcp")) {
                self.handleMcp(request) catch |err| {
                    getLog().print("zts: /mcp handler error: {}\n", .{err}) catch {};
                    request.respond("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"Internal error\"},\"id\":null}", .{
                        .status = .ok,
                        .extra_headers = &json_headers,
                    }) catch {};
                };
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
        const raw_path = target[0..path_end];

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

            // /bundle.js.map — 캐시된 소스맵 반환
            if (std.mem.eql(u8, raw_path, "/bundle.js.map")) {
                self.serveSourceMap(request) catch {};
                return;
            }

            if (std.mem.eql(u8, raw_path, bundle_path)) {
                self.serveBundle(request) catch |err| {
                    getLog().print("zts: bundle failed: {}\n", .{err}) catch {};
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
        });
        defer bundler.deinit();

        var result = try bundler.bundle();
        defer result.deinit(self.allocator);

        if (result.hasErrors()) {
            const diags = result.getDiagnostics();
            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(self.allocator);
            const w = msg.writer(self.allocator);
            try w.print("// ZTS Bundle Error\n", .{});
            for (diags) |d| {
                try w.print("// [{s}] {s}: {s}\n", .{
                    @tagName(d.severity),
                    d.file_path,
                    d.message,
                });
            }
            try w.print("console.error('ZTS: bundle failed, see server logs');\n", .{});

            try request.respond(msg.items, .{
                .status = .internal_server_error,
                .extra_headers = &js_headers,
            });

            getLog().print("  500 {s} (bundle errors)\n", .{abs_entry}) catch {};
            return;
        }

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

        getLog().print("  200 {s} (bundled)\n", .{bundle_path}) catch {};
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
            getLog().print("  200 /bundle.js.map\n", .{}) catch {};
        } else {
            try request.respond("", .{
                .status = .not_found,
                .extra_headers = &cors_headers,
            });
        }
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
                getLog().print("  200 /@react-refresh (noop — not installed)\n", .{}) catch {};
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
        getLog().print("  200 /@react-refresh\n", .{}) catch {};
    }

    fn serveAutoHtml(_: *DevServer, request: *http.Server.Request) !void {
        const html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head><meta charset="utf-8"><title>ZTS Dev Server</title></head>
            \\<body>
            \\<div id="root"></div>
            \\<script src="/@react-refresh"></script>
            \\<script type="module" src="/bundle.js"></script>
            \\<script>
            \\(function() {
            \\  var ws, timer, overlay;
            \\  function showOverlay(errors) {
            \\    hideOverlay();
            \\    overlay = document.createElement('div');
            \\    overlay.id = 'zts-error-overlay';
            \\    overlay.style.cssText = 'position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.85);color:#ff5555;font-family:monospace;font-size:14px;padding:32px;box-sizing:border-box;z-index:99999;overflow:auto;white-space:pre-wrap;';
            \\    var wrap = document.createElement('div');
            \\    wrap.style.cssText = 'max-width:800px;margin:0 auto';
            \\    var h = document.createElement('h2');
            \\    h.style.cssText = 'color:#ff5555;margin:0 0 16px';
            \\    h.textContent = 'Build Error';
            \\    wrap.appendChild(h);
            \\    for (var i = 0; i < errors.length; i++) {
            \\      var card = document.createElement('div');
            \\      card.style.cssText = 'background:#1a1a1a;border:1px solid #ff5555;border-radius:4px;padding:16px;margin-bottom:12px';
            \\      var file = document.createElement('div');
            \\      file.style.cssText = 'color:#888;margin-bottom:8px';
            \\      file.textContent = errors[i].file;
            \\      var msg = document.createElement('div');
            \\      msg.style.cssText = 'color:#fff';
            \\      msg.textContent = errors[i].message;
            \\      card.appendChild(file);
            \\      card.appendChild(msg);
            \\      wrap.appendChild(card);
            \\    }
            \\    overlay.appendChild(wrap);
            \\    overlay.onclick = function() { hideOverlay(); };
            \\    document.body.appendChild(overlay);
            \\  }
            \\  function hideOverlay() {
            \\    if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
            \\    overlay = null;
            \\  }
            \\  function connect() {
            \\    ws = new WebSocket('ws://' + location.host + '/__hmr');
            \\    ws.onopen = function() { console.log('[zts] HMR connected'); };
            \\    ws.onmessage = function(e) {
            \\      var msg = JSON.parse(e.data);
            \\      if (msg.type === 'update-start' || msg.type === 'update-done') return;
            \\      if (msg.type === 'full-reload') { hideOverlay(); location.reload(); }
            \\      if (msg.type === 'update') {
            \\        if (typeof __zts_apply_update === 'function') {
            \\          hideOverlay();
            \\          __zts_apply_update(msg.modules);
            \\        } else { hideOverlay(); location.reload(); }
            \\      }
            \\      if (msg.type === 'css-update') {
            \\        var links = document.querySelectorAll('link[rel="stylesheet"]');
            \\        for (var j = 0; j < links.length; j++) {
            \\          var href = links[j].getAttribute('href');
            \\          if (href && href.split('?')[0] === msg.file) {
            \\            links[j].href = msg.file + '?t=' + Date.now();
            \\            console.log('[zts] CSS updated:', msg.file);
            \\          }
            \\        }
            \\      }
            \\      if (msg.type === 'error') { showOverlay(msg.errors); }
            \\    };
            \\    ws.onclose = function() {
            \\      console.log('[zts] HMR disconnected, reconnecting...');
            \\      clearTimeout(timer);
            \\      timer = setTimeout(connect, 1000);
            \\    };
            \\  }
            \\  connect();
            \\})();
            \\</script>
            \\</body>
            \\</html>
        ;

        try request.respond(html, .{
            .extra_headers = &html_headers,
        });

        getLog().print("  200 / (auto html)\n", .{}) catch {};
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

        try request.respond(content, .{
            .extra_headers = &headers,
        });

        getLog().print("  200 {s}\n", .{rel_path}) catch {};
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

// ============================================================
// SSE / EventRing / MCP 헬퍼 테스트
// ============================================================

test "SseSink.writeFrame: 표준 SSE 형식 (event: + data: + 빈 줄)" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var sink: SseSink = .{ .writer = &w };
    try sink.writeFrame("build_done", "{\"id\":42}");
    const out = buf[0..w.end];
    try std.testing.expectEqualStrings("event: build_done\ndata: {\"id\":42}\n\n", out);
}

test "writeJsonEscaped: 특수 문자 이스케이프" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJsonEscaped(&w, "a\"b\\c\nd\rt\te");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\rt\\te", buf[0..w.end]);
}

test "writeJsonValue: id 필드 (string/integer/null)" {
    var buf: [256]u8 = undefined;

    var w1 = std.Io.Writer.fixed(&buf);
    try writeJsonValue(&w1, .{ .integer = 42 });
    try std.testing.expectEqualStrings("42", buf[0..w1.end]);

    var w2 = std.Io.Writer.fixed(&buf);
    try writeJsonValue(&w2, .{ .string = "abc" });
    try std.testing.expectEqualStrings("\"abc\"", buf[0..w2.end]);

    var w3 = std.Io.Writer.fixed(&buf);
    try writeJsonValue(&w3, .null);
    try std.testing.expectEqualStrings("null", buf[0..w3.end]);
}

test "EventRing: push/snapshotSince — since 이후만 반환" {
    const alloc = std.testing.allocator;
    var ring = EventRing.init(alloc);
    defer ring.deinit();

    ring.push(1, "a", "{\"v\":1}");
    ring.push(2, "b", "{\"v\":2}");
    ring.push(3, "c", "{\"v\":3}");

    const snap = try ring.snapshotSince(alloc, 1);
    defer {
        for (snap) |r| {
            alloc.free(r.event_type);
            alloc.free(r.data_json);
        }
        alloc.free(snap);
    }
    try std.testing.expectEqual(@as(usize, 2), snap.len);
    try std.testing.expectEqual(@as(u64, 2), snap[0].seq);
    try std.testing.expectEqualStrings("b", snap[0].event_type);
    try std.testing.expectEqual(@as(u64, 3), snap[1].seq);
}

test "EventRing: capacity 초과 시 오래된 항목 덮어쓰기" {
    const alloc = std.testing.allocator;
    var ring = EventRing.init(alloc);
    defer ring.deinit();

    var i: u64 = 0;
    while (i < EventRing.capacity + 50) : (i += 1) {
        ring.push(i + 1, "e", "{}");
    }

    // 가장 최근 capacity개만 보존되어야 함
    const snap = try ring.snapshotSince(alloc, 0);
    defer {
        for (snap) |r| {
            alloc.free(r.event_type);
            alloc.free(r.data_json);
        }
        alloc.free(snap);
    }
    try std.testing.expectEqual(@as(usize, EventRing.capacity), snap.len);
    // 첫 항목은 잘려나간 만큼 뒤로 밀린 seq
    try std.testing.expectEqual(@as(u64, 51), snap[0].seq);
}

test "EventRing: snapshotSince 빈 결과 (since == head)" {
    const alloc = std.testing.allocator;
    var ring = EventRing.init(alloc);
    defer ring.deinit();

    ring.push(1, "a", "{}");
    ring.push(2, "b", "{}");

    const snap = try ring.snapshotSince(alloc, 2);
    defer alloc.free(snap);
    try std.testing.expectEqual(@as(usize, 0), snap.len);
}

test "SseClients: broadcast — 다수 클라이언트에 SSE 형식으로 전송" {
    var sse: SseClients = .{};

    var buf1: [256]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&buf1);
    var sink1: SseSink = .{ .writer = &w1 };
    var buf2: [256]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    var sink2: SseSink = .{ .writer = &w2 };

    sse.add(&sink1);
    sse.add(&sink2);
    try std.testing.expectEqual(@as(usize, 2), sse.len);

    sse.broadcast("ping", "{}");
    try std.testing.expectEqualStrings("event: ping\ndata: {}\n\n", buf1[0..w1.end]);
    try std.testing.expectEqualStrings("event: ping\ndata: {}\n\n", buf2[0..w2.end]);
}

test "SseClients: remove — swap-remove로 제거" {
    var sse: SseClients = .{};

    var buf1: [16]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&buf1);
    var sink1: SseSink = .{ .writer = &w1 };
    var buf2: [16]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&buf2);
    var sink2: SseSink = .{ .writer = &w2 };
    var buf3: [16]u8 = undefined;
    var w3 = std.Io.Writer.fixed(&buf3);
    var sink3: SseSink = .{ .writer = &w3 };

    sse.add(&sink1);
    sse.add(&sink2);
    sse.add(&sink3);
    sse.remove(&sink2);

    try std.testing.expectEqual(@as(usize, 2), sse.len);
    try std.testing.expect(sse.items[0] == &sink1);
    try std.testing.expect(sse.items[1] == &sink3);
}

test "SseClients: broadcast 시 dead client 자동 제거" {
    var sse: SseClients = .{};

    var buf_ok: [256]u8 = undefined;
    var w_ok = std.Io.Writer.fixed(&buf_ok);
    var sink_ok: SseSink = .{ .writer = &w_ok };
    var buf_full: [4]u8 = undefined; // 너무 작아 SSE 프레임 못 씀 → 쓰기 실패
    var w_full = std.Io.Writer.fixed(&buf_full);
    var sink_full: SseSink = .{ .writer = &w_full };

    sse.add(&sink_full);
    sse.add(&sink_ok);
    sse.broadcast("evt", "{}");

    try std.testing.expectEqual(@as(usize, 1), sse.len);
    try std.testing.expect(sse.items[0] == &sink_ok);
}

test "EventType: 상수가 정확한 이벤트 이름 매핑" {
    try std.testing.expectEqualStrings("server_ready", EventType.server_ready);
    try std.testing.expectEqualStrings("watch_change", EventType.watch_change);
    try std.testing.expectEqualStrings("bundle_build_started", EventType.bundle_build_started);
    try std.testing.expectEqualStrings("bundle_build_done", EventType.bundle_build_done);
    try std.testing.expectEqualStrings("bundle_build_failed", EventType.bundle_build_failed);
    try std.testing.expectEqualStrings("cache_reset", EventType.cache_reset);
}
