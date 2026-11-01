const std = @import("std");
const Module = @import("../module.zig").Module;

fn outputCount(module: *const Module) usize {
    if (comptime @hasField(Module, "codegen_output_domain")) {
        const domain = module.codegen_output_domain orelse return 0;
        return domain.symbols.items.len;
    }
    return 0;
}

test "shared namespace output holder has a separate registered codegen identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const helpers = @import("../test_helpers.zig");
    try helpers.writeFile(tmp.dir, "entry.mjs", "import * as ns from './value.mjs';console.log(ns);");
    try helpers.writeFile(tmp.dir, "value.mjs", "export const a=3;export const b=7;");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);
    const value = try helpers.absPath(&tmp, "value.mjs");
    defer std.testing.allocator.free(value);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    var linker = @import("../linker.zig").Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    var modules = graph.modulesIterator();
    var actual: ?*const Module = null;
    while (modules.next()) |module| if (std.mem.eql(u8, module.path, value)) {
        actual = module;
    };
    const owner = actual orelse return error.MissingNamespaceOwner;
    try std.testing.expect(!linker.ns_shared_inline_cache.contains(owner.index.toU32()));
    const ordinary = try @import("../cross_chunk_export.zig").Provider.capture(&linker, owner.index.toU32(), "a", .ordinary_export);
    const before_owner = owner.semantic.?.owner_token;
    const before_scopes = owner.semantic.?.scopes;
    const before_references = owner.semantic.?.references;
    const before = owner.semantic.?.symbols.items;
    const output_before = outputCount(owner);
    const original_ids = try std.testing.allocator.dupe(?u32, owner.semantic.?.symbol_ids);
    defer std.testing.allocator.free(original_ids);
    {
        const output = @import("../codegen_output_domain.zig");
        var staging: output.Registry = .{};
        defer staging.deinit(std.testing.allocator);
        const pending = try output.Domain.createNamespace(std.testing.allocator, owner.codegen_output_owner, "pending_namespace");
        defer pending.destroy();
        var prepared = try staging.prepareNamespace(std.testing.allocator, &graph, owner, pending, "pending_namespace");
        defer prepared.deinit(std.testing.allocator);
        try std.testing.expect(prepared.isCurrent());
        const row = pending.symbols.items[0];
        pending.symbols.items[0].abi = @fromBackingInt(@intCast(999));
        try std.testing.expect(!prepared.isCurrent());
        pending.symbols.items[0] = row;
        try std.testing.expect(prepared.isCurrent());
        try std.testing.expect(owner.codegen_output_domain == null);
    }
    const name = try linker.ensureSharedNsVar(owner.index);
    const sem = &owner.semantic.?;
    // Source semantic identity/backing is not the output binding domain.
    try std.testing.expectEqual(before.len, sem.symbols.items.len);
    try std.testing.expectEqual(@intFromPtr(before.ptr), @intFromPtr(sem.symbols.items.ptr));
    try std.testing.expectEqualSlices(?u32, original_ids, sem.symbol_ids);
    try std.testing.expectEqual(output_before + 1, outputCount(owner));
    const reference = linker.sharedNamespaceOutputRef(owner.index).?;
    try std.testing.expectEqual(owner.index, reference.module);
    try std.testing.expectEqual(owner.codegen_output_owner, reference.owner);
    try std.testing.expectEqual(owner.codegen_output_domain.?.namespace_holder, reference.symbol);
    const provider = try @import("../cross_chunk_export.zig").Provider.capture(&linker, owner.index.toU32(), name, .{ .shared_namespace = reference });
    try provider.validate(&linker);
    try ordinary.validate(&linker);
    try std.testing.expectEqualStrings(name, (try provider.localName(&linker)).?);
    try std.testing.expectEqual(before_owner, sem.owner_token);
    try std.testing.expectEqual(@intFromPtr(before_scopes.ptr), @intFromPtr(sem.scopes.ptr));
    try std.testing.expectEqual(@intFromPtr(before_references.ptr), @intFromPtr(sem.references.ptr));
    const domain = owner.codegen_output_domain.?;
    const saved_symbol = domain.symbols.items[reference.symbol.toIndex()];
    const saved_owner = domain.owner;
    domain.owner = .unassigned;
    try std.testing.expectError(error.InvalidCrossChunkExport, provider.validate(&linker));
    domain.owner = saved_owner;
    domain.symbols.items[reference.symbol.toIndex()].role = @fromBackingInt(@intCast(999));
    try std.testing.expectError(error.InvalidCrossChunkExport, provider.validate(&linker));
    domain.symbols.items[reference.symbol.toIndex()] = saved_symbol;
    domain.symbols.items[reference.symbol.toIndex()].abi = @fromBackingInt(@intCast(999));
    try std.testing.expectError(error.InvalidCrossChunkExport, provider.validate(&linker));
    domain.symbols.items[reference.symbol.toIndex()] = saved_symbol;
    {
        const original_rows = domain.symbols.items;
        const foreign_rows = try std.testing.allocator.dupe(@import("../codegen_output_domain.zig").Symbol, original_rows);
        defer std.testing.allocator.free(foreign_rows);
        domain.symbols.items = foreign_rows;
        defer domain.symbols.items = original_rows;
        try std.testing.expectError(error.InvalidCrossChunkExport, provider.validate(&linker));
    }
    var foreign = reference;
    foreign.owner = .unassigned;
    try std.testing.expect(linker.sharedNamespaceEmittedName(foreign) == null);
    foreign = reference;
    foreign.symbol = .none;
    try std.testing.expect(linker.sharedNamespaceEmittedName(foreign) == null);
    const cached = linker.ns_shared_inline_cache.getPtr(owner.index.toU32()).?;
    const actual_name = cached.var_name;
    const same_bytes = try std.testing.allocator.dupe(u8, actual_name);
    defer std.testing.allocator.free(same_bytes);
    cached.var_name = same_bytes;
    try std.testing.expectError(error.InvalidCrossChunkExport, provider.validate(&linker));
    cached.var_name = actual_name;
    try provider.validate(&linker);
    const again = try linker.ensureSharedNsVar(owner.index);
    try std.testing.expectEqualStrings(name, again);
    try std.testing.expectEqual(output_before + 1, outputCount(owner));
}

test "shared namespace output identity survives actual ModuleStore relocation without source row birth" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const Graph = @import("../graph.zig").ModuleGraph;
    const Linker = @import("../linker.zig").Linker;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "import * as ns from './value.mjs';console.log(ns);");
    try helpers.writeFile(tmp.dir, "value.mjs", "export const a=3;export const b=7;");
    try helpers.writeFile(tmp.dir, "lead.mjs", "export const lead=1;");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const value = try helpers.absPath(&tmp, "value.mjs");
    defer a.free(value);
    const lead = try helpers.absPath(&tmp, "lead.mjs");
    defer a.free(lead);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var store = @import("../module_store.zig").PersistentModuleStore.init(a);
    defer store.deinit();
    var saved_ref: @import("../codegen_output_domain.zig").Ref = undefined;
    var saved_domain: *@import("../codegen_output_domain.zig").Domain = undefined;
    {
        var graph = Graph.init(a, &cache);
        defer graph.deinit();
        {
            var linker = Linker.init(a, &graph, .esm);
            defer linker.deinit();
            try graph.build(std.testing.io, &.{entry});
            try linker.link();
            const target = graph.path_to_module.get(value).?;
            _ = try linker.ensureSharedNsVar(target);
            saved_ref = linker.sharedNamespaceOutputRef(target).?;
            saved_domain = graph.getModule(target).?.codegen_output_domain.?;
        }
        for (0..graph.moduleCount()) |i| {
            const module = graph.moduleAtMut(@import("../types.zig").ModuleIndex.fromUsize(i)).?;
            if (module.parse_arena != null) store.putModule(module.path, module, module.mtime);
        }
        try std.testing.expect(store.modules.getPtr(value).?.module.codegen_output_domain == saved_domain);
        try std.testing.expect(graph.getModule(saved_ref.module).?.codegen_output_domain == null);
    }
    var graph = Graph.init(a, &cache);
    defer graph.deinit();
    var unchanged: std.StringHashMapUnmanaged(void) = .empty;
    defer unchanged.deinit(a);
    const rebuild = try graph.buildIncremental(std.testing.io, &.{ lead, entry }, &store, &unchanged);
    defer a.free(rebuild.reparsed_indices);
    const target = graph.path_to_module.get(value).?;
    const module = graph.getModule(target).?;
    try std.testing.expect(module.codegen_output_domain == saved_domain);
    try std.testing.expectEqual(saved_ref.owner, module.codegen_output_owner);
    try std.testing.expect(target != saved_ref.module);
    const source_symbols = module.semantic.?.symbols.items;
    var linker = Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    _ = try linker.ensureSharedNsVar(target);
    const relocated = linker.sharedNamespaceOutputRef(target).?;
    try std.testing.expectEqual(saved_ref.owner, relocated.owner);
    try std.testing.expectEqual(saved_ref.symbol, relocated.symbol);
    try std.testing.expectEqual(target, relocated.module);
    try std.testing.expect(linker.sharedNamespaceEmittedName(saved_ref) == null);
    try std.testing.expectEqual(@intFromPtr(source_symbols.ptr), @intFromPtr(module.semantic.?.symbols.items.ptr));
    try std.testing.expectEqual(source_symbols.len, module.semantic.?.symbols.items.len);
}

test "shared namespace output JSON carrier preserves its actual source domain" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "import * as ns from './data.json';console.log(ns.default.a);");
    try helpers.writeFile(tmp.dir, "data.json", "{\"a\":3,\"b\":7}");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const json = try helpers.absPath(&tmp, "data.json");
    defer a.free(json);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    var linker = @import("../linker.zig").Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    const target = graph.path_to_module.get(json).?;
    const module = graph.getModule(target).?;
    try std.testing.expectEqual(@import("../types.zig").ModuleType.json, module.module_type);
    try std.testing.expect(module.ast != null);
    const source = module.ast.?.source;
    const nodes = module.ast.?.nodes.items;
    const has_semantic = module.semantic != null;
    const name = try linker.ensureSharedNsVar(target);
    const reference = linker.sharedNamespaceOutputRef(target).?;
    const provider = try @import("../cross_chunk_export.zig").Provider.capture(&linker, target.toU32(), name, .{ .shared_namespace = reference });
    try provider.validate(&linker);
    try std.testing.expectEqual(has_semantic, module.semantic != null);
    try std.testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(module.ast.?.source.ptr));
    try std.testing.expectEqual(@intFromPtr(nodes.ptr), @intFromPtr(module.ast.?.nodes.items.ptr));
    try std.testing.expectEqual(nodes.len, module.ast.?.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), outputCount(module));
}

test "shared namespace output domain owned allocations clean up at every failure" {
    const output = @import("../codegen_output_domain.zig");
    const actual = Module.init(@fromBackingInt(@intCast(0)), "/actual-output-owner.mjs");
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(a: std.mem.Allocator, owner: output.Owner) !void {
            const domain = try output.Domain.createNamespace(a, owner, "owned_namespace");
            defer domain.destroy();
            try std.testing.expect(domain.validNamespace());
            try std.testing.expectEqualStrings("owned_namespace", domain.symbols.items[0].logical_name);
        }
    }.run, .{actual.codegen_output_owner});
}

test "shared namespace output whole ensure failure preserves source and retries one publication" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "value.mjs", "export const a=3;export const b=7;");
    const value = try helpers.absPath(&tmp, "value.mjs");
    defer a.free(value);
    var failures: usize = 0;
    var reached_success = false;
    for (0..128) |offset| {
        var failing = std.testing.FailingAllocator.init(a, .{});
        const alloc = failing.allocator();
        var cache = @import("../resolve_cache.zig").ResolveCache.init(alloc, .{});
        defer cache.deinit();
        var graph = @import("../graph.zig").ModuleGraph.init(alloc, &cache);
        defer graph.deinit();
        try graph.build(std.testing.io, &.{value});
        var linker = @import("../linker.zig").Linker.init(alloc, &graph, .esm);
        defer linker.deinit();
        try linker.link();
        const target = graph.path_to_module.get(value).?;
        const module = graph.getModule(target).?;
        const before_symbols = module.semantic.?.symbols.items;
        const before_ids = module.semantic.?.symbol_ids;
        const original_ids = try a.dupe(?u32, before_ids);
        defer a.free(original_ids);
        const before_owner = module.semantic.?.owner_token;
        try std.testing.expect(module.codegen_output_domain == null);
        failing.fail_index = failing.alloc_index + offset;
        const result = linker.ensureSharedNsVar(target);
        failing.fail_index = std.math.maxInt(usize);
        if (result) |_| {
            if (!failing.has_induced_failure) reached_success = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try std.testing.expect(module.codegen_output_domain == null);
            try std.testing.expectEqual(@as(usize, 0), linker.ns_shared_inline_cache.count());
            try std.testing.expectEqual(@as(usize, 0), linker.ns_shared_inline_order.items.len);
            try std.testing.expectEqual(@as(usize, 0), linker.ns_shared_var_names.count());
            _ = try linker.ensureSharedNsVar(target);
        }
        try std.testing.expectEqual(before_owner, module.semantic.?.owner_token);
        try std.testing.expectEqual(@intFromPtr(before_symbols.ptr), @intFromPtr(module.semantic.?.symbols.items.ptr));
        try std.testing.expectEqual(before_symbols.len, module.semantic.?.symbols.items.len);
        try std.testing.expectEqual(@intFromPtr(before_ids.ptr), @intFromPtr(module.semantic.?.symbol_ids.ptr));
        try std.testing.expectEqualSlices(?u32, original_ids, module.semantic.?.symbol_ids);
        try std.testing.expectEqual(@as(usize, 1), outputCount(module));
        try std.testing.expectEqual(@as(usize, 1), linker.ns_shared_inline_cache.count());
        try std.testing.expect(linker.sharedNamespaceOutputRef(target) != null);
        if (reached_success) break;
    }
    try std.testing.expect(reached_success and failures > 0);
    std.debug.print("namespace output whole ensure actual OOM failures={d} retry=one-publication source-rows=unchanged\n", .{failures});
}

test "shared namespace output birth preserves actual registered CJS runtime source receipt" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const runtime = @import("../../semantic/output_runtime_witness.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "import * as ns from './value.cjs';console.log(ns.a,ns.b);");
    try helpers.writeFile(tmp.dir, "value.cjs", "exports.a=3;exports.b=7;");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const value = try helpers.absPath(&tmp, "value.cjs");
    defer a.free(value);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    var linker = @import("../linker.zig").Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    const module = graph.getModule(graph.path_to_module.get(value).?).?;
    try std.testing.expectEqual(@import("../types.zig").WrapKind.cjs, module.wrap_kind);
    var source = (try runtime.capture(a, &graph, module)) orelse return error.MissingActualRuntimeSourceReceipt;
    defer source.deinit(a);
    try std.testing.expect(source.wrapper != null and source.entries.len >= 3);
    try std.testing.expect(source.validateTarget(module));
    const before_epoch = graph.output_runtime_registry.epoch;
    const before_registration = graph.output_runtime_registry.lookup(module).?;
    const before_owner = module.semantic.?.owner_token;
    const before_scopes = module.semantic.?.scopes;
    _ = try linker.ensureSharedNsVar(module.index);
    try std.testing.expect(linker.sharedNamespaceOutputRef(module.index) != null);
    try std.testing.expect(source.validateTarget(module));
    const target: runtime.Target = .{ .source = &source, .module = module };
    try std.testing.expect(target.validates(&module.ast.?, module.semantic.?.symbols.items, module.semantic.?.symbol_ids));
    try std.testing.expectEqual(before_epoch, graph.output_runtime_registry.epoch);
    try std.testing.expect(std.meta.eql(before_registration, graph.output_runtime_registry.lookup(module).?));
    try std.testing.expectEqual(before_owner, module.semantic.?.owner_token);
    try std.testing.expectEqual(@intFromPtr(before_scopes.ptr), @intFromPtr(module.semantic.?.scopes.ptr));
    try std.testing.expectEqual(before_scopes.len, module.semantic.?.scopes.len);
}

test "shared namespace output cache restores actual metadata declaration to the same registered owner" {
    const a = std.testing.allocator;
    const helpers = @import("../test_helpers.zig");
    const Linker = @import("../linker.zig").Linker;
    const Decl = @import("../compiled_module.zig").CompiledModule.SharedNsDecl;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "import * as ns from './value.mjs';console.log(Reflect.get(ns,'a'),Reflect.get(ns,'b'));");
    try helpers.writeFile(tmp.dir, "value.mjs", "export const a=3;export const b=7;");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const value = try helpers.absPath(&tmp, "value.mjs");
    defer a.free(value);
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(a, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    const importer = graph.getModule(graph.path_to_module.get(entry).?).?;
    const target = graph.getModule(graph.path_to_module.get(value).?).?;
    try std.testing.expectEqual(@as(usize, 1), importer.import_bindings.len);
    const binding = importer.import_bindings[0];
    try std.testing.expectEqual(@import("../binding_scanner.zig").ImportBinding.Kind.namespace, binding.kind);
    // The scanner carrier can still be an AliasTable ID at this phase.
    // Resolve only the producer's actual node/physical semantic map.
    const source_semantic = &importer.semantic.?;
    const source_local = @import("../binding_scanner.zig").resolveImportLocalSymbol(binding, .{
        .module_index = importer.index,
        .ast = &importer.ast.?,
        .symbol_ids = source_semantic.symbol_ids,
        .symbols = source_semantic.symbols.items,
    });
    const source_sid = source_local.semanticIndex() orelse return error.MissingActualImportSourceSID;
    try std.testing.expectEqual(source_sid, source_semantic.symbol_ids[@backingInt(binding.local_symbol_node.?)].?);
    const record = importer.import_records[binding.import_record_index];
    try std.testing.expectEqual(target.index, record.resolved);
    var decls: []const Decl = &.{};
    defer {
        for (decls) |decl| {
            a.free(decl.target_path);
            a.free(decl.var_name);
            a.free(decl.object_literal);
        }
        a.free(decls);
    }
    var original: @import("../codegen_output_domain.zig").Ref = undefined;
    {
        var linker = Linker.init(a, &graph, .esm);
        defer linker.deinit();
        try linker.link();
        try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
        linker.use_shared_ns_preamble = true;
        var metadata = try linker.buildMetadataForAst(&importer.ast.?, importer.index.toU32(), true, null, .esm, true);
        defer metadata.deinit();
        try std.testing.expectEqual(@as(usize, 1), metadata.ns_inline_objects.entries.len);
        try std.testing.expectEqual(target.index.toU32(), metadata.ns_inline_objects.entries[0].shared_target_mod_idx.?);
        decls = try linker.collectSharedNamespaceDecls(a, &metadata);
        try std.testing.expectEqual(@as(usize, 1), decls.len);
        try std.testing.expectEqualStrings(target.path, decls[0].target_path);
        original = linker.sharedNamespaceOutputRef(record.resolved).?;
    }
    const source_owner = target.semantic.?.owner_token;
    const source_ids = target.semantic.?.symbol_ids;
    var restored = Linker.init(a, &graph, .esm);
    defer restored.deinit();
    try restored.link();
    try restored.restoreSharedNamespaceDecls(decls);
    const reference = restored.sharedNamespaceOutputRef(record.resolved).?;
    try std.testing.expect(std.meta.eql(original, reference));
    const provider = try @import("../cross_chunk_export.zig").Provider.capture(&restored, target.index.toU32(), decls[0].var_name, .{ .shared_namespace = reference });
    try provider.validate(&restored);
    try std.testing.expectEqualStrings(decls[0].var_name, (try provider.localName(&restored)).?);
    try std.testing.expectEqual(source_owner, target.semantic.?.owner_token);
    try std.testing.expectEqual(@intFromPtr(source_ids.ptr), @intFromPtr(target.semantic.?.symbol_ids.ptr));
    var foreign = reference;
    foreign.module = importer.index;
    try std.testing.expect(restored.sharedNamespaceEmittedName(foreign) == null);
}
