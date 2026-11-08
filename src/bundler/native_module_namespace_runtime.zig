//! Native module namespace reflection over lexical getter exports.
//! Runtime construction never reads a lexical binding before an actual get.
//! See ECMA-262 10.4.6; the nonconfigurable writable placeholders permit live
//! values while satisfying Proxy invariants. No source body is parsed or moved.
pub const NAMESPACE_EXPRESSION: []const u8 =
    \\(function(){
    \\  const create=Object.create,define=Object.defineProperty,own=Object.getOwnPropertyDescriptor;
    \\  const prevent=Object.preventExtensions,same=Object.is,keysOf=Reflect.ownKeys;
    \\  const defineReflect=Reflect.defineProperty,remove=Reflect.deleteProperty,apply=Reflect.apply;
    \\  const sort=Array.prototype.sort,ProxyIntrinsic=Proxy,TypeErrorIntrinsic=TypeError,tag=Symbol.toStringTag;
    \\  function data(value,writable,enumerable,configurable){return{__proto__:null,value,writable,enumerable,configurable}}
    \\  function field(descriptor,key){const item=own(descriptor,key);return item===undefined?undefined:item.value}
    \\  function copiedDescriptor(descriptor){
    \\    const result=create(null),fields=['value','writable','get','set','enumerable','configurable'];
    \\    for(let i=0;i<fields.length;i++){const key=fields[i],item=own(descriptor,key);if(item!==undefined)define(result,key,data(item.value,true,true,true))}
    \\    return result;
    \\  }
    \\  return function(getters){
    \\    const target=create(null),cached=create(null),keys=keysOf(getters);
    \\    for(let i=0;i<keys.length;i++){
    \\      const key=keys[i];
    \\      if(typeof key!=='string')throw new TypeErrorIntrinsic('A module export key must be a string');
    \\      const descriptor=own(getters,key),value=descriptor===undefined?undefined:own(descriptor,'value');
    \\      if(value===undefined||typeof value.value!=='function')throw new TypeErrorIntrinsic('A module export requires a lexical getter');
    \\      define(cached,key,data(value.value,false,false,false));
    \\    }
    \\    apply(sort,keys,[]);
    \\    for(let i=0;i<keys.length;i++)define(target,keys[i],data(undefined,true,true,false));
    \\    define(target,tag,data('Module',false,false,false));
    \\    define(keys,keys.length,data(tag,true,true,true));
    \\    prevent(target);
    \\    function exported(key){return typeof key==='string'&&own(cached,key)!==undefined}
    \\    function read(key){return apply(cached[key],undefined,[])}
    \\    return new ProxyIntrinsic(target,{
    \\      __proto__:null,
    \\      get(target,key){if(typeof key==='symbol')return key===tag?'Module':undefined;return exported(key)?read(key):undefined},
    \\      has(target,key){return typeof key==='symbol'?own(target,key)!==undefined:exported(key)},
    \\      ownKeys(){return keys},
    \\      getOwnPropertyDescriptor(target,key){
    \\        if(typeof key==='symbol')return key===tag?data('Module',false,false,false):undefined;
    \\        return exported(key)?data(read(key),true,true,false):undefined;
    \\      },
    \\      set(){return false},
    \\      defineProperty(target,key,descriptor){
    \\        if(typeof key==='symbol')return defineReflect(target,key,copiedDescriptor(descriptor));
    \\        if(!exported(key))return false;
    \\        const current=read(key);
    \\        if(field(descriptor,'configurable')===true||field(descriptor,'enumerable')===false||own(descriptor,'get')!==undefined||own(descriptor,'set')!==undefined||field(descriptor,'writable')===false)return false;
    \\        const value=own(descriptor,'value');
    \\        return value===undefined||same(value.value,current);
    \\      },
    \\      deleteProperty(target,key){return typeof key==='symbol'?remove(target,key):!exported(key)}
    \\    });
    \\  };
    \\})()
;

// Normal compiler minification handles the same semantic expression.
pub const NAMESPACE_EXPRESSION_MIN: []const u8 = NAMESPACE_EXPRESSION;

const std = @import("std");
fn printed(a: std.mem.Allocator, minify: bool) ![]const u8 {
    const program = try @import("compiler_output_program.zig").Program.create(std.testing.allocator, "module.exports=" ++ NAMESPACE_EXPRESSION ++ ";");
    defer program.destroy();
    var codegen = @import("../codegen/codegen.zig").Codegen.initWithOptions(a, &program.ast, .{
        .semantic_symbol_ids = program.analysis.symbol_ids.items,
        .semantic_symbols = program.analysis.symbols.items,
        .semantic_scope_maps = program.analysis.scope_maps.items,
        .semantic_symbol_name_overrides = &program.names,
        .minify_whitespace = minify,
        .minify_syntax = minify,
    });
    try codegen.emitExpr(try program.hostExportValue(), .comma, .{});
    return codegen.buf.items;
}
fn node(a: std.mem.Allocator, source: []const u8) !std.process.RunResult {
    return std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "--input-type=module", "-e", source }, .stdout_limit = .limited(32768), .stderr_limit = .limited(32768) });
}

// Numeric export keys are a separately adjudicated observation: Node26 lists
// canonical numeric keys in index order, Bun1.4.3 uses UTF16 order but reports a
// non-null prototype. Neither difference changes this 10.4.6 contract.
// Raw cross-runtime observations remain in issue6959-namespace-runtime evidence.
test "native module namespace runtime matches Native noninteger reflection and mutation contracts" {
    const provider = "export let value=41;export const nan=NaN;export const minus=-0;export function change(){value++}export function f(){return this===undefined};const proto=7,emoji=8,bmp=9;export{proto as '__proto__',emoji as '😀',bmp as '\\uE000'};";
    const locals = "let value=41;const nan=NaN,minus=-0,proto=7,emoji=8,bmp=9;function change(){value++}function f(){return this===undefined}";
    const table = "{value:()=>value,nan:()=>nan,minus:()=>minus,change:()=>change,f:()=>f,['__proto__']:()=>proto,'😀':()=>emoji,'\\uE000':()=>bmp}";
    const common = "const shape=d=>d===undefined?null:[typeof d.value==='number'&&Number.isNaN(d.value)?'NaN':Object.is(d.value,-0)?'-0':typeof d.value==='function'?'function':d.value,d.writable,d.enumerable,d.configurable,'get'in d,'set'in d];const key=k=>typeof k==='symbol'?String(k):k;const attempt=f=>{try{return f()}catch(e){return e.name}};";
    const probes = [_][]const u8{
        "console.log(JSON.stringify([Object.getPrototypeOf(ns)===null,Object.isExtensible(ns),Object.prototype.toString.call(ns),Reflect.ownKeys(ns).map(key),shape(Object.getOwnPropertyDescriptor(ns,'value')),shape(Object.getOwnPropertyDescriptor(ns,Symbol.toStringTag)),ns.__proto__,ns.missing]));",
        "const before=Object.getOwnPropertyDescriptor(ns,'value');ns.change();const after=Object.getOwnPropertyDescriptor(ns,'value');console.log(JSON.stringify([before.value,after.value,ns.value,ns.f(),(0,ns.f)(),Reflect.defineProperty(ns,'nan',{value:NaN}),Reflect.defineProperty(ns,'minus',{value:0}),Reflect.defineProperty(ns,'minus',{value:-0})]));",
        "console.log(JSON.stringify([Reflect.set(ns,'value',99),attempt(()=>{ns.value=99}),Reflect.set(ns,'missing',1),Reflect.deleteProperty(ns,'value'),Reflect.deleteProperty(ns,'missing'),Reflect.deleteProperty(ns,Symbol.toStringTag),Reflect.defineProperty(ns,'value',{value:41}),Reflect.defineProperty(ns,'value',{value:42}),Reflect.defineProperty(ns,'value',{writable:true}),Reflect.defineProperty(ns,'value',{writable:false}),Reflect.defineProperty(ns,'value',{configurable:false}),Reflect.defineProperty(ns,'value',{configurable:true}),Reflect.defineProperty(ns,'value',{enumerable:true}),Reflect.defineProperty(ns,'value',{enumerable:false}),Reflect.defineProperty(ns,'value',{get:undefined}),Reflect.defineProperty(ns,Symbol.toStringTag,{writable:false}),Reflect.defineProperty(ns,Symbol.toStringTag,{value:'Other'}),Reflect.defineProperty(ns,Symbol('other'),{value:1}),ns.value]));",
        "console.log(JSON.stringify([Reflect.setPrototypeOf(ns,null),Reflect.setPrototypeOf(ns,{}),Object.preventExtensions(ns)===ns,Object.isSealed(ns),Object.isFrozen(ns),attempt(()=>Object.freeze(ns)),attempt(()=>Object.seal(ns)===ns),'value'in ns,'missing'in ns,Symbol.toStringTag in ns]));",
        "const receiver={};console.log(JSON.stringify([Reflect.get(ns,'value',receiver),Reflect.set(ns,'value',7,receiver),Object.hasOwn(receiver,'value'),Reflect.get(ns,Symbol.toStringTag,receiver),Reflect.getOwnPropertyDescriptor(ns,Symbol('absent')),ns.f.call(ns),ns.f.call(undefined)]));",
        "const effects=[];const desc={get value(){effects.push('value');return 41},get enumerable(){effects.push('enum');return true}};const result=Reflect.defineProperty(ns,'value',desc);console.log(JSON.stringify([result,effects,ns.value]));",
    };
    for (probes, 0..) |probe, index| for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(provider.len));
        _ = std.base64.standard.Encoder.encode(encoded, provider);
        const native = try std.mem.concat(a, u8, &.{ "import*as ns from'data:text/javascript;base64,", encoded, "';", common, probe });
        const model = try std.mem.concat(a, u8, &.{ "const make=", try printed(a, minify), ";", locals, ";const ns=make(", table, ");", common, probe });
        const expected = try node(a, native);
        const actual = try node(a, model);
        errdefer std.debug.print("namespace probe={d} minify={} stderr={s}\nmodel={s}\n", .{ index, minify, actual.stderr, model });
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
    };
}

test "native module namespace runtime preserves actual module TDZ and hoisted function reads" {
    const probe = "function probe(ns){return[Reflect.ownKeys(ns).map(k=>typeof k==='symbol'?String(k):k),'value'in ns,attempt(()=>ns.value),attempt(()=>Object.getOwnPropertyDescriptor(ns,'value').value),attempt(()=>Object.keys(ns)),attempt(()=>Reflect.defineProperty(ns,'value',{configurable:true})),ns.hoisted()]}const attempt=f=>{try{return f()}catch(e){return e.name}};";
    for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const native = try std.mem.concat(a, u8, &.{ "import*as ns from'./entry.mjs';", probe, "const before=probe(ns);export let value=42;export function hoisted(){return 7}console.log(JSON.stringify([before,probe(ns)]));" });
        const helpers = @import("test_helpers.zig");
        try helpers.writeFile(tmp.dir, "entry.mjs", native);
        const path = try helpers.absPath(&tmp, "entry.mjs");
        defer std.testing.allocator.free(path);
        const expected = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", path }, .stdout_limit = .limited(32768), .stderr_limit = .limited(32768) });
        const model = try std.mem.concat(a, u8, &.{ "const make=", try printed(a, minify), ";", probe, "const it=(function*(){const ns=make({value:()=>value,hoisted:()=>hoisted});yield ns;let value=42;function hoisted(){return 7}})();const ns=it.next().value;const before=probe(ns);it.next();console.log(JSON.stringify([before,probe(ns)]));" });
        const actual = try node(a, model);
        try std.testing.expect(expected.term == .exited and expected.term.exited == 0);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
    }
}

test "native module namespace runtime keeps specified UTF16 key order including numeric names" {
    for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.mem.concat(a, u8, &.{ "const make=", try printed(a, minify), ";const ns=make({'2':()=>2,'10':()=>10,z:()=>0,'01':()=>1,'😀':()=>0,'\\uE000':()=>0});console.log(JSON.stringify(Reflect.ownKeys(ns).map(k=>typeof k==='symbol'?String(k):k)));" });
        const actual = try node(a, source);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("[\"01\",\"10\",\"2\",\"z\",\"😀\",\"\",\"Symbol(Symbol.toStringTag)\"]\n", actual.stdout);
        try std.testing.expectEqualStrings("", actual.stderr);
    }
}

test "native module namespace runtime captures intrinsics and rejects metadata accessors without invoking them" {
    const exercise =
        \\const saved={create:Object.create,define:Object.defineProperty,own:Object.getOwnPropertyDescriptor,prevent:Object.preventExtensions,same:Object.is,keys:Reflect.ownKeys,reflectDefine:Reflect.defineProperty,remove:Reflect.deleteProperty,apply:Reflect.apply,sort:Array.prototype.sort,Proxy,Symbol,TypeError};
        \\let touched=0,value=42;const getter=()=>value;getter.call=()=>{throw 'own-call'};const table={value:getter};const invalid={get x(){touched++;return()=>1}};
        \\const trap=()=>{throw 'intrinsic-trap'};let result;try{
        \\saved.define(Object.prototype,'get',{configurable:true,get(){throw 'prototype-get'}});
        \\Object.create=Object.defineProperty=Object.getOwnPropertyDescriptor=Object.preventExtensions=Object.is=trap;Reflect.ownKeys=Reflect.defineProperty=Reflect.deleteProperty=Reflect.apply=trap;Array.prototype.sort=trap;globalThis.Proxy=globalThis.Symbol=globalThis.TypeError=trap;
        \\const ns=make(table);value=43;let rejected=false;try{make(invalid)}catch(e){rejected=e instanceof saved.TypeError}
        \\result=[ns.value,saved.own(ns,'value').value,saved.reflectDefine(ns,'value',{__proto__:null,value:43}),saved.reflectDefine(ns,saved.Symbol.toStringTag,{__proto__:null,writable:false}),saved.remove(ns,'value'),touched,rejected];
        \\}finally{Object.create=saved.create;Object.defineProperty=saved.define;Object.getOwnPropertyDescriptor=saved.own;Object.preventExtensions=saved.prevent;Object.is=saved.same;Reflect.ownKeys=saved.keys;Reflect.defineProperty=saved.reflectDefine;Reflect.deleteProperty=saved.remove;Reflect.apply=saved.apply;Array.prototype.sort=saved.sort;globalThis.Proxy=saved.Proxy;globalThis.Symbol=saved.Symbol;globalThis.TypeError=saved.TypeError;delete Object.prototype.get}
        \\console.log(JSON.stringify(result));
    ;
    for ([_]bool{ false, true }) |minify| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const source = try std.mem.concat(a, u8, &.{ "const make=", try printed(a, minify), ";", exercise });
        const actual = try node(a, source);
        errdefer std.debug.print("namespace capture minify={} stderr={s}\n", .{ minify, actual.stderr });
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings("[43,43,true,true,false,0,true]\n", actual.stdout);
        try std.testing.expectEqualStrings("", actual.stderr);
    }
}
