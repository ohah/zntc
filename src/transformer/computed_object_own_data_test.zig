const std = @import("std");
const helpers = @import("../bundler/test_helpers.zig");
const bundler = @import("../bundler/bundler.zig");
const compat = @import("compat.zig");

const cases = [_][]const u8{
    "var events=[];Object.defineProperty(Object.prototype,'after',{set:function(v){events.push('setter:'+v)},configurable:true});var key='first';var object={[key]:1,after:2};console.log(Object.prototype.hasOwnProperty.call(object,'after'),object.after,events.join(','));delete Object.prototype.after;",
    "Object.defineProperty(Object.prototype,'after',{value:9,writable:false,configurable:true});var key='first';var object={[key]:1,after:2};console.log(Object.prototype.hasOwnProperty.call(object,'after'),object.after);delete Object.prototype.after;",
    "var events=[];Object.defineProperty(Object.prototype,'after',{get:function(){events.push('get');return 9},configurable:true});var key='first';var object={[key]:1,after:2};console.log(Object.prototype.hasOwnProperty.call(object,'after'),object.after,events.join(','));delete Object.prototype.after;",
    "var events=[];var key='first';var object={get after(){events.push('get');return 9},[key]:1,after:2};console.log(Object.getOwnPropertyDescriptor(object,'after').value,object.after,events.join(','));",
    "var events=[];Object.defineProperty(Object.prototype,'1000',{set:function(v){events.push(v)},configurable:true});var key='first';var object={[key]:1,1e3:2};console.log(Object.prototype.hasOwnProperty.call(object,'1000'),object[1000],events.length);delete Object.prototype[1000];",
    "var events=[];Object.defineProperty(Object.prototype,'after',{set:function(v){events.push(v)},configurable:true});var key='first';var object={[key]:1,'a\\u0066ter':2};console.log(Object.prototype.hasOwnProperty.call(object,'after'),object.after,events.length);delete Object.prototype.after;",
    "var events=[];Object.defineProperty(Object.prototype,'after',{set:function(v){events.push(v)},configurable:true});var key='first',after=2;var object={[key]:1,after};console.log(Object.prototype.hasOwnProperty.call(object,'after'),object.after,events.length);delete Object.prototype.after;",
    "var key='first';var object={[key]:1,__proto__(){return 7}};console.log(Object.prototype.hasOwnProperty.call(object,'__proto__'),object.__proto__(),Object.getPrototypeOf(object)===Object.prototype);",
    "var key='first',__proto__=7;var object={[key]:1,__proto__};console.log(Object.prototype.hasOwnProperty.call(object,'__proto__'),object.__proto__,Object.getPrototypeOf(object)===Object.prototype);",
    "var key='first',proto={inherited:7};var object={[key]:1,__proto__:proto,last:2};console.log(Object.prototype.hasOwnProperty.call(object,'__proto__'),Object.getPrototypeOf(object)===proto,object.inherited,object.last);",
    "var key='__proto__';var object={[key]:7,last:2};console.log(Object.prototype.hasOwnProperty.call(object,'__proto__'),object.__proto__,Object.getPrototypeOf(object)===Object.prototype);",
    "var object={__proto__(){return 7}};console.log(Object.prototype.hasOwnProperty.call(object,'__proto__'),object.__proto__(),Object.getPrototypeOf(object)===Object.prototype);",
    "var __proto__=7;var object={__proto__};console.log(Object.prototype.hasOwnProperty.call(object,'__proto__'),object.__proto__,Object.getPrototypeOf(object)===Object.prototype);",
    "var __proto__=7;var object={method(){return 1},__proto__};console.log(object.method(),Object.prototype.hasOwnProperty.call(object,'__proto__'),object.__proto__,Object.getPrototypeOf(object)===Object.prototype);",
    "var __proto__=7;var object={__pro\\u0074o__};console.log(Object.prototype.hasOwnProperty.call(object,'__proto__'),object.__proto__,Object.getPrototypeOf(object)===Object.prototype);",
};

test "computed object own data properties preserve setter descriptor and proto roles" {
    for (cases, 0..) |source, index| {
        for ([_]compat.ESTarget{ .es5, .es2015 }) |target| {
            for ([_]bool{ false, true }) |minify| {
                var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                var tmp = std.testing.tmpDir(.{});
                defer tmp.cleanup();
                try helpers.writeFile(tmp.dir, "entry.mjs", source);
                const entry = try helpers.absPath(&tmp, "entry.mjs");
                defer std.testing.allocator.free(entry);
                const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", entry } });
                try std.testing.expect(native.term == .exited and native.term.exited == 0);
                var b = bundler.Bundler.init(std.testing.allocator, .{
                    .entry_points = &.{entry},
                    .platform = .node,
                    .format = .cjs,
                    .unsupported = compat.fromESTarget(target),
                    .minify_identifiers = minify,
                });
                defer b.deinit();
                const result = try b.bundle(std.testing.io);
                defer result.deinit(std.testing.allocator);
                try std.testing.expect(!result.hasErrors());
                if (target == .es5) {
                    var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, result.output);
                    var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
                    parser.configureFromExtension(".cjs");
                    _ = try parser.parse();
                    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
                    for (parser.ast.nodes.items) |node| try std.testing.expect(node.tag != .computed_property_key);
                }

                try helpers.writeFile(tmp.dir, "output.cjs", result.output);
                const output = try helpers.absPath(&tmp, "output.cjs");
                defer std.testing.allocator.free(output);
                const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", output } });
                if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                    std.debug.print("computed own property case={d} target={s} minify={any}\nnative={s}\nactual={s}\nstderr={s}\n{s}\n", .{ index, @tagName(target), minify, native.stdout, actual.stdout, actual.stderr, result.output });
                try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
                try std.testing.expectEqualStrings(native.stdout, actual.stdout);
            }
        }
    }
}

test "computed object own data key roles decode identifiers once and return owned names" {
    const KeyCase = struct { source: []const u8, expected: ?[]const u8 };
    const inputs = [_]KeyCase{
        .{ .source = "var object={__proto__:1}", .expected = "__proto__" },
        .{ .source = "var object={__pro\\u0074o__:1}", .expected = "__proto__" },
        .{ .source = "var object={\"__pro\\u0074o__\":1}", .expected = "__proto__" },
        .{ .source = "var object={\"__pro\\\\u0074o__\":1}", .expected = "__pro\\u0074o__" },
        .{ .source = "var object={[\"__proto__\"]:1}", .expected = null },
    };
    for (inputs) |input| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, input.source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".mjs");
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var checked: usize = 0;
        for (parser.ast.nodes.items) |node| {
            if (node.tag != .object_property) continue;
            const name = try parser.ast.directStaticKeyName(std.testing.allocator, node.data.binary.left);
            defer if (name) |value| std.testing.allocator.free(value);
            if (input.expected) |expected| {
                try std.testing.expect(name != null);
                try std.testing.expectEqualStrings(expected, name.?);
            } else try std.testing.expect(name == null);
            checked += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), checked);
    }
}
