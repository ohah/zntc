//! Same-AST authority for a preceding local class constructor.
//! A pure identifier read alone does not prove safe ClassDefinitionEvaluation.
const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Scope = @import("../semantic/scope.zig").Scope;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Reference = @import("../semantic/symbol.zig").Reference;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const walk = @import("../parser/ast_walk.zig");

pub const Identity = struct {
    symbol_ids: []const ?u32,
    symbols: []const Symbol,
    scopes: []const Scope,
    references: []const Reference,
};

/// Borrowed only during one immutable statement-metadata build; never cached
/// or carried across an AST/semantic edit or module publication.
pub const Plan = struct {
    ast: *const ast_mod.Ast,
    safe_reads: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        self.safe_reads.deinit(allocator);
    }

    pub fn contains(self: *const Plan, ast: *const ast_mod.Ast, node: ast_mod.NodeIndex) bool {
        return self.ast == ast and !node.isNone() and self.safe_reads.contains(@backingInt(node));
    }
};

fn directClass(ast: *const ast_mod.Ast, statement: ast_mod.NodeIndex) ?ast_mod.NodeIndex {
    var current = statement;
    for (0..256) |_| {
        if (current.isNone() or @backingInt(current) >= ast.nodes.items.len) return null;
        const node = ast.getNode(current);
        switch (node.tag) {
            .class_declaration => return current,
            .export_default_declaration => current = node.data.unary.operand,
            .export_named_declaration => {
                if (!ast.hasExtra(node.data.extra, 0)) return null;
                current = ast.readExtraNode(node.data.extra, 0);
            },
            else => return null,
        }
    }
    return null;
}

/// Source classes own a non-configurable, non-writable prototype data property.
/// Once initialized, their constructor/prototype checks cannot invoke a getter.
/// A class decorator may replace that constructor, so it never grants authority.
pub fn prepare(
    allocator: std.mem.Allocator,
    ast: *const ast_mod.Ast,
    root: ast_mod.NodeIndex,
    identity: Identity,
) !Plan {
    var plan: Plan = .{ .ast = ast };
    errdefer plan.deinit(allocator);
    if (root.isNone() or @backingInt(root) >= ast.nodes.items.len or ast.getNode(root).tag != .program) return plan;
    const list = ast.getNode(root).data.list;
    if (list.start > ast.extra_data.items.len or list.len > ast.extra_data.items.len - list.start) return plan;
    if (identity.symbol_ids.len < ast.nodes.items.len) return plan;
    var has_class = false;
    for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
        if (directClass(ast, @fromBackingInt(raw)) != null) {
            has_class = true;
            break;
        }
    }
    if (!has_class) return plan;
    const binding_counts = try allocator.alloc(usize, identity.symbols.len);
    defer allocator.free(binding_counts);
    @memset(binding_counts, 0);
    const reachable = try walk.collectReachableNodeIndicesFrom(allocator, ast, root);
    defer allocator.free(reachable);
    for (reachable) |raw| {
        if (ast.nodes.items[raw].tag != .binding_identifier) continue;
        const sid = identity.symbol_ids[raw] orelse continue;
        if (sid < binding_counts.len) binding_counts[sid] += 1;
    }
    const Edge = struct { sid: u32, scope: ScopeId, valid: bool };
    var declarations: std.AutoHashMapUnmanaged(u32, Edge) = .empty;
    defer declarations.deinit(allocator);
    var reads: std.AutoHashMapUnmanaged(u32, Edge) = .empty;
    defer reads.deinit(allocator);
    for (identity.references) |row| {
        if (row.symbol_id.isNone()) continue;
        const declaration = row.flags.declare;
        const node = if (declaration) row.declaration_node_index else row.node_index;
        if (node.isNone() or @backingInt(node) >= ast.nodes.items.len) continue;
        const index = @backingInt(node);
        const sid = @backingInt(row.symbol_id);
        const pure_declaration = declaration and !row.flags.read and !row.flags.write and !row.flags.type_context and !row.flags.value_as_type;
        const pure_read = !declaration and row.isValueUse() and row.flags.read and !row.flags.write;
        const map = if (declaration) &declarations else &reads;
        const entry = try map.getOrPut(allocator, index);
        if (entry.found_existing) {
            entry.value_ptr.valid = false;
        } else entry.value_ptr.* = .{
            .sid = sid,
            .scope = row.scope_id,
            .valid = identity.symbol_ids[index] == sid and (pure_declaration or pure_read),
        };
    }
    var initialized: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer initialized.deinit(allocator);
    for (ast.extra_data.items[list.start..][0..list.len]) |raw| {
        const class = directClass(ast, @fromBackingInt(raw)) orelse continue;
        const node = ast.getNode(class);
        if (!ast.hasExtra(node.data.extra, ast_mod.ClassExtra.deco_len)) continue;
        var heritage = ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.super);
        var depth: usize = 0;
        while (!heritage.isNone() and @backingInt(heritage) < ast.nodes.items.len and
            ast.getNode(heritage).tag == .parenthesized_expression and depth < 256) : (depth += 1)
            heritage = ast.getNode(heritage).data.unary.operand;
        if (!heritage.isNone() and @backingInt(heritage) < ast.nodes.items.len and ast.getNode(heritage).tag == .identifier_reference) {
            if (identity.symbol_ids[@backingInt(heritage)]) |sid| {
                if (reads.get(@backingInt(heritage))) |edge| {
                    if (edge.valid and edge.sid == sid and initialized.contains(sid))
                        try plan.safe_reads.put(allocator, @backingInt(heritage), {});
                }
            }
        }
        // Add only after visiting this class's heritage: a self/forward read
        // must retain its original TDZ behavior.
        const binding = ast.readExtraNode(node.data.extra, ast_mod.ClassExtra.name);
        if (binding.isNone() or @backingInt(binding) >= ast.nodes.items.len or ast.getNode(binding).tag != .binding_identifier) continue;
        const sid = identity.symbol_ids[@backingInt(binding)] orelse continue;
        if (sid >= identity.symbols.len or binding_counts[sid] != 1) continue;
        const symbol = identity.symbols[sid];
        const declaration = declarations.get(@backingInt(binding)) orelse continue;
        if (!declaration.valid or declaration.sid != sid or declaration.scope != symbol.scope_id) continue;
        if (symbol.kind != .class_decl or symbol.isSynthetic() or symbol.write_count != 0 or symbol.scope_id.isNone()) continue;
        const scope = symbol.scope_id.toIndex();
        if (scope >= identity.scopes.len or symbol.origin_scope != symbol.scope_id) continue;
        const frame = identity.scopes[scope];
        // Global lexical bindings are observable by foreign indirect eval.
        if (frame.kind != .module or !frame.parent.isNone() or frame.blocksMangling()) continue;
        if (ast.readExtra(node.data.extra, ast_mod.ClassExtra.deco_len) != 0) continue;
        try initialized.put(allocator, sid, {});
    }
    return plan;
}

fn fixture(source: []const u8, module: bool) !struct {
    arena: std.heap.ArenaAllocator,
    ast: ast_mod.Ast,
    root: ast_mod.NodeIndex,
    identity: Identity,
} {
    if (!@import("builtin").is_test) @compileError("initial source fixture analysis is test-only");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
    parser.is_module = module;
    scanner.is_module = module;
    const root = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
    analyzer.is_module = module;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.enable_source_external_origins = true;
    try analyzer.analyze();
    return .{ .arena = arena, .ast = parser.ast, .root = root, .identity = .{
        .symbols = analyzer.symbols.items,
        .scopes = analyzer.scopes.items,
        .symbol_ids = analyzer.symbol_ids.items,
        .references = analyzer.references.items,
    } };
}

test "heritage authority uses exact preceding module class declarations" {
    const cases = [_]struct { source: []const u8, expected: usize, module: bool = true }{
        .{ .source = "class Base{};class Child extends Base{}", .expected = 1 },
        .{ .source = "class Base{};class Child extends(Base){};class Last extends Child{}", .expected = 2 },
        .{ .source = "export class Base{};export class Child extends Base{}", .expected = 1 },
        .{ .source = "class Child extends Base{};class Base{}", .expected = 0 },
        .{ .source = "class Base extends Base{}", .expected = 0 },
        .{ .source = "class Base{};Base=other;class Child extends Base{}", .expected = 0 },
        .{ .source = "class Base{};eval('Base=other');class Child extends Base{}", .expected = 0 },
        .{ .source = "const Base=new Proxy(class{},{});class Child extends Base{}", .expected = 0 },
        .{ .source = "class Child extends external.Base{}", .expected = 0 },
        .{ .source = "class Base{};class Child extends Base{}", .expected = 0, .module = false },
    };
    for (cases) |case| {
        var f = try fixture(case.source, case.module);
        defer f.arena.deinit();
        var plan = try prepare(std.testing.allocator, &f.ast, f.root, f.identity);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.expected, plan.safe_reads.count());
    }
}

test "heritage authority rejects foreign headers and broken physical declaration edges" {
    var f = try fixture("class Base{};class Child extends Base{}", true);
    defer f.arena.deinit();
    const a = f.arena.allocator();
    var baseline = try prepare(std.testing.allocator, &f.ast, f.root, f.identity);
    defer baseline.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), baseline.safe_reads.count());
    var keys = baseline.safe_reads.keyIterator();
    const reference: ast_mod.NodeIndex = @fromBackingInt(keys.next().?.*);
    const first_class = directClass(&f.ast, @fromBackingInt(f.ast.extra_data.items[f.ast.getNode(f.root).data.list.start])).?;
    const binding = f.ast.readExtraNode(f.ast.getNode(first_class).data.extra, ast_mod.ClassExtra.name);
    const sid = f.identity.symbol_ids[@backingInt(binding)].?;
    const scope = f.identity.symbols[sid].scope_id.toIndex();
    var foreign_header = f.ast;
    try std.testing.expect(!baseline.contains(&foreign_header, reference));

    for (0..7) |mutation| {
        var view = f.identity;
        const ids = try a.dupe(?u32, view.symbol_ids);
        const symbols = try a.dupe(Symbol, view.symbols);
        const scopes = try a.dupe(Scope, view.scopes);
        const rows = try a.alloc(Reference, view.references.len + 1);
        @memcpy(rows[0..view.references.len], view.references);
        view.symbol_ids = ids;
        view.symbols = symbols;
        view.scopes = scopes;
        view.references = rows[0..view.references.len];
        switch (mutation) {
            0 => ids[@backingInt(binding)] = null,
            1 => ids[@backingInt(reference)] = null,
            2 => symbols[sid].write_count += 1,
            3 => scopes[scope].subtree_has_direct_eval = true,
            4 => {
                for (view.references) |row| {
                    if (row.flags.declare and row.declaration_node_index == binding) {
                        rows[view.references.len] = row;
                        break;
                    }
                }
                view.references = rows;
            },
            5 => {
                for (rows[0..view.references.len]) |*row| {
                    if (row.node_index == reference) row.flags.type_context = true;
                }
            },
            6 => view.symbol_ids = ids[0 .. ids.len - 1],
            else => unreachable,
        }
        var rejected = try prepare(std.testing.allocator, &f.ast, f.root, view);
        defer rejected.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), rejected.safe_reads.count());
    }
}

test "heritage authority real bundles preserve constructor and prototype effects" {
    const io_helpers = @import("test_helpers.zig");
    const Bundler = @import("bundler.zig").Bundler;
    const cases = [_]struct { source: []const u8, removable: bool }{
        .{ .source = "export{};class Base{};class Unused extends Base{};console.log(new Base() instanceof Base)", .removable = true },
        .{ .source = "export{};class Base{};Base.DEFAULT_UP=123;class Unused extends Base{};console.log(Base.DEFAULT_UP)", .removable = true },
        .{ .source = "export{};class Base{};Base=new Proxy(Base,{get(t,k,r){if(k==='prototype')console.log('prototype');return Reflect.get(t,k,r)}});class Unused extends Base{};console.log('done')", .removable = false },
        .{ .source = "export{};class Base{};eval(\"Base=new Proxy(Base,{get(t,k,r){if(k==='prototype')console.log('prototype');return Reflect.get(t,k,r)}})\");class Unused extends Base{};console.log('done')", .removable = false },
        .{ .source = "export{};process.on('uncaughtException',e=>console.log(e.name));class Unused extends Base{};class Base{}", .removable = false },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // Non-minified entries deliberately preserve their declarations.
        // Exercise the provider statement-shaking path used by the original
        // three.js regressions, without changing the source under test.
        try io_helpers.writeFile(tmp.dir, "provider.mjs", case.source);
        try io_helpers.writeFile(tmp.dir, "entry.mjs", "import './provider.mjs';");
        const entry = try io_helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", entry } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            var bundler = Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .platform = .node,
                .format = .cjs,
                .minify_identifiers = minify,
            });
            defer bundler.deinit();
            const result = try bundler.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            if (!minify) try std.testing.expectEqual(case.removable, std.mem.indexOf(u8, result.output, "class Unused") == null);
            const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.output } });
            defer std.testing.allocator.free(actual.stdout);
            defer std.testing.allocator.free(actual.stderr);
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("heritage runtime source={s} minify={any}\nexpected={s}actual={s}stderr={s}\n{s}\n", .{ case.source, minify, native.stdout, actual.stdout, actual.stderr, result.output });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

fn prepareWithAllocationFailure(allocator: std.mem.Allocator, ast: *const ast_mod.Ast, root: ast_mod.NodeIndex, identity: Identity) !void {
    var plan = try prepare(allocator, ast, root, identity);
    defer plan.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), plan.safe_reads.count());
}

test "heritage authority OOM leaves the actual source identities unchanged" {
    var f = try fixture("class Base{};class Child extends Base{}", true);
    defer f.arena.deinit();
    const a = f.arena.allocator();
    const before_ids = try a.dupe(?u32, f.identity.symbol_ids);
    const before_symbols = try a.dupe(Symbol, f.identity.symbols);
    const before_rows = try a.dupe(Reference, f.identity.references);
    const before_scopes = try a.dupe(Scope, f.identity.scopes);
    const nodes_pointer = f.ast.nodes.items.ptr;
    const nodes_len = f.ast.nodes.items.len;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareWithAllocationFailure, .{ &f.ast, f.root, f.identity });
    try std.testing.expect(nodes_pointer == f.ast.nodes.items.ptr and nodes_len == f.ast.nodes.items.len);
    try std.testing.expectEqualSlices(?u32, before_ids, f.identity.symbol_ids);
    for (before_symbols, f.identity.symbols) |before, after| try std.testing.expectEqualDeep(before, after);
    for (before_rows, f.identity.references) |before, after| try std.testing.expectEqualDeep(before, after);
    for (before_scopes, f.identity.scopes) |before, after| try std.testing.expectEqualDeep(before, after);
}
