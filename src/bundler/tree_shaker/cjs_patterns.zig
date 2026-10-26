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
const ast_walk = @import("../../parser/ast_walk.zig");
const Kind = @import("../../lexer/token.zig").Kind;
const Span = @import("../../lexer/token.zig").Span;

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

    var branches: std.ArrayListUnmanaged(BufferCapabilityFoldBranch) = .empty;
    defer branches.deinit(allocator);
    var dead_fallback_names: std.StringHashMapUnmanaged(void) = .empty;
    defer dead_fallback_names.deinit(allocator);

    for (ast.nodes.items, 0..) |node, i| {
        if (node.tag != .if_statement) continue;
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
        if (!alternate.isNone()) {
            if (@backingInt(alternate) >= ast.nodes.items.len) return false;
            const alternate_tag = ast.nodes.items[@backingInt(alternate)].tag;
            if (alternate_tag != .expression_statement and alternate_tag != .block_statement) return false;
            try collectDeadAlternateCjsExportIdentifiers(allocator, ast, alternate, &dead_fallback_names);
        }
        try branches.append(allocator, .{
            .if_index = @fromBackingInt(@intCast(i)),
            .kept = kept,
            .alternate = alternate,
        });
    }
    if (branches.items.len == 0) return false;
    // The retained graph cannot rebuild function-declaration liveness for an
    // exact dead fallback function. Dynamic root reads are handled by the
    // TreeShaker's declaration and writer seeds below; missing semantic data
    // still takes the full analyzer path because visibility cannot be proven.
    needs_semantic_reanalysis.* = hasTopLevelDeadFallbackFunction(ast, &dead_fallback_names) or
        (if (semantic) |sem| sem.scopes.len == 0 else true);

    var seen = try std.DynamicBitSet.initEmpty(allocator, ast.nodes.items.len);
    defer seen.deinit();
    for (branches.items) |branch| {
        try appendSubtreeNodes(allocator, ast, branch.alternate, &seen, removed_nodes);
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

    // No AST write happens until all candidate node indexes are captured. This
    // keeps allocation or shape failures on the existing full-analysis path.
    for (branches.items) |branch| {
        ast.nodes.items[@backingInt(branch.if_index)].data.ternary.c = .none;
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

/// The retained graph does not rebuild function-declaration liveness for an
/// exact dead fallback function, so keep its established full-analysis path.
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

test "retained Node Buffer fold reanalyzes dead top-level fallback functions only" {
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
            .expected_reanalysis = true,
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
};

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

fn collectNodeBufferCtorNames(
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
    stmt: Node,
    buffer_names: *const std.StringHashMapUnmanaged(void),
) bool {
    if (stmt.tag != .expression_statement) return false;
    const expr_idx = stmt.data.unary.operand;
    if (expr_idx.isNone() or @backingInt(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@backingInt(expr_idx)];
    if (expr.tag != .assignment_expression) return false;
    if (!isModuleExportsLhs(ast, expr.data.binary.left)) return false;
    const rhs_idx = expr.data.binary.right;
    if (rhs_idx.isNone() or @backingInt(rhs_idx) >= ast.nodes.items.len) return false;
    const rhs = ast.nodes.items[@backingInt(rhs_idx)];
    return rhs.tag == .identifier_reference and buffer_names.contains(ast.getText(rhs.span));
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
