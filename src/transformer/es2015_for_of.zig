//! ES2015 다운레벨링: for-of loop
//!
//! --target < es2015 일 때 활성화.
//!
//! Iterator protocol 변환:
//!
//! for (const x of iterable) { body }
//! →
//! var _a = true, _b = false, _c = undefined;
//! try {
//!   for (var _d = iterable[Symbol.iterator](), _e;
//!        !(_a = (_e = _d.next()).done);
//!        _a = true) {
//!     var x = _e.value;
//!     body
//!   }
//! } catch (err) {
//!   _b = true;
//!   _c = err;
//! } finally {
//!   try {
//!     if (!_a && _d.return != null) {
//!       _d.return();
//!     }
//!   } finally {
//!     if (_b) { throw _c; }
//!   }
//! }
//!
//! 이 패턴은 Set, Map, Generator 등 모든 iterable을 올바르게 순회한다.
//! 이전 구현은 .length/[] 배열 패턴만 지원하여 Set 등에서 깨짐.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-for-in-and-for-of-statements (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/for_of.rs
//! - TypeScript: src/compiler/transformers/es2015.ts

const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2015ForOf(comptime Transformer: type) type {
    return struct {
        // for_await_of_statement (ES2018) is not downleveled at any target —
        // matches SWC/esbuild behavior. Full downlevel requires an async
        // iterator protocol helper (cf. Babel's plugin-proposal-async-generator-functions).
        /// for (const x of iterable) { body }
        /// → iterator protocol (try-catch-finally 포함)
        pub fn lowerForOfStatement(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            return lowerForOfStatementLabeled(self, node, .none);
        }

        /// `label_name_idx`가 주어지면 lowered inner `for_statement`에 label을 부여해
        /// `continue <label>` / `break <label>` 가 iteration statement를 타겟으로 하게 한다.
        /// 미지정(.none)이면 일반 for-of 경로.
        pub fn lowerForOfStatementLabeled(self: *Transformer, node: Node, label_name_idx: NodeIndex) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a; // loop variable (variable_declaration or expression)
            const right = node.data.ternary.b; // iterable
            const body = node.data.ternary.c; // body

            // 임시 변수 (makeTempVarSpan으로 고유 이름 생성 — 중첩 for-of 안전)
            const inc_span = try es_helpers.makeTempVarSpan(self); // _a: iteratorNormalCompletion
            const die_span = try es_helpers.makeTempVarSpan(self); // _b: didIteratorError
            const ie_span = try es_helpers.makeTempVarSpan(self); // _c: iteratorError
            const iter_span = try es_helpers.makeTempVarSpan(self); // _d: iterator
            const step_span = try es_helpers.makeTempVarSpan(self); // _e: step
            const err_span = try es_helpers.makeTempVarSpan(self); // _f: catch param

            // 리터럴 span 캐싱 (addString 중복 호출 방지)
            const true_span = try self.ast.addString("true");
            const false_span = try self.ast.addString("false");
            const null_span_cached = try self.ast.addString("null");

            const new_right = try self.visitNode(right);

            // =====================================================
            // 1. 세 개의 var 선언 (try 바깥)
            // =====================================================

            // var _a = true
            const inc_true = try makeBoolLiteral(self, true_span, true);
            const inc_decl = try makeVarDeclFromSpan(self, inc_span, inc_true, span);

            // var _b = false
            const die_false = try makeBoolLiteral(self, false_span, false);
            const die_decl = try makeVarDeclFromSpan(self, die_span, die_false, span);

            // var _c = void 0
            const ie_undef = try es_helpers.makeVoidZero(self, span);
            const ie_decl = try makeVarDeclFromSpan(self, ie_span, ie_undef, span);

            // =====================================================
            // 2. for 문 (try 블록 안)
            // =====================================================

            // --- init: var _d = iterable[Symbol.iterator](), _e ---

            // iterable[Symbol.iterator]()
            const symbol_ref = try es_helpers.makeIdentifierRef(self, "Symbol");
            const iterator_prop = try es_helpers.makeIdentifierRef(self, "iterator");
            const symbol_iterator = try es_helpers.makeStaticMember(self, symbol_ref, iterator_prop, span);
            const iterable_iter_method = try es_helpers.makeComputedMember(self, new_right, symbol_iterator, span);
            const iter_call = try es_helpers.makeCallExpr(self, iterable_iter_method, &.{}, span);

            // var _d = ..., _e
            const iter_binding = try es_helpers.makeBindingIdentifier(self, iter_span);
            const iter_declarator = try es_helpers.makeDeclarator(self, iter_binding, iter_call, span);
            const step_binding = try es_helpers.makeBindingIdentifier(self, step_span);
            const step_declarator = try es_helpers.makeDeclarator(self, step_binding, .none, span);
            const for_init = try es_helpers.makeVarDeclaration(self, &.{ iter_declarator, step_declarator }, .@"var", span);

            // --- test: !(_a = (_e = _d.next()).done) ---

            // _d.next()
            const iter_ref_next = try makeRefFromSpan(self, iter_span, span);
            const next_prop = try es_helpers.makeIdentifierRef(self, "next");
            const iter_next = try es_helpers.makeStaticMember(self, iter_ref_next, next_prop, span);
            const iter_next_call = try es_helpers.makeCallExpr(self, iter_next, &.{}, span);

            // _e = _d.next()
            const step_ref_assign = try makeRefFromSpan(self, step_span, span);
            const step_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = step_ref_assign, .right = iter_next_call, .flags = 0 } },
            });

            // (_e = _d.next()).done
            const paren_step = try es_helpers.makeParenExpr(self, step_assign, span);
            const done_prop = try es_helpers.makeIdentifierRef(self, "done");
            const step_done = try es_helpers.makeStaticMember(self, paren_step, done_prop, span);

            // _a = (...).done
            const inc_ref_assign = try makeRefFromSpan(self, inc_span, span);
            const inc_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = inc_ref_assign, .right = step_done, .flags = 0 } },
            });

            // !(_a = ...)
            const paren_inc = try es_helpers.makeParenExpr(self, inc_assign, span);
            const not_inc = try makeUnaryNot(self, paren_inc, span);

            // --- update: _a = true ---
            const inc_ref_update = try makeRefFromSpan(self, inc_span, span);
            const update_true = try makeBoolLiteral(self, true_span, true);
            const for_update = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = inc_ref_update, .right = update_true, .flags = 0 } },
            });

            // --- body: var x = _e.value; original_body ---
            const new_body = try self.visitNode(body);

            // _e.value
            const step_ref_body = try makeRefFromSpan(self, step_span, span);
            const value_prop = try es_helpers.makeIdentifierRef(self, "value");
            const step_value = try es_helpers.makeStaticMember(self, step_ref_body, value_prop, span);

            // var x = _e.value
            const elem_assign = try buildLoopVarAssign(self, left, step_value, span);

            // prepend to body
            const final_body = if (!new_body.isNone())
                try self.prependStatementsToBody(new_body, &.{elem_assign})
            else
                new_body;

            // --- for_statement ---
            const for_extra = try self.ast.addExtras(&.{
                @intFromEnum(for_init),
                @intFromEnum(not_inc),
                @intFromEnum(for_update),
                @intFromEnum(final_body),
            });
            const for_stmt = try self.ast.addNode(.{
                .tag = .for_statement,
                .span = span,
                .data = .{ .extra = for_extra },
            });

            // =====================================================
            // 3. try 블록
            // =====================================================
            // labeled for-of: label을 block 대신 inner for_statement에 붙여야
            // `continue LABEL` 이 합법적인 iteration statement를 가리킨다.
            const labeled_for_stmt = if (label_name_idx.isNone())
                for_stmt
            else
                try self.ast.addNode(.{
                    .tag = .labeled_statement,
                    .span = span,
                    .data = .{ .binary = .{ .left = label_name_idx, .right = for_stmt, .flags = 0 } },
                });
            const try_body_list = try self.ast.addNodeList(&.{labeled_for_stmt});
            const try_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = try_body_list },
            });

            // =====================================================
            // 4. catch (_f) { _b = true; _c = _f; }
            // =====================================================
            const die_ref_catch = try makeRefFromSpan(self, die_span, span);
            const catch_true = try makeBoolLiteral(self, true_span, true);
            const die_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = die_ref_catch, .right = catch_true, .flags = 0 } },
            });
            const die_stmt = try es_helpers.makeExprStmt(self, die_assign, span);

            const ie_ref_catch = try makeRefFromSpan(self, ie_span, span);
            const err_ref_catch = try makeRefFromSpan(self, err_span, span);
            const ie_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = ie_ref_catch, .right = err_ref_catch, .flags = 0 } },
            });
            const ie_stmt = try es_helpers.makeExprStmt(self, ie_assign, span);

            const catch_body_list = try self.ast.addNodeList(&.{ die_stmt, ie_stmt });
            const catch_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = catch_body_list },
            });
            const catch_param = try es_helpers.makeBindingIdentifier(self, err_span);
            const catch_clause = try self.ast.addNode(.{
                .tag = .catch_clause,
                .span = span,
                .data = .{ .binary = .{ .left = catch_param, .right = catch_body, .flags = 0 } },
            });

            // =====================================================
            // 5. finally: try { if (!_a && _d.return != null) { _d.return(); } }
            //             finally { if (_b) { throw _c; } }
            // =====================================================

            // !_a
            const inc_ref_finally = try makeRefFromSpan(self, inc_span, span);
            const not_inc_finally = try makeUnaryNot(self, inc_ref_finally, span);

            // _d.return != null
            const iter_ref_finally = try makeRefFromSpan(self, iter_span, span);
            const return_prop = try es_helpers.makeIdentifierRef(self, "return");
            const iter_return = try es_helpers.makeStaticMember(self, iter_ref_finally, return_prop, span);
            const null_lit = try self.ast.addNode(.{
                .tag = .null_literal,
                .span = null_span_cached,
                .data = .{ .none = 0 },
            });
            const return_neq_null = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = iter_return,
                    .right = null_lit,
                    .flags = @intFromEnum(token_mod.Kind.neq),
                } },
            });

            // !_a && _d.return != null
            const and_expr = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = not_inc_finally,
                    .right = return_neq_null,
                    .flags = @intFromEnum(token_mod.Kind.amp2),
                } },
            });

            // _d.return()
            const iter_ref_call = try makeRefFromSpan(self, iter_span, span);
            const return_prop2 = try es_helpers.makeIdentifierRef(self, "return");
            const iter_return2 = try es_helpers.makeStaticMember(self, iter_ref_call, return_prop2, span);
            const iter_return_call = try es_helpers.makeCallExpr(self, iter_return2, &.{}, span);
            const iter_return_stmt = try es_helpers.makeExprStmt(self, iter_return_call, span);

            // if (!_a && _d.return != null) { _d.return(); }
            const if_body_list = try self.ast.addNodeList(&.{iter_return_stmt});
            const if_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = if_body_list },
            });
            const inner_if = try self.ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = and_expr, .b = if_body, .c = .none } },
            });

            const inner_try_body_list = try self.ast.addNodeList(&.{inner_if});
            const inner_try_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = inner_try_body_list },
            });

            // if (_b) { throw _c; }
            const die_ref_finally = try makeRefFromSpan(self, die_span, span);
            const ie_ref_finally = try makeRefFromSpan(self, ie_span, span);
            const throw_ie = try self.ast.addNode(.{
                .tag = .throw_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = ie_ref_finally, .flags = 0 } },
            });
            const inner_finally_if_body_list = try self.ast.addNodeList(&.{throw_ie});
            const inner_finally_if_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = inner_finally_if_body_list },
            });
            const inner_finally_if = try self.ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = die_ref_finally, .b = inner_finally_if_body, .c = .none } },
            });
            const inner_finally_list = try self.ast.addNodeList(&.{inner_finally_if});
            const inner_finally_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = inner_finally_list },
            });

            // inner try-finally (no catch)
            const inner_try_stmt = try self.ast.addNode(.{
                .tag = .try_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = inner_try_block, .b = .none, .c = inner_finally_block } },
            });

            // outer finally
            const outer_finally_list = try self.ast.addNodeList(&.{inner_try_stmt});
            const outer_finally_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = outer_finally_list },
            });

            // =====================================================
            // 6. 전체 try-catch-finally 조립
            // =====================================================
            const try_catch_finally = try self.ast.addNode(.{
                .tag = .try_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = try_block, .b = catch_clause, .c = outer_finally_block } },
            });

            // 4개 statement를 block으로 래핑하여 단일 노드로 반환.
            // pending_nodes를 쓰면 중첩 for-of에서 inner가 outer body 밖으로 빠져나감.
            const wrapper_list = try self.ast.addNodeList(&.{ inc_decl, die_decl, ie_decl, try_catch_finally });
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = wrapper_list },
            });
        }

        // ================================================================
        // 헬퍼
        // ================================================================

        fn makeRefFromSpan(self: *Transformer, name_span: Span, node_span: Span) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = node_span,
                .data = .{ .string_ref = name_span },
            });
        }

        fn makeBoolLiteral(self: *Transformer, lit_span: Span, value: bool) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{
                .tag = .boolean_literal,
                .span = lit_span,
                .data = .{ .none = if (value) 1 else 0 },
            });
        }

        fn makeUnaryNot(self: *Transformer, operand: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const extra = try self.ast.addExtras(&.{
                @intFromEnum(operand),
                @intFromEnum(token_mod.Kind.bang),
            });
            return self.ast.addNode(.{
                .tag = .unary_expression,
                .span = span,
                .data = .{ .extra = extra },
            });
        }

        fn makeVarDeclFromSpan(self: *Transformer, name_span: Span, init: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const binding = try es_helpers.makeBindingIdentifier(self, name_span);
            const declarator = try es_helpers.makeDeclarator(self, binding, init, span);
            return es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
        }

        /// for-of의 left를 기반으로 var 선언 또는 대입문 생성.
        ///
        /// Destructuring pattern(`const [a,b]` / `const {a,b}`) 은 ES5 `var` 내부
        /// 에 올 수 없으므로 임시 변수 + element/prop 접근 declarator 로 전개한다.
        /// 즉 `var [a, b] = _e.value` → `var _t = _e.value, a = _t[0], b = _t[1]`.
        fn buildLoopVarAssign(self: *Transformer, left: NodeIndex, elem: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (left.isNone()) return NodeIndex.none;
            const left_node = self.ast.getNode(left);

            if (left_node.tag == .variable_declaration) {
                const le = left_node.data.extra;
                const list_start = self.readU32(le, 1);
                const list_len = self.readU32(le, 2);
                if (list_len == 0) return NodeIndex.none;

                const first_decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list_start]);
                const first_decl = self.ast.getNode(first_decl_idx);
                if (first_decl.tag != .variable_declarator) return NodeIndex.none;

                const binding_idx: NodeIndex = self.readNodeIdx(first_decl.data.extra, 0);
                if (binding_idx.isNone()) return NodeIndex.none;
                const binding_node = self.ast.getNode(binding_idx);

                if (binding_node.tag == .array_pattern or binding_node.tag == .object_pattern) {
                    // Destructuring pattern — 임시 변수 _t 도입 후 패턴을 declarator로 전개
                    const temp_span = try es_helpers.makeTempVarSpan(self);
                    const temp_binding = try es_helpers.makeBindingIdentifier(self, temp_span);
                    const temp_decl = try es_helpers.makeDeclarator(self, temp_binding, elem, span);

                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    try self.scratch.append(self.allocator, temp_decl);

                    const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
                    try es2015_destruct.emitPatternDeclarators(self, binding_node, temp_span, span);

                    return es_helpers.makeVarDeclaration(self, self.scratch.items[scratch_top..], .@"var", span);
                }

                const binding_name = try self.visitNode(binding_idx);
                const declarator = try es_helpers.makeDeclarator(self, binding_name, elem, span);
                return es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
            } else if (left_node.tag == .array_assignment_target or left_node.tag == .object_assignment_target) {
                // Assignment destructuring: `for ([a,b] of ...)` → _t = elem; a = _t[0]; ...
                // 기존 lowerDestructuringAssignment 경로(시퀀스 expression)를 재사용.
                const assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = left, .right = elem, .flags = 0 } },
                });
                const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
                const lowered_seq = try es2015_destruct.lowerDestructuringAssignment(self, self.ast.getNode(assign));
                return es_helpers.makeExprStmt(self, lowered_seq, span);
            } else {
                const new_left = try self.visitNode(left);
                const assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = new_left, .right = elem, .flags = 0 } },
                });
                return self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
                });
            }
        }
    };
}

test "ES2015 for-of module compiles" {
    _ = ES2015ForOf;
}
