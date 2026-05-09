//! Unused expression simplification for the minify pass.
//!
//! This module owns statement-position expression pruning: comma expression
//! cleanup, pure branch/argument/property removal, and template literal
//! reduction. The parent minify loop decides when these passes run.

const std = @import("std");
const minify_mod = @import("../minify.zig");
const MinifyCtx = minify_mod.MinifyCtx;
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const Span = @import("../../lexer/token.zig").Span;
const Kind = @import("../../lexer/token.zig").Kind;
const purity = @import("../../bundler/purity.zig");

/// 전체 노드 치환 + fixed-point 신호. 이 모듈 안에서만 쓰는 작은 mutation helper.
inline fn replaceNode(ast: *Ast, idx: u32, new_node: Node, changed: *bool) void {
    ast.nodes.items[idx] = new_node;
    changed.* = true;
}

/// `inner_idx` 를 감싸는 새 `parenthesized_expression` 노드를 append 하고 그 NodeIndex 반환.
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

/// sequence_expression (comma operator) 축약. #1644 PR1.5 확장.
/// 마지막 원소 **앞에** 오는 모든 `isStmtRemovable` 원소 제거: `(1, foo, bar, baz())` → `baz()`.
/// 단일 원소만 남으면 sequence 자체를 그 노드로 교체.
///
/// 이전 구현은 prefix 리터럴만 제거. 이번 PR 에서 중간 원소도 제거 가능하도록 확장.
///
/// **Two-phase**: (1) 유지 / 제거 원소를 먼저 수집 완료 + extra_data 에 append 성공까지
/// 확인한 뒤 (2) reference_count 감산 + list rewrite 를 **한 번에** commit. 중간 OOM 시
/// symbol 상태가 stale 이 되지 않도록 원자적 처리.
pub fn simplifySequence(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
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
        for (removed_buf.items) |raw| minify_mod.decrementRefsInExpr(ast, ctx, @enumFromInt(raw));
        replaceNode(ast, node_idx, ast.nodes.items[last_raw], changed);
        return;
    }

    // extra_data 에 새 list 먼저 append — 실패 시 mutation 없이 return.
    kept_buf.append(ast.allocator, last_raw) catch return;
    const new_start: u32 = @intCast(ast.extra_data.items.len);
    ast.extra_data.appendSlice(ast.allocator, kept_buf.items) catch return;

    // 이 지점부터는 allocation 실패 없음 — 안전하게 decrement + rewrite.
    for (removed_buf.items) |raw| minify_mod.decrementRefsInExpr(ast, ctx, @enumFromInt(raw));
    ast.nodes.items[node_idx].data = .{
        .list = .{ .start = new_start, .len = @intCast(kept_buf.items.len) },
    };
    changed.* = true;
}

/// expression_statement 의 자식 expression 을 unused 맥락에서 축약하고, 최종적으로
/// removable 이면 `empty_statement` 로 교체한다.
/// `simplifyUnusedInPlace` 가 내부 부분 제거 (`a ? b : c;` → `a || c;` 등) 를 수행.
pub fn simplifyUnusedExprStmt(ast: *Ast, ctx: MinifyCtx, node_idx: u32, node: Node, changed: *bool) void {
    const operand = node.data.unary.operand;
    const removable = simplifyUnusedInPlace(ast, ctx, operand, changed, 0);
    if (removable) {
        minify_mod.decrementRefsInExpr(ast, ctx, operand);
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

/// `expression_statement` 의 operand 가 `parenthesized_expression` 이고 inner 가 statement
/// 시작 시 파싱 모호성이 없으면 paren 을 벗긴다.
///
/// **Leading-token 판정**: Statement 시작 자리에서 모호성을 유발하는 **첫 토큰** 은
///   - `{` — block 시작 → object / object-pattern assignment 모호
///   - `function` — function declaration → function expression 모호
///   - `class` — class declaration → class expression 모호
///
/// 이 토큰은 inner 자체뿐 아니라 `call(callee, args)` 의 callee, `a.b` 의 object, `a + b` 의
/// left, `(a, b, c)` 의 첫 원소 등 **leading operand 체인** 을 통해 드러난다.
/// 예: `(function(){})();` — call 의 callee 가 function_expression → statement 시작 시
/// `function(){}(...)` 가 되면 anonymous function declaration 으로 파싱 (syntax error).
///
/// `isSafeStmtLead` 가 leading operand 를 재귀로 따라 최상위 dangerous tag 를 탐지.
fn unwrapRedundantStmtParen(ast: *Ast, stmt_idx: u32, changed: *bool) void {
    const stmt = ast.nodes.items[stmt_idx];
    const op_ni = @intFromEnum(stmt.data.unary.operand);
    if (op_ni >= ast.nodes.items.len) return;
    const op_node = ast.nodes.items[op_ni];
    if (op_node.tag != .parenthesized_expression) return;

    const inner_idx = op_node.data.unary.operand;
    if (!isSafeStmtLead(ast, inner_idx, 0)) return;

    ast.nodes.items[stmt_idx].data = .{ .unary = .{ .operand = inner_idx, .flags = stmt.data.unary.flags } };
    changed.* = true;
}

const max_stmt_lead_depth: u32 = 64;

/// expression 의 **leading token chain** 이 statement 시작 자리에서 파싱 모호성을
/// 유발하는지 판정. true 면 안전 (paren 없이 statement 시작 가능), false 면 paren 필요.
///
/// 재귀: call/new 의 callee, member 의 object, binary/logical 의 left, conditional 의 test,
/// sequence 의 첫 원소, tagged_template 의 tag, assignment 의 left 등 leading 따라 내려감.
fn isSafeStmtLead(ast: *const Ast, idx: NodeIndex, depth: u32) bool {
    if (depth >= max_stmt_lead_depth) return false;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[ni];
    const d = depth + 1;

    return switch (node.tag) {
        // Leading token 이 `function` / `class` / `{` / `[` — statement 시작 시 모호.
        .function_expression,
        .arrow_function_expression,
        .class_expression,
        .object_expression,
        .array_expression,
        // Destructuring assignment target — `{v} = o;` / `[a] = b;` 가 block/array 시작으로 파싱.
        .object_assignment_target,
        .array_assignment_target,
        .object_pattern,
        .array_pattern,
        => false,

        // Assignment 의 LHS 재귀 판정 (위 target 이 directly LHS 면 false 로 떨어짐).
        .assignment_expression => isSafeStmtLead(ast, node.data.binary.left, d),

        // Leading operand 로 내려가는 케이스.
        .call_expression, .new_expression => blk: {
            const e = node.data.extra;
            if (!ast.hasExtra(e, 0)) break :blk false;
            break :blk isSafeStmtLead(ast, @enumFromInt(ast.readExtra(e, 0)), d);
        },
        .static_member_expression,
        .computed_member_expression,
        .private_field_expression,
        => blk: {
            const e = node.data.extra;
            if (!ast.hasExtra(e, 0)) break :blk false;
            break :blk isSafeStmtLead(ast, @enumFromInt(ast.readExtra(e, 0)), d);
        },
        .tagged_template_expression => blk: {
            const e = node.data.extra;
            if (!ast.hasExtra(e, 0)) break :blk false;
            break :blk isSafeStmtLead(ast, @enumFromInt(ast.readExtra(e, 0)), d);
        },
        .binary_expression, .logical_expression => isSafeStmtLead(ast, node.data.binary.left, d),
        .conditional_expression => isSafeStmtLead(ast, node.data.ternary.a, d),
        .sequence_expression => blk: {
            const list = node.data.list;
            if (list.len == 0 or list.start >= ast.extra_data.items.len) break :blk false;
            break :blk isSafeStmtLead(ast, @enumFromInt(ast.extra_data.items[list.start]), d);
        },
        .parenthesized_expression => true, // 이미 paren — 벗겨도 새 paren 이 생기지 않음
        // unary / update / literal / identifier / this / template 등은 leading 이
        // `!` / `+` / `++` / 리터럴 / identifier / backtick 등으로 안전.
        else => true,
    };
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
        .template_literal => rewriteTemplateLiteralUnused(ast, ctx, ni, node, changed, depth),
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
        minify_mod.decrementRefsInExpr(ast, ctx, left_idx);
        replaceNode(ast, ni, ast.nodes.items[right_ni], changed);
        return false;
    }
    if (right_rem) {
        // `impure == pure` → `impure`
        const left_ni = @intFromEnum(left_idx);
        if (left_ni >= ast.nodes.items.len) return false;
        minify_mod.decrementRefsInExpr(ast, ctx, right_idx);
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
    minify_mod.decrementRefsInExpr(ast, ctx, right_idx);
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
        minify_mod.decrementRefsInExpr(ast, ctx, cons_idx);
        minify_mod.decrementRefsInExpr(ast, ctx, alt_idx);
        replaceNode(ast, ni, ast.nodes.items[test_ni], changed);
        return isStmtRemovableDepth(ast, test_idx, ctx, d);
    }

    if (cons_rem) {
        // a ? [pure] : c → a || c
        const right_idx = ensureLogicalOperand(ast, alt_idx) catch return false;
        minify_mod.decrementRefsInExpr(ast, ctx, cons_idx);
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
        minify_mod.decrementRefsInExpr(ast, ctx, alt_idx);
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

    // realloc-safe 순회 — simplifyUnusedInPlace 재귀가 reduceToSequenceExpr → extra_data grow
    // → ArrayList realloc → 캡처된 indices slice invalid (#2422 동일 패턴, #2426).
    var iter = ast.iterateExtraList(list);
    while (iter.next()) |idx| {
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

    // realloc-safe 순회 — simplifyUnusedInPlace 재귀가 extra_data grow 가능 (#2426).
    var iter = ast.iterateExtraList(.{ .start = args_start, .len = args_len });
    while (iter.next()) |idx| {
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

    // realloc-safe 순회 — simplifyUnusedInPlace 재귀가 extra_data grow 가능 (#2426).
    var iter = ast.iterateExtraList(list);
    while (iter.next()) |prop_idx| {
        const prop_ni = @intFromEnum(prop_idx);
        const prop = ast.nodes.items[prop_ni];

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

/// Template literal 의 substitution expression 을 부분 축약 (oxc 방식).
///   - substitution 이 Symbol 가능성이 있으면 pending 에 쌓아 ToString 호출 유지 (`Symbol →
///     String` 변환은 TypeError — 관측 가능한 side-effect).
///   - impure substitution 을 만나면 쌓인 pending 을 새 template_literal 로 감싸 transformed
///     에 flush + impure 자체도 추가.
///   - pure substitution 은 drop.
///   - 끝에 남은 pending 도 새 template_literal 로 flush.
/// transformed 를 최종 sequence / single / empty 로 환원.
///
/// `data.none == 0` (substitution 없는 단순 `` `static` ``) 는 그대로 removable.
fn rewriteTemplateLiteralUnused(ast: *Ast, ctx: MinifyCtx, ni: u32, node: Node, changed: *bool, depth: u32) bool {
    if (node.data.none == 0) return true;
    const list = node.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return false;
    const items = ast.extra_data.items[list.start .. list.start + list.len];

    var pending: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer pending.deinit(ast.allocator);
    var transformed: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer transformed.deinit(ast.allocator);
    // 진짜 축약이 있었는지 추적 — 모든 substitution 이 canBeSymbol 이라 전부 pending 으로만
    // 쌓이면 결과물 template 이 원본과 의미 동일. fixed-point 에서 무한 재생성 방지.
    var dropped_or_split = false;

    for (items) |raw| {
        if (raw >= ast.nodes.items.len) return false;
        const child = ast.nodes.items[raw];
        if (child.tag == .template_element) continue;

        const idx: NodeIndex = @enumFromInt(raw);
        if (purity.canBeSymbol(ast, idx)) {
            pending.append(ast.allocator, idx) catch return false;
            continue;
        }

        const child_rem = simplifyUnusedInPlace(ast, ctx, idx, changed, depth + 1);
        if (child_rem) {
            dropped_or_split = true;
            continue;
        }

        // impure — flush pending 후 자체도 추가
        if (pending.items.len > 0) {
            const tmpl = buildTemplateLiteral(ast, pending.items, node.span) catch return false;
            transformed.append(ast.allocator, tmpl) catch return false;
            pending.clearRetainingCapacity();
        }
        transformed.append(ast.allocator, idx) catch return false;
        dropped_or_split = true;
    }

    // 아무것도 drop 되거나 split 되지 않았으면 rewrite 이득 없음 — 원본 유지.
    if (!dropped_or_split) return false;

    if (pending.items.len > 0) {
        const tmpl = buildTemplateLiteral(ast, pending.items, node.span) catch return false;
        transformed.append(ast.allocator, tmpl) catch return false;
    }

    return reduceToSequenceExpr(ast, ni, node.span, transformed.items, changed) catch false;
}

/// `exprs` 를 substitution 으로 갖는 새 template_literal 노드를 생성한다. 각 quasi 는
/// 빈 literal 조각 (`` ` ``, `` }${ ``, `` }` ``) 으로 raw text 없이 `${}` 만 남기는 형태.
/// string_table 에 넣은 리터럴 텍스트의 span 을 element 에 할당 — codegen 의 `writeNodeSpan`
/// 이 template_element 의 span 을 그대로 출력한다.
fn buildTemplateLiteral(ast: *Ast, exprs: []const NodeIndex, span: Span) !NodeIndex {
    std.debug.assert(exprs.len > 0);

    const n = exprs.len;
    const total_items = 2 * n + 1;

    try ast.extra_data.ensureUnusedCapacity(ast.allocator, total_items);
    try ast.nodes.ensureUnusedCapacity(ast.allocator, n + 2); // N+1 elements + 1 template_literal

    const new_start: u32 = @intCast(ast.extra_data.items.len);

    // 첫 quasi: `` `${ `` — backtick + ${
    ast.extra_data.appendAssumeCapacity(appendTemplateElement(ast, try ast.addString("`${")));

    for (exprs, 0..) |expr, i| {
        ast.extra_data.appendAssumeCapacity(@intFromEnum(expr));
        const elem_text = if (i == n - 1) "}`" else "}${";
        ast.extra_data.appendAssumeCapacity(appendTemplateElement(ast, try ast.addString(elem_text)));
    }

    const tmpl_ni: u32 = @intCast(ast.nodes.items.len);
    ast.nodes.appendAssumeCapacity(.{
        .tag = .template_literal,
        .span = span,
        .data = .{ .list = .{ .start = new_start, .len = @intCast(total_items) } },
    });
    return @enumFromInt(tmpl_ni);
}

/// 호출자 `buildTemplateLiteral` 이 `ensureUnusedCapacity` 로 미리 확보 — assume capacity 안전.
fn appendTemplateElement(ast: *Ast, elem_span: Span) u32 {
    const ni: u32 = @intCast(ast.nodes.items.len);
    ast.nodes.appendAssumeCapacity(.{
        .tag = .template_element,
        .span = elem_span,
        .data = .{ .none = 0 },
    });
    return ni;
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
