const std = @import("std");
const unicode = @import("unicode.zig");
const decodeUtf8 = unicode.decodeUtf8;
const isIdentifierStart = unicode.isIdentifierStart;
const isIdentifierContinue = unicode.isIdentifierContinue;

test "decodeUtf8: ASCII" {
    const result = decodeUtf8("A");
    try std.testing.expectEqual(@as(u21, 'A'), result.codepoint);
    try std.testing.expectEqual(@as(u3, 1), result.len);
}

test "decodeUtf8: 2-byte UTF-8" {
    // é = U+00E9 = 0xC3 0xA9
    const result = decodeUtf8("\xC3\xA9");
    try std.testing.expectEqual(@as(u21, 0x00E9), result.codepoint);
    try std.testing.expectEqual(@as(u3, 2), result.len);
}

test "decodeUtf8: 3-byte UTF-8 (한)" {
    // 한 = U+D55C = 0xED 0x95 0x9C
    const result = decodeUtf8("\xED\x95\x9C");
    try std.testing.expectEqual(@as(u21, 0xD55C), result.codepoint);
    try std.testing.expectEqual(@as(u3, 3), result.len);
}

test "decodeUtf8: 4-byte UTF-8 (emoji)" {
    // 😀 = U+1F600 = 0xF0 0x9F 0x98 0x80
    const result = decodeUtf8("\xF0\x9F\x98\x80");
    try std.testing.expectEqual(@as(u21, 0x1F600), result.codepoint);
    try std.testing.expectEqual(@as(u3, 4), result.len);
}

test "isIdentifierStart: ASCII" {
    try std.testing.expect(isIdentifierStart('a'));
    try std.testing.expect(isIdentifierStart('Z'));
    try std.testing.expect(isIdentifierStart('_'));
    try std.testing.expect(isIdentifierStart('$'));
    try std.testing.expect(!isIdentifierStart('0'));
    try std.testing.expect(!isIdentifierStart('+'));
}

test "isIdentifierStart: Unicode" {
    try std.testing.expect(isIdentifierStart(0x00E9)); // é (Latin)
    try std.testing.expect(isIdentifierStart(0x4E2D)); // 中 (CJK)
    try std.testing.expect(isIdentifierStart(0xD55C)); // 한 (Hangul)
    try std.testing.expect(isIdentifierStart(0x03B1)); // α (Greek)
    try std.testing.expect(isIdentifierStart(0x0410)); // А (Cyrillic)
}

test "isIdentifierStart: CJK Extension A" {
    // CJK Extension A 범위 (U+3400-U+4DBF) — vals-cjk 테스트 대응
    try std.testing.expect(isIdentifierStart(0x3400)); // 㐀
    try std.testing.expect(isIdentifierStart(0x362E)); // 㘮
    try std.testing.expect(isIdentifierStart(0x4DB5)); // 䶵
}

test "isIdentifierStart: VERTICAL TILDE excluded" {
    // U+2E2F (VERTICAL TILDE) — Pattern_Syntax이므로 ID_Start에서 제외
    try std.testing.expect(!isIdentifierStart(0x2E2F));
}

test "isIdentifierStart: Other_ID_Start" {
    // Other_ID_Start 특별 문자
    try std.testing.expect(isIdentifierStart(0x1885)); // MONGOLIAN LETTER ALI GALI BALUDA
    try std.testing.expect(isIdentifierStart(0x1886)); // MONGOLIAN LETTER ALI GALI THREE BALUDA
    try std.testing.expect(isIdentifierStart(0x2118)); // SCRIPT CAPITAL P (℘)
    try std.testing.expect(isIdentifierStart(0x212E)); // ESTIMATED SYMBOL (℮)
    try std.testing.expect(isIdentifierStart(0x309B)); // KATAKANA-HIRAGANA VOICED SOUND MARK (゛)
    try std.testing.expect(isIdentifierStart(0x309C)); // KATAKANA-HIRAGANA SEMI-VOICED SOUND MARK (゜)
}

test "isIdentifierContinue: digits and special" {
    try std.testing.expect(isIdentifierContinue('0'));
    try std.testing.expect(isIdentifierContinue('9'));
    try std.testing.expect(isIdentifierContinue('a'));
    try std.testing.expect(isIdentifierContinue('$'));
    try std.testing.expect(isIdentifierContinue(0x200C)); // ZWNJ
    try std.testing.expect(isIdentifierContinue(0x200D)); // ZWJ
    try std.testing.expect(!isIdentifierContinue('+'));
    try std.testing.expect(!isIdentifierContinue(' '));
}

test "isIdentifierContinue: combining marks and digits" {
    try std.testing.expect(isIdentifierContinue(0x0300)); // COMBINING GRAVE ACCENT
    try std.testing.expect(isIdentifierContinue(0x0966)); // DEVANAGARI DIGIT ZERO
    try std.testing.expect(isIdentifierContinue(0x00B7)); // MIDDLE DOT (Other_ID_Continue)
    try std.testing.expect(isIdentifierContinue(0x203F)); // UNDERTIE (Pc)
    try std.testing.expect(isIdentifierContinue(0xFF3F)); // FULLWIDTH LOW LINE (Pc)
}

test "isIdentifierContinue: VERTICAL TILDE excluded" {
    // U+2E2F (VERTICAL TILDE) — ID_Start도 아니고 ID_Continue도 아님
    try std.testing.expect(!isIdentifierContinue(0x2E2F));
}

test "isIdentifierContinue: Katakana middle dot (Unicode 15.1.0)" {
    // U+30FB KATAKANA MIDDLE DOT — Unicode 15.1.0에서 ID_Continue에 추가
    try std.testing.expect(isIdentifierContinue(0x30FB));
    // U+FF65 HALFWIDTH KATAKANA MIDDLE DOT
    try std.testing.expect(isIdentifierContinue(0xFF65));
}
