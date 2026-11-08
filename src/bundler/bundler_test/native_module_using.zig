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

test "native module using selected disposal owner uses current physical rows and rejects foreign metadata" {
    const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
    const Graph = @import("../graph.zig").ModuleGraph;
    const Linker = @import("../linker.zig").Linker;
    const Shaker = @import("../tree_shaker.zig").TreeShaker;
    const publication = @import("../native_async_disposal_publication.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try helpers.writeFile(tmp.dir, "main.mjs", "import{resource}from'./lib.mjs';console.log(resource);");
    try helpers.writeFile(tmp.dir, "lib.mjs", "await using ignored={async[Symbol.asyncDispose](){globalThis.disposed=true}};export const resource=7;");
    const entry = try helpers.absPath(&tmp, "main.mjs");
    defer std.testing.allocator.free(entry);
    var cache = ResolveCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    var graph = Graph.init(std.testing.allocator, &cache);
    defer graph.deinit();
    try graph.build(std.testing.io, &.{entry});
    var linker = Linker.init(std.testing.allocator, &graph, .esm);
    defer linker.deinit();
    try linker.link();
    linker.populateImportSymbols();
    var shaker = try Shaker.init(std.testing.allocator, &graph, &linker);
    defer shaker.deinit();
    try shaker.analyze(&.{entry});
    const main = graph.moduleAtMut(@fromBackingInt(@as(u32, 0))).?;
    try std.testing.expect(main.is_entry_point);
    const module = graph.moduleAtMut(main.import_records[0].resolved).?;
    try std.testing.expect(shaker.isIncluded(module.index.toU32()));
    // The healthy selection comes from real parse -> semantic -> link -> shake.
    try std.testing.expect((try publication.retainedDeclaration(std.testing.allocator, module, &shaker)) != null);
    const infos = &shaker.module_stmt_infos[module.index.toU32()].?;
    var row: ?usize = null;
    for (infos.stmts, 0..) |statement, i| {
        const node = module.ast.?.nodes.items[statement.node_idx];
        if (node.tag == .variable_declaration and module.ast.?.variableDeclarationKind(node) == .await_using) {
            try std.testing.expect(row == null);
            row = i;
        }
    }
    const selected_row = row orelse return error.TestUnexpectedResult;
    try std.testing.expect(shaker.isStmtReachable(module.index.toU32(), @intCast(selected_row)));
    const original = infos.stmts[selected_row];
    try std.testing.expect(infos.stmts.len >= 2);
    // Wrong physical node must not borrow the other declaration's coordinate.
    {
        defer infos.stmts[selected_row] = original;
        infos.stmts[selected_row].node_idx = infos.stmts[if (selected_row == 0) 1 else 0].node_idx;
        try std.testing.expectError(error.InvalidNativeAsyncDisposalOwner, publication.retainedDeclaration(std.testing.allocator, module, &shaker));
    }
    // The same physical declaration must still own its exact declared SID.
    {
        defer infos.stmts[selected_row] = original;
        infos.stmts[selected_row].declared_symbols = &.{};
        try std.testing.expectError(error.InvalidNativeAsyncDisposalOwner, publication.retainedDeclaration(std.testing.allocator, module, &shaker));
    }
    // A controlled dead-row change observes actual selected-shaker metadata;
    // it is not a claim that policy may erase an effectful resource.
    {
        defer shaker.reachable_stmts[module.index.toU32()].?.set(selected_row);
        shaker.reachable_stmts[module.index.toU32()].?.unset(selected_row);
        try std.testing.expect((try publication.retainedDeclaration(std.testing.allocator, module, &shaker)) == null);
    }
    try std.testing.expect((try publication.retainedDeclaration(std.testing.allocator, module, &shaker)) != null);
    // A separately built actual graph has coincident numeric IDs, not ownership.
    var foreign_graph = Graph.init(std.testing.allocator, &cache);
    defer foreign_graph.deinit();
    try foreign_graph.build(std.testing.io, &.{entry});
    var foreign_linker = Linker.init(std.testing.allocator, &foreign_graph, .esm);
    defer foreign_linker.deinit();
    try foreign_linker.link();
    foreign_linker.populateImportSymbols();
    var foreign_shaker = try Shaker.init(std.testing.allocator, &foreign_graph, &foreign_linker);
    defer foreign_shaker.deinit();
    try foreign_shaker.analyze(&.{entry});
    const foreign_module = foreign_graph.moduleAtMut(module.index).?;
    try std.testing.expect(foreign_module != module);
    try std.testing.expectEqual(module.index, foreign_module.index);
    try std.testing.expectError(error.InvalidNativeAsyncDisposalOwner, publication.retainedDeclaration(std.testing.allocator, module, &foreign_shaker));
    try std.testing.expect((try publication.retainedDeclaration(std.testing.allocator, module, &shaker)) != null);
}
