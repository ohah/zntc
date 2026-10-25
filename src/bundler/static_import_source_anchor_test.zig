const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const imports = @import("import_scanner.zig");
const module_parser = @import("../parser/module.zig");

test "static source anchors are captured by parser and reconstructed by AST scanner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "import './a';import def from './b';import * as ns from './c';import {value as local} from './d';export {value} from './e';export * from './f';";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".mjs");
    parser.enable_scan = true;
    _ = try parser.parse();
    const records = try imports.extractImports(a, &parser.ast);
    try std.testing.expectEqual(@as(usize, 6), records.len);
    try std.testing.expectEqual(records.len, parser.scan_import_records.items.len);
    for (records, parser.scan_import_records.items) |record, inline_record| {
        try std.testing.expect(!record.source_node.isNone());
        try std.testing.expectEqual(inline_record.source_node, record.source_node);
        try std.testing.expectEqual(ast_mod.Node.Tag.string_literal, parser.ast.getNode(record.source_node).tag);
    }
}

test "static source anchors survive literal clones graph metadata merge and cache reconstruction" {
    for ([_]usize{ 1, 70 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var source: std.ArrayList(u8) = .empty;
        for (0..count) |index| try source.appendSlice(a, try std.fmt.allocPrint(a, "import './dep{d}.cjs';", .{index}));
        var scanner = try Scanner.init(a, source.items);
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        parser.enable_scan = true;
        const root = try parser.parse();
        const previous = try imports.extractImports(a, &parser.ast);
        for (previous, 0..) |*record, index| record.resolved = @import("types.zig").ModuleIndex.fromUsize(index);
        var ast = try ast_mod.Ast.cloneForTransformer(&parser.ast, a);
        ast.transformed_root = root;
        for (parser.scan_import_records.items) |record| try std.testing.expectEqual(ast_mod.Node.Tag.string_literal, ast.getNode(record.source_node).tag);
        var transformer = try @import("../transformer/transformer.zig").Transformer.initBorrow(a, &ast, .{});
        var statements = ast.iterateExtraList(ast.getNode(root).data.list);
        while (statements.next()) |statement| {
            const node = ast.getNode(statement);
            const decl = module_parser.readImportDeclExtras(&ast, node.data.extra);
            const cloned_source = try @import("../transformer/es_helpers.zig").cloneNode(&transformer, decl.source);
            try std.testing.expect(cloned_source != decl.source);
            ast.extra_data.items[node.data.extra + 2] = @backingInt(cloned_source);
        }
        const scanned = try imports.extractImports(a, &ast);
        const merged = try @import("graph/parse_helpers.zig").mergeImportRecords(a, previous, scanned);
        try std.testing.expectEqual(count, merged.len);
        for (merged, previous, scanned) |current, old, fresh| {
            try std.testing.expect(current.source_node != old.source_node);
            try std.testing.expectEqual(fresh.source_node, current.source_node);
            try std.testing.expectEqual(old.resolved, current.resolved);
        }
        var bytes: std.ArrayList(u8) = .empty;
        try @import("../parser/ast_codec.zig").serialize(&ast, &bytes, a);
        var restored = try @import("../parser/ast_codec.zig").deserialize(bytes.items, a);
        const reconstructed = try imports.extractImports(a, &restored);
        try std.testing.expectEqual(merged.len, reconstructed.len);
        for (merged, reconstructed) |before, after| try std.testing.expectEqual(before.source_node, after.source_node);
    }
}

test "static storage preserves source binding SID scope and declaration handoff in ten contexts" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const bodies = [_][]const u8{
        "export function run(){return other.other}",
        "export function run(require_b){return other.other}",
        "export function run(__toESM){return other.other}",
        "export function run(__import_callsite_0){return other.other}",
        "export function run(value=other.other){return value}",
        "export function run(){return (()=>other.other)()}",
        "export class Read{read(){return other.other}}",
        "export function run(){return {other}.other.other}",
        "export {other};export function run(){return other.other}",
        "export function run(){return [other.other,eval('other.other')]}",
    };
    for (bodies, 0..) |body, context| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", if (context == 8) "import('./consumer.mjs').then(m=>console.log(m.other.other,m.run()));" else "import('./consumer.mjs').then(m=>console.log(m));");
        const source = try std.fmt.allocPrint(std.testing.allocator, "import {s} from './b.cjs';{s}", .{ if (context % 2 == 0) "other" else "* as other", body });
        defer std.testing.allocator.free(source);
        try helpers.writeFile(tmp.dir, "consumer.mjs", source);
        try helpers.writeFile(tmp.dir, "b.cjs", "exports.other=43;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .unsupported = if (context >= 4) @import("../transformer/compat.zig").fromESTarget(.es5) else .{} };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        if (context == 8) {
            const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            defer std.testing.allocator.free(execution.stdout);
            defer std.testing.allocator.free(execution.stderr);
            try std.testing.expectEqualStrings("43 43\n", execution.stdout);
        }
        var found = false;
        var modules = graph.modulesIterator();
        while (modules.next()) |module| {
            if (!std.mem.endsWith(u8, module.path, "/consumer.mjs")) continue;
            const sem = module.semantic.?;
            const ast = &module.ast.?;
            for (module.import_bindings) |binding| {
                if (binding.callsite_target != null or binding.is_helper) continue;
                const record = module.import_records[binding.import_record_index];
                const target = graph.getModule(record.resolved) orelse continue;
                if (!std.mem.endsWith(u8, target.path, "/b.cjs")) continue;
                found = true;
                try std.testing.expect(record.callsite_lowered);
                const physical_binding = binding.local_symbol_node.?;
                const sid = sem.symbol_ids[@backingInt(physical_binding)].?;
                try std.testing.expect(binding.local_role == .materialized_var);
                try std.testing.expectEqual(@as(?u32, sid), binding.local_symbol.semanticIndex());
                var original: NodeIndex = .none;
                const expected_tag: ast_mod.Node.Tag = if (binding.kind == .namespace) .import_namespace_specifier else .import_default_specifier;
                for (ast.nodes.items, 0..) |old_node, raw| {
                    if (old_node.tag == expected_tag and raw < sem.symbol_ids.len and sem.symbol_ids[raw] == @as(?u32, sid)) original = @fromBackingInt(@as(u32, @intCast(raw)));
                }
                try std.testing.expect(!original.isNone());
                try std.testing.expect(physical_binding != original);
                const symbol = sem.symbols.items[sid];
                try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, symbol.kind);
                try std.testing.expectEqual(@as(u32, 0), @backingInt(symbol.scope_id));
                try std.testing.expect(!symbol.decl_flags.is_import and symbol.decl_flags.function_scoped);
                var declarations: usize = 0;
                for (sem.references) |reference| {
                    if (@backingInt(reference.symbol_id) != sid or !reference.flags.declare) continue;
                    declarations += 1;
                    try std.testing.expect(reference.declaration_node_index != original);
                    try std.testing.expectEqual(ast_mod.Node.Tag.binding_identifier, ast.getNode(reference.declaration_node_index).tag);
                    try std.testing.expectEqual(@as(?u32, sid), sem.symbol_ids[@backingInt(reference.declaration_node_index)]);
                    try std.testing.expectEqual(symbol.scope_id, reference.scope_id);
                }
                try std.testing.expectEqual(@as(usize, 1), declarations);
                // Recover effective use scopes solely from actual AST owners.
                var checked: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer checked.deinit(std.testing.allocator);
                try checked.put(std.testing.allocator, sid, {});
                for (module.import_bindings) |alias| if (alias.callsite_target != null) {
                    try checked.put(std.testing.allocator, alias.local_symbol.semanticIndex().?, {});
                };
                const Work = struct { node: NodeIndex, scope: u32 };
                var work: std.ArrayList(Work) = .empty;
                defer work.deinit(std.testing.allocator);
                try work.append(std.testing.allocator, .{ .node = ast.transformed_root.?, .scope = 0 });
                var uses: usize = 0;
                while (work.pop()) |item| {
                    if (item.node.isNone()) continue;
                    const node = ast.getNode(item.node);
                    const scope = sem.scope_owner_map.get(@backingInt(item.node)) orelse item.scope;
                    if (node.tag == .identifier_reference and @backingInt(item.node) < sem.symbol_ids.len and sem.symbol_ids[@backingInt(item.node)] != null and checked.contains(sem.symbol_ids[@backingInt(item.node)].?)) {
                        for (sem.references) |reference| {
                            if (reference.node_index != item.node) continue;
                            uses += 1;
                            try std.testing.expectEqual(scope, @backingInt(reference.scope_id));
                        }
                    }
                    var children = @import("../parser/ast_walk.zig").children(ast, node);
                    while (children.next()) |child| try work.append(std.testing.allocator, .{ .node = child, .scope = scope });
                }
                try std.testing.expect(uses > 0);
            }
        }
        try std.testing.expect(found);
    }
}

test "static source anchors reject malformed inputs without spelling recovery in ten states" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const binding_scanner = @import("binding_scanner.zig");
    for (0..10) |corruption| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import('./consumer.mjs').then(m=>console.log(m.run()));");
        try helpers.writeFile(tmp.dir, "consumer.mjs", "import './a.cjs';import * as other from './b.cjs';export function run(){return other.other}");
        try helpers.writeFile(tmp.dir, "a.cjs", "globalThis.effect=1;");
        try helpers.writeFile(tmp.dir, "b.cjs", "exports.other=43;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .platform = .react_native };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        var candidate: ?*@import("module.zig").Module = null;
        var modules = graph.modulesIterator();
        while (modules.next()) |module| if (std.mem.endsWith(u8, module.path, "/consumer.mjs")) {
            candidate = graph.moduleAtMut(module.index);
        };
        const module = candidate orelse return error.MissingStaticConsumer;
        const initial_binding = module.import_bindings[0];
        const local = binding_scanner.resolveImportLocalSymbol(initial_binding, .{ .module_index = module.index, .ast = &module.ast.?, .symbol_ids = module.semantic.?.symbol_ids, .symbols = module.semantic.?.symbols.items });
        const sid = local.semanticIndex().?;
        const source_a = module.import_records[0].source_node;
        const source_b = module.import_records[1].source_node;
        switch (corruption) {
            0 => try @constCast(module.semantic.?.scope_maps)[0].put(module.parse_arena.?.allocator(), "other", sid + 1),
            1 => module.import_records[0].source_node = .none,
            2 => module.import_records[0].source_node = @fromBackingInt(@as(u32, @intCast(module.ast.?.nodes.items.len))),
            3 => module.import_records[0].source_node = initial_binding.local_symbol_node.?,
            4 => module.import_records[0].source_node = source_b,
            5 => module.import_bindings[0].local_symbol_node = null,
            6 => module.import_bindings[0].local_symbol = @import("symbol.zig").SymbolRef.makeSemantic(module.index, sid + 1),
            7 => {
                module.import_records[0].span = .EMPTY;
                module.import_records[1].span = .EMPTY;
            },
            8 => {
                module.import_records[0].specifier = "unrelated_decoy_a";
                module.import_records[1].specifier = "unrelated_decoy_b";
            },
            9 => {
                std.mem.swap(@import("types.zig").ImportRecord, &module.import_records[0], &module.import_records[1]);
                module.import_bindings[0].import_record_index = 0;
            },
            else => unreachable,
        }
        var linker = @import("linker.zig").Linker.init(std.testing.allocator, &graph, .esm);
        defer linker.deinit();
        if (corruption <= 5) {
            try std.testing.expectError(error.InvalidCallsiteBinding, @import("static_import_callsite.zig").lower(&graph, &linker));
        } else {
            try @import("static_import_callsite.zig").lower(&graph, &linker);
            const binding = module.import_bindings[0];
            try std.testing.expect(binding.local_role == .materialized_var);
            try std.testing.expectEqual(@as(?u32, sid), binding.local_symbol.semanticIndex());
            const resolved = binding_scanner.resolveImportLocalSymbol(binding, .{ .module_index = module.index, .ast = &module.ast.?, .symbol_ids = module.semantic.?.symbol_ids, .symbols = module.semantic.?.symbols.items });
            try std.testing.expect(resolved.eql(local));
            try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(binding, .{ .module_index = module.index, .module_scope = module.semantic.?.scope_maps[0] }).isValid());
            try std.testing.expectEqual(source_a, module.import_records[if (corruption == 9) 1 else 0].source_node);
            try std.testing.expectEqual(source_b, module.import_records[if (corruption == 9) 0 else 1].source_node);
        }
    }
}

test "static source anchors follow unicode and module specifier rewrite producers" {
    const Bundler = @import("bundler.zig").Bundler;
    const helpers = @import("test_helpers.zig");
    const mapping = [_]@import("../transformer/transformer.zig").ModuleSpecifierMapEntry{.{ .module = "./a.cjs", .template = "./parts/{name}.cjs" }};
    for ([_]bool{ false, true }) |rewrite| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import('./consumer.mjs').then(m=>console.log(m.run()));");
        try helpers.writeFile(tmp.dir, "consumer.mjs", if (rewrite) "import {value} from './a.cjs';export function run(){return value}" else "import './\\u{0062}.cjs';import {value} from './\\u{0061}.cjs';export function run(){return value}");
        try helpers.writeFile(tmp.dir, "a.cjs", "exports.value=42;");
        try helpers.writeFile(tmp.dir, "b.cjs", "exports.other=43;");
        try tmp.dir.createDirPath(std.testing.io, "parts");
        try helpers.writeFile(tmp.dir, "parts/value.cjs", "module.exports=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const options: @import("bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .inline_dynamic_imports = true, .unsupported = @import("../transformer/compat.zig").fromESTarget(.es5), .module_specifier_map = if (rewrite) &mapping else &.{} };
        var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, options);
        defer cache.deinit();
        var graph = @import("graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        var bundler = Bundler.initWithGraph(std.testing.allocator, options, &cache, &graph);
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        var modules = graph.modulesIterator();
        var lowered: usize = 0;
        while (modules.next()) |module| {
            if (!std.mem.endsWith(u8, module.path, "/consumer.mjs")) continue;
            const ast = &module.ast.?;
            for (module.import_records) |record| {
                if (record.kind != .static_import and record.kind != .side_effect) continue;
                try std.testing.expect(!record.source_node.isNone());
                try std.testing.expectEqual(ast_mod.Node.Tag.string_literal, ast.getNode(record.source_node).tag);
                if (std.mem.startsWith(u8, record.specifier, "./")) {
                    try std.testing.expect(record.callsite_lowered);
                    lowered += 1;
                }
            }
        }
        try std.testing.expectEqual(@as(usize, if (rewrite) 1 else 2), lowered);
        const execution = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer std.testing.allocator.free(execution.stdout);
        defer std.testing.allocator.free(execution.stderr);
        try std.testing.expectEqualStrings("42\n", execution.stdout);
    }
}
