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

    var info: PkgInfo = .{ .is_module = false, .side_effects = .unknown };
    if (pkg_json.parsePackageJson(self.allocator, io, pkg_dir_path)) |parsed_val| {
        var parsed = parsed_val;
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
        return .{ .is_module = info.is_module, .side_effects = .unknown };
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

/// 모듈 경로에서 가장 가까운 package.json의 "type" 필드가 "module"인지 확인.
/// `lookupPkgInfo` 로 캐시 경유 — 같은 pkg 의 side_effects 조회와 pkg.json parse 공유.
pub fn isPackageTypeModule(self: *ModuleGraph, io: std.Io, module_path: []const u8) bool {
    var scope = profile.begin(.graph_discover_pm_is_pkg_type);
    defer scope.end();
    const pkg_dir_path = findPackageDirPath(module_path) orelse return false;
    return self.lookupPkgInfo(io, pkg_dir_path).is_module;
}
