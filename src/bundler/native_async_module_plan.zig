//! Output roles for native single-file module environments. Module constructor
//! owners survive canonical renumbering; no source ScopeId or SymbolId is copied.
const std = @import("std");
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const types = @import("types.zig");
const Owner = @import("codegen_output_domain.zig").Owner;

pub const Member = struct {
    owner: Owner,
    index: types.ModuleIndex,
    previous_wrap: types.WrapKind,
    previous_exports: types.ExportsKind,
};

pub fn restore(graph: *ModuleGraph) void {
    var modules = graph.modulesIterator();
    while (modules.next()) |module| {
        const prior = graph.native_async_module_members.get(module.codegen_output_owner) orelse continue;
        if (prior.owner != module.codegen_output_owner) @panic("native module output owner changed");
        @import("graph/native_async_module_roles.zig").restore(graph, module.index, prior);
    }
    graph.native_async_module_members.clearRetainingCapacity();
}

pub fn contains(graph: *const ModuleGraph, module: *const Module) bool {
    const role = graph.native_async_module_members.get(module.codegen_output_owner) orelse return false;
    if (role.owner == .unassigned or role.owner != module.codegen_output_owner or role.index != module.index or
        graph.getModule(role.index) != module or module.wrap_kind != .esm)
        @panic("native module environment lost its actual module output owner");
    return true;
}

pub fn promote(graph: *ModuleGraph) !void {
    if (!graph.transform_options_base.native_async_module_boundaries or !graph.native_async_module_demanded) return;
    const factory_index = graph.path_to_module.get("\x00zntc:runtime/native-async-module") orelse return;
    const factory = graph.getModule(factory_index) orelse return error.InvalidNativeAsyncModuleFactory;
    const origin = factory.runtime_helper_source orelse return error.InvalidNativeAsyncModuleFactory;
    if (origin.catalog != .native_async_module or
        !@import("../runtime_helper_modules.zig").matchesConstructedSource(origin, graph.helper_plugin_opts, factory.source) or
        factory.dependencies.items.len != 0) return error.InvalidNativeAsyncModuleFactory;

    // The first environment protocol admits closed JavaScript ESM graphs.
    // Other layouts retain the existing fail-closed publication diagnostic.
    var modules = graph.modulesIterator();
    while (modules.next()) |module| {
        if (module == factory or module.is_disabled) continue;
        if (module.is_external) return;
        if (!module.module_type.isJavaScriptLike() or module.wrap_kind == .cjs or module.ast == null) return;
        for (module.export_bindings) |binding| if (binding.kind == .re_export_star or binding.kind == .re_export_namespace) return;
        const semantic = module.semantic orelse return;
        if (semantic.scopes.len == 0 or !semantic.scopes[0].is_strict or semantic.scopes[0].blocksMangling()) return;
        var globals = semantic.unresolved_references.keyIterator();
        while (globals.next()) |name| if (@import("../lexer/scanner.zig").Scanner.identifierValueEquals(name.*, "arguments")) return;
        if (!try hasOnlyProgramAsyncResources(graph.allocator, &(module.ast.?))) return;
    }
    modules = graph.modulesIterator();
    while (modules.next()) |module| {
        if (module == factory or module.is_external or module.is_disabled) continue;
        if (module.codegen_output_owner == .unassigned) return error.InvalidNativeAsyncModuleOwner;
        try graph.native_async_module_members.put(graph.allocator, module.codegen_output_owner, .{
            .owner = module.codegen_output_owner,
            .index = module.index,
            .previous_wrap = module.wrap_kind,
            .previous_exports = module.exports_kind,
        });
        @import("graph/native_async_module_roles.zig").promote(graph, module.index);
    }
}

fn hasOnlyProgramAsyncResources(a: std.mem.Allocator, tree: *const @import("../parser/ast.zig").Ast) !bool {
    const NodeIndex = @import("../parser/ast.zig").NodeIndex;
    if (tree.nodes.items.len == 0) return false;
    const root = tree.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(tree.nodes.items.len - 1))));
    if (root.isNone() or tree.getNode(root).tag != .program) return false;
    var direct: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
    defer direct.deinit(a);
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(a);
    var statements = tree.iterateExtraList(tree.getNode(root).data.list);
    while (statements.next()) |statement| {
        try direct.put(a, statement, {});
        try stack.append(a, statement);
    }
    var visited: std.AutoHashMapUnmanaged(NodeIndex, void) = .empty;
    defer visited.deinit(a);
    while (stack.pop()) |index| {
        if (index.isNone()) continue;
        if (@backingInt(index) >= tree.nodes.items.len) return error.InvalidNativeAsyncModuleOwner;
        const seen = try visited.getOrPut(a, index);
        if (seen.found_existing) continue;
        const node = tree.getNode(index);
        if (tree.functionBodyBlock(node) != null) continue;
        if (node.tag == .variable_declaration and tree.variableDeclarationKind(node) == .await_using and !direct.contains(index)) return false;
        var children = @import("../parser/ast_walk.zig").children(tree, node);
        while (children.next()) |child| try stack.append(a, child);
    }
    return true;
}
