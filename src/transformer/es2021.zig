//! ES2021 다운레벨링: ??= / ||= / &&= (logical assignment)
//!
//! --target < es2021 일 때 활성화.
//! ??= → a ?? (a = b) (또는 target < es2020이면 a != null ? a : (a = b))
//! ||= → a || (a = b)
//! &&= → a && (a = b)
//!
//! 스펙:
//! - ??= / ||= / &&= : https://tc39.es/ecma262/#sec-assignment-operators (ES2021, TC39 Stage 4: 2020-07)
//!                      https://github.com/tc39/proposal-logical-assignment
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerAssign)
//! - oxc: crates/oxc_transformer/src/es2021/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2021(comptime Transformer: type) type {
    return struct {
        /// `a ??= b` → `a ?? (a = b)` (es2021→es2020)
        /// `a ??= b` → `a != null ? a : (a = b)` (→es2019)
        pub fn lowerNullishAssignment(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_left = try self.visitNode(node.data.binary.left);
            const new_right = try self.visitNode(node.data.binary.right);
            const left_copy1 = try self.ast.addNode(self.ast.getNode(new_left));
            self.copySymbolId(new_left, left_copy1);

            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = node.span,
                .data = .{ .binary = .{
                    .left = left_copy1,
                    .right = new_right,
                    .flags = @intFromEnum(token_mod.Kind.eq),
                } },
            });
            const paren_assign = try es_helpers.makeParenExpr(self, assign, node.span);

            if (self.options.unsupported.nullish_coalescing) {
                const left_copy2 = try self.ast.addNode(self.ast.getNode(new_left));
                self.copySymbolId(new_left, left_copy2);
                const null_span = try self.ast.addString("null");
                const null_node = try self.ast.addNode(.{
                    .tag = .null_literal,
                    .span = null_span,
                    .data = .{ .none = 0 },
                });
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
                    .data = .{ .ternary = .{ .a = neq_null, .b = left_copy2, .c = paren_assign } },
                });
            } else {
                return self.ast.addNode(.{
                    .tag = .logical_expression,
                    .span = node.span,
                    .data = .{ .binary = .{
                        .left = new_left,
                        .right = paren_assign,
                        .flags = @intFromEnum(token_mod.Kind.question2),
                    } },
                });
            }
        }

        /// `a ||= b` → `a || (a = b)`, `a &&= b` → `a && (a = b)`
        pub fn lowerLogicalAssignment(self: *Transformer, node: Node, logical_op: token_mod.Kind) Transformer.Error!NodeIndex {
            const new_left = try self.visitNode(node.data.binary.left);
            const new_right = try self.visitNode(node.data.binary.right);
            const left_copy = try self.ast.addNode(self.ast.getNode(new_left));
            self.copySymbolId(new_left, left_copy);

            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = node.span,
                .data = .{ .binary = .{
                    .left = left_copy,
                    .right = new_right,
                    .flags = @intFromEnum(token_mod.Kind.eq),
                } },
            });
            const paren_assign = try es_helpers.makeParenExpr(self, assign, node.span);
            return self.ast.addNode(.{
                .tag = .logical_expression,
                .span = node.span,
                .data = .{ .binary = .{
                    .left = new_left,
                    .right = paren_assign,
                    .flags = @intFromEnum(logical_op),
                } },
            });
        }
    };
}
