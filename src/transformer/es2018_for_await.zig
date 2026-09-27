//! ES2018 다운레벨링: for-await-of loop
//!
//! --target < es2018 일 때 활성화.
//! Hermes / ES5는 `for await` 키워드 자체를 파싱하지 못하므로, async function body 가
//! `__async(function*() { ... })` 로 래핑되기 전에 미리 `while` 루프로 변환해야 한다.
//!
//! 입력:
//!   for await (const v of iterable) body;
//!
//! 출력 (tsc __asyncValues 스타일, #4746 3단계부터 방문 없는 AST 풀이):
//!   {
//!     var _iter = __asyncValues(iterable), _step = void 0, _ret = void 0, _err_obj = void 0;
//!     try {
//!       while (!(_step = await _iter.next()).done) {
//!         const v = _step.value;   // 원래 종류
//!         body;
//!       }
//!     } catch (_err) { _err_obj = { error: _err }; }
//!     finally {
//!       try { if (_step && !_step.done && (_ret = _iter.return)) await _ret.call(_iter); }
//!       finally { if (_err_obj) throw _err_obj.error; }
//!     }
//!   }
//!
//! 풀이는 방문하지 않는다 — 일반 경로는 결과를 방문하고(합성한 `await` 도 그때 낮아진다),
//! 상태 기계는 결과를 수집한다. async generator 는 본문 전처리 단계에서 **제자리 풀이**
//! (`lowerInPlace`)해 합성 `await` 도 사용자 await 와 함께 `yield __await(…)` 로 바뀌게 한다.
//!
//! Flow gate: `options.unsupported.needsForAwaitOfDownlevel()` (= ES2018 미지원).
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
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const ReferenceFlags = @import("../semantic/symbol.zig").ReferenceFlags;
const es_helpers = @import("es_helpers.zig");
const ast_walk = @import("../parser/ast_walk.zig");

pub fn ES2018ForAwait(comptime Transformer: type) type {
    return struct {
        const ForOf = @import("es2015_for_of.zig").ES2015ForOf(Transformer);

        /// for await (const v of iter) body; → 풀이 결과를 방문한다(일반 경로).
        pub fn lowerForAwaitOf(self: *Transformer, source_idx: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            return lowerForAwaitOfLabeled(self, source_idx, node, .none);
        }

        /// label 이 있으면 안쪽 while 에 붙인다(`continue <label>` 이 루프를 가리키게).
        pub fn lowerForAwaitOfLabeled(self: *Transformer, source_idx: NodeIndex, node: Node, label_name_idx: NodeIndex) Transformer.Error!NodeIndex {
            // Register while the original async body's lexical owners are live.
            // Extracted-wrapper and state-machine routes need their own pass
            // after their output scopes are established.
            const register_semantics = self.semantic_edit_enabled and
                !self.in_extracted_fn_body and
                !self.options.unsupported.async_await and
                !self.options.unsupported.generator;
            return self.visitNode(try rewriteForAwait(self, source_idx, node, label_name_idx, register_semantics));
        }

        /// for-await 를 **방문 없이** 반복자 while 루프로 풀어 쓴다 (#4746 3단계).
        ///
        /// - 임시 변수는 선언 때 모두 초기화한다. 같은 함수에서 루프가 다시 실행될 때 앞
        ///   실행의 `_errObj`·`_step` 이 남으면, 에러 없이 끝난 실행의 finally 가 옛 에러를
        ///   다시 던지거나 새 iterator 를 닫았다. 초기값이 있으면 상태 기계도 선언을 대입으로
        ///   바꾸며 이름을 wrapper 에 등록한다(catch 파라미터는 상태 기계가 리네임·등록).
        /// - `_step` 은 본문(루프 변수 선언)에서 읽으므로 모듈 고유 이름(for-of 와 같은 이유).
        /// - 반복자 생성은 try 밖 — 생성이 던지면 닫을 것이 없다.
        pub fn rewriteForAwait(self: *Transformer, source_idx: NodeIndex, node: Node, label_name_idx: NodeIndex, register_semantics: bool) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a;
            const right = node.data.ternary.b;
            const body = node.data.ternary.c;

            const input_loop_scope = if (register_semantics)
                self.outputOwnedScope(source_idx) orelse self.current_scope
            else
                ScopeId.none;
            const loop_scope = if (register_semantics and input_loop_scope.isNone())
                self.programScope()
            else
                input_loop_scope;
            const var_scope = if (register_semantics) variableScope(self, loop_scope) else ScopeId.none;
            const wrapper_scope = if (register_semantics) self.outputScopeParent(loop_scope) else ScopeId.none;

            self.runtime_helpers.async_values = true;

            const iter = try es_helpers.makeTempVarSpan(self);
            const step = try ForOf.uniqueStepName(self);
            const ret = try es_helpers.makeTempVarSpan(self);
            const errobj = try es_helpers.makeTempVarSpan(self);
            // A catch parameter is not a function-scoped temp. Using
            // makeTempVarSpan here also makes the hoister emit a second `var`
            // binding with the same spelling outside the catch scope.
            const err = try self.ast.addString(try es_helpers.resolveSyntheticName(self, "_err"));
            // var _iter = __asyncValues(iterable), _step = void 0, _ret = void 0, _errObj = void 0;
            const values_call = try es_helpers.makeCallExpr(self, try es_helpers.makeRuntimeHelperRef(self, "__asyncValues"), &.{right}, span);
            const iter_binding = try es_helpers.makeSyntheticBinding(self, iter);
            const iter_symbol = if (register_semantics) try self.declareSyntheticTempInScope(iter_binding, span, var_scope) else null;
            const step_binding = try es_helpers.makeSyntheticBinding(self, step);
            const step_symbol = if (register_semantics) try self.declareSyntheticTempInScope(step_binding, span, var_scope) else null;
            const ret_binding = try es_helpers.makeSyntheticBinding(self, ret);
            const ret_symbol = if (register_semantics) try self.declareSyntheticTempInScope(ret_binding, span, var_scope) else null;
            const errobj_binding = try es_helpers.makeSyntheticBinding(self, errobj);
            const errobj_symbol = if (register_semantics) try self.declareSyntheticTempInScope(errobj_binding, span, var_scope) else null;
            const decl = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, iter_binding, values_call, span),
                try es_helpers.makeDeclarator(self, step_binding, try es_helpers.makeVoidZero(self, span), span),
                try es_helpers.makeDeclarator(self, ret_binding, try es_helpers.makeVoidZero(self, span), span),
                try es_helpers.makeDeclarator(self, errobj_binding, try es_helpers.makeVoidZero(self, span), span),
            }, .@"var", span);
            // These temps are declared in `decl`; the generic temp hoister must
            // not create unbound duplicates in the program or wrapper scope.
            es_helpers.consumeTempVarSpan(self, iter);
            es_helpers.consumeTempVarSpan(self, ret);
            es_helpers.consumeTempVarSpan(self, errobj);

            // while (!(_step = await _iter.next()).done) { <루프 변수 = _step.value>; body }
            const next_call = try es_helpers.makeCallExpr(self, try es_helpers.makeStaticMember(self, try makeRef(self, iter, iter_symbol, loop_scope, .{ .read = true }, register_semantics), try es_helpers.makePropertyName(self, "next"), span), &.{}, span);
            const step_assign = try self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{
                .left = try makeRef(self, step, step_symbol, loop_scope, .{ .write = true }, register_semantics),
                .right = try es_helpers.makeAwaitExpression(self, next_call, span),
                .flags = 0,
            } } });
            const test_expr = try es_helpers.makeUnaryNot(self, try es_helpers.makeStaticMember(self, step_assign, try es_helpers.makePropertyName(self, "done"), span), span);
            const value = try es_helpers.makeStaticMember(self, try makeRef(self, step, step_symbol, loop_scope, .{ .read = true }, register_semantics), try es_helpers.makePropertyName(self, "value"), span);
            const while_stmt = try self.ast.addNode(.{ .tag = .while_statement, .span = span, .data = .{ .binary = .{
                .left = test_expr,
                .right = try ForOf.buildLoopBody(self, left, value, body, span),
                .flags = 0,
            } } });
            if (register_semantics) try self.remapCopiedScopeOwner(source_idx, while_stmt);
            const loop_stmt = if (label_name_idx.isNone()) while_stmt else try self.ast.addNode(.{
                .tag = .labeled_statement,
                .span = span,
                .data = .{ .binary = .{ .left = label_name_idx, .right = while_stmt, .flags = 0 } },
            });

            // catch (_err) { _errObj = { error: _err }; }
            const err_binding = try es_helpers.makeSyntheticBinding(self, err);
            const catch_clause = try self.ast.addNode(.{ .tag = .catch_clause, .span = span, .data = .{ .binary = .{
                .left = err_binding,
                .right = .none,
                .flags = 0,
            } } });
            const catch_scope = if (register_semantics)
                try self.addGeneratedCatchScope(wrapper_scope, catch_clause)
            else
                ScopeId.none;
            const err_symbol = if (register_semantics) try self.declareSyntheticInScope(err_binding, span, .catch_binding, catch_scope) else null;
            const err_ref = try makeRef(self, err, err_symbol, catch_scope, .{ .read = true }, register_semantics);
            const error_prop = try self.ast.addNode(.{ .tag = .object_property, .span = span, .data = .{ .binary = .{
                .left = try es_helpers.makePropertyName(self, "error"),
                .right = err_ref,
                .flags = 0,
            } } });
            const error_obj = try self.ast.addNode(.{ .tag = .object_expression, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{error_prop}) } });
            const catch_write = try makeRef(self, errobj, errobj_symbol, catch_scope, .{ .write = true }, register_semantics);
            const set_errobj = try es_helpers.makeAssignStmt(self, catch_write, error_obj, span, 0);
            const catch_body = try block(self, &.{set_errobj}, span);
            var catch_node = self.ast.getNode(catch_clause);
            catch_node.data.binary.right = catch_body;
            self.ast.nodes.items[@intFromEnum(catch_clause)] = catch_node;

            // finally { try { if (_step && !_step.done && (_ret = _iter.return)) await _ret.call(_iter); }
            //           finally { if (_errObj) throw _errObj.error; } }
            const not_done = try es_helpers.makeUnaryNot(self, try es_helpers.makeStaticMember(self, try makeRef(self, step, step_symbol, wrapper_scope, .{ .read = true }, register_semantics), try es_helpers.makePropertyName(self, "done"), span), span);
            const and1 = try logicalAnd(self, try makeRef(self, step, step_symbol, wrapper_scope, .{ .read = true }, register_semantics), not_done, span);
            const ret_assign = try self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{
                .left = try makeRef(self, ret, ret_symbol, wrapper_scope, .{ .write = true }, register_semantics),
                .right = try es_helpers.makeStaticMember(self, try makeRef(self, iter, iter_symbol, wrapper_scope, .{ .read = true }, register_semantics), try es_helpers.makePropertyName(self, "return"), span),
                .flags = 0,
            } } });
            const close_cond = try logicalAnd(self, and1, ret_assign, span);
            const close_call = try es_helpers.makeCallExpr(self, try es_helpers.makeStaticMember(self, try makeRef(self, ret, ret_symbol, wrapper_scope, .{ .read = true }, register_semantics), try es_helpers.makePropertyName(self, "call"), span), &.{try makeRef(self, iter, iter_symbol, wrapper_scope, .{ .read = true }, register_semantics)}, span);
            const close_if = try self.ast.addNode(.{ .tag = .if_statement, .span = span, .data = .{ .ternary = .{
                .a = close_cond,
                .b = try es_helpers.makeExprStmt(self, try es_helpers.makeAwaitExpression(self, close_call, span), span),
                .c = .none,
            } } });
            const rethrow = try self.ast.addNode(.{ .tag = .throw_statement, .span = span, .data = .{ .unary = .{
                .operand = try es_helpers.makeStaticMember(self, try makeRef(self, errobj, errobj_symbol, wrapper_scope, .{ .read = true }, register_semantics), try es_helpers.makePropertyName(self, "error"), span),
                .flags = 0,
            } } });
            const rethrow_if = try self.ast.addNode(.{ .tag = .if_statement, .span = span, .data = .{ .ternary = .{
                .a = try makeRef(self, errobj, errobj_symbol, wrapper_scope, .{ .read = true }, register_semantics),
                .b = try block(self, &.{rethrow}, span),
                .c = .none,
            } } });
            const inner_try = try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{
                .a = try block(self, &.{close_if}, span),
                .b = .none,
                .c = try block(self, &.{rethrow_if}, span),
            } } });
            const try_stmt = try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{
                .a = try block(self, &.{loop_stmt}, span),
                .b = catch_clause,
                .c = try block(self, &.{inner_try}, span),
            } } });
            return block(self, &.{ decl, try_stmt }, span);
        }

        fn variableScope(self: *Transformer, start: ScopeId) ScopeId {
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            var scope = start;
            var hops: usize = 0;
            while (!scope.isNone() and hops < scopes.len) : (hops += 1) {
                if (scope.toIndex() >= scopes.len) std.debug.panic("invalid for-await source scope", .{});
                if (scopes[scope.toIndex()].kind.isVarScope()) return scope;
                scope = scopes[scope.toIndex()].parent;
            }
            std.debug.panic("for-await has no enclosing var scope", .{});
        }

        fn makeRef(self: *Transformer, name_span: Span, id: ?SymbolId, scope: ScopeId, flags: ReferenceFlags, register_semantics: bool) Transformer.Error!NodeIndex {
            const node = try es_helpers.makeSyntheticRefFromSpan(self, name_span);
            if (register_semantics) try self.addSyntheticRefInScope(node, id, scope, flags);
            return node;
        }

        /// async generator 본문 전처리: 본문의 for-await(라벨 포함)를 **제자리에서** 풀이로
        /// 바꾼다. 바로 뒤의 `rewriteAwaitToYieldAwait` 가 합성 `await` 까지 `yield __await(…)`
        /// 로 바꾸게 하려는 것이다 — 풀이를 방문 때 하면 합성 await 가 평범한 `yield` 로
        /// 낮아지거나(async 를 낮추는 타겟) 상태 기계가 따로 표시해야 했다(#4707).
        /// 중첩 함수·클래스는 자기 문맥이라 들어가지 않는다.
        pub fn lowerInPlace(self: *Transformer, root: NodeIndex, register_semantics: bool) Transformer.Error!void {
            if (root.isNone()) return;
            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            var kids: std.ArrayList(NodeIndex) = .empty;
            defer kids.deinit(self.allocator);
            try stack.append(self.allocator, root);
            while (stack.pop()) |idx| {
                if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;
                var node = self.ast.getNode(idx);
                switch (node.tag) {
                    .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .class_declaration, .class_expression => continue,
                    .for_await_of_statement => {
                        _ = try @import("es2025_using.zig").ES2025Using(Transformer).normalizeForOfUsingHead(self, idx, false);
                        node = self.ast.getNode(idx);
                        const rewritten = try rewriteForAwait(self, idx, node, .none, register_semantics);
                        self.ast.nodes.items[@intFromEnum(idx)] = self.ast.getNode(rewritten);
                        if (register_semantics) try self.removeInPlaceScopeOwner(idx);
                        node = self.ast.getNode(idx);
                    },
                    .labeled_statement => {
                        const child = node.data.binary.right;
                        if (!child.isNone() and self.ast.getNode(child).tag == .for_await_of_statement) {
                            _ = try @import("es2025_using.zig").ES2025Using(Transformer).normalizeForOfUsingHead(self, child, false);
                            const rewritten = try rewriteForAwait(self, child, self.ast.getNode(child), node.data.binary.left, register_semantics);
                            self.ast.nodes.items[@intFromEnum(idx)] = self.ast.getNode(rewritten);
                            node = self.ast.getNode(idx);
                        }
                    },
                    else => {},
                }
                // 제자리 풀이 **뒤의** 노드에서 자식을 모은다(풀이 결과 안의 원래 본문으로 내려간다).
                kids.clearRetainingCapacity();
                try ast_walk.collectChildrenInto(self.ast, node, &kids, self.allocator);
                try stack.appendSlice(self.allocator, kids.items);
            }
        }

        fn logicalAnd(self: *Transformer, a: NodeIndex, b: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{ .tag = .logical_expression, .span = span, .data = .{ .binary = .{
                .left = a,
                .right = b,
                .flags = @intFromEnum(token_mod.Kind.amp2),
            } } });
        }

        fn block(self: *Transformer, stmts: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(stmts) } });
        }
    };
}

test "ES2018 for-await module compiles" {
    _ = ES2018ForAwait;
}
