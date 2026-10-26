const std = @import("std");
const ast = @import("../parser/ast.zig");
const owner_utils = @import("output_scope_test_utils.zig");
const creator = @import("generated_static_block.zig");

fn ownerReport(a: std.mem.Allocator, t: anytype, root: ast.NodeIndex) !@import("symbol_coverage.zig").ExactReport {
    const editor = &t.semantic_editor.?;
    const maps = try a.alloc(std.StringHashMapUnmanaged(usize), editor.scopes.items.len);
    @memset(maps, .empty);
    const helpers: std.StringHashMapUnmanaged(usize) = .empty;
    const empty: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    return @import("symbol_coverage.zig").checkExact(a, t.ast, root, @intCast(t.ast.nodes.items.len), &.{}, &.{}, editor.scopes.items, maps, &editor.scope_owner_map, &.{}, &.{}, &helpers, &empty, &empty, &origins);
}

test "generated static creator native primary and canonical body are born before visiting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "class C{}");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    try initial.analyze();
    try std.testing.expect(!initial.scopes.items[0].is_strict);
    var class: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| if (node.tag == .class_declaration) {
        class = @fromBackingInt(@as(u32, @intCast(raw)));
    };
    const class_scope: @import("../semantic/scope.zig").ScopeId = @fromBackingInt(initial.scope_owner_map.get(@backingInt(class)).?);
    const class_body = parser.ast.readExtraNode(parser.ast.getNode(class).data.extra, ast.ClassExtra.body);
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{});
    try t.initSymbolIdsOwned(&parser.ast, initial.symbol_ids.items);
    t.symbols = initial.symbols.items;
    t.references = initial.references.items;
    t.scopes = initial.scopes.items;
    t.scope_maps = initial.scope_maps.items;
    t.scope_owner_map = initial.scope_owner_map;
    t.class_self_symbol_map = initial.class_self_symbol_map;
    t.semantic_edit_enabled = true;
    const body = try t.ast.addListNode(.block_statement, .EMPTY, try t.ast.addNodeList(&.{}));
    // Intrinsic static strictness must not depend on an already-strict parent.
    const block = try creator.create(&t, @fromBackingInt(0), body, .EMPTY);
    const editor = &t.semantic_editor.?;
    try std.testing.expectEqual(.class_static_block, editor.scopes.items[block.scope.toIndex()].kind);
    try std.testing.expect(editor.scopes.items[block.scope.toIndex()].kind.isVarScope());
    try std.testing.expect(editor.scopes.items[block.scope.toIndex()].is_strict);
    try std.testing.expectEqual(@as(?u32, @backingInt(block.scope)), editor.scope_owner_map.get(@backingInt(block.node)));
    try std.testing.expectEqual(@as(?u32, @backingInt(block.scope)), editor.scope_owner_map.get(@backingInt(body)));
    t.ast.nodes.items[@backingInt(class_body)].data.list = try t.ast.addNodeList(&.{block.node});
    const wrong_parent = try ownerReport(a, &t, root);
    try std.testing.expect(wrong_parent.scope_owner_parent_mismatch > 0);
    try t.reparentGeneratedScope(block.scope, class_scope);
    const positive = try ownerReport(a, &t, root);
    try std.testing.expectEqual(@as(usize, 0), positive.scope_owner_mismatch);
    try std.testing.expectEqual(@as(usize, 0), positive.scope_owner_parent_mismatch);
    try std.testing.expectEqual(@as(usize, 0), positive.duplicate_scope_owner);
    _ = editor.scope_owner_map.remove(@backingInt(block.node));
    try std.testing.expect((try ownerReport(a, &t, root)).scope_owner_mismatch > 0);
    try editor.scope_owner_map.put(a, @backingInt(block.node), @backingInt(block.scope));
    try editor.scope_owner_map.put(a, @backingInt(body), @backingInt(class_scope));
    try std.testing.expect((try ownerReport(a, &t, root)).scope_owner_mismatch > 0);
    try editor.scope_owner_map.put(a, @backingInt(body), @backingInt(block.scope));
    editor.scopes.items[block.scope.toIndex()].kind = .function;
    try std.testing.expect((try ownerReport(a, &t, root)).scope_owner_mismatch > 0);
    editor.scopes.items[block.scope.toIndex()].kind = .class_static_block;
    editor.scopes.items[block.scope.toIndex()].is_strict = false;
    try std.testing.expect((try ownerReport(a, &t, root)).scope_strictness_mismatch > 0);
    editor.scopes.items[block.scope.toIndex()].is_strict = true;
    const nested = try t.ast.addListNode(.block_statement, .EMPTY, try t.ast.addNodeList(&.{}));
    t.ast.nodes.items[@backingInt(body)].data.list = try t.ast.addNodeList(&.{nested});
    try editor.scope_owner_map.put(a, @backingInt(nested), @backingInt(block.scope));
    try std.testing.expect((try ownerReport(a, &t, root)).duplicate_scope_owner > 0);
    _ = editor.scope_owner_map.remove(@backingInt(nested));
    t.ast.nodes.items[@backingInt(body)].data.list = try t.ast.addNodeList(&.{});
    const restored = try ownerReport(a, &t, root);
    try std.testing.expectEqual(@as(usize, 0), restored.scope_owner_mismatch);
    const output = try t.visitNode(root);
    var parents = try owner_utils.buildParentMap(a, t.ast, output);
    var found: usize = 0;
    var nodes = parents.keyIterator();
    while (nodes.next()) |raw| {
        const node = t.ast.nodes.items[raw.*];
        if (node.tag != .static_block) continue;
        try std.testing.expectEqual(block.scope, t.outputOwnedScope(@fromBackingInt(raw.*)).?);
        try std.testing.expectEqual(block.scope, t.outputOwnedScope(node.data.unary.operand).?);
        found += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), found);
    t.ast.transformed_root = output;
    const edited = (try t.finishSemanticEdit()).?;
    nodes = parents.keyIterator();
    while (nodes.next()) |raw| {
        const node = t.ast.nodes.items[raw.*];
        if (node.tag != .static_block) continue;
        try std.testing.expectEqual(@as(?u32, @backingInt(block.scope)), edited.scope_owner_map.get(raw.*));
        try std.testing.expectEqual(@as(?u32, @backingInt(block.scope)), edited.scope_owner_map.get(@backingInt(node.data.unary.operand)));
        // Editor.finish transfers its maps away. The live Transformer reader
        // must still retain both published owner edges after that handoff.
        try std.testing.expectEqual(block.scope, t.outputOwnedScope(@fromBackingInt(raw.*)).?);
        try std.testing.expectEqual(block.scope, t.outputOwnedScope(node.data.unary.operand).?);
    }
}
const Case = struct { source: []const u8, native: []const u8, legacy: bool = false, assign: bool = false, erased: bool = false };
const cases = [_]Case{
    .{ .source = "function id(v){return v}@id class C{}console.log(new C() instanceof C)", .native = "class C{}console.log(new C() instanceof C)" },
    .{ .source = "function id(v){return v}class C{@id value=2}console.log(new C().value)", .native = "class C{value=2}console.log(new C().value)" },
    .{ .source = "const out=[];function add(v,c){c.addInitializer(function(){out.push(7)});return v}class C{@add static read(){}static value=(out.push(8),1)}console.log(out.join(),C.value)", .native = "const out=[];class C{static read(){}static{out.push(7)}static value=(out.push(8),1)}console.log(out.join(),C.value)" },
    .{ .source = "const out=[];function add(v,c){c.addInitializer(function(){out.push(7)});return v}class C{@add static read(){}static{out.push(9)}}console.log(out.join())", .native = "const out=[];class C{static read(){}static{out.push(7)}static{out.push(9)}}console.log(out.join())" },
    .{ .source = "function id(v){return v}class C{@id accessor value=3}console.log(new C().value)", .native = "class C{#value=3;get value(){return this.#value}set value(v){this.#value=v}}console.log(new C().value)" },
    .{ .source = "function id(v){return v}@id export default class{static value=7;static{console.log(this.name,this.value)}}", .native = "export default class{static value=7;static{console.log(this.name,this.value)}}", .legacy = true },
    .{ .source = "class C{static value=3;static{}}console.log(C.value)", .native = "class C{static value=3;static{}}console.log(C.value)", .assign = true },
    .{ .source = "let n=0;const key=()=>{n++;return 'x'};class C{static[key()]=4;static{}}console.log(n,C.x)", .native = "let n=0;const key=()=>{n++;return 'x'};class C{static[key()]=4;static{}}console.log(n,C.x)", .assign = true },
    .{ .source = "class C{static value=()=>this;static{}}console.log(C.value()===C)", .native = "class C{static value=()=>this;static{}}console.log(C.value()===C)", .assign = true },
    .{ .source = "declare class Erased{static value:number}console.log('erased')", .native = "console.log('erased')", .erased = true },
};

fn beforeWalker(case: Case, target: @import("compat.zig").ESTarget) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, case.source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".mts");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    initial.is_ts = true;
    initial.is_module = true;
    initial.enable_stmt_info = true;
    initial.enable_exact_declaration_anchors = true;
    try initial.analyze();
    try std.testing.expectEqual(@as(usize, 0), initial.errors.items.len);
    const unsupported = @import("options.zig").TransformOptions.compat.fromESTarget(target);
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{
        .unsupported = unsupported,
        .experimental_decorators = case.legacy,
        .use_define_for_class_fields = !case.assign and !case.legacy,
    });
    try t.initSymbolIdsOwned(&parser.ast, initial.symbol_ids.items);
    t.symbols = initial.symbols.items;
    t.references = initial.references.items;
    t.scopes = initial.scopes.items;
    t.scope_maps = initial.scope_maps.items;
    t.scope_owner_map = initial.scope_owner_map;
    t.class_self_symbol_map = initial.class_self_symbol_map;
    t.node_scope_provenance = initial.node_scope_provenance;
    t.unresolved_references = &initial.unresolved_references;
    t.semantic_edit_enabled = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    var parents = try owner_utils.buildParentMap(a, t.ast, output);
    const retained = !unsupported.class and !unsupported.class_static_block;
    var blocks: usize = 0;
    var nodes = parents.keyIterator();
    while (nodes.next()) |raw| {
        const node = t.ast.nodes.items[raw.*];
        if (node.tag != .static_block) continue;
        try std.testing.expect(retained);
        const scope = t.outputOwnedScope(@fromBackingInt(raw.*)) orelse return error.MissingGeneratedStaticPrimary;
        try std.testing.expectEqual(scope, t.outputOwnedScope(node.data.unary.operand).?);
        const editor = &t.semantic_editor.?;
        try std.testing.expectEqual(.class_static_block, editor.scopes.items[scope.toIndex()].kind);
        try std.testing.expect(editor.scopes.items[scope.toIndex()].kind.isVarScope());
        try std.testing.expect(editor.scopes.items[scope.toIndex()].is_strict);
        const class_body = parents.get(raw.*).?;
        try std.testing.expectEqual(.class_body, t.ast.nodes.items[class_body].tag);
        const class_node: ast.NodeIndex = @fromBackingInt(parents.get(class_body).?);
        try std.testing.expectEqual(t.outputOwnedScope(class_node).?, editor.scopes.items[scope.toIndex()].parent);
        blocks += 1;
    }
    if (retained and !case.erased) try std.testing.expect(blocks > 0) else try std.testing.expectEqual(@as(usize, 0), blocks);
}

test "generated static creator ten native removed and lowered actual owner controls" {
    for (cases) |case| for ([_]@import("compat.zig").ESTarget{ .es2022, .es2021, .es5 }) |target| {
        errdefer std.debug.print("static creator target={s} source={s}\n", .{ @tagName(target), case.source });
        try beforeWalker(case, target);
    };
}

test "generated static creator distinguishes every class and static feature role" {
    for ([_]bool{ false, true }) |lower_class| for ([_]bool{ false, true }) |lower_static| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "");
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        _ = try parser.parse();
        var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try initial.analyze();
        var unsupported = @import("options.zig").TransformOptions.compat.fromESTarget(.esnext);
        unsupported.class = lower_class;
        unsupported.class_static_block = lower_static;
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = unsupported });
        try t.initSymbolIdsOwned(&parser.ast, initial.symbol_ids.items);
        t.symbols = initial.symbols.items;
        t.references = initial.references.items;
        t.scopes = initial.scopes.items;
        t.scope_maps = initial.scope_maps.items;
        t.scope_owner_map = initial.scope_owner_map;
        t.semantic_edit_enabled = true;
        const body = try t.ast.addListNode(.block_statement, .EMPTY, try t.ast.addNodeList(&.{}));
        const generated = try creator.create(&t, @fromBackingInt(0), body, .EMPTY);
        const editor = &t.semantic_editor.?;
        if (!lower_class and !lower_static) {
            try std.testing.expectEqual(.class_static_block, editor.scopes.items[generated.scope.toIndex()].kind);
            try std.testing.expect(editor.scopes.items[generated.scope.toIndex()].is_strict);
            try std.testing.expect(editor.scopes.items[generated.scope.toIndex()].kind.isVarScope());
            try std.testing.expectEqual(generated.scope, t.outputOwnedScope(generated.node).?);
        } else {
            try std.testing.expectEqual(.block, editor.scopes.items[generated.scope.toIndex()].kind);
            try std.testing.expect(!editor.scopes.items[generated.scope.toIndex()].is_strict);
            try std.testing.expect(!editor.scopes.items[generated.scope.toIndex()].kind.isVarScope());
            try std.testing.expect(t.outputOwnedScope(generated.node) == null);
        }
        try std.testing.expectEqual(generated.scope, t.outputOwnedScope(body).?);
    };
}
