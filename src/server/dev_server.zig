const std = @import("std");
const http = std.http;
const mime = @import("mime.zig");
const lib = @import("../root.zig");
const Bundler = lib.bundler.Bundler;
const BundleOptions = lib.bundler.BundleOptions;
const BundleResult = lib.bundler.BundleResult;
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
        };
    }

    pub fn deinit(self: *DevServer) void {
        if (self.tcp_server) |*s| s.deinit();
        if (self.abs_entry) |ae| self.allocator.free(ae);
        self.root_dir.close();
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
        for (request.head.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "host")) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
            try req.appendSlice(allocator, h.name);
            try req.appendSlice(allocator, ": ");
            try req.appendSlice(allocator, h.value);
            try req.appendSlice(allocator, "\r\n");
        }
        try req.appendSlice(allocator, "\r\n");

        // 요청 바디 전달 (POST/PUT/PATCH)
        if (request.head.content_length) |cl| {
            if (cl > 0) {
                const body = try allocator.alloc(u8, cl);
                defer allocator.free(body);
                const n = try request.reader().readAll(body);
                try req.appendSlice(allocator, body[0..n]);
            }
        }

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
            const connection = self.tcp_server.?.accept() catch |err| {
                getLog().print("zts: accept failed: {}\n", .{err}) catch {};
                continue;
            };
            const thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, handleConnection, .{ self, connection }) catch {
                connection.stream.close();
                continue;
            };
            thread.detach();
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

        // 초기 번들 → 모듈 경로 수집
        var watch_paths = collectModulePaths(self.allocator, abs_entry, self.plugins) orelse return;
        defer freeWatchPaths(self.allocator, &watch_paths);

        // root_dir의 CSS 파일을 watch 대상에 추가
        var css_paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (css_paths.items) |p| self.allocator.free(p);
            css_paths.deinit(self.allocator);
        }
        {
            const root_real = std.fs.cwd().realpathAlloc(self.allocator, self.root_path) catch null;
            defer if (root_real) |r| self.allocator.free(r);
            if (root_real) |root| {
                collectCssFiles(self.allocator, self.root_dir, root, &css_paths);
            }
        }

        // 초기 mtime 맵 구축
        var mtime_map = std.StringHashMap(i128).init(self.allocator);
        defer mtime_map.deinit();
        for (watch_paths) |p| {
            const stat = std.fs.cwd().statFile(p) catch continue;
            mtime_map.put(p, stat.mtime) catch continue;
        }
        for (css_paths.items) |p| {
            const stat = std.fs.cwd().statFile(p) catch continue;
            mtime_map.put(p, stat.mtime) catch continue;
        }

        getLog().print("  [watch] watching {d} files for changes...\n", .{watch_paths.len}) catch {};

        while (true) {
            std.Thread.sleep(watch_interval_ms * std.time.ns_per_ms);

            // 변경된 파일 수집
            var changed_paths: std.ArrayList([]const u8) = .empty;
            defer changed_paths.deinit(self.allocator);

            // JS 모듈 + CSS 파일 변경 감지
            const all_paths = [_][]const []const u8{ watch_paths, css_paths.items };
            for (all_paths) |paths| {
                for (paths) |p| {
                    const stat = std.fs.cwd().statFile(p) catch continue;
                    const prev = mtime_map.get(p) orelse {
                        mtime_map.put(p, stat.mtime) catch {};
                        changed_paths.append(self.allocator, p) catch {};
                        continue;
                    };
                    if (stat.mtime != prev) {
                        mtime_map.put(p, stat.mtime) catch {};
                        getLog().print("  [watch] changed: {s}\n", .{std.fs.path.basename(p)}) catch {};
                        changed_paths.append(self.allocator, p) catch {};
                    }
                }
            }

            if (changed_paths.items.len == 0) continue;

            // CSS 변경 → 번들 재빌드 없이 css-update 전송 (link tag swap)
            var has_css = false;
            {
                // root_real을 루프 밖에서 1회만 계산
                const root_real = std.fs.cwd().realpathAlloc(self.allocator, self.root_path) catch null;
                defer if (root_real) |r| self.allocator.free(r);

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
            }

            // CSS만 변경되었으면 JS 재빌드 스킵
            var has_non_css = false;
            for (changed_paths.items) |cp| {
                if (!std.mem.endsWith(u8, cp, ".css")) {
                    has_non_css = true;
                    break;
                }
            }
            if (has_css and !has_non_css) continue;

            // 재번들 시도 → 에러면 에러 오버레이, 성공이면 HMR update (폴백: full-reload)
            const rebuild_result = tryRebuild(self.allocator, abs_entry, self.plugins);
            switch (rebuild_result) {
                .success => |result| {
                    defer {
                        if (result.dev_codes) |codes| {
                            BundleResult.ModuleDevCode.freeAll(codes, self.allocator);
                        }
                    }

                    // HMR update 메시지 빌드: 변경된 모듈만 포함
                    const hmr_msg = buildHmrUpdateMessage(
                        self.allocator,
                        changed_paths.items,
                        result.dev_codes,
                    );

                    if (hmr_msg) |msg| {
                        defer self.allocator.free(msg);
                        self.ws_clients.broadcast(msg);
                        getLog().print("  [hmr] update sent ({d} modules)\n", .{changed_paths.items.len}) catch {};
                    } else {
                        // dev codes가 없거나 매칭 실패 → full-reload 폴백
                        self.ws_clients.broadcast("{\"type\":\"full-reload\"}");
                    }

                    freeWatchPaths(self.allocator, &watch_paths);
                    watch_paths = result.paths;
                    mtime_map.clearAndFree();
                    for (watch_paths) |p| {
                        const stat = std.fs.cwd().statFile(p) catch continue;
                        mtime_map.put(p, stat.mtime) catch {};
                    }
                    getLog().print("  [watch] watching {d} files for changes...\n", .{watch_paths.len}) catch {};
                },
                .build_error => |err_msg| {
                    defer self.allocator.free(err_msg);
                    self.ws_clients.broadcast(err_msg);
                    getLog().print("  [watch] build error, overlay sent\n", .{}) catch {};
                },
                .fatal => {},
            }
        }
    }

    const RebuildSuccess = struct {
        paths: []const []const u8,
        dev_codes: ?[]const BundleResult.ModuleDevCode,
    };

    const RebuildResult = union(enum) {
        success: RebuildSuccess,
        build_error: []const u8, // JSON 에러 메시지 (allocator 소유)
        fatal, // 번들러 자체 실패
    };

    fn tryRebuild(allocator: std.mem.Allocator, abs_entry: []const u8, plugins: []const plugin_mod.Plugin) RebuildResult {
        var bundler = Bundler.init(allocator, .{
            .entry_points = &.{abs_entry},
            .platform = .browser,
            .dev_mode = true,
            .react_refresh = true,
            .plugins = plugins,
        });
        defer bundler.deinit();

        var result = bundler.bundle() catch return .fatal;

        // 파싱 에러(warning)도 dev server에서는 에러로 취급
        const has_build_issues = blk: {
            for (result.getDiagnostics()) |d| {
                if (d.severity == .@"error" or d.code == .parse_error) break :blk true;
            }
            break :blk false;
        };
        if (has_build_issues) {
            const diags = result.getDiagnostics();
            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(allocator);
            const w = msg.writer(allocator);
            w.print("{{\"type\":\"error\",\"errors\":[", .{}) catch return .fatal;
            for (diags, 0..) |d, i| {
                if (i > 0) w.print(",", .{}) catch {};
                w.print("{{\"file\":\"", .{}) catch {};
                writeJsonEscaped(w, d.file_path) catch return .fatal;
                w.print("\",\"message\":\"", .{}) catch {};
                writeJsonEscaped(w, d.message) catch return .fatal;
                w.print("\"}}", .{}) catch {};
            }
            w.print("]}}", .{}) catch return .fatal;

            const err_json = allocator.dupe(u8, msg.items) catch return .fatal;
            result.deinit(allocator);
            return .{ .build_error = err_json };
        }

        const paths = result.module_paths;
        result.module_paths = null;
        const dev_codes = result.module_dev_codes;
        result.module_dev_codes = null; // 소유권 이전
        result.deinit(allocator);
        return if (paths) |p| .{ .success = .{ .paths = p, .dev_codes = dev_codes } } else .fatal;
    }

    /// 변경된 파일 경로와 dev codes를 매칭하여 HMR update JSON 메시지를 빌드한다.
    /// 매칭되는 모듈이 없으면 null 반환 (full-reload 폴백).
    ///
    /// 출력 형태: {"type":"update","modules":[{"id":"path","code":"__zts_register(...)"}]}
    fn buildHmrUpdateMessage(
        allocator: std.mem.Allocator,
        changed_paths: []const []const u8,
        dev_codes: ?[]const BundleResult.ModuleDevCode,
    ) ?[]const u8 {
        const codes = dev_codes orelse return null;
        if (codes.len == 0) return null;

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(allocator);
        const w = msg.writer(allocator);

        w.print("{{\"type\":\"update\",\"modules\":[", .{}) catch return null;
        var count: usize = 0;

        for (codes) |c| {
            // dev code의 id (상대/절대) → 변경 경로와 매칭
            var matched = false;
            for (changed_paths) |cp| {
                // 절대 경로가 id를 suffix로 포함하는지 확인 (경로 구분자 체크로 false positive 방지)
                if (std.mem.eql(u8, cp, c.id) or
                    (std.mem.endsWith(u8, cp, c.id) and
                        cp.len > c.id.len and cp[cp.len - c.id.len - 1] == '/'))
                {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;

            if (count > 0) w.print(",", .{}) catch {};
            w.print("{{\"id\":\"", .{}) catch return null;
            writeJsonEscaped(w, c.id) catch return null;
            w.print("\",\"code\":\"", .{}) catch return null;
            writeJsonEscaped(w, c.code) catch return null;
            w.print("\"}}", .{}) catch return null;
            count += 1;
        }

        if (count == 0) return null;

        w.print("]}}", .{}) catch return null;
        return allocator.dupe(u8, msg.items) catch return null;
    }

    fn collectModulePaths(allocator: std.mem.Allocator, abs_entry: []const u8, plugins: []const plugin_mod.Plugin) ?[]const []const u8 {
        var bundler = Bundler.init(allocator, .{
            .entry_points = &.{abs_entry},
            .platform = .browser,
            .dev_mode = true,
            .react_refresh = true,
            .plugins = plugins,
        });
        defer bundler.deinit();

        var result = bundler.bundle() catch return null;
        const paths = result.module_paths;
        result.module_paths = null; // deinit에서 해제하지 않도록 소유권 이전
        result.deinit(allocator);
        return paths;
    }

    fn freeWatchPaths(allocator: std.mem.Allocator, paths: *[]const []const u8) void {
        for (paths.*) |p| allocator.free(p);
        allocator.free(paths.*);
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
