const std = @import("std");
const sourcemap = @import("sourcemap.zig");
const encodeVLQ = sourcemap.encodeVLQ;
const SourceMapBuilder = sourcemap.SourceMapBuilder;

test "VLQ: encode 0" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeVLQ(std.testing.allocator, &buf, 0);
    try std.testing.expectEqualStrings("A", buf.items);
}

test "VLQ: encode 1" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeVLQ(std.testing.allocator, &buf, 1);
    try std.testing.expectEqualStrings("C", buf.items);
}

test "VLQ: encode -1" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeVLQ(std.testing.allocator, &buf, -1);
    try std.testing.expectEqualStrings("D", buf.items);
}

test "VLQ: encode 16" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeVLQ(std.testing.allocator, &buf, 16);
    try std.testing.expectEqualStrings("gB", buf.items);
}

test "VLQ: encode -16" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try encodeVLQ(std.testing.allocator, &buf, -16);
    try std.testing.expectEqualStrings("hB", buf.items);
}

test "SourceMapBuilder: simple mapping" {
    var builder = SourceMapBuilder.init(std.testing.allocator);
    defer builder.deinit();

    _ = try builder.addSource("input.ts");
    try builder.addMapping(.{
        .generated_line = 0,
        .generated_column = 0,
        .source_index = 0,
        .original_line = 0,
        .original_column = 0,
    });

    const json = try builder.generateJSON("output.js");
    // mappings는 "AAAA" (모든 값이 0)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mappings\":\"AAAA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sources\":[\"input.ts\"]") != null);
}

test "SourceMapBuilder: multi-line mapping" {
    var builder = SourceMapBuilder.init(std.testing.allocator);
    defer builder.deinit();

    _ = try builder.addSource("input.ts");
    try builder.addMapping(.{ .generated_line = 0, .generated_column = 0, .original_line = 0, .original_column = 0 });
    try builder.addMapping(.{ .generated_line = 1, .generated_column = 0, .original_line = 1, .original_column = 0 });

    const json = try builder.generateJSON("output.js");
    // 줄1 "AAAA" (0,0,0,0), 줄2 "AACA" (col=0, src=0, line=+1, col=0)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mappings\":\"AAAA;AACA\"") != null);
}

// ============================================================
// appendSourceMappingURLComment (#2660)
// ============================================================

test "appendSourceMappingURLComment: linked → //# sourceMappingURL=<url>.map\\n" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var slot: ?[]const u8 = null;
    try sourcemap.appendSourceMappingURLComment(&output, std.testing.allocator, .{
        .mode = .linked,
        .output_filename = "bundle.js",
    }, &slot);
    try std.testing.expectEqualStrings("//# sourceMappingURL=bundle.js.map\n", output.items);
}

test "appendSourceMappingURLComment: linked + prefix_slash → //# sourceMappingURL=/<url>.map\\n" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var slot: ?[]const u8 = null;
    try sourcemap.appendSourceMappingURLComment(&output, std.testing.allocator, .{
        .mode = .linked,
        .output_filename = "bundle.js",
        .prefix_slash = true,
    }, &slot);
    try std.testing.expectEqualStrings("//# sourceMappingURL=/bundle.js.map\n", output.items);
}

test "appendSourceMappingURLComment: external → 주석 없음" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var slot: ?[]const u8 = null;
    try sourcemap.appendSourceMappingURLComment(&output, std.testing.allocator, .{
        .mode = .external,
        .output_filename = "bundle.js",
    }, &slot);
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
}

test "appendSourceMappingURLComment: inline_ → base64 embed + json consumed (slot null)" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    const json_owned = try std.testing.allocator.dupe(u8, "{\"version\":3}");
    var slot: ?[]const u8 = json_owned;
    try sourcemap.appendSourceMappingURLComment(&output, std.testing.allocator, .{
        .mode = .inline_,
        .inline_json = json_owned,
    }, &slot);
    // base64({"version":3}) = "eyJ2ZXJzaW9uIjozfQ=="
    try std.testing.expectEqualStrings(
        "//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozfQ==\n",
        output.items,
    );
    // helper 가 json 을 consume + slot 갱신 — caller 의 free 책임 해제.
    try std.testing.expect(slot == null);
}

test "appendSourceMappingURLComment: inline_ + null json → silent skip (lazy 시나리오)" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var slot: ?[]const u8 = null;
    try sourcemap.appendSourceMappingURLComment(&output, std.testing.allocator, .{
        .mode = .inline_,
    }, &slot);
    // lazy 등으로 json 이 null 이면 noop — output 변동 없음.
    try std.testing.expectEqual(@as(usize, 0), output.items.len);
    try std.testing.expect(slot == null);
}

test "appendSourceMappingURLComment: inline_ + prefix_slash 는 무시됨 (linked-only 옵션)" {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    const json_owned = try std.testing.allocator.dupe(u8, "{}");
    var slot: ?[]const u8 = json_owned;
    try sourcemap.appendSourceMappingURLComment(&output, std.testing.allocator, .{
        .mode = .inline_,
        .prefix_slash = true, // ignored
        .inline_json = json_owned,
    }, &slot);
    try std.testing.expectEqualStrings(
        "//# sourceMappingURL=data:application/json;base64,e30=\n",
        output.items,
    );
    try std.testing.expect(slot == null);
}
