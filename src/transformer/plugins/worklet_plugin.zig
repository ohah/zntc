//! Reanimated Worklet AST Plugin
//!
//! "worklet" 디렉티브가 있는 함수를 감지하고,
//! __workletHash, __closure, __initData 프로퍼티 할당을 함수 뒤에 주입한다.
//!
//! 사용:
//!   const plugins = [_]AstPlugin{ WorkletPlugin.plugin() };
//!   var t = Transformer.init(alloc, ast, .{ .ast_plugins = &plugins });

const std = @import("std");
const ast_plugin = @import("../ast_plugin.zig");
const AstPlugin = ast_plugin.AstPlugin;
const AstTransformCtx = ast_plugin.AstTransformCtx;
const FunctionInfo = ast_plugin.FunctionInfo;
const worklet_mod = @import("../transformer/worklet.zig");
const Error = @import("../transformer.zig").Transformer.Error;

/// Worklet AstPlugin 인스턴스를 반환한다.
pub fn plugin() AstPlugin {
    return .{
        .name = "reanimated-worklet",
        .onFunction = onFunction,
    };
}

/// onFunction 훅 — "worklet" 디렉티브 감지 + 프로퍼티 할당 주입.
fn onFunction(ctx: ?*anyopaque, api: *AstTransformCtx, info: FunctionInfo) Error!void {
    _ = ctx;

    // "worklet" 디렉티브 확인
    if (info.body_idx.isNone()) return;
    if (!api.hasDirective(info.body_idx, "worklet")) return;

    // 디렉티브 제거
    const stripped_body = try api.stripDirective(info.body_idx);

    // Closure 변수 추출
    const closure_vars = try api.getClosureVars(stripped_body, info.params_start, info.params_len);
    defer api.getAllocator().free(closure_vars);

    // Init code 생성
    const func_name = info.name orelse "anonymous";
    const init_code = try api.generateCode(
        func_name,
        stripped_body,
        closure_vars,
        info.params_start,
        info.params_len,
        info.flags,
    );
    defer api.getAllocator().free(init_code);

    // Hash 계산
    const hash = @as(u32, @truncate(std.hash.Wyhash.hash(0, init_code)));

    // __workletHash, __closure, __initData 프로퍼티 할당 생성
    const stmts = try worklet_mod.buildWorkletPropertyAssignments(
        api.transformer,
        func_name,
        closure_vars,
        init_code,
        hash,
        info.source_path,
    );

    // trailing statements로 함수 뒤에 삽입
    for (stmts) |stmt| {
        try api.addTrailingStatement(stmt);
    }
}
