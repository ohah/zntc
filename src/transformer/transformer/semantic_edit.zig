//! 변환 중 합성 바인딩과 참조를 원래 semantic SymbolId 공간에 추가한다 (#4819).
const std = @import("std");
const Transformer = @import("../transformer.zig").Transformer;
const NodeIndex = @import("../../parser/ast.zig").NodeIndex;
const Span = @import("../../lexer/token.zig").Span;
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
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

fn declareSynthetic(self: *Transformer, binding: NodeIndex, declaration_span: Span, kind: SymbolKind) Transformer.Error!?SymbolId {
    if (!self.semantic_edit_enabled) return null;
    const editor = try editorFor(self);
    const name_span = self.ast.getNode(binding).data.string_ref;
    const id = editor.declare(
        binding,
        name_span,
        declaration_span,
        self.current_scope,
        kind,
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
    try setSymbolId(self, binding, id);
    return id;
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
    const symbol = id orelse return;
    const editor = try editorFor(self);
    editor.addReference(
        node,
        symbol,
        self.current_scope,
        .{ .read = true },
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
    try setSymbolId(self, node, symbol);
}

/// nullish lowering의 temp 참조는 hoist 선언보다 먼저 생성된다. 이름 대신
/// makeTempVarSpan의 고유 Span을 기록하고 선언 시점에 SymbolId를 연결한다.
pub fn trackHoistedTempRef(self: *Transformer, name_span: Span, node: NodeIndex, flags: ReferenceFlags) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.current_scope.isNone()) return;
    // 이 단계에서 hoist 바인딩을 편집하는 곳은 program뿐이다. 함수 안의 참조를
    // 불필요하게 큐에 쌓거나 최상위 바인딩에 연결하지 않는다.
    const root_scope = self.scope_owner_map.get(self.parser_node_count - 1) orelse return;
    var var_scope = self.current_scope;
    while (!var_scope.isNone() and !self.scopes[var_scope.toIndex()].kind.isVarScope()) {
        var_scope = self.scopes[var_scope.toIndex()].parent;
    }
    if (var_scope.isNone() or var_scope.toIndex() != root_scope) return;
    try self.pending_temp_refs.append(self.allocator, .{
        .name_start = name_span.start,
        .node = node,
        .scope = self.current_scope,
        .flags = flags,
    });
}

/// program-level 호이스트가 만든 바인딩에 앞서 기록한 참조를 연결한다.
/// generated function scope 등록 전에는 program 경로에서만 호출한다.
pub fn bindHoistedTemp(self: *Transformer, binding: NodeIndex, name_span: Span, declaration_span: Span) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    var has_refs = false;
    for (self.pending_temp_refs.items) |ref| {
        if (ref.name_start == name_span.start) {
            has_refs = true;
            break;
        }
    }
    if (!has_refs) return;

    const root_idx = self.parser_node_count - 1;
    const root_scope: @import("../../semantic/scope.zig").ScopeId = @enumFromInt(
        self.scope_owner_map.get(root_idx) orelse std.debug.panic("missing program scope for hoisted temp", .{}),
    );
    const editor = try editorFor(self);
    const id = editor.declare(
        binding,
        name_span,
        declaration_span,
        root_scope,
        .variable_var,
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
    try setSymbolId(self, binding, id);
    var i: usize = 0;
    while (i < self.pending_temp_refs.items.len) {
        const ref = self.pending_temp_refs.items[i];
        if (ref.name_start != name_span.start) {
            i += 1;
            continue;
        }
        editor.addReference(ref.node, id, ref.scope, ref.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        try setSymbolId(self, ref.node, id);
        _ = self.pending_temp_refs.swapRemove(i);
    }
}

/// 변환 중 복사된 사용자 식별자와 scope owner도 편집 결과에 합친다.
pub fn finishSemanticEdit(self: *Transformer) Transformer.Error!?SemanticEditor.Result {
    const editor = if (self.semantic_editor) |*e| e else return null;
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
