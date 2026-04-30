//! emotion 1st-party transform — `compiler.emotion`.
//!
//! ## 변환 의도
//!
//! Reference: `references/emotion/packages/babel-plugin/` (MIT) /
//! `references/swc-plugins/packages/emotion/` (Apache 2.0).
//!
//! ```js
//! // 입력
//! import { css } from "@emotion/react";
//! const button = css`color: red;`;
//!
//! // 출력 (autoLabel)
//! import { css } from "@emotion/react";
//! const button = css`label:button;color: red;`;
//! ```
//!
//! ## 첫 PR 범위 — autoLabel
//!
//! - 변수명을 CSS class label 로 자동 부여 — DevTools 가독성
//! - `import { css } from "@emotion/react"` 의 named binding 추적
//! - `const X = css\`...\`` 형태에서 첫 quasi text 에 `label:X;` prepend
//! - styled-components 와 별개: emotion 은 named import (`{ css }`),
//!   styled-components 는 default import (`styled`).
//!
//! ## 후속 PR (미지원)
//!
//! - sourceMap 라벨링
//! - `<div css={...}>` prop hoist
//! - `@emotion/styled` (default styled — styled-components 와 동일 패턴)
//! - `keyframes` / `Global` / `injectGlobal`

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

/// emotion `css` import source 문자열 — 흔한 4가지 entry 모두 인정.
pub const EMOTION_CSS_SOURCES: []const []const u8 = &.{
    "@emotion/react",
    "@emotion/css",
    "@emotion/core", // legacy v10
    "@emotion/native", // RN
};

pub fn isEmotionCssSource(source: []const u8) bool {
    for (EMOTION_CSS_SOURCES) |s| {
        if (std.mem.eql(u8, s, source)) return true;
    }
    return false;
}

/// `visitImportDeclaration` hook — source 가 emotion 이고 `{ css }` named specifier 가 있으면
/// local binding 이름을 state.css_binding 에 저장.
pub fn detectEmotionImport(self: *Transformer, node: Node) Error!void {
    if (!self.options.emotion) return;
    if (self.plugins.emotion.css_binding != null) return;

    const x = module_parser.readImportDeclExtras(self.ast, node.data.extra);
    if (x.source.isNone()) return;
    const source_node = self.ast.getNode(x.source);
    if (source_node.tag != .string_literal) return;
    const source_text = import_scanner.stripQuotes(self.ast.getText(source_node.span)) orelse return;
    if (!isEmotionCssSource(source_text)) return;

    var i: u32 = 0;
    while (i < x.specs_len) : (i += 1) {
        const spec_idx_raw = self.ast.extra_data.items[x.specs_start + i];
        const spec_idx: NodeIndex = @enumFromInt(spec_idx_raw);
        if (spec_idx.isNone()) continue;
        const spec_node = self.ast.getNode(spec_idx);
        if (spec_node.tag != .import_specifier) continue;
        // import_specifier: binary { left=imported, right=local }
        const imported_idx = spec_node.data.binary.left;
        const local_idx = spec_node.data.binary.right;
        if (imported_idx.isNone() or local_idx.isNone()) continue;
        const imported_node = self.ast.getNode(imported_idx);
        if (imported_node.tag != .identifier_reference) continue;
        if (!std.mem.eql(u8, self.ast.getText(imported_node.data.string_ref), "css")) continue;
        // local 이름 추출 (alias 있을 수 있음).
        const local_node = self.ast.getNode(local_idx);
        if (local_node.tag != .identifier_reference and local_node.tag != .binding_identifier) continue;
        const local_name = self.ast.getText(local_node.data.string_ref);
        if (local_name.len == 0) continue;
        self.plugins.emotion.css_binding = local_name;
        return;
    }
}

/// `visitVariableDeclarator` 의 post-visit hook — emotion `css\`...\`` 형태면 첫 quasi 에
/// `label:<var_name>;` prepend.
pub fn maybeApplyAutoLabel(self: *Transformer, init_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    if (!self.options.emotion) return init_idx;
    const binding = self.plugins.emotion.css_binding orelse return init_idx;
    if (var_name.len == 0) return init_idx;
    if (init_idx.isNone()) return init_idx;

    const init_node = self.ast.getNode(init_idx);
    if (init_node.tag != .tagged_template_expression) return init_idx;

    // tagged_template extra = [tag, template, flags]
    const e = init_node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return init_idx;
    const tag_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const template_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
    const flags = self.ast.extra_data.items[e + 2];

    // tag 가 emotion css binding 인지 확인 — `css` 식별자만 (chain `css.something` 은 skip).
    if (tag_idx.isNone()) return init_idx;
    const tag_node = self.ast.getNode(tag_idx);
    if (tag_node.tag != .identifier_reference) return init_idx;
    if (!std.mem.eql(u8, self.ast.getText(tag_node.data.string_ref), binding)) return init_idx;

    const new_template = try prependLabelToTemplate(self, template_idx, var_name);
    if (new_template == template_idx) return init_idx;

    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(tag_idx),
        @intFromEnum(new_template),
        flags,
    });
    return self.ast.addNode(.{
        .tag = .tagged_template_expression,
        .span = init_node.span,
        .data = .{ .extra = new_extra },
    });
}

/// template_literal 의 첫 quasi 시작에 `label:<name>;` prepend. no-interp / interp 둘 다 처리.
fn prependLabelToTemplate(self: *Transformer, template_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    const node = self.ast.getNode(template_idx);
    if (node.tag != .template_literal) return template_idx;

    if (node.data.none == 0) {
        return try prependLabelToNoInterpTemplate(self, template_idx, node, var_name);
    }
    return try prependLabelToInterpTemplate(self, template_idx, node, var_name);
}

/// no-interp `\`text\`` — `\`label:<name>;text\`` 빌드.
fn prependLabelToNoInterpTemplate(
    self: *Transformer,
    template_idx: NodeIndex,
    node: ast_mod.Node,
    var_name: []const u8,
) Error!NodeIndex {
    const raw = self.ast.getText(node.span);
    if (raw.len < 2 or raw[0] != '`' or raw[raw.len - 1] != '`') return template_idx;
    const inner = raw[1 .. raw.len - 1];

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.append(self.allocator, '`');
    try writeLabelPrefix(self.allocator, &buf, var_name);
    try buf.appendSlice(self.allocator, inner);
    try buf.append(self.allocator, '`');

    const new_span = try self.ast.addString(buf.items);
    return self.ast.addNode(.{
        .tag = .template_literal,
        .span = new_span,
        .data = .{ .list = .{ .start = 0, .len = 0 } },
    });
}

/// interp template — 첫 template_element 시작에 `label:<name>;` prepend.
fn prependLabelToInterpTemplate(
    self: *Transformer,
    template_idx: NodeIndex,
    node: ast_mod.Node,
    var_name: []const u8,
) Error!NodeIndex {
    const list = node.data.list;
    if (list.len == 0) return template_idx;
    const items = self.ast.extra_data.items[list.start .. list.start + list.len];

    const first_idx: NodeIndex = @enumFromInt(items[0]);
    const first_node = self.ast.getNode(first_idx);
    if (first_node.tag != .template_element) return template_idx;

    // 첫 element span: `\`text${` (head) — 첫 char 가 backtick, 끝이 `${`.
    const raw = self.ast.getText(first_node.span);
    if (raw.len < 3 or raw[0] != '`') return template_idx;
    if (raw[raw.len - 2] != '$' or raw[raw.len - 1] != '{') return template_idx;
    const inner = raw[1 .. raw.len - 2];

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.append(self.allocator, '`');
    try writeLabelPrefix(self.allocator, &buf, var_name);
    try buf.appendSlice(self.allocator, inner);
    try buf.append(self.allocator, '$');
    try buf.append(self.allocator, '{');

    const new_first_span = try self.ast.addString(buf.items);
    const new_first = try self.ast.addNode(.{
        .tag = .template_element,
        .span = new_first_span,
        .data = .{ .none = 0 },
    });

    // children list 재구성 — 첫 번째만 교체, 나머지는 그대로.
    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);
    try self.scratch.append(self.allocator, new_first);
    for (items[1..]) |raw_idx| try self.scratch.append(self.allocator, @enumFromInt(raw_idx));

    const new_list = try self.ast.addNodeList(self.scratch.items[top..]);
    return self.ast.addNode(.{
        .tag = .template_literal,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}

fn writeLabelPrefix(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), var_name: []const u8) Error!void {
    try buf.appendSlice(allocator, "label:");
    try buf.appendSlice(allocator, var_name);
    try buf.append(allocator, ';');
}
