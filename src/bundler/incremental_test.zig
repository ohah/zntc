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

test "IncrementalBundler: conflict 가 사라진 cache-hit 모듈의 canonical_name UAF (strict)" {
    // Strict regression: Linker 가 build 1 에서 conflict rename 으로 b.ts 심볼에
    // canonical_name (build 1 의 canonical_strings 버퍼 포인터) 을 심는다.
    // Linker.deinit 이 그 버퍼를 free.
    //
    // build 2 에서 a.ts 를 수정해 conflict 가 사라지면, b.ts 는 cache-hit 인데
    // 새 Linker 의 calculateRenames 가 conflict 가 없으므로 b 심볼 canonical_name
    // 을 *재할당하지 않는다*. 따라서 build 1 의 stale pointer 가 그대로 살아
    // emit 이 freed memory 를 읽음.
    //
    // 수정 (graph.buildIncremental cache-hit reset): cache-hit 직후 모든 sem.symbols
    // 의 canonical_name 을 "" 로 리셋. conflict 재발 시 새 Linker 가 다시 assign,
    // 재발 안 하면 "" 그대로 → emit 이 fallback name (소스 span) 사용.
    //
    // 검증: post-build 2 에서 store 의 b.ts 심볼 canonical_name 이 빈 문자열
    // 이거나 (수정 후) garbage / freed pointer (수정 전) 인지 확인.
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

    // build 1: 전체 파싱, store 비어있음.
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    // build 2: incremental. store 가 채워짐 + a.ts/b.ts conflict rename 발생.
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
    // build 3: a.ts 의 export 이름 변경 → `count` 충돌 사라짐. b.ts 는 cache-hit.
    // 수정이 있으면: b 의 canonical_name 이 cache-hit reset 으로 "" 가 됨.
    // 수정이 없으면: build 2 의 stale pointer 그대로 — 0xAA 시작 garbage.
    try writeFile(tmp.dir, "a.ts", "export const other = 1;");
    try writeFile(tmp.dir, "index.ts",
        \\import { other as A } from './a';
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

    // post-build 3 store 검사. b.ts 의 모든 심볼 canonical_name 은:
    //   - 수정 후: "" (conflict 사라져 재할당 안 됨, reset 으로 빈 상태)
    //   - 수정 전: build 2 의 freed canonical_strings 포인터 → 0xAA 시작 garbage
    var it = ib.persistent_store.modules.iterator();
    while (it.next()) |store_entry| {
        if (!std.mem.endsWith(u8, store_entry.key_ptr.*, "b.ts")) continue;
        const sem = store_entry.value_ptr.module.semantic orelse continue;
        for (sem.symbols.items) |sym| {
            if (sym.canonical_name.len == 0) continue;
            const first = sym.canonical_name[0];
            const is_ident_start =
                (first >= 'a' and first <= 'z') or
                (first >= 'A' and first <= 'Z') or
                first == '_' or first == '$';
            if (!is_ident_start) {
                std.debug.print(
                    "garbage canonical_name first-byte 0x{x} in b.ts: {s}\n",
                    .{ first, sym.canonical_name },
                );
                return error.GarbageCanonicalName;
            }
        }
    }
}

test "BundleResult.reparsed_paths: cache-hit 모듈은 제외, cache-miss 만 포함" {
    // HMR `phantom updates` 필터의 source-of-truth. napi_entry 가 이 리스트로
    // cache-hit 모듈을 HMR payload 에서 제외하므로, 리스트가 정확해야 한다.
    //
    // 시나리오:
    //   build 1: 전체 파싱, reparsed_paths = null (non-incremental — module_store 미전달).
    //   build 2: util.ts 만 cache-miss (수정), index.ts 는 cache-hit.
    //            → reparsed_paths = [util.ts] 만 포함, index.ts 제외.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "util.ts", "export const x = 1;");
    try writeFile(tmp.dir, "index.ts", "import { x } from './util';\nconsole.log(x);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const util_path = try absPath(&tmp, "util.ts");
    defer std.testing.allocator.free(util_path);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
    });
    defer ib.deinit();

    // build 1: 전체 파싱.
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }

    // build 2 (incremental store seed): 파일은 변경 없지만 store 가 채워지는 시점.
    // IncrementalBundler 는 첫 빌드에서는 store 미전달, 두 번째부터 전달.
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }

    // build 3: util.ts 만 수정 → cache-miss. index.ts cache-hit.
    try writeFile(tmp.dir, "util.ts", "export const x = 999;");

    // BundleResult 를 직접 생성해 reparsed_paths 검사. IncrementalBundler 는
    // 내부적으로 Bundler.bundle() 을 호출하지만 결과를 노출하지 않으므로,
    // 같은 store 를 공유한 별도 Bundler 로 검증.
    const Bundler = @import("bundler.zig").Bundler;
    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .module_store = &ib.persistent_store,
    });
    defer bundler.deinit();

    var result = try bundler.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.reparsed_paths != null);
    const paths = result.reparsed_paths.?;
    // util.ts 는 포함, index.ts 는 제외.
    var saw_util = false;
    var saw_index = false;
    for (paths) |p| {
        if (std.mem.endsWith(u8, p, "util.ts")) saw_util = true;
        if (std.mem.endsWith(u8, p, "index.ts")) saw_index = true;
    }
    try std.testing.expect(saw_util);
    try std.testing.expect(!saw_index);
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

// ============================================================
// RFC #1672 Phase B2 — compiled output cache
// ============================================================

test "IncrementalBundler: compiled_cache populates on rebuild path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "export const hello = 'world';");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드 — mtime 이 Module 에 주입되지 않는 경로 (first-build). cache 비활성.
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }

    // 두 번째 빌드 — rebuild 경로에서 mtime 주입 → cache miss + put.
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(ib.compiled_cache.entries.count() >= 1);

    // 세 번째 빌드 — 동일 mtime/옵션 → cache hit 경로. 엔트리 개수 유지.
    const count_after_2 = ib.compiled_cache.entries.count();
    {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expectEqual(count_after_2, ib.compiled_cache.entries.count());
}

test "IncrementalBundler: compiled_cache invalidates on file change" {
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

    // 첫 빌드 (first-build: cache skip) + 두 번째 빌드 (rebuild: cache put).
    for (0..2) |_| {
        const r = try ib.rebuild();
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    const entries_before = ib.compiled_cache.entries.count();
    try std.testing.expect(entries_before >= 1);

    // util.ts 수정 → mtime 변경 → cache miss → 새 emit + put (기존 엔트리 교체).
    try writeFile(tmp.dir, "util.ts", "export const x = 42;");

    const result = try ib.rebuild();
    switch (result) {
        .success => |r| {
            defer freeChanged(r.changed_modules);
            try std.testing.expect(r.changed_modules.len > 0);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
    // 모듈 수 변동 없으므로 엔트리 개수는 유지 (put 이 기존 entry 교체).
    try std.testing.expectEqual(entries_before, ib.compiled_cache.entries.count());
}
