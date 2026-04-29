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
//! // 출력 (babel-plugin-styled-components 의 표준 형태)
//! import styled from "styled-components";
//! const Button = styled.div.withConfig({ displayName: "Button" })`color: red;`;
//! ```
//!
//! 본 ZTS 구현은 **iterative**:
//! - **현재 (이번 PR)**: post-declaration `Button.displayName = "Button";` — DevTools 표시 충족
//! - **후속 PR**: `.withConfig(...)` 래핑 + componentId hash + SSR 안정화
//!
//! ## hook point
//!
//! - `visitImportDeclaration`: source 가 "styled-components" / "styled-components/native" 면
//!   default specifier 의 로컬 이름을 `state.default_binding` 에 저장.
//! - `visitVariableDeclarator`: init 이 `<binding>.X\`...\`` / `<binding>(X)\`...\`` 형태이면
//!   `state.registrations` 에 변수 이름 추가.
//! - 프로그램 끝 (`run`): registrations 마다 `<name>.displayName = "<name>";` 주입.
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
const module_parser = @import("../../parser/module.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const StyledComponentRegistration = @import("../plugin_state.zig").StyledComponentRegistration;

/// styled-components import source 문자열 (정확 매치). v6+ 는 "/native" subpath 도 인정.
pub const STYLED_SOURCES: []const []const u8 = &.{
    "styled-components",
    "styled-components/native",
};

/// string_literal 의 텍스트에서 따옴표를 제거. 빈 문자열 / 따옴표 없는 경우 null.
fn unquoteStringLiteral(raw: []const u8) ?[]const u8 {
    if (raw.len < 2) return null;
    const q = raw[0];
    if (q != '"' and q != '\'' and q != '`') return null;
    if (raw[raw.len - 1] != q) return null;
    return raw[1 .. raw.len - 1];
}

/// import source 가 styled-components 인지 확인.
pub fn isStyledImportSource(source: []const u8) bool {
    for (STYLED_SOURCES) |s| {
        if (std.mem.eql(u8, s, source)) return true;
    }
    return false;
}

/// `visitImportDeclaration` 의 hook. styled-components import 면 default specifier
/// 로컬 이름을 `state.styled_components.default_binding` 에 저장.
///
/// 호출 시점: visitImportDeclaration 의 본격 변환 전. 옵션 비활성 시 즉시 return.
pub fn detectStyledImport(self: *Transformer, node: Node) void {
    if (!self.options.styled_components) return;
    // 이미 다른 styled-components import 가 감지된 경우 — 중복 import 는 드물지만,
    // 첫 import 의 binding 을 유지 (babel-plugin 동작).
    if (self.plugins.styled_components.default_binding != null) return;

    const x = module_parser.readImportDeclExtras(self.ast, node.data.extra);
    // source 노드에서 unquoted 텍스트 추출.
    if (x.source.isNone()) return;
    const source_node = self.ast.getNode(x.source);
    if (source_node.tag != .string_literal) return;
    const raw = self.ast.getText(source_node.span);
    const source_text = unquoteStringLiteral(raw) orelse return;
    if (!isStyledImportSource(source_text)) return;

    // specifiers 순회 — default specifier 의 local 이름 찾기.
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

/// tag 표현식이 styled binding 을 사용하는지 확인.
/// 인식 케이스 (이번 PR):
///   - `<binding>.X` (static_member_expression) → true
///   - `<binding>(arg)` (call_expression) → true
/// 미인식 (후속 PR):
///   - `<binding>.X.attrs({...})` chain
///   - `<binding>.X.withConfig({...})` chain
fn tagUsesBinding(self: *Transformer, tag_idx: NodeIndex, binding: []const u8) bool {
    if (tag_idx.isNone()) return false;
    const tag_node = self.ast.getNode(tag_idx);
    switch (tag_node.tag) {
        .static_member_expression => {
            // extra = [object, property, flags]
            const e = tag_node.data.extra;
            if (e + 1 >= self.ast.extra_data.items.len) return false;
            const obj_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            if (obj_idx.isNone()) return false;
            const obj_node = self.ast.getNode(obj_idx);
            if (obj_node.tag != .identifier_reference) return false;
            const name = self.ast.getText(obj_node.data.string_ref);
            return std.mem.eql(u8, name, binding);
        },
        .call_expression => {
            // extra = [callee, args_start, args_len, flags]
            const e = tag_node.data.extra;
            if (e >= self.ast.extra_data.items.len) return false;
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            if (callee_idx.isNone()) return false;
            const callee_node = self.ast.getNode(callee_idx);
            if (callee_node.tag != .identifier_reference) return false;
            const name = self.ast.getText(callee_node.data.string_ref);
            return std.mem.eql(u8, name, binding);
        },
        else => return false,
    }
}

/// `visitVariableDeclarator` hook. init 이 styled tagged template 이면 변수 이름을
/// `state.styled_components.registrations` 에 추가.
///
/// 호출 시점: visitVariableDeclarator 의 변환 직전. 옵션 비활성 / binding 미감지 시 no-op.
pub fn detectStyledDeclaration(self: *Transformer, node: Node) void {
    if (!self.options.styled_components) return;
    const binding = self.plugins.styled_components.default_binding orelse return;

    // variable_declarator extra = [name, type_annotation, init]
    const e = node.data.extra;
    if (e + 2 >= self.ast.extra_data.items.len) return;
    const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
    if (init_idx.isNone()) return;

    const init_node = self.ast.getNode(init_idx);
    if (init_node.tag != .tagged_template_expression) return;

    // tagged_template_expression: extra = [tag, template, flags]
    const te = init_node.data.extra;
    if (te + 1 >= self.ast.extra_data.items.len) return;
    const tag_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[te]);
    if (!tagUsesBinding(self, tag_idx, binding)) return;

    // 변수 이름 추출 — binding_identifier.string_ref 의 텍스트.
    if (name_idx.isNone()) return;
    const name_node = self.ast.getNode(name_idx);
    if (name_node.tag != .binding_identifier and name_node.tag != .identifier_reference) return;
    const var_name = self.ast.getText(name_node.data.string_ref);
    if (var_name.len == 0) return;

    self.plugins.styled_components.registrations.append(self.allocator, .{ .name = var_name }) catch return;
}
