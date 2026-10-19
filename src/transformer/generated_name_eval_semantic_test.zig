const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Transformer = @import("transformer.zig").Transformer;
const es_helpers = @import("es_helpers.zig");

test "generated-name eval cache is scoped and reserves decoded names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "function plain() {} function dynamic() { eval(\"typeof Cache_withRef\\\\u0032\"); eval(`typeof ${\"Loop_withRef\" + \"2\"}`); }";

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    try analyzer.analyze();

    var plain_scope: ?ScopeId = null;
    var dynamic_scope: ?ScopeId = null;
    var root_scope: ?ScopeId = null;
    for (analyzer.scopes.items, 0..) |scope, raw| {
        const scope_id: ScopeId = @fromBackingInt(@intCast(@as(u32, @intCast(raw))));
        if (scope.parent.isNone()) root_scope = scope_id;
        if (scope.kind != .function) continue;
        if (scope.subtree_has_direct_eval) {
            dynamic_scope = scope_id;
        } else {
            plain_scope = scope_id;
        }
    }
    const plain = plain_scope orelse return error.TestUnexpectedResult;
    const dynamic = dynamic_scope orelse return error.TestUnexpectedResult;
    const root = root_scope orelse return error.TestUnexpectedResult;
    try std.testing.expect(plain != dynamic);

    // Model the module-wide preferred spelling having been selected before
    // the direct-eval scope asks for its own generated output name.
    const base = "Cache_withRef";
    const cached = "Cache_withRef2";
    analyzer.scopes.items[root.toIndex()].subtree_has_direct_eval = false;
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    transformer.scopes = analyzer.scopes.items;
    try transformer.synthetic_names.put(allocator, try allocator.dupe(u8, base), try allocator.dupe(u8, cached));
    try transformer.synthetic_taken.put(allocator, try allocator.dupe(u8, cached), {});

    const plain_name = try es_helpers.resolveGeneratedNameAvoidingDynamicEval(&transformer, base, plain);
    try std.testing.expectEqualStrings(cached, plain_name);

    const dynamic_name = try es_helpers.resolveGeneratedNameAvoidingDynamicEval(&transformer, base, dynamic);
    try std.testing.expectEqualStrings("Cache_withRef3", dynamic_name);
    try std.testing.expectEqualStrings(cached, transformer.synthetic_names.get(base).?);

    // This name has no module cache entry. Its candidate is assembled by a
    // static template interpolation, so the suffix loop must inspect it too.
    const loop_name = try es_helpers.resolveGeneratedNameAvoidingDynamicEval(&transformer, "Loop_withRef", dynamic);
    try std.testing.expectEqualStrings("Loop_withRef3", loop_name);
}
