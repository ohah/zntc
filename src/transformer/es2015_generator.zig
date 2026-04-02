//! ES2015 다운레벨링: generator function → 상태 머신
//!
//! --target < es2015 일 때 활성화.
//!
//! function* gen() { yield 1; var x = yield 2; return x; }
//! → function gen() {
//!     return __generator(function(_state) {
//!       switch (_state.label) {
//!         case 0: return [4, 1];
//!         case 1: x = _state.sent(); return [4, 2];
//!         case 2: return [2, _state.sent()];
//!       }
//!     });
//!   }
//!
//! 상태 머신 instruction 코드:
//!   [4, value] — yield (일시정지, value 반환)
//!   [2, value] — return (완료)
//!   [3, label] — break/jump (다른 case로 이동)
//!   [5, iter]  — yield* (위임)
//!
//! __generator 런타임 헬퍼:
//!   _state.label — 현재 case 번호
//!   _state.sent() — .next(value)로 전달된 값
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-generator-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/generator.rs (~3778줄)
//! - TypeScript: src/compiler/transformers/generators.ts
//! - esbuild: 미지원

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

/// 상태 머신의 개별 연산.
const OpCode = enum {
    statement, // 일반 문
    yield_op, // yield value → [4, value]
    yield_star, // yield* iter → [5, iter]
    return_op, // return value → [2, value]
    break_op, // goto label → [3, label]
    break_when_true, // if (expr) goto label
    break_when_false, // if (!expr) goto label
    nop, // case 경계 강제 (빈 연산)
};

/// 연산의 인자.
const OpArg = union(enum) {
    none: void,
    node: NodeIndex, // statement, yield, return의 값
    label: u32, // break_op의 대상 label
    label_and_node: struct { label: u32, node: NodeIndex }, // break_when_true/false
};

/// 하나의 연산 (opcode + 인자).
const Operation = struct {
    code: OpCode,
    arg: OpArg,
};

pub fn ES2015Generator(comptime Transformer: type) type {
    return struct {
        /// generator function을 상태 머신으로 변환.
        /// function*: extra = [name, params_start, params_len, body, flags, return_type]
        pub fn lowerGeneratorFunction(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const extras = self.old_ast.extra_data.items;
            const e = node.data.extra;
            const span = node.span;

            const name_idx: NodeIndex = @enumFromInt(extras[e]);
            const params_start = extras[e + 1];
            const params_len = extras[e + 2];
            const body_idx: NodeIndex = @enumFromInt(extras[e + 3]);
            const flags = extras[e + 4];

            const new_name = try self.visitNode(name_idx);
            const new_params = try self.visitExtraList(params_start, params_len);

            const sm_result = try buildStateMachine(self, body_idx, span);
            if (sm_result.body.isNone()) return .none;

            const gen_call = try buildGeneratorHelperCall(self, sm_result.body, span);

            // return __generator(...) 문
            const ret_stmt = try self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = gen_call, .flags = 0 } },
            });

            // hoisted var 선언을 __generator 밖에 배치
            const body_list = if (sm_result.var_decl.isNone())
                try self.new_ast.addNodeList(&.{ret_stmt})
            else
                try self.new_ast.addNodeList(&.{ sm_result.var_decl, ret_stmt });
            const new_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // 일반 function으로 변환 (generator 플래그 제거)
            const new_flags = flags & ~@as(u32, ast_mod.FunctionFlags.is_generator);
            const none = @intFromEnum(NodeIndex.none);
            const new_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(new_name),
                new_params.start,
                new_params.len,
                @intFromEnum(new_body),
                new_flags,
                none,
            });
            return self.new_ast.addNode(.{
                .tag = node.tag,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        pub const StateMachineResult = struct {
            body: NodeIndex, // switch 문 (또는 switch를 포함하는 block)
            var_decl: NodeIndex, // 호이스팅된 var 선언 (없으면 .none)
        };

        /// generator body를 switch 문 기반 상태 머신으로 변환.
        /// es2017 결합 변환에서도 호출 (async body의 await를 yield처럼 처리).
        pub fn buildStateMachine(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!StateMachineResult {
            if (body_idx.isNone()) return .{ .body = .none, .var_decl = .none };

            const body = self.old_ast.getNode(body_idx);

            // expression body (arrow function): implicit return으로 처리
            if (body.tag != .block_statement and body.tag != .function_body) {
                return buildExpressionBodyStateMachine(self, body_idx, body, span);
            }

            const stmts = self.old_ast.extra_data.items[body.data.list.start .. body.data.list.start + body.data.list.len];

            // Phase 1: 연산 수집 (yield/return/statement를 Operation으로 변환)
            var ops: std.ArrayList(Operation) = .empty;
            defer ops.deinit(self.allocator);

            var next_label: u32 = 1; // label 0은 시작

            // 변수 호이스팅: generator body의 모든 var 선언을 수집.
            // JS의 var는 function-scoped이므로 switch case 안에 두면 안 됨.
            var hoisted_vars: std.ArrayList(NodeIndex) = .empty;
            defer hoisted_vars.deinit(self.allocator);
            try collectHoistedVars(self, stmts, &hoisted_vars);

            for (stmts) |raw_idx| {
                try collectOperations(self, @enumFromInt(raw_idx), &ops, &next_label);
            }

            // 암시적 return (마지막에 return이 없으면 추가)
            if (ops.items.len == 0 or ops.items[ops.items.len - 1].code != .return_op) {
                try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .none = {} } });
            }

            // Phase 2: 연산을 switch case로 변환
            const switch_node = try buildSwitchFromOps(self, ops.items, span);

            // var 선언을 __generator 콜백 밖으로 분리하여 함수 스코프에 배치.
            // 콜백 안에 두면 매 호출마다 var가 재선언되어 상태가 리셋됨.
            var var_decl_node: NodeIndex = .none;
            if (hoisted_vars.items.len > 0) {
                const scratch_top2 = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top2);

                for (hoisted_vars.items) |binding| {
                    const declarator = try es_helpers.makeDeclarator(self, binding, .none, span);
                    try self.scratch.append(self.allocator, declarator);
                }
                var_decl_node = try es_helpers.makeVarDeclaration(self, self.scratch.items[scratch_top2..], 0, span);
            }

            return .{ .body = switch_node, .var_decl = var_decl_node };
        }

        /// AST 문을 순회하며 연산을 수집.
        fn collectOperations(self: *Transformer, stmt_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            if (stmt_idx.isNone()) return;
            const stmt = self.old_ast.getNode(stmt_idx);

            switch (stmt.tag) {
                .expression_statement => {
                    // expression_statement 안의 yield/await 감지
                    const expr_idx = stmt.data.unary.operand;
                    const expr = self.old_ast.getNode(expr_idx);

                    if (expr.tag == .yield_expression or expr.tag == .await_expression) {
                        const value_idx = expr.data.unary.operand;
                        const is_delegate = if (expr.tag == .yield_expression) (expr.data.unary.flags & 1) != 0 else false;
                        const new_value = if (!value_idx.isNone()) try self.visitNode(value_idx) else NodeIndex.none;
                        // yield* → [5, iter], yield/await → [4, value]
                        const opcode: OpCode = if (is_delegate) .yield_star else .yield_op;
                        try ops.append(self.allocator, .{ .code = opcode, .arg = .{ .node = new_value } });
                        next_label.* += 1;
                        try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                        // _state.sent() — resume 시 throw된 에러를 발생시키기 위해 필수
                        const sent_stmt = try buildSentExprStmt(self, stmt.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = sent_stmt } });
                    } else if (expr.tag == .assignment_expression) {
                        // x = yield value / x = await value 패턴 감지
                        const right_idx = expr.data.binary.right;
                        const right = self.old_ast.getNode(right_idx);
                        if (right.tag == .yield_expression or right.tag == .await_expression) {
                            const yield_value_idx = right.data.unary.operand;
                            const new_yield_value = if (!yield_value_idx.isNone()) try self.visitNode(yield_value_idx) else NodeIndex.none;
                            try ops.append(self.allocator, .{ .code = .yield_op, .arg = .{ .node = new_yield_value } });
                            next_label.* += 1;
                            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                            const new_left = try self.visitNode(expr.data.binary.left);
                            const sent_call = try buildSentCall(self, stmt.span);
                            const assign_stmt = try makeDestructuringAssignStmt(self, new_left, sent_call, stmt.span);
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                        } else {
                            const new_stmt = try self.visitNode(stmt_idx);
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    } else {
                        const new_stmt = try self.visitNode(stmt_idx);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    }
                },
                .return_statement => {
                    const value_idx = stmt.data.unary.operand;
                    if (!value_idx.isNone()) {
                        const value_node = self.old_ast.getNode(value_idx);
                        if (value_node.tag == .yield_expression or value_node.tag == .await_expression) {
                            // return yield/await x → yield x + return _state.sent()
                            const inner_value = value_node.data.unary.operand;
                            const new_inner = if (!inner_value.isNone()) try self.visitNode(inner_value) else NodeIndex.none;
                            const is_delegate = if (value_node.tag == .yield_expression) (value_node.data.unary.flags & 1) != 0 else false;
                            const opcode: OpCode = if (is_delegate) .yield_star else .yield_op;
                            try ops.append(self.allocator, .{ .code = opcode, .arg = .{ .node = new_inner } });
                            next_label.* += 1;
                            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                            const sent = try buildSentCall(self, stmt.span);
                            try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = sent } });
                        } else {
                            const new_value = try self.visitNode(value_idx);
                            try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = new_value } });
                        }
                    } else {
                        try ops.append(self.allocator, .{ .code = .return_op, .arg = .{ .node = NodeIndex.none } });
                    }
                },
                .variable_declaration => {
                    // 모든 var는 호이스팅됨. init를 assignment로 변환.
                    try collectVarDeclWithYield(self, stmt, ops, next_label);
                },
                .if_statement => {
                    try collectIfOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .for_statement => {
                    try collectForOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .while_statement => {
                    try collectWhileOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .do_while_statement => {
                    try collectDoWhileOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .try_statement => {
                    try collectTryOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .labeled_statement => {
                    try collectLabeledOperations(self, stmt, ops, next_label);
                },
                .switch_statement => {
                    try collectSwitchOperations(self, stmt_idx, stmt, ops, next_label);
                },
                .break_statement, .continue_statement => {
                    const label_idx = stmt.data.unary.operand;
                    if (!label_idx.isNone() and self.generator_label_stack.items.len > 0) {
                        const label_node = self.old_ast.getNode(label_idx);
                        const label_text = self.old_ast.source[label_node.span.start..label_node.span.end];
                        const stack = self.generator_label_stack.items;
                        var found = false;
                        var i = stack.len;
                        while (i > 0) {
                            i -= 1;
                            if (std.mem.eql(u8, stack[i].name, label_text)) {
                                const target = if (stmt.tag == .continue_statement)
                                    stack[i].continue_label orelse stack[i].break_label
                                else
                                    stack[i].break_label;
                                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = target } });
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            const new_stmt = try self.visitNode(stmt_idx);
                            if (!new_stmt.isNone()) {
                                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                            }
                        }
                    } else {
                        const new_stmt = try self.visitNode(stmt_idx);
                        if (!new_stmt.isNone()) {
                            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                        }
                    }
                },
                else => {
                    const new_stmt = try self.visitNode(stmt_idx);
                    if (!new_stmt.isNone()) {
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                    }
                },
            }
        }

        /// if문의 연산 수집.
        fn collectIfOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.ternary.a;
            const then_body = stmt.data.ternary.b;
            const else_body = stmt.data.ternary.c;

            // yield가 if 안에 있는지 빠른 체크
            const has_yield = containsYield(self, then_body) or containsYield(self, else_body);
            // yield 없어도 return/break/continue가 있으면 ops로 처리해야 함
            // (generator 컨텍스트에서 return → return [2]로 변환 필요)
            if (!has_yield and !containsReturn(self, then_body) and !containsReturn(self, else_body)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            const new_cond = try self.visitNode(condition);
            const has_else = !else_body.isNone();
            // else 없으면 else_label 할당하지 않음 (nop 수와 label 수 일치)
            const else_label = if (has_else) blk: {
                const l = next_label.*;
                next_label.* += 1;
                break :blk l;
            } else @as(u32, 0);
            const end_label = next_label.*;
            next_label.* += 1;

            // if (!cond) goto else_label or end_label
            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{
                    .label = if (has_else) else_label else end_label,
                    .node = new_cond,
                } },
            });

            // then body
            try collectBodyOperations(self, then_body, ops, next_label);

            // goto end (then body가 return/break로 끝나면 생략 — dead code 방지)
            if (ops.items.len == 0 or (ops.items[ops.items.len - 1].code != .return_op and ops.items[ops.items.len - 1].code != .break_op)) {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = end_label } });
            }

            // else label
            if (!else_body.isNone()) {
                // mark else_label (nop으로 case 경계)
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
                try collectBodyOperations(self, else_body, ops, next_label);
            }

            // mark end_label
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// for문의 연산 수집.
        fn collectForOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const extras = self.old_ast.extra_data.items;
            const e = stmt.data.extra;
            const init_idx: NodeIndex = @enumFromInt(extras[e]);
            const test_idx: NodeIndex = @enumFromInt(extras[e + 1]);
            const update_idx: NodeIndex = @enumFromInt(extras[e + 2]);
            const body_idx: NodeIndex = @enumFromInt(extras[e + 3]);

            if (!containsYield(self, body_idx)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // init: var는 호이스팅 후 assignment로 변환, expression은 그대로
            if (!init_idx.isNone()) {
                const init_node = self.old_ast.getNode(init_idx);
                if (init_node.tag == .variable_declaration) {
                    // var i = 0 → i = 0 (var는 이미 호이스팅됨)
                    try collectVarDeclWithYield(self, init_node, ops, next_label);
                } else {
                    const new_init = try self.visitNode(init_idx);
                    if (!new_init.isNone()) {
                        const init_stmt = try es_helpers.makeExprStmt(self, new_init, stmt.span);
                        try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = init_stmt } });
                    }
                }
            }

            // cond_label만 미리 할당. end_label은 body 처리 후 결정 (sentinel+fixup).
            const cond_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            // test (end_label은 sentinel — body 처리 후 fixup)
            const for_end_sent = LABEL_SENTINEL_BASE; // for loop 전용 sentinel
            const for_ops_start = ops.items.len;
            if (!test_idx.isNone()) {
                const new_test = try self.visitNode(test_idx);
                try ops.append(self.allocator, .{
                    .code = .break_when_false,
                    .arg = .{ .label_and_node = .{ .label = for_end_sent, .node = new_test } },
                });
            }

            // body
            try collectBodyOperations(self, body_idx, ops, next_label);

            // update (별도 label — labeled continue의 대상)
            const update_label = next_label.*;
            next_label.* += 1;
            self.generator_for_update_label = update_label;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark update_label
            if (!update_idx.isNone()) {
                const new_update = try self.visitNode(update_idx);
                if (!new_update.isNone()) {
                    const update_stmt = try es_helpers.makeExprStmt(self, new_update, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = update_stmt } });
                }
            }

            // goto cond_label
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = cond_label } });

            // end_label: body 처리 완료 후 할당
            const end_label = next_label.*;
            next_label.* += 1;

            // fixup: for_end_sent → end_label
            fixupSentinel(ops.items[for_ops_start..], for_end_sent, end_label);

            // mark end_label
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// while문의 연산 수집.
        fn collectWhileOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            if (!containsYield(self, body_idx)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            const cond_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark cond_label

            // end_label을 sentinel로 설정 (body 처리 후 실제 값으로 fixup)
            const cond_false_idx = ops.items.len;
            const new_cond = try self.visitNode(condition);
            try ops.append(self.allocator, .{
                .code = .break_when_false,
                .arg = .{ .label_and_node = .{ .label = 0, .node = new_cond } }, // placeholder
            });

            // body (yield가 nop를 생성하여 next_label이 증가할 수 있음)
            try collectBodyOperations(self, body_idx, ops, next_label);

            // goto cond_label
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = cond_label } });

            // end_label을 body 처리 후에 할당 (yield로 인한 label 증가 반영)
            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark end_label

            // break_when_false의 label을 실제 end_label로 fixup
            ops.items[cond_false_idx].arg = .{ .label_and_node = .{ .label = end_label, .node = new_cond } };
        }

        const LABEL_SENTINEL_BASE = std.math.maxInt(u32);

        /// nesting depth에 따라 고유한 break/continue sentinel 생성.
        /// 중첩 labeled scope에서 sentinel 충돌을 방지.
        fn breakSentinel(depth: usize) u32 {
            return LABEL_SENTINEL_BASE - @as(u32, @intCast(depth * 2));
        }
        fn continueSentinel(depth: usize) u32 {
            return LABEL_SENTINEL_BASE - @as(u32, @intCast(depth * 2)) - 1;
        }

        /// ops 슬라이스에서 sentinel 값을 실제 label로 교체.
        fn fixupSentinel(ops_slice: []Operation, sentinel: u32, actual: u32) void {
            for (ops_slice) |*op| {
                switch (op.code) {
                    .break_op => {
                        if (op.arg == .label and op.arg.label == sentinel) {
                            op.arg = .{ .label = actual };
                        }
                    },
                    .break_when_false, .break_when_true => {
                        if (op.arg == .label_and_node and op.arg.label_and_node.label == sentinel) {
                            op.arg = .{ .label_and_node = .{ .label = actual, .node = op.arg.label_and_node.node } };
                        }
                    },
                    else => {},
                }
            }
        }

        /// labeled statement의 연산 수집.
        /// break/continue label은 body 처리 후에 결정 (sentinel+fixup).
        fn collectLabeledOperations(self: *Transformer, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const label_idx = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            const label_name = if (!label_idx.isNone()) blk: {
                const label_node = self.old_ast.getNode(label_idx);
                break :blk self.old_ast.source[label_node.span.start..label_node.span.end];
            } else "";

            const body_node = self.old_ast.getNode(body_idx);
            const is_loop = body_node.tag == .for_statement or
                body_node.tag == .while_statement or
                body_node.tag == .do_while_statement or
                body_node.tag == .for_in_statement or
                body_node.tag == .for_of_statement;

            const is_for = body_node.tag == .for_statement;
            const depth = self.generator_label_stack.items.len;
            const break_sent = breakSentinel(depth);
            const continue_sent = continueSentinel(depth);

            const continue_label: ?u32 = if (!is_loop)
                null
            else if (is_for)
                continue_sent // for loop: body 처리 후 fixup
            else
                next_label.*; // while/do-while: cond_label

            const ops_start = ops.items.len;
            const saved_update_label = self.generator_for_update_label;
            self.generator_for_update_label = null;

            try self.generator_label_stack.append(self.allocator, .{
                .name = label_name,
                .break_label = break_sent,
                .continue_label = continue_label,
            });

            try collectOperations(self, body_idx, ops, next_label);

            _ = self.generator_label_stack.pop();

            const actual_continue = if (is_for) self.generator_for_update_label orelse @as(u32, 0) else @as(u32, 0);
            self.generator_for_update_label = saved_update_label;

            const end_label = next_label.*;
            next_label.* += 1;

            // fixup: break sentinel → end_label, continue sentinel → actual_continue
            const ops_slice = ops.items[ops_start..];
            fixupSentinel(ops_slice, break_sent, end_label);
            if (is_for) {
                fixupSentinel(ops_slice, continue_sent, actual_continue);
            }

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });
        }

        /// switch문의 연산 수집.
        /// switch(x) { case 1: yield a; break; default: yield b; }
        /// → if-else 체인으로 분해 + 각 case body를 순서대로 배치.
        /// case_labels는 sentinel+fixup으로 body 처리 후 결정.
        fn collectSwitchOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const all_extras = self.old_ast.extra_data.items;
            const e = stmt.data.extra;
            const disc_idx: NodeIndex = @enumFromInt(all_extras[e]);
            const cases_start_val = all_extras[e + 1];
            const cases_len_val = all_extras[e + 2];

            if (!containsYield(self, stmt_idx)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            const new_disc = try self.visitNode(disc_idx);
            const cases = all_extras[cases_start_val .. cases_start_val + cases_len_val];

            // 각 case에 고유 sentinel 할당 (body 처리 후 실제 label로 fixup)
            const sentinel_base = LABEL_SENTINEL_BASE - 100; // 충분히 떨어진 sentinel 영역
            var case_sentinels = try self.allocator.alloc(u32, cases.len);
            defer self.allocator.free(case_sentinels);
            var default_case_idx: ?usize = null;

            for (cases, 0..) |raw_idx, i| {
                case_sentinels[i] = sentinel_base - @as(u32, @intCast(i));

                // default case 감지
                const case_node = self.old_ast.getNode(@enumFromInt(raw_idx));
                const ce = case_node.data.extra;
                const test_idx: NodeIndex = @enumFromInt(all_extras[ce]);
                if (test_idx.isNone()) {
                    default_case_idx = i;
                }
            }

            const end_sentinel = sentinel_base - @as(u32, @intCast(cases.len));
            const ops_start = ops.items.len;

            // 분기 코드: if (disc === caseTest) goto case_sentinel
            for (cases, 0..) |raw_idx, i| {
                const case_node = self.old_ast.getNode(@enumFromInt(raw_idx));
                const ce = case_node.data.extra;
                const test_idx: NodeIndex = @enumFromInt(all_extras[ce]);

                if (test_idx.isNone()) continue; // default

                const new_test = try self.visitNode(test_idx);
                const eq_check = try self.new_ast.addNode(.{
                    .tag = .binary_expression,
                    .span = stmt.span,
                    .data = .{ .binary = .{
                        .left = new_disc,
                        .right = new_test,
                        .flags = @intFromEnum(token_mod.Kind.eq3),
                    } },
                });

                try ops.append(self.allocator, .{
                    .code = .break_when_true,
                    .arg = .{ .label_and_node = .{ .label = case_sentinels[i], .node = eq_check } },
                });
            }

            // default가 있으면 goto default, 없으면 goto end
            if (default_case_idx) |di| {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = case_sentinels[di] } });
            } else {
                try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = end_sentinel } });
            }

            // 각 case body 출력 + 실제 label 할당
            var actual_labels = try self.allocator.alloc(u32, cases.len);
            defer self.allocator.free(actual_labels);

            for (cases, 0..) |raw_idx, i| {
                // case body 시작 지점에 실제 label 할당
                actual_labels[i] = next_label.*;
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                const case_node = self.old_ast.getNode(@enumFromInt(raw_idx));
                const ce = case_node.data.extra;
                const stmts_s = all_extras[ce + 1];
                const stmts_l = all_extras[ce + 2];
                const case_stmts = all_extras[stmts_s .. stmts_s + stmts_l];

                for (case_stmts) |case_stmt_raw| {
                    const case_stmt = self.old_ast.getNode(@enumFromInt(case_stmt_raw));
                    if (case_stmt.tag == .break_statement and case_stmt.data.unary.operand.isNone()) {
                        try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = end_sentinel } });
                    } else {
                        try collectOperations(self, @enumFromInt(case_stmt_raw), ops, next_label);
                    }
                }
            }

            // end label
            const actual_end = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            // fixup: sentinel → actual labels
            const ops_slice = ops.items[ops_start..];
            for (case_sentinels, 0..) |sent, i| {
                fixupSentinel(ops_slice, sent, actual_labels[i]);
            }
            fixupSentinel(ops_slice, end_sentinel, actual_end);
        }

        /// do-while문의 연산 수집. body → condition 순서.
        fn collectDoWhileOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const condition = stmt.data.binary.left;
            const body_idx = stmt.data.binary.right;

            if (!containsYield(self, body_idx)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            const body_label = next_label.*;
            next_label.* += 1;

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } }); // mark body_label

            // body
            try collectBodyOperations(self, body_idx, ops, next_label);

            // condition → if true, goto body_label
            const new_cond = try self.visitNode(condition);
            try ops.append(self.allocator, .{
                .code = .break_when_true,
                .arg = .{ .label_and_node = .{ .label = body_label, .node = new_cond } },
            });
        }

        /// try/catch/finally 안의 yield를 상태 머신으로 변환.
        /// try_statement: ternary { a=block, b=catch_clause, c=finally_block }
        /// catch_clause: binary { left=param, right=body }
        ///
        /// 변환 패턴:
        ///   _state.trys.push([try_label, catch_label, finally_label, end_label])
        ///   try body → yield points
        ///   goto end
        ///   catch: param = _state.sent(); catch body
        ///   finally: finally body + return [7] (endfinally)
        fn collectTryOperations(self: *Transformer, stmt_idx: NodeIndex, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const try_body = stmt.data.ternary.a;
            const catch_clause = stmt.data.ternary.b;
            const finally_body = stmt.data.ternary.c;

            // yield가 없으면 그대로 visit
            if (!containsYield(self, try_body) and !containsYield(self, catch_clause) and !containsYield(self, finally_body)) {
                const new_stmt = try self.visitNode(stmt_idx);
                if (!new_stmt.isNone()) {
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = new_stmt } });
                }
                return;
            }

            // try_label = 현재 case 번호. next_label은 1에서 시작하고
            // 각 nop append 직전에 +1되므로, next_label - 1 == 현재 case 번호.
            const try_label = next_label.* - 1;

            // trys.push placeholder — body 처리 후 실제 label로 교체
            const trys_push_slot = ops.items.len;
            try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = .none } });

            try collectBodyOperations(self, try_body, ops, next_label);

            const catch_label = next_label.*;
            next_label.* += 1;

            // try body 끝 break placeholder
            const try_break_slot = ops.items.len;
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = 0 } });

            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            if (!catch_clause.isNone()) {
                const catch_node = self.old_ast.getNode(catch_clause);
                const catch_param = catch_node.data.binary.left;
                const catch_body_idx = catch_node.data.binary.right;

                if (!catch_param.isNone()) {
                    const new_param = try self.visitNode(catch_param);
                    const sent = try buildSentCall(self, stmt.span);
                    const assign = try self.new_ast.addNode(.{
                        .tag = .assignment_expression,
                        .span = stmt.span,
                        .data = .{ .binary = .{ .left = new_param, .right = sent, .flags = 0 } },
                    });
                    const assign_stmt = try es_helpers.makeExprStmt(self, assign, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                }

                try collectBodyOperations(self, catch_body_idx, ops, next_label);
            }

            // catch body 끝 break placeholder
            const catch_break_slot = ops.items.len;
            try ops.append(self.allocator, .{ .code = .break_op, .arg = .{ .label = 0 } });

            var finally_label: ?u32 = null;
            if (!finally_body.isNone()) {
                finally_label = next_label.*;
                next_label.* += 1;
                try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                try collectBodyOperations(self, finally_body, ops, next_label);

                const endfinally_ret = try buildInstructionReturn(self, 7, .none, stmt.span);
                try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = endfinally_ret } });
            }

            const end_label = next_label.*;
            next_label.* += 1;
            try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

            // fixup: try/catch body 끝 → 항상 end_label로 break.
            // finally가 있으면 __generator 런타임이 _.label < t[2] 체크로
            // finally로 자동 우회 + _.ops.push(op)로 원래 목적지 보존.
            ops.items[try_break_slot] = .{ .code = .break_op, .arg = .{ .label = end_label } };
            ops.items[catch_break_slot] = .{ .code = .break_op, .arg = .{ .label = end_label } };

            const actual_finally = finally_label orelse end_label;
            const trys_push = try buildTrysPush(self, try_label, catch_label, actual_finally, end_label, stmt.span);
            ops.items[trys_push_slot] = .{ .code = .statement, .arg = .{ .node = trys_push } };
        }

        /// _state.trys.push([try_label, catch_label, finally_label, end_label]) expression_statement 생성.
        fn buildTrysPush(self: *Transformer, try_label: u32, catch_label: u32, finally_label: u32, end_label: u32, span: Span) Transformer.Error!NodeIndex {
            const state_ref = try es_helpers.makeIdentifierRef(self, "_state");

            // _state.trys
            const trys_prop = try es_helpers.makeIdentifierRef(self, "trys");
            const trys_member = try es_helpers.makeStaticMember(self, state_ref, trys_prop, span);

            // _state.trys.push
            const push_prop = try es_helpers.makeIdentifierRef(self, "push");
            const push_member = try es_helpers.makeStaticMember(self, trys_member, push_prop, span);

            // [try_label, catch_label, finally_label, end_label] 배열 (TypeScript __generator 스펙)
            const n0 = try es_helpers.makeNumericLiteral(self, try_label);
            const n1 = try es_helpers.makeNumericLiteral(self, catch_label);
            const n2 = try es_helpers.makeNumericLiteral(self, finally_label);
            const n3 = try es_helpers.makeNumericLiteral(self, end_label);
            const arr_list = try self.new_ast.addNodeList(&.{ n0, n1, n2, n3 });
            const arr = try self.new_ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_list },
            });

            // _state.trys.push([...])
            const call = try es_helpers.makeCallExpr(self, push_member, &.{arr}, span);
            return es_helpers.makeExprStmt(self, call, span);
        }

        /// generator body에서 모든 var 선언의 binding name을 수집 (호이스팅).
        /// let/const는 block-scoped이므로 호이스팅하지 않음 (ES2015 변환에서 var로 바뀌므로 포함).
        /// destructuring 패턴은 개별 identifier로 분해하여 호이스팅.
        /// (var {a, b} = expr → var a, b; 로 호이스팅. var {a, b}; 는 문법 에러)
        fn collectHoistedVars(self: *Transformer, stmts: []const u32, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            for (stmts) |raw_idx| {
                const node = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (node.tag == .variable_declaration) {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    const list_start = extras[e + 1];
                    const list_len = extras[e + 2];
                    const decls = extras[list_start .. list_start + list_len];
                    for (decls) |decl_raw| {
                        const decl = self.old_ast.getNode(@enumFromInt(decl_raw));
                        if (decl.tag != .variable_declarator) continue;
                        const binding: NodeIndex = @enumFromInt(extras[decl.data.extra]);
                        if (!binding.isNone()) {
                            try collectBindingIdentifiers(self, binding, hoisted);
                        }
                    }
                } else if (node.tag == .block_statement or node.tag == .function_body) {
                    const inner = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                    try collectHoistedVars(self, inner, hoisted);
                } else if (node.tag == .if_statement) {
                    // then/else body 재귀
                    try collectHoistedVarFromNode(self, node.data.ternary.b, hoisted);
                    try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
                } else if (node.tag == .for_statement) {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    // init (variable_declaration일 수 있음)
                    try collectHoistedVarFromNode(self, @enumFromInt(extras[e]), hoisted);
                    // body
                    try collectHoistedVarFromNode(self, @enumFromInt(extras[e + 3]), hoisted);
                } else if (node.tag == .while_statement or node.tag == .do_while_statement) {
                    try collectHoistedVarFromNode(self, node.data.binary.right, hoisted);
                } else if (node.tag == .for_in_statement or node.tag == .for_of_statement) {
                    try collectHoistedVarFromNode(self, node.data.ternary.c, hoisted);
                }
            }
        }

        /// 단일 노드에서 호이스팅할 var를 수집 (block이면 재귀).
        fn collectHoistedVarFromNode(self: *Transformer, idx: NodeIndex, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            if (idx.isNone()) return;
            const node = self.old_ast.getNode(idx);
            if (node.tag == .block_statement or node.tag == .function_body) {
                const inner = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                try collectHoistedVars(self, inner, hoisted);
            } else if (node.tag == .variable_declaration) {
                // for-in/for-of의 left가 variable_declaration인 경우
                const extras = self.old_ast.extra_data.items;
                const e = node.data.extra;
                const list_start = extras[e + 1];
                const list_len = extras[e + 2];
                const decls = extras[list_start .. list_start + list_len];
                for (decls) |decl_raw| {
                    const decl = self.old_ast.getNode(@enumFromInt(decl_raw));
                    if (decl.tag != .variable_declarator) continue;
                    const binding: NodeIndex = @enumFromInt(extras[decl.data.extra]);
                    if (!binding.isNone()) {
                        try collectBindingIdentifiers(self, binding, hoisted);
                    }
                }
            }
        }

        /// binding 패턴에서 모든 binding_identifier를 추출.
        /// destructuring 패턴(object_pattern, array_pattern)은 재귀적으로 분해.
        /// `var {a, b}` → `var a, b` (destructuring 없이 개별 identifier로 호이스팅)
        fn collectBindingIdentifiers(self: *Transformer, binding_idx: NodeIndex, hoisted: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            if (binding_idx.isNone()) return;
            const node = self.old_ast.getNode(binding_idx);
            switch (node.tag) {
                .binding_identifier => {
                    const new_binding = try self.visitNode(binding_idx);
                    try hoisted.append(self.allocator, new_binding);
                },
                .object_pattern => {
                    const props = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                    for (props) |raw_idx| {
                        const prop = self.old_ast.getNode(@enumFromInt(raw_idx));
                        if (prop.tag == .binding_property) {
                            // {key: value} → value 쪽에서 identifier 추출
                            try collectBindingIdentifiers(self, prop.data.binary.right, hoisted);
                        } else if (prop.tag == .rest_element or prop.tag == .binding_rest_element) {
                            try collectBindingIdentifiers(self, prop.data.unary.operand, hoisted);
                        } else if (prop.tag == .assignment_pattern) {
                            // {x = default} → x
                            try collectBindingIdentifiers(self, prop.data.binary.left, hoisted);
                        }
                    }
                },
                .array_pattern => {
                    const elements = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                    for (elements) |raw_idx| {
                        const elem_idx: NodeIndex = @enumFromInt(raw_idx);
                        if (elem_idx.isNone()) continue; // array hole
                        try collectBindingIdentifiers(self, elem_idx, hoisted);
                    }
                },
                .assignment_pattern => {
                    // [x = default] → x
                    try collectBindingIdentifiers(self, node.data.binary.left, hoisted);
                },
                .rest_element, .binding_rest_element => {
                    try collectBindingIdentifiers(self, node.data.unary.operand, hoisted);
                },
                else => unreachable,
            }
        }

        /// assignment_expression을 expression_statement로 만들되,
        /// object_pattern이 좌변이면 괄호로 감싸서 block statement와 구분.
        /// ({a, b} = expr); vs {a, b} = expr; (후자는 syntax error)
        fn makeDestructuringAssignStmt(self: *Transformer, lhs: NodeIndex, rhs: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = lhs, .right = rhs, .flags = 0 } },
            });
            const expr = if (self.new_ast.getNode(lhs).tag == .object_pattern)
                try self.new_ast.addNode(.{
                    .tag = .parenthesized_expression,
                    .span = span,
                    .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
                })
            else
                assign;
            return es_helpers.makeExprStmt(self, expr, span);
        }

        /// yield가 있는 variable_declaration의 각 declarator를 개별 연산으로 변환.
        /// var x = yield 1 → yield 1 (op) + x = _state.sent() (op)
        /// var x = expr (no yield) → x = expr (statement op)
        fn collectVarDeclWithYield(self: *Transformer, stmt: Node, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const extras = self.old_ast.extra_data.items;
            const e = stmt.data.extra;
            const list_start = extras[e + 1];
            const list_len = extras[e + 2];
            const decls = extras[list_start .. list_start + list_len];

            for (decls) |decl_raw| {
                const decl = self.old_ast.getNode(@enumFromInt(decl_raw));
                if (decl.tag != .variable_declarator) continue;

                const binding: NodeIndex = @enumFromInt(extras[decl.data.extra]);
                const init_idx: NodeIndex = @enumFromInt(extras[decl.data.extra + 2]);

                if (init_idx.isNone()) continue;

                const init_node = self.old_ast.getNode(init_idx);
                if (init_node.tag == .yield_expression or init_node.tag == .await_expression) {
                    // var x = yield/await value → yield value + x = _state.sent()
                    const yield_val = init_node.data.unary.operand;
                    const new_val = if (!yield_val.isNone()) try self.visitNode(yield_val) else NodeIndex.none;
                    try ops.append(self.allocator, .{ .code = .yield_op, .arg = .{ .node = new_val } });
                    next_label.* += 1;
                    try ops.append(self.allocator, .{ .code = .nop, .arg = .{ .none = {} } });

                    // x = _state.sent()
                    const new_binding = try self.visitNode(binding);
                    const sent_call = try buildSentCall(self, stmt.span);
                    const assign_stmt = try makeDestructuringAssignStmt(self, new_binding, sent_call, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                } else {
                    // var x = expr (no yield) → x = expr
                    const new_binding = try self.visitNode(binding);
                    const new_init = try self.visitNode(init_idx);
                    const assign_stmt = try makeDestructuringAssignStmt(self, new_binding, new_init, stmt.span);
                    try ops.append(self.allocator, .{ .code = .statement, .arg = .{ .node = assign_stmt } });
                }
            }
        }

        /// AST 서브트리에 yield_expression 또는 generator labeled jump가 있는지 체크.
        fn containsYield(self: *const Transformer, idx: NodeIndex) bool {
            if (idx.isNone()) return false;
            const node = self.old_ast.getNode(idx);
            if (node.tag == .yield_expression or node.tag == .await_expression) return true;
            // labeled break/continue: generator label stack에 등록된 label 참조 시 처리 필요
            if ((node.tag == .break_statement or node.tag == .continue_statement) and
                !node.data.unary.operand.isNone() and self.generator_label_stack.items.len > 0)
            {
                const label_node = self.old_ast.getNode(node.data.unary.operand);
                const label_text = self.old_ast.source[label_node.span.start..label_node.span.end];
                for (self.generator_label_stack.items) |entry| {
                    if (std.mem.eql(u8, entry.name, label_text)) return true;
                }
            }
            // function/arrow 경계에서는 중단 (nested generator/arrow의 yield는 다른 스코프)
            if (node.tag == .function_declaration or node.tag == .function_expression or
                node.tag == .arrow_function_expression) return false;

            // 자식 순회
            return switch (node.tag) {
                .block_statement,
                .function_body,
                .array_expression,
                .sequence_expression,
                .formal_parameters,
                .class_body,
                => {
                    const members = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                    for (members) |raw_idx| {
                        if (containsYield(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .expression_statement,
                .return_statement,
                .throw_statement,
                .spread_element,
                .rest_element,
                .parenthesized_expression,
                => containsYield(self, node.data.unary.operand),
                .assignment_expression,
                .binary_expression,
                .logical_expression,
                => containsYield(self, node.data.binary.left) or containsYield(self, node.data.binary.right),
                .conditional_expression,
                .if_statement,
                .for_in_statement,
                .for_of_statement,
                .try_statement,
                => containsYield(self, node.data.ternary.a) or containsYield(self, node.data.ternary.b) or containsYield(self, node.data.ternary.c),
                .catch_clause,
                .while_statement,
                .do_while_statement,
                .labeled_statement,
                => containsYield(self, node.data.binary.left) or containsYield(self, node.data.binary.right),
                .for_statement => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 3 >= extras.len) return false;
                    return containsYield(self, @enumFromInt(extras[e + 3])); // body
                },
                .switch_statement => {
                    // switch_statement: extra = [discriminant, cases.start, cases.len]
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    const cases_start = extras[e + 1];
                    const cases_len = extras[e + 2];
                    const cases = extras[cases_start .. cases_start + cases_len];
                    for (cases) |raw_idx| {
                        if (containsYield(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .switch_case => {
                    // switch_case: extra = [test, stmts_start, stmts_len]
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    const stmts_start = extras[e + 1];
                    const stmts_len = extras[e + 2];
                    const stmts = extras[stmts_start .. stmts_start + stmts_len];
                    for (stmts) |raw_idx| {
                        if (containsYield(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .variable_declaration => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    const list_start = extras[e + 1];
                    const list_len = extras[e + 2];
                    const decls = extras[list_start .. list_start + list_len];
                    for (decls) |raw_idx| {
                        if (containsYield(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .variable_declarator => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    return containsYield(self, @enumFromInt(extras[e + 2])); // init
                },
                else => false,
            };
        }

        /// AST 서브트리에 return_statement가 있는지 체크.
        /// generator 내 if body에서 return이 있으면 collectOperations로 처리해야
        /// return [2]로 변환됨.
        fn containsReturn(self: *const Transformer, idx: NodeIndex) bool {
            if (idx.isNone()) return false;
            const node = self.old_ast.getNode(idx);
            if (node.tag == .return_statement) return true;
            // function/arrow 경계 중단
            if (node.tag == .function_declaration or node.tag == .function_expression or
                node.tag == .arrow_function_expression) return false;

            return switch (node.tag) {
                .block_statement, .function_body => {
                    const members = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
                    for (members) |raw_idx| {
                        if (containsReturn(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .if_statement, .for_in_statement, .for_of_statement => {
                    return containsReturn(self, node.data.ternary.b) or containsReturn(self, node.data.ternary.c);
                },
                .while_statement, .do_while_statement, .labeled_statement => containsReturn(self, node.data.binary.right),
                .for_statement => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 3 >= extras.len) return false;
                    return containsReturn(self, @enumFromInt(extras[e + 3]));
                },
                .switch_statement => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    const cases_start = extras[e + 1];
                    const cases_len = extras[e + 2];
                    const cases = extras[cases_start .. cases_start + cases_len];
                    for (cases) |raw_idx| {
                        if (containsReturn(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .switch_case => {
                    const extras = self.old_ast.extra_data.items;
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    const stmts_start = extras[e + 1];
                    const stmts_len = extras[e + 2];
                    const stmts = extras[stmts_start .. stmts_start + stmts_len];
                    for (stmts) |raw_idx| {
                        if (containsReturn(self, @enumFromInt(raw_idx))) return true;
                    }
                    return false;
                },
                .try_statement => {
                    // try: ternary { a=block, b=catch, c=finally }
                    return containsReturn(self, node.data.ternary.a) or
                        containsReturn(self, node.data.ternary.b) or
                        containsReturn(self, node.data.ternary.c);
                },
                else => false,
            };
        }

        /// expression body (arrow function 등)를 state machine으로 변환.
        /// expression을 implicit return으로 처리.
        fn buildExpressionBodyStateMachine(self: *Transformer, body_idx: NodeIndex, body: Node, span: Span) Transformer.Error!StateMachineResult {
            // expression body는 최대 3개 연산 (yield + nop + return)
            var ops_buf: [3]Operation = undefined;
            var ops_len: usize = 0;

            if (body.tag == .await_expression or body.tag == .yield_expression) {
                // return await/yield x → yield x + return _state.sent()
                const inner_value = body.data.unary.operand;
                const new_inner = if (!inner_value.isNone()) try self.visitNode(inner_value) else NodeIndex.none;
                const is_delegate = if (body.tag == .yield_expression) (body.data.unary.flags & 1) != 0 else false;
                const opcode: OpCode = if (is_delegate) .yield_star else .yield_op;
                ops_buf[0] = .{ .code = opcode, .arg = .{ .node = new_inner } };
                ops_buf[1] = .{ .code = .nop, .arg = .{ .none = {} } };
                const sent = try buildSentCall(self, span);
                ops_buf[2] = .{ .code = .return_op, .arg = .{ .node = sent } };
                ops_len = 3;
            } else {
                // 일반 expression: return expr
                const new_value = try self.visitNode(body_idx);
                ops_buf[0] = .{ .code = .return_op, .arg = .{ .node = new_value } };
                ops_len = 1;
            }

            const switch_node = try buildSwitchFromOps(self, ops_buf[0..ops_len], span);
            return .{ .body = switch_node, .var_decl = .none };
        }

        /// 연산 리스트를 switch case로 변환.
        fn buildSwitchFromOps(self: *Transformer, ops: []const Operation, span: Span) Transformer.Error!NodeIndex {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var case_num: u32 = 0;
            // label = case number 직접 사용 (nop 순서대로 번호 매김)
            var current_case_stmts: std.ArrayList(NodeIndex) = .empty;
            defer current_case_stmts.deinit(self.allocator);

            for (ops) |op| {
                switch (op.code) {
                    .nop => {
                        // fall-through 방지: __generator는 label로 case를 추적하므로
                        // fall-through 시 label과 실행 위치가 불일치하여 무한루프.
                        // .return_statement 하나만 체크해도 충분: yield_op, return_op,
                        // break_op 모두 buildInstructionReturn을 거쳐 return_statement 생성.
                        if (current_case_stmts.items.len > 0) {
                            const next_case = case_num + 1;
                            const last_node = self.new_ast.getNode(current_case_stmts.items[current_case_stmts.items.len - 1]);
                            if (last_node.tag != .return_statement) {
                                const jump = try buildInstructionReturn(self, 3, try es_helpers.makeNumericLiteral(self, next_case), span);
                                try current_case_stmts.append(self.allocator, jump);
                            }
                        }
                        const case_node = try buildSwitchCase(self, case_num, current_case_stmts.items, span);
                        try self.scratch.append(self.allocator, case_node);
                        current_case_stmts.clearRetainingCapacity();
                        case_num += 1;
                    },
                    .statement => {
                        if (op.arg == .node and !op.arg.node.isNone()) {
                            try current_case_stmts.append(self.allocator, op.arg.node);
                        }
                    },
                    .yield_op => {
                        // return [4, value]
                        const ret = try buildInstructionReturn(self, 4, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                        // case 마무리 (다음 nop에서 새 case가 시작됨)
                    },
                    .return_op => {
                        // return [2, value]
                        const ret = try buildInstructionReturn(self, 2, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                    .break_op => {
                        // return [3, label]
                        const label = if (op.arg == .label) op.arg.label else 0;
                        const label_node = try es_helpers.makeNumericLiteral(self, label);
                        const ret = try buildInstructionReturn(self, 3, label_node, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                    .break_when_false => {
                        if (op.arg == .label_and_node) {
                            const stmt = try buildConditionalBreak(self, op.arg.label_and_node.label, op.arg.label_and_node.node, true, span);
                            try current_case_stmts.append(self.allocator, stmt);
                        }
                    },
                    .break_when_true => {
                        if (op.arg == .label_and_node) {
                            const stmt = try buildConditionalBreak(self, op.arg.label_and_node.label, op.arg.label_and_node.node, false, span);
                            try current_case_stmts.append(self.allocator, stmt);
                        }
                    },
                    .yield_star => {
                        // return [5, iter]
                        const ret = try buildInstructionReturn(self, 5, if (op.arg == .node) op.arg.node else .none, span);
                        try current_case_stmts.append(self.allocator, ret);
                    },
                }
            }

            // 마지막 case
            if (current_case_stmts.items.len > 0) {
                const case_node = try buildSwitchCase(self, case_num, current_case_stmts.items, span);
                try self.scratch.append(self.allocator, case_node);
            }

            // switch(_state.label) { cases... }
            const state_ref = try es_helpers.makeIdentifierRef(self, "_state");
            const label_prop = try es_helpers.makeIdentifierRef(self, "label");
            const discriminant = try es_helpers.makeStaticMember(self, state_ref, label_prop, span);

            // switch_statement: extra = [discriminant, cases_start, cases_len]
            const cases_list = try self.new_ast.addNodeList(self.scratch.items[scratch_top..]);
            const switch_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(discriminant),
                cases_list.start,
                cases_list.len,
            });
            return self.new_ast.addNode(.{
                .tag = .switch_statement,
                .span = span,
                .data = .{ .extra = switch_extra },
            });
        }

        /// block_statement이면 내부 문들을 순회, 아니면 단일 문으로 collectOperations.
        fn collectBodyOperations(self: *Transformer, body_idx: NodeIndex, ops: *std.ArrayList(Operation), next_label: *u32) Transformer.Error!void {
            const body_node = self.old_ast.getNode(body_idx);
            if (body_node.tag == .block_statement) {
                const stmts = self.old_ast.extra_data.items[body_node.data.list.start .. body_node.data.list.start + body_node.data.list.len];
                for (stmts) |raw_idx| {
                    try collectOperations(self, @enumFromInt(raw_idx), ops, next_label);
                }
            } else {
                try collectOperations(self, body_idx, ops, next_label);
            }
        }

        /// 조건부 break: if (cond) return [3, label] 또는 if (!cond) return [3, label].
        /// negate=true이면 조건을 !로 반전.
        fn buildConditionalBreak(self: *Transformer, label: u32, cond: NodeIndex, negate: bool, span: Span) Transformer.Error!NodeIndex {
            const final_cond = if (negate) blk: {
                const paren_cond = try self.new_ast.addNode(.{
                    .tag = .parenthesized_expression,
                    .span = span,
                    .data = .{ .unary = .{ .operand = cond, .flags = 0 } },
                });
                break :blk try self.new_ast.addNode(.{
                    .tag = .unary_expression,
                    .span = span,
                    .data = .{ .extra = try self.new_ast.addExtras(&.{
                        @intFromEnum(paren_cond),
                        @intFromEnum(token_mod.Kind.bang),
                    }) },
                });
            } else cond;

            const label_node = try es_helpers.makeNumericLiteral(self, label);
            const break_ret = try buildInstructionReturn(self, 3, label_node, span);
            const if_body_list = try self.new_ast.addNodeList(&.{break_ret});
            const if_body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = if_body_list },
            });
            return self.new_ast.addNode(.{
                .tag = .if_statement,
                .span = span,
                .data = .{ .ternary = .{ .a = final_cond, .b = if_body, .c = .none } },
            });
        }

        /// switch case 노드 생성: case N: stmts...
        /// switch_case: extra = [test_expr, stmts_start, stmts_len]
        fn buildSwitchCase(self: *Transformer, case_num: u32, stmts: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const test_node = try es_helpers.makeNumericLiteral(self, case_num);

            const body_list = try self.new_ast.addNodeList(stmts);
            const case_extra = try self.new_ast.addExtras(&.{
                @intFromEnum(test_node),
                body_list.start,
                body_list.len,
            });

            return self.new_ast.addNode(.{
                .tag = .switch_case,
                .span = span,
                .data = .{ .extra = case_extra },
            });
        }

        /// return [instruction, value] 문 생성.
        pub fn buildInstructionReturn(self: *Transformer, instruction: u32, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const inst_node = try es_helpers.makeNumericLiteral(self, instruction);

            const arr_items = if (!value.isNone())
                try self.new_ast.addNodeList(&.{ inst_node, value })
            else
                try self.new_ast.addNodeList(&.{inst_node});

            const arr = try self.new_ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = arr_items },
            });

            return self.new_ast.addNode(.{
                .tag = .return_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = arr, .flags = 0 } },
            });
        }

        /// _state.sent() 호출 생성.
        fn buildSentCall(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const state_ref = try es_helpers.makeIdentifierRef(self, "_state");
            const sent_prop = try es_helpers.makeIdentifierRef(self, "sent");
            const sent_member = try es_helpers.makeStaticMember(self, state_ref, sent_prop, span);
            return es_helpers.makeCallExpr(self, sent_member, &.{}, span);
        }

        /// _state.sent(); expression_statement 생성.
        /// yield resume 시 throw된 에러를 발생시키기 위해 필요.
        fn buildSentExprStmt(self: *Transformer, span: Span) Transformer.Error!NodeIndex {
            const sent = try buildSentCall(self, span);
            return es_helpers.makeExprStmt(self, sent, span);
        }

        /// _state identifier reference 생성.
        fn buildStateRef(self: *Transformer, _: Span) Transformer.Error!NodeIndex {
            return es_helpers.makeIdentifierRef(self, "_state");
        }

        /// __generator(function(_state) { ... }) 호출 생성.
        /// es2017 결합 변환에서도 호출.
        pub fn buildGeneratorHelperCall(self: *Transformer, switch_body: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            self.runtime_helpers.generator = true;

            // _state 파라미터
            const state_span = try self.new_ast.addString("_state");
            const state_param = try es_helpers.makeBindingIdentifier(self, state_span);

            // function body: switch_body를 block으로 감싸기
            const body_list = try self.new_ast.addNodeList(&.{switch_body});
            const body = try self.new_ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = body_list },
            });

            // function(_state) { ... }
            const params = try self.new_ast.addNodeList(&.{state_param});
            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.new_ast.addExtras(&.{
                none, // anonymous
                params.start,
                params.len,
                @intFromEnum(body),
                0, // flags
                none,
            });
            const func_expr = try self.new_ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            // __generator(func)
            const gen_ref = try es_helpers.makeIdentifierRef(self, "__generator");
            return es_helpers.makeCallExpr(self, gen_ref, &.{func_expr}, span);
        }
    };
}

test "ES2015 generator module compiles" {
    _ = ES2015Generator;
}
