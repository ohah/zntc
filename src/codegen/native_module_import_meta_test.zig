const std = @import("std");
const Parser = @import("../parser/parser.zig").Parser;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Codegen = @import("codegen.zig").Codegen;
const Options = @import("options.zig").CodegenOptions;

fn print(a: std.mem.Allocator, source: []const u8, options: Options) ![]const u8 {
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
    var codegen = Codegen.initWithOptions(a, &parser.ast, options);
    return codegen.generate(root);
}

test "native module import meta defaults retain legacy CJS and ESM output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "console.log(import.meta,import.meta.url,import.meta.dirname,import.meta.filename);";
    const cjs = try print(a, source, .{ .module_format = .cjs, .platform = .node, .minify_whitespace = true });
    const explicit_false = try print(a, source, .{ .module_format = .cjs, .platform = .node, .minify_whitespace = true, .native_module_import_meta = false });
    try std.testing.expectEqualStrings(cjs, explicit_false);
    try std.testing.expect(std.mem.indexOf(u8, cjs, "pathToFileURL(__filename)") != null);
    try std.testing.expect(std.mem.indexOf(u8, cjs, "import.meta") == null);
    const esm = try print(a, source, .{ .module_format = .esm, .platform = .node, .minify_whitespace = true });
    const esm_explicit = try print(a, source, .{ .module_format = .esm, .platform = .node, .minify_whitespace = true, .native_module_import_meta = false });
    try std.testing.expectEqualStrings(esm, esm_explicit);
    try std.testing.expectEqualStrings(source, esm);
    const browser = try print(a, source, .{ .module_format = .cjs, .platform = .browser, .minify_whitespace = true });
    try std.testing.expect(std.mem.indexOf(u8, browser, "import.meta") == null);
}

test "native module import meta retains output Module Record in source executions" {
    const sources = [_][]const u8{
        "const meta=import.meta;console.log(JSON.stringify([meta===import.meta,meta.url===import.meta.url,meta.dirname===import.meta.dirname,meta.filename===import.meta.filename,Object.getPrototypeOf(meta)===null]));",
        "function source(){return[import.meta===import.meta,import.meta.url,import.meta.dirname,import.meta.filename]}const arrow=()=>import.meta;const object={method(){return import.meta}};class C{method(){return import.meta}static meta=import.meta}console.log(JSON.stringify([source(),arrow()===import.meta,object.method()===import.meta,new C().method()===import.meta,C.meta===import.meta]));",
        "async function source(){await 0;return[import.meta.url,import.meta.dirname,import.meta.filename]}await 0;console.log(JSON.stringify(await source()));",
        "console.log(JSON.stringify([import.meta['url']===import.meta.url,typeof import.meta.resolve,import.meta.resolve('./native-module-reference.mjs')]));",
    };
    for (sources, 0..) |source, case| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const generated = try print(a, source, .{ .module_format = .cjs, .platform = .node, .native_module_import_meta = true, .module_await_as_yield = true, .minify_whitespace = minify });
        try std.testing.expect(std.mem.indexOf(u8, generated, "pathToFileURL(__filename)") == null);
        const model = try std.fmt.allocPrint(a, "async function drive(it){{let step=it.next();while(!step.done){{try{{step=it.next(await step.value)}}catch(error){{step=it.throw(error)}}}}}}await drive((function*(){{\"use strict\";{s}}})());", .{generated});
        // Both executions have the same output eval Module Record location.
        // This checks metadata preservation, not original-source URL mapping.
        const expected = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", model }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        errdefer std.debug.print("importmeta case={d} minify={} generated={s}\nactual={s}\n", .{ case, minify, generated, actual.stderr });
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
    };
}
