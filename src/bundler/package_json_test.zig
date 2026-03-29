const std = @import("std");
const pkg_json = @import("package_json.zig");
const parsePackageJson = pkg_json.parsePackageJson;
const resolveExports = pkg_json.resolveExports;
const resolveImports = pkg_json.resolveImports;
const isSubpathMap = pkg_json.isSubpathMap;

// ============================================================
// Tests
// ============================================================

test "parsePackageJson: basic fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"test-pkg","main":"./lib/index.js","module":"./esm/index.js","type":"module"}
        ,
    });

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
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

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
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

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
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

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
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

    const result = parsePackageJson(std.testing.allocator, tmp.dir);
    try std.testing.expectError(error.FileNotFound, result);
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

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
    defer result.deinit();

    try std.testing.expect(result.pkg.imports != null);
}
