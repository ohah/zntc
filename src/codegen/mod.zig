//! ZTS Code Generator
//!
//! 변환된 AST를 JavaScript 문자열 + 소스맵으로 출력한다.
//!
//! 설계:
//! - AST를 순회하며 JS 문자열을 ArrayList(u8)에 직접 출력
//! - switch 기반 (transformer와 동일 패턴)
//! - 원본 소스의 span을 참조하여 식별자/리터럴 텍스트를 zero-copy 출력
//! - 소스맵 V3: VLQ 인코딩 + JSON 출력 (D046)

pub const codegen = @import("codegen.zig");
pub const Codegen = codegen.Codegen;
pub const QuoteStyle = codegen.QuoteStyle;
pub const sourcemap = @import("sourcemap.zig");
pub const SourceMapBuilder = sourcemap.SourceMapBuilder;
pub const function_map = @import("function_map.zig");
pub const FunctionMapBuilder = function_map.FunctionMapBuilder;
pub const mangler = @import("mangler.zig");

test {
    _ = codegen;
    _ = sourcemap;
    _ = function_map;
    _ = mangler;

    // test files
    _ = @import("codegen_test.zig");
    _ = @import("sourcemap_test.zig");
    _ = @import("mangler_test.zig");
}
