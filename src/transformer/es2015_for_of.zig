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
const es2015_block_scoping = @import("es2015_block_scoping.zig");

pub fn ES2015ForOf(comptime Transformer: type) type {
    return struct {
        /// for (const x of iterable) { body }
        /// → iterator protocol (try-catch-finally 포함)
        pub fn lowerForOfStatement(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            return lowerForOfStatementLabeled(self, node, .none);
        }

        /// `label_name_idx`가 주어지면 lowered inner `for_statement`에 label을 부여해
        /// `continue <label>` / `break <label>` 가 iteration statement를 타겟으로 하게 한다.
        /// 미지정(.none)이면 일반 for-of 경로.
        pub fn lowerForOfStatementLabeled(self: *Transformer, node: Node, label_name_idx: NodeIndex) Transformer.Error!NodeIndex {
            return self.visitNode(try rewriteForOf(self, node, label_name_idx, false));
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
        ///   최상단에 선언하도록 등록한다(catch 임시 변수가 리네임되지 않게 하는 표시도 겸한다).
        pub fn rewriteForOf(self: *Transformer, node: Node, label_name_idx: NodeIndex, register_sm_temps: bool) Transformer.Error!NodeIndex {
            const span = node.span;
            const left = node.data.ternary.a;
            const right = node.data.ternary.b;
            const body = node.data.ternary.c;

            const norm = try es_helpers.makeTempVarSpan(self); // _a
            const did_err = try es_helpers.makeTempVarSpan(self); // _b
            const err_val = try es_helpers.makeTempVarSpan(self); // _c
            const iter = try es_helpers.makeTempVarSpan(self); // _d
            // step 은 본문(루프 변수 선언)에서 읽는다 — 본문이 `_loop` 함수로 추출되면 **함수 경계
            // 너머**의 참조가 된다. 카운터 temp(`_e`)는 중첩 함수가 자기 temp 로 같은 이름을
            // 다시 선언해 가릴 수 있어서, 모듈 전체에서 고유한 이름을 쓴다.
            const step = try uniqueStepName(self);
            const catch_param = try es_helpers.makeTempVarSpan(self); // _f
            if (register_sm_temps) {
                try self.generator_temp_var_spans.appendSlice(self.allocator, &.{ norm, did_err, err_val, iter, step, catch_param });
            }

            // var _a = true; var _b = false; var _c = void 0;
            const norm_decl = try makeVarDeclFromSpan(self, norm, try es_helpers.makeBoolLiteral(self, true), span);
            const did_decl = try makeVarDeclFromSpan(self, did_err, try es_helpers.makeBoolLiteral(self, false), span);
            const err_decl = try makeVarDeclFromSpan(self, err_val, try es_helpers.makeVoidZero(self, span), span);

            // init: var _d = __values(iterable), _e
            self.runtime_helpers.values = true;
            const values_call = try es_helpers.makeCallExpr(self, try es_helpers.makeRuntimeHelperRef(self, "__values"), &.{right}, span);
            const for_init = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, try es_helpers.makeBindingIdentifier(self, iter), values_call, span),
                try es_helpers.makeDeclarator(self, try es_helpers.makeBindingIdentifier(self, step), .none, span),
            }, .@"var", span);

            // test: !(_a = (_e = _d.next()).done)
            const next_call = try es_helpers.makeCallExpr(self, try es_helpers.makeStaticMember(self, try makeRefFromSpan(self, iter), try es_helpers.makeIdentifierRef(self, "next"), span), &.{}, span);
            const step_assign = try makeAssign(self, try makeRefFromSpan(self, step), next_call, span);
            const done = try es_helpers.makeStaticMember(self, step_assign, try es_helpers.makeIdentifierRef(self, "done"), span);
            const for_test = try es_helpers.makeUnaryNot(self, try makeAssign(self, try makeRefFromSpan(self, norm), done, span), span);

            // update: _a = true
            const for_update = try makeAssign(self, try makeRefFromSpan(self, norm), try es_helpers.makeBoolLiteral(self, true), span);

            // body: <루프 변수 = _e.value>; body
            const value = try es_helpers.makeStaticMember(self, try makeRefFromSpan(self, step), try es_helpers.makeIdentifierRef(self, "value"), span);
            const for_body = try buildLoopBody(self, left, value, body, span);

            const for_stmt = try self.addExtraNode(.for_statement, span, &.{
                @intFromEnum(for_init), @intFromEnum(for_test), @intFromEnum(for_update), @intFromEnum(for_body),
            });
            const loop_stmt = if (label_name_idx.isNone()) for_stmt else try self.ast.addNode(.{
                .tag = .labeled_statement,
                .span = span,
                .data = .{ .binary = .{ .left = label_name_idx, .right = for_stmt, .flags = 0 } },
            });

            // catch (_f) { _b = true; _c = _f; }
            const catch_body = try makeBlock(self, &.{
                try es_helpers.makeExprStmt(self, try makeAssign(self, try makeRefFromSpan(self, did_err), try es_helpers.makeBoolLiteral(self, true), span), span),
                try es_helpers.makeExprStmt(self, try makeAssign(self, try makeRefFromSpan(self, err_val), try makeRefFromSpan(self, catch_param), span), span),
            }, span);
            const catch_clause = try self.ast.addNode(.{ .tag = .catch_clause, .span = span, .data = .{ .binary = .{
                .left = try es_helpers.makeBindingIdentifier(self, catch_param),
                .right = catch_body,
                .flags = 0,
            } } });

            // finally { try { if (!_a && _d.return != null) _d.return(); } finally { if (_b) throw _c; } }
            const ret_member = try es_helpers.makeStaticMember(self, try makeRefFromSpan(self, iter), try es_helpers.makeIdentifierRef(self, "return"), span);
            const close_cond = try self.ast.addNode(.{ .tag = .logical_expression, .span = span, .data = .{ .binary = .{
                .left = try es_helpers.makeUnaryNot(self, try makeRefFromSpan(self, norm), span),
                .right = try es_helpers.makeNeqNull(self, ret_member, span),
                .flags = @intFromEnum(token_mod.Kind.amp2),
            } } });
            const close_call = try es_helpers.makeCallExpr(self, try es_helpers.makeStaticMember(self, try makeRefFromSpan(self, iter), try es_helpers.makeIdentifierRef(self, "return"), span), &.{}, span);
            const close_if = try self.ast.addNode(.{ .tag = .if_statement, .span = span, .data = .{ .ternary = .{
                .a = close_cond,
                .b = try es_helpers.makeExprStmt(self, close_call, span),
                .c = .none,
            } } });
            const rethrow = try self.ast.addNode(.{ .tag = .throw_statement, .span = span, .data = .{ .unary = .{ .operand = try makeRefFromSpan(self, err_val), .flags = 0 } } });
            const rethrow_if = try self.ast.addNode(.{ .tag = .if_statement, .span = span, .data = .{ .ternary = .{
                .a = try makeRefFromSpan(self, did_err),
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

        /// 루프 변수 대입을 앞에 둔 본문 블록. 원래 본문 블록에 루프 변수와 같은 이름의
        /// 선언이 있으면(헤더와 본문은 스코프가 다르다) 합치지 않고 한 겹 더 감싼다.
        fn buildLoopBody(self: *Transformer, left: NodeIndex, value: NodeIndex, body: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const left_node = self.ast.getNode(left);
            const head_stmt = if (left_node.tag == .variable_declaration) blk: {
                const d = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[self.readU32(left_node.data.extra, 1)]));
                const binding = self.readNodeIdx(d.data.extra, 0);
                break :blk try es_helpers.makeVarDeclaration(self, &.{
                    try es_helpers.makeDeclarator(self, binding, value, span),
                }, self.ast.variableDeclarationKind(left_node), span);
            } else try es_helpers.makeExprStmt(self, try makeAssign(self, left, value, span), span);

            if (body.isNone()) return makeBlock(self, &.{head_stmt}, span);
            const body_node = self.ast.getNode(body);
            if (body_node.tag == .block_statement and !(left_node.tag == .variable_declaration and try headCollidesWithBlock(self, left_node, body_node))) {
                var items: std.ArrayList(NodeIndex) = .empty;
                defer items.deinit(self.allocator);
                try items.append(self.allocator, head_stmt);
                var i: u32 = 0;
                while (i < body_node.data.list.len) : (i += 1) {
                    try items.append(self.allocator, @enumFromInt(self.ast.extra_data.items[body_node.data.list.start + i]));
                }
                return makeBlock(self, items.items, body_node.span);
            }
            return makeBlock(self, &.{ head_stmt, body }, span);
        }

        /// 헤더 선언 이름이 본문 블록 직계 선언(let/const/using/var/class/function)과 겹치는지.
        fn headCollidesWithBlock(self: *Transformer, head: Node, block: Node) Transformer.Error!bool {
            const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
            var head_names: std.ArrayList([]const u8) = .empty;
            defer head_names.deinit(self.allocator);
            const hd = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[self.readU32(head.data.extra, 1)]));
            try BlockScoping.collectBindingNames(self, self.readNodeIdx(hd.data.extra, 0), &head_names);

            var block_names: std.ArrayList([]const u8) = .empty;
            defer block_names.deinit(self.allocator);
            var i: u32 = 0;
            while (i < block.data.list.len) : (i += 1) {
                const st = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[block.data.list.start + i]));
                switch (st.tag) {
                    .variable_declaration => {
                        const ds = self.readU32(st.data.extra, 1);
                        const dl = self.readU32(st.data.extra, 2);
                        var j: u32 = 0;
                        while (j < dl) : (j += 1) {
                            const d = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[ds + j]));
                            if (d.tag == .variable_declarator) try BlockScoping.collectBindingNames(self, self.readNodeIdx(d.data.extra, 0), &block_names);
                        }
                    },
                    .class_declaration, .function_declaration => {
                        const name = self.readNodeIdx(st.data.extra, 0);
                        if (!name.isNone()) try block_names.append(self.allocator, self.ast.getText(self.ast.getNode(name).span));
                    },
                    else => {},
                }
            }
            for (head_names.items) |h| {
                for (block_names.items) |b| {
                    if (std.mem.eql(u8, h, b)) return true;
                }
            }
            return false;
        }

        fn uniqueStepName(self: *Transformer) Transformer.Error!Span {
            const prefix = "_step";
            while (true) {
                const name = try self.buildUniqueName(prefix, &self.forof_step_counter);
                defer if (name.ptr != prefix.ptr) self.allocator.free(name);
                if (es_helpers.nameAppearsInSource(self, name)) continue;
                return self.ast.addString(name);
            }
        }

        fn makeAssign(self: *Transformer, target: NodeIndex, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{ .left = target, .right = value, .flags = 0 } } });
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
            return self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = name_span,
                .data = .{ .string_ref = name_span },
            });
        }

        fn makeVarDeclFromSpan(self: *Transformer, name_span: Span, init: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const binding = try es_helpers.makeBindingIdentifier(self, name_span);
            const declarator = try es_helpers.makeDeclarator(self, binding, init, span);
            return es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
        }
    };
}

test "ES2015 for-of module compiles" {
    _ = ES2015ForOf;
}
