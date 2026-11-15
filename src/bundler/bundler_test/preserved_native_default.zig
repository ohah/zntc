const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");

const File = struct { path: []const u8, source: []const u8 };
const Case = struct { name: []const u8, files: []const File, observe: []const u8, expected: []const u8 };

fn check(case: Case) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
    for (case.files) |file| try helpers.writeFile(tmp.dir, file.path, file.source);
    try helpers.writeFile(tmp.dir, "observe.mjs", case.observe);
    const observer = try helpers.absPath(&tmp, "observe.mjs");
    defer a.free(observer);
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", observer } });
    defer a.free(native.stdout);
    defer a.free(native.stderr);
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings(case.expected, native.stdout);
    const entry = try helpers.absPath(&tmp, "main.mjs");
    defer a.free(entry);
    for (0..4) |mode| {
        var bundler = Bundler.init(a, .{
            .entry_points = &.{entry},
            .platform = .node,
            .format = .esm,
            .preserve_modules = true,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .out_extension_js = ".mjs",
            .keep_names = true,
            .minify_whitespace = mode == 1 or mode == 3,
            .minify_syntax = mode == 2 or mode == 3,
            .minify_identifiers = mode == 3,
            // Exercise the map-enabled uncached path without asserting map text.
            .sourcemap = .{ .enable = mode == 1 },
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        const outputs = result.outputs orelse return error.MissingNativeDefaultOutputs;
        for (outputs) |output| {
            try std.testing.expect(!std.fs.path.isAbsolute(output.path));
            const dest = try std.fs.path.join(a, &.{ "out", output.path });
            defer a.free(dest);
            try helpers.writeFile(tmp.dir, dest, output.contents);
        }
        try helpers.writeFile(tmp.dir, "out/observe.mjs", case.observe);
        const emitted_observer = try helpers.absPath(&tmp, "out/observe.mjs");
        defer a.free(emitted_observer);
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", emitted_observer } });
        defer a.free(actual.stdout);
        defer a.free(actual.stderr);
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
            std.debug.print("preserved native default case={s} mode={d} stderr={s} expected={s} actual={s}\n", .{ case.name, mode, actual.stderr, native.stdout, actual.stdout });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    }
}

test "preserved native default anonymous function retains callable name prototype and identity" {
    try check(.{
        .name = "single",
        .files = &.{.{ .path = "main.mjs", .source = "export default function(){return 42}" }},
        .observe = "import f from './main.mjs';import again from './main.mjs';console.log(JSON.stringify([f(),f.name,f===again,f.prototype.constructor===f,new f() instanceof f]));",
        .expected = "[42,\"default\",true,true,true]\n",
    });
}

test "preserved native default distinct anonymous providers avoid facade name collisions" {
    try check(.{
        .name = "two providers",
        .files = &.{
            .{ .path = "main.mjs", .source = "import a from './a.mjs';import b from './b.mjs';const _default=7;const default_export=8;export{a,b,_default,default_export}" },
            .{ .path = "a.mjs", .source = "export default function(){return 41}" },
            .{ .path = "b.mjs", .source = "export default function(){return 42}" },
        },
        .observe = "import{a,b,_default,default_export}from './main.mjs';console.log(JSON.stringify([a(),b(),a.name,b.name,a!==b,a.prototype!==b.prototype,a.prototype.constructor===a,b.prototype.constructor===b,_default,default_export]));",
        .expected = "[41,42,\"default\",\"default\",true,true,true,true,7,8]\n",
    });
}

test "preserved native default anonymous function is hoisted across a cycle" {
    try check(.{
        .name = "cycle",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{early}from './b.mjs';export default function(){return 42}export{early}" },
            .{ .path = "b.mjs", .source = "import f from './main.mjs';export const early=[f(),f.name,f.prototype.constructor===f]" },
        },
        .observe = "import f,{early}from './main.mjs';console.log(JSON.stringify([early,f(),f.name]));",
        .expected = "[[42,\"default\",true],42,\"default\"]\n",
    });
}

test "preserved native default named and class expression snapshot controls" {
    try check(.{
        .name = "named and snapshot class",
        .files = &.{
            .{ .path = "main.mjs", .source = "import Named from './named.mjs';import Snapshot from './class.mjs';export{Named,Snapshot}" },
            .{ .path = "named.mjs", .source = "export default function Original(){return 42}" },
            .{ .path = "class.mjs", .source = "let C=class First{};export default C;C=class Second{}" },
        },
        .observe = "import{Named,Snapshot}from './main.mjs';console.log(JSON.stringify([Named(),Named.name,Snapshot.name,Snapshot.prototype.constructor===Snapshot,new Snapshot() instanceof Snapshot]));",
        .expected = "[42,\"Original\",\"First\",true,true]\n",
    });
}
