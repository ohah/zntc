const std = @import("std");
const ast = @import("../parser/ast.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Reference = @import("../semantic/symbol.zig").Reference;
const Scope = @import("../semantic/scope.zig").Scope;
const Transformer = @import("transformer.zig").Transformer;
const native = @import("native_arguments.zig");
const Editor = @import("../semantic/editor.zig").SemanticEditor;

const Fixture = struct {
    t: Transformer,
    owner: ast.NodeIndex,
    params: ast.NodeIndex,
    replacement: ast.NodeIndex = .none,
    body: ScopeId,
    source: ScopeId,
    sibling: ast.NodeIndex,
    sibling_body: ScopeId,
    sibling_sid: u32,
    sid: u32,
    reference: ast.NodeIndex = .none,

    fn init(a: std.mem.Allocator, source: []const u8) !Fixture {
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        const parser = try a.create(@import("../parser/parser.zig").Parser);
        parser.* = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var sem = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        sem.enable_stmt_info = true;
        sem.enable_exact_declaration_anchors = true;
        try sem.analyze();
        try std.testing.expectEqual(@as(usize, 0), sem.errors.items.len);
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = @import("compat.zig").fromESTarget(.es5) });
        try t.initSymbolIds(sem.symbol_ids.items);
        t.symbols = sem.symbols.items;
        t.references = sem.references.items;
        t.scopes = sem.scopes.items;
        t.scope_maps = sem.scope_maps.items;
        t.scope_owner_map = sem.scope_owner_map;
        t.node_scope_provenance = sem.node_scope_provenance;
        t.semantic_edit_enabled = true;
        t.semantic_editor = try Editor.init(a, t.ast, t.symbols, t.scopes, t.scope_maps, t.scope_owner_map, t.references, t.symbol_ids.items, t.helper_scope_map);
        try t.semantic_editor.?.importNodeScopeProvenance(t.node_scope_provenance);
        var first: ?ast.NodeIndex = null;
        var second: ?ast.NodeIndex = null;
        for (t.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration) continue;
            if (first == null) first = @fromBackingInt(@as(u32, @intCast(raw))) else second = @fromBackingInt(@as(u32, @intCast(raw)));
        }
        const owner = first.?;
        const sibling = second.?;
        const params = t.ast.readExtraNode(t.ast.getNode(owner).data.extra, ast.FunctionExtra.params);
        const parameter_scope = t.outputOwnedScope(params).?;
        const sibling_params = t.ast.readExtraNode(t.ast.getNode(sibling).data.extra, ast.FunctionExtra.params);
        const sibling_source = t.outputOwnedScope(sibling_params).?;
        return .{ .t = t, .owner = owner, .params = params, .body = t.outputOwnedScope(owner).?, .source = parameter_scope, .sibling = sibling, .sibling_body = t.outputOwnedScope(sibling).?, .sid = @intCast(t.semantic_editor.?.scope_maps.items[parameter_scope.toIndex()].get("arguments").?), .sibling_sid = @intCast(t.semantic_editor.?.scope_maps.items[sibling_source.toIndex()].get("arguments").?) };
    }

    fn prepare(self: *Fixture) !void {
        try std.testing.expect(native.canHandoffParameterEngine(&self.t, self.params, self.body));
        self.reference = try self.t.makeNativeArgumentsRef(self.source, self.body, .EMPTY);
        try native.recordParameterHandoff(&self.t, self.reference, self.params, self.body);
        self.replacement = try self.t.ast.addFormalParameters(try self.t.ast.addNodeList(&.{}), .EMPTY);
        const extra = self.t.ast.getNode(self.owner).data.extra;
        self.t.ast.extra_data.items[extra + ast.FunctionExtra.params] = @backingInt(self.replacement);
    }

    fn complete(self: *Fixture) !bool {
        return native.completeParameterHandoff(&self.t, self.owner, self.params, self.replacement, self.body);
    }

    fn expectComplete(self: *Fixture) !void {
        const old_read = (try self.t.semantic_editor.?.referenceForNode(self.reference)).?;
        const old_origin = self.t.native_arguments_reference_origins.get(@backingInt(self.reference)).?;
        try std.testing.expect(try self.complete());
        const e = &self.t.semantic_editor.?;
        try std.testing.expectEqual(self.body, e.symbols.items[self.sid].scope_id);
        try std.testing.expectEqual(@as(?usize, self.sid), e.scope_maps.items[self.body.toIndex()].get("arguments"));
        try std.testing.expect(e.scope_maps.items[self.source.toIndex()].get("arguments") == null);
        try std.testing.expectEqualDeep(old_read, (try e.referenceForNode(self.reference)).?);
        var expected_origin = old_origin;
        expected_origin.owner_scope = self.body;
        try std.testing.expectEqualDeep(expected_origin, self.t.native_arguments_reference_origins.get(@backingInt(self.reference)).?);
        try std.testing.expectEqual(@as(?ScopeId, self.body), self.t.native_arguments_declaration_origins.get(self.sid));
        try std.testing.expectEqual(@as(?u32, self.sid), self.t.getSymbolIdAt(self.reference));
        try std.testing.expectEqual(@as(usize, 0), self.t.native_arguments_parameter_handoffs.count());
        var declarations: usize = 0;
        for (e.references.items) |row| {
            if (@backingInt(row.symbol_id) == self.sid and row.flags.declare) {
                try std.testing.expectEqual(self.body, row.scope_id);
                try std.testing.expect(row.node_index.isNone() and row.declaration_node_index.isNone());
                declarations += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
    }
};

fn expectMapEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    try std.testing.expectEqual(expected.count(), actual.count());
    var it = expected.iterator();
    while (it.next()) |entry| try std.testing.expectEqualDeep(entry.value_ptr.*, actual.get(entry.key_ptr.*).?);
}

// Structural snapshot, including maps and both coordinate fields. Rejection
// must leave the deliberately malformed input unchanged; restoration then
// proves the same positive handoff still works.
const Snapshot = struct {
    symbols: []Symbol,
    references: []Reference,
    scopes: []Scope,
    ids: []?u32,
    editor_ids: []?u32,
    nodes: []ast.Node,
    extra: []u32,
    maps: []std.StringHashMapUnmanaged(usize),
    owners: std.AutoHashMapUnmanaged(u32, u32),
    origins: std.AutoHashMapUnmanaged(u32, native.ReferenceOrigin),
    declarations: std.AutoHashMapUnmanaged(u32, ScopeId),
    plans: std.AutoHashMapUnmanaged(u32, native.ParameterHandoff),

    fn take(a: std.mem.Allocator, f: *Fixture) !Snapshot {
        const e = &f.t.semantic_editor.?;
        const maps = try a.alloc(std.StringHashMapUnmanaged(usize), e.scope_maps.items.len);
        for (maps, e.scope_maps.items) |*dest, map| dest.* = try map.clone(a);
        return .{ .symbols = try a.dupe(Symbol, e.symbols.items), .references = try a.dupe(Reference, e.references.items), .scopes = try a.dupe(Scope, e.scopes.items), .ids = try a.dupe(?u32, f.t.symbol_ids.items), .editor_ids = try a.dupe(?u32, e.symbol_ids.items), .nodes = try a.dupe(ast.Node, f.t.ast.nodes.items), .extra = try a.dupe(u32, f.t.ast.extra_data.items), .maps = maps, .owners = try e.scope_owner_map.clone(a), .origins = try f.t.native_arguments_reference_origins.clone(a), .declarations = try f.t.native_arguments_declaration_origins.clone(a), .plans = try f.t.native_arguments_parameter_handoffs.clone(a) };
    }

    fn expectUnchanged(self: Snapshot, f: *Fixture) !void {
        const e = &f.t.semantic_editor.?;
        try std.testing.expectEqualDeep(self.symbols, e.symbols.items);
        try std.testing.expectEqualDeep(self.references, e.references.items);
        try std.testing.expectEqualDeep(self.scopes, e.scopes.items);
        try std.testing.expectEqualDeep(self.ids, f.t.symbol_ids.items);
        try std.testing.expectEqualDeep(self.editor_ids, e.symbol_ids.items);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(self.nodes), std.mem.sliceAsBytes(f.t.ast.nodes.items));
        try std.testing.expectEqualDeep(self.extra, f.t.ast.extra_data.items);
        for (self.maps, e.scope_maps.items) |before, after| try expectMapEqual(before, after);
        try expectMapEqual(self.owners, e.scope_owner_map);
        try expectMapEqual(self.origins, f.t.native_arguments_reference_origins);
        try expectMapEqual(self.declarations, f.t.native_arguments_declaration_origins);
        try expectMapEqual(self.plans, f.t.native_arguments_parameter_handoffs);
    }

    fn restore(self: Snapshot, f: *Fixture) void {
        const e = &f.t.semantic_editor.?;
        @memcpy(e.symbols.items, self.symbols);
        @memcpy(e.references.items, self.references);
        @memcpy(e.scopes.items, self.scopes);
        @memcpy(f.t.symbol_ids.items, self.ids);
        @memcpy(e.symbol_ids.items, self.editor_ids);
        @memcpy(f.t.ast.nodes.items, self.nodes);
        @memcpy(f.t.ast.extra_data.items, self.extra);
        @memcpy(e.scope_maps.items, self.maps);
        e.scope_owner_map = self.owners;
        f.t.native_arguments_reference_origins = self.origins;
        f.t.native_arguments_declaration_origins = self.declarations;
        f.t.native_arguments_parameter_handoffs = self.plans;
    }
};

const input_source = "async function*f(value=7){yield value} async function*g(other=8){yield other}";
const Mutation = enum { owner_sibling, body_sibling, old_params_sibling, replacement_sibling, replacement_owned, replacement_not_formals, replacement_non_simple, plan_body, plan_source, declaration_origin, symbol_sid, symbol_role, symbol_scope, read_scope, read_flags, read_stmt, read_scope_stmt, read_sid, origin_sid, origin_owner, origin_scope, origin_stmt, origin_scope_stmt, missing_origin, orphan_origin, missing_declaration, duplicate_declaration, source_slot, target_slot, ref_count, write_count };

test "native parameter handoff rejects hostile exact tuples atomically and restores the positive" {
    inline for (std.meta.tags(Mutation)) |mutation| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a, input_source);
        try f.prepare();
        const valid = try Snapshot.take(a, &f);
        const e = &f.t.semantic_editor.?;
        var read: usize = 0;
        var declaration: usize = 0;
        for (e.references.items, 0..) |row, i| {
            if (@backingInt(row.symbol_id) != f.sid) continue;
            if (row.flags.declare) declaration = i else read = i;
        }
        var owner = f.owner;
        var params = f.params;
        var replacement = f.replacement;
        var body = f.body;
        var expected: anyerror = error.InvalidNode;
        switch (mutation) {
            .owner_sibling => {
                owner = f.sibling;
                expected = error.InvalidScope;
            },
            .body_sibling => {
                body = f.sibling_body;
                expected = error.InvalidScope;
            },
            .old_params_sibling => {
                f.t.native_arguments_parameter_handoffs.getPtr(f.sid).?.params = f.t.ast.readExtraNode(f.t.ast.getNode(f.sibling).data.extra, ast.FunctionExtra.params);
                params = f.t.native_arguments_parameter_handoffs.get(f.sid).?.params;
                expected = error.InvalidScope;
            },
            .replacement_sibling => {
                replacement = f.t.ast.readExtraNode(f.t.ast.getNode(f.sibling).data.extra, ast.FunctionExtra.params);
                expected = error.InvalidScope;
            },
            .replacement_owned => {
                try e.scope_owner_map.put(a, @backingInt(f.replacement), @backingInt(f.source));
                expected = error.InvalidScope;
            },
            .replacement_not_formals => f.t.ast.nodes.items[@backingInt(f.replacement)].tag = .empty_statement,
            .replacement_non_simple => f.t.ast.nodes.items[@backingInt(f.replacement)].data.list = f.t.ast.getNode(f.params).data.list,
            .plan_body => {
                f.t.native_arguments_parameter_handoffs.getPtr(f.sid).?.body_scope = f.sibling_body;
                expected = error.InvalidScope;
            },
            .plan_source => {
                f.t.native_arguments_parameter_handoffs.getPtr(f.sid).?.source_scope = f.sibling_body;
                expected = error.InvalidScope;
            },
            .declaration_origin => {
                f.t.native_arguments_declaration_origins.getPtr(f.sid).?.* = f.sibling_body;
                expected = error.InvalidScope;
            },
            .symbol_sid => {
                e.references.items[read].symbol_id = @fromBackingInt(f.sibling_sid);
            },
            .symbol_role => {
                e.symbols.items[f.sid].synthetic_kind = null;
                expected = error.InvalidSymbol;
            },
            .symbol_scope => {
                e.symbols.items[f.sid].scope_id = f.sibling_body;
                expected = error.InvalidScope;
            },
            .read_scope => {
                e.references.items[read].scope_id = f.sibling_body;
                expected = error.InvalidScope;
            },
            .read_flags => e.references.items[read].flags.write = true,
            .read_stmt => e.references.items[read].stmt_idx +%= 1,
            .read_scope_stmt => e.references.items[read].scope_stmt_idx +%= 1,
            .read_sid => {
                f.t.symbol_ids.items[@backingInt(f.reference)] = f.sibling_sid;
                expected = error.InvalidSymbol;
            },
            .origin_sid => {
                f.t.native_arguments_reference_origins.getPtr(@backingInt(f.reference)).?.symbol_id = @fromBackingInt(f.sibling_sid);
                expected = error.InvalidSymbol;
            },
            .origin_owner => {
                f.t.native_arguments_reference_origins.getPtr(@backingInt(f.reference)).?.owner_scope = f.sibling_body;
                expected = error.InvalidScope;
            },
            .origin_scope => {
                f.t.native_arguments_reference_origins.getPtr(@backingInt(f.reference)).?.scope = f.sibling_body;
                expected = error.InvalidScope;
            },
            .origin_stmt => f.t.native_arguments_reference_origins.getPtr(@backingInt(f.reference)).?.stmt +%= 1,
            .origin_scope_stmt => f.t.native_arguments_reference_origins.getPtr(@backingInt(f.reference)).?.scope_stmt +%= 1,
            .missing_origin => {
                _ = f.t.native_arguments_reference_origins.remove(@backingInt(f.reference));
            },
            .orphan_origin => {
                try f.t.native_arguments_reference_origins.put(a, @backingInt(f.replacement), f.t.native_arguments_reference_origins.get(@backingInt(f.reference)).?);
                expected = error.ReferenceNotFound;
            },
            .missing_declaration => e.references.items[declaration].flags.declare = false,
            .duplicate_declaration => {
                try e.references.append(a, e.references.items[declaration]);
            },
            .source_slot => {
                try e.scope_maps.items[f.source.toIndex()].put(a, "arguments", f.sibling_sid);
                expected = error.InvalidScope;
            },
            .target_slot => {
                try e.scope_maps.items[f.body.toIndex()].put(a, "arguments", f.sibling_sid);
                expected = error.InvalidScope;
            },
            .ref_count => e.symbols.items[f.sid].reference_count += 1,
            .write_count => {
                e.symbols.items[f.sid].write_count += 1;
                expected = error.InvalidSymbol;
            },
        }
        const malformed = try Snapshot.take(a, &f);
        try std.testing.expectError(expected, native.completeParameterHandoff(&f.t, owner, params, replacement, body));
        try malformed.expectUnchanged(&f);
        // The duplicate-row case changed the list length; restore exact source
        // length before copying the original rows back.
        e.references.items.len = valid.references.len;
        valid.restore(&f);
        try f.expectComplete();
    }
}

const EligibilityMutation = enum { observed_read, observed_write, body_binding, duplicate_engine, missing_declaration, duplicate_declaration, wrong_role, wrong_kind, wrong_scope, wrong_parent, kept_params, graphless, already_recorded };
test "native parameter handoff eligibility keeps observed shadowed and native boundaries unchanged" {
    inline for (std.meta.tags(EligibilityMutation)) |mutation| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var f = try Fixture.init(a, input_source);
        try std.testing.expect(native.canHandoffParameterEngine(&f.t, f.params, f.body));
        const valid = try Snapshot.take(a, &f);
        const e = &f.t.semantic_editor.?;
        const old_unsupported = f.t.options.unsupported;
        switch (mutation) {
            .observed_read => e.symbols.items[f.sid].reference_count += 1,
            .observed_write => e.symbols.items[f.sid].write_count += 1,
            .body_binding => try e.scope_maps.items[f.body.toIndex()].put(a, "arguments", f.sibling_sid),
            .duplicate_engine => {
                var symbol = e.symbols.items[f.sid];
                symbol.scope_id = f.body;
                try e.symbols.append(a, symbol);
            },
            .missing_declaration, .duplicate_declaration => {
                for (e.references.items, 0..) |row, i| {
                    if (@backingInt(row.symbol_id) != f.sid or !row.flags.declare) continue;
                    if (mutation == .missing_declaration) e.references.items[i].flags.write = true else try e.references.append(a, row);
                    break;
                }
            },
            .wrong_role => e.symbols.items[f.sid].synthetic_kind = null,
            .wrong_kind => e.symbols.items[f.sid].kind = .variable_var,
            .wrong_scope => e.symbols.items[f.sid].scope_id = f.sibling_body,
            .wrong_parent => e.scopes.items[f.body.toIndex()].parent = f.sibling_body,
            .kept_params => f.t.options.unsupported.default_params = false,
            .graphless => f.t.semantic_edit_enabled = false,
            .already_recorded => try f.t.native_arguments_declaration_origins.put(a, f.sid, f.source),
        }
        const malformed = try Snapshot.take(a, &f);
        try std.testing.expect(!native.canHandoffParameterEngine(&f.t, f.params, f.body));
        try malformed.expectUnchanged(&f);
        e.symbols.items.len = valid.symbols.len;
        e.references.items.len = valid.references.len;
        valid.restore(&f);
        f.t.options.unsupported = old_unsupported;
        f.t.semantic_edit_enabled = true;
        try f.prepare();
        try f.expectComplete();
    }
    const sources = [_][]const u8{
        "async function*f(value=7){yield arguments[0]} async function*g(other=8){yield other}",
        "async function*f(value=7){var arguments;yield value} async function*g(other=8){yield other}",
        "async function*f(value=7,...rest){yield value} async function*g(other=8){yield other}",
    };
    for (sources) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), input);
        const before = try Snapshot.take(arena.allocator(), &f);
        try std.testing.expect(!native.canHandoffParameterEngine(&f.t, f.params, f.body));
        try before.expectUnchanged(&f);
    }
}

test "native parameter handoff stays absent for actual dynamic and retained parameter callers" {
    const sources = [_][]const u8{
        "async function*f(value=7){eval('');yield value} async function*g(other=8){yield other}",
        "async function*f(value=7){yield value} async function*g(other=8){yield other}",
    };
    for (sources, 0..) |input, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), input);
        if (index == 1) f.t.options.unsupported = @import("compat.zig").fromESTarget(.es2017);
        _ = try f.t.transform();
        try std.testing.expectEqual(@as(usize, 0), f.t.native_arguments_parameter_handoffs.count());
        try std.testing.expectEqual(f.source, f.t.semantic_editor.?.symbols.items[f.sid].scope_id);
        try std.testing.expectEqual(@as(?usize, f.sid), f.t.semantic_editor.?.scope_maps.items[f.source.toIndex()].get("arguments"));
    }
}

test "native parameter handoff records and copies only the exact existing formal plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, input_source);
    try f.prepare();
    const before = try Snapshot.take(a, &f);
    try std.testing.expectError(error.InvalidSymbol, native.recordParameterHandoff(&f.t, f.reference, f.params, f.body));
    try before.expectUnchanged(&f);
    const sibling_params = f.t.ast.readExtraNode(f.t.ast.getNode(f.sibling).data.extra, ast.FunctionExtra.params);
    try std.testing.expectError(error.InvalidScope, native.recordParameterHandoff(&f.t, f.reference, sibling_params, f.body));
    try before.expectUnchanged(&f);
    try std.testing.expectError(error.InvalidScope, native.recordParameterHandoff(&f.t, f.reference, f.params, f.sibling_body));
    try before.expectUnchanged(&f);
    const copied = try f.t.ast.addFormalParameters(f.t.ast.getNode(f.params).data.list, .EMPTY);
    try f.t.semantic_editor.?.scope_owner_map.put(a, @backingInt(copied), @backingInt(f.source));
    const old_origin = f.t.native_arguments_reference_origins.get(@backingInt(f.reference)).?;
    const old_row = (try f.t.semantic_editor.?.referenceForNode(f.reference)).?;
    native.copyParameterHandoff(&f.t, f.params, copied, f.body);
    try std.testing.expectEqual(copied, f.t.native_arguments_parameter_handoffs.get(f.sid).?.params);
    try std.testing.expectEqualDeep(old_origin, f.t.native_arguments_reference_origins.get(@backingInt(f.reference)).?);
    try std.testing.expectEqualDeep(old_row, (try f.t.semantic_editor.?.referenceForNode(f.reference)).?);
    f.params = copied;
    try f.expectComplete();
}

test "native parameter handoff generated factory reads preserve exact published coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, "");
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    _ = try parser.parse();
    var sem = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    sem.enable_stmt_info = true;
    sem.enable_exact_declaration_anchors = true;
    try sem.analyze();
    const source_symbol_count = sem.symbols.items.len;
    const source_scope_count = sem.scopes.items.len;
    try std.testing.expectEqual(@as(usize, 0), source_symbol_count);
    var t = try Transformer.init(a, &parser.ast, .{});
    try t.initSymbolIds(sem.symbol_ids.items);
    t.symbols = sem.symbols.items;
    t.references = sem.references.items;
    t.scopes = sem.scopes.items;
    t.scope_maps = sem.scope_maps.items;
    t.scope_owner_map = sem.scope_owner_map;
    t.node_scope_provenance = sem.node_scope_provenance;
    t.semantic_edit_enabled = true;
    const empty = try t.ast.addNodeList(&.{});
    const params = try t.ast.addFormalParameters(empty, .EMPTY);
    const body = try t.ast.addListNode(.block_statement, .EMPTY, empty);
    const none = @backingInt(ast.NodeIndex.none);
    const extra = try t.ast.addExtras(&.{ none, @backingInt(params), @backingInt(body), 0, none });
    const function = try t.ast.addExtraNode(.function_expression, .EMPTY, extra);
    const scope = try t.addGeneratedFunctionScope(t.programScope(), function);
    try std.testing.expect(scope.toIndex() >= source_scope_count);
    try std.testing.expectEqual(@as(?ScopeId, scope), t.outputOwnedScope(function));
    const reference = try t.makeNativeArgumentsRef(scope, scope, .EMPTY);
    const id = t.getSymbolIdAt(reference).?;
    try std.testing.expect(id >= source_symbol_count);
    try std.testing.expectEqual(@as(?u32, id), t.semantic_editor.?.symbol_ids.items[@backingInt(reference)]);
    // New identity alone does not select the exact-reference consumer. The
    // actual producer API reserves both its SID and its known output Scope.
    try std.testing.expect(id >= t.symbols.len);
    try t.trackExactOutputReferenceInScope(reference, id, scope);
    try std.testing.expectEqual(@as(?u32, id), t.exact_output_ref_symbol_ids.get(@backingInt(reference)));
    try std.testing.expectEqual(@as(?u32, @backingInt(scope)), t.exact_output_ref_scope_ids.get(@backingInt(reference)));
    const head = try t.ast.addNode(.{ .tag = .empty_statement, .span = .EMPTY, .data = .{ .none = 0 } });
    const ret = try t.ast.addNode(.{ .tag = .return_statement, .span = .EMPTY, .data = .{ .unary = .{ .operand = reference, .flags = 0 } } });
    const body_list = try t.ast.addNodeList(&.{ head, ret });
    t.ast.nodes.items[@backingInt(body)].data.list = body_list;
    const statement = try t.ast.addNode(.{ .tag = .expression_statement, .span = .EMPTY, .data = .{ .unary = .{ .operand = function, .flags = 0 } } });
    const original = try t.ast.addListNode(.program, .EMPTY, try t.ast.addNodeList(&.{statement}));
    try native.publish(&t, original);
    try std.testing.expectEqual(@as(u32, 0), (try t.semantic_editor.?.referenceForNode(reference)).?.stmt_idx);
    const prefix_a = try t.ast.addNode(.{ .tag = .empty_statement, .span = .EMPTY, .data = .{ .none = 0 } });
    const prefix_b = try t.ast.addNode(.{ .tag = .empty_statement, .span = .EMPTY, .data = .{ .none = 0 } });
    const program = try t.ast.addListNode(.program, .EMPTY, try t.ast.addNodeList(&.{ prefix_a, prefix_b, statement }));
    // Independent owner oracle: actual program slot 2, actual body slot 1,
    // actual function/body/return edges. No projector/publication helper is
    // used to compute these expected coordinates.
    const program_list = t.ast.getNode(program).data.list;
    try std.testing.expectEqual(@backingInt(statement), t.ast.extra_data.items[program_list.start + 2]);
    try std.testing.expectEqual(function, t.ast.getNode(statement).data.unary.operand);
    try std.testing.expectEqual(body, t.ast.readExtraNode(t.ast.getNode(function).data.extra, ast.FunctionExtra.body));
    try std.testing.expectEqual(@backingInt(ret), t.ast.extra_data.items[body_list.start + 1]);
    try std.testing.expectEqual(reference, t.ast.getNode(ret).data.unary.operand);
    try native.publish(&t, program);
    const before = (try t.semantic_editor.?.referenceForNode(reference)).?;
    try std.testing.expectEqual(@as(u32, 2), before.stmt_idx);
    try std.testing.expectEqual(@as(u32, 1), before.scope_stmt_idx);
    try std.testing.expectEqual(scope, before.scope_id);
    try std.testing.expectEqual(@as(u32, id), @backingInt(before.symbol_id));
    try std.testing.expectEqualDeep(@as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true }), before.flags);
    const origin = t.native_arguments_reference_origins.get(@backingInt(reference)).?;
    try std.testing.expectEqual(@as(u32, 2), origin.stmt);
    try std.testing.expectEqual(@as(u32, 1), origin.scope_stmt);
    try @import("transformer/semantic_edit.zig").bindOutputScopesAndReferencesChecked(&t, program, t.programScope());
    const after = (try t.semantic_editor.?.referenceForNode(reference)).?;
    try std.testing.expectEqualDeep(before, after);
    try std.testing.expectEqualDeep(origin, t.native_arguments_reference_origins.get(@backingInt(reference)).?);
    try std.testing.expectEqual(@as(?u32, id), t.getSymbolIdAt(reference));
    try std.testing.expectEqual(scope, t.semantic_editor.?.symbols.items[id].scope_id);
}

test "native argument assignment producer rejects invalid access atomically" {
    const Flags = @import("../semantic/symbol.zig").ReferenceFlags;
    for ([_]Flags{ .{}, .{ .read = true }, .{ .write = true, .declare = true }, .{ .write = true, .type_context = true }, .{ .write = true, .value_as_type = true }, .{ .write = true, ._reserved = 1 } }) |flags| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), input_source);
        try f.prepare();
        const before = try Snapshot.take(arena.allocator(), &f);
        try std.testing.expectError(error.InvalidNode, native.recordAssignment(&f.t, f.reference, flags));
        try before.expectUnchanged(&f);
    }
    for ([_]Flags{ .{ .write = true }, .{ .read = true, .write = true } }) |flags| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var f = try Fixture.init(arena.allocator(), input_source);
        try f.prepare();
        const e = &f.t.semantic_editor.?;
        const row = (try e.referenceForNode(f.reference)).?;
        const origin = f.t.native_arguments_reference_origins.get(@backingInt(f.reference)).?;
        try native.recordAssignment(&f.t, f.reference, flags);
        var expected_row = row;
        expected_row.flags = flags;
        var expected_origin = origin;
        expected_origin.flags = flags;
        try std.testing.expectEqualDeep(expected_row, (try e.referenceForNode(f.reference)).?);
        try std.testing.expectEqualDeep(expected_origin, f.t.native_arguments_reference_origins.get(@backingInt(f.reference)).?);
        try std.testing.expectEqual(@as(u32, 1), e.symbols.items[f.sid].reference_count);
        try std.testing.expectEqual(@as(u32, 1), e.symbols.items[f.sid].write_count);
        try std.testing.expectEqual(f.source, e.symbols.items[f.sid].scope_id);
        try std.testing.expect((try native.publication(&f.t, @backingInt(f.reference))) != null);
    }
}
