/// 브라우저/엔진 타겟 호환성 테이블.
///
/// `--target=chrome80,safari14` 같은 엔진 버전 타겟을 UnsupportedFeatures bitmask로 변환.
/// `--target=es2020` 같은 ES 버전 타겟도 동일한 bitmask로 수렴.
///
/// 데이터 소스: esbuild compat-table.go + kangax/compat-table 교차검증 (2026-03-31 기준)
const std = @import("std");

// ─── 타겟 엔진 ───

pub const Engine = enum(u8) {
    chrome,
    firefox,
    safari,
    edge,
    node,
    deno,
    ios, // iOS Safari
    hermes,

    /// 엔진 이름 문자열 → Engine enum. 대소문자 무시.
    pub fn fromString(s: []const u8) ?Engine {
        const max_len = comptime blk: {
            var m: usize = 0;
            for (std.meta.fields(Engine)) |f| m = @max(m, f.name.len);
            break :blk m;
        };
        var buf: [max_len]u8 = undefined;
        if (s.len > buf.len or s.len == 0) return null;
        for (s, 0..) |c, i| {
            buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        const lower = buf[0..s.len];
        return std.meta.stringToEnum(Engine, lower);
    }
};

// ─── ES 버전 타겟 (기존 Target enum 대체) ───

pub const ESTarget = enum(u8) {
    es5,
    es2015,
    es2016,
    es2017,
    es2018,
    es2019,
    es2020,
    es2021,
    es2022,
    es2023,
    es2024,
    es2025,
    esnext,
};

// ─── Feature 인덱스 (UnsupportedFeatures 비트 위치와 1:1 대응) ───

pub const Feature = enum(u5) {
    // ES2015
    arrow,
    class,
    template_literal,
    destructuring,
    for_of,
    spread,
    object_extensions, // computed + shorthand properties (esbuild 동일)
    default_params,
    block_scoping,
    generator,
    new_target,
    // ES2016
    exponentiation,
    // ES2017
    async_await,
    // ES2018
    object_spread,
    // ES2019
    optional_catch_binding,
    // ES2020
    nullish_coalescing,
    optional_chaining,
    // ES2021
    logical_assignment,
    // ES2022
    class_static_block,
    class_private_method,
    class_private_field,
    top_level_await,
    // ES2023
    hashbang,
    // ES2025
    using,
    // Regex feature flags (esbuild 대응: RegExpStickyAndUnicodeFlags / DotAllFlag / NamedCaptureGroups)
    // 다운레벨링은 regex pattern/flag 치환(src/transformer/regex_lower.zig)으로 수행한다.
    regex_sticky, // /y flag (ES2015)
    regex_dotall, // /s flag (ES2018) — `.` → `[\s\S]` + flag strip
    regex_named_groups, // (?<name>...) (ES2018) — positional group으로 strip
    /// `\u{X}` brace unicode escape (ES2015). 문자열/template 내부는 surrogate pair로,
    /// regex 의 `u` flag + `\u{X}` 도 surrogate pair + flag strip (#1388).
    unicode_brace_escape,
    /// ES2025 duplicate named capture group (`(?<y>..)|(?<y>..)`). 미지원 타겟에선
    /// regex_named_groups 와 같은 strip+__wrapRegExp 경로로 다운레벨 (#4199).
    /// NOTE: Feature enum 과 UnsupportedFeatures 필드는 비트 위치가 1:1 — 끝에만 추가.
    regex_duplicate_named_groups,
    /// ES2025 inline modifier group `(?ims-ims:...)` (#4210). 미지원 타겟에선
    /// 다운레벨 부재 — verbatim 패스스루 + loud 진단으로 silent SyntaxError 방지.
    regex_modifiers,

    /// 이 feature가 도입된 ES 버전.
    pub fn esVersion(self: Feature) ESTarget {
        return switch (self) {
            .arrow, .class, .template_literal, .destructuring, .for_of, .spread, .object_extensions, .default_params, .block_scoping, .generator, .new_target, .regex_sticky, .unicode_brace_escape => .es2015,
            .exponentiation => .es2016,
            .async_await => .es2017,
            .object_spread, .regex_dotall, .regex_named_groups => .es2018,
            .optional_catch_binding => .es2019,
            .nullish_coalescing, .optional_chaining => .es2020,
            .logical_assignment => .es2021,
            .class_static_block, .class_private_method, .class_private_field, .top_level_await => .es2022,
            .hashbang => .es2023,
            .using, .regex_duplicate_named_groups, .regex_modifiers => .es2025,
        };
    }
};

// ─── Unsupported Features bitmask ───
// 각 비트가 true이면 해당 feature를 다운레벨링해야 함.

pub const UnsupportedFeatures = packed struct(u32) {
    // ES2015
    arrow: bool = false,
    class: bool = false,
    template_literal: bool = false,
    destructuring: bool = false,
    for_of: bool = false,
    spread: bool = false,
    object_extensions: bool = false, // computed + shorthand properties
    default_params: bool = false,
    block_scoping: bool = false,
    generator: bool = false,
    new_target: bool = false,
    // ES2016
    exponentiation: bool = false,
    // ES2017
    async_await: bool = false,
    // ES2018
    object_spread: bool = false,
    // ES2019
    optional_catch_binding: bool = false,
    // ES2020
    nullish_coalescing: bool = false,
    optional_chaining: bool = false,
    // ES2021
    logical_assignment: bool = false,
    // ES2022
    class_static_block: bool = false,
    class_private_method: bool = false,
    class_private_field: bool = false,
    /// Top-level await (모듈 최상단 await). ES2022부터 지원. 미지원 타겟에서는
    /// top-level 문장을 async IIFE 로 감싸 wrapping (esbuild 호환). (#1384)
    top_level_await: bool = false,
    // ES2023
    hashbang: bool = false,
    // ES2025
    using: bool = false,
    // Regex features
    regex_sticky: bool = false,
    regex_dotall: bool = false,
    regex_named_groups: bool = false,
    unicode_brace_escape: bool = false,
    regex_duplicate_named_groups: bool = false,
    /// ES2025 inline modifier group `(?ims-ims:...)` (#4210). s-enabling `(?s:)` 는
    /// 다운레벨(needsRegexLowering 포함), i/m/disabling 잔여는 보존 + 진단.
    regex_modifiers: bool = false,

    _: u2 = 0,

    /// regex literal lowering 이 필요한 비트가 하나라도 set 인지.
    /// node_dispatch 조기탈출/graph prepass 게이트가 공유 — 새 regex 비트는
    /// 여기 한 곳만 추가하면 된다 (#4199 에서 게이트 2곳 누락이 실제 발생).
    pub fn needsRegexLowering(self: @This()) bool {
        return self.regex_dotall or self.regex_named_groups or self.regex_sticky or
            self.unicode_brace_escape or self.regex_duplicate_named_groups or self.regex_modifiers;
    }

    /// 어떤 feature flag 라도 set 됐는지 (= packed struct 가 zero 가 아닌지).
    /// `.{}` (기본값, 모든 비트 false) 와 명시적으로 어느 비트라도 set 된 상태를 구분할 때 사용.
    pub fn hasAny(self: @This()) bool {
        return @as(u32, @bitCast(self)) != 0;
    }

    // Feature enum과 UnsupportedFeatures 필드 순서 1:1 대응 검증.
    // Feature 추가/재배치 시 여기서 컴파일 에러가 발생한다.
    comptime {
        const feature_fields = std.meta.fields(Feature);
        const struct_fields = std.meta.fields(UnsupportedFeatures);
        for (feature_fields) |ff| {
            std.debug.assert(std.mem.eql(u8, ff.name, struct_fields[ff.value].name));
        }
    }

    /// ES2015 feature 중 하나라도 unsupported이면 true.
    pub fn needsAnyES2015(self: UnsupportedFeatures) bool {
        const mask: u32 = (1 << 11) - 1; // 하위 11비트 (arrow ~ new_target)
        return (@as(u32, @bitCast(self)) & mask) != 0;
    }

    /// 미지원 feature를 합산 (OR). 가장 보수적인 결과.
    pub fn merge(self: UnsupportedFeatures, other: UnsupportedFeatures) UnsupportedFeatures {
        return @bitCast(@as(u32, @bitCast(self)) | @as(u32, @bitCast(other)));
    }

    /// class / class_private_field / class_private_method 중 하나라도 unsupported 면 true.
    /// transformer 가 raw private syntax 를 lowering 할 책임이 있는 경우 — codegen 의 invariant
    /// assert 와 emitter/transpile 옵션 전파에 사용.
    pub fn requiresPrivateDownlevel(self: UnsupportedFeatures) bool {
        return self.class or self.class_private_field or self.class_private_method;
    }

    /// object literal method shorthand 를 `key: function` 형태로 낮춰야 하는 타겟인지.
    /// object_extensions 미지원이면 전부 변환 대상이고, Hermes/RN 처럼 shorthand 자체는
    /// 지원하지만 async/generator method 만 낮춰야 하는 경우도 포함. node 단위 정밀 판정 전에
    /// 멤버 순회를 건너뛰기 위한 cheap gate.
    pub fn needsObjectMethodDownlevel(self: UnsupportedFeatures) bool {
        return self.object_extensions or self.async_await or self.generator;
    }

    /// `for await (... of ...)` 는 ES2018 문법. 전용 feature 비트가 없어서, ES2018 비트
    /// (object_spread / regex_dotall / regex_named_groups) 중 하나라도 unsupported 면
    /// "타겟이 ES2018 미만" 으로 간주. async_await (ES2017) 도 같이 OR — ES2017 미지원 타겟은
    /// 당연히 ES2018 도 미지원이므로 별도 분기 없이 동일 경로로 처리.
    pub fn needsForAwaitOfDownlevel(self: UnsupportedFeatures) bool {
        return self.async_await or self.object_spread or self.regex_dotall or self.regex_named_groups;
    }
};

// ─── 엔진 버전 ───

pub const EngineVersion = struct {
    engine: Engine,
    major: u16,
    minor: u16 = 0,

    /// "chrome80", "safari14.1", "node16" → EngineVersion.
    pub fn fromString(s: []const u8) ?EngineVersion {
        var digit_start: ?usize = null;
        for (s, 0..) |c, i| {
            if (c >= '0' and c <= '9') {
                digit_start = i;
                break;
            }
        }
        const split = digit_start orelse return null;
        if (split == 0) return null;
        const engine = Engine.fromString(s[0..split]) orelse return null;
        const ver = parseMajorMinor(s[split..]) orelse return null;
        return .{ .engine = engine, .major = ver.major, .minor = ver.minor };
    }
};

/// 버전 비교. a < b 이면 true.
fn versionLessThan(a_major: u16, a_minor: u16, b_major: u16, b_minor: u16) bool {
    if (a_major != b_major) return a_major < b_major;
    return a_minor < b_minor;
}

/// browserslist entry 한 줄 → EngineVersion.
/// 다음 형식 모두 흡수:
///   - 표준 출력: "chrome 100", "ios_saf 14.5"
///   - 사용자 직접 쿼리: "chrome >= 87", "chrome>=87", "chrome 87"
///   - 공백 없는 형식: "chrome87" (`EngineVersion.fromString` 과 동등)
/// 매핑 불가능한 엔진 (samsung, kaios 등) 또는 stat 쿼리 (defaults, > 0.5%) 는 null.
pub fn parseBrowserslistEntry(s: []const u8) ?EngineVersion {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return null;

    var name_end: usize = 0;
    while (name_end < trimmed.len) : (name_end += 1) {
        const c = trimmed[name_end];
        if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_')) break;
    }
    if (name_end == 0) return null;
    const name_raw = trimmed[0..name_end];

    // operator (>=, >, <=, <, =, ~) skip — Zig CLI 가 raw query 도 받음.
    // browserslist 패키지 표준 출력에는 operator 가 없지만 사용자 직접 입력에는 흔함.
    var rest = std.mem.trim(u8, trimmed[name_end..], " \t");
    while (rest.len > 0 and (rest[0] == '>' or rest[0] == '<' or rest[0] == '=' or rest[0] == '~')) {
        rest = std.mem.trim(u8, rest[1..], " \t");
    }
    if (rest.len == 0) return null;

    // range "87-89" 는 좌단만 흡수 — 가장 낮은 버전 기준 보수적 downlevel.
    var ver_end: usize = 0;
    while (ver_end < rest.len) : (ver_end += 1) {
        const c = rest[ver_end];
        if (!((c >= '0' and c <= '9') or c == '.')) break;
    }
    if (ver_end == 0) return null;
    const ver_str = rest[0..ver_end];

    // browserslist alias → ZNTC Engine. `Engine.fromString` 이 lowercase 정규화하므로
    // 비교만 case-insensitive 로. Opera (Blink 15+) 는 Chromium 기반이라 chrome 으로 매핑하고
    // 버전도 Chromium 으로 변환 — compat_table 에 opera 를 별도 추가하지 않아도 정확한 feature
    // 매트릭스가 적용됨.
    const is_opera = std.ascii.eqlIgnoreCase(name_raw, "opera") or std.ascii.eqlIgnoreCase(name_raw, "op_mob");
    const engine_str: []const u8 =
        if (std.ascii.eqlIgnoreCase(name_raw, "ios_saf")) "ios" else if (std.ascii.eqlIgnoreCase(name_raw, "and_chr")) "chrome" else if (std.ascii.eqlIgnoreCase(name_raw, "and_ff")) "firefox" else if (is_opera) "chrome" else name_raw;
    const engine = Engine.fromString(engine_str) orelse return null;

    const ver = parseMajorMinor(ver_str) orelse return null;
    const major = if (is_opera) (operaToChromium(ver.major) orelse return null) else ver.major;
    return .{ .engine = engine, .major = major, .minor = ver.minor };
}

/// Opera (Blink) major → 대응 Chromium major.
/// Opera 15+ 는 Blink 엔진으로 전환 — Presto (14 이하) 는 Chrome 매트릭스로 매핑할 수 없어 null.
/// 정확한 매핑은 Opera changelog 기준이지만 (15→28, 36→49, 60→73, 75→88, 80→94),
/// 보수적 근사 (Opera + 14) 로 단순화 — 실제 Chromium 버전보다 약간 낮게 잡혀 over-downlevel.
/// 보수적 over-downlevel 은 안전한 방향 (런타임 미지원 syntax 노출 위험 < 약간의 번들 사이즈).
fn operaToChromium(opera_major: u16) ?u16 {
    if (opera_major < 15) return null;
    return opera_major + 13;
}

/// "100" / "14.5" / "16.11" → {major, minor}. parseInt 실패 시 null.
fn parseMajorMinor(s: []const u8) ?struct { major: u16, minor: u16 } {
    if (std.mem.indexOf(u8, s, ".")) |dot| {
        const major = std.fmt.parseInt(u16, s[0..dot], 10) catch return null;
        const minor = std.fmt.parseInt(u16, s[dot + 1 ..], 10) catch return null;
        return .{ .major = major, .minor = minor };
    }
    const major = std.fmt.parseInt(u16, s, 10) catch return null;
    return .{ .major = major, .minor = 0 };
}

/// browserslist 쿼리 → UnsupportedFeatures bitmask.
/// comma 로 split 후 각 entry 를 `parseBrowserslistEntry` 로 파싱. 하나라도 실패하면 null.
/// stat 기반 쿼리 ("defaults", "last 2 versions", "> 0.5%") 는 caniuse-lite 데이터가 필요해
/// Zig CLI 에서는 미지원 — 호출자가 친절한 에러 메시지로 안내.
pub fn browserslistToUnsupported(query: []const u8) ?UnsupportedFeatures {
    // 64 = browserslist 의 "defaults" 도 ~30 entry, 일반 query 의 안전한 상한.
    var engines: [64]EngineVersion = undefined;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, query, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const ev = parseBrowserslistEntry(trimmed) orelse return null;
        if (count >= engines.len) return null;
        engines[count] = ev;
        count += 1;
    }
    if (count == 0) return null;
    return unsupportedFeatures(engines[0..count]);
}

// ─── Compat Table ───
// esbuild compat-table.go 기준 (2026-03-31 교차검증)
// 각 엔트리: (feature, engine, major, minor) = "이 엔진의 이 버전부터 지원"
// 엔트리가 없으면 해당 엔진에서 미지원으로 간주.

const CompatEntry = struct {
    feature: Feature,
    engine: Engine,
    major: u16,
    minor: u16 = 0,
};

const compat_table = [_]CompatEntry{
    // ── ES2015: arrow ──
    .{ .feature = .arrow, .engine = .chrome, .major = 49 },
    .{ .feature = .arrow, .engine = .firefox, .major = 45 },
    .{ .feature = .arrow, .engine = .safari, .major = 10 },
    .{ .feature = .arrow, .engine = .edge, .major = 13 },
    .{ .feature = .arrow, .engine = .node, .major = 6 },
    .{ .feature = .arrow, .engine = .deno, .major = 1 },
    .{ .feature = .arrow, .engine = .ios, .major = 10 },
    .{ .feature = .arrow, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: class ──
    .{ .feature = .class, .engine = .chrome, .major = 49 },
    .{ .feature = .class, .engine = .firefox, .major = 45 },
    .{ .feature = .class, .engine = .safari, .major = 10 },
    .{ .feature = .class, .engine = .edge, .major = 13 },
    .{ .feature = .class, .engine = .node, .major = 6 },
    .{ .feature = .class, .engine = .deno, .major = 1 },
    .{ .feature = .class, .engine = .ios, .major = 10 },
    .{ .feature = .class, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: template_literal ──
    // esbuild는 tagged template caching 기준으로 더 높은 버전 요구
    .{ .feature = .template_literal, .engine = .chrome, .major = 62 },
    .{ .feature = .template_literal, .engine = .firefox, .major = 53 },
    .{ .feature = .template_literal, .engine = .safari, .major = 13 },
    .{ .feature = .template_literal, .engine = .edge, .major = 79 },
    .{ .feature = .template_literal, .engine = .node, .major = 8, .minor = 10 },
    .{ .feature = .template_literal, .engine = .deno, .major = 1 },
    .{ .feature = .template_literal, .engine = .ios, .major = 13 },
    .{ .feature = .template_literal, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: destructuring ──
    .{ .feature = .destructuring, .engine = .chrome, .major = 51 },
    .{ .feature = .destructuring, .engine = .firefox, .major = 53 },
    .{ .feature = .destructuring, .engine = .safari, .major = 10 },
    .{ .feature = .destructuring, .engine = .edge, .major = 18 },
    .{ .feature = .destructuring, .engine = .node, .major = 6, .minor = 5 },
    .{ .feature = .destructuring, .engine = .deno, .major = 1 },
    .{ .feature = .destructuring, .engine = .ios, .major = 10 },
    .{ .feature = .destructuring, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: for_of ──
    .{ .feature = .for_of, .engine = .chrome, .major = 51 },
    .{ .feature = .for_of, .engine = .firefox, .major = 53 },
    .{ .feature = .for_of, .engine = .safari, .major = 10 },
    .{ .feature = .for_of, .engine = .edge, .major = 15 },
    .{ .feature = .for_of, .engine = .node, .major = 6, .minor = 5 },
    .{ .feature = .for_of, .engine = .deno, .major = 1 },
    .{ .feature = .for_of, .engine = .ios, .major = 10 },
    .{ .feature = .for_of, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: spread ──
    .{ .feature = .spread, .engine = .chrome, .major = 46 },
    .{ .feature = .spread, .engine = .firefox, .major = 36 },
    .{ .feature = .spread, .engine = .safari, .major = 10 },
    .{ .feature = .spread, .engine = .edge, .major = 13 },
    .{ .feature = .spread, .engine = .node, .major = 5 },
    .{ .feature = .spread, .engine = .deno, .major = 1 },
    .{ .feature = .spread, .engine = .ios, .major = 10 },
    .{ .feature = .spread, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: object_extensions (computed + shorthand) ──
    .{ .feature = .object_extensions, .engine = .chrome, .major = 44 },
    .{ .feature = .object_extensions, .engine = .firefox, .major = 34 },
    .{ .feature = .object_extensions, .engine = .safari, .major = 10 },
    .{ .feature = .object_extensions, .engine = .edge, .major = 12 },
    .{ .feature = .object_extensions, .engine = .node, .major = 4 },
    .{ .feature = .object_extensions, .engine = .deno, .major = 1 },
    .{ .feature = .object_extensions, .engine = .ios, .major = 10 },
    .{ .feature = .object_extensions, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: default_params ──
    .{ .feature = .default_params, .engine = .chrome, .major = 49 },
    .{ .feature = .default_params, .engine = .firefox, .major = 53 },
    .{ .feature = .default_params, .engine = .safari, .major = 10 },
    .{ .feature = .default_params, .engine = .edge, .major = 14 },
    .{ .feature = .default_params, .engine = .node, .major = 6 },
    .{ .feature = .default_params, .engine = .deno, .major = 1 },
    .{ .feature = .default_params, .engine = .ios, .major = 10 },
    .{ .feature = .default_params, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: block_scoping ──
    .{ .feature = .block_scoping, .engine = .chrome, .major = 49 },
    .{ .feature = .block_scoping, .engine = .firefox, .major = 51 },
    .{ .feature = .block_scoping, .engine = .safari, .major = 11 },
    .{ .feature = .block_scoping, .engine = .edge, .major = 14 },
    .{ .feature = .block_scoping, .engine = .node, .major = 6 },
    .{ .feature = .block_scoping, .engine = .deno, .major = 1 },
    .{ .feature = .block_scoping, .engine = .ios, .major = 11 },
    .{ .feature = .block_scoping, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: generator ──
    .{ .feature = .generator, .engine = .chrome, .major = 50 },
    .{ .feature = .generator, .engine = .firefox, .major = 53 },
    .{ .feature = .generator, .engine = .safari, .major = 10 },
    .{ .feature = .generator, .engine = .edge, .major = 13 },
    .{ .feature = .generator, .engine = .node, .major = 6 },
    .{ .feature = .generator, .engine = .deno, .major = 1 },
    .{ .feature = .generator, .engine = .ios, .major = 10 },
    .{ .feature = .generator, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2015: new.target ──
    .{ .feature = .new_target, .engine = .chrome, .major = 46 },
    .{ .feature = .new_target, .engine = .firefox, .major = 41 },
    .{ .feature = .new_target, .engine = .safari, .major = 10 },
    .{ .feature = .new_target, .engine = .edge, .major = 13 },
    .{ .feature = .new_target, .engine = .node, .major = 5 },
    .{ .feature = .new_target, .engine = .deno, .major = 1 },
    .{ .feature = .new_target, .engine = .ios, .major = 10 },
    .{ .feature = .new_target, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2016: exponentiation (**) ──
    .{ .feature = .exponentiation, .engine = .chrome, .major = 52 },
    .{ .feature = .exponentiation, .engine = .firefox, .major = 52 },
    .{ .feature = .exponentiation, .engine = .safari, .major = 10, .minor = 1 },
    .{ .feature = .exponentiation, .engine = .edge, .major = 14 },
    .{ .feature = .exponentiation, .engine = .node, .major = 7 },
    .{ .feature = .exponentiation, .engine = .deno, .major = 1 },
    .{ .feature = .exponentiation, .engine = .ios, .major = 10, .minor = 3 },
    .{ .feature = .exponentiation, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2017: async_await ──
    .{ .feature = .async_await, .engine = .chrome, .major = 55 },
    .{ .feature = .async_await, .engine = .firefox, .major = 52 },
    .{ .feature = .async_await, .engine = .safari, .major = 11 },
    .{ .feature = .async_await, .engine = .edge, .major = 15 },
    .{ .feature = .async_await, .engine = .node, .major = 7, .minor = 6 },
    .{ .feature = .async_await, .engine = .deno, .major = 1 },
    .{ .feature = .async_await, .engine = .ios, .major = 11 },
    // hermes 0.7 = 0/16 미지원, hermes 0.12 = 16/16 (compat-table.github.io 검증)
    .{ .feature = .async_await, .engine = .hermes, .major = 0, .minor = 12 },

    // ── ES2018: object_spread ──
    .{ .feature = .object_spread, .engine = .chrome, .major = 60 },
    .{ .feature = .object_spread, .engine = .firefox, .major = 55 },
    .{ .feature = .object_spread, .engine = .safari, .major = 11, .minor = 1 },
    .{ .feature = .object_spread, .engine = .edge, .major = 79 },
    .{ .feature = .object_spread, .engine = .node, .major = 8, .minor = 3 },
    .{ .feature = .object_spread, .engine = .deno, .major = 1 },
    .{ .feature = .object_spread, .engine = .ios, .major = 11, .minor = 3 },
    .{ .feature = .object_spread, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2019: optional_catch_binding ──
    .{ .feature = .optional_catch_binding, .engine = .chrome, .major = 66 },
    .{ .feature = .optional_catch_binding, .engine = .firefox, .major = 58 },
    .{ .feature = .optional_catch_binding, .engine = .safari, .major = 11, .minor = 1 },
    .{ .feature = .optional_catch_binding, .engine = .edge, .major = 79 },
    .{ .feature = .optional_catch_binding, .engine = .node, .major = 10 },
    .{ .feature = .optional_catch_binding, .engine = .deno, .major = 1 },
    .{ .feature = .optional_catch_binding, .engine = .ios, .major = 11, .minor = 3 },
    .{ .feature = .optional_catch_binding, .engine = .hermes, .major = 0, .minor = 12 },

    // ── ES2020: nullish_coalescing (??) ──
    .{ .feature = .nullish_coalescing, .engine = .chrome, .major = 80 },
    .{ .feature = .nullish_coalescing, .engine = .firefox, .major = 72 },
    .{ .feature = .nullish_coalescing, .engine = .safari, .major = 13, .minor = 1 },
    .{ .feature = .nullish_coalescing, .engine = .edge, .major = 80 },
    .{ .feature = .nullish_coalescing, .engine = .node, .major = 14 },
    .{ .feature = .nullish_coalescing, .engine = .deno, .major = 1 },
    .{ .feature = .nullish_coalescing, .engine = .ios, .major = 13, .minor = 4 },
    .{ .feature = .nullish_coalescing, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2020: optional_chaining (?.) ──
    .{ .feature = .optional_chaining, .engine = .chrome, .major = 91 },
    .{ .feature = .optional_chaining, .engine = .firefox, .major = 74 },
    .{ .feature = .optional_chaining, .engine = .safari, .major = 13, .minor = 1 },
    .{ .feature = .optional_chaining, .engine = .edge, .major = 91 },
    .{ .feature = .optional_chaining, .engine = .node, .major = 16, .minor = 9 },
    .{ .feature = .optional_chaining, .engine = .deno, .major = 1, .minor = 9 },
    .{ .feature = .optional_chaining, .engine = .ios, .major = 13, .minor = 4 },
    .{ .feature = .optional_chaining, .engine = .hermes, .major = 0, .minor = 12 },

    // ── ES2021: logical_assignment (??=, ||=, &&=) ──
    .{ .feature = .logical_assignment, .engine = .chrome, .major = 85 },
    .{ .feature = .logical_assignment, .engine = .firefox, .major = 79 },
    .{ .feature = .logical_assignment, .engine = .safari, .major = 14 },
    .{ .feature = .logical_assignment, .engine = .edge, .major = 85 },
    .{ .feature = .logical_assignment, .engine = .node, .major = 15 },
    .{ .feature = .logical_assignment, .engine = .deno, .major = 1, .minor = 2 },
    .{ .feature = .logical_assignment, .engine = .ios, .major = 14 },
    .{ .feature = .logical_assignment, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2022: class_static_block ──
    .{ .feature = .class_static_block, .engine = .chrome, .major = 91 },
    .{ .feature = .class_static_block, .engine = .firefox, .major = 93 },
    .{ .feature = .class_static_block, .engine = .safari, .major = 16, .minor = 4 },
    .{ .feature = .class_static_block, .engine = .edge, .major = 94 },
    .{ .feature = .class_static_block, .engine = .node, .major = 16, .minor = 11 },
    .{ .feature = .class_static_block, .engine = .deno, .major = 1, .minor = 14 },
    .{ .feature = .class_static_block, .engine = .ios, .major = 16, .minor = 4 },

    // ── ES2022: class_private_method ──
    // Private methods (#method): Chrome 84, Firefox 90, Safari 15
    .{ .feature = .class_private_method, .engine = .chrome, .major = 84 },
    .{ .feature = .class_private_method, .engine = .firefox, .major = 90 },
    .{ .feature = .class_private_method, .engine = .safari, .major = 15 },
    .{ .feature = .class_private_method, .engine = .edge, .major = 84 },
    .{ .feature = .class_private_method, .engine = .node, .major = 14, .minor = 6 },
    .{ .feature = .class_private_method, .engine = .deno, .major = 1 },
    .{ .feature = .class_private_method, .engine = .ios, .major = 15 },
    // hermes: private methods 미지원 → compat_table에 없음 → 항상 다운레벨링

    // ── ES2022: class_private_field ──
    // Private instance fields (#field): Chrome 74, Firefox 90, Safari 14.1
    .{ .feature = .class_private_field, .engine = .chrome, .major = 74 },
    .{ .feature = .class_private_field, .engine = .firefox, .major = 90 },
    .{ .feature = .class_private_field, .engine = .safari, .major = 14, .minor = 1 },
    .{ .feature = .class_private_field, .engine = .edge, .major = 79 },
    .{ .feature = .class_private_field, .engine = .node, .major = 12 },
    .{ .feature = .class_private_field, .engine = .deno, .major = 1 },
    .{ .feature = .class_private_field, .engine = .ios, .major = 14, .minor = 5 },
    // hermes: private fields 미지원 → 항상 다운레벨링

    // ── ES2022: top_level_await ──
    // Top-level await (ES modules): Chrome 89, Firefox 89, Safari 15, Node 14.8
    .{ .feature = .top_level_await, .engine = .chrome, .major = 89 },
    .{ .feature = .top_level_await, .engine = .firefox, .major = 89 },
    .{ .feature = .top_level_await, .engine = .safari, .major = 15 },
    .{ .feature = .top_level_await, .engine = .edge, .major = 89 },
    .{ .feature = .top_level_await, .engine = .node, .major = 14, .minor = 8 },
    .{ .feature = .top_level_await, .engine = .deno, .major = 1 },
    .{ .feature = .top_level_await, .engine = .ios, .major = 15 },
    // hermes: 미지원 → 항상 다운레벨링

    // ── ES2023: hashbang (#!) ──
    .{ .feature = .hashbang, .engine = .chrome, .major = 74 },
    .{ .feature = .hashbang, .engine = .firefox, .major = 67 },
    .{ .feature = .hashbang, .engine = .safari, .major = 13, .minor = 1 },
    .{ .feature = .hashbang, .engine = .edge, .major = 79 },
    .{ .feature = .hashbang, .engine = .node, .major = 12 },
    .{ .feature = .hashbang, .engine = .deno, .major = 1 },
    .{ .feature = .hashbang, .engine = .ios, .major = 13, .minor = 4 },
    .{ .feature = .hashbang, .engine = .hermes, .major = 0 },

    // ── ES2025: using (Explicit Resource Management) ──
    .{ .feature = .using, .engine = .chrome, .major = 134 },
    .{ .feature = .using, .engine = .firefox, .major = 132 },
    .{ .feature = .using, .engine = .safari, .major = 18, .minor = 2 },
    .{ .feature = .using, .engine = .node, .major = 22 },
    .{ .feature = .using, .engine = .deno, .major = 1, .minor = 38 },

    // ── ES2025: duplicate named capture groups (#4199) ── (hermes row 없음 = 미지원)
    .{ .feature = .regex_duplicate_named_groups, .engine = .chrome, .major = 125 },
    .{ .feature = .regex_duplicate_named_groups, .engine = .edge, .major = 125 },
    .{ .feature = .regex_duplicate_named_groups, .engine = .firefox, .major = 129 },
    .{ .feature = .regex_duplicate_named_groups, .engine = .safari, .major = 17, .minor = 4 },
    .{ .feature = .regex_duplicate_named_groups, .engine = .ios, .major = 17, .minor = 4 },
    .{ .feature = .regex_duplicate_named_groups, .engine = .node, .major = 23 },
    .{ .feature = .regex_duplicate_named_groups, .engine = .deno, .major = 1, .minor = 44 },
    // edge, ios, hermes: 미지원 → compat_table에 없음 → 항상 다운레벨링

    // ── ES2025: regex inline modifiers `(?ims-ims:...)` (#4210) ──
    // BCD: safari 가 26 으로 늦음(dup-named 의 17.4 와 다름). hermes 미지원.
    .{ .feature = .regex_modifiers, .engine = .chrome, .major = 125 },
    .{ .feature = .regex_modifiers, .engine = .edge, .major = 125 },
    .{ .feature = .regex_modifiers, .engine = .firefox, .major = 132 },
    .{ .feature = .regex_modifiers, .engine = .safari, .major = 26 },
    .{ .feature = .regex_modifiers, .engine = .ios, .major = 26 },
    .{ .feature = .regex_modifiers, .engine = .node, .major = 23 },
    .{ .feature = .regex_modifiers, .engine = .deno, .major = 1, .minor = 44 },

    // ── ES2015: regex_sticky (/y) ──
    .{ .feature = .regex_sticky, .engine = .chrome, .major = 49 },
    .{ .feature = .regex_sticky, .engine = .firefox, .major = 3 },
    .{ .feature = .regex_sticky, .engine = .safari, .major = 10 },
    .{ .feature = .regex_sticky, .engine = .edge, .major = 13 },
    .{ .feature = .regex_sticky, .engine = .node, .major = 6 },
    .{ .feature = .regex_sticky, .engine = .deno, .major = 1 },
    .{ .feature = .regex_sticky, .engine = .ios, .major = 10 },
    .{ .feature = .regex_sticky, .engine = .hermes, .major = 0, .minor = 7 },

    // ── ES2018: regex_dotall (/s) ──
    .{ .feature = .regex_dotall, .engine = .chrome, .major = 62 },
    .{ .feature = .regex_dotall, .engine = .firefox, .major = 78 },
    .{ .feature = .regex_dotall, .engine = .safari, .major = 11, .minor = 1 },
    .{ .feature = .regex_dotall, .engine = .edge, .major = 79 },
    .{ .feature = .regex_dotall, .engine = .node, .major = 8, .minor = 10 },
    .{ .feature = .regex_dotall, .engine = .deno, .major = 1 },
    .{ .feature = .regex_dotall, .engine = .ios, .major = 11, .minor = 3 },
    // hermes: 미지원

    // ── ES2015: unicode_brace_escape (`\u{XXXX}`) ──
    // 문자열/regex의 brace unicode escape. ES2015 도입.
    .{ .feature = .unicode_brace_escape, .engine = .chrome, .major = 44 },
    .{ .feature = .unicode_brace_escape, .engine = .firefox, .major = 53 },
    .{ .feature = .unicode_brace_escape, .engine = .safari, .major = 10 },
    .{ .feature = .unicode_brace_escape, .engine = .edge, .major = 12 },
    .{ .feature = .unicode_brace_escape, .engine = .node, .major = 4 },
    .{ .feature = .unicode_brace_escape, .engine = .deno, .major = 1 },
    .{ .feature = .unicode_brace_escape, .engine = .ios, .major = 10 },
    .{ .feature = .unicode_brace_escape, .engine = .hermes, .major = 0 },

    // ── ES2018: regex_named_groups ──
    .{ .feature = .regex_named_groups, .engine = .chrome, .major = 64 },
    .{ .feature = .regex_named_groups, .engine = .firefox, .major = 78 },
    .{ .feature = .regex_named_groups, .engine = .safari, .major = 11, .minor = 1 },
    .{ .feature = .regex_named_groups, .engine = .edge, .major = 79 },
    .{ .feature = .regex_named_groups, .engine = .node, .major = 10 },
    .{ .feature = .regex_named_groups, .engine = .deno, .major = 1 },
    .{ .feature = .regex_named_groups, .engine = .ios, .major = 11, .minor = 3 },
    // hermes: 미지원
};

// ─── 변환 함수 ───

/// comptime: 특정 엔진이 특정 feature를 지원하기 시작하는 최소 버전.
/// compat_table에 없으면 null (= 해당 엔진에서 미지원).
fn getMinVersion(engine: Engine, feature: Feature) ?struct { major: u16, minor: u16 } {
    for (compat_table) |entry| {
        if (entry.feature == feature and entry.engine == engine) {
            return .{ .major = entry.major, .minor = entry.minor };
        }
    }
    return null;
}

/// React Native (Hermes) preset.
/// 명시되지 않은 features 는 native keep (default false).
pub fn fromHermesPreset() UnsupportedFeatures {
    // NOTE: regex_duplicate_named_groups 비트는 별도 set 안 함 — 아래
    // regex_named_groups=true 가 strip 경로를 superset 으로 커버 (#4199).
    return .{
        // 호환 마진 다운레벨링 (closure 의미 / state machine 종속 / Hermes runtime 버그 회피)
        .arrow = true, // #1299: object property arrow ternary 뒤 prop 누락
        .class = true,
        .block_scoping = true,
        .generator = true,
        .async_await = true,
        .new_target = true,
        // Hermes 미지원
        .class_static_block = true,
        .class_private_method = true,
        .class_private_field = true,
        .top_level_await = true,
        .using = true,
        .regex_dotall = true,
        .regex_named_groups = true,
        .unicode_brace_escape = true,
    };
}

/// ESTarget → UnsupportedFeatures.
/// 타겟 ES 버전보다 높은 버전에서 도입된 feature를 unsupported로 설정.
pub fn fromESTarget(target: ESTarget) UnsupportedFeatures {
    const t = @intFromEnum(target);
    var bits: u32 = 0;
    inline for (std.meta.fields(Feature)) |f| {
        const feature: Feature = @enumFromInt(f.value);
        // feature의 도입 버전이 타겟보다 높으면 다운레벨링 필요
        if (t < @intFromEnum(feature.esVersion())) {
            bits |= (@as(u32, 1) << f.value);
        }
    }
    return @bitCast(bits);
}

/// 엔진 버전 목록 → UnsupportedFeatures.
/// 미지원 feature의 union: 하나라도 미지원이면 해당 feature를 다운레벨링.
pub fn unsupportedFeatures(targets: []const EngineVersion) UnsupportedFeatures {
    var result: u32 = 0;

    for (targets) |target| {
        var engine_unsupported: u32 = 0;

        inline for (std.meta.fields(Feature)) |f| {
            const feature: Feature = @enumFromInt(f.value);
            const min_ver = getMinVersion(target.engine, feature);

            const is_unsupported = if (min_ver) |mv|
                versionLessThan(target.major, target.minor, mv.major, mv.minor)
            else
                true; // compat table에 없으면 해당 엔진에서 미지원

            if (is_unsupported) {
                engine_unsupported |= (@as(u32, 1) << f.value);
            }
        }

        result |= engine_unsupported;
    }

    return @bitCast(result);
}

// ─── 테스트 ───

test "fromESTarget — esnext는 모두 false" {
    const f = fromESTarget(.esnext);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(f)));
}

test "fromESTarget — es5는 모든 feature true" {
    const f = fromESTarget(.es5);
    try std.testing.expect(f.arrow);
    try std.testing.expect(f.class);
    try std.testing.expect(f.template_literal);
    try std.testing.expect(f.destructuring);
    try std.testing.expect(f.for_of);
    try std.testing.expect(f.spread);
    try std.testing.expect(f.object_extensions);
    try std.testing.expect(f.default_params);
    try std.testing.expect(f.block_scoping);
    try std.testing.expect(f.generator);
    try std.testing.expect(f.exponentiation);
    try std.testing.expect(f.async_await);
    try std.testing.expect(f.object_spread);
    try std.testing.expect(f.optional_catch_binding);
    try std.testing.expect(f.nullish_coalescing);
    try std.testing.expect(f.optional_chaining);
    try std.testing.expect(f.logical_assignment);
    try std.testing.expect(f.class_static_block);
    try std.testing.expect(f.class_private_method);
    try std.testing.expect(f.using);
}

test "fromESTarget — es2020은 ES2020까지 지원, ES2021 이상 미지원" {
    const f = fromESTarget(.es2020);
    // ES2020까지 지원 → false
    try std.testing.expect(!f.nullish_coalescing);
    try std.testing.expect(!f.optional_chaining);
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.exponentiation);
    try std.testing.expect(!f.async_await);
    try std.testing.expect(!f.object_spread);
    try std.testing.expect(!f.optional_catch_binding);
    // ES2021 이상 미지원 → true
    try std.testing.expect(f.logical_assignment);
    try std.testing.expect(f.class_static_block);
    try std.testing.expect(f.class_private_method);
}

test "unsupportedFeatures — chrome80" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .chrome, .major = 80 },
    });
    // Chrome 80은 arrow(49), class(49) 등 ES2015 지원
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.class);
    // Chrome 80은 nullish coalescing(80) 지원
    try std.testing.expect(!f.nullish_coalescing);
    // Chrome 80은 optional chaining(91) 미지원
    try std.testing.expect(f.optional_chaining);
    // Chrome 80은 class static block(91) 미지원
    try std.testing.expect(f.class_static_block);
    // Chrome 80 < 84 → private method 미지원
    try std.testing.expect(f.class_private_method);
}

test "unsupportedFeatures — chrome80,safari14 교집합" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .chrome, .major = 80 },
        .{ .engine = .safari, .major = 14 },
    });
    // 둘 다 arrow 지원
    try std.testing.expect(!f.arrow);
    // Chrome 80: optional chaining 미지원 → 전체 결과도 미지원
    try std.testing.expect(f.optional_chaining);
    // Safari 14: class static block(16.4) 미지원 → 전체 결과도 미지원
    try std.testing.expect(f.class_static_block);
    // 둘 다 logical assignment 미지원 (Chrome 85, Safari 14)
    // Chrome 80 < 85 → 미지원
    try std.testing.expect(f.logical_assignment);
    // Safari 14 < 15 → private method 미지원
    try std.testing.expect(f.class_private_method);
}

test "unsupportedFeatures — hermes 0.12 지원/미지원 구분" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .hermes, .major = 0, .minor = 12 },
    });
    // hermes 0.7+: ES2015 (arrow/class/template_literal 등) 지원
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.class);
    try std.testing.expect(!f.template_literal);
    // hermes 0.12: async_await + optional_chaining 지원
    try std.testing.expect(!f.async_await);
    try std.testing.expect(!f.for_of);
    try std.testing.expect(!f.optional_chaining);
    // hermes: private methods 미지원 (compat table에 없음)
    try std.testing.expect(f.class_private_method);
}

test "needsAnyES2015 — es2020은 false" {
    const f = fromESTarget(.es2020);
    try std.testing.expect(!f.needsAnyES2015());
}

test "needsAnyES2015 — es5는 true" {
    const f = fromESTarget(.es5);
    try std.testing.expect(f.needsAnyES2015());
}

test "merge — 두 bitmask 합산" {
    const a = UnsupportedFeatures{ .arrow = true };
    const b = UnsupportedFeatures{ .class = true };
    const merged = a.merge(b);
    try std.testing.expect(merged.arrow);
    try std.testing.expect(merged.class);
    try std.testing.expect(!merged.template_literal);
}

test "Engine.fromString — 정상 케이스" {
    try std.testing.expectEqual(Engine.chrome, Engine.fromString("chrome").?);
    try std.testing.expectEqual(Engine.chrome, Engine.fromString("Chrome").?);
    try std.testing.expectEqual(Engine.safari, Engine.fromString("safari").?);
    try std.testing.expectEqual(Engine.node, Engine.fromString("node").?);
    try std.testing.expectEqual(Engine.hermes, Engine.fromString("hermes").?);
    try std.testing.expectEqual(Engine.ios, Engine.fromString("ios").?);
    try std.testing.expectEqual(Engine.deno, Engine.fromString("deno").?);
}

test "Engine.fromString — 에러 케이스" {
    try std.testing.expectEqual(@as(?Engine, null), Engine.fromString("unknown"));
    try std.testing.expectEqual(@as(?Engine, null), Engine.fromString(""));
    try std.testing.expectEqual(@as(?Engine, null), Engine.fromString("verylongenginenameover10"));
}

// ─── fromESTarget 경계값 테스트 ───

test "fromESTarget — es2015는 ES2015만 지원" {
    const f = fromESTarget(.es2015);
    // ES2015 자체는 지원 → false
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.class);
    try std.testing.expect(!f.generator);
    // ES2016부터는 미지원 → true
    try std.testing.expect(f.exponentiation);
    try std.testing.expect(f.async_await);
    try std.testing.expect(f.nullish_coalescing);
}

test "fromESTarget — es2016은 exponentiation 지원" {
    const f = fromESTarget(.es2016);
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.exponentiation);
    try std.testing.expect(f.async_await); // ES2017부터
}

test "fromESTarget — es2022는 class_static_block, class_private_method 지원" {
    const f = fromESTarget(.es2022);
    try std.testing.expect(!f.class_static_block);
    try std.testing.expect(!f.class_private_method);
    try std.testing.expect(!f.logical_assignment);
    try std.testing.expect(!f.optional_chaining);
    // es2022에서 ES2023+ 미지원
    try std.testing.expect(f.hashbang);
    try std.testing.expect(f.using);
}

// ─── 엔진 버전 경계값 테스트 ───

test "unsupportedFeatures — chrome49 경계: arrow 지원 시작" {
    // chrome 48 < 49 → arrow 미지원
    const f48 = unsupportedFeatures(&.{.{ .engine = .chrome, .major = 48 }});
    try std.testing.expect(f48.arrow);
    // chrome 49 >= 49 → arrow 지원
    const f49 = unsupportedFeatures(&.{.{ .engine = .chrome, .major = 49 }});
    try std.testing.expect(!f49.arrow);
}

test "unsupportedFeatures — chrome91 경계: optional chaining + class static block" {
    const f90 = unsupportedFeatures(&.{.{ .engine = .chrome, .major = 90 }});
    try std.testing.expect(f90.optional_chaining); // 91 미만 → 미지원
    try std.testing.expect(f90.class_static_block);

    const f91 = unsupportedFeatures(&.{.{ .engine = .chrome, .major = 91 }});
    try std.testing.expect(!f91.optional_chaining); // 91 이상 → 지원
    try std.testing.expect(!f91.class_static_block);
}

test "unsupportedFeatures — safari minor 버전 경계 (10.0 vs 10.1)" {
    // safari 10.0: exponentiation(10.1) 미지원
    const f10_0 = unsupportedFeatures(&.{.{ .engine = .safari, .major = 10, .minor = 0 }});
    try std.testing.expect(f10_0.exponentiation);
    try std.testing.expect(!f10_0.arrow); // arrow(10) 지원

    // safari 10.1: exponentiation 지원
    const f10_1 = unsupportedFeatures(&.{.{ .engine = .safari, .major = 10, .minor = 1 }});
    try std.testing.expect(!f10_1.exponentiation);
}

test "unsupportedFeatures — node16.9 경계: optional chaining" {
    // node 16.8 < 16.9 → optional chaining 미지원
    const f16_8 = unsupportedFeatures(&.{.{ .engine = .node, .major = 16, .minor = 8 }});
    try std.testing.expect(f16_8.optional_chaining);

    // node 16.9 → optional chaining 지원
    const f16_9 = unsupportedFeatures(&.{.{ .engine = .node, .major = 16, .minor = 9 }});
    try std.testing.expect(!f16_9.optional_chaining);
}

// ─── 복합 엔진 타겟 ───

test "unsupportedFeatures — 3개 엔진 교집합" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .chrome, .major = 91 },
        .{ .engine = .safari, .major = 14 },
        .{ .engine = .node, .major = 16 },
    });
    // chrome91: 모두 지원 (class_static_block 포함)
    // safari14: class_static_block(16.4) 미지원
    // node16: class_static_block(16.11) 미지원, optional_chaining(16.9) 미지원
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.nullish_coalescing);
    try std.testing.expect(f.class_static_block); // safari + node 모두 미지원
    try std.testing.expect(f.optional_chaining); // node16.0 < 16.9
    try std.testing.expect(f.using); // 모든 엔진이 using 미지원
}

test "unsupportedFeatures — 최신 엔진은 모두 지원" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .chrome, .major = 134 },
        .{ .engine = .firefox, .major = 132 },
        // safari 26: regex_modifiers (#4210) 가 safari 26 부터라 이전 버전은
        // 모든 feature 지원이 아니다 (dup-named 의 17.4 와 다른 경계).
        .{ .engine = .safari, .major = 26 },
    });
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(f)));
}

test "unsupportedFeatures — hermes 0.7 지원/미지원 구분" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .hermes, .major = 0, .minor = 7 },
    });
    // hermes 0.7에서 지원하는 것들 (ES2015 baseline + ES2016~2020 일부)
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.class);
    try std.testing.expect(!f.template_literal);
    try std.testing.expect(!f.destructuring);
    try std.testing.expect(!f.default_params);
    try std.testing.expect(!f.block_scoping);
    try std.testing.expect(!f.generator);
    try std.testing.expect(!f.new_target);
    try std.testing.expect(!f.for_of);
    try std.testing.expect(!f.spread);
    try std.testing.expect(!f.object_extensions);
    try std.testing.expect(!f.exponentiation);
    try std.testing.expect(!f.object_spread);
    try std.testing.expect(!f.nullish_coalescing);
    try std.testing.expect(!f.logical_assignment);
    // hermes 0.7 < 0.12 → async_await / optional_chaining 미지원
    try std.testing.expect(f.async_await);
    try std.testing.expect(f.optional_chaining);
    // hermes 미지원 (compat table에 없음)
    try std.testing.expect(f.class_static_block);
    try std.testing.expect(f.class_private_method);
}

test "unsupportedFeatures — 단일 엔진 + hermes 교집합은 hermes 미지원이 지배" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .chrome, .major = 100 },
        .{ .engine = .hermes, .major = 0, .minor = 12 },
    });
    // chrome100 + hermes 0.12 둘 다 ES2015 + ES2020 지원
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.class);
    try std.testing.expect(!f.optional_chaining);
    // hermes 가 미지원하는 features 는 결과도 미지원 (지배)
    try std.testing.expect(f.class_private_method);
    try std.testing.expect(f.class_private_field);
    try std.testing.expect(f.top_level_await);
}

// ─── versionLessThan 엣지 케이스 ───

test "unsupportedFeatures — 정확히 같은 버전은 지원" {
    // deno 1.0 = arrow 최소 지원 버전 → 지원
    const f = unsupportedFeatures(&.{.{ .engine = .deno, .major = 1, .minor = 0 }});
    try std.testing.expect(!f.arrow);
    try std.testing.expect(!f.class);
}

test "unsupportedFeatures — 빈 타겟은 모두 지원" {
    const f = unsupportedFeatures(&.{});
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(f)));
}

// ─── EngineVersion.fromString 테스트 ───

test "EngineVersion.fromString — 정상 케이스" {
    const ev1 = EngineVersion.fromString("chrome80").?;
    try std.testing.expectEqual(Engine.chrome, ev1.engine);
    try std.testing.expectEqual(@as(u16, 80), ev1.major);
    try std.testing.expectEqual(@as(u16, 0), ev1.minor);

    const ev2 = EngineVersion.fromString("safari14.1").?;
    try std.testing.expectEqual(Engine.safari, ev2.engine);
    try std.testing.expectEqual(@as(u16, 14), ev2.major);
    try std.testing.expectEqual(@as(u16, 1), ev2.minor);

    const ev3 = EngineVersion.fromString("node16.11").?;
    try std.testing.expectEqual(Engine.node, ev3.engine);
    try std.testing.expectEqual(@as(u16, 16), ev3.major);
    try std.testing.expectEqual(@as(u16, 11), ev3.minor);
}

test "EngineVersion.fromString — 에러 케이스" {
    try std.testing.expectEqual(@as(?EngineVersion, null), EngineVersion.fromString(""));
    try std.testing.expectEqual(@as(?EngineVersion, null), EngineVersion.fromString("80"));
    try std.testing.expectEqual(@as(?EngineVersion, null), EngineVersion.fromString("chrome"));
    try std.testing.expectEqual(@as(?EngineVersion, null), EngineVersion.fromString("unknown80"));
}

test "parseBrowserslistEntry — 표준 출력 형식" {
    const ev1 = parseBrowserslistEntry("chrome 100").?;
    try std.testing.expectEqual(Engine.chrome, ev1.engine);
    try std.testing.expectEqual(@as(u16, 100), ev1.major);

    const ev2 = parseBrowserslistEntry("ios_saf 14.5").?;
    try std.testing.expectEqual(Engine.ios, ev2.engine);
    try std.testing.expectEqual(@as(u16, 14), ev2.major);
    try std.testing.expectEqual(@as(u16, 5), ev2.minor);

    const ev3 = parseBrowserslistEntry("and_chr 100").?;
    try std.testing.expectEqual(Engine.chrome, ev3.engine);
}

test "parseBrowserslistEntry — operator + 공백" {
    const ev1 = parseBrowserslistEntry("chrome >= 87").?;
    try std.testing.expectEqual(Engine.chrome, ev1.engine);
    try std.testing.expectEqual(@as(u16, 87), ev1.major);

    const ev2 = parseBrowserslistEntry("firefox>78").?;
    try std.testing.expectEqual(Engine.firefox, ev2.engine);
    try std.testing.expectEqual(@as(u16, 78), ev2.major);

    // EngineVersion.fromString 호환 (공백/operator 없음)
    const ev3 = parseBrowserslistEntry("chrome80").?;
    try std.testing.expectEqual(Engine.chrome, ev3.engine);
    try std.testing.expectEqual(@as(u16, 80), ev3.major);
}

test "parseBrowserslistEntry — 미매핑/잘못된 syntax 는 null" {
    try std.testing.expectEqual(@as(?EngineVersion, null), parseBrowserslistEntry(""));
    try std.testing.expectEqual(@as(?EngineVersion, null), parseBrowserslistEntry("defaults"));
    try std.testing.expectEqual(@as(?EngineVersion, null), parseBrowserslistEntry("> 0.5%"));
    try std.testing.expectEqual(@as(?EngineVersion, null), parseBrowserslistEntry("samsung 14"));
}

test "parseBrowserslistEntry — opera 는 Chromium alias" {
    // Opera 80 → Chromium 93 (보수적 +13). chrome 엔진으로 매핑.
    const ev1 = parseBrowserslistEntry("opera 80").?;
    try std.testing.expectEqual(Engine.chrome, ev1.engine);
    try std.testing.expectEqual(@as(u16, 93), ev1.major);

    // op_mob 도 같은 매핑.
    const ev2 = parseBrowserslistEntry("op_mob 75").?;
    try std.testing.expectEqual(Engine.chrome, ev2.engine);
    try std.testing.expectEqual(@as(u16, 88), ev2.major);

    // Opera 15 (Blink 시작) → Chromium 28.
    const ev3 = parseBrowserslistEntry("opera 15").?;
    try std.testing.expectEqual(Engine.chrome, ev3.engine);
    try std.testing.expectEqual(@as(u16, 28), ev3.major);

    // Presto (Opera 14 이하) 는 Chrome 매트릭스로 매핑 불가 → null.
    try std.testing.expectEqual(@as(?EngineVersion, null), parseBrowserslistEntry("opera 12"));
}

test "browserslistToUnsupported — 다중 엔진 union" {
    // chrome 91 + firefox 79: 양쪽 다 optional_chaining 지원, 양쪽 다 logical_assignment 지원
    const f1 = browserslistToUnsupported("chrome >= 91, firefox 79").?;
    try std.testing.expect(!f1.optional_chaining);
    try std.testing.expect(!f1.logical_assignment);

    // chrome 87 + firefox 78: firefox 78 < 79 → logical_assignment 미지원 → union 도 미지원
    const f2 = browserslistToUnsupported("chrome 87, firefox 78").?;
    try std.testing.expect(f2.logical_assignment);
    // chrome 87 < 91 → optional_chaining 미지원
    try std.testing.expect(f2.optional_chaining);
}

test "browserslistToUnsupported — stat 쿼리는 null" {
    try std.testing.expectEqual(@as(?UnsupportedFeatures, null), browserslistToUnsupported("defaults"));
    try std.testing.expectEqual(@as(?UnsupportedFeatures, null), browserslistToUnsupported("last 2 versions"));
}

test "regex_modifiers — es2024는 미지원, es2025는 지원 (#4210)" {
    try std.testing.expect(fromESTarget(.es2024).regex_modifiers);
    try std.testing.expect(!fromESTarget(.es2025).regex_modifiers);
    try std.testing.expect(!fromESTarget(.esnext).regex_modifiers);
    // es5 = 모든 feature 미지원에 포함
    try std.testing.expect(fromESTarget(.es5).regex_modifiers);
}

test "regex_modifiers — safari 26 경계 (dup-named 의 17.4 와 다름, #4210)" {
    // Safari 25 < 26 → modifiers 미지원이지만 dup-named(17.4)는 지원
    const s25 = unsupportedFeatures(&.{.{ .engine = .safari, .major = 25 }});
    try std.testing.expect(s25.regex_modifiers);
    try std.testing.expect(!s25.regex_duplicate_named_groups);
    // Safari 26 → 둘 다 지원
    const s26 = unsupportedFeatures(&.{.{ .engine = .safari, .major = 26 }});
    try std.testing.expect(!s26.regex_modifiers);
    // node 22 < 23 → 미지원, node 23 → 지원
    try std.testing.expect(unsupportedFeatures(&.{.{ .engine = .node, .major = 22 }}).regex_modifiers);
    try std.testing.expect(!unsupportedFeatures(&.{.{ .engine = .node, .major = 23 }}).regex_modifiers);
    // hermes: compat table 미등록 → 항상 미지원
    try std.testing.expect(unsupportedFeatures(&.{.{ .engine = .hermes, .major = 0, .minor = 12 }}).regex_modifiers);
}
