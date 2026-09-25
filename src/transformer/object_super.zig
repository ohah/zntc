//! 객체 리터럴 메서드의 `super` 낮추기 — home object 임시 변수 (#4729).
//!
//! 스펙상 객체 리터럴 메서드의 `super.x` 는 **그 메서드가 정의된 객체**(home object)의
//! [[Prototype]] 에서 찾는다. 메서드를 그대로 두는 타겟에선 native `super` 가 알아서
//! 처리하지만, 다음 경우엔 `super` 를 쓸 수 없는 자리로 옮겨지므로 직접 낮춰야 한다.
//!   - es5: 메서드 자체가 `key: function() {}` 로 바뀐다 (또는 class lowering 타겟이라
//!     getter/setter 안 `super` 도 낮춘다).
//!   - async/generator 를 낮추는 타겟: 본문이 `__async(this, arguments, function*(){…})`
//!     같은 일반 함수로 옮겨진다.
//!
//! 방식: 객체를 임시 변수에 담고(`_obj = { … }`) 메서드 안 `super` 의 기준을
//! `Object.getPrototypeOf(_obj)` 로 낮춘다. 호출 시점에 프로토타입을 읽으므로 나중에
//! `Object.setPrototypeOf` 로 바꿔도 따라간다.
//!
//! 임시 변수는 **객체가 평가될 때마다** 새로 생겨야 한다 — 루프 안 객체들이 한 변수를
//! 공유하면 먼저 만든 객체의 메서드가 나중 객체의 프로토타입을 본다. 그래서:
//!   - arrow 가 네이티브인 타겟: `((_obj) => _obj = { … })()` — 파라미터라 평가마다 새
//!     바인딩이다. arrow 라 `this`/`arguments`/`super` 도 그대로다.
//!   - es5: `(function (_obj) { return _obj = { … }; })()`. 일반 함수라 값 자리의
//!     `this`/`arguments`/`super`/`new.target` 이 바뀌므로, 그런 게 없을 때만 쓴다.
//!   - 값 자리에 `yield`/`await` 가 있거나(감싸면 깨짐) es5 에서 위 문맥을 쓰면 함수 단위
//!     `var` 임시 변수로 돌아간다. 이때는 클로저가 캡처하는 루프 본문이 `_loop` 으로
//!     추출되며 그 안에 선언돼 반복마다 새로 생기고, 추출되지 않는 루프에서만 공유된다.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const es_helpers = @import("es_helpers.zig");
const members = @import("transformer/members.zig");

/// 이 메서드 안의 `super` 가 이번 타겟에서 native 로 남지 못하는지.
fn superMustBeLowered(self: *const Transformer, flags: u32) bool {
    const u = self.options.unsupported;
    if (u.class or u.object_extensions) return true;
    return members.methodNeedsAsyncOrGeneratorLowering(self, flags);
}

/// 메서드의 params/body 에 이 메서드를 home 으로 하는 `super` 가 있는지.
/// 일반 함수·클래스·다른 메서드는 경계 — 그 안의 `super` 는 다른 home 을 가진다(일반
/// 함수 안에선 애초에 문법 오류). arrow 는 경계가 아니다.
fn methodUsesSuper(self: *Transformer, method: Node) bool {
    const e = method.data.extra;
    var found = false;
    const roots = [_]NodeIndex{
        self.readNodeIdx(e, ast_mod.MethodExtra.params),
        self.readNodeIdx(e, ast_mod.MethodExtra.body),
    };
    for (roots) |r| {
        if (r.isNone()) continue;
        // OOM 이면 보수적으로 "쓴다" — home 을 배정해도 결과는 맞다.
        ast_walk.walkPreorderIterative(self.allocator, self.ast, r, &found, superVisit) catch return true;
        if (found) return true;
    }
    return false;
}

fn superVisit(found: *bool, _: NodeIndex, node: Node) ast_walk.WalkAction {
    switch (node.tag) {
        .super_expression => {
            found.* = true;
            return .stop;
        },
        .function_declaration,
        .function_expression,
        .function,
        .class_declaration,
        .class_expression,
        .method_definition,
        => return .skip_children,
        else => return .descend,
    }
}

pub const Home = struct {
    span: Span,
    wrap: Wrap,

    pub const Wrap = enum {
        /// `_a = obj` — 함수 단위 `var` 임시 변수.
        assign,
        /// `((home) => home = obj)()` — home 은 arrow 파라미터.
        arrow,
        /// `(function (home) { return home = obj; })()` — es5.
        function,
    };
};

/// 객체의 값 자리(메서드 본문 밖)에서 감싸는 함수가 바꿔 버릴 문맥을 쓰는지.
/// arrow 는 투명(같은 문맥), 일반 함수는 경계. 클래스·중첩 메서드는 보수적으로 들여다본다.
fn valuesUseFunctionContext(self: *Transformer, node: Node) bool {
    var ctx: ContextScan = .{ .ast = self.ast };
    const list = node.data.list;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const m_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        if (m_idx.isNone()) continue;
        const m = self.ast.getNode(m_idx);
        const target = if (m.tag == .method_definition) self.readNodeIdx(m.data.extra, ast_mod.MethodExtra.key) else m_idx;
        if (target.isNone()) continue;
        // OOM 이면 보수적으로 "쓴다" — 함수로 감싸지 않고 임시 변수로 돌아갈 뿐이다.
        ast_walk.walkPreorderIterative(self.allocator, self.ast, target, &ctx, contextVisit) catch return true;
        if (ctx.found) return true;
    }
    return false;
}

const ContextScan = struct {
    ast: *const ast_mod.Ast,
    found: bool = false,
};

fn contextVisit(ctx: *ContextScan, _: NodeIndex, n: Node) ast_walk.WalkAction {
    switch (n.tag) {
        .this_expression, .super_expression, .meta_property, .yield_expression, .await_expression => {
            ctx.found = true;
            return .stop;
        },
        .identifier_reference => {
            if (std.mem.eql(u8, ctx.ast.getText(n.data.string_ref), "arguments")) {
                ctx.found = true;
                return .stop;
            }
            return .descend;
        },
        .function_declaration, .function_expression, .function => return .skip_children,
        else => return .descend,
    }
}

/// 객체의 값 자리(메서드 본문 밖)에 `yield`/`await` 가 있는지 — arrow 로 감싸면 깨진다.
/// 메서드는 계산된 키만 본다(본문은 자기 함수라 무관).
fn valuesYieldOrAwait(self: *Transformer, node: Node) bool {
    const scan = @import("es2015_generator/scan.zig");
    const list = node.data.list;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const m_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        if (m_idx.isNone()) continue;
        const m = self.ast.getNode(m_idx);
        const target = if (m.tag == .method_definition) self.readNodeIdx(m.data.extra, ast_mod.MethodExtra.key) else m_idx;
        if (scan.containsYield(self, target)) return true;
    }
    return false;
}

fn allocHome(self: *Transformer, node: Node) Transformer.Error!Home {
    const wrap: Home.Wrap = if (!self.options.unsupported.arrow)
        (if (valuesYieldOrAwait(self, node)) .assign else .arrow)
    else if (valuesUseFunctionContext(self, node)) .assign else .function;
    if (wrap != .assign) {
        // 함수 파라미터 — 함수 단위 temp 카운터를 쓰지 않는다(var 로 호이스팅되면 안 됨).
        const prefix = "_obj";
        while (true) {
            const name = try self.buildUniqueName(prefix, &self.object_home_counter);
            defer if (name.ptr != prefix.ptr) self.allocator.free(name);
            // 사용자 식별자를 가리면 값 자리의 `_obj` 참조가 파라미터로 바뀐다.
            if (es_helpers.nameAppearsInSource(self, name)) continue;
            return .{ .span = try self.ast.addString(name), .wrap = wrap };
        }
    }
    return .{ .span = try es_helpers.makeTempVarSpan(self), .wrap = .assign };
}

/// 객체 리터럴 방문 전에 호출. home 이 필요한 메서드가 있으면 임시 변수를 만들어
/// 그 메서드들을 등록하고 돌려준다. 호출자는 방문 결과를 `wrapWithHome` 으로 감싸고,
/// 끝나면 `release(mark)` 로 등록을 되돌린다.
pub fn prepareHome(self: *Transformer, node: Node) Transformer.Error!?Home {
    const list = node.data.list;
    var home: ?Home = null;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const m_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        if (m_idx.isNone()) continue;
        const m = self.ast.getNode(m_idx);
        if (m.tag != .method_definition) continue;
        const flags = self.readU32(m.data.extra, ast_mod.MethodExtra.flags);
        if (!superMustBeLowered(self, flags)) continue;
        if (!methodUsesSuper(self, m)) continue;
        if (home == null) home = try allocHome(self, node);
        try self.object_super_homes.append(self.allocator, .{ .method_extra = m.data.extra, .home = home.?.span });
    }
    return home;
}

pub fn release(self: *Transformer, mark: usize) void {
    self.object_super_homes.shrinkRetainingCapacity(mark);
}

/// 이 method_definition(extra 인덱스)에 배정된 home 임시 변수.
pub fn lookup(self: *const Transformer, method_extra: u32) ?Span {
    var i = self.object_super_homes.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.object_super_homes.items[i];
        if (entry.method_extra == method_extra) return entry.home;
    }
    return null;
}

/// 객체 리터럴 방문 결과를 home 에 담는다 — `Home.Wrap` 참고.
pub fn wrapWithHome(self: *Transformer, home: Home, obj: NodeIndex, span: Span) Transformer.Error!NodeIndex {
    const assign = try self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{
        .left = try es_helpers.makeTempVarRef(self, home.span, home.span),
        .right = obj,
        .flags = 0,
    } } });
    if (home.wrap == .assign) return assign;

    const param_binding = try es_helpers.makeSyntheticBinding(self, home.span);
    const none = @intFromEnum(NodeIndex.none);
    const formal = try self.ast.addNode(.{
        .tag = .formal_parameter,
        .span = span,
        // extras = [pattern, type_ann, default, flags, deco_start, deco_len] — deco_len 은 0.
        .data = .{ .extra = try self.ast.addExtras(&.{ @intFromEnum(param_binding), none, none, 0, 0, 0 }) },
    });
    const params = try self.ast.addFormalParameters(try self.ast.addNodeList(&.{formal}), span);
    const callee = switch (home.wrap) {
        .assign => unreachable,
        .arrow => try self.ast.addNode(.{ .tag = .arrow_function_expression, .span = span, .data = .{
            .extra = try self.ast.addExtras(&.{ @intFromEnum(params), @intFromEnum(assign), 0 }),
        } }),
        .function => blk: {
            const ret = try self.ast.addNode(.{ .tag = .return_statement, .span = span, .data = .{ .unary = .{ .operand = assign, .flags = 0 } } });
            const body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{ret}) } });
            break :blk try self.ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{
                .extra = try self.ast.addExtras(&.{ none, @intFromEnum(params), @intFromEnum(body), 0, none }),
            } });
        },
    };
    return es_helpers.makeCallExpr(self, callee, &.{}, span);
}

pub const Saved = struct {
    home: ?Span,
    class: ?Span,
    class_old_idx: NodeIndex,
    is_static: bool,
    static_receiver: ?Span,
    in_extracted_fn: bool,
    via_proto_chain: bool,
    this_alias: bool,
};

/// 메서드 본문 진입. `home` 이 있으면(객체 리터럴이 배정) 그 메서드의 `super` 는 home
/// 기준이고, 바깥 클래스의 super 문맥은 전부 끊는다 — 남겨 두면 es5 에서 바깥 클래스의
/// 부모가 기준이 된다. 없으면(클래스 메서드, super 없는 객체 메서드) 바깥 home 만 끊는다.
pub fn enterMethod(self: *Transformer, home: ?Span) Saved {
    const saved: Saved = .{
        .home = self.current_super_home_object,
        .class = self.current_super_class,
        .class_old_idx = self.current_super_class_old_idx,
        .is_static = self.current_super_is_static,
        .static_receiver = self.current_super_static_receiver,
        .in_extracted_fn = self.current_super_in_extracted_fn,
        .via_proto_chain = self.current_super_via_proto_chain,
        .this_alias = self.super_call_this_alias,
    };
    self.current_super_home_object = home;
    if (home != null) {
        self.current_super_class = null;
        self.current_super_class_old_idx = .none;
        self.current_super_is_static = false;
        self.current_super_static_receiver = null;
        self.current_super_in_extracted_fn = false;
        self.current_super_via_proto_chain = false;
        self.super_call_this_alias = false;
    }
    return saved;
}

pub fn leaveMethod(self: *Transformer, saved: Saved) void {
    self.current_super_home_object = saved.home;
    self.current_super_class = saved.class;
    self.current_super_class_old_idx = saved.class_old_idx;
    self.current_super_is_static = saved.is_static;
    self.current_super_static_receiver = saved.static_receiver;
    self.current_super_in_extracted_fn = saved.in_extracted_fn;
    self.current_super_via_proto_chain = saved.via_proto_chain;
    self.super_call_this_alias = saved.this_alias;
}

/// `Object.getPrototypeOf(<home>)` — 호출 시점의 home object 프로토타입.
pub fn buildHomeProto(self: *Transformer, home: Span, span: Span) Transformer.Error!NodeIndex {
    const object_ref = try es_helpers.makeGlobalRef(self, "Object");
    const get_proto = try es_helpers.makePropertyName(self, "getPrototypeOf");
    const callee = try es_helpers.makeStaticMember(self, object_ref, get_proto, span);
    return es_helpers.makeCallExpr(self, callee, &.{try es_helpers.makeTempVarRef(self, home, home)}, span);
}
