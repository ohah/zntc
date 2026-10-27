const std = @import("std");
const helpers = @import("../bundler/test_helpers.zig");
const bundler = @import("../bundler/bundler.zig");
const profile = @import("../profile.zig");
const inputs = [_][]const u8{
    "const obj={value:3};const result=(obj?.value ?? 7);console.log(result);",
    "const obj=null;const result=(obj?.value ?? 7);console.log(result);",
    "let calls=0;const obj={value:3};function key(){calls++;return \"value\"}const result=(obj?.[key()] ?? 7);console.log(result,calls);",
    "let calls=0;function get(){calls++;return {value:3}}const result=(get()?.value ?? 7);console.log(result,calls);",
    "let calls=0;function get(){calls++;return undefined}const result=(get()?.value ?? 7);console.log(result,calls);",
    "const obj={value:0};const result=(obj?.value ?? 7);console.log(result);",
    "const obj={value:false};const result=(obj?.value ?? 7);console.log(result);",
    "const obj={nested:{value:3}};const result=(obj?.nested.value ?? 7);console.log(result);",
    "let calls=0;const obj={value:null};function fallback(){calls++;return 7}const result=(obj?.value ?? fallback());console.log(result,calls);",
    "const obj={value:3};function sibling(){const obj={value:9};return obj?.value}const result=(obj?.value ?? 7);console.log(result,sibling());",
};

test "optional nullish composition retains exact member graph and native effects" {
    for (inputs) |source| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", source);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", entry } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var b = bundler.Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es2019), .minify_identifiers = minify });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", output } });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

const ast_mod = @import("../parser/ast.zig");
const sem_mod = @import("../bundler/module.zig");
const symbol = @import("../semantic/symbol.zig");
const Cert = @import("optional_nullish_composition.zig");
const Transformer = @import("transformer.zig").Transformer;
const Fixture = struct {
    t: Transformer,
    sem: sem_mod.ModuleSemanticData,
    root: ast_mod.NodeIndex,
    source_count: usize,
    fn init(a: std.mem.Allocator, text: []const u8) !Fixture {
        return initWithPublication(a, text, true);
    }
    fn initWithPublication(a: std.mem.Allocator, text: []const u8, publish: bool) !Fixture {
        return initWithMode(a, text, publish, true);
    }
    fn initWithMode(a: std.mem.Allocator, text: []const u8, publish: bool, late_names: bool) !Fixture {
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, text);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        const input_ast = try a.create(ast_mod.Ast);
        input_ast.* = parser.ast;
        const analyzer = try a.create(@import("../semantic/analyzer.zig").SemanticAnalyzer);
        analyzer.* = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, input_ast);
        analyzer.is_module = true;
        analyzer.enable_exact_declaration_anchors = true;
        analyzer.enable_stmt_info = true;
        try analyzer.analyze();
        var sem: sem_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        _ = sem.captureOwnerToken();
        const options: @import("transformer.zig").TransformOptions = .{ .unsupported = @import("compat.zig").fromESTarget(.es2019), .defer_runtime_helper_name_resolution = late_names, .emit_runtime_helper_imports = !late_names };
        var source = (try @import("../bundler/graph/transform_prepass.zig").optionalNullishSource(a, input_ast, &sem, options)) orelse return error.MissingCompositionSource;
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
        source.owner = sem.owner_token;
        source.output = t.ast;
        t.optional_nullish_source = source;
        const source_count = sem.symbols.items.len;
        const root = try t.transform();
        sem.applyEdit((try t.finishSemanticEdit()).?);
        // Missing birth records are a failed factory contract, not permission
        // for tests to index a nonexistent application and crash.
        try std.testing.expectEqual(source.inputs.len, t.optional_nullish_applications.items.len);
        if (publish) try std.testing.expect(try Cert.publishPositions(&t, &sem, root));
        return .{ .t = t, .sem = sem, .root = root, .source_count = source_count };
    }
};

test "optional nullish composition records known births and restores borrowed capture" {
    for (inputs) |text| for ([_]bool{ false, true }) |late_names| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.initWithMode(a, text, true, late_names);
        try std.testing.expect(f.t.optional_nullish_capture == null);
        try std.testing.expectEqual(@as(usize, 1), f.t.optional_nullish_applications.items.len);
        try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
        const app = f.t.optional_nullish_applications.items[0];
        try std.testing.expect(app.sid >= f.source_count);
        try std.testing.expectEqual(app.sid, f.t.temp_symbols_by_producer_id.get(app.producer).?);
        try std.testing.expectEqual(@as(u32, 0), @backingInt(app.scope));
        const result = f.t.ast.getNode(app.result);
        try std.testing.expectEqual(ast_mod.Node.Tag.conditional_expression, result.tag);
        try std.testing.expectEqual(app.read, result.data.ternary.b);
        try std.testing.expectEqual(app.right, result.data.ternary.c);
        const condition = f.t.ast.getNode(result.data.ternary.a);
        const capture = f.t.ast.getNode(condition.data.binary.left);
        try std.testing.expectEqual(app.write, capture.data.binary.left);
        try std.testing.expectEqual(app.inner.result, capture.data.binary.right);
        const positions = try @import("../semantic/statement_coordinates.zig").collect(a, f.t.ast, f.root);
        for ([_]ast_mod.NodeIndex{ app.write, app.read }, 0..) |node, i| {
            var count: usize = 0;
            for (f.sem.references) |row| if (row.node_index == node) {
                count += 1;
                try std.testing.expectEqual(app.sid, @backingInt(row.symbol_id));
                try std.testing.expectEqual(app.scope, row.scope_id);
                try std.testing.expectEqual(i == 0, row.flags.write);
                try std.testing.expectEqual(i == 1, row.flags.read);
                try std.testing.expectEqual(positions[@backingInt(node)].?.stmt_idx, row.stmt_idx);
                try std.testing.expectEqual(positions[@backingInt(node)].?.scope_stmt_idx, row.scope_stmt_idx);
            };
            try std.testing.expectEqual(@as(usize, 1), count);
        }
        if (app.inner.producer != 0) {
            try std.testing.expect(app.inner.producer != app.producer);
            try std.testing.expect(app.inner.sid.? >= f.source_count and app.inner.sid.? != app.sid);
        }
    };
}

test "optional nullish composition rejects foreign and corrupted authority without writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, inputs[3]);
    try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    const source = f.t.optional_nullish_source.?;
    var foreign_ast = try f.t.ast.cloneForTransformer(a);
    var foreign_sem = f.sem;
    foreign_sem.owner_token = .unassigned;
    _ = foreign_sem.captureOwnerToken();
    const rows = try a.dupe(symbol.Reference, f.sem.references);
    const ids = try a.dupe(?u32, f.sem.symbol_ids);
    const scopes = try a.dupe(@import("../semantic/scope.zig").Scope, f.sem.scopes);
    const app = f.t.optional_nullish_applications.items[0];
    const Reject = struct {
        fn call(fixture: *Fixture, previous: []const symbol.Reference) !void {
            try std.testing.expect(!try Cert.complete(&fixture.t, &fixture.sem, fixture.root));
            for (previous, fixture.sem.references) |before, after| try std.testing.expect(std.meta.eql(before, after));
        }
    };
    for (0..4) |fault| {
        var bad = source;
        switch (fault) {
            0 => bad.owner = .unassigned,
            1 => bad.owner = foreign_sem.owner_token,
            2 => bad.ast = &foreign_ast,
            3 => bad.output = &foreign_ast,
            else => unreachable,
        }
        f.t.optional_nullish_source = bad;
        try Reject.call(&f, rows);
        f.t.optional_nullish_source = source;
        try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    }
    const saved_items = f.t.optional_nullish_applications.items;
    f.t.optional_nullish_applications.items = saved_items[0..0];
    try Reject.call(&f, rows);
    f.t.optional_nullish_applications.items = saved_items;
    try f.t.optional_nullish_applications.append(a, app);
    try Reject.call(&f, rows);
    f.t.optional_nullish_applications.shrinkRetainingCapacity(1);
    for (0..8) |fault| {
        var bad = app;
        switch (fault) {
            0 => bad.scope = @fromBackingInt(1),
            1 => bad.producer = app.inner.producer,
            2 => bad.sid = app.inner.sid.?,
            3 => bad.read = app.write,
            4 => bad.write = app.read,
            5 => bad.inner.result = app.right,
            6 => bad.right = app.inner.result,
            7 => bad.input.left = app.input.right,
            else => unreachable,
        }
        f.t.optional_nullish_applications.items[0] = bad;
        try Reject.call(&f, rows);
        f.t.optional_nullish_applications.items[0] = app;
        try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    }
    const node = f.t.ast.nodes.items[@backingInt(app.result)];
    const replacement_literal = try f.t.ast.addNode(f.t.ast.getNode(app.right));
    f.t.ast.nodes.items[@backingInt(app.result)].data.ternary.c = replacement_literal;
    try Reject.call(&f, rows);
    f.t.ast.nodes.items[@backingInt(app.result)] = node;
    for (f.sem.references, 0..) |row, index| {
        if (row.node_index != app.write) continue;
        for (0..4) |fault| {
            var bad = row;
            switch (fault) {
                0 => bad.scope_id = @fromBackingInt(1),
                1 => bad.flags.read = true,
                2 => bad.stmt_idx += 1,
                3 => bad.scope_stmt_idx += 1,
                else => unreachable,
            }
            @constCast(f.sem.references)[index] = bad;
            try std.testing.expect(!try Cert.complete(&f.t, &f.sem, f.root));
            @constCast(f.sem.references)[index] = row;
        }
    }
    try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    for (rows, f.sem.references) |before, after| try std.testing.expect(std.meta.eql(before, after));
    try std.testing.expectEqualSlices(?u32, ids, f.sem.symbol_ids);
    for (scopes, f.sem.scopes) |before, after| try std.testing.expect(std.meta.eql(before, after));
    try std.testing.expect(std.meta.eql(app, f.t.optional_nullish_applications.items[0]));
}

test "optional nullish composition publishes coordinates atomically and never heals twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.initWithPublication(a, inputs[3], false);
    try std.testing.expect(f.t.optional_nullish_published_root == null);
    try std.testing.expect(!try Cert.complete(&f.t, &f.sem, f.root));
    const app = f.t.optional_nullish_applications.items[0];
    const source = f.t.optional_nullish_source.?;
    const rows = try a.dupe(symbol.Reference, f.sem.references);
    const original_pointer = f.sem.references.ptr;
    for (0..4) |fault| {
        for (f.sem.references, 0..) |row, index| {
            if (row.node_index != app.write) continue;
            var bad = row;
            switch (fault) {
                0 => bad.scope_id = @fromBackingInt(1),
                1 => bad.flags.read = true,
                2 => bad.stmt_idx = 0,
                3 => bad.symbol_id = @fromBackingInt(app.inner.sid.?),
                else => unreachable,
            }
            @constCast(f.sem.references)[index] = bad;
            try std.testing.expect(!try Cert.publishPositions(&f.t, &f.sem, f.root));
            try std.testing.expectEqual(original_pointer, f.sem.references.ptr);
            try std.testing.expect(f.t.optional_nullish_published_root == null);
            try std.testing.expect(std.meta.eql(bad, f.sem.references[index]));
            @constCast(f.sem.references)[index] = row;
        }
    }
    var bad_source = source;
    bad_source.owner = .unassigned;
    f.t.optional_nullish_source = bad_source;
    try std.testing.expect(!try Cert.publishPositions(&f.t, &f.sem, f.root));
    try std.testing.expectEqual(original_pointer, f.sem.references.ptr);
    try std.testing.expect(f.t.optional_nullish_published_root == null);
    f.t.optional_nullish_source = source;
    for (rows, f.sem.references) |before, after| try std.testing.expect(std.meta.eql(before, after));
    for (f.sem.references, 0..) |row, index| {
        if (!row.flags.declare or @backingInt(row.symbol_id) != app.sid) continue;
        try std.testing.expectEqual(symbol.Reference.NO_STMT, row.stmt_idx);
        try std.testing.expectEqual(symbol.Reference.NO_STMT, row.scope_stmt_idx);
        for (0..2) |fault| {
            var bad = row;
            if (fault == 0) bad.stmt_idx = 0 else bad.scope_stmt_idx = 0;
            @constCast(f.sem.references)[index] = bad;
            try std.testing.expect(!try Cert.publishPositions(&f.t, &f.sem, f.root));
            try std.testing.expectEqual(original_pointer, f.sem.references.ptr);
            try std.testing.expect(f.t.optional_nullish_published_root == null);
            try std.testing.expect(std.meta.eql(bad, f.sem.references[index]));
            @constCast(f.sem.references)[index] = row;
        }
    }
    try std.testing.expect(try Cert.publishPositions(&f.t, &f.sem, f.root));
    try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    try std.testing.expectEqual(f.root, f.t.optional_nullish_published_root.?);
    for (rows, f.sem.references) |before, after| {
        var positions_only = before;
        positions_only.stmt_idx = after.stmt_idx;
        positions_only.scope_stmt_idx = after.scope_stmt_idx;
        try std.testing.expect(std.meta.eql(positions_only, after));
    }
    for (f.sem.references, 0..) |row, index| {
        if (row.node_index != app.write) continue;
        var bad = row;
        bad.scope_stmt_idx += 1;
        @constCast(f.sem.references)[index] = bad;
        try std.testing.expect(!try Cert.publishPositions(&f.t, &f.sem, f.root));
        try std.testing.expect(std.meta.eql(bad, f.sem.references[index]));
        @constCast(f.sem.references)[index] = row;
    }
    for (f.sem.references, 0..) |row, index| {
        if (!row.flags.declare or @backingInt(row.symbol_id) != app.sid) continue;
        const contexts = try @import("../semantic/statement_coordinates.zig").collect(a, f.t.ast, f.root);
        const actual = contexts[@backingInt(row.declaration_node_index)].?;
        try std.testing.expectEqual(actual.stmt_idx, row.stmt_idx);
        try std.testing.expectEqual(actual.scope_stmt_idx, row.scope_stmt_idx);
        for (0..2) |fault| {
            var bad = row;
            if (fault == 0) bad.stmt_idx += 1 else bad.scope_stmt_idx += 1;
            @constCast(f.sem.references)[index] = bad;
            try std.testing.expect(!try Cert.complete(&f.t, &f.sem, f.root));
            try std.testing.expect(!try Cert.publishPositions(&f.t, &f.sem, f.root));
            try std.testing.expect(std.meta.eql(bad, f.sem.references[index]));
            @constCast(f.sem.references)[index] = row;
        }
    }
    try std.testing.expect(try Cert.complete(&f.t, &f.sem, f.root));
    try std.testing.expect(std.meta.eql(app, f.t.optional_nullish_applications.items[0]));
}

test "optional nullish composition keeps ordinary controls and mixed unsafe source boundaries" {
    const rejected = [_][]const u8{
        "const o={value:3};console.log(o?.value);",
        "const value=null;console.log(value??7);",
        "const fn=()=>3;console.log(fn?.()??7);",
        "class C{#value=3;read(){return this?.#value??7}}",
        "const o={};console.log(o?.value??(()=>7));",
        "async function read(){const o={};return o?.value??7}",
        "const o={};function read(value=(o?.value??7)){return value}",
        "const o={};class C{static value=(o?.value??7)}",
        "const o={};eval('');console.log(o?.value??7);",
        "const o={};console.log(o?.[(()=> 'value')()]??7);",
        "const o={};const fn=()=>3;const a=o?.value??7;const b=fn?.()??7;",
    };
    for (rejected) |text| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, text);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        analyzer.is_module = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        const sem: sem_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        const options: @import("transformer.zig").TransformOptions = .{ .unsupported = @import("compat.zig").fromESTarget(.es2019) };
        const plan = try @import("../bundler/graph/transform_prepass.zig").optionalNullishSource(a, &parser.ast, &sem, options);
        try std.testing.expect(plan == null);
    }
}

test "native no-op graph native optional nullish preserves runtime without lowering births" {
    var observed_resyncs: u32 = 0;
    for (inputs, 0..) |source, index| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", source);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", entry } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var b = bundler.Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es2020), .minify_identifiers = minify });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const resyncs = profile.count(.graph_resync_semantic);
        observed_resyncs += resyncs;
        std.debug.print("NATIVE NOOP RED case={d} identifiers={} resync={d}\n", .{ index, minify, resyncs });
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(arena.allocator(), std.testing.io, .{ .argv = &.{ "node", output } });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
    // Execute every native control before reporting the admission failure.
    try std.testing.expectEqual(@as(u32, 0), observed_resyncs);
}

const Native = @import("native_noop_graph.zig");
const NativeFixture = struct {
    t: Transformer,
    sem: sem_mod.ModuleSemanticData,
    root: ast_mod.NodeIndex,
    fn init(a: std.mem.Allocator, text: []const u8) !NativeFixture {
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, text);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        const tree = try a.create(ast_mod.Ast);
        tree.* = parser.ast;
        const analyzer = try a.create(@import("../semantic/analyzer.zig").SemanticAnalyzer);
        analyzer.* = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, tree);
        analyzer.is_module = true;
        analyzer.enable_exact_declaration_anchors = true;
        analyzer.enable_stmt_info = true;
        try analyzer.analyze();
        var sem: sem_mod.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        _ = sem.captureOwnerToken();
        const options: @import("transformer.zig").TransformOptions = .{ .unsupported = @import("compat.zig").fromESTarget(.es2020) };
        const holder = try a.create(sem_mod.Module);
        holder.* = sem_mod.Module.init(@fromBackingInt(@as(u32, 0)), "native.mjs");
        holder.source = text;
        holder.module_type = .js;
        holder.ast = tree.*;
        holder.semantic = sem;
        var plan = (try Native.forModule(a, holder, options)) orelse return error.MissingNativeSource;
        var t = try Transformer.init(a, &holder.ast.?, options);
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
        plan.owner = sem.owner_token;
        plan.output = t.ast;
        t.native_noop_source = plan;
        const root = try t.transform();
        if (try t.finishSemanticEdit()) |edit| sem.applyEdit(edit);
        return .{ .t = t, .sem = sem, .root = root };
    }
};

test "native no-op graph native authority rejects foreign domains and changed source tuples without healing" {
    for (inputs) |text| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try NativeFixture.init(a, text);
        try std.testing.expect(f.t.native_noop_before_binder);
        try std.testing.expect(try Native.complete(&f.t, &f.sem, f.root));
        try std.testing.expectEqual(@as(usize, 0), f.t.optional_nullish_applications.items.len);
        try std.testing.expectEqual(@as(usize, 0), f.t.temp_symbols_by_producer_id.count());
        try std.testing.expectEqual(f.t.native_noop_source.?.symbols.len, f.sem.symbols.items.len);
        const before = try a.dupe(symbol.Reference, f.sem.references);
        const original = f.t.native_noop_source.?;
        const foreign = try NativeFixture.init(a, text);
        f.t.native_noop_source.?.output = foreign.t.ast;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        f.t.native_noop_source = original;
        f.t.native_noop_source.?.owner = foreign.sem.owner_token;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        f.t.native_noop_source = original;
        f.t.native_noop_source.?.ast = foreign.t.native_noop_source.?.ast;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        f.t.native_noop_source = original;
        const copies = &f.t.native_noop_copies;
        try std.testing.expect(copies.items.len > 0);
        const saved_copy = copies.items[0];
        copies.items[0].output = f.root;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        copies.items[0] = saved_copy;
        try copies.append(a, saved_copy);
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        _ = copies.pop();
        const member = for (copies.items) |copy| {
            const node = f.t.ast.getNode(copy.output);
            if (node.tag == .static_member_expression or node.tag == .computed_member_expression) break copy.output;
        } else return error.MissingNativeMember;
        const extra = f.t.ast.getNode(member).data.extra;
        const saved_flags = f.t.ast.extra_data.items[extra + 2];
        f.t.ast.extra_data.items[extra + 2] ^= ast_mod.MemberFlags.optional_chain;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        f.t.ast.extra_data.items[extra + 2] = saved_flags;
        const saved_member = f.t.ast.getNode(member);
        f.t.ast.nodes.items[@backingInt(member)].tag = if (saved_member.tag == .static_member_expression) .computed_member_expression else .static_member_expression;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        f.t.ast.nodes.items[@backingInt(member)] = saved_member;
        const row_index = for (f.sem.references, 0..) |ref, i| {
            if (!ref.flags.declare and !ref.node_index.isNone()) break i;
        } else return error.MissingNativeRead;
        const rows = @constCast(f.sem.references);
        const saved_row = rows[row_index];
        rows[row_index].scope_id = .none;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        rows[row_index] = saved_row;
        if (f.sem.scopes.len > 1) {
            rows[row_index].scope_id = @fromBackingInt(if (@backingInt(saved_row.scope_id) == 0) @as(u32, 1) else @as(u32, 0));
            try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
            rows[row_index] = saved_row;
        }
        rows[row_index].flags.write = !rows[row_index].flags.write;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        rows[row_index] = saved_row;
        rows[row_index].stmt_idx += 1;
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        rows[row_index] = saved_row;
        for (before, f.sem.references) |x, y| try std.testing.expect(std.meta.eql(x, y));
        try std.testing.expect(try Native.complete(&f.t, &f.sem, f.root));
    }
}

test "native no-op graph native source boundaries exclude dynamic and actual lowering" {
    const excluded = [_][]const u8{
        "const box={value:3};console.log(eval('box')?.value??7);",
        "class C{static value;static{this.value=7}}console.log(C?.value??0);",
        "let x=null;x??=7;console.log(x?.value??7);",
        "const f=()=>3;console.log(f?.()??7);",
        "import './dependency.mjs';const box=null;console.log(box?.value??7);",
    };
    for (excluded) |text| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.MissingNativeSource, NativeFixture.init(arena.allocator(), text));
    }
}

test "native no-op graph native assignment access modes follow actual parent operations" {
    const operations = [_][]const u8{ "counter=4", "counter+=2", "counter++", "++counter", "counter--", "--counter" };
    for (operations, 0..) |operation, operation_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.fmt.allocPrint(a, "let counter=3;const box={{value:1}};function run(){{{s};return box?.value??7}}console.log(run(),counter);", .{operation});
        var fixture = try NativeFixture.init(a, source);
        try std.testing.expect(fixture.t.native_noop_before_binder);
        try std.testing.expect(try Native.complete(&fixture.t, &fixture.sem, fixture.root));
        var writes: usize = 0;
        for (fixture.sem.references) |ref| if (ref.flags.write and !ref.flags.declare) {
            writes += 1;
            try std.testing.expectEqual(operation_index != 0, ref.flags.read);
        };
        try std.testing.expectEqual(@as(usize, 1), writes);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", source);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", entry } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            profile.resetForTest();
            defer profile.resetForTest();
            profile.setIoForTest(std.testing.io);
            profile.addFromCsv("graph.resync.semantic");
            var b = bundler.Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .unsupported = @import("compat.zig").fromESTarget(.es2020), .minify_identifiers = minify });
            defer b.deinit();
            const result = try b.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
            try helpers.writeFile(tmp.dir, "output.cjs", result.output);
            const output = try helpers.absPath(&tmp, "output.cjs");
            defer std.testing.allocator.free(output);
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output } });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

test "native no-op graph native hardening keeps module domains metadata and copy indices exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try NativeFixture.init(a, inputs[2]);
    const foreign = try NativeFixture.init(a, inputs[2]);
    try std.testing.expect(try Native.complete(&f.t, &f.sem, f.root));
    const rows = try a.dupe(symbol.Reference, f.sem.references);
    const copies = try a.dupe(Native.Copy, f.t.native_noop_copies.items);
    const original_domain = f.t.semantic_source_ast;
    f.t.semantic_source_ast = foreign.t.semantic_source_ast;
    try std.testing.expect(!try Native.beforeBinder(&f.t, f.root));
    try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
    f.t.semantic_source_ast = original_domain;
    inline for (.{ "is_typescript", "has_jsx", "has_jsx_key_after_spread", "has_decorator", "has_flow_enum_declaration" }) |field| {
        const source_ast = @constCast(f.t.native_noop_source.?.ast);
        const prior_source = @field(source_ast, field);
        @field(source_ast, field) = !prior_source;
        try std.testing.expect(!try Native.beforeBinder(&f.t, f.root));
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        @field(source_ast, field) = prior_source;
        const prior_output = @field(f.t.ast, field);
        @field(f.t.ast, field) = !prior_output;
        try std.testing.expect(!try Native.beforeBinder(&f.t, f.root));
        try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
        @field(f.t.ast, field) = prior_output;
    }
    const frame = f.t.native_noop_source.?.module_frame.?;
    const original_module = @constCast(frame.pointer);
    f.t.native_noop_source.?.module_frame.?.pointer = foreign.t.native_noop_source.?.module_frame.?.pointer;
    try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
    f.t.native_noop_source.?.module_frame = frame;
    const original_records = original_module.import_records;
    const record = try a.alloc(@import("../bundler/types.zig").ImportRecord, 1);
    record[0] = .{ .source_node = .none, .specifier = "./foreign.cjs", .kind = .require, .span = .{ .start = 0, .end = 0 } };
    original_module.import_records = record;
    try std.testing.expect((try Native.forModule(a, original_module, f.t.options)) == null);
    try std.testing.expect(!try Native.beforeBinder(&f.t, f.root));
    try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
    original_module.import_records = original_records;
    const original_bindings = original_module.import_bindings;
    // Only the forbidden nonempty count is observed; no fabricated binding is read.
    original_module.import_bindings = try a.alloc(@typeInfo(@TypeOf(original_bindings)).pointer.child, 1);
    try std.testing.expect((try Native.forModule(a, original_module, f.t.options)) == null);
    try std.testing.expect(!try Native.beforeBinder(&f.t, f.root));
    try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
    original_module.import_bindings = original_bindings;
    const key = @backingInt(f.t.native_noop_copies.items[0].source);
    const index = f.t.native_noop_copy_index.get(key).?;
    try std.testing.expect(f.t.native_noop_copy_index.remove(key));
    try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
    try f.t.native_noop_copy_index.put(a, key, (index + 1) % f.t.native_noop_copies.items.len);
    try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
    try f.t.native_noop_copy_index.put(a, key, index);
    try f.t.native_noop_copies.append(a, f.t.native_noop_copies.items[0]);
    try std.testing.expect(!try Native.complete(&f.t, &f.sem, f.root));
    _ = f.t.native_noop_copies.pop();
    for (rows, f.sem.references) |x, y| try std.testing.expect(std.meta.eql(x, y));
    for (copies, f.t.native_noop_copies.items) |x, y| try std.testing.expect(std.meta.eql(x, y));
    try std.testing.expect(try Native.beforeBinder(&f.t, f.root));
    try std.testing.expect(try Native.complete(&f.t, &f.sem, f.root));
}

test "native no-op graph native failed source allocation supplies no admission alternative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixture = try NativeFixture.init(a, inputs[0]);
    const m = fixture.t.native_noop_source.?.module_frame.?.pointer;
    const prepared = (try Native.forModule(std.testing.allocator, m, fixture.t.options)) orelse return error.MissingNativeSource;
    defer prepared.deinit(std.testing.allocator);
    try std.testing.expect(Native.preparedMatches(&prepared, m));
    const prepass = @import("../bundler/graph/transform_prepass.zig");
    try std.testing.expect(prepass.nativeNoopPreparedAdmissionForTest(m, fixture.t.options, &prepared));
    try std.testing.expect(!prepass.nativeNoopPreparedAdmissionForTest(m, fixture.t.options, null));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const unavailable: ?Native.Source = Native.forModule(failing.allocator(), m, fixture.t.options) catch |err| blk: {
        try std.testing.expectEqual(error.OutOfMemory, err);
        break :blk null;
    };
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(unavailable == null);
    try std.testing.expect(!prepass.nativeNoopPreparedAdmissionForTest(m, fixture.t.options, if (unavailable) |*source| source else null));
}

test "native no-op graph native required installation and late snapshot identity never fail open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try NativeFixture.init(a, inputs[2]);
    const original = fixture.t.native_noop_source.?;
    const rows = try a.dupe(symbol.Reference, fixture.sem.references);
    try std.testing.expect(Native.requirementSatisfied(&fixture.t, &original));
    fixture.t.native_noop_source = null;
    try std.testing.expect(!Native.requirementSatisfied(&fixture.t, &original));
    try std.testing.expect(!try Native.complete(&fixture.t, &fixture.sem, fixture.root));
    fixture.t.native_noop_source = original;
    inline for (.{ "nodes", "references", "symbols", "scopes", "owners", "node_mask", "reference_indices", "owner_scopes" }) |field| {
        const prior = @field(original, field);
        @field(fixture.t.native_noop_source.?, field) = try a.dupe(@typeInfo(@TypeOf(prior)).pointer.child, prior);
        // Same values/domain/root, but not the one owned capture admission chose.
        try std.testing.expect(!Native.requirementSatisfied(&fixture.t, &original));
        @field(fixture.t.native_noop_source.?, field) = prior;
    }
    for (rows, fixture.sem.references) |x, y| try std.testing.expect(std.meta.eql(x, y));
    try std.testing.expect(Native.requirementSatisfied(&fixture.t, &original));
    try std.testing.expect(try Native.complete(&fixture.t, &fixture.sem, fixture.root));
}
