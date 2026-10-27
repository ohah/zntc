//! Statement coordinates from current AST lists. No binding or scope identity is selected here.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const SemanticReference = @import("symbol.zig").Reference;
pub const Context = struct {
    stmt_idx: u32 = SemanticReference.NO_STMT,
    scope_stmt_idx: u32 = SemanticReference.NO_STMT,
};

const MinifiedStatementFrame = struct {
    node: ast_mod.NodeIndex,
    context: Context,
};

/// Recompute the statement coordinates consumed by tree shaking and the
/// emitter's dead-store pass, while keeping every existing SymbolId and
/// ScopeId. These coordinates are derived from current AST statement lists;
/// inability to map a graph row exactly makes retention ineligible.
pub fn collect(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
) ![]?Context {
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return error.InvalidRoot;
    const contexts = try allocator.alloc(?Context, ast.nodes.items.len);
    @memset(contexts, null);
    var stack: std.ArrayListUnmanaged(MinifiedStatementFrame) = .empty;
    try stack.append(allocator, .{ .node = root, .context = .{} });

    while (stack.pop()) |frame| {
        if (frame.node.isNone()) continue;
        const raw: usize = @backingInt(frame.node);
        if (raw >= ast.nodes.items.len) return error.InvalidStatementNode;
        if (contexts[raw]) |existing| {
            if (!std.meta.eql(existing, frame.context)) return error.AmbiguousStatementContext;
            continue;
        }
        contexts[raw] = frame.context;
        const node = ast.nodes.items[raw];
        if (node.tag == .program or node.tag == .block_statement) {
            const list = node.data.list;
            const start: usize = list.start;
            const len: usize = list.len;
            if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start)
                return error.InvalidStatementList;
            for (ast.extra_data.items[start .. start + len], 0..) |child_raw, index| {
                const child: ast_mod.NodeIndex = @fromBackingInt(child_raw);
                var context = frame.context;
                if (node.tag == .program) context.stmt_idx = @intCast(index);
                context.scope_stmt_idx = @intCast(index);
                try stack.append(allocator, .{ .node = child, .context = context });
            }
            continue;
        }

        if (node.tag == .ts_enum_declaration) {
            const extra = node.data.extra;
            const prelude = ast.readExtraNode(extra, ast_mod.EnumExtra.runtime_prelude);
            var prefix_len: u32 = 0;
            if (!prelude.isNone()) {
                if (@backingInt(prelude) >= ast.nodes.items.len) return error.InvalidStatementNode;
                const body = ast.getNode(prelude);
                if (body.tag != .block_statement) return error.InvalidStatementList;
                prefix_len = body.data.list.len;
                try stack.append(allocator, .{ .node = prelude, .context = frame.context });
            }
            try stack.append(allocator, .{ .node = ast.readExtraNode(extra, ast_mod.EnumExtra.name), .context = frame.context });
            const start = ast.extra_data.items[extra + ast_mod.EnumExtra.members_start];
            const len = ast.extra_data.items[extra + ast_mod.EnumExtra.members_len];
            if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start)
                return error.InvalidStatementList;
            for (ast.extra_data.items[start .. start + len], 0..) |member, index| {
                var context = frame.context;
                context.scope_stmt_idx = std.math.add(u32, prefix_len, @intCast(index)) catch return error.InvalidStatementList;
                try stack.append(allocator, .{ .node = @fromBackingInt(member), .context = context });
            }
            continue;
        }

        var children = ast_walk.children(ast, node);
        while (children.next()) |child| {
            try stack.append(allocator, .{ .node = child, .context = frame.context });
        }
    }
    return contexts;
}
