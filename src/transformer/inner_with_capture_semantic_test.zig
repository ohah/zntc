const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const ast = @import("../parser/ast.zig");
const Arrow = @import("es2015_arrow.zig").ES2015Arrow(Transformer);

fn expectInnerWithCapture(source: []const u8, expected: bool) !void {
    errdefer std.debug.print("source: {s}\n", .{source});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".cjs");
    const source_root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    try analyzer.analyze();
    var t = try Transformer.init(alloc, &parser.ast, .{});
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.semantic_edit_enabled = true;
    var outer: ast.NodeIndex = .none;
    var source_object: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .object_expression) source_object = @fromBackingInt(@intCast(raw));
        if (node.tag == .arrow_function_expression) outer = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!outer.isNone());
    try std.testing.expectEqual(expected, (try Arrow.lexicalCapturesInWith(&t, outer)).any());
    if (expected) {
        t.options.unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5);
        try t.buildBlockRenameMap();
        try @import("parameter_environment.zig").collectClassInferredNames(&t);
        try @import("native_parameter_cells.zig").normalize(&t);
        const transformed = try t.visitNode(source_root);
        try std.testing.expect(t.used_unsupported_arrow_dynamic_scope);
        try std.testing.expectEqual(ast.Node.Tag.arrow_function_expression, t.ast.getNode(outer).tag);
        const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(alloc, t.ast, transformed);
        try std.testing.expect(std.mem.indexOfScalar(u32, live, @backingInt(outer)) != null);
        try std.testing.expectEqual(@as(usize, 0), t.capture_refs.items.len);
        if (std.mem.indexOf(u8, source, "super.") != null)
            try std.testing.expect(std.mem.indexOfScalar(u32, live, @backingInt(source_object)) != null);
    }
}

test "inner with lexical capture detection respects evaluation boundaries" {
    const positives = [_][]const u8{
        "function Parent(get=()=>{with({}){return new.target}}){return get}",
        "function Parent(){return()=>{with({}){return this}}}",
        "function Parent(){return()=>{with({}){return arguments}}}",
        "function Parent(){return()=>{with({}){{return new.target}}}}",
        "function Parent(){return()=>{with({}){return()=>this}}}",
        "function Parent(){return()=>{with({}){return class extends this.Base{}}}}",
        "function Parent(){return()=>{with({}){return class{[this.key](){}}}}}",
        "function Parent(){return()=>{with({}){return{[this.key](){}}}}}",
        "function Parent(){return()=>{with({}){return argum\\u0065nts}}}",
        "function Parent(){return()=>{with({}){with({}){return new.target}}}}",
        "const object={read(){return()=>{with({}){return super.value}}}};",
        "function Parent(arguments){return()=>{with({}){return arguments}}}",
        "const read=(arguments)=>()=>{with({}){return arguments[0]}};",
    };
    for (positives) |source| try expectInnerWithCapture(source, true);
    const negatives = [_][]const u8{
        "function Parent(){return()=>{with(this.object){return 1}}}",
        "function Parent(){return()=>{with({}){}return new.target}}",
        "function Parent(){return()=>{with({}){return function(){return this}}}}",
        "function Parent(){return()=>{return function(){with({}){return new.target}}}}",
        "function Parent(){return()=>{with({}){return{read(){return this}}}}}",
        "function Parent(){return()=>{with({}){return class{value=this}}}}",
        "function Parent(){return()=>{with({}){return 1}}}",
        "const read=(arguments)=>{with({}){return arguments[0]}};",
        "const read=()=>arguments=>{with({}){return arguments[0]}};",
        "const read=()=>{let arguments=[7];with({}){return arguments[0]}};",
        "const read=()=>{with({}){return object.arguments}};",
        "const read=()=>{with({}){return {arguments:7}}};",
        "const read=()=>{with({}){return {arguments(){return 7}}}};",
    };
    for (negatives) |source| try expectInnerWithCapture(source, false);
}

test "inner with lexical capture keeps static method names out of value visitation" {
    const sources = [_][]const u8{
        "const read=()=>({arguments(){return 7}});",
        "const read=()=>({async arguments(){return 7}});",
        "const read=()=>({*arguments(){yield 7}});",
        "const read=()=>({get arguments(){return 7}});",
        "const read=()=>({set arguments(value){}});",
        "function Parent(name){return()=>({[arguments[0]](){return 7}})}",
        "function Parent(name){return()=>({async [arguments[0]](){return 7}})}",
        "const read=()=>class{async arguments(){return 7}};",
        "function Parent(name){return()=>class{async [arguments[0]](){return 7}}}",
    };
    for (sources) |source| {
        for ([_]@import("transformer.zig").TransformOptions.compat.ESTarget{ .es5, .es2015 }) |target| {
            if (target == .es5 and std.mem.indexOf(u8, source, "=>class") != null) continue;
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();
            var scanner = try Scanner.init(alloc, source);
            var parser = Parser.init(alloc, &scanner);
            parser.configureFromExtension(".cjs");
            const root = try parser.parse();
            var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
            try analyzer.analyze();
            var t = try Transformer.init(alloc, &parser.ast, .{ .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(target) });
            t.options.unsupported.arrow = true;
            try t.initSymbolIds(analyzer.symbol_ids.items);
            t.symbols = analyzer.symbols.items;
            t.references = analyzer.references.items;
            t.scopes = analyzer.scopes.items;
            t.scope_maps = analyzer.scope_maps.items;
            t.scope_owner_map = analyzer.scope_owner_map;
            t.class_self_symbol_map = analyzer.class_self_symbol_map;
            t.node_scope_provenance = analyzer.node_scope_provenance;
            t.semantic_edit_enabled = true;
            var key: ast.NodeIndex = .none;
            for (parser.ast.nodes.items) |node| {
                if (node.tag == .method_definition) key = parser.ast.readExtraNode(node.data.extra, ast.MethodExtra.key);
            }
            try std.testing.expect(!key.isNone());
            const original = t.ast.getNode(key);
            const original_id = t.getSymbolIdAt(key);
            try t.buildBlockRenameMap();
            const transformed = try t.visitNode(root);
            const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(alloc, t.ast, transformed);
            if (original.tag == .computed_property_key) {
                try std.testing.expect(std.mem.indexOfScalar(u32, live, @backingInt(key)) == null);
                var captured_arguments = false;
                for (t.capture_refs.items) |reference| {
                    if (reference.kind == .arguments_value) captured_arguments = true;
                }
                try std.testing.expect(captured_arguments);
            } else {
                try std.testing.expect(std.mem.indexOfScalar(u32, live, @backingInt(key)) != null);
                try std.testing.expectEqual(original.tag, t.ast.getNode(key).tag);
                try std.testing.expectEqual(original_id, t.getSymbolIdAt(key));
            }
            try std.testing.expect(!t.used_unsupported_arrow_dynamic_scope);
            if (t.semantic_editor) |*editor| try std.testing.expect((try editor.referenceForNode(key)) == null);
        }
    }
}
