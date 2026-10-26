//! TypeScript namespace and module-assignment helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const es_helpers = @import("../es_helpers.zig");
const SemanticSymbol = @import("../../semantic/symbol.zig").Symbol;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// import x = require('y') -> const x = require('y')
/// import x = Namespace.Member -> const x = Namespace.Member
pub fn visitImportEqualsDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    const name_idx = node.data.binary.left;
    const value_idx = node.data.binary.right;
    const name_node = self.ast.getNode(name_idx);
    const new_name = try self.makeUserBinding(name_node.span, name_idx);
    const new_value = try self.visitNode(value_idx);

    const decl_extra = try self.ast.addExtras(&.{
        @backingInt(new_name),
        @backingInt(NodeIndex.none),
        @backingInt(new_value),
    });
    const declarator = try self.ast.addNode(.{
        .tag = .variable_declarator,
        .span = node.span,
        .data = .{ .extra = decl_extra },
    });

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    try self.scratch.append(self.allocator, declarator);
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const var_extra = try self.ast.addExtras(&.{ @backingInt(VariableDeclarationKind.@"const"), list.start, list.len });
    return self.ast.addNode(.{
        .tag = .variable_declaration,
        .span = node.span,
        .data = .{ .extra = var_extra },
    });
}

/// `export = expr;` -> `module.exports = expr;`
/// ESM output context can still fail at runtime with `module is not defined`
/// (tsc TS1203 equivalent); policy is handled outside this syntax rewrite.
pub fn visitExportAssignment(self: *Transformer, node: Node) Error!NodeIndex {
    const new_expr = try self.visitNode(node.data.unary.operand);
    if (new_expr.isNone()) return .none;

    const module_id = try es_helpers.makeGlobalRef(self, "module");
    const exports_prop = try es_helpers.makePropertyName(self, "exports");
    const member = try es_helpers.makeStaticMember(self, module_id, exports_prop, node.span);
    return es_helpers.makeAssignStmt(self, member, new_expr, node.span, 0);
}

/// ts_module_declaration: binary = { left=name, right=body_or_inner, flags }
/// flags=1: ambient module/namespace declaration -> strip.
/// flags=0: namespace with runtime output; codegen emits the IIFE.
pub fn visitNamespaceDeclaration(self: *Transformer, node: Node) Error!NodeIndex {
    if (node.data.binary.flags == 1) return .none;

    const namespace_owner_symbol_id: ?u32 = if (self.getSymbolIdAt(node.data.binary.left)) |symbol_id| blk: {
        if (self.namespace_declaration_owners) |owners| break :blk owners.get(symbol_id) orelse symbol_id;
        break :blk symbol_id;
    } else null;
    const name_node = self.ast.getNode(node.data.binary.left);
    const is_root_namespace = self.namespace_path.items.len == 0;
    const saved_root_symbol = self.namespace_root_symbol_id;
    if (is_root_namespace) self.namespace_root_symbol_id = self.getSymbolIdAt(node.data.binary.left);
    try self.namespace_path.append(self.allocator, self.ast.getText(name_node.span));
    defer {
        _ = self.namespace_path.pop();
        if (is_root_namespace) self.namespace_root_symbol_id = saved_root_symbol;
    }
    const new_name = try self.visitNode(node.data.binary.left);
    // A namespace is emitted as an ordinary IIFE, so its captures belong to
    // that invocation, even when the declaration is nested in another arrow.
    const capture_frame = es_helpers.pushCaptureFrame(self);
    const saved_arrow_depth = self.arrow_this_depth;
    const saved_needs_this = self.needs_this_var;
    const saved_needs_arguments = self.needs_arguments_var;
    self.arrow_this_depth = 0;
    self.needs_this_var = false;
    self.needs_arguments_var = false;
    defer {
        self.arrow_this_depth = saved_arrow_depth;
        self.needs_this_var = saved_needs_this;
        self.needs_arguments_var = saved_needs_arguments;
        es_helpers.popCaptureFrame(self, capture_frame);
    }
    const saved_namespace_scope = self.namespace_iife_scope;
    const saved_temp_counter = self.temp_var_counter;
    const saved_binding_len = self.namespace_temp_bindings.items.len;
    self.namespace_iife_scope = self.current_scope;
    defer self.namespace_iife_scope = saved_namespace_scope;

    var pushed_export_frame = false;
    if (self.semantic_edit_enabled) {
        switch (namespaceIifeParameterSymbolId(self, self.current_scope)) {
            .missing => {},
            .invalid => std.debug.panic("namespace IIFE has ambiguous or invalid parameter SymbolIds", .{}),
            .found => |parameter_sid| {
                var frame = transformer_mod.NamespaceExportFrame{
                    .parameter_symbol_id = parameter_sid,
                    .owner_symbol_id = namespace_owner_symbol_id,
                };
                errdefer if (!pushed_export_frame) frame.exported_symbol_ids.deinit(self.allocator);
                try collectDirectNamespaceExportSymbols(self, node.data.binary.right, &frame.exported_symbol_ids);
                try self.namespace_export_frames.append(self.allocator, frame);
                pushed_export_frame = true;
            },
        }
    }
    defer if (pushed_export_frame) {
        var frame = self.namespace_export_frames.pop() orelse unreachable;
        frame.exported_symbol_ids.deinit(self.allocator);
    };

    var new_body = try self.visitNode(node.data.binary.right);
    if (!new_body.isNone()) {
        var captures: [3]NodeIndex = undefined;
        const capture_count = try es_helpers.fillThisArgumentsCaptures(self, &captures, node.span);
        const source_scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
        const strict_iife = !self.current_scope.isNone() and self.current_scope.toIndex() < source_scopes.len and source_scopes[self.current_scope.toIndex()].is_strict;
        if (capture_count != 0 or strict_iife) {
            const previous_body = self.ast.getNode(new_body);
            if (previous_body.tag != .block_statement and previous_body.tag != .ts_module_block)
                @panic("namespace captures require the actual IIFE body");
            var statements: std.ArrayList(NodeIndex) = .empty;
            defer statements.deinit(self.allocator);
            if (strict_iife) {
                // The generated ordinary IIFE must preserve its source strict
                // environment: unmapped arguments, poisoned callee and this.
                const text = try self.ast.addString("\"use strict\"");
                const directive = try self.ast.addNode(.{ .tag = .directive, .span = text, .data = .{ .none = 0 } });
                try statements.append(self.allocator, directive);
            }
            try statements.appendSlice(self.allocator, captures[0..capture_count]);
            for (0..previous_body.data.list.len) |index| {
                try statements.append(self.allocator, self.ast.readExtraNode(previous_body.data.list.start, @intCast(index)));
            }
            const captured_body = try self.ast.addNode(.{ .tag = previous_body.tag, .span = previous_body.span, .data = .{ .list = try self.ast.addNodeList(statements.items) } });
            try self.remapCopiedScopeOwner(new_body, captured_body);
            new_body = captured_body;
        }
    }
    if (!new_body.isNone()) {
        for (self.namespace_temp_bindings.items[saved_binding_len..]) |entry| {
            if (self.getSymbolIdAt(entry.binding) != null) continue;
            if (self.pending_temp_ref_chains.contains(self.currentPendingTempRefKey(entry.span))) {
                try self.bindHoistedTemp(entry.binding, entry.span, node.span, entry.scope);
            } else {
                // An empty destructuring pattern still emits the initializer's
                // local temp, even though no member reads that binding.
                _ = try self.declareSyntheticInScope(entry.binding, node.span, .variable_var, entry.scope);
            }
        }
        self.namespace_temp_bindings.shrinkRetainingCapacity(saved_binding_len);
        const body_tag = self.ast.getNode(new_body).tag;
        if (body_tag == .block_statement) {
            new_body = try self.hoistTempVarsInOriginalFunction(new_body, saved_temp_counter, node.span);
            self.temp_var_counter = saved_temp_counter;
        }
    }
    if (new_body.isNone()) return .none;

    const body_node = self.ast.getNode(new_body);
    if ((body_node.tag == .block_statement or body_node.tag == .ts_module_block) and body_node.data.list.len == 0) {
        return .none;
    }

    return self.ast.addNode(.{
        .tag = .ts_module_declaration,
        .span = node.span,
        .data = .{ .binary = .{ .left = new_name, .right = new_body, .flags = 0 } },
    });
}

/// Rewrite an exported-variable use to a normal member expression whose object
/// reference is bound to the exact virtual namespace IIFE parameter. This covers
/// declarations owned by the active namespace body and merged namespace proxies.
pub fn namespaceExportAccess(self: *Transformer, idx: NodeIndex) Error!?NodeIndex {
    // Keep legacy analysis-only transforms on the codegen fallback until they
    // provide the editor needed to move the exact Reference to the parameter.
    if (!self.semantic_edit_enabled) return null;
    const node = self.ast.getNode(idx);
    if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) return null;
    const source_sid = self.getSymbolIdAt(idx) orelse return null;
    const proxy_owner_symbol_id = if (self.namespace_member_owners) |owners| owners.get(source_sid) else null;

    var parameter_sid: ?u32 = null;
    var frame_index = self.namespace_export_frames.items.len;
    while (frame_index > 0) {
        frame_index -= 1;
        const frame = self.namespace_export_frames.items[frame_index];
        const proxy_belongs_to_frame = if (proxy_owner_symbol_id) |owner_symbol_id|
            frame.owner_symbol_id == owner_symbol_id
        else
            false;
        if (frame.exported_symbol_ids.contains(source_sid) or proxy_belongs_to_frame) {
            parameter_sid = frame.parameter_symbol_id;
            break;
        }
    }
    const sid = parameter_sid orelse return null;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    if (sid >= symbols.len) return null;
    const parameter = symbols[sid];
    if (parameter.synthetic_kind != .namespace_iife_parameter) return null;

    const parameter_name = if (parameter.synthetic_name.len > 0)
        parameter.synthetic_name
    else
        self.ast.getText(parameter.name);
    const parameter_name_span = try self.ast.addString(parameter_name);
    const parameter_ref = try es_helpers.identifierRefNode(self, parameter_name_span, node.span);
    try self.addSyntheticRefInScope(
        parameter_ref,
        @fromBackingInt(@intCast(sid)),
        self.current_scope,
        .{ .read = true },
    );

    const property_name_span = try self.ast.addString(self.ast.getText(node.data.string_ref));
    const property = try es_helpers.makePropertyNameAt(self, property_name_span, node.span);
    const access = try es_helpers.makeStaticMember(self, parameter_ref, property, node.span);
    try self.removeSemanticReference(idx);
    return access;
}

const NamespaceIifeParameterLookup = union(enum) {
    missing,
    found: u32,
    invalid,
};

fn namespaceIifeParameterSymbolId(
    self: *Transformer,
    namespace_scope: @import("../../semantic/scope.zig").ScopeId,
) NamespaceIifeParameterLookup {
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    var selected: ?u32 = null;
    for (symbols, 0..) |symbol, sid| {
        if (symbol.synthetic_kind != .namespace_iife_parameter or symbol.scope_id != namespace_scope) continue;
        if (symbol.kind != .parameter or sid > std.math.maxInt(u32) or selected != null) return .invalid;
        selected = @intCast(sid);
    }
    return if (selected) |sid| .{ .found = sid } else .missing;
}

fn collectDirectNamespaceExportSymbols(
    self: *Transformer,
    body_idx: NodeIndex,
    exported_symbols: *std.AutoHashMapUnmanaged(u32, void),
) Error!void {
    if (body_idx.isNone() or @backingInt(body_idx) >= self.ast.nodes.items.len) return;
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .ts_module_block) return;
    const list = body.data.list;
    if (list.start > self.ast.extra_data.items.len or list.len > self.ast.extra_data.items.len - list.start) return;

    for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        if (stmt_idx.isNone() or @backingInt(stmt_idx) >= self.ast.nodes.items.len) continue;
        const stmt = self.ast.getNode(stmt_idx);
        if (stmt.tag != .export_named_declaration) continue;
        const extra = stmt.data.extra;
        if (extra >= self.ast.extra_data.items.len) continue;
        const decl_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[extra]));
        if (decl_idx.isNone() or @backingInt(decl_idx) >= self.ast.nodes.items.len) continue;
        const declaration = self.ast.getNode(decl_idx);
        if (declaration.tag != .variable_declaration) continue;
        const decl_extra: usize = declaration.data.extra;
        if (decl_extra > self.ast.extra_data.items.len or self.ast.extra_data.items.len - decl_extra <= 2) continue;
        const start = self.ast.extra_data.items[decl_extra + 1];
        const len = self.ast.extra_data.items[decl_extra + 2];
        if (start > self.ast.extra_data.items.len or len > self.ast.extra_data.items.len - start) continue;
        for (self.ast.extra_data.items[start .. start + len]) |raw_declarator| {
            const declarator_idx: NodeIndex = @fromBackingInt(@intCast(raw_declarator));
            if (declarator_idx.isNone() or @backingInt(declarator_idx) >= self.ast.nodes.items.len) continue;
            const declarator = self.ast.getNode(declarator_idx);
            if (declarator.tag != .variable_declarator) continue;
            const declarator_extra = declarator.data.extra;
            if (declarator_extra >= self.ast.extra_data.items.len) continue;
            const binding_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[declarator_extra]));
            if (binding_idx.isNone() or @backingInt(binding_idx) >= self.ast.nodes.items.len or
                self.ast.getNode(binding_idx).tag != .binding_identifier) continue;
            const sid = self.getSymbolIdAt(binding_idx) orelse continue;
            try exported_symbols.put(self.allocator, sid, {});
        }
    }
}

// This helper is private to namespace transformation; keep its identity invariants in a white-box test.
test "#4819 namespace transform requires one parameter SymbolId per owner scope" {
    const allocator = std.testing.allocator;
    var ast = ast_mod.Ast.init(allocator, "");
    defer ast.deinit();
    var transformer = try Transformer.init(allocator, &ast, .{});
    defer transformer.deinit();

    const span = @import("../../lexer/token.zig").Span{ .start = 0, .end = 0 };
    const symbols = [_]SemanticSymbol{
        .{
            .name = span,
            .scope_id = @fromBackingInt(@intCast(0)),
            .kind = .parameter,
            .declaration_span = span,
            .synthetic_kind = .namespace_iife_parameter,
        },
    };
    transformer.symbols = &symbols;
    switch (namespaceIifeParameterSymbolId(&transformer, @fromBackingInt(@intCast(0)))) {
        .found => |sid| try std.testing.expectEqual(@as(u32, 0), sid),
        else => return error.ExpectedUniqueNamespaceIifeParameter,
    }

    var wrong_kind = symbols;
    wrong_kind[0].kind = .variable_const;
    transformer.symbols = &wrong_kind;
    try std.testing.expectEqual(
        NamespaceIifeParameterLookup.invalid,
        namespaceIifeParameterSymbolId(&transformer, @fromBackingInt(@intCast(0))),
    );

    const ambiguous = [_]SemanticSymbol{ symbols[0], symbols[0] };
    transformer.symbols = &ambiguous;
    try std.testing.expectEqual(
        NamespaceIifeParameterLookup.invalid,
        namespaceIifeParameterSymbolId(&transformer, @fromBackingInt(@intCast(0))),
    );

    try std.testing.expectEqual(
        NamespaceIifeParameterLookup.missing,
        namespaceIifeParameterSymbolId(&transformer, @fromBackingInt(@intCast(1))),
    );
}
