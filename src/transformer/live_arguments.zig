//! A mutable source arguments binding must stay one cell across generated
//! ordinary functions. Native engine storage and the output cell have distinct
//! exact identities; copying only captured reads cannot preserve source writes.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const symbols = @import("../semantic/symbol.zig");
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const NodeIndex = ast_mod.NodeIndex;

pub const CaptureScopes = struct {
    lowered_arrows: std.AutoHashMapUnmanaged(u32, void) = .empty,
    extracted_owners: std.AutoHashMapUnmanaged(u32, void) = .empty,
    required_symbols: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.lowered_arrows.deinit(allocator);
        self.extracted_owners.deinit(allocator);
        self.required_symbols.deinit(allocator);
    }
};

/// Collect source owners whose generated ordinary functions can change the
/// lexical path to `arguments`. A plain function's own native `arguments`
/// reads need no synthetic live cell.
pub fn collectCaptureScopes(self: anytype, allocator: std.mem.Allocator, result: *CaptureScopes) std.mem.Allocator.Error!bool {
    const source = self.semantic_source_ast orelse return false;
    const owners = if (self.semantic_editor) |*editor| &editor.scope_owner_map else &self.scope_owner_map;
    const symbols_table = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const references = if (self.semantic_editor) |*editor| editor.references.items else self.references;
    var iter = owners.iterator();
    while (iter.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw >= self.parser_node_count or raw >= source.nodes.items.len) continue;
        if (entry.value_ptr.* >= scopes.len) return false;
        const node = source.nodes.items[raw];
        switch (node.tag) {
            .arrow_function_expression => try result.lowered_arrows.put(allocator, entry.value_ptr.*, {}),
            .function, .function_declaration, .function_expression, .method_definition => {
                const flags_index: usize = if (node.tag == .method_definition)
                    ast_mod.MethodExtra.flags
                else
                    ast_mod.FunctionExtra.flags;
                if (node.data.extra > source.extra_data.items.len or
                    source.extra_data.items.len - node.data.extra <= flags_index) return false;
                const flags = switch (node.tag) {
                    .function, .function_declaration, .function_expression => source.readExtra(node.data.extra, ast_mod.FunctionExtra.flags),
                    .method_definition => ast_mod.methodFlagsToFunctionFlags(source.readExtra(node.data.extra, ast_mod.MethodExtra.flags)),
                    else => unreachable,
                };
                const is_async = flags & ast_mod.FunctionFlags.is_async != 0;
                const is_generator = flags & ast_mod.FunctionFlags.is_generator != 0;
                const unsupported = self.options.unsupported;
                // Other transforms can extract generator loop bodies even
                // when the target keeps native generators. A generated
                // generator then becomes the nearest ordinary owner of
                // source `arguments`, so preserve the live cell for every
                // generator owner while lexical arguments are being lowered.
                const may_be_extracted = is_generator or (is_async and unsupported.async_await);
                if (may_be_extracted) try result.extracted_owners.put(allocator, entry.value_ptr.*, {});
            },
            else => {},
        }
    }

    for (references) |reference| {
        if (reference.flags.declare) continue;
        const id = @backingInt(reference.symbol_id);
        if (id >= symbols_table.len) return false;
        const symbol = symbols_table[id];
        if (symbol.synthetic_kind != .implicit_arguments or result.required_symbols.contains(id)) continue;
        if (symbol.kind != .parameter or symbol.scope_id.isNone() or symbol.scope_id.toIndex() >= scopes.len) {
            try result.required_symbols.put(allocator, id, {});
            continue;
        }

        var cursor = reference.scope_id;
        var reached_owner = false;
        var requires_cell = false;
        var hops: usize = 0;
        while (!cursor.isNone() and hops <= scopes.len) : (hops += 1) {
            const raw_scope = cursor.toIndex();
            if (raw_scope >= scopes.len) {
                requires_cell = true;
                break;
            }
            if (result.lowered_arrows.contains(raw_scope)) {
                requires_cell = true;
                break;
            }
            if (cursor == symbol.scope_id) {
                reached_owner = true;
                requires_cell = result.extracted_owners.contains(raw_scope);
                break;
            }
            cursor = scopes[raw_scope].parent;
        }
        if (!reached_owner and !requires_cell) requires_cell = true;
        if (requires_cell) try result.required_symbols.put(allocator, id, {});
    }
    return true;
}

pub fn requiresLiveCell(id: u32, capture_scopes: *const CaptureScopes) bool {
    return capture_scopes.required_symbols.contains(id);
}

pub const Cell = struct {
    scope: ScopeId,
    engine_id: symbols.SymbolId,
    name: []const u8,
    source_has_binding: bool,
    declaration: NodeIndex = .none,
};

/// A split native parameter environment owns arguments above the body and
/// cannot use a body cell. The actual ordinary owner supplies this distinction.
pub fn unsplitOwner(self: anytype, scope: ScopeId) ?NodeIndex {
    var owner: ?NodeIndex = null;
    var iter = self.scope_owner_map.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(scope)) continue;
        const raw = entry.key_ptr.*;
        if (raw >= self.parser_node_count or raw >= self.ast.nodes.items.len) continue;
        switch (self.ast.nodes.items[raw].tag) {
            .function_declaration, .function_expression, .function => {},
            .ts_module_declaration, .ts_enum_declaration => {
                // This source node is an actual ordinary IIFE creator. Its
                // exact typed parameter must belong to this same function
                // scope; source member proxies are not native arguments.
                const table = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                var parameters: usize = 0;
                for (table) |symbol| {
                    if (symbol.scope_id == scope and symbol.synthetic_kind == (if (self.ast.nodes.items[raw].tag == .ts_enum_declaration) symbols.SyntheticKind.enum_iife_parameter else symbols.SyntheticKind.namespace_iife_parameter)) {
                        if (symbol.kind != .parameter) @panic("namespace IIFE parameter has no native parameter role");
                        parameters += 1;
                    }
                }
                if (parameters != 1) @panic("namespace arguments owner has no unique actual IIFE parameter");
            },
            else => continue,
        }
        if (owner != null) std.debug.panic("arguments source scope has multiple ordinary owners", .{});
        owner = @fromBackingInt(raw);
    }
    return owner;
}

pub fn isArrowLocal(self: anytype, scope: ScopeId) bool {
    var owners = self.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (entry.value_ptr.* == @backingInt(scope) and raw < self.parser_node_count and
            raw < self.ast.nodes.items.len and self.ast.nodes.items[raw].tag == .arrow_function_expression) return true;
    }
    return false;
}

pub fn prepare(self: anytype, source_id: u32, name: []const u8, owner: NodeIndex) std.mem.Allocator.Error!void {
    try @import("transformer/semantic_edit.zig").renameParameterEnvironmentBinding(self, source_id, name);
    const editor = &self.semantic_editor.?;
    const scope = editor.symbols.items[source_id].scope_id;
    const source_has_binding = editor.symbols.items[source_id].kind == .variable_var;
    if (editor.scope_maps.items[scope.toIndex()].contains("arguments"))
        std.debug.panic("live arguments cell did not release its native engine name", .{});
    const engine_name = try self.ast.addString("arguments");
    const engine_id: symbols.SymbolId = @fromBackingInt(@as(u32, @intCast(editor.symbols.items.len)));
    try editor.symbols.append(self.allocator, .{
        .name = engine_name,
        .scope_id = scope,
        .origin_scope = scope,
        .kind = .parameter,
        .decl_flags = symbols.SymbolKind.parameter.declFlags(),
        .declaration_span = self.ast.getNode(owner).span,
        .synthetic_kind = .implicit_arguments,
        .synthetic_name = "arguments",
    });
    editor.scopes.items[scope.toIndex()].symbol_count += 1;
    try editor.scope_maps.items[scope.toIndex()].put(self.allocator, "arguments", @backingInt(engine_id));
    editor.ensureDeclarationAtNode(engine_id, scope, .none) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => std.debug.panic("native arguments engine declaration lost its exact scope: {s}", .{@errorName(err)}),
    };
    try @import("native_arguments.zig").record(self, engine_id, scope);
    const cell = &editor.symbols.items[source_id];
    cell.kind = .variable_var;
    cell.decl_flags = symbols.SymbolKind.variable_var.declFlags();
    // The source-ID rename table already owns this cell's output spelling.
    // A second late capture-name selection would conflict with that choice.
    cell.synthetic_kind = null;
    cell.output_name_hint = "";
    try self.live_arguments_cells.put(self.allocator, source_id, .{ .scope = scope, .engine_id = engine_id, .name = name, .source_has_binding = source_has_binding });
}

pub fn noteReference(self: anytype, source: NodeIndex) void {
    const id = self.getSymbolIdAt(source) orelse return;
    const cell = self.live_arguments_cells.get(id) orelse return;
    if (cell.scope == self.capture_scope) self.needs_arguments_var = true;
}

const OwnedCell = struct { id: symbols.SymbolId, cell: *Cell };

pub fn ownerCell(self: anytype) ?OwnedCell {
    var found: ?OwnedCell = null;
    var iter = self.live_arguments_cells.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.scope != self.capture_scope) continue;
        if (found != null) std.debug.panic("one ordinary owner has multiple live arguments cells", .{});
        found = .{ .id = @fromBackingInt(entry.key_ptr.*), .cell = entry.value_ptr };
    }
    return found;
}

pub fn makeDeclaration(self: anytype, span: @import("../lexer/token.zig").Span) std.mem.Allocator.Error!?NodeIndex {
    const plan = ownerCell(self) orelse return null;
    if (!plan.cell.declaration.isNone()) std.debug.panic("live arguments cell emitted more than once", .{});
    const init = try self.makeSyntheticRefForSymbol(plan.cell.engine_id, plan.cell.scope, .{ .read = true });
    const declaration = try self.buildVarDecl(plan.cell.name, init, span);
    const decl = self.ast.getNode(declaration);
    const list_start = self.readU32(decl.data.extra, 1);
    const item: NodeIndex = @fromBackingInt(self.ast.extra_data.items[list_start]);
    const binding = self.readNodeIdx(self.ast.getNode(item).data.extra, 0);
    const editor = &self.semantic_editor.?;
    if (editor.symbols.items[@backingInt(plan.id)].scope_id != plan.cell.scope)
        std.debug.panic("live arguments storage moved away from its ordinary owner", .{});
    if (plan.cell.source_has_binding) {
        editor.attachVarRedeclaration(binding, plan.id, plan.cell.scope) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            std.debug.panic("live arguments redeclaration lost exact identity: {s}", .{@errorName(err)});
        };
        // A same-name var redeclaration is a second declaration anchor. Do
        // not reanchor the original initializer through the shared interned
        // name span when synchronizing the transformer's ID mirror.
        const raw = @backingInt(binding);
        if (self.symbol_ids.items.len <= raw)
            try self.symbol_ids.appendNTimes(self.allocator, null, raw + 1 - self.symbol_ids.items.len);
        self.symbol_ids.items[raw] = @backingInt(plan.id);
    } else {
        try self.rebindOutputBinding(binding, @backingInt(plan.id));
    }
    editor.ensureDeclarationAtNode(plan.id, plan.cell.scope, binding) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        std.debug.panic("live arguments declaration lost exact identity: {s}", .{@errorName(err)});
    };
    plan.cell.declaration = declaration;
    return declaration;
}
