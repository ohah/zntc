//! Node discovers CJS names statically, then snapshots each imported value.
//! require() retains the same live getter; these are deliberately different
//! boundaries from a native ESM namespace's live binding semantics.
const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const helpers = @import("../test_helpers.zig");
const compat = @import("../../transformer/compat.zig");

test "public entry CJS native namespace discovers ten source key shapes without changing live descriptors" {
    const cases = [_]struct { key: []const u8, syntax: []const u8, direct: bool = false, shadow: bool = false }{
        .{ .key = "value", .syntax = "value", .direct = true },
        .{ .key = "publicValue", .syntax = "publicValue" },
        .{ .key = "x-y", .syntax = "'x-y'" },
        .{ .key = "value", .syntax = "'\\u0076alue'" },
        .{ .key = "café", .syntax = "café" },
        .{ .key = "quo\"te", .syntax = "'quo\"te'" },
        .{ .key = "back\\slash", .syntax = "'back\\\\slash'" },
        .{ .key = "__proto__", .syntax = "'__proto__'" },
        .{ .key = "__esModule", .syntax = "'__esModule'" },
        .{ .key = "readValue", .syntax = "'readValue'", .shadow = true },
    };
    for (cases, 0..) |case, index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const source = if (case.direct)
            "export let value=42;export function update(){value++}"
        else
            try std.fmt.allocPrint(a, "{s}let tracked=42;export{{tracked as {s}}};export function update(){{{s}tracked++}}", .{
                if (case.shadow) "const Object={tag:'object'},exports={tag:'exports'},module={tag:'module'},__defProp={tag:'helper'};" else "",
                case.syntax,
                if (case.shadow) "if(Object.tag!=='object'||exports.tag!=='exports'||module.tag!=='module'||__defProp.tag!=='helper')throw Error('lost source shadow');" else "",
            });
        try helpers.writeFile(tmp.dir, "entry.mjs", source);
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const key = try std.json.Stringify.valueAlloc(a, case.key, .{});
        const source_uri = try std.json.Stringify.valueAlloc(a, try std.fmt.allocPrint(a, "file://{s}", .{entry}), .{});
        const native_script = try std.fmt.allocPrint(a, "const namespace=await import({s});const before=namespace[{s}];namespace.update();console.log(JSON.stringify([before,namespace[{s}]]));", .{ source_uri, key, key });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native_script } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("[42,43]\n", native.stdout);
        for ([_]bool{ false, true }) |wrapped| for ([_]bool{ false, true }) |minify| for ([_]bool{ false, true }) |configurable| {
            var bundler = Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .platform = if (wrapped) .react_native else .node,
                .format = .cjs,
                .preserve_modules = wrapped,
                .code_splitting = wrapped,
                .preserve_modules_root = std.fs.path.dirname(entry),
                .strict_execution_order = wrapped,
                .configurable_exports = configurable,
                .unsupported = compat.fromESTarget(.es5),
                .rn_version_matrix = if (wrapped) compat.fromESTarget(.es5) else null,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            defer bundler.deinit();
            const result = try bundler.bundle(std.testing.io);
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(!result.hasErrors());
            const output_name = if (wrapped) "entry.js" else "output.cjs";
            if (result.outputs) |outputs| {
                for (outputs) |file| try helpers.writeFile(tmp.dir, file.path, file.contents);
            } else try helpers.writeFile(tmp.dir, output_name, result.output);
            const output = try helpers.absPath(&tmp, output_name);
            defer std.testing.allocator.free(output);
            const quoted_output = try std.json.Stringify.valueAlloc(a, output, .{});
            const output_uri = try std.json.Stringify.valueAlloc(a, try std.fmt.allocPrint(a, "file://{s}", .{output}), .{});
            const script = try std.fmt.allocPrint(a, "(async function(){{const host=require({s});const key={s};const before=host[key];const descriptor=Object.getOwnPropertyDescriptor(host,key);" ++
                "const namespace=await import({s});if(!Object.hasOwn(namespace,key))throw Error('missing native CJS name');const snapshot=namespace[key];host.update();" ++
                "const after=Object.getOwnPropertyDescriptor(host,key);if(!Object.hasOwn(host,key)||Object.getPrototypeOf(host)!==Object.prototype)throw Error('own key/prototype');" ++
                "if(typeof descriptor.get!=='function'||descriptor.set!==undefined||!descriptor.enumerable||descriptor.configurable!=={s})throw Error('getter descriptor');" ++
                "if(after.get!==descriptor.get||after.set!==descriptor.set||after.enumerable!==descriptor.enumerable||after.configurable!==descriptor.configurable)throw Error('changed descriptor');" ++
                "console.log(JSON.stringify([before,snapshot,host[key],namespace[key]]));}})().catch(function(error){{console.error(error);process.exitCode=1}});", .{ quoted_output, key, output_uri, if (configurable) "true" else "false" });
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, actual.stdout, "[42,42,43,42]\n")) {
                std.debug.print("CJS namespace case={} key={s} wrapped={} minify={} configurable={} stdout={s} stderr={s}\n", .{ index, case.key, wrapped, minify, configurable, actual.stdout, actual.stderr });
                if (result.outputs) |outputs| {
                    for (outputs) |file| std.debug.print("CJS namespace output {s}:\n{s}\n", .{ file.path, file.contents });
                } else std.debug.print("CJS namespace output:\n{s}\n", .{result.output});
            }
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings("", actual.stderr);
            // Node CJS namespace values are snapshots. Do not replace this
            // expectation with native ESM's live [42,43] behavior above.
            try std.testing.expectEqualStrings("[42,42,43,42]\n", actual.stdout);
        };
    }
}
