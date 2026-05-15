//! Runtime Helper 이름 테이블 — transformer/bundler 공용 abstraction.
//!
//! minify 모드에서 `__xxx` → `$xx` 축약 이름 매핑을 단일 소스로 관리한다.
//! transformer (AST identifier emit) 와 bundler (preamble + mangler reserved)
//! 양쪽이 **이 모듈에만 의존** — 서로에게 의존하지 않아 레이어 역전 없음.
//!
//! - `NAMES`: 각 helper 의 축약 이름 상수 (base_name 참조용).
//! - `PAIRS`: `(base_name, short)` 매핑 테이블. 단일 소스.
//! - `helperName(base, minify)`: transformer 가 AST identifier 이름 결정 시 호출.
//! - `ALL_SHORT_NAMES`: mangler 예약 / 테스트 iterate 용.
//!
//! 실제 preamble 문자열 템플릿 (`CJS_RUNTIME_MIN` 등) 은 `bundler/runtime_helpers.zig`
//! 에 유지된다 — bundler-only concern. 이 모듈은 **이름만** 담당.

const std = @import("std");

pub const NAMES = struct {
    // bundler interop
    pub const CJS_FACTORY_MIN = "$c"; // __commonJS — 호출 빈도 가장 높음 (모듈 wrapper 마다)
    pub const REQUIRE_MIN = "$r"; // __commonJS body 내부 function __require
    pub const ESM_FACTORY_MIN = "$e"; // __esm
    pub const EXPORT_MIN = "$x"; // __export
    pub const TOESM_MIN = "$tE"; // __toESM
    pub const TOCOMMONJS_MIN = "$tC"; // __toCommonJS
    // Object.* alias — __toESM/__export body 에서 참조.
    pub const CREATE_MIN = "$cr"; // __create
    pub const GET_PROTO_OF_MIN = "$gP"; // __getProtoOf
    pub const DEF_PROP_MIN = "$dp"; // __defProp
    pub const GET_OWN_PROP_NAMES_MIN = "$gN"; // __getOwnPropNames
    pub const GET_OWN_PROP_DESC_MIN = "$gD"; // __getOwnPropDesc
    pub const HAS_OWN_MIN = "$hO"; // __hasOwn
    pub const COPY_PROPS_MIN = "$cp"; // __copyProps
    // transformer-emitted downlevel (RN/ES5 타겟에서 다수 emit)
    pub const EXTENDS_MIN = "$eX"; // __extends (ES2015 class)
    pub const CLASS_CALL_CHECK_MIN = "$cC"; // __classCallCheck
    pub const CALL_SUPER_MIN = "$cS"; // __callSuper
    pub const SUPER_GET_MIN = "$sPg"; // __superGet
    pub const SUPER_SET_MIN = "$sPs"; // __superSet
    pub const ASSERT_THIS_INITIALIZED_MIN = "$aT"; // __assertThisInitialized
    pub const ASSERT_THIS_UNINITIALIZED_MIN = "$aU"; // __assertThisUninitialized
    pub const POSSIBLE_CONSTRUCTOR_RETURN_MIN = "$pR"; // __possibleConstructorReturn
    pub const TDZ_MIN = "$td"; // __tdz
    pub const READ_MIN = "$rd"; // __read
    pub const ASYNC_MIN = "$aS"; // __async (async/await → generator)
    pub const ASYNC_VALUES_MIN = "$aV"; // __asyncValues (for-await-of)
    pub const GENERATOR_MIN = "$gn"; // __generator
    pub const REST_MIN = "$rs"; // __rest (object rest destructure)
    pub const TAGGED_TEMPLATE_MIN = "$tt"; // __taggedTemplateLiteral
    pub const ARRAY_LIKE_TO_ARRAY_MIN = "$aL"; // __arrayLikeToArray
    pub const TO_CONSUMABLE_ARRAY_MIN = "$tA"; // __toConsumableArray (array spread)
    pub const NAME_MIN = "$nm"; // __name (--keep-names)
    pub const TO_BINARY_MIN = "$tb"; // __toBinary (binary loader asset)
    // ES2022 private field downlevel
    pub const PRIVATE_METHOD_INIT_MIN = "$pI"; // __classPrivateMethodInit
    pub const PRIVATE_METHOD_GET_MIN = "$pG"; // __classPrivateMethodGet
    pub const PRIVATE_FIELD_SET_MIN = "$pF"; // __classPrivateFieldSet
    pub const PRIVATE_FIELD_SET_LOCAL = "__zntcClassPrivateFieldSet";
    pub const STATIC_PRIVATE_ACCESS_MIN = "$sA"; // __classCheckPrivateStaticAccess
    pub const STATIC_PRIVATE_DESC_MIN = "$sD"; // __classCheckPrivateStaticFieldDescriptor
    pub const STATIC_PRIVATE_GET_MIN = "$sG"; // __classStaticPrivateFieldSpecGet
    pub const STATIC_PRIVATE_SET_MIN = "$sS"; // __classStaticPrivateFieldSpecSet
    // decorator
    pub const DECORATE_CLASS_MIN = "$dC"; // __decorateClass
    pub const DECORATE_PARAM_MIN = "$dK"; // __decorateParam
    pub const DEF_PROP_2_MIN = "$dp2"; // __defProp2 (DECORATOR body, $dp 와 분리)
    pub const METADATA_MIN = "$mD"; // __metadata
    pub const ES_DECORATE_MIN = "$eD"; // __esDecorate
    pub const RUN_INITIALIZERS_MIN = "$rI"; // __runInitializers
    pub const SET_FUNCTION_NAME_MIN = "$sF"; // __setFunctionName
    pub const PROP_KEY_MIN = "$pK"; // __propKey
    // ES2025 explicit resource management
    pub const USING_MIN = "$us"; // __using
    pub const CALL_DISPOSE_MIN = "$cD"; // __callDispose
    // RegExp downlevel
    pub const WRAP_REGEXP_MIN = "$wR"; // __wrapRegExp (named capture downlevel)
};

/// 모든 runtime helper 의 `(base_name, short_name)` 단일 소스 테이블.
/// 새 helper 추가는 여기에 entry 만 추가 — `helperName` 조회, mangler 예약, 테스트
/// iteration 이 전부 이 테이블을 consume 하므로 세 곳의 drift 를 구조적으로 방지한다.
pub const PAIRS = [_]struct { base: []const u8, short: []const u8 }{
    // bundler interop (#1618 + #1621)
    .{ .base = "__commonJS", .short = NAMES.CJS_FACTORY_MIN },
    .{ .base = "__require", .short = NAMES.REQUIRE_MIN },
    .{ .base = "__esm", .short = NAMES.ESM_FACTORY_MIN },
    .{ .base = "__export", .short = NAMES.EXPORT_MIN },
    .{ .base = "__toESM", .short = NAMES.TOESM_MIN },
    .{ .base = "__toCommonJS", .short = NAMES.TOCOMMONJS_MIN },
    .{ .base = "__create", .short = NAMES.CREATE_MIN },
    .{ .base = "__getProtoOf", .short = NAMES.GET_PROTO_OF_MIN },
    .{ .base = "__defProp", .short = NAMES.DEF_PROP_MIN },
    .{ .base = "__getOwnPropNames", .short = NAMES.GET_OWN_PROP_NAMES_MIN },
    .{ .base = "__getOwnPropDesc", .short = NAMES.GET_OWN_PROP_DESC_MIN },
    .{ .base = "__hasOwn", .short = NAMES.HAS_OWN_MIN },
    .{ .base = "__copyProps", .short = NAMES.COPY_PROPS_MIN },
    // transformer-emitted downlevel (#1621)
    .{ .base = "__extends", .short = NAMES.EXTENDS_MIN },
    .{ .base = "__classCallCheck", .short = NAMES.CLASS_CALL_CHECK_MIN },
    .{ .base = "__callSuper", .short = NAMES.CALL_SUPER_MIN },
    .{ .base = "__superGet", .short = NAMES.SUPER_GET_MIN },
    .{ .base = "__superSet", .short = NAMES.SUPER_SET_MIN },
    .{ .base = "__assertThisInitialized", .short = NAMES.ASSERT_THIS_INITIALIZED_MIN },
    .{ .base = "__assertThisUninitialized", .short = NAMES.ASSERT_THIS_UNINITIALIZED_MIN },
    .{ .base = "__possibleConstructorReturn", .short = NAMES.POSSIBLE_CONSTRUCTOR_RETURN_MIN },
    .{ .base = "__tdz", .short = NAMES.TDZ_MIN },
    .{ .base = "__read", .short = NAMES.READ_MIN },
    .{ .base = "__async", .short = NAMES.ASYNC_MIN },
    .{ .base = "__asyncValues", .short = NAMES.ASYNC_VALUES_MIN },
    .{ .base = "__generator", .short = NAMES.GENERATOR_MIN },
    .{ .base = "__rest", .short = NAMES.REST_MIN },
    .{ .base = "__taggedTemplateLiteral", .short = NAMES.TAGGED_TEMPLATE_MIN },
    .{ .base = "__arrayLikeToArray", .short = NAMES.ARRAY_LIKE_TO_ARRAY_MIN },
    .{ .base = "__toConsumableArray", .short = NAMES.TO_CONSUMABLE_ARRAY_MIN },
    .{ .base = "__name", .short = NAMES.NAME_MIN },
    .{ .base = "__toBinary", .short = NAMES.TO_BINARY_MIN },
    .{ .base = "__classPrivateMethodInit", .short = NAMES.PRIVATE_METHOD_INIT_MIN },
    .{ .base = "__classPrivateMethodGet", .short = NAMES.PRIVATE_METHOD_GET_MIN },
    .{ .base = "__classPrivateFieldSet", .short = NAMES.PRIVATE_FIELD_SET_MIN },
    .{ .base = "__classCheckPrivateStaticAccess", .short = NAMES.STATIC_PRIVATE_ACCESS_MIN },
    .{ .base = "__classCheckPrivateStaticFieldDescriptor", .short = NAMES.STATIC_PRIVATE_DESC_MIN },
    .{ .base = "__classStaticPrivateFieldSpecGet", .short = NAMES.STATIC_PRIVATE_GET_MIN },
    .{ .base = "__classStaticPrivateFieldSpecSet", .short = NAMES.STATIC_PRIVATE_SET_MIN },
    .{ .base = "__decorateClass", .short = NAMES.DECORATE_CLASS_MIN },
    .{ .base = "__decorateParam", .short = NAMES.DECORATE_PARAM_MIN },
    .{ .base = "__defProp2", .short = NAMES.DEF_PROP_2_MIN },
    .{ .base = "__metadata", .short = NAMES.METADATA_MIN },
    .{ .base = "__esDecorate", .short = NAMES.ES_DECORATE_MIN },
    .{ .base = "__runInitializers", .short = NAMES.RUN_INITIALIZERS_MIN },
    .{ .base = "__setFunctionName", .short = NAMES.SET_FUNCTION_NAME_MIN },
    .{ .base = "__propKey", .short = NAMES.PROP_KEY_MIN },
    .{ .base = "__using", .short = NAMES.USING_MIN },
    .{ .base = "__callDispose", .short = NAMES.CALL_DISPOSE_MIN },
    .{ .base = "__wrapRegExp", .short = NAMES.WRAP_REGEXP_MIN },
};

/// PAIRS 로부터 base_name → short_name comptime 해시맵.
const helper_map: std.StaticStringMap([]const u8) = blk: {
    var entries: [PAIRS.len]struct { []const u8, []const u8 } = undefined;
    for (PAIRS, 0..) |p, i| entries[i] = .{ p.base, p.short };
    break :blk std.StaticStringMap([]const u8).initComptime(entries);
};

/// PAIRS 의 short name 만 뽑은 comptime 배열. mangler 예약/테스트 iterate 용.
pub const ALL_SHORT_NAMES: [PAIRS.len][]const u8 = blk: {
    var names: [PAIRS.len][]const u8 = undefined;
    for (PAIRS, 0..) |p, i| names[i] = p.short;
    break :blk names;
};

/// tslib UMD 가 global 에 노출하는 private class helper 이름.
/// 출처: `node_modules/tslib/tslib.js` 의 `exporter("__classPrivate*", ...)`.
/// 시그니처가 ZNTC inline 과 다를 수 있으므로, `PAIRS` 에 같은 base 가 있으면
/// (즉 ZNTC 가 그 이름으로 inline emit 한다면) `LOCAL_OVERRIDES` 에 `__zntc`
/// prefix local 을 등록해 격리해야 한다. 새 helper 추가 / tslib 업데이트로
/// PAIRS 가 늘면 아래 `comptime` drift check 가 빌드 타임에 잡는다.
pub const TSLIB_UMD_EXPORTS = [_][]const u8{
    "__classPrivateFieldGet",
    "__classPrivateFieldSet",
    "__classPrivateFieldIn",
};

/// 비minify 모드에서 helper 의 local 이름을 ZNTC 전용 prefix 로 격리하는 매핑.
/// tslib UMD 가 같은 이름을 global 에 노출해도 emit 된 호출이 사용자 코드의
/// helper 로 잘못 resolve 되지 않도록 보장 (#3141 `ea519cbb`).
pub const LOCAL_OVERRIDES = [_]struct { base: []const u8, local: []const u8 }{
    .{ .base = "__classPrivateFieldSet", .local = NAMES.PRIVATE_FIELD_SET_LOCAL },
};

// 빌드 타임 drift 가드 — `TSLIB_UMD_EXPORTS` 와 `PAIRS` 가 겹치는 base 는
// 반드시 `LOCAL_OVERRIDES` 에 등록되어야 한다. ZNTC 가 새 inline helper 를
// 추가하다가 tslib 와 충돌하는 이름을 우연히 사용하는 경우, 또는 tslib
// 신규 helper export 가 PAIRS 에 추가될 경우, 컴파일 단계에서 즉시 실패.
comptime {
    @setEvalBranchQuota(10_000);
    for (TSLIB_UMD_EXPORTS) |tslib_name| {
        var in_pairs = false;
        for (PAIRS) |p| {
            if (std.mem.eql(u8, p.base, tslib_name)) {
                in_pairs = true;
                break;
            }
        }
        if (in_pairs) {
            var has_override = false;
            for (LOCAL_OVERRIDES) |o| {
                if (std.mem.eql(u8, o.base, tslib_name)) {
                    has_override = true;
                    break;
                }
            }
            if (!has_override) {
                @compileError("tslib UMD export collides with ZNTC inline helper, add LOCAL_OVERRIDES entry: " ++ tslib_name);
            }
        }
    }
}

/// transformer 가 AST identifier 로 emit 하는 runtime helper local 이름을 minify 플래그에
/// 따라 축약/원본으로 선택한다. non-helper identifier (Math, writable 등) 에는
/// 호출하지 않는다 — `PAIRS` 에 등록된 이름만 처리. 매핑에 없으면 원본 반환
/// (mangler_test 가 drift 를 빌드 타임에 잡음).
pub fn helperName(base_name: []const u8, minify: bool) []const u8 {
    if (!minify) {
        // tslib UMD 와 시그니처가 다른 ZNTC inline helper 는 `__zntc` prefix
        // 로 local 격리. drift 는 위 comptime check 로 빌드 타임에 검출.
        inline for (LOCAL_OVERRIDES) |o| {
            if (std.mem.eql(u8, base_name, o.base)) return o.local;
        }
        return base_name;
    }
    return helper_map.get(base_name) orelse base_name;
}

test "helperName: tslib UMD 와 충돌하는 PAIRS entry 는 LOCAL_OVERRIDES 로 격리" {
    // TSLIB_UMD_EXPORTS 에 등록된 이름이 PAIRS 에도 있다면 (즉 ZNTC inline
    // 이 그 이름을 emit 한다면) helperName(.., false) 결과는 반드시 base 와
    // 달라야 한다. comptime drift check 가 빌드 타임에 잡지만, runtime
    // invariant 도 명시적으로 잠가 invariant 위반 시 즉시 실패.
    for (TSLIB_UMD_EXPORTS) |tslib_name| {
        var in_pairs = false;
        for (PAIRS) |p| {
            if (std.mem.eql(u8, p.base, tslib_name)) {
                in_pairs = true;
                break;
            }
        }
        if (!in_pairs) continue;

        const local = helperName(tslib_name, false);
        try std.testing.expect(!std.mem.eql(u8, local, tslib_name));
    }
}

test "helperName: 일반 helper 는 비minify 에서 base 그대로 반환" {
    // PRIVATE_FIELD_SET 외 다른 helper 는 override 없으니 base 그대로.
    try std.testing.expectEqualStrings("__extends", helperName("__extends", false));
    try std.testing.expectEqualStrings("__generator", helperName("__generator", false));
    try std.testing.expectEqualStrings("__classCallCheck", helperName("__classCallCheck", false));
}

test "helperName: minify 모드는 short 매핑 반환" {
    try std.testing.expectEqualStrings(NAMES.EXTENDS_MIN, helperName("__extends", true));
    try std.testing.expectEqualStrings(NAMES.PRIVATE_FIELD_SET_MIN, helperName("__classPrivateFieldSet", true));
}
