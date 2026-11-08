const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");
const compat = @import("../../transformer/transformer.zig").TransformOptions.compat;

test "native module using guards preserve disposal errors source TDZ and named evaluation" {
    const cases = [_]struct { lib: []const u8, entry: []const u8, expected: []const u8 }{
        .{
            .lib = "globalThis.log=[];using a={[Symbol.dispose](){log.push('dispose')}};export const value=42;",
            .entry = "import{value}from './lib.mjs';console.log(JSON.stringify([value,...log]));",
            .expected = "[42,\"dispose\"]\n",
        },
        .{
            .lib = "globalThis.log=[];using resource=class{static[Symbol.dispose](){log.push(this.name)}};export const value=resource.name;",
            .entry = "import{value}from './lib.mjs';console.log(JSON.stringify([value,...log]));",
            .expected = "[\"resource\",\"resource\"]\n",
        },
        .{
            .lib = "globalThis.log=[];using __proto__=class{static[Symbol.dispose](){log.push(this.name)}};export const value=__proto__.name;",
            .entry = "import{value}from './lib.mjs';console.log(JSON.stringify([value,...log]));",
            .expected = "[\"__proto__\",\"__proto__\"]\n",
        },
        .{
            .lib = "globalThis.log=[];using \\u0072=class{static[Symbol.dispose](){log.push(this.name)}};export const value=r.name;",
            .entry = "import{value}from './lib.mjs';console.log(JSON.stringify([value,...log]));",
            .expected = "[\"r\",\"r\"]\n",
        },
        .{
            .lib = "const D=Symbol.dispose;globalThis.log=[];globalThis.Symbol={dispose:'other'};using resource={[D](){log.push('dispose')}};export const value=42;",
            .entry = "import{value}from './lib.mjs';console.log(JSON.stringify([value,...log]));",
            .expected = "[42,\"dispose\"]\n",
        },
        .{
            .lib = "globalThis.log=[];function dispose(){log.push('dispose')}dispose.call=function(){log.push('own-call')};using resource={[Symbol.dispose]:dispose};export const value=42;",
            .entry = "import{value}from './lib.mjs';console.log(JSON.stringify([value,...log]));",
            .expected = "[42,\"dispose\"]\n",
        },
        .{
            .lib = "globalThis.log='';const P=Array.prototype.push,Q=Array.prototype.pop;Array.prototype.push=Array.prototype.pop=function(){throw 'array-trap'};using resource={[Symbol.dispose](){Array.prototype.push=P;Array.prototype.pop=Q;globalThis.log+='dispose'}};export const value=42;",
            .entry = "import{value}from './lib.mjs';console.log(JSON.stringify([value,log]));",
            .expected = "[42,\"dispose\"]\n",
        },
        .{
            .lib = "globalThis.log=[];using resource={get[Symbol.dispose](){try{resource}catch(e){log.push(e.name)}return function(){log.push('dispose')}}};export const value=42;",
            .entry = "import{value}from './lib.mjs';console.log(JSON.stringify([value,...log]));",
            .expected = "[42,\"ReferenceError\",\"dispose\"]\n",
        },
    };
    for (cases, 0..) |case, index| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "lib.mjs", case.lib);
        try helpers.writeFile(tmp.dir, "entry.mjs", case.entry);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        var bundler = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .format = .iife,
            .platform = .node,
            .unsupported = compat.fromESTarget(.esnext),
            .minify_syntax = minify,
            .minify_identifiers = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        if (result.hasErrors()) std.debug.print("native module using case={d} minify={} diagnostics={any}\n", .{ index, minify, result.diagnostics });
        try std.testing.expect(!result.hasErrors());
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, case.expected, actual.stdout)) std.debug.print("native module using case={d} minify={} stderr={s} output={s}\n", .{ index, minify, actual.stderr, result.output });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, actual.stdout);
    };
}

test "native module using guard runtime captures once drains once and preserves suppression shape" {
    const runtime = @import("../runtime_helpers.zig");
    const source = runtime.USING_RUNTIME ++
        "let count=0;let disposed=0;let g=__using([],{get[Symbol.dispose](){count++;return function(){disposed++}}},false,true);g[Symbol.dispose]();g[Symbol.dispose]();console.log(count,disposed);" ++
        "try{using a=__using([],{[Symbol.dispose](){throw 'A'}},false,true);using b=__using([],{[Symbol.dispose](){throw 'B'}},false,true);throw 'E'}catch(e){console.log(e.error,e.suppressed.error,e.suppressed.suppressed)}";
    const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    defer std.testing.allocator.free(actual.stdout);
    defer std.testing.allocator.free(actual.stderr);
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings("1 1\nA B E\n", actual.stdout);
}

test "native module using guard mode does not require Symbol for legacy null acquisition" {
    const runtime = @import("../runtime_helpers.zig");
    const source = "globalThis.Symbol=void 0;" ++ runtime.USING_RUNTIME ++ "console.log(__using([],null,false));";
    const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", source } });
    defer std.testing.allocator.free(actual.stdout);
    defer std.testing.allocator.free(actual.stderr);
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings("null\n", actual.stdout);
}

test "native module using mixed await exports wait for disposal in single output and native PM" {
    for ([_]bool{ false, true }) |preserve| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "lib.mjs", "using resource={label:'pending',[Symbol.dispose](){}};await using other={async[Symbol.asyncDispose](){await 0;resource.label='completed'}};export{resource};");
        try helpers.writeFile(tmp.dir, "main.mjs", "const{resource}=await import('./lib.mjs');console.log(resource.label);");
        const entry = try helpers.absPath(&tmp, "main.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", entry } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("completed\n", native.stdout);
        try std.testing.expectEqualStrings("", native.stderr);
        var bundler = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .platform = .node,
            .format = .esm,
            .inline_dynamic_imports = !preserve,
            .preserve_modules = preserve,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .out_extension_js = ".mjs",
            .unsupported = compat.fromESTarget(.esnext),
            .minify_syntax = minify,
            .minify_identifiers = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        if (preserve) {
            const outputs = result.outputs orelse return error.TestUnexpectedResult;
            for (outputs) |file| {
                const path = try std.fs.path.join(std.testing.allocator, &.{ "dist", file.path });
                defer std.testing.allocator.free(path);
                try helpers.writeFile(tmp.dir, path, file.contents);
            }
        } else try helpers.writeFile(tmp.dir, "dist/main.mjs", result.output);
        const output = try helpers.absPath(&tmp, "dist/main.mjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        if (actual.term != .exited or actual.term.exited != 0) std.debug.print("native module using mixed export minify={} stderr={s} code={s}\n", .{ minify, actual.stderr, result.output });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("completed\n", actual.stdout);
    };
}

test "native module CJS TLA temps keep actual prefix and wrapped pattern owners" {
    const sources = [_][]const u8{
        "const{resource}=await import('./lib.mjs');console.log(resource);",
        "const before=globalThis.missing?.value??7;const{resource}=await import('./lib.mjs');console.log(JSON.stringify([before,resource]));",
        "function source(x){return x?.value??5}const{resource}=await import('./lib.mjs');console.log(JSON.stringify([source(null),resource]));",
        "const[value=42,...rest]=await Promise.resolve([undefined,7]);console.log(JSON.stringify([value,rest]));",
    };
    for (sources) |source| for ([_]compat.ESTarget{ .esnext, .es5 }) |target| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "lib.mjs", "export const resource=42;");
        try helpers.writeFile(tmp.dir, "main.mjs", source);
        const entry = try helpers.absPath(&tmp, "main.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", entry } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        var bundler = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .platform = .node,
            .format = .cjs,
            .unsupported = compat.fromESTarget(target),
            .keep_names = true,
            .minify_syntax = minify,
            .minify_identifiers = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        try std.testing.expect(!result.hasErrors());
        try helpers.writeFile(tmp.dir, "output.cjs", result.output);
        const output = try helpers.absPath(&tmp, "output.cjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        try std.testing.expectEqualStrings(native.stderr, actual.stderr);
    };
}
