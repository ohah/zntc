const std = @import("std");
const pkg_json = @import("package_json.zig");
const parsePackageJson = pkg_json.parsePackageJson;
const resolveExports = pkg_json.resolveExports;
const resolveImports = pkg_json.resolveImports;
const isSubpathMap = pkg_json.isSubpathMap;

// ============================================================
// Tests
// ============================================================

// path-based parsePackageJson 호출용 helper — tmp dir 의 절대경로 반환.
// caller 는 buf 를 자체 stack 에 보유.
fn tmpDirPath(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return try tmp.dir.realpath(".", buf);
}

test "parsePackageJson: basic fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"test-pkg","main":"./lib/index.js","module":"./esm/index.js","type":"module"}
        ,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &buf);
    var result = try parsePackageJson(std.testing.allocator, dir_path);
    defer result.deinit();

    try std.testing.expectEqualStrings("test-pkg", result.pkg.name.?);
    try std.testing.expectEqualStrings("./lib/index.js", result.pkg.main.?);
    try std.testing.expectEqualStrings("./esm/index.js", result.pkg.module.?);
    try std.testing.expect(result.pkg.isModule());
}

test "parsePackageJson: sideEffects false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"pure-pkg","sideEffects":false}
        ,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &buf);
    var result = try parsePackageJson(std.testing.allocator, dir_path);
    defer result.deinit();

    switch (result.pkg.side_effects) {
        .all => |b| try std.testing.expect(!b),
        else => return error.TestUnexpectedResult,
    }
}

test "parsePackageJson: sideEffects array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"css-pkg","sideEffects":["*.css","./src/polyfill.js"]}
        ,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &buf);
    var result = try parsePackageJson(std.testing.allocator, dir_path);
    defer result.deinit();

    switch (result.pkg.side_effects) {
        .patterns => |patterns| {
            try std.testing.expectEqual(@as(usize, 2), patterns.len);
            try std.testing.expectEqualStrings("*.css", patterns[0]);
            try std.testing.expectEqualStrings("./src/polyfill.js", patterns[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parsePackageJson: sideEffects empty array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"empty-pkg","sideEffects":[]}
        ,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &buf);
    var result = try parsePackageJson(std.testing.allocator, dir_path);
    defer result.deinit();

    // 빈 배열은 sideEffects: false와 동일
    switch (result.pkg.side_effects) {
        .all => |b| try std.testing.expect(!b),
        else => return error.TestUnexpectedResult,
    }
}

test "parsePackageJson: missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &buf);
    const result = parsePackageJson(std.testing.allocator, dir_path);
    try std.testing.expectError(error.FileNotFound, result);
}

// path-based 시그니처의 회귀 방지 — std.fs.Dir 핸들 우회 후 새로 노출되는 경로:

test "parsePackageJson: symlink-to-directory 안의 package.json (bun/.bun 패턴)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 실제 패키지 디렉토리
    try tmp.dir.makeDir("real_pkg");
    var real_dir = try tmp.dir.openDir("real_pkg", .{});
    defer real_dir.close();
    try real_dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"linked-pkg","main":"./index.js"}
        ,
    });

    // bun/.bun 같은 symlink-to-directory
    tmp.dir.symLink("real_pkg", "linked_pkg", .{ .is_directory = true }) catch |err| switch (err) {
        // Windows / 권한 부족 환경 skip
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &buf);

    // symlink 경로로 parsePackageJson 호출 — std.fs.path.join 후 readFile 가
    // symlink 를 따라가 target 의 package.json 읽음
    var join_buf: [std.fs.max_path_bytes]u8 = undefined;
    const linked_path = try std.fmt.bufPrint(&join_buf, "{s}/linked_pkg", .{tmp_path});

    var result = try parsePackageJson(std.testing.allocator, linked_path);
    defer result.deinit();

    try std.testing.expectEqualStrings("linked-pkg", result.pkg.name.?);
}

test "parsePackageJson: OutOfMemory 는 별도로 throw (silent swallow 방지)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"oom-test"}
        ,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &buf);

    // failingAllocator 0 byte 허용 — std.fs.path.join 의 첫 alloc 부터 실패
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const result = parsePackageJson(failing.allocator(), dir_path);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "resolveExports: string shorthand" {
    const source =
        \\{"exports":"./index.js"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;
    const result = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./index.js", result.?.path);
}

test "resolveExports: condition object" {
    const source =
        \\{"exports":{"import":"./esm.js","require":"./cjs.js","default":"./index.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    // import 조건 매칭
    const esm = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./esm.js", esm.?.path);

    const cjs = resolveExports(std.testing.allocator, exports, ".", &.{"require"});
    try std.testing.expectEqualStrings("./cjs.js", cjs.?.path);

    const fallback = resolveExports(std.testing.allocator, exports, ".", &.{"browser"});
    try std.testing.expectEqualStrings("./index.js", fallback.?.path);
}

test "resolveExports: subpath map" {
    const source =
        \\{"exports":{".":"./index.js","./utils":"./src/utils.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const root = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./index.js", root.?.path);

    const utils = resolveExports(std.testing.allocator, exports, "./utils", &.{"import"});
    try std.testing.expectEqualStrings("./src/utils.js", utils.?.path);

    const missing = resolveExports(std.testing.allocator, exports, "./nonexistent", &.{"import"});
    try std.testing.expect(missing == null);
}

test "resolveExports: nested conditions in subpath" {
    const source =
        \\{"exports":{".":{"import":"./esm.js","require":"./cjs.js"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const esm = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./esm.js", esm.?.path);

    const cjs = resolveExports(std.testing.allocator, exports, ".", &.{"require"});
    try std.testing.expectEqualStrings("./cjs.js", cjs.?.path);
}

test "resolveExports: wildcard pattern" {
    const source =
        \\{"exports":{".":"./index.js","./*":"./src/*.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const result = resolveExports(std.testing.allocator, exports, "./utils", &.{"import"});
    try std.testing.expect(result != null);
    defer if (result.?.allocated) std.testing.allocator.free(result.?.path);
    // 와일드카드 치환: ./* → ./utils, ./src/*.js → ./src/utils.js
    try std.testing.expectEqualStrings("./src/utils.js", result.?.path);
}

test "resolveExports: no match returns null" {
    const source =
        \\{"exports":{"./internal":"./src/internal.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;
    const result = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expect(result == null);
}

test "isSubpathMap" {
    const source1 =
        \\{".":"./index.js","./utils":"./utils.js"}
    ;
    const parsed1 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source1, .{});
    defer parsed1.deinit();
    try std.testing.expect(isSubpathMap(parsed1.value.object));

    const source2 =
        \\{"import":"./esm.js","require":"./cjs.js"}
    ;
    const parsed2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source2, .{});
    defer parsed2.deinit();
    try std.testing.expect(!isSubpathMap(parsed2.value.object));
}

test "resolveImports: exact match" {
    const source =
        \\{"#ansi-styles":"./source/vendor/ansi-styles/index.js"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const result = resolveImports(std.testing.allocator, parsed.value, "#ansi-styles", &.{ "import", "default" });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("./source/vendor/ansi-styles/index.js", result.?.path);
    try std.testing.expect(!result.?.allocated);
}

test "resolveImports: condition object" {
    const source =
        \\{"#supports-color":{"node":"./source/vendor/supports-color/index.js","default":"./source/vendor/supports-color/browser.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    // node 조건 매칭
    const node_result = resolveImports(std.testing.allocator, parsed.value, "#supports-color", &.{ "node", "default" });
    try std.testing.expect(node_result != null);
    try std.testing.expectEqualStrings("./source/vendor/supports-color/index.js", node_result.?.path);

    // default 폴백
    const browser_result = resolveImports(std.testing.allocator, parsed.value, "#supports-color", &.{ "import", "browser" });
    try std.testing.expect(browser_result != null);
    try std.testing.expectEqualStrings("./source/vendor/supports-color/browser.js", browser_result.?.path);
}

test "resolveImports: wildcard pattern" {
    const source =
        \\{"#utils/*":"./src/utils/*.js"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const result = resolveImports(std.testing.allocator, parsed.value, "#utils/string", &.{"default"});
    try std.testing.expect(result != null);
    defer if (result.?.allocated) std.testing.allocator.free(result.?.path);
    try std.testing.expectEqualStrings("./src/utils/string.js", result.?.path);
    try std.testing.expect(result.?.allocated);
}

test "resolveImports: no match returns null" {
    const source =
        \\{"#foo":"./foo.js"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const result = resolveImports(std.testing.allocator, parsed.value, "#bar", &.{"default"});
    try std.testing.expect(result == null);
}

test "parsePackageJson: imports field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"chalk","imports":{"#ansi-styles":"./source/vendor/ansi-styles/index.js"}}
        ,
    });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmpDirPath(&tmp, &buf);
    var result = try parsePackageJson(std.testing.allocator, dir_path);
    defer result.deinit();

    try std.testing.expect(result.pkg.imports != null);
}
