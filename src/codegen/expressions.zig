//! Expression and member-expression emit helpers for Codegen.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Kind = @import("../lexer/token.zig").Kind;
const unicode = @import("../lexer/unicode.zig");
const calls = @import("calls.zig");
const precedence = @import("precedence.zig");
const Level = precedence.Level;
const ExprFlags = precedence.ExprFlags;
const ConstValue = @import("../semantic/symbol.zig").ConstValue;

/// minify_syntax 시 string_literal 객체 키를 따옴표 없이 emit 가능한지.
/// `raw` 는 따옴표 포함 리터럴 텍스트. escape 없는 단순 리터럴이고 valid ES
/// IdentifierName 이며 `__proto__` 가 아닐 때만 true. 객체 키는 reserved
/// word 도 valid 라 reserved 검사 불필요; `{"__proto__":v}` 는 일반 프로퍼티,
/// `{__proto__:v}` 는 proto setter 라 semantic 이 달라져 반드시 제외.
fn objectKeyUnquotable(raw: []const u8) bool {
    if (raw.len < 2) return false;
    const q = raw[0];
    if ((q != '"' and q != '\'') or raw[raw.len - 1] != q) return false;
    const s = raw[1 .. raw.len - 1];
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, '\\') != null) return false;
    if (std.mem.eql(u8, s, "__proto__")) return false;
    if (!unicode.isIdentifierStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!unicode.isIdentifierContinue(c)) return false;
    }
    return true;
}

pub fn emitUnary(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // PR6: wrap = level.gte(.prefix)
    _ = flags;
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (e + 1 >= extras.len) return;
    const operand: NodeIndex = @enumFromInt(extras[e]);
    const op: Kind = @enumFromInt(@as(u8, @truncate(extras[e + 1])));
    if (op == .bang and self.options.linking_metadata != null) {
        if (self.evalBooleanCondition(operand)) |v| {
            try self.write(if (!v) "true" else "false");
            return;
        }
    }
    const is_keyword_op = op == .kw_typeof or op == .kw_void or op == .kw_delete;
    // 직전 연산자와 붙어 `--`/`++` 로 합쳐지면 한 칸 끼운다 (`- -x`, `- --x`) (#4482).
    if (!is_keyword_op) try self.printSpaceBeforeOperator(op);
    try self.write(op.symbol());
    if (is_keyword_op) {
        try self.writeByte(' ');
    } else {
        // 이 `-`/`+`/`!` 도 다음 토큰과 합쳐질 수 있다 → 기록.
        self.recordOperatorToken(op);
    }
    // operand level = .prefix.lower() (esbuild EUnary value = LPrefix-1)
    try self.emitExpr(operand, Level.prefix.lower(), .{});
}

pub fn emitUpdate(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // PR6: prefix→wrap=level.gte(.prefix), postfix→level.gte(.postfix)
    _ = flags;
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    const extras = self.ast.extra_data.items;
    if (e + 1 >= extras.len) return;
    const operand: NodeIndex = @enumFromInt(extras[e]);
    const extra_flags = extras[e + 1];
    const is_postfix = (extra_flags & ast_mod.UnaryFlags.postfix) != 0;
    const op: Kind = @enumFromInt(@as(u8, @truncate(extra_flags)));
    if (!is_postfix) {
        // 직전 연산자와 붙어 `---`(=`--`+`-`) 나 `<!--`(HTML 주석) 가 되면 한 칸 끊는다.
        try self.printSpaceBeforeOperator(op);
        try self.write(op.symbol());
        self.recordOperatorToken(op);
    }
    // operand 는 update 의 lvalue 타겟 — 미존재 ns 멤버를 `(void 0)` 으로 바꾸면
    // `(void 0)++` SyntaxError 가 되므로 emitStaticMember 가 재작성을 건너뛰게 한다.
    self.member_assign_target = true;
    // operand level: postfix→.postfix.lower()(=.prefix), prefix→.prefix.lower()(=.exponentiation)
    const operand_level = if (is_postfix) Level.postfix.lower() else Level.prefix.lower();
    try self.emitExpr(operand, operand_level, .{});
    self.member_assign_target = false;
    if (is_postfix) {
        try self.write(op.symbol());
        self.recordOperatorToken(op);
    }
}

/// 이항 연산자 심볼 + 양옆 spacing 을 좌/우 피연산자 사이에 emit. 재귀·반복 경로 공용.
fn emitBinaryOperator(self: anytype, node: Node) !void {
    const op: Kind = @enumFromInt(node.data.binary.flags);
    if (op == .kw_in or op == .kw_instanceof) {
        // 영문 키워드 연산자는 양옆 공백 필수 (`a in b` ≠ `ainb`) — minify 와 무관.
        try self.writeByte(' ');
        try self.write(op.symbol());
        try self.writeByte(' ');
    } else {
        // RHS 가 `+`/`-` 로 시작해 토큰이 합쳐지는 경우(`a+ +b`)는 RHS 자신이 emit 직전에
        // printSpaceBeforeOperator 로 끊는다 — 여기선 이 연산자를 기록만 한다 (#4482).
        // 좌측은 합쳐질 일 없음: postfix `a++` + `+b` 는 `a+++b` 로 다시 lex 해도
        // `(a++)+b` 라 의미가 같다.
        try self.writeSpace();
        try self.write(op.symbol());
        self.recordOperatorToken(op);
        try self.writeSpace();
    }
}

/// idx 가 좌결합 평탄화 대상 스파인 노드인지. binary 는 항상, logical 은 상수 단락(fold)이
/// 없을 때(linking_metadata == null)만 — fold 는 좌/우 일부만 emit 해 평탄화를 깨므로 그땐
/// 재귀 경로로 둔다(깊은 `&&`/`||` 체인 + 번들 상수폴드 조합은 드묾). (#4123)
fn emitSpineContinues(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return false;
    const t = self.ast.getNode(idx).tag;
    if (t == .binary_expression) return true;
    if (t == .logical_expression and self.options.linking_metadata == null) return true;
    return false;
}

const BinaryChildLevels = struct { left: Level, right: Level };

/// binary/logical 노드가 좌/우 자식에 내려보내는 precedence level (esbuild
/// binaryExprVisitor.checkAndPrepare). 좌결합 → right=entry, left=entry.lower();
/// 우결합(`**`) → left=entry, right=entry.lower(). `??`↔`||`/`&&` 혼용 금지와 `**`
/// 좌단항 강제괄호 특수처리 포함. (PR5: 계산만, wrap 발동은 PR6.)
fn binaryChildLevels(self: anytype, node: Node) BinaryChildLevels {
    const op: Kind = @enumFromInt(node.data.binary.flags);
    const entry = precedence.binaryOpLevel(op) orelse return .{ .left = .lowest, .right = .lowest };
    var left_level = if (precedence.isRightAssociative(op)) entry else entry.lower();
    var right_level = if (precedence.isLeftAssociative(op)) entry else entry.lower();
    if (op == .question2) {
        // `??` 와 `||`/`&&` 는 괄호 없이 혼용 불가 → 자식이 `||`/`&&` 면 강제 괄호.
        if (binaryChildIsLogical(self, node.data.binary.left)) left_level = .prefix;
        if (binaryChildIsLogical(self, node.data.binary.right)) right_level = .prefix;
    } else if (op == .star2) {
        // `**` 좌측은 단항을 직접 가질 수 없음(`-a**b` 는 SyntaxError) → 강제 괄호.
        if (powLeftNeedsParen(self, node.data.binary.left)) left_level = .call;
    }
    return .{ .left = left_level, .right = right_level };
}

/// transparent wrapper(paren/chain/TS·Flow type cast)를 벗겨 실제 피연산자 노드를 반환.
/// emitParen 투명화(#4042) 후, 자식 노드 구조를 *직접* 검사하는 헬퍼들(`??`/`||` 혼용,
/// `**` 좌단항, RHS 부호 토큰)은 래퍼 너머의 실제 노드를 봐야 정확하다 — 래퍼는 더 이상
/// `(` 를 출력하지 않으므로 출력 시작 토큰이 안쪽 operand 의 것이 된다.
/// 단일 구현 `calls.skipWrappers(.., include_paren=true)` 에 위임.
fn skipTransparent(self: anytype, idx: NodeIndex) NodeIndex {
    return calls.skipWrappers(self, idx, true);
}

/// 노드가 (transparent wrapper 너머로) `||`(.pipe2) 또는 `&&`(.amp2) logical_expression 인지.
fn binaryChildIsLogical(self: anytype, idx: NodeIndex) bool {
    const real = skipTransparent(self, idx);
    if (real.isNone() or @intFromEnum(real) >= self.ast.nodes.items.len) return false;
    const n = self.ast.getNode(real);
    if (n.tag != .logical_expression) return false;
    const cop: Kind = @enumFromInt(n.data.binary.flags);
    return cop == .pipe2 or cop == .amp2;
}

/// `**` 좌측이 **출력 시** prefix 단항으로 시작하는지 — 그러면 `-a ** b` 가 SyntaxError 라
/// 괄호가 필수다 (esbuild BinOpPow).
///
/// 중요 — AST 태그만 봐서는 안 된다 (#4482). codegen 은 emit 시점에 노드를 갈아치운다:
///   - 상수 단락 fold: `(ON && -1) ** k` → emitBinary 가 살아남는 분기(`-1`)를 그 자리에 emit
///   - 상수 조건 fold: `(ON ? -1 : 2) ** k` → emitConditional 이 동일
///   - 상수 인라인:   `U ** 2` (U=undefined) → identifier 자리에 `void 0` 텍스트
/// 그래서 **실제로 먼저 나올 토큰**을 따라 내려간다. 여기서 true 면 `binaryChildLevels` 가
/// 좌측 level 을 올리고, 실제 괄호는 그 자리에 emit 되는 노드의 wrap 이 만든다.
fn powLeftNeedsParen(self: anytype, idx: NodeIndex) bool {
    var cur = skipTransparent(self, idx);
    var depth: u8 = 0;
    while (depth < 32) : (depth += 1) {
        if (cur.isNone() or @intFromEnum(cur) >= self.ast.nodes.items.len) return false;
        const n = self.ast.getNode(cur);
        switch (n.tag) {
            // `-x` / `!x` / `void x` / `await x` — 단항으로 시작.
            .unary_expression, .await_expression => return true,
            // 상수 폴딩이 만든 음수 리터럴(`-2`). 양수면 exprNeedsParens 가 괄호를 안 친다.
            .numeric_literal, .bigint_literal => return true,
            .boolean_literal => return self.options.minify_syntax, // `!0`/`!1` peephole
            .identifier_reference => {
                if (constInlineValue(self, cur)) |cv| {
                    return switch (cv.kind) {
                        .undefined_ => true, // `void 0`
                        .number => cv.number_text.len > 0 and cv.number_text[0] == '-',
                        else => false, // true/false/null → 키워드로 시작
                    };
                }
                return calls.isUndefinedPeephole(self, cur); // 전역 `undefined` → `void 0`
            },
            // 상수 단락 fold — emitBinary 와 **같은 판정**을 해야 한다.
            .logical_expression => {
                if (self.options.linking_metadata == null) return false;
                const left_val = self.evalBooleanCondition(n.data.binary.left) orelse return false;
                const op: Kind = @enumFromInt(n.data.binary.flags);
                // 단락 확정 → `true`/`false` 텍스트로 접힘 (키워드로 시작).
                if ((op == .amp2 and !left_val) or (op == .pipe2 and left_val)) return false;
                cur = skipTransparent(self, n.data.binary.right); // 우변이 그 자리에 온다
            },
            // 상수 조건 fold — emitConditional 과 같은 판정.
            .conditional_expression => {
                if (self.options.linking_metadata == null) return false;
                const cond = self.evalBooleanCondition(n.data.ternary.a) orelse return false;
                cur = skipTransparent(self, if (cond) n.data.ternary.b else n.data.ternary.c);
            },
            else => return false,
        }
    }
    return false;
}

/// 이항 노드 emit. 좌결합 체인(a+b+c+…)은 좌 스파인이 N-deep 라 순수 재귀면 스택 오버플로우
/// (#4123) → 좌 스파인을 명시 스택으로 평탄화해 반복 emit 한다. 출력 텍스트와 addSourceMapping
/// 순서(root → 스파인 top-down → 최좌단 leaf → operator+right bottom-up)는 재귀판과 동일.
pub fn emitBinary(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    // wrap 은 emitExpr 진입부 exprNeedsParens 가 담당(중앙 집중). level 은 단락 폴드 시
    // 살아남는 분기를 부모 level 로 투과해, 폴드로 wrap 을 위임받은 그 분기가 자기 wrap 을
    // 정확히 걸 수 있게 한다(.lowest 로 투과하면 고-precedence 슬롯에서 괄호 유실).
    try self.addSourceMapping(node.span);
    const op: Kind = @enumFromInt(node.data.binary.flags);
    // 괄호 안이 아니면 자식에 forbid_in 전파(`for ((a in b);;)` 헤더 오파싱 방지).
    // PR6 에서 wrap 시 false 로 조정(괄호 안에선 in 이 안전). PR5 는 wrap 미발동.
    const child_flags = ExprFlags{ .forbid_in = flags.forbid_in };
    if (self.options.linking_metadata != null and node.tag == .logical_expression) {
        if (self.evalBooleanCondition(node.data.binary.left)) |left_val| {
            if ((op == .amp2 and !left_val) or
                (op == .pipe2 and left_val))
            {
                try self.write(if (left_val) "true" else "false");
                return;
            }
            // 단락 폴드: logical 이 사라지고 right 가 그 자리 → 부모 level/flags 투과
            // (자식이 부모 level 로 자기 wrap → exprNeedsParens 의 wrap-위임이 정확해짐).
            try self.emitExpr(node.data.binary.right, level, flags);
            return;
        }
    }

    const left = node.data.binary.left;
    // 빠른 경로(depth 1, 대부분의 `a OP b`): 좌 자식이 스파인 노드가 아니면 기존 형태(할당 0).
    if (!emitSpineContinues(self, left)) {
        const lv = binaryChildLevels(self, node);
        try self.emitExpr(left, lv.left, child_flags);
        try emitBinaryOperator(self, node);
        try self.emitExpr(node.data.binary.right, lv.right, child_flags);
        return;
    }

    // 느린 경로: 좌 스파인 평탄화 (체인당 1회 할당). root 는 위에서 이미 addSourceMapping/fold 처리.
    var spine: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer spine.deinit(self.allocator);
    var cur = left;
    while (true) {
        try spine.append(self.allocator, cur);
        const nl = self.ast.getNode(cur).data.binary.left;
        if (emitSpineContinues(self, nl)) cur = nl else break;
    }
    // 스파인 노드(left..bottom) addSourceMapping 을 top-down 으로 (재귀판 순서 보존).
    for (spine.items) |s| try self.addSourceMapping(self.ast.getNode(s).span);
    // 최좌단 leaf = 최하단 스파인 노드의 left (그 노드의 leftLevel). esbuild binaryExprStack
    // 이 각 노드의 leftLevel/rightLevel 을 따로 들고 leaf 는 bottom 노드 leftLevel 로 emit.
    const bottom = self.ast.getNode(spine.items[spine.items.len - 1]);
    try self.emitExpr(bottom.data.binary.left, binaryChildLevels(self, bottom).left, child_flags);
    // bottom-up: 각 스파인 노드 operator+right (소스순, 각자 rightLevel), 마지막에 root.
    var i = spine.items.len;
    while (i > 0) : (i -= 1) {
        const sn = self.ast.getNode(spine.items[i - 1]);
        try emitBinaryOperator(self, sn);
        try self.emitExpr(sn.data.binary.right, binaryChildLevels(self, sn).right, child_flags);
    }
    try emitBinaryOperator(self, node);
    try self.emitExpr(node.data.binary.right, binaryChildLevels(self, node).right, child_flags);
}

/// unary_expression / update_expression 의 extra = [operand, flags]. flags 의 low byte 가
/// 연산자 Kind. extra 범위 밖이면 null.
pub fn unaryOpKind(self: anytype, extra_base: u32) ?Kind {
    const extras = self.ast.extra_data.items;
    if (extra_base + 1 >= extras.len) return null;
    return @enumFromInt(@as(u8, @truncate(extras[extra_base + 1])));
}

/// 식별자가 번들 상수 인라인 대상이면 그 상수값, 아니면 null. codegen 의 identifier
/// 경로가 리터럴 텍스트를 **직접** 쓰므로(노드 태그는 그대로 identifier_reference),
/// 출력 시작 토큰을 보는 검사들은 이 값을 봐야 실제 출력과 일치한다.
pub fn constInlineValue(self: anytype, idx: NodeIndex) ?ConstValue {
    const meta = self.options.linking_metadata orelse return null;
    const sid = self.resolveSymbolId(idx, meta) orelse return null;
    return meta.const_values.get(sid);
}

pub fn emitAssignment(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // PR6: wrap = level.gte(.assign)
    try self.addSourceMapping(node.span);
    const child_flags = ExprFlags{ .forbid_in = flags.forbid_in };
    // left 는 assignment 의 lvalue 타겟 — 미존재 ns 멤버를 `(void 0)` 으로 바꾸면
    // `(void 0) = x` SyntaxError 가 되므로 emitStaticMember 가 재작성을 건너뛰게 한다.
    // emitStaticMember 가 진입 즉시 리셋하므로 중첩 object 위치(rvalue)는 영향 없음.
    self.member_assign_target = true;
    // 우결합: left = .assign, right = .assign.lower()(= .yield, esbuild LAssign-1=LYield)
    try self.emitExpr(node.data.binary.left, .assign, child_flags);
    self.member_assign_target = false;
    try self.writeSpace();
    if (node.data.binary.flags != 0) {
        const op: Kind = @enumFromInt(node.data.binary.flags);
        try self.write(op.symbol());
    } else {
        try self.writeByte('=');
    }
    try self.writeSpace();
    const right = node.data.binary.right;
    const right_level = Level.assign.lower();
    const is_simple_assign = node.data.binary.flags == 0 or
        @as(Kind, @enumFromInt(node.data.binary.flags)) == .eq;
    if (self.fn_map_builder != null and is_simple_assign and self.isFunctionLike(right)) {
        const saved = self.pending_fn_name;
        self.pending_fn_name = try self.resolveMemberLeafName(node.data.binary.left);
        defer {
            if (self.pending_fn_name) |s| self.allocator.free(s);
            self.pending_fn_name = saved;
        }
        try self.emitExpr(right, right_level, child_flags);
    } else {
        try self.emitExpr(right, right_level, child_flags);
    }
}

pub fn emitConditional(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    // wrap 은 emitExpr 진입부가 담당. level 은 상수 폴드 시 살아남는 분기를 부모 level 로
    // 투과해 그 분기가 자기 wrap 을 정확히 걸게 한다(.lowest 투과 시 고-precedence 슬롯 유실).
    try self.addSourceMapping(node.span);
    const t = node.data.ternary;
    if (self.options.linking_metadata != null) {
        if (self.evalBooleanCondition(t.a)) |cond| {
            try self.emitExpr(if (cond) t.b else t.c, level, flags);
            return;
        }
    }
    // esbuild EIf: test=.conditional(forbid_in 보존), yes=.yield(clean), no=.yield(forbid_in 보존).
    const branch_flags = ExprFlags{ .forbid_in = flags.forbid_in };
    try self.emitExpr(t.a, .conditional, branch_flags);
    try self.writeSpace();
    try self.writeByte('?');
    try self.writeSpace();
    try self.emitExpr(t.b, .yield, .{});
    try self.writeSpace();
    try self.writeByte(':');
    try self.writeSpace();
    try self.emitExpr(t.c, .yield, branch_flags);
}

pub fn emitSequence(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.emitList(node, ",");
}

/// `parenthesized_expression` 은 대체로 투명 — 괄호를 출력하지 않고 operand 를 부모의
/// `level`/`flags` 그대로 재귀한다. 괄호가 필요하면 operand 의 precedence(exprNeedsParens)
/// 가 재유도한다 (esbuild/oxc 는 paren 노드를 AST 에 두지 않고 precedence 로만 괄호를 낸다).
/// 군더더기 괄호는 제거하고 load-bearing 만 재유도한다 — 전 모드 통일(#4042). `level`/
/// `flags` 전파로 `(a?.b as T).c` 같은 타입래퍼 통과 optional-chain 끊기 괄호도 보존된다.
///
/// 예외 — function/arrow expression 둘레의 괄호는 *보존*한다 (esbuild 가 EFunction/EArrow
/// 의 `IsParenthesized` 를 출력에 반영하는 것과 동일). IIFE(`(function(){})()`)·
/// `var x=(function(){})`·`export default (function(){})` 형태가 유지된다. object/array 는
/// esbuild 도 IsParenthesized 를 무시하므로 투명 처리한다(`({a:1})`→`{a:1}`).
pub fn emitParen(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    const inner = node.data.unary.operand;
    const real = skipTransparent(self, inner);
    if (!real.isNone() and @intFromEnum(real) < self.ast.nodes.items.len) {
        switch (self.ast.getNode(real).tag) {
            .function_expression, .function, .arrow_function_expression => {
                // 중첩 transparent wrapper 의 이중 괄호 방지 위해 skip 한 실제 노드를
                // 새 .lowest 컨텍스트로 직접 emit (괄호가 precedence 를 리셋).
                try self.writeByte('(');
                try self.emitExpr(real, .lowest, .{});
                try self.writeByte(')');
                return;
            },
            else => {},
        }
    }
    try self.emitExpr(inner, level, flags);
}

pub fn emitSpread(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level;
    _ = flags;
    try self.addSourceMapping(node.span);
    try self.write("...");
    // spread value level = .comma (esbuild ESpread value = LComma)
    try self.emitExpr(node.data.unary.operand, .comma, .{});
}

pub fn emitAwait(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // PR6: wrap = level.gte(.prefix)
    _ = flags;
    try self.addSourceMapping(node.span);
    try self.write("await ");
    // value level = .prefix.lower() (esbuild EAwait value = LPrefix-1)
    try self.emitExpr(node.data.unary.operand, Level.prefix.lower(), .{});
}

pub fn emitYield(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // PR6: wrap = level.gte(.assign)
    _ = flags;
    try self.addSourceMapping(node.span);
    try self.write("yield");
    if (node.data.unary.flags & 1 != 0) try self.writeByte('*');
    if (!node.data.unary.operand.isNone()) {
        try self.writeByte(' ');
        // value level = .yield (esbuild EYield value = LYield)
        try self.emitExpr(node.data.unary.operand, .yield, .{});
    }
}

pub fn emitArray(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.writeByte('[');
    try self.emitExpressionList(node, self.listSep());
    try self.writeByte(']');
}

pub fn emitObject(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const list = node.data.list;
    if (list.len == 0) {
        try self.write("{}");
        return;
    }
    if (self.options.minify_whitespace) {
        try self.writeByte('{');
        try self.emitList(node, ",");
        try self.writeByte('}');
    } else {
        try self.write("{ ");
        try self.emitList(node, ", ");
        try self.write(" }");
    }
}

pub fn emitObjectProperty(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const key = node.data.binary.left;
    const value = node.data.binary.right;
    if (key.isNone()) return;
    if (value.isNone()) {
        if (identifierHasRename(self, key) or identifierHasConstValue(self, key)) {
            const key_node = self.ast.getNode(key);
            try self.writeIdentifierSpan(key_node.data.string_ref);
            if (self.options.minify_whitespace) {
                try self.writeByte(':');
            } else {
                try self.write(": ");
            }
            try self.emitNode(key);
        } else {
            try self.emitNode(key);
        }
    } else {
        const key_node = self.ast.getNode(key);
        if (key_node.tag == .identifier_reference) {
            try self.writeIdentifierSpan(key_node.data.string_ref);
        } else if (key_node.tag == .string_literal and self.options.minify_syntax) {
            const raw = self.ast.getText(key_node.span);
            if (objectKeyUnquotable(raw)) {
                try self.write(ast_mod.Ast.stripStringQuotes(raw));
            } else {
                try self.emitNode(key);
            }
        } else {
            try self.emitNode(key);
        }
        if (self.options.minify_whitespace) {
            try self.writeByte(':');
        } else {
            try self.write(": ");
        }
        if (self.fn_map_builder != null and self.isFunctionLike(value)) {
            const saved = self.pending_fn_name;
            self.pending_fn_name = try self.ast.staticKeyName(self.allocator, key);
            defer {
                if (self.pending_fn_name) |s| self.allocator.free(s);
                self.pending_fn_name = saved;
            }
            // object property value 는 argument 위치 → .comma (esbuild Property.Value=LComma)
            try self.emitExpr(value, .comma, .{});
        } else {
            try self.emitExpr(value, .comma, .{});
        }
    }
}

pub fn identifierHasRename(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const key_node = self.ast.getNode(idx);
    if (self.options.linking_metadata) |meta| {
        if (self.resolveSymbolId(idx, meta)) |sym_id| {
            if (meta.renames.get(sym_id) != null) return true;
        }
    }
    if (self.ns_prefix) |_| {
        if (key_node.tag == .identifier_reference or key_node.tag == .assignment_target_identifier) {
            const name = self.ast.getText(key_node.data.string_ref);
            if (self.ns_exports) |exports| {
                if (exports.contains(name)) return true;
            }
        }
    }
    return false;
}

fn identifierHasConstValue(self: anytype, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    if (self.options.linking_metadata) |meta| {
        if (self.resolveSymbolId(idx, meta)) |sym_id| {
            if (meta.const_values.get(sym_id)) |cv| return cv.isSafeToInline();
        }
    }
    return false;
}

pub fn emitComputedKey(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.writeByte('[');
    // object computed key `[k]` 는 argument 위치 → .comma (esbuild Property.Key computed=LComma)
    try self.emitExpr(node.data.unary.operand, .comma, .{});
    try self.writeByte(']');
}

pub fn emitStaticMember(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // PR6: optional-chain 끊기 wrap
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return;
    const object = self.ast.readExtraNode(e, 0);
    const property = self.ast.readExtraNode(e, 1);
    const member_flags = self.ast.readExtra(e, 2);
    const MemberFlags = ast_mod.MemberFlags;

    // 이 member 가 assignment/update 의 lvalue 타겟인지. 진입 즉시 읽고 리셋해
    // object(중첩 member) 재귀 emit 은 rvalue 로 처리되게 한다.
    const is_assign_target = self.member_assign_target;
    self.member_assign_target = false;

    if (self.options.linking_metadata) |meta| {
        // optional chain(`ns?.prop`)도 포함한다. module namespace 객체는 절대 nullish 가
        // 아니므로 ns 위치의 선행 `?.` 는 단락(short-circuit)되지 않는 no-op — 치환 시
        // `?.` 를 안전히 제거할 수 있다(`ns?.x` ≡ `ns.x`). 체인 뒤쪽(`ns?.a?.b`)의 `?.`
        // 는 각자의 base 기준이라 영향 없음. (이 블록이 fire 하지 않으면 아래 일반 emit 이
        // `?.` 를 그대로 보존한다.)
        const obj_node_i = @intFromEnum(object);
        if (obj_node_i < meta.symbol_ids.len) {
            if (meta.symbol_ids[obj_node_i]) |obj_sym_id| {
                if (meta.ns_member_rewrites.get(obj_sym_id)) |inner_map| {
                    const prop_node = self.ast.getNode(property);
                    const prop_text = self.ast.getText(prop_node.data.string_ref);
                    if (inner_map.get(prop_text)) |canonical_name| {
                        if (canonical_name.len > 0 and canonical_name[0] == '{') {
                            try self.writeByte('(');
                            try self.write(canonical_name);
                            try self.writeByte(')');
                        } else {
                            try self.write(canonical_name);
                        }
                        return;
                    }
                    // 멤버가 rewrite map 에 없음 = 그 export 가 존재하지 않음(static ESM).
                    // ns 객체가 member-rewrite 로 materialize 되지 않았다면(ns_inline_objects
                    // 미등록) `ns.prop` 은 선언된 적 없는 ns 식별자를 참조해 ReferenceError 가
                    // 된다 — ESM 은 미존재 멤버를 undefined 로 평가하므로 `void 0` 으로 재작성한다
                    // (#3982 ambiguous 멤버와 동형, esbuild parity). materialize 된 경우(값 사용/
                    // shadow)는 ns 가 renamed 변수로 선언돼 있어 fall-through(`var.prop`→undefined)
                    // 가 안전하고, CJS namespace 는 copyProps+rename 경로라 inner_map 자체가 없어
                    // 이 분기에 도달하지 않는다(동적 멤버를 void 0 으로 잘못 가리지 않음).
                    //
                    // 두 가드:
                    //  - lvalue 타겟(`ns.x = 1`/`ns.x++`)이면 `(void 0)=1` 은 SyntaxError →
                    //    재작성 skip, 기존 fall-through 유지(런타임 throw, namespace 멤버
                    //    대입은 어차피 ESM 에러). optional chain(`ns?.x`)은 LHS 가 될 수 없어
                    //    이 가드와 무관.
                    //  - dev 번들은 모듈이 항상 wrapper 로 선언돼 `ns` 가 존재하므로 dangling
                    //    이 발생하지 않는다. 재작성 불필요 + CJS 동적 멤버 오인 방지 위해 skip.
                    if (!is_assign_target and
                        self.options.dev_module_id == null and
                        meta.ns_inline_objects.get(obj_sym_id) == null)
                    {
                        // `(void 0)` — paren 필수. 이 멤버 식은 call/member 의 피연산자가
                        // 될 수 있어(`ns.x()`, `ns.x.y`) bare `void 0` 은 `void 0()`(=
                        // `void(0())`) / `void 0.y`(SyntaxError) 로 잘못 파싱된다. paren 으로
                        // 감싸면 모든 컨텍스트에서 undefined 의미가 보존된다.
                        try self.write("(void 0)");
                        return;
                    }
                }
            }
        }
    }

    if (self.options.dev_module_id != null or self.options.module_format == .cjs or self.options.replace_import_meta) {
        if (self.resolveImportMetaProp(object, property)) |prop_text| {
            if (self.options.dev_module_id) |dev_id| {
                if (std.mem.eql(u8, prop_text, "hot")) {
                    try self.write("__zntc_make_hot(\"");
                    try self.write(dev_id);
                    try self.write("\")");
                    return;
                }
            }
            if (self.options.module_format == .cjs or self.options.replace_import_meta) {
                if (std.mem.eql(u8, prop_text, "url")) {
                    try self.writeImportMetaUrl();
                    return;
                }
                if (self.options.platform == .node) {
                    if (std.mem.eql(u8, prop_text, "dirname")) {
                        try self.write("__dirname");
                        return;
                    } else if (std.mem.eql(u8, prop_text, "filename")) {
                        try self.write("__filename");
                        return;
                    }
                } else {
                    if (std.mem.eql(u8, prop_text, "dirname") or std.mem.eql(u8, prop_text, "filename")) {
                        try self.write("\"\"");
                        return;
                    }
                }
            }
        }
    }

    // object level = .postfix. self 가 None(체인 밖: optional 아니고 object 도 체인 아님)이면
    // object 에 has_non_optional_chain_parent set → object 가 optional chain start/continue 면
    // `(a?.b).c` 처럼 끊는다. Start/Continue 면 clear. forbid_call 보존(esbuild EDot target flags).
    const self_in_chain = (member_flags & MemberFlags.optional_chain) != 0 or
        calls.objectContinuesOptionalChain(self, object);
    const obj_flags = ExprFlags{
        .forbid_call = flags.forbid_call,
        .has_non_optional_chain_parent = !self_in_chain,
    };
    try self.emitExpr(object, Level.postfix, obj_flags);
    if (member_flags & MemberFlags.optional_chain != 0) {
        try self.write("?.");
    } else {
        // object 가 정수 리터럴로 끝나면 `42.x` 가 `42.`(소수점)으로 오파싱됨 → 공백
        // (`42 .toString()`). esbuild needSpaceBeforeDot. `?.` 는 소수점 모호성 없어 제외.
        if (self.need_space_before_dot == self.buf.items.len) try self.writeByte(' ');
        try self.writeByte('.');
    }
    // property name 슬롯은 reserved word 도 valid identifier 로 취급되므로 peephole
    // 치환 (예: `undefined` → `void 0`) 이 적용되면 안 된다 — `obj.undefined` 가
    // `obj.void 0` 로 깨지면 SyntaxError. emitNode 우회 시 sourcemap mapping 이
    // 같이 빠지므로 명시 발행 후 raw span 출력.
    const prop_node = self.ast.getNode(property);
    try self.addSourceMapping(prop_node.span);
    try self.writeIdentifierSpan(prop_node.span);
}

pub fn emitComputedMember(self: anytype, node: Node, level: Level, flags: ExprFlags) !void {
    _ = level; // PR6: optional-chain 끊기 wrap
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return;
    const object = self.ast.readExtraNode(e, 0);
    const property = self.ast.readExtraNode(e, 1);
    const member_flags = self.ast.readExtra(e, 2);
    const MemberFlags = ast_mod.MemberFlags;
    const self_in_chain = (member_flags & MemberFlags.optional_chain) != 0 or
        calls.objectContinuesOptionalChain(self, object);
    const obj_flags = ExprFlags{
        .forbid_call = flags.forbid_call,
        .has_non_optional_chain_parent = !self_in_chain,
    };
    try self.emitExpr(object, Level.postfix, obj_flags);
    if (member_flags & MemberFlags.optional_chain != 0) {
        try self.write("?.");
    }
    try self.writeByte('[');
    // computed index 는 괄호 `[]` 안 → .lowest (esbuild EIndex.Index = LLowest)
    try self.emitExpr(property, .lowest, .{});
    try self.writeByte(']');
}

test "objectKeyUnquotable: valid IdentifierName 만 unquote (semantic-preserving)" {
    const t = std.testing;
    // valid: 따옴표 벗겨도 동일 — reserved word 도 객체 키로는 valid
    try t.expect(objectKeyUnquotable("\"source\""));
    try t.expect(objectKeyUnquotable("\"extensions\""));
    try t.expect(objectKeyUnquotable("'compressible'"));
    try t.expect(objectKeyUnquotable("\"_x\""));
    try t.expect(objectKeyUnquotable("\"$a\""));
    try t.expect(objectKeyUnquotable("\"a1\""));
    try t.expect(objectKeyUnquotable("\"if\"")); // reserved word: {if:1} 은 valid JS
    // invalid: quote 유지해야 정확성 보존
    try t.expect(!objectKeyUnquotable("\"\"")); // 빈 키
    try t.expect(!objectKeyUnquotable("\"1a\"")); // 숫자 시작
    try t.expect(!objectKeyUnquotable("\"a-b\"")); // 하이픈
    try t.expect(!objectKeyUnquotable("\"application/json\"")); // 슬래시
    try t.expect(!objectKeyUnquotable("\"a b\"")); // 공백
    try t.expect(!objectKeyUnquotable("\"a\\nb\"")); // escape — 디코드 회피(보수적)
    try t.expect(!objectKeyUnquotable("\"__proto__\"")); // proto setter semantic 보존
    try t.expect(!objectKeyUnquotable("source")); // 따옴표 없는 raw 는 대상 아님
    try t.expect(!objectKeyUnquotable("\"")); // 길이 부족
    try t.expect(!objectKeyUnquotable("\"a'")); // quote 불일치
}
