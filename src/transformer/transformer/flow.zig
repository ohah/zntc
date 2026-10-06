//! Flow syntax lowering helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const es_helpers = @import("../es_helpers.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

const FlowMatchContext = struct {
    temp_span: Span,
    symbol_id: ?SymbolId,
    function_scope: ScopeId,
    arm_scope: ScopeId,
};

fn sourceBindingScope(self: *Transformer, binding: NodeIndex) ScopeId {
    const raw_id = self.getSymbolIdAt(binding) orelse std.debug.panic("Flow match binding has no SymbolId", .{});
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    if (raw_id >= symbols.len) std.debug.panic("Flow match binding SymbolId is out of range", .{});
    return symbols[raw_id].scope_id;
}

/// A Flow match subject is represented as a path until an emitted use is
/// built. This avoids creating identifier-reference nodes for intermediate
/// pattern paths that never reach the output tree.
const MatchSubject = struct { path: std.ArrayListUnmanaged(NodeIndex) = .empty };

/// Build one emitted subject expression and register the generated temp read
/// at the expression's actual output scope.
fn makeMatchSubjectExpr(self: *Transformer, subject: *const MatchSubject, context: FlowMatchContext, scope: ScopeId, span: Span) Error!NodeIndex {
    var expression = try es_helpers.makeTempVarRef(self, context.temp_span, context.temp_span);
    try self.addSyntheticRefInScope(expression, context.symbol_id, scope, .{ .read = true });
    for (subject.path.items) |key| {
        expression = try es_helpers.makeComputedMember(self, expression, try es_helpers.cloneNode(self, key), span);
    }
    return expression;
}

/// 한 pattern 의 lowering 결과.
///   test_expr : subject 와 비교한 boolean 식 (true literal = 무조건 매치)
///   bindings  : test 통과 후 선언할 `let <id> = subject;` 문 (binding/as).
///               arena 소유 — then_stmts 와 달리 의도적으로 free 하지 않음.
///   guard     : binding 선언 이후 평가할 추가 조건식 (.none = 없음)
const LoweredPattern = struct {
    test_expr: NodeIndex,
    bindings: []const NodeIndex,
    guard: NodeIndex,
};

fn mkBool(self: *Transformer, val: bool) Error!NodeIndex {
    return es_helpers.makeBoolLiteral(self, val);
}

fn mkBin(self: *Transformer, span: Span, left: NodeIndex, right: NodeIndex, kind: token_mod.Kind) Error!NodeIndex {
    return self.ast.addBinaryNode(.binary_expression, span, left, right, @intFromEnum(kind));
}

fn mkBlock(self: *Transformer, span: Span, stmts: []const NodeIndex) Error!NodeIndex {
    const list = try self.ast.addNodeList(stmts);
    return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = list } });
}

/// `let <id_span> = <subject>;` variable declaration 생성.
/// subject 는 1회용 AST 노드라 cloneNode 로 복제해 쓴다. `origin` 은 이름이 나온 패턴 노드.
fn mkBindingDecl(self: *Transformer, id_span: Span, origin: NodeIndex, subject: *MatchSubject, span: Span, context: FlowMatchContext) Error!NodeIndex {
    const subj = try makeMatchSubjectExpr(self, subject, context, context.arm_scope, span);
    const bind = try self.makeUserBinding(id_span, origin);
    const decl = try es_helpers.makeDeclarator(self, bind, subj, span);
    return es_helpers.makeVarDeclaration(self, &.{decl}, .let, span);
}

fn mkNum(self: *Transformer, val: usize) Error!NodeIndex {
    return es_helpers.makeNumericLiteral(self, @intCast(val));
}

/// match object key 노드 → JS literal (computed-member 인덱스 & `in` 좌변).
/// 매 호출 새 노드 (1회용).
fn mkKeyLit(self: *Transformer, key: NodeIndex) Error!NodeIndex {
    const kn = self.ast.getNode(key);
    return switch (kn.tag) {
        // 이미 따옴표 포함 span — 그대로 string literal.
        .string_literal => self.ast.addNode(.{ .tag = .string_literal, .span = kn.span, .data = .{ .string_ref = kn.span } }),
        // 식별자 키 → `"k"` 문자열 리터럴.
        .identifier_reference => es_helpers.buildQuotedKeyLiteral(self, kn.span),
        // numeric/bigint 키.
        else => self.ast.addNode(.{ .tag = .numeric_literal, .span = kn.span, .data = .{ .string_ref = kn.span } }),
    };
}

/// 항상-true test(`&& true`) 생략용 판별. `data.none == 1` 은
/// es_helpers.makeBoolLiteral 의 true 인코딩 계약 (변경 시 동반 수정 필요).
fn isAlwaysTrue(self: *Transformer, n: NodeIndex) bool {
    const nd = self.ast.getNode(n);
    return nd.tag == .boolean_literal and nd.data.none == 1;
}

fn mkStrLit(self: *Transformer, text: []const u8) Error!NodeIndex {
    const quoted = try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{text});
    const sp = try self.ast.addString(quoted);
    return self.ast.addNode(.{ .tag = .string_literal, .span = sp, .data = .{ .string_ref = sp } });
}

/// `typeof <subject> === "object"` — `in`/속성 접근 전 object 가드.
fn mkTypeofObject(self: *Transformer, subject: *MatchSubject, span: Span, context: FlowMatchContext) Error!NodeIndex {
    const tof_extra = try self.ast.addExtras(&.{
        @intFromEnum(try makeMatchSubjectExpr(self, subject, context, context.function_scope, span)),
        @intFromEnum(token_mod.Kind.kw_typeof),
    });
    const tof = try self.ast.addNode(.{ .tag = .unary_expression, .span = span, .data = .{ .extra = tof_extra } });
    return mkBin(self, span, tof, try mkStrLit(self, "object"), .eq3);
}

/// object match pattern: `S != null && ("k" in S) && <sub(S.k)> && ...` (+rest).
fn lowerObjectPattern(self: *Transformer, pnode: Node, subject: *MatchSubject, span: Span, context: FlowMatchContext) Error!LoweredPattern {
    const lst = pnode.data.list;
    // S != null && typeof S === "object" — primitive/null 이면 `in` throw 방지.
    var test_acc = try mkBin(
        self,
        span,
        try es_helpers.makeNeqNull(self, try makeMatchSubjectExpr(self, subject, context, context.function_scope, span), span),
        try mkTypeofObject(self, subject, span, context),
        .amp2,
    );
    var binds: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var guard_acc: NodeIndex = .none;

    // rest binding 을 위해 명시 키 노드 수집.
    var key_lits: std.ArrayListUnmanaged(NodeIndex) = .empty;

    var i: u32 = 0;
    while (i < lst.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[lst.start + i]);
        const cn = self.ast.getNode(child);
        if (cn.tag == .flow_match_rest) {
            if (cn.data.none == 1) {
                // let <rest> = Object.assign({}, S); delete <rest>.k1; ...
                const empty_obj = try self.ast.addNode(.{ .tag = .object_expression, .span = span, .data = .{ .list = .{ .start = 0, .len = 0 } } });
                const copy_call = try es_helpers.makeObjectAssignCall(self, &.{ empty_obj, try makeMatchSubjectExpr(self, subject, context, context.arm_scope, span) }, span);
                const bind = try self.makeUserBinding(cn.span, child);
                const decl = try es_helpers.makeDeclarator(self, bind, copy_call, span);
                try binds.append(self.allocator, try es_helpers.makeVarDeclaration(self, &.{decl}, .let, span));
                for (key_lits.items) |kl| {
                    const rest_ref = try self.makeIdentifierRefWithSymbol(cn.span, child);
                    if (self.semantic_edit_enabled)
                        try self.trackUserReadFromBinding(rest_ref, child, sourceBindingScope(self, child));
                    const del_member = try es_helpers.makeComputedMember(self, rest_ref, kl, span);
                    const del_extra = try self.ast.addExtras(&.{ @intFromEnum(del_member), @intFromEnum(token_mod.Kind.kw_delete) });
                    const del = try self.ast.addNode(.{ .tag = .unary_expression, .span = span, .data = .{ .extra = del_extra } });
                    try binds.append(self.allocator, try es_helpers.makeExprStmt(self, del, span));
                }
            }
            continue; // inexact marker (none==0): 추가 체크 없음
        }
        // flow_match_object_prop: binary { key, value }
        const key = cn.data.binary.left;
        const value = cn.data.binary.right;
        try subject.path.append(self.allocator, try mkKeyLit(self, key));
        const sub = try lowerMatchPattern(self, value, subject, span, context);
        _ = subject.path.pop();
        const in_expr = try mkBin(self, span, try mkKeyLit(self, key), try makeMatchSubjectExpr(self, subject, context, context.function_scope, span), .kw_in);
        try key_lits.append(self.allocator, try mkKeyLit(self, key));
        test_acc = try andJoin(self, span, test_acc, in_expr);
        if (!isAlwaysTrue(self, sub.test_expr)) test_acc = try andJoin(self, span, test_acc, sub.test_expr);
        for (sub.bindings) |b| try binds.append(self.allocator, b);
        if (!sub.guard.isNone()) guard_acc = try andJoin(self, span, guard_acc, sub.guard);
    }
    return .{ .test_expr = test_acc, .bindings = binds.items, .guard = guard_acc };
}

/// array match pattern: `Array.isArray(S) && S.length (===|>=) N && <sub(S[i])>` (+rest slice).
fn lowerArrayPattern(self: *Transformer, pnode: Node, subject: *MatchSubject, span: Span, context: FlowMatchContext) Error!LoweredPattern {
    const lst = pnode.data.list;
    var elem_count: usize = 0;
    var rest_node: NodeIndex = .none;
    var i: u32 = 0;
    while (i < lst.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[lst.start + i]);
        if (self.ast.getNode(child).tag == .flow_match_rest) {
            rest_node = child;
        } else elem_count += 1;
    }

    const is_arr = try es_helpers.makeCallExpr(
        self,
        try es_helpers.makeStaticMember(self, try es_helpers.makeGlobalRef(self, "Array"), try es_helpers.makePropertyName(self, "isArray"), span),
        &.{try makeMatchSubjectExpr(self, subject, context, context.function_scope, span)},
        span,
    );
    const len_member = try es_helpers.makeStaticMember(self, try makeMatchSubjectExpr(self, subject, context, context.function_scope, span), try es_helpers.makePropertyName(self, "length"), span);
    const len_cmp_kind: token_mod.Kind = if (rest_node.isNone()) .eq3 else .gt_eq;
    const len_test = try mkBin(self, span, len_member, try mkNum(self, elem_count), len_cmp_kind);
    var test_acc = try mkBin(self, span, is_arr, len_test, .amp2);

    var binds: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var guard_acc: NodeIndex = .none;
    var idx: usize = 0;
    i = 0;
    while (i < lst.len) : (i += 1) {
        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[lst.start + i]);
        if (self.ast.getNode(child).tag == .flow_match_rest) continue;
        try subject.path.append(self.allocator, try mkNum(self, idx));
        const sub = try lowerMatchPattern(self, child, subject, span, context);
        _ = subject.path.pop();
        if (!isAlwaysTrue(self, sub.test_expr)) test_acc = try andJoin(self, span, test_acc, sub.test_expr);
        for (sub.bindings) |b| try binds.append(self.allocator, b);
        if (!sub.guard.isNone()) guard_acc = try andJoin(self, span, guard_acc, sub.guard);
        idx += 1;
    }
    if (!rest_node.isNone() and self.ast.getNode(rest_node).data.none == 1) {
        // let <rest> = S.slice(elem_count)
        const slice_call = try es_helpers.makeCallExpr(
            self,
            try es_helpers.makeStaticMember(self, try makeMatchSubjectExpr(self, subject, context, context.arm_scope, span), try es_helpers.makePropertyName(self, "slice"), span),
            &.{try mkNum(self, elem_count)},
            span,
        );
        const bind = try self.makeUserBinding(self.ast.getNode(rest_node).span, rest_node);
        const decl = try es_helpers.makeDeclarator(self, bind, slice_call, span);
        try binds.append(self.allocator, try es_helpers.makeVarDeclaration(self, &.{decl}, .let, span));
    }
    return .{ .test_expr = test_acc, .bindings = binds.items, .guard = guard_acc };
}

fn andJoin(self: *Transformer, span: Span, a: NodeIndex, b: NodeIndex) Error!NodeIndex {
    if (a.isNone()) return b;
    return mkBin(self, span, a, b, .amp2);
}

/// match pattern → (test, bindings, guard). `subject` 는 비교 대상 expression
/// (`_m`, `_m["k"]`, `_m[0]` …). AST 노드는 1회용이라 사용 시마다 cloneNode.
/// cloneNode 는 **shallow** copy — 자식 인덱스를 공유한다. 따라서 subject 의
/// 자식은 모두 leaf(temp ident / key literal)여야 안전하며, 실제로 그렇다
/// (member chain 의 base 는 항상 `_m` temp, key 는 literal). 더 깊은 subject
/// 가 필요해지면 deep clone 또는 thunk 로 바꿔야 한다.
/// Flow match semantics:
///   wildcard `_`            → 항상 매치
///   binding `const x`       → 항상 매치 + `let x = S`
///   literal/member/unary    → `S === <expr>`
///   OR `a | b`              → `test(a) || test(b)` (OR 내부 binding/guard 무시)
///   as `p as x`             → test(p) + `let x = S`
///   guard `p if (c)`        → test(p), binding 후 `c` 평가
///   object `{k: p, ...r}`   → `S != null && ("k" in S) && test(p, S.k)` + rest
///   array `[p, ...r]`       → `Array.isArray(S) && length && test(p, S[i])` + rest
///   instance `C { ... }`    → `S instanceof C && <object body>`
fn lowerMatchPattern(self: *Transformer, pattern: NodeIndex, subject: *MatchSubject, span: Span, context: FlowMatchContext) Error!LoweredPattern {
    const pnode = self.ast.getNode(pattern);
    switch (pnode.tag) {
        .flow_match_opaque_pattern => return .{
            .test_expr = try mkBool(self, false),
            .bindings = &.{},
            .guard = .none,
        },
        .flow_match_binding_pattern => {
            const binds = try self.allocator.alloc(NodeIndex, 1);
            binds[0] = try mkBindingDecl(self, pnode.span, pattern, subject, span, context);
            return .{ .test_expr = try mkBool(self, true), .bindings = binds, .guard = .none };
        },
        .flow_match_or_pattern => {
            const lst = pnode.data.list;
            var acc: NodeIndex = .none;
            var i: u32 = 0;
            while (i < lst.len) : (i += 1) {
                const sub: NodeIndex = @enumFromInt(self.ast.extra_data.items[lst.start + i]);
                const lp = try lowerMatchPattern(self, sub, subject, span, context);
                acc = if (acc.isNone()) lp.test_expr else try mkBin(self, span, acc, lp.test_expr, .pipe2);
            }
            if (acc.isNone()) acc = try mkBool(self, false);
            return .{ .test_expr = acc, .bindings = &.{}, .guard = .none };
        },
        .flow_match_as_pattern => {
            const lp = try lowerMatchPattern(self, pnode.data.binary.left, subject, span, context);
            const id_idx = pnode.data.binary.right;
            const extra_decl = try mkBindingDecl(self, self.ast.getNode(id_idx).span, id_idx, subject, span, context);
            const binds = try self.allocator.alloc(NodeIndex, lp.bindings.len + 1);
            std.mem.copyForwards(NodeIndex, binds[0..lp.bindings.len], lp.bindings);
            binds[lp.bindings.len] = extra_decl;
            return .{ .test_expr = lp.test_expr, .bindings = binds, .guard = lp.guard };
        },
        .flow_match_guard_pattern => {
            const lp = try lowerMatchPattern(self, pnode.data.binary.left, subject, span, context);
            const g = try self.visitNode(pnode.data.binary.right);
            const combined = if (lp.guard.isNone()) g else try mkBin(self, span, lp.guard, g, .amp2);
            return .{ .test_expr = lp.test_expr, .bindings = lp.bindings, .guard = combined };
        },
        .flow_match_object_pattern => return lowerObjectPattern(self, pnode, subject, span, context),
        .flow_match_array_pattern => return lowerArrayPattern(self, pnode, subject, span, context),
        .flow_match_instance_pattern => {
            // S instanceof Ctor && <object body test>
            const ctor = try self.visitNode(pnode.data.binary.left);
            const inst = try mkBin(self, span, try makeMatchSubjectExpr(self, subject, context, context.function_scope, span), ctor, .kw_instanceof);
            const body = self.ast.getNode(pnode.data.binary.right);
            const lp = try lowerObjectPattern(self, body, subject, span, context);
            return .{ .test_expr = try andJoin(self, span, inst, lp.test_expr), .bindings = lp.bindings, .guard = lp.guard };
        },
        // wildcard `_` 는 무조건 매치.
        .identifier_reference => if (std.mem.eql(u8, self.ast.getText(pnode.span), "_")) {
            return .{ .test_expr = try mkBool(self, true), .bindings = &.{}, .guard = .none };
        },
        else => {},
    }
    // identifier(non-`_`) / literal / member / unary → `S === <expr>`
    const v = try self.visitNode(pattern);
    return .{
        .test_expr = try mkBin(self, span, try makeMatchSubjectExpr(self, subject, context, context.function_scope, span), v, .eq3),
        .bindings = &.{},
        .guard = .none,
    };
}

/// Flow match expression → (function(_m){if(_m===P){B}else if...})(expr)
pub fn visitFlowMatch(self: *Transformer, node: Node) Error!NodeIndex {
    const span = node.span;
    const e = node.data.extra;
    const discriminant_idx = self.readNodeIdx(e, 0);
    const arms_start = self.readU32(e, 1);
    const arms_len = self.readU32(e, 2);

    // arm 인덱스를 미리 로컬에 복사 (visitNode가 extra_data를 재할당할 수 있으므로)
    const arm_indices = try self.allocator.alloc(u32, arms_len);
    defer self.allocator.free(arm_indices);
    for (0..arms_len) |i| {
        arm_indices[i] = self.ast.extra_data.items[arms_start + i];
    }

    const new_discriminant = try self.visitNode(discriminant_idx);

    // 임시 변수 _m
    const match_var = try es_helpers.makeTempVarSpan(self);
    const match_param = try es_helpers.makeSyntheticBinding(self, match_var);
    // The generated function parameter already declares this temp. Keep it
    // out of the enclosing function's generic temp-hoist pass.
    es_helpers.consumeTempVarSpan(self, match_var);

    // The function owner and parameter must exist before any emitted temp
    // reference is created, so lowering can attach the exact SymbolId and
    // output ScopeId immediately.
    const fn_body = try mkBlock(self, span, &.{});
    const fn_params_list = try self.ast.addNodeList(&.{match_param});
    const fn_params_node = try self.ast.addFormalParameters(fn_params_list, span);
    const fn_extra = try self.ast.addExtras(&.{
        @intFromEnum(NodeIndex.none), // name (anonymous)
        @intFromEnum(fn_params_node),
        @intFromEnum(fn_body),
        0, // flags
        @intFromEnum(NodeIndex.none), // return type
    });
    const fn_expr = try self.ast.addNode(.{
        .tag = .function_expression,
        .span = span,
        .data = .{ .extra = fn_extra },
    });
    const fn_scope = try self.addGeneratedFunctionScope(self.current_scope, fn_expr);
    const match_symbol = try self.declareSyntheticInScope(match_param, span, .parameter, fn_scope);

    // 각 arm → `if (<test>) { <bindings>; [if (<guard>)] return <body>; }`
    // 을 순서대로 나열. 매치되면 return 으로 함수 탈출, 아니면 다음 if 로 진행.
    // self.scratch 는 lowerMatchPattern 내부 visitNode(guard) 가 재사용하므로
    // 충돌 방지를 위해 local alloc 으로 if 문 리스트를 모은다.
    const if_stmts = try self.allocator.alloc(NodeIndex, arm_indices.len);
    defer self.allocator.free(if_stmts);

    for (arm_indices, 0..) |ai, k| {
        const arm = self.ast.getNode(@enumFromInt(ai));
        const pattern = arm.data.binary.left;
        const new_body_raw = try self.visitNode(arm.data.binary.right);
        const body_node = self.ast.getNode(new_body_raw);

        // body 가 block `{ s1; s2; }` 이면 statement 들을 펼치고 `return;` 으로
        // 함수 탈출 (값 없는 statement-arm). expression 이면 `return <expr>;`.
        // `return <block>` 으로 wrap 하면 codegen 이 object literal 로 출력해 깨짐.
        var body_stmts: std.ArrayListUnmanaged(NodeIndex) = .empty;
        if (body_node.tag == .block_statement) {
            const blist = body_node.data.list;
            var bi: u32 = 0;
            while (bi < blist.len) : (bi += 1) {
                try body_stmts.append(self.allocator, @enumFromInt(self.ast.extra_data.items[blist.start + bi]));
            }
            try body_stmts.append(self.allocator, try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = NodeIndex.none, .flags = 0 } },
            }));
        } else {
            try body_stmts.append(self.allocator, try self.ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = new_body_raw, .flags = 0 } },
            }));
        }

        const then_block = try mkBlock(self, span, &.{});
        const arm_scope = try self.addGeneratedScope(fn_scope, then_block, .block);
        const context: FlowMatchContext = .{
            .temp_span = match_var,
            .symbol_id = match_symbol,
            .function_scope = fn_scope,
            .arm_scope = arm_scope,
        };
        var subject = MatchSubject{};
        defer subject.path.deinit(self.allocator);
        const lp = try lowerMatchPattern(self, pattern, &subject, span, context);

        // then-block: bindings... + (guard ? if (guard) { body } : body)
        var then_list: std.ArrayListUnmanaged(NodeIndex) = .empty;
        for (lp.bindings) |b| try then_list.append(self.allocator, b);
        if (lp.guard.isNone()) {
            for (body_stmts.items) |s| try then_list.append(self.allocator, s);
        } else {
            try then_list.append(self.allocator, try self.ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{
                    .a = lp.guard,
                    .b = try mkBlock(self, span, body_stmts.items),
                    .c = NodeIndex.none,
                } },
            }));
        }
        self.ast.nodes.items[@intFromEnum(then_block)].data.list = try self.ast.addNodeList(then_list.items);

        if_stmts[k] = try self.ast.addNode(.{
            .tag = .if_statement,
            .span = span,
            .data = .{ .ternary = .{ .a = lp.test_expr, .b = then_block, .c = NodeIndex.none } },
        });
    }

    // function(_m) { if-list }
    self.ast.nodes.items[@intFromEnum(fn_body)].data.list = try self.ast.addNodeList(if_stmts);

    // (function(_m){...})(discriminant)
    // function expression을 IIFE 형태로 호출 — emitCall이 callee를 자동으로 괄호 처리
    // call_expression extra: [callee, args_start, args_len, flags]
    const args_list = try self.ast.addNodeList(&.{new_discriminant});
    const call_extra = try self.ast.addExtras(&.{
        @intFromEnum(fn_expr),
        args_list.start,
        args_list.len,
        0, // flags
    });
    return self.ast.addNode(.{
        .tag = .call_expression,
        .span = span,
        .data = .{ .extra = call_extra },
    });
}

/// Flow component with ref → 2개 statement로 변환:
///   function Name_withRef({...props}, ref) { ... }    ← pending_nodes
///   const Name = React.forwardRef(Name_withRef);       ← 반환값
///
/// extra = [name, params_start, params_len, body]
/// Flow component with ref: 파서가 생성한 2개 statement를 방문.
/// extra = [func_decl, const_decl]
/// func_decl은 pending_nodes에, const_decl은 반환.
fn flowComponentForwardRefArgument(self: *Transformer, const_decl: NodeIndex) NodeIndex {
    if (const_decl.isNone() or @intFromEnum(const_decl) >= self.ast.nodes.items.len) return .none;
    const declaration = self.ast.getNode(const_decl);
    if (declaration.tag != .variable_declaration) return .none;
    const variable_extra = declaration.data.extra;
    const extras = self.ast.extra_data.items;
    if (variable_extra + 2 >= extras.len or extras[variable_extra + 2] != 1) return .none;
    const declarators_start = extras[variable_extra + 1];
    if (declarators_start >= extras.len) return .none;
    const declarator_idx: NodeIndex = @enumFromInt(extras[declarators_start]);
    if (declarator_idx.isNone() or @intFromEnum(declarator_idx) >= self.ast.nodes.items.len) return .none;
    const declarator = self.ast.getNode(declarator_idx);
    if (declarator.tag != .variable_declarator) return .none;
    const declarator_extra = declarator.data.extra;
    if (declarator_extra + 2 >= extras.len) return .none;
    const call_idx: NodeIndex = @enumFromInt(extras[declarator_extra + 2]);
    if (call_idx.isNone() or @intFromEnum(call_idx) >= self.ast.nodes.items.len) return .none;
    const call = self.ast.getNode(call_idx);
    if (call.tag != .call_expression) return .none;
    const call_extra = call.data.extra;
    if (call_extra + 2 >= extras.len or extras[call_extra + 2] != 1) return .none;
    const args_start = extras[call_extra + 1];
    if (args_start >= extras.len) return .none;
    const argument: NodeIndex = @enumFromInt(extras[args_start]);
    if (argument.isNone() or @intFromEnum(argument) >= self.ast.nodes.items.len or
        self.ast.getNode(argument).tag != .identifier_reference) return .none;
    return argument;
}

fn updateFlowComponentName(self: *Transformer, identifier: NodeIndex, name_span: Span) void {
    if (identifier.isNone() or @intFromEnum(identifier) >= self.ast.nodes.items.len) return;
    const raw = @intFromEnum(identifier);
    const node = &self.ast.nodes.items[raw];
    if (node.tag != .binding_identifier and node.tag != .identifier_reference) return;
    node.span = name_span;
    node.data = .{ .string_ref = name_span };
}

pub fn visitFlowComponentWrapper(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const func_decl_idx = self.readNodeIdx(e, 0);
    const const_decl_idx = self.readNodeIdx(e, 1);

    // The parser-created helper name is not present in source text. Resolve it
    // against source identifiers before adding it to the semantic scope; the
    // ordinary Flow component binding remains unchanged.
    const func_decl = self.ast.getNode(func_decl_idx);
    const name_idx = self.readNodeIdx(func_decl.data.extra, ast_mod.FunctionExtra.name);
    const forward_ref_argument = flowComponentForwardRefArgument(self, const_decl_idx);
    if (!name_idx.isNone() and !forward_ref_argument.isNone()) {
        const old_name_span = self.ast.getNode(name_idx).data.string_ref;
        const old_name = self.ast.getText(old_name_span);
        const resolved_name = try es_helpers.resolveGeneratedName(self, old_name);
        if (!std.mem.eql(u8, old_name, resolved_name)) {
            // The analyzer saw the parser-created argument before this generated
            // binding existed, so it may have resolved the name to a user binding.
            try self.removeSemanticReference(forward_ref_argument);
            const new_name_span = try self.ast.addString(resolved_name);
            updateFlowComponentName(self, name_idx, new_name_span);
            updateFlowComponentName(self, forward_ref_argument, new_name_span);
        }
    }

    // function Name_withRef 방문 (ES2015 lowering 등 적용)
    const new_func = try self.visitNode(func_decl_idx);
    try self.pending_nodes.append(self.allocator, new_func);

    // const Name = React.forwardRef(Name_withRef) 방문
    const new_const = try self.visitNode(const_decl_idx);
    if (self.semantic_edit_enabled and !new_func.isNone() and !new_const.isNone()) {
        const output_func = self.ast.getNode(new_func);
        if (output_func.tag == .function_declaration) {
            const output_name = self.readNodeIdx(output_func.data.extra, ast_mod.FunctionExtra.name);
            const output_ref = flowComponentForwardRefArgument(self, new_const);
            if (!output_name.isNone() and !output_ref.isNone()) {
                const symbol = try self.declareSyntheticInScope(output_name, node.span, .function_decl, self.current_scope);
                try self.addSyntheticRefInScope(output_ref, symbol, self.current_scope, .{ .read = true });
            }
        }
    }
    return new_const;
}
