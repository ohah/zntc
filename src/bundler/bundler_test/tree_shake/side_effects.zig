const std = @import("std");
const Bundler = @import("../../bundler.zig").Bundler;
const test_helpers = @import("../../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// package.json sideEffects integration tests
// ============================================================

test "sideEffects: package.json sideEffects=false auto-applied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './node_modules/mypkg/index.js'; console.log('entry');");
    try writeFile(tmp.dir, "node_modules/mypkg/package.json",
        \\{"name":"mypkg","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/mypkg/index.js", "export const x = 1; console.log('should be removed');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "should be removed") == null);
}

test "sideEffects: package.json sideEffects=true keeps module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './node_modules/polyfill/index.js'; console.log('entry');");
    try writeFile(tmp.dir, "node_modules/polyfill/package.json",
        \\{"name":"polyfill","sideEffects":true}
    );
    try writeFile(tmp.dir, "node_modules/polyfill/index.js", "globalThis.polyfilled = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "polyfilled") != null);
}

test "sideEffects: no package.json field keeps default true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './node_modules/nopkg/index.js';");
    try writeFile(tmp.dir, "node_modules/nopkg/package.json",
        \\{"name":"nopkg"}
    );
    try writeFile(tmp.dir, "node_modules/nopkg/index.js", "console.log('included');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "included") != null);
}

test "sideEffects: side-effect-only import to ESM module under __esm wrap invokes init (#1193)" {
    // Reanimated `layoutReanimation/index.ts`: `import './animationsManager'` +
    // `export * from './animationBuilder'`. animationsManager.ts는 ESM 모듈이며
    // RN 플랫폼에서 __esm 래핑된다. barrel(index.ts) factory body가 side-effect
    // import 대상의 init 함수를 호출하지 않으면 top-level side-effect가 실행되지
    // 않아 `global.LayoutAnimationsManager` 할당 누락 → UI Hermes SIGABRT.
    //
    // 주의: sideeffect 모듈이 CJS로 감지되면 기존 body rewrite가 require를 호출
    // 하므로 버그가 드러나지 않는다. .ts + export를 포함해 ESM으로 만들어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "pkg/index.ts",
        \\import './sideeffect';
        \\export * from './values';
    );
    try writeFile(tmp.dir, "pkg/values.ts",
        \\export const x = 1;
    );
    try writeFile(tmp.dir, "pkg/sideeffect.ts",
        \\export {};
        \\globalThis.sideEffectRan = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // side-effect 본문이 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "sideEffectRan") != null);

    // barrel(index.ts) init 함수 안에서 sideeffect ESM init이 호출되어야 한다.
    const index_init_start = std.mem.indexOf(u8, result.output, "var init_index = __esm") orelse
        return error.IndexInitMissing;
    const index_init_end_off = std.mem.indexOfPos(u8, result.output, index_init_start, "})") orelse
        return error.IndexInitMalformed;
    const index_init_block = result.output[index_init_start .. index_init_end_off + 2];
    try std.testing.expect(std.mem.indexOf(u8, index_init_block, "init_sideeffect()") != null);
}

test "sideEffects: CJS side-effect import must not be duplicated in barrel init (#1193)" {
    // #1193 fix 후속: CJS 타겟은 body rewrite가 이미 require_xxx()를 주입하므로
    // side-effect import 전용 preamble 루프는 ESM 타겟만 처리해야 한다.
    // 중복 호출은 side-effect가 두 번 실행되는 동작 회귀를 일으킬 수 있음.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"./index.js","sideEffects":["./sideeffect.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './sideeffect';
        \\export * from './values';
    );
    try writeFile(tmp.dir, "node_modules/pkg/values.js",
        \\export const x = 1;
    );
    try writeFile(tmp.dir, "node_modules/pkg/sideeffect.js",
        \\globalThis.sideEffectRan = true;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    const index_init_start = std.mem.indexOf(u8, result.output, "var init_pkg_index = __esm") orelse
        return error.IndexInitMissing;
    const index_init_end_off = std.mem.indexOfPos(u8, result.output, index_init_start, "})") orelse
        return error.IndexInitMalformed;
    const index_init_block = result.output[index_init_start .. index_init_end_off + 2];
    const count = std.mem.count(u8, index_init_block, "require_pkg_sideeffect()");
    try std.testing.expectEqual(@as(usize, 1), count);
}

// ============================================================
// UserDefined sideEffects lock — rolldown DeterminedSideEffects::UserDefined parity
// ============================================================

test "sideEffects: UserDefined lock — package.json sideEffects array MUST NOT be overridden by auto-purity" {
    // React-native-worklets의 lib/module/index.js는 top-level에서 init() 호출 (side-effect).
    // 근데 `import` + `function_call()`만 있는 파일은 ZNTC auto-purity 로직이 "pure"로 오판할 수도.
    // package.json의 sideEffects 배열에 명시된 파일은 auto-purity가 덮어쓰면 안 됨.
    // 이 테스트는 해당 regression을 방지한다 (#1193 root cause).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/pkg';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/pkg/package.json",
        \\{"name":"pkg","main":"./index.js","sideEffects":["./runtime-init.js"]}
    );
    try writeFile(tmp.dir, "node_modules/pkg/index.js",
        \\import './runtime-init';
        \\export const x = 1;
    );
    // runtime-init.js는 top-level에서 globalInit() 호출.
    // 호출 자체는 auto-purity 기준으로 "pure"로 보일 수 있지만 (function call on unknown binding),
    // sideEffects array에 명시됐으므로 반드시 보존되어야 한다.
    try writeFile(tmp.dir, "node_modules/pkg/runtime-init.js",
        \\import { globalInit } from './helper';
        \\globalInit();
    );
    try writeFile(tmp.dir, "node_modules/pkg/helper.js",
        \\export function globalInit() { globalThis.__runtimeInitialized = true; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // runtime-init.js body가 번들에 포함되어야 한다
    try std.testing.expect(std.mem.indexOf(u8, result.output, "globalInit()") != null);
    // 게다가 top-level init 경로에서 실행 가능해야 한다 — 단순 정의 외에 호출 라인이 있어야 함
    // (RN 플랫폼에서는 __esm wrap의 factory body에 globalInit() 있어야)
    const has_call = std.mem.count(u8, result.output, "globalInit()") >= 2;
    try std.testing.expect(has_call);
}

test "sideEffects: UserDefined lock — sideEffects:false module stays tree-shakable even if complex" {
    // 반대 방향 회귀: sideEffects:false는 auto-purity와 일치 — lock이 잘못 걸리면 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './node_modules/lib';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "node_modules/lib/package.json",
        \\{"name":"lib","main":"./index.js","sideEffects":false}
    );
    try writeFile(tmp.dir, "node_modules/lib/index.js",
        \\export const x = 1;
        \\export const unused = 2;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1") != null);
}

test "sideEffects: UserDefined lock — auto-purity does not flip package.json true to false" {
    // `sideEffects: true` (array 아님)도 user_defined 설정.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './node_modules/preserve';
    );
    try writeFile(tmp.dir, "node_modules/preserve/package.json",
        \\{"name":"preserve","sideEffects":true}
    );
    // body는 pure literal만 — auto-purity가 보면 "pure"라고 판단할 텍스트.
    try writeFile(tmp.dir, "node_modules/preserve/index.js",
        \\const PURE_CONST = 42;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // sideEffects:true로 명시된 순수 module도 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "sideEffects: UserDefined lock — pattern matched file preserved even in node_modules with other pure modules" {
    // react-native-worklets 실제 구조 흉내: sideEffects에 특정 파일만 나열.
    // 매치되는 파일의 top-level call은 보존, 매치 안 되는 pure 파일은 tree-shake.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { api } from './node_modules/worklets';
        \\console.log(api);
    );
    try writeFile(tmp.dir, "node_modules/worklets/package.json",
        \\{"name":"worklets","main":"./index.js","sideEffects":["./index.js","./init.js"]}
    );
    try writeFile(tmp.dir, "node_modules/worklets/index.js",
        \\import { init } from './init';
        \\import { api } from './api';
        \\init();
        \\export { api };
    );
    try writeFile(tmp.dir, "node_modules/worklets/init.js",
        \\export function init() { globalThis.__workletsReady = true; }
    );
    try writeFile(tmp.dir, "node_modules/worklets/api.js",
        \\export const api = 'ok';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // index.js의 `init();` call이 번들에 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "init()") != null);
    // api 사용도 보존
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"ok\"") != null or
        std.mem.indexOf(u8, result.output, "'ok'") != null);
}
