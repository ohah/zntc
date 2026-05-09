//! Dead-store pruning helpers used by bundler emission.

const std = @import("std");
const Module = @import("../module.zig").Module;
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const purity = @import("../purity.zig");
const TokenKind = @import("../../lexer/token.zig").Kind;
const semantic_symbol = @import("../../semantic/symbol.zig");
const Reference = semantic_symbol.Reference;
const Symbol = semantic_symbol.Symbol;

const AssignmentInfo = struct {
    stmt_idx: u32,
    lhs_idx: u32,
    sym_idx: u32,
};

const RefKey = struct {
    symbol_id: u32,
    scope_id: u32,
};

const RefEvent = struct {
    ref_pos: u32,
    node_idx: u32,
    stmt_idx: u32,
    symbol_id: u32,
    scope_id: u32,
    flags: semantic_symbol.ReferenceFlags,

    fn isRead(self: RefEvent) bool {
        return self.flags.read;
    }

    fn isPureWrite(self: RefEvent) bool {
        return self.flags.write and !self.flags.read;
    }
};

const DeadStoreRefIndex = struct {
    const EventList = std.ArrayListUnmanaged(RefEvent);

    by_key: std.AutoHashMapUnmanaged(RefKey, EventList) = .empty,
    all_events: std.ArrayListUnmanaged(RefEvent) = .empty,
    declare_events: std.ArrayListUnmanaged(RefEvent) = .empty,

    fn init(allocator: std.mem.Allocator, references: []const Reference) !DeadStoreRefIndex {
        var index: DeadStoreRefIndex = .{};
        errdefer index.deinit(allocator);

        for (references, 0..) |ref, ref_pos| {
            if (ref.scope_stmt_idx == Reference.NO_STMT) continue;

            const symbol_id: u32 = @intFromEnum(ref.symbol_id);
            const scope_id: u32 = @intFromEnum(ref.scope_id);
            const event: RefEvent = .{
                .ref_pos = @intCast(ref_pos),
                .node_idx = @intFromEnum(ref.node_index),
                .stmt_idx = ref.scope_stmt_idx,
                .symbol_id = symbol_id,
                .scope_id = scope_id,
                .flags = ref.flags,
            };

            if (ref.flags.declare) {
                try index.declare_events.append(allocator, event);
                continue;
            }
            if (!ref.isValueUse()) continue;
            if (ref.node_index.isNone()) continue;

            try index.all_events.append(allocator, event);
            const key: RefKey = .{ .symbol_id = symbol_id, .scope_id = scope_id };
            const gop = try index.by_key.getOrPut(allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.append(allocator, event);
        }

        return index;
    }

    fn deinit(self: *DeadStoreRefIndex, allocator: std.mem.Allocator) void {
        var it = self.by_key.valueIterator();
        while (it.next()) |events| {
            events.deinit(allocator);
        }
        self.by_key.deinit(allocator);
        self.all_events.deinit(allocator);
        self.declare_events.deinit(allocator);
    }

    fn findWriteForNode(self: *const DeadStoreRefIndex, symbol_id: u32, node_idx: u32) ?RefEvent {
        for (self.all_events.items) |event| {
            if (event.symbol_id == symbol_id and event.node_idx == node_idx and event.isPureWrite()) return event;
        }
        return null;
    }

    fn findUniquePureWriteInStmt(self: *const DeadStoreRefIndex, symbol_id: u32, stmt_idx: u32) ?RefEvent {
        var found: ?RefEvent = null;
        for (self.all_events.items) |event| {
            if (event.symbol_id != symbol_id) continue;
            if (event.stmt_idx != stmt_idx) continue;
            if (!event.isPureWrite()) continue;
            if (found != null) return null;
            found = event;
        }
        return found;
    }

    fn findWriteForAssignment(self: *const DeadStoreRefIndex, symbol_id: u32, node_idx: u32, stmt_idx: u32) ?RefEvent {
        return self.findWriteForNode(symbol_id, node_idx) orelse self.findUniquePureWriteInStmt(symbol_id, stmt_idx);
    }

    fn findDeclare(self: *const DeadStoreRefIndex, symbol_id: u32, scope_id: u32, stmt_idx: u32) ?RefEvent {
        for (self.declare_events.items) |event| {
            if (event.symbol_id == symbol_id and event.scope_id == scope_id and event.stmt_idx == stmt_idx) return event;
        }
        return null;
    }

    fn firstSameScopeEventAfter(self: *const DeadStoreRefIndex, event: RefEvent) ?RefEvent {
        const events = self.by_key.get(.{ .symbol_id = event.symbol_id, .scope_id = event.scope_id }) orelse return null;
        for (events.items) |candidate| {
            if (candidate.ref_pos <= event.ref_pos) continue;
            if (candidate.stmt_idx < event.stmt_idx) continue;
            return candidate;
        }
        return null;
    }

    /// `start_event` 다음에 같은 symbol 을 덮어쓰는 pure write event 를 반환한다.
    /// 사이에 read 가 있거나 같은 statement 안에서 read 가 같이 있으면 보존을 위해 null.
    /// closure 등 다른 scope 의 read 도 보존해야 하므로 read 검사는 모든 scope 를 본다.
    fn findOverwriteAfter(self: *const DeadStoreRefIndex, start_event: RefEvent) ?RefEvent {
        const next_event = self.firstSameScopeEventAfter(start_event) orelse return null;
        if (!next_event.isPureWrite()) return null;
        if (self.hasReadBetween(start_event.symbol_id, start_event.ref_pos, next_event.ref_pos)) return null;
        if (self.hasReadInStmt(start_event.symbol_id, next_event.stmt_idx, next_event.ref_pos)) return null;
        return next_event;
    }

    fn hasReadBetween(self: *const DeadStoreRefIndex, symbol_id: u32, start_ref_pos: u32, end_ref_pos: u32) bool {
        for (self.all_events.items) |event| {
            if (event.symbol_id != symbol_id) continue;
            if (event.ref_pos <= start_ref_pos or event.ref_pos >= end_ref_pos) continue;
            if (event.isRead()) return true;
        }
        return false;
    }

    fn hasReadInStmt(self: *const DeadStoreRefIndex, symbol_id: u32, stmt_idx: u32, except_ref_pos: u32) bool {
        for (self.all_events.items) |event| {
            if (event.symbol_id != symbol_id) continue;
            if (event.stmt_idx != stmt_idx) continue;
            if (event.ref_pos == except_ref_pos) continue;
            if (event.isRead()) return true;
        }
        return false;
    }
};

test "DeadStoreRefIndex matches transformed assignment by unique same-statement write" {
    const allocator = std.testing.allocator;
    const old_lhs_node: NodeIndex = @enumFromInt(10);
    const transformed_lhs_node: u32 = 200;
    const references = [_]Reference{
        .{
            .node_index = old_lhs_node,
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(2),
            .stmt_idx = 0,
            .scope_stmt_idx = 3,
            .flags = .{ .write = true },
        },
    };

    var index = try DeadStoreRefIndex.init(allocator, &references);
    defer index.deinit(allocator);

    try std.testing.expect(index.findWriteForNode(2, transformed_lhs_node) == null);
    const event = index.findWriteForAssignment(2, transformed_lhs_node, 3) orelse return error.MissingWriteEvent;
    try std.testing.expectEqual(@as(u32, @intFromEnum(old_lhs_node)), event.node_idx);
    try std.testing.expectEqual(@as(u32, 3), event.stmt_idx);
}

test "DeadStoreRefIndex does not guess when same-statement writes are ambiguous" {
    const allocator = std.testing.allocator;
    const references = [_]Reference{
        .{
            .node_index = @enumFromInt(10),
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(2),
            .stmt_idx = 0,
            .scope_stmt_idx = 3,
            .flags = .{ .write = true },
        },
        .{
            .node_index = @enumFromInt(11),
            .scope_id = @enumFromInt(1),
            .symbol_id = @enumFromInt(2),
            .stmt_idx = 0,
            .scope_stmt_idx = 3,
            .flags = .{ .write = true },
        },
    };

    var index = try DeadStoreRefIndex.init(allocator, &references);
    defer index.deinit(allocator);

    try std.testing.expect(index.findWriteForAssignment(2, 200, 3) == null);
}

pub fn markDeadOverwrittenAssignments(
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    references: []const Reference,
    symbols: []const Symbol,
    unresolved_globals: ?*const purity.GlobalRefSet,
    skip_nodes: *std.DynamicBitSet,
    module: *const Module,
) !void {
    if (ast.nodes.items.len == 0) return;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    const stmts = ast.extra_data.items[list.start .. list.start + list.len];

    var ref_index = try DeadStoreRefIndex.init(allocator, references);
    defer ref_index.deinit(allocator);

    markDeadOverwrittenInStatementList(ast, stmts, symbol_ids, symbols, &ref_index, unresolved_globals, skip_nodes, module);
}

pub fn markDeadOverwrittenFunctionBodiesOnly(
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbol_ids: []const ?u32,
    references: []const Reference,
    symbols: []const Symbol,
    unresolved_globals: ?*const purity.GlobalRefSet,
    skip_nodes: *std.DynamicBitSet,
    module: *const Module,
) !void {
    if (ast.nodes.items.len == 0) return;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return;

    var ref_index = try DeadStoreRefIndex.init(allocator, references);
    defer ref_index.deinit(allocator);

    for (ast.nodes.items) |node| {
        if (ast.functionBodyBlock(node) == null) continue;
        markDeadOverwrittenFunctionBody(ast, node, symbol_ids, symbols, &ref_index, unresolved_globals, skip_nodes, module);
    }
}

fn markDeadOverwrittenInStatementList(
    ast: *Ast,
    stmts: []const u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    ref_index: *const DeadStoreRefIndex,
    unresolved_globals: ?*const purity.GlobalRefSet,
    skip_nodes: *std.DynamicBitSet,
    module: *const Module,
) void {
    for (stmts, 0..) |raw_stmt, i| {
        if (raw_stmt >= ast.nodes.items.len) continue;
        if (raw_stmt < skip_nodes.capacity() and skip_nodes.isSet(raw_stmt)) continue;
        markDeadOverwrittenDeclarationInitializers(ast, raw_stmt, i, stmts, symbol_ids, symbols, ref_index, unresolved_globals, module);
        const current = assignmentInfoForStmt(ast, raw_stmt, symbol_ids, unresolved_globals, true) orelse continue;
        const current_write = ref_index.findWriteForAssignment(current.sym_idx, current.lhs_idx, @intCast(i)) orelse continue;
        const next_event = ref_index.findOverwriteAfter(current_write) orelse continue;
        if (next_event.stmt_idx <= i or next_event.stmt_idx >= stmts.len) continue;
        const next_raw = stmts[next_event.stmt_idx];
        if (next_raw >= ast.nodes.items.len) continue;
        if (next_raw < skip_nodes.capacity() and skip_nodes.isSet(next_raw)) continue;
        const next_assign = assignmentInfoForStmt(ast, next_raw, symbol_ids, unresolved_globals, false) orelse continue;
        if (next_assign.sym_idx != current.sym_idx) continue;
        if (ref_index.findWriteForAssignment(next_assign.sym_idx, next_assign.lhs_idx, next_event.stmt_idx) == null) continue;
        if (current.stmt_idx < skip_nodes.capacity()) skip_nodes.set(current.stmt_idx);
    }

    for (stmts) |raw_stmt| {
        markDeadOverwrittenNestedStatementLists(ast, raw_stmt, symbol_ids, symbols, ref_index, unresolved_globals, skip_nodes, module);
    }
}

fn markDeadOverwrittenNestedStatementLists(
    ast: *Ast,
    node_idx: u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    ref_index: *const DeadStoreRefIndex,
    unresolved_globals: ?*const purity.GlobalRefSet,
    skip_nodes: *std.DynamicBitSet,
    module: *const Module,
) void {
    if (node_idx >= ast.nodes.items.len) return;
    const node = ast.nodes.items[node_idx];

    if (node.tag == .block_statement) {
        const list = node.data.list;
        if (list.start + list.len <= ast.extra_data.items.len) {
            const stmts = ast.extra_data.items[list.start .. list.start + list.len];
            markDeadOverwrittenInStatementList(ast, stmts, symbol_ids, symbols, ref_index, unresolved_globals, skip_nodes, module);
        }
    }

    markDeadOverwrittenFunctionBody(ast, node, symbol_ids, symbols, ref_index, unresolved_globals, skip_nodes, module);
}

fn markDeadOverwrittenFunctionBody(
    ast: *Ast,
    node: ast_mod.Node,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    ref_index: *const DeadStoreRefIndex,
    unresolved_globals: ?*const purity.GlobalRefSet,
    skip_nodes: *std.DynamicBitSet,
    module: *const Module,
) void {
    if (ast.functionBodyBlock(node)) |body_idx| {
        if (@intFromEnum(body_idx) < ast.nodes.items.len) {
            const body = ast.nodes.items[@intFromEnum(body_idx)];
            if (body.tag == .block_statement) {
                const list = body.data.list;
                if (list.start + list.len <= ast.extra_data.items.len) {
                    const stmts = ast.extra_data.items[list.start .. list.start + list.len];
                    markDeadOverwrittenInStatementList(ast, stmts, symbol_ids, symbols, ref_index, unresolved_globals, skip_nodes, module);
                }
            }
        }
    }
}

fn markDeadOverwrittenDeclarationInitializers(
    ast: *Ast,
    stmt_idx: u32,
    stmt_pos: usize,
    stmts: []const u32,
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    ref_index: *const DeadStoreRefIndex,
    unresolved_globals: ?*const purity.GlobalRefSet,
    module: *const Module,
) void {
    if (stmt_idx >= ast.nodes.items.len) return;
    const stmt = ast.nodes.items[stmt_idx];
    if (stmt.tag != .variable_declaration) return;

    const kind = ast.variableDeclarationKind(stmt);
    if (kind == .@"const" or kind.isUsing()) return;

    const e = stmt.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return;
    const list_start = ast.extra_data.items[e + 1];
    const list_len = ast.extra_data.items[e + 2];
    if (list_len != 1 or list_start >= ast.extra_data.items.len) return;

    const decl_idx = ast.extra_data.items[list_start];
    if (decl_idx >= ast.nodes.items.len) return;
    const decl = ast.nodes.items[decl_idx];
    if (decl.tag != .variable_declarator) return;

    const de = decl.data.extra;
    if (de + 2 >= ast.extra_data.items.len) return;
    const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de]);
    const init_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de + 2]);
    if (name_idx.isNone() or init_idx.isNone()) return;
    const name_ni = @intFromEnum(name_idx);
    if (name_ni >= ast.nodes.items.len or name_ni >= symbol_ids.len) return;
    const name = ast.nodes.items[name_ni];
    if (name.tag != .binding_identifier) return;
    const sym_idx: u32 = @intCast(symbol_ids[name_ni] orelse return);
    if (sym_idx >= symbols.len) return;
    if (isExportedSymbol(module, sym_idx)) return;
    if (!purity.isExprPure(ast, init_idx, unresolved_globals)) return;

    const decl_scope = @intFromEnum(symbols[sym_idx].scope_id);
    const declare_event = ref_index.findDeclare(sym_idx, decl_scope, @intCast(stmt_pos)) orelse return;
    const next_event = ref_index.findOverwriteAfter(declare_event) orelse return;
    if (next_event.stmt_idx <= stmt_pos or next_event.stmt_idx >= stmts.len) return;

    const next_raw = stmts[next_event.stmt_idx];
    if (next_raw >= ast.nodes.items.len) return;
    const next_assign = assignmentInfoForStmt(ast, next_raw, symbol_ids, unresolved_globals, false) orelse return;
    if (next_assign.sym_idx != sym_idx) return;
    if (ref_index.findWriteForAssignment(next_assign.sym_idx, next_assign.lhs_idx, next_event.stmt_idx) == null) return;
    ast.extra_data.items[de + 2] = @intFromEnum(NodeIndex.none);
}

fn isExportedSymbol(module: *const Module, sym_idx: u32) bool {
    for (module.export_bindings) |binding| {
        if (binding.symbol.semanticIndex()) |export_sym| {
            if (export_sym == sym_idx) return true;
        }
    }
    return false;
}

fn assignmentInfoForStmt(
    ast: *const Ast,
    stmt_idx: u32,
    symbol_ids: []const ?u32,
    unresolved_globals: ?*const purity.GlobalRefSet,
    require_pure_rhs: bool,
) ?AssignmentInfo {
    if (stmt_idx >= ast.nodes.items.len) return null;
    const stmt = ast.nodes.items[stmt_idx];
    if (stmt.tag != .expression_statement) return null;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag != .assignment_expression) return null;

    const op: TokenKind = @enumFromInt(expr.data.binary.flags);
    if (op != .eq) return null;

    const lhs_idx = expr.data.binary.left;
    if (lhs_idx.isNone() or @intFromEnum(lhs_idx) >= ast.nodes.items.len) return null;
    const lhs = ast.nodes.items[@intFromEnum(lhs_idx)];
    if (lhs.tag != .assignment_target_identifier and lhs.tag != .identifier_reference) return null;
    const lhs_ni = @intFromEnum(lhs_idx);
    if (lhs_ni >= symbol_ids.len) return null;
    const sym_idx: u32 = @intCast(symbol_ids[lhs_ni] orelse return null);

    const rhs_idx = expr.data.binary.right;
    if (require_pure_rhs and !purity.isExprPure(ast, rhs_idx, unresolved_globals)) return null;

    return .{
        .stmt_idx = stmt_idx,
        .lhs_idx = @intCast(lhs_ni),
        .sym_idx = sym_idx,
    };
}
