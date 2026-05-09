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

        const saved_super_class = self.current_super_class;
        if (!super_idx.isNone()) {
            self.current_super_class = self.ast.getNode(super_idx).span;
        }
        defer self.current_super_class = saved_super_class;

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
        if ((lower_pm or lower_pf) and node.tag == .class_expression and new_name.isNone() and
            classBodyHasStaticPrivateMember(self, current_body_idx, lower_pm, lower_pf))
        {
            const tmp_span = try es_helpers.makeTempVarSpan(self);
            new_name = try es_helpers.makeBindingIdentifier(self, tmp_span);
        }
        var had_private_methods = false;
        var had_private_fields = false;

        if (lower_pm or lower_pf) {
            const has_super = !self.readNodeIdx(e, 1).isNone();
            const class_name_text: ?[]const u8 = if (self.getClassNameSpan(new_name)) |s|
                self.ast.getText(s)
            else
                null;
            var new_body: NodeIndex = .none;
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
                    return wrapClassExprInIIFE(
                        self,
                        static_key_memos.items,
                        pre_stmts.items,
                        class_result,
                        static_block_iifes.items,
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
                return wrapClassExprInIIFE(
                    self,
                    &.{},
                    pre_stmts.items,
                    class_result,
                    &.{},
                    new_name,
                    node.span,
                );
            }

            for (pre_stmts.items) |stmt| {
                try self.pending_nodes.append(self.allocator, stmt);
            }
            try self.pending_nodes.append(self.allocator, class_result);
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

fn classBodyHasStaticPrivateMember(self: *Transformer, body_idx: NodeIndex, lower_methods: bool, lower_fields: bool) bool {
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

fn wrapClassExprInIIFE(
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
