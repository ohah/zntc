// ast_codec_test.zig — #4438 PR1 AST 직렬화 round-trip + fail-safe 테스트.

const std = @import("std");
const testing = std.testing;
const codec = @import("ast_codec.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("parser.zig").Parser;
const Codegen = @import("../codegen/codegen.zig").Codegen;

test "ast_codec: serialize→deserialize round-trip == codegen byte-identical" {
    const alloc = testing.allocator;
    const cases = [_][]const u8{
        "const x = 1 + 2; let y = x * 3; const z = y - x;",
        "function add(a, b) { return a + b; } const r = add(1, 2);",
        "const obj = { a: 1, b: [2, 3], c: { d: 'hi' } }; const { a, ...rest } = obj;",
        "class C { p = 1; method(n) { return this.p + n; } } const c = new C();",
        "async function f() { for (const x of [1, 2, 3]) { await g(x); } }",
        "const ts: number = 1; let s: string = 'x'; interface I { a: number }",
        "export const list = [1, 2, 3].map((n) => n * 2).filter((n) => n > 2);",
        "declare const ext: number; const used = ext + 1;",
        "const tpl = `a${x}b${y}c`; const re = /ab+c/gi; const big = 100_000n;",
        "try { f(); } catch (e) { g(e); } finally { h(); } switch (x) { case 1: break; default: }",
    };
    for (cases, 0..) |source, i| {
        errdefer std.debug.print("FAILED case [{d}]: {s}\n", .{ i, source });

        var scanner = try Scanner.init(alloc, source);
        defer scanner.deinit();
        var parser = Parser.init(alloc, &scanner);
        defer parser.deinit();
        const root = try parser.parse();

        var cg1 = Codegen.init(alloc, &parser.ast);
        defer cg1.deinit();
        const out1 = try cg1.generate(root);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try codec.serialize(&parser.ast, &buf, alloc);

        var ast2 = try codec.deserialize(buf.items, alloc);
        defer {
            alloc.free(ast2.source);
            ast2.deinit();
        }

        var cg2 = Codegen.init(alloc, &ast2);
        defer cg2.deinit();
        const out2 = try cg2.generate(root);

        try testing.expectEqualStrings(out1, out2);
    }
}

test "ast_codec: 변조/버전/매직/truncated 거부 (fail-safe)" {
    const alloc = testing.allocator;
    const source = "const x = 1 + 2; function f() { return x; }";

    var scanner = try Scanner.init(alloc, source);
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&parser.ast, &buf, alloc);

    // 정상 경로는 성공
    {
        var ast2 = try codec.deserialize(buf.items, alloc);
        alloc.free(ast2.source);
        ast2.deinit();
    }
    // bad magic
    {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[0] ^= 0xFF;
        try testing.expectError(error.BadMagic, codec.deserialize(dup, alloc));
    }
    // unsupported version
    {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[4] = 0xEE;
        try testing.expectError(error.UnsupportedVersion, codec.deserialize(dup, alloc));
    }
    // checksum mismatch (payload 변조)
    {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[dup.len - 1] ^= 0xFF;
        try testing.expectError(error.ChecksumMismatch, codec.deserialize(dup, alloc));
    }
    // truncated (header 미만)
    {
        try testing.expectError(error.Truncated, codec.deserialize(buf.items[0..8], alloc));
    }
}

test "ast_codec: declare_only_names + jsx_pragma round-trip 보존" {
    const alloc = testing.allocator;
    const source =
        "/** @jsx h @jsxFrag Frag */\n" ++
        "declare const X: number;\n" ++
        "export { X };\n" ++
        "const y = 1;\n";

    var scanner = try Scanner.init(alloc, source);
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    _ = try parser.parse();

    // 이 소스가 실제로 두 필드를 채워야 검증이 의미있다 (안 채우면 trivially-pass 갭).
    try testing.expect(parser.ast.declare_only_names.count() > 0);
    try testing.expect(parser.ast.jsx_pragma_factory != null);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&parser.ast, &buf, alloc);

    var ast2 = try codec.deserialize(buf.items, alloc);
    defer {
        alloc.free(ast2.source);
        ast2.deinit();
    }

    // declare_only_names 보존 (transpile.zig type-only export 판정의 입력)
    try testing.expectEqual(parser.ast.declare_only_names.count(), ast2.declare_only_names.count());
    try testing.expect(ast2.declare_only_names.contains("X"));

    // jsx_pragma 보존 (source offset 재설정 path 검증)
    try testing.expectEqualStrings(parser.ast.jsx_pragma_factory.?, ast2.jsx_pragma_factory.?);
    if (parser.ast.jsx_pragma_fragment) |fr| {
        try testing.expectEqualStrings(fr, ast2.jsx_pragma_fragment.?);
    }
}
