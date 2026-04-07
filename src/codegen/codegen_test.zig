// codegen_test.zig — 테스트 허브 (실제 테스트는 codegen_test/ 하위 파일에 있음)
//
// 카테고리별 분리:
//   helpers.zig            — 공용 헬퍼 (TestResult, e2e*, SourceMapTestResult)
//   basic.zig              — 기본 codegen 출력 테스트
//   features.zig           — E2E 기능 테스트 (class, arrow, async, destructuring, JSX 등)
//   cjs_importmeta.zig     — CJS 포맷 + import.meta 폴리필
//   es_downlevel.zig       — ES 버전별 다운레벨링 (ES2020→ES5)
//   minify_sourcemap.zig   — 삼항, minify, source map 정확도
//   flow.zig               — Flow 타입 스트리핑
//   engine_jsx.zig         — 엔진 타겟 + JSX 런타임 모드
//   private_jsx_advanced.zig — private method, JSX text/dev/auto, ES2025

comptime {
    _ = @import("codegen_test/helpers.zig");
    _ = @import("codegen_test/basic.zig");
    _ = @import("codegen_test/features.zig");
    _ = @import("codegen_test/cjs_importmeta.zig");
    _ = @import("codegen_test/es_downlevel.zig");
    _ = @import("codegen_test/minify_sourcemap.zig");
    _ = @import("codegen_test/flow.zig");
    _ = @import("codegen_test/engine_jsx.zig");
    _ = @import("codegen_test/private_jsx_advanced.zig");
    _ = @import("codegen_test/decorator.zig");
}
