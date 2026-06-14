const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Transformer = @import("../transformer/transformer.zig").Transformer;
const Codegen = @import("codegen.zig").Codegen;
const manglePrivateFields = @import("private_mangler.zig").manglePrivateFields;

fn mangleAndGen(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var t = try Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();
    manglePrivateFields(t.ast);
    var cg = Codegen.initWithOptions(allocator, t.ast, .{ .minify_whitespace = true });
    return try cg.generate(root);
}

test "private mangle: generated 이름이 생존 원본과 충돌 안 함 (#4283)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `#zzzzz` 는 `#a` 로 줄지만 원본 `#a` 가 생존 → reserved 라 `#b` 로 배정.
    // 버그 땐 `#zzzzz`→`#a` + 원본 `#a` 가 둘 다 `#a` (중복 private = SyntaxError).
    const out = try mangleAndGen(a,
        \\class C { #zzzzz = 1; #a = 2; m() { return this.#zzzzz + this.#a; } }
    );
    try std.testing.expectEqualStrings("class C{#b=1;#a=2;m(){return this.#b+this.#a;}}", out);
}
