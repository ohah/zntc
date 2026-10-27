const std = @import("std");
const helpers = @import("../bundler/test_helpers.zig");
const bundler = @import("../bundler/bundler.zig");
const profile = @import("../profile.zig");
const File = struct { name: []const u8, source: []const u8 };
const Case = struct { name: []const u8, entry: []const u8, files: []const File };
const cases = [_]Case{
    .{ .name = "single", .entry = "import './a.mjs';console.log(globalThis.value);", .files = &.{.{ .name = "a.mjs", .source = "globalThis.order=(globalThis.order||'')+'a';globalThis.value=7;" }} },
    .{ .name = "two-ordered", .entry = "import './a.mjs';import './b.mjs';console.log(globalThis.order);", .files = &.{ .{ .name = "a.mjs", .source = "globalThis.order=(globalThis.order||'')+'a';globalThis.value=7;" }, .{ .name = "b.mjs", .source = "globalThis.order=(globalThis.order||'')+'b';" } } },
    .{ .name = "repeat-literals", .entry = "import './a.mjs';import './a.mjs';console.log(globalThis.order);", .files = &.{.{ .name = "a.mjs", .source = "globalThis.order=(globalThis.order||'')+'a';globalThis.value=7;" }} },
    .{ .name = "escaped-path", .entry = "import './\\u0061.mjs';console.log(globalThis.value);", .files = &.{.{ .name = "a.mjs", .source = "globalThis.order=(globalThis.order||'')+'a';globalThis.value=7;" }} },
    .{ .name = "interleaved", .entry = "import './a.mjs';globalThis.order+='x';import './b.mjs';console.log(globalThis.order);", .files = &.{ .{ .name = "a.mjs", .source = "globalThis.order=(globalThis.order||'')+'a';globalThis.value=7;" }, .{ .name = "b.mjs", .source = "globalThis.order=(globalThis.order||'')+'b';" } } },
    .{ .name = "global-read", .entry = "import './a.mjs';console.log(globalThis.value+2);", .files = &.{.{ .name = "a.mjs", .source = "globalThis.order=(globalThis.order||'')+'a';globalThis.value=7;" }} },
    .{ .name = "three-order", .entry = "import './a.mjs';import './b.mjs';import './c.mjs';console.log(globalThis.order);", .files = &.{ .{ .name = "a.mjs", .source = "globalThis.order=(globalThis.order||'')+'a';globalThis.value=7;" }, .{ .name = "b.mjs", .source = "globalThis.order=(globalThis.order||'')+'b';" }, .{ .name = "c.mjs", .source = "globalThis.order=(globalThis.order||'')+'c';" } } },
    .{ .name = "empty-dependency", .entry = "import './a.mjs';console.log(7);", .files = &.{.{ .name = "a.mjs", .source = "" }} },
    .{ .name = "package-sideeffects-false", .entry = "import './a.mjs';console.log(7);", .files = &.{ .{ .name = "a.mjs", .source = "globalThis.unused=1;" }, .{ .name = "package.json", .source = "{\"type\":\"module\",\"sideEffects\":false}" } } },
    .{ .name = "lowered-dependency", .entry = "import './a.mjs';console.log(globalThis.value);", .files = &.{.{ .name = "a.mjs", .source = "const box=null;globalThis.value=box?.value??7;" }} },
};
test "side effect entry graph preserves ten native entries independently of dependency fallbacks" {
    var owners: [20]bool = undefined;
    var selected: usize = 0;
    for (cases) |case| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        for (case.files) |file| try helpers.writeFile(tmp.dir, file.name, file.source);
        try helpers.writeFile(tmp.dir, "entry.mjs", case.entry);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", entry } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var b = bundler.Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es2019), .minify_identifiers = minify });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", output } });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        var cache = @import("../bundler/resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = @import("../bundler/graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.minify_identifiers = minify;
        graph.transform_options_base.unsupported = @import("compat.zig").fromESTarget(.es2019);
        try graph.build(std.testing.io, &.{entry});
        const m = graph.findModuleByPath(entry) orelse return error.MissingEntry;
        try std.testing.expectEqualStrings(entry, m.path);
        if (minify) try std.testing.expect(m.semantic != null);
        const sem = if (m.semantic) |*value| value else null;
        owners[selected] = !minify or (sem != null and sem.?.owner_token != .unassigned);
        selected += 1;
        std.debug.print("SIDE EFFECT ENTRY RED case={s} id={} refs={d} symbols={d} scopes={d} records={d} bindings={d} owner={d}\n", .{ case.name, minify, if (sem) |v| v.references.len else 0, if (sem) |v| v.symbols.items.len else 0, if (sem) |v| v.scopes.len else 0, m.import_records.len, m.import_bindings.len, if (sem) |v| @backingInt(v.owner_token) else 0 });
    };
    try std.testing.expectEqual(@as(usize, 20), selected);
    // Finish every native/runtime cell before the intended ID retention RED.
    for (owners) |retained| try std.testing.expect(retained);
}

const ast_mod = @import("../parser/ast.zig");
const module_mod = @import("../bundler/module.zig");
const Entry = @import("sideeffect_entry_graph.zig");
const Transformer = @import("transformer.zig").Transformer;
const Fixture = struct {
    t: Transformer,
    m: *module_mod.Module,
    prepared: Entry.Source,
    root: ast_mod.NodeIndex,
    fn init(a: std.mem.Allocator) !Fixture {
        return initWithText(a, "import './a.mjs';import './b.mjs';console.log(globalThis.value);");
    }
    fn initWithText(a: std.mem.Allocator, text: []const u8) !Fixture {
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, text);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        const m = try a.create(module_mod.Module);
        m.* = module_mod.Module.init(@fromBackingInt(@as(u32, 0)), "entry.mjs");
        m.ast = parser.ast;
        m.source = text;
        m.module_type = .js;
        m.exports_kind = .esm;
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &m.ast.?);
        analyzer.is_module = true;
        analyzer.enable_exact_declaration_anchors = true;
        analyzer.enable_stmt_info = true;
        try analyzer.analyze();
        m.semantic = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        const scan = try @import("../bundler/import_scanner.zig").extractImportsWithCjsDetection(a, &m.ast.?);
        m.import_records = scan.records;
        m.has_cjs_export_signal = scan.has_module_exports or scan.has_exports_dot;
        m.has_esmodule_marker = scan.has_esmodule_marker;
        const opts: @import("transformer.zig").TransformOptions = .{ .unsupported = @import("compat.zig").fromESTarget(.es2019) };
        const prepared = (try Entry.forModule(a, m, opts)) orelse return error.MissingEntrySource;
        var t = try Transformer.init(a, &m.ast.?, opts);
        const sem = &m.semantic.?;
        try t.initSymbolIds(sem.symbol_ids);
        t.symbols = sem.symbols.items;
        t.references = sem.references;
        t.scopes = sem.scopes;
        t.scope_maps = sem.scope_maps;
        t.scope_owner_map = sem.scope_owner_map;
        t.node_scope_provenance = sem.node_scope_provenance;
        t.class_self_symbol_map = sem.class_self_symbol_map;
        t.helper_scope_map = sem.helper_scope_map;
        t.unresolved_references = &m.semantic.?.unresolved_references;
        t.semantic_edit_enabled = true;
        t.entry_graph_source = Entry.activate(prepared, &t, m) orelse return error.InvalidEntryActivation;
        const root = try t.transform();
        if (try t.finishSemanticEdit()) |edit| sem.applyEdit(edit);
        m.ast = t.ast.*;
        // The real shared metadata routine, not a fabricated late snapshot.
        var cache = @import("../bundler/resolve_cache.zig").ResolveCache.init(a, .{ .platform = .node });
        var graph = @import("../bundler/graph.zig").ModuleGraph.init(a, &cache);
        try @import("../bundler/graph/transform_prepass.zig").resyncModuleGraphMetadataAfterAstMutation(&graph, m, a);
        try std.testing.expect(!try Entry.metadataRequirementSatisfied(&t, m, root));
        try std.testing.expect(try Entry.publishMetadataCompletion(&t, m, root));
        try std.testing.expect(try Entry.metadataRequirementSatisfied(&t, m, root));
        return .{ .t = t, .m = m, .prepared = prepared, .root = root };
    }
};

test "side effect entry graph rejects foreign domains and incomplete import metadata without healing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    const foreign = try Fixture.init(a);
    try std.testing.expect(Entry.requirementSatisfied(&f.t, &f.prepared));
    try std.testing.expect(try Entry.complete(&f.t, &f.m.semantic.?, f.root));
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
    const original = f.t.entry_graph_source.?;
    const before_ids = try a.dupe(?u32, f.m.semantic.?.symbol_ids);
    const before_scope = f.m.semantic.?.scopes[0];
    const before_records = try a.dupe(@import("../bundler/types.zig").ImportRecord, f.m.import_records);
    for (0..20) |mutation| {
        const saved_event = f.t.entry_graph_imports.items[0];
        const saved_record = f.m.import_records[0];
        const saved_context = f.m.context_expansion_deps;
        const saved_dep = f.m.is_context_dep;
        const saved_ast = f.m.ast.?;
        switch (mutation) {
            0 => f.t.entry_graph_source = null,
            1 => f.t.entry_graph_source.?.module_pointer = foreign.m,
            2 => f.t.entry_graph_source.?.view = foreign.t.entry_graph_source.?.view,
            3 => f.t.entry_graph_source.?.input_domain = foreign.t.semantic_source_ast.?,
            4 => f.t.entry_graph_source.?.output = foreign.t.ast,
            5 => f.t.entry_graph_source.?.owner = foreign.m.semantic.?.owner_token,
            6 => f.t.entry_graph_imports.items[0].source = saved_event.output,
            7 => f.t.entry_graph_imports.items[0].literal = f.t.entry_graph_imports.items[1].literal,
            8 => f.t.entry_graph_imports.items[0].fields[1] = 1,
            9 => f.t.entry_graph_imports.items[0].fields[3] = 1,
            10 => f.m.import_records[0].source_node = f.m.import_records[1].source_node,
            11 => f.m.import_records[0].kind = .static_import,
            12 => f.m.import_records[0].resolved = @fromBackingInt(@as(u32, 17)),
            13 => f.m.import_records[0].is_lazy_resolved = !saved_record.is_lazy_resolved,
            14 => f.m.import_records[0].is_external = !saved_record.is_external,
            15 => f.m.import_records[0].specifier = "./wrong.mjs",
            16 => f.m.context_expansion_deps = f.m.import_records,
            17 => f.m.is_context_dep = true,
            18 => f.m.ast = foreign.t.ast.*,
            19 => f.t.entry_graph_before_binder = false,
            else => unreachable,
        }
        // This direct assertion independently checks the required-install guard.
        if (mutation == 0) try std.testing.expect(!Entry.requirementSatisfied(&f.t, &f.prepared));
        // The validator must not manufacture an installation or repair rows.
        const accepted = Entry.requirementSatisfied(&f.t, &f.prepared) and (try Entry.afterMetadata(&f.t, f.m, f.root));
        try std.testing.expect(!accepted);
        try std.testing.expectEqualSlices(?u32, before_ids, f.m.semantic.?.symbol_ids);
        try std.testing.expectEqualDeep(before_scope, f.m.semantic.?.scopes[0]);
        f.t.entry_graph_source = original;
        f.t.entry_graph_imports.items[0] = saved_event;
        f.m.import_records[0] = saved_record;
        f.m.context_expansion_deps = saved_context;
        f.m.is_context_dep = saved_dep;
        f.m.ast = saved_ast;
        f.t.entry_graph_before_binder = true;
        try std.testing.expect(Entry.requirementSatisfied(&f.t, &f.prepared));
        try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
        for (before_records, f.m.import_records) |before, after| try std.testing.expectEqualDeep(before, after);
    }
    // A late Scope copied into both installed certificate and current graph
    // must not replace the original same-capture scalar authority.
    const actual_scope = @constCast(f.m.semantic.?.scopes);
    const saved_scope = actual_scope[0];
    actual_scope[0].is_strict = !saved_scope.is_strict;
    f.t.entry_graph_source.?.source_scope = actual_scope[0];
    try std.testing.expect(!Entry.requirementSatisfied(&f.t, &f.prepared));
    actual_scope[0] = saved_scope;
    f.t.entry_graph_source = original;
    try std.testing.expect(Entry.requirementSatisfied(&f.t, &f.prepared));
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
    // String ownership is payload, not pointer identity or late record selection.
    const saved = f.m.import_records[0].specifier;
    f.m.import_records[0].specifier = try a.dupe(u8, saved);
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
    f.m.import_records[0].specifier = saved;
}

test "side effect entry graph preserves excluded source boundaries and requires unique complete creator events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rejected = [_][]const u8{
        "import {value} from './a.mjs';console.log(value);",
        "import value from './a.mjs';console.log(value);",
        "import * as value from './a.mjs';console.log(value);",
        "import './a.mjs';const local=7;console.log(local);",
        "import './a.mjs';export const value=7;",
        "import('./a.mjs');",
        "require('./a.mjs');",
        "import './a.mjs';console.log(eval('7'));",
        "import './a.mjs';console.log(globalThis.box?.value??7);",
        "import './a.mjs';function read(){return 7}console.log(read());",
        "import './a.mjs';module.exports.value=7;",
        "import './a.mjs';exports.value=7;",
        "import './a.mjs';Object.defineProperty(exports,'__esModule',{value:true});",
    };
    for (rejected) |text| try std.testing.expectError(error.MissingEntrySource, Fixture.initWithText(a, text));
    var f = try Fixture.init(a);
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
    const imports = &f.t.entry_graph_imports;
    const original = try a.dupe(Entry.ImportEvent, imports.items);
    _ = imports.pop();
    try std.testing.expect(!try Entry.afterMetadata(&f.t, f.m, f.root));
    try std.testing.expectEqual(@as(usize, 1), imports.items.len);
    try imports.append(a, original[1]);
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
    try imports.append(a, original[0]);
    try std.testing.expect(!try Entry.afterMetadata(&f.t, f.m, f.root));
    try std.testing.expectEqual(@as(usize, 3), imports.items.len);
    _ = imports.pop();
    std.mem.swap(Entry.ImportEvent, &imports.items[0], &imports.items[1]);
    try std.testing.expect(!try Entry.afterMetadata(&f.t, f.m, f.root));
    std.mem.swap(Entry.ImportEvent, &imports.items[0], &imports.items[1]);
    const first = f.t.entry_graph_copies.items[0];
    const index = f.t.entry_graph_copy_index.getPtr(@backingInt(first.source)).?;
    const saved_index = index.*;
    index.* = (saved_index + 1) % f.t.entry_graph_copies.items.len;
    try std.testing.expect(!try Entry.afterMetadata(&f.t, f.m, f.root));
    index.* = saved_index;
    const source = f.t.entry_graph_source.?;
    f.t.entry_graph_source.?.records = try a.dupe(@import("../bundler/types.zig").ImportRecord, source.records);
    try std.testing.expect(!Entry.requirementSatisfied(&f.t, &f.prepared));
    f.t.entry_graph_source = source;
    const literal = source.imports[0].literal;
    const slots = @constCast(source.record_slots);
    const saved_slot = slots[@backingInt(literal)];
    slots[@backingInt(literal)] = 1;
    try std.testing.expect(!try Entry.afterMetadata(&f.t, f.m, f.root));
    slots[@backingInt(literal)] = saved_slot;
    f.t.entry_graph_source.?.record_slots = try a.dupe(?usize, source.record_slots);
    try std.testing.expect(!Entry.requirementSatisfied(&f.t, &f.prepared));
    f.t.entry_graph_source = source;
    try std.testing.expect(Entry.requirementSatisfied(&f.t, &f.prepared));
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
}

test "side effect entry graph indexes source literal identities once for a hundred imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (0..100) |index| try text.appendSlice(a, try std.fmt.allocPrint(a, "import './dep-{d}.mjs';", .{index}));
    var f = try Fixture.initWithText(a, text.items);
    const source = f.t.entry_graph_source.?;
    try std.testing.expectEqual(@as(usize, 100), source.imports.len);
    try std.testing.expectEqual(@as(usize, 100), source.records.len);
    try std.testing.expectEqual(@as(usize, 100), f.t.entry_graph_imports.items.len);
    for (source.imports, 0..) |item, index| {
        try std.testing.expectEqual(index, item.slot);
        try std.testing.expectEqual(@as(?usize, index), source.record_slots[@backingInt(item.literal)]);
        try std.testing.expectEqual(item.literal, source.records[index].source_node);
    }
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
    const options: @import("transformer.zig").TransformOptions = .{ .unsupported = @import("compat.zig").fromESTarget(.es2019) };
    // These are independent source metadata boundaries, even if a caller
    // supplies an otherwise plain ESM graph and identical syntax.
    const source_flags = [_]enum { cjs, marker, hybrid }{ .cjs, .marker, .hybrid };
    for (source_flags) |flag| {
        const before_kind = f.m.exports_kind;
        switch (flag) {
            .cjs => f.m.has_cjs_export_signal = true,
            .marker => f.m.has_esmodule_marker = true,
            .hybrid => f.m.exports_kind = .esm_with_dynamic_fallback,
        }
        try std.testing.expect((try Entry.forModule(a, f.m, options)) == null);
        f.m.has_cjs_export_signal = false;
        f.m.has_esmodule_marker = false;
        f.m.exports_kind = before_kind;
    }
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
}

test "side effect entry graph requires actual second stage execution and atomically rejects stale seals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a);
    const foreign = try Fixture.init(a);
    const original = f.t.entry_graph_metadata_seal.?;
    f.t.entry_graph_metadata_seal = null;
    // A read-only successful validator did not execute the publication phase.
    try std.testing.expect(try Entry.afterMetadata(&f.t, f.m, f.root));
    try std.testing.expect(!try Entry.metadataRequirementSatisfied(&f.t, f.m, f.root));
    try std.testing.expect(try Entry.publishMetadataCompletion(&f.t, f.m, f.root));
    try expectSameSeal(original, f.t.entry_graph_metadata_seal.?);
    const before_ids = try a.dupe(?u32, f.m.semantic.?.symbol_ids);
    const before_scope = f.m.semantic.?.scopes[0];
    for (0..6) |mutation| {
        switch (mutation) {
            0 => f.t.entry_graph_metadata_seal.?.module_pointer = foreign.m,
            1 => f.t.entry_graph_metadata_seal.?.source_view = foreign.t.entry_graph_source.?.view,
            2 => f.t.entry_graph_metadata_seal.?.output_domain = foreign.t.ast,
            3 => f.t.entry_graph_metadata_seal.?.input_domain = foreign.t.semantic_source_ast.?,
            4 => f.t.entry_graph_metadata_seal.?.owner = foreign.m.semantic.?.owner_token,
            5 => f.t.entry_graph_metadata_seal.?.root = f.t.entry_graph_imports.items[0].output,
            else => unreachable,
        }
        try std.testing.expect(!try Entry.metadataRequirementSatisfied(&f.t, f.m, f.root));
        f.t.entry_graph_metadata_seal = original;
        try std.testing.expect(try Entry.metadataRequirementSatisfied(&f.t, f.m, f.root));
    }
    const record_before = f.m.import_records[0];
    f.m.import_records[0].specifier = "./stale-metadata.mjs";
    const stale_before = f.m.import_records[0];
    try std.testing.expect(!try Entry.publishMetadataCompletion(&f.t, f.m, f.root));
    try expectSameSeal(original, f.t.entry_graph_metadata_seal.?);
    try std.testing.expectEqualDeep(stale_before, f.m.import_records[0]);
    try std.testing.expect(!try Entry.metadataRequirementSatisfied(&f.t, f.m, f.root));
    try std.testing.expectEqualSlices(?u32, before_ids, f.m.semantic.?.symbol_ids);
    try std.testing.expectEqualDeep(before_scope, f.m.semantic.?.scopes[0]);
    f.m.import_records[0] = record_before;
    try std.testing.expect(try Entry.publishMetadataCompletion(&f.t, f.m, f.root));
    try std.testing.expect(try Entry.metadataRequirementSatisfied(&f.t, f.m, f.root));
}

test "side effect entry graph allocation failure cannot supply a prepared admission alternative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a);
    const prepass = @import("../bundler/graph/transform_prepass.zig");
    // This fresh capture is from the actual current Module payload, rather than
    // reusing the original pre-publication input header as a late source.
    const valid = (try Entry.forModule(a, f.m, f.t.options)) orelse return error.MissingFreshEntrySource;
    try std.testing.expect(prepass.sideeffectEntryPreparedAdmissionForTest(f.m, f.t.options, &valid));
    try std.testing.expect(!prepass.sideeffectEntryPreparedAdmissionForTest(f.m, f.t.options, null));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const unavailable: ?Entry.Source = Entry.forModule(failing.allocator(), f.m, f.t.options) catch |err| blk: {
        try std.testing.expectEqual(error.OutOfMemory, err);
        break :blk null;
    };
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(unavailable == null);
    try std.testing.expect(!prepass.sideeffectEntryPreparedAdmissionForTest(f.m, f.t.options, if (unavailable) |*source| source else null));
}

fn expectSameSeal(wanted: Entry.MetadataSeal, actual: Entry.MetadataSeal) !void {
    try std.testing.expect(wanted.source_view == actual.source_view);
    try std.testing.expect(wanted.input_domain == actual.input_domain);
    try std.testing.expect(wanted.output_domain == actual.output_domain);
    try std.testing.expect(wanted.module_pointer == actual.module_pointer);
    try std.testing.expectEqual(wanted.module_index, actual.module_index);
    try std.testing.expectEqual(wanted.root, actual.root);
    try std.testing.expectEqual(wanted.owner, actual.owner);
}
