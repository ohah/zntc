const std = @import("std");
const bundler = @import("../bundler.zig");
const Bundler = bundler.Bundler;
const BundleResult = bundler.BundleResult;
const Store = @import("../module_store.zig").PersistentModuleStore;
const Graph = @import("../graph.zig").ModuleGraph;
const helpers = @import("../test_helpers.zig");
const compat = @import("../../transformer/compat.zig");

fn run(allocator: std.mem.Allocator, path: []const u8) !std.process.RunResult {
    return std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", path } });
}

fn writePreserved(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, directory: []const u8, result: BundleResult) ![]const u8 {
    const outputs = result.outputs orelse return error.MissingPreservedCacheOutputs;
    var entry_found = false;
    for (outputs) |file| {
        try std.testing.expect(!std.fs.path.isAbsolute(file.path));
        const target = try std.fs.path.join(allocator, &.{ directory, file.path });
        defer allocator.free(target);
        try helpers.writeFile(tmp.dir, target, file.contents);
        if (std.mem.eql(u8, file.path, "main.cjs")) entry_found = true;
    }
    try std.testing.expect(entry_found);
    const relative = try std.fs.path.join(allocator, &.{ directory, "main.cjs" });
    defer allocator.free(relative);
    return helpers.absPath(tmp, relative);
}

test "preserved cycles module store non-PM to PM transition retains private lexical TDZ" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Identical to the private-cell cycle regression. No fixture edits or
    // watcher change notifications occur between the two configurations.
    const files = [_]struct { name: []const u8, source: []const u8 }{
        .{ .name = "main.mjs", .source = "import{f}from'./a.mjs';import{early}from'./b.mjs';console.log(JSON.stringify([early,f()]));\n" },
        .{ .name = "a.mjs", .source = "import'./b.mjs';export function f(){return x;}let x=42;\n" },
        .{ .name = "b.mjs", .source = "import{f}from'./a.mjs';export let early;try{early=f();}catch(e){early=e.name;}\n" },
    };
    try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}\n");
    var paths: [files.len][]const u8 = undefined;
    var times: [files.len]i128 = undefined;
    for (files, 0..) |file, i| {
        try helpers.writeFile(tmp.dir, file.name, file.source);
        paths[i] = try helpers.absPath(&tmp, file.name);
        times[i] = try Graph.getMtime(std.testing.io, paths[i]);
    }
    defer for (paths) |path| a.free(path);
    const entry = paths[0];
    const provider = paths[1];
    const expected = "[\"ReferenceError\",42]\n";
    const native = try run(a, entry);
    defer a.free(native.stdout);
    defer a.free(native.stderr);
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings(expected, native.stdout);

    var store = Store.init(a);
    defer store.deinit();
    const initial_options: bundler.BundleOptions = .{
        .entry_points = &.{entry},
        .format = .cjs,
        .platform = .node,
        .unsupported = compat.fromESTarget(.es5),
        .module_store = &store,
    };
    {
        var initial = Bundler.init(a, initial_options);
        defer initial.deinit();
        const initial_result = try initial.bundle(std.testing.io);
        defer initial_result.deinit(a);
        if (initial_result.hasErrors()) std.debug.print("PM_STORE_TRANSITION initial_build errors={} reparsed={any}\n", .{ initial_result.hasErrors(), initial_result.reparsed_modules });
        try std.testing.expect(!initial_result.hasErrors());
        try helpers.writeFile(tmp.dir, "initial.cjs", initial_result.output);
        const first_output = try helpers.absPath(&tmp, "initial.cjs");
        defer a.free(first_output);
        const first = try run(a, first_output);
        defer a.free(first.stdout);
        defer a.free(first.stderr);
        // This first configuration only seeds the store; its pre-existing
        // single-bundle cycle value is not promoted to the PM contract.
        if (first.term != .exited or first.term.exited != 0) std.debug.print("PM_STORE_TRANSITION initial_runtime term={any} stdout={s} stderr={s}\n", .{ first.term, first.stdout, first.stderr });
        try std.testing.expect(first.term == .exited and first.term.exited == 0);
    }
    const cached_provider = store.modules.get(provider) orelse return error.MissingTransitionProviderCacheEntry;
    try std.testing.expectEqual(times[1], cached_provider.mtime);
    var pm_options = initial_options;
    pm_options.preserve_modules = true;
    pm_options.preserve_modules_root = std.fs.path.dirname(entry);
    pm_options.out_extension_js = ".cjs";
    var warm = Bundler.init(a, pm_options);
    defer warm.deinit();
    const warm_result = try warm.bundle(std.testing.io);
    defer warm_result.deinit(a);
    try std.testing.expect(!warm_result.hasErrors());
    const warm_entry = try writePreserved(a, &tmp, "warm", warm_result);
    defer a.free(warm_entry);
    const warm_actual = try run(a, warm_entry);
    defer a.free(warm_actual.stdout);
    defer a.free(warm_actual.stderr);

    // Policy admission is per entry: same-policy lookup retains the exact
    // cached module; reversing it evicts before any arena can be transferred.
    const retained = store.getIfFresh(provider, times[1]) orelse return error.MissingPmProviderCacheEntry;
    try std.testing.expectEqual(@as(?bool, true), retained.pm_cjs_module_environments);
    try std.testing.expect(retained == store.getIfFresh(provider, times[1]).?);
    store.pm_cjs_module_environments = false;
    try std.testing.expect(store.getIfFresh(provider, times[1]) == null);
    try std.testing.expect(!store.modules.contains(provider));
    store.pm_cjs_module_environments = true;

    pm_options.module_store = null;
    var cold = Bundler.init(a, pm_options);
    defer cold.deinit();
    const cold_result = try cold.bundle(std.testing.io);
    defer cold_result.deinit(a);
    try std.testing.expect(!cold_result.hasErrors());
    const cold_entry = try writePreserved(a, &tmp, "cold", cold_result);
    defer a.free(cold_entry);
    const cold_actual = try run(a, cold_entry);
    defer a.free(cold_actual.stdout);
    defer a.free(cold_actual.stderr);
    for (paths, times) |path, before| try std.testing.expectEqual(before, try Graph.getMtime(std.testing.io, path));
    if (warm_actual.term != .exited or warm_actual.term.exited != 0 or cold_actual.term != .exited or cold_actual.term.exited != 0 or
        !std.mem.eql(u8, native.stdout, warm_actual.stdout) or !std.mem.eql(u8, native.stdout, cold_actual.stdout))
        std.debug.print("PM_STORE_TRANSITION warm_reparsed={any} warm_term={any} warm_stdout={s} warm_stderr={s} cold_term={any} cold_stdout={s} cold_stderr={s}\n", .{ warm_result.reparsed_modules, warm_actual.term, warm_actual.stdout, warm_actual.stderr, cold_actual.term, cold_actual.stdout, cold_actual.stderr });
    try std.testing.expect(cold_actual.term == .exited and cold_actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, cold_actual.stdout);
    try std.testing.expect(warm_actual.term == .exited and warm_actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, warm_actual.stdout);
    try std.testing.expectEqualStrings(cold_actual.stdout, warm_actual.stdout);
}
