//! ES2016 다운레벨링: ** (exponentiation operator)
//!
//! --target < es2016 일 때 활성화.
//! a ** b    → Math.pow(a, b)
//! a **= b   → a = Math.pow(a, b)
//!
//! 스펙:
//! - ** : https://tc39.es/ecma262/#sec-exp-operator (ES2016, TC39 Stage 4)
//!         https://github.com/tc39/proposal-exponentiation-operator
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerExponentiationOperator)
//! - oxc: crates/oxc_transformer/src/es2016/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");

pub fn ES2016(comptime Transformer: type) type {
    return struct {
        /// `a ** b` → `Math.pow(a, b)`
        pub fn lowerExponentiation(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_left = try self.visitNode(node.data.binary.left);
            const new_right = try self.visitNode(node.data.binary.right);
            return es_helpers.makeMathPowCall(self, new_left, new_right, node.span);
        }

        /// `a **= b` → `a = Math.pow(a, b)`
        pub fn lowerExponentiationAssignment(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_left = try self.visitNode(node.data.binary.left);
            const new_right = try self.visitNode(node.data.binary.right);

            // Math.pow(a, b) — left를 복사해서 callee의 인자로 사용
            const left_copy = try self.ast.addNode(self.ast.getNode(new_left));
            self.copySymbolId(new_left, left_copy);
            const pow_call = try es_helpers.makeMathPowCall(self, left_copy, new_right, node.span);

            // a = Math.pow(a, b)
            return self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = node.span,
                .data = .{ .binary = .{
                    .left = new_left,
                    .right = pow_call,
                    .flags = @intFromEnum(token_mod.Kind.eq),
                } },
            });
        }
    };
}
