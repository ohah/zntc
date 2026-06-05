//! link sub-phase 분해 벤치 (#4176 측정 인프라).
//!
//! 이슈 #4176 의 타깃 경로 = **dev HMR 보존-hit rebuild 의 link 단계**. 그 단계는
//! sub-phase 5개가 *전체 모듈* 을 순회한다(변경 1개여도 O(N)):
//!   - lExp  buildExportMap            → export_map[(module_index, name)]
//!   - lRes  resolveImports            → import canonical (resolveExportChain)
//!   - lReExp populateReExportAliases  → alias canonical
//!   - lImp  populateImportSymbols     → ib.symbol / ib.local_symbol
//!   - lNs   populateNamespaceAccesses → namespace escape
//!
//! 이 벤치는 `IncrementalBundler`(dev_mode + enable_persistence)로 보존-hit rebuild 를
//! 구동하고, `result.profile_snapshot` 에서 link sub-phase total 을 읽어 분해 출력한다.
//! (`incremental_bench_v4` 는 store 기반 non-dev 경로라 `scope_hoist or dev_mode` 게이트에
//! 걸려 **linker 자체를 생성하지 않는다** — link sub-phase 측정 불가. 그래서 별도 harness.)
//!
//! `other`(5 sub-phase 밖 잔여)도 분해한다 — lRen(computeRenames, 보존-hit 면 skip=0) +
//! lChain(chain_cache 스캔) + lGuard(renameReuseGuard, #4173 G1 경량) + lInj
//! (injectPreservedRenames). **측정 결과 warm 보존-hit 의 link 는 lExp ~34% / lRes ~26% /
//! lInj ~37% 3-way 지배** (lReExp/lImp/lNs/lRen/lChain/lGuard 모두 ~0%). lInj=보존 rename
//! 스냅샷 전량 재주입(O(snap.entries))으로, 변경 1개여도 전 모듈 rename 을 매 빌드 다시
//! 주입한다 — #4176 이 안 다룬 warm 레버. (namespace-free fixture 에서도 ~37% 로 동일 →
//! namespace synthetic 이름 artifact 아님, 진짜 O(rename 심볼 수).)
//!
//! 합성 fixture (leaf×M + barrel re-export + consumer×K) 가 sub-phase 를 자극한다:
//!   - leaf×M + barrel(re-export×M)         → lExp (export_bindings) / lReExp / lRes 체인
//!   - consumer×K (barrel named import ×2)   → lRes(체인 해석) / lImp (findExportBinding)
//!   - consumer×K (`import * as NS` escape)  → lNs (namespace binding 순회 + escape 판정)
//!
//! body-only edit(말미 숫자 리터럴) → 위상 보존 + rename 재사용 가드 통과 = 이슈 타깃 경로.
//! 보존-hit 검증(`graph_changed == false`)으로 측정이 올바른 경로임을 보장한다.
//!
//! ⚠️ **lNs heavy-path caveat**: lNs 의 *무거운* 작업은 namespace **member-access**
//! (`NS.x`) 인라인이다. 그런데 같은 fixture 패턴(다수 모듈이 namespace member-access)은
//! 병렬 emit 의 별도 **double-free 버그**(공유 ns inline-object 문자열, metadata_types.zig:145)
//! 를 노출해 flaky segfault 를 낸다 — 측정 인프라와 무관한 선재 버그라 여기선 namespace 를
//! **escape**(`export const nsref = NS`)만 시켜 lNs binding 순회는 돌리되 인라인 경로는 피한다.
//! → 이 fixture 에서 lNs 절대값은 작게(≈0%) 나온다. heavy lNs(member-access) 실측은 위 버그
//! 수정 후 또는 8092 앱에서.
//!
//! ⚠️ 절대 numbers 는 fixture 규모(수백 모듈)에 비례 — 8092 앱과 다르나 *상대 분포*
//! (어느 sub-phase 가 지배적인가)는 동형. 8092 실측은 `ZNTC_PROFILE=all zntc --serve` 의
//! `bundle_build_done` SSE event `profile` 필드(snapshotToJson, link_*_ms)로.

const std = @import("std");
const IncrementalBundler = @import("../incremental.zig").IncrementalBundler;
const BundleResult = @import("../bundler.zig").BundleResult;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;
const profile = @import("../../profile.zig");

/// fixture 규모 — CI 시간 vs 측정 신호 trade-off. 로컬 정밀 측정은 상향 가능.
/// consumer{j} 가 leaf{j} 를 namespace import(escape) 하므로 K ≤ M 필요.
const M_LEAVES = 200;
const K_CONSUMERS = 200;
comptime {
    if (K_CONSUMERS > M_LEAVES) @compileError("K_CONSUMERS ≤ M_LEAVES (consumer{j} namespaces leaf{j})");
}
/// 보존-hit warm rebuild 측정 반복 — 최소값(noise floor)을 취한다.
const WARM_ITERS = 3;

const LinkBreakdown = struct {
    link_ns: u64,
    lexp_ns: u64,
    lres_ns: u64,
    lreexp_ns: u64,
    limp_ns: u64,
    lns_ns: u64,
    lren_ns: u64, // computeRenames — reuse-hit(보존-hit)에선 skip 되어야 0. >0 이면 가드 미통과.
    lchain_ns: u64, // chain_cache_enabled 스캔 (link 내, 첫 re-export 까지)
    lguard_ns: u64, // renameReuseGuard (G1 경량, #4173)
    linj_ns: u64, // injectPreservedRenames

    fn fromSnapshot(snap: *const profile.ProfileSnapshot) LinkBreakdown {
        return .{
            .link_ns = snap.total(.link),
            .lexp_ns = snap.total(.link_build_export_map),
            .lres_ns = snap.total(.link_resolve_imports),
            .lreexp_ns = snap.total(.link_populate_re_export_aliases),
            .limp_ns = snap.total(.link_populate_import_symbols),
            .lns_ns = snap.total(.link_populate_namespace_accesses),
            .lren_ns = snap.total(.link_compute_renames),
            .lchain_ns = snap.total(.link_chain_cache_scan),
            .lguard_ns = snap.total(.link_rename_reuse_guard),
            .linj_ns = snap.total(.link_inject_renames),
        };
    }

    /// per-field 최소값 — 반복 측정의 noise floor 추정.
    fn minWith(self: LinkBreakdown, o: LinkBreakdown) LinkBreakdown {
        return .{
            .link_ns = @min(self.link_ns, o.link_ns),
            .lexp_ns = @min(self.lexp_ns, o.lexp_ns),
            .lres_ns = @min(self.lres_ns, o.lres_ns),
            .lreexp_ns = @min(self.lreexp_ns, o.lreexp_ns),
            .limp_ns = @min(self.limp_ns, o.limp_ns),
            .lns_ns = @min(self.lns_ns, o.lns_ns),
            .lren_ns = @min(self.lren_ns, o.lren_ns),
            .lchain_ns = @min(self.lchain_ns, o.lchain_ns),
            .lguard_ns = @min(self.lguard_ns, o.lguard_ns),
            .linj_ns = @min(self.linj_ns, o.linj_ns),
        };
    }
};

/// consumer{j} 소스. `delta` 만 바뀌면 body-only edit(imports/exports/name-set 불변) →
/// 위상 보존 + rename 재사용 가드 통과. caller 가 free.
///
/// `import * as NS` + `export const nsref = NS` → namespace 를 **escape** 시킨다(값으로 사용).
/// 이러면 lNs(populateNamespaceAccesses)가 binding 을 순회·escape 판정은 하되, member-access
/// (`NS.x`) 인라인 경로는 타지 않는다 — 그 인라인 경로가 병렬 emit double-free 버그(파일 상단
/// caveat)를 트리거하기 때문. member-access 를 쓰면 ~1/6 빈도로 flaky segfault. (실측: 8회 중
/// member-access=1 crash / escape-only=0 crash.)
fn consumerSource(allocator: std.mem.Allocator, j: usize, delta: usize) ![]u8 {
    const a = j % M_LEAVES;
    const b = (j + 1) % M_LEAVES;
    return std.fmt.allocPrint(
        allocator,
        "import {{ v{d}, v{d} }} from './barrel.js';\n" ++
            "import * as NS from './leaf{d}.js';\n" ++
            "export const nsref{d} = NS;\n" ++
            "export const c{d} = v{d} + v{d} + {d};\n",
        .{ a, b, j, j, j, a, b, delta },
    );
}

fn writeFixture(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    // leaf×M — 각 export 1개.
    for (0..M_LEAVES) |i| {
        var pbuf: [64]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "leaf{d}.js", .{i});
        var sbuf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&sbuf, "export const v{d} = {d};\n", .{ i, i });
        try writeFile(dir, p, s);
    }

    // barrel — leaf 전부 re-export (lExp/lReExp/lRes 체인).
    {
        var barrel: std.ArrayList(u8) = .empty;
        defer barrel.deinit(allocator);
        for (0..M_LEAVES) |i| {
            try barrel.print(allocator, "export {{ v{d} }} from './leaf{d}.js';\n", .{ i, i });
        }
        try writeFile(dir, "barrel.js", barrel.items);
    }

    // consumer×K — barrel named import(lRes 체인/lImp) + namespace escape(lNs binding 순회).
    for (0..K_CONSUMERS) |j| {
        const src = try consumerSource(allocator, j, 0);
        defer allocator.free(src);
        var pbuf: [64]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "consumer{d}.js", .{j});
        try writeFile(dir, p, src);
    }

    // entry — 모든 consumer 참조(elision 방지).
    {
        var entry: std.ArrayList(u8) = .empty;
        defer entry.deinit(allocator);
        for (0..K_CONSUMERS) |j| {
            try entry.print(allocator, "import {{ c{d} }} from './consumer{d}.js';\n", .{ j, j });
        }
        try entry.appendSlice(allocator, "let _sink = 0;\n");
        for (0..K_CONSUMERS) |j| {
            try entry.print(allocator, "_sink += c{d};\n", .{j});
        }
        try entry.appendSlice(allocator, "console.log(_sink);\n");
        try writeFile(dir, "entry.ts", entry.items);
    }
}

fn pct(part: u64, whole: u64) u64 {
    return if (whole == 0) 0 else part * 100 / whole;
}

fn printBreakdown(label: []const u8, bd: LinkBreakdown) void {
    // `other` = link 총합 − (5 sub-phase + computeRenames). chain_cache 스캔/renameReuseGuard
    // (G1 경량, #4173)/injectPreservedRenames/finalize glue 등 #4176 타깃 밖 잔여.
    // lRen(computeRenames)은 보존-hit 면 0(가드 통과 skip). >0 이면 reuse-hit 미발동 신호.
    const sum9 = bd.lexp_ns + bd.lres_ns + bd.lreexp_ns + bd.limp_ns + bd.lns_ns +
        bd.lren_ns + bd.lchain_ns + bd.lguard_ns + bd.linj_ns;
    const other_ns = bd.link_ns -| sum9;
    std.debug.print(
        \\  {s}: link={d:>5}us | lExp {d:>4}us {d:>2}% · lRes {d:>4}us {d:>2}% · lReExp {d:>4}us {d:>2}% · lImp {d:>4}us {d:>2}% · lNs {d:>4}us {d:>2}% · lRen {d:>5}us {d:>2}%
        \\         | lChain {d:>4}us {d:>2}% · lGuard {d:>5}us {d:>2}% · lInj {d:>5}us {d:>2}% · other {d:>5}us {d:>2}%
        \\
    , .{
        label,
        bd.link_ns / 1000,
        bd.lexp_ns / 1000,
        pct(bd.lexp_ns, bd.link_ns),
        bd.lres_ns / 1000,
        pct(bd.lres_ns, bd.link_ns),
        bd.lreexp_ns / 1000,
        pct(bd.lreexp_ns, bd.link_ns),
        bd.limp_ns / 1000,
        pct(bd.limp_ns, bd.link_ns),
        bd.lns_ns / 1000,
        pct(bd.lns_ns, bd.link_ns),
        bd.lren_ns / 1000,
        pct(bd.lren_ns, bd.link_ns),
        bd.lchain_ns / 1000,
        pct(bd.lchain_ns, bd.link_ns),
        bd.lguard_ns / 1000,
        pct(bd.lguard_ns, bd.link_ns),
        bd.linj_ns / 1000,
        pct(bd.linj_ns, bd.link_ns),
        other_ns / 1000,
        pct(other_ns, bd.link_ns),
    });
}

test "link sub-phase bench: dev HMR 보존-hit link 분해 (#4176)" {
    profile.resetForTest();
    // begin()/end() 의 timing 은 prof_io 가 set 돼야 동작(Io.Timestamp 필요). resetForTest 는
    // prof_io 를 안 건드리므로 명시 주입 — 단독 -Dtest-filter 실행에서도 측정되도록.
    profile.setIoForTest(std.testing.io);
    profile.addCategories(&.{
        "link",
        "link_build_export_map",
        "link_resolve_imports",
        "link_populate_re_export_aliases",
        "link_populate_import_symbols",
        "link_populate_namespace_accesses",
        "link_compute_renames",
        "link_chain_cache_scan",
        "link_rename_reuse_guard",
        "link_inject_renames",
    });
    defer profile.resetForTest();

    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFixture(allocator, tmp.dir);

    const entry = try absPath(&tmp, "entry.ts");
    defer allocator.free(entry);
    const consumer0 = try absPath(&tmp, "consumer0.js");
    defer allocator.free(consumer0);

    var ib = IncrementalBundler.init(allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    ib.enable_persistence = true; // buildIncrementalPreserved(보존-hit) 경로 활성 — production HMR 동형.
    defer ib.deinit();

    // cold build (full discovery + full link).
    var module_count: usize = 0;
    var cold: ?LinkBreakdown = null;
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| {
                defer BundleResult.ModuleDevCode.freeAll(s.changed_modules, allocator);
                module_count = s.paths.len;
                if (s.profile_snapshot) |snap| cold = LinkBreakdown.fromSnapshot(&snap);
            },
            .build_error => |e| {
                allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }

    var changed: std.StringHashMapUnmanaged(void) = .empty;
    defer changed.deinit(allocator);
    try changed.put(allocator, consumer0, {});

    // warmup discard(dir-fd / inode cache 워밍).
    {
        const src = try consumerSource(allocator, 0, 1);
        defer allocator.free(src);
        try writeFile(tmp.dir, "consumer0.js", src);
        const r = try ib.rebuildWithChanges(std.testing.io, &changed);
        switch (r) {
            .success => |s| BundleResult.ModuleDevCode.freeAll(s.changed_modules, allocator),
            .build_error => |e| {
                allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }

    // 보존-hit warm rebuild ×WARM_ITERS — body-only edit, link sub-phase 측정.
    var warm_min: ?LinkBreakdown = null;
    for (0..WARM_ITERS) |iter| {
        const src = try consumerSource(allocator, 0, iter + 2);
        defer allocator.free(src);
        try writeFile(tmp.dir, "consumer0.js", src);
        const r = try ib.rebuildWithChanges(std.testing.io, &changed);
        switch (r) {
            .success => |s| {
                defer BundleResult.ModuleDevCode.freeAll(s.changed_modules, allocator);
                // 위상 불변(보존-hit)이어야 link sub-phase 측정이 이슈 타깃 경로다.
                try std.testing.expectEqual(false, s.graph_changed);
                // body-only edit 가 실제로 반영됐는지(= changed_files 키가 graph 모듈 경로와
                // 매칭) 검증. 미스매치면 reparse 가 silent no-op 이 돼 "0-변경 보존-hit" 를
                // 측정하게 되는데(graph_changed 는 그래도 false) 이건 이슈가 노린 "1-모듈
                // 변경" 경로가 아니다.
                try std.testing.expect(s.changed_modules.len > 0);
                if (s.profile_snapshot) |snap| {
                    const bd = LinkBreakdown.fromSnapshot(&snap);
                    warm_min = if (warm_min) |w| w.minWith(bd) else bd;
                }
            },
            .build_error => |e| {
                allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }

    // 측정 self-validation: profiling 이 silent 비활성(prof_io 미주입/카테고리 미등록 회귀)
    // 이면 snapshot=null → warm_min=null 로 *아무것도 측정 못 한 채* 통과해버린다. 그걸
    // 회귀로 잡도록 link 총합이 실제 기록됐는지 단언한다.
    try std.testing.expect(warm_min != null);
    try std.testing.expect(warm_min.?.link_ns > 0);

    std.debug.print(
        \\
        \\[link-subphase-bench #4176] {d} modules (M={d} leaves + barrel + K={d} consumers), dev HMR:
        \\
    , .{ module_count, M_LEAVES, K_CONSUMERS });
    if (cold) |c| printBreakdown("cold ", c);
    if (warm_min) |w| printBreakdown("warm*", w);
    std.debug.print(
        \\  (warm* = {d} 보존-hit rebuild per-field 최소값. 절대값은 fixture 규모 비례 — 상대 분포가 신호.
        \\   8092 실측: `ZNTC_PROFILE=all zntc --serve` → bundle_build_done.profile 의 link_*_ms.)
        \\
    , .{WARM_ITERS});
}
