//! codepoint_set.zig 테스트 — #3509 핵심 조각.
//! regexpu/regenerate `encodeSurrogateRange` 동형 검증.

const std = @import("std");
const cps = @import("codepoint_set.zig");

test "CodePointSet normalize — 정렬 + 인접/중첩 병합" {
    const a = std.testing.allocator;
    var s = cps.CodePointSet{};
    defer s.deinit(a);
    try s.addRange(a, 0x41, 0x5A); // A-Z
    try s.addOne(a, 0x30); // 0
    try s.addRange(a, 0x5B, 0x60); // 인접 → A-` 로 병합
    try s.addRange(a, 0x45, 0x50); // 중첩
    try s.normalize(a);
    const r = s.items();
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqual(@as(u32, 0x30), r[0].min);
    try std.testing.expectEqual(@as(u32, 0x30), r[0].max);
    try std.testing.expectEqual(@as(u32, 0x41), r[1].min);
    try std.testing.expectEqual(@as(u32, 0x60), r[1].max);
}

test "CodePointSet complement — [0,0x10FFFF] 여집합 (#3513)" {
    const a = std.testing.allocator;
    var s = cps.CodePointSet{};
    defer s.deinit(a);
    try s.addOne(a, 0x61); // {a}
    var c = try s.complement(a);
    defer c.deinit(a);
    const r = c.items();
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqual(@as(u32, 0), r[0].min);
    try std.testing.expectEqual(@as(u32, 0x60), r[0].max);
    try std.testing.expectEqual(@as(u32, 0x62), r[1].min);
    try std.testing.expectEqual(@as(u32, 0x10FFFF), r[1].max);
}

test "CodePointSet complement — 빈 집합 → 전체 / 전체 → 빈" {
    const a = std.testing.allocator;
    {
        var s = cps.CodePointSet{};
        defer s.deinit(a);
        var c = try s.complement(a);
        defer c.deinit(a);
        try std.testing.expectEqual(@as(usize, 1), c.items().len);
        try std.testing.expectEqual(@as(u32, 0), c.items()[0].min);
        try std.testing.expectEqual(@as(u32, 0x10FFFF), c.items()[0].max);
    }
    {
        var s = cps.CodePointSet{};
        defer s.deinit(a);
        try s.addRange(a, 0, 0x10FFFF);
        var c = try s.complement(a);
        defer c.deinit(a);
        try std.testing.expectEqual(@as(usize, 0), c.items().len);
    }
}

fn expectPieces(lo: u32, hi: u32, expected: []const cps.Piece) !void {
    const a = std.testing.allocator;
    var out: std.ArrayList(cps.Piece) = .empty;
    defer out.deinit(a);
    try cps.encodeSurrogateRange(lo, hi, &out, a);
    try std.testing.expectEqualSlices(cps.Piece, expected, out.items);
}

test "encodeSurrogateRange — 동일 high surrogate (1F600-1F64F)" {
    try expectPieces(0x1F600, 0x1F64F, &.{
        .{ .hi_min = 0xD83D, .hi_max = 0xD83D, .lo_min = 0xDE00, .lo_max = 0xDE4F },
    });
}

test "encodeSurrogateRange — 단일 astral codepoint (1F600)" {
    try expectPieces(0x1F600, 0x1F600, &.{
        .{ .hi_min = 0xD83D, .hi_max = 0xD83D, .lo_min = 0xDE00, .lo_max = 0xDE00 },
    });
}

test "encodeSurrogateRange — high 교차, 부분 경계 (1F600-1F900)" {
    try expectPieces(0x1F600, 0x1F900, &.{
        .{ .hi_min = 0xD83D, .hi_max = 0xD83D, .lo_min = 0xDE00, .lo_max = 0xDFFF },
        .{ .hi_min = 0xD83E, .hi_max = 0xD83E, .lo_min = 0xDC00, .lo_max = 0xDD00 },
    });
}

test "encodeSurrogateRange — 전체 astral (10000-10FFFF) 전 low 경계 fold → 1 piece" {
    try expectPieces(0x10000, 0x10FFFF, &.{
        .{ .hi_min = 0xD800, .hi_max = 0xDBFF, .lo_min = 0xDC00, .lo_max = 0xDFFF },
    });
}

test "encodeSurrogateRange — mid 블록 포함 (1F600-2F800)" {
    // lo 1F600: c=0xF600 H=0xD83D L=0xDE00
    // hi 2F800: c=0x1F800 H=0xD800+(0x1F800>>10)=0xD87E L=0xDC00+(0x1F800&0x3FF)=0xDC00
    try expectPieces(0x1F600, 0x2F800, &.{
        .{ .hi_min = 0xD83D, .hi_max = 0xD83D, .lo_min = 0xDE00, .lo_max = 0xDFFF },
        .{ .hi_min = 0xD83E, .hi_max = 0xD87D, .lo_min = 0xDC00, .lo_max = 0xDFFF },
        .{ .hi_min = 0xD87E, .hi_max = 0xD87E, .lo_min = 0xDC00, .lo_max = 0xDC00 },
    });
}
