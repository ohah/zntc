//! ES2015 다운레벨링: let/const → var + for-loop 클로저 캡처 IIFE
//!
//! --target < es2015 일 때 활성화.
//!
//! 1단계: let/const → var 키워드 변환.
//! 2단계: for 루프에서 let/const 변수를 클로저가 캡처하는 경우 _loop 함수 추출.
//!
//! 변환 예시:
//!   for (let i = 0; i < 3; i++) { fns.push(() => i); }
//!   →
//!   var _loop = function(i) { fns.push(function() { return i; }); };
//!   for (var i = 0; i < 3; i++) { _loop(i); }
//!
//! 제어 흐름 처리 (FlowHelper):
//!   - return expr → return { v: expr }; 호출부에서 if (typeof _ret === "object") return _ret.v;
//!   - break      → return "break";      호출부에서 if (_ret === "break") break;
//!   - continue   → return;              (함수에서 return은 자연스럽게 다음 반복으로)
//!   - break label / continue label → return "break|label" / "continue|label"
//!   - switch 내부/중첩 루프 내부의 break/continue는 변환하지 않음
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-let-and-const-declarations (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/block_scoping/ (~1404줄)
//! - Babel: @babel/plugin-transform-block-scoping

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const SymbolId = @import("../semantic/symbol.zig").SymbolId;

/// block scoping 다운레벨 시 모든 lexical(let/const/using/await_using)을 var로 치환.
/// (using disposal 등 의미 보존은 별도 패스가 처리)
pub inline fn lowerKind(_: VariableDeclarationKind) VariableDeclarationKind {
    return .@"var";
}

/// closure 경계 — 안의 capture / await / yield 등은 우리 책임이 아니라 해당 함수 책임.
/// hasCapturedClosure / hasAwaitExpression 양쪽이 동일 set 사용 → 단일 정의로 drift 차단.
///
/// `method_definition` 도 포함 — class/object literal 의 method body 는 자체 함수 scope.
/// 누락 시 `for (let i ...) { class C { m() { return i; } } }` 같은 패턴에서 m() 안의
/// `i` 를 capture 가 아닌 직접 reference 로 오인 → per-iteration fresh binding 변환 누락.
inline fn isFunctionBoundary(tag: Tag) bool {
    return tag == .function_expression or
        tag == .function_declaration or
        tag == .arrow_function_expression or
        tag == .function or
        tag == .method_definition;
}

pub fn ES2015BlockScoping(comptime Transformer: type) type {
    return struct {
        const Self = @This();

        pub const LoopClosureResult = struct {
            loop_fn: NodeIndex,
            loop_function: NodeIndex,
            loop_binding: NodeIndex,
            loop_symbol_id: ?SymbolId,
            loop_owner_scope: ScopeId,
            generator_function_scope: ?ScopeId = null,
            call_and_check: NodeIndex,
            ret_temp_span: ?Span = null,
            ret_temp_binding: ?NodeIndex = null,
            ret_temp_symbol_id: ?SymbolId = null,
            ret_temp_owner_scope: ScopeId = .none,
        };

        const ControlFlowCheck = struct {
            node: NodeIndex,
            ret_temp_span: ?Span = null,
            ret_temp_binding: ?NodeIndex = null,
            ret_temp_symbol_id: ?SymbolId = null,
            ret_temp_owner_scope: ScopeId = .none,
        };

        /// for 루프의 init에서 let/const 변수 이름을 수집한다.
        /// 반환: 수집된 변수 이름 목록. 비어 있으면 클로저 캡처 분석 불필요.
        pub fn collectLexicalVarNames(
            self: *Transformer,
            init_idx: NodeIndex,
        ) !std.ArrayList([]const u8) {
            var bindings: std.ArrayList(NodeIndex) = .empty;
            defer bindings.deinit(self.allocator);
            try collectLexicalVarBindings(self, init_idx, &bindings);
            return namesOf(self, bindings.items);
        }

        /// `collectLexicalVarNames` 의 노드판 — 같은 순서의 바인딩 식별자 노드. 이름으로 만든
        /// 새 노드(`_loop` 매개변수 등)에 원래 심볼을 물려줄 때 쓴다 (#4760).
        pub fn collectLexicalVarBindings(
            self: *Transformer,
            init_idx: NodeIndex,
            out: *std.ArrayList(NodeIndex),
        ) !void {
            if (init_idx.isNone()) return;
            const init = self.ast.getNode(init_idx);
            if (init.tag != .variable_declaration) return;
            if (!self.ast.variableDeclarationKind(init).isLexical()) return;

            const e = init.data.extra;
            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);

            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const decl_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[list_start + i]));
                const decl = self.ast.getNode(decl_idx);
                if (decl.tag != .variable_declarator) continue;
                try collectBindingNodes(self, self.readNodeIdx(decl.data.extra, 0), out);
            }
        }

        /// 패턴 안의 바인딩 식별자 노드 (`collectBindingNames` 의 노드판).
        pub fn collectBindingNodes(self: *Transformer, idx: NodeIndex, out: *std.ArrayList(NodeIndex)) !void {
            var it = try ast_walk.bindingIdentifiers(self.allocator, self.ast, idx, .{});
            defer it.deinit();
            while (try it.next()) |leaf_idx| {
                if (self.ast.getNode(leaf_idx).tag != .binding_identifier) continue;
                try out.append(self.allocator, leaf_idx);
            }
        }

        /// 바인딩 노드들의 이름 (같은 순서).
        fn namesOf(self: *Transformer, bindings: []const NodeIndex) !std.ArrayList([]const u8) {
            var names: std.ArrayList([]const u8) = .empty;
            errdefer names.deinit(self.allocator);
            for (bindings) |binding| try names.append(self.allocator, try self.decodedName(self.ast.getText(self.ast.getNode(binding).span)));
            return names;
        }

        /// binding pattern에서 모든 identifier 이름을 수집한다.
        /// destructuring 포함 (array_pattern, object_pattern, rest_element, assignment_pattern).
        /// `binding_identifier` 만 수집 — cover-grammar 의 identifier_reference /
        /// assignment_target_identifier 는 lexical 선언 컨텍스트에서 등장하지 않는다.
        pub fn collectBindingNames(
            self: *Transformer,
            idx: NodeIndex,
            names: *std.ArrayList([]const u8),
        ) !void {
            var it = try ast_walk.bindingIdentifiers(self.allocator, self.ast, idx, .{});
            defer it.deinit();
            while (try it.next()) |leaf_idx| {
                const leaf = self.ast.getNode(leaf_idx);
                if (leaf.tag != .binding_identifier) continue;
                try names.append(self.allocator, try self.decodedName(self.ast.getText(leaf.span)));
            }
        }

        /// AST subtree 를 명시적 stack DFS 로 순회 (stack overflow 불가능).
        /// closure (function/arrow) 경계는 `in_closure=true` 로 표시되어 callback 에
        /// 전달된다 — callback 이 그 정보로 자기 의미의 가드를 적용 (capture 검사,
        /// await/yield 검사 등). callback 이 true 반환 시 즉시 early-return true.
        ///
        /// 트랜스포머가 새로 만든 노드도 방문한다(범위 검사만) — #4722.
        /// OOM 시 보수적으로 true 반환 (호출부가 안전한 fallback 으로 처리).
        fn anyMatchInsideClosure(
            self: *Transformer,
            body_idx: NodeIndex,
            ctx: anytype,
            comptime visit: fn (@TypeOf(ctx), Node, bool) bool,
        ) bool {
            if (body_idx.isNone()) return false;
            // 트랜스포머가 만든 노드도 본다(#4722). 예전엔 파서 노드만 봤는데, 바깥 루프 추출이
            // 본문을 재작성하면 안쪽 루프가 새 노드가 되어 캡처를 못 보는 false negative 가
            // 났다(가드 도입 당시 TODO 로 남아 있던 문제). 레이아웃은 comptime 표로 검증된다.
            const max_node: usize = self.ast.nodes.items.len;

            const ScanEntry = struct { idx: NodeIndex, in_closure: bool };
            var stack: std.ArrayList(ScanEntry) = .empty;
            defer stack.deinit(self.allocator);
            stack.append(self.allocator, .{ .idx = body_idx, .in_closure = false }) catch return true;

            while (stack.items.len > 0) {
                const entry = stack.pop() orelse break;
                if (entry.idx.isNone()) continue;
                if (@backingInt(entry.idx) >= max_node) continue;
                const node = self.ast.getNode(entry.idx);

                const in_closure = entry.in_closure or isFunctionBoundary(node.tag);

                if (visit(ctx, node, in_closure)) return true;

                var children: std.ArrayList(NodeIndex) = .empty;
                defer children.deinit(self.allocator);
                collectChildIndices(self, node, &children) catch return true;
                for (children.items) |child_idx| {
                    const outer = @import("transformer/semantic_edit.zig").childSkipsOutputScope(self.ast, @backingInt(entry.idx), @backingInt(child_idx));
                    const field_initializer = (node.tag == .property_definition or node.tag == .accessor_property) and
                        self.ast.readExtraNode(node.data.extra, ast_mod.PropertyExtra.init) == child_idx;
                    stack.append(self.allocator, .{ .idx = child_idx, .in_closure = if (outer) entry.in_closure else in_closure or field_initializer }) catch return true;
                }
            }
            return false;
        }

        /// loop body 안에서 closure (arrow/function) 가 lexical 변수를 캡처하는지 검사.
        /// closure 안의 identifier_reference 만 본다 — top-level (in_closure=false) reference
        /// 는 그냥 같은 scope 의 var 사용이라 capture 가 아니다.
        pub fn hasCapturedClosure(
            self: *Transformer,
            body_idx: NodeIndex,
            lexical_names: []const []const u8,
        ) bool {
            if (lexical_names.len == 0) return false;
            const Ctx = struct {
                self: *Transformer,
                names: []const []const u8,
            };
            const ctx = Ctx{ .self = self, .names = lexical_names };
            return anyMatchInsideClosure(self, body_idx, ctx, struct {
                fn visit(c: Ctx, node: Node, in_closure: bool) bool {
                    if (!in_closure or node.tag != .identifier_reference) return false;
                    const name = c.self.ast.getText(node.span);
                    for (c.names) |ln| {
                        if (Scanner.identifierNamesEqual(name, ln)) return true;
                    }
                    return false;
                }
            }.visit);
        }

        /// 루프 본문에서 선언되어 **반복마다 새로 생겨야 하는** 블록 스코프 바인딩 이름 (#4743).
        /// `let`/`const`/`using`/`class` — 상태 기계는 catch 파라미터도 wrapper 로 끌어올리므로
        /// `include_catch_params` 로 함께 모은다(일반 경로의 catch 는 native 라 불필요).
        /// 함수 경계와 **중첩 루프**는 들어가지 않는다 — 중첩 루프의 본문 바인딩은 그 루프가
        /// 자기 반복마다 추출한다.
        pub fn collectLoopBodyLexicalNames(
            self: *Transformer,
            body_idx: NodeIndex,
            include_catch_params: bool,
            out: *std.ArrayList([]const u8),
        ) !void {
            if (body_idx.isNone()) return;
            var ctx: LoopBodyScan = .{ .self = self, .include_catch = include_catch_params };
            defer ctx.found.deinit(self.allocator);
            try ast_walk.walkPreorderIterative(self.allocator, self.ast, body_idx, &ctx, LoopBodyScan.lexicalVisit);
            for (ctx.found.items) |idx| try collectBindingNames(self, idx, out);
            for (ctx.class_names.items) |name| try out.append(self.allocator, name);
            ctx.class_names.deinit(self.allocator);
        }

        /// 루프 본문의 **원래** `var` 선언 이름 (#4743). 본문을 `_loop` 함수로 뽑으면 이 이름들이
        /// 그 함수의 지역 변수가 되어 루프 밖에서 사라진다 — 추출할 때 바깥으로 끌어올린다.
        /// 방문 뒤에는 `let` 도 `var` 가 되어 구분할 수 없으므로 **원본**에서 모은다.
        /// var 는 함수 스코프라 중첩 루프·블록 안까지 보고, 함수 경계에서만 멈춘다.
        pub fn collectLoopBodyVarNames(
            self: *Transformer,
            body_idx: NodeIndex,
            out: *std.ArrayList([]const u8),
        ) !void {
            var bindings: std.ArrayList(NodeIndex) = .empty;
            defer bindings.deinit(self.allocator);
            try collectLoopBodyVarBindings(self, body_idx, &bindings);
            for (bindings.items) |binding| try out.append(self.allocator, try self.decodedName(self.ast.getText(self.ast.getNode(binding).span)));
        }

        /// `collectLoopBodyVarNames` 의 노드판 (같은 순서).
        pub fn collectLoopBodyVarBindings(
            self: *Transformer,
            body_idx: NodeIndex,
            out: *std.ArrayList(NodeIndex),
        ) !void {
            if (body_idx.isNone()) return;
            var ctx: LoopBodyScan = .{ .self = self, .include_catch = false };
            defer ctx.found.deinit(self.allocator);
            defer ctx.class_names.deinit(self.allocator);
            try ast_walk.walkPreorderIterative(self.allocator, self.ast, body_idx, &ctx, LoopBodyScan.varVisit);
            for (ctx.found.items) |idx| try collectBindingNodes(self, idx, out);
        }

        const LoopBodyScan = struct {
            self: *Transformer,
            include_catch: bool,
            /// 바인딩(패턴 포함) 노드 — 이름 추출은 순회 뒤에 한다(visit 는 에러를 못 낸다).
            found: std.ArrayList(NodeIndex) = .empty,
            class_names: std.ArrayList([]const u8) = .empty,
            oom: bool = false,

            fn push(ctx: *LoopBodyScan, idx: NodeIndex) void {
                ctx.found.append(ctx.self.allocator, idx) catch {
                    ctx.oom = true;
                };
            }

            fn pushDeclarators(ctx: *LoopBodyScan, node: Node) void {
                const ds = ctx.self.readU32(node.data.extra, 1);
                const dl = ctx.self.readU32(node.data.extra, 2);
                var j: u32 = 0;
                while (j < dl) : (j += 1) {
                    const d = ctx.self.ast.getNode(@fromBackingInt(@intCast(ctx.self.ast.extra_data.items[ds + j])));
                    if (d.tag != .variable_declarator) continue;
                    const b = ctx.self.readNodeIdx(d.data.extra, 0);
                    if (!b.isNone()) ctx.push(b);
                }
            }

            fn isLoop(tag: Tag) bool {
                return switch (tag) {
                    .for_statement, .for_in_statement, .for_of_statement, .for_await_of_statement, .while_statement, .do_while_statement => true,
                    else => false,
                };
            }

            fn lexicalVisit(ctx: *LoopBodyScan, _: NodeIndex, node: Node) ast_walk.WalkAction {
                if (isFunctionBoundary(node.tag) or isLoop(node.tag)) return .skip_children;
                switch (node.tag) {
                    .variable_declaration => {
                        if (ctx.self.ast.hasExtra(node.data.extra, 3) and ctx.self.ast.variableDeclarationKind(node).isLexical()) ctx.pushDeclarators(node);
                        return .descend;
                    },
                    .ts_enum_declaration => {
                        // A runtime enum has source lexical storage even before
                        // its actual outer declaration is spliced into the list.
                        if ((ctx.self.readU32(node.data.extra, ast_mod.EnumExtra.flags) & 2) == 0) {
                            const name = ctx.self.readNodeIdx(node.data.extra, ast_mod.EnumExtra.name);
                            if (!name.isNone() and ctx.self.ast.getNode(name).tag == .binding_identifier) ctx.push(name);
                        }
                        return .descend;
                    },
                    .class_declaration => {
                        const name = ctx.self.readNodeIdx(node.data.extra, ast_mod.ClassExtra.name);
                        if (!name.isNone()) {
                            const text = ctx.self.stableName(ctx.self.ast.getText(ctx.self.ast.getNode(name).span)) catch blk: {
                                ctx.oom = true;
                                break :blk "";
                            };
                            ctx.class_names.append(ctx.self.allocator, text) catch {
                                ctx.oom = true;
                            };
                        }
                        return .skip_children;
                    },
                    .catch_clause => {
                        if (ctx.include_catch and !node.data.binary.left.isNone()) ctx.push(node.data.binary.left);
                        return .descend;
                    },
                    else => return .descend,
                }
            }

            fn varVisit(ctx: *LoopBodyScan, _: NodeIndex, node: Node) ast_walk.WalkAction {
                if (isFunctionBoundary(node.tag)) return .skip_children;
                if (node.tag == .variable_declaration and ctx.self.ast.hasExtra(node.data.extra, 3) and
                    ctx.self.ast.variableDeclarationKind(node) == .@"var") ctx.pushDeclarators(node);
                return .descend;
            }
        };

        /// 추출할 본문에서 `names` 의 `var` 선언을 대입으로 바꾼다 (#4743). 선언은 호출자가
        /// `var names…, _loop = function…` 로 바깥에 둔다. 함수 경계 안은 건드리지 않는다.
        /// 구조분해 패턴 선언은 그대로 둔다(일반 경로는 방문 때 이미 식별자로 풀렸다).
        fn hoistVarsOutOfBody(self: *Transformer, idx: NodeIndex, names: []const []const u8, inherited_scope: ScopeId) Transformer.Error!NodeIndex {
            const next = try hoistVarsOutOfBodyInner(self, idx, names, inherited_scope);
            try self.remapCopiedScopeOwner(idx, next);
            return next;
        }

        fn hoistVarsOutOfBodyInner(self: *Transformer, idx: NodeIndex, names: []const []const u8, inherited_scope: ScopeId) Transformer.Error!NodeIndex {
            if (idx.isNone() or names.len == 0) return idx;
            // A write executes in the scope of the original statement, even
            // when this subtree has already been copied by control-flow
            // lowering. The caller supplies the scope for synthetic wrappers.
            const scope: ScopeId = if (self.semantic_edit_enabled)
                @fromBackingInt(@intCast(self.transformed_scope_owner_map.get(@backingInt(idx)) orelse
                    self.scope_owner_map.get(@backingInt(idx)) orelse @backingInt(inherited_scope)))
            else
                inherited_scope;
            const node = self.ast.getNode(idx);
            switch (node.tag) {
                .block_statement => {
                    var items: std.ArrayList(NodeIndex) = .empty;
                    defer items.deinit(self.allocator);
                    var changed = false;
                    var i: u32 = 0;
                    while (i < node.data.list.len) : (i += 1) {
                        const child: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[node.data.list.start + i]));
                        const cn = self.ast.getNode(child);
                        if (cn.tag == .variable_declaration and isHoistableVar(self, cn, names)) {
                            try appendVarAsAssignments(self, cn, names, scope, &items);
                            changed = true;
                            continue;
                        }
                        const nc = try hoistVarsOutOfBody(self, child, names, scope);
                        if (nc != child) changed = true;
                        try items.append(self.allocator, nc);
                    }
                    if (!changed) return idx;
                    return self.ast.addNode(.{ .tag = .block_statement, .span = node.span, .data = .{ .list = try self.ast.addNodeList(items.items) } });
                },
                .variable_declaration => {
                    if (!isHoistableVar(self, node, names)) return idx;
                    var items: std.ArrayList(NodeIndex) = .empty;
                    defer items.deinit(self.allocator);
                    try appendVarAsAssignments(self, node, names, scope, &items);
                    return self.ast.addNode(.{ .tag = .block_statement, .span = node.span, .data = .{ .list = try self.ast.addNodeList(items.items) } });
                },
                .if_statement => {
                    const t = node.data.ternary;
                    const b = try hoistVarsOutOfBody(self, t.b, names, scope);
                    const c = try hoistVarsOutOfBody(self, t.c, names, scope);
                    if (b == t.b and c == t.c) return idx;
                    return self.ast.addNode(.{ .tag = .if_statement, .span = node.span, .data = .{ .ternary = .{ .a = t.a, .b = b, .c = c } } });
                },
                .while_statement, .do_while_statement, .labeled_statement => {
                    const r = try hoistVarsOutOfBody(self, node.data.binary.right, names, scope);
                    if (r == node.data.binary.right) return idx;
                    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .binary = .{ .left = node.data.binary.left, .right = r, .flags = node.data.binary.flags } } });
                },
                .for_statement => {
                    const e = node.data.extra;
                    var init = self.readNodeIdx(e, 0);
                    if (!init.isNone()) {
                        const init_node = self.ast.getNode(init);
                        if (init_node.tag == .variable_declaration and isHoistableVar(self, init_node, names)) init = try varAsExpression(self, init_node, names, scope);
                    }
                    const body = try hoistVarsOutOfBody(self, self.readNodeIdx(e, 3), names, scope);
                    if (init == self.readNodeIdx(e, 0) and body == self.readNodeIdx(e, 3)) return idx;
                    return self.addExtraNode(.for_statement, node.span, &.{
                        @backingInt(init), @backingInt(self.readNodeIdx(e, 1)), @backingInt(self.readNodeIdx(e, 2)), @backingInt(body),
                    });
                },
                .for_in_statement, .for_of_statement, .for_await_of_statement => {
                    const t = node.data.ternary;
                    var left = t.a;
                    if (!left.isNone()) {
                        const ln = self.ast.getNode(left);
                        if (ln.tag == .variable_declaration and isHoistableVar(self, ln, names)) {
                            const d = self.ast.getNode(@fromBackingInt(@intCast(self.ast.extra_data.items[self.readU32(ln.data.extra, 1)])));
                            const b_idx = self.readNodeIdx(d.data.extra, 0);
                            const b = self.ast.getNode(b_idx);
                            if (b.tag == .binding_identifier) {
                                left = try self.makeIdentifierRefWithSymbol(b.data.string_ref, b_idx);
                                try self.trackUserWriteFromBinding(left, b_idx, scope);
                            }
                        }
                    }
                    const c = try hoistVarsOutOfBody(self, t.c, names, scope);
                    if (left == t.a and c == t.c) return idx;
                    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .ternary = .{ .a = left, .b = t.b, .c = c } } });
                },
                .try_statement => {
                    const t = node.data.ternary;
                    const a = try hoistVarsOutOfBody(self, t.a, names, scope);
                    const b = try hoistVarsOutOfBody(self, t.b, names, scope);
                    const c = try hoistVarsOutOfBody(self, t.c, names, scope);
                    if (a == t.a and b == t.b and c == t.c) return idx;
                    return self.ast.addNode(.{ .tag = .try_statement, .span = node.span, .data = .{ .ternary = .{ .a = a, .b = b, .c = c } } });
                },
                .catch_clause => {
                    const body = try hoistVarsOutOfBody(self, node.data.binary.right, names, scope);
                    if (body == node.data.binary.right) return idx;
                    return self.ast.addNode(.{ .tag = .catch_clause, .span = node.span, .data = .{ .binary = .{
                        .left = node.data.binary.left,
                        .right = body,
                        .flags = node.data.binary.flags,
                    } } });
                },
                .switch_statement => {
                    const e = node.data.extra;
                    const cs = self.readU32(e, 1);
                    const cl = self.readU32(e, 2);
                    var cases: std.ArrayList(NodeIndex) = .empty;
                    defer cases.deinit(self.allocator);
                    var changed = false;
                    var i: u32 = 0;
                    while (i < cl) : (i += 1) {
                        const case_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[cs + i]));
                        const cn = self.ast.getNode(case_idx);
                        const ce = cn.data.extra;
                        const block = try self.ast.addNode(.{ .tag = .block_statement, .span = cn.span, .data = .{ .list = .{ .start = self.readU32(ce, 1), .len = self.readU32(ce, 2) } } });
                        const nb = try hoistVarsOutOfBody(self, block, names, scope);
                        if (nb == block) {
                            try cases.append(self.allocator, case_idx);
                            continue;
                        }
                        changed = true;
                        const bl = self.ast.getNode(nb).data.list;
                        try cases.append(self.allocator, try self.addExtraNode(.switch_case, cn.span, &.{ @backingInt(self.readNodeIdx(ce, 0)), bl.start, bl.len }));
                    }
                    if (!changed) return idx;
                    const list = try self.ast.addNodeList(cases.items);
                    return self.addExtraNode(.switch_statement, node.span, &.{ @backingInt(self.readNodeIdx(e, 0)), list.start, list.len });
                },
                else => return idx,
            }
        }

        /// 모든 declarator 가 `names` 에 든 **식별자**인 var 선언인지.
        fn isHoistableVar(self: *Transformer, node: Node, names: []const []const u8) bool {
            if (!self.ast.hasExtra(node.data.extra, 3) or self.ast.variableDeclarationKind(node) != .@"var") return false;
            const ds = self.readU32(node.data.extra, 1);
            const dl = self.readU32(node.data.extra, 2);
            if (dl == 0) return false;
            var j: u32 = 0;
            while (j < dl) : (j += 1) {
                const d = self.ast.getNode(@fromBackingInt(@intCast(self.ast.extra_data.items[ds + j])));
                if (d.tag != .variable_declarator) return false;
                const b = self.ast.getNode(self.readNodeIdx(d.data.extra, 0));
                if (b.tag != .binding_identifier) return false;
                if (!nameIn(self.ast.getText(b.data.string_ref), names)) return false;
            }
            return true;
        }

        fn nameIn(name: []const u8, names: []const []const u8) bool {
            for (names) |n| {
                if (Scanner.identifierNamesEqual(n, name)) return true;
            }
            return false;
        }

        /// `var a = 1, b;` → `a = 1;` (초기값 없는 declarator 는 버린다)
        fn appendVarAsAssignments(self: *Transformer, node: Node, names: []const []const u8, scope: ScopeId, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            _ = names;
            const ds = self.readU32(node.data.extra, 1);
            const dl = self.readU32(node.data.extra, 2);
            var j: u32 = 0;
            while (j < dl) : (j += 1) {
                const d = self.ast.getNode(@fromBackingInt(@intCast(self.ast.extra_data.items[ds + j])));
                const init = self.readNodeIdx(d.data.extra, 2);
                if (init.isNone()) continue;
                const b_idx = self.readNodeIdx(d.data.extra, 0);
                const b = self.ast.getNode(b_idx);
                const target = try self.makeIdentifierRefWithSymbol(b.data.string_ref, b_idx);
                try self.trackUserWriteFromBinding(target, b_idx, scope);
                const assign = try self.ast.addNode(.{ .tag = .assignment_expression, .span = d.span, .data = .{ .binary = .{
                    .left = target,
                    .right = init,
                    .flags = 0,
                } } });
                try out.append(self.allocator, try es_helpers.makeExprStmt(self, assign, d.span));
            }
        }

        /// for 헤더용: `var i = 0, j = 1` → `i = 0, j = 1` (없으면 none)
        fn varAsExpression(self: *Transformer, node: Node, names: []const []const u8, scope: ScopeId) Transformer.Error!NodeIndex {
            var stmts: std.ArrayList(NodeIndex) = .empty;
            defer stmts.deinit(self.allocator);
            try appendVarAsAssignments(self, node, names, scope, &stmts);
            if (stmts.items.len == 0) return .none;
            var exprs: std.ArrayList(NodeIndex) = .empty;
            defer exprs.deinit(self.allocator);
            for (stmts.items) |st| try exprs.append(self.allocator, self.ast.getNode(st).data.unary.operand);
            if (exprs.items.len == 1) return exprs.items[0];
            return self.ast.addNode(.{ .tag = .sequence_expression, .span = node.span, .data = .{ .list = try self.ast.addNodeList(exprs.items) } });
        }

        /// loop body 직속 (closure 경계 안 넘는) `await` expression 이 있는지 검사.
        /// 있으면 합성된 `_loop` 함수도 async 로 emit + 호출부 `await _loop(x)` wrap
        /// 필요 — `_loop` 가 새 function scope 라 enclosing async-ness 가 끊기기 때문.
        pub fn hasAwaitExpression(self: *Transformer, body_idx: NodeIndex) bool {
            return @import("loop_await_driver.zig").hasSuspension(self, body_idx, .await_expression) catch true;
        }

        /// loop body 를 `_loop` 함수로 추출할 때 원래 body 의 lexical `this` /
        /// `super` 의미가 필요한지 검사한다. 일반 function/class/method 는 자체
        /// `this` 를 가지므로 경계에서 멈추고, arrow function 은 outer `this` 를
        /// 캡처하므로 계속 탐색한다.
        pub fn hasLexicalThisReference(self: *Transformer, body_idx: NodeIndex) bool {
            const captures = @import("es2015_arrow.zig").ES2015Arrow(Transformer).lexicalCaptures(self, body_idx) catch return true;
            return captures.this_value or captures.super_value;
        }

        /// 노드의 자식 NodeIndex들을 scratch 버퍼에 수집한다.
        /// 공통 `ast_walk.ChildIterator` 로 자식 순회 + 범위 밖 인덱스를 걸러낸다
        /// (extra 자식에만 한정). 트랜스포머가 만든 노드도 포함한다 — #4722.
        fn collectChildIndices(self: *Transformer, node: Node, buf: *std.ArrayList(NodeIndex)) !void {
            const kind = node.tag.dataKind();
            var it = ast_walk.children(self.ast, node);
            while (it.next()) |child| {
                if (kind == .extra) {
                    const raw = @backingInt(child);
                    if (raw == 0 or raw >= self.ast.nodes.items.len) continue;
                }
                try buf.append(self.allocator, child);
            }
        }

        /// 제어 흐름 분석 결과.
        pub const FlowResult = struct {
            has_return: bool = false,
            has_break: bool = false,
            /// for-of body 최상단의 unlabeled `continue`. body 가 `_loop` 함수로 추출될 때
            /// 해당 `continue` 는 반드시 `return;` 으로 변환되어야 — 안 그러면 SyntaxError
            /// (Illegal continue statement: no surrounding iteration statement).
            has_continue: bool = false,
            has_labeled_break: bool = false,
            has_labeled_continue: bool = false,
            labels: std.ArrayList([]const u8) = .empty,

            /// 호출부에 `var _ret = _loop(x); if (...) ...` 체크 체인이 필요한지.
            /// `return` / `break` / labeled 는 호출부가 값을 검사해 outer 루프를 종료하거나
            /// 함수를 return 해야 한다. unlabeled `continue` 는 body 안에서 `return;` 으로만
            /// 변환하면 되고 호출부는 `_loop(x);` 그대로 — `_ret` 불필요.
            pub fn needsRetVar(self: *const FlowResult) bool {
                return self.has_return or self.has_break or self.has_labeled_break or self.has_labeled_continue;
            }

            /// body 를 재작성해야 하는지 (break/continue/return → return 문 치환).
            /// `needsRetVar` 보다 넓음 — `has_continue` 단독으로도 true.
            pub fn needsTransform(self: *const FlowResult) bool {
                return self.needsRetVar() or self.has_continue;
            }
        };

        /// for 루프 body를 _loop 함수로 추출하고 호출로 대체한다.
        ///
        /// 반환: { .loop_fn_decl, .call_stmt } — 호출부에서 조립.
        // Only the actual extracted body moves here. The source loop header and
        // its callsite retain their original owner outside the new function.
        /// Transfer actual body var storage when its implementation function
        /// is created. Source vars intentionally shared outside were removed by
        /// hoistVarsOutOfBody; nested functions/classes own their declarations.
        fn bindExtractedBodyVarStorage(self: *Transformer, body: NodeIndex, owner: ScopeId) Transformer.Error!void {
            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            try stack.append(self.allocator, body);
            while (stack.pop()) |idx| {
                if (idx.isNone()) continue;
                const node = self.ast.getNode(idx);
                switch (node.tag) {
                    .function_declaration, .function_expression, .function, .arrow_function_expression, .method_definition, .class_declaration, .class_expression => continue,
                    .variable_declaration => {
                        if (self.ast.variableDeclarationKind(node) == .@"var") {
                            var declared: std.ArrayList(NodeIndex) = .empty;
                            defer declared.deinit(self.allocator);
                            const start = self.readU32(node.data.extra, 1);
                            const len = self.readU32(node.data.extra, 2);
                            for (0..len) |i| {
                                const declarator = self.ast.getNode(@fromBackingInt(self.ast.extra_data.items[start + i]));
                                try collectBindingNodes(self, self.ast.readExtraNode(declarator.data.extra, 0), &declared);
                            }
                            for (declared.items) |binding| {
                                const id = self.getSymbolIdAt(binding) orelse std.debug.panic("extracted body var has no producer SID: node={d} name={s}", .{ @backingInt(binding), self.ast.getText(self.ast.getNode(binding).span) });
                                const existing = self.semantic_editor.?.symbols.items[id];
                                if (existing.annex_b_alias.state != .lowered or existing.annex_b_alias.variable.isNone() or existing.scope_id != owner)
                                    try self.relocateOutputSymbolAs(id, owner, binding);
                                const symbol = &self.semantic_editor.?.symbols.items[id];
                                symbol.kind = .variable_var;
                                symbol.decl_flags = symbol.kind.declFlags();
                                var planned = self.retained_loop_key_cells.valueIterator();
                                while (planned.next()) |cells| for (cells.*) |*cell| {
                                    if (cell.capture.symbol_id != null and @backingInt(cell.capture.symbol_id.?) == id)
                                        cell.capture.owner_scope = owner;
                                };
                            }
                        }
                    },
                    else => {},
                }
                var children = ast_walk.children(self.ast, node);
                while (children.next()) |child| try stack.append(self.allocator, child);
            }
        }

        fn prepareExtractedGeneratorBody(self: *Transformer, body: NodeIndex, source: ScopeId, target: ScopeId, headers: []const u32, parameters: []const u32) Transformer.Error!void {
            try self.reparentGeneratedBodyScopes(source, target, body);
            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            try stack.append(self.allocator, body);
            while (stack.pop()) |node| {
                if (node.isNone()) continue;
                const editor = &self.semantic_editor.?;
                const maybe_ref = editor.referenceForNode(node) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => std.debug.panic("extracted body lost a source reference: {s}", .{@errorName(err)}),
                };
                if (maybe_ref) |reference| {
                    if (!reference.flags.declare) {
                        var id = @backingInt(reference.symbol_id);
                        for (headers, parameters) |header, parameter| {
                            if (id == header) {
                                id = parameter;
                                break;
                            }
                        }
                        const scope = if (reference.scope_id == source) target else reference.scope_id;
                        if (scope != reference.scope_id or id != @backingInt(reference.symbol_id)) {
                            editor.relocateReference(node, scope, @fromBackingInt(id), reference.stmt_idx, reference.scope_stmt_idx) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => std.debug.panic("extracted body cannot move a source reference: {s}", .{@errorName(err)}),
                            };
                            const raw = @backingInt(node);
                            if (self.symbol_ids.items.len <= raw) try self.symbol_ids.appendNTimes(self.allocator, null, raw + 1 - self.symbol_ids.items.len);
                            self.symbol_ids.items[raw] = id;
                        }
                    }
                }
                var children = ast_walk.children(self.ast, self.ast.getNode(node));
                while (children.next()) |child| try stack.append(self.allocator, child);
            }
        }

        fn replaceAnnexBlockEdge(self: *Transformer, parent: NodeIndex, old: NodeIndex, next: NodeIndex) void {
            const node = self.ast.getNode(parent);
            var matches: usize = 0;
            switch (Tag.dataKind(node.tag)) {
                .leaf => {},
                .unary => if (node.data.unary.operand == old) {
                    self.ast.nodes.items[@backingInt(parent)].data.unary.operand = next;
                    matches += 1;
                },
                .binary => {
                    if (node.data.binary.left == old) {
                        self.ast.nodes.items[@backingInt(parent)].data.binary.left = next;
                        matches += 1;
                    }
                    if (node.data.binary.right == old) {
                        self.ast.nodes.items[@backingInt(parent)].data.binary.right = next;
                        matches += 1;
                    }
                },
                .ternary => {
                    if (node.data.ternary.a == old) {
                        self.ast.nodes.items[@backingInt(parent)].data.ternary.a = next;
                        matches += 1;
                    }
                    if (node.data.ternary.b == old) {
                        self.ast.nodes.items[@backingInt(parent)].data.ternary.b = next;
                        matches += 1;
                    }
                    if (node.data.ternary.c == old) {
                        self.ast.nodes.items[@backingInt(parent)].data.ternary.c = next;
                        matches += 1;
                    }
                },
                .list => for (node.data.list.start..node.data.list.start + node.data.list.len) |slot| {
                    if (self.ast.extra_data.items[slot] == @backingInt(old)) {
                        self.ast.extra_data.items[slot] = @backingInt(next);
                        matches += 1;
                    }
                },
                .extra => {
                    for (Tag.extraChildOffsets(node.tag)) |off| {
                        const slot = node.data.extra + off;
                        if (self.ast.extra_data.items[slot] == @backingInt(old)) {
                            self.ast.extra_data.items[slot] = @backingInt(next);
                            matches += 1;
                        }
                    }
                    for (Tag.extraListOffsets(node.tag)) |offsets| {
                        const start = self.ast.extra_data.items[node.data.extra + offsets[0]];
                        const len = self.ast.extra_data.items[node.data.extra + offsets[1]];
                        for (start..start + len) |slot| if (self.ast.extra_data.items[slot] == @backingInt(old)) {
                            self.ast.extra_data.items[slot] = @backingInt(next);
                            matches += 1;
                        };
                    }
                },
            }
            if (matches != 1) @panic("Annex B carrier has no unique actual parent edge");
        }

        fn annexEmptyCompletion(self: *Transformer, value: NodeIndex, owner: ScopeId, span: Span) Transformer.Error!NodeIndex {
            const name = try self.buildUniqueNameAvoidingDynamicEval("__zntc_annex_done", &self.block_rename_counter, owner);
            const binding = try es_helpers.makeExactSyntheticBinding(self, name);
            _ = try self.declareSyntheticInScope(binding, span, .variable_var, owner);
            const declarator = try es_helpers.makeDeclarator(self, binding, value, span);
            return es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);
        }

        fn annexSetter(self: *Transformer, variable: SymbolId, span: Span) Transformer.Error!SymbolId {
            if (self.loop_annex_b_setters.get(@backingInt(variable))) |known| return known.symbol;
            const original = self.semantic_editor.?.symbols.items[@backingInt(variable)];
            const owner = original.scope_id;
            const name = try self.buildUniqueNameAvoidingDynamicEval("__zntc_annex_set", &self.block_rename_counter, owner);
            const binding = try es_helpers.makeExactSyntheticBinding(self, name);
            const id = (try self.declareSyntheticInScope(binding, span, .variable_var, owner)).?;
            const parameter_name = try self.buildUniqueNameAvoidingDynamicEval("__zntc_annex_value", &self.block_rename_counter, owner);
            const parameter = try es_helpers.makeExactSyntheticBinding(self, parameter_name);
            const params = try self.ast.addFormalParameters(try self.ast.addNodeList(&.{parameter}), span);
            const body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
            const function = try self.addExtraNode(.function_expression, span, &.{ @backingInt(NodeIndex.none), @backingInt(params), @backingInt(body), 0, @backingInt(NodeIndex.none) });
            const scope = try self.addGeneratedFunctionScope(owner, function);
            const value_id = (try self.declareSyntheticInScope(parameter, span, .parameter, scope)).?;
            const target = try self.makeSyntheticRefForSymbol(variable, scope, .{ .write = true });
            self.ast.nodes.items[@backingInt(target)].data.string_ref = try self.ast.addString(if (original.synthetic_name.len > 0) original.synthetic_name else self.ast.getText(original.name));
            const value = try es_helpers.makeIdentifierRefFromSpan(self, try self.ast.addString(parameter_name));
            try self.addSyntheticRefInScope(value, value_id, scope, .{ .read = true });
            try self.trackExactOutputReference(target, @backingInt(variable));
            try self.trackExactOutputRead(value, @backingInt(value_id));
            const assignment = try es_helpers.makeAssignStmt(self, target, value, span, 0);
            const statements = try self.ast.addNodeList(&.{assignment});
            self.ast.nodes.items[@backingInt(body)].data.list = statements;
            try self.loop_annex_b_setters.put(self.allocator, @backingInt(variable), .{ .binding = binding, .value = function, .symbol = id, .owner = owner });
            self.generator_function_storage_changed = true;
            try self.generator_function_storage_scopes.put(self.allocator, @backingInt(owner), {});
            return id;
        }

        const AnnexCatch = struct { wrapper: NodeIndex, handler: NodeIndex, scope: ScopeId, binding: NodeIndex };
        fn annexCatch(self: *Transformer, block: NodeIndex, lexical_scope: ScopeId, lexical: SymbolId, name: []const u8) Transformer.Error!AnnexCatch {
            const span = self.ast.getNode(block).span;
            const parent = self.semantic_editor.?.scopes.items[lexical_scope.toIndex()].parent;
            const wrapper = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
            const outer = try self.addGeneratedScope(parent, wrapper, .block);
            const binding = try es_helpers.makeExactSyntheticBinding(self, name);
            const handler = try self.ast.addNode(.{ .tag = .catch_clause, .span = span, .data = .{ .binary = .{ .left = binding, .right = block, .flags = 0 } } });
            const scope = try self.addGeneratedScope(outer, handler, .catch_clause);
            const nil = try es_helpers.makeNullLiteral(self);
            const thrown = try self.ast.addNode(.{ .tag = .throw_statement, .span = span, .data = .{ .unary = .{ .operand = nil, .flags = 0 } } });
            const try_body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{thrown}) } });
            _ = try self.addGeneratedScope(outer, try_body, .block);
            const statement = try self.ast.addNode(.{ .tag = .try_statement, .span = span, .data = .{ .ternary = .{ .a = try_body, .b = handler, .c = .none } } });
            const list = try self.ast.addNodeList(&.{statement});
            self.ast.nodes.items[@backingInt(wrapper)].data.list = list;
            const editor = &self.semantic_editor.?;
            editor.scopes.items[scope.toIndex()].subtree_has_direct_eval = editor.scopes.items[lexical_scope.toIndex()].subtree_has_direct_eval;
            editor.scopes.items[scope.toIndex()].subtree_has_with = editor.scopes.items[lexical_scope.toIndex()].subtree_has_with;
            editor.reparentScope(lexical_scope, scope) catch @panic("Annex B source block lost its exact catch parent");
            editor.relocateSymbolAsPreservingAnchors(lexical, scope, binding) catch @panic("Annex B catch binding changed identity");
            editor.symbols.items[@backingInt(lexical)].kind = .catch_binding;
            editor.symbols.items[@backingInt(lexical)].decl_flags = @import("../semantic/symbol.zig").SymbolKind.catch_binding.declFlags();
            editor.symbols.items[@backingInt(lexical)].annex_b_alias.state = .lowered_catch;
            editor.ensureDeclarationAtNode(lexical, scope, binding) catch @panic("Annex B catch declaration birth failed");
            if (self.symbol_ids.items.len <= @backingInt(binding)) try self.symbol_ids.appendNTimes(self.allocator, null, @backingInt(binding) + 1 - self.symbol_ids.items.len);
            self.symbol_ids.items[@backingInt(binding)] = @backingInt(lexical);
            return .{ .wrapper = wrapper, .handler = handler, .scope = scope, .binding = binding };
        }

        // Called after the actual ordinary extraction callback owns
        // its ScopeId, before bindExtractedBodyVarStorage. No name chooses an ID.
        fn lowerExtractedNativeAnnexB(self: *Transformer, body: NodeIndex, source_scope: ScopeId, callback: ScopeId) Transformer.Error!NodeIndex {
            if (!self.semantic_edit_enabled or self.semantic_editor == null) return body;
            var output_body = body;
            const annex = @import("../semantic/annex_b_function.zig");
            const Group = struct {
                lexical: SymbolId,
                variable: SymbolId,
                block: NodeIndex,
                parent: NodeIndex,
                lexical_scope: ScopeId,
                declarations: std.ArrayList(NodeIndex) = .empty,
                output_name: []const u8 = "",
            };
            const Work = struct { node: NodeIndex, parent: NodeIndex, scope: ScopeId, block: NodeIndex, block_parent: NodeIndex };
            var groups: std.ArrayList(Group) = .empty;
            defer {
                for (groups.items) |*group| group.declarations.deinit(self.allocator);
                groups.deinit(self.allocator);
            }
            var declaration_parents: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty;
            defer declaration_parents.deinit(self.allocator);
            var by_symbol: std.AutoHashMapUnmanaged(u32, usize) = .empty;
            defer by_symbol.deinit(self.allocator);
            var stack: std.ArrayList(Work) = .empty;
            defer stack.deinit(self.allocator);
            try stack.append(self.allocator, .{ .node = body, .parent = .none, .scope = callback, .block = .none, .block_parent = .none });
            while (stack.pop()) |work| {
                if (work.node.isNone()) continue;
                const node = self.ast.getNode(work.node);
                if (node.tag == .function_declaration) {
                    const role = (annex.forDeclaration(self.ast, self.symbol_ids.items, self.semantic_editor.?.symbols.items, work.node) catch
                        @panic("extracted block function lost its typed Annex B pair")) orelse continue;
                    if (role.state != .native) continue;
                    const lexical_scope = self.semantic_editor.?.symbols.items[@backingInt(role.lexical)].scope_id;
                    if (work.block.isNone() or lexical_scope != work.scope)
                        @panic("extracted Annex B declaration has no exact lexical entry owner");
                    const slot = try by_symbol.getOrPut(self.allocator, @backingInt(role.lexical));
                    if (!slot.found_existing) {
                        slot.value_ptr.* = groups.items.len;
                        try groups.append(self.allocator, .{ .lexical = role.lexical, .variable = role.variable, .block = work.block, .parent = work.block_parent, .lexical_scope = lexical_scope });
                    }
                    const group = &groups.items[slot.value_ptr.*];
                    if (group.variable != role.variable or group.block != work.block or group.lexical_scope != lexical_scope)
                        @panic("extracted Annex B group changed its source owner");
                    try declaration_parents.put(self.allocator, @backingInt(work.node), work.parent);
                    try group.declarations.append(self.allocator, work.node);
                    continue;
                }
                if (isFunctionBoundary(node.tag) or node.tag == .class_declaration or node.tag == .class_expression) continue;
                const scope = self.outputOwnedScope(work.node) orelse work.scope;
                const is_block = node.tag == .block_statement or node.tag == .function_body;
                const block = if (is_block) work.node else work.block;
                const block_parent = if (is_block) work.parent else work.block_parent;
                // Reverse the child push, preserving source-order declaration
                // instantiation (including duplicate last-declaration semantics).
                var children: std.ArrayList(NodeIndex) = .empty;
                defer children.deinit(self.allocator);
                var it = ast_walk.children(self.ast, node);
                while (it.next()) |child| try children.append(self.allocator, child);
                var i = children.items.len;
                while (i > 0) {
                    i -= 1;
                    try stack.append(self.allocator, .{ .node = children.items[i], .parent = work.node, .scope = scope, .block = block, .block_parent = block_parent });
                }
            }
            var source_anchors = false;
            for (self.semantic_editor.?.references.items) |reference| {
                if (reference.flags.declare and !reference.declaration_node_index.isNone() and
                    @backingInt(reference.declaration_node_index) < self.parser_node_count) source_anchors = true;
            }
            if (groups.items.len > 0) {
                // Known extraction dataflow: outer-evaluated generated reads
                // in this actual body now execute in the new callback frame.
                // Nested source functions already own their separate scopes.
                try prepareExtractedGeneratorBody(self, body, source_scope, callback, &.{}, &.{});
                self.generator_function_storage_changed = true;
                try self.generator_function_storage_scopes.put(self.allocator, @backingInt(callback), {});
            }
            // Validate all complete groups before moving any binding storage.
            for (groups.items) |group| {
                const role = (annex.forSymbol(self.semantic_editor.?.symbols.items, group.lexical) catch
                    @panic("invalid extracted Annex B group")) orelse @panic("missing extracted Annex B group");
                if (role.source_assignment_count != group.declarations.items.len)
                    @panic("extracted Annex B declaration group is incomplete");
                for (group.declarations.items) |declaration| {
                    const binding = self.ast.readExtraNode(self.ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name);
                    var anchors: usize = 0;
                    for (self.semantic_editor.?.references.items) |reference| {
                        if (!reference.flags.declare or reference.declaration_node_index != binding) continue;
                        if (reference.symbol_id != group.lexical or reference.scope_id != group.lexical_scope)
                            @panic("extracted Annex B declaration changed identity or storage");
                        anchors += 1;
                    }
                    if (anchors > 1 or (source_anchors and anchors != 1)) @panic("extracted Annex B declaration has no unique exact anchor");
                }
            }
            var block_parents: std.AutoHashMapUnmanaged(u32, NodeIndex) = .empty;
            defer block_parents.deinit(self.allocator);
            for (groups.items) |*group| {
                _ = annex.markLowered(self.semantic_editor.?.symbols.items, group.lexical, @intCast(group.declarations.items.len)) catch
                    @panic("extracted Annex B implicit operation count changed");
                try @import("es2015_generator.zig").ES2015Generator(Transformer).ensureAnnexBVariableStorage(self, @backingInt(group.variable));
                const saved_scope = self.current_scope;
                self.current_scope = group.lexical_scope;
                defer self.current_scope = saved_scope;
                const original = self.semantic_editor.?.symbols.items[@backingInt(group.lexical)];
                const source_name = try self.decodedName(self.ast.getText(original.name));
                // Storage spelling is chosen for a known ID, never used to
                // recover the lexical or outer variable identity.
                const dynamic = self.semantic_editor.?.scopes.items[group.lexical_scope.toIndex()].blocksMangling();
                group.output_name = if (dynamic) source_name else try self.buildUniqueNameAvoidingDynamicEval("__zntc_annex", &self.block_rename_counter, callback);
                var setter: ?SymbolId = null;
                if (dynamic) {
                    setter = try annexSetter(self, group.variable, self.ast.getNode(group.block).span);
                    if (source_anchors) for (group.declarations.items) |declaration| {
                        const old_binding = self.ast.readExtraNode(self.ast.getNode(declaration).data.extra, ast_mod.FunctionExtra.name);
                        _ = self.semantic_editor.?.removeDeclarationAtNode(old_binding, group.lexical) catch @panic("Annex B catch lost its source declaration row");
                    };
                    const carrier = try annexCatch(self, group.block, group.lexical_scope, group.lexical, group.output_name);
                    const parent = block_parents.get(@backingInt(group.block)) orelse group.parent;
                    if (parent.isNone()) {
                        if (output_body != group.block) @panic("Annex B root block changed its owner edge");
                        output_body = carrier.wrapper;
                    } else replaceAnnexBlockEdge(self, parent, group.block, carrier.wrapper);
                    try block_parents.put(self.allocator, @backingInt(group.block), carrier.handler);
                }
                if (self.block_rename_map == null) self.block_rename_map = .empty;
                try self.block_rename_map.?.put(self.allocator, @backingInt(group.lexical), group.output_name);
                var prefix: std.ArrayList(NodeIndex) = .empty;
                defer prefix.deinit(self.allocator);
                // Each source function value is instantiated at lexical entry.
                // All keep their own AST/scopes; the last assignment wins.
                for (group.declarations.items) |declaration| {
                    const source = self.ast.getNode(declaration);
                    const old_binding = self.ast.readExtraNode(source.data.extra, ast_mod.FunctionExtra.name);
                    const expr = try self.addExtraNode(.function_expression, source.span, &.{
                        @backingInt(NodeIndex.none),                                                        @backingInt(self.ast.readExtraNode(source.data.extra, ast_mod.FunctionExtra.params)),
                        @backingInt(self.ast.readExtraNode(source.data.extra, ast_mod.FunctionExtra.body)), self.readU32(source.data.extra, 3),
                        self.readU32(source.data.extra, 4),
                    });
                    try self.remapCopiedScopeOwner(declaration, expr);
                    try self.removeInPlaceScopeOwner(declaration);
                    // Existing name restoration gives the anonymous value its
                    // source name without adding a named-expression self SID.
                    self.runtime_helpers.keep_names = true;
                    const name_helper = try es_helpers.makeRuntimeHelperRef(self, "__name");
                    const name_literal = try es_helpers.buildQuotedKeyLiteral(self, try self.ast.addString(source_name));
                    const value = try es_helpers.makeCallExpr(self, name_helper, &.{ expr, name_literal }, source.span);
                    if (dynamic) {
                        const target = try self.makeSyntheticRefForSymbol(group.lexical, group.lexical_scope, .{ .write = true });
                        self.ast.nodes.items[@backingInt(target)].data.string_ref = try self.ast.addString(group.output_name);
                        try self.trackExactOutputReference(target, @backingInt(group.lexical));
                        const assignment = try es_helpers.makeAssignExpr(self, target, value, source.span, 0);
                        try prefix.append(self.allocator, try annexEmptyCompletion(self, assignment, callback, source.span));
                    } else {
                        const binding = try es_helpers.makeExactSyntheticBinding(self, group.output_name);
                        const editor = &self.semantic_editor.?;
                        editor.relocateSymbolAsPreservingAnchors(group.lexical, callback, binding) catch @panic("extracted Annex B storage collision");
                        if (self.symbol_ids.items.len <= @backingInt(binding)) try self.symbol_ids.appendNTimes(self.allocator, null, @backingInt(binding) + 1 - self.symbol_ids.items.len);
                        self.symbol_ids.items[@backingInt(binding)] = @backingInt(group.lexical);
                        if (source_anchors) {
                            _ = editor.reanchorDeclarationFromNode(self.ast, old_binding, binding, group.lexical) catch @panic("extracted Annex B exact declaration handoff failed");
                        } else {
                            try editor.references.append(self.allocator, .{ .node_index = .none, .declaration_node_index = binding, .scope_id = callback, .symbol_id = group.lexical, .flags = .{ .declare = true } });
                        }
                        for (editor.references.items) |*reference| if (reference.flags.declare and reference.symbol_id == group.lexical) {
                            reference.scope_id = callback;
                        };
                        editor.symbols.items[@backingInt(group.lexical)].kind = .variable_var;
                        editor.symbols.items[@backingInt(group.lexical)].decl_flags = @import("../semantic/symbol.zig").SymbolKind.variable_var.declFlags();
                        const declarator = try es_helpers.makeDeclarator(self, binding, value, source.span);
                        try prefix.append(self.allocator, try es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", source.span));
                    }
                    const editor = &self.semantic_editor.?;
                    const outer = editor.symbols.items[@backingInt(group.variable)];
                    const outer_name = if (outer.synthetic_name.len > 0) outer.synthetic_name else self.ast.getText(outer.name);
                    const target = try self.makeSyntheticRefForSymbol(group.variable, group.lexical_scope, .{ .write = true });
                    self.ast.nodes.items[@backingInt(target)].data.string_ref = try self.ast.addString(outer_name);
                    const read = try es_helpers.makeIdentifierRefFromSpan(self, try self.ast.addString(group.output_name));
                    try self.addSyntheticRefInScope(read, group.lexical, group.lexical_scope, .{ .read = true });
                    try self.trackExactOutputReference(target, @backingInt(group.variable));
                    try self.trackExactOutputRead(read, @backingInt(group.lexical));
                    const operation = if (setter) |id| blk: {
                        // The setter owns the V write in its actual outer environment.
                        try self.removeSemanticReference(target);
                        const known = editor.symbols.items[@backingInt(id)];
                        const callee = try es_helpers.makeIdentifierRefFromSpan(self, try self.ast.addString(known.synthetic_name));
                        try self.addSyntheticRefInScope(callee, id, group.lexical_scope, .{ .read = true });
                        try self.trackExactOutputRead(callee, @backingInt(id));
                        break :blk try es_helpers.makeCallExpr(self, callee, &.{read}, source.span);
                    } else try es_helpers.makeAssignExpr(self, target, read, source.span, 0);
                    const assignment = try annexEmptyCompletion(self, operation, callback, source.span);
                    const parent = declaration_parents.get(@backingInt(declaration)) orelse @panic("Annex B function lost its actual source position");
                    replaceAnnexBlockEdge(self, parent, declaration, assignment);
                }
                const block_node = self.ast.getNode(group.block);
                const list = block_node.data.list;
                var statements: std.ArrayList(NodeIndex) = .empty;
                defer statements.deinit(self.allocator);
                try statements.appendSlice(self.allocator, prefix.items);
                for (self.ast.extra_data.items[list.start .. list.start + list.len]) |raw| try statements.append(self.allocator, @fromBackingInt(raw));
                const replacement = try self.ast.addNodeList(statements.items);
                self.ast.nodes.items[@backingInt(group.block)].data.list = replacement;
            }
            // Publish renamed actual value leaves by exact source SID. ES5
            // shorthand was already expanded during the original body visit.
            if (groups.items.len > 0) {
                const nodes = try ast_walk.collectReachableNodeIndicesFrom(self.allocator, self.ast, body);
                defer self.allocator.free(nodes);
                for (nodes) |raw| {
                    const node = self.ast.getNode(@fromBackingInt(raw));
                    if (node.tag != .identifier_reference and node.tag != .assignment_target_identifier) continue;
                    const sid = self.getSymbolIdAt(@fromBackingInt(raw)) orelse continue;
                    const index = by_symbol.get(sid) orelse continue;
                    const name = try self.ast.addString(groups.items[index].output_name);
                    self.ast.nodes.items[raw].data.string_ref = name;
                }
            }
            return output_body;
        }

        pub fn buildLoopClosureWithFlow(
            self: *Transformer,
            visited_body: NodeIndex,
            lexical_names: []const []const u8,
            flow: *const FlowResult,
            local_label: ?[]const u8,
            span: Span,
            is_async: bool,
            preserve_this: bool,
            /// `_loop` 을 generator 로 만들고 호출부를 `yield* _loop(...)` 로 낸다. (#4716)
            /// 본문에 `yield`/`await` 이 있어 평범한 함수로는 추출할 수 없을 때 쓴다 —
            /// 상태 기계가 `[5, __values(_loop(x))]` 위임으로 접고, `yield*` 의 값이
            /// `_loop` 의 return 값이라 break/continue/return 신호도 그대로 실려 온다.
            delegates_yield: bool,
            /// 호출자가 본문을 visit 하기 **직전**의 `temp_var_counter`. 그 뒤에 생긴 임시
            /// 변수는 본문 안에서만 쓰이므로 `_loop` 안에 선언한다 — 바깥 함수에 두면 모든
            /// 반복이 한 변수를 공유해, 반복마다 만든 클로저가 마지막 값을 보게 된다 (#4729:
            /// 루프 안 객체 리터럴의 home 임시 변수). 본문을 visit 하지 않고 넘기면 null.
            body_temp_start: ?u32,
            /// 본문의 원래 `var` 이름(`collectLoopBodyVarNames`). 함수로 뽑으면 지역 변수가 되어
            /// 루프 밖에서 사라지므로, 본문 선언은 대입으로 바꾸고 `var …, _loop = …` 로 바깥에
            /// 둔다 (#4743).
            hoist_vars: []const []const u8,
            /// `lexical_names`·`hoist_vars` 와 **같은 길이·같은 순서**의 원래 바인딩 노드. 이름으로 만드는
            /// 매개변수·인자·호이스트 선언에 심볼을 물려준다 (#4760). 예전엔 "모르면 빈 slice" 라
            /// 길이가 어긋나면 조용히 심볼 없이 만들었다 — 이제 모든 호출자가 짝을 넘기므로 필수.
            lexical_bindings: []const NodeIndex,
            hoist_bindings: []const NodeIndex,
            /// 생성자가 아는 실제 호출 위치. generator 수집기는 current_scope가 루프 스코프가 아니다.
            call_scope: @import("../semantic/scope.zig").ScopeId,
            /// 추출된 generator 함수의 실제 삽입 부모. 비-generator 호출은 `.none`.
            generator_parent_scope: @import("../semantic/scope.zig").ScopeId,
            await_driver: bool,
        ) Transformer.Error!LoopClosureResult {
            const is_generator = delegates_yield or await_driver;
            std.debug.assert(lexical_bindings.len == lexical_names.len);
            std.debug.assert(hoist_bindings.len == hoist_vars.len);
            // --- _loop 함수명 생성 ---
            // Standalone non-minified output chooses the emitted spelling after
            // all generated bindings are known. Keep a collision-free working
            // name during semantic edits; eval/with scopes use the existing
            // early, dynamic-lookup-aware collision path.
            const late_loop_output_name = es_helpers.canUseLateStandaloneOutputName(self, call_scope);
            const loop_prefix = if (late_loop_output_name) "__zntc_loop" else "_loop";
            const loop_name = if (late_loop_output_name)
                try self.buildUniqueName(loop_prefix, &self.loop_counter)
            else
                try self.buildUniqueNameAvoidingDynamicEval(loop_prefix, &self.loop_counter, call_scope);

            const needs_ret_var = flow.needsRetVar();

            // --- body 재작성 (break/continue/return → return "..." / return; / return{v:...}) ---
            var transformed_body = visited_body;
            if (flow.needsTransform()) {
                transformed_body = try transformControlFlow(self, visited_body, flow);
            }

            // #1807: FunctionExpression.body 는 spec 상 BlockStatement 여야 하므로
            // braces 없는 단일 statement body (e.g. `for (..) if (..)`) 는 감싸야
            // codegen 이 `function(x) { if (..) }` 로 emit 한다.
            if (!transformed_body.isNone()) {
                const body_node = self.ast.getNode(transformed_body);
                if (body_node.tag != .block_statement) {
                    const wrapped_list = try self.ast.addNodeList(&.{transformed_body});
                    transformed_body = try self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = body_node.span,
                        .data = .{ .list = wrapped_list },
                    });
                }
            }

            transformed_body = try hoistVarsOutOfBody(self, transformed_body, hoist_vars, call_scope);
            if (await_driver) try @import("loop_await_driver.zig").awaitToYield(self, transformed_body);

            var body_temp_bindings: std.ArrayListUnmanaged(@import("transformer/lists.zig").HoistedStateTemp) = .empty;
            defer body_temp_bindings.deinit(self.allocator);
            const before_temp_hoist = transformed_body;
            if (body_temp_start) |start| {
                if (self.temp_var_counter > start and !transformed_body.isNone()) {
                    transformed_body = if (self.semantic_edit_enabled)
                        try self.hoistTempVarsRecording(transformed_body, start, span, &body_temp_bindings)
                    else
                        try self.hoistTempVars(transformed_body, start, span);
                    self.temp_var_counter = start;
                }
            }
            try self.remapCopiedScopeOwner(before_temp_hoist, transformed_body);

            // --- function params: 캡처된 변수 ---
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            var param_bindings: std.ArrayList(NodeIndex) = .empty;
            defer param_bindings.deinit(self.allocator);
            for (lexical_names, 0..) |name, name_i| {
                const param_span = try self.ast.addString(name);
                const param = if (is_generator and self.semantic_edit_enabled)
                    try self.makeUserBinding(param_span, .none)
                else
                    try self.makeUserBinding(param_span, lexical_bindings[name_i]);
                try param_bindings.append(self.allocator, param);
                const formal = try self.ast.addNode(.{
                    .tag = .formal_parameter,
                    .span = param_span,
                    // extras = [pattern, type_ann, default, flags, deco_start, deco_len].
                    // ⚠️ deco_len 은 **0** 이어야 한다. 여기 `none`(0xFFFFFFFF)을 넣으면
                    // 이 노드를 visit 하는 순간 `visitExtraList` 가 40억 개를 순회하려다
                    // 죽는다 — 기존에는 이 파라미터가 다시 방문되지 않아 잠복해 있었다.
                    .data = .{ .extra = try self.ast.addExtras(&.{
                        @backingInt(param), @backingInt(NodeIndex.none), @backingInt(NodeIndex.none),
                        0,                  0,                           0,
                    }) },
                });
                try self.scratch.append(self.allocator, formal);
            }
            const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);

            const none = @backingInt(NodeIndex.none);
            const params_node = try self.ast.addFormalParameters(params, span);
            const func_flags: u32 = (if (is_async and !await_driver) ast_mod.FunctionFlags.is_async else 0) |
                (if (is_generator) ast_mod.FunctionFlags.is_generator else 0);
            const func_extra = try self.ast.addExtras(&.{
                none,                          @backingInt(params_node),
                @backingInt(transformed_body), func_flags,
                none,
            });
            const func_expr = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            var generator_function_scope: ?ScopeId = null;
            if (is_generator and self.semantic_edit_enabled) {
                if ((!await_driver and generator_parent_scope.isNone()) or call_scope.isNone())
                    std.debug.panic("extracted generator loop has no exact insertion scope", .{});
                const function_scope = try self.addGeneratedFunctionScope(if (await_driver) call_scope else generator_parent_scope, func_expr);
                generator_function_scope = function_scope;
                var header_symbol_ids: std.ArrayList(u32) = .empty;
                defer header_symbol_ids.deinit(self.allocator);
                var parameter_symbol_ids: std.ArrayList(u32) = .empty;
                defer parameter_symbol_ids.deinit(self.allocator);
                for (lexical_bindings, param_bindings.items) |source_binding, parameter_binding| {
                    const source_id = self.getSymbolIdAt(source_binding) orelse
                        std.debug.panic("extracted generator loop header has no source SymbolId", .{});
                    _ = try self.declareSyntheticInScope(parameter_binding, span, .parameter, function_scope);
                    const parameter_id = self.getSymbolIdAt(parameter_binding) orelse
                        std.debug.panic("extracted generator loop parameter has no generated SymbolId", .{});
                    try header_symbol_ids.append(self.allocator, source_id);
                    try parameter_symbol_ids.append(self.allocator, parameter_id);
                    // References are rebound before their ordinary visit. Carry
                    // this exact parameter's already-selected spelling through
                    // that visit, including the existing shorthand-key protocol.
                    if (self.block_rename_map) |*renames| {
                        const emitted = try self.stableName(self.ast.getText(self.ast.getNode(parameter_binding).data.string_ref));
                        try renames.put(self.allocator, parameter_id, emitted);
                    }
                }
                // for-in's computed key/index reads are created before this
                // extracted generator has an output switch. Reassign their
                // pending owner only when the exact refs are in this body;
                // the nested generator will reserve its real switch scope.
                if (!self.generator_state_machine_scope.isNone()) {
                    try self.retargetDeferredGeneratorForInBodyReferences(
                        transformed_body,
                        self.generator_state_machine_scope,
                        function_scope,
                    );
                }
                try prepareExtractedGeneratorBody(self, transformed_body, call_scope, function_scope, header_symbol_ids.items, parameter_symbol_ids.items);
                if (!await_driver and self.options.unsupported.generator) try self.deferred_generator_loop_migrations.put(self.allocator, @backingInt(function_scope), .{
                    .loop_function = func_expr,
                    .body = visited_body,
                    .enclosing_function_scope = self.current_scope,
                    .call_scope = call_scope,
                    .header_symbol_ids = try self.allocator.dupe(u32, header_symbol_ids.items),
                    .parameter_symbol_ids = try self.allocator.dupe(u32, parameter_symbol_ids.items),
                });
            }

            // Deferred state-machine callsites have no assembled callback
            // owner yet. Their existing producer binds them with that callback.
            if (!is_generator and self.semantic_edit_enabled and !call_scope.isNone()) {
                const function_scope = self.outputOwnedScope(func_expr) orelse try self.addGeneratedFunctionScope(call_scope, func_expr);
                try self.reparentGeneratedBodyScopes(call_scope, function_scope, transformed_body);
                transformed_body = try lowerExtractedNativeAnnexB(self, transformed_body, call_scope, function_scope);
                self.ast.extra_data.items[func_extra + 2] = @backingInt(transformed_body);
            }

            // The body temps were allocated before this extracted function
            // had an AST owner or ScopeId. Bind them now, after the exact
            // function scope exists, so the binding and every pending use
            // move together into the emitted `_loop` function.
            if (body_temp_bindings.items.len > 0 and self.semantic_edit_enabled) {
                if (call_scope.isNone())
                    std.debug.panic("extracted loop body temps have no exact source scope", .{});
                const function_scope = generator_function_scope orelse self.outputOwnedScope(func_expr) orelse
                    try self.addGeneratedFunctionScope(call_scope, func_expr);
                try self.bindGeneratedFunctionTemps(
                    call_scope,
                    function_scope,
                    transformed_body,
                    body_temp_bindings.items,
                    span,
                );
            }

            if (self.semantic_edit_enabled and !call_scope.isNone()) {
                const function_scope = self.outputOwnedScope(func_expr) orelse @panic("extracted body has no exact function owner");
                try bindExtractedBodyVarStorage(self, transformed_body, function_scope);
            }

            // --- var _loop = function(...) { ... } ---
            const loop_name_span = try self.ast.addString(loop_name);
            const loop_binding = try es_helpers.makeExactSyntheticBindingFromSpan(self, loop_name_span);
            const loop_symbol = try self.declareSyntheticVar(loop_binding, span);
            const loop_owner_scope = if (loop_symbol) |symbol| blk: {
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                const raw_id = @backingInt(symbol);
                if (raw_id >= symbols.len)
                    std.debug.panic("extracted loop binding has an invalid exact SymbolId", .{});
                break :blk symbols[raw_id].scope_id;
            } else .none;
            if (late_loop_output_name) {
                const symbol = loop_symbol orelse
                    std.debug.panic("late-named extracted loop has no exact SymbolId", .{});
                const editor = if (self.semantic_editor) |*existing|
                    existing
                else
                    std.debug.panic("late-named extracted loop has no semantic editor", .{});
                const generated = &editor.symbols.items[@backingInt(symbol)];
                if (!std.mem.eql(u8, generated.synthetic_name, loop_name))
                    std.debug.panic("extracted loop binding lost its staging spelling", .{});
                generated.synthetic_kind = .block_scoping_loop_binding;
                generated.output_name_hint = "_loop";
            }
            const output_function = if (await_driver or (is_generator and !self.options.unsupported.generator)) try self.visitNode(func_expr) else func_expr;
            const loop_decl = try es_helpers.makeDeclarator(self, loop_binding, output_function, span);
            var decls: std.ArrayList(NodeIndex) = .empty;
            defer decls.deinit(self.allocator);
            for (hoist_vars, 0..) |name, name_i| {
                const b = try self.makeUserBinding(try self.ast.addString(name), hoist_bindings[name_i]);
                try decls.append(self.allocator, try es_helpers.makeDeclarator(self, b, .none, span));
            }
            try decls.append(self.allocator, loop_decl);
            const loop_var = try es_helpers.makeVarDeclaration(self, decls.items, .@"var", span);

            // The call block is an actual emitted lexical owner. Reserve it
            // before its argument/helper reads are born, rather than letting
            // final binding introduce a new scope around existing rows.
            const call_block = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{}) } });
            const callsite_scope = if (!is_generator and self.semantic_edit_enabled)
                try self.addGeneratedScope(call_scope, call_block, .block)
            else
                call_scope;

            // --- _loop(i, j, ...) 호출 ---
            const scratch_top2 = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top2);
            const loop_ref = try es_helpers.makeExactSyntheticRef(self, loop_name);
            var loop_ref_scope = callsite_scope;
            if (loop_symbol) |symbol| {
                const scopes = if (self.semantic_editor) |*editor| editor.scopes.items else self.scopes;
                const symbols = if (self.semantic_editor) |*editor| editor.symbols.items else self.symbols;
                const loop_symbol_scope = symbols[@backingInt(symbol)].scope_id;
                var cursor = callsite_scope;
                var visible_from_call_scope = false;
                for (0..scopes.len) |_| {
                    if (cursor.isNone() or cursor.toIndex() >= scopes.len) break;
                    if (cursor == loop_symbol_scope) {
                        visible_from_call_scope = true;
                        break;
                    }
                    cursor = scopes[cursor.toIndex()].parent;
                }
                if (!visible_from_call_scope) {
                    if (self.current_scope.isNone()) std.debug.panic("extracted loop reference has no provisional scope", .{});
                    loop_ref_scope = self.current_scope;
                }
                try self.addSyntheticRefInScope(loop_ref, symbol, loop_ref_scope, .{ .read = true });
                if (is_generator) try self.trackGeneratorStateReference(loop_ref, symbol, loop_ref_scope, .{ .read = true });
            } else {
                try self.addSyntheticRefInScope(loop_ref, null, loop_ref_scope, .{ .read = true });
            }
            const call_callee = if (preserve_this) blk: {
                const call_prop = try es_helpers.makePropertyName(self, "call");
                try self.scratch.append(self.allocator, try es_helpers.makeThisExpr(self, span));
                break :blk try es_helpers.makeStaticMember(self, loop_ref, call_prop, span);
            } else loop_ref;
            for (lexical_names, 0..) |name, name_i| {
                const arg = try self.makeUserRefNamedAtScope(name, lexical_bindings[name_i], callsite_scope);
                try self.scratch.append(self.allocator, arg);
            }
            const loop_call = try es_helpers.makeCallExpr(self, call_callee, self.scratch.items[scratch_top2..], span);

            // is_async — `_loop(...)` 가 Promise 반환. 호출부도 `await _loop(...)` 로
            // wrap 해야 iteration 순서 보존 + needsRetVar 시 _ret 가 resolved value.
            const driver = if (await_driver) try @import("loop_await_driver.zig").build(self, loop_call, call_scope, span) else null;
            defer if (driver) |owned| self.allocator.free(owned.statements);
            const call_expr: NodeIndex = if (driver) |driven| driven.value else if (delegates_yield)
                try self.ast.addNode(.{
                    .tag = .yield_expression,
                    .span = span,
                    .data = .{ .unary = .{ .operand = loop_call, .flags = ast_mod.YieldFlags.is_delegate } },
                })
            else if (is_async)
                try es_helpers.makeAwaitExpression(self, loop_call, span)
            else
                loop_call;

            // --- 제어 흐름 후처리: var _ret = await _loop(i); if (...) ... ---
            var final_stmt: NodeIndex = undefined;
            var ret_temp_span: ?Span = null;
            var ret_temp_binding: ?NodeIndex = null;
            var ret_temp_symbol_id: ?SymbolId = null;
            var ret_temp_owner_scope: ScopeId = .none;
            if (needs_ret_var) {
                const control_flow_check = try buildControlFlowCheck(self, call_expr, flow, local_label, callsite_scope, span);
                final_stmt = control_flow_check.node;
                ret_temp_span = control_flow_check.ret_temp_span;
                ret_temp_binding = control_flow_check.ret_temp_binding;
                ret_temp_symbol_id = control_flow_check.ret_temp_symbol_id;
                ret_temp_owner_scope = control_flow_check.ret_temp_owner_scope;
            } else {
                final_stmt = try self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = call_expr, .flags = 0 } },
                });
            }

            // 호출문을 블록으로 감싸기
            var call_statements: std.ArrayList(NodeIndex) = .empty;
            defer call_statements.deinit(self.allocator);
            if (driver) |driven| try call_statements.appendSlice(self.allocator, driven.statements);
            try call_statements.append(self.allocator, final_stmt);
            const call_block_list = try self.ast.addNodeList(call_statements.items);
            self.ast.nodes.items[@backingInt(call_block)].data.list = call_block_list;

            return .{
                .loop_fn = loop_var,
                .loop_function = output_function,
                .loop_binding = loop_binding,
                .loop_symbol_id = loop_symbol,
                .loop_owner_scope = loop_owner_scope,
                .generator_function_scope = generator_function_scope,
                .call_and_check = call_block,
                .ret_temp_span = ret_temp_span,
                .ret_temp_binding = ret_temp_binding,
                .ret_temp_symbol_id = ret_temp_symbol_id,
                .ret_temp_owner_scope = ret_temp_owner_scope,
            };
        }

        /// body AST를 반복적(iterative)으로 스캔하여 break/continue/return 사용을 분석한다.
        /// 명시적 스택 사용 — stack overflow 불가능.
        pub fn analyzeControlFlow(
            self: *Transformer,
            body_idx: NodeIndex,
            flow: *FlowResult,
            init_loop_depth: u32,
            init_switch_depth: u32,
        ) void {
            const FlowEntry = struct { idx: NodeIndex, loop_depth: u32, switch_depth: u32 };
            var stack: std.ArrayList(FlowEntry) = .empty;
            defer stack.deinit(self.allocator);
            stack.append(self.allocator, .{ .idx = body_idx, .loop_depth = init_loop_depth, .switch_depth = init_switch_depth }) catch return;

            // 본문 **안에서** 정의된 라벨은 추출 후에도 그대로 유효하다 — 바깥 신호가 아니다 (#4722).
            // 예전엔 라벨 점프를 전부 바깥 신호로 봐서, 안쪽 라벨 루프의 정상 `continue B` 까지
            // `return "continue|B"` 로 바뀌어 함수를 빠져나갔다.
            var inner_labels: std.ArrayList([]const u8) = .empty;
            defer inner_labels.deinit(self.allocator);
            collectDefinedLabels(self, body_idx, &inner_labels);

            while (stack.items.len > 0) {
                const entry = stack.pop() orelse break;
                if (entry.idx.isNone()) continue;
                if (@backingInt(entry.idx) >= self.ast.nodes.items.len) continue;
                const node = self.ast.getNode(entry.idx);

                var loop_depth = entry.loop_depth;
                var switch_depth = entry.switch_depth;

                switch (node.tag) {
                    .for_statement,
                    .for_in_statement,
                    .for_of_statement,
                    .for_await_of_statement,
                    .while_statement,
                    .do_while_statement,
                    => {
                        loop_depth += 1;
                    },
                    .switch_statement => {
                        switch_depth += 1;
                    },
                    // 클로저 경계: 내부 무시. 메서드도 함수다 — 빠지면 클래스/객체
                    // 메서드 안 `return` 을 루프의 return 으로 셌다 (#4766).
                    .function_expression,
                    .function_declaration,
                    .arrow_function_expression,
                    .function,
                    .method_definition,
                    => continue,

                    .return_statement => {
                        flow.has_return = true;
                        continue;
                    },
                    .break_statement => {
                        if (node.data.unary.operand.isNone()) {
                            if (loop_depth == 0 and switch_depth == 0) flow.has_break = true;
                        } else {
                            const name = self.ast.getText(self.ast.getNode(node.data.unary.operand).span);
                            if (!containsLabel(inner_labels.items, name)) {
                                flow.has_labeled_break = true;
                                appendUniqueLabel(flow, self.allocator, name);
                            }
                        }
                        continue;
                    },
                    .continue_statement => {
                        if (node.data.unary.operand.isNone()) {
                            // unlabeled continue. loop_depth==0 이면 추출된 _loop 의
                            // outer for-of 를 타겟으로 하는 것이므로 `return;` 으로 변환 필요.
                            // 중첩 loop(>0) 안의 continue 는 해당 inner loop 가 그대로 받는다.
                            if (loop_depth == 0) flow.has_continue = true;
                        } else {
                            const name = self.ast.getText(self.ast.getNode(node.data.unary.operand).span);
                            if (!containsLabel(inner_labels.items, name)) {
                                flow.has_labeled_continue = true;
                                appendUniqueLabel(flow, self.allocator, name);
                            }
                        }
                        continue;
                    },
                    else => {},
                }

                var children: std.ArrayList(NodeIndex) = .empty;
                defer children.deinit(self.allocator);
                collectChildIndices(self, node, &children) catch {};
                for (children.items) |child_idx| {
                    stack.append(self.allocator, .{ .idx = child_idx, .loop_depth = loop_depth, .switch_depth = switch_depth }) catch {};
                }
            }
        }

        fn containsLabel(labels: []const []const u8, name: []const u8) bool {
            for (labels) |l| if (Scanner.identifierNamesEqual(l, name)) return true;
            return false;
        }

        /// body 안(클로저 경계 제외)에서 정의된 라벨 이름을 모은다.
        fn collectDefinedLabels(self: *Transformer, body_idx: NodeIndex, out: *std.ArrayList([]const u8)) void {
            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            stack.append(self.allocator, body_idx) catch return;
            while (stack.pop()) |idx| {
                if (idx.isNone() or @backingInt(idx) >= self.ast.nodes.items.len) continue;
                const node = self.ast.getNode(idx);
                switch (node.tag) {
                    .function_expression, .function_declaration, .arrow_function_expression, .function, .method_definition => continue,
                    .labeled_statement => if (!node.data.binary.left.isNone()) {
                        out.append(self.allocator, self.ast.getText(self.ast.getNode(node.data.binary.left).span)) catch {};
                    },
                    else => {},
                }
                var children: std.ArrayList(NodeIndex) = .empty;
                defer children.deinit(self.allocator);
                collectChildIndices(self, node, &children) catch {};
                stack.appendSlice(self.allocator, children.items) catch {};
            }
        }

        /// label 중복 없이 추가
        fn appendUniqueLabel(flow: *FlowResult, alloc: std.mem.Allocator, label_text: []const u8) void {
            for (flow.labels.items) |l| {
                if (Scanner.identifierNamesEqual(l, label_text)) return;
            }
            flow.labels.append(alloc, label_text) catch {};
        }

        /// body 내부의 break/continue/return을 _loop 함수에 맞게 변환한다.
        /// return expr → return { v: expr }
        /// break → return "break"
        /// continue → return (값 없음)
        fn transformControlFlow(
            self: *Transformer,
            body_idx: NodeIndex,
            flow: *const FlowResult,
        ) Transformer.Error!NodeIndex {
            const next = try transformControlFlowInner(self, body_idx, flow);
            try self.remapCopiedScopeOwner(body_idx, next);
            return next;
        }

        fn transformControlFlowInner(
            self: *Transformer,
            body_idx: NodeIndex,
            flow: *const FlowResult,
        ) Transformer.Error!NodeIndex {
            if (body_idx.isNone()) return body_idx;
            const body = self.ast.getNode(body_idx);
            // body 가 block 이 아닐 때도 transformStmtFlow 로 재귀 변환해야 한다.
            // e.g. `for (let x of a) if (cond) continue;` — body 가 if_statement 이고
            // 내부 continue 는 반드시 `return;` 으로 바뀌어야 한다 (#1807 후속).
            if (body.tag != .block_statement) {
                return transformStmtFlow(self, body_idx, flow, 0, 0);
            }

            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // realloc-safe — transformStmtFlow 재귀가 addNode/addNodeList 로 extra_data grow 가능 (#2426).
            var iter = self.ast.iterateExtraList(body.data.list);
            while (iter.next()) |stmt| {
                const transformed = try transformStmtFlow(self, stmt, flow, 0, 0);
                try self.scratch.append(self.allocator, transformed);
            }

            const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = body.span,
                .data = .{ .list = new_list },
            });
        }

        fn transformStmtFlow(
            self: *Transformer,
            idx: NodeIndex,
            flow: *const FlowResult,
            loop_depth: u32,
            switch_depth: u32,
        ) Transformer.Error!NodeIndex {
            const next = try transformStmtFlowInner(self, idx, flow, loop_depth, switch_depth);
            try self.remapCopiedScopeOwner(idx, next);
            return next;
        }

        fn transformStmtFlowInner(
            self: *Transformer,
            idx: NodeIndex,
            flow: *const FlowResult,
            loop_depth: u32,
            switch_depth: u32,
        ) Transformer.Error!NodeIndex {
            if (idx.isNone()) return idx;
            const node = self.ast.getNode(idx);

            switch (node.tag) {
                // 중첩 루프/switch: depth 증가
                .for_statement,
                .for_in_statement,
                .for_of_statement,
                .for_await_of_statement,
                .while_statement,
                .do_while_statement,
                => return transformFlowInLoop(self, idx, node, flow, loop_depth + 1, switch_depth),

                .switch_statement => return transformFlowInLoop(self, idx, node, flow, loop_depth, switch_depth + 1),

                // 클로저 경계: 변환하지 않음
                .function_expression,
                .function_declaration,
                .arrow_function_expression,
                .function,
                => return idx,

                .return_statement => {
                    if (flow.has_return) {
                        // return expr → return { v: expr }
                        const val = node.data.unary.operand;
                        if (val.isNone()) {
                            // return; → return { v: void 0 }
                            const void_zero = try es_helpers.makeVoidZero(self, node.span);
                            const obj = try buildReturnObject(self, void_zero, node.span);
                            return self.ast.addNode(.{
                                .tag = .return_statement,
                                .span = node.span,
                                .data = .{ .unary = .{ .operand = obj, .flags = 0 } },
                            });
                        }
                        const obj = try buildReturnObject(self, val, node.span);
                        return self.ast.addNode(.{
                            .tag = .return_statement,
                            .span = node.span,
                            .data = .{ .unary = .{ .operand = obj, .flags = 0 } },
                        });
                    }
                    return idx;
                },
                .break_statement => {
                    if (node.data.unary.operand.isNone()) {
                        // unlabeled break
                        if (loop_depth == 0 and switch_depth == 0 and flow.has_break) {
                            // break → return "break"
                            const str = try es_helpers.buildStringNode(self, "\"break\"", node.span);
                            return self.ast.addNode(.{
                                .tag = .return_statement,
                                .span = node.span,
                                .data = .{ .unary = .{ .operand = str, .flags = 0 } },
                            });
                        }
                    } else if (flow.has_labeled_break and
                        containsLabel(flow.labels.items, self.ast.getText(self.ast.getNode(node.data.unary.operand).span)))
                    {
                        // break label → return "break|label" (본문 밖 라벨만 — #4722)
                        const label_text = self.ast.getText(self.ast.getNode(node.data.unary.operand).span);
                        const sentinel = try std.fmt.allocPrint(self.allocator, "\"break|{s}\"", .{label_text});
                        defer self.allocator.free(sentinel);
                        const str = try es_helpers.buildStringNode(self, sentinel, node.span);
                        return self.ast.addNode(.{
                            .tag = .return_statement,
                            .span = node.span,
                            .data = .{ .unary = .{ .operand = str, .flags = 0 } },
                        });
                    }
                    return idx;
                },
                .continue_statement => {
                    if (node.data.unary.operand.isNone()) {
                        // unlabeled continue → return (빈 return)
                        if (loop_depth == 0) {
                            return self.ast.addNode(.{
                                .tag = .return_statement,
                                .span = node.span,
                                .data = .{ .unary = .{ .operand = NodeIndex.none, .flags = 0 } },
                            });
                        }
                    } else if (flow.has_labeled_continue and
                        containsLabel(flow.labels.items, self.ast.getText(self.ast.getNode(node.data.unary.operand).span)))
                    {
                        // continue label → return "continue|label" (본문 밖 라벨만 — #4722)
                        const label_text = self.ast.getText(self.ast.getNode(node.data.unary.operand).span);
                        const sentinel = try std.fmt.allocPrint(self.allocator, "\"continue|{s}\"", .{label_text});
                        defer self.allocator.free(sentinel);
                        const str = try es_helpers.buildStringNode(self, sentinel, node.span);
                        return self.ast.addNode(.{
                            .tag = .return_statement,
                            .span = node.span,
                            .data = .{ .unary = .{ .operand = str, .flags = 0 } },
                        });
                    }
                    return idx;
                },

                // block_statement: 내부 문들을 재귀 변환
                .block_statement => {
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    // realloc-safe — transformStmtFlow 재귀가 extra_data grow 가능 (#2426).
                    var iter = self.ast.iterateExtraList(node.data.list);
                    while (iter.next()) |stmt| {
                        try self.scratch.append(self.allocator, try transformStmtFlow(self, stmt, flow, loop_depth, switch_depth));
                    }
                    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    return self.ast.addNode(.{
                        .tag = .block_statement,
                        .span = node.span,
                        .data = .{ .list = new_list },
                    });
                },

                // if_statement: consequent/alternate 재귀
                .if_statement => {
                    const new_cons = try transformStmtFlow(self, node.data.ternary.b, flow, loop_depth, switch_depth);
                    const new_alt = try transformStmtFlow(self, node.data.ternary.c, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = .if_statement,
                        .span = node.span,
                        .data = .{ .ternary = .{ .a = node.data.ternary.a, .b = new_cons, .c = new_alt } },
                    });
                },

                // labeled_statement: 내부 문 재귀
                .labeled_statement => {
                    const new_body = try transformStmtFlow(self, node.data.binary.right, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = .labeled_statement,
                        .span = node.span,
                        .data = .{ .binary = .{ .left = node.data.binary.left, .right = new_body, .flags = node.data.binary.flags } },
                    });
                },

                // try_statement: try/catch/finally 재귀
                .try_statement => {
                    const new_try = try transformStmtFlow(self, node.data.ternary.a, flow, loop_depth, switch_depth);
                    const new_catch = try transformStmtFlow(self, node.data.ternary.b, flow, loop_depth, switch_depth);
                    const new_finally = try transformStmtFlow(self, node.data.ternary.c, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = .try_statement,
                        .span = node.span,
                        .data = .{ .ternary = .{ .a = new_try, .b = new_catch, .c = new_finally } },
                    });
                },

                .catch_clause => {
                    const new_body = try transformStmtFlow(self, node.data.binary.right, flow, loop_depth, switch_depth);
                    if (new_body == node.data.binary.right) return idx;
                    return self.ast.addNode(.{
                        .tag = .catch_clause,
                        .span = node.span,
                        .data = .{ .binary = .{
                            .left = node.data.binary.left,
                            .right = new_body,
                            .flags = node.data.binary.flags,
                        } },
                    });
                },

                else => return idx,
            }
        }

        /// 중첩 루프/switch 내부의 body만 변환
        fn transformFlowInLoop(
            self: *Transformer,
            _: NodeIndex,
            node: Node,
            flow: *const FlowResult,
            loop_depth: u32,
            switch_depth: u32,
        ) Transformer.Error!NodeIndex {
            // for_statement의 body, while의 body 등을 재귀 변���
            // 각 노드 타입에 따라 body 위치가 다름
            switch (node.tag) {
                .for_statement => {
                    const e = node.data.extra;
                    const new_body = try transformStmtFlow(self, self.readNodeIdx(e, 3), flow, loop_depth, switch_depth);
                    return self.addExtraNode(.for_statement, node.span, &.{
                        self.ast.extra_data.items[e],
                        self.ast.extra_data.items[e + 1],
                        self.ast.extra_data.items[e + 2],
                        @backingInt(new_body),
                    });
                },
                .while_statement, .do_while_statement => {
                    const new_body = try transformStmtFlow(self, node.data.binary.right, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = node.tag,
                        .span = node.span,
                        .data = .{ .binary = .{ .left = node.data.binary.left, .right = new_body, .flags = node.data.binary.flags } },
                    });
                },
                .for_in_statement, .for_of_statement, .for_await_of_statement => {
                    const new_body = try transformStmtFlow(self, node.data.ternary.c, flow, loop_depth, switch_depth);
                    return self.ast.addNode(.{
                        .tag = node.tag,
                        .span = node.span,
                        .data = .{ .ternary = .{ .a = node.data.ternary.a, .b = node.data.ternary.b, .c = new_body } },
                    });
                },
                .switch_statement => {
                    // switch cases 내부의 문들을 재귀 변환
                    const e = node.data.extra;
                    const cases_start = self.readU32(e, 1);
                    const cases_len = self.readU32(e, 2);
                    const scratch_top = self.scratch.items.len;
                    defer self.scratch.shrinkRetainingCapacity(scratch_top);
                    for (0..cases_len) |ci| {
                        const case_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[cases_start + ci]));
                        const case_node = self.ast.getNode(case_idx);
                        // switch_case: extra = [test(0), stmts_start(1), stmts_len(2)]
                        const ce = case_node.data.extra;
                        const test_node: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[ce]));
                        const case_stmts_start = self.ast.extra_data.items[ce + 1];
                        const case_stmts_len = self.ast.extra_data.items[ce + 2];
                        // case body 의 각 문을 재귀 변환. inner_scratch 는 transform
                        // 으로 생긴 임시 stmt 인덱스들만 추적 — addNodeList 로 복사된
                        // 뒤에는 즉시 shrink 해야 뒤따르는 switch_case append 가
                        // scratch_top 바로 위에 놓인다 (shrink 가 append 이후에 일어나면
                        // 방금 추가한 switch_case 까지 잘려나간다).
                        const inner_scratch = self.scratch.items.len;
                        for (0..case_stmts_len) |si| {
                            const stmt_idx: NodeIndex = @fromBackingInt(@intCast(self.ast.extra_data.items[case_stmts_start + si]));
                            try self.scratch.append(self.allocator, try transformStmtFlow(self, stmt_idx, flow, loop_depth, switch_depth));
                        }
                        const new_stmts = try self.ast.addNodeList(self.scratch.items[inner_scratch..]);
                        self.scratch.shrinkRetainingCapacity(inner_scratch);
                        try self.scratch.append(self.allocator, try self.addExtraNode(.switch_case, case_node.span, &.{
                            @backingInt(test_node), new_stmts.start, new_stmts.len,
                        }));
                    }
                    const new_cases = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    return self.addExtraNode(.switch_statement, node.span, &.{
                        self.ast.extra_data.items[e],
                        new_cases.start,
                        new_cases.len,
                    });
                },
                else => return NodeIndex.none,
            }
        }

        /// { v: expr } 객체 리터럴을 생성한다 (return 변환용).
        fn buildReturnObject(self: *Transformer, value: NodeIndex, span: Span) Transformer.Error!NodeIndex {
            // variant-typed helper — tag 에 맞는 variant 를 debug 빌드에서 assertion.
            // (이전에는 `addNode` 직접 호출로 `object_property` 에 `.extra` variant 를
            // 잘못 써서 codegen panic — #1797.)
            const key = try es_helpers.makePropertyName(self, "v");
            const prop = try self.ast.addBinaryNode(.object_property, span, key, value, 0);
            const obj_list = try self.ast.addNodeList(&.{prop});
            return self.ast.addListNode(.object_expression, span, obj_list);
        }

        /// _loop() 호출 후 제어 흐름 체크 코드를 생성한다.
        /// var _ret = _loop(i); if (typeof _ret === "object") return _ret.v; if (_ret === "break") break;
        /// `label_scope` 를 위에서부터 훑어 경계(null) 전에 `label` 이 있으면 true.
        fn labelVisibleWithoutBoundary(self: *Transformer, label: []const u8) bool {
            var i = self.label_scope.items.len;
            while (i > 0) {
                i -= 1;
                const entry = self.label_scope.items[i] orelse return false;
                if (Scanner.identifierNamesEqual(entry, label)) return true;
            }
            return false;
        }

        fn makeControlFlowRetRef(
            self: *Transformer,
            binding: NodeIndex,
            name: []const u8,
            symbol: ?SymbolId,
            call_scope: ScopeId,
        ) Transformer.Error!NodeIndex {
            const ref = try es_helpers.makeExactSyntheticRef(self, name);
            if (symbol) |id| {
                const reference_scope = if (call_scope.isNone()) self.programScope() else call_scope;
                try self.addSyntheticRefInScope(ref, id, reference_scope, .{ .read = true });
            } else if (self.semantic_edit_enabled and self.state_machine_depth > 0) {
                if (!call_scope.isNone())
                    std.debug.panic("loop control-flow temp has an output scope but no producer SymbolId", .{});
                try self.trackGeneratedCallbackTempReference(binding, ref, self.current_scope, .{ .read = true });
            }
            return ref;
        }

        fn buildControlFlowCheck(
            self: *Transformer,
            loop_call: NodeIndex,
            flow: *const FlowResult,
            local_label: ?[]const u8,
            call_scope: @import("../semantic/scope.zig").ScopeId,
            span: Span,
        ) Transformer.Error!ControlFlowCheck {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // Use a per-loop exact name/span so deferred generator callback
            // references cannot merge with another loop's `_ret` chain.
            const binding_scope: @import("../semantic/scope.zig").ScopeId = if (self.semantic_edit_enabled)
                if (call_scope.isNone()) self.programScope() else self.nearestVarScope(call_scope)
            else
                .none;
            const dynamic_scope = if (call_scope.isNone()) self.current_scope else call_scope;
            const late_ret_output_name = self.semantic_edit_enabled and self.state_machine_depth == 0 and
                es_helpers.canUseLateStandaloneOutputName(self, binding_scope);
            const ret_prefix = if (late_ret_output_name) "__zntc_loop_ret" else "_ret";
            const ret_name = if (late_ret_output_name)
                try es_helpers.uniqueSyntheticName(self, ret_prefix, &self.control_flow_ret_counter)
            else
                try es_helpers.uniqueSyntheticNameAvoidingDynamicEval(self, ret_prefix, &self.control_flow_ret_counter, dynamic_scope);
            const ret_name_span = try self.ast.addString(ret_name);
            const ret_binding = try es_helpers.makeExactSyntheticBinding(self, ret_name);
            const ret_declarator = try es_helpers.makeDeclarator(self, ret_binding, loop_call, span);
            const ret_decl = try es_helpers.makeVarDeclaration(self, &.{ret_declarator}, .@"var", span);
            const ret_symbol: ?SymbolId = if (!self.semantic_edit_enabled)
                null
            else if (call_scope.isNone() and self.state_machine_depth > 0) blk: {
                try self.bindHoistedTemp(ret_binding, ret_name_span, span, .none);
                break :blk null;
            } else blk: {
                break :blk try self.declareSyntheticTempInScope(ret_binding, span, binding_scope);
            };
            if (late_ret_output_name) {
                const symbol = ret_symbol orelse std.debug.panic("late-named loop control-flow result has no exact SymbolId", .{});
                es_helpers.markStandaloneLateSyntheticOutputName(self, symbol, self.ast.getText(ret_name_span), .block_scoping_loop_ret_binding, "_ret");
            }
            try self.scratch.append(self.allocator, ret_decl);

            // if (typeof _ret === "object") return _ret.v;
            if (flow.has_return) {
                const ret_ref = try makeControlFlowRetRef(self, ret_binding, ret_name, ret_symbol, call_scope);
                // variant-typed helper — `unary_expression` 은 `.extra = [operand, op]`
                // layout. (이전엔 `.unary` variant 로 잘못 써서 `if (<= === "object")`
                // syntax error — #1797.)
                const typeof_extra = try self.ast.addExtras(&.{
                    @backingInt(ret_ref),
                    @backingInt(token_mod.Kind.kw_typeof),
                });
                const typeof_expr = try self.ast.addExtraNode(.unary_expression, span, typeof_extra);
                const obj_str = try es_helpers.buildStringNode(self, "\"object\"", span);
                const typeof_check = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = typeof_expr, .right = obj_str, .flags = @backingInt(token_mod.Kind.eq3) } },
                });
                // _ret.v
                const ret_ref2 = try makeControlFlowRetRef(self, ret_binding, ret_name, ret_symbol, call_scope);
                const v_prop = try es_helpers.makePropertyName(self, "v");
                const ret_v = try es_helpers.makeStaticMember(self, ret_ref2, v_prop, span);
                const return_stmt = try self.ast.addNode(.{
                    .tag = .return_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = ret_v, .flags = 0 } },
                });
                const if_return = try self.ast.addNode(.{
                    .tag = .if_statement,
                    .span = span,
                    .data = .{ .ternary = .{ .a = typeof_check, .b = return_stmt, .c = NodeIndex.none } },
                });
                try self.scratch.append(self.allocator, if_return);
            }

            // if (_ret === "break") break;
            if (flow.has_break) {
                const ret_ref = try makeControlFlowRetRef(self, ret_binding, ret_name, ret_symbol, call_scope);
                const break_str = try es_helpers.buildStringNode(self, "\"break\"", span);
                const break_check = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = ret_ref, .right = break_str, .flags = @backingInt(token_mod.Kind.eq3) } },
                });
                const break_stmt = try self.ast.addNode(.{
                    .tag = .break_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = NodeIndex.none, .flags = 0 } },
                });
                const if_break = try self.ast.addNode(.{
                    .tag = .if_statement,
                    .span = span,
                    .data = .{ .ternary = .{ .a = break_check, .b = break_stmt, .c = NodeIndex.none } },
                });
                try self.scratch.append(self.allocator, if_break);
            }

            // labeled break/continue 처리
            for (flow.labels.items) |label| {
                // if (_ret === "break|label") break label;
                // if (_ret === "continue|label") continue label;
                for ([_][]const u8{ "break", "continue" }) |kw| {
                    const sentinel = try std.fmt.allocPrint(self.allocator, "\"{s}|{s}\"", .{ kw, label });
                    defer self.allocator.free(sentinel);
                    const ret_ref = try makeControlFlowRetRef(self, ret_binding, ret_name, ret_symbol, call_scope);
                    const sentinel_str = try es_helpers.buildStringNode(self, sentinel, span);
                    const check = try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = ret_ref, .right = sentinel_str, .flags = @backingInt(token_mod.Kind.eq3) } },
                    });
                    // 라벨이 **경계 없이 보이면** `break/continue <label>` 로 바로 점프하고, 클로저
                    // 경계 너머면 `return "<kw>|<label>"` 로 한 단계 위 클로저에 전달한다 (#4722).
                    // 예전엔 자기 루프 라벨(local_label)만 점프로 봤다 — 바깥 루프가 **추출되지 않은
                    // 같은 함수의 루프**여도 return 으로 전달해 함수 전체를 빠져나갔다(동기 코드에서도).
                    // 반대로 무조건 점프하면 중첩 추출에서 `break B` 가 정의 안 된 라벨이 된다.
                    const jump = (local_label != null and Scanner.identifierNamesEqual(local_label.?, label)) or
                        labelVisibleWithoutBoundary(self, label);
                    const ctrl_stmt = if (jump) blk: {
                        // 라벨 이름 — 변수가 아니라 심볼이 없다.
                        const label_node = try es_helpers.makePropertyName(self, label);
                        const ctrl_tag: Tag = if (std.mem.eql(u8, kw, "break")) .break_statement else .continue_statement;
                        break :blk try self.ast.addNode(.{
                            .tag = ctrl_tag,
                            .span = span,
                            .data = .{ .unary = .{ .operand = label_node, .flags = 0 } },
                        });
                    } else try self.ast.addNode(.{
                        .tag = .return_statement,
                        .span = span,
                        .data = .{ .unary = .{ .operand = sentinel_str, .flags = 0 } },
                    });
                    const if_ctrl = try self.ast.addNode(.{
                        .tag = .if_statement,
                        .span = span,
                        .data = .{ .ternary = .{ .a = check, .b = ctrl_stmt, .c = NodeIndex.none } },
                    });
                    try self.scratch.append(self.allocator, if_ctrl);
                }
            }

            // 모든 문을 블록으로 감싸기
            const block_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            const block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = block_list },
            });
            return .{
                .node = block,
                .ret_temp_span = ret_name_span,
                .ret_temp_binding = ret_binding,
                .ret_temp_symbol_id = ret_symbol,
                .ret_temp_owner_scope = if (ret_symbol != null) binding_scope else .none,
            };
        }
    };
}

test "ES2015 block scoping module compiles" {
    const std_lib = @import("std");
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.@"var")); // var → var
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.let)); // let → var
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.@"const")); // const → var
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.using)); // using → var
    try std_lib.testing.expectEqual(VariableDeclarationKind.@"var", lowerKind(.await_using)); // await_using → var
}
