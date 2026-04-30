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

/// chain 분석 결과 — `wrapStyledTag` 가 wrap 여부를 결정하는 데 사용.
const ChainAnalysis = struct {
    /// chain root identifier 가 styled binding 과 일치
    matches_binding: bool,
    /// chain 어딘가에 사용자 명시 `.withConfig({...})` 가 있음 — wrap 시 user 의 ID 가 우리
    /// 자동 ID 로 override 되는 footgun 회피용 skip 신호
    has_user_with_config: bool,
};

/// tag 표현식의 chain root 가 styled binding 인지 + 사용자 명시 withConfig 가 있는지 확인.
/// 인식 (모두):
///   - `<binding>.X` (static_member)
///   - `<binding>(arg)` (call)
///   - `<binding>.X.attrs({...})` / `<binding>(X).attrs({...})` (chain: call→member→identifier)
///   - `<binding>.X.attrs({...}).attrs({...})` (다중 체인)
///   - `<binding>.X.withConfig({...})` — matches_binding 이지만 has_user_with_config=true 라서
///     wrap 시 skip 됨 (later-wins 로 user 의 componentId 가 override 되는 것을 방지)
fn analyzeTagChain(self: *Transformer, tag_idx: NodeIndex) ChainAnalysis {
    const result_no_match: ChainAnalysis = .{ .matches_binding = false, .has_user_with_config = false };
    const binding = self.plugins.styled_components.default_binding orelse return result_no_match;
    var has_with_config = false;
    var current = tag_idx;
    while (true) {
        if (current.isNone()) return result_no_match;
        const node = self.ast.getNode(current);
        switch (node.tag) {
            .identifier_reference => {
                const matches = std.mem.eql(u8, self.ast.getText(node.data.string_ref), binding);
                return .{ .matches_binding = matches, .has_user_with_config = has_with_config };
            },
            .static_member_expression => {
                // extra = [object, property, flags] — property 가 "withConfig" 면 표시.
                if (!self.ast.hasExtra(node.data.extra, 1)) return result_no_match;
                const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[node.data.extra + 1]);
                if (!prop_idx.isNone()) {
                    const prop_node = self.ast.getNode(prop_idx);
                    if (prop_node.tag == .identifier_reference) {
                        if (std.mem.eql(u8, self.ast.getText(prop_node.data.string_ref), "withConfig")) {
                            has_with_config = true;
                        }
                    }
                }
                current = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
            },
            .call_expression => {
                // extra = [callee, args_start, args_len, flags] — root 방향으로 callee 만 따라감.
                if (!self.ast.hasExtra(node.data.extra, 0)) return result_no_match;
                current = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
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

/// arrow block body `{ ...; return X }` — return statement 의 operand 만 walk. 변경 없으면
/// 원본 block_idx 반환 (identity 보존).
///
/// **Top-level only**: `if (...) return X` / `try { return X } catch {}` / `switch (...) { case
/// ...: return X }` 같이 중첩 statement 안의 return 은 미인식. ZTS 의 단방향 visitor
/// 모델에서 control-flow 노드를 일반화 walk 하는 건 후속 epic.
fn wrapStyledInBlockReturns(self: *Transformer, block_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    const block_node = self.ast.getNode(block_idx);
    const list = block_node.data.list;
    const stmts = self.ast.extra_data.items[list.start .. list.start + list.len];

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var changed = false;
    for (stmts) |raw| {
        const stmt_idx: NodeIndex = @enumFromInt(raw);
        const stmt_node = self.ast.getNode(stmt_idx);
        if (stmt_node.tag == .return_statement) {
            const old_operand = stmt_node.data.unary.operand;
            if (!old_operand.isNone() and shouldAttemptWrap(self, old_operand)) {
                const new_operand = try wrapStyledTagInExpr(self, old_operand, var_name);
                if (new_operand != old_operand) {
                    changed = true;
                    const new_return = try self.ast.addNode(.{
                        .tag = .return_statement,
                        .span = stmt_node.span,
                        .data = .{ .unary = .{ .operand = new_operand, .flags = stmt_node.data.unary.flags } },
                    });
                    try self.scratch.append(self.allocator, new_return);
                    continue;
                }
            }
        }
        try self.scratch.append(self.allocator, stmt_idx);
    }

    if (!changed) return block_idx;

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
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
    // 사용자가 명시 `.withConfig({...})` 작성한 경우 wrap 시 later-wins 시맨틱으로 user 의
    // componentId 가 우리 자동 ID 로 override 되는 footgun. 보수적 skip — user 의 명시 의도
    // 존중.
    if (chain.has_user_with_config) return init_idx;

    const new_tag = try buildWithConfigCall(self, tag_idx, var_name);
    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(new_tag),
        @intFromEnum(template_idx),
        flags,
    });
    return self.ast.addNode(.{
        .tag = .tagged_template_expression,
        .span = init_node.span,
        .data = .{ .extra = new_extra },
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
