//! ZTS 디버그 로그 인프라.
//!
//! 카테고리별 토글 가능한 진단 로그. `ZTS_DEBUG` env 또는 NAPI option
//! (`BundleOptions.debug`) 으로 활성화. 비활성 카테고리는 `enabled()` 의 분기
//! 한 번만 통과하므로 hot path 영향 최소.
//!
//! ### 사용법
//! ```zig
//! const debug_log = @import("debug_log.zig");
//!
//! debug_log.print(.compiled_cache, "hits={d} misses={d}\n", .{ hits, misses });
//! // 또는 format 계산이 비싸면:
//! if (debug_log.enabled(.compiled_cache)) {
//!     const expensive = try computeSummary();
//!     defer allocator.free(expensive);
//!     debug_log.print(.compiled_cache, "{s}\n", .{expensive});
//! }
//! ```
//!
//! ### 카테고리 추가
//! `Category` enum 에 이름 추가 → 끝. wildcard 는 지원하지 않음 (쉼표 구분 명시만).
//!
//! ### env 형식
//! `ZTS_DEBUG=compiled_cache,hmr` — 쉼표 구분. 공백/대소문자 무시.

const std = @import("std");

/// 로그 카테고리. 추가 시 이 enum 에만 이름 넣으면 됨.
pub const Category = enum {
    compiled_cache,

    /// 카테고리 이름으로 enum 조회 (공백 제거 + 대소문자 무시).
    pub fn fromString(s: []const u8) ?Category {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return null;
        inline for (@typeInfo(Category).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(trimmed, f.name)) {
                return @field(Category, f.name);
            }
        }
        return null;
    }
};

/// 활성 카테고리 bitmask. enum 값을 비트 인덱스로 사용.
/// 프로세스 전역 — 초기화 후에는 read-only 로 다뤄 thread-safe.
var enabled_mask: u64 = 0;

/// 활성 여부 조회. hot path 에서 호출 가능 (single u64 AND).
pub fn enabled(cat: Category) bool {
    const bit = @as(u64, 1) << @intFromEnum(cat);
    return (enabled_mask & bit) != 0;
}

/// 쉼표 구분 카테고리 이름 목록을 mask 에 합집합으로 추가. 기존 활성은 유지.
/// env / NAPI / CLI 어느 진입점에서 호출해도 동일 동작.
pub fn addFromCsv(csv: []const u8) void {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |name| {
        if (Category.fromString(name)) |c| {
            enabled_mask |= @as(u64, 1) << @intFromEnum(c);
        }
    }
}

/// 문자열 리스트를 mask 에 합집합으로 추가 (NAPI option 용).
pub fn addCategories(names: []const []const u8) void {
    for (names) |name| {
        if (Category.fromString(name)) |c| {
            enabled_mask |= @as(u64, 1) << @intFromEnum(c);
        }
    }
}

/// 프로세스 시작 시 1회 호출. `ZTS_DEBUG` env 를 읽어 mask 초기화.
/// CLI main / NAPI entry 양쪽에서 호출 — 중복 호출 해도 idempotent.
pub fn initFromEnv(allocator: std.mem.Allocator) void {
    const value = std.process.getEnvVarOwned(allocator, "ZTS_DEBUG") catch return;
    defer allocator.free(value);
    addFromCsv(value);
}

/// 테스트/재설정용. 전체 비활성.
pub fn resetForTest() void {
    enabled_mask = 0;
}

/// 카테고리 prefix 를 붙여 stderr 로 출력. 비활성이면 no-op.
/// 호출 예: `print(.compiled_cache, "hits={d}\n", .{count})`
pub fn print(cat: Category, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(cat)) return;
    std.debug.print("[" ++ @tagName(cat) ++ "] " ++ fmt, args);
}

// ===========================================================================
// Tests
// ===========================================================================

test "Category.fromString 매칭" {
    try std.testing.expect(Category.fromString("compiled_cache") == .compiled_cache);
    try std.testing.expect(Category.fromString("COMPILED_CACHE") == .compiled_cache);
    try std.testing.expect(Category.fromString("  compiled_cache  ") == .compiled_cache);
    try std.testing.expect(Category.fromString("nonexistent") == null);
    try std.testing.expect(Category.fromString("") == null);
}

test "addFromCsv: 여러 카테고리 + 알 수 없는 이름은 무시" {
    resetForTest();
    defer resetForTest();

    addFromCsv("compiled_cache, unknown ,compiled_cache");
    try std.testing.expect(enabled(.compiled_cache));
}

test "addFromCsv: 공백만 있는 항목은 무시" {
    resetForTest();
    defer resetForTest();

    addFromCsv(" , ,");
    try std.testing.expect(!enabled(.compiled_cache));
}

test "enabled: 기본값은 false" {
    resetForTest();
    defer resetForTest();

    try std.testing.expect(!enabled(.compiled_cache));
}
