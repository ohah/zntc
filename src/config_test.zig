const std = @import("std");
const config_mod = @import("config.zig");
const TsConfig = config_mod.TsConfig;
const stripJsonComments = config_mod.stripJsonComments;

test "stripJsonComments - single line comments" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  // This is a comment
        \\  "key": "value"
        \\}
    ;
    const result = try stripJsonComments(allocator, input);
    defer allocator.free(result);

    // 주석이 공백으로 대체되었는지 확인
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value", parsed.value.object.get("key").?.string);
}

test "stripJsonComments - multi line comments" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  /* multi
        \\     line
        \\     comment */
        \\  "key": "value"
        \\}
    ;
    const result = try stripJsonComments(allocator, input);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value", parsed.value.object.get("key").?.string);
}

test "stripJsonComments - comments inside strings are preserved" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "key": "// not a comment",
        \\  "key2": "/* also not */"
        \\}
    ;
    const result = try stripJsonComments(allocator, input);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("// not a comment", parsed.value.object.get("key").?.string);
    try std.testing.expectEqualStrings("/* also not */", parsed.value.object.get("key2").?.string);
}

test "stripJsonComments - trailing comma" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "a": 1,
        \\  "b": 2,
        \\}
    ;
    const result = try stripJsonComments(allocator, input);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("a").?.integer == 1);
    try std.testing.expect(parsed.value.object.get("b").?.integer == 2);
}

test "TsConfig.load - missing file returns defaults" {
    const allocator = std.testing.allocator;
    // 존재하지 않는 디렉토리를 지정하면 기본값이 반환된다
    var config = try TsConfig.load(allocator, "/tmp/zts_test_nonexistent_dir_12345");
    defer config.deinit();

    try std.testing.expect(config.target == null);
    try std.testing.expect(config.module == null);
    try std.testing.expect(config.jsx == null);
    try std.testing.expectEqualStrings("React.createElement", config.jsx_factory);
    try std.testing.expectEqualStrings("React.Fragment", config.jsx_fragment_factory);
    try std.testing.expect(config.out_dir == null);
    try std.testing.expect(config.root_dir == null);
    try std.testing.expect(config.source_map == false);
    try std.testing.expect(config.declaration == false);
    try std.testing.expect(config.strict == false);
    try std.testing.expect(config.experimental_decorators == false);
    try std.testing.expect(config.emit_decorator_metadata == false);
    try std.testing.expect(config.verbatim_module_syntax == false);
}

test "TsConfig.load - parse compilerOptions" {
    const allocator = std.testing.allocator;

    // 임시 디렉토리에 테스트용 tsconfig.json 생성
    const tmp_dir = "/tmp/zts_test_config_parse";
    std.fs.cwd().makePath(tmp_dir) catch {}; // 이미 존재하면 무시
    defer std.fs.cwd().deleteTree(tmp_dir) catch {}; // cleanup 실패 무시

    const tsconfig_content =
        \\{
        \\  "compilerOptions": {
        \\    "target": "es2020",
        \\    "module": "esnext",
        \\    "jsx": "react-jsx",
        \\    "jsxFactory": "h",
        \\    "jsxFragmentFactory": "Fragment",
        \\    "outDir": "./dist",
        \\    "rootDir": "./src",
        \\    "sourceMap": true,
        \\    "declaration": true,
        \\    "strict": true,
        \\    "experimentalDecorators": true,
        \\    "emitDecoratorMetadata": true,
        \\    "verbatimModuleSyntax": true
        \\  }
        \\}
    ;

    const tsconfig_path = try std.fs.path.join(allocator, &.{ tmp_dir, "tsconfig.json" });
    defer allocator.free(tsconfig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tsconfig_path, .data = tsconfig_content });

    var config = try TsConfig.load(allocator, tmp_dir);
    defer config.deinit();

    try std.testing.expectEqualStrings("es2020", config.target.?);
    try std.testing.expectEqualStrings("esnext", config.module.?);
    try std.testing.expectEqualStrings("react-jsx", config.jsx.?);
    try std.testing.expectEqualStrings("h", config.jsx_factory);
    try std.testing.expectEqualStrings("Fragment", config.jsx_fragment_factory);
    try std.testing.expectEqualStrings("./dist", config.out_dir.?);
    try std.testing.expectEqualStrings("./src", config.root_dir.?);
    try std.testing.expect(config.source_map == true);
    try std.testing.expect(config.declaration == true);
    try std.testing.expect(config.strict == true);
    try std.testing.expect(config.experimental_decorators == true);
    try std.testing.expect(config.emit_decorator_metadata == true);
    try std.testing.expect(config.verbatim_module_syntax == true);
}

test "TsConfig.load - JSONC with comments" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/zts_test_config_jsonc";
    std.fs.cwd().makePath(tmp_dir) catch {}; // 이미 존재하면 무시
    defer std.fs.cwd().deleteTree(tmp_dir) catch {}; // cleanup 실패 무시

    const tsconfig_content =
        \\{
        \\  // TypeScript 설정
        \\  "compilerOptions": {
        \\    "target": "es2021", // ES2021
        \\    /* JSX 설정 */
        \\    "jsx": "preserve",
        \\    "strict": true,
        \\  }
        \\}
    ;

    const tsconfig_path = try std.fs.path.join(allocator, &.{ tmp_dir, "tsconfig.json" });
    defer allocator.free(tsconfig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tsconfig_path, .data = tsconfig_content });

    var config = try TsConfig.load(allocator, tmp_dir);
    defer config.deinit();

    try std.testing.expectEqualStrings("es2021", config.target.?);
    try std.testing.expectEqualStrings("preserve", config.jsx.?);
    try std.testing.expect(config.strict == true);
}

test "TsConfig.load - extends inheritance" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/zts_test_config_extends";
    std.fs.cwd().makePath(tmp_dir) catch {}; // 이미 존재하면 무시
    defer std.fs.cwd().deleteTree(tmp_dir) catch {}; // cleanup 실패 무시

    // base.json: 기본 설정
    const base_content =
        \\{
        \\  "compilerOptions": {
        \\    "target": "es2019",
        \\    "strict": true,
        \\    "sourceMap": true,
        \\    "jsx": "react"
        \\  }
        \\}
    ;
    const base_path = try std.fs.path.join(allocator, &.{ tmp_dir, "base.json" });
    defer allocator.free(base_path);
    try std.fs.cwd().writeFile(.{ .sub_path = base_path, .data = base_content });

    // tsconfig.json: base를 확장하고 일부 오버라이드
    const tsconfig_content =
        \\{
        \\  "extends": "./base.json",
        \\  "compilerOptions": {
        \\    "target": "es2022",
        \\    "outDir": "./build"
        \\  }
        \\}
    ;
    const tsconfig_path = try std.fs.path.join(allocator, &.{ tmp_dir, "tsconfig.json" });
    defer allocator.free(tsconfig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tsconfig_path, .data = tsconfig_content });

    var config = try TsConfig.load(allocator, tmp_dir);
    defer config.deinit();

    // target은 자식이 오버라이드 → "es2022"
    try std.testing.expectEqualStrings("es2022", config.target.?);
    // strict, sourceMap은 base에서 상속
    try std.testing.expect(config.strict == true);
    try std.testing.expect(config.source_map == true);
    // jsx는 base에서 상속
    try std.testing.expectEqualStrings("react", config.jsx.?);
    // outDir은 자식에서 설정
    try std.testing.expectEqualStrings("./build", config.out_dir.?);
}

test "TsConfig.load - partial compilerOptions" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/zts_test_config_partial";
    std.fs.cwd().makePath(tmp_dir) catch {}; // 이미 존재하면 무시
    defer std.fs.cwd().deleteTree(tmp_dir) catch {}; // cleanup 실패 무시

    // 일부 옵션만 있는 tsconfig
    const tsconfig_content =
        \\{
        \\  "compilerOptions": {
        \\    "target": "esnext"
        \\  }
        \\}
    ;
    const tsconfig_path = try std.fs.path.join(allocator, &.{ tmp_dir, "tsconfig.json" });
    defer allocator.free(tsconfig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tsconfig_path, .data = tsconfig_content });

    var config = try TsConfig.load(allocator, tmp_dir);
    defer config.deinit();

    try std.testing.expectEqualStrings("esnext", config.target.?);
    // 나머지는 기본값
    try std.testing.expect(config.module == null);
    try std.testing.expect(config.jsx == null);
    try std.testing.expectEqualStrings("React.createElement", config.jsx_factory);
    try std.testing.expect(config.source_map == false);
    try std.testing.expect(config.strict == false);
}
