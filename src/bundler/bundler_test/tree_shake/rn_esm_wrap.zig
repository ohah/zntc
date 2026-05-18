const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// #2398 — RN-platform .esm wrap 환경에서 barrel re-export DCE
// ============================================================

test "TreeShaking #2398: RN .esm wrap + sideEffects:false barrel drops unused re-exports" {
    // graph.zig:2510 의 RN preset 이 모든 ESM 모듈을 .esm wrap → 종전엔 lodash-es 처럼
    // 명시적 sideEffects:false 패키지조차 unused re-export 가 전부 번들에 들어가던
    // 회귀. 본 fix 후 user-declared pure 모듈은 정밀 DCE 가능해야 함.
    // findPackageDirPath 가 node_modules 위치 기준이라 fixture 도 동일 구조.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { default as used } from './used.js';
        \\export { default as unused1 } from './unused1.js';
        \\export { default as unused2 } from './unused2.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export default function used() { return 'USED_FN_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused1.js", "export default function unused1() { return 'UNUSED_FN1_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/unused2.js", "export default function unused2() { return 'UNUSED_FN2_BODY'; }");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_FN_BODY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_FN1_BODY") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_FN2_BODY") == null);
}

test "TreeShaking #2398: RN .esm wrap + sideEffects 미명시는 conservative 보존 (회귀 가드)" {
    // RN core 처럼 `package.json sideEffects` 필드 없는 모듈은 본 fix 가
    // 종전 보수 동작 유지. user-declared pure 가 아니면 .esm wrap StmtInfo 빌드도
    // 안 하고 evaluation effect 로 간주해 init ordering 깨지지 않도록 안전판.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { default as used } from './used.js';
        \\export { default as helper } from './helper.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js", "export default function used() { return 'USED_FN'; }");
    try writeFile(tmp.dir, "node_modules/pkg/helper.js", "export default function helper() { return 'HELPER_FN'; }");
    // package.json sideEffects 미명시 (필드 없는 형태) → conservative
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\"}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_FN") != null);
    // sideEffects 미명시 → 종전 동작 그대로 helper 도 보존 (보수)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "HELPER_FN") != null);
}

test "TreeShaking #2398: RN .esm wrap + sideEffects:false barrel 50개 re-export 스케일" {
    // lodash-es 와 가까운 형태 reproduce. 종전엔 50개 fn body 가 모두 번들에 들어
    // 갔지만 (107KB) 본 fix 후 1 개만 남아야 함. 작은 fixture 에선 발견 안 되던
    // scale-induced 회귀 (예: bitset 크기, O(N²) 폭주) 까지 catch.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // entry — 50개 중 fn0 만 사용
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn0 } from 'pkg';
        \\console.log(fn0());
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    // 50 개 default-as-named re-export 의 barrel — 향후 카운트 늘려도 overflow 없도록 dynamic.
    var barrel_buf: std.ArrayList(u8) = .empty;
    defer barrel_buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var line_buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "export {{ default as fn{d} }} from './fn{d}.js';\n", .{ i, i });
        try barrel_buf.appendSlice(std.testing.allocator, line);

        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "node_modules/pkg/fn{d}.js", .{i});
        var body_buf: [128]u8 = undefined;
        const body = try std.fmt.bufPrint(&body_buf, "export default function fn{d}() {{ return 'FN_BODY_{d}_MARKER'; }}\n", .{ i, i });
        try writeFile(tmp.dir, name, body);
    }
    try writeFile(tmp.dir, "node_modules/pkg/index.js", barrel_buf.items);

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "FN_BODY_0_MARKER") != null);
    // 49개 unused 모두 drop 검증 (n=1..49)
    var j: usize = 1;
    while (j < 50) : (j += 1) {
        var marker_buf: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "FN_BODY_{d}_MARKER", .{j});
        try std.testing.expect(std.mem.indexOf(u8, result.output, marker) == null);
    }
}

test "TreeShaking #2398: RN .esm wrap + side-effect import 는 본문 보존" {
    // sideEffects 패턴 매칭으로 setup.js 만 side_effects=true 인 케이스. setup.js 가
    // evaluation effect 로 잡혀 보존되어야 함. metadata.zig:438 의 새 `continue` 가드가
    // legitimate init 호출까지 끊지 않는지 회귀 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { val } from 'pkg';
        \\console.log(val);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './setup.js';
        \\export { val } from './val.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/setup.js", "globalThis.__SETUP_RAN__ = 'SIDE_EFFECT_MARKER';");
    try writeFile(tmp.dir, "node_modules/pkg/val.js", "export const val = 'VAL_MARKER';");
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": [\"./setup.js\"]}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "VAL_MARKER") != null);
    // setup.js 는 sideEffects pattern 매칭 → 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "SIDE_EFFECT_MARKER") != null);
}

test "TreeShaking #2398: RN require() 가 .esm wrap target namespace 전체 보존" {
    // markAllExportsUsed 가 .cjs 뿐 아니라 .esm wrap target 에도 적용되는지 검증.
    // 본 fix 전에는 .esm 의 StmtInfo 부재로 자동 보존됐던 동작인데, 본 fix 가
    // StmtInfo 빌드를 활성화하면서 명시 마킹 필요. 빠지면 require() 결과 객체의
    // 일부 property 가 undefined 가 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const lib = require('pkg');
        \\console.log(lib.a, lib.b, lib.c);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export const a = 'A_MARKER';
        \\export const b = 'B_MARKER';
        \\export const c = 'C_MARKER';
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // require() namespace 접근 → 모든 export 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "A_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "B_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "C_MARKER") != null);
}

test "TreeShaking #2398: RN namespace import (`import * as ns`) 가 .esm wrap pure pkg 의 모든 export 보존" {
    // require() 와 대칭 — `import * as ns` 도 어떤 property 가 읽힐지 정적 분석 불가
    // 하므로 namespace 사용 시 모든 export 가 살아야 함. tree_shaker 의 namespace 경로
    // (registerNamespaceRewrites 등) 가 .esm wrap 에도 markAllExportsUsed 적용해야
    // 일부 property 가 undefined 가 되는 회귀 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as ns from 'pkg';
        \\const key = (Math.random() > 0.5) ? 'a' : 'b';
        \\console.log(ns[key], ns.c);
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export const a = 'NS_A_MARKER';
        \\export const b = 'NS_B_MARKER';
        \\export const c = 'NS_C_MARKER';
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace 객체로 사용 → static analysis 불가능 → 보수적으로 모두 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_A_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_B_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_C_MARKER") != null);
}

test "TreeShaking: RN .esm wrap unused namespace re-export drops orphan import init" {
    // Sentry-style barrel:
    //   import * as logger from './logs/public-api.js';
    //   export { logger };
    //
    // If consumers only use another export from the same pure wrapper, the
    // namespace target can be tree-shaken. The original import declaration must
    // be skipped too; otherwise the wrapper body still executes
    // `(init_public_api$N(), __toCommonJS(exports_public_api$N))` even though
    // that target wrapper was not emitted.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import * as logger from './logs/public-api.js';
        \\export { logger };
        \\export function used() { return 'USED_EXPORT_MARKER'; }
    );
    try writeFile(tmp.dir, "node_modules/pkg/logs/public-api.js",
        \\import { capture } from './internal.js';
        \\export { fmt } from '../utils/parameterize.js';
        \\export function debug() { return capture('UNUSED_LOGGER_MARKER'); }
    );
    try writeFile(tmp.dir, "node_modules/pkg/logs/internal.js",
        \\export function capture(value) { return value; }
    );
    try writeFile(tmp.dir, "node_modules/pkg/utils/parameterize.js",
        \\export function fmt(value) { return value; }
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_EXPORT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_LOGGER_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "pkg_logs_public_api") == null);
}

test "TreeShaking: RN .esm wrap used namespace re-export includes namespace target" {
    // `export { logger }` where `logger` is `import * as logger` must keep the
    // namespace source. Otherwise the re-exporting wrapper can be live while its
    // generated import init points at a pruned wrapper.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { logger } from 'pkg';
        \\console.log(logger.debug());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import * as logger from './logs/public-api.js';
        \\export { logger };
    );
    try writeFile(tmp.dir, "node_modules/pkg/logs/public-api.js",
        \\import { capture } from './internal.js';
        \\export { fmt } from '../utils/parameterize.js';
        \\export function debug() { return capture('USED_LOGGER_MARKER'); }
    );
    try writeFile(tmp.dir, "node_modules/pkg/logs/internal.js",
        \\export function capture(value) { return value; }
    );
    try writeFile(tmp.dir, "node_modules/pkg/utils/parameterize.js",
        \\export function fmt(value) { return value; }
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_LOGGER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init_pkg_logs_public_api") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports_pkg_logs_public_api") != null);
}

test "TreeShaking: RN .esm wrap export-star drops getter for pruned source" {
    // `export * from './style.js'` expands into lazy getters on the barrel
    // exports object. If the star source is tree-shaken, those getters must be
    // omitted too; otherwise the live barrel can contain
    // `init_style()` / `exports_style.foo` references to a wrapper that was not
    // emitted in the release bundle.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { used } from 'pkg';
        \\console.log(used());
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\export { used } from './used.js';
        \\export * from './style.js';
    );
    try writeFile(tmp.dir, "node_modules/pkg/used.js",
        \\export function used() { return 'USED_FROM_STAR_BARREL'; }
    );
    try writeFile(tmp.dir, "node_modules/pkg/style.js",
        \\export const unusedStyle = 'UNUSED_STAR_STYLE_MARKER';
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json", "{\"name\": \"pkg\", \"main\": \"index.js\", \"sideEffects\": false}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .tree_shaking = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "USED_FROM_STAR_BARREL") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UNUSED_STAR_STYLE_MARKER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "pkg_style") == null);
}
