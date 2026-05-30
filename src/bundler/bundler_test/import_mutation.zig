//! #4020: ESM import 바인딩/namespace 멤버 변형(assign/delete/update) 을 번들 단계에서
//! 거부. esbuild/rolldown parity — import 바인딩은 read-only, namespace 객체는 sealed.
//!   - `marker = v` / `delete marker` / `marker++` (import 바인딩 직접)        → 에러
//!   - `ns.x = v` / `delete ns.x` / `ns.x++` (namespace 멤버, `import * as ns`)  → 에러
//!   - `obj.x = v` (named import 객체 멤버) / `ns.a.b = v` (중첩) / shadowing      → 합법
//! 검출은 semantic analyzer(번들 단계 gate), 진단(ZNTC0805)은 parse_module 가 fatal 로 승격.
//! single-file transform/transpile 은 통과(esbuild transform parity, gate off).

const std = @import("std");
const testing = std.testing;
const helpers = @import("../test_helpers.zig");
const writeFile = helpers.writeFile;

fn bundleEntry(backing: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !helpers.Bundled {
    return helpers.bundleEntry(backing, tmp, entry_name, .{ .scope_hoist = true, .tree_shaking = true });
}

fn hasImportMutationDiag(r: *const helpers.Bundled) bool {
    const diags = r.result.diagnostics orelse return false;
    for (diags) |d| {
        if (d.code == .assign_to_import) return true;
    }
    return false;
}

fn writeMod(tmp: *std.testing.TmpDir) !void {
    try writeFile(tmp.dir, "mod.js",
        \\export const marker = 1;
        \\export let mutable = 2;
        \\export const obj = { x: 1 };
    );
}

// ============================================================
// 에러: import 바인딩/namespace 멤버 변형
// ============================================================

test "import mutation: delete ns.member 는 build error (존재 멤버)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.r = delete ns.marker;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(r.result.hasErrors());
    try testing.expect(hasImportMutationDiag(&r));
}

test "import mutation: delete ns.member 는 build error (미존재 멤버)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.r = delete ns.nope;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(hasImportMutationDiag(&r));
}

test "import mutation: ns.member = v 는 build error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\ns.marker = 5;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(hasImportMutationDiag(&r));
}

test "import mutation: ns.member++ 는 build error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\ns.marker++;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(hasImportMutationDiag(&r));
}

test "import mutation: named import 직접 재대입(marker = v)은 build error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import { marker } from './mod.js';
        \\globalThis.x = 1;
        \\marker = 5;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(hasImportMutationDiag(&r));
}

test "import mutation: let export 직접 재대입(mutable = v)은 build error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import { mutable } from './mod.js';
        \\mutable = 5;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(hasImportMutationDiag(&r));
}

// ============================================================
// 합법: false-positive 가드
// ============================================================

test "import mutation: named import 객체 멤버 변형(obj.x = v)은 합법" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import { obj } from './mod.js';
        \\obj.x = 5;
        \\globalThis.r = obj.x;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(!hasImportMutationDiag(&r));
    try testing.expect(!r.result.hasErrors());
}

test "import mutation: namespace 의 *중첩* 멤버(ns.obj.x = v)는 합법" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.r = ns.obj;
        \\ns.obj.x = 5;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(!hasImportMutationDiag(&r));
}

test "import mutation: 같은 이름 local 이 shadow 하면 합법" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.r = ns.marker;
        \\function f(ns) { ns.marker = 5; return ns; }
        \\globalThis.f = f;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(!hasImportMutationDiag(&r));
}

test "import mutation: import 읽기(ns.marker)는 합법" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.r = ns.marker;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(!hasImportMutationDiag(&r));
    try testing.expect(!r.result.hasErrors());
}

test "import mutation: 자기 export let 재대입(x = v)은 합법" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\export let x = 1;
        \\x = 5;
        \\globalThis.r = x;
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(!hasImportMutationDiag(&r));
}

// ============================================================
// max-review 가 적발한 우회 경로 (for-in/of · destructuring · wrapper) — 전부 거부.
// ============================================================

fn expectMutationErr(comptime src: []const u8) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js", src);
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(hasImportMutationDiag(&r));
}

test "import mutation: for-in/of LHS 가 import 바인딩/namespace 멤버면 build error" {
    try expectMutationErr("import * as ns from './mod.js'; for (ns.marker in {a:1}) {}");
    try expectMutationErr("import { marker } from './mod.js'; for (marker of [1,2]) {}");
    try expectMutationErr("import * as ns from './mod.js'; for (ns.marker of [1]) {}");
}

test "import mutation: destructuring assignment target 도 leaf 까지 검출" {
    try expectMutationErr("import { marker } from './mod.js'; [marker] = [5];");
    try expectMutationErr("import { marker } from './mod.js'; ({ a: marker } = { a: 5 });");
    try expectMutationErr("import * as ns from './mod.js'; [ns.marker] = [5];");
    try expectMutationErr("import { marker } from './mod.js'; [...marker] = [5];");
    try expectMutationErr("import { mutable } from './mod.js'; ({ mutable } = { mutable: 5 });");
}

test "import mutation: parenthesized / TS wrapper 타겟도 언래핑해 검출" {
    try expectMutationErr("import { marker } from './mod.js'; (marker) = 5;");
    try expectMutationErr("import * as ns from './mod.js'; (ns.marker) = 5;");
    try expectMutationErr("import * as ns from './mod.js'; globalThis.r = delete (ns.marker);");
    try expectMutationErr("import { mutable } from './mod.js'; mutable! = 5;");
    try expectMutationErr("import * as ns from './mod.js'; ns.marker! = 5;");
}

test "import mutation: for-in/of 의 선언 head / 로컬 destructure 는 합법" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeMod(&tmp);
    try writeFile(tmp.dir, "entry.js",
        \\import * as ns from './mod.js';
        \\globalThis.r = ns.marker;
        \\for (let k in { a: 1 }) { globalThis.k = k; }
        \\for (const [v] of [[1]]) { globalThis.v = v; }
    );
    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    try testing.expect(!hasImportMutationDiag(&r));
    try testing.expect(!r.result.hasErrors());
}
