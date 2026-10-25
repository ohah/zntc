const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const module_parser = @import("../parser/module.zig");

const cases = [_][]const u8{
    "import {map} from 'library'; console.log(map);",
    "import {map,filter} from 'library'; console.log(map,filter);",
    "import {map} from 'library'; function read(map){return map} console.log(map,read(1));",
    "import {map} from 'library'; function read(value=map){return value} console.log(read());",
    "import {map} from 'library'; console.log((()=>map)());",
    "import {map} from 'library'; class Read{read(){return map}} console.log(new Read().read());",
    "import {map} from 'library'; console.log({map});",
    "import {map} from 'library'; export {map};",
    "import {m\\u0061p} from 'library'; console.log(map);",
    "import {map,filter,reduce} from 'library'; console.log(reduce(filter(map)));",
};

fn expectMapBindingIdentity(enabled: bool) !void {
    var bad_cases: usize = 0;
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, source);
        var parser = Parser.init(allocator, &scanner);
        parser.is_module = true;
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        const list = parser.ast.getNode(root).data.list;
        const declaration: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[list.start]);
        const original = module_parser.readImportDeclExtras(&parser.ast, parser.ast.getNode(declaration).data.extra);
        var anchors: std.ArrayList(NodeIndex) = .empty;
        for (0..original.specs_len) |index| {
            const specifier: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[original.specs_start + index]);
            try anchors.append(allocator, parser.ast.getNode(specifier).data.binary.right);
        }
        const mapping = [_]@import("options.zig").ModuleSpecifierMapEntry{.{ .module = "library", .template = "./parts/{name}.mjs" }};
        var transformer = try Transformer.init(allocator, &parser.ast, .{ .module_specifier_map = &mapping });
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.references = analyzer.references.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.scope_maps = analyzer.scope_maps.items;
        transformer.scope_owner_map = analyzer.scope_owner_map;
        transformer.node_scope_provenance = analyzer.node_scope_provenance;
        transformer.helper_scope_map = analyzer.helper_scope_map;
        transformer.unresolved_references = &analyzer.unresolved_references;
        transformer.semantic_edit_enabled = enabled;
        // Inspect producer identity before finishSemanticEdit, with a separate
        // no-finalizer control proving the handoff is not late reconstruction.
        const output = try transformer.transform();
        const output_list = transformer.ast.getNode(output).data.list;
        var mismatch = false;
        for (anchors.items, 0..) |anchor, index| {
            const next_decl: NodeIndex = @fromBackingInt(transformer.ast.extra_data.items[output_list.start + index]);
            const next = module_parser.readImportDeclExtras(transformer.ast, transformer.ast.getNode(next_decl).data.extra);
            try std.testing.expectEqual(@as(u32, 1), next.specs_len);
            const binding: NodeIndex = @fromBackingInt(transformer.ast.extra_data.items[next.specs_start]);
            try std.testing.expectEqual(ast_mod.Node.Tag.import_default_specifier, transformer.ast.getNode(binding).tag);
            const expected_names = [_][]const u8{ "map", "filter", "reduce" };
            const expected_path = try std.fmt.allocPrint(allocator, "'./parts/{s}.mjs'", .{expected_names[index]});
            try std.testing.expectEqualStrings(expected_path, transformer.ast.getText(transformer.ast.getNode(next.source).data.string_ref));
            if (binding != anchor or transformer.getSymbolIdAt(binding) != analyzer.symbol_ids.items[@backingInt(anchor)]) mismatch = true;
        }
        if (enabled) {
            const editor = if (transformer.semantic_editor) |*value| value else return error.MissingSemanticEditor;
            try std.testing.expectEqual(analyzer.symbols.items.len, editor.symbols.items.len);
            try std.testing.expectEqual(analyzer.scopes.items.len, editor.scopes.items.len);
            for (anchors.items) |anchor| {
                const sid = analyzer.symbol_ids.items[@backingInt(anchor)].?;
                try std.testing.expectEqual(analyzer.symbols.items[sid].kind, editor.symbols.items[sid].kind);
                try std.testing.expectEqual(analyzer.symbols.items[sid].scope_id, editor.symbols.items[sid].scope_id);
                try std.testing.expectEqual(analyzer.symbols.items[sid].reference_count, editor.symbols.items[sid].reference_count);
                try std.testing.expectEqual(analyzer.symbols.items[sid].write_count, editor.symbols.items[sid].write_count);
                var declarations: usize = 0;
                for (editor.references.items) |reference| {
                    if (@backingInt(reference.symbol_id) != sid or !reference.flags.declare) continue;
                    declarations += 1;
                    try std.testing.expectEqual(anchor, reference.declaration_node_index);
                    try std.testing.expectEqual(analyzer.symbols.items[sid].scope_id, reference.scope_id);
                }
                try std.testing.expectEqual(@as(usize, 1), declarations);
            }
            _ = try transformer.finishSemanticEdit();
        }
        if (mismatch) bad_cases += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), bad_cases);
}

test "module map preserves original import binding anchors across ten source contexts" {
    try expectMapBindingIdentity(false);
}

test "module map preserves exact declaration SID Scope and references before finish in ten contexts" {
    try expectMapBindingIdentity(true);
}

fn checkAtomicSplitAllocation(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    var scanner = try Scanner.init(memory, "import {map,filter,reduce} from 'library';");
    var parser = Parser.init(memory, &scanner);
    parser.is_module = true;
    const root = try parser.parse();
    const list = parser.ast.getNode(root).data.list;
    const declaration: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[list.start]);
    const original = module_parser.readImportDeclExtras(&parser.ast, parser.ast.getNode(declaration).data.extra);
    var anchors: [3]NodeIndex = undefined;
    for (&anchors, 0..) |*anchor, index| {
        const specifier: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[original.specs_start + index]);
        anchor.* = parser.ast.getNode(specifier).data.binary.right;
    }
    const suffix = "/{name}.mjs";
    const large_template = try memory.alloc(u8, 4096 + suffix.len);
    @memset(large_template[0..4096], 'x');
    @memcpy(large_template[4096..], suffix);
    const mapping = [_]@import("options.zig").ModuleSpecifierMapEntry{.{ .module = "library", .template = large_template }};
    var transformer = try Transformer.initBorrow(memory, &parser.ast, .{ .module_specifier_map = &mapping });
    errdefer for (anchors) |anchor| {
        std.debug.assert(parser.ast.getNode(anchor).tag == .identifier_reference);
    };
    _ = try @import("transformer/import_export.zig").visitImportDeclaration(&transformer, parser.ast.getNode(declaration));
    for (anchors) |anchor| try std.testing.expectEqual(ast_mod.Node.Tag.import_default_specifier, parser.ast.getNode(anchor).tag);
}

test "module map commits the split binding roles only after all allocations succeed" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAtomicSplitAllocation, .{});
}

test "module map rejects ten malformed exact bindings without scope-name recovery" {
    for (0..10) |poison| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, "import {map,filter} from 'library'; function decoy(value){return value} console.log(map,filter);");
        var parser = Parser.init(allocator, &scanner);
        parser.is_module = true;
        const root = try parser.parse();
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        try analyzer.analyze();
        const list = parser.ast.getNode(root).data.list;
        const declaration: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[list.start]);
        const original = module_parser.readImportDeclExtras(&parser.ast, parser.ast.getNode(declaration).data.extra);
        const specifier: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[original.specs_start]);
        const anchor = parser.ast.getNode(specifier).data.binary.right;
        const sid = analyzer.symbol_ids.items[@backingInt(anchor)].?;
        var transformer = try Transformer.init(allocator, &parser.ast, .{});
        try transformer.initSymbolIds(analyzer.symbol_ids.items);
        transformer.symbols = analyzer.symbols.items;
        transformer.scopes = analyzer.scopes.items;
        transformer.semantic_edit_enabled = true;
        var checked_anchor = anchor;
        switch (poison) {
            0 => checked_anchor = .none,
            1 => checked_anchor = @fromBackingInt(@as(u32, @intCast(transformer.ast.nodes.items.len + 3))),
            2 => transformer.ast.nodes.items[@backingInt(anchor)].tag = .binding_identifier,
            3 => transformer.symbol_ids.items[@backingInt(anchor)] = null,
            4 => transformer.symbol_ids.items.len = @backingInt(anchor),
            5 => transformer.symbol_ids.items[@backingInt(anchor)] = @intCast(transformer.symbols.len + 7),
            6 => @constCast(transformer.symbols)[sid].kind = .variable_var,
            7 => @constCast(transformer.symbols)[sid].decl_flags.is_import = false,
            8 => @constCast(transformer.symbols)[sid].scope_id = .none,
            9 => @constCast(transformer.symbols)[sid].scope_id = @fromBackingInt(@as(u32, @intCast(transformer.scopes.len + 3))),
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidMappedImportBinding, @import("transformer/import_export.zig").validateMappedImportBinding(&transformer, checked_anchor));
    }
}

fn expectMalformedProducerPanic(mode: []const u8) !void {
    const allocator = std.testing.allocator;
    const executable = try std.process.executablePathAlloc(std.testing.io, allocator);
    defer allocator.free(executable);
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("ZNTC_MODULE_MAP_PANIC_MODE", mode);
    const child_index: u32 = blk: {
        for (@import("builtin").test_functions, 0..) |test_function, index| {
            if (std.mem.endsWith(u8, test_function.name, "module map producer malformed identity panic child")) break :blk @intCast(index);
        }
        return error.MissingModuleMapPanicChild;
    };
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ executable, "--listen=-" }, .environ_map = &environ, .stdin = .pipe, .stdout = .ignore, .stderr = .pipe });
    defer child.kill(io);
    var message_buffer: [64]u8 = undefined;
    var writer = child.stdin.?.writer(io, &message_buffer);
    const client: std.zig.Client = .{ .in = undefined, .out = &writer.interface };
    try client.serveRunTest(child_index);
    try client.serveBodylessMessage(.exit);
    child.stdin.?.close(io);
    child.stdin = null;
    var stderr_buffer: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(child.stderr.?, io, &stderr_buffer);
    const stderr = try reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(stderr);
    const term = try child.wait(io);
    try std.testing.expect(!term.success());
    try std.testing.expect(std.mem.indexOf(u8, stderr, "mapped import lost its exact source binding") != null);
}

test "module map producer rejects malformed identity at creation" {
    try expectMalformedProducerPanic("missing-id");
    try expectMalformedProducerPanic("wrong-kind");
}

test "module map producer malformed identity panic child" {
    if (!std.testing.environ.containsUnemptyConstant("ZNTC_MODULE_MAP_PANIC_MODE")) return;
    const mode = try std.testing.environ.getAlloc(std.testing.allocator, "ZNTC_MODULE_MAP_PANIC_MODE");
    defer std.testing.allocator.free(mode);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "import {map} from 'library';console.log(map);");
    var parser = Parser.init(allocator, &scanner);
    parser.is_module = true;
    const root = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const list = parser.ast.getNode(root).data.list;
    const declaration: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[list.start]);
    const original = module_parser.readImportDeclExtras(&parser.ast, parser.ast.getNode(declaration).data.extra);
    const specifier: NodeIndex = @fromBackingInt(parser.ast.extra_data.items[original.specs_start]);
    const anchor = parser.ast.getNode(specifier).data.binary.right;
    const sid = analyzer.symbol_ids.items[@backingInt(anchor)].?;
    const mapping = [_]@import("options.zig").ModuleSpecifierMapEntry{.{ .module = "library", .template = "./parts/{name}.mjs" }};
    var transformer = try Transformer.initBorrow(allocator, &parser.ast, .{ .module_specifier_map = &mapping });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.references = analyzer.references.items;
    transformer.semantic_edit_enabled = true;
    if (std.mem.eql(u8, mode, "missing-id")) {
        transformer.symbol_ids.items[@backingInt(anchor)] = null;
    } else {
        @constCast(transformer.symbols)[sid].kind = .variable_var;
    }
    _ = try @import("transformer/import_export.zig").visitImportDeclaration(&transformer, parser.ast.getNode(declaration));
}
