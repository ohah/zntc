const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;

// #4178 회귀 가드: 다수 모듈이 동일 namespace 를 `import * as NS` + member-access(`NS.x`) 하면,
// `LinkingMetadata.deinit` 의 ns_member_rewrites '{' free 휴리스틱이 borrowed(owned_rename_values
// 등 다른 소유자) 값을 dangling read/double-free → 병렬 emit 에서 flaky segfault 였다(fix 전
// 결정적 재현). 충분한 모듈 수(병렬 emit range 분할 + 공유 ns inline 트리거)가 필요.
test "ns_dblfree #4178: dev 다수 모듈 동일 namespace member-access 가 crash 안 함" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "shared.ts", "export const a = 1;\nexport const b = 2;\nexport const c = 3;\nexport const d = 4;\n");
    var idx: std.ArrayList(u8) = .empty;
    defer idx.deinit(std.testing.allocator);
    const N = 40;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        var pbuf: [32]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "m{d}.ts", .{i});
        var sbuf: [128]u8 = undefined;
        const s = try std.fmt.bufPrint(&sbuf, "import * as NS from './shared';\nexport const x{d} = NS.a + NS.b + NS.c + NS.d;\n", .{i});
        try writeFile(tmp.dir, p, s);
        try idx.print(std.testing.allocator, "import {{ x{d} }} from './m{d}';\nconsole.log(x{d});\n", .{ i, i, i });
    }
    try writeFile(tmp.dir, "index.ts", idx.items);

    const entry = try test_helpers.absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = true,
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer b.deinit();
    const r = try b.bundle(std.testing.io);
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!r.hasErrors());
}
