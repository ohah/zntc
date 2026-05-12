//! ES2015 다운레벨링: object literal method shorthand
//!
//! --target < es2015 (object_extensions unsupported) 일 때 활성화.
//! 또한 Hermes/RN 처럼 method shorthand 자체는 지원하지만 async/generator 를
//! 다운레벨링해야 하는 타겟에서는 해당 method만 function expression으로 바꾼다.
//! { m() {} } → { m: function() {} }
//! { async a() {} } → { a: function() {} }  (body는 async lowering)
//! { *g() {} } → { g: function*() {} }      (이후 generator lowering)
//! { [k]() {} } → { [k]: function() {} }    (computed_property_key 유지 → es2015_computed가 후처리)
//!
//! getter/setter는 ES5도 지원하므로 변환하지 않음.
//!
//! 동작 방식:
//!   1. object_expression 내 member 리스트를 순회
//!   2. method_definition(getter/setter 제외)를 object_property + function_expression으로 교체
//!   3. computed key는 computed_property_key 노드를 그대로 보존 → 이후 ES2015Computed가 sequence expression으로 변환
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-method-definitions (ES2015 PropertyDefinition: MethodDefinition)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/shorthand_property.rs (단, SWC는 shorthand prop만, method는 별도)
//! - esbuild: internal/js_parser/js_parser.go (lowerMethodShorthand 유사 경로)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;

pub fn ES2015ObjectMethods(comptime Transformer: type) type {
    return struct {
        fn isPlainObjectMethod(flags: u32) bool {
            return (flags & ast_mod.MethodFlags.is_getter) == 0 and
                (flags & ast_mod.MethodFlags.is_setter) == 0;
        }

        fn methodNeedsFunctionLowering(self: *const Transformer, flags: u32) bool {
            if (!isPlainObjectMethod(flags)) return false;
            return self.options.unsupported.object_extensions or
                (self.options.unsupported.async_await and (flags & ast_mod.MethodFlags.is_async) != 0) or
                (self.options.unsupported.generator and (flags & ast_mod.MethodFlags.is_generator) != 0);
        }

        /// object_expression 멤버 중 method_definition이 있는지 확인.
        /// getter/setter(flags 0x02/0x04)는 ES5도 지원하므로 제외.
        pub fn hasObjectMethod(self: *const Transformer, node: Node) bool {
            const members = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (members) |raw_idx| {
                const m = self.ast.getNode(@enumFromInt(raw_idx));
                if (m.tag != .method_definition) continue;
                const flags = self.ast.extra_data.items[m.data.extra + ast_mod.MethodExtra.flags];
                if (!isPlainObjectMethod(flags)) continue;
                return true;
            }
            return false;
        }

        /// 현재 타겟에서 method_definition → object_property + function_expression
        /// 변환이 필요한 멤버가 있는지 확인.
        pub fn needsObjectMethodLowering(self: *const Transformer, node: Node) bool {
            const members = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (members) |raw_idx| {
                const m = self.ast.getNode(@enumFromInt(raw_idx));
                if (m.tag != .method_definition) continue;
                const flags = self.ast.extra_data.items[m.data.extra + ast_mod.MethodExtra.flags];
                if (methodNeedsFunctionLowering(self, flags)) return true;
            }
            return false;
        }

        /// method_definition → object_property { key: function_expression } 로 변환한 object_expression 반환.
        /// function_expression은 async/generator 플래그를 보존하므로, 상위 visitNode가
        /// async_await/generator unsupported일 경우 자동으로 추가 lowering을 수행한다.
        pub fn lowerObjectMethods(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const members_start = node.data.list.start;
            const members_len = node.data.list.len;

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // visitNode가 extra_data를 재할당할 수 있으므로 인덱스 루프 사용.
            var i: u32 = 0;
            while (i < members_len) : (i += 1) {
                const raw_idx = self.ast.extra_data.items[members_start + i];
                const m_idx: NodeIndex = @enumFromInt(raw_idx);
                const m = self.ast.getNode(m_idx);

                if (m.tag != .method_definition) {
                    // 일반 property / spread → 기존 방문 경로
                    const new_m = try self.visitNode(m_idx);
                    if (!new_m.isNone()) try self.scratch.append(self.allocator, new_m);
                    continue;
                }

                const me = m.data.extra;
                const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + ast_mod.MethodExtra.key]);
                const params_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + ast_mod.MethodExtra.params]);
                const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + ast_mod.MethodExtra.body]);
                const flags: u32 = self.ast.extra_data.items[me + ast_mod.MethodExtra.flags];

                // getter/setter 또는 현재 타겟에서 보존 가능한 일반 method는 원본 그대로 방문.
                if (!methodNeedsFunctionLowering(self, flags)) {
                    const new_m = try self.visitNode(m_idx);
                    if (!new_m.isNone()) try self.scratch.append(self.allocator, new_m);
                    continue;
                }

                // method → function 플래그 재매핑 (비트 위치가 다름).
                const fn_flags = ast_mod.methodFlagsToFunctionFlags(flags);

                const none = @intFromEnum(NodeIndex.none);

                // function_expression: [name, params, body, flags, return_type]
                const fn_extra = try self.ast.addExtras(&.{
                    none,
                    @intFromEnum(params_idx),
                    @intFromEnum(body_idx),
                    fn_flags,
                    none,
                });
                const fn_expr = try self.ast.addNode(.{
                    .tag = .function_expression,
                    .span = m.span,
                    .data = .{ .extra = fn_extra },
                });

                // 상위 visitNode를 통해 async/generator lowering 적용
                const new_fn = try self.visitNode(fn_expr);

                // key도 방문 (computed_property_key 내부 expr 등)
                const new_key = try self.visitNode(key_idx);

                const prop = try self.ast.addNode(.{
                    .tag = .object_property,
                    .span = m.span,
                    .data = .{ .binary = .{ .left = new_key, .right = new_fn, .flags = 0 } },
                });
                try self.scratch.append(self.allocator, prop);
            }

            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = new_list },
            });
        }
    };
}

test "ES2015 object methods module compiles" {
    _ = ES2015ObjectMethods;
}
