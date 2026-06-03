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

const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../lexer/token.zig");
const es_helpers = @import("es_helpers.zig");

pub fn ES2021(comptime Transformer: type) type {
    return struct {
        /// `a ??= b` → `a ?? (a = b)` (es2021→es2020)
        /// `a ??= b` → `a != null ? a : (a = b)` (→es2019)
        /// 주의: private field 좌변은 caller(transformer.zig)에서 es2015_class로 먼저 라우팅됨 —
        /// private get/set이 함수 호출이라 여기서 만드는 `(a = b)` 패턴의 assignment target이 될 수 없음.
        pub fn lowerNullishAssignment(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const target = (try es_helpers.prepareAssignmentTargetRef(self, node.data.binary.left, node.span)) orelse unreachable;
            const new_right = try self.visitNode(node.data.binary.right);
            const assign = try es_helpers.makeAssignExpr(self, target.write, new_right, node.span, @intFromEnum(token_mod.Kind.eq));

            if (self.options.unsupported.nullish_coalescing) {
                // ternary lowering 은 condition 과 truthy branch 두 자리에 read 표현을 emit 한다.
                // member access 는 두 자리에 두면 getter 가 두 번 호출되므로 임시 변수에 캡처해야 한다.
                // 그러나 plain identifier 는 부작용이 없어 캡처가 불필요한 noise 다 (#1287 follow-up).
                const read_tag = self.ast.getNode(target.read).tag;
                if (read_tag == .identifier_reference or read_tag == .assignment_target_identifier) {
                    const neq_null = try es_helpers.makeNeqNull(self, target.read, node.span);
                    return self.ast.addNode(.{
                        .tag = .conditional_expression,
                        .span = node.span,
                        .data = .{ .ternary = .{ .a = neq_null, .b = target.value, .c = assign } },
                    });
                }
                const captured = try es_helpers.captureToTemp(self, target.read, node.span);
                const captured_value = try es_helpers.makeTempVarRef(self, captured.span, node.span);
                const neq_null = try es_helpers.makeNeqNull(self, captured.paren_assign, node.span);
                return self.ast.addNode(.{
                    .tag = .conditional_expression,
                    .span = node.span,
                    .data = .{ .ternary = .{ .a = neq_null, .b = captured_value, .c = assign } },
                });
            }

            return self.ast.addNode(.{
                .tag = .logical_expression,
                .span = node.span,
                .data = .{ .binary = .{
                    .left = target.read,
                    .right = assign,
                    .flags = @intFromEnum(token_mod.Kind.question2),
                } },
            });
        }

        /// `a ||= b` → `a || (a = b)`, `a &&= b` → `a && (a = b)`
        /// 주의: private field 좌변은 caller(transformer.zig)에서 es2015_class로 먼저 라우팅됨.
        pub fn lowerLogicalAssignment(self: *Transformer, node: Node, logical_op: token_mod.Kind) Transformer.Error!NodeIndex {
            const target = (try es_helpers.prepareAssignmentTargetRef(self, node.data.binary.left, node.span)) orelse unreachable;
            const new_right = try self.visitNode(node.data.binary.right);
            const assign = try es_helpers.makeAssignExpr(self, target.write, new_right, node.span, @intFromEnum(token_mod.Kind.eq));
            return self.ast.addNode(.{
                .tag = .logical_expression,
                .span = node.span,
                .data = .{ .binary = .{
                    .left = target.read,
                    .right = assign,
                    .flags = @intFromEnum(logical_op),
                } },
            });
        }
    };
}
