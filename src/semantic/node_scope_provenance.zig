//! Creation provenance of expressions that are not lexical scope owners.
const std = @import("std");
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const ScopeId = @import("scope.zig").ScopeId;
pub const Entry = struct {
    scope: ScopeId,
    /// Initial source expression; clones retain this exact producer identity.
    source_node: NodeIndex,
    /// A real source with ObjectEnvironment surrounds this expression.
    with_environment: bool = false,
    external_import: ?@import("import_erasure.zig").ExternalOrigin = null,
    source_external: ?@import("source_external_origin.zig").Origin = null,
};
pub const Map = std.AutoHashMapUnmanaged(NodeIndex, Entry);

/// A fresh semantic owner may rebuild scope indices for this same append-only
/// AST. Keep only the initial expression identity; never copy old ScopeIds.
pub fn preserveSourceOrigins(ast: *const @import("../parser/ast.zig").Ast, current: *Map, previous: *const Map) error{ InvalidExpressionOrigin, InvalidExpressionEnvironment }!void {
    var entries = current.iterator();
    while (entries.next()) |entry| {
        const old = previous.get(entry.key_ptr.*) orelse continue;
        if (old.source_node.isNone() or @backingInt(old.source_node) >= ast.nodes.items.len or ast.getNode(old.source_node).tag != .import_expression) return error.InvalidExpressionOrigin;
        if (old.with_environment != entry.value_ptr.with_environment) return error.InvalidExpressionEnvironment;
        entry.value_ptr.source_node = old.source_node;
    }
}
