//! Auto-workletization helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const AutoWorkletCallee = @import("../../bundler/plugin.zig").AutoWorkletCallee;
const worklet_plugin = @import("../plugins/worklet_plugin.zig");

/// call_expression의 callee가 auto-workletization 대상 함수인지 매칭.
/// identifier_reference(직접 호출) 또는 static_member_expression(메서드 호출) 지원.
pub fn matchAutoWorkletCallee(self: *Transformer, callee_idx: NodeIndex) ?AutoWorkletCallee {
    if (self.options.plugins.len == 0) return null;
    if (callee_idx.isNone()) return null;

    const callee_node = self.ast.getNode(callee_idx);
    // 합성된 노드(es2018_for_await 등이 만든 __asyncValues 등)는 span 이 string_table 인코딩.
    // self.ast.source[..] 직접 접근 시 STRING_TABLE_BIT 가 set 되어 OOB -> SIGBUS (#1404).
    // self.ast.getText(span) 가 두 경로 모두 처리.
    const callee_name: []const u8 = switch (callee_node.tag) {
        // scheduleOnUI(...) 형태
        .identifier_reference => self.ast.getText(callee_node.span),
        // obj.onBegin(...) 형태: 프로퍼티 이름만 추출
        .static_member_expression => blk: {
            const me = callee_node.data.extra;
            if (me + 1 >= self.ast.extra_data.items.len) break :blk "";
            const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
            if (prop_idx.isNone()) break :blk "";
            const prop = self.ast.getNode(prop_idx);
            break :blk self.ast.getText(prop.span);
        },
        else => return null,
    };
    if (callee_name.len == 0) return null;

    const is_method = callee_node.tag == .static_member_expression;
    for (self.options.plugins) |p| {
        for (p.autoWorkletCallees) |entry| {
            if (entry.is_method != is_method) continue;
            if (!std.mem.eql(u8, entry.name, callee_name)) continue;
            // receiver_kind 검증: layout_animation은 수신자가 알려진 LA 클래스여야 함.
            if (entry.receiver_kind == .layout_animation) {
                const me = callee_node.data.extra;
                const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
                if (!isLayoutAnimationReceiver(self, obj_idx)) continue;
            }
            // receiver_kind 검증: gesture_object는 수신자가 `Gesture.Foo()` 체인이어야 함.
            if (entry.receiver_kind == .gesture_object) {
                const me = callee_node.data.extra;
                const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
                if (!isGestureObjectReceiver(self, obj_idx)) continue;
            }
            return entry;
        }
    }
    return null;
}

/// Layout Animation receiver 여부 판정.
/// Babel plugin의 isLayoutAnimationsChainableOrNewOperator 포팅:
///  - identifier가 알려진 LA 클래스명이면 true
///  - new LAClass(...)면 true
///  - LAClass.chainMethod()로 체이닝된 경우 재귀적으로 true (chainMethod는 build/duration 등)
fn isLayoutAnimationReceiver(self: *Transformer, node_idx: NodeIndex) bool {
    if (node_idx.isNone()) return false;
    const node = self.ast.getNode(node_idx);

    // Identifier: 클래스 이름 직접 매칭
    if (node.tag == .identifier_reference) {
        const name = self.ast.getText(node.span);
        for (worklet_plugin.LAYOUT_ANIMATION_CLASSES) |c| {
            if (std.mem.eql(u8, c, name)) return true;
        }
        return false;
    }

    // new LAClass(...)
    if (node.tag == .new_expression) {
        const ne = node.data.extra;
        const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ne]);
        return isLayoutAnimationReceiver(self, callee_idx);
    }

    // LAChain.chainMethod(): 체이닝 메서드 호출
    if (node.tag == .call_expression) {
        const ce = node.data.extra;
        const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
        const callee_node = self.ast.getNode(callee_idx);
        if (callee_node.tag != .static_member_expression) return false;
        const me = callee_node.data.extra;
        const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
        if (prop_idx.isNone()) return false;
        const prop = self.ast.getNode(prop_idx);
        const prop_name = self.ast.getText(prop.span);
        var chainable = false;
        for (worklet_plugin.LAYOUT_ANIMATION_CHAINABLE_METHODS) |m| {
            if (std.mem.eql(u8, m, prop_name)) {
                chainable = true;
                break;
            }
        }
        if (!chainable) return false;
        const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
        return isLayoutAnimationReceiver(self, obj_idx);
    }

    return false;
}

/// Gesture object receiver 여부 판정.
/// Babel plugin의 containsGestureObject 포팅:
///  - `Gesture.Foo()` 직접 (Foo는 GESTURE_OBJECT_NAMES 중 하나) -> true
///  - `X.method()` 체인이면 X로 재귀
///  - 그 외 -> false
fn isGestureObjectReceiver(self: *Transformer, node_idx: NodeIndex) bool {
    if (node_idx.isNone()) return false;
    const node = self.ast.getNode(node_idx);
    if (node.tag != .call_expression) return false;

    const ce = node.data.extra;
    const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
    const callee = self.ast.getNode(callee_idx);
    if (callee.tag != .static_member_expression) return false;

    const me = callee.data.extra;
    const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me]);
    const obj_node = self.ast.getNode(obj_idx);

    // 직접: `Gesture.Foo()` - object가 `Gesture` identifier + property가 gesture object 이름
    if (obj_node.tag == .identifier_reference) {
        const obj_name = self.ast.getText(obj_node.span);
        if (!std.mem.eql(u8, obj_name, "Gesture")) return false;
        const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 1]);
        if (prop_idx.isNone()) return false;
        const prop = self.ast.getNode(prop_idx);
        const prop_name = self.ast.getText(prop.span);
        for (worklet_plugin.GESTURE_OBJECT_NAMES) |g| {
            if (std.mem.eql(u8, g, prop_name)) return true;
        }
        return false;
    }

    // 체인: `X.method().onFoo(...)` - object(= `X.method()`) 재귀
    return isGestureObjectReceiver(self, obj_idx);
}

/// Object hook의 object literal 인자를 방문하며, 각 property 값(function/arrow/method)에
/// auto_next 플래그를 전파하여 worklet으로 변환한다.
/// Metro+Babel의 `processWorkletizableObject` 대응 (reanimated 'object hooks').
fn visitObjectExpressionAutoWorklet(self: *Transformer, obj_idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(obj_idx);
    if (node.tag != .object_expression) return self.visitNode(obj_idx);
    const list = node.data.list;
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const raw = self.ast.extra_data.items[list.start + i];
        const prop_idx: NodeIndex = @enumFromInt(raw);
        if (prop_idx.isNone()) continue;
        const prop = self.ast.getNode(prop_idx);

        switch (prop.tag) {
            // shorthand method: `{ onScroll(e) { ... } }` - method_definition 자체가 worklet
            .method_definition => {
                const saved = self.plugins.worklet.auto_next;
                self.plugins.worklet.auto_next = true;
                const new_prop = try self.visitNode(prop_idx);
                self.plugins.worklet.auto_next = saved;
                if (!new_prop.isNone()) try self.scratch.append(self.allocator, new_prop);
            },
            // `{ onScroll: (e) => {...} }` - value가 function/arrow면 workletize
            .object_property => {
                const value_idx = prop.data.binary.right;
                const is_fn = blk: {
                    if (value_idx.isNone()) break :blk false;
                    const v = self.ast.getNode(value_idx);
                    break :blk v.tag == .function_expression or v.tag == .arrow_function_expression;
                };
                if (is_fn) {
                    const saved = self.plugins.worklet.auto_next;
                    self.plugins.worklet.auto_next = true;
                    const new_value = try self.visitNode(value_idx);
                    self.plugins.worklet.auto_next = saved;
                    const key_idx = prop.data.binary.left;
                    const new_key = if (!key_idx.isNone() and self.ast.getNode(key_idx).tag != .computed_property_key)
                        try self.copyNodeDirect(key_idx)
                    else
                        try self.visitNode(key_idx);
                    const new_prop = try self.ast.addNode(.{
                        .tag = .object_property,
                        .span = prop.span,
                        .data = .{ .binary = .{
                            .left = new_key,
                            .right = new_value,
                            .flags = prop.data.binary.flags,
                        } },
                    });
                    try self.scratch.append(self.allocator, new_prop);
                } else {
                    const new_prop = try self.visitNode(prop_idx);
                    if (!new_prop.isNone()) try self.scratch.append(self.allocator, new_prop);
                }
            },
            else => {
                const new_prop = try self.visitNode(prop_idx);
                if (!new_prop.isNone()) try self.scratch.append(self.allocator, new_prop);
            },
        }
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = .object_expression,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}

/// auto-workletization이 필요한 call expression의 인자를 개별 방문.
/// 대상 인자 위치의 function/arrow 방문 전에 plugins.worklet.auto_next 플래그를 설정.
pub fn visitCallArgsWithAutoWorklet(self: *Transformer, args_start: u32, args_len: u32, callee: AutoWorkletCallee) Error!NodeList {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    const pending_top = self.pending_nodes.items.len;
    defer self.pending_nodes.shrinkRetainingCapacity(pending_top);

    const trailing_top = self.trailing_nodes.items.len;
    defer self.trailing_nodes.shrinkRetainingCapacity(trailing_top);

    var i: u32 = 0;
    while (i < args_len) : (i += 1) {
        const raw_idx = self.ast.extra_data.items[args_start + i];
        const arg_idx: NodeIndex = @enumFromInt(raw_idx);

        // 이 인자가 auto-worklet 대상인지 확인
        const should_auto = blk: {
            for (callee.arg_indices) |idx| {
                if (idx == 0xFF) break;
                if (idx == @as(u8, @intCast(i))) break :blk true;
            }
            break :blk false;
        };

        // save/restore: 재귀적 visitNode 내부의 중첩 call_expression이
        // plugins.worklet.auto_next를 오염시키지 않도록 보호.
        const saved_auto = self.plugins.worklet.auto_next;
        var object_hook_arg = false;
        if (should_auto and !arg_idx.isNone()) {
            const arg_node = self.ast.getNode(arg_idx);
            if (arg_node.tag == .function_expression or
                arg_node.tag == .arrow_function_expression)
            {
                self.plugins.worklet.auto_next = true;
            } else if (callee.accept_object and arg_node.tag == .object_expression) {
                object_hook_arg = true;
            }
        }

        const new_child = if (object_hook_arg)
            try visitObjectExpressionAutoWorklet(self, arg_idx)
        else
            try self.visitNode(arg_idx);
        self.plugins.worklet.auto_next = saved_auto;

        // pending_nodes 드레인
        if (self.pending_nodes.items.len > pending_top) {
            try self.scratch.appendSlice(self.allocator, self.pending_nodes.items[pending_top..]);
            self.pending_nodes.shrinkRetainingCapacity(pending_top);
        }

        if (!new_child.isNone()) {
            try self.scratch.append(self.allocator, new_child);
        }

        // trailing_nodes 드레인
        if (self.trailing_nodes.items.len > trailing_top) {
            try self.scratch.appendSlice(self.allocator, self.trailing_nodes.items[trailing_top..]);
            self.trailing_nodes.shrinkRetainingCapacity(trailing_top);
        }
    }

    return self.ast.addNodeList(self.scratch.items[scratch_top..]);
}
