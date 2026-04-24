//! Pointer-stable segmented list. `std.SegmentedList` 와 유사하지만
//! shelf pointer 배열 자체가 **고정 크기** 라 append 가 절대 shelf pointer
//! realloc 을 일으키지 않는다.
//!
//! ## 배경 (#1779 worker race-safety)
//!
//! `std.SegmentedList(T, 0)` 은 `dynamic_segments: ArrayListUnmanaged([*]T)`
//! 로 shelf pointer 를 보관한다. append 시 shelf 수 증가 → ArrayListUnmanaged
//! grow → `dynamic_segments.items` 배열이 realloc. 그동안 worker thread 가
//! `at(i)` 호출로 `dynamic_segments[shelf_idx]` 를 읽고 있으면 stale pointer
//! → segfault (CI 에서 `Stress: 15 modules` 테스트로 재현).
//!
//! 즉 `std.SegmentedList` 는 **chunk 내부 pointer 는 stable** 하지만
//! **shelf pointer 배열 자체가 unstable**. #1779 PR #3 의 "append 가 기존
//! pointer 를 무효화하지 않는다" invariant 는 chunk 내부에만 성립.
//!
//! ## 해결
//!
//! `shelves` 를 고정 크기 array `[MAX_SHELVES]?[*]T` 로 선언. Append 가
//! 새 shelf alloc 시 해당 slot 에 pointer write 하지만 배열 자체는 realloc
//! 안 함. 다른 worker 가 이미 확인된 shelf 를 읽는 것은 완전히 안전.
//!
//! `MAX_SHELVES = 32` → shelf i 의 size = 2^i items. 전체 capacity =
//! 2^32 - 1 ≈ 4.3B items. 메모리 overhead 32 * @sizeOf(?[*]T) = 256 bytes
//! (pointer 만, chunk 는 lazy alloc).
//!
//! ## Race-safety 증명
//!
//! Worker A 가 `at(i)` 호출:
//! 1. `self.len` 읽음 (i < len 이 caller invariant)
//! 2. `shelfIndex(i)` 계산 (const func)
//! 3. `self.shelves[shelf_idx]` pointer 읽음 — 이 slot 이 이미 non-null 임은
//!    `i < len` 에서 보장 (len 증가 전 shelf 할당이 완료).
//! 4. `shelves[shelf_idx].?[inner]` access.
//!
//! Main 이 append 해도:
//! - 새 shelf alloc 은 **다른 slot** 에 write → A 가 읽는 slot 영향 없음.
//! - `self.len += 1` 는 A 가 이미 len 을 읽은 후라 무관 (happens-after).
//!
//! 핵심 invariant: **append 는 i < len 인 모든 i 에 대해 shelf slot 이
//! 이미 write 되었음을 보장한 후에야 len 을 증가시킨다**.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn StableSegmentedList(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const MAX_SHELVES: ShelfIndex = 32;
        const ShelfIndex = u6;

        shelves: [MAX_SHELVES]?[*]T = [_]?[*]T{null} ** MAX_SHELVES,
        len: usize = 0,

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (&self.shelves, 0..) |*shelf_opt, i| {
                if (shelf_opt.*) |ptr| {
                    const shelf_size = @as(usize, 1) << @intCast(i);
                    allocator.free(ptr[0..shelf_size]);
                    shelf_opt.* = null;
                }
            }
            self.len = 0;
        }

        pub fn append(self: *Self, allocator: Allocator, item: T) !void {
            const idx = self.len;
            const shelf_idx = shelfIndex(idx);
            if (shelf_idx >= MAX_SHELVES) return error.OutOfMemory;

            // Lazy shelf alloc (shelf 당 최대 1회). len 증가 전에 write 완료 → race-free.
            if (self.shelves[shelf_idx] == null) {
                const shelf_size = @as(usize, 1) << shelf_idx;
                const buf = try allocator.alloc(T, shelf_size);
                self.shelves[shelf_idx] = buf.ptr;
            }

            const inner = boxInShelf(idx, shelf_idx);
            self.shelves[shelf_idx].?[inner] = item;
            self.len += 1;
        }

        /// Index 기반 access. caller 는 `idx < count()` 확인 책임.
        pub fn at(self: anytype, idx: usize) AtType(@TypeOf(self)) {
            std.debug.assert(idx < self.len);
            const shelf_idx = shelfIndex(idx);
            const inner = boxInShelf(idx, shelf_idx);
            return &self.shelves[shelf_idx].?[inner];
        }

        pub fn count(self: Self) usize {
            return self.len;
        }

        pub const ConstIterator = struct {
            list: *const Self,
            index: usize,

            pub fn next(it: *ConstIterator) ?*const T {
                if (it.index >= it.list.len) return null;
                const p = it.list.at(it.index);
                it.index += 1;
                return p;
            }
        };

        pub fn constIterator(self: *const Self, start_index: usize) ConstIterator {
            return .{ .list = self, .index = start_index };
        }

        pub const Iterator = struct {
            list: *Self,
            index: usize,

            pub fn next(it: *Iterator) ?*T {
                if (it.index >= it.list.len) return null;
                const p = it.list.at(it.index);
                it.index += 1;
                return p;
            }
        };

        pub fn iterator(self: *Self, start_index: usize) Iterator {
            return .{ .list = self, .index = start_index };
        }

        fn AtType(comptime SelfType: type) type {
            if (@typeInfo(SelfType).pointer.is_const) return *const T;
            return *T;
        }

        inline fn shelfIndex(list_index: usize) ShelfIndex {
            // shelf i: list_index ∈ [2^i - 1, 2^(i+1) - 2]
            // i = floor(log2(list_index + 1))
            return @intCast(std.math.log2_int(usize, list_index + 1));
        }

        inline fn boxInShelf(list_index: usize, shelf_idx: ShelfIndex) usize {
            // inner = list_index - (2^shelf_idx - 1)
            return list_index + 1 - (@as(usize, 1) << shelf_idx);
        }
    };
}

// ============================================================
// Tests
// ============================================================

test "StableSegmentedList: basic append + at" {
    const allocator = std.testing.allocator;
    var list = StableSegmentedList(u32){};
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), list.count());

    try list.append(allocator, 10);
    try list.append(allocator, 20);
    try list.append(allocator, 30);

    try std.testing.expectEqual(@as(usize, 3), list.count());
    try std.testing.expectEqual(@as(u32, 10), list.at(0).*);
    try std.testing.expectEqual(@as(u32, 20), list.at(1).*);
    try std.testing.expectEqual(@as(u32, 30), list.at(2).*);
}

test "StableSegmentedList: pointer stability across many appends" {
    const allocator = std.testing.allocator;
    var list = StableSegmentedList(u32){};
    defer list.deinit(allocator);

    try list.append(allocator, 42);
    const ptr0 = list.at(0);
    try std.testing.expectEqual(@as(u32, 42), ptr0.*);

    // 여러 shelf 경계 넘는 append (shelves: 0→1→2→3→4→5→6→7→8→9 = 1023 items).
    var i: u32 = 1;
    while (i < 1024) : (i += 1) {
        try list.append(allocator, i);
    }

    // 초기 pointer 여전히 유효해야 함 — std.SegmentedList 는 이 시점에 realloc 일어남.
    try std.testing.expectEqual(@as(u32, 42), ptr0.*);
    try std.testing.expectEqual(@as(usize, 1024), list.count());
    try std.testing.expectEqual(@as(u32, 1023), list.at(1023).*);
}

test "StableSegmentedList: shelf index formula" {
    // shelf 0: idx 0
    // shelf 1: idx 1-2
    // shelf 2: idx 3-6
    // shelf 3: idx 7-14
    const L = StableSegmentedList(u8);
    try std.testing.expectEqual(@as(u6, 0), L.shelfIndex(0));
    try std.testing.expectEqual(@as(u6, 1), L.shelfIndex(1));
    try std.testing.expectEqual(@as(u6, 1), L.shelfIndex(2));
    try std.testing.expectEqual(@as(u6, 2), L.shelfIndex(3));
    try std.testing.expectEqual(@as(u6, 2), L.shelfIndex(6));
    try std.testing.expectEqual(@as(u6, 3), L.shelfIndex(7));
    try std.testing.expectEqual(@as(u6, 3), L.shelfIndex(14));
    try std.testing.expectEqual(@as(u6, 4), L.shelfIndex(15));
}

test "StableSegmentedList: iterator" {
    const allocator = std.testing.allocator;
    var list = StableSegmentedList(u32){};
    defer list.deinit(allocator);

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try list.append(allocator, i);
    }

    var it = list.constIterator(0);
    var expected: u32 = 0;
    while (it.next()) |v| : (expected += 1) {
        try std.testing.expectEqual(expected, v.*);
    }
    try std.testing.expectEqual(@as(u32, 100), expected);
}

test "StableSegmentedList: mutable iterator" {
    const allocator = std.testing.allocator;
    var list = StableSegmentedList(u32){};
    defer list.deinit(allocator);

    try list.append(allocator, 1);
    try list.append(allocator, 2);
    try list.append(allocator, 3);

    var it = list.iterator(0);
    while (it.next()) |p| {
        p.* *= 10;
    }

    try std.testing.expectEqual(@as(u32, 10), list.at(0).*);
    try std.testing.expectEqual(@as(u32, 20), list.at(1).*);
    try std.testing.expectEqual(@as(u32, 30), list.at(2).*);
}

// #1779 CI fail 의 정확한 reproduction: worker thread 가 at(i) 반복 read 하는 동안
// main thread 가 append 로 shelf grow 유발. std.SegmentedList 였으면 dynamic_segments
// 가 ArrayListUnmanaged realloc → reader 의 pointer stale → segfault 또는 value 불일치.
// StableSegmentedList 는 shelves 배열 고정이라 read 가 항상 안전해야 함.
test "StableSegmentedList: concurrent reader survives grower appends (race-safety)" {
    const allocator = std.testing.allocator;
    var list = StableSegmentedList(u64){};
    defer list.deinit(allocator);

    const N_INITIAL: usize = 100;
    const N_READERS: usize = 4;
    const FINAL_SIZE: usize = 10_000;

    // 초기 items — reader 가 이 slot 들을 불변으로 관찰.
    {
        var i: usize = 0;
        while (i < N_INITIAL) : (i += 1) {
            try list.append(allocator, @intCast(i));
        }
    }

    var stop = std.atomic.Value(bool).init(false);
    var mismatch = std.atomic.Value(bool).init(false);

    const readerFn = struct {
        fn run(l: *StableSegmentedList(u64), m: *std.atomic.Value(bool), s: *std.atomic.Value(bool)) void {
            while (!s.load(.acquire)) {
                var k: usize = 0;
                while (k < N_INITIAL) : (k += 1) {
                    const p = l.at(k);
                    if (p.* != @as(u64, @intCast(k))) {
                        m.store(true, .release);
                        return;
                    }
                }
                // busy-wait 회피 — graph_test.zig:935 parallelWorker 와 동일 패턴.
                std.Thread.yield() catch {};
            }
        }
    }.run;

    var readers: [N_READERS]std.Thread = undefined;
    for (&readers) |*r| {
        r.* = try std.Thread.spawn(.{}, readerFn, .{ &list, &mismatch, &stop });
    }

    // Main 이 동시에 append 로 shelf grow 유발. std.SegmentedList 였으면 이 시점에
    // dynamic_segments realloc 여러 번 → reader 의 shelf pointer stale.
    {
        var i: usize = N_INITIAL;
        while (i < FINAL_SIZE) : (i += 1) {
            try list.append(allocator, @intCast(i));
        }
    }

    stop.store(true, .release);
    for (&readers) |r| r.join();

    try std.testing.expect(!mismatch.load(.acquire));
    try std.testing.expectEqual(FINAL_SIZE, list.count());
    try std.testing.expectEqual(@as(u64, 0), list.at(0).*);
    try std.testing.expectEqual(@as(u64, FINAL_SIZE - 1), list.at(FINAL_SIZE - 1).*);
}
