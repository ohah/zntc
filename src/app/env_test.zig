//! app/env.zig 테스트 — Vite .env 파일 우선순위/prefix + import.meta.env define.

const std = @import("std");
const env = @import("env.zig");

test "app env loader honors Vite file priority and prefixes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env", .data = "VITE_KEY=base\nSECRET=hidden\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env.local", .data = "VITE_KEY=local\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env.production", .data = "VITE_KEY=prod\nZNTC_FLAG=yes\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env.production.local", .data = "VITE_KEY=prod-local\n" });

    var env_map = try env.loadEnv(std.testing.allocator, std.testing.io, .{ .mode = "production", .env_dir = dir });
    defer env.deinitMap(&env_map, std.testing.allocator);
    try std.testing.expectEqualStrings("prod-local", env_map.get("VITE_KEY").?);
    try std.testing.expectEqualStrings("yes", env_map.get("ZNTC_FLAG").?);
    try std.testing.expect(env_map.get("SECRET") == null);
}

test "app env define includes base and import.meta.env object" {
    var env_map = env.EnvMap.init(std.testing.allocator);
    defer env.deinitMap(&env_map, std.testing.allocator);
    try env_map.put(try std.testing.allocator.dupe(u8, "VITE_API"), try std.testing.allocator.dupe(u8, "ok"));

    const defines = try env.envToDefine(std.testing.allocator, &env_map, "development", "/app/");
    defer env.freeDefines(std.testing.allocator, defines);

    var found_base = false;
    var found_object = false;
    for (defines) |entry| {
        if (std.mem.eql(u8, entry.key, "import.meta.env.BASE_URL")) {
            found_base = true;
            try std.testing.expectEqualStrings("\"/app/\"", entry.value);
        }
        if (std.mem.eql(u8, entry.key, "import.meta.env")) {
            found_object = true;
            try std.testing.expect(std.mem.indexOf(u8, entry.value, "\"VITE_API\":\"ok\"") != null);
        }
    }
    try std.testing.expect(found_base);
    try std.testing.expect(found_object);
}
