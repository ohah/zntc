//! Synchronous private module environments; the frame factory is emitted separately.
//! Physical CommonJS loading and internal namespace/evaluation state are distinct.
pub const source =
    \\var __pmModule = (function () {
    \\  var create = Object.create;
    \\  var define = Object.defineProperty;
    \\  var prevent = Object.preventExtensions;
    \\  var ownDescriptor = Object.getOwnPropertyDescriptor;
    \\  var invoke = Function.prototype.call.bind(Function.prototype.call);
    \\  var nativeNext;
    \\  var sort = Function.prototype.call.bind(Array.prototype.sort);
    \\  var tag = typeof Symbol === "function" ? Symbol.toStringTag : void 0;
    \\  var Failure = Error;
    \\  var records = create(null), depth = 0;
    \\  function data(value, flags) {
    \\    var descriptor = create(null);
    \\    descriptor.value = value;
    \\    descriptor.enumerable = !!(flags & 1);
    \\    descriptor.configurable = !!(flags & 2);
    \\    descriptor.writable = !!(flags & 4);
    \\    return descriptor;
    \\  }
    \\  function accessor(getter) {
    \\    var descriptor = create(null);
    \\    descriptor.get = getter;
    \\    descriptor.enumerable = true;
    \\    return descriptor;
    \\  }
    \\  function evaluate(record) {
    \\    if (record.state === 3) throw record.error;
    \\    if (record.state === 1 || record.state === 2) return;
    \\    record.state = 1;
    \\    try {
    \\      for (var i = 0; i < record.dependencies.length; i++) evaluate(record.dependencies[i]);
    \\      if (!invoke(record.next, record.frame).done) throw new Failure("unexpected second module suspension");
    \\      record.state = 2;
    \\      record.publish(record.namespace, true);
    \\    } catch (error) {
    \\      record.state = 3;
    \\      record.error = error;
    \\      throw error;
    \\    }
    \\  }
    \\  function prepare(key, factory, specifications, publish) {
    \\    var record = records[key];
    \\    if (record) {
    \\      if (record.state === 3) throw record.error;
    \\      return record.namespace;
    \\    }
    \\    record = create(null);
    \\    record.state = 0;
    \\    record.dependencies = [];
    \\    record.slots = [];
    \\    record.publish = publish;
    \\    records[key] = record;
    \\    depth++;
    \\    try {
    \\      record.frame = factory(record.slots);
    \\      var next = ownDescriptor(record.frame, "next");
    \\      if (next) record.next = next.value;
    \\      else {
    \\        if (!nativeNext) nativeNext = record.frame.next;
    \\        record.next = nativeNext;
    \\      }
    \\      var first = invoke(record.next, record.frame);
    \\      if (first.done) throw new Failure("missing module namespace suspension");
    \\      record.namespace = first.value;
    \\      publish(record.namespace, false);
    \\      for (var i = 0; i < specifications.length; i++) {
    \\        var specification = specifications[i];
    \\        specification.load();
    \\        var dependency = records[specification.key];
    \\        if (!dependency) throw new Failure("missing physical module environment");
    \\        if (dependency.state === 3) throw dependency.error;
    \\        define(record.dependencies, i, data(dependency, 7));
    \\        define(record.slots, i, data(dependency.namespace, 7));
    \\      }
    \\    } catch (error) {
    \\      record.state = 3;
    \\      record.error = error;
    \\      throw error;
    \\    } finally {
    \\      depth--;
    \\    }
    \\    if (depth === 0) evaluate(record);
    \\    return record.namespace;
    \\  }
    \\  prepare.namespace = function (entries) {
    \\    var ordered = [], namespace = create(null);
    \\    for (var i = 0; i < entries.length; i++) {
    \\      if (typeof entries[i][0] !== "string" || typeof entries[i][1] !== "function") throw new Failure("invalid module namespace entry");
    \\      define(ordered, i, data(entries[i], 7));
    \\    }
    \\    sort(ordered, function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
    \\    for (var i = 0; i < ordered.length; i++) {
    \\      if (i && ordered[i - 1][0] === ordered[i][0]) throw new Failure("duplicate module namespace entry");
    \\      define(namespace, ordered[i][0], accessor(ordered[i][1]));
    \\    }
    \\    if (tag) define(namespace, tag, data("Module", 0));
    \\    return prevent(namespace);
    \\  };
    \\  return prepare;
    \\})();
;

test "synchronous module runtime resumes private frames after source changes generator prototypes" {
    const std = @import("std");
    const a = std.testing.allocator;
    const script = source ++
        "\nconst p=__pmModule,proto=Object.getPrototypeOf(Object.getPrototypeOf((function*(){})())),saved=proto.next,out=[];" ++
        "function* main(){yield p.namespace([]);out.push(42)}" ++
        "function* dep(){yield p.namespace([]);proto.next=function(){throw Error('poison-generator-next')}}" ++
        "try{p('main',main,[{key:'dep',load:function(){p('dep',dep,[],function(){})}}],function(){});" ++
        "p('later-root',function*(){yield p.namespace([]);out.push(84)},[],function(){})}finally{proto.next=saved}" ++
        "console.log(JSON.stringify(out));";
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
    defer a.free(actual.stdout);
    defer a.free(actual.stderr);
    if (actual.term != .exited or actual.term.exited != 0) std.debug.print("module generator isolation stderr={s}\n", .{actual.stderr});
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings("[42,84]\n", actual.stdout);
}

test "synchronous module runtime caches the identical error despite prototype setters" {
    const std = @import("std");
    const a = std.testing.allocator;
    const script = source ++
        "\nconst p=__pmModule,expected={stable:42};let swallowed=0,one,two;" ++
        "function* frame(){yield p.namespace([]);Object.defineProperty(Object.prototype,'error',{set:function(){swallowed++},configurable:true});throw expected}" ++
        "try{try{p('failure',frame,[],function(){})}catch(e){one=e}try{p('failure',frame,[],function(){})}catch(e){two=e}}finally{delete Object.prototype.error}" ++
        "console.log(JSON.stringify([one===expected,two===expected,swallowed]));";
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
    defer a.free(actual.stdout);
    defer a.free(actual.stderr);
    if (actual.term != .exited or actual.term.exited != 0) std.debug.print("module error cache stderr={s}\n", .{actual.stderr});
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings("[true,true,0]\n", actual.stdout);
}

test "synchronous module runtime isolates later records and property descriptors from source prototypes" {
    const std = @import("std");
    const a = std.testing.allocator;
    const script = source ++
        "\nconst p=__pmModule,create=Object.create,define=Object.defineProperty;const out=[];" ++
        "for(const field of ['value','get','set']){" ++
        "function* first(){yield p.namespace([]);const d=create(null);d.value=field==='value'?123:function(){};d.configurable=true;define(Object.prototype,field,d)}" ++
        "function* later(){yield p.namespace([['value',function(){return 42}]])}" ++
        "try{p('first:'+field,first,[],function(){});out.push(p('later:'+field,later,[],function(){}).value)}finally{delete Object.prototype[field]}}" ++
        "for(const field of ['frame','namespace']){let intercepted=0;" ++
        "function* first(){yield p.namespace([]);define(Object.prototype,field,{set:function(){intercepted++},configurable:true})}" ++
        "function* later(){yield p.namespace([['value',function(){return 42}]])}" ++
        "try{p('first:'+field,first,[],function(){});out.push([p('later:'+field,later,[],function(){}).value,intercepted])}finally{delete Object.prototype[field]}}" ++
        "console.log(JSON.stringify(out));";
    const actual = try std.process.run(a, std.testing.io, .{ .argv = &.{ "node", "-e", script } });
    defer a.free(actual.stdout);
    defer a.free(actual.stderr);
    if (actual.term != .exited or actual.term.exited != 0) std.debug.print("module prototype isolation stderr={s}\n", .{actual.stderr});
    try std.testing.expect(actual.term == .exited and actual.term.exited == 0);
    try std.testing.expectEqualStrings("[42,42,42,[42,0],[42,0]]\n", actual.stdout);
}
