const std = @import("std");
const resolver_mod = @import("resolver.zig");
const Resolver = resolver_mod.Resolver;
const ModuleType = @import("types.zig").ModuleType;
const isRelativeOrAbsolute = resolver_mod.isRelativeOrAbsolute;
const splitBareSpecifier = resolver_mod.splitBareSpecifier;

// ============================================================
// Tests
// ============================================================

test "isRelativeOrAbsolute" {
    try std.testing.expect(isRelativeOrAbsolute("./foo"));
    try std.testing.expect(isRelativeOrAbsolute("../foo"));
    try std.testing.expect(isRelativeOrAbsolute("/abs/path"));
    try std.testing.expect(!isRelativeOrAbsolute("react"));
    try std.testing.expect(!isRelativeOrAbsolute("@mui/material"));
    try std.testing.expect(!isRelativeOrAbsolute(""));
}

/// 테스트용 헬퍼: tmpDir에 파일 생성 (부모 디렉토리 자동 생성)
fn createFile(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    const file = try dir.createFile(path, .{});
    file.close();
}

/// 테스트용 헬퍼: 경로 끝 부분 비교 (구분자 독립 — Windows `\` + Unix `/` 모두 처리).
fn pathEndsWith(path: []const u8, expected_suffix: []const u8) bool {
    if (path.len < expected_suffix.len) return false;
    const tail = path[path.len - expected_suffix.len ..];
    for (tail, expected_suffix) |a, b| {
        const na = if (a == '\\') @as(u8, '/') else a;
        const nb = if (b == '\\') @as(u8, '/') else b;
        if (na != nb) return false;
    }
    return true;
}

const writeFile = @import("test_helpers.zig").writeFile;

test "resolve: exact file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "foo.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./foo.ts");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "foo.ts"));
    try std.testing.expectEqual(ModuleType.javascript, result.module_type);
}

test "resolve: extension search (.ts)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "bar.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./bar");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "bar.ts"));
}

test "resolve: extension search (.tsx before .js)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "comp.tsx");
    try createFile(tmp.dir, "comp.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./comp");
    defer std.testing.allocator.free(result.path);

    // .ts → .tsx → .js 순서이므로 .tsx가 먼저
    try std.testing.expect(pathEndsWith(result.path, "comp.tsx"));
}

test "resolve: TS extension mapping (.js → .ts)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "util.ts");
    // util.js는 없음. import './util.js' → ./util.ts로 해석

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./util.js");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "util.ts"));
}

test "resolve: TS extension mapping (.jsx → .tsx)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "App.tsx");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./App.jsx");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "App.tsx"));
}

test "resolve: directory index (./dir → ./dir/index.ts)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "components/index.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./components");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "components/index.ts"));
}

test "resolve: directory index (.tsx)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "pages/index.tsx");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./pages");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "pages/index.tsx"));
}

test "resolve: parent directory (../)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "shared.ts");
    try createFile(tmp.dir, "sub/entry.ts");

    const sub_path = try tmp.dir.realpathAlloc(std.testing.allocator, "sub");
    defer std.testing.allocator.free(sub_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(sub_path, "../shared");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "shared.ts"));
}

test "resolve: module not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = resolver.resolve(dir_path, "./nonexistent");
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "resolve: bare specifier with main field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/my-lib/package.json", "{\"main\":\"./lib/index.js\"}");
    try createFile(tmp.dir, "node_modules/my-lib/lib/index.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "my-lib");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "my-lib/lib/index.js"));
}

test "resolve: bare specifier with module field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/esm-pkg/package.json", "{\"module\":\"./esm/index.js\",\"main\":\"./cjs/index.js\"}");
    try createFile(tmp.dir, "node_modules/esm-pkg/esm/index.js");
    try createFile(tmp.dir, "node_modules/esm-pkg/cjs/index.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "esm-pkg");
    defer std.testing.allocator.free(result.path);

    // module 필드가 main보다 우선
    try std.testing.expect(pathEndsWith(result.path, "esm-pkg/esm/index.js"));
}

test "resolve: bare specifier with exports field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/exp-pkg/package.json", "{\"exports\":{\"import\":\"./esm.js\",\"require\":\"./cjs.js\"}}");
    try createFile(tmp.dir, "node_modules/exp-pkg/esm.js");
    try createFile(tmp.dir, "node_modules/exp-pkg/cjs.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "exp-pkg");
    defer std.testing.allocator.free(result.path);

    // 기본 conditions에 "import"가 포함되어 esm.js 선택
    try std.testing.expect(pathEndsWith(result.path, "exp-pkg/esm.js"));
}

test "resolve: bare specifier with index fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/simple/package.json", "{\"name\":\"simple\"}");
    try createFile(tmp.dir, "node_modules/simple/index.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "simple");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "simple/index.js"));
}

test "resolve: bare specifier walk up directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // node_modules는 루트에, 소스 파일은 src/deep/ 에
    try writeFile(tmp.dir, "node_modules/top-pkg/package.json", "{\"main\":\"./index.js\"}");
    try createFile(tmp.dir, "node_modules/top-pkg/index.js");
    try createFile(tmp.dir, "src/deep/entry.ts");

    const deep_path = try tmp.dir.realpathAlloc(std.testing.allocator, "src/deep");
    defer std.testing.allocator.free(deep_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(deep_path, "top-pkg");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "top-pkg/index.js"));
}

test "resolve: bare specifier not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = resolver.resolve(dir_path, "nonexistent-pkg");
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "splitBareSpecifier" {
    const s1 = splitBareSpecifier("react");
    try std.testing.expectEqualStrings("react", s1.pkg_name);
    try std.testing.expectEqualStrings(".", s1.subpath);

    const s2 = splitBareSpecifier("react/jsx-runtime");
    try std.testing.expectEqualStrings("react", s2.pkg_name);
    try std.testing.expectEqualStrings("/jsx-runtime", s2.subpath);

    const s3 = splitBareSpecifier("@mui/material");
    try std.testing.expectEqualStrings("@mui/material", s3.pkg_name);
    try std.testing.expectEqualStrings(".", s3.subpath);

    const s4 = splitBareSpecifier("@mui/material/Button");
    try std.testing.expectEqualStrings("@mui/material", s4.pkg_name);
    try std.testing.expectEqualStrings("/Button", s4.subpath);
}

test "resolve: json module type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "data.json");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./data.json");
    defer std.testing.allocator.free(result.path);

    try std.testing.expectEqual(ModuleType.json, result.module_type);
}

test "resolve: css module type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "style.css");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./style.css");
    defer std.testing.allocator.free(result.path);

    try std.testing.expectEqual(ModuleType.css, result.module_type);
}

test "resolve: extension search priority (.ts > .tsx > .js)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "mod.ts");
    try createFile(tmp.dir, "mod.tsx");
    try createFile(tmp.dir, "mod.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./mod");
    defer std.testing.allocator.free(result.path);

    // .ts가 가장 먼저
    try std.testing.expect(pathEndsWith(result.path, "mod.ts"));
}

test "resolve: exact .js file exists (no TS mapping)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "lib.js");
    try createFile(tmp.dir, "lib.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./lib.js");
    defer std.testing.allocator.free(result.path);

    // 정확한 .js가 있으면 TS 매핑하지 않음
    try std.testing.expect(pathEndsWith(result.path, "lib.js"));
}

test "resolve: subpath imports (#specifier)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json",
        \\{"name":"my-app","imports":{"#utils":"./src/utils.js"}}
    );
    try createFile(tmp.dir, "src/utils.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "#utils");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "src/utils.js"));
}

test "resolve: subpath imports with conditions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json",
        \\{"name":"my-app","imports":{"#dep":{"node":"./src/node.js","default":"./src/browser.js"}}}
    );
    try createFile(tmp.dir, "src/node.js");
    try createFile(tmp.dir, "src/browser.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    // 기본 conditions에 "browser"가 있으므로 browser.js 우선 (import > module > browser)
    var resolver = Resolver.init(std.testing.allocator);
    resolver.conditions = &.{ "node", "import", "default" };
    const result = try resolver.resolve(dir_path, "#dep");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "src/node.js"));
}

test "resolve: subpath imports not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "package.json",
        \\{"name":"my-app","imports":{"#foo":"./foo.js"}}
    );

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = resolver.resolve(dir_path, "#bar");
    try std.testing.expectError(error.ModuleNotFound, result);
}
