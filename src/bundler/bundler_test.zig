// bundler_test.zig — 테스트 허브 (실제 테스트는 bundler_test/ 하위 파일에 있음)
//
// 카테고리별 분리:
//   basic.zig              — 기본 번들링, 링커, re-export, scope hoisting, circular
//   typescript_format.zig  — TypeScript, deep chain, real-world, format, edge, complex
//   compat.zig             — Rollup/esbuild/Bun/Rolldown/Webpack 호환성, stress
//   default_deconflict.zig — default export, deconflict, assignment, TS/circular 고급
//   patterns.zig           — real-world 패턴, error, format 고급, mixed, hoisting
//   expressions.zig        — expression, new, codegen, class, module, control flow, async
//   jsx.zig                — JSX 컴포넌트, TS 고급, deconflict, edge
//   resolution.zig         — package.json, extension, dynamic import, namespace, JSON
//   tree_shake.zig         — tree shaking, @__PURE__, sideEffects, integration
//   cjs_esm.zig            — CJS interop, ESM wrap, TLA
//   splitting_dev.zig      — code splitting, dev mode, profiling
//   minify_loader.zig      — minify, asset loader, scope hoist regression
//   plugin_misc.zig        — plugin, worker, Flow, ESM live binding, JSX auto, RN, misc
//   function_map.zig       — Metro x_facebook_sources function map 번들러 통합 테스트

comptime {
    _ = @import("bundler_test/basic.zig");
    _ = @import("bundler_test/typescript_format.zig");
    _ = @import("bundler_test/compat.zig");
    _ = @import("bundler_test/default_deconflict.zig");
    _ = @import("bundler_test/patterns.zig");
    _ = @import("bundler_test/expressions.zig");
    _ = @import("bundler_test/jsx.zig");
    _ = @import("bundler_test/resolution.zig");
    _ = @import("bundler_test/tree_shake.zig");
    _ = @import("bundler_test/cjs_esm.zig");
    _ = @import("bundler_test/splitting_dev.zig");
    _ = @import("bundler_test/minify_loader.zig");
    _ = @import("bundler_test/plugin_misc.zig");
    _ = @import("bundler_test/function_map.zig");
    _ = @import("bundler_test/virtual_ns_treeshake.zig");
    _ = @import("bundler_test/ns_member_shadow.zig");
    _ = @import("bundler_test/exports_name_dedup.zig");
    _ = @import("bundler_test/lowering_rename_leak.zig");
    _ = @import("bundler_test/manual_chunks.zig");
    _ = @import("namespace_access_test.zig");
}
