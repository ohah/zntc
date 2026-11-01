//! Strict creation of ESM functions hoisted into a mixed script bundle.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const Module = @import("module.zig").Module;

/// Same-graph anchors, persisted with their semantic arrays. Public property
/// spelling supplies NamedEvaluation; it never selects a binding identity.
pub const RoleKind = enum(u32) { factory, body_directive, _ };
pub const NameRole = enum(u32) { binding, anonymous_default, _ };

pub const Role = struct {
    kind: RoleKind = .factory,
    body: NodeIndex = .none,
    directive: NodeIndex = .none,
    name_role: NameRole = .binding,
    declaration: NodeIndex,
    binding: NodeIndex,
    symbol: SymbolId,
    returned_function: NodeIndex = .none,
    factory: NodeIndex = .none,
    factory_scope: ScopeId = .none,
    source_scope: ScopeId,
    lexical_root: ScopeId,
};

pub const OutputContext = struct {
    program: NodeIndex = .none,
    directive: NodeIndex = .none,
    functions: []const Role = &.{},
};

fn requireCanonicalFactoryRoles(ast: *const ast_mod.Ast, semantic: anytype, program: NodeIndex, allocator: std.mem.Allocator) !void {
    const root = try checkedNode(ast, program);
    if (root.tag != .program) return;
    var roles: std.AutoHashMapUnmanaged(NodeIndex, Role) = .empty;
    defer roles.deinit(allocator);
    var role_symbols: std.AutoHashMapUnmanaged(SymbolId, void) = .empty;
    defer role_symbols.deinit(allocator);
    for (semantic.strict_output_context.functions) |role| {
        try role_symbols.put(allocator, role.symbol, {});
        const slot = try roles.getOrPut(allocator, role.declaration);
        if (slot.found_existing) return error.InvalidStrictFunctionRole;
        slot.value_ptr.* = role;
    }
    for (semantic.symbols.items, 0..) |symbol, raw| {
        if (symbol.binding_instantiation.strict_output_function and
            !role_symbols.contains(@fromBackingInt(@as(u32, @intCast(raw))))) return error.InvalidStrictFunctionRole;
    }
    // A source var redeclaration shares storage with its live source function;
    // its own binding is not the function/factory producer binding.
    var source_functions: std.AutoHashMapUnmanaged(SymbolId, NodeIndex) = .empty;
    defer source_functions.deinit(allocator);
    for (try checkedExtras(ast, root.data.list.start, root.data.list.len)) |raw| {
        const statement = try checkedNode(ast, @fromBackingInt(raw));
        const index: NodeIndex = switch (statement.tag) {
            .export_named_declaration => @fromBackingInt((try checkedExtras(ast, statement.data.extra, 1))[0]),
            .export_default_declaration => statement.data.unary.operand,
            else => @fromBackingInt(raw),
        };
        if (index.isNone()) continue;
        const declaration = try checkedNode(ast, index);
        if (declaration.tag != .function_declaration) continue;
        const binding = ast.readExtraNode(declaration.data.extra, 0);
        if (binding.isNone() or @backingInt(binding) >= semantic.symbol_ids.len) continue;
        if ((try checkedNode(ast, binding)).tag != .binding_identifier) return error.InvalidStrictFunctionRole;
        const sid = semantic.symbol_ids[@backingInt(binding)] orelse continue;
        if (sid >= semantic.symbols.items.len) return error.InvalidStrictFunctionRole;
        const symbol = semantic.symbols.items[sid];
        if (isFunctionKind(symbol.kind) and symbol.scope_id.toIndex() == 0)
            try source_functions.put(allocator, @fromBackingInt(@as(u32, @intCast(sid))), binding);
    }
    for (try checkedExtras(ast, root.data.list.start, root.data.list.len)) |raw| {
        const statement = try checkedNode(ast, @fromBackingInt(raw));
        const declaration_index: NodeIndex = switch (statement.tag) {
            .export_named_declaration => @fromBackingInt((try checkedExtras(ast, statement.data.extra, 1))[0]),
            .export_default_declaration => statement.data.unary.operand,
            else => @fromBackingInt(raw),
        };
        if (declaration_index.isNone()) continue;
        const declaration = try checkedNode(ast, declaration_index);
        if (declaration.tag == .function_declaration) {
            const binding = ast.readExtraNode(declaration.data.extra, 0);
            if (binding.isNone() or @backingInt(binding) >= semantic.symbol_ids.len) continue;
            const sid = semantic.symbol_ids[@backingInt(binding)] orelse continue;
            if (sid >= semantic.symbols.items.len) return error.InvalidStrictFunctionRole;
            if (semantic.symbols.items[sid].binding_instantiation.strict_output_function) {
                const role = roles.get(declaration_index) orelse return error.InvalidStrictFunctionRole;
                if (role.kind != .body_directive or role.binding != binding or @backingInt(role.symbol) != sid) return error.InvalidStrictFunctionRole;
            }
            continue;
        }
        if (declaration.tag != .variable_declaration) continue;
        const extra = try checkedExtras(ast, declaration.data.extra, 3);
        for (try checkedExtras(ast, extra[1], extra[2])) |declarator_raw| {
            const declarator = try checkedNode(ast, @fromBackingInt(declarator_raw));
            if (declarator.tag != .variable_declarator) return error.InvalidStrictFunctionRole;
            const binding: NodeIndex = @fromBackingInt((try checkedExtras(ast, declarator.data.extra, 3))[0]);
            if (binding.isNone() or @backingInt(binding) >= semantic.symbol_ids.len) continue;
            const sid = semantic.symbol_ids[@backingInt(binding)] orelse continue;
            if (sid >= semantic.symbols.items.len) return error.InvalidStrictFunctionRole;
            const symbol = semantic.symbols.items[sid];
            if ((!isFunctionKind(symbol.kind) and !symbol.binding_instantiation.strict_output_function) or symbol.scope_id.toIndex() != 0) continue;
            if (extra[0] == @backingInt(ast_mod.VariableDeclarationKind.@"var") and
                (try checkedNode(ast, binding)).tag == .binding_identifier and
                source_functions.get(@fromBackingInt(@as(u32, @intCast(sid)))) != null and
                source_functions.get(@fromBackingInt(@as(u32, @intCast(sid)))).? != binding) continue;
            // A source function stored in a generated var requires its recorded
            // producer role. This census detects loss; it never reconstructs one.
            const role = roles.get(declaration_index) orelse return error.InvalidStrictFunctionRole;
            if (role.binding != binding or @backingInt(role.symbol) != sid) return error.InvalidStrictFunctionRole;
        }
    }
}

pub fn validateContext(ast: *const ast_mod.Ast, semantic: anytype, allocator: std.mem.Allocator) !void {
    const context = semantic.strict_output_context;
    if (ast.nodes.items.len != 0) {
        const current_root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
        try requireCanonicalFactoryRoles(ast, semantic, current_root, allocator);
    }
    if (context.program.isNone()) {
        if (!context.directive.isNone() or context.functions.len != 0) return error.InvalidStrictFunctionRole;
        return;
    }
    const program = try checkedNode(ast, context.program);
    const directive = try checkedNode(ast, context.directive);
    if (program.tag != .program or directive.tag != .directive or semantic.scopes.len == 0 or !semantic.scopes[0].is_strict or
        semantic.scope_owner_map.get(@backingInt(context.program)) != 0 or
        !std.mem.eql(u8, ast.getText(directive.span), "\"use strict\"") and !std.mem.eql(u8, ast.getText(directive.span), "'use strict'")) return error.InvalidStrictFunctionRole;
    var found = false;
    for (try checkedExtras(ast, program.data.list.start, program.data.list.len)) |raw| {
        const node: NodeIndex = @fromBackingInt(raw);
        if ((try checkedNode(ast, node)).tag != .directive) break;
        if (node == context.directive) found = true;
    }
    if (!found) return error.InvalidStrictFunctionRole;
    for (context.functions) |role| try validate(ast, semantic, role, allocator);
}

/// Keep each validated factory declaration as the emitter's exact producer
/// anchor. Ordinary declarations can still merge around these live boundaries.
pub fn mergeOutputDeclarations(ast: *ast_mod.Ast, semantic: anytype, root: NodeIndex, skip_nodes: ?*const std.DynamicBitSet, allocator: std.mem.Allocator) !void {
    var preserved: std.ArrayList(NodeIndex) = .empty;
    defer preserved.deinit(allocator);
    for (semantic.strict_output_context.functions) |role| {
        if (role.kind == .factory) try preserved.append(allocator, role.declaration);
    }
    if (preserved.items.len != 0) try validateContext(ast, semantic, allocator);
    @import("../transformer/minify.zig").mergeDeclsPreserving(ast, root, skip_nodes, preserved.items, allocator);
}

pub fn remapProgram(context: *OutputContext, previous: NodeIndex, next: NodeIndex) !void {
    if (context.program.isNone()) return;
    if (context.program != previous or next.isNone()) return error.InvalidStrictFunctionRole;
    context.program = next;
}

fn isFunctionKind(kind: @import("../semantic/symbol.zig").SymbolKind) bool {
    return switch (kind) {
        .function_decl, .generator_decl, .async_function_decl, .async_generator_decl => true,
        else => false,
    };
}

fn checkedNode(ast: *const ast_mod.Ast, index: NodeIndex) !ast_mod.Node {
    if (index.isNone() or @backingInt(index) >= ast.nodes.items.len) return error.InvalidStrictFunctionRole;
    return ast.getNode(index);
}

fn checkedExtras(ast: *const ast_mod.Ast, start: u32, count: usize) ![]const u32 {
    if (start > ast.extra_data.items.len or count > ast.extra_data.items.len - start) return error.InvalidStrictFunctionRole;
    return ast.extra_data.items[start .. start + count];
}

pub fn validate(ast: *const ast_mod.Ast, semantic: anytype, role: Role, allocator: std.mem.Allocator) !void {
    const declaration = try checkedNode(ast, role.declaration);
    const binding = try checkedNode(ast, role.binding);
    const sid = @backingInt(role.symbol);
    if (role.symbol.isNone() or sid >= semantic.symbols.items.len or @backingInt(role.binding) >= semantic.symbol_ids.len or
        semantic.symbol_ids[@backingInt(role.binding)] != sid) return error.InvalidStrictFunctionRole;
    const symbol = semantic.symbols.items[sid];
    const anonymous_default = role.name_role == .anonymous_default;
    if (role.name_role != .binding and !anonymous_default) return error.InvalidStrictFunctionRole;
    const valid_kind = if (anonymous_default) symbol.kind == .variable_const and symbol.decl_flags.is_default_export else isFunctionKind(symbol.kind);
    if (!valid_kind or symbol.scope_id.toIndex() != 0 or !symbol.binding_instantiation.strict_output_function) return error.InvalidStrictFunctionRole;
    if (role.kind == .body_directive) {
        if (declaration.tag != .function_declaration or binding.tag != .binding_identifier or
            !role.returned_function.isNone() or !role.factory.isNone() or !role.factory_scope.isNone() or role.name_role != .binding or role.lexical_root != role.source_scope or
            role.source_scope.isNone() or role.source_scope.toIndex() >= semantic.scopes.len or
            semantic.scope_owner_map.get(@backingInt(role.declaration)) != @backingInt(role.source_scope) or
            !semantic.scopes[role.source_scope.toIndex()].is_strict or !try hasSimpleParameters(ast, declaration)) return error.InvalidStrictFunctionRole;
        if (ast.readExtraNode(declaration.data.extra, 0) != role.binding or ast.readExtraNode(declaration.data.extra, 2) != role.body) return error.InvalidStrictFunctionRole;
        const body = try checkedNode(ast, role.body);
        const directive = try checkedNode(ast, role.directive);
        if (body.tag != .block_statement or directive.tag != .directive) return error.InvalidStrictFunctionRole;
        const text = ast.getText(directive.span);
        if (!std.mem.eql(u8, text, "\"use strict\"") and !std.mem.eql(u8, text, "'use strict'")) return error.InvalidStrictFunctionRole;
        var found = false;
        for (try checkedExtras(ast, body.data.list.start, body.data.list.len)) |raw| {
            const node: NodeIndex = @fromBackingInt(raw);
            if ((try checkedNode(ast, node)).tag != .directive) break;
            if (node == role.directive) found = true;
        }
        if (!found) return error.InvalidStrictFunctionRole;
        return;
    }
    if (role.kind != .factory or !role.body.isNone() or !role.directive.isNone()) return error.InvalidStrictFunctionRole;
    const returned_function = try checkedNode(ast, role.returned_function);
    const factory = try checkedNode(ast, role.factory);
    if (declaration.tag != .variable_declaration or binding.tag != .binding_identifier or
        returned_function.tag != .function_expression or factory.tag != .function_expression) return error.InvalidStrictFunctionRole;
    const returned_extra = try checkedExtras(ast, returned_function.data.extra, 5);
    const factory_extra = try checkedExtras(ast, factory.data.extra, 5);
    if (returned_extra[0] != @backingInt(NodeIndex.none) or factory_extra[0] != @backingInt(NodeIndex.none)) return error.InvalidStrictFunctionRole;
    for ([_]ScopeId{ role.factory_scope, role.source_scope, role.lexical_root }) |scope| {
        if (scope.isNone() or scope.toIndex() >= semantic.scopes.len or !semantic.scopes[scope.toIndex()].is_strict) return error.InvalidStrictFunctionRole;
    }
    if (semantic.scope_owner_map.get(@backingInt(role.factory)) != @backingInt(role.factory_scope) or
        semantic.scope_owner_map.get(@backingInt(role.returned_function)) != @backingInt(role.source_scope) or
        semantic.scopes[role.factory_scope.toIndex()].parent.toIndex() != 0 or
        semantic.scopes[role.lexical_root.toIndex()].parent != role.factory_scope) return error.InvalidStrictFunctionRole;
    var current = role.source_scope;
    var hops: usize = 0;
    while (current != role.lexical_root) : (hops += 1) {
        if (current.isNone() or current.toIndex() >= semantic.scopes.len or hops >= semantic.scopes.len) return error.InvalidStrictFunctionRole;
        current = semantic.scopes[current.toIndex()].parent;
    }
    const variable_extra = try checkedExtras(ast, declaration.data.extra, 3);
    if (variable_extra[0] != @backingInt(ast_mod.VariableDeclarationKind.@"var") or variable_extra[2] != 1) return error.InvalidStrictFunctionRole;
    const declaration_list = try checkedExtras(ast, variable_extra[1], 1);
    const declarator = try checkedNode(ast, @fromBackingInt(declaration_list[0]));
    if (declarator.tag != .variable_declarator) return error.InvalidStrictFunctionRole;
    const declarator_extra = try checkedExtras(ast, declarator.data.extra, 3);
    if (declarator_extra[0] != @backingInt(role.binding)) return error.InvalidStrictFunctionRole;
    const call = try checkedNode(ast, @fromBackingInt(declarator_extra[2]));
    if (call.tag != .call_expression) return error.InvalidStrictFunctionRole;
    const call_extra = try checkedExtras(ast, call.data.extra, 4);
    if (call_extra[0] != @backingInt(role.factory) or call_extra[2] != 0) return error.InvalidStrictFunctionRole;
    const parameters = try checkedNode(ast, @fromBackingInt(factory_extra[1]));
    if (parameters.tag != .formal_parameters or parameters.data.list.len != 0) return error.InvalidStrictFunctionRole;
    const body = try checkedNode(ast, @fromBackingInt(factory_extra[2]));
    if (body.tag != .block_statement or body.data.list.len != 2) return error.InvalidStrictFunctionRole;
    const body_list = try checkedExtras(ast, body.data.list.start, 2);
    const directive = try checkedNode(ast, @fromBackingInt(body_list[0]));
    if (directive.tag != .directive or !std.mem.eql(u8, ast.getText(directive.span), "\"use strict\"")) return error.InvalidStrictFunctionRole;
    const result = try checkedNode(ast, @fromBackingInt(body_list[1]));
    if (result.tag != .return_statement) return error.InvalidStrictFunctionRole;
    const member = try checkedNode(ast, result.data.unary.operand);
    if (member.tag != .computed_member_expression) return error.InvalidStrictFunctionRole;
    const member_extra = try checkedExtras(ast, member.data.extra, 3);
    const object = try checkedNode(ast, @fromBackingInt(member_extra[0]));
    if (object.tag != .object_expression or object.data.list.len != 1) return error.InvalidStrictFunctionRole;
    const properties = try checkedExtras(ast, object.data.list.start, 1);
    const property = try checkedNode(ast, @fromBackingInt(properties[0]));
    if (property.tag != .object_property or property.data.binary.right != role.returned_function) return error.InvalidStrictFunctionRole;
    const property_key = try checkedNode(ast, property.data.binary.left);
    const key_index = if (property_key.tag == .computed_property_key) property_key.data.unary.operand else property.data.binary.left;
    if (@backingInt(key_index) != member_extra[1]) return error.InvalidStrictFunctionRole;
    const key = try checkedNode(ast, key_index);
    if (key.tag != .string_literal) return error.InvalidStrictFunctionRole;
    const key_text = ast.getText(key.span);
    if (key_text.len < 2 or key_text[0] != '"' or key_text[key_text.len - 1] != '"') return error.InvalidStrictFunctionRole;
    const source_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else ast.getText(symbol.name);
    const public_name = if (anonymous_default) "default" else try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(allocator, source_name);
    if (!std.mem.eql(u8, public_name, key_text[1 .. key_text.len - 1])) return error.InvalidStrictFunctionRole;
    if (std.mem.eql(u8, public_name, "__proto__") and property_key.tag != .computed_property_key) return error.InvalidStrictFunctionRole;
}

pub fn lower(graph: *@import("graph.zig").ModuleGraph, shaker: ?*@import("tree_shaker.zig").TreeShaker) !bool {
    var changed = false;
    for (0..graph.moduleCount()) |index| {
        const module = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(index)) orelse continue;
        if (!module.is_included) continue;
        const before = if (module.ast) |ast| ast.nodes.items.len + ast.extra_data.items.len else 0;
        try lowerModuleWithShaker(module, shaker);
        if (module.ast) |ast| changed = changed or before != ast.nodes.items.len + ast.extra_data.items.len;
    }
    return changed;
}

fn hasSimpleParameters(ast: *const ast_mod.Ast, node: ast_mod.Node) !bool {
    const extra = try checkedExtras(ast, node.data.extra, 5);
    const parameters = try checkedNode(ast, @fromBackingInt(extra[1]));
    if (parameters.tag != .formal_parameters) return error.InvalidStrictFunctionRole;
    const list = try checkedExtras(ast, parameters.data.list.start, parameters.data.list.len);
    for (list) |raw| if ((try checkedNode(ast, @fromBackingInt(raw))).tag != .binding_identifier) return false;
    return true;
}

fn addStrictDirective(ast: *ast_mod.Ast, body_index: NodeIndex, allocator: std.mem.Allocator) !NodeIndex {
    const body = try checkedNode(ast, body_index);
    if (body.tag != .block_statement and body.tag != .program) return error.InvalidStrictFunctionRole;
    const original = try allocator.dupe(u32, try checkedExtras(ast, body.data.list.start, body.data.list.len));
    var insertion: usize = 0;
    while (insertion < original.len) : (insertion += 1) {
        const node = try checkedNode(ast, @fromBackingInt(original[insertion]));
        if (node.tag != .directive) break;
        const text = ast.getText(node.span);
        if (std.mem.eql(u8, text, "\"use strict\"") or std.mem.eql(u8, text, "'use strict'")) return @fromBackingInt(original[insertion]);
    }
    const span = try ast.addString("\"use strict\"");
    const directive = try ast.addNode(.{ .tag = .directive, .span = span, .data = .{ .string_ref = span } });
    var statements: std.ArrayList(NodeIndex) = .empty;
    for (original[0..insertion]) |raw| try statements.append(allocator, @fromBackingInt(raw));
    try statements.append(allocator, directive);
    for (original[insertion..]) |raw| try statements.append(allocator, @fromBackingInt(raw));
    ast.nodes.items[@backingInt(body_index)].data.list = try ast.addNodeList(statements.items);
    return directive;
}

pub fn lowerModule(module: *Module) !void {
    return lowerModuleWithShaker(module, null);
}

fn restoreSourceImportDeclarations(module: *Module, editor: anytype, root: NodeIndex, allocator: std.mem.Allocator) ![]const NodeIndex {
    const ast = editor.ast;
    const contexts = try @import("statement_owner_projection.zig").collect(allocator, ast, root);
    const Local = struct { node: NodeIndex, symbol: u32 };
    const Owner = struct { record: u32, declaration: ?NodeIndex };
    var bindings: std.AutoHashMapUnmanaged(Local, Owner) = .empty;
    defer bindings.deinit(allocator);
    for (module.import_bindings) |binding| {
        if (binding.callsite_target != null or binding.local_role != .import_binding) continue;
        const anchor = binding.local_symbol_node orelse continue;
        const local = @import("binding_scanner.zig").resolveImportLocalSymbol(binding, .{ .module_index = module.index, .ast = ast, .symbol_ids = editor.symbol_ids.items, .symbols = editor.symbols.items });
        const sid = local.semanticIndex() orelse continue;
        if (binding.local_symbol.semanticIndex()) |cached| if (cached != sid) return error.InvalidStrictFunctionRole;
        const slot = try bindings.getOrPut(allocator, .{ .node = anchor, .symbol = sid });
        const declaration = binding.local_declaration_node;
        const owner: Owner = .{ .record = binding.import_record_index, .declaration = declaration };
        if (slot.found_existing and !std.meta.eql(slot.value_ptr.*, owner)) return error.InvalidStrictFunctionRole;
        slot.value_ptr.* = owner;
    }
    const Plan = struct { declaration: NodeIndex, record: u32 };
    var plans: std.ArrayList(Plan) = .empty;
    var selected: std.AutoHashMapUnmanaged(NodeIndex, u32) = .empty;
    defer selected.deinit(allocator);
    for (editor.references.items) |reference| {
        if (!reference.flags.declare or reference.declaration_node_index.isNone()) continue;
        const anchor = reference.declaration_node_index;
        if (@backingInt(anchor) < contexts.len and contexts[@backingInt(anchor)] != null) continue;
        const sid = @backingInt(reference.symbol_id);
        if (sid >= editor.symbols.items.len) return error.InvalidStrictFunctionRole;
        const symbol = editor.symbols.items[sid];
        if (symbol.kind != .import_binding or symbol.scope_id.toIndex() != 0 or reference.scope_id.toIndex() != 0) continue;
        const owner = bindings.get(.{ .node = anchor, .symbol = sid }) orelse return error.InvalidStrictFunctionRole;
        const record_index = owner.record;
        if (record_index >= module.import_records.len) return error.InvalidStrictFunctionRole;
        const record = module.import_records[record_index];
        if (record.kind != .static_import or record.source_node.isNone() or (try checkedNode(ast, record.source_node)).tag != .string_literal) return error.InvalidStrictFunctionRole;
        const declaration = owner.declaration orelse return error.InvalidStrictFunctionRole;
        const declaration_node = try checkedNode(ast, declaration);
        if (declaration_node.tag != .import_declaration) return error.InvalidStrictFunctionRole;
        const extra = @import("../parser/module.zig").readImportDeclExtras(ast, declaration_node.data.extra);
        if (extra.source != record.source_node) return error.InvalidStrictFunctionRole;
        var owns_local = false;
        for (try checkedExtras(ast, extra.specs_start, extra.specs_len)) |raw| {
            const specifier_index: NodeIndex = @fromBackingInt(raw);
            const specifier = try checkedNode(ast, specifier_index);
            const local = switch (specifier.tag) {
                .import_specifier => if (specifier.data.binary.right.isNone()) specifier.data.binary.left else specifier.data.binary.right,
                .import_default_specifier, .import_namespace_specifier => specifier_index,
                else => continue,
            };
            if (local == anchor) owns_local = true;
        }
        if (!owns_local) return error.InvalidStrictFunctionRole;
        const slot = try selected.getOrPut(allocator, declaration);
        if (slot.found_existing) {
            if (slot.value_ptr.* != record_index) return error.InvalidStrictFunctionRole;
            continue;
        }
        slot.value_ptr.* = record_index;
        try plans.append(allocator, .{ .declaration = declaration, .record = record_index });
    }
    if (plans.items.len == 0) return &.{};
    std.mem.sortUnstable(Plan, plans.items, {}, struct {
        fn lessThan(_: void, left: Plan, right: Plan) bool {
            return left.record < right.record;
        }
    }.lessThan);
    const list = ast.getNode(root).data.list;
    const original = try allocator.dupe(u32, try checkedExtras(ast, list.start, list.len));
    var statements: std.ArrayList(NodeIndex) = .empty;
    var restored: std.ArrayList(NodeIndex) = .empty;
    var insertion: usize = 0;
    while (insertion < original.len and (try checkedNode(ast, @fromBackingInt(original[insertion]))).tag == .directive) : (insertion += 1)
        try statements.append(allocator, @fromBackingInt(original[insertion]));
    for (plans.items) |plan| {
        try statements.append(allocator, plan.declaration);
        try restored.append(allocator, plan.declaration);
    }
    for (original[insertion..]) |raw| try statements.append(allocator, @fromBackingInt(raw));
    ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(statements.items);
    return restored.items;
}

fn materializeFacadeBinding(editor: anytype, source_export: NodeIndex, sid: u32, allocator: std.mem.Allocator) !NodeIndex {
    const ast = editor.ast;
    const selected = try @import("default_facade_identity.zig").symbolAt(ast, source_export, editor.symbol_ids.items, editor.symbols.items) orelse return error.InvalidStrictFunctionRole;
    if (selected != sid) return error.InvalidStrictFunctionRole;
    const row = editor.symbols.items[sid];
    const previous = try allocator.dupe(u8, if (row.synthetic_name.len > 0) row.synthetic_name else ast.getText(row.name));
    var physical = previous;
    var suffix: u32 = 0;
    while (editor.scope_maps.items[0].get(physical)) |existing| {
        if (existing == sid) break;
        physical = try std.fmt.allocPrint(allocator, "__default_export_{d}_{d}", .{ sid, suffix });
        suffix += 1;
    }
    const span = try ast.addString(physical);
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = span, .data = .{ .string_ref = span } });
    if (!std.mem.eql(u8, previous, physical) and editor.scope_maps.items[0].get(previous) == @as(?usize, sid))
        _ = editor.scope_maps.items[0].remove(previous);
    try editor.scope_maps.items[0].put(allocator, physical, sid);
    editor.symbols.items[sid].name = span;
    editor.symbols.items[sid].synthetic_name = physical;
    try editor.attachExistingBinding(binding, @fromBackingInt(sid));
    editor.symbol_ids.items[@backingInt(source_export)] = null;
    return binding;
}

fn rewriteDefaultAlias(module: *Module, editor: anytype, source_export: NodeIndex, binding: NodeIndex, sid: u32, allocator: std.mem.Allocator) !void {
    const ast = editor.ast;
    const row = editor.symbols.items[sid];
    const local = try ast.addNode(.{ .tag = .identifier_reference, .span = row.name, .data = .{ .string_ref = row.name } });
    try editor.addReference(local, @fromBackingInt(sid), @fromBackingInt(@as(u32, 0)), .{ .read = true }, @import("../semantic/symbol.zig").Reference.NO_STMT, @import("../semantic/symbol.zig").Reference.NO_STMT);
    const default_span = try ast.addString("default");
    const public = try ast.addNode(.{ .tag = .identifier_reference, .span = default_span, .data = .{ .string_ref = default_span } });
    const specifier = try ast.addNode(.{ .tag = .export_specifier, .span = ast.getNode(source_export).span, .data = .{ .binary = .{ .left = local, .right = public, .flags = 0 } } });
    const list = try ast.addNodeList(&.{specifier});
    ast.nodes.items[@backingInt(source_export)] = .{ .tag = .export_named_declaration, .span = ast.getNode(source_export).span, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(NodeIndex.none), list.start, list.len, @backingInt(NodeIndex.none), 0, 0 }) } };
    for (module.export_bindings) |*exported| {
        if (exported.default_export_node != source_export) continue;
        if (exported.kind != .local or exported.symbol.semanticIndex() != @as(?u32, sid) or exported.symbol.moduleIndex() != module.index) return error.InvalidStrictFunctionRole;
        exported.local_symbol_node = local;
        exported.local_span = ast.getNode(binding).span;
        exported.local_name = try allocator.dupe(u8, if (row.synthetic_name.len > 0) row.synthetic_name else ast.getText(row.name));
        exported.default_export_node = null;
        exported.has_default_export_facade = false;
        exported.source_specifier_node = specifier;
    }
}

fn lowerModuleWithShaker(module: *Module, shaker: ?*@import("tree_shaker.zig").TreeShaker) !void {
    const ast = if (module.ast) |*value| value else return;
    const semantic = if (module.semantic) |*value| value else return;
    try validateContext(ast, semantic.*, module.parse_arena.?.allocator());
    if (module.wrap_kind != .esm or semantic.scopes.len == 0 or !semantic.scopes[0].is_strict) return;
    const allocator = module.parse_arena.?.allocator();
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    const list = ast.getNode(root).data.list;
    const statements = try allocator.dupe(u32, ast.extra_data.items[list.start .. list.start + list.len]);
    var recorded: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
    defer recorded.deinit(allocator);
    for (semantic.strict_output_context.functions) |role| try recorded.put(allocator, role.declaration, {});
    const Plan = struct { declaration: NodeIndex, source_export: ?NodeIndex, symbol: u32, anonymous_default: bool };
    var plans: std.ArrayList(Plan) = .empty;
    for (statements) |raw| {
        const statement: NodeIndex = @fromBackingInt(raw);
        const node = ast.getNode(statement);
        const declaration = switch (node.tag) {
            .export_named_declaration => ast.readExtraNode(node.data.extra, 0),
            .export_default_declaration => node.data.unary.operand,
            else => statement,
        };
        if (declaration.isNone() or ast.getNode(declaration).tag != .function_declaration or recorded.contains(declaration)) continue;
        const binding = ast.readExtraNode(ast.getNode(declaration).data.extra, 0);
        const anonymous = binding.isNone();
        const sid = if (anonymous) blk: {
            if (node.tag != .export_default_declaration) return error.InvalidStrictFunctionRole;
            break :blk try @import("default_facade_identity.zig").symbolAt(ast, statement, semantic.symbol_ids, semantic.symbols.items) orelse return error.InvalidStrictFunctionRole;
        } else semantic.symbol_ids[@backingInt(binding)] orelse return error.InvalidStrictFunctionRole;
        try plans.append(allocator, .{ .declaration = declaration, .source_export = if (node.tag == .export_default_declaration) statement else null, .symbol = sid, .anonymous_default = anonymous });
    }
    var factory_groups: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer factory_groups.deinit(allocator);
    for (plans.items) |plan| {
        if (plan.anonymous_default or !try hasSimpleParameters(ast, ast.getNode(plan.declaration)))
            try factory_groups.put(allocator, plan.symbol, {});
    }
    var default_hoists: std.AutoHashMapUnmanaged(NodeIndex, NodeIndex) = .empty;
    defer default_hoists.deinit(allocator);
    var editor = try semantic.beginEdit(allocator, ast);
    defer editor.deinit();
    const module_directive = try addStrictDirective(ast, root, allocator);
    const restored_imports = try restoreSourceImportDeclarations(module, &editor, root, allocator);
    var roles: std.ArrayList(Role) = .empty;
    try roles.appendSlice(allocator, semantic.strict_output_context.functions);
    const none = @backingInt(NodeIndex.none);
    for (plans.items) |plan| {
        const declaration = plan.declaration;
        const original = ast.getNode(declaration);
        const sid = plan.symbol;
        if (sid >= editor.symbols.items.len) return error.InvalidStrictFunctionRole;
        if (!module.isStatementAliveBySym(sid)) continue;
        const binding = if (plan.anonymous_default)
            try materializeFacadeBinding(&editor, plan.source_export.?, sid, allocator)
        else
            ast.readExtraNode(original.data.extra, 0);
        if (@backingInt(binding) >= editor.symbol_ids.items.len or editor.symbol_ids.items[@backingInt(binding)] != @as(?u32, sid)) return error.InvalidStrictFunctionRole;
        const symbol = editor.symbols.items[sid];
        if ((!isFunctionKind(symbol.kind) and !plan.anonymous_default) or symbol.scope_id.toIndex() != 0) return error.InvalidStrictFunctionRole;
        const source_scope: ScopeId = @fromBackingInt(editor.scope_owner_map.get(@backingInt(declaration)) orelse return error.InvalidStrictFunctionRole);
        if (!factory_groups.contains(sid)) {
            const body_index = ast.readExtraNode(original.data.extra, 2);
            const directive = try addStrictDirective(ast, body_index, allocator);
            editor.symbols.items[sid].binding_instantiation.strict_output_function = true;
            try roles.append(allocator, .{ .kind = .body_directive, .declaration = declaration, .binding = binding, .symbol = @fromBackingInt(sid), .body = body_index, .directive = directive, .source_scope = source_scope, .lexical_root = source_scope });
            continue;
        }
        var function_extra: [5]u32 = undefined;
        @memcpy(&function_extra, ast.extra_data.items[original.data.extra .. original.data.extra + 5]);
        function_extra[0] = none;
        const returned = try ast.addNode(.{ .tag = .function_expression, .span = original.span, .data = .{ .extra = try ast.addExtras(&function_extra) } });
        try editor.remapScopeOwner(declaration, returned);
        const directive_span = try ast.addString("\"use strict\"");
        const directive = try ast.addNode(.{ .tag = .directive, .span = directive_span, .data = .{ .string_ref = directive_span } });
        const body = try ast.addNode(.{ .tag = .block_statement, .span = original.span, .data = .{ .list = try ast.addNodeList(&.{}) } });
        const parameters = try ast.addFormalParameters(try ast.addNodeList(&.{}), original.span);
        const factory = try ast.addNode(.{ .tag = .function_expression, .span = original.span, .data = .{ .extra = try ast.addExtras(&.{ none, @backingInt(parameters), @backingInt(body), 0, none }) } });
        const factory_scope = try editor.addScope(@fromBackingInt(@as(u32, 0)), factory, .function, true);
        var lexical_root = source_scope;
        var hops: usize = 0;
        while (true) : (hops += 1) {
            if (lexical_root.isNone() or lexical_root.toIndex() >= editor.scopes.items.len or hops >= editor.scopes.items.len) return error.InvalidStrictFunctionRole;
            const parent = editor.scopes.items[lexical_root.toIndex()].parent;
            if (parent.toIndex() == 0) break;
            lexical_root = parent;
        }
        try editor.reparentScope(lexical_root, factory_scope);
        const source_name = module.symbolName(@fromBackingInt(sid)) orelse return error.InvalidStrictFunctionRole;
        const decoded_buffer = try allocator.alloc(u8, source_name.len);
        const public_name = if (plan.anonymous_default) "default" else @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesInto(source_name, decoded_buffer) orelse source_name;
        const key_span = try ast.addString(try std.fmt.allocPrint(allocator, "\"{s}\"", .{public_name}));
        const key = try ast.addNode(.{ .tag = .string_literal, .span = key_span, .data = .{ .string_ref = key_span } });
        const property_key = if (std.mem.eql(u8, public_name, "__proto__"))
            try ast.addNode(.{ .tag = .computed_property_key, .span = key_span, .data = .{ .unary = .{ .operand = key, .flags = 0 } } })
        else
            key;
        const property = try ast.addNode(.{ .tag = .object_property, .span = original.span, .data = .{ .binary = .{ .left = property_key, .right = returned, .flags = 0 } } });
        const object = try ast.addNode(.{ .tag = .object_expression, .span = original.span, .data = .{ .list = try ast.addNodeList(&.{property}) } });
        const member = try ast.addNode(.{ .tag = .computed_member_expression, .span = original.span, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(object), @backingInt(key), 0 }) } });
        const result = try ast.addNode(.{ .tag = .return_statement, .span = original.span, .data = .{ .unary = .{ .operand = member, .flags = 0 } } });
        ast.nodes.items[@backingInt(body)].data.list = try ast.addNodeList(&.{ directive, result });
        const call = try ast.addNode(.{ .tag = .call_expression, .span = original.span, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(factory), 0, 0, 0 }) } });
        const declarator = try ast.addNode(.{ .tag = .variable_declarator, .span = original.span, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(binding), none, @backingInt(call) }) } });
        const declarations = try ast.addNodeList(&.{declarator});
        ast.nodes.items[@backingInt(declaration)] = .{ .tag = .variable_declaration, .span = original.span, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(ast_mod.VariableDeclarationKind.@"var"), declarations.start, declarations.len }) } };
        editor.symbols.items[sid].binding_instantiation.strict_output_function = true;
        try roles.append(allocator, .{ .name_role = if (plan.anonymous_default) .anonymous_default else .binding, .declaration = declaration, .binding = binding, .symbol = @fromBackingInt(sid), .returned_function = returned, .factory = factory, .factory_scope = factory_scope, .source_scope = source_scope, .lexical_root = lexical_root });
        if (plan.source_export) |source_export| {
            try rewriteDefaultAlias(module, &editor, source_export, binding, sid, allocator);
            try default_hoists.put(allocator, source_export, declaration);
        }
    }
    if (default_hoists.count() != 0) {
        const current_list = ast.getNode(root).data.list;
        const current = try allocator.dupe(u32, try checkedExtras(ast, current_list.start, current_list.len));
        var expanded: std.ArrayList(NodeIndex) = .empty;
        for (current) |raw| {
            const statement: NodeIndex = @fromBackingInt(raw);
            if (default_hoists.get(statement)) |declaration| try expanded.append(allocator, declaration);
            try expanded.append(allocator, statement);
        }
        ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(expanded.items);
    }
    ast.transformed_root = root;
    const old_ids_len = editor.symbol_ids.items.len;
    try editor.symbol_ids.resize(allocator, ast.nodes.items.len);
    @memset(editor.symbol_ids.items[old_ids_len..], null);
    var coordinate_input = semantic.*;
    coordinate_input.symbols = editor.symbols;
    coordinate_input.scopes = editor.scopes.items;
    coordinate_input.scope_maps = editor.scope_maps.items;
    coordinate_input.scope_owner_map = editor.scope_owner_map;
    coordinate_input.symbol_ids = editor.symbol_ids.items;
    coordinate_input.references = editor.references.items;
    const projected = (try @import("statement_owner_projection.zig").project(allocator, ast, root, &coordinate_input)) orelse return error.InvalidStrictFunctionRole;
    editor.references.deinit(allocator);
    editor.references = .fromOwnedSlice(projected);
    const edited = try editor.finish();
    semantic.applyEdit(edited);
    semantic.strict_output_context = .{ .program = root, .directive = module_directive, .functions = try roles.toOwnedSlice(allocator) };
    try validateContext(ast, semantic.*, allocator);
    var newly_live: std.ArrayList(NodeIndex) = .empty;
    try newly_live.append(allocator, module_directive);
    try newly_live.appendSlice(allocator, restored_imports);
    try @import("statement_owner_projection.zig").refresh(module, shaker, newly_live.items);
    if (module.transform_cache) |*cache| cache.symbol_ids = semantic.symbol_ids;
}

test "strict ESM function factories retain source SID scope and mutable references across ten forms" {
    const sources = [_][]const u8{
        "export function read(value=1){return this}",
        "export function __proto__(value=1){return this}",
        "export function read(value=1){return arguments.callee}",
        "export function read(value=1){eval('var leaked=1');return typeof leaked}",
        "export function read(n=1){if(n){read=()=>77;return read(0)}return 42}",
        "export function read(first,second=1){return 42}",
        "export function read(value=1){return read.caller}",
        "export function read(callback=function(){return this}){return callback()}",
        "export function* read(value=1){yield this}",
        "export async function read(value=1){return this}",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        scanner.is_module = true;
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.is_module = true;
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var module = Module.init(@fromBackingInt(@as(u32, 0)), "strict.mjs");
        module.ast = parser.ast;
        module.source = source;
        module.parse_arena = &arena;
        module.wrap_kind = .esm;
        module.semantic = .{
            .symbols = analyzer.symbols,
            .scopes = analyzer.scopes.items,
            .scope_maps = analyzer.scope_maps.items,
            .scope_owner_map = analyzer.scope_owner_map,
            .node_scope_provenance = analyzer.node_scope_provenance,
            .exported_names = analyzer.exported_names,
            .symbol_ids = analyzer.symbol_ids.items,
            .unresolved_references = analyzer.unresolved_references,
            .references = analyzer.references.items,
        };
        const references = try allocator.dupe(@import("../semantic/symbol.zig").Reference, analyzer.references.items);
        const symbol_count = analyzer.symbols.items.len;
        const scope_count = analyzer.scopes.items.len;
        const owner = module.semantic.?.captureOwnerToken();
        try lowerModule(&module);
        const current = module.semantic.?;
        try std.testing.expectEqual(owner, current.owner_token);
        try std.testing.expectEqual(symbol_count, current.symbols.items.len);
        try std.testing.expectEqual(scope_count + 1, current.scopes.len);
        try std.testing.expectEqual(references.len, current.references.len);
        for (references, current.references) |before, after| {
            var identity = after;
            identity.stmt_idx = before.stmt_idx;
            identity.scope_stmt_idx = before.scope_stmt_idx;
            try std.testing.expectEqualDeep(before, identity);
        }
        try std.testing.expectEqual(@as(usize, 1), current.strict_output_context.functions.len);
        const role = current.strict_output_context.functions[0];
        try validate(&module.ast.?, current, role, allocator);
        try std.testing.expectEqual(analyzer.scopes.items[role.source_scope.toIndex()].is_strict, current.scopes[role.source_scope.toIndex()].is_strict);
        var codegen = @import("../codegen/codegen.zig").Codegen.init(allocator, &module.ast.?);
        const code = try codegen.generate(root);
        try std.testing.expect(std.mem.indexOf(u8, code, "use strict") != null);
        var bytes: std.ArrayList(u8) = .empty;
        try @import("module_codec.zig").serialize(&module.ast.?, &current, &bytes, allocator);
        var decoded = try @import("module_codec.zig").deserialize(bytes.items, allocator);
        try std.testing.expectEqualDeep(current.strict_output_context.functions, decoded.semantic.strict_output_context.functions);
        try validate(&decoded.ast, decoded.semantic, decoded.semantic.strict_output_context.functions[0], allocator);
        var malformed = role;
        malformed.factory_scope = .none;
        try std.testing.expectError(error.InvalidStrictFunctionRole, validate(&module.ast.?, current, malformed, allocator));
        malformed = role;
        malformed.symbol = @fromBackingInt(@as(u32, @intCast(current.symbols.items.len)));
        try std.testing.expectError(error.InvalidStrictFunctionRole, validate(&module.ast.?, current, malformed, allocator));
        try expectStableReapplication(&module, allocator);
    }
}

test "strict simple function directives preserve source prologue and nested coordinates in ten forms" {
    const sources = [_][]const u8{
        "export function read(){return this}",
        "export function read(value){return arguments.callee}",
        "export function read(){/*first*/'custom';/*second*/'other';let value=1;return value}",
        "export function read(){let value=1;{let nested=2;return ()=>value+nested}}",
        "export function read(){eval('read=()=>77');return read()}",
        "export function read(){return class Inner{self(){return Inner}}}",
        "export function read(){class Local{}return Local}",
        "export function read(){try{let value=1;return()=>value}catch(error){return error}}",
        "export function __proto__(value){return this}",
        "export function read(){'custom';'use strict';let value=1;return value}",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        scanner.is_module = true;
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.is_module = true;
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        const original_scopes = try allocator.dupe(@import("../semantic/scope.zig").Scope, analyzer.scopes.items);
        const original_references = try allocator.dupe(@import("../semantic/symbol.zig").Reference, analyzer.references.items);
        var module = Module.init(@fromBackingInt(@as(u32, 0)), "strict.mjs");
        module.ast = parser.ast;
        module.source = source;
        module.parse_arena = &arena;
        module.wrap_kind = .esm;
        module.semantic = .{
            .symbols = analyzer.symbols,
            .scopes = analyzer.scopes.items,
            .scope_maps = analyzer.scope_maps.items,
            .scope_owner_map = analyzer.scope_owner_map,
            .class_self_symbol_map = analyzer.class_self_symbol_map,
            .node_scope_provenance = analyzer.node_scope_provenance,
            .exported_names = analyzer.exported_names,
            .symbol_ids = analyzer.symbol_ids.items,
            .unresolved_references = analyzer.unresolved_references,
            .references = analyzer.references.items,
        };
        const list = parser.ast.getNode(root).data.list;
        const statement = parser.ast.getNode(@fromBackingInt(parser.ast.extra_data.items[list.start]));
        const function_index = parser.ast.readExtraNode(statement.data.extra, 0);
        const body_index = parser.ast.readExtraNode(parser.ast.getNode(function_index).data.extra, 2);
        const old_body = parser.ast.getNode(body_index).data.list;
        var old_prologue: std.ArrayList(NodeIndex) = .empty;
        for (parser.ast.extra_data.items[old_body.start .. old_body.start + old_body.len]) |raw| {
            const index: NodeIndex = @fromBackingInt(raw);
            if (parser.ast.getNode(index).tag != .directive) break;
            try old_prologue.append(allocator, index);
        }
        const owner = module.semantic.?.captureOwnerToken();
        try lowerModule(&module);
        const current = module.semantic.?;
        try std.testing.expectEqual(owner, current.owner_token);
        try std.testing.expectEqualDeep(original_scopes, current.scopes);
        try std.testing.expectEqual(@as(usize, 1), current.strict_output_context.functions.len);
        try std.testing.expectEqual(.body_directive, current.strict_output_context.functions[0].kind);
        const body_role = current.strict_output_context.functions[0];
        var encoded: std.ArrayList(u8) = .empty;
        try @import("module_codec.zig").serialize(&module.ast.?, &current, &encoded, allocator);
        const decoded = try @import("module_codec.zig").deserialize(encoded.items, allocator);
        try std.testing.expectEqualDeep(current.strict_output_context.functions, decoded.semantic.strict_output_context.functions);
        try validateContext(&decoded.ast, decoded.semantic, allocator);
        var missing = current;
        missing.strict_output_context.functions = &.{};
        try std.testing.expectError(error.InvalidStrictFunctionRole, validateContext(&module.ast.?, missing, allocator));
        var malformed = body_role;
        malformed.directive = .none;
        try std.testing.expectError(error.InvalidStrictFunctionRole, validate(&module.ast.?, current, malformed, allocator));
        malformed = body_role;
        malformed.lexical_root = .none;
        try std.testing.expectError(error.InvalidStrictFunctionRole, validate(&module.ast.?, current, malformed, allocator));
        try std.testing.expectEqual(original_references.len, current.references.len);
        for (original_references, current.references) |before, after| {
            var identity = after;
            identity.scope_stmt_idx = before.scope_stmt_idx;
            identity.stmt_idx = before.stmt_idx;
            try std.testing.expectEqualDeep(before, identity);
        }
        const body = module.ast.?.getNode(body_index).data.list;
        var strict_body = false;
        for (module.ast.?.extra_data.items[body.start .. body.start + body.len]) |raw| {
            const node = module.ast.?.getNode(@fromBackingInt(raw));
            if (node.tag != .directive) break;
            const text = module.ast.?.getText(node.span);
            strict_body = strict_body or std.mem.eql(u8, text, "\"use strict\"") or std.mem.eql(u8, text, "'use strict'");
        }
        try std.testing.expect(strict_body);
        for (old_prologue.items, 0..) |old_directive, index| try std.testing.expectEqual(@backingInt(old_directive), module.ast.?.extra_data.items[body.start + index]);
        const once = try allocator.dupe(@import("../semantic/symbol.zig").Reference, current.references);
        const node_count = module.ast.?.nodes.items.len;
        try lowerModule(&module);
        try std.testing.expectEqual(node_count, module.ast.?.nodes.items.len);
        try std.testing.expectEqualDeep(once, module.semantic.?.references);
        var codegen = @import("../codegen/codegen.zig").Codegen.init(allocator, &module.ast.?);
        const code = try codegen.generate(root);
        var output_scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, code);
        output_scanner.is_module = true;
        var output_parser = @import("../parser/parser.zig").Parser.init(allocator, &output_scanner);
        output_parser.is_module = true;
        _ = try output_parser.parse();
        try std.testing.expectEqual(@as(usize, 0), output_parser.errors.items.len);
    }
}

test "strict module prologue is executable before prefixes while CJS remains sloppy" {
    const helpers = @import("test_helpers.zig");
    for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import('./consumer.mjs').then(m=>console.log(m.run()));");
        try helpers.writeFile(tmp.dir, "consumer.mjs", "import{value,sloppy}from'./dep.cjs';let mode;try{eval('strict_marker=1');mode='sloppy'}catch{mode='strict'}export function run(){return[mode,value,sloppy()]}");
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.value=42;exports.sloppy=function(){return[this,'sloppy_marker']};");
        var output = try helpers.bundleEntry(std.testing.allocator, &tmp, "entry.mjs", .{ .inline_dynamic_imports = true, .minify_identifiers = minify, .minify_whitespace = minify, .minify_syntax = minify, .keep_names = true });
        defer output.deinit();
        try std.testing.expectEqual(@as(usize, 0), if (output.result.diagnostics) |diagnostics| diagnostics.len else 0);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, output.code());
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
        try analyzer.analyze();
        var strict_owners: usize = 0;
        var sloppy_owners: usize = 0;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            const body = parser.ast.functionBodyBlock(node) orelse continue;
            var has_strict_marker = false;
            var has_sloppy_marker = false;
            var pending: std.ArrayList(NodeIndex) = .empty;
            try pending.append(allocator, body);
            while (pending.pop()) |child| {
                if (child.isNone()) continue;
                const inner = parser.ast.getNode(child);
                // Observe the nearest function, not an outer sloppy bundle IIFE
                // that merely contains both independently owned environments.
                if (parser.ast.functionBodyBlock(inner) != null) continue;
                if (inner.tag == .string_literal) {
                    const text = parser.ast.getText(inner.span);
                    has_strict_marker = has_strict_marker or std.mem.indexOf(u8, text, "strict_marker") != null;
                    has_sloppy_marker = has_sloppy_marker or std.mem.indexOf(u8, text, "sloppy_marker") != null;
                }
                var children = @import("../parser/ast_walk.zig").children(&parser.ast, inner);
                while (children.next()) |next| try pending.append(allocator, next);
            }
            if (!has_strict_marker and !has_sloppy_marker) continue;
            const scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.MissingOutputFunctionScope;
            if (has_strict_marker) {
                try std.testing.expect(analyzer.scopes.items[scope].is_strict);
                strict_owners += 1;
            }
            if (has_sloppy_marker) {
                try std.testing.expect(!analyzer.scopes.items[scope].is_strict);
                sloppy_owners += 1;
            }
        }
        try std.testing.expect(strict_owners != 0);
        try std.testing.expect(sloppy_owners != 0);
    }
}

test "strict default function factories preserve exact source and facade identities in ten forms" {
    const sources = [_][]const u8{
        "export default function read(value=1){return this}",
        "export default function(value=1){return this}",
        "export default function(){return this}",
        "export default function* read(value=1){yield this}",
        "export default async function(value=1){return this}",
        "export default function __proto__(value=1){return this}",
        "export default function r\\u0065ad(value=1){return this}",
        "export default function read(first,second=1){return 42}",
        "export default function read(n=1){if(n){read=()=>77;return read(0)}return 42}",
        "const _default=7;export default function(value=1){return[_default,this]}",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        scanner.is_module = true;
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.is_module = true;
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var source_export = NodeIndex.none;
        const original_list = parser.ast.getNode(root).data.list;
        for (parser.ast.extra_data.items[original_list.start .. original_list.start + original_list.len]) |raw| {
            const index: NodeIndex = @fromBackingInt(raw);
            if (parser.ast.getNode(index).tag == .export_default_declaration) source_export = index;
        }
        try std.testing.expect(!source_export.isNone());
        const function = parser.ast.getNode(source_export).data.unary.operand;
        const original_binding = parser.ast.readExtraNode(parser.ast.getNode(function).data.extra, 0);
        const anonymous = original_binding.isNone();
        const sid = analyzer.symbol_ids.items[@backingInt(if (anonymous) source_export else original_binding)].?;
        const source_scope = analyzer.scope_owner_map.get(@backingInt(function)).?;
        const count = analyzer.symbols.items.len;
        const source_default = analyzer.scope_maps.items[0].get("_default");
        var module = Module.init(@fromBackingInt(@as(u32, 0)), "strict-default.mjs");
        module.ast = parser.ast;
        module.source = source;
        module.parse_arena = &arena;
        module.wrap_kind = .esm;
        module.semantic = .{
            .symbols = analyzer.symbols,
            .scopes = analyzer.scopes.items,
            .scope_maps = analyzer.scope_maps.items,
            .scope_owner_map = analyzer.scope_owner_map,
            .node_scope_provenance = analyzer.node_scope_provenance,
            .exported_names = analyzer.exported_names,
            .symbol_ids = analyzer.symbol_ids.items,
            .unresolved_references = analyzer.unresolved_references,
            .references = analyzer.references.items,
        };
        module.export_bindings = try allocator.alloc(@import("binding_scanner.zig").ExportBinding, 1);
        module.export_bindings[0] = .{ .exported_name = "default", .local_name = "unused-public-spelling", .local_span = parser.ast.getNode(source_export).span, .local_symbol_node = if (anonymous) null else original_binding, .kind = .local, .symbol = @import("symbol.zig").SymbolRef.makeSemantic(module.index, sid), .default_export_node = source_export, .has_default_export_facade = anonymous, .init_is_fn_or_class = true };
        const owner = module.semantic.?.captureOwnerToken();
        try lowerModule(&module);
        const current = module.semantic.?;
        try std.testing.expectEqual(owner, current.owner_token);
        try std.testing.expectEqual(count, current.symbols.items.len);
        try std.testing.expectEqual(@as(usize, 1), current.strict_output_context.functions.len);
        const role = current.strict_output_context.functions[0];
        try std.testing.expectEqual(.factory, role.kind);
        try std.testing.expectEqual(sid, @backingInt(role.symbol));
        try std.testing.expectEqual(source_scope, @backingInt(role.source_scope));
        try std.testing.expectEqual(@as(?u32, sid), current.symbol_ids[@backingInt(role.binding)]);
        try std.testing.expectEqual(if (anonymous) @TypeOf(role.name_role).anonymous_default else .binding, role.name_role);
        try std.testing.expectEqual(ast_mod.Node.Tag.export_named_declaration, module.ast.?.getNode(source_export).tag);
        const exported = module.export_bindings[0];
        try std.testing.expectEqual(@as(?NodeIndex, null), exported.default_export_node);
        try std.testing.expect(!exported.has_default_export_facade);
        try std.testing.expectEqual(@as(?u32, sid), current.symbol_ids[@backingInt(exported.local_symbol_node.?)]);
        if (anonymous) {
            try std.testing.expectEqual(@as(?u32, null), current.symbol_ids[@backingInt(source_export)]);
            if (source_default != @as(?usize, sid)) try std.testing.expectEqual(source_default, current.scope_maps[0].get("_default"));
        }
        var encoded: std.ArrayList(u8) = .empty;
        try @import("module_codec.zig").serialize(&module.ast.?, &current, &encoded, allocator);
        const decoded = try @import("module_codec.zig").deserialize(encoded.items, allocator);
        try std.testing.expectEqualDeep(current.strict_output_context.functions, decoded.semantic.strict_output_context.functions);
        try validateContext(&decoded.ast, decoded.semantic, allocator);
        var missing = current;
        missing.strict_output_context.functions = &.{};
        try std.testing.expectError(error.InvalidStrictFunctionRole, validateContext(&module.ast.?, missing, allocator));
        try expectStableReapplication(&module, allocator);
    }
}

fn expectStableReapplication(module: *Module, allocator: std.mem.Allocator) !void {
    const before = module.semantic.?;
    const roles = try allocator.dupe(Role, before.strict_output_context.functions);
    const scopes = try allocator.dupe(@import("../semantic/scope.zig").Scope, before.scopes);
    const symbol_ids = try allocator.dupe(?u32, before.symbol_ids);
    const node_count = module.ast.?.nodes.items.len;
    try lowerModule(module);
    const after = module.semantic.?;
    try std.testing.expectEqual(before.owner_token, after.owner_token);
    try std.testing.expectEqual(before.symbols.items.len, after.symbols.items.len);
    try std.testing.expectEqual(node_count, module.ast.?.nodes.items.len);
    try std.testing.expectEqualDeep(roles, after.strict_output_context.functions);
    try std.testing.expectEqualDeep(scopes, after.scopes);
    try std.testing.expectEqualSlices(?u32, symbol_ids, after.symbol_ids);
}

test "strict function census permits actual var redeclarations sharing a source function SID" {
    const sources = [_][]const u8{
        "function read(){};var read=5;",
        "\"use strict\";function read(){};var read=5;",
        "function read(value=1){};var read=5;",
        "function* read(){};var read=5;",
        "async function read(){};var read=5;",
        "async function* read(){};var read=5;",
        "function read(){};var read;var read=5;",
        "function read(){};var \\u0072ead=5;",
        "var read=5;function read(){}",
        "function read(){};function read(){};var read=5;",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        _ = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var module = Module.init(@fromBackingInt(@as(u32, 0)), "strict.mjs");
        module.ast = parser.ast;
        module.source = source;
        module.parse_arena = &arena;
        module.wrap_kind = .esm;
        module.semantic = .{
            .symbols = analyzer.symbols,
            .scopes = analyzer.scopes.items,
            .scope_maps = analyzer.scope_maps.items,
            .scope_owner_map = analyzer.scope_owner_map,
            .node_scope_provenance = analyzer.node_scope_provenance,
            .exported_names = analyzer.exported_names,
            .symbol_ids = analyzer.symbol_ids.items,
            .unresolved_references = analyzer.unresolved_references,
            .references = analyzer.references.items,
        };
        const owner = module.semantic.?.captureOwnerToken();
        const symbols = module.semantic.?.symbols.items.len;
        try validateContext(&module.ast.?, module.semantic.?, allocator);
        const root = module.ast.?.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(module.ast.?.nodes.items.len - 1))));
        const root_list = module.ast.?.getNode(root).data.list;
        var source_functions: usize = 0;
        var source_function: NodeIndex = .none;
        var checked_function_vars: usize = 0;
        for (module.ast.?.extra_data.items[root_list.start .. root_list.start + root_list.len]) |raw| {
            const statement: NodeIndex = @fromBackingInt(raw);
            const node = module.ast.?.getNode(statement);
            if (node.tag == .function_declaration) {
                source_functions += 1;
                source_function = statement;
            }
            if (node.tag != .variable_declaration) continue;
            const declarator = module.ast.?.readExtraNode(module.ast.?.extra_data.items[node.data.extra + 1], 0);
            const binding = module.ast.?.readExtraNode(module.ast.?.getNode(declarator).data.extra, 0);
            const sid = module.semantic.?.symbol_ids[@backingInt(binding)].?;
            if (!isFunctionKind(module.semantic.?.symbols.items[sid].kind)) continue;
            checked_function_vars += 1;
            const old_kind = module.ast.?.extra_data.items[node.data.extra];
            module.ast.?.extra_data.items[node.data.extra] = @backingInt(ast_mod.VariableDeclarationKind.let);
            try std.testing.expectError(error.InvalidStrictFunctionRole, validateContext(&module.ast.?, module.semantic.?, allocator));
            module.ast.?.extra_data.items[node.data.extra] = old_kind;
        }
        if (source_functions == 1 and checked_function_vars > 0) {
            const function = module.ast.?.getNode(source_function);
            module.ast.?.nodes.items[@backingInt(source_function)].tag = .empty_statement;
            try std.testing.expectError(error.InvalidStrictFunctionRole, validateContext(&module.ast.?, module.semantic.?, allocator));
            module.ast.?.nodes.items[@backingInt(source_function)] = function;
        }
        try validateContext(&module.ast.?, module.semantic.?, allocator);
        try lowerModule(&module);
        try validateContext(&module.ast.?, module.semantic.?, allocator);
        try std.testing.expectEqual(owner, module.semantic.?.owner_token);
        try std.testing.expectEqual(symbols, module.semantic.?.symbols.items.len);
        try expectStableReapplication(&module, allocator);
    }
}

test "strict adjacent factories keep their actual declaration owners through emission merge" {
    const sources = [_][]const u8{
        "export function first(value=1){return this}export function second(value=2){return this}",
        "export function first(value=1){return this}export function second(value=2){return this}export function third(value=3){return this}",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        scanner.is_module = true;
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.is_module = true;
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var module = Module.init(@fromBackingInt(@as(u32, 0)), "strict.mjs");
        module.ast = parser.ast;
        module.source = source;
        module.parse_arena = &arena;
        module.wrap_kind = .esm;
        module.semantic = .{
            .symbols = analyzer.symbols,
            .scopes = analyzer.scopes.items,
            .scope_maps = analyzer.scope_maps.items,
            .scope_owner_map = analyzer.scope_owner_map,
            .node_scope_provenance = analyzer.node_scope_provenance,
            .exported_names = analyzer.exported_names,
            .symbol_ids = analyzer.symbol_ids.items,
            .unresolved_references = analyzer.unresolved_references,
            .references = analyzer.references.items,
        };
        try lowerModule(&module);
        const ast = &module.ast.?;
        const owner = module.semantic.?.captureOwnerToken();
        const current = module.semantic.?;
        try validateContext(ast, current, allocator);
        const roles = try allocator.dupe(Role, current.strict_output_context.functions);
        try mergeOutputDeclarations(ast, current, root, null, allocator);
        try mergeOutputDeclarations(ast, current, root, null, allocator);
        try std.testing.expectEqualDeep(roles, current.strict_output_context.functions);
        try std.testing.expectEqual(owner, module.semantic.?.captureOwnerToken());
        for (roles) |role| {
            const declaration = ast.getNode(role.declaration);
            try std.testing.expectEqual(.variable_declaration, declaration.tag);
            try std.testing.expectEqual(@as(u32, 1), ast.extra_data.items[declaration.data.extra + 2]);
        }
        try validateContext(ast, current, allocator);
    }
}
test "strict function source census requires exact live binding without inventing factory roles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Legal SCRIPT declarations. Do not substitute export+var duplicate ESM syntax.
    const input_source = "function read(value=1){return value};var read=5;function other(){};var other=6;";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, input_source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var module = Module.init(@fromBackingInt(@as(u32, 0)), "source-script.js");
    module.ast = parser.ast;
    module.source = input_source;
    module.parse_arena = &arena;
    module.wrap_kind = .esm;
    module.semantic = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .node_scope_provenance = analyzer.node_scope_provenance,
        .exported_names = analyzer.exported_names,
        .symbol_ids = analyzer.symbol_ids.items,
        .unresolved_references = analyzer.unresolved_references,
        .references = analyzer.references.items,
    };
    const mutable_ids = try allocator.dupe(?u32, module.semantic.?.symbol_ids);
    module.semantic.?.symbol_ids = mutable_ids;
    const ast = &module.ast.?;
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    const list = ast.getNode(root).data.list;
    var functions: [2]NodeIndex = undefined;
    var count: usize = 0;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
        const ni: NodeIndex = @fromBackingInt(raw);
        if (ast.getNode(ni).tag != .function_declaration) continue;
        functions[count] = ni;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    const binding = ast.readExtraNode(ast.getNode(functions[0]).data.extra, 0);
    const sibling = ast.readExtraNode(ast.getNode(functions[1]).data.extra, 0);
    const sid = module.semantic.?.symbol_ids[@backingInt(binding)].?;
    const sibling_sid = module.semantic.?.symbol_ids[@backingInt(sibling)].?;
    try std.testing.expect(sid != sibling_sid);
    try validateContext(ast, module.semantic.?, allocator);
    // A valid sibling SID is not proof for the original source function's var.
    mutable_ids[@backingInt(binding)] = sibling_sid;
    try std.testing.expectError(error.InvalidStrictFunctionRole, validateContext(ast, module.semantic.?, allocator));
    mutable_ids[@backingInt(binding)] = null;
    try std.testing.expectError(error.InvalidStrictFunctionRole, validateContext(ast, module.semantic.?, allocator));
    mutable_ids[@backingInt(binding)] = sid;
    const original_binding = ast.nodes.items[@backingInt(binding)];
    ast.nodes.items[@backingInt(binding)].tag = .identifier_reference;
    try std.testing.expectError(error.InvalidStrictFunctionRole, validateContext(ast, module.semantic.?, allocator));
    ast.nodes.items[@backingInt(binding)] = original_binding;
    // A producer-tagged function cannot borrow the source redeclaration exemption.
    module.semantic.?.symbols.items[sid].binding_instantiation.strict_output_function = true;
    try std.testing.expectError(error.InvalidStrictFunctionRole, validateContext(ast, module.semantic.?, allocator));
    module.semantic.?.symbols.items[sid].binding_instantiation.strict_output_function = false;
    try validateContext(ast, module.semantic.?, allocator);
    try lowerModule(&module);
    try validateContext(&module.ast.?, module.semantic.?, allocator);
    // SCRIPT redeclarations do not manufacture a strict factory ledger.
    try std.testing.expectEqual(@as(usize, 0), module.semantic.?.strict_output_context.functions.len);
    try expectStableReapplication(&module, allocator);
}
