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

/// emotion `css` / `keyframes` named import 가 export 되는 source 들.
pub const EMOTION_CSS_SOURCES: []const []const u8 = &.{
    "@emotion/react",
    "@emotion/css",
    "@emotion/core", // legacy v10
    "@emotion/native", // RN
    "@emotion/primitives", // RN primitives
    "@emotion/primitives-core", // RN primitives 의 core
};

/// emotion default `styled` import 가 export 되는 source 들.
pub const EMOTION_STYLED_SOURCES: []const []const u8 = &.{
    "@emotion/styled",
    "@emotion/native", // @emotion/native 는 default styled 도 export
    "@emotion/primitives", // RN primitives 도 default styled
    "@emotion/styled-base", // 저레벨 패키지 — 일부 사용자 직접 import
};

fn isInList(source: []const u8, list: []const []const u8) bool {
    for (list) |s| {
        if (std.mem.eql(u8, s, source)) return true;
    }
    return false;
}

pub fn isEmotionCssSource(source: []const u8) bool {
    return isInList(source, EMOTION_CSS_SOURCES);
}

pub fn isEmotionStyledSource(source: []const u8) bool {
    return isInList(source, EMOTION_STYLED_SOURCES);
}

/// emotion named-import (`{ X }` 형태) 별 EmotionState 필드 매핑. 새 named API 가
/// 추가되면 여기에 한 줄만 더하면 import 인식 + tagMatchesEmotion (해당 시) 까지 자동.
const NamedImportSpec = struct {
    imported: []const u8,
    field: []const u8,
};

const NAMED_IMPORT_SPECS = [_]NamedImportSpec{
    .{ .imported = "css", .field = "css_binding" },
    .{ .imported = "keyframes", .field = "keyframes_binding" },
    .{ .imported = "injectGlobal", .field = "inject_global_binding" },
    .{ .imported = "Global", .field = "global_binding" },
};

/// `tagMatchesEmotion` 의 identifier 형태 매칭에 참여하는 binding 필드들.
/// `Global` 은 JSX element 매칭이라 제외, `styled` 는 chain 처리라 제외.
const TAG_BINDING_FIELDS = [_][]const u8{
    "css_binding",
    "keyframes_binding",
    "inject_global_binding",
};

/// `visitImportDeclaration` hook — emotion source 의 `{ css }` named specifier 또는
/// `@emotion/styled` 의 default specifier 를 binding 으로 저장.
pub fn detectEmotionImport(self: *Transformer, node: Node) Error!void {
    if (!self.options.emotion) return;

    const x = module_parser.readImportDeclExtras(self.ast, node.data.extra);
    if (x.source.isNone()) return;
    const source_node = self.ast.getNode(x.source);
    if (source_node.tag != .string_literal) return;
    const source_text = import_scanner.stripQuotes(self.ast.getText(source_node.span)) orelse return;

    const want_css_or_keyframes = isEmotionCssSource(source_text);
    const want_styled = isEmotionStyledSource(source_text) and self.plugins.emotion.styled_binding == null;
    if (!want_css_or_keyframes and !want_styled) return;

    var i: u32 = 0;
    while (i < x.specs_len) : (i += 1) {
        const spec_idx_raw = self.ast.extra_data.items[x.specs_start + i];
        const spec_idx: NodeIndex = @enumFromInt(spec_idx_raw);
        if (spec_idx.isNone()) continue;
        const spec_node = self.ast.getNode(spec_idx);
        switch (spec_node.tag) {
            .import_default_specifier => {
                if (!want_styled) continue;
                const local_name = self.ast.getText(spec_node.data.string_ref);
                if (local_name.len == 0) continue;
                self.plugins.emotion.styled_binding = local_name;
            },
            .import_specifier => {
                if (!want_css_or_keyframes) continue;
                // binary { left=imported, right=local }
                const imported_idx = spec_node.data.binary.left;
                const local_idx = spec_node.data.binary.right;
                if (imported_idx.isNone() or local_idx.isNone()) continue;
                const imported_node = self.ast.getNode(imported_idx);
                if (imported_node.tag != .identifier_reference) continue;
                const imported_name = self.ast.getText(imported_node.data.string_ref);
                const local_node = self.ast.getNode(local_idx);
                if (local_node.tag != .identifier_reference and local_node.tag != .binding_identifier) continue;
                const local_name = self.ast.getText(local_node.data.string_ref);
                if (local_name.len == 0) continue;
                inline for (NAMED_IMPORT_SPECS) |spec| {
                    if (std.mem.eql(u8, imported_name, spec.imported) and
                        @field(self.plugins.emotion, spec.field) == null)
                    {
                        @field(self.plugins.emotion, spec.field) = local_name;
                        break;
                    }
                }
            },
            else => {},
        }
    }
}

/// `visitVariableDeclarator` 의 post-visit hook. tag 가 emotion binding 이면 첫 quasi 에
/// `label:<var_name>;` prepend.
///
/// 인식 형태:
///   - `css\`...\`` (css_binding identifier 직접)
///   - `styled.div\`...\`` (styled_binding 의 static_member 첫 단계)
///   - `styled(Component)\`...\`` (styled_binding 의 call 첫 단계)
///
/// 미인식 (후속 PR):
///   - `css.x\`...\`` / `styled.div.attrs({})\`...\`` 같은 추가 chain
pub fn maybeApplyAutoLabel(self: *Transformer, init_idx: NodeIndex, var_name: []const u8) Error!NodeIndex {
    if (!self.options.emotion) return init_idx;
    if (!self.options.emotion_auto_label) return init_idx; // opt-out: emotion 활성이지만 autoLabel skip
    if (var_name.len == 0) return init_idx;
    if (init_idx.isNone()) return init_idx;

    const init_node = self.ast.getNode(init_idx);
    if (init_node.tag != .tagged_template_expression) return init_idx;

    const e = init_node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return init_idx;
    const tag_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const template_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
    const flags = self.ast.extra_data.items[e + 2];

    if (!tagMatchesEmotion(self, tag_idx)) return init_idx;

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

/// JSX attribute value autoLabel hook — `lowerJSXAttribute` 에서 호출.
///
/// 두 가지 시나리오 처리:
///   1. **모든 element 의 `css` attr** — `<Button css={css\`...\`}>` → `label:Button;`,
///      `<div css={css\`...\`}>` → `label:div;`.
///   2. **`<Global>` element 의 `styles` attr** — `<Global styles={css\`...\`}>` →
///      `label:Global;` (alias 시 alias 이름). emotion 이 import 한 `Global` binding 과
///      element name 이 일치할 때만 `styles` 를 인식 — `styles` 자체는 너무 일반적이라
///      false-positive 위험 (다른 라이브러리의 styles prop) 방지.
///
/// 공통 흐름: parser 가 attribute value 에 jsx_expression_container 를 만들지 않고
/// 내부 expression 을 직접 저장 (parser/jsx.zig:301-325). label 추출 후 기존
/// `maybeApplyAutoLabel` 로 template 변형 (emotion + autoLabel 옵션 검사도 거기서).
pub fn maybeApplyAutoLabelForJsxAttr(
    self: *Transformer,
    attr_name: []const u8,
    value_idx: NodeIndex,
    tag_name_idx: NodeIndex,
) Error!NodeIndex {
    // hot path: 모든 JSX attribute (className/onClick/id/...) 마다 호출 — attr-name
    // 빠른 reject 를 AST 접근 (`jsxElementLabel`) 보다 먼저 수행.
    const is_css = std.mem.eql(u8, attr_name, "css");
    const is_styles = std.mem.eql(u8, attr_name, "styles");
    if (!is_css and !is_styles) return value_idx;
    if (value_idx.isNone()) return value_idx;

    const label = jsxElementLabel(self, tag_name_idx) orelse return value_idx;
    const is_global_styles = is_styles and elementMatchesGlobal(self, tag_name_idx);
    if (!is_css and !is_global_styles) return value_idx;

    return try maybeApplyAutoLabel(self, value_idx, label);
}

/// JSX element 가 import 된 `Global` binding 과 일치하는지.
///
/// **단순 jsx_identifier 만 매칭** — `<Foo.Global>` 같은 member expression 은 거부.
/// 이유: rightmost 가 "Global" 이라도 사용자 컴포넌트 (`<Foo.Global>`) 가 emotion 의
/// `Global` 일 가능성은 0 → false-positive 방지. 정식으로 지원하려면 namespace import
/// (`import * as Em`) 추적이 필요한데 현재 범위 밖.
fn elementMatchesGlobal(self: *Transformer, tag_name_idx: NodeIndex) bool {
    const binding = self.plugins.emotion.global_binding orelse return false;
    if (tag_name_idx.isNone()) return false;
    const tag_node = self.ast.getNode(tag_name_idx);
    if (tag_node.tag != .jsx_identifier) return false;
    return std.mem.eql(u8, self.ast.getText(tag_node.span), binding);
}

/// JSX element label 추출 — autoLabel 의 source 로 쓰일 이름.
///
/// 처리:
///   - `jsx_identifier` (`<Button>`) → "Button"
///   - `jsx_member_expression` (`<Foo.Bar>`, `<Foo.Bar.Baz>`) → rightmost identifier
///     (babel-plugin-emotion 동작과 일치 — 의미 있는 부분이 rightmost).
fn jsxElementLabel(self: *Transformer, tag_name_idx: NodeIndex) ?[]const u8 {
    if (tag_name_idx.isNone()) return null;
    var current = tag_name_idx;
    while (true) {
        const node = self.ast.getNode(current);
        switch (node.tag) {
            .jsx_identifier => return self.ast.getText(node.span),
            .jsx_member_expression => {
                current = node.data.binary.right;
                if (current.isNone()) return null;
            },
            else => return null,
        }
    }
}

/// tag 가 emotion 인식 패턴인지 확인.
///   - `css\`...\`` / `keyframes\`...\`` — 직접 identifier 만
///   - `styled.X\`...\`` / `styled(X)\`...\`` / `styled.div.withComponent(...)\`...\`` —
///     chain walker (root identifier 가 styled_binding 이면 인식)
fn tagMatchesEmotion(self: *Transformer, tag_idx: NodeIndex) bool {
    if (tag_idx.isNone()) return false;
    const state = &self.plugins.emotion;
    const tag_node = self.ast.getNode(tag_idx);

    // 직접 identifier — css 또는 keyframes binding 만 인식 (`css.x` 같은 chain 은 제외 — emotion
    // 의 `css` 는 member API 가 없어 chain 시 부정확한 라벨 위험).
    if (tag_node.tag == .identifier_reference) {
        const text = self.ast.getText(tag_node.data.string_ref);
        inline for (TAG_BINDING_FIELDS) |field_name| {
            if (@field(state, field_name)) |b| {
                if (std.mem.eql(u8, text, b)) return true;
            }
        }
        return false;
    }

    // chain (member / call) — root 까지 walk 해서 styled_binding 매치 확인.
    // styled.div / styled(X) / styled.div.withComponent(...) / styled(X).withComponent(...) 등.
    return chainRootIsStyledBinding(self, tag_idx);
}

/// chain root identifier 가 styled_binding 인지 확인. styled-components 의 analyzeTagChain
/// 과 동일 패턴 (descend `static_member_expression.object` / `call_expression.callee`).
fn chainRootIsStyledBinding(self: *Transformer, tag_idx: NodeIndex) bool {
    const binding = self.plugins.emotion.styled_binding orelse return false;
    var current = tag_idx;
    while (true) {
        if (current.isNone()) return false;
        const node = self.ast.getNode(current);
        switch (node.tag) {
            .identifier_reference => {
                return std.mem.eql(u8, self.ast.getText(node.data.string_ref), binding);
            },
            .static_member_expression => {
                if (!self.ast.hasExtra(node.data.extra, 1)) return false;
                current = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
            },
            .call_expression => {
                if (!self.ast.hasExtra(node.data.extra, 0)) return false;
                current = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
            },
            else => return false,
        }
    }
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
