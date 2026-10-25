//! Exact initial-producer anchor for an anonymous default-export facade.
const ast_mod = @import("../parser/ast.zig");
const Symbol = @import("../semantic/symbol.zig").Symbol;

/// Named declarations and ordinary values are not facade roles. A supported
/// role uses the export node's authoritative SID, never a spelling lookup.
pub fn symbolAt(ast: *const ast_mod.Ast, node: ast_mod.NodeIndex, ids: []const ?u32, symbols: []const Symbol) error{InvalidDefaultFacade}!?u32 {
    if (node.isNone() or @backingInt(node) >= ast.nodes.items.len) return error.InvalidDefaultFacade;
    const raw = @backingInt(node);
    if (ast.getNode(node).tag != .export_default_declaration or raw >= ids.len) return null;
    const sid = ids[raw] orelse return null;
    if (sid >= symbols.len) return error.InvalidDefaultFacade;
    const symbol = symbols[sid];
    if (!symbol.decl_flags.is_default_export or symbol.kind != .variable_const or symbol.scope_id.toIndex() != 0) return null;
    return sid;
}
