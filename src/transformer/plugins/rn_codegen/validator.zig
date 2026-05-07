//! Schema Validator — `ComponentSchema` 정합성 검증.
//!
//! `@react-native/codegen` 의 `SchemaValidator.js:14-48` 동등 — schema 안에서 같은
//! component 이름이 두 번 이상 등장하지 않는지 확인.
//!
//! 단일 spec 파일 변환에서는 component 1 개라 사실상 trivial하지만, 향후 multi-component
//! spec (한 파일에 `codegenNativeComponent` 두 개) 또는 schema aggregation 시점을
//! 위해 추가.
//!
//! `schema_builder` 가 던지는 `error.UnresolvedTypeReference` / `UnsupportedPropType` /
//! `InvalidNativePropsBody` 도 같은 codegen 에러 코드 family (1400-1499) 와 매핑.
//! 코드 정의: `error_codes.zig:codegen_*`.

const std = @import("std");
const schema = @import("schema.zig");
const schema_builder = @import("schema_builder.zig");
const Code = @import("../../../error_codes.zig").Code;

/// `ComponentSchema` 정합성 검증. duplicate component 발견 시 첫 충돌 이름 반환,
/// 없으면 null. caller 가 진단 메시지 빌드 시 이름 사용 +
/// `Code.codegen_duplicate_component` 로 분류.
///
/// 빈 schema (component 0 개) 는 null 반환.
///
/// 보통 component 1-3 개라 단순 nested loop O(N²) 가 hash table 보다 빠름 — RN core
/// 의 가장 큰 spec 도 component < 5 개. components 가 20+ 으로 일반화되면 HashSet 으로 전환.
pub fn validate(component_schema: schema.ComponentSchema) ?[]const u8 {
    for (component_schema.components, 0..) |c, i| {
        for (component_schema.components[i + 1 ..]) |other| {
            if (std.mem.eql(u8, c.name, other.name)) return c.name;
        }
    }
    return null;
}

/// `schema_builder.Error` → `error_codes.Code` 매핑. 진단 출력 시 사용 — 사용자가 docs 사이트
/// (`https://ohah.github.io/zntc/reference/errors/zntc1400/`) 로 찾아갈 수 있도록 ZNTC 표준 코드.
///
/// `OutOfMemory` 는 codegen 도메인 외 — caller 가 먼저 분기해 처리해야 함.
/// 본 함수에 OOM 을 넘기는 건 프로그래밍 버그 (`unreachable`).
pub fn schemaBuilderErrorCode(err: schema_builder.Error) Code {
    return switch (err) {
        error.UnresolvedTypeReference => .codegen_unresolved_type_reference,
        error.UnsupportedPropType => .codegen_unsupported_prop_type,
        error.InvalidNativePropsBody => .codegen_invalid_native_props_body,
        error.InheritanceTooDeep => .codegen_inheritance_too_deep,
        error.OutOfMemory => unreachable, // caller 가 먼저 분기해야 함
    };
}
