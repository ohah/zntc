//! TypeScript namespace and module-assignment helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const es_helpers = @import("../es_helpers.zig");
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
        @intFromEnum(new_name),
        @intFromEnum(NodeIndex.none),
        @intFromEnum(new_value),
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
    const var_extra = try self.ast.addExtras(&.{ @intFromEnum(VariableDeclarationKind.@"const"), list.start, list.len });
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
    const new_name = try self.visitNode(node.data.binary.left);
    const saved_namespace_scope = self.namespace_iife_scope;
    const saved_temp_counter = self.temp_var_counter;
    const saved_binding_len = self.namespace_temp_bindings.items.len;
    self.namespace_iife_scope = self.current_scope;
    defer self.namespace_iife_scope = saved_namespace_scope;

    var pushed_export_frame = false;
    if (self.semantic_edit_enabled) {
        if (namespaceIifeParameterSymbolId(self, self.current_scope)) |parameter_sid| {
            var frame = transformer_mod.NamespaceExportFrame{
                .parameter_symbol_id = parameter_sid,
                .owner_symbol_id = namespace_owner_symbol_id,
            };
            errdefer if (!pushed_export_frame) frame.exported_symbol_ids.deinit(self.allocator);
            try collectDirectNamespaceExportSymbols(self, node.data.binary.right, &frame.exported_symbol_ids);
            try self.namespace_export_frames.append(self.allocator, frame);
            pushed_export_frame = true;
        }
    }
    defer if (pushed_export_frame) {
        var frame = self.namespace_export_frames.pop() orelse unreachable;
        frame.exported_symbol_ids.deinit(self.allocator);
    };

    var new_body = try self.visitNode(node.data.binary.right);
    if (!new_body.isNone()) {
        for (self.namespace_temp_bindings.items[saved_binding_len..]) |entry| {
            if (self.getSymbolIdAt(entry.binding) != null) continue;
            if (self.pending_temp_ref_chains.contains(entry.span.start)) {
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
        @enumFromInt(sid),
        self.current_scope,
        .{ .read = true },
    );

    const property_name_span = try self.ast.addString(self.ast.getText(node.data.string_ref));
    const property = try es_helpers.makePropertyNameAt(self, property_name_span, node.span);
    const access = try es_helpers.makeStaticMember(self, parameter_ref, property, node.span);
    try self.removeSemanticReference(idx);
    return access;
}

fn namespaceIifeParameterSymbolId(self: *Transformer, namespace_scope: @import("../../semantic/scope.zig").ScopeId) ?u32 {
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    for (symbols, 0..) |symbol, sid| {
        if (symbol.synthetic_kind == .namespace_iife_parameter and symbol.scope_id == namespace_scope) {
            return @intCast(sid);
        }
    }
    return null;
}

fn collectDirectNamespaceExportSymbols(
    self: *Transformer,
    body_idx: NodeIndex,
    exported_symbols: *std.AutoHashMapUnmanaged(u32, void),
) Error!void {
    if (body_idx.isNone() or @intFromEnum(body_idx) >= self.ast.nodes.items.len) return;
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .ts_module_block) return;
    const list = body.data.list;
    if (list.start > self.ast.extra_data.items.len or list.len > self.ast.extra_data.items.len - list.start) return;

    for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @enumFromInt(raw_stmt);
        if (stmt_idx.isNone() or @intFromEnum(stmt_idx) >= self.ast.nodes.items.len) continue;
        const stmt = self.ast.getNode(stmt_idx);
        if (stmt.tag != .export_named_declaration) continue;
        const extra = stmt.data.extra;
        if (extra >= self.ast.extra_data.items.len) continue;
        const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra]);
        if (decl_idx.isNone() or @intFromEnum(decl_idx) >= self.ast.nodes.items.len) continue;
        const declaration = self.ast.getNode(decl_idx);
        if (declaration.tag != .variable_declaration) continue;
        const decl_extra: usize = declaration.data.extra;
        if (decl_extra > self.ast.extra_data.items.len or self.ast.extra_data.items.len - decl_extra <= 2) continue;
        const start = self.ast.extra_data.items[decl_extra + 1];
        const len = self.ast.extra_data.items[decl_extra + 2];
        if (start > self.ast.extra_data.items.len or len > self.ast.extra_data.items.len - start) continue;
        for (self.ast.extra_data.items[start .. start + len]) |raw_declarator| {
            const declarator_idx: NodeIndex = @enumFromInt(raw_declarator);
            if (declarator_idx.isNone() or @intFromEnum(declarator_idx) >= self.ast.nodes.items.len) continue;
            const declarator = self.ast.getNode(declarator_idx);
            if (declarator.tag != .variable_declarator) continue;
            const declarator_extra = declarator.data.extra;
            if (declarator_extra >= self.ast.extra_data.items.len) continue;
            const binding_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[declarator_extra]);
            if (binding_idx.isNone() or @intFromEnum(binding_idx) >= self.ast.nodes.items.len or
                self.ast.getNode(binding_idx).tag != .binding_identifier) continue;
            const sid = self.getSymbolIdAt(binding_idx) orelse continue;
            try exported_symbols.put(self.allocator, sid, {});
        }
    }
}
