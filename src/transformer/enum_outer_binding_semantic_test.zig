const std = @import("std");
const ast = @import("../parser/ast.zig");

test "enum outer binding initial source identity belongs to its actual enclosing lexical environment" {
    const sources = [_][]const u8{
        "function run(){enum E{A=7};return E.A}",
        "class C{constructor(){enum E{A=7};this.value=E.A}}",
        "class C{read(){enum E{A=7};return E.A}}",
        "class C{static{enum E{A=7};console.log(E.A)}}",
        "enum E{A=9};{enum E{A=7};console.log(E.A)}console.log(E.A)",
        "function run(){try{console.log(E)}catch(error){}enum E{A=7}}",
        "{enum E{A=7};enum E{B=9};console.log(E.A,E.B)}",
        "const all=[];for(let index=0;index<2;index++){enum E{A=index};all.push(()=>E.A)}",
        "const all=[];for(let index=0;index<2;index++){enum E{A=index};enum E{B=index+7};all.push(()=>E.A)}",
        "namespace N{export enum E{A=7}}",
        "function run(){enum E{A=9};{enum E{A=7};console.log(E.A)}console.log(E.A)}",
        "function make(){enum E{A=7};return()=>E}",
    };
    for (sources) |source| {
        errdefer std.debug.print("enum source identity: {s}\n", .{source});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_ts = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var checked: usize = 0;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .ts_enum_declaration) continue;
            const name = parser.ast.readExtraNode(node.data.extra, ast.EnumExtra.name);
            const id = analyzer.symbol_ids.items[@backingInt(name)] orelse return error.MissingInitialEnumOuterBinding;
            const inner = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.MissingInitialEnumIifeScope;
            const outer = analyzer.scopes.items[inner].parent;
            try std.testing.expectEqual(outer, analyzer.symbols.items[id].scope_id);
            const top = analyzer.scopes.items[outer.toIndex()].kind == .global or analyzer.scopes.items[outer.toIndex()].kind == .module;
            try std.testing.expectEqual(if (top) @import("../semantic/symbol.zig").SymbolKind.variable_var else .variable_let, analyzer.symbols.items[id].kind);
            var declarations: usize = 0;
            for (analyzer.references.items) |reference| if (reference.flags.declare and reference.declaration_node_index == name) {
                try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                try std.testing.expectEqual(outer, reference.scope_id);
                declarations += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), declarations);
            checked += 1;
        }
        try std.testing.expect(checked > 0);
    }
}

fn checkBirth(source: []const u8, es5: bool) !void {
    const utils = @import("output_scope_test_utils.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    const root = try parser.parse();
    var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    initial.is_strict_mode = parser.is_strict_mode;
    initial.is_ts = true;
    initial.enable_stmt_info = true;
    initial.enable_exact_declaration_anchors = true;
    try initial.analyze();
    try std.testing.expectEqual(@as(usize, 0), initial.errors.items.len);
    var ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var original_names: std.ArrayList(ast.NodeIndex) = .empty;
    for (parser.ast.nodes.items) |node| if (node.tag == .ts_enum_declaration) {
        const name = parser.ast.readExtraNode(node.data.extra, ast.EnumExtra.name);
        const id = initial.symbol_ids.items[@backingInt(name)] orelse return error.MissingInitialEnumId;
        try ids.put(a, id, {});
        try original_names.append(a, name);
    };
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = @import("options.zig").TransformOptions.compat.fromESTarget(if (es5) .es5 else .esnext) });
    try t.initSymbolIds(initial.symbol_ids.items);
    t.symbols = initial.symbols.items;
    t.references = initial.references.items;
    t.scopes = initial.scopes.items;
    t.scope_maps = initial.scope_maps.items;
    t.scope_owner_map = initial.scope_owner_map;
    t.node_scope_provenance = initial.node_scope_provenance;
    t.class_self_symbol_map = initial.class_self_symbol_map;
    t.namespace_member_owners = &initial.namespace_member_owners;
    t.namespace_declaration_owners = &initial.namespace_declaration_owners;
    t.unresolved_references = &initial.unresolved_references;
    t.semantic_edit_enabled = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    var parents = try utils.buildParentMap(a, t.ast, output);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    if (t.outputOwnedScope(output)) |scope| try owners.put(a, @backingInt(output), @backingInt(scope));
    var keys = parents.keyIterator();
    while (keys.next()) |raw| if (t.outputOwnedScope(@fromBackingInt(raw.*))) |scope| {
        try owners.put(a, raw.*, @backingInt(scope));
    };
    const editor = &t.semantic_editor.?;
    try std.testing.expectEqual(ids.count(), t.enum_outer_storage_bindings.count());
    var enum_writes: usize = 0;
    keys = parents.keyIterator();
    while (keys.next()) |raw| {
        const node = t.ast.nodes.items[raw.*];
        if (node.tag != .ts_enum_declaration) continue;
        const target = t.ast.readExtraNode(node.data.extra, ast.EnumExtra.name);
        try std.testing.expectEqual(.assignment_target_identifier, t.ast.getNode(target).tag);
        const id = t.getSymbolIdAt(target) orelse return error.MissingEnumWriteId;
        try std.testing.expect(ids.contains(id));
        const binding = t.enum_outer_storage_bindings.get(id) orelse return error.MissingActualEnumBinding;
        try std.testing.expect(parents.contains(@backingInt(binding)));
        const expected = utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(target)) orelse return error.MissingEnumActualOuterScope;
        const reference = (try editor.referenceForNode(target)) orelse return error.MissingEnumWriteAtBirth;
        try std.testing.expect(reference.flags.write and reference.flags.read and !reference.flags.declare);
        try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
        try std.testing.expectEqual(expected, reference.scope_id);
        try std.testing.expect(t.outputOwnedScope(@fromBackingInt(raw.*)).? != expected);
        enum_writes += 1;
    }
    try std.testing.expectEqual(original_names.items.len, enum_writes);
    var storage = t.enum_outer_storage_bindings.iterator();
    while (storage.next()) |entry| {
        const id = entry.key_ptr.*;
        const binding = entry.value_ptr.*;
        var declarations: usize = 0;
        for (editor.references.items) |reference| if (reference.flags.declare and @backingInt(reference.symbol_id) == id) {
            try std.testing.expectEqual(binding, reference.declaration_node_index);
            try std.testing.expect(parents.contains(@backingInt(binding)));
            const expected = utils.expectedScope(t.ast, output, &parents, &owners, @backingInt(binding)) orelse return error.MissingEnumDeclarationOwner;
            var storage_scope = expected;
            const declarator_node = parents.get(@backingInt(binding)).?;
            const declaration_node = t.ast.getNode(@fromBackingInt(parents.get(declarator_node).?));
            if (t.ast.variableDeclarationKind(declaration_node) == .@"var") {
                while (!editor.scopes.items[storage_scope.toIndex()].kind.isVarScope()) storage_scope = editor.scopes.items[storage_scope.toIndex()].parent;
            }
            try std.testing.expectEqual(storage_scope, reference.scope_id);
            try std.testing.expectEqual(storage_scope, editor.symbols.items[id].scope_id);
            declarations += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), declarations);
        const declarator = parents.get(@backingInt(binding)).?;
        const declaration = t.ast.getNode(@fromBackingInt(parents.get(declarator).?));
        try std.testing.expectEqual(.variable_declaration, declaration.tag);
        const kind = t.ast.variableDeclarationKind(declaration);
        const lexical = initial.symbols.items[id].kind == .variable_let;
        try std.testing.expectEqual(if (lexical and !es5) ast.VariableDeclarationKind.let else .@"var", kind);
    }
    for (original_names.items) |name| if (!parents.contains(@backingInt(name))) {
        for (editor.references.items) |reference| try std.testing.expect(!reference.flags.declare or reference.declaration_node_index != name);
    };
}

test "enum outer binding source SID actual storage and merged writes are born before finalization" {
    const sources = [_][]const u8{
        "function run(){enum E{A=7};return E.A}",
        "class C{constructor(){enum E{A=7};this.value=E.A}}",
        "class C{read(){enum E{A=7};return E.A}}",
        "class C{static{enum E{A=7};console.log(E.A)}}",
        "enum E{A=9};{enum E{A=7};console.log(E.A)}console.log(E.A)",
        "function run(){try{console.log(E)}catch(error){}enum E{A=7}}",
        "{enum E{A=7};enum E{B=9};console.log(E.A,E.B)}",
        "const all=[];for(let index=0;index<2;index++){enum E{A=index};all.push(()=>E.A)}",
        "const all=[];for(let index=0;index<2;index++){enum E{A=index};enum E{B=index+7};all.push(()=>E.A)}",
        "namespace N{export enum E{A=7}}",
        "function run(){enum E{A=9};{enum E{A=7};console.log(E.A)}console.log(E.A)}",
        "function make(){enum E{A=7};return()=>E}",
        "namespace E{export const before=3}enum E{A=7};console.log(E.before,E.A)",
        "enum E{A=7}namespace E{export const after=3};console.log(E.after,E.A)",
        "function run(){namespace E{export const before=3}enum E{A=7};return E}",
        "namespace N{export namespace E{export const before=3}export enum E{A=7}}",
        "export enum E{A=7};export enum E{B=9};console.log(E.A,E.B)",
    };
    for (sources) |source| for ([_]bool{ false, true }) |es5| {
        errdefer std.debug.print("birth es5={} source={s}\n", .{ es5, source });
        try checkBirth(source, es5);
    };
}

// Equal numeric slots from a separate parser are not the same semantic domain.
test "enum outer binding source identity import rejects foreign AST before mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "{enum E{A=7};console.log(E.A)}";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var other_scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var other = @import("../parser/parser.zig").Parser.init(a, &other_scanner);
    other.configureFromExtension(".ts");
    _ = try other.parse();
    try std.testing.expectEqual(parser.ast.nodes.items.len, other.ast.nodes.items.len);
    var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    initial.is_ts = true;
    try initial.analyze();
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{});
    try std.testing.expectError(error.InvalidSourceOwner, t.initSymbolIdsOwned(&other.ast, initial.symbol_ids.items));
    try std.testing.expectEqual(@as(usize, 0), t.enum_outer_source_ids.count());
    try t.initSymbolIdsOwned(&parser.ast, initial.symbol_ids.items);
    try std.testing.expectEqual(@as(usize, 1), t.enum_outer_source_ids.count());
}
