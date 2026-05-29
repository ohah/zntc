//! ZNTC Bundler — Resolve Cache + External 처리
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
const spin = @import("../util/spin_lock.zig");
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
const debug_log = @import("../debug_log.zig");

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

/// resolve 결과 캐시 샤드 수 (2의 거듭제곱). 병렬 discover 에서 worker 들이 mutex 한 개에
/// 직렬화되던 걸 분산 — `hash(cache_key) % N` 로 샤드를 골라 서로 다른 cache line 을 쓰게 한다.
const num_resolve_cache_shards = 16;

/// Path string interning pool (PR resolve interning, oxc/parcel 패턴).
///
/// 모든 resolve 결과의 path string 을 단일 pool 에 저장. 같은 path 가 여러 cache 엔트리,
/// caller (Module / CachedResolvedDep) 에서 등장해도 *동일 slice 참조*.
///
/// 메모리 lifetime:
/// - `shard.arena` 가 interned bytes 소유. `ResolveCache.deinit` 시 한 번에 free.
/// - 모든 caller 가 *borrow only* — `allocator.free(interned_path)` 호출 금지.
///
/// thread-safety (PR #3750): 16-shard. `hash(path) & (num_shards - 1)` (low bits) 로
/// shard 선택 — `cacheShardFor` 와 동일. 같은 path 는 항상 같은 shard 에 landing 하므로
/// uniqueness 보장. single mutex 회귀 회복.
pub const PathInternPool = struct {
    pub const num_shards = 16;

    comptime {
        // num_shards 는 power-of-two — `& (num_shards - 1)` mask 유효성 보장.
        std.debug.assert(@popCount(@as(u32, num_shards)) == 1);
        // sweep review: cache_shards 와 같은 N 유지 — drift 시 hash 분포 invariant 깨짐.
        std.debug.assert(num_shards == num_resolve_cache_shards);
    }

    /// 모든 필드 non-optional — `PathInternPool{}` 직접 초기화를 compile-time 차단,
    /// `init()` 호출 강제. (5-angle review 일치: optional + default 로 두면 첫 intern 에서
    /// null unwrap panic 가능.)
    shards: [num_shards]Shard,
    /// init 시 받은 allocator 영구 보관 — intern/deinit 가 다른 allocator 를 받아 set
    /// 의 bucket 이 mismatched 한 allocator 로 free 되는 footgun 차단 (sweep review).
    parent_allocator: std.mem.Allocator,

    /// `pub` 으로 노출하지 않음 — 외부에서 `PathInternPool.Shard{...}` 직접 생성으로
    /// init() 강제를 우회하는 것을 차단 (sweep review).
    const Shard = struct {
        arena: std.heap.ArenaAllocator,
        /// interned bytes set. key = slice into `arena`. value = void.
        set: std.StringHashMapUnmanaged(void) = .empty,
        mutex: spin.SpinLock = .{},
    };

    pub fn init(parent_allocator: std.mem.Allocator) PathInternPool {
        var pool: PathInternPool = .{
            .shards = undefined,
            .parent_allocator = parent_allocator,
        };
        for (&pool.shards) |*s| {
            s.* = .{
                .arena = std.heap.ArenaAllocator.init(parent_allocator),
                .set = .{},
                .mutex = .{},
            };
        }
        return pool;
    }

    pub fn deinit(self: *PathInternPool) void {
        for (&self.shards) |*s| {
            s.set.deinit(self.parent_allocator);
            s.arena.deinit();
        }
    }

    /// path → shard 선택. `hash & (num_shards - 1)` (low bits) — `cacheShardFor` 와 동일.
    /// power-of-two assert 가 위 comptime block 에서 보장됨.
    inline fn shardFor(self: *PathInternPool, path: []const u8) *Shard {
        const h = std.hash_map.hashString(path);
        const idx: usize = @intCast(h & (num_shards - 1));
        return &self.shards[idx];
    }

    /// path 가 pool 에 있으면 그 slice 반환, 없으면 dupe 후 추가.
    /// 반환된 slice 의 lifetime = pool 의 lifetime (= ResolveCache lifetime).
    pub fn intern(self: *PathInternPool, path: []const u8) std.mem.Allocator.Error![]const u8 {
        const shard = self.shardFor(path);
        shard.mutex.lock();
        defer shard.mutex.unlock();
        if (shard.set.getKey(path)) |existing| return existing;
        const owned = try shard.arena.allocator().dupe(u8, path);
        try shard.set.put(self.parent_allocator, owned, {});
        return owned;
    }

    /// 두 path 를 intern. 각각 별도 shard 일 수 있어 두 번 lock. (single-lock atomicity
    /// 의존 없음 — caller 는 즉시 ResolvedModule 구성, OOM 시 input string 만 errdefer
    /// 로 해제. 부분 commit 된 interned bytes 는 pool deinit 시 일괄 reclaim.)
    pub fn internPair(
        self: *PathInternPool,
        path1: []const u8,
        path2: ?[]const u8,
    ) std.mem.Allocator.Error!struct { []const u8, ?[]const u8 } {
        const p1 = try self.intern(path1);
        const p2: ?[]const u8 = if (path2) |p| try self.intern(p) else null;
        return .{ p1, p2 };
    }
};

pub const ResolveCache = struct {
    allocator: std.mem.Allocator,
    resolver: Resolver,
    /// 병렬 resolve 결과 캐시 — `num_resolve_cache_shards` 개의 (mutex + map) 로 샤딩.
    cache_shards: [num_resolve_cache_shards]CacheShard,
    /// PR resolve interning: 모든 resolved path 의 single-source-of-truth pool.
    /// caller 는 *borrow only*, free 안 함. `deinit` 시 일괄 reclaim.
    path_pool: PathInternPool,
    /// (deferred 5) `.dataurl.data` 전용 arena. data 가 base64 큰 메모리라 path_pool
    /// (StringHashMap dedup) 부적합 — 별도 arena 로 caller-borrow 일관성 확보 + ""
    /// placeholder 위험 제거. dedup 없음 (data 가 모듈마다 다르고 hash 매칭 거의 없음).
    ///
    /// **Memory bound**: monotonic 증가. `IncrementalBundler` 의 N rebuild 마다 ResolveCache
    /// 재생성 (PR #3756) 으로 자동 reclaim — watch mode 무한 누적 방지.
    ///
    /// **Lock order** (ResolveCache 의 모든 mutex):
    ///   1. `cache_shards[i].mutex` (resolve cache shard)
    ///   2. `path_pool.shards[i].mutex` (path intern shard)
    ///   3. `realpath_cache.shards[i].mutex` (realpath dir cache shard) — R2 (#3745)
    ///   4. `dataurl_arena_mutex` (this)
    ///   5. `browser_cache_mutex`
    /// 잠금 시 *반드시 위 순서* — 역순/중첩 잠금 금지 (deadlock). 현재 코드는 각 mutex
    /// 가 짧은 critical section 안에서만 잠겨 상호배제 영향 없지만 future 추가 시 enforce.
    dataurl_arena: std.heap.ArenaAllocator,
    dataurl_arena_mutex: spin.SpinLock = .{},
    external_patterns: []const []const u8,
    platform: Platform,
    packages_external: bool = false,

    /// 디렉토리 엔트리 캐시 — readdir() 결과를 메모리에 보관하여 stat() syscall 대폭 감소.
    dir_cache: resolver_mod.DirEntryCache,
    realpath_cache: resolver_mod.RealpathCache,
    /// package.json 파싱 캐시 — 디렉토리당 1회 read+parse (importer 디렉토리마다 재파싱 방지).
    pkg_json_cache: pkg_json.PackageJsonCache,

    /// 패키지 디렉토리별 browser 필드 override 캐시 (disabled + string remap).
    /// pkg_dir_path → BrowserOverrides (null 이면 browser 필드 없음).
    browser_overrides_cache: std.StringHashMap(?BrowserOverrides),
    /// `browser_overrides_cache` 접근 보호 — `getBareModuleOverride` 는 어떤 락도 안 쥐고
    /// 호출되므로(`resolveInner` 의 pre-resolve 분기) 두 worker 가 같은 패키지를 처음
    /// 만나면 `.put` 이 동시에 일어나 HashMap 이 깨질 수 있다.
    browser_cache_mutex: spin.SpinLock = .{},
    /// 커스텀 조건이 병합된 조건 배열 (import용, require용).
    conditions_import: []const []const u8 = &.{},
    conditions_require: []const []const u8 = &.{},
    conditions_allocated: bool = false,

    const CacheShard = struct {
        mutex: spin.SpinLock = .{},
        map: std.StringHashMap(CachedResult),
    };

    fn cacheShardFor(self: *ResolveCache, cache_key: []const u8) *CacheShard {
        const shard_index: usize = @intCast(std.hash_map.hashString(cache_key) % num_resolve_cache_shards);
        return &self.cache_shards[shard_index];
    }

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
                // Metro: `unstable_conditionNames: ["react-native"]` + 리졸버가
                // importer 시점에 `require` / `default` 를 자동 추가
                // (`references/metro/packages/metro-resolver/src/utils/matchSubpathFromExportsLike.js`).
                // ESM 패키지가 react-native 조건 없이 require/default 만 노출해도
                // Metro 는 `require` 매칭으로 정상 해석함 → `require` 를 살려야 한다.
                .react_native => &.{ c.react_native, c.require, c.default },
            },
            else => switch (platform) {
                .node => &.{ c.node, c.import, c.module, c.default },
                .browser => &.{ c.browser, c.import, c.module, c.default },
                .neutral => &.{ c.import, c.module, c.default },
                // Metro: `unstable_conditionNames: ["react-native"]` + 리졸버가
                // ESM importer 에서 `import` / `default` 를 자동 추가.
                // ESM-only 패키지가 react-native 조건 없이 `import`/`default` 만
                // 노출하는 경우에도 Metro 는 `./dist/index.js` 같은 import 분기를
                // 정상 해석한다. `module` 은 RN 표준 main field 가 아니므로 미포함.
                .react_native => &.{ c.react_native, c.import, c.default },
            },
        };
    }

    /// 플랫폼별 기본 main_fields 순서. 사용자가 --main-fields를 지정하지 않으면 적용.
    /// Rspack/Webpack-style ESM-friendly 기본값: `module` 필드를 `main`보다 우선한다.
    /// browser는 "browser" 필드(string)로 main을 교체해야 debug 같은 패키지가 올바르게
    /// 브라우저 빌드로 해석된다.
    fn defaultMainFieldsFor(platform: Platform) []const []const u8 {
        const f = pkg_json.field;
        return switch (platform) {
            .browser => &.{ f.browser, f.module, f.main },
            .node => &.{ f.module, f.main },
            .neutral => &.{ f.module, f.main },
            .react_native => &.{ f.react_native, f.browser, f.main },
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
        /// 일반 node_modules 탐색 실패 시 source_dir 의 realpath 디렉토리로 한 번 더 탐색.
        resolve_symlink_siblings: bool = false,
        /// Metro `resolver.disableHierarchicalLookup` 호환 — parent dir walk-up 차단.
        disable_hierarchical_lookup: bool = false,
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
        r.resolve_symlink_siblings = options.resolve_symlink_siblings;
        r.disable_hierarchical_lookup = options.disable_hierarchical_lookup;
        r.alias = alias;
        r.ts_paths = options.ts_paths;
        r.fallback = options.fallback;
        r.block_list = options.block_list;
        r.custom_extensions = options.resolve_extensions;
        r.main_fields = if (options.main_fields.len == 0) defaultMainFieldsFor(platform) else options.main_fields;
        r.node_paths = options.node_paths;
        r.react_native_asset_scale_fallback = platform == .react_native;
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
        var cache_shards: [num_resolve_cache_shards]CacheShard = undefined;
        for (&cache_shards) |*s| s.* = .{ .map = std.StringHashMap(CachedResult).init(allocator) };
        const rc = ResolveCache{
            .allocator = allocator,
            .resolver = r,
            .cache_shards = cache_shards,
            .path_pool = PathInternPool.init(allocator),
            .dataurl_arena = std.heap.ArenaAllocator.init(allocator),
            .external_patterns = external_patterns,
            .platform = platform,
            .packages_external = options.packages_external,
            .dir_cache = resolver_mod.DirEntryCache.init(allocator),
            .realpath_cache = resolver_mod.RealpathCache.init(allocator),
            .pkg_json_cache = pkg_json.PackageJsonCache.init(allocator),
            .browser_overrides_cache = std.StringHashMap(?BrowserOverrides).init(allocator),
            .conditions_import = cond_import,
            .conditions_require = cond_require,
            .conditions_allocated = has_custom,
        };
        return rc;
    }

    pub fn deinit(self: *ResolveCache) void {
        self.dir_cache.deinit();
        self.realpath_cache.deinit();
        self.pkg_json_cache.deinit();

        // 캐시된 cache_key 만 free — value 의 path/resolve_dir 는 path_pool 소유 (자동 reclaim).
        for (&self.cache_shards) |*shard| {
            var it = shard.map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            shard.map.deinit();
        }

        // PR resolve interning: path pool 일괄 reclaim.
        self.path_pool.deinit();
        // (deferred 5) dataurl.data arena 일괄 reclaim.
        self.dataurl_arena.deinit();

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
    pub fn resolve(
        self: *ResolveCache,
        io: std.Io,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolvedModule {
        return self.resolveInner(false, io, source_dir, specifier, kind);
    }

    /// 스레드 안전 resolve. 병렬 resolve 의 union 직접 사용.
    pub fn resolveThreadSafe(
        self: *ResolveCache,
        io: std.Io,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolvedModule {
        return self.resolveInner(true, io, source_dir, specifier, kind);
    }

    /// resolve 공통 구현. thread_safe=true이면 mutex로 캐시 접근 보호 + resolver 스택 복사.
    fn resolveInner(
        self: *ResolveCache,
        comptime thread_safe: bool,
        io: std.Io,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolvedModule {
        var scope = profile.begin(.resolve);
        defer scope.end();

        {
            var external_scope = profile.begin(.resolve_external);
            defer external_scope.end();
            if (self.isExternal(specifier)) return null;
        }

        // 스택 버퍼로 캐시 키 생성 (alloc/free 제거)
        var key_buf: [8192]u8 = undefined;
        const kind_str = @tagName(kind);
        const key_len = source_dir.len + 1 + specifier.len + 1 + kind_str.len;
        const cache_key = blk: {
            var key_scope = profile.begin(.resolve_cache_key);
            defer key_scope.end();
            break :blk if (key_len <= key_buf.len) stack_key: {
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
                break :stack_key key_buf[0..pos];
            } else self.makeCacheKey(source_dir, specifier, kind) catch
                return error.OutOfMemory;
        };
        defer if (key_len > key_buf.len) self.allocator.free(cache_key);

        // 이 키가 속한 캐시 샤드 — lookup/store/putCache 모두 이 샤드의 mutex 로 보호.
        const cache_shard = self.cacheShardFor(cache_key);

        // 캐시 조회
        {
            var lookup_scope = profile.begin(.resolve_cache_lookup);
            defer lookup_scope.end();
            if (thread_safe) cache_shard.mutex.lock();
            defer if (thread_safe) cache_shard.mutex.unlock();
            if (cache_shard.map.get(cache_key)) |cached| {
                return switch (cached) {
                    // PR resolve interning: cache 의 path/resolve_dir 는 *interned* — caller 가
                    // borrow only. dupe 회피.
                    .resolved => |m| switch (m) {
                        .file => |f| fileResult(f.path, f.resolve_dir, f.module_type, f.is_module_field),
                        .disabled => |d| disabledResult(d.path, d.module_type),
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
        {
            var browser_scope = profile.begin(.resolve_browser_override);
            defer browser_scope.end();
            if (self.platform.isBrowserLike()) {
                while (remap_depth < MAX_REMAP_DEPTH) : (remap_depth += 1) {
                    // 동일 specifier 로 self-remap 이면 즉시 종료 (recursive-module fixture).
                    if (remap_depth > 0 and std.mem.eql(u8, effective_spec, remap_buf[remap_depth - 1])) break;
                    switch (self.getBareModuleOverride(io, source_dir, effective_spec)) {
                        .disabled => {
                            const disabled_path = std.fmt.allocPrint(self.allocator, "(disabled):{s}", .{effective_spec}) catch return error.OutOfMemory;
                            // interning: pool 에 store + 원본 free. cache + caller 둘 다 interned.
                            const result = try self.internDisabled(disabled_path, .js, .owned);
                            var store_scope = profile.begin(.resolve_cache_store);
                            defer store_scope.end();
                            if (thread_safe) cache_shard.mutex.lock();
                            defer if (thread_safe) cache_shard.mutex.unlock();
                            self.putCache(cache_key, .{ .resolved = result }) catch {};
                            return result;
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
        }

        // 실제 resolve — thread_safe 모드에서는 resolver를 스택 복사하여 conditions 수정 방지
        var local_resolver = self.resolver;
        local_resolver.conditions = self.conditionsFor(kind);
        local_resolver.dir_cache = &self.dir_cache;
        local_resolver.realpath_cache = &self.realpath_cache;
        local_resolver.pkg_json_cache = &self.pkg_json_cache;
        if (!thread_safe) {
            // 단일 스레드: self.resolver의 conditions를 직접 교체 후 복원
            self.resolver.conditions = local_resolver.conditions;
        }
        const resolve_ptr = if (thread_safe) &local_resolver else &self.resolver;

        const result = blk: {
            var resolver_scope = profile.begin(.resolve_resolver);
            defer resolver_scope.end();
            var audit = debug_log.auditScope(.resolve_audit);
            defer if (audit.on) debug_log.print(.resolve_audit, "resolve bare={d} spec_len={d} src_len={d} ns={d}\n", .{ @intFromBool(!resolver_mod.isRelativeOrAbsolute(effective_spec)), effective_spec.len, source_dir.len, audit.elapsedNs() });
            break :blk resolve_ptr.resolve(io, source_dir, effective_spec) catch |err| switch (err) {
                error.ModuleNotFound => {
                    var store_scope = profile.begin(.resolve_cache_store);
                    defer store_scope.end();
                    if (thread_safe) cache_shard.mutex.lock();
                    defer if (thread_safe) cache_shard.mutex.unlock();
                    self.putCache(cache_key, .not_found) catch {};
                    return error.ModuleNotFound;
                },
                else => return err,
            };
        };

        // browser override 체크 + 캐시 저장 (disabled / remap / normal).
        if (thread_safe) cache_shard.mutex.lock();
        defer if (thread_safe) cache_shard.mutex.unlock();

        // resolver 가 `--fallback:NAME=false` (또는 다른 disabled 경로) 로 빈 모듈을
        // 반환한 경우 — disabled variant 로 캐싱 + 반환. 이 분기 없이는 `.file` 로
        // cache 되어 graph 단계에서 일반 파싱 시도 → "No loader configured" 에러.
        if (result.disabled) {
            // interning: result.path free + pool intern + cache & caller borrow.
            const disabled = try self.internDisabled(result.path, result.module_type, .owned);
            if (result.resolve_dir) |dir| self.allocator.free(dir);
            var store_scope = profile.begin(.resolve_cache_store);
            defer store_scope.end();
            self.putCache(cache_key, .{ .resolved = disabled }) catch {};
            return disabled;
        }

        if (self.platform.isBrowserLike()) {
            var browser_scope = profile.begin(.resolve_browser_override);
            defer browser_scope.end();
            const override = self.getBrowserOverride(io, result.path);
            switch (override) {
                .disabled => {
                    const disabled = try self.internDisabled(result.path, result.module_type, .owned);
                    if (result.resolve_dir) |dir| self.allocator.free(dir);
                    var store_scope = profile.begin(.resolve_cache_store);
                    defer store_scope.end();
                    self.putCache(cache_key, .{ .resolved = disabled }) catch {};
                    return disabled;
                },
                .remap => |rep| {
                    // rep 는 package-root 상대. Resolver.resolve(pkg_root, "./rep") 로
                    // 확장자 / directory index 등 정상 resolve path 재사용. 성공 시 대체 결과 반환.
                    if (findPackageDirPath(result.path)) |pkg_root| {
                        const spec_buf = std.fmt.allocPrint(self.allocator, "./{s}", .{rep}) catch {
                            // fallthrough — interning: result intern + cache store.
                            const file_result = try self.internAndFreeFile(result);
                            var store_scope = profile.begin(.resolve_cache_store);
                            defer store_scope.end();
                            self.putCache(cache_key, .{ .resolved = file_result }) catch {};
                            return file_result;
                        };
                        defer self.allocator.free(spec_buf);
                        if (thread_safe) cache_shard.mutex.unlock();
                        const maybe_replaced = self.resolver.resolve(io, pkg_root, spec_buf);
                        if (thread_safe) cache_shard.mutex.lock();
                        if (maybe_replaced) |replaced| {
                            // 원본 result free — replaced 가 새 owner.
                            self.allocator.free(result.path);
                            if (result.resolve_dir) |dir| self.allocator.free(dir);
                            const file_result = try self.internAndFreeFile(replaced);
                            var store_scope = profile.begin(.resolve_cache_store);
                            defer store_scope.end();
                            self.putCache(cache_key, .{ .resolved = file_result }) catch {};
                            return file_result;
                        } else |_| {
                            // fallthrough — replacement 해결 실패 시 원본 사용.
                        }
                    }
                },
                .none => {},
            }
        }

        const file_result = try self.internAndFreeFile(result);
        {
            var store_scope = profile.begin(.resolve_cache_store);
            defer store_scope.end();
            self.putCache(cache_key, .{ .resolved = file_result }) catch {};
        }
        return file_result;
    }

    /// path 는 *interned* (path_pool 소유). caller 는 borrow only — free 안 함.
    /// `.borrowed` 명시로 caller-borrow 시맨틱 type-level 표명.
    fn fileResult(path: []const u8, resolve_dir: ?[]const u8, module_type: ModuleType, is_module_field: bool) ResolvedModule {
        return .{ .file = .{
            .path = path,
            .resolve_dir = resolve_dir,
            .module_type = module_type,
            .is_module_field = is_module_field,
            .owner = .borrowed,
        } };
    }

    fn disabledResult(path: []const u8, module_type: ModuleType) ResolvedModule {
        return .{ .disabled = .{ .path = path, .module_type = module_type, .owner = .borrowed } };
    }

    /// PR resolve interning helper — resolver 가 alloc 한 path 를 intern + 원본 free.
    /// 반환된 ResolvedModule 의 path 는 path_pool 소유 (caller borrow only).
    /// **OOM 시 input 도 free** (errdefer) — single-owner invariant 일관.
    fn internAndFreeFile(self: *ResolveCache, result: resolver_mod.ResolveResult) error{OutOfMemory}!ResolvedModule {
        errdefer {
            self.allocator.free(result.path);
            if (result.resolve_dir) |dir| self.allocator.free(dir);
        }
        const paths = try self.path_pool.internPair(result.path, result.resolve_dir);
        // resolver 원본 free — pool 이 단일 owner.
        self.allocator.free(result.path);
        if (result.resolve_dir) |dir| self.allocator.free(dir);
        return .{ .file = .{
            .path = paths[0],
            .resolve_dir = paths[1],
            .module_type = result.module_type,
            .is_module_field = result.is_module_field,
            .owner = .borrowed,
        } };
    }

    /// disabled variant 용 — path 단일 intern. `owner.isOwned()` 면 원본 free.
    /// **OOM 시 input 도 free** (errdefer) — single-owner invariant 일관.
    fn internDisabled(self: *ResolveCache, path: []const u8, module_type: ModuleType, owner: plugin_mod.Owner) error{OutOfMemory}!ResolvedModule {
        errdefer if (owner.isOwned()) self.allocator.free(path);
        const interned = try self.path_pool.intern(path);
        if (owner.isOwned()) self.allocator.free(path);
        return .{ .disabled = .{ .path = interned, .module_type = module_type, .owner = .borrowed } };
    }

    /// 캐시에 엔트리 저장. 기존 키가 있으면 이전 키 free (value 의 path 는 pool 소유).
    /// 호출자는 `cacheShardFor(cache_key)` 의 mutex 를 쥔 상태여야 한다 (resolveInner 가 그렇게 한다).
    fn putCache(self: *ResolveCache, cache_key: []const u8, value: CachedResult) !void {
        const map = &self.cacheShardFor(cache_key).map;
        // 기존 엔트리가 있으면 key 만 free (value 의 path 는 path_pool 소유).
        if (map.fetchRemove(cache_key)) |old| {
            self.allocator.free(old.key);
        }
        const key_owned = self.allocator.dupe(u8, cache_key) catch return error.OutOfMemory;
        map.put(key_owned, value) catch return error.OutOfMemory;
    }

    /// 해석된 절대 경로가 package.json "browser" 필드에서 override (disabled / remap) 되었는지 판별.
    /// node_modules 내 파일만 대상. 결과는 패키지 디렉토리별로 캐싱 (반복 파싱 방지).
    /// remap 의 value 는 BrowserOverrides 가 소유 — caller 는 외부 저장 금지.
    fn getBrowserOverride(self: *ResolveCache, io: std.Io, resolved_path: []const u8) OverrideKind {
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

        const overrides = self.getOrBuildBrowserOverrides(io, pkg_dir_path) orelse return .none;

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
    fn getBareModuleOverride(self: *ResolveCache, io: std.Io, source_dir: []const u8, specifier: []const u8) OverrideKind {
        // source_dir 이 node_modules/<pkg> 내부이면 해당 pkg 의 browser 필드 조회.
        const pkg_dir_path = findPackageDirPath(source_dir) orelse return .none;

        const overrides = self.getOrBuildBrowserOverrides(io, pkg_dir_path) orelse return .none;

        if (overrides.module_disabled.contains(specifier)) return .disabled;
        if (overrides.module_remap.get(specifier)) |rep| return .{ .remap = rep };
        return .none;
    }

    /// 패키지의 browser override 를 캐시에서 가져오거나 (없으면) 빌드해 넣는다. thread-safe.
    /// 빌드(package.json 파싱)는 락 밖에서 하고, 다 만든 뒤 짧게 락 잡아 삽입 — 그 사이 다른
    /// 스레드가 먼저 넣었으면 내가 만든 건 폐기 (DirEntryCache 와 동일 패턴).
    /// 반환값은 캐시 map 과 무관한 by-value 복사라 락 밖에서 읽어도 안전 (BrowserOverrides 의
    /// 내부 map 들은 빌드 후 불변, 그 버킷은 deinit 전까지 안 풀린다).
    fn getOrBuildBrowserOverrides(self: *ResolveCache, io: std.Io, pkg_dir_path: []const u8) ?BrowserOverrides {
        {
            self.browser_cache_mutex.lock();
            defer self.browser_cache_mutex.unlock();
            if (self.browser_overrides_cache.get(pkg_dir_path)) |cached| return cached;
        }

        var built = self.buildBrowserOverrides(io, pkg_dir_path);

        self.browser_cache_mutex.lock();
        defer self.browser_cache_mutex.unlock();
        if (self.browser_overrides_cache.get(pkg_dir_path)) |existing| {
            if (built) |*b| b.deinit(self.allocator);
            return existing;
        }
        const key_owned = self.allocator.dupe(u8, pkg_dir_path) catch {
            if (built) |*b| b.deinit(self.allocator);
            return null;
        };
        self.browser_overrides_cache.put(key_owned, built) catch {
            self.allocator.free(key_owned);
            if (built) |*b| b.deinit(self.allocator);
            return null;
        };
        return built;
    }

    /// package.json 의 browser 필드를 4 축 (path/module × disabled/remap) 으로 수집.
    /// 키 prefix 로 분류: "./foo" → path-key, 나머지는 bare module key (#1530).
    fn buildBrowserOverrides(self: *ResolveCache, io: std.Io, pkg_dir_path: []const u8) ?BrowserOverrides {
        // pkg_json_cache 가 소유 — 여기서 deinit 하지 않는다 (디렉토리당 1회 parse 재사용).
        const parsed = self.pkg_json_cache.getOrParse(io, pkg_dir_path) catch return null;
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
    /// external 패턴 슬라이스 교체(#3318 ④). `external_patterns` 는
    /// init 시 borrow 저장만 되고 실제 소비는 `isExternal`(resolve 단계
    /// lazy)이라, resolve 시작 *전* 에 교체하면 init 무변경으로 무손실.
    /// 슬라이스는 여전히 **borrow**(소유모델 불변) — 호출자(Bundler)가
    /// combined 버퍼 소유·해제. MF seam 을 옵션 레이어가 아닌 번들러
    /// 단일 지점에서 주입하는 데 사용.
    /// PR resolve interning: 외부 (plugin) ResolvedModule 의 path 를 pool 로 옮김.
    /// 원본 path / resolve_dir 는 free, pool 의 interned slice 가리키는 ResolvedModule 반환.
    /// plugin runner 가 alloc 한 결과를 caller-borrow invariant 에 맞춤.
    ///
    /// **interning 적용 variant**: 모든 variant — Owner discriminator 로 borrow vs owned 분기.
    /// `.dataurl` 는 mime 은 path_pool, data 는 별도 `dataurl_arena` 에 dupe (deferred 5) —
    /// data 가 base64 큰 메모리라 dedup 부적합이지만 cache lifetime 동안 valid 보장.
    ///
    /// owner ambiguity 해소 — Owner enum discriminator:
    /// - `.file/.disabled/.external/.custom` default true (native resolver / NAPI bridge dupe)
    /// - `.virtual` default false (runtime_helper borrow 가 더 흔함)
    /// - ``.owned`` 면 intern + 원본 free
    /// - ``.borrowed`` 면 intern 만 (caller 가 owner 유지)
    ///
    /// 반환된 ResolvedModule 의 path 는 항상 path_pool 의 interned slice (caller borrow
    /// only) — `.borrowed` 로 명시.
    pub fn internResolvedModule(self: *ResolveCache, m: ResolvedModule) !ResolvedModule {
        return switch (m) {
            .file => |f| blk: {
                // errdefer 와 explicit free 분리 — sub-scope 로 errdefer 영역 격리.
                const paths = pool: {
                    errdefer if (f.owner.isOwned()) {
                        self.allocator.free(f.path);
                        if (f.resolve_dir) |d| self.allocator.free(d);
                    };
                    break :pool try self.path_pool.internPair(f.path, f.resolve_dir);
                };
                if (f.owner.isOwned()) {
                    self.allocator.free(f.path);
                    if (f.resolve_dir) |d| self.allocator.free(d);
                }
                break :blk .{ .file = .{
                    .path = paths[0],
                    .resolve_dir = paths[1],
                    .module_type = f.module_type,
                    .is_module_field = f.is_module_field,
                    .owner = .borrowed,
                } };
            },
            // .disabled — internDisabled helper 가 동일 errdefer + sub-scope-equivalent
            // 패턴 보유 (line 670-675). 다른 variant 의 inline blk 패턴과 다르지만 동작 동일.
            .disabled => |d| try self.internDisabled(d.path, d.module_type, d.owner),
            // (이하 .virtual/.external/.custom) inline sub-scope 패턴:
            // owner ambiguity 해소 — `.owned` 만 free.
            // intern 실패 시 errdefer 가 free, 성공 시 explicit free 후 break — explicit
            // free 와 errdefer 가 같은 slice 를 노리지 않도록 errdefer 는 intern 호출
            // 영역만 감싼다 (sub-scope blk 로 격리).
            .virtual => |v| blk: {
                const interned = pool: {
                    errdefer if (v.owner.isOwned()) self.allocator.free(v.path);
                    break :pool try self.path_pool.intern(v.path);
                };
                if (v.owner.isOwned()) self.allocator.free(v.path);
                break :blk .{ .virtual = .{ .path = interned, .plugin_data = v.plugin_data, .owner = .borrowed } };
            },
            // (#3763 후속) .external/.custom 도 .virtual 와 같은 Owner 패턴 — intern +
            // 조건부 free. 현재 resolve_imports.zig:349 가 unreachable 라 도달 안 함이지만,
            // future plugin layer 활성화 시 dangling/leak 방지 가능.
            .external => |e| blk: {
                const interned = pool: {
                    errdefer if (e.owner.isOwned()) self.allocator.free(e.path);
                    break :pool try self.path_pool.intern(e.path);
                };
                if (e.owner.isOwned()) self.allocator.free(e.path);
                break :blk .{ .external = .{ .path = interned, .owner = .borrowed } };
            },
            .custom => |c| blk: {
                // (retro review P0) name + path 둘 다 같은 owner 가정 (Owner 단일).
                // c.name.ptr == c.path.ptr (aliasing) + `.owned` 면 free 두 번 →
                // double-free. invariant: caller 가 동일 slice 를 둘 다 가리키지 않게 하거나
                // `.borrowed` 로 borrow 명시. mixed owner 케이스는 future RFC (owner_name +
                // owner_path 분리).
                if (c.owner.isOwned()) std.debug.assert(c.name.ptr != c.path.ptr);
                const paths = pool: {
                    errdefer if (c.owner.isOwned()) {
                        self.allocator.free(c.name);
                        self.allocator.free(c.path);
                    };
                    break :pool try self.path_pool.internPair(c.name, c.path);
                };
                if (c.owner.isOwned()) {
                    self.allocator.free(c.name);
                    self.allocator.free(c.path);
                }
                break :blk .{ .custom = .{
                    .name = paths[0],
                    .path = paths[1].?,
                    .plugin_data = c.plugin_data,
                    .owner = .borrowed,
                } };
            },
            // (deferred 2 + 5) .dataurl: mime 은 path_pool intern (짧고 재사용 가능),
            // data 는 별도 `dataurl_arena` 에 dupe (base64 큰 메모리라 path_pool dedup
            // 부적합, 그러나 cache lifetime 유지 위해 자체 arena 필요).
            // - `.owned`: mime + data 원본 free (intern/dupe 후 store 가 owner)
            // - `.borrowed`: caller-borrow 유지하되, dataurl_arena 에 dupe 해 cache lifetime
            //   동안 valid 보장 (caller 가 그 사이 free 해도 안전).
            //
            // ★ 일관성: 모든 variant 가 반환 시 cache-owned slice → caller 가 borrow
            //   하기만 하면 됨. 이전 PR (#3767) 의 "" placeholder 위험 제거.
            //
            // (review finding) `.custom` 처럼 mime.ptr == data.ptr aliasing 시 double-free
            // → debug assert 로 차단.
            .dataurl => |du| blk: {
                if (du.owner.isOwned()) std.debug.assert(du.mime.ptr != du.data.ptr);
                const interned_mime = pool: {
                    errdefer if (du.owner.isOwned()) {
                        self.allocator.free(du.mime);
                        self.allocator.free(du.data);
                    };
                    break :pool try self.path_pool.intern(du.mime);
                };
                const interned_data = data_blk: {
                    errdefer if (du.owner.isOwned()) {
                        self.allocator.free(du.mime);
                        self.allocator.free(du.data);
                    };
                    self.dataurl_arena_mutex.lock();
                    defer self.dataurl_arena_mutex.unlock();
                    break :data_blk try self.dataurl_arena.allocator().dupe(u8, du.data);
                };
                if (du.owner.isOwned()) {
                    self.allocator.free(du.mime);
                    self.allocator.free(du.data);
                }
                break :blk .{
                    .dataurl = .{
                        .mime = interned_mime,
                        .data = interned_data, // cache-owned (dataurl_arena, dedup 없음)
                        .owner = .borrowed,
                    },
                };
            },
        };
    }

    pub fn setExternalPatterns(self: *ResolveCache, patterns: []const []const u8) void {
        self.external_patterns = patterns;
    }

    pub fn isExternal(self: *const ResolveCache, specifier: []const u8) bool {
        // node: 프리픽스는 platform과 무관하게 항상 external
        if (std.mem.startsWith(u8, specifier, "node:")) return true;

        const is_path = resolver_mod.isRelativeOrAbsolute(specifier);

        // 상대/절대 경로는 Node builtin 이 될 수 없으므로 builtin 목록 선형 탐색을 피한다.
        if (self.platform == .node and !is_path and isNodeBuiltin(specifier)) return true;

        // --packages=external: 모든 bare import를 external 처리
        if (self.packages_external and !is_path) return true;

        // 사용자 지정 external 패턴
        for (self.external_patterns) |pattern| {
            if (matchGlob(pattern, specifier)) return true;
            if (matchPackageSubPath(pattern, specifier)) return true;
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
/// #1962 esbuild/rolldown 동등 — external 패키지의 sub-path 자동 매칭.
/// 예) `external: ["react"]` → "react/jsx-runtime", "react/jsx-dev-runtime" 도 external.
/// `*` 보유 패턴 (e.g. `react/*`) 은 사용자가 sub-path 매칭을 직접 작성한 것이므로
/// 자동 확장 안 함 — 명시 의도와 충돌하지 않게.
pub fn matchPackageSubPath(pattern: []const u8, specifier: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "*") != null) return false;
    if (specifier.len <= pattern.len) return false;
    if (!std.mem.startsWith(u8, specifier, pattern)) return false;
    return specifier[pattern.len] == '/';
}

pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '{')) |open| {
        if (std.mem.indexOfScalarPos(u8, pattern, open + 1, '}')) |close| {
            const prefix = pattern[0..open];
            const body = pattern[open + 1 .. close];
            const suffix = pattern[close + 1 ..];
            var rest = body;
            while (true) {
                const comma = std.mem.indexOfScalar(u8, rest, ',');
                const alt = if (comma) |idx| rest[0..idx] else rest;
                var expanded_buf: [4096]u8 = undefined;
                if (prefix.len + alt.len + suffix.len <= expanded_buf.len) {
                    @memcpy(expanded_buf[0..prefix.len], prefix);
                    @memcpy(expanded_buf[prefix.len .. prefix.len + alt.len], alt);
                    @memcpy(expanded_buf[prefix.len + alt.len .. prefix.len + alt.len + suffix.len], suffix);
                    if (matchGlob(expanded_buf[0 .. prefix.len + alt.len + suffix.len], text)) return true;
                }
                if (comma) |idx| {
                    rest = rest[idx + 1 ..];
                } else break;
            }
            return false;
        }
    }

    return matchGlobNoBrace(pattern, text);
}

fn matchGlobNoBrace(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;

    if (std.mem.startsWith(u8, pattern, "**")) {
        var rest = pattern[2..];
        if (std.mem.startsWith(u8, rest, "/")) {
            rest = rest[1..];
            if (matchGlobNoBrace(rest, text)) return true;
            for (text, 0..) |ch, i| {
                if (ch == '/' and matchGlobNoBrace(rest, text[i + 1 ..])) return true;
            }
            return false;
        }

        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (matchGlobNoBrace(rest, text[i..])) return true;
        }
        return false;
    }

    if (pattern[0] == '*') {
        const rest = pattern[1..];
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (matchGlobNoBrace(rest, text[i..])) return true;
            if (i == text.len or text[i] == '/') break;
        }
        return false;
    }

    if (pattern[0] == '?') {
        if (text.len == 0 or text[0] == '/') return false;
        return matchGlobNoBrace(pattern[1..], text[1..]);
    }

    if (text.len == 0 or pattern[0] != text[0]) return false;
    return matchGlobNoBrace(pattern[1..], text[1..]);
}
