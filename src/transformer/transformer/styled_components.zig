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
//! - 조건부: `cond ? styled.div\`\` : styled.div\`\`` (var 이름 단일)
//! - 클래스 정적 필드: `class { static Child = styled.div\`\` }` (이름 = "Child")
//! - 객체 프로퍼티: `{ One: styled.div\`\` }` (이름 = "One")
//! - 체인: `styled.div.attrs({...})\`\`` / `styled.div.withConfig({...})\`\``
//! - 할당: `var X = Y = styled.div\`\``

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

/// tag 표현식의 chain root 가 styled binding 인지 확인.
/// 인식 (모두):
///   - `<binding>.X` (static_member)
///   - `<binding>(arg)` (call)
///   - `<binding>.X.attrs({...})` / `<binding>(X).attrs({...})` (chain: call→member→identifier)
///   - `<binding>.X.attrs({...}).attrs({...})` (다중 체인)
///   - `<binding>.X.withConfig({...})` (사용자 명시 withConfig — 본 PR 은 추가 .withConfig
///     를 한 번 더 append 하므로 styled-components 의 later-wins 시맨틱에 의존; 후속 PR 에서
///     기존 withConfig 인식 시 merge / skip 분기)
fn tagUsesBinding(self: *Transformer, tag_idx: NodeIndex) bool {
    const binding = self.plugins.styled_components.default_binding orelse return false;
    var current = tag_idx;
    while (true) {
        if (current.isNone()) return false;
        const node = self.ast.getNode(current);
        switch (node.tag) {
            .identifier_reference => {
                return std.mem.eql(u8, self.ast.getText(node.data.string_ref), binding);
            },
            .static_member_expression => {
                // extra = [object, property, flags] — root 방향으로 object 만 따라감.
                if (!self.ast.hasExtra(node.data.extra, 1)) return false;
                current = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
            },
            .call_expression => {
                // extra = [callee, args_start, args_len, flags] — root 방향으로 callee 만 따라감.
                if (!self.ast.hasExtra(node.data.extra, 0)) return false;
                current = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
            },
            else => return false,
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

/// 표현식이 styled tagged template 을 (직접 / 조건부 / 괄호 안에) 포함하면 wrap.
/// caller 가 init.tag 를 사전 검사 (`isWrappableExpr`) 한 뒤 호출.
///
/// 인식 expression 형태:
///   - `styled.div\`...\`` (직접)
///   - `cond ? styled.div\`\` : styled.div\`\`` (양쪽 branch 에 같은 var_name 적용 — babel 동작)
///   - `(styled.div\`\`)` (괄호 안)
///   - 위 조합 (조건부 안의 괄호 등)
pub fn wrapStyledTagInExpr(self: *Transformer, expr_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    if (expr_idx.isNone()) return expr_idx;
    const node = self.ast.getNode(expr_idx);
    switch (node.tag) {
        .tagged_template_expression => return wrapStyledTag(self, expr_idx, var_name),
        .conditional_expression => {
            // ternary: a=test, b=consequent, c=alternate. test 는 전파하지 않음 (boolean expr).
            const old_b = node.data.ternary.b;
            const old_c = node.data.ternary.c;
            const new_b = try wrapStyledTagInExpr(self, old_b, var_name);
            const new_c = try wrapStyledTagInExpr(self, old_c, var_name);
            if (new_b == old_b and new_c == old_c) return expr_idx;
            return self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = node.span,
                .data = .{ .ternary = .{
                    .a = node.data.ternary.a,
                    .b = new_b,
                    .c = new_c,
                } },
            });
        },
        .parenthesized_expression => {
            const old_inner = node.data.unary.operand;
            const new_inner = try wrapStyledTagInExpr(self, old_inner, var_name);
            if (new_inner == old_inner) return expr_idx;
            return self.ast.addNode(.{
                .tag = .parenthesized_expression,
                .span = node.span,
                .data = .{ .unary = .{ .operand = new_inner, .flags = node.data.unary.flags } },
            });
        },
        else => return expr_idx,
    }
}

/// caller 의 fast-path 사전 필터 — wrapStyledTagInExpr 가 처리할 수 있는 형태인지.
/// 옵션 OFF / binding 미감지 / 단순 식별자 init (`= 5`, `= other`) 같은 케이스에서 var_name
/// 추출 + 함수 호출 비용을 회피.
pub fn isWrappableExpr(tag: ast_mod.Node.Tag) bool {
    return tag == .tagged_template_expression or
        tag == .conditional_expression or
        tag == .parenthesized_expression;
}

/// 직접 styled tagged template 일 때만 호출되는 wrap (caller 가 tag 검증 후 호출).
/// `wrapStyledTagInExpr` 의 재귀 base case.
pub fn wrapStyledTag(self: *Transformer, init_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    if (var_name.len == 0) return init_idx;
    const init_node = self.ast.getNode(init_idx);

    // tagged_template extra = [tag, template, flags]
    const e = init_node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return init_idx;
    const tag_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const template_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
    const flags = self.ast.extra_data.items[e + 2];

    if (!tagUsesBinding(self, tag_idx)) return init_idx;

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
    const has_filename = self.options.jsx_filename.len > 0;
    if (has_filename) {
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

    const obj_list = if (has_filename) blk: {
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
