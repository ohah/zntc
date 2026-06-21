//! codec IO 원시함수 — 디스크 캐시(#4438) codec 들의 공유 직렬화/역직렬화 빌딩블록.
//!
//! `ast_codec`(PR1) / `semantic_codec`(PR2/PR3) / `module_codec`(PR4) 가 각자 들고 있던
//! byte-identical 한 `putU32`/`putU64`/`putBytes` + bounds-checked `Reader` 를 한 곳으로 모은다.
//! 특히 `Reader.take` 의 오버플로우-guard 는 손상된 length-prefix 에 대한 유일한 방어선이라
//! 사본이 흩어지면 한쪽만 고쳐지는 drift 가 보안/정합성 구멍이 된다 — 단일 지점화.
//!
//! 모든 codec 은 host endian/정렬 native 전제(로컬 캐시). 검증 실패는 항상 error(fail-safe).

const std = @import("std");

/// `Reader` 가 낼 수 있는 유일한 error. 각 codec 의 Error 집합은 이 멤버를 포함하므로(전부
/// `Truncated` 보유) `try` 로 자동 coercion 된다.
pub const ReadError = error{Truncated};

// ── write ────────────────────────────────────────────────────────────────────

pub fn putU32(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) std.mem.Allocator.Error!void {
    try buf.appendSlice(alloc, std.mem.asBytes(&v));
}
pub fn putU64(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u64) std.mem.Allocator.Error!void {
    try buf.appendSlice(alloc, std.mem.asBytes(&v));
}
/// length-prefixed 바이트열: `[len:u32][bytes]`.
pub fn putBytes(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, b: []const u8) std.mem.Allocator.Error!void {
    try putU32(buf, alloc, @intCast(b.len));
    try buf.appendSlice(alloc, b);
}

// ── read ─────────────────────────────────────────────────────────────────────

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    /// 아직 읽지 않은 payload 바이트 수. count-prefix sanity 검증(엔트리당 최소 바이트 ×
    /// count > remaining 이면 손상)에 쓴다 — HashMap 등 `ensureTotalCapacity(count)` 전에
    /// 거대 count 를 거부해 ceilPowerOfTwo unreachable panic 을 막는다(fail-safe).
    pub fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn take(self: *Reader, n: usize) ReadError![]const u8 {
        // checked add — 손상된 length-prefix 가 pos+n 을 오버플로우시켜 경계검사를 우회하는 것 방지.
        const end = std.math.add(usize, self.pos, n) catch return error.Truncated;
        if (end > self.buf.len) return error.Truncated;
        const b = self.buf[self.pos..][0..n];
        self.pos = end;
        return b;
    }
    pub fn u32v(self: *Reader) ReadError!u32 {
        return std.mem.bytesToValue(u32, (try self.take(4))[0..4]);
    }
    /// `putBytes` 의 짝 — `[len:u32][bytes]` 를 읽어 슬라이스 반환(`buf` 를 가리킴, 복사 아님).
    pub fn bytes(self: *Reader) ReadError![]const u8 {
        const n = try self.u32v();
        return self.take(n);
    }
    pub fn byte(self: *Reader) ReadError!u8 {
        return (try self.take(1))[0];
    }
};

// ── tests ──────────────────────────────────────────────────────────────────────

test "codec_io: write/read round-trip" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try putU32(&buf, alloc, 0xDEADBEEF);
    try putU64(&buf, alloc, 0x0123456789ABCDEF);
    try putBytes(&buf, alloc, "hello");
    try putBytes(&buf, alloc, ""); // 빈 슬라이스 경계

    var r = Reader{ .buf = buf.items };
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try r.u32v());
    // u64 는 codec 들의 checksum 처럼 take(8)+bytesToValue 로 읽는다(Reader 에 u64v 미제공).
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), std.mem.bytesToValue(u64, (try r.take(8))[0..8]));
    try testing.expectEqualStrings("hello", try r.bytes());
    try testing.expectEqualStrings("", try r.bytes());
    try testing.expectError(error.Truncated, r.byte()); // 소진 후 추가 read
}

test "codec_io: take 경계/오버플로우 거부 (fail-safe)" {
    const testing = std.testing;
    // 짧은 버퍼: 길이 prefix 가 실제보다 큰 경우 → Truncated (OOB 슬라이스 금지).
    {
        var r = Reader{ .buf = &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF } }; // len=0xFFFFFFFF
        try testing.expectError(error.Truncated, r.bytes());
    }
    // pos+n 오버플로우 직접 검증: pos 를 끝 근처로 두고 거대한 take.
    {
        var r = Reader{ .buf = &[_]u8{ 1, 2, 3 }, .pos = 2 };
        try testing.expectError(error.Truncated, r.take(std.math.maxInt(usize)));
        try testing.expectEqual(@as(usize, 2), r.pos); // 실패 시 pos 불변
    }
    // u32v/u64v 가 4/8 바이트 미만에서 Truncated.
    {
        var r = Reader{ .buf = &[_]u8{ 1, 2, 3 } };
        try testing.expectError(error.Truncated, r.u32v());
    }
}
