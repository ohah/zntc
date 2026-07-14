//! PreambleWriter 유닛 테스트.
//!
//! CJS interop preamble 은 **텍스트로** JS 를 만들기 때문에 멤버명이 식별자가 아닐 때
//! (`import { 'foo-bar' as x }`, ES2022 arbitrary module namespace name) 조용히 문법 오류를
//! 낸다 — 빌드는 성공하고 실행만 죽는다(#4510). 그래서 emit 형태를 여기서 못박는다.

const std = @import("std");
const pw = @import("preamble_writer.zig");
const PreambleWriter = pw.PreambleWriter;

test "isPlainMemberName / isQuotedName (#4510)" {
    try std.testing.expect(pw.isPlainMemberName("foo"));
    try std.testing.expect(pw.isPlainMemberName("_$a1"));
    try std.testing.expect(pw.isPlainMemberName("default")); // 예약어도 멤버 위치에선 유효
    try std.testing.expect(!pw.isPlainMemberName("1abc")); // 숫자 시작
    try std.testing.expect(!pw.isPlainMemberName("foo-bar"));
    try std.testing.expect(!pw.isPlainMemberName(""));

    // binding_scanner 는 문자열 module-export-name 을 **따옴표째** 담아 둔다.
    try std.testing.expect(pw.isQuotedName("\"foo-bar\""));
    try std.testing.expect(pw.isQuotedName("'foo-bar'"));
    try std.testing.expect(!pw.isQuotedName("foo"));
    try std.testing.expect(!pw.isQuotedName("\"unterminated"));
}

test "allocMemberAccess: 식별자는 점, 그 외는 computed (#4510)" {
    const alloc = std.testing.allocator;

    const dot = try pw.allocMemberAccess(alloc, "tag");
    defer alloc.free(dot);
    try std.testing.expectEqualStrings(".tag", dot);

    // 따옴표 포함 원문은 그대로 computed 키로 쓴다(이미 유효한 문자열 리터럴).
    const computed = try pw.allocMemberAccess(alloc, "\"foo-bar\"");
    defer alloc.free(computed);
    try std.testing.expectEqualStrings("[\"foo-bar\"]", computed);

    const single = try pw.allocMemberAccess(alloc, "'a b'");
    defer alloc.free(single);
    try std.testing.expectEqualStrings("['a b']", single);

    // 따옴표 없는 비-식별자(방어적 경로) → quote 해서 emit.
    const raw = try pw.allocMemberAccess(alloc, "foo-bar");
    defer alloc.free(raw);
    try std.testing.expectEqualStrings("[\"foo-bar\"]", raw);
}

test "writeCjsImport: named 멤버명이 비-식별자면 computed 접근 (#4510)" {
    const alloc = std.testing.allocator;
    var w = PreambleWriter.init(alloc);
    defer w.deinit();

    try w.writeCjsImport("x", "\"foo-bar\"", "require_x", false, .babel);
    try std.testing.expectEqualStrings("var x = require_x()[\"foo-bar\"];\n", w.buf.items);
}

test "writeCjsImport: 평범한 named/namespace 는 기존 형태 유지 (#4510 회귀 가드)" {
    const alloc = std.testing.allocator;

    {
        var w = PreambleWriter.init(alloc);
        defer w.deinit();
        try w.writeCjsImport("v", "named", "require_x", false, .babel);
        try std.testing.expectEqualStrings("var v = require_x().named;\n", w.buf.items);
    }
    {
        var w = PreambleWriter.init(alloc);
        defer w.deinit();
        try w.writeCjsImport("ns", "*", "require_x", true, .node);
        try std.testing.expectEqualStrings("var ns = __toESM(require_x(), 1);\n", w.buf.items);
    }
}

test "writeUnresolvedRequire: external CJS 의 비-식별자 멤버명 (#4510)" {
    const alloc = std.testing.allocator;
    var w = PreambleWriter.init(alloc);
    defer w.deinit();

    try w.writeUnresolvedRequire("x", "pkg", "\"foo-bar\"", false);
    try std.testing.expectEqualStrings("var x = require(\"pkg\")[\"foo-bar\"];\n", w.buf.items);
}

test "writeDevRequireNamed: 비-식별자 멤버명은 destructuring 키를 quote (#4510)" {
    const alloc = std.testing.allocator;
    var w = PreambleWriter.init(alloc);
    defer w.deinit();

    try w.writeDevRequireNamed(&.{
        .{ .local = "ok", .imported = "ok" },
        .{ .local = "x", .imported = "\"foo-bar\"" },
    }, "./x.cjs");
    try std.testing.expectEqualStrings(
        "var { ok, \"foo-bar\": x } = __zntc_require(\"./x.cjs\");\n",
        w.buf.items,
    );
}
