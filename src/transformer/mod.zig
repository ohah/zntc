//! ZTS Transformer
//!
//! 원본 AST를 순회하면서 새 AST를 빌드한다 (D041).
//! TypeScript 전용 노드를 제거하고, TS 구문을 JS로 변환한다.
//!
//! 설계:
//! - 새 AST 생성 방식 (D041: oxc/SWC 방식)
//! - Switch 기반 visitor + comptime 보조 (D042: esbuild/Bun 방식)
//! - 단일 패스, 변환 우선순위로 순서 제어 (D043)
//!
//! 참고:
//! - references/oxc/crates/oxc_transformer/src/
//! - references/esbuild/internal/js_parser/js_parser.go

pub const transformer = @import("transformer.zig");
pub const Transformer = transformer.Transformer;
pub const DefineEntry = transformer.DefineEntry;
pub const TransformOptions = transformer.TransformOptions;

/// ES 다운레벨링 모듈 (절충안 구조: 파일 분리 + 단일 패스)
pub const es2015 = @import("es2015.zig");
pub const es2016 = @import("es2016.zig");
pub const es2017 = @import("es2017.zig");
pub const es2018 = @import("es2018.zig");
pub const es2019 = @import("es2019.zig");
pub const es2020 = @import("es2020.zig");
pub const es2021 = @import("es2021.zig");
pub const es2022 = @import("es2022.zig");
pub const es2024 = @import("es2024.zig");
pub const es_helpers = @import("es_helpers.zig");
pub const minify = @import("minify.zig");

test {
    _ = transformer;
    _ = es2015;
    _ = es2016;
    _ = es2017;
    _ = es2018;
    _ = es2019;
    _ = es2020;
    _ = es2021;
    _ = es2022;
    _ = es2024;
    _ = es_helpers;
    _ = minify;

    // test files
    _ = @import("transformer_test.zig");
}
