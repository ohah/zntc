//! Module Federation 연합 경계 식별 (#3318 P1-1).
//!
//! `mf.exposes` 타겟 ∪ `mf.shared` 패키지 ∪ shared 전방-의존 폐포를
//! **연합 경계 모듈**로 표시(`Module.is_federation_boundary`)하고 안정
//! ID(`module_id.zig`, relative-path)를 부여한다.
//!
//! **P1-1 은 분석·표시만** — 스코프 호이스팅 소거 제외 *enforcement*·
//! container/manifest emit 은 P1-2+ 가 이 플래그/ID 를 소비. wrap_kind·
//! entry_points·출력 불변(비-MF 빌드 영향 0 — caller 가 mf!=null 일 때만 호출).
//!
//! 위험 격리: 기존 스코프호이스팅/링커 결정 코드 미변경. graph build 직후
//! ~ link 전 단일스레드 분석 패스(다른 build 패스와 동일 위치·동시성 모델).

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const module_id = @import("module_id.zig");
const resolve_cache = @import("resolve_cache.zig");

/// PR-2 (#3459): 링킹 중 발견된 **정적** `import … from "remote/x"`
/// specifier 집합(삽입순·중복제거). 정적 import 구문은 codegen 이
/// elide(PR-1)하므로 emitHostInit 가 출력만으로 어떤 remote 를
/// 정적-import 했는지 복원 불가(sanitize lossy) → metadata.zig 가
/// 여기 수집, bundler 가 emitHostInit 에 전달해 async preload-gate
/// emit. bundler 소유(`mangle_report` 선례 — Linker 는 `?*` 참조만,
/// const-self 라도 pointee 변경). 키는 dupe(import_records 수명 무관
/// — link 후 emit 까지 생존).
pub const MfStaticRemotes = struct {
    specs: std.StringArrayHashMapUnmanaged(void) = .empty,

    pub fn add(self: *MfStaticRemotes, allocator: std.mem.Allocator, spec: []const u8) !void {
        if (self.specs.contains(spec)) return;
        try self.specs.put(allocator, try allocator.dupe(u8, spec), {});
    }

    pub fn keys(self: *const MfStaticRemotes) []const []const u8 {
        return self.specs.keys();
    }

    pub fn deinit(self: *MfStaticRemotes, allocator: std.mem.Allocator) void {
        for (self.specs.keys()) |k| allocator.free(k);
        self.specs.deinit(allocator);
    }
};

/// P1-6 host: 스펙 런타임 패키지(자체 재구현 금지=D1) 및 그 글로벌 seam.
/// **단일 소스** — mf_options.seamGlobals/번들러 ④ 가 external+글로벌로
/// 걸고 emitHostInit(federation_emit.zig)이 그 글로벌로 init/loadRemote
/// 배선. 두 곳이 반드시 일치해야 동작(mfSharedGlobalName 단일소스 선례).
pub const MF_RUNTIME_PKG = "@module-federation/runtime";
pub const MF_RUNTIME_GLOBAL = "__mf_runtime";

/// specifier 가 원격(`<key>` 정확 또는 `<key>/...` sub-path)인가.
/// resolve_cache.matchPackageSubPath 재사용 — host 치환 판정과 런타임
/// external 판정이 **동일 규칙**(분기 시 `react/*` 류 key 에서 불일치).
pub fn matchesRemoteSpec(spec: []const u8, key: []const u8) bool {
    return std.mem.eql(u8, spec, key) or resolve_cache.matchPackageSubPath(key, spec);
}

/// cwd 절대경로(realpath). **WASI 는 realpath 미지원** — `std.fs.cwd().
/// realpathAlloc` 는 wasm32-wasi 에서 `@compileError`(runtime catch 무관,
/// 참조 자체가 컴파일 실패). comptime os 분기로 비-WASI 만 realpath, WASI
/// 는 null(MF 는 web/native 기능 — wasm-bundler 경로 매칭은 비정규화
/// fallback 으로 충분). 비-WASI 동작 불변.
pub fn cwdRealpath(io: std.Io, allocator: std.mem.Allocator) ?[]const u8 {
    if (comptime builtin.os.tag == .wasi) return null;
    // 0.16: realPathFileAlloc 는 [:0]u8 (N 바이트). []const u8 로 coerce 후 free 하면
    // N-1 만 해제돼 size-mismatch → sentinel-aware free 후 정확 길이 dupe.
    const z = std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator) catch return null;
    defer allocator.free(z);
    return allocator.dupe(u8, z) catch null;
}

/// 패키지명 → container 소유 글로벌 식별자(`__mf_shared_<sanitized>`).
/// 단사·결정적 — P1-2 가 shared seam(`--globals` 글로벌-파라미터)에, P1-4
/// container.init 이 host shareScope 해석값을 이 글로벌에 대입. 두 곳이
/// **같은 규칙**이어야 하므로 federation.zig 가 단일 authoritative 소스
/// (cli/options.zig P1-2 도 이걸 호출). 비식별자(`@/-.`)→`_`, 소문자/scope
/// 보존(react→__mf_shared_react, @scope/pkg→__mf_shared__scope_pkg).
pub fn mfSharedGlobalName(allocator: std.mem.Allocator, pkg: []const u8) ![]const u8 {
    return mfSeamName(allocator, "__mf_shared_", pkg);
}

/// specifier → host 정적 import seam 글로벌(`__mf_remote_<sanitized>`).
/// PR-1(#3459): 정적 `import X from "remoteA/Widget"` 의 binding 을 이
/// 글로벌 참조로 재작성(metadata.zig IIFE mapped 경로 재사용 → 에러
/// 회피). per-spec(subpath 포함) 단위 — `remoteA/Widget`·`remoteA/Btn`
/// 가 서로 다른 글로벌. PR-2 의 async preload-gate 가 `loadRemote` 결과로
/// 채움. sanitize 규칙은 mfSharedGlobalName 과 **단일 소스**(mfSeamName).
pub fn mfRemoteGlobalName(allocator: std.mem.Allocator, spec: []const u8) ![]const u8 {
    return mfSeamName(allocator, "__mf_remote_", spec);
}

/// `<prefix><sanitized name>` — 비식별자(`@/-.`)→`_`, 그 외 보존.
/// mfShared/mfRemote 글로벌명 단일 sanitize 규칙(두 seam 일관 필수).
fn mfSeamName(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, prefix.len + name.len);
    @memcpy(buf[0..prefix.len], prefix);
    for (name, 0..) |c, i| buf[prefix.len + i] = switch (c) {
        '@', '/', '-', '.' => '_',
        else => c,
    };
    return buf;
}

test "mfSharedGlobalName: 결정적 식별자 변환" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "react", .want = "__mf_shared_react" },
        .{ .in = "react-dom", .want = "__mf_shared_react_dom" },
        .{ .in = "@scope/pkg", .want = "__mf_shared__scope_pkg" },
        .{ .in = "lodash.merge", .want = "__mf_shared_lodash_merge" },
    };
    for (cases) |c| {
        const got = try mfSharedGlobalName(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "mfRemoteGlobalName: per-spec 결정적 변환(subpath 포함, shared 와 sanitize 일관)" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "remoteA", .want = "__mf_remote_remoteA" },
        .{ .in = "remoteA/Widget", .want = "__mf_remote_remoteA_Widget" },
        .{ .in = "remoteA/Btn", .want = "__mf_remote_remoteA_Btn" }, // subpath 별 구분
        .{ .in = "@scope/app/X", .want = "__mf_remote__scope_app_X" },
    };
    for (cases) |c| {
        const got = try mfRemoteGlobalName(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
    // shared 와 동일 sanitize 규칙(prefix 만 차이) — 단일소스 mfSeamName 보장
    const r = try mfRemoteGlobalName(a, "react-dom");
    defer a.free(r);
    try std.testing.expectEqualStrings("__mf_remote_react_dom", r);
}

/// 경계 식별 + 표시 + 안정 ID 부여. `mf` 비면 호출 안 됨(caller gate).
/// `entry_points`/`preserve_root` 는 `module_id` root 도출용.
pub fn markBoundary(
    io: std.Io,
    graph: anytype,
    mf: *const types.MfBundleConfig,
    allocator: std.mem.Allocator,
    entry_points: []const []const u8,
    preserve_root: ?[]const u8,
) !void {
    const count = graph.moduleCount();
    if (count == 0) return;

    // module_id root: preserve-modules-root ?? entry 공통 조상 (P3-B 와 동일).
    const root: ?[]const u8 = if (preserve_root) |r|
        r
    else
        module_id.commonAncestorDir(allocator, entry_points) catch null;
    defer if (preserve_root == null) if (root) |r| allocator.free(r);

    // ── exposes: config 값(cwd 상대 가능)을 abs 로 정규화해 모듈과 매칭 ──
    const cwd = cwdRealpath(io, allocator);
    defer if (cwd) |c| allocator.free(c);
    for (mf.exposes) |kv| {
        const abs = resolveAbs(io, allocator, cwd, kv.value) catch continue;
        defer allocator.free(abs);
        var matched = false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(i)));
            // moduleAtMut 직접 호출: 이 패스는 graph build 完~link 前 단일
            // 스레드(파서 워커 race 무관) — bundler.zig store-transfer 와 동일
            // 관례(accessors.zig 금지 주석은 병렬 워커 한정).
            const m = graph.moduleAtMut(idx) orelse continue;
            if (std.mem.eql(u8, m.path, abs)) {
                try setBoundary(allocator, m, root);
                m.is_federation_expose = true; // P1-3: expose→자기 lazy 청크
                matched = true;
                break;
            }
        }
        // 미해결 expose 는 P1-2+ enforcement 가 잘못된 결과를 내므로 조용히
        // 넘기지 말고 진단(분석단계라 빌드 실패는 과함 — RBM/entry 와 동일 warn).
        if (!matched)
            std.log.warn("[mf] expose target not in module graph: {s} ({s})", .{ kv.key, kv.value });
    }

    // ── shared: `/node_modules/<pkg>/` 매칭 시드 → 전방-의존 폐포 DFS ──
    if (mf.shared.len > 0) {
        var seeds: std.ArrayListUnmanaged(ModuleIndex) = .empty;
        defer seeds.deinit(allocator);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(i)));
            const m = graph.getModule(idx) orelse continue;
            if (pkgOf(m.path)) |pkg| {
                for (mf.shared) |s| {
                    if (std.mem.eql(u8, s.name, pkg)) {
                        try seeds.append(allocator, idx);
                        break;
                    }
                }
            }
        }
        try markClosure(graph, allocator, root, seeds.items);
    }
}

/// 시드들의 전방-의존 폐포를 표시. **명시적 스택**(재귀 아님) — 깊은
/// 모듈 체인 stack overflow 회피(`graph/cycles.zig` 와 동일 규율). visited
/// 로 각 모듈 1회 — O(V+E), 메모리 O(V).
fn markClosure(
    graph: anytype,
    allocator: std.mem.Allocator,
    root: ?[]const u8,
    seeds: []const ModuleIndex,
) !void {
    var visited = std.AutoHashMapUnmanaged(u32, void){};
    defer visited.deinit(allocator);
    var stack: std.ArrayListUnmanaged(ModuleIndex) = .empty;
    defer stack.deinit(allocator);
    try stack.appendSlice(allocator, seeds);
    while (stack.pop()) |idx| {
        const gop = try visited.getOrPut(allocator, @intFromEnum(idx));
        if (gop.found_existing) continue;
        const m = graph.moduleAtMut(idx) orelse continue;
        try setBoundary(allocator, m, root);
        try stack.appendSlice(allocator, m.dependencies.items);
    }
}

fn setBoundary(allocator: std.mem.Allocator, m: anytype, root: ?[]const u8) !void {
    if (m.is_federation_boundary) return; // 멱등 — id 재할당·중복 free 방지
    m.is_federation_boundary = true;
    m.federation_id = try module_id.moduleId(allocator, m.path, root);
}

/// specifier 가 패키지 `pkg` 또는 그 subpath(`pkg/...`)인가.
fn pkgMatch(spec: []const u8, pkg: []const u8) bool {
    return std.mem.eql(u8, spec, pkg) or
        (spec.len > pkg.len and std.mem.startsWith(u8, spec, pkg) and spec[pkg.len] == '/');
}

/// (import 패키지, import 심볼명) 이 host-owned **store/Provider 생성**
/// API 인가 → 사람이 읽는 라벨, 아니면 null. **정밀 휴리스틱**: store
/// *생성* 팩토리 심볼만 매칭 — `createSlice`/`useSelector`/`atom`/
/// `useStore`(주입·소비 = GOOD 패턴)는 비매칭(낮은 false-positive).
/// AST 미보존이라 호출 여부는 못 봄 → 심볼 import 자체를 신호로 사용
/// (그 심볼을 import 하면 호출 의도). RFC §3.2(host 단일 store, remote
/// 는 주입) · §7.3 ②(휴리스틱, FP 가능 — 경고는 "확인 권고").
/// **알려진 한계**(false-negative, RFC §7.3 ② 완전 데이터플로 비-목표):
/// namespace import(`import * as RTK; RTK.configureStore()` → imported_
/// name="*") · 재export 경유는 미탐지. 직접 명명 import 만 신호.
fn prohibitedStoreFactory(specifier: []const u8, name: []const u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (pkgMatch(specifier, "@reduxjs/toolkit")) {
        if (eq(u8, name, "configureStore")) return "Redux configureStore";
    } else if (pkgMatch(specifier, "redux")) {
        if (eq(u8, name, "createStore") or eq(u8, name, "legacy_createStore")) return "Redux createStore";
    } else if (pkgMatch(specifier, "zustand")) {
        // zustand: named {create,createStore} 또는 default export(=create).
        if (eq(u8, name, "create") or eq(u8, name, "createStore") or eq(u8, name, "default"))
            return "Zustand store";
    } else if (pkgMatch(specifier, "jotai")) {
        if (eq(u8, name, "createStore")) return "Jotai createStore";
    } else if (pkgMatch(specifier, "react-redux")) {
        if (eq(u8, name, "Provider")) return "react-redux Provider";
    }
    return null;
}

/// P3-4 (#3439): 소유권 경계 린트. 연합 경계 모듈(exposes ∪ shared
/// 폐포)이 host-owned store/Provider 생성 심볼을 import 하면 **비-차단
/// 빌드 경고**(std.log.warn — P3-2 선례, 빌드 실패 아님 · #3336
/// non-literal dynamic import 진단 선례 미러: 탐지→비-차단 경고).
/// markBoundary 직후 호출(경계 플래그 설정 완료 — 동일 단일소스 순회,
/// emit/검증 부작용 0). 휴리스틱이라 false-positive 가능(RFC §7.3 ②) —
/// 메시지가 "의도된 격리면 무시"를 명시. 경고는 절대 빌드를 막지 않음.
pub fn lintOwnershipBoundary(graph: anytype) void {
    const count = graph.moduleCount();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(i)));
        const m = graph.getModule(idx) orelse continue;
        if (!m.is_federation_boundary) continue;
        for (m.import_bindings) |ib| {
            if (ib.import_record_index >= m.import_records.len) continue;
            const spec = m.import_records[ib.import_record_index].specifier;
            const label = prohibitedStoreFactory(spec, ib.imported_name) orelse continue;
            std.log.warn(
                "[mf] 소유권 경계 — 연합 경계 모듈 '{s}' 이 host-owned {s} 을(를) 자체 생성(import '{s}' from '{s}'). remote 는 host store 에 slice/reducer 를 주입하세요(RFC §3.2). 비-차단 — 의도된 격리면 무시.",
                .{ m.federation_id orelse m.path, label, ib.imported_name, spec },
            );
        }
    }
}

test "prohibitedStoreFactory: store-생성 심볼만 매칭(주입·소비는 비매칭)" {
    // 매칭(자체 store/Provider 생성 정황)
    try std.testing.expect(prohibitedStoreFactory("@reduxjs/toolkit", "configureStore") != null);
    try std.testing.expect(prohibitedStoreFactory("redux", "createStore") != null);
    try std.testing.expect(prohibitedStoreFactory("zustand", "create") != null);
    try std.testing.expect(prohibitedStoreFactory("zustand/vanilla", "createStore") != null); // subpath
    try std.testing.expect(prohibitedStoreFactory("zustand", "default") != null); // default=create
    try std.testing.expect(prohibitedStoreFactory("jotai", "createStore") != null);
    try std.testing.expect(prohibitedStoreFactory("react-redux", "Provider") != null);
    // 비매칭 — 주입·소비(GOOD 패턴) → false-positive 회피
    try std.testing.expect(prohibitedStoreFactory("@reduxjs/toolkit", "createSlice") == null);
    try std.testing.expect(prohibitedStoreFactory("react-redux", "useSelector") == null);
    try std.testing.expect(prohibitedStoreFactory("react-redux", "useDispatch") == null);
    try std.testing.expect(prohibitedStoreFactory("jotai", "atom") == null);
    try std.testing.expect(prohibitedStoreFactory("zustand", "useStore") == null);
    try std.testing.expect(prohibitedStoreFactory("react", "useState") == null); // 무관 패키지
    try std.testing.expect(prohibitedStoreFactory("jotai", "createStoreX") == null); // 부분일치 아님
}

/// graph.build 루트 = user entry ∪ exposes. P1-3: exposes 는 user entry
/// 에서 도달 안 될 수 있는 **독립 루트**(webpack 동일) — 그래프에 없으면
/// markBoundary 가 매칭 실패. 반환 slice 의 모든 원소 allocator-dup(소유
/// 명확) → `freeStrList` 로 해제. chunk gen 의 entry_points 는 불변(exposes
/// 는 is_federation_expose → 동적 lazy 청크, user-entry 아님).
pub fn entryWithExposes(
    io: std.Io,
    allocator: std.mem.Allocator,
    mf: *const types.MfBundleConfig,
    entries: []const []const u8,
) ![][]const u8 {
    const cwd = cwdRealpath(io, allocator);
    defer if (cwd) |c| allocator.free(c);
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    for (entries) |e| try list.append(allocator, try allocator.dupe(u8, e));
    for (mf.exposes) |kv| {
        const abs = resolveAbs(io, allocator, cwd, kv.value) catch continue;
        var seen = false;
        for (list.items) |s| {
            if (std.mem.eql(u8, s, abs)) {
                seen = true;
                break;
            }
        }
        if (seen) {
            allocator.free(abs);
            continue;
        }
        try list.append(allocator, abs);
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeStrList(allocator: std.mem.Allocator, list: [][]const u8) void {
    for (list) |s| allocator.free(s);
    allocator.free(list);
}

/// cwd(또는 null) 기준 상대경로를 abs 로. realpath 실패 시 resolve 결과 사용.
pub fn resolveAbs(io: std.Io, allocator: std.mem.Allocator, cwd: ?[]const u8, value: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    const base = cwd orelse ".";
    const joined = try std.fs.path.resolve(allocator, &.{ base, value });
    defer allocator.free(joined);
    // WASI 는 realpath @compileError → comptime 분기(비-WASI 동작 불변).
    if (comptime builtin.os.tag == .wasi) return allocator.dupe(u8, joined);
    // 0.16: realPathFileAlloc 는 [:0]u8 → sentinel-aware free 후 정확 길이 dupe
    // (caller 가 []const u8 로 해제 시 size-mismatch 방지).
    const z = std.Io.Dir.cwd().realPathFileAlloc(io, joined, allocator) catch return allocator.dupe(u8, joined);
    defer allocator.free(z);
    return allocator.dupe(u8, z);
}

/// path 의 최내곽 node_modules 패키지명(`@scope/pkg` 포함). scoped 분기·
/// OS sep 처리는 `resolve_cache.findPackageDirPath`(단일 소스) 재사용 —
/// 그것이 주는 패키지 *디렉터리* path 에서 이름 부분만 슬라이스.
fn pkgOf(path: []const u8) ?[]const u8 {
    const dir = resolve_cache.findPackageDirPath(path) orelse return null;
    const nm = "node_modules" ++ std.fs.path.sep_str;
    const at = std.mem.lastIndexOf(u8, dir, nm) orelse return null;
    return dir[at + nm.len ..];
}

test "markBoundary: shared 시드 + 전방-의존 폐포 표시, 무관 모듈 미표시" {
    const a = std.testing.allocator;
    const StubMod = struct {
        path: []const u8,
        dependencies: std.ArrayList(ModuleIndex) = .empty,
        is_federation_boundary: bool = false,
        federation_id: ?[]const u8 = null,
        is_federation_expose: bool = false, // P1-3 — Module 미러
    };
    // 0=app(entry, 비경계) 1=node_modules/react/index.js(shared seed)
    // 2=node_modules/react/jsx.js(react 전방-의존, 폐포로 표시돼야)
    var mods = [_]StubMod{
        .{ .path = "/p/src/app.ts" },
        .{ .path = "/p/node_modules/react/index.js" },
        .{ .path = "/p/node_modules/react/jsx.js" },
    };
    try mods[1].dependencies.append(a, @enumFromInt(2)); // react → jsx
    defer for (&mods) |*m| {
        m.dependencies.deinit(a);
        if (m.federation_id) |id| a.free(id);
    };
    const StubGraph = struct {
        ms: []StubMod,
        fn moduleCount(self: @This()) usize {
            return self.ms.len;
        }
        fn getModule(self: @This(), idx: ModuleIndex) ?*const StubMod {
            return &self.ms[@intFromEnum(idx)];
        }
        fn moduleAtMut(self: @This(), idx: ModuleIndex) ?*StubMod {
            return &self.ms[@intFromEnum(idx)];
        }
    };
    var g = StubGraph{ .ms = &mods };
    const mf = types.MfBundleConfig{ .name = "app", .shared = &.{.{ .name = "react" }} };
    try markBoundary(std.testing.io, &g, &mf, a, &.{"/p/src/app.ts"}, "/p");

    try std.testing.expect(!mods[0].is_federation_boundary); // app 비경계
    try std.testing.expect(mods[1].is_federation_boundary); // react seed
    try std.testing.expect(mods[2].is_federation_boundary); // 전방-의존 폐포
    try std.testing.expectEqualStrings("node_modules/react/index.js", mods[1].federation_id.?);
    try std.testing.expect(mods[0].federation_id == null);
}

test "pkgOf: scoped/일반 패키지 추출" {
    try std.testing.expectEqualStrings("react", pkgOf("/p/node_modules/react/index.js").?);
    try std.testing.expectEqualStrings(
        "@scope/pkg",
        pkgOf("/p/node_modules/@scope/pkg/dist/x.js").?,
    );
    try std.testing.expect(pkgOf("/p/src/app.ts") == null);
    // 중첩 node_modules → 가장 안쪽 패키지
    try std.testing.expectEqualStrings(
        "b",
        pkgOf("/p/node_modules/a/node_modules/b/i.js").?,
    );
}
