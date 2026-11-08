const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");
const compat = @import("../../transformer/transformer.zig").TransformOptions.compat;

// The oracle evaluates separate native modules, including their async disposal
// jobs. Comparing only the bundle's final eventual log misses the boundary.
test "native await using single output preserves jobs live exports errors and cycles" {
    try runNativeAsyncBoundary(false);
}

test "preserved native await using modules preserve jobs live exports errors and cycles" {
    try runNativeAsyncBoundary(true);
}

fn runNativeAsyncBoundary(preserve: bool) !void {
    const shared = "export const events=[];";
    const cases = [_]struct {
        name: []const u8,
        lib: []const u8,
        entry: []const u8,
        peer: []const u8 = "export {};",
        consumer: ?[]const u8 = null,
    }{
        .{
            .name = "original static dependency",
            .lib = "import{events}from './log.mjs';await using r={async[Symbol.asyncDispose](){events.push('dispose-start');await Promise.resolve();events.push('dispose-end')}};events.push('body');export const answer=42;",
            .entry = "import{events}from './log.mjs';import{answer}from './lib.mjs';events.push('entry');console.log(JSON.stringify([answer,events]));",
        },
        .{
            .name = "async LIFO",
            .lib = "import{events}from './log.mjs';const r=n=>({async[Symbol.asyncDispose](){events.push(n+':start');await 0;events.push(n+':end')}});await using a=r('a');await using b=r('b');events.push('body');export const answer=42;",
            .entry = "import{events}from './log.mjs';import{answer}from './lib.mjs';events.push('entry');console.log(JSON.stringify([answer,events]));",
        },
        .{
            .name = "null async hint and microtasks",
            .lib = "import{events}from './log.mjs';let n=0;function tick(){events.push('tick:'+n);if(++n<8)queueMicrotask(tick)}queueMicrotask(tick);await using r=null;events.push('body');export const answer=42;",
            .entry = "import{events}from './log.mjs';import{answer}from './lib.mjs';events.push('entry');console.log(JSON.stringify([answer,events]));",
        },
        .{
            .name = "body error and two throwing disposers",
            .lib = "import{events}from './log.mjs';const r=n=>({async[Symbol.asyncDispose](){events.push(n);await 0;throw n}});await using a=r('a');await using b=r('b');throw 'body';",
            .entry = "import{events}from './log.mjs';const shape=e=>e instanceof SuppressedError?[shape(e.error),shape(e.suppressed)]:e;try{await import('./lib.mjs')}catch(e){console.log(JSON.stringify([shape(e),events]))}",
        },
        .{
            .name = "acquisition failure disposes prior resource",
            .lib = "import{events}from './log.mjs';await using a={async[Symbol.asyncDispose](){events.push('dispose-start');await 0;events.push('dispose-end')}};await using b={get[Symbol.asyncDispose](){events.push('getter');throw 'acquire'}};",
            .entry = "import{events}from './log.mjs';try{await import('./lib.mjs')}catch(e){events.push(e);console.log(JSON.stringify(events))}",
        },
        .{
            .name = "mixed exported resource",
            .lib = "import{events}from './log.mjs';using resource={label:'ok',[Symbol.dispose](){events.push('sync')}};await using other={async[Symbol.asyncDispose](){events.push('async-start');await 0;events.push('async-end')}};export{resource};",
            .entry = "import{events}from './log.mjs';const{resource}=await import('./lib.mjs');events.push('entry');console.log(JSON.stringify([resource.label,events]));",
        },
        .{
            .name = "own const and class TDZ",
            .lib = "import{events}from './log.mjs';function read(){return [value,Named]}for(const get of [()=>value,()=>Named]){try{get()}catch(e){events.push(e.name)}}await using r={async[Symbol.asyncDispose](){await 0;events.push(read()[0])}};const value=42;class Named{}export{read};",
            .entry = "import{events}from './log.mjs';import{read}from './lib.mjs';console.log(JSON.stringify([read()[0],events]));",
        },
        .{
            .name = "cycle hoisted function and source TDZ",
            .lib = "import{events}from './log.mjs';import{probe}from './peer.mjs';export function read(){return answer}events.push(probe());await using r={async[Symbol.asyncDispose](){await 0;events.push('dispose')}};export const answer=42;",
            .peer = "import{read}from './lib.mjs';export function probe(){try{return read()}catch(e){return e.name}}",
            .entry = "import{events}from './log.mjs';import{answer}from './lib.mjs';console.log(JSON.stringify([answer,events]));",
        },
        .{
            .name = "external ESM live binding and default snapshot",
            .lib = "await using r={async[Symbol.asyncDispose](){await 0}};export let value=1;export default value;export function advance(){value++}",
            .entry = "export{default,value,advance}from './lib.mjs';",
            .consumer = "import initial,*as ns from './ENTRY';ns.advance();const first=ns.value;ns.advance();console.log(JSON.stringify([initial,first,ns.value]));",
        },
        .{
            .name = "ordinary await before native disposal",
            .lib = "import{events}from './log.mjs';await using r={async[Symbol.asyncDispose](){events.push('dispose-start');await 0;events.push('dispose-end')}};events.push('body');await 0;events.push('resumed');export const answer=42;",
            .entry = "import{events}from './log.mjs';import{answer}from './lib.mjs';events.push('entry');console.log(JSON.stringify([answer,events]));",
        },
    };
    for (cases) |case| for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "log.mjs", shared);
        try helpers.writeFile(tmp.dir, "lib.mjs", case.lib);
        try helpers.writeFile(tmp.dir, "peer.mjs", case.peer);
        try helpers.writeFile(tmp.dir, "entry.mjs", case.entry);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native_entry = if (case.consumer) |consumer| blk: {
            const text = try std.mem.replaceOwned(u8, std.testing.allocator, consumer, "ENTRY", "entry.mjs");
            defer std.testing.allocator.free(text);
            try helpers.writeFile(tmp.dir, "native-consumer.mjs", text);
            break :blk try helpers.absPath(&tmp, "native-consumer.mjs");
        } else try std.testing.allocator.dupe(u8, entry);
        defer std.testing.allocator.free(native_entry);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", native_entry } });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        if (native.term != .exited or native.term.exited != 0) std.debug.print("native await using oracle {s}: {s}\n", .{ case.name, native.stderr });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expect(native.stdout.len > 0);
        var bundler = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .format = .esm,
            .platform = .node,
            .unsupported = compat.fromESTarget(.esnext),
            .keep_names = true,
            // Explicit mode: never treat this as a single-output repair.
            .preserve_modules = preserve,
            .preserve_modules_root = std.fs.path.dirname(entry),
            .out_extension_js = ".mjs",
            .minify_syntax = minify,
            .minify_identifiers = minify,
            .minify_whitespace = minify,
        });
        defer bundler.deinit();
        const result = try bundler.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);
        if (result.hasErrors()) std.debug.print("native await using {s} preserve={} minify={} diagnostics={any}\n", .{ case.name, preserve, minify, result.diagnostics });
        try std.testing.expect(!result.hasErrors());
        if (preserve) {
            const outputs = result.outputs orelse return error.TestUnexpectedResult;
            try std.testing.expect(outputs.len >= 2);
            for (outputs) |file| {
                const path = try std.fs.path.join(std.testing.allocator, &.{ "dist", file.path });
                defer std.testing.allocator.free(path);
                try helpers.writeFile(tmp.dir, path, file.contents);
            }
        } else try helpers.writeFile(tmp.dir, "output.mjs", result.output);
        const output = if (case.consumer) |consumer| blk: {
            const text = try std.mem.replaceOwned(u8, std.testing.allocator, consumer, "ENTRY", if (preserve) "dist/entry.mjs" else "output.mjs");
            defer std.testing.allocator.free(text);
            try helpers.writeFile(tmp.dir, "output-consumer.mjs", text);
            break :blk try helpers.absPath(&tmp, "output-consumer.mjs");
        } else try helpers.absPath(&tmp, if (preserve) "dist/entry.mjs" else "output.mjs");
        defer std.testing.allocator.free(output);
        const actual = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", output } });
        defer std.testing.allocator.free(actual.stdout);
        defer std.testing.allocator.free(actual.stderr);
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("native await using {s} preserve={} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ case.name, preserve, minify, native.stdout, actual.stdout, actual.stderr, result.output });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        try std.testing.expectEqualStrings(native.stderr, actual.stderr);
    };
}
