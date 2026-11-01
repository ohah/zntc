//! Compiler-owned dynamic import scheduling is ordinary initially analyzed JS.
//! Source modules import the exact provider binding; callback scopes stay local.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ModuleIndex = @import("types.zig").ModuleIndex;
const symbol = @import("symbol.zig");
const id = "\x00zntc:runtime/dynamic-import-callsite";
const public_name = "__dynamicImport";

pub const Provider = struct {
    module_index: ModuleIndex,
    owner: @import("module.zig").SemanticOwnerToken,
    root: NodeIndex,
    binding_node: NodeIndex,
    binding_id: SymbolId,
    binding_scope: ScopeId,
    active: bool = false,
};

pub fn installCandidate(graph: anytype, io: std.Io) !void {
    const module_mod = @import("module.zig");
    const index = try graph.addModule(io, id);
    const previous = graph.moduleAtMut(index) orelse return error.InvalidDynamicImportProvider;
    const arena = module_mod.createParseArena(graph.allocator) orelse return error.OutOfMemory;
    errdefer module_mod.destroyParseArena(graph.allocator, arena);
    const a = arena.allocator();
    const source = "function __dynamicImport(callback){\"use strict\";return Promise.resolve().then(callback)}";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureForBundler(".mjs");
    const root = try parser.parse();
    if (parser.errors.items.len != 0) return error.InvalidDynamicImportProvider;
    // Record the structural producer anchor before semantic analysis.
    const program = parser.ast.getNode(root);
    var statements = parser.ast.iterateExtraList(program.data.list);
    const declaration = statements.next() orelse return error.InvalidDynamicImportProvider;
    if (statements.next() != null or parser.ast.getNode(declaration).tag != .function_declaration) return error.InvalidDynamicImportProvider;
    const binding = parser.ast.readExtraNode(parser.ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.enable_stmt_info = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    if (analyzer.errors.items.len != 0) return error.InvalidDynamicImportProvider;
    const sid: SymbolId = @fromBackingInt(analyzer.symbol_ids.items[@backingInt(binding)] orelse return error.InvalidDynamicImportProvider);
    const scope = analyzer.symbols.items[@backingInt(sid)].scope_id;
    var semantic: ModuleSemanticData = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .node_scope_provenance = analyzer.node_scope_provenance,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .namespace_member_owners = analyzer.namespace_member_owners,
        .namespace_declaration_owners = analyzer.namespace_declaration_owners,
        .exported_names = analyzer.exported_names,
        .symbol_ids = analyzer.symbol_ids.items,
        .unresolved_references = analyzer.unresolved_references,
        .references = analyzer.references.items,
        .numeric_const_texts = analyzer.numeric_const_texts,
        .helper_scope_map = analyzer.helper_scope_map,
    };
    const owner = semantic.captureOwnerToken();
    var module = module_mod.Module.init(index, previous.path);
    module.parse_arena = arena;
    module.source = source;
    module.ast = parser.ast;
    module.semantic = semantic;
    module.prebuilt_stmt_info = try @import("stmt_info.zig").buildFromSemantic(a, &parser.ast, semantic.symbols.items, semantic.scopes, semantic.symbol_ids, semantic.references, &semantic.unresolved_references, false, false);
    module.export_bindings = try a.alloc(@import("binding_scanner.zig").ExportBinding, 1);
    module.export_bindings[0] = .{ .exported_name = public_name, .local_name = public_name, .local_span = semantic.symbols.items[@backingInt(sid)].declaration_span, .local_symbol_node = binding, .kind = .local, .symbol = symbol.SymbolRef.makeSemantic(index, @backingInt(sid)), .init_is_fn_or_class = true };
    module.exported_names = try a.dupe([]const u8, &.{public_name});
    module.has_local_export = true;
    module.exports_kind = .esm;
    module.module_type = .js;
    module.loader = .javascript;
    module.side_effects = false;
    module.state = .ready;
    previous.deinit(graph.allocator);
    previous.* = module;
    graph.dynamic_import_ast_provider = .{ .module_index = index, .owner = owner, .root = root, .binding_node = binding, .binding_id = sid, .binding_scope = scope };
}

pub fn exactBinding(graph: anytype) !symbol.SymbolID {
    const p = graph.dynamic_import_ast_provider orelse return error.InvalidDynamicImportProvider;
    const module = graph.getModule(p.module_index) orelse return error.InvalidDynamicImportProvider;
    const sem = module.semantic orelse return error.InvalidDynamicImportProvider;
    const ast = module.ast orelse return error.InvalidDynamicImportProvider;
    if (sem.owner_token == .unassigned or sem.owner_token != p.owner or p.binding_node.isNone() or @backingInt(p.binding_node) >= ast.nodes.items.len or @backingInt(p.binding_node) >= sem.symbol_ids.len or @backingInt(p.binding_id) >= sem.symbols.items.len) return error.InvalidDynamicImportProvider;
    if (p.root.isNone() or @backingInt(p.root) >= ast.nodes.items.len or ast.getNode(p.root).tag != .program or ast.getNode(p.binding_node).tag != .binding_identifier) return error.InvalidDynamicImportProvider;
    if (sem.scope_owner_map.get(@backingInt(p.root)) != @as(?u32, @backingInt(p.binding_scope)) or sem.symbols.items[@backingInt(p.binding_id)].kind != .function_decl) return error.InvalidDynamicImportProvider;
    if (!std.mem.eql(u8, ast.getText(ast.getNode(p.binding_node).data.string_ref), public_name)) return error.InvalidDynamicImportProvider;
    var declarations = ast.iterateExtraList(ast.getNode(p.root).data.list);
    const declaration = declarations.next() orelse return error.InvalidDynamicImportProvider;
    if (declarations.next() != null or ast.getNode(declaration).tag != .function_declaration or ast.readExtraNode(ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name) != p.binding_node) return error.InvalidDynamicImportProvider;
    if (sem.symbol_ids[@backingInt(p.binding_node)] != @backingInt(p.binding_id) or sem.symbols.items[@backingInt(p.binding_id)].scope_id != p.binding_scope or p.binding_scope.isNone() or p.binding_scope.toIndex() >= sem.scopes.len) return error.InvalidDynamicImportProvider;
    if (p.binding_scope.toIndex() >= sem.scope_maps.len or sem.scope_maps[p.binding_scope.toIndex()].get(public_name) != @as(?usize, @backingInt(p.binding_id))) return error.InvalidDynamicImportProvider;
    if (module.export_bindings.len != 1 or module.export_bindings[0].local_symbol_node != p.binding_node or !module.export_bindings[0].symbol.eql(symbol.SymbolRef.makeSemantic(p.module_index, @backingInt(p.binding_id)))) return error.InvalidDynamicImportProvider;
    return symbol.SymbolID.make(p.module_index, @backingInt(p.binding_id));
}

pub fn activate(graph: anytype, shaker: ?*@import("tree_shaker.zig").TreeShaker) !void {
    const binding = try exactBinding(graph);
    const p = if (graph.dynamic_import_ast_provider) |*value| value else return error.InvalidDynamicImportProvider;
    const module = graph.moduleAtMut(p.module_index) orelse return error.InvalidDynamicImportProvider;
    const a = module.parse_arena.?.allocator();
    const infos = module.prebuilt_stmt_info orelse return error.InvalidDynamicImportProvider;
    const reachable = try a.create(std.DynamicBitSet);
    reachable.* = try infos.computeReachable(a, &.{@backingInt(binding.inner)});
    const replacement = if (shaker) |s| try reachable.clone(s.allocator) else null;
    module.is_included = true;
    module.reachable_stmts = reachable;
    module.symbol_to_stmt = infos.symbol_to_stmt;
    if (shaker) |s| {
        const index = p.module_index.toU32();
        s.included.set(index);
        if (s.reachable_stmts[index]) |*old| old.deinit();
        s.reachable_stmts[index] = replacement;
        module.tree_shaker_active = true;
        module.reachable_stmts = &s.reachable_stmts[index].?;
    }
    p.active = true;
}

pub fn emit(output: *std.ArrayList(u8), allocator: std.mem.Allocator, graph: anytype, linker: anytype, options: anytype) !void {
    const p = graph.dynamic_import_ast_provider orelse return;
    if (!p.active) return;
    _ = try exactBinding(graph);
    const module = graph.getModule(p.module_index) orelse return error.InvalidDynamicImportProvider;
    const ast = if (module.ast) |*value| value else return error.InvalidDynamicImportProvider;
    const sem = module.semantic orelse return error.InvalidDynamicImportProvider;
    var metadata = try linker.buildMetadataForAst(ast, p.module_index.toU32(), false, sem.symbol_ids, options.format, false);
    defer metadata.deinit();
    var codegen = @import("../codegen/codegen.zig").Codegen.initWithOptions(allocator, ast, .{
        .minify_whitespace = options.minify_whitespace,
        .module_format = .esm,
        .linking_metadata = &metadata,
        .semantic_symbol_ids = sem.symbol_ids,
        .semantic_symbols = sem.symbols.items,
        .semantic_scope_maps = sem.scope_maps,
        .generated_iife_scope_owner_map = &sem.scope_owner_map,
        .require_generated_iife_symbols = true,
    });
    defer codegen.deinit();
    const code = try codegen.generate(p.root);
    try output.appendSlice(allocator, code);
    if (code.len > 0 and code[code.len - 1] != '\n') try output.append(allocator, '\n');
}

test "dynamic provider exact anchors reject ten malformed current graph handles" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    for (0..10) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import('./dep.cjs').then(m=>console.log(m.answer));");
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        _ = try exactBinding(&graph);
        const provider = &graph.dynamic_import_ast_provider.?;
        const module = graph.moduleAtMut(provider.module_index).?;
        const sem = &module.semantic.?;
        switch (corruption) {
            0 => provider.owner = .unassigned,
            1 => sem.owner_token = .unassigned,
            2 => provider.binding_node = .none,
            3 => @constCast(sem.symbol_ids)[@backingInt(provider.binding_node)] = null,
            4 => @constCast(sem.symbol_ids)[@backingInt(provider.binding_node)] = @backingInt(provider.binding_id) + 1,
            5 => sem.symbols.items[@backingInt(provider.binding_id)].kind = .parameter,
            6 => sem.symbols.items[@backingInt(provider.binding_id)].scope_id = .none,
            7 => _ = sem.scope_owner_map.remove(@backingInt(provider.root)),
            8 => module.export_bindings[0].symbol = symbol.SymbolRef.makeSemantic(provider.module_index, @backingInt(provider.binding_id) + 1),
            9 => provider.root = provider.binding_node,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidDynamicImportProvider, exactBinding(&graph));
    }
}

test "dynamic provider literal eval allocator avoids observed identifiers" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const prefixes = [_][]const u8{
        "eval('__dynamicImport=0');",
        "console.log(eval('typeof __dynamicImport'));",
        "eval('__dynamicImport=0;__dynamicImport$1=0');",
        "eval('__dynamic\\\\u0049mport=0');",
        "eval('__dynamic'+'Import=0');",
        "eval(`__dynamic${'Import'}=0`);",
    };
    for (prefixes, 0..) |prefix, context| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = try std.fmt.allocPrint(std.testing.allocator, "{s}import('./dep.cjs').then(m=>console.log(m.answer));", .{prefix});
        defer std.testing.allocator.free(source);
        try helpers.writeFile(tmp.dir, "entry.js", source);
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.answer=42;");
        const entry = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, result.output);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var statements = parser.ast.iterateExtraList(parser.ast.getNode(root).data.list);
        var scheduler_functions: usize = 0;
        while (statements.next()) |statement| {
            const node = parser.ast.getNode(statement);
            if (node.tag != .function_declaration) continue;
            const name_node = parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
            const name = parser.ast.getText(parser.ast.getNode(name_node).data.string_ref);
            try std.testing.expect(!std.mem.eql(u8, name, public_name));
            if (context == 2) try std.testing.expect(!std.mem.eql(u8, name, "__dynamicImport$1"));
            scheduler_functions += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), scheduler_functions);
    }
}
