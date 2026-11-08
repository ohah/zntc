const std = @import("std");

test "lazy iterator Reference private brand primordial and builtin roles preserve source values" {
    const Case = struct { name: []const u8, source: []const u8, expected: []const u8, prelude: []const u8, target: @import("compat.zig").ESTarget };
    const cases = [_]Case{
        .{ .name = "has-after-load", .source = "const saved=WeakMap.prototype.has;class C{#value=1;write(other=this){other.#value=42;return this.#value}}try{WeakMap.prototype.has=()=>false;console.log(new C().write())}finally{WeakMap.prototype.has=saved}", .expected = "42\n", .prelude = "", .target = .es5 },
        .{ .name = "has-own-call", .source = "const has=WeakMap.prototype.has,old=Object.getOwnPropertyDescriptor(has,'call');class C{#value=1;write(other=this){other.#value=42;return this.#value}}try{Object.defineProperty(has,'call',{configurable:true,value:()=>false});console.log(new C().write())}finally{if(old)Object.defineProperty(has,'call',old);else delete has.call}", .expected = "42\n", .prelude = "", .target = .es5 },
        .{ .name = "source-weak-map-alias", .source = "const WeakMap=globalThis.WeakMap;class C{#value=1;write(other=this){other.#value=42;return this.#value}}console.log(new C().write(),WeakMap===globalThis.WeakMap)", .expected = "42 true\n", .prelude = "", .target = .es5 },
        .{ .name = "escaped-weak-map-alias", .source = "const \\u0057eakMap=globalThis.WeakMap;class C{#value=1;write(other=this){other.#value=42;return this.#value}}console.log(new C().write(),WeakMap===globalThis.WeakMap)", .expected = "42 true\n", .prelude = "", .target = .es5 },
        .{ .name = "source-function-name", .source = "const calls=[];function WeakMap(){calls.push('source-constructor');return new globalThis.WeakMap()}class C{#value=1;write(other=this){other.#value=42;return this.#value}}console.log(JSON.stringify([new C().write(),WeakMap.name,calls]))", .expected = "[42,\"WeakMap\",[]]\n", .prelude = "", .target = .es5 },
        .{ .name = "dynamic-alias-es5", .source = "const WeakMap=globalThis.WeakMap;class C{#value=1;write(other=this){other.#value=42;return this.#value}}console.log(new C().write(),eval('WeakMap===globalThis.WeakMap'))", .expected = "42 true\n", .prelude = "", .target = .es5 },
        .{ .name = "host-absent-unused", .source = "function unused(){class C{#value=1;write(){this.#value=42}}}console.log('ok')", .expected = "ok\n", .prelude = "globalThis.WeakMap=void 0;", .target = .es5 },
        .{ .name = "source-type-error", .source = "const TypeError=()=>{throw 'source TypeError'};class C{#value=1;write(other=this){other.#value=42;return this.#value}}try{new C().write({})}catch(error){console.log(error.name)}", .expected = "TypeError\n", .prelude = "", .target = .es5 },
        .{ .name = "read-only-no-set-demand", .source = "const WeakMap=globalThis.WeakMap;class C{#value=42;read(){return this.#value}}console.log(new C().read(),WeakMap===globalThis.WeakMap)", .expected = "42 true\n", .prelude = "", .target = .es5 },
    };
    var failures: usize = 0;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native_source = try std.fmt.allocPrint(allocator, "{s}{s}", .{ case.prelude, case.source });
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native_source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        for ([_]bool{ false, true }) |minify| {
            const result = @import("../transpile.zig").transpile(allocator, case.source, "private-primordial.mjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(case.target),
                .keep_names = true,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            }) catch |err| {
                std.debug.print("Reference result case={s} minify={} pass=false transform_error={s}\n", .{ case.name, minify, @errorName(err) });
                failures += 1;
                continue;
            };
            const actual_source = try std.fmt.allocPrint(allocator, "{s}{s}", .{ case.prelude, result.code });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", actual_source } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("Reference consumer={s} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ case.name, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            const passed = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, native.stdout, actual.stdout);
            std.debug.print("Reference result case={s} minify={} pass={}\n", .{ case.name, minify, passed });
            if (!passed) failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "private WeakMap dynamic constructor preserves the prior intrinsic admission boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Original Native value remains valid. The old sealed 2fb compiler and
    // current compiler both reject the unrelated modern dynamic constructor
    // alias; this is a diagnostic control, not a successful value comparison.
    const source = "const WeakMap=globalThis.WeakMap;class C{#value=1;write(other=this){other.#value=42;return this.#value}}console.log(new C().write(),eval('WeakMap===globalThis.WeakMap'))";
    const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", source } });
    try std.testing.expect(native.term == .exited and native.term.exited == 0);
    try std.testing.expectEqualStrings("42 true\n", native.stdout);
    for ([_]bool{ false, true }) |minify| {
        try std.testing.expectError(error.TransformError, @import("../transpile.zig").transpile(allocator, source, "private-primordial.mjs", .{
            .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es2015),
            .keep_names = true,
            .minify_identifiers = minify,
            .minify_syntax = minify,
            .minify_whitespace = minify,
        }));
        std.debug.print("Reference preserved boundary case=dynamic-alias-es2015 minify={} diagnostic=TransformError matched=true\n", .{minify});
    }
}
