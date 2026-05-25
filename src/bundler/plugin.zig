//! ZNTC Bundler — Plugin System
//!
//! Rollup 호환 플러그인 인터페이스 (resolveId, load, transform, renderChunk, generateBundle).
//! Builtin 플러그인은 Zig 함수 포인터로 구현하여 최고 성능.
//! Subprocess 플러그인은 context 포인터로 child process 상태를 전달.
//!
//! 훅 실행 순서:
//!   - resolveId/load: 첫 번째 non-null 반환 플러그인이 승리 (first 모드)
//!   - transform/renderChunk: 순차 체이닝 (이전 플러그인 출력 → 다음 플러그인 입력)
//!   - generateBundle: 모두 실행

const std = @import("std");
const OutputFile = @import("emitter.zig").OutputFile;
const fs = @import("fs.zig");
const types = @import("types.zig");
const ModuleType = types.ModuleType;
const ast_plugin_mod = @import("../transformer/ast_plugin.zig");
pub const AstTransformCtx = ast_plugin_mod.AstTransformCtx;
pub const FunctionInfo = ast_plugin_mod.FunctionInfo;

/// `Plugin.load` 가 반환할 수 있는 결과 — esbuild `OnLoadResult`, Rollup `{ code, ... }` 호환.
/// `loader` 가 non-null 이면 graph 가 그 값으로 module loader override (확장자 추론 무시).
/// (#2157)
pub const LoadResult = struct {
    contents: []const u8,
    loader: ?types.Loader = null,
    module_type: ?types.ModuleType = null,
    /// plugin 이 반환한 `{ meta }` (JSON 문자열). null = 미설정. caller(parse_arena) 소유 (#1880 PR2).
    meta: ?[]const u8 = null,
    /// Rollup `syntheticNamedExports` (#3664 P2). null = 미설정. 그 외 = fallback 대상 export 이름
    /// ("default" 또는 string target). caller(parse_arena) 소유.
    synthetic_named_exports: ?[]const u8 = null,
};

/// 플러그인 훅에서 반환할 수 있는 에러 타입.
/// anyerror를 쓰지 않고 specific error set으로 제한하여
/// 호출부에서 switch로 명시적 처리 가능.
pub const PluginError = error{
    PluginFailed,
    OutOfMemory,
};

pub const PluginFailure = struct {
    allocator: std.mem.Allocator,
    plugin_name: []const u8,
    hook_name: []const u8,
    message: []const u8,
    file_path: []const u8,
    line: u32 = 0,
    column: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        plugin_name: []const u8,
        hook_name: []const u8,
        message: []const u8,
        file_path: []const u8,
        line: u32,
        column: u32,
    ) !PluginFailure {
        const plugin_name_copy = try allocator.dupe(u8, plugin_name);
        errdefer allocator.free(plugin_name_copy);
        const hook_name_copy = try allocator.dupe(u8, hook_name);
        errdefer allocator.free(hook_name_copy);
        const message_copy = try allocator.dupe(u8, message);
        errdefer allocator.free(message_copy);
        const file_path_copy = try allocator.dupe(u8, file_path);
        return .{
            .allocator = allocator,
            .plugin_name = plugin_name_copy,
            .hook_name = hook_name_copy,
            .message = message_copy,
            .file_path = file_path_copy,
            .line = line,
            .column = column,
        };
    }

    pub fn deinit(self: PluginFailure) void {
        self.allocator.free(self.plugin_name);
        self.allocator.free(self.hook_name);
        self.allocator.free(self.message);
        self.allocator.free(self.file_path);
    }

    pub fn formatMessage(self: PluginFailure, allocator: std.mem.Allocator) ![]const u8 {
        if (self.file_path.len > 0 and self.line > 0) {
            return std.fmt.allocPrint(
                allocator,
                "Plugin \"{s}\" failed in {s}: {s} ({s}:{d}:{d})",
                .{ self.plugin_name, self.hook_name, self.message, self.file_path, self.line, self.column },
            );
        }
        if (self.file_path.len > 0) {
            return std.fmt.allocPrint(
                allocator,
                "Plugin \"{s}\" failed in {s}: {s} ({s})",
                .{ self.plugin_name, self.hook_name, self.message, self.file_path },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "Plugin \"{s}\" failed in {s}: {s}",
            .{ self.plugin_name, self.hook_name, self.message },
        );
    }
};

/// fallible plugin hook 의 out-param. 호출자가 stack 에 만들어 hook 으로 전달하면
/// hook 이 실패 metadata 와 (load/transform 의 경우) source map chain 을 채운다.
/// 이전에는 threadlocal 두 개로 같은 데이터를 흘렸지만 thread-safety/생명주기/계약
/// 추적 모두 명시 out-param 이 깔끔.
pub const HookContext = struct {
    /// hook 이 `error.PluginFailed` 를 반환할 때 metadata 가 들어간다.
    /// 성공 path 에서는 null. caller 가 consume (addPluginFailureDiag) 또는
    /// `deinit()` 으로 해제 책임.
    failure: ?PluginFailure = null,
    /// `load` / `transform` 이 반환한 source map JSON chain.
    /// 다른 hook 은 사용 안 함. caller 가 free 책임.
    source_maps: ?[]const []const u8 = null,
    /// `transform` hook 결과의 `{ meta }` (JSON 문자열) out-param (#1880 #3664 P1). source_maps 와
    /// 동일 패턴 — pluginTransform 이 set, runTransformForModule 이 module.plugin_meta 에 deep merge.
    /// load/resolveId meta 는 각 hook 결과로 직접 처리. caller(parse_arena) 소유.
    meta: ?[]const u8 = null,
    /// `this.getModuleInfo` (PR3, self-only) 용 현재 transform 중인 Module 포인터.
    /// graph 를 조회하지 않고 이 모듈 자신의 정보(id/code/meta)만 노출한다 — discovery 병렬
    /// 단계에서 graph 는 main thread 가 mutate 중이므로 worker 가 graph 를 읽으면 race.
    /// self 모듈은 worker 가 load 단계에서 확정(path/source/plugin_meta)했으므로 안전.
    /// transform hook 에서만 set. null = getModuleInfo 미지원 hook (#1880 PR3).
    current_module: ?*const anyopaque = null,
    /// `this.resolve` (PR4) 용 ResolveCache 포인터. native resolver 는 순수 path resolution
    /// (graph 미접근, sharded-mutex thread-safe)이라 worker/JS thread 에서 안전 + plugin 재진입
    /// 없음. resolveId/load/transform hook 에서 set. null = this.resolve 미지원 (#1880 PR4).
    resolve_cache: ?*anyopaque = null,
    /// `this.emitFile` (PR5) 용 EmitStore 포인터. emit 된 asset 은 메인 스레드(TSFN callJsCallback)
    /// 에서만 단일 store 에 직렬 수집되므로 동기화 불필요(emit_store.zig doc 참조). resolveId/load/
    /// transform hook 에서 set. null = this.emitFile 미지원 hook (#1880 PR5).
    emit_store: ?*anyopaque = null,

    /// 사용 안 하는 failure metadata 를 일괄 정리. 이미 consume 된 경우 no-op.
    /// swallow 경로 (lifecycle hook, fallback null path 등) 에서 `defer ctx.deinit()` 으로 사용.
    pub fn deinit(self: *HookContext) void {
        if (self.failure) |f| {
            f.deinit();
            self.failure = null;
        }
    }
};

/// 두 plugin meta JSON object 를 deep merge 한다 (#1880 #3664 P1: hook 간 meta 누적).
/// nested object 는 재귀 merge, scalar/array/타입불일치는 `add`(나중 hook/plugin) 우선 — Rollup 의
/// hook 순서 의미(later wins)와 일치. shallow merge 는 nested 손실이라 쓰지 않는다. 중간/결과 Value
/// 는 `arena` 소유. 한쪽이 비-object 이거나 parse 실패면 안전하게 add/base 로 fallback. runTransform
/// (chain 누적)·runTransformForModule(load+transform) 양쪽이 공유하도록 plugin.zig 에 둔다.
pub fn mergeMetaJson(arena: std.mem.Allocator, base: ?[]const u8, add: []const u8) ![]const u8 {
    const base_json = base orelse return arena.dupe(u8, add);
    var base_v = std.json.parseFromSliceLeaky(std.json.Value, arena, base_json, .{}) catch
        return arena.dupe(u8, add);
    const add_v = std.json.parseFromSliceLeaky(std.json.Value, arena, add, .{}) catch
        return arena.dupe(u8, base_json);
    if (base_v != .object or add_v != .object) return arena.dupe(u8, add);
    try deepMergeMetaValue(&base_v, add_v);
    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(base_v, .{})});
}

fn deepMergeMetaValue(base: *std.json.Value, add: std.json.Value) std.mem.Allocator.Error!void {
    var it = add.object.iterator();
    while (it.next()) |e| {
        if (base.object.getPtr(e.key_ptr.*)) |existing| {
            if (existing.* == .object and e.value_ptr.* == .object) {
                try deepMergeMetaValue(existing, e.value_ptr.*);
                continue;
            }
        }
        // 신규 키, 또는 둘 중 하나가 비-object → add(나중) 값으로 덮어쓴다.
        try base.object.put(e.key_ptr.*, e.value_ptr.*);
    }
}

/// Plugin resolveId 응답의 통합 모델 (#1885).
///
/// origin 별 type-safe 분기 — esbuild 의 string namespace 보다 컴파일 타임 안전.
/// rolldown 의 풍부한 ResolvedId 와 비슷하지만 tag 가 fs.Namespace 와 통일.
pub const ResolvedModule = union(fs.Namespace) {
    /// fs 또는 plugin 이 제공한 실제 파일. 절대 경로 + module_type + ESM hint.
    /// `owns_path` (default true): caller 가 path/resolve_dir 를 자체 alloc 했음 →
    /// `internResolvedModule` 가 intern 후 원본 free. static literal / parse_arena borrow
    /// 면 false 명시. 모든 production caller (native resolver + NAPI bridge + plugin_test)
    /// 가 dupe 이므로 true 가 호환 default. future plugin layer 의 borrow 케이스만 false.
    file: struct {
        path: []const u8,
        resolve_dir: ?[]const u8 = null,
        module_type: ModuleType = .unknown,
        is_module_field: bool = false,
        owns_path: bool = true,
    },
    /// 메모리 모듈 (plugin only). plugin_data 로 plugin context 전달.
    /// (#3759) `owns_path`: plugin 이 path 를 자체 alloc 했으면 true → bundler 가 intern
    /// 후 원본 free. static literal / borrowed specifier 면 false (default).
    virtual: struct {
        path: []const u8,
        plugin_data: ?*anyopaque = null,
        owns_path: bool = false,
    },
    /// data: URL — 인라인 base64 asset.
    dataurl: struct {
        mime: []const u8,
        data: []const u8,
    },
    /// 번들 미포함 — 런타임 import 유지.
    /// `owns_path` (default true): `.file` 과 동일 시맨틱 (PR #3763 후속).
    external: struct {
        path: []const u8,
        owns_path: bool = true,
    },
    /// browser 필드 false 매핑 — 빈 CJS 로 대체 (esbuild "(disabled)" 방식).
    /// module_type 보존 — resolve_cache 의 cache lookup 정보 손실 방지.
    /// `owns_path` (default true): `.file` 과 동일 시맨틱.
    disabled: struct {
        path: []const u8,
        module_type: ModuleType = .unknown,
        owns_path: bool = true,
    },
    /// 사용자 plugin 의 자유 namespace.
    /// `owns_path` (default true): path *및* name 둘 다 동일 owner 가정.
    /// **invariant**: `owns_path=true` 시 `name.ptr != path.ptr` — 같은 slice 를 둘 다
    /// 가리키면 `internResolvedModule` 가 double-free 시도 (debug assert 로 잡힘).
    /// mixed owner (name borrow + path owned 등) 필요하면 future RFC (`owns_name`/`owns_path`
    /// 분리). 현재 모든 caller 가 동일 owner 라 단일 flag 충분.
    custom: struct {
        name: []const u8,
        path: []const u8,
        plugin_data: ?*anyopaque = null,
        owns_path: bool = true,
    },
};

/// `Plugin.resolveContext` hook signature. (#1579 Phase 2)
pub const ResolveContextFn = ?*const fn (
    ctx: ?*anyopaque,
    dir: []const u8,
    recursive: bool,
    filter_pattern: ?[]const u8,
    filter_flags: ?[]const u8,
    importer: []const u8,
    allocator: std.mem.Allocator,
    hook_ctx: *HookContext,
) PluginError!?[]const []const u8;

/// Rollup 호환 플러그인 인터페이스. 각 훅은 optional 함수 포인터 — null이면 해당 훅을 구현하지 않음.
/// builtin 플러그인(worklet 등) 전용. JS 플러그인은 @zntc/core NAPI 경로에서 처리된다.
pub const Plugin = struct {
    name: []const u8,
    /// 플러그인 상태 전달용 opaque 포인터 (대부분 null).
    context: ?*anyopaque = null,

    /// 모듈 경로 해석 커스텀 (alias, virtual module).
    /// non-null 반환 시 기본 resolver를 건너뜀.
    /// 실패 시 `hook_ctx.failure` 채우고 `error.PluginFailed`.
    resolveId: ?*const fn (ctx: ?*anyopaque, specifier: []const u8, importer: ?[]const u8, allocator: std.mem.Allocator, hook_ctx: *HookContext) PluginError!?ResolvedModule = null,

    /// 모듈 내용 로딩 (virtual module, 커스텀 로더).
    /// non-null 반환 시 파일 시스템 읽기를 건너뜀.
    /// `LoadResult.loader` 를 non-null 로 반환하면 graph 가 module loader 를 그 값으로 override
    /// (확장자 기반 추론 무시) — esbuild `onLoad` callback 의 `loader: 'text' | 'binary' | ...`
    /// 와 동일 의미. (#2157)
    /// `hook_ctx.source_maps` 를 채워 source map chain 전달 가능 (#1902).
    load: ?*const fn (ctx: ?*anyopaque, path: []const u8, allocator: std.mem.Allocator, hook_ctx: *HookContext) PluginError!?LoadResult = null,

    /// 코드 변환 (codegen 직후, CJS 래핑 전).
    /// non-null 반환 시 원본 코드를 반환값으로 교체.
    /// `hook_ctx.source_maps` 를 채워 source map chain 전달 가능 (#1902).
    transform: ?*const fn (ctx: ?*anyopaque, code: []const u8, id: []const u8, allocator: std.mem.Allocator, hook_ctx: *HookContext) PluginError!?[]const u8 = null,

    /// 청크 코드 후처리 (청크 완성 후, footer 전).
    /// non-null 반환 시 청크 코드를 반환값으로 교체.
    renderChunk: ?*const fn (ctx: ?*anyopaque, code: []const u8, chunk_name: []const u8, allocator: std.mem.Allocator, hook_ctx: *HookContext) PluginError!?[]const u8 = null,

    /// 번들 생성 완료 알림. 모든 플러그인에 호출됨.
    generateBundle: ?*const fn (ctx: ?*anyopaque, output_files: []const OutputFile, hook_ctx: *HookContext) void = null,

    /// bundle 시작 시 1회 호출. esbuild `onStart`, Rollup/Vite/rolldown `buildStart` 동일.
    /// 옵션 인자는 Zig 측에서 안 넘김 — JS 어댑터가 자체 context 로 forward.
    buildStart: ?*const fn (ctx: ?*anyopaque, hook_ctx: *HookContext) PluginError!void = null,

    /// bundle 종료 시 1회 호출. 성공/실패 모두 dispatch. 실패 시 fatal diagnostic 첫 항목 전달.
    /// esbuild `onEnd`, Rollup/Vite/rolldown `buildEnd` 동일.
    buildEnd: ?*const fn (ctx: ?*anyopaque, build_error: ?*const types.BundlerDiagnostic, hook_ctx: *HookContext) PluginError!void = null,

    /// write 완료 후 1회 호출. watch 모드면 매 rebuild 마다 재호출.
    /// Rollup/Vite/rolldown `closeBundle` 동일. esbuild 는 `onDispose` 라 명명 다름.
    closeBundle: ?*const fn (ctx: ?*anyopaque, hook_ctx: *HookContext) PluginError!void = null,

    /// `require.context(dir, recursive, filter)` 매칭 결과 주입 (#1579 Phase 2).
    /// ZNTC 자체 regex executor 가 없어서 (#1771) host runtime 의 RegExp 에 위임.
    ///
    /// **mode 인자 미포함**: Metro/webpack 모두 매칭 자체엔 mode 영향 없음 (mode 는 codegen
    /// 단계의 chunk 분할 결정만 좌우). 따라서 host plugin 은 파일 매칭에만 집중하고, mode 는
    /// `record.context_mode` 로 codegen (Phase 3) 에서 직접 활용.
    ///
    /// **메모리 소유권**: outer slice + 각 inner `[]const u8` 모두 `allocator` 로 할당해야 한다.
    /// `Module.deinit` 시 graph 가 일괄 free. plugin 이 source slice / static literal 을 그대로
    /// 반환하려면 `allocator.dupe(u8, s)` 로 복사 필수. 메모리 contract 단순화 위해 단일 정책.
    ///
    /// null 반환: 이 plugin 이 처리 안 함 (다음 plugin 시도 또는 graph 가 diagnostic emit).
    /// 빈 슬라이스 `&.{}`: "매칭 0개 (empty context)" — 정상 동작.
    resolveContext: ResolveContextFn = null,

    // ─── AST 훅 (transformer 내부에서 AST 노드 방문 시 호출) ───

    /// 함수 노드 방문 훅. visitFunction 완료 후 호출.
    /// function_declaration, function_expression, arrow_function_expression 대상.
    onFunction: ?*const fn (ctx: ?*anyopaque, api: *AstTransformCtx, func: FunctionInfo) PluginError!void = null,

    /// Auto-workletization: 특정 함수 호출의 인자를 자동으로 worklet 변환.
    /// transformer가 call_expression을 방문할 때 callee 이름을 매칭하여
    /// 해당 인자 위치의 function을 worklet으로 처리한다.
    autoWorkletCallees: []const AutoWorkletCallee = &.{},

    /// AST 노드 방문 시 호출되는 훅. transformer의 visitNode가 특정 tag에 도달하면
    /// 해당 훅을 호출. 훅이 non-null을 반환하면 default 방문을 건너뛰고 그 결과 사용.
    ///
    /// Babel plugin의 visitor 객체와 동일한 모델 — plugin이 자기 관심 태그만 선언하면
    /// transformer는 해당 tag 방문 시 자동 dispatch. worklet 같은 AST-level 플러그인 로직을
    /// core transformer 밖에 응집시키기 위함.
    visitor: ?Visitor = null,
};

/// AST 노드 방문 훅 묶음.
/// 각 필드는 특정 태그의 enter 훅 — null이면 해당 태그에 개입 없음.
pub const Visitor = struct {
    on_program: ?VisitHook = null,
    on_object_expression: ?VisitHook = null,
    on_call_expression: ?VisitHook = null,
    on_class_declaration: ?VisitHook = null,
    on_class_expression: ?VisitHook = null,
};

/// 노드 방문 훅 시그니처.
/// 반환값:
///   - null: default 방문 진행
///   - NodeIndex: default 방문 건너뛰고 반환값을 결과로 사용
pub const VisitHook = *const fn (
    ctx: ?*anyopaque,
    api: *AstTransformCtx,
    node_idx: ast_plugin_mod.NodeIndex,
) PluginError!?ast_plugin_mod.NodeIndex;

/// Auto-workletization 대상 함수 정의.
/// call_expression의 callee 이름이 매칭되면 지정된 인자 위치의 함수를 worklet으로 변환.
pub const AutoWorkletCallee = struct {
    name: []const u8,
    /// worklet으로 변환할 인자 인덱스 (0-based). 최대 4개.
    arg_indices: [4]u8 = .{ 0, 0xFF, 0xFF, 0xFF },
    /// true이면 obj.method() 형태의 method call도 매칭 (callee가 static_member_expression)
    is_method: bool = false,
    /// true이면 지정된 인자가 object literal일 때 프로퍼티 값(function/arrow/method)도
    /// 재귀적으로 worklet으로 변환. `useAnimatedScrollHandler({ onScroll: fn })` 등
    /// Reanimated "object hook" 패턴용.
    accept_object: bool = false,
    /// 수신자(receiver) 검증 방식.
    /// - any: 이름만 매칭 (기본)
    /// - layout_animation: `X.withCallback(cb)` 형태에서 X가 Layout Animation 클래스인지 추가 검증.
    ///   FadeIn/SlideIn/Bounce* 등의 알려진 클래스 및 new/chain 형태 허용.
    /// - gesture_object: `X.onStart(cb)` 형태에서 X가 `Gesture.Foo()` 또는 그 체인인지 추가 검증.
    ///   Babel plugin의 containsGestureObject 포팅.
    receiver_kind: ReceiverKind = .any,

    pub const ReceiverKind = enum { any, layout_animation, gesture_object };
};

/// 플러그인 배열을 순회하며 훅을 실행하는 유틸리티.
/// stateless — plugins 슬라이스 참조만 보유.
pub const PluginRunner = struct {
    plugins: []const Plugin,

    pub fn init(plugins: []const Plugin) PluginRunner {
        return .{ .plugins = plugins };
    }

    /// plugins가 비어있으면 true (no-op 최적화용)
    pub fn isEmpty(self: *const PluginRunner) bool {
        return self.plugins.len == 0;
    }

    /// resolveId: first 모드 — 첫 번째 non-null 반환값 사용.
    /// 모든 플러그인이 null을 반환하면 null (기본 resolver 사용).
    /// 실패 시 hook 이 `hook_ctx.failure` 를 채우고 `error.PluginFailed`.
    pub fn runResolveId(
        self: *const PluginRunner,
        specifier: []const u8,
        importer: ?[]const u8,
        allocator: std.mem.Allocator,
        hook_ctx: *HookContext,
    ) PluginError!?ResolvedModule {
        for (self.plugins) |p| {
            if (p.resolveId) |hook| {
                if (try hook(p.context, specifier, importer, allocator, hook_ctx)) |result| {
                    return result;
                }
            }
        }
        return null;
    }

    /// resolveContext: first 모드 — 첫 번째 non-null 반환값 사용. (#1579 Phase 2)
    /// 모든 플러그인이 null 반환 시 null (graph 가 diagnostic 으로 처리).
    pub fn runResolveContext(
        self: *const PluginRunner,
        dir: []const u8,
        recursive: bool,
        filter_pattern: ?[]const u8,
        filter_flags: ?[]const u8,
        importer: []const u8,
        allocator: std.mem.Allocator,
        hook_ctx: *HookContext,
    ) PluginError!?[]const []const u8 {
        for (self.plugins) |p| {
            if (p.resolveContext) |hook| {
                if (try hook(p.context, dir, recursive, filter_pattern, filter_flags, importer, allocator, hook_ctx)) |result| {
                    return result;
                }
            }
        }
        return null;
    }

    /// load: first 모드 — 첫 번째 non-null 반환값 사용.
    /// 모든 플러그인이 null을 반환하면 null (파일 시스템에서 읽기).
    /// 성공 시 `hook_ctx.source_maps` 에 plugin 이 채운 source map chain 이 들어 있다.
    pub fn runLoad(
        self: *const PluginRunner,
        path: []const u8,
        allocator: std.mem.Allocator,
        hook_ctx: *HookContext,
    ) PluginError!?LoadResult {
        for (self.plugins) |p| {
            if (p.load) |hook| {
                if (try hook(p.context, path, allocator, hook_ctx)) |result| {
                    return result;
                }
            }
        }
        return null;
    }

    /// transform: 순차 체이닝 — 이전 플러그인 출력이 다음 플러그인 입력.
    /// 체이닝 중간 결과는 free. 최종 결과는 allocator 소유.
    /// 아무 플러그인도 변환하지 않으면 null 반환.
    /// 체인 안에서 각 plugin 이 채운 source maps 를 모아 `hook_ctx.source_maps` 에 합친다.
    pub fn runTransform(
        self: *const PluginRunner,
        code: []const u8,
        id: []const u8,
        allocator: std.mem.Allocator,
        hook_ctx: *HookContext,
    ) PluginError!?[]const u8 {
        var source_maps: std.ArrayList([]const u8) = .empty;
        defer source_maps.deinit(allocator);

        var current: ?[]const u8 = null;
        for (self.plugins) |p| {
            if (p.transform) |hook| {
                const input = current orelse code;
                // 각 plugin 별 fresh inner_ctx — source_maps 는 chain 에서 누적, failure 는
                // 첫 실패 시 outer 로 옮긴다. plugin hook 이 failure 를 read 하는 contract 는
                // 없으므로 hook_ctx.failure 시드 불필요.
                // current_module(PR3) / resolve_cache(PR4) / emit_store(PR5) 를 inner_ctx 로 전파.
                var inner_ctx: HookContext = .{
                    .current_module = hook_ctx.current_module,
                    .resolve_cache = hook_ctx.resolve_cache,
                    .emit_store = hook_ctx.emit_store,
                };
                const result = hook(p.context, input, id, allocator, &inner_ctx) catch |err| {
                    hook_ctx.failure = inner_ctx.failure;
                    return err;
                };
                // meta 는 code(result) 유무와 무관하게 누적 — Rollup transform 은 meta 만 반환 가능.
                // chain 의 각 plugin meta 를 outer hook_ctx.meta 에 deep merge(later plugin 우선).
                // source_maps 와 동일하게 inner_ctx → outer 로 모은다(#1880 #3664 P1). NAPI 경유 JS
                // plugin 은 단일 dispatcher 가 JS chain 을 이미 merge 하므로 existing 분기는 native↔
                // native(여러 native plugin 이 meta 반환) 전용 가드 — 현재는 거의 안 타지만 안전망.
                if (inner_ctx.meta) |m| {
                    hook_ctx.meta = if (hook_ctx.meta) |existing|
                        (mergeMetaJson(allocator, existing, m) catch m)
                    else
                        m;
                }
                if (result) |r| {
                    if (inner_ctx.source_maps) |maps| {
                        try source_maps.appendSlice(allocator, maps);
                    }
                    // 이전 체이닝 결과가 있으면 해제 (원본 code는 caller 소유이므로 건드리지 않음)
                    if (current) |prev| allocator.free(prev);
                    current = r;
                }
            }
        }
        if (source_maps.items.len > 0) {
            hook_ctx.source_maps = try source_maps.toOwnedSlice(allocator);
        }
        return current;
    }

    /// renderChunk: 순차 체이닝 — 이전 플러그인 출력이 다음 플러그인 입력.
    /// 아무 플러그인도 변환하지 않으면 null 반환.
    pub fn runRenderChunk(
        self: *const PluginRunner,
        code: []const u8,
        chunk_name: []const u8,
        allocator: std.mem.Allocator,
        hook_ctx: *HookContext,
    ) PluginError!?[]const u8 {
        var current: ?[]const u8 = null;
        for (self.plugins) |p| {
            if (p.renderChunk) |hook| {
                const input = current orelse code;
                if (try hook(p.context, input, chunk_name, allocator, hook_ctx)) |result| {
                    if (current) |prev| allocator.free(prev);
                    current = result;
                }
            }
        }
        return current;
    }

    /// generateBundle: 모든 플러그인 실행. 반환값 없음.
    pub fn runGenerateBundle(
        self: *const PluginRunner,
        output_files: []const OutputFile,
        hook_ctx: *HookContext,
    ) void {
        for (self.plugins) |p| {
            if (p.generateBundle) |hook| {
                hook(p.context, output_files, hook_ctx);
            }
        }
    }

    /// buildStart: 모든 플러그인 실행. 한 plugin 이 실패하면 즉시 stop + 에러 전파.
    /// bundle 시작 직후 1회만 호출.
    pub fn runBuildStart(self: *const PluginRunner, hook_ctx: *HookContext) PluginError!void {
        for (self.plugins) |p| {
            if (p.buildStart) |hook| try hook(p.context, hook_ctx);
        }
    }

    /// buildEnd: 모든 플러그인 실행. plugin 에러는 swallow — 본 build 의 결과를 가리지 않음.
    /// build_error 가 non-null 이면 build failure (fatal diagnostic 의 첫 항목).
    pub fn runBuildEnd(
        self: *const PluginRunner,
        build_error: ?*const types.BundlerDiagnostic,
    ) void {
        for (self.plugins) |p| {
            if (p.buildEnd) |hook| {
                var hook_ctx: HookContext = .{};
                defer hook_ctx.deinit();
                hook(p.context, build_error, &hook_ctx) catch {};
            }
        }
    }

    /// closeBundle: 모든 플러그인 실행. plugin 에러는 swallow — write 후 cleanup 단계라 caller 영향 없음.
    /// watch 모드는 매 rebuild 마다 호출.
    pub fn runCloseBundle(self: *const PluginRunner) void {
        for (self.plugins) |p| {
            if (p.closeBundle) |hook| {
                var hook_ctx: HookContext = .{};
                defer hook_ctx.deinit();
                hook(p.context, &hook_ctx) catch {};
            }
        }
    }
};
