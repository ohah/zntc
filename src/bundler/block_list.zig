//! resolver blockList — 해석 단계에서 특정 경로를 차단하는 패턴 매칭.
//!
//! Metro/webpack의 blocklist 호환. Metro는 RegExp를 쓰지만 실전 패턴 대부분은
//! 단순 케이스로 커버 가능해서 최소 매처만 구현한다.
//!
//! **지원 구문** (JS regex 서브셋):
//! - 리터럴 문자
//! - `.*` : 임의 문자열 (그리디, 개행 포함 X)
//! - `^` : 시작 앵커 (패턴 맨 앞에서만)
//! - `$` : 끝 앵커 (패턴 맨 뒤에서만)
//! - `\/`, `\.`, `\\` : 이스케이프 (JS regex source 직접 받을 때 보존됨)
//!
//! **미지원**: `|`, `[]`, `()`, `+`, `?`, `{n,m}`, `\w`, `\d`, lookaround 등.
//! 이런 패턴이 필요하면 `onResolve` 플러그인 훅으로 우회.

const std = @import("std");

/// `pattern`이 `text`의 어딘가와 매칭되는지 판정.
/// `^`/`$`가 없으면 substring 매칭(어딘가 포함되면 OK). 있으면 그 위치 고정.
pub fn matches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return false;

    const anchored_start = pattern.len > 0 and pattern[0] == '^';
    const anchored_end = pattern.len > 0 and pattern[pattern.len - 1] == '$'
        // `\$`는 리터럴 $ — 마지막 $ 앞에 역슬래시면 앵커 아님
    and !(pattern.len >= 2 and pattern[pattern.len - 2] == '\\');

    const p_start: usize = if (anchored_start) 1 else 0;
    const p_end: usize = if (anchored_end) pattern.len - 1 else pattern.len;
    const p = pattern[p_start..p_end];

    if (anchored_start and anchored_end) {
        return matchAt(p, text, 0, text.len) == text.len;
    } else if (anchored_start) {
        const r = matchAt(p, text, 0, text.len);
        return r != null_match;
    } else if (anchored_end) {
        // 뒤에서부터 가능한 시작 지점을 훑으며 end 위치가 text.len인지 본다.
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            const r = matchAt(p, text, start, text.len);
            if (r == text.len) return true;
        }
        return false;
    } else {
        // substring: 어떤 시작 지점에서든 매칭되면 true
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (matchAt(p, text, start, text.len) != null_match) return true;
        }
        return false;
    }
}

const null_match: usize = std.math.maxInt(usize);

/// `pattern`을 `text[start..]`에 맞춰 본다. 매칭 성공 시 끝 위치(text 인덱스) 반환, 실패 시 null_match.
fn matchAt(pattern: []const u8, text: []const u8, start: usize, text_end: usize) usize {
    var pi: usize = 0;
    var ti: usize = start;

    while (pi < pattern.len) {
        // `.*` — 0개 이상 임의 문자. 그리디: 최대한 먹고 역추적.
        if (pi + 1 < pattern.len and pattern[pi] == '.' and pattern[pi + 1] == '*') {
            const rest = pattern[pi + 2 ..];
            // rest가 text의 가능한 접미사들과 매칭되는지 — 큰 것부터 시도.
            var take: usize = text_end - ti;
            while (true) : (take -= 1) {
                const r = matchAt(rest, text, ti + take, text_end);
                if (r != null_match) return r;
                if (take == 0) break;
            }
            return null_match;
        }

        // 이스케이프: 다음 문자를 리터럴로 취급
        if (pattern[pi] == '\\' and pi + 1 < pattern.len) {
            if (ti >= text_end) return null_match;
            if (pattern[pi + 1] != text[ti]) return null_match;
            pi += 2;
            ti += 1;
            continue;
        }

        // `.` 단일 — 임의 1문자
        if (pattern[pi] == '.') {
            if (ti >= text_end) return null_match;
            pi += 1;
            ti += 1;
            continue;
        }

        // 리터럴
        if (ti >= text_end) return null_match;
        if (pattern[pi] != text[ti]) return null_match;
        pi += 1;
        ti += 1;
    }

    return ti;
}

// ============ tests ============

test "matches: substring" {
    try std.testing.expect(matches("/ios/", "/app/ios/main.m"));
    try std.testing.expect(!matches("/ios/", "/app/android/main.m"));
}

test "matches: escape slash (JS regex source 그대로)" {
    try std.testing.expect(matches("\\/ios\\/", "/app/ios/main.m"));
    try std.testing.expect(!matches("\\/ios\\/", "/app/ipad/main.m"));
}

test "matches: suffix anchor" {
    try std.testing.expect(matches("\\.bak$", "file.bak"));
    try std.testing.expect(matches("\\.bak$", "/tmp/file.bak"));
    try std.testing.expect(!matches("\\.bak$", "file.bak.txt"));
}

test "matches: prefix anchor" {
    try std.testing.expect(matches("^/src/", "/src/app.ts"));
    try std.testing.expect(!matches("^/src/", "/app/src/main.ts"));
}

test "matches: .* 임의 문자열" {
    try std.testing.expect(matches("node_modules\\/.*\\/node_modules", "foo/node_modules/pkg/node_modules/bar"));
    try std.testing.expect(!matches("node_modules\\/.*\\/node_modules", "foo/node_modules/pkg"));
}

test "matches: Metro 기본 패턴들" {
    try std.testing.expect(matches("\\/__tests__\\/", "/app/src/__tests__/foo.test.ts"));
    try std.testing.expect(matches("\\/android\\/app\\/build\\/", "/project/android/app/build/foo"));
    try std.testing.expect(matches("\\/ios\\/Pods\\/", "/project/ios/Pods/bar"));
}

test "matches: empty pattern rejects" {
    try std.testing.expect(!matches("", "anything"));
}
