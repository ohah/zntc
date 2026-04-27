const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const ConstValue = @import("../semantic/symbol.zig").ConstValue;

fn markForbiddenSites(ast: *const Ast, forbidden: *std.DynamicBitSet) void {
    for (ast.nodes.items) |node| {
        if (node.tag != .object_property) continue;
        if (!node.data.binary.right.isNone()) continue;
        const key_ni = @intFromEnum(node.data.binary.left);
        if (key_ni < forbidden.capacity()) forbidden.set(key_ni);
    }
}

fn constValueNode(ast: *Ast, cv: ConstValue) ?Node {
    return switch (cv.kind) {
        .true_, .false_ => blk: {
            const text = if (cv.kind == .true_) "true" else "false";
            const span = ast.addString(text) catch return null;
            break :blk .{
                .tag = .boolean_literal,
                .span = span,
                .data = .{ .none = 0 },
            };
        },
        .null_ => blk: {
            const span = ast.addString("null") catch return null;
            break :blk .{
                .tag = .null_literal,
                .span = span,
                .data = .{ .none = 0 },
            };
        },
        else => null,
    };
}

/// Linker가 증명한 primitive constants를 AST read-site에 반영한다.
/// codegen-only 치환은 branch body refs를 줄이지 못하므로, minify/DCE 전 literal로
/// materialize해야 dead branch와 그 안의 imports가 다음 pass에서 사라질 수 있다.
pub fn materialize(
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    const_values: *const std.AutoHashMapUnmanaged(u32, ConstValue),
) bool {
    if (const_values.count() == 0) return false;

    var forbidden = std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len) catch return false;
    defer forbidden.deinit();
    markForbiddenSites(ast, &forbidden);

    var changed = false;
    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .identifier_reference) continue;
        if (i >= symbol_ids.len) continue;
        if (forbidden.isSet(i)) continue;
        const sym_id = symbol_ids[i] orelse continue;
        const cv = const_values.get(sym_id) orelse continue;
        const replacement = constValueNode(ast, cv) orelse continue;
        ast.nodes.items[i] = replacement;
        changed = true;
    }
    return changed;
}
