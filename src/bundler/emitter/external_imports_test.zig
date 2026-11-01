const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");
const Module = @import("../module.zig").Module;
const ImportBinding = @import("../binding_scanner.zig").ImportBinding;
const emitChunkExternalImports = @import("external_imports.zig").emitChunkExternalImports;

test "external exact import writer rejects missing and foreign helper identities" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "import { value as local, extra } from 'external'; console.log(local, extra);";
    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(alloc, source);
    scanner.is_module = true;
    var parser = @import("../../parser/parser.zig").Parser.init(alloc, &scanner);
    parser.is_module = true;
    _ = try parser.parse();
    var analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const records = try @import("../import_scanner.zig").extractImports(alloc, &parser.ast);
    const bindings = try @import("../binding_scanner.zig").extractImportBindings(alloc, &parser.ast, records, null);
    var module = Module.init(.fromUsize(3), "entry.mjs");
    module.ast = parser.ast;
    module.semantic = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .exported_names = analyzer.exported_names, .symbol_ids = analyzer.symbol_ids.items, .unresolved_references = analyzer.unresolved_references };
    module.import_records = records;
    for (records) |*rec| rec.is_external = true;
    const scanner_mod = @import("../binding_scanner.zig");
    const original = bindings[0];
    var exact = original;
    exact.local_symbol = scanner_mod.resolveImportLocalSymbol(exact, .{ .module_index = module.index, .ast = &module.ast.?, .symbol_ids = analyzer.symbol_ids.items, .symbols = analyzer.symbols.items });
    exact.is_helper = true;
    var selected = [_]ImportBinding{exact};
    module.import_bindings = &selected;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    try emitChunkExternalImports(&output, a, true, &.{&module}, null, false);
    try testing.expect(std.mem.indexOf(u8, output.items, "value as local") != null);
    const attacks = enum { missing_ref, foreign_owner, other_import_sid, missing_anchor, other_anchor, none_anchor, out_of_bounds_anchor, missing_node_sid, empty_node_map, nonbinding_anchor, missing_declaration, wrong_imported_name, wrong_kind, wrong_source_node };
    inline for (std.meta.tags(attacks)) |attack| {
        selected[0] = exact;
        const raw = @backingInt(exact.local_symbol_node.?);
        const saved_sid = analyzer.symbol_ids.items[raw];
        const saved_ids = module.semantic.?.symbol_ids;
        const saved_source = records[0].source_node;
        switch (attack) {
            .missing_ref => selected[0].local_symbol = .invalid,
            .foreign_owner => selected[0].local_symbol = @import("../symbol.zig").SymbolRef.makeSemantic(.fromUsize(4), exact.local_symbol.semanticIndex().?),
            .other_import_sid => selected[0].local_symbol = scanner_mod.resolveImportLocalSymbol(bindings[1], .{ .module_index = module.index, .ast = &module.ast.?, .symbol_ids = analyzer.symbol_ids.items, .symbols = analyzer.symbols.items }),
            .missing_anchor => selected[0].local_symbol_node = null,
            .other_anchor => selected[0].local_symbol_node = bindings[1].local_symbol_node,
            .none_anchor => selected[0].local_symbol_node = .none,
            .out_of_bounds_anchor => selected[0].local_symbol_node = @fromBackingInt(@as(u32, @intCast(parser.ast.nodes.items.len))),
            .missing_node_sid => analyzer.symbol_ids.items[raw] = null,
            .empty_node_map => module.semantic.?.symbol_ids = &.{},
            .nonbinding_anchor => selected[0].local_symbol_node = records[0].source_node,
            .missing_declaration => selected[0].local_declaration_node = null,
            .wrong_imported_name => selected[0].imported_name = "wrong-property",
            .wrong_kind => selected[0].kind = .default,
            .wrong_source_node => records[0].source_node = exact.local_symbol_node.?,
        }
        output.clearRetainingCapacity();
        const result = emitChunkExternalImports(&output, a, true, &.{&module}, null, false);
        analyzer.symbol_ids.items[raw] = saved_sid;
        module.semantic.?.symbol_ids = saved_ids;
        records[0].source_node = saved_source;
        try testing.expectError(error.InvalidImportLocalSymbol, result);
    }
    selected[0] = exact;
    // The graph owns only its list shelves here; all Module payloads borrow
    // this test's arena, so do not individually deinit the borrowed modules.
    var cache = @import("../resolve_cache.zig").ResolveCache.init(a, .{});
    defer cache.deinit();
    var graph = @import("../graph.zig").ModuleGraph.init(a, &cache);
    defer graph.modules.deinit(a);
    for (0..3) |i| try graph.modules.append(a, Module.init(.fromUsize(i), "decoy.mjs"));
    try graph.modules.append(a, module);
    var linker = @import("../linker.zig").Linker.init(a, &graph, .esm);
    defer linker.deinit();
    try linker.rename_table.put(a, @import("../symbol.zig").SymbolID.make(module.index, exact.local_symbol.semanticIndex().?), "chosen_local");
    const installed = graph.getModule(module.index).?;
    output.clearRetainingCapacity();
    try emitChunkExternalImports(&output, a, true, &.{installed}, &linker, false);
    try testing.expect(std.mem.indexOf(u8, output.items, "value as chosen_local") != null);
    // The same source, module index and SID in a copied Module do not grant
    // the foreign Linker's canonical-name authority.
    try testing.expectError(error.InvalidExternalImportOwner, emitChunkExternalImports(&output, a, true, &.{&module}, &linker, false));
    // A canonical result cannot authorize a malformed stored identity.
    selected[0].local_symbol_node = null;
    try testing.expectError(error.InvalidImportLocalSymbol, emitChunkExternalImports(&output, a, true, &.{installed}, &linker, false));
    selected[0] = exact;
    selected[0].is_helper = false;
    selected[0].source_type_only = true;
    selected[0].local_symbol = .invalid;
    selected[0].local_symbol_node = null;
    module.module_type = .ts;
    output.clearRetainingCapacity();
    try emitChunkExternalImports(&output, a, true, &.{&module}, null, false);
    try testing.expectEqual(@as(usize, 0), output.items.len);
    // Graphless low-level compatibility stays explicit and helper-only.
    module.semantic = null;
    selected[0] = exact;
    selected[0].local_symbol = .invalid;
    selected[0].local_symbol_node = null;
    output.clearRetainingCapacity();
    try emitChunkExternalImports(&output, a, true, &.{&module}, null, false);
    try testing.expect(std.mem.indexOf(u8, output.items, "value as local") != null);
    selected[0].is_helper = false;
    output.clearRetainingCapacity();
    try emitChunkExternalImports(&output, a, true, &.{&module}, null, false);
    try testing.expectEqual(@as(usize, 0), output.items.len);
}

fn checkExternalRuntime(imports: []const u8, body: []const u8) !void {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = try std.fmt.allocPrint(alloc, "{s}{s}", .{ imports, body });
    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(alloc, source);
    scanner.is_module = true;
    var parser = @import("../../parser/parser.zig").Parser.init(alloc, &scanner);
    parser.is_module = true;
    _ = try parser.parse();
    var analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const records = try @import("../import_scanner.zig").extractImports(alloc, &parser.ast);
    const bindings = try @import("../binding_scanner.zig").extractImportBindings(alloc, &parser.ast, records, null);
    var module = Module.init(.fromUsize(3), "entry.mjs");
    module.ast = parser.ast;
    module.semantic = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .exported_names = analyzer.exported_names, .symbol_ids = analyzer.symbol_ids.items, .unresolved_references = analyzer.unresolved_references };
    module.import_records = records;
    module.import_bindings = bindings;
    for (records) |*rec| rec.is_external = true;
    for (bindings) |*binding| binding.local_symbol = @import("../binding_scanner.zig").resolveImportLocalSymbol(binding.*, .{ .module_index = module.index, .ast = &module.ast.?, .symbol_ids = analyzer.symbol_ids.items, .symbols = analyzer.symbols.items });
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try @import("../test_helpers.zig").writeFile(tmp.dir, "native.mjs", source);
    const native_path = try @import("../test_helpers.zig").absPath(&tmp, "native.mjs");
    defer a.free(native_path);
    const native = try std.process.run(a, testing.io, .{ .argv = &.{ "node", native_path } });
    defer a.free(native.stdout);
    defer a.free(native.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, native.term);
    try testing.expectEqualStrings("7\n", native.stdout);
    for ([_]bool{ false, true }) |minify| {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(a);
        try emitChunkExternalImports(&output, a, true, &.{&module}, null, minify);
        try output.appendSlice(a, body);
        try @import("../test_helpers.zig").writeFile(tmp.dir, "output.mjs", output.items);
        const path = try @import("../test_helpers.zig").absPath(&tmp, "output.mjs");
        defer a.free(path);
        const actual = try std.process.run(a, testing.io, .{ .argv = &.{ "node", path } });
        defer a.free(actual.stdout);
        defer a.free(actual.stderr);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, actual.term);
        try testing.expectEqualStrings(native.stdout, actual.stdout);
    }
    if (bindings.len > 0) {
        const saved = bindings[0].imported_name;
        defer bindings[0].imported_name = saved;
        bindings[0].imported_name = "wrong-property";
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(a);
        try testing.expectError(error.InvalidImportLocalSymbol, emitChunkExternalImports(&output, a, true, &.{&module}, null, false));
    }
}

test "external exact import writer preserves ten hostile source inputs without canonical rename" {
    const cases = [_]struct { imports: []const u8, body: []const u8 }{
        .{ .imports = "import{basename as local}from'node:path';", .body = "console.log(local('/a/7'));" },
        .{ .imports = "import path from'node:path';", .body = "console.log(path.basename('/a/7'));" },
        .{ .imports = "import*as path from'node:path';", .body = "console.log(path.basename('/a/7'));" },
        .{ .imports = "import{basename,dirname}from'node:path';", .body = "console.log(basename(dirname('/7/a')));" },
        .{ .imports = "import{basename as left}from'node:path';import{basename as right}from'node:path';", .body = "console.log(left('/7')===right('/7')?left('/7'):'bad');" },
        .{ .imports = "import{basename as v\\u0061lue}from'node:path';", .body = "console.log(value('/a/7'));" },
        .{ .imports = "import{default as value}from'node:path';", .body = "console.log(value.basename('/a/7'));" },
        .{ .imports = "import'node:path';import{basename}from'node:path';", .body = "console.log(basename('/a/7'));" },
        .{ .imports = "import{basename as __generator}from'node:path';", .body = "const basename=17;console.log(__generator('/a/7'));" },
        .{ .imports = "import{basename}from'node:path';import{fileURLToPath}from'node:url';", .body = "console.log(basename(fileURLToPath('file:///a/7')));" },
    };
    for (cases) |case| try checkExternalRuntime(case.imports, case.body);
}

fn checkPairedForeignImportCarrier(source: []const u8) !void {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(alloc, source);
    scanner.is_module = true;
    var parser = @import("../../parser/parser.zig").Parser.init(alloc, &scanner);
    parser.is_module = true;
    _ = try parser.parse();
    var analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const records = try @import("../import_scanner.zig").extractImports(alloc, &parser.ast);
    const bindings = try @import("../binding_scanner.zig").extractImportBindings(alloc, &parser.ast, records, null);
    try testing.expectEqual(@as(usize, 2), bindings.len);
    var module = Module.init(.fromUsize(3), "entry.mjs");
    module.ast = parser.ast;
    module.semantic = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .exported_names = analyzer.exported_names, .symbol_ids = analyzer.symbol_ids.items, .unresolved_references = analyzer.unresolved_references };
    module.import_records = records;
    for (records) |*rec| rec.is_external = true;
    for (bindings) |*binding| binding.local_symbol = @import("../binding_scanner.zig").resolveImportLocalSymbol(binding.*, .{ .module_index = module.index, .ast = &module.ast.?, .symbol_ids = analyzer.symbol_ids.items, .symbols = analyzer.symbols.items });
    try testing.expect(bindings[0].local_symbol.isValid() and bindings[1].local_symbol.isValid());
    try testing.expect(!bindings[0].local_symbol.eql(bindings[1].local_symbol));
    try testing.expect(bindings[0].local_declaration_node != bindings[1].local_declaration_node);
    var selected = [_]ImportBinding{bindings[0]};
    module.import_bindings = &selected;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(a);
    try emitChunkExternalImports(&output, a, true, &.{&module}, null, false);
    // Both values are genuine scanner/analyzer identities. Preserve the first
    // record/source/declaration/imported key while substituting the second pair.
    selected[0].local_symbol_node = bindings[1].local_symbol_node;
    selected[0].local_symbol = bindings[1].local_symbol;
    try testing.expectEqual(bindings[0].local_declaration_node, selected[0].local_declaration_node);
    try testing.expectEqual(bindings[0].import_record_index, selected[0].import_record_index);
    try testing.expectEqualStrings(bindings[0].imported_name, selected[0].imported_name);
    output.clearRetainingCapacity();
    try testing.expectError(error.InvalidImportLocalSymbol, emitChunkExternalImports(&output, a, true, &.{&module}, null, false));
}

test "external exact import writer rejects paired foreign declaration anchor and SID" {
    try checkPairedForeignImportCarrier("import{basename as local}from'node:path';import{fileURLToPath as other}from'node:url';console.log(local,other);");
}

test "external exact import writer rejects paired same-specifier declaration anchor and SID" {
    try checkPairedForeignImportCarrier("import{basename as local}from'node:path';import{dirname as other}from'node:path';console.log(local,other);");
}

test "external exact import writer preserves quoted and escaped imported property roles" {
    try checkExternalRuntime("import{b\\u0061sename as local}from'node:path';", "console.log(local('/a/7'));");
    try checkExternalRuntime("import{'base\\u006eame' as local}from'node:path';", "console.log(local('/a/7'));");
}
