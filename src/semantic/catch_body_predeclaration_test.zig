const std = @import("std");
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Analyzer = @import("analyzer.zig").SemanticAnalyzer;

fn nodeAt(ast: *const @import("../parser/ast.zig").Ast, source: []const u8, marker: []const u8, declaration: bool) !NodeIndex {
    const start = (std.mem.indexOf(u8, source, marker) orelse return error.MissingMarker) + marker.len;
    for (ast.nodes.items, 0..) |node, raw| {
        if (node.span.start != start) continue;
        if (declaration and node.tag == .binding_identifier or !declaration and node.tag == .identifier_reference)
            return @fromBackingInt(@as(u32, @intCast(raw)));
    }
    return error.MissingMarkedNode;
}

test "named catch bodies bind early function reads and mutual references in ten contexts" {
    const sources = [_][]const u8{
        "export function* root(){try{throw 42}catch(error){const saved=/*use*/read;yield 0;function /*decl*/read(){return error}return[saved===read,read()]}}",
        "export function root(){try{throw 42}catch(error){const saved=/*use*/read;function /*decl*/read(){return error}return saved()}}",
        "export function* root(){try{throw 42}catch(error){const saved=/*use*/read;yield 0;function /*decl*/read(){return /*use2*/other()}function /*decl2*/other(){return error}return saved()}}",
        "export function root(){try{throw{error:42}}catch({error}){const saved=/*use*/read;function /*decl*/read(){return error}return saved()}}",
        "export function root(){try{throw[42]}catch([error]){const saved=/*use*/read;function /*decl*/read(){return error}return saved()}}",
        "export function root(){try{throw{one:1,error:42}}catch({one,error}){const saved=/*use*/read;function /*decl*/read(){return error+one}return saved()}}",
        "export function root(){try{throw 1}catch(outer){try{throw 42}catch(error){const saved=/*use*/read;function /*decl*/read(){return error+outer}return saved()}}}",
        "export function root(){try{throw 42}catch(error){class Box{[/*use*/read()](){return error}}function /*decl*/read(){return'method'}return Box}}",
        "export function root(){try{throw 42}catch(error){function build(value=/*use*/read()){return value}function /*decl*/read(){return error}return build()}}",
        "export function root(read){try{throw 42}catch(error){const saved=/*use*/read;function /*decl*/read(){return error}return saved()}}",
    };
    var mismatches: usize = 0;
    var missing: usize = 0;
    var wrong: usize = 0;
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        scanner.is_module = true;
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.is_module = true;
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var failed = false;
        for ([_][2][]const u8{ .{ "/*use*/", "/*decl*/" }, .{ "/*use2*/", "/*decl2*/" } }) |markers| {
            if (std.mem.indexOf(u8, source, markers[0]) == null) continue;
            const use = try nodeAt(&parser.ast, source, markers[0], false);
            const declaration = try nodeAt(&parser.ast, source, markers[1], true);
            const expected = analyzer.symbol_ids.items[@backingInt(declaration)] orelse return error.MissingDeclarationIdentity;
            try std.testing.expectEqual(@import("scope.zig").ScopeKind.block, analyzer.scopes.items[analyzer.symbols.items[expected].scope_id.toIndex()].kind);
            const actual = analyzer.symbol_ids.items[@backingInt(use)];
            if (actual != expected) {
                failed = true;
                if (actual == null) missing += 1 else wrong += 1;
                continue;
            }
            var references: usize = 0;
            for (analyzer.references.items) |reference| {
                if (reference.node_index != use) continue;
                references += 1;
                try std.testing.expectEqual(expected, @backingInt(reference.symbol_id));
                try std.testing.expect(reference.flags.read);
            }
            try std.testing.expectEqual(@as(usize, 1), references);
        }
        if (failed) mismatches += 1;
    }
    if (mismatches != 0) std.debug.print("catch predeclaration: contexts {d}, missing references {d}, wrong valid IDs {d}\n", .{ mismatches, missing, wrong });
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

fn expectMarkedBindings(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    scanner.is_module = true;
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.is_module = true;
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    for ([_][2][]const u8{ .{ "/*use*/", "/*decl*/" }, .{ "/*use2*/", "/*decl2*/" } }) |markers| {
        if (std.mem.indexOf(u8, source, markers[0]) == null) continue;
        const use = try nodeAt(&parser.ast, source, markers[0], false);
        const declaration = try nodeAt(&parser.ast, source, markers[1], true);
        const expected = analyzer.symbol_ids.items[@backingInt(declaration)] orelse return error.MissingDeclarationIdentity;
        try std.testing.expectEqual(@as(?u32, expected), analyzer.symbol_ids.items[@backingInt(use)]);
    }
}

test "named catch bodies retain ten ordinary block parameter and post-declaration controls" {
    for ([_][]const u8{
        "export function root(){try{throw 42}catch{const saved=/*use*/read;function /*decl*/read(){return 42}return saved()}}",
        "export function root(){try{throw{}}catch({}){const saved=/*use*/read;function /*decl*/read(){return 42}return saved()}}",
        "export function root(){try{throw[]}catch([]){const saved=/*use*/read;function /*decl*/read(){return 42}return saved()}}",
        "export function root(){try{throw 42}catch(error){{const saved=/*use*/read;function /*decl*/read(){return error}}{const saved=/*use2*/read;function /*decl2*/read(){return error+1}}}}",
        "export function root(){try{throw 42}catch(error){function /*decl*/read(){return error}const saved=/*use*/read;return saved()}}",
        "export function root(){try{throw 42}catch(error){const /*decl*/value=error;return /*use*/value}}",
        "export function root(){try{throw 42}catch(error){let /*decl*/value=error;return /*use*/value}}",
        "export function root(){try{throw 42}catch(error){class /*decl*/Box{}return /*use*/Box}}",
        "export function root(){try{throw 42}catch(/*decl2*/error){function /*decl*/read(){return /*use2*/error}return /*use*/read}}",
        "export function root(/*decl2*/read){try{throw 42}catch(error){function /*decl*/local(){return error}const saved=/*use*/local}return /*use2*/read}",
    }) |source| try expectMarkedBindings(source);
}

test "named catch bodies predeclare lexical TDZ binding identity before initialization" {
    for ([_][]const u8{
        "export function root(){let value=99;try{throw 42}catch(error){const saved=/*use*/value;let /*decl*/value=error;return saved}}",
        "export function root(){let value=99;try{throw 42}catch(error){const saved=/*use*/value;const /*decl*/value=error;return saved}}",
        "export function root(){let Box=99;try{throw 42}catch(error){const saved=/*use*/Box;class /*decl*/Box{}return saved}}",
        "export function root(){let value=99;try{throw 42}catch(error){const saved=/*use*/value;let[/*decl*/value]=[error];return saved}}",
    }) |source| try expectMarkedBindings(source);
}

test "named catch bodies create declaration and read statement coordinates in their own list" {
    const source = "const pad=0;export function root(){const one=1;const two=2;const three=3;try{throw 42}catch(error){const saved=/*use*/read;function /*decl*/read(){return error}return saved()}}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    scanner.is_module = true;
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.is_module = true;
    _ = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const use = try nodeAt(&parser.ast, source, "/*use*/", false);
    const declaration = try nodeAt(&parser.ast, source, "/*decl*/", true);
    var reads: usize = 0;
    var declarations: usize = 0;
    for (analyzer.references.items) |reference| {
        if (reference.node_index == use) {
            reads += 1;
            try std.testing.expectEqual(@as(u32, 1), reference.stmt_idx);
            try std.testing.expectEqual(@as(u32, 0), reference.scope_stmt_idx);
        }
        if (reference.flags.declare and reference.declaration_node_index == declaration) {
            declarations += 1;
            try std.testing.expectEqual(@as(u32, 1), reference.stmt_idx);
            try std.testing.expectEqual(@as(u32, 1), reference.scope_stmt_idx);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 1), declarations);
}

test "named catch bodies preserve lexical conflict diagnostics and simple var allowance" {
    const sources = [_][]const u8{
        "try{}catch(error){let error}",
        "try{}catch(error){const error=1}",
        "try{}catch(error){class error{}}",
        "try{}catch(error){function error(){}}",
        "try{}catch({error}){let error}",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        scanner.is_module = true;
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.is_module = true;
        _ = try parser.parse();
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.is_module = true;
        try analyzer.analyze();
        try std.testing.expect(parser.errors.items.len + analyzer.errors.items.len > 0);
    }
    try expectMarkedBindings("export function root(){try{throw 42}catch(/*decl*/error){var error;return /*use*/error}}");
}
