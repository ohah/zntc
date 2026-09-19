//! Package metadata cache helpers for ModuleGraph.

const std = @import("std");

const Module = @import("../module.zig").Module;
const pkg_json = @import("../package_json.zig");
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
    } else |_| {}

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
