const std = @import("std");
const Options = @import("options.zig").TransformOptions;
const sources = [_][]const u8{
    "function run(){for(let i=0;i<2;i++){function local(){return i}}return local()}console.log(run());",
    "function run(){for(let i=0;i<2;i++){try{throw 0}catch{function local(){return i}}}return local()}console.log(run());",
    "function run(){const events=[];for(let i=0;i<2;i++){events.push(local());function local(){return i}}return [events,local()]}console.log(JSON.stringify(run()));",
    "function run(){for(let i=0;i<2;i++){function local(){return i+10}function local(){return i+20}}return local()}console.log(run());",
    "function run(){for(let i=0;i<3;i++){if(i<2){function local(){return i}}}return local()}console.log(run());",
    "function run(){for(let i=0;i<2;i++){function \\u006cocal(){return i}}return [local(),local.name]}console.log(JSON.stringify(run()));",
    "function run(){for(let i=0;i<2;i++){function __proto__(){return i}}return [__proto__(),__proto__.name]}console.log(JSON.stringify(run()));",
    "function run(){const out=[];for(let i=0;i<2;i++){function local(){return i}out.push(()=>local)}return out.map(get=>get()())}console.log(JSON.stringify(run()));",
    "function run(){for(let i=0;i<2;i++){local=()=>i+10;function local(){return i}}return local()}console.log(run());",
    "function run(){const get=()=>local;for(let i=0;i<2;i++){function local(){return i}}return get()()}console.log(run());",
    "function run(){const out=[];for(let i=0;i<2;i++){function local(n){return n?local(n-1):i}out.push(local)}return out.map(fn=>fn(1))}console.log(JSON.stringify(run()));",
    "function run(){for(let i=0;i<2;i++){class Nested{read(){return i}}function local(){return new Nested().read()}}return local()}console.log(run());",
    "function run(){const out=[];for(let i=0;i<2;i++){out.push(eval('typeof local'));function local(){return i}}return out}console.log(JSON.stringify(run()));",
    "function run(){const out=[];for(let i=0;i<2;i++){function local(){return i}out.push(eval('local()'));}return out}console.log(JSON.stringify(run()));",
    "function run(){const out=[];for(let i=0;i<2;i++){{function local(){return i}out.push(eval('local()'))}{function local(){return i+10}out.push(eval('local()'))}}return [out,local()]}console.log(JSON.stringify(run()));",
    "function run(){const out=[];for(let i=0;i<2;i++){function local(){return i}out.push(eval('local()'));{function local(){return i+10}out.push(eval('local()'))}out.push(eval('local()'))}return [out,local()]}console.log(JSON.stringify(run()));",
    "function run(){const out=[];const change=()=>{local=()=>99};for(let i=0;i<2;i++){function local(){return i}out.push(local);change();out.push(()=>eval('local()'));}return [out.map(fn=>fn()),local()]}console.log(JSON.stringify(run()));",
    "function run(){const out=[];for(let i=0;i<2;i++){try{throw 0}catch{function local(){return i}out.push(eval('local()'));}}return [out,local()]}console.log(JSON.stringify(run()));",
    "function run(){const out=[];for(let i=0;i<2;i++){function __proto__(){return i}out.push(eval('__proto__()'));}return [out,__proto__.name]}console.log(JSON.stringify(run()));",
    "const out=[];for(let i=0;i<2;i++){function local(){return i}out.push(eval('local()'));}console.log(JSON.stringify([out,local()]));",
    "function run(){var local=()=>99;for(let i=0;i<2;i++){function local(){return i}}return local()}console.log(run());",
};

test "extracted loop Annex B keeps outer storage source-position writes and lexical entry hoisting" {
    for (sources, 0..) |source, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| for ([_]bool{ false, true }) |keep_names| {
            const result = try @import("../transpile.zig").transpile(a, source, "loop.js", .{
                .unsupported = Options.compat.fromESTarget(.es5),
                .minify_identifiers = minify,
                .keep_names = keep_names,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("loop Annex B source={d} min={any} keep={any}\ncode:{s}\nactual:{s}\nstderr:{s}\n", .{ index, minify, keep_names, result.code, actual.stdout, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "extracted loop Annex B published references match independent live AST scopes" {
    const Ast = @import("../parser/ast.zig");
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const walk = @import("../parser/ast_walk.zig");
    const T = @import("transformer.zig").Transformer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, sources[7]);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.enable_stmt_info = true;
    try analyzer.analyze();
    var t = try T.init(a, &parser.ast, .{ .unsupported = Options.compat.fromESTarget(.es5) });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    try t.buildBlockRenameMap();
    const output = try t.visitNode(root);
    try t.registerGeneratedFunctionScopes(output, t.programScope());
    const Generator = @import("es2015_generator.zig").ES2015Generator(T);
    try Generator.appendAnnexBVariableStorage(&t, output);
    try Generator.projectFunctionStorageCoordinates(&t, output);
    const Work = struct { node: Ast.NodeIndex, scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    try stack.append(a, .{ .node = output, .scope = t.programScope() });
    var observed: usize = 0;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const raw = @backingInt(work.node);
        const node = t.ast.getNode(work.node);
        const scope = if (t.scope_owner_removed.contains(raw)) work.scope else t.outputOwnedScope(work.node) orelse work.scope;
        if (t.generator_function_coordinate_handoffs.get(raw)) |known| {
            observed += 1;
            try std.testing.expectEqual(known.scope, scope);
            const row = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingPublishedAnnexReference;
            try std.testing.expectEqual(known.symbol_id, row.symbol_id);
            try std.testing.expectEqual(known.scope, row.scope_id);
        }
        var children = walk.children(t.ast, node);
        while (children.next()) |child| {
            const outside = @import("transformer/semantic_edit.zig").childSkipsOutputScope(t.ast, raw, @backingInt(child));
            try stack.append(a, .{ .node = child, .scope = if (outside) work.scope else scope });
        }
    }
    try std.testing.expect(observed > 0);
}

test "extracted loop Annex B arrow formal normalization preserves public grammar and argument shadows" {
    const controls = [_][]const u8{
        "const read=value=>value+1;console.log(read(41));",
        "const read=(first,second)=>first+second;console.log(read(20,22));",
        "const read=(value=42)=>value;console.log(read());",
        "const read=(...rest)=>rest[0]+rest[1];console.log(read(20,22));",
        "const read=({value})=>value;console.log(read({value:42}));",
        "const read=([value])=>value;console.log(read([42]));",
        "function outer(){return ((arguments)=>arguments)(42)}console.log(outer());",
        "function outer(){const read=value=>[value,arguments[0]];return read(2)}console.log(JSON.stringify(outer(40)));",
        "class Box{method(){return (value=>[this instanceof Box,value])(42)}}console.log(JSON.stringify(new Box().method()));",
        "(function(){const read=({value=21},other=21)=>value+other;console.log(read({}));})();",
    };
    for (controls, 0..) |source, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(a, source, "arrow.cjs", .{ .unsupported = Options.compat.fromESTarget(.es5), .minify_identifiers = minify });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("arrow formal control={d} code:{s}\nactual:{s}\nstderr:{s}\n", .{ index, result.code, actual.stdout, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "extracted loop Annex B arrow formal is a binding while its body read keeps its source tuple" {
    const ast = @import("../parser/ast.zig");
    const T = @import("transformer.zig").Transformer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "const read=get=>get();");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var parameter: ast.NodeIndex = .none;
    var read: ast.NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .assignment_target_identifier) parameter = @fromBackingInt(@as(u32, @intCast(raw)));
        if (node.tag == .identifier_reference and std.mem.eql(u8, parser.ast.getText(node.span), "get")) read = @fromBackingInt(@as(u32, @intCast(raw)));
    }
    try std.testing.expect(!parameter.isNone() and !read.isNone() and parameter != read);
    const sid = analyzer.symbol_ids.items[@backingInt(parameter)].?;
    try std.testing.expectEqual(@as(?u32, sid), analyzer.symbol_ids.items[@backingInt(read)]);
    const source_scope = analyzer.symbols.items[sid].scope_id;
    var source_read: ?@import("../semantic/symbol.zig").Reference = null;
    for (analyzer.references.items) |row| if (row.node_index == read) {
        source_read = row;
    };
    try std.testing.expect(source_read != null);
    const source_body_node = parser.ast.getNode(read);
    var original_rows: usize = 0;
    for (analyzer.references.items) |row| if (row.flags.declare and row.declaration_node_index == parameter) {
        original_rows += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), original_rows);
    var t = try T.init(a, &parser.ast, .{ .unsupported = Options.compat.fromESTarget(.es5) });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.semantic_edit_enabled = true;
    const output = try t.visitNode(root);
    const nodes = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, t.ast, output);
    var bindings: usize = 0;
    for (nodes) |raw| {
        const node = t.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or t.symbol_ids.items[raw] != sid) continue;
        try std.testing.expect(raw >= t.parser_node_count);
        bindings += 1;
        var rows: usize = 0;
        for (t.semantic_editor.?.references.items) |row| if (row.flags.declare and row.declaration_node_index == @as(ast.NodeIndex, @fromBackingInt(raw))) {
            try std.testing.expectEqual(@as(u32, sid), @backingInt(row.symbol_id));
            try std.testing.expectEqual(source_scope, row.scope_id);
            rows += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), rows);
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    var old_rows: usize = 0;
    for (t.semantic_editor.?.references.items) |row| if (row.flags.declare and row.declaration_node_index == parameter) {
        old_rows += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), old_rows);
    const body_after = t.ast.getNode(read);
    try std.testing.expectEqual(@as(@TypeOf(body_after.tag), .identifier_reference), source_body_node.tag);
    try std.testing.expectEqual(source_body_node.tag, body_after.tag);
    try std.testing.expectEqualDeep(source_body_node.span, body_after.span);
    try std.testing.expectEqualDeep(source_body_node.data.string_ref, body_after.data.string_ref);
    try std.testing.expectEqual(analyzer.symbols.items.len, t.semantic_editor.?.symbols.items.len);
    const actual_read = (try t.semantic_editor.?.referenceForNode(read)).?;
    try std.testing.expectEqualDeep(source_read.?, actual_read);
    try std.testing.expectEqual(source_scope, t.semantic_editor.?.symbols.items[sid].scope_id);
}
