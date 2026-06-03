//! Flow syntax lowering helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("../es_helpers.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

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
/// subject 는 1회용 AST 노드라 cloneNode 로 복제해 쓴다.
fn mkBindingDecl(self: *Transformer, id_span: Span, subject: NodeIndex, span: Span) Error!NodeIndex {
    const subj = try es_helpers.cloneNode(self, subject);
    const bind = try es_helpers.makeBindingIdentifier(self, id_span);
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
fn mkTypeofObject(self: *Transformer, subject: NodeIndex, span: Span) Error!NodeIndex {
    const tof_extra = try self.ast.addExtras(&.{
        @intFromEnum(try es_helpers.cloneNode(self, subject)),
        @intFromEnum(token_mod.Kind.kw_typeof),
    });
    const tof = try self.ast.addNode(.{ .tag = .unary_expression, .span = span, .data = .{ .extra = tof_extra } });
    return mkBin(self, span, tof, try mkStrLit(self, "object"), .eq3);
}

/// object match pattern: `S != null && ("k" in S) && <sub(S.k)> && ...` (+rest).
fn lowerObjectPattern(self: *Transformer, pnode: Node, subject: NodeIndex, span: Span) Error!LoweredPattern {
    const lst = pnode.data.list;
    // S != null && typeof S === "object" — primitive/null 이면 `in` throw 방지.
    var test_acc = try mkBin(
        self,
        span,
        try es_helpers.makeNeqNull(self, try es_helpers.cloneNode(self, subject), span),
        try mkTypeofObject(self, subject, span),
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
                const copy_call = try es_helpers.makeObjectAssignCall(self, &.{ empty_obj, try es_helpers.cloneNode(self, subject) }, span);
                const bind = try es_helpers.makeBindingIdentifier(self, cn.span);
                const decl = try es_helpers.makeDeclarator(self, bind, copy_call, span);
                try binds.append(self.allocator, try es_helpers.makeVarDeclaration(self, &.{decl}, .let, span));
                for (key_lits.items) |kl| {
                    const rest_ref = try es_helpers.makeIdentifierRefFromSpan(self, cn.span);
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
        const member = try es_helpers.makeComputedMember(self, try es_helpers.cloneNode(self, subject), try mkKeyLit(self, key), span);
        const sub = try lowerMatchPattern(self, value, member, span);
        const in_expr = try mkBin(self, span, try mkKeyLit(self, key), try es_helpers.cloneNode(self, subject), .kw_in);
        try key_lits.append(self.allocator, try mkKeyLit(self, key));
        test_acc = try andJoin(self, span, test_acc, in_expr);
        if (!isAlwaysTrue(self, sub.test_expr)) test_acc = try andJoin(self, span, test_acc, sub.test_expr);
        for (sub.bindings) |b| try binds.append(self.allocator, b);
        if (!sub.guard.isNone()) guard_acc = try andJoin(self, span, guard_acc, sub.guard);
    }
    return .{ .test_expr = test_acc, .bindings = binds.items, .guard = guard_acc };
}

/// array match pattern: `Array.isArray(S) && S.length (===|>=) N && <sub(S[i])>` (+rest slice).
fn lowerArrayPattern(self: *Transformer, pnode: Node, subject: NodeIndex, span: Span) Error!LoweredPattern {
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
        try es_helpers.makeStaticMember(self, try es_helpers.makeIdentifierRef(self, "Array"), try es_helpers.makeIdentifierRef(self, "isArray"), span),
        &.{try es_helpers.cloneNode(self, subject)},
        span,
    );
    const len_member = try es_helpers.makeStaticMember(self, try es_helpers.cloneNode(self, subject), try es_helpers.makeIdentifierRef(self, "length"), span);
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
        const member = try es_helpers.makeComputedMember(self, try es_helpers.cloneNode(self, subject), try mkNum(self, idx), span);
        const sub = try lowerMatchPattern(self, child, member, span);
        if (!isAlwaysTrue(self, sub.test_expr)) test_acc = try andJoin(self, span, test_acc, sub.test_expr);
        for (sub.bindings) |b| try binds.append(self.allocator, b);
        if (!sub.guard.isNone()) guard_acc = try andJoin(self, span, guard_acc, sub.guard);
        idx += 1;
    }
    if (!rest_node.isNone() and self.ast.getNode(rest_node).data.none == 1) {
        // let <rest> = S.slice(elem_count)
        const slice_call = try es_helpers.makeCallExpr(
            self,
            try es_helpers.makeStaticMember(self, try es_helpers.cloneNode(self, subject), try es_helpers.makeIdentifierRef(self, "slice"), span),
            &.{try mkNum(self, elem_count)},
            span,
        );
        const bind = try es_helpers.makeBindingIdentifier(self, self.ast.getNode(rest_node).span);
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
fn lowerMatchPattern(self: *Transformer, pattern: NodeIndex, subject: NodeIndex, span: Span) Error!LoweredPattern {
    const pnode = self.ast.getNode(pattern);
    switch (pnode.tag) {
        .flow_match_opaque_pattern => return .{
            .test_expr = try mkBool(self, false),
            .bindings = &.{},
            .guard = .none,
        },
        .flow_match_binding_pattern => {
            const binds = try self.allocator.alloc(NodeIndex, 1);
            binds[0] = try mkBindingDecl(self, pnode.span, subject, span);
            return .{ .test_expr = try mkBool(self, true), .bindings = binds, .guard = .none };
        },
        .flow_match_or_pattern => {
            const lst = pnode.data.list;
            var acc: NodeIndex = .none;
            var i: u32 = 0;
            while (i < lst.len) : (i += 1) {
                const sub: NodeIndex = @enumFromInt(self.ast.extra_data.items[lst.start + i]);
                const lp = try lowerMatchPattern(self, sub, try es_helpers.cloneNode(self, subject), span);
                acc = if (acc.isNone()) lp.test_expr else try mkBin(self, span, acc, lp.test_expr, .pipe2);
            }
            if (acc.isNone()) acc = try mkBool(self, false);
            return .{ .test_expr = acc, .bindings = &.{}, .guard = .none };
        },
        .flow_match_as_pattern => {
            const lp = try lowerMatchPattern(self, pnode.data.binary.left, try es_helpers.cloneNode(self, subject), span);
            const id_node = self.ast.getNode(pnode.data.binary.right);
            const extra_decl = try mkBindingDecl(self, id_node.span, subject, span);
            const binds = try self.allocator.alloc(NodeIndex, lp.bindings.len + 1);
            std.mem.copyForwards(NodeIndex, binds[0..lp.bindings.len], lp.bindings);
            binds[lp.bindings.len] = extra_decl;
            return .{ .test_expr = lp.test_expr, .bindings = binds, .guard = lp.guard };
        },
        .flow_match_guard_pattern => {
            const lp = try lowerMatchPattern(self, pnode.data.binary.left, subject, span);
            const g = try self.visitNode(pnode.data.binary.right);
            const combined = if (lp.guard.isNone()) g else try mkBin(self, span, lp.guard, g, .amp2);
            return .{ .test_expr = lp.test_expr, .bindings = lp.bindings, .guard = combined };
        },
        .flow_match_object_pattern => return lowerObjectPattern(self, pnode, subject, span),
        .flow_match_array_pattern => return lowerArrayPattern(self, pnode, subject, span),
        .flow_match_instance_pattern => {
            // S instanceof Ctor && <object body test>
            const ctor = try self.visitNode(pnode.data.binary.left);
            const inst = try mkBin(self, span, try es_helpers.cloneNode(self, subject), ctor, .kw_instanceof);
            const body = self.ast.getNode(pnode.data.binary.right);
            const lp = try lowerObjectPattern(self, body, subject, span);
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
        .test_expr = try mkBin(self, span, try es_helpers.cloneNode(self, subject), v, .eq3),
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
    const match_param = try es_helpers.makeBindingIdentifier(self, match_var);

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

        const subject = try es_helpers.makeTempVarRef(self, match_var, match_var);
        const lp = try lowerMatchPattern(self, pattern, subject, span);

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
        const then_block = try mkBlock(self, span, then_list.items);

        if_stmts[k] = try self.ast.addNode(.{
            .tag = .if_statement,
            .span = span,
            .data = .{ .ternary = .{ .a = lp.test_expr, .b = then_block, .c = NodeIndex.none } },
        });
    }

    // function(_m) { if-list }
    const fn_body = try mkBlock(self, span, if_stmts);
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
pub fn visitFlowComponentWrapper(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const func_decl_idx = self.readNodeIdx(e, 0);
    const const_decl_idx = self.readNodeIdx(e, 1);

    // function Name_withRef 방문 (ES2015 lowering 등 적용)
    const new_func = try self.visitNode(func_decl_idx);
    try self.pending_nodes.append(self.allocator, new_func);

    // const Name = React.forwardRef(Name_withRef) 방문
    return self.visitNode(const_decl_idx);
}
