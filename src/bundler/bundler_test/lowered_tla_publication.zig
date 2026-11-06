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

test "lowered ESM publication owns readiness chunk descriptors and rejects ten foreign producer roles" {
    const a = std.testing.allocator;
    const runtime = @import("../emitter/runtime_helpers.zig");
    const BundlerGraph = @import("../graph.zig").ModuleGraph;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "entry.mjs", "export let value=0;await Promise.resolve();value=42;");
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(entry);
    const options: @import("../bundler.zig").BundleOptions = .{ .entry_points = &.{entry}, .format = .cjs, .code_splitting = true, .unsupported = compat.fromESTarget(.es5) };
    var cache = Bundler.initResolveCacheFromOptions(a, options);
    defer cache.deinit();
    var graph = BundlerGraph.init(a, &cache);
    defer graph.deinit();
    var bundler = Bundler.initWithGraph(a, options, &cache, &graph);
    defer bundler.deinit();
    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(a);
    try std.testing.expect(!result.hasErrors());
    const known = graph.tla_readiness_all orelse return error.MissingTlaReadinessHelper;
    const provider = graph.moduleAtMut(known.module_index) orelse return error.MissingTlaReadinessHelper;
    try std.testing.expect(!provider.is_entry_point);
    inline for (.{ .auto, .named, .default_, .none }) |mode|
        try std.testing.expect(try runtime.cjsEntryDescriptorCandidate(&graph, provider, .cjs, mode));
    try std.testing.expect(!try runtime.cjsEntryDescriptorCandidate(&graph, provider, .esm, .none));
    const saved = provider.*;
    const original_binding = provider.export_bindings[known.export_index];
    const original_symbol = provider.semantic.?.symbols.items[@backingInt(known.symbol_id)];
    for (0..10) |poison| {
        defer {
            provider.* = saved;
            graph.tla_readiness_all = known;
            provider.export_bindings[known.export_index] = original_binding;
            provider.semantic.?.symbols.items[@backingInt(known.symbol_id)] = original_symbol;
        }
        switch (poison) {
            0 => provider.semantic = null,
            1 => graph.tla_readiness_all.?.owner_token = .unassigned,
            2 => provider.semantic.?.owner_token = @fromBackingInt(@intCast(@backingInt(known.owner_token) + 1)),
            3 => graph.tla_readiness_all.?.export_index = @intCast(provider.export_bindings.len),
            4 => graph.tla_readiness_all.?.symbol_id = @fromBackingInt(@as(u32, @intCast(provider.semantic.?.symbols.items.len))),
            5 => provider.export_bindings[known.export_index].symbol = @import("../symbol.zig").SymbolRef.invalid,
            6 => provider.export_bindings[known.export_index].exported_name = "foreign",
            7 => provider.semantic.?.symbols.items[@backingInt(known.symbol_id)].kind = .variable_var,
            8 => provider.runtime_helper_source = null,
            9 => provider.wrap_kind = .esm,
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidTlaReadinessHelper, runtime.cjsEntryDescriptorCandidate(&graph, provider, .cjs, .none));
    }
    // Same bytes and exact helper index do not authorize a foreign Module object.
    var foreign = saved;
    try std.testing.expectError(error.InvalidTlaReadinessHelper, runtime.cjsEntryDescriptorCandidate(&graph, &foreign, .cjs, .none));
    const source_module = graph.moduleAtMut(graph.path_to_module.get(entry).?).?;
    const old_entry = source_module.is_entry_point;
    source_module.is_entry_point = false;
    defer source_module.is_entry_point = old_entry;
    try std.testing.expect(!try runtime.cjsEntryDescriptorCandidate(&graph, source_module, .cjs, .named));
    try std.testing.expect(!try runtime.cjsEntryDescriptorCandidate(&graph, source_module, .cjs, .none));
}
