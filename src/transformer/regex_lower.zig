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
const group_name = @import("../regexp/group_name.zig");
const char_helpers = @import("../regexp/char_helpers.zig");
const cooked_name = @import("cooked_name.zig");

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
    /// ES2025 modifier 다운레벨(#4210) 시, 못 내려 출력에 보존된 modifier 그룹이
    /// 있는가. 호출자(node_dispatch→transformer)가 진단 신호로 모은다.
    kept_modifier: bool = false,
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
    // #4199: duplicate named group (ES2025) 은 named group 자체를 지원하는
    // es2018~es2024 타겟에서도 SyntaxError — 중복이 실재하면 strip 경로 전체를
    // 활성화한다 (#4198 의 array 병합/$1$2/\k 연접이 정확성을 보장).
    const need_named = (opts.unsupported.regex_named_groups and hasNamedGroup(pattern)) or
        (opts.unsupported.regex_duplicate_named_groups and
            try hasDuplicateNamedGroup(allocator, pattern));
    const need_sticky = has_y and opts.unsupported.regex_sticky;
    // `u` flag 자체는 runtime 지원 대상이 아니지만, `\u{X}` brace escape 는 `u` flag 하에서만
    // 허용된다. brace escape 를 surrogate pair 로 내리면서 flag 도 함께 strip 한다.
    const need_unicode = has_u and opts.unsupported.unicode_brace_escape;
    // #4210: ES2025 inline modifier 다운레벨. modifier 가 있으면 transform 을 거쳐
    // 내릴 수 있는 것(s-enabling, ASCII i-enabling)은 내리고 못 내리는 잔여
    // (m/disabling/비-ASCII/`/u`/전역 /i)는 보존+kept_modifier 로 진단 신호.
    const need_modifier = opts.unsupported.regex_modifiers and hasModifierGroup(pattern);

    if (!need_dotall and !need_named and !need_sticky and !need_unicode and !need_modifier) return .{ .text = null };

    // sticky 는 flag strip 만 → 패턴 무변경. dotall/named/unicode/modifier 만 패턴 변환.
    // sticky-only 면 parse/transform/print 를 건너뛰고 원본 패턴 verbatim
    // (불필요 작업 제거 + canonical 정규화 미적용 — ad-hoc 과 동일 바이트).
    const need_pattern_xform = need_dotall or need_named or need_unicode or need_modifier;

    // parse → AST transform → dumb printer (#1475 PR2 정공법; ad-hoc byte-walk
    // 제거). 파서는 렉서 validate 와 동일하므로(이미 통과한 리터럴) parse 실패는
    // 없어야 하나, 방어적으로 실패 시 변환 생략(.text=null = 원본 유지).
    var owned_pattern: ?[]u8 = null;
    defer if (owned_pattern) |p| allocator.free(p);
    // #3509: astral 을 정확히 ES5 로 못 내린 경우(negated/\p{}/class_string)
    // u flag 를 strip 하면 silent 오변환 → u 보존(부분 커버리지, 틀린 출력 0).
    var astral_u_incomplete = false;
    var kept_modifier = false;
    const pattern_text: []const u8 = if (need_pattern_xform) blk: {
        var in_ast = regexp.parse(pattern, flags, allocator) orelse return .{ .text = null };
        defer in_ast.deinit();
        var tr = try regexp.transform.transform(in_ast, .{
            .dotall = need_dotall,
            .strip_named = need_named,
            .unicode_brace = need_unicode,
            .ignore_case = has_i,
            .lower_modifiers = need_modifier,
            .global_u = has_u,
            .lookbehind_ok = !opts.unsupported.regex_lookbehind,
        }, allocator);
        astral_u_incomplete = tr.astral_u_incomplete;
        kept_modifier = tr.kept_modifier;
        // #4211: u 를 보존하기로 결정되면(incomplete) 패턴 *전체*가 u-유효해야
        // 한다 — 이미 적용된 surrogate-alternation/complement 재작성은 u-strip
        // 전제라 부분 적용 시 비일관 miscompile (kept-u 아래서 lone surrogate
        // 매치 불가). unicode_brace 끄고 재변환해 astral 구문을 verbatim 유지.
        if (astral_u_incomplete and need_unicode) {
            tr.deinit();
            tr = try regexp.transform.transform(in_ast, .{
                .dotall = need_dotall,
                .strip_named = need_named,
                .unicode_brace = false,
                .ignore_case = has_i,
                .lower_modifiers = need_modifier,
                .global_u = has_u,
                .lookbehind_ok = !opts.unsupported.regex_lookbehind,
            }, allocator);
            kept_modifier = tr.kept_modifier;
        }
        defer tr.deinit();
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
    return .{ .text = try out.toOwnedSlice(allocator), .named_groups = named_groups, .kept_modifier = kept_modifier };
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
            // ES2025 inline modifier 그룹 `(?ims-ims:...)` 도 non-capturing (#4202).
            // 빠뜨리면 AST 카운터 (regexp/transform.zig 의 ignore_group skip) 와
            // 인덱스가 어긋나 groups map / `$<name>` 재작성이 +1 시프트된다.
            if (tag == ':' or tag == '=' or tag == '!' or
                tag == 'i' or tag == 'm' or tag == 's' or tag == '-')
            {
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
                // ES2025 duplicate named group: 같은 이름의 모든 인덱스를 이어붙인다
                // (`$<y>` → `$1$2`). alternation 상 한쪽만 참여하므로 비참여 그룹은
                // 빈 문자열 — babel __wrapRegExp 의 `group.join("$")` 동형 (#4198).
                var found = false;
                for (mapping) |m| {
                    // #4216: replacement 쪽 이름은 JS string 표기 — \x79 등
                    // string-escape 도 cook 하면 그룹 이름과 동치. cooked_name 은
                    // \u 계열을 포함한 superset 디코더라 그룹이름 측에도 안전.
                    if (cooked_name.eql(m.name, name)) {
                        var buf: [16]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "${d}", .{m.index}) catch unreachable;
                        try out.appendSlice(allocator, s);
                        found = true;
                    }
                }
                if (found) {
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

/// pattern 에 canonical 동일 이름의 named group 이 2개 이상 있는지 (#4199).
/// extractNamedGroupMap 재사용 — 호출 빈도는 "dup gate 만 미지원인 타겟 ×
/// named group 패턴" 으로 좁다.
fn hasDuplicateNamedGroup(allocator: std.mem.Allocator, pattern: []const u8) !bool {
    // named group 이 2개 미만이면 dup 불가 — alloc 전 비할당 프리스캔.
    if (std.mem.count(u8, pattern, "(?<") < 2) return false;
    if (!hasNamedGroup(pattern)) return false;
    const map = try extractNamedGroupMap(allocator, pattern);
    defer allocator.free(map);
    for (map, 0..) |entry, i| {
        for (map[0..i]) |prev| {
            if (group_name.eqlCanonical(prev.name, entry.name)) return true;
        }
    }
    return false;
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

/// `(?ims-ims:...)` inline modifier 그룹(ES2025)이 패턴에 하나라도 있는가. char class
/// 안과 escape 는 제외하고, `(?:`·`(?<name>`·lookaround 와 구분한다 — `(?` 뒤가 modifier
/// 문자(i/m/s) ≥1 개 (선택적 `-[ims]+`) + `:` 로 끝나야 한다. 비트 정의(i=1,m=2,s=4)는
/// 파서 char_helpers 와 공유. 이건 transform 실행/prepass 게이트일 뿐 — 실제 다운레벨
/// 가능 여부·잔여 진단은 transform 결과(kept_modifier)가 결정한다(byte-scan 은 fold
/// bail = 비-ASCII/`\u`escape/`/u`/전역 /i 를 판별 못 함).
pub fn hasModifierGroup(pattern: []const u8) bool {
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
        if (c == '(' and i + 1 < pattern.len and pattern[i + 1] == '?') {
            var j = i + 2;
            var mods: u32 = 0;
            while (j < pattern.len and char_helpers.isModifierChar(pattern[j])) : (j += 1) mods += 1;
            if (j < pattern.len and pattern[j] == '-') {
                j += 1;
                while (j < pattern.len and char_helpers.isModifierChar(pattern[j])) : (j += 1) mods += 1;
            }
            if (mods > 0 and j < pattern.len and pattern[j] == ':') return true;
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

// #4198: ES2025 duplicate named capture group — mapping 은 per-occurrence 로
// 모든 (name, index) 쌍을 보존해야 호출자가 array 병합/`$1$2` 합성 가능.
test "#4198: duplicate named group mapping 은 occurrence 별 전부 보존" {
    const r = try lower(testing.allocator, "/(?<y>\\d{4})-a|(?<y>\\d{4})-b/", .{ .unsupported = .{ .regex_named_groups = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expectEqualStrings("/(\\d{4})-a|(\\d{4})-b/", r.text.?);
    const ng = r.named_groups.?;
    try testing.expectEqual(@as(usize, 2), ng.len);
    try testing.expectEqualStrings("y", ng[0].name);
    try testing.expectEqual(@as(u32, 1), ng[0].index);
    try testing.expectEqualStrings("y", ng[1].name);
    try testing.expectEqual(@as(u32, 2), ng[1].index);
}

// #4201: 그룹 이름 정체성 = escape 디코드된 코드포인트 시퀀스.
test "#4201: \\k<\\u0079> 가 (?<y>) 를 canonical 매칭" {
    const out = (try runLower("/(?<y>a)b\\k<\\u0079>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(a)b\\1/", out);
}

test "#4201: escape-aliased duplicate — $<y> 가 양쪽 occurrence 모두 매칭" {
    const mapping = [_]NamedGroupMapping{
        .{ .name = "y", .index = 1 },
        .{ .name = "\\u0079", .index = 2 },
    };
    const out = (try rewriteReplacementNamedRefs(testing.allocator, "[$<y>]", &mapping)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[$1$2]", out);
}

// #4202: ES2025 inline modifier 그룹 (?i:...) 은 non-capturing — capture 인덱스를
// 차지하면 안 된다 (AST 카운터와 어긋나 groups map 이 +1 시프트되던 버그).
test "#4202: (?i:...) modifier 그룹은 capture 인덱스 비차지" {
    const r = try lower(testing.allocator, "/(?i:id)(?<y>\\d+)/", .{ .unsupported = .{ .regex_named_groups = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expectEqualStrings("/(?i:id)(\\d+)/", r.text.?);
    const ng = r.named_groups.?;
    try testing.expectEqual(@as(usize, 1), ng.len);
    try testing.expectEqualStrings("y", ng[0].name);
    try testing.expectEqual(@as(u32, 1), ng[0].index);
}

test "#4202: (?im-s:...) / (?-i:...) 변형도 비차지 + \\k 인덱스와 일치" {
    const r = try lower(testing.allocator, "/(?im-s:a)(?-i:b)(?<y>c)\\k<y>/", .{ .unsupported = .{ .regex_named_groups = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    // \k<y> 의 AST 경로와 groups map 의 텍스트 스캐너가 같은 인덱스(1)를 내야 한다.
    try testing.expectEqualStrings("/(?im-s:a)(?-i:b)(c)\\1/", r.text.?);
    const ng = r.named_groups.?;
    try testing.expectEqual(@as(usize, 1), ng.len);
    try testing.expectEqual(@as(u32, 1), ng[0].index);
}

test "#4216: replacement $<\\x79> — string-escape 표기도 그룹 이름과 cook 동치" {
    const mapping = [_]NamedGroupMapping{.{ .name = "y", .index = 1 }};
    const out = (try rewriteReplacementNamedRefs(testing.allocator, "[$<\\x79>]", &mapping)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[$1]", out);
}

test "#4198: replacement $<dup> → 모든 인덱스 이어붙임 ($1$2)" {
    const mapping = [_]NamedGroupMapping{
        .{ .name = "y", .index = 1 },
        .{ .name = "y", .index = 2 },
    };
    const out = (try rewriteReplacementNamedRefs(testing.allocator, "[$<y>]", &mapping)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[$1$2]", out);
}

test "#4198: duplicate named group 의 \\k<name> → 모든 인덱스 backref 연접 (?:\\1\\2)" {
    const out = (try runLower("/(?<y>a)\\k<y>|(?<y>b)\\k<y>/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(a)(?:\\1\\2)|(b)(?:\\1\\2)/", out);
}

test "#4198: duplicate \\k<name> + quantifier — (?:) 래핑으로 안전" {
    const out = (try runLower("/(?<y>a)\\k<y>+|(?<y>b)/", .{ .regex_named_groups = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(a)(?:\\1\\2)+|(b)/", out);
}

test "#4198: replacement 단일 이름은 기존과 동일 ($N)" {
    const mapping = [_]NamedGroupMapping{
        .{ .name = "y", .index = 1 },
        .{ .name = "m", .index = 2 },
    };
    const out = (try rewriteReplacementNamedRefs(testing.allocator, "$<m>/$<y>", &mapping)).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("$2/$1", out);
}

// #4199: es2018~es2024 (named group 지원, dup 미지원) gate.
test "#4199: dup gate — es2022 류 타겟에서 duplicate 만 strip" {
    // dup 있음 → strip + mapping
    const r = try lower(testing.allocator, "/(?<y>a)|(?<y>b)/", .{ .unsupported = .{ .regex_duplicate_named_groups = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expectEqualStrings("/(a)|(b)/", r.text.?);
    try testing.expectEqual(@as(usize, 2), r.named_groups.?.len);
}

test "#4199: dup gate — 단일 이름은 no-op (named group 유지)" {
    const out = try runLower("/(?<y>a)-(?<m>b)/", .{ .regex_duplicate_named_groups = true });
    try testing.expect(out == null);
}

test "#4199: dup gate — escape-aliased dup 도 감지 (canonical)" {
    const r = try lower(testing.allocator, "/(?<y>a)|(?<\\u0079>b)/", .{ .unsupported = .{ .regex_duplicate_named_groups = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expectEqualStrings("/(a)|(b)/", r.text.?);
}

// #4211: transform 이 modifier 영역의 유효 플래그를 존중.
test "#4211: (?-s:) 안 dot 은 dotall 재작성 제외" {
    const out = (try runLower("/(?-s:a.b)x./s", .{ .regex_dotall = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?-s:a.b)x[\\s\\S]/", out);
}

test "#4211: (?-i:[k])/iu — fold 확장 대신 u 보존 (byte-exact)" {
    const r = try lower(testing.allocator, "/(?-i:[k])y/iu", .{ .unsupported = .{ .unicode_brace_escape = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.text != null);
    try testing.expectEqualStrings("/(?-i:[k])y/iu", r.text.?);
}

test "#4211: i-영역 class + 바깥 astral class — u 보존 시 전체 verbatim (일관성)" {
    // 부분 재작성(surrogate-alternation)은 kept-u 아래서 lone surrogate 가
    // pair 안을 매치 못해 miscompile — 재변환으로 전체 보존되어야 한다.
    const r = try lower(testing.allocator, "/(?i:[a-z])[\\u{1F600}-\\u{1F601}]/u", .{ .unsupported = .{ .unicode_brace_escape = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.text != null);
    try testing.expectEqualStrings("/(?i:[a-z])[\\u{1F600}-\\u{1F601}]/u", r.text.?);
}

// #4225: u-전용 fold 등가를 가진 리터럴 atom — u 보존 게이트.
test "#4225: /k/iu 리터럴 atom — Kelvin fold 소실 방지 (u 보존, byte-exact)" {
    const out = (try runLower("/ka/iu", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/ka/iu", out);
}

test "#4225: astral fold atom (\\u{10400} Deseret) — fast-path 도 u 보존" {
    const out = (try runLower("/\\u{10400}b/iu", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/\\u{10400}b/iu", out);
}

test "#4225: fold 무관 atom 은 기존 u-strip 유지" {
    const out = (try runLower("/x\\u{1F600}/iu", .{ .unicode_brace_escape = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/x\\uD83D\\uDE00/i", out);
}

// #4237: literal non-ASCII cp 단위 노드 + astral 단일컨텍스트 u-보존 게이트.
test "#4237: literal sharp-s dotall 재인쇄 mojibake 없음" {
    const out = (try runLower("/\xC5\xBF.b/s", .{ .regex_dotall = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/\xC5\xBF[\\s\\S]b/", out);
}

test "#4237: astral literal + quantifier /u — u 보존 게이트" {
    const r = try lower(testing.allocator, "/\xF0\x9F\x98\x80+x/u", .{ .unsupported = .{ .unicode_brace_escape = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    defer if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.text != null);
    try testing.expect(std.mem.endsWith(u8, r.text.?, "/u"));
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

test "hasModifierGroup — inline modifier 그룹 검출 (#4210)" {
    // enabling / disabling / 혼합 / 패턴 중간
    try testing.expect(hasModifierGroup("(?i:a)"));
    try testing.expect(hasModifierGroup("(?s:.)x"));
    try testing.expect(hasModifierGroup("(?-i:b)"));
    try testing.expect(hasModifierGroup("(?im-s:a)"));
    try testing.expect(hasModifierGroup("foo(?i:bar)baz"));
    try testing.expect(hasModifierGroup("(?m:^a$)"));
}

test "hasModifierGroup — non-modifier 그룹과 구분 (#4210)" {
    // non-capturing / named / lookaround 은 modifier 아님
    try testing.expect(!hasModifierGroup("(?:a)"));
    try testing.expect(!hasModifierGroup("(?<n>a)"));
    try testing.expect(!hasModifierGroup("(?=a)"));
    try testing.expect(!hasModifierGroup("(?<=a)"));
    try testing.expect(!hasModifierGroup("(?!a)"));
    try testing.expect(!hasModifierGroup("plain"));
    // modifier 문자 없이 `:` 만 → 아님
    try testing.expect(!hasModifierGroup("(?:-)"));
}

test "hasModifierGroup — char class 안 / escape 는 제외 (#4210)" {
    // `[(?i:]` 는 char class 멤버라 modifier 아님
    try testing.expect(!hasModifierGroup("[(?i:]"));
    // escape 된 `\(` 는 group 시작 아님
    try testing.expect(!hasModifierGroup("\\(?i:"));
    // class 밖의 진짜 modifier 는 여전히 검출
    try testing.expect(hasModifierGroup("[abc](?i:x)"));
}

test "#4210: (?s:.) → (?:[\\s\\S]) 다운레벨 + s-enabling strip" {
    const out = (try runLower("/(?s:.)x/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:[\\s\\S])x/", out);
}

test "#4210: 중첩 dot — a(?s:b.c)d 내부 dot 만 dotall" {
    const out = (try runLower("/a(?s:b.c)d/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/a(?:b[\\s\\S]c)d/", out);
}

test "#4210: 혼합 (?s:.)(?i:x) — s·i 둘 다 다운레벨 (PR2b)" {
    const out = (try runLower("/(?s:.)(?i:x)/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:[\\s\\S])(?:[xX])/", out);
}

test "#4210: 혼합 (?sm:^.$) — s·m 둘 다 다운레벨 (PR3)" {
    const out = (try runLower("/(?sm:^.$)/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:(?:^|(?<=[\\n\\r\\u2028\\u2029]))[\\s\\S](?:$|(?=[\\n\\r\\u2028\\u2029])))/", out);
}

test "#4210: 혼합 (?si:x.) — s·i 둘 다 strip → (?:[xX][\\s\\S]) (PR2b)" {
    const out = (try runLower("/(?si:x.)/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:[xX][\\s\\S])/", out);
}

test "#4210 PR2b: (?i:foo) → (?:[fF][oO][oO]) ASCII non-u fold" {
    const out = (try runLower("/(?i:foo)bar/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:[fF][oO][oO])bar/", out);
}

test "#4210 PR2b: (?i:Hello\\d) — 글자만 fold, \\d identity" {
    const out = (try runLower("/(?i:Hello\\d)/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:[Hh][eE][lL][lL][oO]\\d)/", out);
}

test "#4210 PR2b: (?i:[a-z]) class ASCII fold" {
    const out = (try runLower("/(?i:[a-z])/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:[\\u0041-\\u005A\\u0061-\\u007A])/", out);
}

test "#4210 PR2b: 비-ASCII (?i:café) → fold bail, i 보존 + kept_modifier" {
    const r = try lower(testing.allocator, "/(?i:caf\u{00E9})/", .{ .unsupported = .{ .regex_modifiers = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.kept_modifier); // é 가 non-u fold 불가 → 보존
    try testing.expect(std.mem.indexOf(u8, r.text.?, "(?i:") != null);
}

test "#4210 PR2b: /u 플래그면 i-fold bail + kept_modifier" {
    const r = try lower(testing.allocator, "/(?i:foo)/u", .{ .unsupported = .{ .regex_modifiers = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.kept_modifier);
}

test "#4210 PR2b: 순수 s-enabling 은 kept_modifier 없음(완전 다운레벨)" {
    const r = try lower(testing.allocator, "/(?s:.)x/", .{ .unsupported = .{ .regex_modifiers = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(!r.kept_modifier);
}

test "#4210: modifier 비트 미set(모던 타겟) → 변환 없음" {
    const r = try lower(testing.allocator, "/(?s:.)x/", .{ .unsupported = .{} });
    try testing.expect(r.text == null);
}

test "#4210 PR3: (?m:^a$) → multiline 앵커 재작성 (lookbehind 지원)" {
    // regex_lookbehind 미set = lookbehind 지원(es2018+).
    const out = (try runLower("/(?m:^a$)/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:(?:^|(?<=[\\n\\r\\u2028\\u2029]))a(?:$|(?=[\\n\\r\\u2028\\u2029])))/", out);
}

test "#4210 PR3: (?im:^a) — m 앵커 + i fold" {
    const out = (try runLower("/(?im:^a)/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:(?:^|(?<=[\\n\\r\\u2028\\u2029]))[aA])/", out);
}

test "#4210 PR3: (?m:abc) 앵커 없음 → m strip(no-op)" {
    const out = (try runLower("/(?m:abc)/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:abc)/", out);
}

test "#4210 PR3: lookbehind 미지원(es2017) → m bail + kept_modifier" {
    const r = try lower(testing.allocator, "/(?m:^a$)/", .{ .unsupported = .{ .regex_modifiers = true, .regex_lookbehind = true } });
    defer if (r.text) |t| testing.allocator.free(t);
    if (r.named_groups) |ng| testing.allocator.free(ng);
    try testing.expect(r.kept_modifier);
    try testing.expect(std.mem.indexOf(u8, r.text.?, "(?m:") != null);
}

test "#4210 PR3: \\b 는 m 무관 — (?m:\\bx) 의 \\b 그대로" {
    const out = (try runLower("/(?m:\\bx)/", .{ .regex_modifiers = true })).?;
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/(?:\\bx)/", out);
}
