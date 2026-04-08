//! ZTS Bundler — Resolve Cache + External 처리
//!
//! D064 (import kind별 resolver), D069 (external 옵션), D081 (3계층 Layer 2).
//!
//! 역할:
//!   1. external 패턴 매칭 (문자열 + `*` 글롭)
//!   2. resolve 결과 캐싱 (동일 specifier 재해석 방지)
//!   3. 플랫폼별 node 빌트인 자동 external
//!
//! 참고:
//!   - references/rolldown/crates/rolldown_resolver/src/resolver.rs (캐시 + kind별 분리)
//!   - references/esbuild/pkg/api/api.go (External []string)

const std = @import("std");
const resolver_mod = @import("resolver.zig");
const Resolver = resolver_mod.Resolver;
const ResolveResult = resolver_mod.ResolveResult;
const ResolveError = resolver_mod.ResolveError;
const types = @import("types.zig");
const ImportKind = types.ImportKind;
const pkg_json = @import("package_json.zig");

/// 타겟 플랫폼. codegen.Platform을 번들러 전체에서 공유.
pub const Platform = @import("../codegen/codegen.zig").Platform;

/// Node.js 빌트인 모듈 목록 (node: 프리픽스 없이).
/// platform=node일 때 자동 external로 처리.
/// platform=browser일 때 resolve 실패 시 빈 모듈로 대체 (esbuild "(disabled)" 방식).
pub const node_builtins: []const []const u8 = &.{
    "assert",         "async_hooks",         "buffer",     "child_process",
    "cluster",        "console",             "constants",  "crypto",
    "dgram",          "diagnostics_channel", "dns",        "domain",
    "events",         "fs",                  "http",       "http2",
    "https",          "inspector",           "module",     "net",
    "os",             "path",                "perf_hooks", "process",
    "punycode",       "querystring",         "readline",   "repl",
    "stream",         "string_decoder",      "sys",        "timers",
    "tls",            "trace_events",        "tty",        "url",
    "util",           "v8",                  "vm",         "wasi",
    "worker_threads", "zlib",
};

pub const ResolveCache = struct {
    allocator: std.mem.Allocator,
    resolver: Resolver,
    cache: std.StringHashMap(CachedResult),
    external_patterns: []const []const u8,
    platform: Platform,
    packages_external: bool = false,
    /// 병렬 resolve 시 캐시 접근 보호용 mutex.
    cache_mutex: std.Thread.Mutex = .{},

    /// 디렉토리 엔트리 캐시 — readdir() 결과를 메모리에 보관하여 stat() syscall 대폭 감소.
    dir_cache: resolver_mod.DirEntryCache,

    /// 패키지 디렉토리별 browser 필드 disabled 파일 캐시.
    /// pkg_dir_path → disabled 상대 경로 집합 (null이면 browser 필드 없음).
    browser_disabled_cache: std.StringHashMap(?BrowserDisabledSet),
    /// 커스텀 조건이 병합된 조건 배열 (import용, require용).
    conditions_import: []const []const u8 = &.{},
    conditions_require: []const []const u8 = &.{},
    conditions_allocated: bool = false,

    /// browser 필드에서 false로 매핑된 상대 경로 집합.
    const BrowserDisabledSet = std.StringHashMap(void);

    const CachedResult = union(enum) {
        resolved: ResolveResult,
        external,
        not_found,
        disabled: ResolveResult,
    };

    /// 플랫폼 + import kind에 따른 기본 조건 세트.
    fn baseConditionsFor(platform: Platform, kind: ImportKind) []const []const u8 {
        return switch (kind) {
            .require => switch (platform) {
                .node => &.{ "require", "node", "default" },
                .browser => &.{ "require", "browser", "default" },
                .neutral => &.{ "require", "default" },
                .react_native => &.{ "require", "react-native", "browser", "default" },
            },
            else => switch (platform) {
                .node => &.{ "node", "import", "module", "default" },
                .browser => &.{ "browser", "import", "module", "default" },
                .neutral => &.{ "import", "module", "default" },
                .react_native => &.{ "react-native", "browser", "import", "module", "default" },
            },
        };
    }

    /// 기본 조건에 커스텀 조건을 병합한 배열을 생성한다.
    /// 커스텀 조건은 "default" 앞에 삽입 (esbuild 동작: 커스텀 조건이 default보다 우선).
    fn buildConditions(allocator: std.mem.Allocator, base: []const []const u8, custom: []const []const u8) ![]const []const u8 {
        if (custom.len == 0) return base;
        var result = try std.ArrayList([]const u8).initCapacity(allocator, base.len + custom.len);
        // "default" 앞에 커스텀 조건 삽입
        for (base) |cond| {
            if (std.mem.eql(u8, cond, "default")) {
                for (custom) |c| result.appendAssumeCapacity(c);
            }
            result.appendAssumeCapacity(cond);
        }
        return result.toOwnedSlice(allocator);
    }

    fn conditionsFor(self: *const ResolveCache, kind: ImportKind) []const []const u8 {
        return switch (kind) {
            .require => self.conditions_require,
            else => self.conditions_import,
        };
    }

    pub const InitOptions = struct {
        platform: Platform = .browser,
        external_patterns: []const []const u8 = &.{},
        custom_conditions: []const []const u8 = &.{},
        preserve_symlinks: bool = false,
        alias: []const resolver_mod.AliasEntry = &.{},
        resolve_extensions: []const []const u8 = &.{},
        main_fields: []const []const u8 = &.{},
        /// --packages=external: 모든 bare import를 external 처리
        packages_external: bool = false,
        /// --node-paths: NODE_PATH 추가 탐색 경로
        node_paths: []const []const u8 = &.{},
    };

    pub fn init(
        allocator: std.mem.Allocator,
        options: InitOptions,
    ) ResolveCache {
        const platform = options.platform;
        const external_patterns = options.external_patterns;
        const custom_conditions = options.custom_conditions;
        const preserve_symlinks = options.preserve_symlinks;
        const alias = options.alias;
        var r = Resolver.init(allocator);
        r.preserve_symlinks = preserve_symlinks;
        r.alias = alias;
        r.custom_extensions = options.resolve_extensions;
        r.main_fields = options.main_fields;
        const has_custom = custom_conditions.len > 0;
        const cond_import = if (has_custom)
            buildConditions(allocator, baseConditionsFor(platform, .static_import), custom_conditions) catch baseConditionsFor(platform, .static_import)
        else
            baseConditionsFor(platform, .static_import);
        const cond_require = if (has_custom)
            buildConditions(allocator, baseConditionsFor(platform, .require), custom_conditions) catch baseConditionsFor(platform, .require)
        else
            baseConditionsFor(platform, .require);
        r.conditions = cond_import;
        const rc = ResolveCache{
            .allocator = allocator,
            .resolver = r,
            .cache = std.StringHashMap(CachedResult).init(allocator),
            .external_patterns = external_patterns,
            .platform = platform,
            .packages_external = options.packages_external,
            .dir_cache = resolver_mod.DirEntryCache.init(allocator),
            .browser_disabled_cache = std.StringHashMap(?BrowserDisabledSet).init(allocator),
            .conditions_import = cond_import,
            .conditions_require = cond_require,
            .conditions_allocated = has_custom,
        };
        return rc;
    }

    pub fn deinit(self: *ResolveCache) void {
        self.dir_cache.deinit();

        // 캐시된 경로 문자열 해제
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .resolved => |r| self.allocator.free(r.path),
                .disabled => |r| self.allocator.free(r.path),
                else => {},
            }
        }
        self.cache.deinit();

        // browser disabled 캐시 해제
        var bd_it = self.browser_disabled_cache.iterator();
        while (bd_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |*set| {
                var key_it = set.keyIterator();
                while (key_it.next()) |key| self.allocator.free(key.*);
                set.deinit();
            }
        }
        self.browser_disabled_cache.deinit();
        if (self.conditions_allocated) {
            self.allocator.free(self.conditions_import);
            self.allocator.free(self.conditions_require);
        }
    }

    /// specifier를 해석한다. 캐시 히트 시 캐시에서 반환.
    pub fn resolve(
        self: *ResolveCache,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolveResult {
        return self.resolveInner(false, source_dir, specifier, kind);
    }

    /// 스레드 안전 resolve. 병렬 resolve에서 사용.
    pub fn resolveThreadSafe(
        self: *ResolveCache,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolveResult {
        return self.resolveInner(true, source_dir, specifier, kind);
    }

    /// resolve 공통 구현. thread_safe=true이면 mutex로 캐시 접근 보호 + resolver 스택 복사.
    fn resolveInner(
        self: *ResolveCache,
        comptime thread_safe: bool,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolveResult {
        if (self.isExternal(specifier)) return null;

        // 스택 버퍼로 캐시 키 생성 (alloc/free 제거)
        var key_buf: [8192]u8 = undefined;
        const kind_str = @tagName(kind);
        const key_len = source_dir.len + 1 + specifier.len + 1 + kind_str.len;
        const cache_key = if (key_len <= key_buf.len) blk: {
            var pos: usize = 0;
            @memcpy(key_buf[pos .. pos + source_dir.len], source_dir);
            pos += source_dir.len;
            key_buf[pos] = 0;
            pos += 1;
            @memcpy(key_buf[pos .. pos + specifier.len], specifier);
            pos += specifier.len;
            key_buf[pos] = 0;
            pos += 1;
            @memcpy(key_buf[pos .. pos + kind_str.len], kind_str);
            pos += kind_str.len;
            break :blk key_buf[0..pos];
        } else self.makeCacheKey(source_dir, specifier, kind) catch
            return error.OutOfMemory;
        defer if (key_len > key_buf.len) self.allocator.free(cache_key);

        // 캐시 조회
        {
            if (thread_safe) self.cache_mutex.lock();
            defer if (thread_safe) self.cache_mutex.unlock();
            if (self.cache.get(cache_key)) |cached| {
                return switch (cached) {
                    .resolved => |r| ResolveResult{
                        .path = self.allocator.dupe(u8, r.path) catch return error.OutOfMemory,
                        .module_type = r.module_type,
                    },
                    .disabled => |r| ResolveResult{
                        .path = self.allocator.dupe(u8, r.path) catch return error.OutOfMemory,
                        .module_type = r.module_type,
                        .disabled = true,
                    },
                    .external => null,
                    .not_found => error.ModuleNotFound,
                };
            }
        }

        // 실제 resolve — thread_safe 모드에서는 resolver를 스택 복사하여 conditions 수정 방지
        var local_resolver = self.resolver;
        local_resolver.conditions = self.conditionsFor(kind);
        local_resolver.dir_cache = &self.dir_cache;
        if (!thread_safe) {
            // 단일 스레드: self.resolver의 conditions를 직접 교체 후 복원
            self.resolver.conditions = local_resolver.conditions;
        }
        const resolve_ptr = if (thread_safe) &local_resolver else &self.resolver;

        const result = resolve_ptr.resolve(source_dir, specifier) catch |err| switch (err) {
            error.ModuleNotFound => {
                if (thread_safe) self.cache_mutex.lock();
                defer if (thread_safe) self.cache_mutex.unlock();
                self.putCache(cache_key, .not_found) catch {};
                return error.ModuleNotFound;
            },
            else => return err,
        };

        // browser disabled 체크 + 캐시 저장
        {
            if (thread_safe) self.cache_mutex.lock();
            defer if (thread_safe) self.cache_mutex.unlock();

            if (self.platform.isBrowserLike() and self.isBrowserDisabled(result.path)) {
                const cache_path = self.allocator.dupe(u8, result.path) catch return error.OutOfMemory;
                self.putCache(cache_key, .{ .disabled = .{
                    .path = cache_path,
                    .module_type = result.module_type,
                } }) catch {};
                return ResolveResult{
                    .path = result.path,
                    .module_type = result.module_type,
                    .disabled = true,
                };
            }

            const cache_path = self.allocator.dupe(u8, result.path) catch return error.OutOfMemory;
            self.putCache(cache_key, .{ .resolved = .{
                .path = cache_path,
                .module_type = result.module_type,
            } }) catch {};
        }

        return result;
    }

    /// 캐시에 엔트리 저장. 기존 키가 있으면 이전 키/값 해제 (Critical #1 수정).
    fn putCache(self: *ResolveCache, cache_key: []const u8, value: CachedResult) !void {
        // 기존 엔트리가 있으면 해제
        if (self.cache.fetchRemove(cache_key)) |old| {
            self.allocator.free(old.key);
            switch (old.value) {
                .resolved => |r| self.allocator.free(r.path),
                .disabled => |r| self.allocator.free(r.path),
                else => {},
            }
        }
        const key_owned = self.allocator.dupe(u8, cache_key) catch return error.OutOfMemory;
        self.cache.put(key_owned, value) catch return error.OutOfMemory;
    }

    /// 해석된 절대 경로가 package.json "browser" 필드에서 false로 매핑되었는지 판별.
    /// node_modules 내 파일만 대상. 패키지 루트의 package.json을 찾아 browser 필드 확인.
    /// 결과는 패키지 디렉토리별로 캐싱하여 동일 패키지의 반복 파싱을 방지.
    fn isBrowserDisabled(self: *ResolveCache, resolved_path: []const u8) bool {
        // node_modules 내 파일만 대상
        const nm = "node_modules" ++ std.fs.path.sep_str;
        const nm_pos = std.mem.lastIndexOf(u8, resolved_path, nm) orelse return false;
        const after_nm = resolved_path[nm_pos + nm.len ..];

        // 패키지 디렉토리 찾기: @scope/pkg 또는 pkg
        var pkg_end: usize = 0;
        if (after_nm.len > 0 and after_nm[0] == '@') {
            // scoped: @scope/pkg
            if (std.mem.indexOf(u8, after_nm, std.fs.path.sep_str)) |first_slash| {
                if (std.mem.indexOfPos(u8, after_nm, first_slash + 1, std.fs.path.sep_str)) |second_slash| {
                    pkg_end = second_slash;
                } else {
                    return false;
                }
            } else {
                return false;
            }
        } else {
            // unscoped: pkg
            pkg_end = std.mem.indexOf(u8, after_nm, std.fs.path.sep_str) orelse return false;
        }

        const pkg_dir_path = resolved_path[0 .. nm_pos + nm.len + pkg_end];

        // 캐시 조회: 이미 이 패키지의 browser 필드를 파싱한 적이 있으면 재사용
        const disabled_set = self.browser_disabled_cache.get(pkg_dir_path) orelse blk: {
            // 캐시 미스: package.json 파싱하여 disabled 집합 구축
            const set = self.buildBrowserDisabledSet(pkg_dir_path);
            // 캐시에 저장 (키는 소유 복사본)
            const key_owned = self.allocator.dupe(u8, pkg_dir_path) catch return false;
            self.browser_disabled_cache.put(key_owned, set) catch {
                self.allocator.free(key_owned);
                return false;
            };
            break :blk set;
        };

        // browser 필드가 없거나 disabled 항목이 없으면 false
        const set = disabled_set orelse return false;

        // resolved_path에서 패키지 루트 이후의 상대 경로 추출
        const relative_in_pkg = resolved_path[nm_pos + nm.len + pkg_end ..];
        const dot_relative = if (relative_in_pkg.len > 0 and relative_in_pkg[0] == std.fs.path.sep)
            relative_in_pkg[1..] // "/util.inspect.js" → "util.inspect.js"
        else
            relative_in_pkg;

        // 정확한 매칭 (확장자 있는 형태)
        if (set.contains(dot_relative)) return true;

        // 확장자 제거 후 매칭 ("util.inspect.js" → "util.inspect")
        const ext = std.fs.path.extension(dot_relative);
        if (ext.len > 0) {
            const without_ext = dot_relative[0 .. dot_relative.len - ext.len];
            if (set.contains(without_ext)) return true;
        }

        return false;
    }

    /// package.json의 browser 필드에서 false로 매핑된 상대 경로 집합을 구축.
    /// browser 필드가 없으면 null 반환.
    fn buildBrowserDisabledSet(self: *ResolveCache, pkg_dir_path: []const u8) ?BrowserDisabledSet {
        var pkg_dir = std.fs.cwd().openDir(pkg_dir_path, .{}) catch return null;
        defer pkg_dir.close();

        var parsed = pkg_json.parsePackageJson(std.heap.page_allocator, pkg_dir) catch return null;
        defer parsed.deinit();

        const browser_map = parsed.pkg.browser_map orelse return null;
        const browser_obj = browser_map.object;

        var set = BrowserDisabledSet.init(self.allocator);

        var kit = browser_obj.iterator();
        while (kit.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            // false 값만 처리 (대체 경로는 현재 미지원)
            if (val != .bool or val.bool != false) continue;

            // 키에서 "./" 프리픽스 제거하여 저장
            const key_relative = if (std.mem.startsWith(u8, key, "./"))
                key[2..]
            else
                key;

            const owned_key = self.allocator.dupe(u8, key_relative) catch continue;
            set.put(owned_key, {}) catch {
                self.allocator.free(owned_key);
                continue;
            };
        }

        // disabled 항목이 하나도 없으면 빈 set 대신 null 반환
        if (set.count() == 0) {
            set.deinit();
            return null;
        }

        return set;
    }

    /// specifier가 external인지 판별.
    /// exact match + `*` 글롭 매칭 (D069).
    pub fn isExternal(self: *const ResolveCache, specifier: []const u8) bool {
        // node: 프리픽스 또는 platform=node에서 node 빌트인 자동 external
        // isNodeBuiltin이 "node:" 프리픽스와 서브패스("fs/promises" 등)를 모두 처리
        if (self.platform == .node and isNodeBuiltin(specifier)) return true;

        // node: 프리픽스는 platform과 무관하게 항상 external
        if (std.mem.startsWith(u8, specifier, "node:")) return true;

        // --packages=external: 모든 bare import를 external 처리
        if (self.packages_external and !resolver_mod.isRelativeOrAbsolute(specifier)) return true;

        // 사용자 지정 external 패턴
        for (self.external_patterns) |pattern| {
            if (matchGlob(pattern, specifier)) return true;
        }

        return false;
    }

    fn makeCacheKey(self: *ResolveCache, source_dir: []const u8, specifier: []const u8, kind: ImportKind) ![]const u8 {
        const kind_str = @tagName(kind);
        return std.mem.concat(self.allocator, u8, &.{ source_dir, "\x00", specifier, "\x00", kind_str });
    }
};

/// specifier가 Node.js 빌트인 모듈인지 판별.
/// "util", "fs", "node:fs", "util/types" 등을 인식.
pub fn isNodeBuiltin(specifier: []const u8) bool {
    // node: 프리픽스 제거
    const raw = if (std.mem.startsWith(u8, specifier, "node:"))
        specifier["node:".len..]
    else
        specifier;
    // 서브패스("util/types" 등)에서 기본 이름 추출
    const base = if (std.mem.indexOf(u8, raw, "/")) |slash|
        raw[0..slash]
    else
        raw;
    for (node_builtins) |builtin| {
        if (std.mem.eql(u8, base, builtin)) return true;
    }
    return false;
}

/// 글롭 패턴 매칭. `*`는 `/` 제외 모든 문자에 매칭 (D069).
/// "react" matches "react"
/// "@mui/*" matches "@mui/material" but not "@mui/icons/filled"
/// "node:*" matches "node:fs", "node:path"
pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];

        if (!std.mem.startsWith(u8, text, prefix)) return false;
        if (text.len < prefix.len + suffix.len) return false;
        if (!std.mem.endsWith(u8, text, suffix)) return false;

        // * 가 매칭한 부분에 / 가 있으면 불매칭
        const matched = text[prefix.len .. text.len - suffix.len];
        return std.mem.indexOf(u8, matched, "/") == null;
    }

    // 글롭 없으면 exact match
    return std.mem.eql(u8, pattern, text);
}
