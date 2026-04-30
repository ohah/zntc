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

/// picomatch 호환 glob 매칭 — `*` (0+ chars), `?` (1 char), `[abc]`/`[a-z]`/`[!abc]`
/// (bracket class + negation), `{a,b,c}` (brace expansion, nested 가능). path-segment
/// `/` 는 일반 char 로 취급 — npm package 이름 매칭 use case 라 picomatch 의 segment
/// 경계 동작 (`*` 가 `/` 못 넘음) 은 disable.
pub fn matchesGlob(pattern: []const u8, source: []const u8) bool {
    return matchesGlobInternal(pattern, source);
}

/// brace expansion 처리 후 simple glob 매칭. 비-nested `{a,b}` 가 가장 단순. nested 는
/// 재귀. 합성된 alt 가 길 수 있어 stack-allocated buffer 사용 (실용 패턴 < 512 bytes).
fn matchesGlobInternal(pattern: []const u8, source: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '{')) |open| {
        const close = findMatchingBrace(pattern, open) orelse return matchSimple(pattern, source);
        const prefix = pattern[0..open];
        const suffix = pattern[close + 1 ..];
        const inner = pattern[open + 1 .. close];

        var buf: [512]u8 = undefined;
        var alt_start: usize = 0;
        var depth: usize = 0;
        var i: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            const c: u8 = if (at_end) ',' else inner[i];
            if (!at_end and c == '{') depth += 1;
            if (!at_end and c == '}') depth -= 1;
            const at_split = (c == ',' and depth == 0) or at_end;
            if (!at_split) continue;
            const alt = inner[alt_start..i];
            const total = prefix.len + alt.len + suffix.len;
            if (total <= buf.len) {
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len..][0..alt.len], alt);
                @memcpy(buf[prefix.len + alt.len ..][0..suffix.len], suffix);
                if (matchesGlobInternal(buf[0..total], source)) return true;
            }
            alt_start = i + 1;
        }
        return false;
    }
    return matchSimple(pattern, source);
}

/// `{` 와 매칭되는 `}` 위치 (nested brace 고려). 미발견 시 null.
fn findMatchingBrace(pattern: []const u8, open: usize) ?usize {
    var depth: usize = 1;
    var i: usize = open + 1;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// brace 없는 패턴의 backtracking 매칭 — `*`, `?`, `[...]` 처리.
fn matchSimple(pattern: []const u8, source: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    while (pi < pattern.len) {
        const c = pattern[pi];
        switch (c) {
            '*' => {
                pi += 1;
                if (pi == pattern.len) return true;
                while (si <= source.len) : (si += 1) {
                    if (matchSimple(pattern[pi..], source[si..])) return true;
                }
                return false;
            },
            '?' => {
                if (si >= source.len) return false;
                pi += 1;
                si += 1;
            },
            '[' => {
                const end = std.mem.indexOfScalarPos(u8, pattern, pi + 1, ']') orelse return false;
                if (si >= source.len) return false;
                const negated = pattern[pi + 1] == '!' or pattern[pi + 1] == '^';
                const class_start: usize = if (negated) pi + 2 else pi + 1;
                var matched = false;
                var bi = class_start;
                while (bi < end) {
                    if (bi + 2 < end and pattern[bi + 1] == '-') {
                        if (source[si] >= pattern[bi] and source[si] <= pattern[bi + 2]) matched = true;
                        bi += 3;
                    } else {
                        if (source[si] == pattern[bi]) matched = true;
                        bi += 1;
                    }
                }
                if (matched == negated) return false;
                pi = end + 1;
                si += 1;
            },
            else => {
                if (si >= source.len or source[si] != c) return false;
                pi += 1;
                si += 1;
            },
        }
    }
    return si == source.len;
}

/// `list` 의 패턴 중 하나라도 `source` 와 glob 매칭되는지.
pub fn anyGlobMatch(list: []const []const u8, source: []const u8) bool {
    for (list) |pat| {
        if (matchesGlob(pat, source)) return true;
    }
    return false;
}

test "matchesGlob: exact match (no special)" {
    try std.testing.expect(matchesGlob("styled-components", "styled-components"));
    try std.testing.expect(!matchesGlob("styled-components", "styled-components/native"));
}

test "matchesGlob: single star — prefix/suffix/middle" {
    try std.testing.expect(matchesGlob("@my-org/*", "@my-org/styled"));
    try std.testing.expect(matchesGlob("@my-org/*", "@my-org/"));
    try std.testing.expect(!matchesGlob("@my-org/*", "@other/styled"));
    try std.testing.expect(matchesGlob("*-styled", "my-styled"));
    try std.testing.expect(!matchesGlob("*-styled", "styled-x"));
    try std.testing.expect(matchesGlob("@*/styled", "@my-org/styled"));
    try std.testing.expect(!matchesGlob("@*/styled", "@my-org/css"));
}

test "matchesGlob: multi star" {
    try std.testing.expect(matchesGlob("a*b*c", "axxxbyc"));
    try std.testing.expect(matchesGlob("a*b*c", "abc"));
    try std.testing.expect(!matchesGlob("a*b*c", "axxxc"));
}

test "matchesGlob: question mark" {
    try std.testing.expect(matchesGlob("a?c", "abc"));
    try std.testing.expect(matchesGlob("a?c", "axc"));
    try std.testing.expect(!matchesGlob("a?c", "ac"));
    try std.testing.expect(!matchesGlob("a?c", "abxc"));
}

test "matchesGlob: bracket class" {
    try std.testing.expect(matchesGlob("[abc]", "a"));
    try std.testing.expect(matchesGlob("[abc]", "b"));
    try std.testing.expect(!matchesGlob("[abc]", "d"));
    try std.testing.expect(matchesGlob("[a-z]", "m"));
    try std.testing.expect(!matchesGlob("[a-z]", "M"));
    try std.testing.expect(matchesGlob("[A-Z]", "M"));
}

test "matchesGlob: bracket negation" {
    try std.testing.expect(matchesGlob("[!abc]", "d"));
    try std.testing.expect(!matchesGlob("[!abc]", "a"));
    try std.testing.expect(matchesGlob("[^a-z]", "X"));
    try std.testing.expect(!matchesGlob("[^a-z]", "x"));
}

test "matchesGlob: brace expansion" {
    try std.testing.expect(matchesGlob("{foo,bar}", "foo"));
    try std.testing.expect(matchesGlob("{foo,bar}", "bar"));
    try std.testing.expect(!matchesGlob("{foo,bar}", "baz"));
    try std.testing.expect(matchesGlob("a-{b,c}-d", "a-b-d"));
    try std.testing.expect(matchesGlob("a-{b,c}-d", "a-c-d"));
}

test "matchesGlob: brace nested" {
    try std.testing.expect(matchesGlob("{a,{b,c}}", "a"));
    try std.testing.expect(matchesGlob("{a,{b,c}}", "b"));
    try std.testing.expect(matchesGlob("{a,{b,c}}", "c"));
    try std.testing.expect(!matchesGlob("{a,{b,c}}", "d"));
}

test "matchesGlob: combined star + brace + class" {
    try std.testing.expect(matchesGlob("@{my-org,co}/*", "@my-org/styled"));
    try std.testing.expect(matchesGlob("@{my-org,co}/*", "@co/anything"));
    try std.testing.expect(!matchesGlob("@{my-org,co}/*", "@other/x"));
}
