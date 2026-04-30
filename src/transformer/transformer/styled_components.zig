//! styled-components 1st-party transform — `compiler.styledComponents`.
//!
//! ## 변환 의도
//!
//! Reference: `references/styled-components-babel/src/visitors/displayNameAndId.js` (MIT) /
//! `references/swc-plugins/packages/styled-components/transform/src/visitors/display_name_and_id.rs`
//! (Apache 2.0). 두 구현 모두 다음과 같이 변환:
//!
//! ```js
//! // 입력
//! import styled from "styled-components";
//! const Button = styled.div`color: red;`;
//!
//! // 출력 (이번 PR — babel/swc 표준 형태)
//! import styled from "styled-components";
//! const Button = styled.div.withConfig({ displayName: "Button" })`color: red;`;
//! ```
//!
//! ## 진화
//!
//! - PR 2228 (이전): post-decl `Button.displayName = "Button";` — DevTools 만 충족
//! - **본 PR**: in-place `.withConfig({ displayName })` 래핑 — babel/swc 호환 출력
//! - 후속 PR: componentId hash + SSR 안정화 + chained `.attrs(...)` / `.withConfig(...)`
//!
//! ## hook point
//!
//! - `visitImportDeclaration`: source 가 styled-components 면 default specifier 의 로컬
//!   이름을 `state.default_binding` 에 저장.
//! - `visitVariableDeclarator`: init 변환 후 결과가 `<binding>.X\`...\`` /
//!   `<binding>(arg)\`...\`` 이면 tag 를 `.withConfig({...})` 로 wrap 한 새 노드로 교체.
//!
//! ## 미지원 케이스 (후속 PR)
//!
//! - 클래스 정적 필드: `class { static Child = styled.div\`\` }` (이름 = "Child")
//! - 사용자 명시 `.withConfig({...})` 인식 시 merge / skip
//! - 논리 (`cond && styled.div\`\``)
//! - IIFE (`(() => styled.div\`\`)()`)
//! - chained `var X = Y = styled.div\`\`` 의 outermost name 우선
//! - TS cast: `(styled.div\`\` as any)` / `... satisfies T`

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const module_parser = @import("../../parser/module.zig");
const import_scanner = @import("../../bundler/import_scanner.zig");
const stmt_info = @import("../../bundler/stmt_info.zig");
const wyhash = @import("../../util/wyhash.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

/// v6+ 는 "/native" subpath 도 인정. 추가될 가능성 있음 (vendored fork 등).
pub const STYLED_SOURCES: []const []const u8 = &.{
    "styled-components",
    "styled-components/native",
};

pub fn isStyledImportSource(source: []const u8) bool {
    for (STYLED_SOURCES) |s| {
        if (std.mem.eql(u8, s, source)) return true;
    }
    return false;
}

/// `visitImportDeclaration` hook — source 가 styled-components 면 default specifier 의 로컬
/// 이름을 binding 으로 등록. 옵션 비활성 시 즉시 return (hot path).
pub fn detectStyledImport(self: *Transformer, node: Node) Error!void {
    if (!self.options.styled_components) return;
    // 첫 styled-components import 만 사용 (babel-plugin 동작과 일치).
    if (self.plugins.styled_components.default_binding != null) return;

    const x = module_parser.readImportDeclExtras(self.ast, node.data.extra);
    if (x.source.isNone()) return;
    const source_node = self.ast.getNode(x.source);
    if (source_node.tag != .string_literal) return;
    const source_text = import_scanner.stripQuotes(self.ast.getText(source_node.span)) orelse return;
    if (!isStyledImportSource(source_text)) return;

    var i: u32 = 0;
    while (i < x.specs_len) : (i += 1) {
        const spec_idx_raw = self.ast.extra_data.items[x.specs_start + i];
        const spec_idx: NodeIndex = @enumFromInt(spec_idx_raw);
        if (spec_idx.isNone()) continue;
        const spec_node = self.ast.getNode(spec_idx);
        if (spec_node.tag != .import_default_specifier) continue;
        const local_name = self.ast.getText(spec_node.data.string_ref);
        if (local_name.len == 0) continue;
        self.plugins.styled_components.default_binding = local_name;
        return;
    }
    // default specifier 없음 — `import { css } from "styled-components"` 같은 named-only.
    // 이 PR 은 default binding 만 처리. named (`{ styled }`) 는 후속.
}

/// chain 분석 결과 — `wrapStyledTag` 가 wrap / merge 결정에 사용.
const ChainAnalysis = struct {
    /// chain root identifier 가 styled binding 과 일치
    matches_binding: bool,
    /// 사용자 명시 `.withConfig(<obj>)` call_expression 의 idx — 가장 outer (= 런타임
    /// later-wins 결과). 없으면 .none. chain 중간에 있어도 capture.
    user_with_config_call: NodeIndex = .none,
};

/// tag chain 분석. root binding 매칭 + 사용자 .withConfig 위치까지 한 번 walk 로 수집.
fn analyzeTagChain(self: *Transformer, tag_idx: NodeIndex) ChainAnalysis {
    const result_no_match: ChainAnalysis = .{ .matches_binding = false };
    const binding = self.plugins.styled_components.default_binding orelse return result_no_match;
    var user_with_config: NodeIndex = .none;
    var current = tag_idx;
    while (true) {
        if (current.isNone()) return result_no_match;
        const node = self.ast.getNode(current);
        switch (node.tag) {
            .identifier_reference => {
                const matches = std.mem.eql(u8, self.ast.getText(node.data.string_ref), binding);
                return .{ .matches_binding = matches, .user_with_config_call = user_with_config };
            },
            .static_member_expression => {
                if (!self.ast.hasExtra(node.data.extra, 1)) return result_no_match;
                current = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
            },
            .call_expression => {
                if (!self.ast.hasExtra(node.data.extra, 0)) return result_no_match;
                // Check if this call is `<X>.withConfig(...)` — capture outermost (= first encountered).
                const callee_raw = self.ast.extra_data.items[node.data.extra];
                const callee_idx: NodeIndex = @enumFromInt(callee_raw);
                if (user_with_config.isNone() and !callee_idx.isNone()) {
                    const callee_node = self.ast.getNode(callee_idx);
                    if (callee_node.tag == .static_member_expression and self.ast.hasExtra(callee_node.data.extra, 1)) {
                        const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[callee_node.data.extra + 1]);
                        if (!prop_idx.isNone()) {
                            const prop_node = self.ast.getNode(prop_idx);
                            if (prop_node.tag == .identifier_reference and
                                std.mem.eql(u8, self.ast.getText(prop_node.data.string_ref), "withConfig"))
                            {
                                user_with_config = current;
                            }
                        }
                    }
                }
                current = callee_idx;
            },
            else => return result_no_match,
        }
    }
}

/// object_property 의 key 노드에서 displayName 으로 사용할 이름을 추출.
/// `stmt_info.plainObjectKeyName` 재사용 — escape 포함 문자열 (`{ "A\"B": ... }`) 은
/// 보수적으로 reject 하여 raw vs decoded 시맨틱 차이로 인한 잘못된 매칭 방지.
pub fn objectPropertyKeyName(self: *Transformer, key_idx: NodeIndex) ?[]const u8 {
    const name = stmt_info.plainObjectKeyName(self.ast, key_idx) orelse return null;
    if (name.len == 0) return null;
    return name;
}

/// `Component = styled.div\`...\`` 형태 처리. visitBinaryNode 의 결과 (assignment_expression)
/// 를 받아 right 가 styled tagged template 이면 LHS identifier 이름으로 wrap.
/// LHS 가 member / computed / destructuring 이면 skip — 정적 이름 추출 불가.
pub fn maybeWrapAssignment(self: *Transformer, assignment_idx: NodeIndex) Error!NodeIndex {
    if (assignment_idx.isNone()) return assignment_idx;
    const node = self.ast.getNode(assignment_idx);
    if (node.tag != .assignment_expression) return assignment_idx;
    const left = node.data.binary.left;
    const right = node.data.binary.right;
    if (left.isNone() or right.isNone()) return assignment_idx;
    if (!isWrappableExpr(self.ast.getNode(right).tag)) return assignment_idx;
    const left_node = self.ast.getNode(left);
    // 일반 assignment: LHS 가 assignment_target_identifier (parser 가 destructuring 컨텍스트
    // 외에서도 단순 식별자 LHS 를 이 태그로 변환).
    // identifier_reference 경로는 일부 변환 후 노드 (block-scope rename 등) 대응.
    if (left_node.tag != .assignment_target_identifier and left_node.tag != .identifier_reference) return assignment_idx;
    const var_name = self.ast.getText(left_node.data.string_ref);
    if (var_name.len == 0) return assignment_idx;

    const new_right = try wrapStyledTagInExpr(self, right, var_name);
    if (new_right == right) return assignment_idx;
    return self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = node.span,
        .data = .{ .binary = .{ .left = left, .right = new_right, .flags = node.data.binary.flags } },
    });
}

/// `parenthesized_expression` + 모든 type assertion 류 — 공통적으로 unary { operand, flags }
/// 데이터 변형. wrapStyledTagInExpr 와 isWrappableExpr 가 이 set 을 공유.
///
/// 주의: codegen / semantic / worklet 등 다른 pass 도 비슷한 set 을 가짐. 향후 cross-cutting
/// refactor 로 es_helpers 의 `TRANSPARENT_WRAPPER_TAGS` 같은 단일 source 화 권장 (별도 PR).
fn isUnaryWrapperTag(tag: ast_mod.Node.Tag) bool {
    return switch (tag) {
        .parenthesized_expression,
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_type_assertion,
        .ts_non_null_expression,
        .ts_instantiation_expression,
        .flow_as_expression,
        .flow_type_cast_expression,
        => true,
        else => false,
    };
}

/// 표현식이 styled tagged template 을 (직접 / wrapper 안에) 포함하면 wrap.
/// caller 가 init.tag 를 사전 검사 (`isWrappableExpr`) 한 뒤 호출.
///
/// 인식 expression wrapper:
///   - `styled.div\`...\`` (직접)
///   - `cond ? styled.div\`\` : styled.div\`\`` (양쪽 branch — babel 동작)
///   - `(styled.div\`\`)` (괄호)
///   - `cond && styled.div\`\`` / `default || styled.div\`\`` / `?? styled.div\`\`` (논리 — 우변만)
///   - `styled.div\`\` as T` / `... satisfies T` / `...!` / legacy `<T>...` / Foo<T> 인스턴스화 (TS)
///   - `styled.div\`\` as Foo` (Flow)
///   - `(() => styled.div\`\`)()` IIFE — expression body + block body `{ return X }` 둘 다
///   - 위 조합
///
/// 미인식 (의도된 한계):
///   - `styled.div\`\` || fallback` 처럼 좌변이 styled 인 논리 — wrap 시 단락평가 시맨틱이
///     변할 수 있어 보수적 skip
pub fn wrapStyledTagInExpr(self: *Transformer, expr_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    if (expr_idx.isNone()) return expr_idx;
    const node = self.ast.getNode(expr_idx);
    if (node.tag == .tagged_template_expression) return wrapStyledTag(self, expr_idx, var_name);

    if (node.tag == .conditional_expression) {
        // ternary: a=test, b=consequent, c=alternate. test 는 전파 안 함 (boolean expr).
        const old_b = node.data.ternary.b;
        const old_c = node.data.ternary.c;
        const new_b = try wrapStyledTagInExpr(self, old_b, var_name);
        const new_c = try wrapStyledTagInExpr(self, old_c, var_name);
        if (new_b == old_b and new_c == old_c) return expr_idx;
        return self.ast.addNode(.{
            .tag = .conditional_expression,
            .span = node.span,
            .data = .{ .ternary = .{ .a = node.data.ternary.a, .b = new_b, .c = new_c } },
        });
    }

    if (node.tag == .logical_expression) {
        // && 의 right 가 결과값. || / ?? 도 fallback 위치가 right. left 는 condition/default
        // 라 보통 styled 가 아닐뿐더러, 좌변이 styled 인 `styled.div\`\` || fallback` 케이스는
        // wrap 시 단락평가 시맨틱이 영향 받을 수 있어 보수적 skip.
        const old_right = node.data.binary.right;
        const new_right = try wrapStyledTagInExpr(self, old_right, var_name);
        if (new_right == old_right) return expr_idx;
        return self.ast.addNode(.{
            .tag = .logical_expression,
            .span = node.span,
            .data = .{ .binary = .{
                .left = node.data.binary.left,
                .right = new_right,
                .flags = node.data.binary.flags,
            } },
        });
    }

    if (isUnaryWrapperTag(node.tag)) {
        const old_inner = node.data.unary.operand;
        const new_inner = try wrapStyledTagInExpr(self, old_inner, var_name);
        if (new_inner == old_inner) return expr_idx;
        return self.ast.addNode(.{
            .tag = node.tag,
            .span = node.span,
            .data = .{ .unary = .{ .operand = new_inner, .flags = node.data.unary.flags } },
        });
    }

    if (node.tag == .call_expression) {
        return wrapStyledInIife(self, expr_idx, var_name);
    }

    return expr_idx;
}

/// IIFE `(() => <body>)()` / `(() => <body>)(...args)` — body 에 styled tagged template 이
/// 있으면 body 를 wrap 한 새 call_expression 빌드.
/// expression body + block body (`{ ...; return X }`) 둘 다 인식.
/// callee 가 arrow function 이 아니면 (일반 함수 호출) early-return — hot path 보호.
fn wrapStyledInIife(self: *Transformer, call_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    const call_node = self.ast.getNode(call_idx);
    // call extra = [callee, args_start, args_len, flags]
    if (!self.ast.hasExtra(call_node.data.extra, 2)) return call_idx;
    const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[call_node.data.extra]);
    if (callee_idx.isNone()) return call_idx;

    // 다중 paren `((() => X))()` 도 처리 — while 로 unwrap.
    var arrow_idx = callee_idx;
    var arrow_node = self.ast.getNode(arrow_idx);
    while (arrow_node.tag == .parenthesized_expression) {
        arrow_idx = arrow_node.data.unary.operand;
        if (arrow_idx.isNone()) return call_idx;
        arrow_node = self.ast.getNode(arrow_idx);
    }
    if (arrow_node.tag != .arrow_function_expression) return call_idx;

    // arrow extra = [params(0), body(1), flags(2)]
    if (!self.ast.hasExtra(arrow_node.data.extra, 1)) return call_idx;
    const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[arrow_node.data.extra + 1]);
    if (body_idx.isNone()) return call_idx;

    // expression body 또는 block body 분기.
    const body_node = self.ast.getNode(body_idx);
    const new_body = if (body_node.tag == .block_statement)
        try wrapStyledInBlockReturns(self, body_idx, var_name)
    else
        try wrapStyledTagInExpr(self, body_idx, var_name);
    if (new_body == body_idx) return call_idx;

    // Rebuild arrow with new body (params / flags 그대로).
    const params_idx_raw = self.ast.extra_data.items[arrow_node.data.extra];
    const arrow_flags = if (self.ast.hasExtra(arrow_node.data.extra, 2))
        self.ast.extra_data.items[arrow_node.data.extra + 2]
    else
        0;
    const new_arrow = try self.addExtraNode(.arrow_function_expression, arrow_node.span, &.{
        params_idx_raw,
        @intFromEnum(new_body),
        arrow_flags,
    });

    // Re-wrap parens — 원본의 paren chain 깊이만큼 다시 감쌈 (callee 부터 다시 walk).
    var new_callee = new_arrow;
    var paren_walk_idx = callee_idx;
    var paren_walk_node = self.ast.getNode(paren_walk_idx);
    while (paren_walk_node.tag == .parenthesized_expression) {
        new_callee = try self.ast.addNode(.{
            .tag = .parenthesized_expression,
            .span = paren_walk_node.span,
            .data = .{ .unary = .{ .operand = new_callee, .flags = paren_walk_node.data.unary.flags } },
        });
        paren_walk_idx = paren_walk_node.data.unary.operand;
        if (paren_walk_idx.isNone()) break;
        paren_walk_node = self.ast.getNode(paren_walk_idx);
    }

    // Rebuild call (args / flags 그대로).
    const args_start = self.ast.extra_data.items[call_node.data.extra + 1];
    const args_len = self.ast.extra_data.items[call_node.data.extra + 2];
    const call_flags = if (self.ast.hasExtra(call_node.data.extra, 3))
        self.ast.extra_data.items[call_node.data.extra + 3]
    else
        0;
    return try self.addExtraNode(.call_expression, call_node.span, &.{
        @intFromEnum(new_callee),
        args_start,
        args_len,
        call_flags,
    });
}

/// arrow body 내 return 들을 재귀 walk — return 의 operand 가 styled tagged template 이면 wrap.
/// `es2015_block_scoping.transformStmtFlow` 와 동일한 dispatch 패턴 — control flow 노드의
/// statement child 들을 재귀로 traverse, identity 보존. (Path-A visitor #1672 D2 도입 시
/// 정렬 가능.)
///
/// 인식 case:
///   - `return X;` (직접)
///   - `{ ...; return X; }` (block_statement)
///   - `if (cond) return X;` / `if-else` (if_statement, ternary b/c)
///   - `try { return X } catch (e) { return Y } finally { return Z }` (try_statement)
///   - `switch (x) { case 1: return X; default: return Y; }` (switch_statement)
fn wrapStyledInStmt(self: *Transformer, stmt_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    if (stmt_idx.isNone()) return stmt_idx;
    const node = self.ast.getNode(stmt_idx);
    switch (node.tag) {
        .return_statement => {
            const old_operand = node.data.unary.operand;
            if (old_operand.isNone() or !shouldAttemptWrap(self, old_operand)) return stmt_idx;
            const new_operand = try wrapStyledTagInExpr(self, old_operand, var_name);
            if (new_operand == old_operand) return stmt_idx;
            return self.ast.addNode(.{
                .tag = .return_statement,
                .span = node.span,
                .data = .{ .unary = .{ .operand = new_operand, .flags = node.data.unary.flags } },
            });
        },
        .block_statement => return wrapStyledInBlockReturns(self, stmt_idx, var_name),
        .if_statement => {
            // ternary: a=test, b=consequent, c=alternate
            const old_b = node.data.ternary.b;
            const old_c = node.data.ternary.c;
            const new_b = try wrapStyledInStmt(self, old_b, var_name);
            const new_c = try wrapStyledInStmt(self, old_c, var_name);
            if (new_b == old_b and new_c == old_c) return stmt_idx;
            return self.ast.addNode(.{
                .tag = .if_statement,
                .span = node.span,
                .data = .{ .ternary = .{ .a = node.data.ternary.a, .b = new_b, .c = new_c } },
            });
        },
        .try_statement => {
            // ternary: a=try block, b=catch_clause (or .none), c=finally block (or .none)
            const old_a = node.data.ternary.a;
            const old_b = node.data.ternary.b;
            const old_c = node.data.ternary.c;
            const new_a = try wrapStyledInStmt(self, old_a, var_name);
            const new_b = try wrapStyledInCatchClause(self, old_b, var_name);
            const new_c = try wrapStyledInStmt(self, old_c, var_name);
            if (new_a == old_a and new_b == old_b and new_c == old_c) return stmt_idx;
            return self.ast.addNode(.{
                .tag = .try_statement,
                .span = node.span,
                .data = .{ .ternary = .{ .a = new_a, .b = new_b, .c = new_c } },
            });
        },
        .switch_statement => return wrapStyledInSwitch(self, stmt_idx, var_name),
        // switch_case 는 wrapStyledInSwitch 의 walkStmtList 로 dispatch — 자식 stmts 만 walk.
        .switch_case => return wrapStyledInSwitchCase(self, stmt_idx, var_name),
        .while_statement, .do_while_statement, .labeled_statement => {
            // binary: left=test/label, right=body. (do_while_statement 도 같은 layout —
            // parser 는 test 를 left 에, body 를 right 에 저장.)
            const old_body = node.data.binary.right;
            const new_body = try wrapStyledInStmt(self, old_body, var_name);
            if (new_body == old_body) return stmt_idx;
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .binary = .{
                    .left = node.data.binary.left,
                    .right = new_body,
                    .flags = node.data.binary.flags,
                } },
            });
        },
        .for_statement => {
            // extra = [init, test, update, body]. body 만 walk.
            if (!self.ast.hasExtra(node.data.extra, 3)) return stmt_idx;
            const old_body: NodeIndex = @enumFromInt(self.ast.extra_data.items[node.data.extra + 3]);
            const new_body = try wrapStyledInStmt(self, old_body, var_name);
            if (new_body == old_body) return stmt_idx;
            return try self.addExtraNode(.for_statement, node.span, &.{
                self.ast.extra_data.items[node.data.extra],
                self.ast.extra_data.items[node.data.extra + 1],
                self.ast.extra_data.items[node.data.extra + 2],
                @intFromEnum(new_body),
            });
        },
        .for_in_statement, .for_of_statement, .for_await_of_statement => {
            // ternary: a=left binding, b=right iterable, c=body. body 만 walk.
            const old_c = node.data.ternary.c;
            const new_c = try wrapStyledInStmt(self, old_c, var_name);
            if (new_c == old_c) return stmt_idx;
            return self.ast.addNode(.{
                .tag = node.tag,
                .span = node.span,
                .data = .{ .ternary = .{ .a = node.data.ternary.a, .b = node.data.ternary.b, .c = new_c } },
            });
        },
        else => return stmt_idx,
    }
}

/// catch_clause: binary { left=param (or .none), right=block_statement }. body block 만 walk.
fn wrapStyledInCatchClause(self: *Transformer, idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    if (idx.isNone()) return idx;
    const node = self.ast.getNode(idx);
    if (node.tag != .catch_clause) return idx;
    const old_body = node.data.binary.right;
    const new_body = try wrapStyledInStmt(self, old_body, var_name);
    if (new_body == old_body) return idx;
    return self.ast.addNode(.{
        .tag = .catch_clause,
        .span = node.span,
        .data = .{ .binary = .{
            .left = node.data.binary.left,
            .right = new_body,
            .flags = node.data.binary.flags,
        } },
    });
}

/// stmt list 를 wrapStyledInStmt 로 walk — 변경 없으면 null 반환 (caller identity 보존),
/// 변경 있으면 새 NodeList 반환. block_statement / switch_statement / switch_case 의
/// 공통 list-walking 패턴 통합.
fn walkStmtList(self: *Transformer, list_start: u32, list_len: u32, var_name: []const u8) Error!?ast_mod.NodeList {
    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);

    var changed = false;
    var i: u32 = 0;
    while (i < list_len) : (i += 1) {
        const item_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list_start + i]);
        const new_item = try wrapStyledInStmt(self, item_idx, var_name);
        if (new_item != item_idx) changed = true;
        try self.scratch.append(self.allocator, new_item);
    }

    if (!changed) return null;
    return try self.ast.addNodeList(self.scratch.items[top..]);
}

/// switch_statement: extra = [discriminant, cases_start, cases_len]. 각 case 를 walk.
fn wrapStyledInSwitch(self: *Transformer, switch_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    const node = self.ast.getNode(switch_idx);
    if (!self.ast.hasExtra(node.data.extra, 2)) return switch_idx;
    const cases_start = self.ast.extra_data.items[node.data.extra + 1];
    const cases_len = self.ast.extra_data.items[node.data.extra + 2];

    // switch_case 도 dispatch 통과 — wrapStyledInStmt 가 .switch_case arm 으로 분기.
    const new_list = (try walkStmtList(self, cases_start, cases_len, var_name)) orelse return switch_idx;
    return try self.addExtraNode(.switch_statement, node.span, &.{
        self.ast.extra_data.items[node.data.extra],
        new_list.start,
        new_list.len,
    });
}

/// switch_case: extra = [test (or .none for default), stmts_start, stmts_len]. stmts walk.
fn wrapStyledInSwitchCase(self: *Transformer, case_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    const node = self.ast.getNode(case_idx);
    if (node.tag != .switch_case) return case_idx;
    if (!self.ast.hasExtra(node.data.extra, 2)) return case_idx;
    const stmts_start = self.ast.extra_data.items[node.data.extra + 1];
    const stmts_len = self.ast.extra_data.items[node.data.extra + 2];

    const new_list = (try walkStmtList(self, stmts_start, stmts_len, var_name)) orelse return case_idx;
    return try self.addExtraNode(.switch_case, node.span, &.{
        self.ast.extra_data.items[node.data.extra],
        new_list.start,
        new_list.len,
    });
}

/// block_statement 의 statements 순회 — 각 stmt 를 wrapStyledInStmt 로 재귀 walk.
fn wrapStyledInBlockReturns(self: *Transformer, block_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    const block_node = self.ast.getNode(block_idx);
    const list = block_node.data.list;
    const new_list = (try walkStmtList(self, list.start, list.len, var_name)) orelse return block_idx;
    return self.ast.addNode(.{
        .tag = .block_statement,
        .span = block_node.span,
        .data = .{ .list = new_list },
    });
}

fn isWrappableExpr(tag: ast_mod.Node.Tag) bool {
    return tag == .tagged_template_expression or
        tag == .conditional_expression or
        tag == .logical_expression or
        tag == .call_expression or // IIFE — wrapStyledInIife 가 non-IIFE 는 fast early-return
        isUnaryWrapperTag(tag);
}

/// caller 의 fast-path 사전 필터 — visitVariableDeclarator / visitObjectProperty 가 매
/// declarator 마다 호출. 옵션 OFF / binding 미감지 / wrappable 하지 않은 init 면 var_name
/// 추출 + 함수 호출 비용을 회피.
pub fn shouldAttemptWrap(self: *Transformer, expr_idx: NodeIndex) bool {
    if (!self.options.styled_components) return false;
    if (self.plugins.styled_components.default_binding == null) return false;
    if (expr_idx.isNone()) return false;
    return isWrappableExpr(self.ast.getNode(expr_idx).tag);
}

/// 주어진 `.withConfig(<obj>)` call_expression 노드의 args object 가 object_expression 이면
/// 반환. 아니면 null (computed args / 인자 없음 / array literal 등 — MERGE 불가).
fn withConfigCallArgsObj(self: *Transformer, call_idx: NodeIndex) ?NodeIndex {
    const node = self.ast.getNode(call_idx);
    if (node.tag != .call_expression) return null;
    if (!self.ast.hasExtra(node.data.extra, 2)) return null;
    const args_start = self.ast.extra_data.items[node.data.extra + 1];
    const args_len = self.ast.extra_data.items[node.data.extra + 2];
    if (args_len < 1) return null;
    const arg0_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[args_start]);
    if (arg0_idx.isNone()) return null;
    if (self.ast.getNode(arg0_idx).tag != .object_expression) return null;
    return arg0_idx;
}

/// chain 의 `target_call_idx` 를 `new_call_idx` 로 swap 한 새 chain 을 빌드.
/// `current_idx` 부터 descend 하며 target 을 찾고, 만나면 new_call 로 교체. 위로 돌아오면서
/// member/call 노드를 새 child 로 rebuild. 변경 없으면 current_idx 그대로 반환 (identity).
fn rewriteChainAt(
    self: *Transformer,
    current_idx: NodeIndex,
    target_call_idx: NodeIndex,
    new_call_idx: NodeIndex,
) Error!NodeIndex {
    if (current_idx == target_call_idx) return new_call_idx;
    if (current_idx.isNone()) return current_idx;
    const node = self.ast.getNode(current_idx);
    switch (node.tag) {
        .static_member_expression => {
            if (!self.ast.hasExtra(node.data.extra, 1)) return current_idx;
            const obj_raw = self.ast.extra_data.items[node.data.extra];
            const obj_idx: NodeIndex = @enumFromInt(obj_raw);
            const new_obj = try rewriteChainAt(self, obj_idx, target_call_idx, new_call_idx);
            if (new_obj == obj_idx) return current_idx;
            const prop_raw = self.ast.extra_data.items[node.data.extra + 1];
            const flags = if (self.ast.hasExtra(node.data.extra, 2))
                self.ast.extra_data.items[node.data.extra + 2]
            else
                0;
            return try self.addExtraNode(.static_member_expression, node.span, &.{ @intFromEnum(new_obj), prop_raw, flags });
        },
        .call_expression => {
            if (!self.ast.hasExtra(node.data.extra, 2)) return current_idx;
            const callee_raw = self.ast.extra_data.items[node.data.extra];
            const callee_idx: NodeIndex = @enumFromInt(callee_raw);
            const new_callee = try rewriteChainAt(self, callee_idx, target_call_idx, new_call_idx);
            if (new_callee == callee_idx) return current_idx;
            const args_start = self.ast.extra_data.items[node.data.extra + 1];
            const args_len = self.ast.extra_data.items[node.data.extra + 2];
            const flags = if (self.ast.hasExtra(node.data.extra, 3))
                self.ast.extra_data.items[node.data.extra + 3]
            else
                0;
            return try self.addExtraNode(.call_expression, node.span, &.{ @intFromEnum(new_callee), args_start, args_len, flags });
        },
        else => return current_idx,
    }
}

/// object_expression 의 정적 key 들을 한 번만 스캔하여 displayName / componentId 존재
/// 여부 + spread_element 동반 여부를 동시 반환. spread (`{ ...config }`) 가 있으면 런타임에
/// override 될 수 있어 MERGE 자체를 하면 안 됨 (later-wins 시맨틱) — caller 가 SKIP fallback.
const ObjectKeyScan = struct {
    has_display: bool,
    has_component_id: bool,
    has_spread: bool,
};

fn scanObjectKeys(self: *Transformer, obj_idx: NodeIndex) ObjectKeyScan {
    var result: ObjectKeyScan = .{ .has_display = false, .has_component_id = false, .has_spread = false };
    const obj_node = self.ast.getNode(obj_idx);
    const list = obj_node.data.list;
    const props = self.ast.extra_data.items[list.start .. list.start + list.len];
    for (props) |raw| {
        const prop_idx: NodeIndex = @enumFromInt(raw);
        if (prop_idx.isNone()) continue;
        const prop_node = self.ast.getNode(prop_idx);
        if (prop_node.tag == .spread_element) {
            result.has_spread = true;
            continue;
        }
        if (prop_node.tag != .object_property) continue;
        const name = stmt_info.plainObjectKeyName(self.ast, prop_node.data.binary.left) orelse continue;
        if (std.mem.eql(u8, name, "displayName")) result.has_display = true;
        if (std.mem.eql(u8, name, "componentId")) result.has_component_id = true;
    }
    return result;
}

/// no-interpolation template_literal (`\`color: red;\``) 의 CSS whitespace 를 minify.
/// codegen.zig:2270 의 convention 따라 `data.none == 0` 으로 no-interp 판정.
/// 보간 있는 template (`data.list.len > 0`) 은 후속 PR. 변경 없으면 identity (template_idx).
fn minifyCssTemplate(self: *Transformer, template_idx: NodeIndex) Error!NodeIndex {
    if (template_idx.isNone()) return template_idx;
    const node = self.ast.getNode(template_idx);
    if (node.tag != .template_literal) return template_idx;
    if (node.data.none != 0) return template_idx; // 보간 있음 — codegen.zig:2270 convention.

    const raw = self.ast.getText(node.span);
    if (raw.len < 2 or raw[0] != '`' or raw[raw.len - 1] != '`') return template_idx;
    const inner = raw[1 .. raw.len - 1];

    // Fast-path: 이미 minimal (collapse 할 ws run / leading-trailing ws 없음) 이면 alloc 회피.
    if (!needsCssMinify(inner)) return template_idx;

    // 단일 버퍼 — `\`` + collapsed + `\`` 한 번에 빌드.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.append(self.allocator, '`');
    var prev_ws = true; // leading whitespace skip
    for (inner) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!prev_ws) {
                try buf.append(self.allocator, ' ');
                prev_ws = true;
            }
        } else {
            try buf.append(self.allocator, c);
            prev_ws = false;
        }
    }
    // trailing whitespace strip — closing backtick 직전 ws 제거.
    while (buf.items.len > 1 and buf.items[buf.items.len - 1] == ' ') {
        _ = buf.pop();
    }
    try buf.append(self.allocator, '`');

    const new_span = try self.ast.addString(buf.items);
    return self.ast.addNode(.{
        .tag = .template_literal,
        .span = new_span,
        .data = .{ .list = .{ .start = 0, .len = 0 } },
    });
}

/// CSS minify 가 변경을 만들지 검사 — leading/trailing whitespace, 또는 ws run (>1) 이 있으면 true.
/// alloc 회피 fast-path.
fn needsCssMinify(inner: []const u8) bool {
    if (inner.len == 0) return false;
    if (isCssWhitespace(inner[0]) or isCssWhitespace(inner[inner.len - 1])) return true;
    var prev_ws = false;
    for (inner) |c| {
        const ws = isCssWhitespace(c);
        if (ws and prev_ws) return true; // 다중 ws run
        if (c == '\t' or c == '\n' or c == '\r') return true; // non-space ws 는 항상 collapse 대상
        prev_ws = ws;
    }
    return false;
}

inline fn isCssWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// `wrapStyledTagInExpr` 의 재귀 base case — 직접 tagged_template 일 때만 호출.
fn wrapStyledTag(self: *Transformer, init_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    if (var_name.len == 0) return init_idx;
    const init_node = self.ast.getNode(init_idx);

    // tagged_template extra = [tag, template, flags]
    const e = init_node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return init_idx;
    const tag_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const template_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
    const flags = self.ast.extra_data.items[e + 2];

    const chain = analyzeTagChain(self, tag_idx);
    if (!chain.matches_binding) return init_idx;
    // 사용자 명시 `.withConfig(<obj>)` 가 있으면 MERGE — chain 어디에 있든 (outer 든
    // 중간이든) 그 call 의 args object 에 ZTS 자동 displayName/componentId 를 prepend.
    // 이미 박힌 key 는 보존, spread (`{...config}`) 는 prepend 위치라 user 의 spread 가
    // 우리 값을 자연스럽게 override (= user-intended 시맨틱).
    if (!chain.user_with_config_call.isNone()) {
        return try mergeIntoUserWithConfig(self, init_idx, tag_idx, chain.user_with_config_call, template_idx, flags, var_name);
    }

    const new_tag = try buildWithConfigCall(self, tag_idx, var_name);
    const final_template = if (self.options.styled_components_minify)
        try minifyCssTemplate(self, template_idx)
    else
        template_idx;
    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_tag),
        @intFromEnum(final_template),
        flags,
    });
    return self.ast.addNode(.{
        .tag = .tagged_template_expression,
        .span = init_node.span,
        .data = .{ .extra = new_extra },
    });
}

/// 사용자 `.withConfig(<obj>)` 의 args object 에 ZTS 자동 displayName/componentId 를
/// **prepend** (스프레드보다 앞) — 사용자가 이미 박은 key 는 그대로 보존되고, spread 가
/// 우리 값을 override 할 수 있어 user-intended 시맨틱 보장.
///
/// chain 어디에 있든 (outer 든 중간이든) 동일 처리. `target_call_idx` 가 .withConfig 이고
/// 첫 인자가 object_expression 이라는 보장을 caller 에서 받음 (`analyzeTagChain` + `withConfigCallArgsObj`).
fn mergeIntoUserWithConfig(
    self: *Transformer,
    init_idx: NodeIndex,
    tag_idx: NodeIndex,
    target_call_idx: NodeIndex,
    template_idx: NodeIndex,
    template_flags: u32,
    var_name: []const u8,
) Error!NodeIndex {
    // 1. target call 의 args object 검증
    const args_obj_idx = withConfigCallArgsObj(self, target_call_idx) orelse return init_idx;

    const state = &self.plugins.styled_components;
    if (state.display_name_span == null) state.display_name_span = try self.ast.addString("displayName");

    const scan = scanObjectKeys(self, args_obj_idx);
    const want_component_id = self.options.styled_components_ssr and self.options.jsx_filename.len > 0;
    if (want_component_id and state.component_id_span == null) {
        state.component_id_span = try self.ast.addString("componentId");
        if (state.file_hash_hex == null) state.file_hash_hex = wyhash.hashHex8(self.options.jsx_filename);
    }

    const need_display = !scan.has_display;
    const need_component_id = want_component_id and !scan.has_component_id;
    if (!need_display and !need_component_id) return init_idx;

    // 2. 새 args object 빌드 — ZTS props 를 PREPEND (spread 보다 앞에 위치).
    //    → user 의 spread 또는 explicit static key 가 자동으로 우리 값을 override.
    const old_obj = self.ast.getNode(args_obj_idx);
    const old_list = old_obj.data.list;
    const old_props = self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len];

    const props_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(props_top);

    if (need_display) {
        var display_buf: [256]u8 = undefined;
        const display_quoted = std.fmt.bufPrint(&display_buf, "\"{s}\"", .{var_name}) catch return error.OutOfMemory;
        const display_value_span = try self.ast.addString(display_quoted);
        const display_property = try buildKeyStringProperty(self, state.display_name_span.?, display_value_span);
        try self.scratch.append(self.allocator, display_property);
    }
    if (need_component_id) {
        var component_id_buf: [64]u8 = undefined;
        const component_index = state.component_counter;
        state.component_counter += 1;
        const component_id_quoted = std.fmt.bufPrint(
            &component_id_buf,
            "\"sc-{s}-{d}\"",
            .{ state.file_hash_hex.?, component_index },
        ) catch return error.OutOfMemory;
        const component_id_value_span = try self.ast.addString(component_id_quoted);
        const component_id_property = try buildKeyStringProperty(self, state.component_id_span.?, component_id_value_span);
        try self.scratch.append(self.allocator, component_id_property);
    }
    for (old_props) |raw| try self.scratch.append(self.allocator, @enumFromInt(raw));

    const new_obj_list = try self.ast.addNodeList(self.scratch.items[props_top..]);
    const new_obj = try self.ast.addNode(.{
        .tag = .object_expression,
        .span = old_obj.span,
        .data = .{ .list = new_obj_list },
    });

    // 3. 새 call_expression: target_call 의 callee 그대로, args 의 첫번째만 교체.
    const target_call_node = self.ast.getNode(target_call_idx);
    const callee_idx_raw = self.ast.extra_data.items[target_call_node.data.extra];
    const args_start = self.ast.extra_data.items[target_call_node.data.extra + 1];
    const args_len = self.ast.extra_data.items[target_call_node.data.extra + 2];
    const call_flags = if (self.ast.hasExtra(target_call_node.data.extra, 3))
        self.ast.extra_data.items[target_call_node.data.extra + 3]
    else
        0;

    const args_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(args_top);
    try self.scratch.append(self.allocator, new_obj);
    var i: u32 = 1;
    while (i < args_len) : (i += 1) {
        try self.scratch.append(self.allocator, @enumFromInt(self.ast.extra_data.items[args_start + i]));
    }
    const new_args_list = try self.ast.addNodeList(self.scratch.items[args_top..]);

    const new_call = try self.addExtraNode(.call_expression, target_call_node.span, &.{
        callee_idx_raw,
        new_args_list.start,
        new_args_list.len,
        call_flags,
    });

    // 4. chain 의 target_call 을 new_call 로 swap (recursive rebuild).
    const new_tag = try rewriteChainAt(self, tag_idx, target_call_idx, new_call);

    // 5. 새 tagged_template 빌드 (minify 옵션 시 template 도 minify).
    const final_template = if (self.options.styled_components_minify)
        try minifyCssTemplate(self, template_idx)
    else
        template_idx;
    const new_tt_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_tag),
        @intFromEnum(final_template),
        template_flags,
    });
    return self.ast.addNode(.{
        .tag = .tagged_template_expression,
        .span = self.ast.getNode(init_idx).span,
        .data = .{ .extra = new_tt_extra },
    });
}

/// `<tag>.withConfig({ displayName: "<var_name>"[, componentId: "sc-<hash>-<n>"] })` 빌드.
///
/// componentId 는 SSR hydration 결정론적 식별자 — file path 기반 wyhash 8-hex + 파일 내
/// 등장 순서 counter (SWC `sc-<hash>-<n>` 형식과 동일). `options.jsx_filename` 이 비어있는
/// transpile 경로에선 cross-file ID 충돌 위험이 있어 componentId 자체를 생략 (graceful
/// degradation — displayName 만으로 DevTools 표시는 유지). bundle / app 경로는 항상 filename
/// 이 있으므로 정상 emit.
fn buildWithConfigCall(self: *Transformer, tag_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    const zero = Span{ .start = 0, .end = 0 };
    const state = &self.plugins.styled_components;
    if (state.with_config_span == null) state.with_config_span = try self.ast.addString("withConfig");
    if (state.display_name_span == null) state.display_name_span = try self.ast.addString("displayName");

    const with_config_span = state.with_config_span.?;
    const display_name_key_span = state.display_name_span.?;
    // componentId 는 두 조건 모두 만족 시 emit:
    //  1. ssr 옵션 활성 (default true) — 사용자가 명시적으로 끄지 않음
    //  2. jsx_filename 존재 — file 부분 hash 의 입력
    const emit_component_id = self.options.styled_components_ssr and self.options.jsx_filename.len > 0;
    if (emit_component_id) {
        if (state.component_id_span == null) state.component_id_span = try self.ast.addString("componentId");
        if (state.file_hash_hex == null) state.file_hash_hex = wyhash.hashHex8(self.options.jsx_filename);
    }

    var display_buf: [256]u8 = undefined;
    const display_quoted = std.fmt.bufPrint(&display_buf, "\"{s}\"", .{var_name}) catch return error.OutOfMemory;
    const display_value_span = try self.ast.addString(display_quoted);

    const with_config_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = with_config_span,
        .data = .{ .string_ref = with_config_span },
    });
    // extra = [object, property, flags]
    const member = try self.addExtraNode(.static_member_expression, zero, &.{
        @intFromEnum(tag_idx),
        @intFromEnum(with_config_ref),
        0,
    });

    const display_property = try buildKeyStringProperty(self, display_name_key_span, display_value_span);

    const obj_list = if (emit_component_id) blk: {
        var component_id_buf: [64]u8 = undefined;
        const component_index = state.component_counter;
        state.component_counter += 1;
        const component_id_quoted = std.fmt.bufPrint(
            &component_id_buf,
            "\"sc-{s}-{d}\"",
            .{ state.file_hash_hex.?, component_index },
        ) catch return error.OutOfMemory;
        const component_id_value_span = try self.ast.addString(component_id_quoted);
        const component_id_property = try buildKeyStringProperty(self, state.component_id_span.?, component_id_value_span);
        break :blk try self.ast.addNodeList(&.{ display_property, component_id_property });
    } else try self.ast.addNodeList(&.{display_property});

    const obj = try self.ast.addNode(.{
        .tag = .object_expression,
        .span = zero,
        .data = .{ .list = obj_list },
    });

    // call_expression: extra = [callee, args_start, args_len, flags]
    const args = try self.ast.addNodeList(&.{obj});
    return self.addExtraNode(.call_expression, zero, &.{
        @intFromEnum(member),
        args.start,
        args.len,
        0,
    });
}

/// `key: "value"` object_property 노드 빌드. key 는 identifier_reference, value 는
/// 따옴표 포함 문자열 리터럴 span 으로 미리 준비되어 있어야 함.
fn buildKeyStringProperty(self: *Transformer, key_span: Span, quoted_value_span: Span) Error!NodeIndex {
    const zero = Span{ .start = 0, .end = 0 };
    const key = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = key_span,
        .data = .{ .string_ref = key_span },
    });
    const value = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = quoted_value_span,
        .data = .{ .string_ref = quoted_value_span },
    });
    // object_property: binary = { left=key, right=value, flags }
    return self.ast.addNode(.{
        .tag = .object_property,
        .span = zero,
        .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
    });
}
