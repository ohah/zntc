const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// P1: package.json exports field (통합)
// ============================================================

test "PackageJson: exports string shorthand" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { hello } from 'mypkg';\nconsole.log(hello);");
    try writeFile(tmp.dir, "node_modules/mypkg/package.json",
        \\{ "name": "mypkg", "exports": "./src/index.js" }
    );
    try writeFile(tmp.dir, "node_modules/mypkg/src/index.js", "export const hello = 'from-exports';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-exports\"") != null);
}

test "PackageJson: exports condition import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from 'condpkg';\nconsole.log(val);");
    try writeFile(tmp.dir, "node_modules/condpkg/package.json",
        \\{ "name": "condpkg", "exports": { ".": { "import": "./esm.js", "require": "./cjs.js" } } }
    );
    try writeFile(tmp.dir, "node_modules/condpkg/esm.js", "export const val = 'esm-path';");
    try writeFile(tmp.dir, "node_modules/condpkg/cjs.js", "module.exports = { val: 'cjs-path' };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"esm-path\"") != null);
}

test "PackageJson: subpath exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Button } from 'ui-lib/Button';\nconsole.log(Button);");
    try writeFile(tmp.dir, "node_modules/ui-lib/package.json",
        \\{ "name": "ui-lib", "exports": { "./Button": "./src/Button.js" } }
    );
    try writeFile(tmp.dir, "node_modules/ui-lib/src/Button.js", "export const Button = 'btn-component';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"btn-component\"") != null);
}

test "PackageJson: wildcard exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo } from 'wpkg/utils';\nconsole.log(foo);");
    try writeFile(tmp.dir, "node_modules/wpkg/package.json",
        \\{ "name": "wpkg", "exports": { "./*": "./src/*.js" } }
    );
    try writeFile(tmp.dir, "node_modules/wpkg/src/utils.js", "export const foo = 'wildcard-resolved';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"wildcard-resolved\"") != null);
}

// ============================================================
// P1: package.json module vs main field
// ============================================================

test "PackageJson: module field preferred over main" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from 'dualpkg';\nconsole.log(x);");
    try writeFile(tmp.dir, "node_modules/dualpkg/package.json",
        \\{ "name": "dualpkg", "main": "./cjs.js", "module": "./esm.js" }
    );
    try writeFile(tmp.dir, "node_modules/dualpkg/esm.js", "export const x = 'from-module-field';");
    try writeFile(tmp.dir, "node_modules/dualpkg/cjs.js", "exports.x = 'from-main-field';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-module-field\"") != null);
}

test "PackageJson: main field fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { y } from 'mainonly';\nconsole.log(y);");
    try writeFile(tmp.dir, "node_modules/mainonly/package.json",
        \\{ "name": "mainonly", "main": "./lib.js" }
    );
    try writeFile(tmp.dir, "node_modules/mainonly/lib.js", "export const y = 'from-main';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-main\"") != null);
}

test "PackageJson: react-native platform follows Metro main field order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from 'rnpkg';\nconsole.log(value);");
    try writeFile(tmp.dir, "node_modules/rnpkg/package.json",
        \\{
        \\  "name": "rnpkg",
        \\  "react-native": "./rn.js",
        \\  "browser": "./browser.js",
        \\  "module": "./module.js",
        \\  "main": "./main.js"
        \\}
    );
    try writeFile(tmp.dir, "node_modules/rnpkg/rn.js", "export const value = 'from-react-native';");
    try writeFile(tmp.dir, "node_modules/rnpkg/browser.js", "export const value = 'from-browser';");
    try writeFile(tmp.dir, "node_modules/rnpkg/module.js", "export const value = 'from-module';");
    try writeFile(tmp.dir, "node_modules/rnpkg/main.js", "export const value = 'from-main';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-react-native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-browser\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-module\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-main\"") == null);
}

test "PackageJson: react-native package exports without RN condition matches import" {
    // Metro `unstable_conditionNames: ["react-native"]` + ESM importer 에서
    // `import` / `default` 를 자동 추가하므로, `react-native` 조건이 없어도
    // exports 의 `import` 분기가 우선 매칭된다. main field 의 `react-native`
    // 보다 exports 가 우선.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from 'rnpkg';\nconsole.log(value);");
    try writeFile(tmp.dir, "node_modules/rnpkg/package.json",
        \\{
        \\  "name": "rnpkg",
        \\  "react-native": "./rn.js",
        \\  "main": "./main.js",
        \\  "exports": {
        \\    ".": {
        \\      "import": {
        \\        "types": "./dist/index.d.ts",
        \\        "default": "./dist/index.js"
        \\      },
        \\      "require": {
        \\        "types": "./dist/index.d.cts",
        \\        "default": "./dist/index.cjs"
        \\      }
        \\    }
        \\  }
        \\}
    );
    try writeFile(tmp.dir, "node_modules/rnpkg/rn.js", "export const value = 'from-react-native';");
    try writeFile(tmp.dir, "node_modules/rnpkg/main.js", "export const value = 'from-main';");
    try writeFile(tmp.dir, "node_modules/rnpkg/dist/index.js", "export const value = 'from-import-default';");
    try writeFile(tmp.dir, "node_modules/rnpkg/dist/index.cjs", "module.exports = { value: 'from-require-default' };");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-import-default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-react-native\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-require-default\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-main\"") == null);
}

test "PackageJson: react-native package exports with RN condition wins over import" {
    // 패키지가 `react-native` 조건을 명시했으면 `import` / `default` 보다 우선.
    // Metro 의 conditionNames Set 에서 `react-native` 가 unstable_conditionNames 로
    // 먼저 들어가고, exports 의 키 매칭은 정의 순서를 따른다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { value } from 'rnpkg2';\nconsole.log(value);");
    try writeFile(tmp.dir, "node_modules/rnpkg2/package.json",
        \\{
        \\  "name": "rnpkg2",
        \\  "exports": {
        \\    ".": {
        \\      "react-native": "./dist/index.native.js",
        \\      "import": "./dist/index.js",
        \\      "default": "./dist/index.js"
        \\    }
        \\  }
        \\}
    );
    try writeFile(tmp.dir, "node_modules/rnpkg2/dist/index.native.js", "export const value = 'from-rn-export';");
    try writeFile(tmp.dir, "node_modules/rnpkg2/dist/index.js", "export const value = 'from-import-export';");

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
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-rn-export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-import-export\"") == null);
}

test "Resolver: disableHierarchicalLookup=false (default) finds parent node_modules" {
    // Metro `disableHierarchicalLookup = false` (Node.js 기본 algorithm) — entry 가
    // `packages/app/src/` 에서 import 하면 그 위의 `node_modules` 를 walk-up
    // 탐색해 root 의 `node_modules/lodash` 를 정상 resolve.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "packages/app/src/entry.ts", "import { val } from 'rootonly';\nconsole.log(val);");
    try writeFile(tmp.dir, "node_modules/rootonly/package.json",
        \\{ "name": "rootonly", "main": "./index.js" }
    );
    try writeFile(tmp.dir, "node_modules/rootonly/index.js", "export const val = 'from-root';");

    const entry = try absPath(&tmp, "packages/app/src/entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-root\"") != null);
}

test "Resolver: disableHierarchicalLookup=true blocks parent node_modules walk-up" {
    // Metro `disableHierarchicalLookup = true` — walk-up 차단. entry 의 directory
    // 와 NODE_PATH 만 탐색. 동일 fixture 에서 resolve 실패해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "packages/app/src/entry.ts", "import { val } from 'rootonly';\nconsole.log(val);");
    try writeFile(tmp.dir, "node_modules/rootonly/package.json",
        \\{ "name": "rootonly", "main": "./index.js" }
    );
    try writeFile(tmp.dir, "node_modules/rootonly/index.js", "export const val = 'from-root';");

    const entry = try absPath(&tmp, "packages/app/src/entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .disable_hierarchical_lookup = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // walk-up 차단으로 resolve 실패해야 한다 — root node_modules 에 있어도 못 찾음.
    try std.testing.expect(result.hasErrors());
}

test "Resolver: disableHierarchicalLookup=true still resolves co-located node_modules" {
    // walk-up 차단 시에도 entry 와 같은 디렉토리 (또는 NODE_PATH) 의 node_modules
    // 는 정상 resolve. 같은 워크스페이스 안의 의존성은 평소처럼 작동.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "packages/app/src/entry.ts", "import { val } from 'local';\nconsole.log(val);");
    try writeFile(tmp.dir, "packages/app/src/node_modules/local/package.json",
        \\{ "name": "local", "main": "./index.js" }
    );
    try writeFile(tmp.dir, "packages/app/src/node_modules/local/index.js", "export const val = 'from-local';");

    const entry = try absPath(&tmp, "packages/app/src/entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .disable_hierarchical_lookup = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-local\"") != null);
}

test "PackageJson: no package.json index.js fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { z } from 'nopkg';\nconsole.log(z);");
    try writeFile(tmp.dir, "node_modules/nopkg/index.js", "export const z = 'index-fallback';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"index-fallback\"") != null);
}

// ============================================================
// P1: .mjs/.mts/.cjs/.cts extension handling
// ============================================================

test "Extension: import .mts file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib.mjs';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.mts", "export const x = 'from-mts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-mts\"") != null);
}

test "Extension: import .cts file via .cjs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib.cjs';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.cts", "export const x = 'from-cts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"from-cts\"") != null);
}

test "Extension: direct .mts import without .mjs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './util';\nconsole.log(val);");
    try writeFile(tmp.dir, "util.mts", "export const val = 'mts-direct';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"mts-direct\"") != null);
}

// ============================================================
// P1: Dynamic import() output
// ============================================================

test "DynamicImport: static path in import()" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const lazy = import('./lazy');
        \\lazy.then(m => console.log(m));
    );
    try writeFile(tmp.dir, "lazy.ts", "export const data = 'lazy-loaded';\nconsole.log(data);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // 단일 번들 모드에서 lazy 모듈 코드가 포함되어야 함
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"lazy-loaded\"") != null);
}

test "DynamicImport: external dynamic import preserved" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const ext = import('external-pkg');
        \\ext.then(console.log);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"external-pkg"},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

// (#4595) 단일 번들(splitting/preserve-modules 모두 false)에서 dynamic import 가 인라인되지
// 않고 원문 `import("./dep")` 그대로 새어나가던 회귀 가드. 이 조합에서는 청크로 분리할 수단이
// 없으므로 인라인만이 유일한 처리다. Bundler.init 이 진입점 무관하게 불변식을 강제한다(#4595
// 이전엔 CLI 프론트엔드만 승격 → NAPI/app 경로 누락). esbuild(splitting:false)·rolldown
// (codeSplitting:false) 동작과 동일. 기존 "static path" 테스트는 target 코드 존재만 봤는데,
// side-effect 있는 모듈은 미인라인 깨진 번들에서도 문자열이 남아 통과했다 — 여기선 호출
// 재작성까지 단언한다(side-effect 없는 순수 export 라 미인라인이면 tree-shake 로 사라짐).
test "DynamicImport: single-bundle inlines dynamic import — no raw import() leaks (#4595)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\export async function run() {
        \\  const m = await import('./dep');
        \\  return m.value;
        \\}
    );
    try writeFile(tmp.dir, "dep.ts", "export const value = 'LOADED-4595';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    // splitting/preserve-modules 미지정(기본 false) = 이슈 #4595 의 정확한 조합.
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // (1) dynamic target 코드가 번들에 인라인되어 있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "LOADED-4595") != null);
    // (2) 원문 dynamic import 호출이 재작성되어 남아있으면 안 된다(런타임 깨짐 방지).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import(\"./dep\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import('./dep')") == null);
    // (3) __esm 래퍼 init/exports lazy 호출로 인라인(esbuild/rolldown splitting:false 형태).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Promise.resolve().then") != null);
}

test "DynamicImport: combined with static import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './shared';
        \\const lazy = import('./shared');
        \\console.log(x);
        \\lazy.then(m => console.log(m));
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared-val';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"shared-val\"") != null);
}

// ============================================================
// P1: CJS/IIFE format exports with scope hoisting
// ============================================================

test "Format: CJS scope_hoist entry exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { helper } from './helper';
        \\export const result = helper();
        \\export function getResult() { return result; }
    );
    try writeFile(tmp.dir, "helper.ts", "export function helper() { return 42; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "\"use strict\";\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper") != null);
}

test "Format: IIFE scope_hoist entry exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './dep';
        \\export const doubled = value * 2;
    );
    try writeFile(tmp.dir, "dep.ts", "export const value = 21;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(() => {\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const doubled = 42;") != null);
}

// ============================================================
// P2: export default anonymous expression
// ============================================================

// "Default: anonymous object default export imported" — 기존 "Default: default export object literal"과 중복으로 제거

test "Default: anonymous string default export imported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import greeting from './greeting';
        \\console.log(greeting);
    );
    try writeFile(tmp.dir, "greeting.ts", "export default 'hello world';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello world\"") != null);
}

// ============================================================
// P2: export { X as default }
// ============================================================

test "Default: export named as default then import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import def from './mod';
        \\console.log(def);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\const X = 'named-as-default';
        \\export { X as default };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"named-as-default\"") != null);
}

// ============================================================
// P2: namespace import (import * as ns)
// ============================================================

test "Namespace: import * as ns usage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as utils from './utils';
        \\console.log(utils.add(1, 2), utils.sub(3, 1));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export function add(a: number, b: number) { return a + b; }
        \\export function sub(a: number, b: number) { return a - b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function add") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function sub") != null);
}

test "Namespace: import * combined with named import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as math from './math';
        \\import { PI } from './math';
        \\console.log(math.add(1, 2), PI);
    );
    try writeFile(tmp.dir, "math.ts",
        \\export const PI = 3.14;
        \\export function add(a: number, b: number) { return a + b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "3.14") != null);
}

// ============================================================
// P2: scoped packages (@scope/pkg)
// ============================================================

test "Resolution: scoped package @scope/pkg" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { thing } from '@myorg/utils';\nconsole.log(thing);");
    try writeFile(tmp.dir, "node_modules/@myorg/utils/package.json",
        \\{ "name": "@myorg/utils", "main": "./index.js" }
    );
    try writeFile(tmp.dir, "node_modules/@myorg/utils/index.js", "export const thing = 'scoped-pkg';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"scoped-pkg\"") != null);
}

// ============================================================
// P2: JSON import
// ============================================================

test "Resolution: JSON file import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import data from './data.json';\nconsole.log(data);");
    try writeFile(tmp.dir, "data.json",
        \\{ "name": "test", "version": "1.0.0" }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // JSON import는 에러 없이 번들 생성 (내용 포함 여부는 구현에 따라)
    try std.testing.expect(!result.hasErrors());
}

test "JSON import: ESM format uses scope-hoisted var (linker integration)" {
    // linker 포함 통합 테스트: ESM 포맷에서 JSON → ESM AST로 변환되어
    // export default → var 할당 형태로 출력되는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import data from './data.json';\nconsole.log(data.key);");
    try writeFile(tmp.dir, "data.json",
        \\{"key":"value"}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // JSON ESM: named export 변수로 출력, __commonJS 래핑 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__commonJS") == null);
}

test "JSON import: named exports from top-level object keys" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { name, version } from './app.json';\nconsole.log(name, version);");
    try writeFile(tmp.dir, "app.json",
        \\{"name":"ExampleApp","version":1}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // named export 변수가 출력에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ExampleApp") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log(name") != null);
}

test "JSON import: named exports + default export coexist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config, { name } from './config.json';
        \\console.log(name, config);
    );
    try writeFile(tmp.dir, "config.json",
        \\{"name":"test","debug":true}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"test\"") != null);
}

test "JSON require: CJS consumer emits default object without duplicate named exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.cjs",
        \\const version = require('./package.json').version;
        \\console.log(version);
    );
    try writeFile(tmp.dir, "package.json",
        \\{
        \\  "name": "fixture",
        \\  "version": "1.2.3",
        \\  "scripts": { "test": "zntc" },
        \\  "devDependencies": { "zntc": "workspace:*" }
        \\}
    );

    const entry = try absPath(&tmp, "entry.cjs");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "module.exports") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.name") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.scripts") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exports.devDependencies") == null);
}

test "JSON import: non-object JSON has no named exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import arr from './data.json';\nconsole.log(arr);");
    try writeFile(tmp.dir, "data.json", "[1, 2, 3]");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "IIFE globalName: export → return 변환 (linker integration)" {
    // IIFE + globalName에서 엔트리 export가 "return { ... }" 형태로 출력되는지 검증.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const answer = 42;\nexport const name = \"test\";");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .global_name = "MyLib",
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // IIFE prologue: var MyLib = (() => {
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var MyLib = (() =>") != null);
    // 엔트리 export가 return으로 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "return {") != null);
    // export 키워드가 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export {") == null);
}

// ============================================================
// P2: multi-level rename re-export chain
// ============================================================

// "Re-export: three-level rename chain" — 기존 "Re-export: rename chain (A→B→C→D)"와 중복으로 제거

// ============================================================
// P3: nested scope conflict avoidance
// ============================================================

test "Deconflict: rename avoids nested scope variable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈이 'x'를 top-level에 가짐 → 리네임 발생
    // entry에는 함수 안에 'x$1'이 있음 → 리네임이 x$1을 피해야 함
    try writeFile(tmp.dir, "entry.ts",
        \\import './other';
        \\const x = 'entry-x';
        \\function inner() { const x$1 = 'nested'; return x$1; }
        \\console.log(x, inner());
    );
    try writeFile(tmp.dir, "other.ts", "const x = 'other-x';\nconsole.log(x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"entry-x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"other-x\"") != null);
}

// ============================================================
// P3: long re-export chain (10 levels)
// ============================================================

test "Re-export: 10-level chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './r1';\nconsole.log(val);");
    try writeFile(tmp.dir, "r1.ts", "export { val } from './r2';");
    try writeFile(tmp.dir, "r2.ts", "export { val } from './r3';");
    try writeFile(tmp.dir, "r3.ts", "export { val } from './r4';");
    try writeFile(tmp.dir, "r4.ts", "export { val } from './r5';");
    try writeFile(tmp.dir, "r5.ts", "export { val } from './r6';");
    try writeFile(tmp.dir, "r6.ts", "export { val } from './r7';");
    try writeFile(tmp.dir, "r7.ts", "export { val } from './r8';");
    try writeFile(tmp.dir, "r8.ts", "export { val } from './r9';");
    try writeFile(tmp.dir, "r9.ts", "export { val } from './r10';");
    try writeFile(tmp.dir, "r10.ts", "export const val = 'deep-10';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deep-10\"") != null);
}

// ============================================================
// P3: multi-entry + scope hoist + name conflicts
// ============================================================

test "MultiEntry: scope hoist with shared dep name conflict" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "e1.ts",
        \\import { shared } from './shared';
        \\const name = 'e1';
        \\console.log(name, shared);
    );
    try writeFile(tmp.dir, "e2.ts",
        \\import { shared } from './shared';
        \\const name = 'e2';
        \\console.log(name, shared);
    );
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';\nconst name = 'shared';");

    const entry1 = try absPath(&tmp, "e1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "e2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3개 모듈의 'name' 충돌 → 리네임
    try std.testing.expect(std.mem.indexOf(u8, result.output, "name$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"common\"") != null);
}

// ============================================================
// P3: empty export {} with scope hoist
// ============================================================

test "Export: empty export {} stripped in scope hoist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './sideeffect';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "sideeffect.ts",
        \\console.log('side');
        \\export {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"side\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"main\"") != null);
    // export {} 가 번들에 남아있으면 안 됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export {}") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "export{}") == null);
}

// ============================================================
// P3: import type full strip verification
// ============================================================

test "TypeScript: import type fully stripped in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type User } from './types';
        \\import { greet } from './greet';
        \\const u: User = { name: 'Alice' };
        \\console.log(greet(u.name));
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface User { name: string; }
        \\export interface Post { title: string; }
    );
    try writeFile(tmp.dir, "greet.ts", "export function greet(name: string) { return 'Hello ' + name; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // interface 완전 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    // greet 함수는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet") != null);
}

// ============================================================
// type-only import elision — linker preamble skip (#1791)
// type 위치에서만 쓰이는 binding 은 `buildMetadataForAst` 의 import_bindings
// 루프가 skip → preamble 에 bare `require()` 가 생성되지 않아야 한다.
// transformer 단의 specifier elision 과 대칭.
// ============================================================

test "TypeScript: external + type-only usage → preamble require skip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { HeaderBarButtonItem, Used } from "external-types";
        \\export function f(x: HeaderBarButtonItem): void {}
        \\export const v = Used();
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"external-types"},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 회귀 시 `var HeaderBarButtonItem = require("external-types").HeaderBarButtonItem;`
    // 가 factory 스코프에서 ReferenceError 를 냄 — bungae RN 0.83 crash.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "HeaderBarButtonItem") == null);
    // 값으로 쓰인 Used 는 ESM external import 로 보존 (#1962). type-only elision 후 남은 binding.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Used") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"external-types\"") != null);
}

test "TypeScript: verbatimModuleSyntax=true preserves external type-only preamble" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { TypeAlpha, useValue } from "external-lib";
        \\export function f(x: TypeAlpha): void { useValue(); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"external-lib"},
        .verbatim_module_syntax = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 사용자가 명시적으로 보존을 요청 → 두 binding 모두 ESM import 로 남아야 함 (#1962).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TypeAlpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "useValue") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"external-lib\"") != null);
}

test "TypeScript: external + export re-export → preamble require 유지 (#1793 revert 원인)" {
    // `import { X } from 'ext'; export { X };` 에서 X 는 analyzer 가 value 참조로
    // 등록해야 Phase D 가 drop 하지 않음. #1793 revert 의 직접 실패 경로.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { ExportMe } from "external-pkg";
        \\export { ExportMe };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"external-pkg"},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM external (#1962): import 구문 보존 + re-export 가 ExportMe 식별자를 통해 동작.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ExportMe") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"external-pkg\"") != null);
}

test "TypeScript: external + namespace member access → preamble 유지 (namespace 는 elision 제외)" {
    // `import * as React; React.forwardRef()` — Phase D 는 namespace 를 elision 대상에서
    // 제외. bungae 의 React$250='19.2.0' crash 회귀 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import * as React from "react";
        \\export const Slot = React.forwardRef((a: any, r: any) => null);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react"},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // namespace import 는 preamble 에 유지되어 React.forwardRef 호출 가능.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "React") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "forwardRef") != null);
}

test "TypeScript: external + default import → Phase D 는 default 를 elide 하지 않음" {
    // JSX pragma / CSS-in-JS default export 등 implicit value use 가 많아 default 는
    // elision 제외. 회귀 방지.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import DefaultX from "external-mod";
        \\export function f(x: DefaultX): void {}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"external-mod"},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // ESM external (#1962): default import 도 보존 — `import DefaultX from "external-mod"`.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DefaultX") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"external-mod\"") != null);
}

test "TypeScript: external + named mixed → type-only 만 elide, value-used 유지" {
    // Phase D 의 핵심 기능 — bundle 레벨에서 confirm.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { TypeX, UtilY, TypeZ } from "external-kit";
        \\export function f(a: TypeX, b: TypeZ): void {}
        \\export const v = UtilY();
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"external-kit"},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // value-used 만 ESM external import 에 남음 (#1962). Phase D type-only elision 결과.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "UtilY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from \"external-kit\"") != null);
    // type-only 는 elide 되어 출력에 없음.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TypeX") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TypeZ") == null);
}

/// tsconfig `paths` 회귀 테스트 공통 스캐폴드 — `<key_prefix>*` 를 `<root>/src/*` 한 벌로 매핑하고
/// entry 를 번들해 산출물 복사본을 돌려준다. 호출자에는 픽스처 작성과 단언만 남는다.
/// 스캐폴드를 테스트마다 복붙하면 `Bundler.init` 옵션이나 `PathEntry` 모양이 바뀔 때 한 벌만
/// 고쳐도 나머지가 조용히 약한 가드로 남는다.
const TsPathsBundle = struct {
    output: []u8,
    has_errors: bool,

    fn deinit(self: TsPathsBundle) void {
        std.testing.allocator.free(self.output);
    }
    fn has(self: TsPathsBundle, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }
};

fn bundleWithTsPaths(tmp: *std.testing.TmpDir, entry_rel: []const u8, key_prefix: []const u8) !TsPathsBundle {
    const root = try absPath(tmp, ".");
    defer std.testing.allocator.free(root);
    const src_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/src/", .{root});
    defer std.testing.allocator.free(src_prefix);

    const targets = [_]@import("../../config.zig").TsConfig.PathEntry.Target{
        .{ .prefix = src_prefix, .suffix = "" },
    };
    const paths = [_]@import("../../config.zig").TsConfig.PathEntry{
        .{ .key_prefix = key_prefix, .key_suffix = "", .has_wildcard = true, .targets = &targets },
    };

    const entry = try absPath(tmp, entry_rel);
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .ts_paths = &paths,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    return .{
        .output = try std.testing.allocator.dupe(u8, result.output),
        .has_errors = result.hasErrors(),
    };
}

// (#4603) tsconfig `paths` 는 **non-relative specifier 에만** 적용된다. 가드가 없으면 catch-all
// 매핑(`"paths": { "*": ["src/*"] }` — 실사용 패턴) 이 형제 파일 import 까지 가로채, 사용자가
// 의도한 모듈 대신 **다른 모듈이 조용히 번들된다**(export 가 없으면 런타임 TypeError).
test "tsconfig paths: catch-all 매핑이 상대 import 를 가로채지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "src/config.ts", "export const cfg = () => \"TS_PATHS_ROOT_MARKER\";");
    try writeFile(tmp.dir, "src/workers/config.ts", "export const cfg = () => \"TS_PATHS_SIBLING_MARKER\";");
    try writeFile(tmp.dir, "src/workers/main.ts",
        \\import { cfg } from './config';
        \\console.log(cfg());
    );

    const result = try bundleWithTsPaths(&tmp, "src/workers/main.ts", "");
    defer result.deinit();

    try std.testing.expect(!result.has_errors);
    // 형제 파일이 해석돼야 한다.
    try std.testing.expect(result.has("TS_PATHS_SIBLING_MARKER"));
    try std.testing.expect(!result.has("TS_PATHS_ROOT_MARKER"));
}

// 기능 보존 — 비-relative specifier 에는 paths 가 그대로 적용돼야 한다.
test "tsconfig paths: 비-relative specifier 는 계속 매핑된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "src/config.ts", "export const cfg = () => \"TS_PATHS_ROOT_MARKER\";");
    try writeFile(tmp.dir, "src/workers/main.ts",
        \\import { cfg } from '@/config';
        \\console.log(cfg());
    );

    const result = try bundleWithTsPaths(&tmp, "src/workers/main.ts", "@/");
    defer result.deinit();

    try std.testing.expect(!result.has_errors);
    try std.testing.expect(result.has("TS_PATHS_ROOT_MARKER"));
}

// (#4603) rooted specifier(`/@/*`) 매핑은 실사용 패턴이므로 계속 동작해야 한다. relative 판정에
// `/` 까지 묶으면 그런 프로젝트가 전면 빌드 실패한다.
//
// 술어를 `isRelativeOrAbsolute`(= `/` 도 배제)로 되돌리면 이 테스트가 실패한다 — A/B 확인.
test "tsconfig paths: rooted specifier(/@/*) 매핑은 계속 동작한다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "src/utils.ts", "export const u = () => \"TS_PATHS_ROOTED_MARKER\";");
    try writeFile(tmp.dir, "src/main.ts",
        \\import { u } from '/@/utils';
        \\console.log(u());
    );

    const result = try bundleWithTsPaths(&tmp, "src/main.ts", "/@/");
    defer result.deinit();

    try std.testing.expect(!result.has_errors);
    try std.testing.expect(result.has("TS_PATHS_ROOTED_MARKER"));
}

// (#4603) 상대 specifier 에는 paths 를 **적용하지 않는다** — 형제 파일이 없으면 폴백 없이
// 해석 실패다. "실패하면 paths 로 구제" 를 두면 상대 키가 죽은 설정이 됐다는 사실이 영원히
// 감춰지고, 어느 참조 구현에도 없는 zntc 만의 세 번째 의미가 된다.
test "tsconfig paths: 형제 파일이 없는 상대 import 는 paths 로 구제되지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 형제 `src/workers/config.ts` 는 **일부러 만들지 않는다** — catch-all 이 구제하면 안 된다.
    try writeFile(tmp.dir, "src/config.ts", "export const cfg = () => \"TS_PATHS_NO_FALLBACK_MARKER\";");
    try writeFile(tmp.dir, "src/workers/main.ts",
        \\import { cfg } from './config';
        \\console.log(cfg());
    );

    const result = try bundleWithTsPaths(&tmp, "src/workers/main.ts", "");
    defer result.deinit();

    // 해석 실패가 진단으로 드러나야 하고, 엉뚱한 모듈이 번들되면 안 된다.
    try std.testing.expect(result.has_errors);
    try std.testing.expect(!result.has("TS_PATHS_NO_FALLBACK_MARKER"));
}

// (#4603) 동적 import 는 해석 실패가 **warning** 이라 실패해도 빌드가 green 이고 원문이 그대로
// 나간다(런타임 404). 그래서 정적 import 테스트만으로는 catch-all hijack 회귀를 못 잡는다 —
// 이 kind 로도 "형제 우선" 을 고정한다.
test "tsconfig paths: catch-all 이 동적 import 의 상대 지정자도 가로채지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "src/analytics.ts", "export const a = () => \"TS_PATHS_DYN_ROOT\";");
    try writeFile(tmp.dir, "src/pages/analytics.ts", "export const a = () => \"TS_PATHS_DYN_SIBLING\";");
    try writeFile(tmp.dir, "src/pages/home.ts",
        \\export async function load() {
        \\  const m = await import('./analytics');
        \\  return m.a();
        \\}
        \\console.log(load);
    );

    const result = try bundleWithTsPaths(&tmp, "src/pages/home.ts", "");
    defer result.deinit();

    try std.testing.expect(!result.has_errors);
    // 형제가 인라인돼야 한다 — root 쪽이 들어오면 hijack 회귀.
    try std.testing.expect(result.has("TS_PATHS_DYN_SIBLING"));
    try std.testing.expect(!result.has("TS_PATHS_DYN_ROOT"));
}

// (#4603) 엔트리 선택은 TS/esbuild 의 specificity 규칙 — exact 키가 wildcard 를 이기고,
// wildcard 끼리는 최장 prefix 가 이긴다. 선언 순서(JSON 키 순서)에 의존하면 안 된다:
// 같은 소스·같은 매핑인데 키 순서만 바꾸면 다른 모듈이 번들되던 상태였다.
test "tsconfig paths: exact 키가 catch-all 을 이기고 선언 순서에 의존하지 않는다" {
    for ([_]bool{ false, true }) |catch_all_first| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFile(tmp.dir, "src/shim.ts", "export const s = () => \"TS_PATHS_CATCHALL_TARGET\";");
        try writeFile(tmp.dir, "lib/real-shim.ts", "export const s = () => \"TS_PATHS_EXACT_TARGET\";");
        try writeFile(tmp.dir, "src/main.ts",
            \\import { s } from 'shim';
            \\console.log(s());
        );

        const root = try absPath(&tmp, ".");
        defer std.testing.allocator.free(root);
        const src_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/src/", .{root});
        defer std.testing.allocator.free(src_prefix);
        const exact_target = try std.fmt.allocPrint(std.testing.allocator, "{s}/lib/real-shim.ts", .{root});
        defer std.testing.allocator.free(exact_target);

        const catch_targets = [_]@import("../../config.zig").TsConfig.PathEntry.Target{
            .{ .prefix = src_prefix, .suffix = "" },
        };
        const exact_targets = [_]@import("../../config.zig").TsConfig.PathEntry.Target{
            .{ .prefix = exact_target, .suffix = "" },
        };
        const catch_entry = @import("../../config.zig").TsConfig.PathEntry{
            .key_prefix = "",
            .key_suffix = "",
            .has_wildcard = true,
            .targets = &catch_targets,
        };
        const exact_entry = @import("../../config.zig").TsConfig.PathEntry{
            .key_prefix = "shim",
            .key_suffix = "",
            .has_wildcard = false,
            .targets = &exact_targets,
        };
        const paths = if (catch_all_first)
            [_]@import("../../config.zig").TsConfig.PathEntry{ catch_entry, exact_entry }
        else
            [_]@import("../../config.zig").TsConfig.PathEntry{ exact_entry, catch_entry };

        const entry = try absPath(&tmp, "src/main.ts");
        defer std.testing.allocator.free(entry);

        var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .ts_paths = &paths });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        // 선언 순서와 무관하게 exact 키가 이겨야 한다.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "TS_PATHS_EXACT_TARGET") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "TS_PATHS_CATCHALL_TARGET") == null);
    }
}

// (#4603) 엔트리 선택은 **하나**다 — 더 구체적인 키가 매칭됐는데 그 targets 가 디스크에 없으면
// 덜 구체적인 키가 구제하지 않는다(tsc 동일). 이 계약은 previously-green 을 hard-fail 로 바꿀 수
// 있는 유일한 변경인데 테스트가 없었다: `for (ts_paths) |entry| { for (entry.targets) }` 식
// fall-through 를 되살려도 스위트가 전부 통과했다.
test "tsconfig paths: 구체적 키가 매칭되면 catch-all 이 구제하지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // catch-all 로는 해석되지만, 더 구체적인 `shim` 키의 target 은 존재하지 않는다.
    try writeFile(tmp.dir, "src/shim.ts", "export const s = () => \"CATCHALL_RESCUE\";");
    try writeFile(tmp.dir, "src/main.ts",
        \\import { s } from 'shim';
        \\console.log(s());
    );

    const root = try absPath(&tmp, ".");
    defer std.testing.allocator.free(root);
    const src_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/src/", .{root});
    defer std.testing.allocator.free(src_prefix);
    const missing = try std.fmt.allocPrint(std.testing.allocator, "{s}/nowhere/gone.ts", .{root});
    defer std.testing.allocator.free(missing);

    const catchall_targets = [_]@import("../../config.zig").TsConfig.PathEntry.Target{
        .{ .prefix = src_prefix, .suffix = "" },
    };
    const exact_targets = [_]@import("../../config.zig").TsConfig.PathEntry.Target{
        .{ .prefix = missing, .suffix = "" },
    };
    const paths = [_]@import("../../config.zig").TsConfig.PathEntry{
        .{ .key_prefix = "", .key_suffix = "", .has_wildcard = true, .targets = &catchall_targets },
        .{ .key_prefix = "shim", .key_suffix = "", .has_wildcard = false, .targets = &exact_targets },
    };

    const entry = try absPath(&tmp, "src/main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .ts_paths = &paths });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // exact 키가 이겼고, 그 target 이 없으므로 해석 실패여야 한다.
    try std.testing.expect(result.hasErrors());
    // catch-all 이 구제해서 다른 모듈이 조용히 들어오면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "CATCHALL_RESCUE") == null);
}
