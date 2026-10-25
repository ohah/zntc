//! Real loop output owners and exact relocation of their input expressions.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Span = @import("../lexer/token.zig").Span;
pub const Block = struct { node: NodeIndex, scope: ScopeId };

pub fn createBlock(self: anytype, parent: ScopeId, span: Span) !Block {
    const node = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
    return .{ .node = node, .scope = try self.addGeneratedScope(parent, node, .block) };
}

pub fn fillBlock(self: anytype, node: NodeIndex, statements: []const NodeIndex) !void {
    const list = try self.ast.addNodeList(statements);
    self.ast.nodes.items[@backingInt(node)].data.list = list;
}

pub fn moveExpression(self: anytype, root: NodeIndex, source: ScopeId, target: ScopeId) !void {
    if (!self.semantic_edit_enabled) return;
    try self.reparentGeneratedBodyScopes(source, target, root);
    const refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(self.allocator, self.ast, root);
    defer self.allocator.free(refs);
    for (refs) |node| {
        const editor = &self.semantic_editor.?;
        const reference = editor.referenceForNode(node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => std.debug.panic("generated loop iterable lost source reference: {s}", .{@errorName(err)}),
        };
        if (reference) |ref| {
            if (ref.scope_id == source) editor.moveReference(node, target, ref.stmt_idx, ref.scope_stmt_idx) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => std.debug.panic("generated loop iterable cannot move exact reference: {s}", .{@errorName(err)}),
            };
        }
    }
}
