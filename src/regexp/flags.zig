//! ECMAScript 정규식 플래그 검증.
//!
//! 유효한 플래그: d, g, i, m, s, u, v, y
//! 검증 규칙:
//!   - 중복 금지 (/foo/gg → 에러)
//!   - 미지원 문자 금지 (/foo/x → 에러)
//!   - u와 v 동시 사용 금지 (/foo/uv → 에러, ES2024)

const std = @import("std");

/// RegExp 검증 에러.
pub const Error = struct {
    /// 에러 메시지 (정적 문자열)
    message: []const u8,
    /// 에러 위치 (패턴/플래그 내의 byte offset, 0-based)
    offset: u32 = 0,
};

/// 플래그 비트마스크.
pub const Flags = packed struct(u8) {
    d: bool = false, // hasIndices (ES2022)
    g: bool = false, // global
    i: bool = false, // ignoreCase
    m: bool = false, // multiline
    s: bool = false, // dotAll (ES2018)
    u: bool = false, // unicode (ES2015)
    v: bool = false, // unicodeSets (ES2024)
    y: bool = false, // sticky (ES2015)

    pub fn hasUnicodeMode(self: Flags) bool {
        return self.u or self.v;
    }
};

/// 플래그 텍스트를 검증한다.
/// 유효하면 null, 에러가 있으면 Error 반환.
pub fn validate(flag_text: []const u8) ?Error {
    var seen = Flags{};

    for (flag_text, 0..) |c, i| {
        switch (c) {
            'd' => {
                if (seen.d) return .{ .message = "duplicate regular expression flag 'd'", .offset = @intCast(i) };
                seen.d = true;
            },
            'g' => {
                if (seen.g) return .{ .message = "duplicate regular expression flag 'g'", .offset = @intCast(i) };
                seen.g = true;
            },
            'i' => {
                if (seen.i) return .{ .message = "duplicate regular expression flag 'i'", .offset = @intCast(i) };
                seen.i = true;
            },
            'm' => {
                if (seen.m) return .{ .message = "duplicate regular expression flag 'm'", .offset = @intCast(i) };
                seen.m = true;
            },
            's' => {
                if (seen.s) return .{ .message = "duplicate regular expression flag 's'", .offset = @intCast(i) };
                seen.s = true;
            },
            'u' => {
                if (seen.u) return .{ .message = "duplicate regular expression flag 'u'", .offset = @intCast(i) };
                if (seen.v) return .{ .message = "regular expression flags 'u' and 'v' cannot be used together", .offset = @intCast(i) };
                seen.u = true;
            },
            'v' => {
                if (seen.v) return .{ .message = "duplicate regular expression flag 'v'", .offset = @intCast(i) };
                if (seen.u) return .{ .message = "regular expression flags 'u' and 'v' cannot be used together", .offset = @intCast(i) };
                seen.v = true;
            },
            'y' => {
                if (seen.y) return .{ .message = "duplicate regular expression flag 'y'", .offset = @intCast(i) };
                seen.y = true;
            },
            else => return .{ .message = "invalid regular expression flag", .offset = @intCast(i) },
        }
    }

    return null;
}

/// 플래그 텍스트를 파싱하여 Flags 비트마스크를 반환한다.
/// 검증 없이 파싱만 수행 (검증은 validate()로).
pub fn parse(flag_text: []const u8) Flags {
    var result = Flags{};
    for (flag_text) |c| {
        switch (c) {
            'd' => result.d = true,
            'g' => result.g = true,
            'i' => result.i = true,
            'm' => result.m = true,
            's' => result.s = true,
            'u' => result.u = true,
            'v' => result.v = true,
            'y' => result.y = true,
            else => {},
        }
    }
    return result;
}
