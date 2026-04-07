const std = @import("std");
const helpers = @import("helpers.zig");
const e2e = helpers.e2e;
const e2eCJS = helpers.e2eCJS;
const e2eJSX = helpers.e2eJSX;
const e2eFull = helpers.e2eFull;
const e2eWithOptions = helpers.e2eWithOptions;
const e2eSourceMap = helpers.e2eSourceMap;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;

// E2E Tests: CJS module format
// ============================================================

test "Codegen CJS: import named" {
    var r = try e2eCJS(std.testing.allocator, "import { foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {foo}=require(\"./bar\");", r.output);
}

test "Codegen CJS: import named with rename" {
    // ESM `as` → CJS `:` 변환: import { X as Y } → const {X:Y}=require(...)
    var r = try e2eCJS(std.testing.allocator, "import { Commands as ViewCommands } from './view';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {Commands:ViewCommands}=require(\"./view\");", r.output);
}

test "Codegen CJS: import named multiple with rename" {
    // 여러 named import 중 일부만 rename
    var r = try e2eCJS(std.testing.allocator, "import { foo, bar as baz, qux } from './mod';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {foo,bar:baz,qux}=require(\"./mod\");", r.output);
}

test "Codegen CJS: import named same name" {
    // imported == local (rename 없음) — `:` 출력하지 않음
    var r = try e2eCJS(std.testing.allocator, "import { foo as foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const {foo}=require(\"./bar\");", r.output);
}

test "Codegen CJS: import default" {
    var r = try e2eCJS(std.testing.allocator, "import bar from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const bar=require(\"./bar\").default;", r.output);
}

test "Codegen CJS: import namespace" {
    var r = try e2eCJS(std.testing.allocator, "import * as bar from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("const bar=require(\"./bar\");", r.output);
}

test "Codegen CJS: export all" {
    var r = try e2eCJS(std.testing.allocator, "export * from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("Object.assign(exports,require(\"./bar\"));", r.output);
}

test "Codegen CJS: re-export named" {
    var r = try e2eCJS(std.testing.allocator, "export { foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("exports.foo=require(\"./bar\").foo;", r.output);
}

test "Codegen CJS: re-export default" {
    var r = try e2eCJS(std.testing.allocator, "export { default } from './foo';");
    defer r.deinit();
    try std.testing.expectEqualStrings("exports.default=require(\"./foo\").default;", r.output);
}

test "Codegen CJS: re-export default as named" {
    var r = try e2eCJS(std.testing.allocator, "export { default as Foo } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("exports.Foo=require(\"./bar\").default;", r.output);
}

test "Codegen CJS: re-export named as default" {
    var r = try e2eCJS(std.testing.allocator, "export { foo as default } from './bar';");
    defer r.deinit();
    try std.testing.expectEqualStrings("exports.default=require(\"./bar\").foo;", r.output);
}

test "Codegen CJS: export named function" {
    var r = try e2eCJS(std.testing.allocator, "export function foo() {}");
    defer r.deinit();
    try std.testing.expectEqualStrings("function foo(){}exports.foo=foo;", r.output);
}

test "Codegen CJS + ES5: export default class" {
    // export default class Foo { } → ES5 function + module.exports=Foo;
    var r = try e2eFull(std.testing.allocator, "export default class Foo { constructor() {} }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) }, .{ .minify_whitespace = true, .module_format = .cjs }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "module.exports=Foo;") != null);
    // module.exports=; (빈 값) 금지
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "module.exports=;"), null);
}

test "Codegen CJS + ES5: export default anonymous class" {
    var r = try e2eFull(std.testing.allocator, "export default class { constructor() {} }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) }, .{ .minify_whitespace = true, .module_format = .cjs }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "module.exports=_Class;") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "module.exports=;"), null);
}

test "Codegen CJS + ES5: export default class with extends" {
    var r = try e2eFull(std.testing.allocator, "export default class CustomEvent extends Event { constructor(type) { super(type); } }", .{ .unsupported = TransformOptions.compat.fromESTarget(.es5) }, .{ .minify_whitespace = true, .module_format = .cjs }, ".ts");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "module.exports=CustomEvent;") != null);
    try std.testing.expectEqual(std.mem.indexOf(u8, r.output, "module.exports=;"), null);
}

// ============================================================
// E2E Tests: Formatted output
// ============================================================

test "Codegen formatted: function declaration" {
    var r = try e2eWithOptions(std.testing.allocator, "function foo() { return 1; }", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("function foo() {\n\treturn 1;\n}\n", r.output);
}

test "Codegen formatted: class with method" {
    var r = try e2eWithOptions(std.testing.allocator, "class Foo { bar() {} }", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("class Foo {\n\tbar() {\n\t}\n}\n", r.output);
}

test "Codegen formatted: spaces indent" {
    var r = try e2eWithOptions(std.testing.allocator, "if (x) { return 1; }", .{ .indent_char = .space, .indent_width = 2 });
    defer r.deinit();
    try std.testing.expectEqualStrings("if (x) {\n  return 1;\n}\n", r.output);
}

// ================================================================
// import.meta polyfill tests
// ================================================================

test "import.meta: ESM keeps import.meta as-is" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .esm });
    defer r.deinit();
    try std.testing.expectEqualStrings("const m=import.meta;", r.output);
}

test "import.meta: CJS node — standalone import.meta" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    // CJS node: import.meta → full polyfill object
    try std.testing.expectEqualStrings(
        "const m={url:require(\"url\").pathToFileURL(__filename).href,dirname:__dirname,filename:__filename};",
        r.output,
    );
}

test "import.meta: CJS browser — standalone import.meta" {
    var r = try e2eWithOptions(std.testing.allocator, "const m = import.meta;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    // CJS browser: import.meta → {}
    try std.testing.expectEqualStrings("const m={};", r.output);
}

test "import.meta.url: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "const u=require(\"url\").pathToFileURL(__filename).href;",
        r.output,
    );
}

test "import.meta.url: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=\"\";", r.output);
}

test "import.meta.dirname: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const d = import.meta.dirname;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings("const d=__dirname;", r.output);
}

test "import.meta.dirname: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const d = import.meta.dirname;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const d=\"\";", r.output);
}

test "import.meta.filename: CJS node" {
    var r = try e2eWithOptions(std.testing.allocator, "const f = import.meta.filename;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=__filename;", r.output);
}

test "import.meta.filename: CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const f = import.meta.filename;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const f=\"\";", r.output);
}

test "import.meta.url: ESM keeps as-is" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .module_format = .esm });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=import.meta.url;", r.output);
}

test "import.meta: replace_import_meta with node platform" {
    // 번들러가 replace_import_meta를 설정하는 경우 (non-ESM 번들)
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .replace_import_meta = true, .platform = .node });
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "const u=require(\"url\").pathToFileURL(__filename).href;",
        r.output,
    );
}

test "import.meta: replace_import_meta with browser platform" {
    var r = try e2eWithOptions(std.testing.allocator, "const u = import.meta.url;", .{ .minify_whitespace = true, .replace_import_meta = true, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const u=\"\";", r.output);
}

test "import.meta: unknown property CJS node falls through to polyfill" {
    // import.meta.env 등 알려지지 않은 프로퍼티 → import.meta polyfill + .env
    var r = try e2eWithOptions(std.testing.allocator, "const e = import.meta.env;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .node });
    defer r.deinit();
    // 알려지지 않은 프로퍼티는 import.meta 폴리필 뒤에 .prop이 붙어야 함
    try std.testing.expectEqualStrings(
        "const e={url:require(\"url\").pathToFileURL(__filename).href,dirname:__dirname,filename:__filename}.env;",
        r.output,
    );
}

test "import.meta: unknown property CJS browser" {
    var r = try e2eWithOptions(std.testing.allocator, "const e = import.meta.env;", .{ .minify_whitespace = true, .module_format = .cjs, .platform = .browser });
    defer r.deinit();
    try std.testing.expectEqualStrings("const e={}.env;", r.output);
}

// ============================================================
