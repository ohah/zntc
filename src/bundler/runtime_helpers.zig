//! ZTS Bundler — Runtime Helpers
//!
//! 번들 출력에 주입되는 런타임 헬퍼 상수 모음.
//! emitter.zig, emitChunks, main.zig 등에서 공용으로 사용한다.
//!
//! 각 헬퍼는 normal(포맷팅) + minified 두 벌로 제공.

const std = @import("std");
const RuntimeHelpers = @import("../transformer/transformer.zig").RuntimeHelpers;

// ============================================================
// CJS Interop
// ============================================================

/// __commonJS 팩토리 함수 (esbuild 호환)
pub const CJS_RUNTIME = "var __commonJS = (cb, mod) => function __require() {\n\treturn mod || (0, cb[Object.keys(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;\n};\n";
pub const CJS_RUNTIME_MIN = "var __commonJS=(cb,mod)=>function __require(){return mod||(0,cb[Object.keys(cb)[0]])((mod={exports:{}}).exports,mod),mod.exports};";

/// __toESM: CJS 모듈을 ESM namespace로 변환 (esbuild/rolldown 호환).
/// isNodeMode=true(--platform=node)이면 항상 default: mod를 설정.
/// __esModule=true이면 원본 프로퍼티를 사용하되 default는 추가하지 않음.
/// 참고: references/esbuild/internal/runtime/runtime.go:231
///       references/rolldown/crates/rolldown/src/runtime/index.js:86
pub const TOESM_RUNTIME =
    \\var __getProtoOf = Object.getPrototypeOf;
    \\var __defProp = Object.defineProperty;
    \\var __hasOwn = Object.prototype.hasOwnProperty;
    \\var __copyProps = (to, from) => { for (let key in from) if (__hasOwn.call(from, key) && !__hasOwn.call(to, key)) __defProp(to, key, { get: () => from[key], enumerable: true }); return to; };
    \\var __toESM = (mod, isNodeMode, target) => (target = mod != null ? Object.create(__getProtoOf(mod)) : {}, __copyProps(isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target, mod));
    \\
;
pub const TOESM_RUNTIME_MIN = "var __getProtoOf=Object.getPrototypeOf;var __defProp=Object.defineProperty;var __hasOwn=Object.prototype.hasOwnProperty;var __copyProps=(to,from)=>{for(let key in from)if(__hasOwn.call(from,key)&&!__hasOwn.call(to,key))__defProp(to,key,{get:()=>from[key],enumerable:true});return to};var __toESM=(mod,isNodeMode,target)=>(target=mod!=null?Object.create(__getProtoOf(mod)):{},__copyProps(isNodeMode||!mod||!mod.__esModule?__defProp(target,\"default\",{value:mod,enumerable:true}):target,mod));";

// ============================================================
// Decorator
// ============================================================

/// __decorateClass: experimental decorators 변환 시 주입 (esbuild 호환).
/// __defProp은 __toESM 런타임에도 있지만, decorator 단독 사용 시를 위해 별도 선언.
pub const DECORATOR_RUNTIME =
    \\var __defProp2 = Object.defineProperty;
    \\var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
    \\var __decorateClass = (decorators, target, key, kind) => {
    \\  var result = kind > 1 ? void 0 : kind ? __getOwnPropDesc(target, key) : target;
    \\  for (var i = decorators.length - 1, decorator; i >= 0; i--)
    \\    if (decorator = decorators[i])
    \\      result = (kind ? decorator(target, key, result) : decorator(result)) || result;
    \\  if (kind && result) __defProp2(target, key, result);
    \\  return result;
    \\};
    \\var __decorateParam = (index, decorator) => (target, key) => decorator(target, key, index);
    \\
;
pub const DECORATOR_RUNTIME_MIN = "var __defProp2=Object.defineProperty;var __getOwnPropDesc=Object.getOwnPropertyDescriptor;var __decorateClass=(decorators,target,key,kind)=>{var result=kind>1?void 0:kind?__getOwnPropDesc(target,key):target;for(var i=decorators.length-1,decorator;i>=0;i--)if(decorator=decorators[i])result=(kind?decorator(target,key,result):decorator(result))||result;if(kind&&result)__defProp2(target,key,result);return result};var __decorateParam=(index,decorator)=>(target,key)=>decorator(target,key,index);";

// ============================================================
// ES2015+ Downlevel
// ============================================================

/// __async: async/await → generator 변환 시 주입 (esbuild 호환).
/// generator-to-Promise wrapper. this/arguments를 fn.apply로 보존.
///
/// 스펙 참고: esbuild internal/runtime/runtime.go __async
pub const ASYNC_RUNTIME =
    \\var __async = (fn) => function(...args) {
    \\  return new Promise((resolve, reject) => {
    \\    var gen = fn.apply(this, args);
    \\    function step(key, arg) {
    \\      try { var info = gen[key](arg); var value = info.value; }
    \\      catch (error) { reject(error); return; }
    \\      if (info.done) resolve(value);
    \\      else Promise.resolve(value).then(val => step("next", val), err => step("throw", err));
    \\    }
    \\    step("next");
    \\  });
    \\};
    \\
;
pub const ASYNC_RUNTIME_MIN = "var __async=(fn)=>function(...args){return new Promise((resolve,reject)=>{var gen=fn.apply(this,args);function step(key,arg){try{var info=gen[key](arg);var value=info.value}catch(error){reject(error);return}if(info.done)resolve(value);else Promise.resolve(value).then(val=>step(\"next\",val),err=>step(\"throw\",err))}step(\"next\")})};";

/// __extends: class 상속 prototype chain (ES2015). TypeScript __extends 호환.
pub const EXTENDS_RUNTIME = "var __extends = function(d, b) {\n  for (var p in b) if (Object.prototype.hasOwnProperty.call(b, p)) d[p] = b[p];\n  function __() { this.constructor = d; }\n  d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());\n};\n";
pub const EXTENDS_RUNTIME_MIN = "var __extends=function(d,b){for(var p in b)if(Object.prototype.hasOwnProperty.call(b,p))d[p]=b[p];function __(){this.constructor=d}d.prototype=b===null?Object.create(b):(__.prototype=b.prototype,new __())};";

/// __generator: generator 상태 머신 (ES2015). TypeScript __generator 호환.
/// yield/return/throw를 label 기반 switch로 처리.
pub const GENERATOR_RUNTIME = "var __generator = function(body) {\n  var _ = { label: 0, sent: function() { return t[1]; }, trys: [], ops: [] }, f, y, t, g;\n  return g = { next: verb(0), \"throw\": verb(1), \"return\": verb(2) }, g[Symbol.iterator] = function() { return this; }, g;\n  function verb(n) { return function(v) { return step([n, v]); }; }\n  function step(op) {\n    if (f) throw new TypeError(\"Generator is already executing.\");\n    while (g && (g = 0, op[0] && (_ = 0)), _) try {\n      if (f = 1, y && (t = op[0] & 2 ? y[\"return\"] : op[0] ? y[\"throw\"] || ((t = y[\"return\"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;\n      if (y = 0, t) op = [op[0] & 2, t.value];\n      switch (op[0]) {\n        case 0: case 1: t = op; break;\n        case 4: _.label++; return { value: op[1], done: false };\n        case 5: _.label++; y = op[1]; op = [0]; continue;\n        case 7: op = _.ops.pop(); _.trys.pop(); continue;\n        default:\n          if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }\n          if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }\n          if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }\n          if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }\n          if (t[2]) _.ops.pop();\n          _.trys.pop(); continue;\n      }\n      op = body.call(null, _);\n    } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }\n    if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };\n  }\n};\n";
pub const GENERATOR_RUNTIME_MIN = "var __generator=function(body){var _={label:0,sent:function(){return t[1]},trys:[],ops:[]},f,y,t,g;return g={next:verb(0),\"throw\":verb(1),\"return\":verb(2)},g[Symbol.iterator]=function(){return this},g;function verb(n){return function(v){return step([n,v])}}function step(op){if(f)throw new TypeError(\"Generator is already executing.\");while(g&&(g=0,op[0]&&(_=0)),_)try{if(f=1,y&&(t=op[0]&2?y[\"return\"]:op[0]?y[\"throw\"]||((t=y[\"return\"])&&t.call(y),0):y.next)&&!(t=t.call(y,op[1])).done)return t;if(y=0,t)op=[op[0]&2,t.value];switch(op[0]){case 0:case 1:t=op;break;case 4:_.label++;return{value:op[1],done:false};case 5:_.label++;y=op[1];op=[0];continue;case 7:op=_.ops.pop();_.trys.pop();continue;default:if(!(t=_.trys,t=t.length>0&&t[t.length-1])&&(op[0]===6||op[0]===2)){_=0;continue}if(op[0]===3&&(!t||(op[1]>t[0]&&op[1]<t[3]))){_.label=op[1];break}if(op[0]===6&&_.label<t[1]){_.label=t[1];t=op;break}if(t&&_.label<t[2]){_.label=t[2];_.ops.push(op);break}if(t[2])_.ops.pop();_.trys.pop();continue}op=body.call(null,_)}catch(e){op=[6,e];y=0}finally{f=t=0}if(op[0]&5)throw op[1];return{value:op[0]?op[1]:void 0,done:true}}};";

/// __rest: object destructuring rest (ES2018). TypeScript __rest 호환.
/// exclude 배열에 없는 own 프로퍼티만 복사.
pub const REST_RUNTIME = "var __rest = function(s, e) {\n  var t = {};\n  for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p) && e.indexOf(p) < 0) t[p] = s[p];\n  return t;\n};\n";
pub const REST_RUNTIME_MIN = "var __rest=function(s,e){var t={};for(var p in s)if(Object.prototype.hasOwnProperty.call(s,p)&&e.indexOf(p)<0)t[p]=s[p];return t};";

// ============================================================
// Asset Loader
// ============================================================

/// __toBinary: base64 문자열 → Uint8Array 변환 (binary 로더용, rolldown 호환).
/// atob()로 디코딩 후 각 charCode를 Uint8Array에 복사.
pub const TO_BINARY_RUNTIME =
    \\var __toBinary = function(b64) {
    \\  var str = atob(b64), arr = new Uint8Array(str.length);
    \\  for (var i = 0; i < str.length; i++) arr[i] = str.charCodeAt(i);
    \\  return arr;
    \\};
    \\
;
pub const TO_BINARY_RUNTIME_MIN = "var __toBinary=function(b64){var str=atob(b64),arr=new Uint8Array(str.length);for(var i=0;i<str.length;i++)arr[i]=str.charCodeAt(i);return arr};";

/// __name: 함수/클래스의 .name 프로퍼티를 보존 (esbuild --keep-names 호환).
/// minify로 식별자가 축약되어도 원래 이름을 .name에 설정.
pub const KEEP_NAMES_RUNTIME = "var __name = (target, value) => Object.defineProperty(target, \"name\", { value, configurable: true });\n";
pub const KEEP_NAMES_RUNTIME_MIN = "var __name=(target,value)=>Object.defineProperty(target,\"name\",{value,configurable:true});";

// ============================================================
// HMR (Dev Server)
// ============================================================

/// HMR 런타임: 모듈 레지스트리 + __zts_require + import.meta.hot API.
/// dev mode 번들 상단에 주��된다.
///
/// 구조:
///   __zts_modules[id] = { factory, exports, hot }
///   __zts_require(id) → 모듈의 exports 반환
///   __zts_make_hot(id) → import.meta.hot 호환 API 객체
///   __zts_apply_update(id, code) → 모듈 재실행 (WS에서 호출)
pub const HMR_RUNTIME =
    \\var __zts_modules = {};
    \\var __zts_hot_cbs = {};
    \\var __zts_hot_data = {};
    \\function __zts_require(id) {
    \\  var m = __zts_modules[id];
    \\  if (!m) throw new Error("[zts] Module not found: " + id);
    \\  return m.exports;
    \\}
    \\function __zts_make_hot(id) {
    \\  if (!__zts_hot_cbs[id]) __zts_hot_cbs[id] = {};
    \\  return {
    \\    get data() { return __zts_hot_data[id]; },
    \\    accept: function(deps, cb) {
    \\      if (typeof deps === "function") { cb = deps; deps = undefined; }
    \\      __zts_hot_cbs[id].accept = cb || true;
    \\      if (Array.isArray(deps)) __zts_hot_cbs[id].acceptDeps = deps;
    \\    },
    \\    dispose: function(cb) { __zts_hot_cbs[id].dispose = cb; },
    \\    prune: function(cb) { __zts_hot_cbs[id].prune = cb; },
    \\    invalidate: function() { location.reload(); }
    \\  };
    \\}
    \\function __zts_register(id, factory) {
    \\  var prev = __zts_modules[id];
    \\  var mod = { exports: {}, hot: __zts_make_hot(id), factory: factory };
    \\  __zts_modules[id] = mod;
    \\  window.__zts_currentModuleId = id;
    \\  factory(mod, mod.exports);
    \\  if (prev) {
    \\    var cbs = __zts_hot_cbs[id];
    \\    if (cbs && cbs.dispose) {
    \\      __zts_hot_data[id] = {};
    \\      cbs.dispose(__zts_hot_data[id]);
    \\    }
    \\  }
    \\}
    \\function __zts_apply_update(updates) {
    \\  for (var i = 0; i < updates.length; i++) {
    \\    var id = updates[i].id;
    \\    var cbs = __zts_hot_cbs[id];
    \\    if (!cbs || !cbs.accept) { location.reload(); return; }
    \\    try {
    \\      var fn = new Function("__zts_register", "__zts_require", "__zts_make_hot", updates[i].code);
    \\      fn(__zts_register, __zts_require, __zts_make_hot);
    \\      if (typeof cbs.accept === "function") cbs.accept();
    \\    } catch(e) { console.error("[zts] HMR update failed:", e); location.reload(); }
    \\  }
    \\  if (typeof __zts_RefreshRuntime !== "undefined") __zts_RefreshRuntime.performReactRefresh();
    \\}
    \\var __zts_RefreshRuntime = window.__REACT_REFRESH_RUNTIME__;
    \\window.$RefreshReg$ = function(type, id) {
    \\  if (__zts_RefreshRuntime) __zts_RefreshRuntime.register(type, window.__zts_currentModuleId + " " + id);
    \\};
    \\window.$RefreshSig$ = function() {
    \\  if (__zts_RefreshRuntime) return __zts_RefreshRuntime.createSignatureFunctionForTransform();
    \\  return function(type) { return type; };
    \\};
    \\
;

pub const HMR_RUNTIME_MIN =
    \\var __zts_modules={},__zts_hot_cbs={},__zts_hot_data={};function __zts_require(id){var m=__zts_modules[id];if(!m)throw new Error("[zts] Module not found: "+id);return m.exports}function __zts_make_hot(id){if(!__zts_hot_cbs[id])__zts_hot_cbs[id]={};return{get data(){return __zts_hot_data[id]},accept:function(d,c){if(typeof d==="function"){c=d;d=void 0}__zts_hot_cbs[id].accept=c||true;if(Array.isArray(d))__zts_hot_cbs[id].acceptDeps=d},dispose:function(c){__zts_hot_cbs[id].dispose=c},prune:function(c){__zts_hot_cbs[id].prune=c},invalidate:function(){location.reload()}}}function __zts_register(id,f){var p=__zts_modules[id];var m={exports:{},hot:__zts_make_hot(id),factory:f};__zts_modules[id]=m;f(m,m.exports);if(p){var c=__zts_hot_cbs[id];if(c&&c.dispose){__zts_hot_data[id]={};c.dispose(__zts_hot_data[id])}}}function __zts_apply_update(u){for(var i=0;i<u.length;i++){var id=u[i].id;var c=__zts_hot_cbs[id];if(!c||!c.accept){location.reload();return}try{var fn=new Function("__zts_register","__zts_require","__zts_make_hot",u[i].code);fn(__zts_register,__zts_require,__zts_make_hot);if(typeof c.accept==="function")c.accept()}catch(e){console.error("[zts] HMR update failed:",e);location.reload()}}}
;

/// HMR 런타임의 줄 수 (소스맵 오프셋 계산���, comptime)
pub const HMR_RUNTIME_LINES = blk: {
    @setEvalBranchQuota(10000);
    break :blk @as(u32, std.mem.count(u8, HMR_RUNTIME, "\n"));
};

// ============================================================
// Append Helper
// ============================================================

/// 런타임 헬퍼 문자열을 ArrayList에 주입한다.
/// standalone 트랜스파일(main.zig)에서도 사용할 수 있도록 pub으로 노출.
pub fn appendRuntimeHelpers(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, helpers: RuntimeHelpers, minify: bool) !void {
    if (helpers.extends) {
        try buf.appendSlice(allocator, if (minify) EXTENDS_RUNTIME_MIN else EXTENDS_RUNTIME);
    }
    if (helpers.generator) {
        try buf.appendSlice(allocator, if (minify) GENERATOR_RUNTIME_MIN else GENERATOR_RUNTIME);
    }
    if (helpers.rest) {
        try buf.appendSlice(allocator, if (minify) REST_RUNTIME_MIN else REST_RUNTIME);
    }
    if (helpers.async_helper) {
        try buf.appendSlice(allocator, if (minify) ASYNC_RUNTIME_MIN else ASYNC_RUNTIME);
    }
    if (helpers.to_binary) {
        try buf.appendSlice(allocator, if (minify) TO_BINARY_RUNTIME_MIN else TO_BINARY_RUNTIME);
    }
    if (helpers.keep_names) {
        try buf.appendSlice(allocator, if (minify) KEEP_NAMES_RUNTIME_MIN else KEEP_NAMES_RUNTIME);
    }
}

/// CJS interop 런타임을 ���입한다 (__commonJS + __toESM).
pub fn appendCjsRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool) !void {
    if (minify) {
        try buf.appendSlice(allocator, CJS_RUNTIME_MIN);
        try buf.appendSlice(allocator, TOESM_RUNTIME_MIN);
    } else {
        try buf.appendSlice(allocator, CJS_RUNTIME);
        try buf.appendSlice(allocator, TOESM_RUNTIME);
    }
}

/// Decorator 런타임을 주입한다.
pub fn appendDecoratorRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool) !void {
    if (minify) {
        try buf.appendSlice(allocator, DECORATOR_RUNTIME_MIN);
    } else {
        try buf.appendSlice(allocator, DECORATOR_RUNTIME);
    }
}

/// Async 런타임을 주입한다.
pub fn appendAsyncRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool) !void {
    if (minify) {
        try buf.appendSlice(allocator, ASYNC_RUNTIME_MIN);
    } else {
        try buf.appendSlice(allocator, ASYNC_RUNTIME);
    }
}

/// HMR 런타임을 주입한다.
pub fn appendHmrRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool) !void {
    if (minify) {
        try buf.appendSlice(allocator, HMR_RUNTIME_MIN);
    } else {
        try buf.appendSlice(allocator, HMR_RUNTIME);
    }
}
