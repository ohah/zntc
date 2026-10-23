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
    if (label_index.isNone() or @as(usize, @backingInt(label_index)) >= ast.nodes.items.len) return false;
    const label_node = ast.getNode(label_index);
    const label_name = ast.getText(label_node.span);
    for (labels) |label| {
        if (Scanner.identifierNamesEqual(label_name, label)) return true;
    }
    return false;
}

/// expression_statement가 console.* 호출인지 판별.
/// console.log(...), console["log"](...), console.warn(...) 등.
pub fn isConsoleCallInAst(ast: *const ast_mod.Ast, node: Node) bool {
    if (node.tag != .expression_statement) return false;

    // expression_statement -> unary.operand가 call_expression이어야 함
    const expr_idx = node.data.unary.operand;
    if (expr_idx.isNone()) return false;
    const expr = ast.getNode(expr_idx);
    if (expr.tag != .call_expression) return false;

    // call_expression: extra = [callee, args_start, args_len, flags]
    const ce = expr.data.extra;
    if (ce > ast.extra_data.items.len or ast.extra_data.items.len - ce < 4) return false;
    const callee_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[ce]));
    if (callee_idx.isNone() or @as(usize, @backingInt(callee_idx)) >= ast.nodes.items.len) return false;
    const callee = ast.getNode(callee_idx);

    // 직접 member 호출만 대상으로 한다. 계산 멤버는 부작용 없는 string literal key만 허용한다.
    if (callee.tag != .static_member_expression and callee.tag != .computed_member_expression) return false;

    // left가 identifier "console"
    const me = callee.data.extra;
    if (me > ast.extra_data.items.len or ast.extra_data.items.len - me < 2) return false;
    const obj_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[me]));
    if (obj_idx.isNone() or @as(usize, @backingInt(obj_idx)) >= ast.nodes.items.len) return false;
    const obj = ast.getNode(obj_idx);
    if (obj.tag != .identifier_reference) return false;

    if (callee.tag == .computed_member_expression) {
        if (ast.extra_data.items.len - me < 3 or
            (ast.extra_data.items[me + 2] & ast_mod.MemberFlags.optional_chain) != 0) return false;
        const property_idx: ast_mod.NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[me + 1]));
        if (property_idx.isNone() or @as(usize, @backingInt(property_idx)) >= ast.nodes.items.len or
            ast.getNode(property_idx).tag != .string_literal) return false;
    }

    return std.mem.eql(u8, ast.getText(obj.data.string_ref), "console");
}
