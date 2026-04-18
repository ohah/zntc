//! ZTS AST Constant Folding & Dead Branch Elimination
//!
//! transformer 완료 후 ast를 in-place 수정. bundler/emitter가 항상 호출(#1552).
//! `--define`으로 주입된 상수 비교/리터럴 분기 정리가 `--minify` 없이도 동작해야
//! rolldown/esbuild와 같은 DCE 효과가 난다.
//!
//! 하는 일:
//!   - 이항/단항 상수 폴딩: 1+2→3, "a"+"b"→"ab", !true→false, typeof "x"→"string"
//!   - 엄격 비교: 1===1→true, "a"==="b"→false
//!   - 논리 단락: true && x → x, false || x → x, null ?? x → x
//!   - if / while / ?: dead branch 제거
//!   - sequence/comma 정리
//!
//! 하지 않는 것: 식별자 mangling, 주석 제거 (별도 --minify / codegen peephole 영역).
//!
//! 참고:
//!   - oxc peephole/fold_constants.rs
//!   - esbuild js_ast_helpers.go (ShouldFoldBinaryOperatorWhenMinifying)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;
const Kind = @import("../lexer/token.zig").Kind;

/// f64 → i32 (ToInt32, ECMAScript 7.1.6)
fn toI32(val: f64) i32 {
    if (std.math.isNan(val) or std.math.isInf(val) or val == 0) return 0;
    // 범위 외 값은 wrapping
    const i: i64 = @intFromFloat(@mod(@trunc(val), 4294967296.0));
    return @truncate(i);
}

fn toF64Bitwise(val: i32) f64 {
    return @floatFromInt(val);
}

/// 숫자 리터럴의 값을 파싱한다. codegen은 span 텍스트를 직접 출력하므로
/// number_bytes가 아닌 소스 텍스트에서 파싱해야 한다.
fn parseNumericLiteral(ast: *const Ast, node: Node) ?f64 {
    const text = ast.getText(node.span);
    if (text.len == 0) return null;
    // 0x, 0o, 0b prefix
    if (text.len >= 2 and text[0] == '0') {
        if (text[1] == 'x' or text[1] == 'X') return parseHex(text[2..]);
        if (text[1] == 'o' or text[1] == 'O') return parseOct(text[2..]);
        if (text[1] == 'b' or text[1] == 'B') return parseBin(text[2..]);
    }
    return std.fmt.parseFloat(f64, text) catch null;
}

fn parseHex(text: []const u8) ?f64 {
    const v = std.fmt.parseInt(u64, text, 16) catch return null;
    return @floatFromInt(v);
}

fn parseOct(text: []const u8) ?f64 {
    const v = std.fmt.parseInt(u64, text, 8) catch return null;
    return @floatFromInt(v);
}

fn parseBin(text: []const u8) ?f64 {
    const v = std.fmt.parseInt(u64, text, 2) catch return null;
    return @floatFromInt(v);
}

/// 따옴표를 포함한 문자열 리터럴을 string_table에 추가한다.
fn makeQuotedString(ast: *Ast, text: []const u8) ?Span {
    var buf: [256]u8 = undefined;
    if (text.len + 2 > buf.len) return null;
    buf[0] = '"';
    @memcpy(buf[1 .. 1 + text.len], text);
    buf[1 + text.len] = '"';
    return ast.addString(buf[0 .. text.len + 2]) catch null;
}

/// 숫자를 문자열로 포맷하여 string_table에 추가하고 span을 반환한다.
fn formatNumber(ast: *Ast, value: f64) ?Span {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return null;
    return ast.addString(text) catch null;
}

/// `(expr)` 래핑을 재귀적으로 벗겨 실제 노드를 반환.
/// parenthesized_expression는 semantic상 투명이므로 타입 판별/치환 전에 unwrap.
fn unwrapParens(ast: *const Ast, node: Node) Node {
    var cur = node;
    while (cur.tag == .parenthesized_expression) {
        const inner_ni: u32 = @intFromEnum(cur.data.unary.operand);
        if (inner_ni >= ast.nodes.items.len) break;
        cur = ast.nodes.items[inner_ni];
    }
    return cur;
}

/// 노드가 boolean primitive를 반환함이 정적으로 보장되는지 판별.
/// `!!x → x` / `x === true → x` 류 축약에서 operand 타입 가드로 사용한다.
/// 증명 못 하면 false — 축약을 거부해 semantic 보존 (#1577).
///
/// 참고:
///   - oxc: peephole/minimize_not_expression.rs — `value_type().is_boolean()`
///   - esbuild: js_ast_helpers.go — `KnownPrimitiveType() == PrimitiveBoolean`
///   - swc: compress/optimize/ops.rs — `get_type() == Known(Type::Bool)`
fn isGuaranteedBoolean(ast: *const Ast, node: Node) bool {
    const inner = unwrapParens(ast, node);
    return switch (inner.tag) {
        .boolean_literal => true,
        .unary_expression => blk: {
            const e = inner.data.extra;
            if (e + 1 >= ast.extra_data.items.len) break :blk false;
            const op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[e + 1])));
            break :blk switch (op) {
                .bang, .kw_delete => true,
                else => false,
            };
        },
        .binary_expression => blk: {
            const op: Kind = @enumFromInt(inner.data.binary.flags);
            break :blk switch (op) {
                .eq3, .neq2, .eq2, .neq, .l_angle, .r_angle, .lt_eq, .gt_eq, .kw_in, .kw_instanceof => true,
                else => false,
            };
        },
        else => false,
    };
}

/// AST minify 패스를 실행한다. ast를 in-place 수정.
pub fn minify(ast: *Ast) void {
    for (ast.nodes.items, 0..) |node, i| {
        switch (node.tag) {
            .binary_expression => foldBinary(ast, @intCast(i), node),
            .logical_expression => foldLogical(ast, @intCast(i), node),
            .unary_expression => foldUnary(ast, @intCast(i), node),
            .conditional_expression => foldConditional(ast, @intCast(i), node),
            .if_statement => foldIf(ast, @intCast(i), node),
            .while_statement => foldWhile(ast, @intCast(i), node),
            .sequence_expression => simplifySequence(ast, @intCast(i), node),
            else => {},
        }
    }
}

// ================================================================
// Constant Folding — Binary Expression
// ================================================================

fn foldBinary(ast: *Ast, node_idx: u32, node: Node) void {
    const left_ni = @intFromEnum(node.data.binary.left);
    const right_ni = @intFromEnum(node.data.binary.right);
    if (left_ni >= ast.nodes.items.len or right_ni >= ast.nodes.items.len) return;

    const left = ast.nodes.items[left_ni];
    const right = ast.nodes.items[right_ni];
    const op: Kind = @enumFromInt(node.data.binary.flags);

    // 비교 연산 (산술보다 먼저 — 숫자 === 숫자도 여기서 처리)
    if (op == .eq3 or op == .neq2) {
        // x === true → x, x === false → !x (한쪽만 boolean이면 축약)
        if (simplifyBooleanComparison(ast, node_idx, left, right, left_ni, right_ni, op)) return;

        if (foldStrictEquality(ast, left, right)) |result| {
            const value = if (op == .neq2) !result else result;
            const text = if (value) "true" else "false";
            if (ast.addString(text)) |span| {
                ast.nodes.items[node_idx] = .{
                    .tag = .boolean_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                };
            } else |_| {}
        }
        return;
    }

    // 숫자 산술
    if (left.tag == .numeric_literal and right.tag == .numeric_literal) {
        if (foldNumericBinary(ast, left, right, op)) |result| {
            if (formatNumber(ast, result)) |new_span| {
                const orig_len = (node.span.end & ~ast_mod.Ast.STRING_TABLE_BIT) -| (node.span.start & ~ast_mod.Ast.STRING_TABLE_BIT);
                const new_len = (new_span.end & ~ast_mod.Ast.STRING_TABLE_BIT) -| (new_span.start & ~ast_mod.Ast.STRING_TABLE_BIT);
                if (new_len <= orig_len) {
                    ast.nodes.items[node_idx] = .{
                        .tag = .numeric_literal,
                        .span = new_span,
                        .data = .{ .none = 0 },
                    };
                }
            }
        }
        return;
    }

    // 문자열 연결 (+ 연산자만)
    if (left.tag == .string_literal and right.tag == .string_literal and op == .plus) {
        foldStringConcat(ast, node_idx, left, right);
        return;
    }
}

fn foldNumericBinary(ast: *const Ast, left: Node, right: Node, op: Kind) ?f64 {
    const a = parseNumericLiteral(ast, left) orelse return null;
    const b = parseNumericLiteral(ast, right) orelse return null;

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

fn foldStringConcat(ast: *Ast, node_idx: u32, left: Node, right: Node) void {
    const left_text = ast.getText(left.span);
    const right_text = ast.getText(right.span);

    // escape 규칙이 동일한 경우만 concat — 양쪽 모두 같은 quote char(`"` / `'` / backtick)여야.
    // 다른 quote를 합치면 내부 escape 변환 필요(예: `'..."x"...'`를 double quote로 재포장하면
    // `"`를 `\"`로 바꿔야 hermesc 같은 엄격 파서 통과). 재escape 비용 대신 fold 포기가 안전.
    // 같은 quote끼리는 내부 텍스트가 이미 해당 quote에 대해 escape 되어 있어 그대로 합쳐도 OK.
    const lq = detectQuote(left_text) orelse return;
    const rq = detectQuote(right_text) orelse return;
    if (lq != rq) return;

    const a = left_text[1 .. left_text.len - 1];
    const b = right_text[1 .. right_text.len - 1];

    var buf: [4096]u8 = undefined;
    if (a.len + b.len + 2 > buf.len) return;
    buf[0] = lq;
    @memcpy(buf[1 .. 1 + a.len], a);
    @memcpy(buf[1 + a.len .. 1 + a.len + b.len], b);
    buf[1 + a.len + b.len] = lq;
    const total = 2 + a.len + b.len;

    const span = ast.addString(buf[0..total]) catch return;
    ast.nodes.items[node_idx] = .{
        .tag = .string_literal,
        .span = span,
        .data = .{ .none = 0 },
    };
}

/// 문자열 리터럴의 quote char — `"` / `'` / backtick. 리터럴 형식이 아니면 null.
fn detectQuote(text: []const u8) ?u8 {
    if (text.len < 2) return null;
    const q = text[0];
    if (q != '"' and q != '\'' and q != '`') return null;
    if (text[text.len - 1] != q) return null;
    return q;
}

fn stripQuotes(text: []const u8) []const u8 {
    if (text.len >= 2) {
        if ((text[0] == '"' or text[0] == '\'' or text[0] == '`') and text[text.len - 1] == text[0]) {
            return text[1 .. text.len - 1];
        }
    }
    return text;
}

/// x === true → x, x === false → !x, x !== true → !x, x !== false → x
/// 한쪽이 boolean 리터럴이고 다른 쪽이 non-literal이면 축약.
fn simplifyBooleanComparison(
    ast: *Ast,
    node_idx: u32,
    left: Node,
    right: Node,
    left_ni: u32,
    right_ni: u32,
    op: Kind,
) bool {
    // 어느 쪽이 boolean 리터럴인지 판별
    const bool_val: ?bool = if (left.tag == .boolean_literal)
        getBoolValue(ast, left)
    else if (right.tag == .boolean_literal)
        getBoolValue(ast, right)
    else
        null;
    const bv = bool_val orelse return false;

    // 양쪽 다 리터럴이면 foldStrictEquality에서 처리 (여기서는 축약하지 않음)
    const other_ni = if (left.tag == .boolean_literal) right_ni else left_ni;
    const other_raw = ast.nodes.items[other_ni];
    if (other_raw.tag == .boolean_literal or other_raw.tag == .numeric_literal or
        other_raw.tag == .string_literal or other_raw.tag == .null_literal) return false;

    // other가 boolean임이 보장되지 않으면 축약 거부 — `y === true` 와 `y`는 다르다
    // (y=1일 때 y===true는 false, y는 1). `!!x`와 같은 이유로 #1577에서 가드.
    const other = unwrapParens(ast, other_raw);
    if (!isGuaranteedBoolean(ast, other)) return false;

    // x === true → x, x === false → !x
    // x !== true → !x, x !== false → x
    const need_negate = (op == .eq3 and !bv) or (op == .neq2 and bv);

    if (need_negate) {
        // !x — unary_expression을 새로 만들어야 하는데, in-place 수정으로는
        // extra_data에 추가가 필요. addExtra가 실패할 수 있으므로 try 없이 catch 처리.
        const operand_extra = ast.addExtra(other_ni) catch return false;
        _ = ast.addExtra(@intFromEnum(Kind.bang)) catch return false;
        ast.nodes.items[node_idx] = .{
            .tag = .unary_expression,
            .span = ast.nodes.items[node_idx].span,
            .data = .{ .extra = operand_extra },
        };
    } else {
        // x 그대로
        ast.nodes.items[node_idx] = other;
    }
    return true;
}

fn foldStrictEquality(ast: *const Ast, left: Node, right: Node) ?bool {
    // 숫자 === 숫자
    if (left.tag == .numeric_literal and right.tag == .numeric_literal) {
        const a = parseNumericLiteral(ast, left) orelse return null;
        const b = parseNumericLiteral(ast, right) orelse return null;
        if (std.math.isNan(a) or std.math.isNan(b)) return false;
        return a == b;
    }
    // boolean === boolean
    if (left.tag == .boolean_literal and right.tag == .boolean_literal) {
        const a = getBoolValue(ast, left);
        const b = getBoolValue(ast, right);
        if (a != null and b != null) return a.? == b.?;
    }
    // null === null
    if (left.tag == .null_literal and right.tag == .null_literal) return true;
    // string === string
    if (left.tag == .string_literal and right.tag == .string_literal) {
        const a = stripQuotes(ast.getText(left.span));
        const b = stripQuotes(ast.getText(right.span));
        return std.mem.eql(u8, a, b);
    }
    return null;
}

// ================================================================
// Constant Folding — Unary Expression
// ================================================================

fn foldUnary(ast: *Ast, node_idx: u32, node: Node) void {
    const e = node.data.extra;
    if (e + 1 >= ast.extra_data.items.len) return;
    const operand_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
    const op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[e + 1])));
    const operand_ni = @intFromEnum(operand_idx);
    if (operand_ni >= ast.nodes.items.len) return;
    const operand = ast.nodes.items[operand_ni];

    switch (op) {
        .bang => {
            // !!x → x — inner operand가 이미 boolean일 때만 안전 (#1577).
            // 예: !!(a === b) → a === b. 그러나 !!variable은 ToBoolean 강제변환이
            // 사라지므로 유지해야 함 (undefined/null/0 → false 보존).
            if (operand.tag == .unary_expression) {
                const inner_e = operand.data.extra;
                if (inner_e + 1 < ast.extra_data.items.len) {
                    const inner_op: Kind = @enumFromInt(@as(u8, @truncate(ast.extra_data.items[inner_e + 1])));
                    if (inner_op == .bang) {
                        const inner_operand_ni = ast.extra_data.items[inner_e];
                        if (inner_operand_ni < ast.nodes.items.len) {
                            const unwrapped = unwrapParens(ast, ast.nodes.items[inner_operand_ni]);
                            if (isGuaranteedBoolean(ast, unwrapped)) {
                                ast.nodes.items[node_idx] = unwrapped;
                                return;
                            }
                        }
                    }
                }
            }
            // !true → false, !false → true, !0 → true, !1 → false
            if (evalTruthiness(ast, operand)) |truthy| {
                const text = if (!truthy) "true" else "false";
                if (ast.addString(text)) |span| {
                    ast.nodes.items[node_idx] = .{
                        .tag = .boolean_literal,
                        .span = span,
                        .data = .{ .none = 0 },
                    };
                } else |_| {}
            }
        },
        .kw_typeof => {
            // typeof "str" → "string", typeof 42 → "number", typeof true → "boolean"
            // typeof null → "object", typeof undefined → "undefined"
            if (foldTypeof(ast, operand)) |type_str| {
                if (makeQuotedString(ast, type_str)) |span| {
                    ast.nodes.items[node_idx] = .{
                        .tag = .string_literal,
                        .span = span,
                        .data = .{ .none = 0 },
                    };
                }
            }
        },
        .minus => {
            // -리터럴 → 음수 리터럴 (-1 → numeric_literal(-1))
            if (operand.tag == .numeric_literal) {
                if (parseNumericLiteral(ast, operand)) |val| {
                    if (formatNumber(ast, -val)) |span| {
                        ast.nodes.items[node_idx] = .{
                            .tag = .numeric_literal,
                            .span = span,
                            .data = .{ .none = 0 },
                        };
                    }
                }
            }
        },
        .plus => {
            // +리터럴 → 그대로 (불필요한 단항 + 제거)
            if (operand.tag == .numeric_literal) {
                ast.nodes.items[node_idx] = operand;
            }
        },
        .kw_void => {
            // void 0 → undefined는 minify에서 하지 않음 (codegen에서 처리)
        },
        else => {},
    }
}

// ================================================================
// Helpers
// ================================================================

/// 노드의 truthiness를 정적으로 평가한다. 결정 불가능하면 null.
fn evalTruthiness(ast: *const Ast, node: Node) ?bool {
    return switch (node.tag) {
        .boolean_literal => getBoolValue(ast, node),
        .numeric_literal => blk: {
            const val = parseNumericLiteral(ast, node) orelse break :blk null;
            if (std.math.isNan(val)) break :blk false;
            break :blk val != 0;
        },
        .null_literal => false,
        .string_literal => blk: {
            const text = stripQuotes(ast.getText(node.span));
            break :blk text.len > 0;
        },
        .identifier_reference => blk: {
            const text = ast.getText(node.span);
            if (std.mem.eql(u8, text, "undefined")) break :blk false;
            if (std.mem.eql(u8, text, "NaN")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

fn getBoolValue(ast: *const Ast, node: Node) ?bool {
    if (node.tag != .boolean_literal) return null;
    const text = ast.getText(node.span);
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

fn foldTypeof(ast: *const Ast, operand: Node) ?[]const u8 {
    return switch (operand.tag) {
        .string_literal => "string",
        .numeric_literal => "number",
        .boolean_literal => "boolean",
        .null_literal => "object",
        .identifier_reference => blk: {
            const text = ast.getText(operand.span);
            if (std.mem.eql(u8, text, "undefined")) break :blk "undefined";
            break :blk null;
        },
        .function_expression, .arrow_function_expression => "function",
        else => null,
    };
}

// ================================================================
// Phase 2: Dead Code Elimination
// ================================================================

/// conditional_expression: false ? a : b → b, true ? a : b → a
fn foldConditional(ast: *Ast, node_idx: u32, node: Node) void {
    const cond_ni = @intFromEnum(node.data.ternary.a);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    // 조건이 상수이면 선택된 분기로 교체
    const kept = if (truthy) node.data.ternary.b else node.data.ternary.c;
    const kept_ni = @intFromEnum(kept);
    if (kept_ni >= ast.nodes.items.len) return;
    ast.nodes.items[node_idx] = ast.nodes.items[kept_ni];
}

/// if_statement: if (false) { A } else { B } → B, if (true) { A } → A
fn foldIf(ast: *Ast, node_idx: u32, node: Node) void {
    const cond_ni = @intFromEnum(node.data.ternary.a);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    if (truthy) {
        // if (true) { A } → A (then 분기)
        const then_ni = @intFromEnum(node.data.ternary.b);
        if (then_ni >= ast.nodes.items.len) return;
        ast.nodes.items[node_idx] = ast.nodes.items[then_ni];
    } else {
        // if (false) { A } else { B } → B (else 분기가 있으면)
        if (!node.data.ternary.c.isNone()) {
            const else_ni = @intFromEnum(node.data.ternary.c);
            if (else_ni >= ast.nodes.items.len) return;
            ast.nodes.items[node_idx] = ast.nodes.items[else_ni];
        } else {
            // if (false) { A } → empty_statement
            ast.nodes.items[node_idx] = .{
                .tag = .empty_statement,
                .span = node.span,
                .data = .{ .none = 0 },
            };
        }
    }
}

/// while (false) { ... } → empty_statement
fn foldWhile(ast: *Ast, node_idx: u32, node: Node) void {
    const cond_ni = @intFromEnum(node.data.binary.left);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    if (!truthy) {
        ast.nodes.items[node_idx] = .{
            .tag = .empty_statement,
            .span = node.span,
            .data = .{ .none = 0 },
        };
    }
}

/// logical_expression: true && x → x, false && x → false, true || x → true, false || x → x
fn foldLogical(ast: *Ast, node_idx: u32, node: Node) void {
    const left_ni = @intFromEnum(node.data.binary.left);
    if (left_ni >= ast.nodes.items.len) return;
    const left = ast.nodes.items[left_ni];
    const op: Kind = @enumFromInt(node.data.binary.flags);

    const truthy = evalTruthiness(ast, left) orelse return;

    switch (op) {
        .amp2 => { // &&
            if (truthy) {
                // true && x → x
                const right_ni = @intFromEnum(node.data.binary.right);
                if (right_ni >= ast.nodes.items.len) return;
                ast.nodes.items[node_idx] = ast.nodes.items[right_ni];
            } else {
                // false && x → false (left 값 유지)
                ast.nodes.items[node_idx] = left;
            }
        },
        .pipe2 => { // ||
            if (truthy) {
                // true || x → true (left 값 유지)
                ast.nodes.items[node_idx] = left;
            } else {
                // false || x → x
                const right_ni = @intFromEnum(node.data.binary.right);
                if (right_ni >= ast.nodes.items.len) return;
                ast.nodes.items[node_idx] = ast.nodes.items[right_ni];
            }
        },
        .question2 => { // ??
            // null ?? x → x, undefined ?? x → x
            if (left.tag == .null_literal) {
                const right_ni = @intFromEnum(node.data.binary.right);
                if (right_ni >= ast.nodes.items.len) return;
                ast.nodes.items[node_idx] = ast.nodes.items[right_ni];
            } else if (left.tag == .identifier_reference) {
                const text = ast.getText(left.span);
                if (std.mem.eql(u8, text, "undefined")) {
                    const right_ni = @intFromEnum(node.data.binary.right);
                    if (right_ni >= ast.nodes.items.len) return;
                    ast.nodes.items[node_idx] = ast.nodes.items[right_ni];
                }
            }
        },
        else => {},
    }
}

// ================================================================
// Phase 4: Comma Operator + Template Literal Folding
// ================================================================

/// sequence_expression (comma operator) 축약.
/// side-effect-free 리터럴만 있는 앞쪽 항목 제거: (0, foo) → foo
/// 단, 2개 항목이고 좌측이 리터럴인 경우만.
fn simplifySequence(ast: *Ast, node_idx: u32, node: Node) void {
    const list = node.data.list;
    if (list.len < 2) return;
    if (list.start + list.len > ast.extra_data.items.len) return;

    const indices = ast.extra_data.items[list.start .. list.start + list.len];

    // 마지막 항목 앞의 모든 side-effect-free 리터럴을 건너뛴다
    var first_kept: u32 = 0;
    while (first_kept + 1 < list.len) {
        const ni = indices[first_kept];
        if (ni >= ast.nodes.items.len) return;
        if (!isSideEffectFreeLiteral(ast.nodes.items[ni])) break;
        first_kept += 1;
    }

    if (first_kept == 0) return; // 제거할 항목 없음

    if (first_kept + 1 == list.len) {
        // 마지막 하나만 남음 → sequence 자체를 해당 노드로 교체
        const last_ni = indices[list.len - 1];
        if (last_ni >= ast.nodes.items.len) return;
        ast.nodes.items[node_idx] = ast.nodes.items[last_ni];
    } else {
        // 여러 개 남음 → list 시작점을 조정
        ast.nodes.items[node_idx].data = .{
            .list = .{ .start = list.start + first_kept, .len = list.len - first_kept },
        };
    }
}

fn isSideEffectFreeLiteral(node: Node) bool {
    return switch (node.tag) {
        .numeric_literal, .string_literal, .boolean_literal, .null_literal => true,
        else => false,
    };
}
