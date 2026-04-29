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
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;
const StyledComponentRegistration = @import("../plugin_state.zig").StyledComponentRegistration;

/// styled-components import source 문자열 (정확 매치). v6+ 는 "/native" subpath 도 인정.
pub const STYLED_SOURCES: []const []const u8 = &.{
    "styled-components",
    "styled-components/native",
};

/// import source 가 styled-components 인지 확인.
pub fn isStyledImportSource(source: []const u8) bool {
    for (STYLED_SOURCES) |s| {
        if (std.mem.eql(u8, s, source)) return true;
    }
    return false;
}
