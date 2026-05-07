//! RN View Config Codegen 모듈 — 진입점.
//!
//! `@react-native/codegen` 의 view config 인라인 기능을 ZNTC native 로 옮긴
//! 플러그인 (#2348). 다음 단계:
//!
//!   schema.zig            — Schema 데이터 구조 (PR #1, merged)
//!   type_index.zig        — 같은 파일 내 type alias / interface 인덱싱 (PR #2)
//!   schema_builder.zig    — TODO (PR #3): NativeProps AST → ComponentShape
//!   view_config_emitter.zig — TODO (PR #4): ComponentShape → JS 문자열
//!   validator.zig         — TODO (PR #5): SchemaValidator 동등 + 진단
//!   ../rn_codegen_plugin.zig — 통합 + builtin / CLI / NAPI 노출 (PR #6, merged)
//!
//! 본 mod.zig 자체는 import 만 묶음. 외부에선 필요한 서브 모듈을 직접 import
//! 하거나 본 파일을 통해 가져갈 수 있다.

pub const schema = @import("schema.zig");
pub const type_index = @import("type_index.zig");
pub const schema_builder = @import("schema_builder.zig");
pub const view_config_emitter = @import("view_config_emitter.zig");
pub const validator = @import("validator.zig");

test {
    _ = schema;
    _ = type_index;
    _ = schema_builder;
    _ = view_config_emitter;
    _ = validator;
    _ = @import("type_index_test.zig");
    _ = @import("schema_builder_test.zig");
    _ = @import("view_config_emitter_test.zig");
    _ = @import("validator_test.zig");
    _ = @import("snapshot_test.zig");
}
