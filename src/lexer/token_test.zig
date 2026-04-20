const std = @import("std");
const token_mod = @import("token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Token = token_mod.Token;
const keywords = token_mod.keywords;

test "Kind fits in u8" {
    const fields = @typeInfo(Kind).@"enum".fields;
    try std.testing.expect(fields.len <= 256);
}

test "Kind.isReservedKeyword" {
    // 범위 내
    try std.testing.expect(Kind.kw_await.isReservedKeyword());
    try std.testing.expect(Kind.kw_break.isReservedKeyword());
    try std.testing.expect(Kind.kw_with.isReservedKeyword());
    // 범위 밖 (경계값)
    try std.testing.expect(!Kind.escaped_keyword.isReservedKeyword()); // kw_await 직전
    try std.testing.expect(!Kind.kw_async.isReservedKeyword()); // kw_with 직후
    try std.testing.expect(!Kind.identifier.isReservedKeyword());
    try std.testing.expect(!Kind.l_paren.isReservedKeyword());
}

test "Kind.isStrictModeReserved" {
    try std.testing.expect(Kind.kw_implements.isStrictModeReserved());
    try std.testing.expect(Kind.kw_yield.isStrictModeReserved());
    try std.testing.expect(Kind.kw_public.isStrictModeReserved());
    // 경계값
    try std.testing.expect(Kind.kw_let.isStrictModeReserved()); // ECMAScript 12.1.1: let은 strict mode reserved
    try std.testing.expect(Kind.kw_static.isStrictModeReserved()); // ECMAScript 12.1.1: static도 strict mode reserved
    try std.testing.expect(!Kind.kw_true.isStrictModeReserved()); // kw_yield 직후
}

test "Kind.isKeyword covers all keyword ranges" {
    try std.testing.expect(Kind.kw_await.isKeyword());
    try std.testing.expect(Kind.kw_with.isKeyword());
    try std.testing.expect(Kind.kw_async.isKeyword());
    try std.testing.expect(Kind.kw_yield.isKeyword());
    try std.testing.expect(Kind.kw_true.isKeyword());
    try std.testing.expect(Kind.kw_null.isKeyword());
    // 경계값
    try std.testing.expect(!Kind.escaped_keyword.isKeyword()); // kw_await 직전
    try std.testing.expect(!Kind.l_paren.isKeyword()); // kw_null 직후
    try std.testing.expect(!Kind.identifier.isKeyword());
    try std.testing.expect(!Kind.plus.isKeyword());
}

test "Kind.isLiteralKeyword" {
    try std.testing.expect(Kind.kw_true.isLiteralKeyword());
    try std.testing.expect(Kind.kw_false.isLiteralKeyword());
    try std.testing.expect(Kind.kw_null.isLiteralKeyword());
    try std.testing.expect(!Kind.kw_yield.isLiteralKeyword()); // 직전
    try std.testing.expect(!Kind.l_paren.isLiteralKeyword()); // 직후
}

test "Kind.isNumericLiteral" {
    try std.testing.expect(Kind.decimal.isNumericLiteral());
    try std.testing.expect(Kind.hex.isNumericLiteral());
    try std.testing.expect(Kind.hex_bigint.isNumericLiteral());
    try std.testing.expect(Kind.float.isNumericLiteral());
    try std.testing.expect(!Kind.string_literal.isNumericLiteral());
    try std.testing.expect(!Kind.identifier.isNumericLiteral());
    try std.testing.expect(!Kind.at.isNumericLiteral()); // decimal 직전
}

test "Kind.isBigIntLiteral" {
    try std.testing.expect(Kind.decimal_bigint.isBigIntLiteral());
    try std.testing.expect(Kind.hex_bigint.isBigIntLiteral());
    try std.testing.expect(!Kind.decimal.isBigIntLiteral());
    try std.testing.expect(!Kind.float.isBigIntLiteral());
}

test "Kind.isTemplateLiteral" {
    try std.testing.expect(Kind.no_substitution_template.isTemplateLiteral());
    try std.testing.expect(Kind.template_head.isTemplateLiteral());
    try std.testing.expect(Kind.template_middle.isTemplateLiteral());
    try std.testing.expect(Kind.template_tail.isTemplateLiteral());
    try std.testing.expect(!Kind.string_literal.isTemplateLiteral());
    try std.testing.expect(!Kind.regexp_literal.isTemplateLiteral()); // 직전
    try std.testing.expect(!Kind.jsx_text.isTemplateLiteral()); // 직후
}

test "Kind.isAssignment" {
    try std.testing.expect(Kind.eq.isAssignment());
    try std.testing.expect(Kind.plus_eq.isAssignment());
    try std.testing.expect(Kind.question2_eq.isAssignment());
    try std.testing.expect(!Kind.plus.isAssignment());
    try std.testing.expect(!Kind.eq2.isAssignment());
}

test "Kind.isCompoundAssignment" {
    try std.testing.expect(!Kind.eq.isCompoundAssignment());
    try std.testing.expect(Kind.plus_eq.isCompoundAssignment());
    try std.testing.expect(Kind.question2_eq.isCompoundAssignment());
    try std.testing.expect(!Kind.plus.isCompoundAssignment());
    try std.testing.expect(!Kind.eq2.isCompoundAssignment());
}

test "Kind.slashIsRegex" {
    // 식별자/리터럴 뒤 → division (false)
    try std.testing.expect(!Kind.identifier.slashIsRegex());
    try std.testing.expect(!Kind.decimal.slashIsRegex());
    try std.testing.expect(!Kind.hex_bigint.slashIsRegex());
    try std.testing.expect(!Kind.string_literal.slashIsRegex());
    try std.testing.expect(!Kind.r_paren.slashIsRegex());
    try std.testing.expect(!Kind.r_bracket.slashIsRegex());
    try std.testing.expect(!Kind.kw_this.slashIsRegex());
    try std.testing.expect(!Kind.kw_true.slashIsRegex());
    try std.testing.expect(!Kind.kw_false.slashIsRegex());
    try std.testing.expect(!Kind.kw_null.slashIsRegex());
    try std.testing.expect(!Kind.kw_super.slashIsRegex());
    try std.testing.expect(!Kind.plus2.slashIsRegex());
    try std.testing.expect(!Kind.minus2.slashIsRegex());
    try std.testing.expect(!Kind.template_tail.slashIsRegex());

    // 연산자/키워드 뒤 → regex (true)
    try std.testing.expect(Kind.eq.slashIsRegex());
    try std.testing.expect(Kind.l_paren.slashIsRegex());
    try std.testing.expect(Kind.semicolon.slashIsRegex());
    try std.testing.expect(Kind.kw_return.slashIsRegex());
    try std.testing.expect(Kind.kw_typeof.slashIsRegex());
    try std.testing.expect(Kind.kw_void.slashIsRegex());
    try std.testing.expect(Kind.kw_delete.slashIsRegex());
    try std.testing.expect(Kind.comma.slashIsRegex());
    try std.testing.expect(Kind.eof.slashIsRegex());
    // r_curly → regex (파서가 오버라이드 필요)
    try std.testing.expect(Kind.r_curly.slashIsRegex());
}

test "Kind.symbol returns readable name for punctuators" {
    try std.testing.expectEqualStrings("(", Kind.l_paren.symbol());
    try std.testing.expectEqualStrings("<eof>", Kind.eof.symbol());
    try std.testing.expectEqualStrings("<identifier>", Kind.identifier.symbol());
    try std.testing.expectEqualStrings("=>", Kind.arrow.symbol());
    try std.testing.expectEqualStrings("===", Kind.eq3.symbol());
}

test "Kind.symbol strips kw_ prefix for keywords" {
    try std.testing.expectEqualStrings("break", Kind.kw_break.symbol());
    try std.testing.expectEqualStrings("const", Kind.kw_const.symbol());
    try std.testing.expectEqualStrings("true", Kind.kw_true.symbol());
    try std.testing.expectEqualStrings("null", Kind.kw_null.symbol());
}

test "keywords map lookup" {
    try std.testing.expectEqual(Kind.kw_break, keywords.get("break").?);
    try std.testing.expectEqual(Kind.kw_const, keywords.get("const").?);
    try std.testing.expect(keywords.get("abstract") == null); // TS contextual은 더이상 keyword 아님
    try std.testing.expect(keywords.get("readonly") == null);
    try std.testing.expect(keywords.get("notakeyword") == null);
    try std.testing.expect(keywords.get("foo") == null);
}

test "Span.len and merge" {
    const a = Span{ .start = 5, .end = 10 };
    const b = Span{ .start = 10, .end = 20 };
    try std.testing.expectEqual(@as(u32, 5), a.len());
    const merged = a.merge(b);
    try std.testing.expectEqual(@as(u32, 5), merged.start);
    try std.testing.expectEqual(@as(u32, 20), merged.end);
}

test "Token default values" {
    const tok = Token{};
    try std.testing.expectEqual(Kind.eof, tok.kind);
    try std.testing.expect(!tok.has_newline_before);
    try std.testing.expect(!tok.has_pure_comment_before);
}
