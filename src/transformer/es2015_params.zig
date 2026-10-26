//! ES2015 다운레벨링: default parameters + rest parameters
//!
//! --target < es2015 일 때 활성화.
//!
//! Default parameters:
//!   function f(x = 1) {} → function f(x) { x = x === void 0 ? 1 : x; }
//!
//! Rest parameters:
//!   function f(a, ...rest) {} → function f(a) { var rest = [].slice.call(arguments, 1); }
//!
//! 두 변환 모두 파라미터 목록을 수정하고 함수 바디 앞에 문을 삽입한다.
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-function-definitions (ES2015, default/rest)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/parameters.rs (~845줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go (lowerFunction)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const SymbolKind = @import("../semantic/symbol.zig").SymbolKind;
const ScopeKind = @import("../semantic/scope.zig").ScopeKind;
const ScopeId = @import("../semantic/scope.zig").ScopeId;

/// Ephemeral ownership proof from the caller's current AST, never persisted
/// or reconstructed from an identifier spelling.
pub const RestArgumentsOwner = struct {
    ast_owner: *const ast_mod.Ast,
    function_node: NodeIndex,
    params_node: NodeIndex,
    body_scope: @import("../semantic/scope.zig").ScopeId,
};

pub const NativeArgumentShadow = struct {
    ast_owner: *const ast_mod.Ast,
    function_owner: NodeIndex,
    body_scope: ScopeId,
    block: NodeIndex = .none,
    scope: ScopeId,
    source_symbol: u32,
    native_symbol: ?u32 = null,
    source_declaration: NodeIndex = .none,
};

const NativeArgumentsShape = struct {
    owner: RestArgumentsOwner,
    has_expressions: bool,
    first_default: u32,
    source_tail_binding: NodeIndex = .none,
    source_tail_id: ?u32 = null,
};

pub fn ES2015Params(comptime Transformer: type) type {
    return struct {
        /// The emitted formal parameter and body declarations have different
        /// SymbolKinds. Register each binding before emitting references to it.
        fn registerDestructuringTempIdentityAtCreation(
            self: *Transformer,
            binding: NodeIndex,
            name_span: Span,
            declaration_span: Span,
            kind: SymbolKind,
        ) Transformer.Error!es_helpers.TempIdentityCapture {
            return registerDestructuringTempIdentityInScope(self, binding, name_span, declaration_span, kind, self.current_scope);
        }

        fn registerDestructuringTempIdentityInScope(
            self: *Transformer,
            binding: NodeIndex,
            name_span: Span,
            declaration_span: Span,
            kind: SymbolKind,
            scope: ScopeId,
        ) Transformer.Error!es_helpers.TempIdentityCapture {
            if (!self.semantic_edit_enabled) return .{ .span = name_span };
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            if (scope.isNone() or scope.toIndex() >= scopes.len or scopes[scope.toIndex()].kind != ScopeKind.function)
                std.debug.panic("destructuring parameter temp requires an active function scope", .{});
            const id = if (kind == .variable_var)
                try self.declareSyntheticTempInScope(binding, declaration_span, scope)
            else
                try self.declareSyntheticInScope(binding, declaration_span, kind, scope);
            const symbol_id = id orelse std.debug.panic("destructuring parameter temp has no creation SymbolId", .{});
            if (kind == .parameter) es_helpers.markStandaloneLateSyntheticTemp(self, symbol_id, scope);
            const raw_id = @backingInt(symbol_id);
            const binding_id = self.getSymbolIdAt(binding) orelse
                std.debug.panic("destructuring parameter temp binding missed its creation SymbolId", .{});
            if (binding_id != raw_id)
                std.debug.panic("destructuring parameter temp binding missed its creation SymbolId", .{});
            const editor = if (self.semantic_editor) |*editor| editor else std.debug.panic("destructuring parameter temp was not registered in the semantic editor", .{});
            if (raw_id >= editor.symbols.items.len)
                std.debug.panic("destructuring parameter temp SymbolId is outside the semantic editor", .{});
            const symbol = editor.symbols.items[raw_id];
            if (symbol.scope_id != scope or symbol.kind != kind)
                std.debug.panic("destructuring parameter temp SymbolId has the wrong owner", .{});
            self.forgetSyntheticTempSymbolLookup(name_span, scope);
            return .{ .span = name_span, .symbol_id = symbol_id, .reference_scope = scope };
        }

        fn emitParameterPatternDeclarators(
            self: *Transformer,
            pattern: Node,
            read_identity: es_helpers.TempIdentityCapture,
            span: Span,
        ) Transformer.Error!void {
            const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
            const declaration_start = self.scratch.items.len;
            try es2015_destruct.emitPatternDeclaratorsWithIdentity(self, pattern, read_identity, span, .@"var");
            // These bindings no longer occur in the formal parameter list.
            // Preserve each source identity while moving its storage to the
            // function body that owns the emitted var declaration.
            if (self.semantic_edit_enabled) {
                for (self.scratch.items[declaration_start..]) |declarator| {
                    const node = self.ast.getNode(declarator);
                    if (node.tag != .variable_declarator) continue;
                    const binding = self.ast.readExtraNode(node.data.extra, 0);
                    var bindings = try ast_walk.bindingIdentifiers(self.allocator, self.ast, binding, .{});
                    defer bindings.deinit();
                    while (try bindings.next()) |leaf| {
                        const id = self.getSymbolIdAt(leaf) orelse continue;
                        if (self.semantic_editor.?.symbols.items[id].kind != .parameter) continue;
                        // Only this pattern binding moves. A same-SID body
                        // function still owns its distinct declaration anchor
                        // until its FDI value is emitted or explicitly retired.
                        self.semantic_editor.?.relocateSymbolAsPreservingAnchors(@fromBackingInt(@as(u32, @intCast(id))), self.current_scope, leaf) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => std.debug.panic("parameter pattern lost its exact storage/anchor handoff: {s}", .{@errorName(err)}),
                        };
                    }
                }
            }
        }

        /// 파라미터 패턴 안에 object rest (`{a, ...r}`, ES2018) 가 있는지 검사 (#4251).
        /// default_params(ES2015) 는 지원하나 object_spread(ES2018) 만 미지원인
        /// 타겟(es2016/es2017)에서, object rest 가 든 param 만 lowering 하기 위한
        /// target-aware 게이트. (default-param-only 함수의 불필요 lowering 회피.)
        pub fn hasObjectRestParam(self: *const Transformer, params: ast_mod.NodeList) Transformer.Error!bool {
            const old_params = self.ast.extra_data.items[params.start .. params.start + params.len];
            for (old_params) |raw_idx| {
                if (try parameterHasObjectRest(self, @fromBackingInt(@intCast(raw_idx)))) return true;
            }
            return false;
        }

        /// Return the first parameter whose binding pattern needs ES2018
        /// object-rest lowering. Later parameter initializers are moved into
        /// the body to preserve the pattern's evaluation order.
        pub fn firstObjectRestParamIndex(self: *const Transformer, params: ast_mod.NodeList) Transformer.Error!?usize {
            const old_params = self.ast.extra_data.items[params.start .. params.start + params.len];
            for (old_params, 0..) |raw_idx, i| {
                if (try parameterHasObjectRest(self, @fromBackingInt(@intCast(raw_idx)))) return i;
            }
            return null;
        }

        fn parameterHasObjectRest(self: *const Transformer, param_idx: NodeIndex) Transformer.Error!bool {
            if (param_idx.isNone() or @backingInt(param_idx) >= self.ast.nodes.items.len) return false;
            const param = self.ast.getNode(param_idx);
            const pattern_idx: NodeIndex = switch (param.tag) {
                .formal_parameter => blk: {
                    const extra = param.data.extra;
                    if (extra + ast_mod.FormalParameterExtra.pattern >= self.ast.extra_data.items.len) break :blk .none;
                    break :blk @fromBackingInt(@intCast(self.ast.extra_data.items[extra + ast_mod.FormalParameterExtra.pattern]));
                },
                .assignment_pattern => param.data.binary.left,
                else => param_idx,
            };
            return bindingPatternHasObjectRest(self, pattern_idx);
        }

        /// Search only binding-pattern positions. Default expressions and computed
        /// keys may contain object spread, which does not require parameter lowering.
        fn bindingPatternHasObjectRest(self: *const Transformer, root: NodeIndex) Transformer.Error!bool {
            if (root.isNone() or @backingInt(root) >= self.ast.nodes.items.len) return false;
            var pending: std.ArrayList(NodeIndex) = .empty;
            defer pending.deinit(self.allocator);
            try pending.append(self.allocator, root);

            while (pending.pop()) |idx| {
                if (idx.isNone() or @backingInt(idx) >= self.ast.nodes.items.len) continue;
                const node = self.ast.getNode(idx);
                switch (node.tag) {
                    .formal_parameter => {
                        const extra = node.data.extra;
                        if (extra + ast_mod.FormalParameterExtra.pattern >= self.ast.extra_data.items.len) continue;
                        const pattern: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[extra + ast_mod.FormalParameterExtra.pattern]));
                        if (!pattern.isNone()) try pending.append(self.allocator, pattern);
                    },
                    .assignment_pattern => {
                        if (!node.data.binary.left.isNone()) try pending.append(self.allocator, node.data.binary.left);
                    },
                    .object_pattern => {
                        const split = self.ast.nodeListSplitRest(node.data.list);
                        if (split.rest_operand != null) return true;
                        for (split.elements) |raw_child| {
                            const child_idx: NodeIndex = @fromBackingInt(@intCast(raw_child));
                            if (child_idx.isNone() or @backingInt(child_idx) >= self.ast.nodes.items.len) continue;
                            const child = self.ast.getNode(child_idx);
                            switch (child.tag) {
                                .object_property => {
                                    const value = ast_mod.Ast.objectPropertyValue(child);
                                    if (!value.isNone()) try pending.append(self.allocator, value);
                                },
                                .binding_property => {
                                    const value = child.data.binary.right;
                                    try pending.append(self.allocator, if (value.isNone()) child.data.binary.left else value);
                                },
                                else => try pending.append(self.allocator, child_idx),
                            }
                        }
                    },
                    .array_pattern => {
                        const split = self.ast.nodeListSplitRest(node.data.list);
                        for (split.elements) |raw_child| {
                            const child: NodeIndex = @fromBackingInt(@intCast(raw_child));
                            if (!child.isNone()) try pending.append(self.allocator, child);
                        }
                        if (split.rest_operand) |rest| try pending.append(self.allocator, rest);
                    },
                    .rest_element, .binding_rest_element => {
                        if (!node.data.unary.operand.isNone()) try pending.append(self.allocator, node.data.unary.operand);
                    },
                    .object_property => {
                        const value = ast_mod.Ast.objectPropertyValue(node);
                        if (!value.isNone()) try pending.append(self.allocator, value);
                    },
                    else => {},
                }
            }
            return false;
        }

        /// 파라미터 목록에서 default/rest 파라미터가 있는지 검사한다.
        pub fn hasDefaultOrRest(self: *const Transformer, params: ast_mod.NodeList) bool {
            const old_params = self.ast.extra_data.items[params.start .. params.start + params.len];
            for (old_params) |raw_idx| {
                const param = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                if (param.tag == .spread_element or param.tag == .rest_element) return true;
                // destructuring 파라미터도 ES5 변환 필요
                if (param.tag == .object_pattern or param.tag == .array_pattern) return true;
                if (param.tag == .formal_parameter) {
                    const extras = self.ast.extra_data.items;
                    const pe = param.data.extra;
                    const default_val: NodeIndex = @fromBackingInt(@intCast(extras[pe + 2]));
                    if (!default_val.isNone()) return true;
                    // formal_parameter 안의 destructuring 패턴도 체크
                    const pattern_idx: NodeIndex = @fromBackingInt(@intCast(extras[pe]));
                    const pattern_node = self.ast.getNode(pattern_idx);
                    if (pattern_node.tag == .object_pattern or pattern_node.tag == .array_pattern) return true;
                }
                if (param.tag == .assignment_pattern) return true;
                // An arrow's cover-grammar parameter `(a = 1) =>` stays an
                // assignment expression; in a parameter list it is a default (#5659).
                if (param.tag == .assignment_expression and
                    param.data.binary.flags == @backingInt(token_mod.Kind.eq)) return true;
            }
            return false;
        }

        /// default/rest 파라미터를 변환한다.
        /// 파라미터 목록에서 default와 rest를 제거하고,
        /// 함수 바디 앞에 초기화 문을 삽입한다.
        ///
        /// pass2=true: Pass 2에서 호출. 노드가 이미 visited 상태이므로
        /// visitNode 대신 인덱스를 그대로 사용한다.
        ///
        /// 반환: { new_params, body_prepend_stmts }
        pub fn lowerParams(
            self: *Transformer,
            params: ast_mod.NodeList,
            span: Span,
        ) Transformer.Error!LowerResult {
            return lowerParamsImpl(self, params, span, false, null, null, null, null);
        }

        pub fn lowerParamsPass2(
            self: *Transformer,
            params: ast_mod.NodeList,
            span: Span,
        ) Transformer.Error!LowerResult {
            return lowerParamsImpl(self, params, span, true, null, null, null, null);
        }

        /// Structural mistakes are not an invitation to create a global.
        /// Valid but unsupported source environments retain the existing path.
        pub fn restArgumentsOwner(
            self: *Transformer,
            params: NodeList,
            owner: RestArgumentsOwner,
        ) error{InvalidRestArgumentsOwner}!?RestArgumentsOwner {
            if (!self.semantic_edit_enabled) return null;
            if (owner.ast_owner != self.ast or owner.function_node.isNone() or owner.params_node.isNone() or owner.body_scope.isNone() or
                @backingInt(owner.function_node) >= self.ast.nodes.items.len or @backingInt(owner.params_node) >= self.ast.nodes.items.len)
                return error.InvalidRestArgumentsOwner;
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            const maps = if (self.semantic_editor) |*editor| editor.scope_maps.items else self.scope_maps;
            const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
            if (owner.body_scope.toIndex() >= scopes.len or owner.body_scope.toIndex() >= maps.len or
                scopes[owner.body_scope.toIndex()].kind != .function or self.outputOwnedScope(owner.function_node) != owner.body_scope or
                self.current_scope != owner.body_scope)
                return error.InvalidRestArgumentsOwner;
            const function = self.ast.getNode(owner.function_node);
            const params_offset: u32 = switch (function.tag) {
                .function_declaration, .function_expression, .function, .method_definition => ast_mod.FunctionExtra.params,
                .arrow_function_expression => ast_mod.ArrowExtra.params,
                else => return error.InvalidRestArgumentsOwner,
            };
            if (!self.ast.hasExtra(function.data.extra, params_offset) or self.ast.readExtraNode(function.data.extra, params_offset) != owner.params_node)
                return error.InvalidRestArgumentsOwner;
            const formal = self.ast.getNode(owner.params_node);
            if (formal.tag != .formal_parameters or formal.data.list.start != params.start or formal.data.list.len != params.len or
                params.start > self.ast.extra_data.items.len or params.len > self.ast.extra_data.items.len - params.start)
                return error.InvalidRestArgumentsOwner;
            if (function.tag == .arrow_function_expression) return null;
            const raw_flags = if (self.ast.hasExtra(function.data.extra, ast_mod.FunctionExtra.flags)) self.ast.readExtra(function.data.extra, ast_mod.FunctionExtra.flags) else return error.InvalidRestArgumentsOwner;
            const flags = if (function.tag == .method_definition) ast_mod.methodFlagsToFunctionFlags(raw_flags) else raw_flags;
            if (flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator) != 0) return null;
            if (self.outputOwnedScope(owner.params_node)) |parameter_scope| {
                if (parameter_scope != owner.body_scope) {
                    if (parameter_scope.isNone() or parameter_scope.toIndex() >= scopes.len or scopes[parameter_scope.toIndex()].kind != .function or
                        scopes[owner.body_scope.toIndex()].parent != parameter_scope) return error.InvalidRestArgumentsOwner;
                    return null;
                }
            }
            // A scope-map spelling is only a collision veto. Typed role rows
            // select the engine, and makeNativeArgumentsRef creates its read.
            const slot = maps[owner.body_scope.toIndex()].get("arguments");
            var engine: ?usize = null;
            for (symbols, 0..) |symbol, sid| {
                if (symbol.scope_id != owner.body_scope or symbol.synthetic_kind != .implicit_arguments) continue;
                if (engine != null or slot != sid) return error.InvalidRestArgumentsOwner;
                engine = sid;
                if (symbol.kind != .parameter and symbol.kind != .variable_var) return error.InvalidRestArgumentsOwner;
            }
            if (slot) |sid| {
                if (sid >= symbols.len or symbols[sid].scope_id != owner.body_scope) return error.InvalidRestArgumentsOwner;
                const symbol = symbols[sid];
                if (symbol.synthetic_kind == .implicit_arguments) {
                    if (engine != sid) return error.InvalidRestArgumentsOwner;
                    if (symbol.kind == .variable_var) return null;
                } else {
                    if (symbol.synthetic_kind != null) return error.InvalidRestArgumentsOwner;
                    return null;
                }
            }
            return owner;
        }

        pub fn lowerParamsPass2ForFunction(self: *Transformer, params: NodeList, span: Span, owner: RestArgumentsOwner) Transformer.Error!LowerResult {
            const native_owner = restArgumentsOwner(self, params, owner) catch
                @panic("rest parameter producer has invalid actual function ownership");
            const shape = try planNativeArgumentsShape(self, params, owner);
            const native_formal_scope = try plannedNativeFormalScope(self, params, owner, shape);
            return lowerParamsImpl(self, params, span, true, native_owner, native_formal_scope, shape, owner);
        }

        fn retainsNativeNonSimpleSyntax(self: *Transformer, params: NodeList) Transformer.Error!bool {
            var seen_object_rest = false;
            var retains_native_environment = false;
            for (0..params.len) |offset| {
                const index = self.ast.readExtraNode(params.start, @intCast(offset));
                const param = self.ast.getNode(index);
                if (param.tag == .spread_element or param.tag == .rest_element) {
                    retains_native_environment = true;
                    break;
                }
                const has_object_rest = try parameterHasObjectRest(self, index);
                if (!seen_object_rest and !has_object_rest) {
                    if (@import("native_constructor_timing.zig").simpleFormalBinding(self, index) == null) retains_native_environment = true;
                    continue;
                }
                if (has_object_rest) seen_object_rest = true;
                if (param.tag == .formal_parameter and !self.ast.readExtraNode(param.data.extra, ast_mod.FormalParameterExtra.default).isNone()) retains_native_environment = true;
                if (param.tag == .assignment_pattern and try bindingPatternHasObjectRest(self, param.data.binary.left)) retains_native_environment = true;
            }
            return retains_native_environment;
        }

        fn planNativeArgumentsShape(self: *Transformer, params: NodeList, owner: RestArgumentsOwner) Transformer.Error!?NativeArgumentsShape {
            if (!self.semantic_edit_enabled or self.options.unsupported.default_params or
                !(try hasObjectRestParam(self, params)) or try retainsNativeNonSimpleSyntax(self, params)) return null;
            const node = self.ast.getNode(owner.function_node);
            switch (node.tag) {
                .function, .function_declaration, .function_expression => {},
                else => return null,
            }
            if (self.ast.readExtra(node.data.extra, ast_mod.FunctionExtra.flags) & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator) != 0) return null;
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            if (owner.body_scope.isNone() or owner.body_scope.toIndex() >= scopes.len or scopes[owner.body_scope.toIndex()].kind != .function)
                @panic("native argument shape has no ordinary body scope");
            if (scopes[owner.body_scope.toIndex()].is_strict) return null;
            const expressions = try ast_walk.parameterListHasExpressions(self.allocator, self.ast, params);
            const old_scope = self.outputOwnedScope(owner.params_node);
            if (expressions) {
                const parameter_scope = old_scope orelse @panic("native argument shape lost its split parameter environment");
                if (parameter_scope.isNone() or parameter_scope == owner.body_scope or parameter_scope.toIndex() >= scopes.len or
                    scopes[parameter_scope.toIndex()].kind != .function or scopes[owner.body_scope.toIndex()].parent != parameter_scope)
                    @panic("native argument shape has an invalid parameter/body scope pair");
            } else if (old_scope) |scope| {
                if (scope != owner.body_scope) @panic("expression-free native parameters unexpectedly have a split environment");
            }
            var cutoff = params.len;
            for (0..params.len) |offset| {
                const param = self.ast.getNode(self.ast.readExtraNode(params.start, @intCast(offset)));
                const has_default = if (param.tag == .assignment_pattern) true else if (param.tag == .formal_parameter)
                    !self.ast.readExtraNode(param.data.extra, ast_mod.FormalParameterExtra.default).isNone()
                else
                    false;
                if (has_default) {
                    cutoff = @intCast(offset);
                    break;
                }
            }
            var source_tail: NodeIndex = .none;
            var source_tail_id: ?u32 = null;
            if (!expressions or cutoff == params.len) {
                const nodes = try ast_walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, owner.params_node);
                defer self.allocator.free(nodes);
                find_rest: for (nodes) |raw| {
                    const pattern = self.ast.nodes.items[raw];
                    if (pattern.tag != .object_pattern) continue;
                    for (0..pattern.data.list.len) |offset| {
                        const member = self.ast.getNode(self.ast.readExtraNode(pattern.data.list.start, @intCast(offset)));
                        if (member.tag != .rest_element and member.tag != .spread_element) continue;
                        const binding = member.data.unary.operand;
                        if (self.ast.getNode(binding).tag != .binding_identifier) @panic("object rest tail has no exact source binding");
                        const id = self.getSymbolIdAt(binding) orelse @panic("object rest tail has no source identity");
                        const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                        const expected_scope = if (expressions) old_scope.? else owner.body_scope;
                        if (symbols[id].kind != .parameter or symbols[id].scope_id != expected_scope) @panic("native tail cannot reuse another parameter environment");
                        source_tail = binding;
                        source_tail_id = id;
                        break :find_rest;
                    }
                }
                if (source_tail_id == null) @panic("expression-free object rest has no native tail carrier");
            }
            return .{ .owner = owner, .has_expressions = expressions, .first_default = cutoff, .source_tail_binding = source_tail, .source_tail_id = source_tail_id };
        }

        /// Plan the environment of the actual emitted native formals before
        /// any destructuring temporary is declared.
        fn plannedNativeFormalScope(self: *Transformer, params: NodeList, owner: RestArgumentsOwner, shape: ?NativeArgumentsShape) Transformer.Error!?ScopeId {
            if (!self.semantic_edit_enabled or self.options.unsupported.default_params) return null;
            if (!(try retainsNativeNonSimpleSyntax(self, params)) and !(if (shape) |plan| plan.has_expressions else false)) return null;
            if (owner.ast_owner != self.ast or owner.function_node.isNone() or owner.params_node.isNone() or
                self.outputOwnedScope(owner.function_node) != owner.body_scope)
                @panic("native formal planner has no exact ordinary function owner");
            const function = self.ast.getNode(owner.function_node);
            switch (function.tag) {
                .function, .function_expression, .function_declaration, .method_definition => {},
                else => @panic("native formal planner requires an ordinary function"),
            }
            const formals = self.ast.getNode(owner.params_node);
            if (self.ast.readExtraNode(function.data.extra, ast_mod.FunctionExtra.params) != owner.params_node or
                formals.tag != .formal_parameters or formals.data.list.start != params.start or formals.data.list.len != params.len)
                @panic("native formal planner lost its actual parameter edge");
            // Rest-only lists have no separate source parameter environment.
            // This API only transfers an existing, exact split carrier.
            const scope = self.outputOwnedScope(owner.params_node) orelse return null;
            const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
            if (scope.isNone() or owner.body_scope.isNone() or scope.toIndex() >= scopes.len or owner.body_scope.toIndex() >= scopes.len or
                scopes[scope.toIndex()].kind != .function or scopes[owner.body_scope.toIndex()].kind != .function or scopes[owner.body_scope.toIndex()].parent != scope)
                @panic("native formal planner has no exact parameter/body scope pair");
            return scope;
        }

        /// A lowered wrapper already recorded this exact source-parameter
        /// engine handoff. Default reads consume its SID before the driver
        /// replaces the formals; they do not create or rediscover an engine.
        pub fn unlinkedArgumentsOwner(self: *Transformer, params: NodeList, owner: RestArgumentsOwner) error{InvalidRestArgumentsOwner}!?@import("../semantic/symbol.zig").SymbolId {
            _ = try restArgumentsOwner(self, params, owner);
            if (!self.semantic_edit_enabled) return null;
            const function = self.ast.getNode(owner.function_node);
            if (function.tag == .arrow_function_expression) return null;
            const raw_flags = self.ast.readExtra(function.data.extra, ast_mod.FunctionExtra.flags);
            const flags = if (function.tag == .method_definition) ast_mod.methodFlagsToFunctionFlags(raw_flags) else raw_flags;
            if (flags & (ast_mod.FunctionFlags.is_async | ast_mod.FunctionFlags.is_generator) != 0) return null;
            var selected: ?u32 = null;
            var plans = self.native_arguments_parameter_handoffs.iterator();
            while (plans.next()) |entry| {
                const plan = entry.value_ptr.*;
                if (plan.params != owner.params_node) continue;
                if (selected != null or plan.body_scope != owner.body_scope or
                    self.outputOwnedScope(owner.params_node) != plan.source_scope)
                    return error.InvalidRestArgumentsOwner;
                const editor = &self.semantic_editor.?;
                const id = entry.key_ptr.*;
                if (id >= editor.symbols.items.len or plan.source_scope.isNone() or
                    plan.source_scope.toIndex() >= editor.scopes.items.len or
                    plan.source_scope.toIndex() >= editor.scope_maps.items.len or
                    editor.scopes.items[owner.body_scope.toIndex()].parent != plan.source_scope or
                    self.native_arguments_declaration_origins.get(id) != plan.source_scope)
                    return error.InvalidRestArgumentsOwner;
                const symbol = editor.symbols.items[id];
                if (symbol.scope_id != plan.source_scope or symbol.synthetic_kind != .implicit_arguments or
                    symbol.kind != .parameter or symbol.write_count != 0 or
                    editor.scope_maps.items[plan.source_scope.toIndex()].get("arguments") != @as(?usize, id) or
                    editor.scope_maps.items[owner.body_scope.toIndex()].get("arguments") != null)
                    return error.InvalidRestArgumentsOwner;
                var existing_read = false;
                var origins = self.native_arguments_reference_origins.iterator();
                while (origins.next()) |origin| {
                    if (@backingInt(origin.value_ptr.symbol_id) != id) continue;
                    if (origin.value_ptr.owner_scope != plan.source_scope or origin.value_ptr.scope != owner.body_scope)
                        return error.InvalidRestArgumentsOwner;
                    if ((@import("native_arguments.zig").publication(self, origin.key_ptr.*) catch return error.InvalidRestArgumentsOwner) == null or
                        !std.meta.eql(origin.value_ptr.flags, @as(@import("../semantic/symbol.zig").ReferenceFlags, .{ .read = true })))
                        return error.InvalidRestArgumentsOwner;
                    existing_read = true;
                }
                if (!existing_read) return error.InvalidRestArgumentsOwner;
                selected = id;
            }
            return if (selected) |id| @fromBackingInt(id) else null;
        }

        fn lowerParamsImpl(
            self: *Transformer,
            params: ast_mod.NodeList,
            span: Span,
            comptime pass2: bool,
            rest_owner: ?RestArgumentsOwner,
            native_formal_scope: ?ScopeId,
            argument_shape: ?NativeArgumentsShape,
            function_owner: ?RestArgumentsOwner,
        ) Transformer.Error!LowerResult {
            const param_scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(param_scratch_top);

            var body_stmts: std.ArrayList(NodeIndex) = .empty;
            const unlinked_engine = if (self.unlinked_parameter_bindings != null and function_owner != null)
                unlinkedArgumentsOwner(self, params, function_owner.?) catch @panic("unlinked parameter lost its native arguments handoff")
            else
                null;
            var argument_shadow: ?NativeArgumentShadow = null;
            if (argument_shape) |shape| if (shape.has_expressions and shape.first_default == params.len) {
                if (shape.owner.ast_owner != self.ast or shape.owner.body_scope != self.current_scope or self.outputOwnedScope(shape.owner.function_node) != self.current_scope) @panic("native parameter shadow lost its actual source owner");
                var plan: NativeArgumentShadow = .{ .ast_owner = self.ast, .function_owner = shape.owner.function_node, .body_scope = self.current_scope, .scope = self.current_scope, .source_symbol = shape.source_tail_id orelse @panic("native parameter shadow has no source rest cell") };
                const body = self.ast.functionBodyBlock(self.ast.getNode(shape.owner.function_node)) orelse @panic("native parameter shadow has no actual source body");
                const needs_body_wrapper = !self.options.unsupported.arrow and try @import("parameter_environment.zig").functionBodyHasDynamicLookup(self, self.current_scope, body);
                if (!self.options.unsupported.block_scoping and needs_body_wrapper) {
                    plan.block = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
                    plan.scope = try self.addGeneratedScope(self.current_scope, plan.block, .block);
                    const editor = &self.semantic_editor.?;
                    const source = editor.scopes.items[plan.body_scope.toIndex()];
                    editor.scopes.items[plan.scope.toIndex()].subtree_has_direct_eval = source.subtree_has_direct_eval;
                    editor.scopes.items[plan.scope.toIndex()].subtree_has_with = source.subtree_has_with;
                }
                argument_shadow = plan;
            };

            var param_index: usize = 0; // arguments index tracking
            var param_tdz_names: std.ArrayList(Span) = .empty;
            defer param_tdz_names.deinit(self.allocator);
            const name_starts = try self.allocator.alloc(usize, params.len);
            defer self.allocator.free(name_starts);

            var name_i: u32 = 0;
            while (name_i < params.len) : (name_i += 1) {
                name_starts[name_i] = param_tdz_names.items.len;
                const raw_idx = self.ast.extra_data.items[params.start + name_i];
                try collectBindingNames(self, @fromBackingInt(@intCast(raw_idx)), &param_tdz_names);
            }

            // pass2에서는 노드가 이미 visited 상태이므로 인덱스를 그대로 사용
            const maybeVisit = struct {
                fn call(t: *Transformer, idx: NodeIndex) Transformer.Error!NodeIndex {
                    if (pass2) return idx;
                    return t.visitNode(idx);
                }
            }.call;

            var object_rest_seen = false;
            // Unlinked parameters (#5668) from the first default on read `arguments`.
            var unlinked_after_default = false;
            var i_loop: u32 = 0;
            while (i_loop < params.len) : (i_loop += 1) {
                const raw_idx = self.ast.extra_data.items[params.start + i_loop];
                const param = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));

                if (param.tag == .spread_element or param.tag == .rest_element) {
                    // #4251: rest parameter(`...args`)는 ES2015 — default_params 지원
                    // 타겟(es2016/es2017)에선 native 유지. arguments 기반 lowering 은
                    // arrow 에 arguments 가 없어 ReferenceError(이 경로가 es2017 에서
                    // 도는 건 object_spread 만 미지원이라 object rest 때문). es5(default_
                    // params 미지원)만 `var args = [].slice.call(arguments, N)`.
                    if (!self.options.unsupported.default_params) {
                        const new_rest = try maybeVisit(self, @fromBackingInt(@intCast(raw_idx)));
                        try self.scratch.append(self.allocator, new_rest);
                        continue;
                    }
                    // rest parameter: ...args → var args = [].slice.call(arguments, N)
                    const rest_binding = try maybeVisit(self, param.data.unary.operand);
                    const rest_tag = self.ast.getNode(rest_binding).tag;
                    if (rest_tag == .object_pattern or rest_tag == .array_pattern) {
                        // `...[c, d = c]`: the slice goes to a temp and the pattern
                        // reads it, like a destructured parameter. A pattern left on
                        // the `var` stayed ES2015 syntax (#5668).
                        try buildRestPatternParam(self, rest_binding, param_index, &body_stmts, span, rest_owner);
                        continue;
                    }
                    const rest_stmt = try buildRestSlice(self, rest_binding, param_index, span, rest_owner);
                    try body_stmts.append(self.allocator, rest_stmt);
                    // rest를 params에 넣지 않음
                    continue;
                }

                if (self.unlinked_parameter_bindings) |unlinked| {
                    if (unlinkableParameter(self, param, @fromBackingInt(@intCast(raw_idx)))) |parts| {
                        // Before the first default: formal `_x`, body `var x = _x`.
                        // From it on (outside `length`, like native): body
                        // `var a = arguments[i] === void 0 ? d : arguments[i]`.
                        const binding = try maybeVisit(self, parts.binding);
                        const default_value = if (parts.default.isNone()) NodeIndex.none else blk: {
                            const visited_default = try maybeVisit(self, parts.default);
                            try es_helpers.rewriteTDZReferences(self, visited_default, param_tdz_names.items[name_starts[i_loop]..]);
                            break :blk visited_default;
                        };
                        if (!default_value.isNone()) unlinked_after_default = true;
                        var temp_span: Span = undefined;
                        var temp_identity: es_helpers.TempIdentityCapture = .{ .span = Span.EMPTY };
                        if (!unlinked_after_default) {
                            temp_span = try es_helpers.makeTempVarSpan(self);
                            const temp_binding = try es_helpers.makeSyntheticBinding(self, temp_span);
                            temp_identity = try registerDestructuringTempIdentityAtCreation(
                                self,
                                temp_binding,
                                temp_span,
                                span,
                                .parameter,
                            );
                            es_helpers.consumeTempVarSpan(self, temp_span);
                            try self.scratch.append(self.allocator, temp_binding);
                        }
                        const read = struct {
                            fn call(t: *Transformer, from_arguments: bool, temp: es_helpers.TempIdentityCapture, index: usize, at: Span, engine: ?@import("../semantic/symbol.zig").SymbolId) Transformer.Error!NodeIndex {
                                if (!from_arguments) return es_helpers.makeTempRefFromIdentity(t, temp, at, .{ .read = true });
                                const arguments = if (engine) |id| blk: {
                                    const reference = try t.makeSyntheticRefForSymbol(id, t.current_scope, .{ .read = true });
                                    const owner_scope = t.semantic_editor.?.symbols.items[@backingInt(id)].scope_id;
                                    try @import("native_arguments.zig").recordReference(t, reference, id, owner_scope, t.current_scope);
                                    break :blk reference;
                                } else try es_helpers.makeGlobalRef(t, "arguments");
                                return es_helpers.makeComputedMember(t, arguments, try es_helpers.makeNumericLiteral(t, @intCast(index)), at);
                            }
                        }.call;
                        const value = if (default_value.isNone())
                            try read(self, unlinked_after_default, temp_identity, param_index, span, unlinked_engine)
                        else blk: {
                            const is_undefined = try self.ast.addNode(.{
                                .tag = .binary_expression,
                                .span = span,
                                .data = .{ .binary = .{ .left = try read(self, true, temp_identity, param_index, span, unlinked_engine), .right = try es_helpers.makeVoidZero(self, span), .flags = @backingInt(token_mod.Kind.eq3) } },
                            });
                            break :blk try self.ast.addNode(.{
                                .tag = .conditional_expression,
                                .span = span,
                                .data = .{ .ternary = .{ .a = is_undefined, .b = default_value, .c = try read(self, true, temp_identity, param_index, span, unlinked_engine) } },
                            });
                        };
                        try body_stmts.append(self.allocator, try es_helpers.makeVarDeclaration(self, &.{try es_helpers.makeDeclarator(self, binding, value, span)}, .@"var", span));
                        try unlinked.append(self.allocator, binding);
                        param_index += 1;
                        continue;
                    }
                }

                // ES2016/2017 keep native default/destructuring parameters. Only
                // parameters before the first ES2018 object-rest parameter can
                // stay native. Parameters after it must keep body-lowering order
                // because their initializers run after that parameter's pattern.
                const has_object_rest = if (self.options.unsupported.default_params)
                    false
                else
                    try parameterHasObjectRest(self, @fromBackingInt(@intCast(raw_idx)));
                if (!self.options.unsupported.default_params and !object_rest_seen and !has_object_rest) {
                    const kept = try maybeVisit(self, @fromBackingInt(@intCast(raw_idx)));
                    if (!kept.isNone()) try self.scratch.append(self.allocator, kept);
                    param_index += 1;
                    continue;
                }
                if (has_object_rest) object_rest_seen = true;

                if (param.tag == .formal_parameter) {
                    const pe = param.data.extra;
                    const pattern_idx: NodeIndex = self.readNodeIdx(pe, ast_mod.FormalParameterExtra.pattern);
                    const default_idx: NodeIndex = self.readNodeIdx(pe, ast_mod.FormalParameterExtra.default);

                    if (!default_idx.isNone()) {
                        if (!self.options.unsupported.default_params) {
                            const visited_pattern = try maybeVisit(self, pattern_idx);
                            const visited_default = try maybeVisit(self, default_idx);
                            try es_helpers.rewriteTDZReferences(self, visited_default, param_tdz_names.items[name_starts[i_loop]..]);
                            const temp = try buildDestructuringParam(self, visited_pattern, &body_stmts, span, native_formal_scope);
                            const extras = try self.ast.addExtras(&.{
                                @backingInt(temp),
                                @backingInt(NodeIndex.none),
                                @backingInt(visited_default),
                                self.ast.extra_data.items[pe + ast_mod.FormalParameterExtra.flags],
                                self.ast.extra_data.items[pe + ast_mod.FormalParameterExtra.deco_start],
                                self.ast.extra_data.items[pe + ast_mod.FormalParameterExtra.deco_len],
                            });
                            const lowered_param = try self.ast.addExtraNode(.formal_parameter, param.span, extras);
                            try self.scratch.append(self.allocator, lowered_param);
                            param_index += 1;
                            continue;
                        }
                        const pat_node = self.ast.getNode(pattern_idx);
                        if (pat_node.tag == .object_pattern or pat_node.tag == .array_pattern) {
                            const vp = try maybeVisit(self, pattern_idx);
                            const vd = try maybeVisit(self, default_idx);
                            try es_helpers.rewriteTDZReferences(self, vd, param_tdz_names.items[name_starts[i_loop]..]);
                            const result = try buildDestructuringDefault(self, vp, vd, &body_stmts, span);
                            try self.scratch.append(self.allocator, result);
                        } else {
                            const new_pattern = try maybeVisit(self, pattern_idx);
                            try self.scratch.append(self.allocator, new_pattern);
                            const new_default = try maybeVisit(self, default_idx);
                            try es_helpers.rewriteTDZReferences(self, new_default, param_tdz_names.items[name_starts[i_loop]..]);
                            const default_stmt = try buildDefaultCheck(self, new_pattern, new_default, span);
                            try body_stmts.append(self.allocator, default_stmt);
                        }
                        param_index += 1;
                        continue;
                    }
                }

                if (param.tag == .assignment_pattern) {
                    // assignment_pattern: binary { left=pattern, right=default }
                    const pattern_node = self.ast.getNode(param.data.binary.left);
                    if (!self.options.unsupported.default_params and
                        (try bindingPatternHasObjectRest(self, param.data.binary.left)))
                    {
                        const visited_pattern = try maybeVisit(self, param.data.binary.left);
                        const visited_default = try maybeVisit(self, param.data.binary.right);
                        try es_helpers.rewriteTDZReferences(self, visited_default, param_tdz_names.items[name_starts[i_loop]..]);
                        const temp = try buildDestructuringParam(self, visited_pattern, &body_stmts, span, native_formal_scope);
                        const lowered_param = try self.ast.addNode(.{
                            .tag = .assignment_pattern,
                            .span = param.span,
                            .data = .{ .binary = .{
                                .left = temp,
                                .right = visited_default,
                                .flags = param.data.binary.flags,
                            } },
                        });
                        try self.scratch.append(self.allocator, lowered_param);
                        param_index += 1;
                        continue;
                    }
                    if (pattern_node.tag == .object_pattern or pattern_node.tag == .array_pattern) {
                        const vp = try maybeVisit(self, param.data.binary.left);
                        const vd = try maybeVisit(self, param.data.binary.right);
                        try es_helpers.rewriteTDZReferences(self, vd, param_tdz_names.items[name_starts[i_loop]..]);
                        const result = try buildDestructuringDefault(self, vp, vd, &body_stmts, span);
                        try self.scratch.append(self.allocator, result);
                    } else {
                        const new_pattern = try maybeVisit(self, param.data.binary.left);
                        try self.scratch.append(self.allocator, new_pattern);
                        const new_default = try maybeVisit(self, param.data.binary.right);
                        try es_helpers.rewriteTDZReferences(self, new_default, param_tdz_names.items[name_starts[i_loop]..]);
                        const default_stmt = try buildDefaultCheck(self, new_pattern, new_default, span);
                        try body_stmts.append(self.allocator, default_stmt);
                    }
                    param_index += 1;
                    continue;
                }

                // destructuring 파라미터 (default 없음): temp 변수 경유
                // function View({ ref, ...props }) → function View(_param) { var {ref, ...props} = _param; }
                const param_node = self.ast.getNode(@fromBackingInt(@intCast(raw_idx)));
                const pattern_idx_raw = if (param_node.tag == .formal_parameter)
                    self.ast.extra_data.items[param_node.data.extra]
                else
                    raw_idx;
                const pattern_node = self.ast.getNode(@fromBackingInt(@intCast(pattern_idx_raw)));

                if (pattern_node.tag == .object_pattern or pattern_node.tag == .array_pattern) {
                    const result = try buildDestructuringParam(self, @fromBackingInt(@intCast(pattern_idx_raw)), &body_stmts, span, native_formal_scope);
                    try self.scratch.append(self.allocator, result);
                    param_index += 1;
                    continue;
                }

                // 일반 파라미터: 그대로 방문
                const new_param = try maybeVisit(self, @fromBackingInt(@intCast(raw_idx)));
                if (!new_param.isNone()) {
                    try self.scratch.append(self.allocator, new_param);
                }
                param_index += 1;
            }

            if (argument_shape) |shape| {
                if (self.scratch.items.len - param_scratch_top != params.len)
                    @panic("native argument shape changed its one-to-one input slots");
                for (self.scratch.items[param_scratch_top..]) |formal| {
                    if (@import("native_constructor_timing.zig").simpleFormalBinding(self, formal) == null)
                        @panic("native argument shape expected simple lowered slots");
                }
                if (shape.has_expressions and shape.first_default < params.len) {
                    const slot = param_scratch_top + shape.first_default;
                    const old = self.ast.getNode(self.scratch.items[slot]);
                    const empty = try es_helpers.makeVoidZero(self, span);
                    if (old.tag == .formal_parameter) {
                        const e = old.data.extra;
                        const extra = try self.ast.addExtras(&.{
                            @backingInt(self.ast.readExtraNode(e, ast_mod.FormalParameterExtra.pattern)),
                            @backingInt(self.ast.readExtraNode(e, ast_mod.FormalParameterExtra.type_ann)),
                            @backingInt(empty),
                            self.ast.readExtra(e, ast_mod.FormalParameterExtra.flags),
                            self.ast.readExtra(e, ast_mod.FormalParameterExtra.deco_start),
                            self.ast.readExtra(e, ast_mod.FormalParameterExtra.deco_len),
                        });
                        self.scratch.items[slot] = try self.ast.addExtraNode(.formal_parameter, old.span, extra);
                    } else {
                        self.scratch.items[slot] = try self.ast.addNode(.{ .tag = .assignment_pattern, .span = old.span, .data = .{ .binary = .{ .left = self.scratch.items[slot], .right = empty, .flags = 0 } } });
                    }
                } else {
                    const binding = if (!shape.has_expressions) source_binding: {
                        const id = shape.source_tail_id orelse @panic("native rest tail lost its source cell");
                        if (shape.source_tail_binding.isNone() or self.getSymbolIdAt(shape.source_tail_binding) != @as(?u32, id)) @panic("native rest tail changed its exact source binding");
                        const editor = if (self.semantic_editor) |*value| value else unreachable;
                        const symbol = editor.symbols.items[id];
                        if (symbol.scope_id != self.current_scope or symbol.kind != .parameter) @panic("native rest tail changed its shared storage owner");
                        const name = if (symbol.synthetic_name.len > 0) symbol.synthetic_name else self.ast.getText(symbol.name);
                        const output = try es_helpers.makeExactSyntheticBindingFromSpan(self, try self.ast.addString(name));
                        editor.attachVarRedeclaration(output, @fromBackingInt(id), self.current_scope) catch @panic("native rest formal cannot claim its source cell");
                        try self.setGeneratedSymbolId(output, id);
                        break :source_binding output;
                    } else new_binding: {
                        const plan = &argument_shadow.?;
                        const editor = if (self.semantic_editor) |*value| value else unreachable;
                        const source = editor.symbols.items[plan.source_symbol];
                        if (source.kind != .parameter or source.scope_id != self.current_scope) @panic("native parameter shadow lost its moved source cell");
                        const name = if (source.synthetic_name.len > 0) source.synthetic_name else self.ast.getText(source.name);
                        const output = try es_helpers.makeExactSyntheticBindingFromSpan(self, try self.ast.addString(name));
                        const id = (try self.declareSyntheticInScope(output, span, .parameter, native_formal_scope orelse @panic("native parameter shadow has no real parameter environment"))) orelse unreachable;
                        plan.native_symbol = @intCast(@backingInt(id));
                        break :new_binding output;
                    };
                    const formal = if (shape.has_expressions)
                        try self.ast.addNode(.{ .tag = .assignment_pattern, .span = span, .data = .{ .binary = .{ .left = binding, .right = try es_helpers.makeVoidZero(self, span), .flags = 0 } } })
                    else
                        try self.ast.addNode(.{ .tag = .rest_element, .span = span, .data = .{ .unary = .{ .operand = binding, .flags = 0 } } });
                    try self.scratch.append(self.allocator, formal);
                }
            }
            const new_params = try self.ast.addNodeList(self.scratch.items[param_scratch_top..]);

            if (argument_shape) |shape| {
                if (try ast_walk.parameterListHasExpressions(self.allocator, self.ast, new_params) != shape.has_expressions)
                    @panic("native argument shape changed its actual parameter expressions");
            }
            if (argument_shadow) |plan| {
                if (plan.native_symbol == null) @panic("native parameter shadow has no actual formal binding");
                argument_shadow.?.source_declaration = try finalizeArgumentShadow(self, plan, &body_stmts, span);
            }
            return .{
                .new_params = new_params,
                .body_stmts = body_stmts,
                .native_formal_scope = native_formal_scope,
                .argument_shadow = argument_shadow,
            };
        }

        fn finalizeArgumentShadow(self: *Transformer, plan: NativeArgumentShadow, statements: *std.ArrayList(NodeIndex), span: Span) Transformer.Error!NodeIndex {
            const editor = &self.semantic_editor.?;
            const source_id: @import("../semantic/symbol.zig").SymbolId = @fromBackingInt(plan.source_symbol);
            if (editor.symbols.items[plan.source_symbol].scope_id != plan.body_scope) @panic("native shadow cell left its planned body storage");
            if (plan.block.isNone()) {
                // This mixed target already lowers lexical TDZ. Keep its old
                // undefined entry value rather than exposing ignored extra N.
                const source = editor.symbols.items[plan.source_symbol];
                const name = if (source.synthetic_name.len > 0) source.synthetic_name else self.ast.getText(source.name);
                const target = try es_helpers.makeTempRefFromIdentity(self, .{ .span = try self.ast.addString(name), .symbol_id = source_id, .reference_scope = plan.body_scope }, span, .{ .write = true });
                const reset = try es_helpers.makeAssignStmt(self, target, try es_helpers.makeVoidZero(self, span), span, 0);
                try statements.insert(self.allocator, 0, reset);
                return reset;
            }
            if (self.outputOwnedScope(plan.block) != plan.scope or editor.scopes.items[plan.scope.toIndex()].parent != plan.body_scope) @panic("native shadow cell has no actual lexical block");
            editor.relocateSymbol(source_id, plan.scope) catch @panic("native shadow cell cannot enter its lexical owner");
            editor.symbols.items[plan.source_symbol].kind = .variable_let;
            editor.symbols.items[plan.source_symbol].decl_flags = SymbolKind.variable_let.declFlags();
            var output: std.ArrayList(NodeIndex) = .empty;
            var declarations: usize = 0;
            var source_declaration: NodeIndex = .none;
            for (statements.items) |statement| {
                const node = self.ast.getNode(statement);
                var has_source = false;
                if (node.tag == .variable_declaration and self.ast.variableDeclarationKind(node) == .@"var") {
                    const start = self.ast.readExtra(node.data.extra, 1);
                    const len = self.ast.readExtra(node.data.extra, 2);
                    for (0..len) |i| {
                        const decl = self.ast.getNode(self.ast.readExtraNode(start, @intCast(i)));
                        const binding = self.ast.readExtraNode(decl.data.extra, 0);
                        if (self.ast.getNode(binding).tag == .binding_identifier and self.getSymbolIdAt(binding) == @as(?u32, plan.source_symbol)) has_source = true;
                    }
                    if (has_source) for (0..len) |i| {
                        const declarator = self.ast.readExtraNode(start, @intCast(i));
                        const binding = self.ast.readExtraNode(self.ast.getNode(declarator).data.extra, 0);
                        const selected = self.ast.getNode(binding).tag == .binding_identifier and self.getSymbolIdAt(binding) == @as(?u32, plan.source_symbol);
                        const replacement = try es_helpers.makeVarDeclaration(self, &.{declarator}, if (selected) .let else .@"var", node.span);
                        if (selected) {
                            try self.ast.preserve_lexical_declaration_indices.append(self.allocator, @backingInt(replacement));
                            declarations += 1;
                            source_declaration = replacement;
                        }
                        try output.append(self.allocator, replacement);
                    };
                }
                if (!has_source) try output.append(self.allocator, statement);
            }
            if (declarations != 1) @panic("native shadow cell must initialize at its one actual source binding point");
            statements.deinit(self.allocator);
            statements.* = output;
            for (statements.items) |statement| {
                try self.reparentGeneratedBodyScopes(plan.body_scope, plan.scope, statement);
                try @import("class_strict_context.zig").moveSourceReferences(self, statement, plan.body_scope, plan.body_scope, plan.scope);
            }
            self.ast.nodes.items[@backingInt(plan.block)].data.list = try self.ast.addNodeList(statements.items);
            return source_declaration;
        }

        pub const LowerResult = struct {
            new_params: NodeList,
            body_stmts: std.ArrayList(NodeIndex),
            /// Existing split parameter environment selected before binding birth.
            native_formal_scope: ?ScopeId = null,
            argument_shadow: ?NativeArgumentShadow = null,
        };

        /// destructuring + default parameter → temp 변수 경유.
        /// ({a = 1} = {}) → (_ref); body에 _ref = _ref === void 0 ? {} : _ref; var {a} = _ref;
        /// visited_pattern, visited_default는 이미 방문된 노드 인덱스.
        fn buildDestructuringDefault(
            self: *Transformer,
            visited_pattern: NodeIndex,
            visited_default: NodeIndex,
            body_stmts: *std.ArrayList(NodeIndex),
            span: Span,
        ) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const temp_binding = try es_helpers.makeSyntheticBinding(self, temp_span);
            const temp_identity = try registerDestructuringTempIdentityAtCreation(
                self,
                temp_binding,
                temp_span,
                span,
                .parameter,
            );
            es_helpers.consumeTempVarSpan(self, temp_span);

            const default_stmt = try buildDefaultCheckForTemp(self, temp_identity, visited_default, span);
            try body_stmts.append(self.allocator, default_stmt);

            const temp_ref2 = try es_helpers.makeTempRefFromIdentity(self, temp_identity, span, .{ .read = true });
            const pattern_node = self.ast.getNode(visited_pattern);
            const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
            var read_identity = temp_identity;
            if (pattern_node.tag == .array_pattern) {
                const read_span = try es_helpers.makeTempVarSpan(self);
                const read_binding = try es_helpers.makeSyntheticBinding(self, read_span);
                read_identity = try registerDestructuringTempIdentityAtCreation(
                    self,
                    read_binding,
                    read_span,
                    span,
                    .variable_var,
                );
                es_helpers.consumeTempVarSpan(self, read_span);
                const read_init = try es2015_destruct.buildArrayRead(self, temp_ref2, pattern_node, span);
                const read_decl = try es_helpers.makeVarDeclaration(
                    self,
                    &.{try es_helpers.makeDeclarator(self, read_binding, read_init, span)},
                    .@"var",
                    span,
                );
                try body_stmts.append(self.allocator, read_decl);
            }

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            try emitParameterPatternDeclarators(self, pattern_node, read_identity, span);
            const declarators = self.scratch.items[scratch_top..];
            if (declarators.len > 0) {
                const destruct_decl = try es_helpers.makeVarDeclaration(self, declarators, .@"var", span);
                try body_stmts.append(self.allocator, destruct_decl);
            }

            return temp_binding;
        }

        /// destructuring parameter (default 없음) → temp 변수 경유.
        /// ({ ref, ...props }) → (_param); body에 var ref = _param.ref, props = __rest(_param, ["ref"]);
        fn buildDestructuringParam(
            self: *Transformer,
            pattern_idx: NodeIndex,
            body_stmts: *std.ArrayList(NodeIndex),
            span: Span,
            native_formal_scope: ?ScopeId,
        ) Transformer.Error!NodeIndex {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const temp_binding = try es_helpers.makeSyntheticBinding(self, temp_span);
            var temp_identity = try registerDestructuringTempIdentityInScope(
                self,
                temp_binding,
                temp_span,
                span,
                .parameter,
                native_formal_scope orelse self.current_scope,
            );
            temp_identity.reference_scope = self.current_scope;
            es_helpers.consumeTempVarSpan(self, temp_span);

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            const pattern = self.ast.getNode(pattern_idx);
            const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
            var read_identity = temp_identity;
            if (pattern.tag == .array_pattern) {
                const read_span = try es_helpers.makeTempVarSpan(self);
                const read_binding = try es_helpers.makeSyntheticBinding(self, read_span);
                read_identity = try registerDestructuringTempIdentityAtCreation(
                    self,
                    read_binding,
                    read_span,
                    span,
                    .variable_var,
                );
                es_helpers.consumeTempVarSpan(self, read_span);
                const temp_ref = try es_helpers.makeTempRefFromIdentity(self, temp_identity, span, .{ .read = true });
                const read_init = try es2015_destruct.buildArrayRead(self, temp_ref, pattern, span);
                const read_decl = try es_helpers.makeDeclarator(self, read_binding, read_init, span);
                try self.scratch.append(self.allocator, read_decl);
            }
            try emitParameterPatternDeclarators(self, pattern, read_identity, span);

            const declarators = self.scratch.items[scratch_top..];
            if (declarators.len > 0) {
                const decl = try es_helpers.makeVarDeclaration(self, declarators, .@"var", span);
                try body_stmts.append(self.allocator, decl);
            }

            return temp_binding;
        }

        /// x = x === void 0 ? default_value : x
        /// → expression_statement 생성
        fn buildDefaultCheck(self: *Transformer, pattern: NodeIndex, default_val: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // void 0
            const void_zero = try es_helpers.makeVoidZero(self, span);

            // x === void 0
            const pattern_ref = try copyIdentifier(self, pattern, .{ .read = true });
            const eq_check = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{
                    .left = pattern_ref,
                    .right = void_zero,
                    .flags = @backingInt(token_mod.Kind.eq3),
                } },
            });

            // x === void 0 ? default_value : x
            const pattern_ref2 = try copyIdentifier(self, pattern, .{ .read = true });
            const conditional = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = span,
                .data = .{ .ternary = .{
                    .a = eq_check,
                    .b = default_val,
                    .c = pattern_ref2,
                } },
            });

            // x = (conditional)
            const pattern_ref3 = try copyIdentifier(self, pattern, .{ .write = true });
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = pattern_ref3, .right = conditional, .flags = 0 } },
            });

            // expression_statement
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        fn buildDefaultCheckForTemp(self: *Transformer, temp: es_helpers.TempIdentityCapture, default_val: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            const void_zero = try es_helpers.makeVoidZero(self, span);
            const test_ref = try es_helpers.makeTempRefFromIdentity(self, temp, span, .{ .read = true });
            const eq_check = try self.ast.addNode(.{
                .tag = .binary_expression,
                .span = span,
                .data = .{ .binary = .{ .left = test_ref, .right = void_zero, .flags = @backingInt(token_mod.Kind.eq3) } },
            });
            const value_ref = try es_helpers.makeTempRefFromIdentity(self, temp, span, .{ .read = true });
            const conditional = try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = span,
                .data = .{ .ternary = .{ .a = eq_check, .b = default_val, .c = value_ref } },
            });
            const write_ref = try es_helpers.makeTempRefFromIdentity(self, temp, span, .{ .write = true });
            const assign = try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = span,
                .data = .{ .binary = .{ .left = write_ref, .right = conditional, .flags = 0 } },
            });
            return self.ast.addNode(.{
                .tag = .expression_statement,
                .span = span,
                .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
            });
        }

        const UnlinkableParameter = struct { binding: NodeIndex, default: NodeIndex };

        /// An identifier parameter, with or without a default.
        fn unlinkableParameter(self: *Transformer, param: Node, raw: NodeIndex) ?UnlinkableParameter {
            switch (param.tag) {
                .binding_identifier => return .{ .binding = raw, .default = .none },
                .formal_parameter => {
                    const pe = param.data.extra;
                    const pattern = self.readNodeIdx(pe, ast_mod.FormalParameterExtra.pattern);
                    if (pattern.isNone() or self.ast.getNode(pattern).tag != .binding_identifier) return null;
                    return .{ .binding = pattern, .default = self.readNodeIdx(pe, ast_mod.FormalParameterExtra.default) };
                },
                .assignment_pattern => {
                    const left = param.data.binary.left;
                    if (left.isNone() or self.ast.getNode(left).tag != .binding_identifier) return null;
                    return .{ .binding = left, .default = param.data.binary.right };
                },
                else => return null,
            }
        }

        /// `...<pattern>` → `var _a = [].slice.call(arguments, N)` and the
        /// pattern's declarators reading `_a`.
        fn buildRestPatternParam(
            self: *Transformer,
            pattern_idx: NodeIndex,
            start_index: usize,
            body_stmts: *std.ArrayList(NodeIndex),
            span: Span,
            rest_owner: ?RestArgumentsOwner,
        ) Transformer.Error!void {
            const temp_span = try es_helpers.makeTempVarSpan(self);
            const temp_binding = try es_helpers.makeSyntheticBinding(self, temp_span);
            const temp_identity = try registerDestructuringTempIdentityAtCreation(
                self,
                temp_binding,
                temp_span,
                span,
                .variable_var,
            );
            es_helpers.consumeTempVarSpan(self, temp_span);
            try body_stmts.append(self.allocator, try buildRestSlice(self, temp_binding, start_index, span, rest_owner));

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            const pattern = self.ast.getNode(pattern_idx);
            const es2015_destruct = @import("es2015_destructuring.zig").ES2015Destructuring(Transformer);
            var read_identity = temp_identity;
            if (pattern.tag == .array_pattern) {
                const read_span = try es_helpers.makeTempVarSpan(self);
                const read_binding = try es_helpers.makeSyntheticBinding(self, read_span);
                read_identity = try registerDestructuringTempIdentityAtCreation(
                    self,
                    read_binding,
                    read_span,
                    span,
                    .variable_var,
                );
                es_helpers.consumeTempVarSpan(self, read_span);
                const temp_ref = try es_helpers.makeTempRefFromIdentity(self, temp_identity, span, .{ .read = true });
                const read_init = try es2015_destruct.buildArrayRead(self, temp_ref, pattern, span);
                try self.scratch.append(self.allocator, try es_helpers.makeDeclarator(self, read_binding, read_init, span));
            }
            try emitParameterPatternDeclarators(self, pattern, read_identity, span);
            const declarators = self.scratch.items[scratch_top..];
            if (declarators.len > 0) try body_stmts.append(self.allocator, try es_helpers.makeVarDeclaration(self, declarators, .@"var", span));
        }

        /// var rest = [].slice.call(arguments, N)
        fn buildRestSlice(self: *Transformer, binding: NodeIndex, start_index: usize, span: Span, rest_owner: ?RestArgumentsOwner) Transformer.Error!NodeIndex {
            // [] (empty array)
            const empty_arr_list = try self.ast.addNodeList(&.{});
            const empty_arr = try self.ast.addNode(.{
                .tag = .array_expression,
                .span = span,
                .data = .{ .list = empty_arr_list },
            });

            // [].slice
            const slice_prop = try es_helpers.makePropertyName(self, "slice");
            const slice_member = try es_helpers.makeStaticMember(self, empty_arr, slice_prop, span);

            // [].slice.call
            const call_prop = try es_helpers.makePropertyName(self, "call");
            const slice_call = try es_helpers.makeStaticMember(self, slice_member, call_prop, span);

            // arguments
            const args_ref = if (rest_owner) |owner|
                try self.makeNativeArgumentsRef(owner.body_scope, owner.body_scope, span)
            else
                try es_helpers.makeGlobalRef(self, "arguments");

            // start_index number
            const idx_node = try es_helpers.makeNumericLiteral(self, @intCast(start_index));

            // [].slice.call(arguments, N)
            const call_node = try es_helpers.makeCallExpr(self, slice_call, &.{ args_ref, idx_node }, span);

            // var rest = [].slice.call(arguments, N)
            const declarator = try es_helpers.makeDeclarator(self, binding, call_node, span);
            return es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
        }

        /// identifier 노드를 복제한다 (같은 이름·같은 심볼의 새 노드). 심볼을 물려주지 않으면
        /// minify 가 매개변수 선언만 바꾸고 이 참조는 원래 이름으로 남는다 (#4762).
        fn copyIdentifier(self: *Transformer, node_idx: NodeIndex, flags: @import("../semantic/symbol.zig").ReferenceFlags) Transformer.Error!NodeIndex {
            const node = self.ast.getNode(node_idx);
            const ref = try self.makeIdentifierRefWithSymbolAt(node.data.string_ref, node.span, node_idx);
            const use_scope = if (self.getSymbolIdAt(node_idx)) |raw_id| blk: {
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                if (raw_id < symbols.len) break :blk symbols[raw_id].scope_id;
                break :blk self.current_scope;
            } else self.current_scope;
            if (flags.read) try self.trackUserReadFromBinding(ref, node_idx, use_scope);
            if (flags.write) try self.trackUserWriteFromBinding(ref, node_idx, use_scope);
            return ref;
        }

        fn collectBindingNames(self: *Transformer, idx: NodeIndex, out: *std.ArrayList(Span)) Transformer.Error!void {
            // cover-grammar 결과 (identifier_reference / assignment_target_identifier) 도
            // 동일하게 spans 로 수집 — caller (param TDZ 검사) 가 그 형태를 기대한다.
            var it = try ast_walk.bindingIdentifiers(self.allocator, self.ast, idx, .{});
            defer it.deinit();
            while (try it.next()) |leaf_idx| {
                const emitted_name = self.ast.getNode(leaf_idx).data.string_ref;
                try out.append(self.allocator, emitted_name);
                // Forward reads can still have the source spelling: the
                // analyzer registers parameters in order and does not yet
                // model their separate environment. Keep both spellings of
                // this exact binding for the existing TDZ lowering, including
                // when a body function forced a parameter alias.
                if (self.getSymbolIdAt(leaf_idx)) |id| {
                    const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                    if (id < symbols.len and symbols[id].kind == .parameter) {
                        const source_name = symbols[id].name;
                        if (!std.mem.eql(u8, self.ast.getText(source_name), self.ast.getText(emitted_name)))
                            try out.append(self.allocator, source_name);
                    }
                }
            }
        }
    };
}

test "ES2015 params module compiles" {
    _ = ES2015Params;
}

test "dynamic body wrapper native temp factory records use scopes immediately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Scanner = @import("../lexer/scanner.zig").Scanner;
    const Parser = @import("../parser/parser.zig").Parser;
    const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
    const Transformer = @import("transformer.zig").Transformer;
    var scanner = try Scanner.init(a, "function read({a,...rest}={a:2}){}");
    var parser = Parser.init(a, &scanner);
    const root = try parser.parse();
    var analyzer = Analyzer.init(a, &parser.ast);
    analyzer.enable_exact_declaration_anchors = true;
    try analyzer.analyze();
    const list = parser.ast.getNode(root).data.list;
    const function = parser.ast.readExtraNode(list.start, 0);
    const function_node = parser.ast.getNode(function);
    const params = parser.ast.readExtraNode(function_node.data.extra, ast_mod.FunctionExtra.params);
    const parameter_scope: ScopeId = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(params)).?);
    const body_scope: ScopeId = @fromBackingInt(analyzer.scope_owner_map.get(@backingInt(function)).?);
    try std.testing.expectEqual(parameter_scope, analyzer.scopes.items[body_scope.toIndex()].parent);
    const param = parser.ast.getNode(parser.ast.readExtraNode(parser.ast.getNode(params).data.list.start, 0));
    try std.testing.expectEqual(.assignment_pattern, param.tag);
    var t = try Transformer.init(a, &parser.ast, .{});
    try t.initSymbolIds(analyzer.symbol_ids.items);
    t.symbols = analyzer.symbols.items;
    t.references = analyzer.references.items;
    t.scopes = analyzer.scopes.items;
    t.scope_maps = analyzer.scope_maps.items;
    t.scope_owner_map = analyzer.scope_owner_map;
    t.unresolved_references = &analyzer.unresolved_references;
    t.semantic_edit_enabled = true;
    t.current_scope = body_scope;
    var prefix: std.ArrayList(NodeIndex) = .empty;
    const binding = try ES2015Params(Transformer).buildDestructuringParam(&t, param.data.binary.left, &prefix, function_node.span, parameter_scope);
    const id = t.getSymbolIdAt(binding).?;
    const editor = &t.semantic_editor.?;
    try std.testing.expectEqual(parameter_scope, editor.symbols.items[id].scope_id);
    var declarations: usize = 0;
    var reads: usize = 0;
    for (editor.references.items) |row| {
        if (@backingInt(row.symbol_id) != id) continue;
        if (row.flags.declare) {
            try std.testing.expectEqual(parameter_scope, row.scope_id);
            try std.testing.expectEqual(binding, row.declaration_node_index);
            declarations += 1;
        } else {
            try std.testing.expect(row.flags.read and !row.flags.write and !row.node_index.isNone());
            try std.testing.expectEqual(body_scope, row.scope_id);
            reads += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), declarations);
    try std.testing.expect(reads > 0);
}
