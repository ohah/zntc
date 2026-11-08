//! Native async-module resource protocol. The source producer owns stack,
//! resource declarations, completion records, and its surrounding finally.
//! https://tc39.es/ecma262/#sec-getdisposemethod
//! https://tc39.es/ecma262/#sec-disposeresources
//! Yielded values are awaited directly by the native module scheduler.
//! SuppressedError message matches the pinned Node disposal observation;
//! its message text is not asserted as a universal specification requirement.

pub const ACQUIRE_EXPRESSION: []const u8 =
    \\(function(asyncDispose, syncDispose, apply, PromiseConstructor, TypeErrorConstructor, ObjectConstructor) {
    \\  var defineProperty = ObjectConstructor.defineProperty;
    \\  return function(stack, value, asyncHint) {
    \\    if (value === null || value === void 0) {
    \\      if (asyncHint) defineProperty(stack, stack.length, { __proto__: null, value: { value: void 0, method: void 0, asyncHint: true }, writable: true, enumerable: true, configurable: true });
    \\      return value;
    \\    }
    \\    if (ObjectConstructor(value) !== value)
    \\      throw new TypeErrorConstructor('Disposable resource must be an object');
    \\    var method;
    \\    if (asyncHint) method = value[asyncDispose];
    \\    if (method === null || method === void 0) {
    \\      method = value[syncDispose];
    \\      if (method !== null && method !== void 0 && typeof method !== 'function')
    \\        throw new TypeErrorConstructor('Dispose method must be callable');
    \\      if (asyncHint && method !== null && method !== void 0) {
    \\        method = (function(syncMethod) {
    \\          return function() {
    \\            var receiver = this;
    \\            return new PromiseConstructor(function(resolve, reject) {
    \\              try { apply(syncMethod, receiver, []); resolve(void 0); }
    \\              catch (error) { reject(error); }
    \\            });
    \\          };
    \\        })(method);
    \\      }
    \\    } else if (typeof method !== 'function') {
    \\      throw new TypeErrorConstructor('Dispose method must be callable');
    \\    }
    \\    if (method === null || method === void 0)
    \\      throw new TypeErrorConstructor('Object is not disposable');
    \\    defineProperty(stack, stack.length, { __proto__: null, value: { value: value, method: method, asyncHint: !!asyncHint }, writable: true, enumerable: true, configurable: true });
    \\    return value;
    \\  };
    \\})(Symbol.asyncDispose, Symbol.dispose, Reflect.apply, Promise, TypeError, Object)
;

pub const ACQUIRE_EXPRESSION_MIN: []const u8 = "(function(asyncDispose,syncDispose,apply,PromiseConstructor,TypeErrorConstructor,ObjectConstructor){var defineProperty=ObjectConstructor.defineProperty;return function(stack,value,asyncHint){if(value===null||value===undefined){if(asyncHint)defineProperty(stack,stack.length,{__proto__:null,value:{value:undefined,method:undefined,asyncHint:true},writable:true,enumerable:true,configurable:true});return value}if(ObjectConstructor(value)!==value)throw new TypeErrorConstructor(\"Disposable resource must be an object\");var method;if(asyncHint)method=value[asyncDispose];if(method===null||method===undefined){method=value[syncDispose];if(method!==null&&method!==undefined&&typeof method!==\"function\")throw new TypeErrorConstructor(\"Dispose method must be callable\");if(asyncHint&&method!==null&&method!==undefined){method=function(syncMethod){return function(){var receiver=this;return new PromiseConstructor(function(resolve,reject){try{apply(syncMethod,receiver,[]);resolve(undefined)}catch(error){reject(error)}})}}(method)}}else if(typeof method!==\"function\"){throw new TypeErrorConstructor(\"Dispose method must be callable\")}if(method===null||method===undefined)throw new TypeErrorConstructor(\"Object is not disposable\");defineProperty(stack,stack.length,{__proto__:null,value:{value,method,asyncHint:!!asyncHint},writable:true,enumerable:true,configurable:true});return value}})(Symbol.asyncDispose,Symbol.dispose,Reflect.apply,Promise,TypeError,Object)";

pub const DISPOSE_GENERATOR_EXPRESSION: []const u8 =
    \\(function(apply, SuppressedErrorConstructor) {
    \\  return function*(stack, hasError, error) {
    \\    var needsAwait = false, hasAwaited = false;
    \\    while (stack.length) {
    \\      var resource = stack[stack.length - 1]; stack.length--;
    \\      if (!resource.asyncHint && needsAwait && !hasAwaited) {
    \\        yield void 0;
    \\        needsAwait = false;
    \\      }
    \\      if (resource.method === void 0) {
    \\        needsAwait = true;
    \\        continue;
    \\      }
    \\      try {
    \\        var result = apply(resource.method, resource.value, []);
    \\        if (resource.asyncHint) {
    \\          try { yield result; }
    \\          finally { hasAwaited = true; }
    \\        }
    \\      } catch (failure) {
    \\        error = hasError ? new SuppressedErrorConstructor(failure, error, 'An error was suppressed during disposal') : failure;
    \\        hasError = true;
    \\      }
    \\    }
    \\    if (needsAwait && !hasAwaited) yield void 0;
    \\    if (hasError) throw error;
    \\  };
    \\})(Reflect.apply, SuppressedError)
;

pub const DISPOSE_GENERATOR_EXPRESSION_MIN: []const u8 = "(function(apply,SuppressedErrorConstructor){return function*(stack,hasError,error){var needsAwait=false,hasAwaited=false;while(stack.length){var resource=stack[stack.length-1];stack.length--;if(!resource.asyncHint&&needsAwait&&!hasAwaited){yield undefined;needsAwait=false}if(resource.method===undefined){needsAwait=true;continue}try{var result=apply(resource.method,resource.value,[]);if(resource.asyncHint){try{yield result}finally{hasAwaited=true}}}catch(failure){error=hasError?new SuppressedErrorConstructor(failure,error,\"An error was suppressed during disposal\"):failure;hasError=true}}if(needsAwait&&!hasAwaited)yield undefined;if(hasError)throw error}})(Reflect.apply,SuppressedError)";
