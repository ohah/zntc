//! `zntc bench` CLI subcommand.

const std = @import("std");
const lib = @import("zntc_lib");

/// `zntc bench --phase=<CATS> [options] <FILE>` 서브커맨드.
///
/// 지정한 phase 를 N 회 반복 실행하며 `profile` 모듈의 수치로부터
/// 통계 (mean/median/p95/p99/stddev/min/max) 를 출력한다. baseline save/compare
/// 로 최적화 전후 비교 가능.
///
/// CLI spec: docs/design/profile-infrastructure.md § zntc bench.
const BenchArgs = struct {
    phases_csv: ?[]const u8 = null,
    iterations: u32 = 100,
    warmup: u32 = 10,
    save_path: ?[]const u8 = null,
    compare_path: ?[]const u8 = null,
    format: lib.profile.Format = .table,
    profile_level: lib.profile.Level = .summary,
    input_file: ?[]const u8 = null,
};

fn parseBenchArgs(args: []const []const u8) !BenchArgs {
    var result: BenchArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.startsWith(u8, a, "--phase=")) {
            result.phases_csv = a["--phase=".len..];
        } else if (std.mem.startsWith(u8, a, "--iterations=")) {
            result.iterations = try std.fmt.parseInt(u32, a["--iterations=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--warmup=")) {
            result.warmup = try std.fmt.parseInt(u32, a["--warmup=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--save=")) {
            result.save_path = a["--save=".len..];
        } else if (std.mem.startsWith(u8, a, "--compare=")) {
            result.compare_path = a["--compare=".len..];
        } else if (std.mem.startsWith(u8, a, "--format=")) {
            const s = a["--format=".len..];
            result.format = lib.profile.Format.fromString(s) orelse return error.InvalidFormat;
        } else if (std.mem.startsWith(u8, a, "--profile-level=")) {
            const s = a["--profile-level=".len..];
            result.profile_level = lib.profile.Level.fromString(s) orelse return error.InvalidLevel;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else if (result.input_file == null) {
            result.input_file = a;
        } else {
            return error.MultipleInputFiles;
        }
    }
    return result;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    // 0.16: deprecatedWriter 제거. length-0 buffer(`&.{}`) = unbuffered → 쓰기 즉시
    // drain, std.process.exit 가 defer 우회해도 메시지 유실 없음 (flush 불필요).
    var stdout_state = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_state.interface;
    var stderr_state = std.Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_state.interface;

    const opts = parseBenchArgs(args) catch |err| {
        try stderr.print("zntc bench: argument error ({s}). See `zntc bench --help`.\n", .{@errorName(err)});
        std.process.exit(1);
    };
    const phases_csv = opts.phases_csv orelse {
        try stderr.writeAll("zntc bench: --phase=<CATS> is required (e.g. --phase=parse)\n");
        std.process.exit(1);
    };
    const input_file = opts.input_file orelse {
        try stderr.writeAll("zntc bench: missing input file\n");
        std.process.exit(1);
    };
    if (opts.iterations == 0) {
        try stderr.writeAll("zntc bench: --iterations must be >= 1\n");
        std.process.exit(1);
    }

    // Phase 목록 파싱 (profile Category 로 변환 + owned slice 로 보관).
    var phase_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer phase_names.deinit(allocator);
    var phase_cats: std.ArrayListUnmanaged(lib.profile.Category) = .empty;
    defer phase_cats.deinit(allocator);
    {
        var it = std.mem.splitScalar(u8, phases_csv, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len == 0) continue;
            if (std.ascii.eqlIgnoreCase(name, "all") or std.ascii.eqlIgnoreCase(name, "none")) {
                try stderr.print("zntc bench: --phase={s} not allowed (must be specific phase names)\n", .{name});
                std.process.exit(1);
            }
            const cat = lib.profile.Category.fromString(name) orelse {
                try stderr.print("zntc bench: unknown phase '{s}'\n", .{name});
                std.process.exit(1);
            };
            try phase_names.append(allocator, name);
            try phase_cats.append(allocator, cat);
        }
    }

    // 소스 읽기 (한 번, iteration 간 동일한 입력 사용).
    const source = std.Io.Dir.cwd().readFileAlloc(io, input_file, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
        try stderr.print("zntc bench: cannot read '{s}': {}\n", .{ input_file, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    // Benchmark 실행 — bench.zig 의 공용 runner (NAPI 와 공유).
    const Ctx = struct {
        source: []const u8,
        filename: []const u8,
        fn run(a: std.mem.Allocator, raw_ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            var result = lib.transpile.transpileWithCallback(a, self.source, self.filename, .{}, null) catch return;
            result.deinit(a);
        }
    };
    var ctx: Ctx = .{ .source = source, .filename = input_file };
    var samples = try lib.bench.runBenchmark(
        allocator,
        phase_cats.items,
        opts.iterations,
        opts.warmup,
        Ctx.run,
        &ctx,
    );
    defer samples.deinit(allocator);

    // 통계 계산.
    var phase_stats: std.ArrayListUnmanaged(lib.bench.PhaseStats) = .empty;
    defer phase_stats.deinit(allocator);
    for (samples.per_phase) |*arr| {
        try phase_stats.append(allocator, lib.bench.PhaseStats.fromSamples(arr.items));
    }

    // compare — 먼저 비교 출력, save 는 그 다음.
    if (opts.compare_path) |cmp_path| {
        const cmp_json = std.Io.Dir.cwd().readFileAlloc(io, cmp_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
            try stderr.print("zntc bench: cannot read baseline '{s}': {}\n", .{ cmp_path, err });
            std.process.exit(1);
        };
        defer allocator.free(cmp_json);
        var baseline = lib.bench.readBaselineJson(allocator, cmp_json) catch |err| {
            try stderr.print("zntc bench: invalid baseline format: {}\n", .{err});
            std.process.exit(1);
        };
        defer baseline.deinit(allocator);
        try printBenchCompare(stdout, phase_names.items, phase_stats.items, &baseline);
    } else {
        try printBenchSummary(stdout, phase_names.items, phase_stats.items, opts.iterations, opts.warmup, opts.format);
    }

    // save — 현재 결과를 baseline 으로 저장.
    if (opts.save_path) |save_path| {
        var bl = lib.bench.Baseline.init(allocator);
        defer bl.deinit(allocator);
        bl.iterations = opts.iterations;
        bl.warmup = opts.warmup;
        bl.source_hint = std.fs.path.basename(input_file);
        for (phase_names.items, phase_stats.items) |name, stats| {
            const name_dup = try allocator.dupe(u8, name);
            try bl.phases.put(name_dup, stats);
        }
        const file = std.Io.Dir.cwd().createFile(io, save_path, .{}) catch |err| {
            try stderr.print("zntc bench: cannot create '{s}': {}\n", .{ save_path, err });
            std.process.exit(1);
        };
        defer file.close(io);
        var bl_writer = file.writer(io, &.{});
        try lib.bench.writeBaselineJson(&bl_writer.interface, &bl);
        try stderr.print("baseline saved: {s}\n", .{save_path});
    }
}

fn printBenchSummary(
    writer: anytype,
    phase_names: []const []const u8,
    stats: []const lib.bench.PhaseStats,
    iterations: u32,
    warmup: u32,
    format: lib.profile.Format,
) !void {
    switch (format) {
        .json => try printBenchJson(writer, phase_names, stats, iterations, warmup),
        .csv => try printBenchCsv(writer, phase_names, stats),
        else => try printBenchTable(writer, phase_names, stats, iterations, warmup),
    }
}

fn printBenchTable(
    writer: anytype,
    phase_names: []const []const u8,
    stats: []const lib.bench.PhaseStats,
    iterations: u32,
    warmup: u32,
) !void {
    try writer.writeAll("=== ZNTC Benchmark ===\n");
    try writer.print("iterations: {d} (warmup: {d})\n\n", .{ iterations, warmup });
    try writer.writeAll("Phase       mean       median     p95        p99        stddev     min        max\n");
    try writer.writeAll("----------|----------|----------|----------|----------|----------|----------|----------\n");
    for (phase_names, stats) |name, s| {
        try writer.print("{s: <10} {d: >6.2}ms  {d: >6.2}ms  {d: >6.2}ms  {d: >6.2}ms  {d: >6.2}ms  {d: >6.2}ms  {d: >6.2}ms\n", .{
            name, s.meanMs(), s.medianMs(), s.p95Ms(), s.p99Ms(), s.stddevMs(), s.minMs(), s.maxMs(),
        });
    }
}

fn printBenchJson(
    writer: anytype,
    phase_names: []const []const u8,
    stats: []const lib.bench.PhaseStats,
    iterations: u32,
    warmup: u32,
) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"bench_version\": 1,\n", .{});
    try writer.print("  \"iterations\": {d},\n", .{iterations});
    try writer.print("  \"warmup\": {d},\n", .{warmup});
    try writer.writeAll("  \"phases\": {\n");
    for (phase_names, stats, 0..) |name, s, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.print(
            "    \"{s}\": {{ \"samples\": {d}, \"mean_ms\": {d:.4}, \"median_ms\": {d:.4}, \"p95_ms\": {d:.4}, \"p99_ms\": {d:.4}, \"min_ms\": {d:.4}, \"max_ms\": {d:.4}, \"stddev_ms\": {d:.4} }}",
            .{ name, s.samples, s.meanMs(), s.medianMs(), s.p95Ms(), s.p99Ms(), s.minMs(), s.maxMs(), s.stddevMs() },
        );
    }
    try writer.writeAll("\n  }\n}\n");
}

fn printBenchCsv(
    writer: anytype,
    phase_names: []const []const u8,
    stats: []const lib.bench.PhaseStats,
) !void {
    try writer.writeAll("phase,samples,mean_ms,median_ms,p95_ms,p99_ms,min_ms,max_ms,stddev_ms\n");
    for (phase_names, stats) |name, s| {
        try writer.print("{s},{d},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4}\n", .{
            name, s.samples, s.meanMs(), s.medianMs(), s.p95Ms(), s.p99Ms(), s.minMs(), s.maxMs(), s.stddevMs(),
        });
    }
}

fn printBenchCompare(
    writer: anytype,
    phase_names: []const []const u8,
    stats: []const lib.bench.PhaseStats,
    baseline: *const lib.bench.Baseline,
) !void {
    try writer.writeAll("=== ZNTC Benchmark (vs baseline) ===\n\n");
    try writer.writeAll("Phase       before     after      delta     %         verdict\n");
    try writer.writeAll("----------|----------|----------|---------|---------|----------\n");
    for (phase_names, stats) |name, after| {
        const before = baseline.phases.get(name) orelse continue;
        const cmp = lib.bench.comparePhase(before, after);
        const verdict_str: []const u8 = switch (cmp.verdict) {
            .improved => "+ improved",
            .regressed => "- regressed",
            .unchanged => "= unchanged",
        };
        const sign_delta: []const u8 = if (cmp.delta_ms >= 0) "+" else "";
        const sign_pct: []const u8 = if (cmp.pct >= 0) "+" else "";
        try writer.print("{s: <10} {d: >6.2}ms  {d: >6.2}ms  {s}{d: >6.2}ms {s}{d: >6.1}%  {s}\n", .{
            name, cmp.before_mean_ms, cmp.after_mean_ms, sign_delta, cmp.delta_ms, sign_pct, cmp.pct, verdict_str,
        });
    }
}
