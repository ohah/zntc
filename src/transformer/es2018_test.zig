const std = @import("std");
const transpile = @import("../transpile.zig");
const compat = @import("compat.zig");

test "object spread finishes earlier copies before evaluating later values" {
    const sources = [_][]const u8{
        "var events=[];var source={};Object.defineProperty(source,'left',{enumerable:true,get:function(){events.push('get');return 20}});async function run(){return {...source,right:await(events.push('rhs'),Promise.resolve(22))}}run().then(function(value){console.log(JSON.stringify([value,events]))});",
        "var events=[];var source={};Object.defineProperty(source,'left',{enumerable:true,get:function(){events.push('get');return 20}});function next(){events.push('next');return {right:22}}console.log(JSON.stringify([{...source,...next()},events]));",
        "var events=[];var result={...{get left(){events.push('get');return 42}}};var descriptor=Object.getOwnPropertyDescriptor(result,'left');console.log(JSON.stringify([descriptor.value,typeof descriptor.get,events]));",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const expected = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        try std.testing.expectEqualStrings("", expected.stderr);
        for ([_]compat.ESTarget{ .es5, .es2015, .es2017 }) |target| {
            for ([_]bool{ false, true }) |full| {
                const result = try transpile.transpile(a, source, "spread-order.cjs", .{
                    .unsupported = compat.fromESTarget(target),
                    .minify_identifiers = full,
                    .minify_syntax = full,
                    .minify_whitespace = full,
                });
                const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
                errdefer std.debug.print("spread order target={s} minify={} code={s} expected={s} actual={s} stderr={s}\n", .{ @tagName(target), full, result.code, expected.stdout, actual.stdout, actual.stderr });
                try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
                try std.testing.expectEqualStrings("", actual.stderr);
                try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
            }
        }
    }
}
