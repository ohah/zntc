//! Real bootstrap call ASTs own their own artifact scope, outside user factories.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const SymbolID = @import("symbol.zig").SymbolID;
const ModuleIndex = @import("types.zig").ModuleIndex;
const Module = @import("module.zig").Module;
const Semantic = @import("module.zig").ModuleSemanticData;
const Builder = @import("runtime_callsite_builder.zig").Builder;

pub const Invocation = struct {
    module_index: ModuleIndex,
    owner: @import("module.zig").SemanticOwnerToken,
    target: ModuleIndex,
    root: NodeIndex,
    call: NodeIndex,
    callee: NodeIndex,
    argument: NodeIndex,
    guard_local: SymbolId,
    init_local: SymbolId,
    guard_target: SymbolID,
    init_target: SymbolID,
};

pub fn install(graph: anytype, io: std.Io, target_index: ModuleIndex) !Invocation {
    const target = graph.getModule(target_index) orelse return error.InvalidGuardInvocation;
    if (!target.shouldGuard(true)) return error.InvalidGuardInvocation;
    const guard = try @import("runtime_entry_guard_ast.zig").exactBinding(graph);
    const init: SymbolID = if (target.wrap_kind == .esm) try target.esmInitSymbol() else blk: {
        const id = target.require_symbol orelse return error.InvalidGuardInvocation;
        break :blk SymbolID.make(target.index, @backingInt(id));
    };
    const role: @import("binding_scanner.zig").CallsiteRole = if (target.wrap_kind == .esm) .esm_init else .require;
    const path = try std.fmt.allocPrint(graph.allocator, "\x00zntc:runtime/entry-guard-bootstrap/{d}", .{target_index.toU32()});
    defer graph.allocator.free(path);
    const index = try graph.addModule(io, path);
    const previous = graph.moduleAtMut(index) orelse return error.InvalidGuardInvocation;
    const module_mod = @import("module.zig");
    const arena = module_mod.createParseArena(graph.allocator) orelse return error.OutOfMemory;
    var arena_published = false;
    errdefer if (!arena_published) module_mod.destroyParseArena(graph.allocator, arena);
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureForBundler(".mjs");
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.enable_stmt_info = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    var semantic: Semantic = .{
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
    var module = Module.init(index, previous.path);
    module.parse_arena = arena;
    module.source = "";
    module.ast = parser.ast;
    module.semantic = semantic;
    module.exports_kind = .esm;
    module.module_type = .js;
    module.loader = .javascript;
    // The real guard call can execute user code; placement controls when it runs.
    module.side_effects = true;
    module.state = .ready;
    previous.deinit(graph.allocator);
    previous.* = module;
    arena_published = true;
    const active = graph.moduleAtMut(index).?;
    const ast = &active.ast.?;
    const sem = &active.semantic.?;
    var editor = try sem.beginEdit(a, ast);
    defer editor.deinit();
    var builder: Builder = .{ .allocator = a, .module = active, .graph = graph, .ast = ast, .editor = &editor };
    const guard_local = try builder.imported(guard, .entry_guard);
    const init_local = try builder.imported(init, role);
    const scope: ScopeId = @fromBackingInt(@as(u32, 0));
    const callee = try builder.reference(guard_local, scope);
    const argument = try builder.reference(init_local, scope);
    const call = try builder.call(callee, &.{argument});
    const statement = try ast.addNode(.{ .tag = .expression_statement, .span = .EMPTY, .data = .{ .unary = .{ .operand = call, .flags = 0 } } });
    var statements: std.ArrayList(NodeIndex) = .empty;
    try statements.appendSlice(a, builder.declarations.items);
    try statements.append(a, statement);
    ast.nodes.items[@backingInt(root)].data.list = try ast.addNodeList(statements.items);
    ast.transformed_root = root;
    try builder.validate();
    sem.applyEdit(try editor.finish());
    active.prebuilt_stmt_info = try @import("stmt_info.zig").buildFromSemantic(a, ast, sem.symbols.items, sem.scopes, sem.references, &sem.unresolved_references, false, false);
    return .{ .module_index = index, .owner = owner, .target = target_index, .root = root, .call = call, .callee = callee, .argument = argument, .guard_local = guard_local, .init_local = init_local, .guard_target = guard, .init_target = init };
}

/// The entry emitter consumes only the exact artifact produced by install.
pub fn validate(graph: anytype, invocation: Invocation) !void {
    const module = graph.getModule(invocation.module_index) orelse return error.InvalidGuardInvocation;
    const ast = if (module.ast) |*value| value else return error.InvalidGuardInvocation;
    const sem = module.semantic orelse return error.InvalidGuardInvocation;
    if (invocation.owner == .unassigned or sem.owner_token != invocation.owner or
        invocation.target != invocation.init_target.module or invocation.module_index == invocation.target or
        ast.transformed_root != invocation.root or sem.scope_owner_map.get(@backingInt(invocation.root)) != @as(?u32, 0)) return error.InvalidGuardInvocation;
    const guard = try @import("runtime_entry_guard_ast.zig").exactBinding(graph);
    if (!guard.eql(invocation.guard_target)) return error.InvalidGuardInvocation;
    for ([_]NodeIndex{ invocation.root, invocation.call, invocation.callee, invocation.argument }) |node| {
        if (node.isNone() or @backingInt(node) >= ast.nodes.items.len) return error.InvalidGuardInvocation;
    }
    const root = ast.getNode(invocation.root);
    if (root.tag != .program or root.data.list.len != 3) return error.InvalidGuardInvocation;
    var statements = ast.iterateExtraList(root.data.list);
    for (module.import_bindings) |binding| {
        const statement = statements.next() orelse return error.InvalidGuardInvocation;
        const target = binding.callsite_target orelse return error.InvalidGuardInvocation;
        if (statement != target.declaration) return error.InvalidGuardInvocation;
    }
    const statement = ast.getNode(statements.next() orelse return error.InvalidGuardInvocation);
    if (statement.tag != .expression_statement or statement.data.unary.operand != invocation.call) return error.InvalidGuardInvocation;
    const call = ast.getNode(invocation.call);
    if (call.tag != .call_expression or call.data.extra + 3 >= ast.extra_data.items.len) return error.InvalidGuardInvocation;
    if (ast.readExtraNode(call.data.extra, 0) != invocation.callee or ast.readExtra(call.data.extra, 2) != 1) return error.InvalidGuardInvocation;
    const arg_start = ast.readExtra(call.data.extra, 1);
    if (arg_start >= ast.extra_data.items.len or ast.extra_data.items[arg_start] != @backingInt(invocation.argument)) return error.InvalidGuardInvocation;
    if (module.import_bindings.len != 2) return error.InvalidGuardInvocation;
    for ([_]NodeIndex{ invocation.callee, invocation.argument }, [_]SymbolId{ invocation.guard_local, invocation.init_local }, 0..) |node, sid, i| {
        if (@backingInt(node) >= sem.symbol_ids.len or sid.isNone() or @backingInt(sid) >= sem.symbols.items.len or
            sem.symbol_ids[@backingInt(node)] != @backingInt(sid) or sem.symbols.items[@backingInt(sid)].kind != .import_binding) return error.InvalidGuardInvocation;
        var found = false;
        for (sem.references) |reference| if (reference.node_index == node) {
            if (reference.symbol_id != sid or reference.scope_id.toIndex() != 0 or !reference.flags.read or reference.flags.write or reference.flags.declare) return error.InvalidGuardInvocation;
            found = true;
        };
        if (!found) return error.InvalidGuardInvocation;
        const binding = module.import_bindings[i];
        const target = binding.callsite_target orelse return error.InvalidGuardInvocation;
        const foreign = graph.getModule(target.symbol.module) orelse return error.InvalidGuardInvocation;
        if (foreign.semantic == null or target.owner == .unassigned or foreign.semantic.?.owner_token != target.owner or
            binding.local_symbol.semanticIndex() != @backingInt(sid) or !target.symbol.eql(if (i == 0) invocation.guard_target else invocation.init_target)) return error.InvalidGuardInvocation;
        try @import("runtime_callsite_targets.zig").validateTargetRole(graph, target);
    }
}

/// Bootstrap ownership determines placement, not a fabricated source import.
/// The artifact imports its target; the target never imports the artifact.
pub fn prepare(graph: anytype, io: std.Io) !void {
    const count = graph.moduleCount();
    for (0..count) |raw| {
        const candidate = graph.getModule(ModuleIndex.fromUsize(raw)) orelse continue;
        if (candidate.shouldGuard(true) and candidate.wrap_kind == .esm) {
            if (graph.entry_guard_ast_provider == null) try @import("runtime_entry_guard_ast.zig").installCandidate(graph, io);
            break;
        }
    }
    for (0..count) |raw| {
        const target = graph.getModule(ModuleIndex.fromUsize(raw)) orelse continue;
        if (!target.is_entry_point or !target.shouldGuard(true)) continue;
        if (graph.entry_guard_ast_provider == null) try @import("runtime_entry_guard_ast.zig").installCandidate(graph, io);
        const invocation = try install(graph, io, target.index);
        try graph.entry_guard_invocations.append(graph.allocator, invocation);
        // This edge belongs to the entry output's guard call. No reverse
        // bootstrap edge is added, so initializers keep their original order.
        try graph.linkDependency(target.index, invocation.guard_target.module);
    }
}

pub fn isArtifact(graph: anytype, index: ModuleIndex) bool {
    for (graph.entry_guard_invocations.items) |invocation| if (invocation.module_index == index) return true;
    return false;
}

pub fn find(graph: anytype, index: ModuleIndex) ?Invocation {
    for (graph.entry_guard_invocations.items) |invocation| if (invocation.target == index) return invocation;
    return null;
}

/// Validate the entry artifact's actual chunk assignment and provider edge.
pub fn validatePlacement(graph: anytype, chunks: anytype, invocation: Invocation) !void {
    const actual = chunks.getModuleChunk(invocation.module_index);
    if (actual.isNone() or actual != chunks.getModuleChunk(invocation.target)) return error.InvalidGuardArtifactPlacement;
    const provider_chunk = chunks.getModuleChunk(invocation.guard_target.module);
    if (provider_chunk.isNone()) return error.InvalidGuardForeignEdge;
    if (provider_chunk == actual) return;
    const imports = chunks.getChunk(actual).imports_from.get(@backingInt(provider_chunk)) orelse return error.InvalidGuardForeignEdge;
    const provider = graph.getModule(invocation.guard_target.module) orelse return error.InvalidGuardForeignEdge;
    for (imports.items) |binding| {
        if (binding.canonical_module == invocation.guard_target.module.toU32() and std.mem.eql(u8, binding.name, provider.export_bindings[0].exported_name)) return;
    }
    return error.InvalidGuardForeignEdge;
}

pub fn place(graph: anytype, chunks: anytype) !void {
    for (graph.entry_guard_invocations.items) |invocation| {
        const target_chunk = chunks.getModuleChunk(invocation.target);
        if (target_chunk.isNone()) continue;
        const previous = chunks.getModuleChunk(invocation.module_index);
        if (!previous.isNone() and previous != target_chunk) return error.InvalidGuardArtifactPlacement;
        if (previous.isNone()) {
            chunks.assignModuleToChunk(invocation.module_index, target_chunk);
            try chunks.getChunkMut(target_chunk).addModule(chunks.allocator, invocation.module_index);
        }
        const artifact = graph.moduleAtMut(invocation.module_index) orelse return error.InvalidGuardInvocation;
        artifact.is_included = true;
    }
}

test "split entry guard bootstrap uses a distinct artifact scope and exact foreign identities" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "import {value} from './dep.mjs';console.log(value);");
    try helpers.writeFile(tmp.dir, "dep.mjs", "export const value=42;");
    try helpers.writeFile(tmp.dir, "second.mjs", "export function second(){return 43;}globalThis.second=second();");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);
    const second = try helpers.absPath(&tmp, "second.mjs");
    defer std.testing.allocator.free(second);
    const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{ entry, second }, .platform = .react_native, .code_splitting = true, .entry_error_guard = true, .strict_execution_order = true };
    var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
    defer cache.deinit();
    var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
    defer bundler.deinit();
    const output = try bundler.bundle(std.testing.io);
    defer output.deinit(std.testing.allocator);
    try std.testing.expect(!output.hasErrors());
    const target_index = graph.path_to_module.get(entry).?;
    try std.testing.expectEqual(@as(usize, 2), graph.entry_guard_invocations.items.len);
    const produced = graph.entry_guard_invocations.items[0];
    try validate(&graph, produced);
    const source_module = graph.getModule(target_index).?;
    for (source_module.dependencies.items) |dependency| try std.testing.expect(dependency != produced.module_index);
    var emitted_provider = false;
    for (output.outputs.?) |file| if (std.mem.indexOf(u8, file.contents, "function __zntc_guarded(") != null) {
        emitted_provider = true;
    };
    try std.testing.expect(emitted_provider);

    try @import("runtime_entry_guard_ast.zig").installCandidate(&graph, std.testing.io);
    const invocation = try install(&graph, std.testing.io, target_index);
    try validate(&graph, invocation);
    for (0..10) |mutation| {
        var bad = invocation;
        switch (mutation) {
            0 => bad.owner = .unassigned,
            1 => bad.root = .none,
            2 => bad.call = invocation.root,
            3 => bad.callee = invocation.argument,
            4 => bad.argument = invocation.callee,
            5 => bad.guard_local = invocation.init_local,
            6 => bad.init_local = invocation.guard_local,
            7 => bad.target = invocation.module_index,
            8 => bad.guard_target = invocation.init_target,
            9 => bad.init_target = invocation.guard_target,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidGuardInvocation, validate(&graph, bad));
    }

    try std.testing.expect(invocation.module_index != target_index);
    try std.testing.expect(invocation.module_index != invocation.guard_target.module);
    const bootstrap = graph.getModule(invocation.module_index).?;
    const sem = bootstrap.semantic.?;
    const ast = bootstrap.ast.?;
    try std.testing.expect(sem.owner_token == invocation.owner and invocation.owner != .unassigned);
    try std.testing.expectEqual(@as(usize, 2), bootstrap.import_bindings.len);
    try std.testing.expectEqual(@as(usize, 4), sem.references.len);
    var reads: usize = 0;
    var declarations: usize = 0;
    for (sem.references) |reference| {
        try std.testing.expect(reference.scope_id.toIndex() == 0);
        try std.testing.expect(!reference.flags.write);
        if (reference.flags.declare) declarations += 1 else {
            try std.testing.expect(reference.flags.read);
            reads += 1;
        }
        try std.testing.expect(sem.symbols.items[@backingInt(reference.symbol_id)].kind == .import_binding);
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expectEqual(@as(usize, 2), declarations);
    try std.testing.expect(ast.getNode(invocation.call).tag == .call_expression);
    try std.testing.expect(ast.readExtraNode(ast.getNode(invocation.call).data.extra, 0) == invocation.callee);
    try std.testing.expectEqual(@as(?u32, @backingInt(invocation.guard_local)), sem.symbol_ids[@backingInt(invocation.callee)]);
    try std.testing.expectEqual(@as(?u32, @backingInt(invocation.init_local)), sem.symbol_ids[@backingInt(invocation.argument)]);
    for (bootstrap.import_bindings, 0..) |binding, i| {
        const foreign = binding.callsite_target orelse return error.MissingGuardForeignIdentity;
        try @import("runtime_callsite_targets.zig").validateTargetRole(&graph, foreign);
        try std.testing.expect(bootstrap.import_records[binding.import_record_index].callsite_lowered);
        try std.testing.expect(foreign.symbol.eql(if (i == 0) invocation.guard_target else invocation.init_target));
        try std.testing.expect(binding.symbol.eql(foreign.symbol.toRef()));
    }
}

test "split entry guard bootstrap publishes parse arena ownership before fallible edits" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "export function value(){return 42;}globalThis.value=value();");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);
    var observed_published_failure = false;
    for (0..16) |fail_index| {
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .platform = .react_native, .code_splitting = true, .entry_error_guard = true, .strict_execution_order = true };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        // This allocator remains alive through graph.deinit, including arenas
        // whose ownership transferred to the graph before an injected failure.
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const output = try bundler.bundle(std.testing.io);
        defer output.deinit(std.testing.allocator);
        try std.testing.expect(!output.hasErrors());
        const old = graph.entry_guard_invocations.items[0];
        graph.allocator = failing.allocator();
        const result = install(&graph, std.testing.io, old.target);
        graph.allocator = std.testing.allocator;
        if (result) |invocation| {
            try validate(&graph, invocation);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (graph.getModule(old.module_index)) |artifact| if (artifact.semantic) |semantic| {
                if (semantic.owner_token != old.owner) observed_published_failure = true;
            };
        }
    }
    try std.testing.expect(observed_published_failure);
}
