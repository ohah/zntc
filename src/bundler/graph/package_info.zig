//! Package metadata cache helpers for ModuleGraph.

const std = @import("std");

const Module = @import("../module.zig").Module;
const pkg_json = @import("../package_json.zig");
const types = @import("../types.zig");
const resolve_cache_mod = @import("../resolve_cache.zig");
const profile = @import("../../profile.zig");
const graph_package_side_effects = @import("package_side_effects.zig");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const PkgInfo = ModuleGraph.PkgInfo;
const findPackageDirPath = resolve_cache_mod.findPackageDirPath;

/// `pkg_info_cache` 통합 lookup. pkg_dir_path 별 1회만 parsePackageJson,
/// 이후 호출은 cache hit. is_module 과 side_effects 모두 반환 (#1744).
///
/// Fast path (lock→get→unlock) → Slow path (lock 밖 parse) →
/// double-check put (race 시 내 값 폐기). patterns 메모리 소유권은
/// 캐시가 보유하며 Linker deinit 에서 일괄 해제.
pub fn lookupPkgInfo(self: *ModuleGraph, io: std.Io, pkg_dir_path: []const u8) PkgInfo {
    self.pkg_info_cache_mutex.lock();
    const cached = self.pkg_info_cache.get(pkg_dir_path);
    self.pkg_info_cache_mutex.unlock();
    if (cached) |c| return c;

    var info: PkgInfo = .{ .is_module = false, .side_effects = .unknown, .found = false };
    if (pkg_json.parsePackageJson(self.allocator, io, pkg_dir_path)) |parsed_val| {
        var parsed = parsed_val;
        info.found = true;
        info.is_module = parsed.pkg.isModule();
        info.side_effects = parsed.pkg.side_effects;
        // 소유권을 info 로 이전 — parsed.deinit() 에서 이중 free 방지.
        parsed.pkg.side_effects = .unknown;
        parsed.deinit();
    } else |err| {
        // ⚠️ **파일이 있었는지**와 **읽어낼 수 있었는지**는 다른 질문이다. 깨진 JSON 이나
        // 읽기 실패도 package.json 은 거기 있는 것이므로 `found` 다 — 형식 판정은 그 자리에서
        // 끝나야 한다. 이걸 "없음" 으로 치면 위로 계속 올라가 **상위의 `"type":"module"` 을
        // 잘못 집는다**(깨진 하위 package.json 이 상위 설정에 가려짐).
        info.found = err != error.FileNotFound;
    }

    self.pkg_info_cache_mutex.lock();
    defer self.pkg_info_cache_mutex.unlock();
    // Race: 다른 스레드가 먼저 put 했으면 내 info.side_effects 폐기.
    if (self.pkg_info_cache.get(pkg_dir_path)) |raced| {
        info.side_effects.deinit(self.allocator);
        return raced;
    }
    self.pkg_info_cache.put(self.allocator, pkg_dir_path, info) catch {
        // alloc 실패 시 누수 방지
        info.side_effects.deinit(self.allocator);
        return .{ .is_module = info.is_module, .side_effects = .unknown, .found = info.found };
    };
    return info;
}

/// node_modules 패키지의 package.json sideEffects 필드를 module.side_effects에 반영.
pub fn applySideEffectsFromPackageJson(self: *ModuleGraph, io: std.Io, module: *Module) void {
    if (self.ignore_annotations) return;
    const pkg_dir_path = findPackageDirPath(module.path) orelse return;
    const info = self.lookupPkgInfo(io, pkg_dir_path);
    graph_package_side_effects.applyCached(module, pkg_dir_path, info.side_effects);
}

/// 모듈 경로에서 **가장 가까운** package.json 의 `"type"` 필드가 `"module"` 인지.
///
/// Node 규칙: 파일에서 위로 올라가다 처음 만난 package.json 이 판정을 끝낸다. `"type"` 이
/// 없으면 그 자리에서 CJS 로 확정하고 더 올라가지 않는다 — 상위의 `"type":"module"` 이
/// 하위 디렉토리를 덮지 않는다.
///
/// 예전엔 `findPackageDirPath`(경로에 `node_modules/` 가 있어야 동작) 하나만 써서
/// **사용자 프로젝트 코드에는 아예 적용되지 않았다**. 그래서 `"type":"module"` 앱의 `.js`
/// 가 CJS default import 에서 Babel interop 을 받아, Node·esbuild 와 결과가 갈렸다.
///
/// node_modules 안은 기존 경로를 그대로 쓴다 — 패키지 루트를 문자열로 바로 잘라내므로
/// 디렉토리를 되짚어 올라가는 것보다 싸고, 패키지 내부에 중첩 package.json 이 있어도
/// 루트가 정답인 경우가 대부분이다.
pub fn isPackageTypeModule(self: *ModuleGraph, io: std.Io, module_path: []const u8) bool {
    var scope = profile.begin(.graph_discover_pm_is_pkg_type);
    defer scope.end();
    if (findPackageDirPath(module_path)) |pkg_dir_path| {
        return self.lookupPkgInfo(io, pkg_dir_path).is_module;
    }
    return nearestPackageTypeIsModule(self, io, module_path);
}

/// node_modules 밖에서 가장 가까운 package.json 을 위로 찾아 `"type"` 을 본다.
/// **처음 만난 package.json 에서 멈춘다** — 있으면 그 답이 최종이다(Node 규칙).
fn nearestPackageTypeIsModule(self: *ModuleGraph, io: std.Io, module_path: []const u8) bool {
    // 경로 깊이 상한 — 심볼릭 루프나 비정상 경로에서 무한 순회 방지.
    const max_hops = 64;
    var dir_opt = std.fs.path.dirname(module_path);
    var hops: usize = 0;
    while (dir_opt) |dir| : (hops += 1) {
        if (hops >= max_hops) return false;
        // `lookupPkgInfo` 경유 — 같은 디렉토리의 형제 파일들이 캐시를 공유한다.
        // 직접 parse 하면 모듈 수 × 깊이만큼 같은 파일을 다시 읽는다.
        const info = self.lookupPkgInfo(io, dir);
        if (info.found) return info.is_module;
        const parent = std.fs.path.dirname(dir) orelse return false;
        // 루트(`/`)에서 dirname 이 자기 자신을 돌려주면 전진이 멈춘다 — 그때 종료.
        if (std.mem.eql(u8, parent, dir)) return false;
        dir_opt = parent;
    }
    return false;
}

/// 모듈의 `def_format` 을 파일 확장자 + package.json 에서 파생한다.
///
/// **파싱 시점과 warm 재빌드에서 같은 함수를 써야 한다.** 증분 빌드는 소스가 안 바뀐 모듈을
/// 다시 파싱하지 않는데, `def_format` 의 입력은 소스가 아니라 **파일시스템 상태**
/// (확장자 · package.json 의 `"type"` · `"module"` 필드 해석 여부)다. 그래서 파싱을 건너뛴
/// 모듈도 매 빌드 다시 구해야 한다 — 안 그러면 `"type"` 을 바꿔도 출력이 옛 값으로 굳는다.
pub fn deriveDefFormat(self: *ModuleGraph, io: std.Io, module: *const Module) types.ModuleDefFormat {
    const ext = std.fs.path.extension(module.diskPath());
    if (std.mem.eql(u8, ext, ".mjs")) return .esm_mjs;
    if (std.mem.eql(u8, ext, ".mts")) return .esm_mts;
    if (std.mem.eql(u8, ext, ".cjs")) return .cjs;
    if (std.mem.eql(u8, ext, ".cts")) return .cts;
    if (isPackageTypeModule(self, io, module.path)) return .esm_package_json;
    // `"module"` 필드 해석분은 ESM 으로 파싱하되 Node interop 은 적용하지 않는다 (#4659).
    // `"type":"module"` 검사를 **먼저** 해야 둘 다 해당하는 패키지가 node 로 남는다.
    if (module.is_module_field) return .esm_module_field;
    return .unknown;
}

/// warm 재빌드에서 **파싱을 건너뛴 모듈들**의 `def_format` 을 다시 구한다.
/// package.json 의 `"type"` 이 바뀌면 소스가 그대로여도 interop 이 달라져야 한다 (#4665).
/// 조회는 `pkg_info_cache` 를 타므로 디렉토리당 1회 — 모듈 수에 비례한 해시 조회뿐이다.
pub fn refreshDefFormats(
    self: *ModuleGraph,
    io: std.Io,
    /// 이번 빌드에서 **다시 파싱된** 모듈들. 이들은 `parser_setup` 이 방금 `def_format` 을
    /// 채웠으므로 건너뛴다 — cold 빌드(전부 재파싱)에서는 이 함수가 사실상 무비용이다.
    reparsed: []const types.ModuleIndex,
) void {
    const count = self.modules.count();
    if (count == 0) return;
    // 재파싱 집합이 전체면 할 일이 없다.
    if (reparsed.len >= count) return;

    var skip = std.DynamicBitSetUnmanaged.initEmpty(self.allocator, count) catch return;
    defer skip.deinit(self.allocator);
    for (reparsed) |idx| {
        const i = @intFromEnum(idx);
        if (i < count) skip.set(i);
    }

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (skip.isSet(i)) continue;
        const m = self.moduleAtMut(@enumFromInt(i)) orelse continue;
        m.def_format = deriveDefFormat(self, io, m);
    }
}
