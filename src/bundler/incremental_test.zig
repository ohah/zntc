const std = @import("std");
const Bundler = @import("bundler.zig").Bundler;
const IncrementalBundler = @import("incremental.zig").IncrementalBundler;
const BundleResult = @import("bundler.zig").BundleResult;
const CompiledOutputCache = @import("compiled_cache.zig").CompiledOutputCache;
const module_store = @import("module_store.zig");
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
    const result = try ib.rebuild(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // 두 번째 빌드: 변경 없음 → changed_modules 비어있어야 함
    const result = try ib.rebuild(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // util.ts 수정
    try writeFile(tmp.dir, "util.ts", "export const x = 42;");

    // 증분 빌드: util.ts 변경 감지
    const result = try ib.rebuild(std.testing.io);
    switch (result) {
        .success => |r| {
            defer freeChanged(r.changed_modules);
            try std.testing.expect(r.changed_modules.len > 0);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: changed module code keeps bundle require rewrites" {
    // Expo/RN dev server 회귀 재현:
    // clean bundle에서는 import/asset require가 require_xxx()로 치환되지만,
    // 증분 HMR payload에서 원본 specifier require가 다시 emit되면 런타임 resolver가
    // `@/...` 또는 asset specifier를 처리하지 못하고 무한 reload/fallback으로 이어진다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "dep.ts", "export const label = 'dep';");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.png", .data = &.{ 0x89, 0x50, 0x4E, 0x47 } });
    try writeFile(tmp.dir, "index.ts",
        \\import { label } from './dep';
        \\const icon = require('./icon.png');
        \\console.log(label, icon, 1);
    );

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .collect_module_codes = true,
        .loader_overrides = &.{.{ .ext = ".png", .loader = .dataurl }},
    });
    defer ib.deinit();

    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| {
                std.testing.allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }

    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    try writeFile(tmp.dir, "index.ts",
        \\import { label } from './dep';
        \\const icon = require('./icon.png');
        \\console.log(label, icon, 2);
    );

    const result = try ib.rebuild(std.testing.io);
    switch (result) {
        .success => |r| {
            defer freeChanged(r.changed_modules);
            try std.testing.expect(r.changed_modules.len > 0);

            var saw_index = false;
            for (r.changed_modules) |m| {
                if (std.mem.indexOf(u8, m.id, "index.ts") == null) continue;
                saw_index = true;
                try std.testing.expect(std.mem.indexOf(u8, m.code, "require('./icon.png')") == null);
                try std.testing.expect(std.mem.indexOf(u8, m.code, "require(\"./icon.png\")") == null);
                try std.testing.expect(std.mem.indexOf(u8, m.code, "require('./dep')") == null);
                try std.testing.expect(std.mem.indexOf(u8, m.code, "require(\"./dep\")") == null);
                // dev 모드 HMR module code 는 bundle-local `require_icon` 가 보이지 않으므로
                // CJS require rewrite 도 `__zntc_modules["..."].fn()` registry lookup 형태.
                try std.testing.expect(std.mem.indexOf(u8, m.code, "require_icon()") == null);
                try std.testing.expect(std.mem.indexOf(u8, m.code, "__zntc_modules[") != null);
                try std.testing.expect(std.mem.indexOf(u8, m.code, "icon.png\"].fn()") != null);
            }
            try std.testing.expect(saw_index);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "IncrementalBundler: changed HMR module rewrites mixed alias imports" {
    // 테스트앱 재현: 증분 HMR payload에서 alias import가 raw `require("~/...")`
    // 로 돌아오면 RN eval 스코프에서 global require가 없어 실패한다.
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
        \\  return [appDefaults.mode, LoadingRing, 1];
        \\}
    );

    const entry = try absPath(&tmp, "src/App.tsx");
    defer std.testing.allocator.free(entry);
    const root = try absPath(&tmp, ".");
    defer std.testing.allocator.free(root);
    const src_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/src/", .{root});
    defer std.testing.allocator.free(src_prefix);

    const ts_path_targets = [_]@import("../config.zig").TsConfig.PathEntry.Target{
        .{ .prefix = src_prefix, .suffix = "" },
    };
    const ts_paths = [_]@import("../config.zig").TsConfig.PathEntry{
        .{
            .key_prefix = "~/",
            .key_suffix = "",
            .has_wildcard = true,
            .targets = &ts_path_targets,
        },
    };

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .dev_mode = true,
        .collect_module_codes = true,
        .ts_paths = &ts_paths,
    });
    defer ib.deinit();

    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| {
                std.testing.allocator.free(e);
                return error.TestUnexpectedResult;
            },
            .fatal => return error.TestUnexpectedResult,
        }
    }

    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    try writeFile(tmp.dir, "src/App.tsx",
        \\import { defaultOptions as appDefaults } from '~/core/settings';
        \\import { LoadingRing } from '~/widgets/loading';
        \\export default function App() {
        \\  return [appDefaults.mode, LoadingRing, 2];
        \\}
    );

    const result = try ib.rebuild(std.testing.io);
    switch (result) {
        .success => |r| {
            defer freeChanged(r.changed_modules);
            try std.testing.expect(r.changed_modules.len > 0);

            var saw_app = false;
            for (r.changed_modules) |m| {
                if (std.mem.indexOf(u8, m.id, "src/App.tsx") == null) continue;
                saw_app = true;
                try std.testing.expect(std.mem.indexOf(u8, m.code, "require(\"~/") == null);
                try std.testing.expect(std.mem.indexOf(u8, m.code, "require('~/") == null);
                try std.testing.expect(std.mem.indexOf(u8, m.code, "__zntc_modules[") != null);
            }
            try std.testing.expect(saw_app);
        },
        .build_error => return error.TestUnexpectedResult,
        .fatal => return error.TestUnexpectedResult,
    }
}

test "Bundler watch path: changed HMR module rewrites mixed alias imports" {
    // 테스트앱 재현: NAPI watch 경로는 첫 빌드부터 module_store/compiled_cache를
    // 유지하고, 리빌드 때 changed_files와 skip_bundle_output을 함께 사용한다.
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
    try writeFile(tmp.dir, "src/widgets/header/index.js",
        \\export { HeaderSlot } from './HeaderSlot';
    );
    try writeFile(tmp.dir, "src/widgets/header/HeaderSlot.js",
        \\export function HeaderSlot() {
        \\  return null;
        \\}
    );
    try writeFile(tmp.dir, "src/App.tsx",
        \\import { defaultOptions as appDefaults } from '~/core/settings';
        \\import { LoadingRing } from '~/widgets/loading';
        \\import { HeaderSlot } from '~/widgets/header';
        \\export default function App() {
        \\  return [appDefaults.mode, LoadingRing, HeaderSlot, 1];
        \\}
    );

    const entry = try absPath(&tmp, "src/App.tsx");
    defer std.testing.allocator.free(entry);
    const root = try absPath(&tmp, ".");
    defer std.testing.allocator.free(root);
    const src_prefix = try std.fmt.allocPrint(std.testing.allocator, "{s}/src/", .{root});
    defer std.testing.allocator.free(src_prefix);

    const ts_path_targets = [_]@import("../config.zig").TsConfig.PathEntry.Target{
        .{ .prefix = src_prefix, .suffix = "" },
    };
    const ts_paths = [_]@import("../config.zig").TsConfig.PathEntry{
        .{
            .key_prefix = "~/",
            .key_suffix = "",
            .has_wildcard = true,
            .targets = &ts_path_targets,
        },
    };

    var store = module_store.PersistentModuleStore.init(std.testing.allocator);
    defer store.deinit();
    var compiled_cache = CompiledOutputCache.init(std.testing.allocator);
    defer compiled_cache.deinit();

    const initial_opts = @as(@import("bundler.zig").BundleOptions, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .dev_mode = true,
        .collect_module_codes = true,
        .module_store = &store,
        .compiled_cache = &compiled_cache,
        .ts_paths = &ts_paths,
        .sourcemap = .{ .enable = true, .lazy = true },
    });
    var resolve_cache = Bundler.initResolveCacheFromOptions(std.testing.allocator, initial_opts);
    defer resolve_cache.deinit();

    var initial = Bundler.init(std.testing.allocator, initial_opts);
    var initial_result = try initial.bundle(std.testing.io);
    defer initial_result.deinit(std.testing.allocator);
    defer initial.deinit();
    try std.testing.expect(!initial_result.hasErrors());

    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    try writeFile(tmp.dir, "src/App.tsx",
        \\import { defaultOptions as appDefaults } from '~/core/settings';
        \\import { LoadingRing } from '~/widgets/loading';
        \\import { HeaderSlot } from '~/widgets/header';
        \\export default function App() {
        \\  return [appDefaults.mode, LoadingRing, HeaderSlot, 2];
        \\}
    );

    var touched = std.StringHashMap(void).init(std.testing.allocator);
    defer touched.deinit();
    try touched.put(entry, {});

    var rebuild_opts = initial_opts;
    rebuild_opts.changed_files = &touched;
    rebuild_opts.skip_bundle_output = true;

    var rebuild = Bundler.initWithResolveCache(std.testing.allocator, rebuild_opts, &resolve_cache);
    var rebuild_result = try rebuild.bundle(std.testing.io);
    defer rebuild_result.deinit(std.testing.allocator);
    defer rebuild.deinit();
    try std.testing.expect(!rebuild_result.hasErrors());

    const codes = rebuild_result.module_dev_codes orelse return error.TestUnexpectedResult;
    var saw_app = false;
    for (codes) |m| {
        if (std.mem.indexOf(u8, m.id, "src/App.tsx") == null) continue;
        saw_app = true;
        try std.testing.expect(std.mem.indexOf(u8, m.code, "require(\"~/") == null);
        try std.testing.expect(std.mem.indexOf(u8, m.code, "require('~/") == null);
        try std.testing.expect(std.mem.indexOf(u8, m.code, "__zntc_modules[") != null);
    }
    try std.testing.expect(saw_app);
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
        const r = try ib.rebuild(std.testing.io);
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
    const result = try ib.rebuild(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // import 제거 → extra.ts가 그래프에서 빠짐
    try writeFile(tmp.dir, "index.ts", "console.log('no import');");

    // 증분 빌드: 모듈 수 변경 → graph_changed
    const result = try ib.rebuild(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
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
    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};

    // 2) 첫 번째 파일 변경 → 증분 빌드 (graph_changed=false 예상)
    try writeFile(tmp.dir, "App.ts", "import { helper } from './util';\nexport const msg = helper() + ' v2';");
    var second_path_count: usize = 0;
    {
        const r = try ib.rebuild(std.testing.io);
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
    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};

    // 3) 두 번째 파일 변경 → 증분 빌드 (graph_changed=false 이어야 함!)
    //    이슈 #951: 이 시점에서 graph_changed=true가 되어 full-reload가 발생함
    try writeFile(tmp.dir, "App.ts", "import { helper } from './util';\nexport const msg = helper() + ' v3';");
    {
        const r = try ib.rebuild(std.testing.io);
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
    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    try writeFile(tmp.dir, "util.ts", "export const helper = () => 'v4';");
    {
        const r = try ib.rebuild(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            .build_error => |e| std.testing.allocator.free(e),
            .fatal => {},
        }
    }

    // 구문 에러 삽입
    try writeFile(tmp.dir, "index.ts", "console.log(;);");

    // 재빌드 → 에러 또는 성공 (파서가 에러 복구할 수 있음)
    const result = try ib.rebuild(std.testing.io);
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

test "IncrementalBundler: cache-hit 충돌 모듈의 rename 이 fresh 빌드와 byte-identical (RFC #3940 L.5c)" {
    // RFC #3940 L.5c 로 Symbol.canonical_name field 가 제거되어 rename 은 build-scope
    // Linker.rename_table 에만 산다. 삭제된 canonical_name UAF 테스트의 대체 — 충돌 rename 된
    // 모듈이 다음 build 에서 cache-hit(semantic 재사용) 될 때, 새 build 의 rename_table 이
    // 정확히 재계산돼 from-scratch 빌드와 동일한 번들을 stale/garbage 없이 내는지 검증한다.
    // (구 버그: 이전 build 의 freed canonical_strings 포인터가 store 모듈에 dangling →
    // cache-hit 시 garbage emit.)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 같은 이름 'count' 가 두 모듈에서 export → 충돌 → 한쪽이 count$1 로 rename.
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

    // store 를 mtime 까지 워밍 (B3: 첫 build 부터 cache put).
    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();
    for (0..2) |_| {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }

    // index.ts 만 수정 → 충돌 모듈 a.ts/b.ts 는 cache-hit. (mtime 변별 위해 sleep.)
    std.testing.io.sleep(std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    try writeFile(tmp.dir, "index.ts",
        \\import { count as A } from './a';
        \\import { count as B } from './b';
        \\console.log(A, B, 1);
        \\
    );

    // (1) store 공유 빌드: index.ts reparse, a.ts/b.ts cache-hit.
    var cached = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .module_store = &ib.persistent_store,
    });
    defer cached.deinit();
    var cached_result = try cached.bundle(std.testing.io);
    defer cached_result.deinit(std.testing.allocator);

    // cache-hit 확인: index.ts 만 reparse, 충돌 모듈 a.ts/b.ts 는 미-reparse.
    try std.testing.expect(cached_result.reparsed_paths != null);
    var saw_index = false;
    for (cached_result.reparsed_paths.?) |p| {
        if (std.mem.endsWith(u8, p, "a.ts")) return error.ConflictModuleReparsed;
        if (std.mem.endsWith(u8, p, "b.ts")) return error.ConflictModuleReparsed;
        if (std.mem.endsWith(u8, p, "index.ts")) saw_index = true;
    }
    try std.testing.expect(saw_index);

    // (2) from-scratch 빌드 (store 없음, 수정된 index.ts 읽음).
    var fresh = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer fresh.deinit();
    var fresh_result = try fresh.bundle(std.testing.io);
    defer fresh_result.deinit(std.testing.allocator);

    // 충돌 rename 이 실제로 발생(non-vacuous) + 출력이 valid UTF-8 (stale/garbage 0).
    try std.testing.expect(std.mem.indexOf(u8, fresh_result.output, "count$1") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cached_result.output));

    // 핵심: cache-hit 출력이 from-scratch 출력과 byte-identical — cache-hit 충돌 모듈의
    // rename 이 새 build 의 rename_table 로 정확히 재계산됨(stale pointer 없음).
    try std.testing.expectEqualStrings(fresh_result.output, cached_result.output);
}

// ============================================================
// RFC #1672 Phase B3 — first-build cache reuse
// ============================================================

test "IncrementalBundler: compiled_cache populates on FIRST build (B3)" {
    // B3: parseModule 이 Module.mtime 을 주입하게 되어 첫 build 부터 cache put.
    // 이전 (B2 단독): 첫 build 는 mtime=0 이라 cache 비활성.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "util.ts", "export const x = 1;");
    try writeFile(tmp.dir, "index.ts", "import { x } from './util';\nconsole.log(x);");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드 — 이제 mtime 이 주입되어 cache put 이 작동해야 함.
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    // 2개 모듈 (util + index) 모두 cache 에 저장됐어야.
    try std.testing.expect(ib.compiled_cache.entries.count() >= 2);
}

test "IncrementalBundler: first rebuild hits cache from first build (B3)" {
    // B3 효과 검증: util.ts 는 변경 안 함 → index.ts 수정 후 첫 rebuild 에서 cache hit.
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

    // 첫 빌드 (cache populate).
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    _ = ib.compiled_cache.takeStats(); // 카운터 리셋 — 첫 빌드의 miss 는 제외하고 rebuild 만 관측.

    // index.ts 만 수정, util.ts 는 그대로.
    try writeFile(tmp.dir, "index.ts", "import { x } from './util';\nconsole.log(x + 1);");

    const r = try ib.rebuild(std.testing.io);
    switch (r) {
        .success => |s| freeChanged(s.changed_modules),
        else => return error.TestUnexpectedResult,
    }
    // util.ts 가 변경 안 됐으므로 cache hit 되어야 함.
    try std.testing.expect(ib.compiled_cache.hits >= 1);
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
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }

    // build 2 (incremental store seed): 파일은 변경 없지만 store 가 채워지는 시점.
    // IncrementalBundler 는 첫 빌드에서는 store 미전달, 두 번째부터 전달.
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }

    // build 3: util.ts 만 수정 → cache-miss. index.ts cache-hit.
    try writeFile(tmp.dir, "util.ts", "export const x = 999;");

    // BundleResult 를 직접 생성해 reparsed_paths 검사. IncrementalBundler 는
    // 내부적으로 Bundler.bundle(std.testing.io) 을 호출하지만 결과를 노출하지 않으므로,
    // 같은 store 를 공유한 별도 Bundler 로 검증.
    var bundler = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
        .module_store = &ib.persistent_store,
    });
    defer bundler.deinit();

    var result = try bundler.bundle(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }

    // 두 번째 빌드 — rebuild 경로에서 mtime 주입 → cache miss + put.
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(ib.compiled_cache.entries.count() >= 1);

    // 세 번째 빌드 — 동일 mtime/옵션 → cache hit 경로. 엔트리 개수 유지.
    const count_after_2 = ib.compiled_cache.entries.count();
    {
        const r = try ib.rebuild(std.testing.io);
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
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    const entries_before = ib.compiled_cache.entries.count();
    try std.testing.expect(entries_before >= 1);

    // util.ts 수정 → mtime 변경 → cache miss → 새 emit + put (기존 엔트리 교체).
    try writeFile(tmp.dir, "util.ts", "export const x = 42;");

    const result = try ib.rebuild(std.testing.io);
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

// ============================================================
// #3751 — watch mode arena monotonic growth 방지
// ============================================================

test "IncrementalBundler: ResolveCache resets after rebuild_reset_interval rebuilds (#3751)" {
    // 옵션 A: N rebuild 마다 resolve_cache deinit + 재생성.
    // path_pool arena 가 monotonic 으로 자라는 것을 막아 watch mode RSS bound.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 테스트 가속 — 기본 100 대신 3 rebuild 마다 reset.
    ib.rebuild_reset_interval = 3;

    // 첫 빌드 (resolve_cache 생성).
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    // path_pool 의 *내용* fingerprint — entry path 를 intern 해 ptr 보관.
    // ib.resolve_cache.? 자체 주소는 optional 의 in-place storage 라 reset 후에도
    // 같은 주소를 갖는다 (review Angle A/D finding). 따라서 cache content 의 stable
    // 식별자 — intern 한 slice 가 가리키는 arena 안 주소 — 로 reset 여부를 검증.
    const interned_before = try ib.resolve_cache.?.path_pool.intern("/__test_fingerprint_3751");

    // 2-3 번째 rebuild: 같은 cache 재사용 → 같은 path intern 은 같은 slice 반환.
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
        const interned_again = try ib.resolve_cache.?.path_pool.intern("/__test_fingerprint_3751");
        try std.testing.expectEqual(interned_before.ptr, interned_again.ptr);
    }

    // 4번째 rebuild = interval 도달 → reset 이 일어나야 함. resolve_cache 재생성으로
    // 내부 path_pool / cache_shards / dir_cache 모두 fresh. 다음 build 가 cold 지만
    // arena 무한 증가 차단.
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    // rebuild_count 가 reset 후 1 로 복귀했어야 함.
    try std.testing.expect(ib.rebuild_count < ib.rebuild_reset_interval);
    // 새 arena 에서 같은 path 를 intern → 이전 slice 와 *다른* ptr 이어야 함 (reset 입증).
    const interned_after_reset = try ib.resolve_cache.?.path_pool.intern("/__test_fingerprint_3751");
    try std.testing.expect(interned_before.ptr != interned_after_reset.ptr);
}

test "IncrementalBundler: reset() Control API 도 resolve_cache 같이 비움 (#3751)" {
    // Angle B + E finding: 사용자 수동 reset 이 path_pool 을 안 건드리면 RSS 회복 안 됨.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    defer ib.deinit();

    // 첫 빌드.
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(ib.resolve_cache != null);
    try std.testing.expect(ib.rebuild_count > 0);

    // 수동 reset — resolve_cache 와 rebuild_count 모두 정리되어야 함.
    ib.reset();
    try std.testing.expect(ib.resolve_cache == null);
    try std.testing.expectEqual(@as(usize, 0), ib.rebuild_count);
}

// ============================================================
// Sub-PR-B.2: enable_persistence opt-in path 정확성 가드
// RFC #3933 — default off (영향 0), opt-in 시 persistent_graph 보존 + 매 빌드
// reset/invalidate 호출로 정확성 유지. Sub-PR-B.3 가 selective invalidate.
// ============================================================

test "IncrementalBundler enable_persistence: 첫 빌드 + rebuild 정확성, persistent_graph 보존" {
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
    ib.enable_persistence = true;
    defer ib.deinit();

    // 첫 빌드 — persistent_graph init
    try std.testing.expect(ib.persistent_graph == null);
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    try std.testing.expect(ib.persistent_graph != null);
    const mod_count_after_first = ib.persistent_graph.?.modules.count();
    try std.testing.expect(mod_count_after_first >= 2);

    // 두 번째 rebuild — graph 가 보존되지만 reset/invalidate 로 fresh state.
    // index.ts 수정 → 정확한 build 결과 검증.
    try writeFile(tmp.dir, "index.ts", "import { x } from './util';\nconsole.log(x + 1);");
    {
        const r = try ib.rebuild(std.testing.io);
        switch (r) {
            .success => |s| freeChanged(s.changed_modules),
            else => return error.TestUnexpectedResult,
        }
    }
    // persistent_graph 는 같은 instance — modules slot 보존 (count 동일)
    try std.testing.expect(ib.persistent_graph != null);
    try std.testing.expectEqual(mod_count_after_first, ib.persistent_graph.?.modules.count());
}

test "IncrementalBundler enable_persistence=false: default off, persistent_graph null 유지" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var ib = IncrementalBundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .dev_mode = true,
    });
    // enable_persistence default false
    defer ib.deinit();

    try std.testing.expectEqual(false, ib.enable_persistence);

    const r = try ib.rebuild(std.testing.io);
    switch (r) {
        .success => |s| freeChanged(s.changed_modules),
        else => return error.TestUnexpectedResult,
    }
    // default off 면 persistent_graph 미사용
    try std.testing.expect(ib.persistent_graph == null);
}
