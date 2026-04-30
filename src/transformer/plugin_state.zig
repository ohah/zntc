//! 플러그인별 runtime state를 모아두는 컨테이너.
//!
//! Transformer core에 산재하던 plugin-specific 필드를 이곳으로 이사하여,
//! core는 ES spec 변환에, plugin은 자기 state에 집중할 수 있게 한다.
//!
//! ## 접근 규칙 (docs/DECISIONS.md)
//! 1. 각 plugin은 **자기 sub-struct만** 접근. cross-plugin 접근 금지.
//!    예: refresh plugin이 `plugins.worklet.*`를 읽으면 안 됨.
//! 2. Core는 명명된 hook point 함수(예: `visitBodyWorkletAware`, `dispatchFunctionPlugins`)
//!    를 통해서만 plugin 상태에 접근.
//! 이 규칙을 지키면 추후 visitor-hook 아키텍처로 전환 시 비용이 저렴하다.

const std = @import("std");
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;
const ast_mod = @import("../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;

pub const WorkletState = struct {
    /// auto-workletization 플래그.
    /// visitCallExpression에서 callee 매칭 시 true로 설정하고,
    /// dispatchFunctionPlugins에서 FunctionInfo.is_auto_worklet로 전달 후 false로 리셋.
    auto_next: bool = false,

    /// 익명 worklet 함수 이름 생성 시 사용하는 sequential counter (Babel `null<N>` 호환).
    anonymous_counter: u32 = 0,

    /// worklet 함수 body 방문 중 깊이. > 0 이면 define 치환(`--define:global=...`) 억제.
    /// worklet body는 UI 런타임에서 실행되므로 JS 전용 global polyfill 심볼로 치환하면 안 된다.
    body_depth: u32 = 0,

    /// `__pluginVersion`에 주입할 따옴표로 감싼 문자열 리터럴 span (pre-computed).
    /// worklet당 매번 allocPrint하는 오버헤드 제거 — init에서 한 번만 생성.
    plugin_version_span: ?Span = null,
};

pub const RefreshRegistration = struct {
    /// _c / _c2 핸들 변수의 string_table Span (재사용)
    handle_span: Span,
    /// 컴포넌트 이름 (문자열)
    name: []const u8,
};

pub const RefreshSignature = struct {
    /// _s / _s2 핸들 변수의 string_table Span
    handle_span: Span,
    /// 컴포넌트 이름 (문자열)
    component_name: []const u8,
    /// Hook 시그니처 문자열 ("useState{[foo, setFoo](0)}\nuseEffect{}")
    signature: []const u8,
};

pub const RefreshState = struct {
    /// 감지된 컴포넌트 등록 목록.
    /// transform 완료 후 프로그램 끝에 $RefreshReg$ 호출로 주입.
    registrations: std.ArrayList(RefreshRegistration) = .empty,

    /// Hook 시그니처 등록 목록.
    /// 프로그램 끝에 var _s = $RefreshSig$(); + _s(Component, "sig") 호출로 주입.
    signatures: std.ArrayList(RefreshSignature) = .empty,

    /// 등록 억제 플래그. 중첩 function_declaration이 컴포넌트로 오인되어
    /// `_cN = <name>` ReferenceError 유발하는 것을 방지.
    ///
    /// 외부에서 직접 세팅하지 말고 core의 `visitWithRefreshSuppressed` scope API를 사용할 것.
    suppress_registration: bool = false,
};

pub const EmotionState = struct {
    /// `import { css } from "@emotion/react"` 의 local binding 이름 (alias 포함).
    css_binding: ?[]const u8 = null,

    /// `import styled from "@emotion/styled"` 의 default binding 이름 (alias 포함).
    styled_binding: ?[]const u8 = null,

    /// `import { keyframes } from "@emotion/react"` 의 local binding 이름 (alias 포함).
    /// `keyframes\`...\`` 도 첫 quasi 에 label prepend — emotion 런타임이 animation name
    /// 으로 사용.
    keyframes_binding: ?[]const u8 = null,

    /// `import { injectGlobal } from "@emotion/css"` 의 local binding 이름 (alias 포함).
    /// `const X = injectGlobal\`...\`` 형태에서 첫 quasi 에 `label:X;` prepend.
    /// 일반적으로 side-effect call 로 쓰이지만 binding 형태도 유효한 사용 패턴.
    inject_global_binding: ?[]const u8 = null,

    /// `import { Global } from "@emotion/react"` 의 local binding 이름 (alias 포함).
    /// `<Global styles={css\`...\`} />` JSX element 의 `styles` attr 에 element 이름
    /// 기반 label prepend (`label:Global;`).
    global_binding: ?[]const u8 = null,

    /// `import { ClassNames } from "@emotion/react"` 의 local binding 이름 (alias 포함).
    /// `<ClassNames>{({css}) => ...}</ClassNames>` render-prop 패턴 인식에 사용.
    class_names_binding: ?[]const u8 = null,

    /// `<ClassNames>` render-prop 진입 시 push, exit 시 pop 되는 scope frame stack.
    /// 현재 frame 의 binding 들이 outer (import 기반) binding 보다 우선 적용 →
    /// destructured local 이름 (`{ css: cs }` 의 `cs`) 도 emotion css 로 인식.
    scope_stack: std.ArrayList(EmotionScopeFrame) = .empty,

    /// sourceMap 활성 시 byte offset → (line, col) 변환을 위한 캐시. 각 entry 가
    /// `\n` 의 byte offset. lazy-build (첫 sourceMap 호출 시 source 전체 스캔), 이후
    /// binary search 로 O(log n) per template — 다수 emotion template 이 있는 파일에서
    /// 전체 source re-scan 회피.
    newline_offsets: ?std.ArrayList(u32) = null,
};

/// `<ClassNames>` render-prop 함수 매개변수에서 destructure 된 local binding 이름들.
/// css 만 추적 — `cx`/`theme` 는 autoLabel 에 무관.
pub const EmotionScopeFrame = struct {
    css_binding: ?[]const u8 = null,
};

pub const StyledComponentsState = struct {
    /// `import styled from "styled-components"` 의 default binding 로컬 이름.
    /// alias 가 있으면 그 이름 (예: `import s from "styled-components"` → "s").
    /// import 가 없으면 null — 이후 모든 wrap 이 no-op.
    default_binding: ?[]const u8 = null,

    /// `import { css } from "styled-components"` named import 의 local binding 이름.
    /// minify 적용에 사용 (`styled.X` 처럼 displayName/componentId 는 부여 안 함 —
    /// helper 는 컴포넌트 아닌 CSS 조각 빌더).
    css_binding: ?[]const u8 = null,
    /// `import { keyframes } from "styled-components"` named import.
    keyframes_binding: ?[]const u8 = null,
    /// `import { createGlobalStyle } from "styled-components"` named import.
    create_global_style_binding: ?[]const u8 = null,
    /// `import { injectGlobal } from "styled-components"` named import.
    inject_global_binding: ?[]const u8 = null,

    /// `.withConfig({...})` 래핑 시 매 컴포넌트마다 동일 문자열을 string_table 에 추가하는
    /// 비용을 피하기 위한 lazy 캐시. 첫 wrap 시점에 채워짐.
    with_config_span: ?Span = null,
    display_name_span: ?Span = null,
    component_id_span: ?Span = null,

    /// componentId hash 의 file 부분 — `options.jsx_filename` 의 wyhash 32-bit truncated 8-hex.
    /// SSR hydration 안정화: 같은 파일에서 같은 hash 보장 (counter 와 결합).
    /// 32-bit truncation 은 일반 monorepo (수만 파일) 에서도 collision 무시 가능.
    file_hash_hex: ?[8]u8 = null,

    /// fileName 옵션 활성 시 displayName 의 prefix 부분 캐시 — `<basename>__`. 첫 wrap
    /// 호출 시점에 채워짐. basename 이 `index` 면 parent dir 명으로 fallback.
    /// `options.jsx_filename` 가 비어있거나 fileName 옵션 비활성이면 null.
    display_name_block: ?[]const u8 = null,

    /// componentId 의 0-based counter — 같은 파일 내 styled 컴포넌트 등장 순서.
    /// SWC 의 next_id 와 동일 (sc-<file_hash>-<counter>).
    /// **Invariant**: Transformer 가 파일당 새로 생성된다는 가정에 의존 — 재사용 금지.
    /// 주의: 컴포넌트 추가/순서 변경 시 이후 ID 가 모두 shift → partial-deploy SSR
    /// mismatch 가능. Babel 의 name-based hash 와 trade-off (SWC fixture 호환 우선).
    component_counter: u32 = 0,

    /// cssProp transform 으로 추출된 styled component 의 0-based counter — generated
    /// identifier (`_styled_<n>`) 의 unique suffix. 파일별 reset.
    css_prop_counter: u32 = 0,

    /// cssProp transform 시 사용자 코드에 `import styled from "styled-components"` 가
    /// 없어 transpile.zig 가 자동 prepend 해야 함. JSX import auto-inject 패턴과 동일.
    css_prop_needs_import: bool = false,

    /// auto-inject 된 styled binding 의 실제 이름. collision 시 `_styled`, `_styled2`,
    /// ... 로 mangled. transpile.zig 의 prepend 도 같은 이름 사용. default `"styled"`.
    css_prop_inject_name: []const u8 = "styled",

    /// `css_prop_inject_name` 이 heap-owned 인지 (mangling 발생 시 true). deinit 시
    /// pointer 비교 대신 이 flag 보고 free 결정 — Zig 의 string-literal pooling 은
    /// 컴파일러 implementation-defined 이라 ptr 비교 fragile.
    css_prop_inject_name_owned: bool = false,

    /// cssProp transform 으로 만들어진 module-level decl 들 — program body 끝에 hoist.
    /// `trailing_nodes` 는 nearest list 가 program 이 아니면 declarator list 같은
    /// 부적절한 위치에 들어가 invalid syntax 가 되므로 별도 list 로 관리. visitProgram
    /// 에서 drain.
    css_prop_pending_decls: std.ArrayList(NodeIndex) = .empty,
};

pub const PluginState = struct {
    worklet: WorkletState = .{},
    refresh: RefreshState = .{},
    styled_components: StyledComponentsState = .{},
    emotion: EmotionState = .{},
};
