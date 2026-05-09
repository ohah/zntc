const std = @import("std");
const http = std.http;

/// WS 클라이언트 목록 — 여러 스레드에서 접근하므로 mutex로 보호
pub const WsClients = struct {
    mutex: std.Thread.Mutex = .{},
    /// WebSocket output writer 포인터 목록. handleWebSocket 스택에서 소유.
    items: [max_clients]*std.Io.Writer = undefined,
    len: usize = 0,

    const max_clients = 64;

    pub fn add(self: *WsClients, writer: *std.Io.Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len < max_clients) {
            self.items[self.len] = writer;
            self.len += 1;
        }
    }

    pub fn remove(self: *WsClients, writer: *std.Io.Writer) void {
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

    pub fn broadcast(self: *WsClients, data: []const u8) void {
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

pub const ErrorState = struct {
    mutex: std.Thread.Mutex = .{},
    json: ?[]const u8 = null,

    pub fn deinit(self: *ErrorState, allocator: std.mem.Allocator) void {
        self.clear(allocator);
    }

    pub fn setOwned(self: *ErrorState, allocator: std.mem.Allocator, json: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.json) |old| allocator.free(old);
        self.json = json;
    }

    pub fn setCopy(self: *ErrorState, allocator: std.mem.Allocator, json: []const u8) !void {
        const copy = try allocator.dupe(u8, json);
        self.setOwned(allocator, copy);
    }

    pub fn clear(self: *ErrorState, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.json) |json| allocator.free(json);
        self.json = null;
    }

    pub fn sendIfPresent(self: *ErrorState, writer: *std.Io.Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.json) |json| writeWsFrame(writer, json) catch {};
    }
};

/// 한 SSE 구독자 — `*std.Io.Writer`만 갖고는 chunked transfer-encoding의 chunk 종결을
/// underlying TCP까지 push할 수 없다. `body_writer`가 있으면 `BodyWriter.flush()`로
/// `http_protocol_output.flush()`까지 호출해 frame이 즉시 클라이언트에 도달.
/// 단위 테스트에서는 `body_writer = null`로 fixed buffer만 검증.
pub const SseSink = struct {
    writer: *std.Io.Writer,
    body_writer: ?*http.BodyWriter = null,

    pub fn writeFrame(self: *SseSink, event_type: []const u8, data_json: []const u8) !void {
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
pub const SseClients = struct {
    mutex: std.Thread.Mutex = .{},
    items: [max_clients]*SseSink = undefined,
    len: usize = 0,

    const max_clients = 64;

    pub fn add(self: *SseClients, sink: *SseSink) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len < max_clients) {
            self.items[self.len] = sink;
            self.len += 1;
        }
    }

    pub fn remove(self: *SseClients, sink: *SseSink) void {
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
    pub fn broadcast(self: *SseClients, event_type: []const u8, data_json: []const u8) void {
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
pub const EventRing = struct {
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    items: [capacity]Record = undefined,
    /// 다음 쓰기 위치 (`items[head % capacity]`).
    head: u64 = 0,

    pub const capacity: usize = 256;

    pub const Record = struct {
        seq: u64,
        event_type: []const u8, // owned
        data_json: []const u8, // owned
    };

    pub fn init(allocator: std.mem.Allocator) EventRing {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EventRing) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = @min(self.head, capacity);
        for (self.items[0..count]) |*r| {
            self.allocator.free(r.event_type);
            self.allocator.free(r.data_json);
        }
    }

    pub fn push(self: *EventRing, seq: u64, event_type: []const u8, data_json: []const u8) void {
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
    pub fn snapshotSince(self: *EventRing, alloc: std.mem.Allocator, since_seq: u64) ![]Record {
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
pub fn writeJsonEscaped(w: anytype, s: []const u8) !void {
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

pub fn buildErrorJsonFromDiagnostics(allocator: std.mem.Allocator, diags: anytype) ![]const u8 {
    var msg: std.ArrayList(u8) = .empty;
    errdefer msg.deinit(allocator);
    const w = msg.writer(allocator);

    try w.writeAll("{\"type\":\"error\",\"errors\":[");
    for (diags, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"file\":\"");
        try writeJsonEscaped(w, d.file_path);
        try w.writeAll("\",\"message\":\"");
        try writeJsonEscaped(w, d.message);
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");
    return try msg.toOwnedSlice(allocator);
}

/// 임의의 std.json.Value를 JSON으로 직렬화 (MCP `id` 필드용 — string/integer/null만).
pub fn writeJsonValue(w: anytype, v: std.json.Value) !void {
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
