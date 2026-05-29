const std = @import("std");
const zntc_lib = @import("zntc_lib");

const bundler_mod = zntc_lib.bundler;
const Bundler = bundler_mod.Bundler;
const TrackedFileSet = zntc_lib.server.TrackedFileSet;
const profile_mod = zntc_lib.profile;
const BundleOptions = bundler_mod.BundleOptions;
const SourceMap = zntc_lib.codegen.sourcemap;
const types_mod = zntc_lib.bundler.types;
const common = @import("common.zig");
const options_mod = @import("options.zig");
const plugin_bridge = @import("plugin_bridge.zig");
const c = common.c;

const native_alloc = common.nativeAlloc();

/// 0.16: std.time.Timer 제거 → Io.Timestamp(awake 단조시계) 기반 경과시간 측정.
/// profile/debug 로깅용 (정밀도 비요구). start 시 io 캡처 → read() 가 io 불필요.
const IoTimer = struct {
    io: std.Io,
    start_ns: i128,
    fn start(io: std.Io) IoTimer {
        return .{ .io = io, .start_ns = std.Io.Timestamp.now(io, .awake).toNanoseconds() };
    }
    fn read(self: *const IoTimer) u64 {
        const now = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
        return @intCast(@max(0, now - self.start_ns));
    }
};

const throwError = common.throwError;
const unwrapNapi = common.unwrapNapi;
const getStringArg = common.getStringArg;
const getNamedProperty = common.getNamedProperty;
const getObjectBool = common.getObjectBool;
const getObjectStringArray = common.getObjectStringArray;
const parseBuildOptions = options_mod.parseBuildOptions;
const freeOptionsTypedSlices = options_mod.freeOptionsTypedSlices;
const NapiPlugin = plugin_bridge.NapiPlugin;
const Plugin = bundler_mod.plugin.Plugin;
const NapiManualChunksResolver = plugin_bridge.NapiManualChunksResolver;
const installManualChunksResolver = plugin_bridge.installManualChunksResolver;

/// Issue #1223 Phase 1: 워처 튜닝 상수.
/// - watch_poll_timeout_ms: stop_flag 체크 주기 (이벤트 워처에서도 주기적으로 깨어나기 위함).
/// - watch_debounce_ms: 첫 이벤트 이후 정적(idle) 구간 — 연속 저장 병합 윈도우.
///   phase1c 의 공개 계약은 50ms 내 연속 저장 병합이다. macOS kqueue 는 CI 부하에 따라
///   같은 파일의 후속 NOTE_WRITE 전달이 25ms idle 뒤에 도착할 수 있으므로, idle window 를
///   계약값인 50ms 로 맞춰 빠른 저장을 한 rebuild 로 안정적으로 합친다.
/// - watch_debounce_max_ms: 디바운스 최대 대기 시간 — 지속 변경되는 파일에 의한 기아 방지.
const watch_poll_timeout_ms: u32 = 200;
const watch_debounce_ms: u32 = 50;
const watch_debounce_max_ms: u64 = 500;

/// 파일 내용 해시 상한 (#1233). RN 등 대형 프로젝트의 vendor 번들/asset catalog/locale
/// JSON이 수십 MB에 이를 수 있어 넉넉히 잡음. 초과 시 `util.wyhash.hashFileStreaming`이
/// size+mtime 기반 pseudo-hash로 폴백한다 — 해당 파일이 영영 리빌드 트리거되지 않는 stale
/// output 방지.
const watch_hash_max_bytes: usize = 256 * 1024 * 1024;

/// 이벤트 배열의 path들을 중복 제거 set에 병합.
/// FileWatcher.waitForChanges 결과는 다음 호출에서 무효화되므로 path를 dupe.
fn collectTouched(
    set: *std.StringHashMap(void),
    alloc: std.mem.Allocator,
    evts: []const zntc_lib.server.ChangeEvent,
) void {
    for (evts) |e| {
        if (set.contains(e.path)) continue;
        const dup = alloc.dupe(u8, e.path) catch continue;
        set.put(dup, {}) catch alloc.free(dup);
    }
}

// ─── watch() 비동기 (콜백 기반) ───

const WatchAsyncData = struct {
    env: c.napi_env,
    // 소유된 옵션 (워커 스레드에서 유효해야 하므로 복사)
    options: BundleOptions,
    owned_strings: std.ArrayList([]const u8),
    owned_string_arrays: std.ArrayList([]const []const u8),
    // NAPI 플러그인 (JS 콜백 기반)
    napi_plugins: std.ArrayList(*NapiPlugin),
    zig_plugins: std.ArrayList(Plugin),
    // manualChunks JS resolver — 소유 (deinit 시 TSFN release)
    napi_manual_chunks: ?*NapiManualChunksResolver = null,
    // Watch-specific
    ready_tsfn: c.napi_threadsafe_function,
    rebuild_tsfn: c.napi_threadsafe_function,
    stop_flag: std.atomic.Value(bool),
    /// #3794 — worker thread 가 stop_flag 감지 + 자원 정리 (TSFN release / deinit 직전)
    /// 까지 완료하면 set. `napiWatchStop` 가 wait 해 caller (closeServerForRestart) 가
    /// child process spawn 전에 부모 worker 가 outdir 쓰기를 완전히 멈췄음을 보장.
    /// fire-and-forget 였던 stop() 의 race window 봉인.
    // 0.16: std.Thread.ResetEvent 제거 → std.Io.Event (one-shot set/wait).
    stop_complete: std.Io.Event = .unset,
    /// Metro watchFolders 호환. 그래프 밖 감시 루트(절대/상대 경로).
    watch_roots: []const []const u8 = &.{},
    /// watch_roots 스캔 시 포함할 파일 glob (루트 기준 상대).
    watch_include: []const []const u8 = &.{},
    /// watch_roots 스캔 시 제외할 파일 glob (루트 기준 상대).
    watch_exclude: []const []const u8 = &.{},
    /// 워커 스레드에서 매 rebuild 마다 주입되는 compiled output cache.
    /// watch worker 수명 내내 유지되어 변경 안 된 모듈의 emit 을 스킵.
    compiled_cache: bundler_mod.CompiledOutputCache,

    /// Lazy sourcemap 캐시 (Issue #1727 Phase B). 구조는 rspack `MappedAssetsCache`
    /// 와 동형 — chunk-level / version-based invalidation 같은 확장은 이 struct 안으로 수용.
    sm_cache: LazySourceMapCache = .{},

    /// `.map` 파일을 디스크에 기록할지 여부. bungae 등 lazy 엔드포인트를 갖춘 dev 서버는
    /// false 로 보내 rebuild 경로의 디스크 I/O 를 완전히 제거할 수 있다. CLI 빌드는
    /// 기본 true 유지.
    emit_disk_sourcemap: bool = true,

    fn deinit(self: *WatchAsyncData) void {
        // #3794 — worker 종료 신호 우선 set (모든 early-return / 정상 종료 path 가 deinit 을
        // 거치므로 한 곳에서 가드). `napiWatchStop` 의 stop_complete.wait() 가 깨어나 caller
        // (closeServerForRestart) 에게 안전 신호. wait 한 thread 는 즉시 return — `self`
        // 메모리 접근 없음, 아래 cleanup 후 free 해도 race 없음.
        self.stop_complete.set(common.io());
        // 소유된 문자열 해제
        for (self.owned_strings.items) |s| native_alloc.free(s);
        self.owned_strings.deinit(native_alloc);
        // 배열 컨테이너 해제 (내부 문자열은 owned_strings에서 이미 해제됨)
        for (self.owned_string_arrays.items) |arr| native_alloc.free(arr);
        self.owned_string_arrays.deinit(native_alloc);
        // typed slices (define/module_specifier_map/alias) — native_alloc 소유, 명시 free (#2396).
        freeOptionsTypedSlices(&self.options);
        // NAPI 플러그인 해제
        for (self.napi_plugins.items) |np| np.deinit();
        self.napi_plugins.deinit(native_alloc);
        self.zig_plugins.deinit(native_alloc);
        if (self.napi_manual_chunks) |mc| mc.deinit();
        self.compiled_cache.deinit();
        self.sm_cache.deinit(native_alloc);
        native_alloc.destroy(self);
    }
};

/// Handle-scoped lazy sourcemap 캐시 (Issue #1727 Phase B).
///
/// rebuild 마다 bundler 가 이관한 `SourceMapBuilder` 들을 보관해 dev server 가
/// `/bundle.js.map` / `/hmr-map/:moduleId` 요청을 받으면 NAPI getter 로 JSON 을 즉석
/// 생성. HMR 경로에서 VLQ encode 29ms 를 경로 밖으로 빼낸다. rebuild (worker thread) 와
/// getter (NAPI main thread) 가 동시에 접근할 수 있어 `mutex` 로 직렬화 — builder.buf
/// 가 재사용 버퍼이므로 동시 `generateJSON` 호출도 racy.
///
/// rspack `MappedAssetsCache(FxDashMap)` 과 동형 구조. 향후 chunk-level sourcemap
/// (code splitting + HMR 조합) 이나 version-based invalidation 같은 확장은 이 struct
/// 안으로 수용하기 위해 sub-struct 로 분리.
const LazySourceMapCache = struct {
    /// 최신 rebuild 의 번들 레벨 sourcemap builder. null 이면 lazy 비활성 상태거나 초기
    /// 빌드 실패.
    bundle: ?*SourceMap.SourceMapBuilder = null,
    /// 최신 rebuild 의 모듈 id → per-module sourcemap builder. key/value 모두 caller 가
    /// 전달한 allocator 소유 — `deinit` / `clear` 가 정리한다.
    modules: std.StringHashMapUnmanaged(*SourceMap.SourceMapBuilder) = .empty,
    /// swap / getter 호출을 직렬화.
    mutex: zntc_lib.util.SpinLock = .{},

    /// 현재 캐시된 bundle + module builder 들을 모두 free + 맵 clear. 내부에서 lock
    /// 하지 않으므로 caller 가 `mutex` 를 이미 잡았거나 (stop 경로처럼) 동시 접근이
    /// 없음을 보장해야 한다.
    fn clearModules(self: *LazySourceMapCache, allocator: std.mem.Allocator) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.destroy(allocator);
        }
        self.modules.clearRetainingCapacity();
    }

    fn clear(self: *LazySourceMapCache, allocator: std.mem.Allocator) void {
        if (self.bundle) |sm| sm.destroy(allocator);
        self.bundle = null;
        self.clearModules(allocator);
    }

    /// rebuild 완료 후 builder 들을 swap. 이전 builder 는 free. **내부에서 `mutex` 를
    /// 직접 acquire** — caller 는 추가 lock 불필요.
    ///
    /// Dev HMR rebuild 는 full bundle output 을 생략할 수 있어 `new_bundle == null`
    /// 로 들어온다. 이때 기존 full-bundle sourcemap 을 지우면 `/index.map` 이 첫 HMR
    /// 이후 404 가 되므로, null 은 "bundle map unchanged" 로 처리하고 module map 만
    /// 최신 rebuild 결과로 교체한다.
    ///
    /// Side effect: `module_codes` 의 각 엔트리 `.sm_builder` 를 null 로 되돌린다
    /// (소유권 이전). 이후 `ModuleDevCode.freeAll` 이 double-free 없이 나머지 필드만 정리.
    fn swap(
        self: *LazySourceMapCache,
        allocator: std.mem.Allocator,
        new_bundle: ?*SourceMap.SourceMapBuilder,
        module_codes: []types_mod.ModuleDevCode,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (new_bundle) |sm| {
            if (self.bundle) |old| old.destroy(allocator);
            self.bundle = sm;
        }
        self.clearModules(allocator);
        for (module_codes) |*mc| {
            const builder = mc.sm_builder orelse continue;
            const id_copy = allocator.dupe(u8, mc.id) catch {
                builder.destroy(allocator);
                mc.sm_builder = null;
                continue;
            };
            self.modules.put(allocator, id_copy, builder) catch {
                allocator.free(id_copy);
                builder.destroy(allocator);
                mc.sm_builder = null;
                continue;
            };
            mc.sm_builder = null;
        }
    }

    /// 최종 정리 — clear 후 map 자체도 deinit.
    fn deinit(self: *LazySourceMapCache, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.modules.deinit(allocator);
    }
};

/// onReady 콜백에 전달할 이벤트 데이터
const WatchReadyEvent = struct {
    files: usize,
    bytes: usize,
    /// #3796 — initial 빌드의 output 파일 path 목록. caller (`runServe`) 가 outdir scan 없이
    /// 정확한 outputFiles 정보를 받아 `appDev.injectBundleCssLinks` 호출 가능. contents 는
    /// 메모리 비용 큼 + caller 가 보통 path 만 본다 (`inject.ts` 의 `isCssFile(file.path)` 만
    /// 검사) — path 만 노출. null 이면 outputs 없음 (단일 파일 빌드 등).
    outputs: ?[]const []const u8 = null,
    /// #3799 root-cause — initial bundle() 이 success 반환 + diagnostics 에 error severity
    /// (missing import 등 placeholder 처리된 partial build). 이전엔 worker 종료 — 잘못된 design.
    /// `success` 는 watch lifecycle 자체에 보존, errors 는 별도 노출. consumer (runServe) 가
    /// reportError 호출.
    errors: ?[]const WatchRebuildEvent.ErrorEntry = null,

    fn deinit(self: *WatchReadyEvent, allocator: std.mem.Allocator) void {
        if (self.outputs) |paths| {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }
        if (self.errors) |errs| {
            for (errs) |e| {
                allocator.free(e.file);
                allocator.free(e.message);
            }
            allocator.free(errs);
        }
        allocator.destroy(self);
    }
};

/// HMR rebuild phase 별 소요시간 (밀리초). Issue #1223 관측성.
///
/// 기본 phase (`detect_ms`/`graph_ms`/`link_ms`/`shake_ms`/`emit_ms`/`delta_ms`/`total_ms`)
/// 는 profile 비활성 상태에서도 항상 측정 (bundler `BundleTimings` 기반 — 가벼움).
///
/// Sub-phase (`scan_ms`/`parse_ms`/`resolve_ms`/`semantic_ms`/`transform_ms`/`codegen_ms`/
/// `metadata_ms`) 는 `ZNTC_PROFILE=<cat>` / `BUNGAE_HMR_PROFILE=1` / `BundleOptions.profile`
/// 활성 상태에서만 의미있는 값. 비활성 시 모두 0.
///
/// 이름 매핑 이력: 2026-04-22 이전의 `parse_ms` / `semantic_ms` 는 실제로는 `graph_ns` /
/// `link+shake` 를 담았던 레거시 이름이었다. 이름=의미 일치를 위해 기본 phase 에서
/// `parse_ms`/`semantic_ms` 를 제거하고 `graph_ms`/`link_ms`/`shake_ms` 로 분리.
/// Sub-phase 의 `parse_ms`/`semantic_ms` 는 이제 진짜 parser/analyzer 시간을 의미.
///
/// Sub-phase 필드는 `profile.Category` enum 과 1:1 매핑. Category 에 phase 추가 시
/// 동기화 위치: (1) 이 struct, (2) `fields[]` 배열 (rebuild 이벤트 변환), (3) phase_durations
/// 초기화, (4) `packages/core/index.ts` TS 타입, (5) docs/HMR.md / docs/DEBUG.md.
const PhaseDurations = struct {
    // ── 기본 phase (항상 측정) ──
    detect_ms: f64 = 0,
    graph_ms: f64 = 0,
    link_ms: f64 = 0,
    shake_ms: f64 = 0,
    emit_ms: f64 = 0,
    delta_ms: f64 = 0,
    total_ms: f64 = 0,

    // ── Sub-phase (ZNTC_PROFILE=<cat> 활성 시에만 값 기록) ──
    scan_ms: f64 = 0,
    parse_ms: f64 = 0,
    resolve_ms: f64 = 0,
    semantic_ms: f64 = 0,
    transform_ms: f64 = 0,
    codegen_ms: f64 = 0,
    metadata_ms: f64 = 0,

    // ── Graph sub-phase (graph 내부 분해) ──
    graph_build_ms: f64 = 0,
    graph_worker_ms: f64 = 0,
    graph_discover_ms: f64 = 0,
    graph_finalize_ms: f64 = 0,

    // ── Emit sub-phase (emit 내부 분해) ──
    emit_polyfill_ms: f64 = 0,
    emit_refresh_ms: f64 = 0,
    emit_output_ms: f64 = 0,
    emit_metafile_ms: f64 = 0,
    emit_css_ms: f64 = 0,

    // ── emit_output 내부 분해 (emitter.emitWithTreeShaking) ──
    emit_prelude_ms: f64 = 0,
    emit_module_pass_ms: f64 = 0,
    emit_concat_ms: f64 = 0,
    emit_sourcemap_finalize_ms: f64 = 0,

    // ── Link sub-phase (RFC #3940 Sub-PR-L.0e — Lifecycle redesign 의 link 영역 측정) ──
    // link_compute_renames 가 lodash 측정에서 50ms — RFC #3940 의 SymbolID 패턴 적용 후
    // RenameTable 측정 baseline.
    link_build_export_map_ms: f64 = 0,
    link_resolve_imports_ms: f64 = 0,
    link_compute_renames_ms: f64 = 0,
    link_populate_re_export_aliases_ms: f64 = 0,
    link_populate_import_symbols_ms: f64 = 0,
    link_populate_namespace_accesses_ms: f64 = 0,
};

/// onRebuild 콜백에 전달할 이벤트 데이터
const WatchRebuildEvent = struct {
    success: bool,
    // 성공 시
    changed: ?[]const []const u8 = null,
    graph_changed: bool = false,
    updates: ?[]const ModuleUpdate = null,
    bytes: usize = 0,
    phase_durations: ?PhaseDurations = null,
    /// 증분 그래프에서 재파싱된 모듈 수 (Issue #1223 Phase 2).
    reparsed_modules: ?usize = null,
    // 실패 시
    error_msg: ?[]const u8 = null,
    /// #3799 — bundler diagnostics 의 multi-error 보존. `@errorName(err)` 단일 문자열
    /// (`error_msg`) 와 달리 file path + message 둘 다 보존. caller (broadcastRebuildEvent)
    /// 가 우선 사용, 없으면 error_msg fallback.
    errors: ?[]const ErrorEntry = null,

    const ModuleUpdate = struct {
        id: []const u8,
        code: []const u8,
        /// 모듈별 standalone source map (V3 JSON). null이면 미수집 (Issue #1248).
        map: ?[]const u8 = null,
    };

    /// #3799 — bundler diagnostics 의 1건. file/message 둘 다 native_alloc 으로 dupe.
    const ErrorEntry = struct {
        file: []const u8,
        message: []const u8,
    };

    fn deinit(self: *WatchRebuildEvent) void {
        if (self.changed) |ch| {
            for (ch) |s| native_alloc.free(s);
            native_alloc.free(ch);
        }
        if (self.updates) |upd| {
            for (upd) |u| {
                native_alloc.free(u.id);
                native_alloc.free(u.code);
                if (u.map) |m| native_alloc.free(m);
            }
            native_alloc.free(upd);
        }
        if (self.error_msg) |msg| native_alloc.free(msg);
        if (self.errors) |errs| {
            for (errs) |e| {
                native_alloc.free(e.file);
                native_alloc.free(e.message);
            }
            native_alloc.free(errs);
        }
        native_alloc.destroy(self);
    }
};

/// 파일의 mtime을 가져온다.
fn getFileMtime(path: []const u8) !i128 {
    // 0.16: std.fs.cwd 제거 → Io.Dir.cwd + io; stat.mtime 은 Io.Timestamp.
    const stat = try std.Io.Dir.cwd().statFile(common.io(), path, .{});
    return stat.mtime.toNanoseconds();
}

/// onReady TSFN 콜백 — 메인 스레드에서 실행
fn watchReadyTsfn(env: c.napi_env, js_func: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const event: *WatchReadyEvent = @ptrCast(@alignCast(data.?));
    defer event.deinit(native_alloc);

    if (js_func == null) return;

    // {files: N, bytes: N, outputs?: string[]} 객체 생성
    var js_event: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_event) != c.napi_ok) return;

    var js_files: c.napi_value = undefined;
    _ = c.napi_create_int64(env, @intCast(event.files), &js_files);
    _ = c.napi_set_named_property(env, js_event, "files", js_files);

    var js_bytes: c.napi_value = undefined;
    _ = c.napi_create_int64(env, @intCast(event.bytes), &js_bytes);
    _ = c.napi_set_named_property(env, js_event, "bytes", js_bytes);

    // #3796 — outputs: Array<string> (initial 빌드의 output 파일 path 목록).
    if (event.outputs) |paths| {
        var js_outputs: c.napi_value = undefined;
        _ = c.napi_create_array_with_length(env, paths.len, &js_outputs);
        for (paths, 0..) |p, idx| {
            var js_str: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, p.ptr, p.len, &js_str);
            _ = c.napi_set_element(env, js_outputs, @intCast(idx), js_str);
        }
        _ = c.napi_set_named_property(env, js_event, "outputs", js_outputs);
    }

    // #3799 root-cause — errors: Array<{file, message}> (initial diagnostics 의 error 목록).
    if (event.errors) |errs| {
        var js_errors: c.napi_value = undefined;
        _ = c.napi_create_array_with_length(env, errs.len, &js_errors);
        for (errs, 0..) |e, idx| {
            var js_entry: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_entry);
            var js_file: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, e.file.ptr, e.file.len, &js_file);
            _ = c.napi_set_named_property(env, js_entry, "file", js_file);
            var js_msg: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, e.message.ptr, e.message.len, &js_msg);
            _ = c.napi_set_named_property(env, js_entry, "message", js_msg);
            _ = c.napi_set_element(env, js_errors, @intCast(idx), js_entry);
        }
        _ = c.napi_set_named_property(env, js_event, "errors", js_errors);
    }

    // onReady(event) 호출
    var js_undefined: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undefined);
    var js_result: c.napi_value = undefined;
    var call_args = [_]c.napi_value{js_event};
    _ = c.napi_call_function(env, js_undefined, js_func, 1, &call_args, &js_result);
}

/// onRebuild TSFN 콜백 — 메인 스레드에서 실행
fn watchRebuildTsfn(env: c.napi_env, js_func: c.napi_value, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const event: *WatchRebuildEvent = @ptrCast(@alignCast(data.?));
    defer event.deinit();

    if (js_func == null) return;

    var js_event: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_event) != c.napi_ok) return;

    // success
    var js_success: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, event.success, &js_success);
    _ = c.napi_set_named_property(env, js_event, "success", js_success);

    if (event.success) {
        // changed: string[]
        var js_changed: c.napi_value = undefined;
        if (event.changed) |ch| {
            _ = c.napi_create_array_with_length(env, ch.len, &js_changed);
            for (ch, 0..) |path, i| {
                var js_path: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, path.ptr, path.len, &js_path);
                _ = c.napi_set_element(env, js_changed, @intCast(i), js_path);
            }
        } else {
            _ = c.napi_create_array(env, &js_changed);
        }
        _ = c.napi_set_named_property(env, js_event, "changed", js_changed);

        // graphChanged?: bool
        if (event.graph_changed) {
            var js_gc: c.napi_value = undefined;
            _ = c.napi_get_boolean(env, true, &js_gc);
            _ = c.napi_set_named_property(env, js_event, "graphChanged", js_gc);
        }

        // updates?: [{id, code}]
        if (event.updates) |upd| {
            var js_updates: c.napi_value = undefined;
            _ = c.napi_create_array_with_length(env, upd.len, &js_updates);
            for (upd, 0..) |u, i| {
                var js_u: c.napi_value = undefined;
                _ = c.napi_create_object(env, &js_u);
                var js_id: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, u.id.ptr, u.id.len, &js_id);
                _ = c.napi_set_named_property(env, js_u, "id", js_id);
                var js_code: c.napi_value = undefined;
                _ = c.napi_create_string_utf8(env, u.code.ptr, u.code.len, &js_code);
                _ = c.napi_set_named_property(env, js_u, "code", js_code);
                if (u.map) |m| {
                    var js_map: c.napi_value = undefined;
                    _ = c.napi_create_string_utf8(env, m.ptr, m.len, &js_map);
                    _ = c.napi_set_named_property(env, js_u, "map", js_map);
                }
                _ = c.napi_set_element(env, js_updates, @intCast(i), js_u);
            }
            _ = c.napi_set_named_property(env, js_event, "updates", js_updates);
        }

        // bytes
        var js_bytes: c.napi_value = undefined;
        _ = c.napi_create_int64(env, @intCast(event.bytes), &js_bytes);
        _ = c.napi_set_named_property(env, js_event, "bytes", js_bytes);

        if (event.phase_durations) |pd| {
            var js_pd: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_pd);
            const fields = [_]struct { name: [:0]const u8, value: f64 }{
                // 기본 phase (항상 측정).
                .{ .name = "detect", .value = pd.detect_ms },
                .{ .name = "graph", .value = pd.graph_ms },
                .{ .name = "link", .value = pd.link_ms },
                .{ .name = "shake", .value = pd.shake_ms },
                .{ .name = "emit", .value = pd.emit_ms },
                .{ .name = "delta", .value = pd.delta_ms },
                .{ .name = "total", .value = pd.total_ms },
                // Sub-phase (ZNTC_PROFILE=<cat> 활성 시 의미있는 값, 아니면 0).
                .{ .name = "scan", .value = pd.scan_ms },
                .{ .name = "parse", .value = pd.parse_ms },
                .{ .name = "resolve", .value = pd.resolve_ms },
                .{ .name = "semantic", .value = pd.semantic_ms },
                .{ .name = "transform", .value = pd.transform_ms },
                .{ .name = "codegen", .value = pd.codegen_ms },
                .{ .name = "metadata", .value = pd.metadata_ms },
                // Graph sub-phase.
                .{ .name = "graphBuild", .value = pd.graph_build_ms },
                .{ .name = "graphWorker", .value = pd.graph_worker_ms },
                .{ .name = "graphDiscover", .value = pd.graph_discover_ms },
                .{ .name = "graphFinalize", .value = pd.graph_finalize_ms },
                // Emit sub-phase (bundler.zig 수준).
                .{ .name = "emitPolyfill", .value = pd.emit_polyfill_ms },
                .{ .name = "emitRefresh", .value = pd.emit_refresh_ms },
                .{ .name = "emitOutput", .value = pd.emit_output_ms },
                .{ .name = "emitMetafile", .value = pd.emit_metafile_ms },
                .{ .name = "emitCss", .value = pd.emit_css_ms },
                // emit_output 내부 (emitter.emitWithTreeShaking 분해).
                .{ .name = "emitPrelude", .value = pd.emit_prelude_ms },
                .{ .name = "emitModulePass", .value = pd.emit_module_pass_ms },
                .{ .name = "emitConcat", .value = pd.emit_concat_ms },
                .{ .name = "emitSourcemapFinalize", .value = pd.emit_sourcemap_finalize_ms },
                // RFC #3940 Sub-PR-L.0e — Link sub-phase (lifecycle redesign 의 link 영역 측정).
                .{ .name = "linkBuildExportMap", .value = pd.link_build_export_map_ms },
                .{ .name = "linkResolveImports", .value = pd.link_resolve_imports_ms },
                .{ .name = "linkComputeRenames", .value = pd.link_compute_renames_ms },
                .{ .name = "linkPopulateReExportAliases", .value = pd.link_populate_re_export_aliases_ms },
                .{ .name = "linkPopulateImportSymbols", .value = pd.link_populate_import_symbols_ms },
                .{ .name = "linkPopulateNamespaceAccesses", .value = pd.link_populate_namespace_accesses_ms },
            };
            for (fields) |f| {
                var js_num: c.napi_value = undefined;
                _ = c.napi_create_double(env, f.value, &js_num);
                _ = c.napi_set_named_property(env, js_pd, f.name.ptr, js_num);
            }
            _ = c.napi_set_named_property(env, js_event, "phaseDurations", js_pd);
        }

        if (event.reparsed_modules) |n| {
            var js_n: c.napi_value = undefined;
            _ = c.napi_create_int64(env, @intCast(n), &js_n);
            _ = c.napi_set_named_property(env, js_event, "reparsedModules", js_n);
        }
    } else {
        // error: string (catch 분기 — bundle() 자체가 throw 한 케이스)
        if (event.error_msg) |msg| {
            var js_err: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, msg.ptr, msg.len, &js_err);
            _ = c.napi_set_named_property(env, js_event, "error", js_err);
        }
    }
    // #3799 root-cause — errors 는 success/false 두 분기에서 모두 채워질 수 있다. success=true
    // + errors 는 missing import 같은 partial build 시그널 (build 자체는 성공, output 있음).
    if (event.errors) |errs| {
        var js_errors: c.napi_value = undefined;
        _ = c.napi_create_array_with_length(env, errs.len, &js_errors);
        for (errs, 0..) |e, idx| {
            var js_entry: c.napi_value = undefined;
            _ = c.napi_create_object(env, &js_entry);
            var js_file: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, e.file.ptr, e.file.len, &js_file);
            _ = c.napi_set_named_property(env, js_entry, "file", js_file);
            var js_msg: c.napi_value = undefined;
            _ = c.napi_create_string_utf8(env, e.message.ptr, e.message.len, &js_msg);
            _ = c.napi_set_named_property(env, js_entry, "message", js_msg);
            _ = c.napi_set_element(env, js_errors, @intCast(idx), js_entry);
        }
        _ = c.napi_set_named_property(env, js_event, "errors", js_errors);
    }

    // onRebuild(event) 호출
    var js_undefined: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undefined);
    var js_result: c.napi_value = undefined;
    var call_args = [_]c.napi_value{js_event};
    _ = c.napi_call_function(env, js_undefined, js_func, 1, &call_args, &js_result);
}

/// watchFolders 루트를 재귀 스캔해 TrackedFileSet에 등록.
/// tracked.addPath가 내부에서 key를 dupe하므로 visitor는 false로 walker가 free하게 둔다.
fn addWatchRootFiles(
    allocator: std.mem.Allocator,
    root: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    tracked: *zntc_lib.server.TrackedFileSet,
    count: *usize,
) void {
    const Ctx = struct { tracked: *zntc_lib.server.TrackedFileSet, count: *usize };
    const visit = struct {
        fn f(ctx: Ctx, full_path: []const u8) bool {
            if (ctx.tracked.addPath(full_path, true)) ctx.count.* += 1;
            return false;
        }
    }.f;
    zntc_lib.server.watch_scan.scanRoot(
        allocator,
        common.io(),
        root,
        .{ .include = include, .exclude = exclude },
        Ctx{ .tracked = tracked, .count = count },
        visit,
    ) catch {};
}

/// issue #3858 — root + 모든 sub-dir 을 recursive 로 dir-watch 등록. kqueue/inotify
/// 의 dir-watch 가 single-level (sub-dir 안 변화 안 감지) 이라 sub-dir 도 각각
/// 등록 필요. count 는 tracked 의 watch_count 증가분.
fn addWatchRootDirs(
    allocator: std.mem.Allocator,
    root: []const u8,
    tracked: *zntc_lib.server.TrackedFileSet,
    count: *usize,
) void {
    // root 자체
    if (tracked.addDirPath(root)) count.* += 1;

    // 0.16: std.fs.cwd 제거 → Io.Dir.cwd + io (NAPI 전역 common.io()).
    var dir = std.Io.Dir.cwd().openDir(common.io(), root, .{ .iterate = true }) catch return;
    defer dir.close(common.io());
    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next(common.io()) catch null) |entry| {
        if (entry.kind != .directory) continue;
        // node_modules, .git, .zntc-* 등 skip (watch_scan 의 hasSkippedSegment 와 일관)
        if (std.mem.indexOf(u8, entry.path, "node_modules") != null) continue;
        if (std.mem.indexOf(u8, entry.path, ".git") != null) continue;
        if (std.mem.indexOf(u8, entry.path, ".zntc-") != null) continue;
        const full_path = std.fs.path.join(allocator, &.{ root, entry.path }) catch continue;
        defer allocator.free(full_path);
        if (tracked.addDirPath(full_path)) count.* += 1;
    }
}

/// issue #3858 — dir event 수신 후 root rescan. tracked 의 file 중 root 안 path 와
/// 새 scan 결과 비교 → 신규 file 은 addPath + touched 에 추가 (markIfChanged 가
/// 첫 hash 등록 → changed_files 진입), 삭제된 file 은 removePath + deleted 에 추가
/// (markIfChanged 가 hash 실패로 false → changed_files 우회를 위해 caller 가 직접
/// changed_files 에 push 해야 함). touched/deleted 의 key 는 allocator 가 owner.
fn rescanWatchRootDirty(
    allocator: std.mem.Allocator,
    root: []const u8,
    include: []const []const u8,
    exclude: []const []const u8,
    tracked: *zntc_lib.server.TrackedFileSet,
    touched: *std.StringHashMap(void),
    deleted: *std.StringHashMap(void),
) void {
    // (a) 새 scan 결과 set
    var new_paths = std.StringHashMap(void).init(allocator);
    defer {
        var it = new_paths.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        new_paths.deinit();
    }
    const Ctx = struct {
        new_paths: *std.StringHashMap(void),
        allocator: std.mem.Allocator,
    };
    const visit = struct {
        fn f(ctx: Ctx, full_path: []const u8) bool {
            const dupe = ctx.allocator.dupe(u8, full_path) catch return true;
            const gop = ctx.new_paths.getOrPut(dupe) catch {
                ctx.allocator.free(dupe);
                return true;
            };
            if (gop.found_existing) ctx.allocator.free(dupe);
            return true; // dupe 했으니 walker 가 원본 free
        }
    }.f;
    zntc_lib.server.watch_scan.scanRoot(
        allocator,
        common.io(),
        root,
        .{ .include = include, .exclude = exclude },
        Ctx{ .new_paths = &new_paths, .allocator = allocator },
        visit,
    ) catch return;

    // (b) 신규 file detect — new_paths 에 있고 tracked 에 없음.
    // addWatcherOnly 사용 (hashes 등록 skip) — 다음 markIfChanged 의 첫 호출이
    // hash 등록 + true 반환 → changed_files 에 들어가 첫 emit 보장.
    var nit = new_paths.keyIterator();
    while (nit.next()) |np| {
        if (tracked.contains(np.*)) continue;
        if (!tracked.addWatcherOnly(np.*)) continue;
        const td = allocator.dupe(u8, np.*) catch continue;
        const gop = touched.getOrPut(td) catch {
            allocator.free(td);
            continue;
        };
        if (gop.found_existing) {
            allocator.free(td);
        } else {
            gop.key_ptr.* = td;
        }
    }

    // (c) 삭제 detect — tracked 의 root 안 file 중 new_paths 에 없음
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer {
        for (to_remove.items) |rp| allocator.free(rp);
        to_remove.deinit(allocator);
    }
    var tit = tracked.keyIterator();
    while (tit.next()) |tp| {
        if (tracked.isDirPath(tp.*)) continue;
        // /code-review max #1 — startsWith path boundary. root='/foo' 가
        // '/foobar/x.css' 를 false-positive 매치하지 않도록 separator 또는
        // 정확 일치 강제. multi-watchFolders 시 다른 root 의 file 영향 차단.
        if (!std.mem.startsWith(u8, tp.*, root)) continue;
        if (tp.*.len > root.len and tp.*[root.len] != '/' and tp.*[root.len] != '\\') continue;
        if (new_paths.contains(tp.*)) continue;
        const dupe = allocator.dupe(u8, tp.*) catch continue;
        to_remove.append(allocator, dupe) catch {
            allocator.free(dupe);
        };
    }
    for (to_remove.items) |rp| {
        // deleted set 에 추가 (touched 아님 — markIfChanged 우회 위해)
        const td = allocator.dupe(u8, rp) catch continue;
        const gop = deleted.getOrPut(td) catch {
            allocator.free(td);
            continue;
        };
        if (gop.found_existing) {
            allocator.free(td);
        } else {
            gop.key_ptr.* = td;
        }
        tracked.removePath(rp); // rp 를 read 후 remove (tracked key 와 다른 dupe)
    }
}

/// 단일 파일 빌드 산출물의 `.map` 을 디스크에 기록. lazy 경로 (`sourcemap_json == null`)
/// 이거나 `enabled == false` 이면 no-op. 실패는 silently ignore — dev server 경로에서
/// disk I/O 장애가 빌드 흐름을 막으면 안 됨.
/// #3799 — `bundler.bundle()` 가 성공했지만 result.diagnostics 에 error severity 가 있으면
/// `WatchRebuildEvent.errors` 로 변환. throw 케이스 (catch 분기) 는 별도 `error_msg` 사용.
/// caller 가 entries 를 deinit 책임. 실패 (OOM 등) 시 null 반환.
fn collectErrorsFromResult(
    allocator: std.mem.Allocator,
    result: *const bundler_mod.BundleResult,
) ?[]const WatchRebuildEvent.ErrorEntry {
    const diags = result.getDiagnostics();
    var count: usize = 0;
    for (diags) |d| {
        if (d.severity == .@"error") count += 1;
    }
    if (count == 0) return null;
    const entries = allocator.alloc(WatchRebuildEvent.ErrorEntry, count) catch return null;
    var i: usize = 0;
    var has_failed = false;
    for (diags) |d| {
        if (d.severity != .@"error") continue;
        const file_dup = allocator.dupe(u8, d.file_path) catch {
            has_failed = true;
            break;
        };
        const msg_dup = allocator.dupe(u8, d.message) catch {
            allocator.free(file_dup);
            has_failed = true;
            break;
        };
        entries[i] = .{ .file = file_dup, .message = msg_dup };
        i += 1;
    }
    if (has_failed) {
        // 부분 free
        for (entries[0..i]) |e| {
            allocator.free(e.file);
            allocator.free(e.message);
        }
        allocator.free(entries);
        return null;
    }
    return entries;
}

fn writeSourcemapFile(
    allocator: std.mem.Allocator,
    output_filename: []const u8,
    sourcemap_json: ?[]const u8,
    enabled: bool,
) void {
    if (!enabled) return;
    const sm = sourcemap_json orelse return;
    const map_path = std.fmt.allocPrint(allocator, "{s}.map", .{output_filename}) catch return;
    defer allocator.free(map_path);
    // 0.16: createFile+writeAll+close → Io.Dir.writeFile (one-shot).
    std.Io.Dir.cwd().writeFile(common.io(), .{ .sub_path = map_path, .data = sm }) catch {};
}

/// #3795 — `o.path` 를 outdir 와 결합해 최종 path 를 반환. outdir 가 빈 문자열이면 o_path
/// 그대로 (caller-allocated). o_path 가 이미 absolute 면 outdir 무시 (esbuild 동일). caller
/// 가 alloc 된 결과를 free 해야 함.
fn resolveOutdirPath(allocator: std.mem.Allocator, outdir: []const u8, o_path: []const u8) ![]u8 {
    if (outdir.len == 0) return try allocator.dupe(u8, o_path);
    if (std.fs.path.isAbsolute(o_path)) return try allocator.dupe(u8, o_path);
    return try std.fs.path.join(allocator, &.{ outdir, o_path });
}

/// #3795 — output 한 개를 outdir+path 로 결합해 write. dirname makePath + createFile +
/// writeAll. 실패는 swallow (worker thread 가 다음 output 으로 계속 진행). bundler/emitter 가
/// outdir 를 모르므로 path 가 entry-relative 라도 outdir 명시 시 정확한 디스크 위치로 결합.
fn writeOutputToOutdir(
    allocator: std.mem.Allocator,
    outdir: []const u8,
    o_path: []const u8,
    contents: []const u8,
) void {
    const full_path = resolveOutdirPath(allocator, outdir, o_path) catch return;
    defer allocator.free(full_path);
    // 0.16: makePath→createDirPath, createFile+writeAll+close → Io.Dir.writeFile.
    if (std.fs.path.dirname(full_path)) |dir| std.Io.Dir.cwd().createDirPath(common.io(), dir) catch {};
    std.Io.Dir.cwd().writeFile(common.io(), .{ .sub_path = full_path, .data = contents }) catch {};
}

fn watchWorkerThread(async_data: *WatchAsyncData) void {
    const allocator = native_alloc;
    const bundle_opts = async_data.options;

    // Issue #1223 Phase 2: 초기 빌드에도 PersistentModuleStore 전달.
    // 초기 빌드에서 store가 채워져야 첫 리빌드가 캐시 히트 경로로 진입한다.
    const module_store_mod = bundler_mod.module_store;
    var persistent_store = module_store_mod.PersistentModuleStore.init(allocator);
    defer persistent_store.deinit();

    var initial_opts = bundle_opts;
    initial_opts.module_store = &persistent_store;
    initial_opts.compiled_cache = &async_data.compiled_cache;
    // rebuild 루프와 동일한 collect_module_codes 로 맞춘다 — options_hash 가 같아야
    // first-build 의 cache put 이 첫 rebuild 에서 그대로 hit 된다.
    initial_opts.collect_module_codes = bundle_opts.dev_mode;
    // Lazy sourcemap (Issue #1727 Phase B): dev watch 세션에서는 initial/rebuild 모두
    // builder 를 handle 에 캐시해 `/bundle.js.map`, `/hmr-map/:id` 요청을 즉석 서빙.
    // rebuild 경로의 `emit_sourcemap_finalize` 29ms 를 HMR latency 밖으로 빼낸다.
    if (bundle_opts.dev_mode and bundle_opts.sourcemap.enable) initial_opts.sourcemap.lazy = true;

    var bundler = Bundler.init(allocator, initial_opts);
    defer bundler.deinit();
    var result = bundler.bundle(common.io()) catch |err| {
        // 초기 빌드 실패 — rebuild 이벤트로 에러 전달
        const event = allocator.create(WatchRebuildEvent) catch {
            // OOM — TSFN 해제 + 정리 후 종료
            _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
            _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
            async_data.deinit();
            return;
        };
        const err_name: [:0]const u8 = @errorName(err);
        event.* = .{
            .success = false,
            .error_msg = allocator.dupe(u8, err_name) catch null,
        };
        if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
            event.deinit();
        }
        // TSFN 해제 + 정리 후 종료
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return;
    };
    defer result.deinit(allocator);

    // #3799 root-cause fix — initial bundle() 가 success 반환 (output 생성됨) 이지만
    // diagnostics 에 error severity 가 있을 수 있다 (missing import 등 placeholder 처리된 partial
    // build). 이전 코드는 worker 종료해 dev server 첫 빌드 실패 시 restart 까지 죽음 — 사용자가
    // syntax error 만 만져도 watch 끊김. 정확한 design 은 *success 유지 + ready_event.errors
    // 로 별도 노출* — consumer (runServe) 가 reportError + 정상 흐름 (module_code_cache 채움,
    // file output 등) 둘 다 처리. worker 는 정상 계속.

    // dev mode: per-module code 캐시 (HMR diff용)
    var module_code_cache = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = module_code_cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        module_code_cache.deinit();
    }

    // 초기 빌드의 module_dev_codes로 캐시 초기화
    if (result.module_dev_codes) |codes| {
        for (codes) |mc| {
            const id_copy = allocator.dupe(u8, mc.id) catch continue;
            const code_copy = allocator.dupe(u8, mc.code) catch {
                allocator.free(id_copy);
                continue;
            };
            module_code_cache.put(id_copy, code_copy) catch {
                allocator.free(id_copy);
                allocator.free(code_copy);
            };
        }
    }

    // Lazy sourcemap (Issue #1727 Phase B): initial build 의 builder 들을 handle 로 이관.
    // `swapSourceMapCache` 가 각 `mc.sm_builder` 를 null 로 되돌리므로 `result.deinit` 의
    // `ModuleDevCode.freeAll` 이 이중 해제하지 않는다. bundle builder 도 같은 규칙.
    if (initial_opts.sourcemap.lazy) {
        const mut_codes: []types_mod.ModuleDevCode = if (result.module_dev_codes) |codes|
            @constCast(codes)
        else
            &.{};
        async_data.sm_cache.swap(native_alloc, result.sourcemap_builder, mut_codes);
        result.sourcemap_builder = null;
    }

    var persistent_resolve_cache = Bundler.initResolveCacheFromOptions(allocator, bundle_opts);
    defer persistent_resolve_cache.deinit();

    // Issue #1223 Phase 1: 이벤트 기반 파일 워처 (kqueue/inotify, mtime 폴백).
    // 실패 시 워치 스레드 진입 직전에 종료한다.
    var tracked = TrackedFileSet.init(allocator, common.io(), watch_hash_max_bytes) catch |err| {
        const event = allocator.create(WatchRebuildEvent) catch {
            _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
            _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
            async_data.deinit();
            return;
        };
        const err_name: [:0]const u8 = @errorName(err);
        event.* = .{ .success = false, .error_msg = allocator.dupe(u8, err_name) catch null };
        if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
            event.deinit();
        }
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return;
    };
    defer tracked.deinit();

    var initial_watch_count: usize = 0;
    if (bundle_opts.entry_points.len > 0 and
        tracked.addPath(bundle_opts.entry_points[0], true))
    {
        initial_watch_count += 1;
    }
    if (result.module_paths) |paths| {
        for (paths) |p| {
            if (tracked.addPath(p, true)) initial_watch_count += 1;
        }
    }

    // watchFolders: 번들 그래프 밖 루트를 재귀 스캔해 tracked에 추가
    for (async_data.watch_roots) |root| {
        addWatchRootFiles(
            allocator,
            root,
            async_data.watch_include,
            async_data.watch_exclude,
            &tracked,
            &initial_watch_count,
        );
        // issue #3858 — dev mode 중 신규 file (graph 미진입 .css 등) 의 add/delete
        // 감지를 위해 root_dir + 모든 sub-dir 도 dir-watch. kqueue/inotify 의
        // dir-watch 가 single-level (sub-dir 안 변화 안 감지) 이라 recursive 등록.
        // main loop 가 dir event 시 rescan + 신규 path 의 addPath + touched 갱신.
        addWatchRootDirs(allocator, root, &tracked, &initial_watch_count);
    }

    // 초기 빌드 결과를 파일에 쓰기 (onReady 전에 완료해야 서버가 읽을 수 있음).
    // #3779 follow-up — `skip_initial_output=true` 면 caller 가 별도 `build()` 로 이미
    // outdir 를 채워둔 상태이므로 출력 skip. bytes 카운트는 onReady event 메타용이라
    // outputs 가 있으면 계속 합산한다 (bytes 자체는 출력 여부와 무관).
    const write_initial = !bundle_opts.skip_initial_output;
    var initial_bytes: usize = 0;
    if (result.outputs) |outputs| {
        for (outputs) |o| initial_bytes += o.contents.len;
        if (write_initial) {
            // code splitting: 각 output의 path 로 직접 쓰기 (#3795 — outdir 가 명시되면 결합).
            for (outputs) |o| {
                writeOutputToOutdir(allocator, bundle_opts.outdir, o.path, o.contents);
            }
        }
    } else {
        initial_bytes = result.output.len;
        // 단일 파일: output_filename으로 쓰기 (skip_initial_output 활성 시 skip).
        // #3795 — outdir 명시 시 output_filename 도 outdir-relative 로 처리.
        if (write_initial and bundle_opts.output_filename.len > 0) {
            writeOutputToOutdir(allocator, bundle_opts.outdir, bundle_opts.output_filename, result.output);
            const final_path = resolveOutdirPath(allocator, bundle_opts.outdir, bundle_opts.output_filename) catch null;
            if (final_path) |p| {
                defer allocator.free(p);
                writeSourcemapFile(allocator, p, result.sourcemap, async_data.emit_disk_sourcemap);
            }
            // 빈 placeholder if 분기 — 기존 else 패턴 호환 (sourcemap helper 호출 후).
        }
    }

    // ready 이벤트 전송
    {
        const ready_event = allocator.create(WatchReadyEvent) catch return;
        // #3796 — outputs path 목록 복사 (initial 빌드의 산출 path). single-file 경로
        // (`output_filename`) 도 same shape 으로 일관 노출 → caller (`runServe`) 가 통일 처리.
        var outputs_copy: ?[]const []const u8 = null;
        if (result.outputs) |outputs| {
            const arr = allocator.alloc([]const u8, outputs.len) catch null;
            if (arr) |paths| {
                var fill: usize = 0;
                for (outputs) |o| {
                    const dup = allocator.dupe(u8, o.path) catch break;
                    paths[fill] = dup;
                    fill += 1;
                }
                if (fill == outputs.len) {
                    outputs_copy = paths;
                } else {
                    // partial alloc 실패 — cleanup
                    for (paths[0..fill]) |p| allocator.free(p);
                    allocator.free(paths);
                }
            }
        } else if (bundle_opts.output_filename.len > 0) {
            const arr = allocator.alloc([]const u8, 1) catch null;
            if (arr) |paths| {
                if (allocator.dupe(u8, bundle_opts.output_filename)) |dup| {
                    paths[0] = dup;
                    outputs_copy = paths;
                } else |_| {
                    allocator.free(paths);
                }
            }
        }
        ready_event.* = .{
            .files = initial_watch_count,
            .bytes = initial_bytes,
            .outputs = outputs_copy,
            // #3799 root-cause — initial build 의 diagnostics 에 error 가 있으면 별도 노출.
            // success/lifecycle 영향 없음, consumer (runServe onReady) 가 reportError 처리.
            .errors = if (result.hasErrors()) collectErrorsFromResult(allocator, &result) else null,
        };
        if (c.napi_call_threadsafe_function(async_data.ready_tsfn, @ptrCast(ready_event), c.napi_tsfn_blocking) != c.napi_ok) {
            ready_event.deinit(allocator);
        }
    }

    // Issue #1223 Phase 1: 이벤트 기반 워처 + 디바운스 + content hash 필터링.
    while (!async_data.stop_flag.load(.acquire)) {
        const first_events = tracked.waitForChanges(watch_poll_timeout_ms) catch &[_]zntc_lib.server.ChangeEvent{};
        if (async_data.stop_flag.load(.acquire)) break;

        var total_timer: ?IoTimer = IoTimer.start(common.io());
        var detect_timer: ?IoTimer = IoTimer.start(common.io());

        var touched: std.StringHashMap(void) = .init(allocator);
        defer {
            var kit = touched.keyIterator();
            while (kit.next()) |k| allocator.free(k.*);
            touched.deinit();
        }
        collectTouched(&touched, allocator, first_events);

        if (touched.count() == 0) continue;

        // 디바운스: idle 50ms 확보까지 드레인. 지속 변경되는 파일로 인한 기아를 막기 위해
        // 첫 이벤트로부터 watch_debounce_max_ms 초과 시 강제 종료.
        var debounce_timer: ?IoTimer = IoTimer.start(common.io());
        while (!async_data.stop_flag.load(.acquire)) {
            const more = tracked.waitForChanges(watch_debounce_ms) catch break;
            if (more.len == 0) break;
            collectTouched(&touched, allocator, more);
            if (debounce_timer) |*t| {
                if (t.read() / std.time.ns_per_ms > watch_debounce_max_ms) break;
            }
        }
        if (async_data.stop_flag.load(.acquire)) break;

        // issue #3858 — dir event 분리 후 rescan + 신규/삭제 file detect.
        // touched 에 남은 dir path 는 markIfChanged 가 hash 실패로 false 라 사실상
        // noise — remove 후 dir 자체의 rescan trigger 로 활용.
        // 삭제된 file 은 별도 deleted set 으로 받아 markIfChanged 우회 → 아래
        // changed_files 에 직접 push (deleted 의 hashFileStreaming 가 null 이라
        // markIfChanged 가 false 반환, 그대로 두면 changed_files 누락).
        var deleted: std.StringHashMap(void) = .init(allocator);
        defer {
            var dkit = deleted.keyIterator();
            while (dkit.next()) |k| allocator.free(k.*);
            deleted.deinit();
        }
        var dir_paths_in_touched: std.ArrayList([]const u8) = .empty;
        defer dir_paths_in_touched.deinit(allocator);
        var ttit = touched.keyIterator();
        while (ttit.next()) |k| {
            if (tracked.isDirPath(k.*)) dir_paths_in_touched.append(allocator, k.*) catch {};
        }
        if (dir_paths_in_touched.items.len > 0) {
            // dir path 제거 + 각 watch_root 마다 rescan
            for (dir_paths_in_touched.items) |dp| {
                if (touched.fetchRemove(dp)) |kv| allocator.free(kv.key);
            }
            for (async_data.watch_roots) |root| {
                // 신규 sub-dir 도 dynamic dir-watch — addWatchRootDirs 가 tracked.contains
                // (addDirPath 안에서 dir_paths.contains) 로 중복 skip.
                var dummy_count: usize = 0;
                addWatchRootDirs(allocator, root, &tracked, &dummy_count);
                rescanWatchRootDirty(
                    allocator,
                    root,
                    async_data.watch_include,
                    async_data.watch_exclude,
                    &tracked,
                    &touched,
                    &deleted,
                );
            }
        }
        if (touched.count() == 0 and deleted.count() == 0) continue;

        // content hash 필터링. 신규 file 은 markIfChanged 가 첫 hash 등록이라
        // 항상 true 반환 → changed_files 통과.
        var changed_files: std.ArrayList([]const u8) = .empty;
        defer changed_files.deinit(allocator);
        var tkit = touched.keyIterator();
        while (tkit.next()) |pkey| {
            if (tracked.markIfChanged(pkey.*)) {
                changed_files.append(allocator, pkey.*) catch {};
            }
        }
        // issue #3858 — deleted file 은 hash 우회로 changed_files 에 직접 push.
        // caller (zntc.mjs onRebuild) 가 existsSync 로 add/delete 구분.
        var dkit2 = deleted.keyIterator();
        while (dkit2.next()) |pkey| {
            changed_files.append(allocator, pkey.*) catch {};
        }
        const detect_ns: u64 = if (detect_timer) |*t| t.read() else 0;

        if (changed_files.items.len == 0) continue;

        // Profile counters reset — 이전 rebuild 의 누적치가 이월되지 않도록.
        // mask 와 level 은 유지 (`ZNTC_PROFILE=hmr` 등의 활성 상태는 보존).
        // profile 비활성 상태에선 skip — 불필요한 memset 회피.
        if (profile_mod.anyEnabled()) profile_mod.resetCounters();

        // 재번들 — 증분 빌드: persistent_store + persistent_resolve_cache + compiled_cache 재사용
        var incremental_opts = bundle_opts;
        incremental_opts.collect_module_codes = bundle_opts.dev_mode;
        incremental_opts.module_store = &persistent_store;
        incremental_opts.compiled_cache = &async_data.compiled_cache;
        // Watcher-driven mtime cache (Issue #1727 §3): changed 집합을 graph 에 넘겨
        // 나머지 모듈 stat 을 skip 한다. detect 단계에서 이미 content hash 필터링까지
        // 통과한 `touched` 를 그대로 재사용 — StringHashMap 포인터라 복사 없음.
        incremental_opts.changed_files = &touched;
        // Lazy sourcemap (Issue #1727 Phase B): initial build 와 동일 경로 유지. cache 키
        // 일치 필수 — initial 에서 lazy=true 로 put 된 엔트리가 rebuild 에서 hit 해야 함.
        if (bundle_opts.dev_mode and bundle_opts.sourcemap.enable) incremental_opts.sourcemap.lazy = true;
        // dev_mode + collect_module_codes 인 incremental rebuild 는 풀 bundle output 을
        // 다시 concat 할 필요가 없다 — RN HMR client 는 dev_codes 만 사용. wall 시간이
        // emit_concat (~38ms) + emit_sourcemap_finalize (~19ms) 를 절감한다.
        if (bundle_opts.dev_mode and bundle_opts.collect_module_codes) incremental_opts.skip_bundle_output = true;
        // #3802 — `skip_initial_output=true` 가 caller 가 outdir 단독 owner 임을 명시한 케이스.
        // dev_mode 가 false 인 등의 이유로 위 조건이 false 라도, initial-skip 의 invariant
        // "caller 가 outdir 의 owner" 가 incremental rebuild 부터 갑자기 깨지면 사용자 mental
        // model 위반. skip_initial_output=true 면 incremental 도 출력 skip (즉 강제 emit_concat
        // skip). caller 가 outdir 를 단독으로 관리. 단 dev_mode=false + skip_initial_output=true
        // 조합은 incremental rebuild 시 module_dev_codes 도 비어있어 HMR client 가 받을 데이터 없음
        // — 그 조합은 그 자체로 비정상 사용 (caller responsibility).
        if (bundle_opts.skip_initial_output) incremental_opts.skip_bundle_output = true;
        var rebundler = Bundler.initWithResolveCache(allocator, incremental_opts, &persistent_resolve_cache);
        defer rebundler.deinit();

        var rebuild_result = rebundler.bundle(common.io()) catch |err| {
            // 재빌드 실패
            const event = allocator.create(WatchRebuildEvent) catch continue;
            const err_name: [:0]const u8 = @errorName(err);
            event.* = .{
                .success = false,
                .error_msg = allocator.dupe(u8, err_name) catch null,
            };
            if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
                event.deinit();
            }
            continue;
        };
        defer rebuild_result.deinit(allocator);

        // #3799 root-cause fix — rebuild_result.hasErrors() 면 이전 코드는 별도 early-event +
        // continue 였다. 그러나 그러면 module_code_cache / file output / lazy sourcemap swap 등
        // state update path 가 skip 돼 다음 rebuild 가 stale base 위에서 시작. 정확한 design:
        // *success=true 유지* + event.errors 별도 노출 → consumer 가 reportError + Update broadcast
        // 동시 처리. 정상 흐름 그대로 진행.

        async_data.compiled_cache.logStats("");

        // 출력 파일 쓰기 + 바이트 수 계산 (#3795 — outdir 명시 시 결합).
        var output_bytes: usize = 0;
        if (rebuild_result.outputs) |outputs| {
            for (outputs) |o| output_bytes += o.contents.len;
            for (outputs) |o| {
                writeOutputToOutdir(allocator, bundle_opts.outdir, o.path, o.contents);
            }
        } else {
            output_bytes = rebuild_result.output.len;
            if (bundle_opts.output_filename.len > 0) {
                writeOutputToOutdir(allocator, bundle_opts.outdir, bundle_opts.output_filename, rebuild_result.output);
                const sm_path = resolveOutdirPath(allocator, bundle_opts.outdir, bundle_opts.output_filename) catch null;
                if (sm_path) |p| {
                    defer allocator.free(p);
                    // lazy 는 `rebuild_result.sourcemap == null` 이라 helper 안에서 자동 skip.
                    // eager + `emit_disk_sourcemap=false` 도 skip — bungae 처럼 dev server 가
                    // 직접 lazy 라우트를 제공하는 경우.
                    writeSourcemapFile(allocator, p, rebuild_result.sourcemap, async_data.emit_disk_sourcemap);
                }
                // sourcemap helper 호출 후 — 빈 placeholder if 분기 (기존 else 패턴 호환).
                if (false) {}
            }
        }

        // Lazy sourcemap (Issue #1727): rebuild 산출 builder 들을 handle 로 swap.
        // 이전 rebuild 의 builder 는 `swapSourceMapCache` 내부에서 free.
        if (incremental_opts.sourcemap.lazy) {
            const mut_codes: []types_mod.ModuleDevCode = if (rebuild_result.module_dev_codes) |codes|
                @constCast(codes)
            else
                &.{};
            async_data.sm_cache.swap(native_alloc, rebuild_result.sourcemap_builder, mut_codes);
            rebuild_result.sourcemap_builder = null;
        }

        // rebuild 이벤트 생성
        const event = allocator.create(WatchRebuildEvent) catch continue;
        event.* = .{
            .success = true,
            .bytes = output_bytes,
            // #3799 root-cause — rebuild_result.diagnostics 의 error severity 를 같이 노출.
            // success=true 유지 (output / module_code_cache 모두 정상). consumer 가 reportError
            // + Update broadcast 둘 다 처리.
            .errors = if (rebuild_result.hasErrors()) collectErrorsFromResult(allocator, &rebuild_result) else null,
        };

        // changed 파일 목록 복사
        {
            const ch = allocator.alloc([]const u8, changed_files.items.len) catch null;
            if (ch) |ch_arr| {
                var valid: usize = 0;
                for (changed_files.items) |path| {
                    ch_arr[valid] = allocator.dupe(u8, path) catch continue;
                    valid += 1;
                }
                if (valid > 0) {
                    event.changed = ch_arr[0..valid];
                } else {
                    allocator.free(ch_arr);
                }
            }
        }

        // dev mode: HMR diff
        var delta_timer: ?IoTimer = IoTimer.start(common.io());
        if (rebuild_result.module_dev_codes) |dev_codes| {
            // 모듈 ID 집합 비교 — graph 변경 감지
            const graph_changed_flag = blk: {
                if (dev_codes.len != module_code_cache.count()) break :blk true;
                for (dev_codes) |dc| {
                    if (!module_code_cache.contains(dc.id)) break :blk true;
                }
                break :blk false;
            };

            if (graph_changed_flag) {
                event.graph_changed = true;
            } else {
                // 재파싱된 모듈의 path 집합 — cache-hit 모듈의 phantom update 필터용.
                // canonical-name 배정이 rebuild 간 비결정적으로 움직여, 소스가 안 변한
                // 모듈의 emit 결과도 cache 와 달라져 HMR payload 에 섞여 들어오면
                // runtime 의 `__zntc_apply_update` 가 hot-accept 없는 모듈 (React 내부
                // 등) 에 대해 `__zntc_reload` 를 호출해 첫 rebuild 가 full reload 로
                // 끝나는 문제가 있었다 (#번개 실측). reparsed_paths 가 있으면 그
                // 교집합만 업데이트로 올린다.
                var reparsed_set: std.StringHashMap(void) = .init(allocator);
                defer reparsed_set.deinit();
                if (rebuild_result.reparsed_paths) |paths| {
                    for (paths) |p| reparsed_set.put(p, {}) catch {};
                }
                const use_reparsed_filter = reparsed_set.count() > 0;

                // 단일 패스: 캐시와 비교하여 변경된 모듈만 수집
                var update_list: std.ArrayList(WatchRebuildEvent.ModuleUpdate) = .empty;
                for (dev_codes) |dc| {
                    const cached = module_code_cache.get(dc.id);
                    if (cached == null or !std.mem.eql(u8, cached.?, dc.code)) {
                        // 재파싱 목록이 있을 때만 필터 적용. 첫 증분 빌드 이후 캐시가
                        // 안정화되면 자연히 줄어들므로 후속 rebuild 에선 필터가 무해.
                        if (use_reparsed_filter and !reparsed_set.contains(dc.id)) continue;

                        const id_copy = allocator.dupe(u8, dc.id) catch continue;
                        const code_copy = allocator.dupe(u8, dc.code) catch {
                            allocator.free(id_copy);
                            continue;
                        };
                        const map_copy: ?[]const u8 = if (dc.map) |m|
                            (allocator.dupe(u8, m) catch null)
                        else
                            null;
                        update_list.append(allocator, .{ .id = id_copy, .code = code_copy, .map = map_copy }) catch {
                            allocator.free(id_copy);
                            allocator.free(code_copy);
                            if (map_copy) |m| allocator.free(m);
                            continue;
                        };
                    }
                }
                if (update_list.items.len > 0) {
                    event.updates = update_list.toOwnedSlice(allocator) catch null;
                } else {
                    update_list.deinit(allocator);
                    // 코드 변경 없음 — 힙 할당된 빈 슬라이스 (deinit에서 free 가능)
                    event.updates = allocator.alloc(WatchRebuildEvent.ModuleUpdate, 0) catch null;
                }
            }

            // 캐시 업데이트
            {
                var it = module_code_cache.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                module_code_cache.clearRetainingCapacity();
            }
            for (dev_codes) |dc| {
                const id_copy = allocator.dupe(u8, dc.id) catch continue;
                const code_copy = allocator.dupe(u8, dc.code) catch {
                    allocator.free(id_copy);
                    continue;
                };
                module_code_cache.put(id_copy, code_copy) catch {
                    allocator.free(id_copy);
                    allocator.free(code_copy);
                };
            }
        }
        const delta_ns: u64 = if (delta_timer) |*t| t.read() else 0;
        const total_ns: u64 = if (total_timer) |*t| t.read() else 0;

        const nsToMs = bundler_mod.BundleResult.nsToMs;
        event.phase_durations = .{
            // 기본 phase — BundleTimings 기반 (profile 비활성에서도 항상 측정).
            // 필드 이름과 실제 값이 정확히 일치.
            .detect_ms = nsToMs(detect_ns),
            .graph_ms = nsToMs(rebuild_result.timings.graph_ns),
            .link_ms = nsToMs(rebuild_result.timings.link_ns),
            .shake_ms = nsToMs(rebuild_result.timings.shake_ns),
            .emit_ms = nsToMs(rebuild_result.timings.emit_ns),
            .delta_ms = nsToMs(delta_ns),
            .total_ms = nsToMs(total_ns),

            // Sub-phase — profile 활성 시에만 의미있는 값. 비활성이면 0.
            // graph/link/shake 는 기본 phase 와 동일 의미라 중복 노출 안 함.
            .scan_ms = nsToMs(profile_mod.totalNs(.scan)),
            .parse_ms = nsToMs(profile_mod.totalNs(.parse)),
            .resolve_ms = nsToMs(profile_mod.totalNs(.resolve)),
            .semantic_ms = nsToMs(profile_mod.totalNs(.semantic)),
            .transform_ms = nsToMs(profile_mod.totalNs(.transform)),
            .codegen_ms = nsToMs(profile_mod.totalNs(.codegen)),
            .metadata_ms = nsToMs(profile_mod.totalNs(.metadata)),

            // Graph / Emit sub-phase — bundler.zig 내부 단계 분해.
            .graph_build_ms = nsToMs(profile_mod.totalNs(.graph_build)),
            .graph_worker_ms = nsToMs(profile_mod.totalNs(.graph_worker)),
            .graph_discover_ms = nsToMs(profile_mod.totalNs(.graph_discover)),
            .graph_finalize_ms = nsToMs(profile_mod.totalNs(.graph_finalize)),
            .emit_polyfill_ms = nsToMs(profile_mod.totalNs(.emit_polyfill)),
            .emit_refresh_ms = nsToMs(profile_mod.totalNs(.emit_refresh)),
            .emit_output_ms = nsToMs(profile_mod.totalNs(.emit_output)),
            .emit_metafile_ms = nsToMs(profile_mod.totalNs(.emit_metafile)),
            .emit_css_ms = nsToMs(profile_mod.totalNs(.emit_css)),
            .emit_prelude_ms = nsToMs(profile_mod.totalNs(.emit_prelude)),
            .emit_module_pass_ms = nsToMs(profile_mod.totalNs(.emit_module_pass)),
            .emit_concat_ms = nsToMs(profile_mod.totalNs(.emit_concat)),
            .emit_sourcemap_finalize_ms = nsToMs(profile_mod.totalNs(.emit_sourcemap_finalize)),

            // RFC #3940 Sub-PR-L.0e — Link sub-phase. lifecycle redesign 의 RenameTable
            // 도입 (Phase 2) 후 link_compute_renames 측정 baseline 으로 활용.
            .link_build_export_map_ms = nsToMs(profile_mod.totalNs(.link_build_export_map)),
            .link_resolve_imports_ms = nsToMs(profile_mod.totalNs(.link_resolve_imports)),
            .link_compute_renames_ms = nsToMs(profile_mod.totalNs(.link_compute_renames)),
            .link_populate_re_export_aliases_ms = nsToMs(profile_mod.totalNs(.link_populate_re_export_aliases)),
            .link_populate_import_symbols_ms = nsToMs(profile_mod.totalNs(.link_populate_import_symbols)),
            .link_populate_namespace_accesses_ms = nsToMs(profile_mod.totalNs(.link_populate_namespace_accesses)),
        };
        event.reparsed_modules = rebuild_result.reparsed_modules;

        // rebuild 이벤트 전송
        if (c.napi_call_threadsafe_function(async_data.rebuild_tsfn, @ptrCast(event), c.napi_tsfn_blocking) != c.napi_ok) {
            event.deinit();
        }

        // Issue #1223 Phase 1: diff 기반 재-싱크.
        // 모듈 경로가 변하지 않으면 kqueue/inotify 갱신 없이 기존 상태 재사용.
        // 삭제된 모듈의 content_hash 엔트리도 함께 정리하여 무한 증가 방지.
        var desired: std.StringHashMap(void) = .init(allocator);
        defer desired.deinit();
        if (bundle_opts.entry_points.len > 0) {
            desired.put(bundle_opts.entry_points[0], {}) catch {};
        }
        if (rebuild_result.module_paths) |paths| {
            for (paths) |p| desired.put(p, {}) catch {};
        }

        // stale 엔트리 제거 — 워처와 해시 캐시 양쪽에서.
        {
            var stale: std.ArrayList([]const u8) = .empty;
            defer stale.deinit(allocator);
            var hit = tracked.keyIterator();
            while (hit.next()) |k| {
                if (!desired.contains(k.*)) stale.append(allocator, k.*) catch {};
            }
            for (stale.items) |k| tracked.removePath(k);
        }

        // 추가된 경로만 addPath + 해시. 기존 경로는 kqueue/inotify에 이미 등록됨.
        var dit = desired.keyIterator();
        while (dit.next()) |pkey| {
            if (tracked.contains(pkey.*)) continue;
            _ = tracked.addPath(pkey.*, false);
        }
    }

    // 스레드 종료: TSFN 해제
    _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
    _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);

    // async_data는 stop handle의 reference가 해제될 때까지 유지되어야 한다.
    // stop()이 호출되면 stop_flag가 설정되고, 여기에 도달한다.
    // stop handle의 ref가 GC되면 wrap의 weak ref callback으로 정리.
    // 단, TSFN은 이미 release했으므로 플러그인/문자열만 정리.
    async_data.deinit();
}

/// handle.getBundleSourceMap() — 번들 전체 sourcemap JSON 을 lazy 생성해 반환.
/// handle 에 캐시된 `latest_bundle_sm` builder 가 있으면 `generateJSON` 을 호출해 V3 JSON
/// 문자열을 NAPI string 으로 돌려준다. sourcemap 비활성/미캐시/stop 후에는 null.
/// `sm_mutex` 로 rebuild swap 및 다른 getter 호출과 직렬화 (builder.buf 재진입 금지).
fn napiWatchGetBundleSourceMap(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 0;
    var this: c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, null, &this, null) != c.napi_ok) {
        return throwError(env, "failed to get this");
    }

    const async_data = unwrapNapi(WatchAsyncData, env, this) orelse {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    };

    async_data.sm_cache.mutex.lock();
    defer async_data.sm_cache.mutex.unlock();

    const builder = async_data.sm_cache.bundle orelse {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    };

    const json = builder.generateJSON(async_data.options.output_filename) catch |err| {
        return throwError(env, @errorName(err));
    };

    var js_str: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, json.ptr, json.len, &js_str) != c.napi_ok) {
        return throwError(env, "failed to create string");
    }
    return js_str;
}

/// handle.getHmrSourceMap(moduleId) — per-module sourcemap JSON 을 lazy 생성해 반환.
/// 최신 rebuild 에서 수집된 모듈별 builder 중 `moduleId` 에 해당하는 것을 찾아 `generateJSON`.
/// 모듈이 최신 rebuild 에 포함되지 않았거나 sourcemap 비활성이면 null.
fn napiWatchGetHmrSourceMap(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    var this: c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, &this, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "getHmrSourceMap requires moduleId argument");

    const async_data = unwrapNapi(WatchAsyncData, env, this) orelse {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    };

    const module_id = getStringArg(env, argv[0], native_alloc) orelse return throwError(env, "moduleId is empty");
    defer native_alloc.free(module_id);

    async_data.sm_cache.mutex.lock();
    defer async_data.sm_cache.mutex.unlock();

    const builder = async_data.sm_cache.modules.get(module_id) orelse {
        var js_null: c.napi_value = undefined;
        _ = c.napi_get_null(env, &js_null);
        return js_null;
    };

    const json = builder.generateJSON(module_id) catch |err| {
        return throwError(env, @errorName(err));
    };

    var js_str: c.napi_value = undefined;
    if (c.napi_create_string_utf8(env, json.ptr, json.len, &js_str) != c.napi_ok) {
        return throwError(env, "failed to create string");
    }
    return js_str;
}

/// stop() 네이티브 메서드 — JS에서 handle.stop() 호출 시
fn napiWatchStop(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    // this 객체에서 WatchAsyncData 포인터 추출
    var argc: usize = 0;
    var this: c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, null, &this, null) != c.napi_ok) {
        return throwError(env, "failed to get this");
    }

    // napi_remove_wrap: 포인터를 추출하면서 wrap 해제 (double stop 방지)
    var async_data_ptr: ?*anyopaque = null;
    if (c.napi_remove_wrap(env, this, &async_data_ptr) != c.napi_ok) {
        // 이미 stop()이 호출된 경우 — 무시
        var js_undefined: c.napi_value = undefined;
        _ = c.napi_get_undefined(env, &js_undefined);
        return js_undefined;
    }
    if (async_data_ptr) |ptr| {
        const async_data: *WatchAsyncData = @ptrCast(@alignCast(ptr));
        async_data.stop_flag.store(true, .release);
        // #3794 — worker thread 가 polling cycle 마다 stop_flag 를 체크해 종료하므로 fire-and-forget
        // 이었다. caller (closeServerForRestart) 가 child process spawn 전에 부모 worker 의 outdir
        // 쓰기가 완전히 멈췄음을 보장하려면 worker 의 deinit 진입까지 wait 해야 함. 5초 timeout 으로
        // deadlock 방어 — polling timeout (수십~수백ms) 의 충분한 배수.
        // 0.16: ResetEvent.timedWait 제거 → Io.Event.waitTimeout + 절대 deadline
        // (spurious wakeup 은 error.Timeout 이므로 deadline 미래면 재대기). best-effort.
        const stop_io = common.io();
        const stop_deadline: std.Io.Timeout = (std.Io.Timeout{ .duration = .{ .raw = std.Io.Duration.fromSeconds(5), .clock = .awake } }).toDeadline(stop_io);
        while (true) {
            async_data.stop_complete.waitTimeout(stop_io, stop_deadline) catch {
                if (stop_deadline.toDurationFromNow(stop_io)) |d| {
                    if (d.raw.toNanoseconds() > 0) continue;
                }
                break;
            };
            break;
        }
    }

    var js_undefined: c.napi_value = undefined;
    _ = c.napi_get_undefined(env, &js_undefined);
    return js_undefined;
}

pub fn napiWatch(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argc: usize = 1;
    var argv: [1]c.napi_value = undefined;
    if (c.napi_get_cb_info(env, info, &argc, &argv, null, null) != c.napi_ok) {
        return throwError(env, "failed to get arguments");
    }
    if (argc < 1) return throwError(env, "watch requires an options object");

    // async data 할당
    const async_data = native_alloc.create(WatchAsyncData) catch return throwError(env, "OutOfMemory");
    async_data.* = .{
        .env = env,
        .options = undefined,
        .owned_strings = .empty,
        .owned_string_arrays = .empty,
        .napi_plugins = .empty,
        .zig_plugins = .empty,
        .ready_tsfn = undefined,
        .rebuild_tsfn = undefined,
        .stop_flag = std.atomic.Value(bool).init(false),
        .compiled_cache = bundler_mod.CompiledOutputCache.init(native_alloc),
    };

    // watchFolders/watchInclude/watchExclude 파싱 (parseBuildOptions 바깥에서 수집)
    inline for (.{
        .{ "watchFolders", "watch_roots" },
        .{ "watchInclude", "watch_include" },
        .{ "watchExclude", "watch_exclude" },
    }) |pair| {
        if (getObjectStringArray(env, argv[0], pair[0], native_alloc)) |arr| {
            const ok = blk: {
                for (arr) |s| async_data.owned_strings.append(native_alloc, s) catch break :blk false;
                async_data.owned_string_arrays.append(native_alloc, arr) catch break :blk false;
                break :blk true;
            };
            if (!ok) {
                native_alloc.destroy(async_data);
                return throwError(env, "OutOfMemory");
            }
            @field(async_data.*, pair[1]) = arr;
        }
    }

    // 옵션 파싱
    var opts = parseBuildOptions(env, argv[0], &async_data.owned_strings, &async_data.owned_string_arrays) orelse {
        native_alloc.destroy(async_data);
        return throwError(env, "invalid watch options");
    };

    // _pluginDispatcher가 있으면 NapiPlugin 생성 (napiBuild와 동일 패턴)
    if (getNamedProperty(env, argv[0], "_pluginDispatcher")) |dispatcher_fn| {
        const np = native_alloc.create(NapiPlugin) catch {
            native_alloc.destroy(async_data);
            return throwError(env, "OutOfMemory");
        };
        np.* = .{
            .name = native_alloc.dupe(u8, "js-plugin") catch {
                native_alloc.destroy(np);
                native_alloc.destroy(async_data);
                return throwError(env, "OutOfMemory");
            },
            .tsfn = undefined,
        };

        var resource_name_str: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zntc_watch_plugin", "zntc_watch_plugin".len, &resource_name_str);
        if (c.napi_create_threadsafe_function(
            env,
            dispatcher_fn,
            null,
            resource_name_str,
            0,
            1,
            null,
            null,
            @ptrCast(np),
            NapiPlugin.callJsCallback,
            &np.tsfn,
        ) != c.napi_ok) {
            native_alloc.free(np.name);
            native_alloc.destroy(np);
            native_alloc.destroy(async_data);
            return throwError(env, "failed to create threadsafe function");
        }

        async_data.napi_plugins.append(native_alloc, np) catch {};
        async_data.zig_plugins.append(native_alloc, np.toPlugin()) catch {};
        opts.plugins = async_data.zig_plugins.items;
    }

    // _manualChunks JS 함수가 있으면 TSFN 으로 감싸 Zig resolver 로 연결 (#1027 Phase 2).
    if (getNamedProperty(env, argv[0], "_manualChunks")) |fn_val| {
        if (installManualChunksResolver(env, fn_val, &opts)) |resolver| {
            async_data.napi_manual_chunks = resolver;
        } else {
            native_alloc.destroy(async_data);
            return throwError(env, "failed to install manualChunks resolver");
        }
    }

    async_data.options = opts;
    // `emitDiskSourcemap` 옵션 (기본 true) — bungae 등 lazy 라우트를 갖춘 dev server 는
    // false 로 보내 rebuild 경로의 `.map` 디스크 I/O 를 완전히 제거한다.
    async_data.emit_disk_sourcemap = getObjectBool(env, argv[0], "emitDiskSourcemap", true);

    // onReady 콜백 추출
    const on_ready_fn = getNamedProperty(env, argv[0], "onReady");

    // onRebuild 콜백 추출
    const on_rebuild_fn = getNamedProperty(env, argv[0], "onRebuild");

    // onReady TSFN 생성
    {
        var resource_name: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zntc_watch_ready", "zntc_watch_ready".len, &resource_name);
        if (c.napi_create_threadsafe_function(
            env,
            on_ready_fn orelse null,
            null,
            resource_name,
            0,
            1,
            null,
            null,
            null,
            watchReadyTsfn,
            &async_data.ready_tsfn,
        ) != c.napi_ok) {
            async_data.deinit();
            return throwError(env, "failed to create ready tsfn");
        }
    }

    // onRebuild TSFN 생성
    {
        var resource_name: c.napi_value = undefined;
        _ = c.napi_create_string_utf8(env, "zntc_watch_rebuild", "zntc_watch_rebuild".len, &resource_name);
        if (c.napi_create_threadsafe_function(
            env,
            on_rebuild_fn orelse null,
            null,
            resource_name,
            0,
            1,
            null,
            null,
            null,
            watchRebuildTsfn,
            &async_data.rebuild_tsfn,
        ) != c.napi_ok) {
            _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
            async_data.deinit();
            return throwError(env, "failed to create rebuild tsfn");
        }
    }

    // TSFN의 ref를 해제하여 watch 스레드만으로는 Node.js 프로세스가 종료되는 것을 막지 않도록 한다.
    // (stop() 호출 없이도 프로세스가 종료되도록)
    _ = c.napi_unref_threadsafe_function(env, async_data.ready_tsfn);
    _ = c.napi_unref_threadsafe_function(env, async_data.rebuild_tsfn);

    // 리턴할 handle 객체 생성: { stop() }
    var js_handle: c.napi_value = undefined;
    if (c.napi_create_object(env, &js_handle) != c.napi_ok) {
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return throwError(env, "failed to create handle object");
    }

    // napi_wrap으로 async_data를 handle 객체에 연결
    if (c.napi_wrap(env, js_handle, @ptrCast(async_data), null, null, null) != c.napi_ok) {
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return throwError(env, "failed to wrap handle");
    }

    // stop() 메서드 추가
    var stop_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "stop", "stop".len, napiWatchStop, null, &stop_fn);
    _ = c.napi_set_named_property(env, js_handle, "stop", stop_fn);

    // Lazy sourcemap getter 2 개 추가 (Issue #1727 Phase B).
    // dev server (bungae 등) 가 `/bundle.js.map` / `/hmr-map/:id` 요청받으면 호출.
    var get_bundle_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "getBundleSourceMap", "getBundleSourceMap".len, napiWatchGetBundleSourceMap, null, &get_bundle_fn);
    _ = c.napi_set_named_property(env, js_handle, "getBundleSourceMap", get_bundle_fn);

    var get_hmr_fn: c.napi_value = undefined;
    _ = c.napi_create_function(env, "getHmrSourceMap", "getHmrSourceMap".len, napiWatchGetHmrSourceMap, null, &get_hmr_fn);
    _ = c.napi_set_named_property(env, js_handle, "getHmrSourceMap", get_hmr_fn);

    // 워커 스레드 시작
    const thread = std.Thread.spawn(.{}, watchWorkerThread, .{async_data}) catch {
        _ = c.napi_release_threadsafe_function(async_data.ready_tsfn, c.napi_tsfn_release);
        _ = c.napi_release_threadsafe_function(async_data.rebuild_tsfn, c.napi_tsfn_release);
        async_data.deinit();
        return throwError(env, "failed to spawn watch thread");
    };
    thread.detach();

    return js_handle;
}

// ─── 모듈 등록 ───
