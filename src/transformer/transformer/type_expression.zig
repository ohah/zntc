//! Type-expression visitor helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// TS/Flow expression wrappers keep only their runtime operand when type stripping is enabled.
pub fn visitTsExpression(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(idx);
    if (!self.options.strip_types) {
        return self.copyNodeDirect(idx);
    }
    const operand = node.data.unary.operand;
    if (node.tag == .ts_type_assertion and !operand.isNone()) {
        const op_node = self.ast.getNode(operand);
        if (op_node.tag == .parenthesized_expression and !op_node.data.unary.operand.isNone()) {
            const inner = self.ast.getNode(op_node.data.unary.operand);
            if (inner.tag != .sequence_expression) {
                return self.visitNode(op_node.data.unary.operand);
            }
        }
    }
    return self.visitNode(operand);
}
