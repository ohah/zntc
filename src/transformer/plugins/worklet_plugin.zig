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

// method_definition flags (parser/object.zig와 동일 인코딩).
const METHOD_FLAG_STATIC = 0x01;
const METHOD_FLAG_GETTER = 0x02;
const METHOD_FLAG_SETTER = 0x04;
const METHOD_FLAG_ASYNC = 0x08;
const METHOD_FLAG_GENERATOR = 0x10;

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
    // Layout Animation callback — receiver 검증 필수 (임의 .withCallback() 오인 방지).
    // `FadeIn.withCallback(cb)`, `new FadeIn().withCallback(cb)`, `FadeIn.build().withCallback(cb)` 등.
    .{ .name = "withCallback", .is_method = true, .receiver_kind = .layout_animation },
};

/// Layout Animation 클래스 이름 집합.
/// Reanimated의 EntryExit 애니메이션 + Layout Transition.
/// Babel plugin(src/layoutAnimationAutoworkletization.ts)과 동일.
pub const LAYOUT_ANIMATION_CLASSES = [_][]const u8{
    // EntryExit animations
    "BounceIn",            "BounceInDown",      "BounceInLeft",
    "BounceInRight",       "BounceInUp",        "BounceOut",
    "BounceOutDown",       "BounceOutLeft",     "BounceOutRight",
    "BounceOutUp",         "FadeIn",            "FadeInDown",
    "FadeInLeft",          "FadeInRight",       "FadeInUp",
    "FadeOut",             "FadeOutDown",       "FadeOutLeft",
    "FadeOutRight",        "FadeOutUp",         "FlipInEasyX",
    "FlipInEasyY",         "FlipInXDown",       "FlipInXUp",
    "FlipInYLeft",         "FlipInYRight",      "FlipOutEasyX",
    "FlipOutEasyY",        "FlipOutXDown",      "FlipOutXUp",
    "FlipOutYLeft",        "FlipOutYRight",     "LightSpeedInLeft",
    "LightSpeedInRight",   "LightSpeedOutLeft", "LightSpeedOutRight",
    "PinwheelIn",          "PinwheelOut",       "RollInLeft",
    "RollInRight",         "RollOutLeft",       "RollOutRight",
    "RotateInDownLeft",    "RotateInDownRight", "RotateInUpLeft",
    "RotateInUpRight",     "RotateOutDownLeft", "RotateOutDownRight",
    "RotateOutUpLeft",     "RotateOutUpRight",  "SlideInDown",
    "SlideInLeft",         "SlideInRight",      "SlideInUp",
    "SlideOutDown",        "SlideOutLeft",      "SlideOutRight",
    "SlideOutUp",          "StretchInX",        "StretchInY",
    "StretchOutX",         "StretchOutY",       "ZoomIn",
    "ZoomInDown",          "ZoomInEasyDown",    "ZoomInEasyUp",
    "ZoomInLeft",          "ZoomInRight",       "ZoomInRotate",
    "ZoomInUp",            "ZoomOut",           "ZoomOutDown",
    "ZoomOutEasyDown",     "ZoomOutEasyUp",     "ZoomOutLeft",
    "ZoomOutRight",        "ZoomOutRotate",     "ZoomOutUp",
    // Layout transitions
    "Layout",              "LinearTransition",  "SequencedTransition",
    "FadingTransition",    "JumpingTransition", "CurvedTransition",
    "EntryExitTransition",
};

/// Reanimated web 플랫폼 체크 함수 — `substituteWebPlatformChecks` 옵션에서 `true`로 치환 대상.
pub const WEB_PLATFORM_CHECK_NAMES = [_][]const u8{ "isWeb", "shouldBeUseWeb" };

/// Layout Animation 클래스의 체이닝 메서드 집합.
/// `FadeIn.duration(300).withCallback(cb)` 같은 체인 추적용.
pub const LAYOUT_ANIMATION_CHAINABLE_METHODS = [_][]const u8{
    // Base
    "build",              "duration",          "delay",                 "getDuration",
    "randomDelay",        "getDelay",          "getDelayFunction",
    // Complex
         "easing",
    "rotate",             "springify",         "damping",               "mass",
    "stiffness",          "overshootClamping", "energyThreshold",       "restDisplacementThreshold",
    "restSpeedThreshold", "withInitialValues", "getAnimationAndConfig",
    // DefaultTransition
    "easingX",
    "easingY",            "easingWidth",       "easingHeight",          "entering",
    "exiting",            "reverse",
};

fn onFunction(ctx: ?*anyopaque, api: *AstTransformCtx, info: FunctionInfo) PluginError!void {
    _ = ctx;

    if (info.body_idx.isNone()) return;

    const has_directive = api.hasDirective(info.body_idx, "worklet");
    if (!has_directive and !info.is_auto_worklet) return;

    // 두 body를 별도 strip해야 함 (각각 다른 AST):
    // 1) visited body (info.body_idx): JS thread 실행용. inner 변환(auto-worklet 등) 보존.
    //    function_declaration/expression은 dispatcher가 modified_body로 result 노드를 패치하지만,
    //    method_definition은 직접 function_expression을 새로 빌드하므로 stripped body를 명시 전달.
    // 2) original body (info.original_body_idx): __initData.code용 (TS 포함/ES5 미적용).
    const stripped_body = if (has_directive)
        try api.stripDirective(info.body_idx)
    else
        info.body_idx;
    const code_body = if (has_directive)
        try worklet_mod.stripWorkletDirective(api.transformer, info.original_body_idx)
    else
        info.original_body_idx;

    const func_name = info.name orelse "anonymous";

    const closure_vars = try api.getClosureVars(info.original_body_idx, info.original_params_start, info.original_params_len, info.name);
    defer {
        for (closure_vars) |cv| api.getAllocator().free(cv.name);
        api.getAllocator().free(closure_vars);
    }

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
    } else if (info.node_tag == .method_definition) {
        const t = api.transformer;
        const method_node = t.ast.getNode(info.node_idx);
        const me = method_node.data.extra;
        const method_flags = t.ast.extra_data.items[me + 4];
        const func_expr = try buildFunctionExprFromMethod(api, info, stripped_body);

        if ((method_flags & (METHOD_FLAG_GETTER | METHOD_FLAG_SETTER)) != 0) {
            // class body의 getter/setter는 IIFE object_property로 교체 불가 (class syntax 제약).
            // Babel 호환: body를 `var _w=function(){...}; _w.__workletHash=...; return _w;`로 치환.
            // getter 접근 시 worklet 함수를 반환 (Reanimated runtime 동작과 일치).
            api.modified_body = try buildFactoryBody(api, func_expr, func_name, stmts);
            return;
        }

        // 일반 object method → `{ key: (function(){ var fn=...; fn.__workletHash=...; return fn; })() }`
        const iife = try buildWorkletIIFE(api, func_expr, func_name, stmts);
        const key_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[me]);
        const prop = try t.ast.addNode(.{
            .tag = .object_property,
            .span = method_node.span,
            .data = .{ .binary = .{ .left = key_idx, .right = iife, .flags = 0 } },
        });
        api.replaced_node = prop;
    } else {
        // expression 위치 (function_expression/arrow): IIFE factory로 감싸서 교체
        const iife = try buildWorkletIIFE(api, info.node_idx, func_name, stmts);
        api.replaced_node = iife;
    }
}

/// method_definition에서 function_expression을 추출한다.
/// { build(props) { body } } → function build(props) { body }
/// body_idx: directive가 제거된 stripped body (caller가 전달).
fn buildFunctionExprFromMethod(api: *AstTransformCtx, info: FunctionInfo, body_idx: NodeIndex) PluginError!NodeIndex {
    const t = api.transformer;
    const method_node = t.ast.getNode(info.node_idx);
    const me = method_node.data.extra;

    // method_definition extra = [key(0), params_start(1), params_len(2), body(3), flags(4), ...]
    const name_span = if (info.name) |n| (t.ast.addString(n) catch return error.OutOfMemory) else Span{ .start = 0, .end = 0 };
    const name_node = if (info.name != null) (t.ast.addNode(.{
        .tag = .binding_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    }) catch return error.OutOfMemory) else NodeIndex.none;

    // method flags → function flags (async=bit0 of method flags bit3, generator=bit4)
    const method_flags = t.ast.extra_data.items[me + 4];
    var func_flags: u32 = 0;
    if ((method_flags & METHOD_FLAG_ASYNC) != 0) func_flags |= 0x01; // function async
    if ((method_flags & METHOD_FLAG_GENERATOR) != 0) func_flags |= 0x02; // function generator

    const none = @intFromEnum(NodeIndex.none);
    const func_extra = t.ast.addExtras(&.{
        @intFromEnum(name_node),
        info.params_start,
        info.params_len,
        @intFromEnum(body_idx),
        func_flags,
        none, // return type
    }) catch return error.OutOfMemory;
    return t.ast.addNode(.{
        .tag = .function_expression,
        .span = method_node.span,
        .data = .{ .extra = func_extra },
    }) catch return error.OutOfMemory;
}

/// Worklet factory block: `{ var name = func; name.__workletHash=...; ...; return name; }`
/// IIFE 및 getter/setter 바디 양쪽에서 재사용.
fn buildFactoryBody(
    api: *AstTransformCtx,
    func_node: NodeIndex,
    func_name: []const u8,
    prop_stmts: [5]NodeIndex,
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

    // factory body: [var_decl, ...prop_stmts(5), return_stmt]
    // prop_stmts 크기 변경 시 이 리스트도 함께 업데이트 — 의도적 결합(유지보수 단순성 우선).
    const body_list = try t.ast.addNodeList(&.{
        var_decl,      prop_stmts[0],
        prop_stmts[1], prop_stmts[2],
        prop_stmts[3], prop_stmts[4],
        return_stmt,
    });
    return t.ast.addNode(.{
        .tag = .block_statement,
        .span = zero_span,
        .data = .{ .list = body_list },
    });
}

/// function_expression worklet을 IIFE factory로 감싼다.
fn buildWorkletIIFE(
    api: *AstTransformCtx,
    func_node: NodeIndex,
    func_name: []const u8,
    prop_stmts: [5]NodeIndex,
) PluginError!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const t = api.transformer;
    const none = @intFromEnum(NodeIndex.none);

    const body = try buildFactoryBody(api, func_node, func_name, prop_stmts);

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
