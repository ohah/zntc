const std = @import("std");

test "retained field arrow owns creation site receiver across seventy three contexts" {
    const Case = struct { name: []const u8, source: []const u8, native_generator: bool = false, native_block_scoping: bool = false };
    const cases = [_]Case{
        .{ .name = "implicit base", .source = "class Box{value=7;read=()=>this.value}console.log(new Box().read());" },
        .{ .name = "constructor before fields", .source = "class Box{constructor(){this.other=2}value=7;read=()=>this.value}const box=new Box();console.log(box.read(),box.other);" },
        .{ .name = "constructor body and field arrows", .source = "class Box{value=7;read=()=>this.value;constructor(){this.body=()=>this.value}}const box=new Box();console.log(box.read(),box.body());" },
        .{ .name = "constructor collision", .source = "class Box{value=7;read=()=>this.value;constructor(_this){this.other=_this}}const box=new Box(11);console.log(box.read(),box.other);" },
        .{ .name = "shared nested field arrows", .source = "class Box{value=7;first=()=>this.value;second=()=>()=>this.value+1}const box=new Box();console.log(box.first(),box.second()());" },
        .{ .name = "implicit derived", .source = "class Parent{constructor(){this.base=1}}class Box extends Parent{value=7;read=()=>[this.value,this.base]}console.log(JSON.stringify(new Box().read()));" },
        .{ .name = "explicit derived", .source = "class Parent{constructor(){this.base=1}}class Box extends Parent{value=7;read=()=>this.value;constructor(){super();this.extra=2}}const box=new Box();console.log(box.read(),box.extra);" },
        .{ .name = "replacement super object", .source = "class Parent{constructor(){return{value:4}}}class Box extends Parent{value=7;read=()=>this.value}const box=new Box();console.log(box.read(),box.value);" },
        .{ .name = "outer frame restoration", .source = "function build(){const outer=()=>this;class Box{value=7;read=()=>this.value}return[outer().tag,new Box().read()]}console.log(JSON.stringify(build.call({tag:\"outer\"})));" },
        .{ .name = "field newtarget", .source = "class Box{value=7;read=()=>[this.value,new.target];constructor(){this.actual=new.target}}const box=new Box();console.log(JSON.stringify([box.read(),box.actual===Box]));" },
        .{ .name = "async field arrow", .source = "class Box{value=7;read=async()=>this.value}new Box().read().then(value=>console.log(value));" },
        .{ .name = "nested ordinary function boundary", .source = "class Box{read=(function(){return()=>this.value}).call({value:9})}console.log(new Box().read());" },
        .{ .name = "static field receiver", .source = "class Box{static value=9;static read=()=>this.value}console.log(Box.read());" },
        .{ .name = "literal inferred function name", .source = "class Box{read=()=>this}const box=new Box();console.log(box.read.name,box.read()===box);" },
        .{ .name = "computed inferred function name", .source = "let keyCalls=0;class Box{[(keyCalls++,\"read\")]=()=>this}const box=new Box();console.log(keyCalls,box.read.name,box.read()===box);" },
        .{ .name = "per class computed name", .source = "let key=\"first\";const make=()=>class{[key]=()=>this};const First=make();key=\"second\";const Second=make();const a=new First(),b=new Second();console.log(a.first.name,b.second.name,a.first()===a,b.second()===b);" },
        .{ .name = "nested computed class key receiver", .source = "class Box{value=\"key\";read=()=>class{[this.value](){return 7}}}const C=new Box().read();console.log(new C().key());" },
        .{ .name = "lexical super field arrow", .source = "class Parent{get value(){return this.own}}class Box extends Parent{own=11;read=()=>super.value}console.log(new Box().read());" },
        .{ .name = "super getter method receiver", .source = "class Parent{get method(){return()=>this.own}}class Box extends Parent{own=11;read=()=>super.method()}console.log(new Box().read());" },
        .{ .name = "super computed method receiver", .source = "class Parent{method(){return this.own}}class Box extends Parent{own=12;read=()=>super[\"method\"]()}console.log(new Box().read());" },
        .{ .name = "super write receiver", .source = "class Parent{set value(v){this.own=v}}class Box extends Parent{read=()=>super.value=13}const box=new Box();console.log(box.read(),box.own);" },
        .{ .name = "super compound update", .source = "class Parent{get value(){return this.own}set value(v){this.own=v}}class Box extends Parent{own=5;read=()=>++super.value}const box=new Box();console.log(box.read(),box.own);" },
        .{ .name = "dynamic instance home prototype", .source = "class Parent{get value(){return this.own}}class Box extends Parent{own=7;read=()=>super.value}const box=new Box();Object.setPrototypeOf(Box.prototype,{get value(){return this.own+1}});console.log(box.read());" },
        .{ .name = "static super home receiver", .source = "class Parent{static get value(){return this.own}}class Box extends Parent{static own=14;static read=()=>super.value}console.log(Box.read());" },
        .{ .name = "anonymous class super receiver", .source = "class Parent{get value(){return this.own}}const Box=class extends Parent{own=15;read=()=>super.value};console.log(new Box().read());" },
        .{ .name = "extends alias mutation", .source = "class Parent{get value(){return this.own}}let Base=Parent;class Box extends Base{own=16;read=()=>super.value}Base=class{get value(){return 0}};console.log(new Box().read());" },
        .{ .name = "symbol computed field name", .source = "const key=Symbol(\"read\");class Box{[key]=()=>this};const box=new Box();console.log(box[key].name,box[key]()===box);" },
        .{ .name = "property key coercion once", .source = "let calls=0;const key={[Symbol.toPrimitive](){calls++;return \"read\"}};class Box{[key]=()=>this};const a=new Box(),b=new Box();console.log(calls,a.read.name,b.read.name,a.read()===a,b.read()===b);" },
        .{ .name = "proto computed field name", .source = "class Box{[\"__proto__\"]=()=>this};const box=new Box();console.log(box.__proto__.name,box.__proto__()===box,Object.getPrototypeOf(box)===Box.prototype);" },
        .{ .name = "repeated class site loop", .source = "const all=[];for(let i=0;i<3;i++){const C=class{[\"read\"+i]=()=>this};all.push(C)}console.log(all.map((C,i)=>{const x=new C();return x[\"read\"+i].name+\":\"+(x[\"read\"+i]()===x)}).join(\",\"));" },
        .{ .name = "inferred class name before static evaluation", .source = "const Box=class{[\"read\"]=()=>this;static seen=this.name};console.log(Box.name,Box.seen,new Box().read.name);" },
        .{ .name = "anonymous class name before static evaluation", .source = "function make(){return class{[\"read\"]=()=>this;static seen=this.name}}const C=make();console.log(JSON.stringify([C.name,C.seen,new C().read.name]));" },
        .{ .name = "class declaration TDZ", .source = "try{console.log(Box)}catch(e){console.log(e.name)}class Box{[\"read\"]=()=>this};console.log(new Box().read.name);" },
        .{ .name = "program this in computed key", .source = "this.key=\"read\";class Box{[this.key]=()=>this};console.log(new Box().read.name);" },
        .{ .name = "outer function this and arguments in key", .source = "function make(key){return class{[this.prefix+arguments[0]]=()=>this}}const C=make.call({prefix:\"read\"},\"X\");const box=new C();console.log(box.readX.name,box.readX()===box);" },
        .{ .name = "yield in computed class key", .source = "function* make(){return class{[yield \"key\"]=()=>this}}const g=make();console.log(g.next().value);const C=g.next(\"read\").value;const box=new C();console.log(box.read.name,box.read()===box);" },
        .{ .name = "await in computed class key", .source = "async function make(){return class{[await Promise.resolve(\"read\")]=()=>this}}make().then(C=>{const box=new C();console.log(box.read.name,box.read()===box)});" },
        .{ .name = "derived pre-super key ordering", .source = "class Parent{};class Box extends Parent{constructor(){try{const C=class extends (()=>{throw Error(\"heritage\")})(){[this.key]=()=>this}}catch(e){console.log(e.message)}super()}}new Box();" },
        .{ .name = "name parameter source shadow", .source = "const _nameKey=19;class Box{[\"read\"]=()=>[this,_nameKey]}const box=new Box();console.log(box.read.name,box.read()[0]===box,box.read()[1]);" },
        .{ .name = "await key in direct variable initialization", .source = "async function make(){const C=class{[await Promise.resolve(\"read\")]=()=>this};return C}make().then(C=>{const box=new C();console.log(box.read.name,box.read()===box)});" },
        .{ .name = "await key in direct class declaration", .source = "async function make(){class C{[await Promise.resolve(\"read\")]=()=>this}return C}make().then(C=>{const box=new C();console.log(box.read.name,box.read()===box)});" },
        .{ .name = "await key microtask order", .source = "const trace=[];async function make(){const C=class{[await Promise.resolve(\"read\")]=()=>this};trace.push(\"class\");return C}make().then(C=>{trace.push(new C().read.name)});Promise.resolve().then(()=>trace.push(\"a\")).then(()=>trace.push(\"b\")).then(()=>trace.push(\"c\"));setTimeout(()=>console.log(trace.join(\",\")),0);" },
        .{ .name = "await key inside single lexical block", .source = "async function make(){{const C=class{[await Promise.resolve(\"read\")]=()=>this};return C}}make().then(C=>{const box=new C();console.log(box.read.name,box.read()===box)});" },
        .{ .name = "await key in class argument", .source = "async function make(){const all=[class{[await Promise.resolve(\"read\")]=()=>this}];return all[0]}make().then(C=>{const box=new C();console.log(box.read.name,box.read()===box)});" },
        .{ .name = "await key in switch case", .source = "async function make(){switch(1){case 1:return class{[await Promise.resolve(\"read\")]=()=>this}}}make().then(C=>{const box=new C();console.log(box.read.name,box.read()===box)});" },
        .{ .name = "await key inside catch region", .source = "async function make(){try{throw 1}catch(e){return class{[await Promise.resolve(\"read\")]=()=>this}}}make().then(C=>{const box=new C();console.log(box.read.name,box.read()===box)});" },
        .{ .name = "await key in repeated loop", .source = "async function make(){const all=[];for(let i=0;i<2;i++){all.push(class{[await Promise.resolve(\"read\"+i)]=()=>this})}return all}make().then(all=>console.log(all.map((C,i)=>{const x=new C();return x[\"read\"+i].name+\":\"+(x[\"read\"+i]()===x)}).join(\",\")));" },
        .{ .name = "yield key in repeated loop", .source = "function* make(){const all=[];for(let i=0;i<2;i++){all.push(class{[yield i]=()=>this})}return all}const g=make();console.log(g.next().value,g.next(\"first\").value);const all=g.next(\"second\").value;console.log(new all[0]().first.name,new all[1]().second.name);" },
        .{ .name = "await loop microtask order", .source = "const trace=[];async function make(){for(let i=0;i<2;i++){const C=class{[await Promise.resolve(\"read\"+i)]=()=>this};trace.push(new C()[\"read\"+i].name)}trace.push(\"done\")}make();Promise.resolve().then(()=>trace.push(\"a\")).then(()=>trace.push(\"b\")).then(()=>trace.push(\"c\")).then(()=>trace.push(\"d\"));setTimeout(()=>console.log(trace.join(\",\")),0);" },
        .{ .name = "await class declaration in while", .source = "async function make(){const all=[];let i=0;while(i<2){class C{[await Promise.resolve(\"read\"+i++)]=()=>this}all.push(C)}return all}make().then(all=>console.log(new all[0]().read0.name,new all[1]().read1.name));" },
        .{ .name = "await class in for of", .source = "async function make(){const all=[];for(const key of [\"first\",\"second\"]){all.push(class{[await Promise.resolve(key)]=()=>this})}return all}make().then(all=>console.log(new all[0]().first.name,new all[1]().second.name));" },
        .{ .name = "native generator repeated key", .source = "function* make(){const all=[];for(let i=0;i<2;i++){all.push(class{[yield i]=()=>this})}return all}const g=make();console.log(g.next().value,g.next(\"first\").value);const all=g.next(\"second\").value;console.log(new all[0]().first.name,new all[1]().second.name);", .native_generator = true },
        .{ .name = "await rejection caught in loop", .source = "async function make(){const trace=[];for(let i=0;i<2;i++){try{class C{[await (i?Promise.resolve(\"read\"):Promise.reject(Error(\"bad\")))]=()=>this}trace.push(new C().read.name)}catch(e){trace.push(e.message)}}console.log(trace.join(\",\"))}make();" },
        .{ .name = "await loop finally suspends", .source = "async function make(){const trace=[];for(let i=0;i<2;i++){try{class C{[await Promise.resolve(\"read\"+i)]=()=>this}trace.push(new C()[\"read\"+i].name)}finally{trace.push(await Promise.resolve(\"finally\"+i))}}console.log(trace.join(\",\"))}make();" },
        .{ .name = "await loop break and continue", .source = "async function make(){const all=[];for(let i=0;i<5;i++){class C{[await Promise.resolve(\"read\"+i)]=()=>this}if(i===1)continue;all.push(C);if(i===2)break}return all}make().then(all=>console.log(new all[0]().read0.name,new all[1]().read2.name));" },
        .{ .name = "await loop return value", .source = "async function make(){for(let i=0;i<2;i++){class C{[await Promise.resolve(\"read\"+i)]=()=>this}return C}}make().then(C=>console.log(new C().read0.name));" },
        .{ .name = "await nested loops", .source = "async function make(){const all=[];for(let i=0;i<2;i++){for(let j=0;j<2;j++){all.push(class{[await Promise.resolve(\"read\"+i+j)]=()=>this})}}return all}make().then(all=>console.log(all.map((C,i)=>new C()[\"read\"+Math.floor(i/2)+i%2].name).join(\",\")));" },
        .{ .name = "unbraced await loop class argument", .source = "async function make(){const all=[];for(let i=0;i<2;i++)all.push(class{[await Promise.resolve(\"read\"+i)]=()=>this});return all}make().then(all=>console.log(new all[0]().read0.name,new all[1]().read1.name));" },
        .{ .name = "native generator outer lexical key", .source = "function* make(suffix){const all=[];for(let i=0;i<2;i++){all.push(class{[yield this.prefix+arguments[0]+i]=()=>this})}return all}const g=make.call({prefix:\"p\"},\"x\");console.log(g.next().value,g.next(\"first\").value);const all=g.next(\"second\").value;console.log(new all[0]().first.name,new all[1]().second.name);", .native_generator = true },
        .{ .name = "await key source arguments", .source = "async function make(suffix){const all=[];for(let i=0;i<2;i++){all.push(class{[await Promise.resolve(arguments[0]+i)]=()=>this})}return all}make(\"read\").then(all=>console.log(new all[0]().read0.name,new all[1]().read1.name));" },
        .{ .name = "await key source this and arguments", .source = "async function make(suffix){const all=[];for(let i=0;i<2;i++){all.push(class{[await Promise.resolve(this.prefix+arguments[0]+i)]=()=>this})}return all}make.call({prefix:\"p\"},\"x\").then(all=>console.log(new all[0]().px0.name,new all[1]().px1.name));" },
        .{ .name = "native generator helper async loop", .source = "async function make(){const all=[];for(let i=0;i<2;i++){all.push(class{[await Promise.resolve(\"read\"+i)]=()=>this})}return all}make().then(all=>console.log(new all[0]().read0.name,new all[1]().read1.name));", .native_generator = true },
        .{ .name = "native generator helper method await key", .source = "async function make(){const all=[];for(let i=0;i<2;i++){all.push(class{[\"read\"+i]=()=>this;[await Promise.resolve(\"method\")](){return 7}})}return all}make().then(all=>console.log(new all[0]().read0.name,new all[1]().method()));", .native_generator = true },
        .{ .name = "nested loop field captures outer index", .source = "async function make(){const all=[];for(let i=0;i<2;i++){for(let j=0;j<2;j++){all.push(class{[await Promise.resolve(\"read\"+i+j)]=()=>[this,i]})}}return all}make().then(all=>console.log(all.map((C,n)=>{const x=new C(),f=x[\"read\"+Math.floor(n/2)+n%2];return f()[0]===x&&f()[1]===Math.floor(n/2)}).join(\",\")));" },
        .{ .name = "function key and super compound temps", .source = "function make(){class P{get value(){return this.own}set value(v){this.own=v}}return class C extends P{own=1;[\"read\"]=()=>++super.value}}const C=make(),x=new C();console.log(x.read.name,x.read(),x.read());" },
        .{ .name = "native generator mutable arguments", .source = "function* make(){const all=[];for(let i=0;i<2;i++){yield i;arguments=[\"changed\"];all.push(class{[yield arguments[0]+i]=()=>this})}return all}const g=make(\"initial\");console.log(g.next().value,g.next().value,g.next(\"first\").value,g.next().value);const all=g.next(\"second\").value;console.log(new all[0]().first.name,new all[1]().second.name);", .native_generator = true },
        .{ .name = "implicit field capture async order", .source = "const trace=[];async function make(){const all=[];for(let i=0;i<2;i++){await Promise.resolve();all.push(class{value=i;read=()=>this});trace.push(i)}trace.push(\"done\");console.log(all.map(C=>new C().value).join(\",\"))}make();Promise.resolve().then(()=>trace.push(\"a\")).then(()=>trace.push(\"b\")).then(()=>trace.push(\"c\")).then(()=>trace.push(\"d\"));setTimeout(()=>console.log(trace.join(\",\")),0);" },
        .{ .name = "native block async key loop", .source = "async function make(){const all=[];for(let i=0;i<2;i++)all.push(class{[await Promise.resolve(\"read\"+i)]=()=>this});return all}make().then(all=>console.log(new all[0]().read0.name,new all[1]().read1.name));", .native_block_scoping = true },
        .{ .name = "native block yield key loop", .source = "function* make(){const all=[];for(let i=0;i<2;i++){all.push(class{[yield i]=()=>this})}return all}const g=make();console.log(g.next().value,g.next(\"first\").value);const all=g.next(\"second\").value;console.log(new all[0]().first.name,new all[1]().second.name);", .native_generator = true, .native_block_scoping = true },
        .{ .name = "native block while async key", .source = "async function make(){const all=[];let i=0;while(i<2){class C{[await Promise.resolve(\"read\"+i++)]=()=>this}all.push(C)}return all}make().then(all=>console.log(new all[0]().read0.name,new all[1]().read1.name));", .native_block_scoping = true },
        .{ .name = "native block for of async key", .source = "async function make(){const all=[];for(const key of [\"first\",\"second\"]){all.push(class{[await Promise.resolve(key)]=()=>this})}return all}make().then(all=>console.log(new all[0]().first.name,new all[1]().second.name));", .native_block_scoping = true },
        .{ .name = "await loop function declaration identity", .source = "\"use strict\";async function make(){for(let i=0;i<1;i++){function read(){return i}const saved=read;class C{[await Promise.resolve(\"field\")]=()=>this}console.log(saved===read,read(),new C().field.name)}}make();" },
        .{ .name = "multiple key cells in class", .source = "class C{[\"left\"]=()=>this;[\"right\"]=()=>this}const box=new C();console.log(box.left.name,box.right.name,box.left()===box,box.right()===box);" },
    };
    var mismatches: usize = 0;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", case.source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        try std.testing.expectEqual(@as(u8, 0), native.term.exited);
        for ([_]bool{true}) |define| for ([_]bool{ false, true }) |minify| {
            std.debug.print("field capture running {s} define={any} minify={any}\n", .{ case.name, define, minify });
            var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
            if (case.native_generator) unsupported.generator = false;
            if (case.native_block_scoping) unsupported.block_scoping = false;
            const result = try @import("../transpile.zig").transpile(a, case.source, "input.cjs", .{
                .unsupported = unsupported,
                .use_define_for_class_fields = define,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            if (case.native_generator) try std.testing.expect(std.mem.indexOf(u8, result.code, "=>") == null);
            const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", result.code }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("case:{s} define={any} minify={any}\nsource:{s}\noutput:{s}\nexpected:{s}actual:{s}stderr:{s}\n", .{ case.name, define, minify, case.source, result.code, native.stdout, actual.stdout, actual.stderr });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) mismatches += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "retained field arrow has exact factory bindings and references before final output walk" {
    const ast = @import("../parser/ast.zig");
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    for ([_]u8{ 0, 1, 2 }) |variant| {
        const computed = variant != 0;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, if (variant == 2) "function make(){class A{['read']=()=>this};class B extends A{['read']=()=>[super.read,eval('0')]}return B}" else if (computed) "class A{['read']=()=>this};class B extends A{['read']=()=>[super.read,eval('0')]}" else "class A{read=()=>this};class B extends A{read=()=>[super.read,eval('0')]}");
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        const source_symbol_count = analyzer.symbols.items.len;
        const source_node_count = parser.ast.nodes.items.len;
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{
            .unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80),
            .use_define_for_class_fields = true,
        });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.class_self_symbol_map = analyzer.class_self_symbol_map;
        t.node_scope_provenance = analyzer.node_scope_provenance;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        // Deliberately inspect producer output before finishSemanticEdit's walker.
        try std.testing.expect(t.retained_field_this_plan == null);
        try std.testing.expectEqual(@as(u32, 0), t.retained_field_initializer_frame);
        const editor = &t.semantic_editor.?;
        var captures: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var owners: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var key_slots: std.AutoHashMapUnmanaged(u32, void) = .empty;
        var eval_owners: usize = 0;
        for (editor.symbols.items[source_symbol_count..], source_symbol_count..) |symbol, id| {
            if (symbol.kind == .variable_let or symbol.kind == .variable_var) {
                try std.testing.expectEqual(.function, editor.scopes.items[symbol.scope_id.toIndex()].kind);
                try key_slots.put(a, @intCast(id), {});
                continue;
            }
            if (symbol.kind != .parameter) continue;
            try std.testing.expectEqual(.function, editor.scopes.items[symbol.scope_id.toIndex()].kind);
            const parent = editor.scopes.items[symbol.scope_id.toIndex()].parent;
            try std.testing.expectEqual(.class_body, editor.scopes.items[parent.toIndex()].kind);
            if (editor.scopes.items[symbol.scope_id.toIndex()].subtree_has_direct_eval) eval_owners += 1;
            try std.testing.expect(!editor.scopes.items[symbol.scope_id.toIndex()].subtree_has_with);
            try captures.put(a, @intCast(id), {});
            try owners.put(a, @backingInt(symbol.scope_id), {});
        }
        try std.testing.expectEqual(@as(usize, if (computed) 4 else 2), captures.count());
        try std.testing.expectEqual(@as(usize, if (computed) 2 else 0), key_slots.count());
        try std.testing.expectEqual(@as(usize, 2), owners.count());
        try std.testing.expectEqual(@as(usize, if (computed) 2 else 1), eval_owners);
        const Work = struct { node: ast.NodeIndex, scope: ScopeId };
        var stack: std.ArrayList(Work) = .empty;
        try stack.append(a, .{ .node = output, .scope = @fromBackingInt(0) });
        var bindings: usize = 0;
        var references: usize = 0;
        var home_reads: usize = 0;
        var key_bindings: usize = 0;
        var key_reads: usize = 0;
        var key_writes: usize = 0;
        while (stack.pop()) |work| {
            if (work.node.isNone()) continue;
            const node = t.ast.getNode(work.node);
            const scope = t.outputOwnedScope(work.node) orelse work.scope;
            if (t.getSymbolIdAt(work.node)) |id| if (captures.contains(id)) {
                if (node.tag == .binding_identifier) {
                    try std.testing.expectEqual(scope, editor.symbols.items[id].scope_id);
                    bindings += 1;
                } else if (node.tag == .identifier_reference) {
                    const ref = (try editor.referenceForNode(work.node)) orelse return error.MissingFactoryReferenceAtBirth;
                    try std.testing.expectEqual(id, @backingInt(ref.symbol_id));
                    try std.testing.expectEqual(scope, ref.scope_id);
                    try std.testing.expect(ref.flags.read and !ref.flags.write);
                    references += 1;
                }
            };
            if (t.getSymbolIdAt(work.node)) |id| if (key_slots.contains(id)) {
                if (node.tag == .binding_identifier) {
                    try std.testing.expectEqual(scope, editor.symbols.items[id].scope_id);
                    key_bindings += 1;
                } else if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
                    const ref = (try editor.referenceForNode(work.node)) orelse return error.MissingKeyReferenceAtBirth;
                    try std.testing.expectEqual(id, @backingInt(ref.symbol_id));
                    try std.testing.expectEqual(scope, ref.scope_id);
                    try std.testing.expect(ref.flags.read != ref.flags.write);
                    if (ref.flags.read) key_reads += 1 else key_writes += 1;
                }
            };
            if (@backingInt(work.node) >= source_node_count and node.tag == .identifier_reference) {
                if (t.getSymbolIdAt(work.node)) |id| {
                    var homes = t.class_self_symbol_map.valueIterator();
                    while (homes.next()) |home| if (home.* == id) {
                        const ref = (try editor.referenceForNode(work.node)) orelse return error.MissingHomeReferenceAtBirth;
                        try std.testing.expectEqual(id, @backingInt(ref.symbol_id));
                        try std.testing.expectEqual(scope, ref.scope_id);
                        try std.testing.expect(ref.flags.read and !ref.flags.write);
                        home_reads += 1;
                    };
                }
            }
            var children = @import("../parser/ast_walk.zig").children(t.ast, node);
            while (children.next()) |child| try stack.append(a, .{ .node = child, .scope = scope });
        }
        try std.testing.expectEqual(@as(usize, if (computed) 4 else 2), bindings);
        try std.testing.expectEqual(@as(usize, if (computed) 6 else 2), references);
        try std.testing.expectEqual(@as(usize, 1), home_reads);
        try std.testing.expectEqual(@as(usize, if (computed) 2 else 0), key_bindings);
        try std.testing.expectEqual(@as(usize, if (computed) 2 else 0), key_reads);
        try std.testing.expectEqual(@as(usize, if (computed) 2 else 0), key_writes);
    }
}

test "retained field arrow low-level graphless receiver and loop output stays executable" {
    const sources = [_][]const u8{
        "class Box{value=7;read=()=>this.value}console.log(new Box().read());",
        "function build(){class Box{value=8;read=()=>this.value}return new Box().read()}console.log(build.call({value:1}));",
        "class Box{value=9;read=()=>()=>this.value}console.log(new Box().read()());",
        "const trace=[];async function make(){const all=[];for(let i=0;i<2;i++){await Promise.resolve();all.push(()=>i);trace.push(i)}trace.push(all.map(read=>read()).join(':'))}make();Promise.resolve().then(()=>trace.push('a')).then(()=>trace.push('b')).then(()=>trace.push('c'));setTimeout(()=>console.log(trace.join(',')),0);",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        _ = try parser.parse();
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{
            .unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80),
            .use_define_for_class_fields = true,
        });
        const root = try t.transform();
        try std.testing.expect(!t.semantic_edit_enabled and t.semantic_editor == null);
        var codegen = @import("../codegen/mod.zig").Codegen.init(a, t.ast);
        const body = try codegen.generate(root);
        var helper_code: std.ArrayList(u8) = .empty;
        try @import("../bundler/runtime_helpers.zig").appendRuntimeHelpers(&helper_code, a, t.runtime_helpers, false, t.runtime_es5_compat);
        const output = try std.fmt.allocPrint(a, "{s}{s}", .{ helper_code.items, body });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", source }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", output }, .stdout_limit = .limited(16384), .stderr_limit = .limited(16384) });
        if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout)) std.debug.print("graphless source:{s}\noutput:{s}\nexpected:{s}actual:{s}stderr:{s}\n", .{ source, output, native.stdout, actual.stdout, actual.stderr });
        try std.testing.expectEqual(@as(u8, 0), actual.term.exited);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
    }
}

test "retained loop key cells retain exact owners before final output walk" {
    const ast = @import("../parser/ast.zig");
    const ScopeId = @import("../semantic/scope.zig").ScopeId;
    const sources = [_][]const u8{
        "async function make(){const all=[];for(let i=0;i<2;i++){all.push(class{[await Promise.resolve('read'+i)]=()=>this})}return all}",
        "async function make(){const all=[];for(let i=0;i<2;i++)all.push(class{[await Promise.resolve('read'+i)]=()=>this});return all}",
        "async function make(){const all=[];for(let i=0;i<2;i++){all.push(class{[await Promise.resolve('read'+i)]=()=>this})}return all}",
        "function* make(){const all=[];for(let i=0;i<2;i++){all.push(class{[yield i]=()=>this})}return all}",
        "async function make(){const all=[];for(let i=0;i<2;i++){for(let j=0;j<2;j++){all.push(class{[await Promise.resolve('read'+i+j)]=()=>[this,i]})}}return all}",
        "async function make(){const all=[];for(let i=0;i<2;i++)all.push(class{[await Promise.resolve('read'+i)]=()=>this});return all}",
        "function* make(){const all=[];for(let i=0;i<2;i++){all.push(class{[yield i]=()=>this})}return all}",
        "async function make(){const all=[];for(const key of ['first','second']){all.push(class{[await Promise.resolve(key)]=()=>this})}return all}",
    };
    for (sources, 0..) |source, profile| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var scanner = try @import("../lexer/scanner.zig").Scanner.init(a, source);
        var parser = @import("../parser/parser.zig").Parser.init(a, &scanner);
        parser.configureFromExtension(".cjs");
        const root = try parser.parse();
        var analyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer.init(a, &parser.ast);
        try analyzer.analyze();
        const source_symbols = analyzer.symbols.items.len;
        var unsupported = @import("transformer.zig").TransformOptions.compat.fromReactNativeVersion(0, 80);
        if (profile == 2 or profile == 3 or profile == 6) unsupported.generator = false;
        if (profile >= 5) unsupported.block_scoping = false;
        var t = try @import("transformer.zig").Transformer.init(a, &parser.ast, .{
            .unsupported = unsupported,
            .use_define_for_class_fields = true,
        });
        try t.initSymbolIds(analyzer.symbol_ids.items);
        t.symbols = analyzer.symbols.items;
        t.references = analyzer.references.items;
        t.scopes = analyzer.scopes.items;
        t.scope_maps = analyzer.scope_maps.items;
        t.scope_owner_map = analyzer.scope_owner_map;
        t.class_self_symbol_map = analyzer.class_self_symbol_map;
        t.node_scope_provenance = analyzer.node_scope_provenance;
        t.unresolved_references = &analyzer.unresolved_references;
        t.semantic_edit_enabled = true;
        try t.buildBlockRenameMap();
        const output = try t.visitNode(root);
        try std.testing.expectEqual(@as(u32, 1), t.retained_loop_key_cells.count());
        var planned = t.retained_loop_key_cells.valueIterator();
        const cells = planned.next().?.*;
        try std.testing.expectEqual(@as(usize, 1), cells.len);
        const sid = @backingInt(cells[0].capture.symbol_id.?);
        const editor = &t.semantic_editor.?;
        const Work = struct { node: ast.NodeIndex, scope: ScopeId };
        var stack: std.ArrayList(Work) = .empty;
        try stack.append(a, .{ .node = output, .scope = @fromBackingInt(0) });
        var bindings: usize = 0;
        var reads: usize = 0;
        var writes: usize = 0;
        while (stack.pop()) |work| {
            if (work.node.isNone()) continue;
            const node = t.ast.getNode(work.node);
            const scope = t.outputOwnedScope(work.node) orelse work.scope;
            if (node.tag == .binding_identifier) {
                if (t.getSymbolIdAt(work.node)) |binding_sid| {
                    if (binding_sid >= source_symbols and editor.symbols.items[binding_sid].kind == .variable_var)
                        try std.testing.expectEqual(t.nearestVarScope(scope), editor.symbols.items[binding_sid].scope_id);
                }
            }
            if (t.getSymbolIdAt(work.node)) |generated_sid| {
                if (generated_sid >= source_symbols) {
                    const generated = editor.symbols.items[generated_sid];
                    if (node.tag == .binding_identifier and
                        (generated.kind == .parameter or generated.kind == .catch_binding or generated.kind == .variable_let))
                        try std.testing.expectEqual(scope, generated.scope_id);
                    if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
                        const reference = (try editor.referenceForNode(work.node)) orelse return error.MissingDriverReferenceAtBirth;
                        try std.testing.expectEqual(generated_sid, @backingInt(reference.symbol_id));
                        if (scope != reference.scope_id) std.debug.print("driver owner profile={d} node={d} name={s} sid={d} kind={s} physical={d} ref={d}\n", .{ profile, @backingInt(work.node), t.ast.getText(node.span), generated_sid, @tagName(generated.kind), scope.toIndex(), reference.scope_id.toIndex() });
                        try std.testing.expectEqual(scope, reference.scope_id);
                    }
                }
            }
            if (t.getSymbolIdAt(work.node) == sid) {
                if (node.tag == .binding_identifier) {
                    try std.testing.expectEqual(if (editor.symbols.items[sid].kind == .variable_let) scope else t.nearestVarScope(scope), editor.symbols.items[sid].scope_id);
                    bindings += 1;
                } else if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
                    const reference = (try editor.referenceForNode(work.node)) orelse return error.MissingLoopKeyReferenceAtBirth;
                    try std.testing.expectEqual(scope, reference.scope_id);
                    try std.testing.expectEqual(sid, @backingInt(reference.symbol_id));
                    try std.testing.expect(reference.flags.read != reference.flags.write);
                    if (reference.flags.read) reads += 1 else writes += 1;
                }
            }
            var children = @import("../parser/ast_walk.zig").children(t.ast, node);
            while (children.next()) |child| {
                const skips = @import("transformer/semantic_edit.zig").childSkipsOutputScope(t.ast, @backingInt(work.node), @backingInt(child));
                try stack.append(a, .{ .node = child, .scope = if (skips) work.scope else scope });
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expect(reads > 0);
        try std.testing.expect(writes > 0);
        try std.testing.expectEqual(@as(usize, 0), t.deferred_generator_loop_migrations.count());
    }
}
