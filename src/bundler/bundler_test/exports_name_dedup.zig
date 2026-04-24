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
