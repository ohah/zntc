//! ZNTC Semantic — 심볼 정의
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
    /// `const Foo = class Bar {}` 의 inner `Bar` 같은 named class expression 의
    /// inner name binding. ECMA spec: 외부 scope 에서 안 보이고 `.name` 프로퍼티로만
    /// 관찰됨. mangler 가 이 이름을 mangle 하면 `.name` 도 변하므로 (#2197) skip.
    is_class_expr_name: bool = false,
    /// 나머지 패딩
    _padding: u1 = 0,

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
    /// CJS 래퍼의 `require_<module>` 함수
    cjs_require,
    /// ESM 래퍼의 `init_<module>` 함수
    esm_init,
};

/// 컴파일 타임 상수 값. 번들러 cross-module 인라인 맵 (`linker.buildCrossModuleConstValues`)
/// 의 value 타입으로 사용된다. Symbol 에 직접 임베드하지 않는다 — Symbol 은 `const_kind`
/// 만 들고 number_text 는 `ModuleSemanticData.numeric_const_texts` 사이드테이블에 (#2505).
/// 모든 Symbol 이 16B slice 를 들지 않게 함이 목적.
pub const ConstValue = struct {
    kind: Kind = .none,
    /// `.number`일 때 원본 numeric_literal 텍스트.
    /// target module source를 가리키며, consumer AST materialize 시 string table로 복사한다.
    number_text: []const u8 = "",

    pub const Kind = enum(u8) {
        none,
        true_,
        false_,
        null_,
        undefined_,
        number,
    };

    pub fn isSafeToInline(self: *const ConstValue) bool {
        return switch (self.kind) {
            .none => false,
            .number => self.number_text.len > 0,
            else => true,
        };
    }
};

/// Mangler slot namespace (esbuild `ast.SlotNamespace` 1:1).
///
/// 식별자는 namespace 별로 독립된 slot 공간을 가진다 — 같은 slot 번호라도
/// namespace 가 다르면 충돌하지 않는다 (label `x:` 와 변수 `x` 는 별개 문법
/// 위치). `must_not_be_renamed` 는 slot 을 받지 않는 sentinel (예약/외부/이미
/// 1글자 등). ZNTC 는 현재 label/private 필드를 심볼로 모델링하지 않으므로
/// 실제로는 `default` / `must_not_be_renamed` 만 등장한다 (RFC #3391 / #3392 —
/// label·private 은 후속 PR 에서 심볼화 시 자연히 채워짐). 이 enum 을 semantic
/// 에 두는 이유: Symbol 이 codegen 을 import 하면 레이어 역전 (mangler 가
/// runtime_helper_names 를 공용 모듈로 분리한 것과 동일 원칙).
pub const SlotNamespace = enum(u8) {
    default = 0,
    label = 1,
    private_name = 2,
    must_not_be_renamed = 3,

    /// slot 카운터를 가지는 namespace 수 (`must_not_be_renamed` 은 sentinel 이라 제외).
    pub const indexable_count = 3;
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

    /// 컴파일 타임 상수 종류 (번들러 cross-module 인라인용).
    /// const/let 선언의 초기화 값이 리터럴이면 set. `.number` 일 때만 추가로
    /// `ModuleSemanticData.numeric_const_texts` 에 텍스트가 같이 등록된다 — 16B slice 를
    /// 모든 Symbol 에 박지 않으려는 분리 (#2505).
    const_kind: ConstValue.Kind = .none,

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

    /// Mangler slot namespace (RFC #3391 / #3392 — nested-scope renamer port).
    /// `assignNestedScopeSlots` (codegen/nested_slots.zig) 가 walk 중 계산해
    /// 채운다. PR-1 시점엔 파이프라인 미연결이라 동작 무변경. 캐시 보유 vs
    /// 매번 재계산(esbuild 는 `Symbol.SlotNamespace()` 메서드)의 트레이드오프
    /// 는 PR-2 이름 발급 연결 시 확정한다.
    slot_namespace: SlotNamespace = .default,

    /// Nested-scope slot 번호. null = 미할당 (esbuild `ast.Index32{}` 의 invalid
    /// 대응). top-level 심볼은 nested slot 을 받지 않으므로 walk 후 항상 null.
    /// 형제 scope 끼리 같은 번호를 재사용하고 자식 scope 는 부모 카운트 *이후*
    /// 부터 부여되어, closure-capture 된 outer 이름과 구성적으로 충돌 불가
    /// (esbuild renamer.go 의 핵심 안전 불변식). PR-1: 필드만 추가 — 아직
    /// mangler 가 소비하지 않음 (behavior 무변경).
    nested_scope_slot: ?u32 = null,

    /// 이 심볼의 이름을 반환. 합성은 `synthetic_name`, 정규는 source Span에서.
    pub fn nameText(self: *const Symbol, source: []const u8) []const u8 {
        if (self.synthetic_name.len > 0) return self.synthetic_name;
        return source[self.name.start..self.name.end];
    }

    pub fn isSynthetic(self: *const Symbol) bool {
        return self.synthetic_kind != null;
    }

    /// `export const x` / `export default const` 둘 다 module 외부에서 관찰 가능 — tree-shaker
    /// 보존 판정, minify 의 dead-store 제외, mangler 의 이름 보존 등에서 동일하게 묶인다.
    pub fn isExported(self: *const Symbol) bool {
        return self.decl_flags.is_exported or self.decl_flags.is_default_export;
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
    /// 이 참조가 속한 **enclosing top-level** statement 인덱스. top-level 외에서 일어난 참조라도
    /// 이 값은 해당 참조를 포함하는 top-level stmt (함수 선언 등)의 idx 로 세팅되어 tree-shaker
    /// 가 "top-level stmt 가 어떤 심볼을 참조하는가" 를 추적할 수 있게 한다. top-level 이 아니거나
    /// enable_stmt_info=false 이면 `NO_STMT`.
    stmt_idx: u32 = NO_STMT,
    /// #1669: 이 참조가 속한 **enclosing scope** statement 인덱스 (per-scope 0-base).
    /// program / function body / block 각각 자체 카운터. single-use inline 이 선언-read adjacency
    /// 를 같은 scope 내에서 판단할 때 사용. top-level 에서는 `stmt_idx` 와 동일.
    scope_stmt_idx: u32 = NO_STMT,
    /// 참조 종류 (bitset). read / write / read+write / declare 조합.
    flags: ReferenceFlags = .{},

    pub const NO_STMT: u32 = std.math.maxInt(u32);

    /// #1791: runtime 에 값이 실제로 필요한 참조인지 판정.
    /// `declare` 는 선언 위치 (값 사용 아님), `type_context` / `value_as_type` 는 TS
    /// type 문맥 (런타임 제거됨). 셋 다 false 인 read/write 만 "value-use" 로 취급.
    /// Phase D 가 transformer/linker 양쪽에서 동일 기준으로 공유.
    pub fn isValueUse(self: Reference) bool {
        if (self.flags.declare) return false;
        if (self.flags.type_context or self.flags.value_as_type) return false;
        return self.flags.read or self.flags.write;
    }
};

/// 참조 종류 플래그 (packed bitset).
///
/// 현재 analyzer 가 생성하는 조합:
///   - `{ .read = true }`               — `f(x)`, `y = x` 등 값 읽기
///   - `{ .write = true }`              — `x = 1` (pure assign)
///   - `{ .read = true, .write = true }` — `x += 1`, `x++`, `--x` 등 compound/update
///   - `{ .declare = true }`            — 선언 위치 (#1669 부터 모든 scope). node_index 는 NodeIndex.none
///     (선언 span 을 Reference 에 싣지 않음 — buildFromSemantic 은 scope_id==0 + stmt_idx 로 bucket 분배)
///
/// #1791 type-context flag:
///   - `{ .read = true, .type_context = true }` — `x: T`, `interface I extends T` 등 type 문맥 내 참조
///   - `{ .read = true, .value_as_type = true }` — `typeof x`, `keyof x` — value id 를 type 으로 사용
///   - 두 flag 모두 false 인 `.read` 는 "값으로 참조됨" — import binding elision (#1791 Phase D)
///     판정의 근거. `reference_count` 는 mangler 전용이라 이 판정에는 부적절 (false positive).
pub const ReferenceFlags = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    declare: bool = false,
    /// 참조가 TypeScript type 문맥 (`x: T`, `extends T`, `T[]` 등) 내에서 발생.
    /// 기존 analyzer 가 type node 를 순회하지 않아 이 플래그는 현재 미사용이지만, #1791 에서
    /// type node 진입 시 식별자를 기록할 때 세팅할 예정. Phase D 는 "모든 read 가 이 bit 를
    /// 가지면 value 미사용" 으로 판정.
    type_context: bool = false,
    /// `typeof X` / `keyof X` 처럼 **value 식별자를 type 으로 사용**. `type_context` 와는
    /// 별개 bit — 회색지대 분석 (isolated declarations 등) 에서 구분이 필요할 수 있음.
    /// Phase D 판정에선 `type_context` 와 동일하게 "value 사용 아님" 취급.
    value_as_type: bool = false,
    _reserved: u3 = 0,
};
