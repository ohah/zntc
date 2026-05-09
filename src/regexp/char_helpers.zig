//! Character helpers shared by the regular-expression parser.

const std = @import("std");

pub fn isHexDigit(c: u8) bool {
    return std.ascii.isHex(c);
}

pub fn isSyntaxChar(c: u8) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        else => false,
    };
}

pub fn isModifierChar(c: u8) bool {
    return c == 'i' or c == 'm' or c == 's';
}

/// modifier 문자를 비트로 변환한다 (i=1, m=2, s=4).
pub fn modifierBit(c: u8) u8 {
    return switch (c) {
        'i' => 1,
        'm' => 2,
        's' => 4,
        else => 0,
    };
}

/// v-flag: character class 내에서 리터럴로 사용할 수 없는 문법 문자.
pub fn isClassSetSyntaxChar(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}', '/', '-', '\\', '|' => true,
        else => false,
    };
}

/// v-flag: 예약된 이중 구두점 (&&, !!, ## 등).
/// 두 문자가 같고 예약 목록에 있으면 true.
pub fn isClassSetReservedDoublePunct(c1: u8, c2: u8) bool {
    return c1 == c2 and switch (c1) {
        '&', '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '^', '`', '~' => true,
        else => false,
    };
}

/// 16진수 문자를 값으로 변환한다.
pub fn hexDigitValue(c: u8) u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// 소스의 [start, end) 범위를 16진수로 해석하여 값을 반환한다.
pub fn computeHexValue(source: []const u8, start: u32, end: u32) u32 {
    var val: u32 = 0;
    for (source[start..end]) |c| {
        val = val *| 16 +| hexDigitValue(c);
    }
    return val;
}

/// 소스의 [start, end) 범위를 8진수로 해석하여 값을 반환한다.
pub fn computeOctalValue(source: []const u8, start: u32, end: u32) u32 {
    var val: u32 = 0;
    for (source[start..end]) |c| {
        val = val *| 8 +| (c - '0');
    }
    return val;
}
