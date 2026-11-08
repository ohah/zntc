const std = @import("std");
const ast = @import("../parser/ast.zig");
const Parser = @import("../parser/parser.zig").Parser;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const Codegen = @import("codegen.zig").Codegen;
const Projection = @import("native_module_import_projection.zig");
const SourceView = @import("native_module_using.zig").SourceView;
const Fixture = struct {
    scanner: *Scanner,
    parser: Parser,
    analysis: Analyzer,
    root: ast.NodeIndex,
    plans: []Projection.Entry,
    statements: []const u32,
    fn create(a: std.mem.Allocator, source: []const u8) !*Fixture {
        const self = try a.create(Fixture);
        self.scanner = try a.create(Scanner);
        self.scanner.* = try Scanner.init(a, source);
        self.parser = Parser.init(a, self.scanner);
        self.parser.configureFromExtension(".mjs");
        self.root = try self.parser.parse();
        try std.testing.expectEqual(@as(usize, 0), self.parser.errors.items.len);
        self.analysis = Analyzer.init(a, &self.parser.ast);
        self.analysis.is_module = true;
        self.analysis.enable_exact_declaration_anchors = true;
        // The codegen contract is runtime import immutability. This unit does
        // not change the bundler's independent static mutation admission policy.
        self.analysis.check_import_mutation = false;
        try self.analysis.analyze();
        try std.testing.expectEqual(@as(usize, 0), self.analysis.errors.items.len);
        var plans: std.ArrayListUnmanaged(Projection.Entry) = .empty;
        var statements: std.ArrayListUnmanaged(u32) = .empty;
        var body = self.parser.ast.iterateExtraList(self.parser.ast.getNode(self.root).data.list);
        while (body.next()) |statement| {
            const node = self.parser.ast.getNode(statement);
            if (node.tag != .import_declaration) {
                try statements.append(a, @backingInt(statement));
                continue;
            }
            const extra = @import("../parser/module.zig").readImportDeclExtras(&self.parser.ast, node.data.extra);
            var specs = self.parser.ast.iterateExtraList(.{ .start = extra.specs_start, .len = extra.specs_len });
            while (specs.next()) |specifier| {
                const spec = self.parser.ast.getNode(specifier);
                const binding = if (spec.tag == .import_specifier) (if (spec.data.binary.right.isNone()) spec.data.binary.left else spec.data.binary.right) else specifier;
                const key: ?[]const u8 = if (spec.tag == .import_namespace_specifier) null else if (spec.tag == .import_default_specifier) "default" else self.parser.ast.getText(self.parser.ast.getNode(spec.data.binary.left).span);
                try plans.append(a, .{ .binding = binding, .symbol = self.analysis.symbol_ids.items[@backingInt(binding)].?, .namespace_name = "__provider", .property = key });
            }
        }
        self.plans = try plans.toOwnedSlice(a);
        self.statements = try statements.toOwnedSlice(a);
        return self;
    }
};

test "native module import projection rejects foreign domain SID roles and stale actual references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try Fixture.create(a, "import {value as imported} from 'provider';import * as namespace from 'provider';console.log({imported},namespace);try{imported=1}catch(e){}");
    const other = try Fixture.create(a, "import {value} from 'other';console.log(value);");
    var context = try Projection.Context.create(a, &f.parser.ast, f.root, SourceView.fromAnalyzer(&f.analysis), f.plans);
    try context.validate();
    const original = context;
    const selected = @constCast(context.entries);
    const old = selected[0];
    const sid = f.plans[0].symbol;
    const symbol = f.analysis.symbols.items[sid];
    const old_anchor = f.analysis.references.items[selected[0].anchor.?];
    const poisons = [_]enum { domain, root, sid, binding, namespace_name, namespace_role, scope, origin, anchor, read_role, reference_count, reader_empty, reader_namespace }{ .domain, .root, .sid, .binding, .namespace_name, .namespace_role, .scope, .origin, .anchor, .read_role, .reference_count, .reader_empty, .reader_namespace };
    var iterator = context.uses.iterator();
    const use_row = iterator.next().?;
    const use_raw = use_row.key_ptr.*;
    const use = use_row.value_ptr.*;
    const reference_index = use.read_reference orelse use.write_reference.?;
    const original_ref = f.analysis.references.items[reference_index];
    for (poisons) |poison| {
        switch (poison) {
            .domain => context.domain = &other.parser.ast,
            .root => context.root = f.plans[0].binding,
            .sid => selected[0].entry.symbol = f.plans[1].symbol,
            .binding => selected[0].entry.binding = f.plans[1].binding,
            .namespace_name => selected[0].entry.namespace_name = "",
            .namespace_role => selected[0].entry.property = null,
            .scope => f.analysis.symbols.items[sid].scope_id = .none,
            .origin => f.analysis.symbols.items[sid].origin_scope = .none,
            .anchor => f.analysis.references.items[selected[0].anchor.?].flags.declare = false,
            .read_role => f.analysis.references.items[reference_index].symbol_id = .none,
            .reference_count => context.reference_count += 1,
            .reader_empty => selected[0].entry.binding_reader = "",
            .reader_namespace => {
                selected[0].entry.property = null;
                selected[0].entry.binding_reader = "env[3][0]";
            },
        }
        try std.testing.expectError(error.InvalidNativeModuleImportProjection, context.validate());
        context = original;
        selected[0] = old;
        f.analysis.symbols.items[sid] = symbol;
        f.analysis.references.items[old.anchor.?] = old_anchor;
        f.analysis.references.items[reference_index] = original_ref;
        try context.validate();
    }
    _ = use_raw;
}

test "native module import projection matches live reads receiver readonly RHS defaults and shadowing" {
    const provider = "export let value=41;export let falsy=0;export function change(){value++}export function call(){return this===undefined}export function tag(){return this===undefined}export default function(){return this===undefined}const odd=7;export{odd as 'odd-key'};export const object={method(){return this===object}};";
    const cases = [_][]const u8{
        "console.log(JSON.stringify([imported,call(),defaultValue(),tag`x`,call?.(),object.method(),odd,namespace.value]));change();console.log(imported,namespace.value);",
        "function nested(imported){return imported}async function later(){await 0;return imported}const o={method(){return imported}};change();console.log(JSON.stringify([{imported},nested(9),await later(),o.method(),(()=>imported)()]));",
        "const events=[];try{imported=(events.push('rhs'),99)}catch(e){events.push(e.name)}events.push(imported);console.log(JSON.stringify(events));",
        "const events=[];try{namespace=(events.push('namespace-rhs'),{})}catch(e){events.push(e.name)}events.push(namespace.value);console.log(JSON.stringify(events));",
        "const events=[];try{imported+=(events.push('compound'),1)}catch(e){events.push(e.name)}try{imported++}catch(e){events.push(e.name)}events.push(imported);console.log(JSON.stringify(events));",
        "const events=[];imported||=(events.push('bad'),2);try{falsy||=(events.push('logical'),2)}catch(e){events.push(e.name)}console.log(JSON.stringify([events,imported,falsy]));",
        "const events=[];try{({imported}={get imported(){events.push('get');return 2}})}catch(e){events.push(e.name)}console.log(JSON.stringify([events,imported]));",
        "const events=[];try{call=class{static{events.push(this.name)}}}catch(e){events.push(e.name)}try{({call=class{static{events.push(this.name)}}}={})}catch(e){events.push(e.name)}console.log(JSON.stringify(events));",
    };
    for (cases, 0..) |body, case| for ([_]bool{ false, true }) |minify| for ([_]bool{ false, true }) |cached_reader| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(provider.len));
        _ = std.base64.standard.Encoder.encode(encoded, provider);
        const uri = try std.fmt.allocPrint(a, "data:text/javascript;base64,{s}", .{encoded});
        const source = try std.fmt.allocPrint(a, "import defaultValue,{{value as imported,change,call,tag,falsy,object,'odd-key' as odd}}from'{s}';import*as namespace from'{s}';{s}", .{ uri, uri, body });
        const f = try Fixture.create(a, source);
        if (cached_reader) for (f.plans, 0..) |*entry, ordinal| {
            if (entry.property != null) entry.binding_reader = try std.fmt.allocPrint(a, "__imports[3][{d}]", .{ordinal});
        };
        const context = try Projection.Context.create(a, &f.parser.ast, f.root, SourceView.fromAnalyzer(&f.analysis), f.plans);
        var codegen = Codegen.initWithOptions(a, &f.parser.ast, .{ .module_format = .cjs, .skip_cjs_exports = true, .module_await_as_yield = true, .native_module_import_projection = &context, .semantic_symbol_ids = f.analysis.symbol_ids.items, .semantic_symbols = f.analysis.symbols.items, .minify_whitespace = minify, .minify_syntax = minify });
        const generated = try codegen.generateStatements(f.root, f.statements);
        const factory = @import("../bundler/native_async_module_runtime.zig").FACTORY_EXPRESSION;
        var imports: std.ArrayList(u8) = .empty;
        try imports.appendSlice(a, "[");
        for (context.entries, 0..) |entry, i| {
            if (i > 0) try imports.append(a, ',');
            try imports.appendSlice(a, "[providerInit,");
            try imports.appendSlice(a, entry.quoted_key orelse "null");
            try imports.append(a, ']');
        }
        try imports.append(a, ']');
        const model = if (cached_reader)
            try std.fmt.allocPrint(a, "import*as __provider from'{s}';const factory=({s}),__imports=[null,null,null,[]],table=Object.create(null);for(const key of Object.getOwnPropertyNames(__provider))table[key]=()=>__provider[key];const providerInit=factory(function*(){{yield{{namespace:__provider,bindings:table,hasTLA:false}}}},()=>[]);const init=factory(function*(){{\"use strict\";yield{{namespace:{{}},hasTLA:true}};{s}}},()=>[providerInit],__imports,()=>{s});await init();", .{ uri, factory, generated, imports.items })
        else
            try std.fmt.allocPrint(a, "import*as __provider from'{s}';const init=({s})(function*(){{\"use strict\";yield{{namespace:{{}},hasTLA:true}};{s}}},()=>[]);await init();", .{ uri, factory, generated });
        const expected = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(32768) });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", model }, .stdout_limit = .limited(16384), .stderr_limit = .limited(32768) });
        errdefer std.debug.print("projection case={d} minify={} generated={s}\nnative={s}\nactual={s}\n", .{ case, minify, generated, expected.stderr, actual.stderr });
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
    };
}

test "native module import projection cached runtime binds getter identity without reading lexical values" {
    const checks =
        \\import assert from 'node:assert/strict';
        \\const results=[];
        \\let old2=0;const sync=create(function*(){yield{namespace:{},hasTLA:false};old2++},()=>[]);assert.equal(sync(),undefined);assert.equal(old2,1);results.push('old2');
        \\const oldEnv={};let old3;const sync3=create(function*(env){old3=env;yield{namespace:{},hasTLA:false}},()=>[],oldEnv);sync3();assert.equal(old3,oldEnv);results.push('old3');
        \\let sourceReads=0,sourceBodies=0,bindCalls=0,early,env=[null,null,null,[]],consumer;
        \\const table=Object.create(null),namespace=new Proxy(Object.create(null),{get(){throw Error('proxy read')}});
        \\const provider=create(function*(){table.value=()=>{sourceReads++;return value};yield{namespace,bindings:table,hasTLA:false};const value=42;sourceBodies++},()=>[consumer]);
        \\consumer=create(function*(){yield{namespace:{},hasTLA:false};try{env[3][0]()}catch(error){early=error.name}},()=>[provider],env,()=>{bindCalls++;return[[provider,'value'],[provider,null]]});
        \\assert.equal(sourceReads,0);assert.equal(sourceBodies,0);assert.equal(bindCalls,0);provider();assert.equal(early,'ReferenceError');assert.equal(sourceBodies,1);assert.equal(env[3][0],table.value);assert.equal(env[3][0](),42);assert.equal(env[3][1](),namespace);assert.equal(bindCalls,1);consumer();assert.equal(bindCalls,1);results.push('cycle-tdz','identity','namespace','once');
        \\let dynamicValue=7;const dynamicTable=Object.create(null);dynamicTable.value=()=>dynamicValue;const dynamicProvider=create(function*(){yield{namespace:{},bindings:dynamicTable,hasTLA:false}},()=>[]);
        \\const dynamicEnv=[null,null,null,[]];let dynamicResult;const dynamic=create(function*(){yield{namespace:{},hasTLA:false};dynamicResult=dynamicEnv[3][0]()},()=>[],dynamicEnv,()=>[[dynamicProvider,'value']]);dynamic();assert.equal(dynamicResult,7);dynamicValue=8;assert.equal(dynamicEnv[3][0](),8);results.push('dynamic','live');
        \\let getterRuns=0,invalidBody=0;const poisoned=Object.create(null);Object.defineProperty(poisoned,'value',{get(){getterRuns++;return()=>99}});const badProvider=create(function*(){yield{namespace:{},bindings:poisoned,hasTLA:false}},()=>[]);
        \\const bad=create(function*(){yield{namespace:{},hasTLA:false};invalidBody++},()=>[],[null,null,null,[]],()=>[[badProvider,'value']]);assert.throws(()=>bad(),TypeError);assert.equal(getterRuns,0);assert.equal(invalidBody,0);results.push('accessor-reject');
        \\const missing=create(function*(){yield{namespace:{},hasTLA:false};invalidBody++},()=>[],[null,null,null,[]],()=>[[dynamicProvider,'absent']]);assert.throws(()=>missing(),TypeError);assert.equal(invalidBody,0);results.push('missing-reject');
        \\const own=Object.getOwnPropertyDescriptor;Object.getOwnPropertyDescriptor=()=>{throw Error('replacement')};const capturedEnv=[null,null,null,[]];const captured=create(function*(){yield{namespace:{},hasTLA:false}},()=>[],capturedEnv,()=>[[dynamicProvider,'value']]);try{captured();assert.equal(capturedEnv[3][0](),8)}finally{Object.getOwnPropertyDescriptor=own}results.push('captured-intrinsic');
        \\console.log(JSON.stringify(results));
    ;
    for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const runtime = @import("../bundler/native_async_module_runtime.zig");
        const factory = if (minify) runtime.FACTORY_EXPRESSION_MIN else runtime.FACTORY_EXPRESSION;
        const program = try std.fmt.allocPrint(a, "const create=({s});{s}", .{ factory, checks });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", program }, .stdout_limit = .limited(16384), .stderr_limit = .limited(32768) });
        errdefer std.debug.print("cached runtime minify={} stderr={s}\n", .{ minify, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("[\"old2\",\"old3\",\"cycle-tdz\",\"identity\",\"namespace\",\"once\",\"dynamic\",\"live\",\"accessor-reject\",\"missing-reject\",\"captured-intrinsic\"]\n", actual.stdout);
        try std.testing.expectEqualStrings("", actual.stderr);
    }
}
