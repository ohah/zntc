//! PM namespace projection is an actual source-scope foreign import use.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Builder = @import("runtime_callsite_builder.zig").Builder;
const SymbolID = @import("symbol.zig").SymbolID;

pub fn lower(graph: *@import("graph.zig").ModuleGraph, format: @import("types.zig").Format) !void {
    if (!graph.preserve_modules or format != .cjs) return;
    const helper = graph.tla_readiness_all orelse return;
    const target_symbol = SymbolID.make(helper.module_index, @backingInt(helper.symbol_id));
    for (0..graph.moduleCount()) |index| {
        const module = graph.moduleAtMut(@import("types.zig").ModuleIndex.fromUsize(index)) orelse continue;
        if (module.index == helper.module_index) continue;
        const ast = if (module.ast) |*value| value else continue;
        const sem = if (module.semantic) |*value| value else continue;
        const a = module.parse_arena.?.allocator();
        var selected: std.AutoHashMapUnmanaged(NodeIndex, usize) = .empty;
        for (module.import_records, 0..) |record, ri| {
            if (record.kind != .dynamic_import or record.resolved.isNone() or record.callsite_lowered) continue;
            const target = graph.getModule(record.resolved) orelse return error.InvalidPmNamespaceCallsite;
            if (target.wrap_kind == .esm) try selected.put(a, record.call_node, ri);
        }
        if (selected.count() == 0) continue;
        const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
        var editor = try sem.beginEdit(a, ast);
        defer editor.deinit();
        var builder: Builder = .{ .allocator = a, .ast = ast, .editor = &editor, .module = module, .graph = graph };
        const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(a, ast);
        var changed = false;
        for (live) |raw| {
            const node: NodeIndex = @fromBackingInt(raw);
            const original = ast.getNode(node);
            if (original.tag != .import_expression) continue;
            const provenance = editor.node_scope_provenance.get(node) orelse return error.InvalidPmNamespaceCallsite;
            const record_index = selected.get(provenance.source_node) orelse continue;
            if (provenance.with_environment or !original.data.binary.right.isNone()) continue;
            const record = module.import_records[record_index];
            const target = graph.getModule(record.resolved) orelse return error.InvalidPmNamespaceCallsite;
            const helper_module = graph.getModule(helper.module_index) orelse return error.InvalidPmNamespaceCallsite;
            if (helper.export_index >= helper_module.export_bindings.len) return error.InvalidPmNamespaceCallsite;
            const helper_export = helper_module.export_bindings[helper.export_index];
            if (helper_module.exportBindingSemanticIndex(helper_export) != @as(?u32, @backingInt(helper.symbol_id))) return error.InvalidPmNamespaceCallsite;
            const helper_local = try builder.importedWithOwner(target_symbol, .readiness_all, helper.owner_token, helper_export.exported_name, true);
            const helper_read = try builder.reference(helper_local, provenance.scope);
            const key_span = try ast.addString("importNamespace");
            const key = try ast.addNode(.{ .tag = .identifier_reference, .span = key_span, .data = .{ .string_ref = key_span } });
            const callee = try ast.addExtraNode(.static_member_expression, original.span, try ast.addExtras(&.{ @backingInt(helper_read), @backingInt(key), 0 }));
            const path = try stringLiteral(ast, "");
            const init_identity = try target.esmInitSymbol();
            const namespace_identity = try target.esmNamespaceSymbol();
            const init = try stringLiteral(ast, "");
            const namespace = try stringLiteral(ast, "");
            const boolean_span = try ast.addString(if (target.in_async_cone) "true" else "false");
            const asynchronous = try ast.addNode(.{ .tag = .boolean_literal, .span = boolean_span, .data = .{ .none = @intFromBool(target.in_async_cone) } });
            const replacement = try builder.call(callee, &.{ path, init, namespace, asynchronous });
            ast.nodes.items[raw] = ast.getNode(replacement);
            const local = editor.symbol_ids.items[@backingInt(helper_read)] orelse return error.InvalidPmNamespaceCallsite;
            module.import_records[record_index].pm_namespace_projection = .{ .path_node = path, .init_node = init, .namespace_node = namespace, .asynchronous_node = asynchronous, .target_owner = target.semantic.?.owner_token, .target_init = init_identity.inner, .target_namespace = namespace_identity.inner, .helper_read = helper_read, .call_node = node, .helper_local = @fromBackingInt(local), .scope = provenance.scope, .helper_owner = helper.owner_token };
            module.import_records[record_index].callsite_lowered = true;
            changed = true;
        }
        if (!changed) continue;
        var statements: std.ArrayList(NodeIndex) = .empty;
        var iterator = ast.iterateExtraList(ast.getNode(root).data.list);
        while (iterator.next()) |statement| try statements.append(a, statement);
        try statements.appendSlice(a, builder.declarations.items);
        const next_root = try ast.addNode(.{ .tag = .program, .span = ast.getNode(root).span, .data = .{ .list = try ast.addNodeList(statements.items) } });
        try editor.remapScopeOwner(root, next_root);
        ast.transformed_root = next_root;
        try builder.validate();
        sem.applyEdit(try editor.finish());
        if (module.transform_cache) |*cache| cache.symbol_ids = sem.symbol_ids;
    }
}

fn stringLiteral(ast: *ast_mod.Ast, text: []const u8) !NodeIndex {
    const span = try ast.addString(try std.json.Stringify.valueAlloc(ast.allocator, text, .{}));
    return ast.addNode(.{ .tag = .string_literal, .span = span, .data = .{ .string_ref = span } });
}

pub fn validate(graph: *const @import("graph.zig").ModuleGraph, module: *const @import("module.zig").Module, record: @import("types.zig").ImportRecord) !void {
    const proof = record.pm_namespace_projection orelse return error.InvalidPmNamespaceCallsite;
    const helper = graph.tla_readiness_all orelse return error.InvalidPmNamespaceCallsite;
    const target = graph.getModule(record.resolved) orelse return error.InvalidPmNamespaceCallsite;
    const ast = if (module.ast) |*value| value else return error.InvalidPmNamespaceCallsite;
    const sem = module.semantic orelse return error.InvalidPmNamespaceCallsite;
    if (record.kind != .dynamic_import or !record.callsite_lowered or proof.helper_owner != helper.owner_token or
        target.semantic == null or proof.target_owner == .unassigned or target.semantic.?.owner_token != proof.target_owner or
        (try target.esmInitSymbol()).inner != proof.target_init or (try target.esmNamespaceSymbol()).inner != proof.target_namespace or
        @backingInt(proof.call_node) >= ast.nodes.items.len or @backingInt(proof.helper_read) >= sem.symbol_ids.len or @backingInt(proof.helper_read) >= ast.nodes.items.len or
        sem.symbol_ids[@backingInt(proof.helper_read)] != @backingInt(proof.helper_local)) return error.InvalidPmNamespaceCallsite;
    const call = ast.getNode(proof.call_node);
    if (call.tag != .call_expression) return error.InvalidPmNamespaceCallsite;
    const callee = ast.getNode(ast.readExtraNode(call.data.extra, 0));
    if (callee.tag != .static_member_expression or callee.data.extra > ast.extra_data.items.len or 3 > ast.extra_data.items.len - callee.data.extra) return error.InvalidPmNamespaceCallsite;
    if (ast.readExtra(callee.data.extra, 2) != 0 or ast.readExtraNode(callee.data.extra, 0) != proof.helper_read or
        !std.mem.eql(u8, ast.identifierNameText(ast.getNode(ast.readExtraNode(callee.data.extra, 1))), "importNamespace")) return error.InvalidPmNamespaceCallsite;
    const count = ast.readExtra(call.data.extra, 2);
    const start = ast.readExtra(call.data.extra, 1);
    if (count != 4 or start > ast.extra_data.items.len or count > ast.extra_data.items.len - start) return error.InvalidPmNamespaceCallsite;
    const args = ast.extra_data.items[start..][0..count];
    if (args[0] != @backingInt(proof.path_node) or args[1] != @backingInt(proof.init_node) or args[2] != @backingInt(proof.namespace_node) or args[3] != @backingInt(proof.asynchronous_node)) return error.InvalidPmNamespaceCallsite;
    for ([_]NodeIndex{ proof.path_node, proof.init_node, proof.namespace_node }) |literal| {
        if (@backingInt(literal) >= ast.nodes.items.len or ast.getNode(literal).tag != .string_literal or
            !std.mem.eql(u8, ast.getText(ast.getNode(literal).data.string_ref), "\"\"")) return error.InvalidPmNamespaceCallsite;
    }
    const asynchronous = ast.getNode(proof.asynchronous_node);
    if (asynchronous.tag != .boolean_literal or asynchronous.data.none != @as(u32, @intFromBool(target.in_async_cone))) return error.InvalidPmNamespaceCallsite;
    var found = false;
    for (module.import_bindings) |binding| {
        const selected = binding.callsite_target orelse continue;
        if (binding.local_symbol.semanticIndex() != @as(?u32, @backingInt(proof.helper_local))) continue;
        if (selected.role != .readiness_all or selected.owner != helper.owner_token or selected.symbol.module != helper.module_index or selected.symbol.inner != helper.symbol_id) return error.InvalidPmNamespaceCallsite;
        try @import("runtime_callsite_targets.zig").validateTargetRole(graph, selected);
        found = true;
    }
    if (!found) return error.InvalidPmNamespaceCallsite;
    var read_found = false;
    for (sem.references) |reference| {
        if (reference.node_index != proof.helper_read) continue;
        if (reference.flags.declare or !reference.flags.read or reference.symbol_id != proof.helper_local or reference.scope_id != proof.scope) return error.InvalidPmNamespaceCallsite;
        read_found = true;
    }
    if (!read_found) return error.InvalidPmNamespaceCallsite;
}

test "public entry PM dynamic namespace rejects foreign source roles and static member payloads" {
    const a = std.testing.allocator;
    const helpers = @import("test_helpers.zig");
    const Bundler = @import("bundler.zig").Bundler;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "provider.mjs", "export default 42;");
    try helpers.writeFile(tmp.dir, "consumer.mjs", "export function load(require,module,Promise,__tlaReadyAll){return import('./provider.mjs').then(function(value){return [value.default,require,module,Promise,__tlaReadyAll]})}");
    const entry = try helpers.absPath(&tmp, "consumer.mjs");
    defer a.free(entry);
    const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .platform = .react_native, .rn_version_matrix = @import("../transformer/compat.zig").fromESTarget(.esnext), .entry_error_guard = false, .format = .cjs, .preserve_modules = true, .code_splitting = true };
    var cache = Bundler.initResolveCacheFromOptions(a, options);
    defer cache.deinit();
    const graph = try a.create(@import("graph.zig").ModuleGraph);
    defer a.destroy(graph);
    graph.* = @import("graph.zig").ModuleGraph.init(a, &cache);
    defer graph.deinit();
    var bundler = Bundler.initWithGraph(a, options, &cache, graph);
    defer bundler.deinit();
    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(a);
    try std.testing.expect(!result.hasErrors());
    const owner = graph.getModule(graph.path_to_module.get(entry).?).?;
    var found: usize = 0;
    for (owner.import_records) |record| {
        if (record.pm_namespace_projection == null) continue;
        found += 1;
        try validate(graph, owner, record);
        const ast = &@constCast(owner).ast.?;
        const call = ast.getNode(record.pm_namespace_projection.?.call_node);
        const callee_node = ast.readExtraNode(call.data.extra, 0);
        const callee = ast.getNode(callee_node);
        ast.nodes.items[@backingInt(callee_node)].data.extra = @intCast(ast.extra_data.items.len);
        try std.testing.expectError(error.InvalidPmNamespaceCallsite, validate(graph, owner, record));
        ast.nodes.items[@backingInt(callee_node)] = callee;
        const flags = callee.data.extra + 2;
        const original_flags = ast.extra_data.items[flags];
        ast.extra_data.items[flags] = 1;
        try std.testing.expectError(error.InvalidPmNamespaceCallsite, validate(graph, owner, record));
        ast.extra_data.items[flags] = original_flags;
        try validate(graph, owner, record);
        for (0..8) |poison| {
            var bad = record;
            const proof = &bad.pm_namespace_projection.?;
            switch (poison) {
                0 => proof.helper_owner = .unassigned,
                1 => proof.target_owner = .unassigned,
                2 => proof.path_node = proof.init_node,
                3 => proof.helper_read = proof.path_node,
                4 => proof.helper_local = .none,
                5 => proof.scope = .none,
                6 => proof.call_node = .none,
                7 => proof.target_init = proof.target_namespace,
                else => unreachable,
            }
            try std.testing.expectError(error.InvalidPmNamespaceCallsite, validate(graph, owner, bad));
        }
    }
    try std.testing.expectEqual(@as(usize, 1), found);
}
