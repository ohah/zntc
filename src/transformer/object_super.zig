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
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const ReferenceFlags = @import("../semantic/symbol.zig").ReferenceFlags;
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

/// ES2015 async-arrow lowering moves the arrow body into an ordinary generator.
/// A lexical `super` in that body must use the object method's home object too,
/// even when the containing method itself remains native.
fn hasDownleveledAsyncArrowSuper(self: *Transformer, method: Node) bool {
    if (!self.options.unsupported.async_await) return false;
    return scanMethodSuper(self, method, true);
}

/// 메서드의 params/body 에 이 메서드를 home 으로 하는 `super` 가 있는지.
/// 일반 함수·클래스·다른 메서드는 경계 — 그 안의 `super` 는 다른 home 을 가진다(일반
/// 함수 안에선 애초에 문법 오류). arrow 는 경계가 아니다.
fn methodUsesSuper(self: *Transformer, method: Node) bool {
    return scanMethodSuper(self, method, false);
}

/// `only_in_async_arrow` 면 async arrow 안의 `super` 만 센다. OOM 이면 보수적으로 "쓴다" —
/// home 을 배정해도 결과는 맞다.
fn scanMethodSuper(self: *Transformer, method: Node, only_in_async_arrow: bool) bool {
    const Work = struct {
        node: NodeIndex,
        inside_async_arrow: bool,
    };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    const e = method.data.extra;
    for ([_]NodeIndex{ self.readNodeIdx(e, ast_mod.MethodExtra.params), self.readNodeIdx(e, ast_mod.MethodExtra.body) }) |root|
        stack.append(self.allocator, .{ .node = root, .inside_async_arrow = false }) catch return true;

    while (stack.pop()) |work| {
        if (work.node.isNone() or @backingInt(work.node) >= self.ast.nodes.items.len) continue;
        const node = self.ast.getNode(work.node);
        if (node.tag == .super_expression and (work.inside_async_arrow or !only_in_async_arrow)) return true;
        switch (node.tag) {
            .function_declaration, .function_expression, .function => continue,
            // 경계지만 클래스 extends 식과 멤버·메서드의 계산된 키는 바깥에서 평가된다 —
            // 그 안의 `super` 는 이 메서드의 home 이다 (#4735).
            .class_declaration, .class_expression => {
                const ce = node.data.extra;
                stack.append(self.allocator, .{ .node = self.readNodeIdx(ce, ast_mod.ClassExtra.super), .inside_async_arrow = work.inside_async_arrow }) catch return true;
                const body = self.readNodeIdx(ce, ast_mod.ClassExtra.body);
                if (body.isNone() or self.ast.getNode(body).tag != .class_body) continue;
                var class_members = self.ast.iterateExtraList(self.ast.getNode(body).data.list);
                while (class_members.next()) |member| {
                    const member_node = self.ast.getNode(member);
                    switch (member_node.tag) {
                        .method_definition, .property_definition, .accessor_property => {},
                        else => continue,
                    }
                    const key = self.readNodeIdx(member_node.data.extra, 0);
                    if (key.isNone() or self.ast.getNode(key).tag != .computed_property_key) continue;
                    stack.append(self.allocator, .{ .node = key, .inside_async_arrow = work.inside_async_arrow }) catch return true;
                }
                continue;
            },
            .method_definition => {
                const key = self.readNodeIdx(node.data.extra, ast_mod.MethodExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key)
                    stack.append(self.allocator, .{ .node = key, .inside_async_arrow = work.inside_async_arrow }) catch return true;
                continue;
            },
            else => {},
        }
        const inside_async_arrow = work.inside_async_arrow or
            (node.tag == .arrow_function_expression and
                (self.readU32(node.data.extra, ast_mod.ArrowExtra.flags) & ast_mod.ArrowFlags.is_async) != 0);
        var children = ast_walk.children(self.ast, node);
        while (children.next()) |child| {
            stack.append(self.allocator, .{
                .node = child,
                .inside_async_arrow = inside_async_arrow,
            }) catch return true;
        }
    }
    return false;
}

pub const Home = struct {
    span: Span,
    wrap: Wrap,
    late_output_name: bool = false,
    temp_counter_index: ?u32 = null,

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
        const m_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
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
        const m_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
        if (m_idx.isNone()) continue;
        const m = self.ast.getNode(m_idx);
        const target = if (m.tag == .method_definition) self.readNodeIdx(m.data.extra, ast_mod.MethodExtra.key) else m_idx;
        if (scan.containsYield(self, target)) return true;
    }
    return false;
}

fn allocHome(self: *Transformer, node: Node, allow_late_output_name: bool) Transformer.Error!Home {
    const wrap: Home.Wrap = if (!self.options.unsupported.arrow)
        (if (valuesYieldOrAwait(self, node)) .assign else .arrow)
    else if (valuesUseFunctionContext(self, node)) .assign else .function;
    if (wrap != .assign) {
        // 함수 파라미터 — 함수 단위 temp 카운터를 쓰지 않는다(var 로 호이스팅되면 안 됨).
        const late_output_name = allow_late_output_name and
            (es_helpers.canUseLateStandaloneOutputName(self, self.current_scope) or
                es_helpers.canUseLateGraphOutputName(self, self.current_scope));
        const prefix = if (late_output_name) "__zntc_object_home" else "_obj";
        while (true) {
            const name = if (late_output_name)
                try self.buildUniqueName(prefix, &self.object_home_counter)
            else
                try self.buildUniqueNameAvoidingDynamicEval(prefix, &self.object_home_counter, self.current_scope);
            // 사용자 식별자를 가리면 값 자리의 `_obj` 참조가 파라미터로 바뀐다.
            if (try es_helpers.nameAppearsInSource(self, name)) continue;
            return .{ .span = try self.ast.addString(name), .wrap = wrap, .late_output_name = late_output_name };
        }
    }
    const span = try es_helpers.makeTempVarSpan(self);
    return .{ .span = span, .wrap = .assign, .temp_counter_index = self.temp_var_counter - 1 };
}

/// 객체 리터럴 방문 전에 호출. home 이 필요한 메서드가 있으면 임시 변수를 만들어
/// 그 메서드들을 등록하고 돌려준다. 호출자는 방문 결과를 `wrapWithHome` 으로 감싸고,
/// 끝나면 `release(mark)` 로 등록을 되돌린다.
pub fn prepareHome(self: *Transformer, node: Node, allow_late_output_name: bool) Transformer.Error!?Home {
    const list = node.data.list;
    var home: ?Home = null;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const m_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
        if (m_idx.isNone()) continue;
        const m = self.ast.getNode(m_idx);
        if (m.tag != .method_definition) continue;
        const flags = self.readU32(m.data.extra, ast_mod.MethodExtra.flags);
        if (!superMustBeLowered(self, flags) and !hasDownleveledAsyncArrowSuper(self, m)) continue;
        if (!methodUsesSuper(self, m)) continue;
        if (home == null) home = try allocHome(self, node, allow_late_output_name);
        try self.object_super_homes.append(self.allocator, .{ .method_extra = m.data.extra, .home = home.?.span });
    }
    return home;
}

pub fn release(self: *Transformer, mark: usize) void {
    var retained: usize = 0;
    for (self.object_super_home_references.items) |reference| {
        var released = false;
        for (self.object_super_homes.items[mark..]) |home| {
            if (sameSpan(home.home, reference.home)) {
                released = true;
                break;
            }
        }
        if (released) continue;
        self.object_super_home_references.items[retained] = reference;
        retained += 1;
    }
    self.object_super_home_references.shrinkRetainingCapacity(retained);
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
    if (home.wrap == .assign) {
        const parent_scope = homeObjectParentScope(self, obj, self.current_scope);
        if (self.semantic_edit_enabled) {
            if (parent_scope.isNone()) std.debug.panic("function-scoped object home temp has no output scope", .{});
            const parameter_output_scope = self.loweredParameterEnvironmentOutputScope(parent_scope);
            const output_scope = parameter_output_scope orelse parent_scope;
            const deferred_output_scope = parameter_output_scope == null and
                self.objectSuperTempOutputScopeIsDeferred(parent_scope);
            const callback_binding = if (deferred_output_scope and self.state_machine_depth > 0)
                try es_helpers.makeExactSyntheticBindingFromSpan(self, home.span)
            else
                .none;
            if (!callback_binding.isNone())
                try self.registerGeneratedCallbackTempBinding(
                    home.temp_counter_index orelse std.debug.panic("deferred object home has no allocator slot", .{}),
                    callback_binding,
                );
            const symbol_id: ?SymbolId = if (parameter_output_scope != null)
                (try self.reserveSyntheticTempSymbolInScope(home.span, span, output_scope)) orelse
                    std.debug.panic("lowered parameter object home temp has no SymbolId", .{})
            else if (deferred_output_scope)
                null
            else blk: {
                const owner_scope = self.nearestVarScope(output_scope);
                const binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, home.span);
                break :blk (try self.declareSyntheticTempInScope(binding, span, owner_scope)) orelse
                    std.debug.panic("function-scoped object home temp has no SymbolId", .{});
            };
            try trackHoistedHomeReferences(
                self,
                obj,
                self.ast.getNode(assign).data.binary.left,
                home.span,
                output_scope,
                symbol_id,
                callback_binding,
                if (parameter_output_scope != null and parameter_output_scope.? != parent_scope)
                    parent_scope
                else
                    .none,
            );
        }
        return assign;
    }

    const param_binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, home.span);
    const none = @backingInt(NodeIndex.none);
    const formal = try self.ast.addNode(.{
        .tag = .formal_parameter,
        .span = span,
        // extras = [pattern, type_ann, default, flags, deco_start, deco_len] — deco_len 은 0.
        .data = .{ .extra = try self.ast.addExtras(&.{ @backingInt(param_binding), none, none, 0, 0, 0 }) },
    });
    const params = try self.ast.addFormalParameters(try self.ast.addNodeList(&.{formal}), span);
    const callee = switch (home.wrap) {
        .assign => unreachable,
        .arrow => try self.ast.addNode(.{ .tag = .arrow_function_expression, .span = span, .data = .{
            .extra = try self.ast.addExtras(&.{ @backingInt(params), @backingInt(assign), 0 }),
        } }),
        .function => blk: {
            const ret = try self.ast.addNode(.{ .tag = .return_statement, .span = span, .data = .{ .unary = .{ .operand = assign, .flags = 0 } } });
            const body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{ret}) } });
            break :blk try self.ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{
                .extra = try self.ast.addExtras(&.{ none, @backingInt(params), @backingInt(body), 0, none }),
            } });
        },
    };
    const parent_scope = homeObjectParentScope(self, obj, self.current_scope);
    try bindWrappedHomeParameter(self, callee, param_binding, assign, home.span, parent_scope, home.late_output_name);
    return es_helpers.makeCallExpr(self, callee, &.{}, span);
}

/// Generator and async lowering can visit an object's value expressions while
/// the transform cursor is at an outer scope. The shallowest owned scope in
/// the emitted object still records the lexical scope that contains the
/// expression, so use its parent for the generated home wrapper.
fn homeObjectParentScope(self: *Transformer, root: NodeIndex, fallback: ScopeId) ScopeId {
    if (!self.semantic_edit_enabled or root.isNone()) return fallback;
    var queue: std.ArrayList(NodeIndex) = .empty;
    defer queue.deinit(self.allocator);
    queue.append(self.allocator, root) catch return fallback;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const node_idx = queue.items[cursor];
        if (node_idx.isNone() or @backingInt(node_idx) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(node_idx);
        if (seen.contains(raw)) continue;
        seen.put(self.allocator, raw, {}) catch return fallback;
        if (self.outputOwnedScope(node_idx)) |scope| {
            const parent = self.outputScopeParent(scope);
            if (!parent.isNone()) return parent;
        }
        var it = ast_walk.children(self.ast, self.ast.getNode(node_idx));
        while (it.next()) |child| queue.append(self.allocator, child) catch return fallback;
    }
    return fallback;
}

/// Function-scoped home temps use the normal exact-Span hoister. Record every
/// generated use with its output lexical scope so binding insertion can attach
/// it to the one declaration that owns this temp.
fn trackHoistedHomeReferences(
    self: *Transformer,
    root: NodeIndex,
    write_ref: NodeIndex,
    name_span: Span,
    root_scope: ScopeId,
    symbol_id: ?SymbolId,
    callback_binding: NodeIndex,
    reparent_from_scope: ScopeId,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled or root_scope.isNone()) return;
    var home_refs = try collectObjectSuperHomeReferences(self, name_span);
    defer home_refs.deinit(self.allocator);
    if (symbol_id) |id|
        try self.addSyntheticRefInScope(write_ref, id, root_scope, .{ .write = true })
    else if (!callback_binding.isNone())
        try self.trackGeneratedCallbackTempReference(callback_binding, write_ref, root_scope, .{ .write = true })
    else
        try self.trackHoistedTempRefInScope(name_span, write_ref, root_scope, .{ .write = true });
    const Work = struct { node: NodeIndex, scope: ScopeId };
    var queue: std.ArrayList(Work) = .empty;
    defer queue.deinit(self.allocator);
    try queue.append(self.allocator, .{ .node = root, .scope = root_scope });
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const work = queue.items[cursor];
        if (work.node.isNone() or @backingInt(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        const scope = self.outputOwnedScope(work.node) orelse work.scope;
        if (!reparent_from_scope.isNone() and !scope.isNone() and scope != root_scope and
            self.outputScopeParent(scope) == reparent_from_scope)
        {
            // A lowered default initializer now runs in the function body.
            // Its nested function/class scopes were parsed as siblings under
            // the parameter environment, so move those roots under the exact
            // body scope before attaching the home-temp references.
            try self.reparentGeneratedScope(scope, root_scope);
        }
        if (home_refs.fetchRemove(raw) != null) {
            if (symbol_id) |id|
                try self.addSyntheticRefInScope(work.node, id, scope, .{ .read = true })
            else if (!callback_binding.isNone())
                try self.trackGeneratedCallbackTempReference(callback_binding, work.node, scope, .{ .read = true })
            else
                try self.trackHoistedTempRefInScope(name_span, work.node, scope, .{ .read = true });
        }
        var it = ast_walk.children(self.ast, node);
        while (it.next()) |child| try queue.append(self.allocator, .{ .node = child, .scope = scope });
    }
    forgetObjectSuperHomeReferences(self, name_span);
}

/// Arrow/function home wrappers introduce a real parameter scope after their
/// contents were transformed. Move the scopes owned inside the wrapped object
/// under that scope, then attach the generated home binding and every exact
/// read/write in the wrapper tree.
fn bindWrappedHomeParameter(
    self: *Transformer,
    wrapper: NodeIndex,
    binding: NodeIndex,
    assignment: NodeIndex,
    name_span: Span,
    parent_scope: ScopeId,
    late_output_name: bool,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled or parent_scope.isNone()) return;
    const wrapper_scope = try self.addGeneratedFunctionScope(parent_scope, wrapper);
    if (wrapper_scope.isNone()) return;
    const id = (try self.declareSyntheticInScope(binding, self.ast.getNode(binding).span, .parameter, wrapper_scope)) orelse return;
    if (late_output_name) {
        if (es_helpers.canUseLateGraphOutputName(self, wrapper_scope)) {
            es_helpers.markLateGraphSyntheticSymbol(self, id, .object_super_home_binding, "_obj");
        } else if (es_helpers.canUseLateStandaloneOutputName(self, wrapper_scope)) {
            es_helpers.markStandaloneLateSyntheticOutputName(
                self,
                id,
                self.ast.getText(name_span),
                .object_super_home_binding,
                "_obj",
            );
        } else {
            std.debug.panic("late object-super home parameter lost its eligible scope", .{});
        }
    }
    const write_ref = self.ast.getNode(assignment).data.binary.left;
    var home_refs = try collectObjectSuperHomeReferences(self, name_span);
    defer home_refs.deinit(self.allocator);
    const Work = struct { node: NodeIndex, scope: ScopeId };
    var worklist: std.ArrayList(Work) = .empty;
    defer worklist.deinit(self.allocator);
    try worklist.append(self.allocator, .{ .node = wrapper, .scope = parent_scope });
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    var cursor: usize = 0;
    while (cursor < worklist.items.len) : (cursor += 1) {
        const work = worklist.items[cursor];
        if (work.node.isNone() or @backingInt(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        var scope = work.scope;
        if (self.outputOwnedScope(work.node)) |owned_scope| {
            scope = owned_scope;
            if (owned_scope != wrapper_scope) {
                const visible = if (self.semantic_editor) |*editor|
                    editor.symbolVisibleFrom(id, owned_scope)
                else
                    false;
                if (!visible) try self.reparentGeneratedScope(owned_scope, wrapper_scope);
            }
        }

        if (work.node == write_ref or home_refs.fetchRemove(raw) != null) {
            const flags: ReferenceFlags = if (work.node == write_ref) .{ .write = true } else .{ .read = true };
            try self.addSyntheticRefInScope(work.node, id, scope, flags);
        }
        var it = ast_walk.children(self.ast, node);
        while (it.next()) |child| try worklist.append(self.allocator, .{ .node = child, .scope = scope });
    }
    forgetObjectSuperHomeReferences(self, name_span);
}

fn sameSpan(a: Span, b: Span) bool {
    return a.start == b.start and a.end == b.end;
}

/// Home-prototype reads are recorded at their producer as exact NodeIndexes.
/// Build the short-lived set used while the final output scopes are resolved.
fn collectObjectSuperHomeReferences(
    self: *Transformer,
    home: Span,
) Transformer.Error!std.AutoHashMapUnmanaged(u32, void) {
    var nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    errdefer nodes.deinit(self.allocator);
    for (self.object_super_home_references.items) |reference| {
        if (!sameSpan(reference.home, home)) continue;
        try nodes.put(self.allocator, @backingInt(reference.node), {});
    }
    return nodes;
}

fn forgetObjectSuperHomeReferences(self: *Transformer, home: Span) void {
    var retained: usize = 0;
    for (self.object_super_home_references.items) |reference| {
        if (sameSpan(reference.home, home)) continue;
        self.object_super_home_references.items[retained] = reference;
        retained += 1;
    }
    self.object_super_home_references.shrinkRetainingCapacity(retained);
}

/// A generated `Object.getPrototypeOf(home)` read keeps the exact reference
/// node until its wrapper binding and output scope are known.
pub fn recordHomePrototypeReference(self: *Transformer, home: Span, node: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    try self.object_super_home_references.append(self.allocator, .{ .home = home, .node = node });
}

pub const Saved = struct {
    home: ?Span,
    class: ?Span,
    class_old_idx: NodeIndex,
    is_static: bool,
    static_receiver: ?Span,
    in_extracted_fn: bool,
    via_proto_chain: bool,
    proto_chain_symbol_id: ?SymbolId,
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
        .proto_chain_symbol_id = self.current_super_proto_chain_symbol_id,
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
        self.current_super_proto_chain_symbol_id = null;
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
    self.current_super_proto_chain_symbol_id = saved.proto_chain_symbol_id;
    self.super_call_this_alias = saved.this_alias;
}

/// `Object.getPrototypeOf(<home>)` — 호출 시점의 home object 프로토타입.
pub fn buildHomeProto(self: *Transformer, home: Span, span: Span) Transformer.Error!NodeIndex {
    const object_ref = try es_helpers.makeGlobalRef(self, "Object");
    const get_proto = try es_helpers.makePropertyName(self, "getPrototypeOf");
    const callee = try es_helpers.makeStaticMember(self, object_ref, get_proto, span);
    const home_ref = try es_helpers.makeTempVarRef(self, home, home);
    try recordHomePrototypeReference(self, home, home_ref);
    return es_helpers.makeCallExpr(self, callee, &.{home_ref}, span);
}
