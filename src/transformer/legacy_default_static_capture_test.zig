const std = @import("std");
const ast = @import("../parser/ast.zig");

test "legacy default static capture actual creator handoff before reconciliation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "let sibling=class{};function id(v){return v}@id export default class{static value=7;static{console.log(this.name,this.value)}}";
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.configureFromExtension(".mts");
    const source_root = try parser.parse();
    const source_sibling_declaration = parser.ast.getNode(@fromBackingInt(parser.ast.extra_data.items[parser.ast.getNode(source_root).data.list.start]));
    const source_sibling_declarator = parser.ast.getNode(@fromBackingInt(parser.ast.extra_data.items[parser.ast.readExtra(source_sibling_declaration.data.extra, 1)]));
    const source_sibling_binding = parser.ast.readExtraNode(source_sibling_declarator.data.extra, 0);
    var initial = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    initial.is_ts = true;
    initial.is_module = true;
    initial.enable_stmt_info = true;
    initial.enable_exact_declaration_anchors = true;
    try initial.analyze();
    var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{
        .unsupported = @import("options.zig").TransformOptions.compat.fromESTarget(.es2021),
        .experimental_decorators = true,
        .use_define_for_class_fields = false,
    });
    try t.initSymbolIdsOwned(&parser.ast, initial.symbol_ids.items);
    t.symbols = initial.symbols.items;
    t.references = initial.references.items;
    t.scopes = initial.scopes.items;
    t.scope_maps = initial.scope_maps.items;
    t.scope_owner_map = initial.scope_owner_map;
    t.node_scope_provenance = initial.node_scope_provenance;
    t.class_self_symbol_map = initial.class_self_symbol_map;
    t.unresolved_references = &initial.unresolved_references;
    t.semantic_edit_enabled = true;
    const output = try t.transform();
    try std.testing.expectEqual(@as(u32, 0), t.static_class_captures.count());
    try std.testing.expectEqual(@as(u32, 1), t.completed_static_class_captures.count());
    var exports = t.lowered_anonymous_class_export_bindings.iterator();
    const exported = exports.next().?;
    const actual_binding: ast.NodeIndex = @fromBackingInt(exported.value_ptr.*);
    const actual_id = t.getSymbolIdAt(actual_binding).?;
    const source_self = t.class_self_symbol_map.get(exported.key_ptr.*).?;
    const capture = t.completed_static_class_captures.get(exported.value_ptr.*).?;
    try std.testing.expectEqual(actual_binding, capture.frame.class_binding);
    try std.testing.expectEqual(@as(?u32, actual_id), capture.frame.class_symbol_id);
    try std.testing.expectEqual(@as(?u32, source_self), capture.frame.class_self_symbol_id);
    try std.testing.expect(actual_id != source_self);
    var parents = try @import("output_scope_test_utils.zig").buildParentMap(a, t.ast, output);
    var snapshots: usize = 0;
    var pending_binding: ast.NodeIndex = .none;
    var sibling_binding: ast.NodeIndex = .none;
    var nodes = parents.keyIterator();
    while (nodes.next()) |raw| {
        const node = t.ast.nodes.items[raw.*];
        if (node.tag != .variable_declarator) continue;
        const binding = t.ast.readExtraNode(node.data.extra, 0);
        if (t.getSymbolIdAt(binding) == initial.symbol_ids.items[@backingInt(source_sibling_binding)]) sibling_binding = binding;
        if (binding == actual_binding) {
            const value = t.ast.readExtraNode(node.data.extra, 2);
            try std.testing.expectEqual(.class_expression, t.ast.getNode(value).tag);
            pending_binding = t.ast.readExtraNode(t.ast.getNode(value).data.extra, ast.ClassExtra.name);
            try std.testing.expectEqual(@as(?u32, source_self), t.getSymbolIdAt(pending_binding));
        }
        if (binding != capture.binding) continue;
        const value = t.ast.readExtraNode(node.data.extra, 2);
        try std.testing.expectEqual(@as(?u32, actual_id), t.getSymbolIdAt(value));
        const reference = (try t.semantic_editor.?.referenceForNode(value)).?;
        try std.testing.expectEqual(capture.frame.output_scope, reference.scope_id);
        try std.testing.expectEqual(actual_id, @backingInt(reference.symbol_id));
        try std.testing.expect(reference.flags.read and !reference.flags.write);
        snapshots += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), snapshots);
    try std.testing.expect(!pending_binding.isNone() and !sibling_binding.isNone());
    const source_class: ast.NodeIndex = @fromBackingInt(exported.key_ptr.*);
    const class_scope = t.outputOwnedScope(source_class).?;
    const refs_before = try a.dupe(@import("../semantic/symbol.zig").Reference, t.semantic_editor.?.references.items);
    const ids_before = try a.dupe(?u32, t.semantic_editor.?.symbol_ids.items);
    // Replay the exact producer's pre-handoff registry state, using real live
    // inner/outer bindings from this same generated class value.
    _ = t.completed_static_class_captures.remove(@backingInt(actual_binding));
    var pending = capture;
    pending.frame.class_binding = pending_binding;
    pending.frame.class_symbol_id = source_self;
    pending.frame.class_name = t.ast.getNode(pending_binding).data.string_ref;
    try t.static_class_captures.put(a, @backingInt(pending_binding), pending);
    const handoff = @import("static_class_capture.zig").handoffAnonymousExportValue;
    try std.testing.expectError(error.InvalidClassValueCaptureHandoff, handoff(&t, source_class, pending_binding, sibling_binding, capture.frame.output_scope));
    try std.testing.expectError(error.InvalidClassValueCaptureHandoff, handoff(&t, source_class, sibling_binding, actual_binding, capture.frame.output_scope));
    try std.testing.expectError(error.InvalidClassValueCaptureHandoff, handoff(&t, source_class, pending_binding, actual_binding, class_scope));
    const saved_mapping = t.lowered_anonymous_class_export_bindings.get(@backingInt(source_class)).?;
    try t.lowered_anonymous_class_export_bindings.put(a, @backingInt(source_class), @backingInt(sibling_binding));
    try std.testing.expectError(error.InvalidClassValueCaptureHandoff, handoff(&t, source_class, pending_binding, actual_binding, capture.frame.output_scope));
    try t.lowered_anonymous_class_export_bindings.put(a, @backingInt(source_class), saved_mapping);
    const actual_scope = t.semantic_editor.?.symbols.items[actual_id].scope_id;
    t.semantic_editor.?.symbols.items[actual_id].scope_id = class_scope;
    try std.testing.expectError(error.InvalidClassValueCaptureHandoff, handoff(&t, source_class, pending_binding, actual_binding, capture.frame.output_scope));
    t.semantic_editor.?.symbols.items[actual_id].scope_id = actual_scope;
    const original_self = t.class_self_symbol_map.get(@backingInt(source_class)).?;
    try t.class_self_symbol_map.put(a, @backingInt(source_class), t.getSymbolIdAt(sibling_binding).?);
    try std.testing.expectError(error.InvalidClassValueCaptureHandoff, handoff(&t, source_class, pending_binding, actual_binding, capture.frame.output_scope));
    try t.class_self_symbol_map.put(a, @backingInt(source_class), original_self);
    try std.testing.expectEqualDeep(pending, t.static_class_captures.get(@backingInt(pending_binding)).?);
    try std.testing.expectEqual(@as(u32, 1), t.static_class_captures.count());
    try std.testing.expectEqual(@as(u32, 0), t.completed_static_class_captures.count());
    try std.testing.expectEqualDeep(refs_before, t.semantic_editor.?.references.items);
    try std.testing.expectEqualSlices(?u32, ids_before, t.semantic_editor.?.symbol_ids.items);
    try std.testing.expect(try handoff(&t, source_class, pending_binding, actual_binding, capture.frame.output_scope));
    try std.testing.expect(!t.static_class_captures.contains(@backingInt(pending_binding)));
    try std.testing.expectEqualDeep(capture, t.static_class_captures.get(@backingInt(actual_binding)).?);
    try std.testing.expectEqualDeep(refs_before, t.semantic_editor.?.references.items);
    // Restore the completed registry without introducing a second declaration.
    _ = t.static_class_captures.remove(@backingInt(actual_binding));
    try t.completed_static_class_captures.put(a, @backingInt(actual_binding), capture);
    _ = (try t.finishSemanticEdit()).?;
}

const Case = struct { source: []const u8, native: []const u8, legacy: bool = true, define: bool = false };
const cases = [_]Case{
    .{ .source = "function dec(v){return v}@dec export default class{static value=7;static{console.log(this.name,this.value)}}", .native = "export default class{static value=7;static{console.log(this.name,this.value)}}" },
    .{ .source = "function dec(v){return v}@dec export default class{static value=this;static{console.log(this.value===this,this.name)}}", .native = "export default class{static value=this;static{console.log(this.value===this,this.name)}}" },
    .{ .source = "function dec(v){console.log('decorator',v.value);return class extends v{}}@dec export default class{static value=7;static{console.log('body',this.value)}}", .native = "const C=class{static value=7;static{console.log('body',this.value)}};console.log('decorator',C.value)" },
    .{ .source = "function dec(v){return v}@dec export default class{static{console.log(this.value)}static value=9;static{console.log(this.value)}}", .native = "export default class{static{console.log(this.value)}static value=9;static{console.log(this.value)}}" },
    .{ .source = "function dec(){}export default class{@dec read(){}static value=7;static{console.log(this.value,typeof this.prototype.read)}}", .native = "export default class{read(){}static value=7;static{console.log(this.value,typeof this.prototype.read)}}" },
    .{ .source = "function dec(v){return v}@dec export default class Named{static value=7;static{console.log(this.value,Named===this)}}", .native = "export default class Named{static value=7;static{console.log(this.value,Named===this)}}" },
    .{ .source = "const Box=class{static value=7;static{console.log(this.value)}};console.log(Box.value)", .native = "const Box=class{static value=7;static{console.log(this.value)}};console.log(Box.value)" },
    .{ .source = "function dec(v){return v}class Sibling{static value=3;static{console.log('sibling',this.value)}}@dec export default class{static value=7;static{console.log('default',this.value)}}", .native = "class Sibling{static value=3;static{console.log('sibling',this.value)}}export default class{static value=7;static{console.log('default',this.value)}}" },
    .{ .source = "function dec(v){return v}@dec export default class{static value=7;static{console.log(this.name,this.value)}}", .native = "export default class{static value=7;static{console.log(this.name,this.value)}}", .legacy = false },
    .{ .source = "function dec(v){return v}@dec export default class{static value=(console.log(this.name),7)}", .native = "export default class{static value=(console.log(this.name),7)}" },
    .{ .source = "function dec(v){return v}@dec export default class{static name(){return 3}static value=7;static{console.log(this.name(),this.value)}}", .native = "export default class{static name(){return 3}static value=7;static{console.log(this.name(),this.value)}}" },
    .{ .source = "export default class{static name=this.name;static{console.log(this.name)}}", .native = "export default class{static name=this.name;static{console.log(this.name)}}", .legacy = false, .define = true },
};

test "legacy default static capture native and lowered runtime controls" {
    for (cases, 0..) |case, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const expected = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", case.native } });
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        for ([_]@import("compat.zig").ESTarget{ .es2022, .es2021, .es5 }) |target| for ([_]bool{ false, true }) |minify| {
            std.debug.print("legacy capture case={d} target={s} min={any}\n", .{ index, @tagName(target), minify });
            const result = try @import("../transpile.zig").transpile(a, case.source, "input.mts", .{
                .unsupported = @import("options.zig").TransformOptions.compat.fromESTarget(target),
                .experimental_decorators = case.legacy,
                .use_define_for_class_fields = case.define,
                .keep_names = true,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", result.code } });
            if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("{s}\n{s}\n", .{ result.code, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        };
    }
}
