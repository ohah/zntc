//! Actual instantiation-time name restoration for legacy scope-hoisted defaults.
const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const Module = @import("../module.zig").Module;
const Graph = @import("../graph.zig").ModuleGraph;
const Builder = @import("../runtime_callsite_builder.zig").Builder;

pub const Receipt = struct {
    module: *const Module,
    owner: @import("../codegen_output_domain.zig").Owner,
    index: @import("../types.zig").ModuleIndex,
    source: NodeIndex,
    function: NodeIndex,
    symbol: SymbolId,
    scope: ScopeId,
    statement: NodeIndex,
    call: NodeIndex,
    value: NodeIndex,
    helper: NodeIndex,
    helper_local: SymbolId,
};

pub fn hasDemand(module: *const Module) bool {
    const tree = if (module.ast) |*value| value else return false;
    for (module.export_bindings) |binding| {
        if (binding.kind != .local or !binding.has_default_export_facade) continue;
        const source = binding.default_export_node orelse continue;
        if (source.isNone() or @backingInt(source) >= tree.nodes.items.len) continue;
        const node = tree.getNode(source);
        if (node.tag != .export_default_declaration) continue;
        const function = node.data.unary.operand;
        if (function.isNone() or @backingInt(function) >= tree.nodes.items.len) continue;
        const body = tree.getNode(function);
        if (body.tag == .function_declaration and tree.readExtraNode(body.data.extra, ast_mod.FunctionExtra.name).isNone()) return true;
    }
    return false;
}

pub fn graphDemand(graph: anytype) bool {
    if (!graph.transform_options_base.unsupported.block_scoping or graph.dev_mode or graph.preserve_modules or graph.code_splitting) return false;
    var modules = graph.modulesIterator();
    while (modules.next()) |module| {
        if (module.wrap_kind == .none and hasDemand(module)) return true;
    }
    return false;
}

pub fn lower(graph: *Graph) !bool {
    // File-boundary and factory-owned instantiation have separate producers.
    // Do not move a source-local reference out of those physical environments.
    if (graph.dev_mode or graph.preserve_modules or graph.code_splitting or graph.legacy_name_builtin == null) return false;
    const target = try @import("../lexical_initialization_builtin.zig").exactNames(graph);
    const known = graph.legacy_name_builtin.?;
    const provider = graph.getModule(known.module_index) orelse return error.InvalidDefaultNameProducer;
    const public = provider.export_bindings[known.export_index];
    var changed = false;
    for (0..graph.moduleCount()) |index| {
        const module = graph.moduleAtMut(@import("../types.zig").ModuleIndex.fromUsize(index)) orelse continue;
        if (module.wrap_kind != .none or !hasDemand(module)) continue;
        if (module.legacy_default_names.len != 0) {
            try validate(graph, module);
            continue;
        }
        const tree = &module.ast.?;
        const sem = if (module.semantic) |*value| value else return error.InvalidDefaultNameProducer;
        const root = tree.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
        const raw_scope = sem.scope_owner_map.get(@backingInt(root)) orelse return error.InvalidDefaultNameProducer;
        if (raw_scope >= sem.scopes.len or !sem.scopes[raw_scope].parent.isNone() or
            (sem.scopes[raw_scope].kind != .global and sem.scopes[raw_scope].kind != .module)) return error.InvalidDefaultNameProducer;
        const scope: ScopeId = @fromBackingInt(raw_scope);
        const a = module.parse_arena.?.allocator();
        var editor = try sem.beginEdit(a, tree);
        defer editor.deinit();
        var builder: Builder = .{ .allocator = a, .ast = tree, .editor = &editor, .module = module, .graph = graph };
        const local = try builder.importedWithOwner(target, .keep_names_helper, known.owner_token, public.exported_name, true);
        var receipts: std.ArrayList(Receipt) = .empty;
        for (module.export_bindings) |binding| {
            if (binding.kind != .local or !binding.has_default_export_facade) continue;
            const source = binding.default_export_node orelse continue;
            const node = tree.getNode(source);
            if (node.tag != .export_default_declaration) continue;
            const function = node.data.unary.operand;
            const function_node = tree.getNode(function);
            if (function_node.tag != .function_declaration or !tree.readExtraNode(function_node.data.extra, ast_mod.FunctionExtra.name).isNone()) continue;
            const raw = module.exportBindingSemanticIndex(binding) orelse return error.InvalidDefaultNameProducer;
            if (@backingInt(source) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(source)] != raw or raw >= sem.symbols.items.len) return error.InvalidDefaultNameProducer;
            const symbol = sem.symbols.items[raw];
            if (symbol.scope_id != scope or symbol.kind != .variable_const or !symbol.decl_flags.is_default_export or
                !symbol.decl_flags.is_exported or symbol.lexical_initialization.state != .native) return error.InvalidDefaultNameProducer;
            const value = try builder.reference(@fromBackingInt(raw), scope);
            const helper = try builder.reference(local, scope);
            const text = try tree.addString("\"default\"");
            const literal = try tree.addNode(.{ .tag = .string_literal, .span = text, .data = .{ .string_ref = text } });
            const call = try builder.call(helper, &.{ value, literal });
            const statement = try tree.addNode(.{ .tag = .expression_statement, .span = node.span, .data = .{ .unary = .{ .operand = call, .flags = 0 } } });
            try receipts.append(a, .{ .module = module, .owner = module.codegen_output_owner, .index = module.index, .source = source, .function = function, .symbol = @fromBackingInt(raw), .scope = scope, .statement = statement, .call = call, .value = value, .helper = helper, .helper_local = local });
        }
        var statements: std.ArrayList(NodeIndex) = .empty;
        var existing = tree.iterateExtraList(tree.getNode(root).data.list);
        while (existing.next()) |statement| try statements.append(a, statement);
        try statements.appendSlice(a, builder.declarations.items);
        for (receipts.items) |receipt| try statements.append(a, receipt.statement);
        const replacement = try tree.addNode(.{ .tag = .program, .span = tree.getNode(root).span, .data = .{ .list = try tree.addNodeList(statements.items) } });
        try editor.remapScopeOwner(root, replacement);
        try @import("../strict_function_context.zig").remapProgram(&sem.strict_output_context, root, replacement);
        tree.transformed_root = replacement;
        try builder.validate();
        sem.applyEdit(try editor.finish());
        const projected = (try @import("../statement_owner_projection.zig").project(a, tree, replacement, sem)) orelse return error.InvalidDefaultNameProducer;
        sem.references = projected;
        if (module.transform_cache) |*cache| cache.symbol_ids = sem.symbol_ids;
        module.legacy_default_names = receipts.items;
        try @import("../statement_owner_projection.zig").refresh(module, null, &.{});
        try validate(graph, module);
        changed = true;
    }
    return changed;
}

pub fn validate(graph: anytype, module: *const Module) !void {
    if (module.legacy_default_names.len == 0) return;
    if (module.wrap_kind != .none or module.codegen_output_owner == .unassigned) return error.InvalidDefaultNameProducer;
    const tree = if (module.ast) |*value| value else return error.InvalidDefaultNameProducer;
    const sem = module.semantic orelse return error.InvalidDefaultNameProducer;
    const root = tree.transformed_root orelse return error.InvalidDefaultNameProducer;
    const root_scope = sem.scope_owner_map.get(@backingInt(root)) orelse return error.InvalidDefaultNameProducer;
    if (root_scope >= sem.scopes.len or !sem.scopes[root_scope].parent.isNone() or
        (sem.scopes[root_scope].kind != .global and sem.scopes[root_scope].kind != .module)) return error.InvalidDefaultNameProducer;
    const target = try @import("../lexical_initialization_builtin.zig").exactNames(graph);
    for (module.legacy_default_names) |receipt| {
        for ([_]NodeIndex{ receipt.call, receipt.value, receipt.helper }) |index| {
            if (index.isNone() or @backingInt(index) >= tree.nodes.items.len) return error.InvalidDefaultNameProducer;
        }
        if (receipt.scope.isNone() or receipt.module != module or receipt.owner != module.codegen_output_owner or receipt.index != module.index or receipt.scope.toIndex() != root_scope or @backingInt(receipt.symbol) >= sem.symbols.items.len or
            @backingInt(receipt.source) >= tree.nodes.items.len or @backingInt(receipt.function) >= tree.nodes.items.len or
            @backingInt(receipt.statement) >= tree.nodes.items.len) return error.InvalidDefaultNameProducer;
        const source = tree.getNode(receipt.source);
        const function = tree.getNode(receipt.function);
        if (function.tag != .function_declaration or !tree.hasExtra(function.data.extra, ast_mod.FunctionExtra.name)) return error.InvalidDefaultNameProducer;
        if (source.tag != .export_default_declaration or source.data.unary.operand != receipt.function or function.tag != .function_declaration or
            !tree.readExtraNode(function.data.extra, ast_mod.FunctionExtra.name).isNone() or sem.symbol_ids[@backingInt(receipt.source)] != @backingInt(receipt.symbol)) return error.InvalidDefaultNameProducer;
        const function_scope = sem.scope_owner_map.get(@backingInt(receipt.function)) orelse return error.InvalidDefaultNameProducer;
        if (function_scope >= sem.scopes.len or sem.scopes[function_scope].kind != .function or
            sem.scopes[function_scope].parent != receipt.scope) return error.InvalidDefaultNameProducer;
        const source_symbol = sem.symbols.items[@backingInt(receipt.symbol)];
        if (source_symbol.kind != .variable_const or source_symbol.scope_id != receipt.scope or source_symbol.origin_scope != receipt.scope or
            !source_symbol.decl_flags.is_exported or !source_symbol.decl_flags.is_default_export or source_symbol.lexical_initialization.state != .native or
            !std.meta.eql(source_symbol.declaration_span, source.span)) return error.InvalidDefaultNameProducer;
        var source_exports: usize = 0;
        for (module.export_bindings) |binding| {
            if (binding.default_export_node == receipt.source and binding.kind == .local and binding.has_default_export_facade and
                module.exportBindingSemanticIndex(binding) == @as(?u32, @backingInt(receipt.symbol))) source_exports += 1;
        }
        if (source_exports != 1) return error.InvalidDefaultNameProducer;
        var source_present: usize = 0;
        var present: usize = 0;
        var statements = tree.iterateExtraList(tree.getNode(root).data.list);
        while (statements.next()) |statement| {
            if (statement == receipt.statement) present += 1;
            if (statement == receipt.source) source_present += 1;
        }
        if (source_present != 1 or present != 1 or tree.getNode(receipt.statement).tag != .expression_statement or
            tree.getNode(receipt.statement).data.unary.operand != receipt.call) return error.InvalidDefaultNameProducer;
        const call = tree.getNode(receipt.call);
        if (call.tag != .call_expression or !tree.hasExtra(call.data.extra, 3) or
            tree.readExtraNode(call.data.extra, 0) != receipt.helper) return error.InvalidDefaultNameProducer;
        const args = tree.readExtra(call.data.extra, 1);
        if (args > tree.extra_data.items.len or tree.extra_data.items.len - args < 2 or
            tree.readExtra(call.data.extra, 2) != 2 or tree.readExtraNode(args, 0) != receipt.value) return error.InvalidDefaultNameProducer;
        const literal_index = tree.readExtraNode(args, 1);
        if (literal_index.isNone() or @backingInt(literal_index) >= tree.nodes.items.len) return error.InvalidDefaultNameProducer;
        const literal = tree.getNode(literal_index);
        if (literal.tag != .string_literal or !std.mem.eql(u8, tree.getText(literal.data.string_ref), "\"default\"")) return error.InvalidDefaultNameProducer;
        for ([_]struct { node: NodeIndex, sid: SymbolId }{ .{ .node = receipt.value, .sid = receipt.symbol }, .{ .node = receipt.helper, .sid = receipt.helper_local } }) |expected| {
            if (@backingInt(expected.node) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(expected.node)] != @backingInt(expected.sid)) return error.InvalidDefaultNameProducer;
            var reads: usize = 0;
            for (sem.references) |reference| if (reference.node_index == expected.node) {
                if (reference.symbol_id != expected.sid or reference.scope_id != receipt.scope or reference.flags.declare or !reference.flags.read) return error.InvalidDefaultNameProducer;
                reads += 1;
            };
            if (reads != 1) return error.InvalidDefaultNameProducer;
        }
        var imports: usize = 0;
        for (module.import_bindings) |binding| {
            const proof = binding.callsite_target orelse continue;
            if (proof.role != .keep_names_helper) continue;
            const local = try module.checkedSourceImportLocalSymbol(binding);
            if (local.semanticIndex() != @as(?u32, @backingInt(receipt.helper_local))) continue;
            try @import("../runtime_callsite_targets.zig").validateTargetRole(graph, proof);
            if (proof.symbol.module != target.module or proof.symbol.inner != target.inner) return error.InvalidDefaultNameProducer;
            imports += 1;
        }
        if (imports != 1) return error.InvalidDefaultNameProducer;
    }
}

/// Emit the already registered real calls after the actual helper constructor,
/// before any source body. No function body or lexical environment is invented.
pub fn appendPreamble(
    allocator: std.mem.Allocator,
    graph: *const Graph,
    linker: *const @import("../linker.zig").Linker,
    modules: []const *const Module,
    output: *std.ArrayList(u8),
    format: @import("../types.zig").Format,
    minify: bool,
) !void {
    _ = try @import("../lexical_initialization_builtin.zig").exactNames(graph);
    for (modules) |module| {
        if (module.legacy_default_names.len == 0) continue;
        try validate(graph, module);
        const tree = &module.ast.?;
        const sem = &module.semantic.?;
        const root = tree.transformed_root orelse return error.InvalidDefaultNameProducer;
        var metadata = try linker.buildMetadataForAst(tree, module.index.toU32(), module.is_entry_point, sem.symbol_ids, format, true);
        defer metadata.deinit();
        var statements: std.ArrayList(u32) = .empty;
        defer statements.deinit(allocator);
        for (module.legacy_default_names) |receipt| {
            metadata.skip_nodes.unset(@backingInt(receipt.statement));
            try statements.append(allocator, @backingInt(receipt.statement));
        }
        var codegen = @import("../../codegen/codegen.zig").Codegen.initWithOptions(allocator, tree, .{
            .minify_whitespace = minify,
            .linking_metadata = &metadata,
            .semantic_symbol_ids = sem.symbol_ids,
            .semantic_symbols = sem.symbols.items,
        });
        defer codegen.deinit();
        try output.appendSlice(allocator, try codegen.generateStatements(root, statements.items));
    }
}

test "legacy lexical TDZ hoisted default names retain actual helper and ten producer edges" {
    const Bundler = @import("../bundler.zig").Bundler;
    const helpers = @import("../test_helpers.zig");
    for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import{observed}from'./reader.mjs';export default function(){return 42}console.log(JSON.stringify(observed));");
        try helpers.writeFile(tmp.dir, "reader.mjs", "import value from'./entry.mjs';export const observed=[value.name,value()];");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", entry } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        const options: @import("../bundler.zig").BundleOptions = .{
            .entry_points = &.{entry},
            .platform = .node,
            .format = .esm,
            .unsupported = @import("../../transformer/transformer.zig").TransformOptions.compat.fromESTarget(.es5),
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = Graph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        const observed = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", output.output } });
        defer std.testing.allocator.free(observed.stdout);
        defer std.testing.allocator.free(observed.stderr);
        if (observed.term != .exited or observed.term.exited != 0 or !std.mem.eql(u8, native.stdout, observed.stdout))
            std.debug.print("hoisted default names minify={} native={s} actual={s} stderr={s} output={s}\n", .{ minify, native.stdout, observed.stdout, observed.stderr, output.output });
        try std.testing.expect(observed.term == .exited and observed.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, observed.stdout);
        const module = graph.moduleAtMut(graph.path_to_module.get(entry).?).?;
        try std.testing.expectEqual(@as(usize, 1), module.legacy_default_names.len);
        try validate(&graph, module);
        const original = module.legacy_default_names;
        const changed = try module.parse_arena.?.allocator().dupe(Receipt, original);
        const reader = try helpers.absPath(&tmp, "reader.mjs");
        defer std.testing.allocator.free(reader);
        const foreign = graph.getModule(graph.path_to_module.get(reader).?).?;
        for (0..10) |attack| {
            @memcpy(changed, original);
            switch (attack) {
                0 => changed[0].module = foreign,
                1 => changed[0].owner = .unassigned,
                2 => changed[0].index = .none,
                3 => changed[0].source = original[0].function,
                4 => changed[0].symbol = .none,
                5 => changed[0].helper_local = original[0].symbol,
                6 => changed[0].call = original[0].value,
                7 => changed[0].statement = original[0].source,
                8 => changed[0].function = original[0].source,
                9 => changed[0].scope = .none,
                else => unreachable,
            }
            module.legacy_default_names = changed;
            try std.testing.expectError(error.InvalidDefaultNameProducer, validate(&graph, module));
            module.legacy_default_names = original;
            try validate(&graph, module);
        }
    }
}
