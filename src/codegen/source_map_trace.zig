//! Source Map V3 decoder and trace helper for plugin transform maps.
//!
//! The bundler codegen map points from final emitted module code back to the
//! post-plugin module source. Plugin maps point from each transform output back
//! to the previous input, so final output positions are traced through the
//! plugin chain in reverse order before being inserted into the bundle map.

const std = @import("std");

pub const ParseError = error{
    InvalidSourceMap,
    OutOfMemory,
};

pub const TraceMapping = struct {
    generated_line: u32,
    generated_column: u32,
    source_index: u32,
    original_line: u32,
    original_column: u32,

    fn lessThan(_: void, a: TraceMapping, b: TraceMapping) bool {
        if (a.generated_line != b.generated_line) return a.generated_line < b.generated_line;
        return a.generated_column < b.generated_column;
    }
};

pub const TraceResult = struct {
    source: []const u8,
    source_content: ?[]const u8,
    line: u32,
    column: u32,
};

pub const ParsedMap = struct {
    allocator: std.mem.Allocator,
    sources: []const []const u8,
    sources_content: []const ?[]const u8,
    mappings: []const TraceMapping,
    line_starts: []const usize,

    pub fn deinit(self: *ParsedMap) void {
        for (self.sources) |s| self.allocator.free(s);
        self.allocator.free(self.sources);
        for (self.sources_content) |maybe_content| {
            if (maybe_content) |content| self.allocator.free(content);
        }
        self.allocator.free(self.sources_content);
        self.allocator.free(self.mappings);
        self.allocator.free(self.line_starts);
    }

    pub fn lookup(self: *const ParsedMap, line: u32, column: u32) ?TraceResult {
        const line_usize: usize = @intCast(line);
        if (line_usize + 1 >= self.line_starts.len) return null;
        const start = self.line_starts[line_usize];
        const end = self.line_starts[line_usize + 1];
        var found: ?TraceMapping = null;
        for (self.mappings[start..end]) |mapping| {
            if (mapping.generated_column > column) break;
            found = mapping;
        }
        const mapping = found orelse return null;
        const src_idx: usize = @intCast(mapping.source_index);
        if (src_idx >= self.sources.len) return null;
        const content = if (src_idx < self.sources_content.len) self.sources_content[src_idx] else null;
        return .{
            .source = self.sources[src_idx],
            .source_content = content,
            .line = mapping.original_line,
            .column = mapping.original_column,
        };
    }
};

const BuildState = struct {
    allocator: std.mem.Allocator,
    sources: std.ArrayList([]const u8) = .empty,
    sources_content: std.ArrayList(?[]const u8) = .empty,
    mappings: std.ArrayList(TraceMapping) = .empty,

    fn deinit(self: *BuildState) void {
        for (self.sources.items) |s| self.allocator.free(s);
        for (self.sources_content.items) |maybe_content| {
            if (maybe_content) |content| self.allocator.free(content);
        }
        self.sources.deinit(self.allocator);
        self.sources_content.deinit(self.allocator);
        self.mappings.deinit(self.allocator);
    }

    fn addSource(
        self: *BuildState,
        source_root: []const u8,
        source: []const u8,
        content: ?[]const u8,
    ) ParseError!u32 {
        const source_name = try joinSourceRoot(self.allocator, source_root, source);
        errdefer self.allocator.free(source_name);
        const content_copy = if (content) |c| try self.allocator.dupe(u8, c) else null;
        errdefer if (content_copy) |c| self.allocator.free(c);

        const idx: u32 = @intCast(self.sources.items.len);
        try self.sources.append(self.allocator, source_name);
        try self.sources_content.append(self.allocator, content_copy);
        return idx;
    }
};

pub fn parse(allocator: std.mem.Allocator, json_text: []const u8) ParseError!ParsedMap {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch
        return error.InvalidSourceMap;
    defer parsed.deinit();

    var state = BuildState{ .allocator = allocator };
    errdefer state.deinit();

    try parseValueInto(&state, parsed.value, 0, 0);
    return finishParsedMap(allocator, &state);
}

pub fn trace(maps: []const ParsedMap, line: u32, column: u32) ?TraceResult {
    var current_line = line;
    var current_column = column;
    var result: ?TraceResult = null;
    var i = maps.len;
    while (i > 0) {
        i -= 1;
        const next = maps[i].lookup(current_line, current_column) orelse return null;
        result = next;
        current_line = next.line;
        current_column = next.column;
    }
    return result;
}

fn finishParsedMap(allocator: std.mem.Allocator, state: *BuildState) ParseError!ParsedMap {
    if (state.mappings.items.len > 1) {
        std.mem.sort(TraceMapping, state.mappings.items, {}, TraceMapping.lessThan);
    }

    var max_line: u32 = 0;
    for (state.mappings.items) |mapping| {
        if (mapping.generated_line > max_line) max_line = mapping.generated_line;
    }

    const sources = try state.sources.toOwnedSlice(allocator);
    errdefer freeSources(allocator, sources);
    const sources_content = try state.sources_content.toOwnedSlice(allocator);
    errdefer freeSourceContents(allocator, sources_content);
    const mappings = try state.mappings.toOwnedSlice(allocator);
    errdefer allocator.free(mappings);

    const line_count: usize = if (mappings.len == 0) 1 else @as(usize, @intCast(max_line)) + 2;
    const line_starts = try allocator.alloc(usize, line_count);
    errdefer allocator.free(line_starts);
    var cursor: usize = 0;
    var line: usize = 0;
    while (line + 1 < line_count) : (line += 1) {
        line_starts[line] = cursor;
        while (cursor < mappings.len and mappings[cursor].generated_line == line) {
            cursor += 1;
        }
    }
    line_starts[line_count - 1] = mappings.len;

    return .{
        .allocator = allocator,
        .sources = sources,
        .sources_content = sources_content,
        .mappings = mappings,
        .line_starts = line_starts,
    };
}

fn freeSources(allocator: std.mem.Allocator, sources: []const []const u8) void {
    for (sources) |s| allocator.free(s);
    allocator.free(sources);
}

fn freeSourceContents(allocator: std.mem.Allocator, sources_content: []const ?[]const u8) void {
    for (sources_content) |maybe_content| {
        if (maybe_content) |content| allocator.free(content);
    }
    allocator.free(sources_content);
}

fn parseValueInto(
    state: *BuildState,
    value: std.json.Value,
    base_line: u32,
    base_column: u32,
) ParseError!void {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidSourceMap,
    };
    const version_value = obj.get("version") orelse return error.InvalidSourceMap;
    if (jsonU32(version_value) orelse 0 != 3) return error.InvalidSourceMap;

    if (obj.get("sections")) |sections_value| {
        const sections = switch (sections_value) {
            .array => |a| a,
            else => return error.InvalidSourceMap,
        };
        for (sections.items) |section_value| {
            const section = switch (section_value) {
                .object => |o| o,
                else => return error.InvalidSourceMap,
            };
            const offset = switch (section.get("offset") orelse return error.InvalidSourceMap) {
                .object => |o| o,
                else => return error.InvalidSourceMap,
            };
            const section_line = jsonU32(offset.get("line") orelse return error.InvalidSourceMap) orelse
                return error.InvalidSourceMap;
            const section_column = jsonU32(offset.get("column") orelse return error.InvalidSourceMap) orelse
                return error.InvalidSourceMap;
            const child_map = section.get("map") orelse return error.InvalidSourceMap;
            const child_base_line = base_line + section_line;
            const child_base_column = if (section_line == 0)
                base_column + section_column
            else
                section_column;
            try parseValueInto(state, child_map, child_base_line, child_base_column);
        }
        return;
    }

    const sources_value = obj.get("sources") orelse return error.InvalidSourceMap;
    const sources = switch (sources_value) {
        .array => |a| a,
        else => return error.InvalidSourceMap,
    };
    const source_root = if (obj.get("sourceRoot")) |sr| switch (sr) {
        .string => |s| s,
        else => "",
    } else "";

    const sources_content_array = if (obj.get("sourcesContent")) |sc| switch (sc) {
        .array => |a| a,
        else => null,
    } else null;

    const source_base: u32 = @intCast(state.sources.items.len);
    for (sources.items, 0..) |source_value, i| {
        const source_name = switch (source_value) {
            .string => |s| s,
            else => return error.InvalidSourceMap,
        };
        const content: ?[]const u8 = if (sources_content_array) |arr| blk: {
            if (i >= arr.items.len) break :blk null;
            break :blk switch (arr.items[i]) {
                .string => |s| s,
                .null => null,
                else => null,
            };
        } else null;
        _ = try state.addSource(source_root, source_name, content);
    }

    const mappings_value = obj.get("mappings") orelse return error.InvalidSourceMap;
    const mappings = switch (mappings_value) {
        .string => |s| s,
        else => return error.InvalidSourceMap,
    };
    try decodeMappingsInto(state, mappings, source_base, @intCast(sources.items.len), base_line, base_column);
}

fn decodeMappingsInto(
    state: *BuildState,
    mappings: []const u8,
    source_base: u32,
    source_count: u32,
    base_line: u32,
    base_column: u32,
) ParseError!void {
    var generated_line: u32 = 0;
    var previous_source: i32 = 0;
    var previous_original_line: i32 = 0;
    var previous_original_column: i32 = 0;

    var line_it = std.mem.splitScalar(u8, mappings, ';');
    while (line_it.next()) |line_text| : (generated_line += 1) {
        var previous_generated_column: i32 = 0;
        var segment_it = std.mem.splitScalar(u8, line_text, ',');
        while (segment_it.next()) |segment| {
            if (segment.len == 0) continue;
            var fields_buf: [5]i32 = undefined;
            const fields = try decodeVlqSegment(segment, &fields_buf);
            if (!(fields.len == 1 or fields.len == 4 or fields.len == 5)) {
                return error.InvalidSourceMap;
            }
            previous_generated_column += fields[0];
            if (previous_generated_column < 0) return error.InvalidSourceMap;
            if (fields.len == 1) continue;

            previous_source += fields[1];
            previous_original_line += fields[2];
            previous_original_column += fields[3];
            if (previous_source < 0 or
                previous_original_line < 0 or
                previous_original_column < 0)
            {
                return error.InvalidSourceMap;
            }
            const source_index: u32 = @intCast(previous_source);
            if (source_index >= source_count) return error.InvalidSourceMap;

            try state.mappings.append(state.allocator, .{
                .generated_line = base_line + generated_line,
                .generated_column = if (generated_line == 0)
                    base_column + @as(u32, @intCast(previous_generated_column))
                else
                    @intCast(previous_generated_column),
                .source_index = source_base + source_index,
                .original_line = @intCast(previous_original_line),
                .original_column = @intCast(previous_original_column),
            });
        }
    }
}

fn decodeVlqSegment(segment: []const u8, out: *[5]i32) ParseError![]const i32 {
    var count: usize = 0;
    var value: i64 = 0;
    var shift: u6 = 0;
    for (segment) |ch| {
        const digit = decodeBase64(ch) orelse return error.InvalidSourceMap;
        const continuation = (digit & 32) != 0;
        if (shift > 30) return error.InvalidSourceMap;
        value |= @as(i64, @intCast(digit & 31)) << shift;
        if (!continuation) {
            if (count >= out.len) return error.InvalidSourceMap;
            const negative = (value & 1) != 0;
            const decoded = value >> 1;
            if (decoded > std.math.maxInt(i32)) return error.InvalidSourceMap;
            const signed = if (negative) -decoded else decoded;
            out[count] = @intCast(signed);
            count += 1;
            value = 0;
            shift = 0;
        } else {
            if (shift == 30) return error.InvalidSourceMap;
            shift += 5;
        }
    }
    if (shift != 0 or count == 0) return error.InvalidSourceMap;
    return out[0..count];
}

fn decodeBase64(ch: u8) ?u6 {
    return switch (ch) {
        'A'...'Z' => @intCast(ch - 'A'),
        'a'...'z' => @intCast(ch - 'a' + 26),
        '0'...'9' => @intCast(ch - '0' + 52),
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

fn jsonU32(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else null,
        .float => |f| if (f >= 0 and f <= @as(f64, @floatFromInt(std.math.maxInt(u32))) and @floor(f) == f)
            @intFromFloat(f)
        else
            null,
        else => null,
    };
}

fn joinSourceRoot(allocator: std.mem.Allocator, source_root: []const u8, source: []const u8) ParseError![]const u8 {
    if (source_root.len == 0) return allocator.dupe(u8, source);
    if (source.len == 0) return allocator.dupe(u8, source_root);
    if (source[0] == '/' or std.mem.endsWith(u8, source_root, "/")) {
        return std.mem.concat(allocator, u8, &.{ source_root, source });
    }
    return std.mem.concat(allocator, u8, &.{ source_root, "/", source });
}

test "source map trace: simple mapping lookup" {
    var map = try parse(
        std.testing.allocator,
        "{\"version\":3,\"sources\":[\"input.ts\"],\"sourcesContent\":[\"const x = 1;\"],\"mappings\":\";AAAA;AACA\"}",
    );
    defer map.deinit();

    const hit = map.lookup(1, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("input.ts", hit.source);
    try std.testing.expectEqual(@as(u32, 0), hit.line);
}

test "source map trace: sections offset" {
    var map = try parse(
        std.testing.allocator,
        "{\"version\":3,\"sections\":[{\"offset\":{\"line\":2,\"column\":0},\"map\":{\"version\":3,\"sources\":[\"input.ts\"],\"mappings\":\"AAAA\"}}]}",
    );
    defer map.deinit();

    const hit = map.lookup(2, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("input.ts", hit.source);
    try std.testing.expectEqual(@as(u32, 0), hit.line);
}

test "source map trace: invalid segment shape is rejected" {
    try std.testing.expectError(
        error.InvalidSourceMap,
        parse(std.testing.allocator, "{\"version\":3,\"sources\":[\"input.ts\"],\"mappings\":\"AA\"}"),
    );
}
