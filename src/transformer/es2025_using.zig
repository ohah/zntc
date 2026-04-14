//! ES2025 다운레벨링: using / await using (Explicit Resource Management)
//!
//! --target < es2025 일 때 활성화.
//!
//! 변환 대상:
//! - `using x = expr;` → try-finally + __using/__callDispose
//! - `await using x = expr;` → async try-finally
//!
//! 변환 패턴 (esbuild 호환):
//!
//! 입력:
//! ```javascript
//! {
//!   stmt_before;
//!   using res = getResource();
//!   doSomething(res);
//! }
//! ```
//!
//! 출력:
//! ```javascript
//! {
//!   stmt_before;
//!   var _stack = [];
//!   try {
//!     var res = __using(_stack, getResource());
//!     doSomething(res);
//!   } catch (_) {
//!     var _error = _, _hasError = true;
//!   } finally {
//!     __callDispose(_stack, _error, _hasError);
//!   }
//! }
//! ```
//!
//! await using:
//! - __using(_stack, expr, true) — 3번째 인수 true
//! - finally 블록에서 await __callDispose(...)
//!
//! 스펙:
//! - https://tc39.es/proposal-explicit-resource-management/
//!
//! 참고:
//! - esbuild: pkg/api/api_impl.go (using lowering)
//! - oxc: crates/oxc_transformer/src/es2025/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;

pub fn ES2025Using(comptime Transformer: type) type {
    return struct {
        const Self = @This();

        /// 문장 리스트에서 using/await using 선언이 있는지 스캔한다.
        /// 하나라도 있으면 true 반환 → lowerUsingInStatements 호출 필요.
        pub fn hasUsingDeclaration(self: *Transformer, start: u32, len: u32) bool {
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const raw_idx = self.ast.extra_data.items[start + i];
                const node = self.ast.getNode(@enumFromInt(raw_idx));
                if (node.tag == .variable_declaration) {
                    const e = node.data.extra;
                    if (self.ast.hasExtra(e, 3)) {
                        if (self.ast.variableDeclarationKind(node).isUsing()) return true;
                    }
                }
            }
            return false;
        }

        /// 문장 리스트를 변환한다: using 선언이 포함된 구간을 try-finally로 감싼다.
        ///
        /// 알고리즘:
        /// 1. using 선언이 처음 나타나는 위치를 찾는다
        /// 2. 그 이전 문장들은 그대로 방문하여 출력
        /// 3. using 선언부터 끝까지를 try-finally로 감싼다
        ///   - try body: using 선언을 var + __using() 호출로 변환 + 나머지 문장
        ///   - catch: var _error = _, _hasError = true
        ///   - finally: [await] __callDispose(_stack, _error, _hasError)
        pub fn lowerUsingInStatements(self: *Transformer, start: u32, len: u32) Transformer.Error!NodeList {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // pending_nodes save/restore
            const pending_top = self.pending_nodes.items.len;
            defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

            // 1. using 선언의 첫 위치 찾기
            var first_using_idx: u32 = len;
            var has_await_using = false;
            {
                var i: u32 = 0;
                while (i < len) : (i += 1) {
                    const raw_idx = self.ast.extra_data.items[start + i];
                    const node = self.ast.getNode(@enumFromInt(raw_idx));
                    if (node.tag == .variable_declaration) {
                        const e = node.data.extra;
                        if (self.ast.hasExtra(e, 3)) {
                            const kind = self.ast.variableDeclarationKind(node);
                            if (kind.isUsing()) {
                                if (first_using_idx == len) first_using_idx = i;
                                if (kind == .await_using) has_await_using = true;
                            }
                        }
                    }
                }
            }

            // 방어: using이 없으면 일반 방문
            if (first_using_idx == len) {
                return self.visitExtraList(start, len);
            }

            const zero_span = Span{ .start = 0, .end = 0 };

            // 2. using 이전 문장들을 그대로 방문
            {
                var i: u32 = 0;
                while (i < first_using_idx) : (i += 1) {
                    const raw_idx = self.ast.extra_data.items[start + i];
                    const new_child = try self.visitNode(@enumFromInt(raw_idx));
                    // pending_nodes 드레인
                    if (self.pending_nodes.items.len > pending_top) {
                        try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                        self.pending_nodes.shrinkRetainingCapacity(pending_top);
                    }
                    if (!new_child.isNone()) {
                        try self.scratch.append(self.allocator, new_child);
                    }
                }
            }

            // 3. var _stack = [] 선언 생성
            self.runtime_helpers.using_ctx = true;
            const stack_span = try self.ast.addString("_stack");
            const stack_binding = try es_helpers.makeBindingIdentifier(self, stack_span);
            // [] (빈 배열 리터럴)
            const empty_array = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = zero_span,
                .data = .{ .list = .{ .start = 0, .len = 0 } },
            });
            const stack_declarator = try self.addExtraNode(.variable_declarator, zero_span, &.{
                @intFromEnum(stack_binding),
                @intFromEnum(NodeIndex.none),
                @intFromEnum(empty_array),
            });
            const stack_decl_list = try self.ast.addNodeList(&.{stack_declarator});
            const stack_decl = try self.addExtraNode(.variable_declaration, zero_span, &.{
                @intFromEnum(VariableDeclarationKind.@"var"),
                stack_decl_list.start,
                stack_decl_list.len,
            });
            try self.scratch.append(self.allocator, stack_decl);

            // 4. try body: using 선언 + 나머지 문장 변환
            const try_body_scratch_top = self.scratch.items.len;
            {
                var i: u32 = first_using_idx;
                while (i < len) : (i += 1) {
                    const raw_idx = self.ast.extra_data.items[start + i];
                    const node = self.ast.getNode(@enumFromInt(raw_idx));

                    // using 선언을 var + __using() 호출로 변환
                    if (node.tag == .variable_declaration) {
                        const e = node.data.extra;
                        if (self.ast.hasExtra(e, 3)) {
                            const kind = self.ast.variableDeclarationKind(node);
                            if (kind.isUsing()) {
                                const decl_list_start = self.readU32(e, 1);
                                const decl_list_len = self.readU32(e, 2);
                                try transformUsingDeclarators(
                                    self,
                                    decl_list_start,
                                    decl_list_len,
                                    kind == .await_using,
                                    stack_span,
                                    node.span,
                                );
                                continue;
                            }
                        }
                    }

                    // 일반 문장은 그대로 방문
                    const new_child = try self.visitNode(@enumFromInt(raw_idx));
                    // pending_nodes 드레인
                    if (self.pending_nodes.items.len > pending_top) {
                        try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
                        self.pending_nodes.shrinkRetainingCapacity(pending_top);
                    }
                    if (!new_child.isNone()) {
                        try self.scratch.append(self.allocator, new_child);
                    }
                }
            }
            const try_body_stmts = self.scratch.items[try_body_scratch_top..];
            const try_body_list = try self.ast.addNodeList(try_body_stmts);
            self.scratch.shrinkRetainingCapacity(try_body_scratch_top);
            const try_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = zero_span,
                .data = .{ .list = try_body_list },
            });

            // 5. catch clause: catch (_) { var _error = _, _hasError = true; }
            const catch_block = try buildCatchClause(self, zero_span);

            // 6. finally block: [await] __callDispose(_stack, _error, _hasError)
            const finally_block = try buildFinallyBlock(self, stack_span, has_await_using, zero_span);

            // 7. try_statement 조립
            const try_stmt = try self.ast.addNode(.{
                .tag = .try_statement,
                .span = zero_span,
                .data = .{ .ternary = .{ .a = try_block, .b = catch_block, .c = finally_block } },
            });
            try self.scratch.append(self.allocator, try_stmt);

            return self.ast.addNodeList(self.scratch.items[scratch_top..]);
        }

        /// using 선언의 각 declarator를 var + __using() 호출로 변환하여 scratch에 추가.
        ///
        /// using x = expr → var x = __using(_stack, expr)
        /// await using x = expr → var x = __using(_stack, expr, true)
        fn transformUsingDeclarators(
            self: *Transformer,
            decl_start: u32,
            decl_len: u32,
            is_await: bool,
            stack_span: Span,
            span: Span,
        ) Transformer.Error!void {
            var j: u32 = 0;
            while (j < decl_len) : (j += 1) {
                const raw = self.ast.extra_data.items[decl_start + j];
                const decl = self.ast.getNode(@enumFromInt(raw));
                if (decl.tag != .variable_declarator) continue;

                const de = decl.data.extra;
                const name_idx = self.readNodeIdx(de, 0);
                const init_idx = self.readNodeIdx(de, 2);

                const new_name = try self.visitNode(name_idx);
                const new_init = if (!init_idx.isNone())
                    try self.visitNode(init_idx)
                else
                    // using은 항상 초기화가 필요하지만 방어적으로 void 0 사용
                    try es_helpers.makeVoidZero(self, span);

                // __using(_stack, init [, true])
                const stack_ref = try es_helpers.makeIdentifierRefFromSpan(self, stack_span);
                const using_ref = try es_helpers.makeIdentifierRef(self, "__using");

                const using_call = if (is_await) blk: {
                    const true_span = try self.ast.addString("true");
                    const true_node = try self.ast.addNode(.{
                        .tag = .boolean_literal,
                        .span = true_span,
                        .data = .{ .none = 0 },
                    });
                    break :blk try es_helpers.makeCallExpr(self, using_ref, &.{ stack_ref, new_init, true_node }, span);
                } else try es_helpers.makeCallExpr(self, using_ref, &.{ stack_ref, new_init }, span);

                // var x = __using(...)
                const none = @intFromEnum(NodeIndex.none);
                const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{
                    @intFromEnum(new_name), none, @intFromEnum(using_call),
                });
                const new_decl_list = try self.ast.addNodeList(&.{new_decl});
                const var_decl = try self.addExtraNode(.variable_declaration, span, &.{
                    @intFromEnum(VariableDeclarationKind.@"var"),
                    new_decl_list.start,
                    new_decl_list.len,
                });
                try self.scratch.append(self.allocator, var_decl);
            }
        }

        /// catch (_) { var _error = _, _hasError = true; }
        fn buildCatchClause(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const catch_param_span = try self.ast.addString("_");
            const catch_param = try es_helpers.makeBindingIdentifier(self, catch_param_span);

            // var _error = _, _hasError = true;
            // declarator 1: _error = _
            const error_span = try self.ast.addString("_error");
            const error_binding = try es_helpers.makeBindingIdentifier(self, error_span);
            const underscore_ref = try es_helpers.makeIdentifierRefFromSpan(self, catch_param_span);
            const none = @intFromEnum(NodeIndex.none);
            const error_declarator = try self.addExtraNode(.variable_declarator, span, &.{
                @intFromEnum(error_binding), none, @intFromEnum(underscore_ref),
            });

            // declarator 2: _hasError = true
            const has_error_span = try self.ast.addString("_hasError");
            const has_error_binding = try es_helpers.makeBindingIdentifier(self, has_error_span);
            const true_span = try self.ast.addString("true");
            const true_node = try self.ast.addNode(.{
                .tag = .boolean_literal,
                .span = true_span,
                .data = .{ .none = 0 },
            });
            const has_error_declarator = try self.addExtraNode(.variable_declarator, span, &.{
                @intFromEnum(has_error_binding), none, @intFromEnum(true_node),
            });

            const var_list = try self.ast.addNodeList(&.{ error_declarator, has_error_declarator });
            const var_decl = try self.addExtraNode(.variable_declaration, span, &.{
                @intFromEnum(VariableDeclarationKind.@"var"),
                var_list.start,
                var_list.len,
            });

            // block body
            const body_list = try self.ast.addNodeList(&.{var_decl});
            const body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            return self.ast.addNode(.{
                .tag = .catch_clause,
                .span = span,
                .data = .{ .binary = .{ .left = catch_param, .right = body, .flags = 0 } },
            });
        }

        /// finally { [await] __callDispose(_stack, _error, _hasError); }
        fn buildFinallyBlock(self: *Transformer, stack_span: Span, has_await: bool, span: Span) Transformer.Error!NodeIndex {
            const stack_ref = try es_helpers.makeIdentifierRefFromSpan(self, stack_span);
            const error_ref = try es_helpers.makeIdentifierRef(self, "_error");
            const has_error_ref = try es_helpers.makeIdentifierRef(self, "_hasError");
            const dispose_ref = try es_helpers.makeIdentifierRef(self, "__callDispose");

            const call = try es_helpers.makeCallExpr(self, dispose_ref, &.{ stack_ref, error_ref, has_error_ref }, span);

            // await __callDispose(...) for await using
            const expr = if (has_await) blk: {
                break :blk try self.ast.addNode(.{
                    .tag = .await_expression,
                    .span = span,
                    .data = .{ .unary = .{ .operand = call, .flags = 0 } },
                });
            } else call;

            const expr_stmt = try es_helpers.makeExprStmt(self, expr, span);
            const body_list = try self.ast.addNodeList(&.{expr_stmt});
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });
        }
    };
}

// readU32 헬퍼: Transformer에 이미 정의된 것을 사용 (mixin 패턴)
