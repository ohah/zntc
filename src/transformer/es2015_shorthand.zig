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
        /// key 는 property name 이라 block_rename 대상이 아니므로 원본
        /// identifier 를 그대로 복제한다. value 는 변수 참조라 visitNode 로
        /// 변환해 block_scoping / scope hoist rename 을 적용 받아야 한다.
        pub fn expandShorthand(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const left_idx = node.data.binary.left;
            const original_left = self.ast.getNode(left_idx);

            // key: 원본 이름 그대로. property name 이라 rename 대상 아님.
            const new_key = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = original_left.span,
                .data = .{ .string_ref = original_left.data.string_ref },
            });
            // scope hoisting 등 다른 후속 transform 이 symbol 을 따라가도록 복사.
            self.copySymbolId(left_idx, new_key);

            // value: visitNode 가 block_rename / scope hoist 를 적용.
            const new_value = try self.visitNode(left_idx);

            return self.ast.addNode(.{
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
