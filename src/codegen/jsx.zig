//! JSX 구조적 출력 (`--jsx=preserve`).
//!
//! preserve 모드는 JSX 를 변환하지 않고 그대로 내보내 downstream tool 에 위임한다.
//! 예전엔 그 "그대로" 를 **소스 span 통째 복사**(`writeNodeSpan`)로 구현했는데,
//! 그러면 JSX 안에서만 AST 변형이 통째로 무시된다 (#4470):
//!
//!   - 번들 deconflict rename: `import { Widget as A } from './a'` 는 scope hoisting
//!     후 `Widget` / `Widget$1` 이 되는데, `<A.Panel/>` 은 `A` 를 그대로 들고 있었다.
//!     번들에 `A` 선언이 없으므로 downstream 변환 결과는 `ReferenceError: A is not defined`.
//!   - TypeScript strip: `<Foo prop={v as T}>` 의 `as T` 가 남아 JS 로 파싱 불가.
//!   - `--define` 치환: `<Foo x={__MODE__}>` 가 그대로 남음.
//!
//! 그래서 AST 로 출력한다. 식별자는 일반 identifier 경로를 타므로 rename/const-inline
//! 이 그대로 적용되고, expression container 안은 평범한 표현식 emit 이라 TS strip /
//! define / minify 가 모두 정상 동작한다.
//!
//! 이름 위치별 취급:
//!   - **태그 이름** (`<Foo>`, `<Foo.Bar>`) → 식별자 경로 (rename 적용).
//!     semantic analyzer 가 대문자 태그와 member 루트만 심볼로 해석한다
//!     (`<div>` 같은 intrinsic 은 심볼이 없어 원문 그대로).
//!   - **속성 이름** (`className`) → 항상 원문. analyzer 가 jsx_attribute 의
//!     value(right) 만 방문하고 name(left) 은 방문하지 않으므로 심볼이 붙을 수 없다.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;

/// `<tag attrs>children</tag>` 또는 children 이 없으면 `<tag attrs />`.
///
/// extra: [tag_name, attrs_start, attrs_len, children_start, children_len].
/// 파서는 self-closing 도 children_len = 0 으로 통일하므로 둘을 구분할 수 없다 —
/// children 이 없으면 self-closing 으로 낸다 (JSX 에서 `<div></div>` 와 `<div/>` 는
/// 동치).
pub fn emitJsxElement(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const e = node.data.extra;
    if (!self.ast.hasExtra(e, 4)) return;

    const tag_name = self.ast.readExtraNode(e, 0);
    const attrs_start = self.ast.readExtra(e, 1);
    const attrs_len = self.ast.readExtra(e, 2);
    const children_start = self.ast.readExtra(e, 3);
    const children_len = self.ast.readExtra(e, 4);

    try self.writeByte('<');
    try self.emitNode(tag_name);
    try emitJsxAttrs(self, attrs_start, attrs_len);

    if (children_len == 0) {
        try self.write("/>");
        return;
    }

    try self.writeByte('>');
    try emitJsxChildren(self, children_start, children_len);
    try self.write("</");
    try self.emitNode(tag_name);
    try self.writeByte('>');
}

/// `<>children</>`
pub fn emitJsxFragment(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("<>");
    const list = node.data.list;
    try emitJsxChildren(self, list.start, list.len);
    try self.write("</>");
}

fn emitJsxAttrs(self: anytype, start: u32, len: u32) !void {
    if (len == 0) return;
    const items = self.ast.extra_data.items[start .. start + len];
    for (items) |raw| {
        const idx: NodeIndex = @enumFromInt(raw);
        if (idx.isNone()) continue;
        try self.writeByte(' ');
        try self.emitNode(idx);
    }
}

fn emitJsxChildren(self: anytype, start: u32, len: u32) !void {
    if (len == 0) return;
    const items = self.ast.extra_data.items[start .. start + len];
    for (items) |raw| {
        const idx: NodeIndex = @enumFromInt(raw);
        if (idx.isNone()) continue;
        try self.emitNode(idx);
    }
}

/// `name`, `name="v"`, `name={expr}` — binary: { left = name, right = value }.
/// value 가 none 이면 boolean shorthand (`<input disabled />`).
///
/// **중괄호는 codegen 이 다시 만든다.** 파서는 `name={expr}` 의 `{}` 를 소비해 버리고
/// value 슬롯에 raw expression 만 남긴다 (parser/jsx.zig 의 parseJSXAttribute). 그래서
/// 값이 string_literal 이 아니면 반드시 `{}` 로 감싸야 한다 — 안 그러면 `a={1}` 이
/// `a=1` 로 나가 JSX 문법이 깨진다.
///
/// **name 은 원문 그대로** 낸다. 식별자 경로를 태우면 `<div Foo="x">` 처럼 대문자
/// 속성이 우연히 같은 이름의 변수와 엮여 rename 될 위험이 있다. analyzer 가 name 을
/// 방문하지 않아 실제로 심볼이 붙진 않지만, 의도를 코드로 못박아 둔다.
pub fn emitJsxAttribute(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const b = node.data.binary;
    const name = self.ast.getNode(b.left);
    try self.writeIdentifierSpan(name.data.string_ref);
    if (b.right.isNone()) return;

    try self.writeByte('=');
    const value = self.ast.getNode(b.right);

    // **원본 소스의** string literal 만 raw span 으로 낸다 (`id="lit"`).
    // JSX attribute string 은 JS string 과 escaping 규칙이 다르다 — backslash escape 가
    // 없고 HTML entity 를 쓴다. 그래서 quote 정규화를 걸면 안 되고 원문을 보존해야 한다.
    //
    // 반대로 **합성된** string literal (`--define:__MODE__='"a\"b"'` 치환 결과 등) 을
    // 그 경로로 내보내면 `d="a\"b"` 가 되는데, JSX 는 그 백슬래시를 escape 로 읽지 않아
    // 문자열이 `a\` 에서 끊긴다. 이런 값은 `{}` 로 감싸 **JS 표현식**으로 넘긴다.
    //
    // 판별: 합성 노드의 string_ref 는 string table 을 가리키며 STRING_TABLE_BIT 가 켜져
    // 있다. 원본 소스 노드는 source span 이라 이 비트가 없다.
    const is_source_string = value.tag == .string_literal and
        (value.data.string_ref.start & ast_mod.Ast.STRING_TABLE_BIT) == 0;
    if (is_source_string) {
        try self.writeNodeSpan(value);
        return;
    }

    try self.writeByte('{');
    try self.emitExpr(b.right, .lowest, .{});
    try self.writeByte('}');
}

/// `{...expr}` — attribute 자리와 child 자리 양쪽에서 같은 형태.
pub fn emitJsxSpread(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write("{...");
    try self.emitExpr(node.data.unary.operand, .lowest, .{});
    try self.writeByte('}');
}

/// `{expr}` — operand 가 none 이면 `{}` (빈 컨테이너 / 주석만 있는 경우).
///
/// 여기가 preserve 모드에서 TS strip / define 치환 / rename 이 살아나는 지점이다 —
/// 평범한 표현식 emit 을 타므로 다른 코드와 완전히 동일하게 처리된다.
pub fn emitJsxExpressionContainer(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const operand = node.data.unary.operand;
    if (operand.isNone()) {
        try self.write("{}");
        return;
    }
    const inner = self.ast.getNode(operand);
    if (inner.tag == .jsx_empty_expression) {
        try self.write("{}");
        return;
    }
    try self.writeByte('{');
    try self.emitExpr(operand, .lowest, .{});
    try self.writeByte('}');
}

/// JSX text child — 공백/줄바꿈이 의미를 가지므로 원문 그대로.
pub fn emitJsxText(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    try self.write(self.ast.getText(node.data.string_ref));
}

/// `A.B` / `A.B.C` — binary: { left = jsx_identifier | jsx_member_expression, right = jsx_identifier }.
///
/// **루트 식별자만** 심볼을 가진다 (analyzer 가 member 루트를 resolve). 즉 `A` 는
/// rename 을 따라가고 `.B` / `.C` 는 프로퍼티라 원문 그대로다 — emitNode 가 각
/// 노드의 symbol_id 유무로 알아서 갈라진다.
pub fn emitJsxMemberExpression(self: anytype, node: Node) !void {
    try self.addSourceMapping(node.span);
    const b = node.data.binary;
    try self.emitNode(b.left);
    try self.writeByte('.');
    // 프로퍼티 이름 — 심볼 조회 없이 원문.
    const right = self.ast.getNode(b.right);
    try self.writeIdentifierSpan(right.data.string_ref);
}
