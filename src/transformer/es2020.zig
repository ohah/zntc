//! ES2020 다운레벨링: ?? (nullish coalescing) + ?. (optional chaining)
//!
//! --target < es2020 일 때 활성화.
//! ?? → a != null ? a : b
//! ?. → a == null ? void 0 : a.b
//!
//! 스펙:
//! - ?? : https://tc39.es/ecma262/#sec-nullish-coalescing-operator (ES2020, TC39 Stage 4: 2020-01)
//!         https://github.com/tc39/proposal-nullish-coalescing
//! - ?. : https://tc39.es/ecma262/#sec-optional-chains (ES2020, TC39 Stage 4: 2020-01)
//!         https://github.com/tc39/proposal-optional-chaining
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerNullishCoalescing, lowerOptionalChain)
//! - oxc: crates/oxc_transformer/src/es2020/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const helpers = @import("es_helpers.zig");

/// Transformer 타입 (순환 import 방지를 위해 generic)
pub fn ES2020(comptime Transformer: type) type {
    return struct {
        /// `a ?? b` → `a != null ? a : b`
        pub fn lowerNullishCoalescing(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const old_left_idx = node.data.binary.left;
            const simple = helpers.isSimpleIdentifier(self, old_left_idx);

            const new_left = try self.visitNode(old_left_idx);
            const new_right = try self.visitNode(node.data.binary.right);

            const null_span = try self.ast.addString("null");
            const null_node = try self.ast.addNode(.{
                .tag = .null_literal,
                .span = null_span,
                .data = .{ .none = 0 },
            });

            if (simple) {
                const left_copy = try self.ast.addNode(self.ast.getNode(new_left));
                self.copySymbolId(new_left, left_copy);
                const neq_null = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = new_left,
                        .right = null_node,
                        .flags = @intFromEnum(token_mod.Kind.neq),
                    } },
                });
                return self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = node.span,
                    .data = .{ .ternary = .{ .a = neq_null, .b = left_copy, .c = new_right } },
                });
            } else {
                const temp_span = try helpers.makeTempVarSpan(self);
                const temp_ref1 = try helpers.makeTempVarRef(self, temp_span, node.span);
                const assign_node = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = temp_ref1,
                        .right = new_left,
                        .flags = @intFromEnum(token_mod.Kind.eq),
                    } },
                });
                const paren_assign = try helpers.makeParenExpr(self, assign_node, node.span);
                const neq_null = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = paren_assign,
                        .right = null_node,
                        .flags = @intFromEnum(token_mod.Kind.neq),
                    } },
                });
                const temp_ref2 = try helpers.makeTempVarRef(self, temp_span, node.span);
                return self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = node.span,
                    .data = .{ .ternary = .{ .a = neq_null, .b = temp_ref2, .c = new_right } },
                });
            }
        }

        // ================================================================
        // Optional chaining
        // ================================================================

        pub fn findOptionalChainBase(self: *const Transformer, node: Node) ?NodeIndex {
            var current = node;
            while (true) {
                if (hasOptionalFlag(self, current)) return getChainObject(self, current);
                switch (current.tag) {
                    .static_member_expression, .computed_member_expression, .private_field_expression, .call_expression => {
                        const obj_idx = getChainObject(self, current);
                        if (obj_idx.isNone()) return null;
                        current = self.ast.getNode(obj_idx);
                    },
                    else => return null,
                }
            }
        }

        pub fn lowerOptionalChain(self: *Transformer, node: Node, base_idx: NodeIndex) Transformer.Error!NodeIndex {
            const simple = helpers.isSimpleIdentifier(self, base_idx);
            const visited_base = try self.visitNode(base_idx);

            var null_check_base: NodeIndex = undefined;
            var chain_base: NodeIndex = undefined;

            if (simple) {
                null_check_base = visited_base;
                chain_base = try self.ast.addNode(self.ast.getNode(visited_base));
                // symbol_id 전파: 복제된 노드에도 rename이 적용되도록
                self.copySymbolId(visited_base, chain_base);
            } else {
                const temp_span = try helpers.makeTempVarSpan(self);
                const temp_ref1 = try helpers.makeTempVarRef(self, temp_span, node.span);
                const assign_node = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = temp_ref1,
                        .right = visited_base,
                        .flags = @intFromEnum(token_mod.Kind.eq),
                    } },
                });
                null_check_base = try helpers.makeParenExpr(self, assign_node, node.span);
                chain_base = try helpers.makeTempVarRef(self, temp_span, node.span);
            }

            const rebuilt_chain = try rebuildChainNode(self, node, chain_base);
            const eq_null = try helpers.makeEqNull(self, null_check_base, node.span);
            const void_zero = try helpers.makeVoidZero(self, node.span);
            const cond = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = node.span,
                .data = .{ .ternary = .{ .a = eq_null, .b = void_zero, .c = rebuilt_chain } },
            });
            // 괄호로 감싸서 binary expression 안에서 우선순위 보장
            // 예: a?.b !== c?.d → (a == null ? void 0 : a.b) !== (c == null ? void 0 : c.d)
            return helpers.makeParenExpr(self, cond, node.span);
        }

        fn hasOptionalFlag(self: *const Transformer, node: Node) bool {
            const extras = self.ast.extra_data.items;
            switch (node.tag) {
                .static_member_expression, .computed_member_expression, .private_field_expression => {
                    const e = node.data.extra;
                    if (e + 2 >= extras.len) return false;
                    return (extras[e + 2] & ast_mod.MemberFlags.optional_chain) != 0;
                },
                .call_expression => {
                    const e = node.data.extra;
                    if (e + 3 >= extras.len) return false;
                    return (extras[e + 3] & ast_mod.CallFlags.optional_chain) != 0;
                },
                else => return false,
            }
        }

        fn getChainObject(self: *const Transformer, node: Node) NodeIndex {
            const extras = self.ast.extra_data.items;
            const e = node.data.extra;
            return @enumFromInt(extras[e]);
        }

        fn rebuildChainNode(self: *Transformer, old_node: Node, chain_base: NodeIndex) Transformer.Error!NodeIndex {
            switch (old_node.tag) {
                .static_member_expression, .computed_member_expression, .private_field_expression => {
                    const e = old_node.data.extra;
                    const old_obj: NodeIndex = self.readNodeIdx(e, 0);
                    const old_prop: NodeIndex = self.readNodeIdx(e, 1);
                    const flags = self.readU32(e, 2);
                    const is_optional = (flags & ast_mod.MemberFlags.optional_chain) != 0;
                    const new_obj = if (is_optional) chain_base else try rebuildChainNode(self, self.ast.getNode(old_obj), chain_base);
                    const new_prop = try self.visitNode(old_prop);
                    const new_flags = flags & ~ast_mod.MemberFlags.optional_chain;
                    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_obj), @intFromEnum(new_prop), new_flags });
                    return self.ast.addNode(.{ .tag = old_node.tag, .span = old_node.span, .data = .{ .extra = new_extra } });
                },
                .call_expression => {
                    const e = old_node.data.extra;
                    const old_callee: NodeIndex = self.readNodeIdx(e, 0);
                    const args_start = self.readU32(e, 1);
                    const args_len = self.readU32(e, 2);
                    const flags = self.readU32(e, 3);
                    const is_optional = (flags & ast_mod.CallFlags.optional_chain) != 0;
                    const new_callee = if (is_optional) chain_base else try rebuildChainNode(self, self.ast.getNode(old_callee), chain_base);
                    const new_args = try self.visitExtraList(args_start, args_len);
                    const new_flags = flags & ~ast_mod.CallFlags.optional_chain;
                    const new_extra = try self.ast.addExtras(&.{ @intFromEnum(new_callee), new_args.start, new_args.len, new_flags });
                    return self.ast.addNode(.{ .tag = .call_expression, .span = old_node.span, .data = .{ .extra = new_extra } });
                },
                else => unreachable,
            }
        }
    };
}
