//! Namespace holder hygiene; direct namespace callee rewriting stays unchanged.
const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");
const Case = struct { name: []const u8, entry: []const u8, dep: []const u8, expected: []const u8, lazy: ?[]const u8 = null, barrel: ?[]const u8 = null, forbidden_output: ?[]const u8 = null, owner_placeholder: bool = false, provider_probe: ?[]const u8 = null, provider_expected: []const u8 = "" };
const Format = @import("../types.zig").Format;
const Profile = struct { format: Format = .cjs, preserve: bool = true, split: bool = false, minify: bool = false, syntax: bool = false };
fn run(case: Case, profile: Profile) !void {
    errdefer std.debug.print("namespace holder hygiene case={s} format={s} preserve={any} split={any} minify={any}\n", .{ case.name, @tagName(profile.format), profile.preserve, profile.split, profile.minify });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "package.json", if (profile.format == .esm) "{\"type\":\"module\"}" else "{\"type\":\"commonjs\"}");
    const input_entry = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(input_entry);
    const input_dep = try helpers.absPath(&tmp, "dep.mjs");
    defer std.testing.allocator.free(input_dep);
    const owner = try @import("../namespace_holder_reservations.zig").ownerBase(std.testing.allocator, input_entry, input_dep);
    defer std.testing.allocator.free(owner);
    const prepared = if (case.owner_placeholder)
        try std.mem.replaceOwned(u8, std.testing.allocator, case.entry, "@HOLDER@", owner)
    else
        try std.testing.allocator.dupe(u8, case.entry);
    defer std.testing.allocator.free(prepared);
    try helpers.writeFile(tmp.dir, "entry.mjs", prepared);
    try helpers.writeFile(tmp.dir, "dep.mjs", case.dep);
    if (case.lazy) |text| try helpers.writeFile(tmp.dir, "lazy.mjs", text);
    if (case.barrel) |text| try helpers.writeFile(tmp.dir, "barrel.mjs", text);
    const entry = try helpers.absPath(&tmp, "entry.mjs");
    defer std.testing.allocator.free(entry);
    const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", entry } });
    defer std.testing.allocator.free(native.stdout);
    defer std.testing.allocator.free(native.stderr);
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings(case.expected, native.stdout);
    var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = profile.format, .platform = .node, .preserve_modules = profile.preserve, .code_splitting = profile.split, .minify_identifiers = profile.minify, .minify_syntax = profile.syntax });
    defer bundler.deinit();
    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    if (result.outputs) |outputs| {
        for (outputs) |output| try helpers.writeFile(tmp.dir, std.fs.path.basename(output.path), output.contents);
    } else try helpers.writeFile(tmp.dir, "entry.js", result.output);
    if (case.forbidden_output) |marker| {
        if (result.outputs) |outputs| {
            for (outputs) |output| try std.testing.expect(std.mem.indexOf(u8, output.contents, marker) == null);
        } else try std.testing.expect(std.mem.indexOf(u8, result.output, marker) == null);
    }
    if (case.provider_probe) |probe| {
        try std.testing.expect(profile.format == .cjs and profile.preserve);
        const provider = try helpers.absPath(&tmp, "dep.js");
        defer std.testing.allocator.free(provider);
        const observed = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", probe, provider } });
        defer std.testing.allocator.free(observed.stdout);
        defer std.testing.allocator.free(observed.stderr);
        if (!(observed.term == .exited and observed.term.exited == 0))
            std.debug.print("quoted provider standalone stderr:\n{s}\n", .{observed.stderr});
        try std.testing.expect(observed.term == .exited and observed.term.exited == 0);
        try std.testing.expectEqualStrings(case.provider_expected, observed.stdout);
    }
    const emitted = try helpers.absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(emitted);
    const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", emitted } });
    defer std.testing.allocator.free(actual.stdout);
    defer std.testing.allocator.free(actual.stderr);
    if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("namespace holder hygiene actual runtime error:\n{s}\n", .{actual.stderr});
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    if (!std.mem.eql(u8, native.stdout, actual.stdout)) {
        if (result.outputs) |outputs| {
            for (outputs) |output| std.debug.print("holder output {s}:\n{s}\n", .{ output.path, output.contents });
        } else std.debug.print("holder output:\n{s}\n", .{result.output});
    }
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
}

const positives = [_]Case{
    .{ .name = "same-target-values", .entry = "import*as left from './dep.mjs';import*as right from './dep.mjs';console.log(left===right);", .dep = "export const value=7;", .expected = "true\n" },
    .{ .name = "reflect-parameter-shadow", .entry = "import*as ns from './dep.mjs';function check(ns_ns,dep_ns){return Reflect.get(ns,'value')}console.log(check({value:9},{value:11}));", .dep = "export const value=7;", .expected = "7\n" },
    .{ .name = "top-level-holder-shadow", .entry = "import*as ns from './dep.mjs';const ns_ns=9;console.log(JSON.stringify([Reflect.get(ns,'value'),ns_ns]));", .dep = "export const value=7;", .expected = "[7,9]\n" },
    .{ .name = "closure-holder-shadow", .entry = "import*as ns from './dep.mjs';function check(){let ns_ns={value:9},dep_ns={value:11};return()=>[Reflect.get(ns,'value'),ns_ns.value,dep_ns.value]}console.log(JSON.stringify(check()()));", .dep = "export const value=7;", .expected = "[7,9,11]\n" },
    .{ .name = "value-alias-live-getter", .entry = "import*as ns from './dep.mjs';const alias=ns;Reflect.apply(alias.bump,alias,[]);console.log(Reflect.get(alias,'value'));", .dep = "export let value=6;export function bump(){value++}", .expected = "7\n" },
    .{ .name = "same-target-live-aliases", .entry = "import*as left from './dep.mjs';import*as right from './dep.mjs';Reflect.apply(left.bump,left,[]);console.log(JSON.stringify([left===right,Reflect.get(left,'value'),Reflect.get(right,'value')]));", .dep = "export let value=6;export function bump(){value++}", .expected = "[true,7,7]\n" },
    .{ .name = "different-target-values", .entry = "import*as left from './dep.mjs';import*as right from './lazy.mjs';console.log(JSON.stringify([left===right,Reflect.get(left,'value'),Reflect.get(right,'value')]));", .dep = "export const value=7;", .lazy = "export const value=9;", .expected = "[false,7,9]\n" },
    .{ .name = "unicode-value-key", .entry = "import*as ns from './dep.mjs';console.log(Reflect.get(ns,'값'));", .dep = "export const 값=7;", .expected = "7\n" },
    .{ .name = "actual-owner-global-reservation", .entry = "import*as ns from './dep.mjs';globalThis['@HOLDER@']=13;console.log(JSON.stringify([Reflect.get(ns,'value'),@HOLDER@]));", .dep = "export const value=7;", .expected = "[7,13]\n", .owner_placeholder = true },
    .{ .name = "actual-owner-lexical-reservation", .entry = "import*as ns from './dep.mjs';const @HOLDER@=13;console.log(JSON.stringify([Reflect.get(ns,'value'),@HOLDER@]));", .dep = "export const value=7;", .expected = "[7,13]\n", .owner_placeholder = true },
};
const profiles = [_]Profile{ .{}, .{ .minify = true }, .{ .preserve = false }, .{ .preserve = false, .split = true, .format = .esm } };

test "namespace holder hygiene ten value and lifetime inputs" {
    for (positives) |case| for (profiles) |profile| try run(case, profile);
    std.debug.print("namespace holder hygiene positives=10 profiles=4 native=40\n", .{});
}

test "namespace holder hygiene preserves ordinary call and existing reflection controls" {
    const controls = [_]Case{
        .{ .name = "ordinary-named-call", .entry = "import{read}from './dep.mjs';console.log(read()===undefined);", .dep = "export function read(){return this}", .expected = "true\n" },
        .{ .name = "detached-namespace-member", .entry = "import*as ns from './dep.mjs';console.log((0,ns.read)()===undefined);", .dep = "export function read(){return this}", .expected = "true\n" },
        .{ .name = "value-alias-existing-member-call", .entry = "import*as ns from './dep.mjs';const alias=ns;console.log(alias.read());", .dep = "export const value=7;export function read(){return this.value}", .expected = "7\n" },
        .{ .name = "namespace-direct-independent-call", .entry = "import*as ns from './dep.mjs';console.log(ns.read());", .dep = "export function read(){return 7}", .expected = "7\n" },
        .{ .name = "existing-sealed-extensible-match", .entry = "import*as ns from './dep.mjs';console.log(JSON.stringify(ns.read()));", .dep = "export function read(){return[Object.isExtensible(this),Object.isSealed(this)]}", .expected = "[false,true]\n" },
        .{ .name = "opaque-eval-independent-call", .entry = "import*as ns from './dep.mjs';function check(){let marker=3;return[ns.read(),eval('marker')]}console.log(JSON.stringify(check()));", .dep = "export function read(){return 7}", .expected = "[7,3]\n" },
    };
    for (controls) |case| for (profiles) |profile| try run(case, profile);
    std.debug.print("namespace holder hygiene existing controls=6 profiles=4 native=24\n", .{});
}

test "namespace holder hygiene parallel emission keeps owner names and output deterministic" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
    var entry: std.ArrayList(u8) = .empty;
    defer entry.deinit(a);
    var occupied_params: std.ArrayList(u8) = .empty;
    defer occupied_params.deinit(a);
    try occupied_params.appendSlice(a, "dep_ns");
    for (2..41) |suffix| try occupied_params.print(a, ",dep_ns_{d}", .{suffix});
    for (0..40) |i| {
        const dir = try std.fmt.allocPrint(a, "d{d}", .{i});
        defer a.free(dir);
        try tmp.dir.createDirPath(std.testing.io, dir);
        const dep = try std.fmt.allocPrint(a, "{s}/dep.mjs", .{dir});
        defer a.free(dep);
        const source = try std.fmt.allocPrint(a, "export const value={d};", .{i});
        defer a.free(source);
        try helpers.writeFile(tmp.dir, dep, source);
        const consumer = try std.fmt.allocPrint(a, "c{d}.mjs", .{i});
        defer a.free(consumer);
        const consumer_source = try std.fmt.allocPrint(a, "import*as ns from './{s}';export function get({s}){{return Reflect.get(ns,'value')}}", .{ dep, occupied_params.items });
        defer a.free(consumer_source);
        try helpers.writeFile(tmp.dir, consumer, consumer_source);
        try entry.print(a, "import{{get as g{d}}}from'./{s}';", .{ i, consumer });
    }
    try entry.appendSlice(a, "console.log(");
    for (0..40) |i| {
        if (i != 0) try entry.append(a, '+');
        try entry.print(a, "g{d}()", .{i});
    }
    try entry.appendSlice(a, ");");
    try helpers.writeFile(tmp.dir, "entry.mjs", entry.items);
    const input = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(input);
    const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", input } });
    defer a.free(native.stdout);
    defer a.free(native.stderr);
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings("780\n", native.stdout);
    var serial = Bundler.init(a, .{ .entry_points = &.{input}, .format = .cjs, .platform = .node, .max_threads = 1 });
    defer serial.deinit();
    const serial_result = try serial.bundle(std.testing.io);
    defer serial_result.deinit(a);
    try std.testing.expect(!serial_result.hasErrors());
    var parallel = Bundler.init(a, .{ .entry_points = &.{input}, .format = .cjs, .platform = .node, .max_threads = 4 });
    defer parallel.deinit();
    const parallel_result = try parallel.bundle(std.testing.io);
    defer parallel_result.deinit(a);
    try std.testing.expect(!parallel_result.hasErrors());
    try std.testing.expectEqualStrings(serial_result.output, parallel_result.output);
    try helpers.writeFile(tmp.dir, "actual.cjs", parallel_result.output);
    const output = try helpers.absPath(&tmp, "actual.cjs");
    defer a.free(output);
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output } });
    defer a.free(actual.stdout);
    defer a.free(actual.stderr);
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    std.debug.print("namespace holder hygiene parallel owners=40 source_modules=81 jobs=1/4 native=780 byte_equal=true\n", .{});
}

test "namespace holder hygiene cache invalidates body and shared preamble on source reservation change" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "package.json", "{\"type\":\"module\"}");
    try helpers.writeFile(tmp.dir, "dep.mjs", "export const value=7;");
    try helpers.writeFile(tmp.dir, "other.mjs", "import*as localNS from './dep.mjs';export function touch(){return Reflect.get(localNS,'value')}");
    try helpers.writeFile(tmp.dir, "entry.mjs", "import*as core from './dep.mjs';import{touch}from'./other.mjs';console.log(Reflect.get(core,'value')+touch());");
    const input = try helpers.absPath(&tmp, "entry.mjs");
    defer a.free(input);
    var cache = @import("../compiled_cache.zig").CompiledOutputCache.init(a);
    defer cache.deinit();
    var first_output: ?[]u8 = null;
    defer if (first_output) |text| a.free(text);
    var changed_output: ?[]u8 = null;
    defer if (changed_output) |text| a.free(text);
    var initial_key: u64 = 0;
    var changed_key: u64 = 0;
    for (0..4) |pass| {
        if (pass == 2) try helpers.writeFile(tmp.dir, "other.mjs", "import*as localNS from './dep.mjs';export function touch(){const dep_ns={value:9};return Reflect.get(localNS,'value')}");
        var bundler = Bundler.init(a, .{ .entry_points = &.{input}, .format = .cjs, .platform = .node, .compiled_cache = &cache });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(a);
        try std.testing.expect(!result.hasErrors());
        const stats = cache.takeStats();
        switch (pass) {
            0 => {
                first_output = try a.dupe(u8, result.output);
                initial_key = cache.last_options_hash;
            },
            1 => {
                try std.testing.expect(stats.hits >= 2);
                try std.testing.expectEqual(initial_key, cache.last_options_hash);
                try std.testing.expectEqualStrings(first_output.?, result.output);
            },
            2 => {
                changed_output = try a.dupe(u8, result.output);
                changed_key = cache.last_options_hash;
                try std.testing.expect(initial_key != changed_key);
                try std.testing.expect(stats.misses >= 2);
            },
            3 => {
                try std.testing.expect(stats.hits >= 2);
                try std.testing.expectEqual(changed_key, cache.last_options_hash);
                try std.testing.expectEqualStrings(changed_output.?, result.output);
            },
            else => unreachable,
        }
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", input } });
        defer a.free(native.stdout);
        defer a.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("14\n", native.stdout);
        try helpers.writeFile(tmp.dir, "actual.cjs", result.output);
        const output = try helpers.absPath(&tmp, "actual.cjs");
        defer a.free(output);
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output } });
        defer a.free(actual.stdout);
        defer a.free(actual.stderr);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        std.debug.print("namespace holder hygiene compiled-cache pass={d} hits={d} misses={d} key={x} native=14\n", .{ pass, stats.hits, stats.misses, cache.last_options_hash });
    }
}

test "namespace holder hygiene reserves statically visible eval tokens" {
    const case: Case = .{
        .name = "actual-owner-static-eval-reservation",
        .entry = "import*as ns from './dep.mjs';console.log(JSON.stringify([Reflect.get(ns,'value'),eval('typeof @HOLDER@')]));",
        .dep = "export const value=7;",
        .expected = "[7,\"undefined\"]\n",
        .owner_placeholder = true,
    };
    for (profiles) |profile| try run(case, profile);
}

test "quoted ordinary named exports preserve local bindings and provider keys in four profiles" {
    const cases = [_]Case{
        .{ .name = "quoted-literal-backslash", .entry = "import{\"\\\\u0061\" as read}from './dep.mjs';console.log(read.n)", .dep = "const value={n:7};export{value as \"\\\\u0061\"}", .expected = "7\n" },
        .{ .name = "quoted-literal-quotes", .entry = "import{\"\\\"key\\\"\" as read}from './dep.mjs';console.log(read.n)", .dep = "const value={n:7};export{value as \"\\\"key\\\"\"}", .expected = "7\n" },
        .{ .name = "quoted-unicode", .entry = "import{\"한글\" as read}from './dep.mjs';console.log(read.n)", .dep = "const value={n:7};export{value as \"한글\"}", .expected = "7\n" },
        .{ .name = "ordinary-provider-binding", .entry = "import{value as read}from './dep.mjs';console.log(read.n)", .dep = "export const value={n:7}", .expected = "7\n" },
        .{ .name = "quoted-escaped-local", .entry = "import{\"한글\" as read}from './dep.mjs';console.log(read.n)", .dep = "const \\u0076alue={n:7};export{\\u0076alue as \"한글\"}", .expected = "7\n" },
        .{ .name = "quoted-local-collision", .entry = "import{\"한글\" as read}from './dep.mjs';const value=9;console.log(read.n,value)", .dep = "const value={n:7};export{value as \"한글\"}", .expected = "7 9\n" },
    };
    for (cases) |case| for (profiles) |profile| try run(case, profile);
}

test "quoted ordinary aliases of one provider SID share selected consumer binding" {
    const case = Case{
        .name = "quoted-two-aliases-one-SID",
        .entry = "import{\"first-key\" as first,\"second-key\" as second}from './dep.mjs';console.log(first===second,first.n,second.n)",
        .dep = "const value={n:7};export{value as \"first-key\",value as \"second-key\"}",
        .expected = "true 7 7\n",
    };
    for (profiles) |profile| try run(case, profile);
}

test "quoted ordinary provider standalone exposes actual StringValue own keys" {
    const case = Case{
        .name = "quoted-provider-independent-keys",
        .entry = "import{\"\\\\u0061\" as first,\"\\\"key\\\"\" as second,\"한글\" as third}from './dep.mjs';console.log(first.n,second.n,third.n)",
        .dep = "const value={n:7};export{value as \"\\\\u0061\",value as \"\\\"key\\\"\",value as \"한글\"}",
        .expected = "7 7 7\n",
        .provider_probe =
        \\const ns=require(process.argv[1]);const expected=['\\u0061','"key"','한글'];const keys=Reflect.ownKeys(ns);if(expected.some(k=>!keys.includes(k)||Reflect.get(ns,k).n!==7))throw Error('wrong public StringValue');if(keys.some(k=>k!=='value'&&!expected.includes(k)))throw Error('unexpected source-syntax key');console.log('actual keys and values');
        ,
        .provider_expected = "actual keys and values\n",
    };
    for ([_]Profile{ .{}, .{ .minify = true } }) |profile| try run(case, profile);
}

test "quoted ordinary hoisted function provider standalone exposes actual callable own keys" {
    const case = Case{
        .name = "quoted-hoisted-function-independent-keys",
        .entry = "import{\"\\\\u0061\" as first,\"\\\"key\\\"\" as second}from './dep.mjs';console.log(first(),second())",
        .dep = "function value(){return 7}export{value as \"\\\\u0061\",value as \"\\\"key\\\"\"}",
        .expected = "7 7\n",
        .provider_probe =
        \\const ns=require(process.argv[1]);const expected=['\\u0061','"key"'];const keys=Reflect.ownKeys(ns);if(expected.some(k=>!keys.includes(k)||Reflect.get(ns,k)()!==7))throw Error('wrong callable StringValue');if(keys.some(k=>k!=='value'&&!expected.includes(k)))throw Error('unexpected function source-syntax key');console.log('actual callable keys and values');
        ,
        .provider_expected = "actual callable keys and values\n",
    };
    for ([_]Profile{ .{}, .{ .minify = true } }) |profile| try run(case, profile);
}
