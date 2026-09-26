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
    try std.testing.expectEqual(@as(usize, 1), inner_wrapper_reads);
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
    try std.testing.expectEqual(@as(usize, 1), inner_wrapper_reads);
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

test "#4819 Stage 3 class copy nests under decorator and ES5 IIFE scopes" {
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
    const source_parent = analyzer.scopes.items[source_scope].parent;

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
    const class_iife = edited.scopes[source_scope].parent;
    const decorator_iife = edited.scopes[class_iife.toIndex()].parent;
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[class_iife.toIndex()].kind);
    try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, edited.scopes[decorator_iife.toIndex()].kind);
    try std.testing.expectEqual(source_parent, edited.scopes[decorator_iife.toIndex()].parent);
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
        if (!std.mem.startsWith(u8, name, "_")) continue;
        try std.testing.expectEqual(source_scope, @intFromEnum(edited.symbols.items[@intFromEnum(ref.symbol_id)].scope_id));
        ctor_temp_refs += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), ctor_temp_refs);
}
