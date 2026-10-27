//! Actual source initializer scope before generic output binding.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const scope_utils = @import("output_scope_test_utils.zig");

test "legacy static field block initializer is born in its actual output scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "// @flow\n          const events = [];\n          function decorate(target: any, key?: string): void { events.push('decor:' + key); }\n          class Box {\n            static field: number = events.push('field');\n            static { events.push('block'); }\n            @decorate method(): void {}\n          }\n          console.log(Box.field, events.join(','));";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.is_flow = true;
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const source_root: ast.NodeIndex = @fromBackingInt(@as(u32, @intCast(parser.ast.nodes.items.len - 1)));
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_flow = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var source_read: ast.NodeIndex = .none;
    for (parser.ast.nodes.items) |node| {
        if (node.tag != .property_definition or parser.ast.readExtra(node.data.extra, ast.PropertyExtra.flags) & ast.PropertyFlags.is_static == 0) continue;
        const value = parser.ast.readExtraNode(node.data.extra, ast.PropertyExtra.init);
        if (value.isNone() or parser.ast.getNode(value).tag != .call_expression) continue;
        const callee = parser.ast.readExtraNode(parser.ast.getNode(value).data.extra, 0);
        try std.testing.expectEqual(ast.Node.Tag.static_member_expression, parser.ast.getNode(callee).tag);
        source_read = parser.ast.readExtraNode(parser.ast.getNode(callee).data.extra, 0);
    }
    try std.testing.expect(!source_read.isNone());
    const original_id = analyzer.symbol_ids.items[@backingInt(source_read)].?;
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{ .experimental_decorators = true });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.references = analyzer.references.items;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.helper_scope_map = analyzer.helper_scope_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    t.semantic_edit_enabled = true;
    var semantic = @import("../bundler/module.zig").ModuleSemanticData{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .node_scope_provenance = analyzer.node_scope_provenance,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .namespace_member_owners = analyzer.namespace_member_owners,
        .namespace_declaration_owners = analyzer.namespace_declaration_owners,
        .exported_names = analyzer.exported_names,
        .symbol_ids = analyzer.symbol_ids.items,
        .unresolved_references = analyzer.unresolved_references,
        .references = analyzer.references.items,
        .numeric_const_texts = analyzer.numeric_const_texts,
        .helper_scope_map = analyzer.helper_scope_map,
    };
    const owner = semantic.captureOwnerToken();
    const plan = (try @import("legacy_static_field_block_certificate.zig").sourcePlan(a, &parser.ast, &semantic, t.options)) orelse return error.MissingSourcePlan;
    try @import("class_initializer_publication.zig").activate(&t, plan, owner);
    try t.buildBlockRenameMap();
    const root = try t.visitNode(source_root);
    // No finishSemanticEdit/output binder may repair the initializer here.
    var parents = try scope_utils.buildParentMap(a, t.ast, root);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, t.ast, root);
    for (live) |raw| if (t.outputOwnedScope(@fromBackingInt(raw))) |scope| try owners.put(a, raw, @backingInt(scope));
    const editor = &t.semantic_editor.?;
    var checked: usize = 0;
    for (editor.references.items) |row| {
        if (!row.flags.read or row.flags.declare or row.node_index.isNone()) continue;
        const raw = @backingInt(row.node_index);
        if (!parents.contains(raw)) continue;
        var origin = raw;
        var hops: usize = 0;
        while (origin != @backingInt(source_read)) : (hops += 1) {
            if (hops >= t.ast.nodes.items.len) break;
            origin = t.reference_origin_map.get(origin) orelse break;
        }
        if (origin != @backingInt(source_read)) continue;
        try std.testing.expectEqual(original_id, @backingInt(row.symbol_id));
        const actual = scope_utils.expectedScope(t.ast, root, &parents, &owners, raw).?;
        if (actual != row.scope_id) std.debug.print("legacy static initializer birth sourceNode={d} outputNode={d} SID={d} rowScope={d} actualScope={d}\n", .{ @backingInt(source_read), raw, original_id, @backingInt(row.scope_id), @backingInt(actual) });
        try std.testing.expectEqual(actual, row.scope_id);
        const context = scope_utils.expectedStatementCoordinates(t.ast, &parents, raw).?;
        if (row.stmt_idx != context.stmt_idx or row.scope_stmt_idx != context.scope_stmt_idx) std.debug.print("legacy static initializer coordinates node={d} row={d}/{d} actual={d}/{d}\n", .{ raw, row.stmt_idx, row.scope_stmt_idx, context.stmt_idx, context.scope_stmt_idx });
        try std.testing.expectEqual(context.stmt_idx, row.stmt_idx);
        try std.testing.expectEqual(context.scope_stmt_idx, row.scope_stmt_idx);
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), checked);
    const publication = @import("class_initializer_publication.zig");
    try publication.validateCommitted(&t, root);
    try std.testing.expectEqual(@as(usize, 1), t.class_initializer_frames.items.len);
    const frame = t.class_initializer_frames.items[0];
    // Each descriptor belongs to the original AST and semantic owner domain.
    // Numerically valid sibling handles cannot substitute another role.
    for (0..7) |attack| {
        const saved = t.class_initializer_frames.items[0];
        switch (attack) {
            0 => t.class_initializer_frames.items[0].source.binding = source_read,
            1 => t.class_initializer_frames.items[0].source.key = saved.source.init,
            2 => t.class_initializer_frames.items[0].source.field_index += 1,
            3 => t.class_initializer_frames.items[0].source.owner = .unassigned,
            4 => t.class_initializer_frames.items[0].source.class_id = @fromBackingInt(original_id),
            5 => t.class_initializer_frames.items[0].source.outer_scope = saved.source.class_scope,
            6 => t.class_initializer_frames.items[0].source.read.flags.write = true,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidClassInitializerPublication, publication.validateCommitted(&t, root));
        try std.testing.expectError(error.InvalidClassInitializerPublication, publication.publishChecked(&t, root));
        t.class_initializer_frames.items[0] = saved;
        try publication.validateCommitted(&t, root);
    }

    var index: ?usize = null;
    for (editor.references.items, 0..) |row, i| {
        if (row.node_index == frame.reference) index = i;
    }
    const row_index = index.?;
    const original = editor.references.items[row_index];
    editor.references.items[row_index].scope_stmt_idx += 1;
    try std.testing.expectError(error.InvalidClassInitializerPublication, publication.validateCommitted(&t, root));
    try std.testing.expectError(error.InvalidClassInitializerPublication, publication.publishChecked(&t, root));
    try std.testing.expectEqual(original.scope_stmt_idx + 1, editor.references.items[row_index].scope_stmt_idx);
    try std.testing.expect(std.meta.eql(frame, t.class_initializer_frames.items[0]));
    editor.references.items[row_index] = original;
    editor.references.items[row_index].symbol_id = @fromBackingInt(original_id + 1);
    try std.testing.expectError(error.InvalidClassInitializerPublication, publication.validateCommitted(&t, root));
    editor.references.items[row_index] = original;
    const prior = t.class_initializer_frames.items[0].published;
    t.class_initializer_frames.items[0].published = null;
    try std.testing.expectError(error.InvalidClassInitializerPublication, publication.validateCommitted(&t, root));
    t.class_initializer_frames.items[0].published = prior;
    try publication.validateCommitted(&t, root);
    try publication.publishChecked(&t, root);
    try publication.validateCommitted(&t, root);
    // A real later program-prefix assembly invalidates the old publication.
    // Only the same creator's final publisher can rebase these known rows.
    const program = t.ast.getNode(root);
    const old_list = program.data.list;
    const prefix = try t.ast.addNode(.{ .tag = .empty_statement, .span = program.span, .data = .{ .none = 0 } });
    var statements: std.ArrayList(ast.NodeIndex) = .empty;
    try statements.append(a, prefix);
    for (t.ast.extra_data.items[old_list.start .. old_list.start + old_list.len]) |raw|
        try statements.append(a, @fromBackingInt(raw));
    t.ast.nodes.items[@backingInt(root)].data = .{ .list = try t.ast.addNodeList(statements.items) };
    try std.testing.expectError(error.InvalidClassInitializerPublication, publication.validateCommitted(&t, root));
    try publication.publishChecked(&t, root);
    try publication.validateCommitted(&t, root);
    try std.testing.expectEqual(original.stmt_idx + 1, editor.references.items[row_index].stmt_idx);
    try std.testing.expectEqual(original.scope_stmt_idx, editor.references.items[row_index].scope_stmt_idx);
    try std.testing.expectEqual(original.symbol_id, editor.references.items[row_index].symbol_id);
    try std.testing.expectEqual(original.scope_id, editor.references.items[row_index].scope_id);
}

test "legacy static field block initializer is born with real helper import assembly" {
    const helpers = @import("../bundler/test_helpers.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.js", "// @flow\nconst events=[];function decorate(target:any,key?:string):void{events.push('decor:'+key);}class Box{static field:number=events.push('field');static{events.push('block');}@decorate method():void{}}console.log(Box.field,events.join(','));");
    const entry = try helpers.absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(entry);
    for ([_]bool{ false, true }) |minify| {
        const profile = @import("../profile.zig");
        profile.resetForTest();
        defer profile.resetForTest();
        profile.setIoForTest(std.testing.io);
        profile.addFromCsv("graph.resync.semantic");
        var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .flow = true, .experimental_decorators = true, .minify_identifiers = minify });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        // This public esnext family previously needed one entry resync.
        // Runtime equality alone cannot establish retained identity.
        try std.testing.expectEqual(@as(u32, 0), profile.count(.graph_resync_semantic));
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        if (actual.term != .exited or actual.term.exited != 0) std.debug.print("{s}\n{s}\n", .{ actual.stderr, result.output });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("1 field,block,decor:method\n", actual.stdout);
    }
}

const CompletedCase = struct { members: []const u8, field: []const u8 = "field", calls: []const u8 = "decorate(Box.prototype,'method');", expected: []const u8 };
const completed_cases = [_]CompletedCase{
    .{ .members = "static field=events.push('field');static{events.push('block');}@decorate method(){}", .expected = "1 field,block,decor:method\n" },
    .{ .members = "static field=events.push(1);static{events.push('block');}@decorate method(){}", .expected = "1 1,block,decor:method\n" },
    .{ .members = "static field=events.push(true);static{events.push('block');}@decorate method(){}", .expected = "1 true,block,decor:method\n" },
    .{ .members = "static field=events.push(null);static{events.push('block');}@decorate method(){}", .expected = "1 ,block,decor:method\n" },
    .{ .members = "static field=events.push('a','b');static{events.push('block');}@decorate method(){}", .expected = "2 a,b,block,decor:method\n" },
    .{ .members = "static count=events.push('field');static{events.push('block');}@decorate method(){}", .field = "count", .expected = "1 field,block,decor:method\n" },
    .{ .members = "static field=events.push('field');static{events.push('block');}@decorate run(){}", .calls = "decorate(Box.prototype,'run');", .expected = "1 field,block,decor:run\n" },
    .{ .members = "static{events.push('before');}static field=events.push('field');static{events.push('block');}@decorate method(){}", .expected = "2 before,field,block,decor:method\n" },
    .{ .members = "static field=events.push('field');static{events.push('block');}@decorate method(){}@decorate extra(){}", .calls = "decorate(Box.prototype,'method');decorate(Box.prototype,'extra');", .expected = "1 field,block,decor:method,decor:extra\n" },
    .{ .members = "@decorate method(){}static field=events.push('field');static{events.push('block');}static{events.push('last');}", .expected = "1 field,block,last,decor:method\n" },
    .{ .members = "static field=events.push('field');static{events.push('block');}@decorate method(){}@decorate method(){}", .calls = "decorate(Box.prototype,'method');decorate(Box.prototype,'method');", .expected = "1 field,block,decor:method,decor:method\n" },
};

test "legacy static field block completed certificate retains eleven public inputs and native order" {
    const helpers = @import("../bundler/test_helpers.zig");
    const header = "const events=[];function decorate(target,key){events.push('decor:'+key);}class Box{";
    for (completed_cases, 0..) |case, case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const tail = try std.fmt.allocPrint(a, "console.log(Box.{s},events.join(','));", .{case.field});
        const source = try std.fmt.allocPrint(a, "// @flow\n{s}{s}}}{s}", .{ header, case.members, tail });
        const plain_members = try std.mem.replaceOwned(u8, a, case.members, "@decorate ", "");
        const native_source = try std.fmt.allocPrint(a, "{s}{s}}}{s}{s}", .{ header, plain_members, case.calls, tail });
        try helpers.writeFile(tmp.dir, "native.mjs", native_source);
        const native_path = try helpers.absPath(&tmp, "native.mjs");
        defer std.testing.allocator.free(native_path);
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", native_path } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        try helpers.writeFile(tmp.dir, "entry.js", source);
        const entry = try helpers.absPath(&tmp, "entry.js");
        defer std.testing.allocator.free(entry);
        for ([_]bool{ false, true }) |minify| {
            const profile = @import("../profile.zig");
            profile.resetForTest();
            defer profile.resetForTest();
            profile.setIoForTest(std.testing.io);
            profile.addFromCsv("graph.resync.semantic");
            var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .platform = .node, .format = .cjs, .flow = true, .experimental_decorators = true, .minify_identifiers = minify });
            defer bundler.deinit();
            const result = try bundler.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            if (profile.count(.graph_resync_semantic) != 0) std.debug.print("static certificate case={d} min={any} resync={d}\n", .{ case_index, minify, profile.count(.graph_resync_semantic) });
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
