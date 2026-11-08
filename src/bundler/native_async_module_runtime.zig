//! Native-async-module factory ABI. Source lowering owns lexical environments,
//! actual namespace identity and every source await/disposal effect.
//! The instantiation gate is { namespace, hasTLA }; body values are awaited once.
//! This runtime never discovers a source binding by spelling.

pub const FACTORY_EXPRESSION: []const u8 =
    \\(function(PromiseConstructor, apply, defineProperty, privateKey, promiseThen, ownDescriptor) {
    \\  var protocolToken = {}, nextOrder = 0, ready = [], draining = false;
    \\  function append(array, value) { array[array.length] = value; }
    \\  function call(fn, receiver, args) { return apply(fn, receiver, args); }
    \\  function promiseFor(component) {
    \\    if (!component.promise) component.promise = new PromiseConstructor(function(resolve, reject) {
    \\      component.resolve = resolve; component.reject = reject;
    \\    });
    \\    return component.promise;
    \\  }
    \\  function recordFor(initializer) {
    \\    if (typeof initializer !== 'function') throw new TypeError('Invalid async module dependency');
    \\    var access = initializer[privateKey];
    \\    if (typeof access !== 'function') throw new TypeError('Foreign async module initializer');
    \\    var record = call(access, initializer, [protocolToken]);
    \\    if (!record || record.initializer !== initializer) throw new TypeError('Invalid async module record');
    \\    return record;
    \\  }
    \\  // Collect immutable dependency handles before any module body is resumed.
    \\  // Iterative Tarjan gives every cycle one externally observable completion.
    \\  function collect(root) {
    \\    if (root.component) return [];
    \\    var frames = [{ record: root, entered: false, next: 0 }], members = [], postorder = [], serial = 0;
    \\    while (frames.length) {
    \\      var frame = frames[frames.length - 1], record = frame.record;
    \\      if (!frame.entered) {
    \\        frame.entered = true;
    \\        record.index = record.low = ++serial; record.onStack = true;
    \\        append(members, record);
    \\        var handles = call(record.dependenciesThunk, void 0, []);
    \\        record.dependencies = [];
    \\        for (var i = 0; i < handles.length; i++) append(record.dependencies, recordFor(handles[i]));
    \\      }
    \\      if (frame.next < record.dependencies.length) {
    \\        var child = record.dependencies[frame.next++];
    \\        if (child.component) continue;
    \\        if (!child.index) { append(frames, { record: child, entered: false, next: 0 }); continue; }
    \\        if (child.onStack && child.index < record.low) record.low = child.index;
    \\        continue;
    \\      }
    \\      frames.length--;
    \\      record.order = ++nextOrder;
    \\      append(postorder, record);
    \\      if (record.low === record.index) {
    \\        var component = { remaining: 0, done: false, failed: false, error: void 0, members: [], parents: [], promise: null };
    \\        do {
    \\          var member = members[members.length - 1]; members.length--;
    \\          member.onStack = false; member.component = component;
    \\          append(component.members, member); component.remaining++;
    \\        } while (member !== record);
    \\      }
    \\      if (frames.length && record.low < frames[frames.length - 1].record.low)
    \\        frames[frames.length - 1].record.low = record.low;
    \\    }
    \\    return postorder;
    \\  }
    \\  function enqueue(record) {
    \\    if (record.state !== 0 || record.component.failed) return;
    \\    record.state = 1;
    \\    append(ready, record);
    \\  }
    \\  function notifyParents(parents) {
    \\    for (var i = 0; i < parents.length; i++) {
    \\      var parent = parents[i];
    \\      if (parent.component.failed || parent.state !== 0) continue;
    \\      if (--parent.pending === 0) enqueue(parent);
    \\    }
    \\  }
    \\  function complete(record) {
    \\    if (record.state === 3 || record.component.failed) return;
    \\    record.state = 3;
    \\    notifyParents(record.parents);
    \\    var component = record.component;
    \\    if (--component.remaining === 0) {
    \\      component.done = true;
    \\      if (component.resolve) component.resolve();
    \\      notifyParents(component.parents);
    \\    }
    \\    flush();
    \\  }
    \\  function fail(record, error) {
    \\    var work = [record.component];
    \\    while (work.length) {
    \\      var component = work[work.length - 1]; work.length--;
    \\      if (component.failed) continue;
    \\      component.failed = true; component.error = error;
    \\      if (component.reject) component.reject(error);
    \\      for (var i = 0; i < component.members.length; i++) component.members[i].state = 4;
    \\      for (var i = 0; i < component.parents.length; i++) append(work, component.parents[i].component);
    \\    }
    \\  }
    \\  async function fulfilledModule() {}
    \\  async function rejectedModule(error) { throw error; }
    \\  function settleAsync(record, promise) {
    \\    call(promiseThen, promise, [function() { complete(record); }, function(error) { fail(record, error); }]);
    \\  }
    \\  async function resume(record, step) {
    \\    while (!step.done) {
    \\      var value;
    \\      try { value = await step.value; }
    \\      catch (error) { step = call(record.throwInto, record.iterator, [error]); continue; }
    \\      step = call(record.next, record.iterator, [value]);
    \\    }
    \\  }
    \\  function flush(propagateSyncError) {
    \\    if (draining) return;
    \\    draining = true;
    \\    try {
    \\      while (ready.length) {
    \\        var selected = 0;
    \\        for (var i = 1; i < ready.length; i++) if (ready[i].order < ready[selected].order) selected = i;
    \\        var record = ready[selected];
    \\        ready[selected] = ready[ready.length - 1]; ready.length--;
    \\        if (record.component.failed) continue;
    \\        record.state = 2;
    \\        try {
    \\          var step = call(record.next, record.iterator, []);
    \\          if (step.done) {
    \\            if (record.hasTLA) settleAsync(record, fulfilledModule());
    \\            else complete(record);
    \\          } else {
    \\            if (!record.hasTLA) throw new TypeError('Sync module yielded an await effect');
    \\            settleAsync(record, resume(record, step));
    \\          }
    \\        } catch (error) {
    \\          if (record.hasTLA) settleAsync(record, rejectedModule(error));
    \\          else {
    \\            fail(record, error);
    \\            if (propagateSyncError) {
    \\              for (var j = 0; j < ready.length; j++) if (ready[j].state === 1) ready[j].state = 0;
    \\              ready.length = 0;
    \\              throw error;
    \\            }
    \\          }
    \\        }
    \\      }
    \\    } finally { draining = false; }
    \\  }
    \\  function bindImports(record) {
    \\    if (!record.importsThunk || record.importsBound) return;
    \\    if (record.bindingImports) throw new TypeError('Reentrant async module import binding');
    \\    record.bindingImports = true;
    \\    try {
    \\      var imports = call(record.importsThunk, void 0, []), readers = [];
    \\      if (!record.environment || !record.environment[3]) throw new TypeError('Missing async module import environment');
    \\      for (var i = 0; i < imports.length; i++) {
    \\        var item = imports[i], provider = recordFor(item[0]), key = item[1], reader;
    \\        if (key === null) reader = (function(target) { return function() { return target.namespace; }; })(provider);
    \\        else {
    \\          if (typeof key !== 'string' || !provider.bindings) throw new TypeError('Invalid async module binding table');
    \\          var descriptor = ownDescriptor(provider.bindings, key);
    \\          var field = descriptor && ownDescriptor(descriptor, 'value');
    \\          if (!field || typeof field.value !== 'function') throw new TypeError('Missing async module binding getter');
    \\          reader = field.value;
    \\        }
    \\        append(readers, reader);
    \\      }
    \\      for (var i = 0; i < readers.length; i++) record.environment[3][i] = readers[i];
    \\      record.importsBound = true;
    \\    } finally { record.bindingImports = false; }
    \\  }
    \\  function prepare(root) {
    \\    var records = collect(root);
    \\    for (var i = 0; i < records.length; i++) bindImports(records[i]);
    \\    bindImports(root);
    \\    for (var i = 0; i < records.length; i++) {
    \\      var record = records[i];
    \\      for (var j = 0; j < record.dependencies.length; j++) {
    \\        var dependency = record.dependencies[j];
    \\        if (dependency.component.failed) { fail(record, dependency.component.error); break; }
    \\        if (dependency.component !== record.component) {
    \\          if (!dependency.component.done) { record.pending++; append(dependency.component.parents, record); }
    \\        } else if (dependency.order < record.order && dependency.state !== 3) {
    \\          record.pending++; append(dependency.parents, record);
    \\        }
    \\      }
    \\      if (!record.pending) enqueue(record);
    \\    }
    \\    // A prior synchronous failure may have left instantiated siblings idle.
    \\    // Wake only this actual initializer's reachable records, never all records.
    \\    var work = [root], seen = [];
    \\    while (work.length) {
    \\      var current = work[work.length - 1]; work.length--;
    \\      var known = false;
    \\      for (var j = 0; j < seen.length; j++) if (seen[j] === current) { known = true; break; }
    \\      if (known) continue;
    \\      append(seen, current);
    \\      bindImports(current);
    \\      if (!current.pending) enqueue(current);
    \\      for (var j = 0; j < current.dependencies.length; j++) append(work, current.dependencies[j]);
    \\    }
    \\    flush(true);
    \\  }
    \\  return function(createGenerator, dependencyInitializersThunk, environment, importsThunk) {
    \\    var iterator = call(createGenerator, void 0, [environment]), next = iterator.next, throwInto = iterator.throw;
    \\    var gate = call(next, iterator, []);
    \\    if (gate.done || !gate.value || typeof gate.value.hasTLA !== 'boolean') throw new TypeError('Invalid async module instantiation gate');
    \\    var record = { iterator: iterator, next: next, throwInto: throwInto, namespace: gate.value.namespace, hasTLA: gate.value.hasTLA,
    \\      environment: environment, bindings: gate.value.bindings, importsThunk: importsThunk, importsBound: false, bindingImports: false,
    \\      dependenciesThunk: dependencyInitializersThunk, dependencies: null, component: null,
    \\      index: 0, low: 0, order: 0, onStack: false, pending: 0, parents: [], state: 0 };
    \\    function initializer() {
    \\      prepare(record);
    \\      if (record.component.failed) throw record.component.error;
    \\      if (!record.component.done) return promiseFor(record.component);
    \\    }
    \\    record.initializer = initializer;
    \\    defineProperty(initializer, privateKey, { value: function(token) {
    \\      if (token !== protocolToken) throw new TypeError('Private async module protocol');
    \\      return record;
    \\    } });
    \\    // The actual namespace is installed before evaluation and never copied.
    \\    defineProperty(initializer, 'namespace', { value: gate.value.namespace });
    \\    return initializer;
    \\  };
    \\})(Promise, Reflect.apply, Object.defineProperty, Symbol('async module protocol'), Promise.prototype.then, Object.getOwnPropertyDescriptor)
;

pub const FACTORY_EXPRESSION_MIN: []const u8 = "function(PromiseConstructor,apply,defineProperty,privateKey,promiseThen,ownDescriptor){var protocolToken={},nextOrder=0,ready=[],draining=false;function append(array,value){array[array.length]=value}function call(fn,receiver,args){return apply(fn,receiver,args)}function promiseFor(component){if(!component.promise)component.promise=new PromiseConstructor(function(resolve,reject){component.resolve=resolve;component.reject=reject});return component.promise}function recordFor(initializer){if(typeof initializer!==\"function\")throw new TypeError(\"Invalid async module dependency\");var access=initializer[privateKey];if(typeof access!==\"function\")throw new TypeError(\"Foreign async module initializer\");var record=call(access,initializer,[protocolToken]);if(!record||record.initializer!==initializer)throw new TypeError(\"Invalid async module record\");return record}function collect(root){if(root.component)return[];var frames=[{record:root,entered:false,next:0}],members=[],postorder=[],serial=0;while(frames.length){var frame=frames[frames.length-1],record=frame.record;if(!frame.entered){frame.entered=true;record.index=record.low=++serial;record.onStack=true;append(members,record);var handles=call(record.dependenciesThunk,undefined,[]);record.dependencies=[];for(var i=0;i<handles.length;i++)append(record.dependencies,recordFor(handles[i]))}if(frame.next<record.dependencies.length){var child=record.dependencies[frame.next++];if(child.component)continue;if(!child.index){append(frames,{record:child,entered:false,next:0});continue}if(child.onStack&&child.index<record.low)record.low=child.index;continue}frames.length--;record.order=++nextOrder;append(postorder,record);if(record.low===record.index){var component={remaining:0,done:false,failed:false,error:undefined,members:[],parents:[],promise:null};do{var member=members[members.length-1];members.length--;member.onStack=false;member.component=component;append(component.members,member);component.remaining++}while(member!==record)}if(frames.length&&record.low<frames[frames.length-1].record.low)frames[frames.length-1].record.low=record.low}return postorder}function enqueue(record){if(record.state!==0||record.component.failed)return;record.state=1;append(ready,record)}function notifyParents(parents){for(var i=0;i<parents.length;i++){var parent=parents[i];if(parent.component.failed||parent.state!==0)continue;if(--parent.pending===0)enqueue(parent)}}function complete(record){if(record.state===3||record.component.failed)return;record.state=3;notifyParents(record.parents);var component=record.component;if(--component.remaining===0){component.done=true;if(component.resolve)component.resolve();notifyParents(component.parents)}flush()}function fail(record,error){var work=[record.component];while(work.length){var component=work[work.length-1];work.length--;if(component.failed)continue;component.failed=true;component.error=error;if(component.reject)component.reject(error);for(var i=0;i<component.members.length;i++)component.members[i].state=4;for(var i=0;i<component.parents.length;i++)append(work,component.parents[i].component)}}async function fulfilledModule(){}async function rejectedModule(error){throw error}function settleAsync(record,promise){call(promiseThen,promise,[function(){complete(record)},function(error){fail(record,error)}])}async function resume(record,step){while(!step.done){var value;try{value=await step.value}catch(error){step=call(record.throwInto,record.iterator,[error]);continue}step=call(record.next,record.iterator,[value])}}function flush(propagateSyncError){if(draining)return;draining=true;try{while(ready.length){var selected=0;for(var i=1;i<ready.length;i++)if(ready[i].order<ready[selected].order)selected=i;var record=ready[selected];ready[selected]=ready[ready.length-1];ready.length--;if(record.component.failed)continue;record.state=2;try{var step=call(record.next,record.iterator,[]);if(step.done){if(record.hasTLA)settleAsync(record,fulfilledModule());else complete(record)}else{if(!record.hasTLA)throw new TypeError(\"Sync module yielded an await effect\");settleAsync(record,resume(record,step))}}catch(error){if(record.hasTLA)settleAsync(record,rejectedModule(error));else{fail(record,error);if(propagateSyncError){for(var j=0;j<ready.length;j++)if(ready[j].state===1)ready[j].state=0;ready.length=0;throw error}}}}}finally{draining=false}}function bindImports(record){if(!record.importsThunk||record.importsBound)return;if(record.bindingImports)throw new TypeError(\"Reentrant async module import binding\");record.bindingImports=true;try{var imports=call(record.importsThunk,undefined,[]),readers=[];if(!record.environment||!record.environment[3])throw new TypeError(\"Missing async module import environment\");for(var i=0;i<imports.length;i++){var item=imports[i],provider=recordFor(item[0]),key=item[1],reader;if(key===null)reader=function(target){return function(){return target.namespace}}(provider);else{if(typeof key!==\"string\"||!provider.bindings)throw new TypeError(\"Invalid async module binding table\");var descriptor=ownDescriptor(provider.bindings,key);var field=descriptor&&ownDescriptor(descriptor,\"value\");if(!field||typeof field.value!==\"function\")throw new TypeError(\"Missing async module binding getter\");reader=field.value}append(readers,reader)}for(var i=0;i<readers.length;i++)record.environment[3][i]=readers[i];record.importsBound=true}finally{record.bindingImports=false}}function prepare(root){var records=collect(root);for(var i=0;i<records.length;i++)bindImports(records[i]);bindImports(root);for(var i=0;i<records.length;i++){var record=records[i];for(var j=0;j<record.dependencies.length;j++){var dependency=record.dependencies[j];if(dependency.component.failed){fail(record,dependency.component.error);break}if(dependency.component!==record.component){if(!dependency.component.done){record.pending++;append(dependency.component.parents,record)}}else if(dependency.order<record.order&&dependency.state!==3){record.pending++;append(dependency.parents,record)}}if(!record.pending)enqueue(record)}var work=[root],seen=[];while(work.length){var current=work[work.length-1];work.length--;var known=false;for(var j=0;j<seen.length;j++)if(seen[j]===current){known=true;break}if(known)continue;append(seen,current);bindImports(current);if(!current.pending)enqueue(current);for(var j=0;j<current.dependencies.length;j++)append(work,current.dependencies[j])}flush(true)}return function(createGenerator,dependencyInitializersThunk,environment,importsThunk){var iterator=call(createGenerator,undefined,[environment]),{next,throw:throwInto}=iterator;var gate=call(next,iterator,[]);if(gate.done||!gate.value||typeof gate.value.hasTLA!==\"boolean\")throw new TypeError(\"Invalid async module instantiation gate\");var record={iterator,next,throwInto,namespace:gate.value.namespace,hasTLA:gate.value.hasTLA,environment,bindings:gate.value.bindings,importsThunk,importsBound:false,bindingImports:false,dependenciesThunk:dependencyInitializersThunk,dependencies:null,component:null,index:0,low:0,order:0,onStack:false,pending:0,parents:[],state:0};function initializer(){prepare(record);if(record.component.failed)throw record.component.error;if(!record.component.done)return promiseFor(record.component)}record.initializer=initializer;defineProperty(initializer,privateKey,{value:function(token){if(token!==protocolToken)throw new TypeError(\"Private async module protocol\");return record}});defineProperty(initializer,\"namespace\",{value:gate.value.namespace});return initializer}}(Promise,Reflect.apply,Object.defineProperty,Symbol(\"async module protocol\"),Promise.prototype.then,Object.getOwnPropertyDescriptor)";
