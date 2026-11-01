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
//!   - es5: `(function (_obj) { return _obj = { … }; })()`. 값 자리가 함수 문맥을 쓰지
//!     않으면 이 래퍼를 쓴다. native parameter list 를 유지하는 중 `this` 는 `.call(this)` 로,
//!     `arguments` 는 원래 arguments 객체를 별도 매개변수로 넘겨 보존한다. 그 밖의 문맥은
//!     함수 단위 임시 변수로 돌아간다.
//!   - 값 자리에 `yield`/`await` 가 있으면(감싸면 깨짐) es5 에서 함수 단위
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
const ObjectSuperHomeIdentity = Transformer.ObjectSuperHomeIdentity;
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
    identity: ObjectSuperHomeIdentity,
    wrap: Wrap,
    late_output_name: bool = false,
    temp_counter_index: ?u32 = null,
    arguments_alias_span: ?Span = null,
    arguments_outer_ref: NodeIndex = .none,

    pub const Wrap = enum {
        /// `_a = obj` — 함수 단위 `var` 임시 변수.
        assign,
        /// `((home) => home = obj)()` — home 은 arrow 파라미터.
        arrow,
        /// `(function (home) { return home = obj; })()` — es5.
        function,
        /// `(function (home) { return home = obj; }).call(this)` — es5, `this` 만 사용.
        function_with_this,
        /// `(function (home, args) { return home = obj; })(arguments)` — lexical `arguments` 를 alias.
        function_with_arguments,
        /// `(function (home, args) { return home = obj; }).call(this, arguments)` — `this` 와 `arguments` 를 보존.
        function_with_this_and_arguments,
    };
};

const FunctionContextUse = struct {
    uses_this: bool = false,
    uses_arguments: bool = false,
    uses_other: bool = false,
};

fn argumentsReferenceBelongsToEnclosingScope(self: *Transformer, reference: NodeIndex, start_scope: ScopeId) bool {
    const raw_id = self.getSymbolIdAt(reference) orelse return true;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    if (raw_id >= symbols.len) return false;
    const binding_scope = symbols[raw_id].scope_id;
    var cursor = start_scope;
    var hops: usize = 0;
    while (!cursor.isNone() and hops < scopes.len) : (hops += 1) {
        if (cursor.toIndex() >= scopes.len) return false;
        if (cursor == binding_scope) return true;
        cursor = scopes[cursor.toIndex()].parent;
    }
    return false;
}

/// 객체의 값 자리(메서드 본문 밖)에서 감싸는 함수가 바꿔 버릴 문맥을 쓰는지.
/// arrow 는 투명(같은 문맥), 일반 함수는 경계. 클래스·중첩 메서드는 보수적으로 들여다본다.
fn valuesFunctionContextUse(self: *Transformer, node: Node) FunctionContextUse {
    const ContextWork = struct { node: NodeIndex, parent_tag: ?ast_mod.Node.Tag = null };
    var ctx = FunctionContextUse{};
    var stack: std.ArrayList(ContextWork) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);

    const list = node.data.list;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const m_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list.start + i]));
        if (m_idx.isNone()) continue;
        const m = self.ast.getNode(m_idx);
        if (m.tag == .method_definition) {
            const key = self.readNodeIdx(m.data.extra, ast_mod.MethodExtra.key);
            if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key)
                stack.append(self.allocator, .{ .node = key }) catch return .{ .uses_other = true };
        } else {
            stack.append(self.allocator, .{ .node = m_idx }) catch return .{ .uses_other = true };
        }
    }

    while (stack.pop()) |work| {
        if (work.node.isNone() or @backingInt(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(work.node);
        if (seen.contains(raw)) continue;
        seen.put(self.allocator, raw, {}) catch return .{ .uses_other = true };
        const current = self.ast.getNode(work.node);
        switch (current.tag) {
            .function_declaration, .function_expression, .function => continue,
            .method_definition => {
                const key = self.readNodeIdx(current.data.extra, ast_mod.MethodExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key)
                    stack.append(self.allocator, .{ .node = key }) catch return .{ .uses_other = true };
                continue;
            },
            .this_expression => ctx.uses_this = true,
            .super_expression, .meta_property, .yield_expression, .await_expression => {
                ctx.uses_other = true;
                return ctx;
            },
            .identifier_reference => if (std.mem.eql(u8, self.ast.getText(current.data.string_ref), "arguments") and
                argumentsReferenceBelongsToEnclosingScope(self, work.node, self.current_scope))
            {
                if (work.parent_tag == .update_expression or work.parent_tag == .unary_expression) {
                    ctx.uses_other = true;
                    return ctx;
                }
                ctx.uses_arguments = true;
            },
            .assignment_target_identifier => if (std.mem.eql(u8, self.ast.getText(current.data.string_ref), "arguments") and
                argumentsReferenceBelongsToEnclosingScope(self, work.node, self.current_scope))
            {
                ctx.uses_other = true;
                return ctx;
            },
            else => {},
        }

        var children = ast_walk.children(self.ast, current);
        while (children.next()) |child| {
            stack.append(self.allocator, .{ .node = child, .parent_tag = current.tag }) catch return .{ .uses_other = true };
        }
    }
    return ctx;
}

fn valuesHaveDynamicLookup(self: *Transformer, root: NodeIndex) bool {
    const parameter_environment = @import("parameter_environment.zig");
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);

    const root_node = self.ast.getNode(root);
    if (root_node.tag == .object_expression) {
        const list = root_node.data.list;
        for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
            const member: NodeIndex = @fromBackingInt(@intCast(raw));
            if (member.isNone()) continue;
            const member_node = self.ast.getNode(member);
            if (member_node.tag == .method_definition) {
                const key = self.readNodeIdx(member_node.data.extra, ast_mod.MethodExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key)
                    stack.append(self.allocator, key) catch return true;
            } else {
                stack.append(self.allocator, member) catch return true;
            }
        }
    } else {
        stack.append(self.allocator, root) catch return true;
    }

    while (stack.pop()) |current| {
        if (current.isNone() or @backingInt(current) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(current);
        if (seen.contains(raw)) continue;
        seen.put(self.allocator, raw, {}) catch return true;
        const node = self.ast.getNode(current);
        switch (node.tag) {
            .function_declaration, .function_expression, .function => continue,
            .method_definition => {
                const key = self.readNodeIdx(node.data.extra, ast_mod.MethodExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key)
                    stack.append(self.allocator, key) catch return true;
                continue;
            },
            .with_statement => return true,
            .call_expression => if (parameter_environment.nodeHasDynamicLookup(self, current) catch true) {
                return true;
            },
            else => {},
        }
        var children = ast_walk.children(self.ast, node);
        while (children.next()) |child| stack.append(self.allocator, child) catch return true;
    }
    return false;
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

fn uniqueHomeCaptureName(self: *Transformer, prefix: []const u8) Transformer.Error!Span {
    while (true) {
        const name = try self.buildUniqueNameAvoidingDynamicEval(prefix, &self.object_home_counter, self.current_scope);
        if (try es_helpers.nameAppearsInSource(self, name)) continue;
        return self.ast.addString(name);
    }
}

fn allocHome(self: *Transformer, producer_node: NodeIndex, node: Node, allow_late_output_name: bool) Transformer.Error!Home {
    var arguments_alias_span: ?Span = null;
    const wrap: Home.Wrap = if (!self.options.unsupported.arrow)
        (if (valuesYieldOrAwait(self, node)) .assign else .arrow)
    else blk: {
        if (valuesYieldOrAwait(self, node)) break :blk .assign;
        const context_use = valuesFunctionContextUse(self, node);
        if (context_use.uses_other) break :blk .assign;
        if (context_use.uses_arguments) {
            if (!self.native_parameter_list_retained_for_dynamic_lookup) break :blk .assign;
            // A direct eval / with in the value would observe the wrapper's
            // lexical environment. Keep those expressions in their source frame.
            if (valuesHaveDynamicLookup(self, producer_node)) break :blk .assign;
            arguments_alias_span = try uniqueHomeCaptureName(self, "_args");
            break :blk if (context_use.uses_this)
                .function_with_this_and_arguments
            else
                .function_with_arguments;
        }
        if (context_use.uses_this) break :blk if (self.native_parameter_list_retained_for_dynamic_lookup)
            .function_with_this
        else
            .assign;
        break :blk .function;
    };
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
            return .{
                .identity = .{ .producer_node = producer_node, .span = try self.ast.addString(name) },
                .wrap = wrap,
                .late_output_name = late_output_name,
                .arguments_alias_span = arguments_alias_span,
            };
        }
    }
    const span = try es_helpers.makeTempVarSpan(self);
    return .{
        .identity = .{ .producer_node = producer_node, .span = span },
        .wrap = .assign,
        .temp_counter_index = self.temp_var_counter - 1,
    };
}

/// 객체 리터럴 방문 전에 호출. home 이 필요한 메서드가 있으면 임시 변수를 만들어
/// 그 메서드들을 등록하고 돌려준다. 호출자는 방문 결과를 `wrapWithHome` 으로 감싸고,
/// 끝나면 `release(mark)` 로 등록을 되돌린다.
pub fn prepareHome(self: *Transformer, producer_node: NodeIndex, allow_late_output_name: bool) Transformer.Error!?Home {
    const node = self.ast.getNode(producer_node);
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
        if (home == null) {
            var created = try allocHome(self, producer_node, node, allow_late_output_name);
            if (created.arguments_alias_span) |alias_span| {
                var arguments_refs: std.ArrayList(NodeIndex) = .empty;
                defer arguments_refs.deinit(self.allocator);
                try collectLexicalArgumentsReferences(self, producer_node, &arguments_refs);
                if (arguments_refs.items.len == 0)
                    std.debug.panic("object-super arguments wrapper has no source arguments references", .{});
                const parent_scope = homeObjectWrapperParentScope(self, producer_node, self.current_scope);
                const arguments_origin = arguments_refs.items[0];
                created.arguments_outer_ref = if (self.getSymbolIdAt(arguments_origin) != null)
                    try self.makeUserRefNamedAtScope("arguments", arguments_origin, parent_scope)
                else
                    try es_helpers.makeGlobalRef(self, "arguments");
                for (arguments_refs.items) |ref| {
                    try self.removeSemanticReference(ref);
                    self.ast.nodes.items[@backingInt(ref)].data.string_ref = alias_span;
                }
            }
            home = created;
        }
        try self.object_super_homes.append(self.allocator, .{ .method_extra = m.data.extra, .identity = home.?.identity });
    }
    return home;
}

pub fn release(self: *Transformer, mark: usize) void {
    var retained: usize = 0;
    for (self.object_super_home_references.items) |reference| {
        var released = false;
        for (self.object_super_homes.items[mark..]) |home| {
            if (home.identity.producer_node == reference.producer_node) {
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
pub fn lookup(self: *const Transformer, method_extra: u32) ?ObjectSuperHomeIdentity {
    var i = self.object_super_homes.items.len;
    while (i > 0) {
        i -= 1;
        const entry = self.object_super_homes.items[i];
        if (entry.method_extra == method_extra) return entry.identity;
    }
    return null;
}

fn collectLexicalArgumentsReferences(
    self: *Transformer,
    root: NodeIndex,
    references: *std.ArrayList(NodeIndex),
) Transformer.Error!void {
    const Work = struct { node: NodeIndex, parent_tag: ?ast_mod.Node.Tag = null };
    var stack: std.ArrayList(Work) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);

    const root_node = self.ast.getNode(root);
    if (root_node.tag == .object_expression) {
        const list = root_node.data.list;
        for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
            const member: NodeIndex = @fromBackingInt(@intCast(raw));
            if (member.isNone()) continue;
            const member_node = self.ast.getNode(member);
            if (member_node.tag == .method_definition) {
                const key = self.readNodeIdx(member_node.data.extra, ast_mod.MethodExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key)
                    try stack.append(self.allocator, .{ .node = key });
            } else {
                try stack.append(self.allocator, .{ .node = member });
            }
        }
    } else {
        try stack.append(self.allocator, .{ .node = root });
    }

    while (stack.pop()) |work| {
        if (work.node.isNone() or @backingInt(work.node) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(work.node);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(work.node);
        switch (node.tag) {
            .function_declaration, .function_expression, .function => continue,
            .method_definition => {
                const key = self.readNodeIdx(node.data.extra, ast_mod.MethodExtra.key);
                if (!key.isNone() and self.ast.getNode(key).tag == .computed_property_key)
                    try stack.append(self.allocator, .{ .node = key });
                continue;
            },
            .identifier_reference => {
                if (std.mem.eql(u8, self.ast.getText(node.data.string_ref), "arguments") and
                    argumentsReferenceBelongsToEnclosingScope(self, work.node, self.current_scope))
                {
                    if (work.parent_tag == .update_expression or work.parent_tag == .unary_expression)
                        continue;
                    try references.append(self.allocator, work.node);
                }
            },
            else => {},
        }

        var children = ast_walk.children(self.ast, node);
        while (children.next()) |child| {
            try stack.append(self.allocator, .{ .node = child, .parent_tag = node.tag });
        }
    }
}

fn collectHomeArgumentsAliasReferences(
    self: *Transformer,
    root: NodeIndex,
    alias_span: Span,
    references: *std.ArrayList(NodeIndex),
) Transformer.Error!void {
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    try stack.append(self.allocator, root);

    const alias_name = self.ast.getText(alias_span);
    while (stack.pop()) |current| {
        if (current.isNone() or @backingInt(current) >= self.ast.nodes.items.len) continue;
        const raw = @backingInt(current);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(current);
        if (node.tag == .identifier_reference and
            std.mem.eql(u8, self.ast.getText(node.data.string_ref), alias_name))
        {
            try references.append(self.allocator, current);
        }
        var children = ast_walk.children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
}

/// 객체 리터럴 방문 결과를 home 에 담는다 — `Home.Wrap` 참고.
pub fn wrapWithHome(self: *Transformer, home: Home, obj: NodeIndex, span: Span) Transformer.Error!NodeIndex {
    const assign = try self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{
        .left = try es_helpers.makeTempVarRef(self, home.identity.span, home.identity.span),
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
                try es_helpers.makeExactSyntheticBindingFromSpan(self, home.identity.span)
            else
                .none;
            if (!callback_binding.isNone())
                try self.registerGeneratedCallbackTempBinding(
                    home.temp_counter_index orelse std.debug.panic("deferred object home has no allocator slot", .{}),
                    callback_binding,
                );
            const deferred_temp_producer_id: ?u64 = if (deferred_output_scope and callback_binding.isNone()) blk: {
                const counter_index = home.temp_counter_index orelse
                    std.debug.panic("deferred object home has no allocator slot", .{});
                const producer_id = self.temp_producer_id_by_counter.get(counter_index) orelse
                    std.debug.panic("deferred object home has no producer identity", .{});
                if (producer_id == 0) std.debug.panic("deferred object home has an invalid producer identity", .{});
                break :blk producer_id;
            } else null;
            const symbol_id: ?SymbolId = if (parameter_output_scope != null) blk: {
                const id = (try self.reserveSyntheticTempSymbolInScope(home.identity.span, span, output_scope)) orelse
                    std.debug.panic("lowered parameter object home temp has no SymbolId", .{});
                const counter_index = home.temp_counter_index orelse
                    std.debug.panic("lowered parameter object home temp has no allocator slot", .{});
                const producer_id = self.temp_producer_id_by_counter.get(counter_index) orelse
                    std.debug.panic("lowered parameter object home temp has no producer identity", .{});
                if (producer_id == 0) std.debug.panic("lowered parameter object home temp has an invalid producer identity", .{});
                const producer_symbol = try self.temp_symbol_ids_by_counter.getOrPut(self.allocator, counter_index);
                if (producer_symbol.found_existing and producer_symbol.value_ptr.* != @backingInt(id))
                    std.debug.panic("lowered parameter object home producer changed its exact SymbolId", .{});
                producer_symbol.value_ptr.* = @backingInt(id);
                break :blk id;
            } else if (deferred_output_scope)
                null
            else blk: {
                const owner_scope = self.nearestVarScope(output_scope);
                const binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, home.identity.span);
                break :blk (try self.declareSyntheticTempInScope(binding, span, owner_scope)) orelse
                    std.debug.panic("function-scoped object home temp has no SymbolId", .{});
            };
            try trackHoistedHomeReferences(
                self,
                obj,
                self.ast.getNode(assign).data.binary.left,
                home.identity,
                home.identity.span,
                output_scope,
                symbol_id,
                callback_binding,
                deferred_temp_producer_id,
                if (parameter_output_scope != null and parameter_output_scope.? != parent_scope)
                    parent_scope
                else
                    .none,
            );
        }
        return assign;
    }

    var arguments_refs: std.ArrayList(NodeIndex) = .empty;
    defer arguments_refs.deinit(self.allocator);
    if (home.arguments_alias_span) |alias_span|
        try collectHomeArgumentsAliasReferences(self, obj, alias_span, &arguments_refs);
    const parent_scope = homeObjectWrapperParentScope(self, obj, self.current_scope);
    const arguments_ref = home.arguments_outer_ref;
    if (home.arguments_alias_span != null and arguments_ref.isNone())
        std.debug.panic("object-super arguments wrapper lost its outer reference", .{});

    const param_binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, home.identity.span);
    const none = @backingInt(NodeIndex.none);
    var formals: std.ArrayList(NodeIndex) = .empty;
    defer formals.deinit(self.allocator);
    const home_formal = try self.ast.addNode(.{
        .tag = .formal_parameter,
        .span = span,
        // extras = [pattern, type_ann, default, flags, deco_start, deco_len] — deco_len 은 0.
        .data = .{ .extra = try self.ast.addExtras(&.{ @backingInt(param_binding), none, none, 0, 0, 0 }) },
    });
    try formals.append(self.allocator, home_formal);
    const arguments_binding = if (home.arguments_alias_span) |alias_span| blk: {
        const binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, alias_span);
        const formal = try self.ast.addNode(.{
            .tag = .formal_parameter,
            .span = span,
            .data = .{ .extra = try self.ast.addExtras(&.{ @backingInt(binding), none, none, 0, 0, 0 }) },
        });
        try formals.append(self.allocator, formal);
        break :blk binding;
    } else .none;
    const params = try self.ast.addFormalParameters(try self.ast.addNodeList(formals.items), span);
    const callee = switch (home.wrap) {
        .assign => unreachable,
        .arrow => try self.ast.addNode(.{ .tag = .arrow_function_expression, .span = span, .data = .{
            .extra = try self.ast.addExtras(&.{ @backingInt(params), @backingInt(assign), 0 }),
        } }),
        .function, .function_with_this, .function_with_arguments, .function_with_this_and_arguments => blk: {
            const ret = try self.ast.addNode(.{ .tag = .return_statement, .span = span, .data = .{ .unary = .{ .operand = assign, .flags = 0 } } });
            const body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{ret}) } });
            break :blk try self.ast.addNode(.{ .tag = .function_expression, .span = span, .data = .{
                .extra = try self.ast.addExtras(&.{ none, @backingInt(params), @backingInt(body), 0, none }),
            } });
        },
    };
    try bindWrappedHomeParameter(
        self,
        callee,
        param_binding,
        arguments_binding,
        arguments_refs.items,
        assign,
        home.identity,
        parent_scope,
        home.late_output_name,
    );
    if (home.wrap == .function_with_this or home.wrap == .function_with_this_and_arguments) {
        const call = try es_helpers.makeStaticMember(
            self,
            callee,
            try es_helpers.makePropertyName(self, "call"),
            span,
        );
        if (home.wrap == .function_with_this_and_arguments)
            return es_helpers.makeCallExpr(self, call, &.{
                try es_helpers.makeThisExpr(self, span),
                try es_helpers.makeVoidZero(self, span),
                arguments_ref,
            }, span);
        return es_helpers.makeCallExpr(self, call, &.{try es_helpers.makeThisExpr(self, span)}, span);
    }
    if (home.wrap == .function_with_arguments)
        return es_helpers.makeCallExpr(self, callee, &.{ try es_helpers.makeVoidZero(self, span), arguments_ref }, span);
    return es_helpers.makeCallExpr(self, callee, &.{}, span);
}

/// Generator and async lowering can visit an object's value expressions while
/// the transform cursor is at an outer scope. The shallowest owned scope in
/// the emitted object still records the lexical scope that contains the
/// expression, so use its parent for the generated home wrapper.
fn homeObjectParentScope(self: *Transformer, root: NodeIndex, fallback: ScopeId) ScopeId {
    return findHomeObjectParentScope(self, root, fallback, false);
}

/// A function wrapper cannot be inserted under a lowered formal-parameter
/// environment when its body owns that environment: doing so would make the
/// environment a descendant of the wrapper that it already contains. Place
/// only wrapped home-object expressions outside that formal scope. The
/// assignment-temp path must keep the parameter scope as its exact owner.
fn homeObjectWrapperParentScope(self: *Transformer, root: NodeIndex, fallback: ScopeId) ScopeId {
    return findHomeObjectParentScope(self, root, fallback, true);
}

/// A method lowered to a named expression evaluates outside its self-name
/// environment. That environment must move with the function, including a
/// separate formal scope when present; it never owns the surrounding object.
fn namedFunctionBoundary(self: *Transformer, owner: NodeIndex, inner: ScopeId) ScopeId {
    const node = self.ast.getNode(owner);
    if (node.tag != .function_expression) return inner;
    const name = self.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.name);
    if (name.isNone()) return inner;
    const sid = self.getSymbolIdAt(name) orelse return inner;
    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
    const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
    const maps = if (self.semantic_editor) |*editor| editor.scope_maps.items else self.scope_maps;
    if (sid >= symbols.len or inner.isNone() or inner.toIndex() >= scopes.len) return inner;
    const symbol = symbols[sid];
    const name_scope = symbol.scope_id;
    if (name_scope.isNone() or name_scope == inner or name_scope.toIndex() >= scopes.len or name_scope.toIndex() >= maps.len or
        symbol.origin_scope != name_scope or !symbol.kind.isFunctionLike() or
        scopes[name_scope.toIndex()].kind != .block or
        scopes[name_scope.toIndex()].symbol_count != 1 or
        maps[name_scope.toIndex()].count() != 1) return inner;
    var boundary = inner;
    const params = self.ast.readExtraNode(node.data.extra, ast_mod.FunctionExtra.params);
    if (self.outputOwnedScope(params)) |parameters| {
        if (parameters != boundary and parameters.toIndex() < scopes.len and
            scopes[boundary.toIndex()].parent == parameters and
            scopes[parameters.toIndex()].kind == .function) boundary = parameters;
    }
    if (scopes[boundary.toIndex()].parent != name_scope) return inner;
    var values = maps[name_scope.toIndex()].valueIterator();
    if (values.next().?.* != sid) return inner;
    return name_scope;
}

fn findHomeObjectParentScope(
    self: *Transformer,
    root: NodeIndex,
    fallback: ScopeId,
    escape_lowered_parameter_environment: bool,
) ScopeId {
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
            const parent = self.outputScopeParent(namedFunctionBoundary(self, node_idx, scope));
            if (!parent.isNone()) {
                // A lowered formal-parameter environment belongs to the
                // method found below this object literal, not to the object
                // expression itself. Put the wrapper in the lexical scope
                // outside that method so reparenting its generated parameter
                // and body scopes cannot make the wrapper its own ancestor.
                if (escape_lowered_parameter_environment and
                    self.loweredParameterEnvironmentOutputScope(parent) != null)
                {
                    const lexical_parent = self.outputScopeParent(parent);
                    if (!lexical_parent.isNone()) return lexical_parent;
                }
                return parent;
            }
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
    identity: ObjectSuperHomeIdentity,
    name_span: Span,
    root_scope: ScopeId,
    symbol_id: ?SymbolId,
    callback_binding: NodeIndex,
    deferred_temp_producer_id: ?u64,
    reparent_from_scope: ScopeId,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled or root_scope.isNone()) return;
    var home_refs = try collectObjectSuperHomeReferences(self, identity);
    defer home_refs.deinit(self.allocator);
    if (symbol_id) |id|
        try self.addSyntheticRefInScope(write_ref, id, root_scope, .{ .write = true })
    else if (!callback_binding.isNone())
        try self.trackGeneratedCallbackTempReference(callback_binding, write_ref, root_scope, .{ .write = true })
    else if (deferred_temp_producer_id) |producer_id|
        try self.trackDeferredTempProducerReference(producer_id, name_span, write_ref, root_scope, .{ .write = true })
    else
        std.debug.panic("deferred object home has no exact producer identity", .{});
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
            else if (deferred_temp_producer_id) |producer_id|
                try self.trackDeferredTempProducerReference(producer_id, name_span, work.node, scope, .{ .read = true })
            else
                std.debug.panic("deferred object home has no exact producer identity", .{});
        }
        var it = ast_walk.children(self.ast, node);
        while (it.next()) |child| try queue.append(self.allocator, .{ .node = child, .scope = scope });
    }
    forgetObjectSuperHomeReferences(self, identity);
}

/// Arrow/function home wrappers introduce a real parameter scope after their
/// contents were transformed. Move the scopes owned inside the wrapped object
/// under that scope, then attach the generated home binding and every exact
/// read/write in the wrapper tree.
fn bindWrappedHomeParameter(
    self: *Transformer,
    wrapper: NodeIndex,
    binding: NodeIndex,
    arguments_binding: NodeIndex,
    arguments_refs: []const NodeIndex,
    assignment: NodeIndex,
    identity: ObjectSuperHomeIdentity,
    parent_scope: ScopeId,
    late_output_name: bool,
) Transformer.Error!void {
    if (!self.semantic_edit_enabled or parent_scope.isNone()) return;
    const wrapper_scope = try self.addGeneratedFunctionScope(parent_scope, wrapper);
    if (wrapper_scope.isNone()) return;
    const id = (try self.declareSyntheticInScope(binding, self.ast.getNode(binding).span, .parameter, wrapper_scope)) orelse return;
    const arguments_id = if (!arguments_binding.isNone())
        try self.declareSyntheticInScope(
            arguments_binding,
            self.ast.getNode(arguments_binding).span,
            .parameter,
            wrapper_scope,
        )
    else
        null;
    if (late_output_name) {
        if (es_helpers.canUseLateGraphOutputName(self, wrapper_scope)) {
            es_helpers.markLateGraphSyntheticSymbol(self, id, .object_super_home_binding, "_obj");
        } else if (es_helpers.canUseLateStandaloneOutputName(self, wrapper_scope)) {
            es_helpers.markStandaloneLateSyntheticOutputName(
                self,
                id,
                self.ast.getText(identity.span),
                .object_super_home_binding,
                "_obj",
            );
        } else {
            std.debug.panic("late object-super home parameter lost its eligible scope", .{});
        }
    }
    const write_ref = self.ast.getNode(assignment).data.binary.left;
    var home_refs = try collectObjectSuperHomeReferences(self, identity);
    defer home_refs.deinit(self.allocator);
    var arguments_ref_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer arguments_ref_set.deinit(self.allocator);
    for (arguments_refs) |ref| try arguments_ref_set.put(self.allocator, @backingInt(ref), {});
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
                if (!visible) {
                    var reparent_scope = owned_scope;
                    const params_offset: ?u32 = switch (node.tag) {
                        .function_declaration, .function_expression, .function => ast_mod.FunctionExtra.params,
                        .method_definition => ast_mod.MethodExtra.params,
                        .arrow_function_expression => ast_mod.ArrowExtra.params,
                        else => null,
                    };
                    if (params_offset) |offset| {
                        const params = self.ast.readExtraNode(node.data.extra, offset);
                        if (self.outputOwnedScope(params)) |parameter_scope| {
                            const editor = self.semantic_editor orelse unreachable;
                            if (parameter_scope != owned_scope and owned_scope.toIndex() < editor.scopes.items.len and
                                parameter_scope.toIndex() < editor.scopes.items.len and
                                editor.scopes.items[owned_scope.toIndex()].parent == parameter_scope)
                            {
                                // Keep the function's parameter environment
                                // between the wrapper and its body. Moving the
                                // method and formal scopes independently would
                                // make them siblings and break default reads.
                                reparent_scope = parameter_scope;
                            }
                        }
                    }
                    reparent_scope = namedFunctionBoundary(self, work.node, reparent_scope);
                    try self.reparentGeneratedScope(reparent_scope, wrapper_scope);
                }
            }
        }

        // Direct object-creation expressions now run in this real wrapper.
        // Nested method bodies retain their own recorded use scopes.
        try self.relocateNodeScopeProvenance(work.node, parent_scope, scope);

        // This wrapper is the actual producer moving the already-created
        // computed-object call under its new function scope. Hand off only
        // the recorded callee, using the existing exact helper relocation API;
        // final graph inspection must never infer this move from a late row.
        if (@import("computed_object_helper_authority.zig").contains(self, work.node))
            try self.relocateRuntimeHelperRef(work.node, scope);

        if (work.node == write_ref or home_refs.fetchRemove(raw) != null) {
            const flags: ReferenceFlags = if (work.node == write_ref) .{ .write = true } else .{ .read = true };
            try self.addSyntheticRefInScope(work.node, id, scope, flags);
        } else if (arguments_ref_set.fetchRemove(raw) != null) {
            const arguments_symbol = arguments_id orelse
                std.debug.panic("object-super arguments alias has references but no parameter SymbolId", .{});
            try self.addSyntheticRefInScope(work.node, arguments_symbol, scope, .{ .read = true });
        }
        var it = ast_walk.children(self.ast, node);
        while (it.next()) |child| {
            const child_scope = if (@import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, raw, @backingInt(child))) work.scope else scope;
            try worklist.append(self.allocator, .{ .node = child, .scope = child_scope });
        }
    }
    forgetObjectSuperHomeReferences(self, identity);
}

/// Home-prototype reads are recorded at their producer as exact NodeIndexes.
/// Build the short-lived set used while the final output scopes are resolved.
fn collectObjectSuperHomeReferences(
    self: *Transformer,
    identity: ObjectSuperHomeIdentity,
) Transformer.Error!std.AutoHashMapUnmanaged(u32, void) {
    var nodes: std.AutoHashMapUnmanaged(u32, void) = .empty;
    errdefer nodes.deinit(self.allocator);
    for (self.object_super_home_references.items) |reference| {
        if (reference.producer_node != identity.producer_node) continue;
        try nodes.put(self.allocator, @backingInt(reference.node), {});
    }
    return nodes;
}

fn forgetObjectSuperHomeReferences(self: *Transformer, identity: ObjectSuperHomeIdentity) void {
    var retained: usize = 0;
    for (self.object_super_home_references.items) |reference| {
        if (reference.producer_node == identity.producer_node) continue;
        self.object_super_home_references.items[retained] = reference;
        retained += 1;
    }
    self.object_super_home_references.shrinkRetainingCapacity(retained);
}

/// A generated `Object.getPrototypeOf(home)` read keeps the exact reference
/// node until its wrapper binding and output scope are known.
pub fn recordHomePrototypeReference(self: *Transformer, identity: ObjectSuperHomeIdentity, node: NodeIndex) Transformer.Error!void {
    if (!self.semantic_edit_enabled) return;
    try self.object_super_home_references.append(self.allocator, .{ .producer_node = identity.producer_node, .node = node });
}

pub const Saved = struct {
    home: ?ObjectSuperHomeIdentity,
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
pub fn enterMethod(self: *Transformer, home: ?ObjectSuperHomeIdentity) Saved {
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
pub fn buildHomeProto(self: *Transformer, home: ObjectSuperHomeIdentity, span: Span) Transformer.Error!NodeIndex {
    const builtin = @import("object_builtin_reference.zig");
    const context = builtin.captureHome(self, home) catch |err| return builtin.productionFailure(err);
    const object_ref = builtin.makeReference(self, context) catch |err| return builtin.productionFailure(err);
    const get_proto = try es_helpers.makePropertyName(self, "getPrototypeOf");
    const callee = try es_helpers.makeStaticMember(self, object_ref, get_proto, span);
    const home_ref = try es_helpers.makeTempVarRef(self, home.span, home.span);
    try recordHomePrototypeReference(self, home, home_ref);
    return es_helpers.makeCallExpr(self, callee, &.{home_ref}, span);
}
