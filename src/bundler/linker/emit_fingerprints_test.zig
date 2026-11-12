// #4545: independent SCC input-contract tests and synthetic microbenchmarks.
// Old DFS oracle is pinned in external evidence; only its receiver/call syntax is adapted.
const std = @import("std");
const Linker = @import("../linker.zig").Linker;
const Graph = @import("../graph.zig").ModuleGraph;
const Module = @import("../module.zig").Module;
const Cache = @import("../resolve_cache.zig").ResolveCache;
const types = @import("../types.zig");
const MI = types.ModuleIndex;
const Rec = types.ImportRecord;
const A = std.testing.allocator;
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    cache: Cache,
    graph: Graph,
    fn init(f: *@This(), n: usize) !void {
        f.arena = .init(A);
        f.cache = Cache.init(A, .{});
        f.graph = Graph.init(A, &f.cache);
        errdefer f.deinit();
        for (0..n) |i| {
            const path = try std.fmt.allocPrint(f.arena.allocator(), "/r3-4545/{d}.mjs", .{i});
            try f.graph.modules.append(A, Module.init(MI.fromUsize(i), path));
            try f.graph.path_to_module.put(A, path, MI.fromUsize(i));
        }
    }
    fn deinit(f: *@This()) void {
        f.graph.deinit();
        f.cache.deinit();
        f.arena.deinit();
    }
    fn edges(f: *@This(), i: usize, input: []const Rec) !void {
        f.graph.moduleAtMut(MI.fromUsize(i)).?.import_records = try f.arena.allocator().dupe(Rec, input);
    }
    fn change(f: *@This(), i: usize) void {
        const m = f.graph.moduleAtMut(MI.fromUsize(i)).?;
        m.uses_top_level_await = !m.uses_top_level_await;
    }
};
fn edge(kind: types.ImportKind, target: usize) Rec {
    return .{ .specifier = "./edge.mjs", .kind = kind, .span = .{ .start = 0, .end = 0 }, .resolved = MI.fromUsize(target) };
}
fn oldTable(a: std.mem.Allocator, l: *const Linker) ![]u64 {
    const out = try a.alloc(u64, l.graph.moduleCount());
    errdefer a.free(out);
    const state = try a.alloc(u8, out.len);
    defer a.free(state);
    @memset(state, 0);
    for (0..out.len) |i| _ = oldDeep(l, @intCast(i), out, state, 0);
    return out;
}

fn oldDeep(self: *const Linker, idx: u32, out: []u64, state: []u8, depth: u32) u64 {
    if (idx >= out.len) return 0;
    if (state[idx] == 2) return out[idx];
    const m = self.graph.getModule(@fromBackingInt(@intCast(idx))) orelse {
        state[idx] = 2;
        out[idx] = 0;
        return 0;
    };
    if (state[idx] == 1) return self.emitFingerprint(m); // 사이클 차단: local 만.
    if (depth >= 4096) return self.emitFingerprint(m); // stack overflow 방어(비-memoize).
    state[idx] = 1;
    var h = self.emitFingerprint(m);
    for (m.import_records) |rec| {
        if (rec.is_external) continue;
        // #4535: require.context 대상은 `rec.resolved`(=.none)가 아니라 `context_resolved_paths`
        // →`path_to_module` 로 해석해야 접힌다. 안 접으면 context 대상의 wrap flip/이름 변경이
        // 소비자 키에 반영 안 돼 stale-hit(초기 구현이 context_expansion_deps 를 봐 dead 였던 버그).
        // ⚠️ `forEachWrapperImportTarget`(위)와 **동일 해석 경로**지만 그건 wrapped-only 로 필터해
        // 여기선 재사용 불가(fingerprint 는 전 대상 필요) — require.context resolution 변경 시 양쪽
        // 동반 수정(이 walk 가 4번째 사본 — 드리프트 주의).
        if (rec.kind == .require_context) {
            for (rec.context_resolved_paths) |abs_opt| {
                const abs = abs_opt orelse continue;
                const wi = self.graph.path_to_module.get(abs) orelse continue;
                h = h *% 31 +% oldDeep(self, wi.toU32(), out, state, depth + 1);
            }
            continue;
        }
        if (rec.resolved.isNone()) continue;
        h = h *% 31 +% oldDeep(self, rec.resolved.toU32(), out, state, depth + 1);
    }
    state[idx] = 2;
    out[idx] = h;
    return h;
}

test "SCC fingerprint acyclic exact old ordered duplicate dynamic and helper edges" {
    var f: Fixture = undefined;
    try f.init(5);
    defer f.deinit();
    try f.edges(0, &.{ edge(.static_import, 1), edge(.dynamic_import, 2), edge(.static_import, 1), edge(.require, 3) });
    try f.edges(1, &.{edge(.re_export, 4)});
    var l = Linker.init(A, &f.graph, .esm);
    defer l.deinit();
    const old = try oldTable(A, &l);
    defer A.free(old);
    const actual = try l.computeEmitFingerprints(A);
    defer A.free(actual);
    try std.testing.expectEqualSlices(u64, old, actual);
    try f.edges(0, &.{ edge(.static_import, 1), edge(.dynamic_import, 2), edge(.require, 3) });
    const after = try l.computeEmitFingerprints(A);
    defer A.free(after);
    try std.testing.expect(actual[0] != after[0]);
}
test "SCC fingerprint context uses actual paths and skips external and none" {
    var f: Fixture = undefined;
    try f.init(4);
    defer f.deinit();
    var context = edge(.require_context, 2);
    context.context_resolved_paths = try f.arena.allocator().dupe(?[]const u8, &.{ f.graph.getModule(MI.fromUsize(1)).?.path, null, "/r3-4545/absent.mjs" });
    var external = edge(.static_import, 3);
    external.is_external = true;
    const none: Rec = .{ .specifier = "missing", .kind = .static_import, .span = .{ .start = 0, .end = 0 } };
    try f.edges(0, &.{ context, external, none });
    var l = Linker.init(A, &f.graph, .esm);
    defer l.deinit();
    const old = try oldTable(A, &l);
    defer A.free(old);
    const before = try l.computeEmitFingerprints(A);
    defer A.free(before);
    try std.testing.expectEqualSlices(u64, old, before);
    f.change(2);
    f.change(3);
    const skipped = try l.computeEmitFingerprints(A);
    defer A.free(skipped);
    try std.testing.expectEqual(before[0], skipped[0]);
    f.change(1);
    const changed = try l.computeEmitFingerprints(A);
    defer A.free(changed);
    try std.testing.expect(before[0] != changed[0]);
}
test "SCC fingerprint overlapping cycles self loop and outside consumer" {
    var f: Fixture = undefined;
    try f.init(5);
    defer f.deinit();
    try f.edges(0, &.{edge(.static_import, 1)});
    try f.edges(1, &.{ edge(.static_import, 0), edge(.dynamic_import, 2) });
    try f.edges(2, &.{edge(.re_export, 1)});
    try f.edges(3, &.{edge(.static_import, 0)});
    try f.edges(4, &.{edge(.static_import, 4)});
    var l = Linker.init(A, &f.graph, .esm);
    defer l.deinit();
    const before = try l.computeEmitFingerprints(A);
    defer A.free(before);
    try std.testing.expectEqual(before[0], before[1]);
    try std.testing.expectEqual(before[1], before[2]);
    f.change(2);
    const after = try l.computeEmitFingerprints(A);
    defer A.free(after);
    for (0..4) |i| try std.testing.expect(before[i] != after[i]);
    try std.testing.expectEqual(before[4], after[4]);
}
test "SCC fingerprint 8193 chain retains provider beyond old depth cutoff" {
    var f: Fixture = undefined;
    try f.init(8193);
    defer f.deinit();
    for (0..8192) |i| try f.edges(i, &.{edge(.static_import, i + 1)});
    var l = Linker.init(A, &f.graph, .esm);
    defer l.deinit();
    const before = try l.computeEmitFingerprints(A);
    defer A.free(before);
    f.change(8192);
    const after = try l.computeEmitFingerprints(A);
    defer A.free(after);
    try std.testing.expect(before[0] != after[0]);
    try std.testing.expect(before[4096] != after[4096]);
}
test "SCC fingerprint OOM table transaction and retry" {
    var f: Fixture = undefined;
    try f.init(5);
    defer f.deinit();
    try f.edges(0, &.{edge(.static_import, 1)});
    try f.edges(1, &.{ edge(.static_import, 0), edge(.static_import, 2) });
    try f.edges(3, &.{edge(.require, 1)});
    var l = Linker.init(A, &f.graph, .esm);
    defer l.deinit();
    const expected = try l.computeEmitFingerprints(A);
    defer A.free(expected);
    const Trial = struct {
        fn run(a: std.mem.Allocator, linker: *Linker, want: []const u64) !void {
            const actual = try linker.computeEmitFingerprints(a);
            defer a.free(actual);
            try std.testing.expectEqualSlices(u64, want, actual);
        }
    };
    try std.testing.checkAllAllocationFailures(A, Trial.run, .{ &l, expected });
    const after = try l.computeEmitFingerprints(A);
    defer A.free(after);
    try std.testing.expectEqualSlices(u64, expected, after);
}
// Counters cover the supplied table allocator only, including output allocation.
// Linker-local lazy caches and old recursion stack are not counted. No peak/RSS claim.
fn measure(l: *Linker, old: bool) !void {
    if (old and l.graph.moduleCount() > 4096) {
        std.debug.print("SCC4545_MICRO oldEligible=false reason=old4096DepthContract n={d} optimize={s}\n", .{ l.graph.moduleCount(), @tagName(@import("builtin").mode) });
        return;
    }
    var counter = std.testing.FailingAllocator.init(A, .{});
    const a = counter.allocator();
    const start = std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds();
    const table = if (old) try oldTable(a, l) else try l.computeEmitFingerprints(a);
    const ns = std.Io.Timestamp.now(std.testing.io, .awake).toNanoseconds() - start;
    var checksum: u64 = 0;
    for (table) |value| checksum +%= value;
    a.free(table);
    std.debug.print("SCC4545_MICRO optimize={s} old={} n={d} ns={d} tableAllocCalls={d} cumulativeAllocatedBytes={d} freedBytes={d} peakBytes=unmeasured checksum={d}\n", .{ @tagName(@import("builtin").mode), old, l.graph.moduleCount(), ns, counter.allocations, counter.allocated_bytes, counter.freed_bytes, checksum });
    try std.testing.expectEqual(counter.allocated_bytes, counter.freed_bytes);
}
test "SCC fingerprint microbench synthetic same Graph fresh and hot locals" {
    for ([_]usize{ 256, 1024, 2048 }) |n| {
        var f: Fixture = undefined;
        try f.init(n);
        defer f.deinit();
        for (0..n - 1) |i| try f.edges(i, &.{edge(.static_import, i + 1)});
        var fresh_old = Linker.init(A, &f.graph, .esm);
        defer fresh_old.deinit();
        var fresh_new = Linker.init(A, &f.graph, .esm);
        defer fresh_new.deinit();
        std.debug.print("SCC4545_MODE fresh n={d}\n", .{n});
        try measure(&fresh_old, true);
        try measure(&fresh_new, false);
        var hot = Linker.init(A, &f.graph, .esm);
        defer hot.deinit();
        try @import("shared_namespace.zig").prepareFingerprintInputs(&hot);
        for (0..n) |i| _ = hot.emitFingerprint(f.graph.getModule(MI.fromUsize(i)).?);
        std.debug.print("SCC4545_MODE hot-locals n={d}\n", .{n});
        for (0..8) |round| {
            if (round % 2 == 0) {
                try measure(&hot, true);
                try measure(&hot, false);
            } else {
                try measure(&hot, false);
                try measure(&hot, true);
            }
        }
    }
}

test "SCC fingerprint microbench synthetic ring old incomplete timing baseline only" {
    for ([_]usize{ 256, 1024 }) |n| {
        var f: Fixture = undefined;
        try f.init(n);
        defer f.deinit();
        for (0..n) |i| try f.edges(i, &.{ edge(.static_import, (i + 1) % n), edge(.dynamic_import, (i + 17) % n) });
        var l = Linker.init(A, &f.graph, .esm);
        defer l.deinit();
        try @import("shared_namespace.zig").prepareFingerprintInputs(&l);
        for (0..n) |i| _ = l.emitFingerprint(f.graph.getModule(MI.fromUsize(i)).?);
        std.debug.print("SCC4545_MODE ring-hot old-semantics-incomplete n={d} edges={d}\n", .{ n, n * 2 });
        for (0..8) |round| {
            if (round % 2 == 0) {
                try measure(&l, true);
                try measure(&l, false);
            } else {
                try measure(&l, false);
                try measure(&l, true);
            }
        }
    }
}
