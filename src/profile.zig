//! ZTS 프로파일링 인프라.
//!
//! 파이프라인 단계별 (scan / parse / semantic / transform / codegen / ...)
//! 타이밍을 카테고리 토글 방식으로 수집한다. 비활성 카테고리는 `enabled()` 의
//! 분기 한 번만 통과하므로 hot path 영향 최소 (Release 비활성 < 1% overhead 목표).
//!
//! ### 사용법 (코드 삽입)
//! ```zig
//! const profile = @import("profile.zig");
//!
//! fn someFunction() !void {
//!     var scope = profile.begin(.parse);
//!     defer scope.end();
//!
//!     // ... work ...
//! }
//! ```
//!
//! ### 활성화 (진입점)
//! - env: `ZTS_PROFILE=all` / `ZTS_PROFILE=parse,transform`
//! - CLI (PR 2): `--profile=all --profile-level=detailed`
//! - NAPI (PR 2): `BundleOptions.profile = [...]`
//!
//! ### Category 추가
//! `Category` enum 에 이름 추가 → 끝. Parent/child 관계는 이름 prefix 로 (dot notation:
//! `parse.ast_build` = enum `parse_ast_build`, parent 활성 시 자동으로 child 도 활성).
//!
//! ### 설계 근거
//! 자세한 내용은 `docs/design/profile-infrastructure.md`.

const std = @import("std");

// ============================================================================
// Category & Level
// ============================================================================

/// 프로파일링 카테고리. 새 phase 추가 시 여기에 이름 추가.
///
/// **Dot notation**: `parse.ast_build` 는 enum 식별자 `parse_ast_build` 로 저장된다.
/// `fromString` 이 `.` 를 `_` 로 자동 정규화. 표시는 `displayName` 이 역변환.
///
/// **Parent/child**: prefix 매칭으로 활성 전파. `parse` 활성 시 `parse_ast_build`,
/// `parse_<anything>` 전부 자동 활성. 반대로 `parse_ast_build` 만 지정하면 `parse`
/// 는 활성 안 됨 (하위만 수집).
pub const Category = enum {
    // ── Parsing ──
    scan,
    parse,
    parse_ast_build,

    // ── Analysis ──
    semantic,
    resolve,
    graph,
    graph_build,
    graph_worker,
    graph_discover,
    graph_discover_scan_worker,
    graph_discover_apply,
    graph_finalize,

    // ── Linking / Tree-shaking ──
    link,
    link_build_export_map,
    link_resolve_imports,
    link_compute_renames,
    link_compute_mangling,
    link_populate_re_export_aliases,
    link_populate_import_symbols,
    link_populate_namespace_accesses,
    shake,
    metadata,
    metadata_register_ns_rewrites,

    // ── Transform ──
    transform,
    transform_ts_strip,
    transform_jsx,
    transform_class_field,
    transform_decorator,
    transform_pass2,

    // ── Codegen ──
    codegen,
    codegen_walk,
    codegen_sourcemap,

    // ── Top-level emit ──
    emit,
    emit_polyfill,
    emit_refresh,
    emit_output,
    emit_metafile,
    emit_css,
    // ── emit_output 내부 (emitter.emitWithTreeShaking 분해) ──
    emit_prelude,
    emit_module_pass,
    emit_concat,
    emit_sourcemap_finalize,

    // ── HMR ──
    hmr,
    hmr_detect,
    hmr_delta,

    // ── Cache ──
    cache,

    /// Category 이름으로 enum 조회 (대소문자 무시 + dot→underscore 정규화 + 공백 제거).
    /// 예: `"parse.ast_build"`, `"Parse.AST_Build"`, `" parse "` 모두 매칭.
    pub fn fromString(s: []const u8) ?Category {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return null;

        var buf: [64]u8 = undefined;
        if (trimmed.len > buf.len) return null;
        for (trimmed, 0..) |c, i| {
            buf[i] = if (c == '.') '_' else std.ascii.toLower(c);
        }
        const normalized = buf[0..trimmed.len];

        inline for (@typeInfo(Category).@"enum".fields) |f| {
            if (std.mem.eql(u8, normalized, f.name)) {
                return @field(Category, f.name);
            }
        }
        return null;
    }

    /// 표시용 이름 — underscore 를 dot 으로 변환해 `parse.ast_build` 처럼.
    pub fn displayName(cat: Category) []const u8 {
        return switch (cat) {
            inline else => |c| comptime blk: {
                const name = @tagName(c);
                var buf: [name.len]u8 = undefined;
                for (name, 0..) |ch, i| {
                    buf[i] = if (ch == '_') '.' else ch;
                }
                const out = buf;
                break :blk &out;
            },
        };
    }
};

/// 프로파일링 상세도.
pub const Level = enum {
    /// Phase 총합만 (default).
    summary,
    /// Sub-phase (e.g. `transform.jsx`) 까지 표시.
    detailed,
    /// 모듈별 breakdown.
    per_module,
    /// Transformer visit 함수 수준 (가장 세밀).
    per_pass,

    pub fn fromString(s: []const u8) ?Level {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(trimmed, "summary")) return .summary;
        if (std.ascii.eqlIgnoreCase(trimmed, "detailed")) return .detailed;
        if (std.ascii.eqlIgnoreCase(trimmed, "per-module") or
            std.ascii.eqlIgnoreCase(trimmed, "per_module")) return .per_module;
        if (std.ascii.eqlIgnoreCase(trimmed, "per-pass") or
            std.ascii.eqlIgnoreCase(trimmed, "per_pass")) return .per_pass;
        return null;
    }
};

/// 리포트 출력 포맷.
pub const Format = enum {
    table,
    tree,
    json,
    csv,

    pub fn fromString(s: []const u8) ?Format {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(trimmed, "table")) return .table;
        if (std.ascii.eqlIgnoreCase(trimmed, "tree")) return .tree;
        if (std.ascii.eqlIgnoreCase(trimmed, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(trimmed, "csv")) return .csv;
        return null;
    }
};

// ============================================================================
// State (process-global)
// ============================================================================

/// Category 수. u64 bitmask 안에 맞아야 함 (64 미만).
pub const num_categories = @typeInfo(Category).@"enum".fields.len;

comptime {
    if (num_categories > 64) {
        @compileError("Category count exceeded u64 bitmask. Switch to u128 or ArrayBitSet.");
    }
}

/// 활성 카테고리 비트마스크. hot path 에서는 `enabled()` 의 single AND 로 검사.
/// 프로세스 전역 — 초기화 후 read-only 로 다뤄 thread-safe. 수집 data array 는 현재
/// single-thread 가정 (PR 7 에서 per-thread merge 로 확장 예정).
var enabled_mask: u64 = 0;

/// 현재 level. Reporter 가 어떤 수준까지 노출할지 결정.
var current_level: Level = .summary;

/// 각 category 별 누적 시간 (ns).
var totals_ns: [num_categories]u64 = [_]u64{0} ** num_categories;

/// 각 category 별 호출 횟수.
var counts: [num_categories]u32 = [_]u32{0} ** num_categories;

// ============================================================================
// Activation API (CLI / NAPI / env 공용)
// ============================================================================

/// 활성 여부 조회 (inline + single AND — hot path 용).
pub inline fn enabled(cat: Category) bool {
    const bit = @as(u64, 1) << @intFromEnum(cat);
    return (enabled_mask & bit) != 0;
}

/// 하나라도 활성화된 category 가 있는지. HMR rebuild 에서 counters reset 을 조건부로
/// 수행할 때 사용 (비활성 상태의 불필요한 memset 회피).
pub inline fn anyEnabled() bool {
    return enabled_mask != 0;
}

/// Level 조회.
pub inline fn level() Level {
    return current_level;
}

/// Level 설정 (CLI / NAPI entry 에서 호출).
pub fn setLevel(lv: Level) void {
    current_level = lv;
}

/// 쉼표 구분 카테고리 목록을 mask 에 합집합으로 추가. `all` / `none` 키워드 지원.
/// Parent category 지정 시 child (prefix 매칭) 도 자동 활성.
pub fn addFromCsv(csv: []const u8) void {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(name, "all")) {
            enabled_mask = comptime (@as(u64, 1) << num_categories) - 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "none")) {
            enabled_mask = 0;
            continue;
        }
        if (Category.fromString(name)) |c| {
            enableCategoryAndChildren(c);
        }
    }
}

/// 문자열 배열을 mask 에 합집합으로 추가 (NAPI option 용).
pub fn addCategories(names: []const []const u8) void {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, "all")) {
            enabled_mask = comptime (@as(u64, 1) << num_categories) - 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "none")) {
            enabled_mask = 0;
            continue;
        }
        if (Category.fromString(name)) |c| {
            enableCategoryAndChildren(c);
        }
    }
}

/// `ZTS_PROFILE` / `ZTS_PROFILE_LEVEL` env 를 읽어 활성화. 미설정 시 no-op.
/// CLI main / NAPI entry 양쪽에서 호출 — 중복 호출 해도 idempotent.
pub fn initFromEnv(allocator: std.mem.Allocator) void {
    if (std.process.getEnvVarOwned(allocator, "ZTS_PROFILE")) |v| {
        defer allocator.free(v);
        addFromCsv(v);
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "ZTS_PROFILE_LEVEL")) |v| {
        defer allocator.free(v);
        if (Level.fromString(v)) |lv| setLevel(lv);
    } else |_| {}
}

/// totals_ns / counts 를 0 으로 초기화.
///
/// Debug + Linux x86_64 에서 `@memset` 이 `mov m64 m64` 로 encode 되어 Zig 0.15.2
/// 컴파일러 버그(InvalidInstruction) 를 유발 — comptime array literal 대입으로 회피.
/// Zig upgrade 로 버그 사라지면 이 함수 제거하고 `@memset` 두 줄 복원.
fn zeroCounters() void {
    totals_ns = [_]u64{0} ** num_categories;
    counts = [_]u32{0} ** num_categories;
}

/// 테스트 / 재초기화용. 전체 상태 초기화 (mask + level + counters 모두).
pub fn resetForTest() void {
    enabled_mask = 0;
    current_level = .summary;
    zeroCounters();
}

/// counters 만 reset (mask 와 level 은 유지).
/// HMR rebuild 시작 전에 호출 — 이전 rebuild 의 누적치가 이월되지 않도록.
pub fn resetCounters() void {
    zeroCounters();
}

/// 하나의 category 를 활성화하고, prefix 로 시작하는 child category 도 모두 활성화.
/// 예: `enableCategoryAndChildren(.parse)` → `.parse_ast_build` 도 같이 활성.
fn enableCategoryAndChildren(parent: Category) void {
    const parent_name = @tagName(parent);
    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const child_name = f.name;
        const is_self = std.mem.eql(u8, child_name, parent_name);
        const is_child = child_name.len > parent_name.len and
            std.mem.startsWith(u8, child_name, parent_name) and
            child_name[parent_name.len] == '_';
        if (is_self or is_child) {
            const child = @field(Category, child_name);
            enabled_mask |= @as(u64, 1) << @intFromEnum(child);
        }
    }
}

// ============================================================================
// Scope — RAII timer (hot path API)
// ============================================================================

/// 타이밍 스코프. `begin()` 으로 시작하고 `end()` 로 종료. `defer scope.end();` 관용구.
///
/// 비활성 category 면 `timer == null` — `end()` 도 no-op (분기 한 번).
pub const Scope = struct {
    timer: ?std.time.Timer = null,
    category: Category = .scan, // 비활성 시 사용 안 됨

    pub fn end(self: *Scope) void {
        if (self.timer) |*t| {
            const elapsed_ns = t.read();
            recordTiming(self.category, elapsed_ns);
        }
    }
};

/// 비활성 category 면 no-op scope 반환 (Timer 생성 없음 → zero overhead).
/// 활성 category 면 Timer 시작 + category 기록.
pub inline fn begin(cat: Category) Scope {
    if (!enabled(cat)) return .{};
    return .{
        .timer = std.time.Timer.start() catch null,
        .category = cat,
    };
}

fn recordTiming(cat: Category, ns: u64) void {
    const idx = @intFromEnum(cat);
    totals_ns[idx] += ns;
    counts[idx] += 1;
}

/// 수집된 원시 데이터 조회 (테스트 + 외부 리포터용).
pub fn totalNs(cat: Category) u64 {
    return totals_ns[@intFromEnum(cat)];
}

pub fn count(cat: Category) u32 {
    return counts[@intFromEnum(cat)];
}

// ============================================================================
// Reporting
// ============================================================================

/// 지정한 format 으로 리포트 출력.
pub fn report(writer: anytype, format: Format) !void {
    switch (format) {
        .table => try reportTable(writer),
        .tree => try reportTree(writer),
        .json => try reportJson(writer),
        .csv => try reportCsv(writer),
    }
}

fn totalAllNs() u64 {
    var sum: u64 = 0;
    for (totals_ns) |ns| sum += ns;
    return sum;
}

fn isTopLevel(cat: Category) bool {
    // name 에 `_` 없으면 top-level.
    const name = @tagName(cat);
    return std.mem.indexOfScalar(u8, name, '_') == null;
}

fn isChildOf(cat: Category, parent: Category) bool {
    const child_name = @tagName(cat);
    const parent_name = @tagName(parent);
    return child_name.len > parent_name.len + 1 and
        std.mem.startsWith(u8, child_name, parent_name) and
        child_name[parent_name.len] == '_';
}

fn reportTable(writer: anytype) !void {
    try writer.writeAll("=== ZTS Profile ===\n");
    try writer.writeAll("Phase                Total       %      Count\n");
    try writer.writeAll("--------------------|-----------|-------|------\n");

    const total = totalAllNs();
    if (total == 0) {
        try writer.writeAll("(no samples recorded)\n");
        return;
    }

    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const cat = @field(Category, f.name);
        const idx = @intFromEnum(cat);
        const is_sub = !isTopLevel(cat);
        const skip = counts[idx] == 0 or (current_level == .summary and is_sub);
        if (!skip) {
            const ns = totals_ns[idx];
            const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
            const pct = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total)) * 100.0;
            const name = Category.displayName(cat);

            try writer.print("{s: <20} {d: >7.2}ms  {d: >4.1}%  {d: >5}\n", .{
                name, ms, pct, counts[idx],
            });
        }
    }

    try writer.writeAll("--------------------|-----------|-------|------\n");
    const total_ms = @as(f64, @floatFromInt(total)) / 1_000_000.0;
    try writer.print("{s: <20} {d: >7.2}ms  100.0%\n", .{ "total", total_ms });
}

fn reportTree(writer: anytype) !void {
    // Nested inline for 는 N² comptime branches 를 유발하므로 quota 상향.
    @setEvalBranchQuota(num_categories * num_categories * 16);

    try writer.writeAll("=== ZTS Profile (detailed) ===\n");

    const total = totalAllNs();
    if (total == 0) {
        try writer.writeAll("(no samples recorded)\n");
        return;
    }

    const total_ms = @as(f64, @floatFromInt(total)) / 1_000_000.0;
    try writer.print("total: {d:.2}ms\n", .{total_ms});

    // Top-level categories.
    inline for (@typeInfo(Category).@"enum".fields) |f_top| {
        const cat = @field(Category, f_top.name);
        const idx = @intFromEnum(cat);
        if (counts[idx] > 0 and isTopLevel(cat)) {
            const ns = totals_ns[idx];
            const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
            const pct = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total)) * 100.0;
            try writer.print("├─ {s: <16} {d: >7.2}ms  ({d:.1}%)\n", .{ Category.displayName(cat), ms, pct });

            if (current_level != .summary) {
                // Sub-phases.
                inline for (@typeInfo(Category).@"enum".fields) |f_sub| {
                    const sub_cat = @field(Category, f_sub.name);
                    const sub_idx = @intFromEnum(sub_cat);
                    if (counts[sub_idx] > 0 and isChildOf(sub_cat, cat)) {
                        const sub_ns = totals_ns[sub_idx];
                        const sub_ms = @as(f64, @floatFromInt(sub_ns)) / 1_000_000.0;
                        const sub_pct_of_parent = @as(f64, @floatFromInt(sub_ns)) / @as(f64, @floatFromInt(ns)) * 100.0;
                        try writer.print("│  └─ {s: <13} {d: >7.2}ms  ({d:.1}% of {s})\n", .{
                            Category.displayName(sub_cat),
                            sub_ms,
                            sub_pct_of_parent,
                            Category.displayName(cat),
                        });
                    }
                }
            }
        }
    }
}

fn reportJson(writer: anytype) !void {
    const total = totalAllNs();
    const total_ms = @as(f64, @floatFromInt(total)) / 1_000_000.0;

    try writer.writeAll("{\n");
    try writer.print("  \"profile_version\": 1,\n", .{});
    try writer.print("  \"total_ms\": {d:.3},\n", .{total_ms});
    try writer.print("  \"level\": \"{s}\",\n", .{@tagName(current_level)});
    try writer.writeAll("  \"phases\": {\n");

    var first = true;
    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const cat = @field(Category, f.name);
        const idx = @intFromEnum(cat);
        const is_sub = !isTopLevel(cat);
        const skip = counts[idx] == 0 or (current_level == .summary and is_sub);
        if (!skip) {
            const ns = totals_ns[idx];
            const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
            const pct = if (total > 0)
                @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total)) * 100.0
            else
                0.0;

            if (!first) try writer.writeAll(",\n");
            first = false;
            try writer.print(
                "    \"{s}\": {{ \"total_ms\": {d:.3}, \"count\": {d}, \"pct\": {d:.2} }}",
                .{ Category.displayName(cat), ms, counts[idx], pct },
            );
        }
    }
    try writer.writeAll("\n  }\n}\n");
}

fn reportCsv(writer: anytype) !void {
    try writer.writeAll("phase,total_ms,count,pct\n");
    const total = totalAllNs();

    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const cat = @field(Category, f.name);
        const idx = @intFromEnum(cat);
        const is_sub = !isTopLevel(cat);
        const skip = counts[idx] == 0 or (current_level == .summary and is_sub);
        if (!skip) {
            const ns = totals_ns[idx];
            const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
            const pct = if (total > 0)
                @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total)) * 100.0
            else
                0.0;

            try writer.print("{s},{d:.3},{d},{d:.2}\n", .{ Category.displayName(cat), ms, counts[idx], pct });
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Category.fromString: 기본 매칭" {
    try testing.expect(Category.fromString("parse") == .parse);
    try testing.expect(Category.fromString("PARSE") == .parse);
    try testing.expect(Category.fromString("  parse  ") == .parse);
    try testing.expect(Category.fromString("") == null);
    try testing.expect(Category.fromString("nonexistent") == null);
}

test "Category.fromString: dot notation 정규화" {
    try testing.expect(Category.fromString("parse.ast_build") == .parse_ast_build);
    try testing.expect(Category.fromString("transform.ts_strip") == .transform_ts_strip);
    try testing.expect(Category.fromString("Transform.JSX") == .transform_jsx);
    try testing.expect(Category.fromString("hmr.detect") == .hmr_detect);
}

test "Category.displayName: underscore → dot 역변환" {
    try testing.expectEqualStrings("parse", Category.displayName(.parse));
    try testing.expectEqualStrings("parse.ast.build", Category.displayName(.parse_ast_build));
    try testing.expectEqualStrings("transform.ts.strip", Category.displayName(.transform_ts_strip));
    try testing.expectEqualStrings("hmr.detect", Category.displayName(.hmr_detect));
}

test "Level.fromString" {
    try testing.expect(Level.fromString("summary") == .summary);
    try testing.expect(Level.fromString("detailed") == .detailed);
    try testing.expect(Level.fromString("per-module") == .per_module);
    try testing.expect(Level.fromString("per_module") == .per_module);
    try testing.expect(Level.fromString("per-pass") == .per_pass);
    try testing.expect(Level.fromString("unknown") == null);
}

test "Format.fromString" {
    try testing.expect(Format.fromString("table") == .table);
    try testing.expect(Format.fromString("JSON") == .json);
    try testing.expect(Format.fromString("csv") == .csv);
    try testing.expect(Format.fromString("tree") == .tree);
    try testing.expect(Format.fromString("xml") == null);
}

test "addFromCsv: 개별 category 활성화" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse, transform");
    try testing.expect(enabled(.parse));
    try testing.expect(enabled(.transform));
    try testing.expect(!enabled(.codegen));
}

test "addFromCsv: all 키워드" {
    resetForTest();
    defer resetForTest();

    addFromCsv("all");
    try testing.expect(enabled(.parse));
    try testing.expect(enabled(.transform));
    try testing.expect(enabled(.codegen));
    try testing.expect(enabled(.hmr_detect));
}

test "addFromCsv: none 키워드 초기화" {
    resetForTest();
    defer resetForTest();

    addFromCsv("all");
    addFromCsv("none");
    try testing.expect(!enabled(.parse));
}

test "addFromCsv: 빈 항목 및 공백 무시" {
    resetForTest();
    defer resetForTest();

    addFromCsv(" , , parse , ");
    try testing.expect(enabled(.parse));
}

test "addFromCsv: parent 활성화 시 child 자동 활성" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    try testing.expect(enabled(.parse));
    try testing.expect(enabled(.parse_ast_build));
}

test "addFromCsv: child 만 지정하면 parent 는 비활성" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse.ast_build");
    try testing.expect(!enabled(.parse));
    try testing.expect(enabled(.parse_ast_build));
}

test "addFromCsv: transform parent → 모든 sub-phase 활성" {
    resetForTest();
    defer resetForTest();

    addFromCsv("transform");
    try testing.expect(enabled(.transform));
    try testing.expect(enabled(.transform_ts_strip));
    try testing.expect(enabled(.transform_jsx));
    try testing.expect(enabled(.transform_class_field));
    try testing.expect(enabled(.transform_decorator));
    try testing.expect(enabled(.transform_pass2));
}

test "addFromCsv: 알 수 없는 이름은 무시" {
    resetForTest();
    defer resetForTest();

    addFromCsv("bogus_category, parse");
    try testing.expect(enabled(.parse));
}

test "addCategories: slice 기반 API" {
    resetForTest();
    defer resetForTest();

    const cats = [_][]const u8{ "parse", "transform.jsx" };
    addCategories(&cats);
    try testing.expect(enabled(.parse));
    try testing.expect(enabled(.transform_jsx));
    try testing.expect(!enabled(.transform));
}

test "Scope: 비활성 category 는 zero-cost" {
    resetForTest();
    defer resetForTest();

    // 비활성 상태 — begin 은 Timer 없이 null 반환.
    var scope = begin(.parse);
    try testing.expect(scope.timer == null);
    scope.end();
    try testing.expectEqual(@as(u64, 0), totalNs(.parse));
    try testing.expectEqual(@as(u32, 0), count(.parse));
}

test "Scope: 활성 category 는 시간 누적" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");

    var s1 = begin(.parse);
    std.Thread.sleep(1_000_000); // 1ms
    s1.end();

    var s2 = begin(.parse);
    std.Thread.sleep(1_000_000); // 1ms
    s2.end();

    const total = totalNs(.parse);
    // 실제 시간은 OS 스케줄링에 따라 다름. 최소 보장만 검증.
    try testing.expect(total >= 2_000_000);
    try testing.expectEqual(@as(u32, 2), count(.parse));
}

test "Scope: nested 호출 누적" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    addFromCsv("parse.ast_build");

    var outer = begin(.parse);
    {
        var inner = begin(.parse_ast_build);
        std.Thread.sleep(1_000_000);
        inner.end();
    }
    outer.end();

    try testing.expect(totalNs(.parse) > 0);
    try testing.expect(totalNs(.parse_ast_build) > 0);
    // Outer 가 inner 를 포함하는지 대략 검증 — parent 가 child 보다 크거나 같음.
    try testing.expect(totalNs(.parse) >= totalNs(.parse_ast_build));
}

test "setLevel / level" {
    resetForTest();
    defer resetForTest();

    try testing.expect(level() == .summary);
    setLevel(.detailed);
    try testing.expect(level() == .detailed);
}

test "report: table format 기본 구조" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    var s = begin(.parse);
    std.Thread.sleep(500_000); // 0.5ms
    s.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .table);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "=== ZTS Profile ===") != null);
    try testing.expect(std.mem.indexOf(u8, output, "parse") != null);
    try testing.expect(std.mem.indexOf(u8, output, "total") != null);
}

test "report: json format 기본 구조" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    var s = begin(.parse);
    std.Thread.sleep(500_000);
    s.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .json);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "\"profile_version\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"total_ms\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"phases\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"parse\"") != null);
}

test "report: csv format 기본 구조" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    var s = begin(.parse);
    std.Thread.sleep(500_000);
    s.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .csv);
    const output = fbs.getWritten();

    try testing.expect(std.mem.startsWith(u8, output, "phase,total_ms,count,pct\n"));
    try testing.expect(std.mem.indexOf(u8, output, "parse,") != null);
}

test "report: 데이터 없을 때 empty message" {
    resetForTest();
    defer resetForTest();

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .table);
    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "no samples") != null);
}

test "report: summary level 은 sub-phase 숨김" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse"); // parse + parse_ast_build 자동 활성
    setLevel(.summary);

    var outer = begin(.parse);
    var inner = begin(.parse_ast_build);
    std.Thread.sleep(100_000);
    inner.end();
    outer.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .table);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "parse.ast.build") == null);
    try testing.expect(std.mem.indexOf(u8, output, "parse ") != null);
}

test "report: detailed level 은 sub-phase 노출" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    setLevel(.detailed);

    var outer = begin(.parse);
    var inner = begin(.parse_ast_build);
    std.Thread.sleep(100_000);
    inner.end();
    outer.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .tree);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "parse.ast.build") != null);
}

test "isTopLevel / isChildOf 헬퍼" {
    try testing.expect(isTopLevel(.parse));
    try testing.expect(isTopLevel(.transform));
    try testing.expect(!isTopLevel(.parse_ast_build));
    try testing.expect(!isTopLevel(.transform_jsx));

    try testing.expect(isChildOf(.parse_ast_build, .parse));
    try testing.expect(isChildOf(.transform_jsx, .transform));
    try testing.expect(!isChildOf(.parse, .transform));
    try testing.expect(!isChildOf(.parse, .parse_ast_build));
}

test "resetForTest 초기화" {
    addFromCsv("all");
    setLevel(.detailed);
    var s = begin(.parse);
    std.Thread.sleep(100_000);
    s.end();

    resetForTest();
    try testing.expect(!enabled(.parse));
    try testing.expect(level() == .summary);
    try testing.expectEqual(@as(u64, 0), totalNs(.parse));
    try testing.expectEqual(@as(u32, 0), count(.parse));
}
