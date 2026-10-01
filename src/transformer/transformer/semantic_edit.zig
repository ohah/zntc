//! 변환 중 합성 바인딩과 참조를 원래 semantic SymbolId 공간에 추가한다 (#4819).
const std = @import("std");
const Transformer = @import("../transformer.zig").Transformer;
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const ast_walk = @import("../../parser/ast_walk.zig");
const reference_walk = @import("../../semantic/reference_walk.zig");
const Span = @import("../../lexer/token.zig").Span;
const token_mod = @import("../../lexer/token.zig");
const SymbolId = @import("../../semantic/symbol.zig").SymbolId;
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const ScopeKind = @import("../../semantic/scope.zig").ScopeKind;
const Symbol = @import("../../semantic/symbol.zig").Symbol;
const Reference = @import("../../semantic/symbol.zig").Reference;
const ReferenceFlags = @import("../../semantic/symbol.zig").ReferenceFlags;
const SemanticEditor = @import("../../semantic/editor.zig").SemanticEditor;
const EditorError = @import("../../semantic/editor.zig").Error;
const LexicalCaptureKind = @import("../transformer.zig").LexicalCaptureKind;
const es_helpers = @import("../es_helpers.zig");

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

fn outputSymbolIdAt(self: *Transformer, editor: *SemanticEditor, node: NodeIndex) ?u32 {
    if (self.getSymbolIdAt(node)) |id| return id;
    if (node.isNone() or @intFromEnum(node) >= editor.symbol_ids.items.len) return null;
    return editor.symbol_ids.items[@intFromEnum(node)];
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
    if (self.generated_class_self_relocated_to_wrapper.contains(raw)) return false;
    if (self.generated_class_without_source_anchor.contains(raw)) {
        if (self.semantic_edit_enabled)
            std.debug.panic("generated worklet class needs a fresh self scope and SymbolId", .{});
        return false;
    }
    const origin = self.scope_owner_origins.get(raw) orelse if (raw < self.parser_node_count) raw else std.debug.panic("generated class has no exact source owner", .{});
    // Transforms such as inferred-name class cloning can assign a distinct
    // class-self entry to the emitted node while retaining the original node
    // as its scope-owner origin. Prefer that exact output-node identity, then
    // fall back to the canonical source owner for ordinary copied classes.
    const inner_raw = self.class_self_symbol_map.get(raw) orelse self.class_self_symbol_map.get(origin) orelse {
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

pub fn nearestVarScope(self: *Transformer, scope: ScopeId) ScopeId {
    if (!self.semantic_edit_enabled or scope.isNone()) return .none;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    var cursor = scope;
    var hops: usize = 0;
    while (!cursor.isNone() and hops < scopes.len) : (hops += 1) {
        if (cursor.toIndex() >= scopes.len) std.debug.panic("invalid scope while finding var scope", .{});
        if (scopes[cursor.toIndex()].kind.isVarScope()) return cursor;
        cursor = scopes[cursor.toIndex()].parent;
    }
    std.debug.panic("scope has no var scope", .{});
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
pub fn bindGeneratedState(self: *Transformer, parent: ScopeId, source_scope: ScopeId, callback: NodeIndex, parameter: NodeIndex, ref_start: usize, wrapper_temps: []const @import("lists.zig").HoistedStateTemp, callback_temps: []const @import("lists.zig").HoistedStateTemp, span: Span) Transformer.Error!void {
    if (ref_start > self.generator_state_refs.items.len) std.debug.panic("invalid state machine frame", .{});
    if (self.semantic_edit_enabled and !parent.isNone()) {
        const scope = try addGeneratedFunctionScope(self, parent, callback);
        const symbol = try declareSyntheticInScope(self, parameter, span, .parameter, scope);
        try reparentDeferredGeneratorLoops(self, source_scope, scope);
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
        try reparentLiveSourceScopes(self, source_scope, scope, &live_scopes);
        try self.moveGeneratedFunctionBodyBindings(source_scope, scope, callback);
        var callback_traces = try collectGeneratedNodeTraces(self, callback, scope);
        defer callback_traces.deinit(self.allocator);
        for (wrapper_temps) |temp| {
            try bindStateCallbackTemp(self, temp, span, source_scope, source_scope, scope, &seen, &live_scopes, &callback_traces);
        }
        for (self.generator_state_bindings.items) |temp| {
            const binding_scope = if (temp.callback_local) scope else source_scope;
            if (temp.symbol_id != null) {
                try bindStateCallbackTemp(self, temp, span, source_scope, binding_scope, scope, &seen, &live_scopes, &callback_traces);
            } else if (temp.callback_local) {
                try bindTrackedCallbackTemp(self, temp, span, source_scope, scope, &seen, &live_scopes);
            } else {
                try bindGeneratedWrapperTemp(self, temp, span, source_scope, scope, &seen, &live_scopes);
            }
        }
        for (callback_temps) |temp| {
            try bindStateCallbackTemp(self, temp, span, source_scope, scope, scope, &seen, &live_scopes, &callback_traces);
        }
        try bindGeneratorStateReferences(self, source_scope, scope, callback, &seen, &live_scopes);
        var migrations = self.deferred_generator_loop_migrations.iterator();
        while (migrations.next()) |entry| {
            const migration = entry.value_ptr;
            if (entry.key_ptr.* != @intFromEnum(source_scope)) continue;
            if (!migration.state_callback.isNone()) std.debug.panic("generator loop state callback registered twice", .{});
            migration.state_callback = callback;
            migration.state_callback_scope = scope;
        }
        try migrateDeferredGeneratorLoopBodies(self, source_scope);
    }
    self.generator_state_refs.shrinkRetainingCapacity(ref_start);
}

/// Extracted generator functions are emitted inside their enclosing state
/// callback. Their provisional parent exists before that callback does; move
/// each exact generated function scope once its enclosing callback is known.
fn reparentDeferredGeneratorLoops(self: *Transformer, source_scope: ScopeId, callback_scope: ScopeId) Transformer.Error!void {
    if (source_scope.isNone() or self.deferred_generator_loop_migrations.count() == 0) return;
    const editor = try editorFor(self);
    var ready: std.ArrayList(u32) = .empty;
    defer ready.deinit(self.allocator);
    var entries = self.deferred_generator_loop_migrations.iterator();
    while (entries.next()) |entry| {
        const migration = entry.value_ptr.*;
        if (migration.enclosing_function_scope == source_scope and !migration.function_reparented)
            try ready.append(self.allocator, entry.key_ptr.*);
    }
    for (ready.items) |function_scope_raw| {
        const migration = self.deferred_generator_loop_migrations.getPtr(function_scope_raw) orelse continue;
        const function_scope: ScopeId = @enumFromInt(function_scope_raw);
        if (!scopeWithin(editor.scopes.items, function_scope, callback_scope))
            editor.reparentScope(function_scope, callback_scope) catch |err| return editError(err);
        migration.function_reparented = true;
        try discardCompletedGeneratorLoopMigration(self, function_scope_raw);
    }
}

fn migrateDeferredGeneratorLoopBodies(self: *Transformer, source_scope: ScopeId) Transformer.Error!void {
    if (source_scope.isNone() or self.deferred_generator_loop_migrations.count() == 0) return;
    var ready: std.ArrayList(u32) = .empty;
    defer ready.deinit(self.allocator);
    var entries = self.deferred_generator_loop_migrations.iterator();
    while (entries.next()) |entry| {
        const migration = entry.value_ptr.*;
        if (entry.key_ptr.* != @intFromEnum(source_scope) or migration.state_callback.isNone() or migration.body_migrated) continue;
        try ready.append(self.allocator, entry.key_ptr.*);
    }

    for (ready.items) |function_scope_raw| {
        const migration_ptr = self.deferred_generator_loop_migrations.getPtr(function_scope_raw) orelse continue;
        const migration = migration_ptr.*;
        try migrateGeneratorLoopBody(
            self,
            migration.body,
            migration.state_callback,
            @enumFromInt(function_scope_raw),
            migration.state_callback_scope,
            migration.call_scope,
            migration.header_symbol_ids,
            migration.parameter_symbol_ids,
        );
        migration_ptr.body_migrated = true;
        try discardCompletedGeneratorLoopMigration(self, function_scope_raw);
    }
}

fn discardCompletedGeneratorLoopMigration(self: *Transformer, function_scope_raw: u32) Transformer.Error!void {
    const migration = self.deferred_generator_loop_migrations.get(function_scope_raw) orelse return;
    if (!migration.function_reparented or !migration.body_migrated) return;
    const removed = self.deferred_generator_loop_migrations.fetchRemove(function_scope_raw) orelse return;
    self.allocator.free(removed.value.header_symbol_ids);
    self.allocator.free(removed.value.parameter_symbol_ids);
}

const OutputScopeWork = struct {
    node: NodeIndex,
    scope: ScopeId,
    parent: NodeIndex = .none,
    grandparent: NodeIndex = .none,
};
const OutputReferenceScope = struct { node: NodeIndex, scope: ScopeId, raw_id: u32 };
const OutputBindingCandidate = struct {
    node: NodeIndex,
    raw_id: u32,
    lexical_scope: ScopeId,
    target_scope: ScopeId,
    kind: SymbolKind,
    name: []const u8,
};
const OutputBindingGroup = struct {
    raw_id: u32,
    target_scope: ScopeId,
    lexical_scope: ScopeId,
    kind: SymbolKind,
    name: []const u8,
    first_node: NodeIndex,
    candidate_start: usize,
    candidate_end: usize,
    resolved_id: u32,
};

fn outputBindingCandidateLessThan(_: void, lhs: OutputBindingCandidate, rhs: OutputBindingCandidate) bool {
    if (lhs.raw_id != rhs.raw_id) return lhs.raw_id < rhs.raw_id;
    if (lhs.target_scope != rhs.target_scope) return lhs.target_scope.toIndex() < rhs.target_scope.toIndex();
    if (lhs.kind != rhs.kind) return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn sameOutputBindingGroup(lhs: OutputBindingCandidate, rhs: OutputBindingCandidate) bool {
    return lhs.raw_id == rhs.raw_id and lhs.target_scope == rhs.target_scope and lhs.kind == rhs.kind and
        std.mem.eql(u8, lhs.name, rhs.name);
}

fn containsNodeInExtraList(ast: *const ast_mod.Ast, start: u32, len: u32, child: u32) bool {
    if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return false;
    for (ast.extra_data.items[start .. start + len]) |raw| {
        if (raw == child) return true;
    }
    return false;
}

fn childSkipsOutputScope(ast: *const ast_mod.Ast, parent_raw: u32, child_raw: u32) bool {
    if (parent_raw >= ast.nodes.items.len) return false;
    const parent = ast.nodes.items[parent_raw];
    switch (parent.tag) {
        .ts_enum_declaration => {
            const extra = parent.data.extra;
            return extra < ast.extra_data.items.len and ast.extra_data.items[extra] == child_raw;
        },
        .function_declaration => {
            const extra = parent.data.extra;
            return extra < ast.extra_data.items.len and ast.extra_data.items[extra + ast_mod.FunctionExtra.name] == child_raw;
        },
        .switch_statement => {
            const extra = parent.data.extra;
            return extra < ast.extra_data.items.len and ast.extra_data.items[extra] == child_raw;
        },
        .method_definition => {
            const extra = parent.data.extra;
            if (extra + ast_mod.MethodExtra.deco_len >= ast.extra_data.items.len) return false;
            if (ast.extra_data.items[extra + ast_mod.MethodExtra.key] == child_raw) return true;
            return containsNodeInExtraList(
                ast,
                ast.extra_data.items[extra + ast_mod.MethodExtra.deco_start],
                ast.extra_data.items[extra + ast_mod.MethodExtra.deco_len],
                child_raw,
            );
        },
        .class_declaration => {
            const extra = parent.data.extra;
            if (extra < ast.extra_data.items.len and ast.extra_data.items[extra + ast_mod.ClassExtra.name] == child_raw) return true;
            if (extra + ast_mod.ClassExtra.deco_len >= ast.extra_data.items.len) return false;
            return containsNodeInExtraList(
                ast,
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_start],
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_len],
                child_raw,
            );
        },
        .class_expression => {
            const extra = parent.data.extra;
            if (extra + ast_mod.ClassExtra.deco_len >= ast.extra_data.items.len) return false;
            return containsNodeInExtraList(
                ast,
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_start],
                ast.extra_data.items[extra + ast_mod.ClassExtra.deco_len],
                child_raw,
            );
        },
        else => return false,
    }
}

fn isNamespaceDeclarationNameBinding(ast: *const ast_mod.Ast, parent_raw: u32, child_raw: u32) bool {
    if (parent_raw >= ast.nodes.items.len) return false;
    const parent = ast.nodes.items[parent_raw];
    return parent.tag == .ts_module_declaration and parent.data.binary.left == @as(NodeIndex, @enumFromInt(child_raw));
}

fn isEnumDeclarationNameBinding(ast: *const ast_mod.Ast, parent_raw: u32, child_raw: u32) bool {
    if (parent_raw >= ast.nodes.items.len) return false;
    const parent = ast.nodes.items[parent_raw];
    return parent.tag == .ts_enum_declaration and
        parent.data.extra < ast.extra_data.items.len and
        ast.extra_data.items[parent.data.extra] == child_raw;
}

fn isGeneratedOutputVar(symbol: Symbol) bool {
    // Generated declarations emitted as `var` belong to the output function's
    // var scope, including loop temps assembled inside extracted callbacks.
    return symbol.synthetic_name.len > 0 and symbol.kind == .variable_var or
        (symbol.kind == .variable_const and symbol.synthetic_name.len > 0 and
            std.mem.startsWith(u8, symbol.synthetic_name, "_using"));
}

fn outputBindingTargetScope(
    self: *Transformer,
    editor: *SemanticEditor,
    lexical_scope: ScopeId,
    symbol: Symbol,
    is_declaration_name: bool,
    output_var: bool,
) ScopeId {
    if (is_declaration_name) return lexical_scope;
    if (symbol.kind.declFlags().function_scoped or
        (output_var and (isGeneratedOutputVar(symbol) or symbol.decl_flags.is_default_export)))
        return self.nearestVarScope(lexical_scope);
    // Module/function declarations can be wrapped in generated try blocks by
    // resource lowering. Their original var boundary still encloses the code.
    if (output_var and !symbol.scope_id.isNone() and symbol.scope_id.toIndex() < editor.scopes.items.len and
        editor.scopes.items[symbol.scope_id.toIndex()].kind.isVarScope() and
        scopeWithin(editor.scopes.items, lexical_scope, symbol.scope_id)) return symbol.scope_id;
    return lexical_scope;
}

fn isNamedFunctionExpressionBinding(self: *Transformer, parent: NodeIndex, binding: NodeIndex) bool {
    if (parent.isNone()) return false;
    const node = self.ast.getNode(parent);
    if (node.tag != .function_expression and node.tag != .function) return false;
    return self.readNodeIdx(node.data.extra, ast_mod.FunctionExtra.name) == binding;
}

fn bridgeOutputParentToSourceParent(
    editor: *SemanticEditor,
    output_parent: ScopeId,
    source_parent: ScopeId,
) Transformer.Error!void {
    if (output_parent.isNone() or source_parent.isNone()) return;
    const scopes = editor.scopes.items;
    if (scopeWithin(scopes, output_parent, source_parent) or scopeWithin(scopes, source_parent, output_parent)) return;

    // Scope extraction may put a generated callback and a source loop scope
    // in sibling branches. Insert the output branch below the source loop's
    // former parent, preserving visibility of source bindings while letting
    // the emitted loop scope become a child of its actual output parent.
    var common = output_parent;
    var hops: usize = 0;
    while (!common.isNone() and hops < scopes.len and !scopeWithin(scopes, source_parent, common)) : (hops += 1) {
        if (common.toIndex() >= scopes.len) std.debug.panic("invalid output scope while finding common parent", .{});
        common = scopes[common.toIndex()].parent;
    }
    if (common.isNone()) std.debug.panic("output and source scope trees have no common parent", .{});

    var frontier = output_parent;
    var frontier_parent = scopes[frontier.toIndex()].parent;
    while (frontier_parent != common) {
        if (frontier_parent.isNone() or frontier_parent.toIndex() >= scopes.len)
            std.debug.panic("invalid output scope frontier", .{});
        frontier = frontier_parent;
        frontier_parent = scopes[frontier.toIndex()].parent;
    }
    editor.reparentScope(frontier, source_parent) catch |err| return editError(err);
}

/// Complete lexical boundaries for the emitted callback tree and move only
/// existing identifier references to the scope selected by that output tree.
/// The source analyzer's scopes still describe the pre-lowering tree, so a
/// state-machine switch and references copied from the generator body need an
/// explicit output owner before their IDs can pass the exact audit.
pub fn bindOutputScopesAndReferences(self: *Transformer, root: NodeIndex, root_scope: ScopeId) Transformer.Error!void {
    const editor = try editorFor(self);
    if (self.outputOwnedScope(root) == null) {
        try editor.scope_owner_map.put(self.allocator, @intFromEnum(root), @intFromEnum(root_scope));
    }
    var stack: std.ArrayList(OutputScopeWork) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    var output_refs: std.ArrayList(OutputReferenceScope) = .empty;
    defer output_refs.deinit(self.allocator);
    var output_bindings: std.ArrayList(OutputBindingCandidate) = .empty;
    defer output_bindings.deinit(self.allocator);
    var generated_catch_specs: std.ArrayListUnmanaged(GeneratedLocalSpec) = .empty;
    defer generated_catch_specs.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .scope = root_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone() or @intFromEnum(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        var scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (node.tag == .block_statement and self.outputOwnedScope(work.node) == null) {
            const function_body = !work.parent.isNone() and switch (self.ast.getNode(work.parent).tag) {
                .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => true,
                else => false,
            };
            if (!function_body) scope = try self.addGeneratedScope(work.scope, work.node, ScopeKind.block);
        } else if (node.tag == .block_statement and self.outputOwnedScope(work.node) != null and !work.scope.isNone() and
            !scopeWithin(editor.scopes.items, scope, work.scope) and !scopeWithin(editor.scopes.items, work.scope, scope))
        {
            const source_parent = editor.scopes.items[scope.toIndex()].parent;
            try bridgeOutputParentToSourceParent(editor, work.scope, source_parent);
            editor.reparentScope(scope, work.scope) catch |err| return editError(err);
        }
        if (node.tag == .catch_clause and self.outputOwnedScope(work.node) == null) {
            scope = try self.addGeneratedCatchScope(work.scope, work.node);
        } else if (node.tag == .catch_clause and !scopeWithin(editor.scopes.items, scope, work.scope)) {
            if (scopeWithin(editor.scopes.items, work.scope, scope)) std.debug.panic("output catch scope encloses its AST parent scope", .{});
            editor.reparentScope(scope, work.scope) catch |err| return editError(err);
        }
        if (node.tag == .catch_clause) {
            const param = node.data.binary.left;
            if (!param.isNone() and @intFromEnum(param) >= self.parser_node_count and self.ast.getNode(param).tag == .binding_identifier) {
                const name = self.ast.getText(self.ast.getNode(param).data.string_ref);
                var already_added = false;
                for (generated_catch_specs.items) |spec| {
                    if (std.mem.eql(u8, spec.name, name)) {
                        already_added = true;
                        break;
                    }
                }
                if (!already_added) try generated_catch_specs.append(self.allocator, .{ .name = name, .kind = .catch_binding });
            }
        }
        if ((node.tag == .for_statement or node.tag == .for_in_statement or node.tag == .for_of_statement or node.tag == .for_await_of_statement) and
            self.outputOwnedScope(work.node) != null and !work.scope.isNone() and scope != work.scope and
            !scopeWithin(editor.scopes.items, scope, work.scope) and !scopeWithin(editor.scopes.items, work.scope, scope))
        {
            // Preserve source bindings when extraction moved the emitted loop
            // into a sibling generated-function branch.
            if (!scopeWithin(editor.scopes.items, work.scope, scope)) {
                const source_parent = editor.scopes.items[scope.toIndex()].parent;
                try bridgeOutputParentToSourceParent(editor, work.scope, source_parent);
                editor.reparentScope(scope, work.scope) catch |err| return editError(err);
            }
        }
        if (node.tag == .switch_statement and self.outputOwnedScope(work.node) == null) {
            scope = try self.addGeneratedScope(work.scope, work.node, ScopeKind.switch_block);
        }
        if ((node.tag == .function_declaration or node.tag == .function_expression or node.tag == .function or
            node.tag == .arrow_function_expression or node.tag == .method_definition) and
            self.outputOwnedScope(work.node) != null and !work.scope.isNone() and
            !scopeWithin(editor.scopes.items, scope, work.scope) and !scopeWithin(editor.scopes.items, work.scope, scope))
        {
            const source_parent = editor.scopes.items[scope.toIndex()].parent;
            try bridgeOutputParentToSourceParent(editor, work.scope, source_parent);
            editor.reparentScope(scope, work.scope) catch |err| return editError(err);
        }
        // A namespace name node denotes the outer namespace object. Codegen's
        // IIFE parameter is a separate virtual binding already represented in
        // the namespace function scope; relocating this source SymbolId would
        // merge those two identities and collide with an exported member of
        // the same name.
        if (node.tag == .binding_identifier and
            !isNamespaceDeclarationNameBinding(self.ast, @intFromEnum(work.parent), raw) and
            !isEnumDeclarationNameBinding(self.ast, @intFromEnum(work.parent), raw))
        {
            if (self.generated_body_binding_moves.fetchRemove(raw)) |move| {
                const id = outputSymbolIdAt(self, editor, work.node) orelse std.debug.panic("moved source binding lost its SymbolId", .{});
                if (id != move.value or id >= editor.symbols.items.len)
                    std.debug.panic("moved source binding changed its SymbolId", .{});
                const symbol = editor.symbols.items[id];
                const is_declaration_name = !work.parent.isNone() and
                    self.ast.getNode(work.parent).tag == .function_declaration and
                    self.readNodeIdx(self.ast.getNode(work.parent).data.extra, ast_mod.FunctionExtra.name) == work.node;
                const output_var = !work.parent.isNone() and !work.grandparent.isNone() and
                    self.ast.getNode(work.parent).tag == .variable_declarator and
                    self.ast.getNode(work.grandparent).tag == .variable_declaration and
                    self.ast.variableDeclarationKind(self.ast.getNode(work.grandparent)) == .@"var";
                const target_scope = if (isNamedFunctionExpressionBinding(self, work.parent, work.node))
                    symbol.scope_id
                else
                    outputBindingTargetScope(self, editor, scope, symbol, is_declaration_name, output_var);
                if (target_scope.isNone()) std.debug.panic("moved source binding has no emitted scope", .{});
                if (symbol.scope_id != target_scope)
                    editor.relocateSymbolAs(@enumFromInt(id), target_scope, work.node) catch |err| return editError(err);
            }
            if (outputSymbolIdAt(self, editor, work.node)) |id| {
                if (id < editor.symbols.items.len) {
                    const symbol = editor.symbols.items[id];
                    const is_declaration_name = !work.parent.isNone() and
                        self.ast.getNode(work.parent).tag == .function_declaration and
                        self.readNodeIdx(self.ast.getNode(work.parent).data.extra, ast_mod.FunctionExtra.name) == work.node;
                    const output_var = !work.parent.isNone() and !work.grandparent.isNone() and
                        self.ast.getNode(work.parent).tag == .variable_declarator and
                        self.ast.getNode(work.grandparent).tag == .variable_declaration and
                        self.ast.variableDeclarationKind(self.ast.getNode(work.grandparent)) == .@"var";
                    const target_scope = if (isNamedFunctionExpressionBinding(self, work.parent, work.node))
                        symbol.scope_id
                    else
                        outputBindingTargetScope(self, editor, scope, symbol, is_declaration_name, output_var);
                    if (!target_scope.isNone() and (symbol.synthetic_name.len > 0 or symbol.scope_id != target_scope)) {
                        try output_bindings.append(self.allocator, .{
                            .node = work.node,
                            .raw_id = id,
                            .lexical_scope = scope,
                            .target_scope = target_scope,
                            .kind = symbol.kind,
                            .name = try self.ast.getTextStable(self.allocator, node.data.string_ref),
                        });
                    }
                }
            }
        }
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier or node.tag == .jsx_identifier) {
            var raw_id = outputSymbolIdAt(self, editor, work.node);
            if (raw_id == null) {
                if (editor.referenceForNode(work.node) catch |err| return editError(err)) |reference| {
                    raw_id = @intFromEnum(reference.symbol_id);
                }
            }
            if (raw_id) |id| {
                if (id < editor.symbols.items.len and !self.pending_runtime_helper_ref_index.contains(raw)) {
                    try output_refs.append(self.allocator, .{ .node = work.node, .scope = scope, .raw_id = id });
                }
            }
        }
        if (node.tag == .switch_statement) {
            const extra = node.data.extra;
            if (extra + 2 >= self.ast.extra_data.items.len) continue;
            const discriminant: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra]);
            if (!discriminant.isNone()) try stack.append(self.allocator, .{ .node = discriminant, .scope = work.scope, .parent = work.node, .grandparent = work.parent });
            const cases_start = self.ast.extra_data.items[extra + 1];
            const cases_len = self.ast.extra_data.items[extra + 2];
            if (cases_start > self.ast.extra_data.items.len or cases_len > self.ast.extra_data.items.len - cases_start) continue;
            for (self.ast.extra_data.items[cases_start .. cases_start + cases_len]) |raw_case| {
                try stack.append(self.allocator, .{ .node = @enumFromInt(raw_case), .scope = scope, .parent = work.node, .grandparent = work.parent });
            }
            continue;
        }
        var it = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (it.next()) |child| {
            const child_scope = if (childSkipsOutputScope(self.ast, raw, @intFromEnum(child))) work.scope else scope;
            try stack.append(self.allocator, .{ .node = child, .scope = child_scope, .parent = work.node, .grandparent = work.parent });
        }
    }

    // Resolve each emitted synthetic binding after the full output tree is
    // known. One source SymbolId can materialize as both an outer storage
    // binding and a callback-local binding; moving it while walking would make
    // the last declaration steal the identity from every earlier one.
    std.mem.sort(OutputBindingCandidate, output_bindings.items, {}, outputBindingCandidateLessThan);
    var binding_groups: std.ArrayList(OutputBindingGroup) = .empty;
    defer binding_groups.deinit(self.allocator);
    var candidate_start: usize = 0;
    while (candidate_start < output_bindings.items.len) {
        var candidate_end = candidate_start + 1;
        while (candidate_end < output_bindings.items.len and
            sameOutputBindingGroup(output_bindings.items[candidate_start], output_bindings.items[candidate_end])) : (candidate_end += 1)
        {}
        const candidate = output_bindings.items[candidate_start];
        try binding_groups.append(self.allocator, .{
            .raw_id = candidate.raw_id,
            .target_scope = candidate.target_scope,
            .lexical_scope = candidate.lexical_scope,
            .kind = candidate.kind,
            .name = candidate.name,
            .first_node = candidate.node,
            .candidate_start = candidate_start,
            .candidate_end = candidate_end,
            .resolved_id = candidate.raw_id,
        });
        candidate_start = candidate_end;
    }
    var group_cursor: usize = 0;
    while (group_cursor < binding_groups.items.len) {
        const raw_id = binding_groups.items[group_cursor].raw_id;
        var group_end = group_cursor + 1;
        while (group_end < binding_groups.items.len and binding_groups.items[group_end].raw_id == raw_id) : (group_end += 1) {}
        if (raw_id >= editor.symbols.items.len) std.debug.panic("synthetic output binding has invalid SymbolId", .{});
        const original_scope = editor.symbols.items[raw_id].scope_id;
        const original_name = if (editor.symbols.items[raw_id].synthetic_name.len > 0)
            editor.symbols.items[raw_id].synthetic_name
        else
            self.ast.getText(editor.symbols.items[raw_id].name);
        var matching_scope_group: ?usize = null;
        var ancestor_group: ?usize = null;
        var best_distance: usize = std.math.maxInt(usize);
        for (group_cursor..group_end) |index| {
            const group = binding_groups.items[index];
            if (group.target_scope == original_scope and std.mem.eql(u8, group.name, original_name)) {
                matching_scope_group = index;
                break;
            }
            if (group.target_scope == original_scope and matching_scope_group == null) matching_scope_group = index;
            if (lexicalScopeDistance(editor.scopes.items, original_scope, group.target_scope)) |distance| {
                if (distance < best_distance) {
                    best_distance = distance;
                    ancestor_group = index;
                }
            }
        }
        const primary = matching_scope_group orelse ancestor_group orelse group_cursor;
        const primary_binding = binding_groups.items[primary];
        const editor_binding_id = outputSymbolIdAt(self, editor, primary_binding.first_node) orelse std.debug.panic("primary synthetic binding lost its SymbolId", .{});
        if (editor_binding_id != raw_id) std.debug.panic("primary synthetic binding changed SymbolId", .{});
        var merged_into_existing_var = false;
        if (primary_binding.target_scope.toIndex() < editor.scope_maps.items.len) {
            if (editor.scope_maps.items[primary_binding.target_scope.toIndex()].get(primary_binding.name)) |existing_raw| {
                if (existing_raw != raw_id and existing_raw < editor.symbols.items.len) {
                    const existing = editor.symbols.items[existing_raw];
                    const existing_name = if (existing.synthetic_name.len > 0) existing.synthetic_name else self.ast.getText(existing.name);
                    if (primary_binding.kind == .variable_var and existing.kind == .variable_var and
                        existing.scope_id == primary_binding.target_scope and std.mem.eql(u8, existing_name, primary_binding.name))
                    {
                        try self.rebindOutputBinding(primary_binding.first_node, @intCast(existing_raw));
                        for (output_bindings.items[primary_binding.candidate_start + 1 .. primary_binding.candidate_end]) |binding| {
                            try self.rebindOutputBinding(binding.node, @intCast(existing_raw));
                        }
                        binding_groups.items[primary].resolved_id = @intCast(existing_raw);
                        merged_into_existing_var = true;
                    }
                }
            }
        }
        if (!merged_into_existing_var and
            (editor.symbols.items[raw_id].scope_id != primary_binding.target_scope or
                !std.mem.eql(u8, original_name, primary_binding.name)))
        {
            editor.relocateSymbolAs(@enumFromInt(raw_id), primary_binding.target_scope, primary_binding.first_node) catch |err| return editError(err);
        }
        for (group_cursor..group_end) |index| {
            if (index == primary) continue;
            const group = binding_groups.items[index];
            const binding_id = outputSymbolIdAt(self, editor, group.first_node) orelse std.debug.panic("split synthetic binding lost its SymbolId", .{});
            if (binding_id != raw_id) std.debug.panic("split synthetic binding changed SymbolId", .{});
            const new_id = editor.splitBindingIdentity(
                group.first_node,
                @enumFromInt(raw_id),
                group.lexical_scope,
                group.kind,
                self.ast.getNode(group.first_node).span,
            ) catch |err| return editError(err);
            const first_index = @intFromEnum(group.first_node);
            if (self.symbol_ids.items.len <= first_index)
                try self.symbol_ids.appendNTimes(self.allocator, null, first_index + 1 - self.symbol_ids.items.len);
            self.symbol_ids.items[first_index] = @intFromEnum(new_id);
            binding_groups.items[index].resolved_id = @intFromEnum(new_id);
            for (output_bindings.items[group.candidate_start + 1 .. group.candidate_end]) |binding| {
                if (outputSymbolIdAt(self, editor, binding.node) != @as(?u32, raw_id))
                    std.debug.panic("synthetic binding alias changed before split", .{});
                try self.rebindOutputBinding(binding.node, @intFromEnum(new_id));
            }
        }
        group_cursor = group_end;
    }

    for (output_refs.items) |reference| {
        if (reference.raw_id >= editor.symbols.items.len) continue;
        var only_group: ?OutputBindingGroup = null;
        var group_count: usize = 0;
        for (binding_groups.items) |group| {
            if (group.raw_id != reference.raw_id) continue;
            only_group = group;
            group_count += 1;
        }
        if (group_count == 1 and only_group != null and
            !scopeVisibleFrom(editor.scopes.items, editor.symbols.items[only_group.?.resolved_id].scope_id, reference.scope))
        {
            try bridgeOutputReferenceScopeToBinding(editor, editor.symbols.items[only_group.?.resolved_id].scope_id, reference.scope);
        }
        var resolved_id = reference.raw_id;
        var best_distance: usize = std.math.maxInt(usize);
        for (binding_groups.items) |group| {
            if (group.raw_id != reference.raw_id) continue;
            if (lexicalScopeDistance(editor.scopes.items, reference.scope, group.target_scope)) |distance| {
                if (distance < best_distance) {
                    best_distance = distance;
                    resolved_id = group.resolved_id;
                }
            }
        }
        const output_name = outputReferenceName(self.ast, reference.node);
        const is_virtual_enum_member = editor.symbols.items[reference.raw_id].synthetic_kind == .enum_iife_member;
        const lexical_id = if (output_name) |name|
            if (self.runtime_helper_ref_index.contains(@intFromEnum(reference.node)) or is_virtual_enum_member)
                null
            else
                nearestOutputSymbolAtScope(editor, name, reference.scope)
        else
            null;
        if (lexical_id) |id| resolved_id = id;
        const maybe_reference = editor.referenceForNode(reference.node) catch |err| return editError(err);
        if (!scopeVisibleFrom(editor.scopes.items, editor.symbols.items[resolved_id].scope_id, reference.scope)) {
            // The emitted AST can move a declaration behind a function
            // boundary while leaving an old use outside it (for example an
            // unsupported TLA export). That use now resolves as a global
            // reference. Remove the stale source edge and never attach an
            // invisible local SymbolId.
            if (output_name) |name| {
                if (nearestOutputSymbolAtScope(editor, name, reference.scope) == null)
                    try detachInvisibleOutputReferenceAsExternal(self, editor, reference.node, maybe_reference != null);
            }
            continue;
        }
        if (maybe_reference == null) continue;
        editor.relocateReference(
            reference.node,
            reference.scope,
            @enumFromInt(resolved_id),
            Reference.NO_STMT,
            Reference.NO_STMT,
        ) catch |err| {
            if (err != error.ReferenceNotFound) return editError(err);
        };
        const raw = @intFromEnum(reference.node);
        if (self.symbol_ids.items.len <= raw)
            try self.symbol_ids.appendNTimes(self.allocator, null, raw + 1 - self.symbol_ids.items.len);
        self.symbol_ids.items[raw] = resolved_id;
    }
    try self.trackGeneratedLocalSymbols(root, root_scope, generated_catch_specs.items);
}

fn scopeVisibleFrom(scopes: []const @import("../../semantic/scope.zig").Scope, declared: ScopeId, use: ScopeId) bool {
    if (declared.isNone() or use.isNone() or declared.toIndex() >= scopes.len or use.toIndex() >= scopes.len) return false;
    var current = use;
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        if (current == declared) return true;
        if (current.toIndex() >= scopes.len) return false;
        current = scopes[current.toIndex()].parent;
    }
    return false;
}

fn outputReferenceName(ast: *const ast_mod.Ast, node: NodeIndex) ?[]const u8 {
    if (node.isNone() or @intFromEnum(node) >= ast.nodes.items.len) return null;
    const output_node = ast.getNode(node);
    return switch (output_node.tag) {
        .identifier_reference, .assignment_target_identifier, .jsx_identifier => ast.getText(output_node.data.string_ref),
        else => null,
    };
}

fn nearestOutputSymbolAtScope(editor: *SemanticEditor, name: []const u8, start: ScopeId) ?u32 {
    if (start.isNone()) return null;
    const normalized = baseOutputName(name);
    var current = start;
    var hops: usize = 0;
    while (!current.isNone() and hops < editor.scopes.items.len) : (hops += 1) {
        if (current.toIndex() >= editor.scopes.items.len) return null;
        const map = editor.scope_maps.items[current.toIndex()];
        if (map.get(name)) |symbol| return @intCast(symbol);
        if (!std.mem.eql(u8, name, normalized)) {
            if (map.get(normalized)) |symbol| return @intCast(symbol);
        }
        current = editor.scopes.items[current.toIndex()].parent;
    }
    return null;
}

fn baseOutputName(name: []const u8) []const u8 {
    const dollar = std.mem.lastIndexOfScalar(u8, name, '$') orelse return name;
    if (dollar == 0 or dollar + 1 == name.len) return name;
    for (name[dollar + 1 ..]) |c| {
        if (c < '0' or c > '9') return name;
    }
    return name[0..dollar];
}

/// A lowering can extract an output callback beside the source loop scope
/// that owns a binding, even though the callback still closes over that exact
/// binding. Reattach only a sibling output branch when one source identity has
/// a single emitted binding; genuine out-of-scope references stay invalid.
fn bridgeOutputReferenceScopeToBinding(editor: *SemanticEditor, binding_scope: ScopeId, reference_scope: ScopeId) Transformer.Error!void {
    const scopes = editor.scopes.items;
    if (binding_scope.isNone() or reference_scope.isNone() or binding_scope.toIndex() >= scopes.len or reference_scope.toIndex() >= scopes.len)
        return;
    if (scopeVisibleFrom(scopes, binding_scope, reference_scope) or scopeVisibleFrom(scopes, reference_scope, binding_scope)) return;

    var common = reference_scope;
    var hops: usize = 0;
    while (!common.isNone() and hops < scopes.len and !scopeWithin(scopes, binding_scope, common)) : (hops += 1) {
        common = scopes[common.toIndex()].parent;
    }
    if (common.isNone()) return;

    var branch = reference_scope;
    while (scopes[branch.toIndex()].parent != common) {
        branch = scopes[branch.toIndex()].parent;
        if (branch.isNone() or branch.toIndex() >= scopes.len) return;
    }
    editor.reparentScope(branch, binding_scope) catch |err| return editError(err);
}

fn detachInvisibleOutputReferenceAsExternal(
    self: *Transformer,
    editor: *SemanticEditor,
    node: NodeIndex,
    has_reference: bool,
) Transformer.Error!void {
    const raw = @intFromEnum(node);
    if (has_reference) {
        editor.removeReference(node) catch |err| {
            if (err != error.ReferenceNotFound) return editError(err);
        };
    } else if (raw < editor.symbol_ids.items.len) {
        editor.symbol_ids.items[raw] = null;
    }
    if (raw < self.symbol_ids.items.len) self.symbol_ids.items[raw] = null;
    try self.explicit_global_reference_nodes.put(self.allocator, raw, {});
}

fn lexicalScopeDistance(scopes: []const @import("../../semantic/scope.zig").Scope, use: ScopeId, declared: ScopeId) ?usize {
    if (use.isNone() or declared.isNone() or use.toIndex() >= scopes.len or declared.toIndex() >= scopes.len) return null;
    var current = use;
    var distance: usize = 0;
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        if (current == declared) return distance;
        if (current.toIndex() >= scopes.len) return null;
        current = scopes[current.toIndex()].parent;
        distance += 1;
    }
    return null;
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

const GeneratedNodeTrace = struct {
    scope: ScopeId,
    ambiguous_scope: bool = false,
    flags: ReferenceFlags = .{},
};

const GeneratedNodeVisit = struct {
    node: NodeIndex,
    incoming: ScopeId,
    flags: ReferenceFlags = .{},
};

const GeneratedNodeVisitKey = struct { node: u32, scope: u32 };

fn collectGeneratedNodeTraces(self: *Transformer, root: NodeIndex, root_scope: ScopeId) Transformer.Error!std.AutoHashMapUnmanaged(u32, GeneratedNodeTrace) {
    var traces: std.AutoHashMapUnmanaged(u32, GeneratedNodeTrace) = .empty;
    errdefer traces.deinit(self.allocator);
    var visited: std.AutoHashMapUnmanaged(GeneratedNodeVisitKey, void) = .empty;
    defer visited.deinit(self.allocator);
    var stack: std.ArrayList(GeneratedNodeVisit) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .incoming = root_scope });
    while (stack.pop()) |visit| {
        if (visit.node.isNone() or @intFromEnum(visit.node) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(visit.node);
        var scope = visit.incoming;
        const owner_scope = if (self.scope_owner_removed.contains(raw)) null else self.transformed_scope_owner_map.get(raw) orelse
            self.scope_owner_map.get(raw) orelse
            if (self.semantic_editor) |*editor| editor.scope_owner_map.get(raw) else null;
        if (owner_scope) |owner_scope_id| {
            if (owner_scope_id >= (if (self.semantic_editor) |*editor| editor.scopes.items.len else self.scopes.len))
                std.debug.panic("generated reference scope owner is invalid", .{});
            scope = @enumFromInt(owner_scope_id);
        }
        const trace = try traces.getOrPut(self.allocator, raw);
        if (trace.found_existing) {
            if (trace.value_ptr.scope != scope) trace.value_ptr.ambiguous_scope = true;
            trace.value_ptr.flags.read = trace.value_ptr.flags.read or visit.flags.read;
            trace.value_ptr.flags.write = trace.value_ptr.flags.write or visit.flags.write;
        } else {
            trace.value_ptr.* = .{ .scope = scope, .flags = visit.flags };
        }
        const key: GeneratedNodeVisitKey = .{ .node = raw, .scope = @intFromEnum(scope) };
        const prior = try visited.getOrPut(self.allocator, key);
        if (prior.found_existing) continue;
        const parent = self.ast.getNode(visit.node);
        var children = ast_walk.children(self.ast, parent);
        while (children.next()) |child| {
            if (child.isNone() or @intFromEnum(child) >= self.ast.nodes.items.len) continue;
            const child_node = self.ast.getNode(child);
            const flags = if (child_node.tag == .identifier_reference or child_node.tag == .assignment_target_identifier)
                generatedReferenceFlags(parent, child, child_node.tag)
            else
                ReferenceFlags{};
            try stack.append(self.allocator, .{ .node = child, .incoming = scope, .flags = flags });
        }
    }
    return traces;
}

const GeneratedLoopNodeSet = std.AutoHashMapUnmanaged(u32, void);

fn appendGeneratedLoopExtraList(self: *Transformer, stack: *std.ArrayList(NodeIndex), extra_base: u32, start_off: u32, len_off: u32) Transformer.Error!void {
    const extra = self.ast.extra_data.items;
    if (extra_base >= extra.len or start_off >= extra.len - extra_base or len_off >= extra.len - extra_base) return;
    const start = extra[extra_base + start_off];
    const len = extra[extra_base + len_off];
    if (start > extra.len or len > extra.len - start) return;
    for (extra[start .. start + len]) |raw| try stack.append(self.allocator, @enumFromInt(raw));
}

fn collectGeneratedLoopNodes(self: *Transformer, root: NodeIndex) Transformer.Error!GeneratedLoopNodeSet {
    var nodes: GeneratedLoopNodeSet = .empty;
    errdefer nodes.deinit(self.allocator);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |node| {
        if (node.isNone() or @intFromEnum(node) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(node);
        if (nodes.contains(raw)) continue;
        try nodes.put(self.allocator, raw, {});
        const parent = self.ast.getNode(node);
        var children = ast_walk.children(self.ast, parent);
        while (children.next()) |child| try stack.append(self.allocator, child);
        switch (parent.tag) {
            .class_declaration, .class_expression => try appendGeneratedLoopExtraList(self, &stack, parent.data.extra, ast_mod.ClassExtra.deco_start, ast_mod.ClassExtra.deco_len),
            .method_definition => try appendGeneratedLoopExtraList(self, &stack, parent.data.extra, ast_mod.MethodExtra.deco_start, ast_mod.MethodExtra.deco_len),
            .property_definition, .accessor_property => try appendGeneratedLoopExtraList(self, &stack, parent.data.extra, ast_mod.PropertyExtra.deco_start, ast_mod.PropertyExtra.deco_len),
            .formal_parameter => try appendGeneratedLoopExtraList(self, &stack, parent.data.extra, ast_mod.FormalParameterExtra.deco_start, ast_mod.FormalParameterExtra.deco_len),
            .ts_enum_declaration, .flow_enum_declaration => try appendGeneratedLoopExtraList(self, &stack, parent.data.extra, 1, 2),
            .flow_match_expression => {
                const extra = self.ast.extra_data.items;
                if (parent.data.extra < extra.len) try stack.append(self.allocator, @enumFromInt(extra[parent.data.extra]));
                try appendGeneratedLoopExtraList(self, &stack, parent.data.extra, 1, 2);
            },
            else => {},
        }
    }
    return nodes;
}

fn reparentGeneratedLoopScopeFrontiers(self: *Transformer, nodes: *const GeneratedLoopNodeSet, source_nodes: *const GeneratedLoopNodeSet, new_parent: ScopeId) Transformer.Error!GeneratedLoopNodeSet {
    const editor = try editorFor(self);
    var candidates: GeneratedLoopNodeSet = .empty;
    defer candidates.deinit(self.allocator);
    var owners = nodes.keyIterator();
    while (owners.next()) |raw| {
        const origin = self.scope_owner_origins.get(raw.*) orelse raw.*;
        if (!source_nodes.contains(origin)) continue;
        const owner_scope = self.transformed_scope_owner_map.get(raw.*) orelse editor.scope_owner_map.get(raw.*) orelse self.scope_owner_map.get(raw.*) orelse continue;
        const scope: ScopeId = @enumFromInt(owner_scope);
        if (scope == new_parent or scopeWithin(editor.scopes.items, scope, new_parent)) continue;
        if (scope.isNone() or scope.toIndex() >= editor.scopes.items.len) std.debug.panic("generated loop scope owner is invalid", .{});
        try candidates.put(self.allocator, scope.toIndex(), {});
    }
    var frontiers: GeneratedLoopNodeSet = .empty;
    errdefer frontiers.deinit(self.allocator);
    var roots = candidates.keyIterator();
    while (roots.next()) |raw| {
        var parent = editor.scopes.items[raw.*].parent;
        var has_candidate_ancestor = false;
        while (!parent.isNone()) {
            if (candidates.contains(parent.toIndex())) {
                has_candidate_ancestor = true;
                break;
            }
            parent = editor.scopes.items[parent.toIndex()].parent;
        }
        if (has_candidate_ancestor) continue;
        try frontiers.put(self.allocator, raw.*, {});
        editor.reparentScope(@enumFromInt(raw.*), new_parent) catch |err| return editError(err);
    }
    return frontiers;
}

/// Reconcile the source body first, then its lowered state callback. Header
/// parameters get fresh identities; every copied reference uses its recorded
/// source node and the final AST scope trace.
pub fn migrateGeneratorLoopBody(self: *Transformer, original_body: NodeIndex, final_body: NodeIndex, output_function_scope: ScopeId, output_body_scope: ScopeId, reparent_from_scope: ScopeId, header_symbol_ids: []const u32, parameter_symbol_ids: []const u32) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (header_symbol_ids.len != parameter_symbol_ids.len)
        std.debug.panic("generator loop parameter migration arity mismatch", .{});
    const editor = try editorFor(self);

    var source_nodes = try collectGeneratedLoopNodes(self, original_body);
    defer source_nodes.deinit(self.allocator);
    // Lowering a source binding into an assignment target creates a reference
    // from the binding node itself, so it has no source-reference origin. Keep
    // those writes exact by accepting their SymbolId only when this source
    // body contains the corresponding binding declaration.
    var source_binding_ids: GeneratedLoopNodeSet = .empty;
    defer source_binding_ids.deinit(self.allocator);
    var source_binding_nodes = source_nodes.keyIterator();
    while (source_binding_nodes.next()) |raw| {
        const node: NodeIndex = @enumFromInt(raw.*);
        if (self.ast.getNode(node).tag != .binding_identifier) continue;
        if (self.getSymbolIdAt(node)) |id| try source_binding_ids.put(self.allocator, id, {});
    }
    var final_nodes = try collectGeneratedLoopNodes(self, final_body);
    defer final_nodes.deinit(self.allocator);
    var moved_scope_frontiers = try reparentGeneratedLoopScopeFrontiers(self, &final_nodes, &source_nodes, output_body_scope);
    defer moved_scope_frontiers.deinit(self.allocator);

    var traces = try collectGeneratedNodeTraces(self, final_body, output_body_scope);
    defer traces.deinit(self.allocator);
    const runtime_refs = try reference_walk.collectIdentifierReferences(self.allocator, self.ast, final_body);
    defer self.allocator.free(runtime_refs);
    var live_symbol_ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live_symbol_ids.deinit(self.allocator);
    for (runtime_refs) |node| {
        const raw = @intFromEnum(node);
        const origin = self.reference_origin_map.get(raw) orelse raw;
        const id = self.getSymbolIdAt(node) orelse continue;
        if (!source_nodes.contains(origin) and !source_binding_ids.contains(id)) continue;
        try live_symbol_ids.put(self.allocator, id, {});
    }

    // A lowering-created function-scoped temp can be hoisted before a captured
    // generator loop is extracted. Its exact binding then remains in the
    // enclosing function even though every surviving use is now inside the
    // extracted function. Move only such exact synthetic identities, and only
    // when all live uses are within this output function.
    var live_symbols = live_symbol_ids.keyIterator();
    while (live_symbols.next()) |raw_id| {
        if (raw_id.* >= editor.symbols.items.len) continue;
        const symbol = editor.symbols.items[raw_id.*];
        if (symbol.synthetic_name.len == 0 or symbol.kind != .variable_var or symbol.scope_id.isNone() or
            symbol.scope_id.toIndex() >= editor.scopes.items.len or symbol.scope_id == output_function_scope or
            !editor.scopes.items[symbol.scope_id.toIndex()].kind.isVarScope()) continue;
        var needs_move = false;
        var all_uses_in_output = true;
        for (runtime_refs) |node| {
            const current_id = self.getSymbolIdAt(node) orelse continue;
            if (current_id != raw_id.*) continue;
            const raw = @intFromEnum(node);
            const origin = self.reference_origin_map.get(raw) orelse raw;
            if (!source_nodes.contains(origin) and !source_binding_ids.contains(raw_id.*)) continue;
            const trace = traces.get(raw) orelse std.debug.panic("generator loop reference has no final scope trace", .{});
            if (trace.ambiguous_scope) std.debug.panic("generator loop reference has ambiguous output scopes", .{});
            if (!scopeWithin(editor.scopes.items, trace.scope, symbol.scope_id)) needs_move = true;
            if (!scopeWithin(editor.scopes.items, trace.scope, output_function_scope)) all_uses_in_output = false;
        }
        if (!needs_move or !all_uses_in_output) continue;

        var binding_node: ?NodeIndex = null;
        for (self.symbol_ids.items, 0..) |maybe_id, node_raw| {
            if (maybe_id == null or maybe_id.? != raw_id.* or node_raw >= self.ast.nodes.items.len) continue;
            const candidate: NodeIndex = @enumFromInt(node_raw);
            if (self.ast.getNode(candidate).tag != .binding_identifier) continue;
            binding_node = candidate;
            if (final_nodes.contains(@intCast(node_raw))) break;
        }
        const binding = binding_node orelse std.debug.panic("live extracted loop temp has no output binding node", .{});
        editor.relocateSymbolAs(@enumFromInt(raw_id.*), output_function_scope, binding) catch |err| return editError(err);
    }

    var moved_bindings: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer moved_bindings.deinit(self.allocator);
    var source_nodes_it = source_nodes.keyIterator();
    while (source_nodes_it.next()) |raw| {
        const node: NodeIndex = @enumFromInt(raw.*);
        if (self.ast.getNode(node).tag != .binding_identifier) continue;
        const id_raw = self.getSymbolIdAt(node) orelse continue;
        if (id_raw >= editor.symbols.items.len) std.debug.panic("generator loop binding has an invalid SymbolId", .{});
        if (!live_symbol_ids.contains(id_raw)) continue;
        if (std.mem.indexOfScalar(u32, header_symbol_ids, id_raw) != null) continue;
        const traced_binding_scope = if (final_nodes.contains(raw.*)) blk: {
            const trace = traces.get(raw.*) orelse std.debug.panic("generator loop binding has no final scope trace", .{});
            if (trace.ambiguous_scope) std.debug.panic("generator loop binding has ambiguous output scopes", .{});
            break :blk trace.scope;
        } else output_function_scope;
        // Some declaration nodes own a function-body scope while their name
        // binding remains in the enclosing lexical scope. Keep the existing
        // binding scope when it is still visible from the traced output site.
        const original_binding_scope = editor.symbols.items[id_raw].scope_id;
        const binding_scope = if (scopeWithin(editor.scopes.items, traced_binding_scope, original_binding_scope))
            original_binding_scope
        else
            traced_binding_scope;
        if (moved_bindings.get(id_raw)) |prior_scope| {
            if (prior_scope != @intFromEnum(binding_scope))
                std.debug.panic("one generator loop binding has multiple output scopes", .{});
            continue;
        }
        try moved_bindings.put(self.allocator, id_raw, @intFromEnum(binding_scope));
        const id: SymbolId = @enumFromInt(id_raw);
        if (editor.symbols.items[id_raw].scope_id != binding_scope)
            editor.relocateSymbolAs(id, binding_scope, node) catch |err| return editError(err);
    }
    var original_references: std.AutoHashMapUnmanaged(u32, Reference) = .empty;
    defer original_references.deinit(self.allocator);
    for (self.references) |reference| {
        if (reference.node_index.isNone()) continue;
        try original_references.put(self.allocator, @intFromEnum(reference.node_index), reference);
    }

    var live_refs: GeneratedLoopNodeSet = .empty;
    defer live_refs.deinit(self.allocator);
    for (runtime_refs) |node| {
        const raw = @intFromEnum(node);
        const origin = self.reference_origin_map.get(raw) orelse raw;
        const current_id = self.getSymbolIdAt(node) orelse continue;
        if (!source_nodes.contains(origin) and !source_binding_ids.contains(current_id)) continue;
        try live_refs.put(self.allocator, raw, {});
        if (current_id >= editor.symbols.items.len) std.debug.panic("generator loop reference has an invalid SymbolId", .{});
        var target_id = current_id;
        for (header_symbol_ids, parameter_symbol_ids) |header_id, parameter_id| {
            if (current_id == header_id) {
                target_id = parameter_id;
                break;
            }
        }
        const trace = traces.get(raw) orelse std.debug.panic("generator loop reference has no final scope trace", .{});
        if (trace.ambiguous_scope) std.debug.panic("generator loop reference has ambiguous output scopes", .{});
        const output_scope = trace.scope;
        const target: SymbolId = @enumFromInt(target_id);
        const maybe_reference = editor.referenceForNode(node) catch |err| return editError(err);
        if (maybe_reference) |reference| {
            // The source Reference can still carry a pre-extraction scope that
            // remains an ancestor of the binding, yet no longer matches the
            // final AST owner (for example, a nested arrow inside a moved catch).
            if (reference.scope_id != output_scope or reference.symbol_id != target) {
                editor.relocateReference(node, output_scope, target, reference.stmt_idx, reference.scope_stmt_idx) catch |err| return editError(err);
            }
        } else {
            const metadata = original_references.get(origin);
            const flags = if (metadata) |reference| reference.flags else trace.flags;
            const reference_scope = if (metadata != null and
                scopeWithin(editor.scopes.items, metadata.?.scope_id, editor.symbols.items[target_id].scope_id))
                metadata.?.scope_id
            else
                output_scope;
            if (!flags.read and !flags.write) std.debug.panic("generated loop reference has no access-mode evidence", .{});
            if (raw < editor.symbol_ids.items.len and editor.symbol_ids.items[raw] != null and editor.symbol_ids.items[raw] != target_id)
                editor.symbol_ids.items[raw] = null;
            editor.addCopiedReference(node, target, reference_scope, flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        }
        if (self.symbol_ids.items.len <= raw)
            try self.symbol_ids.appendNTimes(self.allocator, null, raw + 1 - self.symbol_ids.items.len);
        self.symbol_ids.items[raw] = target_id;
    }

    var old_nodes = source_nodes.keyIterator();
    while (old_nodes.next()) |raw| {
        if (live_refs.contains(raw.*)) continue;
        const node: NodeIndex = @enumFromInt(raw.*);
        const reference = editor.referenceForNode(node) catch |err| return editError(err);
        if (reference == null) continue;
        editor.removeReference(node) catch |err| return editError(err);
        if (raw.* < self.symbol_ids.items.len) self.symbol_ids.items[raw.*] = null;
    }

    // A lowered loop head can be emitted in the extracted generator function
    // even though its binding node is outside the source body subtree. Source
    // loop scopes reparented with the body have the same treatment. Move only
    // exact live identities whose output binding remains outside that body.
    var live_ids = live_symbol_ids.keyIterator();
    while (live_ids.next()) |raw_id| {
        if (std.mem.indexOfScalar(u32, header_symbol_ids, raw_id.*) != null) continue;
        if (raw_id.* >= editor.symbols.items.len) continue;
        const source_binding_scope = editor.symbols.items[raw_id.*].scope_id;
        if (source_binding_scope.isNone() or source_binding_scope.toIndex() >= editor.scopes.items.len or
            editor.scopes.items[source_binding_scope.toIndex()].kind.isVarScope()) continue;
        const is_call_scope_binding = source_binding_scope == reparent_from_scope;
        if (!is_call_scope_binding and !moved_scope_frontiers.contains(source_binding_scope.toIndex())) continue;
        var binding_node: ?NodeIndex = null;
        var binding_node_is_in_source = false;
        for (self.symbol_ids.items, 0..) |maybe_id, node_raw| {
            if (maybe_id == null or maybe_id.? != raw_id.* or node_raw >= self.ast.nodes.items.len) continue;
            const candidate: NodeIndex = @enumFromInt(node_raw);
            if (self.ast.getNode(candidate).tag == .binding_identifier) {
                binding_node = candidate;
                binding_node_is_in_source = source_nodes.contains(@intCast(node_raw));
                if (binding_node_is_in_source) break;
            }
        }
        if (binding_node_is_in_source and !is_call_scope_binding) continue;
        const binding = binding_node orelse std.debug.panic("live extracted loop binding has no output binding node", .{});
        editor.relocateSymbolAs(@enumFromInt(raw_id.*), output_function_scope, binding) catch |err| return editError(err);
    }
}

fn generatedReferenceFlags(parent: Node, child: NodeIndex, child_tag: Node.Tag) ReferenceFlags {
    if (child_tag == .assignment_target_identifier) return .{ .write = true };
    if (parent.tag == .assignment_expression and parent.data.binary.left == child) {
        const op: token_mod.Kind = @enumFromInt(parent.data.binary.flags);
        return if (op.isCompoundAssignment()) .{ .read = true, .write = true } else .{ .write = true };
    }
    if (parent.tag == .update_expression) return .{ .read = true, .write = true };
    return .{ .read = true };
}

/// In-place for-await refs can be copied while the generator body is lowered.
/// Reconcile only producer-recorded synthetic SymbolIds, using final AST scope
/// and access mode; never resolve a binding from emitted text.
fn bindGeneratorStateReferences(self: *Transformer, source_scope: ScopeId, callback_scope: ScopeId, callback: NodeIndex, live: *const std.AutoHashMapUnmanaged(u32, void), live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!void {
    if (source_scope.isNone() or self.generator_state_semantic_refs.items.len == 0) return;
    const editor = try editorFor(self);
    var ids: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer ids.deinit(self.allocator);
    for (self.generator_state_semantic_refs.items) |pending| {
        if (!scopeWithin(editor.scopes.items, pending.scope, source_scope)) continue;
        try ids.put(self.allocator, pending.symbol_id, {});
        _ = try generatedTempRefScope(self, source_scope, callback_scope, pending.scope, live_scopes);
    }
    if (ids.count() == 0) return;

    var traces = try collectGeneratedNodeTraces(self, callback, callback_scope);
    defer traces.deinit(self.allocator);
    var entries = traces.iterator();
    while (entries.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= self.symbol_ids.items.len) continue;
        if (!ids.contains(self.symbol_ids.items[raw] orelse continue)) continue;
        const trace = entry.value_ptr.*;
        if (trace.ambiguous_scope) std.debug.panic("generated state reference has ambiguous output scopes", .{});
        const node: NodeIndex = @enumFromInt(raw);
        const node_tag = self.ast.getNode(node).tag;
        if (node_tag != .identifier_reference and node_tag != .assignment_target_identifier) continue;
        if (!trace.flags.read and !trace.flags.write) std.debug.panic("generated state reference has no access mode", .{});
        const id: SymbolId = @enumFromInt(self.symbol_ids.items[raw].?);
        const maybe_reference = editor.referenceForNode(node) catch |err| return editError(err);
        if (maybe_reference) |reference| {
            editor.relocateReference(node, trace.scope, id, reference.stmt_idx, reference.scope_stmt_idx) catch |err| return editError(err);
        } else {
            editor.addCopiedReference(node, id, trace.scope, trace.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        }
    }

    var kept: usize = 0;
    for (self.generator_state_semantic_refs.items) |pending| {
        if (ids.contains(pending.symbol_id) and scopeWithin(editor.scopes.items, pending.scope, source_scope)) continue;
        self.generator_state_semantic_refs.items[kept] = pending;
        kept += 1;
    }
    self.generator_state_semantic_refs.shrinkRetainingCapacity(kept);
    _ = live;
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

pub const GeneratedLocalSpec = struct {
    name: []const u8,
    kind: SymbolKind,
    /// Some emitted declaration forms own a name in their parent scope even
    /// though their AST node also owns a function-body scope.
    binding_scope: ScopeId = .none,
    /// When set, only the generated binding with this exact name span can
    /// satisfy the spec. References still resolve by lexical name and scope.
    exact_binding_span: ?Span = null,
};

/// Add the exact temporary names allocated during one function transform.
/// The completed tree then binds emitted declarations and their unresolved
/// generated uses using the real output-scope ancestry.
pub fn appendGeneratedTempSpecs(self: *Transformer, start_counter: u32, specs: *std.ArrayListUnmanaged(GeneratedLocalSpec)) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    var counter = start_counter;
    while (counter < self.temp_var_counter) : (counter += 1) {
        const name_span = self.temp_span_by_counter.get(counter) orelse continue;
        try specs.append(self.allocator, .{ .name = self.ast.getText(name_span), .kind = .variable_var });
    }
}

/// Complete output ownership for generated function boundaries before binding
/// deferred generator callback parameters. Some per-iteration generators are
/// only fully placed after their enclosing state machine has been assembled.
/// Pass 2 lowers parameter defaults into function bodies and records reads in
/// their output scope. Generated function owners must therefore have scopes
/// before that pass, rather than only during final symbol completion.
pub fn registerGeneratedFunctionScopes(self: *Transformer, root: NodeIndex, root_scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const Work = struct { node: NodeIndex, scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .scope = root_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone() or @intFromEnum(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        var scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (isFunctionBoundary(node.tag) and self.outputOwnedScope(work.node) == null and raw >= self.parser_node_count) {
            scope = try self.addGeneratedFunctionScope(work.scope, work.node);
        }
        var it = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (it.next()) |child| {
            const child_scope = if (childSkipsOutputScope(self.ast, raw, @intFromEnum(child))) work.scope else scope;
            try stack.append(self.allocator, .{ .node = child, .scope = child_scope });
        }
    }
}

pub fn completeGeneratedStateSymbols(self: *Transformer, root: NodeIndex, root_scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const Work = struct { node: NodeIndex, scope: ScopeId };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    var state_specs: std.ArrayListUnmanaged(GeneratedLocalSpec) = .empty;
    defer state_specs.deinit(self.allocator);
    var function_name_specs: std.ArrayListUnmanaged(GeneratedLocalSpec) = .empty;
    defer function_name_specs.deinit(self.allocator);
    var state_names: std.StringHashMapUnmanaged(void) = .empty;
    defer state_names.deinit(self.allocator);
    var temp_specs: std.ArrayListUnmanaged(GeneratedLocalSpec) = .empty;
    defer temp_specs.deinit(self.allocator);
    var temp_spans: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer temp_spans.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .scope = root_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone() or @intFromEnum(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        var scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (node.tag == .variable_declaration) {
            const declaration_kind = self.ast.variableDeclarationKind(node);
            const symbol_kind: SymbolKind = switch (declaration_kind) {
                .@"var" => .variable_var,
                .let => .variable_let,
                .@"const", .using, .await_using => .variable_const,
            };
            const declarations_start = self.readU32(node.data.extra, 1);
            const declarations_len = self.readU32(node.data.extra, 2);
            var i: u32 = 0;
            while (i < declarations_len) : (i += 1) {
                const declaration_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[declarations_start + i]);
                const declaration = self.ast.getNode(declaration_idx);
                if (declaration.tag != .variable_declarator) continue;
                const binding_idx = self.readNodeIdx(declaration.data.extra, 0);
                if (binding_idx.isNone() or @intFromEnum(binding_idx) < self.parser_node_count) continue;
                const binding = self.ast.getNode(binding_idx);
                if (binding.tag != .binding_identifier or !isGeneratedTempSpan(self, binding.data.string_ref)) continue;
                const span_key = (@as(u64, binding.data.string_ref.start) << 32) | binding.data.string_ref.end;
                const gop = try temp_spans.getOrPut(self.allocator, span_key);
                if (!gop.found_existing) try temp_specs.append(self.allocator, .{
                    .name = self.ast.getText(binding.data.string_ref),
                    .kind = symbol_kind,
                    .exact_binding_span = binding.data.string_ref,
                });
            }
        }
        if (isFunctionBoundary(node.tag)) {
            if (self.outputOwnedScope(work.node) == null and raw >= self.parser_node_count) {
                scope = try self.addGeneratedFunctionScope(work.scope, work.node);
            }
            if (node.tag == .function_expression or node.tag == .function_declaration) {
                const extra = node.data.extra;
                if (extra + 3 < self.ast.extra_data.items.len) {
                    const name: NodeIndex = @enumFromInt(self.ast.extra_data.items[extra]);
                    if (!name.isNone() and @intFromEnum(name) >= self.parser_node_count and
                        self.ast.getNode(name).tag == .binding_identifier and self.getSymbolIdAt(name) == null)
                    {
                        const name_span = self.ast.getNode(name).data.string_ref;
                        if (name_span.start & ast_mod.Ast.STRING_TABLE_BIT != 0) {
                            const flags = self.ast.extra_data.items[extra + 3];
                            try function_name_specs.append(self.allocator, .{
                                .name = self.ast.getText(name_span),
                                .kind = generatedFunctionNameKind(flags),
                                .binding_scope = if (node.tag == .function_expression) scope else work.scope,
                                .exact_binding_span = name_span,
                            });
                        }
                    }
                }
            }
            if (self.deferred_generator_helper_refs.fetchRemove(raw)) |deferred| {
                try self.relocatePendingRuntimeHelperRef(deferred.value, scope);
            }
            const params = self.ast.functionParamsList(node);
            for (self.ast.extra_data.items[params.start .. params.start + params.len]) |param_raw| {
                const param: NodeIndex = @enumFromInt(param_raw);
                if (param.isNone() or @intFromEnum(param) < self.parser_node_count) continue;
                const binding_node = self.ast.getNode(param);
                if (binding_node.tag != .binding_identifier) continue;
                const name = self.ast.getText(binding_node.data.string_ref);
                if (!std.mem.startsWith(u8, name, "_state")) continue;
                const gop = try state_names.getOrPut(self.allocator, name);
                if (!gop.found_existing) try state_specs.append(self.allocator, .{ .name = name, .kind = .parameter });
            }
        }
        var it = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (it.next()) |child| {
            const child_scope = if (childSkipsOutputScope(self.ast, raw, @intFromEnum(child))) work.scope else scope;
            try stack.append(self.allocator, .{ .node = child, .scope = child_scope });
        }
    }
    var deferred_captures = self.deferred_capture_function_owners.iterator();
    while (deferred_captures.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (!seen.contains(raw)) continue;
        const owner: NodeIndex = @enumFromInt(raw);
        const scope = self.outputOwnedScope(owner) orelse std.debug.panic("deferred capture function has no output scope", .{});
        try es_helpers.trackThisArgumentsCaptureSymbols(self, owner, scope);
    }
    self.deferred_capture_function_owners.clearRetainingCapacity();
    self.deferred_generator_helper_refs.clearRetainingCapacity();
    try self.trackGeneratedLocalSymbols(root, root_scope, function_name_specs.items);
    try self.trackGeneratedLocalSymbols(root, root_scope, state_specs.items);
    try self.trackGeneratedLocalSymbols(root, root_scope, temp_specs.items);
}

fn generatedFunctionNameKind(flags: u32) SymbolKind {
    const is_async = (flags & ast_mod.FunctionFlags.is_async) != 0;
    const is_generator = (flags & ast_mod.FunctionFlags.is_generator) != 0;
    return if (is_async and is_generator)
        .async_generator_decl
    else if (is_async)
        .async_function_decl
    else if (is_generator)
        .generator_decl
    else
        .function_decl;
}

fn isGeneratedTempSpan(self: *Transformer, span: Span) bool {
    for (self.generated_temp_spans.items) |known| {
        if (known.start == span.start and known.end == span.end) return true;
    }
    return false;
}

fn isFunctionBoundary(tag: @import("../../parser/ast.zig").Node.Tag) bool {
    return switch (tag) {
        .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => true,
        else => false,
    };
}

/// Bind generated locals and unresolved uses inside one completed output tree.
/// Scope ancestry chooses the nearest binding, so nested generated functions
/// can safely reuse a reserved name such as `_this`.
pub fn trackGeneratedLocalSymbols(self: *Transformer, root: NodeIndex, root_scope: ScopeId, specs: []const GeneratedLocalSpec) Transformer.Error!void {
    if (!self.semantic_edit_enabled or specs.len == 0) return;
    const Binding = struct { node: NodeIndex, scope: ScopeId, id: SymbolId, name: []const u8, name_span: Span };
    const Ref = struct { node: NodeIndex, scope: ScopeId, name: []const u8, name_span: Span };
    const Work = struct { node: NodeIndex, scope: ScopeId };
    var bindings: std.ArrayList(Binding) = .empty;
    defer bindings.deinit(self.allocator);
    var refs: std.ArrayList(Ref) = .empty;
    defer refs.deinit(self.allocator);
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    try stack.append(self.allocator, .{ .node = root, .scope = root_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone() or @intFromEnum(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        const scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (node.tag == .binding_identifier) {
            const name = self.ast.getText(node.data.string_ref);
            if (generatedLocalSpecForBinding(specs, name, node.data.string_ref)) |spec| {
                const binding_scope = if (spec.binding_scope.isNone()) scope else spec.binding_scope;
                const symbol_scope = if (spec.kind == .variable_var) self.nearestVarScope(binding_scope) else binding_scope;
                var id: ?SymbolId = if (self.getSymbolIdAt(work.node)) |raw_id|
                    @enumFromInt(raw_id)
                else
                    null;
                if (id == null) {
                    for (bindings.items) |existing| {
                        if (existing.scope == symbol_scope and std.mem.eql(u8, existing.name, name)) {
                            id = existing.id;
                            break;
                        }
                    }
                }
                if (id == null and !binding_scope.isNone()) {
                    const editor = try editorFor(self);
                    if (!symbol_scope.isNone() and symbol_scope.toIndex() < editor.scope_maps.items.len) {
                        if (editor.scope_maps.items[symbol_scope.toIndex()].get(name)) |raw_id| {
                            if (raw_id < editor.symbols.items.len) {
                                const existing = editor.symbols.items[raw_id];
                                if (existing.scope_id == symbol_scope and existing.kind == spec.kind and
                                    std.mem.eql(u8, existing.synthetic_name, name))
                                {
                                    id = @enumFromInt(raw_id);
                                }
                            }
                        }
                    }
                }
                if (id == null) {
                    id = try self.declareSyntheticInScope(work.node, node.span, spec.kind, binding_scope);
                }
                const symbol = id orelse continue;
                if (self.getSymbolIdAt(work.node) == null) try self.setGeneratedSymbolId(work.node, @intFromEnum(symbol));
                const editor = try editorFor(self);
                if (@intFromEnum(symbol) >= editor.symbols.items.len) std.debug.panic("generated local symbol is out of range", .{});
                try bindings.append(self.allocator, .{
                    .node = work.node,
                    .scope = editor.symbols.items[@intFromEnum(symbol)].scope_id,
                    .id = symbol,
                    .name = name,
                    .name_span = node.data.string_ref,
                });
            }
        } else if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
            const name = self.ast.getText(node.data.string_ref);
            const exact_temp_ref = generatedLocalExactBindingSpanTracked(specs, name, node.data.string_ref);
            if (generatedLocalNameTracked(specs, name) and (self.getSymbolIdAt(work.node) == null or exact_temp_ref))
                try refs.append(self.allocator, .{ .node = work.node, .scope = scope, .name = name, .name_span = node.data.string_ref });
        }
        var it = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (it.next()) |child| {
            const child_scope = if (childSkipsOutputScope(self.ast, raw, @intFromEnum(child))) work.scope else scope;
            try stack.append(self.allocator, .{ .node = child, .scope = child_scope });
        }
    }

    const semantic_editor = try editorFor(self);
    for (refs.items) |ref| {
        var best: ?Binding = null;
        var best_distance: usize = std.math.maxInt(usize);
        var exact: ?Binding = null;
        var exact_ambiguous = false;
        var lexical_binding: ?Binding = null;
        if (nearestOutputSymbolAtScope(semantic_editor, ref.name, ref.scope)) |raw_id| {
            if (raw_id < semantic_editor.symbols.items.len) {
                lexical_binding = .{
                    .node = .none,
                    .scope = semantic_editor.symbols.items[raw_id].scope_id,
                    .id = @enumFromInt(raw_id),
                    .name = ref.name,
                    .name_span = ref.name_span,
                };
            }
        }
        for (bindings.items) |binding| {
            if (!std.mem.eql(u8, binding.name, ref.name)) continue;
            if (binding.name_span.start == ref.name_span.start and binding.name_span.end == ref.name_span.end) {
                if (exact) |existing| {
                    if (existing.id != binding.id) exact_ambiguous = true;
                } else {
                    exact = binding;
                }
            }
            const distance = scopeDistance(self, ref.scope, binding.scope) orelse continue;
            if (distance < best_distance) {
                best = binding;
                best_distance = distance;
            }
        }
        const binding = if (lexical_binding) |found|
            found
        else if (best) |found|
            found
        else if (exact_ambiguous)
            continue
        else
            exact orelse continue;
        const node = self.ast.getNode(ref.node);
        const flags: ReferenceFlags = if (node.tag == .assignment_target_identifier)
            .{ .write = true }
        else
            .{ .read = true };
        const reference_scope = if (lexical_binding != null or best != null) ref.scope else binding.scope;
        if (self.getSymbolIdAt(ref.node) != null) {
            const editor = try editorFor(self);
            editor.relocateReference(ref.node, reference_scope, binding.id, Reference.NO_STMT, Reference.NO_STMT) catch |err| {
                if (err == error.ReferenceNotFound) {
                    try self.setGeneratedSymbolId(ref.node, @intFromEnum(binding.id));
                    try self.addSyntheticRefInScope(ref.node, binding.id, reference_scope, flags);
                    continue;
                }
                return editError(err);
            };
            try self.setGeneratedSymbolId(ref.node, @intFromEnum(binding.id));
        } else {
            try self.addSyntheticRefInScope(ref.node, binding.id, reference_scope, flags);
        }
    }
}

fn generatedLocalSpec(specs: []const GeneratedLocalSpec, name: []const u8) ?GeneratedLocalSpec {
    for (specs) |spec| if (std.mem.eql(u8, spec.name, name)) return spec;
    return null;
}

fn generatedLocalSpecForBinding(specs: []const GeneratedLocalSpec, name: []const u8, span: Span) ?GeneratedLocalSpec {
    for (specs) |spec| {
        if (!std.mem.eql(u8, spec.name, name)) continue;
        if (spec.exact_binding_span) |expected| {
            if (expected.start != span.start or expected.end != span.end) continue;
        }
        return spec;
    }
    return null;
}

fn generatedLocalNameTracked(specs: []const GeneratedLocalSpec, name: []const u8) bool {
    return generatedLocalSpec(specs, name) != null;
}

fn generatedLocalExactBindingSpanTracked(specs: []const GeneratedLocalSpec, name: []const u8, span: Span) bool {
    for (specs) |spec| {
        if (!std.mem.eql(u8, spec.name, name)) continue;
        if (spec.exact_binding_span) |expected| {
            if (expected.start == span.start and expected.end == span.end) return true;
        }
    }
    return false;
}

fn scopeDistance(self: *Transformer, scope: ScopeId, ancestor: ScopeId) ?usize {
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (scope.isNone() or ancestor.isNone() or scope.toIndex() >= scopes.len or ancestor.toIndex() >= scopes.len) return null;
    var cursor = scope;
    var distance: usize = 0;
    var hops: usize = 0;
    while (!cursor.isNone() and hops < scopes.len) : (hops += 1) {
        if (cursor == ancestor) return distance;
        cursor = scopes[cursor.toIndex()].parent;
        distance += 1;
    }
    return null;
}

fn generatedTempRefScope(self: *Transformer, source_scope: ScopeId, target_scope: ScopeId, old_scope: ScopeId, live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!ScopeId {
    const editor = try editorFor(self);
    if (old_scope == source_scope) return target_scope;
    if (scopeWithin(editor.scopes.items, old_scope, target_scope)) return old_scope;
    if (!scopeWithin(editor.scopes.items, old_scope, source_scope)) {
        if (self.deferred_generator_loop_migrations.get(@intFromEnum(old_scope))) |migration| {
            if (!migration.function_reparented) return target_scope;
        }
        // Some generated statements in a relocated body retain a reference
        // scope from an outer owner (for example, an inner async-generator
        // body lowered from its enclosing async function). If the old scope
        // is a strict ancestor of the source body, the reference is still
        // live inside the callback AST and belongs to the emitted callback.
        // Route that reference there without moving the ancestor scope itself.
        // Sibling scopes, including parameter-default arrows, remain invalid.
        if (scopeWithin(editor.scopes.items, source_scope, old_scope)) return target_scope;
        std.debug.panic("generated temp reference has unrelated source scope", .{});
    }

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

fn stateTempOutputScope(self: *Transformer, source_scope: ScopeId, target_scope: ScopeId, binding_scope: ScopeId, old_scope: ScopeId, traced_scope: ScopeId, live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!ScopeId {
    const editor = try editorFor(self);
    if (old_scope == source_scope or scopeWithin(editor.scopes.items, old_scope, source_scope) or
        scopeWithin(editor.scopes.items, old_scope, target_scope))
        return generatedTempRefScope(self, source_scope, target_scope, old_scope, live_scopes);
    if (scopeWithin(editor.scopes.items, traced_scope, binding_scope)) return traced_scope;
    if (scopeWithin(editor.scopes.items, target_scope, binding_scope)) return target_scope;
    std.debug.panic("generated state temp has no visible output scope", .{});
}

fn bindStateCallbackTemp(self: *Transformer, temp: @import("lists.zig").HoistedStateTemp, declaration_span: Span, source_scope: ScopeId, binding_scope: ScopeId, callback_scope: ScopeId, live: *const std.AutoHashMapUnmanaged(u32, void), live_scopes: *const std.AutoHashMapUnmanaged(u32, void), traces: *const std.AutoHashMapUnmanaged(u32, GeneratedNodeTrace)) Transformer.Error!void {
    const chain = self.pending_temp_ref_chains.fetchRemove(temp.name_span.start);
    const editor = try editorFor(self);
    const id: SymbolId = if (temp.symbol_id) |raw_id| blk: {
        const existing: SymbolId = @enumFromInt(raw_id);
        editor.relocateSymbolAs(existing, binding_scope, temp.binding) catch |err| return editError(err);
        break :blk existing;
    } else blk: {
        const declared = editor.declare(temp.binding, temp.name_span, declaration_span, binding_scope, .variable_var, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        try setSymbolId(self, temp.binding, declared);
        break :blk declared;
    };

    if (temp.symbol_id) |raw_id| {
        var nodes = live.iterator();
        while (nodes.next()) |entry| {
            const raw_node = entry.key_ptr.*;
            if (raw_node >= self.symbol_ids.items.len or self.symbol_ids.items[raw_node] != raw_id) continue;
            const node: NodeIndex = @enumFromInt(raw_node);
            switch (self.ast.getNode(node).tag) {
                .identifier_reference, .assignment_target_identifier => {},
                else => continue,
            }
            const maybe_reference = editor.referenceForNode(node) catch |err| return editError(err);
            const reference = maybe_reference orelse continue;
            const trace = traces.get(raw_node) orelse std.debug.panic("generated temp reference has no final scope trace", .{});
            if (trace.ambiguous_scope) std.debug.panic("generated temp reference has ambiguous output scopes", .{});
            const target = try stateTempOutputScope(self, source_scope, callback_scope, binding_scope, reference.scope_id, trace.scope, live_scopes);
            if (target != reference.scope_id) {
                editor.relocateReference(node, target, id, reference.stmt_idx, reference.scope_stmt_idx) catch |err| return editError(err);
            }
        }
    }

    var i: ?usize = if (chain) |found| found.value.first else null;
    while (i) |index| {
        const ref = self.pending_temp_refs.items[index];
        std.debug.assert(ref.name_start == temp.name_span.start);
        if (live.contains(@intFromEnum(ref.node))) {
            const trace = traces.get(@intFromEnum(ref.node)) orelse std.debug.panic("generated temp reference has no final scope trace", .{});
            if (trace.ambiguous_scope) std.debug.panic("generated temp reference has ambiguous output scopes", .{});
            const scope = try stateTempOutputScope(self, source_scope, callback_scope, binding_scope, ref.scope, trace.scope, live_scopes);
            editor.addReference(ref.node, id, scope, ref.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
            try setSymbolId(self, ref.node, id);
        }
        i = ref.next;
    }
    if (self.pending_temp_ref_chains.count() == 0) self.pending_temp_refs.clearRetainingCapacity();
}

fn reparentLiveSourceScopes(self: *Transformer, source_scope: ScopeId, target_scope: ScopeId, live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!void {
    if (source_scope.isNone() or target_scope.isNone()) return;
    const editor = try editorFor(self);
    var it = live_scopes.iterator();
    while (it.next()) |entry| {
        const old_scope: ScopeId = @enumFromInt(entry.key_ptr.*);
        if (old_scope == source_scope or scopeWithin(editor.scopes.items, old_scope, target_scope)) continue;
        if (!scopeWithin(editor.scopes.items, old_scope, source_scope)) continue;
        var cursor = old_scope;
        var frontier: ScopeId = .none;
        var hops: usize = 0;
        while (cursor != source_scope and !cursor.isNone() and hops < editor.scopes.items.len) : (hops += 1) {
            frontier = cursor;
            cursor = editor.scopes.items[cursor.toIndex()].parent;
        }
        if (cursor != source_scope or frontier.isNone())
            std.debug.panic("live generated scope is detached from its source function", .{});
        if (scopeWithin(editor.scopes.items, frontier, target_scope)) continue;
        editor.reparentScope(frontier, target_scope) catch |err| return editError(err);
    }
}

pub fn reparentGeneratedBodyScopes(self: *Transformer, source_scope: ScopeId, target_scope: ScopeId, body: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or source_scope.isNone() or target_scope.isNone() or body.isNone()) return;
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
        var children = ast_walk.children(self.ast, self.ast.getNode(node));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    var scopes = try liveScopeOwners(self, &live);
    defer scopes.deinit(self.allocator);
    try reparentLiveSourceScopes(self, source_scope, target_scope, &scopes);
}

fn bindGeneratedWrapperTemp(self: *Transformer, temp: @import("lists.zig").HoistedStateTemp, declaration_span: Span, source_scope: ScopeId, callback_scope: ScopeId, live: *const std.AutoHashMapUnmanaged(u32, void), live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!void {
    const editor = try editorFor(self);
    var expected_scope = source_scope;
    var hops: usize = 0;
    while (hops < editor.scopes.items.len) : (hops += 1) {
        if (editor.scopes.items[expected_scope.toIndex()].kind.isVarScope()) break;
        expected_scope = editor.scopes.items[expected_scope.toIndex()].parent;
        if (expected_scope.isNone()) std.debug.panic("generated wrapper temp has no var scope", .{});
    }
    const temp_key = (@as(u64, @intFromEnum(expected_scope)) << 32) | temp.name_span.start;
    const canonical_id = editor.scope_maps.items[expected_scope.toIndex()].get(self.ast.getText(temp.name_span));
    const id: SymbolId = if (self.bound_temp_symbols.get(temp_key)) |raw_id| blk: {
        if (raw_id >= editor.symbols.items.len) std.debug.panic("generated wrapper temp symbol is out of range", .{});
        const existing = editor.symbols.items[raw_id];
        if (existing.scope_id != expected_scope or !std.mem.eql(u8, self.ast.getText(existing.name), self.ast.getText(temp.name_span)))
            std.debug.panic("generated wrapper temp Span was rebound to an unrelated symbol", .{});
        break :blk @enumFromInt(raw_id);
    } else if (canonical_id) |raw_id| blk: {
        if (raw_id >= editor.symbols.items.len) std.debug.panic("canonical wrapper temp symbol id is out of range", .{});
        const existing = editor.symbols.items[raw_id];
        const name = self.ast.getText(temp.name_span);
        const same_generated_name = existing.synthetic_name.len > 0 and std.mem.eql(u8, existing.synthetic_name, name);
        // Generator hoisting can copy a user `var` binding into a fresh string
        // span. A same-name var in the same function scope is that original
        // function-scoped binding, even though its source span differs.
        const same_source_name = existing.synthetic_name.len == 0 and
            std.mem.eql(u8, self.ast.getText(existing.name), name);
        if (existing.scope_id != expected_scope or existing.kind != .variable_var or
            (!same_generated_name and !same_source_name))
            std.debug.panic("wrapper temp name resolves to a non-generated lexical binding", .{});
        try self.bound_temp_symbols.put(self.allocator, temp_key, @intCast(raw_id));
        break :blk @enumFromInt(raw_id);
    } else blk: {
        const created = editor.declare(
            temp.binding,
            temp.name_span,
            declaration_span,
            source_scope,
            .variable_var,
            Reference.NO_STMT,
            Reference.NO_STMT,
        ) catch |err| return editError(err);
        try self.bound_temp_symbols.put(self.allocator, temp_key, @intFromEnum(created));
        break :blk created;
    };
    try setSymbolId(self, temp.binding, id);

    const chain = self.pending_temp_ref_chains.fetchRemove(temp.name_span.start);
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

fn bindTrackedCallbackTemp(self: *Transformer, temp: @import("lists.zig").HoistedStateTemp, declaration_span: Span, source_scope: ScopeId, callback_scope: ScopeId, live: *const std.AutoHashMapUnmanaged(u32, void), live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!void {
    const chain = self.pending_temp_ref_chains.fetchRemove(temp.name_span.start);
    const editor = try editorFor(self);
    const temp_name = self.ast.getText(temp.name_span);
    const canonical_id = editor.scope_maps.items[callback_scope.toIndex()].get(temp_name);
    const id: SymbolId = if (canonical_id) |raw_id| blk: {
        if (raw_id >= editor.symbols.items.len) std.debug.panic("canonical callback temp symbol id is out of range", .{});
        const existing = editor.symbols.items[raw_id];
        if (existing.scope_id != callback_scope or existing.kind != .variable_var or existing.synthetic_name.len == 0 or
            !std.mem.eql(u8, existing.synthetic_name, temp_name))
            std.debug.panic("callback temp name resolves to a non-generated lexical binding", .{});
        break :blk @enumFromInt(raw_id);
    } else editor.declare(temp.binding, temp.name_span, declaration_span, callback_scope, .variable_var, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
    const temp_slot = @intFromEnum(temp.binding);
    if (temp_slot < self.symbol_ids.items.len) {
        if (self.symbol_ids.items[temp_slot]) |existing| {
            if (existing != @intFromEnum(id)) std.debug.panic("callback temp binding already has a different symbol", .{});
        } else try setSymbolId(self, temp.binding, id);
    } else try setSymbolId(self, temp.binding, id);
    // A lowering performed while collecting the state machine may already
    // have emitted an initialized `var` declaration for this exact temp. The
    // callback hoister adds the canonical declaration above; every declaration
    // carrying the same unique name Span is a `var` redeclaration of that same
    // binding and must share its SymbolId.
    var live_iter = live.iterator();
    while (live_iter.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= self.ast.nodes.items.len or self.ast.nodes.items[raw].tag != .binding_identifier) continue;
        const binding_idx: NodeIndex = @enumFromInt(raw);
        if (binding_idx == temp.binding) continue;
        const binding = self.ast.getNode(binding_idx);
        if (binding.data.string_ref.start != temp.name_span.start or binding.data.string_ref.end != temp.name_span.end) continue;
        const slot = @intFromEnum(binding_idx);
        if (slot < self.symbol_ids.items.len) {
            if (self.symbol_ids.items[slot]) |existing_id| {
                if (existing_id >= editor.symbols.items.len) std.debug.panic("state callback temp alias symbol is out of range", .{});
                // A catch parameter intentionally shadows a same-spelled
                // callback temp inside its catch clause; it is a distinct
                // lexical binding even when both originated from one temp Span.
                if (editor.symbols.items[existing_id].kind != .variable_var) continue;
                if (existing_id == @intFromEnum(id)) continue;
                const old_symbol = editor.symbols.items[existing_id];
                if (old_symbol.synthetic_name.len == 0 or
                    !std.mem.eql(u8, old_symbol.synthetic_name, temp_name))
                    std.debug.panic("callback temp Span resolves to an unrelated var binding", .{});
                try self.setGeneratedSymbolId(binding_idx, @intFromEnum(id));
                var reference_iter = live.iterator();
                while (reference_iter.next()) |reference_entry| {
                    const reference_raw = reference_entry.key_ptr.*;
                    if (reference_raw >= self.ast.nodes.items.len) continue;
                    const reference_node: NodeIndex = @enumFromInt(reference_raw);
                    const reference_ast_node = self.ast.getNode(reference_node);
                    if (reference_ast_node.tag != .identifier_reference and
                        reference_ast_node.tag != .assignment_target_identifier) continue;
                    if (reference_ast_node.data.string_ref.start != temp.name_span.start or
                        reference_ast_node.data.string_ref.end != temp.name_span.end or
                        self.getSymbolIdAt(reference_node) != @as(?u32, existing_id)) continue;
                    const maybe_reference = editor.referenceForNode(reference_node) catch |err| return editError(err);
                    const reference = maybe_reference orelse continue;
                    if (reference.symbol_id != @as(SymbolId, @enumFromInt(existing_id)))
                        std.debug.panic("callback temp alias reference changed SymbolId", .{});
                    const reference_scope = try generatedTempRefScope(
                        self,
                        source_scope,
                        callback_scope,
                        reference.scope_id,
                        live_scopes,
                    );
                    editor.relocateReference(
                        reference_node,
                        reference_scope,
                        id,
                        reference.stmt_idx,
                        reference.scope_stmt_idx,
                    ) catch |err| return editError(err);
                    try self.setGeneratedSymbolId(reference_node, @intFromEnum(id));
                }
            }
        }
        if (slot >= self.symbol_ids.items.len or self.symbol_ids.items[slot] == null) {
            try setSymbolId(self, binding_idx, id);
        }
    }
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

/// Record exact source binding nodes moved into a generated function body.
/// Their final scope is chosen later, after generated block scopes exist.
pub fn moveGeneratedFunctionBodyBindings(self: *Transformer, source_scope: ScopeId, function_scope: ScopeId, body: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or source_scope.isNone() or function_scope.isNone() or source_scope == function_scope) return;
    const Work = struct { node: NodeIndex };
    var work_stack: std.ArrayList(Work) = .empty;
    defer work_stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    try work_stack.append(self.allocator, .{ .node = body });
    while (work_stack.pop()) |work| {
        const node = work.node;
        if (node.isNone() or @intFromEnum(node) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const ast_node = self.ast.getNode(node);
        if (ast_node.tag == .binding_identifier) {
            if (self.getSymbolIdAt(node)) |raw_id| {
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                if (raw_id < symbols.len) {
                    const symbol = symbols[raw_id];
                    if (symbol.scope_id == source_scope and symbol.kind != .parameter and symbol.synthetic_name.len == 0) {
                        const gop = try self.generated_body_binding_moves.getOrPut(self.allocator, raw);
                        if (gop.found_existing and gop.value_ptr.* != raw_id)
                            std.debug.panic("generated binding migration changed its exact SymbolId", .{});
                        gop.value_ptr.* = raw_id;
                    }
                }
            }
        }
        var it = ast_walk.children(self.ast, ast_node);
        while (it.next()) |child| try work_stack.append(self.allocator, .{ .node = child });
    }
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
    try reparentLiveSourceScopes(self, source_scope, function_scope, &live_scopes);
    for (temps) |temp| try moveExistingGeneratedTempToFunction(self, source_scope, function_scope, temp.name_span);
    var traces = try collectGeneratedNodeTraces(self, body, function_scope);
    defer traces.deinit(self.allocator);
    for (temps) |temp| try bindStateCallbackTemp(self, temp, span, source_scope, function_scope, function_scope, &live, &live_scopes, &traces);
}

fn moveExistingGeneratedTempToFunction(self: *Transformer, source_scope: ScopeId, function_scope: ScopeId, name_span: Span) Transformer.Error!void {
    if (source_scope.isNone() or function_scope.isNone() or source_scope == function_scope) return;
    const editor = try editorFor(self);
    if (source_scope.toIndex() >= editor.scope_maps.items.len or function_scope.toIndex() >= editor.scope_maps.items.len) return;
    const name = self.ast.getText(name_span);
    const raw_id = editor.scope_maps.items[source_scope.toIndex()].get(name) orelse return;
    if (raw_id >= editor.symbols.items.len) std.debug.panic("source generated temp symbol is out of range", .{});
    const symbol = editor.symbols.items[raw_id];
    if (symbol.scope_id != source_scope or symbol.kind != .variable_var or symbol.synthetic_name.len == 0 or
        symbol.name.start != name_span.start or symbol.name.end != name_span.end or
        !std.mem.eql(u8, symbol.synthetic_name, name)) return;
    if (editor.scope_maps.items[function_scope.toIndex()].get(name)) |existing| {
        if (existing != raw_id) return;
    }
    editor.moveSymbolToScope(@enumFromInt(raw_id), function_scope) catch |err| return editError(err);
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

pub fn addGeneratedScope(self: *Transformer, parent: ScopeId, owner: NodeIndex, kind: @import("../../semantic/scope.zig").ScopeKind) Transformer.Error!ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const editor = try editorFor(self);
    const scope = editor.addScope(parent, owner, kind, false) catch |err| return editError(err);
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
    return addGeneratedScope(self, parent, owner, .catch_clause);
}

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
        (self.ast.getNode(owner).tag != .function_expression and self.ast.getNode(owner).tag != .function_declaration and
            self.ast.getNode(owner).tag != .method_definition and self.ast.getNode(owner).tag != .arrow_function_expression))
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
        !(old_tag == .for_await_of_statement and new_tag == .while_statement) and
        !(old_tag == .class_expression and new_tag == .class_declaration) and
        !(old_tag == .class_declaration and new_tag == .class_expression) and
        !(old_tag == .function_declaration and new_tag == .function_expression) and
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
        if (self.scope_owner_removed.contains(node)) continue;
        const origin = self.scope_owner_origins.get(node) orelse if (self.scope_owner_map.contains(node)) node else continue;
        if (final_by_origin.get(origin)) |existing| {
            if (existing != node) std.debug.panic("one scope owner {d} has reachable copies {d}:{s}(removed={any}) and {d}:{s}(removed={any})", .{
                origin,
                existing,
                @tagName(self.ast.nodes.items[existing].tag),
                self.scope_owner_removed.contains(existing),
                node,
                @tagName(self.ast.nodes.items[node].tag),
                self.scope_owner_removed.contains(node),
            });
        } else try final_by_origin.put(self.allocator, origin, node);
    }
    var remaps = self.scope_owner_remaps.iterator();
    while (remaps.next()) |entry| {
        // An erased boundary has no final owner. Keep its original metadata;
        // pruning dead scopes is a separate semantic edit.
        entry.value_ptr.* = final_by_origin.get(entry.key_ptr.*) orelse entry.key_ptr.*;
    }
}

/// An in-place lowering can replace a scope-owning source node with an outer
/// wrapper while moving that source scope to a nested generated loop/function.
/// Keep the source map entry until finishSemanticEdit transfers it, but exclude
/// the reused node index from final owner resolution and visitor scope entry.
pub fn removeInPlaceScopeOwner(self: *Transformer, node: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or node.isNone()) return;
    const raw = @intFromEnum(node);
    try self.scope_owner_removed.put(self.allocator, raw, {});
}

fn variableScope(self: *Transformer, start: ScopeId) ScopeId {
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    var scope = start;
    var hops: usize = 0;
    while (!scope.isNone() and hops < scopes.len) : (hops += 1) {
        if (scope.toIndex() >= scopes.len) std.debug.panic("invalid synthetic binding scope", .{});
        if (scopes[scope.toIndex()].kind.isVarScope()) return scope;
        scope = scopes[scope.toIndex()].parent;
    }
    std.debug.panic("synthetic var has no enclosing var scope", .{});
}

fn syntheticTempSymbolKey(name_span: Span, scope: ScopeId) u64 {
    return (@as(u64, @intFromEnum(scope)) << 32) | name_span.start;
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

/// Register only a known lowering temp whose later hoisted declaration must
/// share this SymbolId. General synthetic `var` declarations stay independent.
pub fn declareSyntheticTempInScope(self: *Transformer, binding: NodeIndex, declaration_span: Span, scope: ScopeId) Transformer.Error!?SymbolId {
    if (!self.semantic_edit_enabled) return null;
    const editor = try editorFor(self);
    const name_span = self.ast.getNode(binding).data.string_ref;
    const key = syntheticTempSymbolKey(name_span, variableScope(self, scope));
    if (self.synthetic_temp_symbol_ids.get(key)) |raw_id| {
        const id: SymbolId = @enumFromInt(raw_id);
        editor.attachExistingBinding(binding, id) catch |err| return editError(err);
        try setSymbolId(self, binding, id);
        return id;
    }
    const id = editor.declare(
        binding,
        name_span,
        declaration_span,
        scope,
        .variable_var,
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
    try setSymbolId(self, binding, id);
    try self.synthetic_temp_symbol_ids.put(self.allocator, key, @intFromEnum(id));
    return id;
}

/// Carry the exact identity from a lowering-created generator temp binding to
/// the wrapper declaration emitted after state-machine operation collection.
pub fn recordGeneratorStateTempSymbol(self: *Transformer, name_span: Span, symbol: ?SymbolId) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.state_machine_depth == 0) return;
    const id = symbol orelse return;
    const gop = try self.generator_state_temp_symbols.getOrPut(self.allocator, name_span.start);
    if (gop.found_existing) {
        if (gop.value_ptr.* != @intFromEnum(id)) std.debug.panic("generator temp Span was assigned multiple symbols", .{});
        return;
    }
    gop.value_ptr.* = @intFromEnum(id);
}

pub fn deferGeneratedWrapperTemp(self: *Transformer, binding: NodeIndex, name_span: Span) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (self.state_machine_depth == 0) std.debug.panic("generated wrapper temp deferred outside state-machine lowering", .{});
    for (self.generator_state_bindings.items) |existing| {
        if (existing.binding == binding) return;
    }
    try self.generator_state_bindings.append(self.allocator, .{
        .binding = binding,
        .name_span = name_span,
        .callback_local = false,
    });
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

/// Drop a parser reference that was resolved before a lowering assigned its
/// generated identifier a distinct name and SymbolId.
pub fn removeSemanticReference(self: *Transformer, node: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or node.isNone()) return;
    const editor = try editorFor(self);
    const existing = editor.referenceForNode(node) catch |err| return editError(err);
    if (existing != null) {
        try removeReference(self, editor, node);
        return;
    }
    const raw = @intFromEnum(node);
    if (raw < editor.symbol_ids.items.len) editor.symbol_ids.items[raw] = null;
    if (raw < self.symbol_ids.items.len) self.symbol_ids.items[raw] = null;
}

fn removeReference(self: *Transformer, editor: *SemanticEditor, node: NodeIndex) Transformer.Error!void {
    editor.removeReference(node) catch |err| return editError(err);
    const raw = @intFromEnum(node);
    if (raw < self.symbol_ids.items.len) self.symbol_ids.items[raw] = null;
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
    const initializer = try self.makeUserRefNamedAtScope("arguments", origin, self.capture_scope);
    if (self.getSymbolIdAt(initializer) != id) std.debug.panic("captured arguments read lost its source binding", .{});
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
    const root = self.ast.transformed_root orelse std.debug.panic("lexical capture binding has no transformed root", .{});
    var traces = try collectGeneratedNodeTraces(self, root, self.programScope());
    defer traces.deinit(self.allocator);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    for (reachable) |raw| try live.put(self.allocator, raw, {});

    const editor = try editorFor(self);
    for (reachable) |raw| {
        const origin = self.reference_origin_map.get(raw) orelse raw;
        const index = self.capture_ref_by_origin.get(origin) orelse continue;
        const pending = self.capture_refs.items[index];
        var id = self.capture_binding_ids.get(captureKey(pending.frame, pending.kind)) orelse
            std.debug.panic("live lexical capture has no declaration", .{});
        const ref_node: NodeIndex = @enumFromInt(raw);
        const trace = traces.get(raw) orelse std.debug.panic("live lexical capture has no output scope trace: node={d}", .{raw});
        if (trace.ambiguous_scope) std.debug.panic("live lexical capture has ambiguous output scope: node={d}", .{raw});
        const output_scope = trace.scope;
        if (outputReferenceName(self.ast, ref_node)) |name| {
            if (nearestOutputSymbolAtScope(editor, name, output_scope)) |lexical_id| id = lexical_id;
        }
        if (self.getSymbolIdAt(ref_node)) |existing| {
            if (existing != id) {
                const maybe_reference = editor.referenceForNode(ref_node) catch |err| return editError(err);
                const reference = maybe_reference orelse std.debug.panic("rebound lexical capture has no reference record: node={d} existing={d} expected={d}", .{ raw, existing, id });
                editor.relocateReference(ref_node, output_scope, @enumFromInt(id), reference.stmt_idx, reference.scope_stmt_idx) catch |err| return editError(err);
                self.symbol_ids.items[raw] = id;
            }
            const reference_index = editor.reference_index.get(raw) orelse
                std.debug.panic("bound lexical capture has no reference record: node={d} name={s} symbol={d} frame={d} kind={s}", .{ raw, self.ast.getText(self.ast.getNode(ref_node).data.string_ref), existing, pending.frame, @tagName(pending.kind) });
            const reference = editor.references.items[reference_index];
            if (@intFromEnum(reference.symbol_id) != id or !reference.flags.read) {
                std.debug.panic("bound lexical capture reference has inconsistent identity: node={d} name={s} ref_symbol={d} expected_symbol={d} ref_scope={d} output_scope={d} read={any} write={any} frame={d} kind={s}", .{ raw, self.ast.getText(self.ast.getNode(ref_node).data.string_ref), @intFromEnum(reference.symbol_id), id, reference.scope_id.toIndex(), output_scope.toIndex(), reference.flags.read, reference.flags.write, pending.frame, @tagName(pending.kind) });
            }
            if (reference.scope_id != output_scope) {
                editor.moveReference(ref_node, output_scope, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
            }
            continue;
        }
        try addSyntheticRefInScope(self, @enumFromInt(raw), @enumFromInt(id), output_scope, .{ .read = true });
    }

    for (self.capture_refs.items) |pending| {
        if (pending.source.isNone() or live.contains(@intFromEnum(pending.source))) continue;
        if (self.getSymbolIdAt(pending.source) == null) continue;
        try removeReference(self, editor, pending.source);
    }
}

/// 헬퍼 호출은 import 선언보다 먼저 생성된다. marker가 있는 노드만 보류한다.
pub fn trackRuntimeHelperRef(self: *Transformer, node: NodeIndex, local_name: []const u8) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (self.current_scope.isNone()) std.debug.panic("runtime helper {s} created without scope", .{local_name});
    const index = self.pending_runtime_helper_refs.items.len;
    try self.pending_runtime_helper_refs.append(self.allocator, .{ .node = node, .scope = self.current_scope, .local_name = local_name });
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
pub fn relocatePendingRuntimeHelperRef(self: *Transformer, node: NodeIndex, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (scope.isNone()) std.debug.panic("runtime helper relocation has no scope", .{});
    if (self.pending_runtime_helper_ref_index.get(@intFromEnum(node))) |index| {
        self.pending_runtime_helper_refs.items[index].scope = scope;
        return;
    }
    // `transform` emits and binds helper imports before the final output-scope
    // walk. In that case update the already materialized reference instead.
    if (self.semantic_editor) |*editor| {
        editor.moveReference(node, scope, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
    } else {
        std.debug.panic("runtime helper reference was not pending or bound", .{});
    }
}

/// import specifier의 local 노드에 격리된 심볼을 만들고 앞서 생성한 호출을 연결한다.
pub fn bindRuntimeHelperImport(self: *Transformer, local: NodeIndex, local_name: []const u8, declaration_span: Span) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    const id = editor.declareHelperImport(local, self.ast.getNode(local).data.string_ref, declaration_span, self.programScope()) catch |err| return editError(err);
    try setSymbolId(self, local, id);
    try bindPendingRuntimeHelperRefs(self, editor, local_name, id);
}

fn bindPendingRuntimeHelperRefs(self: *Transformer, editor: *SemanticEditor, local_name: []const u8, id: SymbolId) Transformer.Error!void {
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

/// 단일 파일 출력은 AST 밖 preamble으로 runtime helper를 선언한다. 남은 helper 호출을
/// preamble alias의 가상 심볼에 연결해 외부 전역 참조로 오분류되지 않게 한다.
fn bindRuntimeHelperPreamble(self: *Transformer, editor: *SemanticEditor, local_name: []const u8) Transformer.Error!void {
    const name_span = self.ast.addString(local_name) catch return error.OutOfMemory;
    const id = editor.declareRuntimeHelperPreamble(name_span, Span.EMPTY, self.programScope()) catch |err| return editError(err);
    try bindPendingRuntimeHelperRefs(self, editor, local_name, id);
}

/// nullish lowering의 temp 참조는 hoist 선언보다 먼저 생성된다. 이름 대신
/// makeTempVarSpan의 고유 Span을 기록하고 선언 시점에 SymbolId를 연결한다.
pub fn trackGeneratorStateReference(self: *Transformer, node: NodeIndex, id: ?SymbolId, scope: ScopeId, flags: ReferenceFlags) Transformer.Error!void {
    if (!self.semantic_edit_enabled or !self.options.unsupported.generator) return;
    const symbol = id orelse return;
    try self.generator_state_semantic_refs.append(self.allocator, .{
        .node = node,
        .symbol_id = @intFromEnum(symbol),
        .scope = scope,
        .flags = flags,
    });
}

pub fn trackHoistedTempRef(self: *Transformer, name_span: Span, node: NodeIndex, flags: ReferenceFlags) Transformer.Error!void {
    return trackHoistedTempRefInScope(self, name_span, node, self.current_scope, flags);
}

pub fn trackHoistedTempRefInScope(self: *Transformer, name_span: Span, node: NodeIndex, scope: ScopeId, flags: ReferenceFlags) Transformer.Error!void {
    if (!self.semantic_edit_enabled or scope.isNone()) return;
    try self.generated_temp_spans.append(self.allocator, name_span);
    const index = self.pending_temp_refs.items.len;
    try self.pending_temp_refs.append(self.allocator, .{
        .name_start = name_span.start,
        .node = node,
        .scope = scope,
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
    // State-machine operations are assembled before the generated callback
    // scope exists. Leave exact refs and duplicate var declarations pending;
    // bindGeneratedState will attach them to the callback's temp declaration.
    if (self.state_machine_depth > 0 and binding_scope.isNone()) {
        for (self.generator_state_bindings.items) |existing| {
            if (existing.binding == binding) return;
        }
        try self.generated_temp_spans.append(self.allocator, name_span);
        try self.generator_state_bindings.append(self.allocator, .{
            .binding = binding,
            .name_span = name_span,
            .callback_local = true,
        });
        return;
    }
    const chain = self.pending_temp_ref_chains.fetchRemove(name_span.start);
    const target_scope = if (binding_scope.isNone())
        @as(@import("../../semantic/scope.zig").ScopeId, @enumFromInt(
            self.scope_owner_map.get(self.parser_node_count - 1) orelse std.debug.panic("missing program scope for hoisted temp", .{}),
        ))
    else
        binding_scope;
    const editor = try editorFor(self);
    const expected_scope = variableScope(self, target_scope);
    const temp_key = syntheticTempSymbolKey(name_span, expected_scope);
    const known_temp_id = self.synthetic_temp_symbol_ids.get(temp_key);
    const bound_temp_id = self.bound_temp_symbols.get(temp_key);
    if (chain == null and known_temp_id == null and bound_temp_id == null) return;
    const canonical_id = editor.scope_maps.items[expected_scope.toIndex()].get(self.ast.getText(name_span));
    const id: SymbolId = if (known_temp_id != null) blk: {
        break :blk (try declareSyntheticTempInScope(self, binding, declaration_span, target_scope)).?;
    } else if (bound_temp_id) |raw_id| blk: {
        if (raw_id >= editor.symbols.items.len) std.debug.panic("hoisted temp symbol id is out of range", .{});
        const existing = editor.symbols.items[raw_id];
        if (existing.scope_id != expected_scope or !std.mem.eql(u8, self.ast.getText(existing.name), self.ast.getText(name_span)))
            std.debug.panic("exact temp Span was rebound to an unrelated symbol", .{});
        break :blk @enumFromInt(raw_id);
    } else if (canonical_id) |raw_id| blk: {
        if (raw_id >= editor.symbols.items.len) std.debug.panic("canonical temp symbol id is out of range", .{});
        const existing = editor.symbols.items[raw_id];
        if (existing.scope_id != expected_scope or existing.kind != .variable_var or existing.synthetic_name.len == 0 or
            !std.mem.eql(u8, existing.synthetic_name, self.ast.getText(name_span)))
            std.debug.panic("temp name resolves to a non-generated lexical binding", .{});
        try self.bound_temp_symbols.put(self.allocator, temp_key, @intCast(raw_id));
        break :blk @enumFromInt(raw_id);
    } else blk: {
        const created = editor.declare(
            binding,
            name_span,
            declaration_span,
            target_scope,
            .variable_var,
            Reference.NO_STMT,
            Reference.NO_STMT,
        ) catch |err| return editError(err);
        try self.bound_temp_symbols.put(self.allocator, temp_key, @intFromEnum(created));
        break :blk created;
    };
    try self.bound_temp_symbols.put(self.allocator, temp_key, @intFromEnum(id));
    try setSymbolId(self, binding, id);
    if (chain) |found| {
        var i: ?usize = found.value.first;
        while (i) |index| {
            const ref = self.pending_temp_refs.items[index];
            std.debug.assert(ref.name_start == name_span.start);
            editor.addReference(ref.node, id, ref.scope, ref.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
            try setSymbolId(self, ref.node, id);
            i = ref.next;
        }
    }
    if (self.pending_temp_ref_chains.count() == 0) self.pending_temp_refs.clearRetainingCapacity();
}

/// Bind a generated temp that is emitted directly in a lexical declaration.
/// `var` temps use the exact-span hoister; `let`/`const` temps stay in the
/// declaration's lexical scope and retain their emitted declaration kind.
pub fn bindSyntheticTempInScope(
    self: *Transformer,
    binding: NodeIndex,
    name_span: Span,
    declaration_span: Span,
    kind: SymbolKind,
    scope: @import("../../semantic/scope.zig").ScopeId,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (kind == .variable_var or self.state_machine_depth > 0)
        return bindHoistedTemp(self, binding, name_span, declaration_span, scope);
    const chain = self.pending_temp_ref_chains.fetchRemove(name_span.start);
    const id = (try declareSyntheticInScope(self, binding, declaration_span, kind, scope)) orelse return;
    var i: ?usize = if (chain) |found| found.value.first else null;
    while (i) |index| {
        const ref = self.pending_temp_refs.items[index];
        std.debug.assert(ref.name_start == name_span.start);
        const editor = try editorFor(self);
        editor.addReference(ref.node, id, ref.scope, ref.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        try setSymbolId(self, ref.node, id);
        i = ref.next;
    }
    if (self.pending_temp_ref_chains.count() == 0) self.pending_temp_refs.clearRetainingCapacity();
}

/// `a ?? b`가 `a != null ? a : b`로 늘린 두 읽기 노드의 Reference를 기록한다.
/// 좌측 식별자가 ES5 블록 이름 변경으로 복제되어 참조가 이미 이동했을 수
/// 있으므로, 변환 후 null 검사에 실제로 남는 노드에서 분기 읽기를 복제한다.
pub fn trackNullishIdentifierCopies(self: *Transformer, test_ref: NodeIndex, value_ref: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const test_i = @intFromEnum(test_ref);
    if (test_i >= self.symbol_ids.items.len or self.symbol_ids.items[test_i] == null) return;
    const editor = try editorFor(self);
    editor.cloneReferenceAtSameLocation(test_ref, value_ref) catch |err| return editError(err);
}

/// Replacing an identifier with a renamed copy must move its exact semantic
/// reference along with the SymbolId. The old AST node is no longer emitted.
pub fn replaceUserReferenceWithCopy(self: *Transformer, source: NodeIndex, clone: NodeIndex) Transformer.Error!bool {
    if (!self.semantic_edit_enabled or source == clone) return false;
    const editor = try editorFor(self);
    editor.cloneReferenceAtSameLocation(source, clone) catch |err| {
        if (err == error.ReferenceNotFound) return false;
        return editError(err);
    };
    try removeReference(self, editor, source);
    return true;
}

/// Duplicate a user read when lowering deliberately emits the same identifier
/// at two runtime locations, such as the null check and selected branch of an
/// optional chain. Both AST nodes keep the source reference's exact scope.
pub fn duplicateUserReference(self: *Transformer, source: NodeIndex, clone: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or source == clone) return;
    const editor = try editorFor(self);
    editor.cloneReferenceAtSameLocation(source, clone) catch |err| return editError(err);
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
    try self.trackGeneratorStateReference(argument, @enumFromInt(raw_id), scope, .{ .read = true });
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

/// When a transform replaces a user reference with a fresh identifier node,
/// move the exact source Reference and remove the now unreachable source use
/// so SymbolId counts and Reference evidence stay aligned.
pub fn replaceUserReference(self: *Transformer, source: NodeIndex, replacement: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.getSymbolIdAt(source) == null) return;
    const editor = try editorFor(self);
    const source_ref = editor.referenceForNode(source) catch |err| return editError(err);
    if (source_ref == null) return;
    editor.cloneReferenceAtSameLocation(source, replacement) catch |err| return editError(err);
    try removeReference(self, editor, source);
}

/// A synthesized read whose source is a binding has no Reference to clone.
pub fn trackUserReadFromBinding(self: *Transformer, target: NodeIndex, binding: NodeIndex, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const raw_id = self.getSymbolIdAt(binding) orelse return;
    if (self.getSymbolIdAt(target) != raw_id) std.debug.panic("generated read lost source binding symbol", .{});
    const editor = try editorFor(self);
    editor.addCopiedReference(
        target,
        @enumFromInt(raw_id),
        scope,
        .{ .read = true },
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
}

/// A named class expression's self binding becomes the implementation
/// function name in its generated wrapper scope.
pub fn moveBindingToOutputScope(self: *Transformer, binding: NodeIndex, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled or binding.isNone() or scope.isNone()) return;
    const raw_id = self.getSymbolIdAt(binding) orelse return;
    const editor = try editorFor(self);
    editor.moveSymbolToScope(@enumFromInt(raw_id), scope) catch |err| return editError(err);
}

pub fn moveSymbolToOutputScope(self: *Transformer, raw_id: u32, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled or scope.isNone()) return;
    const editor = try editorFor(self);
    editor.moveSymbolToScope(@enumFromInt(raw_id), scope) catch |err| return editError(err);
}

/// Rebind a newly generated declaration node to the exact existing class-self
/// SymbolId selected by the transform's class owner.
pub fn setGeneratedSymbolId(self: *Transformer, node: NodeIndex, raw_id: u32) Transformer.Error!void {
    if (node.isNone() or @intFromEnum(node) < self.parser_node_count) std.debug.panic("cannot replace a parser-owned SymbolId", .{});
    const index = @intFromEnum(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    self.symbol_ids.items[index] = raw_id;
    if (self.semantic_editor) |*editor| {
        if (editor.symbol_ids.items.len <= index)
            try editor.symbol_ids.appendNTimes(self.allocator, null, index + 1 - editor.symbol_ids.items.len);
        editor.symbol_ids.items[index] = raw_id;
    }
}

pub fn rebindOutputBinding(self: *Transformer, node: NodeIndex, raw_id: u32) Transformer.Error!void {
    if (node.isNone()) std.debug.panic("invalid output binding rebind", .{});
    if (self.semantic_edit_enabled) {
        const editor = try editorFor(self);
        if (raw_id >= editor.symbols.items.len) std.debug.panic("invalid output binding rebind", .{});
        editor.rebindBinding(node, @enumFromInt(raw_id)) catch |err| return editError(err);
    } else if (self.symbols.len != 0 and raw_id >= self.symbols.len) {
        std.debug.panic("invalid output binding rebind", .{});
    }
    const index = @intFromEnum(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    self.symbol_ids.items[index] = raw_id;
}

pub fn splitOutputBindingAsVar(self: *Transformer, node: NodeIndex, expected_raw_id: u32, scope: ScopeId, declaration_span: Span) Transformer.Error!u32 {
    if (!self.semantic_edit_enabled) return expected_raw_id;
    const editor = try editorFor(self);
    const id = editor.splitBindingIdentity(
        node,
        @enumFromInt(expected_raw_id),
        scope,
        .variable_var,
        declaration_span,
    ) catch |err| return editError(err);
    const index = @intFromEnum(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    self.symbol_ids.items[index] = @intFromEnum(id);
    return @intFromEnum(id);
}

pub fn relocateOutputSymbolAs(self: *Transformer, raw_id: u32, scope: ScopeId, binding: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.relocateSymbolAs(@enumFromInt(raw_id), scope, binding) catch |err| return editError(err);
}

pub fn rebindOutputReference(self: *Transformer, node: NodeIndex, raw_id: u32) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    const maybe_reference = editor.referenceForNode(node) catch |err| return editError(err);
    const reference = maybe_reference orelse std.debug.panic("captured loop output reference has no semantic record", .{});
    if (reference.flags.declare) std.debug.panic("captured loop output reference is a declaration", .{});
    editor.relocateReference(
        node,
        reference.scope_id,
        @enumFromInt(raw_id),
        reference.stmt_idx,
        reference.scope_stmt_idx,
    ) catch |err| return editError(err);
    const index = @intFromEnum(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    self.symbol_ids.items[index] = raw_id;
}

/// A generated binding can materialize a symbol that the analyzer represented
/// only as a declaration facade. Keep the declaration row alongside its node ID.
pub fn ensureSymbolDeclaration(self: *Transformer, raw_id: u32, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.ensureDeclaration(@enumFromInt(raw_id), scope) catch |err| return editError(err);
}

/// 변환 중 복사된 사용자 식별자와 scope owner도 편집 결과에 합친다.
pub fn finishSemanticEdit(self: *Transformer) Transformer.Error!?SemanticEditor.Result {
    if (!self.semantic_edit_enabled) return null;
    try resolveReachableScopeOwners(self);
    // Scope-owner remaps are semantic edits even when no binding/reference was
    // synthesized. Arrow-to-function and copied body scopes need a final map.
    if (self.semantic_editor == null and (self.scope_owner_remaps.count() > 0 or
        (!self.options.emit_runtime_helper_imports and self.pending_runtime_helper_chains.count() > 0)))
    {
        _ = try editorFor(self);
    }
    if (self.options.emit_runtime_helper_imports and self.pending_runtime_helper_chains.count() != 0)
        std.debug.panic("generated runtime helper reference has no import", .{});
    if (!self.options.emit_runtime_helper_imports and self.pending_runtime_helper_chains.count() > 0) {
        const editor = try editorFor(self);
        // Binding removes entries from the chain map, so snapshot its keys first.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        var pending = self.pending_runtime_helper_chains.iterator();
        while (pending.next()) |entry| try names.append(self.allocator, entry.key_ptr.*);
        for (names.items) |name| try bindRuntimeHelperPreamble(self, editor, name);
    }
    const editor = if (self.semantic_editor) |*e| e else return null;
    var remaps = self.scope_owner_remaps.iterator();
    while (remaps.next()) |entry| {
        if (self.scope_owner_removed.contains(entry.key_ptr.*)) {
            editor.remapScopeOwnerAfterInPlaceRewrite(@enumFromInt(entry.key_ptr.*), @enumFromInt(entry.value_ptr.*)) catch |err| return editError(err);
        } else {
            editor.remapScopeOwner(@enumFromInt(entry.key_ptr.*), @enumFromInt(entry.value_ptr.*)) catch |err| return editError(err);
        }
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
    // Lowering can discard source identifiers while retaining their semantic
    // rows (for example an export reference when a class declaration becomes
    // an IIFE). Keep only references represented in the final AST so removed
    // nodes cannot keep stale scope ownership or inflate symbol use counts.
    if (self.ast.transformed_root) |root| {
        if (!root.isNone()) {
            const reachable = @import("../../parser/ast_walk.zig").collectReachableNodeIndices(self.allocator, self.ast) catch return error.OutOfMemory;
            defer self.allocator.free(reachable);
            var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer live.deinit(self.allocator);
            for (reachable) |raw| try live.put(self.allocator, raw, {});
            var i = editor.references.items.len;
            while (i > 0) {
                i -= 1;
                const ref = editor.references.items[i];
                if (ref.node_index.isNone() or live.contains(@intFromEnum(ref.node_index))) continue;
                try removeReference(self, editor, ref.node_index);
            }
        }
    }
    const result = editor.finish() catch |err| return editError(err);
    editor.deinit();
    self.semantic_editor = null;
    return result;
}
