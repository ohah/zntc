//! Raw Source closed synchronous ESM graphs can instantiate cells before bodies.
//! Wrapped Source retains its existing init/namespace/guard ABI and backend.
//! Admission is checked again after finalization against actual wrap kinds.
//! Membership is derived from actual graph modules, never a virtual path prefix.
const std = @import("std");
const Graph = @import("graph.zig").ModuleGraph;
const Module = @import("module.zig").Module;
const ModuleIndex = @import("types.zig").ModuleIndex;

pub fn helper(graph: *const Graph, module: *const Module) !bool {
    const constructor = module.runtime_helper_constructor orelse return false;
    if (graph.getModule(module.index) != module or
        !@import("../runtime_helper_modules.zig").matchesModuleConstructor(constructor, graph.helper_plugin_opts, module.source))
        return error.InvalidSynchronousModuleHelper;
    return true;
}

pub fn admitted(graph: *const Graph) !bool {
    if (!graph.pm_cjs_module_environments) return false;
    var count: usize = 0;
    for (0..graph.modules.count()) |i| {
        const module = graph.modules.at(i);
        if (module.is_disabled) continue;
        if (module.is_external) return false;
        if (try helper(graph, module)) continue;
        count += 1;
        if (!module.module_type.isJavaScriptLike() or module.wrap_kind != .none or module.has_cjs_export_signal or
            module.self_uses_top_level_await or module.tla_iife_stmt != null) return false;
        const tree = if (module.ast) |*value| value else return false;
        const semantic = module.semantic orelse return false;
        if (semantic.scopes.len == 0 or !semantic.scopes[0].is_strict or semantic.scopes[0].blocksMangling()) return false;
        var globals = semantic.unresolved_references.keyIterator();
        while (globals.next()) |name| {
            for ([_][]const u8{ "arguments", "require", "module", "exports", "__filename", "__dirname" }) |host| {
                if (@import("../lexer/scanner.zig").Scanner.identifierValueEquals(name.*, host)) return false;
            }
        }
        for (module.import_records) |record| {
            if (record.ts_elided) continue;
            switch (record.kind) {
                .static_import, .re_export, .side_effect => {},
                else => return false,
            }
            if (record.is_external or record.resolved.isNone()) return false;
        }
        // Resource disposal and import.meta retain their existing output paths.
        for (tree.nodes.items) |node| switch (node.tag) {
            .meta_property, .with_statement, .hashbang => return false,
            .variable_declaration => if (tree.variableDeclarationKind(node).isUsing()) {
                return false;
            },
            else => {},
        };
    }
    if (count == 0) return false;
    const colors = try graph.allocator.alloc(u2, graph.modules.count());
    defer graph.allocator.free(colors);
    @memset(colors, 0);
    for (0..graph.modules.count()) |i| {
        const module = graph.modules.at(i);
        if (module.is_disabled or try helper(graph, module)) continue;
        if (try cyclic(graph, module, colors)) return true;
    }
    return false;
}

fn cyclic(graph: *const Graph, module: *const Module, colors: []u2) !bool {
    const index = module.index.toU32();
    if (index >= colors.len or graph.getModule(module.index) != module) return error.InvalidSynchronousModuleOwner;
    if (colors[index] == 1) return true;
    if (colors[index] == 2) return false;
    const Cursor = struct { module: ModuleIndex, next_record: usize = 0 };
    var stack: std.ArrayList(Cursor) = .empty;
    defer stack.deinit(graph.allocator);
    try stack.append(graph.allocator, .{ .module = module.index });
    colors[index] = 1;
    while (stack.items.len != 0) {
        const cursor = &stack.items[stack.items.len - 1];
        const current = graph.getModule(cursor.module) orelse return error.InvalidSynchronousModuleOwner;
        const current_index = current.index.toU32();
        if (current_index >= colors.len or current.index != cursor.module or graph.getModule(current.index) != current)
            return error.InvalidSynchronousModuleOwner;
        if (cursor.next_record == current.import_records.len) {
            colors[current_index] = 2;
            _ = stack.pop();
            continue;
        }
        const record = current.import_records[cursor.next_record];
        cursor.next_record += 1;
        if (record.ts_elided) continue;
        const target = graph.getModule(record.resolved) orelse return error.InvalidSynchronousModuleOwner;
        if (target.is_disabled or try helper(graph, target)) continue;
        const target_index = target.index.toU32();
        if (target_index >= colors.len or graph.getModule(target.index) != target) return error.InvalidSynchronousModuleOwner;
        if (colors[target_index] == 1) return true;
        if (colors[target_index] == 2) continue;
        // Grow before marking the child active; OOM leaves no partial frame.
        try stack.append(graph.allocator, .{ .module = target.index });
        colors[target_index] = 1;
    }
    return false;
}

pub fn contains(graph: *const Graph, module: *const Module) !bool {
    return graph.getModule(module.index) == module and !module.is_disabled and !module.is_external and
        !(try helper(graph, module)) and graph.pm_cjs_module_environment_admitted;
}

/// This same ordered array is consumed by import projection and runtime slots.
pub fn dependencies(a: std.mem.Allocator, graph: *const Graph, module: *const Module, tree_shaker_active: bool) ![]const ModuleIndex {
    if (graph.getModule(module.index) != module) return error.InvalidSynchronousModuleOwner;
    var result: std.ArrayList(ModuleIndex) = .empty;
    errdefer result.deinit(a);
    for (module.import_records) |record| {
        if (record.ts_elided) continue;
        const target = graph.getModule(record.resolved) orelse return error.InvalidSynchronousModuleOwner;
        if (target.is_disabled or try helper(graph, target) or (tree_shaker_active and !target.is_included)) continue;
        var duplicate = false;
        for (result.items) |known| if (known == target.index) {
            duplicate = true;
            break;
        };
        if (!duplicate) try result.append(a, target.index);
    }
    return result.toOwnedSlice(a);
}
