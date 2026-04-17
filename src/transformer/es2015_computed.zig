//! ES2015 다운레벨링: computed property
//!
//! --target < es2015 일 때 활성화.
//! { a: 1, [k]: v, b: 2 } → (_a = { a: 1 }, _a[k] = v, _a.b = 2, _a)
//!
//! 첫 computed property 이전까지는 일반 object literal에 넣고,
//! 이후 property는 임시 변수에 대한 assignment로 변환한다.
//!
//! getter/setter(method_definition with flags 0x02/0x04)가 computed lowering
//! 경로에 남으면(비computed getter/setter는 Phase 1 object literal에 그대로
//! 유지) Phase 2에서 `Object.defineProperty(_a, key, { get/set, enumerable, configurable })`
//! 호출로 재조립한다.
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

/// method_definition의 extra[3] flags — parser/object.zig + parser/class.zig와 동일.
const METHOD_FLAG_GETTER: u32 = 0x02;
const METHOD_FLAG_SETTER: u32 = 0x04;

pub fn ES2015Computed(comptime Transformer: type) type {
    return struct {
        /// object_expression에 computed key를 가진 member가 있는지 확인한다.
        /// object_property뿐 아니라 method_definition (computed getter/setter/method)도 포함.
        pub fn hasComputedProperty(self: *const Transformer, node: Node) bool {
            const members = self.ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len];
            for (members) |raw_idx| {
                const member = self.ast.getNode(@enumFromInt(raw_idx));
                const key_idx = memberKeyIdx(self, member);
                if (key_idx.isNone()) continue;
                const key = self.ast.getNode(key_idx);
                if (key.tag == .computed_property_key) return true;
            }
            return false;
        }

        /// computed property가 있는 object_expression을 sequence expression으로 변환.
        ///
        /// { a: 1, [k]: v, b: 2 }
        /// → (_a = { a: 1 }, _a[k] = v, _a.b = 2, _a)
        pub fn lowerComputedProperties(self: *Transformer, node: Node) Transformer.Error!NodeIndex {
            const span = node.span;
            const members_start = node.data.list.start;
            const members_len = node.data.list.len;

            // 임시 변수 생성
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // Phase 1: 첫 computed key 이전의 member를 일반 object로 수집
            // 이 루프는 읽기만 하므로 슬라이스 안전.
            var first_computed: usize = members_len;
            {
                const members = self.ast.extra_data.items[members_start .. members_start + members_len];
                for (members, 0..) |raw_idx, idx| {
                    const member = self.ast.getNode(@enumFromInt(raw_idx));
                    const key_idx = memberKeyIdx(self, member);
                    if (key_idx.isNone()) continue;
                    const key = self.ast.getNode(key_idx);
                    if (key.tag == .computed_property_key) {
                        first_computed = idx;
                        break;
                    }
                }
            }

            // _a = { prop1, prop2, ... } (computed 이전까지)
            // visitNode가 AST를 변형하므로 인덱스 루프 사용
            const obj_scratch_top = self.scratch.items.len;
            {
                var i_pre: u32 = 0;
                while (i_pre < @as(u32, @intCast(first_computed))) : (i_pre += 1) {
                    const raw_idx = self.ast.extra_data.items[members_start + i_pre];
                    const new_member = try self.visitNode(@enumFromInt(raw_idx));
                    if (!new_member.isNone()) {
                        try self.scratch.append(self.allocator, new_member);
                    }
                }
            }
            const obj_list = try self.ast.addNodeList(self.scratch.items[obj_scratch_top..]);
            self.scratch.shrinkRetainingCapacity(obj_scratch_top);

            const obj_node = try self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = obj_list },
            });

            // _a = { ... }
            const temp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const init_assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = temp_ref, .right = obj_node, .flags = 0 } },
            });

            // sequence expression 시작
            const seq_scratch_top = self.scratch.items.len;
            try self.scratch.append(self.allocator, init_assign);

            // Phase 2: computed 이후 property/method를 assignment / defineProperty로 변환.
            // visitNode가 AST를 변형하므로 인덱스 루프 사용.
            // accessor용 공통 span은 최초 getter/setter 만났을 때 한 번 생성 (addString이 dedup 안 함).
            var accessor_ctx: ?AccessorSpans = null;
            var i_post: u32 = @intCast(first_computed);
            while (i_post < members_len) : (i_post += 1) {
                const raw_idx = self.ast.extra_data.items[members_start + i_post];
                const member = self.ast.getNode(@enumFromInt(raw_idx));

                if (member.tag == .spread_element) {
                    // spread는 es2018 변환이 먼저 처리하므로 여기 도달하지 않음.
                    continue;
                }

                if (member.tag == .method_definition) {
                    const me = member.data.extra;
                    const flags = self.ast.extra_data.items[me + 3];
                    const is_getter = (flags & METHOD_FLAG_GETTER) != 0;
                    const is_setter = (flags & METHOD_FLAG_SETTER) != 0;
                    // 일반/async/generator 메서드는 es2015_object_methods가 먼저 object_property로 변환한다.
                    // getter/setter 외의 메서드가 여기 도달하면 pass 순서가 깨진 것.
                    std.debug.assert(is_getter or is_setter);
                    if (accessor_ctx == null) accessor_ctx = try makeAccessorSpans(self);
                    const define_call = try emitDefineAccessor(self, member, is_getter, temp_span, span, accessor_ctx.?);
                    try self.scratch.append(self.allocator, define_call);
                    continue;
                }

                if (member.tag != .object_property) continue;

                const key_idx = member.data.binary.left;
                const val_idx = member.data.binary.right;
                if (key_idx.isNone()) continue;

                const key = self.ast.getNode(key_idx);
                const new_val = if (val_idx.isNone())
                    // shorthand → key 복제
                    try self.visitNode(key_idx)
                else
                    try self.visitNode(val_idx);

                // _a[computed_key] = val 또는 _a.key = val
                const member_expr = if (key.tag == .computed_property_key) blk: {
                    // computed: _a[expr]
                    const inner_key = try self.visitNode(key.data.unary.operand);
                    const me = try self.ast.addExtras(&.{
                        @intFromEnum(try es_helpers.makeTempVarRef(self, temp_span, temp_span)),
                        @intFromEnum(inner_key),
                        0,
                    });
                    break :blk try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = span,
                        .data = .{ .extra = me },
                    });
                } else blk: {
                    // static: _a.key
                    const new_key = try self.visitNode(key_idx);
                    const me = try self.ast.addExtras(&.{
                        @intFromEnum(try es_helpers.makeTempVarRef(self, temp_span, temp_span)),
                        @intFromEnum(new_key),
                        0,
                    });
                    break :blk try self.ast.addNode(.{
                        .tag = .static_member_expression,
                        .span = span,
                        .data = .{ .extra = me },
                    });
                };

                const assign = try self.ast.addNode(.{
                    .tag = .assignment_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = member_expr, .right = new_val, .flags = 0 } },
                });
                try self.scratch.append(self.allocator, assign);
            }

            // 마지막에 _a 반환
            try self.scratch.append(self.allocator, try es_helpers.makeTempVarRef(self, temp_span, temp_span));

            // (sequence_expression) — 괄호로 감싸야 올바른 우선순위
            const seq_list = try self.ast.addNodeList(self.scratch.items[seq_scratch_top..]);
            self.scratch.shrinkRetainingCapacity(seq_scratch_top);

            const seq = try self.ast.addNode(.{
                .tag = .sequence_expression,
                .span = span,
                .data = .{ .list = seq_list },
            });
            return es_helpers.makeParenExpr(self, seq, span);
        }

        /// member의 key NodeIndex를 반환. object_property는 binary.left, method_definition은 extra[0].
        /// 해당 없는 tag는 NodeIndex.none.
        fn memberKeyIdx(self: *const Transformer, member: Node) NodeIndex {
            return switch (member.tag) {
                .object_property => member.data.binary.left,
                .method_definition => @enumFromInt(self.ast.extra_data.items[member.data.extra]),
                else => NodeIndex.none,
            };
        }

        /// emitDefineAccessor / makeTrueProp가 재사용하는 span 캐시.
        /// addString은 interning을 안 하므로 lowerComputedProperties 한 호출당 한 번만 만든다.
        const AccessorSpans = struct {
            object: Span,
            define_property: Span,
            enumerable: Span,
            configurable: Span,
            truev: Span,
            get: Span,
            set: Span,
        };

        fn makeAccessorSpans(self: *Transformer) Transformer.Error!AccessorSpans {
            return .{
                .object = try self.ast.addString("Object"),
                .define_property = try self.ast.addString("defineProperty"),
                .enumerable = try self.ast.addString("enumerable"),
                .configurable = try self.ast.addString("configurable"),
                .truev = try self.ast.addString("true"),
                .get = try self.ast.addString("get"),
                .set = try self.ast.addString("set"),
            };
        }

        /// getter/setter method_definition → `Object.defineProperty(_a, key, { get/set: fn, enumerable: true, configurable: true })`.
        /// 짝 맞추기는 하지 않음 — 인접하지 않아도 각 accessor마다 개별 defineProperty 호출.
        /// 후속 호출이 이전 descriptor의 get/set 필드를 보존하므로 동작은 정확하다 (ECMAScript ValidateAndApplyPropertyDescriptor).
        fn emitDefineAccessor(
            self: *Transformer,
            member: Node,
            is_getter: bool,
            temp_span: Span,
            span: Span,
            ctx: AccessorSpans,
        ) Transformer.Error!NodeIndex {
            const me = member.data.extra;
            const key_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);

            const func_expr = try buildAccessorFunction(self, member, span);

            const accessor_kind = try es_helpers.makeIdentifierRefFromSpan(self, if (is_getter) ctx.get else ctx.set);
            const accessor_prop = try self.ast.addNode(.{
                .tag = .object_property,
                .span = span,
                .data = .{ .binary = .{ .left = accessor_kind, .right = func_expr, .flags = 0 } },
            });
            const enum_prop = try makeTrueProp(self, ctx.enumerable, ctx.truev, span);
            const config_prop = try makeTrueProp(self, ctx.configurable, ctx.truev, span);
            const desc_list = try self.ast.addNodeList(&.{ accessor_prop, enum_prop, config_prop });
            const desc_obj = try self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = desc_list },
            });

            const key_arg = try buildAccessorKeyArg(self, key_idx);

            const temp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
            const obj_ref = try es_helpers.makeIdentifierRefFromSpan(self, ctx.object);
            const dp_prop = try es_helpers.makeIdentifierRefFromSpan(self, ctx.define_property);
            const callee = try es_helpers.makeStaticMember(self, obj_ref, dp_prop, span);
            return es_helpers.makeCallExpr(self, callee, &.{ temp_ref, key_arg, desc_obj }, span);
        }

        /// method_definition의 params/body를 방문해 function_expression을 만든다.
        fn buildAccessorFunction(self: *Transformer, member: Node, span: Span) Transformer.Error!NodeIndex {
            const me = member.data.extra;
            const params_list = self.ast.functionParamsList(member);
            const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 2]);

            const new_params = try self.visitExtraList(params_list);
            const new_body = try self.visitNode(body_idx);
            const new_params_node = try self.ast.addFormalParameters(new_params, span);

            const none = @intFromEnum(NodeIndex.none);
            const func_extra = try self.ast.addExtras(&.{
                none,                   @intFromEnum(new_params_node),
                @intFromEnum(new_body), 0,
                none,
            });
            return self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });
        }

        /// Object.defineProperty의 두번째 인자: computed key면 내부 expression,
        /// non-computed면 "name" string literal.
        fn buildAccessorKeyArg(self: *Transformer, key_idx: NodeIndex) Transformer.Error!NodeIndex {
            const key_node = self.ast.getNode(key_idx);
            if (key_node.tag == .computed_property_key) {
                return self.visitNode(key_node.data.unary.operand);
            }
            // identifier/numeric/string literal → "name" 으로 감싸 string_literal emit
            const key_text = self.ast.getText(key_node.span);
            const quoted = try self.allocator.alloc(u8, key_text.len + 2);
            defer self.allocator.free(quoted);
            quoted[0] = '"';
            @memcpy(quoted[1 .. 1 + key_text.len], key_text);
            quoted[1 + key_text.len] = '"';
            const quoted_span = try self.ast.addString(quoted);
            return self.ast.addNode(.{
                .tag = .string_literal,
                .span = quoted_span,
                .data = .{ .string_ref = quoted_span },
            });
        }

        /// `{ name: true }` object_property 생성 — span은 모두 pre-cached.
        fn makeTrueProp(self: *Transformer, name_span: Span, true_span: Span, span: Span) Transformer.Error!NodeIndex {
            const key = try es_helpers.makeIdentifierRefFromSpan(self, name_span);
            const val = try self.ast.addNode(.{
                .tag = .boolean_literal,
                .span = true_span,
                .data = .{ .none = 0 },
            });
            return self.ast.addNode(.{
                .tag = .object_property,
                .span = span,
                .data = .{ .binary = .{ .left = key, .right = val, .flags = 0 } },
            });
        }
    };
}

test "ES2015 computed module compiles" {
    _ = ES2015Computed;
}
