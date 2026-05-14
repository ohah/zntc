//! Module registration and dependency-link helpers for ModuleGraph.

const std = @import("std");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const module_mod = @import("../module.zig");
const Module = module_mod.Module;
const plugin_mod = @import("../plugin.zig");
const graph_parse_helpers = @import("parse_helpers.zig");
const moduleTypeForLoader = graph_parse_helpers.moduleTypeForLoader;

/// 확장자에 대한 로더를 결정한다.
/// --loader 오버라이드가 있으면 우선 사용, 없으면 확장자 기본값.
pub fn resolveLoader(self: *const ModuleGraph, ext: []const u8) types.ParsedLoader {
    for (self.loader_overrides) |override| {
        if (std.mem.eql(u8, override.ext, ext)) {
            return .{ .loader = override.loader, .module_type = override.module_type };
        }
    }
    return types.ParsedLoader.fromExtension(ext);
}

/// vue/svelte SFC 의 sub-import (예: `App.vue?vue&type=style&lang.css`) 처럼
/// query/fragment 가 붙은 가상 specifier 에서 loader 결정용 확장자를 추출한다.
/// `?` 위치를 한 번만 scan 해 두 검사를 모두 처리 — query 가 없는 일반 경로
/// (대부분) 에서도 hot path 비용을 한 번으로 묶는다. (#3022)
///
/// 1. query 의 마지막 토큰이 `lang.X` 형식이면 그 `.X` 를 반환 — vite SFC 관례.
/// 2. 아니면 query/fragment 제거한 base path 의 표준 extension 을 반환.
fn loaderExtensionFor(abs_path: []const u8) []const u8 {
    const q_opt = std.mem.indexOfScalar(u8, abs_path, '?');
    const h_opt = std.mem.indexOfScalar(u8, abs_path, '#');

    if (q_opt) |q| {
        const query_end = if (h_opt) |h| @min(h, abs_path.len) else abs_path.len;
        const query = abs_path[q + 1 .. query_end];
        var it = std.mem.tokenizeScalar(u8, query, '&');
        while (it.next()) |token| {
            if (std.mem.startsWith(u8, token, "lang.")) {
                return token[4..]; // ".X" — leading dot 포함
            }
        }
        return std.fs.path.extension(abs_path[0..q]);
    }
    if (h_opt) |h| return std.fs.path.extension(abs_path[0..h]);
    return std.fs.path.extension(abs_path);
}

pub fn discardResolvedModule(self: *ModuleGraph, resolved: plugin_mod.ResolvedModule) void {
    switch (resolved) {
        .file => |f| {
            self.allocator.free(f.path);
            if (f.resolve_dir) |dir| self.allocator.free(dir);
        },
        .disabled => |d| self.allocator.free(d.path),
        .virtual, .dataurl, .external, .custom => {},
    }
}

pub fn markRecordLazyResolved(self: *ModuleGraph, mod_idx: usize, rec_i: usize) void {
    if (mod_idx >= self.modules.count()) return;
    const m = self.modules.at(mod_idx);
    if (rec_i >= m.import_records.len) return;
    m.import_records[rec_i].is_lazy_resolved = true;
}

/// 모듈을 그래프에 추가하고 파싱한다.
/// 이미 존재하면 기존 인덱스를 반환.
pub fn addModule(self: *ModuleGraph, abs_path: []const u8) !ModuleIndex {
    return self.addModuleWithResolveDir(abs_path, null);
}

pub fn addModuleWithResolveDir(self: *ModuleGraph, abs_path: []const u8, resolve_dir: ?[]const u8) !ModuleIndex {
    // 중복 체크
    if (self.path_to_module.get(abs_path)) |existing| {
        if (resolve_dir) |dir| {
            const existing_module = self.modules.at(@intFromEnum(existing));
            if (existing_module.resolve_dir == null) {
                existing_module.resolve_dir = try self.allocator.dupe(u8, dir);
            }
        }
        return existing;
    }

    // 새 모듈 슬롯 할당
    const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.count())));
    var ownership_transferred = false;
    const path_owned = try self.allocator.dupe(u8, abs_path);
    errdefer if (!ownership_transferred) self.allocator.free(path_owned);
    const resolve_dir_owned = if (resolve_dir) |dir| try self.allocator.dupe(u8, dir) else null;
    errdefer if (!ownership_transferred) if (resolve_dir_owned) |dir| self.allocator.free(dir);

    var module = Module.init(index, path_owned);
    module.resolve_dir = resolve_dir_owned;
    const ext_for_loader = loaderExtensionFor(abs_path);
    module.module_type = ModuleType.fromExtension(ext_for_loader);
    // 로더 결정: --loader 오버라이드 → 확장자 기본값
    const parsed_loader = resolveLoader(self, ext_for_loader);
    module.loader = parsed_loader.loader;
    module.module_type = parsed_loader.module_type orelse moduleTypeForLoader(module.module_type, module.loader);
    try self.modules.append(self.allocator, module);
    ownership_transferred = true;
    try self.path_to_module.put(path_owned, index);

    // 신규 모듈 path 의 dir 를 source_read_cache 에 pre-warm — readModuleSource 단계의
    // dir-fd cache MISS (avg 70μs) 를 graph BFS 시점에 미리 처리. virtual path
    // (disabled / optional missing 등) 는 disabled_path 전용 함수에서 처리되므로
    // 여기 들어오는 abs_path 는 fs file path. openDir 실패는 preopenDir 가 swallow.
    if (std.fs.path.dirname(abs_path)) |dir_path| {
        self.source_read_cache.preopenDir(self.allocator, dir_path);
    }

    // 파싱은 build()의 배치 루프에서 수행
    return index;
}

/// platform=browser에서 Node 빌트인 모듈을 빈 CJS 모듈로 등록 (esbuild "(disabled)" 방식).
/// AST 없이 wrap_kind=.cjs, is_disabled=true로 설정.
/// DFS가 이 모듈을 방문하여 exec_index를 부여하고, emitter가 빈 __commonJS wrapper를 출력.
pub fn addDisabledModule(self: *ModuleGraph, specifier: []const u8) !ModuleIndex {
    // 가상 경로: "(disabled):specifier" (esbuild 형식).
    // specifier 기준으로 중복 체크 — 여러 모듈이 같은 빌트인을 require해도 하나만 생성.
    return addDisabledModuleWithMode(self, module_mod.DISABLED_MODULE_PREFIX, specifier, false);
}

/// try/catch 안의 unresolved optional dependency 를 등록한다.
/// 빈 모듈을 반환하면 destructuring/default access 가 catch 로 넘어가지 않으므로,
/// require 되는 순간 Node/Metro처럼 MODULE_NOT_FOUND 를 던지는 CJS wrapper 를 출력한다.
pub fn addOptionalMissingModule(self: *ModuleGraph, specifier: []const u8) !ModuleIndex {
    return addDisabledModuleWithMode(self, module_mod.OPTIONAL_MISSING_MODULE_PREFIX, specifier, true);
}

fn addDisabledModuleWithMode(
    self: *ModuleGraph,
    prefix: []const u8,
    specifier: []const u8,
    throw_on_require: bool,
) !ModuleIndex {
    const disabled_path = try std.mem.concat(self.allocator, u8, &.{ prefix, specifier });

    // 중복 체크
    if (self.path_to_module.get(disabled_path)) |existing| {
        self.allocator.free(disabled_path);
        return existing;
    }

    const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.count())));
    var module = Module.init(index, disabled_path);
    module.module_type = .js;
    module.exports_kind = .commonjs;
    module.wrap_kind = .cjs;
    module.is_disabled = true;
    module.disabled_throw_on_require = throw_on_require;
    module.side_effects = false;
    module.state = .ready;
    try self.modules.append(self.allocator, module);
    try self.path_to_module.put(disabled_path, index);

    return index;
}

/// `external` 패턴 매칭된 specifier 를 phantom Module 로 graph 에 등록.
/// 같은 specifier 의 여러 import 는 한 Module 을 공유 — Rollup `getModuleInfo("react")`
/// 동일 식별자 의미. AST/source 없음, chunk/emit/tree-shake 에선 별도 가드로 제외.
pub fn addExternalModule(self: *ModuleGraph, specifier: []const u8) !ModuleIndex {
    if (self.path_to_module.get(specifier)) |existing| return existing;

    const index: ModuleIndex = @enumFromInt(@as(u32, @intCast(self.modules.count())));
    const path_owned = try self.allocator.dupe(u8, specifier);
    var module = Module.init(index, path_owned);
    module.is_external = true;
    module.module_type = .js;
    module.exports_kind = .esm;
    module.side_effects = true;
    module.state = .ready;
    try self.modules.append(self.allocator, module);
    try self.path_to_module.put(path_owned, index);
    return index;
}

/// 양방향 의존성 등록. from → to (dependencies) + to → from (importers) 를 동시에 append.
/// graph 가 양방향 관계 책임을 캡슐화. storage 가 SegmentedList 로 바뀌어도 caller 영향 없음.
pub fn linkDependency(self: *ModuleGraph, from: ModuleIndex, to: ModuleIndex) !void {
    if (to.isNone()) return;
    const from_mod = self.moduleAtMut(from) orelse return;
    const to_mod = self.moduleAtMut(to) orelse return;
    try from_mod.dependencies.append(self.allocator, to);
    try to_mod.importers.append(self.allocator, from);
}

/// 양방향 dynamic import 등록. `linkDependency` 의 dynamic 버전.
pub fn linkDynamicImport(self: *ModuleGraph, from: ModuleIndex, to: ModuleIndex) !void {
    if (to.isNone()) return;
    const from_mod = self.moduleAtMut(from) orelse return;
    const to_mod = self.moduleAtMut(to) orelse return;
    try from_mod.dynamic_imports.append(self.allocator, to);
    try to_mod.dynamic_importers.append(self.allocator, from);
}
