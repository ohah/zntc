//! Control-flow visitor helpers for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es2015_block_scoping = @import("../es2015_block_scoping.zig");
const es2015_class = @import("../es2015_class.zig");
const es2015_destructuring = @import("../es2015_destructuring.zig");
const es_helpers = @import("../es_helpers.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

fn makeEmptyStatement(self: *Transformer, span: Span) Error!NodeIndex {
    return self.ast.addNode(.{
        .tag = .empty_statement,
        .span = span,
        .data = .{ .none = 0 },
    });
}

fn ensureStatementBody(self: *Transformer, original_idx: NodeIndex, visited_idx: NodeIndex, parent_span: Span) Error!NodeIndex {
    if (!visited_idx.isNone()) return visited_idx;
    const span = if (!original_idx.isNone()) self.ast.getNode(original_idx).span else parent_span;
    return makeEmptyStatement(self, span);
}

fn collectActiveLoopHeaderNames(self: *Transformer, names: []const []const u8, out: *std.ArrayList([]const u8)) Error!void {
    for (names) |name| {
        try out.append(self.allocator, self.lookupBlockRename(name) orelse name);
    }
}

/// if-statement 의 then/else body 는 문법상 반드시 Statement 여야 한다.
/// `--drop=console` 같은 pass 가 body expression_statement 를 `.none` 으로 지워도
/// list context 처럼 제거하면 `if(cond)else ...` 가 되므로 empty_statement 로 보존한다.
pub fn visitIfStatement(self: *Transformer, node: Node) Error!NodeIndex {
    const t = node.data.ternary;
    const new_test = try self.visitNode(t.a);
    const raw_then = try self.visitNode(t.b);
    const new_then = try ensureStatementBody(self, t.b, raw_then, node.span);
    const raw_else = try self.visitNode(t.c);
    const new_else = if (t.c.isNone())
        raw_else
    else
        try ensureStatementBody(self, t.c, raw_else, node.span);
    return self.ast.addNode(.{
        .tag = .if_statement,
        .span = node.span,
        .data = .{ .ternary = .{ .a = new_test, .b = new_then, .c = new_else } },
    });
}

/// while/do/with/labeled 처럼 `binary.right` 가 Statement body 인 노드 전용 visitor.
/// body 가 drop 되어도 빈 statement 를 남겨 syntactic boundary 를 유지한다.
pub fn visitBinaryStatementBody(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(idx);
    const old_left = node.data.binary.left;
    const old_right = node.data.binary.right;
    const new_left = try self.visitNode(old_left);
    const raw_right = try self.visitNode(old_right);
    const new_right = try ensureStatementBody(self, old_right, raw_right, node.span);
    if (new_left == old_left and new_right == old_right) return idx;
    return self.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .binary = .{
            .left = new_left,
            .right = new_right,
            .flags = node.data.binary.flags,
        } },
    });
}

/// for-in/for-of/for-await-of 헤더 전용 ternary visit.
/// `a`(left) 방문 시 in_for_in_of_header 플래그를 켜서, block_scoping 다운레벨로
/// let/const → var 변환 시 불필요한 `= void 0` init 주입을 막는다 (#1386).
pub fn visitForInOfTernary(self: *Transformer, node: Node) Error!NodeIndex {
    if (self.options.unsupported.block_scoping) {
        const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
        var lexical_names = try BlockScoping.collectLexicalVarNames(self, node.data.ternary.a);
        defer lexical_names.deinit(self.allocator);

        if (lexical_names.items.len > 0) {
            const orig_body_idx = node.data.ternary.c;
            // 원본 AST 에서 capture 검사 — visitNode 가 closure 경계를 변환하기 전 시점.
            const has_capture = BlockScoping.hasCapturedClosure(self, orig_body_idx, lexical_names.items);
            // body 에 await 가 있으면 _loop 도 async 여야 (호출부도 await wrap).
            // for-await-of 자체는 enclosing async function 보장이지만 body 에 await
            // 가 없으면 sync _loop 으로 충분.
            const is_async = if (has_capture) BlockScoping.hasAwaitExpression(self, orig_body_idx) else false;
            const preserve_this = if (has_capture) BlockScoping.hasLexicalThisReference(self, orig_body_idx) else false;

            var flow = BlockScoping.FlowResult{};
            defer flow.labels.deinit(self.allocator);
            if (has_capture) {
                BlockScoping.analyzeControlFlow(self, orig_body_idx, &flow, 0, 0);
            }

            const new_b = try self.visitNode(node.data.ternary.b);
            const renames_added = try self.pushLoopHeaderBlockRenames(lexical_names.items);
            defer self.popBlockRenames(renames_added);

            const saved = self.in_for_in_of_header;
            self.in_for_in_of_header = true;
            const new_a = try self.visitNode(node.data.ternary.a);
            self.in_for_in_of_header = saved;
            const raw_c = try self.visitNode(orig_body_idx);
            const new_c = try ensureStatementBody(self, orig_body_idx, raw_c, node.span);

            if (has_capture) {
                var active_lexical_names: std.ArrayList([]const u8) = .empty;
                defer active_lexical_names.deinit(self.allocator);
                try collectActiveLoopHeaderNames(self, lexical_names.items, &active_lexical_names);

                const result = try BlockScoping.buildLoopClosureWithFlow(
                    self,
                    new_c,
                    active_lexical_names.items,
                    &flow,
                    null,
                    node.span,
                    is_async,
                    preserve_this,
                );
                const loop_node = try self.ast.addNode(.{
                    .tag = node.tag,
                    .span = node.span,
                    .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = result.call_and_check } },
                });
                const stmts = try self.ast.addNodeList(&.{ result.loop_fn, loop_node });
                return self.ast.addNode(.{
                    .tag = .block_statement,
                    .span = node.span,
                    .data = .{ .list = stmts },
                });
            }

            return self.ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
            });
        }
    }

    const saved = self.in_for_in_of_header;
    self.in_for_in_of_header = true;
    const new_a = try self.visitNode(node.data.ternary.a);
    self.in_for_in_of_header = saved;
    const new_b = try self.visitNode(node.data.ternary.b);
    const raw_c = try self.visitNode(node.data.ternary.c);
    const new_c = try ensureStatementBody(self, node.data.ternary.c, raw_c, node.span);
    return self.ast.addNode(.{
        .tag = node.tag,
        .span = node.span,
        .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
    });
}

/// for-of/for-in의 left에 private_field 가 포함되면 임시 binding + body prefix
/// assignment 로 재구성 (#1491). 그렇지 않으면 null.
/// - `for (this.#x of arr) BODY` → `for (var _t of arr) { this.#x = _t; BODY }`
/// - `for ({x: this.#x} of arr) BODY` → `for (var _t of arr) { ({x: this.#x} = _t); BODY }`
/// body prefix의 assignment 는 이후 일반 assignment_expression lowering 경로를 거쳐
/// __classPrivateFieldSet / destructuring helper 로 변환됨.
/// #4254(+후속): for-in/for-of 의 LHS destructuring(binding/assignment-target)을 lowering 해야 하면
/// lowerForInOfDestructuring(body-destructure) 으로 라우팅. 두 경우:
///   - es5(unsupported.destructuring): 모든 destructuring binding (기존 for-in).
///   - es2015~17(unsupported.object_spread): object rest binding 만 (for_of 가
///     native 라 LHS 슬롯 expand 불가 → body-destructure).
/// LHS 가 binding(variable_declaration) 아니거나 lowering 불요면 null.
pub fn maybeLowerForInOfDestructuring(self: *Transformer, node: Node) Error!?NodeIndex {
    const left = node.data.ternary.a;
    if (left.isNone()) return null;
    const left_node = self.ast.getNode(left);
    const D = es2015_destructuring.ES2015Destructuring(Transformer);
    if (left_node.tag == .variable_declaration) {
        if (self.options.unsupported.destructuring and D.hasDestructuring(self, left_node)) {
            return try D.lowerForInOfDestructuring(self, node);
        }
        if (self.options.unsupported.object_spread and D.hasObjectRest(self, left_node)) {
            return try D.lowerForInOfDestructuring(self, node);
        }
        return null;
    }
    // #4254 후속(+#4261): assignment-target object rest LHS (`for ({a,...r} of arr)`,
    // `for ([b, {a,...r}] of arr)`). es2015~17(for_of native, object_spread 미지원)
    // 에서 native 잔존 → es2017 엔진 SyntaxError. object/array_assignment_target
    // 트리에 object rest 가 중첩 포함되면 lowering(plain `for({a} of)`/array rest
    // `for([a,...x] of)` 과트리거 회피).
    if ((left_node.tag == .object_assignment_target or left_node.tag == .array_assignment_target) and
        self.options.unsupported.object_spread and
        D.destructuringTargetHasObjectRest(self, left))
    {
        return try D.lowerForInOfDestructuring(self, node);
    }
    return null;
}

pub fn tryLowerForInOfPrivateTarget(self: *Transformer, node: Node) Error!?NodeIndex {
    const left_idx = node.data.ternary.a;
    if (left_idx.isNone()) return null;
    const left_node = self.ast.getNode(left_idx);
    const has_private = switch (left_node.tag) {
        .private_field_expression => true,
        .object_assignment_target, .array_assignment_target => es2015_class.ES2015Class(Transformer).destructuringTargetHasPrivateField(self, left_idx),
        else => false,
    };
    if (!has_private) return null;

    const span = node.span;
    const temp_span = try es_helpers.makeTempVarSpan(self);
    // var _t;
    const binding = try es_helpers.makeBindingIdentifier(self, temp_span);
    const declarator = try es_helpers.makeDeclarator(self, binding, NodeIndex.none, span);
    const var_decl = try es_helpers.makeVarDeclaration(self, &.{declarator}, .@"var", span);

    // (LHS = _t) assignment_expression — 이후 방문 시 lowerPrivateFieldSet / destructuring 경로 거침.
    const tmp_ref = try es_helpers.makeTempVarRef(self, temp_span, temp_span);
    const prefix_assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = span,
        .data = .{ .binary = .{
            .left = left_idx,
            .right = tmp_ref,
            .flags = @intFromEnum(token_mod.Kind.eq),
        } },
    });
    const prefix_stmt = try self.ast.addNode(.{
        .tag = .expression_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = prefix_assign, .flags = 0 } },
    });

    // 원본 body 의 자식을 prefix_stmt 와 묶어 block_statement 생성 (body 내부는 일반 visit).
    const body_idx = node.data.ternary.c;
    const new_body = try buildForBodyWithPrefix(self, body_idx, prefix_stmt, span);

    // for (var _t ... ) new_body 로 재조립한 뒤, 표준 visit로 하위 변환 적용.
    const rewritten = try self.ast.addNode(.{
        .tag = node.tag,
        .span = span,
        .data = .{ .ternary = .{ .a = var_decl, .b = node.data.ternary.b, .c = new_body } },
    });
    return try self.visitNode(rewritten);
}

/// for-loop body 앞에 prefix statement를 삽입해 새 block_statement 생성.
/// body 가 이미 block_statement면 기존 자식 앞에 prefix를 끼우고, 아니면 [prefix, body] 두 개로 감쌈.
fn buildForBodyWithPrefix(self: *Transformer, body_idx: NodeIndex, prefix_stmt: NodeIndex, span: Span) Error!NodeIndex {
    if (body_idx.isNone()) {
        const list = try self.ast.addNodeList(&.{prefix_stmt});
        return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = list } });
    }
    const body_node = self.ast.getNode(body_idx);
    if (body_node.tag != .block_statement) {
        const list = try self.ast.addNodeList(&.{ prefix_stmt, body_idx });
        return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = list } });
    }
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    try self.scratch.append(self.allocator, prefix_stmt);
    const start = body_node.data.list.start;
    const len = body_node.data.list.len;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const child_raw = self.ast.extra_data.items[start + i];
        try self.scratch.append(self.allocator, @enumFromInt(child_raw));
    }
    const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{ .tag = .block_statement, .span = span, .data = .{ .list = list } });
}

pub fn visitForStatement(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const init_idx = self.readNodeIdx(e, 0);

    // ES2015 block scoping: let/const 변수 캡처 감지
    if (self.options.unsupported.block_scoping) {
        const BlockScoping = es2015_block_scoping.ES2015BlockScoping(Transformer);
        var lexical_names = try BlockScoping.collectLexicalVarNames(self, init_idx);
        defer lexical_names.deinit(self.allocator);

        if (lexical_names.items.len > 0) {
            // 원본 body에서 캡처/제어흐름 분석 (new AST에서는 extra 레이아웃이 변경됨)
            const orig_body_idx = self.readNodeIdx(e, 3);
            const has_capture = BlockScoping.hasCapturedClosure(self, orig_body_idx, lexical_names.items);
            const is_async = if (has_capture) BlockScoping.hasAwaitExpression(self, orig_body_idx) else false;
            const preserve_this = if (has_capture) BlockScoping.hasLexicalThisReference(self, orig_body_idx) else false;

            // 제어 흐름 분석도 원본에서 수행
            var flow = BlockScoping.FlowResult{};
            defer flow.labels.deinit(self.allocator);
            if (has_capture) {
                BlockScoping.analyzeControlFlow(self, orig_body_idx, &flow, 0, 0);
            }

            const renames_added = try self.pushLoopHeaderBlockRenames(lexical_names.items);
            defer self.popBlockRenames(renames_added);

            const new_init = try self.visitNode(init_idx);
            const new_test = try self.visitNode(self.readNodeIdx(e, 1));
            const new_update = try self.visitNode(self.readNodeIdx(e, 2));
            const raw_body = try self.visitNode(orig_body_idx);
            const new_body = try ensureStatementBody(self, orig_body_idx, raw_body, node.span);

            if (has_capture) {
                var active_lexical_names: std.ArrayList([]const u8) = .empty;
                defer active_lexical_names.deinit(self.allocator);
                try collectActiveLoopHeaderNames(self, lexical_names.items, &active_lexical_names);

                const result = try BlockScoping.buildLoopClosureWithFlow(
                    self,
                    new_body,
                    active_lexical_names.items,
                    &flow,
                    null,
                    node.span,
                    is_async,
                    preserve_this,
                );

                // var _loop = function(...) { ... };
                // for (var i = 0; ...) { _loop(i); }
                const for_node = try self.addExtraNode(.for_statement, node.span, &.{
                    @intFromEnum(new_init),   @intFromEnum(new_test),
                    @intFromEnum(new_update), @intFromEnum(result.call_and_check),
                });

                // 두 문을 블록으로 반환 (호이스팅 불필요 — for 문 바로 앞에 삽입)
                const stmts = try self.ast.addNodeList(&.{ result.loop_fn, for_node });
                return self.ast.addNode(.{
                    .tag = .block_statement,
                    .span = node.span,
                    .data = .{ .list = stmts },
                });
            }

            return self.addExtraNode(.for_statement, node.span, &.{
                @intFromEnum(new_init), @intFromEnum(new_test), @intFromEnum(new_update), @intFromEnum(new_body),
            });
        }
    }

    const new_init = try self.visitNode(init_idx);
    const new_test = try self.visitNode(self.readNodeIdx(e, 1));
    const new_update = try self.visitNode(self.readNodeIdx(e, 2));
    const old_body = self.readNodeIdx(e, 3);
    const raw_body = try self.visitNode(old_body);
    const new_body = try ensureStatementBody(self, old_body, raw_body, node.span);
    return self.addExtraNode(.for_statement, node.span, &.{
        @intFromEnum(new_init), @intFromEnum(new_test), @intFromEnum(new_update), @intFromEnum(new_body),
    });
}

/// switch_statement: extra = [discriminant, cases.start, cases.len]
pub fn visitSwitchStatement(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const new_disc = try self.visitNode(self.readNodeIdx(e, 0));
    const new_cases = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
    return self.addExtraNode(.switch_statement, node.span, &.{
        @intFromEnum(new_disc), new_cases.start, new_cases.len,
    });
}

/// switch_case: extra_data = [test, stmts_start, stmts_len]
pub fn visitSwitchCase(self: *Transformer, node: Node) Error!NodeIndex {
    const e = node.data.extra;
    const new_test = try self.visitNode(self.readNodeIdx(e, 0));
    const new_stmts = try self.visitExtraList(.{ .start = self.readU32(e, 1), .len = self.readU32(e, 2) });
    return self.addExtraNode(.switch_case, node.span, &.{ @intFromEnum(new_test), new_stmts.start, new_stmts.len });
}
