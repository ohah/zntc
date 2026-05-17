//! 최소 semver range 매칭 — MF P3-2(#3437) shared 버전 호환 빌드타임
//! 검증 단일 소스. npm range 전체가 아니라 shared 의존에 실제로 쓰이는
//! 부분집합만: `^`/`~`/정확/`*`(any)/`>=`,`>`,`<=`,`<`. **그 외(복합
//! `>=1 <2`, `||`, hyphen `A - B`, prerelease 의미)는 판정 불가(`null`)
//! → 호출측이 skip**(정밀 fail-fast 원칙 — 못 푸는 입력에 거짓 경고/
//! 빌드중단 금지, P3-1 "검증 불가 ≠ 위반" 답습). 코드베이스에 기존
//! semver 구현 없음(신규 단일 소스 — 중복 구현 금지).
const std = @import("std");

const Ver = [3]u64; // major, minor, patch

/// "X[.Y[.Z]]"(선행 `v` 허용, prerelease/build `-`/`+` 절단) → {버전,
/// 명시 컴포넌트 수}. range 문자(`^~><=|*x ` 등)·비숫자 코어는 null.
/// `n` 은 tilde upper bound 계산용(npm: `~1`=`<2.0.0` vs `~1.2`=`<1.3.0`).
fn parseVerN(raw: []const u8) ?struct { v: Ver, n: u8 } {
    var s = std.mem.trim(u8, raw, " \t\r\nv");
    if (s.len == 0) return null;
    if (std.mem.indexOfAny(u8, s, "-+")) |c| s = s[0..c]; // prerelease/build 절단
    var out: Ver = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 3) return null; // X.Y.Z.W 비규약
        if (part.len == 0) return null;
        out[i] = std.fmt.parseInt(u64, part, 10) catch return null; // 'x'/'*'/range → null
    }
    return .{ .v = out, .n = @intCast(i) };
}

/// concrete 버전(컴포넌트 수 무시). 호출측 다수가 Ver 만 필요.
fn parseVer(raw: []const u8) ?Ver {
    return (parseVerN(raw) orelse return null).v;
}

fn cmp(a: Ver, b: Ver) std.math.Order {
    for (0..3) |i| {
        if (a[i] != b[i]) return std.math.order(a[i], b[i]);
    }
    return .eq;
}

/// `range` 가 concrete `version` 을 허용하나. `true`/`false` = 확정 판정,
/// **`null` = 판정 불가**(version 비-concrete, 또는 range 가 지원 밖
/// 형태) → 호출측은 null 을 위반으로 보지 말 것(skip).
pub fn satisfies(range: []const u8, version: []const u8) ?bool {
    const v = parseVer(version) orelse return null;
    const r = std.mem.trim(u8, range, " \t\r\n");
    if (r.len == 0 or std.mem.eql(u8, r, "*") or std.mem.eql(u8, r, "x") or
        std.mem.eql(u8, r, "latest")) return true;
    // 복합/대안 range 는 비-목표 → 판정 불가.
    if (std.mem.indexOfAny(u8, r, " ,|") != null) return null;

    if (r[0] == '^') {
        const b = parseVer(r[1..]) orelse return null;
        if (cmp(v, b) == .lt) return false;
        // caret: major>0 → <(M+1).0.0; 0.m(>0) → <0.(m+1).0; 0.0.p → ==
        const upper: Ver = if (b[0] > 0)
            .{ b[0] + 1, 0, 0 }
        else if (b[1] > 0)
            .{ 0, b[1] + 1, 0 }
        else
            .{ 0, 0, b[2] + 1 };
        return cmp(v, upper) == .lt;
    }
    if (r[0] == '~') {
        const p = parseVerN(r[1..]) orelse return null;
        const b = p.v;
        if (cmp(v, b) == .lt) return false;
        // npm tilde: minor 명시 시 `<X.(Y+1).0`, major 만(`~1`)이면
        // `<(X+1).0.0`(minor 변경 허용).
        const upper: Ver = if (p.n >= 2) .{ b[0], b[1] + 1, 0 } else .{ b[0] + 1, 0, 0 };
        return cmp(v, upper) == .lt;
    }
    if (std.mem.startsWith(u8, r, ">=")) {
        const b = parseVer(r[2..]) orelse return null;
        return cmp(v, b) != .lt;
    }
    if (std.mem.startsWith(u8, r, "<=")) {
        const b = parseVer(r[2..]) orelse return null;
        return cmp(v, b) != .gt;
    }
    if (r[0] == '>') {
        const b = parseVer(r[1..]) orelse return null;
        return cmp(v, b) == .gt;
    }
    if (r[0] == '<') {
        const b = parseVer(r[1..]) orelse return null;
        return cmp(v, b) == .lt;
    }
    // 정확(`=` 접두 허용). 비-concrete operand → 판정 불가.
    const exact = if (r[0] == '=') r[1..] else r;
    const b = parseVer(exact) orelse return null;
    return cmp(v, b) == .eq;
}

test "satisfies: caret — major>0 / 0.x / 0.0.x" {
    try std.testing.expectEqual(@as(?bool, true), satisfies("^19.0.0", "19.2.4"));
    try std.testing.expectEqual(@as(?bool, true), satisfies("^19", "19.9.9")); // ^19 = ^19.0.0
    try std.testing.expectEqual(@as(?bool, false), satisfies("^19.0.0", "20.0.0"));
    try std.testing.expectEqual(@as(?bool, false), satisfies("^19.2.0", "19.1.0"));
    try std.testing.expectEqual(@as(?bool, true), satisfies("^0.3.0", "0.3.9")); // 0.x → minor 고정
    try std.testing.expectEqual(@as(?bool, false), satisfies("^0.3.0", "0.4.0"));
    try std.testing.expectEqual(@as(?bool, true), satisfies("^0.0.5", "0.0.5")); // 0.0.x → exact
    try std.testing.expectEqual(@as(?bool, false), satisfies("^0.0.5", "0.0.6"));
}

test "satisfies: tilde / 비교자 / any / 정확" {
    try std.testing.expectEqual(@as(?bool, true), satisfies("~1.2.3", "1.2.9"));
    try std.testing.expectEqual(@as(?bool, false), satisfies("~1.2.3", "1.3.0"));
    // npm: ~1.2 = <1.3.0 (minor 명시) / ~1 = <2.0.0 (major 만)
    try std.testing.expectEqual(@as(?bool, false), satisfies("~1.2", "1.3.0"));
    try std.testing.expectEqual(@as(?bool, true), satisfies("~1", "1.9.9"));
    try std.testing.expectEqual(@as(?bool, false), satisfies("~1", "2.0.0"));
    try std.testing.expectEqual(@as(?bool, true), satisfies(">=18.0.0", "19.2.4"));
    try std.testing.expectEqual(@as(?bool, false), satisfies(">=20", "19.2.4"));
    try std.testing.expectEqual(@as(?bool, true), satisfies("<2.0.0", "1.9.9"));
    try std.testing.expectEqual(@as(?bool, true), satisfies("*", "19.2.4"));
    try std.testing.expectEqual(@as(?bool, true), satisfies("", "1.0.0"));
    try std.testing.expectEqual(@as(?bool, true), satisfies("1.2.3", "1.2.3"));
    try std.testing.expectEqual(@as(?bool, false), satisfies("=1.2.3", "1.2.4"));
}

test "satisfies: 판정 불가 → null (정밀 fail-fast)" {
    // version 비-concrete(zntc P2-0 remote 의 version=range 대용)
    try std.testing.expectEqual(@as(?bool, null), satisfies("^19", "^19"));
    try std.testing.expectEqual(@as(?bool, null), satisfies("^19", "19.x"));
    // range 가 지원 밖(복합/대안/hyphen)
    try std.testing.expectEqual(@as(?bool, null), satisfies(">=1.0.0 <2.0.0", "1.5.0"));
    try std.testing.expectEqual(@as(?bool, null), satisfies("18 || 19", "19.0.0"));
    try std.testing.expectEqual(@as(?bool, null), satisfies("1.0.0 - 2.0.0", "1.5.0"));
}
