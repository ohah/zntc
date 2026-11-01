const std = @import("std");
const ast = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const names = @import("nfe_name_environment.zig");
const compat = @import("compat.zig");

const inputs = [_][]const u8{
    "var Object=function Object(){};console.log(Object.name)",
    "var value=function Object(){};console.log(value.name)",
    "var Foo=function Foo(n){return n?Foo(n-1)+1:0};console.log(Foo.name,Foo(2))",
    "var Foo=function Foo(){return function Foo(){return Foo.name}};console.log(Foo.name,Foo()().toString())",
    "var Foo=function Foo(x=1){return [Foo.name,x]};console.log(Foo.name,JSON.stringify(Foo()))",
    "var Foo=function Foo(x=()=>Foo){return x()===Foo};console.log(Foo.name,Foo())",
    "var Foo=function Foo(...xs){return [Foo.name,xs.length]};console.log(Foo.name,JSON.stringify(Foo(1,2)))",
    "var Foo=async function Foo(){return Foo.name};Foo().then(x=>console.log(Foo.name,x))",
    "var Foo=function* Foo(){yield Foo.name};console.log(Foo.name,Foo().next().value)",
    "var Object=function Object(){var key=\"x\",obj={get[key](){return 3}};return obj.x};console.log(Object.name,Object())",
};

const controls = [_][]const u8{
    "var Foo=function(){};console.log(Foo.name)",
    "\"use strict\";function outer(){var Foo=1;{function Foo(){return 2}console.log(Foo())}console.log(Foo)}outer()",
    "function outer(){var Foo=1;{function Foo(){return 2}}console.log(Foo())}outer()",
    "function outer(){{let Foo=1;console.log(Foo)}{let Foo=2;console.log(Foo)}}outer()",
    "function outer(){let result;{let Foo=3;result=()=>Foo}return result()}console.log(outer())",
    "var Foo=1;var other=function Foo(){return Foo.name};console.log(Foo,other.name,other())",
    "var Foo=function Foo(Foo){return Foo};console.log(Foo.name,Foo(3))",
    "var Foo=function Foo(x=()=>Foo){var Foo=3;return [x().name,Foo]};console.log(Foo.name,JSON.stringify(Foo()))",
    "var Foo=class Foo{};console.log(Foo.name)",
    "var Foo=function Foo(__name){return __name};console.log(Foo.name,Foo(3))",
};

test "NFE name environment exact source self bindings are not hoisted block bindings" {
    for (inputs, 0..) |source, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var initial = Analyzer.init(a, &parser.ast);
        initial.enable_exact_declaration_anchors = true;
        try initial.analyze();
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = compat.fromESTarget(.es5), .keep_names = true });
        try t.initSymbolIds(initial.symbol_ids.items);
        t.symbols = initial.symbols.items;
        t.scopes = initial.scopes.items;
        t.scope_maps = initial.scope_maps.items;
        t.scope_owner_map = initial.scope_owner_map;
        t.references = initial.references.items;
        t.unresolved_references = &initial.unresolved_references;
        const input: names.Input = .{ .source = &parser.ast, .source_node_count = @intCast(parser.ast.nodes.items.len), .symbols = initial.symbols.items, .scopes = initial.scopes.items, .symbol_ids = initial.symbol_ids.items, .owners = &initial.scope_owner_map, .references = initial.references.items };
        const set = try names.collect(a, input);
        try std.testing.expect(set.ids.count() > 0);
        try t.buildBlockRenameMap();
        var ids = set.ids.keyIterator();
        while (ids.next()) |id| {
            try std.testing.expect(set.contains(&parser.ast, initial.symbols.items, initial.scopes.items, initial.references.items, id.*));
            if (t.block_rename_map) |map| try std.testing.expect(!map.contains(id.*));
            if (index == 0) {
                const saved_source = t.semantic_source_ast;
                t.semantic_source_ast = null;
                try t.buildBlockRenameMap();
                const old_path = t.block_rename_map orelse return error.MissingOldRenamePath;
                try std.testing.expect(old_path.contains(id.*));
                t.semantic_source_ast = saved_source;
            }
        }
        // Retain source identity before any output walk or fallback analyzer.
        _ = root;
    }
}

test "NFE name environment rejects valid sibling identities wrong anchors and foreign domains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "var A=function A(x=1){return A};var B=function B(){return B}";
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var initial = Analyzer.init(a, &parser.ast);
    initial.enable_exact_declaration_anchors = true;
    try initial.analyze();
    var functions: [2]ast.NodeIndex = undefined;
    var count: usize = 0;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_expression) continue;
        try std.testing.expect(count < functions.len);
        functions[count] = @fromBackingInt(@as(u32, @intCast(raw)));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    var input: names.Input = .{ .source = &parser.ast, .source_node_count = @intCast(parser.ast.nodes.items.len), .symbols = initial.symbols.items, .scopes = initial.scopes.items, .symbol_ids = initial.symbol_ids.items, .owners = &initial.scope_owner_map, .references = initial.references.items };
    const first = functions[0];
    const second = functions[1];
    const sid = names.selfBinding(input, first) orelse return error.MissingFirstExactNfeRole;
    const sibling = names.selfBinding(input, second) orelse return error.MissingSiblingExactNfeRole;
    try std.testing.expect(sid != sibling);
    const first_node = parser.ast.getNode(first);
    const name = parser.ast.readExtraNode(first_node.data.extra, ast.FunctionExtra.name);
    const params = parser.ast.readExtraNode(first_node.data.extra, ast.FunctionExtra.params);
    const body_scope = initial.scope_owner_map.get(@backingInt(first)).?;
    const params_scope = initial.scope_owner_map.get(@backingInt(params)).?;
    const sibling_scope = initial.scope_owner_map.get(@backingInt(second)).?;
    try std.testing.expect(params_scope != body_scope);
    const name_scope = initial.symbols.items[sid].scope_id;
    initial.symbol_ids.items[@backingInt(name)] = sibling;
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    initial.symbol_ids.items[@backingInt(name)] = sid;
    const kind = initial.symbols.items[sid].kind;
    initial.symbols.items[sid].kind = .variable_var;
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    initial.symbols.items[sid].kind = kind;
    try initial.scope_owner_map.put(a, @backingInt(first), sibling_scope);
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    try initial.scope_owner_map.put(a, @backingInt(first), body_scope);
    try initial.scope_owner_map.put(a, @backingInt(params), sibling_scope);
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    try initial.scope_owner_map.put(a, @backingInt(params), params_scope);
    const parent = initial.scopes.items[name_scope.toIndex()].parent;
    initial.scopes.items[name_scope.toIndex()].parent = @fromBackingInt(body_scope);
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    const cyclic_set = try names.collect(a, input);
    try std.testing.expect(!cyclic_set.ids.contains(sid));
    initial.scopes.items[name_scope.toIndex()].parent = parent;
    var declaration: ?usize = null;
    for (initial.references.items, 0..) |ref, i| if (ref.declaration_node_index == name) {
        declaration = i;
    };
    const sibling_name = parser.ast.readExtraNode(parser.ast.getNode(second).data.extra, ast.FunctionExtra.name);
    initial.symbol_ids.items[@backingInt(sibling_name)] = sid;
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    const duplicate_set = try names.collect(a, input);
    try std.testing.expect(!duplicate_set.ids.contains(sid));
    initial.symbol_ids.items[@backingInt(sibling_name)] = sibling;
    try std.testing.expectEqual(@as(?u32, sid), names.selfBinding(input, first));
    const row_index = declaration.?;
    const row = initial.references.items[row_index];
    initial.references.items[row_index].declaration_node_index = .none;
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    initial.references.items[row_index] = row;
    initial.references.items[row_index].scope_id = @fromBackingInt(sibling_scope);
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    initial.references.items[row_index] = row;
    initial.references.items[row_index].flags.write = true;
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
    initial.references.items[row_index] = row;
    try std.testing.expectEqual(@as(?u32, sid), names.selfBinding(input, first));
    const set = try names.collect(a, input);
    var foreign_ast = parser.ast;
    try std.testing.expect(!set.contains(&foreign_ast, initial.symbols.items, initial.scopes.items, initial.references.items, sid));
    const foreign_symbols = try a.dupe(@import("../semantic/symbol.zig").Symbol, initial.symbols.items);
    try std.testing.expect(!set.contains(&parser.ast, foreign_symbols, initial.scopes.items, initial.references.items, sid));
    const foreign_scopes = try a.dupe(@import("../semantic/scope.zig").Scope, initial.scopes.items);
    try std.testing.expect(!set.contains(&parser.ast, initial.symbols.items, foreign_scopes, initial.references.items, sid));
    const foreign_refs = try a.dupe(@import("../semantic/symbol.zig").Reference, initial.references.items);
    try std.testing.expect(!set.contains(&parser.ast, initial.symbols.items, initial.scopes.items, foreign_refs, sid));
    try std.testing.expect(!set.contains(null, initial.symbols.items, initial.scopes.items, initial.references.items, sid));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const source_node_count = parser.ast.nodes.items.len;
    const source_reference_count = initial.references.items.len;
    try std.testing.expectError(error.OutOfMemory, names.collect(failing.allocator(), input));
    try std.testing.expectEqual(source_node_count, parser.ast.nodes.items.len);
    try std.testing.expectEqual(source_reference_count, initial.references.items.len);
    try std.testing.expectEqual(@as(?u32, sid), names.selfBinding(input, first));
    const NameContext = struct {
        fn get(context: *const anyopaque, binding: @import("../semantic/symbol.zig").Symbol) []const u8 {
            const tree: *const ast.Ast = @ptrCast(@alignCast(context));
            return tree.getText(binding.name);
        }
    };
    // An absent source domain cannot promote output AST into NFE authority.
    const old_table = try @import("block_rename_table.zig").build(a, .{
        .scopes = initial.scopes.items,
        .symbols = initial.symbols.items,
        .scope_maps = initial.scope_maps.items,
        .references = initial.references.items,
        .unresolved = &initial.unresolved_references,
        .ctx = &parser.ast,
        .nameOf = NameContext.get,
        .nfe_self_bindings = &set,
        .source_ast = null,
    });
    try std.testing.expect(old_table.contains(sid));
    input.source_node_count = 0;
    try std.testing.expectEqual(@as(?u32, null), names.selfBinding(input, first));
}

fn runtimeComparison(source: []const u8, minify: bool, module_input: bool) !void {
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = if (module_input) "entry.mjs" else "entry.cjs";
    try helpers.writeFile(tmp.dir, filename, source);
    const entry = try helpers.absPath(&tmp, filename);
    defer std.testing.allocator.free(entry);
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", entry } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = compat.fromESTarget(.es5), .minify_identifiers = minify, .keep_names = true });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    try helpers.writeFile(tmp.dir, "output.cjs", result.output);
    const output = try helpers.absPath(&tmp, "output.cjs");
    defer std.testing.allocator.free(output);
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output } });
    if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("NFE runtime minify={any} source={s}\nexpected={s}actual={s}stderr={s}\n{s}\n", .{ minify, source, native.stdout, actual.stdout, actual.stderr, result.output });
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
}

test "NFE name environment ten inputs and ten ordinary controls preserve native names" {
    var failures: usize = 0;
    for (inputs, 0..) |source, index| for ([_]bool{ false, true }) |minify| {
        runtimeComparison(source, minify, false) catch |err| {
            std.debug.print("NFE ROW cohort=original-input index={d} minify={any} status={s}\n", .{ index, minify, @errorName(err) });
            failures += 1;
            continue;
        };
        std.debug.print("NFE ROW cohort=original-input index={d} minify={any} status=PASS\n", .{ index, minify });
    };
    for (controls, 0..) |source, index| for ([_]bool{ false, true }) |minify| {
        runtimeComparison(source, minify, false) catch |err| {
            std.debug.print("NFE ROW cohort=ordinary-control index={d} minify={any} status={s}\n", .{ index, minify, @errorName(err) });
            failures += 1;
            continue;
        };
        std.debug.print("NFE ROW cohort=ordinary-control index={d} minify={any} status=PASS\n", .{ index, minify });
    };
    std.debug.print("NFE ROW COMPLETE original=20 controls=20 failures={d}\n", .{failures});
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "NFE name environment generated Object module contrast is separate from CJS inputs" {
    var failures: usize = 0;
    for ([_]bool{ false, true }) |minify| runtimeComparison(inputs[9], minify, true) catch {
        failures += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), failures);
}

const ancestor_cases = [_][]const u8{
    inputs[9],
    "var Object=function Object(){return(function Object(){var k='x',o={get[k](){return 3}};return [Object.name,o.x]})()};console.log(Object.name,JSON.stringify(Object()))",
    "function outer(Object){return(function Object(){var k='x',o={get[k](){return 3}};return [Object.name,o.x]})()}console.log(JSON.stringify(outer({})))",
    "var Object=function Object(){var k='x',o={get[k](){return 3}};return o.x};function sibling(Object){return Object.keep}console.log(Object.name,Object(),sibling({keep:7}))",
    "var Object=function Object(){return Object.name};console.log(Object.name,Object())",
};
const dynamic_cases = [_][]const u8{
    "var Object=function Object(){var k='x',o={get[k](){return 3}};return [eval('Object')===Object,o.x]};console.log(Object.name,JSON.stringify(Object()))",
    "var Object=function Object(){var k='x',o;with({}){o={get[k](){return 3}}}return o.x};console.log(Object.name,Object())",
};

test "NFE name environment actual marked two and three ancestors and sibling controls" {
    var failures: usize = 0;
    for (ancestor_cases, 0..) |source, index| for ([_]bool{ false, true }) |minify| {
        runtimeComparison(source, minify, false) catch |err| {
            std.debug.print("NFE ANCESTOR ROW case={d} minify={any} status={s}\n", .{ index, minify, @errorName(err) });
            failures += 1;
            continue;
        };
        std.debug.print("NFE ANCESTOR ROW case={d} minify={any} status=PASS\n", .{ index, minify });
    };
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// Actual marked reference -> actual AST parent -> actual semantic scope chain.
// The same function also verifies the existing dynamic-scope rename veto.
fn checkAncestorGraph(source: []const u8, expected_bindings: usize, dynamic: bool, sibling_control: bool) !void {
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    const Graph = @import("../bundler/graph.zig").ModuleGraph;
    const Linker = @import("../bundler/linker.zig").Linker;
    const SymbolID = @import("../bundler/symbol.zig").SymbolID;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.cjs", source);
    const entry = try helpers.absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);
    var cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs });
    defer cache.deinit();
    var graph = Graph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    graph.transform_options_base = .{ .unsupported = compat.fromESTarget(.es5), .keep_names = true };
    try graph.build(std.testing.io, &.{entry});
    const index = graph.path_to_module.get(entry) orelse return error.MissingEntry;
    const module = graph.getModule(index) orelse return error.MissingModule;
    const tree = &module.ast.?;
    const sem = &module.semantic.?;
    var linker = Linker.init(std.testing.allocator, &graph, .cjs);
    defer linker.deinit();
    linker.keep_names = true;
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
    const transform = module.transform_cache orelse {
        // No marker-producing transform ran. Do not fabricate a cache record.
        try std.testing.expectEqual(@as(usize, 0), expected_bindings);
        try std.testing.expect(!dynamic);
        var source_declarations: usize = 0;
        for (sem.references) |row| {
            if (!row.flags.declare or row.declaration_node_index.isNone() or row.symbol_id.isNone()) continue;
            const sid = @backingInt(row.symbol_id);
            const binding = sem.symbols.items[sid];
            if (binding.synthetic_kind != null) continue;
            const anchor = row.declaration_node_index;
            try std.testing.expectEqual(@as(?u32, sid), sem.symbol_ids[@backingInt(anchor)]);
            try std.testing.expectEqual(binding.scope_id, row.scope_id);
            if (linker.rename_table.get(SymbolID.make(index, sid))) |selected|
                try std.testing.expectEqualStrings(tree.getText(tree.getNode(anchor).span), selected);
            source_declarations += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), source_declarations);
        return;
    };
    const root = tree.transformed_root orelse return error.MissingOutputRoot;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Frame = struct { node: ast.NodeIndex, parent: ?ast.NodeIndex };
    var stack: std.ArrayList(Frame) = .empty;
    var parents: std.AutoHashMapUnmanaged(ast.NodeIndex, ast.NodeIndex) = .empty;
    try stack.append(a, .{ .node = root, .parent = null });
    while (stack.pop()) |frame| {
        if (frame.node.isNone()) continue;
        if (@backingInt(frame.node) >= tree.nodes.items.len) return error.InvalidTraceNode;
        if (frame.parent) |parent| {
            const slot = try parents.getOrPut(a, frame.node);
            if (slot.found_existing) {
                try std.testing.expectEqual(parent, slot.value_ptr.*);
                continue;
            }
            slot.value_ptr.* = parent;
        }
        var children = @import("../parser/ast_walk.zig").children(tree, tree.getNode(frame.node));
        while (children.next()) |child| try stack.append(a, .{ .node = child, .parent = frame.node });
    }
    var observed: usize = 0;
    for (transform.explicit_global_ref_nodes) |raw| {
        const reference: ast.NodeIndex = @fromBackingInt(raw);
        if (!parents.contains(reference)) continue;
        const name = tree.getText(tree.getNode(reference).data.string_ref);
        var owner = reference;
        var output_scope: ?u32 = null;
        for (0..tree.nodes.items.len) |_| {
            if (sem.scope_owner_map.get(@backingInt(owner))) |scope_id| {
                output_scope = scope_id;
                break;
            }
            owner = parents.get(owner) orelse break;
        }
        var scope_id = output_scope orelse continue;
        var bindings: usize = 0;
        for (0..sem.scopes.len) |_| {
            if (scope_id >= sem.scopes.len) return error.InvalidScope;
            if (scope_id < sem.scope_maps.len) if (sem.scope_maps[scope_id].get(name)) |sid| {
                var anchor: ast.NodeIndex = .none;
                for (sem.references) |row| if (@backingInt(row.symbol_id) == sid and row.flags.declare) {
                    anchor = row.declaration_node_index;
                };
                const selected = linker.rename_table.get(SymbolID.make(index, sid)) orelse name;
                try std.testing.expectEqual(dynamic, std.mem.eql(u8, selected, name));
                std.debug.print("NFE ANCESTOR module={d} marker={d} scope={d} SID={d} anchor={d} kind={s} dynamic={any} selected={s}\n", .{ index.toU32(), raw, scope_id, sid, @backingInt(anchor), @tagName(sem.symbols.items[sid].kind), sem.scopes[scope_id].blocksMangling(), selected });
                bindings += 1;
            };
            const parent = sem.scopes[scope_id].parent;
            if (parent.isNone()) break;
            scope_id = parent.toIndex();
        }
        if (bindings > observed) observed = bindings;
    }
    try std.testing.expectEqual(expected_bindings, observed);
    try std.testing.expectEqual(dynamic, sem.scopes[0].blocksMangling());
    if (dynamic) {
        // Dynamic accessors no longer mint a global Object read: a registered
        // provider or the native object owns that operation. The source NFE
        // name must nevertheless remain attached and pinned by direct eval/with.
        var source_names: usize = 0;
        for (tree.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_expression or !parents.contains(@fromBackingInt(@as(u32, @intCast(raw))))) continue;
            const name_node = tree.readExtraNode(node.data.extra, ast.FunctionExtra.name);
            if (name_node.isNone()) continue;
            const binding_node = tree.getNode(name_node);
            if (binding_node.tag != .binding_identifier) continue;
            const sid = sem.symbol_ids[@backingInt(name_node)] orelse return error.MissingDynamicNameSid;
            const symbol = sem.symbols.items[sid];
            if (symbol.synthetic_kind != null) continue;
            try std.testing.expectEqualStrings("Object", tree.getText(binding_node.span));
            const mapped_sid = sem.scope_maps[symbol.scope_id.toIndex()].get(tree.getText(binding_node.span)) orelse return error.MissingDynamicNameMap;
            try std.testing.expectEqual(@as(usize, sid), @as(usize, mapped_sid));
            try std.testing.expect(sem.scopes[symbol.scope_id.toIndex()].kind == .block);
            const selected = linker.rename_table.get(SymbolID.make(index, sid)) orelse tree.getText(binding_node.span);
            try std.testing.expectEqualStrings(tree.getText(binding_node.span), selected);
            var declarations: usize = 0;
            for (sem.references) |row| if (row.declaration_node_index == name_node and row.flags.declare) {
                try std.testing.expectEqual(sid, @backingInt(row.symbol_id));
                try std.testing.expectEqual(symbol.scope_id, row.scope_id);
                declarations += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), declarations);
            source_names += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), source_names);
    }
    if (sibling_control) {
        var sibling_parameters: usize = 0;
        for (tree.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration or !parents.contains(@fromBackingInt(@as(u32, @intCast(raw))))) continue;
            const params = tree.functionParamsList(node);
            if (params.len != 1) continue;
            const parameter = tree.readExtraNode(params.start, 0);
            if (tree.getNode(parameter).tag != .binding_identifier) continue;
            const sid = sem.symbol_ids[@backingInt(parameter)] orelse return error.MissingSiblingParameter;
            const selected = linker.rename_table.get(SymbolID.make(index, sid));
            if (selected) |text| try std.testing.expectEqualStrings(tree.getText(tree.getNode(parameter).span), text);
            sibling_parameters += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), sibling_parameters);
    }
}

test "NFE name environment actual generated global ancestor SID trace" {
    try checkAncestorGraph(ancestor_cases[0], 2, false, false);
    try checkAncestorGraph(ancestor_cases[1], 3, false, false);
    try checkAncestorGraph(ancestor_cases[2], 2, false, false);
    try checkAncestorGraph(ancestor_cases[3], 2, false, true);
    try checkAncestorGraph(ancestor_cases[4], 0, false, false);
    try checkObjectAccessorDescriptorProvider();
    try checkNativeAccessorBoundary(dynamic_cases[1], .object_accessor_with_scope);
    for (dynamic_cases) |source| {
        try checkAncestorGraph(source, 0, true, false);
        for ([_]bool{ false, true }) |minify| try runtimeComparison(source, minify, false);
    }
}

test "object accessor pinned eval uses actual descriptor provider and preserves native runtime" {
    for ([_]bool{ false, true }) |minify| try runtimeComparison(dynamic_cases[0], minify, false);
}

fn checkObjectAccessorDescriptorProvider() !void {
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    const Graph = @import("../bundler/graph.zig").ModuleGraph;
    const Linker = @import("../bundler/linker.zig").Linker;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.cjs", dynamic_cases[0]);
    const entry = try helpers.absPath(&tmp, "entry.cjs");
    defer a.free(entry);
    var cache = Bundler.initResolveCacheFromOptions(a, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs });
    defer cache.deinit();
    var graph = Graph.init(a, &cache);
    defer graph.deinit();
    graph.transform_options_base = .{ .unsupported = compat.fromESTarget(.es5), .keep_names = true };
    try graph.build(std.testing.io, &.{entry});
    const index = graph.path_to_module.get(entry) orelse return error.MissingEntry;
    const module = graph.getModule(index) orelse return error.MissingModule;
    const tree = &module.ast.?;
    const sem = &module.semantic.?;
    try std.testing.expect(sem.owner_token != .unassigned);
    var descriptor: ?u32 = null;
    var imports: usize = 0;
    for (module.import_bindings) |binding| {
        if (!binding.is_helper) continue;
        try std.testing.expect(!std.mem.eql(u8, binding.imported_name, "__classCallCheck"));
        if (!std.mem.eql(u8, binding.imported_name, "__classDefineProperty")) continue;
        imports += 1;
        const local = binding.local_symbol_node orelse return error.MissingDescriptorAnchor;
        const sid = sem.symbol_ids[@backingInt(local)] orelse return error.MissingDescriptorSid;
        try std.testing.expectEqual(binding.local_symbol.semanticIndex().?, sid);
        try std.testing.expectEqual(@as(?usize, sid), sem.helper_scope_map.get("__classDefineProperty"));
        try std.testing.expect(binding.import_record_index < module.import_records.len);
        const provider = graph.getModule(module.import_records[binding.import_record_index].resolved) orelse return error.MissingProvider;
        try std.testing.expectEqualStrings(@import("../runtime_helper_modules.zig").ID_PREFIX ++ "class-define-property", provider.path);
        try std.testing.expect(provider.semantic.?.owner_token != .unassigned);
        const exported = provider.findExportBinding("__classDefineProperty") orelse return error.MissingExport;
        const export_node = exported.local_symbol_node orelse return error.MissingExportAnchor;
        const export_sid = provider.semantic.?.symbol_ids[@backingInt(export_node)] orelse return error.MissingExportSid;
        try std.testing.expectEqual(exported.symbol.semanticIndex().?, export_sid);
        try std.testing.expectEqual(@as(?u32, export_sid), provider.findLocalExportSemanticIndex("__classDefineProperty"));
        descriptor = sid;
    }
    try std.testing.expectEqual(@as(usize, 1), imports);
    const sid = descriptor orelse return error.MissingDescriptor;
    const root = tree.transformed_root orelse return error.MissingRoot;
    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, tree, root);
    defer a.free(reachable);
    var traces = try @import("symbol_coverage.zig").collectScopeTraces(a, tree, root, sem.scopes, &sem.scope_owner_map);
    defer traces.deinit(a);
    var calls: usize = 0;
    for (reachable) |raw| {
        const call = tree.nodes.items[raw];
        if (call.tag != .call_expression or tree.extra_data.items[call.data.extra + 2] != 3) continue;
        const callee = tree.extra_data.items[call.data.extra];
        if (callee >= sem.symbol_ids.len or sem.symbol_ids[callee] != @as(?u32, sid)) continue;
        const trace = traces.get(callee) orelse return error.MissingUseScope;
        try std.testing.expect(trace.valid and !trace.ambiguous and trace.scope_id != null);
        var reads: usize = 0;
        for (sem.references) |reference| if (@backingInt(reference.node_index) == callee) {
            try std.testing.expectEqual(sid, @backingInt(reference.symbol_id));
            try std.testing.expectEqual(trace.scope_id.?, @backingInt(reference.scope_id));
            try std.testing.expect(reference.flags.read and !reference.flags.write and !reference.flags.declare);
            reads += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), reads);
        calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), calls);
    var linker = Linker.init(a, &graph, .cjs);
    defer linker.deinit();
    linker.keep_names = true;
    try linker.link();
    try linker.finalize(.{ .compute_renames = true, .compute_mangling = false });
}

test "object accessor pinned eval publishes exact helper import provider and use scope" {
    try checkObjectAccessorDescriptorProvider();
}

fn checkNativeAccessorBoundary(source: []const u8, code: @FieldType(@import("../bundler/types.zig").BundlerDiagnostic, "code")) !void {
    const helpers = @import("../bundler/test_helpers.zig");
    const Bundler = @import("../bundler/bundler.zig").Bundler;
    const Graph = @import("../bundler/graph.zig").ModuleGraph;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.cjs", source);
    const entry = try helpers.absPath(&tmp, "entry.cjs");
    defer a.free(entry);
    var cache = Bundler.initResolveCacheFromOptions(a, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs });
    defer cache.deinit();
    var graph = Graph.init(a, &cache);
    defer graph.deinit();
    graph.transform_options_base = .{ .unsupported = compat.fromESTarget(.es5), .keep_names = true };
    try graph.build(std.testing.io, &.{entry});
    const module = graph.getModule(graph.path_to_module.get(entry).?).?;
    const tree = &module.ast.?;
    const sem = &module.semantic.?;
    const root = tree.transformed_root orelse return error.MissingRoot;
    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, tree, root);
    defer a.free(reachable);
    var retained: usize = 0;
    for (reachable) |raw| {
        const member = tree.nodes.items[raw];
        if (member.tag != .method_definition) continue;
        const flags = tree.readExtra(member.data.extra, ast.MethodExtra.flags);
        if (flags & (ast.MethodFlags.is_getter | ast.MethodFlags.is_setter) == 0) continue;
        const key = tree.readExtraNode(member.data.extra, ast.MethodExtra.key);
        if (tree.getNode(key).tag != .computed_property_key) continue;
        const owner = sem.scope_owner_map.get(raw) orelse return error.MissingNativeOwner;
        var source_owner: ?u32 = null;
        for (sem.scope_history.source_owners) |original| if (@backingInt(original.owner.node) == raw) {
            try std.testing.expect(source_owner == null);
            source_owner = @backingInt(original.scope);
        };
        try std.testing.expectEqual(owner, source_owner orelse return error.MissingSourceOwner);
        try std.testing.expectEqual(sem.scope_history.source_scopes[owner].parent, sem.scopes[owner].parent);
        try std.testing.expectEqual(sem.scope_history.source_scopes[owner].is_strict, sem.scopes[owner].is_strict);
        const read = tree.getNode(key).data.unary.operand;
        const sid = sem.symbol_ids[@backingInt(read)] orelse return error.MissingNativeKeySid;
        var declarations: usize = 0;
        for (sem.references) |reference| if (@backingInt(reference.symbol_id) == sid and reference.flags.declare) {
            try std.testing.expect(!reference.declaration_node_index.isNone());
            try std.testing.expectEqual(@as(?u32, sid), sem.symbol_ids[@backingInt(reference.declaration_node_index)]);
            declarations += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), declarations);
        retained += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), retained);
    for (module.import_bindings) |binding| try std.testing.expect(!binding.is_helper);
    var warnings: usize = 0;
    for (graph.diagnostics.items) |diagnostic| {
        try std.testing.expect(diagnostic.code != .arrow_dynamic_scope);
        if (diagnostic.code == code) {
            try std.testing.expect(diagnostic.severity == .warning);
            warnings += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), warnings);
}

test "object accessor with preserves native runtime trap order and mutation controls" {
    const with_controls = [_][]const u8{
        dynamic_cases[1],
        "var Object=function Object(){var k='x',o,events=[];var scope=new Proxy({},{has:function has(t,key){events.push(String(key));return false}});with(scope){o={get[k](){return 3}}}return[o.x,events]};console.log(JSON.stringify(Object()))",
        "var saved=globalThis.Object.defineProperty;globalThis.Object.defineProperty=function badDefine(){throw Error('unexpected builtin')};var Object=function Object(){var k='x',o;with({}){o={get[k](){return 3}}}return o.x};console.log(Object.name,Object());globalThis.Object.defineProperty=saved",
        "var saved=globalThis.Object.prototype.constructor;globalThis.Object.prototype.constructor=17;var Object=function Object(){var k='x',o;with({}){o={get[k](){return 3}}}return o.x};console.log(Object.name,Object());globalThis.Object.prototype.constructor=saved",
        "var Object=function Object(){var k='x',o;with({Object:{defineProperty:function badObject(){throw Error('captured')}},__classDefineProperty:function badHelper(){throw Error('captured')},$cDp:function badShortHelper(){throw Error('captured')}}){o={get[k](){return 3}}}return o.x};console.log(Object.name,Object())",
    };
    for (with_controls) |source| for ([_]bool{ false, true }) |minify| try runtimeComparison(source, minify, false);
}

test "object accessor with retains native source owners and reports explicit target boundary" {
    try checkNativeAccessorBoundary(dynamic_cases[1], .object_accessor_with_scope);
}

const opaque_eval_accessor = "var Object=function Object(code){var k='x';eval(code);var o={get[k](){return 3}};return o.x};console.log(Object.name,Object('var __classDefineProperty=function bad(){throw 17};var $cDp=function shortBad(){throw 19}'))";

test "object accessor opaque eval retains native source owners and reports explicit target boundary" {
    try checkNativeAccessorBoundary(opaque_eval_accessor, .object_accessor_eval_scope);
}

test "object accessor opaque eval cannot capture generated helper names" {
    const eval_controls = [_][]const u8{
        opaque_eval_accessor,
        "var Object=function Object(){var k='x';eval('var __classDefineProperty=function bad(){throw 17};var $cDp=function shortBad(){throw 19}');var o={get[k](){return 3}};return o.x};console.log(Object.name,Object())",
        "var Object=function Object(code){var k='x',o={get[k](){return 3}};eval(code);return o.x};console.log(Object.name,Object('var __classDefineProperty=17;var $cDp=19'))",
        "var Object=function Object(code){var k='x';eval(code);var o={get[k](){return 3}};return [o.x,eval('Object')===Object]};console.log(Object.name,JSON.stringify(Object('var __classDefineProperty=17;var $cDp=19')))",
    };
    for (eval_controls) |source| for ([_]bool{ false, true }) |minify| try runtimeComparison(source, minify, false);
}
