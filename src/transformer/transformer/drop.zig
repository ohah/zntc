//! Drop-option filters for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;

pub fn shouldDropNode(self: *const Transformer, node: Node) bool {
    if (self.options.drop_debugger and node.tag == .debugger_statement) return true;
    if (self.options.drop_console and node.tag == .expression_statement and isConsoleCall(self, node)) return true;
    if (self.options.drop_labels.len > 0 and node.tag == .labeled_statement) return hasDroppedLabel(self, node);
    return false;
}

/// expression_statement가 console.* 호출인지 판별.
/// console.log(...), console.warn(...), console.error(...) 등.
pub fn isConsoleCall(self: *const Transformer, node: Node) bool {
    // expression_statement -> unary.operand가 call_expression이어야 함
    const expr_idx = node.data.unary.operand;
    if (expr_idx.isNone()) return false;
    const expr = self.ast.getNode(expr_idx);
    if (expr.tag != .call_expression) return false;

    // call_expression: extra = [callee, args_start, args_len, flags]
    const ce = expr.data.extra;
    if (ce >= self.ast.extra_data.items.len) return false;
    const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
    if (callee_idx.isNone()) return false;
    const callee = self.ast.getNode(callee_idx);

    // callee가 static_member_expression (console.log)이어야 함
    if (callee.tag != .static_member_expression) return false;

    // left가 identifier "console" - extra = [object, property, flags]
    const me = callee.data.extra;
    if (me >= self.ast.extra_data.items.len) return false;
    const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
    if (obj_idx.isNone()) return false;
    const obj = self.ast.getNode(obj_idx);
    if (obj.tag != .identifier_reference) return false;

    const obj_text = self.ast.getText(obj.data.string_ref);
    return std.mem.eql(u8, obj_text, "console");
}

fn hasDroppedLabel(self: *const Transformer, node: Node) bool {
    const label_node = self.ast.getNode(node.data.binary.left);
    const label_name = self.ast.getText(label_node.span);
    for (self.options.drop_labels) |drop| {
        if (std.mem.eql(u8, label_name, drop)) return true;
    }
    return false;
}
