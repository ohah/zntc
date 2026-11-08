const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Codegen = @import("codegen.zig").Codegen;
const Context = @import("native_module_using.zig").Context;
const Wrapper = @import("../bundler/native_module_wrapper_program.zig").Program;

const Fixture = struct {
    parser: Parser,
    scanner: *Scanner,
    analysis: Analyzer,
    root: @import("../parser/ast.zig").NodeIndex,
    fn create(a: std.mem.Allocator, source: []const u8) !*Fixture {
        const f = try a.create(Fixture);
        f.scanner = try a.create(Scanner);
        f.scanner.* = try Scanner.init(a, source);
        f.parser = Parser.init(a, f.scanner);
        f.parser.configureFromExtension(".mjs");
        f.root = try f.parser.parse();
        if (f.parser.hasErrors()) {
            std.debug.print("using source parse: {s}\n", .{source});
            return error.InvalidFixture;
        }
        f.analysis = Analyzer.init(a, &f.parser.ast);
        f.analysis.enable_exact_declaration_anchors = true;
        try f.analysis.analyze();
        try std.testing.expectEqual(@as(usize, 0), f.analysis.errors.items.len);
        return f;
    }
};

test "native module using validates source identities wrapper roles and direct root slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.create(a, "using one=null;await using two=null;async function inner(){await using hidden=null;} {using block=null;}");
    const foreign = try Fixture.create(a, "using other=null;");
    const shell = try Wrapper.create(std.testing.allocator, &.{ "one", "two", "inner", "hidden", "block" });
    defer shell.destroy();
    var context = try Context.create(a, &f.parser.ast, f.root, @import("native_module_using.zig").SourceView.fromAnalyzer(&f.analysis), shell);
    try std.testing.expectEqual(@as(usize, 2), context.declarations.len);
    const original = context;
    const poisons = [_]enum { domain, root, analysis, environment_owner, stack_symbol, slot, source_sid, source_scope, source_origin, source_bytes }{ .domain, .root, .analysis, .environment_owner, .stack_symbol, .slot, .source_sid, .source_scope, .source_origin, .source_bytes };
    for (poisons) |poison| {
        context = original;
        const bindings = @constCast(context.declarations[0].bindings);
        const old_binding = bindings[0];
        const sid = bindings[0].symbol;
        const old_symbol = f.analysis.symbols.items[sid];
        const declarations = @constCast(context.declarations);
        const old_decl = declarations[0];
        switch (poison) {
            .domain => context.domain = &foreign.parser.ast,
            .root => context.root = context.declarations[0].declaration,
            .analysis => context.analysis = @import("native_module_using.zig").SourceView.fromAnalyzer(&foreign.analysis),
            .environment_owner => context.environment.owner = .unassigned,
            .stack_symbol => context.stack.symbol = context.environment.symbol,
            .slot => declarations[0].statement = context.declarations[1].statement,
            .source_sid => bindings[0].symbol = context.declarations[1].bindings[0].symbol,
            .source_scope => f.analysis.symbols.items[sid].scope_id = .none,
            .source_origin => f.analysis.symbols.items[sid].origin_scope = .none,
            .source_bytes => context.source = "foreign",
        }
        try std.testing.expectError(error.InvalidNativeModuleUsingContext, context.validate(&f.parser.ast));
        bindings[0] = old_binding;
        declarations[0] = old_decl;
        f.analysis.symbols.items[sid] = old_symbol;
        context = original;
        try context.validate(&f.parser.ast);
    }
}

test "native module using compares direct acquisition lexical names errors and source functions" {
    const bodies = [_][]const u8{
        "const value=42;try{value=43}catch(e){record(e.name)}using r=make('outer');record(value);",
        "using first=make('first'),second=(record('comma'),make('second'));record('body');",
        "await using first=makeAsync('first');await using nil=null;record('body');await 0;record('resume');",
        "using first=make('first');using second=(()=>{throw 'acquire'})();",
        "using first=makeThrow('first');using second=makeThrow('second');throw 'body';",
        "using first=make('first');try{first=null}catch(e){record(e.name)}record('readonly');",
        "async function inner(){await using own=makeAsync('inner');record('inner:body')}const arrow=async()=>{using own=make('arrow');record('arrow:body')};const obj={async method(){using own=make('method');record('method:body')}};using outer=make('outer');await inner();await arrow();await obj.method();",
        "Function.prototype[Symbol.dispose]=function(){record(this.name)};using named=function(){};using arrow=()=>{};using \\u0065scaped=()=>{};record([named.name,arrow.name,escaped.name]);",
        "Function.prototype[Symbol.dispose]=function(){record(this.name)};using Box=class{};using __proto__=class{};record([Box.name,__proto__.name]);",
        "using first=await Promise.resolve(make('yield'));record('body');",
    };
    const prelude = "const events=[];const record=x=>events.push(x);const make=n=>({[Symbol.dispose](){record('dispose:'+n)}});const makeAsync=n=>({async[Symbol.asyncDispose](){record('start:'+n);await 0;record('end:'+n)}});const makeThrow=n=>({[Symbol.dispose](){record('dispose:'+n);throw n}});const shape=e=>e instanceof SuppressedError?[e.name,e.message,shape(e.error),shape(e.suppressed),Object.keys(e)]:e instanceof Error?e.name:e;";
    for (bodies, 0..) |body, case| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try Fixture.create(a, body);
        // Reservation input is chosen from the actual first-analysis bindings
        // and unresolved reads by the integrating emitter. These source cases
        // do not collide with shell preferred names.
        const shell = try Wrapper.create(std.testing.allocator, &.{});
        defer shell.destroy();
        const context = try Context.create(a, &f.parser.ast, f.root, @import("native_module_using.zig").SourceView.fromAnalyzer(&f.analysis), shell);
        var overrides: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
        if (minify) for (context.declarations, 0..) |declaration, d| {
            for (declaration.bindings, 0..) |binding, b| try overrides.put(a, binding.symbol, try std.fmt.allocPrint(a, "renamedUsing{d}_{d}", .{ d, b }));
        };
        var codegen = Codegen.initWithOptions(a, &f.parser.ast, .{ .module_await_as_yield = true, .native_module_using = &context, .semantic_symbol_ids = f.analysis.symbol_ids.items, .semantic_symbols = f.analysis.symbols.items, .semantic_symbol_name_overrides = &overrides, .minify_whitespace = minify, .minify_syntax = minify });
        const root = f.parser.ast.getNode(f.root);
        const generated = try codegen.generateStatements(f.root, f.parser.ast.extra_data.items[root.data.list.start..][0..root.data.list.len]);
        const inserted = try std.fmt.allocPrint(a, "yield{{namespace:{{}},hasTLA:true}};{s}", .{generated});
        const wrapper = try shell.emitValue(a, inserted, minify);
        const factory = @import("../bundler/native_async_module_runtime.zig").FACTORY_EXPRESSION;
        const acquire = @import("../bundler/native_async_disposal_runtime.zig").ACQUIRE_EXPRESSION;
        const dispose = @import("../bundler/native_async_disposal_runtime.zig").DISPOSE_GENERATOR_EXPRESSION;
        const native = try std.fmt.allocPrint(a, "{s}async function run(){{{s}}}try{{await run()}}catch(e){{record(shape(e))}}console.log(JSON.stringify(events));", .{ prelude, body });
        const model = try std.fmt.allocPrint(a, "{s}const init=({s})({s},()=>[],[{s},{s}]);try{{await init()}}catch(e){{record(shape(e))}}console.log(JSON.stringify(events));", .{ prelude, factory, wrapper, acquire, dispose });
        const expected = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", native }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", model }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        errdefer std.debug.print("using case={d} minify={} generated={s}\nnative={s}\nactual={s}\n", .{ case, minify, generated, expected.stderr, actual.stderr });
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
    };
}
