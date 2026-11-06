const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");
const compat = @import("../../transformer/transformer.zig").TransformOptions.compat;

fn hasTargetError(result: anytype) bool {
    for (result.diagnostics orelse return false) |diagnostic| if (diagnostic.code == .top_level_await_target and diagnostic.severity == .@"error") return true;
    return false;
}

// A rejection is an unsupported-output diagnostic, never a successful runtime
// oracle. The source itself is valid native ESM and has value42 after evaluation.
test "lowered ESM publication rejects only selected split and PM initializer demand" {
    for ([_]bool{ false, true }) |preserve| {
        inline for (.{ .es5, .es2017 }) |target| {
            for ([_]bool{ false, true }) |minify| {
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                try helpers.writeFile(tmp.dir, "slow.mjs", "export let value=0;await Promise.resolve();value=42;");
                try helpers.writeFile(tmp.dir, "consumer.mjs", "import{value}from './slow.mjs';export const combined=value;");
                try helpers.writeFile(tmp.dir, "entry.mjs", "import{combined}from './consumer.mjs';export{combined};export function load(){return import('./lazy.mjs')}");
                try helpers.writeFile(tmp.dir, "lazy.mjs", "export{combined}from './consumer.mjs';");
                const entry = try helpers.absPath(&tmp, "entry.mjs");
                defer std.testing.allocator.free(entry);
                var bundler = Bundler.init(std.testing.allocator, .{
                    .entry_points = &.{entry},
                    .format = .esm,
                    .code_splitting = true,
                    .preserve_modules = preserve,
                    .unsupported = compat.fromESTarget(target),
                    .minify_syntax = minify,
                    .minify_identifiers = minify,
                });
                defer bundler.deinit();
                const result = try bundler.bundle(std.testing.io);
                defer result.deinit(std.testing.allocator);
                if (!result.hasErrors() or !hasTargetError(result)) std.debug.print("lowered ESM publication missed case preserve={any} target={s} minify={any} output_bytes={d} files={d}\n", .{ preserve, @tagName(target), minify, result.output.len, if (result.outputs) |outputs| outputs.len else 0 });
                try std.testing.expect(result.hasErrors());
                try std.testing.expect(hasTargetError(result));
                try std.testing.expectEqual(@as(usize, 0), result.output.len);
                try std.testing.expectEqual(@as(usize, 0), (result.outputs orelse return error.MissingRejectedOutputs).len);
            }
        }
    }
}

test "lowered ESM publication preserves no TLA nested async dropped labels and shaken modules" {
    const cases = [_]struct { source: []const u8, labels: []const []const u8 = &.{}, unused: bool = false }{
        .{ .source = "export const value=42;" },
        .{ .source = "export async function later(){await Promise.resolve();return 7}export const value=42;" },
        .{ .source = "TRACE:{await Promise.resolve(7)}export const value=42;", .labels = &.{"TRACE"} },
        .{ .source = "import './unused.mjs';export const value=42;", .unused = true },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "package.json", if (case.unused) "{\"type\":\"module\",\"sideEffects\":false}" else "{\"type\":\"module\"}");
        try helpers.writeFile(tmp.dir, "entry.mjs", case.source);
        if (case.unused) try helpers.writeFile(tmp.dir, "unused.mjs", "export let unused=0;await Promise.resolve();unused=7;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = .esm, .code_splitting = true, .drop_labels = case.labels, .unsupported = compat.fromESTarget(.es5) });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        const outputs = result.outputs orelse return error.MissingControlOutputs;
        try std.testing.expect(outputs.len > 0);
        for (outputs) |output| try helpers.writeFile(tmp.dir, std.fs.path.basename(output.path), output.contents);
        try helpers.writeFile(tmp.dir, "check.mjs", "import{value}from './entry.js';console.log(value);");
        const check = try helpers.absPath(&tmp, "check.mjs");
        defer std.testing.allocator.free(check);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", check } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("42\n", actual.stdout);
    }
}

test "lowered ESM publication retains native ESM non ESM waiter and single output contracts" {
    const formats = @import("../types.zig");
    const cases = [_]struct { format: formats.Format, target: compat.ESTarget, split: bool, global_name: ?[]const u8 = null }{
        .{ .format = .esm, .target = .esnext, .split = true },
        .{ .format = .cjs, .target = .es5, .split = true },
        .{ .format = .iife, .target = .es5, .split = false, .global_name = "App" },
        .{ .format = .esm, .target = .es5, .split = false },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "export let value=0;await Promise.resolve();value=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = case.format, .code_splitting = case.split, .global_name = case.global_name, .unsupported = compat.fromESTarget(case.target) });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(!hasTargetError(result));
        try helpers.writeFile(tmp.dir, "package.json", if (case.format == .esm) "{\"type\":\"module\"}" else "{\"type\":\"commonjs\"}");
        if (result.outputs) |outputs| {
            try std.testing.expect(outputs.len > 0);
            for (outputs) |output| try helpers.writeFile(tmp.dir, std.fs.path.basename(output.path), output.contents);
        } else {
            try std.testing.expect(result.output.len > 0);
            try helpers.writeFile(tmp.dir, "entry.js", result.output);
        }
        const driver = switch (case.format) {
            .esm => "import{value}from './entry.js';console.log(value);",
            .cjs => "Promise.resolve(require('./entry.js')).then(function(ns){console.log(ns.value)}).catch(function(e){console.error(e);process.exitCode=1});",
            .iife => "const fs=require('fs');const source=fs.readFileSync(require('path').join(__dirname,'entry.js'),'utf8');Promise.resolve(Function(source+';return App;')()).then(function(ns){console.log(ns.value)}).catch(function(e){console.error(e);process.exitCode=1});",
            else => unreachable,
        };
        const filename = if (case.format == .esm) "check.mjs" else "check.cjs";
        try helpers.writeFile(tmp.dir, filename, driver);
        const check = try helpers.absPath(&tmp, filename);
        defer std.testing.allocator.free(check);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", check } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("42\n", actual.stdout);
    }
}
