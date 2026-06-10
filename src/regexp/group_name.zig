//! ES regex group name 의 canonical (escape-decoded) 비교/디코드 (#4201).
//!
//! 그룹 이름은 `\uHHHH`(surrogate pair 포함) / `\u{...}` escape 를 허용하고,
//! 스펙상 이름의 정체성은 **디코드된 코드포인트 시퀀스**다 — `(?<y>)` 와
//! `(?<y>)` 는 같은 이름. raw byte 비교는 escape 표기가 섞이면
//! dedup(중복 키 객체)/`$<name>` 매칭/파서 중복 검증이 전부 어긋난다.
//!
//! 사용처: regexp/parser.zig (중복 검증) · regexp/transform.zig (\k 해석) ·
//! transformer/regex_lower.zig ($<name> 재작성) · transformer/node_dispatch.zig
//! (groups map dedup + canonical key emit).

const std = @import("std");

/// raw 표기에서 다음 코드포인트를 디코드. `\uHHHH`(상위 surrogate 면 후속
/// `\uHHHH` 와 pair 결합) / `\u{...}` / raw UTF-8 모두 처리.
/// 잘못된 시퀀스면 null — 호출자는 raw-byte 동작으로 폴백한다 (이름은 이미
/// 파서 검증을 통과한 상태라 실전에선 도달하지 않는 방어선).
fn nextCodepoint(s: []const u8, i: *usize) ?u21 {
    if (s[i.*] == '\\' and i.* + 1 < s.len and s[i.* + 1] == 'u') {
        var j = i.* + 2;
        if (j < s.len and s[j] == '{') {
            j += 1;
            const hex_start = j;
            var cp: u32 = 0;
            while (j < s.len and s[j] != '}') : (j += 1) {
                const d = std.fmt.charToDigit(s[j], 16) catch return null;
                cp = cp * 16 + d;
                if (cp > 0x10FFFF) return null;
            }
            if (j >= s.len or j == hex_start) return null;
            i.* = j + 1;
            return @intCast(cp);
        }
        if (j + 4 > s.len) return null;
        var cp: u32 = 0;
        for (s[j .. j + 4]) |c| {
            const d = std.fmt.charToDigit(c, 16) catch return null;
            cp = cp * 16 + d;
        }
        i.* = j + 4;
        // 상위 surrogate + 후속 \uDC00..\uDFFF → astral 코드포인트로 결합.
        if (cp >= 0xD800 and cp <= 0xDBFF and i.* + 6 <= s.len and
            s[i.*] == '\\' and s[i.* + 1] == 'u' and s[i.* + 2] != '{')
        {
            var lo: u32 = 0;
            var ok = true;
            for (s[i.* + 2 .. i.* + 6]) |c| {
                const d = std.fmt.charToDigit(c, 16) catch {
                    ok = false;
                    break;
                };
                lo = lo * 16 + d;
            }
            if (ok and lo >= 0xDC00 and lo <= 0xDFFF) {
                i.* += 6;
                return @intCast(0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00));
            }
        }
        return @intCast(cp);
    }
    const len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch return null;
    if (i.* + len > s.len) return null;
    const cp = std.unicode.utf8Decode(s[i.* .. i.* + len]) catch return null;
    i.* += len;
    return cp;
}

/// 두 raw 표기가 canonical 하게 같은 그룹 이름인가 (코드포인트 시퀀스 비교).
/// 어느 쪽이든 디코드 실패 시 raw-byte 비교로 폴백.
pub fn eqlCanonical(a: []const u8, b: []const u8) bool {
    var ia: usize = 0;
    var ib: usize = 0;
    while (true) {
        const a_end = ia >= a.len;
        const b_end = ib >= b.len;
        if (a_end and b_end) return true;
        if (a_end != b_end) return false;
        const ca = nextCodepoint(a, &ia) orelse return std.mem.eql(u8, a, b);
        const cb = nextCodepoint(b, &ib) orelse return std.mem.eql(u8, a, b);
        if (ca != cb) return false;
    }
}

/// raw 표기를 canonical UTF-8 로 디코드해 out 에 append (groups map 키 emit 용).
/// escape 없는 이름은 byte-identical. 디코드/인코드 실패 구간은 raw 그대로 복사
/// (lone surrogate escape 등 — JS string 에선 여전히 유효한 표기).
pub fn appendCanonical(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        const start = i;
        const cp = nextCodepoint(raw, &i) orelse {
            try out.appendSlice(allocator, raw[start..]);
            return;
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch {
            try out.appendSlice(allocator, raw[start..i]);
            continue;
        };
        try out.appendSlice(allocator, buf[0..n]);
    }
}

// ─── 테스트 ───

const testing = std.testing;

test "eqlCanonical: escape 표기 동치" {
    try testing.expect(eqlCanonical("y", "\\u0079"));
    try testing.expect(eqlCanonical("\\u0079", "\\u{79}"));
    try testing.expect(eqlCanonical("year", "\\u0079ear"));
    try testing.expect(!eqlCanonical("y", "\\u007A")); // z
    try testing.expect(!eqlCanonical("y", "yy"));
    try testing.expect(eqlCanonical("한", "\\uD55C"));
    // astral: 𝑦 (U+1D466) = 𝑦 pair = \u{1D466}
    try testing.expect(eqlCanonical("\\uD835\\uDC66", "\\u{1D466}"));
    try testing.expect(eqlCanonical("𝑦", "\\uD835\\uDC66"));
}

test "eqlCanonical: 디코드 실패 시 raw 폴백" {
    try testing.expect(eqlCanonical("\\uZZZZ", "\\uZZZZ"));
    try testing.expect(!eqlCanonical("\\uZZZZ", "y"));
}

test "appendCanonical: escape → UTF-8, plain 은 byte-identical" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try appendCanonical(testing.allocator, &out, "\\u0079ear");
    try testing.expectEqualStrings("year", out.items);
    out.clearRetainingCapacity();
    try appendCanonical(testing.allocator, &out, "plain한");
    try testing.expectEqualStrings("plain한", out.items);
    out.clearRetainingCapacity();
    try appendCanonical(testing.allocator, &out, "\\u{1D466}");
    try testing.expectEqualStrings("𝑦", out.items);
}
