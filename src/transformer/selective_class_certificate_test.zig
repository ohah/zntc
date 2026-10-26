const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Reference = @import("../semantic/symbol.zig").Reference;
const ModuleSemanticData = @import("../bundler/module.zig").ModuleSemanticData;
const Transformer = @import("transformer.zig").Transformer;
const certificate = @import("selective_class_certificate.zig");
const options: @import("transformer.zig").TransformOptions = .{ .strip_types = true, .emit_runtime_helper_imports = true, .unsupported = @import("compat.zig").fromESTarget(.es5) };

const Fixture = struct {
    ast: ast_mod.Ast,
    semantic: ModuleSemanticData,
    unresolved: std.AutoHashMapUnmanaged(u32, void),
};

fn sourceFixture(allocator: std.mem.Allocator, source: []const u8) !Fixture {
    var scanner = try @import("../lexer/scanner.zig").Scanner.init(allocator, source);
    var parser = @import("../parser/parser.zig").Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    return .{ .ast = parser.ast, .unresolved = analyzer.unresolved_reference_nodes, .semantic = .{
        .symbols = analyzer.symbols,
        .scopes = analyzer.scopes.items,
        .scope_maps = analyzer.scope_maps.items,
        .scope_owner_map = analyzer.scope_owner_map,
        .node_scope_provenance = analyzer.node_scope_provenance,
        .class_self_symbol_map = analyzer.class_self_symbol_map,
        .namespace_member_owners = analyzer.namespace_member_owners,
        .namespace_declaration_owners = analyzer.namespace_declaration_owners,
        .exported_names = analyzer.exported_names,
        .symbol_ids = analyzer.symbol_ids.items,
        .unresolved_references = analyzer.unresolved_references,
        .references = analyzer.references.items,
        .numeric_const_texts = analyzer.numeric_const_texts,
        .helper_scope_map = analyzer.helper_scope_map,
    } };
}

const State = struct {
    fixture: *Fixture,
    transformer: *Transformer,
    source: certificate.Source,
    foreign_function: NodeIndex,
    foreign_symbol: u32,
    foreign_parameter: NodeIndex,
    foreign_parameter_symbol: u32,
    foreign_scope: ScopeId,
    input: []const u8,
    initial_ids: []const ?u32,
    initial_owners: std.AutoHashMapUnmanaged(u32, u32),
};

fn state(allocator: std.mem.Allocator, source: []const u8) !State {
    const input = try std.mem.replaceOwned(u8, allocator, source, "function P(){}", "function P(value){}");
    const fixture = try allocator.create(Fixture);
    fixture.* = try sourceFixture(allocator, input);
    var proposed = (try certificate.sourcePlan(allocator, &fixture.ast, &fixture.semantic, options)).?;
    proposed.owner_token = fixture.semantic.captureOwnerToken();
    const heritage = fixture.ast.readExtraNode(fixture.ast.getNode(proposed.plan.class_node).data.extra, ast_mod.ClassExtra.super);
    const foreign_symbol = fixture.semantic.symbol_ids[@backingInt(heritage)].?;
    const initial_ids = try allocator.dupe(?u32, fixture.semantic.symbol_ids);
    const initial_owners = try fixture.semantic.scope_owner_map.clone(allocator);
    const t = try allocator.create(Transformer);
    t.* = try Transformer.init(allocator, &fixture.ast, options);
    try t.initSymbolIds(fixture.semantic.symbol_ids);
    t.symbols = fixture.semantic.symbols.items;
    t.references = fixture.semantic.references;
    t.scopes = fixture.semantic.scopes;
    t.scope_maps = fixture.semantic.scope_maps;
    t.scope_owner_map = fixture.semantic.scope_owner_map;
    t.node_scope_provenance = fixture.semantic.node_scope_provenance;
    t.class_self_symbol_map = fixture.semantic.class_self_symbol_map;
    t.helper_scope_map = fixture.semantic.helper_scope_map;
    t.unresolved_references = &fixture.semantic.unresolved_references;
    t.unresolved_reference_nodes = &fixture.unresolved;
    t.semantic_edit_enabled = true;
    t.record_explicit_global_references = true;
    t.selective_class_candidate = proposed;
    const root = try t.transform();
    if (try t.finishSemanticEdit()) |edited| fixture.semantic.applyEdit(edited);
    try std.testing.expect((try certificate.validate(t, &fixture.semantic, proposed)) != null);
    var parents = try @import("output_scope_test_utils.zig").buildParentMap(allocator, t.ast, root);
    defer parents.deinit(allocator);
    for (fixture.semantic.references) |row| {
        if (!row.flags.declare or @backingInt(row.symbol_id) != foreign_symbol or row.declaration_node_index.isNone()) continue;
        const parent = parents.get(@backingInt(row.declaration_node_index)) orelse continue;
        const function = t.ast.nodes.items[parent];
        if (function.tag != .function_declaration or t.ast.readExtraNode(function.data.extra, 0) != row.declaration_node_index) continue;
        const parameters = t.ast.getNode(t.ast.readExtraNode(function.data.extra, 1));
        try std.testing.expectEqual(@as(u32, 1), parameters.data.list.len);
        const parameter = t.ast.readExtraNode(parameters.data.list.start, 0);
        const parameter_symbol = fixture.semantic.symbol_ids[@backingInt(parameter)].?;
        try std.testing.expect(fixture.semantic.symbols.items[parameter_symbol].kind == .parameter);
        return .{
            .fixture = fixture,
            .transformer = t,
            .source = proposed,
            .foreign_function = @fromBackingInt(parent),
            .foreign_symbol = foreign_symbol,
            .foreign_parameter = parameter,
            .foreign_parameter_symbol = parameter_symbol,
            .foreign_scope = t.outputOwnedScope(@fromBackingInt(parent)).?,
            .input = input,
            .initial_ids = initial_ids,
            .initial_owners = initial_owners,
        };
    }
    return error.MissingRealSiblingFunction;
}

fn rejected(s: State, source: certificate.Source) !void {
    const result = certificate.validate(s.transformer, &s.fixture.semantic, source) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    try std.testing.expect(result == null);
}

const ImportEdge = struct { source_slot: u32, specifier: NodeIndex };
fn importEdge(s: State, sid: u32) !ImportEdge {
    const local = s.transformer.runtime_helper_import_bindings.get(sid) orelse return error.MissingKnownImport;
    const root = s.transformer.ast.getNode(s.transformer.ast.transformed_root.?);
    for (0..root.data.list.len) |offset| {
        const declaration = s.transformer.ast.getNode(s.transformer.ast.readExtraNode(root.data.list.start, @intCast(offset)));
        if (declaration.tag != .import_declaration) continue;
        const extra = declaration.data.extra;
        const start = s.transformer.ast.extra_data.items[extra];
        const len = s.transformer.ast.extra_data.items[extra + 1];
        for (0..len) |i| {
            const specifier = s.transformer.ast.readExtraNode(start, @intCast(i));
            const node = s.transformer.ast.getNode(specifier);
            if (node.tag == .import_specifier and @backingInt(node.data.binary.right) == local)
                return .{ .source_slot = extra + 2, .specifier = specifier };
        }
    }
    return error.MissingKnownImportEdge;
}

const hostile_cases = 15;
test "selective class certificate rejects hostile owner scope provider and flags" {
    std.debug.print("SELECTIVE HOSTILE START cases={d} sources=10\n", .{hostile_cases});
    for (0..hostile_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = @import("selective_class_certificate_fixtures.zig").sources[case % 10];
        const s = try state(a, source);
        const t = s.transformer;
        const sem = &s.fixture.semantic;
        const original_application = t.selective_class_applications.items[0];
        const extends_id = @backingInt(t.runtime_helper_symbol_ids.get("__extends").?);
        switch (case) {
            0 => {
                // A new physical semantic owner with the same numeric rows.
                const saved = sem.*;
                var replacement = sem.*;
                replacement.owner_token = .unassigned;
                replacement.symbols = .fromOwnedSlice(try a.dupe(@import("../semantic/symbol.zig").Symbol, sem.symbols.items));
                replacement.scopes = try a.dupe(@import("../semantic/scope.zig").Scope, sem.scopes);
                replacement.references = try a.dupe(Reference, sem.references);
                replacement.symbol_ids = try a.dupe(?u32, sem.symbol_ids);
                _ = replacement.captureOwnerToken();
                sem.* = replacement;
                try rejected(s, s.source);
                sem.* = saved;
            },
            1 => {
                var other = try sourceFixture(a, s.input);
                try std.testing.expectEqual(s.fixture.ast.nodes.items.len, other.ast.nodes.items.len);
                try std.testing.expect(std.meta.eql(s.source.plan, (try certificate.sourcePlan(a, &other.ast, &other.semantic, options)).?.plan));
                var wrong = s.source;
                wrong.source_ast = &other.ast;
                try rejected(s, wrong);
            },
            2 => {
                try std.testing.expect(s.foreign_scope != original_application.constructor_scope);
                t.selective_class_applications.items[0].constructor = s.foreign_function;
                t.selective_class_applications.items[0].constructor_scope = s.foreign_scope;
                try rejected(s, s.source);
                t.selective_class_applications.items[0] = original_application;
            },
            3 => {
                // A real parameter SID from a different, live function scope.
                t.selective_class_applications.items[0].super_symbol = s.foreign_parameter_symbol;
                t.selective_class_applications.items[0].super_binding = s.foreign_parameter;
                try rejected(s, s.source);
                t.selective_class_applications.items[0] = original_application;
            },
            4 => {
                const target = try importEdge(s, extends_id);
                const other = try importEdge(s, @backingInt(t.runtime_helper_symbol_ids.get("__callSuper").?));
                const saved = t.ast.extra_data.items[target.source_slot];
                t.ast.extra_data.items[target.source_slot] = t.ast.extra_data.items[other.source_slot];
                try rejected(s, s.source);
                t.ast.extra_data.items[target.source_slot] = saved;
            },
            5 => {
                const target = try importEdge(s, extends_id);
                const other = try importEdge(s, @backingInt(t.runtime_helper_symbol_ids.get("__callSuper").?));
                const saved = t.ast.nodes.items[@backingInt(target.specifier)].data.binary.left;
                t.ast.nodes.items[@backingInt(target.specifier)].data.binary.left = t.ast.getNode(other.specifier).data.binary.left;
                try rejected(s, s.source);
                t.ast.nodes.items[@backingInt(target.specifier)].data.binary.left = saved;
            },
            6 => {
                const saved = sem.references;
                const copy = try a.alloc(Reference, saved.len + 1);
                @memcpy(copy[0..saved.len], saved);
                var duplicate: ?Reference = null;
                for (saved) |row| {
                    if (@backingInt(row.symbol_id) == extends_id and row.flags.declare) duplicate = row;
                }
                copy[saved.len] = duplicate.?;
                sem.references = copy;
                try rejected(s, s.source);
                sem.references = saved;
            },
            7, 8 => {
                var index: ?usize = null;
                for (sem.references, 0..) |row, i| {
                    if (@backingInt(row.symbol_id) == extends_id and !row.node_index.isNone() and row.flags.read) index = i;
                }
                const saved = sem.references;
                const copy = try a.dupe(Reference, saved);
                if (case == 7) copy[index.?].flags.write = true else copy[index.?].scope_id = s.foreign_scope;
                sem.references = copy;
                try rejected(s, s.source);
                sem.references = saved;
            },
            9 => {
                try t.selective_class_applications.append(a, original_application);
                try rejected(s, s.source);
                t.selective_class_applications.items.len = 1;
            },
            10 => {
                const removed = t.runtime_helper_import_bindings.fetchRemove(extends_id).?;
                try rejected(s, s.source);
                try t.runtime_helper_import_bindings.put(a, removed.key, removed.value);
            },
            11 => {
                const invalid: NodeIndex = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len + 5)));
                try t.transformed_scope_owner_map.put(a, @backingInt(invalid), @backingInt(original_application.factory_scope));
                t.selective_class_applications.items[0].factory = invalid;
                try rejected(s, s.source);
                t.selective_class_applications.items[0] = original_application;
                try std.testing.expect(t.transformed_scope_owner_map.remove(@backingInt(invalid)));
            },
            12 => {
                var initial = try sourceFixture(a, source);
                const proposed = (try certificate.sourcePlan(a, &initial.ast, &initial.semantic, options)).?;
                const slot = initial.semantic.class_self_symbol_map.getPtr(@backingInt(proposed.plan.class_node)).?;
                const saved = slot.*;
                try std.testing.expect(saved != proposed.symbol);
                try std.testing.expect(initial.semantic.symbols.items[saved].kind == initial.semantic.symbols.items[proposed.symbol].kind);
                slot.* = proposed.symbol;
                try std.testing.expect((try certificate.sourcePlan(a, &initial.ast, &initial.semantic, options)) == null);
                slot.* = saved;
                try std.testing.expect((try certificate.sourcePlan(a, &initial.ast, &initial.semantic, options)) != null);
            },
            13 => {
                const saved = t.selective_class_applications.items;
                t.selective_class_applications.items = saved[0..0];
                try rejected(s, s.source);
                t.selective_class_applications.items = saved;
            },
            14 => {
                const result_assignment = t.ast.getNode(original_application.super_call.result_assignment);
                const call = t.ast.getNode(result_assignment.data.binary.right);
                const callee = t.ast.readExtraNode(call.data.extra, 0);
                const saved = sem.references;
                const copy = try a.alloc(Reference, saved.len + 1);
                @memcpy(copy[0..saved.len], saved);
                var duplicate: ?Reference = null;
                for (saved) |row| {
                    if (row.node_index == callee) duplicate = row;
                }
                copy[saved.len] = duplicate.?;
                sem.references = copy;
                try rejected(s, s.source);
                sem.references = saved;
            },
            else => unreachable,
        }
        // Every corruption is followed by a positive on the exact original
        // graph, not by rebuilding or rediscovering an ID from a spelling.
        try std.testing.expect((try certificate.validate(t, sem, s.source)) != null);
    }
    std.debug.print("SELECTIVE HOSTILE COMPLETE cases={d} sources=10\n", .{hostile_cases});
}

test "selective class certificate source call rejects a valid sibling in the same scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try state(a, "function P(){}class D extends P{constructor(){var go=()=>{P();return super()};go()}}console.log(new D() instanceof P)");
    const initial = &s.fixture.ast;
    const root: NodeIndex = @fromBackingInt(@as(u32, @intCast(initial.nodes.items.len - 1)));
    var parents = try @import("output_scope_test_utils.zig").buildParentMap(a, initial, root);
    const reachable = try @import("../parser/ast_walk.zig").collectReachableNodeIndices(a, initial);
    var sibling: ?NodeIndex = null;
    for (reachable) |raw| {
        const node = initial.nodes.items[raw];
        if (node.tag != .call_expression) continue;
        const callee = initial.readExtraNode(node.data.extra, 0);
        if (@backingInt(callee) < s.initial_ids.len and s.initial_ids[@backingInt(callee)] == s.foreign_symbol) {
            try std.testing.expect(sibling == null);
            sibling = @fromBackingInt(raw);
        }
    }
    const foreign = sibling orelse return error.MissingRealSiblingSourceCall;
    try std.testing.expect(foreign != s.source.plan.first_super_call);
    var owners = s.initial_owners;
    const actual = @import("output_scope_test_utils.zig").expectedScope(initial, root, &parents, &owners, @backingInt(foreign)).?;
    const selected = @import("output_scope_test_utils.zig").expectedScope(initial, root, &parents, &owners, @backingInt(s.source.plan.first_super_call)).?;
    try std.testing.expectEqual(s.source.plan.arrow_scope, actual);
    try std.testing.expectEqual(selected, actual);
    const t = s.transformer;
    const saved_application = t.selective_class_applications.items[0];
    const marker = t.generated_super_call_assignments.getPtr(@backingInt(saved_application.super_assignment)).?;
    const saved_marker = marker.*;
    // Keep the producer marker and published record mutually consistent. The
    // trusted source selector must still reject the different source call.
    marker.source_call = foreign;
    t.selective_class_applications.items[0].super_call.source_call = foreign;
    try rejected(s, s.source);
    marker.* = saved_marker;
    t.selective_class_applications.items[0] = saved_application;
    try std.testing.expect((try certificate.validate(t, &s.fixture.semantic, s.source)) != null);
    std.debug.print("SELECTIVE SOURCE BRIDGE sibling=valid-same-scope rejected=1 restored=1\n", .{});
}
