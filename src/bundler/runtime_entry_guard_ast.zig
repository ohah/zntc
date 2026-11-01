//! Split entry error guards are ordinary initially analyzed JS.
//! The producer records the exact guard function before initial analysis.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const ModuleIndex = @import("types.zig").ModuleIndex;
const symbol = @import("symbol.zig");
const id = "\x00zntc:runtime/split-entry-guard";
const public_name = "__zntc_guarded";

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
    const previous = graph.moduleAtMut(index) orelse return error.InvalidEntryGuardProvider;
    const arena = module_mod.createParseArena(graph.allocator) orelse return error.OutOfMemory;
    errdefer module_mod.destroyParseArena(graph.allocator, arena);
    const a = arena.allocator();
    const source = @import("runtime_helpers.zig").GUARDED_RUNTIME;
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureForBundler(".mjs");
    const root = try parser.parse();
    if (parser.errors.items.len != 0) return error.InvalidEntryGuardProvider;
    // Record the structural producer anchor before semantic analysis.
    const program = parser.ast.getNode(root);
    var statements = parser.ast.iterateExtraList(program.data.list);
    const state_declaration = statements.next() orelse return error.InvalidEntryGuardProvider;
    const global_declaration = statements.next() orelse return error.InvalidEntryGuardProvider;
    if (parser.ast.getNode(state_declaration).tag != .variable_declaration or parser.ast.getNode(global_declaration).tag != .variable_declaration) return error.InvalidEntryGuardProvider;
    const declaration = statements.next() orelse return error.InvalidEntryGuardProvider;
    if (statements.next() != null or parser.ast.getNode(declaration).tag != .function_declaration) return error.InvalidEntryGuardProvider;
    const binding = parser.ast.readExtraNode(parser.ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.enable_stmt_info = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    if (analyzer.errors.items.len != 0) return error.InvalidEntryGuardProvider;
    const sid: SymbolId = @fromBackingInt(analyzer.symbol_ids.items[@backingInt(binding)] orelse return error.InvalidEntryGuardProvider);
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
    graph.entry_guard_ast_provider = .{ .module_index = index, .owner = owner, .root = root, .binding_node = binding, .binding_id = sid, .binding_scope = scope };
}

pub fn exactBinding(graph: anytype) !symbol.SymbolID {
    const p = graph.entry_guard_ast_provider orelse return error.InvalidEntryGuardProvider;
    const module = graph.getModule(p.module_index) orelse return error.InvalidEntryGuardProvider;
    const sem = module.semantic orelse return error.InvalidEntryGuardProvider;
    const ast = module.ast orelse return error.InvalidEntryGuardProvider;
    if (sem.owner_token == .unassigned or sem.owner_token != p.owner or p.binding_node.isNone() or @backingInt(p.binding_node) >= ast.nodes.items.len or @backingInt(p.binding_node) >= sem.symbol_ids.len or @backingInt(p.binding_id) >= sem.symbols.items.len) return error.InvalidEntryGuardProvider;
    if (p.root.isNone() or @backingInt(p.root) >= ast.nodes.items.len or ast.getNode(p.root).tag != .program or ast.getNode(p.binding_node).tag != .binding_identifier) return error.InvalidEntryGuardProvider;
    if (sem.scope_owner_map.get(@backingInt(p.root)) != @as(?u32, @backingInt(p.binding_scope)) or sem.symbols.items[@backingInt(p.binding_id)].kind != .function_decl) return error.InvalidEntryGuardProvider;
    if (!std.mem.eql(u8, ast.getText(ast.getNode(p.binding_node).data.string_ref), public_name)) return error.InvalidEntryGuardProvider;
    var declarations = ast.iterateExtraList(ast.getNode(p.root).data.list);
    const state_declaration = declarations.next() orelse return error.InvalidEntryGuardProvider;
    const global_declaration = declarations.next() orelse return error.InvalidEntryGuardProvider;
    if (ast.getNode(state_declaration).tag != .variable_declaration or ast.getNode(global_declaration).tag != .variable_declaration) return error.InvalidEntryGuardProvider;
    const declaration = declarations.next() orelse return error.InvalidEntryGuardProvider;
    if (declarations.next() != null or ast.getNode(declaration).tag != .function_declaration or ast.readExtraNode(ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name) != p.binding_node) return error.InvalidEntryGuardProvider;
    if (sem.symbol_ids[@backingInt(p.binding_node)] != @backingInt(p.binding_id) or sem.symbols.items[@backingInt(p.binding_id)].scope_id != p.binding_scope or p.binding_scope.isNone() or p.binding_scope.toIndex() >= sem.scopes.len) return error.InvalidEntryGuardProvider;
    if (p.binding_scope.toIndex() >= sem.scope_maps.len or sem.scope_maps[p.binding_scope.toIndex()].get(public_name) != @as(?usize, @backingInt(p.binding_id))) return error.InvalidEntryGuardProvider;
    if (module.export_bindings.len != 1 or module.export_bindings[0].local_symbol_node != p.binding_node or !module.export_bindings[0].symbol.eql(symbol.SymbolRef.makeSemantic(p.module_index, @backingInt(p.binding_id)))) return error.InvalidEntryGuardProvider;
    return symbol.SymbolID.make(p.module_index, @backingInt(p.binding_id));
}

pub fn activate(graph: anytype, shaker: ?*@import("tree_shaker.zig").TreeShaker) !void {
    const binding = try exactBinding(graph);
    const p = if (graph.entry_guard_ast_provider) |*value| value else return error.InvalidEntryGuardProvider;
    const module = graph.moduleAtMut(p.module_index) orelse return error.InvalidEntryGuardProvider;
    const a = module.parse_arena.?.allocator();
    const infos = module.prebuilt_stmt_info orelse return error.InvalidEntryGuardProvider;
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

test "split entry guard provider preserves its initial exact function identity" {
    const Bundler = @import("bundler.zig").Bundler;
    var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, .{ .entry_points = &.{} });
    defer cache.deinit();
    var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try installCandidate(&graph, std.testing.io);
    const first = graph.entry_guard_ast_provider.?;
    const target = try exactBinding(&graph);
    try std.testing.expectEqual(first.module_index, target.module);
    try std.testing.expectEqual(first.binding_id, target.inner);
    const module = graph.getModule(first.module_index).?;
    try std.testing.expect(module.wrap_kind == .none);
    try std.testing.expect(module.import_bindings.len == 0);
    try std.testing.expect(module.semantic.?.symbols.items.len > 3);
    try std.testing.expect(module.semantic.?.references.len > 10);
    // A rebuild receives fresh owner provenance, even for the same virtual path.
    try installCandidate(&graph, std.testing.io);
    const second = graph.entry_guard_ast_provider.?;
    try std.testing.expectEqual(first.module_index, second.module_index);
    try std.testing.expect(first.owner != second.owner);
    _ = try exactBinding(&graph);
}

test "split entry guard provider rejects ten malformed typed producer handles" {
    const Bundler = @import("bundler.zig").Bundler;
    for (0..10) |corruption| {
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, .{ .entry_points = &.{} });
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        try installCandidate(&graph, std.testing.io);
        const provider = &graph.entry_guard_ast_provider.?;
        const module = graph.moduleAtMut(provider.module_index).?;
        const sem = &module.semantic.?;
        const raw = @backingInt(provider.binding_id);
        switch (corruption) {
            0 => provider.owner = .unassigned,
            1 => provider.binding_node = .none,
            2 => provider.root = .none,
            3 => provider.binding_id = @fromBackingInt(@as(u32, @intCast(sem.symbols.items.len))),
            4 => provider.binding_scope = .none,
            5 => @constCast(sem.symbol_ids)[@backingInt(provider.binding_node)] = null,
            6 => sem.symbols.items[raw].kind = .variable_var,
            7 => sem.symbols.items[raw].scope_id = .none,
            8 => module.export_bindings[0].symbol = symbol.SymbolRef.makeSemantic(provider.module_index, if (raw == 0) @as(u32, 1) else @as(u32, 0)),
            9 => try sem.scope_owner_map.put(module.parse_arena.?.allocator(), @backingInt(provider.root), std.math.maxInt(u32)),
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidEntryGuardProvider, exactBinding(&graph));
    }
}
