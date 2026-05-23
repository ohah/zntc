//! Benchmark NAPI callback.

const std = @import("std");
const zntc_lib = @import("zntc_lib");
const common = @import("common.zig");
const c = common.c;

const transpile_mod = zntc_lib.transpile;
const profile_mod = zntc_lib.profile;
const bench_mod = zntc_lib.bench;

const native_alloc = common.nativeAlloc();
const throwError = common.throwError;
const getObjectString = common.getObjectString;
const getObjectStringArray = common.getObjectStringArray;
const getObjectUint32 = common.getObjectUint32;
const setDoubleProp = common.setDoubleProp;

// ─── benchmark 함수 (CLI `zntc bench` 의 NAPI 대응) ───

/// benchmark(optionsObj) → { phases: { <name>: { mean_ms, median_ms, p95_ms, p99_ms, min_ms, max_ms, stddev_ms, samples } } }
///
/// optionsObj:
/// - source: string (source code, 또는)
/// - file: string (파일 경로)
/// - filename: string (source 와 함께, 확장자 감지용)
/// - phases: string[] (측정할 category 목록, required)
/// - iterations: number (default 100)
/// - warmup: number (default 10)
pub fn napiBenchmark(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "benchmark requires an options object");

    const opts_obj = argv[0];

    // source or file
    var arena = std.heap.ArenaAllocator.init(native_alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const filename = getObjectString(env, opts_obj, "filename", arena_alloc) orelse
        arena_alloc.dupe(u8, "input.js") catch return throwError(env, "OutOfMemory");

    const source_owned: []const u8 = blk: {
        if (getObjectString(env, opts_obj, "source", arena_alloc)) |s| break :blk s;
        if (getObjectString(env, opts_obj, "file", arena_alloc)) |path| {
            const loaded = std.fs.cwd().readFileAlloc(arena_alloc, path, 100 * 1024 * 1024) catch {
                return throwError(env, "benchmark: cannot read file");
            };
            break :blk loaded;
        }
        return throwError(env, "benchmark requires 'source' or 'file' option");
    };

    // phases
    const phase_names = getObjectStringArray(env, opts_obj, "phases", arena_alloc) orelse
        return throwError(env, "benchmark requires 'phases' (string array)");
    if (phase_names.len == 0) return throwError(env, "benchmark: 'phases' must be non-empty");

    var phase_cats: std.ArrayList(profile_mod.Category) = .empty;
    defer phase_cats.deinit(arena_alloc);
    for (phase_names) |name| {
        const cat = profile_mod.Category.fromString(name) orelse {
            return throwError(env, "benchmark: unknown phase name");
        };
        phase_cats.append(arena_alloc, cat) catch return throwError(env, "OutOfMemory");
    }

    const iterations = getObjectUint32(env, opts_obj, "iterations", 100);
    const warmup = getObjectUint32(env, opts_obj, "warmup", 10);
    if (iterations == 0) return throwError(env, "benchmark: 'iterations' must be >= 1");

    // Benchmark 실행
    const Ctx = struct {
        source: []const u8,
        filename: []const u8,
        fn run(a: std.mem.Allocator, raw_ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_ctx.?));
            var r = transpile_mod.transpileWithCallback(a, self.source, self.filename, .{}, null) catch return;
            r.deinit(a);
        }
    };
    var ctx: Ctx = .{ .source = source_owned, .filename = filename };
    var samples = bench_mod.runBenchmark(arena_alloc, phase_cats.items, iterations, warmup, Ctx.run, &ctx) catch {
        return throwError(env, "benchmark: runner failed");
    };
    defer samples.deinit(arena_alloc);

    // 결과 객체 구성: { phases: { <name>: PhaseStats-flat } }
    var js_result: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_result) != c.napi_ok) return throwError(env, "failed to create result");

    var js_phases: c.napi_value = undefined;
    _ = c.napi_create_object(env, &js_phases);
    _ = c.napi_set_named_property(env, js_result, "phases", js_phases);

    for (phase_names, 0..) |name, i| {
        const stats = bench_mod.PhaseStats.fromSamples(samples.per_phase[i].items);
        var js_stats: c.napi_value = undefined;
        _ = c.napi_create_object(env, &js_stats);
        setDoubleProp(env, js_stats, "mean_ms", stats.meanMs());
        setDoubleProp(env, js_stats, "median_ms", stats.medianMs());
        setDoubleProp(env, js_stats, "p95_ms", stats.p95Ms());
        setDoubleProp(env, js_stats, "p99_ms", stats.p99Ms());
        setDoubleProp(env, js_stats, "min_ms", stats.minMs());
        setDoubleProp(env, js_stats, "max_ms", stats.maxMs());
        setDoubleProp(env, js_stats, "stddev_ms", stats.stddevMs());

        var js_samples: c.napi_value = undefined;
        _ = c.napi_create_uint32(env, @intCast(stats.samples), &js_samples);
        _ = c.napi_set_named_property(env, js_stats, "samples", js_samples);

        var key_buf: [128]u8 = undefined;
        if (name.len >= key_buf.len) continue;
        @memcpy(key_buf[0..name.len], name);
        key_buf[name.len] = 0;
        _ = c.napi_set_named_property(env, js_phases, @ptrCast(&key_buf), js_stats);
    }

    return js_result;
}
