//! Regression: bun lockfile 의 hash 기반 dedup 으로 같은 패키지가 여러 사본
//! (`node_modules/.bun/<HASH>/node_modules/<pkg>/...`) 으로 설치되면, 두 사본의
//! 같은 모듈 (예: `expo/src/launch/registerRootComponent.tsx`) 이 모두 wrap 되면서
//! `makeVarNameWithPrefix` 가 path 의 마지막 `node_modules/` 이후만 보고 동일한
//! `exports_<pkg>_<...>` / `init_<pkg>_<...>` 변수 이름을 만들어 충돌.
//! 같은 export object 의 'default' getter 두 번 정의 → 두번째가 첫번째를 덮어씀
//! → 실제 사용처 chain 에 init 안 되어 undefined 참조 (`registerRootComponent is
//! not a function`).

const std = @import("std");
const testing = std.testing;
const helpers = @import("../test_helpers.zig");
const writeFile = helpers.writeFile;

fn bundleEntry(backing: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !helpers.Bundled {
    return helpers.bundleEntry(backing, tmp, entry_name, .{ .dev_mode = true });
}

// 두 디렉토리에 같은 basename 모듈 → wrap 시 exports/init 변수가 deconflict.
test "exports name dedup: 같은 basename 두 사본의 변수가 충돌하지 않음" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dir-a/foo.js", "export function value() { return 'a'; }");
    try writeFile(tmp.dir, "dir-b/foo.js", "export function value() { return 'b'; }");
    try writeFile(tmp.dir, "entry.js",
        \\import * as a from './dir-a/foo.js';
        \\import * as b from './dir-b/foo.js';
        \\globalThis.__out = a.value() + ':' + b.value();
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // 첫 사본: 그대로 base 이름
    try testing.expect(std.mem.indexOf(u8, code, "var exports_foo = {}") != null);
    try testing.expect(std.mem.indexOf(u8, code, "var init_foo = __esm") != null);

    // 두번째 사본: $2 suffix 로 deconflict
    try testing.expect(std.mem.indexOf(u8, code, "var exports_foo$2 = {}") != null);
    try testing.expect(std.mem.indexOf(u8, code, "var init_foo$2 = __esm") != null);

    // 같은 변수가 두 번 선언되면 codegen 의 두번째 `__export` 가 첫 getter 를 덮어씀.
    var count_decl: usize = 0;
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, code, search, "var exports_foo = {}")) |idx| {
        count_decl += 1;
        search = idx + 1;
    }
    try testing.expectEqual(@as(usize, 1), count_decl);
}

// 세 사본이면 base, $2, $3 — incremental suffix.
test "exports name dedup: 세 사본은 base, $2, $3 으로 incremental" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a/mod.js", "export const x = 1;");
    try writeFile(tmp.dir, "b/mod.js", "export const x = 2;");
    try writeFile(tmp.dir, "c/mod.js", "export const x = 3;");
    try writeFile(tmp.dir, "entry.js",
        \\import * as a from './a/mod.js';
        \\import * as b from './b/mod.js';
        \\import * as c from './c/mod.js';
        \\globalThis.__out = a.x + b.x + c.x;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    try testing.expect(std.mem.indexOf(u8, code, "var exports_mod = {}") != null);
    try testing.expect(std.mem.indexOf(u8, code, "var exports_mod$2 = {}") != null);
    try testing.expect(std.mem.indexOf(u8, code, "var exports_mod$3 = {}") != null);
}

// 충돌 없는 단일 모듈은 base 이름 유지 (over-fix 방지).
test "exports name dedup: 단일 사본은 suffix 없이 base 이름" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lonely.js", "export const v = 42;");
    try writeFile(tmp.dir, "entry.js",
        \\import * as m from './lonely.js';
        \\globalThis.__out = m.v;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    try testing.expect(std.mem.indexOf(u8, code, "var exports_lonely = {}") != null);
    // suffix 가 붙은 인스턴스가 있으면 안 됨
    try testing.expect(std.mem.indexOf(u8, code, "exports_lonely$") == null);
}

// ============================================================
// #3982: ambiguous export* (한 이름이 2+ distinct 소스에서 export *)
// ESM spec ResolveExport ambiguity — named import = error, namespace 멤버 = undefined.
// diamond(같은 underlying 모듈 2경로)는 ambiguous 아님.
// ============================================================

fn hasAmbiguousDiag(r: *const helpers.Bundled) bool {
    const diags = r.result.diagnostics orelse return false;
    for (diags) |d| {
        if (d.code == .ambiguous_export) return true;
    }
    return false;
}

test "ambiguous export*: 2개 distinct 소스의 같은 이름 named import 는 build error (#3982)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js", "export const shared = 'from-a';");
    try writeFile(tmp.dir, "b.js", "export const shared = 'from-b';");
    try writeFile(tmp.dir, "barrel.js", "export * from './a.js';\nexport * from './b.js';");
    try writeFile(tmp.dir, "entry.js",
        \\import { shared } from './barrel.js';
        \\globalThis.z = shared;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    // ESM spec: ambiguous → esbuild/rolldown/Node 처럼 build error 로 surface.
    try testing.expect(r.result.hasErrors());
    try testing.expect(hasAmbiguousDiag(&r));
}

test "ambiguous export*: 한 소스에만 있는 이름은 정상 해석 (#3982)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js", "export const only_a = 1;\nexport const shared = 'from-a';");
    try writeFile(tmp.dir, "b.js", "export const only_b = 2;\nexport const shared = 'from-b';");
    try writeFile(tmp.dir, "barrel.js", "export * from './a.js';\nexport * from './b.js';");
    try writeFile(tmp.dir, "entry.js",
        \\import { only_a } from './barrel.js';
        \\globalThis.z = only_a;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    // only_a 는 a.js 에만 있음 → 모호하지 않음 → 정상.
    try testing.expect(!r.result.hasErrors());
    try testing.expect(!hasAmbiguousDiag(&r));
}

test "ambiguous export*: diamond(같은 underlying 2경로)는 ambiguous 아님 (#3982)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "real.js", "export const shared = 'real';");
    try writeFile(tmp.dir, "p1.js", "export * from './real.js';");
    try writeFile(tmp.dir, "p2.js", "export * from './real.js';");
    try writeFile(tmp.dir, "barrel.js", "export * from './p1.js';\nexport * from './p2.js';");
    try writeFile(tmp.dir, "entry.js",
        \\import { shared } from './barrel.js';
        \\globalThis.z = shared;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    // shared 가 두 경로로 도달하지만 같은 canonical(real.js) → 모호하지 않음.
    try testing.expect(!r.result.hasErrors());
    try testing.expect(!hasAmbiguousDiag(&r));
}

test "ambiguous export*: namespace 멤버는 undefined — 객체서 제외 + void 0 rewrite (#3982)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js", "export const a = 1;\nexport const shared = 'from-a';");
    try writeFile(tmp.dir, "b.js", "export const b = 2;\nexport const shared = 'from-b';");
    try writeFile(tmp.dir, "barrel.js", "export * from './a.js';\nexport * from './b.js';");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './barrel.js';
        \\globalThis.z = [ns.a, ns.b, ns.shared];
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();
    // namespace 멤버 접근은 에러가 아님(undefined).
    try testing.expect(!r.result.hasErrors());
    // materialize 된 ns 객체에 ambiguous `shared` getter 가 없어야 한다(undefined).
    try testing.expect(std.mem.indexOf(u8, code, "get shared") == null);
}

test "ambiguous export*: namespace 멤버 rewrite 경로(minify, 비-dev)는 void 0 으로 치환 (#3982)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js", "export const a = 1;\nexport const shared = 'from-a';");
    try writeFile(tmp.dir, "b.js", "export const b = 2;\nexport const shared = 'from-b';");
    try writeFile(tmp.dir, "barrel.js", "export * from './a.js';\nexport * from './b.js';");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './barrel.js';
        \\globalThis.z = ns.shared;
    );

    // minify_identifiers + 비-dev → nsMemberRewriteSafe → 객체 materialize 대신
    // emitStaticMember 가 멤버를 직접 재작성하는 경로(registerNamespaceRewrites).
    var r = try helpers.bundleEntry(testing.allocator, &tmp, "entry.js", .{ .minify_identifiers = true });
    defer r.deinit();
    const code = r.code();
    try testing.expect(!r.result.hasErrors());
    // ambiguous `ns.shared` 는 `void 0` 로 재작성되어야 한다.
    try testing.expect(std.mem.indexOf(u8, code, "void 0") != null);
}

test "ambiguous export*: 3개 distinct 소스도 named import build error (#3982)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js", "export const shared = 'a';");
    try writeFile(tmp.dir, "b.js", "export const shared = 'b';");
    try writeFile(tmp.dir, "c.js", "export const shared = 'c';");
    try writeFile(tmp.dir, "barrel.js", "export * from './a.js';\nexport * from './b.js';\nexport * from './c.js';");
    try writeFile(tmp.dir, "entry.js",
        \\import { shared } from './barrel.js';
        \\globalThis.z = shared;
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(r.result.hasErrors());
    try testing.expect(hasAmbiguousDiag(&r));
}

test "ambiguous export*: 한 import 문에 ambiguous+정상 혼재 — ambiguous 만 진단 (#3982)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js", "export const only_a = 1;\nexport const shared = 'from-a';");
    try writeFile(tmp.dir, "b.js", "export const only_b = 2;\nexport const shared = 'from-b';");
    try writeFile(tmp.dir, "barrel.js", "export * from './a.js';\nexport * from './b.js';");
    try writeFile(tmp.dir, "entry.js",
        \\import { only_a, shared, only_b } from './barrel.js';
        \\globalThis.z = [only_a, shared, only_b];
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    // shared 만 ambiguous → 진단 1건. only_a/only_b 는 단일 소스라 정상 해석.
    try testing.expect(hasAmbiguousDiag(&r));
    var ambiguous_count: usize = 0;
    if (r.result.diagnostics) |diags| {
        for (diags) |d| {
            if (d.code == .ambiguous_export) ambiguous_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), ambiguous_count);
}

test "ambiguous export*: default 는 export * 비전파라 ambiguous 아님 (#3982)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // a/b 둘 다 default 가 있지만, ESM 에서 export * 는 default 를 재전파하지 않는다.
    try writeFile(tmp.dir, "a.js", "export default 'da';\nexport const a = 1;");
    try writeFile(tmp.dir, "b.js", "export default 'db';\nexport const b = 2;");
    try writeFile(tmp.dir, "barrel.js", "export * from './a.js';\nexport * from './b.js';");
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './barrel.js';
        \\globalThis.z = [ns.a, ns.b, ns.default];
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    // default 충돌은 ambiguous 진단을 내지 않는다(애초에 namespace 에 포함 안 됨).
    try testing.expect(!hasAmbiguousDiag(&r));
}
