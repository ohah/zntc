//! Primary class visitor fast path helpers.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const PrivateMethodMapping = Transformer.PrivateMethodMapping;
const es_helpers = @import("../es_helpers.zig");
const es2022 = @import("../es2022.zig");

pub fn visitClass(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;

    if (self.options.use_define_for_class_fields and !self.options.experimental_decorators) {
        const raw_name_idx = self.readNodeIdx(e, ast_mod.ClassExtra.name);
        var new_name = if (shouldDropClassExprName(self, node.tag, raw_name_idx))
            ast_mod.NodeIndex.none
        else
            try self.visitNode(raw_name_idx);
        const super_idx = self.readNodeIdx(e, ast_mod.ClassExtra.super);
        const new_super = try self.visitNode(super_idx);

        // VANON fix: anonymous class_expression + static private member 일 때 tmp name 부여를
        // V8 fix 보다 *앞* 으로 이동. 그러면 V8 fix 의 class_name_span_opt 가 새로 합성된 tmp
        // 이름을 보고 proto_chain 활성화 → super-prop access 시 raw extends inline (side-effect
        // 중복) 회피. body_idx 만 미리 읽어 classBodyHasStaticPrivateMember 검사.
        const _anon_body_idx = self.readNodeIdx(e, ast_mod.ClassExtra.body);
        const _lower_pm_pre = self.options.unsupported.class_private_method;
        const _lower_pf_pre = self.options.unsupported.class_private_field;
        if ((_lower_pm_pre or _lower_pf_pre) and node.tag == .class_expression and new_name.isNone() and
            classBodyHasStaticPrivateMember(self, _anon_body_idx, _lower_pm_pre, _lower_pf_pre))
        {
            const tmp_span = try es_helpers.makeTempVarSpan(self);
            new_name = try es_helpers.makeBindingIdentifier(self, tmp_span);
        }

        const saved_super_class = self.current_super_class;
        const saved_super_class_old_idx = self.current_super_class_old_idx;
        // #3680-F5/F6: inner class 가 extends 없으면 outer 의 current_super_class 를 명시적으로 null 로
        // 끊어야 한다 (else null reset 누락 시 outer Base 누수 → 새 flag 로 silent miscompile).
        // F6: fast path 도 super_class 와 동시에 old_idx 를 set — 새 flag 로 fast path 에서도 super
        // lowering 이 활성화되니 symbol propagation (minify rename 등) 을 위해 필요.
        //
        // V8 정밀 fix: extends 가 non-identifier (e.g. `extends getBase()`) 이고 class 가
        // named (class_declaration / named class_expression) 이면 super-prop lowering 이
        // raw extends text 를 매 access 마다 inline 하지 않도록 — current_super_class 를
        // class 자체의 이름으로 set 하고 `current_super_via_proto_chain=true` 로 mark.
        // buildSuperBaseRef 가 이 flag 보고 `Object.getPrototypeOf(<ClassName>.prototype)`
        // 형태로 emit → extends 표현식 1회만 평가됨 (spec) + bundler tree-shake 자연스러움.
        // anonymous class_expression 은 class 자체에 referenceable name 이 없어 fallback
        // (기존 raw extends text inline; side-effect 중복 가능하나 anon class extends getBase()
        // + private member 조합 자체가 극히 드묾).
        const saved_super_via_proto_chain = self.current_super_via_proto_chain;
        self.current_super_via_proto_chain = false;
        defer self.current_super_via_proto_chain = saved_super_via_proto_chain;
        // VSHADOW: V8 fix trigger 시 alias var decl 을 별도 array 에 reserve, class 뒤에 emit.
        // method body 안 super-prop access 는 alias 식별자 (unique tmp name) 참조 → local
        // `let D = 1` shadow 영향 차단. alias init 식은 class 와 *같은* outer scope 에서 평가되어
        // raw class binding D 를 정확히 참조.
        var super_proto_alias_decl: ?NodeIndex = null;
        if (!super_idx.isNone()) {
            const super_node = self.ast.getNode(super_idx);
            const is_simple_id = super_node.tag == .identifier_reference or super_node.tag == .binding_identifier;
            // class self name: raw_name_idx (source 의 binding) 우선, 없으면 visit 결과 new_name.
            const class_name_span_opt: ?Span = self.getClassNameSpan(raw_name_idx) orelse self.getClassNameSpan(new_name);
            if (!is_simple_id and class_name_span_opt != null) {
                // VSHADOW: alias var 생성 — `var _<n>_super = globalThis.Object.getPrototypeOf(D.prototype)`
                // (instance) 또는 `... = globalThis.Object.getPrototypeOf(D)` (static, 단 fast path
                // class 진입 시 is_static=false 로 reset 되므로 instance form 만 emit; static private
                // method body 안에서 V8 trigger 되는 케이스는 buildStandaloneFunc 의 is_static set 이
                // 별도 처리 — 여기 alias 는 instance prototype 기준).
                const alias_span = try es_helpers.makeTempVarSpan(self);
                const alias_binding = try es_helpers.makeBindingIdentifier(self, alias_span);
                const class_old_idx = if (!raw_name_idx.isNone()) raw_name_idx else NodeIndex.none;
                const class_ref = try self.makeIdentifierRefWithSymbol(class_name_span_opt.?, class_old_idx);
                const proto_prop = try es_helpers.makeIdentifierRef(self, "prototype");
                const class_proto = try es_helpers.makeStaticMember(self, class_ref, proto_prop, node.span);
                const global_ref = try es_helpers.makeIdentifierRef(self, "globalThis");
                const object_ref = try es_helpers.makeIdentifierRef(self, "Object");
                const get_proto = try es_helpers.makeIdentifierRef(self, "getPrototypeOf");
                const global_object = try es_helpers.makeStaticMember(self, global_ref, object_ref, node.span);
                const callee = try es_helpers.makeStaticMember(self, global_object, get_proto, node.span);
                const init_call = try es_helpers.makeCallExpr(self, callee, &.{class_proto}, node.span);
                const declarator = try es_helpers.makeDeclarator(self, alias_binding, init_call, node.span);
                super_proto_alias_decl = try es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", node.span);
                // super-prop access 가 alias 식별자 그대로 참조하도록 set.
                self.current_super_class = alias_span;
                self.current_super_class_old_idx = .none;
                self.current_super_via_proto_chain = true;
            } else {
                self.current_super_class = super_node.span;
                self.current_super_class_old_idx = super_idx;
            }
        } else {
            self.current_super_class = null;
            self.current_super_class_old_idx = .none;
        }
        defer self.current_super_class = saved_super_class;
        defer self.current_super_class_old_idx = saved_super_class_old_idx;
        // V4 fix: es2015_class.zig (IIFE path) 와 일관성 — class 진입 시 is_static/static_receiver
        // 도 outer 의 누수 차단. 예: outer static private field init (V3 시나리오) 에서 inner class
        // 진입 시 is_static=true 가 그대로 leak 되면 inner instance method 가 static form 으로 잘못
        // lowering 됨.
        const saved_super_is_static = self.current_super_is_static;
        const saved_super_static_receiver = self.current_super_static_receiver;
        self.current_super_is_static = false;
        self.current_super_static_receiver = null;
        defer self.current_super_is_static = saved_super_is_static;
        defer self.current_super_static_receiver = saved_super_static_receiver;
        // #3680: 우리가 outer standalone fn body 안에서 visit 중이라도 inner class body 의
        // `super` 는 lexical 로 valid 하므로 flag 를 reset. (inner private method 가 다시
        // 추출되면 buildStandaloneFunc 가 다시 true 로 set.)
        const saved_super_in_extracted_fn = self.current_super_in_extracted_fn;
        self.current_super_in_extracted_fn = false;
        defer self.current_super_in_extracted_fn = saved_super_in_extracted_fn;

        var current_body_idx = self.readNodeIdx(e, ast_mod.ClassExtra.body);

        var pre_stmts: std.ArrayList(NodeIndex) = .empty;
        defer pre_stmts.deinit(self.allocator);
        var ctor_stmts: std.ArrayList(NodeIndex) = .empty;
        defer ctor_stmts.deinit(self.allocator);
        var pm_mappings: std.ArrayList(PrivateMethodMapping) = .empty;
        defer {
            for (pm_mappings.items) |pm| {
                self.allocator.free(pm.weakset_name);
                self.allocator.free(pm.func_name);
            }
            pm_mappings.deinit(self.allocator);
        }
        var pf_mappings: std.ArrayList(Transformer.PrivateFieldMapping) = .empty;
        defer {
            for (pf_mappings.items) |pf| {
                self.allocator.free(pf.var_name);
            }
            pf_mappings.deinit(self.allocator);
        }

        const lower_pm = self.options.unsupported.class_private_method;
        const lower_pf = self.options.unsupported.class_private_field;
        // VANON fix: tmp name 합성은 이미 V8 fix 앞에서 처리됨 (위 _anon_body_idx 블록). 여기선 no-op.
        var had_private_methods = false;
        var had_private_fields = false;

        // V1 정밀 fix: static descriptor 를 별도 array 로 받아 *class declaration 뒤,
        // static block IIFE 앞* 에 emit 한다 (receiver=D 가 init 후 평가되도록 + IIFE 가
        // descriptor 참조 가능하도록).
        var static_descriptors: std.ArrayList(NodeIndex) = .empty;
        defer static_descriptors.deinit(self.allocator);

        if (lower_pm or lower_pf) {
            const has_super = !self.readNodeIdx(e, 1).isNone();
            const class_name_text: ?[]const u8 = if (self.getClassNameSpan(new_name)) |s|
                self.ast.getText(s)
            else
                null;
            var new_body: NodeIndex = .none;
            // V_EXPR fix: class_declaration 과 class_expression 모두 별도 array 사용.
            // class_expression 의 경우 wrapClassExprInIIFE 가 post_stmts 위치 (IIFE 안 class_decl
            // 뒤) 로 emit 하므로 TDZ 회피.
            const desc_out: ?*std.ArrayList(NodeIndex) = &static_descriptors;
            const had_any = try es2022.ES2022(Transformer).lowerPrivateMembers(
                self,
                current_body_idx,
                &new_body,
                &pre_stmts,
                &ctor_stmts,
                &pm_mappings,
                &pf_mappings,
                lower_pm,
                lower_pf,
                has_super,
                class_name_text,
                false, // fast path 는 lowerPrivateMembers 가 통째 visit + 복원 (기존 동작).
                desc_out,
            );
            if (had_any) {
                current_body_idx = new_body;
                had_private_methods = pm_mappings.items.len > 0;
                had_private_fields = pf_mappings.items.len > 0;
            }
        }

        if (self.options.unsupported.class_static_block) {
            var new_body: NodeIndex = .none;
            var static_key_memos: std.ArrayList(NodeIndex) = .empty;
            defer static_key_memos.deinit(self.allocator);
            var static_block_iifes: std.ArrayList(NodeIndex) = .empty;
            defer static_block_iifes.deinit(self.allocator);

            const class_name_span = self.getClassNameSpan(new_name);
            const already_visited = had_private_methods or had_private_fields;
            const had_static_blocks = try es2022.ES2022(Transformer).lowerStaticBlocks(
                self,
                current_body_idx,
                &new_body,
                &static_key_memos,
                &static_block_iifes,
                class_name_span,
                already_visited,
            );

            if (had_static_blocks) {
                current_body_idx = new_body;

                const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, ast_mod.ClassExtra.deco_start), .len = self.readU32(e, ast_mod.ClassExtra.deco_len) });
                const none = @intFromEnum(NodeIndex.none);
                const class_result = try self.addExtraNode(node.tag, node.span, &.{
                    @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(current_body_idx),
                    none,                   0,                       0,
                    new_decos.start,        new_decos.len,
                });

                if (node.tag == .class_expression) {
                    // V_EXPR fix: post_stmts = super_alias + static_descriptors + static_block_iifes
                    // — alias/descriptor 가 IIFE 안에서 class_decl 뒤에 emit (receiver=D TDZ 회피).
                    const scratch_top_e = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top_e);
                    if (super_proto_alias_decl) |alias_decl| try self.scratch.append(self.allocator, alias_decl);
                    try self.scratch.appendSlice(self.allocator, static_descriptors.items);
                    try self.scratch.appendSlice(self.allocator, static_block_iifes.items);
                    return wrapClassExprInIIFE(
                        self,
                        static_key_memos.items,
                        pre_stmts.items,
                        class_result,
                        self.scratch.items[scratch_top_e..],
                        new_name,
                        node.span,
                    );
                }

                for (static_key_memos.items) |stmt| {
                    try self.pending_nodes.append(self.allocator, stmt);
                }
                for (pre_stmts.items) |stmt| {
                    try self.pending_nodes.append(self.allocator, stmt);
                }
                try self.pending_nodes.append(self.allocator, class_result);
                // VSHADOW: V8 fix 의 super-prop alias 를 class 뒤에 emit (D init 후 평가되도록).
                if (super_proto_alias_decl) |alias_decl| try self.pending_nodes.append(self.allocator, alias_decl);
                // V1 정밀 fix: static descriptor 는 class 뒤, static block IIFE 앞에 emit.
                // receiver=D 가 init 후 평가됨 + IIFE 가 descriptor (_n 등) 참조 가능.
                for (static_descriptors.items) |desc| {
                    try self.pending_nodes.append(self.allocator, desc);
                }
                for (static_block_iifes.items) |iife| {
                    try self.pending_nodes.append(self.allocator, iife);
                }
                return .none;
            }
        }

        if (had_private_methods or had_private_fields) {
            const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, ast_mod.ClassExtra.deco_start), .len = self.readU32(e, ast_mod.ClassExtra.deco_len) });
            const none = @intFromEnum(NodeIndex.none);
            const class_result = try self.addExtraNode(node.tag, node.span, &.{
                @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(current_body_idx),
                none,                   0,                       0,
                new_decos.start,        new_decos.len,
            });

            if (node.tag == .class_expression) {
                // V_EXPR + VSHADOW fix: super_alias + descriptor 를 IIFE 안 class_decl 뒤에 emit.
                const scratch_top_e2 = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(scratch_top_e2);
                if (super_proto_alias_decl) |alias_decl| try self.scratch.append(self.allocator, alias_decl);
                try self.scratch.appendSlice(self.allocator, static_descriptors.items);
                return wrapClassExprInIIFE(
                    self,
                    &.{},
                    pre_stmts.items,
                    class_result,
                    self.scratch.items[scratch_top_e2..],
                    new_name,
                    node.span,
                );
            }

            for (pre_stmts.items) |stmt| {
                try self.pending_nodes.append(self.allocator, stmt);
            }
            try self.pending_nodes.append(self.allocator, class_result);
            // VSHADOW: super-prop alias 를 class 뒤에 emit.
            if (super_proto_alias_decl) |alias_decl| try self.pending_nodes.append(self.allocator, alias_decl);
            // V1 정밀 fix: static descriptor 를 class 뒤에 emit (static block 없이 private
            // member 만 있는 경로).
            for (static_descriptors.items) |desc| {
                try self.pending_nodes.append(self.allocator, desc);
            }
            return .none;
        }

        const new_body = try self.visitNode(current_body_idx);
        const new_decos = try self.visitExtraList(.{ .start = self.readU32(e, ast_mod.ClassExtra.deco_start), .len = self.readU32(e, ast_mod.ClassExtra.deco_len) });
        const none = @intFromEnum(NodeIndex.none);
        return self.addExtraNode(node.tag, node.span, &.{
            @intFromEnum(new_name), @intFromEnum(new_super), @intFromEnum(new_body),
            none,                   0,                       0,
            new_decos.start,        new_decos.len,
        });
    }

    return self.visitClassWithAssignSemantics(node);
}

pub fn classBodyHasStaticPrivateMember(self: *Transformer, body_idx: NodeIndex, lower_methods: bool, lower_fields: bool) bool {
    if (body_idx.isNone()) return false;
    const body_node = self.ast.getNode(body_idx);
    if (body_node.tag != .class_body) return false;

    const start = body_node.data.list.start;
    const len = body_node.data.list.len;
    if (start + len > self.ast.extra_data.items.len) return false;

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const member = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[start + i]));
        switch (member.tag) {
            .method_definition => {
                if (!lower_methods) continue;
                const e = member.data.extra;
                if (e + ast_mod.MethodExtra.flags >= self.ast.extra_data.items.len) continue;
                const flags = self.readU32(e, ast_mod.MethodExtra.flags);
                if ((flags & ast_mod.MethodFlags.is_static) == 0) continue;
                const key = self.readNodeIdx(e, ast_mod.MethodExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .private_identifier) return true;
            },
            .property_definition => {
                if (!lower_fields) continue;
                const e = member.data.extra;
                if (e + ast_mod.PropertyExtra.flags >= self.ast.extra_data.items.len) continue;
                const flags = self.readU32(e, ast_mod.PropertyExtra.flags);
                if ((flags & ast_mod.PropertyFlags.is_static) == 0) continue;
                const key = self.readNodeIdx(e, ast_mod.PropertyExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .private_identifier) return true;
            },
            else => {},
        }
    }

    return false;
}

pub fn wrapClassExprInIIFE(
    self: *Transformer,
    pre_stmts_a: []const NodeIndex,
    pre_stmts_b: []const NodeIndex,
    class_expr_node: NodeIndex,
    post_stmts: []const NodeIndex,
    new_name: NodeIndex,
    span: Span,
) Error!NodeIndex {
    var decl_name = new_name;
    const ret_name_span: Span = if (decl_name.isNone()) blk: {
        const tmp_span = try es_helpers.makeTempVarSpan(self);
        decl_name = try es_helpers.makeBindingIdentifier(self, tmp_span);
        break :blk tmp_span;
    } else self.ast.getNode(decl_name).data.string_ref;

    const ce = self.ast.getNode(class_expr_node).data.extra;
    const none = @intFromEnum(NodeIndex.none);
    const class_decl = try self.addExtraNode(.class_declaration, span, &.{
        @intFromEnum(decl_name), @intFromEnum(self.readNodeIdx(ce, 1)), @intFromEnum(self.readNodeIdx(ce, 2)),
        none,                    0,                                     0,
        self.readU32(ce, 6),     self.readU32(ce, 7),
    });

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    try self.scratch.appendSlice(self.allocator, pre_stmts_a);
    try self.scratch.appendSlice(self.allocator, pre_stmts_b);
    try self.scratch.append(self.allocator, class_decl);
    try self.scratch.appendSlice(self.allocator, post_stmts);

    const ret_ref = try es_helpers.makeIdentifierRefFromSpan(self, ret_name_span);
    try self.scratch.append(self.allocator, try self.ast.addNode(.{
        .tag = .return_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = ret_ref, .flags = 0 } },
    }));

    const body_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const body_block = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = body_list },
    });

    const arrow = try self.addExtraNode(.arrow_function_expression, span, &.{
        none, @intFromEnum(body_block), 0,
    });
    const paren = try es_helpers.makeParenExpr(self, arrow, span);
    return es_helpers.makeCallExpr(self, paren, &.{}, span);
}

pub fn shouldDropClassExprName(self: *Transformer, tag: Tag, name_idx: NodeIndex) bool {
    if (!self.options.minify_syntax) return false;
    if (self.options.keep_names) return false;
    if (tag != .class_expression) return false;
    if (name_idx.isNone()) return false;
    const node_i = @intFromEnum(name_idx);
    if (node_i >= self.symbol_ids.items.len) return false;
    const sym_id = self.symbol_ids.items[node_i] orelse return false;
    if (sym_id >= self.symbols.len) return false;
    return self.symbols[sym_id].reference_count == 0;
}
