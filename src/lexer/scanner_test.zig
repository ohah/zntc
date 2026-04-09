const std = @import("std");
const scanner_mod = @import("scanner.zig");
const Scanner = scanner_mod.Scanner;
const token_mod = @import("token.zig");
const Kind = token_mod.Kind;

test "Scanner: empty source" {
    var scanner = try Scanner.init(std.testing.allocator, "");
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: BOM skip" {
    var scanner = try Scanner.init(std.testing.allocator, "\xEF\xBB\xBF;");
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expectEqual(Kind.semicolon, scanner.token.kind);
    try std.testing.expectEqual(@as(u32, 3), scanner.token.span.start);
}

test "Scanner: single character tokens" {
    const source = "(){};,~@:";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .l_paren,   .r_paren, .l_curly, .r_curly,
        .semicolon, .comma,   .tilde,   .at,
        .colon,
    };
    for (expected) |kind| {
        try scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: compound operators" {
    const source = "++ -- ** === !== => ... ?? ?. ??= &&= ||=";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .plus2,   .minus2,   .star2,     .eq3,          .neq2,
        .arrow,   .dot3,     .question2, .question_dot, .question2_eq,
        .amp2_eq, .pipe2_eq,
    };
    for (expected) |kind| {
        try scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

test "Scanner: shift operators" {
    const source = "<< >> >>> <<= >>= >>>=";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .shift_left,    .shift_right,    .shift_right3,
        .shift_left_eq, .shift_right_eq, .shift_right3_eq,
    };
    for (expected) |kind| {
        try scanner.next();
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

test "Scanner: identifiers and keywords" {
    const source = "const foo let bar";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("foo", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.kw_let, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("bar", scanner.tokenText());
}

test "Scanner: whitespace and newlines set has_newline_before" {
    const source = "a\nb";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expect(!scanner.token.has_newline_before);

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: CRLF counts as one newline" {
    const source = "a\r\nb";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
    try std.testing.expectEqual(@as(u32, 1), scanner.line);
}

test "Scanner: line offset table" {
    const source = "a\nb\nc";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    // 전체를 스캔하여 line offset 테이블 구축
    while (scanner.token.kind != .eof or scanner.start == 0) {
        try scanner.next();
        if (scanner.token.kind == .eof) break;
    }

    // line 0 → offset 0, line 1 → offset 2, line 2 → offset 4
    try std.testing.expectEqual(@as(u32, 0), scanner.line_offsets.items[0]);
    try std.testing.expectEqual(@as(u32, 2), scanner.line_offsets.items[1]);
    try std.testing.expectEqual(@as(u32, 4), scanner.line_offsets.items[2]);
}

test "Scanner: line offsets with TypeScript type declaration" {
    // type 선언이 있는 소스에서 line_offsets가 정확한지 검증 (#954)
    const source =
        \\import React from "react";
        \\
        \\type Props = {
        \\  name: string;
        \\};
        \\
        \\export function App() {}
        \\
    ;
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    while (scanner.token.kind != .eof or scanner.start == 0) {
        try scanner.next();
        if (scanner.token.kind == .eof) break;
    }

    // 줄 수: 8줄 (7 newlines + 마지막 줄)
    // line 0: import React from "react";
    // line 1: (empty)
    // line 2: type Props = {
    // line 3:   name: string;
    // line 4: };
    // line 5: (empty)
    // line 6: export function App() {}
    // line 7: (empty trailing)
    try std.testing.expectEqual(@as(usize, 8), scanner.line_offsets.items.len);
    try std.testing.expectEqual(@as(u32, 0), scanner.line_offsets.items[0]);

    // 'export function'이 있는 줄의 오프셋 확인
    const export_offset = scanner.line_offsets.items[6];
    const src = source;
    // 해당 오프셋에서 'export'가 시작해야 함
    try std.testing.expect(std.mem.startsWith(u8, src[export_offset..], "export function"));
}

test "Scanner: getLineColumn" {
    const source = "ab\ncde\nf";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    // 전체 스캔
    while (true) {
        try scanner.next();
        if (scanner.token.kind == .eof) break;
    }

    // 'a' = offset 0 → line 0, col 0
    const lc0 = scanner.getLineColumn(0);
    try std.testing.expectEqual(@as(u32, 0), lc0.line);
    try std.testing.expectEqual(@as(u32, 0), lc0.column);

    // 'c' = offset 3 → line 1, col 0
    const lc1 = scanner.getLineColumn(3);
    try std.testing.expectEqual(@as(u32, 1), lc1.line);
    try std.testing.expectEqual(@as(u32, 0), lc1.column);

    // 'f' = offset 7 → line 2, col 0
    const lc2 = scanner.getLineColumn(7);
    try std.testing.expectEqual(@as(u32, 2), lc2.line);
    try std.testing.expectEqual(@as(u32, 0), lc2.column);
}

test "Scanner: hashbang" {
    const source = "#!/usr/bin/env node\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.hashbang_comment, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
}

test "Scanner: private identifier" {
    const source = "#name";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.private_identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("#name", scanner.tokenText());
}

test "Scanner: optional chaining vs ternary + number" {
    // ?. → optional chaining
    const source1 = "?.";
    var s1 = try Scanner.init(std.testing.allocator, source1);
    defer s1.deinit();
    try s1.next();
    try std.testing.expectEqual(Kind.question_dot, s1.token.kind);

    // ?.5 → question + .5 (ternary + number)
    const source2 = "?.5";
    var s2 = try Scanner.init(std.testing.allocator, source2);
    defer s2.deinit();
    try s2.next();
    try std.testing.expectEqual(Kind.question, s2.token.kind);
}

test "Scanner: string literal basic" {
    const source = "'hello' \"world\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: empty string literals" {
    const source = "'' \"\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("''", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"\"", scanner.tokenText());
}

test "Scanner: slash_eq operator" {
    // /= 대입 연산자: 식별자 뒤에서만 division context
    const source = "x /= 2";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // x (identifier)
    try scanner.next(); // /=
    try std.testing.expectEqual(Kind.slash_eq, scanner.token.kind);
}

test "Scanner: /=/ regex vs /= divide-assign" {
    // regex 컨텍스트에서 /=/ 는 regex
    const source = "x.replace(/=/g, '')";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // x
    try scanner.next(); // .
    try scanner.next(); // replace
    try scanner.next(); // (
    try scanner.next(); // /=/g
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

test "Scanner: CR alone as line terminator" {
    const source = "a\rb";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
    try std.testing.expectEqual(@as(u32, 1), scanner.line);
}

test "Scanner: whitespace only source" {
    const source = "   \t\t  \n  ";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: NBSP whitespace (U+00A0)" {
    // U+00A0 = C2 A0
    const source = "a\xC2\xA0b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
}

test "Scanner: all assignment operators" {
    // 각 연산자 앞에 식별자를 넣어 division context 보장 (/= 가 regex로 해석되지 않도록)
    const source = "x = x += x -= x *= x /= x %= x **= x &= x |= x ^= x <<= x >>= x >>>= x &&= x ||= x ??= x";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    const expected = [_]Kind{
        .eq,              .plus_eq,    .minus_eq,      .star_eq,
        .slash_eq,        .percent_eq, .star2_eq,      .amp_eq,
        .pipe_eq,         .caret_eq,   .shift_left_eq, .shift_right_eq,
        .shift_right3_eq, .amp2_eq,    .pipe2_eq,      .question2_eq,
    };
    for (expected) |kind| {
        try scanner.next(); // identifier (x)
        try scanner.next(); // operator
        try std.testing.expectEqual(kind, scanner.token.kind);
    }
}

// ============================================================
// Comment tests
// ============================================================

test "Scanner: single-line comment is skipped" {
    const source = "a // comment\nb";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: multi-line comment is skipped" {
    const source = "a /* comment */ b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("a", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("b", scanner.tokenText());
}

test "Scanner: multi-line comment with newline sets has_newline_before" {
    const source = "a /*\n*/ b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try scanner.next(); // b
    try std.testing.expect(scanner.token.has_newline_before);
}

test "Scanner: @__PURE__ comment sets flag" {
    const source = "/* @__PURE__ */ foo()";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("foo", scanner.tokenText());
    try std.testing.expect(scanner.token.has_pure_comment_before);
}

test "Scanner: #__PURE__ comment sets flag" {
    const source = "/* #__PURE__ */ bar()";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(scanner.token.has_pure_comment_before);
}

test "Scanner: @__NO_SIDE_EFFECTS__ comment sets separate flag" {
    const source = "/* @__NO_SIDE_EFFECTS__ */ function f() {}";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.kw_function, scanner.token.kind);
    // @__NO_SIDE_EFFECTS__는 has_pure_comment_before가 아닌 별도 플래그
    try std.testing.expect(!scanner.token.has_pure_comment_before);
    try std.testing.expect(scanner.token.has_no_side_effects_comment);
}

test "Scanner: #__NO_SIDE_EFFECTS__ comment sets separate flag" {
    const source = "/* #__NO_SIDE_EFFECTS__ */ function g() {}";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.kw_function, scanner.token.kind);
    try std.testing.expect(!scanner.token.has_pure_comment_before);
    try std.testing.expect(scanner.token.has_no_side_effects_comment);
}

test "Scanner: @__PURE__ and @__NO_SIDE_EFFECTS__ are independent" {
    // @__PURE__만 있으면 has_pure_comment_before만 true
    const source1 = "/* @__PURE__ */ foo()";
    var s1 = try Scanner.init(std.testing.allocator, source1);
    defer s1.deinit();
    try s1.next();
    try std.testing.expect(s1.token.has_pure_comment_before);
    try std.testing.expect(!s1.token.has_no_side_effects_comment);
}

test "Scanner: both @__PURE__ and @__NO_SIDE_EFFECTS__ in same comment" {
    const source = "/* @__PURE__ @__NO_SIDE_EFFECTS__ */ function f() {}";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.token.has_pure_comment_before);
    try std.testing.expect(scanner.token.has_no_side_effects_comment);
}

test "Scanner: @__NO_SIDE_EFFECTS__ resets on next token" {
    const source = "/* @__NO_SIDE_EFFECTS__ */ function f() {} x";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next(); // function — has flag
    try std.testing.expect(scanner.token.has_no_side_effects_comment);
    try scanner.next(); // f
    try std.testing.expect(!scanner.token.has_no_side_effects_comment);
}

test "Scanner: normal comment does not set pure flag" {
    const source = "/* normal comment */ x";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(!scanner.token.has_pure_comment_before);
}

test "Scanner: single-line comment at end of file" {
    const source = "a // comment";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: comment-only source" {
    const source = "// just a comment";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.eof, scanner.token.kind);
}

test "Scanner: slash after comment is not confused" {
    const source = "a /* */ / b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
    try scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
}

test "Scanner: multi-line legal comment @license" {
    const source = "/* @license MIT */ var x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(scanner.comments.items[0].is_legal);
}

test "Scanner: multi-line legal comment /*!" {
    const source = "/*! Copyright 2024 */ var x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(scanner.comments.items[0].is_legal);
}

test "Scanner: single-line legal comment @license" {
    const source = "// @license MIT\nvar x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(scanner.comments.items[0].is_legal);
}

test "Scanner: single-line legal comment @preserve" {
    const source = "// @preserve\nvar x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(scanner.comments.items[0].is_legal);
}

test "Scanner: normal comment is not legal" {
    const source = "// just a comment\nvar x;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    try scanner.next();
    try std.testing.expect(scanner.comments.items.len > 0);
    try std.testing.expect(!scanner.comments.items[0].is_legal);
}

// ============================================================
// Numeric literal tests
// ============================================================

test "Scanner: decimal integer" {
    const source = "123 0 42";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("123", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("0", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
}

test "Scanner: hex literal" {
    const source = "0xFF 0X1A";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
    try std.testing.expectEqualStrings("0xFF", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
}

test "Scanner: octal literal" {
    const source = "0o77 0O10";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.octal, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.octal, scanner.token.kind);
}

test "Scanner: binary literal" {
    const source = "0b1010 0B11";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
}

test "Scanner: float literal" {
    const source = "1.5 0.1 .5";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try std.testing.expectEqualStrings("1.5", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try std.testing.expectEqualStrings(".5", scanner.tokenText());
}

test "Scanner: exponential literal" {
    const source = "1e10 1E10 1e+10 1e-10";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.negative_exponential, scanner.token.kind);
}

test "Scanner: bigint literal" {
    const source = "123n 0xFFn 0o77n 0b1010n";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.decimal_bigint, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.hex_bigint, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.octal_bigint, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.binary_bigint, scanner.token.kind);
}

test "Scanner: numeric separator" {
    const source = "1_000_000 0xFF_FF 0b1010_0001";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);
    try std.testing.expectEqualStrings("1_000_000", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.hex, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.binary, scanner.token.kind);
}

test "Scanner: 1..toString is float then dot" {
    // 1..toString() → float(1.) dot identifier(toString) — 소수점 뒤 멤버 접근
    const source = "1..toString";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.float, scanner.token.kind);
    try std.testing.expectEqualStrings("1.", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.dot, scanner.token.kind);
    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("toString", scanner.tokenText());
}

test "Scanner: float with exponent" {
    const source = "1.5e10";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.positive_exponential, scanner.token.kind);
    try std.testing.expectEqualStrings("1.5e10", scanner.tokenText());
}

// ============================================================
// String literal tests
// ============================================================

test "Scanner: string with escape sequences" {
    const source = "\"hello\\nworld\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"hello\\nworld\"", scanner.tokenText());
}

test "Scanner: string with hex escape" {
    const source = "'\\x41'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with unicode escape \\uHHHH" {
    const source = "'\\u0041'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with unicode escape \\u{}" {
    const source = "'\\u{1F600}'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with escaped quote" {
    const source = "'it\\'s'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: string with line continuation" {
    // '\' + newline = line continuation (valid)
    const source = "'hello\\\nworld'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

test "Scanner: unterminated string at EOF" {
    const source = "\"hello";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: newline inside string is error" {
    const source = "\"hello\nworld\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: string with backslash at EOF" {
    const source = "'test\\";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

test "Scanner: consecutive strings" {
    const source = "'a' \"b\" 'c'";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("'a'", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("\"b\"", scanner.tokenText());
    try scanner.next();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
}

// ============================================================
// Template literal tests
// ============================================================

test "Scanner: no substitution template" {
    const source = "`hello world`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
    try std.testing.expectEqualStrings("`hello world`", scanner.tokenText());
}

test "Scanner: template with interpolation" {
    // `hello ${name}!`
    const source = "`hello ${name}!`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);
    try std.testing.expectEqualStrings("`hello ${", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("name", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
    try std.testing.expectEqualStrings("}!`", scanner.tokenText());
}

test "Scanner: template with multiple interpolations" {
    // `${a} + ${b} = ${c}`
    const source = "`${a} + ${b} = ${c}`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    try scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // } + ${
    try std.testing.expectEqual(Kind.template_middle, scanner.token.kind);

    try scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // } = ${
    try std.testing.expectEqual(Kind.template_middle, scanner.token.kind);

    try scanner.next(); // c
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // }`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: nested template literals" {
    // `a${`b${c}d`}e`
    const source = "`a${`b${c}d`}e`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // `a${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    try scanner.next(); // `b${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    try scanner.next(); // c
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // }d`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);

    try scanner.next(); // }e`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: template with object literal inside" {
    // `${{a: 1}}`
    const source = "`${{a: 1}}`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // `${
    try std.testing.expectEqual(Kind.template_head, scanner.token.kind);

    try scanner.next(); // {
    try std.testing.expectEqual(Kind.l_curly, scanner.token.kind);

    try scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next(); // :
    try std.testing.expectEqual(Kind.colon, scanner.token.kind);

    try scanner.next(); // 1
    try std.testing.expectEqual(Kind.decimal, scanner.token.kind);

    try scanner.next(); // }
    try std.testing.expectEqual(Kind.r_curly, scanner.token.kind);

    try scanner.next(); // }`
    try std.testing.expectEqual(Kind.template_tail, scanner.token.kind);
}

test "Scanner: empty template" {
    const source = "``";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
}

test "Scanner: template with newline" {
    const source = "`line1\nline2`";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.no_substitution_template, scanner.token.kind);
}

test "Scanner: unterminated template" {
    const source = "`hello";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.syntax_error, scanner.token.kind);
}

// ============================================================
// RegExp literal tests
// ============================================================

test "Scanner: regex after =" {
    // = /pattern/gi → eq, regexp
    const source = "= /abc/gi";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // =
    try std.testing.expectEqual(Kind.eq, scanner.token.kind);
    try scanner.next(); // /abc/gi
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("/abc/gi", scanner.tokenText());
}

test "Scanner: regex after (" {
    const source = "(/test/)";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // (
    try std.testing.expectEqual(Kind.l_paren, scanner.token.kind);
    try scanner.next(); // /test/
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

test "Scanner: division after identifier" {
    // a / b → identifier, slash, identifier
    const source = "a / b";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // a
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
    try scanner.next(); // b
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
}

test "Scanner: division after number" {
    const source = "10 / 2";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // 10
    try scanner.next(); // /
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
}

test "Scanner: regex with character class" {
    // character class 안의 / 는 regex를 끝내지 않음
    const source = "= /[a/b]/";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // =
    try scanner.next(); // /[a/b]/
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
    try std.testing.expectEqualStrings("/[a/b]/", scanner.tokenText());
}

test "Scanner: regex with escape" {
    const source = "= /a\\/b/";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // =
    try scanner.next(); // /a\/b/
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

test "Scanner: regex after return keyword" {
    const source = "return /test/g";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // return
    try std.testing.expectEqual(Kind.kw_return, scanner.token.kind);
    try scanner.next(); // /test/g
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

test "Scanner: regex after comma" {
    const source = ", /re/";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // ,
    try scanner.next(); // /re/
    try std.testing.expectEqual(Kind.regexp_literal, scanner.token.kind);
}

// ============================================================
// Unicode identifier tests
// ============================================================

test "Scanner: unicode identifier (Latin)" {
    // café = UTF-8: 63 61 66 C3 A9
    const source = "caf\xC3\xA9";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("caf\xC3\xA9", scanner.tokenText());
}

test "Scanner: unicode identifier (CJK)" {
    // 변수 = UTF-8: EB B3 80 EC 88 98
    const source = "\xEB\xB3\x80\xEC\x88\x98";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
}

test "Scanner: unicode identifier (Greek)" {
    // α = UTF-8: CE B1
    const source = "\xCE\xB1 = 1";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("\xCE\xB1", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.eq, scanner.token.kind);
}

test "Scanner: mixed ASCII and unicode in identifier" {
    // test변수 = ASCII + CJK
    const source = "test\xEB\xB3\x80\xEC\x88\x98";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("test\xEB\xB3\x80\xEC\x88\x98", scanner.tokenText());
}

// ============================================================
// JSX mode tests
// ============================================================

test "Scanner: JSX element identifier with hyphen" {
    const source = "data-testid";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextInsideJSXElement();
    try std.testing.expectEqual(Kind.jsx_identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("data-testid", scanner.tokenText());
}

test "Scanner: JSX element tokens" {
    // <div className="hello">
    const source = "div className=\"hello\">";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextInsideJSXElement(); // div
    try std.testing.expectEqual(Kind.jsx_identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("div", scanner.tokenText());

    try scanner.nextInsideJSXElement(); // className
    try std.testing.expectEqual(Kind.jsx_identifier, scanner.token.kind);

    try scanner.nextInsideJSXElement(); // =
    try std.testing.expectEqual(Kind.eq, scanner.token.kind);

    try scanner.nextInsideJSXElement(); // "hello"
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);

    try scanner.nextInsideJSXElement(); // >
    try std.testing.expectEqual(Kind.r_angle, scanner.token.kind);
}

test "Scanner: JSX text content" {
    const source = "Hello World<";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextJSXChild(); // "Hello World"
    try std.testing.expectEqual(Kind.jsx_text, scanner.token.kind);
    try std.testing.expectEqualStrings("Hello World", scanner.tokenText());

    try scanner.nextJSXChild(); // <
    try std.testing.expectEqual(Kind.l_angle, scanner.token.kind);
}

test "Scanner: JSX text with expression" {
    const source = "text{expr}more";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextJSXChild(); // "text"
    try std.testing.expectEqual(Kind.jsx_text, scanner.token.kind);
    try std.testing.expectEqualStrings("text", scanner.tokenText());

    try scanner.nextJSXChild(); // {
    try std.testing.expectEqual(Kind.l_curly, scanner.token.kind);
}

test "Scanner: JSX self-closing tag" {
    const source = "/>";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextInsideJSXElement();
    try std.testing.expectEqual(Kind.slash, scanner.token.kind);
    // 파서가 slash + r_angle을 자체 닫힘 태그로 조합
}

test "Scanner: JSX string without escape" {
    // JSX 속성 문자열은 이스케이프를 처리하지 않음
    const source = "\"hello\\nworld\"";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.nextInsideJSXElement();
    try std.testing.expectEqual(Kind.string_literal, scanner.token.kind);
    // 전체 텍스트가 토큰에 포함됨 (이스케이프 안 함)
    try std.testing.expectEqualStrings("\"hello\\nworld\"", scanner.tokenText());
}

// ============================================================
// JSX pragma tests (D026)
// ============================================================

test "Scanner: @jsx pragma in single-line comment" {
    const source = "// @jsx h\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // const (comment is skipped)
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
    try std.testing.expectEqualStrings("h", scanner.jsx_pragma.?);
}

test "Scanner: @jsx pragma in multi-line comment" {
    const source = "/** @jsx h */\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqualStrings("h", scanner.jsx_pragma.?);
}

test "Scanner: @jsxFrag pragma" {
    const source = "/** @jsxFrag Fragment */";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // eof (comment only)
    try std.testing.expectEqualStrings("Fragment", scanner.jsx_frag_pragma.?);
}

test "Scanner: @jsxRuntime pragma" {
    const source = "// @jsxRuntime automatic";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqualStrings("automatic", scanner.jsx_runtime_pragma.?);
}

test "Scanner: @jsxImportSource pragma" {
    const source = "/** @jsxImportSource preact */";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqualStrings("preact", scanner.jsx_import_source_pragma.?);
}

test "Scanner: multiple pragmas in one file" {
    const source = "/** @jsx h */\n// @jsxFrag Fragment\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    // 전체 스캔
    while (true) {
        try scanner.next();
        if (scanner.token.kind == .eof) break;
    }

    try std.testing.expectEqualStrings("h", scanner.jsx_pragma.?);
    try std.testing.expectEqualStrings("Fragment", scanner.jsx_frag_pragma.?);
}

test "Scanner: no pragma in normal comment" {
    const source = "/* just a comment */ x";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(scanner.jsx_pragma == null);
    try std.testing.expect(scanner.jsx_frag_pragma == null);
}

// ================================================================
// @flow pragma 감지 테스트
// ================================================================

test "Scanner: @flow pragma in single-line comment" {
    const source = "// @flow\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.kw_const, scanner.token.kind);
    try std.testing.expect(scanner.has_flow_pragma);
}

test "Scanner: @flow pragma in multi-line comment" {
    const source = "/* @flow */\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(scanner.has_flow_pragma);
}

test "Scanner: @flow strict pragma" {
    const source = "// @flow strict\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(scanner.has_flow_pragma);
}

test "Scanner: @flow in doc comment" {
    const source = "/**\n * @flow\n */\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(scanner.has_flow_pragma);
}

test "Scanner: @flowtype is not @flow pragma" {
    const source = "// @flowtype something\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(!scanner.has_flow_pragma);
}

test "Scanner: no @flow pragma in normal comment" {
    const source = "/* just a comment */ const x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(!scanner.has_flow_pragma);
}

test "Scanner: @flow at EOF without newline" {
    const source = "// @flow";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // eof
    try std.testing.expect(scanner.has_flow_pragma);
}

test "Scanner: @flow in middle of comment is not pragma" {
    const source = "// This enables @flow support\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(!scanner.has_flow_pragma);
}

test "Scanner: @noflow does not trigger @flow pragma" {
    const source = "// @noflow\nconst x = 1;";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expect(!scanner.has_flow_pragma);
}

// ============================================================
// Annex B: HTML-like comment tests
// ============================================================

test "Scanner: <!-- is single-line comment in non-module mode" {
    const source = "x <!-- this is a comment\ny";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    // is_module defaults to false (non-module/script mode)

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("x", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("y", scanner.tokenText());
}

test "Scanner: <!-- is NOT a comment in module mode" {
    const source = "x <!-- y";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    scanner.is_module = true;

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);

    try scanner.next();
    // module mode에서는 < ! -- 로 파싱됨
    try std.testing.expectEqual(Kind.l_angle, scanner.token.kind);
}

test "Scanner: --> at line start is single-line comment in non-module mode" {
    const source = "x\n--> this is a comment\ny";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("x", scanner.tokenText());

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("y", scanner.tokenText());
}

test "Scanner: --> mid-line is NOT a comment (decrement + greater)" {
    const source = "x --> y";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind); // x

    try scanner.next();
    try std.testing.expectEqual(Kind.minus2, scanner.token.kind); // --

    try scanner.next();
    try std.testing.expectEqual(Kind.r_angle, scanner.token.kind); // >

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind); // y
}

test "Scanner: --> is NOT a comment in module mode" {
    const source = "x\n--> y";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    scanner.is_module = true;

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind); // x

    try scanner.next();
    try std.testing.expectEqual(Kind.minus2, scanner.token.kind); // --

    try scanner.next();
    try std.testing.expectEqual(Kind.r_angle, scanner.token.kind); // >
}

test "Scanner: --> after multiline comment with newline is a comment" {
    const source = "x\n/* comment */ --> this is skipped\ny";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind); // x

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind); // y
    try std.testing.expectEqualStrings("y", scanner.tokenText());
}

test "Scanner: <!-- at start of file is a comment" {
    const source = "<!-- comment\nx";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next();
    try std.testing.expectEqual(Kind.identifier, scanner.token.kind);
    try std.testing.expectEqualStrings("x", scanner.tokenText());
}

test "Scanner: <!-- comment is recorded in comments list" {
    const source = "<!-- a comment\nx";
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();

    try scanner.next(); // skips <!-- comment, returns x
    try std.testing.expectEqual(@as(usize, 1), scanner.comments.items.len);
    try std.testing.expect(!scanner.comments.items[0].is_multiline);
}
