//! Incremental bench v4 — production-realistic invocation pattern.
//! v3 는 changed_files=null 로 호출해 watcher-skip path 우회 (641 stat syscall 발생).
//! v4 는 changed_files 의 3가지 case 를 측정해 stat skip ratio 를 격리.
//!
//! case A: changed_files = empty HashMap   — watcher 가 변경 0 보고 (no-change rebuild)
//! case B: changed_files = {entry.ts}      — watcher 가 1 file 변경 보고 (single-file edit)
//! case C: changed_files = null            — watcher 미통합 (=v3 baseline)
//!
//! lodash-es 641 module fixture 로 측정.

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const PersistentModuleStore = @import("../module_store.zig").PersistentModuleStore;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;
const profile = @import("../../profile.zig");

const LODASH_ENTRY =
    \\import {
    \\  uniq, chunk, compact, drop, dropRight, fill, findIndex, flatten,
    \\  flattenDeep, head, indexOf, initial, intersection, last, nth, pull,
    \\  pullAll, remove, slice, sortedIndex, take, takeRight, union, uniqBy,
    \\  without, xor, zip, zipObject, countBy, every, filter, find, forEach,
    \\  groupBy, includes, keyBy, map, orderBy, partition, reduce, reject,
    \\  sample, shuffle, size, some, sortBy, debounce, throttle, memoize,
    \\  once, defer, delay,
    \\} from 'lodash-es';
    \\console.log([uniq, chunk, compact].map(f => typeof f).join(','));
    \\
;

const Case = enum { empty, single_entry, null_changed };

const WarmResult = struct {
    parse_ns: u64,
    semantic_ns: u64,
    discover_ns: u64,
    total_ns: u64,
    incr_mtime_ns: u64,
    incr_cache_lookup_ns: u64,
    incr_cache_hit_assign_ns: u64,
    incr_miss_parse_ns: u64,
    incr_replay_ns: u64,
    incr_replay_add_module_ns: u64,
    incr_replay_request_exports_ns: u64,
    incr_replay_record_dep_ns: u64,
    incr_replay_other_ns: u64,
    incr_req_static_import_ns: u64,
    incr_req_re_export_ns: u64,
    incr_req_simple_ns: u64,
    incr_req_mutex_ns: u64,
    incr_req_outer_map_ns: u64,
    incr_req_inner_contains_ns: u64,
    incr_req_inner_put_ns: u64,
    incr_re_export_entry_ns: u64,
    incr_re_export_outer_ns: u64,
    incr_miss_resolve_ns: u64,
};

fn measureWarm(allocator: std.mem.Allocator, store: *PersistentModuleStore, entry: []const u8, case: Case) !WarmResult {
    profile.resetCounters();

    var changed_set: std.StringHashMap(void) = .init(allocator);
    defer changed_set.deinit();
    if (case == .single_entry) {
        try changed_set.put(entry, {});
    }

    const changed_ptr: ?*const std.StringHashMap(void) = switch (case) {
        .empty => &changed_set,
        .single_entry => &changed_set,
        .null_changed => null,
    };

    var b = Bundler.init(allocator, .{
        .entry_points = &.{entry},
        .module_store = store,
        .changed_files = changed_ptr,
    });
    defer b.deinit();
    const r = try b.bundle();
    defer r.deinit(allocator);

    const parse_ns = profile.totalNs(.parse);
    const semantic_ns = profile.totalNs(.semantic);
    const discover_ns = profile.totalNs(.graph_discover);
    return .{
        .parse_ns = parse_ns,
        .semantic_ns = semantic_ns,
        .discover_ns = discover_ns,
        .total_ns = parse_ns + semantic_ns + discover_ns,
        .incr_mtime_ns = profile.totalNs(.graph_discover_incr_mtime),
        .incr_cache_lookup_ns = profile.totalNs(.graph_discover_incr_cache_lookup),
        .incr_cache_hit_assign_ns = profile.totalNs(.graph_discover_incr_cache_hit_assign),
        .incr_miss_parse_ns = profile.totalNs(.graph_discover_incr_miss_parse),
        .incr_replay_ns = profile.totalNs(.graph_discover_incr_replay),
        .incr_replay_add_module_ns = profile.totalNs(.graph_discover_incr_replay_add_module),
        .incr_replay_request_exports_ns = profile.totalNs(.graph_discover_incr_replay_request_exports),
        .incr_replay_record_dep_ns = profile.totalNs(.graph_discover_incr_replay_record_dep),
        .incr_replay_other_ns = profile.totalNs(.graph_discover_incr_replay_other),
        .incr_req_static_import_ns = profile.totalNs(.graph_discover_incr_req_static_import),
        .incr_req_re_export_ns = profile.totalNs(.graph_discover_incr_req_re_export),
        .incr_req_simple_ns = profile.totalNs(.graph_discover_incr_req_simple),
        .incr_req_mutex_ns = profile.totalNs(.graph_discover_incr_req_mutex),
        .incr_req_outer_map_ns = profile.totalNs(.graph_discover_incr_req_outer_map),
        .incr_req_inner_contains_ns = profile.totalNs(.graph_discover_incr_req_inner_contains),
        .incr_req_inner_put_ns = profile.totalNs(.graph_discover_incr_req_inner_put),
        .incr_re_export_entry_ns = profile.totalNs(.graph_discover_incr_re_export_entry),
        .incr_re_export_outer_ns = profile.totalNs(.graph_discover_incr_re_export_outer),
        .incr_miss_resolve_ns = profile.totalNs(.graph_discover_incr_miss_resolve),
    };
}

fn printSubPhase(label: []const u8, r: WarmResult) void {
    const d = r.discover_ns;
    const rep = r.incr_replay_ns;
    const req = r.incr_req_static_import_ns + r.incr_req_re_export_ns + r.incr_req_simple_ns;
    // 32-arg print 한계 회피 — 두 호출로 분리.
    std.debug.print(
        \\  {s} sub-phase (us, % of discover):
        \\    mtime           = {d:>7}us ({d:>3}%)
        \\    cache_lookup    = {d:>7}us ({d:>3}%)
        \\    cache_hit_assign= {d:>7}us ({d:>3}%)
        \\    miss_parse      = {d:>7}us ({d:>3}%)
        \\    replay          = {d:>7}us ({d:>3}%)
        \\      add_module    = {d:>7}us ({d:>3}% of replay)
        \\      request_export= {d:>7}us ({d:>3}% of replay)
        \\      record_dep    = {d:>7}us ({d:>3}% of replay)
        \\      other         = {d:>7}us ({d:>3}% of replay)
        \\    miss_resolve    = {d:>7}us ({d:>3}%)
        \\
    , .{
        label,
        r.incr_mtime_ns / 1000,
        if (d == 0) @as(u64, 0) else r.incr_mtime_ns * 100 / d,
        r.incr_cache_lookup_ns / 1000,
        if (d == 0) @as(u64, 0) else r.incr_cache_lookup_ns * 100 / d,
        r.incr_cache_hit_assign_ns / 1000,
        if (d == 0) @as(u64, 0) else r.incr_cache_hit_assign_ns * 100 / d,
        r.incr_miss_parse_ns / 1000,
        if (d == 0) @as(u64, 0) else r.incr_miss_parse_ns * 100 / d,
        r.incr_replay_ns / 1000,
        if (d == 0) @as(u64, 0) else r.incr_replay_ns * 100 / d,
        r.incr_replay_add_module_ns / 1000,
        if (rep == 0) @as(u64, 0) else r.incr_replay_add_module_ns * 100 / rep,
        r.incr_replay_request_exports_ns / 1000,
        if (rep == 0) @as(u64, 0) else r.incr_replay_request_exports_ns * 100 / rep,
        r.incr_replay_record_dep_ns / 1000,
        if (rep == 0) @as(u64, 0) else r.incr_replay_record_dep_ns * 100 / rep,
        r.incr_replay_other_ns / 1000,
        if (rep == 0) @as(u64, 0) else r.incr_replay_other_ns * 100 / rep,
        r.incr_miss_resolve_ns / 1000,
        if (d == 0) @as(u64, 0) else r.incr_miss_resolve_ns * 100 / d,
    });
    std.debug.print(
        \\    request_exports breakdown (us, % of request_exports):
        \\      static_import = {d:>7}us ({d:>3}%)
        \\      re_export     = {d:>7}us ({d:>3}%)
        \\      simple        = {d:>7}us ({d:>3}%)
        \\    requestNamed/All internals (us, % of request_exports):
        \\      mutex         = {d:>7}us ({d:>3}%)
        \\      outer_map     = {d:>7}us ({d:>3}%)
        \\      inner_contains= {d:>7}us ({d:>3}%)
        \\      inner_put     = {d:>7}us ({d:>3}%)
        \\    re_export caller side (us, % of re_export):
        \\      entry         = {d:>7}us ({d:>3}%)
        \\      outer_loop    = {d:>7}us ({d:>3}%)
        \\
    , .{
        r.incr_req_static_import_ns / 1000,
        if (req == 0) @as(u64, 0) else r.incr_req_static_import_ns * 100 / req,
        r.incr_req_re_export_ns / 1000,
        if (req == 0) @as(u64, 0) else r.incr_req_re_export_ns * 100 / req,
        r.incr_req_simple_ns / 1000,
        if (req == 0) @as(u64, 0) else r.incr_req_simple_ns * 100 / req,
        r.incr_req_mutex_ns / 1000,
        if (req == 0) @as(u64, 0) else r.incr_req_mutex_ns * 100 / req,
        r.incr_req_outer_map_ns / 1000,
        if (req == 0) @as(u64, 0) else r.incr_req_outer_map_ns * 100 / req,
        r.incr_req_inner_contains_ns / 1000,
        if (req == 0) @as(u64, 0) else r.incr_req_inner_contains_ns * 100 / req,
        r.incr_req_inner_put_ns / 1000,
        if (req == 0) @as(u64, 0) else r.incr_req_inner_put_ns * 100 / req,
        r.incr_re_export_entry_ns / 1000,
        if (r.incr_req_re_export_ns == 0) @as(u64, 0) else r.incr_re_export_entry_ns * 100 / r.incr_req_re_export_ns,
        r.incr_re_export_outer_ns / 1000,
        if (r.incr_req_re_export_ns == 0) @as(u64, 0) else r.incr_re_export_outer_ns * 100 / r.incr_req_re_export_ns,
    });
}

test "incremental bench v4: changed_files null/empty/single comparison" {
    profile.resetForTest();
    profile.setLevel(.summary);
    profile.addCategories(&.{
        "parse",
        "semantic",
        "graph_discover",
        "graph_discover_incr_mtime",
        "graph_discover_incr_cache_lookup",
        "graph_discover_incr_cache_hit_assign",
        "graph_discover_incr_miss_parse",
        "graph_discover_incr_replay",
        "graph_discover_incr_replay_add_module",
        "graph_discover_incr_replay_request_exports",
        "graph_discover_incr_replay_record_dep",
        "graph_discover_incr_replay_other",
        "graph_discover_incr_req_static_import",
        "graph_discover_incr_req_re_export",
        "graph_discover_incr_req_simple",
        "graph_discover_incr_req_mutex",
        "graph_discover_incr_req_outer_map",
        "graph_discover_incr_req_inner_contains",
        "graph_discover_incr_req_inner_put",
        "graph_discover_incr_re_export_entry",
        "graph_discover_incr_re_export_outer",
        "graph_discover_incr_miss_resolve",
    });

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts", LODASH_ENTRY);

    // node_modules symlink — lodash-es resolve 가능하게.
    // cwd 가 repo root (zig build 의 실행 위치) → 그 안의 node_modules 를 symlink target.
    const real_nm = std.fs.cwd().realpathAlloc(allocator, "node_modules") catch |err| {
        std.debug.print("[bench v4] cwd node_modules absent ({}), skip\n", .{err});
        return error.SkipZigTest;
    };
    defer allocator.free(real_nm);

    const tmp_real = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_real);
    const tmp_nm = try std.fs.path.join(allocator, &.{ tmp_real, "node_modules" });
    defer allocator.free(tmp_nm);
    std.posix.symlink(real_nm, tmp_nm) catch |err| {
        std.debug.print("[bench v4] symlink skip: {}\n", .{err});
        return error.SkipZigTest;
    };

    const entry = try std.fs.path.join(allocator, &.{ tmp_real, "entry.ts" });
    defer allocator.free(entry);

    var store: PersistentModuleStore = .init(allocator);
    defer store.deinit();

    // Cold build — store fill.
    var cold_module_count: usize = 0;
    {
        var b = Bundler.init(allocator, .{
            .entry_points = &.{entry},
            .module_store = &store,
        });
        defer b.deinit();
        const r = b.bundle() catch |err| {
            std.debug.print("[bench v4] cold bundle fail: {}\n", .{err});
            return error.SkipZigTest;
        };
        defer r.deinit(allocator);
        cold_module_count = if (r.module_paths) |paths| paths.len else 0;
    }
    const cold_parse = profile.totalNs(.parse);
    const cold_semantic = profile.totalNs(.semantic);
    const cold_discover = profile.totalNs(.graph_discover);
    const cold_total = cold_parse + cold_semantic + cold_discover;

    // Warm 3 case — first run once and discard (dir-fd / inode cache warmup).
    _ = try measureWarm(allocator, &store, entry, .null_changed);

    const c_null = try measureWarm(allocator, &store, entry, .null_changed);
    const c_empty = try measureWarm(allocator, &store, entry, .empty);
    const c_single = try measureWarm(allocator, &store, entry, .single_entry);

    std.debug.print(
        \\
        \\[incremental-bench v4] lodash-es {d} module, 3 case warm:
        \\  cold        : parse={d}us semantic={d}us discover={d}us total={d}us
        \\  warm null   : parse={d}us semantic={d}us discover={d}us total={d}us  (v3 baseline, 641 stat)
        \\  warm empty  : parse={d}us semantic={d}us discover={d}us total={d}us  (no-change watcher)
        \\  warm single : parse={d}us semantic={d}us discover={d}us total={d}us  (1-file watcher)
        \\
        \\  stat skip ratio (empty/null) = {d}%
        \\  stat skip ratio (single/null) = {d}%
        \\
    , .{
        cold_module_count,
        cold_parse / 1000,
        cold_semantic / 1000,
        cold_discover / 1000,
        cold_total / 1000,
        c_null.parse_ns / 1000,
        c_null.semantic_ns / 1000,
        c_null.discover_ns / 1000,
        c_null.total_ns / 1000,
        c_empty.parse_ns / 1000,
        c_empty.semantic_ns / 1000,
        c_empty.discover_ns / 1000,
        c_empty.total_ns / 1000,
        c_single.parse_ns / 1000,
        c_single.semantic_ns / 1000,
        c_single.discover_ns / 1000,
        c_single.total_ns / 1000,
        if (c_null.total_ns == 0) @as(u64, 0) else c_empty.total_ns * 100 / c_null.total_ns,
        if (c_null.total_ns == 0) @as(u64, 0) else c_single.total_ns * 100 / c_null.total_ns,
    });

    printSubPhase("null  ", c_null);
    printSubPhase("empty ", c_empty);
    printSubPhase("single", c_single);
}
