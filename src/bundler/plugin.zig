//! ZTS Bundler — Plugin System
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
const resolver_mod = @import("resolver.zig");
const ResolveResult = resolver_mod.ResolveResult;
const OutputFile = @import("emitter.zig").OutputFile;
const fs = @import("fs.zig");
const types = @import("types.zig");
const ModuleType = types.ModuleType;
const ast_plugin_mod = @import("../transformer/ast_plugin.zig");
pub const AstTransformCtx = ast_plugin_mod.AstTransformCtx;
pub const FunctionInfo = ast_plugin_mod.FunctionInfo;

/// 플러그인 훅에서 반환할 수 있는 에러 타입.
/// anyerror를 쓰지 않고 specific error set으로 제한하여
/// 호출부에서 switch로 명시적 처리 가능.
pub const PluginError = error{
    PluginFailed,
    OutOfMemory,
};

/// Plugin resolveId 응답의 통합 모델 (#1885).
///
/// origin 별 type-safe 분기 — esbuild 의 string namespace 보다 컴파일 타임 안전.
/// rolldown 의 풍부한 ResolvedId 와 비슷하지만 tag 가 fs.Namespace 와 통일.
pub const ResolvedModule = union(fs.Namespace) {
    /// fs 또는 plugin 이 제공한 실제 파일. 절대 경로 + module_type + ESM hint.
    file: struct {
        path: []const u8,
        module_type: ModuleType = .unknown,
        is_module_field: bool = false,
    },
    /// 메모리 모듈 (plugin only). plugin_data 로 plugin context 전달.
    virtual: struct {
        path: []const u8,
        plugin_data: ?*anyopaque = null,
    },
    /// data: URL — 인라인 base64 asset.
    dataurl: struct {
        mime: []const u8,
        data: []const u8,
    },
    /// 번들 미포함 — 런타임 import 유지.
    external: struct {
        path: []const u8,
    },
    /// browser 필드 false 매핑 — 빈 CJS 로 대체 (esbuild "(disabled)" 방식).
    /// `resolver.ResolveResult.disabled = true` 와 동등 semantic.
    /// module_type 보존 — resolve_cache 의 cache lookup 정보 손실 방지.
    disabled: struct {
        path: []const u8,
        module_type: ModuleType = .unknown,
    },
    /// 사용자 plugin 의 자유 namespace.
    custom: struct {
        name: []const u8,
        path: []const u8,
        plugin_data: ?*anyopaque = null,
    },
};

/// 기존 `ResolveResult` (struct) → `ResolvedModule` (union) 변환.
/// 현재 graph 의 plugin runner 응답 변환에 사용 — plugin runner 가 union 직접
/// 반환으로 마이그레이션되면 제거 가능 (TODO).
pub fn fromLegacy(r: ResolveResult) ResolvedModule {
    if (r.disabled) return .{ .disabled = .{
        .path = r.path,
        .module_type = r.module_type,
    } };
    return .{ .file = .{
        .path = r.path,
        .module_type = r.module_type,
        .is_module_field = r.is_module_field,
    } };
}

/// `Plugin.resolveContext` hook signature. (#1579 Phase 2)
pub const ResolveContextFn = ?*const fn (
    ctx: ?*anyopaque,
    dir: []const u8,
    recursive: bool,
    filter_pattern: ?[]const u8,
    filter_flags: ?[]const u8,
    importer: []const u8,
    allocator: std.mem.Allocator,
) PluginError!?[]const []const u8;

/// Rollup 호환 플러그인 인터페이스. 각 훅은 optional 함수 포인터 — null이면 해당 훅을 구현하지 않음.
/// builtin 플러그인(worklet 등) 전용. JS 플러그인은 @zts/core NAPI 경로에서 처리된다.
pub const Plugin = struct {
    name: []const u8,
    /// 플러그인 상태 전달용 opaque 포인터 (대부분 null).
    context: ?*anyopaque = null,

    /// 모듈 경로 해석 커스텀 (alias, virtual module).
    /// non-null 반환 시 기본 resolver를 건너뜀.
    resolveId: ?*const fn (ctx: ?*anyopaque, specifier: []const u8, importer: ?[]const u8, allocator: std.mem.Allocator) PluginError!?ResolveResult = null,

    /// 모듈 내용 로딩 (virtual module, 커스텀 로더).
    /// non-null 반환 시 파일 시스템 읽기를 건너뜀.
    load: ?*const fn (ctx: ?*anyopaque, path: []const u8, allocator: std.mem.Allocator) PluginError!?[]const u8 = null,

    /// 코드 변환 (codegen 직후, CJS 래핑 전).
    /// non-null 반환 시 원본 코드를 반환값으로 교체.
    transform: ?*const fn (ctx: ?*anyopaque, code: []const u8, id: []const u8, allocator: std.mem.Allocator) PluginError!?[]const u8 = null,

    /// 청크 코드 후처리 (청크 완성 후, footer 전).
    /// non-null 반환 시 청크 코드를 반환값으로 교체.
    renderChunk: ?*const fn (ctx: ?*anyopaque, code: []const u8, chunk_name: []const u8, allocator: std.mem.Allocator) PluginError!?[]const u8 = null,

    /// 번들 생성 완료 알림. 모든 플러그인에 호출됨.
    generateBundle: ?*const fn (ctx: ?*anyopaque, output_files: []const OutputFile) void = null,

    /// `require.context(dir, recursive, filter)` 매칭 결과 주입 (#1579 Phase 2).
    /// ZTS 자체 regex executor 가 없어서 (#1771) host runtime 의 RegExp 에 위임.
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
    pub fn runResolveId(
        self: *const PluginRunner,
        specifier: []const u8,
        importer: ?[]const u8,
        allocator: std.mem.Allocator,
    ) PluginError!?ResolveResult {
        for (self.plugins) |p| {
            if (p.resolveId) |hook| {
                if (try hook(p.context, specifier, importer, allocator)) |result| {
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
    ) PluginError!?[]const []const u8 {
        for (self.plugins) |p| {
            if (p.resolveContext) |hook| {
                if (try hook(p.context, dir, recursive, filter_pattern, filter_flags, importer, allocator)) |result| {
                    return result;
                }
            }
        }
        return null;
    }

    /// load: first 모드 — 첫 번째 non-null 반환값 사용.
    /// 모든 플러그인이 null을 반환하면 null (파일 시스템에서 읽기).
    pub fn runLoad(
        self: *const PluginRunner,
        path: []const u8,
        allocator: std.mem.Allocator,
    ) PluginError!?[]const u8 {
        for (self.plugins) |p| {
            if (p.load) |hook| {
                if (try hook(p.context, path, allocator)) |result| {
                    return result;
                }
            }
        }
        return null;
    }

    /// transform: 순차 체이닝 — 이전 플러그인 출력이 다음 플러그인 입력.
    /// 체이닝 중간 결과는 free. 최종 결과는 allocator 소유.
    /// 아무 플러그인도 변환하지 않으면 null 반환.
    pub fn runTransform(
        self: *const PluginRunner,
        code: []const u8,
        id: []const u8,
        allocator: std.mem.Allocator,
    ) PluginError!?[]const u8 {
        var current: ?[]const u8 = null;
        for (self.plugins) |p| {
            if (p.transform) |hook| {
                const input = current orelse code;
                if (try hook(p.context, input, id, allocator)) |result| {
                    // 이전 체이닝 결과가 있으면 해제 (원본 code는 caller 소유이므로 건드리지 않음)
                    if (current) |prev| allocator.free(prev);
                    current = result;
                }
            }
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
    ) PluginError!?[]const u8 {
        var current: ?[]const u8 = null;
        for (self.plugins) |p| {
            if (p.renderChunk) |hook| {
                const input = current orelse code;
                if (try hook(p.context, input, chunk_name, allocator)) |result| {
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
    ) void {
        for (self.plugins) |p| {
            if (p.generateBundle) |hook| {
                hook(p.context, output_files);
            }
        }
    }
};
