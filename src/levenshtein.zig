//! Levenshtein 편집 거리 + "Did you mean?" 제안
//!
//! 두 문자열 사이의 최소 편집 횟수(삽입, 삭제, 치환)를 계산한다.
//! 번들러에서 unresolved import나 missing export 발생 시
//! 가장 유사한 이름을 "Did you mean 'X'?" 형태로 제안하는 데 사용한다.
//!
//! 알고리즘: Wagner-Fischer (single-row DP)
//!   - 시간: O(m × n)
//!   - 공간: O(min(m, n)) — 짧은 쪽 기준 1행만 사용
//!   - 256바이트까지는 스택 버퍼 사용, 초과 시 allocator 폴백

const std = @import("std");

/// 두 문자열 사이의 Levenshtein 편집 거리를 계산한다.
///
/// 편집 거리란 한 문자열을 다른 문자열로 변환하기 위해 필요한
/// 최소 연산 횟수다 (삽입 1회, 삭제 1회, 치환 1회 각각 비용 1).
///
/// 예: distance("kitten", "sitting") = 3
///   kitten → sitten (k→s) → sittin (e→i) → sitting (삽입 g)
pub fn distance(a: []const u8, b: []const u8) usize {
    // 빈 문자열 처리: 한쪽이 비면 다른 쪽 길이가 곧 거리
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    // 짧은 쪽을 열(column)로 사용하여 메모리 절감
    const short = if (a.len <= b.len) a else b;
    const long = if (a.len <= b.len) b else a;

    // 스택 버퍼: 256자 이하면 힙 할당 없이 처리
    var stack_buf: [256]usize = undefined;
    var row: []usize = undefined;

    if (short.len + 1 <= stack_buf.len) {
        row = stack_buf[0 .. short.len + 1];
    } else {
        // 256자 초과 식별자는 실무에서 거의 없으므로 매칭 대상에서 제외
        return std.math.maxInt(usize);
    }

    // row[j] = distance(long[0..0], short[0..j]) = j (초기값: 빈 문자열에서 삽입)
    for (row, 0..) |*cell, j| {
        cell.* = j;
    }

    // DP: long의 각 문자에 대해 row를 갱신
    for (long) |lc| {
        var prev = row[0]; // 대각선 위 값 (이전 행의 j-1)
        row[0] += 1; // row[0] = i+1 (short가 빈 문자열일 때의 거리)

        for (short, 1..) |sc, j| {
            const delete = row[j] + 1; // long[i] 삭제
            const insert = row[j - 1] + 1; // short[j] 삽입
            const substitute = prev + @as(usize, if (lc == sc) 0 else 1); // 치환 (같으면 0)
            prev = row[j]; // 다음 반복의 대각선 값을 저장
            row[j] = @min(delete, @min(insert, substitute));
        }
    }

    return row[short.len];
}

/// 후보 목록에서 target과 가장 유사한 문자열을 찾는다.
///
/// max_distance 이내의 후보 중 가장 거리가 짧은 것을 반환한다.
/// 적합한 후보가 없으면 null을 반환한다.
///
/// 예: closestMatch("reqact", &.{"react", "redux", "vue"}, 3) → "react"
pub fn closestMatch(
    target: []const u8,
    candidates: []const []const u8,
    max_distance: usize,
) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = max_distance + 1;

    for (candidates) |candidate| {
        // 길이 차이가 max_distance를 초과하면 스킵 (빠른 필터링)
        const len_diff = if (target.len > candidate.len)
            target.len - candidate.len
        else
            candidate.len - target.len;
        if (len_diff > max_distance) continue;

        const d = distance(target, candidate);
        if (d < best_dist) {
            best_dist = d;
            best = candidate;
        }
    }

    return best;
}

/// "Did you mean 'X'?" 형식의 제안 문자열을 생성한다.
///
/// 적합한 후보가 없으면 null을 반환한다.
/// 반환된 문자열은 caller가 allocator.free()로 해제해야 한다.
///
/// 예: didYouMean(alloc, "reqact", &.{"react", "vue"})
///   → "Did you mean 'react'?"
pub fn didYouMean(
    allocator: std.mem.Allocator,
    target: []const u8,
    candidates: []const []const u8,
) !?[]const u8 {
    const match = closestMatch(target, candidates, 3) orelse return null;
    return try std.fmt.allocPrint(allocator, "Did you mean '{s}'?", .{match});
}

// ─── 테스트 ───

test "distance: identical strings" {
    try std.testing.expectEqual(@as(usize, 0), distance("hello", "hello"));
}

test "distance: empty strings" {
    try std.testing.expectEqual(@as(usize, 0), distance("", ""));
    try std.testing.expectEqual(@as(usize, 5), distance("hello", ""));
    try std.testing.expectEqual(@as(usize, 5), distance("", "hello"));
}

test "distance: single character difference" {
    try std.testing.expectEqual(@as(usize, 1), distance("cat", "bat")); // 치환
    try std.testing.expectEqual(@as(usize, 1), distance("cat", "cats")); // 삽입
    try std.testing.expectEqual(@as(usize, 1), distance("cats", "cat")); // 삭제
}

test "distance: classic example — kitten/sitting" {
    try std.testing.expectEqual(@as(usize, 3), distance("kitten", "sitting"));
}

test "distance: completely different" {
    try std.testing.expectEqual(@as(usize, 3), distance("abc", "xyz"));
}

test "distance: real-world typos" {
    try std.testing.expectEqual(@as(usize, 1), distance("react", "reqct")); // 탈자
    try std.testing.expectEqual(@as(usize, 2), distance("react-dom", "react-dmo")); // 전치
    try std.testing.expectEqual(@as(usize, 1), distance("lodash", "lodas")); // 끝 누락
}

test "closestMatch: finds best candidate" {
    const candidates = &[_][]const u8{ "react", "redux", "vue", "angular" };
    const result = closestMatch("reqact", candidates, 3);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("react", result.?);
}

test "closestMatch: returns null when too far" {
    const candidates = &[_][]const u8{ "react", "vue" };
    const result = closestMatch("completely_different_name", candidates, 3);
    try std.testing.expect(result == null);
}

test "closestMatch: exact match returns distance 0" {
    const candidates = &[_][]const u8{ "foo", "bar", "baz" };
    const result = closestMatch("bar", candidates, 3);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("bar", result.?);
}

test "didYouMean: formats suggestion" {
    const result = try didYouMean(std.testing.allocator, "reqact", &.{ "react", "vue" });
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("Did you mean 'react'?", result.?);
}

test "didYouMean: returns null when no match" {
    const result = try didYouMean(std.testing.allocator, "zzzzzzz", &.{ "react", "vue" });
    try std.testing.expect(result == null);
}
