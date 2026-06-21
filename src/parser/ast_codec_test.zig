// ast_codec_test.zig — #4438 PR1 AST 직렬화 round-trip + fail-safe 테스트.

const std = @import("std");
const testing = std.testing;
const codec = @import("ast_codec.zig");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const Ast = ast_mod.Ast;
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

// #4438 회귀 가드: 직렬화는 의미 필드만 같으면 byte-identical 이어야 한다(결정성). 통째
// memcpy 는 struct 꼬리 padding(`tag` 뒤)과 `Data` union 의 active variant 밖 꼬리 바이트가
// 미초기화라 같은 의미도 byte 가 달라졌다(ubuntu/Debug 의 poison → cache_key.차등 fail).
// 두 Ast 의 노드 raw 메모리를 정반대 poison(0xAA/0x55)으로 채우고 의미 필드만 동일하게
// 세팅 → 직렬화 byte 가 같아야 통과. memcpy 회귀 시 이 테스트가 결정적으로 잡는다.
test "ast_codec: 노드 padding/union 꼬리 poison 이 직렬화에 새지 않는다 (#4438 결정성)" {
    const alloc = testing.allocator;

    const build = struct {
        fn f(a: std.mem.Allocator, poison: u8) !Ast {
            var ast = Ast.init(a, "const x = 1;");
            errdefer ast.deinit();
            // 각 노드: raw 를 poison 으로 덮고 의미 필드만 세팅. variant 폭이 12 미만이라
            // 꼬리(>width)가 poison 으로 남는다 — 직렬화가 이를 제외해야 결정적.
            var n0: Node = undefined; // wide leaf, string_ref(8) — 꼬리 4B
            @memset(std.mem.asBytes(&n0), poison);
            n0.tag = .string_literal;
            n0.span = .{ .start = 6, .end = 7 };
            n0.data = .{ .string_ref = .{ .start = 6, .end = 11 } };
            try ast.nodes.append(a, n0);

            var n1: Node = undefined; // leaf, string_ref(8) — 꼬리 4B + tag padding
            @memset(std.mem.asBytes(&n1), poison ^ 0xFF);
            n1.tag = .identifier_reference;
            n1.span = .{ .start = 0, .end = 1 };
            n1.data = .{ .string_ref = .{ .start = 6, .end = 7 } };
            try ast.nodes.append(a, n1);

            var n2: Node = undefined; // unary(8) — operand+flags+_pad, 꼬리 4B
            @memset(std.mem.asBytes(&n2), poison);
            n2.tag = .return_statement;
            n2.span = .{ .start = 0, .end = 1 };
            n2.data = .{ .unary = .{ .operand = @enumFromInt(0), .flags = 3 } };
            try ast.nodes.append(a, n2);

            var n3: Node = undefined; // extra(4) — u32 인덱스, 꼬리 8B
            @memset(std.mem.asBytes(&n3), poison);
            n3.tag = .call_expression;
            n3.span = .{ .start = 0, .end = 1 };
            n3.data = .{ .extra = 0 };
            try ast.nodes.append(a, n3);

            // #4438 none-leaf 회귀: `.none` active leaf(boolean_literal, none-only → 직렬화 폭 4).
            // raw 를 poison 으로 덮고 `.none = 0` 만 세팅 → union 꼬리 [4..12] 가 poison 으로 남는다.
            // dataWidth(.boolean_literal)=4 라 [0..4](=0)만 직렬화하고 poison 꼬리는 제외해야 결정적.
            // 수정 전(폭 8)이면 두 poison fill 의 [4..8] 이 stream 에 새어 byte 가 달라진다.
            var n4: Node = undefined;
            @memset(std.mem.asBytes(&n4), poison);
            n4.tag = .boolean_literal;
            n4.span = .{ .start = 0, .end = 4 };
            n4.data = .{ .none = 0 }; // aggregate literal — 꼬리 미초기화(=직전 poison memset 잔존)
            try ast.nodes.append(a, n4);

            // wide-leaf 의 `.none`(ts_literal_type, 직렬화 폭 8): noneLeaf 가 꼬리를 0 으로 박으므로
            // raw 를 poison 으로 덮어도 [4..8] 이 0 → 결정적. (값 리터럴 string_ref 경로의 8B 보존을
            // 위해 폭은 8 이어야 하고, .none 의 꼬리 결정성은 noneLeaf 가 책임진다.)
            var n5: Node = undefined;
            @memset(std.mem.asBytes(&n5), poison);
            n5.tag = .ts_literal_type;
            n5.span = .{ .start = 0, .end = 4 };
            n5.data = Node.Data.noneLeaf(0);
            try ast.nodes.append(a, n5);
            return ast;
        }
    }.f;

    var a1 = try build(alloc, 0xAA);
    defer a1.deinit();
    var a2 = try build(alloc, 0x55);
    defer a2.deinit();

    var b1: std.ArrayList(u8) = .empty;
    defer b1.deinit(alloc);
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(alloc);
    try codec.serialize(&a1, &b1, alloc);
    try codec.serialize(&a2, &b2, alloc);

    // 정반대 poison 인데 직렬화 byte 가 동일 → padding/union 꼬리가 stream 에 안 샘.
    try testing.expectEqualSlices(u8, b1.items, b2.items);

    // round-trip 으로 의미 복원 검증.
    var rt = try codec.deserialize(b1.items, alloc);
    defer {
        alloc.free(rt.source);
        rt.deinit();
    }
    try testing.expectEqual(@as(usize, 6), rt.nodes.items.len);
    // wide leaf string_ref(8B) 가 온전히 복원(폭 4 로 좁히면 end 가 손실).
    try testing.expectEqual(Node.Tag.string_literal, rt.nodes.items[0].tag);
    try testing.expectEqual(@as(u32, 6), rt.nodes.items[0].data.string_ref.start);
    try testing.expectEqual(@as(u32, 11), rt.nodes.items[0].data.string_ref.end);
    try testing.expectEqual(@as(u16, 3), rt.nodes.items[2].data.unary.flags);
    // none-leaf 복원: boolean_literal 의 `.none` 은 0, ts_literal_type(wide).none 도 0.
    try testing.expectEqual(Node.Tag.boolean_literal, rt.nodes.items[4].tag);
    try testing.expectEqual(@as(u32, 0), rt.nodes.items[4].data.none);
    try testing.expectEqual(Node.Tag.ts_literal_type, rt.nodes.items[5].tag);
    try testing.expectEqual(@as(u32, 0), rt.nodes.items[5].data.none);
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
