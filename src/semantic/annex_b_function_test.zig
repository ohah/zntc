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

test "Annex B initial lexical and variable roles in ten source environments" {
    const sources = [_][]const u8{
        "function root(){const outside=()=>/*outer*/read;{const saved=/*use*/read;function /*decl*/read(){return 42}return[saved,outside]}}",
        "function root(){const outside=()=>/*outer*/read;try{throw 42}catch(error){const saved=/*use*/read;function /*decl*/read(){return error}return[saved,outside]}}",
        "function root(){const outside=()=>/*outer*/read;try{throw{error:42}}catch({error}){const saved=/*use*/read;function /*decl*/read(){return error}return[saved,outside]}}",
        "function root(){const outside=()=>/*outer*/read;try{throw[42]}catch([error]){const saved=/*use*/read;function /*decl*/read(){return error}return[saved,outside]}}",
        "function root(){const outside=()=>/*outer*/read;{const saved=/*use*/read;function /*decl*/read(){return other()}function other(){return 42}return[saved,outside]}}",
        "function root(read){const outside=()=>/*outer*/read;{const saved=/*use*/read;function /*decl*/read(){return 42}return[saved,outside]}}",
        "function root(read=42){const outside=()=>/*outer*/read;{const saved=/*use*/read;function /*decl*/read(){return 42}return[saved,outside]}}",
        "function root(){var read;const outside=()=>/*outer*/read;{const saved=/*use*/read;function /*decl*/read(){return 42}return[saved,outside]}}",
        "function root(){const outside=()=>/*outer*/read;switch(1){case 1:const saved=/*use*/read;function /*decl*/read(){return 42}return[saved,outside]}}",
        "function root(){const outside=()=>/*outer*/read;{const saved=/*use*/read;function /*decl*/read(){return 42}return[saved,outside]}{function read(){return 99}}}",
    };
    var failed: usize = 0;
    for (sources, 0..) |source, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        const declaration = try nodeAt(&parser.ast, source, "/*decl*/", true);
        const early = try nodeAt(&parser.ast, source, "/*use*/", false);
        const outer = try nodeAt(&parser.ast, source, "/*outer*/", false);
        const lexical = analyzer.symbol_ids.items[@backingInt(declaration)].?;
        const alias = analyzer.symbols.items[lexical].annex_b_alias;
        if (index == 6) {
            try std.testing.expect(!alias.parameter_source.isNone());
            try std.testing.expect(alias.parameter_source != alias.variable);
            try std.testing.expectEqual(@import("symbol.zig").SymbolKind.parameter, analyzer.symbols.items[@backingInt(alias.parameter_source)].kind);
        }
        const early_id = analyzer.symbol_ids.items[@backingInt(early)];
        const outer_id = analyzer.symbol_ids.items[@backingInt(outer)];
        const ok = early_id == lexical and !alias.variable.isNone() and @backingInt(alias.variable) != lexical and outer_id == @backingInt(alias.variable);
        if (!ok) {
            failed += 1;
            std.debug.print("Annex B source {d}: lexical={d}, early={any}, outer={any}, alias={any}\n", .{ index, lexical, early_id, outer_id, alias });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "Annex B lexical barriers and non-ordinary declarations do not create an outer alias" {
    const sources = [_][]const u8{
        "function root(){'use strict';{function /*decl*/read(){}}}",
        "function root(){let read=1;{function /*decl*/read(){}}}",
        "function root(){{let read=1;{function /*decl*/read(){}}}}",
        "function root(){{const {read}=object;{function /*decl*/read(){}}}}",
        "function root(){{class read{};{function /*decl*/read(){}}}}",
        "function root(){{function read(){};{function /*decl*/read(){}}}}",
        "function root(){try{throw{read:1}}catch({read}){{function /*decl*/read(){}}}}",
        "function root(){{async function /*decl*/read(){}}}",
        "function root(){{function* /*decl*/read(){}}}",
        "function root(){{async function* /*decl*/read(){}}}",
        "function root(){for(let read=0;read<1;read++){{function /*decl*/read(){}}}}",
        "function root(){for(let read of []){{function /*decl*/read(){}}}}",
        "function root(){switch(1){case 0:let read;break;case 1:{function /*decl*/read(){}}}}",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(allocator, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        const declaration = try nodeAt(&parser.ast, source, "/*decl*/", true);
        const lexical = analyzer.symbol_ids.items[@backingInt(declaration)].?;
        try std.testing.expect(analyzer.symbols.items[lexical].annex_b_alias.variable.isNone());
    }
}

test "Annex B duplicate block declarations share lexical identity and explicit lowering removes only native affinity" {
    const source = "function root(){{function /*decl*/read(){return 1}function /*decl2*/read(){return 2}return /*use*/read}}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const first = analyzer.symbol_ids.items[@backingInt(try nodeAt(&parser.ast, source, "/*decl*/", true))].?;
    const second = analyzer.symbol_ids.items[@backingInt(try nodeAt(&parser.ast, source, "/*decl2*/", true))].?;
    try std.testing.expectEqual(first, second);
    const roles = @import("annex_b_function.zig");
    const id: @import("symbol.zig").SymbolId = @fromBackingInt(first);
    const role = (try roles.forSymbol(analyzer.symbols.items, id)).?;
    var native = try roles.nativeBindingMask(std.testing.allocator, analyzer.symbols.items);
    try std.testing.expect(native.isSet(first));
    try std.testing.expect(native.isSet(@backingInt(role.variable)));
    try std.testing.expectEqual(@as(u32, 2), role.source_assignment_count);
    try std.testing.expectError(error.InvalidAnnexBRole, roles.markLowered(analyzer.symbols.items, id, 1));
    const before_read = analyzer.symbols.items[first].reference_count;
    const before_write = analyzer.symbols.items[@backingInt(role.variable)].write_count;
    const lowered = try roles.markLowered(analyzer.symbols.items, id, 2);
    try std.testing.expectEqual(role.variable, lowered.variable);
    try std.testing.expectEqual(role.parameter_source, lowered.parameter_source);
    try std.testing.expectEqual(@import("symbol.zig").AnnexBFunctionAlias.State.lowered, lowered.state);
    try std.testing.expectEqual(before_read - 2, analyzer.symbols.items[first].reference_count);
    try std.testing.expectEqual(before_write - 2, analyzer.symbols.items[@backingInt(role.variable)].write_count);
    _ = try roles.markLowered(analyzer.symbols.items, id, 2);
    try std.testing.expectEqual(before_read - 2, analyzer.symbols.items[first].reference_count);
    native.deinit();
    var after = try roles.nativeBindingMask(std.testing.allocator, analyzer.symbols.items);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.count());
}
