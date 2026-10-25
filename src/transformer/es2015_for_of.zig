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
const ast_walk = @import("../parser/ast_walk.zig");
const std = @import("std");
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const es2015_block_scoping = @import("es2015_block_scoping.zig");
const es2015_scan = @import("es2015_generator/scan.zig");

pub fn ES2015ForOf(comptime Transformer: type) type {
    return struct {
        /// for (const x of iterable) { body }
        /// → iterator protocol (try-catch-finally 포함)
        pub fn lowerForOfStatement(self: *Transformer, source_idx: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            return lowerForOfStatementLabeled(self, source_idx, node, .none);
        }

        /// `label_name_idx`가 주어지면 lowered inner `for_statement`에 label을 부여해
        /// `continue <label>` / `break <label>` 가 iteration statement를 타겟으로 하게 한다.
        /// 미지정(.none)이면 일반 for-of 경로.
        pub fn lowerForOfStatementLabeled(self: *Transformer, source_idx: NodeIndex, node: Node, label_name_idx: NodeIndex) Transformer.Error!NodeIndex {
            return self.visitNode(try rewriteForOf(self, source_idx, node, label_name_idx, false));
        }

        // Pattern defaults are not expression children of the generator's
        // general scanner. Walk the binding head while preserving function
        // boundaries; computed member keys still run in the outer generator.
        fn bindingHeadSuspends(self: *Transformer, root: NodeIndex) bool {
            var pending: std.ArrayList(NodeIndex) = .empty;
            defer pending.deinit(self.allocator);
            pending.append(self.allocator, root) catch return true;
            while (pending.pop()) |idx| {
                if (idx.isNone()) continue;
                const node = self.ast.getNode(idx);
                switch (node.tag) {
                    .yield_expression, .await_expression => return true,
                    .function_declaration, .function_expression, .function, .arrow_function_expression => continue,
                    .method_definition, .property_definition, .accessor_property => {
                        pending.append(self.allocator, self.readNodeIdx(node.data.extra, 0)) catch return true;
                    },
                    else => {
                        var children = ast_walk.children(self.ast, node);
                        while (children.next()) |child| pending.append(self.allocator, child) catch return true;
                    },
                }
            }
            return false;
        }

        /// for-of 를 **방문 없이** 반복자 for 루프로 풀어 쓴다 — 일반 경로와 상태 기계가 같은
        /// 풀이를 쓴다(#4746 1단계). 결과를 방문(일반)하거나 수집(상태 기계)하면 된다.
        ///
        /// ```js
        /// {
        ///   var _a = true, _b = false, _c = void 0;   // 정상 완료 · 에러 여부 · 에러 값
        ///   try {
        ///     for (var _d = __values(iterable), _e; !(_a = (_e = _d.next()).done); _a = true) {
        ///       <let x = _e.value>;  body
        ///     }
        ///   } catch (_f) { _b = true; _c = _f; }
        ///   finally { try { if (!_a && _d.return != null) _d.return(); } finally { if (_b) throw _c; } }
        /// }
        /// ```
        ///
        /// - `_a` 는 iterator 를 만들기 **전**과 매 `next()` **전**에 참이다 — `__values` 나 `next()`
        ///   가 던지면 닫지 않는다(스펙 IteratorClose). 본문 도중 빠져나가면 거짓이라 닫는다.
        /// - 본문이 throw 로 빠지면 `return()` 의 에러보다 원래 에러가 이긴다(catch 로 기억).
        /// - 루프 변수는 **본문 첫 문장의 원래 종류 선언**이 된다. 반복별 바인딩은 본문 선언
        ///   캡처 추출(#4743)이 맡는다.
        /// - `__values` 는 `Symbol` 이 없는 엔진에서도 배열·유사 배열을 돈다.
        /// - `register_sm_temps`: 상태 기계는 var 선언을 대입으로 바꾸므로 임시 변수를 wrapper
        ///   최상단에 선언하도록 등록한다. catch 매개변수는 catch 자체의 lexical scope에 묶는다.
        pub fn rewriteForOf(self: *Transformer, source_idx: NodeIndex, node: Node, label_name_idx: NodeIndex, register_sm_temps: bool) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a;
            const right = node.data.ternary.b;
            const body = node.data.ternary.c;
            // A suspension-free labeled loop stays inside one state callback.
            // Its iterator and step declarations remain in that native loop;
            // wrapper clones would introduce a second binding for the same ID.
            const native_state_loop = self.semantic_edit_enabled and register_sm_temps and
                !es2015_scan.hasYieldOrReturn(self, body) and
                !bindingHeadSuspends(self, left) and
                !es2015_scan.containsYield(self, right);
            const norm = try es_helpers.makeTempVarSpan(self); // _a
            const norm_counter = self.temp_var_counter - 1;
            const did_err = try es_helpers.makeTempVarSpan(self); // _b
            const did_counter = self.temp_var_counter - 1;
            const err_val = try es_helpers.makeTempVarSpan(self); // _c
            const err_counter = self.temp_var_counter - 1;
            const iter = try es_helpers.makeTempVarSpan(self); // _d
            const iter_counter = self.temp_var_counter - 1;
            // Labeled for-of lowering enters here without visitNode(source_idx),
            // so the traversal cursor can still be the enclosing scope.
            const loop_scope = if (self.semantic_edit_enabled and !register_sm_temps and self.pending_loop_extraction_depth == 0)
                self.outputOwnedScope(source_idx) orelse std.debug.panic("missing for-of source scope", .{})
            else if (self.semantic_edit_enabled and register_sm_temps and !self.generator_operation_scope.isNone())
                self.generator_operation_scope
            else
                self.current_scope;
            const stable_scope = self.semantic_edit_enabled and !register_sm_temps and self.pending_loop_extraction_depth == 0;
            const outer_scope = if (stable_scope) self.outputScopeParent(loop_scope) else self.current_scope;
            const generated_temp_scope = if (self.semantic_edit_enabled and register_sm_temps)
                self.generator_state_machine_scope
            else
                loop_scope;
            // The iterator step is read from the body, including by an extracted
            // `_loop` function. Only standalone paths with a stable exact owner
            // can defer its output spelling until all symbols are known.
            const late_step_output_name = stable_scope and es_helpers.canUseLateStandaloneOutputName(self, loop_scope);
            const step = try uniqueStepName(self, loop_scope, late_step_output_name);
            // var _a = true; var _b = false; var _c = void 0;
            const norm_binding = try es_helpers.makeSyntheticBinding(self, norm);
            const norm_symbol = if (stable_scope) blk: {
                const symbol = try self.declareSyntheticInScope(norm_binding, span, .variable_var, outer_scope);
                es_helpers.markStandaloneLateSyntheticTemp(self, symbol, outer_scope);
                break :blk symbol;
            } else if (register_sm_temps)
                try self.declareSyntheticTempInScope(norm_binding, span, generated_temp_scope)
            else if (self.pending_loop_extraction_depth != 0)
                try self.declareSyntheticTempInScope(norm_binding, span, loop_scope)
            else
                null;
            if (register_sm_temps) try @import("es2015_generator.zig").ES2015Generator(Transformer).appendGeneratorTempSpanWithIdentity(
                self,
                norm,
                norm_symbol,
                generated_temp_scope,
            );
            const norm_decl = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, norm_binding, try es_helpers.makeBoolLiteral(self, true), span),
            }, .@"var", span);
            const did_binding = try es_helpers.makeSyntheticBinding(self, did_err);
            const did_symbol = if (stable_scope) blk: {
                const symbol = try self.declareSyntheticInScope(did_binding, span, .variable_var, outer_scope);
                es_helpers.markStandaloneLateSyntheticTemp(self, symbol, outer_scope);
                break :blk symbol;
            } else if (register_sm_temps)
                try self.declareSyntheticTempInScope(did_binding, span, generated_temp_scope)
            else if (self.pending_loop_extraction_depth != 0)
                try self.declareSyntheticTempInScope(did_binding, span, loop_scope)
            else
                null;
            if (register_sm_temps) try @import("es2015_generator.zig").ES2015Generator(Transformer).appendGeneratorTempSpanWithIdentity(
                self,
                did_err,
                did_symbol,
                generated_temp_scope,
            );
            const did_decl = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, did_binding, try es_helpers.makeBoolLiteral(self, false), span),
            }, .@"var", span);
            const err_binding = try es_helpers.makeSyntheticBinding(self, err_val);
            const err_symbol = if (stable_scope) blk: {
                const symbol = try self.declareSyntheticInScope(err_binding, span, .variable_var, outer_scope);
                es_helpers.markStandaloneLateSyntheticTemp(self, symbol, outer_scope);
                break :blk symbol;
            } else if (register_sm_temps)
                try self.declareSyntheticTempInScope(err_binding, span, generated_temp_scope)
            else if (self.pending_loop_extraction_depth != 0)
                try self.declareSyntheticTempInScope(err_binding, span, loop_scope)
            else
                null;
            if (register_sm_temps) try @import("es2015_generator.zig").ES2015Generator(Transformer).appendGeneratorTempSpanWithIdentity(
                self,
                err_val,
                err_symbol,
                generated_temp_scope,
            );
            const err_decl = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, err_binding, try es_helpers.makeVoidZero(self, span), span),
            }, .@"var", span);

            // init: var _d = __values(iterable), _e
            self.runtime_helpers.values = true;
            const values_call = try es_helpers.makeCallExpr(self, try es_helpers.makeRuntimeHelperRef(self, "__values"), &.{right}, span);
            const iter_binding = try es_helpers.makeSyntheticBinding(self, iter);
            // State-machine collection and a pending `_loop` extraction can move
            // this var into a generated function after this AST is built.
            const iter_symbol = if (register_sm_temps)
                try self.declareSyntheticTempInScope(iter_binding, span, generated_temp_scope)
            else if (self.pending_loop_extraction_depth != 0)
                try self.declareSyntheticTempInScope(iter_binding, span, loop_scope)
            else if (stable_scope) blk: {
                const symbol = try self.declareSyntheticInScope(iter_binding, span, .variable_var, loop_scope);
                es_helpers.markStandaloneLateSyntheticTemp(self, symbol, loop_scope);
                break :blk symbol;
            } else try self.declareSyntheticInScope(iter_binding, span, .variable_var, loop_scope);
            if (register_sm_temps and !native_state_loop) try @import("es2015_generator.zig").ES2015Generator(Transformer).appendGeneratorTempSpanWithIdentity(
                self,
                iter,
                iter_symbol,
                generated_temp_scope,
            );
            if (native_state_loop) {
                const producer_id = self.temp_producer_id_by_counter.get(iter_counter) orelse
                    std.debug.panic("native generator iterator lost its allocator producer", .{});
                es_helpers.consumeTempVarProducer(self, producer_id, iter);
            }
            const step_binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, step);
            const step_symbol = if (register_sm_temps)
                try self.declareSyntheticTempInScope(step_binding, span, generated_temp_scope)
            else if (self.pending_loop_extraction_depth != 0)
                try self.declareSyntheticTempInScope(step_binding, span, loop_scope)
            else
                try self.declareSyntheticInScope(step_binding, span, .variable_var, loop_scope);
            if (self.pending_loop_extraction_depth != 0 and !register_sm_temps and self.semantic_edit_enabled) {
                try recordPendingLoopTempSymbol(self, norm_counter, norm_symbol);
                try recordPendingLoopTempSymbol(self, did_counter, did_symbol);
                try recordPendingLoopTempSymbol(self, err_counter, err_symbol);
                try recordPendingLoopTempSymbol(self, iter_counter, iter_symbol);
            }
            if (late_step_output_name) {
                const symbol = step_symbol orelse std.debug.panic("late-named for-of step has no exact SymbolId", .{});
                es_helpers.markStandaloneLateSyntheticOutputName(self, symbol, self.ast.getText(step), .for_of_step_binding, "_step");
            }
            if (register_sm_temps and !native_state_loop) try @import("es2015_generator.zig").ES2015Generator(Transformer).appendGeneratorTempSpanWithIdentity(
                self,
                step,
                step_symbol,
                generated_temp_scope,
            );
            const for_init = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, iter_binding, values_call, span),
                try es_helpers.makeDeclarator(self, step_binding, .none, span),
            }, .@"var", span);

            // test: !(_a = (_e = _d.next()).done)
            const next_call = try es_helpers.makeCallExpr(self, try es_helpers.makeStaticMember(self, try makeIteratorRef(self, iter, iter_symbol, loop_scope), try es_helpers.makePropertyName(self, "next"), span), &.{}, span);
            const step_assign = try makeAssign(self, try makeForOfRef(self, step, step_symbol, loop_scope, .{ .write = true }), next_call, span);
            const done = try es_helpers.makeStaticMember(self, step_assign, try es_helpers.makePropertyName(self, "done"), span);
            const for_test = try es_helpers.makeUnaryNot(self, try makeAssign(self, try makeForOfRef(self, norm, norm_symbol, loop_scope, .{ .write = true }), done, span), span);

            // update: _a = true
            const for_update = try makeAssign(self, try makeForOfRef(self, norm, norm_symbol, loop_scope, .{ .write = true }), try es_helpers.makeBoolLiteral(self, true), span);

            // body: <루프 변수 = _e.value>; body
            const for_body = try createLoopBody(self, loop_scope, span);
            const body_scope = self.outputOwnedScope(for_body) orelse loop_scope;
            const value = try es_helpers.makeStaticMember(self, try makeForOfRef(self, step, step_symbol, body_scope, .{ .read = true }), try es_helpers.makePropertyName(self, "value"), span);
            _ = try buildLoopBody(self, left, value, body, span, loop_scope, for_body);

            const for_stmt = try self.addExtraNode(.for_statement, span, &.{
                @backingInt(for_init), @backingInt(for_test), @backingInt(for_update), @backingInt(for_body),
            });
            // This iterator loop is the source for-of's lexical boundary. Its
            // synthetic try/block wrappers do not introduce source scopes.
            // Keep the exact source owner before visiting the rewritten tree;
            // then copied iterator loops can carry that same ScopeId onward.
            try self.remapCopiedScopeOwner(source_idx, for_stmt);
            const loop_stmt = if (label_name_idx.isNone()) for_stmt else try self.ast.addNode(.{
                .tag = .labeled_statement,
                .span = span,
                .data = .{ .binary = .{ .left = label_name_idx, .right = for_stmt, .flags = 0 } },
            });

            // The generated catch body contains no source statements, so its
            // parameter can use the stable base spelling even when an outer
            // scope has `_err`; both generated nodes receive the catch SID.
            const did_catch_write = try makeRefFromSpan(self, did_err);
            const err_catch_write = try makeRefFromSpan(self, err_val);
            const catch_binding = try es_helpers.makeExactSyntheticBinding(self, "_err");
            const catch_param_read = try es_helpers.makeExactSyntheticRef(self, "_err");
            const catch_body = try makeBlock(self, &.{
                try es_helpers.makeExprStmt(self, try makeAssign(self, did_catch_write, try es_helpers.makeBoolLiteral(self, true), span), span),
                try es_helpers.makeExprStmt(self, try makeAssign(self, err_catch_write, catch_param_read, span), span),
            }, span);
            const catch_clause = try self.ast.addNode(.{ .tag = .catch_clause, .span = span, .data = .{ .binary = .{
                .left = catch_binding,
                .right = catch_body,
                .flags = 0,
            } } });
            if (self.semantic_edit_enabled) {
                const catch_scope = try self.addGeneratedCatchScope(outer_scope, catch_clause);
                const catch_symbol = (try self.declareSyntheticInScope(catch_binding, span, .catch_binding, catch_scope)) orelse
                    std.debug.panic("generated for-of catch binding has no SymbolId", .{});
                try self.addSyntheticRefInScope(catch_param_read, catch_symbol, catch_scope, .{ .read = true });
                if (stable_scope or register_sm_temps or self.pending_loop_extraction_depth != 0) {
                    try self.addSyntheticRefInScope(did_catch_write, did_symbol orelse std.debug.panic("for-of error flag has no SymbolId", .{}), catch_scope, .{ .write = true });
                    try self.addSyntheticRefInScope(err_catch_write, err_symbol orelse std.debug.panic("for-of error value has no SymbolId", .{}), catch_scope, .{ .write = true });
                }

                if (stable_scope) {
                    // These names already have explicit bindings in the lowered
                    // loop/catch. The generic function temp hoister would add
                    // duplicate `var` bindings outside the catch scope, where
                    // they have no matching semantic identity.
                    for ([_]Span{ norm, did_err, err_val, iter }) |temp_span| {
                        es_helpers.consumeTempVarSpan(self, temp_span);
                    }
                }
            }

            // finally { try { if (!_a && _d.return != null) _d.return(); } finally { if (_b) throw _c; } }
            // The finally wrapper is outside the source for-of lexical scope.
            const ret_member = try es_helpers.makeStaticMember(self, try makeIteratorRef(self, iter, iter_symbol, outer_scope), try es_helpers.makePropertyName(self, "return"), span);
            const close_cond = try self.ast.addNode(.{ .tag = .logical_expression, .span = span, .data = .{ .binary = .{
                .left = try es_helpers.makeUnaryNot(self, try makeForOfRef(self, norm, norm_symbol, outer_scope, .{ .read = true }), span),
                .right = try es_helpers.makeNeqNull(self, ret_member, span),
                .flags = @backingInt(token_mod.Kind.amp2),
            } } });
            const close_call = try es_helpers.makeCallExpr(self, try es_helpers.makeStaticMember(self, try makeIteratorRef(self, iter, iter_symbol, outer_scope), try es_helpers.makePropertyName(self, "return"), span), &.{}, span);
            const close_if = try self.ast.addNode(.{ .tag = .if_statement, .span = span, .data = .{ .ternary = .{
                .a = close_cond,
                .b = try es_helpers.makeExprStmt(self, close_call, span),
                .c = .none,
            } } });
            const rethrow = try self.ast.addNode(.{ .tag = .throw_statement, .span = span, .data = .{ .unary = .{ .operand = try makeForOfRef(self, err_val, err_symbol, outer_scope, .{ .read = true }), .flags = 0 } } });
            const rethrow_if = try self.ast.addNode(.{ .tag = .if_statement, .span = span, .data = .{ .ternary = .{
                .a = try makeForOfRef(self, did_err, did_symbol, outer_scope, .{ .read = true }),
                .b = rethrow,
                .c = .none,
            } } });
            const inner_try = try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{
                .a = try makeBlock(self, &.{close_if}, span),
                .b = .none,
                .c = try makeBlock(self, &.{rethrow_if}, span),
            } } });

            const try_stmt = try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{
                .a = try makeBlock(self, &.{loop_stmt}, span),
                .b = catch_clause,
                .c = try makeBlock(self, &.{inner_try}, span),
            } } });

            // 블록으로 감싼 단일 노드 — pending_nodes 를 쓰면 중첩 for-of 에서 안쪽이 바깥
            // 본문 밖으로 빠져나간다.
            return makeBlock(self, &.{ norm_decl, did_decl, err_decl, try_stmt }, span);
        }

        /// 상태 기계용 for-in 풀이 (#4746 2단계). 방문 없이 AST 만 재구성하고, 상태 기계가 결과를
        /// 수집한다(일반 경로의 for-in 은 ES1 문법이라 native 로 남는다).
        ///
        /// ```js
        /// {
        ///   var _obj = object, _keys = [], _k;
        ///   for (_k in _obj) _keys.push(_k);          // own + 상속 enumerable 키 스냅샷
        ///   for (var _idx = 0; _idx < _keys.length; _idx++) { <let x = _keys[_idx]>; body }
        /// }
        /// ```
        ///
        /// - 키 수집은 yield 없는 native for-in — `Object.keys` 는 own 만 보고 `Object` 가 가려지면
        ///   깨진다. 대상 객체를 먼저 `_obj` 에 담아 그 식의 `yield` 는 선언 수집이 처리한다.
        /// - `_keys`·`_idx` 는 본문(루프 변수 선언)에서 읽으므로 모듈 고유 이름을 쓴다(for-of 의
        ///   step 과 같은 이유 — 본문이 `_loop` 로 추출되면 함수 경계 너머 참조가 된다).
        /// - 상태 기계 전용이라 임시 변수를 wrapper 최상단에 선언하도록 항상 등록한다(초기값 없는
        ///   `_k` 는 선언 수집이 등록하지 않는다 — 빠지면 strict 모드에서 ReferenceError).
        /// - 라벨은 받지 않는다: 라벨 붙은 for-in 은 `collectLabeledOperations` 가 원래 노드로 루프
        ///   여부를 판정하고, 풀이 결과 안쪽 for 의 증가 지점을 `continue` 대상으로 쓴다.
        pub fn rewriteForIn(self: *Transformer, source_idx: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a;
            const right = node.data.ternary.b;
            const body = node.data.ternary.c;
            const loop_scope: @import("../semantic/scope.zig").ScopeId = if (self.semantic_edit_enabled)
                @fromBackingInt(@intCast(self.scope_owner_map.get(@backingInt(source_idx)) orelse @backingInt(self.current_scope)))
            else
                self.current_scope;

            const obj = try es_helpers.makeTempVarSpan(self);
            const key = try es_helpers.makeTempVarSpan(self);
            const names = try uniqueForInNames(self);
            // State-machine collection hoists these `var` bindings into the
            // generated wrapper. Carry each exact name and SymbolId together
            // so references below never recover identity from a name-span
            // lookup after collection.
            const temp_owner_scope = if (self.generator_state_machine_scope.isNone()) loop_scope else self.generator_state_machine_scope;
            const temp_scope: ?ScopeId = if (self.semantic_edit_enabled)
                self.nearestVarScope(temp_owner_scope)
            else
                null;
            const obj_binding = try self.createSyntheticTempBinding(obj, span, temp_scope);
            const keys_binding = try self.createSyntheticTempBinding(names.keys, span, temp_scope);
            const key_binding = try self.createSyntheticTempBinding(key, span, temp_scope);
            const idx_binding = try self.createSyntheticTempBinding(names.idx, span, temp_scope);
            const generator = @import("es2015_generator.zig").ES2015Generator(Transformer);
            const identity_owner = temp_scope orelse .none;
            try generator.appendGeneratorTempSpanWithIdentity(self, obj_binding.name_span, obj_binding.symbol_id, identity_owner);
            try generator.appendGeneratorTempSpanWithIdentity(self, keys_binding.name_span, keys_binding.symbol_id, identity_owner);
            try generator.appendGeneratorTempSpanWithIdentity(self, key_binding.name_span, key_binding.symbol_id, identity_owner);
            try generator.appendGeneratorTempSpanWithIdentity(self, idx_binding.name_span, idx_binding.symbol_id, identity_owner);

            // var _obj = object, _keys = [], _k;
            const empty = try self.ast.addListNode(.array_expression, span, .{ .start = 0, .len = 0 });
            const decl = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, obj_binding.node, right, span),
                try es_helpers.makeDeclarator(self, keys_binding.node, empty, span),
                try es_helpers.makeDeclarator(self, key_binding.node, .none, span),
            }, .@"var", span);

            // for (_k in _obj) _keys.push(_k);
            const push = try es_helpers.makeCallExpr(self, try es_helpers.makeStaticMember(self, try makeRefForSyntheticBinding(self, keys_binding, loop_scope, .{ .read = true }), try es_helpers.makePropertyName(self, "push"), span), &.{try makeRefForSyntheticBinding(self, key_binding, loop_scope, .{ .read = true })}, span);
            const collect = try self.ast.addNode(.{ .tag = .for_in_statement, .span = span, .data = .{ .ternary = .{
                .a = try makeRefForSyntheticBinding(self, key_binding, loop_scope, .{ .write = true }),
                .b = try makeRefForSyntheticBinding(self, obj_binding, loop_scope, .{ .read = true }),
                .c = try es_helpers.makeExprStmt(self, push, span),
            } } });

            // for (var _idx = 0; _idx < _keys.length; _idx++) { <루프 변수 = _keys[_idx]>; body }
            const init = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, idx_binding.node, try es_helpers.makeNumericLiteral(self, 0), span),
            }, .@"var", span);
            const length = try es_helpers.makeStaticMember(self, try makeRefForSyntheticBinding(self, keys_binding, loop_scope, .{ .read = true }), try es_helpers.makePropertyName(self, "length"), span);
            const test_expr = try self.ast.addNode(.{ .tag = .binary_expression, .span = span, .data = .{ .binary = .{
                .left = try makeRefForSyntheticBinding(self, idx_binding, loop_scope, .{ .read = true }),
                .right = length,
                .flags = @backingInt(token_mod.Kind.l_angle),
            } } });
            const update = try self.ast.addNode(.{ .tag = .update_expression, .span = span, .data = .{ .extra = try self.ast.addExtras(&.{
                @backingInt(try makeRefForSyntheticBinding(self, idx_binding, loop_scope, .{ .read = true, .write = true })),
                @backingInt(token_mod.Kind.plus2) | ast_mod.UnaryFlags.postfix,
            }) } });
            const for_body = try createLoopBody(self, loop_scope, span);
            const body_scope = self.outputOwnedScope(for_body) orelse loop_scope;
            const value = try es_helpers.makeComputedMember(self, try makeLoopBodyTempRead(self, keys_binding, body_scope), try makeLoopBodyTempRead(self, idx_binding, body_scope), span);
            const for_stmt = try self.addExtraNode(.for_statement, span, &.{
                @backingInt(init), @backingInt(test_expr), @backingInt(update), @backingInt(try buildLoopBody(self, left, value, body, span, loop_scope, for_body)),
            });
            try self.remapCopiedScopeOwner(source_idx, for_stmt);
            return makeBlock(self, &.{ decl, collect, for_stmt }, span);
        }

        fn uniqueForInNames(self: *Transformer) Transformer.Error!struct { keys: Span, idx: Span } {
            while (true) {
                self.forin_counter += 1;
                const n = self.forin_counter;
                var kb: [32]u8 = undefined;
                var ib: [32]u8 = undefined;
                const k = if (n == 1) "_keys" else std.fmt.bufPrint(&kb, "_keys{d}", .{n}) catch unreachable;
                const i = if (n == 1) "_idx" else std.fmt.bufPrint(&ib, "_idx{d}", .{n}) catch unreachable;
                const key_in_source = try es_helpers.nameAppearsInSource(self, k);
                const index_in_source = try es_helpers.nameAppearsInSource(self, i);
                const key_visible_to_eval = if (self.current_scope.isNone())
                    try es_helpers.nameAppearsInAnyDynamicEvalString(self, k)
                else
                    try es_helpers.nameAppearsInDynamicEvalString(self, self.current_scope, k);
                const index_visible_to_eval = if (self.current_scope.isNone())
                    try es_helpers.nameAppearsInAnyDynamicEvalString(self, i)
                else
                    try es_helpers.nameAppearsInDynamicEvalString(self, self.current_scope, i);
                if (key_in_source or index_in_source or key_visible_to_eval or index_visible_to_eval) continue;
                return .{ .keys = try self.ast.addString(k), .idx = try self.ast.addString(i) };
            }
        }

        /// 루프 변수 대입을 앞에 둔 본문 블록. 원래 본문 블록에 루프 변수와 같은 이름의
        /// 선언이 있으면(헤더와 본문은 스코프가 다르다) 합치지 않고 한 겹 더 감싼다.
        pub fn createLoopBody(self: *Transformer, loop_scope: @import("../semantic/scope.zig").ScopeId, span: Span) Transformer.Error!NodeIndex {
            const result = try makeBlock(self, &.{}, span);
            if (self.semantic_edit_enabled) _ = try self.addGeneratedScope(loop_scope, result, .block);
            return result;
        }

        pub fn buildLoopBody(self: *Transformer, left: NodeIndex, value: NodeIndex, body: NodeIndex, span: Span, loop_scope: @import("../semantic/scope.zig").ScopeId, result: NodeIndex) Transformer.Error!NodeIndex {
            const body_scope = if (self.semantic_edit_enabled)
                self.outputOwnedScope(result) orelse std.debug.panic("loop body lost its planned scope", .{})
            else
                loop_scope;
            if (self.semantic_edit_enabled) try validateLoopValueScope(self, value, body_scope);
            const left_node = self.ast.getNode(left);
            const head_stmt = if (left_node.tag == .variable_declaration) blk: {
                const d = self.ast.getNode(@fromBackingInt(@intCast(self.ast.extra_data.items[self.readU32(left_node.data.extra, 1)])));
                const binding = self.readNodeIdx(d.data.extra, 0);
                break :blk try es_helpers.makeVarDeclaration(self, &.{
                    try es_helpers.makeDeclarator(self, binding, value, span),
                }, self.ast.variableDeclarationKind(left_node), span);
            } else try es_helpers.makeExprStmt(self, try makeAssign(self, left, value, span), span);
            // Keep the original block as an actual child: flattening its statements
            // discards the node which owns the source lexical environment.
            self.ast.nodes.items[@backingInt(result)].data.list = try self.ast.addNodeList(if (body.isNone()) &.{head_stmt} else &.{ head_stmt, body });
            if (self.semantic_edit_enabled) {
                try self.reparentGeneratedBodyScopes(loop_scope, body_scope, body);
                try self.reparentGeneratedBodyScopes(loop_scope, body_scope, head_stmt);
                try moveLoopHead(self, head_stmt, loop_scope, body_scope);
                if (!body.isNone() and self.outputOwnedScope(body) == null)
                    try moveLoopHead(self, body, loop_scope, body_scope);
            }
            return result;
        }

        fn validateLoopValueScope(self: *Transformer, value: NodeIndex, target: @import("../semantic/scope.zig").ScopeId) Transformer.Error!void {
            const refs = try @import("../semantic/reference_walk.zig").collectIdentifierReferences(self.allocator, self.ast, value);
            defer self.allocator.free(refs);
            for (refs) |node| {
                const id = self.getSymbolIdAt(node) orelse std.debug.panic("loop value has no creation SymbolId", .{});
                const maybe = self.semantic_editor.?.referenceForNode(node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("loop value has an invalid creation reference: {s}", .{@errorName(err)}),
                };
                const actual = maybe orelse std.debug.panic("loop value has no creation reference", .{});
                if (actual.scope_id != target or @backingInt(actual.symbol_id) != id)
                    std.debug.panic("loop value reference lost its planned creation identity or scope", .{});
            }
        }

        fn moveLoopHead(self: *Transformer, root: NodeIndex, source: @import("../semantic/scope.zig").ScopeId, target: @import("../semantic/scope.zig").ScopeId) Transformer.Error!void {
            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            try stack.append(self.allocator, root);
            while (stack.pop()) |idx| {
                if (idx.isNone()) continue;
                const node = self.ast.getNode(idx);
                const editor = &self.semantic_editor.?;
                if (node.tag == .binding_identifier) {
                    if (self.getSymbolIdAt(idx)) |sid| {
                        const symbol = editor.symbols.items[sid];
                        if (symbol.scope_id == source and (symbol.kind == .variable_let or symbol.kind == .variable_const))
                            try self.relocateOutputSymbolAs(sid, target, idx);
                    }
                }
                const maybe_ref = editor.referenceForNode(idx) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("loop head lost reference: {s}", .{@errorName(err)}),
                };
                if (maybe_ref) |reference| {
                    if (!reference.flags.declare and reference.scope_id == source) {
                        if (self.tracked_runtime_helper_ref_index.contains(@backingInt(idx)))
                            try self.relocateRuntimeHelperRef(idx, target)
                        else
                            editor.moveReference(idx, target, reference.stmt_idx, reference.scope_stmt_idx) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => std.debug.panic("loop head cannot move reference: {s}", .{@errorName(err)}),
                            };
                    }
                }
                var children = @import("../parser/ast_walk.zig").children(self.ast, node);
                while (children.next()) |child| try stack.append(self.allocator, child);
            }
        }

        pub fn uniqueStepName(self: *Transformer, scope: @import("../semantic/scope.zig").ScopeId, late_output_name: bool) Transformer.Error!Span {
            const prefix = if (late_output_name) "__zntc_step" else "_step";
            while (true) {
                const name = if (late_output_name)
                    try self.buildUniqueName(prefix, &self.forof_step_counter)
                else
                    try self.buildUniqueNameAvoidingDynamicEval(prefix, &self.forof_step_counter, scope);
                if (try es_helpers.nameAppearsInSource(self, name)) continue;
                const span = try self.ast.addString(name);
                try self.generated_temp_spans.append(self.allocator, span);
                return span;
            }
        }

        fn makeAssign(self: *Transformer, target: NodeIndex, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{ .left = target, .right = value, .flags = @backingInt(token_mod.Kind.eq) } } });
        }

        fn makeBlock(self: *Transformer, stmts: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(stmts) } });
        }

        // ================================================================
        // 헬퍼
        // ================================================================

        /// reference 의 `node.span` 은 `name_span` 사용 (binding 과 동일한 정책).
        /// #4218 이후 analyzer 는 `ast.identifierNameText`(string_ref 정본)로
        /// 이름을 읽으므로 span 분리도 동작은 하지만, 여기는 합성 전용 이름이라
        /// 원본 위치 매핑 가치가 없어 단순한 동일-span 정책을 유지한다. (구 사유:
        /// `getSourceText(node.span)` 이 원본 텍스트를 읽어 매칭 실패 → mangler 의
        /// cross-module rename 이 declaration 에만 적용되는 비대칭이 발생한다.
        fn makeRefFromSpan(self: *Transformer, name_span: Span) Transformer.Error!NodeIndex {
            return es_helpers.makeExactSyntheticRefFromSpan(self, name_span);
        }

        fn makeLoopBodyTempRead(self: *Transformer, binding: Transformer.SyntheticBinding, scope: ScopeId) Transformer.Error!NodeIndex {
            const ref = try es_helpers.makeExactSyntheticRefFromSpan(self, binding.name_span);
            if (self.semantic_edit_enabled) {
                const symbol = binding.symbol_id orelse std.debug.panic("loop body temp has no creation identity", .{});
                try self.addSyntheticRefInScope(ref, symbol, scope, .{ .read = true });
                if (self.state_machine_depth > 0) try self.trackExactOutputReference(ref, @backingInt(symbol));
            }
            return ref;
        }

        fn makeRefForSyntheticBinding(self: *Transformer, binding: Transformer.SyntheticBinding, scope: ScopeId, flags: @import("../semantic/symbol.zig").ReferenceFlags) Transformer.Error!NodeIndex {
            const ref = try es_helpers.makeExactSyntheticRefFromSpan(self, binding.name_span);
            if (self.semantic_edit_enabled) {
                const symbol_id = binding.symbol_id orelse std.debug.panic("for-in temp reference has no exact SymbolId", .{});
                if (self.state_machine_depth > 0) {
                    // Generator operation collection runs before the callback's
                    // output scopes are attached. Preserve the producer-chosen
                    // identity now; finishSemanticEdit will register its exact
                    // reference and access mode from the emitted AST ancestry.
                    try self.trackExactOutputReference(ref, @backingInt(symbol_id));
                } else {
                    try self.addSyntheticRefInScope(ref, symbol_id, scope, flags);
                }
            }
            return ref;
        }

        fn makeIteratorRef(self: *Transformer, name_span: Span, symbol: ?SymbolId, scope: @import("../semantic/scope.zig").ScopeId) Transformer.Error!NodeIndex {
            return makeForOfRef(self, name_span, symbol, scope, .{ .read = true });
        }

        fn makeForOfRef(self: *Transformer, name_span: Span, symbol: ?SymbolId, scope: @import("../semantic/scope.zig").ScopeId, flags: @import("../semantic/symbol.zig").ReferenceFlags) Transformer.Error!NodeIndex {
            const ref = try makeRefFromSpan(self, name_span);
            try self.addSyntheticRefInScope(ref, symbol, scope, flags);
            return ref;
        }

        fn recordPendingLoopTempSymbol(self: *Transformer, counter_index: u32, symbol: ?SymbolId) Transformer.Error!void {
            const id = symbol orelse std.debug.panic("pending extracted for-of temp has no exact SymbolId", .{});
            if (self.temp_symbol_ids_by_counter.get(counter_index)) |existing| {
                if (existing != @backingInt(id))
                    std.debug.panic("pending extracted for-of temp slot changed its SymbolId", .{});
                return;
            }
            try self.temp_symbol_ids_by_counter.put(self.allocator, counter_index, @backingInt(id));
        }

        fn makeVarDeclFromSpan(self: *Transformer, name_span: Span, init: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const binding = try es_helpers.makeSyntheticBinding(self, name_span);
            const declarator = try es_helpers.makeDeclarator(self, binding, init, span);
            return es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
        }
    };
}

test "ES2015 for-of module compiles" {
    _ = ES2015ForOf;
}

fn checkNativeStateLoopRegistration(source: []const u8, native: bool) !void {
    const Transformer = @import("transformer.zig").Transformer;
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    var loop: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .for_of_statement) continue;
        if (loop.isNone() or node.span.end - node.span.start > parser.ast.getNode(loop).span.end - parser.ast.getNode(loop).span.start)
            loop = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!loop.isNone());
    var transformer = try Transformer.init(alloc, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.semantic_edit_enabled = true;
    transformer.current_scope = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(loop)).?);
    transformer.state_machine_depth = 1;
    transformer.generator_state_machine_scope = transformer.nearestVarScope(transformer.current_scope);
    _ = try ES2015ForOf(Transformer).rewriteForOf(&transformer, loop, parser.ast.getNode(loop), .none, true);
    const expected_registered: usize = if (native) 3 else 5;
    try std.testing.expectEqual(expected_registered, transformer.generator_temp_producer_identities.items.len);
    try std.testing.expectEqual(expected_registered, transformer.generator_temp_var_spans.items.len);
    try std.testing.expectEqual(@as(u32, if (native) 3 else 4), transformer.temp_span_by_counter.count());
    try std.testing.expectEqual(transformer.temp_span_by_counter.count(), transformer.temp_producer_id_by_counter.count());

    var unregistered_roles: usize = 0;
    for (transformer.ast.nodes.items[transformer.parser_node_count..], transformer.parser_node_count..) |node, raw| {
        if (node.tag != .binding_identifier) continue;
        const sid = transformer.getSymbolIdAt(@fromBackingInt(@intCast(raw))) orelse return error.MissingForOfProducerIdentity;
        const editor = &transformer.semantic_editor.?;
        if (editor.symbols.items[sid].kind != .variable_var) continue;
        var registered = false;
        for (transformer.generator_temp_producer_identities.items) |identity| {
            if (identity.symbol_id == sid) {
                registered = true;
                try std.testing.expectEqual(transformer.generator_state_machine_scope, identity.owner_scope);
            }
        }
        if (registered) continue;
        unregistered_roles += 1;
        var refs: usize = 0;
        for (editor.references.items) |reference| {
            if (@backingInt(reference.symbol_id) == sid and !reference.flags.declare) refs += 1;
        }
        try std.testing.expect(refs > 0);
        var allocator_ids = transformer.temp_symbol_ids_by_counter.iterator();
        while (allocator_ids.next()) |entry| try std.testing.expect(entry.value_ptr.* != sid);
    }
    try std.testing.expectEqual(@as(usize, if (native) 2 else 0), unregistered_roles);
}

test "#4819 native state-loop iterator declarations do not clone into wrapper hoists" {
    const bodies = [_][]const u8{
        "use(value);",
        "{ if (value) continue; use(value); }",
        "{ if (value) break; }",
        "{ try { use(value); } finally { finish(); } }",
        "{ for (const inner of other) use(value, inner); }",
        "{ const read = () => value; use(read); }",
        "{ function* nested() { yield value; } use(nested); }",
        "{ function nested() { return value; } use(nested); }",
        "{ switch (value) { case 1: break; default: use(value); } }",
        "{ let copy = value; while (copy--) use(copy); }",
    };
    for (bodies) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "function* run() {{ outer: for (const value of source) {s} yield 1; }}", .{body});
        defer std.testing.allocator.free(source);
        try checkNativeStateLoopRegistration(source, true);
    }
    // Suspension and return paths still need storage across callback invocations.
    try checkNativeStateLoopRegistration("function* run() { for (const value of source) { yield value; } }", false);
    try checkNativeStateLoopRegistration("function* run() { for (const value of (yield source)) use(value); }", false);
    try checkNativeStateLoopRegistration("function* run() { for (const value of source) return value; }", false);
    try checkNativeStateLoopRegistration("function* run() { for (const [value = (yield fallback)] of source) use(value); }", false);
}
