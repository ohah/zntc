//! A single self-namespace holder with real declaration/reference authority.
//! All fallible preparation precedes publication; source arena backing survives.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const sem_mod = @import("../semantic/symbol.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Module = @import("module.zig").Module;
const Semantic = @import("module.zig").ModuleSemanticData;
const Graph = @import("graph.zig").ModuleGraph;
const walk = @import("../parser/ast_walk.zig");

pub const Options = struct {
    format: @import("types.zig").Format,
    scope_hoist: bool,
    minify_syntax: bool,
};

/// Graph-local output proof. This is never serialized or recovered by name.
pub const Completed = struct {
    module: *const Module,
    owner: @import("module.zig").SemanticOwnerToken,
    root: NodeIndex,
    root_scope: ScopeId,
    holder: u32,
    binding: NodeIndex,
    declarator: NodeIndex,
    statement: NodeIndex,
    getter: NodeIndex,
    getter_scope: ScopeId,
    read: NodeIndex,
    exported: u32,
    nodes: []const ast_mod.Node,
    ids: []const ?u32,
    references: []const sem_mod.Reference,
    expected_nodes: []const ast_mod.Node,
    expected_extras: []const u32,
    expected_ids: []const ?u32,
    source_bytes: []const u8,
    scopes: []const @import("../semantic/scope.zig").Scope,
    expected_scopes: []const @import("../semantic/scope.zig").Scope,
    expected_symbols: []const sem_mod.Symbol,
    strings: []const u8,
    expected_strings: []const u8,
    expected_lexical: []const u32,
    boundary: u32,
    maps: []const std.StringHashMapUnmanaged(usize),
    root_map: std.StringHashMapUnmanaged(usize),
    getter_map: std.StringHashMapUnmanaged(usize),
    cache: @import("module.zig").TransformCache,
};

const Source = struct {
    root: NodeIndex,
    scope: ScopeId,
    specifier: NodeIndex,
    declaration: NodeIndex,
    holder: u32,
    row: usize,
    exported: u32,
};

fn asciiIdentifier(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] != '$')) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '$') return false;
    return true;
}

fn isReflectGet(ast: *const Ast, sem: *const Semantic, call: ast_mod.Node, exported_name: []const u8) bool {
    if (call.tag != .call_expression or !ast.hasExtra(call.data.extra, 3)) return false;
    const extra = ast.extra_data.items;
    if (extra[call.data.extra + 2] != 2 or extra[call.data.extra + 3] != 0) return false;
    const callee_raw = extra[call.data.extra];
    const start = extra[call.data.extra + 1];
    if (callee_raw >= ast.nodes.items.len or start > extra.len or extra.len - start < 2) return false;
    const callee = ast.nodes.items[callee_raw];
    if (callee.tag != .static_member_expression or !ast.hasExtra(callee.data.extra, 2) or extra[callee.data.extra + 2] != 0) return false;
    const base_raw = extra[callee.data.extra];
    const property_raw = extra[callee.data.extra + 1];
    const key_raw = extra[start + 1];
    if (base_raw >= ast.nodes.items.len or property_raw >= ast.nodes.items.len or key_raw >= ast.nodes.items.len or base_raw >= sem.symbol_ids.len) return false;
    const base = ast.nodes.items[base_raw];
    const property = ast.nodes.items[property_raw];
    const key = ast.nodes.items[key_raw];
    return base.tag == .identifier_reference and sem.symbol_ids[base_raw] == null and
        sem.unresolved_references.contains("Reflect") and std.mem.eql(u8, ast.getText(base.span), "Reflect") and
        property.tag == .identifier_reference and std.mem.eql(u8, ast.getText(property.span), "get") and
        key.tag == .string_literal and std.mem.eql(u8, Ast.stripStringQuotes(ast.getText(key.span)), exported_name);
}

fn source(graph: *Graph, module: *const Module) !?Source {
    if (module.wrap_kind != .none or module.transform_cache != null or module.import_bindings.len != 1 or
        module.import_records.len != 1 or module.export_bindings.len != 1 or module.dynamic_imports.items.len != 0 or
        module.reachable_stmts != null or module.symbol_to_stmt != null) return null;
    const ast = if (module.ast) |*value| value else return null;
    const sem = if (module.semantic) |*value| value else return null;
    if (ast.nodes.items.len == 0 or ast.source.ptr != module.source.ptr or ast.source.len != module.source.len) return null;
    if (ast.transformed_root != null or ast.transform_boundary != null or ast.is_typescript or ast.has_jsx or ast.has_decorator or
        sem.scopes.len != 1 or sem.symbols.items.len != 2 or sem.runtime_identities != null or
        sem.strict_output_context.functions.len != 0 or graph.shouldRunTransformerPrePass(module, false)) return null;
    for (sem.scopes) |scope| if (scope.blocksMangling()) return null;
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1)));
    if (ast.getNode(root).tag != .program) return null;
    const root_scope: ScopeId = @fromBackingInt(sem.scope_owner_map.get(@backingInt(root)) orelse return null);
    if (root_scope.isNone() or root_scope.toIndex() >= sem.scopes.len or sem.scopes[root_scope.toIndex()].kind != .module or
        !sem.scopes[root_scope.toIndex()].parent.isNone()) return null;
    const binding = module.import_bindings[0];
    if (binding.kind != .namespace or binding.is_helper or binding.callsite_target != null or binding.local_role != .import_binding or binding.import_record_index != 0) return null;
    const record = module.import_records[0];
    if (record.resolved != module.index or graph.getModule(record.resolved) != module or record.ts_elided or record.is_lazy_resolved) return null;
    const specifier = binding.local_symbol_node orelse return null;
    const declaration = binding.local_declaration_node orelse return null;
    if (@backingInt(specifier) >= sem.symbol_ids.len) return null;
    const holder = sem.symbol_ids[@backingInt(specifier)] orelse return null;
    const exported = module.export_bindings[0];
    if (exported.public_key_origin != null or exported.public_key_literal != null or exported.public_key_binding_value != null or
        exported.has_public_key_literal or !asciiIdentifier(exported.exported_name) or !asciiIdentifier(exported.local_name)) return null;
    const export_node = exported.local_symbol_node orelse return null;
    if (@backingInt(export_node) >= sem.symbol_ids.len) return null;
    const export_sid = sem.symbol_ids[@backingInt(export_node)] orelse return null;
    if (export_sid == holder or export_sid >= sem.symbols.items.len or holder >= sem.symbols.items.len or
        sem.symbols.items[export_sid].kind != .variable_const or sem.symbols.items[export_sid].scope_id != root_scope) return null;
    // The shared coordinate collector and child walk use arena scratch.
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const scratch_allocator = scratch.allocator();
    const source_contexts = try @import("../semantic/statement_coordinates.zig").collect(scratch_allocator, ast, root);
    if (@backingInt(export_node) >= source_contexts.len) return null;
    const export_context = source_contexts[@backingInt(export_node)] orelse return null;
    const reachable = try walk.collectReachableNodeIndicesFrom(scratch_allocator, ast, root);
    const parents = try scratch_allocator.alloc(u32, ast.nodes.items.len);
    @memset(parents, 0);
    var arguments: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (reachable) |raw| {
        const parent = ast.nodes.items[raw];
        var children = walk.children(ast, parent);
        while (children.next()) |child| {
            if (child.isNone()) continue;
            if (@backingInt(child) >= parents.len) return null;
            parents[@backingInt(child)] += 1;
        }
        switch (parent.tag) {
            .assignment_expression, .update_expression, .new_expression, .import_expression => return null,
            else => {},
        }
        if (!isReflectGet(ast, sem, parent, exported.exported_name)) continue;
        if (!ast.hasExtra(parent.data.extra, 2)) return null;
        const start = ast.extra_data.items[parent.data.extra + 1];
        const len = ast.extra_data.items[parent.data.extra + 2];
        if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return null;
        if (len != 2) return null;
        try arguments.put(scratch_allocator, ast.extra_data.items[start], {});
    }
    var row: ?usize = null;
    var reads: usize = 0;
    for (sem.references, 0..) |reference, index| {
        if (@backingInt(reference.symbol_id) != holder) continue;
        if (reference.flags.declare) {
            if (row != null or reference.declaration_node_index != specifier) return null;
            row = index;
        } else {
            if (!std.meta.eql(reference.flags, sem_mod.ReferenceFlags{ .read = true }) or reference.scope_id != root_scope) return null;
            reads += 1;
            // Only an actual reachable value argument with one structural
            // parent. Stale/orphan arena nodes cannot supply this witness.
            const raw = @backingInt(reference.node_index);
            if (raw >= parents.len or parents[raw] != 1 or !arguments.contains(raw)) return null;
            const context = source_contexts[raw] orelse return null;
            if (reference.stmt_idx != context.stmt_idx or reference.scope_stmt_idx != context.scope_stmt_idx or context.stmt_idx <= export_context.stmt_idx) return null;
        }
    }
    if (reads == 0) return null;
    // No source function/class/loop or declaration beyond the known export.
    // A scalar initializer leaves no pending lowering or foreign helper demand.
    var scalar_export = false;
    const statements = walk.topLevelStatementIndices(ast) orelse return null;
    for (statements) |raw| {
        const node = ast.getNode(@fromBackingInt(raw));
        switch (node.tag) {
            .directive, .expression_statement => {},
            .import_declaration => if (raw != @backingInt(declaration)) return null,
            .export_named_declaration => {
                if (!ast.hasExtra(node.data.extra, 5)) return null;
                const decl_raw = ast.extra_data.items[node.data.extra];
                if (decl_raw >= ast.nodes.items.len) return null;
                const decl = ast.nodes.items[decl_raw];
                if (decl.tag != .variable_declaration or !ast.hasExtra(decl.data.extra, 2) or
                    ast.extra_data.items[decl.data.extra] != @backingInt(ast_mod.VariableDeclarationKind.@"const") or ast.extra_data.items[decl.data.extra + 2] != 1) return null;
                const declarations_start = ast.extra_data.items[decl.data.extra + 1];
                if (declarations_start >= ast.extra_data.items.len) return null;
                const declarator_raw = ast.extra_data.items[declarations_start];
                if (declarator_raw >= ast.nodes.items.len) return null;
                const item = ast.nodes.items[declarator_raw];
                if (item.tag != .variable_declarator or !ast.hasExtra(item.data.extra, 2) or ast.extra_data.items[item.data.extra] != @backingInt(export_node) or
                    ast.extra_data.items[item.data.extra + 1] != @backingInt(NodeIndex.none)) return null;
                const initializer = ast.extra_data.items[item.data.extra + 2];
                if (initializer >= ast.nodes.items.len) return null;
                switch (ast.nodes.items[initializer].tag) {
                    .numeric_literal, .string_literal, .boolean_literal, .null_literal => scalar_export = true,
                    else => return null,
                }
            },
            else => return null,
        }
    }
    if (!scalar_export) return null;
    return .{ .root = root, .scope = root_scope, .specifier = specifier, .declaration = declaration, .holder = holder, .row = row orelse return null, .exported = export_sid };
}

fn captureSourceExternals(a: std.mem.Allocator, ast: *const Ast, sem: *const Semantic) !std.AutoHashMapUnmanaged(u32, void) {
    var result: std.AutoHashMapUnmanaged(u32, void) = .empty;
    // Same source-only capture as graph prepass: never attach an ID or mark a
    // generated node external. Coverage still classifies property-key roles.
    for (ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        if (raw >= sem.symbol_ids.len or sem.symbol_ids[raw] != null) continue;
        const raw_name = ast.getText(node.span);
        if (sem.unresolved_references.contains(raw_name)) {
            try result.put(a, @intCast(raw), {});
        } else if (std.mem.indexOfScalar(u8, raw_name, '\\') != null) {
            const decoded = try @import("../lexer/scanner.zig").Scanner.decodeIdentifierEscapesAlloc(a, raw_name);
            if (sem.unresolved_references.contains(decoded)) try result.put(a, @intCast(raw), {});
        }
    }
    return result;
}

pub fn lower(graph: *Graph, options: Options) !void {
    const module = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(0)) orelse return;
    const eligible = options.format == .esm and options.scope_hoist and !options.minify_syntax and !graph.dev_mode and !graph.code_splitting and !graph.preserve_modules and
        graph.moduleCount() == 1 and graph.plugins.len == 0 and !graph.worklet_transform and !graph.react_refresh and !graph.styled_components and !graph.emotion and
        graph.defines.len == 0 and !graph.minify_identifiers and !graph.transform_options_base.unsupported.hasAny() and
        graph.interop_ast_provider == null and graph.dynamic_import_ast_provider == null and graph.entry_guard_ast_provider == null;
    if (graph.self_namespace_holders.contains(module.index.toU32()) or
        (module.import_bindings.len == 1 and module.import_bindings[0].local_role == .materialized_const))
    {
        if (!eligible or graph.shouldRunTransformerPrePass(module, false)) return error.InvalidSelfNamespaceProfile;
        try validate(graph, module);
        return;
    }
    if (!eligible) return;
    for (graph.diagnostics.items) |diagnostic| if (diagnostic.severity == .@"error") return;
    const input = (try source(graph, module)) orelse return;
    try assemble(graph, module, input);
}

fn assemble(graph: *Graph, module: *Module, input: Source) !void {
    const a = module.parse_arena.?.allocator();
    // Value snapshots retain old backing; never deinit the source arena here.
    const old_ast = module.ast.?;
    const old_sem = module.semantic.?;
    const parser_count: u32 = @intCast(old_ast.nodes.items.len);
    const externals = try captureSourceExternals(a, &old_ast, &old_sem);
    const ast = try a.create(Ast);
    ast.* = try Ast.cloneForTransformer(&old_ast, a);
    ast.transform_boundary = parser_count;
    var editor = try old_sem.beginEdit(a, ast);
    const export_name = module.export_bindings[0].exported_name;
    const key_span = try ast.addString(export_name);
    const key = try ast.addNode(.{ .tag = .identifier_reference, .span = .EMPTY, .data = .{ .string_ref = key_span } });
    const value_span = old_sem.symbols.items[input.exported].name;
    const read = try ast.addNode(.{ .tag = .identifier_reference, .span = value_span, .data = .{ .string_ref = value_span } });
    const returned = try ast.addNode(.{ .tag = .return_statement, .span = .EMPTY, .data = .{ .unary = .{ .operand = read, .flags = 0 } } });
    const body = try ast.addNode(.{ .tag = .block_statement, .span = .EMPTY, .data = .{ .list = try ast.addNodeList(&.{returned}) } });
    const params = try ast.addNode(.{ .tag = .formal_parameters, .span = .EMPTY, .data = .{ .list = .{ .start = 0, .len = 0 } } });
    const getter = try ast.addNode(.{ .tag = .method_definition, .span = .EMPTY, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(key), @backingInt(params), @backingInt(body), 2, 0, 0 }) } });
    const getter_scope = try editor.addScope(input.scope, getter, .function, false);
    try editor.addReference(read, @fromBackingInt(input.exported), getter_scope, .{ .read = true }, sem_mod.Reference.NO_STMT, sem_mod.Reference.NO_STMT);
    const object = try ast.addNode(.{ .tag = .object_expression, .span = .EMPTY, .data = .{ .list = try ast.addNodeList(&.{getter}) } });
    ast.has_object_getter = true;
    const holder_name = old_sem.symbols.items[input.holder].name;
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = holder_name, .data = .{ .string_ref = holder_name } });
    const declarator = try ast.addNode(.{ .tag = .variable_declarator, .span = .EMPTY, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(binding), @backingInt(NodeIndex.none), @backingInt(object) }) } });
    const declarations = try ast.addNodeList(&.{declarator});
    const statement = try ast.addNode(.{ .tag = .variable_declaration, .span = .EMPTY, .data = .{ .extra = try ast.addExtras(&.{ @backingInt(ast_mod.VariableDeclarationKind.@"const"), declarations.start, declarations.len }) } });
    try editor.moveKnownNamespaceImportToConst(.{
        .ast = ast,
        .root = input.root,
        .root_scope = input.scope,
        .symbol = @fromBackingInt(input.holder),
        .source_specifier = input.specifier,
        .source_declaration = input.declaration,
        .declaration_row = input.row,
        .expected_source_flags = old_sem.symbols.items[input.holder].decl_flags,
        .output_binding = binding,
        .output_declarator = declarator,
        .output_statement = statement,
    });
    try ast.preserve_lexical_declaration_indices.append(a, @backingInt(statement));
    var statements: std.ArrayList(NodeIndex) = .empty;
    var inserted = false;
    const old_list = old_ast.getNode(input.root).data.list;
    for (old_ast.extra_data.items[old_list.start..][0..old_list.len]) |raw| {
        const node: NodeIndex = @fromBackingInt(raw);
        if (!inserted and old_ast.getNode(node).tag != .directive) {
            try statements.append(a, statement);
            inserted = true;
        }
        if (node != input.declaration) try statements.append(a, node);
    }
    if (!inserted) try statements.append(a, statement);
    // StmtInfo's source-compatible builder requires this to be the last node.
    const root = try ast.addNode(.{ .tag = .program, .span = old_ast.getNode(input.root).span, .data = .{ .list = try ast.addNodeList(statements.items) } });
    try editor.remapScopeOwner(input.root, root);
    ast.transformed_root = root;
    var candidate = old_sem;
    try @import("strict_function_context.zig").remapProgram(&candidate.strict_output_context, input.root, root);
    candidate.applyEdit(try editor.finish());
    const contexts = try @import("../semantic/statement_coordinates.zig").collect(a, ast, root);
    const references = try a.dupe(sem_mod.Reference, candidate.references);
    for (references) |*reference| {
        const node = if (reference.flags.declare) reference.declaration_node_index else reference.node_index;
        if (node.isNone() or @backingInt(node) >= contexts.len) return error.InvalidSelfNamespaceCoordinates;
        const context = contexts[@backingInt(node)] orelse return error.InvalidSelfNamespaceCoordinates;
        reference.stmt_idx = context.stmt_idx;
        reference.scope_stmt_idx = context.scope_stmt_idx;
    }
    candidate.references = references;
    const infos = (try @import("stmt_info.zig").buildFromSemantic(a, ast, candidate.symbols.items, candidate.scopes, references, &candidate.unresolved_references, false, false)) orelse return error.InvalidSelfNamespaceStatements;
    const empty: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const exact = try @import("../transformer/symbol_coverage.zig").checkExactWithCompleteSourceScopeOwners(a, ast, root, parser_count, candidate.symbol_ids, candidate.symbols.items, candidate.scopes, candidate.scope_maps, &candidate.scope_owner_map, references, &.{}, &candidate.helper_scope_map, &externals, &empty, &origins);
    if (!exact.isClean()) return error.InvalidSelfNamespaceExactGraph;
    var completed_bindings = try a.dupe(@import("binding_scanner.zig").ImportBinding, module.import_bindings);
    completed_bindings[0].local_role = .materialized_const;
    completed_bindings[0].local_symbol_node = binding;
    completed_bindings[0].local_declaration_node = statement;
    const binding_context = contexts[@backingInt(binding)] orelse return error.InvalidSelfNamespaceCoordinates;
    const read_context = contexts[@backingInt(read)] orelse return error.InvalidSelfNamespaceCoordinates;
    if (binding_context.stmt_idx >= infos.stmts.len or input.holder >= infos.symbol_to_stmt.len or
        infos.symbol_to_stmt[input.holder] != binding_context.stmt_idx or infos.stmts[binding_context.stmt_idx].node_idx != @backingInt(statement) or
        read_context.stmt_idx != binding_context.stmt_idx or read_context.scope_stmt_idx != 0) return error.InvalidSelfNamespaceStatements;
    const reference_snapshot = try a.dupe(sem_mod.Reference, references);
    const node_snapshot = try a.dupe(ast_mod.Node, ast.nodes.items);
    const extras_snapshot = try a.dupe(u32, ast.extra_data.items);
    const ids_snapshot = try a.dupe(?u32, candidate.symbol_ids);
    const source_snapshot = try a.dupe(u8, ast.source);
    const scopes_snapshot = try a.dupe(@import("../semantic/scope.zig").Scope, candidate.scopes);
    const symbols_snapshot = try a.dupe(sem_mod.Symbol, candidate.symbols.items);
    const strings_snapshot = try a.dupe(u8, ast.string_table.items);
    const lexical_snapshot = try a.dupe(u32, ast.preserve_lexical_declaration_indices.items);
    var projected_module = module.*;
    projected_module.ast = ast.*;
    projected_module.semantic = candidate;
    // The actual native getter is now present; no emitter-only transform may
    // be skipped merely because the original source required no prepass.
    if (graph.shouldRunTransformerPrePass(&projected_module, false)) return error.PendingSelfNamespaceTransform;
    try graph.self_namespace_holders.ensureUnusedCapacity(graph.allocator, 1);
    if (graph.self_namespace_holders.contains(module.index.toU32())) return error.DuplicateSelfNamespaceHolder;
    const cache: @import("module.zig").TransformCache = .{ .runtime_helpers = .{}, .symbol_ids = candidate.symbol_ids };
    const owner = candidate.captureOwnerToken(); // candidate only; source stays unchanged on failure
    const plan: Completed = .{
        .module = module,
        .owner = owner,
        .root = root,
        .root_scope = input.scope,
        .holder = input.holder,
        .binding = binding,
        .declarator = declarator,
        .statement = statement,
        .getter = getter,
        .getter_scope = getter_scope,
        .read = read,
        .exported = input.exported,
        .nodes = ast.nodes.items,
        .ids = candidate.symbol_ids,
        .references = reference_snapshot,
        .expected_nodes = node_snapshot,
        .expected_extras = extras_snapshot,
        .expected_ids = ids_snapshot,
        .source_bytes = source_snapshot,
        .scopes = candidate.scopes,
        .expected_scopes = scopes_snapshot,
        .expected_symbols = symbols_snapshot,
        .strings = ast.string_table.items,
        .expected_strings = strings_snapshot,
        .expected_lexical = lexical_snapshot,
        .boundary = parser_count,
        .maps = candidate.scope_maps,
        .root_map = candidate.scope_maps[input.scope.toIndex()],
        .getter_map = candidate.scope_maps[getter_scope.toIndex()],
        .cache = cache,
    };
    // A real postgraph producer completed the AST and its semantic graph. This
    // view prevents the emitter from cloning an unknown output domain again.
    try validatePayload(plan, ast, &candidate, completed_bindings);
    // Nothing below allocates or validates. Publish both sides together.
    module.ast = ast.*;
    module.semantic = candidate;
    module.import_bindings = completed_bindings;
    module.prebuilt_stmt_info = infos;
    module.namespace_access_index = null;
    module.transform_cache = cache;
    graph.self_namespace_holders.putAssumeCapacity(module.index.toU32(), plan);
}

/// A const role without its exact graph-local creator plan must not return to
/// the old raw-holder path. No identity or coordinate is repaired here.
pub fn validate(graph: *const Graph, module: *const Module) !void {
    const plan = graph.self_namespace_holders.get(module.index.toU32()) orelse return error.MissingSelfNamespaceHolder;
    const ast = if (module.ast) |*value| value else return error.InvalidSelfNamespaceHolder;
    const sem = if (module.semantic) |*value| value else return error.InvalidSelfNamespaceHolder;
    if (plan.module != module or module.wrap_kind != .none) return error.InvalidSelfNamespaceHolder;
    const cache = module.transform_cache orelse return error.InvalidSelfNamespaceHolder;
    if (!std.meta.eql(cache, plan.cache)) return error.InvalidSelfNamespaceHolder;
    try validatePayload(plan, ast, sem, module.import_bindings);
}

fn validatePayload(plan: Completed, ast: *const Ast, sem: *const Semantic, bindings: []const @import("binding_scanner.zig").ImportBinding) !void {
    if (sem.owner_token != plan.owner or ast.transformed_root != plan.root or
        ast.nodes.items.ptr != plan.nodes.ptr or ast.nodes.items.len != plan.nodes.len or
        sem.symbol_ids.ptr != plan.ids.ptr or sem.symbol_ids.len != plan.ids.len or
        sem.scopes.ptr != plan.scopes.ptr or sem.scopes.len != plan.expected_scopes.len or
        sem.scope_maps.ptr != plan.maps.ptr or sem.scope_maps.len != plan.maps.len or
        sem.symbols.items.len != plan.expected_symbols.len or sem.references.len != plan.references.len or !ast.has_object_getter or ast.transform_boundary != plan.boundary or
        ast.string_table.items.ptr != plan.strings.ptr or ast.string_table.items.len != plan.strings.len or
        plan.holder >= sem.symbols.items.len or plan.exported >= sem.symbols.items.len or
        @backingInt(plan.binding) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(plan.binding)] != plan.holder or
        @backingInt(plan.read) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(plan.read)] != plan.exported or
        sem.symbols.items[plan.holder].kind != .variable_const or sem.symbols.items[plan.holder].scope_id != plan.root_scope or
        plan.getter_scope.toIndex() >= sem.scopes.len or plan.root_scope.toIndex() >= sem.scopes.len or
        sem.scopes[plan.getter_scope.toIndex()].parent != plan.root_scope or sem.scopes[plan.getter_scope.toIndex()].kind != .function or
        !sem.scopes[plan.getter_scope.toIndex()].is_strict or
        sem.scope_owner_map.count() != 2 or
        sem.scope_owner_map.get(@backingInt(plan.root)) != @backingInt(plan.root_scope) or
        sem.scope_owner_map.get(@backingInt(plan.getter)) != @backingInt(plan.getter_scope)) return error.InvalidSelfNamespaceHolder;
    if (!std.mem.eql(u8, std.mem.sliceAsBytes(ast.nodes.items), std.mem.sliceAsBytes(plan.expected_nodes)) or
        !std.mem.eql(u32, ast.extra_data.items, plan.expected_extras) or
        !std.mem.eql(u8, ast.source, plan.source_bytes) or
        !std.mem.eql(u8, ast.string_table.items, plan.expected_strings) or
        !std.mem.eql(u32, ast.preserve_lexical_declaration_indices.items, plan.expected_lexical)) return error.InvalidSelfNamespaceHolder;
    const root_map = sem.scope_maps[plan.root_scope.toIndex()];
    const getter_map = sem.scope_maps[plan.getter_scope.toIndex()];
    if (root_map.metadata != plan.root_map.metadata or getter_map.metadata != plan.getter_map.metadata or
        root_map.count() != 2 or getter_map.count() != 0 or
        root_map.get(ast.getText(sem.symbols.items[plan.holder].name)) != @as(?usize, plan.holder) or
        root_map.get(ast.getText(sem.symbols.items[plan.exported].name)) != @as(?usize, plan.exported)) return error.InvalidSelfNamespaceHolder;
    for (sem.scopes, plan.expected_scopes) |current, expected| if (!std.meta.eql(current, expected)) return error.InvalidSelfNamespaceHolder;
    for (sem.symbols.items, plan.expected_symbols) |current, expected| {
        // Liveness/ref counts can be updated legitimately by the linker.
        if (!std.meta.eql(current.name, expected.name) or current.kind != expected.kind or current.scope_id != expected.scope_id or
            current.origin_scope != expected.origin_scope or !std.meta.eql(current.decl_flags, expected.decl_flags) or
            current.synthetic_kind != expected.synthetic_kind or current.synthetic_owner_id != expected.synthetic_owner_id or
            !std.mem.eql(u8, current.synthetic_name, expected.synthetic_name)) return error.InvalidSelfNamespaceHolder;
    }
    for (sem.symbol_ids, plan.expected_ids) |current, expected| if (current != expected) return error.InvalidSelfNamespaceHolder;
    for (sem.references, plan.references) |current, expected| if (!std.meta.eql(current, expected)) return error.InvalidSelfNamespaceHolder;
    if (bindings.len != 1 or bindings[0].local_role != .materialized_const or
        bindings[0].local_symbol_node != plan.binding or bindings[0].local_declaration_node != plan.statement)
        return error.InvalidSelfNamespaceHolder;
}
