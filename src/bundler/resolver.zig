//! ZNTC Bundler — Module Resolver
//!
//! import 경로를 절대 파일 경로로 해석한다 (D081 Layer 1).
//! 상대 경로(`./`, `../`)와 절대 경로를 처리.
//! bare specifier (node_modules)는 PR #4에서 추가.
//!
//! 해석 알고리즘 (D064):
//!   1. 경로 조합 (source_dir + specifier)
//!   2. 정확한 파일 존재 확인
//!   3. 확장자 추가: .ts, .tsx, .js, .jsx, .json
//!   4. TS 확장자 매핑: .js → .ts/.tsx (Rolldown 방식)
//!   5. 디렉토리 index: dir/index.ts, dir/index.tsx, dir/index.js
//!   6. 없으면 ModuleNotFound
//!
//! 참고:
//!   - references/esbuild/internal/resolver/resolver.go
//!   - references/rolldown/crates/rolldown_resolver/src/resolver.rs
//!   - references/bun/src/resolver/resolver.zig

const std = @import("std");
const spin = @import("../util/spin_lock.zig");
const types = @import("types.zig");
const ModuleType = types.ModuleType;
const pkg_json = @import("package_json.zig");
const fs = @import("fs.zig");
const PackageJson = pkg_json.PackageJson;
const resolve_cache = @import("resolve_cache.zig");
const profile = @import("../profile.zig");
const debug_log = @import("../debug_log.zig");

pub const ResolveResult = struct {
    /// 해석된 절대 파일 경로
    path: []const u8,
    /// 확장자에서 추론한 모듈 타입
    module_type: ModuleType,
    /// package.json "browser" 필드에서 false로 매핑된 파일.
    /// platform=browser에서 빈 CJS 모듈로 대체한다 (esbuild "(disabled)" 방식).
    disabled: bool = false,
    /// package.json "module" 필드를 통해 resolve된 파일.
    /// .js 확장자라도 ESM으로 파싱해야 함.
    is_module_field: bool = false,
    /// `preserveSymlinks` 의 기본 module identity 는 logical path 이지만, 표준 pnpm
    /// package symlink 는 Metro 와 맞추기 위해 real package path 로 정규화될 수 있다.
    /// 이 값이 있으면 후속 dependency lookup 은 `path` 의 dirname 대신 여기서 시작한다.
    /// null 이면 dirname(path) 를 사용한다.
    resolve_dir: ?[]const u8 = null,
};

pub const ResolveError = error{
    ModuleNotFound,
    OutOfMemory,
};

/// 기본 확장자 탐색 순서.
/// TypeScript 확장자가 먼저 (TS 프로젝트에서 .ts가 .js보다 우선).
/// .mts/.cts는 ESM/CJS 모듈 전용 TypeScript 확장자.
const default_extensions: []const []const u8 = &.{ ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".json" };

/// TS 확장자 매핑 (D064).
/// import './foo.js'가 실제로 ./foo.ts를 가리킬 수 있음.
const ts_extension_map: []const struct { from: []const u8, to: []const []const u8 } = &.{
    .{ .from = ".js", .to = &.{ ".ts", ".tsx" } },
    .{ .from = ".jsx", .to = &.{".tsx"} },
    .{ .from = ".mjs", .to = &.{".mts"} },
    .{ .from = ".cjs", .to = &.{".cts"} },
};

/// index 파일 탐색 순서 (디렉토리 해석 시).
const index_files: []const []const u8 = &.{ "index.ts", "index.tsx", "index.js", "index.jsx" };

pub const AliasEntry = types.AliasEntry;
pub const FallbackEntry = types.FallbackEntry;

/// tsconfig paths entry 의 key 패턴이 specifier 와 매칭되는지 검사.
/// 매칭되면 wildcard capture (key 가 wildcard 면 `*` 위치의 중간 문자열, 아니면 빈 문자열) 반환.
/// 매칭 안 되면 null.
fn matchTsPathEntry(entry: @import("../config.zig").TsConfig.PathEntry, specifier: []const u8) ?[]const u8 {
    if (!entry.has_wildcard) {
        if (std.mem.eql(u8, specifier, entry.key_prefix)) return ""; // exact 매칭 — capture 없음
        return null;
    }
    if (specifier.len < entry.key_prefix.len + entry.key_suffix.len) return null;
    if (!std.mem.startsWith(u8, specifier, entry.key_prefix)) return null;
    if (!std.mem.endsWith(u8, specifier, entry.key_suffix)) return null;
    return specifier[entry.key_prefix.len .. specifier.len - entry.key_suffix.len];
}

/// 디렉토리 엔트리 캐시 (esbuild 방식).
/// 디렉토리를 처음 접근할 때 readdir()로 파일 목록을 통째로 읽어 캐시.
/// 이후 같은 디렉토리의 파일 존재 확인은 syscall 없이 메모리 조회.
///
/// 멀티스레드 resolve 에서 공유된다. 두 가지 contention 회피:
///   1. **읽기는 `RwLock` 의 shared lock** — 캐시 hit 가 압도적으로 많고(워밍업 후
///      readdir 거의 없음) 서로 막지 않게.
///   2. **readdir + EntrySet 빌드는 lock 을 안 쥔 채** 수행하고, 다 만든 뒤 짧게
///      exclusive lock 을 잡아 삽입. 예전엔 첫 스레드가 느린 readdir syscall 을
///      global mutex 를 쥔 채로 돌려서 나머지 worker 를 전부 막았다.
///
/// `EntrySet` 은 heap 에 두고 map 에는 `*EntrySet` 만 저장 — `getOrLoad` 가 돌려준
/// 포인터가 이후 다른 스레드의 삽입(map rehash)에도 dangling 되지 않게 한다.
pub const DirEntryCache = struct {
    /// 디렉토리 절대 경로 → 엔트리 집합. null이면 디렉토리가 존재하지 않음 (negative 캐시).
    cache: std.StringHashMapUnmanaged(?*EntrySet) = .empty,
    rwlock: spin.SpinRwLock = .{},
    allocator: std.mem.Allocator,
    /// 0.16: listDir 가 io 를 요구. Resolver.resolve 진입 시 주입 (per-instance).
    io: std.Io = undefined,

    const EntrySet = struct {
        files: std.StringHashMapUnmanaged(void) = .empty,
        dirs: std.StringHashMapUnmanaged(void) = .empty,
    };

    pub fn init(allocator: std.mem.Allocator) DirEntryCache {
        return .{
            .cache = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DirEntryCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |set| self.destroyEntrySet(set);
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit(self.allocator);
    }

    fn destroyEntrySet(self: *DirEntryCache, set: *EntrySet) void {
        var fit = set.files.keyIterator();
        while (fit.next()) |k| self.allocator.free(k.*);
        set.files.deinit(self.allocator);
        var dit = set.dirs.keyIterator();
        while (dit.next()) |k| self.allocator.free(k.*);
        set.dirs.deinit(self.allocator);
        self.allocator.destroy(set);
    }

    /// 디렉토리 내 파일 존재 확인. 캐시 미스 시 readdir() 후 캐시.
    pub fn hasFile(self: *DirEntryCache, dir_path: []const u8, file_name: []const u8) bool {
        const set = self.getOrLoad(dir_path) orelse return false;
        return set.files.contains(file_name);
    }

    /// 디렉토리 내 서브디렉토리 존재 확인.
    pub fn hasDir(self: *DirEntryCache, dir_path: []const u8, dir_name: []const u8) bool {
        const set = self.getOrLoad(dir_path) orelse return false;
        return set.dirs.contains(dir_name);
    }

    /// 디렉토리 자체가 존재하는지 확인.
    pub fn dirExists(self: *DirEntryCache, path: []const u8) bool {
        // 부모 디렉토리의 캐시에서 이 디렉토리 이름을 찾기
        const parent = std.fs.path.dirname(path) orelse return false;
        const name = std.fs.path.basename(path);
        if (name.len == 0) return false;
        return self.hasDir(parent, name);
    }

    fn getOrLoad(self: *DirEntryCache, dir_path: []const u8) ?*const EntrySet {
        // 1. fast path — shared lock 으로 조회.
        {
            self.rwlock.lockShared();
            defer self.rwlock.unlockShared();
            if (self.cache.get(dir_path)) |maybe_set| return maybe_set;
        }

        // 2. 캐시 미스 — lock 없이 readdir + EntrySet 빌드.
        const built: ?*EntrySet = self.buildEntrySet(dir_path);

        // 3. exclusive lock 으로 삽입. 그 사이 다른 스레드가 먼저 넣었을 수 있다.
        self.rwlock.lock();
        defer self.rwlock.unlock();
        if (self.cache.get(dir_path)) |existing| {
            if (built) |b| self.destroyEntrySet(b);
            return existing;
        }
        const key = self.allocator.dupe(u8, dir_path) catch {
            if (built) |b| self.destroyEntrySet(b);
            return null;
        };
        self.cache.put(self.allocator, key, built) catch {
            self.allocator.free(key);
            if (built) |b| self.destroyEntrySet(b);
            return null;
        };
        return built;
    }

    /// readdir() 후 heap 에 `EntrySet` 을 만들어 반환. 디렉토리가 없거나 OOM 이면 null
    /// (호출자는 negative 로 캐시) — 기존 동작과 동일.
    fn buildEntrySet(self: *DirEntryCache, dir_path: []const u8) ?*EntrySet {
        const entries = fs.listDir(self.io, self.allocator, dir_path) catch return null;
        // entries 의 name 은 hashmap 으로 소유권 이전되거나 free 됨 — slice 자체만 free.
        defer self.allocator.free(entries);

        const set = self.allocator.create(EntrySet) catch {
            for (entries) |entry| self.allocator.free(entry.name);
            return null;
        };
        set.* = .{
            .files = .empty,
            .dirs = .empty,
        };

        for (entries) |entry| {
            switch (entry.kind) {
                .file => set.files.put(self.allocator, entry.name, {}) catch self.allocator.free(entry.name),
                .directory => set.dirs.put(self.allocator, entry.name, {}) catch self.allocator.free(entry.name),
                .symlink => {
                    // symlink는 대상이 파일인지 디렉토리인지 readdir만으로 알 수 없으므로 양쪽에 등록.
                    // Linux의 bun install이 node_modules에 symlink 디렉토리를 만들기 때문에 필수.
                    // dupe 를 *먼저* — entry.name 을 put 실패 시 free 해도 name2 가 dangling 안 되게.
                    const name2 = self.allocator.dupe(u8, entry.name) catch null;
                    // files.put 실패 시 entry.name free — file/directory arm 과 동일 소유권(leak 방지).
                    set.files.put(self.allocator, entry.name, {}) catch self.allocator.free(entry.name);
                    if (name2) |n2| set.dirs.put(self.allocator, n2, {}) catch self.allocator.free(n2);
                },
                else => self.allocator.free(entry.name),
            }
        }
        return set;
    }
};

/// Directory-level realpath 캐시.
///
/// `makeResult()` 는 모듈마다 `fs.realpath()` syscall 을 호출하는데, 대형 그래프
/// (5000+ 모듈) 에서 이 호출이 38% 비중 (`resolve.realpath` profile, 2026-05-11
/// 실측). 같은 디렉토리의 N 개 파일도 N 번 syscall 한다.
///
/// 이 캐시는 path 의 dirname 만 realpath 하고 basename 은 join — pnpm/.bun
/// symlink 패턴 (디렉토리 단위 symlink) 을 그대로 cover 한다. 같은 디렉토리의
/// 파일 1000 개 → realpath syscall 1 회.
///
/// 한계: file-level symlink (개별 파일이 symlink 인 케이스) 는 dir-level resolve
/// 뒤 basename join 이라 따라가지 못한다. ZNTC 가 import 하는 일반 source/dep
/// 경로는 이 패턴이 거의 없어 영향 없음. preserve_symlinks=true 면 어차피 cache
/// 우회 (기존 동작 동일).
/// dir-level realpath cache. 같은 dir 의 여러 path 가 자주 호출되므로 dir 만 realpath
/// 한 후 basename join (R2 #3745 — symlink-heavy workspace 에서 syscall 80%+ 감소).
///
/// thread-safety (R2): 16-shard. `hash(dir) & (num_shards - 1)` 로 shard 선택 —
/// `PathInternPool` / `cacheShardFor` 와 동일 방식. resolve hot path 에서 worker
/// 들이 single mutex 에 직렬화되던 걸 분산.
pub const RealpathCache = struct {
    pub const num_shards = 16;

    comptime {
        std.debug.assert(@popCount(@as(u32, num_shards)) == 1);
        // (review) cross-pool drift 방지 — PathInternPool / cache_shards 와 같은 N (16).
        // resolve_cache 가 cyclic import 라 직접 비교 못해 hard-coded 16 assert. 변경 시
        // resolve_cache.zig 의 `num_resolve_cache_shards` + `PathInternPool.num_shards` 도 동시 변경 필요.
        std.debug.assert(num_shards == 16);
    }

    shards: [num_shards]Shard,
    allocator: std.mem.Allocator,
    /// 0.16: realpath 가 io 를 요구. Resolver.resolve 진입 시 주입 (per-instance).
    io: std.Io = undefined,

    const Shard = struct {
        cache: std.StringHashMapUnmanaged([]const u8) = .empty,
        mutex: spin.SpinLock = .{},
    };

    pub fn init(allocator: std.mem.Allocator) RealpathCache {
        var rc: RealpathCache = .{
            .shards = undefined,
            .allocator = allocator,
        };
        for (&rc.shards) |*s| {
            s.* = .{ .cache = .empty };
        }
        return rc;
    }

    pub fn deinit(self: *RealpathCache) void {
        for (&self.shards) |*s| {
            var it = s.cache.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            s.cache.deinit(self.allocator);
        }
    }

    /// dir → shard. `PathInternPool.shardFor` 와 동일 패턴.
    inline fn shardFor(self: *RealpathCache, dir: []const u8) *Shard {
        const h = std.hash_map.hashString(dir);
        const idx: usize = @intCast(h & (num_shards - 1));
        return &self.shards[idx];
    }

    /// path 의 realpath 를 owned slice 로 반환.
    /// dir-level 캐시 적중 시 syscall 0. 캐시 miss 면 dir 만 realpath 후 cache + join.
    pub fn resolve(self: *RealpathCache, path: []const u8) error{OutOfMemory}![]const u8 {
        const dir = std.fs.path.dirname(path) orelse {
            // dirname 없음 (root path "/"). 그대로 dupe.
            return self.allocator.dupe(u8, path);
        };
        const basename = std.fs.path.basename(path);
        const shard = self.shardFor(dir);

        shard.mutex.lock();
        const cached_dir: ?[]const u8 = if (shard.cache.get(dir)) |v| v else null;
        shard.mutex.unlock();

        const resolved_dir = cached_dir orelse blk: {
            const new_dir = fs.realpath(self.io, self.allocator, dir) catch
                self.allocator.dupe(u8, dir) catch return error.OutOfMemory;

            shard.mutex.lock();
            defer shard.mutex.unlock();
            // race: 다른 thread 가 먼저 넣었을 수 있음.
            if (shard.cache.get(dir)) |existing| {
                self.allocator.free(new_dir);
                break :blk existing;
            }
            const key = self.allocator.dupe(u8, dir) catch {
                self.allocator.free(new_dir);
                return error.OutOfMemory;
            };
            shard.cache.put(self.allocator, key, new_dir) catch {
                self.allocator.free(key);
                self.allocator.free(new_dir);
                return error.OutOfMemory;
            };
            break :blk new_dir;
        };

        // resolved_dir + "/" + basename
        return std.fs.path.join(self.allocator, &.{ resolved_dir, basename });
    }
};

const NodeModulesPackagePath = struct {
    name: []const u8,
    node_modules_index: usize,
};

/// `<...>/node_modules/<pkg-or-scope/pkg>` 의 안쪽부터 시작해서 `.pnpm` 은 skip,
/// 실제 패키지명을 가진 segment 의 이름과 node_modules 위치를 반환.
/// resolve_cache.findPackageDirPath 를 single source of truth 로 재사용 — `@scope`
/// 와 OS sep 처리가 그쪽에 일원화돼 있다.
fn lastNodeModulesPackagePath(path: []const u8) ?NodeModulesPackagePath {
    const nm = "node_modules" ++ std.fs.path.sep_str;
    var search_end: usize = path.len;
    while (true) {
        const dir = resolve_cache.findPackageDirPath(path[0..search_end]) orelse return null;
        const at = std.mem.lastIndexOf(u8, dir, nm) orelse return null;
        const name = dir[at + nm.len ..];
        if (!std.mem.eql(u8, name, ".pnpm")) {
            return .{ .name = name, .node_modules_index = at };
        }
        // .pnpm 자체는 패키지가 아니라 pnpm hard-link store — outer node_modules 로 재탐색.
        search_end = at;
    }
}

fn hasNodeModulesPnpmPrefix(path: []const u8) bool {
    const nm = "node_modules" ++ std.fs.path.sep_str;
    var search_end: usize = path.len;
    while (true) {
        const dir = resolve_cache.findPackageDirPath(path[0..search_end]) orelse return false;
        const at = std.mem.lastIndexOf(u8, dir, nm) orelse return false;
        if (std.mem.eql(u8, dir[at + nm.len ..], ".pnpm")) return true;
        search_end = at;
    }
}

fn shouldCanonicalizePnpmPackageSymlink(logical_path: []const u8, real_path: []const u8) bool {
    if (std.mem.eql(u8, logical_path, real_path)) return false;

    const logical_pkg = lastNodeModulesPackagePath(logical_path) orelse return false;
    const real_pkg = lastNodeModulesPackagePath(real_path) orelse return false;
    if (!std.mem.eql(u8, logical_pkg.name, real_pkg.name)) return false;

    return hasNodeModulesPnpmPrefix(real_path[0..real_pkg.node_modules_index]);
}

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    /// 조건 세트 (D064: import kind별로 다를 수 있음).
    /// ResolveCache.conditionsFor()에서 platform+kind별로 설정.
    /// 기본값은 테스트용 (브라우저 ESM).
    conditions: []const []const u8 = &.{ "import", "module", "browser", "default" },
    /// symlink 를 따라가지 않고 링크 자체 경로로 해석 (--preserve-symlinks).
    /// 기본은 esbuild/Node 처럼 link path 를 module identity 로 쓰지만,
    /// `resolve_symlink_siblings` 와 함께 켠 표준 pnpm package symlink 는 Metro처럼
    /// 실제 `.pnpm/<pkg>/node_modules/<pkg>` 경로 하나로 정규화한다. 같은 native
    /// package 가 app/node_modules 와 peer package node_modules 양쪽에서 들어와 두 번
    /// evaluate 되는 RN 회귀를 막기 위함이다.
    preserve_symlinks: bool = false,
    /// `preserve_symlinks` 로 logical path 를 module identity 로 보존한 상태에서,
    /// logical node_modules 탐색이 실패한 bare specifier 를 realpath 디렉토리 기준으로
    /// 한 번 더 찾는다.
    /// pnpm 처럼 `app/node_modules/pkg` 가 `.pnpm/.../pkg` 로 symlink 된 환경에서,
    /// `pkg` 의 sibling dependency (예: `code-push`) 가 `.pnpm/.../node_modules/` 에만
    /// 존재하는 경우 Metro/Node 와 같은 결과를 만든다. workspace symlink 패키지는
    /// 앱의 logical node_modules 를 먼저 보므로 consuming app dependency 를 놓치지 않는다.
    /// `preserve_symlinks` 와 직교한 옵션이며, 둘은 함께 켜는 것이 일반적이다.
    resolve_symlink_siblings: bool = false,
    /// `resolveNodeModules` 의 parent dir walk-up 차단 (Metro `resolver.
    /// disableHierarchicalLookup` 호환). monorepo 에서 dependency hoisting
    /// 을 강제하거나, 워크스페이스 루트 외부의 `node_modules` 가 의도치
    /// 않게 탐색되는 것을 막을 때 사용. 기본 false — 일반 Node.js algorithm
    /// (cwd 부터 root 까지 hierarchical lookup) 그대로.
    disable_hierarchical_lookup: bool = false,
    /// import 경로 별칭 (--alias:K=V). resolve 시 specifier 앞부분을 치환.
    /// 정확 매칭: "react" → "preact/compat"
    /// 접두사 매칭: "react/hooks" → "preact/compat/hooks"
    alias: []const AliasEntry = &.{},
    /// tsconfig `paths` — alias 와 달리 `*` wildcard 가 위치 자유, 다중 후보 순차 시도.
    /// resolver 가 패턴 매칭 + 파일 존재 확인을 수행해 첫 resolvable 후보를 반환.
    /// 절대 경로로 정규화된 상태를 기대 (`config.resolveTsPaths` 참고).
    ts_paths: []const @import("../config.zig").TsConfig.PathEntry = &.{},
    /// Fallback 엔트리 (webpack `resolve.fallback` / Metro `extraNodeModules` 호환).
    /// alias와 달리 일반 해석이 **실패했을 때만** 적용. 정확 매칭만 지원 (webpack과 동일).
    /// `to == null`이면 빈 모듈(disabled result)로 대체.
    fallback: []const FallbackEntry = &.{},
    /// blockList — Metro resolver.blockList 호환. 매칭되는 절대 경로는 ModuleNotFound 처리.
    /// 패턴 구문은 `block_list.zig` 참조 (regex 최소 서브셋).
    block_list: []const []const u8 = &.{},
    /// 커스텀 확장자 탐색 순서 (--resolve-extensions). 비어있으면 default_extensions 사용.
    /// RN 예: .ios.ts, .ios.tsx, .native.ts, .native.tsx, .ts, .tsx, .js, .jsx, .json
    custom_extensions: []const []const u8 = &.{},
    /// package.json 필드 해석 순서 (--main-fields). 비어있으면 기본 순서 (module → main).
    /// RN 예: react-native, browser, main
    main_fields: []const []const u8 = &.{},
    /// 디렉토리 엔트리 캐시. null이면 캐시 없이 매번 stat() 호출 (테스트용).
    dir_cache: ?*DirEntryCache = null,
    /// Directory-level realpath 캐시. null 이면 매번 fs.realpath() 호출 (테스트용).
    /// 같은 디렉토리의 N 개 파일 → 1 realpath syscall. 대형 그래프에서 큰 비중.
    realpath_cache: ?*RealpathCache = null,
    /// package.json 파싱 캐시. null 이면 매번 read+parse (테스트용).
    /// 같은 `node_modules/<pkg>/package.json` 을 importer 디렉토리마다 다시 읽지 않게.
    pkg_json_cache: ?*pkg_json.PackageJsonCache = null,
    /// NODE_PATH 추가 탐색 경로 (--node-paths). 상위 디렉토리 탐색 실패 시 폴백.
    node_paths: []const []const u8 = &.{},
    /// React Native asset resolver 호환: `name.ext` base 파일이 없어도
    /// `name@2x.ext` / `name@3x.ext` 같은 scale variant가 있으면 그 파일로 해석한다.
    react_native_asset_scale_fallback: bool = false,
    /// 0.16: fs 연산이 io 를 요구한다. Resolver 는 fs 프로빙이 25+ 메서드에 깊게
    /// 퍼진 stateful 서브시스템이라, public 진입점 `resolve()` 에서 1회 저장한
    /// per-instance io 를 내부 메서드가 self.io 로 읽는다 (전역 아님 — resolve_cache
    /// 의 thread-safe 경로는 resolver 를 복사하므로 io 는 스레드-로컬). std.http.Client
    /// 가 io 를 필드로 갖는 것과 동형.
    io: std.Io = undefined,

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return .{ .allocator = allocator };
    }

    /// alias 규칙을 specifier에 적용한다.
    /// 정확 매칭: specifier == entry.from → entry.to
    /// 접두사 매칭: specifier가 entry.from + "/" 로 시작 → entry.to + 나머지
    /// 매칭 없으면 null 반환. 반환값은 allocator 소유 (호출자가 해제).
    pub fn applyAlias(allocator: std.mem.Allocator, alias_entries: []const AliasEntry, specifier: []const u8) error{OutOfMemory}!?[]const u8 {
        for (alias_entries) |entry| {
            // 정확 매칭
            if (std.mem.eql(u8, specifier, entry.from)) {
                return try allocator.dupe(u8, entry.to);
            }
            // `exact = true` 인 entry 는 prefix 매칭 skip — `to` 가 단일 파일이면 subpath
            // import 가 깨지므로 명시적 opt-in 한 경우에만 prefix 도 허용.
            if (entry.exact) continue;
            // 접두사 매칭: specifier가 "from/" 로 시작
            if (specifier.len > entry.from.len and
                std.mem.startsWith(u8, specifier, entry.from) and
                specifier[entry.from.len] == '/')
            {
                const suffix = specifier[entry.from.len..]; // "/hooks" 등
                var result = try allocator.alloc(u8, entry.to.len + suffix.len);
                @memcpy(result[0..entry.to.len], entry.to);
                @memcpy(result[entry.to.len..], suffix);
                return result;
            }
        }
        return null;
    }

    /// fallback 매핑을 specifier에 적용. bare 해석 실패 시에만 호출됨.
    /// 정확 매칭만 (webpack/Metro 동작). to=null이면 빈 모듈, to=path/name이면 재해석.
    fn applyFallback(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!?ResolveResult {
        for (self.fallback) |entry| {
            if (!std.mem.eql(u8, specifier, entry.from)) continue;
            if (entry.to) |target| {
                // target을 새로운 specifier로 보고 재해석. fallback 재귀는 막기 위해
                // 임시로 fallback을 비워 resolve한다 (잘못된 fallback chain 방지).
                const saved = self.fallback;
                self.fallback = &.{};
                defer self.fallback = saved;
                return try self.resolve(self.io, source_dir, target);
            }
            // target=null → 빈 모듈 (webpack `false`)
            const path_dup = self.allocator.dupe(u8, specifier) catch return error.OutOfMemory;
            return .{ .path = path_dup, .module_type = .js, .disabled = true };
        }
        return null;
    }

    /// tsconfig `paths` 패턴 매칭 + 순차 candidate resolve.
    /// TS 스펙에 따라:
    /// 1. 각 paths entry 에 대해 key 패턴 매칭 (exact 또는 prefix + suffix with captured middle)
    /// 2. 매칭된 entry 의 targets 를 순서대로 시도 — 파일 존재 확인까지 포함
    /// 3. 첫 resolvable target 의 ResolveResult 반환
    /// 모든 entry 매칭/resolve 실패 시 null → caller 가 일반 resolve 경로로 fall-through.
    fn tryTsPaths(self: *Resolver, specifier: []const u8) ResolveError!?ResolveResult {
        for (self.ts_paths) |entry| {
            const captured = matchTsPathEntry(entry, specifier) orelse continue;
            for (entry.targets) |t| {
                // target.prefix 는 tsconfig_dir 기준 절대 경로로 join 만 되어 있음.
                // capture 와 concat 후 `path.resolve` 로 한꺼번에 normalize (`./././` 등 정리).
                const raw = try std.mem.concat(self.allocator, u8, &.{ t.prefix, captured, t.suffix });
                defer self.allocator.free(raw);
                const candidate = try std.fs.path.resolve(self.allocator, &.{raw});
                defer self.allocator.free(candidate);
                if (try self.tryResolvePathLike(candidate)) |r| return r;
            }
        }
        return null;
    }

    /// 절대 경로 1 개에 대해 `resolveInner` 의 pass #1–#4 와 동일 로직으로 resolve 시도.
    /// pnpm symlink package root alias 처럼 file 과 dir 양쪽으로 보이는 경우는
    /// `tryDirectoryIndex` 를 먼저 시도해 package entry(index/main/exports) 로 간다.
    fn tryResolvePathLike(self: *Resolver, abs_path: []const u8) ResolveError!?ResolveResult {
        const maybe_dir = self.dirExists(abs_path);
        if (maybe_dir) {
            // DirEntryCache 는 symlink target 을 readdir 만으로 알 수 없어 file+dir
            // 양쪽에 등록한다. pnpm package symlink root 를 alias 로 직접 가리키면
            // fileExists 가 먼저 true 가 되어 package entry(index/main/exports)를 건너뛰므로,
            // ambiguous directory 후보는 package/directory resolve 를 먼저 시도한다.
            if (try self.tryDirectoryIndex(abs_path)) |result| return result;
        }

        if (self.fileExists(abs_path)) return try self.makeResult(abs_path);
        if (try self.tryReactNativeScaleAssetFallback(abs_path)) |result| return result;
        if (try self.tryExtensions(abs_path)) |result| return result;
        if (try self.tryTsExtensionMapping(abs_path)) |result| return result;
        if (!maybe_dir) {
            if (try self.tryDirectoryIndex(abs_path)) |result| return result;
        }
        return null;
    }

    fn isReactNativeScaleAssetExt(ext: []const u8) bool {
        inline for (&[_][]const u8{
            ".bmp", ".gif",  ".jpg", ".jpeg", ".png", ".psd",  ".svg",   ".webp", ".tiff", ".tif", ".xml", ".avif", ".ico",
            ".m4v", ".mov",  ".mp4", ".mpeg", ".mpg", ".webm", ".aac",   ".aiff", ".caf",  ".m4a", ".mp3", ".wav",  ".html",
            ".pdf", ".yaml", ".yml", ".otf",  ".ttf", ".woff", ".woff2",
        }) |candidate| {
            if (std.ascii.eqlIgnoreCase(ext, candidate)) return true;
        }
        return false;
    }

    fn hasScaleSuffix(name_without_ext: []const u8) bool {
        if (name_without_ext.len < 4 or name_without_ext[name_without_ext.len - 1] != 'x') return false;

        var cursor = name_without_ext.len - 1;
        var saw_digit = false;
        var saw_dot = false;
        while (cursor > 0) {
            const ch = name_without_ext[cursor - 1];
            if (std.ascii.isDigit(ch)) {
                saw_digit = true;
                cursor -= 1;
                continue;
            }
            if (ch == '.' and !saw_dot and saw_digit) {
                saw_dot = true;
                saw_digit = false;
                cursor -= 1;
                continue;
            }
            break;
        }
        return saw_digit and cursor > 0 and name_without_ext[cursor - 1] == '@';
    }

    fn tryReactNativeScaleAssetFallback(self: *Resolver, abs_path: []const u8) ResolveError!?ResolveResult {
        if (!self.react_native_asset_scale_fallback) return null;

        const ext = std.fs.path.extension(abs_path);
        if (ext.len == 0 or !isReactNativeScaleAssetExt(ext)) return null;

        const dir = std.fs.path.dirname(abs_path) orelse return null;
        const basename = std.fs.path.basename(abs_path);
        if (basename.len <= ext.len) return null;

        const name_without_ext = basename[0 .. basename.len - ext.len];
        if (hasScaleSuffix(name_without_ext)) return null;

        // Metro assetResolutions 중 현재 RN asset metadata 모델이 표현하는 정수 scale 후보.
        // base 파일은 위 fileExists에서 이미 확인했으므로 @1x, @2x, @3x, @4x만 순서대로 본다.
        var scale: u32 = 1;
        while (scale <= 4) : (scale += 1) {
            const variant_name = try std.fmt.allocPrint(self.allocator, "{s}@{d}x{s}", .{ name_without_ext, scale, ext });
            defer self.allocator.free(variant_name);
            if (!self.fileExistsIn(dir, variant_name)) continue;

            const variant_path = try std.fs.path.join(self.allocator, &.{ dir, variant_name });
            defer self.allocator.free(variant_path);
            return self.makeResult(variant_path);
        }

        return null;
    }

    pub fn resolve(self: *Resolver, io: std.Io, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        self.io = io;
        // 하위 캐시에도 io 전파 (per-instance; resolve_cache thread-safe 경로는 복사본).
        if (self.dir_cache) |dc| dc.io = io;
        if (self.realpath_cache) |rc| rc.io = io;

        // Vite query-suffix (`./a.txt?raw`, `./w.js?worker`) — 파일시스템을 치기 전에
        // query 를 벗기고, resolve 된 절대경로에 **다시 붙인다** (#4467).
        //
        // query 를 붙인 채로 두는 이유: 같은 파일이라도 query 마다 다른 모듈이어야 한다
        // (`x.png` 는 자산, `x.png?raw` 는 문자열). 모듈 경로가 곧 dedup 키라 query 가
        // 살아 있어야 둘이 갈린다. loader 결정도 이 query 를 읽는다.
        //
        // vue/svelte SFC 의 `?vue&lang.css` 처럼 **알려지지 않은** query 는 건드리지
        // 않는다 — 그쪽은 플러그인이 가상 경로로 처리하는 기존 관용구다.
        if (types.ViteQuery.fromPath(specifier) != null) {
            const bare = types.stripPathQuery(specifier);
            var r = try self.resolveInner(source_dir, bare);
            const suffix = specifier[bare.len..];
            const with_q = std.mem.concat(self.allocator, u8, &.{ r.path, suffix }) catch return error.OutOfMemory;
            self.allocator.free(r.path);
            r.path = with_q;
            return r;
        }

        const result = try self.resolveInner(source_dir, specifier);
        if (self.block_list.len > 0 and !result.disabled) {
            const bl = @import("block_list.zig");
            for (self.block_list) |pat| {
                if (bl.matches(pat, result.path)) {
                    self.allocator.free(result.path);
                    if (result.resolve_dir) |dir| self.allocator.free(dir);
                    return error.ModuleNotFound;
                }
            }
        }
        return result;
    }

    fn resolveInner(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        // 사용자 `--alias` 를 먼저 적용 — CLI 옵션이 tsconfig 보다 우선이라는 원칙.
        // alias 가 치환하면 치환된 specifier 로 계속 (tsconfig paths 는 원본 specifier 로 매칭될 수 없음).
        const effective_specifier = if (self.alias.len > 0)
            (applyAlias(self.allocator, self.alias, specifier) catch return error.OutOfMemory) orelse specifier
        else
            specifier;
        defer if (self.alias.len > 0 and effective_specifier.ptr != specifier.ptr)
            self.allocator.free(effective_specifier);

        // tsconfig paths — alias 미적용 specifier 에 대해서만 의미 있음. alias 가 이미 치환했다면
        // 일반 경로로 continue. (alias 는 보통 절대/상대 경로 리턴이라 ts_paths 와 겹치지 않음)
        if (self.ts_paths.len > 0 and effective_specifier.ptr == specifier.ptr) {
            if (try self.tryTsPaths(specifier)) |r| return r;
        }

        // #specifier → package.json "imports" 필드 (Node.js subpath imports)
        if (effective_specifier.len > 0 and effective_specifier[0] == '#') {
            return self.resolveSubpathImports(source_dir, effective_specifier);
        }

        // bare specifier → node_modules 탐색
        if (!isRelativeOrAbsolute(effective_specifier)) {
            return self.resolveNodeModules(source_dir, effective_specifier) catch |err| {
                if (err == error.ModuleNotFound and self.resolve_symlink_siblings) {
                    if (self.resolveNodeModulesFromRealpath(source_dir, effective_specifier)) |r| return r else |fallback_err| {
                        if (fallback_err != error.ModuleNotFound) return fallback_err;
                    }
                }
                if (err == error.ModuleNotFound and self.node_paths.len > 0) {
                    if (self.resolveNodeModulesFromNodePaths(effective_specifier)) |r| return r else |fallback_err| {
                        if (fallback_err != error.ModuleNotFound) return fallback_err;
                    }
                }
                if (err == error.ModuleNotFound and self.fallback.len > 0) {
                    if (try self.applyFallback(source_dir, effective_specifier)) |r| return r;
                }
                return err;
            };
        }

        // 경로 조합
        const joined = blk: {
            var path_scope = profile.begin(.resolve_path);
            defer path_scope.end();
            break :blk std.fs.path.resolve(self.allocator, &.{ source_dir, effective_specifier }) catch
                return error.OutOfMemory;
        };
        defer self.allocator.free(joined);

        if (try self.tryResolvePathLike(joined)) |result| return result;

        return error.ModuleNotFound;
    }

    /// 확장자를 하나씩 붙여서 존재하는 파일을 찾는다.
    /// custom_extensions가 설정되어 있으면 그것을 사용, 아니면 default_extensions.
    fn tryExtensions(self: *Resolver, base: []const u8) ResolveError!?ResolveResult {
        var scope = profile.begin(.resolve_extensions);
        defer scope.end();

        const extensions = if (self.custom_extensions.len > 0) self.custom_extensions else default_extensions;
        // dir_cache 멤버십 체크는 (dir, name) 으로 한다 — 후보마다 full path 를 alloc 하지 않고
        // basename 만 stack 버퍼에서 조립해 확인, hit 일 때만 full path 를 1회 alloc.
        const dir = std.fs.path.dirname(base) orelse return null;
        const stem = std.fs.path.basename(base);
        var name_buf: [std.fs.max_name_bytes]u8 = undefined;
        for (extensions) |ext| {
            if (stem.len + ext.len > name_buf.len) continue; // NAME_MAX 초과 — 실존 불가
            @memcpy(name_buf[0..stem.len], stem);
            @memcpy(name_buf[stem.len..][0..ext.len], ext);
            if (!self.fileExistsIn(dir, name_buf[0 .. stem.len + ext.len])) continue;

            const path = std.mem.concat(self.allocator, u8, &.{ base, ext }) catch return error.OutOfMemory;
            defer self.allocator.free(path);
            return self.makeResult(path);
        }
        return null;
    }

    /// TS 확장자 매핑: .js → .ts/.tsx 등.
    /// import './foo.js' 했는데 foo.js는 없고 foo.ts가 있으면 foo.ts로 해석.
    fn tryTsExtensionMapping(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        var scope = profile.begin(.resolve_ts_extension_map);
        defer scope.end();

        const ext = std.fs.path.extension(path);
        for (ts_extension_map) |mapping| {
            if (std.mem.eql(u8, ext, mapping.from)) {
                // 확장자를 벗기고 대체 확장자를 붙임
                const base = path[0 .. path.len - ext.len];
                for (mapping.to) |to_ext| {
                    const mapped = std.mem.concat(self.allocator, u8, &.{ base, to_ext }) catch
                        return error.OutOfMemory;
                    defer self.allocator.free(mapped);

                    if (self.fileExists(mapped)) {
                        return self.makeResult(mapped);
                    }
                }
                break;
            }
        }
        return null;
    }

    /// 디렉토리인 경우 index 파일을 탐색한다.
    fn tryDirectoryIndex(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        var scope = profile.begin(.resolve_directory_index);
        defer scope.end();

        // path가 디렉토리인지 확인
        if (!self.dirExists(path)) return null;

        // 디렉토리 내 package.json의 main/module 필드 확인 (서브패스 package.json 패턴)
        // 예: fp-ts/function/package.json → { "main": "../lib/function.js", "module": "../es6/function.js" }
        if (try self.tryDirectoryPackageJson(path)) |result| return result;

        const extensions = if (self.custom_extensions.len > 0) self.custom_extensions else default_extensions;
        // `index<ext>` 후보는 짧으니 stack 버퍼에서 조립 → dir_cache 멤버십만 확인,
        // hit 일 때만 full path 를 1회 alloc (cf. tryExtensions).
        const idx_prefix = "index";
        var name_buf: [std.fs.max_name_bytes]u8 = undefined;
        @memcpy(name_buf[0..idx_prefix.len], idx_prefix);
        for (extensions) |ext| {
            if (idx_prefix.len + ext.len > name_buf.len) continue;
            @memcpy(name_buf[idx_prefix.len..][0..ext.len], ext);
            const index_name = name_buf[0 .. idx_prefix.len + ext.len];
            if (!self.fileExistsIn(path, index_name)) continue;
            const index_path = std.fs.path.resolve(self.allocator, &.{ path, index_name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(index_path);
            return self.makeResult(index_path);
        }
        return null;
    }

    /// package.json 을 캐시(있으면) 또는 직접 read+parse 한다.
    /// 캐시 hit/miss 면 borrowed 포인터 (deinit 금지) + `owned_out` 는 null 그대로.
    /// 캐시 없으면 (테스트 경로) `owned_out` 에 by-value 결과를 두고 그 포인터를 반환 — 호출자가
    /// `owned_out` 의 lifetime/deinit 을 관리. 어느 쪽이든 반환은 `*ParsedPackageJson`.
    fn getPackageJson(
        self: *Resolver,
        dir_path: []const u8,
        owned_out: *?pkg_json.ParsedPackageJson,
    ) pkg_json.PkgJsonCacheError!*pkg_json.ParsedPackageJson {
        var pj_scope = profile.begin(.resolve_resolver_pkg_json);
        defer pj_scope.end();
        if (self.pkg_json_cache) |cache| {
            owned_out.* = null;
            return cache.getOrParse(self.io, dir_path);
        }
        owned_out.* = pkg_json.parsePackageJson(self.allocator, self.io, dir_path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.IoError => return error.IoError,
            error.JsonParseError => return error.JsonParseError,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return &owned_out.*.?;
    }

    /// 디렉토리 내 package.json에서 module/main 필드를 읽어 resolve 시도.
    /// fp-ts 등에서 사용하는 서브패스 package.json 패턴 지원.
    fn tryDirectoryPackageJson(self: *Resolver, dir_path: []const u8) ResolveError!?ResolveResult {
        var pj_owned: ?pkg_json.ParsedPackageJson = null;
        defer if (pj_owned) |*o| o.deinit();
        const parsed = self.getPackageJson(dir_path, &pj_owned) catch return null;
        return self.resolveByMainFields(parsed, dir_path);
    }

    /// package.json의 main_fields 또는 기본 순서(module → main)로 엔트리포인트를 찾는다.
    /// resolvePackage와 tryDirectoryPackageJson에서 공용.
    fn resolveByMainFields(self: *Resolver, parsed: *pkg_json.ParsedPackageJson, base_dir: []const u8) ResolveError!?ResolveResult {
        // R-step1 (RFC #3289): mobx-style cjs main shim 검출 — `dist/index.js` 같은 작은
        // cjs main 이 production conditional require 로 *이미 minified production cjs* 만
        // require 하면 *그쪽이 module field (full source ESM) 보다 훨씬 작은 결과*. esbuild
        // --platform=node default (mainFields=["main"]) 가 자동 처리하던 경로 — zntc 의
        // default (module 우선) 로는 17KB+ 격차 발생 (mobx 71KB vs rolldown 54KB). 검출 시
        // *main 우선*, 아니면 기존 처리.
        if (parsed.pkg.module != null and parsed.pkg.main != null) {
            if (try self.tryCjsMainProductionShim(base_dir, parsed.pkg.main.?)) |result| {
                return result;
            }
        }
        if (self.main_fields.len > 0) {
            const obj = parsed.parsed.value.object;
            for (self.main_fields) |field| {
                if (pkg_json.getStr(obj, field)) |value| {
                    const abs_path = std.fs.path.resolve(self.allocator, &.{ base_dir, value }) catch
                        return error.OutOfMemory;
                    defer self.allocator.free(abs_path);
                    if (self.fileExists(abs_path)) {
                        var result = (try self.makeResult(abs_path)) orelse return null;
                        result.is_module_field = std.mem.eql(u8, field, "module");
                        return result;
                    }
                    if (try self.tryExtensions(abs_path)) |result| return result;
                }
            }
        } else {
            const pkg = &parsed.pkg;
            if (pkg.module) |mod| {
                const abs_path = std.fs.path.resolve(self.allocator, &.{ base_dir, mod }) catch
                    return error.OutOfMemory;
                defer self.allocator.free(abs_path);
                if (self.fileExists(abs_path)) {
                    var result = (try self.makeResult(abs_path)) orelse return null;
                    result.is_module_field = true;
                    return result;
                }
            }
            if (pkg.main) |main| {
                const abs_path = std.fs.path.resolve(self.allocator, &.{ base_dir, main }) catch
                    return error.OutOfMemory;
                defer self.allocator.free(abs_path);
                if (self.fileExists(abs_path)) return self.makeResult(abs_path);
                if (try self.tryExtensions(abs_path)) |result| return result;
            }
        }

        return null;
    }

    /// mobx-style cjs main shim 의 최대 size. 일반적인 production conditional require shim 은
    /// `if (process.env.NODE_ENV === 'production') module.exports = require(...)` 형태로
    /// 200 byte 미만. 1KB 면 충분한 여유 — 큰 cjs main (graphql full bundle 등) 즉시 reject.
    const CJS_SHIM_MAX_SIZE: u64 = 1024;

    /// mobx-style cjs main shim 검출. cjs main file 이 *작고* (< CJS_SHIM_MAX_SIZE)
    /// `process.env.NODE_ENV` 와 `require(...)` 를 모두 포함하면 production conditional
    /// require shim 추정 — main 우선. 매치 안 되면 null 반환 → caller 가 기존 default
    /// (module 우선) fallback. RFC #3289 R-step1 — mobx 17KB 격차 root cause fix.
    fn tryCjsMainProductionShim(self: *Resolver, base_dir: []const u8, main_field: []const u8) ResolveError!?ResolveResult {
        const abs_path = std.fs.path.resolve(self.allocator, &.{ base_dir, main_field }) catch
            return error.OutOfMemory;
        defer self.allocator.free(abs_path);

        // 확장자 fallback — main 이 `dist/index` 같이 확장자 없으면 `.js` 등으로 probe.
        // tryExtensions 결과는 *항상 owned path* (별도 alloc) — borrowed_only flag 로 분기 명확화.
        var resolved_path: []const u8 = abs_path;
        var ext_owned_path: ?[]const u8 = null;
        defer if (ext_owned_path) |p| self.allocator.free(p);
        if (!self.fileExists(abs_path)) {
            const ext_opt = self.tryExtensions(abs_path) catch return null;
            const ext_result = ext_opt orelse return null;
            ext_owned_path = ext_result.path;
            resolved_path = ext_result.path;
        }

        // file size 검사 + read 를 한 번에 — shim 은 작음. 0.16 의 readFileAlloc 는 Limit
        // 초과(큰 cjs main, graphql 등) 시 StreamTooLong → null 로 즉시 reject (구 stat-size
        // 검사 대체). 작은 파일은 그대로 읽어 substring scan.
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, resolved_path, self.allocator, std.Io.Limit.limited(CJS_SHIM_MAX_SIZE)) catch return null;
        defer self.allocator.free(content);

        // production conditional require shim 패턴: `process.env.NODE_ENV` + `require(` 둘 다 등장.
        const has_node_env = std.mem.indexOf(u8, content, "process.env.NODE_ENV") != null;
        const has_require = std.mem.indexOf(u8, content, "require(") != null;
        if (!has_node_env or !has_require) return null;

        return self.makeResult(resolved_path);
    }

    /// bare specifier를 node_modules에서 탐색한다.
    /// source_dir에서 시작하여 상위 디렉토리로 올라가며 node_modules/<pkg>를 찾는다.
    /// NODE_PATH 폴백은 caller (`resolveNodeModulesFromNodePaths`) 가 실패 후 별도로
    /// 실행한다 — `resolve_symlink_siblings` 보다 나중에 동작해 real package 옆
    /// peer dependency 가 전역 .pnpm/node_modules 의 다른 버전보다 우선되게 한다.
    fn resolveNodeModules(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        // 패키지 이름과 서브패스 분리: "@scope/pkg/utils" → ("@scope/pkg", "./utils")
        const split = splitBareSpecifier(specifier);
        const pkg_name = split.pkg_name;
        const subpath = split.subpath;

        // 상위 디렉토리로 올라가며 node_modules 탐색
        var current_dir = source_dir;
        while (true) {
            // node_modules/<pkg>/package.json 시도
            const pkg_dir_path = std.fs.path.resolve(self.allocator, &.{ current_dir, "node_modules", pkg_name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(pkg_dir_path);

            if (self.dirExists(pkg_dir_path)) {
                if (try self.resolvePackage(pkg_dir_path, subpath)) |result| {
                    return result;
                }
            }

            // hierarchical lookup 차단 시 첫 dir 만 탐색.
            if (self.disable_hierarchical_lookup) break;
            // 상위 디렉토리로 이동
            const parent = std.fs.path.dirname(current_dir) orelse break;
            if (std.mem.eql(u8, parent, current_dir)) break; // 루트 도달
            current_dir = parent;
        }

        return error.ModuleNotFound;
    }

    fn resolveNodeModulesFromNodePaths(self: *Resolver, specifier: []const u8) ResolveError!ResolveResult {
        const split = splitBareSpecifier(specifier);
        return self.resolveNodeModulesInNodePaths(split.pkg_name, split.subpath);
    }

    fn resolveNodeModulesInNodePaths(self: *Resolver, pkg_name: []const u8, subpath: []const u8) ResolveError!ResolveResult {
        for (self.node_paths) |np| {
            const pkg_dir_path = std.fs.path.resolve(self.allocator, &.{ np, pkg_name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(pkg_dir_path);

            if (self.dirExists(pkg_dir_path)) {
                if (try self.resolvePackage(pkg_dir_path, subpath)) |result| {
                    return result;
                }
            }
        }

        return error.ModuleNotFound;
    }

    fn resolveNodeModulesFromRealpath(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        // pnpm 처럼 `app/node_modules/pkg` 자체가 symlink 인 경우를 풀어야 한다 —
        // 디렉토리 단위 realpath 캐시는 dirname/basename 분리로 작동하기 때문에
        // 마지막 segment 의 symlink 를 따라가지 않는다. 그래서 캐시를 우회하고 full realpath.
        const real_source_dir = blk: {
            var realpath_scope = profile.begin(.resolve_realpath);
            defer realpath_scope.end();
            break :blk fs.realpath(self.io, self.allocator, source_dir) catch
                self.allocator.dupe(u8, source_dir) catch return error.OutOfMemory;
        };
        defer self.allocator.free(real_source_dir);
        if (std.mem.eql(u8, real_source_dir, source_dir)) return error.ModuleNotFound;
        return self.resolveNodeModules(real_source_dir, specifier);
    }

    /// 패키지 디렉토리에서 엔트리포인트를 해석한다.
    /// 우선순위: exports → module → main → index 파일
    fn resolvePackage(self: *Resolver, pkg_dir_path: []const u8, subpath: []const u8) ResolveError!?ResolveResult {
        // package.json 파싱 시도 (캐시 통과)
        var pj_owned: ?pkg_json.ParsedPackageJson = null;
        defer if (pj_owned) |*o| o.deinit();
        const parsed = self.getPackageJson(pkg_dir_path, &pj_owned) catch |err| switch (err) {
            // package.json 없으면 index 파일 탐색
            error.FileNotFound => return self.tryDirectoryIndex(pkg_dir_path),
            else => return null,
        };

        const pkg = &parsed.pkg;

        // 1. exports 필드 (D064)
        // subpath: "." 또는 "/sub" → exports 매칭용 "." 또는 "./sub"
        const allocated_subpath: ?[]const u8 = if (std.mem.eql(u8, subpath, "."))
            null
        else
            std.mem.concat(self.allocator, u8, &.{ ".", subpath }) catch return error.OutOfMemory;
        defer if (allocated_subpath) |buf| self.allocator.free(buf);
        const exports_subpath = allocated_subpath orelse subpath;

        if (pkg.exports) |exports| {
            const exports_match = blk: {
                var ex_scope = profile.begin(.resolve_resolver_exports);
                defer ex_scope.end();
                break :blk pkg_json.resolveExports(self.allocator, exports, exports_subpath, self.conditions);
            };
            if (exports_match) |exports_result| {
                // (#3981) 매칭된 조건/패턴 target 이 명시적 null → 해석 차단.
                // main fields/index 폴백 없이 not-found (Node ERR_PACKAGE_PATH_NOT_EXPORTED).
                if (exports_result.blocked) return null;
                defer if (exports_result.allocated) self.allocator.free(exports_result.path);
                const abs_path = std.fs.path.resolve(self.allocator, &.{ pkg_dir_path, exports_result.path }) catch
                    return error.OutOfMemory;
                defer self.allocator.free(abs_path);

                if (self.fileExists(abs_path)) {
                    return self.makeResult(abs_path);
                }
                // exports가 가리키는 파일이 없으면 확장자 탐색
                if (try self.tryExtensions(abs_path)) |result| return result;
            }
            // exports가 있는데 매칭 안 되면 다른 필드로 폴백하지 않음 (Node.js 스펙)
            if (!std.mem.eql(u8, subpath, ".")) return null;
        }

        // 서브패스가 있으면 패키지 내부 파일 직접 해석
        // subpath는 "/shams" 형태 (leading /) — resolve()는 절대 경로로 취급하므로
        // leading /를 제거하여 상대 경로로 만든다.
        if (!std.mem.eql(u8, subpath, ".")) {
            const relative_subpath = if (subpath.len > 0 and subpath[0] == '/') subpath[1..] else subpath;
            const sub_file = std.fs.path.resolve(self.allocator, &.{ pkg_dir_path, relative_subpath }) catch
                return error.OutOfMemory;
            defer self.allocator.free(sub_file);

            if (self.fileExists(sub_file)) return self.makeResult(sub_file);
            if (try self.tryExtensions(sub_file)) |result| return result;
            if (try self.tryTsExtensionMapping(sub_file)) |result| return result;
            if (try self.tryDirectoryIndex(sub_file)) |result| return result;
            return null;
        }

        if (try self.resolveByMainFields(parsed, pkg_dir_path)) |result| return result;

        // 4. index 파일 폴백
        return self.tryDirectoryIndex(pkg_dir_path);
    }

    /// Node.js subpath imports: `#specifier`를 package.json "imports" 필드에서 해석한다.
    /// source_dir에서 시작하여 상위 디렉토리로 올라가며 "imports" 필드가 있는 package.json을 찾는다.
    /// https://nodejs.org/api/packages.html#subpath-imports
    fn resolveSubpathImports(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        var current_dir = source_dir;
        while (true) {
            if (pkg_json.parsePackageJson(self.allocator, self.io, current_dir)) |*parsed_result| {
                var parsed = parsed_result.*;
                defer parsed.deinit();

                if (parsed.pkg.imports) |imports| {
                    if (pkg_json.resolveImports(self.allocator, imports, specifier, self.conditions)) |imports_result| {
                        // (#3981) 매칭된 imports 조건 target 이 null → 차단(not-found).
                        if (imports_result.blocked) return error.ModuleNotFound;
                        defer if (imports_result.allocated) self.allocator.free(imports_result.path);

                        // imports 결과는 패키지 디렉토리 기준 상대 경로
                        const abs_path = std.fs.path.resolve(self.allocator, &.{ current_dir, imports_result.path }) catch
                            return error.OutOfMemory;
                        defer self.allocator.free(abs_path);

                        if (self.fileExists(abs_path)) {
                            return (try self.makeResult(abs_path)).?;
                        }
                        // 확장자 탐색
                        if (try self.tryExtensions(abs_path)) |result| return result;
                        if (try self.tryTsExtensionMapping(abs_path)) |result| return result;
                        if (try self.tryDirectoryIndex(abs_path)) |result| return result;
                    }
                }
            } else |_| {}

            // 상위 디렉토리로 이동
            const parent = std.fs.path.dirname(current_dir) orelse break;
            if (std.mem.eql(u8, parent, current_dir)) break;
            current_dir = parent;
        }

        return error.ModuleNotFound;
    }

    fn makeResult(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        // preserve_symlinks=true → 기본은 link path 를 module identity 와 1차 resolve
        // 기준으로 그대로 사용한다. 단 RN/pnpm 에서는 같은 실제 패키지가
        // app/node_modules/<pkg> 와 .pnpm/<peer>/node_modules/<pkg> 두 symlink 로
        // 들어오며 native module init 이 중복될 수 있다. Metro 는 이 케이스를 실제
        // .pnpm package path 하나로 보므로, pnpm package symlink 로 확인되는 경우만
        // identity 를 realpath 로 정규화한다. workspace symlink 는 real target 이
        // .pnpm package root 가 아니므로 logical path 를 유지한다.
        // false → bun(.bun/) / pnpm(.pnpm/) 의 symlink 를 realpath 로 해석해 중첩 node_modules
        // 탐색이 올바른 계층에서 동작하게 한다.
        const resolved = blk: {
            var realpath_scope = profile.begin(.resolve_realpath);
            defer realpath_scope.end();
            if (self.preserve_symlinks) {
                if (self.resolve_symlink_siblings and std.mem.indexOf(u8, path, "node_modules") != null) {
                    const real_path = if (self.realpath_cache) |cache|
                        cache.resolve(path) catch return error.OutOfMemory
                    else
                        fs.realpath(self.io, self.allocator, path) catch
                            self.allocator.dupe(u8, path) catch return error.OutOfMemory;

                    if (shouldCanonicalizePnpmPackageSymlink(path, real_path)) {
                        break :blk real_path;
                    }
                    self.allocator.free(real_path);
                }
                break :blk self.allocator.dupe(u8, path) catch return error.OutOfMemory;
            }
            if (self.realpath_cache) |cache| {
                break :blk cache.resolve(path) catch
                    self.allocator.dupe(u8, path) catch return error.OutOfMemory;
            }
            break :blk fs.realpath(self.io, self.allocator, path) catch
                self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        };
        errdefer self.allocator.free(resolved);
        const resolve_dir = if (self.preserve_symlinks and
            self.resolve_symlink_siblings and
            shouldUseRealResolveDirForLogicalPath(path))
            try self.realResolveDirForLogicalPath(path, resolved)
        else
            null;
        errdefer if (resolve_dir) |dir| self.allocator.free(dir);
        const ext = std.fs.path.extension(resolved);
        return .{
            .path = resolved,
            .module_type = ModuleType.fromExtension(ext),
            .resolve_dir = resolve_dir,
        };
    }

    fn shouldUseRealResolveDirForLogicalPath(path: []const u8) bool {
        return std.mem.indexOf(u8, path, ".pnpm/node_modules/") != null or
            std.mem.indexOf(u8, path, ".pnpm\\node_modules\\") != null;
    }

    fn realResolveDirForLogicalPath(self: *Resolver, path: []const u8, logical_path: []const u8) ResolveError!?[]const u8 {
        const real_path = blk: {
            var realpath_scope = profile.begin(.resolve_realpath);
            defer realpath_scope.end();
            if (self.realpath_cache) |cache| {
                break :blk cache.resolve(path) catch return error.OutOfMemory;
            }
            break :blk fs.realpath(self.io, self.allocator, path) catch
                self.allocator.dupe(u8, path) catch return error.OutOfMemory;
        };
        defer self.allocator.free(real_path);

        if (std.mem.eql(u8, real_path, logical_path)) return null;
        const real_dir = std.fs.path.dirname(real_path) orelse return null;
        const logical_dir = std.fs.path.dirname(logical_path) orelse return null;
        if (std.mem.eql(u8, real_dir, logical_dir)) return null;
        return self.allocator.dupe(u8, real_dir) catch return error.OutOfMemory;
    }

    fn fileExists(self: *const Resolver, path: []const u8) bool {
        const dir_path = std.fs.path.dirname(path) orelse return false;
        const file_name = std.fs.path.basename(path);
        return self.fileExistsIn(dir_path, file_name);
    }

    /// `dir_path` 안에 `file_name` 이 있는지. 후보 확장자 탐색 등에서 full path 를 매번
    /// alloc 했다가 `fileExists` 가 다시 dirname/basename 으로 쪼개던 낭비를 피한다 — caller 가
    /// dir + name 을 직접 넘긴다. (DirEntryCache 자체가 dir 단위 readdir 캐시라 이게 자연스럽다.)
    fn fileExistsIn(self: *const Resolver, dir_path: []const u8, file_name: []const u8) bool {
        var scope = profile.begin(.resolve_file_exists);
        defer scope.end();
        if (file_name.len == 0) return false;
        var audit = debug_log.auditScope(.resolve_audit);
        const result: bool = if (self.dir_cache) |cache|
            @constCast(cache).hasFile(dir_path, file_name)
        else blk: {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const joined = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ dir_path, std.fs.path.sep, file_name }) catch break :blk false;
            const stat = fs.statFile(self.io, joined) catch break :blk false;
            break :blk stat.kind == .file;
        };
        if (audit.on) debug_log.print(.resolve_audit, "exists cache={d} hit={d} dir_len={d} name_len={d} ns={d}\n", .{ @intFromBool(self.dir_cache != null), @intFromBool(result), dir_path.len, file_name.len, audit.elapsedNs() });
        return result;
    }

    fn dirExists(self: *const Resolver, path: []const u8) bool {
        if (self.dir_cache) |cache| {
            return @constCast(cache).dirExists(path);
        }
        const stat = fs.statFile(self.io, path) catch return false;
        return stat.is_dir;
    }
};

/// specifier가 상대 경로(`./`, `../`) 또는 절대 경로(`/`)인지 판별.
pub fn isRelativeOrAbsolute(specifier: []const u8) bool {
    if (specifier.len == 0) return false;
    if (specifier[0] == '/') return true;
    if (specifier.len == 1 and specifier[0] == '.') return true;
    // "./" — 현재 디렉토리 상대
    if (specifier.len >= 2 and specifier[0] == '.' and specifier[1] == '/') return true;
    // "../" — 상위 디렉토리 상대. ".." 뒤에 / 또는 끝이어야 함 ("..foo"는 bare specifier)
    if (specifier.len >= 2 and specifier[0] == '.' and specifier[1] == '.') {
        if (specifier.len == 2) return true; // ".." 그 자체
        if (specifier[2] == '/') return true; // "../..."
    }
    return false;
}

/// bare specifier를 패키지 이름과 서브패스로 분리한다.
/// "react" → ("react", ".")
/// "react/jsx-runtime" → ("react", "./jsx-runtime")
/// "@mui/material" → ("@mui/material", ".")
/// "@mui/material/Button" → ("@mui/material", "./Button")
const BareSpecifierSplit = struct {
    pkg_name: []const u8,
    subpath: []const u8,
};

pub fn splitBareSpecifier(specifier: []const u8) BareSpecifierSplit {
    if (specifier.len == 0) return .{ .pkg_name = specifier, .subpath = "." };

    // scoped package: @scope/name/subpath
    if (specifier[0] == '@') {
        if (std.mem.indexOfScalar(u8, specifier, '/')) |first_slash| {
            // 두 번째 / 를 찾으면 그 뒤가 서브패스
            if (std.mem.indexOfScalarPos(u8, specifier, first_slash + 1, '/')) |second_slash| {
                if (second_slash == specifier.len - 1) {
                    return .{
                        .pkg_name = specifier[0..second_slash],
                        .subpath = ".",
                    };
                }
                return .{
                    .pkg_name = specifier[0..second_slash],
                    .subpath = specifier[second_slash..],
                };
            }
        }
        return .{ .pkg_name = specifier, .subpath = "." };
    }

    // 일반 패키지: name/subpath
    if (std.mem.indexOfScalar(u8, specifier, '/')) |slash| {
        if (slash == specifier.len - 1) {
            return .{
                .pkg_name = specifier[0..slash],
                .subpath = ".",
            };
        }
        return .{
            .pkg_name = specifier[0..slash],
            .subpath = specifier[slash..],
        };
    }

    return .{ .pkg_name = specifier, .subpath = "." };
}
