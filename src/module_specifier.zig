//! 모듈 specifier 표기 판별.
//!
//! resolver(해석)와 config(tsconfig 파싱)가 **같은 술어**를 써야 하는 지점이라 여기 하나만 둔다.
//! 두 곳이 갈라지면 config 는 매핑을 살아 있는 것으로 등록하는데 resolver 는 영원히 매칭하지
//! 않는(또는 그 반대) 상태가 되고, 그건 진단 없는 오번들로 나타난다.

const std = @import("std");

/// 상대 specifier 인지 — `.` 또는 `..` 뒤에 문자열 끝이나 경로 구분자(`/`, `\`) 가 오는 경우.
///
/// - rooted(`/…`) 는 상대가 **아니다**: `"/@/*"` 같은 paths 키가 실사용되므로 `/` 를 상대로
///   묶으면 그런 프로젝트가 전면 빌드 실패한다.
/// - 백슬래시(`.\x`) 도 상대다. 빼면 Windows 표기 지정자만 다른 경로를 타서, 같은 소스가
///   플랫폼 표기에 따라 다른 모듈로 번들된다.
/// - `.foo` / `..foo` / `...x` 처럼 점으로 시작하지만 구분자가 없는 것은 bare specifier 다.
pub fn isRelative(specifier: []const u8) bool {
    if (specifier.len == 0 or specifier[0] != '.') return false;
    // 선행 점 1~2개를 소비한 뒤, 남은 게 없거나(".", "..") 구분자로 시작하면 상대.
    const rest = if (specifier.len >= 2 and specifier[1] == '.') specifier[2..] else specifier[1..];
    if (rest.len == 0) return true;
    return rest[0] == '/' or rest[0] == '\\';
}

test isRelative {
    for ([_][]const u8{ ".", "..", "./x", "../x", ".//x", ".\\x", "..\\x", "./" }) |sp| {
        try std.testing.expect(isRelative(sp));
    }
    for ([_][]const u8{ "", "x", "@/x", "/x", "/@/utils", ".foo", "..foo", "...x", "node:fs" }) |sp| {
        try std.testing.expect(!isRelative(sp));
    }
}
