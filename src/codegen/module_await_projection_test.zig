const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const Codegen = @import("codegen.zig").Codegen;
const Options = @import("options.zig").CodegenOptions;

fn print(a: std.mem.Allocator, source: []const u8, options: Options) ![]const u8 {
    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    parser.configureFromExtension(".mjs");
    const root = try parser.parse();
    if (parser.hasErrors()) {
        std.debug.print("projection parser error: {s}\nsource: {s}\n", .{ parser.errors.items[0].message, source });
        return error.ParserDiagnosticsPresent;
    }
    var generator = Codegen.initWithOptions(a, &parser.ast, options);
    return generator.generate(root);
}

test "module await projection matches yield precedence and preserves default output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "console.log((await value)+1,(await factory)(),(await object).key);";
    const projected = try print(a, source, .{ .minify_whitespace = true, .module_await_as_yield = true });
    try std.testing.expectEqualStrings("console.log((yield value)+1,(yield factory)(),(yield object).key);", projected);
    const original = try print(a, source, .{ .minify_whitespace = true });
    const explicit_false = try print(a, source, .{ .minify_whitespace = true, .module_await_as_yield = false });
    try std.testing.expectEqualStrings(original, explicit_false);
    try std.testing.expect(std.mem.indexOf(u8, original, "yield") == null);
    try std.testing.expect(std.mem.indexOf(u8, original, "await") != null);
}

test "module await projection preserves operands exceptions source executions and computed keys" {
    const sources = [_][]const u8{
        "const values=[(await 3)+4,(await 2)**3,-(await 5),(await Promise.resolve({x:42})).x,(await (()=>42))(),await (0,42)];console.log(JSON.stringify(values));",
        "const events=[];const value=(await Promise.resolve(false))?await(events.push('bad'),0):await(events.push('good'),42);const skipped=false&&(await(events.push('bad'),0));console.log(JSON.stringify([value,skipped,events]));",
        "const events=[];try{await(()=>{throw Error('operand')})()}catch(e){events.push(e.message)}try{await Promise.reject('rejected')}catch(e){events.push(e)}console.log(JSON.stringify(events));",
        "console.log(await(await Promise.resolve(42)));",
        "async function f(input=async()=>await Promise.resolve(20)){const o={async[await Promise.resolve('m')](){return await input()}};return await o.m()}const arrow=async()=>await 2;console.log((await f())+(await arrow()));",
        "const events=[];const o={async[await(events.push('key'),Promise.resolve('m'))](input=async()=>await 40){events.push('body');return(await input())+2}};console.log(await o.m(),JSON.stringify(events));",
        "class Base{}class C extends(await Promise.resolve(Base)){[await Promise.resolve('m')](){return 42}static[await Promise.resolve('s')](){return 43}}console.log(new C().m(),C.s());",
        "const make=async()=>({async[await 'm'](){return await 3}});await 0;const o=await make();console.log(await o.m());",
        "let n=0;const events=[];function tick(){events.push('tick:'+n);if(++n<4)queueMicrotask(tick)}queueMicrotask(tick);events.push('body');await null;events.push('resume');console.log(JSON.stringify(events));",
        "class C{field=async()=>await 42;static field=async()=>await 43;[await 'key']=1}console.log(await new C().field(),await C.field(),new C().key);",
    };
    for (sources, 0..) |source, case_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings("", native.stderr);
        for ([_]bool{ false, true }) |minify| {
            const projected = try print(a, source, .{ .minify_whitespace = minify, .module_await_as_yield = true });
            // The emitter owns the actual module-generator shell. Exercise the
            // printed module statements in exactly that lexical execution role.
            const model = try std.fmt.allocPrint(
                a,
                "async function drive(it){{let step=it.next();while(!step.done){{try{{const value=await step.value;step=it.next(value)}}catch(error){{step=it.throw(error)}}}}}}await drive((function*(){{{s}}})());",
                .{projected},
            );
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", model }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            errdefer std.debug.print("projection case={d} minify={} code={s}\nactual stderr={s}\n", .{ case_index, minify, projected, actual.stderr });
            try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
            try std.testing.expectEqualStrings(native.stdout, actual.stdout);
            try std.testing.expectEqualStrings(native.stderr, actual.stderr);
        }
    }
}
