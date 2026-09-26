//! 변환 중 합성 바인딩과 참조를 원래 semantic SymbolId 공간에 추가한다 (#4819).
const std = @import("std");
const Transformer = @import("../transformer.zig").Transformer;
const NodeIndex = @import("../../parser/ast.zig").NodeIndex;
const Span = @import("../../lexer/token.zig").Span;
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const Reference = @import("../../semantic/symbol.zig").Reference;
const ReferenceFlags = @import("../../semantic/symbol.zig").ReferenceFlags;
const SemanticEditor = @import("../../semantic/editor.zig").SemanticEditor;
const EditorError = @import("../../semantic/editor.zig").Error;

fn editError(err: EditorError) Transformer.Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    std.debug.panic("invalid transform semantic edit: {s}", .{@errorName(err)});
}

fn editorFor(self: *Transformer) Transformer.Error!*SemanticEditor {
    if (self.scopes.len == 0 or self.symbol_ids.items.len == 0)
        std.debug.panic("missing transform semantic scope", .{});
    if (self.semantic_editor == null) {
        self.semantic_editor = SemanticEditor.init(
            self.allocator,
            self.ast,
            self.symbols,
            self.scopes,
            self.scope_maps,
            self.scope_owner_map,
            self.references,
            self.symbol_ids.items,
            self.helper_scope_map,
        ) catch |err| return editError(err);
    }
    return &self.semantic_editor.?;
}

fn setSymbolId(self: *Transformer, node: NodeIndex, id: SymbolId) Transformer.Error!void {
    const index = @intFromEnum(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    if (self.symbol_ids.items[index] != null) std.debug.panic("generated identifier already has a symbol", .{});
    self.symbol_ids.items[index] = @intFromEnum(id);
}

pub fn programScope(self: *Transformer) ScopeId {
    return @enumFromInt(self.scope_owner_map.get(self.parser_node_count - 1) orelse
        std.debug.panic("missing program scope for generated declaration", .{}));
}

/// AST 생성 시점의 current_scope와 실제 삽입 위치가 다를 때 명시한 스코프에 등록한다.
pub fn addGeneratedFunctionScope(self: *Transformer, parent: ScopeId, owner: NodeIndex) Transformer.Error!ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const editor = try editorFor(self);
    return editor.addScope(parent, owner, .function, false) catch |err| return editError(err);
}

pub fn declareSyntheticInScope(self: *Transformer, binding: NodeIndex, declaration_span: Span, kind: SymbolKind, scope: ScopeId) Transformer.Error!?SymbolId {
    if (!self.semantic_edit_enabled) return null;
    const editor = try editorFor(self);
    const name_span = self.ast.getNode(binding).data.string_ref;
    const id = editor.declare(
        binding,
        name_span,
        declaration_span,
        scope,
        kind,
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
    try setSymbolId(self, binding, id);
    return id;
}

fn declareSynthetic(self: *Transformer, binding: NodeIndex, declaration_span: Span, kind: SymbolKind) Transformer.Error!?SymbolId {
    return declareSyntheticInScope(self, binding, declaration_span, kind, self.current_scope);
}

/// `var` 합성 선언을 현재 어휘 스코프에서 생성한다. SymbolId는 추가만 한다.
pub fn declareSyntheticVar(self: *Transformer, binding: NodeIndex, declaration_span: Span) Transformer.Error!?SymbolId {
    return declareSynthetic(self, binding, declaration_span, .variable_var);
}

/// `catch {}` lowering이 만든 미사용 파라미터를 catch 스코프에 등록한다.
pub fn declareSyntheticCatch(self: *Transformer, binding: NodeIndex, declaration_span: Span) Transformer.Error!void {
    _ = try declareSynthetic(self, binding, declaration_span, .catch_binding);
}

/// 생성자가 받은 SymbolId를 그대로 참조에 연결한다. 이름 재검색은 하지 않는다.
pub fn addSyntheticRef(self: *Transformer, node: NodeIndex, id: ?SymbolId) Transformer.Error!void {
    return addSyntheticRefInScope(self, node, id, self.current_scope, .{ .read = true });
}

pub fn addSyntheticRefInScope(self: *Transformer, node: NodeIndex, id: ?SymbolId, scope: ScopeId, flags: ReferenceFlags) Transformer.Error!void {
    const symbol = id orelse return;
    const editor = try editorFor(self);
    editor.addReference(
        node,
        symbol,
        scope,
        flags,
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
    try setSymbolId(self, node, symbol);
}

/// 헬퍼 호출은 import 선언보다 먼저 생성된다. marker가 있는 노드만 보류한다.
pub fn trackRuntimeHelperRef(self: *Transformer, node: NodeIndex, local_name: []const u8) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (self.current_scope.isNone()) std.debug.panic("runtime helper {s} created without scope", .{local_name});
    const index = self.pending_runtime_helper_refs.items.len;
    try self.pending_runtime_helper_refs.append(self.allocator, .{ .node = node, .scope = self.current_scope });
    if (self.pending_runtime_helper_chains.getPtr(local_name)) |chain| {
        self.pending_runtime_helper_refs.items[chain.last].next = index;
        chain.last = index;
    } else {
        try self.pending_runtime_helper_chains.put(self.allocator, local_name, .{ .first = index, .last = index });
    }
}

/// import specifier의 local 노드에 격리된 심볼을 만들고 앞서 생성한 호출을 연결한다.
pub fn bindRuntimeHelperImport(self: *Transformer, local: NodeIndex, local_name: []const u8, declaration_span: Span) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    const id = editor.declareHelperImport(local, self.ast.getNode(local).data.string_ref, declaration_span, self.programScope()) catch |err| return editError(err);
    try setSymbolId(self, local, id);
    const chain = self.pending_runtime_helper_chains.fetchRemove(local_name) orelse return;
    var i: ?usize = chain.value.first;
    while (i) |index| {
        const ref = self.pending_runtime_helper_refs.items[index];
        editor.addReference(ref.node, id, ref.scope, .{ .read = true }, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        try setSymbolId(self, ref.node, id);
        i = ref.next;
    }
    if (self.pending_runtime_helper_chains.count() == 0) self.pending_runtime_helper_refs.clearRetainingCapacity();
}

/// nullish lowering의 temp 참조는 hoist 선언보다 먼저 생성된다. 이름 대신
/// makeTempVarSpan의 고유 Span을 기록하고 선언 시점에 SymbolId를 연결한다.
pub fn trackHoistedTempRef(self: *Transformer, name_span: Span, node: NodeIndex, flags: ReferenceFlags) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.current_scope.isNone()) return;
    const index = self.pending_temp_refs.items.len;
    try self.pending_temp_refs.append(self.allocator, .{
        .name_start = name_span.start,
        .node = node,
        .scope = self.current_scope,
        .flags = flags,
    });
    if (self.pending_temp_ref_chains.getPtr(name_span.start)) |chain| {
        self.pending_temp_refs.items[chain.last].next = index;
        chain.last = index;
    } else {
        try self.pending_temp_ref_chains.put(self.allocator, name_span.start, .{ .first = index, .last = index });
    }
}

/// 원본 프로그램·함수의 호이스트 바인딩에 앞서 기록한 참조를 연결한다.
/// 새로 만든 함수에는 scope 등록 전이므로 호출하지 않는다.
pub fn bindHoistedTemp(self: *Transformer, binding: NodeIndex, name_span: Span, declaration_span: Span, binding_scope: @import("../../semantic/scope.zig").ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const chain = self.pending_temp_ref_chains.fetchRemove(name_span.start) orelse return;

    const target_scope = if (binding_scope.isNone())
        @as(@import("../../semantic/scope.zig").ScopeId, @enumFromInt(
            self.scope_owner_map.get(self.parser_node_count - 1) orelse std.debug.panic("missing program scope for hoisted temp", .{}),
        ))
    else
        binding_scope;
    const editor = try editorFor(self);
    const id = editor.declare(
        binding,
        name_span,
        declaration_span,
        target_scope,
        .variable_var,
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
    try setSymbolId(self, binding, id);
    var i: ?usize = chain.value.first;
    while (i) |index| {
        const ref = self.pending_temp_refs.items[index];
        std.debug.assert(ref.name_start == name_span.start);
        editor.addReference(ref.node, id, ref.scope, ref.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        try setSymbolId(self, ref.node, id);
        i = ref.next;
    }
    if (self.pending_temp_ref_chains.count() == 0) self.pending_temp_refs.clearRetainingCapacity();
}

/// 변환 중 복사된 사용자 식별자와 scope owner도 편집 결과에 합친다.
pub fn finishSemanticEdit(self: *Transformer) Transformer.Error!?SemanticEditor.Result {
    const editor = if (self.semantic_editor) |*e| e else return null;
    if (self.options.emit_runtime_helper_imports and self.pending_runtime_helper_chains.count() != 0)
        std.debug.panic("generated runtime helper reference has no import", .{});
    var remaps = self.scope_owner_remaps.iterator();
    while (remaps.next()) |entry| {
        editor.remapScopeOwner(@enumFromInt(entry.key_ptr.*), @enumFromInt(entry.value_ptr.*)) catch |err| return editError(err);
    }
    if (editor.symbol_ids.items.len < self.symbol_ids.items.len) {
        try editor.symbol_ids.appendNTimes(self.allocator, null, self.symbol_ids.items.len - editor.symbol_ids.items.len);
    }
    for (self.symbol_ids.items, 0..) |maybe_id, i| {
        const id = maybe_id orelse continue;
        if (editor.symbol_ids.items[i]) |existing| {
            if (existing != id) std.debug.panic("generated symbol changed during transform", .{});
        } else editor.symbol_ids.items[i] = id;
    }
    const result = editor.finish() catch |err| return editError(err);
    editor.deinit();
    self.semantic_editor = null;
    return result;
}
