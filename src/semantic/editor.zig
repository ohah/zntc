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
    reference_index: std.AutoHashMapUnmanaged(u32, usize) = .empty,
    reference_index_built: bool = false,
    symbol_ids: std.ArrayList(?u32) = .empty,
    scope_reparented: bool = false,

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
        self.reference_index.deinit(self.allocator);
        self.symbol_ids.deinit(self.allocator);
    }

    pub fn finish(self: *SemanticEditor) Error!Result {
        if (self.scope_reparented) {
            for (self.references.items) |ref| {
                if (!self.visibleFrom(ref.symbol_id, ref.scope_id)) return error.InvalidScope;
            }
        }
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

    fn appendReference(self: *SemanticEditor, ref: Reference) Error!void {
        if (self.reference_index_built and !ref.node_index.isNone()) {
            const key = @intFromEnum(ref.node_index);
            if (self.reference_index.contains(key)) return error.AlreadyBound;
            try self.reference_index.put(self.allocator, key, self.references.items.len);
            errdefer _ = self.reference_index.remove(key);
        }
        try self.references.append(self.allocator, ref);
    }

    fn ensureReferenceIndex(self: *SemanticEditor) Error!void {
        if (self.reference_index_built) return;
        for (self.references.items, 0..) |ref, i| {
            if (!ref.node_index.isNone() and !self.reference_index.contains(@intFromEnum(ref.node_index))) {
                try self.reference_index.put(self.allocator, @intFromEnum(ref.node_index), i);
            }
        }
        self.reference_index_built = true;
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
        const old_tag = self.ast.getNode(old_owner).tag;
        const new_tag = self.ast.getNode(new_owner).tag;
        if (old_tag != new_tag and
            !(old_tag == .arrow_function_expression and new_tag == .function_expression) and
            !(old_tag == .for_of_statement and new_tag == .for_statement) and
            !(old_tag == .method_definition and (new_tag == .function_declaration or new_tag == .function_expression)))
            return error.InvalidNode;
        const scope_id = self.scope_owner_map.get(old_key) orelse return error.InvalidScope;
        if (old_key == new_key) return;
        if (self.scope_owner_map.get(new_key)) |existing| {
            if (existing != scope_id) return error.ScopeOwnerConflict;
        } else {
            try self.scope_owner_map.put(self.allocator, new_key, scope_id);
        }
        _ = self.scope_owner_map.remove(old_key);
    }

    /// AST 서브트리를 새 함수 안으로 옮길 때 기존 스코프 ID를 유지하며 부모만 바꾼다.
    /// 호출자는 이전 부모에만 보이던 참조를 finish 전에 재바인딩하거나 제거해야 한다.
    pub fn reparentScope(self: *SemanticEditor, scope: ScopeId, new_parent: ScopeId) Error!void {
        if (!self.validScope(scope) or !self.validScope(new_parent)) return error.InvalidScope;
        if (self.scopes.items[scope.toIndex()].parent.isNone()) return error.InvalidScope;
        var cursor = new_parent;
        var hops: usize = 0;
        while (!cursor.isNone()) : (hops += 1) {
            if (hops >= self.scopes.items.len or !self.validScope(cursor) or cursor == scope) return error.InvalidScope;
            cursor = self.scopes.items[cursor.toIndex()].parent;
        }
        if (self.scopes.items[scope.toIndex()].parent == new_parent) return;

        self.scopes.items[scope.toIndex()].parent = new_parent;
        self.scope_reparented = true;
        const new_strict = self.scopes.items[new_parent.toIndex()].is_strict;
        if (new_strict) {
            for (self.scopes.items, 0..) |*candidate, i| {
                var ancestor: ScopeId = @enumFromInt(@as(u32, @intCast(i)));
                var depth: usize = 0;
                while (!ancestor.isNone() and depth < self.scopes.items.len) : (depth += 1) {
                    if (!self.validScope(ancestor)) return error.InvalidScope;
                    if (ancestor == scope) {
                        candidate.is_strict = true;
                        break;
                    }
                    ancestor = self.scopes.items[ancestor.toIndex()].parent;
                }
            }
        }
        const moved = self.scopes.items[scope.toIndex()];
        cursor = new_parent;
        hops = 0;
        while (!cursor.isNone() and hops < self.scopes.items.len) : (hops += 1) {
            const ancestor = &self.scopes.items[cursor.toIndex()];
            ancestor.subtree_has_direct_eval = ancestor.subtree_has_direct_eval or moved.subtree_has_direct_eval;
            ancestor.subtree_has_with = ancestor.subtree_has_with or moved.subtree_has_with;
            cursor = ancestor.parent;
        }
    }

    /// 서브트리 이전 시 기존 참조가 새 바인딩을 가리키도록 바꾼다.
    pub fn rebindReference(self: *SemanticEditor, node: NodeIndex, symbol: SymbolId) Error!void {
        if (!self.validSymbol(symbol)) return error.InvalidSymbol;
        try self.ensureReferenceIndex();
        const slot = try self.ensureNodeSlot(node);
        const i = self.reference_index.get(@intFromEnum(node)) orelse return error.ReferenceNotFound;
        const ref = &self.references.items[i];
        if (ref.flags.declare) return error.InvalidNode;
        if (!self.visibleFrom(symbol, ref.scope_id)) return error.InvalidScope;
        self.removeCounts(ref.symbol_id, ref.flags);
        ref.symbol_id = symbol;
        self.symbol_ids.items[slot] = @intFromEnum(symbol);
        self.addCounts(symbol, ref.flags);
    }

    /// 참조의 위치와 대상을 함께 바꾼다. 이전 대상은 새 스코프에서 보이지 않고
    /// 새 대상은 이전 스코프에서 보이지 않는 경우에도 최종 쌍만 유효하면 이동한다.
    /// 오류가 나면 Reference, SymbolId, 사용 횟수는 변경하지 않는다.
    pub fn relocateReference(
        self: *SemanticEditor,
        node: NodeIndex,
        scope: ScopeId,
        symbol: SymbolId,
        stmt_idx: u32,
        scope_stmt_idx: u32,
    ) Error!void {
        if (!self.validScope(scope)) return error.InvalidScope;
        if (!self.validSymbol(symbol)) return error.InvalidSymbol;
        try self.requireIdentifier(node);
        if (self.ast.getNode(node).tag == .binding_identifier) return error.InvalidNode;
        try self.ensureReferenceIndex();
        const i = self.reference_index.get(@intFromEnum(node)) orelse return error.ReferenceNotFound;
        const current = self.references.items[i];
        if (current.flags.declare or (!current.flags.read and !current.flags.write)) return error.InvalidNode;
        if (!self.validScope(current.scope_id)) return error.InvalidScope;
        if (!self.validSymbol(current.symbol_id)) return error.InvalidSymbol;
        const slot = @intFromEnum(node);
        if (slot >= self.symbol_ids.items.len or self.symbol_ids.items[slot] != @as(?u32, @intFromEnum(current.symbol_id)))
            return error.InvalidSymbol;
        if (!self.visibleFrom(symbol, scope)) return error.InvalidScope;

        if (current.symbol_id != symbol and countsAsValue(current.flags)) {
            const source_counts = self.symbols.items[@intFromEnum(current.symbol_id)];
            const target_counts = self.symbols.items[@intFromEnum(symbol)];
            if (source_counts.reference_count == 0 or target_counts.reference_count == std.math.maxInt(u32))
                return error.InvalidSymbol;
            if (current.flags.write and
                (source_counts.write_count == 0 or target_counts.write_count == std.math.maxInt(u32)))
                return error.InvalidSymbol;
        }

        if (current.symbol_id != symbol) {
            self.removeCounts(current.symbol_id, current.flags);
            self.addCounts(symbol, current.flags);
        }
        self.references.items[i].scope_id = scope;
        self.references.items[i].symbol_id = symbol;
        self.references.items[i].stmt_idx = stmt_idx;
        self.references.items[i].scope_stmt_idx = scope_stmt_idx;
        self.symbol_ids.items[slot] = @intFromEnum(symbol);
    }

    /// AST 복사가 만든 새 식별자에 원본 참조의 대상과 read/write 플래그를 복제한다.
    /// 원본 노드가 최종 AST에서 사라졌다면 caller가 removeReference로 정리한다.
    pub fn cloneReference(self: *SemanticEditor, source: NodeIndex, clone: NodeIndex, scope: ScopeId, stmt_idx: u32, scope_stmt_idx: u32) Error!void {
        try self.ensureReferenceIndex();
        const source_i = self.reference_index.get(@intFromEnum(source)) orelse return error.ReferenceNotFound;
        const ref = self.references.items[source_i];
        if (ref.flags.declare) return error.InvalidNode;
        return self.addCopiedReference(clone, ref.symbol_id, scope, ref.flags, stmt_idx, scope_stmt_idx);
    }

    pub fn cloneReferenceAtSameLocation(self: *SemanticEditor, source: NodeIndex, clone: NodeIndex) Error!void {
        try self.ensureReferenceIndex();
        const i = self.reference_index.get(@intFromEnum(source)) orelse return error.ReferenceNotFound;
        const ref = self.references.items[i];
        return self.cloneReference(source, clone, ref.scope_id, ref.stmt_idx, ref.scope_stmt_idx);
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
        try self.appendReference(.{
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

    /// 새 참조에 SymbolId가 먼저 복사된 경로에서 Reference를 명시적으로 붙인다.
    /// 같은 ID여도 이미 Reference가 있으면 중복으로 거부한다.
    pub fn addCopiedReference(
        self: *SemanticEditor,
        node: NodeIndex,
        symbol: SymbolId,
        scope: ScopeId,
        flags: ReferenceFlags,
        stmt_idx: u32,
        scope_stmt_idx: u32,
    ) Error!void {
        if (!self.validSymbol(symbol)) return error.InvalidSymbol;
        if (!self.validScope(scope) or !self.visibleFrom(symbol, scope)) return error.InvalidScope;
        const slot = try self.ensureNodeSlot(node);
        if (self.ast.getNode(node).tag == .binding_identifier or flags.declare) return error.InvalidNode;
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing != @intFromEnum(symbol)) return error.AlreadyBound;
        }
        try self.ensureReferenceIndex();
        try self.appendReference(.{
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
        try self.ensureReferenceIndex();
        const i = self.reference_index.get(@intFromEnum(node)) orelse return error.ReferenceNotFound;
        const ref = &self.references.items[i];
        if (!self.visibleFrom(ref.symbol_id, scope)) return error.InvalidScope;
        ref.scope_id = scope;
        ref.stmt_idx = stmt_idx;
        ref.scope_stmt_idx = scope_stmt_idx;
    }

    /// 제거된 참조의 사용 횟수도 되돌린다. 다른 참조의 순서는 유지한다.
    pub fn removeReference(self: *SemanticEditor, node: NodeIndex) Error!void {
        try self.ensureReferenceIndex();
        const key = @intFromEnum(node);
        const i = self.reference_index.get(key) orelse return error.ReferenceNotFound;
        const ref = self.references.items[i];
        if (!self.validSymbol(ref.symbol_id)) return error.InvalidSymbol;
        self.removeCounts(ref.symbol_id, ref.flags);
        _ = self.references.orderedRemove(i);
        _ = self.reference_index.remove(key);
        for (self.references.items[i..], i..) |moved, new_i| {
            if (!moved.node_index.isNone()) {
                if (self.reference_index.getPtr(@intFromEnum(moved.node_index))) |indexed| indexed.* = new_i;
            }
        }
        if (key < self.symbol_ids.items.len) self.symbol_ids.items[key] = null;
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

test "relocate reference crosses sibling scopes with one final visibility check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);

    const root = try editor.addScope(.none, .none, .module, true);
    const header = try editor.addScope(root, .none, .block, false);
    const generated_fn = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("index");
    const header_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const param_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const header_id = try editor.declare(header_binding, name, Span.EMPTY, header, .variable_let, 1, 0);
    const param_id = try editor.declare(param_binding, name, Span.EMPTY, generated_fn, .parameter, 1, 0);
    try editor.addReference(ref, header_id, header, .{ .read = true, .write = true }, 2, 3);

    try std.testing.expectError(error.InvalidScope, editor.moveReference(ref, generated_fn, 4, 5));
    try std.testing.expectError(error.InvalidScope, editor.rebindReference(ref, param_id));
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(header_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(header_id)].write_count);
    try editor.relocateReference(ref, generated_fn, param_id, 4, 5);

    const ref_i = editor.reference_index.get(@intFromEnum(ref)).?;
    const relocated = editor.references.items[ref_i];
    try std.testing.expectEqual(generated_fn, relocated.scope_id);
    try std.testing.expectEqual(param_id, relocated.symbol_id);
    try std.testing.expectEqual(@as(u32, 4), relocated.stmt_idx);
    try std.testing.expectEqual(@as(u32, 5), relocated.scope_stmt_idx);
    try std.testing.expect(relocated.flags.read and relocated.flags.write);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(param_id)), editor.symbol_ids.items[@intFromEnum(ref)]);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(header_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(header_id)].write_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(param_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(param_id)].write_count);

    try editor.relocateReference(ref, generated_fn, param_id, 4, 5);
    try std.testing.expectEqualDeep(relocated, editor.references.items[ref_i]);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(param_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(param_id)].write_count);
    try editor.removeReference(ref);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(param_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(param_id)].write_count);
    try std.testing.expectEqual(@as(?u32, null), editor.symbol_ids.items[@intFromEnum(ref)]);
    try std.testing.expect(editor.reference_index.get(@intFromEnum(ref)) == null);
}

test "relocate reference after reparenting restores final visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);

    const root = try editor.addScope(.none, .none, .module, true);
    const header = try editor.addScope(root, .none, .block, false);
    const body = try editor.addScope(header, .none, .block, false);
    const generated_fn = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("index");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const param = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const header_id = try editor.declare(binding, name, Span.EMPTY, header, .variable_let, 0, 0);
    const param_id = try editor.declare(param, name, Span.EMPTY, generated_fn, .parameter, 0, 0);
    try editor.addReference(ref, header_id, body, .{ .read = true }, 1, 1);

    try editor.reparentScope(body, generated_fn);
    try std.testing.expectError(error.InvalidScope, editor.finish());
    try editor.relocateReference(ref, body, param_id, Reference.NO_STMT, Reference.NO_STMT);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(?u32, @intFromEnum(param_id)), result.symbol_ids[@intFromEnum(ref)]);
    try std.testing.expectEqual(@as(u32, 0), result.symbols.items[@intFromEnum(header_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), result.symbols.items[@intFromEnum(param_id)].reference_count);
}

test "failed relocation leaves references symbols counts and index intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);

    const root = try editor.addScope(.none, .none, .module, true);
    const left = try editor.addScope(root, .none, .block, false);
    const right = try editor.addScope(root, .none, .function, false);
    const other = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("value");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const right_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const other_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const later = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const missing = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const invalid_node = try ast.addNode(.{ .tag = .null_literal, .span = Span.EMPTY, .data = .{ .none = 0 } });
    const left_id = try editor.declare(binding, name, Span.EMPTY, left, .variable_let, 0, 0);
    const right_id = try editor.declare(right_binding, name, Span.EMPTY, right, .parameter, 0, 0);
    const other_id = try editor.declare(other_binding, name, Span.EMPTY, other, .parameter, 0, 0);
    try editor.addReference(ref, left_id, left, .{ .read = true, .write = true }, 1, 2);
    try editor.addReference(later, left_id, left, .{ .read = true }, 3, 4);
    try editor.ensureReferenceIndex();
    const old_index = editor.reference_index.get(@intFromEnum(ref)).?;
    const before = editor.references.items[old_index];

    try std.testing.expectError(error.InvalidScope, editor.relocateReference(ref, .none, right_id, 8, 9));
    try std.testing.expectError(error.InvalidSymbol, editor.relocateReference(ref, right, .none, 8, 9));
    try std.testing.expectError(error.InvalidScope, editor.relocateReference(ref, right, other_id, 8, 9));
    try std.testing.expectError(error.InvalidNode, editor.relocateReference(binding, right, right_id, 8, 9));
    try std.testing.expectError(error.InvalidNode, editor.relocateReference(invalid_node, right, right_id, 8, 9));
    try std.testing.expectError(error.ReferenceNotFound, editor.relocateReference(missing, right, right_id, 8, 9));
    try std.testing.expectEqualDeep(before, editor.references.items[old_index]);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(left_id)), editor.symbol_ids.items[@intFromEnum(ref)]);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@intFromEnum(left_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(left_id)].write_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(right_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(other_id)].reference_count);
    try std.testing.expectEqual(old_index, editor.reference_index.get(@intFromEnum(ref)).?);

    editor.references.items[old_index].flags = .{ .declare = true };
    try std.testing.expectError(error.InvalidNode, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.references.items[old_index].flags = .{};
    try std.testing.expectError(error.InvalidNode, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.references.items[old_index].flags = before.flags;
    editor.references.items[old_index].scope_id = .none;
    try std.testing.expectError(error.InvalidScope, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.references.items[old_index].scope_id = before.scope_id;
    editor.symbol_ids.items[@intFromEnum(ref)] = @intFromEnum(other_id);
    try std.testing.expectError(error.InvalidSymbol, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.symbol_ids.items[@intFromEnum(ref)] = @intFromEnum(left_id);
    editor.symbols.items[@intFromEnum(right_id)].write_count = std.math.maxInt(u32);
    try std.testing.expectError(error.InvalidSymbol, editor.relocateReference(ref, right, right_id, 8, 9));
    editor.symbols.items[@intFromEnum(right_id)].write_count = 0;
    try std.testing.expectEqualDeep(before, editor.references.items[old_index]);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@intFromEnum(left_id)].reference_count);

    try editor.removeReference(ref);
    const later_i = editor.reference_index.get(@intFromEnum(later)).?;
    try std.testing.expectEqual(later, editor.references.items[later_i].node_index);
    try editor.relocateReference(later, right, right_id, 10, 11);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(right_id)), editor.symbol_ids.items[@intFromEnum(later)]);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(left_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(right_id)].reference_count);
}

test "relocate type references without adding value counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);

    const root = try editor.addScope(.none, .none, .module, true);
    const left = try editor.addScope(root, .none, .block, false);
    const right = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("TypeName");
    const left_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const right_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const type_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const query_ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const left_id = try editor.declare(left_binding, name, Span.EMPTY, left, .variable_let, 0, 0);
    const right_id = try editor.declare(right_binding, name, Span.EMPTY, right, .parameter, 0, 0);
    const type_flags: ReferenceFlags = .{ .read = true, .type_context = true };
    const query_flags: ReferenceFlags = .{ .read = true, .value_as_type = true };
    try editor.addReference(type_ref, left_id, left, type_flags, 1, 2);
    try editor.addReference(query_ref, left_id, left, query_flags, 3, 4);

    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(left_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(left_id)].write_count);
    try editor.relocateReference(type_ref, right, right_id, 5, 6);
    try editor.relocateReference(query_ref, right, right_id, 7, 8);

    const relocated_type = editor.references.items[editor.reference_index.get(@intFromEnum(type_ref)).?];
    const relocated_query = editor.references.items[editor.reference_index.get(@intFromEnum(query_ref)).?];
    try std.testing.expectEqual(right, relocated_type.scope_id);
    try std.testing.expectEqual(right_id, relocated_type.symbol_id);
    try std.testing.expectEqual(@as(u32, 5), relocated_type.stmt_idx);
    try std.testing.expectEqual(@as(u32, 6), relocated_type.scope_stmt_idx);
    try std.testing.expectEqualDeep(type_flags, relocated_type.flags);
    try std.testing.expect(!relocated_type.isValueUse());
    try std.testing.expectEqual(right, relocated_query.scope_id);
    try std.testing.expectEqual(right_id, relocated_query.symbol_id);
    try std.testing.expectEqual(@as(u32, 7), relocated_query.stmt_idx);
    try std.testing.expectEqual(@as(u32, 8), relocated_query.scope_stmt_idx);
    try std.testing.expectEqualDeep(query_flags, relocated_query.flags);
    try std.testing.expect(!relocated_query.isValueUse());
    try std.testing.expectEqual(@as(?u32, @intFromEnum(right_id)), editor.symbol_ids.items[@intFromEnum(type_ref)]);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(right_id)), editor.symbol_ids.items[@intFromEnum(query_ref)]);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(left_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(left_id)].write_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(right_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(right_id)].write_count);
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

test "reparenting a scope requires captured references to be rebound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .global, false);
    const outer = try editor.addScope(root, .none, .block, false);
    const generated_fn = try editor.addScope(root, .none, .function, true);
    const body = try editor.addScope(outer, .none, .block, false);
    const nested = try editor.addScope(body, .none, .function, false);
    const name = try ast.addString("captured");
    const outer_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const param_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const ref = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const outer_id = try editor.declare(outer_binding, name, Span.EMPTY, outer, .variable_let, 0, 0);
    const param_id = try editor.declare(param_binding, name, Span.EMPTY, generated_fn, .parameter, 0, 0);
    try editor.addReference(ref, outer_id, nested, .{ .read = true }, 0, 0);
    editor.scopes.items[body.toIndex()].subtree_has_direct_eval = true;
    editor.scopes.items[body.toIndex()].subtree_has_with = true;
    editor.scopes.items[outer.toIndex()].subtree_has_direct_eval = true;
    editor.scopes.items[outer.toIndex()].subtree_has_with = true;
    try editor.reparentScope(body, generated_fn);
    try std.testing.expectEqual(generated_fn, editor.scopes.items[body.toIndex()].parent);
    try std.testing.expect(editor.scopes.items[body.toIndex()].is_strict);
    try std.testing.expect(editor.scopes.items[nested.toIndex()].is_strict);
    try std.testing.expect(editor.scopes.items[generated_fn.toIndex()].blocksMangling());
    try std.testing.expect(editor.scopes.items[outer.toIndex()].blocksMangling());
    try std.testing.expectError(error.InvalidScope, editor.reparentScope(generated_fn, nested));
    try std.testing.expectError(error.InvalidScope, editor.reparentScope(root, generated_fn));
    try std.testing.expectError(error.InvalidScope, editor.finish());
    try editor.rebindReference(ref, param_id);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(outer_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(param_id)].reference_count);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(?u32, @intFromEnum(param_id)), result.symbol_ids[@intFromEnum(ref)]);
}

test "cloned reference keeps target and write flags without stealing the source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .global, false);
    const sibling = try editor.addScope(root, .none, .function, false);
    const inner = try editor.addScope(sibling, .none, .block, false);
    const name = try ast.addString("value");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const source = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const clone = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const wrong_clone = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    const symbol = try editor.declare(binding, name, Span.EMPTY, sibling, .variable_let, 0, 0);
    try editor.addReference(source, symbol, inner, .{ .read = true, .write = true }, 2, 3);
    editor.symbol_ids.items[try editor.ensureNodeSlot(clone)] = @intFromEnum(symbol);
    editor.symbol_ids.items[try editor.ensureNodeSlot(wrong_clone)] = 999;
    try editor.cloneReference(source, clone, inner, 4, 5);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@intFromEnum(symbol)].reference_count);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@intFromEnum(symbol)].write_count);
    try std.testing.expectError(error.AlreadyBound, editor.cloneReference(source, clone, inner, 4, 5));
    try std.testing.expectError(error.AlreadyBound, editor.cloneReferenceAtSameLocation(source, wrong_clone));
    try std.testing.expectError(error.ReferenceNotFound, editor.cloneReference(binding, clone, inner, 4, 5));
    try std.testing.expectError(error.InvalidScope, editor.cloneReference(source, binding, root, 4, 5));
    try editor.removeReference(source);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(symbol)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(symbol)].write_count);
    const later = try ast.addNode(.{ .tag = .assignment_target_identifier, .span = name, .data = .{ .string_ref = name } });
    try editor.cloneReferenceAtSameLocation(clone, later);
    try std.testing.expectEqual(@as(u32, 2), editor.symbols.items[@intFromEnum(symbol)].reference_count);
    try editor.removeReference(later);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(symbol)].reference_count);
    const result = try editor.finish();
    try std.testing.expectEqual(@as(?u32, null), result.symbol_ids[@intFromEnum(source)]);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(symbol)), result.symbol_ids[@intFromEnum(clone)]);
    try std.testing.expectEqual(@as(u32, 4), result.references[result.references.len - 1].stmt_idx);
    try std.testing.expectEqual(@as(u32, 5), result.references[result.references.len - 1].scope_stmt_idx);
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
