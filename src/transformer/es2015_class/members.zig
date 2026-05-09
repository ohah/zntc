//! Class body member classification and field emission helpers for ES2015 class lowering.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("../es_helpers.zig");
const methods_mod = @import("methods.zig");

const MethodExtra = ast_mod.MethodExtra;
const PropertyExtra = ast_mod.PropertyExtra;
const PropertyFlags = ast_mod.PropertyFlags;

pub fn Members(comptime Transformer: type) type {
    return struct {
        const methods = methods_mod.Methods(Transformer);
        const MethodInfo = methods.MethodInfo;
        const AccessorInfo = methods.AccessorInfo;
        const buildBooleanProp = methods.buildBooleanProp;
        const buildValueProp = methods.buildValueProp;

        const FieldInfo = struct {
            key: NodeIndex,
            init: NodeIndex,
        };

        const StaticElement = union(enum) {
            field: FieldInfo,
            stmt: NodeIndex,
            /// classifyMembers 안에서 visit 가 보류된 raw static_block 본문 statement.
            /// caller 가 setupPrivateFieldMappings 로 매핑을 set 한 뒤 `visitDeferredStaticBlocks`
            /// 가 visit 해서 `.stmt` 로 in-place 대체한다 — 이 방식으로 source order 가 보존된다.
            raw_stmt: NodeIndex,
        };

        const PrivateFieldInfo = struct {
            name: []const u8, // "#x" → "_x" 변환된 이름
            original_name: []const u8, // "#x" 원본 이름 (매칭용)
            init: NodeIndex, // 초기값 (none이면 undefined)
        };

        /// instance field init 의 emission 정보를 source order 로 보존하는 union.
        /// 분류 단계 (classifyMembers) 에서는 raw key/init 만 push 하고, mapping 이 set 된 뒤에
        /// `emitInstanceInits` 가 한 번에 visit 해 statement 로 빌드한다.
        const InstanceInit = union(enum) {
            /// private field (`#x = init` 또는 accessor backing `#_x_acc = init`).
            /// idx 는 cm.private_fields 안의 위치를 가리킨다 — drain 시점에 pf.name/pf.init 으로 buildPrivateFieldInit.
            private_field: usize,
            /// public field (`x = init` 또는 `[k()] = init`).
            public_field: struct {
                key: NodeIndex,
                init: NodeIndex,
            },
        };

        /// 클래스 바디 멤버를 분류: constructor, methods, instance_inits (deferred), static_elements, accessors, private_fields, static_private_fields, private_methods.
        /// `static_elements`: static field/static block 을 소스 순서대로 보존한다 (TC39 spec — class evaluation 시
        /// 필드와 블록이 선언 순서대로 실행). 별도 array 로 나누면 순서 정보가 사라져 `static a; { use a; } static b;` 같은
        /// 의존 체인이 깨진다.
        ///
        /// `instance_inits`: instance field/private/accessor-backing init 을 deferred entry 로 source order 보존.
        /// classifyMembers 가 끝난 뒤 `setupPrivateFieldMappings` 로 매핑이 완성된 다음 `emitInstanceInits` 가
        /// 한 번에 visit + statement 빌드 → cm.instance_fields. visit 가 mapping 을 필요로 하기 때문에 분류와
        /// emission 을 phase 분리한 것 (이전엔 dual setup + 카운터로 우회).
        pub const ClassifiedMembers = struct {
            constructor_idx: ?NodeIndex,
            methods: std.ArrayList(MethodInfo),
            instance_fields: std.ArrayList(NodeIndex),
            instance_inits: std.ArrayList(InstanceInit) = .empty,
            static_elements: std.ArrayList(StaticElement),
            accessors: std.ArrayList(AccessorInfo),
            private_fields: std.ArrayList(PrivateFieldInfo),
            /// static private fields: descriptor 객체 패턴.
            /// instance private fields와 달리 WeakMap이 아닌 { writable: true, value: init } 객체로 변환.
            static_private_fields: std.ArrayList(PrivateFieldInfo),
            private_methods: std.ArrayList(Transformer.PrivateMethodMapping),
            /// accessor_property 합성으로 만드는 `#_<name>_acc` 원본 이름.
            /// `PrivateFieldInfo.original_name`은 `findPrivateFieldMapping`의 `std.mem.eql` 키라 안정적 slice가 필요.
            /// string_table slice는 후속 `addString` 호출의 realloc으로 dangling이 되므로 heap-owned 복사본을 유지한다.
            synthesized_private_names: std.ArrayList([]u8) = .empty,
            /// computed accessor key memoization 을 위한 `var _acc_key_N = <expr>;` statement 들.
            /// IIFE body 앞부분 (WeakSet 선언 직전) 에 배치되어 key 식이 한 번만 평가됨 (#1511).
            accessor_key_memos: std.ArrayList(NodeIndex) = .empty,
            /// instance field init에 arrow this 캡처가 필요한 경우 true.
            /// super class 없는 class에서 var _this = this; 삽입에 사용.
            fields_need_this_alias: bool = false,

            pub fn deinit(cm: *ClassifiedMembers, allocator: std.mem.Allocator) void {
                for (cm.private_fields.items) |pf| {
                    allocator.free(pf.name);
                }
                for (cm.static_private_fields.items) |pf| {
                    allocator.free(pf.name);
                }
                for (cm.private_methods.items) |pm| {
                    allocator.free(pm.weakset_name);
                    allocator.free(pm.func_name);
                }
                for (cm.synthesized_private_names.items) |s| allocator.free(s);
                cm.methods.deinit(allocator);
                cm.instance_fields.deinit(allocator);
                cm.instance_inits.deinit(allocator);
                cm.static_elements.deinit(allocator);
                cm.accessors.deinit(allocator);
                cm.private_fields.deinit(allocator);
                cm.static_private_fields.deinit(allocator);
                cm.private_methods.deinit(allocator);
                cm.synthesized_private_names.deinit(allocator);
            }
        };

        /// classifyMembers 가 보류한 `.raw_stmt` static block entry 를 visit 해서 `.stmt` 로 변환한다.
        /// caller 는 이 함수 호출 전에 setupPrivateFieldMappings 로 매핑을 set 해야 한다 — 그래야 본문
        /// 안의 `this.#x` / `super.x` 등이 정확히 lowering 된다. 본문 visit 시 transformer state 를 static
        /// block 컨텍스트로 set (this_depth=0, current_super_is_static=true, receiver/class_name = class span).
        ///
        /// visit 결과가 none 이면 (declare 같은 strip 대상) 해당 entry 는 새 list 에서 drop —
        /// 원본 동작 (`if (!new_stmt.isNone()) append`) 과 동치.
        pub fn visitDeferredStaticBlocks(self: *Transformer, cm: *ClassifiedMembers, class_name_span: Span) Transformer.Error!void {
            var has_raw = false;
            for (cm.static_elements.items) |elem| {
                if (elem == .raw_stmt) {
                    has_raw = true;
                    break;
                }
            }
            if (!has_raw) return;

            const saved_sb_name = self.static_block_class_name;
            const saved_sb_depth = self.this_depth;
            const saved_super_static = self.current_super_is_static;
            const saved_super_static_receiver = self.current_super_static_receiver;
            self.static_block_class_name = class_name_span;
            self.this_depth = 0;
            self.current_super_is_static = true;
            self.current_super_static_receiver = class_name_span;
            defer {
                self.static_block_class_name = saved_sb_name;
                self.this_depth = saved_sb_depth;
                self.current_super_is_static = saved_super_static;
                self.current_super_static_receiver = saved_super_static_receiver;
            }

            var new_elements: std.ArrayList(StaticElement) = .empty;
            errdefer new_elements.deinit(self.allocator);
            try new_elements.ensureTotalCapacity(self.allocator, cm.static_elements.items.len);
            for (cm.static_elements.items) |elem| {
                switch (elem) {
                    .raw_stmt => |raw| {
                        const visited = try self.visitNode(raw);
                        if (!visited.isNone()) {
                            new_elements.appendAssumeCapacity(.{ .stmt = visited });
                        }
                    },
                    else => new_elements.appendAssumeCapacity(elem),
                }
            }
            cm.static_elements.deinit(self.allocator);
            cm.static_elements = new_elements;
        }

        /// `cm.instance_inits` 의 deferred entry 를 source order 로 visit 해서 statement 를 빌드하고
        /// `cm.instance_fields` 에 push. caller 는 이 함수를 호출하기 전에 `setupPrivateFieldMappings` 로
        /// 매핑을 set 해 둬야 한다 — 이후 `this.#x` / `_x.get(this)` 등의 lowering 이 정확히 이루어진다.
        ///
        /// derived class 안의 instance field init 은 arrow this 캡처가 `_this` 별칭으로 lowering 되도록
        /// `super_call_this_alias` context 를 set 한다 (super class 가 있을 때만).
        pub fn emitInstanceInits(self: *Transformer, cm: *ClassifiedMembers, span: Span) Transformer.Error!void {
            if (cm.instance_inits.items.len == 0) return;

            const saved_field_alias = self.super_call_this_alias;
            const saved_needs_this = self.needs_this_var;
            if (self.current_super_class != null) {
                self.super_call_this_alias = true;
            }
            defer self.super_call_this_alias = saved_field_alias;

            for (cm.instance_inits.items) |entry| {
                const init_stmt = switch (entry) {
                    .private_field => |idx| blk: {
                        const pf = cm.private_fields.items[idx];
                        break :blk try buildPrivateFieldInit(self, pf.name, pf.init, span);
                    },
                    .public_field => |pub_init| blk: {
                        const this_node = try self.ast.addNode(.{
                            .tag = .this_expression,
                            .span = span,
                            .data = .{ .none = 0 },
                        });
                        break :blk try buildFieldAssign(self, this_node, pub_init.key, pub_init.init, span);
                    },
                };
                if (self.needs_this_var and !saved_needs_this) {
                    cm.fields_need_this_alias = true;
                }
                self.needs_this_var = saved_needs_this;
                try cm.instance_fields.append(self.allocator, init_stmt);
            }
        }

        /// instance + static private field 매핑을 빌드하여 current_private_fields에 설정.
        /// 반환값: 매핑 총 개수 (defer에서 free 판단용).
        pub fn setupPrivateFieldMappings(self: *Transformer, cm: *ClassifiedMembers, name_span: Span) Transformer.Error!usize {
            const total = cm.private_fields.items.len + cm.static_private_fields.items.len;
            if (total == 0) return 0;

            var mappings = try self.allocator.alloc(Transformer.PrivateFieldMapping, total);
            for (cm.private_fields.items, 0..) |pf, i| {
                mappings[i] = .{ .original_name = pf.original_name, .var_name = pf.name };
            }
            const class_name = self.ast.getText(name_span);
            for (cm.static_private_fields.items, 0..) |pf, i| {
                mappings[cm.private_fields.items.len + i] = .{
                    .original_name = pf.original_name,
                    .var_name = pf.name,
                    .class_name = class_name,
                };
            }
            self.current_private_fields = mappings;
            return total;
        }

        pub fn classifyMembers(self: *Transformer, body_idx: NodeIndex, span: Span) Transformer.Error!ClassifiedMembers {
            const body_node = self.ast.getNode(body_idx);
            const members_start = body_node.data.list.start;
            const members_len = body_node.data.list.len;

            var cm = ClassifiedMembers{
                .constructor_idx = null,
                .methods = .empty,
                .instance_fields = .empty,
                .static_elements = .empty,
                .accessors = .empty,
                .private_fields = .empty,
                .static_private_fields = .empty,
                .private_methods = .empty,
            };

            // 분류 phase — visitNode 호출 없이 metadata 만 모은다. instance field init / accessor backing 의
            // 실제 statement build 는 caller 가 setupPrivateFieldMappings 로 매핑을 set 한 뒤
            // `emitInstanceInits` 로 한 번에 처리한다. 이 phase 분리로 init 안의 `this.#x` 참조가 항상
            // 완성된 매핑 (regular private + accessor backing 포함) 으로 lowering 된다.
            var m_loop: u32 = 0;
            while (m_loop < members_len) : (m_loop += 1) {
                const raw_idx = self.ast.extra_data.items[members_start + m_loop];
                const member = self.ast.getNode(@enumFromInt(raw_idx));

                if (member.tag == .method_definition) {
                    const me = member.data.extra;
                    const key: NodeIndex = self.readNodeIdx(me, MethodExtra.key);
                    const flags = self.readU32(me, MethodExtra.flags);
                    const is_static = (flags & ast_mod.MethodFlags.is_static) != 0;
                    const is_abstract = (flags & ast_mod.MethodFlags.is_abstract) != 0;
                    const is_declare = (flags & ast_mod.MethodFlags.is_declare) != 0;
                    const pm_kind = es_helpers.privateMethodKindFromFlags(flags);
                    const kind = @intFromEnum(pm_kind);

                    // 본문 없는 메서드 스트리핑: abstract, declare, TS 오버로드 시그니처
                    const method_body: NodeIndex = @enumFromInt(self.readU32(me, MethodExtra.body));
                    if (is_abstract or is_declare or method_body.isNone()) continue;

                    if (!is_static and es_helpers.isConstructorKey(self, key)) {
                        cm.constructor_idx = @enumFromInt(raw_idx);
                        continue;
                    }

                    // private method (#method) / private getter/setter → WeakSet + standalone function 분류.
                    // getter/setter 의 경우 kind 로 func_name suffix 구분 (_get / _set), WeakSet 은
                    // emit 시 name 기준 dedupe 되므로 같은 name 의 get/set 쌍이 하나의 WeakSet 공유 (#1523).
                    if (!key.isNone()) {
                        const key_node = self.ast.getNode(key);
                        if (key_node.tag == .private_identifier) {
                            const orig_name = self.ast.getText(key_node.span); // "#bar"

                            const names = try es_helpers.makePrivateMethodNames(self.allocator, orig_name, pm_kind);

                            try cm.private_methods.append(self.allocator, .{
                                .member_idx = @enumFromInt(raw_idx),
                                .original_name = orig_name,
                                .weakset_name = names.ws_name,
                                .func_name = names.fn_name,
                                .member_span = member.span,
                                .kind = pm_kind,
                            });
                            continue;
                        }
                    }

                    const member_idx = if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key) blk: {
                        const memo_key = try memoizeStaticComputedFieldKey(self, &cm, self.ast.getNode(key).data.unary.operand, member.span);
                        break :blk try es_helpers.replaceMethodDefinitionKey(self, @enumFromInt(raw_idx), memo_key);
                    } else @as(NodeIndex, @enumFromInt(raw_idx));

                    if (kind == 1 or kind == 2) {
                        try cm.accessors.append(self.allocator, .{
                            .member_idx = member_idx,
                            .is_static = is_static,
                            .is_getter = kind == 1,
                            .member_span = member.span,
                        });
                    } else {
                        try cm.methods.append(self.allocator, .{
                            .member_idx = member_idx,
                            .is_static = is_static,
                            .member_span = member.span,
                        });
                    }
                } else if (member.tag == .property_definition) {
                    const pe = member.data.extra;
                    const key: NodeIndex = self.readNodeIdx(pe, PropertyExtra.key);
                    const init_val: NodeIndex = self.readNodeIdx(pe, PropertyExtra.init);
                    const flags = self.readU32(pe, PropertyExtra.flags);
                    const is_static = (flags & ast_mod.PropertyFlags.is_static) != 0;

                    // private field (#x) → cm.private_fields/static_private_fields 에 등록.
                    // instance 의 경우 source order 추적용으로 instance_inits 에도 entry 를 push —
                    // emitInstanceInits 가 매핑 set 후에 buildPrivateFieldInit 으로 statement 를 만든다.
                    const key_node = self.ast.getNode(key);
                    if (key_node.tag == .private_identifier) {
                        const orig_name_owned = try self.allocator.dupe(u8, self.ast.getText(key_node.span));
                        try cm.synthesized_private_names.append(self.allocator, orig_name_owned);
                        const field_info = PrivateFieldInfo{
                            .name = try es_helpers.makePrivateVarName(self.allocator, orig_name_owned),
                            .original_name = orig_name_owned,
                            .init = init_val,
                        };
                        if (is_static) {
                            try cm.static_private_fields.append(self.allocator, field_info);
                        } else {
                            const idx = cm.private_fields.items.len;
                            try cm.private_fields.append(self.allocator, field_info);
                            try cm.instance_inits.append(self.allocator, .{ .private_field = idx });
                        }
                        continue;
                    }

                    if (is_static and !init_val.isNone()) {
                        const static_key = if (key_node.tag == .computed_property_key)
                            try memoizeStaticComputedFieldKey(self, &cm, key_node.data.unary.operand, span)
                        else
                            key;
                        try cm.static_elements.append(self.allocator, .{ .field = .{ .key = static_key, .init = init_val } });
                    } else if (!is_static and !init_val.isNone()) {
                        // 실제 statement build + visitNode 는 emitInstanceInits 가 매핑 set 후에 처리.
                        try cm.instance_inits.append(self.allocator, .{ .public_field = .{ .key = key, .init = init_val } });
                    }
                } else if (member.tag == .static_block) {
                    const sb_body_idx = member.data.unary.operand;
                    if (!sb_body_idx.isNone()) {
                        const sb_body = self.ast.getNode(sb_body_idx);
                        if (sb_body.tag == .block_statement) {
                            // 본문 visit 는 deferred — static block 안의 `this?.#x` 가 lowering 되려면
                            // private mapping 이 set 되어 있어야 하고, accessor backing 이 main loop 가
                            // 더 진행되며 cm.private_fields 에 추가된다. 둘이 끝난 뒤 visitDeferredStaticBlocks
                            // 가 .raw_stmt 를 visit 해 .stmt 로 대체.
                            const sb_stmts_start = sb_body.data.list.start;
                            const sb_stmts_len = sb_body.data.list.len;
                            var i_loop: u32 = 0;
                            while (i_loop < sb_stmts_len) : (i_loop += 1) {
                                const sb_raw = self.ast.extra_data.items[sb_stmts_start + i_loop];
                                try cm.static_elements.append(self.allocator, .{ .raw_stmt = @enumFromInt(sb_raw) });
                            }
                        }
                    }
                } else if (member.tag == .accessor_property) {
                    try classifyAccessorProperty(self, &cm, member, span);
                } else {
                    std.debug.panic("classifyMembers: unexpected member tag {s}", .{@tagName(member.tag)});
                }
            }

            return cm;
        }

        /// `accessor x = init;` → private backing + getter/setter. public / private / computed 키 모두 처리 (#1511).
        /// Stage 3 decorator 경로는 class_decorator.zig 가 처리하므로 여기선 decorator 없는 ES5 직접 경로만.
        fn classifyAccessorProperty(
            self: *Transformer,
            cm: *ClassifiedMembers,
            member: Node,
            span: Span,
        ) Transformer.Error!void {
            const pe = member.data.extra;
            const key_idx = self.readNodeIdx(pe, PropertyExtra.key);
            const init_idx = self.readNodeIdx(pe, PropertyExtra.init);
            const flags = self.readU32(pe, PropertyExtra.flags);
            const is_static = (flags & PropertyFlags.is_static) != 0;

            const key_node = self.ast.getNode(key_idx);
            if (key_node.tag == .private_identifier) {
                return classifyPrivateAccessorProperty(self, cm, key_node, init_idx, is_static, member.span, span);
            }
            if (key_node.tag == .computed_property_key) {
                return classifyComputedAccessorProperty(self, cm, key_idx, init_idx, is_static, member.span, span);
            }

            const raw_key = self.ast.getText(key_node.span);
            const bare_name = stripQuotes(raw_key);

            const storage_name_owned = try std.fmt.allocPrint(self.allocator, "#_{s}_acc", .{bare_name});
            try cm.synthesized_private_names.append(self.allocator, storage_name_owned);
            const storage_span = try self.ast.addString(storage_name_owned);

            const pfi = PrivateFieldInfo{
                .name = try es_helpers.makePrivateVarName(self.allocator, storage_name_owned),
                .original_name = storage_name_owned,
                .init = init_idx,
            };
            if (is_static) {
                try cm.static_private_fields.append(self.allocator, pfi);
            } else {
                const idx = cm.private_fields.items.len;
                try cm.private_fields.append(self.allocator, pfi);
                try cm.instance_inits.append(self.allocator, .{ .private_field = idx });
            }

            const getter_idx = try buildAccessorGetter(self, key_node.span, storage_span, is_static, span);
            try cm.accessors.append(self.allocator, .{
                .member_idx = getter_idx,
                .is_static = is_static,
                .is_getter = true,
                // 동일 accessor_property 에서 파생된 getter/setter 는 같은 원본 span 공유 —
                // 둘이 paired 로 emit 되어 첫 번째(getter) 의 member_span 에서 한 번만 comment flush.
                .member_span = member.span,
            });

            const setter_idx = try buildAccessorSetter(self, key_node.span, storage_span, is_static, span);
            try cm.accessors.append(self.allocator, .{
                .member_idx = setter_idx,
                .is_static = is_static,
                .is_getter = false,
                .member_span = member.span,
            });
        }

        /// `accessor #x = init;` — decorator 없는 private accessor 는 plain private field 와 관찰 동치.
        /// 디코레이터 미지원 경로이므로 instance: 기존 WeakSet 기반 getter/setter 합성, static: 간단히
        /// static_private_field 로 등록 (spec-helper 가 이미 Foo-branded read/write 수행) (#1511).
        fn classifyPrivateAccessorProperty(
            self: *Transformer,
            cm: *ClassifiedMembers,
            key_node: Node,
            init_idx: NodeIndex,
            is_static: bool,
            member_span: Span,
            span: Span,
        ) Transformer.Error!void {
            const orig_name = self.ast.getText(key_node.span); // "#x"

            if (is_static) {
                // static private accessor 는 class-singleton — 별도 backing / synthesis 없이 그대로
                // static private field 로 등록하면 `this.#x` / `this.#x = v` 가 __classStaticPrivateFieldSpec(Get|Set) 로 lowering.
                const pfi = PrivateFieldInfo{
                    .name = try es_helpers.makePrivateVarName(self.allocator, orig_name),
                    .original_name = orig_name,
                    .init = init_idx,
                };
                try cm.static_private_fields.append(self.allocator, pfi);
                return;
            }

            const bare_private = orig_name[1..]; // "x" (# 제거)
            const storage_name_owned = try std.fmt.allocPrint(self.allocator, "#_{s}_acc", .{bare_private});
            try cm.synthesized_private_names.append(self.allocator, storage_name_owned);
            const storage_span = try self.ast.addString(storage_name_owned);

            const pfi = PrivateFieldInfo{
                .name = try es_helpers.makePrivateVarName(self.allocator, storage_name_owned),
                .original_name = storage_name_owned,
                .init = init_idx,
            };
            const idx = cm.private_fields.items.len;
            try cm.private_fields.append(self.allocator, pfi);
            try cm.instance_inits.append(self.allocator, .{ .private_field = idx });

            // getter/setter 의 key 는 동일 private_identifier "#x" 를 각각 새 노드로 생성 (AST 노드 공유 금지).
            const priv_key_get = try self.ast.addNode(.{
                .tag = .private_identifier,
                .span = key_node.span,
                .data = .{ .string_ref = key_node.span },
            });
            const getter_return = try makePrivateFieldAccess(self, storage_span, span);
            const getter_idx = try self.buildGetterMethod(priv_key_get, getter_return, false, span);

            const priv_key_set = try self.ast.addNode(.{
                .tag = .private_identifier,
                .span = key_node.span,
                .data = .{ .string_ref = key_node.span },
            });
            const setter_target = try makePrivateFieldAccess(self, storage_span, span);
            const setter_idx = try self.buildSetterMethod(priv_key_set, setter_target, false, span);

            const get_names = try es_helpers.makePrivateMethodNames(self.allocator, orig_name, .getter);
            try cm.private_methods.append(self.allocator, .{
                .member_idx = getter_idx,
                .original_name = orig_name,
                .weakset_name = get_names.ws_name,
                .func_name = get_names.fn_name,
                .member_span = member_span,
                .kind = .getter,
            });

            const set_names = try es_helpers.makePrivateMethodNames(self.allocator, orig_name, .setter);
            try cm.private_methods.append(self.allocator, .{
                .member_idx = setter_idx,
                .original_name = orig_name,
                .weakset_name = set_names.ws_name,
                .func_name = set_names.fn_name,
                .member_span = member_span,
                .kind = .setter,
            });
        }

        /// `accessor [k] = init;` — 사이드이펙트 없는 key memoization 을 IIFE 범위에 var 선언으로 캐시,
        /// private backing `#_comp_N_acc` + computed get/set 를 accessors 에 등록 — emitAccessors 가 computed
        /// 분기로 Object.defineProperty(proto, _k, { get, set }) 를 emit (#1524 공용 경로 재사용).
        fn classifyComputedAccessorProperty(
            self: *Transformer,
            cm: *ClassifiedMembers,
            key_idx: NodeIndex,
            init_idx: NodeIndex,
            is_static: bool,
            member_span: Span,
            span: Span,
        ) Transformer.Error!void {
            // 고유 backing 이름 — computed 는 바깥 관찰 가능 이름이 없으니 counter 로 unique.
            const seq = cm.synthesized_private_names.items.len;
            const storage_name_owned = try std.fmt.allocPrint(self.allocator, "#_comp_{d}_acc", .{seq});
            try cm.synthesized_private_names.append(self.allocator, storage_name_owned);
            const storage_span = try self.ast.addString(storage_name_owned);

            const pfi = PrivateFieldInfo{
                .name = try es_helpers.makePrivateVarName(self.allocator, storage_name_owned),
                .original_name = storage_name_owned,
                .init = init_idx,
            };
            if (is_static) {
                try cm.static_private_fields.append(self.allocator, pfi);
            } else {
                const idx = cm.private_fields.items.len;
                try cm.private_fields.append(self.allocator, pfi);
                try cm.instance_inits.append(self.allocator, .{ .private_field = idx });
            }

            // key memoization — IIFE body 앞에 `var _acc_key_N = <key_expr>;` 선언 추가, 이후 get/set 은
            // 이 변수를 computed_property_key 로 참조. emitAccessors 는 computed 분기로 Object.defineProperty(proto, _acc_key_N, ...).
            const key_node = self.ast.getNode(key_idx);
            const inner_expr = key_node.data.unary.operand;
            const mem_var_name = try std.fmt.allocPrint(self.allocator, "_acc_key_{d}", .{seq});
            try cm.synthesized_private_names.append(self.allocator, mem_var_name); // allocator 소유 보관용 재사용
            const mem_var_span = try self.ast.addString(mem_var_name);
            const visited_inner = try self.visitNode(inner_expr);
            const var_decl = try self.buildVarDecl(mem_var_name, visited_inner, span);
            try cm.accessor_key_memos.append(self.allocator, var_decl);

            // computed key 노드: computed_property_key(identifier_reference("_acc_key_N")) — getter/setter 각 1개씩.
            const getter_key = try es_helpers.makeComputedKeyRef(self, mem_var_span, span);
            const getter_return = try makePrivateFieldAccess(self, storage_span, span);
            const getter_idx = try buildComputedAccessorGetter(self, getter_key, getter_return, is_static, span);
            try cm.accessors.append(self.allocator, .{
                .member_idx = getter_idx,
                .is_static = is_static,
                .is_getter = true,
                .member_span = member_span,
            });

            const setter_key = try es_helpers.makeComputedKeyRef(self, mem_var_span, span);
            const setter_target = try makePrivateFieldAccess(self, storage_span, span);
            const setter_idx = try buildComputedAccessorSetter(self, setter_key, setter_target, is_static, span);
            try cm.accessors.append(self.allocator, .{
                .member_idx = setter_idx,
                .is_static = is_static,
                .is_getter = false,
                .member_span = member_span,
            });
        }

        fn memoizeStaticComputedFieldKey(self: *Transformer, cm: anytype, key_expr: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const memo = try es_helpers.memoizeComputedKey(self, key_expr, span);
            try cm.accessor_key_memos.append(self.allocator, memo.decl);
            return memo.computed_key;
        }

        /// computed accessor getter method_definition 생성. `get [_acc_key_N]() { return return_expr; }`.
        fn buildComputedAccessorGetter(self: *Transformer, computed_key: NodeIndex, return_expr: NodeIndex, is_static: bool, span: Span) Transformer.Error!NodeIndex {
            return self.buildGetterMethod(computed_key, return_expr, is_static, span);
        }

        /// computed accessor setter method_definition 생성. `set [_acc_key_N](value) { assign_target = value; }`.
        fn buildComputedAccessorSetter(self: *Transformer, computed_key: NodeIndex, assign_target: NodeIndex, is_static: bool, span: Span) Transformer.Error!NodeIndex {
            return self.buildSetterMethod(computed_key, assign_target, is_static, span);
        }

        /// `"foo"` / `'foo'` → `foo` (따옴표 제거). 따옴표 없으면 원본 반환.
        fn stripQuotes(s: []const u8) []const u8 {
            if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) {
                return s[1 .. s.len - 1];
            }
            return s;
        }

        /// `this.#storage` — private_field_expression 태그 필수 (static_member_expression으로 만들면
        /// transformer.zig:899의 private field WeakMap 변환 dispatch를 못 탄다 — silent drop).
        fn makePrivateFieldAccess(self: *Transformer, storage_span: Span, span: Span) Transformer.Error!NodeIndex {
            const this_node = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
            const storage_ref = try self.ast.addNode(.{
                .tag = .private_identifier,
                .span = storage_span,
                .data = .{ .string_ref = storage_span },
            });
            const extra = try self.ast.addExtras(&.{
                @intFromEnum(this_node), @intFromEnum(storage_ref), 0,
            });
            return self.ast.addNode(.{
                .tag = .private_field_expression,
                .span = span,
                .data = .{ .extra = extra },
            });
        }

        fn buildAccessorGetter(
            self: *Transformer,
            key_span: Span,
            storage_span: Span,
            is_static: bool,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const return_expr = try makePrivateFieldAccess(self, storage_span, span);
            const getter_key = try es_helpers.makeIdentifierRefFromSpan(self, key_span);
            return self.buildGetterMethod(getter_key, return_expr, is_static, span);
        }

        fn buildAccessorSetter(
            self: *Transformer,
            key_span: Span,
            storage_span: Span,
            is_static: bool,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const setter_key = try es_helpers.makeIdentifierRefFromSpan(self, key_span);
            const assign_target = try makePrivateFieldAccess(self, storage_span, span);
            return self.buildSetterMethod(setter_key, assign_target, is_static, span);
        }

        /// _x.set(this, init) expression_statement 생성.
        fn buildPrivateFieldInit(self: *Transformer, name: []const u8, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const wm_ref = try es_helpers.makeIdentifierRef(self, name);
            const set_prop = try es_helpers.makeIdentifierRef(self, "set");
            const callee = try es_helpers.makeStaticMember(self, wm_ref, set_prop, span);
            const this_node = try self.ast.addNode(.{
                .tag = .this_expression,
                .span = span,
                .data = .{ .none = 0 },
            });
            const new_init = if (!init_idx.isNone()) try self.visitNode(init_idx) else try es_helpers.makeVoidZero(self, span);
            const call = try es_helpers.makeCallExpr(self, callee, &.{ this_node, new_init }, span);

            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        /// obj.key = init 또는 obj[computedKey] = init expression_statement 생성.
        /// instance field: obj = this, static field: obj = ClassName identifier.
        fn buildFieldAssign(self: *Transformer, obj: NodeIndex, key_idx: NodeIndex, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const member = try es_helpers.makeMemberFromKeyIdx(self, obj, key_idx, span);
            const new_init = try self.visitNode(init_idx);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = member, .right = new_init, .flags = 0 } },
            });
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        /// `Object.defineProperty(Class, key, { configurable: true, enumerable: true, writable: true, value: init })`.
        /// 단순 `Class.key = init` 대입 대신 [[DefineOwnProperty]] 시맨틱이 필요한 이유 — TC39
        /// `ClassFieldDefinitionEvaluation` 은 항상 fresh data descriptor 를 install 한다. 예: `static name = "Custom"`
        /// 의 경우 Function.prototype 으로부터 상속된 `name` 슬롯이 non-writable 이라 단순 대입은 strict mode 에서 throw 한다.
        fn buildStaticFieldDefineProperty(self: *Transformer, obj: NodeIndex, key_idx: NodeIndex, init_idx: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const new_init = try self.visitNode(init_idx);
            const config_prop = try buildBooleanProp(self, "configurable", true, span);
            const enumerable_prop = try buildBooleanProp(self, "enumerable", true, span);
            const writable_prop = try buildBooleanProp(self, "writable", true, span);
            const value_prop = try buildValueProp(self, new_init, span);
            const desc_list = try self.ast.addNodeList(&.{ config_prop, enumerable_prop, writable_prop, value_prop });
            const desc_obj = try self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = desc_list },
            });

            const obj_str_span = try self.ast.addString("Object");
            const dp_str_span = try self.ast.addString("defineProperty");
            const key_arg = try es_helpers.buildDefinePropertyKeyArg(self, key_idx);
            const call = try es_helpers.buildObjectDefinePropertyCall(self, obj_str_span, dp_str_span, obj, key_arg, desc_obj, span);
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = call, .flags = 0 } },
            });
        }

        pub fn buildStaticFieldDefinePropertyWithCtx(self: *Transformer, obj: NodeIndex, key_idx: NodeIndex, init_idx: NodeIndex, class_name_span: Span, span: Span) Transformer.Error!NodeIndex {
            const saved_static = self.current_super_is_static;
            const saved_receiver = self.current_super_static_receiver;
            const saved_class_name = self.static_block_class_name;
            const saved_this_depth = self.this_depth;
            self.current_super_is_static = true;
            self.current_super_static_receiver = class_name_span;
            self.static_block_class_name = class_name_span;
            self.this_depth = 0;
            defer {
                self.current_super_is_static = saved_static;
                self.current_super_static_receiver = saved_receiver;
                self.static_block_class_name = saved_class_name;
                self.this_depth = saved_this_depth;
            }
            return buildStaticFieldDefineProperty(self, obj, key_idx, init_idx, span);
        }
    };
}
