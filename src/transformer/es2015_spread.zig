//! ES2015 다운레벨링: spread element
//!
//! --target < es2015 일 때 활성화.
//!
//! 함수 호출 spread:
//!   f(...arr)         → f.apply(void 0, arr)
//!   f(a, ...arr)      → f.apply(void 0, [a].concat(arr))
//!   obj.f(...arr)     → obj.f.apply(obj, arr)
//!   obj.f(a, ...arr)  → obj.f.apply(obj, [a].concat(arr))
//!
//! 배열 spread:
//!   [...arr]          → [].concat(arr)
//!   [...arr, x]       → [].concat(arr, [x])
//!   [a, ...arr]       → [a].concat(arr)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-argument-lists (ES2015, spread)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/spread.rs (~545줄)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2015Spread(comptime Transformer: type) type {
    return struct {
        /// call_expression의 인자에 spread가 있는지 확인.
        pub fn hasSpreadArg(self: *const Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            if (e + 3 >= extras.len) return false;
            const args_start = extras[e + 1];
            const args_len = extras[e + 2];
            const args = extras[args_start .. args_start + args_len];
            for (args) |raw_idx| {
                const arg = self.ast.getNode(@enumFromInt(raw_idx));
                if (arg.tag == .spread_element) return true;
            }
            return false;
        }

        /// call_expression의 spread를 .apply()로 변환.
        ///
        /// f(...arr)       → f.apply(void 0, arr)
        /// f(a, ...arr)    → f.apply(void 0, [a].concat(arr))
        /// obj.f(...arr)   → obj.f.apply(obj, arr)
        pub fn lowerSpreadCall(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const span = node.span;

            // extra_data에서 인덱스만 미리 읽기 (visitNode 전에)
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            const args_start = self.ast.extra_data.items[e + 1];
            const args_len = self.ast.extra_data.items[e + 2];

            const new_callee = try self.visitNode(callee_idx);

            // this context: obj.f(...) → obj.f.apply(obj, ...)
            // 단순 f(...) → f.apply(void 0, ...)
            const new_callee_node = self.ast.getNode(new_callee);
            const is_member = new_callee_node.tag == .static_member_expression or
                new_callee_node.tag == .computed_member_expression;

            const this_arg = if (is_member) blk: {
                // 이미 visit된 new_callee에서 obj를 추출 (이중 visit 방지)
                const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[new_callee_node.data.extra]);
                break :blk obj_idx;
            } else try es_helpers.makeVoidZero(self, span);

            // args를 하나의 배열로 조합
            const combined_args = try buildSpreadArgs(self, args_start, args_len, span);

            // callee.apply(this, args)
            const apply_span = try self.ast.addString("apply");
            const apply_prop = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = apply_span,
                .data = .{ .string_ref = apply_span },
            });
            const member_extra = try self.ast.addExtras(&.{
                @intFromEnum(new_callee), @intFromEnum(apply_prop), 0,
            });
            const apply_member = try self.ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = member_extra },
            });

            const call_args = try self.ast.addNodeList(&.{ this_arg, combined_args });
            const call_extra = try self.ast.addExtras(&.{
                @intFromEnum(apply_member),
                call_args.start,
                call_args.len,
                0,
            });
            return self.ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call_extra },
            });
        }

        /// new Foo(...args) → new (Foo.bind.apply(Foo, [null].concat(args)))()
        pub fn lowerSpreadNew(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            const span = node.span;

            // extra_data에서 인덱스만 미리 읽기 (visitNode 전에)
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            const args_start = self.ast.extra_data.items[e + 1];
            const args_len = self.ast.extra_data.items[e + 2];

            const new_callee = try self.visitNode(callee_idx);

            // [null].concat(args) — null을 첫 인자로 추가 (bind의 this)
            const null_span = try self.ast.addString("null");
            const null_node = try self.ast.addNode(.{
                .tag = .null_literal,
                .span = null_span,
                .data = .{ .none = 0 },
            });
            const null_arr_list = try self.ast.addNodeList(&.{null_node});
            const null_arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = null_arr_list },
            });

            // args 조합
            const combined_args = try buildSpreadArgs(self, args_start, args_len, span);

            // [null].concat(combined_args)
            const concat_span = try self.ast.addString("concat");
            const concat_prop = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = concat_span,
                .data = .{ .string_ref = concat_span },
            });
            const concat_me = try self.ast.addExtras(&.{
                @intFromEnum(null_arr), @intFromEnum(concat_prop), 0,
            });
            const concat_member = try self.ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = concat_me },
            });
            const concat_call_args = try self.ast.addNodeList(&.{combined_args});
            const concat_call_extra = try self.ast.addExtras(&.{
                @intFromEnum(concat_member), concat_call_args.start, concat_call_args.len, 0,
            });
            const null_concat = try self.ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = concat_call_extra },
            });

            // Foo.bind
            const bind_span = try self.ast.addString("bind");
            const bind_prop = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = bind_span,
                .data = .{ .string_ref = bind_span },
            });
            const bind_me = try self.ast.addExtras(&.{
                @intFromEnum(new_callee), @intFromEnum(bind_prop), 0,
            });
            const bind_member = try self.ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = bind_me },
            });

            // Foo.bind.apply
            const apply_span = try self.ast.addString("apply");
            const apply_prop = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = apply_span,
                .data = .{ .string_ref = apply_span },
            });
            const apply_me = try self.ast.addExtras(&.{
                @intFromEnum(bind_member), @intFromEnum(apply_prop), 0,
            });
            const apply_member = try self.ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = apply_me },
            });

            // Foo.bind.apply(Foo, [null].concat(args))
            // new_callee를 재사용하지 않고 새 identifier 생성 (AST 노드는 1곳에서만 참조)
            const new_callee_node = self.ast.getNode(new_callee);
            const callee_ref2 = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = new_callee_node.span,
                .data = .{ .string_ref = new_callee_node.data.string_ref },
            });
            const apply_args = try self.ast.addNodeList(&.{ callee_ref2, null_concat });
            const apply_extra = try self.ast.addExtras(&.{
                @intFromEnum(apply_member), apply_args.start, apply_args.len, 0,
            });
            const bind_apply_call = try self.ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = apply_extra },
            });

            // new (Foo.bind.apply(Foo, [null].concat(args)))()
            const empty_new_args = try self.ast.addNodeList(&.{});
            const new_extra = try self.ast.addExtras(&.{
                @intFromEnum(bind_apply_call), empty_new_args.start, empty_new_args.len, 0,
            });
            return self.ast.addNode(.{
                .tag = .new_expression,
                .span = span,
                .data = .{ .extra = new_extra },
            });
        }

        /// array_expression에 spread가 있는지 확인.
        pub fn hasSpreadInArray(self: *const Transformer, node: Node) bool {
            const members = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (members) |raw_idx| {
                const elem = self.ast.getNode(@enumFromInt(raw_idx));
                if (elem.tag == .spread_element) return true;
            }
            return false;
        }

        /// array spread를 [].concat()으로 변환.
        /// [...arr, x] → [].concat(arr, [x])
        pub fn lowerSpreadArray(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const members_start = node.data.list.start;
            const members_len = node.data.list.len;

            // 그룹 분리: spread가 아닌 연속 요소를 배열로, spread는 값만 추출
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var non_spread_top = self.scratch.items.len;

            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < members_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[members_start + i_loop];
                const elem = self.ast.getNode(@enumFromInt(raw_idx));
                if (elem.tag == .spread_element) {
                    // 이전 non-spread 그룹을 배열로 flush
                    if (self.scratch.items.len > non_spread_top) {
                        const group_list = try self.ast.addNodeList(self.scratch.items[non_spread_top..]);
                        self.scratch.shrinkRetainingCapacity(non_spread_top);
                        const group_arr = try self.ast.addNode(.{
                            .tag = .array_expression,
                            .span = span,
                            .data = .{ .list = group_list },
                        });
                        try self.scratch.append(self.allocator, group_arr);
                        non_spread_top = self.scratch.items.len;
                    }
                    // spread 값을 직접 추가 (concat 인자)
                    const visited = try self.visitNode(elem.data.unary.operand);
                    try self.scratch.append(self.allocator, visited);
                    non_spread_top = self.scratch.items.len;
                } else {
                    const visited = try self.visitNode(@enumFromInt(raw_idx));
                    if (!visited.isNone()) {
                        try self.scratch.append(self.allocator, visited);
                    }
                }
            }

            // 마지막 non-spread 그룹 flush
            if (self.scratch.items.len > non_spread_top) {
                const group_list = try self.ast.addNodeList(self.scratch.items[non_spread_top..]);
                self.scratch.shrinkRetainingCapacity(non_spread_top);
                const group_arr = try self.ast.addNode(.{
                    .tag = .array_expression,
                    .span = span,
                    .data = .{ .list = group_list },
                });
                try self.scratch.append(self.allocator, group_arr);
            }

            const concat_args_slice = self.scratch.items[scratch_top..];
            if (concat_args_slice.len == 0) {
                // 빈 배열
                const empty_list = try self.ast.addNodeList(&.{});
                return self.ast.addNode(.{
                    .tag = .array_expression,
                    .span = span,
                    .data = .{ .list = empty_list },
                });
            }

            // [].concat(arg1, arg2, ...)
            return buildConcatCall(self, concat_args_slice, span);
        }

        /// 인자 리스트에서 spread를 펼쳐 하나의 배열 표현식으로 만든다.
        /// (a, ...arr) → [a].concat(arr)
        /// (...arr) → arr
        /// (...arr, b) → [].concat(arr, [b])
        fn buildSpreadArgs(self: *Transformer, ba_start: u32, ba_len: u32, span: Span) Transformer.Error!NodeIndex {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            var non_spread_top = self.scratch.items.len;
            var has_non_spread = false;
            var spread_count: usize = 0;

            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            var i_loop: u32 = 0;
            while (i_loop < ba_len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[ba_start + i_loop];
                const arg = self.ast.getNode(@enumFromInt(raw_idx));
                if (arg.tag == .spread_element) {
                    // 이전 non-spread를 배열로 flush
                    if (self.scratch.items.len > non_spread_top) {
                        const group_list = try self.ast.addNodeList(self.scratch.items[non_spread_top..]);
                        self.scratch.shrinkRetainingCapacity(non_spread_top);
                        const group_arr = try self.ast.addNode(.{
                            .tag = .array_expression,
                            .span = span,
                            .data = .{ .list = group_list },
                        });
                        try self.scratch.append(self.allocator, group_arr);
                        non_spread_top = self.scratch.items.len;
                        has_non_spread = true;
                    }
                    const visited = try self.visitNode(arg.data.unary.operand);
                    try self.scratch.append(self.allocator, visited);
                    non_spread_top = self.scratch.items.len;
                    spread_count += 1;
                } else {
                    const visited = try self.visitNode(@enumFromInt(raw_idx));
                    if (!visited.isNone()) {
                        try self.scratch.append(self.allocator, visited);
                        has_non_spread = true;
                    }
                }
            }

            // 마지막 non-spread 그룹 flush
            if (self.scratch.items.len > non_spread_top) {
                const group_list = try self.ast.addNodeList(self.scratch.items[non_spread_top..]);
                self.scratch.shrinkRetainingCapacity(non_spread_top);
                const group_arr = try self.ast.addNode(.{
                    .tag = .array_expression,
                    .span = span,
                    .data = .{ .list = group_list },
                });
                try self.scratch.append(self.allocator, group_arr);
            }

            const args_slice = self.scratch.items[scratch_top..];

            // 최적화: spread만 1개이고 다른 인자 없으면 그대로 반환
            if (args_slice.len == 1 and spread_count == 1 and !has_non_spread) {
                return args_slice[0];
            }

            return buildConcatCall(self, args_slice, span);
        }

        /// [].concat(args...) 호출을 생성한다.
        fn buildConcatCall(self: *Transformer, args: []const NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // []
            const empty_list = try self.ast.addNodeList(&.{});
            const empty_arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = empty_list },
            });

            // [].concat
            const concat_span = try self.ast.addString("concat");
            const concat_prop = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = concat_span,
                .data = .{ .string_ref = concat_span },
            });
            const member_extra = try self.ast.addExtras(&.{
                @intFromEnum(empty_arr), @intFromEnum(concat_prop), 0,
            });
            const concat_member = try self.ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = member_extra },
            });

            // [].concat(args...)
            const concat_args = try self.ast.addNodeList(args);
            const call_extra = try self.ast.addExtras(&.{
                @intFromEnum(concat_member),
                concat_args.start,
                concat_args.len,
                0,
            });
            return self.ast.addNode(.{
                .tag = .call_expression,
                .span = span,
                .data = .{ .extra = call_extra },
            });
        }
    };
}

test "ES2015 spread module compiles" {
    _ = ES2015Spread;
}
