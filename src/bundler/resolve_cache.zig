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
const plugin_mod = @import("plugin.zig");
const ResolvedModule = plugin_mod.ResolvedModule;
const ResolveError = resolver_mod.ResolveError;
const types = @import("types.zig");
const ModuleType = types.ModuleType;
const ImportKind = types.ImportKind;
const pkg_json = @import("package_json.zig");
const profile = @import("../profile.zig");

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

    /// 패키지 디렉토리별 browser 필드 override 캐시 (disabled + string remap).
    /// pkg_dir_path → BrowserOverrides (null 이면 browser 필드 없음).
    browser_overrides_cache: std.StringHashMap(?BrowserOverrides),
    /// 커스텀 조건이 병합된 조건 배열 (import용, require용).
    conditions_import: []const []const u8 = &.{},
    conditions_require: []const []const u8 = &.{},
    conditions_allocated: bool = false,

    /// browser 필드 override — 4 축 분리 (path-key / module-key) × (disabled / remap).
    /// path_* : 키가 "./..." 로 시작 — 패키지 루트 상대 경로 매칭.
    /// module_*: 키가 bare name ("fs", "module-a") — specifier 직접 매칭, resolve 전.
    /// [spec: package-browser-field-spec] (#1530).
    const BrowserOverrides = struct {
        path_disabled: std.StringHashMap(void),
        path_remap: std.StringHashMap([]const u8),
        module_disabled: std.StringHashMap(void),
        module_remap: std.StringHashMap([]const u8),

        fn deinit(self: *BrowserOverrides, allocator: std.mem.Allocator) void {
            inline for (&[_]*std.StringHashMap(void){ &self.path_disabled, &self.module_disabled }) |s| {
                var ki = s.keyIterator();
                while (ki.next()) |k| allocator.free(k.*);
                s.deinit();
            }
            inline for (&[_]*std.StringHashMap([]const u8){ &self.path_remap, &self.module_remap }) |r| {
                var it = r.iterator();
                while (it.next()) |e| {
                    allocator.free(e.key_ptr.*);
                    allocator.free(e.value_ptr.*);
                }
                r.deinit();
            }
        }

        fn isEmpty(self: *const BrowserOverrides) bool {
            return self.path_disabled.count() == 0 and self.path_remap.count() == 0 and
                self.module_disabled.count() == 0 and self.module_remap.count() == 0;
        }
    };

    /// browser override 결과 — path-key 와 bare-module-key 양쪽에서 공용.
    /// remap 의 의미는 caller 문맥 결정: path-key 조회면 pkg-root 상대 경로, bare-module 조회면 replacement specifier.
    const OverrideKind = union(enum) {
        none,
        disabled,
        remap: []const u8,
    };

    /// Remap chain cycle 방어 — depth 3 이상이면 원본 경로로 fallback (#1530).
    const MAX_REMAP_DEPTH: u8 = 3;

    /// Cache 의 internal storage. external 모듈은 isExternal 이 즉시 null 반환하므로
    /// 별도 variant 불필요.
    const CachedResult = union(enum) {
        resolved: ResolvedModule,
        not_found,
    };

    /// 플랫폼 + import kind에 따른 기본 조건 세트.
    fn baseConditionsFor(platform: Platform, kind: ImportKind) []const []const u8 {
        const c = pkg_json.condition;
        return switch (kind) {
            .require => switch (platform) {
                .node => &.{ c.require, c.node, c.default },
                .browser => &.{ c.require, c.browser, c.default },
                .neutral => &.{ c.require, c.default },
                .react_native => &.{ c.require, c.react_native, c.browser, c.default },
            },
            else => switch (platform) {
                .node => &.{ c.node, c.import, c.module, c.default },
                .browser => &.{ c.browser, c.import, c.module, c.default },
                .neutral => &.{ c.import, c.module, c.default },
                .react_native => &.{ c.react_native, c.browser, c.import, c.module, c.default },
            },
        };
    }

    /// 플랫폼별 기본 main_fields 순서. 사용자가 --main-fields를 지정하지 않으면 적용.
    /// esbuild/rolldown 호환: browser는 "browser" 필드(string)로 main을 교체해야 debug 같은
    /// 패키지가 올바르게 브라우저 빌드로 해석된다.
    fn defaultMainFieldsFor(platform: Platform) []const []const u8 {
        const f = pkg_json.field;
        return switch (platform) {
            .browser => &.{ f.browser, f.module, f.main },
            .node => &.{ f.main, f.module },
            .neutral => &.{ f.main, f.module },
            .react_native => &.{ f.react_native, f.browser, f.module, f.main },
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
        /// tsconfig `paths` (절대 경로로 정규화됨). alias 보다 먼저 매칭, 다중 후보 순차 시도.
        ts_paths: []const @import("../config.zig").TsConfig.PathEntry = &.{},
        /// webpack resolve.fallback / Metro extraNodeModules 호환.
        fallback: []const resolver_mod.FallbackEntry = &.{},
        /// Metro resolver.blockList 호환 — 해석 차단 패턴.
        block_list: []const []const u8 = &.{},
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
        r.ts_paths = options.ts_paths;
        r.fallback = options.fallback;
        r.block_list = options.block_list;
        r.custom_extensions = options.resolve_extensions;
        r.main_fields = if (options.main_fields.len == 0) defaultMainFieldsFor(platform) else options.main_fields;
        r.node_paths = options.node_paths;
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
            .browser_overrides_cache = std.StringHashMap(?BrowserOverrides).init(allocator),
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
                .resolved => |m| self.allocator.free(cachedPath(m)),
                .not_found => {},
            }
        }
        self.cache.deinit();

        // browser overrides 캐시 해제
        var bd_it = self.browser_overrides_cache.iterator();
        while (bd_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |*overrides| overrides.deinit(self.allocator);
        }
        self.browser_overrides_cache.deinit();
        if (self.conditions_allocated) {
            self.allocator.free(self.conditions_import);
            self.allocator.free(self.conditions_require);
        }
    }

    /// specifier를 해석한다. 캐시 히트 시 캐시에서 반환.
    /// 결과는 `ResolvedModule` (union(enum)) — caller 가 variant 분기 처리.
    /// Phase 1 단계에선 file/disabled variant 만 반환.
    pub fn resolveAsModule(
        self: *ResolveCache,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolvedModule {
        return self.resolveInner(false, source_dir, specifier, kind);
    }

    /// 스레드 안전 resolveAsModule. 병렬 resolve 의 union 직접 사용.
    pub fn resolveAsModuleThreadSafe(
        self: *ResolveCache,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolvedModule {
        return self.resolveInner(true, source_dir, specifier, kind);
    }

    /// resolve 공통 구현. thread_safe=true이면 mutex로 캐시 접근 보호 + resolver 스택 복사.
    fn resolveInner(
        self: *ResolveCache,
        comptime thread_safe: bool,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolvedModule {
        var scope = profile.begin(.resolve);
        defer scope.end();

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
                    // Phase 1 의 cache 는 file/disabled 만 저장 (putCache 호출처 검증).
                    // path 만 caller 소유로 dupe — 다른 필드는 by-value copy.
                    .resolved => |m| switch (m) {
                        .file => |f| fileResult(
                            self.allocator.dupe(u8, f.path) catch return error.OutOfMemory,
                            f.module_type,
                            f.is_module_field,
                        ),
                        .disabled => |d| disabledResult(
                            self.allocator.dupe(u8, d.path) catch return error.OutOfMemory,
                            d.module_type,
                        ),
                        .virtual, .dataurl, .external, .custom => unreachable,
                    },
                    .not_found => error.ModuleNotFound,
                };
            }
        }

        // browser 필드 bare module intercept — resolve 전 specifier 자체를 치환 / disable (#1530).
        // source_dir 이 node_modules/<pkg> 내부일 때만 적용 (pkg 의 browser 필드가 pkg 내부 import 에 적용).
        // cycle 방어: remap chain 은 최대 MAX_REMAP_DEPTH 회까지만 반복.
        var effective_spec = specifier;
        var remap_buf: [MAX_REMAP_DEPTH][]const u8 = undefined;
        var remap_depth: u8 = 0;
        if (self.platform.isBrowserLike()) {
            while (remap_depth < MAX_REMAP_DEPTH) : (remap_depth += 1) {
                // 동일 specifier 로 self-remap 이면 즉시 종료 (recursive-module fixture).
                if (remap_depth > 0 and std.mem.eql(u8, effective_spec, remap_buf[remap_depth - 1])) break;
                switch (self.getBareModuleOverride(source_dir, effective_spec)) {
                    .disabled => {
                        const disabled_path = std.fmt.allocPrint(self.allocator, "(disabled):{s}", .{effective_spec}) catch return error.OutOfMemory;
                        if (thread_safe) self.cache_mutex.lock();
                        defer if (thread_safe) self.cache_mutex.unlock();
                        self.putCache(cache_key, .{ .resolved = .{ .disabled = .{
                            .path = self.allocator.dupe(u8, disabled_path) catch return error.OutOfMemory,
                            .module_type = .javascript,
                        } } }) catch {};
                        return disabledResult(disabled_path, .javascript);
                    },
                    .remap => |rep| {
                        remap_buf[remap_depth] = effective_spec;
                        effective_spec = rep;
                        continue;
                    },
                    .none => break,
                }
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

        const result = resolve_ptr.resolve(source_dir, effective_spec) catch |err| switch (err) {
            error.ModuleNotFound => {
                if (thread_safe) self.cache_mutex.lock();
                defer if (thread_safe) self.cache_mutex.unlock();
                self.putCache(cache_key, .not_found) catch {};
                return error.ModuleNotFound;
            },
            else => return err,
        };

        // browser override 체크 + 캐시 저장 (disabled / remap / normal).
        {
            if (thread_safe) self.cache_mutex.lock();
            defer if (thread_safe) self.cache_mutex.unlock();

            if (self.platform.isBrowserLike()) {
                const override = self.getBrowserOverride(result.path);
                switch (override) {
                    .disabled => {
                        const cache_path = self.allocator.dupe(u8, result.path) catch return error.OutOfMemory;
                        self.putCache(cache_key, .{ .resolved = .{ .disabled = .{
                            .path = cache_path,
                            .module_type = result.module_type,
                        } } }) catch {};
                        return disabledResult(result.path, result.module_type);
                    },
                    .remap => |rep| {
                        // rep 는 package-root 상대. Resolver.resolve(pkg_root, "./rep") 로
                        // 확장자 / directory index 등 정상 resolve path 재사용. 성공 시 대체 결과 반환.
                        if (findPackageDirPath(result.path)) |pkg_root| {
                            const spec_buf = std.fmt.allocPrint(self.allocator, "./{s}", .{rep}) catch {
                                // fallthrough
                                const cache_path = self.allocator.dupe(u8, result.path) catch return error.OutOfMemory;
                                self.putCache(cache_key, .{ .resolved = .{ .file = .{
                                    .path = cache_path,
                                    .module_type = result.module_type,
                                } } }) catch {};
                                return fileResult(result.path, result.module_type, result.is_module_field);
                            };
                            defer self.allocator.free(spec_buf);
                            if (thread_safe) self.cache_mutex.unlock();
                            const maybe_replaced = self.resolver.resolve(pkg_root, spec_buf);
                            if (thread_safe) self.cache_mutex.lock();
                            if (maybe_replaced) |replaced| {
                                const cache_path = self.allocator.dupe(u8, replaced.path) catch return error.OutOfMemory;
                                self.putCache(cache_key, .{ .resolved = .{ .file = .{
                                    .path = cache_path,
                                    .module_type = replaced.module_type,
                                } } }) catch {};
                                return fileResult(replaced.path, replaced.module_type, replaced.is_module_field);
                            } else |_| {
                                // fallthrough — replacement 해결 실패 시 원본 사용.
                            }
                        }
                    },
                    .none => {},
                }
            }

            const cache_path = self.allocator.dupe(u8, result.path) catch return error.OutOfMemory;
            self.putCache(cache_key, .{ .resolved = .{ .file = .{
                .path = cache_path,
                .module_type = result.module_type,
            } } }) catch {};
        }

        return fileResult(result.path, result.module_type, result.is_module_field);
    }

    /// path 는 caller 가 이미 dupe 한 것을 전달 — caller 가 메모리 owner.
    fn fileResult(path: []const u8, module_type: ModuleType, is_module_field: bool) ResolvedModule {
        return .{ .file = .{ .path = path, .module_type = module_type, .is_module_field = is_module_field } };
    }

    fn disabledResult(path: []const u8, module_type: ModuleType) ResolvedModule {
        return .{ .disabled = .{ .path = path, .module_type = module_type } };
    }

    /// CachedResult.resolved (ResolvedModule) 의 path 추출.
    /// **불변식**: Phase 1 의 cache 는 file/disabled variant 만 저장 (putCache 호출처 검증).
    /// 다른 variant 도달은 BUG — `else => ""` 는 free no-op safety net.
    fn cachedPath(m: ResolvedModule) []const u8 {
        return switch (m) {
            .file => |f| f.path,
            .disabled => |d| d.path,
            else => "",
        };
    }

    /// 캐시에 엔트리 저장. 기존 키가 있으면 이전 키/값 해제 (Critical #1 수정).
    fn putCache(self: *ResolveCache, cache_key: []const u8, value: CachedResult) !void {
        // 기존 엔트리가 있으면 해제
        if (self.cache.fetchRemove(cache_key)) |old| {
            self.allocator.free(old.key);
            switch (old.value) {
                .resolved => |m| self.allocator.free(cachedPath(m)),
                .not_found => {},
            }
        }
        const key_owned = self.allocator.dupe(u8, cache_key) catch return error.OutOfMemory;
        self.cache.put(key_owned, value) catch return error.OutOfMemory;
    }

    /// 해석된 절대 경로가 package.json "browser" 필드에서 override (disabled / remap) 되었는지 판별.
    /// node_modules 내 파일만 대상. 결과는 패키지 디렉토리별로 캐싱 (반복 파싱 방지).
    /// remap 의 value 는 BrowserOverrides 가 소유 — caller 는 외부 저장 금지.
    fn getBrowserOverride(self: *ResolveCache, resolved_path: []const u8) OverrideKind {
        // node_modules 내 파일만 대상
        const nm = "node_modules" ++ std.fs.path.sep_str;
        const nm_pos = std.mem.lastIndexOf(u8, resolved_path, nm) orelse return .none;
        const after_nm = resolved_path[nm_pos + nm.len ..];

        // 패키지 디렉토리 찾기: @scope/pkg 또는 pkg
        var pkg_end: usize = 0;
        if (after_nm.len > 0 and after_nm[0] == '@') {
            // scoped: @scope/pkg
            if (std.mem.indexOf(u8, after_nm, std.fs.path.sep_str)) |first_slash| {
                if (std.mem.indexOfPos(u8, after_nm, first_slash + 1, std.fs.path.sep_str)) |second_slash| {
                    pkg_end = second_slash;
                } else {
                    return .none;
                }
            } else {
                return .none;
            }
        } else {
            // unscoped: pkg
            pkg_end = std.mem.indexOf(u8, after_nm, std.fs.path.sep_str) orelse return .none;
        }

        const pkg_dir_path = resolved_path[0 .. nm_pos + nm.len + pkg_end];

        // 캐시 조회: 이미 이 패키지의 browser 필드를 파싱한 적이 있으면 재사용
        const overrides_opt = self.browser_overrides_cache.get(pkg_dir_path) orelse blk: {
            const built = self.buildBrowserOverrides(pkg_dir_path);
            const key_owned = self.allocator.dupe(u8, pkg_dir_path) catch return .none;
            self.browser_overrides_cache.put(key_owned, built) catch {
                self.allocator.free(key_owned);
                return .none;
            };
            break :blk built;
        };
        const overrides = overrides_opt orelse return .none;

        // resolved_path 에서 패키지 루트 이후의 상대 경로 추출
        const relative_in_pkg = resolved_path[nm_pos + nm.len + pkg_end ..];
        const dot_relative = if (relative_in_pkg.len > 0 and relative_in_pkg[0] == std.fs.path.sep)
            relative_in_pkg[1..]
        else
            relative_in_pkg;

        // 정확한 매칭 (확장자 원형) + 확장자 제거형 둘 다 조회 (path-key 만).
        if (overrides.path_disabled.contains(dot_relative)) return .disabled;
        if (overrides.path_remap.get(dot_relative)) |rep| return .{ .remap = rep };
        const ext = std.fs.path.extension(dot_relative);
        if (ext.len > 0) {
            const without_ext = dot_relative[0 .. dot_relative.len - ext.len];
            if (overrides.path_disabled.contains(without_ext)) return .disabled;
            if (overrides.path_remap.get(without_ext)) |rep| return .{ .remap = rep };
        }

        return .none;
    }

    /// source_dir 의 패키지 browser 필드에서 specifier (bare module name) 매칭 조회.
    /// `import "fs"` / `import "module-a"` 형태를 resolve 전에 intercept 하기 위한 진입점 (#1530).
    /// browser 필드 remap value 는 BrowserOverrides 소유 — caller 외부 저장 금지.
    fn getBareModuleOverride(self: *ResolveCache, source_dir: []const u8, specifier: []const u8) OverrideKind {
        // source_dir 이 node_modules/<pkg> 내부이면 해당 pkg 의 browser 필드 조회.
        const pkg_dir_path = findPackageDirPath(source_dir) orelse return .none;

        const overrides_opt = self.browser_overrides_cache.get(pkg_dir_path) orelse blk: {
            const built = self.buildBrowserOverrides(pkg_dir_path);
            const key_owned = self.allocator.dupe(u8, pkg_dir_path) catch return .none;
            self.browser_overrides_cache.put(key_owned, built) catch {
                self.allocator.free(key_owned);
                return .none;
            };
            break :blk built;
        };
        const overrides = overrides_opt orelse return .none;

        if (overrides.module_disabled.contains(specifier)) return .disabled;
        if (overrides.module_remap.get(specifier)) |rep| return .{ .remap = rep };
        return .none;
    }

    /// package.json 의 browser 필드를 4 축 (path/module × disabled/remap) 으로 수집.
    /// 키 prefix 로 분류: "./foo" → path-key, 나머지는 bare module key (#1530).
    fn buildBrowserOverrides(self: *ResolveCache, pkg_dir_path: []const u8) ?BrowserOverrides {
        var parsed = pkg_json.parsePackageJson(std.heap.page_allocator, pkg_dir_path) catch return null;
        defer parsed.deinit();

        const browser_map = parsed.pkg.browser_map orelse return null;
        const browser_obj = browser_map.object;

        var overrides = BrowserOverrides{
            .path_disabled = std.StringHashMap(void).init(self.allocator),
            .path_remap = std.StringHashMap([]const u8).init(self.allocator),
            .module_disabled = std.StringHashMap(void).init(self.allocator),
            .module_remap = std.StringHashMap([]const u8).init(self.allocator),
        };

        var kit = browser_obj.iterator();
        while (kit.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            const is_relative_path = std.mem.startsWith(u8, key, "./");
            const normalized_key = if (is_relative_path) key[2..] else key;

            switch (val) {
                .bool => |b| {
                    if (!b) {
                        const owned_key = self.allocator.dupe(u8, normalized_key) catch continue;
                        const target = if (is_relative_path) &overrides.path_disabled else &overrides.module_disabled;
                        target.put(owned_key, {}) catch self.allocator.free(owned_key);
                    }
                },
                .string => |s| {
                    // path-key 값은 "./" prefix 제거 후 저장. module-key 값은 원형 유지 (specifier).
                    const val_normalized = if (is_relative_path and std.mem.startsWith(u8, s, "./"))
                        s[2..]
                    else
                        s;
                    const owned_key = self.allocator.dupe(u8, normalized_key) catch continue;
                    const owned_val = self.allocator.dupe(u8, val_normalized) catch {
                        self.allocator.free(owned_key);
                        continue;
                    };
                    const target = if (is_relative_path) &overrides.path_remap else &overrides.module_remap;
                    target.put(owned_key, owned_val) catch {
                        self.allocator.free(owned_key);
                        self.allocator.free(owned_val);
                    };
                },
                else => continue,
            }
        }

        if (overrides.isEmpty()) {
            overrides.deinit(self.allocator);
            return null;
        }

        return overrides;
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

/// 경로에서 `.../node_modules/<pkg>` 또는 `.../node_modules/@scope/<pkg>` 패키지 루트 slice 반환.
/// 파일 경로 / 패키지 루트 dir / trailing slash 포함 dir 모두 매칭. graph.zig 및 resolve_cache 내에서 공용.
pub fn findPackageDirPath(path: []const u8) ?[]const u8 {
    const nm = "node_modules" ++ std.fs.path.sep_str;
    const nm_pos = std.mem.lastIndexOf(u8, path, nm) orelse return null;
    const after_nm = path[nm_pos + nm.len ..];

    var pkg_end: usize = 0;
    if (after_nm.len > 0 and after_nm[0] == '@') {
        const first_slash = std.mem.indexOf(u8, after_nm, std.fs.path.sep_str) orelse return null;
        pkg_end = std.mem.indexOfPos(u8, after_nm, first_slash + 1, std.fs.path.sep_str) orelse after_nm.len;
    } else {
        pkg_end = std.mem.indexOf(u8, after_nm, std.fs.path.sep_str) orelse after_nm.len;
    }

    if (pkg_end == 0) return null;
    return path[0 .. nm_pos + nm.len + pkg_end];
}

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
