//! 변환 중 합성 바인딩과 참조를 원래 semantic SymbolId 공간에 추가한다 (#4819).
const std = @import("std");
const Scanner = @import("../../lexer/scanner.zig").Scanner;
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
const SyntheticKind = @import("../../semantic/symbol.zig").SyntheticKind;
const ScopeId = @import("../../semantic/scope.zig").ScopeId;
const ScopeKind = @import("../../semantic/scope.zig").ScopeKind;
const Scope = @import("../../semantic/scope.zig").Scope;
const Symbol = @import("../../semantic/symbol.zig").Symbol;
const Reference = @import("../../semantic/symbol.zig").Reference;
const ReferenceFlags = @import("../../semantic/symbol.zig").ReferenceFlags;
const SemanticEditor = @import("../../semantic/editor.zig").SemanticEditor;
const EditorError = @import("../../semantic/editor.zig").Error;
const LexicalCaptureKind = @import("../transformer.zig").LexicalCaptureKind;
const es_helpers = @import("../es_helpers.zig");
const symbol_coverage = @import("../symbol_coverage.zig");
const runtime_helper_names = @import("../../runtime_helper_names.zig");

pub const SyntheticBinding = struct {
    node: NodeIndex,
    /// The collision-resolved spelling stored on the binding node.
    name_span: Span,
    symbol_id: ?SymbolId,
};

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
        self.semantic_editor.?.importNodeScopeProvenance(self.node_scope_provenance) catch |err| return editError(err);
        self.semantic_editor.?.importNodeScopeProvenance(self.transformed_node_scope_provenance) catch |err| return editError(err);
    }
    return &self.semantic_editor.?;
}

fn setSymbolId(self: *Transformer, node: NodeIndex, id: SymbolId) Transformer.Error!void {
    const index = @backingInt(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    if (self.symbol_ids.items[index] != null) std.debug.panic("generated identifier already has a symbol", .{});
    if (self.semantic_editor) |*editor| {
        if (self.ast.getNode(node).tag == .binding_identifier) {
            editor.attachExistingBinding(node, id) catch |err| return editError(err);
            self.symbol_ids.items[index] = @backingInt(id);
            return;
        }
    }
    self.symbol_ids.items[index] = @backingInt(id);
}

/// Bind one generated `var` declaration that source analysis would merge with
/// an existing var-scope symbol. Unlike `setSymbolId`, this does not reanchor
/// the symbol's original declaration row to the additional declaration.
pub fn bindSyntheticVarRedeclaration(
    self: *Transformer,
    binding: NodeIndex,
    id: SymbolId,
    lexical_scope: ScopeId,
) Transformer.Error!void {
    const editor = try editorFor(self);
    editor.attachVarRedeclaration(binding, id, lexical_scope) catch |err| return editError(err);
    const index = @backingInt(binding);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    if (self.symbol_ids.items[index]) |existing| {
        if (existing != @backingInt(id)) std.debug.panic("generated var redeclaration changed SymbolId", .{});
    } else {
        self.symbol_ids.items[index] = @backingInt(id);
    }
}

fn outputSymbolIdAt(self: *Transformer, editor: *SemanticEditor, node: NodeIndex) ?u32 {
    if (self.getSymbolIdAt(node)) |id| return id;
    if (node.isNone() or @backingInt(node) >= editor.symbol_ids.items.len) return null;
    return editor.symbol_ids.items[@backingInt(node)];
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
    const raw = @backingInt(source_class);
    if (self.generated_class_self_relocated_to_wrapper.contains(raw)) return false;
    if (self.generated_class_without_source_anchor.contains(raw) and !self.class_self_symbol_map.contains(raw)) {
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
        const source_node = self.ast.getNode(@fromBackingInt(@intCast(origin)));
        const source_name = self.ast.extra_data.items[source_node.data.extra + @import("../../parser/ast.zig").ClassExtra.name];
        if (source_name == @backingInt(NodeIndex.none)) return false;
        std.debug.panic("named source class has no inner self SymbolId", .{});
    };
    const inner: SymbolId = @fromBackingInt(@intCast(inner_raw));
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
    return @fromBackingInt(@intCast(self.scope_owner_map.get(self.parser_node_count - 1) orelse
        std.debug.panic("missing program scope for generated declaration", .{})));
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

/// Whether a source temp's final output var scope will be created by async or
/// generator lowering after this expression is visited. Those paths must keep
/// refs pending until the generated callback owner exists.
pub fn syntheticTempOutputScopeIsDeferred(self: *Transformer, start: ScopeId) bool {
    if (self.state_machine_depth > 0) return true;
    return tempOutputScopeIsDeferredIgnoringStateMachine(self, start);
}

/// Allow producer-ID references in a stable nested function scope to bind
/// while an enclosing generator state machine is still being assembled.
fn knownSyntheticTempOutputScopeIsDeferred(self: *Transformer, start: ScopeId) bool {
    if (!syntheticTempOutputScopeIsDeferred(self, start)) return false;
    return self.state_machine_depth == 0 or tempOutputScopeIsDeferredIgnoringStateMachine(self, start);
}

/// Whether a function scope exists and is stable even when called from inside
/// a state-machine transformation. Used by producers that can register a temp
/// in the known wrapper owner and relocate only its references later.
pub fn tempOutputScopeIsDeferredIgnoringStateMachine(self: *Transformer, start: ScopeId) bool {
    if (start.isNone()) return false;
    const scopes: []const Scope = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    var current = start;
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        if (current.toIndex() >= scopes.len) return false;
        if (scopes[current.toIndex()].kind == .function) {
            if (scopeOwnerNode(self, current)) |owner| {
                if (self.ast.getNode(owner).tag == .formal_parameters) return true;
                if (ownerNeedsLoweredFunctionScope(self, owner)) return true;
            }
        }
        current = scopes[current.toIndex()].parent;
    }
    return false;
}

/// Object-super homes use the scope of their emitted object tree. During an
/// outer state-machine transform that tree can cross a nested synchronous
/// function boundary; only this producer may use that nearest stable owner.
/// Other synthetic temps retain the conservative global state-machine rule.
pub fn objectSuperTempOutputScopeIsDeferred(self: *Transformer, start: ScopeId) bool {
    if (self.state_machine_depth == 0) return syntheticTempOutputScopeIsDeferred(self, start);
    if (start.isNone()) return false;
    const scopes: []const Scope = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    var current = start;
    var hops: usize = 0;
    while (!current.isNone() and hops < scopes.len) : (hops += 1) {
        if (current.toIndex() >= scopes.len) return false;
        if (scopes[current.toIndex()].kind == .function) {
            const owner = scopeOwnerNode(self, current) orelse return true;
            if (self.ast.getNode(owner).tag == .formal_parameters) return true;
            // Stop at the nearest function owner. A stable nested sync
            // function must not inherit the deferred output scope of an outer
            // async/generator state machine.
            return ownerNeedsLoweredFunctionScope(self, owner);
        }
        current = scopes[current.toIndex()].parent;
    }
    return false;
}

fn scopeOwnerNode(self: *Transformer, scope: ScopeId) ?NodeIndex {
    const raw_scope = @backingInt(scope);
    var transformed = self.transformed_scope_owner_map.iterator();
    while (transformed.next()) |entry| {
        if (entry.value_ptr.* == raw_scope and entry.key_ptr.* < self.ast.nodes.items.len)
            return @fromBackingInt(@intCast(entry.key_ptr.*));
    }
    var original = self.scope_owner_map.iterator();
    while (original.next()) |entry| {
        if (entry.value_ptr.* == raw_scope and entry.key_ptr.* < self.ast.nodes.items.len)
            return @fromBackingInt(@intCast(entry.key_ptr.*));
    }
    return null;
}

/// A lowered default initializer is moved from its separate parameter
/// environment into the function body. Synchronous functions use their
/// existing body scope. An explicitly active async wrapper may reserve
/// directly when its exact source scope owns both the parameters and emitted
/// wrapper. Dynamic-lookup and other async/generator owners defer.
fn loweredDefaultParameterOutputScope(self: *Transformer, start_scope: ScopeId) ?ScopeId {
    if (!self.semantic_edit_enabled or
        !self.options.unsupported.default_params or !self.options.unsupported.arrow or
        self.native_parameter_list_retained_for_dynamic_lookup or start_scope.isNone()) return null;

    const scopes: []const Scope = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (start_scope.toIndex() >= scopes.len) return null;
    const start_owner = scopeOwnerNode(self, start_scope) orelse return null;
    const output_owner = self.lowered_parameter_temp_output_owner;
    if (self.state_machine_depth > 0 or !output_owner.isNone()) {
        if (output_owner.isNone()) return null;
        const output_owner_node = self.ast.getNode(output_owner);
        const exact_async_arrow_state_machine = self.state_machine_depth > 0 and
            output_owner_node.tag == .arrow_function_expression and
            ownerNeedsLoweredFunctionScope(self, output_owner);
        const exact_async_function_wrapper = blk: {
            if (!ownerNeedsLoweredFunctionScope(self, output_owner)) break :blk false;
            const async_flags = switch (output_owner_node.tag) {
                .function_declaration, .function_expression, .function => blk_flags: {
                    const flags = self.readU32(output_owner_node.data.extra, ast_mod.FunctionExtra.flags);
                    break :blk_flags .{
                        (flags & ast_mod.FunctionFlags.is_async) != 0,
                        (flags & ast_mod.FunctionFlags.is_generator) != 0,
                    };
                },
                .method_definition => blk_flags: {
                    const flags = self.readU32(output_owner_node.data.extra, ast_mod.MethodExtra.flags);
                    break :blk_flags .{
                        (flags & ast_mod.MethodFlags.is_async) != 0,
                        (flags & ast_mod.MethodFlags.is_generator) != 0,
                    };
                },
                else => break :blk false,
            };
            const exact_async_function = async_flags[0] and !async_flags[1] and
                self.options.unsupported.async_await and self.options.unsupported.generator;
            const exact_async_generator = async_flags[0] and async_flags[1] and
                self.options.unsupported.async_generator;
            break :blk exact_async_function or exact_async_generator;
        };
        const exact_sync_generator_wrapper = ownerIsLoweredSyncGenerator(self, output_owner);
        if (!exact_async_arrow_state_machine and !exact_async_function_wrapper and
            !exact_sync_generator_wrapper) return null;
        const owner_raw = @backingInt(output_owner);
        const output_scope_raw = self.transformed_scope_owner_map.get(owner_raw) orelse
            self.scope_owner_map.get(owner_raw) orelse return null;
        if (output_scope_raw >= scopes.len or scopes[output_scope_raw].kind != .function) return null;
        const output_scope: ScopeId = @fromBackingInt(@intCast(output_scope_raw));

        // The async arrow/function/method wrapper keeps the source owner's
        // function ScopeId. Its parameter temp can use that exact owner while
        // state-machine temp collection is active.
        if (start_owner == output_owner) {
            const parameter_scope = scopes[start_scope.toIndex()].parent;
            if (parameter_scope.isNone()) return null;
            const parameter_owner = scopeOwnerNode(self, parameter_scope) orelse return null;
            if (self.ast.getNode(parameter_owner).tag != .formal_parameters or
                functionParametersNode(self, start_owner) != parameter_owner or output_scope != start_scope)
                return null;
            return output_scope;
        }
        if (self.ast.getNode(start_owner).tag == .formal_parameters and
            functionParametersNode(self, output_owner) == start_owner)
        {
            if (exact_async_arrow_state_machine and scopes[start_scope.toIndex()].parent == output_scope)
                return output_scope;
            if ((exact_async_function_wrapper or exact_sync_generator_wrapper) and
                scopes[output_scope.toIndex()].parent == start_scope)
                return output_scope;
        }
        return null;
    }
    if (self.ast.getNode(start_owner).tag != .formal_parameters) {
        const parent_scope = scopes[start_scope.toIndex()].parent;
        if (parent_scope.isNone()) return null;
        const parameter_owner = scopeOwnerNode(self, parent_scope) orelse return null;
        if (self.ast.getNode(parameter_owner).tag != .formal_parameters or
            functionParametersNode(self, start_owner) != parameter_owner or
            ownerNeedsLoweredFunctionScope(self, start_owner)) return null;
        return start_scope;
    }

    const parameter_owner = start_owner;
    var candidate: ?ScopeId = null;
    var ambiguous = false;

    var transformed = self.transformed_scope_owner_map.iterator();
    while (transformed.next()) |entry| {
        recordParameterOutputScopeCandidate(
            self,
            parameter_owner,
            start_scope,
            scopes,
            entry.key_ptr.*,
            entry.value_ptr.*,
            &candidate,
            &ambiguous,
        );
    }

    var original = self.scope_owner_map.iterator();
    while (original.next()) |entry| {
        recordParameterOutputScopeCandidate(
            self,
            parameter_owner,
            start_scope,
            scopes,
            entry.key_ptr.*,
            entry.value_ptr.*,
            &candidate,
            &ambiguous,
        );
    }
    return if (ambiguous) null else candidate;
}

fn ownerIsLoweredSyncGenerator(self: *Transformer, owner: NodeIndex) bool {
    if (!self.options.unsupported.generator or owner.isNone() or @backingInt(owner) >= self.ast.nodes.items.len)
        return false;
    const node = self.ast.getNode(owner);
    const flags: u32 = switch (node.tag) {
        .function_declaration, .function_expression, .function => self.readU32(node.data.extra, ast_mod.FunctionExtra.flags),
        .method_definition => ast_mod.methodFlagsToFunctionFlags(
            self.readU32(node.data.extra, ast_mod.MethodExtra.flags),
        ),
        else => return false,
    };
    const is_generator = (flags & ast_mod.FunctionFlags.is_generator) != 0;
    const is_async = (flags & ast_mod.FunctionFlags.is_async) != 0;
    return is_generator and !is_async;
}

fn reparentLoweredGeneratorParameterScope(
    self: *Transformer,
    reference_scope: ScopeId,
    output_scope: ScopeId,
    editor: *SemanticEditor,
) Transformer.Error!?ScopeId {
    const owner = self.synthetic_function_source_owner;
    if (!self.options.unsupported.default_params or self.native_parameter_list_retained_for_dynamic_lookup or
        !ownerIsLoweredSyncGenerator(self, owner) or reference_scope.isNone() or output_scope.isNone() or
        reference_scope.toIndex() >= editor.scopes.items.len or output_scope.toIndex() >= editor.scopes.items.len)
        return null;
    const output = editor.scopes.items[output_scope.toIndex()];
    if (reference_scope == output_scope) return null;
    if (!self.synthetic_function_node.isNone() and
        self.outputOwnedScope(self.synthetic_function_node) == reference_scope)
    {
        // The temporary function expression created for a method is replaced
        // by the original method's output owner. Its parameter references must
        // move to that final scope; retaining the temporary function boundary
        // would make the hoisted temp invisible.
        return output_scope;
    }
    var root = reference_scope;
    var hops: usize = 0;
    while (hops < editor.scopes.items.len) : (hops += 1) {
        if (root.isNone() or root.toIndex() >= editor.scopes.items.len) return null;
        const parent = editor.scopes.items[root.toIndex()].parent;
        if (parent == output.parent) break;
        root = parent;
    }
    if (root.isNone() or root.toIndex() >= editor.scopes.items.len or
        editor.scopes.items[root.toIndex()].parent != output.parent)
        return null;
    if (scopeOwnerNode(self, root)) |scope_owner| {
        if (self.ast.getNode(scope_owner).tag == .formal_parameters) return null;
    }
    // Default expressions move into the emitted generator function body.
    // During parameter-temp hoisting, their nested scopes can still be rooted
    // under the source parameter environment. Move that exact subtree under
    // the output function scope so all its reads remain visible to the hoisted
    // temp. Final output-scope binding will reconcile AST-owned scopes later.
    if (root == output_scope) return null;
    editor.reparentScope(root, output_scope) catch |err| return editError(err);
    return reference_scope;
}

/// Resolve the body scope for an expression emitted from a lowered formal
/// parameter environment. Callers that only know a lexical output scope must
/// not treat an ordinary function body as parameter output.
pub fn loweredParameterEnvironmentOutputScope(self: *Transformer, start_scope: ScopeId) ?ScopeId {
    const owner = scopeOwnerNode(self, start_scope) orelse return null;
    if (self.ast.getNode(owner).tag != .formal_parameters) return null;
    if (!parameterScopeHasLoweredOwner(self, owner)) return null;
    return loweredDefaultParameterOutputScope(self, start_scope);
}

fn parameterScopeHasLoweredOwner(self: *Transformer, parameter_owner: NodeIndex) bool {
    var transformed = self.transformed_scope_owner_map.iterator();
    while (transformed.next()) |entry| {
        if (entry.key_ptr.* >= self.ast.nodes.items.len) continue;
        const owner: NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        if (functionParametersNode(self, owner) == parameter_owner and functionHasLoweredParameterList(self, owner)) return true;
    }
    var original = self.scope_owner_map.iterator();
    while (original.next()) |entry| {
        if (entry.key_ptr.* >= self.ast.nodes.items.len) continue;
        const owner: NodeIndex = @fromBackingInt(@intCast(entry.key_ptr.*));
        if (functionParametersNode(self, owner) == parameter_owner and functionHasLoweredParameterList(self, owner)) return true;
    }
    return false;
}

fn recordParameterOutputScopeCandidate(
    self: *Transformer,
    parameter_owner: NodeIndex,
    parameter_scope: ScopeId,
    scopes: []const Scope,
    owner_raw: u32,
    scope_raw: u32,
    candidate: *?ScopeId,
    ambiguous: *bool,
) void {
    if (owner_raw >= self.ast.nodes.items.len) return;
    const owner: NodeIndex = @fromBackingInt(@intCast(owner_raw));
    if (functionParametersNode(self, owner) != parameter_owner) return;
    if (ownerNeedsLoweredFunctionScope(self, owner) or scope_raw >= scopes.len) {
        ambiguous.* = true;
        return;
    }
    const scope: ScopeId = @fromBackingInt(@intCast(scope_raw));
    if (scope == parameter_scope or scopes[scope_raw].kind != .function or
        scopes[scope_raw].parent != parameter_scope)
    {
        ambiguous.* = true;
        return;
    }
    if (candidate.*) |existing| {
        if (existing != scope) ambiguous.* = true;
    } else candidate.* = scope;
}

fn functionParametersNode(self: *Transformer, owner: NodeIndex) ?NodeIndex {
    if (owner.isNone() or @backingInt(owner) >= self.ast.nodes.items.len) return null;
    const node = self.ast.getNode(owner);
    const slot: u32 = switch (node.tag) {
        .function_declaration, .function_expression, .function => ast_mod.FunctionExtra.params,
        .arrow_function_expression => ast_mod.ArrowExtra.params,
        .method_definition => ast_mod.MethodExtra.params,
        else => return null,
    };
    const extra: usize = @intCast(node.data.extra);
    const slot_index: usize = @intCast(slot);
    if (extra + slot_index >= self.ast.extra_data.items.len) return null;
    const raw = self.ast.extra_data.items[extra + slot_index];
    if (raw == @backingInt(NodeIndex.none) or raw >= self.ast.nodes.items.len) return null;
    return @fromBackingInt(@intCast(raw));
}

fn functionHasLoweredParameterList(self: *Transformer, owner: NodeIndex) bool {
    const params_node = functionParametersNode(self, owner) orelse return false;
    const params = self.ast.getNode(params_node);
    if (params.tag != .formal_parameters) return false;
    const Params = @import("../es2015_params.zig").ES2015Params(Transformer);
    return Params.hasDefaultOrRest(self, params.data.list);
}

fn ownerNeedsLoweredFunctionScope(self: *Transformer, owner: NodeIndex) bool {
    const node = self.ast.getNode(owner);
    return switch (node.tag) {
        .function_declaration, .function_expression, .function => blk: {
            const flags = self.readU32(node.data.extra, ast_mod.FunctionExtra.flags);
            break :blk ((flags & ast_mod.FunctionFlags.is_async) != 0 and self.options.unsupported.async_await) or
                ((flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator)) ==
                    (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator) and self.options.unsupported.async_generator) or
                ((flags & ast_mod.FunctionFlags.is_generator) != 0 and self.options.unsupported.generator);
        },
        .arrow_function_expression => blk: {
            const flags = self.readU32(node.data.extra, 2);
            break :blk (flags & ast_mod.ArrowFlags.is_async) != 0 and self.options.unsupported.async_await;
        },
        .method_definition => blk: {
            const flags = self.readU32(node.data.extra, ast_mod.MethodExtra.flags);
            break :blk ((flags & ast_mod.MethodFlags.is_async) != 0 and self.options.unsupported.async_await) or
                ((flags & (ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_generator)) ==
                    (ast_mod.MethodFlags.is_async | ast_mod.MethodFlags.is_generator) and self.options.unsupported.async_generator) or
                ((flags & ast_mod.MethodFlags.is_generator) != 0 and self.options.unsupported.generator);
        },
        else => false,
    };
}

/// The original function or method node, not the transform traversal cursor,
/// determines where a state machine's generated functions live.
pub fn originalFunctionScope(self: *Transformer, owner: NodeIndex) ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const raw = @backingInt(owner);
    if (self.transformed_scope_owner_map.get(raw) orelse self.scope_owner_map.get(raw)) |scope| {
        const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
        if (scope >= scopes.len or scopes[scope].kind != .function)
            std.debug.panic("state machine owner {d} has no function scope", .{raw});
        return @fromBackingInt(@intCast(scope));
    }
    // This exact owner was produced by generator loop extraction before the
    // enclosing state-machine callback exists. Its complete function/parameter
    // migration will establish the true parent. No other missing owner may be
    // silently treated as a generated loop.
    if (self.deferred_generator_loop_owners.get(raw)) |deferred_owner| {
        const function_scope = deferred_owner.function_scope orelse
            std.debug.panic("deferred generator loop owner has no exact function ScopeId", .{});
        const migration = self.deferred_generator_loop_migrations.get(@backingInt(function_scope)) orelse
            std.debug.panic("deferred generator loop owner has no exact migration", .{});
        if (migration.loop_function != owner)
            std.debug.panic("deferred generator loop owner and migration disagree", .{});
        return .none;
    }
    std.debug.panic("missing source function scope for state machine", .{});
}

/// Return the exact function scope that owns state-machine wrapper temps.
/// Extracted generator-loop functions already have a reserved function ScopeId
/// even while their insertion parent awaits the enclosing state callback.
pub fn stateMachineOwnerScope(self: *Transformer, owner: NodeIndex) ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const raw = @backingInt(owner);
    if (self.transformed_scope_owner_map.get(raw) orelse self.scope_owner_map.get(raw)) |scope| {
        const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
        if (scope >= scopes.len or scopes[scope].kind != .function)
            std.debug.panic("state machine owner {d} has no function scope", .{raw});
        return @fromBackingInt(@intCast(scope));
    }
    if (self.deferred_generator_loop_owners.get(raw)) |deferred_owner| {
        const function_scope = deferred_owner.function_scope orelse
            std.debug.panic("deferred generator loop owner has no exact function ScopeId", .{});
        const migration = self.deferred_generator_loop_migrations.get(@backingInt(function_scope)) orelse
            std.debug.panic("deferred generator loop owner has no exact migration", .{});
        if (migration.loop_function != owner)
            std.debug.panic("deferred generator loop owner and migration disagree", .{});
        const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
        if (function_scope.toIndex() >= scopes.len or scopes[function_scope.toIndex()].kind != .function)
            std.debug.panic("deferred generator loop owner ScopeId is not a function scope", .{});
        return function_scope;
    }
    std.debug.panic("missing exact wrapper function scope for state machine", .{});
}

/// Register one state machine callback and its exact pending `_state` uses.
pub fn bindGeneratedState(self: *Transformer, parent: ScopeId, source_scope: ScopeId, callback: NodeIndex, parameter: NodeIndex, ref_start: usize, wrapper_temps: []const @import("lists.zig").HoistedStateTemp, callback_temps: []const @import("lists.zig").HoistedStateTemp, span: Span) Transformer.Error!void {
    if (ref_start > self.generator_state_refs.items.len) std.debug.panic("invalid state machine frame", .{});
    if (self.semantic_edit_enabled) {
        if (parent.isNone() or source_scope.isNone() or callback.isNone() or parameter.isNone())
            std.debug.panic("state callback has no exact owner scope or binding nodes", .{});
        const editor = try editorFor(self);
        const scope = try addGeneratedFunctionScope(self, parent, callback);
        const symbol = (try declareSyntheticInScope(self, parameter, span, .parameter, scope)) orelse
            std.debug.panic("generator state binding is missing its exact SymbolId", .{});
        if (es_helpers.canUseLateStandaloneOutputName(self, scope) or
            es_helpers.canUseLateGraphOutputName(self, scope))
        {
            const state_symbol = &editor.symbols.items[@backingInt(symbol)];
            state_symbol.synthetic_kind = .generator_state_parameter;
            if (self.options.emit_runtime_helper_imports) state_symbol.output_name_hint = "_state";
        }
        try reparentDeferredGeneratorLoops(self, source_scope, scope);
        // Operation lowering can create an expression and then discard it.
        // Only references actually contained in this callback count as uses.
        var pending: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer pending.deinit(self.allocator);
        for (self.generator_state_refs.items[ref_start..]) |ref| try pending.put(self.allocator, @backingInt(ref), {});
        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(self.allocator);
        var stack: std.ArrayList(NodeIndex) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, callback);
        while (stack.pop()) |node| {
            if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) continue;
            const raw = @backingInt(node);
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
        try es_helpers.relocatePrivateReferences(self, callback, scope);
        var callback_traces = try collectGeneratedNodeTraces(self, callback, scope);
        defer callback_traces.deinit(self.allocator);
        for (wrapper_temps) |temp| {
            if (temp.owner_scope.isNone() or temp.symbol_id == null)
                std.debug.panic("generated wrapper temp has no exact owner or SymbolId", .{});
            if (!scopeWithin(editor.scopes.items, temp.owner_scope, source_scope))
                std.debug.panic("generated wrapper temp owner is outside its source function", .{});
            try bindStateCallbackTemp(self, temp, span, source_scope, temp.owner_scope, scope, &seen, &live_scopes, &callback_traces);
        }
        for (self.generator_state_bindings.items) |temp| {
            const binding_scope = if (temp.callback_local)
                scope
            else if (!temp.owner_scope.isNone())
                temp.owner_scope
            else
                std.debug.panic("generated wrapper temp has no exact owner ScopeId", .{});
            if (!temp.callback_local and temp.symbol_id == null)
                std.debug.panic("generated wrapper temp has an owner but no exact SymbolId", .{});
            if (!temp.callback_local and !scopeWithin(editor.scopes.items, binding_scope, source_scope))
                std.debug.panic("generated wrapper temp owner is outside its source function", .{});
            if (temp.symbol_id != null) {
                try bindStateCallbackTemp(self, temp, span, source_scope, binding_scope, scope, &seen, &live_scopes, &callback_traces);
            } else if (temp.callback_local) {
                try bindTrackedCallbackTemp(self, temp, span, source_scope, scope, &seen, &live_scopes);
            } else {
                std.debug.panic("generator wrapper temp has no exact SymbolId", .{});
            }
        }
        for (callback_temps) |temp| {
            try bindStateCallbackTemp(self, temp, span, source_scope, scope, scope, &seen, &live_scopes, &callback_traces);
        }
        try bindGeneratorStateReferences(self, source_scope, scope, callback, &seen, &live_scopes);
        var migrations = self.deferred_generator_loop_migrations.iterator();
        while (migrations.next()) |entry| {
            const migration = entry.value_ptr;
            if (entry.key_ptr.* != @backingInt(source_scope)) continue;
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
        const function_scope: ScopeId = @fromBackingInt(@intCast(function_scope_raw));
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
        if (entry.key_ptr.* != @backingInt(source_scope) or migration.state_callback.isNone() or migration.body_migrated) continue;
        try ready.append(self.allocator, entry.key_ptr.*);
    }

    for (ready.items) |function_scope_raw| {
        const migration_ptr = self.deferred_generator_loop_migrations.getPtr(function_scope_raw) orelse continue;
        const migration = migration_ptr.*;
        try migrateGeneratorLoopBody(
            self,
            migration.body,
            migration.state_callback,
            @fromBackingInt(@intCast(function_scope_raw)),
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
    const owner = self.deferred_generator_loop_owners.getPtr(@backingInt(migration.loop_function)) orelse
        std.debug.panic("completed generator loop migration has no deferred owner", .{});
    if (owner.function_scope == null or @backingInt(owner.function_scope.?) != function_scope_raw or owner.migration_complete)
        std.debug.panic("completed generator loop migration changed exact owner", .{});
    owner.migration_complete = true;
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
const OutputReferenceScope = struct {
    node: NodeIndex,
    scope: ScopeId,
    raw_id: u32,
    exact: bool = false,
    flags: ReferenceFlags = .{},
};
const OutputBindingCandidate = struct {
    node: NodeIndex,
    raw_id: u32,
    lexical_scope: ScopeId,
    target_scope: ScopeId,
    kind: SymbolKind,
    name: []const u8,
    canonical_name: []const u8,
    canonical_name_owned: bool,
    needs_placement: bool,
    is_function_declaration: bool,
};
const OutputBindingGroup = struct {
    raw_id: u32,
    target_scope: ScopeId,
    lexical_scope: ScopeId,
    kind: SymbolKind,
    name: []const u8,
    first_node: NodeIndex,
    needs_placement: bool,
    is_function_declaration: bool,
};

fn outputBindingCandidateLessThan(_: void, lhs: OutputBindingCandidate, rhs: OutputBindingCandidate) bool {
    if (lhs.raw_id != rhs.raw_id) return lhs.raw_id < rhs.raw_id;
    if (lhs.target_scope != rhs.target_scope) return lhs.target_scope.toIndex() < rhs.target_scope.toIndex();
    if (lhs.kind != rhs.kind) return @backingInt(lhs.kind) < @backingInt(rhs.kind);
    return std.mem.lessThan(u8, lhs.canonical_name, rhs.canonical_name);
}

fn sameOutputBindingGroup(lhs: OutputBindingCandidate, rhs: OutputBindingCandidate) bool {
    // Redeclarations share the producer ID and storage scope. Their actual
    // identifier StringValue (or exact ID-keyed output alias) must agree too.
    return lhs.raw_id == rhs.raw_id and lhs.target_scope == rhs.target_scope and lhs.kind == rhs.kind and
        std.mem.eql(u8, lhs.canonical_name, rhs.canonical_name);
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
    return parent.tag == .ts_module_declaration and parent.data.binary.left == @as(NodeIndex, @fromBackingInt(@intCast(child_raw)));
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

fn collectOutputNonSimpleParameterScopes(
    self: *Transformer,
    editor: *SemanticEditor,
    root: NodeIndex,
    scopes: *std.AutoHashMapUnmanaged(u32, void),
) Transformer.Error!void {
    const reachable = ast_walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root) catch return error.OutOfMemory;
    defer self.allocator.free(reachable);
    const Params = @import("../es2015_params.zig").ES2015Params(Transformer);
    // Scopes already owned by an emitted node; a parameter scope taken over by
    // a lowering (a Flow component wrapper, for example) keeps that owner.
    var owned: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer owned.deinit(self.allocator);
    for (reachable) |raw| {
        if (self.outputOwnedScope(@fromBackingInt(@intCast(raw)))) |scope| try owned.put(self.allocator, scope.toIndex(), {});
    }
    for (reachable) |raw| {
        if (raw >= self.ast.nodes.items.len) continue;
        const function = self.ast.nodes.items[raw];
        switch (function.tag) {
            .arrow_function_expression,
            .function_declaration,
            .function_expression,
            .function,
            .method_definition,
            => {},
            else => continue,
        }
        const function_scope = self.outputOwnedScope(@fromBackingInt(@intCast(raw))) orelse continue;
        if (function_scope.isNone() or function_scope.toIndex() >= editor.scopes.items.len) continue;
        const parameter_scope = editor.scopes.items[function_scope.toIndex()].parent;
        if (parameter_scope.isNone() or parameter_scope.toIndex() >= editor.scopes.items.len) continue;
        const params = self.ast.functionParamsList(function);
        if (params.len == 0 or !Params.hasDefaultOrRest(self, params)) continue;
        try scopes.put(self.allocator, parameter_scope.toIndex(), {});
        // A retained non-simple list owns the parameter scope. Transforms copy
        // the list without its owner; default values would then resolve in the
        // body scope and bind to a same-named body `var` (#5652). Attach it
        // here, once the final function node is known to own the body scope
        // whose parent is that parameter scope, so the list and body agree.
        const slot: u32 = if (function.tag == .arrow_function_expression) 0 else 1;
        const params_idx = self.ast.readExtraNode(function.data.extra, slot);
        if (params_idx.isNone() or self.outputOwnedScope(params_idx) != null) continue;
        // Only a real parameter environment (a function-kind scope); a rebuilt
        // constructor's function scope can sit directly under its class body.
        if (editor.scopes.items[parameter_scope.toIndex()].kind != .function) continue;
        if (owned.contains(parameter_scope.toIndex())) continue;
        try editor.scope_owner_map.put(self.allocator, @backingInt(params_idx), parameter_scope.toIndex());
        try owned.put(self.allocator, parameter_scope.toIndex(), {});
    }
}

fn outputBindingTargetScope(
    self: *Transformer,
    editor: *SemanticEditor,
    non_simple_parameter_scopes: *const std.AutoHashMapUnmanaged(u32, void),
    lexical_scope: ScopeId,
    symbol: Symbol,
    is_declaration_name: bool,
    output_var: bool,
) ScopeId {
    if (is_declaration_name) return lexical_scope;
    // A retained non-simple formal list has a parameter environment distinct
    // from the body's var scope. Once lowering makes that list simple, params
    // share the emitted function scope and follow the usual var-scope rule.
    if (symbol.kind == .parameter and non_simple_parameter_scopes.contains(symbol.scope_id.toIndex()))
        return symbol.scope_id;
    if (symbol.kind.declFlags().function_scoped or
        (output_var and (isGeneratedOutputVar(symbol) or symbol.decl_flags.is_default_export)))
        return self.nearestVarScope(lexical_scope);
    // Module/function declarations can be wrapped in generated try blocks by
    // resource lowering. Their original var boundary still encloses the code.
    if (output_var and !symbol.scope_id.isNone() and symbol.scope_id.toIndex() < editor.scopes.items.len and
        editor.scopes.items[symbol.scope_id.toIndex()].kind.isVarScope() and
        self.nearestVarScope(lexical_scope) == symbol.scope_id and
        scopeWithin(editor.scopes.items, lexical_scope, symbol.scope_id)) return symbol.scope_id;
    return lexical_scope;
}

/// Several sloppy block functions with one name all alias the analyzer's
/// var-scope function symbol (Annex B: each block declaration, when
/// evaluated, assigns that var binding). They are one runtime binding.
fn sameIdentifierStringValue(allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8) EditorError!bool {
    if (std.mem.eql(u8, lhs, rhs)) return true;
    const lhs_name = try Scanner.decodeIdentifierEscapesAlloc(allocator, lhs);
    defer if (lhs_name.ptr != lhs.ptr) allocator.free(lhs_name);
    const rhs_name = try Scanner.decodeIdentifierEscapesAlloc(allocator, rhs);
    defer if (rhs_name.ptr != rhs.ptr) allocator.free(rhs_name);
    return std.mem.eql(u8, lhs_name, rhs_name);
}

fn isAnnexBBlockFunctionAliasGroup(self: *Transformer, editor: *SemanticEditor, groups: []const OutputBindingGroup, raw_id: u32) EditorError!bool {
    const scopes = editor.scopes.items;
    const symbol = editor.symbols.items[raw_id];
    // A same-named `var` shares the binding too (#5803), so its symbol may be a var.
    if (!(symbol.kind.isFunctionLike() or symbol.kind == .variable_var) or symbol.scope_id.isNone() or
        symbol.scope_id.toIndex() >= scopes.len) return false;
    if (!scopes[symbol.scope_id.toIndex()].kind.isVarScope()) return false;
    const symbol_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
    var has_block_function = false;
    for (groups) |group| {
        // This validates an already selected ID; it never selects one by name.
        // Scope/function shape cannot legitimize an unrelated copied var ID.
        if (!try sameIdentifierStringValue(self.allocator, symbol_name, group.name)) {
            const renames = self.block_rename_map orelse return false;
            const renamed = renames.get(raw_id) orelse return false;
            if (!try sameIdentifierStringValue(self.allocator, renamed, group.name)) return false;
        }
        if (group.kind != symbol.kind or group.lexical_scope.isNone() or group.lexical_scope.toIndex() >= scopes.len) return false;
        const lexical = scopes[group.lexical_scope.toIndex()];
        // The unchanged outer var declaration participates in validation too.
        if (group.lexical_scope == symbol.scope_id and group.target_scope == symbol.scope_id) continue;
        if (lexical.kind.isVarScope() or lexical.is_strict or !group.is_function_declaration) return false;
        has_block_function = true;
        if (self.nearestVarScope(group.lexical_scope) != symbol.scope_id) return false;
        if (self.ast.getNode(group.first_node).tag != .binding_identifier) return false;
    }
    return has_block_function;
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
    bindOutputScopesAndReferencesChecked(self, root, root_scope) catch |err| return editError(err);
}

/// Producers must select storage identities before final output placement.
/// Keep conflicts observable without inventing a new ID or adopting a
/// same-spelled binding. The production entry treats a conflict as a compiler
/// invariant failure, matching other invalid semantic edits.
pub fn bindOutputScopesAndReferencesChecked(self: *Transformer, root: NodeIndex, root_scope: ScopeId) EditorError!void {
    const editor = try editorFor(self);
    if (self.outputOwnedScope(root) == null) {
        try editor.scope_owner_map.put(self.allocator, @backingInt(root), @backingInt(root_scope));
    }
    var non_simple_parameter_scopes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer non_simple_parameter_scopes.deinit(self.allocator);
    try collectOutputNonSimpleParameterScopes(self, editor, root, &non_simple_parameter_scopes);
    var stack: std.ArrayList(OutputScopeWork) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    var output_refs: std.ArrayList(OutputReferenceScope) = .empty;
    defer output_refs.deinit(self.allocator);
    var output_bindings: std.ArrayList(OutputBindingCandidate) = .empty;
    defer {
        for (output_bindings.items) |binding| if (binding.canonical_name_owned) self.allocator.free(binding.canonical_name);
        output_bindings.deinit(self.allocator);
    }
    try stack.append(self.allocator, .{ .node = root, .scope = root_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone() or @backingInt(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        var scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (node.tag == .import_expression) {
            const provenance = editor.node_scope_provenance.get(work.node) orelse return error.InvalidScope;
            if (provenance.scope != scope) return error.InvalidScope;
            try self.transformed_node_scope_provenance.put(self.allocator, work.node, provenance);
        }
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
            if (!param.isNone() and @backingInt(param) >= self.parser_node_count and self.ast.getNode(param).tag == .binding_identifier) {
                // A generated catch binding must arrive with its producer-owned
                // identity. Finalization must not repair missing identities.
                if (self.getSymbolIdAt(param) == null)
                    std.debug.panic("generated catch binding has no producer SymbolId", .{});
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
            !isNamespaceDeclarationNameBinding(self.ast, @backingInt(work.parent), raw) and
            !isEnumDeclarationNameBinding(self.ast, @backingInt(work.parent), raw))
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
                    outputBindingTargetScope(self, editor, &non_simple_parameter_scopes, scope, symbol, is_declaration_name, output_var);
                if (target_scope.isNone()) std.debug.panic("moved source binding has no emitted scope", .{});
                if (symbol.scope_id != target_scope)
                    editor.relocateSymbolAs(@fromBackingInt(@intCast(id)), target_scope, work.node) catch |err| return editError(err);
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
                        outputBindingTargetScope(self, editor, &non_simple_parameter_scopes, scope, symbol, is_declaration_name, output_var);
                    if (!target_scope.isNone()) {
                        const name = try self.ast.getTextStable(self.allocator, node.data.string_ref);
                        var identity_spelling = name;
                        if (self.block_rename_map) |renames| {
                            if (renames.get(id)) |renamed| {
                                const source_name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
                                if (!try sameIdentifierStringValue(self.allocator, name, source_name) and
                                    !try sameIdentifierStringValue(self.allocator, name, renamed)) return error.InvalidSymbol;
                                identity_spelling = renamed;
                            }
                        }
                        const canonical_name = try Scanner.decodeIdentifierEscapesAlloc(self.allocator, identity_spelling);
                        errdefer if (canonical_name.ptr != identity_spelling.ptr) self.allocator.free(canonical_name);
                        try output_bindings.append(self.allocator, .{
                            .node = work.node,
                            .raw_id = id,
                            .lexical_scope = scope,
                            .target_scope = target_scope,
                            .kind = symbol.kind,
                            .name = name,
                            .canonical_name = canonical_name,
                            .canonical_name_owned = canonical_name.ptr != identity_spelling.ptr,
                            .needs_placement = symbol.synthetic_name.len > 0 or symbol.scope_id != target_scope,
                            .is_function_declaration = is_declaration_name,
                        });
                    }
                }
            }
        }
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier or node.tag == .jsx_identifier) {
            if (self.tracked_runtime_helper_ref_index.get(raw)) |tracked_index| {
                // The helper call already owns its exact SymbolId. Lowering
                // may move it under generated blocks/functions, so update the
                // reference scope from this final AST walk.
                if (scope.isNone() or tracked_index >= self.tracked_runtime_helper_refs.items.len)
                    std.debug.panic("runtime helper reference has no exact output scope", .{});
                editor.moveReference(work.node, scope, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
                self.tracked_runtime_helper_refs.items[tracked_index].scope = scope;
            } else if (self.exact_output_ref_symbol_ids.get(raw)) |exact_id| {
                if (scope.isNone() or exact_id >= editor.symbols.items.len)
                    std.debug.panic("generated reference has no exact output owner", .{});
                const flags: ReferenceFlags = if (work.parent.isNone()) .{ .read = true } else generatedReferenceFlags(self.ast.getNode(work.parent), work.node, node.tag);
                try output_refs.append(self.allocator, .{ .node = work.node, .scope = scope, .raw_id = exact_id, .exact = true, .flags = flags });
            } else {
                var raw_id = outputSymbolIdAt(self, editor, work.node);
                if (raw_id == null) {
                    if (editor.referenceForNode(work.node) catch |err| return editError(err)) |reference| {
                        raw_id = @backingInt(reference.symbol_id);
                    }
                }
                if (raw_id) |id| {
                    if (id < editor.symbols.items.len) {
                        try output_refs.append(self.allocator, .{ .node = work.node, .scope = scope, .raw_id = id });
                    }
                }
            }
        }
        if (node.tag == .switch_statement) {
            const extra = node.data.extra;
            if (extra + 2 >= self.ast.extra_data.items.len) continue;
            const discriminant: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[extra]));
            if (!discriminant.isNone()) try stack.append(self.allocator, .{ .node = discriminant, .scope = work.scope, .parent = work.node, .grandparent = work.parent });
            const cases_start = self.ast.extra_data.items[extra + 1];
            const cases_len = self.ast.extra_data.items[extra + 2];
            if (cases_start > self.ast.extra_data.items.len or cases_len > self.ast.extra_data.items.len - cases_start) continue;
            for (self.ast.extra_data.items[cases_start .. cases_start + cases_len]) |raw_case| {
                try stack.append(self.allocator, .{ .node = @fromBackingInt(@intCast(raw_case)), .scope = scope, .parent = work.node, .grandparent = work.parent });
            }
            continue;
        }
        var it = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (it.next()) |child| {
            const child_scope = if (childSkipsOutputScope(self.ast, raw, @backingInt(child))) work.scope else scope;
            try stack.append(self.allocator, .{ .node = child, .scope = child_scope, .parent = work.node, .grandparent = work.parent });
        }
    }

    // Final placement can update an existing storage's scope or spelling.
    // Distinct storage must already have distinct producer-selected IDs;
    // this pass neither splits identities nor merges by matching names.
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
        var needs_placement = false;
        var is_function_declaration = false;
        for (output_bindings.items[candidate_start..candidate_end]) |binding| {
            needs_placement = needs_placement or binding.needs_placement;
            is_function_declaration = is_function_declaration or binding.is_function_declaration;
        }
        try binding_groups.append(self.allocator, .{
            .raw_id = candidate.raw_id,
            .target_scope = candidate.target_scope,
            .lexical_scope = candidate.lexical_scope,
            .kind = candidate.kind,
            .name = candidate.name,
            .first_node = candidate.node,
            .needs_placement = needs_placement,
            .is_function_declaration = is_function_declaration,
        });
        candidate_start = candidate_end;
    }
    var group_cursor: usize = 0;
    while (group_cursor < binding_groups.items.len) {
        const raw_id = binding_groups.items[group_cursor].raw_id;
        var group_end = group_cursor + 1;
        while (group_end < binding_groups.items.len and binding_groups.items[group_end].raw_id == raw_id) : (group_end += 1) {}
        if (raw_id >= editor.symbols.items.len) std.debug.panic("synthetic output binding has invalid SymbolId", .{});
        // Splitting these would give each block its own identity, so
        // mangling names them apart and the outer reads see only one (#5773).
        if (group_end - group_cursor > 1 and
            try isAnnexBBlockFunctionAliasGroup(self, editor, binding_groups.items[group_cursor..group_end], @intCast(raw_id)))
        {
            group_cursor = group_end;
            continue;
        }
        if (group_end - group_cursor != 1) return error.InvalidSymbol;
        if (!binding_groups.items[group_cursor].needs_placement) {
            group_cursor = group_end;
            continue;
        }
        const original_name = if (editor.symbols.items[raw_id].synthetic_name.len > 0)
            editor.symbols.items[raw_id].synthetic_name
        else
            self.ast.getText(editor.symbols.items[raw_id].name);
        const primary_binding = binding_groups.items[group_cursor];
        const editor_binding_id = outputSymbolIdAt(self, editor, primary_binding.first_node) orelse std.debug.panic("primary synthetic binding lost its SymbolId", .{});
        if (editor_binding_id != raw_id) std.debug.panic("primary synthetic binding changed SymbolId", .{});
        const existing_target_identity = primary_binding.target_scope.toIndex() < editor.scope_maps.items.len and
            editor.scope_maps.items[primary_binding.target_scope.toIndex()].get(primary_binding.name) == @as(?usize, raw_id) and
            std.mem.eql(u8, original_name, primary_binding.name);
        if (primary_binding.target_scope.toIndex() < editor.scope_maps.items.len) {
            if (editor.scope_maps.items[primary_binding.target_scope.toIndex()].get(primary_binding.name)) |existing_raw| {
                if (existing_raw != raw_id and existing_raw < editor.symbols.items.len) {
                    const existing = editor.symbols.items[existing_raw];
                    const existing_name = if (existing.synthetic_name.len > 0) existing.synthetic_name else self.ast.getText(existing.name);
                    if (primary_binding.kind == .variable_var and existing.kind == .variable_var and
                        existing.scope_id == primary_binding.target_scope and std.mem.eql(u8, existing_name, primary_binding.name))
                    {
                        return error.InvalidSymbol;
                    }
                }
            }
        }
        if (!existing_target_identity and
            (editor.symbols.items[raw_id].scope_id != primary_binding.target_scope or
                !std.mem.eql(u8, original_name, primary_binding.name)))
        {
            editor.relocateSymbolAs(@fromBackingInt(@intCast(raw_id)), primary_binding.target_scope, primary_binding.first_node) catch |err| return editError(err);
        }
        group_cursor = group_end;
    }

    for (output_refs.items) |reference| {
        if (reference.raw_id >= editor.symbols.items.len) continue;
        if (reference.exact) {
            if (!scopeVisibleFrom(editor.scopes.items, editor.symbols.items[reference.raw_id].scope_id, reference.scope))
                std.debug.panic("exact generated SymbolId is not visible from its output scope", .{});
            const symbol: SymbolId = @fromBackingInt(@intCast(reference.raw_id));
            const maybe_reference = editor.referenceForNode(reference.node) catch |err| return editError(err);
            if (maybe_reference != null) {
                editor.relocateReference(
                    reference.node,
                    reference.scope,
                    symbol,
                    Reference.NO_STMT,
                    Reference.NO_STMT,
                ) catch |err| return editError(err);
                editor.updateReferenceFlags(reference.node, reference.flags) catch |err| return editError(err);
            } else {
                const raw = @backingInt(reference.node);
                if (raw < editor.symbol_ids.items.len and editor.symbol_ids.items[raw] != null and
                    editor.symbol_ids.items[raw] != reference.raw_id)
                {
                    editor.symbol_ids.items[raw] = null;
                }
                if (raw < editor.symbol_ids.items.len and editor.symbol_ids.items[raw] == reference.raw_id) {
                    editor.addCopiedReference(
                        reference.node,
                        symbol,
                        reference.scope,
                        reference.flags,
                        Reference.NO_STMT,
                        Reference.NO_STMT,
                    ) catch |err| return editError(err);
                } else {
                    editor.addReference(
                        reference.node,
                        symbol,
                        reference.scope,
                        reference.flags,
                        Reference.NO_STMT,
                        Reference.NO_STMT,
                    ) catch |err| return editError(err);
                }
            }
            const raw = @backingInt(reference.node);
            if (self.symbol_ids.items.len <= raw)
                try self.symbol_ids.appendNTimes(self.allocator, null, raw + 1 - self.symbol_ids.items.len);
            self.symbol_ids.items[raw] = reference.raw_id;
            _ = self.exact_output_ref_symbol_ids.remove(raw);
            continue;
        }
        // Source counterparts now participate in validation too. Search the
        // ID-sorted groups instead of scanning every user binding for each use.
        const group_start = std.sort.lowerBound(OutputBindingGroup, binding_groups.items, reference.raw_id, struct {
            fn compare(id: u32, group: OutputBindingGroup) std.math.Order {
                return std.math.order(id, group.raw_id);
            }
        }.compare);
        const only_group: ?OutputBindingGroup = if (group_start < binding_groups.items.len and
            binding_groups.items[group_start].raw_id == reference.raw_id and
            (group_start + 1 == binding_groups.items.len or binding_groups.items[group_start + 1].raw_id != reference.raw_id))
            binding_groups.items[group_start]
        else
            null;
        if (only_group != null and only_group.?.needs_placement and
            !scopeVisibleFrom(editor.scopes.items, editor.symbols.items[only_group.?.raw_id].scope_id, reference.scope))
        {
            try bridgeOutputReferenceScopeToBinding(editor, editor.symbols.items[only_group.?.raw_id].scope_id, reference.scope);
        }
        // The storage identity was selected by its producer, including any
        // explicit producer split. Placement never creates or adopts an ID.
        const resolved_id = reference.raw_id;
        const maybe_reference = editor.referenceForNode(reference.node) catch |err| return editError(err);
        if (!scopeVisibleFrom(editor.scopes.items, editor.symbols.items[resolved_id].scope_id, reference.scope)) {
            // The emitted AST can move a declaration behind a function
            // boundary while leaving an old use outside it (for example an
            // unsupported TLA export). That use now resolves as a global
            // reference. Remove the stale source edge and never attach an
            // invisible local SymbolId.
            if (outputReferenceName(self.ast, reference.node)) |name| {
                if (nearestOutputSymbolBySpelling(editor, name, reference.scope) == null)
                    try detachInvisibleOutputReferenceAsExternal(self, editor, reference.node, maybe_reference != null);
            }
            continue;
        }
        if (maybe_reference == null) continue;
        editor.relocateReference(
            reference.node,
            reference.scope,
            @fromBackingInt(@intCast(resolved_id)),
            Reference.NO_STMT,
            Reference.NO_STMT,
        ) catch |err| {
            if (err != error.ReferenceNotFound) return editError(err);
        };
        const raw = @backingInt(reference.node);
        if (self.symbol_ids.items.len <= raw)
            try self.symbol_ids.appendNTimes(self.allocator, null, raw + 1 - self.symbol_ids.items.len);
        self.symbol_ids.items[raw] = resolved_id;
    }
}

/// Remember a generated `_newTarget` use with its lexical arrow owner. This
/// allows an inner wrapper call's capture argument to bind to the outer
/// wrapper even though that outer binding is created after visiting its body.
pub fn trackNativeParameterArrowRef(self: *Transformer, owner: NodeIndex, node: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (owner.isNone() or node.isNone()) std.debug.panic("native parameter arrow reference has no exact owner", .{});
    try self.native_parameter_arrow_refs.append(self.allocator, .{ .owner = owner, .node = node });
}

/// Bind only refs recorded under this source arrow to its generated wrapper
/// parameter SID. The final output walk supplies each use's actual ScopeId.
pub fn bindNativeParameterArrowRefs(self: *Transformer, owner: NodeIndex, symbol: ?SymbolId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const id = symbol orelse return;
    var index: usize = 0;
    while (index < self.native_parameter_arrow_refs.items.len) {
        const pending = self.native_parameter_arrow_refs.items[index];
        if (pending.owner != owner) {
            index += 1;
            continue;
        }
        const raw = @backingInt(pending.node);
        if (self.exact_output_ref_symbol_ids.get(raw)) |existing| {
            if (existing != @backingInt(id)) std.debug.panic("native parameter reference was assigned to two wrapper symbols", .{});
        } else {
            try self.exact_output_ref_symbol_ids.put(self.allocator, raw, @backingInt(id));
        }
        _ = self.native_parameter_arrow_refs.swapRemove(index);
    }
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
    if (node.isNone() or @backingInt(node) >= ast.nodes.items.len) return null;
    const output_node = ast.getNode(node);
    return switch (output_node.tag) {
        .identifier_reference, .assignment_target_identifier, .jsx_identifier => ast.getText(output_node.data.string_ref),
        else => null,
    };
}

/// Fresh aliases already carry their producer-selected SymbolId. A numeric
/// suffix is part of a spelling, not evidence that an inner base-name binding
/// owns the reference. Only an exact lexical spelling can override that ID.
fn nearestOutputSymbolBySpelling(editor: *SemanticEditor, spelling: []const u8, start: ScopeId) ?u32 {
    if (start.isNone()) return null;
    // `\u0078` 과 `x` 는 같은 이름이다. 변환기가 만든 바인딩은 디코딩 키 하나만 갖기도 하므로
    // 스코프마다 두 표기를 함께 봐야 안쪽 바인딩이 이긴다 (#5667).
    var decode_buf: [256]u8 = undefined;
    const decoded = Scanner.decodeIdentifierEscapesInto(spelling, &decode_buf) orelse spelling;
    var current = start;
    var hops: usize = 0;
    while (!current.isNone() and hops < editor.scopes.items.len) : (hops += 1) {
        if (current.toIndex() >= editor.scopes.items.len) return null;
        const map = editor.scope_maps.items[current.toIndex()];
        if (map.get(spelling)) |symbol| return @intCast(symbol);
        if (decoded.ptr != spelling.ptr) {
            if (map.get(decoded)) |symbol| return @intCast(symbol);
        }
        current = editor.scopes.items[current.toIndex()].parent;
    }
    return null;
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
    const raw = @backingInt(node);
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
        if (visit.node.isNone() or @backingInt(visit.node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(visit.node);
        var scope = visit.incoming;
        const owner_scope = if (self.scope_owner_removed.contains(raw)) null else self.transformed_scope_owner_map.get(raw) orelse
            self.scope_owner_map.get(raw) orelse
            if (self.semantic_editor) |*editor| editor.scope_owner_map.get(raw) else null;
        if (owner_scope) |owner_scope_id| {
            if (owner_scope_id >= (if (self.semantic_editor) |*editor| editor.scopes.items.len else self.scopes.len))
                std.debug.panic("generated reference scope owner is invalid", .{});
            scope = @fromBackingInt(@intCast(owner_scope_id));
        }
        const trace = try traces.getOrPut(self.allocator, raw);
        if (trace.found_existing) {
            if (trace.value_ptr.scope != scope) trace.value_ptr.ambiguous_scope = true;
            trace.value_ptr.flags.read = trace.value_ptr.flags.read or visit.flags.read;
            trace.value_ptr.flags.write = trace.value_ptr.flags.write or visit.flags.write;
        } else {
            trace.value_ptr.* = .{ .scope = scope, .flags = visit.flags };
        }
        const key: GeneratedNodeVisitKey = .{ .node = raw, .scope = @backingInt(scope) };
        const prior = try visited.getOrPut(self.allocator, key);
        if (prior.found_existing) continue;
        const parent = self.ast.getNode(visit.node);
        // A function declaration owns its own scope, but its name binds in the
        // scope the declaration was reached from (#5453).
        const declaration_name = functionDeclarationName(self, parent);
        var children = ast_walk.children(self.ast, parent);
        while (children.next()) |child| {
            if (child.isNone() or @backingInt(child) >= self.ast.nodes.items.len) continue;
            const child_node = self.ast.getNode(child);
            const flags = if (child_node.tag == .identifier_reference or child_node.tag == .assignment_target_identifier)
                generatedReferenceFlags(parent, child, child_node.tag)
            else
                ReferenceFlags{};
            const child_scope = if (child == declaration_name) visit.incoming else scope;
            try stack.append(self.allocator, .{ .node = child, .incoming = child_scope, .flags = flags });
        }
    }
    return traces;
}

fn functionDeclarationName(self: *Transformer, node: Node) NodeIndex {
    if (node.tag != .function_declaration) return .none;
    const slot = node.data.extra + ast_mod.FunctionExtra.name;
    if (slot >= self.ast.extra_data.items.len) return .none;
    return @fromBackingInt(@intCast(self.ast.extra_data.items[slot]));
}

const GeneratedLoopNodeSet = std.AutoHashMapUnmanaged(u32, void);

fn appendGeneratedLoopExtraList(self: *Transformer, stack: *std.ArrayList(NodeIndex), extra_base: u32, start_off: u32, len_off: u32) Transformer.Error!void {
    const extra = self.ast.extra_data.items;
    if (extra_base >= extra.len or start_off >= extra.len - extra_base or len_off >= extra.len - extra_base) return;
    const start = extra[extra_base + start_off];
    const len = extra[extra_base + len_off];
    if (start > extra.len or len > extra.len - start) return;
    for (extra[start .. start + len]) |raw| try stack.append(self.allocator, @fromBackingInt(@intCast(raw)));
}

fn collectGeneratedLoopNodes(self: *Transformer, root: NodeIndex) Transformer.Error!GeneratedLoopNodeSet {
    var nodes: GeneratedLoopNodeSet = .empty;
    errdefer nodes.deinit(self.allocator);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |node| {
        if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(node);
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
                if (parent.data.extra < extra.len) try stack.append(self.allocator, @fromBackingInt(@intCast(extra[parent.data.extra])));
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
        const scope: ScopeId = @fromBackingInt(@intCast(owner_scope));
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
        editor.reparentScope(@fromBackingInt(@intCast(raw.*)), new_parent) catch |err| return editError(err);
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
        const node: NodeIndex = @fromBackingInt(@intCast(raw.*));
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
        const raw = @backingInt(node);
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
            const raw = @backingInt(node);
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
            const candidate: NodeIndex = @fromBackingInt(@intCast(node_raw));
            if (self.ast.getNode(candidate).tag != .binding_identifier) continue;
            binding_node = candidate;
            if (final_nodes.contains(@intCast(node_raw))) break;
        }
        const binding = binding_node orelse std.debug.panic("live extracted loop temp has no output binding node", .{});
        editor.relocateSymbolAs(@fromBackingInt(@intCast(raw_id.*)), output_function_scope, binding) catch |err| return editError(err);
    }

    var moved_bindings: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer moved_bindings.deinit(self.allocator);
    var source_nodes_it = source_nodes.keyIterator();
    while (source_nodes_it.next()) |raw| {
        const node: NodeIndex = @fromBackingInt(@intCast(raw.*));
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
            if (prior_scope != @backingInt(binding_scope))
                std.debug.panic("one generator loop binding has multiple output scopes", .{});
            continue;
        }
        try moved_bindings.put(self.allocator, id_raw, @backingInt(binding_scope));
        const id: SymbolId = @fromBackingInt(@intCast(id_raw));
        if (editor.symbols.items[id_raw].scope_id != binding_scope)
            editor.relocateSymbolAs(id, binding_scope, node) catch |err| return editError(err);
    }
    var original_references: std.AutoHashMapUnmanaged(u32, Reference) = .empty;
    defer original_references.deinit(self.allocator);
    for (self.references) |reference| {
        if (reference.node_index.isNone()) continue;
        try original_references.put(self.allocator, @backingInt(reference.node_index), reference);
    }

    var live_refs: GeneratedLoopNodeSet = .empty;
    defer live_refs.deinit(self.allocator);
    for (runtime_refs) |node| {
        const raw = @backingInt(node);
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
        const target: SymbolId = @fromBackingInt(@intCast(target_id));
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
        const node: NodeIndex = @fromBackingInt(@intCast(raw.*));
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
            const candidate: NodeIndex = @fromBackingInt(@intCast(node_raw));
            if (self.ast.getNode(candidate).tag == .binding_identifier) {
                binding_node = candidate;
                binding_node_is_in_source = source_nodes.contains(@intCast(node_raw));
                if (binding_node_is_in_source) break;
            }
        }
        if (binding_node_is_in_source and !is_call_scope_binding) continue;
        const binding = binding_node orelse std.debug.panic("live extracted loop binding has no output binding node", .{});
        editor.relocateSymbolAs(@fromBackingInt(@intCast(raw_id.*)), output_function_scope, binding) catch |err| return editError(err);
    }
}

fn generatedReferenceFlags(parent: Node, child: NodeIndex, child_tag: Node.Tag) ReferenceFlags {
    if (child_tag == .assignment_target_identifier) return .{ .write = true };
    if (parent.tag == .assignment_expression and parent.data.binary.left == child) {
        const op: token_mod.Kind = @fromBackingInt(@intCast(parent.data.binary.flags));
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
        const node: NodeIndex = @fromBackingInt(@intCast(raw));
        const node_tag = self.ast.getNode(node).tag;
        if (node_tag != .identifier_reference and node_tag != .assignment_target_identifier) continue;
        if (!trace.flags.read and !trace.flags.write) std.debug.panic("generated state reference has no access mode", .{});
        const id: SymbolId = @fromBackingInt(@intCast(self.symbol_ids.items[raw].?));
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
        if (work.node.isNone() or @backingInt(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        var scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (isFunctionBoundary(node.tag) and self.outputOwnedScope(work.node) == null and raw >= self.parser_node_count) {
            scope = try self.addGeneratedFunctionScope(work.scope, work.node);
        }
        var it = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (it.next()) |child| {
            const child_scope = if (childSkipsOutputScope(self.ast, raw, @backingInt(child))) work.scope else scope;
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
    try stack.append(self.allocator, .{ .node = root, .scope = root_scope });
    while (stack.pop()) |work| {
        if (work.node.isNone() or @backingInt(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        var scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (isFunctionBoundary(node.tag)) {
            if (self.outputOwnedScope(work.node) == null and raw >= self.parser_node_count) {
                scope = try self.addGeneratedFunctionScope(work.scope, work.node);
            }
            if (node.tag == .function_expression or node.tag == .function_declaration) {
                const extra = node.data.extra;
                if (extra + 3 < self.ast.extra_data.items.len) {
                    const name: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[extra]));
                    if (!name.isNone() and @backingInt(name) >= self.parser_node_count and
                        self.ast.getNode(name).tag == .binding_identifier and self.getSymbolIdAt(name) == null)
                        std.debug.panic("generated function name has no producer SymbolId", .{});
                }
            }
            if (self.deferred_generator_helper_refs.fetchRemove(raw)) |deferred| {
                try self.relocateRuntimeHelperRef(deferred.value, scope);
            }
        }
        var it = @import("../../parser/ast_walk.zig").children(self.ast, node);
        while (it.next()) |child| {
            const child_scope = if (childSkipsOutputScope(self.ast, raw, @backingInt(child))) work.scope else scope;
            try stack.append(self.allocator, .{ .node = child, .scope = child_scope });
        }
    }
    self.deferred_generator_helper_refs.clearRetainingCapacity();
}

fn isFunctionBoundary(tag: @import("../../parser/ast.zig").Node.Tag) bool {
    return switch (tag) {
        .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition => true,
        else => false,
    };
}

fn generatedTempRefScope(self: *Transformer, source_scope: ScopeId, target_scope: ScopeId, old_scope: ScopeId, live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!ScopeId {
    const editor = try editorFor(self);
    if (old_scope == source_scope) return target_scope;
    if (scopeWithin(editor.scopes.items, old_scope, target_scope)) return old_scope;
    if (!scopeWithin(editor.scopes.items, old_scope, source_scope)) {
        // An extracted generator-loop function temporarily keeps its moved
        // body scopes under the enclosing source function until that outer
        // function's callback is assembled. Its own state callback is built
        // first, so reparent live body scopes under this callback while the
        // exact loop migration is still pending.
        if (self.deferred_generator_loop_migrations.get(@backingInt(source_scope))) |migration| {
            const enclosing_scope = migration.enclosing_function_scope;
            if (!migration.function_reparented and !enclosing_scope.isNone() and
                scopeWithin(editor.scopes.items, old_scope, enclosing_scope))
            {
                var cursor = old_scope;
                var frontier: ScopeId = .none;
                var has_live_scope = false;
                var hops: usize = 0;
                while (cursor != enclosing_scope and !cursor.isNone() and hops < editor.scopes.items.len) : (hops += 1) {
                    has_live_scope = has_live_scope or live_scopes.contains(@backingInt(cursor));
                    frontier = cursor;
                    cursor = editor.scopes.items[cursor.toIndex()].parent;
                }
                if (cursor == enclosing_scope) {
                    if (!has_live_scope or frontier.isNone()) return target_scope;
                    if (scopeWithin(editor.scopes.items, target_scope, frontier)) return target_scope;
                    if (!scopeWithin(editor.scopes.items, frontier, target_scope))
                        editor.reparentScope(frontier, target_scope) catch |err| return editError(err);
                    return old_scope;
                }
            }
        }
        if (self.deferred_generator_loop_migrations.get(@backingInt(old_scope))) |migration| {
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
        has_live_scope = has_live_scope or live_scopes.contains(@backingInt(cursor));
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
    const editor = try editorFor(self);
    const binding_id = self.getSymbolIdAt(temp.binding);
    const source_bound_id = if (source_scope.isNone()) null else self.bound_temp_symbols.get(
        syntheticTempSymbolKey(temp.name_span, variableScope(self, source_scope)),
    );
    const target_bound_id = if (binding_scope.isNone()) null else self.bound_temp_symbols.get(
        syntheticTempSymbolKey(temp.name_span, variableScope(self, binding_scope)),
    );
    if (source_bound_id != null and target_bound_id != null and source_bound_id.? != target_bound_id.?)
        std.debug.panic("state temp source and target registries disagree on SymbolId", .{});
    const registered_id = source_bound_id orelse target_bound_id;
    if (temp.symbol_id != null and binding_id != null and temp.symbol_id.? != binding_id.?)
        std.debug.panic("state temp producer and binding node disagree on SymbolId", .{});
    if (temp.symbol_id != null and registered_id != null and temp.symbol_id.? != registered_id.?)
        std.debug.panic("state temp producer and exact allocation registry disagree on SymbolId", .{});
    if (binding_id != null and registered_id != null and binding_id.? != registered_id.?)
        std.debug.panic("state temp binding and exact allocation registry disagree on SymbolId", .{});
    const exact_id = temp.symbol_id orelse binding_id orelse registered_id;
    if (registered_id) |raw_id| {
        if (raw_id >= editor.symbols.items.len) std.debug.panic("state temp allocation SymbolId is out of range", .{});
        const symbol = editor.symbols.items[raw_id];
        const source_var_scope = if (source_scope.isNone()) binding_scope else variableScope(self, source_scope);
        const target_var_scope = if (binding_scope.isNone()) source_var_scope else variableScope(self, binding_scope);
        if ((symbol.scope_id != source_var_scope and symbol.scope_id != target_var_scope) or
            symbol.kind != .variable_var or symbol.name.start != temp.name_span.start or
            symbol.name.end != temp.name_span.end or
            !std.mem.eql(u8, symbol.synthetic_name, self.ast.getText(temp.name_span)))
            std.debug.panic("state temp allocation registry points to an unrelated symbol", .{});
    }
    const id: SymbolId = if (exact_id) |raw_id| blk: {
        const existing: SymbolId = @fromBackingInt(@intCast(raw_id));
        editor.relocateSymbolAs(existing, binding_scope, temp.binding) catch |err| return editError(err);
        break :blk existing;
    } else blk: {
        const declared = editor.declare(temp.binding, temp.name_span, declaration_span, binding_scope, .variable_var, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        try setSymbolId(self, temp.binding, declared);
        break :blk declared;
    };
    try recordTempProducerSymbolId(self, temp.temp_producer_id, id);

    // Relocation updates the editor's copy of the node-to-symbol table. Keep
    // the transform's parallel table in sync as well; later output and
    // coverage passes read that table directly.
    if (self.getSymbolIdAt(temp.binding)) |existing| {
        if (existing != @backingInt(id)) std.debug.panic("state callback temp binding changed SymbolId", .{});
    } else try setSymbolId(self, temp.binding, id);
    for (self.generator_state_temp_refs.items) |pending| {
        if (pending.binding != temp.binding or !live.contains(@backingInt(pending.reference))) continue;
        const reference_scope = try generatedTempRefScope(self, source_scope, callback_scope, pending.scope, live_scopes);
        if (editor.referenceForNode(pending.reference) catch |err| return editError(err)) |existing| {
            if (existing.symbol_id != id or existing.scope_id != reference_scope or
                existing.flags.read != pending.flags.read or existing.flags.write != pending.flags.write)
                std.debug.panic("generated callback temp reference already has a different identity", .{});
        } else {
            editor.addReference(pending.reference, id, reference_scope, pending.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        }
        try setSymbolId(self, pending.reference, id);
    }
    try bindPendingTempProducerReferencesInCallback(
        self,
        temp.temp_producer_id,
        id,
        temp.name_span,
        source_scope,
        binding_scope,
        callback_scope,
        live,
        live_scopes,
        traces,
    );
    // Source temps carry producer identity. Only callback temps created after
    // state-machine assembly lack it and may take the exact-scope late-name
    // path here.
    if (temp.owner_scope.isNone()) es_helpers.markStandaloneLateSyntheticTemp(self, id, binding_scope);
    if (temp.symbol_id) |raw_id| {
        var nodes = live.iterator();
        while (nodes.next()) |entry| {
            const raw_node = entry.key_ptr.*;
            if (raw_node >= self.symbol_ids.items.len or self.symbol_ids.items[raw_node] != raw_id) continue;
            const node: NodeIndex = @fromBackingInt(@intCast(raw_node));
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
}

fn reparentLiveSourceScopes(self: *Transformer, source_scope: ScopeId, target_scope: ScopeId, live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!void {
    if (source_scope.isNone() or target_scope.isNone()) return;
    const editor = try editorFor(self);
    var it = live_scopes.iterator();
    while (it.next()) |entry| {
        const old_scope: ScopeId = @fromBackingInt(@intCast(entry.key_ptr.*));
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

/// Move only an expression directly evaluated in the relocated source scope.
/// Nested functions keep their own use scopes while their lexical root moves.
pub fn relocateNodeScopeProvenance(self: *Transformer, node: NodeIndex, source: ScopeId, target: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    const previous = editor.node_scope_provenance.get(node) orelse {
        if (self.ast.getNode(node).tag == .import_expression)
            std.debug.panic("moved import expression lost its creation scope provenance", .{});
        return;
    };
    if (previous.scope != source) return;
    editor.recordNodeScopeProvenance(node, target) catch |err| return editError(err);
    try self.transformed_node_scope_provenance.put(self.allocator, node, editor.node_scope_provenance.get(node).?);
    self.node_scope_provenance_changed = true;
}

pub fn reparentGeneratedBodyScopes(self: *Transformer, source_scope: ScopeId, target_scope: ScopeId, body: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or source_scope.isNone() or target_scope.isNone() or body.isNone()) return;
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, body);
    while (stack.pop()) |node| {
        if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(node);
        if (live.contains(raw)) continue;
        try live.put(self.allocator, raw, {});
        try self.relocateNodeScopeProvenance(node, source_scope, target_scope);
        var children = ast_walk.children(self.ast, self.ast.getNode(node));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    var scopes = try liveScopeOwners(self, &live);
    defer scopes.deinit(self.allocator);
    try reparentLiveSourceScopes(self, source_scope, target_scope, &scopes);
}

/// Bind a deferred generated temp from an exact SymbolId or its binding node
/// and final owner. A same-spelled scope-map entry is never an identity.
pub fn bindGeneratedTempByIdentity(
    editor: *SemanticEditor,
    binding: NodeIndex,
    name_span: Span,
    declaration_span: Span,
    lexical_scope: ScopeId,
    owner_scope: ScopeId,
    symbol_id: ?u32,
) EditorError!SymbolId {
    if (symbol_id) |raw_id| {
        if (raw_id >= editor.symbols.items.len) return error.InvalidSymbol;
        const id: SymbolId = @fromBackingInt(@intCast(raw_id));
        const symbol = editor.symbols.items[raw_id];
        if (symbol.scope_id != owner_scope or symbol.kind != .variable_var or
            symbol.name.start != name_span.start or symbol.name.end != name_span.end or
            !std.mem.eql(u8, symbol.synthetic_name, editor.ast.getText(name_span)))
            return error.InvalidSymbol;
        try editor.attachExistingBinding(binding, id);
        return id;
    }
    return editor.declare(
        binding,
        name_span,
        declaration_span,
        lexical_scope,
        .variable_var,
        Reference.NO_STMT,
        Reference.NO_STMT,
    );
}

fn bindTrackedCallbackTemp(self: *Transformer, temp: @import("lists.zig").HoistedStateTemp, declaration_span: Span, source_scope: ScopeId, callback_scope: ScopeId, live: *const std.AutoHashMapUnmanaged(u32, void), live_scopes: *const std.AutoHashMapUnmanaged(u32, void)) Transformer.Error!void {
    const editor = try editorFor(self);
    const owner_scope = variableScope(self, callback_scope);
    const temp_key = syntheticTempSymbolKey(temp.name_span, owner_scope);
    const registered_id = self.synthetic_temp_symbol_ids.get(temp_key);
    const bound_id = self.bound_temp_symbols.get(temp_key);
    if (registered_id != null and bound_id != null and registered_id.? != bound_id.?)
        std.debug.panic("callback temp allocation has conflicting exact SymbolIds", .{});
    if (temp.symbol_id) |producer_id| {
        if ((registered_id != null and registered_id.? != producer_id) or
            (bound_id != null and bound_id.? != producer_id))
            std.debug.panic("callback temp producer disagrees with its exact SymbolId registry", .{});
    }
    const known_id = temp.symbol_id orelse registered_id orelse bound_id;
    const id = bindGeneratedTempByIdentity(
        editor,
        temp.binding,
        temp.name_span,
        declaration_span,
        callback_scope,
        owner_scope,
        known_id,
    ) catch |err| return editError(err);
    try recordTempProducerSymbolId(self, temp.temp_producer_id, id);
    const bound = try self.bound_temp_symbols.getOrPut(self.allocator, temp_key);
    if (bound.found_existing and bound.value_ptr.* != @backingInt(id))
        std.debug.panic("callback temp allocation changed its exact SymbolId", .{});
    bound.value_ptr.* = @backingInt(id);
    es_helpers.markStandaloneLateSyntheticTemp(self, id, callback_scope);
    const temp_slot = @backingInt(temp.binding);
    if (temp_slot < self.symbol_ids.items.len) {
        if (self.symbol_ids.items[temp_slot]) |existing| {
            if (existing != @backingInt(id)) std.debug.panic("callback temp binding already has a different symbol", .{});
        } else try setSymbolId(self, temp.binding, id);
    } else try setSymbolId(self, temp.binding, id);
    for (self.generator_state_temp_refs.items) |pending| {
        if (pending.binding != temp.binding or !live.contains(@backingInt(pending.reference))) continue;
        const scope = try generatedTempRefScope(self, source_scope, callback_scope, pending.scope, live_scopes);
        if (editor.referenceForNode(pending.reference) catch |err| return editError(err)) |existing| {
            if (existing.symbol_id != id or existing.scope_id != scope or
                existing.flags.read != pending.flags.read or existing.flags.write != pending.flags.write)
                std.debug.panic("generated callback temp reference already has a different identity", .{});
        } else {
            editor.addReference(pending.reference, id, scope, pending.flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        }
        try setSymbolId(self, pending.reference, id);
    }
    try bindPendingTempProducerReferencesInCallback(
        self,
        temp.temp_producer_id,
        id,
        temp.name_span,
        source_scope,
        callback_scope,
        callback_scope,
        live,
        live_scopes,
        null,
    );
}

/// Record exact source binding nodes moved into a generated function body.
/// Their final scope is chosen later, after generated block scopes exist.
pub fn moveGeneratedFunctionBodyBindings(self: *Transformer, source_scope: ScopeId, function_scope: ScopeId, body: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or source_scope.isNone() or function_scope.isNone() or source_scope == function_scope) return;
    const Work = struct { node: NodeIndex, scope: ScopeId };
    var work_stack: std.ArrayList(Work) = .empty;
    defer work_stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    try work_stack.append(self.allocator, .{ .node = body, .scope = function_scope });
    while (work_stack.pop()) |work| {
        const node = work.node;
        if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        // This producer has selected the actual generated function owner.
        // Move only direct source uses; nested functions retain their own IDs.
        const output_scope = self.outputOwnedScope(node) orelse work.scope;
        try self.relocateNodeScopeProvenance(node, source_scope, output_scope);
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
        while (it.next()) |child| try work_stack.append(self.allocator, .{ .node = child, .scope = output_scope });
    }
    var nested_scopes = try liveScopeOwners(self, &seen);
    defer nested_scopes.deinit(self.allocator);
    try reparentLiveSourceScopes(self, source_scope, function_scope, &nested_scopes);
}

pub fn bindGeneratedFunctionTemps(self: *Transformer, source_scope: ScopeId, function_scope: ScopeId, body: NodeIndex, temps: []const @import("lists.zig").HoistedStateTemp, span: Span) Transformer.Error!void {
    if (!self.semantic_edit_enabled or function_scope.isNone()) return;
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(self.allocator);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, body);
    while (stack.pop()) |node| {
        if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(node);
        if (live.contains(raw)) continue;
        try live.put(self.allocator, raw, {});
        var it = @import("../../parser/ast_walk.zig").children(self.ast, self.ast.getNode(node));
        while (it.next()) |child| try stack.append(self.allocator, child);
    }
    var live_scopes = try liveScopeOwners(self, &live);
    defer live_scopes.deinit(self.allocator);
    try reparentLiveSourceScopes(self, source_scope, function_scope, &live_scopes);
    try es_helpers.relocatePrivateReferences(self, body, function_scope);
    var traces = try collectGeneratedNodeTraces(self, body, function_scope);
    defer traces.deinit(self.allocator);
    for (temps) |temp| try bindStateCallbackTemp(self, temp, span, source_scope, function_scope, function_scope, &live, &live_scopes, &traces);
}

/// AST 생성 시점의 current_scope와 실제 삽입 위치가 다를 때 명시한 스코프에 등록한다.
pub fn addGeneratedFunctionScope(self: *Transformer, parent: ScopeId, owner: NodeIndex) Transformer.Error!ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const editor = try editorFor(self);
    const scope = editor.addScope(parent, owner, .function, false) catch |err| return editError(err);
    const key = @backingInt(owner);
    try self.transformed_scope_owner_map.put(self.allocator, key, @backingInt(scope));
    try self.scope_owner_origins.put(self.allocator, key, key);
    return scope;
}

pub fn addGeneratedScope(self: *Transformer, parent: ScopeId, owner: NodeIndex, kind: @import("../../semantic/scope.zig").ScopeKind) Transformer.Error!ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const editor = try editorFor(self);
    const scope = editor.addScope(parent, owner, kind, false) catch |err| return editError(err);
    const key = @backingInt(owner);
    try self.transformed_scope_owner_map.put(self.allocator, key, @backingInt(scope));
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

/// A named function expression's immutable name environment has no AST
/// owner of its own. Reserve it before constructor/helper references exist.
pub fn reserveGeneratedNameScope(self: *Transformer, parent: ScopeId) Transformer.Error!ScopeId {
    if (!self.semantic_edit_enabled) return .none;
    const editor = try editorFor(self);
    return editor.addScope(parent, .none, .block, true) catch |err| return editError(err);
}

pub fn bindReservedFunctionOwner(self: *Transformer, scope: ScopeId, owner: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    if (scope.isNone() or scope.toIndex() >= editor.scopes.items.len or owner.isNone() or
        @backingInt(owner) >= self.ast.nodes.items.len or
        (self.ast.getNode(owner).tag != .function_expression and self.ast.getNode(owner).tag != .function_declaration and
            self.ast.getNode(owner).tag != .method_definition and self.ast.getNode(owner).tag != .arrow_function_expression))
        std.debug.panic("invalid reserved function scope owner", .{});
    const raw = @backingInt(owner);
    if (editor.scope_owner_map.contains(raw) or self.transformed_scope_owner_map.contains(raw))
        std.debug.panic("reserved function scope owner already bound", .{});
    try editor.scope_owner_map.put(self.allocator, raw, @backingInt(scope));
    try self.transformed_scope_owner_map.put(self.allocator, raw, @backingInt(scope));
    try self.scope_owner_origins.put(self.allocator, raw, raw);
}

/// A named function expression's self-binding lives in a block scope between
/// the function (or its parameter scope) and their parent, as the analyzer
/// models it (and the exact gate accepts for generated names).
pub fn addFunctionExpressionNameScope(self: *Transformer, func: NodeIndex) Transformer.Error!?ScopeId {
    if (!self.semantic_edit_enabled) return null;
    const function_scope = self.outputOwnedScope(func) orelse return null;
    const editor = try editorFor(self);
    var inner = function_scope;
    const params = self.ast.readExtraNode(self.ast.getNode(func).data.extra, 1);
    if (!params.isNone()) if (self.outputOwnedScope(params)) |params_scope| {
        if (params_scope == editor.scopes.items[inner.toIndex()].parent) inner = params_scope;
    };
    const outer = editor.scopes.items[inner.toIndex()];
    const block = editor.addScope(outer.parent, .none, .block, outer.is_strict) catch |err| return editError(err);
    editor.reparentScope(inner, block) catch |err| return editError(err);
    return block;
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

/// Static field initializers are emitted after their class. Move the lexical
/// scope roots inside a visited initializer out of the source class scope so
/// generated class-self reads resolve through the emitted class binding.
pub fn reparentMovedStaticInitializerScopes(
    self: *Transformer,
    root: NodeIndex,
    source_class_scope: ScopeId,
    output_scope: ScopeId,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (root.isNone() or source_class_scope.isNone() or output_scope.isNone())
        std.debug.panic("moved static initializer has incomplete output scope evidence", .{});
    const editor = try editorFor(self);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |node| {
        if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        if (self.outputOwnedScope(node)) |scope| {
            if (scope != source_class_scope and scope.toIndex() < editor.scopes.items.len and
                editor.scopes.items[scope.toIndex()].parent == source_class_scope)
            {
                try self.reparentGeneratedScope(scope, output_scope);
            }
        }
        var children = @import("../../parser/ast_walk.zig").children(self.ast, self.ast.getNode(node));
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
}

/// Generated class expressions can lack an analyzer-owned class scope. Return
/// the exact owner only when the input node establishes that boundary.
pub fn outputOwnedScope(self: *Transformer, owner: NodeIndex) ?ScopeId {
    const raw = @backingInt(owner);
    const id = self.transformed_scope_owner_map.get(raw) orelse
        self.scope_owner_map.get(raw) orelse
        if (self.semantic_editor) |*editor| editor.scope_owner_map.get(raw) else null;
    return if (id) |value| @fromBackingInt(@intCast(value)) else null;
}

/// Return the lexical scope owning a function's sibling trailing-statement
/// list. This metadata is only needed by AST plugins, so ordinary transformer
/// paths must not inspect possibly partial scope maps for it.
pub fn functionListInsertionScope(self: *Transformer, owner: NodeIndex) ScopeId {
    if (self.options.plugins.len == 0) return self.current_scope;
    const function_scope = self.outputOwnedScope(owner) orelse return self.current_scope;
    if (function_scope.isNone()) return self.current_scope;
    return self.outputScopeParent(function_scope);
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
    const old_key = @backingInt(old);
    const new_key = @backingInt(new);
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
    const raw = @backingInt(node);
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
    return (@as(u64, @backingInt(scope)) << 32) | name_span.start;
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
    const id = (try reserveSyntheticTempSymbolInScope(self, name_span, declaration_span, scope)) orelse return null;
    editor.attachExistingBinding(binding, id) catch |err| return editError(err);
    try setSymbolId(self, binding, id);
    es_helpers.markStandaloneLateSyntheticTemp(self, id, scope);
    return id;
}

/// Reserve the identity of a known lowering temp before its hoisted binding
/// node is emitted. The eventual declaration attaches to this exact SymbolId.
pub fn reserveSyntheticTempSymbolInScope(
    self: *Transformer,
    name_span: Span,
    declaration_span: Span,
    lexical_scope: ScopeId,
) Transformer.Error!?SymbolId {
    if (!self.semantic_edit_enabled) return null;
    const editor = try editorFor(self);
    const owner_scope = variableScope(self, lexical_scope);
    const key = syntheticTempSymbolKey(name_span, owner_scope);
    if (self.synthetic_temp_symbol_ids.get(key)) |raw_id| {
        if (raw_id >= editor.symbols.items.len) return editError(error.InvalidSymbol);
        const id: SymbolId = @fromBackingInt(@intCast(raw_id));
        const symbol = editor.symbols.items[raw_id];
        // State-machine construction can reparent the source var scope before
        // its final callback scope exists. bindStateCallbackTemp validates the
        // moved ID against the exact source and callback owners after assembly.
        const scope_mismatch = symbol.scope_id != owner_scope;
        if ((scope_mismatch and self.state_machine_depth == 0) or symbol.kind != .variable_var or
            symbol.name.start != name_span.start or symbol.name.end != name_span.end or
            !std.mem.eql(u8, symbol.synthetic_name, self.ast.getText(name_span)))
            return editError(error.InvalidSymbol);
        return id;
    }
    const id = editor.reserveSyntheticTempSymbol(name_span, declaration_span, lexical_scope) catch |err| return editError(err);
    try self.synthetic_temp_symbol_ids.put(self.allocator, key, @backingInt(id));
    return id;
}

/// Reserve a generated temp identity by its allocator producer handle. Use
/// this when a known-owner producer must create its binding before generic
/// hoisting emits the declaration; the name span validates metadata but never
/// selects an existing producer.
pub fn reserveSyntheticTempSymbolForProducerInScope(
    self: *Transformer,
    temp_producer_id: u64,
    name_span: Span,
    declaration_span: Span,
    lexical_scope: ScopeId,
) Transformer.Error!?SymbolId {
    if (!self.semantic_edit_enabled) return null;
    if (temp_producer_id == 0 or lexical_scope.isNone()) return editError(error.InvalidSymbol);

    const editor = try editorFor(self);
    const owner_scope = variableScope(self, lexical_scope);
    if (self.temp_symbols_by_producer_id.get(temp_producer_id)) |raw_id| {
        if (raw_id >= editor.symbols.items.len) return editError(error.InvalidSymbol);
        const id: SymbolId = @fromBackingInt(@intCast(raw_id));
        const symbol = editor.symbols.items[raw_id];
        if (symbol.scope_id != owner_scope or symbol.kind != .variable_var or
            symbol.name.start != name_span.start or symbol.name.end != name_span.end or
            !std.mem.eql(u8, symbol.synthetic_name, self.ast.getText(name_span)))
            return editError(error.InvalidSymbol);
        return id;
    }

    const id = editor.reserveSyntheticTempSymbol(name_span, declaration_span, lexical_scope) catch |err| return editError(err);
    try recordTempProducerSymbolId(self, temp_producer_id, id);
    return id;
}

pub const SyntheticTempReferenceIdentity = struct {
    symbol_id: SymbolId,
    reference_scope: ScopeId,
};

/// Reserve an exact temp identity at a producer that emits a reference now and
/// hoists its declaration into a known output var scope later. Deferred owners
/// keep the pending-reference path until their final scope exists.
pub fn reserveSyntheticTempIdentityForReference(
    self: *Transformer,
    name_span: Span,
    declaration_span: Span,
    reference_scope: ScopeId,
) Transformer.Error!?SyntheticTempReferenceIdentity {
    if (!self.semantic_edit_enabled or reference_scope.isNone() or self.static_field_initializer_depth > 0)
        return null;

    const parameter_output_scope = loweredDefaultParameterOutputScope(self, reference_scope);
    if (parameter_output_scope == null and syntheticTempOutputScopeIsDeferred(self, reference_scope)) return null;

    const output_scope = parameter_output_scope orelse reference_scope;
    const symbol_id = try reserveSyntheticTempSymbolInScope(self, name_span, declaration_span, output_scope) orelse return null;
    return .{ .symbol_id = symbol_id, .reference_scope = output_scope };
}

/// Look up the exact temp identity already selected for this output var scope.
/// Callers attach references directly when present and use pending name-span
/// tracking only when the binding scope has not been established yet.
pub fn lookupSyntheticTempSymbol(self: *Transformer, name_span: Span, scope: ScopeId) ?SymbolId {
    if (!self.semantic_edit_enabled or scope.isNone()) return null;
    const key = syntheticTempSymbolKey(name_span, variableScope(self, scope));
    const raw_id = self.synthetic_temp_symbol_ids.get(key) orelse return null;
    return @fromBackingInt(@intCast(raw_id));
}

/// Drop a temp's span index after its producer handle has been handed directly
/// to every known reference. The binding and symbol remain attached by ID.
pub fn forgetSyntheticTempSymbolLookup(self: *Transformer, name_span: Span, scope: ScopeId) void {
    if (!self.semantic_edit_enabled or scope.isNone()) return;
    const key = syntheticTempSymbolKey(name_span, variableScope(self, scope));
    _ = self.synthetic_temp_symbol_ids.remove(key);
}

/// Create a generated `var` temp and register its semantic identity at the
/// same boundary when the output scope is already known. A missing scope is
/// explicit: state-machine and extracted-function paths attach these temps
/// later, after their generated owner scopes exist.
pub fn createSyntheticTempBinding(
    self: *Transformer,
    requested_name: Span,
    declaration_span: Span,
    scope: ?ScopeId,
) Transformer.Error!SyntheticBinding {
    const node = try es_helpers.makeSyntheticBinding(self, requested_name);
    const name_span = self.ast.getNode(node).data.string_ref;
    const symbol_id = if (scope) |target|
        try declareSyntheticTempInScope(self, node, declaration_span, target)
    else
        null;
    return .{ .node = node, .name_span = name_span, .symbol_id = symbol_id };
}

/// Attach the binding half of a temp to the SymbolId already carried by its
/// producer. This avoids recovering a known identity through the span/scope
/// registry when the hoisted declaration is emitted later. Keep the producer's
/// resolved spelling unchanged; generator scope moves are finalized after the
/// wrapper binding is created.
pub fn createSyntheticTempBindingWithIdentity(
    self: *Transformer,
    requested_name: Span,
    scope: ScopeId,
    symbol_id: SymbolId,
) Transformer.Error!SyntheticBinding {
    const node = try es_helpers.makeExactSyntheticBindingFromSpan(self, requested_name);
    const name_span = self.ast.getNode(node).data.string_ref;
    const editor = try editorFor(self);
    const raw_id = @backingInt(symbol_id);
    if (raw_id >= editor.symbols.items.len) return editError(error.InvalidSymbol);
    const owner_scope = variableScope(self, scope);
    const symbol = editor.symbols.items[raw_id];
    const scope_mismatch = symbol.scope_id != owner_scope;
    if ((scope_mismatch and self.state_machine_depth == 0) or symbol.kind != .variable_var or
        symbol.name.start != requested_name.start or symbol.name.end != requested_name.end or
        !std.mem.eql(u8, symbol.synthetic_name, self.ast.getText(name_span)))
        return editError(error.InvalidSymbol);
    try setSymbolId(self, node, symbol_id);
    es_helpers.markStandaloneLateSyntheticTemp(self, symbol_id, owner_scope);
    return .{ .node = node, .name_span = name_span, .symbol_id = symbol_id };
}

pub fn registerGeneratedWrapperTemp(self: *Transformer, binding: NodeIndex, name_span: Span, declaration_span: Span, owner_scope: ScopeId) Transformer.Error!?SymbolId {
    if (!self.semantic_edit_enabled) return null;
    if (self.state_machine_depth == 0) std.debug.panic("generated wrapper temp registered outside state-machine lowering", .{});
    if (owner_scope.isNone() or variableScope(self, owner_scope) != owner_scope)
        std.debug.panic("generated wrapper temp has no exact var owner", .{});
    const symbol = try declareSyntheticTempInScope(self, binding, declaration_span, owner_scope);
    const id = symbol orelse std.debug.panic("generated wrapper temp registration lost its SymbolId", .{});
    for (self.generator_state_bindings.items) |existing| {
        if (existing.binding != binding) continue;
        if (existing.name_span.start != name_span.start or existing.name_span.end != name_span.end or
            existing.symbol_id != @backingInt(id) or existing.owner_scope != owner_scope or existing.callback_local)
            std.debug.panic("generated wrapper temp was registered with conflicting identity", .{});
        return id;
    }
    try self.generator_state_bindings.append(self.allocator, .{
        .binding = binding,
        .name_span = name_span,
        .symbol_id = @backingInt(id),
        .callback_local = false,
        .owner_scope = owner_scope,
    });
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
pub fn declareSyntheticCatch(
    self: *Transformer,
    binding: NodeIndex,
    declaration_span: Span,
    late_output_name: bool,
) Transformer.Error!void {
    const id = try declareSynthetic(self, binding, declaration_span, .catch_binding);
    if (late_output_name) {
        const symbol_id = id orelse std.debug.panic("late-named catch binding has no SymbolId", .{});
        const editor = try editorFor(self);
        const symbol = &editor.symbols.items[@backingInt(symbol_id)];
        symbol.synthetic_kind = .optional_catch_binding;
        if (self.options.emit_runtime_helper_imports) {
            symbol.output_name_hint = "_unused";
        }
    }
}

/// 생성자가 받은 SymbolId를 그대로 참조에 연결한다. 이름 재검색은 하지 않는다.
pub fn addSyntheticRef(self: *Transformer, node: NodeIndex, id: ?SymbolId) Transformer.Error!void {
    return addSyntheticRefInScope(self, node, id, self.current_scope, .{ .read = true });
}

/// Build a generated reference from its owner's exact SymbolId and register the
/// graph edge in one operation. The symbol's selected spelling is authoritative;
/// do not run the source-name collision resolver on it again.
pub fn makeSyntheticRefForSymbol(self: *Transformer, id: SymbolId, scope: ScopeId, flags: ReferenceFlags) Transformer.Error!NodeIndex {
    if (!self.semantic_edit_enabled) std.debug.panic("exact synthetic reference has no semantic editor", .{});
    const editor = try editorFor(self);
    const raw_id = @backingInt(id);
    if (raw_id >= editor.symbols.items.len) std.debug.panic("exact synthetic reference has an invalid SymbolId", .{});
    const node = try es_helpers.makeExactSyntheticRefFromSpan(self, editor.symbols.items[raw_id].name);
    try addSyntheticRefInScope(self, node, id, scope, flags);
    return node;
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

/// Carry a producer-selected SymbolId with a generated reference whose final
/// output scope is not known until its containing class/wrapper is assembled.
/// The finalizer resolves scope from this exact node's output ancestry; it
/// never searches for a binding by spelling.
pub fn recordPendingExactSymbolRef(self: *Transformer, node: NodeIndex, raw_symbol_id: u32) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len or raw_symbol_id >= editor.symbols.items.len)
        std.debug.panic("pending exact SymbolId reference has invalid node or identity", .{});
    const tag = self.ast.getNode(node).tag;
    if (tag != .identifier_reference and tag != .assignment_target_identifier)
        std.debug.panic("pending exact SymbolId reference has a non-reference node", .{});
    for (self.pending_exact_symbol_refs.items) |pending| {
        if (pending.node != node) continue;
        if (pending.symbol_id != raw_symbol_id)
            std.debug.panic("generated reference was assigned multiple exact SymbolIds", .{});
        std.debug.panic("generated reference was queued twice for exact SymbolId finalization", .{});
    }
    try self.pending_exact_symbol_refs.append(self.allocator, .{ .node = node, .symbol_id = raw_symbol_id });
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
    const raw = @backingInt(node);
    if (raw < editor.symbol_ids.items.len) editor.symbol_ids.items[raw] = null;
    if (raw < self.symbol_ids.items.len) self.symbol_ids.items[raw] = null;
}

fn removeReference(self: *Transformer, editor: *SemanticEditor, node: NodeIndex) Transformer.Error!void {
    editor.removeReference(node) catch |err| return editError(err);
    const raw = @backingInt(node);
    if (raw < self.symbol_ids.items.len) self.symbol_ids.items[raw] = null;
}

fn captureKey(frame: u32, kind: LexicalCaptureKind) u64 {
    return (@as(u64, frame) << 2) | @backingInt(kind);
}

pub fn hasLexicalCapture(self: *const Transformer, frame: u32, kind: LexicalCaptureKind) bool {
    for (self.lexical_capture_uses.items) |use| {
        if (use.frame == frame and use.kind == kind) return true;
    }
    return false;
}

pub fn hasLexicalCaptureSince(self: *const Transformer, start: usize, frame: u32, kind: LexicalCaptureKind) bool {
    if (start > self.lexical_capture_uses.items.len) std.debug.panic("lexical capture use marker is out of bounds", .{});
    for (self.lexical_capture_uses.items[start..]) |use| {
        if (use.frame == frame and use.kind == kind) return true;
    }
    return false;
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
    const source_span = if (!source.isNone()) self.ast.getNode(source).span else self.ast.getNode(node).span;
    if (self.capture_frame == 0) {
        if (self.semantic_edit_enabled) {
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            if (!self.current_scope.isNone() and scopes[self.current_scope.toIndex()].kind == .function)
                std.debug.panic("lexical capture in a function without a capture frame", .{});
        }
        // Program-level arrow capture placement is a separate lowering path.
        return;
    }
    if (!self.semantic_edit_enabled) {
        if (kind == .new_target_value) {
            try self.lexical_capture_uses.append(self.allocator, .{ .frame = self.capture_frame, .kind = kind, .span = source_span });
        }
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
    const raw = @backingInt(node);
    if (self.capture_ref_by_origin.contains(raw)) std.debug.panic("lexical capture node tracked twice", .{});
    try self.lexical_capture_uses.append(self.allocator, .{ .frame = self.capture_frame, .kind = kind, .span = source_span });
    try self.capture_ref_by_origin.put(self.allocator, raw, index);
    // A later copy can precede declaration binding; preserve exact origin even
    // while this generated reference has no SymbolId yet.
    try self.reference_origin_map.put(self.allocator, raw, raw);
}

/// Called at the actual capture declaration producer. A frame and role select
/// the binding; emitted text is never used to recover a symbol.
pub fn bindLexicalCapture(self: *Transformer, declaration: NodeIndex, kind: LexicalCaptureKind) Transformer.Error!void {
    try bindLexicalCaptureWithSyntheticKind(self, declaration, kind, null);
}

/// Bind a lexical-capture declaration and optionally defer its output spelling
/// to an exact-SymbolId final-name pass.
pub fn bindLexicalCaptureWithSyntheticKind(
    self: *Transformer,
    declaration: NodeIndex,
    kind: LexicalCaptureKind,
    synthetic_kind: ?SyntheticKind,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.capture_frame == 0) return;
    const decl = self.ast.getNode(declaration);
    if (decl.tag != .variable_declaration) std.debug.panic("lexical capture is not a variable declaration", .{});
    const start = self.readU32(decl.data.extra, 1);
    const len = self.readU32(decl.data.extra, 2);
    if (len != 1) std.debug.panic("lexical capture has multiple declarators", .{});
    const item: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[start]));
    const binding = self.readNodeIdx(self.ast.getNode(item).data.extra, 0);
    const id = (try declareSyntheticInScope(self, binding, decl.span, .variable_var, self.capture_scope)).?;
    var effective_synthetic_kind = synthetic_kind;
    const late_standalone = es_helpers.canUseLateStandaloneOutputName(self, self.capture_scope);
    const late_graph = es_helpers.canUseLateGraphOutputName(self, self.capture_scope);
    if (effective_synthetic_kind == null and kind == .this_value and
        (late_standalone or late_graph))
    {
        _ = try es_helpers.deferSyntheticOutputName(self, "_this");
        effective_synthetic_kind = .this_capture_binding;
    }
    if (effective_synthetic_kind == null and kind == .arguments_value and
        (late_standalone or late_graph))
    {
        _ = try es_helpers.deferSyntheticOutputName(self, "_arguments");
        effective_synthetic_kind = .arguments_capture_binding;
    }
    if (effective_synthetic_kind) |synthetic| {
        const editor = try editorFor(self);
        const symbol = &editor.symbols.items[@backingInt(id)];
        if (symbol.synthetic_kind) |existing_kind| {
            if (existing_kind != synthetic) std.debug.panic("lexical capture SymbolId has conflicting SyntheticKind", .{});
        }
        symbol.synthetic_kind = synthetic;
        if (late_graph) {
            const hint: []const u8 = switch (synthetic) {
                .this_capture_binding => "_this",
                .arguments_capture_binding => "_arguments",
                .new_target_capture_binding => "_newTarget",
                else => std.debug.panic("unsupported late graph lexical capture kind", .{}),
            };
            const staging = try es_helpers.deferSyntheticOutputName(self, hint);
            const emitted_name = self.ast.getText(self.ast.getNode(binding).data.string_ref);
            if (!std.mem.eql(u8, staging, emitted_name))
                std.debug.panic("late graph lexical capture binding differs from its producer staging name", .{});
            symbol.output_name_hint = hint;
        }
    }
    const key = captureKey(self.capture_frame, kind);
    if (self.capture_binding_ids.contains(key)) std.debug.panic("duplicate lexical capture binding", .{});
    try self.capture_binding_ids.put(self.allocator, key, @backingInt(id));
}

/// Bind a lexical-capture frame to a SymbolId that its owning producer has
/// already declared. This avoids inventing a second local when two lowering
/// paths share the same derived-constructor `_newTarget` value.
pub fn bindLexicalCaptureToExistingSymbol(self: *Transformer, kind: LexicalCaptureKind, id: SymbolId) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.capture_frame == 0) return;
    const key = captureKey(self.capture_frame, kind);
    if (self.capture_binding_ids.get(key)) |existing| {
        if (existing != @backingInt(id)) std.debug.panic("lexical capture frame was assigned conflicting SymbolIds", .{});
        return;
    }
    try self.capture_binding_ids.put(self.allocator, key, @backingInt(id));
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
        const id = self.capture_binding_ids.get(captureKey(pending.frame, pending.kind)) orelse
            std.debug.panic("live lexical capture has no declaration", .{});
        const ref_node: NodeIndex = @fromBackingInt(@intCast(raw));
        const trace = traces.get(raw) orelse std.debug.panic("live lexical capture has no output scope trace: node={d}", .{raw});
        if (trace.ambiguous_scope) std.debug.panic("live lexical capture has ambiguous output scope: node={d}", .{raw});
        const output_scope = trace.scope;
        if (self.getSymbolIdAt(ref_node)) |existing| {
            if (existing != id) {
                const maybe_reference = editor.referenceForNode(ref_node) catch |err| return editError(err);
                const reference = maybe_reference orelse std.debug.panic("rebound lexical capture has no reference record: node={d} existing={d} expected={d}", .{ raw, existing, id });
                editor.relocateReference(ref_node, output_scope, @fromBackingInt(@intCast(id)), reference.stmt_idx, reference.scope_stmt_idx) catch |err| return editError(err);
                self.symbol_ids.items[raw] = id;
            }
            const reference_index = editor.reference_index.get(raw) orelse
                std.debug.panic("bound lexical capture has no reference record: node={d} name={s} symbol={d} frame={d} kind={s}", .{ raw, self.ast.getText(self.ast.getNode(ref_node).data.string_ref), existing, pending.frame, @tagName(pending.kind) });
            const reference = editor.references.items[reference_index];
            if (@backingInt(reference.symbol_id) != id or !reference.flags.read) {
                std.debug.panic("bound lexical capture reference has inconsistent identity: node={d} name={s} ref_symbol={d} expected_symbol={d} ref_scope={d} output_scope={d} read={any} write={any} frame={d} kind={s}", .{ raw, self.ast.getText(self.ast.getNode(ref_node).data.string_ref), @backingInt(reference.symbol_id), id, reference.scope_id.toIndex(), output_scope.toIndex(), reference.flags.read, reference.flags.write, pending.frame, @tagName(pending.kind) });
            }
            if (reference.scope_id != output_scope) {
                editor.moveReference(ref_node, output_scope, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
            }
            continue;
        }
        try addSyntheticRefInScope(self, @fromBackingInt(@intCast(raw)), @fromBackingInt(@intCast(id)), output_scope, .{ .read = true });
    }

    for (self.capture_refs.items) |pending| {
        if (pending.source.isNone() or live.contains(@backingInt(pending.source))) continue;
        if (self.getSymbolIdAt(pending.source) == null) continue;
        try removeReference(self, editor, pending.source);
    }
}

/// 헬퍼 호출은 import 선언보다 먼저 생성된다. 첫 호출에서 helper SymbolId를
/// 예약하고 즉시 Reference를 붙여, 뒤늦은 import가 이 ID에 연결되게 한다.
pub fn trackRuntimeHelperRef(self: *Transformer, node: NodeIndex, local_name: []const u8) Transformer.Error!?SymbolId {
    return trackRuntimeHelperRefKind(self, node, local_name, self.options.emit_runtime_helper_imports, false);
}

/// Reserve a standalone helper declaration that is emitted in the preamble
/// but has no AST callsite of its own (for example, helpers referenced only
/// from another helper's template). Existing callsite-backed helper IDs are
/// reused; otherwise the declaration gets its own exact preamble SymbolId.
pub fn ensureStandaloneRuntimeHelperPreambleSymbol(
    self: *Transformer,
    base_name: []const u8,
    minify: bool,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.options.emit_runtime_helper_imports) return;
    if (base_name.len == 0) std.debug.panic("standalone runtime helper preamble has an empty canonical name", .{});

    const helper_name = runtime_helper_names.helperName(base_name, minify);
    const local_name = es_helpers.resolveRuntimeHelperName(self, helper_name) catch return error.OutOfMemory;
    const editor = try editorFor(self);
    if (self.runtime_helper_symbol_ids.get(base_name)) |symbol_id| {
        const raw_id = @backingInt(symbol_id);
        if (raw_id >= editor.symbols.items.len) std.debug.panic("standalone runtime helper preamble has an out-of-range SymbolId", .{});
        const symbol = editor.symbols.items[raw_id];
        if (symbol.scope_id != self.programScope() or symbol.kind != .import_binding or
            symbol.synthetic_kind != .runtime_helper_preamble or
            !std.mem.eql(u8, symbol.synthetic_name, local_name))
            std.debug.panic("standalone runtime helper preamble disagrees with its exact SymbolId", .{});
        return;
    }

    const name_span = try self.ast.addString(local_name);
    const symbol_id = editor.declareRuntimeHelperPreamble(name_span, Span.EMPTY, self.programScope()) catch |err| return editError(err);
    if (self.name_arena == null) self.name_arena = std.heap.ArenaAllocator.init(self.allocator);
    const stable_base = self.name_arena.?.allocator().dupe(u8, base_name) catch return error.OutOfMemory;
    try self.runtime_helper_symbol_ids.put(self.allocator, stable_base, symbol_id);
}

/// JSX and plugin helper imports are AST imports even in standalone mode,
/// where downlevel runtime helpers are emitted through an inline preamble.
pub fn trackRuntimeHelperImportRef(self: *Transformer, node: NodeIndex, local_name: []const u8) Transformer.Error!?SymbolId {
    const defer_import_name = self.options.defer_runtime_helper_name_resolution and
        es_helpers.canUseLateStandaloneOutputName(self, self.programScope());
    return trackRuntimeHelperRefKind(self, node, local_name, true, defer_import_name);
}

/// Reserve a standalone JSX runtime import local for late output naming.
pub fn trackJsxRuntimeImportRef(self: *Transformer, node: NodeIndex, local_name: []const u8) Transformer.Error!?SymbolId {
    const defer_import_name = if (self.semantic_edit_enabled) blk: {
        const program_scope = self.programScope();
        break :blk es_helpers.canUseLateStandaloneOutputName(self, program_scope) or
            es_helpers.canUseLateGraphOutputName(self, program_scope);
    } else false;
    return trackRuntimeHelperRefKind(self, node, local_name, true, defer_import_name);
}

fn trackRuntimeHelperRefKind(self: *Transformer, node: NodeIndex, local_name: []const u8, is_import: bool, defer_import_name: bool) Transformer.Error!?SymbolId {
    if (!self.semantic_edit_enabled) return null;
    if (self.current_scope.isNone()) std.debug.panic("runtime helper {s} created without scope", .{local_name});
    if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len)
        std.debug.panic("runtime helper reference has an invalid node", .{});
    const helper_node = self.ast.getNode(node);
    if (helper_node.tag != .identifier_reference and helper_node.tag != .assignment_target_identifier and helper_node.tag != .jsx_identifier)
        std.debug.panic("runtime helper reference has a non-reference node", .{});
    if (!std.mem.eql(u8, self.ast.getText(helper_node.data.string_ref), local_name))
        std.debug.panic("runtime helper reference spelling changed before identity registration", .{});
    const editor = try editorFor(self);
    const id = editor.reserveRuntimeHelperSymbol(
        helper_node.data.string_ref,
        Span.EMPTY,
        self.programScope(),
        !is_import,
        defer_import_name,
    ) catch |err| return editError(err);
    try trackRuntimeHelperRefWithId(self, node, id);
    return id;
}

/// Bind a cloned helper reference using its already established helper SID.
pub fn trackRuntimeHelperRefWithId(self: *Transformer, node: NodeIndex, id: SymbolId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (self.current_scope.isNone()) std.debug.panic("runtime helper reference created without scope", .{});
    const editor = try editorFor(self);
    if (@backingInt(id) >= editor.symbols.items.len) std.debug.panic("runtime helper SymbolId is out of range", .{});
    const symbol = editor.symbols.items[@backingInt(id)];
    if (symbol.kind != .import_binding or symbol.scope_id != self.programScope())
        std.debug.panic("runtime helper SymbolId has an invalid owner or kind", .{});
    if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len)
        std.debug.panic("runtime helper reference has an invalid node", .{});
    const node_name = self.ast.getText(self.ast.getNode(node).data.string_ref);
    if (!std.mem.eql(u8, symbol.synthetic_name, node_name) or
        editor.helper_scope_map.get(node_name) != @as(?usize, @backingInt(id)))
        std.debug.panic("runtime helper reference does not match its exact helper SymbolId", .{});
    const raw = @backingInt(node);
    if (self.tracked_runtime_helper_ref_index.get(raw)) |existing_index| {
        if (existing_index >= self.tracked_runtime_helper_refs.items.len or
            self.tracked_runtime_helper_refs.items[existing_index].symbol_id != @backingInt(id))
            std.debug.panic("runtime helper reference was tracked with a different SymbolId", .{});
        return;
    }
    if (self.getSymbolIdAt(node) != null) std.debug.panic("runtime helper reference already has a SymbolId", .{});
    editor.addReference(node, id, self.current_scope, .{ .read = true }, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
    try setSymbolId(self, node, id);
    const index = self.tracked_runtime_helper_refs.items.len;
    try self.tracked_runtime_helper_refs.append(self.allocator, .{
        .node = node,
        .scope = self.current_scope,
        .symbol_id = @backingInt(id),
    });
    try self.tracked_runtime_helper_ref_index.put(self.allocator, raw, index);
}

/// `__generator` is created before the async wrapper that contains its call.
/// Retarget only that exact helper node after the wrapper is created.
pub fn relocateRuntimeHelperRef(self: *Transformer, node: NodeIndex, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (scope.isNone()) std.debug.panic("runtime helper relocation has no scope", .{});
    if (self.tracked_runtime_helper_ref_index.get(@backingInt(node))) |index| {
        const editor = try editorFor(self);
        editor.moveReference(node, scope, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
        self.tracked_runtime_helper_refs.items[index].scope = scope;
        return;
    }
    // The final output-scope walk can have removed the tracking record already.
    if (self.semantic_editor) |*editor| {
        editor.moveReference(node, scope, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
    } else {
        std.debug.panic("runtime helper reference was not pending or bound", .{});
    }
}

/// import specifier local을 호출 시점에 만들어 둔 exact helper SymbolId에 붙인다.
pub fn bindRuntimeHelperImport(self: *Transformer, local: NodeIndex, local_name: []const u8, declaration_span: Span) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    const local_node = self.ast.getNode(local);
    const local_span = switch (local_node.tag) {
        .identifier_reference, .import_default_specifier => local_node.data.string_ref,
        else => return editError(error.InvalidNode),
    };
    if (!std.mem.eql(u8, self.ast.getText(local_span), local_name))
        std.debug.panic("runtime helper import local name disagrees with its binding node", .{});
    const raw_id: u32 = if (editor.helper_scope_map.get(local_name)) |mapped|
        @intCast(mapped)
    else
        @backingInt(editor.declareHelperImport(local, local_span, declaration_span, self.programScope()) catch |err| return editError(err));
    return bindRuntimeHelperImportWithId(self, editor, local, @fromBackingInt(@intCast(raw_id)), declaration_span);
}

/// Create and attach an import-only helper symbol when the import has no
/// callsite-backed SymbolId (for example, a sibling export in a helper module).
/// This deliberately fails on an already-reserved helper name so a missing
/// callsite handle cannot be silently replaced by a second declaration.
pub fn declareRuntimeHelperImportId(
    self: *Transformer,
    local: NodeIndex,
    local_name: []const u8,
    declaration_span: Span,
) Transformer.Error!SymbolId {
    if (!self.semantic_edit_enabled)
        std.debug.panic("cannot declare a semantic runtime helper import without semantic editing", .{});
    const editor = try editorFor(self);
    const local_node = self.ast.getNode(local);
    const local_span = switch (local_node.tag) {
        .identifier_reference, .import_default_specifier => local_node.data.string_ref,
        else => return editError(error.InvalidNode),
    };
    if (!std.mem.eql(u8, self.ast.getText(local_span), local_name))
        std.debug.panic("runtime helper import local name disagrees with its binding node", .{});
    return editor.declareHelperImport(local, local_span, declaration_span, self.programScope()) catch |err| return editError(err);
}

/// Bind the generated import node to the exact helper ID reserved by its
/// callsites. The local spelling is checked as an invariant, never used to
/// select which helper symbol receives the declaration.
pub fn bindRuntimeHelperImportById(
    self: *Transformer,
    local: NodeIndex,
    local_name: []const u8,
    symbol_id: SymbolId,
    declaration_span: Span,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    const local_node = self.ast.getNode(local);
    const local_span = switch (local_node.tag) {
        .identifier_reference, .import_default_specifier => local_node.data.string_ref,
        else => return editError(error.InvalidNode),
    };
    if (!std.mem.eql(u8, self.ast.getText(local_span), local_name))
        std.debug.panic("runtime helper import local name disagrees with its binding node", .{});
    const raw_id = @backingInt(symbol_id);
    if (raw_id >= editor.symbols.items.len) return editError(error.InvalidSymbol);
    const symbol = editor.symbols.items[raw_id];
    if (symbol.kind != .import_binding or symbol.scope_id != self.programScope() or
        !std.mem.eql(u8, symbol.synthetic_name, local_name) or
        editor.helper_scope_map.get(local_name) != @as(?usize, raw_id)) return editError(error.InvalidSymbol);
    return bindRuntimeHelperImportWithId(self, editor, local, symbol_id, declaration_span);
}

fn bindRuntimeHelperImportWithId(
    self: *Transformer,
    editor: *SemanticEditor,
    local: NodeIndex,
    id: SymbolId,
    declaration_span: Span,
) Transformer.Error!void {
    const raw_id = @backingInt(id);
    if (self.runtime_helper_import_bindings.contains(raw_id)) return editError(error.DuplicateBinding);
    const local_raw = @backingInt(local);
    const editor_local_id = if (local_raw < editor.symbol_ids.items.len) editor.symbol_ids.items[local_raw] else null;
    if (editor_local_id == null) {
        editor.attachRuntimeHelperImport(local, id, declaration_span) catch |err| return editError(err);
    } else if (editor_local_id != raw_id) {
        return editError(error.InvalidSymbol);
    }
    if (self.getSymbolIdAt(local) == null) try setSymbolId(self, local, id);
    try self.runtime_helper_import_bindings.put(self.allocator, raw_id, @backingInt(local));
}

/// Generator lowering already knows a producer's SymbolId. Keep that identity
/// on the reference node immediately and defer only its final output ScopeId.
pub fn trackGeneratorStateReference(self: *Transformer, node: NodeIndex, id: ?SymbolId, scope: ScopeId, flags: ReferenceFlags) Transformer.Error!void {
    if (!self.semantic_edit_enabled or !self.options.unsupported.generator) return;
    const symbol = id orelse return;
    const raw_node = @backingInt(node);
    if (node.isNone() or raw_node >= self.ast.nodes.items.len)
        std.debug.panic("generator state reference has an invalid producer node", .{});
    const tag = self.ast.getNode(node).tag;
    if (tag != .identifier_reference and tag != .assignment_target_identifier)
        std.debug.panic("generator state reference producer is not an identifier reference", .{});
    if (self.getSymbolIdAt(node)) |existing| {
        if (existing != @backingInt(symbol))
            std.debug.panic("generator state reference disagrees with its producer SymbolId", .{});
    } else try setSymbolId(self, node, symbol);
    try self.generator_state_semantic_refs.append(self.allocator, .{
        .node = node,
        .symbol_id = @backingInt(symbol),
        .scope = scope,
        .flags = flags,
    });
}

/// Preserve a generated callback temp reference against its exact binding
/// node while the state-machine callback ScopeId is still being assembled.
pub fn trackGeneratedCallbackTempReference(
    self: *Transformer,
    binding: NodeIndex,
    reference: NodeIndex,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (self.state_machine_depth == 0 or binding.isNone() or reference.isNone() or scope.isNone())
        std.debug.panic("generated callback temp reference has no exact producer context", .{});
    if (@backingInt(binding) >= self.ast.nodes.items.len or @backingInt(reference) >= self.ast.nodes.items.len)
        std.debug.panic("generated callback temp reference has an invalid node", .{});
    const binding_node = self.ast.getNode(binding);
    const reference_node = self.ast.getNode(reference);
    if (binding_node.tag != .binding_identifier or
        (reference_node.tag != .identifier_reference and reference_node.tag != .assignment_target_identifier))
        std.debug.panic("generated callback temp handle has an unexpected AST node kind", .{});
    if (!std.mem.eql(u8, self.ast.getText(binding_node.data.string_ref), self.ast.getText(reference_node.data.string_ref)))
        std.debug.panic("generated callback temp reference spelling disagrees with its binding handle", .{});
    try self.generator_state_temp_refs.append(self.allocator, .{
        .binding = binding,
        .reference = reference,
        .scope = scope,
        .flags = flags,
    });
}

/// Keep a callback-local producer binding attached to the exact allocator
/// slot that created it. The hoister later retrieves this NodeIndex by slot,
/// without reconstructing the producer from its spelling span.
pub fn registerGeneratedCallbackTempBinding(self: *Transformer, counter_index: u32, binding: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled or self.state_machine_depth == 0 or binding.isNone())
        std.debug.panic("generated callback temp binding has no exact producer context", .{});
    if (counter_index >= self.temp_var_counter or @backingInt(binding) >= self.ast.nodes.items.len)
        std.debug.panic("generated callback temp binding has an invalid allocator slot or node", .{});
    const name_span = self.temp_span_by_counter.get(counter_index) orelse
        std.debug.panic("generated callback temp binding has no allocator span", .{});
    const node = self.ast.getNode(binding);
    if (node.tag != .binding_identifier or node.data.string_ref.start != name_span.start or
        node.data.string_ref.end != name_span.end)
        std.debug.panic("generated callback temp binding disagrees with its allocator slot", .{});
    if (self.callback_temp_bindings_by_counter.get(counter_index)) |existing| {
        if (existing != binding)
            std.debug.panic("callback temp allocator slot has multiple producer bindings", .{});
        return;
    }
    try self.callback_temp_bindings_by_counter.put(self.allocator, counter_index, binding);
}

/// Return the allocator producer already attached to one reference node.
/// The spelling span is checked as metadata and never used to choose a producer.
pub fn pendingTempProducerIdForReference(self: *Transformer, node: NodeIndex) Transformer.Error!?u64 {
    if (!self.semantic_edit_enabled or node.isNone()) return null;
    if (@backingInt(node) >= self.ast.nodes.items.len) return editError(error.InvalidSymbol);
    const reference = self.ast.getNode(node);
    if (reference.tag != .identifier_reference and reference.tag != .assignment_target_identifier) return null;
    var found: ?u64 = null;
    for (self.pending_temp_producer_refs.items) |pending| {
        if (pending.node != node) continue;
        if (pending.temp_producer_id == 0 or pending.scope.isNone() or
            pending.name_span.start != reference.data.string_ref.start or
            pending.name_span.end != reference.data.string_ref.end)
            return editError(error.InvalidSymbol);
        if (found) |existing| {
            if (existing != pending.temp_producer_id) return editError(error.InvalidSymbol);
        } else found = pending.temp_producer_id;
    }
    return found;
}

/// Keep the exact producer handle on a binding emitted by the allocator.
/// Later read clones can copy the handle even while its SymbolId is deferred.
pub fn registerHoistedTempProducerBinding(
    self: *Transformer,
    binding: NodeIndex,
    temp_producer_id: ?u64,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const producer_id = temp_producer_id orelse return;
    if (producer_id == 0 or binding.isNone() or @backingInt(binding) >= self.ast.nodes.items.len or
        self.ast.getNode(binding).tag != .binding_identifier)
        return editError(error.InvalidSymbol);
    const entry = try self.hoisted_temp_producer_by_binding.getOrPut(self.allocator, @backingInt(binding));
    if (entry.found_existing and entry.value_ptr.* != producer_id) return editError(error.InvalidSymbol);
    entry.value_ptr.* = producer_id;
}

pub fn hoistedTempProducerIdForBinding(self: *Transformer, binding: NodeIndex) ?u64 {
    if (!self.semantic_edit_enabled or binding.isNone()) return null;
    return self.hoisted_temp_producer_by_binding.get(@backingInt(binding));
}

/// Resolve a bound SymbolId back to its allocator producer only when exactly
/// one producer owns it. Ambiguity is not resolved from name or span.
pub fn tempProducerIdForSymbolId(self: *Transformer, symbol_id: SymbolId) ?u64 {
    if (!self.semantic_edit_enabled) return null;
    var found: ?u64 = null;
    var iter = self.temp_symbols_by_producer_id.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(symbol_id)) continue;
        if (found != null) return null;
        found = entry.key_ptr.*;
    }
    return found;
}

/// Record a deferred temp reference against the exact allocator producer.
pub fn trackHoistedTempRefByProducerIdInScope(
    self: *Transformer,
    temp_producer_id: u64,
    name_span: Span,
    node: NodeIndex,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (temp_producer_id == 0 or node.isNone() or scope.isNone() or
        @backingInt(node) >= self.ast.nodes.items.len)
        return editError(error.InvalidSymbol);
    const reference = self.ast.getNode(node);
    if ((reference.tag != .identifier_reference and reference.tag != .assignment_target_identifier) or
        reference.data.string_ref.start != name_span.start or reference.data.string_ref.end != name_span.end)
        return editError(error.InvalidSymbol);
    if (try pendingTempProducerIdForReference(self, node)) |existing| {
        if (existing != temp_producer_id) return editError(error.InvalidSymbol);
        if (!try trackPendingTempProducerReferenceInScope(self, node, scope, flags))
            return editError(error.InvalidSymbol);
        return;
    }
    if (self.getSymbolIdAt(node)) |raw_id| {
        if (self.temp_symbols_by_producer_id.get(temp_producer_id)) |producer_symbol_id| {
            if (raw_id != producer_symbol_id) return editError(error.InvalidSymbol);
        }
        return editError(error.InvalidSymbol);
    }
    if (!knownSyntheticTempOutputScopeIsDeferred(self, scope)) {
        if (self.temp_symbols_by_producer_id.get(temp_producer_id)) |raw_id| {
            if (try trackKnownSyntheticTempReferenceByIdInScope(
                self,
                @fromBackingInt(raw_id),
                node,
                scope,
                flags,
            )) return;
        }
    }
    try trackDeferredTempProducerReference(self, temp_producer_id, name_span, node, scope, flags);
}

pub fn trackHoistedTempRef(self: *Transformer, name_span: Span, node: NodeIndex, flags: ReferenceFlags) Transformer.Error!void {
    return trackHoistedTempRefInScope(self, name_span, node, self.current_scope, flags);
}

pub fn trackHoistedTempRefInScope(self: *Transformer, name_span: Span, node: NodeIndex, scope: ScopeId, flags: ReferenceFlags) Transformer.Error!void {
    if (!self.semantic_edit_enabled or scope.isNone()) return;
    if (node.isNone() or @backingInt(node) >= self.ast.nodes.items.len) return editError(error.InvalidSymbol);
    const reference = self.ast.getNode(node);
    if ((reference.tag != .identifier_reference and reference.tag != .assignment_target_identifier) or
        reference.data.string_ref.start != name_span.start or reference.data.string_ref.end != name_span.end)
        return editError(error.InvalidSymbol);
    if (try pendingTempProducerIdForReference(self, node)) |producer_id| {
        if (!try trackPendingTempProducerReferenceInScope(self, node, scope, flags))
            return editError(error.InvalidSymbol);
        if (producer_id == 0) return editError(error.InvalidSymbol);
        return;
    }
    if (self.static_field_initializer_depth == 0) {
        if (es_helpers.producerTempSymbolIdAtRef(self, node)) |producer_id| {
            if (try trackKnownSyntheticTempReferenceByIdInScope(self, producer_id, node, scope, flags)) return;
            if (tempProducerIdForSymbolId(self, producer_id)) |temp_producer_id| {
                return trackHoistedTempRefByProducerIdInScope(
                    self,
                    temp_producer_id,
                    name_span,
                    node,
                    scope,
                    flags,
                );
            }
            return editError(error.InvalidSymbol);
        }
    }
    if (es_helpers.hasTempAllocatorSpan(self, name_span)) return editError(error.InvalidSymbol);
    const chain_key = self.currentPendingTempRefKey(name_span);
    try self.generated_temp_spans.append(self.allocator, name_span);
    const index = self.pending_temp_refs.items.len;
    try self.pending_temp_refs.append(self.allocator, .{
        .name_start = name_span.start,
        .name_end = name_span.end,
        .producer_scope = chain_key.producer_scope,
        .node = node,
        .scope = scope,
        .flags = flags,
    });
    if (self.pending_temp_ref_chains.getPtr(chain_key)) |chain| {
        self.pending_temp_refs.items[chain.last].next = index;
        chain.last = index;
    } else {
        try self.pending_temp_ref_chains.put(self.allocator, chain_key, .{ .first = index, .last = index });
    }
}

/// Preserve a deferred temp reference with its stable allocator identity.
/// The name span validates the AST node; it is never the handoff key.
pub fn trackDeferredTempProducerReference(
    self: *Transformer,
    temp_producer_id: u64,
    name_span: Span,
    node: NodeIndex,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (temp_producer_id == 0 or node.isNone() or scope.isNone() or
        @backingInt(node) >= self.ast.nodes.items.len)
        std.debug.panic("captured temp reference has no stable producer context", .{});
    const reference = self.ast.getNode(node);
    if ((reference.tag != .identifier_reference and reference.tag != .assignment_target_identifier) or
        reference.data.string_ref.start != name_span.start or reference.data.string_ref.end != name_span.end)
        std.debug.panic("captured temp reference disagrees with its producer name span", .{});
    for (self.pending_temp_producer_refs.items) |existing| {
        if (existing.temp_producer_id != temp_producer_id or existing.node != node) continue;
        if (existing.scope != scope or !std.meta.eql(existing.flags, flags))
            std.debug.panic("captured temp reference was registered with conflicting metadata", .{});
        return;
    }
    try self.pending_temp_producer_refs.append(self.allocator, .{
        .temp_producer_id = temp_producer_id,
        .name_span = name_span,
        .node = node,
        .scope = scope,
        .flags = flags,
    });
}

/// Preserve captured temps through the same producer-owned handoff.
pub fn trackCapturedTempReference(
    self: *Transformer,
    temp_producer_id: u64,
    name_span: Span,
    node: NodeIndex,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!void {
    return trackDeferredTempProducerReference(self, temp_producer_id, name_span, node, scope, flags);
}

/// Retarget a deferred producer-owned reference after lowering moves it into
/// an owner scope. The stable producer ID was recorded when the reference was
/// created, so this handoff does not need to rediscover the temp by its span.
pub fn trackPendingTempProducerReferenceInScope(
    self: *Transformer,
    node: NodeIndex,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!bool {
    if (!self.semantic_edit_enabled or node.isNone() or scope.isNone()) return false;
    if (@backingInt(node) >= self.ast.nodes.items.len) return editError(error.InvalidSymbol);
    const editor = try editorFor(self);
    if (@backingInt(scope) >= editor.scopes.items.len) return editError(error.InvalidSymbol);
    const reference = self.ast.getNode(node);
    if (reference.tag != .identifier_reference and reference.tag != .assignment_target_identifier) return false;

    var found: ?usize = null;
    for (self.pending_temp_producer_refs.items, 0..) |pending, index| {
        if (pending.node != node) continue;
        if (pending.temp_producer_id == 0 or pending.scope.isNone() or
            @backingInt(pending.scope) >= editor.scopes.items.len or
            pending.name_span.start != reference.data.string_ref.start or
            pending.name_span.end != reference.data.string_ref.end or
            !std.meta.eql(pending.flags, flags))
            return editError(error.InvalidSymbol);
        if (found != null) return editError(error.InvalidSymbol);
        found = index;
    }
    const index = found orelse return false;
    self.pending_temp_producer_refs.items[index].scope = scope;
    return true;
}

/// Attach a generated `var` temp reference to an identity reserved at its
/// first use when the output scope is known. Parameter environments and
/// state-machine callbacks keep using the deferred hoist path until their
/// final declaration scope exists.
pub fn trackSyntheticTempReference(
    self: *Transformer,
    name_span: Span,
    declaration_span: Span,
    node: NodeIndex,
    flags: ReferenceFlags,
) Transformer.Error!void {
    return trackSyntheticTempReferenceInScope(self, name_span, declaration_span, node, self.current_scope, flags);
}

/// The same exact temp tracking for a caller that already knows the emitted
/// reference scope, even when it differs from `current_scope`.
pub fn trackSyntheticTempReferenceInScope(
    self: *Transformer,
    name_span: Span,
    declaration_span: Span,
    node: NodeIndex,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled or scope.isNone()) return;
    const parameter_output_scope = loweredDefaultParameterOutputScope(self, scope);
    if (self.static_field_initializer_depth > 0 or
        (parameter_output_scope == null and syntheticTempOutputScopeIsDeferred(self, scope)))
        return trackHoistedTempRefInScope(self, name_span, node, scope, flags);

    const output_scope = parameter_output_scope orelse scope;
    const symbol_id = lookupSyntheticTempSymbol(self, name_span, output_scope) orelse
        (try reserveSyntheticTempSymbolInScope(self, name_span, declaration_span, output_scope)) orelse return;
    return addSyntheticRefInScope(self, node, symbol_id, output_scope, flags);
}

/// Attach a known generated reference only when its already-reserved temp ID
/// is visible from the reference's output scope. The binding can live in an
/// enclosing var scope, so the reference scope alone must not reserve a new ID.
pub fn trackKnownSyntheticTempReferenceInScope(
    self: *Transformer,
    name_span: Span,
    node: NodeIndex,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!bool {
    if (!self.semantic_edit_enabled or node.isNone() or scope.isNone() or
        syntheticTempOutputScopeIsDeferred(self, scope)) return false;

    const symbol_id = try lookupVisibleSyntheticTempSymbol(self, name_span, scope) orelse return false;
    if (self.getSymbolIdAt(node)) |raw_id| {
        if (raw_id != @backingInt(symbol_id)) return editError(error.InvalidSymbol);
        const editor = try editorFor(self);
        const existing = (editor.referenceForNode(node) catch |err| return editError(err)) orelse
            return editError(error.InvalidSymbol);
        if (existing.symbol_id != symbol_id or !std.meta.eql(existing.flags, flags))
            return editError(error.InvalidSymbol);
        if (existing.scope_id != scope) {
            editor.relocateReference(
                node,
                scope,
                symbol_id,
                existing.stmt_idx,
                existing.scope_stmt_idx,
            ) catch |err| return editError(err);
        }
        return true;
    }
    try addSyntheticRefInScope(self, node, symbol_id, scope, flags);
    return true;
}

/// Attach a generated temp reference using the identity saved by its allocator
/// slot. The ID is authoritative; the text checks only guard that the node and
/// producer still describe the same generated identifier.
pub fn trackKnownSyntheticTempReferenceByIdInScope(
    self: *Transformer,
    symbol_id: SymbolId,
    node: NodeIndex,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!bool {
    if (!self.semantic_edit_enabled or node.isNone() or scope.isNone()) return false;

    const editor = try editorFor(self);
    const output_scope_deferred = knownSyntheticTempOutputScopeIsDeferred(self, scope);
    const raw_id = @backingInt(symbol_id);
    if (raw_id >= editor.symbols.items.len) return editError(error.InvalidSymbol);
    const reference = self.ast.getNode(node);
    if (reference.tag != .identifier_reference and reference.tag != .assignment_target_identifier)
        return editError(error.InvalidSymbol);
    const name_span = reference.data.string_ref;
    const producer_name = editor.symbols.items[raw_id].name;
    if (producer_name.start != name_span.start or producer_name.end != name_span.end or
        !editor.symbolVisibleFrom(symbol_id, scope)) return editError(error.InvalidSymbol);

    if (self.getSymbolIdAt(node)) |existing_id| {
        if (existing_id != raw_id) return editError(error.InvalidSymbol);
        const maybe_existing = editor.referenceForNode(node) catch |err| return editError(err);
        const existing = maybe_existing orelse {
            if (output_scope_deferred) return false;
            return editError(error.InvalidSymbol);
        };
        if (existing.symbol_id != symbol_id or !std.meta.eql(existing.flags, flags))
            return editError(error.InvalidSymbol);
        if (existing.scope_id != scope) {
            editor.relocateReference(
                node,
                scope,
                symbol_id,
                existing.stmt_idx,
                existing.scope_stmt_idx,
            ) catch |err| return editError(err);
        }
        return true;
    }

    if (output_scope_deferred) return false;
    try addSyntheticRefInScope(self, node, symbol_id, scope, flags);
    return true;
}

fn lookupVisibleSyntheticTempSymbol(
    self: *Transformer,
    name_span: Span,
    reference_scope: ScopeId,
) Transformer.Error!?SymbolId {
    if (self.synthetic_temp_symbol_ids.count() == 0 and self.bound_temp_symbols.count() == 0) return null;
    const editor = try editorFor(self);
    if (reference_scope.toIndex() >= editor.scopes.items.len) return null;
    var found: ?SymbolId = null;
    var ambiguous = false;
    var cursor = reference_scope;
    var hops: usize = 0;
    while (!cursor.isNone() and hops < editor.scopes.items.len) : (hops += 1) {
        const key = syntheticTempSymbolKey(name_span, cursor);
        const synthetic_id = self.synthetic_temp_symbol_ids.get(key);
        const bound_id = self.bound_temp_symbols.get(key);
        if (synthetic_id != null and bound_id != null and synthetic_id.? != bound_id.?) return null;
        const raw_id = synthetic_id orelse bound_id;
        if (raw_id) |raw| {
            if (visibleSyntheticTempCandidate(editor, name_span, reference_scope, raw)) |id| {
                if (found) |existing| {
                    if (existing != id) ambiguous = true;
                } else found = id;
            }
        }
        cursor = editor.scopes.items[cursor.toIndex()].parent;
    }

    return if (ambiguous) null else found;
}

fn visibleSyntheticTempCandidate(
    editor: *SemanticEditor,
    name_span: Span,
    reference_scope: ScopeId,
    raw_id: u32,
) ?SymbolId {
    if (raw_id >= editor.symbols.items.len) return null;
    const id: SymbolId = @fromBackingInt(@intCast(raw_id));
    const symbol = editor.symbols.items[raw_id];
    if (symbol.name.start != name_span.start or symbol.name.end != name_span.end) return null;
    return if (editor.symbolVisibleFrom(id, reference_scope)) id else null;
}

/// 원본 프로그램·함수의 호이스트 바인딩에 앞서 기록한 참조를 연결한다.
/// 새로 만든 함수에는 scope 등록 전이므로 호출하지 않는다.
pub fn bindHoistedTemp(self: *Transformer, binding: NodeIndex, name_span: Span, declaration_span: Span, binding_scope: @import("../../semantic/scope.zig").ScopeId) Transformer.Error!void {
    return bindHoistedTempWithProducerSymbol(self, binding, name_span, declaration_span, binding_scope, null);
}

pub fn bindHoistedTempWithProducerSymbol(
    self: *Transformer,
    binding: NodeIndex,
    name_span: Span,
    declaration_span: Span,
    binding_scope: ScopeId,
    producer_symbol_id: ?SymbolId,
) Transformer.Error!void {
    return bindHoistedTempWithProducerIdentity(
        self,
        binding,
        name_span,
        declaration_span,
        binding_scope,
        producer_symbol_id,
        null,
    );
}

pub fn bindHoistedTempWithProducerIdentity(
    self: *Transformer,
    binding: NodeIndex,
    name_span: Span,
    declaration_span: Span,
    binding_scope: ScopeId,
    producer_symbol_id: ?SymbolId,
    temp_producer_id: ?u64,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (temp_producer_id == null and producer_symbol_id == null and es_helpers.hasTempAllocatorSpan(self, name_span))
        return;
    const pending_key = self.currentPendingTempRefKey(name_span);
    if (temp_producer_id != null and self.pending_temp_ref_chains.contains(pending_key))
        return editError(error.InvalidSymbol);
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
            .symbol_id = self.getSymbolIdAt(binding),
            .callback_local = true,
            .temp_producer_id = temp_producer_id,
        });
        return;
    }
    const chain = if (temp_producer_id == null and !es_helpers.hasTempAllocatorSpan(self, name_span))
        self.pending_temp_ref_chains.fetchRemove(pending_key)
    else
        null;
    const target_scope = if (binding_scope.isNone())
        @as(@import("../../semantic/scope.zig").ScopeId, @fromBackingInt(@intCast(
            self.scope_owner_map.get(self.parser_node_count - 1) orelse std.debug.panic("missing program scope for hoisted temp", .{}),
        )))
    else
        binding_scope;
    const editor = try editorFor(self);
    const expected_scope = variableScope(self, target_scope);
    const temp_key = syntheticTempSymbolKey(name_span, expected_scope);
    const known_temp_id = self.synthetic_temp_symbol_ids.get(temp_key);
    const bound_temp_id = self.bound_temp_symbols.get(temp_key);
    if (producer_symbol_id) |producer_id| {
        const raw_producer_id = @backingInt(producer_id);
        if ((known_temp_id != null and known_temp_id.? != raw_producer_id) or
            (bound_temp_id != null and bound_temp_id.? != raw_producer_id))
            std.debug.panic("hoisted temp producer changed its exact SymbolId", .{});
    }
    if (chain == null and known_temp_id == null and bound_temp_id == null and producer_symbol_id == null and
        (temp_producer_id == null or !hasPendingTempProducerReferences(self, temp_producer_id.?))) return;
    if (known_temp_id != null and bound_temp_id != null and known_temp_id.? != bound_temp_id.?)
        std.debug.panic("hoisted temp allocation has conflicting exact SymbolIds", .{});
    const id = bindGeneratedTempByIdentity(
        editor,
        binding,
        name_span,
        declaration_span,
        target_scope,
        expected_scope,
        if (producer_symbol_id) |producer_id| @backingInt(producer_id) else known_temp_id orelse bound_temp_id,
    ) catch |err| return editError(err);
    try recordTempProducerSymbolId(self, temp_producer_id, id);
    const bound = try self.bound_temp_symbols.getOrPut(self.allocator, temp_key);
    if (bound.found_existing and bound.value_ptr.* != @backingInt(id))
        std.debug.panic("hoisted temp allocation changed its exact SymbolId", .{});
    bound.value_ptr.* = @backingInt(id);
    if (self.getSymbolIdAt(binding)) |existing| {
        if (existing != @backingInt(id)) std.debug.panic("hoisted temp binding changed its exact SymbolId", .{});
    } else try setSymbolId(self, binding, id);
    es_helpers.markStandaloneLateSyntheticTemp(self, id, expected_scope);
    try bindPendingTempProducerReferencesInScope(self, temp_producer_id, id, name_span, expected_scope);
    if (chain) |found| {
        var i: ?usize = found.value.first;
        while (i) |index| {
            const ref = self.pending_temp_refs.items[index];
            std.debug.assert(ref.name_start == name_span.start and ref.name_end == name_span.end);
            const reference_scope = blk: {
                if (!self.options.unsupported.default_params or ref.scope.isNone() or
                    expected_scope.isNone() or expected_scope.toIndex() >= editor.scopes.items.len) break :blk ref.scope;
                // Pass 2 moves lowered default expressions from their separate
                // parameter environment into the function body. Their temp refs
                // must follow that emitted scope so the body var is visible.
                if (editor.scopes.items[expected_scope.toIndex()].parent == ref.scope)
                    break :blk expected_scope;
                if (try reparentLoweredGeneratorParameterScope(self, ref.scope, expected_scope, editor)) |mapped_scope|
                    break :blk mapped_scope;
                break :blk ref.scope;
            };
            try bindPendingHoistedTempReference(self, editor, ref.node, id, reference_scope, ref.flags);
            i = ref.next;
        }
    }
    if (self.pending_temp_ref_chains.count() == 0) self.pending_temp_refs.clearRetainingCapacity();
}

/// A deferred reference may already carry the producer's exact SymbolId or
/// have been attached by another lowering pass. Reuse that reference only
/// after checking its identity, role, and final scope; never count it twice.
fn bindPendingHoistedTempReference(
    self: *Transformer,
    editor: *SemanticEditor,
    node: NodeIndex,
    symbol: SymbolId,
    scope: ScopeId,
    flags: ReferenceFlags,
) Transformer.Error!void {
    const raw_node = @backingInt(node);
    const transformer_symbol = self.getSymbolIdAt(node);
    const editor_symbol = if (raw_node < editor.symbol_ids.items.len)
        editor.symbol_ids.items[raw_node]
    else
        null;
    if (transformer_symbol != null and editor_symbol != null and transformer_symbol.? != editor_symbol.?)
        return editError(error.InvalidSymbol);
    const known_symbol = transformer_symbol orelse editor_symbol;
    if (known_symbol != null and known_symbol.? != @backingInt(symbol))
        return editError(error.InvalidSymbol);

    if (editor.referenceForNode(node) catch |err| return editError(err)) |existing| {
        if (existing.symbol_id != symbol or !std.meta.eql(existing.flags, flags))
            return editError(error.InvalidSymbol);
        if (existing.scope_id != scope) {
            editor.relocateReference(
                node,
                scope,
                symbol,
                existing.stmt_idx,
                existing.scope_stmt_idx,
            ) catch |err| return editError(err);
        }
    } else if (known_symbol != null) {
        editor.addCopiedReference(node, symbol, scope, flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
    } else {
        editor.addReference(node, symbol, scope, flags, Reference.NO_STMT, Reference.NO_STMT) catch |err| return editError(err);
    }

    if (transformer_symbol == null) try setSymbolId(self, node, symbol);
}

fn forgetPendingTempProducerReferences(self: *Transformer, temp_producer_id: u64) void {
    var retained: usize = 0;
    for (self.pending_temp_producer_refs.items) |pending| {
        if (pending.temp_producer_id == temp_producer_id) continue;
        self.pending_temp_producer_refs.items[retained] = pending;
        retained += 1;
    }
    self.pending_temp_producer_refs.shrinkRetainingCapacity(retained);
}

fn hasPendingTempProducerReferences(self: *Transformer, temp_producer_id: u64) bool {
    for (self.pending_temp_producer_refs.items) |pending| {
        if (pending.temp_producer_id == temp_producer_id) return true;
    }
    return false;
}

pub fn recordTempProducerSymbolId(self: *Transformer, temp_producer_id: ?u64, symbol_id: SymbolId) Transformer.Error!void {
    const producer_id = temp_producer_id orelse return;
    if (producer_id == 0) return editError(error.InvalidSymbol);
    const entry = try self.temp_symbols_by_producer_id.getOrPut(self.allocator, producer_id);
    if (entry.found_existing and entry.value_ptr.* != @backingInt(symbol_id))
        return editError(error.InvalidSymbol);
    entry.value_ptr.* = @backingInt(symbol_id);
}

pub fn bindPendingTempProducerReferencesInScope(
    self: *Transformer,
    temp_producer_id: ?u64,
    symbol_id: SymbolId,
    name_span: Span,
    target_scope: ScopeId,
) Transformer.Error!void {
    const producer_id = temp_producer_id orelse return;
    const editor = try editorFor(self);
    for (self.pending_temp_producer_refs.items) |pending| {
        if (pending.temp_producer_id != producer_id) continue;
        if (pending.node.isNone() or @backingInt(pending.node) >= self.ast.nodes.items.len or
            pending.scope.isNone() or @backingInt(pending.scope) >= editor.scopes.items.len or
            pending.name_span.start != name_span.start or pending.name_span.end != name_span.end)
            return editError(error.InvalidSymbol);
        const reference = self.ast.getNode(pending.node);
        if ((reference.tag != .identifier_reference and reference.tag != .assignment_target_identifier) or
            reference.data.string_ref.start != name_span.start or reference.data.string_ref.end != name_span.end)
            return editError(error.InvalidSymbol);
        var reference_scope = pending.scope;
        if (self.options.unsupported.default_params and !reference_scope.isNone() and
            !target_scope.isNone() and target_scope.toIndex() < editor.scopes.items.len and
            editor.scopes.items[target_scope.toIndex()].parent == reference_scope)
        {
            reference_scope = target_scope;
        } else if (try reparentLoweredGeneratorParameterScope(self, reference_scope, target_scope, editor)) |mapped_scope| {
            reference_scope = mapped_scope;
        }
        try bindPendingHoistedTempReference(self, editor, pending.node, symbol_id, reference_scope, pending.flags);
    }
    forgetPendingTempProducerReferences(self, producer_id);
}

fn bindPendingTempProducerReferencesInCallback(
    self: *Transformer,
    temp_producer_id: ?u64,
    symbol_id: SymbolId,
    name_span: Span,
    source_scope: ScopeId,
    binding_scope: ScopeId,
    callback_scope: ScopeId,
    live: *const std.AutoHashMapUnmanaged(u32, void),
    live_scopes: *const std.AutoHashMapUnmanaged(u32, void),
    traces: ?*const std.AutoHashMapUnmanaged(u32, GeneratedNodeTrace),
) Transformer.Error!void {
    const producer_id = temp_producer_id orelse return;
    const editor = try editorFor(self);
    for (self.pending_temp_producer_refs.items) |pending| {
        if (pending.temp_producer_id != producer_id or !live.contains(@backingInt(pending.node))) continue;
        if (pending.node.isNone() or @backingInt(pending.node) >= self.ast.nodes.items.len or
            pending.scope.isNone() or @backingInt(pending.scope) >= editor.scopes.items.len or
            pending.name_span.start != name_span.start or pending.name_span.end != name_span.end)
            return editError(error.InvalidSymbol);
        const reference = self.ast.getNode(pending.node);
        if ((reference.tag != .identifier_reference and reference.tag != .assignment_target_identifier) or
            reference.data.string_ref.start != name_span.start or reference.data.string_ref.end != name_span.end)
            return editError(error.InvalidSymbol);
        const reference_scope = if (traces) |trace_map| blk: {
            const trace = trace_map.get(@backingInt(pending.node)) orelse
                std.debug.panic("captured temp reference has no final scope trace", .{});
            if (trace.ambiguous_scope)
                std.debug.panic("captured temp reference has ambiguous output scopes", .{});
            break :blk try stateTempOutputScope(
                self,
                source_scope,
                callback_scope,
                binding_scope,
                pending.scope,
                trace.scope,
                live_scopes,
            );
        } else try generatedTempRefScope(self, source_scope, callback_scope, pending.scope, live_scopes);
        try bindPendingHoistedTempReference(self, editor, pending.node, symbol_id, reference_scope, pending.flags);
    }
    forgetPendingTempProducerReferences(self, producer_id);
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
    return bindSyntheticTempWithProducerIdentityInScope(
        self,
        binding,
        name_span,
        declaration_span,
        kind,
        scope,
        null,
    );
}

pub fn bindSyntheticTempWithProducerIdentityInScope(
    self: *Transformer,
    binding: NodeIndex,
    name_span: Span,
    declaration_span: Span,
    kind: SymbolKind,
    scope: @import("../../semantic/scope.zig").ScopeId,
    temp_producer_id: ?u64,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (kind == .variable_var or self.state_machine_depth > 0)
        return bindHoistedTempWithProducerIdentity(
            self,
            binding,
            name_span,
            declaration_span,
            scope,
            null,
            temp_producer_id,
        );
    const pending_key = self.currentPendingTempRefKey(name_span);
    if (temp_producer_id != null and self.pending_temp_ref_chains.contains(pending_key))
        return editError(error.InvalidSymbol);
    if (temp_producer_id == null and es_helpers.hasTempAllocatorSpan(self, name_span)) return;
    const chain = self.pending_temp_ref_chains.fetchRemove(self.currentPendingTempRefKey(name_span));
    const id = (try declareSyntheticInScope(self, binding, declaration_span, kind, scope)) orelse return;
    es_helpers.markStandaloneLateSyntheticTemp(self, id, scope);
    try recordTempProducerSymbolId(self, temp_producer_id, id);
    try bindPendingTempProducerReferencesInScope(self, temp_producer_id, id, name_span, scope);
    var i: ?usize = if (chain) |found| found.value.first else null;
    while (i) |index| {
        const ref = self.pending_temp_refs.items[index];
        std.debug.assert(ref.name_start == name_span.start and ref.name_end == name_span.end);
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
    const test_i = @backingInt(test_ref);
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
    // Unresolved/global identifiers have no local Reference to duplicate.
    // cloneNode already carries their external origin through copySymbolId.
    // A resolved SymbolId still requires its exact Reference: do not swallow
    // ReferenceNotFound for a broken local binding.
    if (self.getSymbolIdAt(source) == null) return;
    const editor = try editorFor(self);
    editor.cloneReferenceAtSameLocation(source, clone) catch |err| return editError(err);
}

/// Split a compound assignment's read/write identifier reference after lowering
/// it to a plain assignment. The original target remains a write; the generated
/// value read gets its own exact reference to the same SymbolId and source scope.
pub fn splitCompoundAssignmentIdentifierReference(
    self: *Transformer,
    write_target: NodeIndex,
    value_read: NodeIndex,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const raw_id = self.getSymbolIdAt(write_target) orelse return;
    if (self.getSymbolIdAt(value_read) != raw_id) return editError(error.InvalidSymbol);

    const editor = try editorFor(self);
    const source_reference = (editor.referenceForNode(write_target) catch |err| return editError(err)) orelse
        return editError(error.ReferenceNotFound);
    if (source_reference.flags.declare or !source_reference.flags.read or !source_reference.flags.write)
        return editError(error.InvalidNode);

    const symbol: SymbolId = @fromBackingInt(@intCast(raw_id));
    editor.addCopiedReference(
        value_read,
        symbol,
        source_reference.scope_id,
        .{ .read = true },
        source_reference.stmt_idx,
        source_reference.scope_stmt_idx,
    ) catch |err| return editError(err);
    editor.updateReferenceFlags(write_target, .{ .write = true }) catch |err| return editError(err);
}

/// Split a logical assignment's source reference into the emitted read(s) and write.
/// `??=` needs a second exact read when its ES5 form materializes a ternary.
pub fn splitLogicalAssignmentIdentifierReferences(
    self: *Transformer,
    read_target: NodeIndex,
    value_read: ?NodeIndex,
    write_target: NodeIndex,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const raw_id = self.getSymbolIdAt(read_target) orelse return;
    if (self.getSymbolIdAt(write_target) != raw_id) return editError(error.InvalidSymbol);
    if (value_read) |read| {
        if (self.getSymbolIdAt(read) != raw_id or read == read_target or read == write_target)
            return editError(error.InvalidSymbol);
    }

    const editor = try editorFor(self);
    const source_reference = (editor.referenceForNode(read_target) catch |err| return editError(err)) orelse
        return editError(error.ReferenceNotFound);
    if (source_reference.flags.declare or !source_reference.flags.read or !source_reference.flags.write)
        return editError(error.InvalidNode);

    const symbol: SymbolId = @fromBackingInt(@intCast(raw_id));
    if (value_read) |read| {
        editor.addCopiedReference(
            read,
            symbol,
            source_reference.scope_id,
            .{ .read = true },
            source_reference.stmt_idx,
            source_reference.scope_stmt_idx,
        ) catch |err| return editError(err);
    }
    editor.addCopiedReference(
        write_target,
        symbol,
        source_reference.scope_id,
        .{ .write = true },
        source_reference.stmt_idx,
        source_reference.scope_stmt_idx,
    ) catch |err| return editError(err);
    editor.updateReferenceFlags(read_target, .{ .read = true }) catch |err| return editError(err);
}

/// Isolate a worklet factory copy of a class-self reference from its source
/// AST node and bind it to the reconstructed class identity in the output
/// scope. The parser reference remains owned by the original class body.
pub fn cloneGeneratedClassSelfReference(self: *Transformer, source: NodeIndex) Transformer.Error!NodeIndex {
    if (!self.semantic_edit_enabled) std.debug.panic("worklet class-self copy needs semantic editing", .{});
    const source_id = self.generated_class_copy_source_self_symbol orelse
        std.debug.panic("worklet class-self copy has no source SymbolId", .{});
    const target_id = self.generated_class_copy_target_self_symbol orelse
        std.debug.panic("worklet class-self copy has no reconstructed SymbolId", .{});
    if (self.getSymbolIdAt(source) != source_id)
        std.debug.panic("worklet class-self copy source identity changed", .{});
    const source_node = self.ast.getNode(source);
    if (source_node.tag != .identifier_reference and source_node.tag != .assignment_target_identifier)
        std.debug.panic("worklet class-self copy is not a reference node", .{});

    const editor = try editorFor(self);
    const maybe_reference = editor.referenceForNode(source) catch |err| return editError(err);
    const source_reference = maybe_reference orelse
        std.debug.panic("worklet class-self source has no Reference", .{});
    const clone = try self.ast.addNode(source_node);
    editor.addCopiedReference(
        clone,
        @fromBackingInt(@intCast(target_id)),
        self.current_scope,
        source_reference.flags,
        source_reference.stmt_idx,
        source_reference.scope_stmt_idx,
    ) catch |err| return editError(err);
    try self.trackExactOutputReference(clone, target_id);
    return clone;
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
        @fromBackingInt(@intCast(raw_id)),
        scope,
        .{ .read = true },
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
    try self.trackGeneratorStateReference(argument, @fromBackingInt(@intCast(raw_id)), scope, .{ .read = true });
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
        @fromBackingInt(@intCast(raw_id)),
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
    const raw_id = self.getSymbolIdAt(binding) orelse {
        // A lowering can clone a generated temp read before the state-machine
        // callback has declared that temp. Preserve the exact allocator span
        // so bindGeneratedState can attach this new node to the callback-local
        // SymbolId; name-based lookup would be ambiguous across callbacks.
        if (hoistedTempProducerIdForBinding(self, binding)) |producer_id| {
            if (!try es_helpers.trackKnownHoistedTempRefByProducerId(self, producer_id, target, scope, .{ .read = true }))
                return editError(error.InvalidSymbol);
            return;
        }
        _ = try es_helpers.trackKnownHoistedTempRef(self, target, scope, .{ .read = true });
        return;
    };
    if (self.getSymbolIdAt(target) != raw_id) std.debug.panic("generated read lost source binding symbol", .{});
    const editor = try editorFor(self);
    editor.addCopiedReference(
        target,
        @fromBackingInt(@intCast(raw_id)),
        scope,
        .{ .read = true },
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| return editError(err);
}

/// Defer attaching a generated read until the final AST walk supplies its
/// actual output ScopeId. The producer has already selected the exact binding,
/// so lexical name lookup must not replace that SymbolId later.
pub fn trackExactOutputRead(self: *Transformer, target: NodeIndex, symbol_id: u32) Transformer.Error!void {
    return trackExactOutputReference(self, target, symbol_id);
}

/// Keep a producer-selected SymbolId on a generated reference whose final
/// output scope and read/write role are known only during the final AST walk.
pub fn trackExactOutputReference(self: *Transformer, target: NodeIndex, symbol_id: u32) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    if (target.isNone() or @backingInt(target) >= self.ast.nodes.items.len)
        std.debug.panic("exact generated reference has an invalid AST node", .{});
    const node = self.ast.getNode(target);
    if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier and node.tag != .jsx_identifier)
        std.debug.panic("exact generated reference has a non-reference AST node", .{});
    const editor = try editorFor(self);
    if (symbol_id >= editor.symbols.items.len)
        std.debug.panic("exact generated reference has an out-of-range SymbolId", .{});
    const raw = @backingInt(target);
    if (self.exact_output_ref_symbol_ids.get(raw)) |existing| {
        if (existing != symbol_id)
            std.debug.panic("generated reference was assigned multiple exact SymbolIds", .{});
        return;
    }
    try self.exact_output_ref_symbol_ids.put(self.allocator, raw, symbol_id);
}

/// A named class expression's self binding becomes the implementation
/// function name in its generated wrapper scope.
pub fn moveBindingToOutputScope(self: *Transformer, binding: NodeIndex, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled or binding.isNone() or scope.isNone()) return;
    const raw_id = self.getSymbolIdAt(binding) orelse return;
    const editor = try editorFor(self);
    editor.moveSymbolToScope(@fromBackingInt(@intCast(raw_id)), scope) catch |err| return editError(err);
}

pub fn moveSymbolToOutputScope(self: *Transformer, raw_id: u32, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled or scope.isNone()) return;
    const editor = try editorFor(self);
    editor.moveSymbolToScope(@fromBackingInt(@intCast(raw_id)), scope) catch |err| return editError(err);
}

/// Rebind a newly generated declaration node to the exact existing class-self
/// SymbolId selected by the transform's class owner.
pub fn setGeneratedSymbolId(self: *Transformer, node: NodeIndex, raw_id: u32) Transformer.Error!void {
    if (node.isNone() or @backingInt(node) < self.parser_node_count) std.debug.panic("cannot replace a parser-owned SymbolId", .{});
    const index = @backingInt(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    if (self.semantic_editor) |*editor| {
        if (editor.symbol_ids.items.len <= index)
            try editor.symbol_ids.appendNTimes(self.allocator, null, index + 1 - editor.symbol_ids.items.len);
        if (self.ast.getNode(node).tag == .binding_identifier) {
            if (raw_id >= editor.symbols.items.len) std.debug.panic("generated binding SymbolId is out of range", .{});
            editor.rebindBinding(node, @fromBackingInt(@intCast(raw_id))) catch |err| return editError(err);
        } else {
            editor.symbol_ids.items[index] = raw_id;
        }
    }
    self.symbol_ids.items[index] = raw_id;
}

pub fn rebindOutputBinding(self: *Transformer, node: NodeIndex, raw_id: u32) Transformer.Error!void {
    if (node.isNone()) std.debug.panic("invalid output binding rebind", .{});
    if (self.semantic_edit_enabled) {
        const editor = try editorFor(self);
        if (raw_id >= editor.symbols.items.len) std.debug.panic("invalid output binding rebind", .{});
        editor.rebindBinding(node, @fromBackingInt(@intCast(raw_id))) catch |err| return editError(err);
    } else if (self.symbols.len != 0 and raw_id >= self.symbols.len) {
        std.debug.panic("invalid output binding rebind", .{});
    }
    const index = @backingInt(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    self.symbol_ids.items[index] = raw_id;
}

pub fn splitOutputBindingAsVar(self: *Transformer, node: NodeIndex, expected_raw_id: u32, scope: ScopeId, declaration_span: Span) Transformer.Error!u32 {
    if (!self.semantic_edit_enabled) return expected_raw_id;
    const editor = try editorFor(self);
    const id = editor.splitBindingIdentity(
        node,
        @fromBackingInt(@intCast(expected_raw_id)),
        scope,
        .variable_var,
        declaration_span,
    ) catch |err| return editError(err);
    const index = @backingInt(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    self.symbol_ids.items[index] = @backingInt(id);
    return @backingInt(id);
}

pub fn relocateOutputSymbolAs(self: *Transformer, raw_id: u32, scope: ScopeId, binding: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.relocateSymbolAs(@fromBackingInt(@intCast(raw_id)), scope, binding) catch |err| return editError(err);
}

/// Split the parameter identity from a same-named body `var` that the source
/// analyzer represented with one SymbolId. The parameter binding gets a fresh
/// emitted name; the original identity stays with the body environment.
pub fn splitParameterBodyVarBinding(
    self: *Transformer,
    binding: NodeIndex,
    body_var_id: u32,
    alias_span: Span,
    body_var_span: Span,
) Transformer.Error!?SymbolId {
    if (!self.semantic_edit_enabled) return null;
    const editor = try editorFor(self);
    if (binding.isNone() or @backingInt(binding) >= self.ast.nodes.items.len or
        @backingInt(binding) >= editor.symbol_ids.items.len or
        @backingInt(binding) >= self.symbol_ids.items.len)
        std.debug.panic("invalid parameter binding for body-var identity split", .{});
    const binding_node = self.ast.getNode(binding);
    if (binding_node.tag != .binding_identifier or alias_span.start & ast_mod.Ast.STRING_TABLE_BIT == 0)
        std.debug.panic("invalid parameter binding shape for body-var identity split", .{});
    if (editor.symbol_ids.items[@backingInt(binding)] != body_var_id or
        self.symbol_ids.items[@backingInt(binding)] != body_var_id)
        std.debug.panic("parameter/body-var split no longer points at the shared SymbolId", .{});
    if (body_var_id >= editor.symbols.items.len) std.debug.panic("parameter/body-var SymbolId is out of range", .{});
    const original = editor.symbols.items[body_var_id];
    if (original.kind != .parameter and original.kind != .variable_var)
        std.debug.panic("parameter/body-var split found an unexpected source SymbolKind", .{});
    if (original.scope_id.isNone() or original.scope_id.toIndex() >= editor.scopes.items.len or
        editor.scopes.items[original.scope_id.toIndex()].kind != .function)
        std.debug.panic("parameter/body-var split found a non-function var scope", .{});
    const source_name = if (original.synthetic_name.len > 0) original.synthetic_name else self.ast.getText(original.name);
    if (editor.scope_maps.items[original.scope_id.toIndex()].get(source_name) != body_var_id)
        std.debug.panic("parameter/body-var source scope map lost the shared SymbolId", .{});

    const alias_name = self.ast.getText(alias_span);
    if (alias_name.len == 0 or editor.scope_maps.items[original.scope_id.toIndex()].contains(alias_name))
        std.debug.panic("parameter/body-var alias is empty or already bound", .{});

    const slot = @backingInt(binding);
    editor.symbol_ids.items[slot] = null;
    self.symbol_ids.items[slot] = null;
    const alias_binding = es_helpers.makeExactSyntheticBinding(self, alias_name) catch return error.OutOfMemory;
    const alias_binding_name = self.ast.getNode(alias_binding).data.string_ref;
    const parameter_id = editor.declare(
        alias_binding,
        alias_binding_name,
        binding_node.span,
        original.scope_id,
        .parameter,
        Reference.NO_STMT,
        Reference.NO_STMT,
    ) catch |err| {
        editor.symbol_ids.items[slot] = body_var_id;
        self.symbol_ids.items[slot] = body_var_id;
        return editError(err);
    };
    editor.symbols.items[@backingInt(parameter_id)].name = original.name;
    editor.attachExistingBinding(binding, parameter_id) catch |err| return editError(err);
    if (original.kind == .parameter) {
        editor.symbols.items[body_var_id].kind = .variable_var;
        editor.symbols.items[body_var_id].decl_flags = SymbolKind.variable_var.declFlags();
        editor.symbols.items[body_var_id].declaration_span = body_var_span;
    }
    self.symbol_ids.items[slot] = @backingInt(parameter_id);
    return parameter_id;
}

/// Move a parameter-initializer reference from a shared parameter/body-var
/// identity to the newly split parameter identity.
pub fn rebindParameterBodyVarReference(self: *Transformer, reference: NodeIndex, parameter_id: SymbolId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.rebindReference(reference, parameter_id) catch |err| return editError(err);
    const slot = @backingInt(reference);
    if (self.symbol_ids.items.len <= slot)
        try self.symbol_ids.appendNTimes(self.allocator, null, slot + 1 - self.symbol_ids.items.len);
    self.symbol_ids.items[slot] = @backingInt(parameter_id);
}

pub fn renameParameterEnvironmentBinding(self: *Transformer, raw_id: u32, name: []const u8) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.renameParameterEnvironmentBinding(@fromBackingInt(@intCast(raw_id)), name) catch |err| return editError(err);
}

pub fn renameParameterEnvironmentBindingForDynamicBody(self: *Transformer, raw_id: u32, name: []const u8) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.renameParameterEnvironmentBindingForDynamicBody(@fromBackingInt(@intCast(raw_id)), name) catch |err| return editError(err);
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
        @fromBackingInt(@intCast(raw_id)),
        reference.stmt_idx,
        reference.scope_stmt_idx,
    ) catch |err| return editError(err);
    const index = @backingInt(node);
    if (self.symbol_ids.items.len <= index)
        try self.symbol_ids.appendNTimes(self.allocator, null, index + 1 - self.symbol_ids.items.len);
    self.symbol_ids.items[index] = raw_id;
}

/// A generated binding can materialize a symbol that the analyzer represented
/// only as a declaration facade. Keep the declaration row alongside its node ID.
pub fn ensureSymbolDeclaration(self: *Transformer, raw_id: u32, scope: ScopeId) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.ensureDeclaration(@fromBackingInt(@intCast(raw_id)), scope) catch |err| return editError(err);
}

pub fn ensureSymbolDeclarationAtNode(self: *Transformer, raw_id: u32, scope: ScopeId, binding: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    const editor = try editorFor(self);
    editor.ensureDeclarationAtNode(@fromBackingInt(@intCast(raw_id)), scope, binding) catch |err| return editError(err);
}

/// State-machine collection can flatten an empty generated block while keeping
/// its child lexical scopes. Once dead references are removed, drop only those
/// unreachable generated block owners that carry no bindings or references.
fn elideUnreachableEmptyGeneratedScopes(
    self: *Transformer,
    editor: *SemanticEditor,
    reachable_nodes: *const std.AutoHashMapUnmanaged(u32, void),
) Transformer.Error!void {
    var candidates: std.ArrayList(NodeIndex) = .empty;
    defer candidates.deinit(self.allocator);
    var owners = editor.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const owner_raw = entry.key_ptr.*;
        const scope_raw = entry.value_ptr.*;
        if (owner_raw >= self.ast.nodes.items.len or reachable_nodes.contains(owner_raw) or
            scope_raw < self.scopes.len or scope_raw >= editor.scopes.items.len) continue;
        try candidates.append(self.allocator, @fromBackingInt(@intCast(owner_raw)));
    }
    for (candidates.items) |owner| {
        _ = editor.elideEmptyGeneratedScopeOwner(owner) catch |err| return editError(err);
    }
}

/// Keep a declaration reference anchored to an emitted binding when a lowering
/// copied that binding, materialized a deferred helper declaration, or discarded
/// its source node. Replacements come only from reachable binding nodes carrying
/// that exact SymbolId; stale anchors must still agree with the declaration row.
fn reanchorDetachedDeclarations(
    self: *Transformer,
    editor: *SemanticEditor,
    reachable: *const std.AutoHashMapUnmanaged(u32, void),
) Transformer.Error!void {
    const EmittedDeclaration = struct { node: u32, count: u32 = 1 };
    var emitted_bindings: std.AutoHashMapUnmanaged(u32, EmittedDeclaration) = .empty;
    defer emitted_bindings.deinit(self.allocator);
    var declarations = try symbol_coverage.collectDeclarationNodes(self.allocator, self.ast, reachable);
    defer declarations.deinit(self.allocator);
    var nodes = declarations.iterator();
    while (nodes.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= self.ast.nodes.items.len or raw >= editor.symbol_ids.items.len) continue;
        const sid = editor.symbol_ids.items[raw] orelse continue;
        if (sid >= editor.symbols.items.len) continue;
        if (emitted_bindings.getPtr(sid)) |existing| {
            existing.count += 1;
        } else {
            try emitted_bindings.put(self.allocator, sid, .{ .node = raw });
        }
    }
    for (editor.references.items) |*reference| {
        if (!reference.flags.declare) continue;
        const sid = @backingInt(reference.symbol_id);
        const candidate = emitted_bindings.get(sid) orelse {
            if (!reference.declaration_node_index.isNone()) {
                const old_raw = @backingInt(reference.declaration_node_index);
                if (!reachable.contains(old_raw) and old_raw < editor.symbol_ids.items.len and
                    editor.symbol_ids.items[old_raw] == sid)
                {
                    // Type erasure and import elision can remove the declaration
                    // itself. Retire only a stale anchor that still proves it
                    // belonged to this SymbolId; an unclassified live node stays
                    // visible to the exact audit as a mismatch.
                    reference.declaration_node_index = .none;
                }
            }
            continue;
        };
        // A symbol may have multiple declaration nodes (for example repeated
        // var declarations). Without a preserved row-to-node mapping, choosing
        // one would invent an exact identity, so leave the mismatch visible.
        if (candidate.count != 1) continue;
        if (reference.declaration_node_index.isNone()) {
            reference.declaration_node_index = @fromBackingInt(@intCast(candidate.node));
            continue;
        }
        const old_raw = @backingInt(reference.declaration_node_index);
        if (reachable.contains(old_raw) or old_raw >= editor.symbol_ids.items.len or
            editor.symbol_ids.items[old_raw] != sid) continue;
        reference.declaration_node_index = @fromBackingInt(@intCast(candidate.node));
    }
}

/// Check that deferred temp handoffs which survived into the emitted AST now
/// point at the exact semantic reference created for their producer. Dead
/// lowered nodes may remain in the side tables, but live nodes must never
/// silently leave semantic editing without a SymbolId and output ScopeId.
pub fn validateDeferredGeneratedTempHandoffs(
    self: *Transformer,
    editor: *SemanticEditor,
    live: *const std.AutoHashMapUnmanaged(u32, void),
) bool {
    const valid_temp_reference = struct {
        fn check(
            transformer: *Transformer,
            semantic_editor: *SemanticEditor,
            node_index: NodeIndex,
            expected_symbol_id: ?u32,
            expected_flags: ReferenceFlags,
            expected_name: Span,
        ) bool {
            if (node_index.isNone() or @backingInt(node_index) >= transformer.ast.nodes.items.len) return false;
            const node = transformer.ast.getNode(node_index);
            if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) return false;
            const name_span = node.data.string_ref;
            if (name_span.start != expected_name.start or name_span.end != expected_name.end) return false;
            const raw_symbol_id = transformer.getSymbolIdAt(node_index) orelse return false;
            if (expected_symbol_id) |expected| {
                if (raw_symbol_id != expected) return false;
            }
            if (raw_symbol_id >= semantic_editor.symbols.items.len) return false;
            const symbol = semantic_editor.symbols.items[raw_symbol_id];
            if (symbol.kind != .variable_var or symbol.name.start != name_span.start or
                symbol.name.end != name_span.end or symbol.scope_id.isNone() or
                @backingInt(symbol.scope_id) >= semantic_editor.scopes.items.len or
                !std.mem.eql(u8, symbol.synthetic_name, transformer.ast.getText(name_span))) return false;
            const reference = (semantic_editor.referenceForNode(node_index) catch return false) orelse return false;
            if (reference.node_index != node_index or @backingInt(reference.symbol_id) != raw_symbol_id or
                !std.meta.eql(reference.flags, expected_flags) or reference.scope_id.isNone() or
                @backingInt(reference.scope_id) >= semantic_editor.scopes.items.len) return false;
            if (!scopeWithin(semantic_editor.scopes.items, reference.scope_id, symbol.scope_id)) return false;
            return true;
        }
    }.check;

    var chains = self.pending_temp_ref_chains.iterator();
    while (chains.next()) |entry| {
        const key = entry.key_ptr.*;
        var cursor: ?usize = entry.value_ptr.first;
        var last: ?usize = null;
        var visited: usize = 0;
        while (cursor) |index| {
            if (index >= self.pending_temp_refs.items.len or visited >= self.pending_temp_refs.items.len) return false;
            visited += 1;
            const pending = self.pending_temp_refs.items[index];
            if (pending.name_start != key.name_start or pending.name_end != key.name_end or
                pending.producer_scope != key.producer_scope or pending.scope.isNone() or
                @backingInt(pending.scope) >= editor.scopes.items.len or pending.node.isNone() or
                @backingInt(pending.node) >= self.ast.nodes.items.len) return false;
            const reference_node = self.ast.getNode(pending.node);
            if (reference_node.tag != .identifier_reference and reference_node.tag != .assignment_target_identifier) return false;
            if (reference_node.data.string_ref.start != key.name_start or
                reference_node.data.string_ref.end != key.name_end) return false;
            if (live.contains(@backingInt(pending.node)) and
                !valid_temp_reference(self, editor, pending.node, null, pending.flags, reference_node.data.string_ref)) return false;
            last = index;
            cursor = pending.next;
        }
        if (last == null or last.? != entry.value_ptr.last) return false;
    }

    for (self.pending_temp_producer_refs.items) |pending| {
        if (pending.temp_producer_id == 0 or pending.node.isNone() or
            @backingInt(pending.node) >= self.ast.nodes.items.len or pending.scope.isNone() or
            @backingInt(pending.scope) >= editor.scopes.items.len)
            return false;
        const reference_node = self.ast.getNode(pending.node);
        if (reference_node.tag != .identifier_reference and reference_node.tag != .assignment_target_identifier)
            return false;
        if (reference_node.data.string_ref.start != pending.name_span.start or
            reference_node.data.string_ref.end != pending.name_span.end)
            return false;
        // A live captured reference may not leave semantic editing before its
        // exact allocator producer is bound to a SymbolId.
        if (live.contains(@backingInt(pending.node))) return false;
    }

    for (self.generator_state_temp_refs.items) |pending| {
        if (pending.reference.isNone() or !live.contains(@backingInt(pending.reference))) continue;
        if (pending.binding.isNone() or !live.contains(@backingInt(pending.binding)) or
            @backingInt(pending.binding) >= self.ast.nodes.items.len) return false;
        const binding = self.ast.getNode(pending.binding);
        if (binding.tag != .binding_identifier or pending.scope.isNone() or
            @backingInt(pending.scope) >= editor.scopes.items.len) return false;
        const symbol_id = self.getSymbolIdAt(pending.binding) orelse return false;
        if (symbol_id >= editor.symbols.items.len) return false;
        const symbol = editor.symbols.items[symbol_id];
        if (symbol.kind != .variable_var or symbol.scope_id.isNone() or
            @backingInt(symbol.scope_id) >= editor.scopes.items.len or
            symbol.name.start != binding.data.string_ref.start or
            symbol.name.end != binding.data.string_ref.end or
            !std.mem.eql(u8, symbol.synthetic_name, self.ast.getText(binding.data.string_ref))) return false;
        if (!valid_temp_reference(self, editor, pending.reference, symbol_id, pending.flags, binding.data.string_ref)) return false;
    }
    return true;
}

/// 변환 중 복사된 사용자 식별자와 scope owner도 편집 결과에 합친다.
pub fn finishSemanticEdit(self: *Transformer) Transformer.Error!?SemanticEditor.Result {
    if (!self.semantic_edit_enabled) return null;
    if (self.static_class_contexts.items.len != 0 or self.static_class_captures.count() != 0)
        std.debug.panic("static class capture has no completed output owner", .{});
    try resolveReachableScopeOwners(self);
    // Scope-owner remaps are semantic edits even when no binding/reference was
    // synthesized. Arrow-to-function and copied body scopes need a final map.
    if (self.semantic_editor == null and (self.scope_owner_remaps.count() > 0 or self.node_scope_provenance_changed)) {
        _ = try editorFor(self);
    }
    const editor = if (self.semantic_editor) |*e| e else return null;
    if (self.pending_exact_symbol_refs.items.len != 0)
        std.debug.panic("semantic edit finished with unresolved producer-owned SymbolId references", .{});
    if (self.deferred_generator_loop_migrations.count() != 0)
        std.debug.panic("semantic edit finished with unresolved generator loop migrations", .{});
    var deferred_loop_owners = self.deferred_generator_loop_owners.iterator();
    while (deferred_loop_owners.next()) |entry| {
        const function_scope = entry.value_ptr.function_scope orelse
            std.debug.panic("deferred generator loop owner has no exact function ScopeId", .{});
        if (!entry.value_ptr.migration_complete)
            std.debug.panic("semantic edit finished with an incomplete generator loop owner", .{});
        if (self.transformed_scope_owner_map.get(entry.key_ptr.*) orelse
            self.scope_owner_map.get(entry.key_ptr.*) orelse
            editor.scope_owner_map.get(entry.key_ptr.*)) |owner_scope_raw|
        {
            if (owner_scope_raw != @backingInt(function_scope))
                std.debug.panic("deferred generator loop owner changed its exact ScopeId", .{});
        }
    }
    if (self.tracked_runtime_helper_refs.items.len > 0) {
        for (self.tracked_runtime_helper_refs.items) |reference| {
            if (reference.symbol_id >= editor.symbols.items.len)
                std.debug.panic("generated runtime helper reference has an out-of-range SymbolId", .{});
            if (editor.symbols.items[reference.symbol_id].synthetic_kind == null and
                !self.runtime_helper_import_bindings.contains(reference.symbol_id))
                std.debug.panic("generated runtime helper reference has no import binding", .{});
        }
    }
    var remaps = self.scope_owner_remaps.iterator();
    while (remaps.next()) |entry| {
        if (self.scope_owner_removed.contains(entry.key_ptr.*)) {
            editor.remapScopeOwnerAfterInPlaceRewrite(@fromBackingInt(@intCast(entry.key_ptr.*)), @fromBackingInt(@intCast(entry.value_ptr.*))) catch |err| return editError(err);
        } else {
            editor.remapScopeOwner(@fromBackingInt(@intCast(entry.key_ptr.*)), @fromBackingInt(@intCast(entry.value_ptr.*))) catch |err| return editError(err);
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
            if (!validateDeferredGeneratedTempHandoffs(self, editor, &live))
                std.debug.panic("semantic edit finished with unresolved deferred generated temp handoffs", .{});
            try reanchorDetachedDeclarations(self, editor, &live);
            var i = editor.references.items.len;
            while (i > 0) {
                i -= 1;
                const ref = editor.references.items[i];
                if (ref.node_index.isNone() or live.contains(@backingInt(ref.node_index))) continue;
                try removeReference(self, editor, ref.node_index);
            }
            var stale_uses: std.ArrayList(NodeIndex) = .empty;
            defer stale_uses.deinit(self.allocator);
            var uses = editor.node_scope_provenance.keyIterator();
            while (uses.next()) |node| if (!live.contains(@backingInt(node.*))) try stale_uses.append(self.allocator, node.*);
            for (stale_uses.items) |node| _ = editor.node_scope_provenance.remove(node);
            try elideUnreachableEmptyGeneratedScopes(self, editor, &live);
        }
    }
    const result = editor.finish() catch |err| return editError(err);
    editor.deinit();
    self.semantic_editor = null;
    self.tracked_runtime_helper_refs.clearRetainingCapacity();
    self.tracked_runtime_helper_ref_index.clearRetainingCapacity();
    return result;
}

// Hostile regression fixtures for PR #6029. These deliberately seed conflicting
// transformer/editor identities so hoisted-temp handoff rejects stale bindings.
const HoistedTempHostileFixture = struct {
    const Parser = @import("../../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;

    allocator: std.mem.Allocator,
    scanner: Scanner,
    parser: Parser,
    analyzer: SemanticAnalyzer,
    transformer: Transformer,
    target_id: SymbolId,
    other_id: SymbolId,
    target_name_span: Span,
    program_scope: ScopeId,
    function_scope: ScopeId,
    reference_node: NodeIndex,

    fn init(allocator: std.mem.Allocator) !*HoistedTempHostileFixture {
        const fixture = try allocator.create(HoistedTempHostileFixture);
        fixture.allocator = allocator;
        fixture.scanner = try Scanner.init(allocator, "const target = 0; function inner() { target; }");
        fixture.parser = Parser.init(allocator, &fixture.scanner);
        fixture.parser.configureFromExtension(".mjs");
        const root = try fixture.parser.parse();
        fixture.analyzer = SemanticAnalyzer.init(allocator, &fixture.parser.ast);
        fixture.analyzer.is_module = true;
        try fixture.analyzer.analyze();

        fixture.program_scope = @fromBackingInt(@intCast(fixture.analyzer.scope_owner_map.get(@backingInt(root)) orelse
            return error.MissingProgramScope));

        var target_binding: ?NodeIndex = null;
        var other_binding: ?NodeIndex = null;
        var target_reference: ?NodeIndex = null;
        for (fixture.parser.ast.nodes.items, 0..) |node, raw| {
            const text = switch (node.tag) {
                .binding_identifier, .identifier_reference => fixture.parser.ast.getText(node.data.string_ref),
                else => continue,
            };
            if (node.tag == .binding_identifier and std.mem.eql(u8, text, "target")) {
                target_binding = @fromBackingInt(@intCast(raw));
            } else if (node.tag == .binding_identifier and std.mem.eql(u8, text, "inner")) {
                other_binding = @fromBackingInt(@intCast(raw));
            } else if (node.tag == .identifier_reference and std.mem.eql(u8, text, "target")) {
                target_reference = @fromBackingInt(@intCast(raw));
            }
        }
        const target_binding_node = target_binding orelse return error.MissingTargetBinding;
        const other_binding_node = other_binding orelse return error.MissingAlternateBinding;
        fixture.reference_node = target_reference orelse return error.MissingTargetReference;
        fixture.target_name_span = fixture.parser.ast.getNode(target_binding_node).data.string_ref;
        fixture.target_id = @fromBackingInt(@intCast(fixture.analyzer.symbol_ids.items[@backingInt(target_binding_node)] orelse
            return error.MissingTargetSymbolId));
        fixture.other_id = @fromBackingInt(@intCast(fixture.analyzer.symbol_ids.items[@backingInt(other_binding_node)] orelse
            return error.MissingAlternateSymbolId));
        fixture.function_scope = undefined;
        for (fixture.analyzer.references.items) |reference| {
            if (reference.node_index == fixture.reference_node) {
                fixture.function_scope = reference.scope_id;
                break;
            }
        }
        if (fixture.function_scope.isNone()) return error.MissingReferenceScope;

        fixture.transformer = try Transformer.init(allocator, &fixture.parser.ast, .{});
        try fixture.transformer.initSymbolIds(fixture.analyzer.symbol_ids.items);
        fixture.transformer.symbols = fixture.analyzer.symbols.items;
        fixture.transformer.class_self_symbol_map = fixture.analyzer.class_self_symbol_map;
        fixture.transformer.references = fixture.analyzer.references.items;
        fixture.transformer.scopes = fixture.analyzer.scopes.items;
        fixture.transformer.scope_maps = fixture.analyzer.scope_maps.items;
        fixture.transformer.scope_owner_map = fixture.analyzer.scope_owner_map;
        fixture.transformer.node_scope_provenance = fixture.analyzer.node_scope_provenance;
        fixture.transformer.semantic_edit_enabled = true;
        fixture.transformer.current_scope = fixture.program_scope;
        return fixture;
    }

    fn syntheticReference(self: *HoistedTempHostileFixture) !NodeIndex {
        return es_helpers.makeIdentifierRefFromSpan(&self.transformer, self.target_name_span);
    }

    fn setTransformerSymbol(self: *HoistedTempHostileFixture, node: NodeIndex, id: ?SymbolId) !void {
        const raw = @backingInt(node);
        if (self.transformer.symbol_ids.items.len <= raw) {
            try self.transformer.symbol_ids.appendNTimes(
                self.allocator,
                null,
                raw + 1 - self.transformer.symbol_ids.items.len,
            );
        }
        self.transformer.symbol_ids.items[raw] = if (id) |symbol| @backingInt(symbol) else null;
    }

    fn setEditorSymbol(self: *HoistedTempHostileFixture, node: NodeIndex, id: ?SymbolId) !*SemanticEditor {
        const editor = try editorFor(&self.transformer);
        const raw = @backingInt(node);
        if (editor.symbol_ids.items.len <= raw) {
            try editor.symbol_ids.appendNTimes(editor.allocator, null, raw + 1 - editor.symbol_ids.items.len);
        }
        editor.symbol_ids.items[raw] = if (id) |symbol| @backingInt(symbol) else null;
        return editor;
    }
};

fn expectInvalidSemanticEditPanic(mode: []const u8, expected_error: []const u8) !void {
    const allocator = std.testing.allocator;
    const executable_path = try std.process.executablePathAlloc(std.testing.io, allocator);
    defer allocator.free(executable_path);

    var child_environ = std.process.Environ.Map.init(allocator);
    defer child_environ.deinit();
    try child_environ.put("ZTS_6029_HOSTILE_PANIC_MODE", mode);

    // Run only the dedicated child through Zig's indexed test protocol.
    // Re-running the full test executable would recurse through unrelated
    // suites for every hostile input once this module is explicitly imported.
    const child_index: u32 = blk: {
        for (@import("builtin").test_functions, 0..) |test_function, index| {
            if (std.mem.endsWith(u8, test_function.name, "hostile SymbolId 6029 panic child"))
                break :blk @intCast(index);
        }
        return error.MissingHostilePanicChild;
    };
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ executable_path, "--listen=-" },
        .environ_map = &child_environ,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var message_buffer: [64]u8 = undefined;
    var pipe_writer = child.stdin.?.writer(io, &message_buffer);
    const client: std.zig.Client = .{ .in = undefined, .out = &pipe_writer.interface };
    try client.serveRunTest(child_index);
    try client.serveBodylessMessage(.exit);
    child.stdin.?.close(io);
    child.stdin = null;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_reader = std.Io.File.Reader.initStreaming(child.stderr.?, io, &stderr_buffer);
    const stderr = try stderr_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(stderr);
    const term = try child.wait(io);
    try std.testing.expect(!term.success());
    const expected_message = try std.fmt.allocPrint(
        allocator,
        "invalid transform semantic edit: {s}",
        .{expected_error},
    );
    defer allocator.free(expected_message);
    try std.testing.expect(std.mem.indexOf(u8, stderr, expected_message) != null);
}

test "hostile SymbolId 6029 panic child" {
    if (!std.testing.environ.containsUnemptyConstant("ZTS_6029_HOSTILE_PANIC_MODE")) return;
    const allocator = std.testing.allocator;
    const mode = try std.testing.environ.getAlloc(allocator, "ZTS_6029_HOSTILE_PANIC_MODE");
    defer allocator.free(mode);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const fixture = try HoistedTempHostileFixture.init(arena.allocator());

    if (std.mem.eql(u8, mode, "invalid-import-creation-scope")) {
        try rejectPoisonedImportCreationScope(arena.allocator(), false);
    } else if (std.mem.eql(u8, mode, "conflicting-transformer-editor")) {
        const editor = try fixture.setEditorSymbol(fixture.reference_node, fixture.other_id);
        try bindPendingHoistedTempReference(
            &fixture.transformer,
            editor,
            fixture.reference_node,
            fixture.target_id,
            fixture.function_scope,
            .{ .read = true },
        );
    } else if (std.mem.eql(u8, mode, "conflicting-expected")) {
        const node = try fixture.syntheticReference();
        const editor = try fixture.setEditorSymbol(node, null);
        try fixture.setTransformerSymbol(node, fixture.target_id);
        try bindPendingHoistedTempReference(
            &fixture.transformer,
            editor,
            node,
            fixture.other_id,
            fixture.function_scope,
            .{ .read = true },
        );
    } else if (std.mem.eql(u8, mode, "wrong-reference-symbol")) {
        const editor = try editorFor(&fixture.transformer);
        var found = false;
        for (editor.references.items) |*reference| {
            if (reference.node_index != fixture.reference_node) continue;
            reference.symbol_id = fixture.other_id;
            found = true;
            break;
        }
        if (!found) return error.MissingReferenceRecord;
        try bindPendingHoistedTempReference(
            &fixture.transformer,
            editor,
            fixture.reference_node,
            fixture.target_id,
            fixture.function_scope,
            .{ .read = true },
        );
    } else if (std.mem.eql(u8, mode, "wrong-reference-flags")) {
        const editor = try editorFor(&fixture.transformer);
        var found = false;
        for (editor.references.items) |*reference| {
            if (reference.node_index != fixture.reference_node) continue;
            reference.flags = .{ .write = true };
            found = true;
            break;
        }
        if (!found) return error.MissingReferenceRecord;
        try bindPendingHoistedTempReference(
            &fixture.transformer,
            editor,
            fixture.reference_node,
            fixture.target_id,
            fixture.function_scope,
            .{ .read = true },
        );
    } else if (std.mem.eql(u8, mode, "invalid-existing-scope")) {
        const editor = try editorFor(&fixture.transformer);
        var found = false;
        for (editor.references.items) |*reference| {
            if (reference.node_index != fixture.reference_node) continue;
            reference.scope_id = .none;
            found = true;
            break;
        }
        if (!found) return error.MissingReferenceRecord;
        try bindPendingHoistedTempReference(
            &fixture.transformer,
            editor,
            fixture.reference_node,
            fixture.target_id,
            fixture.program_scope,
            .{ .read = true },
        );
    } else {
        return error.UnknownHostilePanicMode;
    }
    return error.HostileMutationWasAccepted;
}

fn isSemanticEditPanicChild() bool {
    return std.testing.environ.containsUnemptyConstant("ZTS_6029_HOSTILE_PANIC_MODE");
}

test "hostile SymbolId 6029 reject conflicting transformer/editor SID" {
    if (isSemanticEditPanicChild()) return;
    try expectInvalidSemanticEditPanic("conflicting-transformer-editor", "InvalidSymbol");
}

test "hostile SymbolId 6029 reject conflicting expected SID" {
    if (isSemanticEditPanicChild()) return;
    try expectInvalidSemanticEditPanic("conflicting-expected", "InvalidSymbol");
}

test "hostile SymbolId 6029 reject wrong reference symbol" {
    if (isSemanticEditPanicChild()) return;
    try expectInvalidSemanticEditPanic("wrong-reference-symbol", "InvalidSymbol");
}

test "hostile SymbolId 6029 reject wrong reference flags" {
    if (isSemanticEditPanicChild()) return;
    try expectInvalidSemanticEditPanic("wrong-reference-flags", "InvalidSymbol");
}

test "hostile SymbolId 6029 relocates existing reference to requested scope" {
    if (isSemanticEditPanicChild()) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try HoistedTempHostileFixture.init(arena.allocator());
    const editor = try editorFor(&fixture.transformer);
    const before = try editor.referenceForNode(fixture.reference_node) orelse return error.MissingReferenceRecord;
    try std.testing.expectEqual(fixture.function_scope, before.scope_id);
    try bindPendingHoistedTempReference(
        &fixture.transformer,
        editor,
        fixture.reference_node,
        fixture.target_id,
        fixture.program_scope,
        .{ .read = true },
    );
    const after = try editor.referenceForNode(fixture.reference_node) orelse return error.MissingReferenceRecord;
    try std.testing.expectEqual(fixture.program_scope, after.scope_id);
}

test "hostile SymbolId 6029 reuses existing reference without double counting" {
    if (isSemanticEditPanicChild()) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try HoistedTempHostileFixture.init(arena.allocator());
    const editor = try editorFor(&fixture.transformer);
    const reference_count = editor.symbols.items[@backingInt(fixture.target_id)].reference_count;
    const write_count = editor.symbols.items[@backingInt(fixture.target_id)].write_count;
    const reference_len = editor.references.items.len;
    try bindPendingHoistedTempReference(
        &fixture.transformer,
        editor,
        fixture.reference_node,
        fixture.target_id,
        fixture.function_scope,
        .{ .read = true },
    );
    try std.testing.expectEqual(reference_len, editor.references.items.len);
    try std.testing.expectEqual(reference_count, editor.symbols.items[@backingInt(fixture.target_id)].reference_count);
    try std.testing.expectEqual(write_count, editor.symbols.items[@backingInt(fixture.target_id)].write_count);
}

test "hostile SymbolId 6029 preserves copied SID while attaching reference" {
    if (isSemanticEditPanicChild()) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try HoistedTempHostileFixture.init(arena.allocator());
    const node = try fixture.syntheticReference();
    const editor = try fixture.setEditorSymbol(node, fixture.target_id);
    try fixture.setTransformerSymbol(node, fixture.target_id);
    const before = editor.symbols.items[@backingInt(fixture.target_id)].reference_count;
    try bindPendingHoistedTempReference(
        &fixture.transformer,
        editor,
        node,
        fixture.target_id,
        fixture.function_scope,
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(?u32, @backingInt(fixture.target_id)), fixture.transformer.getSymbolIdAt(node));
    try std.testing.expectEqual(@as(?u32, @backingInt(fixture.target_id)), editor.symbol_ids.items[@backingInt(node)]);
    const reference = try editor.referenceForNode(node) orelse return error.MissingCopiedReference;
    try std.testing.expectEqual(fixture.target_id, reference.symbol_id);
    try std.testing.expectEqual(before + 1, editor.symbols.items[@backingInt(fixture.target_id)].reference_count);
}

test "hostile SymbolId 6029 preserves fallback addReference" {
    if (isSemanticEditPanicChild()) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try HoistedTempHostileFixture.init(arena.allocator());
    const node = try fixture.syntheticReference();
    const editor = try fixture.setEditorSymbol(node, null);
    try fixture.setTransformerSymbol(node, null);
    try bindPendingHoistedTempReference(
        &fixture.transformer,
        editor,
        node,
        fixture.target_id,
        fixture.function_scope,
        .{ .read = true },
    );
    const reference = try editor.referenceForNode(node) orelse return error.MissingFallbackReference;
    try std.testing.expectEqual(fixture.target_id, reference.symbol_id);
    try std.testing.expect(reference.flags.read);
    try std.testing.expect(!reference.flags.write);
}

test "hostile SymbolId 6029 writes assigned SID to transformer map" {
    if (isSemanticEditPanicChild()) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fixture = try HoistedTempHostileFixture.init(arena.allocator());
    const node = try fixture.syntheticReference();
    const editor = try fixture.setEditorSymbol(node, null);
    try fixture.setTransformerSymbol(node, null);
    try bindPendingHoistedTempReference(
        &fixture.transformer,
        editor,
        node,
        fixture.target_id,
        fixture.function_scope,
        .{ .read = true },
    );
    try std.testing.expectEqual(@as(?u32, @backingInt(fixture.target_id)), fixture.transformer.getSymbolIdAt(node));
    try std.testing.expectEqual(@as(?u32, @backingInt(fixture.target_id)), editor.symbol_ids.items[@backingInt(node)]);
}

test "hostile SymbolId 6029 fail closed on invalid existing reference" {
    if (isSemanticEditPanicChild()) return;
    try expectInvalidSemanticEditPanic("invalid-existing-scope", "InvalidScope");
}

test "generated body import provenance uses producer-owned nested scope before output walk" {
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, "function read(){return import('./dep.cjs')}");
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var entries = analyzer.node_scope_provenance.iterator();
    const entry = entries.next().?;
    const import_node = entry.key_ptr.*;
    const source_scope = entry.value_ptr.scope;
    var transformer = try Transformer.init(a, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.semantic_edit_enabled = true;
    const ret = try transformer.ast.addNode(.{ .tag = .return_statement, .span = .EMPTY, .data = .{ .unary = .{ .operand = import_node, .flags = 0 } } });
    const nested = try transformer.ast.addNode(.{ .tag = .block_statement, .span = .EMPTY, .data = .{ .list = try transformer.ast.addNodeList(&.{ret}) } });
    const nested_scope = try transformer.addGeneratedScope(source_scope, nested, .block);
    const body = try transformer.ast.addNode(.{ .tag = .block_statement, .span = .EMPTY, .data = .{ .list = try transformer.ast.addNodeList(&.{nested}) } });
    const callback = try @import("../es_helpers.zig").buildGeneratorWrapper(&transformer, body, .EMPTY);
    const callback_scope = try transformer.addGeneratedFunctionScope(source_scope, callback);
    try moveGeneratedFunctionBodyBindings(&transformer, source_scope, callback_scope, body);
    const editor = &transformer.semantic_editor.?;
    try std.testing.expectEqual(nested_scope, editor.node_scope_provenance.get(import_node).?.scope);
    try std.testing.expectEqual(callback_scope, editor.scopes.items[nested_scope.toIndex()].parent);
    try std.testing.expectEqual(import_node, editor.node_scope_provenance.get(import_node).?.source_node);
}

fn rejectPoisonedImportCreationScope(a: std.mem.Allocator, comptime use_checked: bool) !void {
    const Parser = @import("../../parser/parser.zig").Parser;
    const Analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
    var scanner = try Scanner.init(a, "function read(){return import('./dep.cjs')}");
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    try analyzer.analyze();
    var entries = analyzer.node_scope_provenance.iterator();
    const entry = entries.next().?;
    const root_scope: ScopeId = @fromBackingInt(@as(u32, 0));
    try std.testing.expect(entry.value_ptr.scope != root_scope);
    entry.value_ptr.scope = root_scope; // wrong, valid ScopeId
    var transformer = try Transformer.init(a, &parser.ast, .{});
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.semantic_edit_enabled = true;
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(transformer.ast.nodes.items.len - 1)));
    if (use_checked) {
        try bindOutputScopesAndReferencesChecked(&transformer, root, root_scope);
    } else try bindOutputScopesAndReferences(&transformer, root, root_scope);
}

test "hostile SymbolId 6029 checked API rejects import creation scope drift" {
    if (isSemanticEditPanicChild()) return;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidScope, rejectPoisonedImportCreationScope(arena.allocator(), true));
}

test "hostile SymbolId 6029 rejects import creation scope healing" {
    if (isSemanticEditPanicChild()) return;
    try expectInvalidSemanticEditPanic("invalid-import-creation-scope", "InvalidScope");
}
