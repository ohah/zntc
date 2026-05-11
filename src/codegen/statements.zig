//! Codegen helpers for comments and statement-level emission.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Kind = @import("../lexer/token.zig").Kind;
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
        if (emitted) try writeNewline(self);
        try self.emitNode(node_idx);
        emitted = true;
    }
    if (emitted) try writeNewline(self);
    // 파일 끝에 남은 주석들 출력
    try emitComments(self, null);
}

pub fn emitBlock(self: anytype, node: Node) !void {
    try emitBracedList(self, node);
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
        for (indices) |raw_idx| {
            const idx: NodeIndex = @enumFromInt(raw_idx);
            if (isElidedStmt(self, idx)) continue;
            try writeNewline(self);
            try writeIndent(self);
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
                try self.emitNode(t.c);
            }
            return;
        } else {
            // if (true) { ... } → then만 출력
            if (isFunctionDeclarationNode(self, t.b)) return emitIfVerbatim(self, t);
            try self.emitNode(t.b);
            return;
        }
    }
    try emitIfVerbatim(self, t);
}

fn emitIfVerbatim(self: anytype, t: anytype) !void {
    if (self.options.minify_whitespace) try self.write("if(") else try self.write("if (");
    try self.emitNode(t.a);
    try self.writeByte(')');
    try self.emitNode(t.b);
    if (!t.c.isNone()) {
        // else 분기가 DCE 결과 비어 있으면 else 키워드 자체를 생략 (#2967).
        // 변환 전 transformer 가 dead `if` 본문을 `empty_statement` 로 바꿨거나
        // 빈 block 으로 만들면 minify 시 statement 가 사라져 `else }` SyntaxError.
        if (isElidedAlternate(self, t.c)) return;
        if (self.options.minify_whitespace) {
            const next_node = self.ast.getNode(t.c);
            if (next_node.tag == .block_statement) {
                try self.write("else");
            } else {
                try self.write("else ");
            }
        } else {
            try self.write(" else ");
        }
        try self.emitNode(t.c);
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
            // string_literal span 은 quote 포함. 다른 quote 문자 (single vs double) 라도
            // value 가 같으면 같음으로 — quote 제거 비교.
            const lt_raw = self.ast.getText(left.span);
            const rt_raw = self.ast.getText(right.span);
            const lt = stripQuotes(lt_raw);
            const rt = stripQuotes(rt_raw);
            const eq = std.mem.eql(u8, lt, rt);
            return switch (op) {
                .eq2, .eq3 => eq,
                .neq, .neq2 => !eq,
                else => unreachable,
            };
        },
        else => null,
    };
}

/// string literal span (quote 포함) → 내용만. escape 시퀀스는 정확히 같으면 통과,
/// 다르면 보수적으로 비교 실패 처리해도 무방 (false negative 만 → DCE 효과 약간 감소).
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    const first = s[0];
    const last = s[s.len - 1];
    if ((first == '"' or first == '\'' or first == '`') and first == last) {
        return s[1 .. s.len - 1];
    }
    return s;
}

pub fn emitWhile(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    if (self.options.minify_whitespace) try self.write("while(") else try self.write("while (");
    try self.emitNode(node.data.binary.left);
    try self.writeByte(')');
    try self.emitNode(node.data.binary.right);
}

pub fn emitDoWhile(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("do");
    // block body는 emitBracedList가 { 앞 공백 관리, non-block은 공백 필수 (dox++ 방지)
    if (node.data.binary.right.isNone() or self.ast.getNode(node.data.binary.right).tag != .block_statement) {
        try self.writeByte(' ');
    }
    try self.emitNode(node.data.binary.right);
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
    try self.emitNode(@enumFromInt(extras[3]));
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
    try self.emitNode(t.c);
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
    try self.emitNode(t.c);
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
