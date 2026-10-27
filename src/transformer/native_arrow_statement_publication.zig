//! Ephemeral native-arrow parameter placement, from exact creator handles.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const symbol = @import("../semantic/symbol.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const coordinates = @import("../semantic/statement_coordinates.zig");
const params = @import("es2015_params.zig");
const Publication = @import("transformer.zig").StatementPublication;
pub const Error = std.mem.Allocator.Error || error{InvalidNativeArrowStatementPublication};
pub const Handle = struct {
    node: ast.NodeIndex,
    id: symbol.SymbolId,
    scope: ScopeId,
    flags: symbol.ReferenceFlags,
    prior: coordinates.Context,
    local: u32 = symbol.Reference.NO_STMT,
    local_owner: ast.NodeIndex = .none,
    assembly_top: u32 = symbol.Reference.NO_STMT,
    published: ?coordinates.Context = null,
};
pub const Plan = struct {
    formals: params.NativeArrowFormalPlan,
    handles: []Handle,
    prefix_rows: []const symbol.Reference,
    actual_params: ast.NodeIndex = .none,
    body: ast.NodeIndex = .none,
    assembly_root: ast.NodeIndex = .none,
};
pub const Batch = struct { plans: std.ArrayList(Plan) = .empty };
pub const Borrow = struct {
    slot: *?*Batch,
    previous: ?*Batch,
    pub fn restore(self: Borrow) void {
        self.slot.* = self.previous;
    }
};
pub fn borrow(slot: *?*Batch, batch: *Batch) Borrow {
    const lease: Borrow = .{ .slot = slot, .previous = slot.* };
    slot.* = batch;
    return lease;
}
fn localOwner(self: anytype, root: ast.NodeIndex, node: ast.NodeIndex) Error!ast.NodeIndex {
    const Frame = struct { node: ast.NodeIndex, owner: ast.NodeIndex };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var found: ?ast.NodeIndex = null;
    defer seen.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .owner = .none });
    while (stack.pop()) |frame| {
        if (frame.node.isNone()) continue;
        if (@backingInt(frame.node) >= self.ast.nodes.items.len) return invalid();
        const key = @as(u64, @backingInt(frame.node)) | (@as(u64, @backingInt(frame.owner)) << 32);
        const slot = try seen.getOrPut(self.allocator, key);
        if (slot.found_existing) continue;
        if (frame.node == node) {
            if (found) |owner| if (owner != frame.owner) {
                return invalid();
            };
            found = frame.owner;
        }
        const current = self.ast.getNode(frame.node);
        const owner = if (current.tag == .program or current.tag == .block_statement) frame.node else frame.owner;
        var children = walk.children(self.ast, current);
        while (children.next()) |child| try stack.append(self.allocator, .{ .node = child, .owner = owner });
    }
    return found orelse invalid();
}

fn invalid() Error {
    return error.InvalidNativeArrowStatementPublication;
}
fn anchor(row: symbol.Reference) ast.NodeIndex {
    return if (row.flags.declare) row.declaration_node_index else row.node_index;
}
fn context(row: symbol.Reference) coordinates.Context {
    return .{ .stmt_idx = row.stmt_idx, .scope_stmt_idx = row.scope_stmt_idx };
}
fn find(self: anytype, handle: Handle) Error!usize {
    const editor = if (self.semantic_editor) |*value| value else return invalid();
    if (editor.ast != self.ast) return invalid();
    if (handle.node.isNone() or @backingInt(handle.node) >= self.ast.nodes.items.len or self.getSymbolIdAt(handle.node) != @as(?u32, @backingInt(handle.id))) return invalid();
    var found: ?usize = null;
    for (editor.references.items, 0..) |row, index| {
        if (anchor(row) != handle.node) continue;
        if (found != null or row.symbol_id != handle.id or row.scope_id != handle.scope or !std.meta.eql(row.flags, handle.flags) or
            (row.flags.declare and !row.node_index.isNone())) return invalid();
        found = index;
    }
    return found orelse invalid();
}

/// Before any lowering edits, retain source-prefix rows for assembly contrasts.
pub fn capturePrefix(self: anytype, plan: params.NativeArrowFormalPlan) Error![]const symbol.Reference {
    var nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer nodes.deinit(self.allocator);
    for (plan.prefix.nodes) |prefix| {
        const reachable = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, prefix);
        defer self.allocator.free(reachable);
        for (reachable) |raw| try nodes.put(self.allocator, raw, {});
    }
    var rows: std.ArrayList(symbol.Reference) = .empty;
    errdefer rows.deinit(self.allocator);
    const references = if (self.semantic_editor) |*editor| editor.references.items else self.references;
    for (references) |row| if (!anchor(row).isNone() and nodes.contains(@backingInt(anchor(row)))) {
        try rows.append(self.allocator, row);
    };
    return rows.toOwnedSlice(self.allocator);
}

/// Called immediately on creator return, before driver scope relocation.
pub fn capture(self: anytype, formals: params.NativeArrowFormalPlan, list: ast.NodeList, prefix_rows: []const symbol.Reference) Error!Plan {
    var handles: std.ArrayList(Handle) = .empty;
    errdefer handles.deinit(self.allocator);
    for (formals.prefix.nodes.len..list.len) |offset| {
        const formal = self.ast.readExtraNode(list.start, @intCast(offset));
        const binding = @import("native_constructor_timing.zig").simpleFormalBinding(self, formal) orelse return invalid();
        const sid = self.getSymbolIdAt(binding) orelse return invalid();
        const editor = &self.semantic_editor.?;
        if (sid >= editor.symbols.items.len or editor.symbols.items[sid].scope_id != formals.prefix.parameter_scope.?) return invalid();
        var declarations: usize = 0;
        var reads: usize = 0;
        for (editor.references.items) |row| {
            if (@backingInt(row.symbol_id) != sid) continue;
            if (row.flags.declare) {
                if (row.declaration_node_index != binding or !row.node_index.isNone() or row.scope_id != formals.prefix.parameter_scope.? or
                    !std.meta.eql(row.flags, symbol.ReferenceFlags{ .declare = true })) return invalid();
                declarations += 1;
            } else {
                if (!row.flags.read or row.flags.write or row.scope_id != formals.owner.body_scope) return invalid();
                reads += 1;
            }
            try handles.append(self.allocator, .{ .node = anchor(row), .id = row.symbol_id, .scope = row.scope_id, .flags = row.flags, .prior = context(row) });
        }
        if (declarations != 1 or reads == 0) return invalid();
    }
    return .{ .formals = formals, .handles = try handles.toOwnedSlice(self.allocator), .prefix_rows = prefix_rows };
}

fn validateEdges(self: anytype, plan: Plan) Error!void {
    if (!try params.ES2015Params(@TypeOf(self.*)).validNativeArrowFormals(self, plan.formals, plan.actual_params)) return invalid();
    const arrow = self.ast.getNode(plan.formals.owner.function_node);
    if (plan.body.isNone() or self.ast.readExtraNode(arrow.data.extra, ast.ArrowExtra.body) != plan.body or self.outputOwnedScope(plan.formals.owner.function_node) != plan.formals.owner.body_scope) return invalid();
    if (self.outputOwnedScope(plan.body)) |known_body_scope| {
        if (known_body_scope != plan.formals.owner.body_scope) return invalid();
    }
    const body_nodes = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, plan.body);
    defer self.allocator.free(body_nodes);
    var raw_bindings: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer raw_bindings.deinit(self.allocator);
    const actual = self.ast.getNode(plan.actual_params).data.list;
    for (plan.formals.prefix.nodes.len..actual.len) |offset| {
        const formal = self.ast.readExtraNode(actual.start, @intCast(offset));
        const binding = @import("native_constructor_timing.zig").simpleFormalBinding(self, formal) orelse return invalid();
        try raw_bindings.put(self.allocator, @backingInt(binding), self.getSymbolIdAt(binding) orelse return invalid());
    }
    var raw_ids = raw_bindings.valueIterator();
    while (raw_ids.next()) |id| {
        var declarations: usize = 0;
        var reads: usize = 0;
        for (self.semantic_editor.?.references.items) |row| {
            if (@backingInt(row.symbol_id) != id.*) continue;
            var matches: usize = 0;
            for (plan.handles) |handle| if (handle.id == row.symbol_id and handle.node == anchor(row) and std.meta.eql(handle.flags, row.flags)) {
                matches += 1;
            };
            if (matches != 1) return invalid();
            if (row.flags.declare) declarations += 1 else reads += 1;
        }
        if (declarations != 1 or reads == 0) return invalid();
    }
    for (plan.handles) |handle| {
        if (handle.flags.declare) {
            if (raw_bindings.get(@backingInt(handle.node)) != @as(?u32, @backingInt(handle.id))) return invalid();
        } else {
            if (std.mem.indexOfScalar(u32, body_nodes, @backingInt(handle.node)) == null) return invalid();
            var owns_storage = false;
            var ids = raw_bindings.valueIterator();
            while (ids.next()) |id| if (id.* == @backingInt(handle.id)) {
                owns_storage = true;
            };
            if (!owns_storage) return invalid();
        }
    }
}

/// Actual body edge is now installed; source prefix rows stay untouched.
pub fn assemble(self: anytype, plan: *Plan, actual_params: ast.NodeIndex, body: ast.NodeIndex, root: ast.NodeIndex) Error!void {
    var checked = plan.*;
    checked.actual_params = actual_params;
    checked.body = body;
    try validateEdges(self, checked);
    const contexts = coordinates.collect(self.allocator, self.ast, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(),
    };
    defer self.allocator.free(contexts);
    for (plan.prefix_rows) |original| {
        var count: usize = 0;
        for (self.semantic_editor.?.references.items) |row| if (anchor(row) == anchor(original)) {
            if (!std.meta.eql(row, original)) return invalid();
            count += 1;
        };
        if (count != 1) return invalid();
    }
    for (plan.handles) |handle| {
        const index = try find(self, handle);
        if (!std.meta.eql(context(self.semantic_editor.?.references.items[index]), handle.prior)) return invalid();
        if (@backingInt(handle.node) >= contexts.len or contexts[@backingInt(handle.node)] == null) return invalid();
    }
    const owners = try self.allocator.alloc(ast.NodeIndex, plan.handles.len);
    defer self.allocator.free(owners);
    for (plan.handles, 0..) |handle, index| owners[index] = try localOwner(self, root, handle.node);
    plan.actual_params = actual_params;
    plan.body = body;
    plan.assembly_root = root;
    for (plan.handles, 0..) |*handle, index| {
        handle.local = contexts[@backingInt(handle.node)].?.scope_stmt_idx;
        handle.assembly_top = contexts[@backingInt(handle.node)].?.stmt_idx;
        handle.local_owner = owners[index];
    }
}

/// All program list mutations are complete. Validate the whole batch before
/// writing a single row, including any other producer's positions-only edits.
pub fn publish(self: anytype, batch: *Batch, root: ast.NodeIndex) Error!void {
    // No registered producer authority: do not inspect unrelated AST paths.
    if (batch.plans.items.len == 0) return;
    const contexts = coordinates.collect(self.allocator, self.ast, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(),
    };
    defer self.allocator.free(contexts);
    const Update = struct { index: usize, handle: *Handle, value: coordinates.Context };
    var updates: std.ArrayList(Update) = .empty;
    defer updates.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    for (batch.plans.items) |plan| {
        try validateEdges(self, plan);
        for (plan.handles) |*handle| {
            if (handle.local == symbol.Reference.NO_STMT or seen.contains(@backingInt(handle.node))) return invalid();
            try seen.put(self.allocator, @backingInt(handle.node), {});
            const index = try find(self, handle.*);
            if (@backingInt(handle.node) >= contexts.len) return invalid();
            const actual = contexts[@backingInt(handle.node)] orelse return invalid();
            if (actual.stmt_idx == symbol.Reference.NO_STMT or actual.scope_stmt_idx == symbol.Reference.NO_STMT) return invalid();
            // Body-local placement cannot move after assembly. Formal anchors
            // inherit program-local positions, which may shift with imports.
            const actual_local_owner = try localOwner(self, root, handle.node);
            if (handle.local_owner == plan.assembly_root) {
                if (actual_local_owner != root or @as(i64, actual.scope_stmt_idx) - @as(i64, handle.local) != @as(i64, actual.stmt_idx) - @as(i64, handle.assembly_top)) return invalid();
            } else if (actual_local_owner != handle.local_owner or actual.scope_stmt_idx != handle.local) return invalid();
            const prior = handle.published orelse handle.prior;
            const row = self.semantic_editor.?.references.items[index];
            const external_position = !std.meta.eql(context(row), prior);
            var registered_external = false;
            if (!handle.flags.declare) {
                const other = @import("native_constructor_timing.zig").publication(self, @backingInt(handle.node));
                const args = @import("native_arguments.zig").publication(self, @backingInt(handle.node)) catch return invalid();
                const both = @import("worklet_class_clone.zig").agreePublication(self, @backingInt(handle.node), other orelse args, handle.flags) catch return invalid();
                for ([_]?Publication{ other, args, both }) |maybe| if (maybe) |known| {
                    registered_external = true;
                    if (known.symbol_id != handle.id or known.scope != handle.scope or known.stmt != actual.stmt_idx or known.scope_stmt != actual.scope_stmt_idx) return invalid();
                };
            }
            if (external_position and (!registered_external or !std.meta.eql(context(row), actual))) return invalid();
            try updates.append(self.allocator, .{ .index = index, .handle = handle, .value = actual });
        }
    }
    for (updates.items) |update| {
        const row = &self.semantic_editor.?.references.items[update.index];
        row.stmt_idx = update.value.stmt_idx;
        row.scope_stmt_idx = update.value.scope_stmt_idx;
        update.handle.published = update.value;
    }
}

/// Read-only consumer gate. A splice after publication must be republished
/// by its actual producer; equality between stale rows and stale snapshots
/// is not proof of placement in the current root.
pub fn validateCommitted(self: anytype, batch: *Batch, root: ast.NodeIndex) Error!void {
    var tracked = false;
    for (batch.plans.items) |plan| if (plan.handles.len != 0) {
        tracked = true;
    };
    if (!tracked) return;
    const contexts = coordinates.collect(self.allocator, self.ast, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid(),
    };
    defer self.allocator.free(contexts);
    for (batch.plans.items) |plan| {
        try validateEdges(self, plan);
        for (plan.handles) |handle| {
            const known = handle.published orelse return invalid();
            const index = try find(self, handle);
            if (@backingInt(handle.node) >= contexts.len) return invalid();
            const actual = contexts[@backingInt(handle.node)] orelse return invalid();
            if (!std.meta.eql(actual, known) or !std.meta.eql(context(self.semantic_editor.?.references.items[index]), known)) return invalid();
            const actual_owner = try localOwner(self, root, handle.node);
            if (handle.local_owner == plan.assembly_root) {
                if (self.ast.getNode(root).tag != .program or self.ast.getNode(plan.assembly_root).tag != .program or actual_owner != root) return invalid();
            } else if (actual_owner != handle.local_owner) return invalid();
            if (!handle.flags.declare) {
                const ctor = @import("native_constructor_timing.zig").publication(self, @backingInt(handle.node));
                const args = @import("native_arguments.zig").publication(self, @backingInt(handle.node)) catch return invalid();
                for ([_]?Publication{ ctor, args }) |other| if (other) |value| {
                    if (value.symbol_id != handle.id or value.scope != handle.scope or value.stmt != known.stmt_idx or value.scope_stmt != known.scope_stmt_idx) return invalid();
                };
                const other = @import("worklet_class_clone.zig").agreePublication(self, @backingInt(handle.node), ctor orelse args, handle.flags) catch return invalid();
                _ = agree(self, @backingInt(handle.node), other, handle.flags) catch return invalid();
            }
        }
    }
}

/// Generic output binding consumes committed exact publications only.
pub fn agree(self: anytype, raw: u32, other: ?Publication, flags: symbol.ReferenceFlags) @import("../semantic/editor.zig").Error!?Publication {
    const batch = self.native_arrow_statement_batch orelse return other;
    var result = other;
    for (batch.plans.items) |plan| for (plan.handles) |handle| {
        if (@backingInt(handle.node) != raw or handle.flags.declare) continue;
        const published = handle.published orelse return error.InvalidNode;
        validateEdges(self, plan) catch return error.InvalidNode;
        if (!std.meta.eql(handle.flags, flags)) return error.InvalidNode;
        const index = find(self, handle) catch return error.InvalidNode;
        if (!std.meta.eql(context(self.semantic_editor.?.references.items[index]), published)) return error.InvalidNode;
        const known: Publication = .{ .symbol_id = handle.id, .scope = handle.scope, .stmt = published.stmt_idx, .scope_stmt = published.scope_stmt_idx };
        if (result) |existing| if (!std.meta.eql(existing, known)) {
            return error.InvalidNode;
        };
        result = known;
    };
    return result;
}

test "native arrow formal birth P5 owner query rejects only the requested node ambiguity" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "const read=(value)=>{return value};{{7;}{7;}}");
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    const program = parser.ast.getNode(root).data.list;
    const declaration = parser.ast.getNode(parser.ast.readExtraNode(program.start, 0));
    const declarator = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.readExtra(declaration.data.extra, 1), 0));
    const arrow = parser.ast.readExtraNode(declarator.data.extra, 2);
    const body = parser.ast.readExtraNode(parser.ast.getNode(arrow).data.extra, ast.ArrowExtra.body);
    const statement = parser.ast.readExtraNode(parser.ast.getNode(body).data.list.start, 0);
    const read = parser.ast.getNode(statement).data.unary.operand;
    try std.testing.expectEqual(ast.Node.Tag.identifier_reference, parser.ast.getNode(read).tag);
    const outside = parser.ast.getNode(parser.ast.readExtraNode(program.start, 1)).data.list;
    const first_block = parser.ast.readExtraNode(outside.start, 0);
    const second_block = parser.ast.readExtraNode(outside.start, 1);
    const first_expression = parser.ast.readExtraNode(parser.ast.getNode(first_block).data.list.start, 0);
    const second_expression = parser.ast.readExtraNode(parser.ast.getNode(second_block).data.list.start, 0);
    const literal = parser.ast.getNode(first_expression).data.unary.operand;
    parser.ast.nodes.items[@backingInt(second_expression)].data.unary.operand = literal;
    parser.ast.assertInvariants();
    var query = .{ .allocator = a, .ast = &parser.ast };
    try std.testing.expectEqual(body, try localOwner(&query, root, read));
    // The exact requested read may not itself have two statement-list owners.
    parser.ast.nodes.items[@backingInt(second_expression)].data.unary.operand = read;
    try std.testing.expectError(error.InvalidNativeArrowStatementPublication, localOwner(&query, root, read));
}

test "native arrow formal birth P5 empty batch does not inspect unrelated literal DAG" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("transformer.zig").Transformer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "let keep=1;keep;7;7;");
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".cjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var t = try Transformer.init(a, &parser.ast, .{});
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.semantic_edit_enabled = true;
    const program = t.ast.getNode(root).data.list;
    const first = t.ast.readExtraNode(program.start, 2);
    const second = t.ast.readExtraNode(program.start, 3);
    const literal = t.ast.getNode(first).data.unary.operand;
    t.ast.nodes.items[@backingInt(second)].data.unary.operand = literal;
    t.ast.assertInvariants();
    // The existing collector deliberately rejects a literal DAG spanning
    // different numeric contexts. This policy remains unchanged.
    try std.testing.expectError(error.AmbiguousStatementContext, coordinates.collect(a, t.ast, root));
    const rows = try a.dupe(symbol.Reference, t.references);
    try std.testing.expect(rows.len >= 2);
    const ids = try a.dupe(?u32, t.symbol_ids.items);
    const node_count = t.ast.nodes.items.len;
    const extra_count = t.ast.extra_data.items.len;
    try std.testing.expect(t.semantic_editor == null);
    var empty: Batch = .{};
    try publish(&t, &empty, root);
    try validateCommitted(&t, &empty, root);
    try std.testing.expectEqual(@as(usize, 0), empty.plans.items.len);
    try std.testing.expect(t.semantic_editor == null);
    try std.testing.expectEqual(node_count, t.ast.nodes.items.len);
    try std.testing.expectEqual(extra_count, t.ast.extra_data.items.len);
    try std.testing.expectEqual(rows.len, t.references.len);
    for (rows, t.references) |before, after| try std.testing.expect(std.meta.eql(before, after));
    try std.testing.expectEqualSlices(?u32, ids, t.symbol_ids.items);
    std.debug.print("native-arrow-P5 empty-batch no-walk=true literal-DAG-policy=unchanged rows={d} unchanged=true\n", .{rows.len});
}
