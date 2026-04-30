//! 문자열 슬라이스 리스트 헬퍼 — 다중 plugin (emotion/styled-components/worklet) 에서
//! 공유. 짧은 list (1-N items) 의 linear 매칭에 최적.

const std = @import("std");

/// `needle` 이 `list` 에 정확히 등장하는지 (`std.mem.eql` equality).
pub fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

/// 단일 `*` wildcard glob 매칭 — `prefix*suffix` 형태 1 회만 지원. picomatch 풀 스펙
/// (multi `*`, `?`, `[]`, brace expansion) 까진 안 감 — 대부분의 vendored fork 사용
/// 케이스 (`@my-org/*`, `*-styled`) 커버. `*` 미포함 시 정확 일치.
pub fn matchesGlob(pattern: []const u8, source: []const u8) bool {
    const star_pos = std.mem.indexOfScalar(u8, pattern, '*') orelse {
        return std.mem.eql(u8, pattern, source);
    };
    const prefix = pattern[0..star_pos];
    const suffix = pattern[star_pos + 1 ..];
    if (source.len < prefix.len + suffix.len) return false;
    if (!std.mem.startsWith(u8, source, prefix)) return false;
    return std.mem.endsWith(u8, source, suffix);
}

/// `list` 의 패턴 중 하나라도 `source` 와 glob 매칭되는지.
pub fn anyGlobMatch(list: []const []const u8, source: []const u8) bool {
    for (list) |pat| {
        if (matchesGlob(pat, source)) return true;
    }
    return false;
}

test "matchesGlob: exact match (no star)" {
    try std.testing.expect(matchesGlob("styled-components", "styled-components"));
    try std.testing.expect(!matchesGlob("styled-components", "styled-components/native"));
}

test "matchesGlob: prefix wildcard" {
    try std.testing.expect(matchesGlob("@my-org/*", "@my-org/styled"));
    try std.testing.expect(matchesGlob("@my-org/*", "@my-org/"));
    try std.testing.expect(!matchesGlob("@my-org/*", "@other/styled"));
}

test "matchesGlob: suffix wildcard" {
    try std.testing.expect(matchesGlob("*-styled", "my-styled"));
    try std.testing.expect(!matchesGlob("*-styled", "styled-x"));
}

test "matchesGlob: middle wildcard" {
    try std.testing.expect(matchesGlob("@*/styled", "@my-org/styled"));
    try std.testing.expect(!matchesGlob("@*/styled", "@my-org/css"));
}
