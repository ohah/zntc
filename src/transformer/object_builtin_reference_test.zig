const std = @import("std");
const ast = @import("../parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const compat = @import("compat.zig");
const builtin = @import("object_builtin_reference.zig");

fn objectAndMember(tree: *const ast.Ast) !struct { object: NodeIndex, member: NodeIndex } {
    for (tree.nodes.items, 0..) |node, raw| {
        if (node.tag != .object_expression) continue;
        var members = tree.iterateExtraList(node.data.list);
        while (members.next()) |member| {
            const m = tree.getNode(member);
            if (m.tag == .method_definition and tree.extra_data.items[m.data.extra + ast.MethodExtra.flags] & ast.MethodFlags.is_getter != 0)
                return .{ .object = @fromBackingInt(@intCast(raw)), .member = member };
        }
    }
    return error.MissingAccessor;
}

test "object builtin producer fallback keeps fresh globals and source declaration identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "function f(Object){var k='x',p={value:3},o={__proto__:p,get[k](){return super.value}};return o.x+Object.keep}console.log(f({keep:1}))";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var initial = Analyzer.init(a, &parser.ast);
    try initial.analyze();
    var binding: NodeIndex = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .binding_identifier and std.mem.eql(u8, parser.ast.getText(node.span), "Object")) binding = @fromBackingInt(@intCast(raw));
    }
    try std.testing.expect(!binding.isNone());
    const old_sid = initial.symbol_ids.items[@backingInt(binding)].?;
    var source_reads: std.ArrayList(NodeIndex) = .empty;
    for (initial.references.items) |row| if (@backingInt(row.symbol_id) == old_sid) {
        try source_reads.append(a, row.node_index);
    };
    try std.testing.expect(source_reads.items.len > 0);
    var t = try Transformer.init(a, &parser.ast, .{ .unsupported = compat.fromESTarget(.es5), .emit_runtime_helper_imports = true });
    try t.initSymbolIds(initial.symbol_ids.items);
    t.symbols = initial.symbols.items;
    t.scopes = initial.scopes.items;
    t.scope_maps = initial.scope_maps.items;
    t.scope_owner_map = initial.scope_owner_map;
    t.node_scope_provenance = initial.node_scope_provenance;
    t.references = initial.references.items;
    t.unresolved_references = &initial.unresolved_references;
    const handles = try objectAndMember(t.ast);
    const context = try builtin.captureAccessor(&t, handles.object, handles.member);
    try std.testing.expect(context.source_owner_scope != null);
    try std.testing.expect(std.meta.activeTag(context.use_scope) == .deferred_until_reanalysis);
    try std.testing.expect(!t.record_explicit_global_references);
    try std.testing.expect(t.synthetic_idents == null);
    const output_root = try t.transform();
    const marked = try t.ownedExplicitGlobalRefNodes(a);
    var objects: usize = 0;
    for (marked) |raw| {
        if (!std.mem.eql(u8, t.ast.getText(t.ast.nodes.items[raw].span), "Object")) continue;
        objects += 1;
        try std.testing.expect(raw >= parser.ast.nodes.items.len);
        try std.testing.expect(raw >= t.symbol_ids.items.len or t.symbol_ids.items[raw] == null);
    }
    try std.testing.expectEqual(@as(usize, 2), objects);
    var output = Analyzer.init(a, t.ast);
    output.explicit_global_ref_nodes = marked;
    output.collect_unresolved_reference_nodes = true;
    try output.analyze();
    const new_sid = output.symbol_ids.items[@backingInt(binding)] orelse return error.MissingSourceDeclaration;
    const walk = @import("../parser/ast_walk.zig");
    const Frame = struct { node: NodeIndex, parent: ?u32 };
    var stack: std.ArrayList(Frame) = .empty;
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    try stack.append(a, .{ .node = output_root, .parent = null });
    while (stack.pop()) |frame| {
        if (frame.parent) |parent| {
            const entry = try parents.getOrPut(a, @backingInt(frame.node));
            if (entry.found_existing) {
                try std.testing.expectEqual(parent, entry.value_ptr.*);
                continue;
            }
            entry.value_ptr.* = parent;
        }
        var children = walk.children(t.ast, t.ast.getNode(frame.node));
        while (children.next()) |child| if (!child.isNone()) {
            try stack.append(a, .{ .node = child, .parent = @backingInt(frame.node) });
        };
    }

    for (source_reads.items) |read| {
        try std.testing.expectEqual(new_sid, output.symbol_ids.items[@backingInt(read)].?);
        var cursor = @backingInt(read);
        var owner: ?u32 = null;
        while (owner == null) {
            owner = output.scope_owner_map.get(cursor);
            if (owner == null) cursor = parents.get(cursor) orelse return error.MissingActualOwner;
        }
        var found = false;
        for (output.references.items) |row| {
            if (row.node_index == read) {
                try std.testing.expectEqual(owner.?, @backingInt(row.scope_id));
                try std.testing.expectEqual(new_sid, @backingInt(row.symbol_id));
                try std.testing.expect(row.flags.read);
                found = true;
            }
        }
        try std.testing.expect(found);
    }
    for (marked) |raw| {
        if (!std.mem.eql(u8, t.ast.getText(t.ast.nodes.items[raw].span), "Object")) continue;
        try std.testing.expect(output.symbol_ids.items[raw] == null);
        try std.testing.expect(output.unresolved_reference_nodes.contains(raw));
        var cursor = raw;
        var actual_scope: ?u32 = null;
        while (actual_scope == null) {
            actual_scope = output.scope_owner_map.get(cursor);
            if (actual_scope == null) cursor = parents.get(cursor) orelse return error.MissingGeneratedActualOwner;
        }
        std.debug.print("OBJECT BUILTIN USE node={d} actual-scope={d} external=1\n", .{ raw, actual_scope.? });
    }
    std.debug.print("OBJECT BUILTIN BIRTH fresh=2 source-anchor={d} old-sid={d} new-sid={d} deferred=1\n", .{ @backingInt(binding), old_sid, new_sid });
}

test "object builtin producer rejects foreign domain and wrong member before allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "var o={get['x'](){return 3}}, other={get['y'](){return 4}};");
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var t = try Transformer.init(a, &parser.ast, .{});
    var foreign = try Transformer.init(a, &parser.ast, .{});
    const handles = try objectAndMember(t.ast);
    const context = try builtin.captureAccessor(&t, handles.object, handles.member);
    const count = t.ast.nodes.items.len;
    var bad = context;
    bad.output_ast = foreign.ast;
    try std.testing.expectError(error.InvalidNode, builtin.makeReference(&t, bad));
    bad = context;
    bad.source_ast = foreign.ast;
    try std.testing.expectError(error.InvalidNode, builtin.makeReference(&t, bad));
    bad = context;
    bad.object = @fromBackingInt(@intCast(t.parser_node_count));
    try std.testing.expectError(error.InvalidNode, builtin.makeReference(&t, bad));
    bad = context;
    bad.member = handles.object;
    try std.testing.expectError(error.InvalidNode, builtin.makeReference(&t, bad));
    bad = context;
    bad.operation = .home_prototype;
    try std.testing.expectError(error.InvalidNode, builtin.makeReference(&t, bad));
    try std.testing.expectEqual(count, t.ast.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), t.explicit_global_reference_nodes.count());
    _ = &foreign;
}

test "object builtin producer marker OOM returns no installed read or source mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "var o={get['x'](){return 3}};");
    var parser = Parser.init(a, &scanner);
    const root = try parser.parse();
    var t = try Transformer.init(a, &parser.ast, .{});
    const handles = try objectAndMember(t.ast);
    const context = try builtin.captureAccessor(&t, handles.object, handles.member);
    const count = t.ast.nodes.items.len;
    const old_root = t.ast.getNode(root);
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    t.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, builtin.makeReference(&t, context));
    t.allocator = a;
    try std.testing.expectEqual(count, t.ast.nodes.items.len);
    try std.testing.expectEqual(old_root.tag, t.ast.getNode(root).tag);
    try std.testing.expectEqualDeep(old_root.data.list, t.ast.getNode(root).data.list);
    try std.testing.expectEqualDeep(old_root.span, t.ast.getNode(root).span);
    try std.testing.expectEqual(@as(usize, 0), t.explicit_global_reference_nodes.count());
    const reference = try builtin.makeReference(&t, context);
    try std.testing.expect(t.explicit_global_reference_nodes.contains(@backingInt(reference)));
}

test "object builtin producer debug registration is one row per fresh read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "var o={get['x'](){return 3}};");
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var t = try Transformer.init(a, &parser.ast, .{});
    t.record_explicit_global_references = true;
    const handles = try objectAndMember(t.ast);
    const context = try builtin.captureAccessor(&t, handles.object, handles.member);
    const first = try builtin.makeReference(&t, context);
    try std.testing.expectEqual(@as(usize, 1), t.explicit_global_reference_nodes.count());
    const second = try builtin.makeReference(&t, context);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), t.explicit_global_reference_nodes.count());
}

const original_runtime_cases = [_][]const u8{
    "const k=\"x\",p={value:3};const o={__proto__:p,get[k](){return super.value}};console.log(o.x)",
    "const k=\"x\",p={get value(){return this.n}};const o={__proto__:p,n:4,get[k](){return super.value}};console.log(o.x)",
    "let n=0;const p={value:5};const o={__proto__:p,get[(n++,\"x\")](){return super.value}};console.log(o.x,n)",
    "const k=\"x\",p={value:3};const o={__proto__:p,get[k](){return super.value}};Object.setPrototypeOf(o,{value:6});console.log(o.x)",
    "const k=\"x\",p={value:3};const o={__proto__:p,get[k](){return super.value},f(){return this.x+1}};console.log(o.f())",
    "const k=\"x\",p={value:3};const o={__proto__:p,get[k](){function f(x){return x+2}return f(super.value)}};console.log(o.x)",
    "const k=\"x\",p={set value(v){this.n=v}};const o={__proto__:p,set[k](v){super.value=v}};o.x=7;console.log(o.n)",
    "const k=\"x\",p={get value(){return this.n},set value(v){this.n=v}};const o={__proto__:p,n:1,get[k](){return super.value},set[k](v){super.value=v}};o.x=8;console.log(o.x)",
    "const k=\"x\",p={value:3};const o={__proto__:p,get[k](){return 1},get[k](){return super.value}};console.log(o.x)",
    "function f(Object){const k=\"x\",p={value:3};const o={__proto__:p,get[k](){return super.value}};return o.x}console.log(f({}))",
};

test "object builtin producer original ten runtime plain and identifiers" {
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    for (original_runtime_cases, 0..) |source, index| {
        for ([_]bool{ false, true }) |minify| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try helpers.writeFile(tmp.dir, "entry.mjs", source);
            const entry = try helpers.absPath(&tmp, "entry.mjs");
            defer std.testing.allocator.free(entry);
            const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", entry } });
            try std.testing.expect(native.term == .exited and native.term.exited == 0);
            var b = Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .platform = .node,
                .format = .cjs,
                .unsupported = compat.fromESTarget(.es5),
                .minify_identifiers = minify,
            });
            defer b.deinit();
            const result = try b.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            try helpers.writeFile(tmp.dir, "output.cjs", result.output);
            const output = try helpers.absPath(&tmp, "output.cjs");
            defer std.testing.allocator.free(output);
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("OBJECT BUILTIN runtime case={d} minify={any}\nnative={s}actual={s}stderr={s}\n{s}\n", .{ index, minify, native.stdout, actual.stdout, actual.stderr, result.output });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "object builtin producer accessor handoff rejects missing sibling and foreign events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "var o={get['x'](){return 3},get['y'](){return 4}},other={get['z'](){return 5}};");
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var t = try Transformer.init(a, &parser.ast, .{});
    var foreign = try Transformer.init(a, &parser.ast, .{});
    const handles = try objectAndMember(t.ast);
    var members = parser.ast.iterateExtraList(parser.ast.getNode(handles.object).data.list);
    const first = members.next().?;
    const second = members.next().?;
    const out1 = try t.ast.addNode(t.ast.getNode(first));
    const out2 = try t.ast.addNode(t.ast.getNode(second));
    var origins = try builtin.AccessorOrigins.init(&t, handles.object);
    try std.testing.expectError(error.InvalidNode, builtin.captureAccessorWithOrigins(&t, handles.object, out1, &origins));
    try std.testing.expectEqual(@as(usize, 0), t.explicit_global_reference_nodes.count());
    try origins.record(&t, first, out1);
    try origins.record(&t, second, out2);
    const valid = try builtin.captureAccessorWithOrigins(&t, handles.object, out1, &origins);
    var bad = valid;
    bad.output_member = out2;
    try std.testing.expectError(error.InvalidNode, builtin.makeReference(&t, bad));
    var foreign_origins = try builtin.AccessorOrigins.init(&foreign, handles.object);
    bad = valid;
    bad.accessor_origins = &foreign_origins;
    try std.testing.expectError(error.InvalidNode, builtin.makeReference(&t, bad));
    try std.testing.expectError(error.InvalidNode, origins.record(&t, first, out1));
    try std.testing.expectEqual(@as(usize, 0), t.explicit_global_reference_nodes.count());
    const ref = try builtin.makeReference(&t, valid);
    try std.testing.expect(t.explicit_global_reference_nodes.contains(@backingInt(ref)));
    _ = &foreign;
}
