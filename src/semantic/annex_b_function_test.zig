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
        "function root(decoy){const outside=()=>/*outer*/read;{const saved=/*use*/read;function /*decl*/read(){return 42}return[saved,outside]}}",
        "function root(decoy=42){const outside=()=>/*outer*/read;{const saved=/*use*/read;function /*decl*/read(){return 42}return[saved,outside]}}",
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
        "function root(){{async function* read(){};{function /*decl*/read(){}}}}",
        "function root(){try{throw{read:1}}catch({read}){{function /*decl*/read(){}}}}",
        "function root(){{async function /*decl*/read(){}}}",
        "function root(){{function* /*decl*/read(){}}}",
        "function root(){{async function* /*decl*/read(){}}}",
        "function root(read){{function /*decl*/read(){}}}",
        "function root(read=1){{function /*decl*/read(){}}}",
        "function root(read=1){var read;{function /*decl*/read(){}}}",
        "function root(read=1){function read(){};{function /*decl*/read(){}}}",
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

test "Annex B unbraced branches and labelled declarations retain initial identities" {
    const cases = [_]struct { source: []const u8, alias: bool }{
        .{ .source = "function root(){const outer=()=>/*use*/read;if(true)function /*decl*/read(){return 42}}", .alias = true },
        .{ .source = "function root(){const outer=()=>/*use*/read;if(false)function /*decl*/read(){return 42}}", .alias = true },
        .{ .source = "function root(){const outer=()=>/*use*/read;if(false)function other(){}else function /*decl*/read(){return 42}}", .alias = true },
        .{ .source = "function root(){const saved=/*use*/read;label:function /*decl*/read(){return 42}}", .alias = false },
        .{ .source = "function root(){const saved=/*use*/read;outer:inner:function /*decl*/read(){return 42}}", .alias = false },
        .{ .source = "function root(){{const saved=/*use*/read;label:function /*decl*/read(){return 42}}}", .alias = true },
        .{ .source = "function root(){try{throw 1}catch(error){const saved=/*use*/read;label:function /*decl*/read(){return error}}}", .alias = true },
        .{ .source = "function root(decoy){const saved=/*use*/read;label:function /*decl*/read(){return 42}}", .alias = false },
        .{ .source = "function root(decoy=1){const saved=/*use*/read;label:function /*decl*/read(){return 42}}", .alias = false },
        .{ .source = "const saved=/*use*/read;label:function /*decl*/read(){return 42}", .alias = false },
    };
    for (cases, 0..) |case, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(allocator, &parser.ast);
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        const declaration = try nodeAt(&parser.ast, case.source, "/*decl*/", true);
        const use = try nodeAt(&parser.ast, case.source, "/*use*/", false);
        const lexical = analyzer.symbol_ids.items[@backingInt(declaration)].?;
        const alias = analyzer.symbols.items[lexical].annex_b_alias.variable;
        const expected: u32 = if (index < 3) @backingInt(alias) else lexical;
        if (analyzer.symbol_ids.items[@backingInt(use)] != expected)
            std.debug.print("unbraced case {d}: declaration={d}, alias={any}, use={any}\n", .{ index, lexical, alias, analyzer.symbol_ids.items[@backingInt(use)] });
        try std.testing.expectEqual(case.alias, !alias.isNone());
        try std.testing.expectEqual(@as(?u32, expected), analyzer.symbol_ids.items[@backingInt(use)]);
    }
}

test "Annex B direct labelled function shares a simple parameter binding" {
    const source = "function root(/*param*/read){const before=/*use*/read;label:function /*decl*/read(){return 42}return arguments[0]===read}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    const parameter = try nodeAt(&parser.ast, source, "/*param*/", true);
    const declaration = try nodeAt(&parser.ast, source, "/*decl*/", true);
    const use = try nodeAt(&parser.ast, source, "/*use*/", false);
    try std.testing.expectEqual(analyzer.symbol_ids.items[@backingInt(parameter)], analyzer.symbol_ids.items[@backingInt(declaration)]);
    try std.testing.expectEqual(analyzer.symbol_ids.items[@backingInt(parameter)], analyzer.symbol_ids.items[@backingInt(use)]);
}

test "Annex B lowered catch state requires catch storage and has no native name affinity" {
    const sym = @import("symbol.zig");
    const roles = @import("annex_b_function.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "function run(){{function local(){return 1}}return local}");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var lexical: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, id| if (!symbol.annex_b_alias.variable.isNone()) {
        lexical = @intCast(id);
    };
    const id = lexical orelse return error.MissingAnnexRole;
    const original = (try roles.forSymbol(analyzer.symbols.items, @fromBackingInt(id))).?;
    _ = try roles.markLowered(analyzer.symbols.items, original.lexical, original.source_assignment_count);
    analyzer.symbols.items[id].kind = .catch_binding;
    analyzer.symbols.items[id].decl_flags = sym.SymbolKind.catch_binding.declFlags();
    analyzer.symbols.items[id].annex_b_alias.state = .lowered_catch;
    const actual = (try roles.forSymbol(analyzer.symbols.items, original.lexical)).?;
    try std.testing.expectEqual(original.lexical, actual.lexical);
    try std.testing.expectEqual(original.variable, actual.variable);
    try std.testing.expectEqual(@as(u32, 0), @backingInt(sym.AnnexBFunctionAlias.State.native));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(sym.AnnexBFunctionAlias.State.lowered));
    try std.testing.expectEqual(@as(u32, 2), @backingInt(sym.AnnexBFunctionAlias.State.lowered_catch));
    var mask = try roles.nativeBindingMask(a, analyzer.symbols.items);
    defer mask.deinit();
    try std.testing.expect(!mask.isSet(id));
    try std.testing.expect(!mask.isSet(@backingInt(original.variable)));
    for ([_]sym.SymbolKind{ .function_decl, .variable_var, .parameter }) |kind| {
        analyzer.symbols.items[id].kind = kind;
        try std.testing.expectError(error.InvalidAnnexBRole, roles.forSymbol(analyzer.symbols.items, original.lexical));
    }
    analyzer.symbols.items[id].kind = .catch_binding;
    for ([_]sym.AnnexBFunctionAlias.State{ .native, .lowered }) |state| {
        analyzer.symbols.items[id].annex_b_alias.state = state;
        try std.testing.expectError(error.InvalidAnnexBRole, roles.forSymbol(analyzer.symbols.items, original.lexical));
    }
    analyzer.symbols.items[id].annex_b_alias.state = .lowered_catch;
    try std.testing.expect(roles.validate(analyzer.symbols.items));
}

test "Annex B nested ordinary functions own distinct lexical IDs and the same outer variable" {
    const roles = @import("annex_b_function.zig");
    const cases = [_]struct { source: []const u8, inner_count: u32 }{
        .{ .source = "function run(){{function /*outer*/local(){return 1}{function /*inner*/local(){return 2}}}return local}", .inner_count = 1 },
        .{ .source = "function run(){{function /*outer*/local(){return 1}{function /*inner*/local(){return 2}function local(){return 3}}}return local}", .inner_count = 2 },
        .{ .source = "function run(){{function /*outer*/l\\u006fcal(){return 1}{function /*inner*/local(){return 2}}}return local}", .inner_count = 1 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.enable_exact_declaration_anchors = true;
        analyzer.enable_stmt_info = true;
        try analyzer.analyze();
        const outer_node = try nodeAt(&parser.ast, case.source, "/*outer*/", true);
        const inner_node = try nodeAt(&parser.ast, case.source, "/*inner*/", true);
        const outer = analyzer.symbol_ids.items[@backingInt(outer_node)].?;
        const inner = analyzer.symbol_ids.items[@backingInt(inner_node)].?;
        try std.testing.expect(outer != inner);
        const outer_role = (try roles.forSymbol(analyzer.symbols.items, @fromBackingInt(outer))) orelse return error.MissingOuterNativeAnnexRole;
        const inner_role = (try roles.forSymbol(analyzer.symbols.items, @fromBackingInt(inner))) orelse return error.MissingInnerNativeAnnexRole;
        try std.testing.expectEqual(outer_role.variable, inner_role.variable);
        try std.testing.expect(outer_role.variable != outer_role.lexical and inner_role.variable != inner_role.lexical);
        const outer_scope = analyzer.symbols.items[outer].scope_id;
        const inner_scope = analyzer.symbols.items[inner].scope_id;
        const variable_scope = analyzer.symbols.items[@backingInt(outer_role.variable)].scope_id;
        try std.testing.expect(outer_scope != inner_scope and outer_scope != variable_scope and inner_scope != variable_scope);
        try std.testing.expectEqual(outer_scope, analyzer.scopes.items[inner_scope.toIndex()].parent);
        try std.testing.expect(analyzer.scopes.items[variable_scope.toIndex()].kind.isVarScope());
        try std.testing.expectEqual(@as(u32, 1), outer_role.source_assignment_count);
        try std.testing.expectEqual(case.inner_count, inner_role.source_assignment_count);
        try std.testing.expectEqual(case.inner_count + 1, analyzer.symbols.items[@backingInt(outer_role.variable)].write_count);
        var inner_declarations: usize = 0;
        for (analyzer.references.items) |reference| if (reference.flags.declare and @backingInt(reference.symbol_id) == inner) {
            try std.testing.expectEqual(inner_scope, reference.scope_id);
            try std.testing.expect(!reference.declaration_node_index.isNone());
            inner_declarations += 1;
        };
        try std.testing.expectEqual(@as(usize, case.inner_count), inner_declarations);
    }
}

test "Annex B nested ordinary alias keeps strict lexical class async and generator barriers" {
    const cases = [_][]const u8{
        "'use strict';function run(){{function local(){}{function /*inner*/local(){}}}}",
        "function run(){{let local;{function /*inner*/local(){}}}}",
        "function run(){{const local=1;{function /*inner*/local(){}}}}",
        "function run(){{class local{}{function /*inner*/local(){}}}}",
        "function run(){{async function local(){}{function /*inner*/local(){}}}}",
        "function run(){{function* local(){}{function /*inner*/local(){}}}}",
    };
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        try analyzer.analyze();
        const binding = try nodeAt(&parser.ast, source, "/*inner*/", true);
        const sid = analyzer.symbol_ids.items[@backingInt(binding)].?;
        try std.testing.expect((try @import("annex_b_function.zig").forSymbol(analyzer.symbols.items, @fromBackingInt(sid))) == null);
    }
}
