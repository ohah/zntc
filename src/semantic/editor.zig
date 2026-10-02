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

    fn validTextSpan(self: *const SemanticEditor, span: Span) bool {
        const start_is_string = span.start & Ast.STRING_TABLE_BIT != 0;
        const end_is_string = span.end & Ast.STRING_TABLE_BIT != 0;
        if (start_is_string != end_is_string) return false;
        const start: usize = @intCast(span.start & ~Ast.STRING_TABLE_BIT);
        const end: usize = @intCast(span.end & ~Ast.STRING_TABLE_BIT);
        const limit = if (start_is_string) self.ast.string_table.items.len else self.ast.source.len;
        return start <= end and end <= limit;
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

    /// Move an existing binding to its emitted storage scope. The SymbolId and
    /// its references remain unchanged; the caller must also move any source
    /// scopes whose live references now execute beneath the new storage scope.
    pub fn relocateSymbol(self: *SemanticEditor, id: SymbolId, target: ScopeId) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const symbol = &self.symbols.items[@intFromEnum(id)];
        const name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        try self.relocateSymbolWithName(id, target, name, null);
    }

    /// Move and attach an existing binding using its exact emitted name. This
    /// keeps the SymbolId while rekeying the scope map for transforms that
    /// lower distinct same-text bindings into one storage scope with unique
    /// output names.
    pub fn relocateSymbolAs(self: *SemanticEditor, id: SymbolId, target: ScopeId, output_binding: NodeIndex) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        if (!self.validScope(target)) return error.InvalidScope;
        if (output_binding.isNone() or @intFromEnum(output_binding) >= self.ast.nodes.items.len) return error.InvalidNode;
        const node = self.ast.getNode(output_binding);
        if (node.tag != .binding_identifier) return error.InvalidNode;
        const output_name_span = node.data.string_ref;
        if (!self.validTextSpan(output_name_span)) return error.InvalidNode;
        if (self.ast.getText(output_name_span).len == 0) return error.InvalidNode;
        const slot = try self.ensureNodeSlot(output_binding);
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing != @intFromEnum(id)) return error.AlreadyBound;
        }
        const output_name = self.ast.getText(output_name_span);
        const stable_output_name = try self.ast.getTextStable(self.allocator, output_name_span);
        try self.relocateSymbolWithName(id, target, output_name, stable_output_name);
        var has_declaration = false;
        for (self.references.items) |*reference| {
            if (reference.symbol_id != id or !reference.flags.declare) continue;
            reference.scope_id = target;
            has_declaration = true;
        }
        if (!has_declaration) try self.ensureDeclaration(id, target);
        self.symbol_ids.items[slot] = @intFromEnum(id);
    }

    fn relocateSymbolWithName(self: *SemanticEditor, id: SymbolId, target: ScopeId, target_name: []const u8, stable_output_name: ?[]const u8) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        if (!self.validScope(target)) return error.InvalidScope;
        const symbol = &self.symbols.items[@intFromEnum(id)];
        const source = symbol.scope_id;
        if (!self.validScope(source)) return error.InvalidScope;
        const name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        if (source == target and std.mem.eql(u8, name, target_name)) return;
        const source_map = &self.scope_maps.items[source.toIndex()];
        if (source_map.get(name) != @as(?usize, @intFromEnum(id))) return error.InvalidSymbol;
        const target_map = &self.scope_maps.items[target.toIndex()];
        if (target_map.get(target_name)) |existing| {
            if (existing != @intFromEnum(id)) return error.DuplicateBinding;
            if (source != target) return error.DuplicateBinding;
        }
        if (source != target and (self.scopes.items[target.toIndex()].symbol_count == std.math.maxInt(u16) or
            self.scopes.items[source.toIndex()].symbol_count == 0)) return error.InvalidScope;
        // A generated output name can point into Ast.string_table, which may
        // reallocate during later transforms. Store the owned copy when the
        // emitted binding was string-table backed.
        try target_map.put(self.allocator, stable_output_name orelse target_name, @intFromEnum(id));
        _ = source_map.remove(name);
        if (source != target) {
            self.scopes.items[source.toIndex()].symbol_count -= 1;
            self.scopes.items[target.toIndex()].symbol_count += 1;
        }
        if (stable_output_name) |output_name| symbol.synthetic_name = output_name;
        symbol.scope_id = target;
        symbol.origin_scope = target;
        // The declaration record represents the binding site too. When the
        // declaration is moved with its SymbolId, keep that record in the
        // destination scope so finish() can validate the relocated graph.
        for (self.references.items) |*reference| {
            if (reference.symbol_id == id and reference.flags.declare)
                reference.scope_id = target;
        }
        self.scope_reparented = true;
    }

    pub fn attachExistingBinding(self: *SemanticEditor, node: NodeIndex, id: SymbolId) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const slot = try self.ensureNodeSlot(node);
        if (self.ast.getNode(node).tag != .binding_identifier) return error.InvalidNode;
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing == @intFromEnum(id)) return;
            return error.AlreadyBound;
        }
        self.symbol_ids.items[slot] = @intFromEnum(id);
    }

    /// Change the exact identity of an output binding after a lowering splits
    /// one source binding into separate storage and callback bindings.
    pub fn rebindBinding(self: *SemanticEditor, node: NodeIndex, id: SymbolId) Error!void {
        if (!self.validSymbol(id)) return error.InvalidSymbol;
        const slot = try self.ensureNodeSlot(node);
        const binding = self.ast.getNode(node);
        if (binding.tag != .binding_identifier) return error.InvalidNode;
        const symbol = self.symbols.items[@intFromEnum(id)];
        const expected_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
        if (!std.mem.eql(u8, self.ast.getText(binding.data.string_ref), expected_name)) return error.InvalidSymbol;
        self.symbol_ids.items[slot] = @intFromEnum(id);
    }

    /// Give one emitted storage binding a fresh SymbolId while retaining the
    /// source SymbolId for a callback parameter that represents each iteration.
    pub fn splitBindingIdentity(
        self: *SemanticEditor,
        node: NodeIndex,
        expected: SymbolId,
        lexical_scope: ScopeId,
        kind: SymbolKind,
        declaration_span: Span,
    ) Error!SymbolId {
        const slot = try self.ensureNodeSlot(node);
        const binding = self.ast.getNode(node);
        if (binding.tag != .binding_identifier) return error.InvalidNode;
        // A copied output binding can already carry the exact ID in the
        // Transformer's side table while this editor's lazy copy still has an
        // empty slot. Attach that caller-verified identity before splitting.
        if (self.symbol_ids.items[slot]) |existing| {
            if (existing != @intFromEnum(expected)) return error.InvalidSymbol;
        } else {
            self.symbol_ids.items[slot] = @intFromEnum(expected);
        }
        const old_span = binding.data.string_ref;
        const name = self.ast.getText(old_span);
        const target = try self.bindingScope(lexical_scope, kind);
        if (self.scope_maps.items[target.toIndex()].get(name)) |existing_raw| {
            if (existing_raw >= self.symbols.items.len) return error.InvalidSymbol;
            const existing = self.symbols.items[existing_raw];
            const existing_name = if (existing.synthetic_name.len > 0) existing.synthetic_name else self.ast.getText(existing.name);
            // Multiple emitted `var` declarations with the same function
            // scope and name are one JavaScript binding. Preserve that exact
            // runtime identity instead of manufacturing a duplicate map key.
            if (kind == .variable_var and existing.kind == .variable_var and
                existing.scope_id == target and std.mem.eql(u8, existing_name, name))
            {
                const existing_id: SymbolId = @enumFromInt(@as(u32, @intCast(existing_raw)));
                self.symbol_ids.items[slot] = @intFromEnum(existing_id);
                return existing_id;
            }
            // Block function declarations can share one analyzer SymbolId
            // through aliases in sibling lexical scopes. If output emission
            // splits those declarations into distinct block bindings, replace
            // only this alias before declaring the output identity.
            if (existing_raw == @intFromEnum(expected) and existing.scope_id != target) {
                _ = self.scope_maps.items[target.toIndex()].remove(name);
            } else {
                return error.DuplicateBinding;
            }
        }
        const name_span = try self.ast.addString(name);
        self.ast.nodes.items[@intFromEnum(node)].data.string_ref = name_span;
        self.symbol_ids.items[slot] = null;
        return self.declare(node, name_span, declaration_span, lexical_scope, kind, Reference.NO_STMT, Reference.NO_STMT) catch |err| {
            self.ast.nodes.items[@intFromEnum(node)].data.string_ref = old_span;
            self.symbol_ids.items[slot] = @intFromEnum(expected);
            return err;
        };
    }

    pub fn symbolVisibleFrom(self: *const SemanticEditor, symbol: SymbolId, scope: ScopeId) bool {
        return self.visibleFrom(symbol, scope);
    }

    fn requireIdentifier(self: *const SemanticEditor, idx: NodeIndex) Error!void {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) return error.InvalidNode;
        switch (self.ast.getNode(idx).tag) {
            .binding_identifier, .identifier_reference, .assignment_target_identifier, .jsx_identifier => {},
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

    /// Return the single stored reference for this node, building the index on
    /// first use. Transform finalizers use this before relocating live copies.
    pub fn referenceForNode(self: *SemanticEditor, node: NodeIndex) Error!?Reference {
        if (node.isNone()) return null;
        try self.ensureReferenceIndex();
        const index = self.reference_index.get(@intFromEnum(node)) orelse return null;
        return self.references.items[index];
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
            !(old_tag == .for_await_of_statement and new_tag == .while_statement) and
            !(old_tag == .block_statement and new_tag == .while_statement) and
            !(old_tag == .class_declaration and new_tag == .class_expression) and
            !(old_tag == .class_expression and new_tag == .class_declaration) and
            !(old_tag == .function_declaration and new_tag == .function_expression) and
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

    /// Transfer an owner after a controlled in-place rewrite changed the old
    /// node's tag before semantic edits are finalized. The caller must have
    /// recorded this exact replacement; all node, scope, and conflict checks
    /// still apply here.
    pub fn remapScopeOwnerAfterInPlaceRewrite(self: *SemanticEditor, old_owner: NodeIndex, new_owner: NodeIndex) Error!void {
        if (old_owner.isNone() or new_owner.isNone() or
            @intFromEnum(old_owner) >= self.ast.nodes.items.len or
            @intFromEnum(new_owner) >= self.ast.nodes.items.len) return error.InvalidNode;
        const old_key = @intFromEnum(old_owner);
        const new_key = @intFromEnum(new_owner);
        const scope_id = self.scope_owner_map.get(old_key) orelse return error.InvalidScope;
        if (old_key == new_key) return;
        if (self.scope_owner_map.get(new_key)) |existing| {
            if (existing != scope_id) return error.ScopeOwnerConflict;
        } else {
            try self.scope_owner_map.put(self.allocator, new_key, scope_id);
        }
        _ = self.scope_owner_map.remove(old_key);
    }

    /// Remove an empty generated block boundary after a lowering flattens its
    /// owner node out of the output AST. Children keep their own scopes and
    /// are reparented to the removed scope's parent; a scope with bindings or
    /// references cannot be elided.
    pub fn elideEmptyGeneratedScopeOwner(self: *SemanticEditor, owner: NodeIndex) Error!bool {
        if (owner.isNone() or @intFromEnum(owner) >= self.ast.nodes.items.len) return error.InvalidNode;
        const owner_raw = @intFromEnum(owner);
        const scope_raw = self.scope_owner_map.get(owner_raw) orelse return false;
        if (scope_raw >= self.scopes.items.len) return error.InvalidScope;
        const scope_id: ScopeId = @enumFromInt(scope_raw);
        const scope = self.scopes.items[scope_raw];
        if (scope.kind != .block and scope.kind != .switch_block) return false;
        if (scope.parent.isNone() or !self.validScope(scope.parent)) return error.InvalidScope;
        if (scope.symbol_count != 0 or self.scope_maps.items[scope_raw].count() != 0) return false;
        for (self.symbols.items) |symbol| {
            if (symbol.scope_id == scope_id or symbol.origin_scope == scope_id) return false;
        }
        for (self.references.items) |reference| {
            if (reference.scope_id == scope_id) return false;
        }
        var owner_iter = self.scope_owner_map.iterator();
        while (owner_iter.next()) |entry| {
            if (entry.key_ptr.* != owner_raw and entry.value_ptr.* == scope_raw) return false;
        }

        const parent = scope.parent;
        self.scopes.items[parent.toIndex()].subtree_has_direct_eval =
            self.scopes.items[parent.toIndex()].subtree_has_direct_eval or scope.subtree_has_direct_eval;
        self.scopes.items[parent.toIndex()].subtree_has_with =
            self.scopes.items[parent.toIndex()].subtree_has_with or scope.subtree_has_with;
        for (self.scopes.items, 0..) |child, child_index| {
            if (child.parent == scope_id) try self.reparentScope(@enumFromInt(@as(u32, @intCast(child_index))), parent);
        }
        _ = self.scope_owner_map.remove(owner_raw);
        return true;
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

        const was_strict = self.scopes.items[scope.toIndex()].is_strict;
        self.scopes.items[scope.toIndex()].parent = new_parent;
        self.scope_reparented = true;
        const new_strict = self.scopes.items[new_parent.toIndex()].is_strict;
        if (new_strict and !was_strict) {
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

    /// Move one exact binding when lowering replaces its lexical boundary with
    /// a generated boundary that encloses all surviving references.
    pub fn moveSymbolToScope(self: *SemanticEditor, symbol: SymbolId, new_scope: ScopeId) Error!void {
        if (!self.validSymbol(symbol) or !self.validScope(new_scope)) return error.InvalidScope;
        const symbol_index = @intFromEnum(symbol);
        const old_scope = self.symbols.items[symbol_index].scope_id;
        if (old_scope == new_scope) return;
        if (!self.validScope(old_scope)) return error.InvalidScope;
        const name = try self.ast.getTextStable(self.allocator, self.symbols.items[symbol_index].name);
        if (self.scope_maps.items[old_scope.toIndex()].get(name) != symbol_index) return error.InvalidScope;
        if (self.scope_maps.items[new_scope.toIndex()].get(name)) |existing| {
            if (existing != symbol_index) return error.DuplicateBinding;
        } else {
            try self.scope_maps.items[new_scope.toIndex()].put(self.allocator, name, symbol_index);
        }
        _ = self.scope_maps.items[old_scope.toIndex()].remove(name);
        std.debug.assert(self.scopes.items[old_scope.toIndex()].symbol_count > 0);
        self.scopes.items[old_scope.toIndex()].symbol_count -= 1;
        self.scopes.items[new_scope.toIndex()].symbol_count +|= 1;
        self.symbols.items[symbol_index].scope_id = new_scope;
        for (self.references.items) |*reference| {
            if (reference.symbol_id == symbol and reference.flags.declare) reference.scope_id = new_scope;
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
        if (self.scope_maps.items[target.toIndex()].get(name)) |_| {
            return error.DuplicateBinding;
        }
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

    /// 단일 파일 출력의 AST 밖 런타임 helper 선언을 helper 심볼로 등록한다.
    /// 이름은 최종 preamble이 출력할 alias이며, AST 노드 대신 helper_scope_map으로 연결한다.
    pub fn declareRuntimeHelperPreamble(self: *SemanticEditor, name_span: Span, declaration_span: Span, scope: ScopeId) Error!SymbolId {
        if (!self.validScope(scope)) return error.InvalidScope;
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
            .synthetic_kind = .runtime_helper_preamble,
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

    /// Preserve declaration evidence when a transform materializes an AST
    /// binding for a symbol that already exists (for example an export facade).
    /// Declaration rows are node-less by design; the binding node carries the
    /// SymbolId separately.
    pub fn ensureDeclaration(self: *SemanticEditor, symbol: SymbolId, scope: ScopeId) Error!void {
        if (!self.validSymbol(symbol) or !self.validScope(scope)) return error.InvalidScope;
        if (self.symbols.items[@intFromEnum(symbol)].scope_id != scope) return error.InvalidScope;
        for (self.references.items) |reference| {
            if (reference.symbol_id == symbol and reference.flags.declare) return;
        }
        try self.references.append(self.allocator, .{
            .node_index = .none,
            .scope_id = scope,
            .symbol_id = symbol,
            .stmt_idx = Reference.NO_STMT,
            .scope_stmt_idx = Reference.NO_STMT,
            .flags = .{ .declare = true },
        });
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

test "empty flattened block scope elision reparents children and preserves dynamic lookup flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const wrapper_owner = try ast.addNode(.{ .tag = .block_statement, .span = Span.EMPTY, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const wrapper = try editor.addScope(root, wrapper_owner, .block, false);
    const child_owner = try ast.addNode(.{ .tag = .block_statement, .span = Span.EMPTY, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const child = try editor.addScope(wrapper, child_owner, .block, false);
    editor.scopes.items[wrapper.toIndex()].subtree_has_direct_eval = true;
    editor.scopes.items[wrapper.toIndex()].subtree_has_with = true;

    const name = try ast.addString("outer");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const reference = try ast.addNode(.{ .tag = .identifier_reference, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(binding, name, Span.EMPTY, root, .variable_let, 0, 0);
    try editor.addReference(reference, id, child, .{ .read = true }, 0, 0);

    try std.testing.expect(try editor.elideEmptyGeneratedScopeOwner(wrapper_owner));
    try std.testing.expectEqual(@as(?u32, null), editor.scope_owner_map.get(@intFromEnum(wrapper_owner)));
    try std.testing.expectEqual(root, editor.scopes.items[child.toIndex()].parent);
    try std.testing.expect(editor.scopes.items[root.toIndex()].subtree_has_direct_eval);
    try std.testing.expect(editor.scopes.items[root.toIndex()].subtree_has_with);
    _ = try editor.finish();
}

test "empty flattened block scope elision refuses a scope with a local binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const owner = try ast.addNode(.{ .tag = .block_statement, .span = Span.EMPTY, .data = .{ .list = try ast.addNodeList(&.{}) } });
    const scope = try editor.addScope(root, owner, .block, false);
    const name = try ast.addString("local");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    _ = try editor.declare(binding, name, Span.EMPTY, scope, .variable_let, 0, 0);

    try std.testing.expect(!(try editor.elideEmptyGeneratedScopeOwner(owner)));
    try std.testing.expectEqual(@as(?u32, @intFromEnum(scope)), editor.scope_owner_map.get(@intFromEnum(owner)));
}

test "class self storage relocation preserves identity and rejects occupied target atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const source = try editor.addScope(root, .none, .class_body, true);
    const occupied = try editor.addScope(root, .none, .function, true);
    const destination = try editor.addScope(root, .none, .function, true);
    const name = try ast.addString("C");
    const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const duplicate_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const generated_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(source_binding, name, Span.EMPTY, source, .class_decl, 0, 0);
    _ = try editor.declare(duplicate_binding, name, Span.EMPTY, occupied, .function_decl, 0, 0);
    try std.testing.expectError(error.DuplicateBinding, editor.relocateSymbol(id, occupied));
    try std.testing.expectEqual(source, editor.symbols.items[@intFromEnum(id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @intFromEnum(id)), editor.scope_maps.items[source.toIndex()].get("C"));
    try editor.reparentScope(source, destination);
    try editor.relocateSymbol(id, destination);
    try editor.attachExistingBinding(generated_binding, id);
    try editor.attachExistingBinding(generated_binding, id);
    try std.testing.expectEqual(destination, editor.symbols.items[@intFromEnum(id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @intFromEnum(id)), editor.scope_maps.items[destination.toIndex()].get("C"));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[source.toIndex()].get("C"));
    try std.testing.expectEqual(@as(?u32, @intFromEnum(id)), editor.symbol_ids.items[@intFromEnum(generated_binding)]);
    _ = try editor.finish();
}

test "same-text bindings relocate under their exact emitted names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const storage_scope = try editor.addScope(root, .none, .function, false);
    const left_scope = try editor.addScope(storage_scope, .none, .block, false);
    const right_scope = try editor.addScope(storage_scope, .none, .block, false);
    const conflict_scope = try editor.addScope(storage_scope, .none, .block, false);

    const original_name = try ast.addString("_err3");
    const left_source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const right_source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const conflict_source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const left_id = try editor.declare(left_source_binding, original_name, Span.EMPTY, left_scope, .variable_let, 0, 0);
    const right_id = try editor.declare(right_source_binding, original_name, Span.EMPTY, right_scope, .variable_let, 1, 0);
    const conflict_id = try editor.declare(conflict_source_binding, original_name, Span.EMPTY, conflict_scope, .variable_let, 2, 0);
    try std.testing.expect(left_id != right_id and right_id != conflict_id and left_id != conflict_id);

    const left_name = try ast.addString("_err3$4");
    const right_name = try ast.addString("_err3$6");
    const left_output = try ast.addNode(.{ .tag = .binding_identifier, .span = left_name, .data = .{ .string_ref = left_name } });
    const right_output = try ast.addNode(.{ .tag = .binding_identifier, .span = right_name, .data = .{ .string_ref = right_name } });
    editor.references.clearRetainingCapacity(); // model a lowering that removed the source declaration row
    try editor.relocateSymbolAs(left_id, storage_scope, left_output);
    try editor.relocateSymbolAs(right_id, storage_scope, right_output);

    // Force the AST string table to move after relocation. Scope-map keys must
    // remain valid even though the output binding spans still use table offsets.
    for (0..1024) |_| _ = try ast.addString("_relocation_growth");

    try std.testing.expectEqual(@as(?usize, @intFromEnum(left_id)), editor.scope_maps.items[storage_scope.toIndex()].get("_err3$4"));
    try std.testing.expectEqual(@as(?usize, @intFromEnum(right_id)), editor.scope_maps.items[storage_scope.toIndex()].get("_err3$6"));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[left_scope.toIndex()].get("_err3"));
    try std.testing.expectEqualStrings("_err3$4", editor.symbols.items[@intFromEnum(left_id)].nameText(ast.source));
    try std.testing.expectEqualStrings("_err3$6", editor.symbols.items[@intFromEnum(right_id)].nameText(ast.source));
    try std.testing.expectEqual(@as(?u32, @intFromEnum(left_id)), editor.symbol_ids.items[@intFromEnum(left_output)]);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(right_id)), editor.symbol_ids.items[@intFromEnum(right_output)]);
    try std.testing.expectEqual(@as(usize, 2), editor.references.items.len);
    for (editor.references.items) |reference| {
        try std.testing.expect(reference.flags.declare and reference.node_index.isNone());
        try std.testing.expectEqual(storage_scope, reference.scope_id);
    }

    const conflict_output = try ast.addNode(.{ .tag = .binding_identifier, .span = left_name, .data = .{ .string_ref = left_name } });
    try std.testing.expectError(error.DuplicateBinding, editor.relocateSymbolAs(conflict_id, storage_scope, conflict_output));
    try std.testing.expectEqual(conflict_scope, editor.symbols.items[@intFromEnum(conflict_id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @intFromEnum(conflict_id)), editor.scope_maps.items[conflict_scope.toIndex()].get("_err3"));
    try std.testing.expectEqual(@as(?usize, @intFromEnum(left_id)), editor.scope_maps.items[storage_scope.toIndex()].get("_err3$4"));
    try std.testing.expectEqual(@as(u16, 2), editor.scopes.items[storage_scope.toIndex()].symbol_count);
    _ = try editor.finish();
}

test "relocateSymbolAs moves declaration reference with emitted binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "x");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .module, true);
    const source_scope = try editor.addScope(root, .none, .block, false);
    const target_scope = try editor.addScope(root, .none, .function, false);
    const original_name = try ast.addString("original");
    const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const source_name_span = Span{ .start = 0, .end = 1 };
    const output_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = source_name_span, .data = .{ .string_ref = source_name_span } });
    const id = try editor.declare(source_binding, original_name, Span.EMPTY, source_scope, .variable_let, 0, 0);

    try editor.relocateSymbolAs(id, target_scope, output_binding);

    try std.testing.expectEqual(target_scope, editor.symbols.items[@intFromEnum(id)].scope_id);
    try std.testing.expectEqual(target_scope, editor.references.items[0].scope_id);
    try std.testing.expectEqualStrings("x", editor.symbols.items[@intFromEnum(id)].synthetic_name);
    try std.testing.expectEqual(@as(?usize, @intFromEnum(id)), editor.scope_maps.items[target_scope.toIndex()].get("x"));
    try std.testing.expectEqual(@as(?u32, @intFromEnum(id)), editor.symbol_ids.items[@intFromEnum(output_binding)]);
    _ = try editor.finish();
}

test "relocateSymbolAs rejects invalid emitted name spans without changing bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "x");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .module, true);
    const target_scope = try editor.addScope(root, .none, .function, false);
    const source_scope = try editor.addScope(target_scope, .none, .block, false);
    const original_name = try ast.addString("original");
    const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = original_name, .data = .{ .string_ref = original_name } });
    const id = try editor.declare(source_binding, original_name, Span.EMPTY, source_scope, .variable_let, 0, 0);

    const invalid_spans = [_]Span{
        .{ .start = 0, .end = 2 },
        .{ .start = 0, .end = 0 },
        .{ .start = Ast.STRING_TABLE_BIT, .end = 1 },
    };
    for (invalid_spans) |invalid_span| {
        const output_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = invalid_span, .data = .{ .string_ref = invalid_span } });
        const prior_symbol_id_len = editor.symbol_ids.items.len;
        try std.testing.expectError(error.InvalidNode, editor.relocateSymbolAs(id, target_scope, output_binding));
        try std.testing.expectEqual(prior_symbol_id_len, editor.symbol_ids.items.len);
    }

    try std.testing.expectEqual(source_scope, editor.symbols.items[@intFromEnum(id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @intFromEnum(id)), editor.scope_maps.items[source_scope.toIndex()].get("original"));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[target_scope.toIndex()].get("x"));
    _ = try editor.finish();
}

test "splitBindingIdentity reuses a same-scope var declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const function_scope = try editor.addScope(root, .none, .function, false);
    const block_scope = try editor.addScope(function_scope, .none, .block, false);
    const name = try ast.addString("_d");
    const existing_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const source_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const output_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const existing_id = try editor.declare(existing_binding, name, Span.EMPTY, function_scope, .variable_var, 0, 0);
    const source_id = try editor.declare(source_binding, name, Span.EMPTY, block_scope, .variable_const, 1, 0);

    const split_id = try editor.splitBindingIdentity(output_binding, source_id, block_scope, .variable_var, Span.EMPTY);

    try std.testing.expectEqual(existing_id, split_id);
    try std.testing.expectEqual(@as(?u32, @intFromEnum(existing_id)), editor.symbol_ids.items[@intFromEnum(output_binding)]);
    try std.testing.expectEqual(@as(?usize, @intFromEnum(existing_id)), editor.scope_maps.items[function_scope.toIndex()].get("_d"));
    try std.testing.expectEqual(function_scope, editor.symbols.items[@intFromEnum(existing_id)].scope_id);
    _ = try editor.finish();
}

test "relocateSymbolAs accepts a source-backed emitted binding name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "_err3$4");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();
    const root = try editor.addScope(.none, .none, .module, true);
    const source_scope = try editor.addScope(root, .none, .block, false);
    const storage_scope = try editor.addScope(root, .none, .function, false);
    const source_name = try ast.addString("_err3");
    const source_binding = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = source_name,
        .data = .{ .string_ref = source_name },
    });
    const id = try editor.declare(source_binding, source_name, Span.EMPTY, source_scope, .variable_let, 0, 0);
    const output_name: Span = .{ .start = 0, .end = 7 };
    const output_binding = try ast.addNode(.{
        .tag = .binding_identifier,
        .span = output_name,
        .data = .{ .string_ref = output_name },
    });

    try editor.relocateSymbolAs(id, storage_scope, output_binding);

    try std.testing.expectEqual(storage_scope, editor.symbols.items[@intFromEnum(id)].scope_id);
    try std.testing.expectEqual(@as(?usize, @intFromEnum(id)), editor.scope_maps.items[storage_scope.toIndex()].get("_err3$4"));
    try std.testing.expectEqual(@as(?usize, null), editor.scope_maps.items[source_scope.toIndex()].get("_err3"));
    try std.testing.expectEqual(@as(?u32, @intFromEnum(id)), editor.symbol_ids.items[@intFromEnum(output_binding)]);
    try std.testing.expectEqualStrings("_err3$4", editor.symbols.items[@intFromEnum(id)].nameText(ast.source));
    _ = try editor.finish();
}

test "existing facade symbols receive one declaration row when lowered to bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .module, true);
    const name = try ast.addString("_default");
    const binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const id = try editor.declare(binding, name, Span.EMPTY, root, .variable_const, Reference.NO_STMT, Reference.NO_STMT);
    editor.references.clearRetainingCapacity(); // analyzer facade without stmt-info declaration evidence

    try editor.ensureDeclaration(id, root);
    try editor.ensureDeclaration(id, root);
    try std.testing.expectEqual(@as(usize, 1), editor.references.items.len);
    try std.testing.expect(editor.references.items[0].node_index.isNone());
    try std.testing.expectEqual(id, editor.references.items[0].symbol_id);
    try std.testing.expect(editor.references.items[0].flags.declare);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(id)].reference_count);
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

test "JSX identifier references can be rebound and relocated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ast = Ast.init(allocator, "");
    defer ast.deinit();
    var editor = try SemanticEditor.init(allocator, &ast, &.{}, &.{}, &.{}, .empty, &.{}, &.{}, .empty);
    defer editor.deinit();

    const root = try editor.addScope(.none, .none, .module, true);
    const child = try editor.addScope(root, .none, .function, false);
    const name = try ast.addString("Component");
    const renamed_name = try ast.addString("RenamedComponent");
    const first_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = name, .data = .{ .string_ref = name } });
    const second_binding = try ast.addNode(.{ .tag = .binding_identifier, .span = renamed_name, .data = .{ .string_ref = renamed_name } });
    const jsx_ref = try ast.addNode(.{ .tag = .jsx_identifier, .span = name, .data = .{ .string_ref = name } });
    const first_id = try editor.declare(first_binding, name, Span.EMPTY, root, .variable_let, 0, 0);
    const second_id = try editor.declare(second_binding, renamed_name, Span.EMPTY, root, .variable_const, 1, 0);
    try editor.addReference(jsx_ref, first_id, root, .{ .read = true }, 2, 0);

    try editor.rebindReference(jsx_ref, second_id);
    try editor.relocateReference(jsx_ref, child, second_id, 3, 1);

    const reference = (try editor.referenceForNode(jsx_ref)).?;
    try std.testing.expectEqual(child, reference.scope_id);
    try std.testing.expectEqual(second_id, reference.symbol_id);
    try std.testing.expectEqual(@as(u32, 0), editor.symbols.items[@intFromEnum(first_id)].reference_count);
    try std.testing.expectEqual(@as(u32, 1), editor.symbols.items[@intFromEnum(second_id)].reference_count);
    _ = try editor.finish();
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
