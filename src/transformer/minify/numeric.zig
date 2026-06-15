//! Numeric literal parsing and folding helpers for the minify pass.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../../lexer/token.zig").Span;
const Kind = @import("../../lexer/token.zig").Kind;

/// f64 → i32 (ToInt32, ECMAScript 7.1.6)
fn toI32(val: f64) i32 {
    if (std.math.isNan(val) or std.math.isInf(val) or val == 0) return 0;
    const i: i64 = @intFromFloat(@mod(@trunc(val), 4294967296.0));
    return @truncate(i);
}

fn toF64Bitwise(val: i32) f64 {
    return @floatFromInt(val);
}

/// 숫자 리터럴의 값을 파싱한다. codegen은 span 텍스트를 직접 출력하므로
/// number_bytes가 아닌 소스 텍스트에서 파싱해야 한다.
pub fn parseLiteral(ast: *const Ast, node: Node) ?f64 {
    return ast_mod.parseNumericText(ast.getText(node.span));
}

/// 숫자를 문자열로 포맷하여 string_table에 추가하고 span을 반환한다.
///
/// Infinity / NaN 은 JS 숫자 리터럴이 아니므로(`{d}` 가 `inf`/`nan` 을 내뱉음)
/// fold 를 포기한다(null). 모든 fold 경로가 이 함수의 null 을 "폴딩 안 함"
/// 으로 처리하므로 원본 식이 그대로 유지되어 semantic-preserving 이 보장된다.
pub fn formatNumber(ast: *Ast, value: f64) ?Span {
    if (!std.math.isFinite(value)) return null;
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return null;
    return ast.addString(text) catch null;
}

pub fn foldBinary(ast: *const Ast, left: Node, right: Node, op: Kind) ?f64 {
    const a = parseLiteral(ast, left) orelse return null;
    const b = parseLiteral(ast, right) orelse return null;

    return foldValues(a, b, op);
}

pub fn foldValues(a: f64, b: f64, op: Kind) ?f64 {
    return switch (op) {
        .plus => a + b,
        .minus => a - b,
        .star => a * b,
        .slash => if (b != 0) a / b else null,
        .percent => if (b != 0) @mod(a, b) else null,
        .star2 => std.math.pow(f64, a, b),
        .pipe => toF64Bitwise(toI32(a) | toI32(b)),
        .amp => toF64Bitwise(toI32(a) & toI32(b)),
        .caret => toF64Bitwise(toI32(a) ^ toI32(b)),
        else => null,
    };
}

fn evalLiteralExpression(ast: *const Ast, root: NodeIndex, saw_binary: *bool, depth: u32) ?f64 {
    if (root.isNone() or depth > 64) return null;
    const raw: u32 = @intFromEnum(root);
    if (raw >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[raw];
    return switch (node.tag) {
        .numeric_literal => parseLiteral(ast, node),
        .parenthesized_expression => evalLiteralExpression(ast, node.data.unary.operand, saw_binary, depth + 1),
        .binary_expression => blk: {
            saw_binary.* = true;
            const left = evalLiteralExpression(ast, node.data.binary.left, saw_binary, depth + 1) orelse break :blk null;
            const right = evalLiteralExpression(ast, node.data.binary.right, saw_binary, depth + 1) orelse break :blk null;
            const op: Kind = @enumFromInt(node.data.binary.flags);
            break :blk foldValues(left, right, op);
        },
        else => null,
    };
}

inline fn spanByteLen(span: Span) u32 {
    const start = span.start & ~ast_mod.Ast.STRING_TABLE_BIT;
    const end = span.end & ~ast_mod.Ast.STRING_TABLE_BIT;
    return end -| start;
}

/// Fold a standalone numeric-literal expression root in place.
///
/// Tree-shaking uses this for exported numeric seeds where only the initializer
/// and const metadata need to change. It intentionally mirrors `foldBinary`'s
/// size guard so the fast path does not introduce output growth compared with
/// the regular minify pass.
pub fn foldLiteralExpression(ast: *Ast, root: NodeIndex) ?Span {
    if (root.isNone()) return null;
    const raw: u32 = @intFromEnum(root);
    if (raw >= ast.nodes.items.len) return null;

    var saw_binary = false;
    const value = evalLiteralExpression(ast, root, &saw_binary, 0) orelse return null;
    if (!saw_binary) return null;

    const new_span = formatNumber(ast, value) orelse return null;
    const old_node = ast.nodes.items[raw];
    if (spanByteLen(new_span) > spanByteLen(old_node.span)) return null;

    ast.nodes.items[raw] = .{
        .tag = .numeric_literal,
        .span = new_span,
        .data = .{ .none = 0 },
    };
    return new_span;
}
