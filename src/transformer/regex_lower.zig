//! Regex literal 다운레벨링 (#1387)
//!
//! esbuild 수준의 보수적 변환:
//!   - /s (dotAll, ES2018): `.` → `[\s\S]` 치환 + flag strip (완전 구현)
//!   - (?<name>...) (named capture, ES2018): `(?<name>` → `(`으로 strip
//!     → positional group으로만 보존. `match.groups` 객체는 포기.
//!     `\k<name>` named backreference 도 함께 `\N` (positional)으로 변환.
//!   - /y (sticky, ES2015): 미지원 타겟에서 flag strip (런타임 동작 변경 있음 — 경고)
//!
//! - `u` flag + `\u{...}` brace (ES2015): `\u{X}` → surrogate pair / BMP escape + `u` flag strip (#1388)
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser.go — visitRegExpLiteral / js_lexer regex scanner
//! - TC39 Annex B / sec-patterns

const std = @import("std");
const compat = @import("compat.zig");
const regexp = @import("../regexp/mod.zig");

pub const Options = struct {
    unsupported: compat.UnsupportedFeatures,
};

pub const Result = struct {
    /// 최종 regex literal 텍스트 (`/pattern/flags` 전체). 변환이 없으면 null.
    text: ?[]const u8,
    /// named capture group 이 있고 `regex_named_groups` strip 이 적용된 경우의
    /// (name → positional index) 매핑. 호출자가 `__wrapRegExp(re, {...})` 로 감싸는 데
    /// 사용. free 책임은 호출자. `name` 슬라이스는 호출자가 lower 에 전달한 raw
    /// 텍스트의 lifetime 에 의존 — owner 가 살아있는 동안만 유효.
    named_groups: ?[]const NamedGroupMapping = null,
};

/// regex literal 원본 텍스트(`/pattern/flags`)를 받아 변환이 필요하면 새 슬라이스를 반환.
/// 변환이 필요 없으면 `.text = null`.
///
/// 출력 버퍼는 `allocator`로 할당. 호출자가 AST string_table 등으로 복사할 책임.
pub fn lower(allocator: std.mem.Allocator, raw: []const u8, opts: Options) !Result {
    // 최소 `/x/` 이상.
    if (raw.len < 3 or raw[0] != '/') return .{ .text = null };

    // flags 분리: 마지막 '/' 이후가 flags.
    const last_slash = std.mem.lastIndexOfScalar(u8, raw, '/') orelse return .{ .text = null };
    if (last_slash == 0) return .{ .text = null };
    const pattern = raw[1..last_slash];
    const flags = raw[last_slash + 1 ..];

    const has_s = std.mem.indexOfScalar(u8, flags, 's') != null;
    const has_y = std.mem.indexOfScalar(u8, flags, 'y') != null;
    const has_u = std.mem.indexOfScalar(u8, flags, 'u') != null;
    const has_i = std.mem.indexOfScalar(u8, flags, 'i') != null;

    const need_dotall = has_s and opts.unsupported.regex_dotall;
    const need_named = opts.unsupported.regex_named_groups and hasNamedGroup(pattern);
    const need_sticky = has_y and opts.unsupported.regex_sticky;
    // `u` flag 자체는 runtime 지원 대상이 아니지만, `\u{X}` brace escape 는 `u` flag 하에서만
    // 허용된다. brace escape 를 surrogate pair 로 내리면서 flag 도 함께 strip 한다.
    const need_unicode = has_u and opts.unsupported.unicode_brace_escape;

    if (!need_dotall and !need_named and !need_sticky and !need_unicode) return .{ .text = null };

    // sticky 는 flag strip 만 → 패턴 무변경. dotall/named/unicode 만 패턴 변환.
    // sticky-only 면 parse/transform/print 를 건너뛰고 원본 패턴 verbatim
    // (불필요 작업 제거 + canonical 정규화 미적용 — ad-hoc 과 동일 바이트).
    const need_pattern_xform = need_dotall or need_named or need_unicode;

    // parse → AST transform → dumb printer (#1475 PR2 정공법; ad-hoc byte-walk
    // 제거). 파서는 렉서 validate 와 동일하므로(이미 통과한 리터럴) parse 실패는
    // 없어야 하나, 방어적으로 실패 시 변환 생략(.text=null = 원본 유지).
    var owned_pattern: ?[]u8 = null;
    defer if (owned_pattern) |p| allocator.free(p);
    // #3509: astral 을 정확히 ES5 로 못 내린 경우(negated/\p{}/class_string)
    // u flag 를 strip 하면 silent 오변환 → u 보존(부분 커버리지, 틀린 출력 0).
    var astral_u_incomplete = false;
    const pattern_text: []const u8 = if (need_pattern_xform) blk: {
        var in_ast = regexp.parse(pattern, flags, allocator) orelse return .{ .text = null };
        defer in_ast.deinit();
        var tr = try regexp.transform.transform(in_ast, .{
            .dotall = need_dotall,
            .strip_named = need_named,
            .unicode_brace = need_unicode,
            .ignore_case = has_i,
        }, allocator);
        defer tr.deinit();
        astral_u_incomplete = tr.astral_u_incomplete;
        owned_pattern = regexp.printer.print(tr.ast, allocator) catch return .{ .text = null };
        break :blk owned_pattern.?;
    } else pattern;
    const strip_u = need_unicode and !astral_u_incomplete;

    // named capture mapping 추출 — 패턴 변환 성공 후 (early-return 누수 방지).
    // 원본 pattern 기준이라 변환 순서와 무관. 호출자가 `__wrapRegExp` 합성에 사용.
    var named_groups: ?[]const NamedGroupMapping = null;
    errdefer if (named_groups) |ng| allocator.free(ng);
    if (need_named) {
        const map = try extractNamedGroupMap(allocator, pattern);
        if (map.len > 0) named_groups = map else allocator.free(map);
    }

    // /pattern/flags 조립 + 변환된 flag strip.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, pattern_text.len + flags.len + 2);
    try out.append(allocator, '/');
    try out.appendSlice(allocator, pattern_text);
    try out.append(allocator, '/');
    for (flags) |c| {
        if (need_dotall and c == 's') continue;
        if (need_sticky and c == 'y') continue;
        if (strip_u and c == 'u') continue;
        try out.append(allocator, c);
    }
    return .{ .text = try out.toOwnedSlice(allocator), .named_groups = named_groups };
}

/// `String.prototype.replace` replacement string 의 `$<name>` 변환을 위한 매핑 항목.
pub const NamedGroupMapping = struct {
    name: []const u8, // pattern 내부 원본 슬라이스 (수명: pattern 원본)
    index: u32, // 1-based capture group 인덱스
};

/// pattern 을 한 번 순회하며 named group 의 (name, capture index) 매핑을 추출.
/// 비-capture / lookahead / lookbehind 는 capture index 를 차지하지 않는다.
/// 호출자는 반환 슬라이스를 free 해야 한다.
pub fn extractNamedGroupMap(allocator: std.mem.Allocator, pattern: []const u8) ![]const NamedGroupMapping {
    var out: std.ArrayList(NamedGroupMapping) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var in_class: bool = false;
    var group_idx: u32 = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '\\') {
            i += if (i + 1 < pattern.len) 2 else 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            i += 1;
            continue;
        }
        if (c == '[') {
            in_class = true;
            i += 1;
            continue;
        }
        if (c != '(') {
            i += 1;
            continue;
        }
        if (i + 2 < pattern.len and pattern[i + 1] == '?') {
            const tag = pattern[i + 2];
            if (tag == ':' or tag == '=' or tag == '!') {
                i += 1;
                continue;
            }
            if (tag == '<') {
                if (i + 3 < pattern.len and (pattern[i + 3] == '=' or pattern[i + 3] == '!')) {
                    i += 1;
                    continue;
                }
                group_idx += 1;
                if (std.mem.indexOfScalarPos(u8, pattern, i + 3, '>')) |gt| {
                    try out.append(allocator, .{ .name = pattern[i + 3 .. gt], .index = group_idx });
                    i = gt + 1;
                    continue;
                }
            }
        }
        group_idx += 1;
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// `String.prototype.replace` replacement 의 `$<name>` 을 `$N` (positional)으로 치환.
/// 변환된 부분이 하나도 없으면 null (호출자는 원본 그대로 사용).
/// `$$`, `$&`, `$\``, `$'`, `$N` 은 그대로 보존.
pub fn rewriteReplacementNamedRefs(
    allocator: std.mem.Allocator,
    content: []const u8,
    mapping: []const NamedGroupMapping,
) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var changed = false;
    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '$' and i + 2 < content.len and content[i + 1] == '<') {
            if (std.mem.indexOfScalarPos(u8, content, i + 2, '>')) |gt| {
                const name = content[i + 2 .. gt];
                var found_idx: ?u32 = null;
                for (mapping) |m| {
                    if (std.mem.eql(u8, m.name, name)) {
                        found_idx = m.index;
                        break;
                    }
                }
                if (found_idx) |idx| {
                    var buf: [16]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "${d}", .{idx}) catch unreachable;
                    try out.appendSlice(allocator, s);
                    i = gt + 1;
                    changed = true;
                    continue;
                }
            }
        }
        try out.append(allocator, content[i]);
        i += 1;
    }
    if (!changed) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

/// pattern에 `(?<name>...)` (lookbehind 제외) 가 있는지 스캔.
fn hasNamedGroup(pattern: []const u8) bool {
    var i: usize = 0;
    var in_class: bool = false;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (in_class) {
            if (c == ']') in_class = false;
            continue;
        }
        if (c == '[') {
            in_class = true;
            continue;
        }
        if (c == '(' and i + 2 < pattern.len and pattern[i + 1] == '?' and pattern[i + 2] == '<') {
            if (i + 3 < pattern.len and (pattern[i + 3] == '=' or pattern[i + 3] == '!')) continue;
            return true;
        }
    }
    return false;
}

// ─── 테스트 ───

const testing = std.testing;

fn runLower(raw: []const u8, unsupported: compat.UnsupportedFeatures) !?[]const u8 {
    const r = try lower(testing.allocator, raw, .{ .unsupported = unsupported });
    if (r.named_groups) |ng| testing.allocator.free(ng);
    return r.text;
}

test "regex: dotAll /a.b/s → /a[\\s\\S]b/" {
    const out = (try runLower("/a.b/s", .{ .regex_dotall = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a[\\s\\S]b/", out);
}

test "regex: dotAll 이미 escape 된 . 는 변환 X" {
    const out = (try runLower("/a\\.b/s", .{ .regex_dotall = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a\\.b/", out);
}

test "regex: dotAll character class 안의 . 는 그대로" {
    const out = (try runLower("/[a.]b/s", .{ .regex_dotall = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/[a.]b/", out);
}

test "regex: dotAll 타겟이 지원 시 no-op" {
    const out = try runLower("/a.b/s", .{});
    try testing.expect(out == null);
}

test "regex: named capture → positional" {
    const out = (try runLower("/(?<year>\\d{4})/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(\\d{4})/", out);
}

test "regex: named capture 여러 개" {
    const out = (try runLower("/(?<y>\\d{4})-(?<m>\\d{2})/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(\\d{4})-(\\d{2})/", out);
}

test "regex: named capture mapping 반환 (#1063 wrapRegExp 입력)" {
    const r = try lower(testing.allocator, "/(?<y>\\d{4})-(?<m>\\d{2})/", .{ .unsupported = .{ .regex_named_groups = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.named_groups != null);
    const ng = r.named_groups.?;
    try testing.expectEqual(@as(usize, 2), ng.len);
    try testing.expectEqualStrings("y", ng[0].name);
    try testing.expectEqual(@as(u32, 1), ng[0].index);
    try testing.expectEqualStrings("m", ng[1].name);
    try testing.expectEqual(@as(u32, 2), ng[1].index);
}

test "regex: named group 없을 때 mapping null (#1063)" {
    const r = try lower(testing.allocator, "/(\\d+)/", .{ .unsupported = .{ .regex_named_groups = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.named_groups == null);
}

test "regex: lookbehind 만 있을 때 mapping null (#1063)" {
    const r = try lower(testing.allocator, "/(?<=a)b/", .{ .unsupported = .{ .regex_named_groups = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.named_groups == null);
}

test "regex: lookbehind (?<=...) 은 유지" {
    const out = try runLower("/(?<=a)b/", .{ .regex_named_groups = true });
    try testing.expect(out == null);
}

test "regex: sticky /y flag strip" {
    const out = (try runLower("/foo/y", .{ .regex_sticky = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/foo/", out);
}

test "regex: dotAll + sticky 함께" {
    const out = (try runLower("/a.b/sy", .{ .regex_dotall = true, .regex_sticky = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a[\\s\\S]b/", out);
}

test "regex: u + \\u{1F600} → surrogate pair + u strip" {
    const out = (try runLower("/\\u{1F600}/u", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/\\uD83D\\uDE00/", out);
}

test "regex: u + BMP \\u{41} → \\u0041 + u strip" {
    const out = (try runLower("/\\u{41}/u", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/\\u0041/", out);
}

test "regex: u flag 없으면 no-op" {
    const out = try runLower("/\\u0041/", .{ .unicode_brace_escape = true });
    try testing.expect(out == null);
}

test "regex: u + character class — #3509 정확 surrogate-alternation" {
    // 이전 ad-hoc 은 깨진 [😀](code-unit alternation) 출력.
    // #3509: regexpu식 정확 형태 (?:😀) 로 재기준.
    const out = (try runLower("/[\\u{1F600}]/u", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:\\uD83D\\uDE00)/", out);
}

test "regex: u + astral class range — #3509" {
    const out = (try runLower("/[\\u{1F600}-\\u{1F64F}]/u", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:\\uD83D[\\uDE00-\\uDE4F])/", out);
}

test "regex: u + negated class (non-i) — #3513 complement 다운레벨" {
    // [^😀]/u → [0,0x10FFFF]-{😀} complement surrogate-alternation, u strip.
    const out = (try runLower("/[^\\u{1F600}]/u", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "/(?:"));
    try testing.expect(!std.mem.endsWith(u8, out, "/u")); // u strip 됨
    try testing.expect(std.mem.indexOf(u8, out, "\\u{") == null); // brace 잔존 없음
}

test "regex: iu + negated — #3511 fold-확장 complement 다운레벨" {
    // i+u negated 이제 처리(게이트 해제): fold-확장 후 complement, u strip·i 유지.
    const out = (try runLower("/[^\\u{1F600}]/iu", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "/(?:"));
    try testing.expect(std.mem.endsWith(u8, out, "/i")); // u strip, i 유지
    try testing.expect(std.mem.indexOf(u8, out, "\\u{") == null);
}

test "regex: iu + [k] — Kelvin(U+212A) u-전용 fold 보존 (#3511)" {
    const out = (try runLower("/[k]/iu", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\\u212A") != null); // Kelvin 명시
    try testing.expect(std.mem.endsWith(u8, out, "/i"));
}

test "regex: esnext (미지원 없음) no-op" {
    const out = try runLower("/(?<year>\\d{4})/", .{});
    try testing.expect(out == null);
}

test "regex: named backreference \\k<name> → \\N" {
    const out = (try runLower("/(?<dup>a+)b\\k<dup>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(a+)b\\1/", out);
}

test "regex: named backref + 앞쪽 일반 group이 인덱스 차지" {
    const out = (try runLower("/(\\d+)-(?<word>[a-z]+)-\\k<word>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(\\d+)-([a-z]+)-\\2/", out);
}

test "regex: named backref + non-capturing group은 카운트 X" {
    const out = (try runLower("/(?:foo)(?<n>\\d+)\\k<n>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:foo)(\\d+)\\1/", out);
}

test "regex: named backref + lookbehind은 카운트 X" {
    const out = (try runLower("/(?<=\\$)(?<n>\\d+)\\k<n>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?<=\\$)(\\d+)\\1/", out);
}

test "regex: named backref — character class 안의 \\k는 그대로" {
    const out = (try runLower("/(?<n>a)[\\k<n>]/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(a)[\\k<n>]/", out);
}

// #2472 회귀 가드: 32개 stack-cap 시 33번째부터 std.debug.assert 가 ReleaseFast 에서
// 비활성화되어 OOB 쓰기 (UB) 가 발생했음. dynamic ArrayList 로 전환 후 50개도 정상 동작.
test "#2472 regression: 50 named groups + last backref — no truncation" {
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(testing.allocator);
    try pat.append(testing.allocator, '/');
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        try pat.print(testing.allocator, "(?<n{d}>a)", .{i});
    }
    // 마지막 named group 의 backref — 50번째 capture 이므로 \50 으로 변환되어야 한다.
    try pat.appendSlice(testing.allocator, "\\k<n49>/");

    const out = (try runLower(pat.items, .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\\50") != null);
    // 32-stack 회귀 시 named[32..] 가 누락되어 backref 변환 실패 → "\\k<n49>" 잔존했음.
    try testing.expect(std.mem.indexOf(u8, out, "\\k<n") == null);
}
