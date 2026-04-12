//! Reanimated Worklet Plugin
//!
//! "worklet" 디렉티브가 있는 함수를 감지하고,
//! __workletHash, __closure, __initData 프로퍼티 할당을 주입한다.
//!
//! function_declaration (statement 위치) → trailing_nodes로 뒤에 삽입
//! function_expression (expression 위치) → IIFE factory로 감싸서 교체
//!
//! Auto-workletization:
//!   scheduleOnUI, runOnUI, runOnJS 등 알려진 함수의 인자를 자동 worklet 변환.
//!   'worklet' 디렉티브 없이도 FunctionInfo.is_auto_worklet == true이면 변환.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../../lexer/token.zig").Span;
const ast_plugin = @import("../ast_plugin.zig");
const AstTransformCtx = ast_plugin.AstTransformCtx;
const FunctionInfo = ast_plugin.FunctionInfo;
const worklet_mod = @import("../transformer/worklet.zig");
const plugin_mod = @import("../../bundler/plugin.zig");
const Plugin = plugin_mod.Plugin;
const PluginError = plugin_mod.PluginError;
const AutoWorkletCallee = plugin_mod.AutoWorkletCallee;

pub fn plugin() Plugin {
    return .{
        .name = "reanimated-worklet",
        .onFunction = onFunction,
        .autoWorkletCallees = &auto_worklet_callees,
    };
}

/// Reanimated/Worklets auto-workletization 대상 함수 목록.
/// Babel react-native-worklets/plugin과 동일.
const auto_worklet_callees = [_]AutoWorkletCallee{
    // Scheduling functions (arg 0)
    .{ .name = "runOnUI" },
    .{ .name = "runOnUISync" },
    .{ .name = "runOnUIAsync" },
    .{ .name = "scheduleOnUI" },
    .{ .name = "executeOnUIRuntimeSync" },
    .{ .name = "runOnJS" },
    // Scheduling functions (arg 1)
    .{ .name = "runOnRuntime", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "runOnRuntimeSync", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "runOnRuntimeAsync", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "scheduleOnRuntime", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    // Hooks (arg 0)
    .{ .name = "useFrameCallback" },
    .{ .name = "useAnimatedStyle" },
    .{ .name = "useAnimatedProps" },
    .{ .name = "createAnimatedPropAdapter" },
    .{ .name = "useDerivedValue" },
    .{ .name = "useAnimatedScrollHandler" },
    // useAnimatedReaction (args 0 and 1)
    .{ .name = "useAnimatedReaction", .arg_indices = .{ 0, 1, 0xFF, 0xFF } },
    // Animation callbacks
    .{ .name = "withTiming", .arg_indices = .{ 2, 0xFF, 0xFF, 0xFF } },
    .{ .name = "withSpring", .arg_indices = .{ 2, 0xFF, 0xFF, 0xFF } },
    .{ .name = "withDecay", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "withRepeat", .arg_indices = .{ 3, 0xFF, 0xFF, 0xFF } },
    // Gesture handler method callbacks (arg 0, method call)
    .{ .name = "onBegin", .is_method = true },
    .{ .name = "onStart", .is_method = true },
    .{ .name = "onEnd", .is_method = true },
    .{ .name = "onFinalize", .is_method = true },
    .{ .name = "onUpdate", .is_method = true },
    .{ .name = "onChange", .is_method = true },
    .{ .name = "onTouchesDown", .is_method = true },
    .{ .name = "onTouchesMove", .is_method = true },
    .{ .name = "onTouchesUp", .is_method = true },
    .{ .name = "onTouchesCancelled", .is_method = true },
};

fn onFunction(ctx: ?*anyopaque, api: *AstTransformCtx, info: FunctionInfo) PluginError!void {
    _ = ctx;

    if (info.body_idx.isNone()) return;

    const has_directive = api.hasDirective(info.body_idx, "worklet");
    if (!has_directive and !info.is_auto_worklet) return;

    // 두 body를 별도 strip해야 함 (각각 다른 AST):
    // 1) visited body (info.body_idx): JS thread 실행용. inner 변환(auto-worklet 등) 보존.
    //    반환값은 불필요 — side effect(modified_body 패치)만 사용.
    // 2) original body (info.original_body_idx): __initData.code용 (TS 포함/ES5 미적용).
    if (has_directive) {
        _ = try api.stripDirective(info.body_idx);
    }
    const code_body = if (has_directive)
        try worklet_mod.stripWorkletDirective(api.transformer, info.original_body_idx)
    else
        info.original_body_idx;

    const all_closure_vars = try api.getClosureVars(info.original_body_idx, info.original_params_start, info.original_params_len);
    defer {
        for (all_closure_vars) |cv| api.getAllocator().free(cv.name);
        api.getAllocator().free(all_closure_vars);
    }

    const func_name = info.name orelse "anonymous";

    // 함수 자기 참조 제외: 재귀 함수에서 자신의 이름이 closure에 포함되면 순환 참조 발생.
    // function_declaration/expression의 이름은 body 내에서 자기 참조 가능 (JS 스펙).
    var closure_vars_count: usize = 0;
    for (all_closure_vars) |cv| {
        if (!std.mem.eql(u8, cv.name, func_name)) closure_vars_count += 1;
    }
    const closure_vars = if (closure_vars_count < all_closure_vars.len) blk: {
        const filtered = api.getAllocator().alloc(worklet_mod.ClosureVar, closure_vars_count) catch return error.OutOfMemory;
        var fi: usize = 0;
        for (all_closure_vars) |cv| {
            if (!std.mem.eql(u8, cv.name, func_name)) {
                filtered[fi] = cv;
                fi += 1;
            }
        }
        break :blk filtered;
    } else all_closure_vars;
    defer if (closure_vars.ptr != all_closure_vars.ptr) api.getAllocator().free(closure_vars);
    const init_code = try api.generateCode(
        func_name,
        code_body,
        closure_vars,
        info.original_params_start,
        info.original_params_len,
        info.flags,
    );
    defer api.getAllocator().free(init_code);

    const hash = @as(u32, @truncate(std.hash.Wyhash.hash(0, init_code)));

    const stmts = try worklet_mod.buildWorkletPropertyAssignments(
        api.transformer,
        func_name,
        closure_vars,
        init_code,
        hash,
        info.source_path,
        info.node_idx,
    );

    if (info.node_tag == .function_declaration) {
        // statement 위치: trailing_nodes로 함수 뒤에 삽입
        for (stmts) |stmt| {
            try api.addTrailingStatement(stmt);
        }
    } else {
        // expression 위치 (function_expression/arrow): IIFE factory로 감싸서 교체
        //
        // 변환:
        //   function fn() { "worklet"; body }
        // →
        //   (function() {
        //     var fn = function fn() { body };
        //     fn.__workletHash = 123;
        //     fn.__closure = {};
        //     fn.__initData = { code: "...", location: "..." };
        //     return fn;
        //   })()
        const iife = try buildWorkletIIFE(api, info.node_idx, func_name, stmts);
        api.replaced_node = iife;
    }
}

/// function_expression worklet을 IIFE factory로 감싼다.
fn buildWorkletIIFE(
    api: *AstTransformCtx,
    func_node: NodeIndex,
    func_name: []const u8,
    prop_stmts: [4]NodeIndex,
) PluginError!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const t = api.transformer;

    // var funcName = <original function>;
    const name_span = try t.ast.addString(func_name);
    const binding = try t.ast.addNode(.{
        .tag = .binding_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
    const none = @intFromEnum(NodeIndex.none);
    const declarator = try t.addExtraNode(.variable_declarator, zero_span, &.{
        @intFromEnum(binding),
        none, // type annotation
        @intFromEnum(func_node), // init = original function
    });
    const decl_list = try t.ast.addNodeList(&.{declarator});
    const var_decl = try t.addExtraNode(.variable_declaration, zero_span, &.{
        0, // var
        decl_list.start,
        decl_list.len,
    });

    // return funcName;
    const return_ref = try t.ast.addNode(.{
        .tag = .identifier_reference,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
    const return_stmt = try t.ast.addNode(.{
        .tag = .return_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = return_ref, .flags = 0 } },
    });

    // factory body: [var_decl, prop_stmts[0..3], return_stmt]
    const body_list = try t.ast.addNodeList(&.{
        var_decl,      prop_stmts[0],
        prop_stmts[1], prop_stmts[2],
        prop_stmts[3], return_stmt,
    });
    const body = try t.ast.addNode(.{
        .tag = .block_statement,
        .span = zero_span,
        .data = .{ .list = body_list },
    });

    // function() { ... } (wrapper — 파라미터 없는 익명 함수)
    const empty_params = try t.ast.addNodeList(&.{});
    const wrapper_func = try t.addExtraNode(.function_expression, zero_span, &.{
        none, // name (anonymous)
        empty_params.start,
        empty_params.len,
        @intFromEnum(body),
        0, // flags
        none, // return type
    });

    // (function() { ... })() — IIFE 호출
    const call_args = try t.ast.addNodeList(&.{});
    const call_extra = try t.ast.addExtras(&.{
        @intFromEnum(wrapper_func),
        call_args.start,
        call_args.len,
        0,
    });
    return t.ast.addNode(.{
        .tag = .call_expression,
        .span = zero_span,
        .data = .{ .extra = call_extra },
    });
}
