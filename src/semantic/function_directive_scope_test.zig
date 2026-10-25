const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Analyzer = @import("analyzer.zig").SemanticAnalyzer;

fn hasStrictDirective(ast: *const Ast, body: NodeIndex) bool {
    const node = ast.getNode(body);
    if (node.tag != .block_statement) return false;
    for (ast.extra_data.items[node.data.list.start .. node.data.list.start + node.data.list.len]) |raw| {
        const statement = ast.getNode(@fromBackingInt(raw));
        if (statement.tag != .directive) break;
        const text = ast.getText(statement.span);
        if (std.mem.eql(u8, text, "'use strict'") or std.mem.eql(u8, text, "\"use strict\"")) return true;
    }
    return false;
}

test "function directive initial scopes cover ten strict function forms" {
    const sources = [_][]const u8{
        "function read(){'use strict';return this}",
        "function read(value){\"use strict\";return value}",
        "function read(){/*before*/'custom';/*between*/'use strict';return this}",
        "const read=function named(){'use strict';return named}",
        "const read=function(){'use strict';return this}",
        "const read=()=>{'use strict';return this}",
        "const object={read(){'use strict';return this}}",
        "const object={get read(){'use strict';return this}}",
        "function* read(){'use strict';yield this}",
        "async function read(){'use strict';return this}",
    };
    var incorrect: usize = 0;
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
        try std.testing.expect(!analyzer.scopes.items[0].is_strict);
        var found: usize = 0;
        var wrong = false;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            const body = parser.ast.functionBodyBlock(node) orelse continue;
            if (!hasStrictDirective(&parser.ast, body)) continue;
            const scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.MissingFunctionScope;
            found += 1;
            wrong = wrong or !analyzer.scopes.items[scope].is_strict;
        }
        try std.testing.expect(found != 0);
        if (wrong) incorrect += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), incorrect);
}

test "function directive initial scopes keep sloppy non-directive and enclosing environments" {
    const sources = [_][]const u8{
        "function read(){return this}",
        "function read(){'use\\x20strict';return this}",
        "function read(){'use\\u0020strict';return this}",
        "function read(){0;'use strict';return this}",
        "function read(){;'use strict';return this}",
        "function read(){'custom';0;'use strict';return this}",
        "const read=function(){return this}",
        "const read=()=>this",
        "const object={read(){return this}}",
        "function read(value=1){return this}",
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
        for (analyzer.scopes.items) |scope| try std.testing.expect(!scope.is_strict);
        var module_analyzer = Analyzer.init(allocator, &parser.ast);
        module_analyzer.is_module = true;
        try module_analyzer.analyze();
        for (module_analyzer.scopes.items) |scope| try std.testing.expect(scope.is_strict);
    }
}

test "function directive initial scopes prevent inner Annex B aliases without changing sloppy declaration owners" {
    const source = "function strictOuter(){'use strict';{function inner(){}}return typeof inner}function sloppyOuter(){{function inner(){'use strict';return this}}return typeof inner}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(allocator, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    var strict_scope: ?u32 = null;
    var sloppy_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        const name = parser.ast.readExtraNode(node.data.extra, 0);
        if (name.isNone()) continue;
        const text = parser.ast.getText(parser.ast.getNode(name).span);
        if (std.mem.eql(u8, text, "strictOuter")) strict_scope = analyzer.scope_owner_map.get(@intCast(raw));
        if (std.mem.eql(u8, text, "sloppyOuter")) sloppy_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    try std.testing.expect(strict_scope != null and sloppy_scope != null);
    try std.testing.expect(analyzer.scopes.items[strict_scope.?].is_strict);
    try std.testing.expect(!analyzer.scopes.items[sloppy_scope.?].is_strict);
    try std.testing.expect(analyzer.scope_maps.items[strict_scope.?].get("inner") == null);
    const sloppy_alias = analyzer.scope_maps.items[sloppy_scope.?].get("inner") orelse return error.MissingSloppyAlias;
    try std.testing.expectEqual(sloppy_scope.?, analyzer.symbols.items[sloppy_alias].scope_id.toIndex());
    // The same spelling outside the strict block is an unresolved global read,
    // while the sloppy parent's outer alias still has its own exact SID.
    var strict_unresolved: usize = 0;
    var sloppy_resolved: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.getText(node.span), "inner")) continue;
        if (analyzer.unresolved_reference_nodes.contains(@intCast(raw))) {
            try std.testing.expect(analyzer.symbol_ids.items[raw] == null);
            strict_unresolved += 1;
        } else if (analyzer.symbol_ids.items[raw] == @as(?u32, @intCast(sloppy_alias))) sloppy_resolved += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), strict_unresolved);
    try std.testing.expectEqual(@as(usize, 1), sloppy_resolved);
    try std.testing.expect(analyzer.unresolved_references.contains("inner"));
}
