//! function map 수집 통합 테스트.
//! Codegen의 sourcemap_function_map 옵션 활성화 시
//! x_facebook_sources JSON 구조와 contextual name을 검증한다.

const std = @import("std");
const h = @import("helpers.zig");
const Codegen = h.Codegen;
const Scanner = h.Scanner;
const FunctionMapBuilder = @import("../function_map.zig").FunctionMapBuilder;

/// function map 활성화 e2e: x_facebook_sources JSON 반환.
fn e2eFunctionMap(backing_allocator: std.mem.Allocator, source: []const u8) !struct {
    json: []const u8,
    arena: std.heap.ArenaAllocator,
} {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = h.Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();

    var t = try h.Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, &t.ast, .{
        .sourcemap = true,
        .sourcemap_function_map = true,
    });
    cg.line_offsets = scanner.line_offsets.items;
    try cg.addSourceFile("input.ts");
    _ = try cg.generate(root);
    const json = try cg.generateSourceMapWithFunctionMap("output.js") orelse "";
    return .{ .json = json, .arena = arena };
}

test "function_map: function declaration — self name" {
    var r = try e2eFunctionMap(std.testing.allocator, "function foo() {}");
    defer r.arena.deinit();
    // x_facebook_sources 존재
    try std.testing.expect(std.mem.indexOf(u8, r.json, "x_facebook_sources") != null);
    // names에 <global>, foo 존재
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"<global>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"foo\"") != null);
}

test "function_map: arrow function with variable contextual name" {
    var r = try e2eFunctionMap(std.testing.allocator, "const bar = () => {};");
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"bar\"") != null);
}

test "function_map: assignment contextual name — member leaf" {
    var r = try e2eFunctionMap(std.testing.allocator, "obj.render = function() {};");
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"render\"") != null);
}

test "function_map: object property contextual name" {
    var r = try e2eFunctionMap(std.testing.allocator, "const o = { handleClick: () => {} };");
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"handleClick\"") != null);
}

test "function_map: class method — ClassName#method" {
    var r = try e2eFunctionMap(std.testing.allocator, "class MyComp { render() {} }");
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"MyComp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"MyComp#render\"") != null);
}

test "function_map: static method — ClassName.method" {
    var r = try e2eFunctionMap(std.testing.allocator, "class Foo { static create() {} }");
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"Foo.create\"") != null);
}

test "function_map: getter/setter — get__name / set__name" {
    var r = try e2eFunctionMap(std.testing.allocator, "class A { get value() {} set value(v) {} }");
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"A#get__value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"A#set__value\"") != null);
}

test "function_map: export default anonymous function — default" {
    var r = try e2eFunctionMap(std.testing.allocator, "export default function() {}");
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"default\"") != null);
}

test "function_map: string key property" {
    var r = try e2eFunctionMap(std.testing.allocator,
        \\const o = { "onClick": () => {} };
    );
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"onClick\"") != null);
}

test "function_map: computed non-literal key — anonymous" {
    var r = try e2eFunctionMap(std.testing.allocator, "const o = { [expr]: () => {} };");
    defer r.arena.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.json, "\"<anonymous>\"") != null);
}

test "function_map: sourcemap_function_map=false — no x_facebook_sources" {
    // 옵션 비활성화 시 x_facebook_sources 미포함
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, "function foo() {}");
    var parser = h.Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var t = try h.Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();
    var cg = Codegen.initWithOptions(allocator, &t.ast, .{ .sourcemap = true });
    cg.line_offsets = scanner.line_offsets.items;
    try cg.addSourceFile("input.ts");
    _ = try cg.generate(root);
    const json = try cg.generateSourceMap("output.js") orelse "";
    try std.testing.expect(std.mem.indexOf(u8, json, "x_facebook_sources") == null);
}
