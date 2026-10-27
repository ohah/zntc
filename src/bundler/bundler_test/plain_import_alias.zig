//! Plain imported aliases use the exact emitted import local for their SID.
const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");
const fixtures = @import("plain_import_alias_fixtures.zig");
const Format = @import("../types.zig").Format;
const Profile = struct { format: Format = .cjs, preserve: bool = true, split: bool = false, minify: bool = false };
fn run(case: fixtures.Case, profile: Profile) !void {
    errdefer std.debug.print("PM plain import alias case={s} format={s} preserve={any} split={any} minify={any}\n", .{ case.name, @tagName(profile.format), profile.preserve, profile.split, profile.minify });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "package.json", if (profile.format == .esm) "{\"type\":\"module\"}" else "{\"type\":\"commonjs\"}");
    try helpers.writeFile(tmp.dir, "entry.mjs", case.entry);
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
    var bundler = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .format = profile.format, .platform = .node, .preserve_modules = profile.preserve, .code_splitting = profile.split, .minify_identifiers = profile.minify });
    defer bundler.deinit();
    const result = try bundler.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!result.hasErrors());
    if (result.outputs) |outputs| {
        for (outputs) |output| try helpers.writeFile(tmp.dir, std.fs.path.basename(output.path), output.contents);
    } else try helpers.writeFile(tmp.dir, "entry.js", result.output);
    const emitted = try helpers.absPath(&tmp, "entry.js");
    defer std.testing.allocator.free(emitted);
    const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", emitted } });
    defer std.testing.allocator.free(actual.stdout);
    defer std.testing.allocator.free(actual.stderr);
    if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("PM plain import alias actual runtime error:\n{s}\n", .{actual.stderr});
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
}
test "PM plain import alias RED 0 original-full-async" {
    try run(fixtures.candidates[0], .{});
}
test "PM plain import alias RED 1 direct-default-class" {
    try run(fixtures.candidates[1], .{});
}
test "PM plain import alias RED 2 direct-default-function" {
    try run(fixtures.candidates[2], .{});
}
test "PM plain import alias RED 3 parenthesized-new" {
    try run(fixtures.candidates[3], .{});
}
test "PM plain import alias RED 4 closure-new" {
    try run(fixtures.candidates[4], .{});
}
test "PM plain import alias RED 5 class-heritage" {
    try run(fixtures.candidates[5], .{});
}
test "PM plain import alias RED 6 named-unicode-class" {
    try run(fixtures.candidates[6], .{});
}
test "PM plain import alias RED 7 reexport-default" {
    try run(fixtures.candidates[7], .{});
}
test "PM plain import alias RED 8 named-object-value" {
    try run(fixtures.candidates[8], .{});
}
test "PM plain import alias RED 9 tagged-template" {
    try run(fixtures.candidates[9], .{});
}

test "PM plain import alias ASCII same-name and shadow controls" {
    for (fixtures.controls) |case| for ([_]Profile{ .{}, .{ .minify = true }, .{ .preserve = false }, .{ .preserve = false, .split = true, .format = .esm } }) |profile| try run(case, profile);
    std.debug.print("PM plain import alias native-controls=4 profiles=4 total=16\n", .{});
}

test "PM plain import alias escaped binding and Unicode live import controls" {
    for (fixtures.property_source_controls) |case| for ([_]Profile{ .{}, .{ .minify = true } }) |profile| try run(case, profile);
    std.debug.print("PM plain import alias escaped/live source-controls=2 profiles=2 native=4\n", .{});
}
