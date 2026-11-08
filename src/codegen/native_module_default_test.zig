const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Codegen = @import("codegen.zig").Codegen;
const Context = @import("native_module_using.zig").Context;
const View = @import("native_module_using.zig").SourceView;
const Wrapper = @import("../bundler/native_module_wrapper_program.zig").Program;

const Fixture = struct {
    scanner: *Scanner,
    parser: Parser,
    analysis: Analyzer,
    root: @import("../parser/ast.zig").NodeIndex,
    fn create(a: std.mem.Allocator, source: []const u8) !*Fixture {
        const f = try a.create(Fixture);
        f.scanner = try a.create(Scanner);
        f.scanner.* = try Scanner.init(a, source);
        f.parser = Parser.init(a, f.scanner);
        f.parser.configureFromExtension(".mjs");
        f.root = try f.parser.parse();
        try std.testing.expectEqual(@as(usize, 0), f.parser.errors.items.len);
        f.analysis = Analyzer.init(a, &f.parser.ast);
        f.analysis.enable_exact_declaration_anchors = true;
        try f.analysis.analyze();
        try std.testing.expectEqual(@as(usize, 0), f.analysis.errors.items.len);
        return f;
    }
};

test "native module default instantiation preserves lexical facade and function names before the gate" {
    const cases = [_]struct { source: []const u8, late: []const u8, expected: []const u8 }{
        .{ .source = "export default 42;", .late = "[typeof facade,facade]", .expected = "[\"ReferenceError\",[\"number\",42]]\n" },
        .{ .source = "export default function(){return 42}", .late = "[typeof facade,facade(),facade.name]", .expected = "[[\"function\",42,\"default\"],[\"function\",42,\"default\"]]\n" },
        .{ .source = "export default (function(){return 42});", .late = "[typeof facade,facade(),facade.name]", .expected = "[\"ReferenceError\",[\"function\",42,\"default\"]]\n" },
        .{ .source = "export default ()=>42;", .late = "[typeof facade,facade(),facade.name]", .expected = "[\"ReferenceError\",[\"function\",42,\"default\"]]\n" },
        .{ .source = "export default class {static seen=this.name};", .late = "[typeof facade,facade.name,facade.seen]", .expected = "[\"ReferenceError\",[\"function\",\"default\",\"default\"]]\n" },
    };
    for (cases, 0..) |case, case_index| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try Fixture.create(a, case.source);
        const shell = try Wrapper.create(std.testing.allocator, &.{"facade"});
        defer shell.destroy();
        const context = try Context.create(a, &f.parser.ast, f.root, View.fromAnalyzer(&f.analysis), shell);
        const root = f.parser.ast.getNode(f.root);
        const indices = f.parser.ast.extra_data.items[root.data.list.start..][0..root.data.list.len];
        const sid = f.analysis.symbol_ids.items[indices[0]].?;
        var names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        try names.put(a, sid, "facade");
        var codegen = Codegen.initWithOptions(a, &f.parser.ast, .{ .module_format = .cjs, .skip_cjs_exports = true, .module_await_as_yield = true, .native_module_using = &context, .semantic_symbol_ids = f.analysis.symbol_ids.items, .semantic_symbols = f.analysis.symbols.items, .semantic_symbol_name_overrides = &names, .minify_whitespace = minify, .minify_syntax = minify });
        try codegen.write("globalThis.read=()=>");
        try codegen.write(case.late);
        try codegen.write(";");
        try codegen.emitNativeModuleInstantiationPrologue(f.root, indices);
        try codegen.write("yield;");
        const body = try codegen.generateStatements(f.root, indices);
        const program = try std.fmt.allocPrint(a, "const it=(function*(){{\"use strict\";{s}}})();it.next();let early;try{{early=read()}}catch(e){{early=e.name}}it.next();console.log(JSON.stringify([early,read()]));", .{body});
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", program }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        errdefer std.debug.print("default case={d} minify={} program={s}\nstderr={s}\n", .{ case_index, minify, program, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, actual.stdout);
        try std.testing.expectEqualStrings("", actual.stderr);
    };
}

test "native module default prologue rejects foreign root SID scope and implicit declaration evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.create(a, "export default function(){return 42}");
    const shell = try Wrapper.create(std.testing.allocator, &.{});
    defer shell.destroy();
    var context = try Context.create(a, &f.parser.ast, f.root, View.fromAnalyzer(&f.analysis), shell);
    const root = f.parser.ast.getNode(f.root);
    const indices = f.parser.ast.extra_data.items[root.data.list.start..][0..root.data.list.len];
    const sid = f.analysis.symbol_ids.items[indices[0]].?;
    const old = f.analysis.symbols.items[sid];
    const options: @import("options.zig").CodegenOptions = .{ .module_await_as_yield = true, .native_module_using = &context, .semantic_symbol_ids = f.analysis.symbol_ids.items, .semantic_symbols = f.analysis.symbols.items };
    for (0..4) |poison| {
        var codegen = Codegen.initWithOptions(a, &f.parser.ast, options);
        switch (poison) {
            0 => f.analysis.symbols.items[sid].decl_flags.is_default_export = false,
            1 => f.analysis.symbols.items[sid].scope_id = .none,
            2 => f.analysis.symbols.items[sid].declaration_span.end += 1,
            3 => context.root = @fromBackingInt(indices[0]),
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidNativeModuleDefault, codegen.emitNativeModuleInstantiationPrologue(f.root, indices));
        f.analysis.symbols.items[sid] = old;
        context.root = f.root;
    }
}

test "native module default named function restoration is instantiation only and retains later name writes" {
    for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try Fixture.create(a, "export default function named(){return 42}globalThis.during=named.name;Object.defineProperty(named,'name',{value:'changed'});");
        const shell = try Wrapper.create(std.testing.allocator, &.{"chosen"});
        defer shell.destroy();
        const context = try Context.create(a, &f.parser.ast, f.root, View.fromAnalyzer(&f.analysis), shell);
        const root = f.parser.ast.getNode(f.root);
        const indices = f.parser.ast.extra_data.items[root.data.list.start..][0..root.data.list.len];
        const export_node = f.parser.ast.nodes.items[indices[0]];
        const function_node = f.parser.ast.getNode(export_node.data.unary.operand);
        const binding = f.parser.ast.readExtraNode(function_node.data.extra, @import("../parser/ast.zig").FunctionExtra.name);
        const sid = f.analysis.symbol_ids.items[@backingInt(binding)].?;
        var names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        try names.put(a, sid, "chosen");
        var codegen = Codegen.initWithOptions(a, &f.parser.ast, .{ .module_format = .cjs, .skip_cjs_exports = true, .module_await_as_yield = true, .native_module_using = &context, .semantic_symbol_ids = f.analysis.symbol_ids.items, .semantic_symbols = f.analysis.symbols.items, .semantic_symbol_name_overrides = &names, .keep_names = true, .keep_names_helper_name = "restore", .minify_whitespace = minify });
        try codegen.write("globalThis.read=()=>[chosen(),chosen.name];globalThis.mutate=()=>Object.defineProperty(chosen,'name',{value:'cycle'});");
        try codegen.emitNativeModuleInstantiationPrologue(f.root, indices);
        try codegen.write("yield;");
        const body = try codegen.generateStatements(f.root, indices);
        const program = try std.fmt.allocPrint(a, "const restore=(f,n)=>Object.defineProperty(f,'name',{{value:n,configurable:true}});const it=(function*(){{\"use strict\";{s}}})();it.next();const early=read();mutate();it.next();console.log(JSON.stringify([early,during,read()]));", .{body});
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", program }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        errdefer std.debug.print("named default generated={s}\nstderr={s}\n", .{ program, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("[[42,\"named\"],\"cycle\",[42,\"changed\"]]\n", actual.stdout);
        try std.testing.expectEqualStrings("", actual.stderr);
    }
}
