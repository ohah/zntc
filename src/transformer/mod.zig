//! ZNTC Transformer
//!
//! 단일 AST를 append-only로 in-place 변환한다 (transformer.zig 헤더 참조 —
//! RFC_TRANSFORMER_OWN_AST 이후 D041 의 "새 AST 빌드" 모델에서 변경됨).
//! TypeScript 전용 노드를 제거하고, TS 구문을 JS로 변환한다.
//!
//! 설계:
//! - append-only in-place 변환 (clone deep copy 회피)
//! - Switch 기반 visitor + comptime 보조 (D042: esbuild/Bun 방식)
//! - 주 패스는 단일 순회로 변환 우선순위 제어 (D043). 단 ES2015 default/object-spread
//!   params 다운레벨이 켜지면 driver 의 lowerAllFunctionParams 가 전체 노드를 한 번 더 순회
//!
//! 참고:
//! - references/oxc/crates/oxc_transformer/src/
//! - references/esbuild/internal/js_parser/js_parser.go

pub const transformer = @import("transformer.zig");
pub const options = @import("options.zig");
pub const runtime_helper_bits = @import("runtime_helper_bits.zig");
pub const Transformer = transformer.Transformer;
pub const AutoLabelMode = options.AutoLabelMode;
pub const BindingLite = options.BindingLite;
pub const DefineEntry = options.DefineEntry;
pub const ModuleSpecifierMapEntry = options.ModuleSpecifierMapEntry;
pub const Plugin = options.Plugin;
pub const RuntimeHelpers = runtime_helper_bits.RuntimeHelpers;
pub const TransformOptions = options.TransformOptions;
pub const ast_plugin_mod = @import("ast_plugin.zig");

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
    _ = options;
    _ = runtime_helper_bits;
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
    _ = @import("minify_test.zig");
    _ = @import("worklet_test.zig");
    _ = @import("worklet_babel_parity_test.zig");
    _ = @import("styled_components_test.zig");
    _ = @import("emotion_test.zig");
    _ = @import("plugins/rn_codegen/mod.zig");
    _ = @import("plugins/rn_codegen_plugin_test.zig");
}
