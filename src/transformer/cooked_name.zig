//! escape-보존 JS string 표기의 cooked 비교 (#4231/#4216 공용).
//!
//! string escape 전 문법(\n \t … \xHH \uHHHH[pair] \u{...} NonEscape identity,
//! LineContinuation 소거)을 디코드해 UTF-16 code unit 시퀀스로 비교한다.
//! 사용처: const-enum 멤버 lookup(enum.zig), replace $<name> 재작성의
//! replacement-side 이름(regex_lower — string escape 표기 \x79 등도 그룹
//! 이름과 동일 cook).

const std = @import("std");

/// escape-보존 표기에서 다음 cooked 코드포인트를 디코드 (#4231).
/// string escape (\n \t \r \b \f \v \0 \xHH \uHHHH[pair] \u{...}
/// NonEscape identity, LineContinuation=문자 없음) + raw UTF-8.
/// 디코드 실패 시 null — 호출자는 raw eql 폴백.
pub fn nextCookedCp(t: []const u8, i: *usize) ?u21 {
    const c = t[i.*];
    if (c != '\\') {
        const len = std.unicode.utf8ByteSequenceLength(c) catch return null;
        if (i.* + len > t.len) return null;
        const cp = std.unicode.utf8Decode(t[i.* .. i.* + len]) catch return null;
        i.* += len;
        return cp;
    }
    if (i.* + 1 >= t.len) return null;
    const e = t[i.* + 1];
    i.* += 2;
    switch (e) {
        'n' => return '\n',
        't' => return '\t',
        'r' => return '\r',
        'b' => return 0x08,
        'f' => return 0x0C,
        'v' => return 0x0B,
        '0' => {
            // \0 + digit 은 legacy octal — strict 금지, 보수적으로 실패 처리.
            if (i.* < t.len and t[i.*] >= '0' and t[i.*] <= '9') return null;
            return 0;
        },
        'x' => {
            if (i.* + 2 > t.len) return null;
            var cp: u21 = 0;
            for (t[i.* .. i.* + 2]) |h| {
                const d = std.fmt.charToDigit(h, 16) catch return null;
                cp = cp * 16 + d;
            }
            i.* += 2;
            return cp;
        },
        'u' => {
            if (i.* < t.len and t[i.*] == '{') {
                var j = i.* + 1;
                const hs = j;
                var cp: u32 = 0;
                while (j < t.len and t[j] != '}') : (j += 1) {
                    const d = std.fmt.charToDigit(t[j], 16) catch return null;
                    cp = cp * 16 + d;
                    if (cp > 0x10FFFF) return null;
                }
                if (j >= t.len or j == hs) return null;
                i.* = j + 1;
                return @intCast(cp);
            }
            if (i.* + 4 > t.len) return null;
            var cp: u32 = 0;
            for (t[i.* .. i.* + 4]) |h| {
                const d = std.fmt.charToDigit(h, 16) catch return null;
                cp = cp * 16 + d;
            }
            i.* += 4;
            if (cp >= 0xD800 and cp <= 0xDBFF and i.* + 6 <= t.len and
                t[i.*] == '\\' and t[i.* + 1] == 'u' and t[i.* + 2] != '{')
            {
                var lo: u32 = 0;
                var ok = true;
                for (t[i.* + 2 .. i.* + 6]) |h| {
                    const d = std.fmt.charToDigit(h, 16) catch {
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
        },
        '1', '2', '3', '4', '5', '6', '7' => {
            // legacy octal escape — TS 는 거부(TS1487)하나 우리 파서가 수용하는
            // 입력에서 identity 오쿡 방지: 보수적으로 실패 → raw 폴백.
            return null;
        },
        '\n', '\r' => {
            // LineContinuation: cooked 기여 없음 — CRLF pair skip 후 다음 문자.
            if (e == '\r' and i.* < t.len and t[i.*] == '\n') i.* += 1;
            if (i.* >= t.len) return null;
            return nextCookedCp(t, i);
        },
        else => {
            // NonEscapeCharacter: identity (\' \" \\ \` 포함, 멀티바이트 lead 도 그대로)
            const len = std.unicode.utf8ByteSequenceLength(e) catch return null;
            if (i.* - 1 + len > t.len) return null;
            const cp = std.unicode.utf8Decode(t[i.* - 1 .. i.* - 1 + len]) catch return null;
            i.* += len - 1;
            return cp;
        },
    }
}

/// LineContinuation (`\` + LF/CR[LF]/U+2028/9) 연쇄를 소거 — cooked 기여 0.
/// end 검사 전에 호출해야 trailing continuation ('q\<LF>' vs 'q') 이 정확.
pub fn skipLineContinuations(t: []const u8, i: *usize) void {
    while (i.* + 1 < t.len and t[i.*] == '\\') {
        const n1 = t[i.* + 1];
        if (n1 == '\n') {
            i.* += 2;
        } else if (n1 == '\r') {
            i.* += 2;
            if (i.* < t.len and t[i.*] == '\n') i.* += 1;
        } else if (n1 == 0xe2 and i.* + 4 <= t.len and
            t[i.* + 2] == 0x80 and (t[i.* + 3] == 0xa8 or t[i.* + 3] == 0xa9))
        {
            i.* += 4;
        } else break;
    }
}

pub const CookedIter = struct {
    t: []const u8,
    i: usize = 0,
    /// astral cp 의 low surrogate 보류분 — UTF-16 code unit 단위 비교용.
    pending_lo: ?u21 = null,

    /// u21 범위 밖은 불가하므로 surrogate-범위 위 값으로 디코드 실패 표시.
    const error_marker: u21 = 0x1FFFFF;

    /// 다음 UTF-16 code unit. 혼합 escape 표기(`\uD83D\u{DE00}` vs 😀)도
    /// unit 시퀀스로는 동일해져 정확 비교 (#4231 리뷰).
    fn next(self: *@This()) ?u21 {
        if (self.pending_lo) |lo| {
            self.pending_lo = null;
            return lo;
        }
        skipLineContinuations(self.t, &self.i);
        if (self.i >= self.t.len) return null;
        const cp = nextCookedCp(self.t, &self.i) orelse return error_marker;
        if (cp > 0xFFFF) {
            self.pending_lo = @intCast(0xDC00 + ((cp - 0x10000) & 0x3FF));
            return @intCast(0xD800 + ((cp - 0x10000) >> 10));
        }
        return cp;
    }

    fn atEnd(self: *@This()) bool {
        if (self.pending_lo != null) return false;
        skipLineContinuations(self.t, &self.i);
        return self.i >= self.t.len;
    }
};

/// 두 escape-보존 이름이 cooked(UTF-16 unit 시퀀스) 기준으로 같은가 (#4231).
/// 디코드 실패 시 raw-byte 비교 폴백 (이전 동작 보존 방어선).
/// NOTE: escape 디코더는 string_escape.decodeUnicodeHexEscape /
/// regexp/group_name.zig nextCodepoint 와 의도적 별도 구현 — 여기는 string
/// escape 전 문법(superset)이 필요하다. escape 처리 수정 시 셋을 교차 점검.
pub fn eql(a: []const u8, b: []const u8) bool {
    // 공통 케이스 fast-path: byte-identical 이름 (escape 무관하게 동일 cooked).
    if (std.mem.eql(u8, a, b)) return true;
    var xa = CookedIter{ .t = a };
    var xb = CookedIter{ .t = b };
    while (true) {
        const ae = xa.atEnd();
        const be = xb.atEnd();
        if (ae and be) return true;
        if (ae != be) return false;
        const ua = xa.next() orelse return false;
        const ub = xb.next() orelse return false;
        if (ua == CookedIter.error_marker or ub == CookedIter.error_marker)
            return std.mem.eql(u8, a, b);
        if (ua != ub) return false;
    }
}

// ─── 테스트 ───

const testing = std.testing;

test "eql: string-escape 표기 동치 (\\x79/\\u0079/y)" {
    try testing.expect(eql("y", "\\x79"));
    try testing.expect(eql("\\x79", "\\u0079"));
    try testing.expect(!eql("\\x7A", "y"));
}

test "eql: 혼합 surrogate 표기 — UTF-16 unit 시퀀스" {
    try testing.expect(eql("\\uD835\\uDC66", "\\u{1D466}"));
    try testing.expect(eql("\\uD835\\u{DC66}", "\\u{1D466}"));
}

test "eql: trailing line continuation 소거" {
    try testing.expect(eql("q\\\n", "q"));
}

test "eql: legacy octal 은 raw 폴백 (오쿡 금지)" {
    try testing.expect(!eql("\\1", "\\x01"));
    try testing.expect(eql("\\1", "\\1"));
}
