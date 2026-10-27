//! Birth-time authority for computed object own-data helper applications.
//! This ledger never repairs identities or copies late reference coordinates.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const module = @import("../bundler/module.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const NodeIndex = ast_mod.NodeIndex;
const Capture = @import("es_helpers.zig").TempIdentityCapture;
pub const Source = struct { source_ast: *const ast_mod.Ast, output_ast: *const ast_mod.Ast, owner: module.SemanticOwnerToken };
pub const Application = struct {
    source: Source,
    call: NodeIndex,
    callee: NodeIndex,
    args: [3]NodeIndex,
    helper: u32,
    scope: ScopeId,
    object: Capture,
    helper_position: ?@import("../semantic/statement_coordinates.zig").Context = null,
    object_position: ?@import("../semantic/statement_coordinates.zig").Context = null,
};

pub fn candidate(a: std.mem.Allocator, ast: *const ast_mod.Ast, root: NodeIndex) !bool {
    const nodes = try walk.collectReachableNodeIndicesFrom(a, ast, root);
    defer a.free(nodes);
    for (nodes) |raw| {
        const n = ast.nodes.items[raw];
        if (n.tag != .object_expression) continue;
        var members = ast.iterateExtraList(n.data.list);
        while (members.next()) |member_idx| {
            const member = ast.getNode(member_idx);
            const key = switch (member.tag) {
                .object_property => member.data.binary.left,
                .method_definition => ast.readExtraNode(member.data.extra, ast_mod.MethodExtra.key),
                else => continue,
            };
            if (key.isNone()) continue;
            if (ast.getNode(key).tag == .computed_property_key) return true;
            if (member.tag == .object_property and !member.data.binary.right.isNone()) continue;
            const name = try ast.directStaticKeyName(a, key);
            defer if (name) |text| a.free(text);
            if (name != null and std.mem.eql(u8, name.?, "__proto__")) return true;
        }
    }
    return false;
}

pub fn record(self: anytype, call: NodeIndex, callee: NodeIndex, args: [3]NodeIndex, capture: Capture) !void {
    if (self.computed_object_helper_source == null or !self.semantic_edit_enabled) return;
    const helper = self.runtime_helper_symbol_ids.get("__publicField") orelse
        std.debug.panic("computed own-data helper has no birth identity", .{});
    try self.computed_object_helper_applications.append(self.allocator, .{
        .source = self.computed_object_helper_source.?,
        .call = call,
        .callee = callee,
        .args = args,
        .helper = @backingInt(helper),
        .scope = self.current_scope,
        .object = capture,
    });
}

pub fn contains(self: anytype, node: NodeIndex) bool {
    for (self.computed_object_helper_applications.items) |application| {
        if (application.callee == node) return true;
    }
    return false;
}

/// Called only by the existing exact helper relocation producer, before it moves
/// the known reference. The old ledger scope must match the producer's old scope.
pub fn relocate(self: anytype, node: NodeIndex, helper: u32, old: ScopeId, target: ScopeId, apply: bool) bool {
    for (self.computed_object_helper_applications.items) |*application| {
        if (application.callee != node) continue;
        const source = self.computed_object_helper_source orelse return false;
        if (!std.meta.eql(application.source, source) or source.output_ast != self.ast or source.source_ast != self.semantic_source_ast) return false;
        if (application.helper != helper or application.scope != old or target.isNone()) return false;
        if (apply and application.scope != target) {
            application.scope = target;
            application.helper_position = null;
            application.object_position = null;
        }
    }
    return true;
}

const ReferenceIndex = std.AutoHashMapUnmanaged(u32, struct { index: usize, count: usize });
fn indexReferences(a: std.mem.Allocator, sem: *const module.ModuleSemanticData) !ReferenceIndex {
    var result: ReferenceIndex = .empty;
    errdefer result.deinit(a);
    for (sem.references, 0..) |row, i| {
        if (row.node_index.isNone()) continue;
        const entry = try result.getOrPut(a, @backingInt(row.node_index));
        if (entry.found_existing) entry.value_ptr.count += 1 else entry.value_ptr.* = .{ .index = i, .count = 1 };
    }
    return result;
}

fn readRow(sem: *const module.ModuleSemanticData, rows: *const ReferenceIndex, node: NodeIndex, sid: u32, scope: ScopeId, context: @import("../semantic/statement_coordinates.zig").Context, check_coordinates: bool) bool {
    if (@backingInt(node) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(node)] != sid) return false;
    const indexed = rows.get(@backingInt(node)) orelse return false;
    if (indexed.count != 1) return false;
    const row = sem.references[indexed.index];
    return @backingInt(row.symbol_id) == sid and row.scope_id == scope and
        std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true })) and
        (!check_coordinates or (row.stmt_idx == context.stmt_idx and row.scope_stmt_idx == context.scope_stmt_idx));
}

fn validate(self: anytype, sem: *const module.ModuleSemanticData, root: NodeIndex, check_coordinates: bool) !bool {
    const source = self.computed_object_helper_source orelse return false;
    if (source.owner == .unassigned or source.owner != sem.owner_token or source.source_ast != self.semantic_source_ast or
        source.output_ast != self.ast or self.computed_object_helper_applications.items.len == 0) return false;
    const helper = self.runtime_helper_symbol_ids.get("__publicField") orelse return false;
    const sid: u32 = @backingInt(helper);
    if (sid >= sem.symbols.items.len) return false;
    const symbol = sem.symbols.items[sid];
    if (symbol.kind != .import_binding or symbol.scope_id != self.programScope() or symbol.synthetic_name.len == 0 or
        (symbol.synthetic_kind != null and symbol.synthetic_kind != .runtime_helper_import and symbol.synthetic_kind != .runtime_helper_preamble)) return false;
    // Validate the ledger's call schema before any generic AST walk consumes
    // its argument-list offsets. Malformed records never authorize traversal.
    for (self.computed_object_helper_applications.items) |application| {
        if (application.call.isNone() or @backingInt(application.call) >= self.ast.nodes.items.len or
            application.callee.isNone() or @backingInt(application.callee) >= self.ast.nodes.items.len) return false;
        const call = self.ast.getNode(application.call);
        if (call.tag != .call_expression or call.data.extra > self.ast.extra_data.items.len or
            self.ast.extra_data.items.len - call.data.extra < 4) return false;
        const start = self.ast.readExtra(call.data.extra, 1);
        if (self.ast.readExtra(call.data.extra, 2) != 3 or self.ast.readExtra(call.data.extra, 3) != 0 or
            start > self.ast.extra_data.items.len or self.ast.extra_data.items.len - start < 3) return false;
    }
    const nodes = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
    defer self.allocator.free(nodes);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer parents.deinit(self.allocator);
    for (nodes) |raw| {
        try live.put(self.allocator, raw, {});
        var children = walk.children(self.ast, self.ast.nodes.items[raw]);
        while (children.next()) |child| {
            if (child.isNone()) continue;
            const entry = try parents.getOrPut(self.allocator, @backingInt(child));
            if (entry.found_existing and entry.value_ptr.* != raw) return false;
            entry.value_ptr.* = raw;
        }
    }
    const contexts = try @import("../semantic/statement_coordinates.zig").collect(self.allocator, self.ast, root);
    defer self.allocator.free(contexts);
    var reference_rows = try indexReferences(self.allocator, sem);
    defer reference_rows.deinit(self.allocator);
    var recorded: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer recorded.deinit(self.allocator);
    for (self.computed_object_helper_applications.items) |application| {
        if (!std.meta.eql(application.source, source)) return false;
        if (!live.contains(@backingInt(application.call))) continue;
        if (application.helper != sid or (try recorded.getOrPut(self.allocator, @backingInt(application.callee))).found_existing) return false;
        if (parents.get(@backingInt(application.callee)) != @backingInt(application.call)) return false;
        const call = self.ast.getNode(application.call);
        if (call.tag != .call_expression or call.data.extra > self.ast.extra_data.items.len or self.ast.extra_data.items.len - call.data.extra < 4) return false;
        if (self.ast.getNode(application.callee).tag != .identifier_reference or
            self.ast.readExtraNode(call.data.extra, 0) != application.callee or
            self.ast.readExtra(call.data.extra, 2) != 3 or self.ast.readExtra(call.data.extra, 3) != 0) return false;
        const args_start = self.ast.readExtra(call.data.extra, 1);
        if (args_start > self.ast.extra_data.items.len or self.ast.extra_data.items.len - args_start < 3) return false;
        for (application.args, 0..) |arg, i| {
            if (self.ast.extra_data.items[args_start + i] != @backingInt(arg) or !live.contains(@backingInt(arg))) return false;
        }
        var actual_scope: ?ScopeId = null;
        var cursor = @backingInt(application.callee);
        var skips_owner = false;
        var remaining = nodes.len + 1;
        while (remaining != 0) : (remaining -= 1) {
            if (!skips_owner) {
                if (sem.scope_owner_map.get(cursor)) |owner| {
                    actual_scope = @fromBackingInt(owner);
                    break;
                }
            }
            const parent = parents.get(cursor) orelse break;
            skips_owner = @import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, parent, cursor);
            cursor = parent;
        }
        if (actual_scope == null or actual_scope.? != application.scope or application.scope.toIndex() >= sem.scopes.len) return false;
        const helper_context = contexts[@backingInt(application.callee)] orelse return false;
        if (!readRow(sem, &reference_rows, application.callee, sid, application.scope, helper_context, check_coordinates)) return false;
        if (check_coordinates and (application.helper_position == null or !std.meta.eql(application.helper_position.?, helper_context))) return false;
        var object_sid: ?u32 = if (application.object.symbol_id) |id| @backingInt(id) else null;
        if (application.object.temp_producer_id) |producer| {
            const published = self.temp_symbols_by_producer_id.get(producer) orelse return false;
            if (object_sid != null and object_sid.? != published) return false;
            object_sid = published;
        }
        const object = object_sid orelse return false;
        if (object >= sem.symbols.items.len or sem.symbols.items[object].kind != .variable_var) return false;
        const object_context = contexts[@backingInt(application.args[0])] orelse return false;
        if (!readRow(sem, &reference_rows, application.args[0], object, application.scope, object_context, check_coordinates)) return false;
        if (check_coordinates and (application.object_position == null or !std.meta.eql(application.object_position.?, object_context))) return false;
    }
    if (recorded.count() == 0) return false;
    // Every live use of this helper must be one of these exact call callee edges.
    // A class-field application or any unrecorded demand blocks this waiver.
    for (nodes) |raw| {
        if (raw < sem.symbol_ids.len and sem.symbol_ids[raw] == sid and !recorded.contains(raw)) {
            // The helper's actual import-local declaration is not a read use.
            // Only its canonical binding role and unique exact declaration row
            // can exempt it; identifier spelling is never identity evidence.
            const parent = parents.get(raw) orelse return false;
            const binding = self.ast.nodes.items[parent];
            if (binding.tag != .import_specifier or @backingInt(binding.data.binary.right) != raw) return false;
            const declaration_parent = parents.get(parent) orelse return false;
            if (self.ast.nodes.items[declaration_parent].tag != .import_declaration) return false;
            var declarations: usize = 0;
            for (sem.references) |row| {
                if (row.declaration_node_index != @as(NodeIndex, @fromBackingInt(raw))) continue;
                declarations += 1;
                if (@backingInt(row.symbol_id) != sid or row.scope_id != self.programScope() or !row.node_index.isNone() or
                    !std.meta.eql(row.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .declare = true }))) return false;
            }
            if (declarations != 1) return false;
        }
    }
    return true;
}

pub fn complete(self: anytype, sem: *const module.ModuleSemanticData, root: NodeIndex) !bool {
    return validate(self, sem, root, true);
}

/// The prepass calls this after applyEdit and final AST assembly. Domain checks
/// consume the actual module's semantic owner, not a token copied into a view.
/// Every allocation and identity check precedes the coordinates-only writes.
pub fn publishPositions(self: anytype, sem: *module.ModuleSemanticData, root: NodeIndex) !bool {
    if (!try validate(self, sem, root, false)) return false;
    const contexts = try @import("../semantic/statement_coordinates.zig").collect(self.allocator, self.ast, root);
    defer self.allocator.free(contexts);
    const Update = struct { row: usize, context: @import("../semantic/statement_coordinates.zig").Context };
    var updates: std.ArrayList(Update) = .empty;
    defer updates.deinit(self.allocator);
    var reference_rows = try indexReferences(self.allocator, sem);
    defer reference_rows.deinit(self.allocator);
    for (self.computed_object_helper_applications.items) |application| {
        if (contexts[@backingInt(application.call)] == null) continue;
        for ([_]NodeIndex{ application.callee, application.args[0] }) |node| {
            const indexed = reference_rows.get(@backingInt(node)).?;
            try updates.append(self.allocator, .{ .row = indexed.index, .context = contexts[@backingInt(node)].? });
        }
    }
    for (updates.items) |update| {
        @constCast(sem.references)[update.row].stmt_idx = update.context.stmt_idx;
        @constCast(sem.references)[update.row].scope_stmt_idx = update.context.scope_stmt_idx;
    }
    for (self.computed_object_helper_applications.items) |*application| {
        if (contexts[@backingInt(application.call)] == null) continue;
        application.helper_position = contexts[@backingInt(application.callee)];
        application.object_position = contexts[@backingInt(application.args[0])];
    }
    return true;
}

const Fixture = struct {
    transformer: @import("transformer.zig").Transformer,
    semantic: module.ModuleSemanticData,
    root: NodeIndex,
    fn init(a: std.mem.Allocator, text: []const u8) !Fixture {
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, text);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        const ast = try a.create(ast_mod.Ast);
        ast.* = parser.ast;
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        var sem: module.ModuleSemanticData = .{ .symbols = analyzer.symbols, .scopes = analyzer.scopes.items, .scope_maps = analyzer.scope_maps.items, .scope_owner_map = analyzer.scope_owner_map, .node_scope_provenance = analyzer.node_scope_provenance, .symbol_ids = analyzer.symbol_ids.items, .exported_names = analyzer.exported_names, .unresolved_references = analyzer.unresolved_references, .references = analyzer.references.items, .class_self_symbol_map = analyzer.class_self_symbol_map, .helper_scope_map = analyzer.helper_scope_map };
        _ = sem.captureOwnerToken();
        var t = try @import("transformer.zig").Transformer.init(a, ast, .{ .unsupported = @import("compat.zig").fromESTarget(.es5) });
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
        t.record_explicit_global_references = true;
        t.computed_object_helper_source = .{ .source_ast = ast, .output_ast = t.ast, .owner = sem.owner_token };
        const result = try t.transform();
        sem.applyEdit((try t.finishSemanticEdit()).?);
        _ = try publishPositions(&t, &sem, result);
        return .{ .transformer = t, .semantic = sem, .root = result };
    }
};

const inputs = [_][]const u8{
    "var k='x';var o={[k]:1,y:2};",
    "var k='x',y=2;var o={[k]:1,y};",
    "var k='x';var o={[k]:function(){return 1},y:2};",
    "var k='x';var o={[k]:1,__proto__(){return 2}};",
    "var __proto__=2;var o={__proto__};",
    "var __proto__=2;var o={__pro\\u0074o__};",
    "function make(k){return {[k]:1,y:2}}",
    "var make=(k)=>({[k]:1,y:2});",
    "var k='x';var o={get y(){return 1},[k]:2,y:3};",
    "var k=Symbol('key');var o={[k]:1,'after':2};",
};

test "computed object helper authority completes ten exact application families" {
    const expected_applications = [_]usize{ 2, 2, 2, 2, 1, 1, 2, 2, 2, 2 };
    for (inputs, expected_applications) |text, expected_count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var fixture = try Fixture.init(arena.allocator(), text);
        try std.testing.expectEqual(expected_count, fixture.transformer.computed_object_helper_applications.items.len);
        const completed = try complete(&fixture.transformer, &fixture.semantic, fixture.root);
        if (!completed) {
            const expected = try @import("../semantic/statement_coordinates.zig").collect(arena.allocator(), fixture.transformer.ast, fixture.root);
            std.debug.print("authority input={s} applications={d} sourceMatch={any} outputMatch={any} ownerMatch={any}\n", .{ text, fixture.transformer.computed_object_helper_applications.items.len, fixture.transformer.computed_object_helper_source.?.source_ast == fixture.transformer.semantic_source_ast, fixture.transformer.computed_object_helper_source.?.output_ast == fixture.transformer.ast, fixture.transformer.computed_object_helper_source.?.owner == fixture.semantic.owner_token });
            for (fixture.transformer.computed_object_helper_applications.items) |app| {
                std.debug.print("app callee={d} object={d} helper={d} scope={d} capture={any} producer={any}\n", .{ @backingInt(app.callee), @backingInt(app.args[0]), app.helper, @backingInt(app.scope), app.object.symbol_id, app.object.temp_producer_id });
                for (fixture.semantic.references) |row| {
                    if (row.node_index != app.callee and row.node_index != app.args[0]) continue;
                    std.debug.print("row node={d} sid={d} scope={d} flags={any} stmt={d}/{d} actual={any}\n", .{ @backingInt(row.node_index), @backingInt(row.symbol_id), @backingInt(row.scope_id), row.flags, row.stmt_idx, row.scope_stmt_idx, expected[@backingInt(row.node_index)] });
                }
            }
        }
        try std.testing.expect(completed);
    }
}

test "computed object helper authority rejects foreign duplicate stale identities without repair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.init(arena.allocator(), "function sibling(){}var k='x';var o={[k]:1,y:2};");
    try std.testing.expect(try complete(&f.transformer, &f.semantic, f.root));
    const source = f.transformer.computed_object_helper_source.?;
    const application = f.transformer.computed_object_helper_applications.items[0];
    const Mutation = enum { owner, source_ast, output_ast, application_ast, application_owner, helper, scope, object_sid, producer, callee, key, duplicate, missing, flags, coordinates, call_flags, args_start, args_len, published };
    inline for (std.meta.tags(Mutation)) |mutation| {
        var foreign_ast = f.transformer.ast.*;
        var saved_row: ?@import("../semantic/symbol.zig").Reference = null;
        const extra = f.transformer.ast.getNode(application.call).data.extra;
        const saved_start = f.transformer.ast.extra_data.items[extra + 1];
        const saved_len = f.transformer.ast.extra_data.items[extra + 2];
        const saved_flags = f.transformer.ast.extra_data.items[extra + 3];
        var row_index: usize = 0;
        for (f.semantic.references, 0..) |row, i| {
            if (row.node_index == application.callee) {
                row_index = i;
                break;
            }
        }
        switch (mutation) {
            .owner => f.transformer.computed_object_helper_source.?.owner = .unassigned,
            .source_ast => f.transformer.computed_object_helper_source.?.source_ast = &foreign_ast,
            .output_ast => f.transformer.computed_object_helper_source.?.output_ast = &foreign_ast,
            .application_ast => f.transformer.computed_object_helper_applications.items[0].source.output_ast = &foreign_ast,
            .application_owner => f.transformer.computed_object_helper_applications.items[0].source.owner = .unassigned,
            .helper => f.transformer.computed_object_helper_applications.items[0].helper += 1,
            .scope => f.transformer.computed_object_helper_applications.items[0].scope = .none,
            .object_sid => f.transformer.computed_object_helper_applications.items[0].object.symbol_id = @fromBackingInt(application.helper),
            .producer => f.transformer.computed_object_helper_applications.items[0].object.temp_producer_id = std.math.maxInt(u64),
            .callee => f.transformer.computed_object_helper_applications.items[0].callee = application.args[0],
            .key => f.transformer.computed_object_helper_applications.items[0].args[1] = application.args[2],
            .duplicate => try f.transformer.computed_object_helper_applications.append(arena.allocator(), application),
            .missing => _ = f.transformer.computed_object_helper_applications.orderedRemove(0),
            .call_flags => f.transformer.ast.extra_data.items[extra + 3] = ast_mod.CallFlags.is_pure,
            .args_start => f.transformer.ast.extra_data.items[extra + 1] = std.math.maxInt(u32),
            .args_len => f.transformer.ast.extra_data.items[extra + 2] = 2,
            .published => f.transformer.computed_object_helper_applications.items[0].helper_position = null,
            .flags, .coordinates => {
                saved_row = f.semantic.references[row_index];
                if (mutation == .flags) @constCast(f.semantic.references)[row_index].flags.write = true else @constCast(f.semantic.references)[row_index].stmt_idx += 1;
            },
        }
        try std.testing.expect(!try complete(&f.transformer, &f.semantic, f.root));
        f.transformer.ast.extra_data.items[extra + 1] = saved_start;
        f.transformer.ast.extra_data.items[extra + 2] = saved_len;
        f.transformer.ast.extra_data.items[extra + 3] = saved_flags;
        f.transformer.computed_object_helper_source = source;
        if (mutation == .duplicate) _ = f.transformer.computed_object_helper_applications.pop();
        if (mutation == .missing) try f.transformer.computed_object_helper_applications.insert(arena.allocator(), 0, application);
        f.transformer.computed_object_helper_applications.items[0] = application;
        if (saved_row) |row| @constCast(f.semantic.references)[row_index] = row;
        try std.testing.expect(try complete(&f.transformer, &f.semantic, f.root));
    }
}

test "computed object helper authority refuses unrecorded class helper demand atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, "var k='x';var o={[k]:1,y:2};class Box{value=3}");
    try std.testing.expect(f.transformer.runtime_helpers.public_field);
    try std.testing.expect(f.transformer.computed_object_helper_applications.items.len != 0);
    const before = try a.dupe(@import("../semantic/symbol.zig").Reference, f.semantic.references);
    try std.testing.expect(!try publishPositions(&f.transformer, &f.semantic, f.root));
    try std.testing.expect(!try complete(&f.transformer, &f.semantic, f.root));
    try std.testing.expectEqualDeep(before, f.semantic.references);
    for (f.transformer.computed_object_helper_applications.items) |application| {
        try std.testing.expect(application.helper_position == null and application.object_position == null);
    }
}

test "computed object helper authority retains ten actual bundler applications without resync" {
    const helpers = @import("../bundler/test_helpers.zig");
    const profile = @import("../profile.zig");
    for (inputs, 0..) |text, index| {
        for ([_]bool{ false, true }) |minify| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try helpers.writeFile(tmp.dir, "entry.mjs", text);
            const entry = try helpers.absPath(&tmp, "entry.mjs");
            defer std.testing.allocator.free(entry);
            // Inspect immediately after Graph.build, before linker callsites can
            // capture any other owner token. Only the computed source producer
            // captures a token for these no-import/no-class fixtures; the full
            // resync semantic literal resets it to .unassigned. This is a bounded
            // ownership witness, not a general retained-mode equivalence.
            var cache = @import("../bundler/resolve_cache.zig").ResolveCache.init(std.testing.allocator, .{ .platform = .node });
            defer cache.deinit();
            var graph = @import("../bundler/graph.zig").ModuleGraph.init(std.testing.allocator, &cache);
            defer graph.deinit();
            graph.minify_identifiers = minify;
            graph.transform_options_base.unsupported = @import("compat.zig").fromESTarget(.es5);
            try graph.build(std.testing.io, &.{entry});
            const source_module = graph.findModuleByPath(entry) orelse return error.MissingSourceModule;
            try std.testing.expectEqualStrings(entry, source_module.path);
            try std.testing.expect(source_module.transform_cache != null);
            try std.testing.expect(source_module.transform_cache.?.runtime_helpers.public_field);
            try std.testing.expect(source_module.transform_cache.?.helper_ref_nodes.len != 0);
            try std.testing.expect(source_module.semantic != null and source_module.semantic.?.owner_token != .unassigned);
            profile.resetForTest();
            defer profile.resetForTest();
            profile.setIoForTest(std.testing.io);
            profile.addFromCsv("graph.resync.semantic");
            var bundler = @import("../bundler/bundler.zig").Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .platform = .node,
                .format = .cjs,
                .unsupported = @import("compat.zig").fromESTarget(.es5),
                .minify_identifiers = minify,
            });
            defer bundler.deinit();
            const result = try bundler.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            // Sealed a4/557 baseline independently observes source=1 plus
            // these pre-existing virtual-provider resyncs (public-field,
            // to-property-key, and case2 keep-names). Preserve that debt and
            // require exactly one fewer resync; never report aggregate zero.
            const provider_resyncs = [_]u32{ 2, 2, 3, 2, 1, 1, 2, 2, 2, 2 };
            const old_total = provider_resyncs[index] + 1;
            const actual = profile.count(.graph_resync_semantic);
            if (actual != provider_resyncs[index])
                std.debug.print("computed helper actual prepass index={d} minify={any} old_total={d} expected_provider={d} actual_total={d}\n", .{ index, minify, old_total, provider_resyncs[index], actual });
            try std.testing.expectEqual(provider_resyncs[index], actual);
            try std.testing.expectEqual(@as(u32, 1), old_total - actual);
        }
    }
}

test "computed object helper authority relocation validates the recorded old identity atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(a, "function sibling(){}var k='x';var o={[k]:1,y:2};");
    const application = f.transformer.computed_object_helper_applications.items[0];
    var sibling: ScopeId = .none;
    for (f.semantic.scopes, 0..) |scope, raw| {
        if (scope.kind == .function and raw != @backingInt(application.scope)) {
            sibling = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    try std.testing.expect(!sibling.isNone());
    const before = try a.dupe(Application, f.transformer.computed_object_helper_applications.items);
    const references = try a.dupe(@import("../semantic/symbol.zig").Reference, f.semantic.references);
    const variable = @backingInt(application.object.symbol_id.?);
    try std.testing.expect(!relocate(&f.transformer, application.callee, application.helper, sibling, application.scope, false));
    try std.testing.expect(!relocate(&f.transformer, application.callee, variable, application.scope, application.scope, false));
    try std.testing.expect(!relocate(&f.transformer, application.callee, application.helper, application.scope, .none, false));
    try std.testing.expectEqual(before.len, f.transformer.computed_object_helper_applications.items.len);
    for (before, f.transformer.computed_object_helper_applications.items) |expected, actual|
        try std.testing.expect(std.meta.eql(expected, actual));
    try std.testing.expectEqualDeep(references, f.semantic.references);
    try std.testing.expect(relocate(&f.transformer, application.callee, application.helper, application.scope, application.scope, false));
    try std.testing.expect(try complete(&f.transformer, &f.semantic, f.root));
}

test "computed object helper authority super wrapper explicitly hands off the callee scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f = try Fixture.init(arena.allocator(), "var keyCalls = 0;\nvar _obj = 1;\nvar _obj2 = 2;\nfunction getKey() { keyCalls++; return \"read\"; }\nvar base = { read() { return this.input; } };\nvar alternate = { read() { return this.input * 2; } };\nvar methods = { [getKey()]() { return super.read() + 1; } };\nObject.setPrototypeOf(methods, base);\nvar method = methods.read;\nvar first = method.call({ input: 41 });\nObject.setPrototypeOf(methods, alternate);\nvar second = method.call({ input: 20 });\nconsole.log(first, second, keyCalls, _obj, _obj2);\n");
    try std.testing.expectEqual(@as(usize, 1), f.transformer.computed_object_helper_applications.items.len);
    const application = f.transformer.computed_object_helper_applications.items[0];
    const program_scope = f.transformer.programScope();
    try std.testing.expect(application.scope != program_scope);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, f.semantic.scopes[application.scope.toIndex()].kind);
    try std.testing.expectEqual(program_scope, f.semantic.scopes[application.scope.toIndex()].parent);
    var function_owners: usize = 0;
    var owners = f.semantic.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(application.scope)) continue;
        if (f.transformer.ast.nodes.items[entry.key_ptr.*].tag == .function_expression) function_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), function_owners);
    const object_sid = @backingInt(application.object.symbol_id.?);
    // Storage stays in the source outer var environment; these two reads run
    // in the new wrapper. The handoff changes neither SID nor storage owner.
    try std.testing.expectEqual(program_scope, f.semantic.symbols.items[object_sid].scope_id);
    try std.testing.expectEqual(program_scope, f.semantic.symbols.items[application.helper].scope_id);
    for ([_]NodeIndex{ application.callee, application.args[0] }) |node| {
        var count: usize = 0;
        for (f.semantic.references) |row| {
            if (row.node_index != node) continue;
            count += 1;
            try std.testing.expectEqual(application.scope, row.scope_id);
            try std.testing.expect(row.flags.read and !row.flags.write and !row.flags.declare);
            try std.testing.expect(row.stmt_idx != @import("../semantic/symbol.zig").Reference.NO_STMT);
            try std.testing.expect(row.scope_stmt_idx != @import("../semantic/symbol.zig").Reference.NO_STMT);
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
    try std.testing.expect(try complete(&f.transformer, &f.semantic, f.root));
}
