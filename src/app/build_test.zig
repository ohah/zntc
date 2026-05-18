//! app/build.zig 테스트 — HTML/asset rewrite, dev prepare, CSS path 보존/충돌.

const std = @import("std");
const build = @import("build.zig");

test "app build emits rewritten html and public files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("public");
    try tmp.dir.writeFile(.{ .sub_path = "index.html", .data = "<title>%VITE_TITLE%</title><link rel=\"icon\" href=\"/favicon.svg\"><script type=\"module\" src=\"/src/main.ts\"></script>" });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "console.log(import.meta.env.VITE_TITLE, import.meta.env.BASE_URL);" });
    try tmp.dir.writeFile(.{ .sub_path = ".env.production", .data = "VITE_TITLE=ZNTC App\n" });
    try tmp.dir.writeFile(.{ .sub_path = "public/favicon.svg", .data = "<svg></svg>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const output_count = try build.buildApp(std.testing.allocator, .{ .root = root, .base = "/app/" });
    try std.testing.expect(output_count >= 3);

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "ZNTC App") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/app/main-") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ".js") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/app/favicon.svg") != null);
}

test "app dev prepare emits html and returns script entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("public");
    try tmp.dir.writeFile(.{ .sub_path = "index.html", .data = "<title>%VITE_TITLE%</title><script type=\"module\" src=\"/src/main.ts\"></script>" });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "console.log(import.meta.env.VITE_TITLE);" });
    try tmp.dir.writeFile(.{ .sub_path = ".env.development", .data = "VITE_TITLE=Dev App\n" });
    try tmp.dir.writeFile(.{ .sub_path = "public/favicon.svg", .data = "<svg></svg>" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    var result = try build.prepareDev(std.testing.allocator, .{ .root = root, .base = "/app/" });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.endsWith(u8, result.entry_path, "src/main.ts"));

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, ".zntc-dev", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "Dev App") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/app/bundle.js") != null);
}

test "app build rewrites stylesheet url assets and relative html assets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "index.html", .data = "<link rel=\"stylesheet\" href=\"/src/style.css?v=1\"><img src=\"/src/logo.png?raw#x\"><script type=\"module\" src=\"/src/main.ts\"></script>" });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "console.log('x');" });
    try tmp.dir.writeFile(.{ .sub_path = "src/style.css", .data = ".hero{background:url('./bg.png?v=2#hash')}" });
    try tmp.dir.writeFile(.{ .sub_path = "src/bg.png", .data = "bg" });
    try tmp.dir.writeFile(.{ .sub_path = "src/logo.png", .data = "logo" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    _ = try build.buildApp(std.testing.allocator, .{ .root = root, .base = "/app/", .public_dir = null });

    // stylesheet 는 source root-기준 relative path 로 emit (dist/src/style.css).
    const style_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "src", "style.css" });
    defer std.testing.allocator.free(style_path);
    const css = try std.fs.cwd().readFileAlloc(std.testing.allocator, style_path, 1024 * 1024);
    defer std.testing.allocator.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, "url(\"/app/bg.png?v=2#hash\")") != null);

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/app/src/style.css?v=1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "src=\"/app/logo.png?raw#x\"") != null);

    try tmp.dir.access("dist/bg.png", .{});
    try tmp.dir.access("dist/logo.png", .{});
}

test "app build does not collide when bundler emits CSS that HTML also references" {
    // entry main.ts 가 import './main.css' 하고 HTML 도 같은 파일을 link 로 참조하는 시나리오.
    // bundler 는 entry basename 기반으로 main.css 를 asset_output 으로 emit (splitting=false 이면
    // entry_names = "[name]") → reserved 에 main.css 등록. HTML stylesheet 의 source 는
    // root-기준 relative path "src/main.css" 로 별도 emit 되므로 충돌하지 않는다 (서로 다른 path).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{
        .sub_path = "index.html",
        .data = "<link rel=\"stylesheet\" href=\"/src/main.css\"><script type=\"module\" src=\"/src/main.ts\"></script>",
    });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "import './main.css';\nconsole.log('x');" });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.css", .data = ".hero{color:red}" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    _ = try build.buildApp(std.testing.allocator, .{
        .root = root,
        .base = "/",
        .public_dir = null,
        .splitting = false,
    });

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/src/main.css\"") != null);
    try tmp.dir.access("dist/src/main.css", .{});
    try tmp.dir.access("dist/main.css", .{});
}

test "app build preserves nested CSS source path (no basename collision)" {
    // 서브디렉토리에 같은 basename 의 CSS 파일을 두 개 두면, root-기준 relative path 가
    // 보존되어 outdir/src/a/style.css 와 outdir/src/b/style.css 로 분리 emit 된다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src/a");
    try tmp.dir.makePath("src/b");
    try tmp.dir.writeFile(.{
        .sub_path = "index.html",
        .data = "<link rel=\"stylesheet\" href=\"/src/a/style.css\"><link rel=\"stylesheet\" href=\"/src/b/style.css\"><script type=\"module\" src=\"/src/main.ts\"></script>",
    });
    try tmp.dir.writeFile(.{ .sub_path = "src/main.ts", .data = "console.log('x');" });
    try tmp.dir.writeFile(.{ .sub_path = "src/a/style.css", .data = ".a{color:red}" });
    try tmp.dir.writeFile(.{ .sub_path = "src/b/style.css", .data = ".b{color:blue}" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    _ = try build.buildApp(std.testing.allocator, .{ .root = root, .base = "/", .public_dir = null });

    try tmp.dir.access("dist/src/a/style.css", .{});
    try tmp.dir.access("dist/src/b/style.css", .{});

    const html_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "index.html" });
    defer std.testing.allocator.free(html_path);
    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, html_path, 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/src/a/style.css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/src/b/style.css\"") != null);
    const a_css_path = try std.fs.path.join(std.testing.allocator, &.{ root, "dist", "src", "a", "style.css" });
    defer std.testing.allocator.free(a_css_path);
    const a_css = try std.fs.cwd().readFileAlloc(std.testing.allocator, a_css_path, 1024);
    defer std.testing.allocator.free(a_css);
    try std.testing.expect(std.mem.indexOf(u8, a_css, ".a") != null);
}
