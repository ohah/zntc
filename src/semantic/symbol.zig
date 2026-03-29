//! ZTS Semantic — 심볼 정의
//!
//! 비트플래그 기반 심볼 모델 (oxc 참고).
//! SymbolKind는 enum으로 선언 종류를 표현하고,
//! SymbolFlags는 packed struct로 선언 속성을 비트플래그로 표현한다.
//! 재선언 규칙은 excludes 비트마스크로 O(1) 판단.
//!
//! Reference(참조 추적)는 tree-shaking/번들러에서 활용:
//!   - reference_count == 0 → 미사용 심볼 (tree-shaking 대상)
//!   - ReferenceKind로 read/write 구분 (dead store 분석용)

const std = @import("std");
const ScopeId = @import("scope.zig").ScopeId;
const Span = @import("../lexer/token.zig").Span;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;

/// 심볼 인덱스. symbols 배열의 위치를 가리킨다.
pub const SymbolId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: SymbolId) bool {
        return self == .none;
    }
};

/// 심볼 종류. 재선언 규칙이 kind별로 다르다.
///
/// 재선언 규칙 요약:
///   var + var       → 허용 (같은 스코프에서도 가능)
///   var + function  → 허용 (함수 선언이 우선)
///   let + let       → 에러
///   let + const     → 에러
///   const + const   → 에러
///   var + let/const → 에러
///   function + let  → 에러
///   import + *      → 항상 에러
pub const SymbolKind = enum(u8) {
    /// var 선언 — 함수 스코프로 호이스팅, 재선언 허용
    variable_var,
    /// let 선언 — 블록 스코프, 재선언 불가
    variable_let,
    /// const 선언 — 블록 스코프, 재선언 불가, 재할당 불가
    variable_const,
    /// function 선언 — 함수 스코프로 호이스팅, 재선언 조건부 허용
    function_decl,
    /// generator function 선언 (function*) — 블록 스코프에서 lexical
    generator_decl,
    /// async function 선언 — 블록 스코프에서 lexical
    async_function_decl,
    /// async generator function 선언 (async function*) — 블록 스코프에서 lexical
    async_generator_decl,
    /// class 선언 — 블록 스코프, 재선언 불가
    class_decl,
    /// 함수 파라미터
    parameter,
    /// catch(e)의 e
    catch_binding,
    /// import { x }의 x — 재선언 불가, 재할당 불가
    import_binding,

    /// 이 kind의 선언 속성을 DeclFlags로 변환한다.
    pub fn declFlags(self: SymbolKind) DeclFlags {
        return switch (self) {
            .variable_var => DeclFlags.FUNCTION_SCOPED,
            .variable_let => DeclFlags.BLOCK_SCOPED,
            .variable_const => .{ .block_scoped = true, .is_const = true },
            .function_decl => .{ .function_scoped = true, .is_function = true },
            .generator_decl => .{ .block_scoped = true, .is_function = true, .is_generator = true },
            .async_function_decl => .{ .block_scoped = true, .is_function = true, .is_async = true },
            .async_generator_decl => .{ .block_scoped = true, .is_function = true, .is_generator = true, .is_async = true },
            .class_decl => .{ .block_scoped = true, .is_class = true },
            .parameter => DeclFlags.PARAMETER,
            .catch_binding => DeclFlags.CATCH_BINDING,
            .import_binding => DeclFlags.IMPORT,
        };
    }

    /// 블록 스코프 선언인지 (let/const/class/generator/async function/async generator)
    pub fn isBlockScoped(self: SymbolKind) bool {
        return self.declFlags().block_scoped;
    }

    /// 같은 스코프에서 재선언 가능한지 (var, function만)
    pub fn allowsRedeclaration(self: SymbolKind) bool {
        const f = self.declFlags();
        return f.function_scoped and !f.block_scoped;
    }

    /// function-like 선언인지 (function, generator, async function, async generator)
    pub fn isFunctionLike(self: SymbolKind) bool {
        return self.declFlags().is_function;
    }
};

/// 선언 속성 비트플래그 (oxc의 SymbolFlags 참고).
///
/// 재선언 충돌은 `existing.intersects(new.excludes())` 로 O(1) 판단:
/// - excludes()는 이 선언과 공존할 수 없는 플래그 마스크를 반환
/// - 기존 심볼의 flags가 그 마스크와 겹치면 재선언 에러
pub const DeclFlags = packed struct(u16) {
    /// var — 함수 스코프로 호이스팅
    function_scoped: bool = false,
    /// let/const/class — 블록 스코프
    block_scoped: bool = false,
    /// function/generator/async function
    is_function: bool = false,
    /// generator (function*)
    is_generator: bool = false,
    /// async function
    is_async: bool = false,
    /// class
    is_class: bool = false,
    /// const (immutable)
    is_const: bool = false,
    /// parameter
    is_parameter: bool = false,
    /// catch(e)
    is_catch_binding: bool = false,
    /// import binding
    is_import: bool = false,
    /// export된 심볼
    is_exported: bool = false,
    /// export default
    is_default_export: bool = false,
    /// @__NO_SIDE_EFFECTS__ 어노테이션 — 이 함수의 모든 호출이 pure
    no_side_effects: bool = false,
    /// Annex B: if/else body의 function declaration (sloppy mode).
    /// catch body에서 catch parameter와의 충돌 검사를 건너뛰기 위해 필요.
    is_annex_b_function: bool = false,
    /// 나머지 패딩
    _padding: u2 = 0,

    /// 모든 "값(value)" 비트. 재선언 체크에 사용할 전체 마스크.
    pub const all_values: DeclFlags = .{
        .function_scoped = true,
        .block_scoped = true,
        .is_function = true,
        .is_generator = true,
        .is_async = true,
        .is_class = true,
        .is_const = true,
        .is_parameter = true,
        .is_catch_binding = true,
        .is_import = true,
    };

    /// 편의 상수 — 단일 비트 마스크
    pub const FUNCTION_SCOPED: DeclFlags = .{ .function_scoped = true };
    pub const BLOCK_SCOPED: DeclFlags = .{ .block_scoped = true };
    pub const FUNCTION: DeclFlags = .{ .is_function = true };
    pub const PARAMETER: DeclFlags = .{ .is_parameter = true };
    pub const CATCH_BINDING: DeclFlags = .{ .is_catch_binding = true };
    pub const IMPORT: DeclFlags = .{ .is_import = true };

    /// u16 비트 연산용 변환
    pub fn toInt(self: DeclFlags) u16 {
        return @bitCast(self);
    }

    pub fn fromInt(val: u16) DeclFlags {
        return @bitCast(val);
    }

    /// 두 플래그가 겹치는 비트가 있는지 (비트 AND != 0)
    pub fn intersects(self: DeclFlags, other: DeclFlags) bool {
        return (self.toInt() & other.toInt()) != 0;
    }

    // 자주 사용하는 마스크 상수 (excludes 계산용)
    const fn_scoped_or_function = fromInt(FUNCTION_SCOPED.toInt() | FUNCTION.toInt());
    const fn_scoped_or_function_or_param = fromInt(fn_scoped_or_function.toInt() | PARAMETER.toInt());

    /// 이 선언과 공존할 수 없는 플래그 마스크를 반환한다 (oxc의 excludes 패턴).
    /// 새 선언의 excludes()와 기존 심볼의 declFlags()를 intersects하면 충돌 판단.
    pub fn excludes(self: DeclFlags) DeclFlags {
        // var/function: 다른 var/function/parameter와 공존 가능, 나머지(let/const/class 등)와 충돌
        if (self.function_scoped and !self.block_scoped) {
            return fromInt(all_values.toInt() & ~fn_scoped_or_function_or_param.toInt());
        }
        // import: 모든 것과 충돌
        if (self.is_import) return all_values;
        // parameter: 다른 parameter와는 공존 가능 (non-strict), var/function과도 공존
        if (self.is_parameter) {
            return fromInt(all_values.toInt() & ~fn_scoped_or_function_or_param.toInt());
        }
        // catch binding: var와는 공존 가능
        if (self.is_catch_binding) {
            return fromInt(all_values.toInt() & ~FUNCTION_SCOPED.toInt());
        }
        // let/const/class/block-scoped function: 모든 것과 충돌
        return all_values;
    }
};

/// 컴파일 타임 상수 값. 번들러에서 크로스-모듈 인라인에 사용.
/// `const x = false` → ConstValue{ .kind = .false_ }
pub const ConstValue = struct {
    kind: Kind = .none,

    pub const Kind = enum(u8) {
        none,
        true_,
        false_,
        null_,
        undefined_,
    };

    pub fn isSafeToInline(self: *const ConstValue) bool {
        return self.kind != .none;
    }
};

/// 심볼 하나의 데이터.
/// symbols[symbol_id]로 접근.
pub const Symbol = struct {
    /// 심볼 이름 — 소스 코드의 byte offset 범위 (zero-copy)
    name: Span,

    /// 심볼이 등록된 스코프 (var는 호이스팅된 var scope)
    scope_id: ScopeId,

    /// 원래 선언이 작성된 스코프 (var는 호이스팅 전 block scope).
    /// let/const/class 선언 시 같은 block의 var를 찾는 데 사용.
    /// var가 아닌 경우 scope_id와 동일.
    origin_scope: ScopeId = ScopeId.none,

    /// 선언 종류
    kind: SymbolKind,

    /// 선언 속성 비트플래그 (kind에서 파생 + export 등 추가 속성)
    decl_flags: DeclFlags = .{},

    /// 선언 위치 (에러 메시지에서 "여기서 먼저 선언됨" 출력용)
    declaration_span: Span,

    /// 이 심볼이 참조된 횟수 (tree-shaking: 0이면 미사용 심볼).
    /// read/write/read_write 모두 카운트에 포함.
    reference_count: u32 = 0,

    /// 컴파일 타임 상수 값 (번들러 크로스-모듈 인라인용).
    /// const/let 선언의 초기화 값이 리터럴이면 설정.
    const_value: ConstValue = .{},

    /// 이 심볼의 이름을 소스에서 읽는다.
    pub fn nameText(self: *const Symbol, source: []const u8) []const u8 {
        return source[self.name.start..self.name.end];
    }
};

/// 참조 발생 시 (심볼 인덱스, 참조 스코프) 쌍.
/// mangler의 liveness BitSet 계산에 사용: 심볼이 어느 스코프에서 참조되는지 추적.
/// analyzer.resolveIdentifier에서 수집, mangler.mangleLiveness에서 소비.
pub const RefScopePair = struct {
    symbol_idx: u32,
    scope_id: ScopeId,
};

/// 참조 하나의 데이터.
/// 식별자가 어떤 심볼을 참조하는지, read/write인지 기록한다.
/// 번들러의 tree-shaking과 미니파이어의 dead store 분석에 사용.
pub const Reference = struct {
    /// 참조하는 AST 노드의 인덱스
    node_index: NodeIndex,
    /// 참조가 발생한 스코프
    scope_id: ScopeId,
    /// 참조 대상 심볼의 인덱스
    symbol_id: SymbolId,
    /// 참조 종류 (read/write/read_write)
    kind: ReferenceKind,
};

/// 참조 종류. 식별자가 읽기/쓰기/둘 다인지 구분.
///
/// - read:       `f(x)`, `y = x`에서의 x
/// - write:      `x = 1`에서의 x
/// - read_write: `x += 1`, `x++`에서의 x
pub const ReferenceKind = enum(u2) {
    read,
    write,
    read_write,
};
