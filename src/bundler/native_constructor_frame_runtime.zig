//! Runtime activation storage for a native-constructor timing producer.
//! Defining this template does not admit a constructor transform or add fields.
const std = @import("std");

pub const source =
    \\var __nativeCtorThis = (function() {
    \\  var active;
    \\  return function(operation, value) {
    \\    if (operation === 0) {
    \\      var frame = { assign: value, previous: active };
    \\      active = frame;
    \\      return frame;
    \\    }
    \\    if (operation === 1) {
    \\      active.assign(value);
    \\      return value;
    \\    }
    \\    var previous = value.previous;
    \\    value.assign = null;
    \\    value.previous = null;
    \\    active = previous;
    \\  };
    \\})();
    \\
;

test "native constructor frame runtime preserves receiver identity and detaches nested activations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code =
        \\var oldPush=Array.prototype.push,oldPop=Array.prototype.pop,oldBind=Function.prototype.bind;
        \\Array.prototype.push=Array.prototype.pop=Function.prototype.bind=function(){throw Error('unexpected prototype operation')};
    ++ source ++
        \\var outerValue,innerValue;
        \\var first={},second={},third={};
        \\var outer=__nativeCtorThis(0,function(value){outerValue=value});
        \\var firstResult=__nativeCtorThis(1,first);
        \\var inner=__nativeCtorThis(0,function(value){innerValue=value});
        \\__nativeCtorThis(1,second);
        \\__nativeCtorThis(2,inner);
        \\__nativeCtorThis(1,third);
        \\var nestedDetached=inner.previous===null&&inner.assign===null;
        \\__nativeCtorThis(2,outer);
        \\var outerDetached=outer.previous===null&&outer.assign===null;
        \\Array.prototype.push=oldPush;Array.prototype.pop=oldPop;Function.prototype.bind=oldBind;
        \\console.log(JSON.stringify([firstResult===first,outerValue===third,innerValue===second,nestedDetached,outerDetached,Reflect.ownKeys(first).length,Reflect.ownKeys(second).length]));
    ;
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", code }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings("", actual.stderr);
    try std.testing.expectEqualStrings("[true,true,true,true,true,0,0]\n", actual.stdout);
}

// These explicitly assembled controls exercise the engine timing protocol,
// independently of the AST producer. They do not admit a transform target.
test "native constructor frame runtime publishes this before fields and source handlers" {
    const cases = [_]struct { native: []const u8, bridged: []const u8 }{
        .{
            .native = "var saved;class P{}class D extends P{x=(console.log(saved()===this),7);constructor(){saved=()=>this;super();console.log(saved().x)}}new D",
            .bridged = "var saved;class P{}class D extends P{x=(__nativeCtorThis(1,this),console.log(saved()===this),7);constructor(){var cell,frame=__nativeCtorThis(0,function(value){cell=value});try{saved=function(){return cell};super();console.log(saved().x)}finally{try{cell=this}catch(ignored){}__nativeCtorThis(2,frame)}}}new D",
        },
        .{
            .native = "var saved;class P{}class D extends P{x=(()=>{throw{}})();constructor(){saved=()=>this;try{super()}catch({value=(console.log(saved()===this),1)}){console.log(value)}}}new D",
            .bridged = "var saved;class P{}class D extends P{x=(__nativeCtorThis(1,this),(()=>{throw{}})());constructor(){var cell,frame=__nativeCtorThis(0,function(value){cell=value});try{saved=function(){return cell};try{try{super()}finally{try{cell=this}catch(ignored){}}}catch({value=(console.log(saved()===this),1)}){console.log(value)}}finally{try{cell=this}catch(ignored){}__nativeCtorThis(2,frame)}}}new D",
        },
        .{
            // The second construction binds this, then private-brand setup
            // throws before its first field can publish the receiver.
            .native = "var shared={},saved;class P{constructor(){return shared}}class D extends P{#method(){}x=1;constructor(){saved=()=>this;try{super()}catch(error){console.log(error.name,saved()===shared)}}}new D;new D",
            .bridged = "var shared={},saved;class P{constructor(){return shared}}class D extends P{#method(){}x=(__nativeCtorThis(1,this),1);constructor(){var cell,frame=__nativeCtorThis(0,function(value){cell=value});try{saved=function(){return cell};try{try{super()}finally{try{cell=this}catch(ignored){}}}catch(error){console.log(error.name,saved()===shared)}}finally{try{cell=this}catch(ignored){}__nativeCtorThis(2,frame)}}}new D;new D",
        },
        .{
            .native = "var saved,inner;class P{constructor(n){if(n){var outer=saved;inner=new D(0);saved=outer}}}class D extends P{x=(console.log(saved()===this),7);constructor(n){saved=()=>this;super(n);console.log(saved()===this)}}new D(1)",
            .bridged = "var saved,inner;class P{constructor(n){if(n){var outer=saved;inner=new D(0);saved=outer}}}class D extends P{x=(__nativeCtorThis(1,this),console.log(saved()===this),7);constructor(n){var cell,frame=__nativeCtorThis(0,function(value){cell=value});try{saved=function(){return cell};super(n);console.log(saved()===this)}finally{try{cell=this}catch(ignored){}__nativeCtorThis(2,frame)}}}new D(1)",
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const program = try std.fmt.allocPrint(a, "{s}\n{s}", .{ source, case.bridged });
        const native = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", case.native } });
        const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", program } });
        try std.testing.expect(native.term == .exited and native.term.exited == 0);
        try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
        try std.testing.expectEqualStrings(native.stdout, actual.stdout);
        try std.testing.expectEqualStrings(native.stderr, actual.stderr);
    }
}
