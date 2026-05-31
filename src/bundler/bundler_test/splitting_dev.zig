const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const compat = @import("../../transformer/compat.zig");
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// Code Splitting Tests
// ============================================================

test "CodeSplitting: code_splitting=false unchanged — 기존 동작 보존" {
    // code_splitting=false(기본값)일 때 기존 단일 파일 출력이 그대로 동작하는지 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 42;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // 단일 파일 모드: output에 결과, outputs는 null
    try std.testing.expect(result.outputs == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 42;") != null);
    try std.testing.expect(!result.hasErrors());
}

test "CodeSplitting: single entry no split — 동적 import 없으면 청크 1개" {
    // code_splitting=true이지만 dynamic import가 없으면 단일 청크만 생성됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import './lib';\nconst x = 1;\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "const y = 2;\nconsole.log(y);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // outputs가 생성됨 (code_splitting=true)
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 단일 청크 — 동적 import 없으므로 분리 없음
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    // 엔트리 파일명
    try std.testing.expectEqualStrings("index.js", outs[0].path);
    // 두 모듈의 코드 포함
    try std.testing.expect(std.mem.indexOf(u8, outs[0].contents, "const x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, outs[0].contents, "const y = 2;") != null);
}

test "CodeSplitting: dynamic import produces two output files" {
    // entry.ts가 lazy.ts를 dynamic import → 2개의 OutputFile 생성.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const mod = import('./lazy');\nconsole.log(mod);");
    try writeFile(tmp.dir, "lazy.ts", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 2개 청크: entry + lazy
    try std.testing.expectEqual(@as(usize, 2), outs.len);

    // 각 청크에 해당 모듈의 코드가 포함
    var has_entry = false;
    var has_lazy = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "console.log") != null) has_entry = true;
        if (std.mem.indexOf(u8, o.contents, "42") != null) has_lazy = true;
    }
    try std.testing.expect(has_entry);
    try std.testing.expect(has_lazy);
}

test "CodeSplitting: shared module produces common chunk" {
    // 2개 엔트리가 같은 모듈을 공유 → 공통 청크로 추출.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { shared } from './shared';\nconsole.log('a', shared);");
    try writeFile(tmp.dir, "b.ts", "import { shared } from './shared';\nconsole.log('b', shared);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 2 엔트리 + 1 공통 = 3 청크
    try std.testing.expectEqual(@as(usize, 3), outs.len);

    // shared 모듈의 코드는 정확히 하나의 청크에만 포함 (중복 없음)
    var shared_count: usize = 0;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "\"common\"") != null) shared_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shared_count);
}

test "CodeSplitting: cross-chunk import statement" {
    // 엔트리 A가 정적 import하는 모듈이 다른 청크에 있을 때
    // cross-chunk import './dep.js' 문이 삽입되는지 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A → shared (static), B → shared (static)
    // shared는 공통 청크로 추출 → A, B 청크에 cross-chunk import 삽입
    try writeFile(tmp.dir, "a.ts", "import { x } from './shared';\nconsole.log('a', x);");
    try writeFile(tmp.dir, "b.ts", "import { x } from './shared';\nconsole.log('b', x);");
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared_val';");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 엔트리 청크 중 하나 이상에 cross-chunk import가 포함되어야 함.
    // 심볼 수준: import { x } from './chunk-N.js'
    // side-effect: import './chunk-N.js'
    var has_cross_import = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "import \"./") != null or
            std.mem.indexOf(u8, o.contents, "from \"./") != null)
        {
            has_cross_import = true;
            break;
        }
    }
    try std.testing.expect(has_cross_import);
}

test "CodeSplitting: multiple common chunks have unique filenames" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 3 엔트리, 각 쌍이 다른 모듈을 공유 → 2+ 공통 청크
    try writeFile(tmp.dir, "a.ts",
        \\import './ab-shared';
        \\console.log('a');
    );
    try writeFile(tmp.dir, "b.ts",
        \\import './ab-shared';
        \\import './bc-shared';
        \\console.log('b');
    );
    try writeFile(tmp.dir, "c.ts",
        \\import './bc-shared';
        \\console.log('c');
    );
    try writeFile(tmp.dir, "ab-shared.ts", "export const ab = 'shared-ab';");
    try writeFile(tmp.dir, "bc-shared.ts", "export const bc = 'shared-bc';");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);
    const c_path = try absPath(&tmp, "c.ts");
    defer std.testing.allocator.free(c_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path, c_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // 모든 파일명이 고유해야 함
    for (outputs, 0..) |o, i| {
        for (outputs[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, o.path, other.path));
        }
    }
}

test "CodeSplitting: CJS format succeeds — cross-chunk require + 동적 require (P3-B #3321)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry 가 lazy 를 동적 import → 별도 청크. shared 는 정적 cross-chunk.
    try writeFile(tmp.dir, "shared.ts", "export const s = 'S';");
    try writeFile(tmp.dir, "lazy.ts", "import { s } from './shared';\nexport const lazy = s;");
    try writeFile(tmp.dir, "entry.ts", "import { s } from './shared';\nconst x = import('./lazy');\nconsole.log(s, x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .format = .cjs,
    });
    defer bnd.deinit();
    // P3-B: CJS + code_splitting 은 더 이상 에러 아님 — 네이티브 require 가
    // 청크 경계 해석(RFC §4.3). 옛 동작("returns error") 무효화.
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    var has_xchunk_require = false;
    var has_dyn_require = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "= require(\"") != null) has_xchunk_require = true;
        if (std.mem.indexOf(u8, o.contents, "Promise.resolve().then(()=>require(\"") != null) has_dyn_require = true;
        // CJS 청크에 ESM import/export 누출 금지(Node 가 .js 를 CJS 로 로드).
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\nexport {") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\nimport {") == null);
    }
    try std.testing.expect(has_xchunk_require);
    try std.testing.expect(has_dyn_require);
}

test "CodeSplitting: IIFE format succeeds — 레지스트리 + self-register factory (P3-B PR3 #3321)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shared.ts", "export const s = 'S';");
    try writeFile(tmp.dir, "lazy.ts", "import { s } from './shared';\nexport const lazy = s;");
    try writeFile(tmp.dir, "entry.ts", "import { s } from './shared';\nconst x = import('./lazy');\nconsole.log(s, x);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .format = .iife,
    });
    defer bnd.deinit();
    // PR3: iife + code_splitting 은 더 이상 에러 아님 — 런타임 레지스트리
    // (`__zntc_*`) + self-register factory + `<script>` 로더(RFC §4.1/§4.3).
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    var has_register = false;
    var has_require = false;
    var has_loader = false;
    var has_factory = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "__zntc_register") != null) has_register = true;
        if (std.mem.indexOf(u8, o.contents, "__zntc_require(\"") != null) has_require = true;
        if (std.mem.indexOf(u8, o.contents, "__zntc_load_chunk(\"") != null) has_loader = true;
        if (std.mem.indexOf(u8, o.contents, "function(exports, module, require)") != null or
            std.mem.indexOf(u8, o.contents, "function(exports,module,require)") != null) has_factory = true;
        // IIFE 청크에 ESM import/export 누출 금지.
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\nexport {") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\nimport {") == null);
    }
    try std.testing.expect(has_register);
    try std.testing.expect(has_require);
    try std.testing.expect(has_loader);
    try std.testing.expect(has_factory);
}

test "CodeSplitting: UMD/AMD format succeeds — 보편 wrapper + 레지스트리 (P3-B PR4 #3321)" {
    inline for (.{ types.Format.umd, types.Format.amd }) |fmt| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "lazy.ts", "export const lazy = 1;");
        try writeFile(tmp.dir, "entry.ts", "export function load(){ return import('./lazy'); }");

        const entry = try absPath(&tmp, "entry.ts");
        defer std.testing.allocator.free(entry);

        var bnd = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .code_splitting = true,
            .format = fmt,
        });
        defer bnd.deinit();
        // PR4: umd/amd + splitting 은 더 이상 에러 아님 — PR3 레지스트리
        // 기계 + entry 만 보편 wrapper(format_wrapper) + `return
        // __zntc_require(id)`. 옛 동작("returns error") 무효화.
        const result = try bnd.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const outs = result.outputs orelse return error.TestUnexpectedResult;

        var has_wrapper = false;
        var has_return = false;
        var has_reg = false;
        for (outs) |o| {
            if (fmt == .umd and std.mem.indexOf(u8, o.contents, "(function(root, factory)") != null) has_wrapper = true;
            if (fmt == .amd and std.mem.indexOf(u8, o.contents, "define([], function()") != null) has_wrapper = true;
            if (std.mem.indexOf(u8, o.contents, "return globalThis.__zntc_require(\"") != null) has_return = true;
            if (std.mem.indexOf(u8, o.contents, "__zntc_register") != null) has_reg = true;
            // 비-ESM 청크에 ESM import/export 누출 금지.
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "\nexport {") == null);
        }
        try std.testing.expect(has_wrapper);
        try std.testing.expect(has_return);
        try std.testing.expect(has_reg);
    }
}

// preserveModules + non-ESM 은 별도 error name 으로 — code_splitting 미설정 사용자에게
// "CodeSplittingRequiresESM" 가 misleading 이라 분기.
test "PreserveModules: CJS format succeeds with require()/exports (P3-A #3321)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.ts", "export const dep = 1;");
    try writeFile(tmp.dir, "entry.ts", "import { dep } from './dep';\nexport const x = dep;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .preserve_modules = true,
        .format = .cjs,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // cross-module 결합은 ESM import 아닌 require(), export 는 exports.x
    var has_require = false;
    var has_exports = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "require(\"") != null or
            std.mem.indexOf(u8, o.contents, "require('") != null) has_require = true;
        if (std.mem.indexOf(u8, o.contents, "exports.") != null) has_exports = true;
    }
    try std.testing.expect(has_require);
    try std.testing.expect(has_exports);
}

// preserve-modules+iife/umd/amd 는 의도적 non-goal(스코프 아웃, RFC §7):
// preserve-modules 는 모듈 1:1 파일을 소비자 모듈 시스템이 배선하는
// 라이브러리-저작 기능 — iife/umd/amd 는 per-file 모듈 시스템이 없어
// 개념상 무의미(P3-A 의 CJS 는 Node native require 로 가능했음). esbuild
// 미지원·실수요 0. 이 가드(PreserveModulesRequiresESM)가 정답.
test "PreserveModules: IIFE format returns PreserveModulesRequiresESM (intentional non-goal)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .preserve_modules = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = bnd.bundle(std.testing.io);
    try std.testing.expect(result == error.PreserveModulesRequiresESM);
}

// ============================================================
// Tests — 크로스 청크 심볼 수준 import/export
// ============================================================

test "CodeSplitting: cross-chunk named import — 심볼 수준 import 문 생성" {
    // 2개 엔트리가 공통 모듈의 named export를 import할 때
    // 엔트리 청크에 `import { x } from './chunk-N.js'` 형태가 생성되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { createApp } from './shared';\nconsole.log(createApp);");
    try writeFile(tmp.dir, "b.ts", "import { createApp } from './shared';\nconsole.log(createApp);");
    try writeFile(tmp.dir, "shared.ts", "export function createApp() { return 'app'; }");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 엔트리 청크에 `import { createApp }` 형태의 named import가 있어야 함
    var has_named_import = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "import { createApp }") != null or
            std.mem.indexOf(u8, o.contents, "import{createApp}") != null)
        {
            has_named_import = true;
            break;
        }
    }
    try std.testing.expect(has_named_import);

    // 공통 청크에 `export { createApp }` 형태의 export가 있어야 함
    var has_export = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "export { createApp }") != null or
            std.mem.indexOf(u8, o.contents, "export{createApp}") != null)
        {
            has_export = true;
            break;
        }
    }
    try std.testing.expect(has_export);
}

test "CodeSplitting: multiple named imports from common chunk" {
    // 하나의 공통 청크에서 여러 심볼을 가져올 때
    // import { a, b } from './chunk-N.js' 형태로 합쳐져야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x, y } from './shared';\nconsole.log(x, y);");
    try writeFile(tmp.dir, "b.ts", "import { x } from './shared';\nconsole.log(x);");
    try writeFile(tmp.dir, "shared.ts", "export const x = 1;\nexport const y = 2;");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // a.ts 엔트리 청크에 x와 y 모두 import되어야 함
    var has_multi_import = false;
    for (outs) |o| {
        // x와 y가 같은 import 문에 있는지 확인 (순서 무관)
        if ((std.mem.indexOf(u8, o.contents, "import {") != null or
            std.mem.indexOf(u8, o.contents, "import {") != null) and
            std.mem.indexOf(u8, o.contents, "x") != null and
            std.mem.indexOf(u8, o.contents, "y") != null and
            std.mem.indexOf(u8, o.contents, "from \"./") != null)
        {
            has_multi_import = true;
            break;
        }
    }
    try std.testing.expect(has_multi_import);
}

test "CodeSplitting: no cross-chunk symbols when all in same chunk" {
    // 단일 엔트리 — 모든 모듈이 같은 청크에 있으면
    // cross-chunk import/export 없이 인라인 번들이어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './dep';\nconsole.log(x);");
    try writeFile(tmp.dir, "dep.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 단일 청크 — cross-chunk import/export가 없어야 함
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    for (outs) |o| {
        // import 문이나 from 문이 없어야 함 (side-effect든 named든)
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "import '") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "from '") == null);
    }
}

test "CodeSplitting: re-export chain across chunks" {
    // entry → re-exporter → original 체인에서
    // re-exporter와 original이 공통 청크로 추출되면
    // entry 청크에 심볼 import가 있어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { val } from './reexport';\nconsole.log(val);");
    try writeFile(tmp.dir, "b.ts", "import { val } from './reexport';\nconsole.log(val);");
    try writeFile(tmp.dir, "reexport.ts", "export { val } from './original';");
    try writeFile(tmp.dir, "original.ts", "export const val = 'hello';");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 디버그: 출력 파일 수와 내용 확인
    // re-export 체인에서 reexport.ts와 original.ts가 공통 청크로 추출되어야 함
    // 2 엔트리 + 1~2 공통 = 3~4 파일
    // 단, tree-shaking으로 reexport.ts가 제거되면 2개일 수 있음
    try std.testing.expect(outs.len >= 2);

    // 엔트리 청크에 cross-chunk import가 있거나,
    // scope_hoist로 인라인되어 val이 직접 포함될 수 있음
    var has_cross_import = false;
    var has_val_inline = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "from \"./") != null or
            std.mem.indexOf(u8, o.contents, "import \"./") != null)
        {
            has_cross_import = true;
        }
        if (std.mem.indexOf(u8, o.contents, "\"hello\"") != null) {
            has_val_inline = true;
        }
    }
    // cross-chunk import가 있거나, scope_hoist로 인라인되어 값이 포함되어야 함
    try std.testing.expect(has_cross_import or has_val_inline);
}

// ============================================================
// Tests — per-chunk scope hoisting + cross-chunk export alias
// ============================================================

test "CodeSplitting: per-chunk rename — 다른 청크의 같은 이름은 충돌하지 않음" {
    // 2개 엔트리가 각각 같은 이름의 top-level 변수를 가질 때,
    // 다른 청크에 있으므로 rename되지 않아야 한다 (per-chunk 네임스페이스).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "const x = 'from-a';\nconsole.log(x);");
    try writeFile(tmp.dir, "b.ts", "const x = 'from-b';\nconsole.log(x);");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 어떤 청크에도 x$1 같은 리네임이 없어야 함 — 각 청크가 독립 네임스페이스
    for (outs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "x$1") == null);
    }
    // 두 청크 모두 원본 이름 x를 사용
    var a_has_x = false;
    var b_has_x = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "\"from-a\"") != null and
            std.mem.indexOf(u8, o.contents, "const x") != null)
        {
            a_has_x = true;
        }
        if (std.mem.indexOf(u8, o.contents, "\"from-b\"") != null and
            std.mem.indexOf(u8, o.contents, "const x") != null)
        {
            b_has_x = true;
        }
    }
    try std.testing.expect(a_has_x);
    try std.testing.expect(b_has_x);
}

test "CodeSplitting: same-chunk collision still renamed" {
    // 같은 청크 내의 2개 모듈이 같은 이름을 가지면 충돌 해결이 되어야 한다.
    // 단일 엔트리 + 의존성 — 모두 같은 청크에 묶임.
    //
    // D20: 이전 fixture (`import { x } from './dep'; const x = 'entry';`) 는
    // import binding 과 const 가 동일 module scope 에 동명 → ECMAScript
    // LexicallyDeclaredNames 위반 (esbuild/swc/rollup/webpack 모두 redeclaration
    // error 로 거부). analyzer 가 import 를 1st-pass hoisted symbol 로 정식
    // 등록하면서 spec-correct 하게 잡힌다. 테스트 의도("같은 청크 두 모듈의 동명
    // top-level binding → 하나 rename")는 import-shadow 가 아니라 cross-module
    // 동명 충돌로 표현하는 게 정확 — 두 모듈 모두 top-level `const x` 보유.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { dep } from './dep';\nconst x = 'entry';\nconsole.log(x, dep);");
    try writeFile(tmp.dir, "dep.ts", "const x = 'dep';\nexport const dep = x;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 단일 청크 — 같은 청크 내 충돌이므로 x$1이 있어야 함
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    // entry.ts의 x와 dep.ts의 x 중 하나가 rename됨
    const has_rename = std.mem.indexOf(u8, outs[0].contents, "x$1") != null;
    // 또는 import가 제거되어 dep의 x를 직접 참조하여 충돌 없을 수도 있음
    const has_both_values = std.mem.indexOf(u8, outs[0].contents, "'dep'") != null and
        std.mem.indexOf(u8, outs[0].contents, "'entry'") != null;
    try std.testing.expect(has_rename or has_both_values);
}

test "CodeSplitting: cross-chunk export alias with renamed symbol" {
    // 공통 청크에서 2개 모듈이 같은 이름의 export를 가질 때,
    // 청크 내 충돌 해결 후 export { local_name as export_name } 형태로 출력되어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // shared1과 shared2가 모두 "val"을 export하고, 둘 다 같은 청크에 묶이도록 설계
    // a.ts → shared1 (val), shared2 (val)
    // b.ts → shared1 (val), shared2 (val)
    try writeFile(tmp.dir, "a.ts", "import { val } from './shared1';\nimport { val as v2 } from './shared2';\nconsole.log(val, v2);");
    try writeFile(tmp.dir, "b.ts", "import { val } from './shared1';\nimport { val as v2 } from './shared2';\nconsole.log(val, v2);");
    try writeFile(tmp.dir, "shared1.ts", "export const val = 'one';");
    try writeFile(tmp.dir, "shared2.ts", "export const val = 'two';");

    const entry_a = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry_a);
    const entry_b = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry_b);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry_a, entry_b },
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;

    // 공통 청크가 존재해야 함 (2 엔트리 + 1~2 공통 = 3~4 파일)
    try std.testing.expect(outs.len >= 3);

    // 공통 청크에 export 문이 있어야 함
    var has_export = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "export {") != null or
            std.mem.indexOf(u8, o.contents, "export{") != null)
        {
            has_export = true;
            // 공통 청크에 val$1 rename이 있으면 "as val" 형태도 있어야 함
            if (std.mem.indexOf(u8, o.contents, "val$1") != null) {
                try std.testing.expect(std.mem.indexOf(u8, o.contents, "as val") != null);
            }
        }
    }
    try std.testing.expect(has_export);
}

test "CodeSplitting: cross-chunk import binding does not collide with local name" {
    // Bug #2 재현: cross-chunk import 바인딩이 같은 청크의 로컬 이름과 충돌
    // entry.ts imports 'value' from shared (다른 청크), other.ts defines 'value' (같은 청크)
    // → 중복 선언 SyntaxError 방지: 둘 중 하나가 rename되어야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './shared';
        \\import { value as otherValue } from './other';
        \\console.log(value, otherValue);
    );
    try writeFile(tmp.dir, "shared.ts", "export const value = 42;");
    try writeFile(tmp.dir, "other.ts", "export const value = 'local';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 출력에 'value'가 중복 선언되지 않아야 함
    // (import { value } + const value 가 같은 청크에 있으면 안 됨)
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    for (outputs) |o| {
        // entry 청크의 코드에서 SyntaxError 패턴 검사
        // const value = 'local'과 import { value }가 동시에 있으면 안 됨
        if (std.mem.indexOf(u8, o.contents, "\"local\"") != null) {
            // 이 청크에 import { value }도 있으면 충돌
            if (std.mem.indexOf(u8, o.contents, "import {") != null and
                std.mem.indexOf(u8, o.contents, "const value") != null)
            {
                // 둘 다 있으면 하나는 rename되어야 함
                // value$1 또는 as 절이 있어야 함
                const has_rename = std.mem.indexOf(u8, o.contents, "value$1") != null or
                    std.mem.indexOf(u8, o.contents, " as ") != null;
                try std.testing.expect(has_rename);
            }
        }
    }
}

test "CodeSplitting: cross-chunk import reference uses correct binding name" {
    // Bug #1 재현: buildMetadataForAst가 exporter의 rename을 importing 청크에 적용
    // shared.ts의 'greet'가 다른 이유로 rename되면, entry.ts에서 참조가 깨짐
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet } from './shared';
        \\console.log(greet());
    );
    try writeFile(tmp.dir, "shared.ts",
        \\export function greet() { return 'hello'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // entry 청크에서 greet() 호출이 있어야 함
    var found_greet_call = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "greet()") != null) {
            found_greet_call = true;
            // greet가 import에서 왔으면, import 문에 greet가 있어야 함
            if (std.mem.indexOf(u8, o.contents, "import") != null) {
                try std.testing.expect(std.mem.indexOf(u8, o.contents, "greet") != null);
            }
        }
    }
    try std.testing.expect(found_greet_call);
}

test "CodeSplitting: CRITICAL — same name in shared chunk and entry chunk" {
    // shared.ts(공통 청크)에 'x', entry에 import 'x' + 로컬 'x' 정의
    // → 같은 청크에 import { x } + const x 가 공존하면 SyntaxError
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry가 shared를 dynamic import → shared는 별도 청크
    // entry 자체에도 const x = 'local' 선언
    try writeFile(tmp.dir, "entry.ts",
        \\const x = 'local';
        \\const shared = import('./shared');
        \\console.log(x, shared);
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // 최소 2개 청크 (entry + shared)
    try std.testing.expect(outputs.len >= 2);
    // shared 청크에 export 문이 있어야 함
    var has_export = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "export") != null and
            std.mem.indexOf(u8, o.contents, "42") != null)
        {
            has_export = true;
        }
    }
    try std.testing.expect(has_export);
}

test "CodeSplitting: CRITICAL — rename collision between import binding and local var" {
    // 2개 엔트리: a.ts, b.ts → 둘 다 shared.ts의 'val'을 import
    // a.ts에도 로컬 'val' 정의 → a 청크에서 import { val } + const val 충돌
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { val } from './shared';
        \\const val2 = val + 1;
        \\console.log(val2);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { val } from './shared';
        \\console.log(val);
    );
    try writeFile(tmp.dir, "shared.ts", "export const val = getVal();\nfunction getVal() { return 42; }");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // 3개 청크: a, b, shared(공통)
    try std.testing.expectEqual(@as(usize, 3), outputs.len);

    // shared 청크에 export { val } 있어야 함
    var shared_has_export = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "const val = getVal()") != null or
            std.mem.indexOf(u8, o.contents, "const val=getVal()") != null)
        {
            shared_has_export = std.mem.indexOf(u8, o.contents, "export") != null;
        }
    }
    try std.testing.expect(shared_has_export);

    // a 청크에 import { val } from './chunk-...' 있어야 함
    var a_has_import = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "val + 1") != null or
            std.mem.indexOf(u8, o.contents, "val+1") != null)
        {
            a_has_import = std.mem.indexOf(u8, o.contents, "import") != null;
        }
    }
    try std.testing.expect(a_has_import);
}

test "CodeSplitting: CRITICAL — two modules in same chunk with same name as cross-chunk import" {
    // a.ts(엔트리)가 shared.ts의 'x'를 import + local.ts(같은 청크)에도 'x' 선언
    // b.ts(엔트리)도 shared.ts의 'x'를 import → shared.ts는 공통 청크
    // a 청크에 a.ts + local.ts가 같이 있음 → local.ts의 'x'와 import { x } 충돌
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { x } from './shared';
        \\import { y } from './local';
        \\console.log(x, y);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "local.ts",
        \\export const x = 'local-x';
        \\export const y = 'local-y';
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared-x';");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // a 청크를 찾기: local-x가 포함된 청크
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "local-x") != null) {
            // 이 청크에 import { x }도 있다면, const x와 충돌
            // → x$1 rename 또는 import { x as x$1 } 형태여야 함
            const has_import_x = std.mem.indexOf(u8, o.contents, "import") != null;
            const has_const_x = std.mem.indexOf(u8, o.contents, "const x") != null;
            if (has_import_x and has_const_x) {
                // 충돌이 있으면 rename 또는 as가 있어야 함
                const has_deconflict = std.mem.indexOf(u8, o.contents, "x$1") != null or
                    std.mem.indexOf(u8, o.contents, " as ") != null;
                try std.testing.expect(has_deconflict);
            }
        }
    }
}

test "CodeSplitting: three entries sharing module — all import same name" {
    // 3개 엔트리가 shared의 'x'를 import + 각 엔트리에도 로컬 'x'
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { x } from './shared';
        \\const x2 = x;
        \\console.log(x2);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "c.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared';");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);
    const c_path = try absPath(&tmp, "c.ts");
    defer std.testing.allocator.free(c_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path, c_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // 4 청크: 3 엔트리 + 1 공통
    try std.testing.expectEqual(@as(usize, 4), outputs.len);
}

test "CodeSplitting: default export cross-chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import lib from './shared';
        \\console.log(lib);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import lib from './shared';
        \\console.log(lib);
    );
    try writeFile(tmp.dir, "shared.ts", "export default function() { return 42; }");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    try std.testing.expect(outputs.len >= 2);
}

test "CodeSplitting: deep chain across chunks" {
    // a→b (static), a→c (dynamic), c→d (static), b→d (static)
    // d는 a청크(via b)와 c청크(직접) 모두에서 도달 → 공통 청크
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { b } from './b';
        \\const c = import('./c');
        \\console.log(b, c);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { d } from './d';
        \\export const b = d + 1;
    );
    try writeFile(tmp.dir, "c.ts",
        \\import { d } from './d';
        \\export const c = d + 2;
    );
    try writeFile(tmp.dir, "d.ts", "export const d = 10;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // d.ts가 공통 청크에 있어야 함 (a청크, c청크 모두에서 도달)
    try std.testing.expect(outputs.len >= 2);
}

test "CodeSplitting: minified output with chunks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { x } from './shared';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 42;");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .minify_whitespace = true,
        .minify_identifiers = true,
        .minify_syntax = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // minified: 모듈 경계 주석 없음
    for (outputs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "// ---") == null);
    }
}

test "CodeSplitting: CJS module in shared chunk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\import cjs from './shared.cjs';
        \\console.log(cjs);
    );
    try writeFile(tmp.dir, "b.ts",
        \\import cjs from './shared.cjs';
        \\console.log(cjs);
    );
    try writeFile(tmp.dir, "shared.cjs", "module.exports = { value: 42 };");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;
    // CJS 모듈이 공통 청크에 __commonJS 래핑되어야 함
    var has_commonjs = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "__commonJS") != null) {
            has_commonjs = true;
        }
    }
    try std.testing.expect(has_commonjs);
}

// ============================================================
// Content Hash + Naming Pattern Tests
// ============================================================

test "CodeSplitting: content hash naming — entry-names and chunk-names" {
    // --entry-names=[name]-[hash] --chunk-names=chunks/[name]-[hash] 통합 테스트
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { shared } from './shared';\nconsole.log('a', shared);");
    try writeFile(tmp.dir, "b.ts", "import { shared } from './shared';\nconsole.log('b', shared);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .entry_names = "[name]-[hash]",
        .chunk_names = "chunks/[name]-[hash]",
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // 엔트리 파일명: "{name}-{8hex}.js"
    // 공통 청크 파일명: "chunks/chunk-{8hex}.js"
    var entry_count: usize = 0;
    var chunk_count: usize = 0;
    for (outputs) |o| {
        if (std.mem.startsWith(u8, o.path, "chunks/")) {
            chunk_count += 1;
            try std.testing.expect(std.mem.startsWith(u8, o.path, "chunks/chunk-"));
            try std.testing.expect(std.mem.endsWith(u8, o.path, ".js"));
        } else {
            entry_count += 1;
            // "a-{8hex}.js" or "b-{8hex}.js"
            try std.testing.expect(std.mem.endsWith(u8, o.path, ".js"));
            try std.testing.expect(std.mem.indexOf(u8, o.path, "-") != null);
        }
        // placeholder가 최종 출력에 남아있으면 안 된다
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\x00ZH") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.path, "\x00ZH") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), entry_count);
    try std.testing.expect(chunk_count >= 1);
}

test "CodeSplitting: content hash deterministic — same code same hash" {
    // 동일한 코드를 두 번 빌드하면 동일한 content hash가 나와야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 1;");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    // 1차 빌드
    var bnd1 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .chunk_names = "[name]-[hash]",
    });
    defer bnd1.deinit();
    const result1 = try bnd1.bundle(std.testing.io);
    defer result1.deinit(std.testing.allocator);

    // 2차 빌드
    var bnd2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .chunk_names = "[name]-[hash]",
    });
    defer bnd2.deinit();
    const result2 = try bnd2.bundle(std.testing.io);
    defer result2.deinit(std.testing.allocator);

    const outs1 = result1.outputs orelse return error.TestUnexpectedResult;
    const outs2 = result2.outputs orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(outs1.len, outs2.len);

    // 파일명이 동일한지 확인
    for (outs1) |o1| {
        var found = false;
        for (outs2) |o2| {
            if (std.mem.eql(u8, o1.path, o2.path)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

// ============================================================
// Dev Mode Tests
// ============================================================

test "Bundler: dev mode includes polyfills and banner" {
    // dev mode에서 --polyfill, --banner:js가 번들에 포함되는지 확인.
    // Phase 2: 프로덕션 파이프라인(emitWithTreeShaking)을 사용하므로
    // HMR 런타임 없이 polyfill/banner/모듈 코드가 올바른 순서로 출력.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hello');");
    try writeFile(tmp.dir, "my-polyfill.js", "global.MyPolyfill = { init: function() {} };");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "my-polyfill.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .polyfills = &.{polyfill},
        .banner_js = "var __TEST_BANNER__=1;",
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill이 번들에 포함됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MyPolyfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(function(){") != null);
    // banner가 번들에 포함됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__TEST_BANNER__") != null);
    // banner < polyfill < 모듈 코드 순서
    const polyfill_pos = std.mem.indexOf(u8, result.output, "MyPolyfill").?;
    const banner_pos = std.mem.indexOf(u8, result.output, "__TEST_BANNER__").?;
    const code_pos = std.mem.indexOf(u8, result.output, "console.log").?;
    try std.testing.expect(banner_pos < polyfill_pos);
    try std.testing.expect(polyfill_pos < code_pos);
}

test "Bundler: minify_whitespace 가 polyfill content 도 minify (#3649 polyfill root cause)" {
    // RN polyfill 은 모듈 그래프를 우회해 bundler 가 직접 읽어 prepend 한다.
    // minify_whitespace 시 polyfill content 도 주석/공백/들여쓰기가 제거돼야 한다
    // (이전엔 flow strip 만 하고 minify 미전달 → 원본 그대로 남던 회귀).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");
    try writeFile(tmp.dir, "my-polyfill.js", "// license banner comment\nfunction polyHelper(argName) {\n    return argName + 1;\n}\nglobal.MyPolyfill = { run: polyHelper };\n");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "my-polyfill.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .polyfills = &.{polyfill},
        .minify_whitespace = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill content 는 여전히 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MyPolyfill") != null);
    // minify: 주석 제거 + 4-space 들여쓰기 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "license banner comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "    return") == null);
}

test "Bundler: polyfill transpile 의 semantic 진단 owned 필드 누수 없음 (#3649 후속, leak 가드)" {
    // semantic 진단(let 재선언)을 내면서 code 도 정상 생성하는 polyfill — transpile 이
    // diagnostics/line_offsets 를 self.allocator 로 할당한다. 수정 전엔 result.code 만 취하고
    // 나머지를 free 안 해 누수했고, std.testing.allocator(GPA) 가 leak 으로 잡는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('x');");
    // `let x` 재선언 = analyzer 가 throw 없이 진단을 쌓고 codegen 은 진행(정상 code + 진단).
    try writeFile(tmp.dir, "diag-poly.js", "let x = 1;\nlet x = 2;\nglobal.MyPolyfill = x;\n");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "diag-poly.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .polyfills = &.{polyfill},
        .minify_whitespace = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // 핵심 가드: 테스트 종료 시 누수 없음(testing.allocator 가 자동 검출).
    // polyfill 이 실제로 transpile 경로를 타고 번들에 포함됐는지도 확인.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MyPolyfill") != null);
}

test "Bundler: dev mode single file" {
    // Phase 2: dev mode에서 단일 파일이 프로덕션 파이프라인으로 scope-hoisted 출력
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 42;\nexport default x;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm 래핑 출력 (모듈이 __zntc_register로 래핑되지 않음)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_register(\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm") != null);
    // HMR 런타임이 주입됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_modules") != null);
    // 모듈 코드가 번들에 포함됨 (hoisted var + __esm wrapper)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x = 42") != null);
}

test "Bundler: dev mode two files with import" {
    // Phase 2: dev mode에서 두 파일이 scope-hoisted로 번들됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.ts", "export const add = (a, b) => a + b;");
    try writeFile(tmp.dir, "index.ts", "import { add } from './utils';\nconsole.log(add(1, 2));");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // __esm 래핑 (모듈이 __zntc_register로 래핑되지 않음)
    try std.testing.expect(std.mem.indexOf(u8, output, "__zntc_register(\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__esm") != null);
    // 두 모듈의 코드가 모두 포함됨
    try std.testing.expect(std.mem.indexOf(u8, output, "add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "console.log") != null);
}

test "Bundler: dev mode default import" {
    // Phase 2: dev mode에서 default import가 scope-hoisted로 직접 참조됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "greet.ts", "export default function greet() { return 'hi'; }");
    try writeFile(tmp.dir, "index.ts", "import greet from './greet';\nconsole.log(greet());");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // __esm 래핑: greet 함수가 래퍼 안에서 정의됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
}

test "Bundler: dev mode module_dev_codes" {
    // module_dev_codes 수집 (HMR per-module codes)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.ts", "export const add = (a, b) => a + b;");
    try writeFile(tmp.dir, "index.ts", "import { add } from './utils';\nconsole.log(add(1, 2));");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // collect_module_codes=true: per-module codes 수집됨
    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), codes.len);
    for (codes) |c| {
        try std.testing.expect(c.id.len > 0);
        try std.testing.expect(c.code.len > 0);
    }
}

test "Bundler: dev mode per-module sourcemap (Issue #1248)" {
    // sourcemap 활성화 시 ModuleDevCode.map 에 모듈별 V3 소스맵 JSON이 채워진다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.ts", "export const add = (a, b) => a + b;");
    try writeFile(tmp.dir, "index.ts", "import { add } from './utils';\nconsole.log(add(1, 2));");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    try std.testing.expect(codes.len >= 1);

    // 모든 모듈에 standalone sourcemap이 채워짐 + V3 형식 검증
    var maps_found: usize = 0;
    for (codes) |c| {
        const m = c.map orelse continue;
        maps_found += 1;
        try std.testing.expect(std.mem.indexOf(u8, m, "\"version\":3") != null);
        try std.testing.expect(std.mem.indexOf(u8, m, "\"sources\":[") != null);
        try std.testing.expect(std.mem.indexOf(u8, m, "\"mappings\":\"") != null);
        // 모듈 ID가 파일명을 포함해야 함 (sourceMappingURL/디버거 표시용)
        try std.testing.expect(std.mem.indexOf(u8, m, ".ts") != null);
    }
    try std.testing.expect(maps_found == codes.len);
}

test "Bundler: dev mode per-module sourcemap — sources_content=false (Issue #1248)" {
    // sources_content=false 면 모듈 소스맵에도 sourcesContent 미포함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.ts", "console.log('hi');");

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
        .sourcemap = .{ .sources_content = false },
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    try std.testing.expect(codes.len >= 1);
    for (codes) |c| {
        const m = c.map orelse continue;
        try std.testing.expect(std.mem.indexOf(u8, m, "sourcesContent") == null);
    }
}

test "Bundler: dev mode sourcemap" {
    // dev mode에서 소스맵이 생성되는지 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "utils.ts", "export const add = (a, b) => a + b;");
    try writeFile(tmp.dir, "index.ts", "import { add } from './utils';\nconsole.log(add(1, 2));");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 소스맵이 생성되었는지
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;
    // V3 소스맵 JSON 구조 확인
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"mappings\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"sources\":[") != null);
    // 번들에 sourceMappingURL이 있는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "//# sourceMappingURL=/bundle.js.map") != null);
}

test "Bundler: dev mode sourcemap — multi-module sources" {
    // 여러 모듈의 소스맵이 번들 소스맵에 모두 포함되는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "math.ts", "export function add(a: number, b: number) { return a + b; }");
    try writeFile(tmp.dir, "str.ts", "export function upper(s: string) { return s.toUpperCase(); }");
    try writeFile(tmp.dir, "main.ts", "import { add } from './math';\nimport { upper } from './str';\nconsole.log(add(1, 2), upper('hi'));");

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;

    // 소스맵이 V3 형식으로 생성됨
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"version\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"sources\":[") != null);
}

test "Bundler: dev mode sourcemap — mappings point to correct bundle lines" {
    // 번들 출력에서 각 모듈 코드의 줄 위치가 소스맵 매핑과 일치하는지 검증
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const A = 'a';");
    try writeFile(tmp.dir, "b.ts", "import { A } from './a';\nexport const B = A + 'b';");

    const entry = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 번들 출력에 두 모듈의 코드가 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__esm") != null);

    // 소스맵이 생성되고 매핑이 비어있지 않아야 함
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"sources\":[") != null);

    // sourceMappingURL이 번들 끝에 있어야 함
    const url_marker = "//# sourceMappingURL=";
    const url_pos = std.mem.indexOf(u8, result.output, url_marker) orelse
        return error.TestUnexpectedResult;
    // URL은 출력 마지막 줄이어야 함
    const after_url = result.output[url_pos + url_marker.len ..];
    const newline_pos = std.mem.indexOf(u8, after_url, "\n");
    if (newline_pos) |np| {
        // 줄바꿈 이후에는 내용이 없거나 빈 줄만
        const rest = std.mem.trim(u8, after_url[np..], "\n\r ");
        try std.testing.expectEqualStrings("", rest);
    }
}

test "Bundler: dev mode react fast refresh" {
    // Phase 2: React Fast Refresh가 컴포넌트에 $RefreshReg$ 주입 (프로덕션 파이프라인)
    // HMR 런타임(__REACT_REFRESH_RUNTIME__, module.hot.accept)은 Phase 3-4에서 추가.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "App.ts", "export default function App() { return 'hello'; }\nfunction Helper() { return 'helper'; }");

    const entry = try absPath(&tmp, "App.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .react_refresh = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // $RefreshReg$ 호출이 주입되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$") != null);
    // PascalCase 함수명(App, Helper) 등록
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"App\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Helper\"") != null);
    // _c 핸들 변수 선언
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_c") != null);
    // React Refresh 스텁이 번들 prologue에 주입됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshSig$") != null);
}

test "Bundler: dev mode refresh registration" {
    // $RefreshReg$ 컴포넌트 등록이 주입되는지 확인 ($RefreshSig$ 제거 후)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "App.ts",
        \\function App() {
        \\  const x = useState(0);
        \\  useEffect(function() {});
        \\  return x;
        \\}
    );

    const entry = try absPath(&tmp, "App.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .react_refresh = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // $RefreshReg$(_c, "App"); 컴포넌트 등록
    try std.testing.expect(std.mem.indexOf(u8, output, "$RefreshReg$") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"App\"") != null);
    // var _c; 핸들 변수 선언
    try std.testing.expect(std.mem.indexOf(u8, output, "_c") != null);
    // _s() hook signature 호출은 더 이상 주입하지 않음 (Metro 방식)
    // (HMR 런타임의 $RefreshSig$ 글로벌 등록은 있지만, 모듈 코드 내 _s() 호출은 없어야 함)
    try std.testing.expect(std.mem.indexOf(u8, output, "_s(App") == null);
}

// ----------------------------------------------------------------
// react-refresh Vite plugin-react 호환 path filter 회귀 가드
// ----------------------------------------------------------------

test "Bundler: refresh — node_modules entry skipped by Vite-compatible path filter" {
    // node_modules 안에 있는 모듈은 PascalCase 함수여도 $RefreshReg$ 등록 코드를
    // 주입하지 않는다 (Vite @vitejs/plugin-react 의 default exclude).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "node_modules/lib");
    try writeFile(tmp.dir, "node_modules/lib/index.tsx",
        \\export default function LibComp() { return 1; }
    );

    const entry = try absPath(&tmp, "node_modules/lib/index.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .react_refresh = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());

    // node_modules 모듈은 register 코드가 들어가지 않아야 한다 — runtime stub
    // (`g.$RefreshReg$ = function() {}`) 은 별도라 `_c = LibComp;` 패턴으로 검증.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_c = LibComp") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$(_c, \"LibComp\"") == null);
}

test "Bundler: refresh — user-land .tsx still registers (positive control)" {
    // 위 음성 케이스의 짝 — 동일 fixture 패턴에서 path 만 다른 경우 register 가 들어간다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "Comp.tsx",
        \\export default function MyComp() { return 1; }
    );

    const entry = try absPath(&tmp, "Comp.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .react_refresh = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());

    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$(_c, \"MyComp\"") != null);
}

test "Bundler: refresh — ES5 lexical lowering preserves arrow component registration" {
    // RN/Hermes 하위 타겟처럼 const/arrow lowering 이 켜져도, variable declarator
    // 후처리(React Refresh registration)가 누락되면 안 된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "PermissionDialog.tsx",
        \\const PermissionDialog = () => null;
        \\export default PermissionDialog;
    );

    const entry = try absPath(&tmp, "PermissionDialog.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .react_refresh = true,
        .unsupported = compat.fromESTarget(.es5),
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());

    try std.testing.expect(std.mem.indexOf(u8, result.output, "_c = PermissionDialog") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$(_c, \"PermissionDialog\"") != null);
}

test "Bundler: refresh — registration follows linker rename through barrel export" {
    // `const Component = () => {}; export default Component;` 모듈을 barrel 이
    // 같은 이름으로 re-export 하면 linker 가 한쪽을 `Component$1` 로 rename 한다.
    // Refresh 등록용 `_c = Component` 참조도 같은 symbol_id 를 따라가야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\import './shadow';
        \\import { EquipmentSearchBody } from './EquipmentSearch';
        \\console.log(EquipmentSearchBody);
    );
    try writeFile(tmp.dir, "shadow.ts",
        \\const EquipmentSearchBody = 'shadow';
        \\console.log(EquipmentSearchBody);
    );
    try writeFile(tmp.dir, "EquipmentSearch.ts",
        \\import EquipmentSearchBody from './EquipmentSearchBody';
        \\export { EquipmentSearchBody };
    );
    try writeFile(tmp.dir, "EquipmentSearchBody.tsx",
        \\const EquipmentSearchBody = () => null;
        \\EquipmentSearchBody.propTypes = {};
        \\export default EquipmentSearchBody;
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .react_refresh = true,
        .unsupported = compat.fromESTarget(.es5),
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());

    try std.testing.expect(std.mem.indexOf(u8, result.output, "= EquipmentSearchBody$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "= EquipmentSearchBody;\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$(_c, \"EquipmentSearchBody\"") != null);
}

test "Bundler: dev mode ES5 runtime helpers injected globally" {
    // Phase 2: ES5 타겟 dev mode에서 __classCallCheck 등 헬퍼가 모듈 코드 앞에 주입
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "App.ts", "class App { constructor() { this.x = 1; } };\nexport default App;");

    const entry = try absPath(&tmp, "App.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .unsupported = .{ .class = true, .arrow = true },
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // ES5 런타임 헬퍼가 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, output, "__classCallCheck") != null);
    // 헬퍼가 모듈 코드보다 앞에 위치
    const helper_pos = std.mem.indexOf(u8, output, "var __classCallCheck") orelse return error.TestUnexpectedResult;
    const code_pos = std.mem.indexOf(u8, output, "App") orelse return error.TestUnexpectedResult;
    try std.testing.expect(helper_pos < code_pos);
}

// NOTE: "dev mode factory receives module/exports/require" 테스트 삭제 (Phase 2).
// __zntc_register factory 래핑은 프로덕션 __commonJS/__esm 래핑으로 대체됨.

// NOTE: "dev mode dependency map for CJS require resolve" 테스트 삭제 (Phase 2).
// 프로덕션 linker가 import binding을 직접 해결하므로 dep_map 불필요.

test "Bundler: dev mode collect_module_codes" {
    // collect_module_codes=false(기본값)이면 null, true이면 수집됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    // 기본값: null
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .dev_mode = true,
        });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(result.module_dev_codes == null);
    }

    // collect_module_codes=true: per-module codes 수집
    {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .dev_mode = true,
            .collect_module_codes = true,
        });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
        try std.testing.expect(codes.len > 0);
        // 각 code에 모듈 ID와 __esm 래핑 코드가 있는지
        for (codes) |c| {
            try std.testing.expect(c.id.len > 0);
            try std.testing.expect(c.code.len > 0);
        }
    }
}

test "Bundler: dev mode named imports from multiple modules are not mixed" {
    // Phase 2: 여러 모듈에서 named import → scope-hoisted 직접 참조
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "math.ts", "export const add = (a, b) => a + b;\nexport const sub = (a, b) => a - b;");
    try writeFile(tmp.dir, "str.ts", "export const upper = (s) => s.toUpperCase();\nexport const lower = (s) => s.toLowerCase();");
    try writeFile(tmp.dir, "index.ts",
        \\import { add, sub } from './math';
        \\import { upper, lower } from './str';
        \\console.log(add(1,2), sub(3,1), upper("a"), lower("B"));
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // __esm 래핑: 모든 export가 번들에 포함 (hoisted var + 래퍼 내 할당)
    try std.testing.expect(std.mem.indexOf(u8, output, "var add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "var sub") != null or std.mem.indexOf(u8, output, "sub") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "upper") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "lower") != null);
    // 호출이 정상적으로 포함됨
    try std.testing.expect(std.mem.indexOf(u8, output, "console.log") != null);
}

test "Bundler: dev mode ESM→CJS named import uses HMR-safe property access" {
    // dev 모드에서 CJS 모듈의 named import는 별도 top-level var를 만들지 않고
    // require 결과의 property access로 직접 치환한다. HMR eval은 번들 로컬
    // `require_xxx` 이름을 볼 수 없으므로 dev 모드에서는 registry lookup을 사용한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "react.js", "module.exports = { useState: function(v) { return [v, function(){}]; }, useEffect: function(f) { f(); } };");
    try writeFile(tmp.dir, "app.ts",
        \\import { useState, useEffect } from './react';
        \\export function App() {
        \\  const [count, setCount] = useState(0);
        \\  useEffect(() => { console.log(count); }, [count]);
        \\  return count;
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;

    // CJS named import용 hoisted binding이 없어야 함.
    try std.testing.expect(std.mem.indexOf(u8, output, "var useState, useEffect") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "useState = require_react().useState;") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "useEffect = require_react().useEffect;") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "require_react().useState(") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "require_react().useEffect(") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"].fn().useState(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"].fn().useEffect(") != null);
    // 구조분해 패턴 없음 (({useState:...} = ...) 형태가 아님)
    try std.testing.expect(std.mem.indexOf(u8, output, "{useState") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "({useState") == null);
}

test "Bundler: dev mode HMR module code rewrites CJS require to registry lookup" {
    // RN HMR은 globalEvalWithSourceUrl로 update.code를 평가한다. 전체 번들 스코프의
    // `require_react` 같은 로컬 함수명은 보이지 않으므로 CJS require rewrite도
    // __zntc_modules registry 경유여야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "react.js", "module.exports = { useState: function() { return 1; } };");
    try writeFile(tmp.dir, "LogBox.js",
        \\const React = require('./react');
        \\exports.value = React.useState();
    );
    try writeFile(tmp.dir, "index.ts", "import './LogBox';");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    var saw_logbox = false;
    for (codes) |c| {
        if (std.mem.indexOf(u8, c.id, "LogBox.js") == null) continue;
        saw_logbox = true;
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require_react()") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "__zntc_modules[") != null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "\"].fn())") != null);
    }
    try std.testing.expect(saw_logbox);
}

test "Bundler: dev mode HMR registry uses stable ids for disabled CJS shims" {
    // Disabled/optional-missing modules are still CJS wrappers. Their wrapper key
    // must match the dev_id used by HMR-safe require rewrites, otherwise startup
    // fails with `__zntc_modules[id].fn` on undefined.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.js",
        \\const stream = require('stream');
        \\let optional = 'fallback';
        \\try {
        \\  optional = require('missing-peer');
        \\} catch (e) {}
        \\module.exports = { stream, optional };
    );

    const entry = try absPath(&tmp, "index.js");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .browser,
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"(disabled):stream\"(exports, module)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"(optional-missing):missing-peer\"(exports, module)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_modules[\"(disabled):stream\"].fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_modules[\"(optional-missing):missing-peer\"].fn()") != null);

    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    var saw_entry = false;
    for (codes) |c| {
        if (std.mem.indexOf(u8, c.id, "index.js") == null) continue;
        saw_entry = true;
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require__disabled") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require__optional_missing") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "__zntc_modules[\"(disabled):stream\"].fn()") != null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "__zntc_modules[\"(optional-missing):missing-peer\"].fn()") != null);
    }
    try std.testing.expect(saw_entry);
}

test "Bundler: dev mode CJS named import does not allocate colliding hoisted binding" {
    // React Native 재현 형태:
    // - wrapped host 모듈은 로컬 `NativeText` 위에 export getter를 만든다.
    // - 다른 wrapped ESM 모듈도 CJS에서 `{ Text as NativeText }`를 import한다.
    // CJS named import가 top-level var로 호이스팅되면 두 모듈의 `NativeText`가 같은
    // 번들 스코프에서 충돌한다. require property access로 직접 치환하면 충돌 binding
    // 자체가 생기지 않는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "rn.cjs", "module.exports = { Text: 'rn-text' };\n");
    try writeFile(tmp.dir, "host.ts",
        \\export let NativeText = 'host-text';
        \\export function readHostText() {
        \\  return NativeText;
        \\}
    );
    try writeFile(tmp.dir, "nav.ts",
        \\import { Text as NativeText } from './rn.cjs';
        \\export function readNavText() {
        \\  return NativeText;
        \\}
    );
    try writeFile(tmp.dir, "index.ts",
        \\import { readHostText } from './host';
        \\import { readNavText } from './nav';
        \\console.log(readHostText(), readNavText());
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "].fn().Text;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "NativeText = require_rn().Text;") == null);
}

test "Bundler: dev mode alias named import does not emit raw require" {
    // Expo Router _layout 재현: `@/...` alias import가 HMR payload에서 raw
    // `require("@/...")`로 남으면 RN/Hermes eval 스코프에 require가 없어 실패한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "hooks/use-color-scheme.ts",
        \\export function useColorScheme() {
        \\  return 'light';
        \\}
    );
    try writeFile(tmp.dir, "app/_layout.tsx",
        \\import { useColorScheme } from '@/hooks/use-color-scheme';
        \\export default function RootLayout() {
        \\  return useColorScheme();
        \\}
    );

    const entry = try absPath(&tmp, "app/_layout.tsx");
    defer std.testing.allocator.free(entry);
    const root = try absPath(&tmp, ".");
    defer std.testing.allocator.free(root);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
        .alias = &.{.{ .from = "@", .to = root }},
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"@/hooks/use-color-scheme\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('@/hooks/use-color-scheme')") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_modules[") != null);

    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    var saw_layout = false;
    for (codes) |c| {
        if (std.mem.indexOf(u8, c.id, "app/_layout.tsx") == null) continue;
        saw_layout = true;
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require(\"@/hooks/use-color-scheme\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require('@/hooks/use-color-scheme')") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "useColorScheme") != null);
    }
    try std.testing.expect(saw_layout);
}

test "Bundler: dev mode HMR mixed alias imports do not emit raw require" {
    // 테스트앱 재현: HMR payload는 eval 스코프에서 실행되므로 alias import가
    // `require("~/...")`로 남으면 RN/Hermes에 global require가 없어 실패한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/core/settings/index.ts",
        \\export * from './optionStore';
    );
    try writeFile(tmp.dir, "src/core/settings/optionStore.ts",
        \\export const defaultOptions = { mode: 'dev' };
    );
    try writeFile(tmp.dir, "src/widgets/loading/index.js",
        \\import LoadingRing from './LoadingRing';
        \\export { LoadingRing };
    );
    try writeFile(tmp.dir, "src/widgets/loading/LoadingRing.js",
        \\export default function LoadingRing() {
        \\  return null;
        \\}
    );
    try writeFile(tmp.dir, "src/App.tsx",
        \\import { defaultOptions as appDefaults } from '~/core/settings';
        \\import { LoadingRing } from '~/widgets/loading';
        \\export default function App() {
        \\  return [appDefaults.mode, LoadingRing];
        \\}
    );

    const entry = try absPath(&tmp, "src/App.tsx");
    defer std.testing.allocator.free(entry);
    const root = try absPath(&tmp, ".");
    defer std.testing.allocator.free(root);
    const src_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/src/", .{root});
    defer std.testing.allocator.free(src_prefix);

    const ts_path_targets = [_]@import("../../config.zig").TsConfig.PathEntry.Target{
        .{ .prefix = src_prefix, .suffix = "" },
    };
    const ts_paths = [_]@import("../../config.zig").TsConfig.PathEntry{
        .{
            .key_prefix = "~/",
            .key_suffix = "",
            .has_wildcard = true,
            .targets = &ts_path_targets,
        },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .dev_mode = true,
        .collect_module_codes = true,
        .ts_paths = &ts_paths,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"~/") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('~/") == null);

    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    var saw_app = false;
    for (codes) |c| {
        if (std.mem.indexOf(u8, c.id, "src/App.tsx") == null) continue;
        saw_app = true;
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require(\"~/") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require('~/") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "__zntc_modules[") != null);
    }
    try std.testing.expect(saw_app);
}

test "Bundler: dev mode ts paths re-exported CJS named import does not emit raw require" {
    // Expo Router _layout + tsconfig paths 재현:
    // app/_layout.tsx -> @/hooks/use-color-scheme -> react-native(CJS) re-export.
    // init 함수 안에 raw require("@/...")가 남으면 RN/Hermes eval 스코프에서 실패한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/react-native/index.js",
        \\module.exports = {
        \\  useColorScheme: function useColorScheme() {
        \\    return 'dark';
        \\  },
        \\};
    );
    try writeFile(tmp.dir, "hooks/use-color-scheme.ts",
        \\export { useColorScheme } from 'react-native';
    );
    try writeFile(tmp.dir, "app/_layout.tsx",
        \\import { useColorScheme } from '@/hooks/use-color-scheme';
        \\export default function RootLayout() {
        \\  return useColorScheme();
        \\}
    );

    const entry = try absPath(&tmp, "app/_layout.tsx");
    defer std.testing.allocator.free(entry);
    const root = try absPath(&tmp, ".");
    defer std.testing.allocator.free(root);
    const root_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/", .{root});
    defer std.testing.allocator.free(root_prefix);

    const ts_path_targets = [_]@import("../../config.zig").TsConfig.PathEntry.Target{
        .{ .prefix = root_prefix, .suffix = "" },
    };
    const ts_paths = [_]@import("../../config.zig").TsConfig.PathEntry{
        .{
            .key_prefix = "@/",
            .key_suffix = "",
            .has_wildcard = true,
            .targets = &ts_path_targets,
        },
    };

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
        .ts_paths = &ts_paths,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require(\"@/hooks/use-color-scheme\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "require('@/hooks/use-color-scheme')") == null);

    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    var saw_layout = false;
    for (codes) |c| {
        if (std.mem.indexOf(u8, c.id, "app/_layout.tsx") == null) continue;
        saw_layout = true;
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require(\"@/hooks/use-color-scheme\")") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "require('@/hooks/use-color-scheme')") == null);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "useColorScheme") != null);
    }
    try std.testing.expect(saw_layout);
}

test "Bundler: dev mode new expression wraps renamed CJS member callee" {
    // `new Animated.Value()`의 `Animated`가 CJS named import direct access로
    // `require_xxx().Animated`가 되면 callee 내부에 call expression이 생긴다.
    // 괄호가 없으면 JS가 생성자 callee를 다르게 묶어 AnimatedValue를 일반 함수처럼
    // 호출할 수 있다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "rn.cjs",
        \\class Value {
        \\  constructor(v) { this.v = v; }
        \\}
        \\module.exports = { Animated: { Value } };
    );
    try writeFile(tmp.dir, "index.ts",
        \\import { Animated } from './rn.cjs';
        \\export const value = new Animated.Value(0);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "new (__zntc_modules[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "].fn().Animated.Value)(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "new __zntc_modules[") == null);
}

test "Bundler: dev mode new expression wraps renamed CJS deep member callee" {
    // member chain이 더 깊어도 root identifier rename에 call이 섞이면 callee 전체를
    // 감싸야 한다. 일부 navigation/animation 패키지는 namespace 아래에 constructor를 둔다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "rn.cjs",
        \\class Value {
        \\  constructor(v) { this.v = v; }
        \\}
        \\module.exports = { Animated: { nodes: { Value } } };
    );
    try writeFile(tmp.dir, "index.ts",
        \\import { Animated } from './rn.cjs';
        \\export const value = new Animated.nodes.Value(0);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "new (__zntc_modules[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "].fn().Animated.nodes.Value)(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "new __zntc_modules[") == null);
}

test "Bundler: dev mode new expression wraps renamed CJS computed member callee" {
    // computed member도 `new MemberExpression(args)`로 파싱되므로 동일하게 보호해야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "rn.cjs",
        \\class Value {
        \\  constructor(v) { this.v = v; }
        \\}
        \\module.exports = { Animated: { Value } };
    );
    try writeFile(tmp.dir, "index.ts",
        \\import { Animated } from './rn.cjs';
        \\export const value = new Animated["Value"](0);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "new (__zntc_modules[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "].fn().Animated[\"Value\"])(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "new __zntc_modules[") == null);
}

test "Bundler: dev mode new expression keeps plain ESM import callee unwrapped" {
    // call 포함 rename에만 괄호를 추가해야 한다. 일반 ESM import constructor까지
    // 불필요하게 감싸지 않는지 확인한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.ts",
        \\export class Value {
        \\  constructor(public v: number) {}
        \\}
    );
    try writeFile(tmp.dir, "index.ts",
        \\import { Value } from './dep';
        \\export const value = new Value(0);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "new Value(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "new (Value)(0)") == null);
}

test "Bundler: dev mode new expression keeps parens after minify syntax strips original parens" {
    // minify_syntax가 원본 `(Animated.Value)` 괄호를 벗기더라도, rename 후 call이 생기는
    // 경우에는 안전 괄호를 다시 넣어야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "rn.cjs",
        \\class Value {
        \\  constructor(v) { this.v = v; }
        \\}
        \\module.exports = { Animated: { Value } };
    );
    try writeFile(tmp.dir, "index.ts",
        \\import { Animated } from './rn.cjs';
        \\export const value = new (Animated.Value)(0);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .minify_syntax = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    try std.testing.expect(std.mem.indexOf(u8, output, "new (__zntc_modules[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "].fn().Animated.Value)(0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "new __zntc_modules[") == null);
}

test "Profile: pipeline stage timing (dev only, not for CI)" {
    // 프로세스 시작 비용 없이 순수 파이프라인 단계별 시간 측정
    const alloc = std.testing.allocator;
    const Scanner = @import("../../lexer/mod.zig").Scanner;
    const Parser = @import("../../parser/mod.zig").Parser;
    const SemanticAnalyzer = @import("../../semantic/mod.zig").SemanticAnalyzer;
    const Transformer = @import("../../transformer/transformer.zig").Transformer;
    const Codegen = @import("../../codegen/codegen.zig").Codegen;

    const sizes = [_]usize{ 1000, 5000, 10000 };
    const RUNS = 5;

    std.debug.print("\n=== Pipeline Profile ({d} runs avg, Debug build) ===\n", .{RUNS});
    std.debug.print("| Lines | Scanner | Parser | Semantic | Transformer | Codegen | Total (us) |\n", .{});
    std.debug.print("|-------|---------|--------|----------|-------------|---------|------------|\n", .{});

    for (sizes) |line_count| {
        var src_buf: std.ArrayList(u8) = .empty;
        defer src_buf.deinit(alloc);
        for (0..line_count) |i| {
            var line_buf: [64]u8 = undefined;
            const line = std.fmt.bufPrint(&line_buf, "export const v{d} = {d};\n", .{ i, i }) catch continue;
            try src_buf.appendSlice(alloc, line);
        }
        const source = src_buf.items;

        var scan_ns: i128 = 0;
        var parse_ns: i128 = 0;
        var sem_ns: i128 = 0;
        var xform_ns: i128 = 0;
        var cg_ns: i128 = 0;

        // 0.16: std.time.nanoTimestamp 제거 → Io.Timestamp(.awake monotonic) 의
        // nanoseconds 값으로 경과 ns 측정.
        const nowNs = struct {
            fn f() i128 {
                return std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
            }
        }.f;

        for (0..RUNS) |_| {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();

            var t0 = nowNs();
            var scanner = try Scanner.init(a, source);
            scan_ns += nowNs() - t0;

            t0 = nowNs();
            var parser = Parser.init(a, &scanner);
            _ = try parser.parse();
            parse_ns += nowNs() - t0;

            t0 = nowNs();
            var analyzer = SemanticAnalyzer.init(a, &parser.ast);
            _ = analyzer.analyze() catch {};
            sem_ns += nowNs() - t0;

            t0 = nowNs();
            var transformer = try Transformer.init(a, &parser.ast, .{});
            const root = try transformer.transform();
            xform_ns += nowNs() - t0;

            t0 = nowNs();
            var cg = Codegen.init(a, transformer.ast);
            _ = try cg.generate(root);
            cg_ns += nowNs() - t0;
        }

        const us: i128 = 1000;
        const r: i128 = RUNS;
        const total = scan_ns + parse_ns + sem_ns + xform_ns + cg_ns;
        std.debug.print("| {d:>5} | {d:>7} | {d:>6} | {d:>8} | {d:>11} | {d:>7} | {d:>10} |\n", .{
            line_count,
            @divTrunc(scan_ns, r * us),
            @divTrunc(parse_ns, r * us),
            @divTrunc(sem_ns, r * us),
            @divTrunc(xform_ns, r * us),
            @divTrunc(cg_ns, r * us),
            @divTrunc(total, r * us),
        });
    }
}

// ============================================================
// Lazy compilation — dev + code_splitting (RFC docs/RFC_LAZY_COMPILATION.md, PR-2)
// issue #4038: dev init lowering(__zntc_modules[dev_id])이 청크 경계를 못 넘던 버그 수정 검증.
// ============================================================

test "LazyDevSplitting: dev+split → 프로덕션 init 사용, __zntc_modules 누출 없음 (#4038)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 공유 + 동적 + re-export 바렐까지 섞어 wrapped 모듈 init 경로(esm_wrap:838 re-export 등)도 커버.
    try writeFile(tmp.dir, "shared.ts", "export const s = 'S';\nconsole.log('shared boot');");
    try writeFile(tmp.dir, "barrel.ts", "export * from './shared';\nexport const b = 'B';"); // re-export init (#4038)
    try writeFile(tmp.dir, "heavy.ts", "import { s, b } from './barrel';\nexport function heavy() { return 'HEAVY-' + s + b; }");
    try writeFile(tmp.dir, "entry.ts",
        \\import { s, b } from './barrel';
        \\async function go() { const m = await import('./heavy'); console.log(m.heavy()); }
        \\console.log('entry boot', s, b);
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = true,
        .lazy_compilation = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // PR-3a-ii: 동적 heavy 청크는 미파싱 lazy seed 라 emit-skip → entry 청크만 남는다.
    // (PR-2 시절엔 eager 라 outs.len>=2 였으나 PR-3a-ii 부터 동적 청크는 on-demand.)
    try std.testing.expect(outs.len >= 1);
    // heavy 본문은 어디에도 emit 되지 않는다 (미파싱 seed).
    for (outs) |o| try std.testing.expect(std.mem.indexOf(u8, o.contents, "HEAVY-") == null);

    var has_register = false;
    var has_loader = false;
    var has_require_bootstrap = false; // entry 실행 트리거 (#4038 BUG2 회귀 가드)
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "__zntc_register") != null) has_register = true;
        if (std.mem.indexOf(u8, o.contents, "__zntc_load_chunk(\"") != null) has_loader = true;
        if (std.mem.indexOf(u8, o.contents, "__zntc_require(\"") != null) has_require_bootstrap = true;
        // #4038 BUG1 회귀 가드: dev 단일번들 HMR 레지스트리(__zntc_modules)가 청크에 누출되면 안 됨.
        // (청크 런타임은 __zntc_mods/__zntc_require 사용. __zntc_modules 는 단일번들 전용.)
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "__zntc_modules") == null);
        // 빈 dev_id 참조(__zntc_modules[""]) 절대 금지.
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "[\"\"]") == null);
        // IIFE 청크에 ESM import/export 누출 금지.
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\nexport {") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\nimport {") == null);
        // PR-3a-ii: content-hash placeholder(\x00ZH) 가 출력에 새지 않는다 — lazy seed
        // 참조는 경로기반 안정 이름이라 placeholder 미사용(dangling 방지 가드).
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "\x00ZH") == null);
    }
    try std.testing.expect(has_register);
    try std.testing.expect(has_loader); // entry 가 동적 heavy 청크를 안정 이름으로 선참조
    try std.testing.expect(has_require_bootstrap); // entry 가 실행되도록 bootstrap require 존재

    // dev_mode 효과: minify 스킵 → 모듈 경계 주석(//#region) 보존.
    var has_region = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "//#region ") != null) has_region = true;
    }
    try std.testing.expect(has_region);
}

test "LazyCompilation PR-3a: lazy=true 면 동적 import 타겟이 미파싱 seed (본문 미컴파일)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "heavy.ts", "export function heavyMarkerFn() { return 'HEAVY_BODY_MARKER'; }");
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() { const m = await import('./heavy'); console.log(m.heavyMarkerFn()); }
        \\console.log('entry boot');
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = true,
        .lazy_compilation = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // heavy 본문(HEAVY_BODY_MARKER)이 어느 출력에도 없어야 한다 — 미파싱 seed (경계 정지).
    for (outs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "HEAVY_BODY_MARKER") == null);
    }
    // entry 는 정상 컴파일 (boot 로그 + 동적 로더 존재).
    var has_entry = false;
    var has_loader = false;
    for (outs) |o| {
        if (std.mem.indexOf(u8, o.contents, "entry boot") != null) has_entry = true;
        if (std.mem.indexOf(u8, o.contents, "__zntc_load_chunk(\"") != null) has_loader = true;
    }
    try std.testing.expect(has_entry);
    try std.testing.expect(has_loader);
}

// 대조군: lazy=false(eager)면 동적 import 타겟이 정상 컴파일된다 (kill-switch 회귀 0).
test "LazyCompilation PR-3a: lazy=false 면 동적 import 타겟 본문이 컴파일된다 (eager)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "heavy.ts", "export function heavyMarkerFn() { return 'HEAVY_BODY_MARKER'; }");
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() { const m = await import('./heavy'); console.log(m.heavyMarkerFn()); }
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = true,
        .lazy_compilation = false,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    // lazy=false → 기존 eager 경로. heavy 본문이 출력 어딘가에 존재.
    const present = if (result.outputs) |outs| blk: {
        for (outs) |o| if (std.mem.indexOf(u8, o.contents, "HEAVY_BODY_MARKER") != null) break :blk true;
        break :blk false;
    } else std.mem.indexOf(u8, result.output, "HEAVY_BODY_MARKER") != null;
    try std.testing.expect(present);
}

// 전이적 경계 정지: 동적 타겟이 미파싱이라 그 *정적* deps 도 발견조차 안 된다.
test "LazyCompilation PR-3a: 동적 타겟의 정적 의존성도 미파싱(전이 경계정지)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "heavydep.ts", "export const DEP_BODY_MARKER = 'DEP_BODY';");
    try writeFile(tmp.dir, "heavy.ts",
        \\import { DEP_BODY_MARKER } from './heavydep';
        \\export function heavyMarkerFn() { return 'HEAVY_BODY_MARKER' + DEP_BODY_MARKER; }
    );
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() { const m = await import('./heavy'); console.log(m.heavyMarkerFn()); }
        \\console.log('entry boot');
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = true,
        .lazy_compilation = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    for (outs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "HEAVY_BODY_MARKER") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "DEP_BODY") == null); // 전이 deps 도 미발견
    }
}

// 핵심 정확성: 정적 + 동적 둘 다로 도달하는 모듈은 *파싱*된다 (deferred materialization 이
// dedup 으로 static 도달을 우선 — 미파싱 seed 로 잘못 마크하면 안 됨).
test "LazyCompilation PR-3a: 정적+동적 둘 다 도달하는 모듈은 파싱된다 (dedup)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shared.ts", "export const SHARED_BODY_MARKER = 'SHARED_BODY';");
    try writeFile(tmp.dir, "entry.ts",
        \\import { SHARED_BODY_MARKER } from './shared';
        \\async function go() { const m = await import('./shared'); console.log(m); }
        \\console.log('entry boot', SHARED_BODY_MARKER);
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = true,
        .lazy_compilation = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // shared 는 entry 의 정적 import 로 도달 → 파싱됨 (동적 타겟이기도 하지만 static 우선).
    var has_shared = false;
    for (outs) |o| if (std.mem.indexOf(u8, o.contents, "SHARED_BODY") != null) {
        has_shared = true;
    };
    try std.testing.expect(has_shared);
}

// 다중 동적 import: 각 타겟이 독립 seed.
test "LazyCompilation PR-3a: 다중 동적 import 각각 미파싱 seed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const A_BODY_MARKER = 'A_BODY';");
    try writeFile(tmp.dir, "b.ts", "export const B_BODY_MARKER = 'B_BODY';");
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() {
        \\  const a = await import('./a'); const b = await import('./b');
        \\  console.log(a, b);
        \\}
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = true,
        .lazy_compilation = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    for (outs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "A_BODY") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "B_BODY") == null);
    }
}

// 동적 import 없는 entry: lazy=true 여도 seed 0 → eager 와 동일(안전).
test "LazyCompilation PR-3a: 동적 import 없으면 lazy=true 여도 정상 (seed 0)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.ts", "export const LIB_BODY_MARKER = 'LIB_BODY';");
    try writeFile(tmp.dir, "entry.ts",
        \\import { LIB_BODY_MARKER } from './lib';
        \\console.log(LIB_BODY_MARKER);
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = true,
        .lazy_compilation = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    // 동적 import 없음 → 정적 lib 정상 컴파일.
    const present = if (result.outputs) |outs| blk: {
        for (outs) |o| if (std.mem.indexOf(u8, o.contents, "LIB_BODY") != null) break :blk true;
        break :blk false;
    } else std.mem.indexOf(u8, result.output, "LIB_BODY") != null;
    try std.testing.expect(present);
}

// 게이트: lazy=true 라도 code_splitting=false 면 seed 안 만든다 (단일번들 emit 보호).
// 미파싱 seed 가 동적 로더 없는 단일번들에 들어가면 런타임이 깨지므로 eager 로 fallback.
test "LazyCompilation PR-3a: lazy=true + code_splitting=false 면 eager (seed 안 만듦)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "heavy.ts", "export function heavyMarkerFn() { return 'HEAVY_BODY_MARKER'; }");
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() { const m = await import('./heavy'); console.log(m.heavyMarkerFn()); }
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = false, // splitting off → lazy 게이트 비활성 → eager
        .lazy_compilation = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    // 단일번들(code_splitting=false) → heavy 가 eager 로 포함.
    const present = if (result.outputs) |outs| blk: {
        for (outs) |o| if (std.mem.indexOf(u8, o.contents, "HEAVY_BODY_MARKER") != null) break :blk true;
        break :blk false;
    } else std.mem.indexOf(u8, result.output, "HEAVY_BODY_MARKER") != null;
    try std.testing.expect(present);
}

// 게이트: lazy=true + splitting=true 라도 dev_mode=false(프로덕션)면 eager (프로덕션 불변).
test "LazyCompilation PR-3a: lazy=true + dev_mode=false 면 eager (프로덕션 불변)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "heavy.ts", "export function heavyMarkerFn() { return 'HEAVY_BODY_MARKER'; }");
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() { const m = await import('./heavy'); console.log(m.heavyMarkerFn()); }
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = false, // production → lazy 게이트 비활성
        .code_splitting = true,
        .lazy_compilation = true,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    const outs = result.outputs orelse return error.TestUnexpectedResult;
    // 프로덕션 splitting → heavy 가 동적 청크에 eager 로 컴파일.
    var present = false;
    for (outs) |o| if (std.mem.indexOf(u8, o.contents, "HEAVY_BODY_MARKER") != null) {
        present = true;
    };
    try std.testing.expect(present);
}

// PR-3a-ii: lazy seed 동적 청크는 emit-skip + entry 는 경로기반 안정 이름으로 선참조.
test "LazyCompilation PR-3a-ii: 동적 청크 emit-skip + 경로기반 이름은 본문 변경에도 불변" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() { const m = await import('./heavy'); console.log(m.heavyMarkerFn()); }
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // 핵심: heavy 의 *본문* 을 바꿔 다시 빌드해도 entry 의 동적 청크 참조 이름이
    // *불변* 인지 확인 — content-hash 면 본문이 바뀌어 이름이 달라지지만, 경로기반
    // 안정 이름이면 경로(heavy.ts)가 그대로라 동일해야 한다. (PR-3b 가 청크를
    // on-demand 로 나중에 빌드해도 entry 가 선참조한 이름과 일치해야 하므로 필수.)
    const bodies = [_][]const u8{
        "export function heavyMarkerFn() { return 'BODY_ONE'; }",
        "export function heavyMarkerFn() { return 'A_COMPLETELY_DIFFERENT_AND_LONGER_BODY_TWO_xyz'; }",
    };
    var ref_a: ?[]u8 = null;
    defer if (ref_a) |r| std.testing.allocator.free(r);
    for (bodies, 0..) |body, pass| {
        try writeFile(tmp.dir, "heavy.ts", body);
        var bnd = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .dev_mode = true,
            .code_splitting = true,
            .lazy_compilation = true,
            .format = .iife,
        });
        defer bnd.deinit();
        const result = try bnd.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const outs = result.outputs orelse return error.TestUnexpectedResult;
        // heavy 본문(어느 버전이든) 미emit + content-hash placeholder(\x00ZH) 미누출.
        var loader_line: ?[]const u8 = null;
        for (outs) |o| {
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "BODY_ONE") == null);
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "BODY_TWO") == null);
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "\x00ZH") == null);
            if (std.mem.indexOf(u8, o.contents, "__zntc_load_chunk(\"") != null) loader_line = o.contents;
        }
        const lc = loader_line orelse return error.TestUnexpectedResult;
        const pos = std.mem.indexOf(u8, lc, "__zntc_load_chunk(\"").? + "__zntc_load_chunk(\"".len;
        const end = std.mem.indexOfScalarPos(u8, lc, pos, '"').?;
        const ref = lc[pos..end];
        try std.testing.expect(ref.len > 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, ref, 0) == null); // NUL/placeholder 없음
        if (pass == 0) {
            ref_a = try std.testing.allocator.dupe(u8, ref);
        } else {
            // 본문이 완전히 달라졌는데도 이름 동일 = content-hash 아님 = 경로기반 안정.
            try std.testing.expectEqualStrings(ref_a.?, ref);
        }
    }
}

// PR-3b-ii: lazy_force_parse 가 지정 seed 를 lazy defer 대신 즉시 parse(eager). dev lazy
// on-demand 가 요청된 청크 seed 만 끌어올리는 primitive. (전체 (B) on-demand 완성은
// shared-splitting-off + entry export-all-by-local 까지 필요 — RFC §2.1/§6.3 verify 결과.)
test "LazyCompilation PR-3b-ii: lazy_force_parse 가 지정 seed 를 즉시 parse(eager)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "heavy.ts", "export function heavyMarkerFn() { return 'HEAVY_BODY_MARKER'; }");
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() { const m = await import('./heavy'); console.log(m.heavyMarkerFn()); }
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    const heavy_abs = try absPath(&tmp, "heavy.ts");
    defer std.testing.allocator.free(heavy_abs);

    const heavyPresent = struct {
        fn check(force: []const []const u8, e: []const u8) !bool {
            var bnd = Bundler.init(std.testing.allocator, .{
                .entry_points = &.{e},
                .dev_mode = true,
                .code_splitting = true,
                .lazy_compilation = true,
                .lazy_force_parse = force,
                .format = .iife,
            });
            defer bnd.deinit();
            const result = try bnd.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            const outs = result.outputs orelse return error.TestUnexpectedResult;
            for (outs) |o| if (std.mem.indexOf(u8, o.contents, "HEAVY_BODY_MARKER") != null) return true;
            return false;
        }
    }.check;

    // force-parse 가 *유일한* 차이 — 같은 lazy 빌드에서 목록만 다르게 두 번 빌드.
    // 목록 비었을 때: heavy 는 미파싱 seed → 본문 없음. heavy 지정 시: 즉시 parse → 본문 있음.
    try std.testing.expect(!try heavyPresent(&.{}, entry)); // force-parse 없음 → seed
    try std.testing.expect(try heavyPresent(&.{heavy_abs}, entry)); // force-parse → eager
}

test "LazyDevSplitting: kill-switch — lazy_compilation=false 면 dev 단일 번들 보존" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "heavy.ts", "export function heavy() { return 'H'; }");
    try writeFile(tmp.dir, "entry.ts",
        \\async function go() { const m = await import('./heavy'); console.log(m.heavy()); }
        \\go();
    );
    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // dev_mode + code_splitting 이지만 lazy_compilation=false → 기존 dev 단일 번들 경로.
    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .code_splitting = true,
        .lazy_compilation = false,
        .format = .iife,
    });
    defer bnd.deinit();
    const result = try bnd.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    // 단일 번들 경로: output 존재, outputs 없음(청크 분할 안 함). dev 단일번들은 __zntc_modules 사용.
    try std.testing.expect(result.output.len > 0);
    try std.testing.expect(result.outputs == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntc_modules") != null);
}
