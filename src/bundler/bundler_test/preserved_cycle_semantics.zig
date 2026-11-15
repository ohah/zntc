const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");
const compat = @import("../../transformer/transformer.zig").TransformOptions.compat;
const File = struct { path: []const u8, source: []const u8 };
const Case = struct { name: []const u8, files: []const File, expected: []const u8, weak_map_unavailable: bool = false, source_maps: bool = false, expected_entry_exports: ?[]const []const u8 = null, required_entry_imports: ?[]const []const u8 = null, named_entry_consumer: bool = false, generator_only_target: bool = false };

test "preserved cycles share one generator implementation across legacy frames" {
    const a = std.testing.allocator;
    for ([_]usize{ 12, 48 }) |count| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "main.mjs", "import './setup.mjs';import{read}from'./m0.mjs';console.log(JSON.stringify([globalThis.__ringCount,read()]));");
        try helpers.writeFile(tmp.dir, "setup.mjs", "globalThis.__ringCount=0;");
        for (0..count) |i| {
            const name = try std.fmt.allocPrint(a, "m{d}.mjs", .{i});
            defer a.free(name);
            const text = try std.fmt.allocPrint(a, "import './m{d}.mjs';globalThis.__ringCount++;{s}", .{ (i + 1) % count, if (i == 0) "export function read(){return 42}" else "" });
            defer a.free(text);
            try helpers.writeFile(tmp.dir, name, text);
        }
        const entry = try helpers.absPath(&tmp, "main.mjs");
        defer a.free(entry);
        var bundler = Bundler.init(a, .{
            .entry_points = &.{entry},
            .format = .cjs,
            .platform = .node,
            .preserve_modules = true,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .out_extension_js = ".cjs",
            .unsupported = compat.fromESTarget(.es5),
            // Match the measured ring cohort. Observable names have separate
            // Native controls below, with keep_names explicitly enabled.
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        const outputs = result.outputs orelse return error.MissingPreservedCycleOutputs;
        var shared: ?[]const u8 = null;
        var total_bytes: usize = 0;
        for (outputs) |file| {
            total_bytes += file.contents.len;
            for (file.module_ids) |id| if (std.mem.eql(u8, id, @import("../pm_generator_builtin.zig").id)) {
                try std.testing.expect(shared == null);
                shared = file.path;
                try std.testing.expectEqual(@as(usize, 1), file.exports.len);
                try std.testing.expectEqualStrings(@import("../../runtime_helper_modules.zig").catalogExports(.generator)[0], file.exports[0]);
            };
            try helpers.writeFile(tmp.dir, file.path, file.contents);
        }
        const shared_path = shared orelse return error.MissingSharedGeneratorOutput;
        var consumers: usize = 0;
        for (outputs) |file| {
            var source_frame = false;
            for (file.module_ids) |id| if (std.mem.endsWith(u8, id, ".mjs")) {
                source_frame = true;
            };
            if (!source_frame) continue;
            var matches: usize = 0;
            for (file.imports) |import_path| {
                const resolved = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(file.path) orelse ".", import_path });
                defer a.free(resolved);
                const expected = try std.fs.path.resolve(a, &.{shared_path});
                defer a.free(expected);
                if (std.mem.eql(u8, resolved, expected)) matches += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), matches);
            consumers += 1;
        }
        try std.testing.expectEqual(count + 2, consumers);
        // A broad output budget catches the original per-file 2KB helper
        // duplication (44KB/138KB), without pinning compiler formatting.
        try std.testing.expect(total_bytes < if (count == 12) @as(usize, 20_000) else @as(usize, 60_000));
        const output_entry = try helpers.absPath(&tmp, "main.cjs");
        defer a.free(output_entry);
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output_entry } });
        defer a.free(actual.stdout);
        defer a.free(actual.stderr);
        const expected = try std.fmt.allocPrint(a, "[{d},42]\n", .{count});
        defer a.free(expected);
        if (actual.term != .exited or actual.term.exited != 0) std.debug.print("shared generator stderr={s}\n", .{actual.stderr});
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(expected, actual.stdout);
    };
}

// Execute the same source graph as native ESM and as preserved CJS. The source
// catches expected early TDZ errors; the output must still perform later live
// reads. CJS cycle warnings are retained in failure diagnostics, not mistaken
// for uncaught exceptions or used as a substitute for checking actual values.
fn runCase(case: Case) !void {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}\n");
    for (case.files) |file| try helpers.writeFile(tmp.dir, file.path, file.source);
    const entry = try helpers.absPath(&tmp, "main.mjs");
    defer allocator.free(entry);
    const native_entry = if (case.named_entry_consumer) blk: {
        try helpers.writeFile(tmp.dir, "native-named-consumer.mjs", "import{read,'public-key' as alias}from'./main.mjs';console.log(JSON.stringify([read(),alias()]));\n");
        break :blk try helpers.absPath(&tmp, "native-named-consumer.mjs");
    } else if (case.weak_map_unavailable) blk: {
        // Host-capability control: identical prelude for the Native oracle and
        // emitted output. It is not ordinary Source relocation or a runtime shim.
        try helpers.writeFile(tmp.dir, "native-host.mjs", "const saved=globalThis.WeakMap;try{globalThis.WeakMap=undefined;await import('./main.mjs')}finally{globalThis.WeakMap=saved}\n");
        break :blk try helpers.absPath(&tmp, "native-host.mjs");
    } else try allocator.dupe(u8, entry);
    defer allocator.free(native_entry);
    const native_argv: []const []const u8 = if (case.source_maps) &.{ "node", "--enable-source-maps", native_entry } else &.{ "node", native_entry };
    const native = std.process.run(allocator, std.testing.io, .{ .argv = native_argv }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(native.stdout);
    defer allocator.free(native.stderr);
    if (native.term != .exited or native.term.exited != 0) std.debug.print("preserved cycles oracle {s}: {s}\n", .{ case.name, native.stderr });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings(case.expected, native.stdout);
    const Target = enum { modern, legacy, generator_only };
    const targets: []const Target = if (case.generator_only_target) &.{ .modern, .legacy, .generator_only } else &.{ .modern, .legacy };
    for (targets) |target| for ([_]bool{ false, true }) |minify| {
        var bundler = Bundler.init(allocator, .{
            .entry_points = &.{entry},
            .format = .cjs,
            .platform = .node,
            .preserve_modules = true,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .out_extension_js = ".cjs",
            .unsupported = switch (target) {
                .modern => compat.fromESTarget(.esnext),
                .legacy => compat.fromESTarget(.es5),
                .generator_only => .{ .generator = true },
            },
            // Function/class .name is observable in the default/TDZ controls.
            .keep_names = true,
            .sourcemap = .{ .enable = case.source_maps },
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(allocator);
        if (result.hasErrors()) std.debug.print("preserved cycles {s} target={s} minify={} diagnostics={any}\n", .{ case.name, @tagName(target), minify, result.diagnostics });
        try std.testing.expect(!result.hasErrors());
        const outputs = result.outputs orelse return error.MissingPreservedCycleOutputs;
        try std.testing.expect(outputs.len > 0);
        const output_dir = try std.fmt.allocPrint(allocator, "dist-{s}-{s}", .{ @tagName(target), if (minify) "full" else "plain" });
        defer allocator.free(output_dir);
        var found_entry = false;
        for (outputs) |file| {
            try std.testing.expect(!std.fs.path.isAbsolute(file.path));
            if (std.mem.eql(u8, file.path, "main.cjs")) {
                found_entry = true;
                if (case.expected_entry_exports) |expected_exports| {
                    try std.testing.expectEqual(expected_exports.len, file.exports.len);
                    for (expected_exports) |expected_export| {
                        var matches: usize = 0;
                        for (file.exports) |actual_export| {
                            if (std.mem.eql(u8, expected_export, actual_export)) matches += 1;
                        }
                        try std.testing.expectEqual(@as(usize, 1), matches);
                    }
                }
                if (case.required_entry_imports) |required_imports| {
                    for (file.imports) |import_path| {
                        const resolved = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(file.path) orelse ".", import_path });
                        defer allocator.free(resolved);
                        var emitted = false;
                        for (outputs) |provider| {
                            const provider_path = try std.fs.path.resolve(allocator, &.{provider.path});
                            defer allocator.free(provider_path);
                            if (std.mem.eql(u8, resolved, provider_path)) emitted = true;
                        }
                        try std.testing.expect(emitted);
                    }
                    for (required_imports) |required| {
                        const required_path = try std.fs.path.resolve(allocator, &.{required});
                        defer allocator.free(required_path);
                        var found = false;
                        for (file.imports) |import_path| {
                            const resolved = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(file.path) orelse ".", import_path });
                            defer allocator.free(resolved);
                            if (std.mem.eql(u8, required_path, resolved)) found = true;
                        }
                        try std.testing.expect(found);
                    }
                }
            }
            const dest = try std.fs.path.join(allocator, &.{ output_dir, file.path });
            defer allocator.free(dest);
            try helpers.writeFile(tmp.dir, dest, file.contents);
            if (file.sourcemap) |map_json| {
                const map_dest = try std.fmt.allocPrint(allocator, "{s}.map", .{dest});
                defer allocator.free(map_dest);
                try helpers.writeFile(tmp.dir, map_dest, map_json);
            }
        }
        try std.testing.expect(found_entry);
        const output_relative = try std.fs.path.join(allocator, &.{ output_dir, "main.cjs" });
        defer allocator.free(output_relative);
        const output = try helpers.absPath(&tmp, output_relative);
        defer allocator.free(output);
        const actual_entry = if (case.named_entry_consumer) blk: {
            const host_path = try std.fmt.allocPrint(allocator, "{s}/external-named-consumer.mjs", .{output_dir});
            defer allocator.free(host_path);
            try helpers.writeFile(tmp.dir, host_path, "import{read,'public-key' as alias}from'./main.cjs';console.log(JSON.stringify([read(),alias()]));\n");
            break :blk try helpers.absPath(&tmp, host_path);
        } else if (case.weak_map_unavailable) blk: {
            const host_path = try std.fmt.allocPrint(allocator, "output-host-{s}-{s}.mjs", .{ @tagName(target), if (minify) "full" else "plain" });
            defer allocator.free(host_path);
            const host = try std.fmt.allocPrint(allocator, "const saved=globalThis.WeakMap;try{{globalThis.WeakMap=undefined;await import('./{s}')}}finally{{globalThis.WeakMap=saved}}\n", .{output_relative});
            defer allocator.free(host);
            try helpers.writeFile(tmp.dir, host_path, host);
            break :blk try helpers.absPath(&tmp, host_path);
        } else try allocator.dupe(u8, output);
        defer allocator.free(actual_entry);
        const actual_argv: []const []const u8 = if (case.source_maps) &.{ "node", "--enable-source-maps", actual_entry } else &.{ "node", actual_entry };
        const actual = try std.process.run(allocator, std.testing.io, .{ .argv = actual_argv });
        defer allocator.free(actual.stdout);
        defer allocator.free(actual.stderr);
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
            std.debug.print("preserved cycles {s} target={s} minify={} expected={s} actual={s} stderr={s}\n", .{ case.name, @tagName(target), minify, native.stdout, actual.stdout, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

test "preserved cycles direct-let" {
    try runCase(.{
        .name = "direct-let",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{readLater}from'./dep.mjs';export let counter=0;counter=100;console.log(JSON.stringify(readLater()));\n" },
            .{ .path = "dep.mjs", .source = "import{counter}from'./main.mjs';export function readLater(){return counter;}\n" },
        },
        .expected = "100\n",
    });
}

test "preserved cycles alias-let" {
    try runCase(.{
        .name = "alias-let",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{readLater}from'./dep.mjs';let internal=0;export{internal as counter};internal=100;console.log(JSON.stringify(readLater()));\n" },
            .{ .path = "dep.mjs", .source = "import{counter}from'./main.mjs';export function readLater(){return counter;}\n" },
        },
        .expected = "100\n",
    });
}

test "preserved cycles destructure-let" {
    try runCase(.{
        .name = "destructure-let",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{readLater}from'./dep.mjs';export let{counter}={counter:0};counter=100;console.log(JSON.stringify(readLater()));\n" },
            .{ .path = "dep.mjs", .source = "import{counter}from'./main.mjs';export function readLater(){return counter;}\n" },
        },
        .expected = "100\n",
    });
}

test "preserved cycles reexport-one" {
    try runCase(.{
        .name = "reexport-one",
        .files = &.{
            .{ .path = "barrel.mjs", .source = "export{counter}from'./main.mjs';\n" },
            .{ .path = "main.mjs", .source = "import{readLater}from'./dep.mjs';export let counter=0;counter=100;console.log(JSON.stringify(readLater()));\n" },
            .{ .path = "dep.mjs", .source = "import{counter}from'./barrel.mjs';export function readLater(){return counter;}\n" },
        },
        .expected = "100\n",
    });
}

test "preserved cycles reexport-two" {
    try runCase(.{
        .name = "reexport-two",
        .files = &.{
            .{ .path = "barrel.mjs", .source = "export{counter}from'./main.mjs';\n" },
            .{ .path = "main.mjs", .source = "import{readLater}from'./dep.mjs';export let counter=0;counter=100;console.log(JSON.stringify(readLater()));\n" },
            .{ .path = "dep.mjs", .source = "import{counter}from'./barrel2.mjs';export function readLater(){return counter;}\n" },
            .{ .path = "barrel2.mjs", .source = "export{counter}from'./barrel.mjs';\n" },
        },
        .expected = "100\n",
    });
}

test "preserved cycles consumer-paused-import" {
    try runCase(.{
        .name = "consumer-paused-import",
        .files = &.{
            .{ .path = "a.mjs", .source = "import{b}from'./b.mjs';export function run(){return b;}\n" },
            .{ .path = "b.mjs", .source = "import{run}from'./a.mjs';export let b=42;export const result=run();\n" },
            .{ .path = "main.mjs", .source = "import{run}from'./a.mjs';import{result}from'./b.mjs';console.log(JSON.stringify([result,run()]));\n" },
        },
        .expected = "[42,42]\n",
    });
}

test "preserved cycles cycle-let" {
    try runCase(.{
        .name = "cycle-let",
        .files = &.{
            .{ .path = "a.mjs", .source = "import'./b.mjs';export let value=42;\n" },
            .{ .path = "b.mjs", .source = "import{value}from'./a.mjs';export function read(){return typeof value==='function'?'function:'+value.name:value;}let early;try{early=read()}catch(error){early=error.name;}export{early};\n" },
            .{ .path = "main.mjs", .source = "import'./a.mjs';import{early,read}from'./b.mjs';console.log(JSON.stringify([early,read()]));\n" },
        },
        .expected = "[\"ReferenceError\",42]\n",
    });
}

test "preserved cycles cycle-const" {
    try runCase(.{
        .name = "cycle-const",
        .files = &.{
            .{ .path = "a.mjs", .source = "import'./b.mjs';export const value=42;\n" },
            .{ .path = "b.mjs", .source = "import{value}from'./a.mjs';export function read(){return typeof value==='function'?'function:'+value.name:value;}let early;try{early=read()}catch(error){early=error.name;}export{early};\n" },
            .{ .path = "main.mjs", .source = "import'./a.mjs';import{early,read}from'./b.mjs';console.log(JSON.stringify([early,read()]));\n" },
        },
        .expected = "[\"ReferenceError\",42]\n",
    });
}

test "preserved cycles cycle-class" {
    try runCase(.{
        .name = "cycle-class",
        .files = &.{
            .{ .path = "a.mjs", .source = "import'./b.mjs';export class value{}\n" },
            .{ .path = "b.mjs", .source = "import{value}from'./a.mjs';export function read(){return typeof value==='function'?'function:'+value.name:value;}let early;try{early=read()}catch(error){early=error.name;}export{early};\n" },
            .{ .path = "main.mjs", .source = "import'./a.mjs';import{early,read}from'./b.mjs';console.log(JSON.stringify([early,read()]));\n" },
        },
        .expected = "[\"ReferenceError\",\"function:value\"]\n",
    });
}

test "preserved cycles cycle-default" {
    try runCase(.{
        .name = "cycle-default",
        .files = &.{
            .{ .path = "a.mjs", .source = "import'./b.mjs';export default 42;\n" },
            .{ .path = "b.mjs", .source = "import{default as value}from'./a.mjs';export function read(){return typeof value==='function'?'function:'+value.name:value;}let early;try{early=read()}catch(error){early=error.name;}export{early};\n" },
            .{ .path = "main.mjs", .source = "import'./a.mjs';import{early,read}from'./b.mjs';console.log(JSON.stringify([early,read()]));\n" },
        },
        .expected = "[\"ReferenceError\",42]\n",
    });
}

test "preserved cycles cycle-default-function" {
    try runCase(.{
        .name = "cycle-default-function",
        .files = &.{
            .{ .path = "a.mjs", .source = "import'./b.mjs';export default function(){}\n" },
            .{ .path = "b.mjs", .source = "import{default as value}from'./a.mjs';export function read(){return typeof value==='function'?'function:'+value.name:value;}let early;try{early=read()}catch(error){early=error.name;}export{early};\n" },
            .{ .path = "main.mjs", .source = "import'./a.mjs';import{early,read}from'./b.mjs';console.log(JSON.stringify([early,read()]));\n" },
        },
        .expected = "[\"function:default\",\"function:default\"]\n",
    });
}

test "preserved cycles alias-local-setter" {
    try runCase(.{
        .name = "alias-local-setter",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{readLater}from'./dep.mjs';let A=0;export{A as B};export function setA(){A=100;}setA();console.log(JSON.stringify(readLater()));\n" },
            .{ .path = "dep.mjs", .source = "import{B}from'./main.mjs';export function readLater(){return B;}\n" },
        },
        .expected = "100\n",
    });
}

test "preserved cycles alias-identity-setter" {
    try runCase(.{
        .name = "alias-identity-setter",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{readLater}from'./dep.mjs';export let A=0;export{A as B};export function setA(){A=100;}setA();console.log(JSON.stringify(readLater()));\n" },
            .{ .path = "dep.mjs", .source = "import{B}from'./main.mjs';export function readLater(){return B;}\n" },
        },
        .expected = "100\n",
    });
}

test "preserved cycles import-call-this" {
    try runCase(.{
        .name = "import-call-this",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{check}from'./dep.mjs';console.log(JSON.stringify([check(),check?.(),check`tag`]));\n" },
            .{ .path = "dep.mjs", .source = "export function check(){return this===undefined;}\n" },
        },
        .expected = "[true,true,true]\n",
    });
}

test "preserved cycles holder-name-collision" {
    try runCase(.{
        .name = "holder-name-collision",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{read}from'./dep.mjs';export let value=0;value=100;console.log(JSON.stringify(read({value:'wrong'},()=>-1,{value:'wrong'},-2)));\n" },
            .{ .path = "dep.mjs", .source = "import{value}from'./main.mjs';export function read(ns_main,__tdz,exports_main,__moduleURL0){return value;}\n" },
        },
        .expected = "100\n",
    });
}

test "preserved cycles default-only-primitive" {
    try runCase(.{
        .name = "default-only-primitive",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value from'./dep.mjs';console.log(JSON.stringify([value,value===42]));\n" },
            .{ .path = "dep.mjs", .source = "export default 42;\n" },
        },
        .expected = "[42,true]\n",
    });
}

test "preserved cycles default-only-undefined" {
    try runCase(.{
        .name = "default-only-undefined",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value from'./dep.mjs';console.log(JSON.stringify([value===undefined,typeof value]));\n" },
            .{ .path = "dep.mjs", .source = "export default undefined;\n" },
        },
        .expected = "[true,\"undefined\"]\n",
    });
}

test "preserved cycles default-object-esmodule-identity" {
    try runCase(.{
        .name = "default-object-esmodule-identity",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value,{same}from'./dep.mjs';import*as ns from'./dep.mjs';console.log(JSON.stringify([value===same,ns.default===same,value.default,value.__esModule]));\n" },
            .{ .path = "dep.mjs", .source = "const object={__esModule:true,default:99};export{object as same};export default object;\n" },
        },
        .expected = "[true,true,99,true]\n",
    });
}

test "preserved cycles default-as-alias-identity" {
    try runCase(.{
        .name = "default-as-alias-identity",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value from'./dep.mjs';import{alias}from'./barrel.mjs';console.log(JSON.stringify([alias===value,alias.default,alias.__esModule]));\n" },
            .{ .path = "dep.mjs", .source = "export default {__esModule:true,default:99};\n" },
            .{ .path = "barrel.mjs", .source = "export{default as alias}from'./dep.mjs';\n" },
        },
        .expected = "[true,99,true]\n",
    });
}

test "preserved cycles default-only-anonymous-function" {
    try runCase(.{
        .name = "default-only-anonymous-function",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value from'./dep.mjs';console.log(JSON.stringify([typeof value,value.name]));\n" },
            .{ .path = "dep.mjs", .source = "export default function(){}\n" },
        },
        .expected = "[\"function\",\"default\"]\n",
    });
}

test "preserved cycles default-only-named-function" {
    try runCase(.{
        .name = "default-only-named-function",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value from'./dep.mjs';console.log(JSON.stringify([typeof value,value.name]));\n" },
            .{ .path = "dep.mjs", .source = "export default function Named(){}\n" },
        },
        .expected = "[\"function\",\"Named\"]\n",
    });
}

test "preserved cycles default-only-anonymous-class" {
    try runCase(.{
        .name = "default-only-anonymous-class",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value from'./dep.mjs';console.log(JSON.stringify([typeof value,value.name]));\n" },
            .{ .path = "dep.mjs", .source = "export default class{}\n" },
        },
        .expected = "[\"function\",\"default\"]\n",
    });
}

test "preserved cycles default-only-named-class" {
    try runCase(.{
        .name = "default-only-named-class",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value from'./dep.mjs';console.log(JSON.stringify([typeof value,value.name]));\n" },
            .{ .path = "dep.mjs", .source = "export default class Named{}\n" },
        },
        .expected = "[\"function\",\"Named\"]\n",
    });
}

test "preserved cycles default-paused-c-before-b" {
    try runCase(.{
        .name = "default-paused-c-before-b",
        .files = &.{
            .{ .path = "main.mjs", .source = "import'./a.mjs';import{observed}from'./c.mjs';console.log(JSON.stringify(observed));\n" },
            .{ .path = "a.mjs", .source = "import'./c.mjs';import value from'./b.mjs';export function read(){return value;}\n" },
            .{ .path = "b.mjs", .source = "export default 42;\n" },
            .{ .path = "c.mjs", .source = "import value from'./b.mjs';import{read}from'./a.mjs';export const observed=[value,read()];\n" },
        },
        .expected = "[42,42]\n",
    });
}

test "preserved cycles default-weakmap-unavailable" {
    try runCase(.{
        .name = "default-weakmap-unavailable",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{read}from'./consumer.mjs';console.log(JSON.stringify([read(),read()]));\n" },
            .{ .path = "consumer.mjs", .source = "import value from'./dep.mjs';export function read(){return value.answer;}\n" },
            .{ .path = "dep.mjs", .source = "export default {answer:42};\n" },
        },
        .expected = "[42,42]\n",
        .weak_map_unavailable = true,
    });
}

test "preserved cycles default-intrinsic-prototype-mutation" {
    try runCase(.{
        .name = "default-intrinsic-prototype-mutation",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{read}from'./consumer.mjs';const apply=Function.prototype.apply,get=WeakMap.prototype.get,set=WeakMap.prototype.set;let observed;try{Function.prototype.apply=function(){throw new Error('poison-apply')};WeakMap.prototype.get=function(){throw new Error('poison-get')};WeakMap.prototype.set=function(){throw new Error('poison-set')};observed=[read(),read()]}finally{Function.prototype.apply=apply;WeakMap.prototype.get=get;WeakMap.prototype.set=set}console.log(JSON.stringify(observed));\n" },
            .{ .path = "consumer.mjs", .source = "import value from'./dep.mjs';export function read(){return value.answer;}\n" },
            .{ .path = "dep.mjs", .source = "export default {answer:42};\n" },
        },
        .expected = "[42,42]\n",
    });
}

test "preserved cycles default-provider-poisons-intrinsics-before-publication" {
    try runCase(.{
        .name = "default-provider-poisons-intrinsics-before-publication",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{read}from'./consumer.mjs';let observed;try{observed=[read(),read()]}finally{globalThis.__restoreDefaultIntrinsics();delete globalThis.__restoreDefaultIntrinsics}console.log(JSON.stringify(observed));\n" },
            .{ .path = "consumer.mjs", .source = "import value from'./dep.mjs';export function read(){return value.answer;}\n" },
            .{ .path = "dep.mjs", .source = "const apply=Function.prototype.apply,get=WeakMap.prototype.get,set=WeakMap.prototype.set;globalThis.__restoreDefaultIntrinsics=()=>{Function.prototype.apply=apply;WeakMap.prototype.get=get;WeakMap.prototype.set=set};Function.prototype.apply=function(){throw new Error('provider-poison-apply')};WeakMap.prototype.get=function(){throw new Error('provider-poison-get')};WeakMap.prototype.set=function(){throw new Error('provider-poison-set')};export default {answer:42};\n" },
        },
        .expected = "[42,42]\n",
    });
}

test "preserved cycles default-only-object-identity" {
    try runCase(.{
        .name = "default-only-object-identity",
        .files = &.{
            .{ .path = "main.mjs", .source = "import first from'./dep.mjs';import second from'./dep.mjs';import*as ns from'./dep.mjs';console.log(JSON.stringify([first===second,first===ns.default,first.default,first.__esModule]));\n" },
            .{ .path = "dep.mjs", .source = "export default {__esModule:true,default:99};\n" },
        },
        .expected = "[true,true,99,true]\n",
    });
}

test "preserved cycles default-early-anonymous-name-mutation-persists" {
    try runCase(.{
        .name = "default-early-anonymous-name-mutation-persists",
        .files = &.{
            .{ .path = "main.mjs", .source = "import'./a.mjs';import value from'./a.mjs';import{early}from'./b.mjs';console.log(JSON.stringify([early,value.name]));\n" },
            .{ .path = "a.mjs", .source = "import'./b.mjs';export default function(){}\n" },
            .{ .path = "b.mjs", .source = "import value from'./a.mjs';export const early=value.name;Object.defineProperty(value,'name',{value:'changed-by-dependency',configurable:true});\n" },
        },
        .expected = "[\"default\",\"changed-by-dependency\"]\n",
    });
}

test "preserved cycles default-early-named-function-keeps-source-name" {
    try runCase(.{
        .name = "default-early-named-function-keeps-source-name",
        .files = &.{
            .{ .path = "main.mjs", .source = "import'./a.mjs';import value from'./a.mjs';import{early}from'./b.mjs';console.log(JSON.stringify([early,value.name]));\n" },
            .{ .path = "a.mjs", .source = "import'./b.mjs';export default function OriginalName(){}\n" },
            .{ .path = "b.mjs", .source = "import value from'./a.mjs';export const early=value.name;\n" },
        },
        .expected = "[\"OriginalName\",\"OriginalName\"]\n",
    });
}

test "preserved cycles quoted-public-export-alias-live-keys" {
    try runCase(.{
        .name = "quoted-public-export-alias-live-keys",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{'quoted-key' as picked,bump}from'./dep.mjs';import{'again key' as again}from'./barrel.mjs';import*as ns from'./dep.mjs';const before=picked;bump();console.log(JSON.stringify([before,picked,again,ns['quoted-key'],Object.keys(ns)]));\n" },
            .{ .path = "dep.mjs", .source = "let value=41;export{value as 'quoted-key'};export function bump(){value=42;}\n" },
            .{ .path = "barrel.mjs", .source = "export{'quoted-key' as 'again key'}from'./dep.mjs';\n" },
        },
        .expected = "[41,42,42,42,[\"bump\",\"quoted-key\"]]\n",
    });
}

test "preserved cycles default-live-local-alias" {
    try runCase(.{
        .name = "default-live-local-alias",
        .files = &.{
            .{ .path = "main.mjs", .source = "import value from'./dep.mjs';globalThis.bump();console.log(JSON.stringify(value));\n" },
            .{ .path = "dep.mjs", .source = "let n=1;export{n as default};globalThis.bump=()=>n++;\n" },
        },
        .expected = "2\n",
    });
}

test "preserved cycles later-provider-must-not-evaluate-early" {
    try runCase(.{
        .name = "later-provider-must-not-evaluate-early",
        .generator_only_target = true,
        .files = &.{
            .{ .path = "main.mjs", .source = "import'./setup.mjs';import'./a.mjs';import{events}from'./setup.mjs';console.log(JSON.stringify([events,globalThis.__runResult]));\n" },
            .{ .path = "setup.mjs", .source = "export const events=[];\n" },
            .{ .path = "a.mjs", .source = "import'./c.mjs';import{f}from'./b.mjs';export function run(){return f();}\n" },
            .{ .path = "c.mjs", .source = "import{run}from'./a.mjs';import{events}from'./setup.mjs';events.push('c-start');globalThis.__runResult=run();events.push('c-end');\n" },
            .{ .path = "b.mjs", .source = "import{events}from'./setup.mjs';events.push('b-body');export function f(){return 'ok';}\n" },
        },
        .expected = "[[\"c-start\",\"c-end\",\"b-body\"],\"ok\"]\n",
    });
}

test "preserved cycles hoisted-function-private-lexical-before-body" {
    try runCase(.{
        .name = "hoisted-function-private-lexical-before-body",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{f}from'./a.mjs';import{early}from'./b.mjs';console.log(JSON.stringify([early,f()]));\n" },
            .{ .path = "a.mjs", .source = "import'./b.mjs';export function f(){return x;}let x=42;\n" },
            .{ .path = "b.mjs", .source = "import{f}from'./a.mjs';export let early;try{early=f();}catch(e){early=e.name;}\n" },
        },
        .expected = "[\"ReferenceError\",42]\n",
    });
}

test "preserved cycles source-maps-later-provider-evaluation-order" {
    try runCase(.{
        .name = "source-maps-later-provider-evaluation-order",
        .source_maps = true,
        .files = &.{
            .{ .path = "main.mjs", .source = "import'./setup.mjs';import'./a.mjs';import{events}from'./setup.mjs';console.log(JSON.stringify([events,globalThis.__runResult]));\n" },
            .{ .path = "setup.mjs", .source = "export const events=[];\n" },
            .{ .path = "a.mjs", .source = "import'./c.mjs';import{f}from'./b.mjs';export function run(){return f();}\n" },
            .{ .path = "c.mjs", .source = "import{run}from'./a.mjs';import{events}from'./setup.mjs';events.push('c-start');globalThis.__runResult=run();events.push('c-end');\n" },
            .{ .path = "b.mjs", .source = "import{events}from'./setup.mjs';events.push('b-body');export function f(){return 'ok';}\n" },
        },
        .expected = "[[\"c-start\",\"c-end\",\"b-body\"],\"ok\"]\n",
    });
}

test "preserved cycles source-maps-hoisted-cycle-original-throw-line" {
    try runCase(.{
        .name = "source-maps-hoisted-cycle-original-throw-line",
        .source_maps = true,
        .files = &.{
            .{ .path = "a.mjs", .source = "import './b.mjs';\nexport function run(){\n  throw new Error('source-map-cycle');\n}\n" },
            .{ .path = "b.mjs", .source = "import{run}from'./a.mjs';export let line;try{run();}catch(error){const match=error.stack.match(/a\\.mjs:(\\d+):\\d+/);line=match?Number(match[1]):'missing-original-a';}\n" },
            .{ .path = "main.mjs", .source = "import'./a.mjs';import{line}from'./b.mjs';console.log(JSON.stringify(line));\n" },
        },
        .expected = "3\n",
    });
}

test "preserved cycles public metadata excludes private protocol and resolves imports" {
    try runCase(.{
        .name = "public-metadata-physical-imports",
        .named_entry_consumer = true,
        .expected_entry_exports = &.{ "read", "public-key" },
        .required_entry_imports = &.{"dep.cjs"},
        .files = &.{
            .{ .path = "main.mjs", .source = "import{step}from'./dep.mjs';export function read(){return 42;}export{read as 'public-key'};console.log(JSON.stringify(step()));\n" },
            .{ .path = "dep.mjs", .source = "import{read}from'./main.mjs';export function step(){return read();}\n" },
        },
        .expected = "42\n[42,42]\n",
    });
}

test "preserved cycles hoisted-function-private-class-before-body" {
    try runCase(.{
        .name = "hoisted-function-private-class-before-body",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{f}from'./a.mjs';import{early}from'./b.mjs';console.log(JSON.stringify([early,f()]));\n" },
            .{ .path = "a.mjs", .source = "import'./b.mjs';export function f(){return X.value;}class X{static value=42;}\n" },
            .{ .path = "b.mjs", .source = "import{f}from'./a.mjs';export let early;try{early=f();}catch(e){early=e.name;}\n" },
        },
        .expected = "[\"ReferenceError\",42]\n",
    });
}

test "preserved cycles shared generator keeps a same-basename source module" {
    try runCase(.{
        .name = "shared-generator-source-basename",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{read}from'./runtime-generator.mjs';console.log(read());\n" },
            .{ .path = "runtime-generator.mjs", .source = "import'./main.mjs';import'./runtime-generator-1.mjs';export function read(){return 42;}\n" },
            .{ .path = "runtime-generator-1.mjs", .source = "globalThis.generatorSourceKept=true;\n" },
        },
        .expected = "42\n",
    });
}

test "preserved cycles shared generator reserves case variants of source paths" {
    try runCase(.{
        .name = "shared-generator-casefold-source",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{read}from'./Runtime-Generator.mjs';console.log(read());\n" },
            .{ .path = "Runtime-Generator.mjs", .source = "import'./main.mjs';import'./RUNTIME-GENERATOR-1.mjs';export function read(){return 41+globalThis.generatorSuffix;}\n" },
            .{ .path = "RUNTIME-GENERATOR-1.mjs", .source = "globalThis.generatorSuffix=1;\n" },
        },
        .expected = "42\n",
    });
}

test "preserved cycles shared generator reserves source output directories" {
    try runCase(.{
        .name = "shared-generator-source-directory",
        .files = &.{
            .{ .path = "main.mjs", .source = "import{read}from'./runtime-generator.cjs/user.mjs';console.log(read());\n" },
            .{ .path = "runtime-generator.cjs/user.mjs", .source = "import'../main.mjs';import'../runtime-generator-1.cjs/user.mjs';export function read(){return 41+globalThis.generatorSuffix;}\n" },
            .{ .path = "runtime-generator-1.cjs/user.mjs", .source = "globalThis.generatorSuffix=1;\n" },
        },
        .expected = "42\n",
    });
}

test "preserved cycles shared generator isolates later frames from source iterator prototypes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "early.mjs", "import './side.mjs';function* userGenerator(){yield 1;}const proto=Object.getPrototypeOf(Object.getPrototypeOf(userGenerator()));const saved=Object.getOwnPropertyDescriptor(proto,'next');globalThis.intercepts=0;Object.defineProperty(proto,'next',{get:function(){return function(){throw Error('poison-next')}},set:function(value){globalThis.intercepts++},configurable:true});globalThis.restore=function(){if(saved)Object.defineProperty(proto,'next',saved);else delete proto.next};");
    try helpers.writeFile(tmp.dir, "side.mjs", "import './early.mjs';");
    try helpers.writeFile(tmp.dir, "later.mjs", "import './later-side.mjs';export const value=42;");
    try helpers.writeFile(tmp.dir, "later-side.mjs", "import './later.mjs';");
    const early = try helpers.absPath(&tmp, "early.mjs");
    defer a.free(early);
    const later = try helpers.absPath(&tmp, "later.mjs");
    defer a.free(later);
    const source_url = try std.fmt.allocPrint(a, "file://{s}", .{early});
    defer a.free(source_url);
    const source_uri = try std.json.Stringify.valueAlloc(a, source_url, .{});
    defer a.free(source_uri);
    const later_url = try std.fmt.allocPrint(a, "file://{s}", .{later});
    defer a.free(later_url);
    const later_uri = try std.json.Stringify.valueAlloc(a, later_url, .{});
    defer a.free(later_uri);
    const native_script = try std.fmt.allocPrint(a, "await import({s});try{{const m=await import({s});console.log(JSON.stringify([m.value,globalThis.intercepts]))}}finally{{globalThis.restore()}}", .{ source_uri, later_uri });
    defer a.free(native_script);
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native_script } });
    defer a.free(native.stdout);
    defer a.free(native.stderr);
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings("[42,0]\n", native.stdout);
    for ([_]bool{ false, true }) |legacy| for ([_]bool{ false, true }) |minify| {
        var bundler = Bundler.init(a, .{
            .entry_points = &.{ early, later },
            .format = .cjs,
            .platform = .node,
            .preserve_modules = true,
            .preserve_modules_root = std.fs.path.dirname(early),
            .out_extension_js = ".cjs",
            .unsupported = if (legacy) compat.fromESTarget(.es5) else .{},
            .keep_names = true,
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        const directory = try std.fmt.allocPrint(a, "shared-proto-{any}-{any}", .{ legacy, minify });
        defer a.free(directory);
        for (result.outputs.?) |file| {
            const path = try std.fs.path.join(a, &.{ directory, file.path });
            defer a.free(path);
            try helpers.writeFile(tmp.dir, path, file.contents);
        }
        const output_early = try std.fs.path.join(a, &.{ std.fs.path.dirname(early).?, directory, "early.cjs" });
        defer a.free(output_early);
        const output_later = try std.fs.path.join(a, &.{ std.fs.path.dirname(early).?, directory, "later.cjs" });
        defer a.free(output_later);
        const quoted_early = try std.json.Stringify.valueAlloc(a, output_early, .{});
        defer a.free(quoted_early);
        const quoted_later = try std.json.Stringify.valueAlloc(a, output_later, .{});
        defer a.free(quoted_later);
        const script = try std.fmt.allocPrint(a, "require({s});try{{const m=require({s});console.log(JSON.stringify([m.value,globalThis.intercepts]))}}finally{{globalThis.restore()}}", .{ quoted_early, quoted_later });
        defer a.free(script);
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
        defer a.free(actual.stdout);
        defer a.free(actual.stderr);
        if (actual.term != .exited or actual.term.exited != 0) std.debug.print("shared generator prototype stderr={s}\n", .{actual.stderr});
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    };
}

test "preserved cycles shared generator reserves Unicode aliases of ASCII helper paths" {
    try runCase(.{
        .name = "shared-generator-unicode-path-alias",
        .source_maps = true,
        .files = &.{
            .{ .path = "main.mjs", .source = "import{read}from'./runtime-generator.cj\u{17f}/user.mjs';console.log(JSON.stringify([read(),Object.getPrototypeOf(read)===Function.prototype,read.prototype.constructor===read]));\n" },
            .{ .path = "runtime-generator.cj\u{17f}/user.mjs", .source = "import'../main.mjs';import'../runtime-generator-1.cj\u{17f}/user.mjs';export function read(){return 41+globalThis.generatorSuffix;}\n" },
            .{ .path = "runtime-generator-1.cj\u{17f}/user.mjs", .source = "globalThis.generatorSuffix=1;\n" },
        },
        .expected = "[42,true,true]\n",
    });
}
