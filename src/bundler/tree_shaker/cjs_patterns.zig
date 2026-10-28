//! CJS AST pattern helpers used by tree shaking.

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const Module = @import("../module.zig").Module;
const ModuleSemanticData = @import("../module.zig").ModuleSemanticData;
const StmtInfos = @import("../stmt_info.zig").ModuleStmtInfos;
const ast_mod = @import("../../parser/ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Scope = @import("../../semantic/scope.zig").Scope;
const SymbolKind = @import("../../semantic/symbol.zig").SymbolKind;
const ast_walk = @import("../../parser/ast_walk.zig");
const Kind = @import("../../lexer/token.zig").Kind;
const Span = @import("../../lexer/token.zig").Span;

/// Declaration liveness in a dynamic root does not prove that a source-local
/// Buffer alias still has its initializer value. This guards the production
/// optimization before either retained or legacy AST editing may begin.
pub fn nodeBufferCapabilityValuesAreStable(module: *const Module) bool {
    const ast = if (module.ast) |*value| value else return false;
    const semantic = if (module.semantic) |*value| value else return false;
    if (ast.nodes.items.len == 0 or semantic.scopes.len == 0) return false;
    const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or ast.getNode(root).tag != .program) return false;
    const scope = semantic.scope_owner_map.get(@backingInt(root)) orelse return false;
    if (scope != 0 or scope >= semantic.scopes.len) return false;
    const program_scope = semantic.scopes[scope];
    if (program_scope.kind != .global and program_scope.kind != .module) return false;
    if (program_scope.blocksMangling()) return false;

    const allocator = ast.allocator;
    var buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_names.deinit(allocator);
    collectNodeBufferModuleObjectNames(allocator, ast, &buffer_names) catch return false;
    var constructor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer constructor_names.deinit(allocator);
    collectNodeBufferCtorNames(allocator, ast, &buffer_names, &constructor_names) catch return false;
    if (constructor_names.count() == 0) return true;

    // Source var reinitializers share their original binding SID but need not
    // increment write_count. Count actual live initializer edges independently.
    var initializer_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer initializer_counts.deinit(allocator);
    var pending: std.ArrayList(NodeIndex) = .empty;
    defer pending.deinit(allocator);
    var live: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer live.deinit(allocator);
    pending.append(allocator, root) catch return false;
    while (pending.pop()) |current| {
        if (current.isNone()) continue;
        const raw = @backingInt(current);
        if (raw >= ast.nodes.items.len) return false;
        const entry = live.getOrPut(allocator, raw) catch return false;
        if (entry.found_existing) continue;
        const node = ast.getNode(current);
        if (node.tag == .variable_declarator) {
            const binding = ast.readExtraNode(node.data.extra, 0);
            const initializer = ast.readExtraNode(node.data.extra, 2);
            if (!initializer.isNone() and !binding.isNone()) {
                var bindings = ast_walk.bindingIdentifiers(allocator, ast, binding, .{}) catch return false;
                defer bindings.deinit();
                while (bindings.next() catch return false) |leaf| {
                    if (@backingInt(leaf) >= semantic.symbol_ids.len) return false;
                    if (semantic.symbol_ids[@backingInt(leaf)]) |id| {
                        const count = initializer_counts.getOrPut(allocator, id) catch return false;
                        if (!count.found_existing) count.value_ptr.* = 0;
                        count.value_ptr.* += 1;
                    }
                }
            }
        }
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| pending.append(allocator, child) catch return false;
    }

    // Conditions contain only &&, parentheses and plain member reads. Their
    // base references all execute in the if statement's actual lexical scope.
    // Discover that scope from live AST owner edges, never from a row being
    // validated or a name lookup. The visited map also rejects scope ambiguity.
    const Work = struct { node: NodeIndex, scope: u32 };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer visited.deinit(allocator);
    stack.append(allocator, .{ .node = root, .scope = scope }) catch return false;
    while (stack.pop()) |work| {
        if (work.node.isNone()) continue;
        const raw = @backingInt(work.node);
        if (raw >= ast.nodes.items.len) return false;
        const node = ast.getNode(work.node);
        const actual_scope = semantic.scope_owner_map.get(raw) orelse work.scope;
        if (actual_scope >= semantic.scopes.len) return false;
        if (actual_scope != work.scope) {
            const expected_kind: ?@TypeOf(program_scope.kind) = switch (node.tag) {
                .block_statement => .block,
                .switch_statement => .switch_block,
                .catch_clause => .catch_clause,
                else => null,
            };
            if (expected_kind) |kind| {
                if (semantic.scopes[actual_scope].kind != kind or
                    @backingInt(semantic.scopes[actual_scope].parent) != work.scope) return false;
            }
        }
        const seen = visited.getOrPut(allocator, raw) catch return false;
        if (seen.found_existing) {
            if (seen.value_ptr.* != actual_scope) return false;
            continue;
        }
        seen.value_ptr.* = actual_scope;
        if (node.tag == .if_statement) {
            var capabilities: BufferCapabilitySet = .{};
            if (collectNodeBufferCapabilityCondition(ast, node.data.ternary.a, &constructor_names, &capabilities) and capabilities.hasAll()) {
                if (!capabilityConditionValuesAreStable(module, ast, node.data.ternary.a, actual_scope, &initializer_counts)) return false;
            }
        }
        var children = ast_walk.children(ast, node);
        while (children.next()) |child| stack.append(allocator, .{ .node = child, .scope = actual_scope }) catch return false;
    }
    return true;
}

fn capabilityConditionValuesAreStable(module: *const Module, ast: *const Ast, condition: NodeIndex, scope: u32, initializer_counts: *const std.AutoHashMapUnmanaged(u32, u32)) bool {
    const semantic = if (module.semantic) |*value| value else return false;
    if (condition.isNone() or @backingInt(condition) >= ast.nodes.items.len) return false;
    const node = ast.getNode(condition);
    return switch (node.tag) {
        .parenthesized_expression => capabilityConditionValuesAreStable(module, ast, node.data.unary.operand, scope, initializer_counts),
        .logical_expression => node.data.binary.flags == @backingInt(Kind.amp2) and
            capabilityConditionValuesAreStable(module, ast, node.data.binary.left, scope, initializer_counts) and
            capabilityConditionValuesAreStable(module, ast, node.data.binary.right, scope, initializer_counts),
        .static_member_expression => blk: {
            const parts = staticMemberParts(ast, condition) orelse break :blk false;
            if (parts.object.isNone() or @backingInt(parts.object) >= ast.nodes.items.len or
                ast.getNode(parts.object).tag != .identifier_reference or @backingInt(parts.object) >= semantic.symbol_ids.len) break :blk false;
            const id = semantic.symbol_ids[@backingInt(parts.object)] orelse break :blk false;
            if (!exactBufferValueRead(module, parts.object, id, scope)) break :blk false;
            const object = exactNodeBufferConstructorObject(module, ast, id) orelse break :blk false;
            break :blk initializer_counts.get(id) == 1 and initializer_counts.get(object) == 1;
        },
        else => false,
    };
}

pub fn foldNodeBufferCapabilityIfs(allocator: std.mem.Allocator, ast: *Ast) bool {
    var buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_names.deinit(allocator);
    collectNodeBufferModuleObjectNames(allocator, ast, &buffer_names) catch return false;
    if (buffer_names.count() == 0) return false;

    var buffer_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_ctor_names.deinit(allocator);
    collectNodeBufferCtorNames(allocator, ast, &buffer_names, &buffer_ctor_names) catch return false;
    if (buffer_ctor_names.count() == 0) return false;

    var dead_fallback_names: std.StringHashMapUnmanaged(void) = .empty;
    defer dead_fallback_names.deinit(allocator);

    var changed = false;
    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .if_statement) continue;
        var caps: BufferCapabilitySet = .{};
        if (!collectNodeBufferCapabilityCondition(ast, node.data.ternary.a, &buffer_ctor_names, &caps)) continue;
        if (!caps.hasAll()) continue;
        collectDeadAlternateCjsExportIdentifiers(allocator, ast, node.data.ternary.c, &dead_fallback_names) catch {};
        const kept = singleBlockStatement(ast, node.data.ternary.b) orelse node.data.ternary.b;
        const kept_ni = @backingInt(kept);
        if (kept_ni >= ast.nodes.items.len) continue;
        ast.nodes.items[i] = ast.nodes.items[kept_ni];
        changed = true;
    }
    if (changed and dead_fallback_names.count() > 0) {
        removeDeadFallbackSetupStatements(ast, &dead_fallback_names, &buffer_ctor_names);
    }
    return changed;
}

/// Remove the dead alternate from supported branch shapes and return the
/// complete pre-edit node set that becomes unreachable. Keep the if and
/// consequent nodes in place so their graph identities and the surrounding
/// module's CJS statement shape remain stable. A direct `var` consequent does
/// not create a lexical scope, so its binding stays in the same function or
/// module scope. Lexical declarations and other statement shapes still use
/// full reanalysis.
pub fn foldNodeBufferCapabilityIfsRetainingGraph(
    allocator: std.mem.Allocator,
    ast: *Ast,
    removed_nodes: *std.ArrayListUnmanaged(NodeIndex),
    semantic: ?*const ModuleSemanticData,
    needs_semantic_reanalysis: *bool,
) !bool {
    return foldNodeBufferCapabilityIfsWithContext(allocator, ast, removed_nodes, needs_semantic_reanalysis, null, semantic, null);
}

/// The module owns the actual AST and semantic tables. Only this typed path
/// may retain a fallback function declaration after removing its export read.
pub fn foldNodeBufferCapabilityIfsForModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    ast: *Ast,
    removed_nodes: *std.ArrayListUnmanaged(NodeIndex),
    needs_semantic_reanalysis: *bool,
) !bool {
    if (module.ast == null or module.semantic == null or &module.ast.? != ast) return false;
    return foldNodeBufferCapabilityIfsWithContext(allocator, ast, removed_nodes, needs_semantic_reanalysis, module, if (module.semantic) |*sem| sem else null, null);
}

/// Producer-owned relation consumed by named-export reachability. It is held
/// only for one TreeShaker lifetime and never persisted in module/cache data.
pub const FoldedNodeBufferExport = struct {
    kind: enum { module_object, buffer_constructor },
    ast_owner: *const Ast,
    statement: NodeIndex,
    kept: NodeIndex,
    assignment: NodeIndex,
    module_reference: NodeIndex,
    module_symbol: u32,
    object_reference: NodeIndex,
    object_symbol: u32,
    buffer_object_symbol: u32,
};

pub fn foldNodeBufferCapabilityIfsForModuleWithExports(
    allocator: std.mem.Allocator,
    module: *const Module,
    ast: *Ast,
    removed_nodes: *std.ArrayListUnmanaged(NodeIndex),
    needs_semantic_reanalysis: *bool,
    exports: *std.ArrayListUnmanaged(FoldedNodeBufferExport),
) !bool {
    exports.clearRetainingCapacity();
    if (module.ast == null or module.semantic == null or &module.ast.? != ast) return false;
    return foldNodeBufferCapabilityIfsWithContext(allocator, ast, removed_nodes, needs_semantic_reanalysis, module, if (module.semantic) |*sem| sem else null, exports);
}

fn foldNodeBufferCapabilityIfsWithContext(
    allocator: std.mem.Allocator,
    ast: *Ast,
    removed_nodes: *std.ArrayListUnmanaged(NodeIndex),
    needs_semantic_reanalysis: *bool,
    module: ?*const Module,
    semantic: ?*const ModuleSemanticData,
    folded_exports: ?*std.ArrayListUnmanaged(FoldedNodeBufferExport),
) !bool {
    removed_nodes.clearRetainingCapacity();
    needs_semantic_reanalysis.* = false;

    var buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_names.deinit(allocator);
    try collectNodeBufferModuleObjectNames(allocator, ast, &buffer_names);
    if (buffer_names.count() == 0) return false;

    var buffer_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_ctor_names.deinit(allocator);
    try collectNodeBufferCtorNames(allocator, ast, &buffer_names, &buffer_ctor_names);
    if (buffer_ctor_names.count() == 0) return false;

    // The arena retains old pre-minify if/block copies. Only the current
    // program may authorize a semantic edit or provide an export fact.
    var reachable: ?std.DynamicBitSet = null;
    defer if (reachable) |*mask| mask.deinit();
    if (module != null or semantic != null) {
        _ = programNode(ast) orelse return false;
        const root = ast.transformed_root orelse @as(NodeIndex, @fromBackingInt(@as(u32, @intCast(ast.nodes.items.len - 1))));
        const nodes = try ast_walk.collectReachableNodeIndicesFrom(allocator, ast, root);
        defer allocator.free(nodes);
        var mask = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);
        for (nodes) |raw| mask.set(raw);
        reachable = mask;
    }

    var branches: std.ArrayListUnmanaged(BufferCapabilityFoldBranch) = .empty;
    defer branches.deinit(allocator);
    var dead_fallback_names: std.StringHashMapUnmanaged(void) = .empty;
    defer dead_fallback_names.deinit(allocator);

    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .if_statement) continue;
        if (reachable) |mask| if (!mask.isSet(i)) continue;
        var caps: BufferCapabilitySet = .{};
        if (!collectNodeBufferCapabilityCondition(ast, node.data.ternary.a, &buffer_ctor_names, &caps)) continue;
        if (!caps.hasAll()) continue;

        const kept = node.data.ternary.b;
        if (kept.isNone() or @backingInt(kept) >= ast.nodes.items.len) return false;
        const kept_node = ast.nodes.items[@backingInt(kept)];
        const kept_variable_kind: ?u32 = if (kept_node.tag == .variable_declaration) blk: {
            const kind_index = kept_node.data.extra;
            if (kind_index >= ast.extra_data.items.len) return false;
            break :blk ast.extra_data.items[kind_index];
        } else null;
        if (!isRetainableNodeBufferCapabilityBranch(kept_node.tag, kept_variable_kind)) return false;
        const alternate = node.data.ternary.c;
        var retained_var_initializer: ?NodeIndex = null;
        if (!alternate.isNone()) {
            if (@backingInt(alternate) >= ast.nodes.items.len) return false;
            const alternate_tag = ast.nodes.items[@backingInt(alternate)].tag;
            if (alternate_tag == .expression_statement or alternate_tag == .block_statement) {
                try collectDeadAlternateCjsExportIdentifiers(allocator, ast, alternate, &dead_fallback_names);
            } else if (alternate_tag == .variable_declaration and module != null) {
                retained_var_initializer = exactSimpleVarAlternateInitializer(
                    module.?,
                    ast,
                    @fromBackingInt(@intCast(i)),
                    alternate,
                ) orelse return false;
            } else return false;
        }
        try branches.append(allocator, .{
            .if_index = @fromBackingInt(@intCast(i)),
            .kept = kept,
            .alternate = alternate,
            .retained_var_initializer = retained_var_initializer,
        });
    }
    if (branches.items.len == 0) return false;
    // The retained graph edit removes the alternate's exact reference edges.
    // The TreeShaker separately seeds every top-level declaration and writer
    // in a dynamic root, so direct eval/with can still observe fallback
    // functions without forcing a semantic rebuild. Missing root scope data
    // cannot prove that the retained graph is complete and remains fail-closed.
    needs_semantic_reanalysis.* = if (semantic) |sem| sem.scopes.len == 0 else true;
    const requires_function_consumer = hasTopLevelDeadFallbackFunction(ast, &dead_fallback_names);

    var seen = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);
    defer seen.deinit();
    for (branches.items) |branch| {
        try appendSubtreeNodes(
            allocator,
            ast,
            branch.retained_var_initializer orelse branch.alternate,
            &seen,
            removed_nodes,
        );
    }

    var setup_statements: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer setup_statements.deinit(allocator);
    if (dead_fallback_names.count() > 0) {
        const root = programNode(ast) orelse return false;
        const list = root.data.list;
        if (list.start + list.len > ast.extra_data.items.len) return false;
        for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
            const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
            if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) continue;
            const stmt = ast.nodes.items[@backingInt(stmt_idx)];
            if (!isDeadFallbackSetupStatement(ast, stmt, &dead_fallback_names, &buffer_ctor_names)) continue;
            try setup_statements.append(allocator, stmt_idx);
            try appendSubtreeNodes(allocator, ast, stmt_idx, &seen, removed_nodes);
        }
    }

    if (requires_function_consumer) {
        if (module) |owner| {
            // No declaration is removed. Exact alternate reads determine the
            // surviving function identity; the retained graph updater removes
            // those reads and rebuilds statement liveness from its new counts.
            if (!try fallbackFunctionGraphIsStable(allocator, owner, ast, branches.items, setup_statements.items, &dead_fallback_names)) return false;
            needs_semantic_reanalysis.* = false;
        }
    }

    if (folded_exports) |out| {
        if (module) |owner| {
            for (branches.items) |branch| {
                if (foldedBufferExportAt(owner, ast, branch.if_index, branch.kept)) |fact| {
                    try out.append(allocator, fact);
                } else if (requires_function_consumer) return false;
            }
        }
    }

    // No AST write happens until all candidate node indexes are captured. This
    // keeps allocation or shape failures on the existing full-analysis path.
    for (branches.items) |branch| {
        if (branch.retained_var_initializer) |_| {
            const alternate = ast.nodes.items[@backingInt(branch.alternate)];
            const declaration_list_start = ast.extra_data.items[alternate.data.extra + 1];
            const declaration_raw = ast.extra_data.items[declaration_list_start];
            const declarator = ast.nodes.items[declaration_raw];
            ast.extra_data.items[declarator.data.extra + 2] = @backingInt(NodeIndex.none);
        } else {
            ast.nodes.items[@backingInt(branch.if_index)].data.ternary.c = .none;
        }
    }
    for (setup_statements.items) |stmt_idx| {
        const stmt = ast.nodes.items[@backingInt(stmt_idx)];
        ast.nodes.items[@backingInt(stmt_idx)] = .{
            .tag = .empty_statement,
            .span = stmt.span,
            .data = .{ .none = 0 },
        };
    }
    return true;
}

// Classify fallback declarations before requiring the exact function consumer.
fn hasTopLevelDeadFallbackFunction(
    ast: *const Ast,
    dead_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (dead_names.count() == 0) return false;
    const root = programNode(ast) orelse return true;
    const list = root.data.list;
    const extra_len = ast.extra_data.items.len;
    if (list.start > extra_len or list.len > extra_len - list.start) return true;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) return true;
        const stmt = ast.nodes.items[@backingInt(stmt_idx)];
        if (stmt.tag != .function_declaration) continue;
        const extra_base: usize = stmt.data.extra;
        const name_offset: usize = ast_mod.FunctionExtra.name;
        if (extra_base > extra_len or name_offset >= extra_len - extra_base) return true;
        const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[extra_base + name_offset]));
        if (name_idx.isNone() or @backingInt(name_idx) >= ast.nodes.items.len) return true;
        const name = ast.nodes.items[@backingInt(name_idx)];
        if (name.tag != .binding_identifier) return true;
        if (dead_names.contains(ast.getText(name.span))) return true;
    }
    return false;
}

fn isRetainableNodeBufferCapabilityBranch(tag: Node.Tag, variable_kind: ?u32) bool {
    return switch (tag) {
        .expression_statement, .block_statement => true,
        .variable_declaration => variable_kind != null and
            variable_kind.? == @backingInt(ast_mod.VariableDeclarationKind.@"var"),
        else => false,
    };
}

test "retained Node Buffer capability branch accepts only var declarations" {
    const var_kind: u32 = @backingInt(ast_mod.VariableDeclarationKind.@"var");
    try std.testing.expect(isRetainableNodeBufferCapabilityBranch(.expression_statement, null));
    try std.testing.expect(isRetainableNodeBufferCapabilityBranch(.block_statement, null));
    try std.testing.expect(isRetainableNodeBufferCapabilityBranch(.variable_declaration, var_kind));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(.variable_declaration, null));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(
        .variable_declaration,
        @backingInt(ast_mod.VariableDeclarationKind.let),
    ));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(
        .variable_declaration,
        @backingInt(ast_mod.VariableDeclarationKind.@"const"),
    ));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(
        .variable_declaration,
        @backingInt(ast_mod.VariableDeclarationKind.using),
    ));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(
        .variable_declaration,
        @backingInt(ast_mod.VariableDeclarationKind.await_using),
    ));
    try std.testing.expect(!isRetainableNodeBufferCapabilityBranch(.if_statement, null));
}

test "retained Node Buffer fold defers missing semantic scope data to full analysis" {
    const sources = [_][]const u8{
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer() { return 1; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function unrelated() { return 1; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function outer() { function SafeBuffer() { return 1; } }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\async function SafeBuffer() { return 1; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function* SafeBuffer() { return 1; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer(value) { return eval("value"); }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer() { return 1; }
        \\function SafeBuffer(value) { return value; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = Other; exports.Slow = SafeBuffer; }
        \\function Other() { return 1; }
        \\function SafeBuffer() { return 2; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer() { return 1; }
        \\function unrelated() { return 2; }
        ,
        \\function SafeBuffer() { return 1; }
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
        scanner.is_module = false;
        var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.configureFromExtension(".cjs");
        parser.is_module = false;
        _ = try parser.parse();
        var removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
        var needs_semantic_reanalysis = false;
        try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
            allocator,
            &parser.ast,
            &removed_nodes,
            null,
            &needs_semantic_reanalysis,
        ));
        try std.testing.expect(removed_nodes.items.len > 0);
        try std.testing.expect(needs_semantic_reanalysis);
    }
}

fn exactTopLevelVarInitializer(module: *const Module, ast: *const Ast, id: u32) ?NodeIndex {
    const sem = &(module.semantic orelse return null);
    if (id >= sem.symbols.items.len or sem.scopes.len == 0) return null;
    const symbol = sem.symbols.items[id];
    if (symbol.kind != .variable_var or symbol.synthetic_kind != null or symbol.write_count != 0) return null;
    const program_scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return null;
    if (program_scope >= sem.scopes.len) return null;
    if (symbol.scope_id.toIndex() != program_scope) {
        const wrapper = sem.scopes[program_scope].parent;
        if (wrapper.isNone() or symbol.scope_id != wrapper or wrapper.toIndex() >= sem.scopes.len or
            sem.scopes[wrapper.toIndex()].kind != .function or !sem.scopes[wrapper.toIndex()].parent.isNone()) return null;
    }
    const program = programNode(ast) orelse return null;
    const list = program.data.list;
    if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return null;
    var found: ?NodeIndex = null;
    for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
        if (raw >= ast.nodes.items.len) return null;
        const statement = ast.nodes.items[raw];
        if (statement.tag != .variable_declaration) continue;
        const extra = statement.data.extra;
        if (!ast.hasExtra(extra, 2)) return null;
        const start = ast.readExtra(extra, 1);
        const len = ast.readExtra(extra, 2);
        if (start > ast.extra_data.items.len or len > ast.extra_data.items.len - start) return null;
        for (ast.extra_data.items[start..][0..len]) |decl_raw| {
            if (decl_raw >= ast.nodes.items.len) return null;
            const declaration = ast.nodes.items[decl_raw];
            if (declaration.tag != .variable_declarator or !ast.hasExtra(declaration.data.extra, 2)) return null;
            const binding = ast.readExtraNode(declaration.data.extra, 0);
            if (binding.isNone() or @backingInt(binding) >= sem.symbol_ids.len) return null;
            if (sem.symbol_ids[@backingInt(binding)] != id) continue;
            const initializer = ast.readExtraNode(declaration.data.extra, 2);
            if (found != null or initializer.isNone() or @backingInt(initializer) >= ast.nodes.items.len) return null;
            found = initializer;
        }
    }
    return found;
}

fn exactNodeBufferObjectBinding(module: *const Module, ast: *const Ast, id: u32) bool {
    const sem = &(module.semantic orelse return false);
    const initializer = exactTopLevelVarInitializer(module, ast, id) orelse return false;
    if (!isRequireBufferCall(ast, initializer)) return false;
    const callee = ast.readExtraNode(ast.getNode(initializer).data.extra, 0);
    // This is the unresolved CommonJS host read, not a local `require`.
    return @backingInt(callee) < sem.symbol_ids.len and sem.symbol_ids[@backingInt(callee)] == null and sem.unresolved_references.contains("require");
}

fn exactBufferValueRead(module: *const Module, node: NodeIndex, id: u32, scope: u32) bool {
    const sem = &(module.semantic orelse return false);
    if (node.isNone() or @backingInt(node) >= sem.symbol_ids.len or sem.symbol_ids[@backingInt(node)] != id or
        scope >= sem.scopes.len) return false;
    var count: usize = 0;
    for (sem.references) |row| {
        if (row.node_index != node) continue;
        if (@backingInt(row.symbol_id) != id or row.scope_id.toIndex() != scope or
            !row.declaration_node_index.isNone() or
            !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .read = true }))) return false;
        count += 1;
    }
    return count == 1;
}

fn exactNodeBufferConstructorObject(module: *const Module, ast: *const Ast, id: u32) ?u32 {
    const sem = &(module.semantic orelse return null);
    const initializer = exactTopLevelVarInitializer(module, ast, id) orelse return null;
    const parts = staticMemberParts(ast, initializer) orelse return null;
    const property = ast.getNode(parts.property);
    if (property.tag != .identifier_reference or !std.mem.eql(u8, ast.identifierNameText(property), "Buffer")) return null;
    if (@backingInt(parts.object) >= sem.symbol_ids.len or ast.getNode(parts.object).tag != .identifier_reference) return null;
    const object = sem.symbol_ids[@backingInt(parts.object)] orelse return null;
    const scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return null;
    if (!exactBufferValueRead(module, parts.object, object, scope)) return null;
    return if (exactNodeBufferObjectBinding(module, ast, object)) object else null;
}

fn foldedBufferExportAt(module: *const Module, ast: *const Ast, statement: NodeIndex, kept: NodeIndex) ?FoldedNodeBufferExport {
    const sem = &(module.semantic orelse return null);
    if (statement.isNone() or @backingInt(statement) >= ast.nodes.items.len) return null;
    const branch = ast.getNode(statement);
    if (branch.tag != .if_statement or branch.data.ternary.b != kept) return null;
    const assignment_statement = singleBlockStatement(ast, kept) orelse kept;
    if (assignment_statement.isNone() or @backingInt(assignment_statement) >= ast.nodes.items.len) return null;
    const node = ast.getNode(assignment_statement);
    if (node.tag != .expression_statement) return null;
    const expression = node.data.unary.operand;
    if (expression.isNone() or @backingInt(expression) >= ast.nodes.items.len) return null;
    const assignment = ast.getNode(expression);
    if (assignment.tag != .assignment_expression or !exactBufferWrapperRoot(module, ast, assignment.data.binary.left)) return null;
    const module_object_export = isModuleExportsLhs(ast, assignment.data.binary.left);
    if (!module_object_export) {
        if (!isCjsNamedExportLhs(ast, assignment.data.binary.left)) return null;
        const parts = staticMemberParts(ast, assignment.data.binary.left) orelse return null;
        const property = ast.getNode(parts.property);
        if (property.tag != .identifier_reference or !std.mem.eql(u8, ast.identifierNameText(property), "Buffer")) return null;
    }
    const module_reference = memberRootNode(ast, assignment.data.binary.left) orelse return null;
    if (@backingInt(module_reference) >= sem.symbol_ids.len) return null;
    const module_symbol = sem.symbol_ids[@backingInt(module_reference)] orelse return null;
    if (module_object_export) {
        const expected_module = module.cjs_wrapper_module_parameter_symbol orelse return null;
        if (module_symbol != @backingInt(expected_module)) return null;
    }
    const object = assignment.data.binary.right;
    if (object.isNone() or @backingInt(object) >= ast.nodes.items.len or @backingInt(object) >= sem.symbol_ids.len or
        ast.getNode(object).tag != .identifier_reference) return null;
    const object_symbol = sem.symbol_ids[@backingInt(object)] orelse return null;
    const program_scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return null;
    if (program_scope >= sem.scopes.len) return null;
    const use_scope = if (ast.getNode(kept).tag == .block_statement) blk: {
        const scope = sem.scope_owner_map.get(@backingInt(kept)) orelse return null;
        if (scope >= sem.scopes.len or sem.scopes[scope].kind != .block or
            sem.scopes[scope].parent.toIndex() != program_scope) return null;
        break :blk scope;
    } else program_scope;
    if (!exactBufferValueRead(module, object, object_symbol, use_scope)) return null;
    const buffer_object = if (module_object_export) blk: {
        if (!exactNodeBufferObjectBinding(module, ast, object_symbol)) return null;
        break :blk object_symbol;
    } else exactNodeBufferConstructorObject(module, ast, object_symbol) orelse return null;
    return .{ .kind = if (module_object_export) .module_object else .buffer_constructor, .ast_owner = ast, .statement = statement, .kept = kept, .assignment = expression, .module_reference = module_reference, .module_symbol = module_symbol, .object_reference = object, .object_symbol = object_symbol, .buffer_object_symbol = buffer_object };
}

pub fn foldedNodeBufferExportIsCurrent(module: *const Module, ast: *const Ast, statement: NodeIndex, fact: FoldedNodeBufferExport) bool {
    if (fact.ast_owner != ast or fact.statement != statement or statement.isNone() or @backingInt(statement) >= ast.nodes.items.len) return false;
    const node = ast.getNode(statement);
    if (node.tag != .if_statement or !node.data.ternary.c.isNone() or node.data.ternary.b != fact.kept) return false;
    const current = foldedBufferExportAt(module, ast, statement, fact.kept) orelse return false;
    return current.kind == fact.kind and current.buffer_object_symbol == fact.buffer_object_symbol and
        current.assignment == fact.assignment and current.module_reference == fact.module_reference and
        current.module_symbol == fact.module_symbol and current.object_reference == fact.object_reference and current.object_symbol == fact.object_symbol;
}

fn memberRootNode(ast: *const Ast, start: NodeIndex) ?NodeIndex {
    var current = start;
    var fuel = ast.nodes.items.len;
    while (fuel > 0) : (fuel -= 1) {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return null;
        const node = ast.getNode(current);
        if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) return current;
        if (node.tag != .static_member_expression) return null;
        current = (staticMemberParts(ast, current) orelse return null).object;
    }
    return null;
}

fn exactBufferWrapperRoot(module: *const Module, ast: *const Ast, lhs: NodeIndex) bool {
    const sem = &(module.semantic orelse return false);
    const root = memberRootNode(ast, lhs) orelse return false;
    const raw = @backingInt(root);
    if (raw >= sem.symbol_ids.len) return false;
    const id = sem.symbol_ids[raw] orelse return false;
    if (id >= sem.symbols.items.len) return false;
    const symbol = sem.symbols.items[id];
    if (symbol.kind != .parameter) return false;
    if (module.cjs_wrapper_exports_parameter_symbol) |expected| {
        if (@backingInt(expected) == id and symbol.synthetic_kind == .cjs_wrapper_exports_parameter) return true;
    }
    if (module.cjs_wrapper_module_parameter_symbol) |expected| {
        if (@backingInt(expected) == id and symbol.synthetic_kind == .cjs_wrapper_module_parameter) return true;
    }
    return false;
}

fn collectExactFallbackReadIds(
    allocator: std.mem.Allocator,
    module: *const Module,
    ast: *const Ast,
    statement: NodeIndex,
    expected_scope: u32,
    ids: *std.AutoHashMapUnmanaged(u32, void),
) !bool {
    if (statement.isNone() or @backingInt(statement) >= ast.nodes.items.len) return false;
    const node = ast.getNode(statement);
    if (node.tag == .block_statement) {
        const list = node.data.list;
        if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return false;
        const sem = &module.semantic.?;
        const block_scope = sem.scope_owner_map.get(@backingInt(statement)) orelse return false;
        if (block_scope >= sem.scopes.len or sem.scopes[block_scope].kind != .block or
            sem.scopes[block_scope].parent != @as(@import("../../semantic/scope.zig").ScopeId, @fromBackingInt(expected_scope))) return false;
        for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
            if (!try collectExactFallbackReadIds(allocator, module, ast, @fromBackingInt(raw), block_scope, ids)) return false;
        }
        return true;
    }
    if (node.tag != .expression_statement) return false;
    const expression = node.data.unary.operand;
    if (expression.isNone() or @backingInt(expression) >= ast.nodes.items.len) return false;
    const assignment = ast.getNode(expression);
    if (assignment.tag != .assignment_expression or !isCjsNamedExportLhs(ast, assignment.data.binary.left) or
        !exactBufferWrapperRoot(module, ast, assignment.data.binary.left)) return false;
    const value = assignment.data.binary.right;
    if (value.isNone() or @backingInt(value) >= ast.nodes.items.len or ast.getNode(value).tag != .identifier_reference) return false;
    const sem = &module.semantic.?;
    if (@backingInt(value) >= sem.symbol_ids.len) return false;
    const id = sem.symbol_ids[@backingInt(value)] orelse return false;
    if (id >= sem.symbols.items.len) return false;
    var reads: usize = 0;
    for (sem.references) |row| {
        if (row.node_index != value) continue;
        if (@backingInt(row.symbol_id) != id or !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .read = true })) or
            row.scope_id.isNone() or row.scope_id.toIndex() >= sem.scopes.len or row.scope_id.toIndex() != expected_scope) return false;
        var scope = row.scope_id;
        var visible = false;
        var fuel = sem.scopes.len;
        while (!scope.isNone() and scope.toIndex() < sem.scopes.len and fuel > 0) : (fuel -= 1) {
            if (scope == sem.symbols.items[id].scope_id) {
                visible = true;
                break;
            }
            scope = sem.scopes[scope.toIndex()].parent;
        }
        if (!visible) return false;
        reads += 1;
    }
    if (reads != 1) return false;
    try ids.put(allocator, id, {});
    return true;
}

/// The exceptional old path is needed only for a function referenced by the
/// erased fallback export. Prove that actual edge before changing the AST.
/// Its declaration, body, local scopes and all other uses remain untouched.
fn fallbackFunctionGraphIsStable(
    allocator: std.mem.Allocator,
    module: *const Module,
    ast: *const Ast,
    branches: []const BufferCapabilityFoldBranch,
    setup_statements: []const NodeIndex,
    dead_names: *const std.StringHashMapUnmanaged(void),
) !bool {
    const sem = &(module.semantic orelse return false);
    if (module.wrap_kind != .cjs or sem.scopes.len == 0) return false;
    for (sem.scopes) |scope| if (scope.subtree_has_direct_eval) return false;
    // A with environment may redirect a source read without a static SID.
    for (ast.nodes.items) |node| if (node.tag == .with_statement) return false;
    var selected: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer selected.deinit(allocator);
    const program_scope = sem.scope_owner_map.get(@intCast(ast.nodes.items.len - 1)) orelse return false;
    if (program_scope >= sem.scopes.len or (sem.scopes[program_scope].kind != .global and sem.scopes[program_scope].kind != .module)) return false;
    for (branches) |branch| {
        if (branch.alternate.isNone()) continue;
        if (!try collectExactFallbackReadIds(allocator, module, ast, branch.alternate, program_scope, &selected)) return false;
    }
    if (selected.count() == 0) return false;
    var declarations: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer declarations.deinit(allocator);
    var function_declaration_counts: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer function_declaration_counts.deinit(allocator);
    const root = programNode(ast) orelse return false;
    const list = root.data.list;
    if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return false;
    for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
        const node = ast.nodes.items[raw];
        if (node.tag != .function_declaration) continue;
        const binding = ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
        if (binding.isNone() or @backingInt(binding) >= sem.symbol_ids.len or ast.getNode(binding).tag != .binding_identifier) return false;
        const id = sem.symbol_ids[@backingInt(binding)] orelse return false;
        // Legacy spelling detection can request a conservative boundary, but
        // only the actual alternate read SID may authorize this declaration.
        if (!selected.contains(id)) {
            if (dead_names.contains(ast.getText(ast.getNode(binding).span))) return false;
            continue;
        }
        if (id >= sem.symbols.items.len) return false;
        const symbol = sem.symbols.items[id];
        if (!functionDeclarationKindMatches(ast, node, symbol.kind) or symbol.synthetic_kind != null or symbol.isExported() or
            symbol.decl_flags.is_annex_b_function or symbol.scope_id.toIndex() != program_scope or symbol.write_count != 0) return false;
        const function_scope = sem.scope_owner_map.get(raw) orelse return false;
        if (function_scope >= sem.scopes.len or sem.scopes[function_scope].kind != .function or
            sem.scopes[function_scope].parent != symbol.scope_id) return false;
        const first_declaration_for_symbol = !declarations.contains(id);
        var anchored: usize = 0;
        var reads: usize = 0;
        for (sem.references) |row| {
            if (@backingInt(row.symbol_id) != id) continue;
            if (row.flags.declare) {
                const declaration_node: NodeIndex = @fromBackingInt(@intCast(raw));
                const belongs_to_this_declaration = row.node_index == binding or
                    row.declaration_node_index == binding or row.declaration_node_index == declaration_node;
                if (!belongs_to_this_declaration) continue;
                if (!std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .declare = true })) or
                    row.scope_id != symbol.scope_id) return false;
                anchored += 1;
            } else if (first_declaration_for_symbol) {
                if (!std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .read = true })) or row.node_index.isNone() or @backingInt(row.node_index) >= sem.symbol_ids.len or
                    sem.symbol_ids[@backingInt(row.node_index)] != id) return false;
                reads += 1;
            }
        }
        if (anchored != 1) return false;
        if (first_declaration_for_symbol) {
            if (reads != symbol.reference_count) return false;
            try declarations.put(allocator, id, {});
        }
        const declaration_count = try function_declaration_counts.getOrPut(allocator, id);
        if (!declaration_count.found_existing) declaration_count.value_ptr.* = 0;
        if (declaration_count.value_ptr.* == std.math.maxInt(u32)) return false;
        declaration_count.value_ptr.* += 1;
    }
    if (declarations.count() != selected.count()) return false;
    var selected_ids = selected.keyIterator();
    while (selected_ids.next()) |selected_id| {
        const expected_declarations = function_declaration_counts.get(selected_id.*) orelse return false;
        var actual_declarations: u32 = 0;
        for (sem.references) |row| {
            if (@backingInt(row.symbol_id) != selected_id.* or !row.flags.declare) continue;
            if (actual_declarations == std.math.maxInt(u32)) return false;
            actual_declarations += 1;
        }
        if (actual_declarations != expected_declarations) return false;
    }
    for (setup_statements) |statement| {
        const node = ast.getNode(statement);
        if (node.tag != .expression_statement) return false;
        const expression = ast.getNode(node.data.unary.operand);
        // Copy-call setup is an explicit boundary until its argument and
        // callee side effects have an equally exact contract.
        if (expression.tag != .assignment_expression) return false;
        const root_node = memberRootNode(ast, expression.data.binary.left) orelse return false;
        if (@backingInt(root_node) >= sem.symbol_ids.len) return false;
        const id = sem.symbol_ids[@backingInt(root_node)] orelse return false;
        if (!declarations.contains(id)) return false;
    }
    return true;
}

fn functionDeclarationKindMatches(ast: *const Ast, node: Node, symbol_kind: SymbolKind) bool {
    if (node.tag != .function_declaration or !ast.hasExtra(node.data.extra, ast_mod.FunctionExtra.flags)) return false;
    const flags = ast.readExtra(node.data.extra, ast_mod.FunctionExtra.flags);
    const expected_kind: SymbolKind = if (flags & ast_mod.FunctionFlags.is_async != 0 and flags & ast_mod.FunctionFlags.is_generator != 0)
        .async_generator_decl
    else if (flags & ast_mod.FunctionFlags.is_async != 0)
        .async_function_decl
    else if (flags & ast_mod.FunctionFlags.is_generator != 0)
        .generator_decl
    else
        .function_decl;
    return symbol_kind == expected_kind;
}

test "retained Node Buffer fold keeps the graph when fallback function reads are removed" {
    const cases = [_]struct {
        source: []const u8,
        has_direct_eval: bool,
        expected_reanalysis: bool,
    }{
        .{
            .source =
            \\var buffer = require("buffer"); var B = buffer.Buffer;
            \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
            \\else { exports.Buffer = SafeBuffer; }
            \\function SafeBuffer() { return 1; }
            ,
            .has_direct_eval = false,
            .expected_reanalysis = false,
        },
        .{
            .source =
            \\var buffer = require("buffer"); var B = buffer.Buffer;
            \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
            \\else { exports.Buffer = Missing; }
            \\function unrelated() { return 1; }
            \\eval("unrelated");
            ,
            .has_direct_eval = true,
            .expected_reanalysis = false,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, case.source);
        scanner.is_module = false;
        var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
        parser.configureFromExtension(".cjs");
        parser.is_module = false;
        _ = try parser.parse();

        const root_scope: Scope = .{
            .parent = .none,
            .kind = .global,
            .is_strict = false,
            .subtree_has_direct_eval = case.has_direct_eval,
        };
        const scopes = [_]Scope{root_scope};
        const semantic: ModuleSemanticData = .{
            .symbols = .empty,
            .scopes = &scopes,
            .scope_maps = &.{},
            .exported_names = .empty,
            .symbol_ids = &.{},
            .unresolved_references = .empty,
        };
        var removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
        var needs_semantic_reanalysis = false;
        try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
            allocator,
            &parser.ast,
            &removed_nodes,
            &semantic,
            &needs_semantic_reanalysis,
        ));
        try std.testing.expectEqual(case.expected_reanalysis, needs_semantic_reanalysis);
    }
}

test "retained Node Buffer fold fails closed when semantic scope data is unavailable" {
    const source =
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        \\else { exports.Buffer = SafeBuffer; }
        \\var SafeBuffer = function() { return 1; };
        \\function unrelated() { return 2; }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
    scanner.is_module = false;
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    parser.is_module = false;
    _ = try parser.parse();
    var removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var needs_semantic_reanalysis = false;
    try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
        allocator,
        &parser.ast,
        &removed_nodes,
        null,
        &needs_semantic_reanalysis,
    ));
    try std.testing.expect(needs_semantic_reanalysis);

    const empty_semantic: ModuleSemanticData = .{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    var empty_scope_scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
    empty_scope_scanner.is_module = false;
    var empty_scope_parser = @import("../../parser/parser.zig").Parser.init(allocator, &empty_scope_scanner);
    empty_scope_parser.configureFromExtension(".cjs");
    empty_scope_parser.is_module = false;
    _ = try empty_scope_parser.parse();
    var empty_scope_removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var empty_scope_needs_semantic_reanalysis = false;
    try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
        allocator,
        &empty_scope_parser.ast,
        &empty_scope_removed_nodes,
        &empty_semantic,
        &empty_scope_needs_semantic_reanalysis,
    ));
    try std.testing.expect(empty_scope_needs_semantic_reanalysis);
}

const BufferCapabilityFoldBranch = struct {
    if_index: NodeIndex,
    kept: NodeIndex,
    alternate: NodeIndex,
    /// Preserve the hoisted var declaration while removing its dead branch
    /// initializer. Other shapes remove the full alternate subtree.
    retained_var_initializer: ?NodeIndex = null,
};

/// Keep one direct else-var alternate on the same graph. Clearing its
/// initializer preserves the var binding's hoisted declaration and removes
/// only the exact identifier edge from the dead assignment.
fn exactSimpleVarAlternateInitializer(
    module: *const Module,
    ast: *const Ast,
    if_index: NodeIndex,
    alternate: NodeIndex,
) ?NodeIndex {
    if (module.wrap_kind != .cjs or module.ast == null or &module.ast.? != ast) return null;
    const semantic = &(module.semantic orelse return null);
    if (semantic.scopes.len == 0 or alternate.isNone() or @backingInt(alternate) >= ast.nodes.items.len) return null;
    if (ast.nodes.items.len == 0) return null;
    const root: NodeIndex = ast.transformed_root orelse @fromBackingInt(
        @as(u32, @intCast(ast.nodes.items.len - 1)),
    );
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len) return null;
    const root_node = ast.getNode(root);
    const root_scope = semantic.scope_owner_map.get(@backingInt(root)) orelse return null;
    if (root_scope >= semantic.scopes.len or
        (semantic.scopes[root_scope].kind != .global and semantic.scopes[root_scope].kind != .module) or
        root_node.tag != .program or root_node.data.list.start > ast.extra_data.items.len or
        root_node.data.list.len > ast.extra_data.items.len - root_node.data.list.start) return null;
    var top_level_if_count: usize = 0;
    for (ast.extra_data.items[root_node.data.list.start..][0..root_node.data.list.len]) |raw| {
        if (raw == @backingInt(if_index)) top_level_if_count += 1;
    }
    if (top_level_if_count != 1) return null;
    const declaration = ast.nodes.items[@backingInt(alternate)];
    if (declaration.tag != .variable_declaration or !ast.hasExtra(declaration.data.extra, 2) or
        ast.readExtra(declaration.data.extra, 0) != @backingInt(ast_mod.VariableDeclarationKind.@"var")) return null;
    const list_start = ast.readExtra(declaration.data.extra, 1);
    const list_len = ast.readExtra(declaration.data.extra, 2);
    if (list_len != 1 or list_start >= ast.extra_data.items.len or list_len > ast.extra_data.items.len - list_start) return null;
    const declarator_raw = ast.extra_data.items[list_start];
    if (declarator_raw >= ast.nodes.items.len) return null;
    const declarator = ast.nodes.items[declarator_raw];
    if (declarator.tag != .variable_declarator or !ast.hasExtra(declarator.data.extra, 2)) return null;
    const binding = ast.readExtraNode(declarator.data.extra, 0);
    const initializer = ast.readExtraNode(declarator.data.extra, 2);
    if (binding.isNone() or @backingInt(binding) >= semantic.symbol_ids.len or
        ast.getNode(binding).tag != .binding_identifier or initializer.isNone() or
        @backingInt(initializer) >= semantic.symbol_ids.len or
        ast.getNode(initializer).tag != .identifier_reference or
        semantic.node_scope_provenance.contains(initializer)) return null;
    const initializer_raw = @backingInt(initializer);
    if (semantic.class_self_symbol_map.contains(initializer_raw) or
        semantic.namespace_member_owners.contains(initializer_raw) or
        semantic.namespace_declaration_owners.contains(initializer_raw) or
        semantic.scope_owner_map.contains(initializer_raw)) return null;

    if (module.transform_cache) |cache| {
        for (cache.helper_ref_nodes) |raw| if (raw == initializer_raw) return null;
        for (cache.explicit_global_ref_nodes) |raw| if (raw == initializer_raw) return null;
        for (cache.opaque_define_scope_owner_nodes) |raw| if (raw == initializer_raw) return null;
        for (cache.preserved_class_name_nodes) |raw| if (raw == initializer_raw) return null;
        for (cache.worklet_factory_local_bindings) |binding_row| {
            if (binding_row.node_index == initializer_raw) return null;
        }
        for (cache.post_graph_output_bindings) |binding_row| {
            if (binding_row.node_index == initializer_raw) return null;
        }
        var temp_bindings = cache.destructuring_temp_bindings.keyIterator();
        while (temp_bindings.next()) |raw| if (raw.* == initializer_raw) return null;
    }
    if (module.tla_iife_stmt) |raw| if (raw == initializer_raw) return null;
    if (module.tla_promise_reference) |promise_ref| {
        if (promise_ref.binding_node_index == initializer_raw) return null;
    }

    const binding_id = semantic.symbol_ids[@backingInt(binding)] orelse return null;
    if (binding_id >= semantic.symbols.items.len) return null;
    const binding_symbol = semantic.symbols.items[binding_id];
    if (binding_symbol.kind != .variable_var or binding_symbol.synthetic_kind != null or
        binding_symbol.scope_id.toIndex() != root_scope) return null;
    var declaration_rows: usize = 0;
    for (semantic.references) |row| {
        if (!row.flags.declare or row.declaration_node_index != binding) continue;
        if (@backingInt(row.symbol_id) != binding_id or
            !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .declare = true })) or
            row.scope_id != binding_symbol.scope_id) return null;
        declaration_rows += 1;
    }
    if (declaration_rows != 1) return null;

    const initializer_id = semantic.symbol_ids[@backingInt(initializer)] orelse return null;
    if (initializer_id >= semantic.symbols.items.len) return null;
    const initializer_symbol = semantic.symbols.items[initializer_id];
    if (initializer_symbol.scope_id.toIndex() != root_scope or
        initializer_symbol.reference_count == std.math.maxInt(u32)) return null;
    var observed_initializer_edges: u32 = 0;
    for (semantic.references) |row| {
        if (@backingInt(row.symbol_id) != initializer_id or row.flags.declare) continue;
        if (observed_initializer_edges == std.math.maxInt(u32)) return null;
        observed_initializer_edges += 1;
    }
    if (observed_initializer_edges != initializer_symbol.reference_count) return null;
    var initializer_rows: usize = 0;
    for (semantic.references) |row| {
        if (row.node_index != initializer) continue;
        if (@backingInt(row.symbol_id) != initializer_id or
            !std.meta.eql(row.flags, @as(@import("../../semantic/symbol.zig").ReferenceFlags, .{ .read = true })) or
            !row.declaration_node_index.isNone() or @backingInt(row.scope_id) != root_scope) return null;
        initializer_rows += 1;
    }
    if (initializer_rows != 1) return null;
    return initializer;
}

fn appendSingleNode(
    allocator: std.mem.Allocator,
    node_index: NodeIndex,
    seen: *std.DynamicBitSet,
    out: *std.ArrayListUnmanaged(NodeIndex),
    node_count: usize,
) !void {
    if (node_index.isNone()) return error.InvalidRemovedNode;
    const raw = @backingInt(node_index);
    if (raw >= node_count) return error.InvalidRemovedNode;
    if (seen.isSet(raw)) return;
    seen.set(raw);
    try out.append(allocator, node_index);
}

fn appendSubtreeNodes(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    root: NodeIndex,
    seen: *std.DynamicBitSet,
    out: *std.ArrayListUnmanaged(NodeIndex),
) !void {
    if (root.isNone()) return;
    var stack: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone()) continue;
        const raw = @backingInt(idx);
        if (raw >= ast.nodes.items.len) return error.InvalidRemovedNode;
        if (seen.isSet(raw)) continue;
        seen.set(raw);
        try out.append(allocator, idx);
        var children = ast_walk.children(ast, ast.nodes.items[raw]);
        while (children.next()) |child| try stack.append(allocator, child);
    }
}

const BufferCapabilitySet = struct {
    from: bool = false,
    alloc: bool = false,
    alloc_unsafe: bool = false,
    alloc_unsafe_slow: bool = false,

    fn add(self: *BufferCapabilitySet, name: []const u8) bool {
        if (std.mem.eql(u8, name, "from")) {
            self.from = true;
            return true;
        }
        if (std.mem.eql(u8, name, "alloc")) {
            self.alloc = true;
            return true;
        }
        if (std.mem.eql(u8, name, "allocUnsafe")) {
            self.alloc_unsafe = true;
            return true;
        }
        if (std.mem.eql(u8, name, "allocUnsafeSlow")) {
            self.alloc_unsafe_slow = true;
            return true;
        }
        return false;
    }

    fn hasAll(self: BufferCapabilitySet) bool {
        return self.from and self.alloc and self.alloc_unsafe and self.alloc_unsafe_slow;
    }
};

fn collectNodeBufferCapabilityCondition(
    ast: *const Ast,
    idx: NodeIndex,
    ctor_names: *const std.StringHashMapUnmanaged(void),
    caps: *BufferCapabilitySet,
) bool {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[@backingInt(idx)];
    switch (node.tag) {
        .parenthesized_expression => return collectNodeBufferCapabilityCondition(ast, node.data.unary.operand, ctor_names, caps),
        .logical_expression => {
            if (@as(Kind, @fromBackingInt(@intCast(node.data.binary.flags))) != .amp2) return false;
            return collectNodeBufferCapabilityCondition(ast, node.data.binary.left, ctor_names, caps) and
                collectNodeBufferCapabilityCondition(ast, node.data.binary.right, ctor_names, caps);
        },
        .static_member_expression => {
            const parts = staticMemberParts(ast, idx) orelse return false;
            const obj = ast.nodes.items[@backingInt(parts.object)];
            if (obj.tag != .identifier_reference) return false;
            if (!ctor_names.contains(ast.getText(obj.span))) return false;
            const prop = ast.nodes.items[@backingInt(parts.property)];
            if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
            return caps.add(ast.getText(prop.span));
        },
        else => return false,
    }
}

fn singleBlockStatement(ast: *const Ast, idx: NodeIndex) ?NodeIndex {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[@backingInt(idx)];
    if (node.tag != .block_statement) return null;
    const list = node.data.list;
    if (list.len != 1) return null;
    if (list.start >= ast.extra_data.items.len) return null;
    return @fromBackingInt(@intCast(ast.extra_data.items[list.start]));
}

fn collectDeadAlternateCjsExportIdentifiers(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    idx: NodeIndex,
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return;
    const node = ast.nodes.items[@backingInt(idx)];
    if (node.tag == .block_statement) {
        const list = node.data.list;
        if (list.start + list.len > ast.extra_data.items.len) return;
        for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
            try collectDeadAlternateCjsExportIdentifiers(allocator, ast, @fromBackingInt(@intCast(raw)), out);
        }
        return;
    }
    if (node.tag != .expression_statement) return;
    const expr_idx = node.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag != .assignment_expression) return;
    if (!isCjsNamedExportLhs(ast, expr.data.binary.left)) return;
    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @backingInt(rhs_idx) >= ast.nodes.items.len) return;
    const rhs = ast.nodes.items[@backingInt(rhs_idx)];
    if (rhs.tag != .identifier_reference) return;
    try out.put(allocator, ast.getText(rhs.span), {});
}

fn removeDeadFallbackSetupStatements(
    ast: *Ast,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) continue;
        const stmt = ast.nodes.items[@backingInt(stmt_idx)];
        if (!isDeadFallbackSetupStatement(ast, stmt, dead_names, buffer_ctor_names)) continue;
        ast.nodes.items[@backingInt(stmt_idx)] = .{
            .tag = .empty_statement,
            .span = stmt.span,
            .data = .{ .none = 0 },
        };
    }
}

fn isDeadFallbackSetupStatement(
    ast: *const Ast,
    stmt: Node,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (stmt.tag != .expression_statement) return false;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag == .assignment_expression) {
        const root = staticMemberRootIdentifier(ast, expr.data.binary.left) orelse return false;
        return dead_names.contains(root);
    }
    if (expr.tag == .call_expression) {
        return isDeadFallbackCopyCall(ast, expr, dead_names, buffer_ctor_names);
    }
    return false;
}

fn isDeadFallbackCopyCall(
    ast: *const Ast,
    call: Node,
    dead_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) bool {
    const e = call.data.extra;
    if (!ast.hasExtra(e, 2)) return false;
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 2 or args_start + args_len > ast.extra_data.items.len) return false;
    const first_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start]));
    const second_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start + 1]));
    if (first_idx.isNone() or second_idx.isNone()) return false;
    if (@backingInt(first_idx) >= ast.nodes.items.len or @backingInt(second_idx) >= ast.nodes.items.len) return false;
    const first = ast.nodes.items[@backingInt(first_idx)];
    const second = ast.nodes.items[@backingInt(second_idx)];
    if (first.tag != .identifier_reference or second.tag != .identifier_reference) return false;
    return buffer_ctor_names.contains(ast.getText(first.span)) and dead_names.contains(ast.getText(second.span));
}

fn staticMemberRootIdentifier(ast: *const Ast, idx: NodeIndex) ?[]const u8 {
    var current = idx;
    while (true) {
        const parts = staticMemberParts(ast, current) orelse return null;
        const obj = ast.nodes.items[@backingInt(parts.object)];
        if (obj.tag == .identifier_reference) return ast.getText(obj.span);
        current = parts.object;
    }
}

pub fn collectNodeBufferModuleObjectNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        try collectVarNamesMatchingInit(allocator, ast, stmt_idx, out, isRequireBufferCall);
    }
}

pub fn collectNodeBufferCtorNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    buffer_names: *const std.StringHashMapUnmanaged(void),
    out: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const root = programNode(ast) orelse return;
    const list = root.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_stmt| {
        const stmt_idx: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
        if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) continue;
        const stmt = ast.nodes.items[@backingInt(stmt_idx)];
        if (stmt.tag != .variable_declaration) continue;
        const e = stmt.data.extra;
        if (!ast.hasExtra(e, 2)) continue;
        const start = ast.readExtra(e, 1);
        const len = ast.readExtra(e, 2);
        if (start + len > ast.extra_data.items.len) continue;
        for (ast.extra_data.items[start .. start + len]) |raw_decl| {
            const decl_idx: NodeIndex = @fromBackingInt(@intCast(raw_decl));
            if (decl_idx.isNone() or @backingInt(decl_idx) >= ast.nodes.items.len) continue;
            const decl = ast.nodes.items[@backingInt(decl_idx)];
            if (decl.tag != .variable_declarator) continue;
            const de = decl.data.extra;
            if (!ast.hasExtra(de, 2)) continue;
            const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(de, 0)));
            const init_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(de, 2)));
            if (name_idx.isNone() or @backingInt(name_idx) >= ast.nodes.items.len) continue;
            if (!isNodeBufferCtorRead(ast, init_idx, buffer_names)) continue;
            const name = ast.nodes.items[@backingInt(name_idx)];
            if (name.tag == .identifier_reference or name.tag == .binding_identifier or name.tag == .assignment_target_identifier) {
                try out.put(allocator, ast.getText(name.span), {});
            }
        }
    }
}

fn collectVarNamesMatchingInit(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmt_idx: NodeIndex,
    out: *std.StringHashMapUnmanaged(void),
    comptime predicate: fn (*const Ast, NodeIndex) bool,
) std.mem.Allocator.Error!void {
    if (stmt_idx.isNone() or @backingInt(stmt_idx) >= ast.nodes.items.len) return;
    const stmt = ast.nodes.items[@backingInt(stmt_idx)];
    if (stmt.tag != .variable_declaration) return;
    const e = stmt.data.extra;
    if (!ast.hasExtra(e, 2)) return;
    const start = ast.readExtra(e, 1);
    const len = ast.readExtra(e, 2);
    if (start + len > ast.extra_data.items.len) return;
    for (ast.extra_data.items[start .. start + len]) |raw_decl| {
        const decl_idx: NodeIndex = @fromBackingInt(@intCast(raw_decl));
        if (decl_idx.isNone() or @backingInt(decl_idx) >= ast.nodes.items.len) continue;
        const decl = ast.nodes.items[@backingInt(decl_idx)];
        if (decl.tag != .variable_declarator) continue;
        const de = decl.data.extra;
        if (!ast.hasExtra(de, 2)) continue;
        const name_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(de, 0)));
        const init_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(de, 2)));
        if (!predicate(ast, init_idx)) continue;
        if (name_idx.isNone() or @backingInt(name_idx) >= ast.nodes.items.len) continue;
        const name = ast.nodes.items[@backingInt(name_idx)];
        if (name.tag == .identifier_reference or name.tag == .binding_identifier or name.tag == .assignment_target_identifier) {
            try out.put(allocator, ast.getText(name.span), {});
        }
    }
}

fn programNode(ast: *const Ast) ?Node {
    if (ast.nodes.items.len == 0) return null;
    const root = ast.nodes.items[ast.nodes.items.len - 1];
    if (root.tag != .program) return null;
    return root;
}

fn isRequireBufferCall(ast: *const Ast, idx: NodeIndex) bool {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[@backingInt(idx)];
    if (node.tag != .call_expression) return false;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 2)) return false;
    const callee_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(e, 0)));
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.nodes.items[@backingInt(callee_idx)];
    if (callee.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(callee.span), "require")) return false;
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1 or args_start >= ast.extra_data.items.len) return false;
    const arg_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start]));
    if (arg_idx.isNone() or @backingInt(arg_idx) >= ast.nodes.items.len) return false;
    const arg = ast.nodes.items[@backingInt(arg_idx)];
    if (arg.tag != .string_literal) return false;
    const spec = ast_mod.Ast.stripStringQuotes(ast.getText(arg.span));
    return std.mem.eql(u8, spec, "buffer") or std.mem.eql(u8, spec, "node:buffer");
}

fn isNodeBufferCtorRead(
    ast: *const Ast,
    idx: NodeIndex,
    buffer_names: *const std.StringHashMapUnmanaged(void),
) bool {
    const parts = staticMemberParts(ast, idx) orelse return false;
    const obj = ast.nodes.items[@backingInt(parts.object)];
    const prop = ast.nodes.items[@backingInt(parts.property)];
    if (obj.tag != .identifier_reference) return false;
    if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
    return buffer_names.contains(ast.getText(obj.span)) and std.mem.eql(u8, ast.getText(prop.span), "Buffer");
}

pub fn isModuleExportsAssignedNodeBufferObject(
    ast: *const Ast,
    stmt_index: NodeIndex,
    buffer_names: *const std.StringHashMapUnmanaged(void),
    buffer_ctor_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (stmt_index.isNone() or @backingInt(stmt_index) >= ast.nodes.items.len) return false;
    const stmt = ast.nodes.items[@backingInt(stmt_index)];
    if (stmt.tag == .block_statement) {
        const inner = singleBlockStatement(ast, stmt_index) orelse return false;
        return isModuleExportsAssignedNodeBufferObject(ast, inner, buffer_names, buffer_ctor_names);
    }
    if (stmt.tag == .if_statement) {
        const branch = stmt.data.ternary;
        if (!branch.c.isNone()) return false;
        var capabilities: BufferCapabilitySet = .{};
        if (!collectNodeBufferCapabilityCondition(ast, branch.a, buffer_ctor_names, &capabilities) or
            !capabilities.hasAll()) return false;
        return isModuleExportsAssignedNodeBufferObject(ast, branch.b, buffer_names, buffer_ctor_names);
    }
    if (stmt.tag != .expression_statement) return false;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag != .assignment_expression) return false;
    const op: Kind = @fromBackingInt(@intCast(expr.data.binary.flags));
    if (op != .eq) return false;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return false;
    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @backingInt(rhs_idx) >= ast.nodes.items.len) return false;
    const rhs = ast.nodes.items[@backingInt(rhs_idx)];
    return rhs.tag == .identifier_reference and buffer_names.contains(ast.getText(rhs.span));
}

test "Node Buffer module.exports detection follows only a folded capability branch" {
    const folded_source =
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) {
        \\  module.exports = buffer;
        \\} else { exports.Buffer = SafeBuffer; }
        \\function SafeBuffer() { return 1; }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, folded_source);
    scanner.is_module = false;
    var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
    parser.configureFromExtension(".cjs");
    parser.is_module = false;
    _ = try parser.parse();

    var buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_names.deinit(allocator);
    try collectNodeBufferModuleObjectNames(allocator, &parser.ast, &buffer_names);
    var buffer_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer buffer_ctor_names.deinit(allocator);
    try collectNodeBufferCtorNames(allocator, &parser.ast, &buffer_names, &buffer_ctor_names);

    var if_index: ?NodeIndex = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .if_statement) {
            if_index = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    const branch_index = if_index orelse return error.MissingCapabilityBranch;
    try std.testing.expect(!isModuleExportsAssignedNodeBufferObject(
        &parser.ast,
        branch_index,
        &buffer_names,
        &buffer_ctor_names,
    ));

    var removed_nodes: std.ArrayListUnmanaged(NodeIndex) = .empty;
    var needs_semantic_reanalysis = false;
    try std.testing.expect(try foldNodeBufferCapabilityIfsRetainingGraph(
        allocator,
        &parser.ast,
        &removed_nodes,
        null,
        &needs_semantic_reanalysis,
    ));
    try std.testing.expect(isModuleExportsAssignedNodeBufferObject(
        &parser.ast,
        branch_index,
        &buffer_names,
        &buffer_ctor_names,
    ));

    const rejected_cases = [_][]const u8{
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (someRuntimeCondition) { module.exports = buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from) { module.exports = buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer; var other = {};
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = other; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { exports.Buffer = buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports.Buffer = buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports += buffer; }
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) {
        \\  if (someRuntimeCondition) { module.exports = buffer; }
        \\}
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) {
        \\  globalThis.sideEffect = true;
        \\  module.exports = buffer;
        \\}
        ,
        \\var buffer = require("buffer"); var B = buffer.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe) { module.exports = buffer; }
        ,
        \\var buffer = require("buffer"); var alias = buffer; var B = alias.Buffer;
        \\if (B.from && B.alloc && B.allocUnsafe && B.allocUnsafeSlow) { module.exports = buffer; }
        ,
    };
    try std.testing.expectEqual(@as(usize, 10), rejected_cases.len);
    for (rejected_cases) |source| {
        var case_scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, source);
        case_scanner.is_module = false;
        var case_parser = @import("../../parser/parser.zig").Parser.init(allocator, &case_scanner);
        case_parser.configureFromExtension(".cjs");
        case_parser.is_module = false;
        _ = try case_parser.parse();

        var case_buffer_names: std.StringHashMapUnmanaged(void) = .empty;
        defer case_buffer_names.deinit(allocator);
        try collectNodeBufferModuleObjectNames(allocator, &case_parser.ast, &case_buffer_names);
        var case_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
        defer case_ctor_names.deinit(allocator);
        try collectNodeBufferCtorNames(allocator, &case_parser.ast, &case_buffer_names, &case_ctor_names);

        var case_if_index: ?NodeIndex = null;
        const case_program = programNode(&case_parser.ast) orelse return error.MissingRejectedProgram;
        const case_statements = case_program.data.list;
        if (case_statements.start > case_parser.ast.extra_data.items.len or
            case_statements.len > case_parser.ast.extra_data.items.len - case_statements.start)
            return error.InvalidRejectedProgram;
        for (case_parser.ast.extra_data.items[case_statements.start .. case_statements.start + case_statements.len]) |raw_stmt| {
            const stmt_index: NodeIndex = @fromBackingInt(@intCast(raw_stmt));
            if (stmt_index.isNone() or @backingInt(stmt_index) >= case_parser.ast.nodes.items.len) continue;
            if (case_parser.ast.nodes.items[@backingInt(stmt_index)].tag != .if_statement) continue;
            case_if_index = stmt_index;
            break;
        }
        try std.testing.expect(!isModuleExportsAssignedNodeBufferObject(
            &case_parser.ast,
            case_if_index orelse return error.MissingRejectedBranch,
            &case_buffer_names,
            &case_ctor_names,
        ));
    }

    const direct_export_source =
        \\var buffer = require("buffer");
        \\module.exports = buffer;
        \\function unusedFallback() { return 1; }
    ;
    var direct_scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, direct_export_source);
    direct_scanner.is_module = false;
    var direct_parser = @import("../../parser/parser.zig").Parser.init(allocator, &direct_scanner);
    direct_parser.configureFromExtension(".cjs");
    direct_parser.is_module = false;
    _ = try direct_parser.parse();
    var direct_buffer_names: std.StringHashMapUnmanaged(void) = .empty;
    defer direct_buffer_names.deinit(allocator);
    try collectNodeBufferModuleObjectNames(allocator, &direct_parser.ast, &direct_buffer_names);
    var direct_ctor_names: std.StringHashMapUnmanaged(void) = .empty;
    defer direct_ctor_names.deinit(allocator);
    try collectNodeBufferCtorNames(allocator, &direct_parser.ast, &direct_buffer_names, &direct_ctor_names);
    var direct_export_found = false;
    for (direct_parser.ast.nodes.items, 0..) |_, raw| {
        if (isModuleExportsAssignedNodeBufferObject(
            &direct_parser.ast,
            @fromBackingInt(@intCast(raw)),
            &direct_buffer_names,
            &direct_ctor_names,
        )) {
            direct_export_found = true;
            break;
        }
    }
    try std.testing.expect(direct_export_found);
}

fn isModuleExportsLhs(ast: *const Ast, idx: NodeIndex) bool {
    const parts = staticMemberParts(ast, idx) orelse return false;
    const obj = ast.nodes.items[@backingInt(parts.object)];
    const prop = ast.nodes.items[@backingInt(parts.property)];
    return obj.tag == .identifier_reference and
        prop.tag == .identifier_reference and
        std.mem.eql(u8, ast.getText(obj.span), "module") and
        std.mem.eql(u8, ast.getText(prop.span), "exports");
}

fn isCjsNamedExportLhs(ast: *const Ast, idx: NodeIndex) bool {
    const outer = staticMemberParts(ast, idx) orelse return false;
    const prop = ast.nodes.items[@backingInt(outer.property)];
    if (prop.tag != .identifier_reference and prop.tag != .private_identifier) return false;
    const obj = ast.nodes.items[@backingInt(outer.object)];
    if (obj.tag == .identifier_reference and std.mem.eql(u8, ast.getText(obj.span), "exports")) {
        return true;
    }
    if (obj.tag != .static_member_expression) return false;
    const inner = staticMemberParts(ast, outer.object) orelse return false;
    const inner_obj = ast.nodes.items[@backingInt(inner.object)];
    const inner_prop = ast.nodes.items[@backingInt(inner.property)];
    return inner_obj.tag == .identifier_reference and
        inner_prop.tag == .identifier_reference and
        std.mem.eql(u8, ast.getText(inner_obj.span), "module") and
        std.mem.eql(u8, ast.getText(inner_prop.span), "exports");
}

fn moduleExportsRequireSpanAt(ast: *const Ast, idx: NodeIndex) ?Span {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return null;
    const stmt = ast.nodes.items[@backingInt(idx)];
    if (stmt.tag == .block_statement) {
        const inner = singleBlockStatement(ast, idx) orelse return null;
        return moduleExportsRequireSpanAt(ast, inner);
    }
    if (stmt.tag == .if_statement) {
        const t = stmt.data.ternary;
        if (moduleExportsRequireSpanAt(ast, t.b)) |span| return span;
        if (!t.c.isNone()) return moduleExportsRequireSpanAt(ast, t.c);
        return null;
    }
    if (stmt.tag != .expression_statement) return null;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return null;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag != .assignment_expression) return null;
    const op: Kind = @fromBackingInt(@intCast(expr.data.binary.flags));
    if (op != .eq) return null;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return null;

    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @backingInt(rhs_idx) >= ast.nodes.items.len) return null;
    const rhs = ast.nodes.items[@backingInt(rhs_idx)];
    if (rhs.tag != .call_expression) return null;
    const e = rhs.data.extra;
    if (!ast.hasExtra(e, 2)) return null;

    const callee_idx = ast.readExtraNode(e, 0);
    if (callee_idx.isNone() or @backingInt(callee_idx) >= ast.nodes.items.len) return null;
    const callee = ast.nodes.items[@backingInt(callee_idx)];
    if (callee.tag != .identifier_reference or !std.mem.eql(u8, ast.getText(callee.span), "require")) return null;

    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len != 1 or args_start >= ast.extra_data.items.len) return null;
    const arg_idx: NodeIndex = @fromBackingInt(@intCast(ast.extra_data.items[args_start]));
    if (arg_idx.isNone() or @backingInt(arg_idx) >= ast.nodes.items.len) return null;
    const arg = ast.nodes.items[@backingInt(arg_idx)];
    if (arg.tag != .string_literal) return null;
    return arg.span;
}

pub fn moduleExportsRequireTargetAt(m: *const Module, ast: *const Ast, idx: NodeIndex) ?ModuleIndex {
    const span = moduleExportsRequireSpanAt(ast, idx) orelse return null;
    for (m.import_records) |rec| {
        if (rec.kind != .require) continue;
        if (rec.resolved.isNone()) continue;
        if (rec.span.start == span.start and rec.span.end == span.end) return rec.resolved;
    }
    return null;
}

pub fn moduleExportsRequireProxyMatches(
    m: *const Module,
    infos: StmtInfos,
    stmt_idx: u32,
    target: ModuleIndex,
) bool {
    if (stmt_idx >= infos.stmts.len) return false;
    const ast = &(m.ast orelse return false);
    const stmt_ni = infos.stmts[stmt_idx].node_idx;
    if (stmt_ni >= ast.nodes.items.len) return false;
    const proxy_target = moduleExportsRequireTargetAt(m, ast, @fromBackingInt(@intCast(stmt_ni))) orelse return false;
    return @backingInt(proxy_target) == @backingInt(target);
}

fn staticMemberParts(ast: *const Ast, idx: NodeIndex) ?struct { object: NodeIndex, property: NodeIndex } {
    if (idx.isNone() or @backingInt(idx) >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[@backingInt(idx)];
    if (node.tag != .static_member_expression) return null;
    const e = node.data.extra;
    if (!ast.hasExtra(e, 1)) return null;
    const obj_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(e, 0)));
    const prop_idx: NodeIndex = @fromBackingInt(@intCast(ast.readExtra(e, 1)));
    if (obj_idx.isNone() or prop_idx.isNone()) return null;
    if (@backingInt(obj_idx) >= ast.nodes.items.len or @backingInt(prop_idx) >= ast.nodes.items.len) return null;
    return .{ .object = obj_idx, .property = prop_idx };
}
