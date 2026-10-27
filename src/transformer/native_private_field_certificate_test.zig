const std = @import("std");
const helpers = @import("../bundler/test_helpers.zig");
const bundler_mod = @import("../bundler/bundler.zig");
const profile = @import("../profile.zig");
const decorate = "// @flow\nfunction decorate(target:any,key?:string,descriptor?:any):any{return descriptor;}";
const Case = struct { source: []const u8, expected: []const u8 };
const cases = [_]Case{
    .{ .source = decorate ++ "class Box{#value:number=7;@decorate read(delta:number):number{return this.#value+delta}}console.log(new Box().read(2));", .expected = "9\n" },
    .{ .source = decorate ++ "class Box{static #value:number=5;@decorate static read():number{return Box.#value}}console.log(Box.read());", .expected = "5\n" },
    .{ .source = decorate ++ "class Box{#value:string='text';@decorate read():string{return this.#value}}console.log(new Box().read());", .expected = "text\n" },
    .{ .source = decorate ++ "class Box{#value:boolean=true;@decorate read():boolean{return this.#value}}console.log(new Box().read());", .expected = "true\n" },
    .{ .source = decorate ++ "class Box{#value:any=null;@decorate read():boolean{return this.#value===null}}console.log(new Box().read());", .expected = "true\n" },
    .{ .source = decorate ++ "class Box{static #value:string='static';@decorate static read():string{return Box.#value}}console.log(Box.read());", .expected = "static\n" },
    .{ .source = decorate ++ "class Box{static #value:boolean=false;@decorate static read():boolean{return Box.#value}}console.log(Box.read());", .expected = "false\n" },
    .{ .source = decorate ++ "class Box{static #value:any=null;@decorate static read():boolean{return Box.#value===null}}console.log(Box.read());", .expected = "true\n" },
    .{ .source = decorate ++ "class Box{#first:number=2;static #second:number=3;@decorate read():number{return this.#first+Box.#second}}console.log(new Box().read());", .expected = "5\n" },
    .{ .source = decorate ++ "{class Box{#value:number=2;@decorate read():number{return this.#value}}console.log(new Box().read())}{class Box{#value:number=3;@decorate read():number{return this.#value}}console.log(new Box().read())}", .expected = "2\n3\n" },
};

// Independent native JavaScript twins: no compiler or type-erasure helper is
// used to generate the runtime oracle.
const native_cases = [_][]const u8{
    "class Box{#value=7;read(delta){return this.#value+delta}}console.log(new Box().read(2));",
    "class Box{static #value=5;static read(){return Box.#value}}console.log(Box.read());",
    "class Box{#value='text';read(){return this.#value}}console.log(new Box().read());",
    "class Box{#value=true;read(){return this.#value}}console.log(new Box().read());",
    "class Box{#value=null;read(){return this.#value===null}}console.log(new Box().read());",
    "class Box{static #value='static';static read(){return Box.#value}}console.log(Box.read());",
    "class Box{static #value=false;static read(){return Box.#value}}console.log(Box.read());",
    "class Box{static #value=null;static read(){return Box.#value===null}}console.log(Box.read());",
    "class Box{#first=2;static #second=3;read(){return this.#first+Box.#second}}console.log(new Box().read());",
    "{class Box{#value=2;read(){return this.#value}}console.log(new Box().read())}{class Box{#value=3;read(){return this.#value}}console.log(new Box().read())}",
};

test "legacy native private certificate keeps source entry graph and scalar runtime" {
    for (cases, 0..) |case, index| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.js", case.source);
        const entry = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(entry);
        // Inspect immediately after Graph.build, before linker/mangler can
        // capture unrelated owner tokens. Full semantic fallback resets this
        // exact no-import source's token; the completed source plan owns it.
        var cache = @import("../bundler/resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
        defer cache.deinit();
        var graph = @import("../bundler/graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
        defer graph.deinit();
        graph.flow = true;
        graph.minify_identifiers = minify;
        graph.transform_options_base.experimental_decorators = true;
        graph.transform_options_base.unsupported = @import("compat.zig").fromESTarget(.esnext);
        try graph.build(std.testing.io, &.{entry});
        const source_module = graph.findModuleByPath(entry) orelse return error.MissingEntryModule;
        try std.testing.expectEqualStrings(entry, source_module.path);
        try std.testing.expect(source_module.transform_cache != null);
        try std.testing.expect(source_module.semantic.?.owner_token != .unassigned);
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var b = bundler_mod.Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .flow = true, .experimental_decorators = true, .unsupported = @import("compat.zig").fromESTarget(.esnext), .minify_identifiers = minify });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        // This exact esnext fixture has one unchanged decorator provider;
        // source entry retention must remove its only semantic resync.
        if (profile.count(.graph_resync_semantic) != 0) std.debug.print("native private source fallback case={d} minify={} resync={d}\n", .{ index, minify, profile.count(.graph_resync_semantic) });
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", output } });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, actual.stdout);
        try helpers.writeFile(tmp.dir, "native.cjs", native_cases[index]);
        const native_path = try helpers.absPath(&tmp, "native.cjs");
        defer std.testing.allocator.free(native_path);
        const native = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", native_path } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

const ast_mod = @import("../parser/ast.zig");
const Cert = @import("native_private_field_certificate.zig");
const module_mod = @import("../bundler/module.zig");
const Transformer = @import("transformer.zig").Transformer;
const Fixture = struct {
    t: Transformer,
    sem: module_mod.ModuleSemanticData,
    root: ast_mod.NodeIndex,
    fn init(a: std.mem.Allocator, input: []const u8) !Fixture {
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, input);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        const input_ast = try a.create(ast_mod.Ast);
        input_ast.* = parser.ast;
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, input_ast);
        analyzer.enable_exact_declaration_anchors = true;
        analyzer.enable_stmt_info = true;
        try analyzer.analyze();
        var sem: module_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        _ = sem.captureOwnerToken();
        const options: @import("transformer.zig").TransformOptions = .{ .experimental_decorators = true };
        var source = (try Cert.sourcePlan(a, input_ast, &sem, options)) orelse return error.MissingNativePrivateSourcePlan;
        var t = try Transformer.init(a, input_ast, options);
        try t.initSymbolIds(sem.symbol_ids);
        t.symbols = sem.symbols.items;
        t.references = sem.references;
        t.scopes = sem.scopes;
        t.scope_maps = sem.scope_maps;
        t.scope_owner_map = sem.scope_owner_map;
        t.node_scope_provenance = sem.node_scope_provenance;
        t.class_self_symbol_map = sem.class_self_symbol_map;
        t.helper_scope_map = sem.helper_scope_map;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        source.output_ast = t.ast;
        t.native_private_field_source = source;
        const root = try t.transform();
        sem.applyEdit((try t.finishSemanticEdit()).?);
        return .{ .t = t, .sem = sem, .root = root };
    }
};

test "legacy native private certificate preserves specialized keys and actual copy provenance" {
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a, case.source);
        try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
        const source = f.t.native_private_field_source.?;
        try std.testing.expectEqual(source.classes.len + source.fields.len + source.uses.len, f.t.native_private_field_applications.items.len);
        try std.testing.expect(!f.t.runtime_helpers.public_field and !f.t.runtime_helpers.class_static_private_field and !f.t.runtime_helpers.class_private_field_set and !f.t.runtime_helpers.class_private_method_init and !f.t.runtime_helpers.class_private_method_get);
        try std.testing.expect(f.t.runtime_helpers.legacy_decorator);
        for (source.fields) |field| {
            try std.testing.expect(f.t.getSymbolIdAt(field.key) == null);
            const source_scope = source.classes[field.class_index].scope;
            var count: usize = 0;
            for (f.t.native_private_field_applications.items) |app| {
                if (app.kind != .field_copy or app.source != field.node) continue;
                count += 1;
                try std.testing.expect(app.output != field.node);
                try std.testing.expectEqual(source_scope, app.scope);
                const actual = f.t.ast.getNode(app.output);
                try std.testing.expectEqual(field.key, f.t.ast.readExtraNode(actual.data.extra, ast_mod.PropertyExtra.key));
                try std.testing.expectEqual(field.value, f.t.ast.readExtraNode(actual.data.extra, ast_mod.PropertyExtra.init));
            }
            try std.testing.expectEqual(@as(usize, 1), count);
        }
        for (source.uses) |use| {
            try std.testing.expect(f.t.getSymbolIdAt(use.key) == null);
            var count: usize = 0;
            for (f.t.native_private_field_applications.items) |app| {
                if (app.kind != .use_copy or app.source != use.node) continue;
                count += 1;
                try std.testing.expect(app.output != use.node);
                try std.testing.expectEqual(use.scope, app.scope);
                const actual = f.t.ast.getNode(app.output);
                try std.testing.expectEqual(use.key, f.t.ast.readExtraNode(actual.data.extra, 1));
            }
            try std.testing.expectEqual(@as(usize, 1), count);
        }
    }
}

fn expectIneligible(a: std.mem.Allocator, input: []const u8) !void {
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, input);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var sem: module_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .symbol_ids = analyzer.symbol_ids.items, .references = analyzer.references.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references };
    try std.testing.expect((try Cert.sourcePlan(a, &parser.ast, &sem, .{ .experimental_decorators = true })) == null);
}

test "legacy native private certificate preserves unsupported source boundaries" {
    const suffix = "@decorate read(){return this.#value}";
    const negative = [_][]const u8{
        decorate ++ "class Parent{}class Box extends Parent{#value=1;" ++ suffix ++ "}",
        decorate ++ "class Box{#value=1;constructor(){}" ++ suffix ++ "}",
        decorate ++ "class Box{publicValue=2;#value=1;" ++ suffix ++ "}",
        decorate ++ "class Box{static publicValue=2;#value=1;" ++ suffix ++ "}",
        decorate ++ "class Box{publicValue:number;#value=1;" ++ suffix ++ "}",
        decorate ++ "class Box{#value=()=>1;" ++ suffix ++ "}",
        decorate ++ "class Box{#value=work();" ++ suffix ++ "}",
        decorate ++ "class Box{@decorate #value=1;" ++ suffix ++ "}",
        decorate ++ "class Box{#value=1;static {}" ++ suffix ++ "}",
        decorate ++ "class Box{#value=1;@decorate read(){return class Inner{#other=2}}}",
        decorate ++ "const Box=class{#value=1;" ++ suffix ++ "}",
        decorate ++ "class Box{#value=1;accessor other=2;" ++ suffix ++ "}",
    };
    for (negative) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try expectIneligible(arena.allocator(), input);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, cases[0].source);
    const source = f.t.native_private_field_source.?;
    var options = f.t.options;
    options.unsupported = @import("compat.zig").fromESTarget(.es5);
    try std.testing.expect((try Cert.sourcePlan(a, source.ast, &f.sem, options)) == null);
    options = f.t.options;
    options.minify_syntax = true;
    try std.testing.expect((try Cert.sourcePlan(a, source.ast, &f.sem, options)) == null);
    const original = @constCast(f.sem.scopes)[0];
    @constCast(f.sem.scopes)[0].subtree_has_direct_eval = true;
    try std.testing.expect((try Cert.sourcePlan(a, source.ast, &f.sem, f.t.options)) == null);
    @constCast(f.sem.scopes)[0] = original;
    @constCast(f.sem.scopes)[0].subtree_has_with = true;
    try std.testing.expect((try Cert.sourcePlan(a, source.ast, &f.sem, f.t.options)) == null);
    @constCast(f.sem.scopes)[0] = original;
    try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
}

test "legacy native private certificate rejects foreign owner scope and copy tuples without writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, decorate ++ "class Box{#value=2;static #other=3;@decorate read(){return this.#value+Box.#other}}class Other{#value=4;static #other=5;@decorate read(){return this.#value+Other.#other}}");
    try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    const source = f.t.native_private_field_source.?;
    var foreign_ast = try f.t.ast.cloneForTransformer(a);
    var foreign_sem = f.sem;
    foreign_sem.owner_token = .unassigned;
    _ = foreign_sem.captureOwnerToken();
    const rows = try a.dupe(@import("../semantic/symbol.zig").Reference, f.sem.references);
    const ids = try a.dupe(?u32, f.sem.symbol_ids);
    const scopes = try a.dupe(@import("../semantic/scope.zig").Scope, f.sem.scopes);
    const applications = try a.dupe(Cert.Applied, f.t.native_private_field_applications.items);
    const Reject = struct {
        fn call(fixture: *Fixture, original_rows: []const @import("../semantic/symbol.zig").Reference) !void {
            try std.testing.expect(!try Cert.complete(&fixture.t, &fixture.sem, fixture.root));
            for (original_rows, fixture.sem.references) |before, after| try std.testing.expect(std.meta.eql(before, after));
        }
    };
    for (0..4) |fault| {
        var bad = source;
        switch (fault) {
            0 => bad.owner = .unassigned,
            1 => bad.owner = foreign_sem.owner_token,
            2 => bad.ast = &foreign_ast,
            3 => bad.output_ast = &foreign_ast,
            else => unreachable,
        }
        f.t.native_private_field_source = bad;
        try Reject.call(&f, rows);
        f.t.native_private_field_source = source;
        try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    }
    const original_items = f.t.native_private_field_applications.items;
    f.t.native_private_field_applications.items = original_items[0 .. original_items.len - 1];
    try Reject.call(&f, rows);
    f.t.native_private_field_applications.items = original_items;
    try f.t.native_private_field_applications.append(a, original_items[0]);
    try Reject.call(&f, rows);
    f.t.native_private_field_applications.shrinkRetainingCapacity(original_items.len);
    for (f.t.native_private_field_applications.items, 0..) |*app, index| {
        const saved = app.*;
        app.scope = source.classes[0].outer;
        try Reject.call(&f, rows);
        app.* = saved;
        const other = applications[(index + 1) % applications.len];
        app.output = other.output;
        try Reject.call(&f, rows);
        app.* = saved;
    }
    const field = source.fields[0];
    var actual_field: ast_mod.NodeIndex = .none;
    for (applications) |app| if (app.kind == .field_copy and app.source == field.node) {
        actual_field = app.output;
    };
    try std.testing.expect(!actual_field.isNone());
    const extra = f.t.ast.getNode(actual_field).data.extra;
    const saved_key = f.t.ast.extra_data.items[extra + ast_mod.PropertyExtra.key];
    f.t.ast.extra_data.items[extra + ast_mod.PropertyExtra.key] = @backingInt(source.fields[2].key);
    try Reject.call(&f, rows);
    f.t.ast.extra_data.items[extra + ast_mod.PropertyExtra.key] = saved_key;
    const scalar_clone = try f.t.ast.addNode(f.t.ast.getNode(field.value));
    f.t.ast.extra_data.items[extra + ast_mod.PropertyExtra.init] = @backingInt(scalar_clone);
    try Reject.call(&f, rows);
    f.t.ast.extra_data.items[extra + ast_mod.PropertyExtra.init] = @backingInt(field.value);
    @constCast(f.sem.symbol_ids)[@backingInt(field.key)] = source.classes[0].symbol;
    try Reject.call(&f, rows);
    @constCast(f.sem.symbol_ids)[@backingInt(field.key)] = null;
    const class_scope = source.classes[0].scope.toIndex();
    @constCast(f.sem.scopes)[class_scope].kind = .function;
    try Reject.call(&f, rows);
    @constCast(f.sem.scopes)[class_scope] = scopes[class_scope];
    @constCast(f.sem.scopes)[class_scope].parent = source.classes[1].scope;
    try Reject.call(&f, rows);
    @constCast(f.sem.scopes)[class_scope] = scopes[class_scope];
    try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    for (rows, f.sem.references) |before, after| try std.testing.expect(std.meta.eql(before, after));
    try std.testing.expectEqualSlices(?u32, ids, f.sem.symbol_ids);
    for (scopes, f.sem.scopes) |before, after| try std.testing.expect(std.meta.eql(before, after));
    for (applications, f.t.native_private_field_applications.items) |before, after| try std.testing.expect(std.meta.eql(before, after));
}
