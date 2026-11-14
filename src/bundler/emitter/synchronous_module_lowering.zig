//! Final compiler-artifact lowering. This API deliberately accepts no Module,
//! SymbolId, ScopeId or Source semantic object. Its fresh transpile domain is
//! consumed as final bytes and numeric source-map coordinates only.
const std = @import("std");
const sourcemap = @import("../../codegen/sourcemap.zig");
const trace = @import("../../codegen/source_map_trace.zig");
pub const Mapping = sourcemap.Mapping;

pub const Options = struct {
    minify_whitespace: bool = false,
    source_maps: bool = false,
    /// Complete artifact -> original Source coordinates, after wrapper/hole
    /// offsets. Name/source indexes remain in the caller's original tables.
    input_mappings: []const Mapping = &.{},
    platform: @import("../../codegen/options.zig").Platform = .node,
};

pub const Result = struct {
    code: []const u8,
    mappings: []Mapping,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.mappings);
    }
};

/// The input must be the complete physical module artifact, including helper
/// imports, namespace publication and dependency registration. Appending code
/// that names its private locals afterwards would violate this boundary.
///
/// Full ES5 is intentional: a generator-only feature set failed the existing
/// output-name guard on the independent artifact feasibility test. Source-side
/// names/syntax have already been selected and are not requested again. The
/// requested whitespace policy is preserved by this final output pass.
pub fn lower(allocator: std.mem.Allocator, code: []const u8, filename: []const u8, options: Options) !Result {
    var compiled = try @import("../../transpile.zig").transpile(allocator, code, filename, .{
        .unsupported = @import("../../transformer/compat.zig").fromESTarget(.es5),
        .platform = options.platform,
        .minify_whitespace = options.minify_whitespace,
        .sourcemap = options.source_maps,
        // No footer: the owning chunk chooses its physical map filename later.
        .sourcemap_output_filename = "",
    });
    defer compiled.deinit(allocator);
    // Public transpile can return semantic diagnostics together with bytes.
    // Compiler artifacts must never publish such a partially valid result.
    if (compiled.diagnostics.len != 0) return error.InvalidSynchronousModuleArtifact;
    const mappings: []Mapping = if (options.source_maps)
        try compose(allocator, compiled.sourcemap orelse return error.MissingSynchronousModuleArtifactMap, filename, options.input_mappings)
    else
        &.{};
    // Ownership transfer is last: any earlier OOM/invalid-map failure still
    // releases code, diagnostics, line offsets and the temporary outer map.
    const result = Result{ .code = compiled.code, .mappings = mappings };
    compiled.code = &.{};
    return result;
}

/// Compose final -> artifact -> Source without importing artifact names or
/// identities. Unmapped compiler-only lines stay unmapped. This uses the
/// existing V3 decoder; original names are retained from numeric input mappings
/// because the decoder's TraceResult intentionally has no name field.
fn compose(allocator: std.mem.Allocator, json: []const u8, filename: []const u8, input: []const Mapping) ![]Mapping {
    var outer = try trace.parse(allocator, json);
    defer outer.deinit();
    const order = try allocator.alloc(usize, input.len);
    defer allocator.free(order);
    for (order, 0..) |*entry, index| entry.* = index;
    // Preserve insertion order at duplicate generated positions, matching V3
    // lookup's last-segment rule while leaving the caller's array untouched.
    std.mem.sort(usize, order, input, struct {
        fn less(mappings: []const Mapping, left: usize, right: usize) bool {
            if (Mapping.lessThan({}, mappings[left], mappings[right])) return true;
            if (Mapping.lessThan({}, mappings[right], mappings[left])) return false;
            return left < right;
        }
    }.less);
    var output: std.ArrayList(Mapping) = .empty;
    errdefer output.deinit(allocator);
    for (outer.mappings) |mapping| {
        if (mapping.source_index >= outer.sources.len or !std.mem.eql(u8, outer.sources[mapping.source_index], filename))
            return error.InvalidSynchronousModuleArtifactMap;
        const original = lookup(input, order, mapping.original_line, mapping.original_column) orelse continue;
        try output.append(allocator, .{
            .generated_line = mapping.generated_line,
            .generated_column = mapping.generated_column,
            .source_index = original.source_index,
            .original_line = original.original_line,
            .original_column = original.original_column,
            .name_index = original.name_index,
        });
    }
    return output.toOwnedSlice(allocator);
}

fn lookup(input: []const Mapping, order: []const usize, line: u32, column: u32) ?Mapping {
    var low: usize = 0;
    var high = order.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const item = input[order[middle]];
        if (item.generated_line < line or (item.generated_line == line and item.generated_column <= column)) {
            low = middle + 1;
        } else high = middle;
    }
    if (low == 0) return null;
    const found = input[order[low - 1]];
    return if (found.generated_line == line) found else null;
}

test "synchronous module artifact full ES5 preserves independent frame TDZ and snapshots" {
    const code = "function* frame(){yield {read:function(){return value},snapshot:function(){return snapshot},advance:function(){value++}};let value=1;const snapshot=value}var iterator=frame();var ns=iterator.next().value;function attempt(fn){try{return fn()}catch(e){return e.name}}var values=[attempt(ns.read),attempt(ns.snapshot)];iterator.next();values.push(ns.read(),ns.snapshot());ns.advance();values.push(ns.read(),ns.snapshot());console.log(JSON.stringify(values));";
    const a = std.testing.allocator;
    const expected = "[\"ReferenceError\",\"ReferenceError\",1,1,2,1]\n";
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", code } });
    defer a.free(native.stdout);
    defer a.free(native.stderr);
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings(expected, native.stdout);
    const result = try lower(a, code, "compiled-module-artifact.cjs", .{});
    defer result.deinit(a);
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
    defer a.free(actual.stdout);
    defer a.free(actual.stderr);
    if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, expected, actual.stdout))
        std.debug.print("artifact stdout={s} stderr={s} code={s}\n", .{ actual.stdout, actual.stderr, result.code });
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(expected, actual.stdout);
    try std.testing.expectEqual(@as(usize, 0), result.mappings.len);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "function*") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "let ") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "const ") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "=>") == null);
}

test "synchronous module artifact mapping composition preserves original source and name indexes" {
    const a = std.testing.allocator;
    var outer = sourcemap.SourceMapBuilder.init(a);
    defer outer.deinit();
    _ = try outer.addSource("artifact.cjs");
    try outer.addMapping(.{ .generated_line = 10, .generated_column = 0, .original_line = 5, .original_column = 4 });
    try outer.addMapping(.{ .generated_line = 10, .generated_column = 20, .original_line = 5, .original_column = 12 });
    try outer.addMapping(.{ .generated_line = 11, .generated_column = 0, .original_line = 6, .original_column = 0 });
    const json = try outer.generateJSON("final.cjs");
    const input = [_]Mapping{
        .{ .generated_line = 5, .generated_column = 11, .source_index = 1, .original_line = 41, .original_column = 9, .name_index = 2 },
        .{ .generated_line = 5, .generated_column = 2, .source_index = 3, .original_line = 40, .original_column = 7, .name_index = 4 },
    };
    const composed = try compose(a, json, "artifact.cjs", &input);
    defer a.free(composed);
    try std.testing.expectEqual(@as(usize, 2), composed.len);
    try std.testing.expectEqual(@as(u32, 3), composed[0].source_index);
    try std.testing.expectEqual(@as(?u32, 4), composed[0].name_index);
    try std.testing.expectEqual(@as(u32, 40), composed[0].original_line);
    try std.testing.expectEqual(@as(u32, 7), composed[0].original_column);
    try std.testing.expectEqual(@as(u32, 1), composed[1].source_index);
    try std.testing.expectEqual(@as(?u32, 2), composed[1].name_index);
    try std.testing.expectEqual(@as(u32, 10), composed[1].generated_line);
    try std.testing.expectEqual(@as(u32, 20), composed[1].generated_column);
    try std.testing.expectEqual(@as(u32, 11), input[0].generated_column);
    try std.testing.expectError(error.InvalidSynchronousModuleArtifactMap, compose(a, json, "other-artifact.cjs", &input));
}

test "synchronous module artifact maps trace through actual helper preamble and generator expansion" {
    const a = std.testing.allocator;
    const code = "function* frame(){\n yield 0;\n console.log('source-marker');\n}\nvar iterator=frame();iterator.next();iterator.next();";
    const input = [_]Mapping{.{ .generated_line = 2, .generated_column = 1, .original_line = 12, .original_column = 4, .name_index = 0 }};
    const result = try lower(a, code, "artifact-map.cjs", .{ .source_maps = true, .input_mappings = &input });
    defer result.deinit(a);
    try std.testing.expect(result.mappings.len > 0);
    var matched = false;
    for (result.mappings) |mapping| {
        try std.testing.expectEqual(@as(u32, 12), mapping.original_line);
        try std.testing.expectEqual(@as(u32, 4), mapping.original_column);
        try std.testing.expectEqual(@as(?u32, 0), mapping.name_index);
        if (mapping.generated_line > 2) matched = true;
    }
    try std.testing.expect(matched);
}
