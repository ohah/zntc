//! Codegen helpers for comments and statement-level emission.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Kind = @import("../lexer/token.zig").Kind;
const string_escape = @import("../string_escape.zig");
const writer = @import("writer.zig");

const writeNewline = writer.writeNewline;
const writeIndent = writer.writeIndent;
const writeSpace = writer.writeSpace;
const trimTrailingSemicolonBeforeMinifyBoundary = writer.trimTrailingSemicolonBeforeMinifyBoundary;

/// 주석 출력. pos가 null이면 남은 모든 주석 출력 (trailing).
/// minify 모드에서는 legal comment (@license, @preserve, /*!)만 보존 (D022).
pub fn emitComments(self: anytype, pos: ?u32) !void {
    while (self.next_comment_idx < self.comments.len) {
        const comment = self.comments[self.next_comment_idx];
        if (pos) |p| {
            if (comment.start > p) break;
        }
        // minify 모드: legal comment만 출력
        if (self.options.minify_whitespace and !comment.is_legal) {
            self.next_comment_idx += 1;
            continue;
        }
        // 주석은 lexer가 직접 수집한 원문 span — 합성 노드 아님 (#1407 safe).
        try self.write(self.ast.source[comment.start..comment.end]);
        try writeNewline(self);
        // writeNewline 이 indent 를 먹으므로 후속 content 위해 복원 (#1508).
        try writeIndent(self);
        self.next_comment_idx += 1;
    }
}

/// skip_nodes로 마킹되어 codegen 시 생략되는지 확인. emitNode 내부의 early-return과
/// 동일 판정 — list emission에서 newline/indent를 미리 쓰지 않기 위해 사전 체크용.
pub fn isSkipped(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const meta = self.options.linking_metadata orelse return false;
    const node_idx = @intFromEnum(idx);
    return node_idx < meta.skip_nodes.capacity() and meta.skip_nodes.isSet(node_idx);
}

/// program/block 안 statement 가 출력 단계에서 elide 되는지. mangle skip_nodes 외에
/// `minify_whitespace` 모드에서는 `empty_statement` 도 elide — minify pass 가
/// dead declaration 을 empty_statement 로 변환한 결과 (`;;;` 누적) 가 그대로 출력
/// 되던 cosmetic 갭 정리. esbuild/oxc 도 동일 동작.
inline fn isElidedStmt(self: anytype, idx: NodeIndex) bool {
    if (isSkipped(self, idx)) return true;
    if (!self.options.minify_whitespace) return false;
    // `NodeIndex.none` 은 sentinel max — bound check 가 자연 차단.
    const ni = @intFromEnum(idx);
    if (ni >= self.ast.nodes.items.len) return false;
    return self.ast.nodes.items[ni].tag == .empty_statement;
}

pub fn emitProgram(self: anytype, node: Node) !void {
    const list = node.data.list;
    const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
    var emitted = false;
    for (indices) |raw_idx| {
        const node_idx: NodeIndex = @enumFromInt(raw_idx);
        if (node_idx.isNone()) continue;
        // skip_nodes된 statement는 emitNode가 early-return하지만 newline은 이미 찍혀
        // 빈 줄이 남는다 (#1602). 사전 체크로 해당 slot 전체를 건너뛴다.
        if (isElidedStmt(self, node_idx)) continue;
        // minify 시 standalone block_statement (`if(true){...}` fold 잔여 등) 가
        // declaration 을 가지지 않으면 unwrap — `{f()}` → `f();` (probe11).
        if (self.options.minify_whitespace) {
            if (tryUnwrapStandaloneBlock(self, node_idx)) |inner| {
                for (inner) |inner_raw| {
                    const inner_idx: NodeIndex = @enumFromInt(inner_raw);
                    if (inner_idx.isNone()) continue;
                    if (isElidedStmt(self, inner_idx)) continue;
                    if (emitted) try writeNewline(self);
                    try self.emitNode(inner_idx);
                    emitted = true;
                }
                continue;
            }
        }
        if (emitted) try writeNewline(self);
        try self.emitNode(node_idx);
        emitted = true;
    }
    if (emitted) try writeNewline(self);
    // 파일 끝에 남은 주석들 출력
    try emitComments(self, null);
}

/// `idx` 가 declaration 을 포함하지 않는 standalone block_statement 면 그 안의
/// statement indices slice 를 반환. unwrap 시 outer scope 와 의미 동일.
/// let/const/class/function declaration 은 block scope binding 이라 unwrap
/// 불가 (outer scope 로 leak). var 는 hoisting 으로 동등하지만 block 안 var
/// 가 다른 hoist scan 에 안 잡히는 경계 케이스 방어 (singleUnwrappableStmt 와
/// 동일 정책) — 보수적으로 var 도 거부.
fn tryUnwrapStandaloneBlock(self: anytype, idx: NodeIndex) ?[]const u32 {
    const node = self.ast.getNode(idx);
    if (node.tag != .block_statement) return null;
    const list = node.data.list;
    const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw| {
        const child_idx: NodeIndex = @enumFromInt(raw);
        if (child_idx.isNone()) continue;
        const child = self.ast.getNode(child_idx);
        switch (child.tag) {
            .variable_declaration => {
                const kind = self.ast.variableDeclarationKind(child);
                if (kind != .@"var") return null; // let/const → block-scoped, leak 위험
                return null; // var 도 hoist 경계 보수적 거부
            },
            .function_declaration, .class_declaration => return null,
            else => {},
        }
    }
    return indices;
}

pub fn emitBlock(self: anytype, node: Node) !void {
    try emitBracedList(self, node);
}

/// 제어흐름 본문(`if`/`else`/`for`/`while`/`for-in`/`for-of`/`do-while`) 또는 standalone
/// statement 자리(상수-조건 DCE 로 남은 분기)의 노드를 emit. minify 시 그 자리가 "벗겨도
/// 안전한" statement 하나뿐인 block 이면 `{}` 를 제거하고 그 statement 만 출력
/// (`if(x){f()}` → `if(x)f()`). 그 외에는 노드를 그대로 emit.
pub fn emitStatementBody(self: anytype, body_idx: NodeIndex) !void {
    if (unwrappedStatementBody(self, body_idx)) |inner| {
        try self.emitNode(inner);
        return;
    }
    try self.emitNode(body_idx);
}

/// `body_idx` 가 minify 시 `{}` 를 벗길 수 있는 block 이면 그 안의 단일 statement idx,
/// 아니면 null. `else` 키워드 spacing 결정에도 쓰여 별도 함수로 둔다.
fn unwrappedStatementBody(self: anytype, body_idx: NodeIndex) ?NodeIndex {
    if (!self.options.minify_whitespace or body_idx.isNone()) return null;
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement) return null;
    return singleUnwrappableStmt(self, body);
}

/// block 에서 "출력되는" statement 가 정확히 1개이고, 그게 `{}` 없이 단독으로 와도
/// 안전한 종류면 그 statement 의 idx 를 반환. 아니면 null.
///
/// **안전 조건**: lexical declaration(`let`/`const`/`class`/`function` 선언) 은 `if`/`for`
/// 본문으로 올 수 없으므로 거부. `if`/`for`/`while` 류는 뒤따르는 `else` 를 잘못 흡수
/// (dangling else)하거나 ASI 가 미묘해 보수적으로 거부. `var` 선언은 본문으로 valid 하고
/// hoisting 의미도 동일하므로 허용. `return`/`throw`/`break`/`continue`/`debugger`/
/// expression statement 는 `else` 흡수 불가 + lexical decl 아님 → 안전.
/// block 의 element 중 출력되는(= elided 아닌) statement 가 정확히 1개면 그 idx, 아니면 null
/// (0개 또는 2개+ → null).
fn singleNonElidedStmt(self: anytype, block: Node) ?NodeIndex {
    const list = block.data.list;
    const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
    var only: ?NodeIndex = null;
    for (indices) |raw| {
        const idx: NodeIndex = @enumFromInt(raw);
        if (isElidedStmt(self, idx)) continue;
        if (only != null) return null;
        only = idx;
    }
    return only;
}

fn singleUnwrappableStmt(self: anytype, block: Node) ?NodeIndex {
    const stmt_idx = singleNonElidedStmt(self, block) orelse return null; // 빈/2개+ block → `{}` 그대로
    const s = self.ast.getNode(stmt_idx);
    switch (s.tag) {
        .expression_statement,
        .return_statement,
        .throw_statement,
        .break_statement,
        .continue_statement,
        .debugger_statement,
        => return stmt_idx,
        // `var` 는 본문으로 valid + hoisting 동일 → 허용. 단 `esm_var_assign_only`
        // (wrapped ESM body) 에선 top-level `var` 키워드가 codegen 에서 제거되는데,
        // hoist scan 은 block 안 `var` 를 안 잡으므로 벗기면 미선언 할당 → 거부.
        .variable_declaration => return if (!self.options.esm_var_assign_only and
            self.ast.variableDeclarationKind(s) == .@"var") stmt_idx else null,
        else => return null,
    }
}

/// { item1 item2 ... } — 블록과 클래스 바디 공통.
/// `{` 앞 공백: 마지막 바이트가 공백/줄바꿈이 아니면 자동 추가 (이중 공백 방지).
pub fn emitBracedList(self: anytype, node: Node) !void {
    if (!self.options.minify_whitespace and self.buf.items.len > 0) {
        const last = self.buf.items[self.buf.items.len - 1];
        if (last != ' ' and last != '\n' and last != '\t') {
            try self.writeByte(' ');
        }
    }
    try self.writeByte('{');
    const list = node.data.list;
    const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
    if (indices.len > 0) {
        self.indent_level += 1;
        var i: usize = 0;
        while (i < indices.len) : (i += 1) {
            const idx: NodeIndex = @enumFromInt(indices[i]);
            if (isElidedStmt(self, idx)) continue;
            try writeNewline(self);
            try writeIndent(self);
            // #3110: `if(c)return A;` 바로 다음 형제가 `return B;` 면 `return c?A:B;` 로 합침.
            if (self.options.minify_syntax) {
                if (try tryEmitReturnFallthrough(self, indices, i)) |consumed_j| {
                    i = consumed_j; // loop 의 `: (i += 1)` 가 소비된 `return B;` 슬롯을 지나감
                    continue;
                }
            }
            try self.emitNode(idx);
        }
        self.indent_level -= 1;
    }
    trimTrailingSemicolonBeforeMinifyBoundary(self);
    try writeNewline(self);
    try writeIndent(self);
    try self.writeByte('}');
}

pub fn emitExpressionStatement(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.emitNode(node.data.unary.operand);
    try self.writeByte(';');
}

pub fn emitReturn(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("return");
    if (!node.data.unary.operand.isNone()) {
        try self.writeByte(' ');
        try emitNoLineTerminatorOperand(self, node.data.unary.operand);
    }
    try self.writeByte(';');
}

pub fn emitThrow(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("throw ");
    try emitNoLineTerminatorOperand(self, node.data.unary.operand);
    try self.writeByte(';');
}

/// `return` / `throw` 처럼 ECMAScript `NoLineTerminator` restriction 이 있는
/// keyword 직후의 operand 를 emit. operand 의 leading comments 를 newline 없이
/// inline (space-separated) 으로 미리 소비한다 — `emitNode` 가 호출되면 안에서
/// `emitComments` 가 newline + indent 를 끼우는데, 그게 keyword 직후에 오면
/// `return` 은 ASI 로 종료 (`return;`), `throw` 는 syntax error 가 된다.
/// `/* @__PURE__ */ jsxs(...)` 같은 leading annotation 이 흔한 회귀 케이스.
fn emitNoLineTerminatorOperand(self: anytype, operand: NodeIndex) !void {
    if (operand.isNone()) return;
    const operand_node = self.ast.getNode(operand);
    const has_real_span = operand_node.span.start != operand_node.span.end and
        (operand_node.span.start & ast_mod.Ast.STRING_TABLE_BIT) == 0;
    if (has_real_span) {
        try emitLeadingCommentsInline(self, operand_node.span.start);
    }
    try self.emitNode(operand);
}

/// `emitNoLineTerminatorOperand` 의 leading-comment 소비 — `emitComments` 와
/// 동일하나 줄바꿈 대신 space 로 구분한다.
fn emitLeadingCommentsInline(self: anytype, pos: u32) !void {
    while (self.next_comment_idx < self.comments.len) {
        const comment = self.comments[self.next_comment_idx];
        if (comment.start > pos) break;
        if (self.options.minify_whitespace and !comment.is_legal) {
            self.next_comment_idx += 1;
            continue;
        }
        try self.write(self.ast.source[comment.start..comment.end]);
        try self.writeByte(' ');
        self.next_comment_idx += 1;
    }
}

pub fn emitIf(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const t = node.data.ternary;
    // 상수 조건 DCE: if (false) → else만 출력, if (true) → then만 출력
    if (evalBooleanCondition(self, t.a)) |known| {
        if (!known) {
            // if (false) { ... } else { alt } → alt만 출력
            if (!t.c.isNone()) {
                if (isFunctionDeclarationNode(self, t.c)) return emitIfVerbatim(self, t);
                try emitStatementBody(self, t.c);
            }
            return;
        } else {
            // if (true) { ... } → then만 출력
            if (isFunctionDeclarationNode(self, t.b)) return emitIfVerbatim(self, t);
            try emitStatementBody(self, t.b);
            return;
        }
    }
    try emitIfVerbatim(self, t);
}

/// #3095: `cond` 가 paren 없이 `?:` test(= ShortCircuitExpression 또는 그보다 tight)
/// 자리에 올 수 있는 노드 tag 인지 — 보수적 whitelist. assignment / sequence / yield /
/// arrow / conditional 등은 `?:` 보다 느슨해 paren 이 필요하므로 거부 (transform skip).
fn isSafeTernaryTest(tag: ast_mod.Node.Tag) bool {
    return switch (tag) {
        .identifier_reference,
        .this_expression,
        .static_member_expression,
        .computed_member_expression,
        .private_field_expression,
        .call_expression,
        .new_expression,
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regexp_literal,
        .template_literal,
        .tagged_template_expression,
        .parenthesized_expression,
        .unary_expression,
        .update_expression,
        .await_expression,
        .binary_expression,
        .logical_expression,
        => true,
        else => false,
    };
}

/// `idx` 가 `return <expr>;` 이거나 그것 하나만 담은 block 이면 그 expr 의 idx, 아니면 null.
/// `return;` (인자 없음) 은 null.
fn singleReturnArg(self: anytype, idx_in: NodeIndex) ?NodeIndex {
    var idx = idx_in;
    if (idx.isNone()) return null;
    var n = self.ast.getNode(idx);
    if (n.tag == .block_statement) {
        idx = singleNonElidedStmt(self, n) orelse return null;
        n = self.ast.getNode(idx);
    }
    if (n.tag != .return_statement or n.data.unary.operand.isNone()) return null;
    return n.data.unary.operand;
}

/// `if(c){return A}else{...}` 체인 전체가 `return c?A:...` 로 평탄화 가능한지 (pure check).
/// then/else 가 모두 `return <expr>` 이거나 else 가 다시 같은 형태의 if 이고, 모든 cond 가
/// `?:` test 자리에 paren 없이 올 수 있으며, 모든 return arg 가 sequence(comma) 가 아닐 때.
fn canEmitIfReturnChain(self: anytype, t: anytype, depth: u8) bool {
    if (depth >= 32 or t.c.isNone()) return false;
    if (!isSafeTernaryTest(self.ast.getNode(t.a).tag)) return false;
    const a_arg = singleReturnArg(self, t.b) orelse return false;
    if (self.ast.getNode(a_arg).tag == .sequence_expression) return false;
    if (singleReturnArg(self, t.c)) |b_arg| {
        return self.ast.getNode(b_arg).tag != .sequence_expression;
    }
    const else_node = self.ast.getNode(t.c);
    return else_node.tag == .if_statement and canEmitIfReturnChain(self, else_node.data.ternary, depth + 1);
}

/// `canEmitIfReturnChain` 가 통과한 if 체인을 `cond?A:<rest>` 식으로 emit.
/// `is_first` 면 cond 를 `emitNoLineTerminatorOperand` 로 (`return` 직후 ASI 회피).
/// `?:` 는 right-assoc 이라 `a?1:b?2:3` 가 `a?1:(b?2:3)` 로 정확히 파싱됨 — paren 불필요.
fn emitIfReturnChainTail(self: anytype, t: anytype, is_first: bool) !void {
    if (is_first) try emitNoLineTerminatorOperand(self, t.a) else try self.emitNode(t.a);
    try writeSpace(self);
    try self.writeByte('?');
    try writeSpace(self);
    try self.emitNode(singleReturnArg(self, t.b).?);
    try writeSpace(self);
    try self.writeByte(':');
    try writeSpace(self);
    if (singleReturnArg(self, t.c)) |b_arg| {
        try self.emitNode(b_arg);
    } else {
        try emitIfReturnChainTail(self, self.ast.getNode(t.c).data.ternary, false);
    }
}

fn tryEmitIfReturnTernary(self: anytype, t: anytype) !bool {
    if (!self.options.minify_syntax or !canEmitIfReturnChain(self, t, 0)) return false;
    try self.write("return ");
    try emitIfReturnChainTail(self, t, true);
    try self.writeByte(';');
    return true;
}

/// statement list 의 `indices[i]` 가 `if(c)return A;` (else 없음/elided) 이고 바로 다음
/// 출력 statement 가 `return B;` 면 `return c?A:B;` 를 emit 하고 소비한 `return B;` 의
/// list 인덱스를 반환. 아니면 null. minify_syntax 전용 (emitBracedList 에서만 호출).
/// `c` 가 paren 없이 `?:` test 자리에 올 수 있고, A/B 가 sequence(comma) / void 가 아닐 때만.
fn tryEmitReturnFallthrough(self: anytype, indices: []const u32, i: usize) !?usize {
    const if_node = self.ast.getNode(@enumFromInt(indices[i]));
    if (if_node.tag != .if_statement) return null;
    const t = if_node.data.ternary;
    if (!t.c.isNone() and !isElidedAlternate(self, t.c)) return null; // else 가 있으면 #3095 가 처리
    if (evalBooleanCondition(self, t.a) != null) return null; // 상수 조건은 DCE 가 처리 (더 작음)
    if (!isSafeTernaryTest(self.ast.getNode(t.a).tag)) return null;
    const a_arg = singleReturnArg(self, t.b) orelse return null;
    if (self.ast.getNode(a_arg).tag == .sequence_expression) return null;
    var j = i + 1;
    while (j < indices.len and isElidedStmt(self, @enumFromInt(indices[j]))) : (j += 1) {}
    if (j >= indices.len) return null;
    const next = self.ast.getNode(@enumFromInt(indices[j]));
    if (next.tag != .return_statement or next.data.unary.operand.isNone()) return null;
    const b_arg = next.data.unary.operand;
    if (self.ast.getNode(b_arg).tag == .sequence_expression) return null;
    try self.write("return ");
    try emitNoLineTerminatorOperand(self, t.a); // `return` 직후 cond — leading comment ASI 회피
    try writeSpace(self);
    try self.writeByte('?');
    try writeSpace(self);
    try self.emitNode(a_arg);
    try writeSpace(self);
    try self.writeByte(':');
    try writeSpace(self);
    try self.emitNode(b_arg);
    try self.writeByte(';');
    return j;
}

/// `idx` 가 `<expr>;` (expression statement) 이거나 그것 하나만 담은 block 이면 그 expr 의 idx,
/// 아니면 null.
fn singleExprStmt(self: anytype, idx_in: NodeIndex) ?NodeIndex {
    var idx = idx_in;
    if (idx.isNone()) return null;
    var n = self.ast.getNode(idx);
    if (n.tag == .block_statement) {
        idx = singleNonElidedStmt(self, n) orelse return null;
        n = self.ast.getNode(idx);
    }
    if (n.tag != .expression_statement) return null;
    return n.data.unary.operand;
}

/// `&&` 의 좌/우 피연산자로 paren 없이 올 수 있는 노드 tag 인지 — `?:` test whitelist 에서
/// `logical_expression` 만 추가로 제외 (`||`/`??` 가 `&&` 보다 느슨해 `(a||b)&&c` paren 필요;
/// `a&&b` 는 valid 지만 op 검사 회피 위해 통째로 제외 — 보수적).
fn isSafeAndOperand(tag: ast_mod.Node.Tag) bool {
    return isSafeTernaryTest(tag) and tag != .logical_expression;
}

/// `if(c){a()}else{b()}` → `c?a():b();`, `if(c){a()}` (else 없음/elided) → `c&&a();`.
/// minify_syntax 전용. 양쪽 본문이 단일 expression statement 이고 paren-safety 충족 시만.
fn tryEmitIfExprStatement(self: anytype, t: anytype) !bool {
    if (!self.options.minify_syntax) return false;
    const then_expr = singleExprStmt(self, t.b) orelse return false;
    const has_else = !t.c.isNone() and !isElidedAlternate(self, t.c);
    if (!has_else) {
        // `if(c)a();` → `c&&a();` — c 와 a() 둘 다 `&&` 피연산자로 paren 없이 와야 함.
        if (!isSafeAndOperand(self.ast.getNode(t.a).tag)) return false;
        if (!isSafeAndOperand(self.ast.getNode(then_expr).tag)) return false;
        try self.emitNode(t.a);
        try writeSpace(self);
        try self.write("&&");
        try writeSpace(self);
        try self.emitNode(then_expr);
        try self.writeByte(';');
        return true;
    }
    const else_expr = singleExprStmt(self, t.c) orelse return false;
    if (!isSafeTernaryTest(self.ast.getNode(t.a).tag)) return false;
    if (self.ast.getNode(then_expr).tag == .sequence_expression) return false;
    if (self.ast.getNode(else_expr).tag == .sequence_expression) return false;
    try self.emitNode(t.a);
    try writeSpace(self);
    try self.writeByte('?');
    try writeSpace(self);
    try self.emitNode(then_expr);
    try writeSpace(self);
    try self.writeByte(':');
    try writeSpace(self);
    try self.emitNode(else_expr);
    try self.writeByte(';');
    return true;
}

fn emitIfVerbatim(self: anytype, t: anytype) !void {
    if (try tryEmitIfReturnTernary(self, t)) return;
    if (try tryEmitIfExprStatement(self, t)) return;
    if (self.options.minify_whitespace) try self.write("if(") else try self.write("if (");
    try self.emitNode(t.a);
    try self.writeByte(')');
    try emitStatementBody(self, t.b);
    if (!t.c.isNone()) {
        // else 분기가 DCE 결과 비어 있으면 else 키워드 자체를 생략 (#2967).
        // 변환 전 transformer 가 dead `if` 본문을 `empty_statement` 로 바꿨거나
        // 빈 block 으로 만들면 minify 시 statement 가 사라져 `else }` SyntaxError.
        if (isElidedAlternate(self, t.c)) return;
        if (self.options.minify_whitespace) {
            // else 분기가 `{...}` 로 출력되면 `else{`, 아니면(bare statement 또는
            // #3094 로 `{}` 가 벗겨지는 block) 키워드 뒤 공백 필수.
            const emits_braces = self.ast.getNode(t.c).tag == .block_statement and
                unwrappedStatementBody(self, t.c) == null;
            try self.write(if (emits_braces) "else" else "else ");
        } else {
            try self.write(" else ");
        }
        try emitStatementBody(self, t.c);
    }
}

fn isFunctionDeclarationNode(self: anytype, node_idx: NodeIndex) bool {
    if (node_idx.isNone() or @intFromEnum(node_idx) >= self.ast.nodes.items.len) return false;
    return self.ast.getNode(node_idx).tag == .function_declaration;
}

/// else 분기가 출력 후 빈 statement 가 되는지 검사 (#2967):
///   - `empty_statement` (transformer 가 dead `if` 를 변환한 결과)
///   - dead `if (false)` 체인
///   - 모든 element 가 elided 인 block
/// 셋 다 minify 시 `else }` SyntaxError 를 만들므로 else 키워드 자체를 elide.
fn isElidedAlternate(self: anytype, node_idx: NodeIndex) bool {
    return isElidedAlternateDepth(self, node_idx, 0);
}

fn isElidedAlternateDepth(self: anytype, node_idx: NodeIndex, depth: u32) bool {
    if (depth >= 128) return false;
    if (node_idx.isNone() or @intFromEnum(node_idx) >= self.ast.nodes.items.len) return false;
    const n = self.ast.getNode(node_idx);
    switch (n.tag) {
        .empty_statement => return true,
        .if_statement => return isDeadIfNodeDepth(self, node_idx, depth + 1),
        .block_statement => {
            const list = n.data.list;
            const indices = self.ast.extra_data.items[list.start .. list.start + list.len];
            for (indices) |raw| {
                const idx: NodeIndex = @enumFromInt(raw);
                if (!isElidedAlternateDepth(self, idx, depth + 1)) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// else 분기의 if_statement가 상수 조건 DCE로 아무것도 출력하지 않는지 재귀 확인.
/// `else if (false) { ... }` → dead, `else if (false) { ... } else if (false) { ... }` → dead
fn isDeadIfNode(self: anytype, node_idx: NodeIndex) bool {
    return isDeadIfNodeDepth(self, node_idx, 0);
}

fn isDeadIfNodeDepth(self: anytype, node_idx: NodeIndex, depth: u32) bool {
    if (depth >= 128) return false;
    if (node_idx.isNone() or @intFromEnum(node_idx) >= self.ast.nodes.items.len) return false;
    const n = self.ast.getNode(node_idx);
    if (n.tag != .if_statement) return false;
    const t = n.data.ternary;
    const known = evalBooleanCondition(self, t.a) orelse return false;
    if (known) return false;
    if (t.c.isNone()) return true;
    return isDeadIfNodeDepth(self, t.c, depth + 1);
}

/// 조건 노드가 컴파일 타임 boolean으로 확정되면 값을 반환한다.
pub fn evalBooleanCondition(self: anytype, cond_idx: NodeIndex) ?bool {
    return evalBooleanConditionDepth(self, cond_idx, 0);
}

fn evalBooleanConditionDepth(self: anytype, cond_idx: NodeIndex, depth: u8) ?bool {
    if (depth >= 8) return null;
    if (cond_idx.isNone() or @intFromEnum(cond_idx) >= self.ast.nodes.items.len) return null;
    const cond = self.ast.getNode(cond_idx);
    return switch (cond.tag) {
        .boolean_literal => {
            const text = self.ast.getText(cond.span);
            return std.mem.eql(u8, text, "true");
        },
        .identifier_reference => {
            const text = self.ast.getText(cond.span);
            if (std.mem.eql(u8, text, "true")) return true;
            if (std.mem.eql(u8, text, "false")) return false;
            const meta = self.options.linking_metadata orelse return null;
            const sym_id = self.resolveSymbolId(cond_idx, meta) orelse return null;
            const cv = meta.const_values.get(sym_id) orelse return null;
            return switch (cv.kind) {
                .true_ => true,
                .false_ => false,
                .number => (ast_mod.parseNumericText(cv.number_text) orelse return null) != 0,
                else => null,
            };
        },
        .null_literal => false,
        .numeric_literal => {
            const text = self.ast.getText(cond.span);
            const n = ast_mod.parseNumericText(text) orelse return null;
            return n != 0;
        },
        .logical_expression => {
            const left = evalBooleanConditionDepth(self, cond.data.binary.left, depth + 1) orelse return null;
            const log_op: Kind = @enumFromInt(cond.data.binary.flags);
            if (log_op == .amp2 and !left) return false;
            if (log_op == .pipe2 and left) return true;
            return null;
        },
        .parenthesized_expression => {
            return evalBooleanConditionDepth(self, cond.data.unary.operand, depth + 1);
        },
        .unary_expression => {
            // unary_expression은 extra 저장: extra_data[e] = operand, extra_data[e+1] = operator
            const e = cond.data.extra;
            const extras = self.ast.extra_data.items;
            if (e + 1 >= extras.len) return null;
            const operand_idx: NodeIndex = @enumFromInt(extras[e]);
            const op: Kind = @enumFromInt(@as(u8, @truncate(extras[e + 1])));
            if (op == .bang) {
                if (evalBooleanConditionDepth(self, operand_idx, depth + 1)) |v| return !v;
            }
            return null;
        },
        .binary_expression => {
            // string-literal 양쪽 비교만 처리 (#2967): define 으로
            // `process.env.NODE_ENV !== "production"` 이 `"production" !== "production"`
            // 으로 inline 된 후 isDeadIfNode 가 dead branch 를 잡을 수 있도록.
            // 다른 binary op (number, identifier 등) 는 부수효과/런타임 의존이라 evaluate
            // 안 함 — esbuild 도 동일하게 string equality 만 안전 평가.
            const op: Kind = @enumFromInt(cond.data.binary.flags);
            //   eq2 = `==`, eq3 = `===`, neq = `!=`, neq2 = `!==`
            if (op != .eq2 and op != .eq3 and op != .neq and op != .neq2) return null;
            const left = self.ast.getNode(cond.data.binary.left);
            const right = self.ast.getNode(cond.data.binary.right);
            if (left.tag != .string_literal or right.tag != .string_literal) return null;
            const lt_raw = self.ast.getText(left.span);
            const rt_raw = self.ast.getText(right.span);
            const eq = stringLiteralValuesEqual(self.allocator, lt_raw, rt_raw) orelse return null;
            return switch (op) {
                .eq2, .eq3 => eq,
                .neq, .neq2 => !eq,
                else => unreachable,
            };
        },
        else => null,
    };
}

/// string_literal span 은 quote 포함이다. Raw body 비교는 `"Ā"` 와 `"\u0100"`을
/// 다르게 보므로 JS 문자열 값으로 디코드한 뒤 비교한다.
fn stringLiteralValuesEqual(allocator: std.mem.Allocator, left_raw: []const u8, right_raw: []const u8) ?bool {
    const left = string_escape.decodeJsStringLiteral(allocator, left_raw) catch return null;
    defer allocator.free(left);
    const right = string_escape.decodeJsStringLiteral(allocator, right_raw) catch return null;
    defer allocator.free(right);
    return std.mem.eql(u8, left, right);
}

pub fn emitWhile(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    if (self.options.minify_whitespace) try self.write("while(") else try self.write("while (");
    try self.emitNode(node.data.binary.left);
    try self.writeByte(')');
    try emitStatementBody(self, node.data.binary.right);
}

pub fn emitDoWhile(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("do");
    const body = node.data.binary.right;
    // block body 면 emitBracedList 가 `{` 앞 공백을 관리. non-block(또는 #3094 로 `{}` 가
    // 벗겨질 block)은 키워드 뒤 공백 필수 (`dox++` 방지).
    const body_is_braces = !body.isNone() and self.ast.getNode(body).tag == .block_statement and
        unwrappedStatementBody(self, body) == null;
    if (!body_is_braces) try self.writeByte(' ');
    try emitStatementBody(self, body);
    if (self.options.minify_whitespace) try self.write("while(") else try self.write(" while (");
    try self.emitNode(node.data.binary.left);
    try self.write(");");
}

pub fn emitFor(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 4];
    if (self.options.minify_whitespace) try self.write("for(") else try self.write("for (");
    // in_for_init을 save/restore로 관리: init 안에 중첩된 for/for-in/for-of가 있으면
    // 내부 for가 끝날 때 plain assignment로 되돌리지 않도록 해야 한다. (#1564 Case 1)
    const saved_for_init = self.in_for_init;
    self.in_for_init = true;
    try self.emitNode(@enumFromInt(extras[0]));
    if (self.options.minify_whitespace) try self.writeByte(';') else try self.write("; ");
    self.in_for_init = saved_for_init;
    try self.emitNode(@enumFromInt(extras[1]));
    if (self.options.minify_whitespace) try self.writeByte(';') else try self.write("; ");
    try self.emitNode(@enumFromInt(extras[2]));
    try self.writeByte(')');
    try emitStatementBody(self, @enumFromInt(extras[3]));
}

pub fn emitForAwaitOf(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const t = node.data.ternary;
    // for-in/of 와 동일한 var initializer hoist/skip 처리.
    // ES2015 block-scoping 다운레벨이 `const/let x` → `var x = void 0` 로 바꾼
    // 경우 for-await 헤드에 `var x = void 0 of ...` 가 그대로 출력되면 문법 오류.
    if (try tryHoistForInVarInit(self, t.a)) {
        try writeNewline(self);
        try writeIndent(self);
    }
    if (self.options.minify_whitespace) try self.write("for await(") else try self.write("for await (");
    const saved_for_init = self.in_for_init;
    const saved_skip_var_init = self.skip_var_init;
    self.in_for_init = true;
    self.skip_var_init = try shouldSkipVarInit(self, t.a);
    try self.emitNode(t.a);
    self.in_for_init = saved_for_init;
    self.skip_var_init = saved_skip_var_init;
    try self.write(" of ");
    try self.emitNode(t.b);
    try self.writeByte(')');
    try emitStatementBody(self, t.c);
}

pub fn emitForInOf(self: anytype, node: Node, keyword: []const u8) !void {
    try self.addSourceMapping(node.span);
    const t = node.data.ternary;

    // for-in var initializer hoisting (esbuild 호환):
    // `for (var x = expr in y)` → `x = expr;\nfor (var x in y)`
    // TS에서 `for (var x = Array<number> in y)` 같은 패턴에서 타입 인자가
    // 스트리핑되어 initializer가 남을 수 있다. 이를 별도 문장으로 hoisting.
    if (try tryHoistForInVarInit(self, t.a)) {
        try writeNewline(self);
        try writeIndent(self);
    }

    if (self.options.minify_whitespace) try self.write("for(") else try self.write("for (");
    const saved_for_init = self.in_for_init;
    const saved_skip_var_init = self.skip_var_init;
    self.in_for_init = true;
    self.skip_var_init = try shouldSkipVarInit(self, t.a);
    try self.emitNode(t.a);
    self.in_for_init = saved_for_init;
    self.skip_var_init = saved_skip_var_init;
    try self.writeByte(' ');
    try self.write(keyword);
    try self.writeByte(' ');
    try self.emitNode(t.b);
    try self.writeByte(')');
    try emitStatementBody(self, t.c);
}

/// for-in var initializer가 있으면 `name = init;`를 hoisting 출력.
/// 출력했으면 true, 아니면 false.
fn tryHoistForInVarInit(self: anytype, left: NodeIndex) !bool {
    if (left.isNone()) return false;
    const left_node = self.ast.getNode(left);
    if (left_node.tag != .variable_declaration) return false;

    const extras = self.ast.extra_data.items;
    const e = left_node.data.extra;
    const list_start = extras[e + 1];
    const list_len = extras[e + 2];
    if (list_len == 0) return false;

    const first_decl: NodeIndex = @enumFromInt(extras[list_start]);
    if (first_decl.isNone()) return false;
    const decl_node = self.ast.getNode(first_decl);
    if (decl_node.tag != .variable_declarator) return false;

    const name: NodeIndex = @enumFromInt(extras[decl_node.data.extra]);
    const init_val: NodeIndex = @enumFromInt(extras[decl_node.data.extra + 2]);
    if (init_val.isNone()) return false;

    // name = init;
    try self.emitNode(name);
    try writeSpace(self);
    try self.writeByte('=');
    try writeSpace(self);
    try self.emitNode(init_val);
    try self.writeByte(';');
    return true;
}

/// for-in left가 initializer를 가진 var declaration인지 확인.
/// hoisting된 경우 emitVariableDeclarator에서 init를 스킵하기 위함.
fn shouldSkipVarInit(self: anytype, left: NodeIndex) !bool {
    if (left.isNone()) return false;
    const left_node = self.ast.getNode(left);
    if (left_node.tag != .variable_declaration) return false;

    const extras = self.ast.extra_data.items;
    const e = left_node.data.extra;
    const list_start = extras[e + 1];
    const list_len = extras[e + 2];
    if (list_len == 0) return false;

    const first_decl: NodeIndex = @enumFromInt(extras[list_start]);
    if (first_decl.isNone()) return false;
    const decl_node = self.ast.getNode(first_decl);
    if (decl_node.tag != .variable_declarator) return false;

    const init_val: NodeIndex = @enumFromInt(extras[decl_node.data.extra + 2]);
    return !init_val.isNone();
}

pub fn emitSwitch(self: anytype, node: Node) !void {
    // 파서 구조: extra = [discriminant, cases_start, cases_len]
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 3];
    const discriminant: NodeIndex = @enumFromInt(extras[0]);
    const cases_start = extras[1];
    const cases_len = extras[2];

    if (self.options.minify_whitespace) try self.write("switch(") else try self.write("switch (");
    try self.emitNode(discriminant);
    try self.writeByte(')');
    try writeSpace(self);
    try self.writeByte('{');
    if (cases_len > 0) {
        self.indent_level += 1;
        const case_indices = self.ast.extra_data.items[cases_start .. cases_start + cases_len];
        for (case_indices) |raw_idx| {
            try writeNewline(self);
            try writeIndent(self);
            try self.emitNode(@enumFromInt(raw_idx));
        }
        self.indent_level -= 1;
        try writeNewline(self);
        try writeIndent(self);
    }
    try self.writeByte('}');
}

pub fn emitSwitchCase(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    // 파서 구조: extra = [test_expr, stmts_start, stmts_len]
    // test_expr가 none이면 default:
    const e = node.data.extra;
    const extras = self.ast.extra_data.items[e .. e + 3];
    const test_expr: NodeIndex = @enumFromInt(extras[0]);
    const stmts_start = extras[1];
    const stmts_len = extras[2];

    if (test_expr.isNone()) {
        try self.write("default:");
    } else {
        try self.write("case ");
        try self.emitNode(test_expr);
        try self.writeByte(':');
    }

    if (stmts_len > 0) {
        self.indent_level += 1;
        const stmt_indices = self.ast.extra_data.items[stmts_start .. stmts_start + stmts_len];
        for (stmt_indices) |raw_idx| {
            try writeNewline(self);
            try writeIndent(self);
            try self.emitNode(@enumFromInt(raw_idx));
        }
        self.indent_level -= 1;
    }
}

pub fn emitSimpleStmt(self: anytype, node: Node, keyword: []const u8) !void {
    try self.addSourceMapping(node.span);
    try self.write(keyword);
    // label이 있으면 출력
    if (!node.data.unary.operand.isNone()) {
        try self.writeByte(' ');
        try self.emitNode(node.data.unary.operand);
    }
    try self.writeByte(';');
}

pub fn emitTry(self: anytype, node: Node) !void {
    const t = node.data.ternary;
    try self.write("try");
    try writeSpace(self);
    try self.emitNode(t.a); // block
    if (!t.b.isNone()) {
        try writeSpace(self);
        try self.emitNode(t.b); // catch
    }
    if (!t.c.isNone()) {
        try writeSpace(self);
        try self.write("finally");
        try writeSpace(self);
        try self.emitNode(t.c);
    }
}

pub fn emitCatch(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("catch");
    if (!node.data.binary.left.isNone()) {
        if (self.options.minify_whitespace) try self.writeByte('(') else try self.write(" (");
        try self.emitNode(node.data.binary.left);
        try self.writeByte(')');
    }
    try self.emitNode(node.data.binary.right);
}

pub fn emitLabeled(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.emitNode(node.data.binary.left);
    try self.writeByte(':');
    try self.emitNode(node.data.binary.right);
}

pub fn emitWith(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("with(");
    try self.emitNode(node.data.binary.left);
    try self.writeByte(')');
    try self.emitNode(node.data.binary.right);
}
