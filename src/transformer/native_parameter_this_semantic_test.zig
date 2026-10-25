const std = @import("std");
const TransformOptions = @import("transformer.zig").TransformOptions;

const sources = [_][]const u8{
    "class P{}class D extends P{constructor(get=(function(make=()=>this){return make}).call({value:7})){super();console.log(get().value)}}new D",
    "function Parent(get=()=>this){return get}const object={};const get=Parent.call(object);console.log(get()===object,get.name,get.length)",
    "function Parent(get=()=>()=>this){return get}const object={};console.log(Parent.call(object)()()===object)",
    "function Parent({get=()=>this}={}){return get}const object={};console.log(Parent.call(object)()===object)",
    "function Parent(value=2,get=()=>[this,value]){return get}const object={};const get=Parent.call(object);console.log(get()[0]===object,get()[1])",
    "class Parent{constructor(get=()=>this){this.get=get}}const object=new Parent;console.log(object.get()===object)",
    "class Parent{read(get=()=>this){return get}}const object=new Parent;console.log(object.read()()===object)",
    "function Parent(get=()=>this){return get}const get=Parent.call(3);console.log(Number(get()),typeof get())",
    "class Parent{read(get=()=>this){return get}}console.log(Parent.prototype.read.call(undefined)()===undefined)",
    "function Parent(_this=7,get=()=>[this,_this]){return get}const object={};const get=Parent.call(object);console.log(get()[0]===object,get()[1])",
    "function Parent(get=()=>[this,new.target]){this.get=get}const object=new Parent;console.log(object.get()[0]===object,object.get()[1]===Parent)",
    "function Parent(){const first=()=>this;const make=(get=()=>this)=>get;return[first,make()]}const object={};const [first,get]=Parent.call(object);console.log(first()===object,get()===object)",
    "function Parent(arg={get:()=>this}){return arg.get.name}console.log(Parent.call({}))",
    "function Parent(arg={[\"read\"]:()=>this}){return arg.read.name}console.log(Parent.call({}))",
    "let calls=0;function makeKey(){calls++;return \"get\"}function Parent(arg={[makeKey()]:()=>this}){return [arg.get.name,calls]}console.log(Parent.call({}))",
    "const key=Symbol(\"read\");function Parent(arg={[key]:()=>this}){return arg[key].name}console.log(Parent.call({}))",
    "function invoke(callback){return callback}function Parent(arg={get:invoke(()=>this)}){return arg.get.name}console.log(Parent.call({}))",
    "function Parent(arg={outer:{inner:()=>this}}){return arg.outer.inner.name}console.log(Parent.call({}))",
};

test "native parameter initialized this preserves runtime and inferred names across lexical environments" {
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqual(@as(u8, 0), native.term.exited);
        for ([_]bool{ false, true }) |rn| for ([_]bool{ false, true }) |minify| {
            var unsupported = if (rn) TransformOptions.compat.fromReactNativeVersion(0, 80) else TransformOptions.compat.fromESTarget(.es2022);
            unsupported.arrow = true;
            const output = try @import("../transpile.zig").transpile(a, source, "input.cjs", .{ .unsupported = unsupported, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", output.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("source:{s}\ncode:{s}\nexpected:{s}actual:{s}stderr:{s}\n", .{ source, output.code, native.stdout, actual.stdout, actual.stderr });
            try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        };
    }
}

test "captured computed-property arrows preserve names when object spread is unsupported" {
    const cases = [_][]const u8{
        "function Parent(arg={get:()=>this}){return arg.get.name}console.log(Parent.call({}))",
        "var calls=0;var key={toString:function(){calls++;return 'get'}};function Parent(arg={[key]:()=>this}){return [arg.get.name,calls]}console.log(Parent.call({}))",
        "var key={toString:function(){return 0}};function Parent(arg={[key]:()=>this}){return arg[0].name}console.log(Parent.call({}))",
        "var key=Symbol();function Parent(arg={[key]:()=>this}){return arg[key].name}console.log(Parent.call({}))",
        "var writes=0;Object.defineProperty(Object.prototype,'get',{set:function(){writes++},configurable:true});var key={toString:function(){return 'get'}};function Parent(arg={[key]:()=>this}){return [arg.get.name,writes,Object.prototype.hasOwnProperty.call(arg,'get')]}console.log(Parent.call({}))",
        "var writes=0;Object.defineProperty(Object.prototype,'read',{set:function(){writes++},configurable:true});function Parent(arg={['read']:()=>this}){return [arg.read.name,writes,Object.prototype.hasOwnProperty.call(arg,'read')]}console.log(Parent.call({}))",
        "var key=Symbol('read');function Parent(arg={first:1,[key]:()=>this,last:2,[key]:()=>this}){return [Object.keys(arg).join(','),Reflect.ownKeys(arg).length,arg[key].name]}console.log(Parent.call({}))",
        "var first={toString:function(){return 'read'}},second={toString:function(){return 'write'}};function Parent(arg={[first]:()=>this,[second]:()=>this}){return [arg.read.name,arg.write.name]}console.log(Parent.call({}))",
        "var hints=[];var key={[Symbol.toPrimitive]:function(hint){hints.push(hint);return Symbol('read')}};function Parent(arg={[key]:()=>this}){return [arg[Reflect.ownKeys(arg)[0]].name,hints.join(',')]}console.log(Parent.call({}))",
        "var key={toString:function(){return 'read'}};function Parent(arg={[key]:()=>this}){var __name,__namedProperty,__toPropertyKey,$nm,$np;return arg.read.name}console.log(Parent.call({}))",
    };
    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqual(@as(u8, 0), native.term.exited);
        for ([_]TransformOptions.compat.ESTarget{ .es5, .es2017 }) |target| {
            var unsupported = TransformOptions.compat.fromESTarget(target);
            unsupported.arrow = true;
            try std.testing.expect(unsupported.object_spread);
            for ([_]bool{ false, true }) |minify| {
                const output = try @import("../transpile.zig").transpile(a, source, "input.cjs", .{
                    .unsupported = unsupported,
                    .minify_identifiers = minify,
                    .minify_syntax = minify,
                    .minify_whitespace = minify,
                });
                try std.testing.expect(std.mem.indexOf(u8, output.code, "...") == null);
                const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", output.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
                if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("source:{s}\ncode:{s}\nexpected:{s}actual:{s}stderr:{s}\n", .{ source, output.code, native.stdout, actual.stdout, actual.stderr });
                try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
                try std.testing.expectEqualStrings(native.stdout, actual.stdout);
            }
        }
    }
}

test "native parameter initialized this has exact factory binding and references before output walk" {
    const ast = @import("../parser/ast.zig");
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    for (sources[1..]) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        const initial_scope_count = analyzer.scopes.items.len;
        var unsupported = TransformOptions.compat.fromESTarget(.es2022);
        unsupported.arrow = true;
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = unsupported });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.class_self_symbol_map = analyzer.class_self_symbol_map;
        t.node_scope_provenance = analyzer.node_scope_provenance;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        try std.testing.expect(t.native_parameter_arrow_this_capture == null);
        const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, t.ast, output);
        var captures: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var factories: usize = 0;
        for (live) |raw| {
            const node = t.ast.nodes.items[raw];
            if (node.tag != .function_expression) continue;
            const scope = t.outputOwnedScope(@fromBackingInt(raw)) orelse continue;
            if (scope.toIndex() < initial_scope_count) continue;
            factories += 1;
            const params = t.ast.functionParamsList(node);
            try std.testing.expect(params.len >= 1 and params.len <= 2);
            for (t.ast.extra_data.items[params.start .. params.start + params.len]) |binding_raw| {
                const binding: ast.NodeIndex = @fromBackingInt(binding_raw);
                const sid = t.getSymbolIdAt(binding) orelse return error.MissingFactoryParameterIdentity;
                try std.testing.expectEqual(scope, t.semantic_editor.?.symbols.items[sid].scope_id);
                try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.parameter, t.semantic_editor.?.symbols.items[sid].kind);
                try captures.put(a, sid, {});
            }
        }
        try std.testing.expect(factories > 0);
        const Work = struct { node: ast.NodeIndex, scope: ScopeId };
        var stack: std.ArrayList(Work) = .empty;
        try stack.append(a, .{ .node = output, .scope = @fromBackingInt(0) });
        var bindings: usize = 0;
        var reads: usize = 0;
        while (stack.pop()) |work| {
            if (work.node.isNone()) continue;
            const node = t.ast.getNode(work.node);
            const scope = t.outputOwnedScope(work.node) orelse work.scope;
            if (t.getSymbolIdAt(work.node)) |id| if (captures.contains(id)) {
                if (node.tag == .binding_identifier) {
                    try std.testing.expectEqual(scope, t.semantic_editor.?.symbols.items[id].scope_id);
                    bindings += 1;
                } else {
                    const reference = (try t.semantic_editor.?.referenceForNode(work.node)) orelse return error.MissingReferenceAtCreation;
                    try std.testing.expectEqual(id, @backingInt(reference.symbol_id));
                    try std.testing.expectEqual(scope, reference.scope_id);
                    try std.testing.expect(reference.flags.read and !reference.flags.write);
                    reads += 1;
                }
            };
            var children = @import("../parser/ast_walk.zig").children(t.ast, node);
            while (children.next()) |child| {
                const outside_key = node.tag == .method_definition and child == t.ast.readExtraNode(node.data.extra, ast.MethodExtra.key);
                try stack.append(a, .{ .node = child, .scope = if (outside_key) work.scope else scope });
            }
        }
        try std.testing.expectEqual(captures.count(), bindings);
        try std.testing.expect(reads >= captures.count());
    }
}

test "native parameter initialized this excludes derived live bindings and restores nested state" {
    const cases = [_]struct { source: []const u8, factories: usize }{
        .{ .source = "class P{}class D extends P{constructor(get=()=>this){super();this.get=get}}new D", .factories = 0 },
        .{ .source = "class P{}class D extends P{constructor(get=(function(make=()=>this){return make}).call({value:7}),read=()=>this){super();this.get=get;this.read=read}}new D", .factories = 1 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, case.source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        const initial_scope_count = analyzer.scopes.items.len;
        var unsupported = TransformOptions.compat.fromESTarget(.es2022);
        unsupported.arrow = true;
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .unsupported = unsupported });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.class_self_symbol_map = analyzer.class_self_symbol_map;
        t.node_scope_provenance = analyzer.node_scope_provenance;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        // The derived cases remain known public failures. This guards against
        // replacing the live uninitialized environment with an eager snapshot;
        // it is not a correctness assertion for their pending lowering path.
        try std.testing.expect(t.native_parameter_arrow_this_capture == null);
        try std.testing.expect(t.native_parameter_this_snapshot_allowed);
        const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, t.ast, output);
        var factories: usize = 0;
        for (live) |raw| {
            if (t.ast.nodes.items[raw].tag != .function_expression) continue;
            const scope = t.outputOwnedScope(@fromBackingInt(raw)) orelse continue;
            if (scope.toIndex() >= initial_scope_count) factories += 1;
        }
        try std.testing.expectEqual(case.factories, factories);
    }
}
