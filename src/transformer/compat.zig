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
    // ES2023
    hashbang,
    // ES2025
    using,

    /// 이 feature가 도입된 ES 버전.
    pub fn esVersion(self: Feature) ESTarget {
        return switch (self) {
            .arrow, .class, .template_literal, .destructuring, .for_of, .spread, .object_extensions, .default_params, .block_scoping, .generator, .new_target => .es2015,
            .exponentiation => .es2016,
            .async_await => .es2017,
            .object_spread => .es2018,
            .optional_catch_binding => .es2019,
            .nullish_coalescing, .optional_chaining => .es2020,
            .logical_assignment => .es2021,
            .class_static_block, .class_private_method, .class_private_field => .es2022,
            .hashbang => .es2023,
            .using => .es2025,
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
    // ES2023
    hashbang: bool = false,
    // ES2025
    using: bool = false,

    _: u9 = 0,

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
};

// ─── 엔진 버전 ───

pub const EngineVersion = struct {
    engine: Engine,
    major: u16,
    minor: u16 = 0,

    /// "chrome80", "safari14.1", "node16" → EngineVersion.
    pub fn fromString(s: []const u8) ?EngineVersion {
        // 숫자 시작 위치 찾기
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
        const ver_str = s[split..];
        var major: u16 = 0;
        var minor: u16 = 0;
        if (std.mem.indexOf(u8, ver_str, ".")) |dot| {
            major = std.fmt.parseInt(u16, ver_str[0..dot], 10) catch return null;
            minor = std.fmt.parseInt(u16, ver_str[dot + 1 ..], 10) catch return null;
        } else {
            major = std.fmt.parseInt(u16, ver_str, 10) catch return null;
        }
        return .{ .engine = engine, .major = major, .minor = minor };
    }
};

/// 버전 비교. a < b 이면 true.
fn versionLessThan(a_major: u16, a_minor: u16, b_major: u16, b_minor: u16) bool {
    if (a_major != b_major) return a_major < b_major;
    return a_minor < b_minor;
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
    // hermes: 미지원

    // ── ES2015: class ──
    .{ .feature = .class, .engine = .chrome, .major = 49 },
    .{ .feature = .class, .engine = .firefox, .major = 45 },
    .{ .feature = .class, .engine = .safari, .major = 10 },
    .{ .feature = .class, .engine = .edge, .major = 13 },
    .{ .feature = .class, .engine = .node, .major = 6 },
    .{ .feature = .class, .engine = .deno, .major = 1 },
    .{ .feature = .class, .engine = .ios, .major = 10 },

    // ── ES2015: template_literal ──
    // esbuild는 tagged template caching 기준으로 더 높은 버전 요구
    .{ .feature = .template_literal, .engine = .chrome, .major = 62 },
    .{ .feature = .template_literal, .engine = .firefox, .major = 53 },
    .{ .feature = .template_literal, .engine = .safari, .major = 13 },
    .{ .feature = .template_literal, .engine = .edge, .major = 79 },
    .{ .feature = .template_literal, .engine = .node, .major = 8, .minor = 10 },
    .{ .feature = .template_literal, .engine = .deno, .major = 1 },
    .{ .feature = .template_literal, .engine = .ios, .major = 13 },

    // ── ES2015: destructuring ──
    .{ .feature = .destructuring, .engine = .chrome, .major = 51 },
    .{ .feature = .destructuring, .engine = .firefox, .major = 53 },
    .{ .feature = .destructuring, .engine = .safari, .major = 10 },
    .{ .feature = .destructuring, .engine = .edge, .major = 18 },
    .{ .feature = .destructuring, .engine = .node, .major = 6, .minor = 5 },
    .{ .feature = .destructuring, .engine = .deno, .major = 1 },
    .{ .feature = .destructuring, .engine = .ios, .major = 10 },

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

    // ── ES2015: block_scoping ──
    .{ .feature = .block_scoping, .engine = .chrome, .major = 49 },
    .{ .feature = .block_scoping, .engine = .firefox, .major = 51 },
    .{ .feature = .block_scoping, .engine = .safari, .major = 11 },
    .{ .feature = .block_scoping, .engine = .edge, .major = 14 },
    .{ .feature = .block_scoping, .engine = .node, .major = 6 },
    .{ .feature = .block_scoping, .engine = .deno, .major = 1 },
    .{ .feature = .block_scoping, .engine = .ios, .major = 11 },

    // ── ES2015: generator ──
    .{ .feature = .generator, .engine = .chrome, .major = 50 },
    .{ .feature = .generator, .engine = .firefox, .major = 53 },
    .{ .feature = .generator, .engine = .safari, .major = 10 },
    .{ .feature = .generator, .engine = .edge, .major = 13 },
    .{ .feature = .generator, .engine = .node, .major = 6 },
    .{ .feature = .generator, .engine = .deno, .major = 1 },
    .{ .feature = .generator, .engine = .ios, .major = 10 },

    // ── ES2015: new.target ──
    .{ .feature = .new_target, .engine = .chrome, .major = 46 },
    .{ .feature = .new_target, .engine = .firefox, .major = 41 },
    .{ .feature = .new_target, .engine = .safari, .major = 10 },
    .{ .feature = .new_target, .engine = .edge, .major = 13 },
    .{ .feature = .new_target, .engine = .node, .major = 5 },
    .{ .feature = .new_target, .engine = .deno, .major = 1 },
    .{ .feature = .new_target, .engine = .ios, .major = 10 },

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
    // edge, ios, hermes: 미지원 → compat_table에 없음 → 항상 다운레벨링
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

/// Hermes (React Native) 전용 Unsupported matrix.
///
/// Hermes 0.12+ 기준:
/// - class expression 거부 → class 전체를 function IIFE로 다운레벨 (class=true 하나로 private/static 모두 함께 처리됨)
/// - using 선언 미지원
/// - async/await, let/const, ?., ??, arrow, destructuring, generator 등은 native 지원 → 보존
/// - 특히 async는 #1267 state machine 버그 때문에 **반드시 보존해야 함**
///
/// 관련 이슈: #1267, #1275, #1277, #1278, #1283
pub fn fromHermesPreset() UnsupportedFeatures {
    return .{
        .class = true,
        .using = true,
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

test "unsupportedFeatures — hermes는 많은 feature 미지원" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .hermes, .major = 0, .minor = 12 },
    });
    // hermes 0.12: arrow 미지원 (compat table에 없음)
    try std.testing.expect(f.arrow);
    try std.testing.expect(f.class);
    try std.testing.expect(f.async_await);
    // hermes 0.12: for_of(0.7) 지원
    try std.testing.expect(!f.for_of);
    // hermes 0.12: optional_chaining(0.12) 지원
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
        .{ .engine = .safari, .major = 18, .minor = 2 },
    });
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(f)));
}

test "unsupportedFeatures — hermes 0.7 지원/미지원 구분" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .hermes, .major = 0, .minor = 7 },
    });
    // hermes 0.7에서 지원하는 것들
    try std.testing.expect(!f.for_of);
    try std.testing.expect(!f.spread);
    try std.testing.expect(!f.object_extensions);
    try std.testing.expect(!f.exponentiation);
    try std.testing.expect(!f.object_spread);
    try std.testing.expect(!f.nullish_coalescing);
    try std.testing.expect(!f.logical_assignment);
    // hermes 0.7에서 미지원 (compat table에 없음)
    try std.testing.expect(f.arrow);
    try std.testing.expect(f.class);
    try std.testing.expect(f.template_literal);
    try std.testing.expect(f.async_await);
    try std.testing.expect(f.class_static_block);
    try std.testing.expect(f.class_private_method);
    // hermes 0.7 < 0.12 → optional_chaining 미지원
    try std.testing.expect(f.optional_chaining);
}

test "unsupportedFeatures — 단일 엔진 + hermes 교집합은 hermes가 지배" {
    const f = unsupportedFeatures(&.{
        .{ .engine = .chrome, .major = 100 },
        .{ .engine = .hermes, .major = 0, .minor = 12 },
    });
    // chrome100은 모두 지원하지만 hermes가 arrow 미지원 → 결과도 미지원
    try std.testing.expect(f.arrow);
    try std.testing.expect(f.class);
    // hermes 0.12는 optional_chaining 지원
    try std.testing.expect(!f.optional_chaining);
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
