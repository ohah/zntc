const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Ast = @import("../parser/ast.zig").Ast;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const MethodExtra = @import("../parser/ast.zig").MethodExtra;
const ast_walk = @import("../parser/ast_walk.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const coverage = @import("symbol_coverage.zig");

test "#4819 class field computed-key prehoist binds temp identity exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const key = "value";
        \\class Box {
        \\  static [key] = Box;
        \\  field = Box;
        \\}
        \\class InstanceBox {
        \\  [key] = 1;
        \\}
        \\class MethodBox {
        \\  [key]() { return this; }
        \\  field = 1;
        \\}
        \\class AccessorMethodBox {
        \\  get [key]() { return 1; }
        \\  field = 2;
        \\}
        \\class StaticMethodBox {
        \\  static [key]() { return this; }
        \\  field = 3;
        \\}
        \\const ExpressionBox = class {
        \\  static [key] = 1;
        \\  [key]() { return this; }
        \\  field = 2;
        \\};
        \\const SimpleExpressionBox = class {
        \\  [key] = 3;
        \\};
        \\function makeNested(_a) {
        \\  const nestedKey = "nested";
        \\  class NestedBox {
        \\    static [nestedKey] = NestedBox;
        \\    [nestedKey] = 1;
        \\  }
        \\  return NestedBox;
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try coverage.checkStrictWithExactExternalEvidence(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("class-computed-field-prehoist-es5.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());
}

test "#4819 anonymous private class wrapper owns its generated name exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base { constructor(public value: number) {} }
        \\function create(_args: number) {
        \\  return class extends Base {
        \\    #hidden = 1;
        \\    amount: number = _args;
        \\  };
        \\}
        \\function createStatic() {
        \\  return class extends Base {
        \\    static #hidden = 1;
        \\    static read() { return this.#hidden; }
        \\  };
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es2015),
        .use_define_for_class_fields = false,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try coverage.checkStrictWithExactExternalEvidence(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("anonymous-private-class-wrapper-es2015.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());

    var binding_ids: std.ArrayList(u32) = .empty;
    defer binding_ids.deinit(allocator);
    var reference_ids: std.ArrayList(u32) = .empty;
    defer reference_ids.deinit(allocator);
    for (transformer.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier and node.tag != .identifier_reference) continue;
        if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_a")) continue;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (node.tag == .binding_identifier) {
            try binding_ids.append(allocator, id);
        } else {
            try reference_ids.append(allocator, id);
        }
    }
    // Each class wrapper owns one class-name binding; its name must not also
    // be hoisted into the surrounding function as an unrelated `var _a`.
    try std.testing.expectEqual(@as(usize, 2), binding_ids.items.len);
    try std.testing.expect(binding_ids.items[0] != binding_ids.items[1]);
    try std.testing.expect(reference_ids.items.len >= 2);
    for (reference_ids.items) |reference_id| {
        try std.testing.expect(reference_id == binding_ids.items[0] or reference_id == binding_ids.items[1]);
    }
    var generated_class_self_count: usize = 0;
    var self_iter = transformer.class_self_symbol_map.iterator();
    while (self_iter.next()) |entry| {
        const name = transformer.ast.getText(edited.symbols.items[entry.value_ptr.*].name);
        if (!std.mem.eql(u8, name, "_a")) continue;
        generated_class_self_count += 1;
        try std.testing.expect(entry.value_ptr.* == binding_ids.items[0] or entry.value_ptr.* == binding_ids.items[1]);
    }
    try std.testing.expectEqual(@as(usize, 1), generated_class_self_count);
}

test "#4819 ES5 class inner write keeps source IDs and binds accessor uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\let Outer = class Inner { constructor(Inner) { this.arg = Inner; } static write() { Inner = 3; } static self() { return Inner; } };
        \\class Declared { constructor(Declared) { this.arg = Declared; } static write() { Declared++; } static self() { return Declared; } }
        \\Outer = Declared;
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var expression_inner: ?u32 = null;
    var declaration_inner: ?u32 = null;
    var declaration_outer: ?u32 = null;
    var parameter_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) expression_inner = analyzer.class_self_symbol_map.get(@intCast(raw));
        if (node.tag == .class_declaration) {
            declaration_inner = analyzer.class_self_symbol_map.get(@intCast(raw));
            const name_raw = parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").ClassExtra.name];
            declaration_outer = analyzer.symbol_ids.items[name_raw];
        }
    }
    const expr_id = expression_inner orelse return error.TestUnexpectedResult;
    const decl_id = declaration_inner orelse return error.TestUnexpectedResult;
    const outer_id = declaration_outer orelse return error.TestUnexpectedResult;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .binding_identifier or !std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "Inner")) continue;
        const id = analyzer.symbol_ids.items[raw] orelse continue;
        if (id != expr_id) parameter_id = id;
    }
    const param_id = parameter_id orelse return error.TestUnexpectedResult;
    try std.testing.expect(expr_id != param_id);
    try std.testing.expect(decl_id != outer_id);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var found_expr_storage = false;
    var found_decl_storage = false;
    var found_outer = false;
    var found_param = false;
    var accessor_refs: usize = 0;
    for (reachable) |raw| {
        if (raw >= edited.symbol_ids.len or transformer.ast.nodes.items[raw].tag != .binding_identifier) continue;
        const id = edited.symbol_ids[raw] orelse continue;
        if (id == expr_id) found_expr_storage = true;
        if (id == decl_id) found_decl_storage = true;
        if (id == outer_id) found_outer = true;
        if (id == param_id) found_param = true;
    }
    for (edited.references) |ref| {
        if (ref.node_index.isNone()) continue;
        const raw = @intFromEnum(ref.node_index);
        if (std.mem.indexOfScalar(u32, reachable, raw) == null) continue;
        if ((@intFromEnum(ref.symbol_id) == expr_id or @intFromEnum(ref.symbol_id) == decl_id) and
            raw >= transformer.parser_node_count and ref.flags.read) accessor_refs += 1;
    }
    try std.testing.expect(found_expr_storage and found_decl_storage and found_outer and found_param);
    try std.testing.expect(accessor_refs >= 2);

    const late_kind = @import("../semantic/symbol.zig").SyntheticKind.class_self_write_binding;
    var late_target_ids: [2]u32 = undefined;
    var late_target_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    var late_target_count: usize = 0;
    var late_readonly_count: usize = 0;
    var late_ignored_parameter_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != late_kind) continue;
        try std.testing.expect(!symbol.scope_id.isNone());
        if (std.mem.eql(u8, symbol.synthetic_name, "_classSelfWrite")) {
            try std.testing.expect(late_target_count < late_target_ids.len);
            late_target_ids[late_target_count] = @intCast(raw_id);
            late_target_scopes[late_target_count] = symbol.scope_id;
            late_target_count += 1;
        } else if (std.mem.eql(u8, symbol.synthetic_name, "_classSelfReadonly")) {
            late_readonly_count += 1;
        } else if (std.mem.eql(u8, symbol.synthetic_name, "_ignoredClassSelfWrite")) {
            late_ignored_parameter_count += 1;
        } else {
            return error.UnexpectedClassSelfWriteSyntheticName;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), late_target_count);
    try std.testing.expectEqual(@as(usize, 2), late_readonly_count);
    try std.testing.expectEqual(@as(usize, 2), late_ignored_parameter_count);
    try std.testing.expect(late_target_ids[0] != late_target_ids[1]);
    try std.testing.expect(late_target_scopes[0] != late_target_scopes[1]);

    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != late_kind) continue;
        const symbol_id: u32 = @intCast(raw_id);
        try std.testing.expect(symbol.scope_id.toIndex() < edited.scope_maps.len);
        try std.testing.expectEqual(
            @as(?usize, symbol_id),
            edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
        );
        var declaration_count: usize = 0;
        var exact_reference_count: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier and node.tag != .identifier_reference) continue;
            if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), symbol.synthetic_name)) continue;
            const exact_id = edited.symbol_ids[raw] orelse continue;
            if (exact_id != symbol_id) continue;
            if (node.tag == .binding_identifier) {
                declaration_count += 1;
            } else {
                exact_reference_count += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declaration_count);
        if (std.mem.eql(u8, symbol.synthetic_name, "_classSelfWrite") or
            std.mem.eql(u8, symbol.synthetic_name, "_classSelfReadonly"))
            try std.testing.expect(exact_reference_count > 0)
        else
            try std.testing.expectEqual(@as(usize, 0), exact_reference_count);
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != symbol_id or reference.node_index.isNone()) continue;
            const reference_raw = @intFromEnum(reference.node_index);
            try std.testing.expectEqual(@as(?u32, symbol_id), edited.symbol_ids[reference_raw]);
            var visible_scope = reference.scope_id;
            var is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (edited.scope_maps[visible_scope.toIndex()].get(symbol.synthetic_name)) |visible_id| {
                    if (visible_id == symbol_id) {
                        is_visible = true;
                        break;
                    }
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(is_visible);
        }
    }

    const alias_kind = @import("../semantic/symbol.zig").SyntheticKind.class_self_alias_binding;
    var alias_ids: [2]u32 = undefined;
    var alias_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    var alias_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_id| {
        if (symbol.synthetic_kind != alias_kind) continue;
        try std.testing.expectEqualStrings("_classSelf", symbol.synthetic_name);
        try std.testing.expect(!symbol.scope_id.isNone());
        try std.testing.expect(alias_count < alias_ids.len);
        alias_ids[alias_count] = @intCast(raw_id);
        alias_scopes[alias_count] = symbol.scope_id;
        alias_count += 1;

        const symbol_id: u32 = @intCast(raw_id);
        try std.testing.expect(symbol.scope_id.toIndex() < edited.scope_maps.len);
        try std.testing.expectEqual(
            @as(?usize, symbol_id),
            edited.scope_maps[symbol.scope_id.toIndex()].get(symbol.synthetic_name),
        );
        var binding_count: usize = 0;
        var reference_count: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier and node.tag != .identifier_reference) continue;
            if (!std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), symbol.synthetic_name)) continue;
            if (edited.symbol_ids[raw] != symbol_id) continue;
            if (node.tag == .binding_identifier) binding_count += 1 else reference_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), binding_count);
        try std.testing.expect(reference_count > 0);
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != symbol_id or reference.node_index.isNone()) continue;
            const reference_raw = @intFromEnum(reference.node_index);
            try std.testing.expectEqual(@as(?u32, symbol_id), edited.symbol_ids[reference_raw]);
            var visible_scope = reference.scope_id;
            var is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (edited.scope_maps[visible_scope.toIndex()].get(symbol.synthetic_name)) |visible_id| {
                    if (visible_id == symbol_id) {
                        is_visible = true;
                        break;
                    }
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(is_visible);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), alias_count);
    try std.testing.expect(alias_ids[0] != alias_ids[1]);
    try std.testing.expect(alias_scopes[0] != alias_scopes[1]);
}

test "#4819 ES5 class IIFE scopes enclose source class bodies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Declared { value() { return 1; } }
        \\const Named = class Inner { value() { return 2; } };
        \\const Anonymous = class { value() { return 3; } };
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var sources: std.ArrayList(struct { scope: u32, parent: @import("../semantic/scope.zig").ScopeId }) = .empty;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_declaration and node.tag != .class_expression) continue;
        const scope = analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult;
        try sources.append(allocator, .{ .scope = scope, .parent = analyzer.scopes.items[scope].parent });
    }
    try std.testing.expectEqual(@as(usize, 3), sources.items.len);
    var declared_inner: ?u32 = null;
    var declared_outer: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_declaration) continue;
        const name_raw = parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").ClassExtra.name];
        declared_inner = analyzer.class_self_symbol_map.get(@intCast(raw));
        declared_outer = analyzer.symbol_ids.items[name_raw];
        break;
    }
    const inner_id = declared_inner orelse return error.TestUnexpectedResult;
    const outer_id = declared_outer orelse return error.TestUnexpectedResult;
    try std.testing.expect(inner_id != outer_id);

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    for (sources.items) |item| {
        const wrapper = edited.scopes[item.scope].parent;
        try std.testing.expect(!wrapper.isNone());
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[wrapper.toIndex()].kind);
        try std.testing.expectEqual(item.parent, edited.scopes[wrapper.toIndex()].parent);
        try std.testing.expect(edited.scopes[wrapper.toIndex()].is_strict);
        var owners: usize = 0;
        var it = edited.scope_owner_map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != @intFromEnum(wrapper)) continue;
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.function_expression, transformer.ast.nodes.items[entry.key_ptr.*].tag);
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, entry.key_ptr.*) != null);
            owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), owners);
    }
    const inner_scope = edited.symbols.items[inner_id].scope_id;
    try std.testing.expectEqual(edited.scopes[sources.items[0].scope].parent, inner_scope);
    try std.testing.expectEqual(@as(?usize, @intCast(inner_id)), edited.scope_maps[inner_scope.toIndex()].get("Declared"));
    try std.testing.expectEqual(@as(?usize, @intCast(outer_id)), edited.scope_maps[edited.symbols.items[outer_id].scope_id.toIndex()].get("Declared"));
    var inner_binding_live = false;
    var outer_binding_live = false;
    for (reachable) |raw| {
        if (transformer.ast.nodes.items[raw].tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] == inner_id) inner_binding_live = true;
        if (edited.symbol_ids[raw] == outer_id) outer_binding_live = true;
    }
    try std.testing.expect(inner_binding_live and outer_binding_live);
}

test "#4819 ES5 named class expression stores exact inner self in wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const Value = class Named extends Object { static self() { return Named; } };");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var source_scope: ?u32 = null;
    var inner_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_expression) continue;
        const candidate = analyzer.class_self_symbol_map.get(@intCast(raw)) orelse continue;
        source_scope = analyzer.scope_owner_map.get(@intCast(raw));
        inner_id = candidate;
        break;
    }
    const class_scope = source_scope orelse return error.TestUnexpectedResult;
    const inner = inner_id orelse return error.TestUnexpectedResult;
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const wrapper = edited.scopes[class_scope].parent;
    try std.testing.expectEqual(wrapper, edited.symbols.items[inner].scope_id);
    try std.testing.expectEqual(@as(?usize, @intCast(inner)), edited.scope_maps[wrapper.toIndex()].get("Named"));
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var live_binding = false;
    for (reachable) |raw| {
        if (transformer.ast.nodes.items[raw].tag != .binding_identifier or raw >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[raw] == inner) live_binding = true;
    }
    try std.testing.expect(live_binding);
}

test "#4819 ES5 class IIFE check alias does not resolve to shadowing parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const X = class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } };");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var source_scope: ?u32 = null;
    var inner_id: ?u32 = null;
    var ctor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) {
            source_scope = analyzer.scope_owner_map.get(@intCast(raw));
            inner_id = analyzer.class_self_symbol_map.get(@intCast(raw));
        } else if (node.tag == .method_definition and ctor_scope == null) {
            ctor_scope = analyzer.scope_owner_map.get(@intCast(raw));
        }
    }
    const class_scope = source_scope orelse return error.TestUnexpectedResult;
    const inner = inner_id orelse return error.TestUnexpectedResult;
    const constructor_scope = ctor_scope orelse return error.TestUnexpectedResult;
    const parameter = analyzer.scope_maps.items[constructor_scope].get("Inner") orelse return error.TestUnexpectedResult;
    try std.testing.expect(parameter != inner);

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const wrapper = edited.scopes[class_scope].parent;
    try std.testing.expectEqual(wrapper, edited.symbols.items[inner].scope_id);
    const alias = edited.scope_maps[wrapper.toIndex()].get("_classSelf") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alias != inner and alias != parameter);
    try std.testing.expectEqual(@as(?usize, @intCast(parameter)), edited.scope_maps[constructor_scope].get("Inner"));
    var alias_constructor_reads: usize = 0;
    var inner_wrapper_reads: usize = 0;
    for (edited.references) |ref| {
        if (!ref.flags.read or ref.node_index.isNone()) continue;
        if (@intFromEnum(ref.symbol_id) == alias and @intFromEnum(ref.scope_id) == constructor_scope)
            alias_constructor_reads += 1;
        if (@intFromEnum(ref.symbol_id) == inner and ref.scope_id == wrapper)
            inner_wrapper_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_constructor_reads);
    // The exact class-self ID is used by the wrapper's constructor binding,
    // IIFE call, and final return. None may resolve to the shadowing parameter.
    try std.testing.expectEqual(@as(usize, 3), inner_wrapper_reads);
}

test "#4819 ES5 class declaration IIFE check keeps outer and inner identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "class Inner { constructor(Inner) { this.value = Inner; } static self() { return Inner; } }");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var source_scope: ?u32 = null;
    var inner_id: ?u32 = null;
    var outer_id: ?u32 = null;
    var ctor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) {
            source_scope = analyzer.scope_owner_map.get(@intCast(raw));
            inner_id = analyzer.class_self_symbol_map.get(@intCast(raw));
            const name_raw = parser.ast.extra_data.items[node.data.extra + @import("../parser/ast.zig").ClassExtra.name];
            outer_id = analyzer.symbol_ids.items[name_raw];
        } else if (node.tag == .method_definition and ctor_scope == null) {
            ctor_scope = analyzer.scope_owner_map.get(@intCast(raw));
        }
    }
    const class_scope = source_scope orelse return error.TestUnexpectedResult;
    const inner = inner_id orelse return error.TestUnexpectedResult;
    const outer = outer_id orelse return error.TestUnexpectedResult;
    const constructor_scope = ctor_scope orelse return error.TestUnexpectedResult;
    const parameter = analyzer.scope_maps.items[constructor_scope].get("Inner") orelse return error.TestUnexpectedResult;
    try std.testing.expect(inner != outer and inner != parameter and outer != parameter);

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const wrapper = edited.scopes[class_scope].parent;
    try std.testing.expectEqual(wrapper, edited.symbols.items[inner].scope_id);
    try std.testing.expect(edited.symbols.items[outer].scope_id != wrapper);
    const alias = edited.scope_maps[wrapper.toIndex()].get("_classSelf") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alias != inner and alias != outer and alias != parameter);
    var alias_constructor_reads: usize = 0;
    var inner_wrapper_reads: usize = 0;
    for (edited.references) |ref| {
        if (!ref.flags.read or ref.node_index.isNone()) continue;
        if (@intFromEnum(ref.symbol_id) == alias and @intFromEnum(ref.scope_id) == constructor_scope)
            alias_constructor_reads += 1;
        if (@intFromEnum(ref.symbol_id) == inner and ref.scope_id == wrapper)
            inner_wrapper_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), alias_constructor_reads);
    // The exact class-self ID is used by the wrapper's constructor binding,
    // IIFE call, and final return. None may resolve to the outer declaration
    // or the shadowing constructor parameter.
    try std.testing.expectEqual(@as(usize, 3), inner_wrapper_reads);
}

test "#4819 using class copies preserve exact source scope owners" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\using resource = { [Symbol.dispose]() {} };
        \\class Plain { value() { return 1; } }
        \\export class Named { value() { return 2; } }
        \\export default class Default { value() { return 3; } }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var source_scopes: std.ArrayList(u32) = .empty;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .class_declaration) continue;
        try source_scopes.append(allocator, analyzer.scope_owner_map.get(@intCast(raw)) orelse return error.TestUnexpectedResult);
    }
    try std.testing.expectEqual(@as(usize, 3), source_scopes.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    for (source_scopes.items) |source_scope| {
        const wrapper = edited.scopes[source_scope].parent;
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[wrapper.toIndex()].kind);
        var live_owners: usize = 0;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != @intFromEnum(wrapper)) continue;
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.function_expression, transformer.ast.nodes.items[entry.key_ptr.*].tag);
            try std.testing.expect(std.mem.indexOfScalar(u32, reachable, entry.key_ptr.*) != null);
            live_owners += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), live_owners);
    }
}

test "#4819 default derived constructors own exact newTarget symbols per function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base {}
        \\const _newTarget = 1;
        \\class First extends Base {}
        \\class Second extends Base {}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_symbols: std.ArrayList(struct { id: u32, scope: u32 }) = .empty;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_newTarget2")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const raw_id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        const scope_id = @intFromEnum(edited.symbols.items[raw_id].scope_id);
        try generated_symbols.append(allocator, .{ .id = raw_id, .scope = scope_id });
    }

    try std.testing.expectEqual(@as(usize, 2), generated_symbols.items.len);
    try std.testing.expect(generated_symbols.items[0].id != generated_symbols.items[1].id);
    try std.testing.expect(generated_symbols.items[0].scope != generated_symbols.items[1].scope);
    for (generated_symbols.items) |generated| {
        const scope: @import("../semantic/scope.zig").ScopeId = @enumFromInt(generated.scope);
        try std.testing.expectEqual(@as(?usize, @intCast(generated.id)), edited.scope_maps[generated.scope].get("_newTarget2"));

        var declarations: usize = 0;
        var reads: usize = 0;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != generated.id) continue;
            if (reference.flags.declare) {
                declarations += 1;
                try std.testing.expectEqual(scope, reference.scope_id);
            }
            if (reference.flags.read) {
                reads += 1;
                try std.testing.expectEqual(scope, reference.scope_id);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        try std.testing.expectEqual(@as(usize, 1), reads);
    }
}

test "#4819 explicit derived constructor super calls reuse the exact newTarget handle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base {}
        \\const _newTarget = 1;
        \\class ArrowSuper extends Base { constructor(readParam = () => new.target) { const readTarget = () => new.target; const call = () => super(); call(); readTarget(); readParam(); } }
        \\class DirectSuper extends Base { constructor() { super(); } }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_symbols: std.ArrayList(struct { id: u32, scope: u32 }) = .empty;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_newTarget2")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const raw_id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[raw_id].kind != .variable_var) continue;
        const scope_id = @intFromEnum(edited.symbols.items[raw_id].scope_id);
        try generated_symbols.append(allocator, .{ .id = raw_id, .scope = scope_id });
    }

    try std.testing.expectEqual(@as(usize, 2), generated_symbols.items.len);
    try std.testing.expect(generated_symbols.items[0].id != generated_symbols.items[1].id);
    try std.testing.expect(generated_symbols.items[0].scope != generated_symbols.items[1].scope);
    var direct_read = false;
    var nested_read = false;
    var total_reads: usize = 0;
    for (generated_symbols.items) |generated| {
        const scope: @import("../semantic/scope.zig").ScopeId = @enumFromInt(generated.scope);
        try std.testing.expectEqual(@as(?usize, @intCast(generated.id)), edited.scope_maps[generated.scope].get("_newTarget2"));

        var declarations: usize = 0;
        var reads: usize = 0;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != generated.id) continue;
            if (reference.flags.declare) {
                declarations += 1;
                try std.testing.expectEqual(scope, reference.scope_id);
            }
            if (reference.flags.read) {
                reads += 1;
                if (reference.scope_id == scope) direct_read = true else nested_read = true;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), declarations);
        try std.testing.expect(reads >= 1 and reads <= 3);
        total_reads += reads;
    }
    try std.testing.expect(direct_read and nested_read);
    try std.testing.expectEqual(@as(usize, 4), total_reads);
}

test "#4819 Stage 3 class copy nests under decorator and ES5 IIFE scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\@logged
        \\class Box { @logged method() { return 1; } constructor() { this.ready = true; } @logged value = 6; @logged other = 7; @logged accessor current = 8; @logged static staticValue = 9; @logged static method() { return 2; } @logged static get currentStatic() { return 3; } @logged #secret() { return 4; } @logged static #staticSecret() { return 5; } }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    var class_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) class_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    const source_parent = analyzer.scopes.items[source_scope].parent;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const class_iife = edited.scopes[source_scope].parent;
    const decorator_iife = edited.scopes[class_iife.toIndex()].parent;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[class_iife.toIndex()].kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[decorator_iife.toIndex()].kind);
    try std.testing.expectEqual(source_parent, edited.scopes[decorator_iife.toIndex()].parent);

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var metadata_id: ?u32 = null;
    var metadata_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_metadata")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_const) continue;
        metadata_id = id;
        metadata_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), metadata_bindings);
    const exact_metadata_id = metadata_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_metadata_binding,
        edited.symbols.items[exact_metadata_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_metadata", edited.symbols.items[exact_metadata_id].synthetic_name);
    const metadata_scope = edited.symbols.items[exact_metadata_id].scope_id;
    try std.testing.expectEqual(class_iife, metadata_scope);
    try std.testing.expectEqual(@as(?usize, exact_metadata_id), edited.scope_maps[metadata_scope.toIndex()].get("_metadata"));

    var metadata_reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_metadata_id) continue;
        if (!reference.flags.read) continue;
        if (reference.node_index.isNone()) return error.TestUnexpectedResult;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_metadata", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        var visible_scope = reference.scope_id;
        var metadata_is_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == metadata_scope) {
                metadata_is_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(metadata_is_visible);
        metadata_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 12), metadata_reads);

    for ([_][]const u8{ "_value_initializers", "_other_initializers", "_current_initializers", "_staticValue_initializers" }) |initializer_name| {
        var initializer_id: ?u32 = null;
        var initializer_bindings: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), initializer_name)) continue;
            if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
            const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            if (edited.symbols.items[id].kind != .variable_let) continue;
            initializer_id = id;
            initializer_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), initializer_bindings);
        const exact_initializer_id = initializer_id orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
            edited.symbols.items[exact_initializer_id].synthetic_kind.?,
        );
        const initializer_scope = edited.symbols.items[exact_initializer_id].scope_id;
        try std.testing.expectEqual(decorator_iife, initializer_scope);
        try std.testing.expectEqual(
            @as(?usize, exact_initializer_id),
            edited.scope_maps[initializer_scope.toIndex()].get(initializer_name),
        );

        var initializer_reads: usize = 0;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != exact_initializer_id or reference.node_index.isNone()) continue;
            const node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
            try std.testing.expectEqualStrings(initializer_name, transformer.ast.getText(node.data.string_ref));
            try std.testing.expect(reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            var visible_scope = reference.scope_id;
            var initializer_is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (visible_scope == initializer_scope) {
                    initializer_is_visible = true;
                    break;
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(initializer_is_visible);
            initializer_reads += 1;
        }
        try std.testing.expectEqual(@as(usize, 2), initializer_reads);
    }

    const extra_initializer_cases = [_]struct { name: []const u8, reads: usize }{
        .{ .name = "_value_extraInitializers", .reads = 2 },
        .{ .name = "_other_extraInitializers", .reads = 2 },
        .{ .name = "_current_extraInitializers", .reads = 2 },
        .{ .name = "_staticValue_extraInitializers", .reads = 1 },
    };
    for (extra_initializer_cases) |case| {
        var extra_initializer_id: ?u32 = null;
        var extra_initializer_bindings: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), case.name)) continue;
            if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
            const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            if (edited.symbols.items[id].kind != .variable_let) continue;
            extra_initializer_id = id;
            extra_initializer_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), extra_initializer_bindings);
        const exact_extra_initializer_id = extra_initializer_id orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
            edited.symbols.items[exact_extra_initializer_id].synthetic_kind.?,
        );
        const extra_initializer_scope = edited.symbols.items[exact_extra_initializer_id].scope_id;
        try std.testing.expectEqual(decorator_iife, extra_initializer_scope);
        try std.testing.expectEqual(
            @as(?usize, exact_extra_initializer_id),
            edited.scope_maps[extra_initializer_scope.toIndex()].get(case.name),
        );

        var extra_initializer_reads: usize = 0;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != exact_extra_initializer_id or reference.node_index.isNone()) continue;
            const node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
            try std.testing.expectEqualStrings(case.name, transformer.ast.getText(node.data.string_ref));
            try std.testing.expect(reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            var visible_scope = reference.scope_id;
            var extra_initializer_is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (visible_scope == extra_initializer_scope) {
                    extra_initializer_is_visible = true;
                    break;
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(extra_initializer_is_visible);
            extra_initializer_reads += 1;
        }
        try std.testing.expectEqual(case.reads, extra_initializer_reads);
    }

    var class_decorators_id: ?u32 = null;
    var class_decorators_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_classDecorators")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        class_decorators_id = id;
        class_decorators_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_decorators_bindings);
    const exact_class_decorators_id = class_decorators_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_class_decorator_binding,
        edited.symbols.items[exact_class_decorators_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_classDecorators", edited.symbols.items[exact_class_decorators_id].synthetic_name);
    const class_decorators_scope = edited.symbols.items[exact_class_decorators_id].scope_id;
    try std.testing.expectEqual(decorator_iife, class_decorators_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_class_decorators_id),
        edited.scope_maps[class_decorators_scope.toIndex()].get("_classDecorators"),
    );

    var class_decorators_reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_class_decorators_id or !reference.flags.read) continue;
        if (reference.node_index.isNone()) return error.TestUnexpectedResult;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_classDecorators", transformer.ast.getText(node.data.string_ref));
        var visible_scope = reference.scope_id;
        var class_decorators_are_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == class_decorators_scope) {
                class_decorators_are_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(class_decorators_are_visible);
        class_decorators_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_decorators_reads);

    var class_descriptor_id: ?u32 = null;
    var class_descriptor_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_classDescriptor")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        class_descriptor_id = id;
        class_descriptor_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_descriptor_bindings);
    const exact_class_descriptor_id = class_descriptor_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_class_decorator_binding,
        edited.symbols.items[exact_class_descriptor_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_classDescriptor", edited.symbols.items[exact_class_descriptor_id].synthetic_name);
    const class_descriptor_scope = edited.symbols.items[exact_class_descriptor_id].scope_id;
    try std.testing.expectEqual(decorator_iife, class_descriptor_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_class_descriptor_id),
        edited.scope_maps[class_descriptor_scope.toIndex()].get("_classDescriptor"),
    );

    var class_descriptor_reads: usize = 0;
    var class_descriptor_writes: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_class_descriptor_id) continue;
        if (reference.node_index.isNone()) {
            try std.testing.expect(!reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            continue;
        }
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_classDescriptor", transformer.ast.getText(node.data.string_ref));
        var visible_scope = reference.scope_id;
        var class_descriptor_is_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == class_descriptor_scope) {
                class_descriptor_is_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(class_descriptor_is_visible);
        if (reference.flags.write) {
            try std.testing.expect(!reference.flags.read);
            class_descriptor_writes += 1;
        } else {
            try std.testing.expect(reference.flags.read);
            class_descriptor_reads += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), class_descriptor_reads);
    try std.testing.expectEqual(@as(usize, 1), class_descriptor_writes);

    var class_extra_initializers_id: ?u32 = null;
    var class_extra_initializers_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_classExtraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        class_extra_initializers_id = id;
        class_extra_initializers_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_extra_initializers_bindings);
    const exact_class_extra_initializers_id = class_extra_initializers_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_class_decorator_binding,
        edited.symbols.items[exact_class_extra_initializers_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_classExtraInitializers", edited.symbols.items[exact_class_extra_initializers_id].synthetic_name);
    const class_extra_initializers_scope = edited.symbols.items[exact_class_extra_initializers_id].scope_id;
    try std.testing.expectEqual(decorator_iife, class_extra_initializers_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_class_extra_initializers_id),
        edited.scope_maps[class_extra_initializers_scope.toIndex()].get("_classExtraInitializers"),
    );

    var class_extra_initializers_reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_class_extra_initializers_id or !reference.flags.read) continue;
        if (reference.node_index.isNone()) return error.TestUnexpectedResult;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_classExtraInitializers", transformer.ast.getText(node.data.string_ref));
        var visible_scope = reference.scope_id;
        var class_extra_initializers_are_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == class_extra_initializers_scope) {
                class_extra_initializers_are_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(class_extra_initializers_are_visible);
        class_extra_initializers_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), class_extra_initializers_reads);

    var class_this_id: ?u32 = null;
    var class_this_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_classThis")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        class_this_id = id;
        class_this_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), class_this_bindings);
    const exact_class_this_id = class_this_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_class_this_binding,
        edited.symbols.items[exact_class_this_id].synthetic_kind.?,
    );
    try std.testing.expectEqualStrings("_classThis", edited.symbols.items[exact_class_this_id].synthetic_name);
    const class_this_scope = edited.symbols.items[exact_class_this_id].scope_id;
    try std.testing.expectEqual(decorator_iife, class_this_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_class_this_id),
        edited.scope_maps[class_this_scope.toIndex()].get("_classThis"),
    );

    var class_this_reads: usize = 0;
    var class_this_writes: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_class_this_id) continue;
        if (reference.node_index.isNone()) {
            try std.testing.expect(!reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            continue;
        }
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_classThis", transformer.ast.getText(node.data.string_ref));
        var visible_scope = reference.scope_id;
        var class_this_is_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == class_this_scope) {
                class_this_is_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(class_this_is_visible);
        if (reference.flags.write) {
            try std.testing.expect(!reference.flags.read);
            class_this_writes += 1;
        } else {
            try std.testing.expect(reference.flags.read);
            class_this_reads += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), class_this_reads);
    try std.testing.expectEqual(@as(usize, 2), class_this_writes);

    var static_extra_initializers_id: ?u32 = null;
    var static_extra_initializers_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_staticExtraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        static_extra_initializers_id = id;
        static_extra_initializers_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), static_extra_initializers_bindings);
    const exact_static_extra_initializers_id = static_extra_initializers_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
        edited.symbols.items[exact_static_extra_initializers_id].synthetic_kind.?,
    );
    const static_extra_initializers_scope = edited.symbols.items[exact_static_extra_initializers_id].scope_id;
    try std.testing.expectEqual(decorator_iife, static_extra_initializers_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_static_extra_initializers_id),
        edited.scope_maps[static_extra_initializers_scope.toIndex()].get("_staticExtraInitializers"),
    );

    var static_extra_initializers_reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_static_extra_initializers_id) continue;
        if (reference.node_index.isNone()) {
            try std.testing.expect(!reference.flags.read);
            try std.testing.expect(!reference.flags.write);
            continue;
        }
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_staticExtraInitializers", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        var visible_scope = reference.scope_id;
        var static_extra_initializers_are_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == static_extra_initializers_scope) {
                static_extra_initializers_are_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(static_extra_initializers_are_visible);
        static_extra_initializers_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), static_extra_initializers_reads);

    var instance_extra_initializers_id: ?u32 = null;
    var instance_extra_initializers_bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_instanceExtraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        instance_extra_initializers_id = id;
        instance_extra_initializers_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), instance_extra_initializers_bindings);
    const exact_instance_extra_initializers_id = instance_extra_initializers_id orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
        edited.symbols.items[exact_instance_extra_initializers_id].synthetic_kind.?,
    );
    const instance_extra_initializers_scope = edited.symbols.items[exact_instance_extra_initializers_id].scope_id;
    try std.testing.expectEqual(decorator_iife, instance_extra_initializers_scope);
    try std.testing.expectEqual(
        @as(?usize, exact_instance_extra_initializers_id),
        edited.scope_maps[instance_extra_initializers_scope.toIndex()].get("_instanceExtraInitializers"),
    );

    var instance_extra_initializers_reads: usize = 0;
    var instance_extra_initializers_reference_scopes: [3]@import("../semantic/scope.zig").ScopeId = undefined;
    var instance_extra_initializers_scope_counts: [3]usize = .{ 0, 0, 0 };
    var instance_extra_initializers_scope_len: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_instance_extra_initializers_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_instanceExtraInitializers", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        var visible_scope = reference.scope_id;
        var instance_extra_initializers_are_visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == instance_extra_initializers_scope) {
                instance_extra_initializers_are_visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(instance_extra_initializers_are_visible);
        var scope_slot: usize = 0;
        while (scope_slot < instance_extra_initializers_scope_len) : (scope_slot += 1) {
            if (instance_extra_initializers_reference_scopes[scope_slot] == reference.scope_id) break;
        }
        if (scope_slot == instance_extra_initializers_scope_len) {
            if (instance_extra_initializers_scope_len == instance_extra_initializers_reference_scopes.len) return error.TestUnexpectedResult;
            instance_extra_initializers_reference_scopes[scope_slot] = reference.scope_id;
            instance_extra_initializers_scope_len += 1;
        }
        instance_extra_initializers_scope_counts[scope_slot] += 1;
        instance_extra_initializers_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), instance_extra_initializers_reads);
    try std.testing.expectEqual(@as(usize, 2), instance_extra_initializers_scope_len);
    try std.testing.expect(
        (instance_extra_initializers_scope_counts[0] == 2 and instance_extra_initializers_scope_counts[1] == 1) or
            (instance_extra_initializers_scope_counts[0] == 1 and instance_extra_initializers_scope_counts[1] == 2),
    );

    var member_decorator_bindings: usize = 0;
    var member_decorator_names: std.ArrayList([]const u8) = .empty;
    defer member_decorator_names.deinit(allocator);
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (std.mem.indexOf(u8, name, "_decorators") == null) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
            edited.symbols.items[id].synthetic_kind.?,
        );
        member_decorator_bindings += 1;
        const decorator_scope = edited.symbols.items[id].scope_id;
        try std.testing.expectEqual(decorator_iife, decorator_scope);
        try std.testing.expectEqual(@as(?usize, id), edited.scope_maps[decorator_scope.toIndex()].get(name));
        for (member_decorator_names.items) |previous| try std.testing.expect(!std.mem.eql(u8, previous, name));
        try member_decorator_names.append(allocator, name);

        var reads: usize = 0;
        var writes: usize = 0;
        var reference_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != id or reference.node_index.isNone()) continue;
            const reference_node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, reference_node.tag);
            try std.testing.expectEqualStrings(name, transformer.ast.getText(reference_node.data.string_ref));
            if (reference_scope) |previous_scope| {
                try std.testing.expectEqual(previous_scope, reference.scope_id);
            } else {
                reference_scope = reference.scope_id;
            }
            if (reference.flags.write) {
                try std.testing.expect(!reference.flags.read);
                writes += 1;
            } else {
                try std.testing.expect(reference.flags.read);
                reads += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), reads);
        try std.testing.expectEqual(@as(usize, 1), writes);
        try std.testing.expect(reference_scope != null);
    }
    try std.testing.expectEqual(@as(usize, 9), member_decorator_bindings);

    for ([_][]const u8{ "_private_secret_descriptor", "_private_staticSecret_descriptor" }) |descriptor_name| {
        var private_descriptor_id: ?u32 = null;
        var private_descriptor_bindings: usize = 0;
        for (reachable) |raw| {
            const node = transformer.ast.nodes.items[raw];
            if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), descriptor_name)) continue;
            if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
            const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
            if (edited.symbols.items[id].kind != .variable_let) continue;
            private_descriptor_id = id;
            private_descriptor_bindings += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), private_descriptor_bindings);
        const exact_private_descriptor_id = private_descriptor_id orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @import("../semantic/symbol.zig").SyntheticKind.stage3_member_decorator_binding,
            edited.symbols.items[exact_private_descriptor_id].synthetic_kind.?,
        );
        const private_descriptor_scope = edited.symbols.items[exact_private_descriptor_id].scope_id;
        try std.testing.expectEqual(decorator_iife, private_descriptor_scope);
        try std.testing.expectEqual(
            @as(?usize, exact_private_descriptor_id),
            edited.scope_maps[private_descriptor_scope.toIndex()].get(descriptor_name),
        );

        var private_descriptor_reads: usize = 0;
        var private_descriptor_writes: usize = 0;
        var private_descriptor_read_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        var private_descriptor_write_scope: ?@import("../semantic/scope.zig").ScopeId = null;
        for (edited.references) |reference| {
            if (@intFromEnum(reference.symbol_id) != exact_private_descriptor_id or reference.node_index.isNone()) continue;
            const node = transformer.ast.getNode(reference.node_index);
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
            try std.testing.expectEqualStrings(descriptor_name, transformer.ast.getText(node.data.string_ref));
            var visible_scope = reference.scope_id;
            var descriptor_is_visible = false;
            var hops: usize = 0;
            while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
                if (visible_scope == private_descriptor_scope) {
                    descriptor_is_visible = true;
                    break;
                }
                visible_scope = edited.scopes[visible_scope.toIndex()].parent;
            }
            try std.testing.expect(descriptor_is_visible);
            if (reference.flags.write) {
                try std.testing.expect(!reference.flags.read);
                private_descriptor_writes += 1;
                private_descriptor_write_scope = reference.scope_id;
            } else {
                try std.testing.expect(reference.flags.read);
                private_descriptor_reads += 1;
                try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[reference.scope_id.toIndex()].kind);
                private_descriptor_read_scope = reference.scope_id;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), private_descriptor_reads);
        try std.testing.expectEqual(@as(usize, 1), private_descriptor_writes);
        try std.testing.expect(private_descriptor_read_scope.? != private_descriptor_write_scope.?);
    }
}

test "#4819 Stage 3 member extra initializer binds its synthetic constructor read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\class Box { @logged value = 6; }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var class_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) class_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var extra_initializer_id: ?u32 = null;
    var bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_value_extraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        extra_initializer_id = id;
        bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    const exact_id = extra_initializer_id orelse return error.TestUnexpectedResult;
    const binding_scope = edited.symbols.items[exact_id].scope_id;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[binding_scope.toIndex()].kind);
    try std.testing.expect(binding_scope.toIndex() != source_scope);
    try std.testing.expectEqual(@as(?usize, exact_id), edited.scope_maps[binding_scope.toIndex()].get("_value_extraInitializers"));

    var reads: usize = 0;
    var read_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_value_extraInitializers", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        var visible_scope = reference.scope_id;
        var visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == binding_scope) {
                visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(visible);
        if (reads >= read_scopes.len) return error.TestUnexpectedResult;
        read_scopes[reads] = reference.scope_id;
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expect(read_scopes[0] != read_scopes[1]);
}

test "#4819 Stage 3 instance extra initializer keeps exact block and constructor reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\class Box { @logged method() { return 1; } }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var class_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_declaration) class_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var instance_initializer_id: ?u32 = null;
    var bindings: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_instanceExtraInitializers")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        if (edited.symbols.items[id].kind != .variable_let) continue;
        instance_initializer_id = id;
        bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    const exact_id = instance_initializer_id orelse return error.TestUnexpectedResult;
    const binding_scope = edited.symbols.items[exact_id].scope_id;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[binding_scope.toIndex()].kind);
    try std.testing.expect(binding_scope.toIndex() != source_scope);
    try std.testing.expectEqual(@as(?usize, exact_id), edited.scope_maps[binding_scope.toIndex()].get("_instanceExtraInitializers"));

    var reads: usize = 0;
    var read_scopes: [2]@import("../semantic/scope.zig").ScopeId = undefined;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings("_instanceExtraInitializers", transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[reference.scope_id.toIndex()].kind);
        var visible_scope = reference.scope_id;
        var visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == binding_scope) {
                visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(visible);
        if (reads >= read_scopes.len) return error.TestUnexpectedResult;
        read_scopes[reads] = reference.scope_id;
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expect(read_scopes[0] != read_scopes[1]);
}

test "#4819 ES5 class methods retain original scope on emitted functions and bind body temps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Box {
        \\  stamp = 0;
        \\  constructor(v) { this.value = v.next() ?? 1; }
        \\  ["read"](x) { return x.next() ?? this.value; }
        \\  get current() { return this.read() ?? 0; }
        \\  set current(v) { this.value = v.next() ?? 2; }
        \\}
        \\const Direct = class Named { constructor(v) { this.value = v.next() ?? 3; } };
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var original_methods: std.ArrayList(struct { owner: NodeIndex, scope: u32 }) = .empty;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag != .method_definition) continue;
        const owner: NodeIndex = @enumFromInt(@as(u32, @intCast(index)));
        if (analyzer.scope_owner_map.get(@intFromEnum(owner))) |scope| {
            try original_methods.append(allocator, .{ .owner = owner, .scope = scope });
        }
    }
    try std.testing.expectEqual(@as(usize, 5), original_methods.items.len);

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_temp_refs: usize = 0;
    for (original_methods.items) |method| {
        try std.testing.expect(edited.scope_owner_map.get(@intFromEnum(method.owner)) == null);
        var final_owner: ?NodeIndex = null;
        var owners = edited.scope_owner_map.iterator();
        while (owners.next()) |entry| {
            if (entry.value_ptr.* != method.scope) continue;
            try std.testing.expect(final_owner == null);
            final_owner = @enumFromInt(entry.key_ptr.*);
        }
        const owner = final_owner orelse return error.TestUnexpectedResult;
        const tag = transformer.ast.getNode(owner).tag;
        try std.testing.expect(tag == .function_declaration or tag == .function_expression);
        try std.testing.expect(std.mem.indexOfScalar(u32, reachable, @intFromEnum(owner)) != null);
    }
    for (edited.references) |ref| {
        if (ref.node_index.isNone() or @intFromEnum(ref.node_index) < transformer.parser_node_count) continue;
        const node = transformer.ast.getNode(ref.node_index);
        if (node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (!std.mem.startsWith(u8, name, "_")) continue;
        for (original_methods.items) |method| {
            if (@intFromEnum(ref.scope_id) == method.scope) generated_temp_refs += 1;
        }
    }
    try std.testing.expect(generated_temp_refs >= 5);
}

test "#4819 simple named class keeps inner name environment and binds constructor check alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const X = class C { constructor(C) { this.value = C; } };");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var class_scope: ?u32 = null;
    var inner_id: ?u32 = null;
    var constructor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) {
            class_scope = analyzer.scope_owner_map.get(@intCast(raw));
            inner_id = analyzer.class_self_symbol_map.get(@intCast(raw));
        } else if (node.tag == .method_definition) {
            constructor_scope = analyzer.scope_owner_map.get(@intCast(raw));
        }
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    const self_id = inner_id orelse return error.TestUnexpectedResult;
    const ctor_scope = constructor_scope orelse return error.TestUnexpectedResult;
    const original_parent = analyzer.scopes.items[source_scope].parent;

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    const wrapper = edited.scopes[source_scope].parent;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[wrapper.toIndex()].kind);
    try std.testing.expectEqual(original_parent, edited.scopes[wrapper.toIndex()].parent);
    try std.testing.expectEqual(@as(@import("../semantic/scope.zig").ScopeId, @enumFromInt(source_scope)), edited.symbols.items[self_id].scope_id);
    const alias = edited.scope_maps[wrapper.toIndex()].get("_classSelf") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alias != self_id);
    var wrapper_reads: usize = 0;
    var ctor_reads: usize = 0;
    for (edited.references) |ref| {
        if (@intFromEnum(ref.symbol_id) != alias or !ref.flags.read) continue;
        if (ref.scope_id == wrapper) wrapper_reads += 1;
        if (@intFromEnum(ref.scope_id) == ctor_scope) ctor_reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), wrapper_reads);
    try std.testing.expectEqual(@as(usize, 1), ctor_reads);
}

test "#4819 anonymous ES5 class expression name gets an exact SymbolId before wrapper refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "const _Class = 17; function consume(value) {} consume(class { method() { return 1; } });";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var class_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag == .class_expression) class_scope = analyzer.scope_owner_map.get(@intCast(raw));
    }
    const source_scope = class_scope orelse return error.TestUnexpectedResult;
    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var generated_name_id: ?u32 = null;
    var generated_name_bindings: usize = 0;
    var generated_name: ?[]const u8 = null;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse continue;
        if (edited.symbols.items[id].kind != .function_decl) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (!std.mem.startsWith(u8, name, "_Class")) continue;
        generated_name_id = id;
        generated_name = name;
        generated_name_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), generated_name_bindings);
    const exact_id = generated_name_id orelse return error.TestUnexpectedResult;
    const exact_name = generated_name orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, exact_name, "_Class"));
    const binding_scope = edited.symbols.items[exact_id].scope_id;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[binding_scope.toIndex()].kind);
    try std.testing.expectEqual(@as(?usize, exact_id), edited.scope_maps[binding_scope.toIndex()].get(exact_name));
    try std.testing.expectEqual(binding_scope, edited.scopes[source_scope].parent);

    var reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != exact_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.identifier_reference, node.tag);
        try std.testing.expectEqualStrings(exact_name, transformer.ast.getText(node.data.string_ref));
        try std.testing.expect(reference.flags.read);
        try std.testing.expect(!reference.flags.write);
        var visible_scope = reference.scope_id;
        var visible = false;
        var hops: usize = 0;
        while (!visible_scope.isNone() and hops < edited.scopes.len) : (hops += 1) {
            if (visible_scope == binding_scope) {
                visible = true;
                break;
            }
            visible_scope = edited.scopes[visible_scope.toIndex()].parent;
        }
        try std.testing.expect(visible);
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), reads);
}

test "#4819 anonymous default ES5 class export has an exact generated binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "class Base { static read() { return 1; } } const _Class = 17; const _Class2 = 18; export default class extends Base { static self() { return super.read(); } }";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var report = try coverage.checkStrictWithExactExternalEvidence(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("anonymous-default-class-es5.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);
    var generated_bindings: usize = 0;
    var outer_symbol: ?u32 = null;
    var inner_symbol: ?u32 = null;
    for (reachable) |raw| {
        const binding = transformer.ast.nodes.items[raw];
        if (binding.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(binding.data.string_ref), "_Class3")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        generated_bindings += 1;
        switch (edited.symbols.items[id].kind) {
            .variable_var => outer_symbol = id,
            .function_decl => inner_symbol = id,
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), generated_bindings);
    const outer_id = outer_symbol orelse return error.TestUnexpectedResult;
    const inner_id = inner_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expect(outer_id != inner_id);
    try std.testing.expectEqual(
        @as(?usize, outer_id),
        edited.scope_maps[edited.symbols.items[outer_id].scope_id.toIndex()].get("_Class3"),
    );
    try std.testing.expectEqual(
        @as(?usize, inner_id),
        edited.scope_maps[edited.symbols.items[inner_id].scope_id.toIndex()].get("_Class3"),
    );

    var export_uses_outer_symbol = false;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .export_default_declaration) continue;
        const operand: NodeIndex = node.data.unary.operand;
        if (operand.isNone() or @intFromEnum(operand) >= edited.symbol_ids.len) continue;
        if (edited.symbol_ids[@intFromEnum(operand)] == outer_id) export_uses_outer_symbol = true;
    }
    try std.testing.expect(export_uses_outer_symbol);

    var inner_reads: usize = 0;
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) == inner_id and reference.flags.read) inner_reads += 1;
    }
    try std.testing.expect(inner_reads > 0);
}

test "#4819 anonymous default ES5 class export marks its late output name by SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "export default class { static value() { return 1; } }");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
        .defer_runtime_helper_name_resolution = true,
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;

    var outer_class_symbols: usize = 0;
    for (edited.symbols.items) |symbol| {
        if ((symbol.synthetic_kind orelse continue) != .anonymous_class_export_binding) continue;
        try std.testing.expectEqualStrings("_Class", symbol.synthetic_name);
        outer_class_symbols += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), outer_class_symbols);
}

test "#4819 Stage 3 decorated anonymous default class preserves exact generated names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function tag(value, context) { return value; }
        \\@tag
        \\export default class { static value = 1; }
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var wrapper_symbol: ?usize = null;
    var constructor_symbol: ?usize = null;
    for (edited.symbols.items, 0..) |symbol, id| {
        if (!std.mem.eql(u8, symbol.synthetic_name, "_Class") or symbol.synthetic_kind != null) continue;
        if (symbol.kind == .variable_var) wrapper_symbol = id;
        if (symbol.kind == .function_decl) constructor_symbol = id;
    }
    const wrapper_id = wrapper_symbol orelse return error.TestUnexpectedResult;
    const constructor_id = constructor_symbol orelse return error.TestUnexpectedResult;
    try std.testing.expect(wrapper_id != constructor_id);
    try std.testing.expect(edited.symbols.items[wrapper_id].scope_id != edited.symbols.items[constructor_id].scope_id);

    const reachable = try ast_walk.collectReachableNodeIndicesFrom(allocator, transformer.ast, root);
    var wrapper_binding_count: usize = 0;
    var wrapper_write_count: usize = 0;
    var constructor_binding_count: usize = 0;
    var wrapper_reference_node_count: usize = 0;
    for (reachable) |reachable_node| {
        const raw = reachable_node;
        const node = transformer.ast.getNode(@enumFromInt(raw));
        const name_span = switch (node.tag) {
            .binding_identifier, .identifier_reference, .assignment_target_identifier => node.data.string_ref,
            else => continue,
        };
        if (!std.mem.eql(u8, transformer.ast.getText(name_span), "_Class")) continue;
        const symbol_id = if (raw < edited.symbol_ids.len) edited.symbol_ids[raw] else null;
        const exact_id = symbol_id orelse continue;
        if (exact_id == wrapper_id and node.tag == .binding_identifier) wrapper_binding_count += 1;
        if (exact_id == constructor_id and node.tag == .binding_identifier) constructor_binding_count += 1;
        if (exact_id == wrapper_id and (node.tag == .identifier_reference or node.tag == .assignment_target_identifier)) {
            wrapper_reference_node_count += 1;
            var found_reference = false;
            for (edited.references) |reference| {
                if (reference.node_index != @as(NodeIndex, @enumFromInt(raw))) continue;
                found_reference = true;
            }
            try std.testing.expect(found_reference);
        }
    }
    for (edited.references) |reference| {
        if (@intFromEnum(reference.symbol_id) != wrapper_id or reference.node_index.isNone()) continue;
        const node = transformer.ast.getNode(reference.node_index);
        if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
        try std.testing.expect(reference.flags.write);
        try std.testing.expect(!reference.flags.read);
        wrapper_write_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), wrapper_binding_count);
    try std.testing.expectEqual(@as(usize, 1), constructor_binding_count);
    try std.testing.expectEqual(@as(usize, 2), wrapper_reference_node_count);
    try std.testing.expectEqual(@as(usize, 2), wrapper_write_count);
    var report = try coverage.checkStrictWithExactExternalEvidence(
        allocator,
        transformer.ast,
        root,
        transformer.parser_node_count,
        edited.symbol_ids,
        edited.symbols.items,
        edited.scopes,
        &edited.scope_owner_map,
        edited.references,
        if (transformer.synthetic_idents) |*synthetic| synthetic else null,
        .{
            .unresolved_reference_nodes = &analyzer.unresolved_reference_nodes,
            .explicit_global_reference_nodes = &transformer.explicit_global_reference_nodes,
            .reference_origin_map = &transformer.reference_origin_map,
        },
    );
    defer report.deinit(allocator);
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("stage3-anonymous-default-class-es5.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());
}

test "#4819 inferred anonymous class does not gain a named-class wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const Inferred = class {}; console.log(Inferred.name);");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.class_self_symbol_map.count());

    var transformer = try Transformer.init(allocator, &parser.ast, .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 0), transformer.preserved_simple_class_names.items.len);
    _ = try transformer.finishSemanticEdit();
}

test "#4819 decorated explicit constructor binds generated nullish temp in original scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function logged(value) { return value; }
        \\class Box {
        \\  @logged field = 1;
        \\  constructor(value) { this.field = value.next() ?? 2; }
        \\}
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var ctor_scope: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag != .method_definition) continue;
        const key_idx: NodeIndex = @enumFromInt(parser.ast.extra_data.items[node.data.extra + MethodExtra.key]);
        const key = parser.ast.getNode(key_idx);
        if (key.tag != .identifier_reference or !std.mem.eql(u8, parser.ast.getText(key.data.string_ref), "constructor")) continue;
        ctor_scope = analyzer.scope_owner_map.get(@as(u32, @intCast(index)));
    }
    const source_scope = ctor_scope orelse return error.TestUnexpectedResult;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
    const edited = (try transformer.finishSemanticEdit()).?;

    var ctor_owners: usize = 0;
    var owners = edited.scope_owner_map.iterator();
    while (owners.next()) |entry| {
        if (entry.value_ptr.* != source_scope) continue;
        const owner: NodeIndex = @enumFromInt(entry.key_ptr.*);
        try std.testing.expect(transformer.ast.getNode(owner).tag == .function_declaration);
        ctor_owners += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ctor_owners);

    var ctor_temp_refs: usize = 0;
    for (edited.references) |ref| {
        if (@intFromEnum(ref.scope_id) != source_scope or ref.node_index.isNone()) continue;
        if (@intFromEnum(ref.node_index) < transformer.parser_node_count) continue;
        const node = transformer.ast.getNode(ref.node_index);
        if (node.tag != .identifier_reference) continue;
        const name = transformer.ast.getText(node.data.string_ref);
        if (!std.mem.eql(u8, name, "_a")) continue;
        try std.testing.expectEqual(source_scope, @intFromEnum(edited.symbols.items[@intFromEnum(ref.symbol_id)].scope_id));
        ctor_temp_refs += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), ctor_temp_refs);
}

test "#4819 generated class super parameter owns colliding alias references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\class Base { static get value() { return 3; } }
        \\const _super = 1;
        \\class Declared extends Base { constructor() { super(); } method() { return super.value; } static read() { return super.value; } }
        \\const Expression = class extends Base { method() { return super.value; } };
    ;
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;

    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    const reachable = try ast_walk.collectReachableNodeIndices(allocator, transformer.ast);

    var super_parameter_ids: [2]u32 = undefined;
    var super_parameter_count: usize = 0;
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .binding_identifier or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_super2")) continue;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse continue;
        if (edited.symbols.items[id].kind != .parameter) continue;
        if (super_parameter_count >= super_parameter_ids.len) return error.TestUnexpectedResult;
        super_parameter_ids[super_parameter_count] = id;
        super_parameter_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), super_parameter_count);
    try std.testing.expect(super_parameter_ids[0] != super_parameter_ids[1]);

    var aliased_references: usize = 0;
    var parameter_reads = [_]usize{ 0, 0 };
    for (reachable) |raw| {
        const node = transformer.ast.nodes.items[raw];
        if (node.tag != .identifier_reference or !std.mem.eql(u8, transformer.ast.getText(node.data.string_ref), "_super2")) continue;
        aliased_references += 1;
        if (raw >= edited.symbol_ids.len) return error.TestUnexpectedResult;
        const id = edited.symbol_ids[raw] orelse return error.TestUnexpectedResult;
        var matched = false;
        for (super_parameter_ids, 0..) |parameter_id, index| {
            if (id != parameter_id) continue;
            parameter_reads[index] += 1;
            matched = true;
        }
        try std.testing.expect(matched);
        var semantic_reference_count: usize = 0;
        for (edited.references) |reference| {
            if (reference.node_index != @as(NodeIndex, @enumFromInt(raw))) continue;
            try std.testing.expectEqual(id, @intFromEnum(reference.symbol_id));
            try std.testing.expect(reference.flags.read);
            semantic_reference_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), semantic_reference_count);
    }
    try std.testing.expect(aliased_references > 0);
    try std.testing.expect(parameter_reads[0] > 0 and parameter_reads[1] > 0);
}
