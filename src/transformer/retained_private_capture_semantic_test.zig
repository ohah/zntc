const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer.zig").Transformer;
const TransformOptions = @import("transformer.zig").TransformOptions;
const ast = @import("../parser/ast.zig");
const Span = @import("../lexer/token.zig").Span;

fn checkRetainedPrivate(source: []const u8, private_lowering: bool, expected_private_name: ?[]const u8, orphan: bool) !void {
    errdefer std.debug.print("source: {s}\n", .{source});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, source);
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".cjs");
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var analyzer = SemanticAnalyzer.init(alloc, &parser.ast);
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    var unsupported = TransformOptions.compat.fromESTarget(if (private_lowering) .es5 else .es2022);
    // A valid partial capability profile: arrows require lowering, private
    // classes remain native. It must keep the existing 1503/1504 policy.
    unsupported.arrow = true;
    var t = try Transformer.init(alloc, &parser.ast, .{ .unsupported = unsupported });
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.class_self_symbol_map = analyzer.class_self_symbol_map;
    t.node_scope_provenance = analyzer.node_scope_provenance;
    t.unresolved_references = &analyzer.unresolved_references;
    t.unresolved_reference_nodes = &analyzer.unresolved_reference_nodes;
    t.semantic_edit_enabled = true;
    if (orphan) _ = try t.ast.addNode(.{ .tag = .private_identifier, .span = .{ .start = 0, .end = 1 }, .data = .{ .string_ref = .{ .start = 0, .end = 1 } } });
    const root = try t.transform();
    const expects_error = private_lowering and expected_private_name != null;
    try std.testing.expectEqual(expects_error, t.unsupported_arrow_private_scope_span != null);
    if (t.unsupported_arrow_private_scope_span) |span| {
        try std.testing.expect(span.end > span.start and span.end <= source.len);
        try std.testing.expectEqualStrings(expected_private_name.?, source[span.start..span.end]);
        try std.testing.expect(@import("../parser/ast_walk.zig").hasRawPrivateSyntax(t.ast, root));
    }
    try std.testing.expect(t.used_unsupported_arrow_dynamic_scope or t.used_unsupported_arrow_dynamic_eval);
}

test "retained private capture diagnoses exact syntax and target without weakening codegen" {
    const sources = [_]struct { source: []const u8, private_name: []const u8 }{
        .{ .source = "function Parent(){return()=>{with({}){return class{#value=7;[this.key](){return this.#value}}}}}", .private_name = "#value" },
        .{ .source = "function Parent(){return()=>{with({}){return class{#read(){return 7}[this.key](){return this.#read()}}}}}", .private_name = "#read" },
        .{ .source = "function Parent(){return()=>{with({}){return class{get #read(){return 7}[this.key](){return this.#read}}}}}", .private_name = "#read" },
        .{ .source = "function Parent(){return()=>{with({}){return class{set #write(value){this.value=value}[this.key](){this.#write=7;return this.value}}}}}", .private_name = "#write" },
        .{ .source = "function Parent(){return()=>{with({}){return class{static #value=7;static [this.key](){return this.#value}}}}}", .private_name = "#value" },
        .{ .source = "function Parent(){return()=>{with({}){return class{static #read(){return 7}static [this.key](){return this.#read()}}}}}", .private_name = "#read" },
        .{ .source = "function Parent(){return()=>{with({}){return class{#value=7;[this.key](){return #value in this}}}}}", .private_name = "#value" },
        .{ .source = "function Parent(){return()=>{with({}){return class Named{#value=7;[this.key](){return this.#value}}}}}", .private_name = "#value" },
        .{ .source = "function Parent(){with({}){return()=>class{#value=7;[this.key](){return this.#value}}}}", .private_name = "#value" },
        .{ .source = "function Parent(code){return()=>{eval(code);return class{#value=7;[this.key](){return this.#value}}}}", .private_name = "#value" },
    };
    for (sources) |fixture| {
        try checkRetainedPrivate(fixture.source, true, fixture.private_name, false);
        try checkRetainedPrivate(fixture.source, false, fixture.private_name, false);
    }
    const private_looking_string = "function Parent(){return()=>{with({}){return [this,'#value=7']}}}";
    try checkRetainedPrivate(private_looking_string, true, null, false);
    try checkRetainedPrivate(private_looking_string, true, null, true);
    // A private class elsewhere in the module is lowered normally. It is not
    // part of the native arrow subtree retained by the dynamic-capture guard.
    try checkRetainedPrivate("class Other{#value=7;read(){return this.#value}}function Parent(){return()=>{with({}){return this}}}", true, null, false);
}

test "retained private capture supplies a typed diagnostic with real source span" {
    const Capture = struct {
        threadlocal var span: ?Span = null;
        threadlocal var code: ?@import("../error_codes.zig").Code = null;
        fn onError(_: []const u8, _: []const u8, _: *const Scanner, diagnostics: []const @import("../diagnostic.zig").Diagnostic) void {
            if (diagnostics.len != 1) return;
            span = diagnostics[0].span;
            code = diagnostics[0].code;
        }
    };
    const source = "function Parent(){return()=>{with({}){return class{#value=7;[this.key](){return this.#value}}}}}";
    Capture.span = null;
    Capture.code = null;
    try std.testing.expectError(error.ArrowPrivateDynamicScope, @import("../transpile.zig").transpileWithCallback(std.testing.allocator, source, "input.cjs", .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    }, &Capture.onError));
    try std.testing.expectEqual(@import("../error_codes.zig").Code.arrow_private_dynamic_scope, Capture.code.?);
    const span = Capture.span.?;
    try std.testing.expectEqualStrings("#value", source[span.start..span.end]);
}
