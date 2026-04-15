//! ES2018 다운레벨링: for-await-of loop
//!
//! --target < es2017 (async_await unsupported) 일 때 활성화.
//! Hermes / ES5는 `for await` 키워드 자체를 파싱하지 못하므로, async function body 가
//! `__async(function*() { ... })` 로 래핑되기 전에 미리 `while` 루프로 변환해야 한다.
//!
//! 입력:
//!   for await (const v of iterable) body;
//!
//! 출력 (tsc __asyncValues 스타일):
//!   {
//!     var _iter = __asyncValues(iterable), _step, _ret, _err_obj;
//!     try {
//!       while (!(_step = await _iter.next()).done) {
//!         var v = _step.value;
//!         body;
//!       }
//!     } catch (_err) { _err_obj = { error: _err }; }
//!     finally {
//!       try { if (_step && !_step.done && (_ret = _iter.return)) await _ret.call(_iter); }
//!       finally { if (_err_obj) throw _err_obj.error; }
//!     }
//!   }
//!
//! 바깥쪽 async function 이 ES2017 lowering 으로 `__async(function*(){...})` 로 변환되면
//! 내부의 `await` 는 `yield` 로 재변환된다. 즉 이 변환은 for-await 키워드/구조만 제거하고
//! `await` 자체는 그대로 둠. 후속 ES2017 lowering 이 yield 변환을 처리.
//!
//! Flow gate: `options.unsupported.async_await` (= ES2017 미지원 = for-await 도 동시에 미지원).
//! 별도의 for_await 피쳐 플래그를 두지 않은 이유: for-await 는 async function 안에서만 쓸 수
//! 있고, 엔진 관점에서 for-await 만 구현/async_await 만 구현 같은 비대칭 조합이 실질적으로
//! 존재하지 않음.
//!
//! 참고:
//! - TypeScript: src/compiler/transformers/es2018.ts (visitForAwaitOfStatement)
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerForAwaitLoop)
//! - tslib: __asyncValues

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2018ForAwait(comptime Transformer: type) type {
    return struct {
        /// for await (const v of iter) body; → iterator protocol + await 수동 루프.
        ///
        /// label 이 있으면 inner while_statement 에 부여 (break/continue LABEL 지원).
        pub fn lowerForAwaitOf(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            return lowerForAwaitOfLabeled(self, node, .none);
        }

        pub fn lowerForAwaitOfLabeled(self: *Transformer, node: Node, label_name_idx: NodeIndex) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a;
            const right = node.data.ternary.b;
            const body = node.data.ternary.c;

            // 런타임 헬퍼 사용 마킹.
            self.runtime_helpers.async_values = true;

            // 임시 변수 span (겹침 방지 — makeTempVarSpan 는 counter 기반 고유 이름).
            const iter_span = try es_helpers.makeTempVarSpan(self); // _a: iterator
            const step_span = try es_helpers.makeTempVarSpan(self); // _b: step
            const ret_span = try es_helpers.makeTempVarSpan(self); // _c: iterator.return 캐시
            const errobj_span = try es_helpers.makeTempVarSpan(self); // _d: { error }
            const err_span = try es_helpers.makeTempVarSpan(self); // _e: catch param

            const new_right = try self.visitNode(right);

            // =====================================================
            // 1. var _iter = __asyncValues(iterable), _step, _ret, _errObj;
            // =====================================================
            const async_values_ref = try es_helpers.makeIdentifierRef(self, "__asyncValues");
            const async_values_call = try es_helpers.makeCallExpr(self, async_values_ref, &.{new_right}, span);

            const iter_binding = try es_helpers.makeBindingIdentifier(self, iter_span);
            const iter_decl = try es_helpers.makeDeclarator(self, iter_binding, async_values_call, span);

            const step_binding = try es_helpers.makeBindingIdentifier(self, step_span);
            const step_decl = try es_helpers.makeDeclarator(self, step_binding, .none, span);

            const ret_binding = try es_helpers.makeBindingIdentifier(self, ret_span);
            const ret_decl = try es_helpers.makeDeclarator(self, ret_binding, .none, span);

            const errobj_binding = try es_helpers.makeBindingIdentifier(self, errobj_span);
            const errobj_decl = try es_helpers.makeDeclarator(self, errobj_binding, .none, span);

            const outer_var = try es_helpers.makeVarDeclaration(self, &.{ iter_decl, step_decl, ret_decl, errobj_decl }, .@"var", span);

            // =====================================================
            // 2. while test: !(_step = await _iter.next()).done
            // =====================================================
            const iter_ref_next = try es_helpers.makeIdentifierRefFromSpan(self, iter_span);
            const next_prop = try es_helpers.makeIdentifierRef(self, "next");
            const iter_next = try es_helpers.makeStaticMember(self, iter_ref_next, next_prop, span);
            const iter_next_call = try es_helpers.makeCallExpr(self, iter_next, &.{}, span);

            // await _iter.next()
            const await_next = try self.ast.addNode(.{
                .tag = .yield_expression,
                .span = span,
                .data = .{ .unary = .{ .operand = iter_next_call, .flags = 0 } },
            });

            // _step = await _iter.next()
            const step_ref_assign = try es_helpers.makeIdentifierRefFromSpan(self, step_span);
            const step_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = step_ref_assign, .right = await_next, .flags = 0 } },
            });

            // (_step = await _iter.next()).done
            const paren_step = try es_helpers.makeParenExpr(self, step_assign, span);
            const done_prop = try es_helpers.makeIdentifierRef(self, "done");
            const step_done = try es_helpers.makeStaticMember(self, paren_step, done_prop, span);

            // !(...)
            const not_done = try makeUnaryNot(self, step_done, span);

            // =====================================================
            // 3. while body: var v = _step.value; body;
            // =====================================================
            const step_ref_body = try es_helpers.makeIdentifierRefFromSpan(self, step_span);
            const value_prop = try es_helpers.makeIdentifierRef(self, "value");
            const step_value = try es_helpers.makeStaticMember(self, step_ref_body, value_prop, span);

            const new_body = try self.visitNode(body);

            const elem_stmt = try buildLoopVarAssign(self, left, step_value, span);

            const while_body_block = if (!new_body.isNone())
                try self.prependStatementsToBody(new_body, &.{elem_stmt})
            else blk: {
                const list = try self.ast.addNodeList(&.{elem_stmt});
                break :blk try self.ast.addNode(.{
                    .tag = .block_statement,
                    .span = span,
                    .data = .{ .list = list },
                });
            };

            // while_statement: data.binary = { left=test, right=body }
            const while_stmt = try self.ast.addNode(.{
                .tag = .while_statement,
                .span = span,
                .data = .{ .binary = .{ .left = not_done, .right = while_body_block, .flags = 0 } },
            });

            // labeled while 지원 (iteration statement 라서 continue LABEL 합법).
            const labeled_while = if (label_name_idx.isNone())
                while_stmt
            else
                try self.ast.addNode(.{
                    .tag = .labeled_statement,
                    .span = span,
                    .data = .{ .binary = .{ .left = label_name_idx, .right = while_stmt, .flags = 0 } },
                });

            // =====================================================
            // 4. try block
            // =====================================================
            const try_body_list = try self.ast.addNodeList(&.{labeled_while});
            const try_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = try_body_list },
            });

            // =====================================================
            // 5. catch (_err) { _errObj = { error: _err }; }
            // =====================================================
            const errobj_ref_catch = try es_helpers.makeIdentifierRefFromSpan(self, errobj_span);
            const error_key = try es_helpers.makeIdentifierRef(self, "error");
            const err_ref_catch = try es_helpers.makeIdentifierRefFromSpan(self, err_span);
            const error_prop = try self.ast.addNode(.{
                .tag = .object_property,
                .span = span,
                .data = .{ .binary = .{ .left = error_key, .right = err_ref_catch, .flags = 0 } },
            });
            const error_props_list = try self.ast.addNodeList(&.{error_prop});
            const error_obj = try self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = error_props_list },
            });
            const errobj_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = errobj_ref_catch, .right = error_obj, .flags = 0 } },
            });
            const errobj_assign_stmt = try es_helpers.makeExprStmt(self, errobj_assign, span);
            const catch_body_list = try self.ast.addNodeList(&.{errobj_assign_stmt});
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
            // 6. finally:
            //    try {
            //      if (_step && !_step.done && (_ret = _iter.return)) await _ret.call(_iter);
            //    } finally { if (_errObj) throw _errObj.error; }
            // =====================================================

            // _step
            const step_ref_f1 = try es_helpers.makeIdentifierRefFromSpan(self, step_span);

            // _step.done
            const step_ref_f2 = try es_helpers.makeIdentifierRefFromSpan(self, step_span);
            const done_prop2 = try es_helpers.makeIdentifierRef(self, "done");
            const step_done2 = try es_helpers.makeStaticMember(self, step_ref_f2, done_prop2, span);
            const not_step_done = try makeUnaryNot(self, step_done2, span);

            // _step && !_step.done
            const and1 = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = step_ref_f1,
                    .right = not_step_done,
                    .flags = @intFromEnum(token_mod.Kind.amp2),
                } },
            });

            // _iter.return
            const iter_ref_f = try es_helpers.makeIdentifierRefFromSpan(self, iter_span);
            const return_prop = try es_helpers.makeIdentifierRef(self, "return");
            const iter_return = try es_helpers.makeStaticMember(self, iter_ref_f, return_prop, span);

            // _ret = _iter.return
            const ret_ref_assign = try es_helpers.makeIdentifierRefFromSpan(self, ret_span);
            const ret_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = ret_ref_assign, .right = iter_return, .flags = 0 } },
            });
            const paren_ret_assign = try es_helpers.makeParenExpr(self, ret_assign, span);

            // (_step && !_step.done) && (_ret = _iter.return)
            const and2 = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = and1,
                    .right = paren_ret_assign,
                    .flags = @intFromEnum(token_mod.Kind.amp2),
                } },
            });

            // _ret.call(_iter)
            const ret_ref_call = try es_helpers.makeIdentifierRefFromSpan(self, ret_span);
            const call_prop = try es_helpers.makeIdentifierRef(self, "call");
            const ret_call_method = try es_helpers.makeStaticMember(self, ret_ref_call, call_prop, span);
            const iter_ref_arg = try es_helpers.makeIdentifierRefFromSpan(self, iter_span);
            const ret_call = try es_helpers.makeCallExpr(self, ret_call_method, &.{iter_ref_arg}, span);

            // await _ret.call(_iter)
            const await_ret_call = try self.ast.addNode(.{
                .tag = .yield_expression,
                .span = span,
                .data = .{ .unary = .{ .operand = ret_call, .flags = 0 } },
            });
            const await_stmt = try es_helpers.makeExprStmt(self, await_ret_call, span);

            // if (_step && !_step.done && (_ret = _iter.return)) await _ret.call(_iter);
            const if_return = try self.ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = and2, .b = await_stmt, .c = .none } },
            });

            const inner_try_body_list = try self.ast.addNodeList(&.{if_return});
            const inner_try_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = inner_try_body_list },
            });

            // inner finally: if (_errObj) throw _errObj.error;
            const errobj_ref_f = try es_helpers.makeIdentifierRefFromSpan(self, errobj_span);
            const errobj_ref_throw = try es_helpers.makeIdentifierRefFromSpan(self, errobj_span);
            const error_prop_ref = try es_helpers.makeIdentifierRef(self, "error");
            const errobj_error = try es_helpers.makeStaticMember(self, errobj_ref_throw, error_prop_ref, span);
            const throw_stmt = try self.ast.addNode(.{
                .tag = .throw_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = errobj_error, .flags = 0 } },
            });
            const if_throw_body_list = try self.ast.addNodeList(&.{throw_stmt});
            const if_throw_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = if_throw_body_list },
            });
            const if_throw = try self.ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = errobj_ref_f, .b = if_throw_body, .c = .none } },
            });
            const inner_finally_list = try self.ast.addNodeList(&.{if_throw});
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

            // outer finally block = { inner_try_stmt }
            const outer_finally_list = try self.ast.addNodeList(&.{inner_try_stmt});
            const outer_finally_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = outer_finally_list },
            });

            // =====================================================
            // 7. 최종 try-catch-finally
            // =====================================================
            const try_stmt = try self.ast.addNode(.{
                .tag = .try_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = try_block, .b = catch_clause, .c = outer_finally_block } },
            });

            // 전체를 하나의 block 으로 래핑 (pending_nodes 사용 시 중첩에서 범위가 새는 문제 회피 —
            // es2015_for_of.zig 와 동일 전략).
            const wrapper_list = try self.ast.addNodeList(&.{ outer_var, try_stmt });
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = wrapper_list },
            });
        }

        // ================================================================
        // 헬퍼
        // ================================================================

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

        /// for-await 의 left (variable_declaration 또는 expression) → `<left> = _step.value;` 문장.
        ///
        /// variable_declaration:
        ///   var v = _step.value;
        ///   (const/let 도 var 로 강등 — ES2015 미만 block-scoping 미지원 타겟에서도 안전.
        ///    TDZ 의미는 잃지만, 실전 코드에서 for-await head 가 TDZ 를 기대하는 경우는 없음.)
        ///
        /// expression:
        ///   (left) = _step.value;
        ///
        /// 현재는 head binding 이 단순 identifier 인 경우만 완전 지원.
        /// destructuring pattern (`for await (const [k, v] of iter)`) 은 binding identifier 를
        /// 그대로 body 로 옮기므로 ES2015 destructuring 미지원 타겟에서는 후속 destructuring
        /// lowering 이 필요하다. (#1383)
        fn buildLoopVarAssign(self: *Transformer, left: NodeIndex, elem: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            if (left.isNone()) {
                // for await (;;) 은 문법적으로 불가하지만 방어.
                return es_helpers.makeExprStmt(self, elem, span);
            }
            const left_node = self.ast.getNode(left);

            if (left_node.tag == .variable_declaration) {
                const le = left_node.data.extra;
                const list_start = self.readU32(le, 1);
                const list_len = self.readU32(le, 2);
                if (list_len == 0) return es_helpers.makeExprStmt(self, elem, span);

                const first_decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list_start]);
                const first_decl = self.ast.getNode(first_decl_idx);
                if (first_decl.tag != .variable_declarator) return es_helpers.makeExprStmt(self, elem, span);

                const binding_idx: NodeIndex = self.readNodeIdx(first_decl.data.extra, 0);
                if (binding_idx.isNone()) return es_helpers.makeExprStmt(self, elem, span);
                const binding_node = self.ast.getNode(binding_idx);

                if (binding_node.tag == .array_pattern or binding_node.tag == .object_pattern) {
                    // Destructuring — 임시 변수 + element/prop 접근 declarator로 전개
                    // (`var [a, b] = _step.value` 는 ES5에서 문법 오류)
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
                return es_helpers.makeExprStmt(self, assign, span);
            }
        }
    };
}

test "ES2018 for-await module compiles" {
    _ = ES2018ForAwait;
}
