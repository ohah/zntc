const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const Options = @import("transformer.zig").TransformOptions;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Using = @import("es2025_using.zig").ES2025Using(Transformer);

const sources = [_][]const u8{
    "using value=null;const read=()=>value;read();",
    "function run(){using value=null;const read=()=>value;read();}",
    "function run(){{using value=null;const read=()=>value;read();}}",
    "async function run(){await using value=null;const read=()=>value;read();}",
    "function* run(){using value=null;const read=()=>value;yield read();}",
    "function run(){try{using value=null;const read=()=>value;read();}finally{}}",
    "function run(){try{throw 1;}catch(error){using value=null;const read=()=>value;read();}}",
    "class Box{run(){using value=null;const read=()=>value;read();}}",
    "const run=()=>{using value=null;const read=()=>value;read();};",
    "for(let index=0;index<1;index++){using value=null;const read=()=>value;read();}",
    "function run(){using value=null;const read=()=>value;read();import('./dep.cjs');}",
    "function run(){using value=null;const read=()=>{import('./dep.cjs');return value;};read();}",
};

fn checkCase(source: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_module = parser.is_module;
    analyzer.is_strict_mode = parser.is_strict_mode;
    try analyzer.analyze();
    var transformer = try Transformer.init(a, &parser.ast, .{
        .unsupported = Options.compat.fromESTarget(.es2022),
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.helper_scope_map = analyzer.helper_scope_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    const Work = struct { node: ast.NodeIndex, scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    try stack.append(a, .{ .node = root, .scope = @fromBackingInt(@as(u32, 0)) });
    var owner: ast.NodeIndex = .none;
    var owner_scope: ScopeId = .none;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const node = transformer.ast.getNode(work.node);
        const scope: ScopeId = if (analyzer.scope_owner_map.get(@backingInt(work.node))) |raw| @fromBackingInt(raw) else work.scope;
        if ((node.tag == .program or node.tag == .block_statement) and
            Using.hasUsingDeclaration(&transformer, node.data.list.start, node.data.list.len))
        {
            owner = work.node;
            owner_scope = scope;
            break;
        }
        var children = walk.children(transformer.ast, node);
        while (children.next()) |child| try stack.append(a, .{ .node = child, .scope = scope });
    }
    try std.testing.expect(!owner.isNone() and !owner_scope.isNone());
    transformer.current_scope = owner_scope;
    const list = transformer.ast.getNode(owner).data.list;
    const rewritten = try Using.rewriteUsingStatementsWithOwner(&transformer, list.start, list.len, if (owner == root) .program else .body);
    try std.testing.expect(!rewritten.disposal_try.isNone());
    const region = transformer.ast.getNode(rewritten.disposal_try);
    const try_body = region.data.ternary.a;
    const catch_clause = region.data.ternary.b;
    const catch_body = transformer.ast.getNode(catch_clause).data.binary.right;
    const finally_body = region.data.ternary.c;
    const try_scope = transformer.outputOwnedScope(try_body) orelse return error.MissingTryBlockScope;
    const catch_scope = transformer.outputOwnedScope(catch_clause) orelse return error.MissingCatchScope;
    const catch_body_scope = transformer.outputOwnedScope(catch_body) orelse return error.MissingCatchBodyScope;
    const finally_scope = transformer.outputOwnedScope(finally_body) orelse return error.MissingFinallyScope;
    const editor = &transformer.semantic_editor.?;
    try std.testing.expectEqual(analyzer.scopes.items.len + 4, editor.scopes.items.len);
    try std.testing.expectEqual(analyzer.symbols.items.len + 6, editor.symbols.items.len);
    const catch_param = transformer.ast.getNode(catch_clause).data.binary.left;
    const catch_id = transformer.getSymbolIdAt(catch_param).?;
    try std.testing.expectEqual(catch_scope, editor.symbols.items[catch_id].scope_id);
    var catch_declarations: usize = 0;
    for (editor.references.items) |reference| {
        if (!reference.flags.declare or reference.declaration_node_index != catch_param) continue;
        try std.testing.expectEqual(catch_id, @backingInt(reference.symbol_id));
        try std.testing.expectEqual(catch_scope, reference.scope_id);
        catch_declarations += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), catch_declarations);
    for ([_]ScopeId{ try_scope, catch_scope, finally_scope }) |scope|
        try std.testing.expectEqual(owner_scope, editor.scopes.items[scope.toIndex()].parent);
    try std.testing.expectEqual(catch_scope, editor.scopes.items[catch_body_scope.toIndex()].parent);
    for ([_]ScopeId{ try_scope, catch_body_scope, finally_scope }) |scope|
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.block, editor.scopes.items[scope.toIndex()].kind);
    // Source bindings retain identity while their emitted lexical storage and
    // direct references move into the exact new try block. Nested closures
    // retain their own ScopeId and move only their lexical parent.
    stack.clearRetainingCapacity();
    try stack.append(a, .{ .node = try_body, .scope = try_scope });
    var try_references: usize = 0;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const n = transformer.ast.getNode(work.node);
        const scope = transformer.outputOwnedScope(work.node) orelse work.scope;
        if (n.tag == .import_expression) {
            const provenance = editor.node_scope_provenance.get(work.node) orelse return error.MissingImportCreationProvenance;
            try std.testing.expectEqual(scope, provenance.scope);
            try std.testing.expectEqual(work.node, provenance.source_node);
        }
        if (n.tag == .arrow_function_expression) {
            try std.testing.expectEqual(try_scope, editor.scopes.items[scope.toIndex()].parent);
        }
        if (n.tag == .identifier_reference or n.tag == .assignment_target_identifier) {
            const edge = (try editor.referenceForNode(work.node)) orelse return error.MissingTryCreationReference;
            try std.testing.expectEqual(scope, edge.scope_id);
            try_references += 1;
        }
        if (n.tag == .binding_identifier) {
            const sid = transformer.getSymbolIdAt(work.node) orelse return error.MissingSourceStorageIdentity;
            if (sid < analyzer.symbols.items.len) {
                const original = analyzer.symbols.items[sid];
                if (original.scope_id == owner_scope and original.kind.isBlockScoped()) {
                    try std.testing.expectEqual(if (owner == root) owner_scope else try_scope, editor.symbols.items[sid].scope_id);
                }
            }
        }
        var children = walk.children(transformer.ast, n);
        while (children.next()) |child| try stack.append(a, .{ .node = child, .scope = scope });
    }
    try std.testing.expect(try_references >= 4);
    for ([_]struct { node: ast.NodeIndex, scope: ScopeId }{
        .{ .node = catch_body, .scope = catch_body_scope },
        .{ .node = finally_body, .scope = finally_scope },
    }) |body| {
        var pending: std.ArrayList(ast.NodeIndex) = .empty;
        try pending.append(a, body.node);
        var references: usize = 0;
        while (pending.pop()) |node| {
            if (node.isNone()) continue;
            if (transformer.ast.getNode(node).tag == .identifier_reference or transformer.ast.getNode(node).tag == .assignment_target_identifier) {
                const edge = (try editor.referenceForNode(node)) orelse return error.MissingCreationReference;
                try std.testing.expectEqual(body.scope, edge.scope_id);
                try std.testing.expect(!edge.flags.declare);
                references += 1;
            }
            var children = walk.children(transformer.ast, transformer.ast.getNode(node));
            while (children.next()) |child| try pending.append(a, child);
        }
        try std.testing.expect(references >= 3);
    }
}

test "using cleanup block owners and references exist before output finalization" {
    var failures: usize = 0;
    for (sources, 0..) |source, index| checkCase(source) catch |err| {
        std.debug.print("using block producer case={d} failure={s} source={s}\n", .{ index, @errorName(err), source });
        failures += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), failures);
}
