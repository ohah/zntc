const std = @import("std");
const unicode_property = @import("unicode_property.zig");
const isValidUnicodeProperty = unicode_property.isValidUnicodeProperty;
const isValidLoneUnicodeProperty = unicode_property.isValidLoneUnicodeProperty;
const isValidPropertyOfStrings = unicode_property.isValidPropertyOfStrings;

test "isValidUnicodeProperty — General_Category (gc)" {
    // gc 약어로 검색
    try std.testing.expect(isValidUnicodeProperty("gc", "Lu"));
    try std.testing.expect(isValidUnicodeProperty("gc", "Uppercase_Letter"));
    try std.testing.expect(isValidUnicodeProperty("gc", "Ll"));
    try std.testing.expect(isValidUnicodeProperty("gc", "Nd"));
    try std.testing.expect(isValidUnicodeProperty("gc", "digit"));
    // 전체 이름으로 검색
    try std.testing.expect(isValidUnicodeProperty("General_Category", "Lu"));
    try std.testing.expect(isValidUnicodeProperty("General_Category", "Letter"));
    // 유효하지 않은 값
    try std.testing.expect(!isValidUnicodeProperty("gc", "NotACategory"));
    try std.testing.expect(!isValidUnicodeProperty("gc", ""));
    try std.testing.expect(!isValidUnicodeProperty("gc", "Latin"));
}

test "isValidUnicodeProperty — Script (sc)" {
    try std.testing.expect(isValidUnicodeProperty("Script", "Latin"));
    try std.testing.expect(isValidUnicodeProperty("Script", "Latn"));
    try std.testing.expect(isValidUnicodeProperty("sc", "Greek"));
    try std.testing.expect(isValidUnicodeProperty("sc", "Grek"));
    try std.testing.expect(isValidUnicodeProperty("sc", "Han"));
    try std.testing.expect(isValidUnicodeProperty("sc", "Hangul"));
    // 유효하지 않은 스크립트
    try std.testing.expect(!isValidUnicodeProperty("Script", "NotAScript"));
    try std.testing.expect(!isValidUnicodeProperty("sc", "Lu"));
}

test "isValidUnicodeProperty — Script_Extensions (scx)" {
    // scx는 sc 값을 공유
    try std.testing.expect(isValidUnicodeProperty("Script_Extensions", "Latin"));
    try std.testing.expect(isValidUnicodeProperty("scx", "Latn"));
    try std.testing.expect(isValidUnicodeProperty("scx", "Common"));
    // 유효하지 않은 프로퍼티 이름
    try std.testing.expect(!isValidUnicodeProperty("InvalidProp", "Latin"));
}

test "isValidUnicodeProperty — invalid property name" {
    try std.testing.expect(!isValidUnicodeProperty("Foo", "Bar"));
    try std.testing.expect(!isValidUnicodeProperty("", "Lu"));
}

test "isValidLoneUnicodeProperty — gc values" {
    try std.testing.expect(isValidLoneUnicodeProperty("Lu"));
    try std.testing.expect(isValidLoneUnicodeProperty("Uppercase_Letter"));
    try std.testing.expect(isValidLoneUnicodeProperty("Ll"));
    try std.testing.expect(isValidLoneUnicodeProperty("Letter"));
    try std.testing.expect(isValidLoneUnicodeProperty("Number"));
    try std.testing.expect(isValidLoneUnicodeProperty("Nd"));
}

test "isValidLoneUnicodeProperty — binary properties" {
    try std.testing.expect(isValidLoneUnicodeProperty("ASCII"));
    try std.testing.expect(isValidLoneUnicodeProperty("Alphabetic"));
    try std.testing.expect(isValidLoneUnicodeProperty("Alpha"));
    try std.testing.expect(isValidLoneUnicodeProperty("Emoji"));
    try std.testing.expect(isValidLoneUnicodeProperty("White_Space"));
    try std.testing.expect(isValidLoneUnicodeProperty("space"));
    try std.testing.expect(isValidLoneUnicodeProperty("ID_Start"));
    try std.testing.expect(isValidLoneUnicodeProperty("IDS"));
}

test "isValidLoneUnicodeProperty — invalid" {
    try std.testing.expect(!isValidLoneUnicodeProperty("NotAProperty"));
    try std.testing.expect(!isValidLoneUnicodeProperty("Latin"));
    try std.testing.expect(!isValidLoneUnicodeProperty(""));
}

test "isValidPropertyOfStrings — valid" {
    try std.testing.expect(isValidPropertyOfStrings("Basic_Emoji"));
    try std.testing.expect(isValidPropertyOfStrings("Emoji_Keycap_Sequence"));
    try std.testing.expect(isValidPropertyOfStrings("RGI_Emoji_Modifier_Sequence"));
    try std.testing.expect(isValidPropertyOfStrings("RGI_Emoji_Flag_Sequence"));
    try std.testing.expect(isValidPropertyOfStrings("RGI_Emoji_Tag_Sequence"));
    try std.testing.expect(isValidPropertyOfStrings("RGI_Emoji_ZWJ_Sequence"));
    try std.testing.expect(isValidPropertyOfStrings("RGI_Emoji"));
}

test "isValidPropertyOfStrings — invalid" {
    try std.testing.expect(!isValidPropertyOfStrings("ASCII"));
    try std.testing.expect(!isValidPropertyOfStrings("Emoji"));
    try std.testing.expect(!isValidPropertyOfStrings("Lu"));
    try std.testing.expect(!isValidPropertyOfStrings(""));
}
