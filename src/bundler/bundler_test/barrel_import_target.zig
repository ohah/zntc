//! Plain imported aliases use the exact emitted import local for their SID.
const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");
const Case = struct { name: []const u8, entry: []const u8, dep: []const u8, expected: []const u8, lazy: ?[]const u8 = null, barrel: ?[]const u8 = null };
const Format = @import("../types.zig").Format;
const Profile = struct { format: Format = .cjs, preserve: bool = true, split: bool = false, minify: bool = false };
fn run(case: Case, profile: Profile) !void {
    errdefer std.debug.print("PM barrel import target case={s} format={s} preserve={any} split={any} minify={any}\n", .{ case.name, @tagName(profile.format), profile.preserve, profile.split, profile.minify });
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
    if (!(actual.term == .exited and actual.term.exited == 0)) std.debug.print("PM barrel import target actual runtime error:\n{s}\n", .{actual.stderr});
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings(native.stdout, actual.stdout);
}
const candidates = [_]Case{
    .{ .name = "direct-default", .dep = "export default class 이름{read(){return 7}}", .barrel = "export{default}from\"./dep.mjs\";", .entry = "import Read from\"./barrel.mjs\";console.log(new Read().read());", .expected = "7\n" },
    .{ .name = "named-to-default", .dep = "export class 이름{read(){return 7}}", .barrel = "export{이름 as default}from\"./dep.mjs\";", .entry = "import Read from\"./barrel.mjs\";console.log(new Read().read());", .expected = "7\n" },
    .{ .name = "local-import-default-expression", .dep = "export default class 이름{read(){return 7}}", .barrel = "import Local from\"./dep.mjs\";export default Local;", .entry = "import Read from\"./barrel.mjs\";console.log(new Read().read());", .expected = "7\n" },
    .{ .name = "local-import-export-specifier", .dep = "export default class 이름{read(){return 7}}", .barrel = "import Local from\"./dep.mjs\";export{Local as default};", .entry = "import Read from\"./barrel.mjs\";console.log(new Read().read());", .expected = "7\n" },
    .{ .name = "default-to-named-alias", .dep = "export default class 이름{read(){return 7}}", .barrel = "export{default as Public}from\"./dep.mjs\";", .entry = "import{Public as Read}from\"./barrel.mjs\";console.log(new Read().read());", .expected = "7\n" },
    .{ .name = "default-function", .dep = "export default function 읽기(){return 7}", .barrel = "export{default}from\"./dep.mjs\";", .entry = "import read from\"./barrel.mjs\";console.log(read());", .expected = "7\n" },
    .{ .name = "anonymous-default-function", .dep = "export default function(){return 7}", .barrel = "export{default}from\"./dep.mjs\";", .entry = "import read from\"./barrel.mjs\";console.log(read());", .expected = "7\n" },
    .{ .name = "default-object", .dep = "const 데이터={read:7};export default 데이터;", .barrel = "export{default}from\"./dep.mjs\";", .entry = "import value from\"./barrel.mjs\";console.log(value.read);", .expected = "7\n" },
    .{ .name = "named-function-default", .dep = "export function 읽기(){return 7}", .barrel = "export{읽기 as default}from\"./dep.mjs\";", .entry = "import read from\"./barrel.mjs\";console.log(read());", .expected = "7\n" },
    .{ .name = "ASCII-default-class", .dep = "export default class Provider{read(){return 7}}", .barrel = "export{default}from\"./dep.mjs\";", .entry = "import Read from\"./barrel.mjs\";console.log(new Read().read());", .expected = "7\n" },
};
test "PM barrel import target RED 0 direct-default" {
    try run(candidates[0], .{ .minify = true });
}
test "PM barrel import target RED 1 named-to-default" {
    try run(candidates[1], .{ .minify = true });
}
test "PM barrel import target RED 2 local-import-default-expression" {
    try run(candidates[2], .{ .minify = true });
}
test "PM barrel import target RED 3 local-import-export-specifier" {
    try run(candidates[3], .{ .minify = true });
}
test "PM barrel import target RED 4 default-to-named-alias" {
    try run(candidates[4], .{ .minify = true });
}
test "PM barrel import target RED 5 default-function" {
    try run(candidates[5], .{ .minify = true });
}
test "PM barrel import target RED 6 anonymous-default-function" {
    try run(candidates[6], .{ .minify = true });
}
test "PM barrel import target RED 7 default-object" {
    try run(candidates[7], .{ .minify = true });
}
test "PM barrel import target RED 8 named-function-default" {
    try run(candidates[8], .{ .minify = true });
}
test "PM barrel import target RED 9 ASCII-default-class" {
    try run(candidates[9], .{ .minify = true });
}
test "PM barrel import target normal controls" {
    for (candidates) |case| {
        try run(case, .{});
        try run(case, .{ .preserve = false });
    }
}
