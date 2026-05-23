//! RN View Config Codegen 모듈 — 진입점.
//!
//! `@react-native/codegen` 의 view config 인라인 기능을 ZNTC native 로 옮긴
//! 플러그인 (#2348, 모든 단계 완료). 서브 모듈:
//!
//!   schema.zig              — Schema 데이터 구조
//!   type_index.zig          — 같은 파일 내 type alias / interface 인덱싱
//!   schema_builder.zig      — NativeProps AST → ComponentShape (inheritance/intersection/wrapper unwrap)
//!   view_config_emitter.zig — ComponentShape → JS 문자열 (RN 0.78 GenerateViewConfigJs parity)
//!   validator.zig           — duplicate-component check + error-code 매핑
//!   ../rn_codegen_plugin.zig — 통합 + builtin / CLI / NAPI 노출 (graph/plugins.zig builtin / RN preset)
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
