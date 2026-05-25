//! ZNTC 프로파일링 인프라.
//!
//! 파이프라인 단계별 (scan / parse / semantic / transform / codegen / ...)
//! 타이밍을 카테고리 토글 방식으로 수집한다. 비활성 카테고리는 `enabled()` 의
//! 분기 한 번만 통과하므로 hot path 영향 최소 (Release 비활성 < 1% overhead 목표).
//!
//! ### 사용법 (코드 삽입)
//! ```zig
//! const profile = @import("profile.zig");
//!
//! fn someFunction() !void {
//!     var scope = profile.begin(.parse);
//!     defer scope.end();
//!
//!     // ... work ...
//! }
//! ```
//!
//! ### 활성화 (진입점)
//! - env: `ZNTC_PROFILE=all` / `ZNTC_PROFILE=parse,transform`
//! - CLI (PR 2): `--profile=all --profile-level=detailed`
//! - NAPI (PR 2): `BundleOptions.profile = [...]`
//!
//! ### Category 추가
//! `Category` enum 에 이름 추가 → 끝. Parent/child 관계는 이름 prefix 로 (dot notation:
//! `parse.ast_build` = enum `parse_ast_build`, parent 활성 시 자동으로 child 도 활성).
//!
//! ### 설계 근거
//! 자세한 내용은 `docs/design/profile-infrastructure.md`.

const std = @import("std");
const builtin = @import("builtin");

/// counters(`totals_ns` 등)를 atomic 으로 갱신할지 여부 (comptime).
///
/// native multi-thread 빌드는 worker pool 에서 phase 가 동시에 끝나므로 atomic add 가
/// 필요하다(lost update 방지). 단, 타깃이 해당 counter 폭의 atomic 을 지원하지 않으면 mutex
/// fallback 을 쓴다:
/// - `single_threaded` 빌드(transpile-only `zig build wasm`) — race 자체가 없음.
/// - WASM — Zig 0.15.2 는 64-bit atomic RMW(`@atomicRmw(u64, …)`)를 지원하지 않는다
///   (atomics feature 가 있는 `wasm-bundler` 타깃도 "expected 32-bit integer type or
///   smaller" 로 컴파일 실패). wasm-bundler 가 multi-thread 면 프로파일 카운터만 mutex 로
///   느려질 수 있고, 번들 결과와는 무관하다.
/// - 32-bit native targets — `u64` timing counters 는 atomic 불가지만 `u32` counts 는
///   계속 atomic 가능하다.
inline fn useAtomicCounter(comptime T: type) bool {
    return !builtin.single_threaded and
        !builtin.cpu.arch.isWasm() and
        @bitSizeOf(T) <= @bitSizeOf(usize);
}

var counter_mutex: std.Thread.Mutex = .{};

inline fn atomicAdd(comptime T: type, slot: *T, delta: T) void {
    if (useAtomicCounter(T)) {
        _ = @atomicRmw(T, slot, .Add, delta, .monotonic);
    } else if (!builtin.single_threaded) {
        counter_mutex.lock();
        defer counter_mutex.unlock();
        slot.* += delta;
    } else {
        slot.* += delta;
    }
}

inline fn atomicGet(comptime T: type, slot: *const T) T {
    if (useAtomicCounter(T)) return @atomicLoad(T, slot, .monotonic);
    if (!builtin.single_threaded) {
        counter_mutex.lock();
        defer counter_mutex.unlock();
        return slot.*;
    }
    return slot.*;
}

// ============================================================================
// Category & Level
// ============================================================================

/// 프로파일링 카테고리. 새 phase 추가 시 여기에 이름 추가.
///
/// **Dot notation**: `parse.ast_build` 는 enum 식별자 `parse_ast_build` 로 저장된다.
/// `fromString` 이 `.` 를 `_` 로 자동 정규화. 표시는 `displayName` 이 역변환.
///
/// **Parent/child**: prefix 매칭으로 활성 전파. `parse` 활성 시 `parse_ast_build`,
/// `parse_<anything>` 전부 자동 활성. 반대로 `parse_ast_build` 만 지정하면 `parse`
/// 는 활성 안 됨 (하위만 수집).
pub const Category = enum {
    // ── Parsing ──
    scan,
    parse,
    parse_ast_build,
    parse_program,
    parse_statement,
    parse_module_import,
    parse_module_export,
    parse_expression_assignment,

    // ── Analysis ──
    semantic,
    resolve,
    resolve_external,
    resolve_cache_key,
    resolve_cache_lookup,
    resolve_browser_override,
    resolve_resolver,
    resolve_resolver_pkg_json,
    resolve_resolver_exports,
    resolve_cache_store,
    resolve_path,
    resolve_file_exists,
    resolve_extensions,
    resolve_ts_extension_map,
    resolve_directory_index,
    resolve_realpath,
    graph,
    graph_build,
    graph_worker,
    graph_discover,
    graph_discover_scan_worker,
    graph_discover_scan_worker_parse,
    graph_discover_scan_worker_resolve,
    graph_discover_apply,
    graph_discover_pm_setup,
    graph_discover_pm_setup_read,
    graph_discover_pm_setup_read_file,
    graph_discover_pm_setup_read_with_stat,
    graph_discover_pm_setup_read_open,
    graph_discover_pm_setup_read_stat,
    graph_discover_pm_setup_read_bytes,
    graph_discover_pm_setup_read_close,
    graph_discover_pm_setup_parser,
    graph_discover_pm_parse,
    graph_discover_pm_semantic,
    graph_discover_pm_post,
    graph_discover_pm_post_records,
    graph_discover_pm_post_optional_requires,
    graph_discover_pm_post_worker_records,
    graph_discover_pm_post_namespace_access,
    graph_discover_pm_post_synthetic_symbols,
    graph_discover_pm_post_jsx_imports,
    graph_discover_pm_prepass,
    graph_discover_pm_prepass_decision,
    graph_discover_pm_prepass_decision_module_gate,
    graph_discover_pm_prepass_decision_ast_flags,
    graph_discover_pm_prepass_decision_options,
    graph_discover_pm_prepass_decision_unsupported_walk,
    graph_discover_pm_prepass_run,
    graph_discover_pm_is_pkg_type,
    // Incremental rebuild hot path (build_flow.zig:buildIncremental).
    // M0 측정값 (lodash-es 641 module warm) 의 47ms 를 sub-phase 로 분해해서
    // 어느 단계가 dominant 인지 측정한다. graph_discover_pm_* 와 동위 prefix.
    graph_discover_incr_mtime, // mtime 결정 (watcher skip → cached / fallback stat)
    graph_discover_incr_cache_lookup, // store.getIfFresh — fresh 판정 (hash + mtime 비교)
    graph_discover_incr_cache_hit_assign, // 캐시 히트 시 Module struct 복원 + ownership 이전
    graph_discover_incr_miss_parse, // 캐시 미스 — parseModule + sideEffects 적용
    graph_discover_incr_replay, // 히트 분기: replay cached resolved deps + deferred imports
    // replay 내부 분해 (PR-M3): parallel 가능 vs main-thread mutex 비중 격리.
    // 47ms warm 의 95% 가 replay. 진짜 ROI 검증을 위해 hot path 의 4 sub-step 측정.
    graph_discover_incr_replay_add_module, // addModuleWithResolveDir — path_to_module HashMap put
    graph_discover_incr_replay_request_exports, // requestDependencyExports — requested_exports HashMap mutation
    graph_discover_incr_replay_record_dep, // recordResolvedDep — import_records write + linkDependency/linkDynamicImport
    graph_discover_incr_replay_other, // virtual/disabled/optional/external/worker 분기 + 부수 work
    // requestDependencyExports 의 3 분기 (PR-M4). 37ms 단일 함수의 어느 분기가 dominant 인지.
    graph_discover_incr_req_static_import, // static_import — import_bindings iterate + requestNamed/All
    graph_discover_incr_req_re_export, // re_export — requestedExportsForReExportRecord (cross-product loop)
    graph_discover_incr_req_simple, // side_effect/require/dyn/worker/glob/require_context — requestAll
    // requestNamed/requestAll 내부 4-way (PR-M5). M4 결과 re_export 42% 절감 후 잔여 18ms
    // 의 진짜 dominant 격리. mutex / outer HashMap / inner contains / inner put.
    graph_discover_incr_req_mutex, // requested_exports_mutex.lock+unlock cost
    graph_discover_incr_req_outer_map, // self.requested_exports.getOrPut(mod_idx key)
    graph_discover_incr_req_inner_contains, // names.contains(name) (inner HashMap)
    graph_discover_incr_req_inner_put, // names.put(name, {}) (inner HashMap)
    // re_export caller side decomposition (PR-M6). M5 가 lock+map=17% 만 격리 → 나머지 83%
    // (caller) 의 진짜 dominant 찾기. entry setup (requested_names 복사 + has_star scan) 와
    // outer loop body (per-name lookup + branch) 분리.
    graph_discover_incr_re_export_entry, // 함수 진입 시 setup (requested_names 복사 + star scan)
    // entry 내부 3-way (PR-M7). Z1 후 entry 5.6ms 의 진짜 dominant 식별.
    graph_discover_incr_re_export_entry_get, // requested_exports.get (outer HashMap lookup)
    graph_discover_incr_re_export_entry_copy, // names.keyIterator + stack/heap append (Z1 buffer)
    graph_discover_incr_re_export_entry_star_scan, // has_star_for_rec scan (export_bindings 순회)
    graph_discover_incr_re_export_outer, // outer loop body (per-name index lookup + branch)
    // record_dep + add_module 내부 분해 (PR-M8). Z2 후 잔여 22ms 의 다음 후보:
    // record_dep 5.7ms (linkDep 양방향 append + import_records write)
    // add_module 4.3ms (path_to_module.get + alloc + dup + put + preopenDir)
    graph_discover_incr_record_dep_rec_write, // import_records[rec_i].resolved = dep_idx (single store)
    graph_discover_incr_record_dep_link, // linkDependency/linkDynamicImport (양방향 ArrayList append)
    graph_discover_incr_add_module_dedup, // path_to_module.get(abs_path) — dedup 분기
    graph_discover_incr_add_module_alloc, // Module.init + path/dir dupe + slot alloc
    graph_discover_incr_add_module_put, // path_to_module.put + modules.append
    graph_discover_incr_add_module_preopen, // source_read_cache.preopenDir
    graph_discover_incr_miss_resolve, // 미스 분기: resolveModuleImports (대칭 측정용)
    graph_finalize,
    graph_renumber,
    graph_resync,
    graph_resync_const,
    graph_resync_semantic,
    graph_resync_stmt_info,
    graph_resync_import_scan,
    graph_resync_import_bindings,
    graph_resync_export_bindings,
    graph_resync_classify,
    graph_resync_alias,
    graph_resync_binding_refs,
    graph_runtime_polyfills,
    graph_runtime_polyfills_collect,
    graph_runtime_polyfills_aggregate,
    graph_runtime_polyfills_inject,

    // ── Linking / Tree-shaking ──
    link,
    link_build_export_map,
    link_resolve_imports,
    link_compute_renames,
    link_compute_mangling,
    link_populate_re_export_aliases,
    link_populate_import_symbols,
    link_populate_namespace_accesses,
    shake,
    shake_init,
    shake_analyze,
    shake_post_link_finalize,
    shake_setup,
    shake_const_prepass,
    shake_const_prepass_full_materialize,
    shake_const_prepass_numeric_propagate,
    shake_const_prepass_numeric_seed_scan,
    shake_const_prepass_numeric_queue,
    shake_const_prepass_build_facts,
    shake_const_prepass_build_facts_resolve,
    shake_const_prepass_build_facts_lookup,
    shake_const_prepass_candidate_gate,
    shake_const_prepass_materialize,
    shake_const_prepass_forbidden,
    shake_const_prepass_reachable,
    shake_const_prepass_replace,
    shake_const_prepass_minify_resync,
    shake_const_prepass_node_buffer,
    shake_const_prepass_link_refresh,
    shake_purity,
    shake_stmt_info,
    shake_fixpoint,
    shake_fixpoint_sym_to_ib,
    shake_fixpoint_bfs,
    shake_fixpoint_bfs_seed,
    shake_fixpoint_bfs_queue,
    shake_fixpoint_bfs_follow_import,
    shake_fixpoint_bfs_seed_export,
    shake_fixpoint_bfs_seed_export_direct,
    shake_fixpoint_bfs_require_scan,
    shake_fixpoint_bfs_final_mark_exports,
    shake_fixpoint_bfs_enqueue_side_effects,
    shake_fixpoint_bfs_seed_export_resolve,
    shake_fixpoint_bfs_seed_export_mark,
    shake_fixpoint_bfs_seed_export_cjs,
    shake_fixpoint_bfs_seed_export_namespace_scan,
    shake_fixpoint_bfs_seed_export_intermediate,
    shake_fixpoint_bfs_seed_export_semantic_lookup,
    shake_fixpoint_bfs_seed_export_enqueue_symbol,
    shake_fixpoint_bfs_seed_export_opaque,
    shake_fixpoint_process_imports,
    shake_fixpoint_re_exports,
    shake_fixpoint_re_exports_module,
    shake_fixpoint_eval_deps,
    shake_prune,
    shake_numeric_postpass,
    shake_numeric_postpass_queue_seed,
    shake_numeric_postpass_queue,
    shake_numeric_postpass_build_facts,
    shake_numeric_postpass_build_facts_resolve,
    shake_numeric_postpass_build_facts_lookup,
    shake_numeric_postpass_candidate_gate,
    shake_numeric_postpass_materialize,
    shake_numeric_postpass_forbidden,
    shake_numeric_postpass_reachable,
    shake_numeric_postpass_replace,
    shake_numeric_postpass_minify_resync,
    shake_numeric_postpass_minify,
    shake_numeric_postpass_resync,
    shake_numeric_postpass_minify_skip,
    shake_mirror,
    metadata,
    metadata_skip_nodes,
    metadata_import_bindings,
    metadata_register_ns_rewrites,
    metadata_merge_phase_b,
    metadata_finalize_ns,
    metadata_require_rewrites,
    metadata_final_exports,

    // ── Transform ──
    transform,
    transform_ts_strip,
    transform_jsx,
    transform_class_field,
    transform_decorator,
    transform_pass2,

    // ── Codegen ──
    codegen,
    codegen_walk,
    codegen_sourcemap,
    // (C1 도구 보강) sub-phase 측정
    codegen_setup, // collectTopLevelDeclNames + ensureTotalCapacity
    codegen_emit, // emitNode (program 전체)
    codegen_finalize, // keep_names + finalize
    codegen_sm_add, // addSourceMapping 누적 (매 노드)

    // ── Top-level emit ──
    emit,
    emit_polyfill,
    emit_refresh,
    emit_output,
    emit_metafile,
    emit_css,
    // ── emit_output 내부 (emitter.emitWithTreeShaking 분해) ──
    emit_prelude,
    emit_module_pass,
    emit_concat,
    emit_sourcemap_finalize,

    // ── HMR ──
    hmr,
    hmr_detect,
    hmr_delta,

    // ── Cache ──
    cache,

    /// Category 이름으로 enum 조회 (대소문자 무시 + dot→underscore 정규화 + 공백 제거).
    /// 예: `"parse.ast_build"`, `"Parse.AST_Build"`, `" parse "` 모두 매칭.
    pub fn fromString(s: []const u8) ?Category {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return null;

        var buf: [64]u8 = undefined;
        if (trimmed.len > buf.len) return null;
        for (trimmed, 0..) |c, i| {
            buf[i] = if (c == '.') '_' else std.ascii.toLower(c);
        }
        const normalized = buf[0..trimmed.len];

        inline for (@typeInfo(Category).@"enum".fields) |f| {
            if (std.mem.eql(u8, normalized, f.name)) {
                return @field(Category, f.name);
            }
        }
        return null;
    }

    /// 표시용 이름 — underscore 를 dot 으로 변환해 `parse.ast_build` 처럼.
    pub fn displayName(cat: Category) []const u8 {
        return switch (cat) {
            inline else => |c| comptime blk: {
                @setEvalBranchQuota(20000);
                const name = @tagName(c);
                var buf: [name.len]u8 = undefined;
                for (name, 0..) |ch, i| {
                    buf[i] = if (ch == '_') '.' else ch;
                }
                const out = buf;
                break :blk &out;
            },
        };
    }
};

/// 프로파일링 상세도.
pub const Level = enum {
    /// Phase 총합만 (default).
    summary,
    /// Sub-phase (e.g. `transform.jsx`) 까지 표시.
    detailed,
    /// 모듈별 breakdown.
    per_module,
    /// Transformer visit 함수 수준 (가장 세밀).
    per_pass,

    pub fn fromString(s: []const u8) ?Level {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(trimmed, "summary")) return .summary;
        if (std.ascii.eqlIgnoreCase(trimmed, "detailed")) return .detailed;
        if (std.ascii.eqlIgnoreCase(trimmed, "per-module") or
            std.ascii.eqlIgnoreCase(trimmed, "per_module")) return .per_module;
        if (std.ascii.eqlIgnoreCase(trimmed, "per-pass") or
            std.ascii.eqlIgnoreCase(trimmed, "per_pass")) return .per_pass;
        return null;
    }
};

/// 리포트 출력 포맷.
pub const Format = enum {
    table,
    tree,
    json,
    csv,

    pub fn fromString(s: []const u8) ?Format {
        const trimmed = std.mem.trim(u8, s, " \t");
        if (trimmed.len == 0) return null;
        if (std.ascii.eqlIgnoreCase(trimmed, "table")) return .table;
        if (std.ascii.eqlIgnoreCase(trimmed, "tree")) return .tree;
        if (std.ascii.eqlIgnoreCase(trimmed, "json")) return .json;
        if (std.ascii.eqlIgnoreCase(trimmed, "csv")) return .csv;
        return null;
    }
};

// ============================================================================
// State (process-global)
// ============================================================================

/// Category 수. `ProfileMask` 크기와 counters 배열의 comptime 길이로 사용한다.
pub const num_categories = @typeInfo(Category).@"enum".fields.len;

const all_categories: [num_categories]Category = blk: {
    var cats: [num_categories]Category = undefined;
    for (@typeInfo(Category).@"enum".fields, 0..) |f, i| {
        cats[i] = @field(Category, f.name);
    }
    break :blk cats;
};

const ProfileMask = std.StaticBitSet(num_categories);

/// 활성 카테고리 비트마스크. hot path 에서는 `enabled()` 의 bitset lookup 만 수행.
/// 프로세스 전역 — 초기화 후 read-only 로 다뤄 thread-safe.
var enabled_mask: ProfileMask = ProfileMask.initEmpty();

/// 현재 level. Reporter 가 어떤 수준까지 노출할지 결정.
var current_level: Level = .summary;

/// 각 category 별 누적 시간 (ns) — 모든 스레드 합산.
/// Parent scope 전체 시간을 보존하는 inclusive total 이다.
/// 번들러는 phase 를 thread pool 에서 돌리므로 increment 는 atomic 으로 한다 (`recordTiming`).
/// 읽기(`totalNs` 등 / reporter)는 worker join 이후라 race 없지만 일관성 위해 atomic load.
var totals_ns: [num_categories]u64 = [_]u64{0} ** num_categories;

/// 각 category 별 child scope 제외 시간 (ns) — 모든 스레드 합산.
/// `total_ms` 는 기존 호환성을 위해 inclusive 로 유지하고, 전체 합계/JSON self_ms 는
/// 이 값을 사용해 nested phase 중복 합산을 피한다.
var self_totals_ns: [num_categories]u64 = [_]u64{0} ** num_categories;

/// 각 category 별 호출 횟수 — 모든 스레드 합산.
var counts: [num_categories]u32 = [_]u32{0} ** num_categories;

const max_scope_depth = 128;

const ActiveScope = struct {
    child_ns: u64 = 0,
};

/// Scope nesting 스택은 **스레드별** 로 둔다. 예전엔 프로세스 전역이라 worker thread 들이
/// 같은 스택을 동시에 push/pop → `stack_index` 계산이 깨지면서 parent scope 가 자기
/// inclusive 시간을 전부 self 로 기록 → 합계가 wall time 의 수십 배로 부풀던 버그.
threadlocal var active_scopes: [max_scope_depth]ActiveScope = [_]ActiveScope{.{}} ** max_scope_depth;
threadlocal var active_scope_len: u8 = 0;

/// 프로파일 활성화 시점 — reporter 가 wall-clock 경과를 함께 보여주려고 보관.
/// Σself(모든 스레드 누적)은 병렬 구간 때문에 wall 보다 클 수 있어 비교 기준이 필요하다.
/// 활성화(`addFromCsv`/`addCategories`)는 worker thread 가 생기기 전 startup 에서 1회뿐이라
/// hot path(`begin`) 에 검사를 둘 필요 없이 여기서 한 번 찍는다.
var wall_start: ?std.time.Instant = null;

// ============================================================================
// Activation API (CLI / NAPI / env 공용)
// ============================================================================

/// 활성 여부 조회 (inline bitset lookup — hot path 용).
pub inline fn enabled(cat: Category) bool {
    return enabled_mask.isSet(@intFromEnum(cat));
}

/// 하나라도 활성화된 category 가 있는지. HMR rebuild 에서 counters reset 을 조건부로
/// 수행할 때 사용 (비활성 상태의 불필요한 memset 회피).
pub inline fn anyEnabled() bool {
    return enabled_mask.count() != 0;
}

/// Level 조회.
pub inline fn level() Level {
    return current_level;
}

/// Level 설정 (CLI / NAPI entry 에서 호출).
pub fn setLevel(lv: Level) void {
    current_level = lv;
}

/// 활성화된 직후 호출 — wall-clock 기준점을 1회 찍는다 (이미 찍혔으면 no-op).
fn markActivated() void {
    if (wall_start == null and anyEnabled()) wall_start = std.time.Instant.now() catch null;
}

/// 쉼표 구분 카테고리 목록을 mask 에 합집합으로 추가. `all` / `none` 키워드 지원.
/// Parent category 지정 시 child (prefix 매칭) 도 자동 활성.
pub fn addFromCsv(csv: []const u8) void {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(name, "all")) {
            enabled_mask = ProfileMask.initFull();
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "none")) {
            enabled_mask = ProfileMask.initEmpty();
            continue;
        }
        if (Category.fromString(name)) |c| {
            enableCategoryAndChildren(c);
        }
    }
    markActivated();
}

/// 문자열 배열을 mask 에 합집합으로 추가 (NAPI option 용).
pub fn addCategories(names: []const []const u8) void {
    for (names) |name| {
        if (std.ascii.eqlIgnoreCase(name, "all")) {
            enabled_mask = ProfileMask.initFull();
            continue;
        }
        if (std.ascii.eqlIgnoreCase(name, "none")) {
            enabled_mask = ProfileMask.initEmpty();
            continue;
        }
        if (Category.fromString(name)) |c| {
            enableCategoryAndChildren(c);
        }
    }
    markActivated();
}

/// `ZNTC_PROFILE` / `ZNTC_PROFILE_LEVEL` env 를 읽어 활성화. 미설정 시 no-op.
/// CLI main / NAPI entry 양쪽에서 호출 — 중복 호출 해도 idempotent.
pub fn initFromEnv(allocator: std.mem.Allocator) void {
    if (std.process.getEnvVarOwned(allocator, "ZNTC_PROFILE")) |v| {
        defer allocator.free(v);
        addFromCsv(v);
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "ZNTC_PROFILE_LEVEL")) |v| {
        defer allocator.free(v);
        if (Level.fromString(v)) |lv| setLevel(lv);
    } else |_| {}
}

/// totals_ns / counts 를 0 으로 초기화.
///
/// Debug + Linux x86_64 에서 `@memset` 이 `mov m64 m64` 로 encode 되어 Zig 0.15.2
/// 컴파일러 버그(InvalidInstruction) 를 유발 — comptime array literal 대입으로 회피.
/// Zig upgrade 로 버그 사라지면 이 함수 제거하고 `@memset` 두 줄 복원.
fn zeroCounters() void {
    totals_ns = [_]u64{0} ** num_categories;
    self_totals_ns = [_]u64{0} ** num_categories;
    counts = [_]u32{0} ** num_categories;
    // active_scope_len 은 threadlocal — 호출 스레드 것만 리셋된다. 호출처(test reset / HMR
    // rebuild 직전)는 모두 single-thread 라 안전; worker 들은 join 된 상태(depth 0)다.
    active_scope_len = 0;
    wall_start = null;
}

/// 테스트 / 재초기화용. 전체 상태 초기화 (mask + level + counters 모두).
pub fn resetForTest() void {
    enabled_mask = ProfileMask.initEmpty();
    current_level = .summary;
    zeroCounters();
}

/// counters 만 reset (mask 와 level 은 유지).
/// HMR rebuild 시작 전에 호출 — 이전 rebuild 의 누적치가 이월되지 않도록.
pub fn resetCounters() void {
    zeroCounters();
}

/// 하나의 category 를 활성화하고, prefix 로 시작하는 child category 도 모두 활성화.
/// 예: `enableCategoryAndChildren(.parse)` → `.parse_ast_build` 도 같이 활성.
fn enableCategoryAndChildren(parent: Category) void {
    const parent_name = @tagName(parent);
    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const child_name = f.name;
        const is_self = std.mem.eql(u8, child_name, parent_name);
        const is_child = child_name.len > parent_name.len and
            std.mem.startsWith(u8, child_name, parent_name) and
            child_name[parent_name.len] == '_';
        if (is_self or is_child) {
            const child = @field(Category, child_name);
            enabled_mask.set(@intFromEnum(child));
        }
    }
}

// ============================================================================
// Scope — RAII timer (hot path API)
// ============================================================================

/// 타이밍 스코프. `begin()` 으로 시작하고 `end()` 로 종료. `defer scope.end();` 관용구.
///
/// 비활성 category 면 `timer == null` — `end()` 도 no-op (분기 한 번).
pub const Scope = struct {
    timer: ?std.time.Timer = null,
    category: Category = .scan, // 비활성 시 사용 안 됨
    stack_index: u8 = 0,
    stack_active: bool = false,

    pub fn end(self: *Scope) void {
        if (self.timer) |*t| {
            const elapsed_ns = t.read();
            var child_ns: u64 = 0;
            if (self.stack_active) {
                if (active_scope_len == self.stack_index + 1) {
                    child_ns = active_scopes[self.stack_index].child_ns;
                    active_scope_len = self.stack_index;
                    if (self.stack_index > 0) {
                        active_scopes[self.stack_index - 1].child_ns += elapsed_ns;
                    }
                } else {
                    // Scope 는 LIFO 로 닫혀야 child subtraction 이 정확하다. 혹시 깨지면
                    // 이후 sample 오염을 막기 위해 stack 만 비우고 inclusive/self 동일 처리.
                    active_scope_len = 0;
                }
                self.stack_active = false;
            }
            const self_ns = elapsed_ns -| child_ns;
            recordTiming(self.category, elapsed_ns, self_ns);
            self.timer = null;
        }
    }
};

/// 비활성 category 면 no-op scope 반환 (Timer 생성 없음 → zero overhead).
/// 활성 category 면 Timer 시작 + category 기록.
pub inline fn begin(cat: Category) Scope {
    if (!enabled(cat)) return .{};
    const timer = std.time.Timer.start() catch return .{};
    if (active_scope_len >= max_scope_depth) {
        return .{
            .timer = timer,
            .category = cat,
        };
    }
    const stack_index = active_scope_len;
    active_scopes[stack_index] = .{};
    active_scope_len += 1;
    return .{
        .timer = timer,
        .category = cat,
        .stack_index = stack_index,
        .stack_active = true,
    };
}

/// sub-phase profile category 가 optional 일 때 (off → null) 사용.
pub inline fn beginMaybe(cat: ?Category) Scope {
    if (cat) |c| return begin(c);
    return .{};
}

fn recordTiming(cat: Category, ns: u64, self_ns: u64) void {
    const idx = @intFromEnum(cat);
    // 여러 worker thread 가 동시에 기록할 수 있으므로 atomic add (lost update 방지).
    // 측정 구간(`t.read()`) 밖이라 contention 시간이 sample 에 섞이지 않는다.
    atomicAdd(u64, &totals_ns[idx], ns);
    atomicAdd(u64, &self_totals_ns[idx], self_ns);
    atomicAdd(u32, &counts[idx], 1);
}

/// 수집된 원시 데이터 조회 (테스트 + 외부 리포터용). 모든 스레드 합산값.
pub fn totalNs(cat: Category) u64 {
    return atomicGet(u64, &totals_ns[@intFromEnum(cat)]);
}

pub fn selfNs(cat: Category) u64 {
    return atomicGet(u64, &self_totals_ns[@intFromEnum(cat)]);
}

pub fn count(cat: Category) u32 {
    return atomicGet(u32, &counts[@intFromEnum(cat)]);
}

// ============================================================================
// Reporting
// ============================================================================

/// 지정한 format 으로 리포트 출력.
pub fn report(writer: anytype, format: Format) !void {
    @setEvalBranchQuota(20000);
    switch (format) {
        .table => try reportTable(writer),
        .tree => try reportTree(writer),
        .json => try reportJson(writer),
        .csv => try reportCsv(writer),
    }
}

fn totalAllNs() u64 {
    var sum: u64 = 0;
    for (&self_totals_ns) |*ns| sum += atomicGet(u64, ns);
    return sum;
}

/// 프로파일 활성화 이후 경과한 실제 벽시계 시간 (ns). 측정 안 시작했으면 0.
/// 병렬 phase 때문에 Σself 가 wall 을 초과하는 게 정상이므로 비교 기준으로 함께 보여준다.
fn wallNs() u64 {
    const start = wall_start orelse return 0;
    const now = std.time.Instant.now() catch return 0;
    return now.since(start);
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn pctOf(part: u64, whole: u64) f64 {
    if (whole == 0) return 0.0;
    return @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole)) * 100.0;
}

fn isTopLevel(cat: Category) bool {
    // name 에 `_` 없으면 top-level.
    const name = @tagName(cat);
    return std.mem.indexOfScalar(u8, name, '_') == null;
}

fn isChildOf(cat: Category, parent: Category) bool {
    const child_name = @tagName(cat);
    const parent_name = @tagName(parent);
    return child_name.len > parent_name.len + 1 and
        std.mem.startsWith(u8, child_name, parent_name) and
        child_name[parent_name.len] == '_';
}

fn reportTable(writer: anytype) !void {
    try writer.writeAll("=== ZNTC Profile ===\n");
    try writer.writeAll("Phase                Total       Self        %      Count\n");
    try writer.writeAll("--------------------|-----------|-----------|-------|------\n");

    const total = totalAllNs();
    if (total == 0) {
        try writer.writeAll("(no samples recorded)\n");
        return;
    }

    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const cat = @field(Category, f.name);
        const cnt = count(cat);
        const is_sub = !isTopLevel(cat);
        const skip = cnt == 0 or (current_level == .summary and is_sub);
        if (!skip) {
            const self_ns = selfNs(cat);
            try writer.print("{s: <20} {d: >7.2}ms  {d: >7.2}ms  {d: >4.1}%  {d: >5}\n", .{
                Category.displayName(cat), nsToMs(totalNs(cat)), nsToMs(self_ns), pctOf(self_ns, total), cnt,
            });
        }
    }

    try writer.writeAll("--------------------|-----------|-----------|-------|------\n");
    // `total` = Σself(모든 스레드). 병렬 phase 가 있으면 wall 보다 큰 게 정상.
    try writer.print("{s: <20} {d: >7.2}ms  {d: >7.2}ms  100.0%   (Σ self, all threads)\n", .{ "total", nsToMs(total), nsToMs(total) });
    const wall_ns = wallNs();
    if (wall_ns > 0) {
        try writer.print("{s: <20} {d: >7.2}ms\n", .{ "wall", nsToMs(wall_ns) });
    }
}

fn reportTree(writer: anytype) !void {
    try writer.writeAll("=== ZNTC Profile (detailed) ===\n");

    const total = totalAllNs();
    if (total == 0) {
        try writer.writeAll("(no samples recorded)\n");
        return;
    }

    const wall_ns = wallNs();
    if (wall_ns > 0) {
        try writer.print("wall: {d:.2}ms   |   Σ self (all threads): {d:.2}ms\n", .{ nsToMs(wall_ns), nsToMs(total) });
    } else {
        try writer.print("total: {d:.2}ms\n", .{nsToMs(total)});
    }

    // Top-level categories.
    for (all_categories) |cat| {
        if (count(cat) > 0 and isTopLevel(cat)) {
            const ns = totalNs(cat);
            const self_ns = selfNs(cat);
            try writer.print("├─ {s: <16} {d: >7.2}ms total  {d: >7.2}ms self  ({d:.1}%)\n", .{
                Category.displayName(cat), nsToMs(ns), nsToMs(self_ns), pctOf(self_ns, total),
            });

            if (current_level != .summary) {
                // Sub-phases.
                for (all_categories) |sub_cat| {
                    if (count(sub_cat) > 0 and isChildOf(sub_cat, cat)) {
                        const sub_self_ns = selfNs(sub_cat);
                        try writer.print("│  └─ {s: <13} {d: >7.2}ms total  {d: >7.2}ms self  ({d:.1}% of {s})\n", .{
                            Category.displayName(sub_cat),
                            nsToMs(totalNs(sub_cat)),
                            nsToMs(sub_self_ns),
                            pctOf(sub_self_ns, ns),
                            Category.displayName(cat),
                        });
                    }
                }
            }
        }
    }
}

fn reportJson(writer: anytype) !void {
    const total = totalAllNs();

    try writer.writeAll("{\n");
    try writer.print("  \"profile_version\": 1,\n", .{});
    // total_ms = Σ self (모든 스레드). wall_ms = 실제 경과. 병렬 phase 가 있으면 total > wall.
    try writer.print("  \"total_ms\": {d:.3},\n", .{nsToMs(total)});
    try writer.print("  \"wall_ms\": {d:.3},\n", .{nsToMs(wallNs())});
    try writer.print("  \"level\": \"{s}\",\n", .{@tagName(current_level)});
    try writer.writeAll("  \"phases\": {\n");

    var first = true;
    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const cat = @field(Category, f.name);
        const cnt = count(cat);
        const is_sub = !isTopLevel(cat);
        const skip = cnt == 0 or (current_level == .summary and is_sub);
        if (!skip) {
            const ns = totalNs(cat);
            const self_ns = selfNs(cat);

            if (!first) try writer.writeAll(",\n");
            first = false;
            try writer.print(
                "    \"{s}\": {{ \"total_ms\": {d:.3}, \"self_ms\": {d:.3}, \"count\": {d}, \"pct\": {d:.2}, \"self_pct\": {d:.2} }}",
                .{ Category.displayName(cat), nsToMs(ns), nsToMs(self_ns), cnt, pctOf(ns, total), pctOf(self_ns, total) },
            );
        }
    }
    try writer.writeAll("\n  }\n}\n");
}

fn reportCsv(writer: anytype) !void {
    try writer.writeAll("phase,total_ms,self_ms,count,pct,self_pct\n");
    const total = totalAllNs();

    inline for (@typeInfo(Category).@"enum".fields) |f| {
        const cat = @field(Category, f.name);
        const cnt = count(cat);
        const is_sub = !isTopLevel(cat);
        const skip = cnt == 0 or (current_level == .summary and is_sub);
        if (!skip) {
            const ns = totalNs(cat);
            const self_ns = selfNs(cat);
            try writer.print("{s},{d:.3},{d:.3},{d},{d:.2},{d:.2}\n", .{
                Category.displayName(cat), nsToMs(ns), nsToMs(self_ns), cnt, pctOf(ns, total), pctOf(self_ns, total),
            });
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Category.fromString: 기본 매칭" {
    try testing.expect(Category.fromString("parse") == .parse);
    try testing.expect(Category.fromString("PARSE") == .parse);
    try testing.expect(Category.fromString("  parse  ") == .parse);
    try testing.expect(Category.fromString("") == null);
    try testing.expect(Category.fromString("nonexistent") == null);
}

test "Category.fromString: dot notation 정규화" {
    try testing.expect(Category.fromString("parse.ast_build") == .parse_ast_build);
    try testing.expect(Category.fromString("transform.ts_strip") == .transform_ts_strip);
    try testing.expect(Category.fromString("Transform.JSX") == .transform_jsx);
    try testing.expect(Category.fromString("hmr.detect") == .hmr_detect);
    try testing.expect(Category.fromString("resolve.cache.lookup") == .resolve_cache_lookup);
    try testing.expect(Category.fromString("resolve.ts.extension.map") == .resolve_ts_extension_map);
    try testing.expect(Category.fromString("resolve.directory.index") == .resolve_directory_index);
    try testing.expect(Category.fromString("shake.analyze") == .shake_analyze);
    try testing.expect(Category.fromString("shake.post.link.finalize") == .shake_post_link_finalize);
    try testing.expect(Category.fromString("shake.fixpoint.bfs") == .shake_fixpoint_bfs);
    try testing.expect(Category.fromString("shake.fixpoint.bfs.follow.import") == .shake_fixpoint_bfs_follow_import);
    try testing.expect(Category.fromString("shake.fixpoint.bfs.seed.export.direct") == .shake_fixpoint_bfs_seed_export_direct);
    try testing.expect(Category.fromString("shake.fixpoint.bfs.seed.export.resolve") == .shake_fixpoint_bfs_seed_export_resolve);
    try testing.expect(Category.fromString("shake.fixpoint.re.exports.module") == .shake_fixpoint_re_exports_module);
    try testing.expect(Category.fromString("shake.numeric.postpass.build.facts.resolve") == .shake_numeric_postpass_build_facts_resolve);
    try testing.expect(Category.fromString("shake.numeric.postpass.minify.skip") == .shake_numeric_postpass_minify_skip);
    try testing.expect(Category.fromString("graph.resync.const") == .graph_resync_const);
    try testing.expect(Category.fromString("graph.resync.binding.refs") == .graph_resync_binding_refs);
    try testing.expect(Category.fromString("shake.const.prepass.build.facts") == .shake_const_prepass_build_facts);
    try testing.expect(Category.fromString("shake.const.prepass.build.facts.lookup") == .shake_const_prepass_build_facts_lookup);
}

test "Category.displayName: underscore → dot 역변환" {
    try testing.expectEqualStrings("parse", Category.displayName(.parse));
    try testing.expectEqualStrings("parse.ast.build", Category.displayName(.parse_ast_build));
    try testing.expectEqualStrings("transform.ts.strip", Category.displayName(.transform_ts_strip));
    try testing.expectEqualStrings("hmr.detect", Category.displayName(.hmr_detect));
    try testing.expectEqualStrings("resolve.cache.lookup", Category.displayName(.resolve_cache_lookup));
    try testing.expectEqualStrings("resolve.ts.extension.map", Category.displayName(.resolve_ts_extension_map));
    try testing.expectEqualStrings("resolve.directory.index", Category.displayName(.resolve_directory_index));
    try testing.expectEqualStrings("shake.analyze", Category.displayName(.shake_analyze));
    try testing.expectEqualStrings("shake.post.link.finalize", Category.displayName(.shake_post_link_finalize));
    try testing.expectEqualStrings("shake.fixpoint.bfs", Category.displayName(.shake_fixpoint_bfs));
    try testing.expectEqualStrings("shake.fixpoint.bfs.follow.import", Category.displayName(.shake_fixpoint_bfs_follow_import));
    try testing.expectEqualStrings("shake.fixpoint.bfs.seed.export.direct", Category.displayName(.shake_fixpoint_bfs_seed_export_direct));
    try testing.expectEqualStrings("shake.fixpoint.bfs.seed.export.resolve", Category.displayName(.shake_fixpoint_bfs_seed_export_resolve));
    try testing.expectEqualStrings("shake.fixpoint.re.exports.module", Category.displayName(.shake_fixpoint_re_exports_module));
    try testing.expectEqualStrings("shake.numeric.postpass.build.facts.resolve", Category.displayName(.shake_numeric_postpass_build_facts_resolve));
    try testing.expectEqualStrings("shake.numeric.postpass.minify.skip", Category.displayName(.shake_numeric_postpass_minify_skip));
    try testing.expectEqualStrings("graph.resync.const", Category.displayName(.graph_resync_const));
    try testing.expectEqualStrings("graph.resync.binding.refs", Category.displayName(.graph_resync_binding_refs));
    try testing.expectEqualStrings("shake.const.prepass.build.facts", Category.displayName(.shake_const_prepass_build_facts));
    try testing.expectEqualStrings("shake.const.prepass.build.facts.lookup", Category.displayName(.shake_const_prepass_build_facts_lookup));
}

test "Level.fromString" {
    try testing.expect(Level.fromString("summary") == .summary);
    try testing.expect(Level.fromString("detailed") == .detailed);
    try testing.expect(Level.fromString("per-module") == .per_module);
    try testing.expect(Level.fromString("per_module") == .per_module);
    try testing.expect(Level.fromString("per-pass") == .per_pass);
    try testing.expect(Level.fromString("unknown") == null);
}

test "Format.fromString" {
    try testing.expect(Format.fromString("table") == .table);
    try testing.expect(Format.fromString("JSON") == .json);
    try testing.expect(Format.fromString("csv") == .csv);
    try testing.expect(Format.fromString("tree") == .tree);
    try testing.expect(Format.fromString("xml") == null);
}

test "addFromCsv: 개별 category 활성화" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse, transform");
    try testing.expect(enabled(.parse));
    try testing.expect(enabled(.transform));
    try testing.expect(!enabled(.codegen));
}

test "addFromCsv: all 키워드" {
    resetForTest();
    defer resetForTest();

    addFromCsv("all");
    try testing.expect(enabled(.parse));
    try testing.expect(enabled(.transform));
    try testing.expect(enabled(.codegen));
    try testing.expect(enabled(.hmr_detect));
}

test "addFromCsv: none 키워드 초기화" {
    resetForTest();
    defer resetForTest();

    addFromCsv("all");
    addFromCsv("none");
    try testing.expect(!enabled(.parse));
}

test "addFromCsv: 빈 항목 및 공백 무시" {
    resetForTest();
    defer resetForTest();

    addFromCsv(" , , parse , ");
    try testing.expect(enabled(.parse));
}

test "addFromCsv: parent 활성화 시 child 자동 활성" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    try testing.expect(enabled(.parse));
    try testing.expect(enabled(.parse_ast_build));
}

test "addFromCsv: shake parent → 모든 sub-phase 활성" {
    resetForTest();
    defer resetForTest();

    addFromCsv("shake");
    try testing.expect(enabled(.shake));
    try testing.expect(enabled(.shake_init));
    try testing.expect(enabled(.shake_analyze));
    try testing.expect(enabled(.shake_post_link_finalize));
    try testing.expect(enabled(.shake_const_prepass));
    try testing.expect(enabled(.shake_const_prepass_build_facts));
    try testing.expect(enabled(.shake_fixpoint));
    try testing.expect(enabled(.shake_fixpoint_bfs));
    try testing.expect(enabled(.shake_fixpoint_bfs_follow_import));
    try testing.expect(enabled(.shake_fixpoint_bfs_seed_export_direct));
    try testing.expect(enabled(.shake_fixpoint_bfs_seed_export_resolve));
    try testing.expect(enabled(.shake_numeric_postpass));
}

test "addFromCsv: child 만 지정하면 parent 는 비활성" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse.ast_build");
    try testing.expect(!enabled(.parse));
    try testing.expect(enabled(.parse_ast_build));
}

test "addFromCsv: transform parent → 모든 sub-phase 활성" {
    resetForTest();
    defer resetForTest();

    addFromCsv("transform");
    try testing.expect(enabled(.transform));
    try testing.expect(enabled(.transform_ts_strip));
    try testing.expect(enabled(.transform_jsx));
    try testing.expect(enabled(.transform_class_field));
    try testing.expect(enabled(.transform_decorator));
    try testing.expect(enabled(.transform_pass2));
}

test "addFromCsv: 알 수 없는 이름은 무시" {
    resetForTest();
    defer resetForTest();

    addFromCsv("bogus_category, parse");
    try testing.expect(enabled(.parse));
}

test "addCategories: slice 기반 API" {
    resetForTest();
    defer resetForTest();

    const cats = [_][]const u8{ "parse", "transform.jsx" };
    addCategories(&cats);
    try testing.expect(enabled(.parse));
    try testing.expect(enabled(.transform_jsx));
    try testing.expect(!enabled(.transform));
}

test "Scope: 비활성 category 는 zero-cost" {
    resetForTest();
    defer resetForTest();

    // 비활성 상태 — begin 은 Timer 없이 null 반환.
    var scope = begin(.parse);
    try testing.expect(scope.timer == null);
    scope.end();
    try testing.expectEqual(@as(u64, 0), totalNs(.parse));
    try testing.expectEqual(@as(u64, 0), selfNs(.parse));
    try testing.expectEqual(@as(u32, 0), count(.parse));
}

test "Scope: 활성 category 는 시간 누적" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");

    var s1 = begin(.parse);
    std.Thread.sleep(1_000_000); // 1ms
    s1.end();

    var s2 = begin(.parse);
    std.Thread.sleep(1_000_000); // 1ms
    s2.end();

    const total = totalNs(.parse);
    const self_total = selfNs(.parse);
    // 실제 시간은 OS 스케줄링에 따라 다름. 최소 보장만 검증.
    try testing.expect(total >= 2_000_000);
    try testing.expect(self_total >= 2_000_000);
    try testing.expectEqual(@as(u32, 2), count(.parse));
}

test "Scope: nested 호출 누적" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    addFromCsv("parse.ast_build");

    var outer = begin(.parse);
    {
        var inner = begin(.parse_ast_build);
        std.Thread.sleep(1_000_000);
        inner.end();
    }
    outer.end();

    try testing.expect(totalNs(.parse) > 0);
    try testing.expect(totalNs(.parse_ast_build) > 0);
    // Outer 가 inner 를 포함하는지 대략 검증 — parent 가 child 보다 크거나 같음.
    try testing.expect(totalNs(.parse) >= totalNs(.parse_ast_build));
    try testing.expect(selfNs(.parse) <= totalNs(.parse));
    try testing.expect(selfNs(.parse_ast_build) <= totalNs(.parse_ast_build));
    try testing.expectEqual(totalNs(.parse), totalAllNs());
}

test "setLevel / level" {
    resetForTest();
    defer resetForTest();

    try testing.expect(level() == .summary);
    setLevel(.detailed);
    try testing.expect(level() == .detailed);
}

test "report: table format 기본 구조" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    var s = begin(.parse);
    std.Thread.sleep(500_000); // 0.5ms
    s.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .table);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "=== ZNTC Profile ===") != null);
    try testing.expect(std.mem.indexOf(u8, output, "parse") != null);
    try testing.expect(std.mem.indexOf(u8, output, "total") != null);
}

test "report: json format 기본 구조" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    var s = begin(.parse);
    std.Thread.sleep(500_000);
    s.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .json);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "\"profile_version\": 1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"total_ms\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"self_ms\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"phases\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"parse\"") != null);
}

test "report: csv format 기본 구조" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    var s = begin(.parse);
    std.Thread.sleep(500_000);
    s.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .csv);
    const output = fbs.getWritten();

    try testing.expect(std.mem.startsWith(u8, output, "phase,total_ms,self_ms,count,pct,self_pct\n"));
    try testing.expect(std.mem.indexOf(u8, output, "parse,") != null);
}

test "report: 데이터 없을 때 empty message" {
    resetForTest();
    defer resetForTest();

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .table);
    const output = fbs.getWritten();
    try testing.expect(std.mem.indexOf(u8, output, "no samples") != null);
}

test "report: summary level 은 sub-phase 숨김" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse"); // parse + parse_ast_build 자동 활성
    setLevel(.summary);

    var outer = begin(.parse);
    var inner = begin(.parse_ast_build);
    std.Thread.sleep(100_000);
    inner.end();
    outer.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .table);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "parse.ast.build") == null);
    try testing.expect(std.mem.indexOf(u8, output, "parse ") != null);
}

test "report: detailed level 은 sub-phase 노출" {
    resetForTest();
    defer resetForTest();

    addFromCsv("parse");
    setLevel(.detailed);

    var outer = begin(.parse);
    var inner = begin(.parse_ast_build);
    std.Thread.sleep(100_000);
    inner.end();
    outer.end();

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try report(fbs.writer(), .tree);
    const output = fbs.getWritten();

    try testing.expect(std.mem.indexOf(u8, output, "parse.ast.build") != null);
}

test "isTopLevel / isChildOf 헬퍼" {
    try testing.expect(isTopLevel(.parse));
    try testing.expect(isTopLevel(.transform));
    try testing.expect(!isTopLevel(.parse_ast_build));
    try testing.expect(!isTopLevel(.transform_jsx));

    try testing.expect(isChildOf(.parse_ast_build, .parse));
    try testing.expect(isChildOf(.transform_jsx, .transform));
    try testing.expect(!isChildOf(.parse, .transform));
    try testing.expect(!isChildOf(.parse, .parse_ast_build));
}

test "resetForTest 초기화" {
    addFromCsv("all");
    setLevel(.detailed);
    var s = begin(.parse);
    std.Thread.sleep(100_000);
    s.end();

    resetForTest();
    try testing.expect(!enabled(.parse));
    try testing.expect(level() == .summary);
    try testing.expectEqual(@as(u64, 0), totalNs(.parse));
    try testing.expectEqual(@as(u64, 0), selfNs(.parse));
    try testing.expectEqual(@as(u32, 0), count(.parse));
}

test "addFromCsv all enables categories beyond u128 mask boundary" {
    resetForTest();
    defer resetForTest();

    addFromCsv("all");
    try testing.expect(enabled(.shake_fixpoint_re_exports_module));
    try testing.expect(enabled(.cache));
}
