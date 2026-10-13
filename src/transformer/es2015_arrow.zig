//! ES2015 다운레벨링: arrow function
//!
//! --target < es2015 일 때 활성화.
//! () => expr       → function() { return expr; }
//! () => { stmts }  → function() { stmts }
//! (x) => x + 1     → function(x) { return x + 1; }
//! x => x + 1       → function(x) { return x + 1; }
//!
//! 파서에서 arrow의 params 슬롯은 세 가지 형태:
//!   1. NodeIndex.none → 빈 파라미터 (() => ...)
//!   2. binding_identifier → 단일 파라미터 (x => ...)
//!   3. formal_parameters(list) → 괄호 형태 ((x, y) => ...)
//!
//! this/arguments 캡처:
//!   arrow body 안의 this → _this, arguments → _arguments로 치환.
//!   외부 함수(visitFunction)에서 var _this = this; / var _arguments = arguments; 삽입.
//!   중첩 arrow는 같은 _this를 공유, 내부 일반 함수는 별도 스코프.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-arrow-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/arrow.rs (~253줄)
//! - ZNTC ES2017: es2017.zig lowerAsyncArrow

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const es_helpers = @import("es_helpers.zig");
const FunctionInfo = @import("ast_plugin.zig").FunctionInfo;

pub const LexicalCaptureInfo = struct {
    this_value: bool = false,
    arguments_value: bool = false,
    new_target_value: bool = false,
    super_value: bool = false,

    pub fn any(self: LexicalCaptureInfo) bool {
        return self.this_value or self.arguments_value or self.new_target_value or self.super_value;
    }
};

pub fn ES2015Arrow(comptime Transformer: type) type {
    return struct {
        fn pushDecorators(self: *Transformer, stack: *std.ArrayList(NodeIndex), extra: u32, start_offset: u32, len_offset: u32) std.mem.Allocator.Error!void {
            const list = ast_mod.NodeList{
                .start = self.readU32(extra, start_offset),
                .len = self.readU32(extra, len_offset),
            };
            if (list.start > self.ast.extra_data.items.len or list.len > self.ast.extra_data.items.len - list.start) return;
            var decorators = self.ast.iterateExtraList(list);
            while (decorators.next()) |decorator| try stack.append(self.allocator, decorator);
        }

        /// Dynamic `with` lookup can intercept generated lexical-capture aliases.
        /// Scan nested arrows and class expressions in outer-evaluated positions,
        /// while skipping ordinary functions and method bodies with their own values.
        pub fn lexicalCaptures(self: *Transformer, source_owner: NodeIndex) std.mem.Allocator.Error!LexicalCaptureInfo {
            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer seen.deinit(self.allocator);
            var captures: LexicalCaptureInfo = .{};
            try stack.append(self.allocator, source_owner);

            while (stack.pop()) |idx| {
                if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;
                const raw = @intFromEnum(idx);
                if (seen.contains(raw)) continue;
                try seen.put(self.allocator, raw, {});
                const node = self.ast.getNode(idx);
                if (idx != source_owner and isLexicalValueBoundary(node.tag)) continue;
                if (idx != source_owner) switch (node.tag) {
                    // A method owns `this` in its parameters and body, but its
                    // computed key and decorators are evaluated outside it.
                    .method_definition => {
                        try stack.append(self.allocator, self.readNodeIdx(node.data.extra, ast_mod.MethodExtra.key));
                        try pushDecorators(self, &stack, node.data.extra, ast_mod.MethodExtra.deco_start, ast_mod.MethodExtra.deco_len);
                        continue;
                    },
                    // Class field initializers have class/instance `this`; a
                    // computed field key and decorators evaluate in the outer scope.
                    .property_definition, .accessor_property => {
                        try stack.append(self.allocator, self.readNodeIdx(node.data.extra, ast_mod.PropertyExtra.key));
                        try pushDecorators(self, &stack, node.data.extra, ast_mod.PropertyExtra.deco_start, ast_mod.PropertyExtra.deco_len);
                        continue;
                    },
                    .static_block => continue,
                    else => {},
                };

                switch (node.tag) {
                    .this_expression => captures.this_value = true,
                    .super_expression => captures.super_value = true,
                    .meta_property => if (node.data.none == 1) {
                        captures.new_target_value = true;
                    },
                    .identifier_reference => {
                        const raw_name = self.ast.identifierNameText(node);
                        var decode_buffer: [64]u8 = undefined;
                        const name = if (std.mem.indexOfScalar(u8, raw_name, '\\') != null)
                            Scanner.decodeIdentifierEscapesInto(raw_name, &decode_buffer) orelse raw_name
                        else
                            raw_name;
                        if (std.mem.eql(u8, name, "arguments")) captures.arguments_value = true;
                    },
                    else => {},
                }

                if (node.tag == .class_declaration or node.tag == .class_expression) {
                    try pushDecorators(self, &stack, node.data.extra, ast_mod.ClassExtra.deco_start, ast_mod.ClassExtra.deco_len);
                }

                var children = ast_walk.children(self.ast, node);
                while (children.next()) |child| try stack.append(self.allocator, child);
            }
            return captures;
        }

        /// A direct eval argument that is not a statically written string can
        /// observe any generated lexical-capture binding in this arrow's
        /// closure. Preserve the arrow instead of guessing synthetic names.
        /// Scan through nested functions too: their eval calls can see aliases
        /// created by an enclosing lowered arrow.
        pub fn hasDynamicEvalArgument(self: *Transformer, root: NodeIndex) std.mem.Allocator.Error!bool {
            if (root.isNone() or @intFromEnum(root) >= self.ast.nodes.items.len) return false;

            // The analyzer propagates direct-eval presence through ancestor
            // scopes, so most arrows can avoid a second AST walk. If ownership
            // is unavailable, scan and fail closed on malformed scope data.
            if (self.outputOwnedScope(root)) |scope_id| {
                const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
                if (scope_id.toIndex() >= scopes.len) return true;
                if (!scopes[scope_id.toIndex()].subtree_has_direct_eval) return false;
            }

            const reachable = try ast_walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, root);
            defer self.allocator.free(reachable);
            const extras = self.ast.extra_data.items;
            for (reachable) |raw| {
                if (raw >= self.ast.nodes.items.len) return true;
                const node = self.ast.nodes.items[raw];
                if (node.tag != .call_expression) continue;
                const e = node.data.extra;
                if (e > extras.len or extras.len - e < 4) return true;
                if ((extras[e + 3] & ast_mod.CallFlags.optional_chain) != 0) continue;

                const callee_idx = self.ast.readExtraNode(e, 0);
                if (!isDirectEvalCallee(self.ast, callee_idx)) continue;

                const args_start = extras[e + 1];
                const args_len = extras[e + 2];
                if (args_len == 0) continue;
                if (args_start >= extras.len or args_len > extras.len - args_start) return true;
                const arg_raw = extras[args_start];
                if (arg_raw >= self.ast.nodes.items.len) return true;

                var arg_idx: NodeIndex = @enumFromInt(arg_raw);
                while (!arg_idx.isNone() and @intFromEnum(arg_idx) < self.ast.nodes.items.len) {
                    const arg = self.ast.getNode(arg_idx);
                    if (arg.tag == .parenthesized_expression or ast_mod.Node.Tag.isTransparentTypeWrapper(arg.tag)) {
                        arg_idx = arg.data.unary.operand;
                    } else {
                        if (arg.tag != .string_literal) return true;
                        break;
                    }
                }
            }
            return false;
        }

        /// Downleveling a class erases the method home-object context required
        /// by a preserved arrow's lexical `super`. Keep the whole class when a
        /// `with` body can make that preservation necessary.
        pub fn hasLexicalSuperArrow(self: *Transformer, root: NodeIndex) std.mem.Allocator.Error!bool {
            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
            defer seen.deinit(self.allocator);
            try stack.append(self.allocator, root);

            while (stack.pop()) |idx| {
                if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;
                const raw = @intFromEnum(idx);
                if (seen.contains(raw)) continue;
                try seen.put(self.allocator, raw, {});
                const node = self.ast.getNode(idx);
                if (idx != root and isLexicalValueBoundary(node.tag)) continue;

                if (node.tag == .arrow_function_expression) {
                    const captures = try lexicalCaptures(self, idx);
                    if (captures.super_value) return true;
                }
                if (node.tag == .class_declaration or node.tag == .class_expression) {
                    try pushDecorators(self, &stack, node.data.extra, ast_mod.ClassExtra.deco_start, ast_mod.ClassExtra.deco_len);
                } else if (node.tag == .method_definition) {
                    try pushDecorators(self, &stack, node.data.extra, ast_mod.MethodExtra.deco_start, ast_mod.MethodExtra.deco_len);
                } else if (node.tag == .property_definition or node.tag == .accessor_property) {
                    try pushDecorators(self, &stack, node.data.extra, ast_mod.PropertyExtra.deco_start, ast_mod.PropertyExtra.deco_len);
                }

                var children = ast_walk.children(self.ast, node);
                while (children.next()) |child| try stack.append(self.allocator, child);
            }
            return false;
        }

        /// arrow_function_expression → function_expression 변환.
        /// arrow body 안의 this → _this, arguments → _arguments 치환을 위해
        /// arrow_this_depth를 증가시킨 상태로 body를 방문한다.
        pub fn lowerArrowFunction(self: *Transformer, source_owner: NodeIndex, node: Node) Transformer.Error!NodeIndex {
            const e = node.data.extra;
            if (e + 2 >= self.ast.extra_data.items.len) return NodeIndex.none;

            const native_parameter_capture = self.options.unsupported.arrow and
                (!self.options.unsupported.default_params or
                    self.native_parameter_list_retained_for_dynamic_lookup) and self.capture_frame != 0 and
                self.native_parameter_initializer_frame == self.capture_frame;
            const native_parameter_arrow_depth = self.native_parameter_arrow_depth;
            const parent_native_parameter_arrow_owner = self.native_parameter_arrow_owner;
            if (native_parameter_capture) {
                self.native_parameter_arrow_depth += 1;
                self.native_parameter_arrow_owner = source_owner;
            }
            defer self.native_parameter_arrow_depth = native_parameter_arrow_depth;
            defer self.native_parameter_arrow_owner = parent_native_parameter_arrow_owner;

            const params_idx: NodeIndex = self.readNodeIdx(e, 0);
            const body_idx: NodeIndex = self.readNodeIdx(e, 1);
            const flags = self.readU32(e, ast_mod.ArrowExtra.flags);

            const saved_outermost_arrow = self.outermost_lowered_arrow_scope;
            if (self.arrow_this_depth == 0) self.outermost_lowered_arrow_scope = self.current_scope;
            defer self.outermost_lowered_arrow_scope = saved_outermost_arrow;
            const visited = blk: {
                // Defaults and body share the arrow's lexical this/arguments.
                self.arrow_this_depth += 1;
                defer self.arrow_this_depth -= 1;
                const params = try arrowParamsToList(self, params_idx);
                const body_temps = self.temp_var_counter;
                const body = try self.visitBodyWorkletAware(body_idx);
                break :blk .{ .params = params, .body_temps = body_temps, .body = body };
            };
            const param_list = visited.params;
            const body_temp_start = visited.body_temps;
            const new_body = visited.body;

            // expression body → { return expr; }
            var func_body = blk: {
                if (new_body.isNone()) break :blk new_body;
                const body_node = self.ast.getNode(new_body);
                if (body_node.tag != .block_statement and body_node.tag != .function_body) {
                    const ret = try self.ast.addNode(.{
                        .tag = .return_statement,
                        .span = node.span,
                        .data = .{ .unary = .{ .operand = new_body, .flags = 0 } },
                    });
                    const list = try self.ast.addNodeList(&.{ret});
                    break :blk try self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = node.span,
                        .data = .{ .list = list },
                    });
                }
                break :blk new_body;
            };
            func_body = try self.hoistArrowBodyTemps(func_body, body_temp_start, node.span, source_owner);

            // function_expression: extra = [name(0), params(1), body(2), flags(3), return_type(4)]
            const func_flags: u32 = if (flags & ast_mod.ArrowFlags.is_async != 0)
                ast_mod.FunctionFlags.is_async
            else
                0;

            const none = @intFromEnum(NodeIndex.none);
            const params_node = try self.ast.addFormalParameters(param_list, node.span);
            const new_extra = try self.ast.addExtras(&.{
                none, // name (anonymous)
                @intFromEnum(params_node),
                @intFromEnum(func_body),
                func_flags,
                none, // return_type
            });

            var result = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = node.span,
                .data = .{ .extra = new_extra },
            });

            // Plugin dispatch: worklet 등 AST 플러그인 적용
            const is_auto_worklet = self.plugins.worklet.auto_next;
            if (try self.dispatchFunctionPlugins(result, .{
                .node_idx = result,
                .node_tag = .function_expression,
                .name = null,
                .body_idx = func_body,
                .params = param_list,
                // pre-visit body 사용: __initData.code는 ES5 헬퍼 없이 생성되어야 함.
                // Hermes UI runtime이 spread/rest를 네이티브 지원하므로 ES5 변환 불필요.
                // ES5 헬퍼(예: __toConsumableArray)는 worklet이 아닌 일반 함수라
                // UI thread에서 remote function으로 직렬화되어 동기 호출 불가.
                .original_params = param_list,
                .original_body_idx = body_idx,
                .flags = func_flags,
                .source_path = self.options.jsx_filename,
                .is_auto_worklet = is_auto_worklet,
            })) |replacement| {
                result = replacement;
            }

            if (native_parameter_capture) {
                if (try findLexicalNewTargetSpan(self, source_owner)) |new_target_span| {
                    return wrapNativeParameterArrow(
                        self,
                        source_owner,
                        result,
                        node.span,
                        new_target_span,
                        native_parameter_arrow_depth == 0,
                        parent_native_parameter_arrow_owner,
                    );
                }
            }

            return result;
        }

        /// arrow params (단일 NodeIndex) → function params (NodeList) 변환.
        /// lowerAsyncArrowToStateMachine 등에서 arrow를 function으로 변환할 때 사용.
        /// visitNode로 자식을 방문한다.
        pub fn arrowParamsToList(self: *Transformer, params_idx: NodeIndex) Transformer.Error!NodeList {
            const list = try arrowParamsToListRaw(self, params_idx);
            // A cover-grammar parameter `(a = 1) =>` stays an assignment
            // expression. As a function parameter it is a default value: give
            // it the assignment-pattern shape the parameter lowering handles,
            // or ES5 output kept `function(a = 1)` (#5659).
            for (self.ast.extra_data.items[list.start .. list.start + list.len]) |*raw| {
                const param = self.ast.getNode(@enumFromInt(raw.*));
                if (param.tag != .assignment_expression) continue;
                if (param.data.binary.flags != @intFromEnum(@import("../lexer/token.zig").Kind.eq)) continue;
                raw.* = @intFromEnum(try self.ast.addNode(.{
                    .tag = .assignment_pattern,
                    .span = param.span,
                    .data = .{ .binary = .{ .left = param.data.binary.left, .right = param.data.binary.right, .flags = 0 } },
                }));
            }
            return list;
        }

        fn arrowParamsToListRaw(self: *Transformer, params_idx: NodeIndex) Transformer.Error!NodeList {
            if (params_idx.isNone()) return self.ast.addNodeList(&.{});
            const params_node = self.ast.getNode(params_idx);
            return switch (params_node.tag) {
                .formal_parameters => self.visitParameterList(params_node.data.list),
                .parenthesized_expression => blk: {
                    const inner_idx = params_node.data.unary.operand;
                    if (inner_idx.isNone()) break :blk try self.ast.addNodeList(&.{});
                    const inner = self.ast.getNode(inner_idx);
                    if (inner.tag == .sequence_expression) {
                        break :blk try self.visitParameterList(inner.data.list);
                    }
                    const new_param = try self.visitParameterNode(inner_idx);
                    break :blk try self.ast.addNodeList(if (!new_param.isNone()) &.{new_param} else &.{});
                },
                else => blk: {
                    const new_param = try self.visitParameterNode(params_idx);
                    break :blk try self.ast.addNodeList(if (!new_param.isNone()) &.{new_param} else &.{});
                },
            };
        }
    };
}

fn isDirectEvalCallee(ast: *const ast_mod.Ast, source: NodeIndex) bool {
    var idx = source;
    while (!idx.isNone() and @intFromEnum(idx) < ast.nodes.items.len) {
        const node = ast.getNode(idx);
        if (node.tag == .parenthesized_expression or ast_mod.Node.Tag.isTransparentTypeWrapper(node.tag)) {
            idx = node.data.unary.operand;
            continue;
        }
        if (node.tag != .identifier_reference) return false;
        const raw_name = ast.identifierNameText(node);
        if (std.mem.eql(u8, raw_name, "eval")) return true;
        if (std.mem.indexOfScalar(u8, raw_name, '\\') == null) return false;
        var decode_buffer: [64]u8 = undefined;
        const decoded = Scanner.decodeIdentifierEscapesInto(raw_name, &decode_buffer) orelse return false;
        return std.mem.eql(u8, decoded, "eval");
    }
    return false;
}

fn isLexicalValueBoundary(tag: Tag) bool {
    return switch (tag) {
        .function_declaration,
        .function_expression,
        .function,
        => true,
        else => false,
    };
}

fn isFunctionBoundary(tag: Tag) bool {
    return switch (tag) {
        .function_declaration,
        .function_expression,
        .function,
        .method_definition,
        .class_declaration,
        .class_expression,
        => true,
        else => false,
    };
}

fn findLexicalNewTargetSpan(
    self: anytype,
    root: NodeIndex,
) std.mem.Allocator.Error!?@import("../lexer/token.zig").Span {
    var stack: std.ArrayList(NodeIndex) = .empty;
    defer stack.deinit(self.allocator);
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer seen.deinit(self.allocator);
    try stack.append(self.allocator, root);
    while (stack.pop()) |idx| {
        if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;
        const raw = @intFromEnum(idx);
        if (seen.contains(raw)) continue;
        try seen.put(self.allocator, raw, {});
        const node = self.ast.getNode(idx);
        if (node.tag == .meta_property and node.data.none == 1) return node.span;
        if (idx != root and isFunctionBoundary(node.tag)) continue;
        var children = ast_walk.children(self.ast, node);
        while (children.next()) |child| try stack.append(self.allocator, child);
    }
    return null;
}

fn isDirectDefaultArrow(self: anytype, source_owner: NodeIndex) bool {
    if (self.native_parameter_default_root.isNone()) return false;
    var root = self.native_parameter_default_root;
    while (!root.isNone() and self.ast.getNode(root).tag == .parenthesized_expression) {
        root = self.ast.getNode(root).data.unary.operand;
    }
    return root == source_owner;
}

fn wrapNativeParameterArrow(
    self: anytype,
    source_owner: NodeIndex,
    lowered_arrow: NodeIndex,
    span: @import("../lexer/token.zig").Span,
    new_target_span: @import("../lexer/token.zig").Span,
    is_outermost_native_parameter_arrow: bool,
    parent_native_parameter_arrow_owner: NodeIndex,
) !NodeIndex {
    const arrow_scope = self.outputOwnedScope(source_owner) orelse self.current_scope;
    // Share the same scoped spelling choice with the refs created while this
    // arrow is visited. In particular, this generated parameter must not
    // shadow a source parameter such as `_newTarget` in the enclosing
    // parameter environment.
    const output_name: es_helpers.ScopedSyntheticOutputName = if (self.semantic_edit_enabled)
        try es_helpers.resolveScopedSyntheticOutputName(self, "_newTarget", arrow_scope)
    else
        .{ .name = try es_helpers.resolveSyntheticName(self, "_newTarget"), .late = false };
    const name = output_name.name;
    const binding = try es_helpers.makeExactSyntheticBinding(self, name);
    const params = try self.ast.addFormalParameters(try self.ast.addNodeList(&.{binding}), span);

    var return_value = lowered_arrow;
    if (is_outermost_native_parameter_arrow and isDirectDefaultArrow(self, source_owner)) {
        if (self.native_parameter_name_hint) |inferred_name| {
            // A direct anonymous function default gets its name from the
            // parameter binding. Keep that NamedEvaluation after adding the
            // lexical capture factory.
            const key = try es_helpers.makePropertyName(self, inferred_name);
            const property = try self.ast.addNode(.{
                .tag = .object_property,
                .span = span,
                .data = .{ .binary = .{ .left = key, .right = lowered_arrow, .flags = 0 } },
            });
            const object = try self.ast.addNode(.{
                .tag = .object_expression,
                .span = span,
                .data = .{ .list = try self.ast.addNodeList(&.{property}) },
            });
            const access_key = try es_helpers.makePropertyName(self, inferred_name);
            return_value = try es_helpers.makeStaticMember(self, object, access_key, span);
        }
    }

    const return_stmt = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = return_value, .flags = 0 } },
    });
    const wrapper_body = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = try self.ast.addNodeList(&.{return_stmt}) },
    });
    const wrapper_extra = try self.ast.addExtras(&.{
        @intFromEnum(NodeIndex.none),
        @intFromEnum(params),
        @intFromEnum(wrapper_body),
        0,
        @intFromEnum(NodeIndex.none),
    });
    const wrapper = try self.ast.addNode(.{
        .tag = .function_expression,
        .span = span,
        .data = .{ .extra = wrapper_extra },
    });

    const parent_scope = self.outputScopeParent(arrow_scope);
    const wrapper_scope = try self.addGeneratedFunctionScope(parent_scope, wrapper);
    try self.reparentGeneratedScope(arrow_scope, wrapper_scope);
    const wrapper_symbol = try self.declareSyntheticInScope(binding, span, .parameter, wrapper_scope);
    if (output_name.late) {
        const symbol_id = wrapper_symbol orelse std.debug.panic("late native parameter _newTarget binding has no SymbolId", .{});
        es_helpers.markStandaloneLateSyntheticSymbol(self, symbol_id, .new_target_capture_binding);
    }
    try self.bindNativeParameterArrowRefs(source_owner, wrapper_symbol);
    try self.remapCopiedScopeOwner(source_owner, lowered_arrow);

    const capture_value = if (is_outermost_native_parameter_arrow) blk: {
        if (self.options.unsupported.new_target) {
            // Retained class constructors can be derived, where `this` is not
            // initialized yet while parameters run. Preserve the native
            // meta-property at this boundary instead of lowering it to
            // `this.constructor`.
            if (!self.options.unsupported.class and self.new_target_ctx == .constructor) {
                break :blk try self.ast.addNode(.{
                    .tag = .meta_property,
                    .span = new_target_span,
                    .data = .{ .none = 1 },
                });
            }
            break :blk try self.lowerNewTarget(span);
        }
        break :blk try self.ast.addNode(.{
            .tag = .meta_property,
            .span = new_target_span,
            .data = .{ .none = 1 },
        });
    } else blk: {
        const ref = if (self.semantic_edit_enabled)
            try es_helpers.makeExactSyntheticRef(self, name)
        else
            try es_helpers.makeSyntheticRef(self, "_newTarget");
        try self.trackNativeParameterArrowRef(parent_native_parameter_arrow_owner, ref);
        break :blk ref;
    };
    const call = try es_helpers.makeCallExpr(self, wrapper, &.{capture_value}, span);
    return call;
}

test "ES2015 arrow module compiles" {
    _ = ES2015Arrow;
}
