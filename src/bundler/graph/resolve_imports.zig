//! Import resolution and resolved dependency application for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const CachedResolvedDep = @import("../module.zig").CachedResolvedDep;
const plugin_mod = @import("../plugin.zig");
const resolve_cache_mod = @import("../resolve_cache.zig");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const graph_glob = @import("glob.zig");
const expandGlobRecords = graph_glob.expandGlobRecords;
const graph_require_context = @import("require_context.zig");
const expandRequireContextRecords = graph_require_context.expandRecords;
const graph_import_usage = @import("import_usage.zig");
const graph_requested_exports = @import("requested_exports.zig");
const profile = @import("../../profile.zig");

/// PR-3b-ii: 동적 import 타겟 `path` 가 lazy_force_parse 목록에 있으면 lazy defer 대신
/// 즉시 parse. on-demand 컴파일이 요청된 lazy 청크 seed 만 eager 로 끌어올린다.
fn pathInForceParse(self: *const ModuleGraph, path: []const u8) bool {
    for (self.lazy_force_parse) |fp| {
        if (std.mem.eql(u8, fp, path)) return true;
    }
    return false;
}

fn appendResolvedDep(
    self: *ModuleGraph,
    mod_idx: usize,
    dep: CachedResolvedDep,
) !void {
    // PR #3749 Phase 3 (C): dep.path 는 PathRef variant — caller 가 lifetime 명시.
    // graph 가 추가 dupe 안 함. interned/specifier variant 는 borrow,
    // owned variant 는 caller-alloc + module.deinit 시 자동 free.
    const mod_ptr = self.modules.at(mod_idx);
    try mod_ptr.resolved_deps.append(self.allocator, dep);
}

pub fn replayCachedResolvedDeps(self: *ModuleGraph, io: std.Io, mod_idx: usize) !void {
    std.debug.assert(mod_idx < self.modules.count());
    const mod_index = ModuleIndex.fromUsize(mod_idx);
    const mod_ptr = self.modules.at(mod_idx);

    for (mod_ptr.resolved_deps.items) |dep| {
        switch (dep.target) {
            .file, .virtual => {
                // #4074: cache-hit rebuild 의 replay 경로에도 miss 경로(resolveModuleImports:356)
                // 와 동일한 lazy 게이트를 적용한다. 없으면 동적 import 타겟을 여기서 addModule
                // (=.reserved 모듈 추가) → discovery 루프가 파싱 → emit 해 *rebuild 마다* 미요청
                // lazy seed 가 디스크에 떨어진다(첫 빌드는 emit-skip, 첫 rebuild 부터 laziness 손실).
                // 게이트가 통과하면 addModule/link 대신 lazy_seeds 에 쌓고 continue → 루프 종료 후
                // materializeLazySeeds 가 미파싱 seed(state=.ready, ast=null, is_lazy_seed)로 처리.
                // miss 경로와 달리 dep 는 이미 resolved_deps 에 있어 appendResolvedDep 재등록 안 함.
                // .file 만(virtual/external 동적 타겟은 miss 경로도 eager — PR-3b 범위).
                if (dep.target == .file and dep.kind == .dynamic_import and
                    self.lazy_compilation and self.code_splitting and self.dev_mode)
                {
                    if (dep.record_index) |rec_idx| {
                        if (!pathInForceParse(self, dep.path.bytes())) {
                            const pa = self.path_arena.allocator();
                            try self.lazy_seeds.append(self.allocator, .{
                                .from = mod_index,
                                .rec_i = @intCast(rec_idx),
                                .path = try pa.dupe(u8, dep.path.bytes()),
                                .resolve_dir = if (dep.resolve_dir) |rd| try pa.dupe(u8, rd.bytes()) else null,
                            });
                            continue;
                        }
                    }
                }
                var s_am = profile.begin(.graph_discover_incr_replay_add_module);
                const dep_idx = try self.addModuleWithResolveDir(io, dep.path.bytes(), if (dep.resolve_dir) |rd| rd.bytes() else null);
                s_am.end();
                if (dep.target_is_module_field or mod_ptr.is_module_field) {
                    self.modules.at(@intFromEnum(dep_idx)).is_module_field = true;
                }
                if (dep.is_context_dep) {
                    self.modules.at(@intFromEnum(dep_idx)).is_context_dep = true;
                }
                try replayLinkResolvedDep(self, io, mod_index, mod_idx, dep, dep_idx);
            },
            .disabled => {
                // _other 는 leaf bucket — request_exports/record_dep 와 중첩 측정 금지
                // (inclusive totals 가 합쳐져 percentage 가 100% 초과). addDisabledModule
                // 만 _other 로 측정하고 link 부분은 replayLinkResolvedDep 가 자체 측정.
                var s_o = profile.begin(.graph_discover_incr_replay_other);
                const dep_idx = try self.addDisabledModule(dep.path.bytes());
                s_o.end();
                try replayLinkResolvedDep(self, io, mod_index, mod_idx, dep, dep_idx);
            },
            .optional_missing => {
                var s_o = profile.begin(.graph_discover_incr_replay_other);
                const dep_idx = try self.addOptionalMissingModule(dep.path.bytes());
                s_o.end();
                try replayLinkResolvedDep(self, io, mod_index, mod_idx, dep, dep_idx);
            },
            .external => {
                // external 은 replayLinkResolvedDep 를 거치지 않고 inline 하므로
                // 동일한 sub-phase 로 명시 분해 (다른 분기와 측정 대칭성 유지).
                var s_am = profile.begin(.graph_discover_incr_replay_add_module);
                const ext_idx = try self.addExternalModule(dep.path.bytes());
                s_am.end();
                if (dep.record_index) |rec_idx| {
                    if (rec_idx < mod_ptr.import_records.len) {
                        mod_ptr.import_records[rec_idx].is_external = true;
                        var s_re = profile.begin(.graph_discover_incr_replay_request_exports);
                        _ = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_idx, mod_ptr.import_records[rec_idx], ext_idx);
                        s_re.end();
                    }
                }
                var s_rd = profile.begin(.graph_discover_incr_replay_record_dep);
                defer s_rd.end();
                if (dep.kind == .dynamic_import) {
                    try self.linkDynamicImport(mod_index, ext_idx);
                } else if (dep.kind == .css_url) {
                    // external 로 분류된 css_url 도 JS 의존성 엣지를 만들지 않는다.
                    if (dep.record_index) |rec_idx| {
                        if (rec_idx < mod_ptr.import_records.len) {
                            prepareCssUrlAsset(self, mod_idx, rec_idx, ext_idx);
                        }
                    }
                } else {
                    try self.linkDependency(mod_index, ext_idx);
                }
            },
            .worker => {
                // worker_entries.append 만 — 진짜 link 는 별도 phase. _other leaf 적합.
                var s_o = profile.begin(.graph_discover_incr_replay_other);
                defer s_o.end();
                const rec_idx = dep.record_index orelse continue;
                const path_dupe = try self.allocator.dupe(u8, dep.path.bytes());
                try self.worker_entries.append(self.allocator, .{
                    .resolved_path = path_dupe,
                    .source_module = mod_index,
                    .record_index = @intCast(rec_idx),
                });
            },
        }
    }
}

/// `record_index` 가 있으면 record 갱신 + link, 없으면 link 만 수행. file/virtual/disabled
/// 케이스가 공통으로 사용. external 은 `is_external` flag 기록 후 무조건 link 라 별도.
fn replayLinkResolvedDep(
    self: *ModuleGraph,
    io: std.Io,
    mod_index: ModuleIndex,
    mod_idx: usize,
    dep: CachedResolvedDep,
    dep_idx: ModuleIndex,
) !void {
    if (dep.record_index) |rec_idx| {
        const mod_ptr = self.modules.at(mod_idx);
        if (rec_idx >= mod_ptr.import_records.len) return;
        var s_re = profile.begin(.graph_discover_incr_replay_request_exports);
        const request_changed = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_idx, mod_ptr.import_records[rec_idx], dep_idx);
        s_re.end();
        var s_rd = profile.begin(.graph_discover_incr_replay_record_dep);
        try recordResolvedDep(self, mod_index, mod_idx, rec_idx, dep_idx, dep.kind);
        s_rd.end();
        if (request_changed) try resolveDeferredRequestedImportsIfReady(self, io, dep_idx);
        return;
    }
    // `.css_url` 은 JS export 를 요청하지 않는다 (asset 은 JS 그래프 밖).
    if (dep.kind != .css_url) {
        var s_re = profile.begin(.graph_discover_incr_replay_request_exports);
        _ = try graph_requested_exports.requestAll(self, dep_idx);
        s_re.end();
    }
    var s_rd = profile.begin(.graph_discover_incr_replay_record_dep);
    defer s_rd.end();
    if (dep.kind == .dynamic_import) {
        try self.linkDynamicImport(mod_index, dep_idx);
    } else if (dep.kind == .css_url) {
        if (dep.record_index) |rec_idx| {
            if (rec_idx < self.modules.at(mod_idx).import_records.len) {
                prepareCssUrlAsset(self, mod_idx, rec_idx, dep_idx);
            }
        }
    } else {
        try self.linkDependency(mod_index, dep_idx);
    }
}

/// context_expansion_deps 를 resolve 하고 graph 에 module + dependency 로 등록 (#1579 Phase 4).
/// scanModules receiver / resolveModuleImports 양쪽 경로에서 호출. SegmentedList 로
/// append 해도 기존 *Module 포인터는 유효 (#1779 INVARIANTS.md).
pub fn applyContextDepResults(self: *ModuleGraph, io: std.Io, mod_idx: usize) !void {
    const mod_index = ModuleIndex.fromUsize(mod_idx);
    const mod_ptr = self.modules.at(mod_idx);
    const context_deps = mod_ptr.context_expansion_deps;
    if (context_deps.len == 0) return;

    const module_path = mod_ptr.path;
    const source_dir = mod_ptr.sourceDir();
    for (context_deps) |dep| {
        const resolved = self.resolve_cache.resolveThreadSafe(io, source_dir, dep.specifier, dep.kind) catch |err| switch (err) {
            error.ModuleNotFound => {
                self.addDiag(
                    .unresolved_import,
                    .warning,
                    module_path,
                    dep.span,
                    .resolve,
                    "Cannot resolve require.context match",
                    dep.specifier,
                );
                continue;
            },
            else => |e| return e,
        };
        if (resolved) |m| switch (m) {
            .file => |f| {
                // PR resolve interning: f.path / f.resolve_dir 는 path_pool 소유 (borrow only, free 금지).
                const dep_idx = try self.addModuleWithResolveDir(io, f.path, f.resolve_dir);
                _ = try graph_requested_exports.requestAll(self, dep_idx);
                // tree-shaker 가 static import 없이도 이 모듈을 보존하도록 마킹.
                self.modules.at(@intFromEnum(dep_idx)).is_context_dep = true;
                try appendResolvedDep(self, mod_idx, .{
                    .kind = dep.kind,
                    .target = .file,
                    .path = .{ .interned = f.path },
                    .resolve_dir = if (f.resolve_dir) |d| .{ .interned = d } else null,
                    .target_is_module_field = f.is_module_field,
                    .is_context_dep = true,
                });
                try self.linkDependency(mod_index, dep_idx);
            },
            // require.context 의 disabled / virtual 등 variant — path_pool borrow only.
            .disabled => {},
            // (deferred 6) future plugin layer 가 이들 variant 를 require.context 결과로
            // 반환할 가능성은 현재 없음 (resolver 는 .file/.disabled 만 emit). 그러나
            // unreachable 는 release build 에서 UB → explicit panic 으로 의미 있는
            // diagnostic 제공. 활성화 시 별도 RFC 필요.
            // (review note) site 2 (line ~357) 와 달리 require.context 는 `.virtual` 도
            // 미지원 — `.virtual` 까지 panic arm 에 포함.
            .virtual, .dataurl, .external, .custom => std.debug.panic(
                "require.context resolver returned unsupported variant — only .file/.disabled supported here (got {s})",
                .{@tagName(m)},
            ),
        };
    }
}

/// 의존성 인덱스를 import_records 에 기록하고 graph 에 link.
/// dynamic_import 는 별도 link 경로 — 그 외는 일반 dependency.
/// SegmentedList 는 realloc 없지만 모듈 소유 slice 를 update 하므로 *Module 재조회 안전.
fn recordResolvedDep(
    self: *ModuleGraph,
    mod_index: ModuleIndex,
    mod_idx: usize,
    rec_i: usize,
    dep_idx: ModuleIndex,
    kind: types.ImportKind,
) !void {
    var s_rw = profile.begin(.graph_discover_incr_record_dep_rec_write);
    const src_mod = self.modules.at(mod_idx);
    src_mod.import_records[rec_i].resolved = dep_idx;
    src_mod.import_records[rec_i].is_lazy_resolved = false;
    s_rw.end();
    var s_lk = profile.begin(.graph_discover_incr_record_dep_link);
    defer s_lk.end();
    if (kind == .dynamic_import) {
        try self.linkDynamicImport(mod_index, dep_idx);
    } else if (kind == .css_url) {
        prepareCssUrlAsset(self, mod_idx, rec_i, dep_idx);
    } else {
        try self.linkDependency(mod_index, dep_idx);
    }
}

/// `.css_url` record 가 방금 resolve 된 asset 모듈을 CSS 참조에 맞게 준비한다 (#4466).
/// 모든 link 경로(신규 resolve / cached replay / external)가 공유한다.
///
/// **dependency 엣지를 만들지 않는다.** CSS `url()` 이 가리키는 asset 은 JS 실행
/// 의존성이 아니다. 엣지를 만들면 chunk.zig 의 도달성 BFS 가 `m.dependencies` 를
/// 타고 asset 모듈에 도달하는데, parseAssetModule 이 asset 의 module_type 을 .js 로
/// 바꿔 두기 때문에 `isJavaScriptLike()` 필터를 통과해 JS 청크에 배정된다. 결과는
/// 아무도 부르지 않는 `var require_codicon = __commonJS(…)` 죽은 코드.
///
/// 엣지 없이도 asset 은 정상 emit 된다 — addModuleWithResolveDir 가 이미 그래프에
/// 등록했고, bundler.zig 의 asset 수집은 dependency/청크가 아니라 `asset_data` 를
/// 가진 *모든* 모듈을 훑기 때문이다. record.resolved 로 css_emitter 가 출력
/// 파일명을 되찾는다.
fn prepareCssUrlAsset(self: *ModuleGraph, mod_idx: usize, rec_i: usize, dep_idx: ModuleIndex) void {
    const record = self.modules.at(mod_idx).import_records[rec_i];
    const dep = self.modules.at(@intFromEnum(dep_idx));

    // CSS `url()` 대상은 확장자와 무관하게 파일 자산이다 (Vite 동작).
    // 기본 확장자 테이블에 없는 것(`.cur`, `.apng`, `.svgz` …)은 loader 가 `.none`
    // 인데, 그대로 두면 parse_module 이 `no_loader` **에러**로 빌드를 세운다 —
    // 이 CSS 는 예전엔 (재작성은 안 됐지만) 멀쩡히 빌드되던 것이라 명백한 회귀다.
    // 명시 `--loader` 지정(.explicit)은 존중해 건드리지 않는다.
    if (dep.loader == .none and !dep.loader_explicit) {
        dep.loader = .file;
    }

    // `url(./sprite.svg#icon)` / `url(./f.eot?#iefix)` — suffix 가 붙은 참조는 data
    // URL 로 인라인하면 suffix 를 붙일 자리가 없다 (base64 뒤에 `#icon` 을 이어붙이면
    // fragment 의미가 깨지거나 URL 자체가 망가진다). 파일로 방출하게 인라인을 끈다.
    // SVG 스프라이트는 4KB 미만이 흔해서 기본 inline-limit 에 그대로 걸린다.
    if (record.css_url_suffix.len > 0) {
        dep.asset_no_inline = true;
    }
}

pub fn applyResolveResult(
    self: *ModuleGraph,
    io: std.Io,
    mod_idx: usize,
    rec_i: usize,
    record: types.ImportRecord,
    resolved: ?plugin_mod.ResolvedModule,
    is_error: bool,
) !void {
    const mod_index = ModuleIndex.fromUsize(mod_idx);
    // (#3984) 비-literal dynamic import(`import(x)`)는 parser 가 dynamic_invalid_reason
    // 을 설정해 둔 *의도된 비해석* 레코드다. worker scan 은 빈 specifier("") 로
    // resolve 를 시도하는데, 그 결과가 (a) native resolve 실패 → is_error, (b)
    // `--packages=external`/`--external` 에서 isExternal("")=true → is_error=false 인데
    // phantom external 로 link, (c) resolveId plugin 이 ""를 resolve → 잘못된 모듈 link
    // 로 갈라진다. 어느 경우든 generic "Cannot resolve module" 나 잘못된 link 대신 그
    // reason 을 warning 으로 emit + passthrough 해야 한다. 따라서 is_error 분기 *이전*
    // 에 일괄 처리한다(altitude: 세 경로를 한 곳으로 수렴). resolved 를 채우지 않고
    // return → codegen 이 원본 import() 를 native passthrough. resolve_failed 마킹으로
    // resolveModuleImports 의 동형 분기가 중복 emit 하지 않게 한다(단일 경고).
    if (record.dynamic_invalid_reason) |reason| {
        const rec_ptr = &self.modules.at(mod_idx).import_records[rec_i];
        if (!rec_ptr.resolve_failed) {
            self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, reason, null);
            rec_ptr.resolve_failed = true;
        }
        return;
    }
    if (is_error) {
        // Worker resolve 실패 → 경고만 (메인 빌드 중단하지 않음)
        if (record.kind == .worker) {
            self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Cannot resolve worker module", record.specifier);
            return;
        }
        // ModuleNotFound — browser에서 Node 빌트인은 빈 CJS로 대체.
        // `.css_url` 은 제외한다 (#4485): CSS `url()` 의 대상은 **파일**이지 모듈이 아니라
        // Node builtin 일 수가 없다. `isNodeBuiltin` 이 sub-path 도 builtin 으로 치기 때문에
        // (`util/types`) `url(path/gone.png)` 같은 참조가 여기서 빈 CJS stub 으로 삼켜져
        // "Cannot resolve CSS url()" 경고가 사라졌다 — bare url() 이 형제 파일로 해석되는
        // 지금은 그 경고가 오탈자를 잡아주는 유일한 안전망이라 삼키면 안 된다.
        if (record.kind != .css_url and
            self.resolve_cache.platform.isBrowserLike() and
            resolve_cache_mod.isNodeBuiltin(record.specifier))
        {
            const dep_idx = try self.addDisabledModule(record.specifier);
            try appendResolvedDep(self, mod_idx, .{
                .record_index = @intCast(rec_i),
                .kind = record.kind,
                .target = .disabled,
                .path = .{ .specifier = record.specifier },
            });
            try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
            return;
        }
        // try-block 안의 optional require/import — warning + stub.
        // follow-redirects/debug.js 의 silent-catch 패턴 같이 unresolved 가
        // runtime 에 catch 되는 의도된 케이스를 build hard-fail 시키지 않는다.
        if (record.is_optional) {
            self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Optional dependency not resolved (will throw at runtime if reached)", record.specifier);
            const dep_idx = try self.addOptionalMissingModule(record.specifier);
            try appendResolvedDep(self, mod_idx, .{
                .record_index = @intCast(rec_i),
                .kind = record.kind,
                .target = .optional_missing,
                .path = .{ .specifier = record.specifier },
            });
            try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
            return;
        }
        // #2466 implicit type-only import — `react-native-screens/types` 처럼 .d.ts 만
        // 있는 subpath 를 `import { X } from '...'` 로 가져와 X 를 type position 에서만
        // 쓰는 패턴. babel typescript preset 은 transform 시 statement 통째 제거하므로
        // Metro 는 resolve 시도조차 안 함. ZNTC 는 parser 가 type annotation 을 폐기
        // 해서 analyzer 가 type-position reference 를 못 보지만, 그게 오히려 도움 —
        // value position 참조가 0 이면 (truly unused 이거나 type-only) 어느 경우든
        // bundle 에서 빠져도 동작 동등. resolve 실패 + binding 전부 value-use 없음 →
        // soft fail (warning + stub).
        if (record.kind == .static_import and graph_import_usage.isImportAllBindingsUnused(self, self.modules.at(mod_idx), record)) {
            self.addDiag(.unresolved_import, .warning, self.modules.at(mod_idx).path, record.span, .resolve, "Type-only import elided (no value usage)", record.specifier);
            const dep_idx = try self.addDisabledModule(record.specifier);
            try appendResolvedDep(self, mod_idx, .{
                .record_index = @intCast(rec_i),
                .kind = record.kind,
                .target = .disabled,
                .path = .{ .specifier = record.specifier },
            });
            try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
            return;
        }
        // `.css_url` 은 경고에 그친다 (Vite parity, #4466). CSS 의 `url()` 은 빌드
        // 타임에 해석되지 않아도 런타임에 유효할 수 있다 — 서버가 따로 서빙하거나,
        // 배포 스크립트가 나중에 복사해 넣는 자산이 흔하다. 여기서 빌드를 세우면
        // 지금까지 (재작성은 안 되지만) 멀쩡히 빌드되던 프로젝트가 업그레이드
        // 하자마자 깨진다. 해석 실패한 url 은 emitter 가 원문 그대로 흘려보낸다.
        const sev: types.BundlerDiagnostic.Severity = switch (record.kind) {
            .dynamic_import, .css_url => .warning,
            else => .@"error",
        };
        const msg = if (record.kind == .css_url)
            "Cannot resolve CSS url() asset — left unchanged"
        else
            "Cannot resolve module";
        self.addDiag(.unresolved_import, sev, self.modules.at(mod_idx).path, record.span, .resolve, msg, record.specifier);
        // 실패 확정 마킹 — 성공(recordResolvedDep 가 resolved 설정)·external 과 동일하게
        // "재resolve 불필요" 상태로 둬야 shouldResolveRecordForModule/resolveModuleImports
        // 가 이 record 를 다시 resolve(+ 중복 진단)하지 않는다.
        self.modules.at(mod_idx).import_records[rec_i].resolve_failed = true;
        return;
    }

    if (resolved) |m| {
        // Phase 1 의 cache 와 plugin (fromLegacy 통과) 는 file/disabled variant 만 반환.
        // virtual/dataurl/external/custom 은 PR 5 plugin layer 도입 시 처리.
        switch (m) {
            .file => |f| {
                // PR resolve interning: f.path / f.resolve_dir 는 path_pool 소유 (borrow only).
                // Worker: 메인 그래프에 모듈로 추가하지 않고 경로만 수집
                if (record.kind == .worker) {
                    const path_dupe = try self.allocator.dupe(u8, f.path);
                    try self.worker_entries.append(self.allocator, .{
                        .resolved_path = path_dupe,
                        .source_module = @enumFromInt(mod_idx),
                        .record_index = @intCast(rec_i),
                    });
                    try appendResolvedDep(self, mod_idx, .{
                        .record_index = @intCast(rec_i),
                        .kind = record.kind,
                        .target = .worker,
                        .path = .{ .interned = f.path },
                        .resolve_dir = if (f.resolve_dir) |d| .{ .interned = d } else null,
                        .target_is_module_field = f.is_module_field,
                    });
                    return;
                }

                // PR-3a lazy: 동적 import 타겟은 BFS 경계에서 정지 — addModule(=parse 유발)
                // 대신 seed 로 deferred 한다. BFS 종료 후 materializeLazySeeds 가 일괄 처리
                // (static 으로도 도달했으면 그 파싱 모듈에 link, 아니면 미파싱 seed). incremental
                // 캐시 정합 위해 appendResolvedDep 는 유지.
                //   게이트는 dev_split(=dev_mode and code_splitting and lazy_compilation)과 동일.
                //   셋 중 하나라도 빠지면 미파싱 seed 가 단일번들/프로덕션 emit 을 깨므로(동적
                //   로더 미생성) eager 유지 → kill-switch 회귀 0. (virtual/external 동적 타겟은
                //   이 .file arm 밖이라 PR-3a-i 에선 eager — PR-3b 범위.)
                // PR-3b-ii: lazy_force_parse 에 든 타겟은 deferred 하지 않고 즉시 parse(eager)
                // — on-demand 가 그 seed 만 force-parse 한 fresh 빌드로 단일청크를 만든다.
                if (self.lazy_compilation and self.code_splitting and self.dev_mode and record.kind == .dynamic_import and !pathInForceParse(self, f.path)) {
                    const pa = self.path_arena.allocator();
                    try self.lazy_seeds.append(self.allocator, .{
                        .from = mod_index,
                        .rec_i = @intCast(rec_i),
                        .path = try pa.dupe(u8, f.path),
                        .resolve_dir = if (f.resolve_dir) |d| try pa.dupe(u8, d) else null,
                    });
                    try appendResolvedDep(self, mod_idx, .{
                        .record_index = @intCast(rec_i),
                        .kind = record.kind,
                        .target = .file,
                        .path = .{ .interned = f.path },
                        .resolve_dir = if (f.resolve_dir) |d| .{ .interned = d } else null,
                        .target_is_module_field = f.is_module_field,
                    });
                    return;
                }

                const dep_idx = try self.addModuleWithResolveDir(io, f.path, f.resolve_dir);
                if (f.is_module_field or self.modules.at(mod_idx).is_module_field) {
                    self.modules.at(@intFromEnum(dep_idx)).is_module_field = true;
                }
                const request_changed = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, dep_idx);
                try appendResolvedDep(self, mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .file,
                    .path = .{ .interned = f.path },
                    .resolve_dir = if (f.resolve_dir) |d| .{ .interned = d } else null,
                    .target_is_module_field = f.is_module_field,
                });
                try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
                if (request_changed) try resolveDeferredRequestedImportsIfReady(self, io, dep_idx);
            },
            .disabled => |d| {
                // PR resolve interning: d.path 는 path_pool 소유 (borrow only).
                _ = d;
                const dep_idx = try self.addDisabledModule(record.specifier);
                _ = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, dep_idx);
                try appendResolvedDep(self, mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .disabled,
                    .path = .{ .specifier = record.specifier },
                });
                try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
            },
            .virtual => |v| {
                // #1961 + #3759: virtual module 은 plugin 의 load 훅이 source 채움.
                // addModule 이 path 를 dupe 하므로 graph 가 owner. v.path 는 이미
                // `internResolvedModule` 이 path_pool 에 intern 한 borrow slice → .interned
                // 로 wrap (PathRef 의미 정합: .interned = path_pool 소유, caller borrow).
                // putModule 의 clonePathRefIfNeeded 가 .interned → .owned dupe.
                const dep_idx = try self.addModule(io, v.path);
                const request_changed = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, dep_idx);
                try appendResolvedDep(self, mod_idx, .{
                    .record_index = @intCast(rec_i),
                    .kind = record.kind,
                    .target = .virtual,
                    .path = .{ .interned = v.path },
                });
                try recordResolvedDep(self, mod_index, mod_idx, rec_i, dep_idx, record.kind);
                if (request_changed) try resolveDeferredRequestedImportsIfReady(self, io, dep_idx);
            },
            // (deferred 6) `.external` 은 phantom external 경로 (line 354 의 else 분기) 가
            // 별도로 처리하지만, plugin 이 resolveId 에서 직접 `.external` 반환하는 경로는
            // 아직 미설계. `.dataurl` / `.custom` 도 동일 — production 도달 시 별도 RFC 후
            // 명시적 활성화. 그 전까지 release build 의 silent UB 방지 위해 explicit panic.
            .dataurl, .external, .custom => std.debug.panic(
                "resolved variant not yet wired into resolve_imports — plugin returned unsupported variant for specifier '{s}' (got {s})",
                .{ record.specifier, @tagName(m) },
            ),
        }
    } else {
        // external — phantom Module 로 graph 에 등록 + 양방향 link.
        // 핵심 정책: `record.resolved` 는 `.none` 그대로 둔다. emit/linker 의 기존
        // `rec.resolved.isNone()` 외부 검출 코드를 깨지 않으면서 ModuleInfo /
        // graph traversal 에서만 phantom 노드가 보이도록 분리.
        const ext_idx = try self.addExternalModule(record.specifier);
        const src_mod = self.modules.at(mod_idx);
        src_mod.import_records[rec_i].is_external = true;
        src_mod.import_records[rec_i].is_lazy_resolved = false;
        _ = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, ext_idx);
        try appendResolvedDep(self, mod_idx, .{
            .record_index = @intCast(rec_i),
            .kind = record.kind,
            .target = .external,
            .path = .{ .specifier = record.specifier },
        });
        if (record.kind == .dynamic_import) {
            try self.linkDynamicImport(mod_index, ext_idx);
        } else if (record.kind == .css_url or record.kind == .worker) {
            // external 로 분류된 css_url / worker 는 JS 의존성 엣지를 만들면 안 된다.
            // 이것들은 import 가 아니라 **URL 문자열**이다 — 엣지를 걸면 UMD/AMD 의
            // 의존성 배열(`define(["css.worker.js"], …)`)에 딸려 들어가 AMD 로더가 worker
            // 스크립트를 메인 번들의 모듈 의존성으로 fetch·실행하려 든다 (#4483).
            // emitter 는 원문 URL 을 그대로 흘려보낸다.
        } else {
            try self.linkDependency(mod_index, ext_idx);
        }
    }
}

pub fn resolveDeferredRequestedImportsIfReady(self: *ModuleGraph, io: std.Io, idx: ModuleIndex) anyerror!void {
    if (idx.isNone()) return;
    const mod_idx = idx.toUsize();
    if (mod_idx >= self.modules.count()) return;
    const m = self.modules.at(mod_idx);
    if (m.state != .ready or m.is_external or m.is_disabled) return;
    try propagateRequestedExportsFromResolvedReExports(self, io, idx);
    if (!graph_requested_exports.hasDeferredRequestedImports(self, mod_idx)) return;
    try resolveModuleImports(self, io, idx);
}

fn propagateRequestedExportsFromResolvedReExports(self: *ModuleGraph, io: std.Io, idx: ModuleIndex) anyerror!void {
    if (idx.isNone()) return;
    const mod_idx = idx.toUsize();
    if (mod_idx >= self.modules.count()) return;
    const m = self.modules.at(mod_idx);

    for (m.import_records, 0..) |record, rec_i| {
        if (record.kind != .re_export) continue;
        if (record.resolved.isNone()) continue;
        const request_changed = try graph_requested_exports.requestDependencyExports(self, mod_idx, rec_i, record, record.resolved);
        if (request_changed) {
            // 이미 resolve 된 re-export barrel 에 뒤늦게 namespace/require 요청이 들어오면
            // 하위 lazy barrel 의 미해결 record 까지 다시 전파해야 한다.
            try resolveDeferredRequestedImportsIfReady(self, io, record.resolved);
        }
    }
}

/// Phase 1: 모듈의 import들을 resolve하고 의존성 모듈을 등록한다.
/// modules 배열이 커질 수 있으므로, 포인터가 아닌 인덱스로만 접근.
pub fn resolveModuleImports(self: *ModuleGraph, io: std.Io, idx: ModuleIndex) !void {
    const mod_idx = @intFromEnum(idx);
    if (mod_idx >= self.modules.count()) return;

    const mod_ptr = self.modules.at(mod_idx);
    const module_path = mod_ptr.path;
    const source_dir = mod_ptr.sourceDir();

    // Plugin: resolveId 훅용 runner를 루프 밖에서 한 번만 생성
    const plugin_runner: ?plugin_mod.PluginRunner = self.pluginRunnerWithBuiltins();

    // import.meta.glob: glob 레코드를 파일 시스템에서 확장
    expandGlobRecords(self.allocator, io, mod_ptr.import_records, source_dir);
    // require.context: plugin 으로 matches 주입 + context_expansion_deps 로 수집 (#1579 Phase 4).
    expandRequireContextRecords(self, io, mod_idx);

    const records = mod_ptr.import_records;
    for (records, 0..) |record, rec_i| {
        if (record.kind == .glob) continue;
        if (record.kind == .require_context) continue;
        if (record.kind == .dynamic_import) {
            if (record.dynamic_invalid_reason) |reason| {
                // 비-literal dynamic import: warning 후 resolved=.none 유지 →
                // chunk/codegen 무시(원본 import() 네이티브 passthrough).
                // (#3984) worker-scan 경로(applyResolveResult)가 이미 진단했으면
                // resolve_failed 가 set 되어 있다 → 중복 emit 방지. worker scan 을
                // 거치지 않고 직접 도달한 fallback 경로만 여기서 emit 하되, 여기서도
                // resolve_failed 를 set 해 (applyResolveResult 와 대칭) resolveModuleImports
                // 재진입(lazy re-export barrel 타깃이 ready 후 재방문)에서 중복 emit 을 막는다.
                if (!record.resolve_failed) {
                    self.addDiag(.unresolved_import, .warning, module_path, record.span, .resolve, reason, null);
                    mod_ptr.import_records[rec_i].resolve_failed = true;
                }
                continue;
            }
        }
        if (record.resolved != .none or record.is_external or record.resolve_failed) continue;
        const should_link = graph_requested_exports.shouldLinkResolvedRecordForModule(self, mod_idx, rec_i, record);

        // Plugin: resolveId 훅 — 기본 resolver 전에 플러그인에게 경로 해석 기회를 줌
        if (plugin_runner) |runner| {
            if (self.shouldRunResolveId(record.specifier)) {
                // this.resolve (PR4): resolveId hook 에 ResolveCache 전달.
                // this.emitFile (PR5): resolveId hook 에 EmitStore 전달.
                var hook_ctx: plugin_mod.HookContext = .{ .resolve_cache = @ptrCast(self.resolve_cache), .emit_store = self.emit_store };
                const resolve_result = runner.runResolveId(record.specifier, module_path, self.allocator, &hook_ctx) catch |err| switch (err) {
                    error.PluginFailed => {
                        self.addPluginFailureDiag(hook_ctx.failure, module_path, record.span, .resolve);
                        return;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                // non-null이면 플러그인이 resolve 완료 → 기본 resolver 건너뜀.
                // PR resolve interning: plugin 결과를 cache 의 path_pool 로 intern (caller borrow 일관).
                if (resolve_result) |plugin_result| {
                    const interned = try self.resolve_cache.internResolvedModule(plugin_result);
                    if (should_link) {
                        try applyResolveResult(self, io, mod_idx, rec_i, record, interned, false);
                    } else {
                        self.markRecordLazyResolved(mod_idx, rec_i);
                        self.discardResolvedModule(interned);
                    }
                    continue;
                }
                // null이면 기본 resolver로 fall through
            }
        }

        const resolved = self.resolve_cache.resolve(
            io,
            source_dir,
            record.specifier,
            record.kind,
        ) catch |err| switch (err) {
            error.ModuleNotFound => {
                try applyResolveResult(self, io, mod_idx, rec_i, record, null, true);
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (should_link) {
            try applyResolveResult(self, io, mod_idx, rec_i, record, resolved, false);
        } else if (resolved) |resolved_module| {
            self.markRecordLazyResolved(mod_idx, rec_i);
            self.discardResolvedModule(resolved_module);
        }
    }

    // require.context context_expansion_deps 도 resolve + addDep.
    try applyContextDepResults(self, io, mod_idx);
}
