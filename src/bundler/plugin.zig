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

/// Rollup 호환 플러그인 인터페이스.
/// 각 훅은 optional 함수 포인터 — null이면 해당 훅을 구현하지 않음.
/// context 필드로 플러그인 상태를 전달 (builtin은 null, subprocess는 child process handle).
pub const Plugin = struct {
    name: []const u8,
    /// 플러그인 상태를 전달하는 opaque 포인터.
    /// builtin 플러그인은 null, subprocess 플러그인은 SubprocessPlugin 포인터.
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

    // ─── AST 훅 (transformer 내부에서 AST 노드 방문 시 호출) ───

    /// 함수 노드 방문 훅. visitFunction 완료 후 호출.
    /// function_declaration, function_expression, arrow_function_expression 대상.
    onFunction: ?*const fn (ctx: ?*anyopaque, api: *AstTransformCtx, func: FunctionInfo) PluginError!void = null,

    /// Auto-workletization: 특정 함수 호출의 인자를 자동으로 worklet 변환.
    /// transformer가 call_expression을 방문할 때 callee 이름을 매칭하여
    /// 해당 인자 위치의 function을 worklet으로 처리한다.
    autoWorkletCallees: []const AutoWorkletCallee = &.{},
};

/// Auto-workletization 대상 함수 정의.
/// call_expression의 callee 이름이 매칭되면 지정된 인자 위치의 함수를 worklet으로 변환.
pub const AutoWorkletCallee = struct {
    name: []const u8,
    /// worklet으로 변환할 인자 인덱스 (0-based). 최대 4개.
    arg_indices: [4]u8 = .{ 0, 0xFF, 0xFF, 0xFF },
    /// true이면 obj.method() 형태의 method call도 매칭 (callee가 static_member_expression)
    is_method: bool = false,
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
