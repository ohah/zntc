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

/// tag 표현식이 styled binding 을 사용하는지 확인 (root identifier 만 비교).
/// 인식: `<binding>.X` / `<binding>(arg)`. 미인식 (후속 PR): chain `.attrs(...)` / `.withConfig(...)`.
fn tagUsesBinding(self: *Transformer, tag_idx: NodeIndex) bool {
    if (tag_idx.isNone()) return false;
    const binding = self.plugins.styled_components.default_binding orelse return false;
    const tag_node = self.ast.getNode(tag_idx);
    const root_idx: NodeIndex = switch (tag_node.tag) {
        .static_member_expression => blk: {
            // extra = [object, property, flags]
            if (!self.ast.hasExtra(tag_node.data.extra, 1)) return false;
            break :blk @enumFromInt(self.ast.extra_data.items[tag_node.data.extra]);
        },
        .call_expression => blk: {
            // extra = [callee, args_start, args_len, flags]
            if (!self.ast.hasExtra(tag_node.data.extra, 0)) return false;
            break :blk @enumFromInt(self.ast.extra_data.items[tag_node.data.extra]);
        },
        else => return false,
    };
    if (root_idx.isNone()) return false;
    const root_node = self.ast.getNode(root_idx);
    if (root_node.tag != .identifier_reference) return false;
    return std.mem.eql(u8, self.ast.getText(root_node.data.string_ref), binding);
}

/// `visitVariableDeclarator` 의 post-visit hook. caller 가 init.tag 를 사전 검사한 뒤
/// tagged_template_expression 일 때만 호출 — 옵션 비활성 / binding 미감지 / 다른 tag 면
/// caller 가 미리 거른다.
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

/// `<tag>.withConfig({ displayName: "<var_name>" })` call_expression 빌드.
/// "withConfig" / "displayName" span 은 PluginState 에 lazy 캐싱 — 매 호출마다 string_table
/// 에 같은 문자열이 append 되는 것을 피한다 (refresh.zig 의 $RefreshReg$ span 패턴과 동일).
fn buildWithConfigCall(self: *Transformer, tag_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    const zero = Span{ .start = 0, .end = 0 };
    const state = &self.plugins.styled_components;
    if (state.with_config_span == null) state.with_config_span = try self.ast.addString("withConfig");
    if (state.display_name_span == null) state.display_name_span = try self.ast.addString("displayName");
    const with_config_span = state.with_config_span.?;
    const display_name_key_span = state.display_name_span.?;

    var quoted_buf: [256]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{var_name}) catch return error.OutOfMemory;
    const quoted_span = try self.ast.addString(quoted);

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

    const key = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = display_name_key_span,
        .data = .{ .string_ref = display_name_key_span },
    });
    const value = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = quoted_span,
        .data = .{ .string_ref = quoted_span },
    });
    // object_property: binary = { left=key, right=value, flags }
    const property = try self.ast.addNode(.{
        .tag = .object_property,
        .span = zero,
        .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
    });

    const obj_list = try self.ast.addNodeList(&.{property});
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
