//! ZTS Semantic — 심볼 정의
//!
//! 비트플래그 기반 심볼 모델 (oxc 참고).
//! SymbolKind는 enum으로 선언 종류를 표현하고,
//! SymbolFlags는 packed struct로 선언 속성을 비트플래그로 표현한다.
//! 재선언 규칙은 excludes 비트마스크로 O(1) 판단.
//!
//! Reference(참조 추적)는 tree-shaking/번들러에서 활용:
//!   - reference_count == 0 → 미사용 심볼 (tree-shaking 대상)
//!   - ReferenceFlags(packed bitset)로 read/write 구분 (dead store 분석용)

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
    /// export 된 top-level 심볼. `analyzer.visitExportNamedDeclaration` /
    /// `visitExportDefaultDeclaration` 에서 세팅. `mangler.shouldSkip` 이 단일 파일 transpile
    /// 에서 이름 보존 근거로 소비. 번들러는 `Module.export_bindings` 로 entry-boundary 를 별도 관리.
    is_exported: bool = false,
    /// `export default` 대상. `is_exported` 와 함께 세팅됨.
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

/// Bundler가 생성한 합성 심볼 종류. #1328 Phase 4e-2.
/// 선언 소스가 AST에 없는 심볼 — linker가 cross-module 연결용으로 추가.
/// `re_export_alias`는 값 의미가 없어 semantic 공간에 얹지 않으며 bundler
/// 전용 `AliasTable`에 남는다 (RFC #1338 결정).
pub const SyntheticKind = enum(u8) {
    /// `export default ...` 합성 변수 (`_default`, `_default$N`)
    default_export,
    /// CJS 래퍼의 `exports_<module>` 객체
    cjs_exports,
    /// ESM 래퍼의 `init_<module>` 함수
    esm_init,
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

    /// 이 심볼이 write로 참조된 횟수. `x = ...`, `x += ...`, `x++` 등 LHS 등장 수.
    /// `let` const promotion 결정용 — 0이면 초기값 이후 재할당 없는 "사실상 const"로 간주하여
    /// 크로스-모듈 인라인 대상. oxc/rolldown과 동일한 접근.
    write_count: u32 = 0,

    /// 컴파일 타임 상수 값 (번들러 크로스-모듈 인라인용).
    /// const/let 선언의 초기화 값이 리터럴이면 설정 (단 let은 `write_count == 0`일 때만 인라인).
    const_value: ConstValue = .{},

    /// Bundler가 추가한 합성 심볼 종류. null = AST 선언에서 온 정규 심볼.
    /// #1328 Phase 4e-2: `extendSymbol`로 추가된 심볼만 non-null.
    synthetic_kind: ?SyntheticKind = null,

    /// 합성 심볼의 이름 (소스 span이 없으므로 직접 저장). 정규 심볼은 빈 문자열.
    /// #1338 Phase 4e-2c: HashMap 사이드카 대체 — ArrayList 수명과 일치시켜
    /// incremental rebuild 시 arena 불일치 방지.
    synthetic_name: []const u8 = "",

    /// 번들러 linker/mangler가 주입한 canonical (rename된) 이름. 빈 문자열 =
    /// 미지정 (원본 이름 유지). 소유권은 linker (`canonical_strings` ArrayList)
    /// — Symbol은 non-owning slice만 보유. linker가 살아있는 동안만 유효.
    canonical_name: []const u8 = "",

    /// 이 심볼의 이름을 반환. 합성은 `synthetic_name`, 정규는 source Span에서.
    pub fn nameText(self: *const Symbol, source: []const u8) []const u8 {
        if (self.synthetic_name.len > 0) return self.synthetic_name;
        return source[self.name.start..self.name.end];
    }

    pub fn isSynthetic(self: *const Symbol) bool {
        return self.synthetic_kind != null;
    }

    /// Linker가 canonical_name을 주입했는지 여부. 빈 문자열 = 미지정.
    pub fn hasCanonicalName(self: *const Symbol) bool {
        return self.canonical_name.len > 0;
    }
};

/// Bundler가 post-semantic 단계에서 합성 심볼을 semantic 공간에 추가한다.
/// #1328 Phase 4e-2 / RFC #1338.
///
/// `list`는 `ModuleSemanticData.symbols`의 ArrayList이어야 하고,
/// `allocator`는 해당 모듈의 `parse_arena`여야 한다.
///
/// 합성 심볼은 소스 범위의 name span이 없으므로 `Symbol.name`은 빈 Span,
/// 실제 이름은 `Symbol.synthetic_name` 필드에 직접 저장한다 (ArrayList 수명
/// 과 일치 — incremental rebuild 시 HashMap 수명 문제 회피).
///
/// 반환된 SymbolId로 `SymbolRef { .semantic = { module, id } }` 구성 가능.
pub fn extendSymbol(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Symbol),
    kind: SymbolKind,
    synthetic: SyntheticKind,
    name_text: []const u8,
    declaration_span: Span,
) !SymbolId {
    const id_u32: u32 = @intCast(list.items.len);
    try list.append(allocator, .{
        .name = .{ .start = 0, .end = 0 },
        .scope_id = ScopeId.none,
        .kind = kind,
        .decl_flags = kind.declFlags(),
        .declaration_span = declaration_span,
        .synthetic_kind = synthetic,
        .synthetic_name = name_text,
    });
    return @enumFromInt(id_u32);
}

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
    /// 이 참조가 속한 top-level statement 인덱스. top-level 이 아니거나 enable_stmt_info=false 이면
    /// `NO_STMT`. span 기반 역추적은 decorator 등 "stmt span 외부 노드" 에서 누락되므로
    /// analyzer 가 `current_top_stmt_idx` 를 직접 저장한다.
    stmt_idx: u32 = NO_STMT,
    /// 참조 종류 (bitset). 현재 analyzer 는 read 또는 write 한 플래그만 set 한다.
    flags: ReferenceFlags = .{},

    pub const NO_STMT: u32 = std.math.maxInt(u32);
};

/// 참조 종류 플래그 (packed bitset).
///
/// 현재 analyzer 가 생성하는 조합:
///   - `{ .read = true }`  — `f(x)`, `y = x` 등 값 읽기
///   - `{ .write = true }` — `x = 1`, `x += 1`, `x++` (compound/update 도 현재는 write 로만 뭉뚱)
pub const ReferenceFlags = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    _reserved: u6 = 0,
};
