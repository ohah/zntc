//! 변환 중 AST 변경과 함께 의미 정보를 갱신하는 명시적 편집기 (#4819).
//!
//! SymbolId는 한 번 부여하면 이 편집기의 수명 동안 재배정하지 않는다. 이름이나
//! 소스 위치로 바인딩을 다시 찾지 않고, 생성자가 넘긴 scope와 SymbolId를 사용한다.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const scope_mod = @import("scope.zig");
const symbol_mod = @import("symbol.zig");

const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const Scope = scope_mod.Scope;
const ScopeId = scope_mod.ScopeId;
const ScopeKind = scope_mod.ScopeKind;
const Symbol = symbol_mod.Symbol;
const SymbolId = symbol_mod.SymbolId;
const SymbolKind = symbol_mod.SymbolKind;
const Reference = symbol_mod.Reference;
const ReferenceFlags = symbol_mod.ReferenceFlags;

pub const Error = std.mem.Allocator.Error || error{
    InvalidScope,
    InvalidSymbol,
    InvalidNode,
    ScopeOwnerConflict,
    DuplicateBinding,
    AlreadyBound,
    ReferenceNotFound,
};

/// 기존 analyzer 결과를 복사해 가변 상태로 보관한다. 원본 slice는 변경하지 않는다.
/// allocator는 모듈 arena여야 한다. 생성한 이름은 최종 출력까지 살아 있어야 한다.
pub const SemanticEditor = struct {
    allocator: std.mem.Allocator,
    ast: *Ast,
    symbols: std.ArrayList(Symbol) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    scope_maps: std.ArrayList(std.StringHashMapUnmanaged(usize)) = .empty,
    scope_owner_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    helper_scope_map: std.StringHashMapUnmanaged(usize) = .empty,
    references: std.ArrayList(Reference) = .empty,
    symbol_ids: std.ArrayList(?u32) = .empty,

    /// 편집 완료 후 번들러 모듈 또는 단일 파일 출력 경로에 넘길 소유 데이터.
    /// 모든 slice는 init에 전달한 모듈 arena가 소유한다.
    pub const Result = struct {
        symbols: std.ArrayList(Symbol),
        scopes: []Scope,
        scope_maps: []std.StringHashMapUnmanaged(usize),
        scope_owner_map: std.AutoHashMapUnmanaged(u32, u32),
        helper_scope_map: std.StringHashMapUnmanaged(usize),
        references: []Reference,
        symbol_ids: []?u32,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        ast: *Ast,
        symbols: []const Symbol,
        scopes: []const Scope,
        scope_maps: []const std.StringHashMapUnmanaged(usize),
        scope_owner_map: std.AutoHashMapUnmanaged(u32, u32),
        references: []const Reference,
        symbol_ids: []const ?u32,
        helper_scope_map: std.StringHashMapUnmanaged(usize),
    ) Error!SemanticEditor {
        if (scopes.len != scope_maps.len) return error.InvalidScope;
        var self: SemanticEditor = .{ .allocator = allocator, .ast = ast };
        errdefer self.deinit();
        try self.symbols.appendSlice(allocator, symbols);
        try self.scopes.appendSlice(allocator, scopes);
        for (scope_maps) |source_map| {
            var map: std.StringHashMapUnmanaged(usize) = .empty;
            errdefer map.deinit(allocator);
            var iter = source_map.iterator();
            while (iter.next()) |entry| {
                try map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
            try self.scope_maps.append(allocator, map);
        }
        var owner_iter = scope_owner_map.iterator();
        while (owner_iter.next()) |entry| {
            try self.scope_owner_map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        var helper_iter = helper_scope_map.iterator();
        while (helper_iter.next()) |entry| {
            try self.helper_scope_map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        try self.references.appendSlice(allocator, references);
        try self.symbol_ids.appendSlice(allocator, symbol_ids);
        return self;
    }

    pub fn deinit(self: *SemanticEditor) void {
        for (self.scope_maps.items) |*map| map.deinit(self.allocator);
        self.scope_maps.deinit(self.allocator);
        self.scope_owner_map.deinit(self.allocator);
        self.helper_scope_map.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        self.references.deinit(self.allocator);
        self.symbol_ids.deinit(self.allocator);
    }

    pub fn finish(self: *SemanticEditor) Error!Result {
        const scopes = try self.scopes.toOwnedSlice(self.allocator);
        const scope_maps = try self.scope_maps.toOwnedSlice(self.allocator);
        const references = try self.references.toOwnedSlice(self.allocator);
        const symbol_ids = try self.symbol_ids.toOwnedSlice(self.allocator);
        const symbols = self.symbols;
        const scope_owner_map = self.scope_owner_map;
        const helper_scope_map = self.helper_scope_map;
        self.symbols = .empty;
        self.scope_owner_map = .empty;
        self.helper_scope_map = .empty;
        return .{
            .symbols = symbols,
            .scopes = scopes,
            .scope_maps = scope_maps,
            .scope_owner_map = scope_owner_map,
            .helper_scope_map = helper_scope_map,
            .references = references,
            .symbol_ids = symbol_ids,
        };
    }

    fn validScope(self: *const SemanticEditor, id: ScopeId) bool {
        return !id.isNone() and id.toIndex() < self.scopes.items.len;
    }

    fn validSymbol(self: *const SemanticEditor, id: SymbolId) bool {
        return !id.isNone() and @intFromEnum(id) < self.symbols.items.len;
    }

    fn visibleFrom(self: *const SemanticEditor, symbol: SymbolId, scope: ScopeId) bool {
        if (!self.validSymbol(symbol) or !self.validScope(scope)) return false;
        const target = self.symbols.items[@intFromEnum(symbol)].scope_id;
        var current = scope;
        var hops: usize = 0;
        while (hops < self.scopes.items.len) : (hops += 1) {
            if (current == target) return true;
            current = self.scopes.items[current.toIndex()].parent;
            if (current.isNone() or !self.validScope(current)) return false;
        }
        return false;
    }

    fn requireIdentifier(self: *const SemanticEditor, idx: NodeIndex) Error!void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return error.InvalidNode;
        switch (self.ast.getNode(idx).tag) {
            .binding_identifier, .identifier_reference, .assignment_target_identifier => {},
            else => return error.InvalidNode,
        }
    }

    fn ensureNodeSlot(self: *SemanticEditor, idx: NodeIndex) Error!usize {
        try self.requireIdentifier(idx);
        const i = @intFromEnum(idx);
        if (self.symbol_ids.items.len <= i) {
            try self.symbol_ids.appendNTimes(self.allocator, null, i + 1 - self.symbol_ids.items.len);
        }
        return i;
    }

    /// AST가 새 어휘 경계를 만들 때 호출한다. strict는 부모에서 자식으로 전파된다.
    pub fn addScope(self: *SemanticEditor, parent: ScopeId, owner: NodeIndex, kind: ScopeKind, is_strict: bool) Error!ScopeId {
        if (!parent.isNone() and !self.validScope(parent)) return error.InvalidScope;
        if (parent.isNone() and self.scopes.items.len != 0) return error.InvalidScope;
        if (!owner.isNone() and @intFromEnum(owner) >= self.ast.nodes.items.len) return error.InvalidNode;
        const strict = is_strict or (if (parent.isNone()) false else self.scopes.items[parent.toIndex()].is_strict);
        const id: ScopeId = @enumFromInt(@as(u32, @intCast(self.scopes.items.len)));
        try self.scopes.append(self.allocator, .{ .parent = parent, .kind = kind, .is_strict = strict });
        errdefer _ = self.scopes.pop();
        try self.scope_maps.append(self.allocator, .empty);
        if (!owner.isNone()) try self.scope_owner_map.put(self.allocator, @intFromEnum(owner), @intFromEnum(id));
        return id;
    }

    /// 동일한 어휘 경계를 가진 노드를 트랜스포머가 복사했을 때 소유자를 새 AST 노드로 옮긴다.
    /// 기존 노드를 재방문해도 scope_id를 새로 만들지 않는다.
    pub fn remapScopeOwner(self: *SemanticEditor, old_owner: NodeIndex, new_owner: NodeIndex) Error!void {
        if (old_owner.isNone() or new_owner.isNone() or
            @intFromEnum(old_owner) >= self.ast.nodes.items.len or
            @intFromEnum(new_owner) >= self.ast.nodes.items.len) return error.InvalidNode;
        const old_key = @intFromEnum(old_owner);
        const new_key = @intFromEnum(new_owner);
        if (self.ast.getNode(old_owner).tag != self.ast.getNode(new_owner).tag) return error.InvalidNode;
        const scope_id = self.scope_owner_map.get(old_key) orelse return error.InvalidScope;
        if (old_key == new_key) return;
        if (self.scope_owner_map.get(new_key)) |existing| {
            if (existing != scope_id) return error.ScopeOwnerConflict;
        } else {
            try self.scope_owner_map.put(self.allocator, new_key, scope_id);
        }
        _ = self.scope_owner_map.remove(old_key);
    }

    fn bindingScope(self: *const SemanticEditor, lexical_scope: ScopeId, kind: SymbolKind) Error!ScopeId {
        if (!self.validScope(lexical_scope)) return error.InvalidScope;
        if (kind != .variable_var) return lexical_scope;
        var scope = lexical_scope;
        var hops: usize = 0;
        while (hops < self.scopes.items.len) : (hops += 1) {
            if (self.scopes.items[scope.toIndex()].kind.isVarScope()) return scope;
            scope = self.scopes.items[scope.toIndex()].parent;
            if (scope.isNone() or !self.validScope(scope)) return error.InvalidScope;
        }
        return error.InvalidScope;
    }

    /// 새 합성 바인딩을 선언한다. name_span은 AST string table의 이름이어야 한다.
    /// stmt_idx는 최상위 문장, scope_stmt_idx는 직접 소속된 스코프의 문장 인덱스다.
    pub fn declare(
        self: *SemanticEditor,
        binding: NodeIndex,
        name_span: Span,
        declaration_span: Span,
        lexical_scope: ScopeId,
        kind: SymbolKind,
        stmt_idx: u32,
        scope_stmt_idx: u32,
    ) Error!SymbolId {
        const node_slot = try self.ensureNodeSlot(binding);
        if (self.ast.getNode(binding).tag != .binding_identifier) return error.InvalidNode;
        if (name_span.start & Ast.STRING_TABLE_BIT == 0) return error.InvalidNode;
        if (!std.mem.eql(u8, self.ast.getText(self.ast.getNode(binding).data.string_ref), self.ast.getText(name_span))) return error.InvalidNode;
        if (self.symbol_ids.items[node_slot] != null) return error.AlreadyBound;
        const target = try self.bindingScope(lexical_scope, kind);
        const name = try self.ast.getTextStable(self.allocator, name_span);
        if (self.scope_maps.items[target.toIndex()].contains(name)) return error.DuplicateBinding;
        const id: SymbolId = @enumFromInt(@as(u32, @intCast(self.symbols.items.len)));
        try self.symbols.append(self.allocator, .{
            .name = name_span,
            .scope_id = target,
            .origin_scope = lexical_scope,
            .kind = kind,
            .decl_flags = kind.declFlags(),
            .declaration_span = declaration_span,
            .synthetic_name = name,
        });
        try self.scope_maps.items[target.toIndex()].put(self.allocator, name, @intFromEnum(id));
        try self.references.append(self.allocator, .{
            .node_index = .none,
            .scope_id = target,
            .symbol_id = id,
            .stmt_idx = stmt_idx,
            .scope_stmt_idx = scope_stmt_idx,
            .flags = .{ .declare = true },
        });
        self.symbol_ids.items[node_slot] = @intFromEnum(id);
        self.scopes.items[target.toIndex()].symbol_count +|= 1;
        return id;
    }

    /// 헬퍼 import의 local 노드는 파서 관례상 identifier_reference일 수 있다.
    /// 사용자 동명 선언과 충돌해도 별도 helper_scope_map에 보관한다.
    pub fn declareHelperImport(self: *SemanticEditor, local: NodeIndex, name_span: Span, declaration_span: Span, scope: ScopeId) Error!SymbolId {
        const slot = try self.ensureNodeSlot(local);
        if (!self.validScope(scope)) return error.InvalidScope;
        if (self.symbol_ids.items[slot] != null) return error.AlreadyBound;
        if (self.ast.getNode(local).tag != .identifier_reference) return error.InvalidNode;
        if (name_span.start & Ast.STRING_TABLE_BIT == 0) return error.InvalidNode;
        const name = try self.ast.getTextStable(self.allocator, name_span);
        if (self.helper_scope_map.contains(name)) return error.DuplicateBinding;
        const id: SymbolId = @enumFromInt(@as(u32, @intCast(self.symbols.items.len)));
        try self.symbols.append(self.allocator, .{
            .name = name_span,
            .scope_id = scope,
            .origin_scope = scope,
            .kind = .import_binding,
            .decl_flags = SymbolKind.import_binding.declFlags(),
            .declaration_span = declaration_span,
            .synthetic_name = name,
        });
        try self.helper_scope_map.put(self.allocator, name, @intFromEnum(id));
        if (!self.scope_maps.items[scope.toIndex()].contains(name)) {
            try self.scope_maps.items[scope.toIndex()].put(self.allocator, name, @intFromEnum(id));
            self.scopes.items[scope.toIndex()].symbol_count +|= 1;
        }
        try self.references.append(self.allocator, .{
            .node_index = .none,
            .scope_id = scope,
            .symbol_id = id,
            .stmt_idx = Reference.NO_STMT,
            .scope_stmt_idx = Reference.NO_STMT,
            .flags = .{ .declare = true },
        });
        self.symbol_ids.items[slot] = @intFromEnum(id);
        return id;
    }

    fn countsAsValue(flags: ReferenceFlags) bool {
        return !flags.declare and !flags.type_context and !flags.value_as_type;
    }

    fn addCounts(self: *SemanticEditor, id: SymbolId, flags: ReferenceFlags) void {
        if (!countsAsValue(flags)) return;
        const sym = &self.symbols.items[@intFromEnum(id)];
        sym.reference_count += 1;
        if (flags.write) sym.write_count += 1;
    }

    fn removeCounts(self: *SemanticEditor, id: SymbolId, flags: ReferenceFlags) void {
        if (!countsAsValue(flags)) return;
        const sym = &self.symbols.items[@intFromEnum(id)];
        std.debug.assert(sym.reference_count > 0);
        sym.reference_count -= 1;
        if (flags.write) {
            std.debug.assert(sym.write_count > 0);
            sym.write_count -= 1;
        }
    }

    /// 참조 대상은 이름 검색 없이 호출자가 넘긴 SymbolId로 확정한다.
    pub fn addReference(
        self: *SemanticEditor,
        node: NodeIndex,
        symbol: SymbolId,
        scope: ScopeId,
        flags: ReferenceFlags,
        stmt_idx: u32,
        scope_stmt_idx: u32,
    ) Error!void {
        if (!self.validSymbol(symbol)) return error.InvalidSymbol;
        if (!self.validScope(scope)) return error.InvalidScope;
        if (!self.visibleFrom(symbol, scope)) return error.InvalidScope;
        const slot = try self.ensureNodeSlot(node);
        if (self.ast.getNode(node).tag == .binding_identifier or flags.declare) return error.InvalidNode;
        if (self.symbol_ids.items[slot] != null) return error.AlreadyBound;
        try self.references.append(self.allocator, .{
            .node_index = node,
            .scope_id = scope,
            .symbol_id = symbol,
            .stmt_idx = stmt_idx,
            .scope_stmt_idx = scope_stmt_idx,
            .flags = flags,
        });
        self.symbol_ids.items[slot] = @intFromEnum(symbol);
        self.addCounts(symbol, flags);
    }

    /// 서브트리를 다른 문장이나 스코프로 옮긴 경우 참조의 소유권을 수정한다.
    pub fn moveReference(self: *SemanticEditor, node: NodeIndex, scope: ScopeId, stmt_idx: u32, scope_stmt_idx: u32) Error!void {
        if (!self.validScope(scope)) return error.InvalidScope;
        for (self.references.items) |*ref| {
            if (ref.node_index != node) continue;
            if (!self.visibleFrom(ref.symbol_id, scope)) return error.InvalidScope;
            ref.scope_id = scope;
            ref.stmt_idx = stmt_idx;
            ref.scope_stmt_idx = scope_stmt_idx;
            return;
        }
        return error.ReferenceNotFound;
    }

    /// 제거된 참조의 사용 횟수도 되돌린다. 다른 참조의 순서는 유지한다.
    pub fn removeReference(self: *SemanticEditor, node: NodeIndex) Error!void {
        for (self.references.items, 0..) |ref, i| {
            if (ref.node_index != node) continue;
            if (!self.validSymbol(ref.symbol_id)) return error.InvalidSymbol;
            self.removeCounts(ref.symbol_id, ref.flags);
            _ = self.references.orderedRemove(i);
            const slot = @intFromEnum(node);
            if (slot < self.symbol_ids.items.len) self.symbol_ids.items[slot] = null;
            return;
        }
        return error.ReferenceNotFound;
    }
};

test "synthetic declaration, explicit references, move and removal keep stable IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const block_owner = try ast.addNode(.{
        .tag = .block_statement,
        .span = Span.EMPTY,
        .data = .{ .list = try ast.addNodeList(&.{}) },
    });
    const block = try editor.addScope(root, block_owner, .block, false);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(block)), editor.scope_owner_map.get(@intFromEnum(block_owner)));
    try std.testing.expect(editor.scopes.items[block.toIndex()].is_strict);
    const name = try ast.addString("_this");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref_node = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(binding, name, Span.EMPTY, block, .variable_var, 2, 1);
    try std.testing.expectEqual(root, editor.symbols.items[@intFromEnum(id)].scope_id);
    try editor.addReference(ref_node, id, block, .{ .read = true }, 2, 1);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(id)].reference_count);
    try editor.moveReference(ref_node, root, 3, 0);
    try std.testing.expectEqual(@as(u32, 3), editor.references.items[1].stmt_idx);
    try editor.removeReference(ref_node);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(id)].reference_count);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(id)), editor.symbol_ids.items[@intFromEnum(binding)]);
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@intFromEnum(ref_node)]);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(usize, 2), result.scopes.len);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(block)), result.scope_owner_map.get(@intFromEnum(block_owner)));
    try std.testing.expectEqual(@as(usize, 1), result.symbols.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.references.len);
}

test "same provisional name in separate scopes never shares a symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const left = try editor.addScope(root, .none, .function, false);
    const right = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("_this");
    const left_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const right_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const left_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const right_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const left_id = try editor.declare(left_binding, name, Span.EMPTY, left, .variable_var, 0, 0);
    const right_id = try editor.declare(right_binding, name, Span.EMPTY, right, .variable_var, 1, 0);
    try std.testing.expect(left_id != right_id);
    try editor.addReference(left_ref, left_id, left, .{ .read = true }, 0, 0);
    try editor.addReference(right_ref, right_id, right, .{ .read = true }, 1, 0);
    const wrong_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    try std.testing.expectError(error.InvalidScope, editor.addReference(wrong_ref, left_id, right, .{ .read = true }, 1, 0));
    try std.testing.expectError(error.InvalidScope, editor.moveReference(left_ref, right, 1, 0));
    try std.testing.expectEqual(@as(?u32, @intFromEnum(left_id)), editor.symbol_ids.items[@intFromEnum(left_ref)]);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(right_id)), editor.symbol_ids.items[@intFromEnum(right_ref)]);
    try std.testing.expectError(error.DuplicateBinding, editor.declare(
        try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } }),
        name,
        Span.EMPTY,
        left,
        .variable_var,
        0,
        1,
    ));
}

test "helper import remains isolated from a user binding with the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const name = try ast.addString("__extends");
    const user_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const helper_local = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const helper_call = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const user_id = try editor.declare(user_binding, name, Span.EMPTY, root, .variable_const, 0, 0);
    const helper_id = try editor.declareHelperImport(helper_local, name, Span.EMPTY, root);
    try std.testing.expect(user_id != helper_id);
    try std.testing.expectEqual(@as(?usize, @intFromEnum(user_id)), editor.scope_maps.items[root.toIndex()].get("__extends"));
    try std.testing.expectEqual(@as(?usize, @intFromEnum(helper_id)), editor.helper_scope_map.get("__extends"));
    try editor.addReference(helper_call, helper_id, root, .{ .read = true }, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(user_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(helper_id)].reference_count);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(?usize, @intFromEnum(helper_id)), result.helper_scope_map.get("__extends"));
}

test "invalid identities and type-only references cannot corrupt liveness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const name = try ast.addString("temp");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const type_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const write_ref = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(binding, name, Span.EMPTY, root, .variable_let, 0, 0);
    try std.testing.expectError(error.InvalidSymbol, editor.addReference(type_ref, .none, root, .{ .read = true }, 0, 0));
    try std.testing.expectError(error.InvalidScope, editor.addReference(type_ref, id, .none, .{ .read = true }, 0, 0));
    try editor.addReference(type_ref, id, root, .{ .read = true, .type_context = true }, 0, 0);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(id)].reference_count);
    try std.testing.expectError(error.AlreadyBound, editor.addReference(type_ref, id, root, .{ .read = true }, 0, 0));
    try editor.addReference(write_ref, id, root, .{ .write = true }, 0, 0);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(id)].write_count);
    try editor.removeReference(write_ref);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(id)].write_count);
    try std.testing.expectError(error.ReferenceNotFound, editor.removeReference(write_ref));
}
