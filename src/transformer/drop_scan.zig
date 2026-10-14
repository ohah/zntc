//! AST-only checks shared by drop transforms and graph pre-pass selection.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Node = ast_mod.Node;

/// Check the graph-prepass drop options in one AST walk. These options are
/// independent; any matching statement requires the graph transform pre-pass.
pub fn hasDroppedTransformStatement(
    ast: *const ast_mod.Ast,
    drop_console: bool,
    drop_debugger: bool,
    labels: []const []const u8,
) bool {
    if (!drop_console and !drop_debugger and labels.len == 0) return false;

    for (ast.nodes.items) |node| {
        if (drop_console and node.tag == .expression_statement and isConsoleCallInAst(ast, node)) return true;
        if (drop_debugger and node.tag == .debugger_statement) return true;
        if (labels.len != 0 and node.tag == .labeled_statement and isDroppedLabel(ast, node, labels)) return true;
    }
    return false;
}

pub fn isDroppedLabel(ast: *const ast_mod.Ast, node: Node, labels: []const []const u8) bool {
    if (node.tag != .labeled_statement) return false;
    const label_index = node.data.binary.left;
    if (label_index.isNone() or @as(usize, @intFromEnum(label_index)) >= ast.nodes.items.len) return false;
    const label_node = ast.getNode(label_index);
    const label_name = ast.getText(label_node.span);
    for (labels) |label| {
        if (Scanner.identifierNamesEqual(label_name, label)) return true;
    }
    return false;
}

/// expression_statement가 console.* 호출인지 판별.
/// console.log(...), console.warn(...), console.error(...) 등.
pub fn isConsoleCallInAst(ast: *const ast_mod.Ast, node: Node) bool {
    if (node.tag != .expression_statement) return false;

    // expression_statement -> unary.operand가 call_expression이어야 함
    const expr_idx = node.data.unary.operand;
    if (expr_idx.isNone()) return false;
    const expr = ast.getNode(expr_idx);
    if (expr.tag != .call_expression) return false;

    // call_expression: extra = [callee, args_start, args_len, flags]
    const ce = expr.data.extra;
    if (ce >= ast.extra_data.items.len) return false;
    const callee_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[ce]);
    if (callee_idx.isNone()) return false;
    const callee = ast.getNode(callee_idx);

    // callee가 static_member_expression (console.log)이어야 함
    if (callee.tag != .static_member_expression) return false;

    // left가 identifier "console"
    const me = callee.data.extra;
    if (me >= ast.extra_data.items.len) return false;
    const obj_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[me]);
    if (obj_idx.isNone()) return false;
    const obj = ast.getNode(obj_idx);
    if (obj.tag != .identifier_reference) return false;

    return std.mem.eql(u8, ast.getText(obj.data.string_ref), "console");
}
