//! Code-point 집합 + astral→surrogate-pair 분해 (#3509 핵심 조각).
//!
//! regexpu-core / regenerate 의 `encodeSurrogateRange` 와 동형:
//! astral code-point range 를 ES5-safe surrogate-pair 조각들로 분해한다.
//! 외부 Unicode 데이터 불필요 — 순수 결정론 알고리즘.

const std = @import("std");

pub const Range = struct { min: u32, max: u32 }; // inclusive

/// surrogate 조각: high∈[hi_min,hi_max] 뒤 low∈[lo_min,lo_max].
/// hi_min==hi_max 면 `\uHi`, 아니면 `[\uHi_min-\uHi_max]`.
/// lo_min==lo_max 면 `\uLo`, 아니면 `[\uLo_min-\uLo_max]`.
pub const Piece = struct { hi_min: u32, hi_max: u32, lo_min: u32, lo_max: u32 };

pub const CodePointSet = struct {
    ranges: std.ArrayList(Range) = .empty,

    pub fn deinit(self: *CodePointSet, a: std.mem.Allocator) void {
        self.ranges.deinit(a);
    }

    pub fn addRange(self: *CodePointSet, a: std.mem.Allocator, min: u32, max: u32) !void {
        if (min > max) return;
        try self.ranges.append(a, .{ .min = min, .max = max });
    }

    pub fn addOne(self: *CodePointSet, a: std.mem.Allocator, cp: u32) !void {
        try self.ranges.append(a, .{ .min = cp, .max = cp });
    }

    pub fn isEmpty(self: *const CodePointSet) bool {
        return self.ranges.items.len == 0;
    }

    /// 정렬 + 중첩/인접(max+1==next.min) range 병합.
    pub fn normalize(self: *CodePointSet, a: std.mem.Allocator) !void {
        const rs = self.ranges.items;
        if (rs.len <= 1) return;
        std.mem.sort(Range, rs, {}, struct {
            fn lt(_: void, x: Range, y: Range) bool {
                return x.min < y.min or (x.min == y.min and x.max < y.max);
            }
        }.lt);
        var merged: std.ArrayList(Range) = .empty;
        errdefer merged.deinit(a);
        var cur = rs[0];
        for (rs[1..]) |r| {
            // 인접/중첩 — r.min 이 cur.max+1 이하 (cur.max==maxInt 방어).
            if (r.min <= cur.max or (cur.max != std.math.maxInt(u32) and r.min == cur.max + 1)) {
                if (r.max > cur.max) cur.max = r.max;
            } else {
                try merged.append(a, cur);
                cur = r;
            }
        }
        try merged.append(a, cur);
        self.ranges.deinit(a);
        self.ranges = merged;
    }

    pub fn items(self: *const CodePointSet) []const Range {
        return self.ranges.items;
    }

    /// [0, 0x10FFFF] 전체 대비 여집합을 새 set 으로 반환 (regexpu
    /// `UNICODE_SET.clone().remove(set)` 와 동형). 호출자가 deinit.
    pub fn complement(self: *CodePointSet, a: std.mem.Allocator) !CodePointSet {
        try self.normalize(a);
        var out = CodePointSet{};
        errdefer out.deinit(a);
        var next: u32 = 0;
        for (self.ranges.items) |r| {
            if (r.min > next) try out.addRange(a, next, r.min - 1);
            if (r.max == 0x10FFFF) return out; // 더 이상 gap 없음
            next = r.max + 1;
        }
        try out.addRange(a, next, 0x10FFFF);
        return out;
    }
};

/// astral codepoint(≥0x10000) → UTF-16 surrogate pair. 표준 ECMA-262 공식.
/// regexp 모듈 내 단일 출처 (transform.pushSurrogate 도 이것을 사용).
pub fn splitSurrogatePair(cp: u32) struct { hi: u32, lo: u32 } {
    const v = cp - 0x10000;
    return .{ .hi = 0xD800 + (v >> 10), .lo = 0xDC00 + (v & 0x3FF) };
}

/// astral range [lo,hi] (둘 다 0x10000..0x10FFFF) → surrogate 조각들.
/// regenerate 알고리즘: 시작/끝 부분 low 행 + 가운데 full-low 블록.
pub fn encodeSurrogateRange(
    lo: u32,
    hi: u32,
    out: *std.ArrayList(Piece),
    a: std.mem.Allocator,
) !void {
    std.debug.assert(lo >= 0x10000 and hi <= 0x10FFFF and lo <= hi);
    const s1 = splitSurrogatePair(lo);
    const s2 = splitSurrogatePair(hi);
    const h1 = s1.hi;
    const l1 = s1.lo;
    const h2 = s2.hi;
    const l2 = s2.lo;

    if (h1 == h2) {
        try out.append(a, .{ .hi_min = h1, .hi_max = h1, .lo_min = l1, .lo_max = l2 });
        return;
    }

    const lo_full = (l1 == 0xDC00); // 시작이 low 행 전체 → mid 로 흡수
    const hi_full = (l2 == 0xDFFF); // 끝이 low 행 전체 → mid 로 흡수

    if (!lo_full) {
        try out.append(a, .{ .hi_min = h1, .hi_max = h1, .lo_min = l1, .lo_max = 0xDFFF });
    }
    const mid_lo: u32 = if (lo_full) h1 else h1 + 1;
    const mid_hi: u32 = if (hi_full) h2 else h2 - 1;
    if (mid_lo <= mid_hi) {
        try out.append(a, .{ .hi_min = mid_lo, .hi_max = mid_hi, .lo_min = 0xDC00, .lo_max = 0xDFFF });
    }
    if (!hi_full) {
        try out.append(a, .{ .hi_min = h2, .hi_max = h2, .lo_min = 0xDC00, .lo_max = l2 });
    }
}
