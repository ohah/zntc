//! 증분 빌드 — dev server용
//!
//! 전체 재번들 대신 변경된 모듈만 재파싱+재변환+재emit하여 HMR 속도를 개선한다.
//!
//! 전략:
//!   1. 첫 번들: 전체 빌드, 결과(모듈별 코드)를 캐싱
//!   2. 파일 변경: 해당 모듈만 재빌드, 나머지는 캐시 사용
//!   3. 새 import 추가 시: 전체 재빌드 폴백 (그래프 구조 변경)

const std = @import("std");
const Bundler = @import("bundler.zig").Bundler;
const BundleResult = @import("bundler.zig").BundleResult;
const BundleOptions = @import("bundler.zig").BundleOptions;
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const module_store = @import("module_store.zig");
const CompiledModule = @import("compiled_module.zig").CompiledModule;
const CompiledOutputCache = @import("compiled_cache.zig").CompiledOutputCache;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const PreservedRenames = @import("symbol.zig").PreservedRenames;

/// JSON 문자열 값 내부의 특수 문자를 이스케이프한다 (RFC 8259 준수).
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{@as(u16, c)});
            } else {
                try writer.writeByte(c);
            },
        }
    }
}

/// BundleResult의 에러 진단을 JSON 문자열로 변환한다.
fn buildErrorJson(allocator: std.mem.Allocator, result: *const BundleResult) ?[]const u8 {
    const diags = result.getDiagnostics();
    // 0.16: ArrayList.writer 제거 → Io.Writer.Allocating. catch-return-null 경로라
    // errdefer 가 동작 안 하므로 defer deinit + buffered() dupe.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    w.print("{{\"type\":\"error\",\"errors\":[", .{}) catch return null;
    for (diags, 0..) |d, i| {
        if (i > 0) w.print(",", .{}) catch {};
        w.print("{{\"file\":\"", .{}) catch return null;
        writeJsonEscaped(w, d.file_path) catch return null;
        w.print("\",\"message\":\"", .{}) catch return null;
        writeJsonEscaped(w, d.message) catch return null;
        w.print("\"}}", .{}) catch return null;
    }
    w.print("]}}", .{}) catch return null;
    return allocator.dupe(u8, aw.writer.buffered()) catch null;
}

/// 증분 dev 번들러. 모듈별 코드를 캐싱하여 변경 시 부분 재빌드.
/// 파싱 캐시(PersistentModuleStore)와 resolve 캐시(ResolveCache)를 빌드 간 보존하여
/// 변경되지 않은 모듈의 재파싱을 스킵한다.
pub const IncrementalBundler = struct {
    allocator: std.mem.Allocator,
    options: BundleOptions,

    /// 캐시된 모듈별 dev code (module_id → __zntc_register code)
    module_cache: std.StringHashMapUnmanaged(CachedModule) = .empty,
    /// 마지막 번들의 모듈 경로 목록
    last_paths: ?[]const []const u8 = null,
    /// 전체 재빌드가 필요한지 (첫 빌드 또는 그래프 변경)
    needs_full_rebuild: bool = true,

    /// 모듈 파싱 캐시 (장기 보존). 변경 안 된 모듈의 AST/semantic을 빌드 간 재사용.
    persistent_store: module_store.PersistentModuleStore,
    /// resolve 캐시 (장기 보존). dir_cache 포함.
    resolve_cache: ?ResolveCache = null,
    /// Compiled output cache — 변경 안 된 모듈의 emit 결과를 빌드 간 보존.
    /// 첫 빌드 시엔 mtime 이 아직 Module 에 주입되지 않아 miss 만 발생 (B3 에서 확장).
    compiled_cache: CompiledOutputCache,

    /// (#3751) `rebuild_reset_interval` 마다 `resolve_cache` 를 deinit + 재생성.
    /// `PathInternPool.arena` 가 monotonic — file rename / 임시 .ts→.tsx / dynamic
    /// import 패턴 → 옛 path 가 영원히 arena 에 남아 장기 watch (30+ 분) 후 RSS 단방향
    /// 증가. Phase 3 (#3749) 후 `PersistentModuleStore` 가 `PathRef.owned` 으로
    /// self-clone 하므로 reset 안전.
    rebuild_count: usize = 0,
    /// reset 주기. test 가 override 가능. 0 = reset 비활성.
    rebuild_reset_interval: usize = 100,

    /// RFC #3933 Sub-PR-B.2 — opt-in persistent ModuleGraph.
    /// true 면 첫 빌드 시 graph 를 init + 이후 rebuild 가 같은 graph 재사용 (Bundler.initWithGraph).
    /// graph 의 reset/invalidate 호출자 wire-up 까진 Sub-PR-B.3 — 본 PR 에서는 default false
    /// 라 영향 0 (기존 path, 매 빌드 graph init/deinit). `ZNTC_INCREMENTAL_PERSIST=1` env
    /// 또는 dev_server 가 명시 set 으로 opt-in. 환경별 통합은 후속 PR.
    enable_persistence: bool = false,
    /// `enable_persistence=true` 일 때 첫 빌드부터 init + 이후 빌드 간 보존되는 ModuleGraph.
    /// `deinit` 가 일괄 해제. caller 는 직접 접근 금지 — `doBuild` 만이 lifetime 관리.
    persistent_graph: ?ModuleGraph = null,

    /// HMR rename 재사용 스냅샷 (perf/hmr-link-rename-reuse). 초기 빌드(또는 가드
    /// fallback 빌드)가 만든 rename_table 보존본을 빌드 간 유지했다가, 다음 HMR rebuild
    /// 의 `computeRenames` 를 skip 하는 데 쓴다. `deinit`/`reset`/`needs_full_rebuild` 에서
    /// drop. arena 소유라 `deinit()` 한 번이 일괄 해제.
    preserved_renames: ?PreservedRenames = null,

    /// 모듈 단위 dev/HMR 캐시 엔트리.
    /// `code` = `__zntc_register` wrapper (HMR 경로).
    /// `compiled` / `input_hash` = compiled output cache 재사용용 (populate 는 별도 PR).
    const CachedModule = struct {
        id: []const u8,
        code: []const u8,
        compiled: ?CompiledModule = null,
        input_hash: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, options: BundleOptions) IncrementalBundler {
        return .{
            .allocator = allocator,
            .options = options,
            .module_cache = .empty,
            .persistent_store = module_store.PersistentModuleStore.init(allocator),
            .compiled_cache = CompiledOutputCache.init(allocator),
        };
    }

    pub fn deinit(self: *IncrementalBundler) void {
        self.clearCache();
        self.module_cache.deinit(self.allocator);
        self.persistent_store.deinit();
        self.compiled_cache.deinit();
        if (self.resolve_cache) |*rc| rc.deinit();
        if (self.persistent_graph) |*g| g.deinit();
        if (self.preserved_renames) |*pr| pr.deinit();
    }

    /// 외부에서 캐시 전체 무효화 (Control API `/reset-cache` 등).
    /// 다음 rebuild()는 초기 빌드와 동일한 전체 재번들.
    /// (#3751) `resolve_cache` 와 `rebuild_count` 도 reset — 자동 reset 과 대칭.
    /// 사용자가 RSS 증가를 이유로 수동 reset 호출 시 path_pool arena 가 해제되지
    /// 않는 비대칭을 차단 (/code-review max Angle B + E finding).
    pub fn reset(self: *IncrementalBundler) void {
        self.clearCache();
        self.persistent_store.deinit();
        self.persistent_store = module_store.PersistentModuleStore.init(self.allocator);
        self.compiled_cache.clear();
        if (self.resolve_cache) |*rc| {
            rc.deinit();
            self.resolve_cache = null;
        }
        self.rebuild_count = 0;
        self.needs_full_rebuild = true;
        // 보존 스냅샷도 drop — 다음 빌드는 초기 빌드처럼 from-scratch deconflict 후 재캡처.
        if (self.preserved_renames) |*pr| {
            pr.deinit();
            self.preserved_renames = null;
        }
    }

    fn clearCache(self: *IncrementalBundler) void {
        var it = self.module_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.value_ptr.code);
            if (entry.value_ptr.compiled) |c| c.deinit(self.allocator);
        }
        self.module_cache.clearRetainingCapacity();

        if (self.last_paths) |paths| {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
        }
        self.last_paths = null;
    }

    /// 증분 번들. caller 가 변경 path 를 모를 때 (initial build 등).
    /// 그래프 변경(새 import 추가 등)이 감지되면 자동으로 전체 재빌드 폴백.
    pub fn rebuild(self: *IncrementalBundler, io: std.Io) !RebuildResult {
        return self.rebuildWithChanges(io, null);
    }

    /// `rebuild` 의 watcher-driven 변형. caller (dev_server / NAPI) 가 알아챈
    /// 변경 path set 을 그대로 graph 에 전달. NAPI watch (packages/core/src/napi/watch.zig:1135)
    /// 와 동일 패턴. 큰 graph 에서 graph_discover 의 stat syscall 누적을 우회.
    pub fn rebuildWithChanges(
        self: *IncrementalBundler,
        io: std.Io,
        changed_files: ?*const std.StringHashMapUnmanaged(void),
    ) !RebuildResult {
        if (self.needs_full_rebuild) {
            return self.doBuild(io, true, changed_files);
        }
        return self.doBuild(io, false, changed_files);
    }

    fn doBuild(
        self: *IncrementalBundler,
        io: std.Io,
        is_first: bool,
        changed_files: ?*const std.StringHashMapUnmanaged(void),
    ) !RebuildResult {
        // (#3751) N rebuild 마다 resolve_cache reset — arena monotonic growth 차단.
        // 빌드 *사이* 에서만 실행 (in-flight CachedResolvedDep 가 모두 store 로 owned-clone
        // 된 상태).
        //
        // is_first 가드 없이 `resolve_cache != null` 만 검사 — review Angle B/E finding:
        // build_error → needs_full_rebuild=true 패턴에서 다음 rebuild 가 is_first=true 라
        // `!is_first` 가드를 쓰면 영원히 reset skip 가능. resolve_cache 존재 여부로만
        // 판단해야 cold/warm 무관하게 N 마다 trigger 됨.
        if (self.resolve_cache != null and self.rebuild_reset_interval > 0 and
            self.rebuild_count >= self.rebuild_reset_interval)
        {
            if (self.resolve_cache) |*rc| {
                rc.deinit();
                self.resolve_cache = null;
            }
            self.rebuild_count = 0;
        }

        // resolve_cache 초기화 (첫 빌드 시 또는 위 reset 직후) 또는 재사용
        if (self.resolve_cache == null) {
            self.resolve_cache = Bundler.initResolveCacheFromOptions(self.allocator, self.options);
        }

        // 증분 빌드: 첫 빌드가 아니면 module_store 를 전달하여 파싱 캐시 활용.
        // compiled_cache 는 매 빌드 주입 — miss 는 안전하게 폴백 (emit 경로가 cache 없을 때와 동일).
        var opts = self.options;
        opts.compiled_cache = &self.compiled_cache;

        // NAPI watch.zig:823-1142 의 dev_mode 최적화 패키지 양도. 같은 invariant
        // (HMR client 는 module_dev_codes 만 소비) 가 web dev_server 에도 성립.
        // - initial: lazy sourcemap finalize (initial output 은 필요하므로 skip_bundle_output 미적용)
        // - incremental: skip_bundle_output 으로 emit_concat (~38ms) + emit_sourcemap_finalize
        //   (~19ms) 절감. dev_codes 만 broadcast 하는 dev_server.buildHmrUpdateFromModules
        //   와 호환.
        //
        // dev_mode 자체가 *개발용 빠른 빌드* 의지 → caller 가 dev_mode=true 면 자동 최적화
        // 적용. caller 가 eager sourcemap / full bundle output 원하면 dev_mode=false 사용.
        //
        // **dev_server 사용자 주의 (latent)**: sourcemap.lazy 는 result.sourcemap (eager JSON)
        // 대신 result.sourcemap_builder 만 채움. dev_server 가 sourcemap_builder 를 소비하지
        // 않으면 (`/bundle.js.map` 라우트) sourcemap.enable 켜는 순간 404. 현재 dev_server.zig
        // 가 sourcemap.enable=false default 라 dormant — sourcemap 활성화 시 sourcemap_builder
        // wire-up 또는 lazy 비활성화 follow-up 필수.
        if (opts.dev_mode and opts.sourcemap.enable) opts.sourcemap.lazy = true;
        // perf/hmr-link-rename-reuse: dev 빌드는 항상 rename 재사용에 *참여* 한다.
        // - 초기 빌드: reuse_renames=true 지만 skip_bundle_output=false 라 bundler 가 inject 는
        //   막고 스냅샷 capture 만 한다 (BundleResult.rename_snapshot 으로 반환).
        // - HMR rebuild: preserved_renames 를 주입 → bundler 가 가드 통과 시 computeRenames skip.
        opts.reuse_renames = opts.dev_mode and opts.collect_module_codes;
        if (!is_first) {
            opts.module_store = &self.persistent_store;
            opts.changed_files = changed_files;
            if (opts.dev_mode and opts.collect_module_codes) opts.skip_bundle_output = true;
            if (self.preserved_renames) |*pr| opts.preserved_renames = pr;
        }

        // RFC #3933 Sub-PR-B.2 + perf/hmr-graph-topology-reuse Phase A — enable_persistence
        // opt-in path. Bundler.initWithGraph wire-up.
        //
        // **Phase A 의미**: persistent_graph 를 빌드 *간* 보존한다(매 빌드 deinit/재init 폐기).
        // 첫 빌드는 init, 이후 빌드는 같은 graph 를 재사용 — bundle() 의 external_graph 훅
        // (bundler.zig)이 빌드 직전 `prepareForPreservedRebuild` 로 모듈을 비워 fresh 와
        // byte-identical 출력을 보장한다(graph struct/backing/path_arena 재사용 → 객체 수명
        // 안정 + alloc 절감). 위상 보존(edge/exec_index 재사용)은 transferModulesToStore
        // 소유권 재설계가 필요해 Phase B 로 분리.
        //
        // **정확성 가드**: graph_changed(아래 pathSetsEqual)가 위상 변화(모듈 추가/삭제)를
        // 감지하면 그 빌드 자체는 prepareForPreservedRebuild 로 fresh discovery 라 정확하다.
        // (Phase B 의 selective edge-reuse 도입 시 여기서 추가 fallback 가드가 필요.)
        var bundler = blk: {
            if (!self.enable_persistence) break :blk Bundler.initWithResolveCache(self.allocator, opts, &self.resolve_cache.?);
            if (self.persistent_graph == null) {
                self.persistent_graph = ModuleGraph.init(self.allocator, &self.resolve_cache.?);
            }
            break :blk Bundler.initWithGraph(self.allocator, opts, &self.resolve_cache.?, &self.persistent_graph.?);
        };
        defer bundler.deinit(); // resolve_cache_external=true이므로 resolve_cache는 해제 안 됨

        // RFC #3940 Sub-PR-L.0b — bundle 직후 profile snapshot 캡처 (ZNTC_PROFILE 활성 시).
        // caller (dev_server) 가 SSE event payload 또는 NAPI watch callback 에 포함.
        // counter reset 은 다음 build 측정 위해 즉시. snapshot 은 cheap (atomic load N회).
        //
        // /code-review max followup #2 fix: bundle() catch return .fatal 이 reset 을 skip
        // 하면 다음 성공 build snapshot 이 실패 build 의 partial 누적값과 섞여 측정 오염.
        // anyEnabled() 를 한 번 캐싱 후 fatal/success 모든 경로에서 reset 보장.
        const _profile = @import("../profile.zig");
        const profile_was_enabled = _profile.anyEnabled();
        var result = bundler.bundle(io) catch {
            if (profile_was_enabled) _profile.resetCounters();
            return .fatal;
        };
        const profile_snapshot: ?_profile.ProfileSnapshot = if (profile_was_enabled)
            _profile.takeSnapshot()
        else
            null;
        if (profile_was_enabled) _profile.resetCounters();

        if (result.hasErrors()) {
            const err_json = buildErrorJson(self.allocator, &result) orelse {
                result.deinit(self.allocator);
                return .fatal;
            };
            result.deinit(self.allocator);
            // 빌드 에러 후엔 다음 rebuild 를 full rebuild 로 강제. 그렇지 않으면 broken
            // module 이 persistent_store 에 캐시된 채 남아, 같은 broken 파일에 대한
            // 다음 incremental rebuild 가 cache hit → `result.hasErrors()` false → `.success`
            // (changed_modules=0) 로 잘못 보고하고, dev server 가 overlay 를 clear 해버린다.
            // 파일이 고쳐지면 full rebuild 가 에러 없이 끝나며 doBuild 의 `if (is_first)`
            // 분기에서 flag 가 자동 해제된다.
            self.needs_full_rebuild = true;
            // 보존 스냅샷도 drop — full rebuild 가 from-scratch 재캡처. stale 스냅샷이
            // 고친 후 첫 빌드에 잘못 주입되는 일 방지.
            if (self.preserved_renames) |*pr| {
                pr.deinit();
                self.preserved_renames = null;
            }
            return .{ .build_error = err_json };
        }

        // perf/hmr-link-rename-reuse: 새 스냅샷이 캡처됐으면(초기/fallback 빌드) 교체.
        // 재사용-hit 빌드는 result.rename_snapshot=null 이라 기존 스냅샷 유지. result.deinit
        // 이 arena 를 해제하기 전에 move out (소유권 이전).
        //
        // F5: result.rename_snapshot 이 null 인 경우는 두 가지로 갈린다 —
        //  - reuse-hit: 새 deconflict 없음 → 기존 보존본 유지 (아래 두 분기 모두 skip).
        //  - invalidated: fallback 재계산했으나 buildRenameSnapshot 이 불완전 스냅샷을
        //    폐기 → 기존(stale) 보존본을 **drop**. 안 그러면 stale 이 다음 reuse-hit 에
        //    잘못 주입(silent wrong-binding). "fallback 했는데 capture 실패 = preserved 없음"
        //    상태가 일관되도록 보장한다.
        if (result.rename_snapshot) |new_snap| {
            if (self.preserved_renames) |*pr| pr.deinit();
            self.preserved_renames = new_snap;
            result.rename_snapshot = null; // double-free 방지 (result.deinit 가 안 건드리게)
        } else if (result.rename_snapshot_invalidated) {
            if (self.preserved_renames) |*pr| {
                pr.deinit();
                self.preserved_renames = null;
            }
        }

        const graph_changed = is_first or !self.pathSetsEqual(result.module_paths);

        // 그래프 구조 변경 (모듈 추가/제거) 시 compiled_cache 전체 무효화.
        // 삭제된 경로 엔트리가 stale 하게 남지 않도록 — 단순히 path 필터로 부분 정리하는
        // 최적화는 follow-up. is_first 일 때는 cache 가 비어있어 no-op.
        if (graph_changed and !is_first) self.compiled_cache.clear();

        // 변경된 모듈 코드만 수집 (캐시 대비 diff)
        var actually_changed: std.ArrayList(BundleResult.ModuleDevCode) = .empty;
        defer actually_changed.deinit(self.allocator);

        if (!is_first) {
            if (result.module_dev_codes) |new_codes| {
                try actually_changed.ensureTotalCapacity(self.allocator, new_codes.len);

                for (new_codes) |nc| {
                    if (!nc.changed) continue; // cache hit(id-only, 빈 code) — changed_modules 제외
                    const cached = self.module_cache.get(nc.id);
                    const code_changed = if (cached) |c| !std.mem.eql(u8, c.code, nc.code) else true;
                    if (!code_changed) continue;
                    // id/code/map 을 dupe — result.deinit 후에도 slice 가 유효해야 함.
                    // ownership 은 caller 에게 넘어간다 (BundleResult.ModuleDevCode.freeAll 호출 필수).
                    const id_copy = self.allocator.dupe(u8, nc.id) catch continue;
                    const code_copy = self.allocator.dupe(u8, nc.code) catch {
                        self.allocator.free(id_copy);
                        continue;
                    };
                    const map_copy: ?[]const u8 = if (nc.map) |m| self.allocator.dupe(u8, m) catch {
                        self.allocator.free(id_copy);
                        self.allocator.free(code_copy);
                        continue;
                    } else null;
                    actually_changed.appendAssumeCapacity(.{
                        .id = id_copy,
                        .code = code_copy,
                        .map = map_copy,
                    });
                }
            }
        }

        self.updateCache(&result);
        if (is_first) self.needs_full_rebuild = false;
        // (#3751) reset interval 카운터 — 빌드 *완료* 후 증가. error/fatal 경로는 카운트
        // 안 함 (broken state 가 reset 시점을 좌우하지 않도록).
        self.rebuild_count += 1;

        self.compiled_cache.logStats(if (is_first) "first=true " else "first=false ");

        result.deinit(self.allocator);

        return .{
            .success = .{
                .paths = self.last_paths orelse &.{},
                .changed_modules = try actually_changed.toOwnedSlice(self.allocator),
                .graph_changed = graph_changed,
                .profile_snapshot = profile_snapshot,
            },
        };
    }

    /// 빌드 결과의 모듈 경로 집합이 캐시와 동일한지 비교 (#951).
    /// 카운트만 비교하면 빌드 경로 차이로 false positive가 발생할 수 있다.
    fn pathSetsEqual(self: *const IncrementalBundler, new_paths_opt: ?[]const []const u8) bool {
        const old_paths = self.last_paths orelse return new_paths_opt == null;
        const new_paths = new_paths_opt orelse return false;

        if (old_paths.len != new_paths.len) return false;

        // old_paths를 해시셋에 넣고 new_paths 전부가 존재하는지 확인
        var set: std.StringHashMapUnmanaged(void) = .empty;
        defer set.deinit(self.allocator);
        set.ensureTotalCapacity(self.allocator, @intCast(old_paths.len)) catch return false;
        for (old_paths) |p| {
            set.putAssumeCapacity(p, {});
        }
        for (new_paths) |p| {
            if (!set.contains(p)) return false;
        }
        return true;
    }

    fn updateCache(self: *IncrementalBundler, result: *const BundleResult) void {
        // last_paths 는 매 빌드 새 module_paths 로 교체(기존 동작). module_cache 는 아래에서
        // changed 선택 갱신하므로 clearCache(전체 비움) 대신 last_paths 만 직접 교체한다.
        if (self.last_paths) |paths| {
            for (paths) |p| self.allocator.free(p);
            self.allocator.free(paths);
            self.last_paths = null;
        }
        if (result.module_paths) |paths| {
            const copied = self.allocator.alloc([]const u8, paths.len) catch {
                self.needs_full_rebuild = true;
                return;
            };
            for (paths, 0..) |p, i| {
                copied[i] = self.allocator.dupe(u8, p) catch "";
            }
            self.last_paths = copied;
        }

        // module_cache 정합: dev_codes 는 변경분(changed=true, 새 code) + cache hit(changed=false,
        // 빈 placeholder)의 합집합이다. hit 의 빈 code 로 캐시를 덮으면 다음 rebuild 의 diff 비교가
        // 깨져(phantom update) 안 변한 모듈이 changed_modules 에 섞이므로, 키 정합 + changed 선택
        // 갱신으로 hit 모듈의 기존 실제 code 를 유지한다.
        if (result.module_dev_codes) |codes| {
            // 1) dev_codes 에 없는 키 제거 — 모듈 삭제 반영.
            var live: std.StringHashMapUnmanaged(void) = .empty;
            defer live.deinit(self.allocator);
            for (codes) |c| live.put(self.allocator, c.id, {}) catch {};
            var stale: std.ArrayList([]const u8) = .empty;
            defer stale.deinit(self.allocator);
            var it = self.module_cache.iterator();
            while (it.next()) |e| {
                if (!live.contains(e.key_ptr.*)) stale.append(self.allocator, e.key_ptr.*) catch {};
            }
            for (stale.items) |k| {
                if (self.module_cache.fetchRemove(k)) |kv| {
                    self.allocator.free(kv.value.id);
                    self.allocator.free(kv.value.code);
                    if (kv.value.compiled) |c| c.deinit(self.allocator);
                }
            }
            // 2) changed=true 만 새 code 로 갱신/추가. changed=false 는 기존 실제 code 유지
            //    (없으면 — first 빌드는 전부 changed=true — 빈 placeholder 추가).
            for (codes) |c| {
                if (c.changed) {
                    if (self.module_cache.getPtr(c.id)) |vp| {
                        const code = self.allocator.dupe(u8, c.code) catch continue;
                        self.allocator.free(vp.code);
                        if (vp.compiled) |cc| cc.deinit(self.allocator);
                        vp.code = code;
                        vp.compiled = null;
                    } else {
                        const id = self.allocator.dupe(u8, c.id) catch continue;
                        const code = self.allocator.dupe(u8, c.code) catch {
                            self.allocator.free(id);
                            continue;
                        };
                        self.module_cache.put(self.allocator, id, .{ .id = id, .code = code }) catch {
                            self.allocator.free(id);
                            self.allocator.free(code);
                        };
                    }
                } else if (!self.module_cache.contains(c.id)) {
                    const id = self.allocator.dupe(u8, c.id) catch continue;
                    const code = self.allocator.dupe(u8, "") catch {
                        self.allocator.free(id);
                        continue;
                    };
                    self.module_cache.put(self.allocator, id, .{ .id = id, .code = code }) catch {
                        self.allocator.free(id);
                        self.allocator.free(code);
                    };
                }
            }
        }
    }

    pub const RebuildSuccess = struct {
        paths: []const []const u8,
        /// Ownership 은 caller 에게 이전 — 각 엔트리의 `id`/`code`/`map` 은
        /// `allocator.dupe` 복사본이므로 `BundleResult.ModuleDevCode.freeAll(_, allocator)`
        /// 로 정리해야 한다. 단순히 slice 만 free 하면 leak.
        changed_modules: []const BundleResult.ModuleDevCode,
        graph_changed: bool,
        /// RFC #3940 Sub-PR-L.0b — bundle 직후 profile snapshot. `ZNTC_PROFILE` 활성 시
        /// 만 채워짐 (`anyEnabled()` true 일 때). caller (dev_server) 가 SSE event 의
        /// `profile` 필드 또는 NAPI watch callback payload 에 포함. null 이면 미측정.
        /// 측정 효율: snapshot 자체는 cheap (atomic load × num_categories).
        profile_snapshot: ?@import("../profile.zig").ProfileSnapshot = null,
    };

    pub const RebuildResult = union(enum) {
        success: RebuildSuccess,
        build_error: []const u8,
        fatal,
    };
};

// ── writeJsonEscaped 유닛 테스트 ──

test "writeJsonEscaped: 특수문자 이스케이프" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try writeJsonEscaped(w, "he said \"hello\"\nnew\\line\ttab");
    try std.testing.expectEqualStrings(
        "he said \\\"hello\\\"\\nnew\\\\line\\ttab",
        aw.writer.buffered(),
    );
}

test "writeJsonEscaped: 빈 문자열" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try writeJsonEscaped(w, "");
    try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
}

test "writeJsonEscaped: 일반 텍스트" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try writeJsonEscaped(w, "hello world 123");
    try std.testing.expectEqualStrings("hello world 123", aw.writer.buffered());
}
