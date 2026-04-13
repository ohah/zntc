const std = @import("std");
const dev_server = @import("dev_server.zig");
const sanitizePath = dev_server.sanitizePath;

test "sanitizePath: 루트 경로" {
    const testing = std.testing;
    try testing.expectEqualStrings("index.html", sanitizePath("/").?);
    try testing.expectEqualStrings("index.html", sanitizePath("").?);
    try testing.expectEqualStrings("index.html", sanitizePath("///").?);
}

test "sanitizePath: 일반 경로" {
    const testing = std.testing;
    try testing.expectEqualStrings("app.js", sanitizePath("/app.js").?);
    try testing.expectEqualStrings("src/main.ts", sanitizePath("/src/main.ts").?);
    try testing.expectEqualStrings("assets/logo.png", sanitizePath("/assets/logo.png").?);
}

test "sanitizePath: 디렉토리 탈출 차단" {
    const testing = std.testing;
    try testing.expect(sanitizePath("/../etc/passwd") == null);
    try testing.expect(sanitizePath("/..") == null);
    try testing.expect(sanitizePath("/../..") == null);
    try testing.expect(sanitizePath("/foo/../../etc/passwd") == null);
}

test "sanitizePath: null 바이트 차단" {
    const testing = std.testing;
    try testing.expect(sanitizePath("/foo\x00bar") == null);
}

test "sanitizePath: 백슬래시 차단" {
    const testing = std.testing;
    try testing.expect(sanitizePath("/foo\\bar") == null);
    try testing.expect(sanitizePath("\\..\\etc\\passwd") == null);
}

test "DevServer.shutdown: 플래그 설정 + acceptLoop 종료 신호" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var server = try dev_server.DevServer.init(testing.allocator, .{
        .root_dir = tmp_path,
        .port = 0,
        .host = "127.0.0.1",
    });
    defer server.deinit();

    // shutdown 호출 — start() 안 부른 상태에서도 안전해야 함 (tcp_server == null)
    server.shutdown();
    try testing.expect(server.shutdown_requested.load(.acquire));
}
