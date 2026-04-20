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
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const Span = @import("../lexer/token.zig").Span;
const Kind = @import("../lexer/token.zig").Kind;
const symbol_mod = @import("../semantic/symbol.zig");
const scope_mod = @import("../semantic/scope.zig");
const purity = @import("../bundler/purity.zig");
const ast_walk = @import("../parser/ast_walk.zig");

/// Minify pass 컨텍스트. semantic 정보가 있을 때만 dead store 제거가 동작한다.
/// `symbols` 는 mutable slice — dead declaration 제거 시 init 내부 identifier reference 의
/// `reference_count` 를 감산하기 위해 필요하다 (stale 방지).
/// `scopes` 는 eval / with 포함 여부 조회용 (dynamic lookup 보호).
pub const MinifyCtx = struct {
    symbols: []symbol_mod.Symbol,
    symbol_ids: []const ?u32,
    scopes: []const scope_mod.Scope,
    unresolved_globals: ?*const purity.GlobalRefSet,

    /// semantic 없이 호출할 때 사용. dead store pass 는 skip 된다.
    pub const empty: MinifyCtx = .{
        .symbols = &.{},
        .symbol_ids = &.{},
        .scopes = &.{},
        .unresolved_globals = null,
    };

    /// semantic 정보 3축 (symbols / symbol_ids / scopes) 이 모두 채워졌는지 확인.
    /// scopes 누락 시 eval / with 가드가 silent 통과되어 직접 eval 스코프 안의 변수가
    /// 잘못 제거될 수 있으므로, 세 필드 모두 요구하는 all-or-nothing 계약.
    inline fn hasSemantic(self: MinifyCtx) bool {
        return self.symbols.len > 0 and self.symbol_ids.len > 0 and self.scopes.len > 0;
    }
};

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

/// fixed-point loop 반복 상한. oxc `PeepholeOptimizations::run_in_loop` 와 동일 값.
/// pathological AST 에서 무한 교환 (e.g. A↔B) 을 방지.
const max_fixpoint_iterations: u32 = 3;

/// 전체 노드 치환 + fixed-point 신호. fold / simplify 사이트가 반복적으로 쓰는 패턴.
inline fn replaceNode(ast: *Ast, idx: u32, new_node: Node, changed: *bool) void {
    ast.nodes.items[idx] = new_node;
    changed.* = true;
}

/// `inner_idx` 를 감싸는 새 `parenthesized_expression` 노드를 append 하고 그 NodeIndex 반환.
/// 실패 시 (OOM) `inner_idx` 를 그대로 반환 — 호출자가 grammar 위반이 발생할 수 있는 자리에
/// 이 결과를 넣으면 안 됨. 필요 시 호출자가 사전에 realloc 감수.
fn wrapInParen(ast: *Ast, inner_idx: NodeIndex) !NodeIndex {
    const inner_ni = @intFromEnum(inner_idx);
    const span = if (inner_ni < ast.nodes.items.len)
        ast.nodes.items[inner_ni].span
    else
        Span{ .start = 0, .end = 0 };
    const new_ni: u32 = @intCast(ast.nodes.items.len);
    try ast.nodes.append(ast.allocator, .{
        .tag = .parenthesized_expression,
        .span = span,
        .data = .{ .unary = .{ .operand = inner_idx, .flags = 0 } },
    });
    return @enumFromInt(new_ni);
}

/// AST minify 패스를 실행한다. ast를 in-place 수정.
/// `ctx` 에 semantic 정보가 있으면 dead store (unused declaration) 제거도 함께 수행.
///
/// **Fixed-point loop** (#1650): constant fold → simplify → dead store 가 서로의 제거
/// 기회를 만들기 때문에 (`let y = 1 + 2; let x = y;` → 1 iter: fold + x dead, y.ref 감산
/// → 2 iter: y dead), `runOnce` 를 변경 없을 때까지 반복한다.
pub fn minify(ast: *Ast, ctx: MinifyCtx) void {
    // for-loop binding 은 fold passes 가 새로 만들지 않아 iter-invariant — 미리 1회만 수집.
    var skip_for_binding: ?std.DynamicBitSet = null;
    defer if (skip_for_binding) |*b| b.deinit();
    if (ctx.hasSemantic()) {
        skip_for_binding = std.DynamicBitSet.initEmpty(ast.allocator, ast.nodes.items.len) catch null;
        if (skip_for_binding) |*b| markForLoopBindings(ast, b);
    }

    var i: u32 = 0;
    while (i < max_fixpoint_iterations) : (i += 1) {
        const skip_ptr: ?*const std.DynamicBitSet = if (skip_for_binding) |*b| b else null;
        if (!runOnce(ast, ctx, skip_ptr)) break;
    }
}

/// minify 1 iteration. 변경이 있었으면 true 반환 (fixed-point 종료 판정용).
/// `changed` 는 보수적 true 허용 — 실제 mutation 없이 true 설정해도 최악 1 iter 더 돌고 끝.
///
/// **Index-based loop**: rewrite 중 `ast.nodes.append` (e.g. paren 노드 생성) 로
/// items slice 가 재할당되어도 안전 — 매 iter `ast.nodes.items[i]` 재슬라이스.
/// 새로 append 된 노드는 `items.len` 증가로 자동 순회됨.
fn runOnce(ast: *Ast, ctx: MinifyCtx, skip_for_binding: ?*const std.DynamicBitSet) bool {
    var changed = false;
    var i: u32 = 0;
    while (i < ast.nodes.items.len) : (i += 1) {
        const node = ast.nodes.items[i];
        switch (node.tag) {
            .binary_expression => foldBinary(ast, i, node, &changed),
            .logical_expression => foldLogical(ast, i, node, &changed),
            .unary_expression => foldUnary(ast, i, node, &changed),
            .conditional_expression => foldConditional(ast, i, node, &changed),
            .if_statement => foldIf(ast, i, node, &changed),
            .while_statement => foldWhile(ast, i, node, &changed),
            .sequence_expression => simplifySequence(ast, ctx, i, node, &changed),
            // PR1.5 (a): unused expression statement 축약 — semantic 정보 있을 때만
            // (symbol_ids 가 없으면 identifier local binding 판정 불가)
            .expression_statement => if (ctx.hasSemantic()) simplifyUnusedExprStmt(ast, ctx, i, node, &changed),
            else => {},
        }
    }
    if (ctx.hasSemantic()) {
        removeDeadStores(ast, ctx, skip_for_binding, &changed);
    }
    return changed;
}

// ================================================================
// Dead Store Elimination — Unused Declaration (#1644 PR1)
// ================================================================
//
// 제거 조건 (모두 만족):
//   - `var` / `let` / `const` 의 **단일** `binding_identifier` declarator
//   - symbol 의 `scope_id != 0` (함수/블록 local 만) — top-level 은 tree-shaker 영역
//   - `reference_count == 0` and `write_count == 0`
//   - `is_exported` / `is_default_export` 둘 다 false
//   - init 이 없거나 `purity.isExprPure` 가 true
//
// 제외:
//   - top-level (module scope) 선언     — tree-shaker 가 커버, 중복 제거는 fixture 회귀
//   - `using` / `await using`           — `[Symbol.dispose]` 호출이 side-effect
//   - destructuring / non-identifier    — pattern 은 간접 getter 호출 가능
//   - declarator 2개 이상               — 부분 제거는 PR 범위 밖 (복잡도)
//   - init 이 불순                      — "강등" (→ expression_statement) 은 PR1.5
//
// 제거 시 init expression 내 모든 identifier_reference 의 `reference_count` 를
// 감산해 semantic scalar 와의 정합성을 유지한다 — fixed-point loop 의 다음 iter 가
// 연쇄 dead 탐지를 위해 정확한 ref_count 를 필요로 한다.

/// `skip_for_binding` 은 `minify` 가 1회 수집해 모든 iter 에 공유 — fold passes 가
/// for-loop 을 새로 만들지 않아 재계산 불필요. null 이면 (OOM) 보수적으로 전부 skip.
fn removeDeadStores(ast: *Ast, ctx: MinifyCtx, skip_for_binding: ?*const std.DynamicBitSet, changed: *bool) void {
    const skip = skip_for_binding orelse return;

    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .variable_declaration) continue;
        if (skip.isSet(i)) continue;
        tryRemoveDeadDecl(ast, ctx, @intCast(i), node, changed);
    }
}

/// for-loop (for / for-in / for-of / for-await-of) 의 init/left 자리에 있는
/// variable_declaration 노드 인덱스를 bitset 에 set. 해당 binding 은 body 에서
/// 사용되지 않더라도 구문상 필수이므로 dead store 제거 대상이 아니다.
fn markForLoopBindings(ast: *const Ast, skip: *std.DynamicBitSet) void {
    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .for_statement => {
                // extra = [init, test, update, body] — init 이 자식 0
                const ei = node.data.extra;
                if (ei >= ast.extra_data.items.len) continue;
                const raw = ast.extra_data.items[ei];
                if (raw < ast.nodes.items.len and
                    ast.nodes.items[raw].tag == .variable_declaration)
                {
                    skip.set(raw);
                }
            },
            .for_in_statement, .for_of_statement, .for_await_of_statement => {
                // ternary: a = LHS (variable_declaration 또는 assignment target)
                const raw = @intFromEnum(node.data.ternary.a);
                if (raw < ast.nodes.items.len and
                    ast.nodes.items[raw].tag == .variable_declaration)
                {
                    skip.set(raw);
                }
            },
            else => {},
        }
    }
}

fn tryRemoveDeadDecl(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
    const kind = ast.variableDeclarationKind(node);
    // `using` / `await using`: Symbol.dispose 호출 side-effect → 보존
    if (kind.isUsing()) return;

    const extra = node.data.extra;
    if (extra + 2 >= ast.extra_data.items.len) return;
    const list_start = ast.extra_data.items[extra + 1];
    const list_len = ast.extra_data.items[extra + 2];
    // 단일 declarator 만 처리 (부분 제거는 PR 범위 밖)
    if (list_len != 1) return;
    if (list_start >= ast.extra_data.items.len) return;

    const decl_raw = ast.extra_data.items[list_start];
    if (decl_raw >= ast.nodes.items.len) return;
    const decl = ast.nodes.items[decl_raw];
    if (decl.tag != .variable_declarator) return;

    // variable_declarator: extra = [name, type_ann, init]
    const de = decl.data.extra;
    if (de + 2 >= ast.extra_data.items.len) return;
    const name_raw = ast.extra_data.items[de];
    const init_raw = ast.extra_data.items[de + 2];

    if (name_raw >= ast.nodes.items.len) return;
    const name_node = ast.nodes.items[name_raw];
    // 단일 binding_identifier 만 — destructuring/array/object pattern 제외
    if (name_node.tag != .binding_identifier) return;

    // symbol_ids[name_node_idx] → symbol index
    if (name_raw >= ctx.symbol_ids.len) return;
    const sym_id = ctx.symbol_ids[name_raw] orelse return;
    if (sym_id >= ctx.symbols.len) return;
    const sym = ctx.symbols[sym_id];

    // top-level (module scope=0) 는 tree-shaker 영역 — 여기서 지우면 bundle 경로의 entry
    // top-level 선언이 사라져 fixture 가 깨진다. 함수/블록 local 만 대상.
    const scope_idx = @intFromEnum(sym.scope_id);
    if (scope_idx == 0) return;

    // eval / with 스코프 안의 선언은 동적 lookup 대상이 될 수 있다. mangler 와 동일 보호
    // (Scope.blocksMangling — subtree_has_direct_eval / subtree_has_with).
    if (scope_idx < ctx.scopes.len and ctx.scopes[scope_idx].blocksMangling()) return;

    // exported binding 보호 — transpile 단독 경로는 tree-shaker 가 없어 직접 지키는 외엔 없다
    if (sym.decl_flags.is_exported or sym.decl_flags.is_default_export) return;

    // reference 가 있거나 다른 곳에서 쓰이면 dead 아님
    if (sym.reference_count != 0 or sym.write_count != 0) return;

    // init 이 있으면 purity 검사 — 불순하면 RHS 보존을 위해 (아직) 제거 불가
    const init_idx: NodeIndex = @enumFromInt(init_raw);
    if (!init_idx.isNone()) {
        if (!purity.isExprPure(ast, init_idx, ctx.unresolved_globals)) return;
        // init 내부의 pure identifier_reference 들의 reference_count 를 감산
        decrementRefsInExpr(ast, ctx, init_idx);
    }

    // variable_declaration 전체를 empty_statement 로 교체
    replaceNode(ast, node_idx, .{
        .tag = .empty_statement,
        .span = node.span,
        .data = .{ .none = 0 },
    }, changed);
}

/// expression 안의 모든 `identifier_reference` 노드를 찾아, symbol_ids 로 symbol 을
/// 역매핑해 `reference_count` 를 1 감산한다. init expression 은 RHS 이므로
/// assignment_target_identifier 는 등장하지 않아 read 경로만 처리.
fn decrementRefsInExpr(ast: *const Ast, ctx: MinifyCtx, idx: NodeIndex) void {
    if (idx.isNone()) return;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return;
    const node = ast.nodes.items[ni];

    if (node.tag == .identifier_reference) {
        if (ni < ctx.symbol_ids.len) {
            if (ctx.symbol_ids[ni]) |sid| {
                if (sid < ctx.symbols.len and ctx.symbols[sid].reference_count > 0) {
                    ctx.symbols[sid].reference_count -= 1;
                }
            }
        }
        return;
    }

    var it = ast_walk.children(ast, node);
    while (it.next()) |child| {
        decrementRefsInExpr(ast, ctx, child);
    }
}

/// 인접한 같은-kind `var`/`let`/`const` 선언을 단일 선언으로 병합한다 (#1588).
///
/// 반드시 tree-shaking **이후**에 호출해야 한다. 번들러는 `var A=1; var B=2;`에서
/// `B`만 tree-shake로 skip_nodes에 마킹하는데, merge가 이를 무시하면 B가 A와 합쳐져
/// tree-shaker가 단일 statement를 제거하지 못해 미사용 declarator가 최종 출력에 남는다.
/// `skip_nodes`가 주어지면 마킹된 statement는 merge 대상에서 제외해 tree-shaker 효과를 보존한다.
pub fn mergeDecls(ast: *Ast, skip_nodes: ?*const std.DynamicBitSet) void {
    for (ast.nodes.items, 0..) |node, i| {
        switch (node.tag) {
            .program, .block_statement, .function_body => mergeAdjacentDecls(ast, @intCast(i), node, skip_nodes),
            else => {},
        }
    }
}

// ================================================================
// Constant Folding — Binary Expression
// ================================================================

fn foldBinary(ast: *Ast, node_idx: u32, node: Node, changed: *bool) void {
    const left_ni = @intFromEnum(node.data.binary.left);
    const right_ni = @intFromEnum(node.data.binary.right);
    if (left_ni >= ast.nodes.items.len or right_ni >= ast.nodes.items.len) return;

    const left = ast.nodes.items[left_ni];
    const right = ast.nodes.items[right_ni];
    const op: Kind = @enumFromInt(node.data.binary.flags);

    // 비교 연산 (산술보다 먼저 — 숫자 === 숫자도 여기서 처리)
    if (op == .eq3 or op == .neq2) {
        // x === true → x, x === false → !x (한쪽만 boolean이면 축약)
        if (simplifyBooleanComparison(ast, node_idx, left, right, left_ni, right_ni, op)) {
            changed.* = true;
            return;
        }

        if (foldStrictEquality(ast, left, right)) |result| {
            const value = if (op == .neq2) !result else result;
            const text = if (value) "true" else "false";
            if (ast.addString(text)) |span| {
                replaceNode(ast, node_idx, .{
                    .tag = .boolean_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                }, changed);
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
                    replaceNode(ast, node_idx, .{
                        .tag = .numeric_literal,
                        .span = new_span,
                        .data = .{ .none = 0 },
                    }, changed);
                }
            }
        }
        return;
    }

    // 문자열 연결 (+ 연산자만)
    if (left.tag == .string_literal and right.tag == .string_literal and op == .plus) {
        foldStringConcat(ast, node_idx, left, right, changed);
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

fn foldStringConcat(ast: *Ast, node_idx: u32, left: Node, right: Node, changed: *bool) void {
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
    replaceNode(ast, node_idx, .{
        .tag = .string_literal,
        .span = span,
        .data = .{ .none = 0 },
    }, changed);
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

fn foldUnary(ast: *Ast, node_idx: u32, node: Node, changed: *bool) void {
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
                                replaceNode(ast, node_idx, unwrapped, changed);
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
                    replaceNode(ast, node_idx, .{
                        .tag = .boolean_literal,
                        .span = span,
                        .data = .{ .none = 0 },
                    }, changed);
                } else |_| {}
            }
        },
        .kw_typeof => {
            // typeof "str" → "string", typeof 42 → "number", typeof true → "boolean"
            // typeof null → "object", typeof undefined → "undefined"
            if (foldTypeof(ast, operand)) |type_str| {
                if (makeQuotedString(ast, type_str)) |span| {
                    replaceNode(ast, node_idx, .{
                        .tag = .string_literal,
                        .span = span,
                        .data = .{ .none = 0 },
                    }, changed);
                }
            }
        },
        .minus => {
            // -리터럴 → 음수 리터럴 (-1 → numeric_literal(-1))
            if (operand.tag == .numeric_literal) {
                if (parseNumericLiteral(ast, operand)) |val| {
                    if (formatNumber(ast, -val)) |span| {
                        replaceNode(ast, node_idx, .{
                            .tag = .numeric_literal,
                            .span = span,
                            .data = .{ .none = 0 },
                        }, changed);
                    }
                }
            }
        },
        .plus => {
            // +리터럴 → 그대로 (불필요한 단항 + 제거)
            if (operand.tag == .numeric_literal) {
                replaceNode(ast, node_idx, operand, changed);
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
fn foldConditional(ast: *Ast, node_idx: u32, node: Node, changed: *bool) void {
    const cond_ni = @intFromEnum(node.data.ternary.a);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    // 조건이 상수이면 선택된 분기로 교체
    const kept = if (truthy) node.data.ternary.b else node.data.ternary.c;
    const kept_ni = @intFromEnum(kept);
    if (kept_ni >= ast.nodes.items.len) return;
    replaceNode(ast, node_idx, ast.nodes.items[kept_ni], changed);
}

/// if_statement: if (false) { A } else { B } → B, if (true) { A } → A
fn foldIf(ast: *Ast, node_idx: u32, node: Node, changed: *bool) void {
    const cond_ni = @intFromEnum(node.data.ternary.a);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    if (truthy) {
        // if (true) { A } → A (then 분기)
        const then_ni = @intFromEnum(node.data.ternary.b);
        if (then_ni >= ast.nodes.items.len) return;
        replaceNode(ast, node_idx, ast.nodes.items[then_ni], changed);
    } else {
        // if (false) { A } else { B } → B (else 분기가 있으면)
        if (!node.data.ternary.c.isNone()) {
            const else_ni = @intFromEnum(node.data.ternary.c);
            if (else_ni >= ast.nodes.items.len) return;
            replaceNode(ast, node_idx, ast.nodes.items[else_ni], changed);
        } else {
            // if (false) { A } → empty_statement
            replaceNode(ast, node_idx, .{
                .tag = .empty_statement,
                .span = node.span,
                .data = .{ .none = 0 },
            }, changed);
        }
    }
}

/// while (false) { ... } → empty_statement
fn foldWhile(ast: *Ast, node_idx: u32, node: Node, changed: *bool) void {
    const cond_ni = @intFromEnum(node.data.binary.left);
    if (cond_ni >= ast.nodes.items.len) return;
    const cond = ast.nodes.items[cond_ni];

    const truthy = evalTruthiness(ast, cond) orelse return;
    if (!truthy) {
        replaceNode(ast, node_idx, .{
            .tag = .empty_statement,
            .span = node.span,
            .data = .{ .none = 0 },
        }, changed);
    }
}

/// logical_expression: true && x → x, false && x → false, true || x → true, false || x → x
fn foldLogical(ast: *Ast, node_idx: u32, node: Node, changed: *bool) void {
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
                replaceNode(ast, node_idx, ast.nodes.items[right_ni], changed);
            } else {
                // false && x → false (left 값 유지)
                replaceNode(ast, node_idx, left, changed);
            }
        },
        .pipe2 => { // ||
            if (truthy) {
                // true || x → true (left 값 유지)
                replaceNode(ast, node_idx, left, changed);
            } else {
                // false || x → x
                const right_ni = @intFromEnum(node.data.binary.right);
                if (right_ni >= ast.nodes.items.len) return;
                replaceNode(ast, node_idx, ast.nodes.items[right_ni], changed);
            }
        },
        .question2 => { // ??
            // null ?? x → x, undefined ?? x → x
            if (left.tag == .null_literal) {
                const right_ni = @intFromEnum(node.data.binary.right);
                if (right_ni >= ast.nodes.items.len) return;
                replaceNode(ast, node_idx, ast.nodes.items[right_ni], changed);
            } else if (left.tag == .identifier_reference) {
                const text = ast.getText(left.span);
                if (std.mem.eql(u8, text, "undefined")) {
                    const right_ni = @intFromEnum(node.data.binary.right);
                    if (right_ni >= ast.nodes.items.len) return;
                    replaceNode(ast, node_idx, ast.nodes.items[right_ni], changed);
                }
            }
        },
        else => {},
    }
}

// ================================================================
// Phase 4: Comma Operator + Template Literal Folding
// ================================================================

/// sequence_expression (comma operator) 축약. #1644 PR1.5 확장.
/// 마지막 원소 **앞에** 오는 모든 `isStmtRemovable` 원소 제거: `(1, foo, bar, baz())` → `baz()`.
/// 단일 원소만 남으면 sequence 자체를 그 노드로 교체.
///
/// 이전 구현은 prefix 리터럴만 제거. 이번 PR 에서 중간 원소도 제거 가능하도록 확장.
///
/// **Two-phase**: (1) 유지 / 제거 원소를 먼저 수집 완료 + extra_data 에 append 성공까지
/// 확인한 뒤 (2) reference_count 감산 + list rewrite 를 **한 번에** commit. 중간 OOM 시
/// symbol 상태가 stale 이 되지 않도록 원자적 처리.
fn simplifySequence(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
    const list = node.data.list;
    if (list.len < 2) return;
    if (list.start + list.len > ast.extra_data.items.len) return;

    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    const last_raw = indices[list.len - 1];
    if (last_raw >= ast.nodes.items.len) return;

    // Phase 1 (collect only, no mutation): 유지할 원소 / 제거할 원소 분류.
    var kept_buf: std.ArrayListUnmanaged(u32) = .empty;
    defer kept_buf.deinit(ast.allocator);
    var removed_buf: std.ArrayListUnmanaged(u32) = .empty;
    defer removed_buf.deinit(ast.allocator);

    for (indices[0 .. list.len - 1]) |raw| {
        if (raw >= ast.nodes.items.len) return;
        // 내부 부분 rewrite 도 동시에 수행 (`a ? b : c` → `a || c` 등).
        // rewriter 가 내부 제거분은 이미 감산함 — 최종 removable 로 판정되면 호출자가 raw 전체 감산.
        if (simplifyUnusedInPlace(ast, ctx, @enumFromInt(raw), changed, 0)) {
            removed_buf.append(ast.allocator, raw) catch return;
        } else {
            kept_buf.append(ast.allocator, raw) catch return;
        }
    }

    if (removed_buf.items.len == 0) return; // 아무것도 제거 안 됨

    // Phase 2 (commit): 모든 allocation 성공 확인 후 mutation.
    if (kept_buf.items.len == 0) {
        // 마지막 하나만 남음 → sequence 를 해당 노드로 교체. list rewrite 불필요.
        for (removed_buf.items) |raw| decrementRefsInExpr(ast, ctx, @enumFromInt(raw));
        replaceNode(ast, node_idx, ast.nodes.items[last_raw], changed);
        return;
    }

    // extra_data 에 새 list 먼저 append — 실패 시 mutation 없이 return.
    kept_buf.append(ast.allocator, last_raw) catch return;
    const new_start: u32 = @intCast(ast.extra_data.items.len);
    ast.extra_data.appendSlice(ast.allocator, kept_buf.items) catch return;

    // 이 지점부터는 allocation 실패 없음 — 안전하게 decrement + rewrite.
    for (removed_buf.items) |raw| decrementRefsInExpr(ast, ctx, @enumFromInt(raw));
    ast.nodes.items[node_idx].data = .{
        .list = .{ .start = new_start, .len = @intCast(kept_buf.items.len) },
    };
    changed.* = true;
}

/// expression_statement 의 자식 expression 을 unused 맥락에서 축약하고, 최종적으로
/// removable 이면 `empty_statement` 로 교체한다.
/// `simplifyUnusedInPlace` 가 내부 부분 제거 (`a ? b : c;` → `a || c;` 등) 를 수행.
fn simplifyUnusedExprStmt(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
    const operand = node.data.unary.operand;
    const removable = simplifyUnusedInPlace(ast, ctx, operand, changed, 0);
    if (removable) {
        decrementRefsInExpr(ast, ctx, operand);
        replaceNode(ast, node_idx, .{
            .tag = .empty_statement,
            .span = node.span,
            .data = .{ .none = 0 },
        }, changed);
        return;
    }

    // Post-rewrite paren unwrap: `({a: foo()});` 의 object 가 rewrite 로 `foo()` 가 되면
    // paren 은 statement 자리에서 redundant — inner 가 statement 시작 시 모호한 tag
    // (object / function / class expression) 가 아니면 paren 을 벗긴다.
    unwrapRedundantStmtParen(ast, node_idx, changed);
}

/// `expression_statement` 의 operand 가 `parenthesized_expression` 이고 그 inner 가
/// **확실히 안전한 tag** 면 paren 을 벗긴다.
///
/// Statement 시작 시 paren 이 필요한 케이스:
///   - `{...}` object_expression — block 과 모호
///   - `function () {}` / `class {}` — declaration 과 모호
///   - `{v} = o` / `[a] = b` — destructuring assignment 의 LHS object/array pattern 이 block/array 과 모호
///   - `(1, {v} = o)` / `(1, {a})` — sequence 첫 원소가 위 조건 유발
///
/// 정확한 재귀 판정은 LHS tag / sequence head 까지 내려가야 하므로 **whitelist 로 단순화** —
/// rewrite 결과 흔히 나오는 안전한 expression tag 에 대해서만 unwrap 허용, 그 외는 유지.
/// 바이트 2 손해 (paren 2개) 대신 정확성 확보.
fn unwrapRedundantStmtParen(ast: *Ast, stmt_idx: u32, changed: *bool) void {
    const stmt = ast.nodes.items[stmt_idx];
    const op_ni = @intFromEnum(stmt.data.unary.operand);
    if (op_ni >= ast.nodes.items.len) return;
    const op_node = ast.nodes.items[op_ni];
    if (op_node.tag != .parenthesized_expression) return;

    const inner_idx = op_node.data.unary.operand;
    const inner_ni = @intFromEnum(inner_idx);
    if (inner_ni >= ast.nodes.items.len) return;

    // Whitelist: statement 시작 시 파싱 모호성이 없는 tag 만 unwrap.
    const safe = switch (ast.nodes.items[inner_ni].tag) {
        .call_expression,
        .new_expression,
        .identifier_reference,
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regexp_literal,
        .this_expression,
        .static_member_expression,
        .private_field_expression,
        .computed_member_expression,
        .binary_expression,
        .logical_expression,
        .unary_expression,
        .update_expression,
        .conditional_expression,
        .template_literal,
        .tagged_template_expression,
        .await_expression,
        .yield_expression,
        => true,
        else => false,
    };
    if (!safe) return;

    ast.nodes.items[stmt_idx].data = .{ .unary = .{ .operand = inner_idx, .flags = stmt.data.unary.flags } };
    changed.* = true;
}

// ================================================================
// Unused Expression In-Place Simplify (#1650 step 2 — c/d)
// ================================================================
//
// **호출 site contract**: `idx` 의 expression 결과값이 **버려지는 자리** (statement 자리 또는
// `sequence_expression` 비마지막 원소) 전용. call callee (`(0, f)()` 의 `0`), assignment RHS,
// return expression 등 결과값이 관측되는 자리에 쓰면 semantic 위반.
//
// **Mutation contract**:
//   - 내부 rewrite 시 제거되는 sub-expression 의 `reference_count` 를 **내부에서 감산**.
//   - 반환 `true`: 현재 idx 전체가 removable — 호출자는 idx 를 drop 하고 **추가로** idx 전체의
//     refs 를 감산해야 함 (최종 drop).
//   - 반환 `false`: 호출자는 idx 를 유지. 감산 금지.
//
// **Rewrites** (모두 fixed-point loop 하에서 연쇄):
//   - `a ? b : c` 에서 b / c 가 removable → `a && b` / `a || c` (logical_expression 으로 변환)
//   - `a ? b : c` 에서 둘 다 removable → `a` (conditional 을 test 로 교체)
//   - `a <op> b` (비교) 에서 한쪽 removable → 나머지로 교체
//   - `a && b` / `a || b` / `a ?? b` 에서 right removable → left 만 남김 (short-circuit 의미상 OK)
//   - template_literal 전체 (모든 substitution removable) → true 판정만

// depth 제한은 `isStmtRemovableDepth` 와 맞춤 — 두 함수가 상호 재귀.
const max_unused_simplify_depth: u32 = max_stmt_removable_depth;

fn simplifyUnusedInPlace(ast: *Ast, ctx: MinifyCtx, idx: NodeIndex, changed: *bool, depth: u32) bool {
    if (depth >= max_unused_simplify_depth) return false;
    if (idx.isNone()) return true;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[ni];

    // Rewritable tag 만 여기서 mutation. 그 외는 `isStmtRemovableDepth` 판정에 위임 —
    // literal / identifier / unary / sequence / template 등은 판정만 필요.
    return switch (node.tag) {
        .binary_expression => rewriteBinaryUnused(ast, ctx, ni, node, changed, depth),
        .logical_expression => rewriteLogicalUnused(ast, ctx, ni, node, changed, depth),
        .conditional_expression => rewriteConditionalUnused(ast, ctx, ni, node, changed, depth),
        .array_expression => rewriteArrayUnused(ast, ctx, ni, node, changed, depth),
        .object_expression => rewriteObjectUnused(ast, ctx, ni, node, changed, depth),
        .call_expression, .new_expression => rewriteCallOrNewUnused(ast, ctx, ni, node, changed, depth),
        .parenthesized_expression => simplifyUnusedInPlace(ast, ctx, node.data.unary.operand, changed, depth + 1),
        else => isStmtRemovableDepth(ast, idx, ctx, depth),
    };
}

/// 비교 연산 (`==`, `===`, `!=`, `!==`, `<`, `>`, `<=`, `>=`, `in`, `instanceof`) 은
/// 양쪽 operand 가 pure 면 전체 removable. 한쪽만 removable 이면 나머지로 교체.
/// 비교 외 binary (`+`, `-`, `*`, `|`, ...) 는 양쪽 pure 여야 removable — JS `valueOf`/`toString`
/// 의 side-effect 는 purity 가 이미 식별. 부분 rewrite 는 안 함 (의미 보존 복잡).
fn rewriteBinaryUnused(ast: *Ast, ctx: MinifyCtx, ni: u32, node: Node, changed: *bool, depth: u32) bool {
    const op: Kind = @enumFromInt(node.data.binary.flags);
    const is_comparison = switch (op) {
        .eq3, .neq2, .eq2, .neq, .l_angle, .r_angle, .lt_eq, .gt_eq, .kw_in, .kw_instanceof => true,
        else => false,
    };

    const left_idx = node.data.binary.left;
    const right_idx = node.data.binary.right;
    const d = depth + 1;

    if (!is_comparison) {
        return isStmtRemovableDepth(ast, left_idx, ctx, d) and
            isStmtRemovableDepth(ast, right_idx, ctx, d);
    }

    const left_rem = isStmtRemovableDepth(ast, left_idx, ctx, d);
    const right_rem = isStmtRemovableDepth(ast, right_idx, ctx, d);

    if (left_rem and right_rem) return true;

    if (left_rem) {
        // `pure == impure` → `impure`
        const right_ni = @intFromEnum(right_idx);
        if (right_ni >= ast.nodes.items.len) return false;
        decrementRefsInExpr(ast, ctx, left_idx);
        replaceNode(ast, ni, ast.nodes.items[right_ni], changed);
        return false;
    }
    if (right_rem) {
        // `impure == pure` → `impure`
        const left_ni = @intFromEnum(left_idx);
        if (left_ni >= ast.nodes.items.len) return false;
        decrementRefsInExpr(ast, ctx, right_idx);
        replaceNode(ast, ni, ast.nodes.items[left_ni], changed);
        return false;
    }
    return false;
}

/// `&&`, `||`, `??` 는 short-circuit 때문에 left 의 truthy/nullish 판정이 b 의 실행을 제어.
/// statement 자리에선 결과값은 버려지므로:
///   - right removable → `left` 만 남김 (b 의 실행 여부 차이는 "pure" 라 관측 불가)
///   - left removable only → 그대로 유지 (b 의 실행 여부가 바뀜 → 의미 변경)
///   - 둘 다 removable → 전체 removable
fn rewriteLogicalUnused(ast: *Ast, ctx: MinifyCtx, ni: u32, node: Node, changed: *bool, depth: u32) bool {
    const left_idx = node.data.binary.left;
    const right_idx = node.data.binary.right;
    const d = depth + 1;

    const right_rem = isStmtRemovableDepth(ast, right_idx, ctx, d);
    if (!right_rem) return false;

    const left_rem = isStmtRemovableDepth(ast, left_idx, ctx, d);
    if (left_rem) return true;

    // right drop, left 만 남김
    const left_ni = @intFromEnum(left_idx);
    if (left_ni >= ast.nodes.items.len) return false;
    decrementRefsInExpr(ast, ctx, right_idx);
    replaceNode(ast, ni, ast.nodes.items[left_ni], changed);
    return false;
}

/// Conditional `a ? b : c` 를 unused 자리에서 축약:
///   - b, c 둘 다 removable → `a` 로 교체 (a 자체 removable 여부로 반환)
///   - b removable → `a || c` (b 는 a truthy 시 실행되므로 drop OK)
///   - c removable → `a && b`
///   - 둘 다 impure → 그대로
///
/// **Grammar**: conditional 의 cons/alt 는 `AssignmentExpression` 을 paren 없이 허용
/// (`a ? b : c = d` → `a ? b : (c = d)` 로 파싱). 그러나 `logical_expression` 의 right 자리는
/// `LogicalORExpression` 이라 assignment / sequence 직접 불가. rewrite 시 kept operand 가
/// 이 두 tag 이면 `parenthesized_expression` 노드를 새로 만들어 감싸서 옮긴다.
fn rewriteConditionalUnused(ast: *Ast, ctx: MinifyCtx, ni: u32, node: Node, changed: *bool, depth: u32) bool {
    const test_idx = node.data.ternary.a;
    const cons_idx = node.data.ternary.b;
    const alt_idx = node.data.ternary.c;
    const d = depth + 1;

    const cons_rem = isStmtRemovableDepth(ast, cons_idx, ctx, d);
    const alt_rem = isStmtRemovableDepth(ast, alt_idx, ctx, d);

    if (cons_rem and alt_rem) {
        const test_ni = @intFromEnum(test_idx);
        if (test_ni >= ast.nodes.items.len) return false;
        decrementRefsInExpr(ast, ctx, cons_idx);
        decrementRefsInExpr(ast, ctx, alt_idx);
        replaceNode(ast, ni, ast.nodes.items[test_ni], changed);
        return isStmtRemovableDepth(ast, test_idx, ctx, d);
    }

    if (cons_rem) {
        // a ? [pure] : c → a || c
        const right_idx = ensureLogicalOperand(ast, alt_idx) catch return false;
        decrementRefsInExpr(ast, ctx, cons_idx);
        ast.nodes.items[ni] = .{
            .tag = .logical_expression,
            .span = node.span,
            .data = .{ .binary = .{ .left = test_idx, .right = right_idx, .flags = @intFromEnum(Kind.pipe2) } },
        };
        changed.* = true;
        return false;
    }

    if (alt_rem) {
        // a ? b : [pure] → a && b
        const right_idx = ensureLogicalOperand(ast, cons_idx) catch return false;
        decrementRefsInExpr(ast, ctx, alt_idx);
        ast.nodes.items[ni] = .{
            .tag = .logical_expression,
            .span = node.span,
            .data = .{ .binary = .{ .left = test_idx, .right = right_idx, .flags = @intFromEnum(Kind.amp2) } },
        };
        changed.* = true;
        return false;
    }

    return false;
}

/// `logical_expression` 의 operand 자리에 paren 없이 올 수 있는 `NodeIndex` 로 변환.
/// `assignment_expression` / `sequence_expression` 은 JS grammar 상 paren 필수 (LogicalOR
/// 자리에 직접 못 옴) — `wrapInParen` 으로 감싼다. 그 외는 그대로 반환.
fn ensureLogicalOperand(ast: *Ast, idx: NodeIndex) !NodeIndex {
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return idx;
    return switch (ast.nodes.items[ni].tag) {
        .assignment_expression, .sequence_expression => try wrapInParen(ast, idx),
        else => idx,
    };
}

// ================================================================
// Unused Multi-Element Rewrite (#1650 follow-up: Array / New / Object)
// ================================================================
//
// `[a, b, c];` / `new Pure(a, b);` / `{k: v, [k()]: v2};` 가 statement 자리 (또는 unused
// sequence 원소 자리) 에 있을 때, pure 원소는 drop 하고 impure 만 남겨 sequence 로 flatten.
// oxc `remove_unused_expression.rs` 의 `remove_unused_array_expr` / `remove_unused_new_expr`
// / `remove_unused_object_expr` 와 동등 동작.
//
// 모두 공통 축소 로직: kept 원소 개수에 따라
//   0 → 전체 removable (호출자가 empty 로 교체)
//   1 → 단일 노드로 slot 교체
//   N → sequence_expression 으로 교체 (새 list entry + 새 sequence 노드)

/// `kept` 원소로 `ni` slot 을 축소한다. 반환: 최종 removable 여부 (kept.len == 0).
/// kept 가 1 이면 해당 노드 복사로 slot 교체, 2+ 이면 sequence_expression 생성.
/// `span` 은 원본 노드의 span (sequence 의 표시용).
fn reduceToSequenceExpr(
    ast: *Ast,
    ni: u32,
    span: Span,
    kept: []const NodeIndex,
    changed: *bool,
) !bool {
    if (kept.len == 0) return true;
    if (kept.len == 1) {
        const single_ni = @intFromEnum(kept[0]);
        if (single_ni >= ast.nodes.items.len) return false;
        replaceNode(ast, ni, ast.nodes.items[single_ni], changed);
        return false;
    }
    // kept >= 2: sequence_expression 생성
    const new_start: u32 = @intCast(ast.extra_data.items.len);
    try ast.extra_data.ensureUnusedCapacity(ast.allocator, kept.len);
    for (kept) |idx| ast.extra_data.appendAssumeCapacity(@intFromEnum(idx));
    ast.nodes.items[ni] = .{
        .tag = .sequence_expression,
        .span = span,
        .data = .{ .list = .{ .start = new_start, .len = @intCast(kept.len) } },
    };
    changed.* = true;
    return false;
}

/// `[a, b, c];` 원소 중 pure 를 drop. spread 원소가 있으면 skip — `[...x]` 의 x 는
/// iterator protocol 호출로 side-effect 가능 + 배열 축약 자체가 의미 변경 (arity).
fn rewriteArrayUnused(ast: *Ast, ctx: MinifyCtx, ni: u32, node: Node, changed: *bool, depth: u32) bool {
    const list = node.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return false;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];

    // spread 가드 — 원소 중 하나라도 spread_element 이면 전체 rewrite 포기 (drop 자체 불가).
    for (indices) |raw| {
        if (raw >= ast.nodes.items.len) return false;
        if (ast.nodes.items[raw].tag == .spread_element) return false;
    }

    if (list.len == 0) return true;

    var kept: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer kept.deinit(ast.allocator);

    for (indices) |raw| {
        const idx: NodeIndex = @enumFromInt(raw);
        // array hole — NodeIndex.none — drop
        if (idx.isNone()) continue;
        const child_rem = simplifyUnusedInPlace(ast, ctx, idx, changed, depth + 1);
        if (child_rem) continue;
        kept.append(ast.allocator, idx) catch return false;
    }

    return reduceToSequenceExpr(ast, ni, node.span, kept.items, changed) catch false;
}

/// `new F(a, b, c);` / `F(a, b, c);` 를 `@__PURE__` 등으로 purity 확정된 경우
/// args 중 pure 를 drop 하고 impure 만 sequence 로 남김. callee 는 pure 가정이므로 drop.
/// purity 미확정이면 유지.
///
/// **super() 가드**: `super(...)` 는 derived constructor 에서 binding 역할 (this 접근 전
/// 반드시 호출). `@__PURE__` annotation 이 붙어도 drop 금지 — side-effect 와 별개로 semantic
/// 필수 호출.
fn rewriteCallOrNewUnused(ast: *Ast, ctx: MinifyCtx, ni: u32, node: Node, changed: *bool, depth: u32) bool {
    // call_expression / new_expression extras: [callee, args_start, args_len, flags]
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return false;
    const callee_raw = ast.extra_data.items[e];
    if (callee_raw < ast.nodes.items.len and
        ast.nodes.items[callee_raw].tag == .super_expression) return false;

    // purity 는 전체 expression 단위. pure 가 아니면 args drop 자체도 안전하지 않음.
    // (callee 가 impure 면 인자 evaluate 순서/횟수 관측 가능).
    if (!purity.isExprPure(ast, @enumFromInt(ni), ctx.unresolved_globals)) return false;

    const args_start = ast.extra_data.items[e + 1];
    const args_len = ast.extra_data.items[e + 2];
    if (args_start + args_len > ast.extra_data.items.len) return true;

    if (args_len == 0) return true;

    var kept: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer kept.deinit(ast.allocator);

    for (ast.extra_data.items[args_start .. args_start + args_len]) |raw| {
        const idx: NodeIndex = @enumFromInt(raw);
        if (idx.isNone()) continue;
        const child_rem = simplifyUnusedInPlace(ast, ctx, idx, changed, depth + 1);
        if (child_rem) continue;
        kept.append(ast.allocator, idx) catch return false;
    }

    return reduceToSequenceExpr(ast, ni, node.span, kept.items, changed) catch false;
}

/// `{k: v, [k()]: v2};` 의 key / value / spread 를 분해해 pure 는 drop, impure 만 남김.
/// spread 는 `{...x}` 의 x 가 side-effect (iterator, proxy trap) 이므로 sequence 원소로 보존.
/// method / getter / setter 는 value 가 function_expression 이라 pure — 전체 drop 가능.
/// computed key (`[expr]`) 의 expr 은 pure 면 drop, impure 면 sequence 에 추가.
fn rewriteObjectUnused(ast: *Ast, ctx: MinifyCtx, ni: u32, node: Node, changed: *bool, depth: u32) bool {
    const list = node.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return false;

    if (list.len == 0) return true;

    const props = ast.extra_data.items[list.start .. list.start + list.len];

    // Spread 혼합 처리 (oxc 방식): spread 원소는 expression 자리에 직접 놓을 수 없고
    // `{...x}` 형태 유지가 필요하므로 변환 복잡도 대비 ROI 가 낮다.
    //   - 전원 spread: 각 spread 의 argument 가 모두 pure 면 전체 drop, 아니면 유지.
    //   - 일부만 spread: 변환 포기 (유지).
    //   - 전원 non-spread: 아래 일반 경로에서 pure value / computed key 분해.
    var any_spread = false;
    var all_spread = true;
    for (props) |raw| {
        if (raw >= ast.nodes.items.len) return false;
        const tag = ast.nodes.items[raw].tag;
        if (tag == .spread_element) {
            any_spread = true;
        } else {
            all_spread = false;
        }
    }

    if (all_spread) {
        for (props) |raw| {
            const spread = ast.nodes.items[raw];
            if (!isStmtRemovableDepth(ast, spread.data.unary.operand, ctx, depth + 1)) return false;
        }
        return true;
    }
    if (any_spread) return false;

    var kept: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer kept.deinit(ast.allocator);

    for (props) |raw| {
        const prop = ast.nodes.items[raw];

        switch (prop.tag) {
            .object_property => {
                // data.binary: left = key, right = value
                const key_idx = prop.data.binary.left;
                const value_idx = prop.data.binary.right;

                // computed key 는 evaluate side-effect 가능 — pure 면 drop, 아니면 남김.
                const key_ni = @intFromEnum(key_idx);
                if (key_ni < ast.nodes.items.len and
                    ast.nodes.items[key_ni].tag == .computed_property_key)
                {
                    const inner = ast.nodes.items[key_ni].data.unary.operand;
                    const key_rem = simplifyUnusedInPlace(ast, ctx, inner, changed, depth + 1);
                    if (!key_rem) kept.append(ast.allocator, inner) catch return false;
                }

                // value — shorthand 면 key 와 같지만 판정 동일. 재귀로 축약 + removable 판정.
                const value_rem = simplifyUnusedInPlace(ast, ctx, value_idx, changed, depth + 1);
                if (!value_rem) kept.append(ast.allocator, value_idx) catch return false;
            },
            // method_definition / getter / setter — function body 는 evaluate 시 pure (객체
            // 생성 시 호출 안 됨). 단 computed key (`[foo()]() {}`) 의 expression 은 객체
            // 생성 시 evaluate → side-effect 보존 필요.
            .method_definition => {
                const me = prop.data.extra;
                if (me + @as(u32, ast_mod.MethodExtra.key) >= ast.extra_data.items.len) return false;
                const key_raw = ast.extra_data.items[me + ast_mod.MethodExtra.key];
                if (key_raw >= ast.nodes.items.len) continue;
                if (ast.nodes.items[key_raw].tag != .computed_property_key) continue;
                const inner = ast.nodes.items[key_raw].data.unary.operand;
                const key_rem = simplifyUnusedInPlace(ast, ctx, inner, changed, depth + 1);
                if (!key_rem) kept.append(ast.allocator, inner) catch return false;
            },
            else => {
                // 알 수 없는 property — 보수적으로 전체 유지.
                return false;
            },
        }
    }

    return reduceToSequenceExpr(ast, ni, node.span, kept.items, changed) catch false;
}

/// expression 이 **statement 자리에서 안전히 삭제 가능한지** 판정. `purity.isExprPure`
/// 는 "expression 내부로서" pure 를 보므로 identifier_reference / member access 도
/// pure 로 인정하지만, statement 자리에서는:
///   - unresolved identifier → `ReferenceError` side-effect
///   - member access → getter / Proxy trap 실행
/// 가 발생하므로 엄격 기준이 필요하다.
///
/// 보수적 허용 목록:
///   - 리터럴 (numeric, string, boolean, null, bigint, regex)
///   - `this` / function expression / arrow
///   - pure unary (`!x`, `+1`, `~0`, `typeof x` — delete 제외)
///   - pure binary / logical / conditional — 자식이 모두 removable
///   - parenthesized — 내부 expression 이 removable
///   - @__PURE__ call/new
///   - identifier_reference: function 스코프 이하 local 바인딩만 (top-level / import / 미해결 제외)
///   - member access: 제외 (getter 위험)
///
/// **호출 site contract**: statement 자리 또는 sequence_expression 원소 자리 전용.
/// call_expression 의 callee 자리에 쓰면 `(0, f)()` 의 `0` 을 제거해 this 바인딩을
/// 바꾸는 회귀 가능 — 새 호출 site 추가 시 contract 확인.
fn isStmtRemovable(ast: *const Ast, idx: NodeIndex, ctx: MinifyCtx) bool {
    return isStmtRemovableDepth(ast, idx, ctx, 0);
}

const max_stmt_removable_depth: u32 = 128;

fn isStmtRemovableDepth(ast: *const Ast, idx: NodeIndex, ctx: MinifyCtx, depth: u32) bool {
    if (depth >= max_stmt_removable_depth) return false;
    if (idx.isNone()) return true;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[ni];
    const d = depth + 1;

    return switch (node.tag) {
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regexp_literal,
        .this_expression,
        .function_expression,
        .arrow_function_expression,
        => true,

        // identifier_reference: function 스코프 이하 local 만. top-level (scope_id=0) 과
        // import 바인딩은 live binding 이라 `import * as ns` 등의 초기화 순서를 건드릴 수
        // 있어 보수적으로 유지 (dead store removeDeadStores 와 동일 가드).
        .identifier_reference => blk: {
            if (ni >= ctx.symbol_ids.len) break :blk false;
            const sid = ctx.symbol_ids[ni] orelse break :blk false;
            if (sid >= ctx.symbols.len) break :blk false;
            const sym = ctx.symbols[sid];
            if (@intFromEnum(sym.scope_id) == 0) break :blk false;
            if (sym.decl_flags.is_import) break :blk false;
            break :blk true;
        },

        .parenthesized_expression => isStmtRemovableDepth(ast, node.data.unary.operand, ctx, d),

        .unary_expression => blk: {
            const e = node.data.extra;
            if (!ast.hasExtra(e, 1)) break :blk false;
            const op_kind: u8 = @truncate(ast.readExtra(e, 1) & 0xFF);
            if (op_kind == @intFromEnum(Kind.kw_delete)) break :blk false;
            break :blk isStmtRemovableDepth(ast, @enumFromInt(ast.readExtra(e, 0)), ctx, d);
        },

        .binary_expression, .logical_expression => isStmtRemovableDepth(ast, node.data.binary.left, ctx, d) and
            isStmtRemovableDepth(ast, node.data.binary.right, ctx, d),

        .conditional_expression => blk: {
            const t = node.data.ternary;
            break :blk isStmtRemovableDepth(ast, t.a, ctx, d) and
                isStmtRemovableDepth(ast, t.b, ctx, d) and
                isStmtRemovableDepth(ast, t.c, ctx, d);
        },

        .sequence_expression => blk: {
            const list = node.data.list;
            if (list.start + list.len > ast.extra_data.items.len) break :blk false;
            for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
                if (!isStmtRemovableDepth(ast, @enumFromInt(raw), ctx, d)) break :blk false;
            }
            break :blk true;
        },

        .template_literal => blk: {
            // 단순 문자열 template (data.none = 0) — substitution 없음, removable.
            if (node.data.none == 0) break :blk true;
            const list = node.data.list;
            if (list.start + list.len > ast.extra_data.items.len) break :blk false;
            for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
                if (raw >= ast.nodes.items.len) break :blk false;
                const child = ast.nodes.items[raw];
                // template_element 는 리터럴 문자열 조각 — 항상 removable.
                if (child.tag == .template_element) continue;
                if (!isStmtRemovableDepth(ast, @enumFromInt(raw), ctx, d)) break :blk false;
            }
            break :blk true;
        },

        // @__PURE__ call/new — 사용자 assertion. member callee 여도 "제거해도 됨" 선언이므로
        // purity 가 true 면 그대로 따름 (esbuild/rolldown 동일).
        .call_expression, .new_expression => purity.isExprPure(ast, idx, ctx.unresolved_globals),

        else => false,
    };
}

// ================================================================
// Phase 5: Adjacent Same-Kind Declaration Merge (#1588)
// ================================================================
//
// `var a=1; var b=2;` → `var a=1,b=2;` — 선언당 4-6 바이트 절감.
// 참고: esbuild `mangleStmts`, rolldown `mergeable_declarations.rs`.

// `ast.allocator`는 parse_arena라 `free`가 no-op — watch 재빌드 시 캐시된 모듈의
// arena에 임시 할당이 누적되므로 스택 버퍼만 사용. 상한 초과 블록은 merge 스킵.
const MAX_STMTS_PER_BLOCK: usize = 4096;
const MAX_DECLS_PER_MERGE: usize = 1024;

/// Program/BlockStatement/FunctionBody 내 연속된 같은-kind 선언을 병합한다.
///
/// `skip_nodes`가 주어지면 tree-shake로 마킹된 statement는 accumulator에 넣지 않아
/// merge 대상에서도 제외된다 (statement 자체는 새 리스트에 그대로 남음 — codegen이
/// skip_nodes를 보고 출력을 생략).
fn mergeAdjacentDecls(ast: *Ast, node_idx: u32, node: Node, skip_nodes: ?*const std.DynamicBitSet) void {
    const list = node.data.list;
    if (list.len < 2) return;
    if (list.len > MAX_STMTS_PER_BLOCK) return;
    if (@as(usize, list.start) + list.len > ast.extra_data.items.len) return;

    // 원본 리스트 복사 — 이후 extra_data append가 슬라이스를 무효화할 수 있음.
    var stmts_buf: [MAX_STMTS_PER_BLOCK]u32 = undefined;
    const stmts = stmts_buf[0..list.len];
    @memcpy(stmts, ast.extra_data.items[list.start .. list.start + list.len]);

    var out_buf: [MAX_STMTS_PER_BLOCK]u32 = undefined;
    var out_len: usize = 0;
    var changed = false;

    for (stmts) |stmt_ni| {
        // skip_nodes 마킹된 statement는 merge 후보에서 제외. prev로도, cur로도 취급 안 함.
        // 대신 원본 순서대로 out_buf에 포함 — codegen이 skip_nodes 보고 출력 생략.
        const is_skipped = if (skip_nodes) |s| (stmt_ni < s.capacity() and s.isSet(stmt_ni)) else false;

        if (!is_skipped and tryMergeWithPrev(ast, stmt_ni, out_buf[0..out_len], skip_nodes)) {
            changed = true;
            continue;
        }
        out_buf[out_len] = stmt_ni;
        out_len += 1;
    }

    if (!changed) return;

    // 새 리스트를 extra_data 끝에 append — 원본 슬롯은 garbage로 남는다.
    // 두 번째 호출 시엔 이미 merge 완료 상태라 `changed=false`로 조기 반환 → idempotent.
    const new_start = ast.addExtras(out_buf[0..out_len]) catch return;
    ast.nodes.items[node_idx].data = .{
        .list = .{ .start = new_start, .len = @intCast(out_len) },
    };
}

/// `cur_ni`가 `accumulated`의 마지막 non-skipped 선언과 병합 가능하면 병합하고 true 반환.
/// 병합 시: prev의 declarator list를 `[prev_decls ++ cur_decls]`로 확장.
fn tryMergeWithPrev(ast: *Ast, cur_ni: u32, accumulated: []const u32, skip_nodes: ?*const std.DynamicBitSet) bool {
    if (accumulated.len == 0) return false;
    if (cur_ni >= ast.nodes.items.len) return false;
    const cur = ast.nodes.items[cur_ni];
    if (cur.tag != .variable_declaration) return false;

    // prev 탐색 시 skip_nodes 마킹된 항목은 건너뜀 — 이들은 codegen에서도 출력 안 되므로
    // 인접성 기준으로 삼으면 tree-shake 결과와 어긋날 수 있다.
    var prev_ni: u32 = 0;
    var found_prev = false;
    var idx: usize = accumulated.len;
    while (idx > 0) {
        idx -= 1;
        const candidate = accumulated[idx];
        const is_skipped = if (skip_nodes) |s| (candidate < s.capacity() and s.isSet(candidate)) else false;
        if (is_skipped) continue;
        prev_ni = candidate;
        found_prev = true;
        break;
    }
    if (!found_prev) return false;

    if (prev_ni >= ast.nodes.items.len) return false;
    const prev = ast.nodes.items[prev_ni];
    if (prev.tag != .variable_declaration) return false;

    const kind_prev = ast.variableDeclarationKind(prev);
    const kind_cur = ast.variableDeclarationKind(cur);
    if (kind_prev != kind_cur) return false;
    // `using`/`await using`: declarator 좌→우로 dispose 스택에 push되고 block 끝에서
    // LIFO로 pop되므로, 개별 선언과 merged 선언의 dispose 순서가 동일 → 안전하게 merge.

    const pe = prev.data.extra;
    const ce = cur.data.extra;
    if (pe + 2 >= ast.extra_data.items.len) return false;
    if (ce + 2 >= ast.extra_data.items.len) return false;

    const p_start = ast.extra_data.items[pe + 1];
    const p_len = ast.extra_data.items[pe + 2];
    const c_start = ast.extra_data.items[ce + 1];
    const c_len = ast.extra_data.items[ce + 2];

    if (@as(usize, p_start) + p_len > ast.extra_data.items.len) return false;
    if (@as(usize, c_start) + c_len > ast.extra_data.items.len) return false;

    const total_len: usize = @as(usize, p_len) + c_len;
    if (total_len > MAX_DECLS_PER_MERGE) return false;

    var buf: [MAX_DECLS_PER_MERGE]u32 = undefined;
    @memcpy(buf[0..p_len], ast.extra_data.items[p_start .. p_start + p_len]);
    @memcpy(buf[p_len..total_len], ast.extra_data.items[c_start .. c_start + c_len]);

    const new_start = ast.addExtras(buf[0..total_len]) catch return false;
    // pe+1/pe+2는 고정 인덱스이므로 addExtras 후에도 직접 쓰기 가능.
    ast.extra_data.items[pe + 1] = new_start;
    ast.extra_data.items[pe + 2] = @intCast(total_len);
    // `cur`의 declarator list를 비워 idempotency 보장. 번들러는 같은 module 내용을
    // module-program과 wrapper-program 양쪽에 담아 ast.nodes에 남기므로, 두 container가
    // 각각 minify를 한 번씩 실행한다. 두 번째 container가 동일 pair를 재병합하면
    // prev의 list(이미 a,b)에 cur의 list(b)를 또 붙여 중복(a,b,b)이 되므로 방지 필요.
    ast.extra_data.items[ce + 2] = 0;
    return true;
}
