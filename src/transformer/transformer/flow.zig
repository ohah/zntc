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
fn mkBindingDecl(self: *Transformer, id_span: Span, match_var: Span, span: Span) Error!NodeIndex {
    const subj = try es_helpers.makeTempVarRef(self, match_var, match_var);
    const bind = try es_helpers.makeBindingIdentifier(self, id_span);
    const decl = try es_helpers.makeDeclarator(self, bind, subj, span);
    return es_helpers.makeVarDeclaration(self, &.{decl}, .let, span);
}

/// match pattern → (test, bindings, guard). discriminant 는 `match_var` temp.
/// Flow match semantics:
///   wildcard `_`            → 항상 매치
///   binding `const x`       → 항상 매치 + `let x = _m`
///   literal/member/unary    → `_m === <expr>`
///   OR `a | b`              → `test(a) || test(b)` (OR 내부 binding/guard 무시)
///   as `p as x`             → test(p) + `let x = _m`
///   guard `p if (c)`        → test(p), binding 후 `c` 평가
///   object/array/instance   → opaque (false, 후속 PR 에서 정밀 구조분해)
fn lowerMatchPattern(self: *Transformer, pattern: NodeIndex, match_var: Span, span: Span) Error!LoweredPattern {
    const pnode = self.ast.getNode(pattern);
    switch (pnode.tag) {
        .flow_match_opaque_pattern => return .{
            .test_expr = try mkBool(self, false),
            .bindings = &.{},
            .guard = .none,
        },
        .flow_match_binding_pattern => {
            const binds = try self.allocator.alloc(NodeIndex, 1);
            binds[0] = try mkBindingDecl(self, pnode.span, match_var, span);
            return .{ .test_expr = try mkBool(self, true), .bindings = binds, .guard = .none };
        },
        .flow_match_or_pattern => {
            const lst = pnode.data.list;
            var acc: NodeIndex = .none;
            var i: u32 = 0;
            while (i < lst.len) : (i += 1) {
                const sub: NodeIndex = @enumFromInt(self.ast.extra_data.items[lst.start + i]);
                const lp = try lowerMatchPattern(self, sub, match_var, span);
                acc = if (acc.isNone()) lp.test_expr else try mkBin(self, span, acc, lp.test_expr, .pipe2);
            }
            if (acc.isNone()) acc = try mkBool(self, false);
            return .{ .test_expr = acc, .bindings = &.{}, .guard = .none };
        },
        .flow_match_as_pattern => {
            const lp = try lowerMatchPattern(self, pnode.data.binary.left, match_var, span);
            const id_node = self.ast.getNode(pnode.data.binary.right);
            const extra_decl = try mkBindingDecl(self, id_node.span, match_var, span);
            const binds = try self.allocator.alloc(NodeIndex, lp.bindings.len + 1);
            std.mem.copyForwards(NodeIndex, binds[0..lp.bindings.len], lp.bindings);
            binds[lp.bindings.len] = extra_decl;
            return .{ .test_expr = lp.test_expr, .bindings = binds, .guard = lp.guard };
        },
        .flow_match_guard_pattern => {
            const lp = try lowerMatchPattern(self, pnode.data.binary.left, match_var, span);
            const g = try self.visitNode(pnode.data.binary.right);
            const combined = if (lp.guard.isNone()) g else try mkBin(self, span, lp.guard, g, .amp2);
            return .{ .test_expr = lp.test_expr, .bindings = lp.bindings, .guard = combined };
        },
        // wildcard `_` 는 무조건 매치.
        .identifier_reference => if (std.mem.eql(u8, self.ast.getText(pnode.span), "_")) {
            return .{ .test_expr = try mkBool(self, true), .bindings = &.{}, .guard = .none };
        },
        else => {},
    }
    // identifier(non-`_`) / literal / member / unary → `_m === <expr>`
    const subj = try es_helpers.makeTempVarRef(self, match_var, match_var);
    const v = try self.visitNode(pattern);
    return .{ .test_expr = try mkBin(self, span, subj, v, .eq3), .bindings = &.{}, .guard = .none };
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
        const ret = try self.ast.addNode(.{
            .tag = .return_statement,
            .span = span,
            .data = .{ .unary = .{ .operand = new_body_raw, .flags = 0 } },
        });

        const lp = try lowerMatchPattern(self, pattern, match_var, span);

        // then-block: bindings... + (guard ? if (guard) return body : return body)
        const tail = if (lp.guard.isNone()) ret else try self.ast.addNode(.{
            .tag = .if_statement,
            .span = span,
            .data = .{ .ternary = .{
                .a = lp.guard,
                .b = try mkBlock(self, span, &.{ret}),
                .c = NodeIndex.none,
            } },
        });
        const then_stmts = try self.allocator.alloc(NodeIndex, lp.bindings.len + 1);
        defer self.allocator.free(then_stmts);
        std.mem.copyForwards(NodeIndex, then_stmts[0..lp.bindings.len], lp.bindings);
        then_stmts[lp.bindings.len] = tail;
        const then_block = try mkBlock(self, span, then_stmts);

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
    // function expression을 parenthesized로 감싸서 IIFE 형태로 만듦
    const paren_fn = try es_helpers.makeParenExpr(self, fn_expr, span);
    // call_expression extra: [callee, args_start, args_len, flags]
    const args_list = try self.ast.addNodeList(&.{new_discriminant});
    const call_extra = try self.ast.addExtras(&.{
        @intFromEnum(paren_fn),
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
