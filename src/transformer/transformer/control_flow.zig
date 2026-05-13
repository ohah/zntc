//! Control-flow visitor helpers for Transformer.

const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const es2015_block_scoping = @import("../es2015_block_scoping.zig");
const es2015_class = @import("../es2015_class.zig");
const es_helpers = @import("../es_helpers.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

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

            const saved = self.in_for_in_of_header;
            self.in_for_in_of_header = true;
            const new_a = try self.visitNode(node.data.ternary.a);
            self.in_for_in_of_header = saved;
            const new_b = try self.visitNode(node.data.ternary.b);
            const new_c = try self.visitNode(orig_body_idx);

            if (has_capture) {
                const result = try BlockScoping.buildLoopClosureWithFlow(
                    self,
                    new_c,
                    lexical_names.items,
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
    const new_c = try self.visitNode(node.data.ternary.c);
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

            const new_init = try self.visitNode(init_idx);
            const new_test = try self.visitNode(self.readNodeIdx(e, 1));
            const new_update = try self.visitNode(self.readNodeIdx(e, 2));
            const new_body = try self.visitNode(orig_body_idx);

            if (has_capture) {
                const result = try BlockScoping.buildLoopClosureWithFlow(
                    self,
                    new_body,
                    lexical_names.items,
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
    const new_body = try self.visitNode(self.readNodeIdx(e, 3));
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
