//! Runtime helper usage bitset shared by transformer and bundler emit paths.

/// 런타임 헬퍼 사용 추적 비트맵.
/// transformer가 각 변환 시 해당 비트를 설정하고,
/// 번들러 emitter가 필요한 헬퍼만 출력에 주입한다.
pub const RuntimeHelpers = packed struct(u32) {
    /// __async: async/await -> generator wrapper (ES2017)
    async_helper: bool = false,
    /// __extends: class 상속 prototype chain (ES2015)
    extends: bool = false,
    /// __spreadArray: spread 연산 (ES2015)
    spread_array: bool = false,
    /// __generator: generator 상태 머신 (ES2015)
    generator: bool = false,
    /// __rest: destructuring rest (ES2015)
    rest: bool = false,
    /// __values: for-of iterator protocol (ES2015)
    values: bool = false,
    /// __toBinary: base64 -> Uint8Array (binary 로더)
    to_binary: bool = false,
    /// __name: 함수/클래스 .name 프로퍼티 보존 (--keep-names)
    keep_names: bool = false,
    /// __classPrivateMethodInit: private method brand check (WeakSet.add with error)
    class_private_method_init: bool = false,
    /// __classPrivateMethodGet: private method access with brand check
    class_private_method_get: bool = false,
    /// __classCallCheck: class를 new 없이 호출 방지 (ES2015 스펙)
    class_call_check: bool = false,
    /// __callSuper: Reflect.construct 기반 super() 호출 (네이티브 클래스 extends 지원)
    call_super: bool = false,
    /// __taggedTemplateLiteral: tagged template 객체 생성 (ES2015)
    tagged_template_literal: bool = false,
    /// __using/__callDispose: using/await using 변환 (ES2025)
    using_ctx: bool = false,
    /// __classStaticPrivateFieldSpecGet/Set: static private field accessor
    class_static_private_field: bool = false,
    /// __esDecorate/__runInitializers: TC39 Stage 3 decorator 변환 (TypeScript 5.0+)
    es_decorator: bool = false,
    /// __asyncValues: for-await-of -> while 루프 변환 (ES2018)
    async_values: bool = false,
    /// __superGet: super property get receiver 보존 (ES2015 class)
    super_get: bool = false,
    /// __superSet: super property set receiver 보존 (ES2015 class)
    super_set: bool = false,
    /// __assertThisInitialized/__assertThisUninitialized/__possibleConstructorReturn: derived constructor this 상태 검사
    derived_constructor: bool = false,
    /// __classPrivateFieldSet: instance private field set with return value (#1488).
    class_private_field_set: bool = false,
    /// __asyncGenerator: `async function*` -> Symbol.asyncIterator 객체 (ES2018, #1911)
    async_generator: bool = false,
    /// __await: async generator body 안 await 표현 wrapper (ES2018, #1911)
    await_helper: bool = false,
    /// __tdz: default initializer / block scope TDZ read
    tdz: bool = false,
    /// __read: array destructuring iterable protocol read
    read: bool = false,
    /// __decorateClass: TS legacy `experimentalDecorators` 변환 (#2194).
    /// transpile-only 모드에서도 헬퍼 정의가 출력에 inline 되도록 transformer 가
    /// 호출 emit 시 함께 set 한다.
    legacy_decorator: bool = false,
    /// __wrapRegExp: named capture group downlevel (Hermes/ES5 등) 에서 RegExp
    /// 결과의 `.groups.NAME` 접근을 살리는 wrapper (#1063).
    wrap_regex: bool = false,
    _padding: u5 = 0,

    /// 어떤 helper flag 라도 set 됐는지 - emitter 의 prepend 분기에서 빈 helper 시
    /// no-op 결정에 사용.
    pub fn hasAny(self: @This()) bool {
        return @as(u32, @bitCast(self)) != 0;
    }
};
