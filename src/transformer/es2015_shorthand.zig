//! ES2015 다운레벨링: shorthand property
//!
//! --target < es2015 일 때 활성화.
//! { x, y } → { x: x, y: y }
//! { method() {} } → method는 object_property가 아닌 method_definition이므로 여기서 미처리.
//!
//! object_property에서 binary.right가 none이면 shorthand.
//! key의 identifier를 복제하여 value로 채워넣는다.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-object-initialiser (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/shorthand_property.rs (~41줄)

const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;

pub fn ES2015Shorthand(comptime Transformer: type) type {
    return struct {
        /// shorthand property를 full form으로 확장한다.
        /// { x } → { x: x }
        ///
        /// key(identifier_reference)를 복제해서 value로 설정.
        pub fn expandShorthand(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const new_key = try self.visitNode(node.data.binary.left);

            // key를 복제하여 value로 사용
            const key_node = self.new_ast.getNode(new_key);
            const new_value = try self.new_ast.addNode(.{
                .tag = .identifier_reference,
                .span = key_node.span,
                .data = .{ .string_ref = key_node.data.string_ref },
            });
            // scope hoisting rename이 value에도 적용되도록 symbol_id 복사.
            // key는 프로퍼티 이름이므로 rename 불필요하나, value는 변수 참조이므로 필요.
            self.copyNewSymbolId(new_key, new_value);

            return self.new_ast.addNode(.{
                .tag = .object_property,
                .span = node.span,
                .data = .{ .binary = .{
                    .left = new_key,
                    .right = new_value,
                    .flags = node.data.binary.flags,
                } },
            });
        }
    };
}

test "ES2015 shorthand module compiles" {
    _ = ES2015Shorthand;
}
