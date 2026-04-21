//! ZTS 벤치마크 인프라.
//!
//! 특정 phase 를 N 회 반복 실행하며 `profile` 모듈이 수집한 수치로부터 통계
//! (mean / median / p95 / p99 / stddev / min / max) 를 계산한다. baseline
//! save/compare 로 최적화 전후 비교 가능.
//!
//! 사용자 진입점:
//! - CLI: `zts bench --phase=parse ./App.tsx` (PR 5 / main.zig)
//! - NAPI: `benchmark({ phases: ["parse"], iterations: 100, ... })` (PR 5 / napi_entry.zig)
//!
//! ### Flow
//! ```zig
//! const bench = @import("bench.zig");
//! const stats = bench.PhaseStats.fromSamples(allocator, samples_ns);
//! try bench.writeBaseline(writer, &.{ .{ "parse", stats } });
//! const baseline = try bench.readBaseline(allocator, json_text);
//! const cmp = bench.compare(baseline, stats);
//! ```

const std = @import("std");
const profile = @import("profile.zig");

/// Phase 하나의 통계. 모든 값은 나노초(ns) 단위 원본 + ms 변환 게터.
pub const PhaseStats = struct {
    samples: usize,
    mean_ns: f64,
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    min_ns: u64,
    max_ns: u64,
    stddev_ns: f64,

    pub fn meanMs(self: PhaseStats) f64 {
        return self.mean_ns / 1_000_000.0;
    }
    pub fn medianMs(self: PhaseStats) f64 {
        return @as(f64, @floatFromInt(self.median_ns)) / 1_000_000.0;
    }
    pub fn p95Ms(self: PhaseStats) f64 {
        return @as(f64, @floatFromInt(self.p95_ns)) / 1_000_000.0;
    }
    pub fn p99Ms(self: PhaseStats) f64 {
        return @as(f64, @floatFromInt(self.p99_ns)) / 1_000_000.0;
    }
    pub fn minMs(self: PhaseStats) f64 {
        return @as(f64, @floatFromInt(self.min_ns)) / 1_000_000.0;
    }
    pub fn maxMs(self: PhaseStats) f64 {
        return @as(f64, @floatFromInt(self.max_ns)) / 1_000_000.0;
    }
    pub fn stddevMs(self: PhaseStats) f64 {
        return self.stddev_ns / 1_000_000.0;
    }

    /// 샘플 배열로부터 통계 계산. `samples` 는 정렬된다 (caller 가 허용).
    pub fn fromSamples(samples: []u64) PhaseStats {
        std.debug.assert(samples.len > 0);
        std.mem.sort(u64, samples, {}, std.sort.asc(u64));

        var sum: u128 = 0;
        for (samples) |s| sum += s;
        const mean: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples.len));

        var sq: f64 = 0.0;
        for (samples) |s| {
            const d = @as(f64, @floatFromInt(s)) - mean;
            sq += d * d;
        }
        const stddev: f64 = if (samples.len > 1)
            @sqrt(sq / @as(f64, @floatFromInt(samples.len - 1)))
        else
            0.0;

        return .{
            .samples = samples.len,
            .mean_ns = mean,
            .median_ns = percentile(samples, 50),
            .p95_ns = percentile(samples, 95),
            .p99_ns = percentile(samples, 99),
            .min_ns = samples[0],
            .max_ns = samples[samples.len - 1],
            .stddev_ns = stddev,
        };
    }
};

/// p 번째 백분위수 (정렬된 배열 기준). p ∈ [0, 100]. 선형 보간 X — nearest rank.
fn percentile(sorted: []const u64, p: u32) u64 {
    std.debug.assert(p <= 100);
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    // Nearest-rank: idx = ceil(p/100 * N) - 1, clamped.
    const scaled = @as(u64, @intCast(p)) * @as(u64, @intCast(sorted.len));
    var idx: usize = @intCast((scaled + 99) / 100);
    if (idx == 0) idx = 1;
    if (idx > sorted.len) idx = sorted.len;
    return sorted[idx - 1];
}

/// Baseline 파일 포맷 — `--save` 가 출력, `--compare` 가 입력.
pub const Baseline = struct {
    bench_version: u32 = 1,
    source_hint: []const u8 = "",
    iterations: u32 = 0,
    warmup: u32 = 0,
    /// phase name → PhaseStats. Allocator 소유.
    phases: std.StringHashMap(PhaseStats),

    pub fn init(allocator: std.mem.Allocator) Baseline {
        return .{
            .phases = std.StringHashMap(PhaseStats).init(allocator),
        };
    }

    pub fn deinit(self: *Baseline, allocator: std.mem.Allocator) void {
        var it = self.phases.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.phases.deinit();
    }
};

/// Baseline 을 JSON 으로 직렬화.
pub fn writeBaselineJson(writer: anytype, baseline: *const Baseline) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"bench_version\": {d},\n", .{baseline.bench_version});
    try writer.print("  \"source_hint\": \"{s}\",\n", .{baseline.source_hint});
    try writer.print("  \"iterations\": {d},\n", .{baseline.iterations});
    try writer.print("  \"warmup\": {d},\n", .{baseline.warmup});
    try writer.writeAll("  \"phases\": {\n");

    var it = baseline.phases.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try writer.writeAll(",\n");
        first = false;
        const s = entry.value_ptr.*;
        try writer.print(
            "    \"{s}\": {{ \"samples\": {d}, \"mean_ms\": {d:.4}, \"median_ms\": {d:.4}, \"p95_ms\": {d:.4}, \"p99_ms\": {d:.4}, \"min_ms\": {d:.4}, \"max_ms\": {d:.4}, \"stddev_ms\": {d:.4} }}",
            .{
                entry.key_ptr.*,
                s.samples,
                s.meanMs(),
                s.medianMs(),
                s.p95Ms(),
                s.p99Ms(),
                s.minMs(),
                s.maxMs(),
                s.stddevMs(),
            },
        );
    }
    try writer.writeAll("\n  }\n}\n");
}

/// Baseline JSON 파일로부터 읽기. ms → ns 역변환.
pub fn readBaselineJson(allocator: std.mem.Allocator, json_text: []const u8) !Baseline {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var bl = Baseline.init(allocator);
    errdefer bl.deinit(allocator);

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidBaselineFormat,
    };

    if (obj.get("iterations")) |v| switch (v) {
        .integer => |i| bl.iterations = @intCast(i),
        else => {},
    };
    if (obj.get("warmup")) |v| switch (v) {
        .integer => |i| bl.warmup = @intCast(i),
        else => {},
    };

    if (obj.get("phases")) |phases_val| {
        const phases = switch (phases_val) {
            .object => |o| o,
            else => return error.InvalidBaselineFormat,
        };
        var it = phases.iterator();
        while (it.next()) |entry| {
            const name = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(name);
            const stats_obj = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            const mean_ms = jsonNumber(stats_obj.get("mean_ms")) orelse 0.0;
            const median_ms = jsonNumber(stats_obj.get("median_ms")) orelse 0.0;
            const p95_ms = jsonNumber(stats_obj.get("p95_ms")) orelse 0.0;
            const p99_ms = jsonNumber(stats_obj.get("p99_ms")) orelse 0.0;
            const min_ms = jsonNumber(stats_obj.get("min_ms")) orelse 0.0;
            const max_ms = jsonNumber(stats_obj.get("max_ms")) orelse 0.0;
            const stddev_ms = jsonNumber(stats_obj.get("stddev_ms")) orelse 0.0;
            const samples = if (stats_obj.get("samples")) |v| switch (v) {
                .integer => |i| @as(usize, @intCast(i)),
                else => 0,
            } else 0;
            try bl.phases.put(name, .{
                .samples = samples,
                .mean_ns = mean_ms * 1_000_000.0,
                .median_ns = @intFromFloat(median_ms * 1_000_000.0),
                .p95_ns = @intFromFloat(p95_ms * 1_000_000.0),
                .p99_ns = @intFromFloat(p99_ms * 1_000_000.0),
                .min_ns = @intFromFloat(min_ms * 1_000_000.0),
                .max_ns = @intFromFloat(max_ms * 1_000_000.0),
                .stddev_ns = stddev_ms * 1_000_000.0,
            });
        }
    }

    return bl;
}

fn jsonNumber(v: ?std.json.Value) ?f64 {
    if (v == null) return null;
    return switch (v.?) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// Baseline 비교 결과.
pub const Comparison = struct {
    before_mean_ms: f64,
    after_mean_ms: f64,
    delta_ms: f64,
    pct: f64,
    verdict: Verdict,

    pub const Verdict = enum { improved, regressed, unchanged };
};

/// 단일 phase 의 before/after 비교. 5% 이내 변화는 unchanged.
pub fn comparePhase(before: PhaseStats, after: PhaseStats) Comparison {
    const before_ms = before.meanMs();
    const after_ms = after.meanMs();
    const delta = after_ms - before_ms;
    const pct = if (before_ms == 0) 0.0 else (delta / before_ms) * 100.0;
    const verdict: Comparison.Verdict = if (@abs(pct) < 5.0)
        .unchanged
    else if (delta < 0)
        .improved
    else
        .regressed;
    return .{
        .before_mean_ms = before_ms,
        .after_mean_ms = after_ms,
        .delta_ms = delta,
        .pct = pct,
        .verdict = verdict,
    };
}

// ============================================================================
// Benchmark runner (CLI/NAPI 공용)
// ============================================================================

/// Iteration 하나를 실행하는 콜백. caller 가 transpile/bundle 등을 호출.
/// profile 모듈 상태는 bench runner 가 매 iteration 마다 reset + activate.
pub const RunOnceFn = *const fn (allocator: std.mem.Allocator, ctx: ?*anyopaque) anyerror!void;

/// Phase 별 ns 샘플 배열.
pub const Samples = struct {
    /// `phase_cats[i]` 에 대응하는 샘플 목록. Allocator 소유.
    per_phase: []std.ArrayListUnmanaged(u64),

    pub fn deinit(self: *Samples, allocator: std.mem.Allocator) void {
        for (self.per_phase) |*arr| arr.deinit(allocator);
        allocator.free(self.per_phase);
    }
};

/// 통합 benchmark 실행 — profile 모듈을 활용해 phase 별 ns 를 수집.
///
/// `run_one` 은 실제 작업 (transpile / bundle / 기타) 을 수행하는 콜백.
/// 에러는 iteration skip 으로 처리 (warmup/측정 모두 continue).
pub fn runBenchmark(
    allocator: std.mem.Allocator,
    phase_cats: []const profile.Category,
    iterations: u32,
    warmup: u32,
    run_one: RunOnceFn,
    ctx: ?*anyopaque,
) !Samples {
    std.debug.assert(iterations > 0);

    // 샘플 버퍼 초기화 (phase 별).
    const per_phase = try allocator.alloc(std.ArrayListUnmanaged(u64), phase_cats.len);
    errdefer {
        for (per_phase) |*arr| arr.deinit(allocator);
        allocator.free(per_phase);
    }
    for (per_phase) |*arr| arr.* = .empty;

    // warmup — 샘플 수집 없이 JIT/cache 워밍.
    {
        var w: u32 = 0;
        while (w < warmup) : (w += 1) {
            resetAndActivate(phase_cats);
            run_one(allocator, ctx) catch continue;
        }
    }

    // iterations — phase 별 ns 수집.
    {
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            resetAndActivate(phase_cats);
            run_one(allocator, ctx) catch continue;

            for (phase_cats, 0..) |cat, idx| {
                const ns = profile.totalNs(cat);
                try per_phase[idx].append(allocator, ns);
            }
        }
    }

    return .{ .per_phase = per_phase };
}

fn resetAndActivate(phase_cats: []const profile.Category) void {
    profile.resetForTest();
    for (phase_cats) |cat| {
        const name_slice: [1][]const u8 = .{@tagName(cat)};
        profile.addCategories(&name_slice);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "percentile nearest-rank" {
    var data = [_]u64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try testing.expectEqual(@as(u64, 50), percentile(&data, 50));
    try testing.expectEqual(@as(u64, 100), percentile(&data, 100));
    try testing.expectEqual(@as(u64, 10), percentile(&data, 10));
    try testing.expectEqual(@as(u64, 100), percentile(&data, 99));
    try testing.expectEqual(@as(u64, 100), percentile(&data, 95));
}

test "PhaseStats.fromSamples 단일 샘플" {
    var data = [_]u64{100};
    const s = PhaseStats.fromSamples(&data);
    try testing.expectEqual(@as(u64, 100), s.median_ns);
    try testing.expectEqual(@as(u64, 100), s.p95_ns);
    try testing.expectEqual(@as(u64, 100), s.min_ns);
    try testing.expectEqual(@as(u64, 100), s.max_ns);
    try testing.expectEqual(@as(f64, 100.0), s.mean_ns);
    try testing.expectEqual(@as(f64, 0.0), s.stddev_ns);
}

test "PhaseStats.fromSamples 통계 정확성" {
    // 샘플: 10, 20, 30, 40, 50 — mean 30, median 30, stddev 이론값 √250
    var data = [_]u64{ 10, 20, 30, 40, 50 };
    const s = PhaseStats.fromSamples(&data);
    try testing.expectApproxEqAbs(@as(f64, 30.0), s.mean_ns, 0.001);
    try testing.expectEqual(@as(u64, 30), s.median_ns);
    try testing.expectEqual(@as(u64, 10), s.min_ns);
    try testing.expectEqual(@as(u64, 50), s.max_ns);
    try testing.expectApproxEqAbs(@as(f64, @sqrt(250.0)), s.stddev_ns, 0.001);
}

test "PhaseStats.fromSamples 정렬 독립" {
    var data = [_]u64{ 50, 10, 40, 20, 30 };
    const s = PhaseStats.fromSamples(&data);
    try testing.expectEqual(@as(u64, 10), s.min_ns);
    try testing.expectEqual(@as(u64, 50), s.max_ns);
    try testing.expectEqual(@as(u64, 30), s.median_ns);
}

test "ms 변환 게터" {
    const s: PhaseStats = .{
        .samples = 1,
        .mean_ns = 1_000_000.0,
        .median_ns = 2_000_000,
        .p95_ns = 3_000_000,
        .p99_ns = 3_500_000,
        .min_ns = 500_000,
        .max_ns = 5_000_000,
        .stddev_ns = 100_000.0,
    };
    try testing.expectApproxEqAbs(@as(f64, 1.0), s.meanMs(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2.0), s.medianMs(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 3.0), s.p95Ms(), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.1), s.stddevMs(), 0.001);
}

test "Baseline JSON round-trip" {
    const allocator = testing.allocator;
    var bl = Baseline.init(allocator);
    defer bl.deinit(allocator);
    bl.iterations = 100;
    bl.warmup = 10;
    try bl.phases.put(try allocator.dupe(u8, "parse"), .{
        .samples = 100,
        .mean_ns = 42_300_000.0,
        .median_ns = 41_800_000,
        .p95_ns = 48_200_000,
        .p99_ns = 52_100_000,
        .min_ns = 40_100_000,
        .max_ns = 55_300_000,
        .stddev_ns = 2_100_000.0,
    });

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeBaselineJson(fbs.writer(), &bl);
    const json = fbs.getWritten();

    var roundtrip = try readBaselineJson(allocator, json);
    defer roundtrip.deinit(allocator);
    try testing.expectEqual(@as(u32, 100), roundtrip.iterations);
    try testing.expectEqual(@as(u32, 10), roundtrip.warmup);
    const parse_stats = roundtrip.phases.get("parse") orelse return error.MissingPhase;
    try testing.expectApproxEqAbs(@as(f64, 42.3), parse_stats.meanMs(), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 2.1), parse_stats.stddevMs(), 0.01);
}

test "comparePhase improved / regressed / unchanged verdict" {
    const before: PhaseStats = .{ .samples = 100, .mean_ns = 42_300_000.0, .median_ns = 0, .p95_ns = 0, .p99_ns = 0, .min_ns = 0, .max_ns = 0, .stddev_ns = 0 };

    // improved: 25% 감소
    {
        const after: PhaseStats = .{ .samples = 100, .mean_ns = 31_800_000.0, .median_ns = 0, .p95_ns = 0, .p99_ns = 0, .min_ns = 0, .max_ns = 0, .stddev_ns = 0 };
        const cmp = comparePhase(before, after);
        try testing.expect(cmp.verdict == .improved);
        try testing.expect(cmp.delta_ms < 0);
        try testing.expect(cmp.pct < -20);
    }
    // regressed: 10% 증가
    {
        const after: PhaseStats = .{ .samples = 100, .mean_ns = 46_500_000.0, .median_ns = 0, .p95_ns = 0, .p99_ns = 0, .min_ns = 0, .max_ns = 0, .stddev_ns = 0 };
        const cmp = comparePhase(before, after);
        try testing.expect(cmp.verdict == .regressed);
        try testing.expect(cmp.delta_ms > 0);
        try testing.expect(cmp.pct > 5);
    }
    // unchanged: 2% 변화
    {
        const after: PhaseStats = .{ .samples = 100, .mean_ns = 43_100_000.0, .median_ns = 0, .p95_ns = 0, .p99_ns = 0, .min_ns = 0, .max_ns = 0, .stddev_ns = 0 };
        const cmp = comparePhase(before, after);
        try testing.expect(cmp.verdict == .unchanged);
    }
}
