const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Parser = @import("../../parser/parser.zig").Parser;
const Scanner = @import("../../lexer/scanner.zig").Scanner;
const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
const SemanticEditor = @import("../../semantic/editor.zig").SemanticEditor;
const Journal = @import("semantic_journal.zig").SemanticJournal;

const Fixture = struct {
    parser: Parser,
    analyzer: Analyzer,
    editor: SemanticEditor,
    root: ast_mod.NodeIndex,

    fn init(a: std.mem.Allocator, source: []const u8) !*Fixture {
        return initWithStatements(a, source, false);
    }

    fn initWithStatements(a: std.mem.Allocator, source: []const u8, statement_info: bool) !*Fixture {
        return initWithSourceOrigins(a, source, statement_info, false);
    }

    fn initWithSourceOrigins(a: std.mem.Allocator, source: []const u8, statement_info: bool, source_origins: bool) !*Fixture {
        const f = try a.create(Fixture);
        const scanner = try a.create(Scanner);
        scanner.* = try Scanner.init(a, source);
        f.parser = Parser.init(a, scanner);
        f.parser.configureFromExtension(".js");
        f.root = try f.parser.parse();
        f.analyzer = Analyzer.init(a, &f.parser.ast);
        f.analyzer.collect_unresolved_reference_nodes = true;
        f.analyzer.enable_source_external_origins = source_origins;
        f.analyzer.enable_stmt_info = statement_info;
        f.analyzer.enable_exact_declaration_anchors = true;
        try f.analyzer.analyze();
        f.editor = try f.analyzer.beginEdit();
        return f;
    }

    fn createJournal(f: *Fixture, a: std.mem.Allocator) !Journal {
        return Journal.init(a, f.analyzer.references.items, .{
            .domain = &f.parser.ast,
            .root = f.root,
            .symbol_ids = f.analyzer.symbol_ids.items,
            .owners = &f.analyzer.scope_owner_map,
            .expressions = &f.analyzer.node_scope_provenance,
            .class_self = &f.analyzer.class_self_symbol_map,
            .symbols = f.analyzer.symbols.items,
            .scopes = f.analyzer.scopes.items,
            .scope_maps = f.analyzer.scope_maps.items,
            .source_epoch = @intCast(f.analyzer.scope_history.events.len),
        });
    }

    fn declaredSid(f: *Fixture, statement: usize) u32 {
        const ast = &f.parser.ast;
        const body = ast.getNode(f.root).data.list;
        const declaration = ast.nodes.items[ast.extra_data.items[body.start + statement]];
        const first = ast.extra_data.items[ast.extra_data.items[declaration.data.extra + 1]];
        const binding = ast.extra_data.items[ast.nodes.items[first].data.extra];
        return f.analyzer.symbol_ids.items[binding].?;
    }

    fn reference(f: *Fixture, sid: u32) u32 {
        for (f.analyzer.references.items) |row| {
            if (!row.flags.declare and @backingInt(row.symbol_id) == sid) return @backingInt(row.node_index);
        }
        unreachable;
    }

    fn copy(f: *Fixture, journal: *Journal, source: u32, target: u32) void {
        journal.recordCopy(&f.parser.ast, source, target, f.editor.symbol_ids.items);
        f.parser.ast.nodes.items[target] = f.parser.ast.nodes.items[source];
        f.editor.symbol_ids.items[target] = f.editor.symbol_ids.items[source];
    }
};

test "minifier semantic journal preserves chained reference copies and retires dead children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, "const value=42;console.log((0,(0,value)));");
    const sid = f.declaredSid(0);
    const source = f.reference(sid);
    var journal = try f.createJournal(a);
    var first: ?u32 = null;
    var second: ?u32 = null;
    for (f.parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .sequence_expression) continue;
        const last = f.parser.ast.extra_data.items[node.data.list.start + node.data.list.len - 1];
        if (last == source) first = @intCast(raw) else second = @intCast(raw);
    }
    try std.testing.expect(first != null and second != null);
    const original = (try f.editor.referenceForNode(@fromBackingInt(source))).?;
    f.copy(&journal, source, first.?);
    f.copy(&journal, first.?, second.?);
    try journal.apply(&f.editor, f.root, null, null);
    try std.testing.expectEqual(@as(usize, 2), journal.events.items.len);
    try std.testing.expectEqual(@as(?@TypeOf(original), null), try f.editor.referenceForNode(@fromBackingInt(source)));
    try std.testing.expectEqual(@as(?@TypeOf(original), null), try f.editor.referenceForNode(@fromBackingInt(first.?)));
    const actual = (try f.editor.referenceForNode(@fromBackingInt(second.?))).?;
    try std.testing.expectEqual(original.symbol_id, actual.symbol_id);
    try std.testing.expectEqual(original.scope_id, actual.scope_id);
    try std.testing.expectEqual(@as(u32, 1), actual.stmt_idx);
    try std.testing.expectEqual(@as(u32, 1), actual.scope_stmt_idx);
    try std.testing.expectEqualDeep(original.flags, actual.flags);
    try std.testing.expectEqual(@as(u32, 1), f.editor.symbols.items[sid].reference_count);
}

test "minifier semantic journal replaces the target reference in its actual scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.initWithStatements(a, "const source=42;const target=7;console.log(source,target);", true);
    const source_sid = f.declaredSid(0);
    const target_sid = f.declaredSid(1);
    const source = f.reference(source_sid);
    const target = f.reference(target_sid);
    const previous = (try f.editor.referenceForNode(@fromBackingInt(target))).?;
    var journal = try f.createJournal(a);
    f.copy(&journal, source, target);
    try journal.apply(&f.editor, f.root, null, null);
    const actual = (try f.editor.referenceForNode(@fromBackingInt(target))).?;
    try std.testing.expectEqual(@as(u32, source_sid), @backingInt(actual.symbol_id));
    try std.testing.expectEqual(previous.scope_id, actual.scope_id);
    try std.testing.expectEqual(previous.stmt_idx, actual.stmt_idx);
    try std.testing.expectEqual(@as(u32, 2), f.editor.symbols.items[source_sid].reference_count);
    try std.testing.expectEqual(@as(u32, 0), f.editor.symbols.items[target_sid].reference_count);
}

test "minifier semantic journal preserves generator owner and rejects a foreign target owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, "console.log(true?function*(){yield 42}:function*(){yield 0});");
    var owners: [2]u32 = undefined;
    var count: usize = 0;
    var target: ?u32 = null;
    for (f.parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .function_expression) {
            owners[count] = @intCast(raw);
            count += 1;
        }
        if (node.tag == .conditional_expression) target = @intCast(raw);
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    const scope = f.editor.scope_owner_map.get(owners[0]).?;
    var negative = try f.createJournal(a);
    negative.recordCopy(&f.parser.ast, owners[0], owners[1], f.editor.symbol_ids.items);
    try std.testing.expectError(error.ScopeOwnerConflict, negative.apply(&f.editor, f.root, null, null));
    try std.testing.expectEqual(@as(?u32, scope), f.editor.scope_owner_map.get(owners[0]));
    var positive = try f.createJournal(a);
    f.copy(&positive, owners[0], target.?);
    try positive.apply(&f.editor, f.root, null, null);
    try std.testing.expectEqual(@as(?u32, scope), f.editor.scope_owner_map.get(target.?));
    try std.testing.expectEqual(@as(?u32, null), f.editor.scope_owner_map.get(owners[0]));
}

test "minifier semantic journal propagates recording OOM before publishing a graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, "const source=42;const target=7;console.log(source,target);");
    const sid = f.declaredSid(0);
    const target_sid = f.declaredSid(1);
    const source = f.reference(sid);
    const target = f.reference(target_sid);
    const before = (try f.editor.referenceForNode(@fromBackingInt(target))).?;
    var journal = try f.createJournal(std.testing.allocator);
    defer journal.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    journal.allocator = failing.allocator();
    journal.recordCopy(&f.parser.ast, source, target, f.editor.symbol_ids.items);
    journal.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, journal.apply(&f.editor, f.root, null, null));
    try std.testing.expectEqualDeep(before, (try f.editor.referenceForNode(@fromBackingInt(target))).?);
    try std.testing.expectEqual(@as(?u32, target_sid), f.editor.symbol_ids.items[target]);
}

test "minifier semantic journal elides actual arrow frames and preserves nested generator scope" {
    const minify = @import("../minify.zig");
    for ([_][]const u8{
        "const value=42;console.log((()=>value)());",
        "const value=42;console.log((()=>function*(){yield value})()().next().value);",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try Fixture.initWithStatements(a, source, true);
        const sid = f.declaredSid(0);
        const read = f.reference(sid);
        var arrow: ?u32 = null;
        var generator: ?u32 = null;
        for (f.parser.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .arrow_function_expression) arrow = @intCast(raw);
            if (node.tag == .function_expression) generator = @intCast(raw);
        }
        const arrow_scope = f.editor.scope_owner_map.get(arrow.?).?;
        const parent = f.editor.scopes.items[arrow_scope].parent;
        const original = (try f.editor.referenceForNode(@fromBackingInt(read))).?;
        var journal = try f.createJournal(a);
        minify.minify(&f.parser.ast, .{
            .symbols = f.analyzer.symbols.items,
            .symbol_ids = f.editor.symbol_ids.items,
            .symbol_ids_mut = f.editor.symbol_ids.items,
            .semantic_journal = &journal,
            .scopes = f.analyzer.scopes.items,
            .references = f.analyzer.references.items,
            .unresolved_globals = &f.analyzer.unresolved_references,
        }, a, f.root);
        var inline_count: usize = 0;
        for (journal.events.items) |event| if (event.inline_scope != null) {
            inline_count += 1;
        };
        try std.testing.expectEqual(@as(usize, 1), inline_count);
        try journal.apply(&f.editor, f.root, null, null);
        try std.testing.expectEqual(@as(?u32, null), f.editor.scope_owner_map.get(arrow.?));
        const actual = (try f.editor.referenceForNode(@fromBackingInt(read))).?;
        try std.testing.expectEqual(original.symbol_id, actual.symbol_id);
        if (generator) |owner| {
            const scope = f.editor.scope_owner_map.get(owner).?;
            try std.testing.expectEqual(parent, f.editor.scopes.items[scope].parent);
            try std.testing.expectEqual(original.scope_id, actual.scope_id);
        } else try std.testing.expectEqual(parent, actual.scope_id);
    }
}

test "minifier semantic journal preserves the actual class self carrier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, "const C=true?class Inner{read(){return Inner}}:class{};console.log(C);");
    var source: ?u32 = null;
    var target: ?u32 = null;
    for (f.parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression and !f.parser.ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.name).isNone()) source = @intCast(raw);
        if (node.tag == .conditional_expression) target = @intCast(raw);
    }
    const self_sid = f.analyzer.class_self_symbol_map.get(source.?).?;
    const source_owner = f.analyzer.scope_owner_map.get(source.?).?;
    var class_self = try f.analyzer.class_self_symbol_map.clone(a);
    var journal = try f.createJournal(a);
    f.copy(&journal, source.?, target.?);
    try journal.apply(&f.editor, f.root, null, &class_self);
    try std.testing.expectEqual(@as(?u32, self_sid), class_self.get(target.?));
    try std.testing.expectEqual(@as(?u32, null), class_self.get(source.?));
    try std.testing.expectEqual(@as(?u32, source_owner), f.editor.scope_owner_map.get(target.?));
    try std.testing.expectEqual(@as(?u32, null), f.editor.scope_owner_map.get(source.?));
}

test "minifier semantic journal preserves actual import expression source provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, "const promise=true?import('./external.mjs'):0;console.log(promise);");
    var source: ?u32 = null;
    var target: ?u32 = null;
    for (f.parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .import_expression) source = @intCast(raw);
        if (node.tag == .conditional_expression) target = @intCast(raw);
    }
    const original = f.analyzer.node_scope_provenance.get(@fromBackingInt(source.?)).?;
    var journal = try f.createJournal(a);
    f.copy(&journal, source.?, target.?);
    try journal.apply(&f.editor, f.root, null, null);
    try std.testing.expectEqual(@as(?@TypeOf(original), null), f.editor.node_scope_provenance.get(@fromBackingInt(source.?)));
    const actual = f.editor.node_scope_provenance.get(@fromBackingInt(target.?)).?;
    try @import("../../semantic/test_node_equality.zig").expectEqualDeep(original, actual);
    try std.testing.expectEqual(@as(ast_mod.NodeIndex, @fromBackingInt(source.?)), actual.source_node);
    _ = try f.editor.finish();
}

test "minifier semantic journal separates declaration retirement from reference phase" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, "const value=7;console.log(1);");
    const sid = f.declaredSid(0);
    var declaration: ?@import("../../semantic/symbol.zig").Reference = null;
    for (f.editor.references.items) |row| {
        if (row.flags.declare and @backingInt(row.symbol_id) == sid) declaration = row;
    }
    try std.testing.expect(declaration != null);
    var journal = try f.createJournal(a);
    const body = &f.parser.ast.nodes.items[@backingInt(f.root)].data.list;
    body.start += 1;
    body.len -= 1;
    const receipt = try journal.applyReferenceAndOwnerEdits(&f.editor, f.root, null, null);
    defer journal.freeApplicationReceipt(receipt);
    var present = false;
    for (f.editor.references.items) |row| if (std.meta.eql(row, declaration.?)) {
        present = true;
    };
    try std.testing.expect(present);
    try journal.retireDeadDeclarationAnchors(&f.editor, f.root);
    for (f.editor.references.items) |row| try std.testing.expect(!std.meta.eql(row, declaration.?));
}

test "minifier semantic journal rejects a physically foreign AST domain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try Fixture.init(a, "const value=7;console.log(value);");
    const foreign = try Fixture.init(a, "const value=7;console.log(value);");
    var journal = try first.createJournal(a);
    const before = foreign.editor.references.items.len;
    try std.testing.expectError(error.InvalidReferenceIdentity, journal.applyReferenceAndOwnerEdits(&foreign.editor, foreign.root, null, null));
    try std.testing.expectEqual(before, foreign.editor.references.items.len);
}

test "minifier semantic journal accounts only source backed historical delta edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.init(a, "const value=7;console.log(value);console.log(value);");
    const sid = f.declaredSid(0);
    // An earlier producer removed one actual statement, leaving its historical
    // reference row and aggregate decrement in the source graph.
    const body = &f.parser.ast.nodes.items[@backingInt(f.root)].data.list;
    body.len -= 1;
    const old_deltas = try a.alloc(u32, f.editor.symbols.items.len);
    @memset(old_deltas, 0);
    old_deltas[sid] = 1;
    try std.testing.expectEqual(@as(u32, 2), f.editor.symbols.items[sid].reference_count);
    var journal = try f.createJournal(a);
    try std.testing.expectEqual(@as(usize, 1), journal.baseline_edges.items.len);
    const receipt = try journal.applyReferenceAndOwnerEdits(&f.editor, f.root, null, null);
    defer journal.freeApplicationReceipt(receipt);
    try std.testing.expectEqual(@as(u32, 1), f.editor.symbols.items[sid].reference_count);
    try std.testing.expect(try journal.accountsForBaselineDeltas(receipt, old_deltas));
    var missing = receipt;
    missing.reference_changes = &.{};
    try std.testing.expect(!try journal.accountsForBaselineDeltas(missing, old_deltas));
    old_deltas[sid] = 2;
    try std.testing.expect(!try journal.accountsForBaselineDeltas(receipt, old_deltas));
    old_deltas[sid] = 0;
    try std.testing.expect(!try journal.accountsForBaselineDeltas(receipt, old_deltas));
}

const InlineReceipt = @import("../../semantic/function_retirement_receipt.zig").ApplicationReceipt;
const InlineRetirement = @import("../../semantic/source_owned_retirement.zig");

const ActualInlineFixture = struct {
    fixture: *Fixture,
    journal: Journal,
    receipt: InlineReceipt,

    fn init(a: std.mem.Allocator) !ActualInlineFixture {
        return initSource(a, "function run(value){let item=value;return item;}console.log(run(42));");
    }

    fn initSource(a: std.mem.Allocator, source: []const u8) !ActualInlineFixture {
        const f = try Fixture.initWithSourceOrigins(a, source, true, true);
        var journal = try f.createJournal(a);
        const deltas = try a.alloc(u32, f.analyzer.symbols.items.len);
        @memset(deltas, 0);
        @import("../minify.zig").minify(&f.parser.ast, .{
            .symbols = f.analyzer.symbols.items,
            .symbol_ids = f.editor.symbol_ids.items,
            .symbol_ids_mut = f.editor.symbol_ids.items,
            .semantic_journal = &journal,
            .scopes = f.analyzer.scopes.items,
            .references = f.analyzer.references.items,
            .unresolved_globals = &f.analyzer.unresolved_references,
            .ref_deltas = deltas,
            .allow_top_level_inline = true,
        }, a, f.root);
        try std.testing.expect(journal.failure == null);
        try std.testing.expectEqual(@as(usize, 1), journal.inlined_bindings.items.len);
        const receipt = try journal.applyReferenceAndOwnerEdits(&f.editor, f.root, null, null);
        return .{ .fixture = f, .journal = journal, .receipt = receipt };
    }
};

fn inlineStateValid(a: std.mem.Allocator, tree: *const ast_mod.Ast, root: ast_mod.NodeIndex, editor: *const SemanticEditor) !bool {
    const nodes = try @import("../../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, tree, root);
    defer a.free(nodes);
    var live = try std.DynamicBitSet.initEmpty(a, tree.nodes.items.len);
    defer live.deinit();
    for (nodes) |raw| live.set(raw);
    const history = editor.scopeHistoryView();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const index = try @import("../../semantic/scope_frame_history.zig").validateAndIndex(scratch.allocator(), tree, editor.scopes.items, &editor.scope_owner_map, &history, null);
    return index.valid and try InlineRetirement.validateWithIndex(a, tree, &editor.source_owned_retirements, &live, editor.symbols.items, editor.symbol_ids.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, &editor.helper_scope_map, .{ .scope_history = &history, .node_scope_provenance = &editor.node_scope_provenance }, &index);
}

test "minifier actual local inline retirement rejects ten paired producer receipts" {
    for (0..10) |poison| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const actual = try ActualInlineFixture.init(a);
        const f = actual.fixture;
        const original = actual.receipt.inlined_bindings[0];
        const before_ids = try a.dupe(?u32, f.editor.symbol_ids.items);
        const before_refs = try a.dupe(@import("../../semantic/symbol.zig").Reference, f.editor.references.items);
        const before_symbols = try a.dupe(@import("../../semantic/symbol.zig").Symbol, f.editor.symbols.items);
        const events = try a.dupe(@import("../../semantic/inlined_binding_retirement.zig").Event, actual.receipt.inlined_bindings);
        var foreign_ast = f.parser.ast;
        switch (poison) {
            0 => events[0].domain = &foreign_ast,
            1 => events[0].symbol_id = @fromBackingInt(@as(u32, @intCast(f.editor.symbols.items.len))),
            2 => events[0].declaration.flags.write = true,
            3 => events[0].witness.read_reference.node_index = original.witness.initializer,
            4 => events[0].initializer_node.tag = .empty_statement,
            5 => events[0].wrapped_initializer = !original.wrapped_initializer,
            6 => events[0].witness.source_epoch = std.math.maxInt(u32),
            7 => events[0].before.scope_id = .none,
            8 => events[0].statement_node.tag = .empty_statement,
            9 => events[0].witness.declarator = original.binding,
            else => unreachable,
        }
        var poisoned = actual.receipt;
        poisoned.inlined_bindings = events;
        if (f.editor.retireInlinedLocalBindings(events, f.root, poisoned)) |_| {
            std.debug.print("inline producer poison accepted={d}\n", .{poison});
            return error.TestExpectedError;
        } else |_| {}
        try std.testing.expectEqual(@as(u32, 0), f.editor.source_owned_retirements.count());
        try std.testing.expectEqualSlices(?u32, before_ids, f.editor.symbol_ids.items);
        try std.testing.expectEqualDeep(before_refs, f.editor.references.items);
        for (before_symbols, f.editor.symbols.items) |before, after| try std.testing.expect(InlineRetirement.equalSymbol(before, after));
        try actual.journal.retireInlinedBindings(&f.editor, f.root, actual.receipt);
        try std.testing.expectEqual(@as(u32, 1), f.editor.source_owned_retirements.count());
        try std.testing.expect(try inlineStateValid(a, &f.parser.ast, f.root, &f.editor));
    }
}

test "minifier actual local inline retirement survives fresh AST semantic codec and rejects persistent tuple poison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const actual = try ActualInlineFixture.init(a);
    const f = actual.fixture;
    try actual.journal.retireInlinedBindings(&f.editor, f.root, actual.receipt);
    try std.testing.expect(try inlineStateValid(a, &f.parser.ast, f.root, &f.editor));
    const sem = @import("../../bundler/module.zig").ModuleSemanticData{
        .symbols = f.editor.symbols,
        .scopes = f.editor.scopes.items,
        .scope_maps = f.editor.scope_maps.items,
        .scope_owner_map = f.editor.scope_owner_map,
        .class_self_symbol_map = f.analyzer.class_self_symbol_map,
        .exported_names = f.analyzer.exported_names,
        .symbol_ids = f.editor.symbol_ids.items,
        .unresolved_references = f.analyzer.unresolved_references,
        .references = f.editor.references.items,
        .helper_scope_map = f.editor.helper_scope_map,
        .node_scope_provenance = f.editor.node_scope_provenance,
        .source_owned_retirements = f.editor.source_owned_retirements,
        .scope_history = f.editor.scopeHistoryView(),
    };
    var bytes: std.ArrayList(u8) = .empty;
    try @import("../../bundler/semantic_codec.zig").serialize(&sem, &bytes, a);
    const restored = try @import("../../bundler/semantic_codec.zig").deserialize(bytes.items, a);
    var fresh = try ast_mod.Ast.cloneForTransformer(&f.parser.ast, a);
    try std.testing.expect(&fresh != &f.parser.ast);
    var editor = try restored.beginEdit(a, &fresh);
    try std.testing.expect(try inlineStateValid(a, &fresh, f.root, &editor));
    const sid = @backingInt(actual.receipt.inlined_bindings[0].symbol_id);
    const witness = editor.source_owned_retirements.getPtr(sid).?;
    const original = witness.*;
    witness.inlined_binding.?.read_reference.flags.write = true;
    try std.testing.expect(!try inlineStateValid(a, &fresh, f.root, &editor));
    witness.* = original;
    witness.inlined_binding.?.source_frame.parent = original.source_scope;
    try std.testing.expect(!try inlineStateValid(a, &fresh, f.root, &editor));
    witness.* = original;
    try std.testing.expect(try inlineStateValid(a, &fresh, f.root, &editor));
    for (0..3) |poison| {
        switch (poison) {
            0 => witness.inlined_binding.?.read_node.data.string_ref = .{ .start = 5, .end = 4 },
            1 => witness.inlined_binding.?.read_node.data.string_ref = .{ .start = 0, .end = @intCast(fresh.source.len + 1) },
            2 => witness.inlined_binding.?.read_node.data.string_ref = .{ .start = ast_mod.Ast.STRING_TABLE_BIT, .end = 0 },
            else => unreachable,
        }
        try std.testing.expect(!try inlineStateValid(a, &fresh, f.root, &editor));
        witness.* = original;
        try std.testing.expect(try inlineStateValid(a, &fresh, f.root, &editor));
    }
}

test "minifier actual local inline retirement preserves escaped declaration and read StringValues" {
    for ([_][]const u8{
        "function run(value){let \\u0069tem=value;return item;}console.log(run(42));",
        "function run(value){let item=value;return \\u0069tem;}console.log(run(42));",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const actual = try ActualInlineFixture.initSource(a, source);
        const f = actual.fixture;
        try actual.journal.retireInlinedBindings(&f.editor, f.root, actual.receipt);
        try std.testing.expectEqual(@as(u32, 1), f.editor.source_owned_retirements.count());
        try std.testing.expect(try inlineStateValid(a, &f.parser.ast, f.root, &f.editor));
    }
}

test "minifier actual local inline retirement heap OOM preserves source graph and retries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const actual = try ActualInlineFixture.init(a);
    const f = actual.fixture;
    var failures: usize = 0;
    var succeeded = false;
    for (0..512) |fail_index| {
        var editor = try SemanticEditor.init(std.testing.allocator, &f.parser.ast, f.editor.symbols.items, f.editor.scopes.items, f.editor.scope_maps.items, f.editor.scope_owner_map, f.editor.references.items, f.editor.symbol_ids.items, f.editor.helper_scope_map);
        defer editor.deinit();
        try editor.importScopeHistory(f.editor.scopeHistoryView());
        try editor.importNodeScopeProvenance(f.editor.node_scope_provenance);
        const refs_ptr = editor.references.items.ptr;
        const ids_ptr = editor.symbol_ids.items.ptr;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        editor.allocator = failing.allocator();
        const result = editor.retireInlinedLocalBindings(actual.receipt.inlined_bindings, f.root, actual.receipt);
        editor.allocator = std.testing.allocator;
        if (result) |count| {
            try std.testing.expectEqual(@as(usize, 1), count);
            try std.testing.expect(try inlineStateValid(a, &f.parser.ast, f.root, &editor));
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            try std.testing.expectEqual(@intFromPtr(refs_ptr), @intFromPtr(editor.references.items.ptr));
            try std.testing.expectEqual(@intFromPtr(ids_ptr), @intFromPtr(editor.symbol_ids.items.ptr));
            try std.testing.expectEqual(@as(u32, 0), editor.source_owned_retirements.count());
            try std.testing.expectEqualDeep(f.editor.references.items, editor.references.items);
            try std.testing.expectEqualSlices(?u32, f.editor.symbol_ids.items, editor.symbol_ids.items);
        }
    }
    try std.testing.expect(succeeded and failures > 0);
    std.debug.print("actual inline retirement heap OOM failures={d} success=1\n", .{failures});
}
