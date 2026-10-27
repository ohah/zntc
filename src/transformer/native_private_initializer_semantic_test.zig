const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const Transformer = @import("transformer.zig").Transformer;
const Options = @import("options.zig").TransformOptions;
const helpers = @import("transformer/class_member_helpers.zig");

const Case = struct { source: []const u8, reference: ?[]const u8 = null };
const cases = [_]Case{
    .{ .source = "class Box{#first=this.#second;#second=1;read(){return this.#first}}try{new Box();console.log('constructed')}catch(e){console.log(e instanceof TypeError)}" },
    .{ .source = "class Box{#first=(#first in this);read(){return this.#first}}console.log(new Box().read());" },
    .{ .source = "class Box{#first=(#second in this);#second=1;read(){return this.#first}}console.log(new Box().read());" },
    .{ .source = "class Box{#first;#second=(#first in this);read(){return this.#second}}console.log(new Box().read());" },
    .{ .source = "class Box{#first=7;#second=this.#first;read(){return this.#second}}console.log(new Box().read());" },
    .{ .source = "var events=[];class Box{#first=events.push('first');#second=events.push('second');constructor(){events.push('ctor')}}new Box();console.log(events.join(','));" },
    .{ .source = "class Base{}class Box extends Base{#first=this.#second;#second=1}try{new Box();console.log('constructed')}catch(e){console.log(e instanceof TypeError)}" },
    .{ .source = "var events=[];class Base{constructor(){events.push('base')}}class Box extends Base{#value=events.push('field');constructor(...args){events.push('pre');super(...args);events.push('post')}}new Box();console.log(events.join(','));" },
    .{ .source = "class Box{#value=7;#read=()=>this.#value;read(){return this.#read()}}console.log(new Box().read());" },
    .{ .source = "var events=[];class Box{static #first=events.push('first');static #second=events.push('second');static read(){return this.#first+this.#second}}console.log(Box.read(),events.join(','));" },
    .{ .source = "class Box{#field=7;constructor(value=this.#field){this.saved=value}}console.log(new Box().saved);" },
    .{ .source = "class Box{#field=7;constructor(get=()=>value,value=this.#field){this.get=get}}console.log(new Box().get());" },
    // Mixed public assignment work keeps the existing, ordered producer.
    .{ .source = "var events=[];function value(name){events.push(name);return name}class Box{first=value('public-first');#value=value('private');last=value('public-last');read(){return this.#value}}new Box();console.log(events.join(','));" },
    // Assign mode erases the uninitialized public type-only declaration; the
    // private-brand oracle removes only that explicit public policy difference.
    .{ .source = "class Box{unused:number;#value=(#value in this);read(){return this.#value}}console.log(new Box().read());", .reference = "class Box{#value=(#value in this);read(){return this.#value}}console.log(new Box().read());" },
};

fn runCase(case: Case, index: usize, minify: bool, target: @import("compat.zig").ESTarget) !void {
    const io_helpers = @import("../bundler/test_helpers.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try io_helpers.writeFile(tmp.dir, "native.cjs", case.reference orelse case.source);
    try io_helpers.writeFile(tmp.dir, "entry.ts", case.source);
    const native_path = try io_helpers.absPath(&tmp, "native.cjs");
    defer std.testing.allocator.free(native_path);
    const entry = try io_helpers.absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", native_path } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    var b = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .experimental_decorators = true, .unsupported = @import("compat.zig").fromESTarget(target), .minify_identifiers = minify });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    try io_helpers.writeFile(tmp.dir, "output.cjs", result.output);
    const output = try io_helpers.absPath(&tmp, "output.cjs");
    defer std.testing.allocator.free(output);
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output } });
    if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("native private case={d} id={any} native={s} actual={s} err={s}\n{s}\n", .{ index, minify, native.stdout, actual.stdout, actual.stderr, result.output });
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
}

test "native private initializer keeps brand installation and derived timing without public work" {
    for (cases, 0..) |case, index| {
        for ([_]bool{ false, true }) |minify| try runCase(case, index, minify, .esnext);
    }
}

test "native private initializer preserves lowered shared plans and mixed execution order" {
    for ([_]usize{ 4, 5, 7, 12 }) |index| {
        for ([_]@import("compat.zig").ESTarget{ .es2021, .es5 }) |target| {
            for ([_]bool{ false, true }) |minify| try runCase(cases[index], index, minify, target);
        }
    }
}

const Fixture = struct {
    parser: @import("../parser/parser.zig").Parser,
    analyzer: @import("../semantic/analyzer.zig").SemanticAnalyzer,
    class: NodeIndex,
    body: NodeIndex,

    fn init(a: std.mem.Allocator, source: []const u8) !Fixture {
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".ts");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var class: NodeIndex = .none;
        for (parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .class_declaration) class = @fromBackingInt(@intCast(raw));
        }
        return .{ .parser = parser, .analyzer = analyzer, .class = class, .body = parser.ast.readExtraNode(parser.ast.getNode(class).data.extra, ast_mod.ClassExtra.body) };
    }

    fn transformer(self: *Fixture, a: std.mem.Allocator, options: Options) !Transformer {
        var t = try Transformer.init(a, &self.parser.ast, options);
        try t.initSymbolIds(self.analyzer.symbol_ids.items);
        t.symbols = self.analyzer.symbols.items;
        t.references = self.analyzer.references.items;
        t.scopes = self.analyzer.scopes.items;
        t.scope_maps = self.analyzer.scope_maps.items;
        t.scope_owner_map = self.analyzer.scope_owner_map;
        t.node_scope_provenance = self.analyzer.node_scope_provenance;
        t.class_self_symbol_map = self.analyzer.class_self_symbol_map;
        t.helper_scope_map = self.analyzer.helper_scope_map;
        t.unresolved_references = &self.analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        return t;
    }
};

test "native private initializer preserves its key and ordinary initializer reference in the class scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, "const outer=7;class Box{#value=outer;read(){return this.#value}}");
    const members = f.parser.ast.getNode(f.body).data.list;
    const field: NodeIndex = @fromBackingInt(f.parser.ast.extra_data.items[members.start]);
    const key = f.parser.ast.readExtraNode(f.parser.ast.getNode(field).data.extra, ast_mod.PropertyExtra.key);
    const value = f.parser.ast.readExtraNode(f.parser.ast.getNode(field).data.extra, ast_mod.PropertyExtra.init);
    const sid = f.analyzer.symbol_ids.items[@backingInt(value)].?;
    const owner = f.analyzer.scope_owner_map.get(@backingInt(f.class)).?;
    const scope_count = f.analyzer.scopes.items.len;
    var source_row: ?@import("../semantic/symbol.zig").Reference = null;
    for (f.analyzer.references.items) |row| {
        if (row.node_index == value) source_row = row;
    }
    try std.testing.expect(source_row != null);
    try std.testing.expect(f.analyzer.symbol_ids.items[@backingInt(key)] == null); // native-private identity is not an ordinary SID
    var t = try f.transformer(a, .{ .experimental_decorators = true });
    try std.testing.expect(helpers.canKeepNativePrivateInitializers(&t, f.body));
    _ = try t.transform();
    const editor = &t.semantic_editor.?;
    try std.testing.expectEqual(scope_count, editor.scopes.items.len); // no synthetic constructor owner
    var declarations: usize = 0;
    const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(a, t.ast);
    for (live) |raw| {
        const node = t.ast.nodes.items[raw];
        if (node.tag != .property_definition) continue;
        if (t.ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.key) != key) continue;
        declarations += 1;
        try std.testing.expectEqual(value, t.ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.init));
    }
    try std.testing.expectEqual(@as(usize, 1), declarations);
    var reads: usize = 0;
    for (editor.references.items) |row| {
        if (row.node_index != value) continue;
        reads += 1;
        try std.testing.expectEqual(sid, @backingInt(row.symbol_id));
        try std.testing.expectEqual(owner, @backingInt(row.scope_id));
        try std.testing.expectEqual(source_row.?.flags, row.flags);
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expect(t.getSymbolIdAt(key) == null);
}

test "native private initializer policy rejects mixed autoaccessor parameter-property and lowered producers" {
    const Policy = struct { source: []const u8, keep: bool };
    const policies = [_]Policy{
        .{ .source = "class Box{#value=1;read(){return this.#value}}", .keep = true },
        .{ .source = "class Box{publicValue=1;#value=2}", .keep = false },
        .{ .source = "class Box{accessor value=1;#value=2}", .keep = false },
        .{ .source = "class Box{#value=1;constructor(public value:number){}}", .keep = false },
        .{ .source = "function dec(){}class Box{@dec #value=1}", .keep = false },
        .{ .source = "class Box{declare value:number;#value=1}", .keep = true },
        .{ .source = "class Box{value:number;#value=1}", .keep = true },
        .{ .source = "class Box{static publicValue=1;static #value=2}", .keep = true },
        .{ .source = "class Box{static {console.log(1)}#value=2}", .keep = true },
    };
    for (policies) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a, case.source);
        var t = try f.transformer(a, .{ .experimental_decorators = true });
        try std.testing.expectEqual(case.keep, helpers.canKeepNativePrivateInitializers(&t, f.body));
        t.options.unsupported.class_private_method = true;
        try std.testing.expect(!helpers.canKeepNativePrivateInitializers(&t, f.body));
        t.options.unsupported.class_private_method = false;
        t.options.unsupported.class_private_field = true;
        try std.testing.expect(!helpers.canKeepNativePrivateInitializers(&t, f.body));
    }
}

test "native private initializer graphless visitor preserves original native field edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, cases[0].source);
    var t = try f.transformer(a, .{ .experimental_decorators = true });
    t.semantic_edit_enabled = false;
    try std.testing.expect(helpers.canKeepNativePrivateInitializers(&t, f.body));
    const root = try t.transform();
    try std.testing.expect(t.semantic_editor == null);
    const source_members = f.parser.ast.getNode(f.body).data.list;
    const original_field: NodeIndex = @fromBackingInt(f.parser.ast.extra_data.items[source_members.start]);
    const original_key = f.parser.ast.readExtraNode(f.parser.ast.getNode(original_field).data.extra, ast_mod.PropertyExtra.key);
    const original_value = f.parser.ast.readExtraNode(f.parser.ast.getNode(original_field).data.extra, ast_mod.PropertyExtra.init);
    const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(a, t.ast);
    var found: usize = 0;
    for (live) |raw| {
        const node = t.ast.nodes.items[raw];
        if (node.tag != .property_definition or t.ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.key) != original_key) continue;
        found += 1;
        const actual_value = t.ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.init);
        // Graphless visitation clones composite expressions. It still keeps
        // the private access in this native initializer and preserves the
        // exact lexical private-key node, rather than moving it to a ctor.
        try std.testing.expectEqual(ast_mod.Node.Tag.private_field_expression, t.ast.getNode(actual_value).tag);
        try std.testing.expectEqual(
            f.parser.ast.readExtraNode(f.parser.ast.getNode(original_value).data.extra, 1),
            t.ast.readExtraNode(t.ast.getNode(actual_value).data.extra, 1),
        );
    }
    try std.testing.expectEqual(@as(usize, 1), found);
    var codegen = @import("../codegen/codegen.zig").Codegen.init(a, t.ast);
    const code = try codegen.generate(root);
    const result = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", code } });
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expectEqualStrings("true\n", result.stdout);
}
