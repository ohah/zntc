const std = @import("std");

test "lazy iterator Reference consumers preserve call argument and callee evaluation" {
    const Case = struct { name: []const u8, source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .name = "argument-abrupt", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};const target={get run(){log.push(\"callee\");return function(){log.push(\"call\")}}};try{target.run(([first=fail(),second]=source()))}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"callee\",\"iter\",\"next\",\"default\",\"close\",\"failure\"]\n" },
        .{ .name = "argument-order", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};const target={get run(){log.push(\"callee\");return function(){log.push(\"call\",arguments[1]===last)}}};target.run(log.push(\"before\"),([first=(log.push(\"default\"),42),second]=source()),log.push(\"after\"));console.log(JSON.stringify(log));", .expected = "[\"callee\",\"before\",\"iter\",\"next\",\"default\",\"next\",\"close\",\"after\",\"call\",true]\n" },
        .{ .name = "callee-getter-abrupt", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};const target={get run(){log.push(\"callee\");throw \"callee-failure\"}};try{target.run(([first]=source()))}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"callee\",\"callee-failure\"]\n" },
        .{ .name = "receiver-before-argument", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};let target={label:\"old\",run(value){log.push(this.label,value===last)}};nextHook=()=>{target={label:\"new\",run(){log.push(\"wrong-receiver\")}}};target.run(([first]=source()));console.log(JSON.stringify(log));", .expected = "[\"iter\",\"next\",\"close\",\"old\",true]\n" },
        .{ .name = "optional-call-skips-argument", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};const target=null;target?.run(([first=fail()]=source()));log.push(\"skip\");console.log(JSON.stringify(log));", .expected = "[\"skip\"]\n" },
        .{ .name = "assignment-callee-value", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};const callable=function(){\"use strict\";log.push(this===void 0?\"unbound\":\"bound\");return 42};callable[Symbol.iterator]=function(){log.push(\"iter\");return{next(){log.push(\"next\");return{value:void 0,done:false}},return(){log.push(\"close\");return{done:true}}}};log.push(([first=(log.push(\"default\"),7)]=callable)());console.log(JSON.stringify(log));", .expected = "[\"iter\",\"next\",\"default\",\"close\",\"unbound\",42]\n" },
        .{ .name = "direct-eval-callee-before-argument", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};const savedEval=eval;function run(){let local=42,value;nextHook=()=>{globalThis.eval=()=>-1};try{return eval(([value]=source(),\"local\"))}finally{globalThis.eval=savedEval}}log.push(run());console.log(JSON.stringify(log));", .expected = "[\"iter\",\"next\",\"close\",42]\n" },
        .{ .name = "assignment-eval-callee-indirect", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};const savedEval=eval;savedEval[Symbol.iterator]=function(){log.push(\"iter\");return{next(){log.push(\"next\");return{value:42,done:false}},return(){log.push(\"close\");return{done:true}}}};function run(){let hidden=42,value;return ([value]=eval)(\"typeof hidden\")}try{log.push(run())}finally{delete savedEval[Symbol.iterator]}console.log(JSON.stringify(log));", .expected = "[\"iter\",\"next\",\"close\",\"undefined\"]\n" },
        .{ .name = "close-before-call-abrupt", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};const target={run(value){log.push(\"call\",value===last);throw \"call-failure\"}};try{target.run(([first]=source()))}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"iter\",\"next\",\"close\",\"call\",true,\"call-failure\"]\n" },
        .{ .name = "constructor-callee-before-argument", .source = "const log=[];let first,second,last,nextHook=null;function fail(){log.push('default');throw 'failure'}function source(){return last={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');if(nextHook)nextHook();return{value:void 0,done:false}},return(){log.push('close');return{done:true}}}}}};function getConstructor(){log.push(\"callee\");return function Box(value){log.push(\"construct\",value===last);this.answer=42}}const value=new (getConstructor())(([first=(log.push(\"default\"),7)]=source()));log.push(value.answer);console.log(JSON.stringify(log));", .expected = "[\"callee\",\"iter\",\"next\",\"default\",\"close\",\"construct\",true,42]\n" },
    };
    var failures: usize = 0;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", case.source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, case.source, "reference-consumer.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .keep_names = true,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("Reference consumer={s} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ case.name, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            const passed = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, native.stdout, actual.stdout);
            std.debug.print("Reference result case={s} minify={} pass={}\n", .{ case.name, minify, passed });
            if (!passed) failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "lazy iterator Reference extensions preserve rest nested multiple super and private order" {
    const Case = struct { name: []const u8, source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .name = "rest-argument", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function run(value){log.push('call',value===last,first,rest)}run(([first,...rest]=src('A',[1,2,3])));console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"A:next\",\"A:next\",\"A:next\",\"call\",true,1,[2,3]]\n" },
        .{ .name = "rest-completed-before-later-argument", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function run(){}try{run(([first,...rest]=src('A',[1,2])),fail())}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"A:next\",\"A:next\",\"default\",\"failure\"]\n" },
        .{ .name = "nested-abrupt", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function run(){}try{run(([[first=fail()]]=src('O',[src('I',[void 0])]))) }catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"O:iter\",\"O:next\",\"I:iter\",\"I:next\",\"default\",\"I:close\",\"O:close\",\"failure\"]\n" },
        .{ .name = "nested-normal", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function run(){log.push('call',first)}run(([[first=(log.push('default'),42)]]=src('O',[src('I',[void 0])])));console.log(JSON.stringify(log));", .expected = "[\"O:iter\",\"O:next\",\"I:iter\",\"I:next\",\"default\",\"I:close\",\"O:close\",\"call\",42]\n" },
        .{ .name = "multiple-second-abrupt", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function run(){}try{run(([first]=src('A',[1])),([second=fail(),third]=src('B',[void 0,2])))}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"A:close\",\"B:iter\",\"B:next\",\"default\",\"B:close\",\"failure\"]\n" },
        .{ .name = "multiple-method-reference", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};const target={get run(){log.push('get');return function(a,b){log.push('call',this===target,first,second)}}};target.run(([first]=src('A',[1])),([second]=src('B',[2])));console.log(JSON.stringify(log));", .expected = "[\"get\",\"A:iter\",\"A:next\",\"A:close\",\"B:iter\",\"B:next\",\"B:close\",\"call\",true,1,2]\n" },
        .{ .name = "super-computed-default", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};class Base{set value(v){log.push('set:'+v)}}class Derived extends Base{run(){[super[(log.push('key'),'value')]=(log.push('default'),42)]=src('A',[void 0])}}new Derived().run();console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"key\",\"A:next\",\"default\",\"set:42\",\"A:close\"]\n" },
        .{ .name = "private-brand-after-default", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};class Owner{#value;run(other){try{[other.#value=(log.push('default'),42)]=src('A',[void 0])}catch(error){log.push(error.name)}}}new Owner().run({});console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"default\",\"A:close\",\"TypeError\"]\n" },
        .{ .name = "super-call-argument-abrupt", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};class Base{run(){log.push('call')}}class Derived extends Base{run(){try{super.run(([first=fail(),second]=src('A',[void 0,2])))}catch(error){log.push(error)}}}new Derived().run();console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"default\",\"A:close\",\"failure\"]\n" },
        .{ .name = "private-call-argument-abrupt", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};class Owner{#run(){log.push('call')}run(){try{this.#run(([first=fail(),second]=src('A',[void 0,2])))}catch(error){log.push(error)}}}new Owner().run();console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"default\",\"A:close\",\"failure\"]\n" },
    };
    var failures: usize = 0;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", case.source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, case.source, "reference-consumer.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .keep_names = true,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("Reference consumer={s} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ case.name, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            const passed = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, native.stdout, actual.stdout);
            std.debug.print("Reference result case={s} minify={} pass={}\n", .{ case.name, minify, passed });
            if (!passed) failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "lazy iterator Reference private scalar brands reject missing receivers" {
    const Case = struct { name: []const u8, source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .name = "private-scalar-brand", .source = "class Owner{#value;run(other){try{other.#value=42;console.log('accepted')}catch(error){console.log(error.name)}}}new Owner().run({});", .expected = "TypeError\n" },
    };
    var failures: usize = 0;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", case.source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, case.source, "reference-consumer.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .keep_names = true,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("Reference consumer={s} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ case.name, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            const passed = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, native.stdout, actual.stdout);
            std.debug.print("Reference result case={s} minify={} pass={}\n", .{ case.name, minify, passed });
            if (!passed) failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "lazy iterator Reference default and loop gaps retain IteratorClose order" {
    const Case = struct { name: []const u8, source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .name = "default-inner-abrupt", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};let fourth;function run(){}try{run(([first=([second=fail(),third]=src('I',[void 0,2])),fourth]=src('O',[void 0,3])))}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"O:iter\",\"O:next\",\"I:iter\",\"I:next\",\"default\",\"I:close\",\"O:close\",\"failure\"]\n" },
        .{ .name = "default-inner-normal", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};let fourth;function run(){log.push('call',first,second)}run(([first=(([second]=src('I',[42])),7),fourth]=src('O',[void 0,3])));console.log(JSON.stringify(log));", .expected = "[\"O:iter\",\"O:next\",\"I:iter\",\"I:next\",\"I:close\",\"O:next\",\"O:close\",\"call\",7,42]\n" },
        .{ .name = "for-condition-call", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};let fourth;function check(){log.push('check');return false}try{for(;check(([first=fail(),second]=src('A',[void 0,2])));){log.push('body')}}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"default\",\"A:close\",\"failure\"]\n" },
        .{ .name = "for-update-call", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};let fourth;function check(){log.push('check')}try{for(let once=true;once;check(([first=fail(),second]=src('A',[void 0,2])))){log.push('body');once=false}}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"body\",\"A:iter\",\"A:next\",\"default\",\"A:close\",\"failure\"]\n" },
        .{ .name = "for-initializer-call", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};let fourth;function check(){log.push('check');return 1}try{for(let once=check(([first=fail(),second]=src('A',[void 0,2])));once;){log.push('body');break}}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"default\",\"A:close\",\"failure\"]\n" },
    };
    var failures: usize = 0;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", case.source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, case.source, "reference-consumer.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .keep_names = true,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("Reference consumer={s} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ case.name, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            const passed = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, native.stdout, actual.stdout);
            std.debug.print("Reference result case={s} minify={} pass={}\n", .{ case.name, minify, passed });
            if (!passed) failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "lazy iterator Reference loop completion boundaries retain per-evaluation cleanup" {
    const Case = struct { name: []const u8, source: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .name = "condition-false", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function check(){log.push('check');return false}for(;check(([first=(log.push('default'),42)]=src('A',[void 0])));){log.push('wrong-body')}console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"default\",\"A:close\",\"check\"]\n" },
        .{ .name = "update-after-continue", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};let index=0;function step(){log.push('update:'+index);index++}for(;index<2;step(([first=(log.push('default'),42)]=src('A',[void 0])))){log.push('body:'+index);continue}console.log(JSON.stringify(log));", .expected = "[\"body:0\",\"A:iter\",\"A:next\",\"default\",\"A:close\",\"update:0\",\"body:1\",\"A:iter\",\"A:next\",\"default\",\"A:close\",\"update:1\"]\n" },
        .{ .name = "break-skips-update", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function step(){log.push('wrong-update')}for(;true;step(([first=fail(),second]=src('A',[void 0,2])))){log.push('body');break}console.log(JSON.stringify(log));", .expected = "[\"body\"]\n" },
        .{ .name = "body-throw-skips-update", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function step(){log.push('wrong-update')}try{for(;true;step(([first=fail(),second]=src('A',[void 0,2])))){log.push('body');throw 'body-error'}}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"body\",\"body-error\"]\n" },
        .{ .name = "continue-label", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};let index=0;function check(){return index++<2}outer:for(;check(([first=(log.push('default'),42)]=src('A',[void 0])));){log.push('body');continue outer}console.log(JSON.stringify(log));", .expected = "[\"A:iter\",\"A:next\",\"default\",\"A:close\",\"body\",\"A:iter\",\"A:next\",\"default\",\"A:close\",\"body\",\"A:iter\",\"A:next\",\"default\",\"A:close\"]\n" },
        .{ .name = "combined-ready-init-header", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function init(){log.push('init');return 1}function check(){log.push('check');return false}try{for(let once=init(([first]=src('I',[1])));check(([second=fail(),third]=src('A',[void 0,2])));){log.push('wrong-body')}}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"I:iter\",\"I:next\",\"I:close\",\"init\",\"A:iter\",\"A:next\",\"default\",\"A:close\",\"failure\"]\n" },
        .{ .name = "normal-close-error", .source = "const log=[];let first,second,third,rest,last;function fail(){log.push('default');throw 'failure'}function src(label,values){return last={[Symbol.iterator](){log.push(label+':iter');let index=0;return{next(){log.push(label+':next');return index<values.length?{value:values[index++],done:false}:{done:true}},return(){log.push(label+':close');return{done:true}}}}}};function check(){log.push('wrong-check')}const value={[Symbol.iterator](){log.push('iter');return{next(){log.push('next');return{value:void 0,done:false}},return(){log.push('close');throw 'close-error'}}}};try{for(;check(([first=(log.push('default'),42)]=value));){log.push('wrong-body')}}catch(error){log.push(error)}console.log(JSON.stringify(log));", .expected = "[\"iter\",\"next\",\"default\",\"close\",\"close-error\"]\n" },
    };
    var failures: usize = 0;
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const native = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", case.source } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expectEqualStrings(case.expected, native.stdout);
        for ([_]bool{ false, true }) |minify| {
            const result = try @import("../transpile.zig").transpile(allocator, case.source, "reference-consumer.cjs", .{
                .unsupported = @import("transformer.zig").TransformOptions.compat.fromESTarget(.es5),
                .keep_names = true,
                .minify_identifiers = minify,
                .minify_syntax = minify,
                .minify_whitespace = minify,
            });
            const actual = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "node", "-e", result.code } });
            if (actual.term != .exited or actual.term.exited != 0 or !std.mem.eql(u8, native.stdout, actual.stdout))
                std.debug.print("Reference consumer={s} minify={} native={s} actual={s} stderr={s} code={s}\n", .{ case.name, minify, native.stdout, actual.stdout, actual.stderr, result.code });
            const passed = actual.term == .exited and actual.term.exited == 0 and std.mem.eql(u8, native.stdout, actual.stdout);
            std.debug.print("Reference result case={s} minify={} pass={}\n", .{ case.name, minify, passed });
            if (!passed) failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
