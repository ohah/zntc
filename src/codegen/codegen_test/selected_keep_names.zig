const std = @import("std");
const NodeIndex = @import("../../parser/ast.zig").NodeIndex;
const Codegen = @import("../codegen.zig").Codegen;
const Metadata = @import("../codegen.zig").LinkingMetadata;

test "selected statement keepNames prologues honor ten source order and DCE controls" {
    const Selection = enum { all, drop_first, drop_second, skip_second };
    const Case = struct { source: []const u8, names: []const u8, selection: Selection = .all, rename: bool = true, lower_brace: bool = false };
    const cases = [_]Case{
        .{ .source = "console.log(JSON.stringify([first.name,second.name]));function first(){}function second(){}", .names = "[\"first\",\"second\"]" },
        .{ .source = "'use strict';/*header*/'custom';console.log(JSON.stringify([(0,first)()===undefined,first.name]));function first(){return this}", .names = "[\"first\"]" },
        .{ .source = "console.log(first.name);function first(){}function second(){}", .names = "[\"first\"]", .selection = .drop_second },
        .{ .source = "console.log(first.name);function first(){}function second(){}", .names = "[\"first\"]", .selection = .skip_second },
        .{ .source = "console.log(second.name);function first(){}function second(){}", .names = "[\"second\"]", .selection = .drop_first },
        .{ .source = "console.log(JSON.stringify([first.name,second.name]));function second(){}function first(){}", .names = "[\"second\",\"first\"]" },
        .{ .source = "console.log(f\\u0069rst.name);function f\\u0069rst(){}", .names = "[\"first\"]" },
        .{ .source = "console.log(한글.name);function 한글(){}", .names = "[\"한글\"]" },
        .{ .source = "console.log(__proto__.name);function __proto__(){}", .names = "[\"__proto__\"]" },
        .{ .source = "#!/usr/bin/env node\n'use strict';console.log(JSON.stringify([(0,first)()===undefined,first.name]));function first(){return this}", .names = "[\"first\"]" },
        .{ .source = "console.log(first.name);function first(){}", .names = "[]", .rename = false },
        .{ .source = "console.log(\\u{10400}.name);function \\u{10400}(){}", .names = "[\"𐐀\"]", .lower_brace = true },
    };
    var failures: usize = 0;
    for (cases, 0..) |case, index| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try @import("../../lexer/scanner.zig").Scanner.init(allocator, case.source);
        var parser = @import("../../parser/parser.zig").Parser.init(allocator, &scanner);
        const root = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        var analyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer.init(allocator, &parser.ast);
        try analyzer.analyze();
        try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
        var metadata: Metadata = .{ .skip_nodes = try std.DynamicBitSet.initEmpty(allocator, parser.ast.nodes.items.len), .renames = .empty, .final_exports = null, .symbol_ids = analyzer.symbol_ids.items, .allocator = allocator };
        var selected: std.ArrayList(u32) = .empty;
        const list = parser.ast.getNode(root).data.list;
        var ordinal: usize = 0;
        for (parser.ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
            const node = parser.ast.getNode(@fromBackingInt(raw));
            if (node.tag == .function_declaration) {
                const name = parser.ast.readExtraNode(node.data.extra, 0);
                const sid = analyzer.symbol_ids.items[@backingInt(name)].?;
                if (case.rename) try metadata.renames.put(allocator, sid, if (ordinal == 0) "chosen_first" else "chosen_second");
                const drop = case.selection == .drop_first and ordinal == 0 or case.selection == .drop_second and ordinal == 1;
                if (case.selection == .skip_second and ordinal == 1) metadata.skip_nodes.set(raw);
                ordinal += 1;
                if (drop) continue;
            }
            try selected.append(allocator, raw);
        }
        var generator = Codegen.initWithOptions(allocator, &parser.ast, .{ .keep_names = true, .minify_whitespace = minify, .lower_unicode_brace = case.lower_brace, .ascii_only = case.lower_brace, .linking_metadata = &metadata, .semantic_symbols = analyzer.symbols.items });
        const output = try generator.generateStatements(root, selected.items);
        if (case.lower_brace) try std.testing.expect(std.mem.indexOf(u8, output, "\\u{") == null);
        const quoted_source = try std.json.Stringify.valueAlloc(allocator, case.source, .{});
        const quoted_output = try std.json.Stringify.valueAlloc(allocator, output, .{});
        const native_script = try std.fmt.allocPrint(allocator, "require('node:vm').runInNewContext({s},{{console}});", .{quoted_source});
        const generated_script = try std.fmt.allocPrint(allocator, "const events=[];function name(t,n){{events.push(n);Object.defineProperty(t,'name',{{value:n,configurable:true}});return t}}require('node:vm').runInNewContext({s},{{console,__name:name,$nm:name}});console.log(JSON.stringify(events));", .{quoted_output});
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", native_script }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        const generated = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", generated_script }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqualStrings("", native.stderr);
        try std.testing.expectEqualStrings("", generated.stderr);
        const expected = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ native.stdout, case.names });
        if (!std.mem.eql(u8, expected, generated.stdout)) {
            failures += 1;
            std.debug.print("selected keepNames case {d} min={any}: expected={s} actual={s} output={s}\n", .{ index, minify, expected, generated.stdout, output });
        }
        var disabled = Codegen.initWithOptions(allocator, &parser.ast, .{ .keep_names = false, .minify_whitespace = minify, .linking_metadata = &metadata, .semantic_symbols = analyzer.symbols.items });
        const disabled_output = try disabled.generateStatements(root, selected.items);
        try std.testing.expect(std.mem.indexOf(u8, disabled_output, "__name(") == null and std.mem.indexOf(u8, disabled_output, "$nm(") == null);
    };
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "selected statement keepNames restores wrapped ESM defaults before source reads" {
    const helpers = @import("../../bundler/test_helpers.zig");
    for ([_]bool{ false, true }) |minify| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try helpers.writeFile(tmp.dir, "entry.mjs", "import('./consumer.mjs').then(m=>console.log(JSON.stringify([m.default.name,m.snapshot,m.value()])));");
        try helpers.writeFile(tmp.dir, "consumer.mjs", "import './dep.cjs';export const snapshot=read.name;export default function read(){return 42}export function value(){return read()}");
        try helpers.writeFile(tmp.dir, "dep.cjs", "exports.value=42;");
        const entry = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(entry);
        const native = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", entry }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer std.testing.allocator.free(native.stdout);
        defer std.testing.allocator.free(native.stderr);
        try std.testing.expectEqualStrings("", native.stderr);
        var output = try helpers.bundleEntry(std.testing.allocator, &tmp, "entry.mjs", .{ .inline_dynamic_imports = true, .keep_names = true, .minify_identifiers = minify, .minify_syntax = minify, .minify_whitespace = minify });
        defer output.deinit();
        const generated = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "node", "-e", output.code() }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        defer std.testing.allocator.free(generated.stdout);
        defer std.testing.allocator.free(generated.stderr);
        try std.testing.expectEqualStrings("", generated.stderr);
        try std.testing.expectEqualStrings(native.stdout, generated.stdout);
    }
}
