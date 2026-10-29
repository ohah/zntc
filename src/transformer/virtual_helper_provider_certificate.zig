//! Read-only preservation of a catalog constructor's parsed semantic graph.
//! Node containers may be copied; bindings, scopes and native engine roles may
//! not be rediscovered or repaired while establishing this certificate.
const std = @import("std");
const ast = @import("../parser/ast.zig");
const walk = @import("../parser/ast_walk.zig");
const refs_walk = @import("../semantic/reference_walk.zig");
const sym = @import("../semantic/symbol.zig");
const scopes_mod = @import("../semantic/scope.zig");
const module = @import("../bundler/module.zig");
const origin_mod = @import("../runtime_helper_source_origin.zig");
const helpers = @import("../runtime_helper_modules.zig");
const NodeIndex = ast.NodeIndex;
pub const Error = std.mem.Allocator.Error || error{InvalidProviderPreservation};
const Owner = struct { node: u32, scope: u32 };
const External = struct { node: u32, owner: Owner };
const Export = struct { name: []const u8, span: @import("../lexer/token.zig").Span };
pub const Source = struct {
    source_domain: *const ast.Ast,
    syntax: ast.Ast,
    output_domain: *const ast.Ast,
    origin: origin_mod.Origin,
    input_source: []const u8,
    input_source_hash: u64,
    owner: module.SemanticOwnerToken,
    root: NodeIndex,
    nodes: []const u32,
    node_set: std.AutoHashMapUnmanaged(u32, void),
    leaves: []const NodeIndex,
    externals: []const External,
    symbols: []const sym.Symbol,
    scopes: []const scopes_mod.Scope,
    references: []const sym.Reference,
    owners: []const Owner,
    exports: []const Export,
};

fn invalid() Error {
    return error.InvalidProviderPreservation;
}

// Only called for the closed super-get/set catalogs. Both walks consume actual
// scope owners; copied syntax never selects a new scope from a name.
fn nearestOwner(a: std.mem.Allocator, tree: *const ast.Ast, root: NodeIndex, target: u32, scopes: []const scopes_mod.Scope, owners: *const std.AutoHashMapUnmanaged(u32, u32)) Error!?Owner {
    const Work = struct { node: NodeIndex, owner: ?Owner };
    var stack: std.ArrayList(Work) = .empty;
    var seen: std.AutoHashMapUnmanaged(u32, ?Owner) = .empty;
    try stack.append(a, .{ .node = root, .owner = null });
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const raw = @backingInt(work.node);
        if (raw >= tree.nodes.items.len) return null;
        var current = work.owner;
        if (owners.get(raw)) |scope| {
            if (scope >= scopes.len) return null;
            const kind = scopes[scope].kind;
            const valid = switch (tree.nodes.items[raw].tag) {
                .program => kind == .module,
                .function_expression => kind == .function,
                .block_statement, .while_statement => kind == .block,
                else => false,
            };
            if (!valid) return null;
            if (work.owner) |parent| {
                if (parent.scope != scope and @backingInt(scopes[scope].parent) != parent.scope) return null;
            } else if (!scopes[scope].parent.isNone()) return null;
            current = .{ .node = raw, .scope = scope };
        }
        const prior = try seen.getOrPut(a, raw);
        if (prior.found_existing) {
            if (!std.meta.eql(prior.value_ptr.*, current)) return null;
            continue;
        }
        prior.value_ptr.* = current;
        if (raw == target) return current;
        var children = walk.children(tree, tree.nodes.items[raw]);
        while (children.next()) |child| try stack.append(a, .{ .node = child, .owner = current });
    }
    return null;
}

const ExternalRole = enum(u1) { object, type_error };
fn expectedExternalCounts(catalog: origin_mod.Catalog) [2]usize {
    return switch (catalog) {
        .super_get => .{ 2, 0 },
        .super_set => .{ 2, 1 },
        else => .{ 0, 0 },
    };
}
// The winning sealed catalog and actual runtime edge select this source role.
// Spelling is its invariant, never a way to recover a SymbolId or ScopeId.
fn externalRole(catalog: origin_mod.Catalog, tree: *const ast.Ast, leaves: []const NodeIndex, node: NodeIndex) ?ExternalRole {
    if (node.isNone() or @backingInt(node) >= tree.nodes.items.len or
        std.mem.indexOfScalar(NodeIndex, leaves, node) == null or tree.getNode(node).tag != .identifier_reference) return null;
    const text = tree.getText(tree.getNode(node).data.string_ref);
    if ((catalog == .super_get or catalog == .super_set) and std.mem.eql(u8, text, "Object")) return .object;
    if (catalog == .super_set and std.mem.eql(u8, text, "TypeError")) return .type_error;
    return null;
}

fn eligible(tree: *const ast.Ast, nodes: []const u32, options: @import("transformer.zig").TransformOptions, catalog: origin_mod.Catalog) bool {
    for (nodes) |raw| {
        const node = tree.nodes.items[raw];
        switch (node.tag) {
            .program,
            .variable_declaration,
            .variable_declarator,
            .function_expression,
            .function_declaration,
            .function,
            .formal_parameters,
            .block_statement,
            .return_statement,
            .expression_statement,
            .if_statement,
            .conditional_expression,
            .sequence_expression,
            .identifier_reference,
            .binding_identifier,
            .assignment_target_identifier,
            .assignment_expression,
            .binary_expression,
            .logical_expression,
            .static_member_expression,
            .computed_member_expression,
            .call_expression,
            .parenthesized_expression,
            .object_expression,
            .object_property,
            .array_expression,
            .unary_expression,
            .update_expression,
            .numeric_literal,
            .string_literal,
            .boolean_literal,
            .null_literal,
            .this_expression,
            .empty_statement,
            .export_named_declaration,
            .export_specifier,
            => {},
            .while_statement => if (catalog != .super_get and catalog != .super_set) return false,
            .throw_statement, .new_expression => if (catalog != .super_set) return false,
            .regexp_literal => if (!std.mem.eql(u8, tree.getText(node.data.string_ref), "/./")) return false,
            else => return false,
        }
        const Token = @import("../lexer/token.zig").Kind;
        switch (node.tag) {
            .variable_declaration => if (tree.variableDeclarationKind(node).isLexical() or tree.variableDeclarationKind(node).isUsing()) return false,
            .binary_expression => if (options.unsupported.exponentiation and node.data.binary.flags == @backingInt(Token.star2)) return false,
            .logical_expression => if (options.unsupported.nullish_coalescing and node.data.binary.flags == @backingInt(Token.question2)) return false,
            .assignment_expression => {
                const flags = node.data.binary.flags;
                if (options.unsupported.exponentiation and flags == @backingInt(Token.star2_eq)) return false;
                if (options.unsupported.logical_assignment and (flags == @backingInt(Token.amp2_eq) or flags == @backingInt(Token.pipe2_eq) or flags == @backingInt(Token.question2_eq))) return false;
            },
            .object_property => if (options.unsupported.object_extensions and node.data.binary.right.isNone()) return false,
            .static_member_expression, .computed_member_expression => if (tree.readExtra(node.data.extra, 2) & ast.MemberFlags.optional_chain != 0) return false,
            .call_expression, .new_expression => {
                if (!tree.hasExtra(node.data.extra, 4) or
                    tree.readExtra(node.data.extra, 3) & (ast.CallFlags.optional_chain | ast.CallFlags.callee_optional_chain) != 0) return false;
            },
            else => {},
        }
        if ((node.tag == .function_expression or node.tag == .function_declaration or node.tag == .function) and tree.readExtra(node.data.extra, ast.FunctionExtra.flags) != 0) return false;
    }
    return true;
}

/// Record only the exact pair just installed by tryDiskLoadHit. The decoder
/// result's stack object is used to prove backing identity, never retained.
pub fn recordInstalledDiskSource(current: *module.Module, restored: *const @import("../bundler/module_codec.zig").DeserializedModule, options: helpers.SourceOptions) bool {
    if (current.runtime_helper_cache_source != null) return false;
    const loaded = current.runtime_helper_source orelse return false;
    const arena = current.parse_arena orelse return false;
    const tree = if (current.ast) |*value| value else return false;
    const semantic = if (current.semantic) |*value| value else return false;
    if (!helpers.matchesConstructedSource(loaded, options, current.source) or
        !std.meta.eql(tree.*, restored.ast) or !std.meta.eql(semantic.*, restored.semantic) or
        semantic.owner_token != .unassigned or tree.nodes.items.len == 0 or
        !std.mem.eql(u8, current.source, tree.source)) return false;
    const root = tree.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
    if (@backingInt(root) >= tree.nodes.items.len or tree.getNode(root).tag != .program) return false;
    const decoded_hash = @import("../util/wyhash.zig").hashU64(tree.source);
    if (decoded_hash != loaded.contents_hash) return false;
    // All fallible/identity checks precede the current graph owner and one
    // publication. Never adopt an owner token from an unrelated cached graph.
    const owner = semantic.captureOwnerToken();
    if (owner == .unassigned) return false;
    current.runtime_helper_cache_source = .{
        .module_domain = current,
        .ast_domain = tree,
        .semantic_domain = semantic,
        .arena_domain = arena,
        .constructor = loaded,
        .winning_source = current.source,
        .decoded_source = tree.source,
        .decoded_hash = decoded_hash,
        .owner = owner,
        .root = root,
        .cache_key = current.disk_cache_key,
        .nodes = tree.nodes.items,
        .extras = tree.extra_data.items,
        .strings = tree.string_table.items,
        .symbols = semantic.symbols.items,
        .scopes = semantic.scopes,
        .scope_maps = semantic.scope_maps,
        .references = semantic.references,
        .symbol_ids = semantic.symbol_ids,
        .scope_owners = semantic.scope_owner_map,
    };
    return true;
}

const CacheInput = struct { current: *const module.Module, copy: module.RuntimeHelperCacheSource };
fn matchesCacheInput(input: CacheInput, tree: *const ast.Ast, semantic: *const module.ModuleSemanticData, loaded: origin_mod.Origin, options: helpers.SourceOptions, contents: []const u8) bool {
    const current = input.current;
    const copy = input.copy;
    const root = tree.transformed_root orelse if (tree.nodes.items.len > 0) @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1)))) else return false;
    if (@backingInt(root) >= tree.nodes.items.len or tree.getNode(root).tag != .program) return false;
    return copy.module_domain == current and copy.ast_domain == tree and copy.semantic_domain == semantic and
        current.parse_arena != null and current.parse_arena.? == copy.arena_domain and
        copy.owner != .unassigned and semantic.owner_token == copy.owner and copy.cache_key == current.disk_cache_key and copy.root == root and
        std.meta.eql(copy.nodes, tree.nodes.items) and std.meta.eql(copy.extras, tree.extra_data.items) and std.meta.eql(copy.strings, tree.string_table.items) and
        std.meta.eql(copy.symbols, semantic.symbols.items) and std.meta.eql(copy.scopes, semantic.scopes) and std.meta.eql(copy.scope_maps, semantic.scope_maps) and
        std.meta.eql(copy.references, semantic.references) and std.meta.eql(copy.symbol_ids, semantic.symbol_ids) and std.meta.eql(copy.scope_owners, semantic.scope_owner_map) and
        std.meta.eql(copy.constructor, loaded) and current.runtime_helper_source != null and std.meta.eql(current.runtime_helper_source.?, loaded) and
        std.meta.eql(copy.winning_source, contents) and helpers.matchesConstructedSource(loaded, options, contents) and
        std.meta.eql(copy.decoded_source, tree.source) and @import("../util/wyhash.zig").hashU64(tree.source) == copy.decoded_hash and
        copy.decoded_hash == loaded.contents_hash;
}

pub fn captureFromModule(a: std.mem.Allocator, current: *module.Module, source_options: helpers.SourceOptions, options: @import("transformer.zig").TransformOptions, has_external_ast_producer: bool) Error!?Source {
    const tree = if (current.ast) |*value| value else return null;
    const semantic = if (current.semantic) |*value| value else return null;
    const loaded = current.runtime_helper_source orelse return null;
    const cache_input: ?CacheInput = if (current.runtime_helper_cache_source) |copy| .{ .current = current, .copy = copy } else null;
    return captureInput(a, tree, semantic, loaded, current.source, source_options, options, has_external_ast_producer, cache_input);
}

/// Only a winning builtin constructor may reach this call site. Revalidate its
/// source bytes against both the Module and parsed AST after all load/transform
/// stages. An AST hook is a separate producer even when it leaves equal bytes.
pub fn capture(a: std.mem.Allocator, tree: *const ast.Ast, semantic: *module.ModuleSemanticData, loaded: origin_mod.Origin, module_source: []const u8, source_options: helpers.SourceOptions, options: @import("transformer.zig").TransformOptions, has_external_ast_producer: bool) Error!?Source {
    return captureInput(a, tree, semantic, loaded, module_source, source_options, options, has_external_ast_producer, null);
}

fn captureInput(a: std.mem.Allocator, tree: *const ast.Ast, semantic: *module.ModuleSemanticData, loaded: origin_mod.Origin, module_source: []const u8, source_options: helpers.SourceOptions, options: @import("transformer.zig").TransformOptions, has_external_ast_producer: bool, cache_input: ?CacheInput) Error!?Source {
    const source_witness = origin_mod.matchesContents(loaded, tree.source) or
        (if (cache_input) |input| matchesCacheInput(input, tree, semantic, loaded, source_options, module_source) else false);
    if (has_external_ast_producer or !options.strip_types or options.minify_syntax or options.react_refresh or options.emotion or options.styled_components or
        options.drop_console or options.drop_debugger or options.drop_labels.len != 0 or options.hasMappedImportToSplit(tree) or
        @import("transformer/define.zig").astUsesDefine(tree, options.define) or
        !helpers.matchesConstructedSource(loaded, source_options, module_source) or !source_witness) return null;
    for (options.plugins) |plugin| if (plugin.transform != null or plugin.onFunction != null or plugin.visitor != null or plugin.autoWorkletCallees.len != 0) return null;
    const root = tree.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
    const nodes = try walk.collectReachableNodeIndicesFrom(a, tree, root);
    if (!eligible(tree, nodes, options, loaded.catalog)) return null;
    var node_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (nodes) |raw| try node_set.put(a, raw, {});
    const leaves = try refs_walk.collectIdentifierReferences(a, tree, root);
    var externals: std.ArrayList(External) = .empty;
    var external_counts: [2]usize = .{ 0, 0 };
    for (leaves) |leaf| {
        const raw = @backingInt(leaf);
        if (raw >= semantic.symbol_ids.len) return null;
        if (semantic.symbol_ids[raw] != null) continue;
        // The constructor/variant/content seal and actual lexical null-ID
        // leaf establish this role. Spelling is only its fixed invariant;
        // no name lookup is used to find a binding or decide its ScopeId.
        const role = externalRole(loaded.catalog, tree, leaves, leaf) orelse return null;
        external_counts[@backingInt(role)] += 1;
        const owner = (try nearestOwner(a, tree, root, raw, semantic.scopes, &semantic.scope_owner_map)) orelse return null;
        try externals.append(a, .{ .node = raw, .owner = owner });
    }
    if (!std.meta.eql(external_counts, expectedExternalCounts(loaded.catalog))) return null;
    var owners: std.ArrayList(Owner) = .empty;
    for (nodes) |raw| if (semantic.scope_owner_map.get(raw)) |scope| try owners.append(a, .{ .node = raw, .scope = scope });
    var exports: std.ArrayList(Export) = .empty;
    var export_iterator = semantic.exported_names.iterator();
    while (export_iterator.next()) |entry| try exports.append(a, .{ .name = entry.key_ptr.*, .span = entry.value_ptr.* });
    return .{
        .source_domain = tree,
        .syntax = tree.*,
        .output_domain = undefined,
        .origin = loaded,
        .input_source = tree.source,
        .input_source_hash = @import("../util/wyhash.zig").hashU64(tree.source),
        .owner = semantic.captureOwnerToken(),
        .root = root,
        .nodes = nodes,
        .node_set = node_set,
        .leaves = leaves,
        .externals = try externals.toOwnedSlice(a),
        .symbols = try a.dupe(sym.Symbol, semantic.symbols.items),
        .scopes = try a.dupe(scopes_mod.Scope, semantic.scopes),
        .references = try a.dupe(sym.Reference, semantic.references),
        .owners = try owners.toOwnedSlice(a),
        .exports = try exports.toOwnedSlice(a),
    };
}

pub fn activate(self: anytype, selected: Source) Error!void {
    if (!self.semantic_edit_enabled or selected.owner == .unassigned or selected.source_domain != self.semantic_source_ast or self.virtual_provider_source != null) return invalid();
    var source = selected;
    source.output_domain = self.ast;
    self.virtual_provider_source = source;
}

/// The exact visit invocation supplies this source/result pair. No row, SID,
/// scope or flags are attached here. Manual child containers are proven later
/// through this known parent's schema edges, never by spelling or span.
pub fn recordVisit(self: anytype, source_node: NodeIndex, result: NodeIndex) Error!void {
    const source = self.virtual_provider_source orelse return;
    self.virtual_provider_before_binder_root = .none;
    if (source.output_domain != self.ast or source.source_domain != self.semantic_source_ast) return invalid();
    if (source_node.isNone() or @backingInt(source_node) >= source.syntax.nodes.items.len) return;
    if (!source.node_set.contains(@backingInt(source_node))) return;
    if (result.isNone() or @backingInt(result) >= self.ast.nodes.items.len) return invalid();
    const entry = try self.virtual_provider_visits.getOrPut(self.allocator, @backingInt(source_node));
    if (entry.found_existing and entry.value_ptr.* != @backingInt(result)) return invalid();
    entry.value_ptr.* = @backingInt(result);
}

const Pair = struct { source: NodeIndex, output: NodeIndex };
fn appendPair(a: std.mem.Allocator, stack: *std.ArrayList(Pair), source: NodeIndex, output: NodeIndex) Error!void {
    if (source.isNone() != output.isNone()) return invalid();
    if (!source.isNone()) try stack.append(a, .{ .source = source, .output = output });
}
fn appendList(a: std.mem.Allocator, stack: *std.ArrayList(Pair), old: *const ast.Ast, new: *const ast.Ast, before: ast.NodeList, after: ast.NodeList) Error!void {
    if (before.len != after.len or before.start > old.extra_data.items.len or before.len > old.extra_data.items.len - before.start or after.start > new.extra_data.items.len or after.len > new.extra_data.items.len - after.start) return invalid();
    for (0..before.len) |index| try appendPair(a, stack, @fromBackingInt(old.extra_data.items[before.start + index]), @fromBackingInt(new.extra_data.items[after.start + index]));
}
fn shape(self: anytype, source: Source, root: NodeIndex) Error!std.AutoHashMapUnmanaged(u32, u32) {
    const old = &source.syntax;
    const new = self.ast;
    if (self.virtual_provider_visits.get(@backingInt(source.root)) != @backingInt(root)) return invalid();
    var result: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    errdefer result.deinit(self.allocator);
    var stack: std.ArrayList(Pair) = .empty;
    defer stack.deinit(self.allocator);
    try stack.append(self.allocator, .{ .source = source.root, .output = root });
    while (stack.pop()) |pair| {
        const a = @backingInt(pair.source);
        const b = @backingInt(pair.output);
        if (a >= old.nodes.items.len or b >= new.nodes.items.len) return invalid();
        const entry = try result.getOrPut(self.allocator, a);
        if (entry.found_existing) {
            if (entry.value_ptr.* != b) return invalid();
            continue;
        }
        entry.value_ptr.* = b;
        if (self.virtual_provider_visits.get(a)) |known| if (known != b) return invalid();
        const before = old.nodes.items[a];
        const after = new.nodes.items[b];
        if (before.tag == .parenthesized_expression and after.tag != before.tag) {
            try appendPair(self.allocator, &stack, before.data.unary.operand, pair.output);
            continue;
        }
        if (before.tag != after.tag) return invalid();
        switch (before.tag.dataKind()) {
            .leaf => switch (before.tag) {
                .identifier_reference, .binding_identifier, .assignment_target_identifier, .string_literal, .regexp_literal => {
                    if (!std.mem.eql(u8, old.getText(before.data.string_ref), new.getText(after.data.string_ref))) return invalid();
                },
                else => if (before.data.none != after.data.none or !std.mem.eql(u8, old.getText(before.span), new.getText(after.span))) return invalid(),
            },
            .unary => {
                if (before.data.unary.flags != after.data.unary.flags) return invalid();
                try appendPair(self.allocator, &stack, before.data.unary.operand, after.data.unary.operand);
            },
            .binary => {
                if (before.data.binary.flags != after.data.binary.flags) return invalid();
                try appendPair(self.allocator, &stack, before.data.binary.left, after.data.binary.left);
                try appendPair(self.allocator, &stack, before.data.binary.right, after.data.binary.right);
            },
            .ternary => {
                try appendPair(self.allocator, &stack, before.data.ternary.a, after.data.ternary.a);
                try appendPair(self.allocator, &stack, before.data.ternary.b, after.data.ternary.b);
                try appendPair(self.allocator, &stack, before.data.ternary.c, after.data.ternary.c);
            },
            .list => try appendList(self.allocator, &stack, old, new, before.data.list, after.data.list),
            .extra => {
                const words = before.tag.runtimeExtraWords() orelse return invalid();
                const x = before.data.extra;
                const y = after.data.extra;
                // The winning catalog is parsed by parseFunctionExpression,
                // which writes only the four runtime words. Its recorded
                // visitFunction result adds a canonical absent return type.
                // Never read the following unrelated source allocation.
                const parser_expression = before.tag == .function_expression;
                const source_words: usize = if (parser_expression) 4 else words;
                if (x > old.extra_data.items.len or source_words > old.extra_data.items.len - x or y > new.extra_data.items.len or words > new.extra_data.items.len - y) return invalid();
                if (parser_expression and (self.virtual_provider_visits.get(a) != b or new.extra_data.items[y + ast.FunctionExtra.return_type] != @backingInt(NodeIndex.none))) return invalid();
                for (0..source_words) |offset| {
                    var handled = false;
                    for (before.tag.extraChildOffsets()) |child| if (child == offset) {
                        try appendPair(self.allocator, &stack, @fromBackingInt(old.extra_data.items[x + offset]), @fromBackingInt(new.extra_data.items[y + offset]));
                        handled = true;
                    };
                    for (before.tag.extraListOffsets()) |list| {
                        if (list[0] == offset) {
                            try appendList(self.allocator, &stack, old, new, .{ .start = old.extra_data.items[x + list[0]], .len = old.extra_data.items[x + list[1]] }, .{ .start = new.extra_data.items[y + list[0]], .len = new.extra_data.items[y + list[1]] });
                            handled = true;
                        }
                        if (list[1] == offset) handled = true;
                    }
                    if (!handled and old.extra_data.items[x + offset] != new.extra_data.items[y + offset]) return invalid();
                }
            },
        }
    }
    return result;
}

pub const View = struct {
    symbols: []const sym.Symbol,
    scopes: []const scopes_mod.Scope,
    references: []const sym.Reference,
    ids: []const ?u32,
    owners: ?*const std.AutoHashMapUnmanaged(u32, u32) = null,
};
fn owned(self: anytype, view: View, raw: u32) ?u32 {
    return if (view.owners) |map| map.get(raw) else if (self.outputOwnedScope(@fromBackingInt(raw))) |id| @backingInt(id) else null;
}
fn validate(self: anytype, source: Source, view: View, root: NodeIndex) Error!void {
    if (source.owner == .unassigned or source.output_domain != self.ast or source.source_domain != self.semantic_source_ast or (!std.meta.eql(source.input_source, self.ast.source) or @import("../util/wyhash.zig").hashU64(self.ast.source) != source.input_source_hash) or self.runtime_helpers.hasAny() or self.runtime_helper_import_bindings.count() != 0 or view.symbols.len != source.symbols.len or view.scopes.len != source.scopes.len) return invalid();
    for (source.symbols, view.symbols) |before, after| {
        // Ref/write counters may include dead copied rows. Compare storage and
        // instantiation identity here; live reference multiplicity is checked below.
        if (before.kind != after.kind or before.scope_id != after.scope_id or before.origin_scope != after.origin_scope or
            before.synthetic_kind != after.synthetic_kind or before.synthetic_owner_id != after.synthetic_owner_id or
            before.const_kind != after.const_kind or before.requires_uppercase_first_char != after.requires_uppercase_first_char or
            !std.meta.eql(before.decl_flags, after.decl_flags) or !std.meta.eql(before.annex_b_alias, after.annex_b_alias) or
            !std.meta.eql(before.parameter_copy, after.parameter_copy) or !std.meta.eql(before.binding_instantiation, after.binding_instantiation) or
            !std.mem.eql(u8, before.nameText(source.syntax.source), after.nameText(self.ast.source)) or
            !std.mem.eql(u8, before.synthetic_name, after.synthetic_name) or !std.mem.eql(u8, before.output_name_hint, after.output_name_hint)) return invalid();
    }
    for (source.scopes, view.scopes) |before, after| if (before.kind != after.kind or before.parent != after.parent or before.is_strict != after.is_strict or before.symbol_count != after.symbol_count) return invalid();
    var pairs = try shape(self, source, root);
    defer pairs.deinit(self.allocator);
    const live = try walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
    defer self.allocator.free(live);
    var reachable: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reachable.deinit(self.allocator);
    for (live) |raw| try reachable.put(self.allocator, raw, {});
    for (source.owners) |owner| {
        const output = pairs.get(owner.node) orelse return invalid();
        if (owned(self, view, output) != owner.scope) return invalid();
    }
    var reverse: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer reverse.deinit(self.allocator);
    var it = pairs.iterator();
    while (it.next()) |entry| try reverse.put(self.allocator, entry.value_ptr.*, {});
    for (live) |raw| {
        if (!reverse.contains(raw)) return invalid();
        if (owned(self, view, raw)) |actual_scope| {
            var explained = false;
            for (source.owners) |owner| {
                if (pairs.get(owner.node) == raw and owner.scope == actual_scope) explained = true;
            }
            if (!explained) return invalid();
        }
    }
    var count: usize = 0;
    for (view.references) |row| {
        const anchor = if (row.flags.declare) row.declaration_node_index else row.node_index;
        if (anchor.isNone() or reachable.contains(@backingInt(anchor))) count += 1;
    }
    if (count != source.references.len) return invalid();
    for (source.references) |before| {
        const anchor = if (before.flags.declare) before.declaration_node_index else before.node_index;
        const expected = if (anchor.isNone()) NodeIndex.none else @as(NodeIndex, @fromBackingInt(pairs.get(@backingInt(anchor)) orelse return invalid()));
        var matches: usize = 0;
        for (view.references) |after| {
            const current = if (after.flags.declare) after.declaration_node_index else after.node_index;
            if (current != expected or after.symbol_id != before.symbol_id or after.scope_id != before.scope_id or !std.meta.eql(after.flags, before.flags)) continue;
            if (!current.isNone() and (@backingInt(current) >= view.ids.len or view.ids[@backingInt(current)] != @as(u32, @intCast(@backingInt(before.symbol_id))))) return invalid();
            matches += 1;
        }
        if (matches != 1) return invalid();
    }
    var external_counts: [2]usize = .{ 0, 0 };
    for (source.externals) |external| {
        const role = externalRole(source.origin.catalog, &source.syntax, source.leaves, @fromBackingInt(external.node)) orelse return invalid();
        external_counts[@backingInt(role)] += 1;
    }
    if (!std.meta.eql(external_counts, expectedExternalCounts(source.origin.catalog))) return invalid();
    if (source.externals.len != 0) {
        var actual_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        for (live) |raw| if (owned(self, view, raw)) |scope| try actual_owners.put(self.allocator, raw, scope);
        for (source.externals, 0..) |external, index| {
            for (source.externals[0..index]) |earlier| if (earlier.node == external.node) return invalid();
            const output = pairs.get(external.node) orelse return invalid();
            const expected_owner = pairs.get(external.owner.node) orelse return invalid();
            if (output >= view.ids.len or view.ids[output] != null or
                self.explicit_global_reference_nodes.contains(output)) return invalid();
            const actual = (try nearestOwner(self.allocator, self.ast, root, output, view.scopes, &actual_owners)) orelse return invalid();
            if (actual.node != expected_owner or actual.scope != external.owner.scope) return invalid();
            for (view.references) |row| if ((!row.node_index.isNone() and @backingInt(row.node_index) == output) or
                (!row.declaration_node_index.isNone() and @backingInt(row.declaration_node_index) == output)) return invalid();
        }
    }
    const output_leaves = try refs_walk.collectIdentifierReferences(self.allocator, self.ast, root);
    defer self.allocator.free(output_leaves);
    if (output_leaves.len != source.leaves.len) return invalid();
    for (source.leaves) |leaf| {
        const output = pairs.get(@backingInt(leaf)) orelse return invalid();
        var found: usize = 0;
        for (output_leaves) |current| if (@backingInt(current) == output) {
            found += 1;
        };
        if (found != 1) return invalid();
    }
}

pub fn beforeBinder(self: anytype, root: NodeIndex) std.mem.Allocator.Error!void {
    const source = self.virtual_provider_source orelse return;
    self.virtual_provider_before_binder_root = .none;
    // A container-only transform need not create an Editor before the output
    // binder. Read its current graph directly; creating an Editor here would
    // turn this preservation witness into a semantic producer.
    const view: View = if (self.semantic_editor) |*editor|
        .{ .symbols = editor.symbols.items, .scopes = editor.scopes.items, .references = editor.references.items, .ids = editor.symbol_ids.items }
    else
        .{ .symbols = self.symbols, .scopes = self.scopes, .references = self.references, .ids = self.symbol_ids.items };
    validate(self, source, view, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    self.virtual_provider_before_binder_root = root;
}

pub fn complete(self: anytype, semantic: *const module.ModuleSemanticData, module_source: []const u8, root: NodeIndex) Error!bool {
    const source = self.virtual_provider_source orelse return false;
    if (self.virtual_provider_before_binder_root != root or semantic.owner_token != source.owner or !origin_mod.matchesContents(source.origin, module_source) or semantic.exported_names.count() != source.exports.len) return false;
    for (source.exports) |edge| {
        const current = semantic.exported_names.get(edge.name) orelse return false;
        if (!std.meta.eql(edge.span, current)) return false;
    }
    validate(self, source, .{ .symbols = semantic.symbols.items, .scopes = semantic.scopes, .references = semantic.references, .ids = semantic.symbol_ids, .owners = &semantic.scope_owner_map }, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return true;
}
