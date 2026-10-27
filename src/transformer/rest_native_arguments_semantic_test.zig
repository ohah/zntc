const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const symbol_mod = @import("../semantic/symbol.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const Options = @import("options.zig").TransformOptions;
const Params = @import("es2015_params.zig").ES2015Params(Transformer);
const Owner = @import("es2015_params.zig").RestArgumentsOwner;
const walk = @import("../parser/ast_walk.zig");

fn transformer(a: std.mem.Allocator, parser: *Parser, analyzer: *Analyzer, options: Options) !Transformer {
    var t = try Transformer.init(a, &parser.ast, options.withModuleJsxPragmas(&parser.ast));
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    return t;
}

const Positive = struct { source: ?[]const u8 = null, fixture: ?[]const u8 = null, expected: []const u8 };
const jsx_expected = "{\"tag\":\"div\",\"children\":[{\"tag\":\"Fragment\",\"children\":[{\"tag\":\"span\",\"children\":[]}]}]}\n";
const positives = [_]Positive{
    .{ .source = "function f(...rest){return rest.join(',')}console.log(f(1,2));", .expected = "1,2\n" },
    .{ .source = "function f(head,...rest){return [head,rest]}console.log(JSON.stringify(f(1,2,3)));", .expected = "[1,[2,3]]\n" },
    .{ .source = "const object={f(...rest){return rest.length}};console.log(object.f(1,2));", .expected = "2\n" },
    .{ .source = "function outer(){function f(...rest){return rest[0]}return f(42)}console.log(outer());", .expected = "42\n" },
    .{ .source = "const f=function named(...rest){return rest[0]};console.log(f(42));", .expected = "42\n" },
    .{ .source = "function f(...rest){{const rest=9;}return rest[0]}console.log(f(42));", .expected = "42\n" },
    .{ .source = "function f(...[first,second]){return first+second}console.log(f(20,22));", .expected = "42\n" },
    .{ .fixture = "4760-block-destructure-shadow.mjs", .expected = "outer inner/C\n" },
    .{ .fixture = "4819-classic-jsx-member-factory.tsx", .expected = jsx_expected },
    .{ .fixture = "4819-classic-jsx-shadowed-factory.tsx", .expected = jsx_expected },
};

fn sourceOf(a: std.mem.Allocator, case: Positive) ![]const u8 {
    if (case.source) |source| return source;
    const path = try std.fmt.allocPrint(a, "tests/integration/fixtures/downlevel-oracle/{s}", .{case.fixture.?});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(1 << 20));
}

fn analyze(a: std.mem.Allocator, parser: *Parser) !Analyzer {
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_module = true;
    analyzer.is_ts = parser.source_mode == .ts;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
    return analyzer;
}

test "owned rest arguments are born at ten actual ordinary owners before output walker" {
    for (positives, 0..) |case, index| {
        errdefer std.debug.print("owned rest birth positive={d}\n", .{index});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try sourceOf(a, case);
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(if (case.fixture != null and std.mem.endsWith(u8, case.fixture.?, ".tsx")) ".tsx" else ".mjs");
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = try analyze(a, &parser);
        var t = try transformer(a, &parser, &analyzer, .{ .unsupported = Options.compat.fromESTarget(.es5), .jsx_transform = parser.ast.has_jsx, .jsx_runtime = .classic });
        try t.buildBlockRenameMap();
        const visited = try t.visitNode(root);
        try t.registerGeneratedFunctionScopes(visited, t.programScope());
        var selected: ?Owner = null;
        for (try walk.collectReachableNodeIndicesFrom(a, t.ast, visited)) |raw| {
            const node = t.ast.nodes.items[raw];
            if (node.tag != .function_declaration and node.tag != .function_expression and node.tag != .function and node.tag != .method_definition) continue;
            const params = t.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params);
            const list = t.ast.getNode(params).data.list;
            var has_rest = false;
            for (0..list.len) |offset| {
                const tag = t.ast.getNode(t.ast.readExtraNode(list.start, @intCast(offset))).tag;
                if (tag == .rest_element or tag == .spread_element) has_rest = true;
            }
            if (!has_rest) continue;
            try std.testing.expect(selected == null);
            selected = .{ .ast_owner = t.ast, .function_node = @fromBackingInt(raw), .params_node = params, .body_scope = t.outputOwnedScope(@fromBackingInt(raw)).? };
        }
        const owner = selected orelse return error.MissingOrdinaryRestOwner;
        t.current_scope = owner.body_scope;
        const list = t.ast.getNode(owner.params_node).data.list;
        try std.testing.expect(try Params.restArgumentsOwner(&t, list, owner) != null);
        var lowered = try Params.lowerParamsPass2ForFunction(&t, list, t.ast.getNode(owner.function_node).span, owner);
        defer lowered.body_stmts.deinit(a);
        try std.testing.expect(lowered.body_stmts.items.len > 0);
        try std.testing.expectEqual(@as(usize, 1), t.native_arguments_declaration_origins.count());
        const editor = &t.semantic_editor.?;
        var origins = t.native_arguments_declaration_origins.iterator();
        const origin = origins.next().?;
        const sid = origin.key_ptr.*;
        try std.testing.expectEqual(owner.body_scope, origin.value_ptr.*);
        try std.testing.expectEqual(symbol_mod.SymbolKind.parameter, editor.symbols.items[sid].kind);
        try std.testing.expectEqual(symbol_mod.SyntheticKind.implicit_arguments, editor.symbols.items[sid].synthetic_kind.?);
        try std.testing.expectEqual(owner.body_scope, editor.symbols.items[sid].scope_id);
        var reads: usize = 0;
        var declarations: usize = 0;
        for (editor.references.items) |row| {
            if (@backingInt(row.symbol_id) != sid) continue;
            try std.testing.expectEqual(owner.body_scope, row.scope_id);
            if (row.flags.declare) {
                try std.testing.expect(row.node_index.isNone() and row.declaration_node_index.isNone());
                try std.testing.expect(std.meta.eql(row.flags, @as(symbol_mod.ReferenceFlags, .{ .declare = true })));
                declarations += 1;
            } else {
                try std.testing.expect(row.flags.read and !row.flags.write);
                try std.testing.expectEqual(@as(?u32, sid), editor.symbol_ids.items[@backingInt(row.node_index)]);
                try std.testing.expect(!t.explicit_global_reference_nodes.contains(@backingInt(row.node_index)));
                reads += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), reads);
        try std.testing.expectEqual(@as(usize, 1), declarations);

        // Independently exercise the production driver too. A correct low-level
        // API is insufficient if that caller still emits a GLOBAL arguments.
        var full = try transformer(a, &parser, &analyzer, .{ .unsupported = Options.compat.fromESTarget(.es5), .jsx_transform = parser.ast.has_jsx, .jsx_runtime = .classic });
        const emitted_root = try full.transform();
        const edited = (try full.finishSemanticEdit()).?;
        try std.testing.expectEqual(@as(usize, 1), full.native_arguments_declaration_origins.count());
        const contexts = try @import("../semantic/statement_coordinates.zig").collect(a, full.ast, emitted_root);
        var generated = full.native_arguments_declaration_origins.iterator();
        const native = generated.next().?;
        const native_sid = native.key_ptr.*;
        const native_scope = native.value_ptr.*;
        try std.testing.expectEqual(native_scope, edited.symbols.items[native_sid].scope_id);
        try std.testing.expectEqual(symbol_mod.SyntheticKind.implicit_arguments, edited.symbols.items[native_sid].synthetic_kind.?);
        var actual_owner: ?u32 = null;
        for (try walk.collectReachableNodeIndicesFrom(a, full.ast, emitted_root)) |raw| {
            const node = full.ast.nodes.items[raw];
            if (node.tag != .function_declaration and node.tag != .function_expression and node.tag != .function and node.tag != .method_definition) continue;
            if (edited.scope_owner_map.get(raw) != @as(?u32, @backingInt(native_scope))) continue;
            try std.testing.expect(actual_owner == null);
            actual_owner = raw;
            try std.testing.expect(full.ast.nodeListSplitRest(full.ast.functionParamsList(node)).rest_operand == null);
        }
        const primary = actual_owner orelse return error.MissingEmittedRestFunction;
        var published_reads: usize = 0;
        var published_declarations: usize = 0;
        for (edited.references) |row| {
            if (@backingInt(row.symbol_id) != native_sid) continue;
            try std.testing.expectEqual(native_scope, row.scope_id);
            const expected = contexts[if (row.flags.declare) primary else @backingInt(row.node_index)] orelse return error.MissingNativeRestContext;
            try std.testing.expectEqual(expected.stmt_idx, row.stmt_idx);
            try std.testing.expectEqual(expected.scope_stmt_idx, row.scope_stmt_idx);
            if (row.flags.declare) {
                published_declarations += 1;
            } else {
                try std.testing.expectEqual(@as(?u32, native_sid), edited.symbol_ids[@backingInt(row.node_index)]);
                try std.testing.expect(!full.explicit_global_reference_nodes.contains(@backingInt(row.node_index)));
                published_reads += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), published_reads);
        try std.testing.expectEqual(@as(usize, 1), published_declarations);
    }
}

test "owned rest arguments ten ordinary sources preserve public runtime" {
    for (positives, 0..) |case, index| {
        errdefer std.debug.print("owned rest runtime positive={d}\n", .{index});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try sourceOf(a, case);
        const result = try @import("../transpile.zig").transpile(a, source, case.fixture orelse "input.mjs", .{ .unsupported = Options.compat.fromESTarget(.es5), .minify_identifiers = true, .minify_whitespace = true });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, case.expected, actual.stdout))
            std.debug.print("owned rest runtime code:{s}\nstdout:{s}\nstderr:{s}\n", .{ result.code, actual.stdout, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, actual.stdout);
        if (case.fixture == null or !std.mem.endsWith(u8, case.fixture.?, ".tsx")) {
            const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
            try std.testing.expect(native.term == .exited and native.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
}

const InvalidOwner = enum { foreign_ast, sibling_scope, sibling_owner, wrong_params_edge, wrong_edge_matching_list, sibling_frame_wrong_body, wrong_list, no_scope, program_scope, dangling_function, dangling_params, wrong_scope_kind, wrong_current_scope, hidden_engine };

test "owned rest arguments reject foreign sibling and malformed actual owner contexts without mutation" {
    for (std.meta.tags(InvalidOwner)) |mutation| {
        errdefer std.debug.print("owned rest invalid={s}\n", .{@tagName(mutation)});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, "function first(...rest){return rest.length}function second(...other){return other.length}");
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        var analyzer = try analyze(a, &parser);
        var t = try transformer(a, &parser, &analyzer, .{ .unsupported = Options.compat.fromESTarget(.es5) });
        var owners: std.ArrayList(Owner) = .empty;
        for (t.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration) continue;
            const fn_node: NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
            try owners.append(a, .{ .ast_owner = t.ast, .function_node = fn_node, .params_node = t.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params), .body_scope = t.outputOwnedScope(fn_node).? });
        }
        try std.testing.expectEqual(@as(usize, 2), owners.items.len);
        var owner = owners.items[0];
        var list = t.ast.getNode(owner.params_node).data.list;
        t.current_scope = owner.body_scope;
        var foreign = try transformer(a, &parser, &analyzer, .{ .unsupported = Options.compat.fromESTarget(.es5) });
        try std.testing.expect(foreign.ast != t.ast);
        try std.testing.expectEqual(foreign.ast.nodes.items.len, t.ast.nodes.items.len);
        var foreign_owner = owner;
        foreign_owner.ast_owner = foreign.ast;
        foreign.current_scope = foreign_owner.body_scope;
        try std.testing.expectEqual(owner.body_scope, foreign.outputOwnedScope(foreign_owner.function_node).?);
        try std.testing.expect((try Params.restArgumentsOwner(&foreign, list, foreign_owner)) != null);
        switch (mutation) {
            .foreign_ast => owner.ast_owner = foreign.ast,
            .sibling_scope => owner.body_scope = owners.items[1].body_scope,
            .sibling_owner => owner = owners.items[1],
            .wrong_params_edge => owner.params_node = owners.items[1].params_node,
            .wrong_edge_matching_list => {
                owner.params_node = owners.items[1].params_node;
                list = t.ast.getNode(owner.params_node).data.list;
            },
            .sibling_frame_wrong_body => {
                owner = owners.items[1];
                owner.body_scope = owners.items[0].body_scope;
                list = t.ast.getNode(owner.params_node).data.list;
            },
            .wrong_list => list = t.ast.getNode(owners.items[1].params_node).data.list,
            .no_scope => owner.body_scope = .none,
            .program_scope => owner.body_scope = t.programScope(),
            .dangling_function => owner.function_node = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len))),
            .dangling_params => owner.params_node = @fromBackingInt(@as(u32, @intCast(t.ast.nodes.items.len))),
            .wrong_scope_kind => analyzer.scopes.items[owner.body_scope.toIndex()].kind = .block,
            .wrong_current_scope => t.current_scope = owners.items[1].body_scope,
            .hidden_engine => {
                const symbols = try a.alloc(symbol_mod.Symbol, t.symbols.len + 1);
                @memcpy(symbols[0..t.symbols.len], t.symbols);
                symbols[t.symbols.len] = .{ .name = .EMPTY, .declaration_span = .EMPTY, .kind = .parameter, .scope_id = owner.body_scope, .synthetic_kind = .implicit_arguments, .synthetic_name = "arguments" };
                t.symbols = symbols;
            },
        }
        const symbols_before = try a.dupe(symbol_mod.Symbol, t.symbols);
        const references_before = try a.dupe(symbol_mod.Reference, t.references);
        const ids_before = try a.dupe(?u32, t.symbol_ids.items);
        const scopes_before = try a.dupe(@import("../semantic/scope.zig").Scope, t.scopes);
        const owner_count = t.scope_owner_map.count();
        try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.restArgumentsOwner(&t, list, owner));
        try std.testing.expectEqualDeep(symbols_before, t.symbols);
        try std.testing.expectEqualDeep(references_before, t.references);
        try std.testing.expectEqualSlices(?u32, ids_before, t.symbol_ids.items);
        try std.testing.expectEqualDeep(scopes_before, t.scopes);
        try std.testing.expectEqual(owner_count, t.scope_owner_map.count());
        try std.testing.expectEqual(@as(usize, 0), t.native_arguments_declaration_origins.count());
    }
}

test "owned rest arguments retain source collisions split parameters and native arrow boundaries" {
    const sources = [_][]const u8{
        "function f(arguments,...rest){return rest}",
        "function f(...rest){var arguments;return rest}",
        "function f(...rest){var arguments=99;return rest}",
        "function f(...rest){let arguments=99;return rest}",
        "function f(value=1,...rest){return [value,rest]}",
        "const f=({x,...obj},...rest)=>[x,obj,rest];",
        "async function f(...rest){return rest}",
        "function* f(...rest){yield rest}",
    };
    for (sources, 0..) |source, index| {
        errdefer std.debug.print("owned rest boundary={d}\n", .{index});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, source);
        var parser = Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = Analyzer.init(a, &parser.ast);
        analyzer.enable_stmt_info = true;
        analyzer.enable_exact_declaration_anchors = true;
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var t = try transformer(a, &parser, &analyzer, .{ .unsupported = Options.compat.fromESTarget(if (index == 5) .es2017 else .es5) });
        var selected: ?Owner = null;
        for (t.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .function_declaration and node.tag != .arrow_function_expression) continue;
            const fn_node: NodeIndex = @fromBackingInt(@as(u32, @intCast(raw)));
            selected = .{ .ast_owner = t.ast, .function_node = fn_node, .params_node = t.ast.readExtraNode(node.data.extra, if (node.tag == .arrow_function_expression) ast_mod.ArrowExtra.params else ast_mod.FunctionExtra.params), .body_scope = t.outputOwnedScope(fn_node).? };
        }
        const owner = selected orelse return error.MissingBoundaryOwner;
        t.current_scope = owner.body_scope;
        const symbols_before = try a.dupe(symbol_mod.Symbol, t.symbols);
        const references_before = try a.dupe(symbol_mod.Reference, t.references);
        const ids_before = try a.dupe(?u32, t.symbol_ids.items);
        const scopes_before = try a.dupe(@import("../semantic/scope.zig").Scope, t.scopes);
        const list = t.ast.getNode(owner.params_node).data.list;
        try std.testing.expect((try Params.restArgumentsOwner(&t, list, owner)) == null);
        try std.testing.expectEqualDeep(symbols_before, t.symbols);
        try std.testing.expectEqualDeep(references_before, t.references);
        try std.testing.expectEqualSlices(?u32, ids_before, t.symbol_ids.items);
        try std.testing.expectEqualDeep(scopes_before, t.scopes);
        try std.testing.expectEqual(@as(usize, 0), t.native_arguments_declaration_origins.count());
        if (index == 5) {
            var lowered = try Params.lowerParamsPass2(&t, list, t.ast.getNode(owner.function_node).span);
            defer lowered.body_stmts.deinit(a);
            try std.testing.expect(t.ast.nodeListSplitRest(lowered.new_params).rest_operand != null);
            try std.testing.expectEqual(@as(usize, 0), t.native_arguments_declaration_origins.count());
        }
    }
}

test "owned rest arguments graphless wrapper keeps the legacy parameter API boundary" {
    for ([_]bool{ false, true }) |owned_api| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try Scanner.init(a, "function f(...rest){return rest}");
        var parser = Parser.init(a, &scanner);
        _ = try parser.parse();
        var t = try Transformer.init(a, &parser.ast, .{ .unsupported = Options.compat.fromESTarget(.es5) });
        try std.testing.expect(!t.semantic_edit_enabled and t.current_scope.isNone());
        var function: ?NodeIndex = null;
        for (t.ast.nodes.items, 0..) |node, raw| {
            if (node.tag == .function_declaration) function = @fromBackingInt(@as(u32, @intCast(raw)));
        }
        const node = t.ast.getNode(function.?);
        const params = t.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params);
        var lowered = if (owned_api)
            try Params.lowerParamsPass2ForFunction(&t, t.ast.getNode(params).data.list, node.span, .{ .ast_owner = t.ast, .function_node = function.?, .params_node = params, .body_scope = .none })
        else
            try Params.lowerParamsPass2(&t, t.ast.getNode(params).data.list, node.span);
        defer lowered.body_stmts.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), lowered.body_stmts.items.len);
        try std.testing.expectEqual(@as(usize, 0), t.native_arguments_declaration_origins.count());
        try std.testing.expect(t.semantic_editor == null);
    }
}

const UnlinkedFixture = struct {
    t: *Transformer,
    root: NodeIndex,
    owner: Owner,
};

fn unlinkedFixture(a: std.mem.Allocator, source: []const u8) !UnlinkedFixture {
    const scanner = try a.create(Scanner);
    scanner.* = try Scanner.init(a, source);
    const parser = try a.create(Parser);
    parser.* = Parser.init(a, scanner);
    parser.configureFromExtension(".unknown");
    const source_root = try parser.parse();
    const analyzer = try a.create(Analyzer);
    analyzer.* = Analyzer.init(a, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const t = try a.create(Transformer);
    t.* = try transformer(a, parser, analyzer, .{ .unsupported = Options.compat.fromESTarget(.es5) });
    try t.buildBlockRenameMap();
    const root = try t.visitNode(source_root);
    try t.registerGeneratedFunctionScopes(root, t.programScope());
    const reachable = try walk.collectReachableNodeIndicesFrom(a, t.ast, root);
    for (reachable) |raw| {
        const node = t.ast.nodes.items[raw];
        if (node.tag != .function_declaration) continue;
        const index: NodeIndex = @fromBackingInt(raw);
        const owner: Owner = .{ .ast_owner = t.ast, .function_node = index, .params_node = t.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params), .body_scope = t.outputOwnedScope(index).? };
        t.current_scope = owner.body_scope;
        return .{ .t = t, .root = root, .owner = owner };
    }
    return error.MissingUnlinkedFunctionOwner;
}

const unlinked_source = "async function* f(value,opts={}){yield value+(opts.k||0)}";

test "unlinked arguments default reads keep the existing engine before output walker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, unlinked_source);
    var parser = Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    var source_scope: ScopeId = .none;
    var body_scope: ScopeId = .none;
    for (parser.ast.nodes.items, 0..) |node, raw| {
        if (node.tag != .function_declaration) continue;
        body_scope = @fromBackingInt(analyzer.scope_owner_map.get(@intCast(raw)).?);
        source_scope = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(parser.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params))).?);
    }
    var engine: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, id| {
        if (symbol.synthetic_kind != .implicit_arguments or symbol.scope_id != source_scope) continue;
        try std.testing.expect(engine == null);
        engine = @intCast(id);
    }
    const id = engine orelse return error.MissingSourceNativeEngine;
    var t = try transformer(a, &parser, &analyzer, .{ .unsupported = Options.compat.fromESTarget(.es5) });
    t.record_explicit_global_references = true;
    const output = try t.transform();
    _ = root;
    // Actual transform Pass 2 and program publication ran; finish/output
    // validation has not. No new engine or identity healing is permitted.
    const editor = &t.semantic_editor.?;
    try std.testing.expectEqual(body_scope, editor.symbols.items[id].scope_id);
    try std.testing.expectEqual(@as(?ScopeId, body_scope), t.native_arguments_declaration_origins.get(id));
    try std.testing.expect(!t.native_arguments_parameter_handoffs.contains(id));
    var engines: usize = 0;
    for (editor.symbols.items) |symbol| {
        if (symbol.synthetic_kind == .implicit_arguments and (symbol.scope_id == source_scope or symbol.scope_id == body_scope)) engines += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), engines);
    const coordinates = try @import("../semantic/statement_coordinates.zig").collect(a, t.ast, output);
    var declarations: usize = 0;
    var reads: usize = 0;
    for (editor.references.items) |row| {
        if (@backingInt(row.symbol_id) != id) continue;
        try std.testing.expectEqual(body_scope, row.scope_id);
        if (row.flags.declare) {
            declarations += 1;
            continue;
        }
        try std.testing.expectEqualDeep(@as(symbol_mod.ReferenceFlags, .{ .read = true }), row.flags);
        try std.testing.expectEqual(@as(?u32, id), t.getSymbolIdAt(row.node_index));
        const origin = t.native_arguments_reference_origins.get(@backingInt(row.node_index)).?;
        try std.testing.expectEqual(body_scope, origin.owner_scope);
        try std.testing.expectEqual(body_scope, origin.scope);
        const actual = coordinates[@backingInt(row.node_index)].?;
        try std.testing.expectEqual(actual.stmt_idx, row.stmt_idx);
        try std.testing.expectEqual(actual.scope_stmt_idx, row.scope_stmt_idx);
        _ = (try @import("native_arguments.zig").publication(&t, @backingInt(row.node_index))).?;
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), declarations);
    try std.testing.expectEqual(@as(usize, 3), reads);
    const report = try @import("symbol_coverage.zig").checkExact(a, t.ast, output, t.parser_node_count, editor.symbol_ids.items, editor.symbols.items, editor.scopes.items, editor.scope_maps.items, &editor.scope_owner_map, editor.references.items, t.helper_ref_nodes.items, &t.helper_scope_map, &analyzer.unresolved_reference_nodes, &t.explicit_global_reference_nodes, &t.reference_origin_map);
    try std.testing.expectEqual(@as(usize, 0), report.shadowed_external_reference);
    try std.testing.expectEqual(@as(usize, 0), report.missing_reference);
    try std.testing.expectEqual(@as(usize, 0), report.identity_mismatch);
    try std.testing.expectEqual(@as(usize, 0), report.reference_scope_mismatch);
    std.debug.print("UNLINKED ARGUMENTS BIRTH engine={d} reads=3 declaration=1 before-finish=1 shadowed=0\n", .{id});
}

test "unlinked arguments reject foreign handoffs engines and AST owners without mutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try unlinkedFixture(a, unlinked_source ++ "async function* other(value,opts={}){yield value}");
    const list = f.t.ast.getNode(f.owner.params_node).data.list;
    const id = (try Params.unlinkedArgumentsOwner(f.t, list, f.owner)).?;
    const raw = @backingInt(id);
    const plan = f.t.native_arguments_parameter_handoffs.get(raw).?;
    var foreign_id: ?u32 = null;
    var plans = f.t.native_arguments_parameter_handoffs.iterator();
    while (plans.next()) |entry| if (entry.key_ptr.* != raw) {
        foreign_id = entry.key_ptr.*;
    };
    const other_id = foreign_id orelse return error.MissingForeignNativeEngine;
    const other_plan = f.t.native_arguments_parameter_handoffs.get(other_id).?;
    const symbols_before = try a.dupe(symbol_mod.Symbol, f.t.semantic_editor.?.symbols.items);
    const references_before = try a.dupe(symbol_mod.Reference, f.t.semantic_editor.?.references.items);
    var corrupted = plan;
    corrupted.body_scope = other_plan.body_scope;
    f.t.native_arguments_parameter_handoffs.getPtr(raw).?.* = corrupted;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, f.owner));
    f.t.native_arguments_parameter_handoffs.getPtr(raw).?.* = plan;
    corrupted.source_scope = other_plan.source_scope;
    f.t.native_arguments_parameter_handoffs.getPtr(raw).?.* = corrupted;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, f.owner));
    f.t.native_arguments_parameter_handoffs.getPtr(raw).?.* = plan;
    _ = f.t.native_arguments_parameter_handoffs.remove(raw);
    f.t.native_arguments_parameter_handoffs.getPtr(other_id).?.* = plan;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, f.owner));
    f.t.native_arguments_parameter_handoffs.getPtr(other_id).?.* = other_plan;
    try f.t.native_arguments_parameter_handoffs.put(a, raw, plan);
    const same_numbers = try unlinkedFixture(a, unlinked_source ++ "async function* other(value,opts={}){yield value}");
    try std.testing.expectEqual(f.owner.body_scope, same_numbers.owner.body_scope);
    try std.testing.expectEqual(f.owner.params_node, same_numbers.owner.params_node);
    var wrong_ast = f.owner;
    wrong_ast.ast_owner = same_numbers.t.ast;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, wrong_ast));
    var foreign_function: NodeIndex = .none;
    const live = try walk.collectReachableNodeIndicesFrom(a, f.t.ast, f.root);
    for (live) |node| {
        const index: NodeIndex = @fromBackingInt(node);
        if (f.t.ast.getNode(index).tag == .function_declaration and f.t.outputOwnedScope(index) == other_plan.body_scope) foreign_function = index;
    }
    try std.testing.expect(!foreign_function.isNone());
    var wrong_function = f.owner;
    wrong_function.function_node = foreign_function;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, wrong_function));
    var wrong_params = f.owner;
    wrong_params.params_node = other_plan.params;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, wrong_params));
    var wrong_body = f.owner;
    wrong_body.body_scope = other_plan.body_scope;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, wrong_body));
    const foreign_list = f.t.ast.getNode(other_plan.params).data.list;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, foreign_list, f.owner));
    f.t.semantic_editor.?.symbols.items[raw].kind = .variable_var;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, f.owner));
    f.t.semantic_editor.?.symbols.items[raw] = symbols_before[raw];
    var origin_node: ?u32 = null;
    var origins = f.t.native_arguments_reference_origins.iterator();
    while (origins.next()) |entry| if (entry.value_ptr.symbol_id == id) {
        origin_node = entry.key_ptr.*;
    };
    const original_origin = f.t.native_arguments_reference_origins.get(origin_node.?).?;
    f.t.native_arguments_reference_origins.getPtr(origin_node.?).?.flags.write = true;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, list, f.owner));
    f.t.native_arguments_reference_origins.getPtr(origin_node.?).?.* = original_origin;
    // Make the first existing plan's actual owner the query target. A reader
    // must still reject a second claim, rather than returning the first row.
    var ordered = f.t.native_arguments_parameter_handoffs.iterator();
    const first = ordered.next().?;
    const first_id = first.key_ptr.*;
    const first_plan = first.value_ptr.*;
    const second_id = if (first_id == raw) other_id else raw;
    const second_plan = f.t.native_arguments_parameter_handoffs.get(second_id).?;
    var first_function: NodeIndex = .none;
    for (live) |node| {
        const index: NodeIndex = @fromBackingInt(node);
        if (f.t.ast.getNode(index).tag == .function_declaration and f.t.outputOwnedScope(index) == first_plan.body_scope) first_function = index;
    }
    try std.testing.expect(!first_function.isNone());
    const first_owner: Owner = .{ .ast_owner = f.t.ast, .function_node = first_function, .params_node = first_plan.params, .body_scope = first_plan.body_scope };
    f.t.current_scope = first_plan.body_scope;
    f.t.native_arguments_parameter_handoffs.getPtr(second_id).?.* = first_plan;
    try std.testing.expectError(error.InvalidRestArgumentsOwner, Params.unlinkedArgumentsOwner(f.t, f.t.ast.getNode(first_plan.params).data.list, first_owner));
    f.t.native_arguments_parameter_handoffs.getPtr(second_id).?.* = second_plan;
    f.t.current_scope = f.owner.body_scope;
    try std.testing.expectEqualDeep(symbols_before, f.t.semantic_editor.?.symbols.items);
    try std.testing.expectEqualDeep(references_before, f.t.semantic_editor.?.references.items);
    try std.testing.expectEqual(id, (try Params.unlinkedArgumentsOwner(f.t, list, f.owner)).?);
    for ([_][]const u8{
        "async function* f(value=1){yield arguments[0]}",
        "async function* f(arguments,value=1){yield value}",
        "async function* f(value=1){let arguments=42;yield arguments}",
    }, 0..) |source, boundary_index| {
        errdefer std.debug.print("UNLINKED boundary={d} source={s}\n", .{ boundary_index, source });
        const boundary = try unlinkedFixture(a, source);
        const before_symbols = try a.dupe(symbol_mod.Symbol, boundary.t.semantic_editor.?.symbols.items);
        const before_refs = try a.dupe(symbol_mod.Reference, boundary.t.semantic_editor.?.references.items);
        const selected = try Params.unlinkedArgumentsOwner(boundary.t, boundary.t.ast.getNode(boundary.owner.params_node).data.list, boundary.owner);
        if (boundary_index == 2) {
            // The source lexical binding moved into the generator body. The
            // ordinary outer wrapper still owns a distinct parameter engine.
            const selected_id = selected orelse return error.MissingValidWrapperEngine;
            const engine_symbol = boundary.t.semantic_editor.?.symbols.items[@backingInt(selected_id)];
            try std.testing.expectEqual(@as(?symbol_mod.SyntheticKind, .implicit_arguments), engine_symbol.synthetic_kind);
            var lexical: usize = 0;
            for (boundary.t.ast.nodes.items, 0..) |node, raw_node| {
                if (node.tag != .binding_identifier or !std.mem.eql(u8, boundary.t.ast.getText(node.data.string_ref), "arguments")) continue;
                const source_id = boundary.t.getSymbolIdAt(@fromBackingInt(@as(u32, @intCast(raw_node)))) orelse continue;
                const source_symbol = boundary.t.semantic_editor.?.symbols.items[source_id];
                if (source_symbol.kind != .variable_let) continue;
                try std.testing.expect(source_id != @backingInt(selected_id));
                try std.testing.expect(source_symbol.scope_id != engine_symbol.scope_id);
                lexical += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), lexical);
        } else try std.testing.expect(selected == null);
        try std.testing.expectEqualDeep(before_symbols, boundary.t.semantic_editor.?.symbols.items);
        try std.testing.expectEqualDeep(before_refs, boundary.t.semantic_editor.?.references.items);
    }
    std.debug.print("UNLINKED ARGUMENTS HOSTILE hostile=11 source-boundaries=3 restored=1\n", .{});
}

test "unlinked arguments default runtime matches native in sloppy and strict environments" {
    const sources = [_][]const u8{
        "async function* f(value,opts={}){yield value+(opts.k||0)};(async()=>console.log((await f(1,{k:2}).next()).value,(await f(5).next()).value))();",
        "async function* f(value=7){yield value};(async()=>console.log((await f().next()).value,(await f(undefined).next()).value))();",
        "async function* f(value,opts={k:2}){yield value+opts.k};(async()=>console.log((await f(40,undefined).next()).value))();",
        "let count=0;async function* f(value=(++count)){yield value};const first=f();const second=f(9);(async()=>console.log(count,(await first.next()).value,(await second.next()).value))();",
        "const outside=40;async function* f(value=outside+2){yield value};(async()=>console.log((await f().next()).value))();",
        "async function* f(value=1,other=value+1){yield value+other};(async()=>console.log((await f().next()).value,(await f(20,22).next()).value))();",
        "'use strict';async function* f(value=42){yield value};(async()=>console.log((await f().next()).value))();",
        "const object={value:42,async *f(value=this.value){yield value}};(async()=>console.log((await object.f().next()).value))();",
        "const f=async function* named(value=42){yield value};(async()=>console.log((await f().next()).value))();",
        "async function* f(value=1){let arguments=42;yield value+arguments};(async()=>console.log((await f().next()).value))();",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (sources, 0..) |source, case| {
        errdefer std.debug.print("UNLINKED RUNTIME case={d}\n", .{case});
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        for ([_]bool{ false, true }) |minify| {
            const output = try @import("../transpile.zig").transpile(a, source, "input.unknown", .{ .unsupported = Options.compat.fromESTarget(.es5), .minify_identifiers = minify });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", output.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("UNLINKED RUNTIME minify={} expected={s} actual={s} stderr={s} code={s}\n", .{ minify, native.stdout, actual.stdout, actual.stderr, output.code });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        }
    }
    std.debug.print("UNLINKED ARGUMENTS RUNTIME sources=10 modes=2 native=20\n", .{});
}

test "unlinked arguments creator registers reads before parameter fragment movement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try unlinkedFixture(a, unlinked_source);
    const params = f.t.ast.getNode(f.owner.params_node).data.list;
    const id = (try Params.unlinkedArgumentsOwner(f.t, params, f.owner)).?;
    const plan = f.t.native_arguments_parameter_handoffs.get(@backingInt(id)).?;
    const second = f.t.ast.getNode(f.t.ast.readExtraNode(params.start, 1));
    const binding = switch (second.tag) {
        .assignment_pattern => second.data.binary.left,
        .formal_parameter => f.t.ast.readExtraNode(second.data.extra, ast_mod.FormalParameterExtra.pattern),
        else => return error.MissingActualDefaultBinding,
    };
    const binding_id = f.t.getSymbolIdAt(binding).?;
    const before = f.t.semantic_editor.?.references.items.len;
    const engines_before = f.t.native_arguments_declaration_origins.count();
    var unlinked: std.ArrayList(NodeIndex) = .empty;
    f.t.unlinked_parameter_bindings = &unlinked;
    const lowered = try Params.lowerParamsPass2ForFunction(f.t, params, f.t.ast.getNode(f.owner.function_node).span, f.owner);
    f.t.unlinked_parameter_bindings = null;
    // These are the actual returned declaration fragments, before the driver
    // moves source-parameter references or replaces the function body.
    var parents: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var statements: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    for (lowered.body_stmts.items, 0..) |statement, index| {
        const live = try walk.collectReachableNodeIndicesFrom(a, f.t.ast, statement);
        for (live) |raw| {
            try statements.put(a, raw, index);
            var children = walk.children(f.t.ast, f.t.ast.nodes.items[raw]);
            while (children.next()) |child| {
                const slot = try parents.getOrPut(a, @backingInt(child));
                try std.testing.expect(!slot.found_existing);
                slot.value_ptr.* = raw;
            }
        }
    }
    var reads: usize = 0;
    for (f.t.semantic_editor.?.references.items[before..]) |row| {
        if (row.symbol_id != id or row.flags.declare) continue;
        try std.testing.expectEqual(f.owner.body_scope, row.scope_id);
        try std.testing.expectEqualDeep(@as(symbol_mod.ReferenceFlags, .{ .read = true }), row.flags);
        try std.testing.expectEqual(@as(?u32, @backingInt(id)), f.t.getSymbolIdAt(row.node_index));
        try std.testing.expectEqual(symbol_mod.Reference.NO_STMT, row.stmt_idx);
        try std.testing.expectEqual(symbol_mod.Reference.NO_STMT, row.scope_stmt_idx);
        const origin = f.t.native_arguments_reference_origins.get(@backingInt(row.node_index)).?;
        try std.testing.expectEqual(plan.source_scope, origin.owner_scope);
        try std.testing.expectEqual(f.owner.body_scope, origin.scope);
        var cursor = @backingInt(row.node_index);
        const member = parents.get(cursor).?;
        try std.testing.expectEqual(ast_mod.Node.Tag.computed_member_expression, f.t.ast.nodes.items[member].tag);
        while (parents.get(cursor)) |parent| {
            cursor = parent;
            if (f.t.ast.nodes.items[cursor].tag == .variable_declarator) break;
        }
        const declarator = f.t.ast.nodes.items[cursor];
        try std.testing.expectEqual(ast_mod.Node.Tag.variable_declarator, declarator.tag);
        try std.testing.expectEqual(@as(?u32, binding_id), f.t.getSymbolIdAt(f.t.ast.readExtraNode(declarator.data.extra, 0)));
        try std.testing.expectEqual(ast_mod.Node.Tag.variable_declaration, f.t.ast.nodes.items[parents.get(cursor).?].tag);
        try std.testing.expectEqual(@as(?usize, 1), statements.get(@backingInt(row.node_index)));
        _ = (try @import("native_arguments.zig").publication(f.t, @backingInt(row.node_index))).?;
        reads += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), reads);
    try std.testing.expectEqual(engines_before, f.t.native_arguments_declaration_origins.count());
    std.debug.print("UNLINKED ARGUMENTS CREATOR reads=2 actual-declarator=1 pre-fragment-move=1\n", .{});
}
