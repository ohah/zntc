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
const wyhash = @import("../../util/wyhash.zig");
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
const Transformer = @import("../transformer.zig").Transformer;

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
        .visitor = .{
            .on_program = onProgram,
            .on_object_expression = onObjectExpression,
            .on_call_expression = onCallExpression,
            .on_class_declaration = onClassDeclaration,
            .on_class_expression = onClassDeclaration,
        },
    };
}

/// Reanimated/Worklets auto-workletization 대상 함수 목록.
/// Babel react-native-worklets/plugin과 동일.
const auto_worklet_callees = [_]AutoWorkletCallee{
    // Scheduling functions (arg 0) — Babel plugin reanimatedFunctionHooks
    .{ .name = "runOnUI" },
    .{ .name = "runOnUISync" },
    .{ .name = "runOnUIAsync" },
    .{ .name = "scheduleOnUI" },
    .{ .name = "executeOnUIRuntimeSync" },
    // NOTE: runOnJS(fn)은 JS thread에서 실행할 함수를 받는 것이라 worklet이 아님 — 제외.
    // Scheduling functions (arg 1)
    .{ .name = "runOnRuntime", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "runOnRuntimeSync", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "runOnRuntimeAsync", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "scheduleOnRuntime", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "runOnRuntimeSyncWithId", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "scheduleOnRuntimeWithId", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    // Hooks (arg 0)
    .{ .name = "useFrameCallback" },
    .{ .name = "useAnimatedStyle" },
    .{ .name = "useAnimatedProps" },
    .{ .name = "createAnimatedPropAdapter" },
    .{ .name = "useDerivedValue" },
    // Object hooks — 객체 리터럴 인자의 property value도 worklet으로 변환
    .{ .name = "useAnimatedScrollHandler", .accept_object = true },
    // Gesture Handler object hooks (gestureHandlerAutoworkletization.ts:41-51)
    .{ .name = "useTapGesture", .accept_object = true },
    .{ .name = "usePanGesture", .accept_object = true },
    .{ .name = "usePinchGesture", .accept_object = true },
    .{ .name = "useRotationGesture", .accept_object = true },
    .{ .name = "useFlingGesture", .accept_object = true },
    .{ .name = "useLongPressGesture", .accept_object = true },
    .{ .name = "useNativeGesture", .accept_object = true },
    .{ .name = "useManualGesture", .accept_object = true },
    .{ .name = "useHoverGesture", .accept_object = true },
    // useAnimatedReaction (args 0 and 1)
    .{ .name = "useAnimatedReaction", .arg_indices = .{ 0, 1, 0xFF, 0xFF } },
    // Animation callbacks
    .{ .name = "withTiming", .arg_indices = .{ 2, 0xFF, 0xFF, 0xFF } },
    .{ .name = "withSpring", .arg_indices = .{ 2, 0xFF, 0xFF, 0xFF } },
    .{ .name = "withDecay", .arg_indices = .{ 1, 0xFF, 0xFF, 0xFF } },
    .{ .name = "withRepeat", .arg_indices = .{ 3, 0xFF, 0xFF, 0xFF } },
    // Gesture handler method callbacks — receiver 검증 필수 (임의 `.onStart()` 오인 방지).
    // Babel plugin의 isGestureObjectEventCallbackMethod 참고: `Gesture.Foo()[.method()*].onX(cb)` 패턴만 매칭.
    .{ .name = "onBegin", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onStart", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onEnd", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onFinalize", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onUpdate", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onChange", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onTouchesDown", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onTouchesMove", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onTouchesUp", .is_method = true, .receiver_kind = .gesture_object },
    .{ .name = "onTouchesCancelled", .is_method = true, .receiver_kind = .gesture_object },
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

/// `Gesture.Foo()`의 `Foo` 후보 이름 집합 — gesture handler builder method의 receiver 검증에 사용.
/// Babel plugin의 `gestureHandlerGestureObjects` 그대로.
pub const GESTURE_OBJECT_NAMES = [_][]const u8{
    "Tap",        "Pan",    "Pinch",  "Rotation", "Fling",        "LongPress",
    "ForceTouch", "Native", "Manual", "Race",     "Simultaneous", "Exclusive",
    "Hover",
};

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

    // Babel 호환: 익명 worklet에 `<sanitizedFile>_null<N>` 이름 부여.
    // 같은 이름의 worklet이 동일 파일에서 충돌해도 sequence index로 구분 가능.
    var anon_name_buf: [256]u8 = undefined;
    var sanitize_buf: [128]u8 = undefined;
    const func_name = if (info.name) |n| n else blk: {
        const idx = api.transformer.plugins.worklet.anonymous_counter;
        api.transformer.plugins.worklet.anonymous_counter += 1;
        const file_marker = sanitizeFilename(info.source_path, &sanitize_buf);
        const name = std.fmt.bufPrint(&anon_name_buf, "{s}_null{d}", .{ file_marker, idx }) catch return error.OutOfMemory;
        break :blk name;
    };

    // ctx가 캐시 소유 — 해제는 dispatcher의 deinitClosureCache()가 담당 (#1114).
    const closure_vars = try api.getClosureVars(&info);

    const init_code = try api.generateCode(
        func_name,
        code_body,
        closure_vars,
        info.original_params_start,
        info.original_params_len,
        info.flags,
    );
    defer api.getAllocator().free(init_code);

    const hash = @as(u32, @truncate(wyhash.hashU64(init_code)));

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
        // 함수 body에서 "worklet" directive 제거 (dispatcher가 result 노드 body slot 패치)
        if (has_directive) api.modified_body = stripped_body;
    } else if (info.node_tag == .method_definition) {
        const t = api.transformer;
        const method_node = t.ast.getNode(info.node_idx);
        const me = method_node.data.extra;
        const method_flags = t.ast.extra_data.items[me + 3];
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

    // method_definition extra = [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
    const name_span = if (info.name) |n| (t.ast.addString(n) catch return error.OutOfMemory) else Span{ .start = 0, .end = 0 };
    const name_node = if (info.name != null) (t.ast.addNode(.{
        .tag = .binding_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    }) catch return error.OutOfMemory) else NodeIndex.none;

    // method flags → function flags (async=bit0 of method flags bit3, generator=bit4)
    const method_flags = t.ast.extra_data.items[me + 3];
    var func_flags: u32 = 0;
    if ((method_flags & METHOD_FLAG_ASYNC) != 0) func_flags |= 0x01; // function async
    if ((method_flags & METHOD_FLAG_GENERATOR) != 0) func_flags |= 0x02; // function generator

    const none = @intFromEnum(NodeIndex.none);
    // function_expression: extra = [name(0), params(1), body(2), flags(3), ret_type(4)]
    const params_list_node = t.ast.addFormalParameters(
        .{ .start = info.params_start, .len = info.params_len },
        method_node.span,
    ) catch return error.OutOfMemory;
    const func_extra = t.ast.addExtras(&.{
        @intFromEnum(name_node),
        @intFromEnum(params_list_node),
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
    const empty_params_node = try t.ast.addFormalParameters(empty_params, zero_span);
    const wrapper_func = try t.addExtraNode(.function_expression, zero_span, &.{
        none, // name (anonymous)
        @intFromEnum(empty_params_node),
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

// ================================================================
// Visitor hooks — Babel plugin visitor 포팅
// core transformer에 worklet-specific 로직이 leak되지 않도록 plugin에 응집.
// ================================================================

/// Program 노드: 파일 최상단 `'worklet';` directive 감지 시 top-level 함수/클래스를
/// auto-worklet으로 표시하고 전체 program을 재구성.
fn onProgram(ctx: ?*anyopaque, api: *AstTransformCtx, node_idx: NodeIndex) PluginError!?NodeIndex {
    _ = ctx;
    const t = api.transformer;
    const node = t.ast.getNode(node_idx);
    if (node.tag != .program) return null;
    if (!hasFileWorkletDirective(t, node.data.list.start, node.data.list.len)) return null;
    return try visitFileWorkletProgram(t, node);
}

/// Object expression: `{ ..., __workletContextObject: X }` 마커 감지 시 factory로 교체.
fn onObjectExpression(ctx: ?*anyopaque, api: *AstTransformCtx, node_idx: NodeIndex) PluginError!?NodeIndex {
    _ = ctx;
    const t = api.transformer;
    const node = t.ast.getNode(node_idx);
    if (node.tag != .object_expression) return null;
    if (!hasWorkletContextObjectMarker(t, node)) return null;
    return try lowerWorkletContextObject(t, node);
}

/// Call expression: `isWeb()` / `shouldBeUseWeb()` → `true` 리터럴 (옵션 플래그 기반).
fn onCallExpression(ctx: ?*anyopaque, api: *AstTransformCtx, node_idx: NodeIndex) PluginError!?NodeIndex {
    _ = ctx;
    const t = api.transformer;
    if (!t.options.substitute_web_platform_checks) return null;
    const node = t.ast.getNode(node_idx);
    if (node.tag != .call_expression) return null;
    const e = node.data.extra;
    if (e + 3 >= t.ast.extra_data.items.len) return null;
    const callee_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[e]);
    const args_len = t.ast.extra_data.items[e + 2];
    if (args_len != 0 or callee_idx.isNone()) return null;
    const callee = t.ast.getNode(callee_idx);
    if (callee.tag != .identifier_reference) return null;
    const name = t.ast.source[callee.span.start..callee.span.end];
    for (WEB_PLATFORM_CHECK_NAMES) |n| {
        if (std.mem.eql(u8, n, name)) {
            const true_span = try t.ast.addString("true");
            return try t.ast.addNode(.{
                .tag = .boolean_literal,
                .span = true_span,
                .data = .{ .string_ref = true_span },
            });
        }
    }
    return null;
}

// ================================================================
// Helpers — visitor 훅에서 호출 (transformer.zig에서 이관)
// ================================================================

fn hasFileWorkletDirective(t: *Transformer, list_start: u32, list_len: u32) bool {
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[list_start + i]);
        if (idx.isNone()) continue;
        const stmt = t.ast.getNode(idx);
        if (stmt.tag != .expression_statement) return false;
        const inner_idx = stmt.data.unary.operand;
        if (inner_idx.isNone()) return false;
        const inner = t.ast.getNode(inner_idx);
        if (inner.tag != .string_literal) return false;
        const text = t.ast.source[inner.span.start..inner.span.end];
        if (std.mem.eql(u8, text, "\"worklet\"") or std.mem.eql(u8, text, "'worklet'")) return true;
    }
    return false;
}

fn visitFileWorkletProgram(t: *Transformer, node: Node) !NodeIndex {
    const list_start = node.data.list.start;
    const list_len = node.data.list.len;

    const scratch_top = t.scratch.items.len;
    defer t.scratch.shrinkRetainingCapacity(scratch_top);
    const pending_top = t.pending_nodes.items.len;
    defer t.pending_nodes.shrinkRetainingCapacity(pending_top);
    const trailing_top = t.trailing_nodes.items.len;
    defer t.trailing_nodes.shrinkRetainingCapacity(trailing_top);

    // CommonJS `exports.X = Y` 는 Babel 호환을 위해 파일 하단으로 이동.
    var deferred_exports: std.ArrayList(NodeIndex) = .empty;
    defer deferred_exports.deinit(t.allocator);

    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const raw = t.ast.extra_data.items[list_start + i];
        const child_idx: NodeIndex = @enumFromInt(raw);
        if (!child_idx.isNone()) {
            const child = t.ast.getNode(child_idx);
            if (isCommonJSExport(t, child)) {
                const visited = try t.visitNode(child_idx);
                if (!visited.isNone()) try deferred_exports.append(t.allocator, visited);
                continue;
            }
            switch (child.tag) {
                .function_declaration, .class_declaration, .variable_declaration, .export_named_declaration, .export_default_declaration => t.plugins.worklet.auto_next = true,
                else => {},
            }
        }
        if (t.pending_nodes.items.len > pending_top) {
            try t.scratch.appendSlice(t.allocator, t.pending_nodes.items[pending_top..]);
            t.pending_nodes.shrinkRetainingCapacity(pending_top);
        }
        const new_child = try t.visitNode(child_idx);
        t.plugins.worklet.auto_next = false;
        if (!new_child.isNone()) try t.scratch.append(t.allocator, new_child);
        if (t.trailing_nodes.items.len > trailing_top) {
            try t.scratch.appendSlice(t.allocator, t.trailing_nodes.items[trailing_top..]);
            t.trailing_nodes.shrinkRetainingCapacity(trailing_top);
        }
    }

    for (deferred_exports.items) |e| try t.scratch.append(t.allocator, e);

    const new_list = try t.ast.addNodeList(t.scratch.items[scratch_top..]);
    return t.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}

/// `exports.X = Y` 형태의 statement인지 판정. Babel 동일 (module.X는 처리 안 함).
/// 원본: react-native-worklets/plugin/src/file.ts::isCommonJSExport
fn isCommonJSExport(t: *Transformer, node: Node) bool {
    if (node.tag != .expression_statement) return false;
    const inner_idx = node.data.unary.operand;
    if (inner_idx.isNone()) return false;
    const expr = t.ast.getNode(inner_idx);
    if (expr.tag != .assignment_expression) return false;
    const lhs_idx = expr.data.binary.left;
    if (lhs_idx.isNone()) return false;
    const lhs = t.ast.getNode(lhs_idx);
    if (lhs.tag != .static_member_expression) return false;
    const me = lhs.data.extra;
    if (me >= t.ast.extra_data.items.len) return false;
    const obj_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[me]);
    if (obj_idx.isNone()) return false;
    const obj = t.ast.getNode(obj_idx);
    if (obj.tag != .identifier_reference) return false;
    const obj_name = t.ast.source[obj.span.start..obj.span.end];
    return std.mem.eql(u8, obj_name, "exports");
}

fn hasWorkletContextObjectMarker(t: *Transformer, node: Node) bool {
    const list_start = node.data.list.start;
    const list_len = node.data.list.len;
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[list_start + i]);
        if (idx.isNone()) continue;
        const prop = t.ast.getNode(idx);
        if (prop.tag != .object_property) continue;
        const key_idx = prop.data.binary.left;
        if (key_idx.isNone()) continue;
        const key = t.ast.getNode(key_idx);
        if (key.tag != .identifier_reference) continue;
        const name = t.ast.source[key.span.start..key.span.end];
        if (std.mem.eql(u8, name, "__workletContextObject")) return true;
    }
    return false;
}

fn lowerWorkletContextObject(t: *Transformer, node: Node) !NodeIndex {
    const list_start = node.data.list.start;
    const list_len = node.data.list.len;
    const zero_span = Span{ .start = 0, .end = 0 };

    const scratch_top = t.scratch.items.len;
    defer t.scratch.shrinkRetainingCapacity(scratch_top);

    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const child_raw = t.ast.extra_data.items[list_start + i];
        const child_idx: NodeIndex = @enumFromInt(child_raw);
        const prop = t.ast.getNode(child_idx);
        var is_marker = false;
        if (prop.tag == .object_property) {
            const key = t.ast.getNode(prop.data.binary.left);
            if (key.tag == .identifier_reference) {
                const name = t.ast.source[key.span.start..key.span.end];
                is_marker = std.mem.eql(u8, name, "__workletContextObject");
            }
        }
        if (!is_marker) {
            const visited = try t.visitNode(child_idx);
            if (!visited.isNone()) try t.scratch.append(t.allocator, visited);
            continue;
        }

        // __workletContextObjectFactory: function() { 'worklet'; return { ...methods... }; }
        // factory가 호출되면 marker 없는 원본 object를 재구성해 반환 (runtime 정확성).
        const factory_name_span = try t.ast.addString("__workletContextObjectFactory");
        const new_key = try t.ast.addNode(.{
            .tag = .identifier_reference,
            .span = factory_name_span,
            .data = .{ .string_ref = factory_name_span },
        });
        const body = try buildContextObjectFactoryBody(t, list_start, list_len);
        const empty_params = try t.ast.addNodeList(&.{});
        const empty_params_node = try t.ast.addFormalParameters(empty_params, zero_span);
        const none = @intFromEnum(NodeIndex.none);
        const fn_node = try t.addExtraNode(.function_expression, zero_span, &.{
            none, @intFromEnum(empty_params_node), @intFromEnum(body), 0, none,
        });
        const visited_fn = try t.visitNode(fn_node);
        const new_prop = try t.ast.addNode(.{
            .tag = .object_property,
            .span = prop.span,
            .data = .{ .binary = .{ .left = new_key, .right = visited_fn, .flags = 0 } },
        });
        try t.scratch.append(t.allocator, new_prop);
    }

    const new_list = try t.ast.addNodeList(t.scratch.items[scratch_top..]);
    return t.ast.addNode(.{
        .tag = .object_expression,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}

/// Context object factory body — `'worklet'; return { ...non-marker members... };`
/// 원본 object_expression의 list_start/list_len을 받아 marker(`__workletContextObject`)를
/// 제외한 멤버들로 반환 object_expression을 재구성.
/// method_definition(`foo() {...}`)은 object_property + function_expression으로 long-form 변환.
fn buildContextObjectFactoryBody(t: *Transformer, list_start: u32, list_len: u32) !NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const scratch_top = t.scratch.items.len;
    defer t.scratch.shrinkRetainingCapacity(scratch_top);

    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const child_raw = t.ast.extra_data.items[list_start + i];
        const child_idx: NodeIndex = @enumFromInt(child_raw);
        const member = t.ast.getNode(child_idx);
        if (member.tag == .object_property) {
            const k = t.ast.getNode(member.data.binary.left);
            if (k.tag == .identifier_reference) {
                const name = t.ast.source[k.span.start..k.span.end];
                if (std.mem.eql(u8, name, "__workletContextObject")) continue;
            }
            try t.scratch.append(t.allocator, child_idx);
        } else if (member.tag == .method_definition) {
            // method → object_property with function_expression value.
            const me = member.data.extra;
            const key_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[me]);
            const params_idx_raw = t.ast.extra_data.items[me + 1];
            const body_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[me + 2]);
            const m_flags = t.ast.extra_data.items[me + 3];
            // method → function expression flags: async/generator만 전파
            var fn_flags: u32 = 0;
            if ((m_flags & METHOD_FLAG_ASYNC) != 0) fn_flags |= 0x01;
            if ((m_flags & METHOD_FLAG_GENERATOR) != 0) fn_flags |= 0x02;
            const none = @intFromEnum(NodeIndex.none);
            const fn_expr = try t.addExtraNode(.function_expression, member.span, &.{
                none, params_idx_raw, @intFromEnum(body_idx), fn_flags, none,
            });
            const new_prop = try t.ast.addNode(.{
                .tag = .object_property,
                .span = member.span,
                .data = .{ .binary = .{ .left = key_idx, .right = fn_expr, .flags = 0 } },
            });
            try t.scratch.append(t.allocator, new_prop);
        }
    }

    const ret_obj_list = try t.ast.addNodeList(t.scratch.items[scratch_top..]);
    const ret_obj = try t.ast.addNode(.{
        .tag = .object_expression,
        .span = zero_span,
        .data = .{ .list = ret_obj_list },
    });
    return buildWorkletReturnBlock(t, ret_obj, &.{});
}

/// `{ 'worklet'; return <ret_value>; }` block 생성. worklet factory body 공통 구조.
/// 추가 선언이 필요하면 `extra_stmts`에 var_decl 등을 넘기면 순서대로 삽입.
fn buildWorkletReturnBlock(t: *Transformer, ret_value: NodeIndex, extra_stmts: []const NodeIndex) !NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const dir_span = try t.ast.addString("\"worklet\"");
    const dir_str = try t.ast.addNode(.{
        .tag = .string_literal,
        .span = dir_span,
        .data = .{ .string_ref = dir_span },
    });
    const dir_stmt = try t.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = dir_str, .flags = 0 } },
    });
    const ret_stmt = try t.ast.addNode(.{
        .tag = .return_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = ret_value, .flags = 0 } },
    });
    const top = t.scratch.items.len;
    defer t.scratch.shrinkRetainingCapacity(top);
    try t.scratch.append(t.allocator, dir_stmt);
    try t.scratch.appendSlice(t.allocator, extra_stmts);
    try t.scratch.append(t.allocator, ret_stmt);
    const body_list = try t.ast.addNodeList(t.scratch.items[top..]);
    return t.ast.addNode(.{
        .tag = .block_statement,
        .span = zero_span,
        .data = .{ .list = body_list },
    });
}

/// `{ 'worklet'; return null; }` — stub factory body.
fn buildWorkletContextStubBody(t: *Transformer) !NodeIndex {
    const null_span = try t.ast.addString("null");
    const null_node = try t.ast.addNode(.{
        .tag = .null_literal,
        .span = null_span,
        .data = .{ .none = 0 },
    });
    return buildWorkletReturnBlock(t, null_node, &.{});
}

// ================================================================
// Worklet class (__workletClass marker) — Phase 5
// ================================================================

/// `class Foo { __workletClass = X; ... }` 감지 시 factory 생성.
/// 반환값 non-null 시 default 방문 건너뛰고 visited class + trailing factory 할당.
fn onClassDeclaration(ctx: ?*anyopaque, api: *AstTransformCtx, node_idx: NodeIndex) PluginError!?NodeIndex {
    _ = ctx;
    const t = api.transformer;
    const node = t.ast.getNode(node_idx);
    if (node.tag != .class_declaration and node.tag != .class_expression) return null;

    // class body = extra[2] (.list)
    const class_extra = node.data.extra;
    if (class_extra + 2 >= t.ast.extra_data.items.len) return null;
    const body_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[class_extra + 2]);
    if (body_idx.isNone()) return null;

    // marker 검사를 먼저 — 없으면 early return (synthetic class_expression의 경우
    // getClassName이 string_table span을 source로 읽어 panic 유발하는 걸 방지).
    if (!hasWorkletClassMarker(t, body_idx)) return null;
    const class_name = getClassName(t, node) orelse return null;

    // __workletClass property를 strip한 새 body 생성 + default 방문 수행.
    const stripped_body = try stripWorkletClassMarker(t, body_idx);
    // 원본 class extra를 복사하여 body만 교체한 새 class 노드.
    const none = @intFromEnum(NodeIndex.none);
    const new_name_idx = t.ast.extra_data.items[class_extra];
    const new_super_idx = t.ast.extra_data.items[class_extra + 1];
    const deco_start = t.ast.extra_data.items[class_extra + 6];
    const deco_len = t.ast.extra_data.items[class_extra + 7];
    const new_class = try t.addExtraNode(node.tag, node.span, &.{
        new_name_idx, new_super_idx, @intFromEnum(stripped_body),
        none,         0,             0,
        deco_start,   deco_len,
    });
    // visit은 skip (default 경로가 __workletClass 필드 없는 상태로 이미 완료).
    // Trailing: `Foo.Foo__classFactory = <worklet IIFE>`
    const factory_stmt = try buildClassFactoryAssignment(t, class_name, stripped_body);
    // pending_nodes 또는 trailing_nodes에 추가해야 program/block이 반영.
    try t.trailing_nodes.append(t.allocator, factory_stmt);
    return new_class;
}

fn getClassName(t: *Transformer, node: Node) ?[]const u8 {
    const e = node.data.extra;
    const name_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[e]);
    if (name_idx.isNone()) return null;
    const name_node = t.ast.getNode(name_idx);
    if (name_node.tag != .binding_identifier) return null;
    return t.ast.source[name_node.span.start..name_node.span.end];
}

fn hasWorkletClassMarker(t: *Transformer, body_idx: NodeIndex) bool {
    const body = t.ast.getNode(body_idx);
    if (body.tag != .class_body) return false;
    const ls = body.data.list.start;
    const ll = body.data.list.len;
    var i: u32 = 0;
    while (i < ll) : (i += 1) {
        const m: NodeIndex = @enumFromInt(t.ast.extra_data.items[ls + i]);
        if (m.isNone()) continue;
        const mn = t.ast.getNode(m);
        if (mn.tag != .property_definition) continue;
        const me = mn.data.extra;
        if (me >= t.ast.extra_data.items.len) continue;
        const key_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[me]);
        if (key_idx.isNone()) continue;
        const key = t.ast.getNode(key_idx);
        if (key.tag != .identifier_reference) continue;
        const name = t.ast.source[key.span.start..key.span.end];
        if (std.mem.eql(u8, name, "__workletClass")) return true;
    }
    return false;
}

fn stripWorkletClassMarker(t: *Transformer, body_idx: NodeIndex) !NodeIndex {
    const body = t.ast.getNode(body_idx);
    const ls = body.data.list.start;
    const ll = body.data.list.len;

    const top = t.scratch.items.len;
    defer t.scratch.shrinkRetainingCapacity(top);

    var i: u32 = 0;
    while (i < ll) : (i += 1) {
        const m: NodeIndex = @enumFromInt(t.ast.extra_data.items[ls + i]);
        if (m.isNone()) continue;
        const mn = t.ast.getNode(m);
        var is_marker = false;
        if (mn.tag == .property_definition) {
            const me = mn.data.extra;
            if (me < t.ast.extra_data.items.len) {
                const key_idx: NodeIndex = @enumFromInt(t.ast.extra_data.items[me]);
                if (!key_idx.isNone()) {
                    const key = t.ast.getNode(key_idx);
                    if (key.tag == .identifier_reference) {
                        const name = t.ast.source[key.span.start..key.span.end];
                        is_marker = std.mem.eql(u8, name, "__workletClass");
                    }
                }
            }
        }
        if (!is_marker) try t.scratch.append(t.allocator, m);
    }

    const new_list = try t.ast.addNodeList(t.scratch.items[top..]);
    return t.ast.addNode(.{ .tag = .class_body, .span = body.span, .data = .{ .list = new_list } });
}

/// Class factory body — `{ 'worklet'; var <Class> = class { stripped_body }; return <Class>; }`
/// factory 호출 시 UI 스레드에서 클래스를 재생성해 반환 (runtime 정확성).
fn buildClassFactoryBody(t: *Transformer, class_name_span: Span, stripped_body: NodeIndex) !NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };
    const none = @intFromEnum(NodeIndex.none);

    const class_binding = try t.ast.addNode(.{
        .tag = .binding_identifier,
        .span = class_name_span,
        .data = .{ .string_ref = class_name_span },
    });
    const class_expr = try t.addExtraNode(.class_expression, zero_span, &.{
        @intFromEnum(class_binding), none, @intFromEnum(stripped_body),
        none,                        0,    0,
        0,                           0,
    });
    // var <Class> = class_expr;
    const declarator = try t.addExtraNode(.variable_declarator, zero_span, &.{
        @intFromEnum(class_binding), none, @intFromEnum(class_expr),
    });
    const decl_list = try t.ast.addNodeList(&.{declarator});
    const var_decl = try t.addExtraNode(.variable_declaration, zero_span, &.{
        0, // var
        decl_list.start,
        decl_list.len,
    });
    const return_ref = try t.ast.addNode(.{
        .tag = .identifier_reference,
        .span = class_name_span,
        .data = .{ .string_ref = class_name_span },
    });
    return buildWorkletReturnBlock(t, return_ref, &.{var_decl});
}

/// 생성. plugin의 onFunction이 자동으로 함수를 worklet으로 변환.
/// stripped_body: `__workletClass` 마커 제거된 class_body (factory가 클래스 재생성에 사용).
fn buildClassFactoryAssignment(t: *Transformer, class_name: []const u8, stripped_body: NodeIndex) !NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // factory 이름: `<ClassName>__classFactory`
    var factory_name_buf: [128]u8 = undefined;
    const factory_name = std.fmt.bufPrint(&factory_name_buf, "{s}__classFactory", .{class_name}) catch return error.OutOfMemory;
    const factory_name_span = try t.ast.addString(factory_name);
    const class_name_span = try t.ast.addString(class_name);

    const binding_node = try t.ast.addNode(.{
        .tag = .binding_identifier,
        .span = factory_name_span,
        .data = .{ .string_ref = factory_name_span },
    });
    const body = try buildClassFactoryBody(t, class_name_span, stripped_body);
    const empty_params = try t.ast.addNodeList(&.{});
    const empty_params_node = try t.ast.addFormalParameters(empty_params, zero_span);
    const none = @intFromEnum(NodeIndex.none);
    const inner_fn = try t.addExtraNode(.function_declaration, zero_span, &.{
        @intFromEnum(binding_node), @intFromEnum(empty_params_node),
        @intFromEnum(body),         0,                  none,
    });

    // IIFE: (function() { function <fn>(){...} return <fn>; })()
    const fn_ref = try t.ast.addNode(.{
        .tag = .identifier_reference,
        .span = factory_name_span,
        .data = .{ .string_ref = factory_name_span },
    });
    const ret_stmt = try t.ast.addNode(.{
        .tag = .return_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = fn_ref, .flags = 0 } },
    });
    const iife_body_list = try t.ast.addNodeList(&.{ inner_fn, ret_stmt });
    const iife_body = try t.ast.addNode(.{ .tag = .block_statement, .span = zero_span, .data = .{ .list = iife_body_list } });
    const wrapper_fn = try t.addExtraNode(.function_expression, zero_span, &.{
        none, @intFromEnum(empty_params_node), @intFromEnum(iife_body), 0, none,
    });
    const call_args = try t.ast.addNodeList(&.{});
    const call_extra = try t.ast.addExtras(&.{ @intFromEnum(wrapper_fn), call_args.start, call_args.len, 0 });
    const iife = try t.ast.addNode(.{ .tag = .call_expression, .span = zero_span, .data = .{ .extra = call_extra } });

    // visit을 돌려 plugin의 onFunction이 IIFE 내부 function_declaration을 worklet화하도록.
    // Fast Refresh 등록은 억제: IIFE 내부 factory는 최상위 바인딩이 아니라 `_cN = <name>`가 ReferenceError.
    const visited_iife = try t.visitWithRefreshSuppressed(iife);

    // LHS: ClassName.ClassName__classFactory
    const obj_ref = try t.ast.addNode(.{
        .tag = .identifier_reference,
        .span = class_name_span,
        .data = .{ .string_ref = class_name_span },
    });
    const prop_ref = try t.ast.addNode(.{
        .tag = .identifier_reference,
        .span = factory_name_span,
        .data = .{ .string_ref = factory_name_span },
    });
    const member = try t.addExtraNode(.static_member_expression, zero_span, &.{
        @intFromEnum(obj_ref), @intFromEnum(prop_ref), 0,
    });
    // assignment_expression: binary = { left, right, flags }
    const assign = try t.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = member, .right = visited_iife, .flags = 0 } },
    });
    return t.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
    });
}

// `buildWorkletContextStubBody` 재사용 (동일한 `'worklet'; return null;` body).

/// 파일 경로에서 마지막 segment를 추출 후 alphanumeric만 남겨 worklet 이름에 사용.
/// `/foo/App.tsx` → `AppTsx`, `/dev/null` → `null`. Babel의 makeWorkletName과 유사.
/// caller가 buffer 제공 — race-free, 호출간 결과 보존.
fn sanitizeFilename(path: []const u8, buf: []u8) []const u8 {
    if (path.len == 0) return "anon";
    var start: usize = 0;
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '/' or path[i - 1] == '\\') {
            start = i;
            break;
        }
    }
    const basename = path[start..];
    var len: usize = 0;
    for (basename) |ch| {
        if (len >= buf.len) break;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9')) {
            buf[len] = ch;
            len += 1;
        }
    }
    if (len == 0) return "anon";
    return buf[0..len];
}
