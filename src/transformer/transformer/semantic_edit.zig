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
const LexicalCaptureKind = @import("../transformer.zig").LexicalCaptureKind;

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

/// Bind the generated ES5 constructor to the source class's exact inner name.
/// The outer declaration keeps its own SymbolId. Returns false only when the
/// exact analyzer source was anonymous and this name was generated later.
pub fn bindClassSelfStorage(self: *Transformer, source_class: NodeIndex, binding: NodeIndex, storage_scope: ScopeId) Transformer.Error!bool {
    // Bare Transformer callers can intentionally omit semantic analysis.
    if (self.symbol_ids.items.len == 0) {
        if (self.semantic_edit_enabled) std.debug.panic("class self edit has no semantic input", .{});
        return false;
    }
    const raw = @intFromEnum(source_class);
    if (self.generated_class_without_source_anchor.contains(raw)) {
        if (self.semantic_edit_enabled)
            std.debug.panic("generated worklet class needs a fresh self scope and SymbolId", .{});
        return false;
    }
    const origin = self.scope_owner_origins.get(raw) orelse if (raw < self.parser_node_count) raw else std.debug.panic("generated class has no exact source owner", .{});
    const inner_raw = self.class_self_symbol_map.get(origin) orelse {
        const source_node = self.ast.getNode(@enumFromInt(origin));
        const source_name = self.ast.extra_data.items[source_node.data.extra + @import("../../parser/ast.zig").ClassExtra.name];
        if (source_name == @intFromEnum(NodeIndex.none)) return false;
        std.debug.panic("named source class has no inner self SymbolId", .{});
    };
    const inner: SymbolId = @enumFromInt(inner_raw);
    if (self.getSymbolIdAt(binding)) |existing| {
        if (existing != inner_raw) std.debug.panic("generated class self binding changed SymbolId", .{});
    }
    if (!self.semantic_edit_enabled) {
        if (self.getSymbolIdAt(binding) == null) try setSymbolId(self, binding, inner);
        return true;
    }
    const editor = try editorFor(self);
    editor.relocateSymbol(inner, storage_scope) catch |err| return editError(err);
    editor.attachExistingBinding(binding, inner) catch |err| return editError(err);
    if (self.getSymbolIdAt(binding) == null) try setSymbolId(self, binding, inner);
    return true;
}

pub fn programScope(self: *Transformer) ScopeId {
    return @enumFromInt(self.scope_owner_map.get(self.parser_node_count - 1) orelse
        std.debug.panic("missing program scope for generated declaration", .{}));
}

/// The original function or method node, not the transform traversal cursor,
/// determines where a state machine's generated functions live.
pub fn originalFunctionScope(self: *Transformer, owner: NodeIndex) ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const raw = @intFromEnum(owner);
    if (self.transformed_scope_owner_map.get(raw) orelse self.scope_owner_map.get(raw)) |scope| {
        const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
        if (scope >= scopes.len or scopes[scope].kind != .function)
            std.debug.panic("state machine owner {d} has no function scope", .{raw});
        return @enumFromInt(scope);
    }
    // This exact owner was produced by generator loop extraction before the
    // enclosing state-machine callback exists. Its complete function/parameter
    // migration will establish the true parent. No other missing owner may be
    // silently treated as a generated loop.
    if (self.deferred_generator_loop_owners.contains(raw)) return .none;
    std.debug.panic("missing source function scope for state machine", .{});
}

/// Register one state machine callback and its exact pending `_state` uses.
pub fn bindGeneratedState(self: *Transformer, parent: ScopeId, source_scope: ScopeId, callback: NodeIndex, parameter: NodeIndex, ref_start: usize, callback_temps: []const @import("lists.zig").HoistedStateTemp, span: Span) Transformer.Error!void {
    if (ref_start > self.generator_state_refs.items.len) std.debug.panic("invalid state machine frame", .{});
    if (self.semantic_edit_enabled and !parent.isNone()) {
        const scope = try addGeneratedFunctionScope(self, parent, callback);
        const symbol = try declareSyntheticInScope(self, parameter, span, .parameter, scope);
        // Operation lowering can create an expression and then discard it.
        // Only references actually contained in this callback count as uses.
        var pending: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer pending.deinit(self.allocator);
        for (self.generator_state_refs.items[ref_start..]) |ref| try pending.put(self.allocator, @intFromEnum(ref), {});
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(self.allocator);
        var stack: std.ArrayList(NodeIndex) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, callback);
        while (stack.pop()) |node| {
            if (node.isNone() or @intFromEnum(node) >= self.ast.nodes.items.len) continue;
            const raw = @intFromEnum(node);
            if (seen.contains(raw)) continue;
            try seen.put(self.allocator, raw, {});
            if (pending.contains(raw)) try addSyntheticRefInScope(self, node, symbol, scope, .{ .read = true });
            var it = @import("../../parser/ast_walk.zig").children(self.ast, self.ast.getNode(node));
            while (it.next()) |child| try stack.append(self.allocator, child);
        }
        var live_scopes = try liveScopeOwners(self, &seen);
        defer live_scopes.deinit(self.allocator);
        for (callback_temps) |temp| {
            try bindStateCallbackTemp(self, temp, span, source_scope, scope, &seen, &live_scopes);
        }
    }
    self.generator_state_refs.shrinkRetainingCapacity(ref_start);
}

/// Bind only the exact temp declarations emitted into this callback. The
/// producer records their NodeIndex while hoisting, so no identifier-name
/// lookup or scan of unrelated pending temps is needed.
fn liveScopeOwners(self: *Transformer, live: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!std.AutoHashMapUnmanaged(u32, void) {
    var scopes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var it = live.iterator();
    while (it.next()) |entry| {
        const node = entry.key_ptr.*;
        if (self.transformed_scope_owner_map.get(node) orelse self.scope_owner_map.get(node)) |scope|
            try scopes.put(self.allocator, scope, {});
    }
    return scopes;
}

fn scopeWithin(scopes: []const @import("../../semantic/scope.zig").Scope, scope: ScopeId, ancestor: ScopeId) bool {
    var cursor = scope;
    var hops: usize = 0;
    while (!cursor.isNone() and hops < scopes.len) : (hops += 1) {
        if (cursor == ancestor) return true;
        cursor = scopes[cursor.toIndex()].parent;
    }
    return false;
}

fn generatedTempRefScope(self: *Transformer, source_scope: ScopeId, target_scope: ScopeId, old_scope: ScopeId, live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!ScopeId {
    const editor = try editorFor(self);
    if (old_scope == source_scope) return target_scope;
    if (scopeWithin(editor.scopes.items, old_scope, target_scope)) return old_scope;
    if (!scopeWithin(editor.scopes.items, old_scope, source_scope))
        std.debug.panic("generated temp reference has unrelated source scope", .{});

    // The state machine can flatten a source block away. A live copied block or
    // nested function keeps its entire source ancestor chain. A removed loop
    // owner can still carry a header binding used by a live descendant, so
    // moving only the live descendant would disconnect that binding. Move
    // the first child of the source function when any scope in that chain is
    // live; a fully erased chain makes the reference callback-local.
    var cursor = old_scope;
    var frontier: ScopeId = .none;
    var has_live_scope = false;
    while (cursor != source_scope) {
        has_live_scope = has_live_scope or live_scopes.contains(@intFromEnum(cursor));
        frontier = cursor;
        cursor = editor.scopes.items[cursor.toIndex()].parent;
    }
    if (!has_live_scope) return target_scope;
    editor.reparentScope(frontier, target_scope) catch |err| return editError(err);
    return old_scope;
}

fn bindStateCallbackTemp(self: *Transformer, temp: @import("lists.zig").HoistedStateTemp, declaration_span: Span, source_scope: ScopeId, callback_scope: ScopeId, live: *const std.AutoHashMapUnmanaged(u32, void), live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!void {
    const chain = self.pending_temp_ref_chains.fetchRemove(temp.name_span.start);
    const editor = try editorFor(self);
    const id = editor.declare(temp.binding, temp.name_span, declaration_span, callback_scope, .variable_var, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
    try setSymbolId(self, temp.binding, id);
    var i: ?usize = if (chain) |found| found.value.first else null;
    while (i) |index| {
        const ref = self.pending_temp_refs.items[index];
        std.debug.assert(ref.name_start == temp.name_span.start);
        if (live.contains(@intFromEnum(ref.node))) {
            const scope = try generatedTempRefScope(self, source_scope, callback_scope, ref.scope, live_scopes);
            editor.addReference(ref.node, id, scope, ref.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
            try setSymbolId(self, ref.node, id);
        }
        i = ref.next;
    }
    if (self.pending_temp_ref_chains.count() == 0) self.pending_temp_refs.clearRetainingCapacity();
}

pub fn bindGeneratedFunctionTemps(self: *Transformer, source_scope: ScopeId, function_scope: ScopeId, body: NodeIndex, temps: []const @import("lists.zig").HoistedStateTemp, span: Span) Transformer.Error!void {
    if (!self.semantic_edit_enabled or function_scope.isNone()) return;
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, body);
    while (stack.pop()) |node| {
        if (node.isNone() or @intFromEnum(node) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(node);
        if (live.contains(raw)) continue;
        try live.put(self.allocator, raw, {});
        var it = @import("../../parser/ast_walk.zig").children(self.ast, self.ast.getNode(node));
        while (it.next()) |child| try stack.append(self.allocator, child);
    }
    var live_scopes = try liveScopeOwners(self, &live);
    defer live_scopes.deinit(self.allocator);
    for (temps) |temp| try bindStateCallbackTemp(self, temp, span, source_scope, function_scope, &live, &live_scopes);
}

/// AST 생성 시점의 current_scope와 실제 삽입 위치가 다를 때 명시한 스코프에 등록한다.
pub fn addGeneratedFunctionScope(self: *Transformer, parent: ScopeId, owner: NodeIndex) Transformer.Error!ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const editor = try editorFor(self);
    const scope = editor.addScope(parent, owner, .function, false) catch |err| return editError(err);
    const key = @intFromEnum(owner);
    try self.transformed_scope_owner_map.put(self.allocator, key, @intFromEnum(scope));
    try self.scope_owner_origins.put(self.allocator, key, key);
    return scope;
}

/// Generated iterator-close catch clauses have a real lexical boundary.
/// Register their owner before the rewritten tree is visited so copied
/// catch nodes retain this ScopeId and their parameter does not leak outward.
pub fn addGeneratedCatchScope(self: *Transformer, parent: ScopeId, owner: NodeIndex) Transformer.Error!ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    if (owner.isNone() or self.ast.getNode(owner).tag != .catch_clause)
        std.debug.panic("invalid generated catch scope owner", .{});
    const editor = try editorFor(self);
    const scope = editor.addScope(parent, owner, .catch_clause, false) catch |err| return editError(err);
    const key = @intFromEnum(owner);
    try self.transformed_scope_owner_map.put(self.allocator, key, @intFromEnum(scope));
    try self.scope_owner_origins.put(self.allocator, key, key);
    return scope;
}

/// Class lowering emits the IIFE body before its function node exists. Reserve
/// its scope now so generated bindings and references have their output parent.
pub fn reserveGeneratedFunctionScope(self: *Transformer, parent: ScopeId) Transformer.Error!ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const editor = try editorFor(self);
    return editor.addScope(parent, .none, .function, true) catch |err| return editError(err);
}

pub fn bindReservedFunctionOwner(self: *Transformer, scope: ScopeId, owner: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    if (scope.isNone() or scope.toIndex() >= editor.scopes.items.len or owner.isNone() or
        @intFromEnum(owner) >= self.ast.nodes.items.len or
        (self.ast.getNode(owner).tag != .function_expression and self.ast.getNode(owner).tag != .function_declaration))
        std.debug.panic("invalid reserved function scope owner", .{});
    const raw = @intFromEnum(owner);
    if (editor.scope_owner_map.contains(raw) or self.transformed_scope_owner_map.contains(raw))
        std.debug.panic("reserved function scope owner already bound", .{});
    try editor.scope_owner_map.put(self.allocator, raw, @intFromEnum(scope));
    try self.transformed_scope_owner_map.put(self.allocator, raw, @intFromEnum(scope));
    try self.scope_owner_origins.put(self.allocator, raw, raw);
}

pub fn reparentGeneratedScope(self: *Transformer, source: ScopeId, parent: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.reparentScope(source, parent) catch |err| return editError(err);
}

pub fn outputScopeParent(self: *Transformer, source: ScopeId) ScopeId {
    if (source.isNone()) return .none;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (source.toIndex() >= scopes.len) std.debug.panic("invalid output source scope", .{});
    return scopes[source.toIndex()].parent;
}

/// Generated class expressions can lack an analyzer-owned class scope. Return
/// the exact owner only when the input node establishes that boundary.
pub fn outputOwnedScope(self: *Transformer, owner: NodeIndex) ?ScopeId {
    const raw = @intFromEnum(owner);
    const id = self.transformed_scope_owner_map.get(raw) orelse
        self.scope_owner_map.get(raw) orelse
        if (self.semantic_editor) |*editor| editor.scope_owner_map.get(raw) else null;
    return if (id) |value| @enumFromInt(value) else null;
}

/// Track all copies of a lexical boundary. A source node can be revisited on
/// separate branches, so the live owner is selected from the final AST later.
pub fn remapCopiedScopeOwner(self: *Transformer, old: NodeIndex, new: NodeIndex) Transformer.Error!void {
    if (old.isNone() or new.isNone() or old == new) return;
    const old_tag = self.ast.getNode(old).tag;
    const new_tag = self.ast.getNode(new).tag;
    if (old_tag != new_tag and
        !(old_tag == .arrow_function_expression and new_tag == .function_expression) and
        !(old_tag == .for_of_statement and new_tag == .for_statement) and
        !(old_tag == .class_declaration and new_tag == .class_expression) and
        !(old_tag == .method_definition and (new_tag == .function_declaration or new_tag == .function_expression))) return;
    const old_key = @intFromEnum(old);
    const new_key = @intFromEnum(new);
    const scope = self.transformed_scope_owner_map.get(old_key) orelse self.scope_owner_map.get(old_key) orelse return;
    if (self.transformed_scope_owner_map.get(new_key) orelse self.scope_owner_map.get(new_key)) |existing| {
        if (existing != scope) std.debug.panic("copied scope owner has conflicting scopes", .{});
    }
    const origin = self.scope_owner_origins.get(old_key) orelse if (self.scope_owner_map.contains(old_key)) old_key else null;
    if (origin) |first| {
        try self.scope_owner_remaps.put(self.allocator, first, new_key);
        try self.scope_owner_origins.put(self.allocator, new_key, first);
    }
    try self.transformed_scope_owner_map.put(self.allocator, new_key, scope);
}

/// Resolve branch copies only after transform() has installed the final root.
/// Two reachable copies of one scope cannot safely share its ScopeId.
fn resolveReachableScopeOwners(self: *Transformer) Transformer.Error!void {
    if (self.scope_owner_remaps.count() == 0) return;
    const reachable = @import("../../parser/ast_walk.zig").collectReachableNodeIndices(self.allocator, self.ast) catch return error.OutOfMemory;
    defer self.allocator.free(reachable);
    var final_by_origin: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer final_by_origin.deinit(self.allocator);
    for (reachable) |node| {
        const origin = self.scope_owner_origins.get(node) orelse if (self.scope_owner_map.contains(node)) node else continue;
        if (final_by_origin.get(origin)) |existing| {
            if (existing != node) std.debug.panic("one scope owner has multiple reachable copies", .{});
        } else try final_by_origin.put(self.allocator, origin, node);
    }
    var remaps = self.scope_owner_remaps.iterator();
    while (remaps.next()) |entry| {
        // An erased boundary has no final owner. Keep its original metadata;
        // pruning dead scopes is a separate semantic edit.
        entry.value_ptr.* = final_by_origin.get(entry.key_ptr.*) orelse entry.key_ptr.*;
    }
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

fn captureKey(frame: u32, kind: LexicalCaptureKind) u64 {
    return (@as(u64, frame) << 1) | @intFromEnum(kind);
}

/// An `arguments` binding declared inside the lowered arrow already resolves
/// inside its emitted function, without an outer capture alias.
pub fn shouldCaptureArguments(self: *Transformer, source: NodeIndex) bool {
    if (!self.semantic_edit_enabled or self.outermost_lowered_arrow_scope.isNone()) return true;
    const raw_id = self.getSymbolIdAt(source) orelse return true;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    if (raw_id >= symbols.len) std.debug.panic("arguments source symbol is absent", .{});
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    var cursor = symbols[raw_id].scope_id;
    while (!cursor.isNone()) {
        if (cursor == self.outermost_lowered_arrow_scope) return false;
        cursor = scopes[cursor.toIndex()].parent;
    }
    return true;
}

/// The capture initializer reads the source `arguments` binding when it is an
/// explicit user symbol. Implicit function arguments remain a host reference.
pub fn makeCapturedArgumentsInit(self: *Transformer) Transformer.Error!NodeIndex {
    const helpers = @import("../es_helpers.zig");
    if (!self.semantic_edit_enabled or self.capture_frame == 0)
        return helpers.makeGlobalRef(self, "arguments");
    var origin: NodeIndex = .none;
    var source_id: ?u32 = null;
    for (self.capture_refs.items) |pending| {
        if (pending.frame != self.capture_frame or pending.kind != .arguments_value or pending.source.isNone()) continue;
        const id = self.getSymbolIdAt(pending.source) orelse continue;
        if (source_id) |existing| {
            if (existing != id) std.debug.panic("one arguments capture frame has multiple source bindings", .{});
        } else {
            source_id = id;
            origin = pending.source;
        }
    }
    const id = source_id orelse return helpers.makeGlobalRef(self, "arguments");
    const initializer = try self.makeUserRefNamed("arguments", origin);
    const editor = try editorFor(self);
    editor.addCopiedReference(initializer, @enumFromInt(id), self.capture_scope, .{ .read = true }, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
    return initializer;
}

/// A generated lexical alias reference is paired with its source function
/// frame at construction. The source identifier is retained only so a replaced
/// original `arguments` Reference can be removed after final reachability.
pub fn trackLexicalCaptureRef(self: *Transformer, node: NodeIndex, source: NodeIndex, kind: LexicalCaptureKind) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (self.capture_frame == 0) {
        const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
        if (!self.current_scope.isNone() and scopes[self.current_scope.toIndex()].kind == .function)
            std.debug.panic("lexical capture in a function without a capture frame", .{});
        // Program-level arrow capture placement is a separate lowering path.
        return;
    }
    if (self.capture_scope.isNone() or self.current_scope.isNone())
        std.debug.panic("lexical capture has no source function scope", .{});
    const index = self.capture_refs.items.len;
    try self.capture_refs.append(self.allocator, .{
        .node = node,
        .source = source,
        .scope = self.current_scope,
        .frame = self.capture_frame,
        .kind = kind,
    });
    const raw = @intFromEnum(node);
    if (self.capture_ref_by_origin.contains(raw)) std.debug.panic("lexical capture node tracked twice", .{});
    try self.capture_ref_by_origin.put(self.allocator, raw, index);
    // A later copy can precede declaration binding; preserve exact origin even
    // while this generated reference has no SymbolId yet.
    try self.reference_origin_map.put(self.allocator, raw, raw);
}

/// Called at the actual capture declaration producer. A frame and role select
/// the binding; emitted text is never used to recover a symbol.
pub fn bindLexicalCapture(self: *Transformer, declaration: NodeIndex, kind: LexicalCaptureKind) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.capture_frame == 0) return;
    const decl = self.ast.getNode(declaration);
    if (decl.tag != .variable_declaration) std.debug.panic("lexical capture is not a variable declaration", .{});
    const start = self.readU32(decl.data.extra, 1);
    const len = self.readU32(decl.data.extra, 2);
    if (len != 1) std.debug.panic("lexical capture has multiple declarators", .{});
    const item: NodeIndex = @enumFromInt(self.ast.extra_data.items[start]);
    const binding = self.readNodeIdx(self.ast.getNode(item).data.extra, 0);
    const id = (try declareSyntheticInScope(self, binding, decl.span, .variable_var, self.capture_scope)).?;
    const key = captureKey(self.capture_frame, kind);
    if (self.capture_binding_ids.contains(key)) std.debug.panic("duplicate lexical capture binding", .{});
    try self.capture_binding_ids.put(self.allocator, key, @intFromEnum(id));
}

fn bindReachableLexicalCaptures(self: *Transformer) Transformer.Error!void {
    if (self.capture_refs.items.len == 0) return;
    const reachable = @import("../../parser/ast_walk.zig").collectReachableNodeIndices(self.allocator, self.ast) catch return error.OutOfMemory;
    defer self.allocator.free(reachable);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    for (reachable) |raw| try live.put(self.allocator, raw, {});

    for (reachable) |raw| {
        const origin = self.reference_origin_map.get(raw) orelse raw;
        const index = self.capture_ref_by_origin.get(origin) orelse continue;
        const pending = self.capture_refs.items[index];
        const id = self.capture_binding_ids.get(captureKey(pending.frame, pending.kind)) orelse
            std.debug.panic("live lexical capture has no declaration", .{});
        try addSyntheticRefInScope(self, @enumFromInt(raw), @enumFromInt(id), pending.scope, .{ .read = true });
    }

    const editor = try editorFor(self);
    for (self.capture_refs.items) |pending| {
        if (pending.source.isNone() or live.contains(@intFromEnum(pending.source))) continue;
        if (self.getSymbolIdAt(pending.source) == null) continue;
        editor.removeReference(pending.source) catch |err| return editError(err);
    }
}

/// 헬퍼 호출은 import 선언보다 먼저 생성된다. marker가 있는 노드만 보류한다.
pub fn trackRuntimeHelperRef(self: *Transformer, node: NodeIndex, local_name: []const u8) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (self.current_scope.isNone()) std.debug.panic("runtime helper {s} created without scope", .{local_name});
    const index = self.pending_runtime_helper_refs.items.len;
    try self.pending_runtime_helper_refs.append(self.allocator, .{ .node = node, .scope = self.current_scope });
    try self.pending_runtime_helper_ref_index.put(self.allocator, @intFromEnum(node), index);
    if (self.pending_runtime_helper_chains.getPtr(local_name)) |chain| {
        self.pending_runtime_helper_refs.items[chain.last].next = index;
        chain.last = index;
    } else {
        try self.pending_runtime_helper_chains.put(self.allocator, local_name, .{ .first = index, .last = index });
    }
}

/// `__generator` is created before the async wrapper that contains its call.
/// Retarget only the exact pending helper node after that wrapper is created.
pub fn relocatePendingRuntimeHelperRef(self: *Transformer, node: NodeIndex, scope: ScopeId) void {
    if (!self.semantic_edit_enabled) return;
    if (scope.isNone()) std.debug.panic("runtime helper relocation has no scope", .{});
    const index = self.pending_runtime_helper_ref_index.get(@intFromEnum(node)) orelse
        std.debug.panic("runtime helper reference was not pending", .{});
    self.pending_runtime_helper_refs.items[index].scope = scope;
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
        _ = self.pending_runtime_helper_ref_index.remove(@intFromEnum(ref.node));
        editor.addReference(ref.node, id, ref.scope, .{ .read = true }, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        try setSymbolId(self, ref.node, id);
        i = ref.next;
    }
    if (self.pending_runtime_helper_chains.count() == 0) {
        self.pending_runtime_helper_refs.clearRetainingCapacity();
        self.pending_runtime_helper_ref_index.clearRetainingCapacity();
    }
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

/// `a ?? b`가 `a != null ? a : b`로 늘린 두 읽기 노드의 Reference를 기록한다.
/// 원본 식별자가 새 노드로 교체된 경우 원본 사용 횟수는 제거한다.
pub fn trackNullishIdentifierCopies(self: *Transformer, source: NodeIndex, test_ref: NodeIndex, value_ref: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const source_i = @intFromEnum(source);
    if (source_i >= self.symbol_ids.items.len or self.symbol_ids.items[source_i] == null) return;
    const editor = try editorFor(self);
    if (test_ref != source) {
        editor.cloneReferenceAtSameLocation(source, test_ref) catch |err| return editError(err);
    }
    editor.cloneReferenceAtSameLocation(source, value_ref) catch |err| return editError(err);
    if (test_ref != source) editor.removeReference(source) catch |err| return editError(err);
}

/// `_loop(index)`의 새 인자는 원래 헤더 바인딩을 읽는다. 바인딩에는 복제할
/// Reference가 없으므로 생성 위치의 스코프와 읽기 플래그로 직접 등록한다.
pub fn trackUserArgumentFromBinding(self: *Transformer, argument: NodeIndex, binding: NodeIndex, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const raw_id = self.getSymbolIdAt(binding) orelse return;
    if (self.getSymbolIdAt(argument) != raw_id) std.debug.panic("loop argument lost header symbol", .{});
    const editor = try editorFor(self);
    editor.addCopiedReference(
        argument,
        @enumFromInt(raw_id),
        scope,
        .{ .read = true },
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
}

/// Hoisting a source `var` declaration into an assignment creates a new write
/// target. The binding has no Reference to clone, so record the source
/// expression's lexical scope explicitly. This may differ from both the
/// binding's function scope and `current_scope` (generator collection).
pub fn trackUserWriteFromBinding(self: *Transformer, target: NodeIndex, binding: NodeIndex, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const raw_id = self.getSymbolIdAt(binding) orelse return;
    if (self.getSymbolIdAt(target) != raw_id) std.debug.panic("hoisted var write lost source symbol", .{});
    const editor = try editorFor(self);
    editor.addCopiedReference(
        target,
        @enumFromInt(raw_id),
        scope,
        .{ .write = true },
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
}

/// 변환 중 복사된 사용자 식별자와 scope owner도 편집 결과에 합친다.
pub fn finishSemanticEdit(self: *Transformer) Transformer.Error!?SemanticEditor.Result {
    if (!self.semantic_edit_enabled) return null;
    try resolveReachableScopeOwners(self);
    // Scope-owner remaps are semantic edits even when no binding/reference was
    // synthesized. Arrow-to-function and copied body scopes need a final map.
    if (self.semantic_editor == null and self.scope_owner_remaps.count() > 0)
        _ = try editorFor(self);
    const editor = if (self.semantic_editor) |*e| e else return null;
    if (self.options.emit_runtime_helper_imports and self.pending_runtime_helper_chains.count() != 0)
        std.debug.panic("generated runtime helper reference has no import", .{});
    var remaps = self.scope_owner_remaps.iterator();
    while (remaps.next()) |entry| {
        editor.remapScopeOwner(@enumFromInt(entry.key_ptr.*), @enumFromInt(entry.value_ptr.*)) catch |err| return editError(err);
    }
    try bindReachableLexicalCaptures(self);
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
