//! ES2025 다운레벨링: using / await using (Explicit Resource Management)
//!
//! --target < es2025 일 때 활성화.
//!
//! 변환 대상:
//! - `using x = expr;` → try-finally + __using/__callDispose
//! - `await using x = expr;` → async try-finally
//!
//! 변환 패턴 (esbuild 호환):
//!
//! 입력:
//! ```javascript
//! {
//!   stmt_before;
//!   using res = getResource();
//!   doSomething(res);
//! }
//! ```
//!
//! 출력:
//! ```javascript
//! {
//!   var _stack = [], _error = void 0, _hasError = false;
//!   try {
//!     stmt_before;
//!     const res = __using(_stack, getResource());
//!     doSomething(res);
//!   } catch (_) {
//!     _error = _;
//!     _hasError = true;
//!   } finally {
//!     __callDispose(_stack, _error, _hasError);
//!   }
//! }
//! ```
//!
//! await using:
//! - __using(_stack, expr, true) — 3번째 인수 true
//! - finally 블록에서 await __callDispose(...)
//!
//! 스펙:
//! - https://tc39.es/proposal-explicit-resource-management/
//!
//! 참고:
//! - esbuild: pkg/api/api_impl.go (using lowering)
//! - oxc: crates/oxc_transformer/src/es2025/

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const es_helpers = @import("es_helpers.zig");
const VariableDeclarationKind = ast_mod.VariableDeclarationKind;
const module_parser = @import("../parser/module.zig");

pub fn ES2025Using(comptime Transformer: type) type {
    return struct {
        const Self = @This();

        /// 문장 리스트에서 using/await using 선언이 있는지 스캔한다.
        /// 하나라도 있으면 true 반환 → lowerUsingInStatements 호출 필요.
        pub fn hasUsingDeclaration(self: *Transformer, start: u32, len: u32) bool {
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const raw_idx = self.ast.extra_data.items[start + i];
                const node = self.ast.getNode(@enumFromInt(raw_idx));
                if (node.tag == .variable_declaration) {
                    const e = node.data.extra;
                    if (self.ast.hasExtra(e, 3)) {
                        if (self.ast.variableDeclarationKind(node).isUsing()) return true;
                    }
                }
            }
            return false;
        }

        /// 낮추는 문장 목록의 종류. 모듈 최상위는 `import`/`export` 가 try 안에 들어갈 수
        /// 없어 따로 다룬다.
        pub const ListKind = enum { program, body };

        const Names = struct { stack: Span, err: Span, has_err: Span, catch_param: Span };

        /// 낮추기마다 고유한 `_stack`/`_error`/`_hasError` 이름. 고정 이름이면 중첩 블록이
        /// 서로의 스택을 덮어쓰고, 사용자 변수 `_stack` 과도 충돌한다 (#4730).
        fn allocNames(self: *Transformer) Transformer.Error!Names {
            const bases = [_][]const u8{ "_stack", "_error", "_hasError" };
            while (true) {
                self.using_counter += 1;
                const n = self.using_counter;
                var bufs: [3][32]u8 = undefined;
                var names: [3][]const u8 = undefined;
                var collide = false;
                for (bases, 0..) |b, k| {
                    names[k] = if (n == 1) b else std.fmt.bufPrint(&bufs[k], "{s}{d}", .{ b, n }) catch unreachable;
                    if (es_helpers.nameAppearsInSource(self, names[k])) collide = true;
                }
                if (collide) continue;
                return .{
                    .stack = try self.ast.addString(names[0]),
                    .err = try self.ast.addString(names[1]),
                    .has_err = try self.ast.addString(names[2]),
                    .catch_param = try self.ast.addString("_"),
                };
            }
        }

        fn push(self: *Transformer, list: *std.ArrayList(NodeIndex), stmt: NodeIndex) Transformer.Error!void {
            try list.append(self.allocator, stmt);
        }

        /// using 낮추기: 재구성한 목록을 방문한다.
        pub fn lowerUsingInStatements(self: *Transformer, start: u32, len: u32, kind: ListKind) Transformer.Error!NodeList {
            const rewritten = try rewriteUsingStatements(self, start, len, kind);
            return self.visitExtraList(rewritten);
        }

        /// `"use strict"` 같은 지시문은 목록 맨 앞에 남아야 한다 — try 안으로 들어가면
        /// 평범한 문자열 식이 되어 strict 모드가 풀린다.
        fn isDirective(node: Node) bool {
            return node.tag == .directive;
        }

        /// 문장 리스트를 try/catch/finally 로 감싼다 (esbuild 호환 형태).
        ///
        /// ```js
        /// var _stack = [], _error = void 0, _hasError = false;
        /// try { <문장들, using 은 __using(_stack, …)> }
        /// catch (_) { _error = _; _hasError = true; }
        /// finally { [await] __callDispose(_stack, _error, _hasError); }
        /// ```
        ///
        /// - **목록 전체**(지시문 제외)를 감싼다. 첫 `using` 부터만 감싸면 그 뒤의 함수 선언이
        ///   try 블록 안으로 들어가 앞쪽 문장에서 호출할 수 없게 된다 (#4730).
        /// - `_error`/`_hasError` 는 진입마다 초기화한다. 앞 블록(또는 이전 반복)의 에러가
        ///   남아 있으면 에러 없이 끝난 블록의 finally 가 옛 에러를 다시 던진다.
        /// - 함수 선언은 try 밖 앞쪽으로 끌어올린다 — 모듈 최상위는 `export function` 때문에,
        ///   es5 는 블록 안 함수 선언이 표준이 아니어서. (es5 는 let/const 가 var 가 되므로
        ///   끌어올린 함수도 try 안 선언을 본다.)
        /// - 모듈 최상위: import·re-export 는 try 밖에 두고, try 안의 let/const/class 는 var 로
        ///   바꿔 모듈 스코프에 남긴다. `export` 는 떼어 끝에 `export { … }` 로 모은다.
        ///
        /// 이 함수는 **방문하지 않고** 구조만 바꾼다 — 일반 목록은 결과를 그대로 방문하고,
        /// generator 상태 기계는 결과의 try 를 기존 try 수집으로 접는다.
        pub fn rewriteUsingStatements(self: *Transformer, start: u32, len: u32, kind: ListKind) Transformer.Error!NodeList {
            var has_await_using = false;
            {
                var i: u32 = 0;
                while (i < len) : (i += 1) {
                    const node = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[start + i]));
                    if (node.tag == .variable_declaration and self.ast.hasExtra(node.data.extra, 3) and
                        self.ast.variableDeclarationKind(node) == .await_using) has_await_using = true;
                }
            }

            var head: std.ArrayList(NodeIndex) = .empty; // 지시문 + try 밖으로 끌어올린 문장
            defer head.deinit(self.allocator);
            var body: std.ArrayList(NodeIndex) = .empty; // try 블록
            defer body.deinit(self.allocator);
            var tail: std.ArrayList(NodeIndex) = .empty; // try 뒤 (`export { … }`)
            defer tail.deinit(self.allocator);
            var export_specs: std.ArrayList(NodeIndex) = .empty;
            defer export_specs.deinit(self.allocator);

            self.runtime_helpers.using_ctx = true;
            const names = try allocNames(self);
            const zero_span = Span{ .start = 0, .end = 0 };
            const hoist_functions = kind == .program or self.options.unsupported.block_scoping;
            // 블록·함수 본문의 `using` 은 native let/const 가 되는 타겟이면 const 로 남긴다.
            const using_kind: VariableDeclarationKind = if (kind == .program or self.options.unsupported.block_scoping) .@"var" else .@"const";

            var i: u32 = 0;
            var in_prologue = true;
            while (i < len) : (i += 1) {
                const stmt: NodeIndex = @enumFromInt(self.ast.extra_data.items[start + i]);
                const node = self.ast.getNode(stmt);
                if (in_prologue and isDirective(node)) {
                    try push(self, &head, stmt);
                    continue;
                }
                in_prologue = false;

                if (node.tag == .variable_declaration and self.ast.hasExtra(node.data.extra, 3)) {
                    const vkind = self.ast.variableDeclarationKind(node);
                    if (vkind.isUsing()) {
                        try transformUsingDeclarators(self, &body, self.readU32(node.data.extra, 1), self.readU32(node.data.extra, 2), vkind == .await_using, names.stack, using_kind, node.span);
                        continue;
                    }
                    if (kind == .program and (vkind == .let or vkind == .@"const")) {
                        try push(self, &body, try asVarDeclaration(self, node));
                        continue;
                    }
                }

                switch (node.tag) {
                    .function_declaration => if (hoist_functions) {
                        try push(self, &head, stmt);
                        continue;
                    },
                    else => {},
                }

                if (kind == .program) {
                    switch (node.tag) {
                        .import_declaration, .export_all_declaration => {
                            try push(self, &head, stmt);
                            continue;
                        },
                        .class_declaration => {
                            try push(self, &body, try classAsVar(self, node));
                            continue;
                        },
                        .export_named_declaration => {
                            const x = module_parser.readExportNamedExtras(self.ast, node.data.extra);
                            if (!x.source.isNone()) {
                                try push(self, &head, stmt);
                            } else if (x.decl.isNone()) {
                                try push(self, &tail, stmt);
                            } else {
                                const decl = self.ast.getNode(x.decl);
                                switch (decl.tag) {
                                    .variable_declaration => {
                                        try collectDeclNames(self, decl, &export_specs);
                                        try push(self, &body, try asVarDeclaration(self, decl));
                                    },
                                    .class_declaration => {
                                        const cname = self.readNodeIdx(decl.data.extra, ast_mod.ClassExtra.name);
                                        try export_specs.append(self.allocator, try makeExportSpec(self, self.ast.getText(self.ast.getNode(cname).span), cname, null));
                                        try push(self, &body, try classAsVar(self, decl));
                                    },
                                    // `export function` 과 TS 전용 선언(enum/namespace 등)은 try 밖.
                                    else => try push(self, &head, stmt),
                                }
                            }
                            continue;
                        },
                        .export_default_declaration => {
                            const operand = node.data.unary.operand;
                            const on = self.ast.getNode(operand);
                            if (on.tag == .function_declaration) {
                                try push(self, &head, stmt);
                                continue;
                            }
                            const named_class = on.tag == .class_declaration and !self.readNodeIdx(on.data.extra, ast_mod.ClassExtra.name).isNone();
                            if (named_class) {
                                const cname = self.readNodeIdx(on.data.extra, ast_mod.ClassExtra.name);
                                try export_specs.append(self.allocator, try makeExportSpec(self, self.ast.getText(self.ast.getNode(cname).span), cname, "default"));
                                try push(self, &body, try classAsVar(self, on));
                            } else {
                                const default_name = try uniqueSourceName(self, "_default");
                                const value = if (on.tag == .class_declaration) try classExpressionOf(self, on) else operand;
                                const binding = try es_helpers.makeBindingIdentifier(self, try self.ast.addString(default_name));
                                const decl = try es_helpers.makeVarDeclaration(self, &.{try es_helpers.makeDeclarator(self, binding, value, node.span)}, .@"var", node.span);
                                try export_specs.append(self.allocator, try makeExportSpec(self, default_name, .none, "default"));
                                try push(self, &body, decl);
                            }
                            continue;
                        },
                        else => {},
                    }
                }

                try push(self, &body, stmt);
            }

            // var _stack = [], _error = void 0, _hasError = false;
            const empty_array = try self.ast.addNode(.{ .tag = .array_expression, .span = zero_span, .data = .{ .list = .{ .start = 0, .len = 0 } } });
            const init_decl = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, try es_helpers.makeBindingIdentifier(self, names.stack), empty_array, zero_span),
                try es_helpers.makeDeclarator(self, try es_helpers.makeBindingIdentifier(self, names.err), try es_helpers.makeVoidZero(self, zero_span), zero_span),
                try es_helpers.makeDeclarator(self, try es_helpers.makeBindingIdentifier(self, names.has_err), try es_helpers.makeBoolLiteral(self, false), zero_span),
            }, .@"var", zero_span);

            const try_block = try self.ast.addNode(.{ .tag = .block_statement, .span = zero_span, .data = .{ .list = try self.ast.addNodeList(body.items) } });
            const catch_clause = try buildCatchClause(self, names, zero_span);
            const finally_block = try buildFinallyBlock(self, names, has_await_using, zero_span);
            const try_stmt = try self.ast.addNode(.{
                .tag = .try_statement,
                .span = zero_span,
                .data = .{ .ternary = .{ .a = try_block, .b = catch_clause, .c = finally_block } },
            });

            try head.append(self.allocator, init_decl);
            try head.append(self.allocator, try_stmt);
            try head.appendSlice(self.allocator, tail.items);
            if (export_specs.items.len > 0) {
                const specs = try self.ast.addNodeList(export_specs.items);
                const none = @intFromEnum(NodeIndex.none);
                try head.append(self.allocator, try self.addExtraNode(.export_named_declaration, zero_span, &.{ none, specs.start, specs.len, none, 0, 0 }));
            }
            return self.ast.addNodeList(head.items);
        }

        /// `for ([await] using x of it) body` → `for (const _using of it) { [await] using x = _using; body }`.
        /// 루프 헤더의 using 은 어떤 경로에서도 낮춰지지 않았다 — es2015+ 에선 `using` 문법이
        /// 그대로 남고, es5 에선 dispose 없이 var 가 됐다 (#4730). 본문 블록으로 옮기면 블록
        /// 낮추기가 그대로 적용된다. 노드를 **제자리에서** 바꾸므로 모든 진입점(일반 방문,
        /// 라벨 붙은 루프, 상태 기계)이 같은 모양을 보고, 두 번째 호출은 아무 일도 안 한다.
        pub fn normalizeForOfUsingHead(self: *Transformer, idx: NodeIndex) Transformer.Error!bool {
            if (!self.options.unsupported.using) return false;
            const node = self.ast.getNode(idx);
            if (node.tag != .for_of_statement and node.tag != .for_await_of_statement) return false;
            const left = node.data.ternary.a;
            if (left.isNone()) return false;
            const ln = self.ast.getNode(left);
            if (ln.tag != .variable_declaration or !self.ast.hasExtra(ln.data.extra, 3)) return false;
            const vkind = self.ast.variableDeclarationKind(ln);
            if (!vkind.isUsing()) return false;
            if (self.readU32(ln.data.extra, 2) != 1) return false;
            const d = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[self.readU32(ln.data.extra, 1)]));
            const binding = self.readNodeIdx(d.data.extra, 0);

            const tmp_name = try uniqueSourceName(self, "_using");
            defer self.allocator.free(tmp_name);
            const tmp_span = try self.ast.addString(tmp_name);
            const new_left = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, try es_helpers.makeBindingIdentifier(self, tmp_span), .none, ln.span),
            }, .@"const", ln.span);
            const using_decl = try es_helpers.makeVarDeclaration(self, &.{
                try es_helpers.makeDeclarator(self, binding, try es_helpers.makeIdentifierRefFromSpan(self, tmp_span), d.span),
            }, vkind, ln.span);
            const new_body = try self.ast.addNode(.{ .tag = .block_statement, .span = node.span, .data = .{
                .list = try self.ast.addNodeList(&.{ using_decl, node.data.ternary.c }),
            } });
            self.ast.nodes.items[@intFromEnum(idx)].data.ternary.a = new_left;
            self.ast.nodes.items[@intFromEnum(idx)].data.ternary.c = new_body;
            return true;
        }

        /// `let`/`const` 선언을 같은 declarator 들의 `var` 선언으로 (모듈 최상위 전용).
        fn asVarDeclaration(self: *Transformer, decl: Node) Transformer.Error!NodeIndex {
            return self.addExtraNode(.variable_declaration, decl.span, &.{
                @intFromEnum(VariableDeclarationKind.@"var"),
                self.readU32(decl.data.extra, 1),
                self.readU32(decl.data.extra, 2),
            });
        }

        fn classExpressionOf(self: *Transformer, decl: Node) Transformer.Error!NodeIndex {
            return self.ast.addNode(.{ .tag = .class_expression, .span = decl.span, .data = decl.data });
        }

        /// `class C {}` → `var C = class C {}` — 모듈 스코프에 남아 끌어올린 함수·export 가 본다.
        fn classAsVar(self: *Transformer, decl: Node) Transformer.Error!NodeIndex {
            const cname = self.readNodeIdx(decl.data.extra, ast_mod.ClassExtra.name);
            const name_span = try self.ast.addString(self.ast.getText(self.ast.getNode(cname).span));
            const binding = try es_helpers.makeBindingIdentifier(self, name_span);
            self.propagateSymbolId(cname, binding);
            return es_helpers.makeVarDeclaration(self, &.{try es_helpers.makeDeclarator(self, binding, try classExpressionOf(self, decl), decl.span)}, .@"var", decl.span);
        }

        fn collectDeclNames(self: *Transformer, decl: Node, specs: *std.ArrayList(NodeIndex)) Transformer.Error!void {
            const BlockScoping = @import("es2015_block_scoping.zig").ES2015BlockScoping(Transformer);
            const ds = self.readU32(decl.data.extra, 1);
            const dl = self.readU32(decl.data.extra, 2);
            var j: u32 = 0;
            while (j < dl) : (j += 1) {
                const d = self.ast.getNode(@enumFromInt(self.ast.extra_data.items[ds + j]));
                if (d.tag != .variable_declarator) continue;
                var bindings: std.ArrayList(NodeIndex) = .empty;
                defer bindings.deinit(self.allocator);
                try BlockScoping.collectBindingNodes(self, self.readNodeIdx(d.data.extra, 0), &bindings);
                for (bindings.items) |b| try specs.append(self.allocator, try makeExportSpec(self, self.ast.getText(self.ast.getNode(b).span), b, null));
            }
        }

        /// `local as exported` 지정자. exported 가 null 이면 local 과 같은 이름. `local_origin` 은
        /// local 의 원래 바인딩(합성 `_default` 면 `.none`) — 심볼을 물려준다 (#4760).
        fn makeExportSpec(self: *Transformer, local: []const u8, local_origin: NodeIndex, exported: ?[]const u8) Transformer.Error!NodeIndex {
            const local_ref = if (local_origin.isNone()) try es_helpers.makeSyntheticRef(self, local) else try self.makeUserRefNamed(local, local_origin);
            const exported_ref = if (exported) |e| try es_helpers.makePropertyName(self, e) else local_ref;
            return self.ast.addNode(.{ .tag = .export_specifier, .span = Span{ .start = 0, .end = 0 }, .data = .{ .binary = .{ .left = local_ref, .right = exported_ref, .flags = 0 } } });
        }

        fn uniqueSourceName(self: *Transformer, base: []const u8) Transformer.Error![]const u8 {
            var n: u32 = 1;
            while (true) : (n += 1) {
                const name = if (n == 1) try self.allocator.dupe(u8, base) else try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ base, n });
                if (!es_helpers.nameAppearsInSource(self, name)) return name;
                self.allocator.free(name);
            }
        }

        /// using 선언의 각 declarator 를 `<kind> x = __using(_stack, expr [, true])` 로.
        fn transformUsingDeclarators(
            self: *Transformer,
            out: *std.ArrayList(NodeIndex),
            decl_start: u32,
            decl_len: u32,
            is_await: bool,
            stack_span: Span,
            decl_kind: VariableDeclarationKind,
            span: Span,
        ) Transformer.Error!void {
            var j: u32 = 0;
            while (j < decl_len) : (j += 1) {
                const raw = self.ast.extra_data.items[decl_start + j];
                const decl = self.ast.getNode(@enumFromInt(raw));
                if (decl.tag != .variable_declarator) continue;

                const de = decl.data.extra;
                const name_idx = self.readNodeIdx(de, 0);
                const init_idx = self.readNodeIdx(de, 2);

                // 방문은 호출자(목록 방문 또는 상태 기계)가 한다.
                const new_name = name_idx;
                const new_init = if (!init_idx.isNone())
                    init_idx
                else
                    // using은 항상 초기화가 필요하지만 방어적으로 void 0 사용
                    try es_helpers.makeVoidZero(self, span);

                const stack_ref = try es_helpers.makeIdentifierRefFromSpan(self, stack_span);
                const using_ref = try es_helpers.makeRuntimeHelperRef(self, "__using");
                const using_call = if (is_await)
                    try es_helpers.makeCallExpr(self, using_ref, &.{ stack_ref, new_init, try es_helpers.makeBoolLiteral(self, true) }, span)
                else
                    try es_helpers.makeCallExpr(self, using_ref, &.{ stack_ref, new_init }, span);

                const none = @intFromEnum(NodeIndex.none);
                const new_decl = try self.addExtraNode(.variable_declarator, decl.span, &.{
                    @intFromEnum(new_name), none, @intFromEnum(using_call),
                });
                try out.append(self.allocator, try es_helpers.makeVarDeclaration(self, &.{new_decl}, decl_kind, span));
            }
        }

        /// catch (_) { _error = _; _hasError = true; }
        fn buildCatchClause(self: *Transformer, names: Names, span: Span) Transformer.Error!NodeIndex {
            const catch_param = try es_helpers.makeBindingIdentifier(self, names.catch_param);
            const set_err = try es_helpers.makeExprStmt(self, try self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{
                .left = try es_helpers.makeIdentifierRefFromSpan(self, names.err),
                .right = try es_helpers.makeIdentifierRefFromSpan(self, names.catch_param),
                .flags = 0,
            } } }), span);
            const set_has = try es_helpers.makeExprStmt(self, try self.ast.addNode(.{ .tag = .assignment_expression, .span = span, .data = .{ .binary = .{
                .left = try es_helpers.makeIdentifierRefFromSpan(self, names.has_err),
                .right = try es_helpers.makeBoolLiteral(self, true),
                .flags = 0,
            } } }), span);
            const body = try self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{ set_err, set_has }) } });
            return self.ast.addNode(.{
                .tag = .catch_clause,
                .span = span,
                .data = .{ .binary = .{ .left = catch_param, .right = body, .flags = 0 } },
            });
        }

        /// finally { [await] __callDispose(_stack, _error, _hasError); }
        fn buildFinallyBlock(self: *Transformer, names: Names, has_await: bool, span: Span) Transformer.Error!NodeIndex {
            const call = try es_helpers.makeCallExpr(self, try es_helpers.makeRuntimeHelperRef(self, "__callDispose"), &.{
                try es_helpers.makeIdentifierRefFromSpan(self, names.stack),
                try es_helpers.makeIdentifierRefFromSpan(self, names.err),
                try es_helpers.makeIdentifierRefFromSpan(self, names.has_err),
            }, span);
            const expr = if (has_await) try es_helpers.makeAwaitExpression(self, call, span) else call;
            const expr_stmt = try es_helpers.makeExprStmt(self, expr, span);
            return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = try self.ast.addNodeList(&.{expr_stmt}) } });
        }
    };
}

// readU32 헬퍼: Transformer에 이미 정의된 것을 사용 (mixin 패턴)
