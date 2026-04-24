//! ES2015 다운레벨링: let/const → var + for-loop 클로저 캡처 IIFE
//!
//! --target < es2015 일 때 활성화.
//!
//! 1단계: let/const → var 키워드 변환.
//! 2단계: for 루프에서 let/const 변수를 클로저가 캡처하는 경우 _loop 함수 추출.
//!
//! 변환 예시:
//!   for (let i = 0; i < 3; i++) { fns.push(() => i); }
//!   →
//!   var _loop = function(i) { fns.push(function() { return i; }); };
//!   for (var i = 0; i < 3; i++) { _loop(i); }
//!
//! 제어 흐름 처리 (FlowHelper):
//!   - return expr → return { v: expr }; 호출부에서 if (typeof _ret === "object") return _ret.v;
//!   - break      → return "break";      호출부에서 if (_ret === "break") break;
//!   - continue   → return;              (함수에서 return은 자연스럽게 다음 반복으로)
//!   - break label / continue label → return "break|label" / "continue|label"
//!   - switch 내부/중첩 루프 내부의 break/continue는 변환하지 않음
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-let-and-const-declarations (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/block_scoping/ (~1404줄)
//! - Babel: @babel/plugin-transform-block-scoping

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;

/// block scoping 다운레벨 시 모든 lexical(let/const/using/await_using)을 var로 치환.
/// (using disposal 등 의미 보존은 별도 패스가 처리)
pub inline fn lowerKind(_: VariableDeclarationKind) VariableDeclarationKind {
    return .@"var";
}

pub fn ES2015BlockScoping(comptime Transformer: type) type {
    return struct {
        const Self = @This();

        /// for 루프의 init에서 let/const 변수 이름을 수집한다.
        /// 반환: 수집된 변수 이름 목록. 비어 있으면 클로저 캡처 분석 불필요.
        pub fn collectLexicalVarNames(
            self: *Transformer,
            init_idx: NodeIndex,
        ) !std.ArrayList([]const u8) {
            var names: std.ArrayList([]const u8) = .empty;
            if (init_idx.isNone()) return names;
            const init = self.ast.getNode(init_idx);
            if (init.tag != .variable_declaration) return names;

            if (!self.ast.variableDeclarationKind(init).isLexical()) return names;

            const e = init.data.extra;

            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);

            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list_start + i]);
                const decl = self.ast.getNode(decl_idx);
                if (decl.tag != .variable_declarator) continue;
                const name_idx = self.readNodeIdx(decl.data.extra, 0);
                try collectBindingNames(self, name_idx, &names);
            }
            return names;
        }

        /// binding pattern에서 모든 identifier 이름을 수집한다.
        /// destructuring 포함 (array_pattern, object_pattern, rest_element, assignment_pattern).
        pub fn collectBindingNames(
            self: *Transformer,
            idx: NodeIndex,
            names: *std.ArrayList([]const u8),
        ) !void {
            if (idx.isNone()) return;
            const node = self.ast.getNode(idx);
            switch (node.tag) {
                .binding_identifier => {
                    const text = self.ast.getText(node.span);
                    try names.append(self.allocator, text);
                },
                .array_pattern => {
                    const split = self.ast.nodeListSplitRest(node.data.list);
                    for (split.elements) |raw| {
                        try collectBindingNames(self, @enumFromInt(raw), names);
                    }
                    if (split.rest_operand) |op| {
                        try collectBindingNames(self, op, names);
                    }
                },
                .object_pattern => {
                    const split = self.ast.nodeListSplitRest(node.data.list);
                    for (split.elements) |raw| {
                        const prop = self.ast.getNode(@enumFromInt(raw));
                        // binding_property: binary = { left: key, right: value, flags }
                        if (prop.tag == .binding_property) {
                            try collectBindingNames(self, prop.data.binary.right, names);
                        }
                    }
                    if (split.rest_operand) |op| {
                        try collectBindingNames(self, op, names);
                    }
                },
                .assignment_pattern => {
                    // assignment_pattern은 binary: left = binding, right = default value
                    try collectBindingNames(self, node.data.binary.left, names);
                },
                else => {},
            }
        }

        /// loop body 내부를 반복적(iterative)으로 스캔하여
        /// 클로저(arrow/function)가 lexical 변수를 캡처하는지 검사한다.
        /// 명시적 스택 사용 — stack overflow 불가능.
        pub fn hasCapturedClosure(
            self: *Transformer,
            body_idx: NodeIndex,
            lexical_names: []const []const u8,
        ) bool {
            if (body_idx.isNone() or lexical_names.len == 0) return false;
            // 원본 AST 범위. 원본 파서 노드만 방문 (transformer가 추가한 노드는 무시).
            const max_node = self.parser_node_count;

            const ScanEntry = struct { idx: NodeIndex, fn_depth: u32 };
            var stack: std.ArrayList(ScanEntry) = .empty;
            defer stack.deinit(self.allocator);
            stack.append(self.allocator, .{ .idx = body_idx, .fn_depth = 0 }) catch return false;

            while (stack.items.len > 0) {
                const entry = stack.pop() orelse break;
                if (entry.idx.isNone()) continue;
                if (@intFromEnum(entry.idx) >= max_node) continue;
                const node = self.ast.getNode(entry.idx);

                // 클로저 경계: fn_depth 증가
                const fn_depth = if (node.tag == .function_expression or
                    node.tag == .function_declaration or
                    node.tag == .arrow_function_expression or
                    node.tag == .function)
                    entry.fn_depth + 1
                else
                    entry.fn_depth;

                // identifier_reference: fn_depth > 0이면 캡처 검사
                if (node.tag == .identifier_reference and fn_depth > 0) {
                    const name = self.ast.getText(node.span);
                    for (lexical_names) |ln| {
                        if (std.mem.eql(u8, name, ln)) return true;
                    }
                }

                // 자식 노드를 스택에 push (OOM 시 보수적으로 캡처 가정)
                var children: std.ArrayList(NodeIndex) = .empty;
                defer children.deinit(self.allocator);
                collectChildIndices(self, node, &children) catch return true;
                for (children.items) |child_idx| {
                    stack.append(self.allocator, .{ .idx = child_idx, .fn_depth = fn_depth }) catch return true;
                }
            }
            return false;
        }

        /// 노드의 자식 NodeIndex들을 scratch 버퍼에 수집한다.
        /// 공통 `ast_walk.ChildIterator` 로 자식 순회 + `parser_node_count` 가드로
        /// transformer 신규 노드 영역을 걸러낸다 (extra 자식에만 한정).
        fn collectChildIndices(self: *Transformer, node: Node, buf: *std.ArrayList(NodeIndex)) !void {
            const kind = node.tag.dataKind();
            var it = ast_walk.children(self.ast, node);
            while (it.next()) |child| {
                if (kind == .extra) {
                    const raw = @intFromEnum(child);
                    if (raw == 0 or raw >= self.parser_node_count) continue;
                }
                try buf.append(self.allocator, child);
            }
        }

        /// 제어 흐름 분석 결과.
        pub const FlowResult = struct {
            has_return: bool = false,
            has_break: bool = false,
            has_labeled_break: bool = false,
            has_labeled_continue: bool = false,
            labels: std.ArrayList([]const u8) = .empty,
        };

        /// for 루프 body를 _loop 함수로 추출하고 호출로 대체한다.
        ///
        /// 반환: { .loop_fn_decl, .call_stmt } — 호출부에서 조립.
        pub fn buildLoopClosureWithFlow(
            self: *Transformer,
            visited_body: NodeIndex,
            lexical_names: []const []const u8,
            flow: *const FlowResult,
            span: Span,
        ) Transformer.Error!struct { loop_fn: NodeIndex, call_and_check: NodeIndex } {
            // --- _loop 함수명 생성 ---
            const loop_prefix = "_loop";
            const loop_name = try self.buildUniqueName(loop_prefix, &self.loop_counter);
            defer if (loop_name.ptr != loop_prefix.ptr) self.allocator.free(loop_name);

            const needs_ret_var = flow.has_return or flow.has_break or flow.has_labeled_break or flow.has_labeled_continue;

            // --- body 내��� break/continue/return 변환 ---
            var transformed_body = visited_body;
            if (needs_ret_var) {
                transformed_body = try transformControlFlow(self, visited_body, flow);
            }

            // --- function params: 캡처된 변수 ---
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            for (lexical_names) |name| {
                const param_span = try self.ast.addString(name);
                const param = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = param_span,
                    .data = .{ .string_ref = param_span },
                });
                const formal = try self.ast.addNode(.{
                    .tag = .formal_parameter,
                    .span = param_span,
                    .data = .{ .extra = try self.ast.addExtras(&.{
                        @intFromEnum(param), @intFromEnum(NodeIndex.none), @intFromEnum(NodeIndex.none),
                        0,                   0,                            @intFromEnum(NodeIndex.none),
                    }) },
                });
                try self.scratch.append(self.allocator, formal);
            }
            const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);

            const none = @intFromEnum(NodeIndex.none);
            const params_node = try self.ast.addFormalParameters(params, span);
            const func_extra = try self.ast.addExtras(&.{
                none,                           @intFromEnum(params_node),
                @intFromEnum(transformed_body), 0,
                none,
            });
            const func_expr = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            // --- var _loop = function(...) { ... } ---
            const loop_name_span = try self.ast.addString(loop_name);
            const loop_binding = try es_helpers.makeBindingIdentifier(self, loop_name_span);
            const loop_decl = try es_helpers.makeDeclarator(self, loop_binding, func_expr, span);
            const loop_var = try es_helpers.makeVarDeclaration(self, &.{loop_decl}, .@"var", span);

            // --- _loop(i, j, ...) 호출 ---
            const scratch_top2 = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top2);
            for (lexical_names) |name| {
                try self.scratch.append(self.allocator, try es_helpers.makeIdentifierRef(self, name));
            }
            const call_args = try self.ast.addNodeList(self.scratch.items[scratch_top2..]);
            const loop_ref = try es_helpers.makeIdentifierRef(self, loop_name);
            const call_extra = try self.ast.addExtras(&.{
                @intFromEnum(loop_ref), call_args.start, call_args.len, 0,
            });
            const loop_call = try self.ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call_extra },
            });

            // --- 제어 흐름 후처리: var _ret = _loop(i); if (...) ... ---
            var final_stmt: NodeIndex = undefined;
            if (needs_ret_var) {
                final_stmt = try buildControlFlowCheck(self, loop_call, flow, span);
            } else {
                final_stmt = try self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = loop_call, .flags = 0 } },
                });
            }

            // 호출문을 블록으로 감싸기
            const call_block_list = try self.ast.addNodeList(&.{final_stmt});
            const call_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = call_block_list },
            });

            return .{ .loop_fn = loop_var, .call_and_check = call_block };
        }

        /// body AST를 반복적(iterative)으로 스캔하여 break/continue/return 사용을 분석한다.
        /// 명시적 스택 사용 — stack overflow 불가능.
        pub fn analyzeControlFlow(
            self: *Transformer,
            body_idx: NodeIndex,
            flow: *FlowResult,
            init_loop_depth: u32,
            init_switch_depth: u32,
        ) void {
            const FlowEntry = struct { idx: NodeIndex, loop_depth: u32, switch_depth: u32 };
            var stack: std.ArrayList(FlowEntry) = .empty;
            defer stack.deinit(self.allocator);
            stack.append(self.allocator, .{ .idx = body_idx, .loop_depth = init_loop_depth, .switch_depth = init_switch_depth }) catch return;

            while (stack.items.len > 0) {
                const entry = stack.pop() orelse break;
                if (entry.idx.isNone()) continue;
                if (@intFromEnum(entry.idx) >= self.parser_node_count) continue;
                const node = self.ast.getNode(entry.idx);

                var loop_depth = entry.loop_depth;
                var switch_depth = entry.switch_depth;

                switch (node.tag) {
                    .for_statement,
                    .for_in_statement,
                    .for_of_statement,
                    .for_await_of_statement,
                    .while_statement,
                    .do_while_statement,
                    => {
                        loop_depth += 1;
                    },
                    .switch_statement => {
                        switch_depth += 1;
                    },
                    .function_expression,
                    .function_declaration,
                    .arrow_function_expression,
                    .function,
                    => continue, // 클로저 경계: 내부 무시

                    .return_statement => {
                        flow.has_return = true;
                        continue;
                    },
                    .break_statement => {
                        if (node.data.unary.operand.isNone()) {
                            if (loop_depth == 0 and switch_depth == 0) flow.has_break = true;
                        } else {
                            flow.has_labeled_break = true;
                            appendUniqueLabel(flow, self.allocator, self.ast.getText(self.ast.getNode(node.data.unary.operand).span));
                        }
                        continue;
                    },
                    .continue_statement => {
                        if (!node.data.unary.operand.isNone()) {
                            flow.has_labeled_continue = true;
                            appendUniqueLabel(flow, self.allocator, self.ast.getText(self.ast.getNode(node.data.unary.operand).span));
                        }
                        continue;
                    },
                    else => {},
                }

                var children: std.ArrayList(NodeIndex) = .empty;
                defer children.deinit(self.allocator);
                collectChildIndices(self, node, &children) catch {};
                for (children.items) |child_idx| {
                    stack.append(self.allocator, .{ .idx = child_idx, .loop_depth = loop_depth, .switch_depth = switch_depth }) catch {};
                }
            }
        }

        /// label 중복 없이 추가
        fn appendUniqueLabel(flow: *FlowResult, alloc: std.mem.Allocator, label_text: []const u8) void {
            for (flow.labels.items) |l| {
                if (std.mem.eql(u8, l, label_text)) return;
            }
            flow.labels.append(alloc, label_text) catch {};
        }

        /// body 내부의 break/continue/return을 _loop 함수에 맞게 변환한다.
        /// return expr → return { v: expr }
        /// break → return "break"
        /// continue → return (값 없음)
        fn transformControlFlow(
            self: *Transformer,
            body_idx: NodeIndex,
            flow: *const FlowResult,
        ) Transformer.Error!NodeIndex {
            // body는 block_statement. 각 문을 재귀적으로 변환.
            if (body_idx.isNone()) return body_idx;
            const body = self.ast.getNode(body_idx);
            if (body.tag != .block_statement) return body_idx;

            const list = body.data.list;
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            const stmts = self.ast.extra_data.items[list.start .. list.start + list.len];
            for (stmts) |raw| {
                const transformed = try transformStmtFlow(self, @enumFromInt(raw), flow, 0, 0);
                try self.scratch.append(self.allocator, transformed);
            }

            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = body.span,
                .data = .{ .list = new_list },
            });
        }

        fn transformStmtFlow(
            self: *Transformer,
            idx: NodeIndex,
            flow: *const FlowResult,
            loop_depth: u32,
            switch_depth: u32,
        ) Transformer.Error!NodeIndex {
            if (idx.isNone()) return idx;
            const node = self.ast.getNode(idx);

            switch (node.tag) {
                // 중첩 루프/switch: depth 증가
                .for_statement,
                .for_in_statement,
                .for_of_statement,
                .for_await_of_statement,
                .while_statement,
                .do_while_statement,
                => return transformFlowInLoop(self, idx, node, flow, loop_depth + 1, switch_depth),

                .switch_statement => return transformFlowInLoop(self, idx, node, flow, loop_depth, switch_depth + 1),

                // 클로저 경계: 변환하지 않음
                .function_expression,
                .function_declaration,
                .arrow_function_expression,
                .function,
                => return idx,

                .return_statement => {
                    if (flow.has_return) {
                        // return expr → return { v: expr }
                        const val = node.data.unary.operand;
                        if (val.isNone()) {
                            // return; → return { v: void 0 }
                            const void_zero = try es_helpers.makeVoidZero(self, node.span);
                            const obj = try buildReturnObject(self, void_zero, node.span);
                            return self.ast.addNode(.{
                                .tag = .return_statement,
                                .span = node.span,
                                .data = .{ .unary = .{ .operand = obj, .flags = 0 } },
                            });
                        }
                        const obj = try buildReturnObject(self, val, node.span);
                        return self.ast.addNode(.{
                            .tag = .return_statement,
                            .span = node.span,
                            .data = .{ .unary = .{ .operand = obj, .flags = 0 } },
                        });
                    }
                    return idx;
                },
                .break_statement => {
                    if (node.data.unary.operand.isNone()) {
                        // unlabeled break
                        if (loop_depth == 0 and switch_depth == 0 and flow.has_break) {
                            // break → return "break"
                            const str = try es_helpers.buildStringNode(self, "\"break\"", node.span);
                            return self.ast.addNode(.{
                                .tag = .return_statement,
                                .span = node.span,
                                .data = .{ .unary = .{ .operand = str, .flags = 0 } },
                            });
                        }
                    } else if (flow.has_labeled_break) {
                        // break label → return "break|label"
                        const label_text = self.ast.getText(self.ast.getNode(node.data.unary.operand).span);
                        const sentinel = try std.fmt.allocPrint(self.allocator, "\"break|{s}\"", .{label_text});
                        defer self.allocator.free(sentinel);
                        const str = try es_helpers.buildStringNode(self, sentinel, node.span);
                        return self.ast.addNode(.{
                            .tag = .return_statement,
                            .span = node.span,
                            .data = .{ .unary = .{ .operand = str, .flags = 0 } },
                        });
                    }
                    return idx;
                },
                .continue_statement => {
                    if (node.data.unary.operand.isNone()) {
                        // unlabeled continue → return (빈 return)
                        if (loop_depth == 0) {
                            return self.ast.addNode(.{
                                .tag = .return_statement,
                                .span = node.span,
                                .data = .{ .unary = .{ .operand = NodeIndex.none, .flags = 0 } },
                            });
                        }
                    } else if (flow.has_labeled_continue) {
                        // continue label → return "continue|label"
                        const label_text = self.ast.getText(self.ast.getNode(node.data.unary.operand).span);
                        const sentinel = try std.fmt.allocPrint(self.allocator, "\"continue|{s}\"", .{label_text});
                        defer self.allocator.free(sentinel);
                        const str = try es_helpers.buildStringNode(self, sentinel, node.span);
                        return self.ast.addNode(.{
                            .tag = .return_statement,
                            .span = node.span,
                            .data = .{ .unary = .{ .operand = str, .flags = 0 } },
                        });
                    }
                    return idx;
                },

                // block_statement: 내부 문들을 재귀 변환
                .block_statement => {
                    const list = node.data.list;
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    const stmts = self.ast.extra_data.items[list.start .. list.start + list.len];
                    for (stmts) |raw| {
                        try self.scratch.append(self.allocator, try transformStmtFlow(self, @enumFromInt(raw), flow, loop_depth, switch_depth));
                    }
                    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    return self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = node.span,
                        .data = .{ .list = new_list },
                    });
                },

                // if_statement: consequent/alternate 재귀
                .if_statement => {
                    const new_cons = try transformStmtFlow(self, node.data.ternary.b, flow, loop_depth, switch_depth);
                    const new_alt = try transformStmtFlow(self, node.data.ternary.c, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = .if_statement,
                        .span = node.span,
                        .data = .{ .ternary = .{ .a = node.data.ternary.a, .b = new_cons, .c = new_alt } },
                    });
                },

                // labeled_statement: 내부 문 재귀
                .labeled_statement => {
                    const new_body = try transformStmtFlow(self, node.data.binary.right, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = .labeled_statement,
                        .span = node.span,
                        .data = .{ .binary = .{ .left = node.data.binary.left, .right = new_body, .flags = node.data.binary.flags } },
                    });
                },

                // try_statement: try/catch/finally 재귀
                .try_statement => {
                    const new_try = try transformStmtFlow(self, node.data.ternary.a, flow, loop_depth, switch_depth);
                    const new_catch = try transformStmtFlow(self, node.data.ternary.b, flow, loop_depth, switch_depth);
                    const new_finally = try transformStmtFlow(self, node.data.ternary.c, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = .try_statement,
                        .span = node.span,
                        .data = .{ .ternary = .{ .a = new_try, .b = new_catch, .c = new_finally } },
                    });
                },

                else => return idx,
            }
        }

        /// 중첩 루프/switch 내부의 body만 변환
        fn transformFlowInLoop(
            self: *Transformer,
            _: NodeIndex,
            node: Node,
            flow: *const FlowResult,
            loop_depth: u32,
            switch_depth: u32,
        ) Transformer.Error!NodeIndex {
            // for_statement의 body, while의 body 등을 재귀 변���
            // 각 노드 타입에 따라 body 위치가 다름
            switch (node.tag) {
                .for_statement => {
                    const e = node.data.extra;
                    const new_body = try transformStmtFlow(self, self.readNodeIdx(e, 3), flow, loop_depth, switch_depth);
                    return self.addExtraNode(.for_statement, node.span, &.{
                        self.ast.extra_data.items[e],
                        self.ast.extra_data.items[e + 1],
                        self.ast.extra_data.items[e + 2],
                        @intFromEnum(new_body),
                    });
                },
                .while_statement, .do_while_statement => {
                    const new_body = try transformStmtFlow(self, node.data.binary.right, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = node.tag,
                        .span = node.span,
                        .data = .{ .binary = .{ .left = node.data.binary.left, .right = new_body, .flags = node.data.binary.flags } },
                    });
                },
                .for_in_statement, .for_of_statement, .for_await_of_statement => {
                    const new_body = try transformStmtFlow(self, node.data.ternary.c, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = node.tag,
                        .span = node.span,
                        .data = .{ .ternary = .{ .a = node.data.ternary.a, .b = node.data.ternary.b, .c = new_body } },
                    });
                },
                .switch_statement => {
                    // switch cases 내부의 문들을 재귀 변환
                    const e = node.data.extra;
                    const cases_start = self.readU32(e, 1);
                    const cases_len = self.readU32(e, 2);
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    for (0..cases_len) |ci| {
                        const case_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[cases_start + ci]);
                        const case_node = self.ast.getNode(case_idx);
                        // switch_case: extra = [test(0), stmts_start(1), stmts_len(2)]
                        const ce = case_node.data.extra;
                        const test_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
                        const case_stmts_start = self.ast.extra_data.items[ce + 1];
                        const case_stmts_len = self.ast.extra_data.items[ce + 2];
                        // case body의 각 문을 재귀 변환
                        const inner_scratch = self.scratch.items.len;
                        defer self.scratch.shrinkRetainingCapacity(inner_scratch);
                        for (0..case_stmts_len) |si| {
                            const stmt_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[case_stmts_start + si]);
                            try self.scratch.append(self.allocator, try transformStmtFlow(self, stmt_idx, flow, loop_depth, switch_depth));
                        }
                        const new_stmts = try self.ast.addNodeList(self.scratch.items[inner_scratch..]);
                        try self.scratch.append(self.allocator, try self.addExtraNode(.switch_case, case_node.span, &.{
                            @intFromEnum(test_node), new_stmts.start, new_stmts.len,
                        }));
                    }
                    const new_cases = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    return self.addExtraNode(.switch_statement, node.span, &.{
                        self.ast.extra_data.items[e],
                        new_cases.start,
                        new_cases.len,
                    });
                },
                else => return NodeIndex.none,
            }
        }

        /// { v: expr } 객체 리터럴을 생성한다 (return 변환용).
        fn buildReturnObject(self: *Transformer, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // object_property 는 `binary = { left=key, right=value, flags }` layout.
            // 이전 구현은 `.extra` 로 생성해 codegen 의 `emitObjectProperty` 가
            // `node.data.binary.left/right` 로 garbage 메모리를 읽어 panic (#1797 알려진
            // 제약). 기존 `es_helpers.zig:31-35` 등 다른 object_property 생성 사이트와
            // 동일한 binary layout 으로 수정.
            const key = try es_helpers.makeIdentifierRef(self, "v");
            const prop = try self.ast.addNode(.{
                .tag = .object_property,
                .span = span,
                .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
            });
            const obj_list = try self.ast.addNodeList(&.{prop});
            return self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = obj_list },
            });
        }

        /// _loop() 호출 후 제어 흐름 체크 코드를 생성한다.
        /// var _ret = _loop(i); if (typeof _ret === "object") return _ret.v; if (_ret === "break") break;
        fn buildControlFlowCheck(
            self: *Transformer,
            loop_call: NodeIndex,
            flow: *const FlowResult,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // var _ret = _loop(i)
            const ret_decl = try self.buildVarDecl("_ret", loop_call, span);
            try self.scratch.append(self.allocator, ret_decl);

            // if (typeof _ret === "object") return _ret.v;
            if (flow.has_return) {
                const ret_ref = try es_helpers.makeIdentifierRef(self, "_ret");
                // unary_expression 의 data layout 은 `.extra = [operand, operator]`.
                // 기존 `.unary` variant 로 생성하면 codegen 이 operand 대신 operator 토큰
                // 문자열(`<=`)을 출력 → `if (<= === "object")` 문법 에러.
                const typeof_extra = try self.ast.addExtras(&.{
                    @intFromEnum(ret_ref),
                    @intFromEnum(token_mod.Kind.kw_typeof),
                });
                const typeof_expr = try self.ast.addNode(.{
                    .tag = .unary_expression,
                    .span = span,
                    .data = .{ .extra = typeof_extra },
                });
                const obj_str = try es_helpers.buildStringNode(self, "\"object\"", span);
                const typeof_check = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = typeof_expr, .right = obj_str, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                });
                // _ret.v
                const ret_ref2 = try es_helpers.makeIdentifierRef(self, "_ret");
                const v_prop = try es_helpers.makeIdentifierRef(self, "v");
                const ret_v = try es_helpers.makeStaticMember(self, ret_ref2, v_prop, span);
                const return_stmt = try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = ret_v, .flags = 0 } },
                });
                const if_return = try self.ast.addNode(.{
                    .tag = .if_statement,
                    .span = span,
                    .data = .{ .ternary = .{ .a = typeof_check, .b = return_stmt, .c = NodeIndex.none } },
                });
                try self.scratch.append(self.allocator, if_return);
            }

            // if (_ret === "break") break;
            if (flow.has_break) {
                const ret_ref = try es_helpers.makeIdentifierRef(self, "_ret");
                const break_str = try es_helpers.buildStringNode(self, "\"break\"", span);
                const break_check = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = ret_ref, .right = break_str, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                });
                const break_stmt = try self.ast.addNode(.{
                    .tag = .break_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = NodeIndex.none, .flags = 0 } },
                });
                const if_break = try self.ast.addNode(.{
                    .tag = .if_statement,
                    .span = span,
                    .data = .{ .ternary = .{ .a = break_check, .b = break_stmt, .c = NodeIndex.none } },
                });
                try self.scratch.append(self.allocator, if_break);
            }

            // labeled break/continue 처리
            for (flow.labels.items) |label| {
                // if (_ret === "break|label") break label;
                // if (_ret === "continue|label") continue label;
                for ([_][]const u8{ "break", "continue" }) |kw| {
                    const sentinel = try std.fmt.allocPrint(self.allocator, "\"{s}|{s}\"", .{ kw, label });
                    defer self.allocator.free(sentinel);
                    const ret_ref = try es_helpers.makeIdentifierRef(self, "_ret");
                    const sentinel_str = try es_helpers.buildStringNode(self, sentinel, span);
                    const check = try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = ret_ref, .right = sentinel_str, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                    });
                    const label_span = try self.ast.addString(label);
                    const label_node = try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = label_span,
                        .data = .{ .string_ref = label_span },
                    });
                    const ctrl_tag: Tag = if (std.mem.eql(u8, kw, "break")) .break_statement else .continue_statement;
                    const ctrl_stmt = try self.ast.addNode(.{
                        .tag = ctrl_tag,
                        .span = span,
                        .data = .{ .unary = .{ .operand = label_node, .flags = 0 } },
                    });
                    const if_ctrl = try self.ast.addNode(.{
                        .tag = .if_statement,
                        .span = span,
                        .data = .{ .ternary = .{ .a = check, .b = ctrl_stmt, .c = NodeIndex.none } },
                    });
                    try self.scratch.append(self.allocator, if_ctrl);
                }
            }

            // 모든 문을 블록으로 감싸기
            const block_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = block_list },
            });
        }
    };
}

test "ES2015 block scoping module compiles" {
    const std_lib = @import("std");
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.@"var")); // var → var
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.let)); // let → var
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.@"const")); // const → var
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.using)); // using → var
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.await_using)); // await_using → var
}
