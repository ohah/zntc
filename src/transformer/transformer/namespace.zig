//! TypeScript namespace and module-assignment helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const es_helpers = @import("../es_helpers.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// import x = require('y') -> const x = require('y')
/// import x = Namespace.Member -> const x = Namespace.Member
pub fn visitImportEqualsDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    const name_idx = node.data.binary.left;
    const value_idx = node.data.binary.right;
    const new_name = try self.visitNode(name_idx);
    const new_value = try self.visitNode(value_idx);

    const decl_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_name),
        @intFromEnum(NodeIndex.none),
        @intFromEnum(new_value),
    });
    const declarator = try self.ast.addNode(.{
        .tag = .variable_declarator,
        .span = node.span,
        .data = .{ .extra = decl_extra },
    });

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    try self.scratch.append(self.allocator, declarator);
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const var_extra = try self.ast.addExtras(&.{ @intFromEnum(VariableDeclarationKind.@"const"), list.start, list.len });
    return self.ast.addNode(.{
        .tag = .variable_declaration,
        .span = node.span,
        .data = .{ .extra = var_extra },
    });
}

/// `export = expr;` -> `module.exports = expr;`
/// ESM output context can still fail at runtime with `module is not defined`
/// (tsc TS1203 equivalent); policy is handled outside this syntax rewrite.
pub fn visitExportAssignment(self: *Transformer, node: Node) Error!NodeIndex {
    const new_expr = try self.visitNode(node.data.unary.operand);
    if (new_expr.isNone()) return .none;

    const module_id = try es_helpers.makeIdentifierRef(self, "module");
    const exports_id = try es_helpers.makeIdentifierRef(self, "exports");
    const member = try es_helpers.makeStaticMember(self, module_id, exports_id, node.span);
    return es_helpers.makeAssignStmt(self, member, new_expr, node.span, 0);
}

/// ts_module_declaration: binary = { left=name, right=body_or_inner, flags }
/// flags=1: ambient module declaration (`declare module "*.css" { ... }`) -> strip.
/// flags=0: namespace with runtime output; codegen emits the IIFE.
pub fn visitNamespaceDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    if (node.data.binary.flags == 1) return .none;

    const new_name = try self.visitNode(node.data.binary.left);
    const new_body = try self.visitNode(node.data.binary.right);
    if (new_body.isNone()) return .none;

    const body_node = self.ast.getNode(new_body);
    if ((body_node.tag == .block_statement or body_node.tag == .ts_module_block) and body_node.data.list.len == 0) {
        return .none;
    }

    return self.ast.addNode(.{
        .tag = .ts_module_declaration,
        .span = node.span,
        .data = .{ .binary = .{ .left = new_name, .right = new_body, .flags = 0 } },
    });
}
