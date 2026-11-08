//! A retained native await-using declaration needs a real async module boundary.
//! Diagnose the selected output layout, never a source-text signal or an old
//! retired declaration. Explicit native ESM module files keep their own scope.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const scope_mod = @import("../semantic/scope.zig");
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const ChunkGraph = @import("chunk.zig").ChunkGraph;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const EmitOptions = @import("emitter.zig").EmitOptions;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;

pub fn diagnose(graph: *ModuleGraph, options: *const EmitOptions, shaker: ?*const TreeShaker, chunks: ?*const ChunkGraph) !bool {
    // Chunk membership is authoritative only after the actual planner runs.
    if (chunks == null and (options.code_splitting or options.preserve_modules) and !options.dev_mode and
        options.format == .esm and !options.unsupported.using and !options.unsupported.top_level_await) return false;
    var entry_count: usize = 0;
    var entries = graph.modulesIterator();
    while (entries.next()) |module| {
        if (shaker) |s| if (!s.isIncluded(module.index.toU32())) continue;
        if (module.is_entry_point and !module.is_external and !module.is_disabled) entry_count += 1;
    }
    var blocked = false;
    var modules = graph.modulesIterator();
    while (modules.next()) |module| {
        if (shaker) |s| if (!s.isIncluded(module.index.toU32())) continue;
        if (module.is_external or module.is_disabled or !module.module_type.isJavaScriptLike()) continue;
        // Initial analysis marks the implicit Await as well as explicit await.
        // Ordinary modules must not pay for another complete AST traversal.
        if (!module.self_uses_top_level_await) continue;
        if (preservesBoundary(graph, module, options, chunks, shaker, entry_count)) continue;
        const span = try retainedDeclaration(graph.allocator, module, shaker) orelse continue;
        try graph.addOwnedDiagnostic(.{
            .code = .top_level_await_target,
            .severity = .@"error",
            .file_path = module.path,
            .span = span,
            .step = .link,
            .message = "This output layout cannot preserve native await using module disposal before its importer runs",
            .suggestion = "Use --preserve-modules with --format=esm and a native await-using/top-level-await target (API: preserveModules: true, format: 'esm').",
        });
        blocked = true;
    }
    return blocked;
}

fn preservesBoundary(graph: *const ModuleGraph, module: *const Module, options: *const EmitOptions, chunks: ?*const ChunkGraph, shaker: ?*const TreeShaker, entry_count: usize) bool {
    if (options.format != .esm or options.dev_mode or options.unsupported.using or
        options.unsupported.top_level_await or module.wrap_kind != .none) return false;
    if (chunks) |plan| {
        const index = plan.getModuleChunk(module.index);
        if (index.isNone() or @backingInt(index) >= plan.chunks.items.len) return false;
        const chunk = plan.getChunk(index);
        return chunk.modules.items.len == 1 and chunk.modules.items[0] == module.index;
    }
    // A unique unwrapped ESM entry is already the final module evaluation in
    // the single-output path. Its native registrations belong to that output
    // module, not to a factory or an earlier dependency's flattened body.
    if (!module.is_entry_point or entry_count != 1) return false;
    var ordered = graph.modulesIterator();
    while (ordered.next()) |other| {
        if (shaker) |selected| if (!selected.isIncluded(other.index.toU32())) continue;
        if (other.is_external or other.is_disabled or !other.module_type.isJavaScriptLike() or other.only_dynamically_reached) continue;
        if (other.exec_index > module.exec_index) return false;
    }
    return true;
}

fn retainedDeclaration(a: std.mem.Allocator, module: *const Module, shaker: ?*const TreeShaker) !?Span {
    const tree = &(module.ast orelse return null);
    if (tree.nodes.items.len == 0) return null;
    const root = tree.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
    if (root.isNone() or @backingInt(root) >= tree.nodes.items.len or tree.getNode(root).tag != .program) return error.InvalidNativeAsyncDisposalOwner;
    const semantic = &(module.semantic orelse return error.InvalidNativeAsyncDisposalOwner);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(a);
    var visited: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
    defer visited.deinit(a);
    var statements = tree.iterateExtraList(tree.getNode(root).data.list);
    var offset: u32 = 0;
    while (statements.next()) |statement| : (offset += 1) {
        if (shaker) |s| if (!s.isStmtReachable(module.index.toU32(), offset)) continue;
        try stack.append(a, statement);
    }
    while (stack.pop()) |index| {
        if (index.isNone()) continue;
        const raw = @backingInt(index);
        if (raw >= tree.nodes.items.len) return error.InvalidNativeAsyncDisposalOwner;
        const slot = try visited.getOrPut(a, index);
        if (slot.found_existing) continue;
        const node = tree.getNode(index);
        switch (node.tag) {
            // These create a function; their bodies do not evaluate the module.
            .function_declaration, .function_expression, .arrow_function_expression => continue,
            .variable_declaration => if (tree.hasExtra(node.data.extra, 2) and tree.variableDeclarationKind(node) == .await_using) {
                // variable_declaration.extra = [kind, declarators.start, declarators.len].
                const start = tree.extra_data.items[node.data.extra + 1];
                const len = tree.extra_data.items[node.data.extra + 2];
                if (len == 0 or start >= tree.extra_data.items.len or len > tree.extra_data.items.len - start) return error.InvalidNativeAsyncDisposalOwner;
                const declarator_index = tree.readExtraNode(start, 0);
                if (declarator_index.isNone() or @backingInt(declarator_index) >= tree.nodes.items.len) return error.InvalidNativeAsyncDisposalOwner;
                const declarator = tree.getNode(declarator_index);
                if (declarator.tag != .variable_declarator or !tree.hasExtra(declarator.data.extra, 2)) return error.InvalidNativeAsyncDisposalOwner;
                const binding = tree.readExtraNode(declarator.data.extra, 0);
                if (binding.isNone() or @backingInt(binding) >= semantic.symbol_ids.len or
                    @backingInt(binding) >= tree.nodes.items.len or tree.getNode(binding).tag != .binding_identifier) return error.InvalidNativeAsyncDisposalOwner;
                const sid = semantic.symbol_ids[@backingInt(binding)] orelse return error.InvalidNativeAsyncDisposalOwner;
                if (sid >= semantic.symbols.items.len) return error.InvalidNativeAsyncDisposalOwner;
                const owner = semantic.symbols.items[sid].scope_id;
                if (owner.isNone() or owner.toIndex() >= semantic.scopes.len or scope_mod.anyAncestor(semantic.scopes, owner, struct {
                    fn isFunction(scope: scope_mod.Scope) bool {
                        return scope.kind == .function;
                    }
                }.isFunction)) return error.InvalidNativeAsyncDisposalOwner;
                var declarations: usize = 0;
                for (semantic.references) |reference| {
                    if (reference.declaration_node_index == binding and reference.node_index.isNone() and
                        @backingInt(reference.symbol_id) == sid and reference.scope_id == owner and
                        reference.flags.declare and !reference.flags.read and !reference.flags.write) declarations += 1;
                }
                if (declarations != 1 or node.span.start & ast_mod.Ast.STRING_TABLE_BIT != 0 or
                    node.span.end < node.span.start or node.span.end > module.source.len) return error.InvalidNativeAsyncDisposalOwner;
                return node.span;
            },
            else => {},
        }
        var children = ast_walk.children(tree, node);
        while (children.next()) |child| try stack.append(a, child);
    }
    return null;
}
