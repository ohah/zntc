//! 심볼 기준 블록 스코핑 표(`block_rename_table.zig`)의 규칙별 판정 (#4760 4단계).

const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Ast = @import("../parser/ast.zig").Ast;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const table_mod = @import("block_rename_table.zig");

/// 표가 바꾸기로 한 심볼들의 이름(선언 순서)을 쉼표로 이어 돌려준다.
fn renamedNames(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    const Ctx = struct {
        fn nameOf(ctx: *const anyopaque, sym: Symbol) []const u8 {
            const ast: *const Ast = @ptrCast(@alignCast(ctx));
            return ast.getText(sym.name);
        }
    };
    var table = try table_mod.build(allocator, .{
        .scopes = analyzer.scopes.items,
        .symbols = analyzer.symbols.items,
        .scope_maps = analyzer.scope_maps.items,
        .references = analyzer.references.items,
        .unresolved = &analyzer.unresolved_references,
        .ctx = &parser.ast,
        .nameOf = Ctx.nameOf,
    });
    defer table.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    for (analyzer.symbols.items, 0..) |sym, i| {
        if (!table.contains(@intCast(i))) continue;
        if (out.items.len > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, parser.ast.getText(sym.name));
    }
    return out.items;
}

fn expectRenamed(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(expected, try renamedNames(arena.allocator(), source));
}

test "(1) 매개변수와 같은 이름의 블록 바인딩은 바꾼다 — var 가 되면 매개변수를 덮는다" {
    try expectRenamed("export function f(key) { for (const key of [1]) g(key); return key; }", "key");
}

test "(1) 블록과 함수 사이 catch 파라미터와 같은 이름도 바꾼다" {
    try expectRenamed("export function f() { try { g(); } catch (x) { { let x = 1; g(x); } g(x); } }", "x");
}

test "(1) 함수 본문 최상위 let 과 같은 이름의 블록 바인딩은 바꾼다" {
    try expectRenamed("export function f() { let v = 1; { let v = 2; g(v); } return v; }", "v");
}

test "함수 본문 최상위 let/const 는 대상이 아니다 — var 가 되어도 같은 함수 스코프다" {
    try expectRenamed("const s = 1; export function f() { const s = 2; return s; }", "");
}

test "(2) 형제 루프의 같은 이름은 클로저에 안 잡히면 한 var 로 합친다" {
    try expectRenamed("export function f(a) { for (let i = 0; i < a; i++) g(i); for (let i = 0; i < a; i++) g(i); }", "");
}

test "(2) 형제 블록의 같은 이름은 한쪽이 클로저에 잡히면 바꾼다" {
    try expectRenamed("export function f(fns) { { let x = 1; fns.push(() => x); } { let x = 2; g(x); } }", "x");
}

test "(3) 함수 안에서 바깥 같은 이름을 참조하면 바꾼다 — var 가 그 참조를 가로챈다" {
    try expectRenamed("let n = 0; export function f() { { let n = 1; g(n); } return n; }", "n");
}

test "(3) 바깥 같은 이름을 참조하지 않으면 바꾸지 않는다" {
    try expectRenamed("let n = 0; export function f() { { let n = 1; g(n); } } g(n);", "");
}

test "(4) 같은 이름의 전역을 참조하면 바꾼다 (#4764 switch)" {
    try expectRenamed("export function f(k) { switch (k) { case 0: let value = 1; g(value); } return value; }", "value");
}

test "direct eval 을 품은 블록의 바인딩은 바꾸지 않는다 — eval 은 이름 문자열로 찾는다" {
    try expectRenamed("export function f() { var x = 'v'; { let x = 'b'; return eval('x'); } }", "");
}
