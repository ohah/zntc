//! Source-map and function-map helpers for codegen.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;

pub fn addSourceFile(self: anytype, source_name: []const u8) !void {
    if (self.sm_builder) |*sm| {
        _ = try sm.addSource(source_name);
        if (self.options.sources_content) {
            try sm.addSourceContent(self.ast.source);
        }
    }
}

pub fn generateSourceMap(self: anytype, output_file: []const u8) !?[]const u8 {
    if (self.sm_builder) |*sm| {
        return try sm.generateJSON(output_file);
    }
    return null;
}

pub fn generateSourceMapWithFunctionMap(self: anytype, output_file: []const u8) !?[]const u8 {
    const sm = &(self.sm_builder orelse return null);
    if (self.fn_map_builder) |*fm| {
        return try sm.generateJSONWithFunctionMap(self.allocator, output_file, fm);
    }
    return try sm.generateJSON(output_file);
}

pub fn addSourceMapping(self: anytype, span: Span) !void {
    if (self.sm_builder) |*sm| {
        // 합성 노드 (string_table 참조) 와 zero-width span 은 발행 안 함 (zero span 도 포함).
        // 호출자가 emitter 첫 줄에서 부담 없이 호출하도록 가드 일원화.
        if (span.start & Ast.STRING_TABLE_BIT != 0) return;
        if (span.start == span.end) return;
        const lc = getOriginalLineColumn(self, span.start);
        try sm.addMapping(.{
            .generated_line = self.gen_line,
            .generated_column = self.gen_col,
            .source_index = 0,
            .original_line = lc.line,
            .original_column = lc.column,
        });
    }
}

fn getOriginalLineColumn(self: anytype, offset: u32) struct { line: u32, column: u32 } {
    const offsets = self.line_offsets;
    if (offsets.len == 0) return .{ .line = 0, .column = offset };
    var lo: u32 = 0;
    var hi: u32 = @intCast(offsets.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (offsets[mid] <= offset) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    const line_idx = if (lo > 0) lo - 1 else 0;
    return .{
        .line = line_idx,
        .column = offset - offsets[line_idx],
    };
}

pub fn fnMapEnter(self: anytype, name: []const u8) !void {
    if (self.fn_map_builder == null) return;
    const interned = try self.fn_map_builder.?.internedName(name);
    try self.fn_name_stack.append(self.allocator, interned);
    errdefer _ = self.fn_name_stack.pop();
    try self.fn_map_builder.?.push(.{
        .name = interned,
        .line = self.gen_line + 1,
        .column = self.gen_col,
    });
}

pub fn fnMapExit(self: anytype) !void {
    if (self.fn_map_builder == null) return;
    if (self.fn_name_stack.items.len == 0) return;
    _ = self.fn_name_stack.pop();
    if (self.fn_name_stack.items.len == 0) return;
    const parent = self.fn_name_stack.items[self.fn_name_stack.items.len - 1];
    try self.fn_map_builder.?.push(.{
        .name = parent,
        .line = self.gen_line + 1,
        .column = self.gen_col,
    });
}

pub fn isFunctionLike(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    return switch (self.ast.getNode(idx).tag) {
        .function_declaration, .function_expression, .function, .arrow_function_expression, .class_declaration, .class_expression => true,
        else => false,
    };
}

pub fn resolveMemberLeafName(self: anytype, idx: NodeIndex) !?[]u8 {
    if (idx.isNone()) return null;
    const n = self.ast.getNode(idx);
    return switch (n.tag) {
        .identifier_reference, .assignment_target_identifier, .binding_identifier => try self.allocator.dupe(u8, self.ast.getText(n.data.string_ref)),
        .static_member_expression => blk: {
            const e = n.data.extra;
            if (!self.ast.hasExtra(e, 2)) break :blk null;
            const property = self.ast.readExtraNode(e, 1);
            break :blk try self.ast.staticKeyName(self.allocator, property);
        },
        .computed_member_expression => blk: {
            const e = n.data.extra;
            if (!self.ast.hasExtra(e, 2)) break :blk null;
            const property = self.ast.readExtraNode(e, 1);
            break :blk try self.ast.staticKeyName(self.allocator, property);
        },
        else => null,
    };
}

fn resolveParentClassName(self: anytype) ?[]const u8 {
    const stack = self.fn_name_stack.items;
    if (stack.len == 0) return null;
    const top = stack[stack.len - 1];
    if (std.mem.eql(u8, top, "<global>") or std.mem.eql(u8, top, "<anonymous>")) return null;
    return top;
}

pub fn resolveMethodName(self: anytype, key: NodeIndex, flags: u32) ![]u8 {
    const is_getter = flags & ast_mod.MethodFlags.is_getter != 0;
    const is_setter = flags & ast_mod.MethodFlags.is_setter != 0;
    const is_static = flags & ast_mod.MethodFlags.is_static != 0;
    const sep: []const u8 = if (is_static) "." else "#";

    const raw_owned: []u8 = (try self.ast.staticKeyName(self.allocator, key)) orelse
        try self.allocator.dupe(u8, "<anonymous>");
    defer self.allocator.free(raw_owned);
    const raw: []const u8 = raw_owned;

    if (std.mem.eql(u8, raw, "constructor")) {
        const parent = resolveParentClassName(self);
        return try self.allocator.dupe(u8, parent orelse "constructor");
    }

    const class_name = resolveParentClassName(self);

    if (is_getter) {
        return if (class_name) |cn|
            std.fmt.allocPrint(self.allocator, "{s}{s}get__{s}", .{ cn, sep, raw })
        else
            std.fmt.allocPrint(self.allocator, "get__{s}", .{raw});
    }
    if (is_setter) {
        return if (class_name) |cn|
            std.fmt.allocPrint(self.allocator, "{s}{s}set__{s}", .{ cn, sep, raw })
        else
            std.fmt.allocPrint(self.allocator, "set__{s}", .{raw});
    }
    return if (class_name) |cn|
        std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ cn, sep, raw })
    else
        try self.allocator.dupe(u8, raw);
}
