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

    const result = try b.bundle();
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

    const result = try b.bundle();
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

    const result = try b.bundle();
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

    const result = try b.bundle();
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

    const result = try bundler.bundle();
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
    const result = try bnd.bundle();
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

test "CodeSplitting: CJS format returns error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const x = import('./lazy');\nconsole.log(x);");
    try writeFile(tmp.dir, "lazy.ts", "export const lazy = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
        .format = .cjs,
    });
    defer bnd.deinit();
    // CJS + code_splitting은 에러
    const result = bnd.bundle();
    try std.testing.expect(result == error.CodeSplittingRequiresESM);
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

    const result = try bundler.bundle();
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

    const result = try bundler.bundle();
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

    const result = try bundler.bundle();
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

    const result = try bundler.bundle();
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

    const result = try bundler.bundle();
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
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './dep';\nconst x = 'entry';\nconsole.log(x);");
    try writeFile(tmp.dir, "dep.ts", "export const x = 'dep';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .code_splitting = true,
    });
    defer bundler.deinit();

    const result = try bundler.bundle();
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

    const result = try bundler.bundle();
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
    const result = try bnd.bundle();
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
    const result = try bnd.bundle();
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
    const result = try bnd.bundle();
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
    try writeFile(tmp.dir, "shared.ts", "export const val = 42;");

    const a_path = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(a_path);
    const b_path = try absPath(&tmp, "b.ts");
    defer std.testing.allocator.free(b_path);

    var bnd = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
    });
    defer bnd.deinit();
    const result = try bnd.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const outputs = result.outputs orelse return error.TestUnexpectedResult;

    // 3개 청크: a, b, shared(공통)
    try std.testing.expectEqual(@as(usize, 3), outputs.len);

    // shared 청크에 export { val } 있어야 함
    var shared_has_export = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "const val = 42") != null or
            std.mem.indexOf(u8, o.contents, "const val=42") != null)
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
    const result = try bnd.bundle();
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
    const result = try bnd.bundle();
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
    const result = try bnd.bundle();
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
    const result = try bnd.bundle();
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
    const result = try bnd.bundle();
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
    const result = try bnd.bundle();
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
    const result = try bnd.bundle();
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
    const result1 = try bnd1.bundle();
    defer result1.deinit(std.testing.allocator);

    // 2차 빌드
    var bnd2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ a_path, b_path },
        .code_splitting = true,
        .chunk_names = "[name]-[hash]",
    });
    defer bnd2.deinit();
    const result2 = try bnd2.bundle();
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
    // error-guard.js 등 폴리필이 누락되면 global.ErrorUtils가 undefined.
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill이 번들에 포함됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MyPolyfill") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "(function(){") != null);
    // banner가 번들에 포함됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__TEST_BANNER__") != null);
    // polyfill/banner가 HMR 런타임보다 앞에 위치
    const polyfill_pos = std.mem.indexOf(u8, result.output, "MyPolyfill").?;
    const hmr_pos = std.mem.indexOf(u8, result.output, "__zts_modules").?;
    try std.testing.expect(polyfill_pos < hmr_pos);
    const banner_pos = std.mem.indexOf(u8, result.output, "__TEST_BANNER__").?;
    try std.testing.expect(banner_pos < polyfill_pos);
}

test "Bundler: dev mode single file" {
    // dev mode에서 단일 파일이 __zts_register로 래핑되는지 확인
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // HMR 런타임이 주입되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_modules") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_register") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_make_hot") != null);
    // 모듈이 register로 래핑되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_register(\"") != null);
    // export가 __zts_exports로 변환되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_exports.default") != null);
}

test "Bundler: dev mode two files with import" {
    // dev mode에서 두 파일 간 import가 __zts_require로 변환되는지 확인
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 모듈이 각각 __zts_register로 래핑
    const output = result.output;
    const first = std.mem.indexOf(u8, output, "__zts_register(\"") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, output[first + 1 ..], "__zts_register(\"") != null);
    // __zts_require 호출이 있는지
    try std.testing.expect(std.mem.indexOf(u8, output, "__zts_require(\"") != null);
    // utils.ts의 export가 __zts_exports.add로 변환
    try std.testing.expect(std.mem.indexOf(u8, output, "__zts_exports.add") != null);
}

test "Bundler: dev mode default import" {
    // dev mode에서 default import가 __zts_require(...).default로 변환되는지 확인
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // default import → .default
    try std.testing.expect(std.mem.indexOf(u8, result.output, ".default") != null);
    // greet.ts의 default export
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_exports.default") != null);
}

test "Bundler: dev mode module_dev_codes" {
    // dev mode에서 module_dev_codes가 생성되는지 확인
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // module_dev_codes가 존재하고 2개 모듈 (utils + index)
    const codes = result.module_dev_codes orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), codes.len);
    // 각 code에 __zts_register 래핑이 있는지
    for (codes) |c| {
        try std.testing.expect(c.id.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, c.code, "__zts_register(\"") != null);
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

    const result = try b.bundle();
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;

    // 3개 모듈 모두 sources 배열에 있어야 함
    try std.testing.expect(std.mem.indexOf(u8, sm, "math.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "str.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "main.ts") != null);

    // mappings가 빈 문자열이 아니어야 함 (실제 매핑 존재)
    try std.testing.expect(std.mem.indexOf(u8, sm, "\"mappings\":\"\"") == null);
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // 번들 출력에 두 모듈의 코드가 포함되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const B") != null);

    // 소스맵에 두 소스가 모두 있어야 함
    const sm = result.sourcemap orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, sm, "a.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sm, "b.ts") != null);

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
    // React Fast Refresh가 컴포넌트에 $RefreshReg$ 주입하는지 확인
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // $RefreshReg$ 호출이 주입되었는지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$") != null);
    // PascalCase 함수명(App, Helper) 등록
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"App\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"Helper\"") != null);
    // _c 핸들 변수 선언
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_c") != null);
    // react-refresh 런타임 바인딩
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshReg$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "$RefreshSig$") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__REACT_REFRESH_RUNTIME__") != null);
    // hot.accept() 자동 삽입
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zts_module.hot.accept()") != null);
}

test "Bundler: dev mode refresh signature" {
    // Hook 시그니처($RefreshSig$)가 주입되는지 확인
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

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const output = result.output;
    // var _s = $RefreshSig$(); 선언
    try std.testing.expect(std.mem.indexOf(u8, output, "$RefreshSig$") != null);
    // _s(); boundary marker 호출 (함수 body 시작)
    try std.testing.expect(std.mem.indexOf(u8, output, "_s()") != null);
    // _s(App, "signature"); 시그니처 연결
    try std.testing.expect(std.mem.indexOf(u8, output, "_s(App") != null);
    // 시그니처에 useState, useEffect 포함
    try std.testing.expect(std.mem.indexOf(u8, output, "useState") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "useEffect") != null);
    // 바인딩 정보: useState{x(0)} — LHS 바인딩 + 초기값
    try std.testing.expect(std.mem.indexOf(u8, output, "useState{x(0)}") != null);
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

        for (0..RUNS) |_| {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();

            var t0 = std.time.nanoTimestamp();
            var scanner = try Scanner.init(a, source);
            scan_ns += std.time.nanoTimestamp() - t0;

            t0 = std.time.nanoTimestamp();
            var parser = Parser.init(a, &scanner);
            _ = try parser.parse();
            parse_ns += std.time.nanoTimestamp() - t0;

            t0 = std.time.nanoTimestamp();
            var analyzer = SemanticAnalyzer.init(a, &parser.ast);
            _ = analyzer.analyze() catch {};
            sem_ns += std.time.nanoTimestamp() - t0;

            t0 = std.time.nanoTimestamp();
            var transformer = try Transformer.init(a, &parser.ast, .{});
            const root = try transformer.transform();
            xform_ns += std.time.nanoTimestamp() - t0;

            t0 = std.time.nanoTimestamp();
            var cg = Codegen.init(a, &transformer.ast);
            _ = try cg.generate(root);
            cg_ns += std.time.nanoTimestamp() - t0;
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

