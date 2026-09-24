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
const ast_walk = @import("../parser/ast_walk.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;

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

        /// for 루프의 init에서 let/const 변수 이름을 수집한다.
        /// 반환: 수집된 변수 이름 목록. 비어 있으면 클로저 캡처 분석 불필요.
        pub fn collectLexicalVarNames(
            self: *Transformer,
            init_idx: NodeIndex,
        ) !std.ArrayList([]const u8) {
            var names: std.ArrayList([]const u8) = .empty;
            if (init_idx.isNone()) return names;
            const init = self.ast.getNode(init_idx);
            if (init.tag != .variable_declaration) return names;

            if (!self.ast.variableDeclarationKind(init).isLexical()) return names;

            const e = init.data.extra;

            const list_start = self.readU32(e, 1);
            const list_len = self.readU32(e, 2);

            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const decl_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list_start + i]);
                const decl = self.ast.getNode(decl_idx);
                if (decl.tag != .variable_declarator) continue;
                const name_idx = self.readNodeIdx(decl.data.extra, 0);
                try collectBindingNames(self, name_idx, &names);
            }
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
                try names.append(self.allocator, try self.stableName(self.ast.getText(leaf.span)));
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
                if (@intFromEnum(entry.idx) >= max_node) continue;
                const node = self.ast.getNode(entry.idx);

                const in_closure = entry.in_closure or isFunctionBoundary(node.tag);

                if (visit(ctx, node, in_closure)) return true;

                var children: std.ArrayList(NodeIndex) = .empty;
                defer children.deinit(self.allocator);
                collectChildIndices(self, node, &children) catch return true;
                for (children.items) |child_idx| {
                    stack.append(self.allocator, .{ .idx = child_idx, .in_closure = in_closure }) catch return true;
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
                        if (std.mem.eql(u8, name, ln)) return true;
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
            if (body_idx.isNone()) return;
            var ctx: LoopBodyScan = .{ .self = self, .include_catch = false };
            defer ctx.found.deinit(self.allocator);
            defer ctx.class_names.deinit(self.allocator);
            try ast_walk.walkPreorderIterative(self.allocator, self.ast, body_idx, &ctx, LoopBodyScan.varVisit);
            for (ctx.found.items) |idx| try collectBindingNames(self, idx, out);
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
                    const d = ctx.self.ast.getNode(@enumFromInt(ctx.self.ast.extra_data.items[ds + j]));
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
        fn hoistVarsOutOfBody(self: *Transformer, idx: NodeIndex, names: []const []const u8) Transformer.Error!NodeIndex {
            if (idx.isNone() or names.len == 0) return idx;
            const node = self.ast.getNode(idx);
            switch (node.tag) {
                .block_statement => {
                    var items: std.ArrayList(NodeIndex) = .empty;
                    defer items.deinit(self.allocator);
                    var changed = false;
                    var i: u32 = 0;
                    while (i < node.data.list.len) : (i += 1) {
                        const child: NodeIndex = @enumFromInt(self.ast.extra_data.items[node.data.list.start + i]);
                        const cn = self.ast.getNode(child);
                        if (cn.tag == .variable_declaration and isHoistableVar(self, cn, names)) {
                            try appendVarAsAssignments(self, cn, names, &items);
                            changed = true;
                            continue;
                        }
                        const nc = try hoistVarsOutOfBody(self, child, names);
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
                    try appendVarAsAssignments(self, node, names, &items);
                    return self.ast.addNode(.{ .tag = .block_statement, .span = node.span, .data = .{ .list = try self.ast.addNodeList(items.items) } });
                },
                .if_statement => {
                    const t = node.data.ternary;
                    const b = try hoistVarsOutOfBody(self, t.b, names);
                    const c = try hoistVarsOutOfBody(self, t.c, names);
                    if (b == t.b and c == t.c) return idx;
                    return self.ast.addNode(.{ .tag = .if_statement, .span = node.span, .data = .{ .ternary = .{ .a = t.a, .b = b, .c = c } } });
                },
                .while_statement, .do_while_statement, .labeled_statement => {
                    const r = try hoistVarsOutOfBody(self, node.data.binary.right, names);
                    if (r == node.data.binary.right) return idx;
                    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .binary = .{ .left = node.data.binary.left, .right = r, .flags = node.data.binary.flags } } });
                },
                .for_statement => {
                    const e = node.data.extra;
                    var init = self.readNodeIdx(e, 0);
                    if (!init.isNone()) {
                        const init_node = self.ast.getNode(init);
                        if (init_node.tag == .variable_declaration and isHoistableVar(self, init_node, names)) init = try varAsExpression(self, init_node, names);
                    }
                    const body = try hoistVarsOutOfBody(self, self.readNodeIdx(e, 3), names);
                    if (init == self.readNodeIdx(e, 0) and body == self.readNodeIdx(e, 3)) return idx;
                    return self.addExtraNode(.for_statement, node.span, &.{
                        @intFromEnum(init), @intFromEnum(self.readNodeIdx(e, 1)), @intFromEnum(self.readNodeIdx(e, 2)), @intFromEnum(body),
                    });
                },
                .for_in_statement, .for_of_statement, .for_await_of_statement => {
                    const t = node.data.ternary;
                    var left = t.a;
                    if (!left.isNone()) {
                        const ln = self.ast.getNode(left);
                        if (ln.tag == .variable_declaration and isHoistableVar(self, ln, names)) {
                            const d = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[self.readU32(ln.data.extra, 1)]));
                            const b = self.ast.getNode(self.readNodeIdx(d.data.extra, 0));
                            if (b.tag == .binding_identifier) left = try es_helpers.makeIdentifierRefFromSpan(self, b.data.string_ref);
                        }
                    }
                    const c = try hoistVarsOutOfBody(self, t.c, names);
                    if (left == t.a and c == t.c) return idx;
                    return self.ast.addNode(.{ .tag = node.tag, .span = node.span, .data = .{ .ternary = .{ .a = left, .b = t.b, .c = c } } });
                },
                .try_statement => {
                    const t = node.data.ternary;
                    const a = try hoistVarsOutOfBody(self, t.a, names);
                    var b = t.b;
                    if (!b.isNone()) {
                        const cc = self.ast.getNode(b);
                        const body = try hoistVarsOutOfBody(self, cc.data.binary.right, names);
                        if (body != cc.data.binary.right) b = try self.ast.addNode(.{ .tag = .catch_clause, .span = cc.span, .data = .{ .binary = .{ .left = cc.data.binary.left, .right = body, .flags = cc.data.binary.flags } } });
                    }
                    const c = try hoistVarsOutOfBody(self, t.c, names);
                    if (a == t.a and b == t.b and c == t.c) return idx;
                    return self.ast.addNode(.{ .tag = .try_statement, .span = node.span, .data = .{ .ternary = .{ .a = a, .b = b, .c = c } } });
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
                        const case_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[cs + i]);
                        const cn = self.ast.getNode(case_idx);
                        const ce = cn.data.extra;
                        const block = try self.ast.addNode(.{ .tag = .block_statement, .span = cn.span, .data = .{ .list = .{ .start = self.readU32(ce, 1), .len = self.readU32(ce, 2) } } });
                        const nb = try hoistVarsOutOfBody(self, block, names);
                        if (nb == block) {
                            try cases.append(self.allocator, case_idx);
                            continue;
                        }
                        changed = true;
                        const bl = self.ast.getNode(nb).data.list;
                        try cases.append(self.allocator, try self.addExtraNode(.switch_case, cn.span, &.{ @intFromEnum(self.readNodeIdx(ce, 0)), bl.start, bl.len }));
                    }
                    if (!changed) return idx;
                    const list = try self.ast.addNodeList(cases.items);
                    return self.addExtraNode(.switch_statement, node.span, &.{ @intFromEnum(self.readNodeIdx(e, 0)), list.start, list.len });
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
                const d = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[ds + j]));
                if (d.tag != .variable_declarator) return false;
                const b = self.ast.getNode(self.readNodeIdx(d.data.extra, 0));
                if (b.tag != .binding_identifier) return false;
                if (!nameIn(self.ast.getText(b.data.string_ref), names)) return false;
            }
            return true;
        }

        fn nameIn(name: []const u8, names: []const []const u8) bool {
            for (names) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
            return false;
        }

        /// `var a = 1, b;` → `a = 1;` (초기값 없는 declarator 는 버린다)
        fn appendVarAsAssignments(self: *Transformer, node: Node, names: []const []const u8, out: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            _ = names;
            const ds = self.readU32(node.data.extra, 1);
            const dl = self.readU32(node.data.extra, 2);
            var j: u32 = 0;
            while (j < dl) : (j += 1) {
                const d = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[ds + j]));
                const init = self.readNodeIdx(d.data.extra, 2);
                if (init.isNone()) continue;
                const b = self.ast.getNode(self.readNodeIdx(d.data.extra, 0));
                const assign = try self.ast.addNode(.{ .tag = .assignment_expression, .span = d.span, .data = .{ .binary = .{
                    .left = try es_helpers.makeIdentifierRefFromSpan(self, b.data.string_ref),
                    .right = init,
                    .flags = 0,
                } } });
                try out.append(self.allocator, try es_helpers.makeExprStmt(self, assign, d.span));
            }
        }

        /// for 헤더용: `var i = 0, j = 1` → `i = 0, j = 1` (없으면 none)
        fn varAsExpression(self: *Transformer, node: Node, names: []const []const u8) Transformer.Error!NodeIndex {
            var stmts: std.ArrayList(NodeIndex) = .empty;
            defer stmts.deinit(self.allocator);
            try appendVarAsAssignments(self, node, names, &stmts);
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
            return anyMatchInsideClosure(self, body_idx, {}, struct {
                fn visit(_: void, node: Node, in_closure: bool) bool {
                    return !in_closure and node.tag == .await_expression;
                }
            }.visit);
        }

        /// loop body 를 `_loop` 함수로 추출할 때 원래 body 의 lexical `this` /
        /// `super` 의미가 필요한지 검사한다. 일반 function/class/method 는 자체
        /// `this` 를 가지므로 경계에서 멈추고, arrow function 은 outer `this` 를
        /// 캡처하므로 계속 탐색한다.
        pub fn hasLexicalThisReference(self: *Transformer, body_idx: NodeIndex) bool {
            if (body_idx.isNone()) return false;
            // 트랜스포머가 만든 노드도 본다(#4722). 예전엔 파서 노드만 봤는데, 바깥 루프 추출이
            // 본문을 재작성하면 안쪽 루프가 새 노드가 되어 캡처를 못 보는 false negative 가
            // 났다(가드 도입 당시 TODO 로 남아 있던 문제). 레이아웃은 comptime 표로 검증된다.
            const max_node: usize = self.ast.nodes.items.len;

            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            stack.append(self.allocator, body_idx) catch return true;

            while (stack.items.len > 0) {
                const idx = stack.pop() orelse break;
                if (idx.isNone()) continue;
                if (@intFromEnum(idx) >= max_node) continue;
                const node = self.ast.getNode(idx);

                switch (node.tag) {
                    .this_expression,
                    .super_expression,
                    => return true,

                    .function_expression,
                    .function_declaration,
                    .function,
                    .method_definition,
                    .class_expression,
                    .class_declaration,
                    => continue,

                    else => {},
                }

                var children: std.ArrayList(NodeIndex) = .empty;
                defer children.deinit(self.allocator);
                collectChildIndices(self, node, &children) catch return true;
                for (children.items) |child_idx| {
                    stack.append(self.allocator, child_idx) catch return true;
                }
            }
            return false;
        }

        /// 노드의 자식 NodeIndex들을 scratch 버퍼에 수집한다.
        /// 공통 `ast_walk.ChildIterator` 로 자식 순회 + 범위 밖 인덱스를 걸러낸다
        /// (extra 자식에만 한정). 트랜스포머가 만든 노드도 포함한다 — #4722.
        fn collectChildIndices(self: *Transformer, node: Node, buf: *std.ArrayList(NodeIndex)) !void {
            const kind = node.tag.dataKind();
            var it = ast_walk.children(self.ast, node);
            while (it.next()) |child| {
                if (kind == .extra) {
                    const raw = @intFromEnum(child);
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
            is_generator: bool,
            /// 호출자가 본문을 visit 하기 **직전**의 `temp_var_counter`. 그 뒤에 생긴 임시
            /// 변수는 본문 안에서만 쓰이므로 `_loop` 안에 선언한다 — 바깥 함수에 두면 모든
            /// 반복이 한 변수를 공유해, 반복마다 만든 클로저가 마지막 값을 보게 된다 (#4729:
            /// 루프 안 객체 리터럴의 home 임시 변수). 본문을 visit 하지 않고 넘기면 null.
            body_temp_start: ?u32,
            /// 본문의 원래 `var` 이름(`collectLoopBodyVarNames`). 함수로 뽑으면 지역 변수가 되어
            /// 루프 밖에서 사라지므로, 본문 선언은 대입으로 바꾸고 `var …, _loop = …` 로 바깥에
            /// 둔다 (#4743).
            hoist_vars: []const []const u8,
        ) Transformer.Error!struct { loop_fn: NodeIndex, call_and_check: NodeIndex } {
            // --- _loop 함수명 생성 ---
            const loop_prefix = "_loop";
            const loop_name = try self.buildUniqueName(loop_prefix, &self.loop_counter);
            defer if (loop_name.ptr != loop_prefix.ptr) self.allocator.free(loop_name);

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

            transformed_body = try hoistVarsOutOfBody(self, transformed_body, hoist_vars);

            if (body_temp_start) |start| {
                if (self.temp_var_counter > start and !transformed_body.isNone()) {
                    transformed_body = try self.hoistTempVars(transformed_body, start, span);
                    self.temp_var_counter = start;
                }
            }

            // --- function params: 캡처된 변수 ---
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);
            for (lexical_names) |name| {
                const param_span = try self.ast.addString(name);
                const param = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = param_span,
                    .data = .{ .string_ref = param_span },
                });
                const formal = try self.ast.addNode(.{
                    .tag = .formal_parameter,
                    .span = param_span,
                    // extras = [pattern, type_ann, default, flags, deco_start, deco_len].
                    // ⚠️ deco_len 은 **0** 이어야 한다. 여기 `none`(0xFFFFFFFF)을 넣으면
                    // 이 노드를 visit 하는 순간 `visitExtraList` 가 40억 개를 순회하려다
                    // 죽는다 — 기존에는 이 파라미터가 다시 방문되지 않아 잠복해 있었다.
                    .data = .{ .extra = try self.ast.addExtras(&.{
                        @intFromEnum(param), @intFromEnum(NodeIndex.none), @intFromEnum(NodeIndex.none),
                        0,                   0,                            0,
                    }) },
                });
                try self.scratch.append(self.allocator, formal);
            }
            const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);

            const none = @intFromEnum(NodeIndex.none);
            const params_node = try self.ast.addFormalParameters(params, span);
            const func_flags: u32 = (if (is_async) ast_mod.FunctionFlags.is_async else 0) |
                (if (is_generator) ast_mod.FunctionFlags.is_generator else 0);
            const func_extra = try self.ast.addExtras(&.{
                none,                           @intFromEnum(params_node),
                @intFromEnum(transformed_body), func_flags,
                none,
            });
            const func_expr = try self.ast.addNode(.{
                .tag = .function_expression,
                .span = span,
                .data = .{ .extra = func_extra },
            });

            // --- var _loop = function(...) { ... } ---
            const loop_name_span = try self.ast.addString(loop_name);
            const loop_binding = try es_helpers.makeBindingIdentifier(self, loop_name_span);
            const loop_decl = try es_helpers.makeDeclarator(self, loop_binding, func_expr, span);
            var decls: std.ArrayList(NodeIndex) = .empty;
            defer decls.deinit(self.allocator);
            for (hoist_vars) |name| {
                const b = try es_helpers.makeBindingIdentifier(self, try self.ast.addString(name));
                try decls.append(self.allocator, try es_helpers.makeDeclarator(self, b, .none, span));
            }
            try decls.append(self.allocator, loop_decl);
            const loop_var = try es_helpers.makeVarDeclaration(self, decls.items, .@"var", span);

            // --- _loop(i, j, ...) 호출 ---
            const scratch_top2 = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top2);
            const loop_ref = try es_helpers.makeIdentifierRef(self, loop_name);
            const call_callee = if (preserve_this) blk: {
                const call_prop = try es_helpers.makeIdentifierRef(self, "call");
                try self.scratch.append(self.allocator, try es_helpers.makeThisExpr(self, span));
                break :blk try es_helpers.makeStaticMember(self, loop_ref, call_prop, span);
            } else loop_ref;
            for (lexical_names) |name| {
                try self.scratch.append(self.allocator, try es_helpers.makeIdentifierRef(self, name));
            }
            const loop_call = try es_helpers.makeCallExpr(self, call_callee, self.scratch.items[scratch_top2..], span);

            // is_async — `_loop(...)` 가 Promise 반환. 호출부도 `await _loop(...)` 로
            // wrap 해야 iteration 순서 보존 + needsRetVar 시 _ret 가 resolved value.
            const call_expr: NodeIndex = if (is_generator)
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
            if (needs_ret_var) {
                final_stmt = try buildControlFlowCheck(self, call_expr, flow, local_label, span);
            } else {
                final_stmt = try self.ast.addNode(.{
                    .tag = .expression_statement,
                    .span = span,
                    .data = .{ .unary = .{ .operand = call_expr, .flags = 0 } },
                });
            }

            // 호출문을 블록으로 감싸기
            const call_block_list = try self.ast.addNodeList(&.{final_stmt});
            const call_block = try self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = call_block_list },
            });

            return .{ .loop_fn = loop_var, .call_and_check = call_block };
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
                if (@intFromEnum(entry.idx) >= self.ast.nodes.items.len) continue;
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
                    .function_expression,
                    .function_declaration,
                    .arrow_function_expression,
                    .function,
                    => continue, // 클로저 경계: 내부 무시

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
            for (labels) |l| if (std.mem.eql(u8, l, name)) return true;
            return false;
        }

        /// body 안(클로저 경계 제외)에서 정의된 라벨 이름을 모은다.
        fn collectDefinedLabels(self: *Transformer, body_idx: NodeIndex, out: *std.ArrayList([]const u8)) void {
            var stack: std.ArrayList(NodeIndex) = .empty;
            defer stack.deinit(self.allocator);
            stack.append(self.allocator, body_idx) catch return;
            while (stack.pop()) |idx| {
                if (idx.isNone() or @intFromEnum(idx) >= self.ast.nodes.items.len) continue;
                const node = self.ast.getNode(idx);
                switch (node.tag) {
                    .function_expression, .function_declaration, .arrow_function_expression, .function => continue,
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
                if (std.mem.eql(u8, l, label_text)) return;
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
                        @intFromEnum(new_body),
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
                        const case_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[cases_start + ci]);
                        const case_node = self.ast.getNode(case_idx);
                        // switch_case: extra = [test(0), stmts_start(1), stmts_len(2)]
                        const ce = case_node.data.extra;
                        const test_node: NodeIndex = @enumFromInt(self.ast.extra_data.items[ce]);
                        const case_stmts_start = self.ast.extra_data.items[ce + 1];
                        const case_stmts_len = self.ast.extra_data.items[ce + 2];
                        // case body 의 각 문을 재귀 변환. inner_scratch 는 transform
                        // 으로 생긴 임시 stmt 인덱스들만 추적 — addNodeList 로 복사된
                        // 뒤에는 즉시 shrink 해야 뒤따르는 switch_case append 가
                        // scratch_top 바로 위에 놓인다 (shrink 가 append 이후에 일어나면
                        // 방금 추가한 switch_case 까지 잘려나간다).
                        const inner_scratch = self.scratch.items.len;
                        for (0..case_stmts_len) |si| {
                            const stmt_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[case_stmts_start + si]);
                            try self.scratch.append(self.allocator, try transformStmtFlow(self, stmt_idx, flow, loop_depth, switch_depth));
                        }
                        const new_stmts = try self.ast.addNodeList(self.scratch.items[inner_scratch..]);
                        self.scratch.shrinkRetainingCapacity(inner_scratch);
                        try self.scratch.append(self.allocator, try self.addExtraNode(.switch_case, case_node.span, &.{
                            @intFromEnum(test_node), new_stmts.start, new_stmts.len,
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
            const key = try es_helpers.makeIdentifierRef(self, "v");
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
                if (std.mem.eql(u8, entry, label)) return true;
            }
            return false;
        }

        fn buildControlFlowCheck(
            self: *Transformer,
            loop_call: NodeIndex,
            flow: *const FlowResult,
            local_label: ?[]const u8,
            span: Span,
        ) Transformer.Error!NodeIndex {
            const scratch_top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(scratch_top);

            // var _ret = _loop(i)
            const ret_decl = try self.buildVarDecl("_ret", loop_call, span);
            try self.scratch.append(self.allocator, ret_decl);

            // if (typeof _ret === "object") return _ret.v;
            if (flow.has_return) {
                const ret_ref = try es_helpers.makeIdentifierRef(self, "_ret");
                // variant-typed helper — `unary_expression` 은 `.extra = [operand, op]`
                // layout. (이전엔 `.unary` variant 로 잘못 써서 `if (<= === "object")`
                // syntax error — #1797.)
                const typeof_extra = try self.ast.addExtras(&.{
                    @intFromEnum(ret_ref),
                    @intFromEnum(token_mod.Kind.kw_typeof),
                });
                const typeof_expr = try self.ast.addExtraNode(.unary_expression, span, typeof_extra);
                const obj_str = try es_helpers.buildStringNode(self, "\"object\"", span);
                const typeof_check = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = typeof_expr, .right = obj_str, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                });
                // _ret.v
                const ret_ref2 = try es_helpers.makeIdentifierRef(self, "_ret");
                const v_prop = try es_helpers.makeIdentifierRef(self, "v");
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
                const ret_ref = try es_helpers.makeIdentifierRef(self, "_ret");
                const break_str = try es_helpers.buildStringNode(self, "\"break\"", span);
                const break_check = try self.ast.addNode(.{
                    .tag = .binary_expression,
                    .span = span,
                    .data = .{ .binary = .{ .left = ret_ref, .right = break_str, .flags = @intFromEnum(token_mod.Kind.eq3) } },
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
                    const ret_ref = try es_helpers.makeIdentifierRef(self, "_ret");
                    const sentinel_str = try es_helpers.buildStringNode(self, sentinel, span);
                    const check = try self.ast.addNode(.{
                        .tag = .binary_expression,
                        .span = span,
                        .data = .{ .binary = .{ .left = ret_ref, .right = sentinel_str, .flags = @intFromEnum(token_mod.Kind.eq3) } },
                    });
                    // 라벨이 **경계 없이 보이면** `break/continue <label>` 로 바로 점프하고, 클로저
                    // 경계 너머면 `return "<kw>|<label>"` 로 한 단계 위 클로저에 전달한다 (#4722).
                    // 예전엔 자기 루프 라벨(local_label)만 점프로 봤다 — 바깥 루프가 **추출되지 않은
                    // 같은 함수의 루프**여도 return 으로 전달해 함수 전체를 빠져나갔다(동기 코드에서도).
                    // 반대로 무조건 점프하면 중첩 추출에서 `break B` 가 정의 안 된 라벨이 된다.
                    const jump = (local_label != null and std.mem.eql(u8, local_label.?, label)) or
                        labelVisibleWithoutBoundary(self, label);
                    const ctrl_stmt = if (jump) blk: {
                        const label_span = try self.ast.addString(label);
                        const label_node = try self.ast.addNode(.{
                            .tag = .identifier_reference,
                            .span = label_span,
                            .data = .{ .string_ref = label_span },
                        });
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
            return self.ast.addNode(.{
                .tag = .block_statement,
                .span = span,
                .data = .{ .list = block_list },
            });
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
