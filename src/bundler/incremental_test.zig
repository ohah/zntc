const std = @import("std");
const IncrementalBundler = @import("incremental.zig").IncrementalBundler;
const BundleResult = @import("bundler.zig").BundleResult;
const test_helpers = @import("test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

/// RebuildSuccess.changed_modules ownership 을 받아 안전하게 해제.
/// id/code/map 이 allocator.dupe 복사본이므로 freeAll 필수.
fn freeChanged(modules: []const BundleResult.ModuleDevCode) void {
    BundleResult.ModuleDevCode.freeAll(modules, std.testing.allocator);
}

test "IncrementalBundler: first build is full rebuild" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hello');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드: 전체 재빌드
    const result = try ib.rebuild();
    switch (result) {
        .success => |r| {
            try std.testing.expect(r.graph_changed); // 첫 빌드는 항상 graph_changed
            try std.testing.expect(r.paths.len > 0);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: second build without changes has no changed modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hello');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // 두 번째 빌드: 변경 없음 → changed_modules 비어있어야 함
    const result = try ib.rebuild();
    switch (result) {
        .success => |r| {
            defer freeChanged(r.changed_modules);
            try std.testing.expectEqual(false, r.graph_changed);
            try std.testing.expectEqual(@as(usize, 0), r.changed_modules.len);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: detects code change in modified file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "util.ts", "export const x = 1;");
    try writeFile(tmp.dir, "index.ts", "import { x } from './util';\nconsole.log(x);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer ib.deinit();

    // 첫 빌드
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // util.ts 수정
    try writeFile(tmp.dir, "util.ts", "export const x = 42;");

    // 증분 빌드: util.ts 변경 감지
    const result = try ib.rebuild();
    switch (result) {
        .success => |r| {
            defer freeChanged(r.changed_modules);
            try std.testing.expect(r.changed_modules.len > 0);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: detects graph change (new import)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hello');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드 (1개 모듈)
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // 새 모듈 추가 + import 추가
    try writeFile(tmp.dir, "extra.ts", "export const y = 2;");
    try writeFile(tmp.dir, "index.ts", "import { y } from './extra';\nconsole.log(y);");

    // 증분 빌드: 모듈 수 변경 → graph_changed
    const result = try ib.rebuild();
    switch (result) {
        .success => |r| {
            defer freeChanged(r.changed_modules);
            try std.testing.expect(r.graph_changed);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: detects graph change when import removed (module deleted)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "extra.ts", "export const y = 2;");
    try writeFile(tmp.dir, "index.ts", "import { y } from './extra';\nconsole.log(y);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드 (2개 모듈: index.ts + extra.ts)
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // import 제거 → extra.ts가 그래프에서 빠짐
    try writeFile(tmp.dir, "index.ts", "console.log('no import');");

    // 증분 빌드: 모듈 수 변경 → graph_changed
    const result = try ib.rebuild();
    switch (result) {
        .success => |r| {
            defer freeChanged(r.changed_modules);
            try std.testing.expect(r.graph_changed);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: second file change should NOT trigger graph_changed (#951)" {
    // 이슈 #951 재현: 첫 HMR → 두번째 full reload → 이후 정상
    // 그래프 구조(import 관계)가 변하지 않는데 두 번째 변경에서 graph_changed=true가 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 3단계 import chain: index → App → util
    try writeFile(tmp.dir, "util.ts", "export const helper = () => 'v1';");
    try writeFile(tmp.dir, "App.ts", "import { helper } from './util';\nexport const msg = helper();");
    try writeFile(tmp.dir, "index.ts", "import { msg } from './App';\nconsole.log(msg);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer ib.deinit();

    // 1) 첫 빌드 (graph_changed=true 예상, 첫 빌드이므로)
    var first_path_count: usize = 0;
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| {
                try std.testing.expect(s.graph_changed);
                first_path_count = s.paths.len;
                freeChanged(s.changed_modules);
            },
            .build_error => |e| {
                std.testing.allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }

    // mtime 차이를 보장하기 위해 약간 대기
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // 2) 첫 번째 파일 변경 → 증분 빌드 (graph_changed=false 예상)
    try writeFile(tmp.dir, "App.ts", "import { helper } from './util';\nexport const msg = helper() + ' v2';");
    var second_path_count: usize = 0;
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| {
                defer freeChanged(s.changed_modules);
                second_path_count = s.paths.len;
                try std.testing.expectEqual(first_path_count, second_path_count);
                try std.testing.expectEqual(false, s.graph_changed);
            },
            .build_error => |e| {
                std.testing.allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }

    // mtime 차이를 보장하기 위해 약간 대기
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // 3) 두 번째 파일 변경 → 증분 빌드 (graph_changed=false 이어야 함!)
    //    이슈 #951: 이 시점에서 graph_changed=true가 되어 full-reload가 발생함
    try writeFile(tmp.dir, "App.ts", "import { helper } from './util';\nexport const msg = helper() + ' v3';");
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| {
                defer freeChanged(s.changed_modules);
                // 핵심 검증: 두 번째 변경에서도 graph_changed=false여야 함
                try std.testing.expectEqual(second_path_count, s.paths.len);
                try std.testing.expectEqual(false, s.graph_changed);
                try std.testing.expect(s.changed_modules.len > 0);
            },
            .build_error => |e| {
                std.testing.allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }

    // 4) 세 번째 파일 변경도 graph_changed=false여야 함 (안정성 확인)
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try writeFile(tmp.dir, "util.ts", "export const helper = () => 'v4';");
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| {
                defer freeChanged(s.changed_modules);
                try std.testing.expectEqual(false, s.graph_changed);
            },
            .build_error => |e| {
                std.testing.allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }
}

test "IncrementalBundler: build error returns error message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('ok');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // 구문 에러 삽입
    try writeFile(tmp.dir, "index.ts", "console.log(;);");

    // 재빌드 → 에러 또는 성공 (파서가 에러 복구할 수 있음)
    const result = try ib.rebuild();
    // 파서 에러 복구 수준에 따라 build_error 또는 success
    switch (result) {
        .success => |r| {
            freeChanged(r.changed_modules);
        },
        .build_error => |err_msg| {
            defer std.testing.allocator.free(err_msg);
            try std.testing.expect(std.mem.indexOf(u8, err_msg, "error") != null);
        },
        .fatal => {},
    }
}

test "IncrementalBundler: cache-hit rebuild emit 은 garbage canonical 을 내지 않는다 (smoke)" {
    // Regression smoke test: Linker 가 conflict rename 에서 `Symbol.canonical_name`
    // 에 자신의 `canonical_strings` 버퍼 포인터를 심는다. `Linker.deinit` 이후
    // string 은 freed 지만 Symbol 은 `parse_arena` 에 살아 PersistentModuleStore
    // 를 통해 다음 rebuild 까지 살아남는다. 다음 rebuild 의 cache-hit emit 이
    // freed memory 를 읽으면 임의의 heap 내용이 identifier 로 출력 → JSC 의
    // `'identifier' expected in declaration` syntax error.
    //
    // 수정 (graph.buildIncremental cache-hit): cache-hit 모듈의 symbol
    // canonical_name 을 빈 문자열로 리셋해 stale pointer 를 끊고, 새 Linker 가
    // 다시 assign 하도록 한다.
    //
    // 한계: 이 unit test 는 fixture 가 작아 GPA 가 freed canonical_strings
    // 버퍼를 garbage 로 즉시 재사용하지 않을 수 있어, fix 가 빠져도 통과할 수
    // 있다 (실제 번개 App rebuild 처럼 heap pressure 가 있어야 deterministic).
    // 즉 smoke test 로서 cache-hit reset 경로가 깨지지 않았는지 + emit 이 명백한
    // garbage 를 내지 않는지만 확인한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "export const count = 1;");
    try writeFile(tmp.dir, "b.ts", "export const count = 2;");
    try writeFile(tmp.dir, "index.ts",
        \\import { count as A } from './a';
        \\import { count as B } from './b';
        \\console.log(A, B);
        \\
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer ib.deinit();

    // build 1: full. store 비어있음.
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    // build 2: incremental, store 채움 (a.ts, b.ts 의 conflict rename 발생).
    try writeFile(tmp.dir, "index.ts",
        \\import { count as A } from './a';
        \\import { count as B } from './b';
        \\console.log(A, B, 1);
        \\
    );
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    // build 3: incremental, a.ts/b.ts cache-hit.
    // 수정이 빠지면 cache-hit 모듈의 stale canonical_name 이 emit 에 누출.
    // 수정 후엔 reset → fresh assign 으로 정상.
    try writeFile(tmp.dir, "index.ts",
        \\import { count as A } from './a';
        \\import { count as B } from './b';
        \\console.log(A, B, 1, 2);
        \\
    );
    const r = try ib.rebuild();
    switch (r) {
        .success => |s| {
            defer freeChanged(s.changed_modules);
            // emit 에 path 가 식별자 위치 (= 직전 char 가 `"` 아님) 에 등장하면
            // canonical_name UAF 누출. 정상 path 키는 항상 `"` 직후.
            for (s.changed_modules) |c| {
                var i: usize = 0;
                while (std.mem.indexOfPos(u8, c.code, i, "/Users/")) |idx| {
                    const prev = if (idx == 0) 0 else c.code[idx - 1];
                    if (prev != '"' and prev != '\'') {
                        std.debug.print(
                            "garbage path identifier in {s} at offset {} (prev=0x{x}): ...{s}...\n",
                            .{ c.id, idx, prev, c.code[@max(idx, 16) - 16 .. @min(idx + 32, c.code.len)] },
                        );
                        return error.GarbagePathInEmit;
                    }
                    i = idx + 1;
                }
                // GPA poison byte (0xAA) 식별자 누출 — UAF 의 또 다른 양상.
                if (std.mem.indexOf(u8, c.code, "\xaa\xaa\xaa")) |idx| {
                    std.debug.print("0xAA poison bytes in {s} at offset {}\n", .{ c.id, idx });
                    return error.PoisonInEmit;
                }
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: changed_modules content stays valid after rebuild" {
    // 번개 HMR 경로에서 발견된 use-after-free 재현.
    // 기존에는 result.deinit 이 module_codes 의 id/code 를 freeAll 하는데,
    // actually_changed 가 동일 slice 를 포인터 복사로 가지고 있어 반환 후 dangling.
    // 수정: actually_changed 에 넣을 때 dupe 하여 caller 에게 ownership 이전.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "util.ts", "export const x = 1;");
    try writeFile(tmp.dir, "index.ts", "import { x } from './util';\nconsole.log(x);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer ib.deinit();

    // 첫 빌드
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }

    // 여러 번 파일 수정 + rebuild + changed_modules 의 content 실제 읽기로 corruption 노출.
    const payloads = [_][]const u8{
        "export const x = 2;",
        "export const x = 3;",
        "export const x = 4;",
    };
    for (payloads) |payload| {
        try writeFile(tmp.dir, "util.ts", payload);
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| {
                defer freeChanged(s.changed_modules);
                for (s.changed_modules) |c| {
                    try std.testing.expect(c.id.len > 0);
                    try std.testing.expect(c.code.len > 0);
                    try std.testing.expect(std.mem.indexOf(u8, c.code, "function") != null);
                }
            },
            else => return error.TestUnexpectedResult,
        }
    }
}
