//! Stage 3 decorator transform for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../../lexer/token.zig").Span;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const es_helpers = @import("../es_helpers.zig");
const class_member_helpers = @import("class_member_helpers.zig");
const makeThisPrivateField = class_member_helpers.makeThisPrivateField;
const insertAfterSuperCall = class_member_helpers.insertAfterSuperCall;
const buildSuperSpreadArgsShell = class_member_helpers.buildSuperSpreadArgsShell;
const stage3_helpers = @import("stage3_decorator_helpers.zig");
const Stage3MemberInfo = stage3_helpers.Stage3MemberInfo;
const extractCleanVarName = stage3_helpers.extractCleanVarName;

const ANON_CLASS_NAME = "_Class";

fn makeIdentifier(self: *Transformer, name: []const u8) Error!NodeIndex {
    return es_helpers.makeIdentifierRef(self, name);
}

/// TC39 Stage 3 decorator 변환 메인 함수.
pub fn transformStage3Decorators(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const zero_span = Span{ .start = 0, .end = 0 };
    const none = @intFromEnum(NodeIndex.none);

    // 런타임 헬퍼 사용 표시
    self.runtime_helpers.es_decorator = true;

    // accessor backing storage 이름 충돌 회피용 — 같은 base name 의 public/
    // private accessor 가 한 class 에 동거하거나, 사용자 코드가 동일 이름의
    // identifier 를 이미 사용 중이면 PrivateNameAllocator 가 suffix 로 회피.
    var private_name_allocator = try es_helpers.PrivateNameAllocator.init(self.allocator, self.ast);
    defer private_name_allocator.deinit();

    // 클래스 이름, super, body, decorator 추출
    const name_idx = self.readNodeIdx(e, ast_mod.ClassExtra.name);
    const super_idx = self.readNodeIdx(e, ast_mod.ClassExtra.super);
    const body_idx = self.readNodeIdx(e, ast_mod.ClassExtra.body);
    const class_deco_start = self.readU32(e, ast_mod.ClassExtra.deco_start);
    const class_deco_len = self.readU32(e, ast_mod.ClassExtra.deco_len);

    // 클래스 이름 텍스트 (Foo). 익명/default class는 "_Class"를 사용.
    // "default"는 JS 예약어이므로 변수명으로 사용 불가.
    // 주의: getText 반환값은 string table 내부 포인터이므로 addString 후 무효화될 수 있음.
    // allocator로 복사하여 안전하게 보관한다.
    // makeTempVarSpan을 사용하지 않음 — hoistTempVars가 불필요한 var 선언을 추가하므로.
    const class_name_text = if (!name_idx.isNone()) blk: {
        const name_node = self.ast.getNode(name_idx);
        const name_text = self.ast.getText(name_node.data.string_ref);
        if (std.mem.eql(u8, name_text, "default")) {
            break :blk try self.allocator.dupe(u8, ANON_CLASS_NAME);
        }
        break :blk try self.allocator.dupe(u8, name_text);
    } else blk: {
        break :blk try self.allocator.dupe(u8, ANON_CLASS_NAME);
    };
    defer self.allocator.free(class_name_text);

    // body 멤버 순회: member decorator 수집
    var member_infos: std.ArrayList(Stage3MemberInfo) = .empty;
    defer {
        for (member_infos.items) |info| {
            self.allocator.free(info.decorators);
            if (info.initializers_name) |name| self.allocator.free(name);
            if (info.extra_initializers_name) |name| self.allocator.free(name);
            if (info.descriptor_name) |name| self.allocator.free(name);
            if (info.deco_var_name) |name| self.allocator.free(name);
        }
        member_infos.deinit(self.allocator);
    }

    var has_instance_decorators = false;
    var has_static_decorators = false;

    const body_node = self.ast.getNode(body_idx);
    const body_start = body_node.data.list.start;
    const body_len = body_node.data.list.len;

    // 새 class body 멤버 (decorator 제거 + 필요 시 constructor 삽입)
    var new_members: std.ArrayList(NodeIndex) = .empty;
    defer new_members.deinit(self.allocator);

    var has_constructor = false;

    // instance field/accessor initializer 체이닝용: 마지막 field의 extra_initializers_name만 추적.
    // TypeScript 패턴: 첫 field에 _instanceExtraInitializers를 piggyback,
    // 이후 field에 이전 field의 _extraInitializers를 piggyback,
    // constructor에 마지막 field의 _extraInitializers를 삽입
    var last_instance_field_extra: ?[]const u8 = null;

    {
        var i: u32 = 0;
        while (i < body_len) : (i += 1) {
            const raw = self.ast.extra_data.items[body_start + i];
            const member_idx: NodeIndex = @enumFromInt(raw);
            if (member_idx.isNone()) continue;
            const member = self.ast.getNode(member_idx);
            const me = member.data.extra;

            if (member.tag == .method_definition) {
                const flags = self.readU32(me, ast_mod.MethodExtra.flags);
                const deco_start = self.readU32(me, ast_mod.MethodExtra.deco_start);
                const deco_len = self.readU32(me, ast_mod.MethodExtra.deco_len);
                const is_static = (flags & ast_mod.MethodFlags.is_static) != 0;
                const is_getter = (flags & ast_mod.MethodFlags.is_getter) != 0;
                const is_setter = (flags & ast_mod.MethodFlags.is_setter) != 0;

                // constructor 감지
                if (!is_getter and !is_setter and !is_static) {
                    const key_idx = self.readNodeIdx(me, ast_mod.MethodExtra.key);
                    if (!key_idx.isNone()) {
                        const key_node = self.ast.getNode(key_idx);
                        if (key_node.tag == .identifier_reference or key_node.tag == .binding_identifier) {
                            const key_text = self.ast.getText(key_node.data.string_ref);
                            if (std.mem.eql(u8, key_text, "constructor")) {
                                has_constructor = true;
                            }
                        }
                    }
                }

                // key를 한 번만 방문 (decorator info + stripped method 공용)
                const key_idx = self.readNodeIdx(me, ast_mod.MethodExtra.key);
                const new_key = try self.visitNode(key_idx);
                // private identifier 감지
                const is_private = blk: {
                    const orig_key = self.ast.getNode(key_idx);
                    break :blk orig_key.tag == .private_identifier;
                };

                const is_private_method = is_private and deco_len > 0 and !is_getter and !is_setter;

                if (deco_len > 0) {
                    const kind = if (is_getter) "getter" else if (is_setter) "setter" else "method";
                    const name_node_idx = try self.memberKeyToStringLiteral(new_key);
                    const decos = try self.collectStage3Decorators(deco_start, deco_len);
                    const var_n = extractCleanVarName(self, name_node_idx);
                    // getter/setter는 같은 이름에 다른 kind → kind prefix로 충돌 방지
                    const kind_prefix = if (is_getter) "get_" else if (is_setter) "set_" else "";
                    const deco_vname = try std.fmt.allocPrint(self.allocator, "_{s}{s}_decorators", .{ kind_prefix, var_n });

                    if (is_static) has_static_decorators = true else has_instance_decorators = true;

                    // private method: descriptor 변수명 + body 저장
                    var desc_name: ?[]const u8 = null;
                    var m_body: NodeIndex = .none;
                    var m_params: ast_mod.NodeList = .{ .start = 0, .len = 0 };
                    if (is_private_method) {
                        desc_name = try std.fmt.allocPrint(self.allocator, "_private_{s}_descriptor", .{var_n});
                        m_body = try self.visitNode(self.readNodeIdx(me, ast_mod.MethodExtra.body));
                        m_params = self.ast.functionParamsList(member);
                    }

                    try member_infos.append(self.allocator, .{
                        .kind = kind,
                        .name = name_node_idx,
                        .is_static = is_static,
                        .is_private = is_private,
                        .decorators = decos,
                        .descriptor_name = desc_name,
                        .method_body = m_body,
                        .method_params = m_params,
                        .deco_var_name = deco_vname,
                    });
                }

                if (is_private_method) {
                    // private decorated method → getter로 교체: get #method() { return _descriptor.value; }
                    const info = member_infos.items[member_infos.items.len - 1];
                    const desc_ref = try makeIdentifier(self, info.descriptor_name.?);
                    const val_key = try makeIdentifier(self, "value");
                    const return_expr = try es_helpers.makeStaticMember(self, desc_ref, val_key, zero_span);
                    const getter = try self.buildGetterMethod(new_key, return_expr, is_static, member.span);
                    try new_members.append(self.allocator, getter);
                } else {
                    // public method 또는 non-decorated → 그대로 추가
                    const new_body = try self.visitNode(self.readNodeIdx(me, ast_mod.MethodExtra.body));
                    const empty_list = try self.ast.addNodeList(&.{});
                    const new_method = try self.addExtraNode(.method_definition, member.span, &.{
                        @intFromEnum(new_key),
                        self.readU32(me, ast_mod.MethodExtra.params),
                        @intFromEnum(new_body),
                        flags,
                        empty_list.start,
                        empty_list.len,
                    });
                    try new_members.append(self.allocator, new_method);
                }
            } else if (member.tag == .property_definition) {
                const flags = self.readU32(me, ast_mod.PropertyExtra.flags);
                const deco_start = self.readU32(me, ast_mod.PropertyExtra.deco_start);
                const deco_len = self.readU32(me, ast_mod.PropertyExtra.deco_len);
                const is_static = (flags & ast_mod.PropertyFlags.is_static) != 0;

                // key를 한 번만 방문
                const key_idx_prop = self.readNodeIdx(me, ast_mod.PropertyExtra.key);
                const new_key = try self.visitNode(key_idx_prop);
                const is_private_field = self.ast.getNode(key_idx_prop).tag == .private_identifier;

                var field_init_name: ?[]const u8 = null;
                if (deco_len > 0) {
                    const name_node_idx = try self.memberKeyToStringLiteral(new_key);
                    const decos = try self.collectStage3Decorators(deco_start, deco_len);
                    const var_n = extractCleanVarName(self, name_node_idx);
                    const deco_vname = try std.fmt.allocPrint(self.allocator, "_{s}_decorators", .{var_n});

                    if (is_static) has_static_decorators = true else has_instance_decorators = true;

                    const names = try self.buildFieldInitNames(name_node_idx);
                    field_init_name = names.init_name;

                    try member_infos.append(self.allocator, .{
                        .kind = "field",
                        .name = name_node_idx,
                        .is_static = is_static,
                        .is_private = is_private_field,
                        .decorators = decos,
                        .initializers_name = names.init_name,
                        .extra_initializers_name = names.extra_name,
                        .deco_var_name = deco_vname,
                    });
                }

                // property를 decorator 없이 추가 (decorated면 초기값을 __runInitializers로 래핑)
                const raw_init = try self.visitNode(self.readNodeIdx(me, ast_mod.PropertyExtra.init));
                const new_init = if (field_init_name) |init_name| blk: {
                    // TypeScript 패턴: (runInit(this, _prevExtra), runInit(this, _x_initializers, val))
                    // 첫 field: _prevExtra = _instanceExtraInitializers
                    // 이후 field: _prevExtra = 이전 field의 _extraInitializers
                    const this_node = try self.ast.addNode(.{
                        .tag = .this_expression,
                        .span = zero_span,
                        .data = .{ .none = 0 },
                    });
                    const callee = try makeIdentifier(self, "__runInitializers");
                    const init_arr = try makeIdentifier(self, init_name);
                    const init_call = if (!raw_init.isNone()) init_blk: {
                        const args = try self.ast.addNodeList(&.{ this_node, init_arr, raw_init });
                        break :init_blk try self.addExtraNode(.call_expression, zero_span, &.{
                            @intFromEnum(callee), args.start, args.len, 0,
                        });
                    } else init_blk: {
                        // 초기값 없어도 void 0을 명시적으로 전달 — __runInitializers가 arguments.length > 2를 체크
                        const void0 = try makeIdentifier(self, "void 0");
                        const args = try self.ast.addNodeList(&.{ this_node, init_arr, void0 });
                        break :init_blk try self.addExtraNode(.call_expression, zero_span, &.{
                            @intFromEnum(callee), args.start, args.len, 0,
                        });
                    };

                    // instance field만 initializer 체이닝 적용 (static은 static block에서 처리)
                    if (!is_static) {
                        const prev_extra = last_instance_field_extra orelse "_instanceExtraInitializers";
                        const result = try buildPiggybackedInitCall(self, prev_extra, init_call);
                        const info = member_infos.items[member_infos.items.len - 1];
                        if (info.extra_initializers_name) |extra_name| {
                            last_instance_field_extra = extra_name;
                        }
                        break :blk result;
                    } else {
                        break :blk init_call;
                    }
                } else raw_init;
                const empty_list = try self.ast.addNodeList(&.{});
                const new_prop = try self.addExtraNode(.property_definition, member.span, &.{
                    @intFromEnum(new_key),
                    @intFromEnum(new_init),
                    flags,
                    empty_list.start,
                    empty_list.len,
                });
                try new_members.append(self.allocator, new_prop);
            } else if (member.tag == .accessor_property) {
                const flags = self.readU32(me, ast_mod.PropertyExtra.flags);
                const deco_start = self.readU32(me, ast_mod.PropertyExtra.deco_start);
                const deco_len = self.readU32(me, ast_mod.PropertyExtra.deco_len);
                const is_static = (flags & ast_mod.PropertyFlags.is_static) != 0;

                const key_idx = self.readNodeIdx(me, ast_mod.PropertyExtra.key);
                const new_key = try self.visitNode(key_idx);
                const new_init = try self.visitNode(self.readNodeIdx(me, ast_mod.PropertyExtra.init));
                const is_private_accessor = self.ast.getNode(key_idx).tag == .private_identifier;

                if (deco_len > 0) {
                    const name_node_idx = try self.memberKeyToStringLiteral(new_key);
                    const decos = try self.collectStage3Decorators(deco_start, deco_len);
                    const var_n = extractCleanVarName(self, name_node_idx);
                    const deco_vname = try std.fmt.allocPrint(self.allocator, "_{s}_decorators", .{var_n});

                    if (is_static) has_static_decorators = true else has_instance_decorators = true;

                    const names = try self.buildFieldInitNames(name_node_idx);

                    try member_infos.append(self.allocator, .{
                        .kind = "accessor",
                        .name = name_node_idx,
                        .is_static = is_static,
                        .is_private = is_private_accessor,
                        .decorators = decos,
                        .initializers_name = names.init_name,
                        .extra_initializers_name = names.extra_name,
                        .deco_var_name = deco_vname,
                    });

                    // accessor → private backing field + getter + setter.
                    // PrivateNameAllocator 가 `_x_accessor_storage` → 이미 사용
                    // 중이면 `_x_accessor_storage2` 처럼 회피.
                    const storage_base = try std.fmt.allocPrint(self.allocator, "_{s}_accessor_storage", .{var_n});
                    defer self.allocator.free(storage_base);
                    const storage_local = try private_name_allocator.makeUniqueName(storage_base);
                    defer self.allocator.free(storage_local);
                    const storage_name = try std.fmt.allocPrint(self.allocator, "#{s}", .{storage_local});
                    defer self.allocator.free(storage_name);
                    const storage_span = try self.ast.addString(storage_name);
                    const storage_key = try self.ast.addNode(.{
                        .tag = .private_identifier,
                        .span = storage_span,
                        .data = .{ .string_ref = storage_span },
                    });
                    // 초기값: TypeScript 패턴 — (runInit(this, _prevExtra), runInit(this, _x_initializers, val))
                    const init_val = blk: {
                        const init_call = if (!new_init.isNone()) init_blk: {
                            const this_node = try self.ast.addNode(.{
                                .tag = .this_expression,
                                .span = zero_span,
                                .data = .{ .none = 0 },
                            });
                            const callee = try makeIdentifier(self, "__runInitializers");
                            const init_arr_ref = try makeIdentifier(self, names.init_name);
                            const args = try self.ast.addNodeList(&.{ this_node, init_arr_ref, new_init });
                            break :init_blk try self.addExtraNode(.call_expression, zero_span, &.{
                                @intFromEnum(callee), args.start, args.len, 0,
                            });
                        } else NodeIndex.none;

                        // instance accessor만 initializer 체이닝 적용
                        if (!is_static) {
                            const prev_extra = last_instance_field_extra orelse "_instanceExtraInitializers";
                            last_instance_field_extra = names.extra_name;
                            break :blk try buildPiggybackedInitCall(self, prev_extra, init_call);
                        } else {
                            break :blk init_call;
                        }
                    };

                    const empty_decos = try self.ast.addNodeList(&.{});
                    const backing_field = try self.addExtraNode(.property_definition, member.span, &.{
                        @intFromEnum(storage_key),
                        @intFromEnum(init_val),
                        flags, // static 플래그 보존
                        empty_decos.start,
                        empty_decos.len,
                    });
                    try new_members.append(self.allocator, backing_field);

                    // get x() { return this.#_x_accessor_storage; }
                    // .private_field_expression 태그 필수 — .static_member_expression 으로 만들면
                    // transformer.zig:899 private field WeakMap dispatch 를 못 탐 (Stage 3 출력 재방문 경로에서만
                    // 우연히 동작하던 것을 안정화).
                    //
                    // 이전: public accessor 일 때 `data.string_ref` 를 가정하고 새
                    // identifier_reference 노드를 합성. computed key (`accessor ["x"]`)
                    // 처럼 다른 union variant (`unary.operand`) 를 가진 key 면
                    // garbage span 으로 합성돼 codegen 단계에서 slice panic 발화.
                    // 같은 NodeIndex 를 getter/setter 양쪽에서 공유 — codegen 은
                    // index 만 보고 emit 하므로 안전 — method-level decorator
                    // computed key path 와 동일 방향.
                    {
                        const return_expr = try makeThisPrivateField(self, storage_span);
                        const getter = try self.buildGetterMethod(new_key, return_expr, is_static, zero_span);
                        try new_members.append(self.allocator, getter);
                    }

                    // set x(value) { this.#_x_accessor_storage = value; }
                    {
                        const assign_target = try makeThisPrivateField(self, storage_span);
                        const setter = try self.buildSetterMethod(new_key, assign_target, is_static, zero_span);
                        try new_members.append(self.allocator, setter);
                    }
                } else {
                    // decorator 없는 accessor → 그대로 유지
                    const empty_list = try self.ast.addNodeList(&.{});
                    const new_acc = try self.addExtraNode(.accessor_property, member.span, &.{
                        @intFromEnum(new_key),
                        @intFromEnum(new_init),
                        flags,
                        empty_list.start,
                        empty_list.len,
                    });
                    try new_members.append(self.allocator, new_acc);
                }
            } else {
                // static_block 등 그대로 방문하여 추가
                const visited = try self.visitNode(member_idx);
                if (!visited.isNone()) {
                    try new_members.append(self.allocator, visited);
                }
            }
        }
    }

    // ---- IIFE 구조 생성 ----
    // 전체 출력:
    //   let Foo = (() => {
    //     let _classDecorators = [...]; ...
    //     var Foo = class [extends Super] { ... };
    //     return Foo = _classThis;
    //   })();

    // __esDecorate 호출 목록 (static {} 블록에 넣을 것)
    var static_block_stmts: std.ArrayList(NodeIndex) = .empty;
    defer static_block_stmts.deinit(self.allocator);

    // IIFE 내부 let 선언 목록
    var iife_stmts: std.ArrayList(NodeIndex) = .empty;
    defer iife_stmts.deinit(self.allocator);

    // _classThis 변수
    const classThis_span = try self.ast.addString("_classThis");

    // static { _classThis = this; }
    {
        const classThis_ref = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = classThis_span,
            .data = .{ .string_ref = classThis_span },
        });
        const this_node = try self.ast.addNode(.{
            .tag = .this_expression,
            .span = zero_span,
            .data = .{ .none = 0 },
        });
        const assign = try self.ast.addNode(.{
            .tag = .assignment_expression,
            .span = zero_span,
            .data = .{ .binary = .{ .left = classThis_ref, .right = this_node, .flags = 0 } },
        });
        const assign_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
        });
        const static_body_list = try self.ast.addNodeList(&.{assign_stmt});
        const static_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = zero_span,
            .data = .{ .list = static_body_list },
        });
        const static_block = try self.ast.addNode(.{
            .tag = .static_block,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = static_body, .flags = 0 } },
        });
        try new_members.insert(self.allocator, 0, static_block);
    }

    // _metadata 선언 + member __esDecorate 호출 + class __esDecorate 호출
    // → 2번째 static { } 블록에 모두 넣기

    // const _metadata = typeof Symbol === "function" && Symbol.metadata ? Object.create(null) : void 0;
    const metadata_decl = try self.buildMetadataDecl();
    try static_block_stmts.append(self.allocator, metadata_decl);

    // TC39 스펙 decorator 순서:
    // 1단계: 모든 member decorator 식을 **소스 순서**로 평가하여 변수에 저장
    // 2단계: __esDecorate를 **스펙 순서**로 호출
    //   (static non-field → instance non-field → static field → instance field)

    // 1단계: 소스 순서로 식 평가 → _name_decorators = [dec1, dec2];
    for (member_infos.items) |info| {
        if (info.deco_var_name) |vname| {
            const deco_list = try self.ast.addNodeList(info.decorators);
            const deco_arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = zero_span,
                .data = .{ .list = deco_list },
            });
            const var_ref = try makeIdentifier(self, vname);
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = zero_span,
                .data = .{ .binary = .{ .left = var_ref, .right = deco_arr, .flags = 0 } },
            });
            try static_block_stmts.append(self.allocator, try es_helpers.makeExprStmt(self, assign, zero_span));
        }
    }

    // 2단계: 스펙 순서로 __esDecorate 호출
    const is_non_field = struct {
        fn check(kind: []const u8) bool {
            return !std.mem.eql(u8, kind, "field");
        }
    }.check;
    // [is_static, is_non_field] — 4 pass: static non-field → instance non-field → static field → instance field
    const passes = [_][2]bool{ .{ true, true }, .{ false, true }, .{ true, false }, .{ false, false } };
    for (passes) |pass| {
        const want_static = pass[0];
        const want_non_field = pass[1];
        for (member_infos.items) |info| {
            if (info.is_static == want_static and is_non_field(info.kind) == want_non_field) {
                try self.appendEsDecorateStmt(&static_block_stmts, info);
            }
        }
    }

    // class decorator __esDecorate 호출 (식 평가는 이미 IIFE 최상단 let 선언에서 완료)
    if (class_deco_len > 0) {
        const class_call = try self.buildClassEsDecorateCall(classThis_span);
        const class_call_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = class_call, .flags = 0 } },
        });
        try static_block_stmts.append(self.allocator, class_call_stmt);

        // Foo = _classThis = _classDescriptor.value;
        const reassign = try self.buildClassReassign(class_name_text, classThis_span);
        try static_block_stmts.append(self.allocator, reassign);
    }

    // if (_metadata) Object.defineProperty(_classThis, Symbol.metadata, { enumerable: true, configurable: true, writable: true, value: _metadata });
    {
        const metadata_define = try self.buildMetadataDefineProperty(classThis_span);
        try static_block_stmts.append(self.allocator, metadata_define);
    }

    // __runInitializers(_classThis, _classExtraInitializers);
    if (class_deco_len > 0) {
        const run_init = try self.buildRunInitializersCall(classThis_span, "_classExtraInitializers");
        const run_init_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = run_init, .flags = 0 } },
        });
        try static_block_stmts.append(self.allocator, run_init_stmt);
    }

    // 2번째 static { } 블록 생성
    if (static_block_stmts.items.len > 0) {
        const sb_body_list = try self.ast.addNodeList(static_block_stmts.items);
        const sb_body = try self.ast.addNode(.{
            .tag = .block_statement,
            .span = zero_span,
            .data = .{ .list = sb_body_list },
        });
        const sb = try self.ast.addNode(.{
            .tag = .static_block,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = sb_body, .flags = 0 } },
        });
        // 첫 static block 뒤에 삽입 (index 1)
        try new_members.insert(self.allocator, 1, sb);
    }

    // constructor에 __runInitializers 삽입
    // TypeScript 패턴:
    //   - field/accessor decorator 있을 때: constructor 앞에 마지막 field의 _extraInitializers 삽입
    //     (_instanceExtraInitializers는 첫 field 초기화에 piggyback됨)
    //   - field/accessor decorator 없을 때: constructor 앞에 _instanceExtraInitializers 삽입
    if (has_instance_decorators) {
        // constructor에 삽입할 initializer 이름 결정
        const ctor_init_name = last_instance_field_extra orelse "_instanceExtraInitializers";

        const this_node = try self.ast.addNode(.{
            .tag = .this_expression,
            .span = zero_span,
            .data = .{ .none = 0 },
        });
        const run_init = try self.buildRunInitializersCall2(this_node, ctor_init_name);
        const run_init_stmt = try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = zero_span,
            .data = .{ .unary = .{ .operand = run_init, .flags = 0 } },
        });

        const has_super = !super_idx.isNone();

        if (has_constructor) {
            // new_members에서 constructor를 key 기반으로 탐색 (static block 삽입에 무관)
            for (new_members.items, 0..) |member_node_idx, mi| {
                const m = self.ast.getNode(member_node_idx);
                if (m.tag != .method_definition) continue;
                const m_flags = self.readU32(m.data.extra, ast_mod.MethodExtra.flags);
                // static/getter/setter 중 하나라도 있으면 skip (plain instance constructor 아님)
                const non_ctor_mask = ast_mod.MethodFlags.is_static | ast_mod.MethodFlags.is_getter | ast_mod.MethodFlags.is_setter;
                if ((m_flags & non_ctor_mask) != 0) continue;
                const m_key_idx = self.readNodeIdx(m.data.extra, 0);
                if (m_key_idx.isNone()) continue;
                const m_key = self.ast.getNode(m_key_idx);
                if (m_key.tag != .identifier_reference and m_key.tag != .binding_identifier) continue;
                if (!std.mem.eql(u8, self.ast.getText(m_key.data.string_ref), "constructor")) continue;

                const old_body_idx = self.readNodeIdx(m.data.extra, 2);
                const new_body_ctor = if (has_super)
                    try insertAfterSuperCall(self, old_body_idx, run_init_stmt)
                else
                    try self.prependStatementsToBody(old_body_idx, &.{run_init_stmt});
                const empty_decos = try self.ast.addNodeList(&.{});
                // method_definition: [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
                const new_ctor_method = try self.addExtraNode(.method_definition, m.span, &.{
                    self.readU32(m.data.extra, 0), // key
                    self.readU32(m.data.extra, 1), // params (formal_parameters idx)
                    @intFromEnum(new_body_ctor),
                    self.readU32(m.data.extra, 3), // flags
                    empty_decos.start,
                    empty_decos.len,
                });
                new_members.items[mi] = new_ctor_method;
                break;
            }
        } else {
            // 합성 constructor: derived면 `constructor(...args) { super(...args); __runInitializers(...); }`,
            // 아니면 `constructor() { __runInitializers(...); }`. super stmt는 scratch에 push, params는 반환.
            const stmts_scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(stmts_scratch_top);

            const ctor_params_node: NodeIndex = if (has_super) blk: {
                const shell = try buildSuperSpreadArgsShell(self);
                try self.scratch.append(self.allocator, shell.super_stmt);
                break :blk shell.params_node;
            } else blk: {
                const empty_params = try self.ast.addNodeList(&.{});
                break :blk try self.ast.addFormalParameters(empty_params, zero_span);
            };
            try self.scratch.append(self.allocator, run_init_stmt);

            const ctor_body_list = try self.ast.addNodeList(self.scratch.items[stmts_scratch_top..]);
            const ctor_body = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = zero_span,
                .data = .{ .list = ctor_body_list },
            });
            const ctor_key_span = try self.ast.addString("constructor");
            const ctor_key = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = ctor_key_span,
                .data = .{ .string_ref = ctor_key_span },
            });
            const empty_decos = try self.ast.addNodeList(&.{});
            const ctor_method = try self.addExtraNode(.method_definition, zero_span, &.{
                @intFromEnum(ctor_key),
                @intFromEnum(ctor_params_node),
                @intFromEnum(ctor_body),
                0, // flags (no static/getter/setter)
                empty_decos.start,
                empty_decos.len,
            });
            try new_members.append(self.allocator, ctor_method);
        }
    }

    // 새 class body 생성
    const new_body_list = try self.ast.addNodeList(new_members.items);
    const new_body = try self.ast.addNode(.{
        .tag = .class_body,
        .span = zero_span,
        .data = .{ .list = new_body_list },
    });

    // var Foo = class [extends Super] { ... } (decorator 없이, 이름 제거)
    // class body 내의 이름 바인딩은 const이므로, static { } 블록에서 Foo = ... 재대입이 불가.
    // TypeScript와 동일하게 class expression에 이름을 제거하여 외부 var Foo를 참조하게 한다.
    const new_super = try self.visitNode(super_idx);
    const empty_decos = try self.ast.addNodeList(&.{});
    const inner_class = try self.addExtraNode(.class_expression, node.span, &.{
        none,              @intFromEnum(new_super), @intFromEnum(new_body),
        none,              0,                       0,
        empty_decos.start, empty_decos.len,
    });

    // IIFE 내부: var Foo = class { ... };
    const inner_name_span = try self.ast.addString(class_name_text);
    const inner_binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = inner_name_span,
        .data = .{ .string_ref = inner_name_span },
    });
    const inner_declarator = try self.addExtraNode(.variable_declarator, zero_span, &.{
        @intFromEnum(inner_binding), none, @intFromEnum(inner_class),
    });
    const inner_decl_list = try self.ast.addNodeList(&.{inner_declarator});
    const inner_var_decl = try self.addExtraNode(.variable_declaration, zero_span, &.{
        0, inner_decl_list.start, inner_decl_list.len, // 0 = var
    });
    try iife_stmts.append(self.allocator, inner_var_decl);

    // return Foo = _classThis;
    const return_name = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = inner_name_span,
        .data = .{ .string_ref = inner_name_span },
    });
    const classThis_ref2 = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = classThis_span,
        .data = .{ .string_ref = classThis_span },
    });
    const return_assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = return_name, .right = classThis_ref2, .flags = 0 } },
    });
    const return_stmt = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = return_assign, .flags = 0 } },
    });
    try iife_stmts.append(self.allocator, return_stmt);

    // IIFE body: { let _classDecorators = ...; ... var Foo = class { ... }; return ...; }
    // let 선언들을 iife_stmts 앞에 삽입
    var all_iife_stmts: std.ArrayList(NodeIndex) = .empty;
    defer all_iife_stmts.deinit(self.allocator);

    // let 선언 생성
    const let_decls = try self.buildStage3LetDeclarations(
        class_deco_start,
        class_deco_len,
        member_infos.items,
        has_instance_decorators,
        has_static_decorators,
    );
    try all_iife_stmts.appendSlice(self.allocator, let_decls);
    self.allocator.free(let_decls);

    // var Foo = class { ... }; + return ...;
    try all_iife_stmts.appendSlice(self.allocator, iife_stmts.items);

    const iife_body_list = try self.ast.addNodeList(all_iife_stmts.items);
    const iife_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = zero_span,
        .data = .{ .list = iife_body_list },
    });

    // () => { ... }
    // arrow_function_expression: extra = [params(0), body(1), flags]
    // params = .none → codegen이 "()" 출력
    const arrow = try self.addExtraNode(.arrow_function_expression, zero_span, &.{
        none, // params = .none (빈 파라미터)
        @intFromEnum(iife_body),
        0, // flags (not async)
    });

    // (() => { ... })()
    const paren_arrow = try self.ast.addNode(.{
        .tag = .parenthesized_expression,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = arrow, .flags = 0 } },
    });
    const empty_args = try self.ast.addNodeList(&.{});
    const iife_call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(paren_arrow), empty_args.start, empty_args.len, 0,
    });

    // class expression / 익명 class / export default class → IIFE call 직접 반환
    // 이름 있는 class declaration만 `let Foo = (...)` 선언을 사용.
    // - class_expression: 표현식 위치에서 사용
    // - name_idx.isNone(): 익명 class (export default class {} 등)
    // - name == "default": export default class (JS 예약어)
    const has_named_binding = if (!name_idx.isNone()) blk: {
        break :blk !std.mem.eql(u8, self.ast.getText(self.ast.getNode(name_idx).data.string_ref), "default");
    } else false;

    if (node.tag == .class_expression or !has_named_binding) {
        return iife_call;
    }

    // class declaration → let Foo = (() => { ... })();
    // "default" 이름은 IIFE 내부 var에서 사용한 temp var name을 재사용
    const outer_name_span = try self.ast.addString(class_name_text);

    const outer_binding = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = outer_name_span,
        .data = .{ .string_ref = outer_name_span },
    });
    const outer_declarator = try self.addExtraNode(.variable_declarator, zero_span, &.{
        @intFromEnum(outer_binding), none, @intFromEnum(iife_call),
    });
    const outer_decl_list = try self.ast.addNodeList(&.{outer_declarator});
    const outer_var_decl = try self.addExtraNode(.variable_declaration, zero_span, &.{
        1, outer_decl_list.start, outer_decl_list.len, // 1 = let
    });

    // pending_nodes로 hoist한 뒤 `.none` 반환 — export 컨텍스트에서
    // `export default Named;` / `export { Named };`로 분리되는 pattern을 유지한다.
    // ES5 target은 outer_var_decl 내부의 arrow/let/class/static block을 추가 다운레벨링하기
    // 위해 pending에 push하기 전에 visitNode로 재방문한다.
    const to_hoist = if (self.options.unsupported.class)
        try self.visitNode(outer_var_decl)
    else
        outer_var_decl;
    if (!to_hoist.isNone()) {
        try self.pending_nodes.append(self.allocator, to_hoist);
    }
    return .none;
}

/// field/accessor 초기화에 이전 extra initializers를 piggyback하는 sequence expression 생성.
/// TypeScript 패턴: `(__runInitializers(this, _prevExtra), __runInitializers(this, _x_initializers, val))`
/// init_call이 .none이면 prevCall만 반환 (초기값 없는 accessor).
fn buildPiggybackedInitCall(self: *Transformer, prev_extra_name: []const u8, init_call: NodeIndex) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const prev_this = try self.ast.addNode(.{
        .tag = .this_expression,
        .span = zero_span,
        .data = .{ .none = 0 },
    });
    const prev_callee = try makeIdentifier(self, "__runInitializers");
    const prev_arr = try makeIdentifier(self, prev_extra_name);
    const prev_args = try self.ast.addNodeList(&.{ prev_this, prev_arr });
    const prev_call = try self.addExtraNode(.call_expression, zero_span, &.{
        @intFromEnum(prev_callee), prev_args.start, prev_args.len, 0,
    });
    if (!init_call.isNone()) {
        const seq_list = try self.ast.addNodeList(&.{ prev_call, init_call });
        const seq = try self.ast.addNode(.{
            .tag = .sequence_expression,
            .span = zero_span,
            .data = .{ .list = seq_list },
        });
        return es_helpers.makeParenExpr(self, seq, zero_span);
    } else {
        return prev_call;
    }
}
