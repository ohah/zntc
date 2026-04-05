//! ES2015 다운레벨링: computed property
//!
//! --target < es2015 일 때 활성화.
//! { a: 1, [k]: v, b: 2 } → (_a = { a: 1 }, _a[k] = v, _a.b = 2, _a)
//!
//! 첫 computed property 이전까지는 일반 object literal에 넣고,
//! 이후 property는 임시 변수에 대한 assignment로 변환한다.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-object-initialiser (ES2015, computed property names)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/computed_props.rs (~458줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2015Computed(comptime Transformer: type) type {
    return struct {
        /// object_expression에 computed property가 있는지 확인한다.
        pub fn hasComputedProperty(self: *const Transformer, node: Node) bool {
            const members = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (members) |raw_idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .object_property) {
                    const key_idx = member.data.binary.left;
                    if (!key_idx.isNone()) {
                        const key = self.old_ast.getNode(key_idx);
                        if (key.tag == .computed_property_key) return true;
                    }
                }
            }
            return false;
        }

        /// computed property가 있는 object_expression을 sequence expression으로 변환.
        ///
        /// { a: 1, [k]: v, b: 2 }
        /// → (_a = { a: 1 }, _a[k] = v, _a.b = 2, _a)
        pub fn lowerComputedProperties(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const members = self.old_ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];

            // 임시 변수 생성
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // Phase 1: 첫 computed property 이전의 property를 일반 object로 수집
            var first_computed: usize = members.len;
            for (members, 0..) |raw_idx, idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));
                if (member.tag == .object_property) {
                    const key_idx = member.data.binary.left;
                    if (!key_idx.isNone()) {
                        const key = self.old_ast.getNode(key_idx);
                        if (key.tag == .computed_property_key) {
                            first_computed = idx;
                            break;
                        }
                    }
                }
            }

            // _a = { prop1, prop2, ... } (computed 이전까지)
            const obj_scratch_top = self.scratch.items.len;
            for (members[0..first_computed]) |raw_idx| {
                const new_member = try self.visitNode(@enumFromInt(raw_idx));
                if (!new_member.isNone()) {
                    try self.scratch.append(self.allocator, new_member);
                }
            }
            const obj_list = try self.new_ast.addNodeList(self.scratch.items[obj_scratch_top..]);
            self.scratch.shrinkRetainingCapacity(obj_scratch_top);

            const obj_node = try self.new_ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = obj_list },
            });

            // _a = { ... }
            const temp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const init_assign = try self.new_ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = temp_ref, .right = obj_node, .flags = 0 } },
            });

            // sequence expression 시작
            const seq_scratch_top = self.scratch.items.len;
            try self.scratch.append(self.allocator, init_assign);

            // Phase 2: computed 이후 property를 assignment로 변환
            for (members[first_computed..]) |raw_idx| {
                const member = self.old_ast.getNode(@enumFromInt(raw_idx));

                if (member.tag == .method_definition or member.tag == .spread_element) {
                    // method_definition은 Object.defineProperty로 변환해야 하나
                    // ES5 환경에서도 method shorthand 없이 동작하므로 현재는 스킵.
                    // spread_element는 es2018 변환이 먼저 처리하므로 여기 도달하지 않음.
                    continue;
                }

                if (member.tag != .object_property) continue;

                const key_idx = member.data.binary.left;
                const val_idx = member.data.binary.right;
                if (key_idx.isNone()) continue;

                const key = self.old_ast.getNode(key_idx);
                const new_val = if (val_idx.isNone())
                    // shorthand → key 복제
                    try self.visitNode(key_idx)
                else
                    try self.visitNode(val_idx);

                // _a[computed_key] = val 또는 _a.key = val
                const member_expr = if (key.tag == .computed_property_key) blk: {
                    // computed: _a[expr]
                    const inner_key = try self.visitNode(key.data.unary.operand);
                    const me = try self.new_ast.addExtras(&.{
                        @intFromEnum(try es_helpers.makeTempVarRef(self, temp_span, temp_span)),
                        @intFromEnum(inner_key),
                        0,
                    });
                    break :blk try self.new_ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = span,
                        .data = .{ .extra = me },
                    });
                } else blk: {
                    // static: _a.key
                    const new_key = try self.visitNode(key_idx);
                    const me = try self.new_ast.addExtras(&.{
                        @intFromEnum(try es_helpers.makeTempVarRef(self, temp_span, temp_span)),
                        @intFromEnum(new_key),
                        0,
                    });
                    break :blk try self.new_ast.addNode(.{
                        .tag = .static_member_expression,
                        .span = span,
                        .data = .{ .extra = me },
                    });
                };

                const assign = try self.new_ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = member_expr, .right = new_val, .flags = 0 } },
                });
                try self.scratch.append(self.allocator, assign);
            }

            // 마지막에 _a 반환
            try self.scratch.append(self.allocator, try es_helpers.makeTempVarRef(self, temp_span, temp_span));

            // (sequence_expression) — 괄호로 감싸야 올바른 우선순위
            const seq_list = try self.new_ast.addNodeList(self.scratch.items[seq_scratch_top..]);
            self.scratch.shrinkRetainingCapacity(seq_scratch_top);

            const seq = try self.new_ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
            return es_helpers.makeParenExpr(self, seq, span);
        }
    };
}

test "ES2015 computed module compiles" {
    _ = ES2015Computed;
}
