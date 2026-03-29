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
