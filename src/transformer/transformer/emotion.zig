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
const plugin_state = @import("../plugin_state.zig");
const sourcemap_mod = @import("../../codegen/sourcemap.zig");

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
    .{ .imported = "ClassNames", .field = "class_names_binding" },
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

/// `visitVariableDeclarator` 의 post-visit hook + JSX inline css attr hook 의 공용 코어.
/// tag 가 emotion binding 이면 두 가지 transform 중 활성된 것 적용:
///   - **autoLabel** — 첫 quasi 시작에 `label:<var_name>;` prepend (`emotion_auto_label`).
///   - **sourceMap** — 마지막 quasi 끝에 inline `/*# sourceMappingURL=... */` append
///     (`emotion_source_map`). babel-plugin-emotion 동작과 동일.
///
/// 인식 형태:
///   - `css\`...\`` (css_binding identifier 직접)
///   - `styled.div\`...\`` / `styled(Component)\`...\`` (styled_binding chain)
pub fn maybeTransformEmotionTemplate(
    self: *Transformer,
    init_idx: NodeIndex,
    var_name: []const u8,
) Error!NodeIndex {
    if (!self.options.emotion) return init_idx;
    if (init_idx.isNone()) return init_idx;

    const init_node = self.ast.getNode(init_idx);
    if (init_node.tag != .tagged_template_expression) return init_idx;

    const e = init_node.data.extra;
    if (!self.ast.hasExtra(e, 2)) return init_idx;
    const tag_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    const template_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
    const flags = self.ast.extra_data.items[e + 2];

    if (!tagMatchesEmotion(self, tag_idx)) return init_idx;

    const apply_label = labelEnabledNow(self) and var_name.len > 0;
    const apply_sm = self.options.emotion_source_map;
    if (!apply_label and !apply_sm) return init_idx;

    const label_text: ?[]const u8 = if (apply_label) var_name else null;

    var sm_buf: std.ArrayList(u8) = .empty;
    defer sm_buf.deinit(self.allocator);
    if (apply_sm) {
        try ensureNewlineCache(self);
        const pos = byteOffsetToLineColCached(self, init_node.span.start);
        const filename = if (self.options.jsx_filename.len > 0) self.options.jsx_filename else "unknown";
        try buildSourceMapComment(self.allocator, &sm_buf, self.ast.source, filename, pos);
    }
    const sm_text: ?[]const u8 = if (apply_sm) sm_buf.items else null;

    const new_template = try transformEmotionTemplate(self, template_idx, label_text, sm_text);
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
/// `maybeTransformEmotionTemplate` 로 template 변형 (emotion + autoLabel + sourceMap
/// 옵션 검사도 거기서).
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
    // className 은 ClassNames render-prop scope 안에서만 인식 (밖에서는 일반 className
    // 이라 절대 처리 금지 — scope_stack 비어있으면 즉시 false).
    const is_classnames_inline = self.plugins.emotion.scope_stack.items.len > 0 and
        std.mem.eql(u8, attr_name, "className");
    if (!is_css and !is_styles and !is_classnames_inline) return value_idx;
    if (value_idx.isNone()) return value_idx;

    // styles attr 은 `<Global>` element 일 때만 통과 — 다른 element 에서는 false-positive
    // 위험 (다른 라이브러리/사용자 컴포넌트의 styles prop).
    if (is_styles and !elementMatchesGlobal(self, tag_name_idx)) return value_idx;

    const label = jsxElementLabel(self, tag_name_idx) orelse return value_idx;
    return try maybeTransformEmotionTemplate(self, value_idx, label);
}

/// JSX element 가 import 된 `Global` binding 과 일치하는지 — 단순 identifier 만.
fn elementMatchesGlobal(self: *Transformer, tag_name_idx: NodeIndex) bool {
    const binding = self.plugins.emotion.global_binding orelse return false;
    return jsxIdentifierEquals(self, tag_name_idx, binding);
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

/// `<ClassNames>` JSX element 진입 시 scope frame 을 push.
/// 반환 true: scope 가 push 됐으니 caller 가 `exitClassNamesScope` 로 pop 책임.
/// 반환 false: ClassNames 가 아니거나 render-prop 패턴이 아님 → no-op.
///
/// 인식하는 패턴:
/// ```
/// <ClassNames>
///   {({ css }) => <div className={css`...`}/>}
/// </ClassNames>
/// ```
/// children 첫 노드가 jsx_expression_container 의 arrow_function/function_expression,
/// 그 첫 param 이 object_pattern 으로 `css` 를 destructure (alias 도 추적).
pub fn maybeEnterClassNamesScope(self: *Transformer, jsx_node: ast_mod.Node) Error!bool {
    if (!self.options.emotion) return false;
    const binding = self.plugins.emotion.class_names_binding orelse return false;

    // jsx_element extra: [tag_name, attrs_start, attrs_len, children_start, children_len]
    const e = jsx_node.data.extra;
    if (!self.ast.hasExtra(e, 4)) return false;
    const tag_name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
    if (!jsxIdentifierEquals(self, tag_name_idx, binding)) return false;

    const children_start = self.ast.extra_data.items[e + 3];
    const children_len = self.ast.extra_data.items[e + 4];

    const fn_idx = findRenderPropFunction(self, children_start, children_len) orelse return false;
    const css_local = extractDestructuredCssLocal(self, fn_idx) orelse return false;

    try self.plugins.emotion.scope_stack.append(
        self.allocator,
        .{ .css_binding = css_local },
    );
    return true;
}

/// `maybeEnterClassNamesScope` 가 true 반환했을 때 caller 가 호출 (defer pattern).
pub fn exitClassNamesScope(self: *Transformer) void {
    _ = self.plugins.emotion.scope_stack.pop();
}

/// 단순 jsx_identifier 의 텍스트가 `expected` 와 일치하는지.
/// `<Foo.X>` 같은 member expression / namespaced 는 거부 — false-positive 방지
/// (사용자 컴포넌트의 member 가 emotion binding 일 가능성 0).
fn jsxIdentifierEquals(self: *Transformer, idx: NodeIndex, expected: []const u8) bool {
    if (idx.isNone()) return false;
    const node = self.ast.getNode(idx);
    if (node.tag != .jsx_identifier) return false;
    return std.mem.eql(u8, self.ast.getText(node.span), expected);
}

/// children 중 첫 번째 jsx_expression_container 안의 arrow/function_expression 을 반환.
/// 텍스트 노드 / 다른 element 는 skip.
fn findRenderPropFunction(self: *Transformer, children_start: u32, children_len: u32) ?NodeIndex {
    if (children_len == 0) return null;
    const indices = self.ast.extra_data.items[children_start .. children_start + children_len];
    for (indices) |raw_idx| {
        const child_idx: NodeIndex = @enumFromInt(raw_idx);
        const child = self.ast.getNode(child_idx);
        if (child.tag != .jsx_expression_container) continue;
        const inner = child.data.unary.operand;
        if (inner.isNone()) continue;
        const inner_node = self.ast.getNode(inner);
        if (inner_node.tag == .arrow_function_expression or
            inner_node.tag == .function_expression)
        {
            return inner;
        }
    }
    return null;
}

/// 함수 첫 param 의 object_pattern 에서 destructured `css` 의 local 이름 추출.
/// 처리: shorthand `{ css }` → "css", aliased `{ css: cs }` → "cs".
/// nested pattern / default value 등은 first PR 범위 밖 → null.
fn extractDestructuredCssLocal(self: *Transformer, fn_idx: NodeIndex) ?[]const u8 {
    const fn_node = self.ast.getNode(fn_idx);
    const params = self.ast.functionParams(fn_node);
    if (params.len == 0) return null;
    const first_param_idx: NodeIndex = @enumFromInt(params[0]);
    const first_param = self.ast.getNode(first_param_idx);
    if (first_param.tag != .object_pattern) return null;

    const list = first_param.data.list;
    if (list.len == 0) return null;
    const props = self.ast.extra_data.items[list.start .. list.start + list.len];

    for (props) |raw_idx| {
        const prop_idx: NodeIndex = @enumFromInt(raw_idx);
        const prop = self.ast.getNode(prop_idx);
        if (prop.tag != .binding_property) continue;

        const key_idx = prop.data.binary.left;
        const value_idx = prop.data.binary.right;
        if (key_idx.isNone() or value_idx.isNone()) continue;

        const key_node = self.ast.getNode(key_idx);
        if (!std.mem.eql(u8, self.ast.getText(key_node.span), "css")) continue;

        const value_node = self.ast.getNode(value_idx);
        if (value_node.tag != .binding_identifier) return null;
        return self.ast.getText(value_node.span);
    }
    return null;
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
        // scope frame 우선 — `<ClassNames>` render-prop 의 destructured `css` 는 outer
        // import binding 보다 우선해야 함 (정확히 그 함수 안에서만 유효).
        if (state.scope_stack.items.len > 0) {
            const top = state.scope_stack.items[state.scope_stack.items.len - 1];
            if (top.css_binding) |b| {
                if (std.mem.eql(u8, text, b)) return true;
            }
        }
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

/// template_literal 변환 — `label_text` 가 있으면 첫 quasi 에 prepend, `source_map_text` 가
/// 있으면 마지막 quasi 에 append. no-interp / interp 둘 다 처리.
/// 둘 다 null 이면 호출되지 않음 (caller 가 가드).
fn transformEmotionTemplate(
    self: *Transformer,
    template_idx: NodeIndex,
    label_text: ?[]const u8,
    source_map_text: ?[]const u8,
) Error!NodeIndex {
    const node = self.ast.getNode(template_idx);
    if (node.tag != .template_literal) return template_idx;

    if (node.data.none == 0) {
        return try transformNoInterpTemplate(self, template_idx, node, label_text, source_map_text);
    }
    return try transformInterpTemplate(self, template_idx, node, label_text, source_map_text);
}

/// no-interp: 단일 span (`\`text\``) — label 은 backtick 다음, sourceMap 은 closing
/// backtick 직전에 삽입.
fn transformNoInterpTemplate(
    self: *Transformer,
    template_idx: NodeIndex,
    node: ast_mod.Node,
    label_text: ?[]const u8,
    source_map_text: ?[]const u8,
) Error!NodeIndex {
    const raw = self.ast.getText(node.span);
    if (raw.len < 2 or raw[0] != '`' or raw[raw.len - 1] != '`') return template_idx;
    const inner = raw[1 .. raw.len - 1];

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.append(self.allocator, '`');
    if (label_text) |l| try writeLabelPrefix(self, &buf, l);
    try buf.appendSlice(self.allocator, inner);
    if (source_map_text) |sm| try buf.appendSlice(self.allocator, sm);
    try buf.append(self.allocator, '`');

    const new_span = try self.ast.addString(buf.items);
    return self.ast.addNode(.{
        .tag = .template_literal,
        .span = new_span,
        .data = .{ .list = .{ .start = 0, .len = 0 } },
    });
}

/// interp: children = [te0, expr0, te1, expr1, ..., teN]. label 은 te0 시작에,
/// sourceMap 은 teN (마지막 template_element) 끝에 삽입.
fn transformInterpTemplate(
    self: *Transformer,
    template_idx: NodeIndex,
    node: ast_mod.Node,
    label_text: ?[]const u8,
    source_map_text: ?[]const u8,
) Error!NodeIndex {
    const list = node.data.list;
    if (list.len == 0) return template_idx;
    const items = self.ast.extra_data.items[list.start .. list.start + list.len];

    const first_idx: NodeIndex = @enumFromInt(items[0]);
    const first_node = self.ast.getNode(first_idx);
    if (first_node.tag != .template_element) return template_idx;

    // 마지막 template_element 위치 (children 중 가장 큰 i where items[i].tag == template_element).
    var last_te_pos: usize = 0;
    for (items, 0..) |raw_idx, i| {
        const idx: NodeIndex = @enumFromInt(raw_idx);
        if (self.ast.getNode(idx).tag == .template_element) last_te_pos = i;
    }
    const last_idx: NodeIndex = @enumFromInt(items[last_te_pos]);

    // First element 재작성 — `\`text${` → `\`label:<name>;text${`
    var new_first: NodeIndex = first_idx;
    if (label_text) |l| {
        const raw = self.ast.getText(first_node.span);
        if (raw.len < 3 or raw[0] != '`') return template_idx;
        if (raw[raw.len - 2] != '$' or raw[raw.len - 1] != '{') return template_idx;
        const inner = raw[1 .. raw.len - 2];

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.append(self.allocator, '`');
        try writeLabelPrefix(self, &buf, l);
        try buf.appendSlice(self.allocator, inner);
        try buf.appendSlice(self.allocator, "${");

        const new_first_span = try self.ast.addString(buf.items);
        new_first = try self.ast.addNode(.{
            .tag = .template_element,
            .span = new_first_span,
            .data = .{ .none = 0 },
        });
    }

    // Last element 재작성 — `}text\`` → `}text<sourcemap>\``
    var new_last: NodeIndex = last_idx;
    if (source_map_text) |sm| {
        const last_node = self.ast.getNode(last_idx);
        const raw = self.ast.getText(last_node.span);
        if (raw.len < 2 or raw[raw.len - 1] != '`') return template_idx;
        if (raw[0] != '}') return template_idx;
        const inner = raw[1 .. raw.len - 1];

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.append(self.allocator, '}');
        try buf.appendSlice(self.allocator, inner);
        try buf.appendSlice(self.allocator, sm);
        try buf.append(self.allocator, '`');

        const new_last_span = try self.ast.addString(buf.items);
        new_last = try self.ast.addNode(.{
            .tag = .template_element,
            .span = new_last_span,
            .data = .{ .none = 0 },
        });
    }

    if (new_first == first_idx and new_last == last_idx) return template_idx;

    // children list 재구성 — first/last 만 교체.
    const top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(top);
    for (items, 0..) |raw_idx, i| {
        if (i == 0 and new_first != first_idx) {
            try self.scratch.append(self.allocator, new_first);
        } else if (i == last_te_pos and new_last != last_idx) {
            try self.scratch.append(self.allocator, new_last);
        } else {
            try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
        }
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[top..]);
    return self.ast.addNode(.{
        .tag = .template_literal,
        .span = node.span,
        .data = .{ .list = new_list },
    });
}

/// 현재 빌드에서 autoLabel 적용 여부. `.always` 즉시 true, `.never` 즉시 false,
/// `.dev_only` 는 `process.env.NODE_ENV` define 이 `"production"` 인지 확인 — 그러면
/// false (production build), 아니면 true (development build).
fn labelEnabledNow(self: *Transformer) bool {
    return switch (self.options.emotion_auto_label) {
        .never => false,
        .always => true,
        .dev_only => !defineMatchesProduction(self),
    };
}

/// `process.env.NODE_ENV` define entry 가 `"production"` 으로 설정됐는지.
/// value 는 JS 표현식 string (e.g. `"\"production\""` JSON-encoded). quote 제거 후 비교.
fn defineMatchesProduction(self: *Transformer) bool {
    for (self.options.define) |entry| {
        if (!std.mem.eql(u8, entry.key, "process.env.NODE_ENV")) continue;
        const v = entry.value;
        if (v.len < 2) return false;
        const first = v[0];
        const last = v[v.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return std.mem.eql(u8, v[1 .. v.len - 1], "production");
        }
        return false;
    }
    return false;
}

fn writeLabelPrefix(self: *Transformer, buf: *std.ArrayList(u8), var_name: []const u8) Error!void {
    try buf.appendSlice(self.allocator, "label:");
    try writeFormattedLabel(self, buf, var_name);
    try buf.append(self.allocator, ';');
}

/// labelFormat 기반 label 문자열을 buf 에 append.
///
/// 동작:
///   - var_name 자체 sanitize (invalid CSS char → `-`, trim)
///   - labelFormat 비어있으면 sanitized var_name 만 emit
///   - 토큰 치환 (case-insensitive): `[local]` / `[filename]` / `[dirname]`
///   - filename basename 이 `index` 면 parent dir 명으로 fallback
fn writeFormattedLabel(self: *Transformer, buf: *std.ArrayList(u8), var_name: []const u8) Error!void {
    const format = self.options.emotion_label_format;
    if (format.len == 0) {
        try writeSanitizedLabelPart(self.allocator, buf, var_name);
        return;
    }

    // filename / dirname 추출 — basename 이 `index` 면 dirname 으로 fallback.
    const filename_full = self.options.jsx_filename;
    const dirname_full = std.fs.path.dirname(filename_full) orelse "";
    const dirname_local = std.fs.path.basename(dirname_full);
    const basename_full = std.fs.path.basename(filename_full);
    const ext = std.fs.path.extension(basename_full);
    const basename_no_ext = basename_full[0 .. basename_full.len - ext.len];
    const filename_local = if (std.mem.eql(u8, basename_no_ext, "index")) dirname_local else basename_no_ext;

    // 토큰 치환: `[local]` / `[filename]` / `[dirname]` (case-insensitive).
    var i: usize = 0;
    while (i < format.len) {
        const remaining = format[i..];
        if (matchTokenIgnoreCase(remaining, "[local]")) |len| {
            try writeSanitizedLabelPart(self.allocator, buf, var_name);
            i += len;
        } else if (matchTokenIgnoreCase(remaining, "[filename]")) |len| {
            try writeSanitizedLabelPart(self.allocator, buf, filename_local);
            i += len;
        } else if (matchTokenIgnoreCase(remaining, "[dirname]")) |len| {
            try writeSanitizedLabelPart(self.allocator, buf, dirname_local);
            i += len;
        } else {
            try buf.append(self.allocator, format[i]);
            i += 1;
        }
    }
}

/// `s` 가 `token` 과 case-insensitive 로 시작하면 token.len 반환, 아니면 null.
fn matchTokenIgnoreCase(s: []const u8, token: []const u8) ?usize {
    if (s.len < token.len) return null;
    for (s[0..token.len], token) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return null;
    }
    return token.len;
}

/// label 의 한 부분을 sanitize 후 buf 에 append. invalid CSS class char
/// (`!"#$%&'()*+,./:;<=>?@[]^|}~{` + backtick + backslash) → `-`, 양 끝 공백 trim.
/// ASCII 문자만 대상 — non-ASCII (한글 등) 는 통과 (CSS class 로 유효).
fn writeSanitizedLabelPart(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), raw: []const u8) Error!void {
    const trimmed = std.mem.trim(u8, raw, " \t\n\r");
    for (trimmed) |c| {
        if (isInvalidCssClassChar(c)) {
            try buf.append(allocator, '-');
        } else {
            try buf.append(allocator, c);
        }
    }
}

fn isInvalidCssClassChar(c: u8) bool {
    return switch (c) {
        '!',
        '"',
        '#',
        '$',
        '%',
        '&',
        '\'',
        '(',
        ')',
        '*',
        '+',
        ',',
        '.',
        '/',
        ':',
        ';',
        '<',
        '=',
        '>',
        '?',
        '@',
        '[',
        '\\',
        ']',
        '^',
        '`',
        '|',
        '}',
        '~',
        '{',
        => true,
        else => false,
    };
}

// ─── sourceMap 생성 (babel-plugin-emotion source-maps.js 호환) ───
//
// 한 css template 마다 inline sourceMap 1개 매핑: `generated:{1,0} → source:{line, col}`.
// CSS 안에 `/*# sourceMappingURL=data:application/json;base64,... */` 주석으로 embed —
// emotion 런타임이 CSS 출력에 보존, DevTools 가 해석해 source 위치 점프 가능.

pub const LineCol = struct { line: u32, col: u32 };

/// 첫 sourceMap 호출 시 source 전체를 한 번 스캔해 newline 위치를 캐시. 이후 호출에서는
/// binary search 로 O(log n) lookup — 다수 emotion template 이 있는 파일에서 O(n²) 회피.
fn ensureNewlineCache(self: *Transformer) Error!void {
    if (self.plugins.emotion.newline_offsets != null) return;
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(self.allocator);
    for (self.ast.source, 0..) |c, i| {
        if (c == '\n') try list.append(self.allocator, @intCast(i));
    }
    self.plugins.emotion.newline_offsets = list;
}

/// 캐시된 newline offset 들로 byte offset → 0-indexed (line, col) — sourceMap VLQ 호환.
fn byteOffsetToLineColCached(self: *Transformer, offset: u32) LineCol {
    const offsets = if (self.plugins.emotion.newline_offsets) |list| list.items else return .{ .line = 0, .col = 0 };
    // first index where offsets[i] >= offset
    var lo: usize = 0;
    var hi: usize = offsets.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (offsets[mid] < offset) lo = mid + 1 else hi = mid;
    }
    const line: u32 = @intCast(lo);
    const col: u32 = if (lo == 0) offset else offset - offsets[lo - 1] - 1;
    return .{ .line = line, .col = col };
}

/// inline sourceMap 주석을 `buf` 에 빌드: `/*# sourceMappingURL=data:application/json;
/// charset=utf-8;base64,<b64> */` 형식.
fn buildSourceMapComment(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    source: []const u8,
    filename: []const u8,
    pos: LineCol,
) Error!void {
    // VLQ mappings — 단일 segment: gen_col=0, src_idx=0, src_line=pos.line, src_col=pos.col.
    var vlq_buf: std.ArrayList(u8) = .empty;
    defer vlq_buf.deinit(allocator);
    try sourcemap_mod.encodeVLQ(allocator, &vlq_buf, 0);
    try sourcemap_mod.encodeVLQ(allocator, &vlq_buf, 0);
    try sourcemap_mod.encodeVLQ(allocator, &vlq_buf, @intCast(pos.line));
    try sourcemap_mod.encodeVLQ(allocator, &vlq_buf, @intCast(pos.col));

    // JSON: {"version":3,"sources":["<filename>"],"sourcesContent":["<source>"],
    //        "mappings":"<vlq>","names":[]}
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.appendSlice(allocator, "{\"version\":3,\"sources\":[");
    try sourcemap_mod.appendJsonStringTo(allocator, &json, filename);
    try json.appendSlice(allocator, "],\"sourcesContent\":[");
    try sourcemap_mod.appendJsonStringTo(allocator, &json, source);
    try json.appendSlice(allocator, "],\"mappings\":\"");
    try json.appendSlice(allocator, vlq_buf.items);
    try json.appendSlice(allocator, "\",\"names\":[]}");

    // base64 encode JSON
    const enc = std.base64.standard.Encoder;
    const b64_len = enc.calcSize(json.items.len);
    const b64_buf = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64_buf);
    _ = enc.encode(b64_buf, json.items);

    try buf.appendSlice(allocator, "/*# sourceMappingURL=data:application/json;charset=utf-8;base64,");
    try buf.appendSlice(allocator, b64_buf);
    try buf.appendSlice(allocator, " */");
}
