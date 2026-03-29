const std = @import("std");
const mime = @import("mime.zig");
const fromExtension = mime.fromExtension;

test "기본 MIME type 매핑" {
    const testing = std.testing;
    try testing.expectEqualStrings("text/html; charset=utf-8", fromExtension("index.html"));
    try testing.expectEqualStrings("application/javascript; charset=utf-8", fromExtension("app.js"));
    try testing.expectEqualStrings("application/javascript; charset=utf-8", fromExtension("mod.mjs"));
    try testing.expectEqualStrings("text/css; charset=utf-8", fromExtension("style.css"));
    try testing.expectEqualStrings("application/json; charset=utf-8", fromExtension("data.json"));
    try testing.expectEqualStrings("image/png", fromExtension("logo.png"));
    try testing.expectEqualStrings("image/svg+xml", fromExtension("icon.svg"));
    try testing.expectEqualStrings("font/woff2", fromExtension("font.woff2"));
    try testing.expectEqualStrings("application/wasm", fromExtension("module.wasm"));
    try testing.expectEqualStrings("application/json", fromExtension("bundle.js.map"));
}

test "알 수 없는 확장자" {
    const testing = std.testing;
    try testing.expectEqualStrings("application/octet-stream", fromExtension("file.xyz"));
    try testing.expectEqualStrings("application/octet-stream", fromExtension("noext"));
}

test "경로에 디렉토리 포함" {
    const testing = std.testing;
    try testing.expectEqualStrings("text/html; charset=utf-8", fromExtension("src/pages/index.html"));
    try testing.expectEqualStrings("application/javascript; charset=utf-8", fromExtension("dist/bundle.js"));
}
