//! Bounded native runtime syntax preserves source identities despite container copies.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const symbols = @import("../semantic/symbol.zig");
const scope = @import("../semantic/scope.zig");
const module = @import("../bundler/module.zig");
const Options = @import("transformer.zig").TransformOptions;
const N = ast.NodeIndex;
pub const Owner = struct { node: N, scope: u32 };
pub const Metadata = struct {
    typescript: bool,
    jsx: bool,
    jsx_key_after_spread: bool,
    decorators: bool,
    flow_enum: bool,
    fn capture(tree: *const ast.Ast) Metadata {
        return .{ .typescript = tree.is_typescript, .jsx = tree.has_jsx, .jsx_key_after_spread = tree.has_jsx_key_after_spread, .decorators = tree.has_decorator, .flow_enum = tree.has_flow_enum_declaration };
    }
};
pub const ModuleFrame = struct { pointer: *const module.Module, index: @import("../bundler/types.zig").ModuleIndex };
pub const Source = struct {
    ast: *const ast.Ast,
    output: ?*const ast.Ast = null,
    owner: module.SemanticOwnerToken = .unassigned,
    root: N,
    metadata: Metadata,
    module_frame: ?ModuleFrame = null,
    node_mask: []const bool,
    reference_indices: []const ?usize,
    owner_scopes: []const ?u32,
    nodes: []const u32,
    references: []const symbols.Reference,
    symbols: []const symbols.Symbol,
    scopes: []const scope.Scope,
    owners: []const Owner,
    pub fn deinit(self: Source, a: std.mem.Allocator) void {
        a.free(self.node_mask);
        a.free(self.reference_indices);
        a.free(self.owner_scopes);
        a.free(self.nodes);
        a.free(self.references);
        a.free(self.symbols);
        a.free(self.scopes);
        a.free(self.owners);
    }
};
pub const Copy = struct {
    source: N,
    output: N,
    source_ast: *const ast.Ast,
    output_ast: *const ast.Ast,
    owner: module.SemanticOwnerToken,
    source_function: N = .none,
    function: N = .none,
    function_scope: scope.ScopeId = .none,
};
fn allowed(tag: ast.Node.Tag) bool {
    return switch (tag) {
        .program,
        .function_declaration,
        .function_body,
        .block_statement,
        .formal_parameters,
        .binding_identifier,
        .identifier_reference,
        .assignment_target_identifier,
        .static_member_expression,
        .computed_member_expression,
        .logical_expression,
        .binary_expression,
        .assignment_expression,
        .update_expression,
        .variable_declaration,
        .variable_declarator,
        .object_expression,
        .object_property,
        .array_expression,
        .expression_statement,
        .return_statement,
        .call_expression,
        .numeric_literal,
        .string_literal,
        .null_literal,
        .boolean_literal,
        .empty_statement,
        .parenthesized_expression,
        => true,
        else => false,
    };
}
/// This deliberately excludes imports; source graph edges need their own certificate.
pub fn sourcePlan(a: std.mem.Allocator, tree: *const ast.Ast, sem: *const module.ModuleSemanticData, opts: Options) !?Source {
    if (tree.nodes.items.len == 0 or tree.is_typescript or tree.has_jsx or tree.has_decorator or
        opts.unsupported.optional_chaining or opts.unsupported.nullish_coalescing or
        opts.minify_syntax or !opts.strip_types or opts.react_refresh or opts.emotion or opts.styled_components or
        opts.define.len != 0 or opts.drop_console or opts.drop_debugger or opts.drop_labels.len != 0 or
        opts.module_specifier_map.len != 0 or opts.unsupportedGraphPrePassFeatureUsed(tree)) return null;
    for (sem.scopes) |s| if (s.blocksMangling()) return null;
    const root: N = tree.transformed_root orelse @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1)));
    if (root.isNone() or tree.getNode(root).tag != .program) return null;
    const nodes = try walk.collectReachableNodeIndicesFrom(a, tree, root);
    var transferred = false;
    defer if (!transferred) a.free(nodes);
    var native = false;
    for (nodes) |raw| {
        if (raw >= tree.nodes.items.len) return null;
        const node = tree.nodes.items[raw];
        if (!allowed(node.tag)) return null;
        if (node.tag == .function_declaration and tree.readExtra(node.data.extra, ast.FunctionExtra.flags) != 0) return null;
        if (node.tag == .call_expression and (tree.readExtra(node.data.extra, 3) & ast.CallFlags.optional_chain) != 0) return null;
        if (node.tag == .static_member_expression or node.tag == .computed_member_expression) {
            if ((tree.readExtra(node.data.extra, 2) & ast.MemberFlags.optional_chain) != 0) native = true;
        }
        if (node.tag == .logical_expression and node.data.binary.flags == @backingInt(@import("../lexer/token.zig").Kind.question2)) native = true;
    }
    if (!native) return null;
    const node_mask = try a.alloc(bool, tree.nodes.items.len);
    defer if (!transferred) a.free(node_mask);
    @memset(node_mask, false);
    for (nodes) |raw| node_mask[raw] = true;
    const reference_indices = try a.alloc(?usize, tree.nodes.items.len);
    defer if (!transferred) a.free(reference_indices);
    @memset(reference_indices, null);
    for (sem.references, 0..) |ref, i| {
        if (ref.flags.declare or ref.node_index.isNone()) continue;
        const raw = @backingInt(ref.node_index);
        if (raw >= reference_indices.len or reference_indices[raw] != null) return null;
        reference_indices[raw] = i;
    }
    const owner_scopes = try a.alloc(?u32, tree.nodes.items.len);
    defer if (!transferred) a.free(owner_scopes);
    @memset(owner_scopes, null);
    var owners: std.ArrayListUnmanaged(Owner) = .empty;
    errdefer owners.deinit(a);
    var it = sem.scope_owner_map.iterator();
    while (it.next()) |entry| {
        const raw = entry.key_ptr.*;
        if (raw < node_mask.len and node_mask[raw]) {
            owner_scopes[raw] = entry.value_ptr.*;
            try owners.append(a, .{ .node = @fromBackingInt(raw), .scope = entry.value_ptr.* });
        }
    }
    const refs = try a.dupe(symbols.Reference, sem.references);
    errdefer a.free(refs);
    const syms = try a.dupe(symbols.Symbol, sem.symbols.items);
    errdefer a.free(syms);
    const scopes = try a.dupe(scope.Scope, sem.scopes);
    errdefer a.free(scopes);
    const owned = try owners.toOwnedSlice(a);
    transferred = true;
    return .{ .ast = tree, .root = root, .metadata = Metadata.capture(tree), .node_mask = node_mask, .reference_indices = reference_indices, .owner_scopes = owner_scopes, .nodes = nodes, .references = refs, .symbols = syms, .scopes = scopes, .owners = owned };
}
/// Capture the actual original module graph, rather than inferring it from AST tags.
pub fn forModule(a: std.mem.Allocator, m: *const module.Module, opts: Options) !?Source {
    if (m.ast == null or m.semantic == null or m.import_records.len != 0 or m.import_bindings.len != 0) return null;
    var source = (try sourcePlan(a, &m.ast.?, &m.semantic.?, opts)) orelse return null;
    source.module_frame = .{ .pointer = m, .index = m.index };
    return source;
}
fn moduleValid(source: Source) bool {
    const frame = source.module_frame orelse return false;
    const m = frame.pointer;
    return m.index == frame.index and m.ast != null and m.semantic != null and
        &m.ast.? == source.ast and m.semantic.?.owner_token == source.owner and
        m.import_records.len == 0 and m.import_bindings.len == 0;
}
fn appendCopy(self: anytype, copy: Copy) !void {
    const slot = try self.native_noop_copy_index.getOrPut(self.allocator, @backingInt(copy.source));
    if (slot.found_existing) {
        self.native_noop_invalid = true;
        return;
    }
    errdefer _ = self.native_noop_copy_index.remove(@backingInt(copy.source));
    slot.value_ptr.* = self.native_noop_copies.items.len;
    try self.native_noop_copies.append(self.allocator, copy);
}
pub fn record(self: anytype, input: N, output: N) !void {
    const source = self.native_noop_source orelse return;
    if (input.isNone() or @backingInt(input) >= source.node_mask.len or !source.node_mask[@backingInt(input)]) return;
    try appendCopy(self, .{ .source = input, .output = output, .source_ast = source.ast, .output_ast = self.ast, .owner = source.owner });
}
fn equal(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.meta.eql(x, y)) return false;
    return true;
}
fn mapped(self: anytype, source: N) ?N {
    const index = self.native_noop_copy_index.get(@backingInt(source)) orelse return null;
    if (index >= self.native_noop_copies.items.len or self.native_noop_copies.items[index].source != source) return null;
    return self.native_noop_copies.items[index].output;
}
fn payloadSame(a: *const ast.Ast, x: ast.Node, b: *const ast.Ast, y: ast.Node) bool {
    if (x.tag != y.tag or !std.meta.eql(x.span, y.span)) return false;
    switch (ast.Node.Tag.dataKind(x.tag)) {
        .leaf => return std.mem.eql(u8, std.mem.asBytes(&x.data)[0..ast.Node.Tag.dataWidth(x.tag)], std.mem.asBytes(&y.data)[0..ast.Node.Tag.dataWidth(y.tag)]),
        .unary => return x.data.unary.flags == y.data.unary.flags,
        .binary => return x.data.binary.flags == y.data.binary.flags,
        .ternary => return true,
        .list => return x.data.list.len == y.data.list.len,
        .extra => {
            const len = ast.Node.Tag.runtimeExtraWords(x.tag) orelse return false;
            if (!a.hasExtra(x.data.extra, len - 1) or !b.hasExtra(y.data.extra, len - 1)) return false;
            for (0..len) |i| {
                if (std.mem.indexOfScalar(u8, ast.Node.Tag.extraChildOffsets(x.tag), @intCast(i)) != null) continue;
                var list_start = false;
                for (ast.Node.Tag.extraListOffsets(x.tag)) |offset| if (offset[0] == i) {
                    list_start = true;
                };
                if (!list_start and a.extra_data.items[x.data.extra + i] != b.extra_data.items[y.data.extra + i]) return false;
            }
            return true;
        },
    }
}
const Pair = struct { input: N, output: N };
fn shape(self: anytype, source: Source, root: N) !bool {
    if (self.native_noop_invalid or self.native_noop_copies.items.len != self.native_noop_copy_index.count()) return false;
    for (self.native_noop_copies.items, 0..) |copy, index| {
        if (self.native_noop_copy_index.get(@backingInt(copy.source)) != index or copy.source.isNone() or copy.output.isNone() or
            @backingInt(copy.source) >= source.ast.nodes.items.len or @backingInt(copy.output) >= self.ast.nodes.items.len) return false;
        if (copy.source_ast != source.ast or copy.output_ast != self.ast or copy.owner != source.owner) return false;
        if (!copy.function.isNone()) {
            if (@backingInt(copy.function) >= self.ast.nodes.items.len) return false;
            const function = self.ast.getNode(copy.function);
            if (function.tag != .function_declaration or self.ast.readExtraNode(function.data.extra, ast.FunctionExtra.params) != copy.output) return false;
            if (self.outputOwnedScope(copy.function) != copy.function_scope) return false;
            const original_fn = copy.source_function;
            if (original_fn.isNone() or @backingInt(original_fn) >= source.ast.nodes.items.len or
                source.ast.getNode(original_fn).tag != .function_declaration or mapped(self, original_fn) != copy.function) return false;
            if (source.ast.readExtraNode(source.ast.getNode(original_fn).data.extra, ast.FunctionExtra.params) != copy.source) return false;
        }
    }
    if (mapped(self, source.root) != root) return false;
    var todo: std.ArrayListUnmanaged(Pair) = .empty;
    defer todo.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer seen.deinit(self.allocator);
    try todo.append(self.allocator, .{ .input = source.root, .output = root });
    while (todo.pop()) |pair| {
        if (pair.input.isNone() or pair.output.isNone()) {
            if (pair.input != pair.output) return false;
            continue;
        }
        if (@backingInt(pair.input) >= source.ast.nodes.items.len or @backingInt(pair.output) >= self.ast.nodes.items.len) return false;
        if (seen.get(@backingInt(pair.input))) |old| {
            if (old != @backingInt(pair.output)) return false;
            continue;
        }
        try seen.put(self.allocator, @backingInt(pair.input), @backingInt(pair.output));
        if (mapped(self, pair.input)) |known| {
            if (known != pair.output) return false;
        } else if (pair.input != pair.output) return false;
        const input = source.ast.getNode(pair.input);
        const output = self.ast.getNode(pair.output);
        if (!payloadSame(source.ast, input, self.ast, output)) return false;
        var left = walk.children(source.ast, input);
        var right = walk.children(self.ast, output);
        while (left.next()) |child| {
            const actual = right.next() orelse return false;
            try todo.append(self.allocator, .{ .input = child, .output = actual });
        }
        if (right.next() != null) return false;
    }
    if (seen.count() != source.nodes.len) return false;
    // No fabricated or unreachable copy record can acquire authority.
    for (self.native_noop_copies.items) |copy| if (seen.get(@backingInt(copy.source)) != @backingInt(copy.output)) return false;
    return true;
}
/// Called before the generic binder. It only observes the current creator graph.
pub fn beforeBinder(self: anytype, root: N) !bool {
    const source = self.native_noop_source orelse return false;
    if (source.output != self.ast or source.ast == self.ast or source.ast != self.semantic_source_ast or source.owner == .unassigned or !moduleValid(source) or
        !std.meta.eql(source.metadata, Metadata.capture(source.ast)) or !std.meta.eql(source.metadata, Metadata.capture(self.ast))) return false;
    const refs = if (self.semantic_editor) |*e| e.references.items else self.references;
    const syms = if (self.semantic_editor) |*e| e.symbols.items else self.symbols;
    const scopes = if (self.semantic_editor) |*e| e.scopes.items else self.scopes;
    if (!equal(symbols.Reference, source.references, refs) or !equal(symbols.Symbol, source.symbols, syms) or !equal(scope.Scope, source.scopes, scopes)) return false;
    for (source.references) |ref| {
        const node = if (ref.flags.declare) ref.declaration_node_index else ref.node_index;
        if (!node.isNone() and (@backingInt(node) >= self.symbol_ids.items.len or self.symbol_ids.items[@backingInt(node)] != @backingInt(ref.symbol_id))) return false;
    }
    for (source.owners) |owner| {
        const node = mapped(self, owner.node) orelse owner.node;
        const actual = self.outputOwnedScope(node) orelse return false;
        if (@backingInt(actual) != owner.scope) return false;
    }
    if (!try shape(self, source, root)) return false;
    // Build a read-only owner view only from the recorded source owners and
    // their actual visit copies, never by discovering a new ScopeId.
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer owners.deinit(self.allocator);
    for (source.owners) |owner| try owners.put(self.allocator, @backingInt(mapped(self, owner.node) orelse owner.node), owner.scope);
    const view = .{ .symbols = .{ .items = syms }, .scopes = scopes, .references = refs, .symbol_ids = self.symbol_ids.items, .scope_owner_map = owners, .class_self_symbol_map = self.class_self_symbol_map };
    const projected = (try @import("../bundler/statement_owner_projection.zig").project(self.allocator, self.ast, root, &view)) orelse return false;
    defer self.allocator.free(projected);
    return equal(symbols.Reference, source.references, projected);
}
pub fn complete(self: anytype, sem: *const module.ModuleSemanticData, root: N) !bool {
    const source = self.native_noop_source orelse return false;
    if (!self.native_noop_before_binder or self.native_noop_before_binder_root != root or sem.owner_token != source.owner or source.output != self.ast or
        source.ast != self.semantic_source_ast or !moduleValid(source) or
        !std.meta.eql(source.metadata, Metadata.capture(source.ast)) or !std.meta.eql(source.metadata, Metadata.capture(self.ast))) return false;
    if (!equal(symbols.Reference, source.references, sem.references) or !equal(symbols.Symbol, source.symbols, sem.symbols.items) or !equal(scope.Scope, source.scopes, sem.scopes)) return false;
    for (source.owners) |owner| {
        const node = mapped(self, owner.node) orelse owner.node;
        if (sem.scope_owner_map.get(@backingInt(node)) != owner.scope) return false;
    }
    if (sem.scope_owner_map.count() != source.owners.len) return false;
    return shape(self, source, root);
}

/// Preserve already-proven source coordinates at the existing reference consumer.
/// No current-row coordinate is ever adopted as an expectation here.
pub fn agree(self: anytype, node: N, id: u32, use_scope: scope.ScopeId, flags: symbols.ReferenceFlags, other: ?@import("transformer.zig").StatementPublication) @import("../semantic/editor.zig").Error!?@import("transformer.zig").StatementPublication {
    const source = self.native_noop_source orelse return other;
    if (!self.native_noop_before_binder) return other;
    if (source.output != self.ast or source.owner == .unassigned) return error.InvalidNode;
    const sealed = self.native_noop_before_binder_root orelse return error.InvalidNode;
    if (mapped(self, source.root) != sealed) return error.InvalidNode;
    if (@backingInt(node) >= source.reference_indices.len) return other;
    const index = source.reference_indices[@backingInt(node)] orelse return other;
    if (index >= source.references.len) return error.InvalidNode;
    const ref = source.references[index];
    if (ref.flags.declare or ref.node_index != node) return error.InvalidNode;
    if (@backingInt(ref.symbol_id) != id or ref.scope_id != use_scope or !std.meta.eql(ref.flags, flags)) return error.InvalidNode;
    if (mapped(self, node) != node) return error.InvalidNode;
    const copy_index = self.native_noop_copy_index.get(@backingInt(node)) orelse return error.InvalidNode;
    if (copy_index >= self.native_noop_copies.items.len) return error.InvalidNode;
    const copy = self.native_noop_copies.items[copy_index];
    if (copy.source != node or copy.source_ast != source.ast or copy.output_ast != self.ast or copy.owner != source.owner or copy.output != node) return error.InvalidNode;
    const result: @import("transformer.zig").StatementPublication = .{ .symbol_id = ref.symbol_id, .scope = ref.scope_id, .stmt = ref.stmt_idx, .scope_stmt = ref.scope_stmt_idx };
    if (other) |prior| if (!std.meta.eql(prior, result)) return error.InvalidNode;
    return result;
}

/// The function visitor owns this formal wrapper, including empty native lists.
pub fn recordFunctionFormals(self: anytype, original: N, function: N, old_params: N, new_params: N) !void {
    const source = self.native_noop_source orelse return;
    if (original.isNone() or @backingInt(original) >= source.node_mask.len or !source.node_mask[@backingInt(original)]) return;
    const source_fn = source.ast.getNode(original);
    if (source_fn.tag != .function_declaration) {
        self.native_noop_invalid = true;
        return;
    }
    const source_params = source.ast.readExtraNode(source_fn.data.extra, ast.FunctionExtra.params);
    const function_scope: scope.ScopeId = @fromBackingInt(source.owner_scopes[@backingInt(original)] orelse {
        self.native_noop_invalid = true;
        return;
    });
    const actual_fn = self.ast.getNode(function);
    const refs = if (self.semantic_editor) |*e| e.references.items else self.references;
    const syms = if (self.semantic_editor) |*e| e.symbols.items else self.symbols;
    const scopes = if (self.semantic_editor) |*e| e.scopes.items else self.scopes;
    if (old_params != source_params or actual_fn.tag != source_fn.tag or
        self.ast.readExtraNode(actual_fn.data.extra, ast.FunctionExtra.params) != new_params or
        function_scope != self.current_scope or function_scope.toIndex() >= source.scopes.len or source.scopes[function_scope.toIndex()].kind != .function or
        self.ast.getNode(old_params).tag != .formal_parameters or self.ast.getNode(new_params).tag != .formal_parameters or
        !payloadSame(self.ast, self.ast.getNode(old_params), self.ast, self.ast.getNode(new_params)) or
        !equal(symbols.Reference, source.references, refs) or !equal(symbols.Symbol, source.symbols, syms) or !equal(scope.Scope, source.scopes, scopes))
    {
        self.native_noop_invalid = true;
        return;
    }
    var expected = walk.children(self.ast, self.ast.getNode(old_params));
    var actual = walk.children(self.ast, self.ast.getNode(new_params));
    while (expected.next()) |node| {
        if (actual.next() != node) {
            self.native_noop_invalid = true;
            return;
        }
    }
    if (actual.next() != null) {
        self.native_noop_invalid = true;
        return;
    }
    try appendCopy(self, .{ .source = source_params, .output = new_params, .source_ast = source.ast, .output_ast = self.ast, .owner = source.owner, .source_function = original, .function = function, .function_scope = function_scope });
}
