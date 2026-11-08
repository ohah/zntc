//! A native module's source AST and the compiler wrapper retain separate
//! first-analysis/name domains. Only the checked statement hole joins output.
const std = @import("std");
const Ast = @import("../../parser/ast.zig").Ast;
const NodeIndex = @import("../../parser/ast.zig").NodeIndex;
const Module = @import("../module.zig").Module;
const Linker = @import("../linker.zig").Linker;
const Metadata = @import("../linker.zig").LinkingMetadata;
const Codegen = @import("../../codegen/codegen.zig").Codegen;
const Using = @import("../../codegen/native_module_using.zig");
const Wrapper = @import("../native_module_wrapper_program.zig").Program;
const Imports = @import("../../codegen/native_module_import_projection.zig");
const Storage = @import("../../codegen/native_module_storage_projection.zig");
const Accessor = @import("../native_module_accessor_program.zig").Program;
const Namespace = @import("native_module_namespace.zig");
const parent = @import("../emitter.zig");

pub fn emit(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    tree: *const Ast,
    root: NodeIndex,
    module: *const Module,
    view: Using.SourceView,
    source_aliases: ?*const std.AutoHashMapUnmanaged(u32, []const u8),
    metadata: ?*const Metadata,
    linker: *const Linker,
    options: anytype,
    foreign_names: ?[]const []const u8,
) !@import("esm_wrap.zig").EsmEmitResult {
    if (!@import("../native_async_module_plan.zig").contains(linker.graph, module) or view.domain != tree)
        return error.InvalidNativeAsyncModuleOwner;
    const factory = try parent.checkedNativeAsyncModuleFactory(linker.graph, linker);
    const acquire = try parent.checkedNativeAsyncModuleAcquire(linker.graph, linker);
    const dispose = try parent.checkedNativeAsyncModuleDispose(linker.graph, linker);
    const namespace_provider = try parent.checkedNativeAsyncModuleNamespace(linker.graph, linker);
    var import_entries: std.ArrayList(Imports.Entry) = .empty;
    var import_initializers: std.ArrayList([]const u8) = .empty;
    for (module.import_bindings) |binding| {
        if (binding.callsite_target) |target| {
            // These imports carry compiler-owned init/namespace handles,
            // not a source module export named by their placeholder key.
            try @import("../runtime_callsite_targets.zig").validateTargetRole(linker.graph, target);
            continue;
        }
        if (binding.import_record_index >= module.import_records.len) return error.InvalidNativeAsyncModuleOwner;
        const target_index = module.import_records[binding.import_record_index].resolved;
        if (target_index.isNone()) continue;
        const target = linker.graph.getModule(target_index) orelse return error.InvalidNativeAsyncModuleOwner;
        // No emitted source can read a provider the actual shaker removed.
        // A new runtime import thunk must not resurrect its missing init handle.
        if (linker.tree_shaker_active and !target.is_included) continue;
        if (!@import("../native_async_module_plan.zig").contains(linker.graph, target)) {
            if (target == factory.module) continue;
            if (linker.graph.interop_ast_provider) |provider| {
                if (provider.module_index == target_index) {
                    _ = try @import("../runtime_interop_ast.zig").outputNames(linker.graph, &linker.rename_table);
                    continue;
                }
            }
            if (linker.graph.dynamic_import_ast_provider) |provider| {
                if (provider.module_index == target_index) {
                    _ = try @import("../runtime_dynamic_import_ast.zig").exactBinding(linker.graph);
                    if (!provider.active) return error.InvalidDynamicImportProvider;
                    continue;
                }
            }
            return error.InvalidNativeAsyncModuleDependency;
        }
        const local = try module.checkedImportBindingSourceSymbol(binding);
        const sid = local.semanticIndex() orelse return error.InvalidNativeAsyncModuleOwner;
        try import_initializers.append(arena, try target.allocInitName(arena, &linker.rename_table));
        try import_entries.append(arena, .{
            .binding = binding.source_local_symbol_node orelse return error.InvalidNativeAsyncModuleOwner,
            .symbol = sid,
            .namespace_name = try target.allocExportsName(arena, &linker.rename_table),
            .property = if (binding.kind == .namespace) null else binding.imported_name,
        });
    }
    var reservations: std.ArrayList([]const u8) = .empty;
    if (foreign_names) |names| try reservations.appendSlice(arena, names);
    for (view.symbols) |symbol| {
        try reservations.append(arena, if (symbol.synthetic_name.len > 0) symbol.synthetic_name else tree.getText(symbol.name));
        if (symbol.output_name_hint.len > 0) try reservations.append(arena, symbol.output_name_hint);
    }
    for (tree.nodes.items) |source_node| switch (source_node.tag) {
        .identifier_reference, .binding_identifier, .assignment_target_identifier => try reservations.append(arena, tree.identifierNameText(source_node)),
        else => {},
    };
    if (metadata) |md| {
        var names = md.renames.valueIterator();
        while (names.next()) |name| try reservations.append(arena, name.*);
    }
    var linked_names = linker.rename_table.map.valueIterator();
    while (linked_names.next()) |name| try reservations.append(arena, name.*);
    if (options.native_module_publication) |plan| {
        try reservations.append(arena, plan.artifact.ready.name);
        for (plan.artifact.cells) |cell| try reservations.append(arena, cell.name);
    }
    const wrapper = try Wrapper.create(allocator, reservations.items);
    defer wrapper.destroy();
    const environment = try wrapper.environmentLocal();
    const bindings_name = try std.fmt.allocPrint(arena, "{s}[4]", .{environment.final_name});
    for (import_entries.items, 0..) |*entry, ordinal| {
        if (entry.property != null)
            entry.binding_reader = try std.fmt.allocPrint(arena, "{s}[3][{d}]", .{ environment.final_name, ordinal });
    }
    const imports = try Imports.Context.create(arena, tree, root, view, import_entries.items);
    var source_metadata: ?Metadata = if (metadata) |value| value.* else null;
    if (source_metadata) |*value| {
        // Cross-module canonical locals live inside separate generator lexical
        // environments. Actual imports use their installed namespace getters.
        value.ns_member_rewrites = .{};
        value.ns_inline_objects = .{};
        value.export_getter_overrides = try value.export_getter_overrides.clone(arena);
        for (module.export_bindings) |binding| {
            const sid = module.exportBindingSemanticIndex(binding) orelse continue;
            if (try imports.readExpressionForSymbol(arena, sid)) |expression|
                try value.export_getter_overrides.put(arena, module.exportBindingLocalName(binding), expression);
        }
    }
    const source_metadata_ptr: ?*const Metadata = if (source_metadata) |*value| value else null;

    const using = try Using.Context.create(arena, tree, root, view, wrapper);
    const storage_entries: []const Storage.Entry = if (options.native_module_publication) |plan| try plan.storageEntries(arena, module, view) else &.{};
    const storage: ?Storage.Context = if (storage_entries.len != 0) try Storage.Context.create(arena, tree, root, view, wrapper, storage_entries) else null;

    const namespace = try module.allocExportsName(arena, &linker.rename_table);
    const initializer = try module.allocInitName(arena, &linker.rename_table);

    var codegen = Codegen.initWithOptions(arena, tree, .{
        .compiler_literal_overrides = options.compiler_literal_overrides,
        .module_format = .cjs,
        .skip_cjs_exports = true,
        .module_await_as_yield = true,
        .native_module_import_meta = true,
        .native_module_using = &using,
        .native_module_import_projection = &imports,
        .native_module_storage_projection = if (storage) |*context| context else null,
        .minify_whitespace = options.minify_whitespace,
        .minify_syntax = options.minify_syntax,
        .sourcemap = options.sourcemap.enable,
        .source_root = options.sourcemap.source_root orelse "",
        .sources_content = options.sourcemap.sources_content,
        .linking_metadata = source_metadata_ptr,
        .semantic_symbol_ids = view.symbol_ids,
        .semantic_symbols = view.symbols,
        .source_binding_aliases = source_aliases,
        .semantic_scope_maps = if (module.semantic) |sem| sem.scope_maps else &.{},
        .generated_iife_scope_owner_map = view.scope_owner_map,
        .require_generated_iife_symbols = true,
        .namespace_declaration_owners = if (module.semantic) |*sem| &sem.namespace_declaration_owners else null,
        .keep_names = options.keep_names,
        .platform = options.platform,
        .import_records = module.import_records,
        .require_context_module_id_root = options.root_dir,
    });
    defer codegen.deinit();
    if (options.sourcemap.enable) {
        codegen.line_offsets = module.line_offsets;
        try codegen.addSourceFile(parent.sourcemapSourcePath(module.path, options));
    }
    var body: std.ArrayList(u8) = .empty;
    try Namespace.append(&body, arena, module, linker, &codegen, &imports, namespace, namespace_provider.local_name, bindings_name);
    if (options.native_module_publication) |plan| {
        for (storage_entries) |entry| {
            const local_name = codegen.finalSymbolName(entry.symbol) orelse view.symbols[entry.symbol].nameText(tree.source);
            const local = try Namespace.identifier(arena, &codegen, local_name);
            const descriptor = try Accessor.create(allocator, reservations.items);
            defer descriptor.destroy();
            const value = try descriptor.setterValueLocal();
            const getter = try std.fmt.allocPrint(arena, "return {s};", .{local});
            const setter = try plan.setterBody(arena, module, entry.symbol, local, value.final_name);
            const expression = try descriptor.emitDescriptor(arena, getter, setter, options.minify_whitespace);
            try body.appendSlice(arena, try linker.esmInteropRuntimeHelperName(.def_prop));
            try body.append(arena, '(');
            try body.appendSlice(arena, environment.final_name);
            try body.appendSlice(arena, "[2],");
            const slot = try std.fmt.allocPrint(arena, "{d}", .{entry.slot});
            try body.appendSlice(arena, slot);
            try body.append(arena, ',');
            try body.appendSlice(arena, expression);
            try body.appendSlice(arena, ");\n");
        }
    }
    try codegen.write(body.items);
    const program_node = tree.getNode(root);
    if (program_node.tag != .program) return error.InvalidNativeAsyncModuleOwner;
    const statements = tree.extra_data.items[program_node.data.list.start..][0..program_node.data.list.len];
    try codegen.emitNativeModuleInstantiationPrologue(root, statements);
    body.clearRetainingCapacity();
    try body.appendSlice(arena, "yield {namespace:");
    try body.appendSlice(arena, namespace);
    try body.appendSlice(arena, if (module.self_uses_top_level_await) ",hasTLA:true,bindings:" else ",hasTLA:false,bindings:");
    try body.appendSlice(arena, bindings_name);
    try body.appendSlice(arena, "};\n");
    try codegen.write(body.items);
    const body_code = try codegen.generateStatements(root, statements);
    var body_site: ?@import("../../codegen/compiler_statement_insertions.zig").Emission = null;
    const expression = try wrapper.emitValueTracked(arena, body_code, options.minify_whitespace, &body_site);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "var ");
    try output.appendSlice(allocator, namespace);
    try output.appendSlice(allocator, ";var ");
    try output.appendSlice(allocator, initializer);
    try output.appendSlice(allocator, "=");
    try output.appendSlice(allocator, factory.local_name);
    try output.appendSlice(allocator, "(");
    const expression_line: u32 = @intCast(std.mem.count(u8, output.items, "\n"));
    const expression_column = @import("../../codegen/writer.zig").trailingColumn(output.items);
    try output.appendSlice(allocator, expression);
    try output.appendSlice(allocator, ",function(){return[");
    var first = true;
    const eager = try classifyEagerDependencies(arena, module);
    var emitted_dependencies: std.AutoHashMapUnmanaged(@import("../types.zig").ModuleIndex, void) = .empty;
    for (module.dependencies.items) |index| {
        if (index == factory.module.index) continue;
        if (!eager.admits(index)) continue;
        const emitted = try emitted_dependencies.getOrPut(arena, index);
        if (emitted.found_existing) continue;
        const dependency = linker.graph.getModule(index) orelse return error.InvalidNativeAsyncModuleOwner;
        if (dependency.is_external or dependency.is_disabled or (linker.tree_shaker_active and !dependency.is_included)) continue;
        // This actual graph-owned provider is emitted in the preamble, not
        // evaluated as a source module. Its typed bindings were validated by
        // prepareEsmInteropRuntimeNamesForEmit before any emitter worker.
        if (linker.graph.interop_ast_provider) |provider| {
            if (provider.module_index == index) {
                _ = try @import("../runtime_interop_ast.zig").outputNames(linker.graph, &linker.rename_table);
                continue;
            }
        }
        if (linker.graph.dynamic_import_ast_provider) |provider| {
            if (provider.module_index == index) {
                _ = try @import("../runtime_dynamic_import_ast.zig").exactBinding(linker.graph);
                if (!provider.active) return error.InvalidDynamicImportProvider;
                continue;
            }
        }
        if (!@import("../native_async_module_plan.zig").contains(linker.graph, dependency)) return error.InvalidNativeAsyncModuleDependency;
        if (!first) try output.append(allocator, ',');
        first = false;
        try output.appendSlice(allocator, try dependency.allocInitName(arena, &linker.rename_table));
    }
    try output.appendSlice(allocator, "]},[");
    try output.appendSlice(allocator, acquire.local_name);
    try output.append(allocator, ',');
    try output.appendSlice(allocator, dispose.local_name);
    try output.appendSlice(allocator, ",{},[]],function(){return[");
    for (import_entries.items, import_initializers.items, 0..) |entry, init_name, ordinal| {
        if (ordinal != 0) try output.append(allocator, ',');
        try output.append(allocator, '[');
        try output.appendSlice(allocator, init_name);
        try output.append(allocator, ',');
        if (entry.property) |key| {
            const quoted = try std.json.Stringify.valueAlloc(arena, try Namespace.keyValue(arena, key), .{});
            try output.appendSlice(allocator, quoted);
        } else try output.appendSlice(allocator, "null");
        try output.append(allocator, ']');
    }
    try output.appendSlice(allocator, "]});\n");
    var mappings: ?[]@import("../../codegen/sourcemap.zig").Mapping = null;
    var names: []const []const u8 = &.{};
    errdefer {
        if (mappings) |items| allocator.free(items);
        for (names) |name| allocator.free(name);
        if (names.len != 0) allocator.free(names);
    }
    if (codegen.sm_builder) |*sm| {
        const site = body_site orelse return error.InvalidNativeAsyncModuleOwner;
        const body_line = expression_line + site.line;
        const body_column = site.column + (if (site.line == 0) expression_column else @as(u32, 0));
        if (sm.mappings.items.len != 0) {
            const copied = try allocator.dupe(@import("../../codegen/sourcemap.zig").Mapping, sm.mappings.items);
            mappings = copied;
            for (copied) |*mapping| {
                if (mapping.generated_line == 0) mapping.generated_column += body_column;
                mapping.generated_line += body_line;
            }
        }
        if (sm.names.items.len != 0) {
            const copied = try allocator.alloc([]const u8, sm.names.items.len);
            var completed: usize = 0;
            errdefer {
                for (copied[0..completed]) |name| allocator.free(name);
                allocator.free(copied);
            }
            for (sm.names.items, 0..) |name, i| {
                copied[i] = try allocator.dupe(u8, name);
                completed += 1;
            }
            names = copied;
        }
    }
    return .{ .code = try output.toOwnedSlice(allocator), .mappings = mappings, .names = names };
}

// A lowered dynamic import installs real compiler imports for its exact init
// and namespace handles. Those edges keep code reachable; they must not turn
// the original lazy request into an eager evaluation dependency.
const EagerDependencies = struct {
    source: std.AutoHashMapUnmanaged(@import("../types.zig").ModuleIndex, void) = .empty,
    compiler: std.AutoHashMapUnmanaged(@import("../types.zig").ModuleIndex, void) = .empty,
    fn admits(self: EagerDependencies, target: @import("../types.zig").ModuleIndex) bool {
        return self.source.contains(target) or !self.compiler.contains(target);
    }
};
fn classifyEagerDependencies(a: std.mem.Allocator, module: *const Module) !EagerDependencies {
    var result: EagerDependencies = .{};
    const roles = try a.alloc(u2, module.import_records.len);
    @memset(roles, 0);
    for (module.import_bindings) |binding| {
        if (binding.import_record_index >= roles.len) return error.InvalidNativeAsyncModuleDependency;
        roles[binding.import_record_index] |= if (binding.callsite_target != null) @as(u2, 2) else @as(u2, 1);
    }
    for (module.import_records, 0..) |record, ri| {
        if (record.resolved.isNone() or !record.kind.isEagerEvalDependency()) continue;
        if (roles[ri] == 2) {
            try result.compiler.put(a, record.resolved, {});
        } else {
            try result.source.put(a, record.resolved, {});
        }
    }
    return result;
}
