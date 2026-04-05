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

pub fn ES2016(comptime Transformer: type) type {
    return struct {
        /// `a ** b` → `Math.pow(a, b)`
        pub fn lowerExponentiation(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_left = try self.visitNode(node.data.binary.left);
            const new_right = try self.visitNode(node.data.binary.right);

            return buildMathPowCall(self, node.span, new_left, new_right);
        }

        /// `a **= b` → `a = Math.pow(a, b)`
        pub fn lowerExponentiationAssignment(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_left = try self.visitNode(node.data.binary.left);
            const new_right = try self.visitNode(node.data.binary.right);

            // Math.pow(a, b) — left를 복사해서 callee의 인자로 사용
            const left_copy = try self.ast.addNode(self.ast.getNode(new_left));
            self.copySymbolId(new_left, left_copy);
            const pow_call = try buildMathPowCall(self, node.span, left_copy, new_right);

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

        /// Math.pow(left, right) 호출 노드를 생성.
        fn buildMathPowCall(self: *Transformer, span: Span, left: NodeIndex, right: NodeIndex) Transformer.Error!NodeIndex {
            // "Math" 식별자
            const math_span = try self.ast.addString("Math");
            const math_node = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = math_span,
                .data = .{ .string_ref = math_span },
            });

            // "pow" 식별자
            const pow_span = try self.ast.addString("pow");
            const pow_node = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = pow_span,
                .data = .{ .string_ref = pow_span },
            });

            // Math.pow (static member expression) — extra = [object, property, flags]
            const member_extra = try self.ast.addExtras(&.{ @intFromEnum(math_node), @intFromEnum(pow_node), 0 });
            const callee = try self.ast.addNode(.{
                .tag = .static_member_expression,
                .span = span,
                .data = .{ .extra = member_extra },
            });

            // 인자 리스트: (left, right)
            const args = try self.ast.addNodeList(&.{ left, right });

            // call_expression: extra = [callee, args_start, args_len, flags]
            const call_extra = try self.ast.addExtras(&.{
                @intFromEnum(callee),
                args.start,
                args.len,
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
