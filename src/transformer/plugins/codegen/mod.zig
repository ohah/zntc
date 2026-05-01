//! RN View Config Codegen 모듈 — 진입점.
//!
//! `@react-native/codegen` 의 view config 인라인 기능을 ZTS native 로 옮긴
//! 플러그인 (#2348). 다음 단계:
//!
//!   schema.zig            — Schema 데이터 구조 (PR #1, merged)
//!   type_index.zig        — 같은 파일 내 type alias / interface 인덱싱 (PR #2)
//!   schema_builder.zig    — TODO (PR #3): NativeProps AST → ComponentShape
//!   view_config_emitter.zig — TODO (PR #4): ComponentShape → JS 문자열
//!   validator.zig         — TODO (PR #5): SchemaValidator 동등 + 진단
//!   codegen_plugin.zig    — TODO (PR #6): 통합 + builtin / CLI / NAPI 노출
//!
//! 본 mod.zig 자체는 import 만 묶음. 외부에선 필요한 서브 모듈을 직접 import
//! 하거나 본 파일을 통해 가져갈 수 있다.

pub const schema = @import("schema.zig");
pub const type_index = @import("type_index.zig");

test {
    _ = schema;
    _ = type_index;
    _ = @import("type_index_test.zig");
}
