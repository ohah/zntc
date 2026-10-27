//! Worklet 변환 테스트 (transformer_test.zig에서 분리).
//! Babel react-native-worklets plugin 호환성 검증을 집중적으로 다룬다.
//!
//! 참고:
//! - worklet_babel_parity_test.zig — Babel 테스트 포팅(parity)
//! - plugins/worklet_plugin.zig — 실제 플러그인 구현

const std = @import("std");
const tt = @import("transformer_test.zig");
const transformer_mod = @import("transformer.zig");
const TransformOptions = transformer_mod.TransformOptions;
const Plugin = @import("../bundler/plugin.zig").Plugin;
const worklet_plugin_mod = @import("plugins/worklet_plugin.zig");
const compat = @import("compat.zig");

const transformWorklet = tt.transformWorklet;
const generateCode = tt.generateCode;
const parseAndTransformWithOptions = tt.parseAndTransformWithOptions;

test "Worklet: generated factory locals keep exact semantic coverage" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const coverage = @import("symbol_coverage.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const current = 17;
        \\const run = () => 2;
        \\function declared() { "worklet"; return 1; }
        \\function make() { return function nested() { "worklet"; return 42; }; }
        \\const anonymous = function() { "worklet"; return 3; };
        \\const arrow = () => { "worklet"; return 4; };
        \\const handlers = {
        \\  run(value) { "worklet"; return run() + value; },
        \\  get current() { "worklet"; return 7; },
        \\  set current(current) { "worklet"; this.currentValue = current; }
        \\};
        \\class Box {
        \\  set value(value) { "worklet"; this.stored = value; }
        \\  set current(input) { "worklet"; this.storedCurrent = current + input; }
        \\}
    ;

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var transformer = try transformer_mod.Transformer.init(allocator, &parser.ast, .{
        .plugins = &plugins,
        .jsx_filename = "test.ts",
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    var codegen = @import("../codegen/codegen.zig").Codegen.init(allocator, transformer.ast);
    defer codegen.deinit();
    const output = try codegen.generate(root);
    try std.testing.expect(std.mem.indexOf(u8, output, "var __zntcWorkletFactoryLocal4 = function(value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__zntcWorkletFactoryLocal4.__closure = { run: run }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__zntcWorkletFactoryLocal8.__closure = { current: current }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__zntcWorkletFactoryLocal4.__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "current.__workletHash") == null);
    const edited = (try transformer.finishSemanticEdit()).?;
    const expected_factory_hints = [_]struct { name: []const u8, count: usize }{
        .{ .name = "nested", .count = 1 },
        .{ .name = "testts_null0", .count = 1 },
        .{ .name = "testts_null1", .count = 1 },
        .{ .name = "run", .count = 1 },
        .{ .name = "current", .count = 3 },
        .{ .name = "value", .count = 1 },
    };
    var factory_local_count: usize = 0;
    for (edited.symbols.items, 0..) |symbol, raw_symbol_id| {
        if (symbol.synthetic_kind != .worklet_factory_local) continue;
        factory_local_count += 1;
        try std.testing.expect(symbol.output_name_hint.len > 0);
        try std.testing.expect(!std.mem.eql(u8, symbol.synthetic_name, symbol.output_name_hint));
        try std.testing.expect(!symbol.scope_id.isNone());
        const output_scope = edited.scopes[symbol.scope_id.toIndex()];
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.function, output_scope.kind);
        const symbol_id: @import("../semantic/symbol.zig").SymbolId = @fromBackingInt(@intCast(raw_symbol_id));
        var reference_count: usize = 0;
        for (edited.references) |reference| {
            if (reference.symbol_id != symbol_id) continue;
            try std.testing.expectEqual(symbol.scope_id, reference.scope_id);
            reference_count += 1;
        }
        try std.testing.expect(reference_count > 0);
    }
    try std.testing.expectEqual(@as(usize, 8), factory_local_count);
    for (expected_factory_hints) |expected| {
        var found: usize = 0;
        for (edited.symbols.items) |symbol| {
            if (symbol.synthetic_kind == .worklet_factory_local and
                std.mem.eql(u8, symbol.output_name_hint, expected.name)) found += 1;
        }
        try std.testing.expectEqual(expected.count, found);
    }
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
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("worklet-factory-locals.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());
}

test "Worklet class factory output hints avoid direct-eval names with semantic edits" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\const handlers = {
        \\  call() { "worklet"; return eval("call"); },
        \\  get read() { "worklet"; return eval("read"); }
        \\};
        \\class Clazz {
        \\  __workletClass = true;
        \\  read() { return eval("Clazz__classFactory"); }
        \\}
    ;

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var transformer = try transformer_mod.Transformer.init(allocator, &parser.ast, .{
        .plugins = &plugins,
        .jsx_filename = "test.ts",
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    var found_call = false;
    var found_read = false;
    var found_class_factory = false;
    for (edited.symbols.items) |symbol| {
        if (symbol.synthetic_kind != .worklet_factory_local) continue;
        if (std.mem.eql(u8, symbol.output_name_hint, "call2")) found_call = true;
        if (std.mem.eql(u8, symbol.output_name_hint, "read2")) found_read = true;
        if (std.mem.eql(u8, symbol.output_name_hint, "Clazz__classFactory2")) found_class_factory = true;
    }
    try std.testing.expect(found_call);
    try std.testing.expect(found_read);
    try std.testing.expect(found_class_factory);
}

test "Worklet semantic-less class factory avoids a captured source binding" {
    const sources = [_][]const u8{
        \\const Clazz_\u005fclassFactory = 73;
        \\class Clazz {
        \\  __workletClass = true;
        \\  static capturedFactoryName() { return Clazz_\u005fclassFactory; }
        \\}
        ,
        \\const Clazz_\u{5f}classFactory = 73;
        \\class Clazz {
        \\  __workletClass = true;
        \\  static capturedFactoryName() { return Clazz_\u{5f}classFactory; }
        \\}
    };
    const closure_keys = [_][]const u8{
        "__closure = { Clazz_\\u005fclassFactory:",
        "__closure = { Clazz_\\u{5f}classFactory:",
    };
    for (sources, closure_keys) |source, closure_key| {
        var result = try transformWorklet(std.testing.allocator, source);
        defer result.deinit();
        const code = try generateCode(&result);
        defer std.testing.allocator.free(code);
        try std.testing.expect(std.mem.indexOf(u8, code, "function Clazz__classFactory2()") != null);
        try std.testing.expect(std.mem.indexOf(u8, code, closure_key) != null);
    }
}

test "#4819 Worklet method factory does not capture an escaped same-name local" {
    const source =
        \\const read = 73;
        \\const handlers = {
        \\  r\u0065ad() { "worklet"; return read; }
        \\};
        \\console.log(handlers.read());
    ;

    var result = try transformWorklet(std.testing.allocator, source);
    defer result.deinit();
    const code = try generateCode(&result);
    defer std.testing.allocator.free(code);

    const actual = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "-e", code },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(actual.stdout);
    defer std.testing.allocator.free(actual.stderr);
    switch (actual.term) {
        .exited => |code_status| if (code_status != 0) {
            std.debug.print("node stderr:\n{s}\n", .{actual.stderr});
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("node stderr:\n{s}\n", .{actual.stderr});
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqualStrings("73\n", actual.stdout);
}

test "#4819 Worklet factory local avoids a direct-eval method name" {
    const source =
        \\globalThis.call = "global method";
        \\globalThis["call" + "2"] = "global candidate";
        \\globalThis.read = "global getter";
        \\globalThis["commit" + "2"] = "global unique candidate";
        \\const commit = "outer closure";
        \\const handlers = {
        \\  call() { "worklet"; return eval("ca" + "ll") + ":" + eval("call" + "2"); },
        \\  get read() { "worklet"; return ev\u0061l("read"); },
        \\  commit() { "worklet"; return commit + ":" + eval("commit" + "2"); }
        \\};
        \\console.log(handlers.call());
        \\console.log(handlers.read());
        \\console.log(handlers.commit());
    ;

    var result = try transformWorklet(std.testing.allocator, source);
    defer result.deinit();
    const code = try generateCode(&result);
    defer std.testing.allocator.free(code);

    const actual = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "-e", code },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(actual.stdout);
    defer std.testing.allocator.free(actual.stderr);
    switch (actual.term) {
        .exited => |code_status| if (code_status != 0) {
            std.debug.print("node stderr:\n{s}\n", .{actual.stderr});
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("node stderr:\n{s}\n", .{actual.stderr});
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqualStrings(
        "global method:global candidate\nglobal getter\nouter closure:global unique candidate\n",
        actual.stdout,
    );
}

test "#4819 Worklet class factory local avoids ten direct-eval names without semantic edits" {
    const source =
        \\globalThis['C0__' + 'classFactory'] = "global:0";
        \\class C0 { __workletClass = true; read() { return eval('C0__classFactory'); } }
        \\console.log(new (C0['C0__' + 'classFactory']())().read());
        \\globalThis['C1__' + 'classFactory'] = "global:1";
        \\class C1 { __workletClass = true; read() { return eval("C1__classFactory"); } }
        \\console.log(new (C1['C1__' + 'classFactory']())().read());
        \\globalThis['C2__' + 'classFactory'] = "global:2";
        \\class C2 { __workletClass = true; read() { return eval('C2__' + 'classFactory'); } }
        \\console.log(new (C2['C2__' + 'classFactory']())().read());
        \\globalThis['C3__' + 'classFactory'] = "global:3";
        \\class C3 { __workletClass = true; read() { return eval(`C3__classFactory`); } }
        \\console.log(new (C3['C3__' + 'classFactory']())().read());
        \\globalThis['C4__' + 'classFactory'] = "global:4";
        \\class C4 { __workletClass = true; read() { return eval(('C4__classFactory')); } }
        \\console.log(new (C4['C4__' + 'classFactory']())().read());
        \\globalThis['C5__' + 'classFactory'] = "global:5";
        \\class C5 { __workletClass = true; read() { return eval('C5__classFact\\u006fry'); } }
        \\console.log(new (C5['C5__' + 'classFactory']())().read());
        \\globalThis['C6__' + 'classFactory'] = "global:6";
        \\class C6 { __workletClass = true; read() { return eval('C6__' + `classFactory`); } }
        \\console.log(new (C6['C6__' + 'classFactory']())().read());
        \\globalThis['C7__' + 'classFactory'] = "global:7";
        \\class C7 { __workletClass = true; read() { return eval(`C7__` + `classFactory`); } }
        \\console.log(new (C7['C7__' + 'classFactory']())().read());
        \\globalThis['C8__' + 'classFactory'] = "global:8";
        \\class C8 { __workletClass = true; read() { return eval((`C8__classFactory`)); } }
        \\console.log(new (C8['C8__' + 'classFactory']())().read());
        \\globalThis['C9__' + 'classFactory'] = "global:9";
        \\class C9 { __workletClass = true; read() { return eval('C9' + '__classFactory'); } }
        \\console.log(new (C9['C9__' + 'classFactory']())().read());
    ;

    var result = try transformWorklet(std.testing.allocator, source);
    defer result.deinit();
    const code = try generateCode(&result);
    defer std.testing.allocator.free(code);
    for (0..10) |index| {
        const expected_name = try std.fmt.allocPrint(
            std.testing.allocator,
            "function C{d}__classFactory2()",
            .{index},
        );
        defer std.testing.allocator.free(expected_name);
        try std.testing.expect(std.mem.indexOf(u8, code, expected_name) != null);
    }

    const actual = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "-e", code },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(actual.stdout);
    defer std.testing.allocator.free(actual.stderr);
    switch (actual.term) {
        .exited => |code_status| if (code_status != 0) {
            std.debug.print("node stderr:\n{s}\n", .{actual.stderr});
            return error.TestUnexpectedResult;
        },
        else => {
            std.debug.print("node stderr:\n{s}\n", .{actual.stderr});
            return error.TestUnexpectedResult;
        },
    }
    try std.testing.expectEqualStrings(
        "global:0\nglobal:1\nglobal:2\nglobal:3\nglobal:4\nglobal:5\nglobal:6\nglobal:7\nglobal:8\nglobal:9\n",
        actual.stdout,
    );
}

test "Worklet class factory accepts long class identifier names" {
    const allocator = std.testing.allocator;
    const class_name = try allocator.alloc(u8, 120);
    defer allocator.free(class_name);
    @memset(class_name, 'A');
    const source = try std.fmt.allocPrint(
        allocator,
        "class {s} {{ __workletClass = true; value() {{ return 42; }} }}",
        .{class_name},
    );
    defer allocator.free(source);

    var result = try transformWorklet(allocator, source);
    defer result.deinit();
    const code = try generateCode(&result);
    defer allocator.free(code);
    const expected_factory = try std.fmt.allocPrint(allocator, "function {s}__classFactory()", .{class_name});
    defer allocator.free(expected_factory);
    try std.testing.expect(std.mem.indexOf(u8, code, expected_factory) != null);
}

test "Worklet init code uses the exact semantic enum IIFE parameter" {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function workletFn() {
        \\  "worklet";
        \\  const _Shade = 7;
        \\  enum Shade { Shade = 1, Next = Shade.Shade + 1 }
        \\  return Shade.Next + _Shade;
        \\}
    ;

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    parser.is_module = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var transformer = try transformer_mod.Transformer.init(allocator, &parser.ast, .{
        .plugins = &plugins,
        .jsx_filename = "test.ts",
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.namespace_declaration_owners = &analyzer.namespace_declaration_owners;
    transformer.unresolved_references = &analyzer.unresolved_references;

    const root = try transformer.transform();
    try std.testing.expect(!root.isNone());

    var expected_parameter_name: ?[]const u8 = null;
    for (analyzer.symbols.items) |symbol| {
        if (symbol.synthetic_kind == .enum_iife_parameter) {
            expected_parameter_name = symbol.synthetic_name;
            break;
        }
    }
    try std.testing.expect(expected_parameter_name != null);
    try std.testing.expect(std.mem.eql(u8, expected_parameter_name.?, "_Shade1"));

    var init_data_code: ?[]const u8 = null;
    for (transformer.ast.nodes.items) |node| {
        if (node.tag != .string_literal) continue;
        const text = transformer.ast.getText(node.span);
        if (std.mem.indexOf(u8, text, "function workletFn") != null) {
            init_data_code = text;
            break;
        }
    }
    try std.testing.expect(init_data_code != null);
    try std.testing.expect(std.mem.indexOf(u8, init_data_code.?, expected_parameter_name.?) != null);
    const exact_member_read = try std.fmt.allocPrint(allocator, "{s}.Shade", .{expected_parameter_name.?});
    try std.testing.expect(std.mem.indexOf(u8, init_data_code.?, exact_member_read) != null);
    try std.testing.expect(std.mem.indexOf(u8, init_data_code.?, "Shade.Shade") == null);
}

fn checkWorkletClassFactoryExactCoverage(
    unsupported: compat.UnsupportedFeatures,
    target_name: []const u8,
    class_name: []const u8,
    source: []const u8,
) !void {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const coverage = @import("symbol_coverage.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();

    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var transformer = try transformer_mod.Transformer.init(allocator, &parser.ast, .{
        .plugins = &plugins,
        .unsupported = unsupported,
        .jsx_filename = "test.ts",
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;

    const root = try transformer.transform();
    var codegen = @import("../codegen/codegen.zig").Codegen.init(allocator, transformer.ast);
    defer codegen.deinit();
    const output = try codegen.generate(root);
    if (std.mem.indexOf(u8, source, "\\u0046") != null) {
        try std.testing.expect(std.mem.indexOf(u8, output, "function __zntcWorkletClassFactory2()") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, output, "__closure = { instanceValue:") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__closure = { value:") == null);
    if (std.mem.indexOf(u8, source, "[computedKey]") != null)
        try std.testing.expect(std.mem.indexOf(u8, output, "__closure = { computedKey: computedKey }") != null);
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
    if (!report.hasCompleteExactCoverage()) coverage.printStrict(target_name, &report);
    try std.testing.expect(report.hasCompleteExactCoverage());

    const class_factory_output_name = try std.fmt.allocPrint(allocator, "{s}__classFactory", .{class_name});
    var class_factory_symbol_id: ?u32 = null;
    for (edited.symbols.items, 0..) |symbol, raw_symbol_id| {
        if (symbol.synthetic_kind != .worklet_factory_local or
            !std.mem.eql(u8, symbol.output_name_hint, class_factory_output_name)) continue;
        try std.testing.expect(class_factory_symbol_id == null);
        class_factory_symbol_id = @intCast(raw_symbol_id);
        try std.testing.expect(!std.mem.eql(u8, symbol.synthetic_name, class_factory_output_name));
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.function_decl, symbol.kind);
        try std.testing.expectEqual(
            @import("../semantic/scope.zig").ScopeKind.function,
            edited.scopes[symbol.scope_id.toIndex()].kind,
        );
    }
    try std.testing.expect(class_factory_symbol_id != null);

    // The source class keeps its original inner-name identity. The class
    // reconstructed by the worklet factory owns a different immutable name,
    // while the factory's mutable `var Clazz` remains in the parent function.
    var source_class_self: ?u32 = null;
    var source_self_iter = analyzer.class_self_symbol_map.iterator();
    while (source_self_iter.next()) |entry| {
        if (entry.key_ptr.* >= transformer.parser_node_count) continue;
        if (parser.ast.getNode(@fromBackingInt(@intCast(entry.key_ptr.*))).tag != .class_declaration) continue;
        source_class_self = entry.value_ptr.*;
        break;
    }
    try std.testing.expect(source_class_self != null);

    var generated_class_self: ?u32 = null;
    var generated_self_iter = transformer.class_self_symbol_map.iterator();
    while (generated_self_iter.next()) |entry| {
        if (entry.key_ptr.* < transformer.parser_node_count) continue;
        if (transformer.ast.getNode(@fromBackingInt(@intCast(entry.key_ptr.*))).tag != .class_expression) continue;
        try std.testing.expect(generated_class_self == null);
        generated_class_self = entry.value_ptr.*;
    }
    try std.testing.expect(generated_class_self != null);
    try std.testing.expect(generated_class_self.? != source_class_self.?);

    const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
    const ScopeKind = @import("../semantic/scope.zig").ScopeKind;
    const generated_symbol = edited.symbols.items[generated_class_self.?];
    try std.testing.expectEqual(SymbolKind.class_decl, generated_symbol.kind);
    try std.testing.expect(generated_symbol.decl_flags.is_const);
    const generated_class_scope = edited.scopes[generated_symbol.scope_id.toIndex()];
    if (unsupported.class) {
        try std.testing.expect(generated_class_scope.kind == .function or generated_class_scope.kind == .class_body);
    } else if (unsupported.class_static_block) {
        // A native class expression whose static code moves out already has
        // its real class-declaration storage in the planned wrapper function.
        try std.testing.expectEqual(ScopeKind.function, generated_class_scope.kind);
        const parents = try @import("output_scope_test_utils.zig").buildParentMap(allocator, transformer.ast, root);
        var actual_declarations: usize = 0;
        for (transformer.ast.nodes.items, 0..) |node, raw| {
            if (node.tag != .class_declaration or !parents.contains(@intCast(raw))) continue;
            const binding = transformer.ast.readExtraNode(node.data.extra, @import("../parser/ast.zig").ClassExtra.name);
            if (binding.isNone() or edited.symbol_ids[@backingInt(binding)] != generated_class_self) continue;
            const body = parents.get(@intCast(raw)).?;
            const owner = parents.get(body).?;
            try std.testing.expectEqual(.block_statement, transformer.ast.nodes.items[body].tag);
            try std.testing.expectEqual(if (unsupported.arrow) @import("../parser/ast.zig").Node.Tag.function_expression else .arrow_function_expression, transformer.ast.nodes.items[owner].tag);
            try std.testing.expectEqual(@as(?u32, @backingInt(generated_symbol.scope_id)), edited.scope_owner_map.get(owner));
            actual_declarations += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), actual_declarations);
    } else {
        try std.testing.expectEqual(ScopeKind.class_body, generated_class_scope.kind);
    }
    var factory_local: ?u32 = null;
    for (edited.symbols.items, 0..) |symbol, symbol_idx| {
        if (symbol.kind != .variable_var) continue;
        if (!std.mem.eql(u8, symbol.synthetic_name, class_name)) continue;
        try std.testing.expect(factory_local == null);
        factory_local = @intCast(symbol_idx);
    }
    try std.testing.expect(factory_local != null);
    try std.testing.expect(factory_local.? != generated_class_self.?);
    const factory_local_scope = edited.symbols.items[factory_local.?].scope_id;
    var factory_local_encloses_class = false;
    var scope_cursor = generated_symbol.scope_id;
    var scope_hops: usize = 0;
    while (!scope_cursor.isNone() and scope_hops < edited.scopes.len) : (scope_hops += 1) {
        if (scope_cursor == factory_local_scope) {
            factory_local_encloses_class = true;
            break;
        }
        scope_cursor = edited.scopes[scope_cursor.toIndex()].parent;
    }
    try std.testing.expect(factory_local_encloses_class);

    var outer_class_binding: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, symbol_idx| {
        if (symbol.kind != SymbolKind.class_decl or !std.mem.eql(u8, symbol.nameText(source), class_name)) continue;
        const scope_kind = analyzer.scopes.items[symbol.scope_id.toIndex()].kind;
        if (scope_kind == ScopeKind.module or scope_kind == ScopeKind.global) {
            outer_class_binding = @intCast(symbol_idx);
            break;
        }
    }
    try std.testing.expect(outer_class_binding != null);

    var source_self_refs: usize = 0;
    var generated_self_refs: usize = 0;
    var outer_class_refs: usize = 0;
    for (edited.references) |reference| {
        const reference_symbol = @backingInt(reference.symbol_id);
        if (reference_symbol == source_class_self.?) source_self_refs += 1;
        if (reference_symbol == generated_class_self.?) generated_self_refs += 1;
        if (reference_symbol == outer_class_binding.?) outer_class_refs += 1;
    }
    var analyzed_source_self_refs: usize = 0;
    for (analyzer.references.items) |reference|
        if (@backingInt(reference.symbol_id) == source_class_self.?) {
            analyzed_source_self_refs += 1;
        };
    if (analyzed_source_self_refs > 0) {
        try std.testing.expect(source_self_refs >= analyzed_source_self_refs);
        try std.testing.expect(generated_self_refs >= analyzed_source_self_refs);
    }
    try std.testing.expect(outer_class_refs > 0);
}

test "#4819 Worklet class factories bind reconstructed class identity exactly" {
    const hostile_source =
        \\class Clazz {
        \\  __workletClass = true;
        \\  static value = Clazz;
        \\  instanceValue = () => Clazz;
        \\  static { globalThis.workletClassSelf = Clazz; }
        \\  static self() {
        \\    "worklet";
        \\    const readSelf = () => Clazz;
        \\    function shadow(Clazz) { return Clazz; }
        \\    return readSelf() === shadow(null);
        \\  }
        \\}
        \\let observed = Clazz;
        \\Clazz = null;
    ;
    try checkWorkletClassFactoryExactCoverage(compat.fromESTarget(.es5), "worklet-class-factory-es5.ts", "Clazz", hostile_source);
    try checkWorkletClassFactoryExactCoverage(compat.fromESTarget(.es2022), "worklet-class-factory-es2022.ts", "Clazz", hostile_source);

    const empty_source =
        \\class Bare { __workletClass = true; }
        \\let observed = Bare;
        \\Bare = null;
    ;
    try checkWorkletClassFactoryExactCoverage(compat.fromESTarget(.es5), "worklet-class-factory-empty-es5.ts", "Bare", empty_source);
    try checkWorkletClassFactoryExactCoverage(compat.fromESTarget(.es2022), "worklet-class-factory-empty-es2022.ts", "Bare", empty_source);

    const computed_key_source =
        \\const computedKey = "dynamic";
        \\class Clazz {
        \\  __workletClass = true;
        \\  static [computedKey] = Clazz;
        \\  static read() { return Clazz; }
        \\}
        \\let observed = Clazz;
    ;
    try checkWorkletClassFactoryExactCoverage(compat.fromESTarget(.es2022), "worklet-class-factory-computed-key-es2022.ts", "Clazz", computed_key_source);
}

test "#4819 Worklet class factory staging name avoids escaped source bindings" {
    const escaped_source =
        \\const __zntcWorkletClass\u0046actory = 73;
        \\class Clazz {
        \\  __workletClass = true;
        \\  static capturedFactoryName() { return __zntcWorkletClass\u0046actory; }
        \\}
    ;
    try checkWorkletClassFactoryExactCoverage(.{}, "worklet-class-factory-escaped-source.ts", "Clazz", escaped_source);
}

fn checkBlockFunctionWorkletSemanticEdit(is_module: bool) !void {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const coverage = @import("symbol_coverage.zig");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source =
        \\function nestedDeclaration(flag) {
        \\  if (flag) {
        \\    function localWorklet() { "worklet"; return 5; }
        \\    return localWorklet();
        \\  }
        \\  {
        \\    function localWorklet() { "worklet"; return 6; }
        \\    return localWorklet();
        \\  }
        \\}
    ;

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = is_module;
    try analyzer.analyze();

    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var transformer = try transformer_mod.Transformer.init(allocator, &parser.ast, .{
        .plugins = &plugins,
        .jsx_filename = "test.ts",
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
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
    if (!report.hasCompleteExactCoverage()) coverage.printStrict("worklet-block-function.ts", &report);
    try std.testing.expect(report.hasCompleteExactCoverage());
}

test "Worklet: block function declaration does not collide in module semantic edit" {
    try checkBlockFunctionWorkletSemanticEdit(true);
}

test "Worklet: block function declaration does not collide in script semantic edit" {
    try checkBlockFunctionWorkletSemanticEdit(false);
}

test "Worklet: function with worklet directive adds property assignments" {
    var r = try transformWorklet(std.testing.allocator,
        \\function animate(x) {
        \\  "worklet";
        \\  return withSpring(x + offset);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // "worklet" 디렉티브가 제거되고, 함수 뒤에 __workletHash, __closure, __initData가 추가됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
    // "worklet" 디렉티브는 출력에서 제거됨
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\"") == null);
}

test "Worklet: function without worklet directive is unchanged" {
    var r = try transformWorklet(std.testing.allocator,
        \\function foo(x) {
        \\  return x + 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // worklet 변환 없음
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") == null);
}

test "Worklet: statement count includes property assignments" {
    // function + 3 property assignments = 4 statements
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function animate(x) { \"worklet\"; return withSpring(x + offset); }",
        .{ .plugins = &[_]Plugin{worklet_plugin_mod.plugin()}, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    // 1 function declaration + 4 property assignments (hash/closure/initData/stackDetails/pluginVersion) = 6 statements
    try std.testing.expectEqual(@as(u32, 6), r.statementCount());
}

test "Worklet: no closure vars produces empty closure object" {
    var r = try transformWorklet(std.testing.allocator,
        \\function simple() {
        \\  "worklet";
        \\  return 42;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: multiple closure vars are sorted alphabetically" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim(x) {
        \\  "worklet";
        \\  return withSpring(x + offset + scale);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // closure 변수: offset, scale, withSpring (알파벳 순)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "offset") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "scale") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "withSpring") != null);
}

test "Worklet: parameters are not closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim(x, y) {
        \\  "worklet";
        \\  return x + y + offset;
        \\}
    );
    defer r.deinit();
    // function + 5 property assignments = 6 statements
    try std.testing.expectEqual(@as(u32, 6), r.statementCount());
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x, y는 파라미터이므로 closure에 포함되지 않아야 함
    // __closure에 offset만 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { offset: offset }") != null);
}

test "Worklet: initData contains code and location" {
    var r = try transformWorklet(std.testing.allocator,
        \\function move() {
        \\  "worklet";
        \\  return velocity;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // __initData에 code와 location 필드가 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "code:") != null or
        std.mem.indexOf(u8, code, "code: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "location:") != null or
        std.mem.indexOf(u8, code, "location: ") != null);
    // location에 test.ts 경로가 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "test.ts") != null);
}

test "Worklet: non-worklet function mixed with worklet function" {
    var r = try transformWorklet(std.testing.allocator,
        \\function normal() { return 1; }
        \\function anim() {
        \\  "worklet";
        \\  return 2;
        \\}
    );
    defer r.deinit();
    // normal(1) + anim(1) + 5 property assignments = 7 statements
    try std.testing.expectEqual(@as(u32, 7), r.statementCount());
}

test "Worklet: globals are excluded from closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim() {
        \\  "worklet";
        \\  console.log(Math.random());
        \\  return undefined;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // console, Math, undefined는 글로벌이므로 closure에 포함되지 않아야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: react-native-worklets default globals are excluded from closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\function anim() {
        \\  "worklet";
        \\  return [
        \\    decodeURI, decodeURIComponent, encodeURI, encodeURIComponent, escape, unescape,
        \\    Function, AggregateError, EvalError, RangeError, ReferenceError, SyntaxError,
        \\    TypeError, URIError, InternalError, BigInt, Uint8ClampedArray, Atomics,
        \\    WeakRef, FinalizationRegistry, Iterator, AsyncIterator, GeneratorFunction,
        \\    AsyncGeneratorFunction, Generator, AsyncGenerator, AsyncFunction, performance,
        \\    setImmediate, clearImmediate, HermesInternal, _WORKLET, _IS_FABRIC,
        \\  ];
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // react-native-worklets Babel plugin의 notCapturedIdentifiers와 맞춰 closure에 넣지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "performance: performance") == null);
}

test "Worklet: worklets error bindings are excluded from closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\const ReanimatedError = Error;
        \\const WorkletsError = Error;
        \\function anim() {
        \\  "worklet";
        \\  if (Math.random()) throw new ReanimatedError("bad");
        \\  throw new WorkletsError("bad");
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // Babel plugin은 이 에러 바인딩을 글로벌로 취급하므로 closure/classFactory에 넣지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "ReanimatedError: ReanimatedError") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "ReanimatedError__classFactory") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "WorkletsError: WorkletsError") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "WorkletsError__classFactory") == null);
}

test "Worklet: worklet transform disabled when no plugins" {
    // plugins 없이 변환하면 worklet 처리 안 됨
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function f() { \"worklet\"; return 1; }",
        .{},
    );
    defer r.deinit();
    // plugins가 없으므로 worklet 변환 없음 — statement 1개 (함수만)
    try std.testing.expectEqual(@as(u32, 1), r.statementCount());
}

test "Worklet: rest params are not included in closure (#1104)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function guard(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{
            .plugins = &plugins,
            .jsx_filename = "test.ts",
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
        },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // pre-visit body 사용: fn, args는 파라미터이므로 closure 비어야 함.
    // ES5 헬퍼(__toConsumableArray)는 pre-visit body에 없으므로 closure에 미포함.
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: directive found after rest params transform (#1102)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "function guard(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{
            .plugins = &plugins,
            .jsx_filename = "test.ts",
            .unsupported = TransformOptions.compat.fromESTarget(.es5),
        },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // worklet 변환이 적용되어야 함 (디렉티브가 rest params 뒤로 밀려도)
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    // "worklet" 디렉티브가 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\"") == null);
}

test "Worklet: function_expression worklet produces IIFE factory (#1100)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var x = wrap(function myWorklet() { \"worklet\"; return 42; });",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // IIFE factory로 감싸져야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    // 원본 함수가 IIFE 안에서 var로 할당
    try std.testing.expect(std.mem.indexOf(u8, code, "var myWorklet") != null);
    // return으로 반환
    try std.testing.expect(std.mem.indexOf(u8, code, "return myWorklet") != null);
}

test "Worklet: property access not collected as closure var (if_statement ternary)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(std.testing.allocator,
        \\function calc(current, previous) {
        \\  "worklet";
        \\  if (previous === undefined) {
        \\    return current.force;
        \\  } else {
        \\    return current.force - previous.force;
        \\  }
        \\}
    , .{ .plugins = &plugins, .jsx_filename = "test.ts" });
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 'force'는 property access이므로 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested member expression a.b.c excludes property names" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  return obj.a.b.c;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj는 param → closure 비어야 함. a, b, c는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: external variable captured, property excluded" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var config = { speed: 1 }; function f(x) { \"worklet\"; return x * config.speed; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // config → closure, speed → property 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "config") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { config: config }") != null);
}

test "Worklet: try-catch body member access excludes property" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  try { return obj.data; } catch(e) { return e.message; }
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj, e는 param/catch local → closure 비어야 함. data, message는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: destructuring locals not in closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(obj) {
        \\  "worklet";
        \\  const { x, y } = obj;
        \\  return x + y;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x, y는 destructuring → locals. obj는 param → locals.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: conditional expression member access" {
    var r = try transformWorklet(std.testing.allocator,
        \\function f(x, flag) {
        \\  "worklet";
        \\  return flag ? x.a : x.b;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // a, b는 property → 제외
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: inner function declaration is local" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var cb = 1; function f() { \"worklet\"; function inner() { return 1; } return cb; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // inner → local function. cb → external closure var.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { cb: cb }") != null);
}

test "Worklet: globalThis property not collected as closure var (unary_expression extra)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var fn = 1; function setup() { \"worklet\"; if (!globalThis.__myProp) { globalThis.__myProp = fn; } }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // __myProp는 globalThis의 property이므로 closure에 포함되면 안 됨
    // fn만 closure에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { fn: fn }") != null);
}

test "Worklet: arrow function params not in closure (ES5 lowering)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const pf = (value, context) => { \"worklet\"; return ext + value + context; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // value, context는 파라미터이므로 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: arrow function params not in closure (arrow 보존, ES5 lowering 없음)" {
    // #1283 후속: RN Hermes 프리셋은 arrow를 보존 — parser가 모든 arrow의 params를
    // formal_parameters list로 정규화하므로 worklet plugin이 파라미터를 올바르게
    // 인식해야 한다. value/context는 closure에 포함되면 안 됨.
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const pf = (value, context) => { \"worklet\"; return ext + value + context; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // params(value, context)는 closure에서 제외, ext만 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
    // value/context가 __closure에 들어가면 안 됨 (Hermes ReferenceError 방지)
    try std.testing.expect(std.mem.indexOf(u8, code, "value: value") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "context: context") == null);
}

test "Worklet: single-param arrow (x => ...) — x는 closure에서 제외 (arrow 보존)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const pf = x => { \"worklet\"; return ext + x; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "x: x") == null);
}

test "Worklet: arrow function with typed var params not in closure (ES5 lowering)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "type Fn = any; var ext = 1; export const pf: Fn = (value, context) => { \"worklet\"; return ext + value + context; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // type annotation이 변수에 있고 params에는 없는 경우에도 params는 제외되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: pre-visit body used for initData (no ES5 helpers in closure)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function setup() { \"worklet\"; const f = (cb: any, ...args: any[]) => { cb(...args); }; globalThis.setTimeout = f as any; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // pre-visit body 사용: ES5 헬퍼(__toConsumableArray)가 closure에 없어야 함.
    // Hermes UI runtime이 spread를 네이티브 지원하므로 ES5 변환 불필요.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested function captures outer refs but params stay local" {
    var r = try transformWorklet(std.testing.allocator,
        \\var ext = 1;
        \\export function w() {
        \\  "worklet";
        \\  function inner(x) { return x + ext; }
        \\  return inner(1);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // ext는 inner body에서 참조하는 외부 변수 → worklet closure에 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "ext}=this.__closure") != null);
    // inner의 param x는 closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "x: x") == null);
}

test "Worklet: default param (c = 0) not in closure" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export const f = (c = 0) => { \"worklet\"; return c * 2; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // c는 default parameter — closure에 포함되면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: default param with external ref" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var scale = 2; export const f = (c = 0) => { \"worklet\"; return c * scale; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // c는 param → 제외, scale은 외부 참조 → 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { scale: scale }") != null);
}

test "Worklet: __stackDetails property is emitted" {
    // Babel workletFactory.ts:298-327 포맷: [new global.Error(), lineOffset, -27]
    var r = try transformWorklet(std.testing.allocator,
        \\function f() {
        \\  "worklet";
        \\  return 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__stackDetails = [new global.Error()") != null);
}

test "Worklet: initData code has no ES5 helpers (spread preserved)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function g(fn, ...args) { \"worklet\"; return fn(...args); }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // initData.code에 __toConsumableArray가 없어야 함 (pre-visit body 사용)
    const init_start = std.mem.indexOf(u8, code, "__initData = { code:") orelse unreachable;
    const init_end = std.mem.indexOfPos(u8, code, init_start, "location:") orelse unreachable;
    const init_section = code[init_start..init_end];
    try std.testing.expect(std.mem.indexOf(u8, init_section, "__toConsumableArray") == null);
    // 원본 spread 문법이 유지되어야 함
    try std.testing.expect(std.mem.indexOf(u8, init_section, "...args") != null);
}

test "Worklet: initData code has no TS syntax (as expression stripped)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "export function g(v: number) { \"worklet\"; return v as any; }",
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // initData.code에 TS 'as' 구문이 없어야 함
    const init_start = std.mem.indexOf(u8, code, "__initData = { code:") orelse unreachable;
    const init_end = std.mem.indexOfPos(u8, code, init_start, "location:") orelse unreachable;
    const init_section = code[init_start..init_end];
    try std.testing.expect(std.mem.indexOf(u8, init_section, " as ") == null);
}

test "Worklet: global stays global and __DEV__ is captured like Metro" {
    var r = try transformWorklet(std.testing.allocator,
        \\export function f() {
        \\  "worklet";
        \\  if (__DEV__) { console.log(global); }
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // Metro Worklets 플러그인은 __DEV__를 글로벌 제외 목록에 넣지 않고
    // closure 값으로 캡처한다. UI 런타임의 __initData.code가 번들 prelude를
    // 볼 수 없기 때문에 zntc도 같은 방식으로 전달해야 한다.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { __DEV__: __DEV__ }") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "console.log(global)") != null);
}

test "Worklet: multiple default params not in closure" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const f = (a = 0, b = 1) => { \"worklet\"; return a + b + ext; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // a, b는 default params → 제외, ext만 closure에
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
}

test "Worklet: arrow function with worklet directive is transformed (ES5)" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        "var ext = 1; export const f = () => { \"worklet\"; return ext; };",
        .{ .plugins = &plugins, .jsx_filename = "test.ts", .unsupported = TransformOptions.compat.fromESTarget(.es5) },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // arrow worklet이 IIFE factory로 변환되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = { ext: ext }") != null);
    // "worklet" 디렉티브가 제거되어야 함 (__initData 안은 제외)
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
}

test "Worklet: nested worklet calls another worklet" {
    var r = try transformWorklet(std.testing.allocator,
        \\function helper() {
        \\  "worklet";
        \\  return 42;
        \\}
        \\function main() {
        \\  "worklet";
        \\  return helper();
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 둘 다 worklet으로 변환
    var count: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, code, search, "__workletHash")) |pos| {
        count += 1;
        search = pos + 1;
    }
    try std.testing.expect(count >= 2);
    // main의 closure에 helper가 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "helper: helper") != null);
}

test "Worklet: computed property access in worklet body" {
    var r = try transformWorklet(std.testing.allocator,
        \\var obj = {};
        \\var key = "x";
        \\function f() {
        \\  "worklet";
        \\  return obj[key];
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // obj와 key 모두 closure에 포함 (computed access는 둘 다 외부 참조)
    try std.testing.expect(std.mem.indexOf(u8, code, "key: key") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "obj: obj") != null);
}

test "Worklet: object method with worklet directive is transformed" {
    var r = try transformWorklet(std.testing.allocator,
        \\var logger = { warn(msg) {
        \\  "worklet";
        \\  return msg;
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // object method worklet → object_property + IIFE로 변환
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
    // method가 object_property value로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, code, "warn:") != null);
}

test "Worklet: object method with outer closure vars captured" {
    var r = try transformWorklet(std.testing.allocator,
        \\var config = {};
        \\var obj = { build(props) {
        \\  "worklet";
        \\  return config[props];
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "config}=this.__closure") != null);
}

test "Worklet: getter with worklet directive becomes factory body (Babel 호환)" {
    // getter/setter는 class body에서 IIFE 교체 불가 → body를 factory block으로 치환.
    // `get x() { var x = function(){...}; x.__workletHash=...; return x; }`
    // getter 접근 시 worklet 함수를 반환 (Reanimated 런타임과 일치).
    var r = try transformWorklet(std.testing.allocator,
        \\var obj = { get x() {
        \\  "worklet";
        \\  return 1;
        \\} };
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
}

test "Worklet: scope hoisting rename reflected in closure value" {
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var r = try parseAndTransformWithOptions(
        std.testing.allocator,
        \\import { helper } from "./a";
        \\import { helper as h2 } from "./b";
        \\export function w() { "worklet"; return helper() + h2(); }
    ,
        .{ .plugins = &plugins, .jsx_filename = "test.ts" },
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // closure에 helper가 포함되어야 함 (explicit key-value)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "helper:") != null);
}

test "Worklet: auto-workletization for scheduleOnUI argument" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\scheduleOnUI(() => {
        \\  console.log("auto worklet");
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // auto-worklet 변환: __workletHash가 주입되어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "__initData") != null);
}

test "Worklet: auto-workletization for runOnUI argument" {
    var r = try transformWorklet(std.testing.allocator,
        \\function runOnUI(fn) { return fn; }
        \\runOnUI(() => {
        \\  return 42;
        \\})();
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: auto-workletization skips non-function args" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\var x = 1;
        \\scheduleOnUI(x);
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 인자가 함수가 아니면 worklet 변환 없음
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: auto-workletization with correct arg index (withDecay arg 1)" {
    var r = try transformWorklet(std.testing.allocator,
        \\function withDecay(config, callback) {}
        \\withDecay({}, () => {
        \\  console.log("done");
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // withDecay의 두 번째 인자(index 1)가 worklet화
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: auto-workletization does not affect wrong arg index" {
    var r = try transformWorklet(std.testing.allocator,
        \\function withDecay(config, callback) {}
        \\withDecay(() => { return 1; }, null);
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // withDecay의 첫 번째 인자(index 0)는 auto-worklet 대상 아님
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: method auto-workletization for gesture handler onBegin" {
    // Babel parity: `Gesture.Foo()` 체인의 onBegin만 workletize.
    var r = try transformWorklet(std.testing.allocator,
        \\Gesture.Pan().onBegin((e) => {
        \\  console.log(e);
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") != null);
}

test "Worklet: method onBegin on non-gesture-object receiver is NOT workletized" {
    // 임의 객체의 `.onBegin()`은 auto-worklet 대상 아님 (Babel parity).
    var r = try transformWorklet(std.testing.allocator,
        \\var gesture = {};
        \\gesture.onBegin((e) => {
        \\  console.log(e);
        \\});
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__workletHash") == null);
}

test "Worklet: auto-workletization inside worklet function body" {
    var r = try transformWorklet(std.testing.allocator,
        \\function scheduleOnUI(fn) {}
        \\function outer() {
        \\  "worklet";
        \\  scheduleOnUI(() => {
        \\    console.log("inner");
        \\  });
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // outer 함수의 __workletHash
    try std.testing.expect(std.mem.indexOf(u8, code, "outer.__workletHash") != null);
    // inner arrow도 auto-worklet 변환되어야 함 (IIFE로 wrapping)
    // 이전 버그: stripDirective가 원본 body로 덮어써서 inner 변환이 손실
    const count = std.mem.count(u8, code, "__workletHash");
    try std.testing.expect(count >= 2); // outer + inner
}

test "Worklet: closure analysis includes refs inside object getters/setters/methods" {
    var r = try transformWorklet(std.testing.allocator,
        \\function outerFn() { return 42; }
        \\function w() {
        \\  "worklet";
        \\  return { get v() { return outerFn(); }, set v(x) { outerFn(); }, m() { outerFn(); } };
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // outerFn이 __closure에 포함되어야 함 (getter/setter/method body에서 참조)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "outerFn") != null);
    // __initData.code에서 this.__closure로 destructure
    try std.testing.expect(std.mem.indexOf(u8, code, "outerFn}=this.__closure") != null);
}

test "Worklet: object method worklet strips directive from IIFE body" {
    // method_definition 경로에서 stripped body를 사용하지 않으면
    // IIFE 내부 function 바디에 `'worklet'` directive가 잔존 (Reanimated runtime 크래시).
    var r = try transformWorklet(std.testing.allocator,
        \\var ERROR_MESSAGES = {
        \\  invalidColor(color) {
        \\    "worklet";
        \\    return "Invalid color: " + color;
        \\  }
        \\};
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "\"worklet\";") == null);
    try std.testing.expect(std.mem.indexOf(u8, code, "invalidColor.__workletHash") != null);
}

test "Worklet: recursive function self-reference excluded from __closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\function recurse(n) {
        \\  "worklet";
        \\  if (n > 0) recurse(n - 1);
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: TS type assertion (as) does not break closure analysis" {
    var r = try transformWorklet(std.testing.allocator,
        \\var outer = {} as any;
        \\function w() {
        \\  "worklet";
        \\  return (outer as any).value;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "outer}=this.__closure") != null);
}

test "Worklet: closure captures through ternary, template literal, array, spread" {
    var r = try transformWorklet(std.testing.allocator,
        \\var a = 1, b = 2, c = 3, d = [4];
        \\function w() {
        \\  "worklet";
        \\  var x = a ? b : c;
        \\  var y = `${a}`;
        \\  var z = [...d, a];
        \\  return x + y + z;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "a: a") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "b: b") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "c: c") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "d: d") != null);
}

test "Worklet: closure captures through switch, for-in, try-catch" {
    var r = try transformWorklet(std.testing.allocator,
        \\var val = 1, obj = {}, fn2 = () => {};
        \\function w() {
        \\  "worklet";
        \\  switch (val) { case 1: break; }
        \\  for (var k in obj) {}
        \\  try { fn2(); } catch (e) {}
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "val: val") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "obj: obj") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "fn2: fn2") != null);
    // catch param 'e'는 closure가 아닌 로컬
    try std.testing.expect(std.mem.indexOf(u8, code, "e: e") == null);
}

test "Worklet: method param shadowing does not leak to outer closure" {
    var r = try transformWorklet(std.testing.allocator,
        \\var x = 1;
        \\function w() {
        \\  "worklet";
        \\  var x = 2;
        \\  return { set v(x) { console.log(x); } };
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // x는 worklet 내부 로컬이므로 closure에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: nested object with computed property and new expression" {
    var r = try transformWorklet(std.testing.allocator,
        \\var key = "a", Cls = class {};
        \\function w() {
        \\  "worklet";
        \\  var o = { [key]: new Cls() };
        \\  return o;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "key: key") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "Cls: Cls") != null);
}

test "Worklet: nested function and arrow capture outer imports" {
    var r = try transformWorklet(std.testing.allocator,
        \\var isShared = (v) => v != null;
        \\var helper = () => 42;
        \\function w() {
        \\  "worklet";
        \\  function extract(x) {
        \\    if (isShared(x)) return;
        \\    var fn = () => helper();
        \\  }
        \\  return extract;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // 중첩 function 안의 isShared와 arrow 안의 helper 모두 worklet closure에 포함
    try std.testing.expect(std.mem.indexOf(u8, code, "isShared: isShared") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "helper: helper") != null);
    // extract의 param x는 closure에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, code, " x:x") == null);
}

test "Worklet: arrow callback param does not leak into outer closure (cover grammar)" {
    var r = try transformWorklet(std.testing.allocator,
        \\function w() {
        \\  "worklet";
        \\  var arr = [];
        \\  arr.forEach((item) => item());
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    // arrow param 'item'은 closure에 없어야 함 (cover grammar 파라미터)
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "Worklet: arrow with destructured param does not leak" {
    var r = try transformWorklet(std.testing.allocator,
        \\function w() {
        \\  "worklet";
        \\  var fn = ({ a, b }) => a + b;
        \\  return fn;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

// ============================================================
// Babel parity: __initData.code destructuring shorthand + sourceMap field (#1193 follow-up)
// ============================================================

test "Worklet: __initData.code uses shorthand destructuring (const {X} = this.__closure)" {
    // Babel react-native-worklets는 worklet code string에서 shorthand 형태로 emit.
    // Reanimated runtime이 해당 형태를 기대하는 경우를 대비 parity 유지.
    var r = try transformWorklet(std.testing.allocator,
        \\var foo = 1;
        \\function w() {
        \\  "worklet";
        \\  return foo + 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "{foo}=this.__closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "{foo:foo}=this.__closure") == null);
}

test "Worklet: __initData.code shorthand for multiple closure vars" {
    var r = try transformWorklet(std.testing.allocator,
        \\var a = 1, b = 2, c = 3;
        \\function w() {
        \\  "worklet";
        \\  return a + b + c;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "{a,b,c}=this.__closure") != null);
}

test "Worklet: __initData does NOT emit sourceMap when none generated" {
    // Babel plugin은 실제 source map 생성 성공 시에만 sourceMap 필드를 주입
    // (workletFactory.ts:187). 빈 문자열을 넣으면 Reanimated 네이티브가
    // JSON 파싱 실패 → UI Runtime 초기화 abort →
    // `Expected microtaskQueueFinalizers to be defined` 에러로 이어짐.
    // ZNTC는 worklet 수준 source map 미지원 → 필드 생략이 정답.
    var r = try transformWorklet(std.testing.allocator,
        \\function w() {
        \\  "worklet";
        \\  return 1;
        \\}
    );
    defer r.deinit();
    const code = try generateCode(&r);
    defer std.testing.allocator.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, "sourceMap") == null);
}

// ============================================================
// #2484 worklet walker depth 한계 회귀 가드
// ============================================================

test "#2484 regression: 100-deep nested expression — outer ref captured in closure" {
    // walkBodyForClosureAnalysis 의 depth>64 silent return 으로 65+ 깊이 ref 누락.
    // 명시 stack 으로 전환 후 100 depth 에서도 outerVar 가 closure 에 잡혀야 한다.
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "function w() {\n  \"worklet\";\n  return ");
    var i: u32 = 0;
    while (i < 100) : (i += 1) try src.appendSlice(a, "(");
    try src.appendSlice(a, "outerVar");
    while (i > 0) : (i -= 1) try src.appendSlice(a, ")");
    try src.appendSlice(a, ";\n}\n");

    var r = try transformWorklet(a, src.items);
    defer r.deinit();
    const code = try generateCode(&r);
    defer a.free(code);

    // closure 객체에 outerVar 가 포함되어야 한다 (worklet hoisted destructure 형태).
    try std.testing.expect(std.mem.indexOf(u8, code, "{outerVar}=this.__closure") != null);
}

test "#2484 regression: 35-deep nested object pattern param — leaf binding registered as local" {
    // collectAllIdentifiers 의 depth>32 silent return 으로 33+ 깊이의 param leaf 가
    // fn_locals 에 등록 안 됨 → body 의 그 이름 reference 가 outer ref 로 오분류 →
    // closure 에 잘못 포함. 명시 stack 으로 전환 후 35 깊이 leaf 도 정상 등록되어
    // closure 가 비어 있음을 확인 (정확 매칭).
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "function w(");
    var i: u32 = 0;
    while (i < 35) : (i += 1) try src.appendSlice(a, "{a:");
    try src.appendSlice(a, "x");
    while (i > 0) : (i -= 1) try src.appendSlice(a, "}");
    try src.appendSlice(a, ") {\n  \"worklet\";\n  return x;\n}\n");

    var r = try transformWorklet(a, src.items);
    defer r.deinit();
    const code = try generateCode(&r);
    defer a.free(code);

    // x 가 deep nested param leaf 로 정상 잡히면 outer ref 가 없어 closure 가 비어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, code, "__closure = {}") != null);
}

test "#2484 regression: deeply nested new expression — class factory captured" {
    // collectNewExpressionCallees 의 depth>128 silent return 으로 129+ 깊이의
    // new X() callee 가 new_classes 에 등록 안 됨 → factory 자동 import 누락.
    // 명시 stack 으로 전환 후 150 depth 도 정상 등록.
    const a = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "function w() {\n  \"worklet\";\n  return ");
    var i: u32 = 0;
    while (i < 150) : (i += 1) try src.appendSlice(a, "(");
    try src.appendSlice(a, "new DeepClass()");
    while (i > 0) : (i -= 1) try src.appendSlice(a, ")");
    try src.appendSlice(a, ";\n}\n");

    var r = try transformWorklet(a, src.items);
    defer r.deinit();
    const code = try generateCode(&r);
    defer a.free(code);

    // worklet class factory: `new X()` 발견 시 closure 에 `X` 와 `X__classFactory` 함께 등록.
    // 깊이 한도가 살아있으면 두 키 모두 누락되므로 정확 매칭으로 검증.
    try std.testing.expect(std.mem.indexOf(u8, code, "{DeepClass,DeepClass__classFactory}=this.__closure") != null);
}

test "static block environment Worklet reconstruction consumes its body alias before copying" {
    const source =
        \\class Clazz {
        \\  __workletClass = true;
        \\  static { globalThis.workletClassSelf = Clazz; }
        \\  static self() { "worklet"; return Clazz; }
        \\}
        \\const observed = Clazz;
        \\Clazz = null;
    ;
    try checkWorkletClassFactoryExactCoverage(compat.fromESTarget(.es5), "static-worklet-body-es5.ts", "Clazz", source);
    try checkWorkletClassFactoryExactCoverage(compat.fromESTarget(.es2015), "static-worklet-body-es2015.ts", "Clazz", source);
}

test "worklet class factory owns distinct statement nodes and cloned lexical identities" {
    try checkWorkletClassOwnedIdentity(true);
    try checkWorkletClassOwnedIdentity(false);
}

fn checkWorkletClassOwnedIdentity(is_module: bool) !void {
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const coordinates = @import("../semantic/statement_coordinates.zig");
    const source =
        \\const outside=42;
        \\class Clazz {
        \\  __workletClass=true;
        \\  method(value=outside){const local=value;return()=>[local,outside,Clazz]}
        \\}
        \\console.log(new Clazz().method()()[0]);
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(if (is_module) ".mjs" else ".js");
    _ = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.is_module = is_module;
    analyzer.collect_unresolved_reference_nodes = true;
    analyzer.enable_stmt_info = true;
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const plugins = [_]Plugin{worklet_plugin_mod.plugin()};
    var transformer = try transformer_mod.Transformer.init(a, &parser.ast, .{
        .plugins = &plugins,
        .jsx_filename = "owned-class.mjs",
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.class_self_symbol_map = analyzer.class_self_symbol_map;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.node_scope_provenance = analyzer.node_scope_provenance;
    transformer.unresolved_references = &analyzer.unresolved_references;
    transformer.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    transformer.semantic_edit_enabled = true;
    transformer.synthetic_idents = .empty;
    const source_root: @import("../parser/ast.zig").NodeIndex = @fromBackingInt(@as(u32, @intCast(transformer.ast.nodes.items.len - 1)));
    const source_symbol_count = analyzer.symbols.items.len;
    try transformer.buildBlockRenameMap();
    const root = try transformer.visitNode(source_root);
    const actual = try coordinates.collect(a, transformer.ast, root);
    try std.testing.expect(actual[@backingInt(root)] != null);
    const scope_utils = @import("output_scope_test_utils.zig");
    const editor = &transformer.semantic_editor.?;
    var parents = try scope_utils.buildParentMap(a, transformer.ast, root);
    var owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    const live = try @import("../parser/ast_walk.zig").collectReachableNodeIndicesFrom(a, transformer.ast, root);
    for (live) |raw| if (transformer.outputOwnedScope(@fromBackingInt(raw))) |scope| try owners.put(a, raw, @backingInt(scope));
    try std.testing.expectEqual(@as(usize, 1), transformer.plugins.worklet.class_factories.items.len);
    const factory = transformer.plugins.worklet.class_factories.items[0];
    try std.testing.expect(factory.source_self != factory.target_self);
    try std.testing.expect(factory.source_scope != factory.target_scope);
    try std.testing.expect(editor.scopes.items[factory.target_scope.toIndex()].is_strict);
    try std.testing.expectEqual(is_module, editor.scopes.items[factory.parent.toIndex()].is_strict);
    // Check the generated wrapper against its physical lexical context before
    // the generic output walker can observe or alter any metadata.
    var checked_wrappers: usize = 0;
    var owner_iterator = owners.iterator();
    while (owner_iterator.next()) |entry| {
        if (entry.value_ptr.* != @backingInt(factory.parent)) continue;
        const expected_parent = scope_utils.expectedScope(transformer.ast, root, &parents, &owners, entry.key_ptr.*).?;
        checked_wrappers += 1;
        try std.testing.expectEqual(expected_parent, editor.scopes.items[entry.value_ptr.*].parent);
    }
    try std.testing.expectEqual(@as(usize, 1), checked_wrappers);
    for (editor.references.items) |row| {
        if (row.flags.declare or row.node_index.isNone()) continue;
        const raw = @backingInt(row.node_index);
        if (raw >= actual.len or actual[raw] == null) continue;
        const use_scope = scope_utils.expectedScope(transformer.ast, root, &parents, &owners, raw) orelse continue;
        if (use_scope != row.scope_id) std.debug.print("worklet physical reference node={d} name={s} SID={d} actual={d} row={d}\n", .{ raw, transformer.ast.identifierNameText(transformer.ast.getNode(row.node_index)), @backingInt(row.symbol_id), @backingInt(use_scope), @backingInt(row.scope_id) });
        try std.testing.expectEqual(use_scope, row.scope_id);
    }
    var external: ?u32 = null;
    var parameter: ?u32 = null;
    var local: ?u32 = null;
    for (analyzer.symbols.items, 0..) |symbol, raw| {
        if (std.mem.eql(u8, symbol.nameText(source), "outside")) external = @intCast(raw);
        if (std.mem.eql(u8, symbol.nameText(source), "value")) parameter = @intCast(raw);
        if (std.mem.eql(u8, symbol.nameText(source), "local")) local = @intCast(raw);
    }
    try std.testing.expect(external != null and parameter != null and local != null);
    for ([_]u32{ parameter.?, local.? }) |original| {
        var matches: usize = 0;
        for (editor.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, raw| {
            if (std.meta.eql(symbol.name, analyzer.symbols.items[original].name) and symbol.kind == analyzer.symbols.items[original].kind) {
                try std.testing.expect(raw != original);
                try std.testing.expect(symbol.scope_id != analyzer.symbols.items[original].scope_id);
                matches += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
    var clone_external_reads: usize = 0;
    var clone_self_reads: usize = 0;
    var checked: usize = 0;
    for (transformer.plugins.worklet.class_reference_nodes.items) |node| {
        const raw = @backingInt(node);
        if (raw >= actual.len or actual[raw] == null) continue;
        const origin = transformer.plugins.worklet.class_reference_origins.get(raw).?;
        var count: usize = 0;
        for (editor.references.items) |row| {
            const anchor = if (row.flags.declare) row.declaration_node_index else row.node_index;
            if (anchor != node) continue;
            try std.testing.expectEqual(origin.symbol, row.symbol_id);
            try std.testing.expectEqual(origin.scope, row.scope_id);
            try std.testing.expectEqualDeep(origin.flags, row.flags);
            const expected = scope_utils.expectedStatementCoordinates(transformer.ast, &parents, raw).?;
            try std.testing.expectEqual(expected.stmt_idx, row.stmt_idx);
            try std.testing.expectEqual(expected.scope_stmt_idx, row.scope_stmt_idx);
            if (!row.flags.declare) try std.testing.expectEqual(@as(?@import("../semantic/scope.zig").ScopeId, row.scope_id), scope_utils.expectedScope(transformer.ast, root, &parents, &owners, raw));
            count += 1;
            if (row.flags.read and @backingInt(row.symbol_id) == external.?) clone_external_reads += 1;
            if (row.flags.read and row.symbol_id == factory.target_self) clone_self_reads += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        checked += 1;
    }
    try std.testing.expect(checked > 5 and clone_external_reads > 0 and clone_self_reads > 0);
    const publication = @import("worklet_class_clone.zig");
    var selected_node: @import("../parser/ast.zig").NodeIndex = .none;
    var selected_row: usize = 0;
    for (transformer.plugins.worklet.class_reference_nodes.items) |node| {
        if (actual[@backingInt(node)] == null) continue;
        const origin = transformer.plugins.worklet.class_reference_origins.get(@backingInt(node)).?;
        if (@backingInt(origin.symbol) != external.? or !origin.flags.read) continue;
        for (editor.references.items, 0..) |row, index| {
            if (row.node_index == node) {
                selected_node = node;
                selected_row = index;
                break;
            }
        }
        if (!selected_node.isNone()) break;
    }
    try std.testing.expect(!selected_node.isNone());
    const original_row = editor.references.items[selected_row];
    const original_origin = transformer.plugins.worklet.class_reference_origins.get(@backingInt(selected_node)).?;
    const original_slot = editor.symbol_ids.items[@backingInt(selected_node)];
    const reference_snapshot = try a.dupe(@import("../semantic/symbol.zig").Reference, editor.references.items);
    for (0..8) |hostile| {
        switch (hostile) {
            0 => editor.references.items[selected_row].symbol_id = factory.source_self,
            1 => editor.references.items[selected_row].scope_id = factory.source_scope,
            2 => editor.references.items[selected_row].flags = .{ .write = true },
            3 => editor.symbol_ids.items[@backingInt(selected_node)] = @backingInt(factory.source_self),
            4 => _ = transformer.plugins.worklet.class_reference_origins.remove(@backingInt(selected_node)),
            5 => transformer.plugins.worklet.class_factories.items[0].target_self = factory.source_self,
            6 => transformer.plugins.worklet.class_factories.items[0].parent = factory.source_scope,
            7 => transformer.plugins.worklet.class_factories.items[0].source_scope = factory.target_scope,
            else => unreachable,
        }
        if (hostile >= 5) try std.testing.expectError(error.InvalidWorkletFactoryOwner, publication.publishChecked(&transformer, root)) else if (hostile == 4) try std.testing.expectError(error.MissingWorkletCloneOrigin, publication.publishChecked(&transformer, root)) else try std.testing.expectError(error.InvalidWorkletCloneOrigin, publication.publishChecked(&transformer, root));
        // Rejection does not publish positions for any other participating row.
        for (editor.references.items, reference_snapshot, 0..) |row, previous, index| {
            if (index == selected_row) continue;
            try std.testing.expectEqualDeep(previous, row);
        }
        editor.references.items[selected_row] = original_row;
        editor.symbol_ids.items[@backingInt(selected_node)] = original_slot;
        try transformer.plugins.worklet.class_reference_origins.put(a, @backingInt(selected_node), original_origin);
        transformer.plugins.worklet.class_factories.items[0] = factory;
        try publication.publishChecked(&transformer, root);
        try std.testing.expectEqualDeep(reference_snapshot, editor.references.items);
    }
    const clone_core = @import("../semantic/runtime_subtree_clone.zig");
    const good = clone_core.BoundaryBinding{ .source = factory.source_self, .target = factory.target_self };
    const node_count = transformer.ast.nodes.items.len;
    const symbol_count = editor.symbols.items.len;
    const row_count = editor.references.items.len;
    var no_owners: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    var foreign_ast = transformer.ast.*;
    for (0..5) |hostile| {
        var bindings = [_]clone_core.BoundaryBinding{ good, good };
        switch (hostile) {
            0 => bindings[0].source = @fromBackingInt(external.?),
            1 => bindings[0].target = factory.source_self,
            2 => bindings[0].source = factory.target_self,
            3, 4 => {},
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidCloneOwnership, clone_core.cloneWithBindings(
            a,
            if (hostile == 4) &foreign_ast else transformer.ast,
            editor,
            &.{},
            &no_owners,
            &.{},
            &.{},
            factory.source_scope,
            factory.target_scope,
            bindings[0..if (hostile == 3) 2 else 1],
        ));
        try std.testing.expectEqual(node_count, transformer.ast.nodes.items.len);
        try std.testing.expectEqual(symbol_count, editor.symbols.items.len);
        try std.testing.expectEqual(row_count, editor.references.items.len);
        try std.testing.expectEqualDeep(reference_snapshot, editor.references.items);
        try publication.publishChecked(&transformer, root);
    }
}
