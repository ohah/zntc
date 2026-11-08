//! ES2018 object spread: operand values are copied as fresh data properties;
//! ordinary groups define their descriptors on the same final target.
//! Object-super methods share that target through their typed home producer.
//!
//! 스펙:
//! - object rest/spread: https://tc39.es/ecma262/#sec-object-initializer (ES2018, TC39 Stage 4: 2018-01)
//!                        https://github.com/tc39/proposal-object-rest-spread
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerObjectSpread)
//! - oxc: crates/oxc_transformer/src/es2018/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const helpers = @import("es_helpers.zig");

/// Transformer 타입 (순환 import 방지를 위해 generic)
pub fn ES2018(comptime Transformer: type) type {
    return struct {
        /// object_expression의 프로퍼티 중 spread_element이 있는지 확인.
        /// 원본 AST를 읽어서 판단한다 (변환 전 스캔).
        pub fn hasSpreadProperty(self: *Transformer, node: Node) bool {
            const indices = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (indices) |raw_idx| {
                const child = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (child.tag == .spread_element) return true;
            }
            return false;
        }

        /// `{ a: 1, ...obj, b: 2 }` → `__spreadProps(__spreadValues({ a: 1 }, obj), { b: 2 })`
        ///
        /// ast의 object_expression을 방문하면서 각 프로퍼티를 visitNode로 변환하고,
        /// 결과를 공통 visited-group finalizer에 넘겨 값 복사와 프로퍼티 정의를 구분한다.
        pub fn lowerObjectSpread(self: *Transformer, source_object: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            const list_start = node.data.list.start;
            const list_len = node.data.list.len;
            const builtin = @import("object_builtin_reference.zig");
            var origins: ?builtin.AccessorOrigins = null;
            defer if (origins) |*batch| batch.deinit(self.allocator);
            if (self.options.unsupported.object_extensions) {
                var members = self.ast.iterateExtraList(node.data.list);
                while (members.next()) |member_idx| {
                    const member = self.ast.getNode(member_idx);
                    if (member.tag == .method_definition and
                        self.ast.readExtra(member.data.extra, @import("../parser/ast.zig").MethodExtra.flags) &
                            (@import("../parser/ast.zig").MethodFlags.is_getter | @import("../parser/ast.zig").MethodFlags.is_setter) != 0)
                    {
                        origins = builtin.AccessorOrigins.init(self, source_object) catch |err| return builtin.productionFailure(err);
                        break;
                    }
                }
            }

            // ast 프로퍼티를 방문하여 ast 노드로 변환
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // while 인덱스 루프: visitNode가 extra_data를 재할당할 수 있으므로 슬라이스 캐시 금지
            var j: u32 = 0;
            while (j < list_len) : (j += 1) {
                const raw_idx = self.ast.extra_data.items[list_start + j];
                const child = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (child.tag == .spread_element) {
                    // spread: 피연산자를 방문하고 ast에 spread_element로 다시 감싸기
                    const operand = try self.visitNode(child.data.unary.operand);
                    const new_spread = try self.ast.addNode(.{
                        .tag = .spread_element,
                        .span = child.span,
                        .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                    });
                    try self.scratch.append(self.allocator, new_spread);
                } else {
                    // non-spread: 자식을 방문하고 추가
                    const new_child = try @import("es2015_object_methods.zig").ES2015ObjectMethods(Transformer).lowerObjectMember(self, @fromBackingInt(@intCast(raw_idx)));
                    if (!new_child.isNone()) {
                        try self.scratch.append(self.allocator, new_child);
                    }
                }
            }

            const new_props = self.scratch.items[scratch_top..];
            // Children have already been visited. Finish method/computed-key
            // syntax through the same source-owned groups as suspension lowering.
            return @import("es2015_computed.zig").ES2015Computed(Transformer).lowerObjectWithVisitedChildren(self, source_object, node, new_props, if (origins) |*batch| batch else null);
        }
    };
}

test "ES2018 module compiles" {
    // 모듈 컴파일 확인용 빈 테스트
    _ = ES2018;
}

test {
    _ = @import("es2018_test.zig");
}
