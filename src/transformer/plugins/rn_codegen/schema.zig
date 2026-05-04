//! RN View Config Codegen — Schema 데이터 구조
//!
//! `@react-native/codegen` 의 `CodegenSchema` (`lib/CodegenSchema.d.ts`) 중
//! view config 생성에 필요한 부분만 1:1 포팅. NativeModule (TurboModule) 스키마는
//! 의도적으로 제외 — 본 codegen 플러그인은 Fabric 컴포넌트 view config inline 만
//! 지원 (#2348 § 4 참고).
//!
//! 메모리 모델:
//!   - 모든 슬라이스/문자열은 schema_builder 가 사용하는 arena allocator 가 소유.
//!   - 개별 deinit 금지. arena.deinit() 으로 일괄 해제 (CLAUDE.md "Memory ownership").
//!   - 재귀 타입 (`PropTypeAnnotation.object` → `NamedShape(PropTypeAnnotation)` →
//!     `PropTypeAnnotation`) 은 슬라이스 헤더 (16B 고정) 로 풀어서 sizeof 무한
//!     재귀 회피. 실제 N 개 element 는 arena heap.
//!
//! 참고: `@react-native/codegen` 0.85.x 기준. RN minor 간 schema 변경 빈도는
//! 낮음 (#2348 § 7 측정: 2년에 2건).

const std = @import("std");

/// 플랫폼 한정자 — `excludedPlatforms` 등에서 사용.
pub const Platform = enum { ios, android };

/// 이름 + optional 플래그 + 타입 어노테이션 묶음.
/// `CodegenSchema.d.ts` 의 `NamedShape<T>` 동등.
///
/// 사용 예: `NamedShape(PropTypeAnnotation)`, `NamedShape(EventTypeAnnotation)`,
/// `NamedShape(CommandTypeAnnotation)`, `NamedShape(CommandParamTypeAnnotation)`.
pub fn NamedShape(comptime T: type) type {
    return struct {
        name: []const u8,
        optional: bool,
        type_annotation: T,
    };
}

/// View Config 가 다루는 prop 타입 어노테이션.
/// `CodegenSchema.d.ts` 의 `PropTypeAnnotation` union 동등.
///
/// `default` 필드는 spec 파일에서 `WithDefault<T, default>` 또는 default
/// expression 으로 추출. 추출 실패 시 null (boolean/string/float) 또는
/// 0/빈문자열 (int32/double) 등 합리적 기본값.
pub const PropTypeAnnotation = union(enum) {
    boolean: BooleanProp,
    string: StringProp,
    double: DoubleProp,
    float: FloatProp,
    int32: Int32Prop,
    string_enum: StringEnumProp,
    int32_enum: Int32EnumProp,
    reserved: ReservedPropPrimitive,
    object: ObjectProp,
    array: ComponentArrayTypeAnnotation,
    mixed,

    pub const BooleanProp = struct { default: ?bool };
    pub const StringProp = struct { default: ?[]const u8 };
    pub const DoubleProp = struct { default: f64 };
    pub const FloatProp = struct { default: ?f64 };
    pub const Int32Prop = struct { default: i32 };
    pub const StringEnumProp = struct {
        default: []const u8,
        options: []const []const u8,
    };
    pub const Int32EnumProp = struct {
        default: i32,
        options: []const i32,
    };
    pub const ObjectProp = struct {
        properties: []const NamedShape(PropTypeAnnotation),
        /// 인터페이스 상속 시 base 타입 이름 (디버그/메타 용도).
        base_types: []const []const u8 = &.{},
    };
};

/// `ReservedPropTypeAnnotation` 의 `name` 필드.
/// view config 의 `validAttributes` 매핑 시 이 enum 으로 분기.
///
/// 매핑 (`GenerateViewConfigJs.js:43-108` 참고):
///   color        → processColor / colorAttribute (RN 0.85+ 형태)
///   image_source → resolveAssetSource
///   point        → pointsDiffer
///   edge_insets  → insetsDiffer
///   image_request, dimension → 매핑 미정 (현재 ZTS 미지원, fail-fast)
pub const ReservedPropPrimitive = enum {
    color,
    image_source,
    point,
    edge_insets,
    image_request,
    dimension,
};

/// `PropTypeAnnotation.array` 의 element 타입.
/// `CodegenSchema.d.ts` 의 `ComponentArrayTypeAnnotation = ArrayTypeAnnotation<...>` 동등.
///
/// 2차원 배열 (`array_of_objects`) 은 codegen 에서 ObjectTypeAnnotation 만 허용
/// — 그래서 element 타입을 generic 으로 두지 않고 명시적 variant.
pub const ComponentArrayTypeAnnotation = union(enum) {
    boolean,
    string,
    double,
    float,
    int32,
    mixed,
    string_enum: PropTypeAnnotation.StringEnumProp,
    object: []const NamedShape(PropTypeAnnotation),
    reserved: ReservedPropPrimitive,
    /// 배열의 배열 — `ArrayTypeAnnotation<ObjectTypeAnnotation<PropTypeAnnotation>>`.
    array_of_objects: []const NamedShape(PropTypeAnnotation),
};

/// 이벤트 콜백 인자 타입 어노테이션.
/// `CodegenSchema.d.ts` 의 `EventTypeAnnotation` 동등.
///
/// `PropTypeAnnotation` 과 별개 — 이벤트는 reserved 타입 (color 등) 못 받고,
/// `string_literal_union` 같은 이벤트 전용 타입을 받음.
pub const EventTypeAnnotation = union(enum) {
    boolean,
    string,
    double,
    float,
    int32,
    mixed,
    string_literal_union: []const []const u8,
    object: []const NamedShape(EventTypeAnnotation),
    /// `ArrayTypeAnnotation<EventTypeAnnotation>` — 단일 element 타입을 가리키는
    /// 포인터. arena 에 element type annotation 한 개를 박아두고 가리킴.
    array: *const EventTypeAnnotation,
};

/// 이벤트 prop 의 메타데이터.
/// `CodegenSchema.d.ts` 의 `EventTypeShape` 동등.
pub const EventTypeShape = struct {
    name: []const u8,
    bubbling_type: BubblingType,
    optional: bool,
    /// paper(legacy) 호환용 — 옛 이벤트 이름.
    paper_top_level_name_deprecated: ?[]const u8 = null,
    /// 이벤트 콜백의 인자 객체 properties. 인자 없는 이벤트는 null.
    /// (TS 의 `argument?: ObjectTypeAnnotation<EventTypeAnnotation>` 은
    ///  ObjectTypeAnnotation wrapper 를 풀어서 properties 슬라이스만 보관.)
    argument: ?[]const NamedShape(EventTypeAnnotation) = null,
};

pub const BubblingType = enum { direct, bubble };

/// 컴포넌트가 상속하는 base prop 셋.
/// `CodegenSchema.d.ts` 의 `ExtendsPropsShape` 동등.
///
/// 현재 정의된 known 타입은 `react_native_core_view_props` 하나뿐 — RN 런타임
/// (Fabric ViewConfigRegistry) 이 자체 등록하므로 view config emit 시에는 무시.
pub const ExtendsPropsShape = struct {
    known_type_name: KnownExtendsType,

    pub const KnownExtendsType = enum { react_native_core_view_props };
};

/// Imperative command 의 파라미터 타입.
/// `CodegenSchema.d.ts` 의 `CommandParamTypeAnnotation` 동등.
///
/// 주의: command param 은 `mixed` 직접 못 받음 — array element 로만 가능.
pub const CommandParamTypeAnnotation = union(enum) {
    boolean,
    string,
    double,
    float,
    int32,
    /// `ReservedTypeAnnotation { name: 'RootTag' }` — command 전용 reserved.
    /// `ReservedPropPrimitive` 와 별개 enum 인 이유는 RN 의 schema 가 둘을
    /// 다른 union 으로 정의하기 때문.
    root_tag,
    /// `ComponentCommandArrayTypeAnnotation = ArrayTypeAnnotation<basic + mixed>`.
    array: CommandArrayElement,
};

/// command 파라미터에서 array 가 받을 수 있는 element 타입.
pub const CommandArrayElement = enum {
    boolean,
    string,
    double,
    float,
    int32,
    mixed,
};

/// Imperative command 시그니처.
/// `CodegenSchema.d.ts` 의 `CommandTypeAnnotation = FunctionTypeAnnotation<Param, Void>` 동등.
///
/// 반환 타입은 항상 `void` 로 codegen 이 강제 — 별도 필드 없음.
pub const CommandTypeAnnotation = struct {
    params: []const NamedShape(CommandParamTypeAnnotation),
};

/// 한 NativeComponent 파일 (= 한 spec) 의 모든 메타데이터.
/// `CodegenSchema.d.ts` 의 `ComponentShape` (+ `OptionsShape`) 동등.
///
/// 차이점: TS 에선 `ComponentSchema.components` 가 `{ [name]: ComponentShape }`
/// dict 로 키-값이라 `name` 이 ComponentShape 자체에 없음. Zig 에선 슬라이스로
/// 풀면서 `name` 을 ComponentShape 필드로 흡수.
pub const ComponentShape = struct {
    /// 컴포넌트 이름 (`codegenNativeComponent('Name')` 의 인자).
    name: []const u8,
    /// 옵션: paper(legacy) 컴포넌트 이름.
    paper_component_name: ?[]const u8 = null,
    paper_component_name_deprecated: ?[]const u8 = null,
    /// 옵션: 인터페이스 전용 (JS impl 없음).
    interface_only: bool = false,
    /// 일부 플랫폼 전용 컴포넌트.
    excluded_platforms: []const Platform = &.{},
    /// 옵션: deprecated view config 이름 (호환).
    deprecated_view_config_name: ?[]const u8 = null,
    /// 상속 base — 현재는 `react_native_core_view_props` 만 사용.
    extends_props: []const ExtendsPropsShape = &.{},
    events: []const EventTypeShape = &.{},
    props: []const NamedShape(PropTypeAnnotation) = &.{},
    commands: []const NamedShape(CommandTypeAnnotation) = &.{},

    /// RN runtime 이 등록한 native 클래스 이름 — Paper 호환을 위해 paperComponentName
    /// 우선. emitter / file wrapper 양쪽이 같은 lookup 을 하지 않게 한 곳에 모음.
    pub fn nativeName(self: ComponentShape) []const u8 {
        return self.paper_component_name orelse self.name;
    }

    /// imperative commands (`codegenNativeCommands`) 가 있는지. emitter / wrapper /
    /// plugin 의 free 분기에서 같은 식 (`commands.len > 0`) 반복하지 않게 한 곳에 모음.
    pub fn hasCommands(self: ComponentShape) bool {
        return self.commands.len > 0;
    }
};

/// 한 spec 파일에 들어있는 모든 ComponentShape (보통 1 개, 가끔 여러 개).
/// `CodegenSchema.d.ts` 의 `ComponentSchema` 동등.
///
/// view config emit 은 each ComponentShape 단위로 호출.
pub const ComponentSchema = struct {
    components: []const ComponentShape,
};
