//! 플러그인별 runtime state를 모아두는 컨테이너.
//!
//! Transformer core에 산재하던 plugin-specific 필드를 이곳으로 이사하여,
//! core는 ES spec 변환에, plugin은 자기 state에 집중할 수 있게 한다.
//!
//! ## 접근 규칙 (DECISIONS.md)
//! 1. 각 plugin은 **자기 sub-struct만** 접근. cross-plugin 접근 금지.
//!    예: refresh plugin이 `plugins.worklet.*`를 읽으면 안 됨.
//! 2. Core는 명명된 hook point 함수(예: `visitBodyWorkletAware`, `dispatchFunctionPlugins`)
//!    를 통해서만 plugin 상태에 접근.
//! 이 규칙을 지키면 추후 visitor-hook 아키텍처로 전환 시 비용이 저렴하다.

const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

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

pub const PluginState = struct {
    worklet: WorkletState = .{},
};
