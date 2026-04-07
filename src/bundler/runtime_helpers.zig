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

/// __commonJS ES5 호환: arrow → function.
pub const CJS_RUNTIME_ES5 = "var __commonJS = function(cb, mod) { return function __require() {\n\treturn mod || (0, cb[Object.keys(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;\n}; };\n";
pub const CJS_RUNTIME_ES5_MIN = "var __commonJS=function(cb,mod){return function __require(){return mod||(0,cb[Object.keys(cb)[0]])((mod={exports:{}}).exports,mod),mod.exports}}";

/// __toESM: CJS 모듈을 ESM namespace로 변환 (rolldown 호환).
/// isNodeMode=true(--platform=node)이면 항상 default: mod를 설정.
/// __esModule=true이면 원본 프로퍼티를 사용하되 default는 추가하지 않음.
///
/// __copyProps: getOwnPropertyNames로 non-enumerable 포함 전체 프로퍼티를 복사하고,
/// 원본 descriptor의 enumerable 플래그를 보존한다. bind로 key를 고정하여 var 루프에서도 안전.
/// 참고: references/rolldown/crates/rolldown/src/runtime/index.js:86
pub const TOESM_RUNTIME =
    \\var __create = Object.create;
    \\var __getProtoOf = Object.getPrototypeOf;
    \\var __defProp = Object.defineProperty;
    \\var __getOwnPropNames = Object.getOwnPropertyNames;
    \\var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
    \\var __hasOwn = Object.prototype.hasOwnProperty;
    \\var __copyProps = (to, from, except, desc) => {
    \\  if (from && typeof from === "object" || typeof from === "function") {
    \\    for (var keys = __getOwnPropNames(from), i = 0, n = keys.length, key; i < n; i++) {
    \\      key = keys[i];
    \\      if (!__hasOwn.call(to, key) && key !== except)
    \\        __defProp(to, key, { get: ((k) => from[k]).bind(null, key), enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    \\    }
    \\  }
    \\  return to;
    \\};
    \\var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target, mod));
    \\
;
pub const TOESM_RUNTIME_MIN = "var __create=Object.create;var __getProtoOf=Object.getPrototypeOf;var __defProp=Object.defineProperty;var __getOwnPropNames=Object.getOwnPropertyNames;var __getOwnPropDesc=Object.getOwnPropertyDescriptor;var __hasOwn=Object.prototype.hasOwnProperty;var __copyProps=(to,from,except,desc)=>{if(from&&typeof from===\"object\"||typeof from===\"function\"){for(var keys=__getOwnPropNames(from),i=0,n=keys.length,key;i<n;i++){key=keys[i];if(!__hasOwn.call(to,key)&&key!==except)__defProp(to,key,{get:((k)=>from[k]).bind(null,key),enumerable:!(desc=__getOwnPropDesc(from,key))||desc.enumerable})}}return to};var __toESM=(mod,isNodeMode,target)=>(target=mod!=null?__create(__getProtoOf(mod)):{},__copyProps(isNodeMode||!mod||!mod.__esModule?__defProp(target,\"default\",{value:mod,enumerable:true}):target,mod));";

/// __toESM configurable + ES5 호환: RN/Hermes용.
/// arrow → function, configurable: true. --platform=react-native에서 자동 활성화.
pub const TOESM_RUNTIME_CONFIGURABLE =
    \\var __create = Object.create;
    \\var __getProtoOf = Object.getPrototypeOf;
    \\var __defProp = Object.defineProperty;
    \\var __getOwnPropNames = Object.getOwnPropertyNames;
    \\var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
    \\var __hasOwn = Object.prototype.hasOwnProperty;
    \\var __copyProps = function(to, from, except, desc) {
    \\  if (from && typeof from === "object" || typeof from === "function") {
    \\    for (var keys = __getOwnPropNames(from), i = 0, n = keys.length, key; i < n; i++) {
    \\      key = keys[i];
    \\      if (!__hasOwn.call(to, key) && key !== except)
    \\        __defProp(to, key, { get: (function(k) { return from[k]; }).bind(null, key), enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable, configurable: true });
    \\    }
    \\  }
    \\  return to;
    \\};
    \\var __toESM = function(mod, isNodeMode, target) { return target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true, configurable: true }) : target, mod); };
    \\
;
pub const TOESM_RUNTIME_CONFIGURABLE_MIN = "var __create=Object.create;var __getProtoOf=Object.getPrototypeOf;var __defProp=Object.defineProperty;var __getOwnPropNames=Object.getOwnPropertyNames;var __getOwnPropDesc=Object.getOwnPropertyDescriptor;var __hasOwn=Object.prototype.hasOwnProperty;var __copyProps=function(to,from,except,desc){if(from&&typeof from===\"object\"||typeof from===\"function\"){for(var keys=__getOwnPropNames(from),i=0,n=keys.length,key;i<n;i++){key=keys[i];if(!__hasOwn.call(to,key)&&key!==except)__defProp(to,key,{get:(function(k){return from[k]}).bind(null,key),enumerable:!(desc=__getOwnPropDesc(from,key))||desc.enumerable,configurable:true})}}return to};var __toESM=function(mod,isNodeMode,target){return target=mod!=null?__create(__getProtoOf(mod)):{},__copyProps(isNodeMode||!mod||!mod.__esModule?__defProp(target,\"default\",{value:mod,enumerable:true,configurable:true}):target,mod)};";

/// __esm: ESM 모듈의 지연 초기화 팩토리 (esbuild 호환).
/// ESM 모듈이 require()로 소비될 때 사용. 한 번만 실행되고 결과를 캐시.
/// 참고: references/esbuild/internal/runtime/runtime.go:173
pub const ESM_RUNTIME = "var __esm = (fn, res) => function __init() {\n\treturn fn && (res = (0, fn[Object.keys(fn)[0]])(fn = 0)), res;\n};\n";
pub const ESM_RUNTIME_MIN = "var __esm=(fn,res)=>function __init(){return fn&&(res=(0,fn[Object.keys(fn)[0]])(fn=0)),res};";

/// __esm ES5 호환: arrow → function.
pub const ESM_RUNTIME_ES5 = "var __esm = function(fn, res) { return function __init() {\n\treturn fn && (res = (0, fn[Object.keys(fn)[0]])(fn = 0)), res;\n}; };\n";
pub const ESM_RUNTIME_ES5_MIN = "var __esm=function(fn,res){return function __init(){return fn&&(res=(0,fn[Object.keys(fn)[0]])(fn=0)),res}}";

/// __export: ESM namespace 객체에 live getter 등록 (esbuild 호환).
/// var foo_exports = {}; __export(foo_exports, { greet: () => greet });
/// __defProp은 __toESM 런타임에 이미 정의됨.
/// 참고: references/esbuild/internal/runtime/runtime.go:187
pub const EXPORT_RUNTIME = "var __export = (target, all) => {\n\tfor (var name in all)\n\t\t__defProp(target, name, { get: all[name], enumerable: true });\n};\n";
pub const EXPORT_RUNTIME_MIN = "var __export=(target,all)=>{for(var name in all)__defProp(target,name,{get:all[name],enumerable:true})};";

/// __export configurable 버전: RN/Hermes 호환.
pub const EXPORT_RUNTIME_CONFIGURABLE = "var __export = function(target, all) {\n\tfor (var name in all)\n\t\t__defProp(target, name, { get: all[name], enumerable: true, configurable: true });\n};\n";
pub const EXPORT_RUNTIME_CONFIGURABLE_MIN = "var __export=function(target,all){for(var name in all)__defProp(target,name,{get:all[name],enumerable:true,configurable:true})};";

/// __toCommonJS: ESM namespace → CJS 호환 객체 변환 (rolldown 호환).
/// __commonJS로 래핑된 모듈은 mod["module.exports"]에 원본 exports가 있으므로
/// 복사 없이 직접 반환하여 getter/non-enumerable 프로퍼티를 보존한다.
/// 그 외에는 { __esModule: true } + 원본 프로퍼티 복사.
/// 참고: references/rolldown/crates/rolldown/src/runtime/index.js:105
/// __copyProps, __defProp, __hasOwn은 __toESM 런타임에 이미 정의됨.
pub const TOCOMMONJS_RUNTIME = "var __toCommonJS = mod => __hasOwn.call(mod, 'module.exports') ? mod['module.exports'] : __copyProps(__defProp({}, '__esModule', { value: true }), mod);\n";
pub const TOCOMMONJS_RUNTIME_MIN = "var __toCommonJS=mod=>__hasOwn.call(mod,\"module.exports\")?mod[\"module.exports\"]:__copyProps(__defProp({},\"__esModule\",{value:true}),mod);";

/// __toCommonJS configurable 버전: RN/Hermes 호환.
pub const TOCOMMONJS_RUNTIME_CONFIGURABLE = "var __toCommonJS = function(mod) { return __hasOwn.call(mod, 'module.exports') ? mod['module.exports'] : __copyProps(__defProp({}, '__esModule', { value: true, configurable: true }), mod); };\n";
pub const TOCOMMONJS_RUNTIME_CONFIGURABLE_MIN = "var __toCommonJS=function(mod){return __hasOwn.call(mod,\"module.exports\")?mod[\"module.exports\"]:__copyProps(__defProp({},\"__esModule\",{value:true,configurable:true}),mod)};";

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

/// __metadata: emitDecoratorMetadata 시 Reflect.metadata 호출 (TypeScript 호환).
/// design:type, design:paramtypes, design:returntype 메타데이터를 클래스/멤버에 부착.
pub const METADATA_RUNTIME =
    \\var __metadata = (key, value) => {
    \\  if (typeof Reflect !== "undefined" && typeof Reflect.metadata === "function")
    \\    return Reflect.metadata(key, value);
    \\};
    \\
;
pub const METADATA_RUNTIME_MIN = "var __metadata=(key,value)=>{if(typeof Reflect!==\"undefined\"&&typeof Reflect.metadata===\"function\")return Reflect.metadata(key,value)};";

// ============================================================
// ES2015+ Downlevel
// ============================================================

/// __classCallCheck: class를 new 없이 호출하면 TypeError (ES2015 스펙 준수).
pub const CLASS_CALL_CHECK_RUNTIME =
    \\var __classCallCheck = function(instance, Constructor) {
    \\  if (!(instance instanceof Constructor))
    \\    throw new TypeError("Cannot call a class as a function");
    \\};
    \\
;
pub const CLASS_CALL_CHECK_RUNTIME_MIN = "var __classCallCheck=function(instance,Constructor){if(!(instance instanceof Constructor))throw new TypeError(\"Cannot call a class as a function\")};";

/// __callSuper: super() 호출을 Reflect.construct로 래핑 (SWC _call_super 호환).
/// 네이티브 ES6 클래스(Error, Map 등)를 extends할 때 .call()이 불가하므로
/// Reflect.construct를 사용하여 올바른 내부 슬롯을 가진 인스턴스를 생성.
/// 트랜스파일된 클래스에는 fallback으로 .apply()를 사용.
pub const CALL_SUPER_RUNTIME =
    \\var __callSuper = function(_this, Parent, args) {
    \\  if (typeof Reflect !== "undefined" && typeof Reflect.construct === "function") {
    \\    return Reflect.construct(Parent, args || [], _this.constructor);
    \\  }
    \\  var result = Parent.apply(_this, args);
    \\  if (result && (typeof result === "object" || typeof result === "function")) return result;
    \\  return _this;
    \\};
    \\
;
pub const CALL_SUPER_RUNTIME_MIN = "var __callSuper=function(_this,Parent,args){if(typeof Reflect!==\"undefined\"&&typeof Reflect.construct===\"function\")return Reflect.construct(Parent,args||[],_this.constructor);var result=Parent.apply(_this,args);if(result&&(typeof result===\"object\"||typeof result===\"function\"))return result;return _this};";

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

/// __async ES5 호환: arrow function, rest params 없이 동일 동작.
pub const ASYNC_RUNTIME_ES5 =
    \\var __async = function(fn) {
    \\  return function() {
    \\    var args = Array.prototype.slice.call(arguments);
    \\    var self = this;
    \\    return new Promise(function(resolve, reject) {
    \\      var gen = fn.apply(self, args);
    \\      function step(key, arg) {
    \\        try { var info = gen[key](arg); var value = info.value; }
    \\        catch (error) { reject(error); return; }
    \\        if (info.done) resolve(value);
    \\        else Promise.resolve(value).then(function(val) { step("next", val); }, function(err) { step("throw", err); });
    \\      }
    \\      step("next");
    \\    });
    \\  };
    \\};
    \\
;
pub const ASYNC_RUNTIME_ES5_MIN = "var __async=function(fn){return function(){var args=Array.prototype.slice.call(arguments);var self=this;return new Promise(function(resolve,reject){var gen=fn.apply(self,args);function step(key,arg){try{var info=gen[key](arg);var value=info.value}catch(error){reject(error);return}if(info.done)resolve(value);else Promise.resolve(value).then(function(val){step(\"next\",val)},function(err){step(\"throw\",err)})}step(\"next\")})}};";

/// __extends: class 상속 prototype chain (ES2015). TypeScript __extends 호환.
pub const EXTENDS_RUNTIME = "var __extends = function(d, b) {\n  for (var p in b) if (Object.prototype.hasOwnProperty.call(b, p)) d[p] = b[p];\n  function __() { this.constructor = d; }\n  d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());\n};\n";
pub const EXTENDS_RUNTIME_MIN = "var __extends=function(d,b){for(var p in b)if(Object.prototype.hasOwnProperty.call(b,p))d[p]=b[p];function __(){this.constructor=d}d.prototype=b===null?Object.create(b):(__.prototype=b.prototype,new __())};";

/// __generator: generator 상태 머신 (ES2015). TypeScript __generator 호환.
/// yield/return/throw를 label 기반 switch로 처리.
/// 두 번째 인자 genFn을 받아 프로토타입 체인을 설정:
///   g -> genFn.prototype -> __GeneratorPrototype -> IteratorPrototype (Symbol.iterator)
/// compat-table "%GeneratorPrototype% prototype chain" 테스트 통과를 위해 필요.
pub const GENERATOR_RUNTIME =
    \\var __generator = function() {
    \\  var __iterProto = {};
    \\  __iterProto[Symbol.iterator] = function() { return this; };
    \\  var __genProto = Object.create(__iterProto);
    \\  var __protoSet = typeof Symbol !== "undefined" ? Symbol("__protoSet") : "__gen_proto_set__";
    \\  return function(body, genFn) {
    \\    var _ = { label: 0, sent: function() { return t[1]; }, trys: [], ops: [] }, f, y, t, g;
    \\    if (genFn) {
    \\      if (!genFn[__protoSet]) {
    \\        Object.setPrototypeOf(genFn.prototype, __genProto);
    \\        genFn[__protoSet] = true;
    \\      }
    \\      g = Object.create(genFn.prototype);
    \\    } else {
    \\      g = {};
    \\      g[Symbol.iterator] = function() { return this; };
    \\    }
    \\    g.next = verb(0); g["throw"] = verb(1); g["return"] = verb(2);
    \\    return g;
    \\    function verb(n) { return function(v) { return step([n, v]); }; }
    \\    function step(op) {
    \\      if (f) throw new TypeError("Generator is already executing.");
    \\      while (g && (g = 0, op[0] && (_ = 0)), _) try {
    \\        if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
    \\        if (y = 0, t) op = [op[0] & 2, t.value];
    \\        switch (op[0]) {
    \\          case 0: case 1: t = op; break;
    \\          case 4: _.label++; return { value: op[1], done: false };
    \\          case 5: _.label++; y = op[1]; op = [0]; continue;
    \\          case 7: op = _.ops.pop(); _.trys.pop(); continue;
    \\          default:
    \\            if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
    \\            if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
    \\            if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
    \\            if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
    \\            if (t[2]) _.ops.pop();
    \\            _.trys.pop(); continue;
    \\        }
    \\        op = body.call(null, _);
    \\      } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
    \\      if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    \\    }
    \\  };
    \\}();
    \\
;
pub const GENERATOR_RUNTIME_MIN = "var __generator=function(){var __iterProto={};__iterProto[Symbol.iterator]=function(){return this};var __genProto=Object.create(__iterProto);return function(body,genFn){var _={label:0,sent:function(){return t[1]},trys:[],ops:[]},f,y,t,g;if(genFn){if(!genFn.__proto_set){Object.setPrototypeOf(genFn.prototype,__genProto);genFn.__proto_set=true}g=Object.create(genFn.prototype)}else{g={};g[Symbol.iterator]=function(){return this}}g.next=verb(0);g[\"throw\"]=verb(1);g[\"return\"]=verb(2);return g;function verb(n){return function(v){return step([n,v])}}function step(op){if(f)throw new TypeError(\"Generator is already executing.\");while(g&&(g=0,op[0]&&(_=0)),_)try{if(f=1,y&&(t=op[0]&2?y[\"return\"]:op[0]?y[\"throw\"]||((t=y[\"return\"])&&t.call(y),0):y.next)&&!(t=t.call(y,op[1])).done)return t;if(y=0,t)op=[op[0]&2,t.value];switch(op[0]){case 0:case 1:t=op;break;case 4:_.label++;return{value:op[1],done:false};case 5:_.label++;y=op[1];op=[0];continue;case 7:op=_.ops.pop();_.trys.pop();continue;default:if(!(t=_.trys,t=t.length>0&&t[t.length-1])&&(op[0]===6||op[0]===2)){_=0;continue}if(op[0]===3&&(!t||(op[1]>t[0]&&op[1]<t[3]))){_.label=op[1];break}if(op[0]===6&&_.label<t[1]){_.label=t[1];t=op;break}if(t&&_.label<t[2]){_.label=t[2];_.ops.push(op);break}if(t[2])_.ops.pop();_.trys.pop();continue}op=body.call(null,_)}catch(e){op=[6,e];y=0}finally{f=t=0}if(op[0]&5)throw op[1];return{value:op[0]?op[1]:void 0,done:true}}}();";

/// __taggedTemplateLiteral: tagged template literal의 template 객체 생성 (ES2015).
/// cooked 배열에 raw 프로퍼티를 추가하여 Object.freeze로 불변 처리.
/// raw가 cooked와 동일하면 생략 가능 (두 번째 인자 없이 호출).
pub const TAGGED_TEMPLATE_RUNTIME = "var __taggedTemplateLiteral = function(cooked, raw) {\n\tif (!raw) raw = cooked.slice(0);\n\treturn Object.freeze(Object.defineProperty(cooked, \"raw\", { value: Object.freeze(raw) }));\n};\n";
pub const TAGGED_TEMPLATE_RUNTIME_MIN = "var __taggedTemplateLiteral=function(cooked,raw){if(!raw)raw=cooked.slice(0);return Object.freeze(Object.defineProperty(cooked,\"raw\",{value:Object.freeze(raw)}))};";

/// __rest: object destructuring rest (ES2018). TypeScript __rest 호환.
/// exclude 배열에 없는 own 프로퍼티 + Symbol 프로퍼티 복사.
pub const REST_RUNTIME =
    \\var __rest = function(s, e) {
    \\  var t = {};
    \\  for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p) && e.indexOf(p) < 0) t[p] = s[p];
    \\  if (typeof Object.getOwnPropertySymbols === "function")
    \\    for (var i = 0, symbols = Object.getOwnPropertySymbols(s); i < symbols.length; i++)
    \\      if (e.indexOf(symbols[i]) < 0 && Object.prototype.propertyIsEnumerable.call(s, symbols[i]))
    \\        t[symbols[i]] = s[symbols[i]];
    \\  return t;
    \\};
    \\
;
pub const REST_RUNTIME_MIN = "var __rest=function(s,e){var t={};for(var p in s)if(Object.prototype.hasOwnProperty.call(s,p)&&e.indexOf(p)<0)t[p]=s[p];if(typeof Object.getOwnPropertySymbols===\"function\")for(var i=0,symbols=Object.getOwnPropertySymbols(s);i<symbols.length;i++)if(e.indexOf(symbols[i])<0&&Object.prototype.propertyIsEnumerable.call(s,symbols[i]))t[symbols[i]]=s[symbols[i]];return t};";

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
// Private Method (ES2022 downlevel)
// ============================================================

/// __classPrivateMethodInit: WeakSet brand check + add (SWC 호환).
/// private method가 있는 class의 constructor에서 호출.
/// 이미 등록된 인스턴스면 TypeError (재초기화 방지).
pub const PRIVATE_METHOD_INIT_RUNTIME =
    \\var __classPrivateMethodInit = function(obj, privateSet) {
    \\  if (privateSet.has(obj)) throw new TypeError("Cannot initialize the same private elements twice on an object");
    \\  privateSet.add(obj);
    \\};
    \\
;
pub const PRIVATE_METHOD_INIT_RUNTIME_MIN = "var __classPrivateMethodInit=function(obj,privateSet){if(privateSet.has(obj))throw new TypeError(\"Cannot initialize the same private elements twice on an object\");privateSet.add(obj)};";

/// __classPrivateMethodGet: brand check + private method 접근 (SWC 호환).
/// this.#method() 호출 시 brand check 후 함수 참조 반환.
pub const PRIVATE_METHOD_GET_RUNTIME =
    \\var __classPrivateMethodGet = function(receiver, privateSet, fn) {
    \\  if (!privateSet.has(receiver)) throw new TypeError("attempted to get private field on non-instance");
    \\  return fn;
    \\};
    \\
;
pub const PRIVATE_METHOD_GET_RUNTIME_MIN = "var __classPrivateMethodGet=function(receiver,privateSet,fn){if(!privateSet.has(receiver))throw new TypeError(\"attempted to get private field on non-instance\");return fn}";

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
    \\var __zts_g = typeof globalThis !== "undefined" ? globalThis : typeof global !== "undefined" ? global : typeof window !== "undefined" ? window : this;
    \\var __zts_reload = function() {
    \\  if (typeof location !== "undefined") location.reload();
    \\  else if (__zts_g.nativeModuleProxy && __zts_g.nativeModuleProxy.DevSettings) __zts_g.nativeModuleProxy.DevSettings.reload();
    \\};
    \\function __zts_require(id) {
    \\  var m = __zts_modules[id];
    \\  if (!m) throw new Error("[zts] Module not found: " + id);
    \\  if (!m.initialized && m.factory) {
    \\    m.initialized = true;
    \\    __zts_g.__zts_currentModuleId = id;
    \\    var require = function(spec) { return __zts_require(m.deps && m.deps[spec] || spec); };
    \\    m.factory(m, m.exports, require);
    \\  }
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
    \\    invalidate: function() { __zts_reload(); }
    \\  };
    \\}
    \\function __zts_register(id, deps, factory) {
    \\  var prev = __zts_modules[id];
    \\  var mod = { exports: {}, hot: __zts_make_hot(id), factory: factory, deps: deps, initialized: false };
    \\  __zts_modules[id] = mod;
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
    \\    if (!cbs || !cbs.accept) { __zts_reload(); return; }
    \\    try {
    \\      // globalEvalWithSourceUrl (RN/Hermes): code runs in global scope, so
    \\      // __zts_register etc. must be global vars (which they are).
    \\      // new Function (browser): code receives them as function params.
    \\      if (typeof __zts_g.globalEvalWithSourceUrl === "function") {
    \\        __zts_g.globalEvalWithSourceUrl(updates[i].code, "zts-hmr://" + id);
    \\      } else {
    \\        var fn = new Function("__zts_register", "__zts_require", "__zts_make_hot", updates[i].code);
    \\        fn(__zts_register, __zts_require, __zts_make_hot);
    \\      }
    \\      __zts_require(id);
    \\      if (typeof cbs.accept === "function") cbs.accept();
    \\    } catch(e) { console.error("[zts] HMR update failed:", e); __zts_reload(); }
    \\  }
    \\  if (typeof __zts_RefreshRuntime !== "undefined") __zts_RefreshRuntime.performReactRefresh();
    \\}
    \\var __zts_RefreshRuntime = __zts_g.__REACT_REFRESH_RUNTIME__;
    \\__zts_g.$RefreshReg$ = function(type, id) {
    \\  if (__zts_RefreshRuntime) __zts_RefreshRuntime.register(type, __zts_g.__zts_currentModuleId + " " + id);
    \\};
    \\__zts_g.$RefreshSig$ = function() {
    \\  if (__zts_RefreshRuntime) return __zts_RefreshRuntime.createSignatureFunctionForTransform();
    \\  return function(type) { return type; };
    \\};
    \\
;

pub const HMR_RUNTIME_MIN =
    \\var __zts_modules={},__zts_hot_cbs={},__zts_hot_data={},__zts_g=typeof globalThis!=="undefined"?globalThis:typeof global!=="undefined"?global:typeof window!=="undefined"?window:this,__zts_reload=function(){if(typeof location!=="undefined")location.reload();else if(__zts_g.nativeModuleProxy&&__zts_g.nativeModuleProxy.DevSettings)__zts_g.nativeModuleProxy.DevSettings.reload()};function __zts_require(id){var m=__zts_modules[id];if(!m)throw new Error("[zts] Module not found: "+id);if(!m.initialized&&m.factory){m.initialized=true;__zts_g.__zts_currentModuleId=id;var r=function(s){return __zts_require(m.deps&&m.deps[s]||s)};m.factory(m,m.exports,r)}return m.exports}function __zts_make_hot(id){if(!__zts_hot_cbs[id])__zts_hot_cbs[id]={};return{get data(){return __zts_hot_data[id]},accept:function(d,c){if(typeof d==="function"){c=d;d=void 0}__zts_hot_cbs[id].accept=c||true;if(Array.isArray(d))__zts_hot_cbs[id].acceptDeps=d},dispose:function(c){__zts_hot_cbs[id].dispose=c},prune:function(c){__zts_hot_cbs[id].prune=c},invalidate:function(){__zts_reload()}}}function __zts_register(id,d,f){var p=__zts_modules[id];var m={exports:{},hot:__zts_make_hot(id),factory:f,deps:d,initialized:false};__zts_modules[id]=m;if(p){var c=__zts_hot_cbs[id];if(c&&c.dispose){__zts_hot_data[id]={};c.dispose(__zts_hot_data[id])}}}function __zts_apply_update(u){for(var i=0;i<u.length;i++){var id=u[i].id;var c=__zts_hot_cbs[id];if(!c||!c.accept){__zts_reload();return}try{if(typeof __zts_g.globalEvalWithSourceUrl==="function"){__zts_g.globalEvalWithSourceUrl(u[i].code,"zts-hmr://"+id)}else{var fn=new Function("__zts_register","__zts_require","__zts_make_hot",u[i].code);fn(__zts_register,__zts_require,__zts_make_hot)}__zts_require(id);if(typeof c.accept==="function")c.accept()}catch(e){console.error("[zts] HMR update failed:",e);__zts_reload()}}if(typeof __zts_RefreshRuntime!=="undefined")__zts_RefreshRuntime.performReactRefresh()}var __zts_RefreshRuntime=__zts_g.__REACT_REFRESH_RUNTIME__;__zts_g.$RefreshReg$=function(t,id){if(__zts_RefreshRuntime)__zts_RefreshRuntime.register(t,__zts_g.__zts_currentModuleId+" "+id)};__zts_g.$RefreshSig$=function(){if(__zts_RefreshRuntime)return __zts_RefreshRuntime.createSignatureFunctionForTransform();return function(t){return t}}
;

/// HMR 런타임의 줄 수 (소스맵 오프셋 계산���, comptime)
pub const HMR_RUNTIME_LINES = blk: {
    @setEvalBranchQuota(10000);
    break :blk @as(u32, std.mem.count(u8, HMR_RUNTIME, "\n"));
};

// ============================================================
// Using (Explicit Resource Management, ES2025)
// ============================================================

/// __using: 리소스를 dispose 스택에 등록 (esbuild 호환).
/// __callDispose: 스택의 리소스를 역순으로 dispose (esbuild 호환).
pub const USING_RUNTIME =
    \\var __using = (stack, value, async) => {
    \\  if (value != null) {
    \\    if (typeof value !== "object" && typeof value !== "function") throw new TypeError("Object expected");
    \\    var dispose, inner;
    \\    if (async) dispose = value[Symbol.asyncDispose];
    \\    if (dispose === void 0) {
    \\      dispose = value[Symbol.dispose];
    \\      if (async) inner = dispose;
    \\    }
    \\    if (typeof dispose !== "function") throw new TypeError("Object not disposable");
    \\    if (inner) dispose = function() { try { inner.call(this); } catch (e) { return Promise.reject(e); } };
    \\    stack.push([async, dispose, value]);
    \\  } else if (async) {
    \\    stack.push([async]);
    \\  }
    \\  return value;
    \\};
    \\var __callDispose = (stack, error, hasError) => {
    \\  var E = typeof SuppressedError === "function" ? SuppressedError : function(e, s, m) {
    \\    var err = new Error(m);
    \\    err.error = e;
    \\    err.suppressed = s;
    \\    return err;
    \\  };
    \\  var fail = (e) => error = hasError ? new E(e, error, "An error was suppressed during disposal") : (hasError = true, e);
    \\  var next = (it) => {
    \\    while (it = stack.pop()) {
    \\      try {
    \\        var result = it[1] && it[1].call(it[2]);
    \\        if (it[0]) return Promise.resolve(result).then(next, (e) => { fail(e); return next(); });
    \\      } catch (e) {
    \\        fail(e);
    \\      }
    \\    }
    \\    if (hasError) throw error;
    \\  };
    \\  return next();
    \\};
    \\
;
pub const USING_RUNTIME_MIN = "var __using=(stack,value,async)=>{if(value!=null){if(typeof value!==\"object\"&&typeof value!==\"function\")throw new TypeError(\"Object expected\");var dispose,inner;if(async)dispose=value[Symbol.asyncDispose];if(dispose===void 0){dispose=value[Symbol.dispose];if(async)inner=dispose}if(typeof dispose!==\"function\")throw new TypeError(\"Object not disposable\");if(inner)dispose=function(){try{inner.call(this)}catch(e){return Promise.reject(e)}};stack.push([async,dispose,value])}else if(async){stack.push([async])}return value};var __callDispose=(stack,error,hasError)=>{var E=typeof SuppressedError===\"function\"?SuppressedError:function(e,s,m){var err=new Error(m);err.error=e;err.suppressed=s;return err};var fail=(e)=>error=hasError?new E(e,error,\"An error was suppressed during disposal\"):(hasError=true,e);var next=(it)=>{while(it=stack.pop()){try{var result=it[1]&&it[1].call(it[2]);if(it[0])return Promise.resolve(result).then(next,(e)=>{fail(e);return next()})}catch(e){fail(e)}}if(hasError)throw error};return next()};";

/// __using/__callDispose ES5 호환: arrow → function.
pub const USING_RUNTIME_ES5 =
    \\var __using = function(stack, value, async) {
    \\  if (value != null) {
    \\    if (typeof value !== "object" && typeof value !== "function") throw new TypeError("Object expected");
    \\    var dispose, inner;
    \\    if (async) dispose = value[Symbol.asyncDispose];
    \\    if (dispose === void 0) {
    \\      dispose = value[Symbol.dispose];
    \\      if (async) inner = dispose;
    \\    }
    \\    if (typeof dispose !== "function") throw new TypeError("Object not disposable");
    \\    if (inner) dispose = function() { try { inner.call(this); } catch (e) { return Promise.reject(e); } };
    \\    stack.push([async, dispose, value]);
    \\  } else if (async) {
    \\    stack.push([async]);
    \\  }
    \\  return value;
    \\};
    \\var __callDispose = function(stack, error, hasError) {
    \\  var E = typeof SuppressedError === "function" ? SuppressedError : function(e, s, m) {
    \\    var err = new Error(m);
    \\    err.error = e;
    \\    err.suppressed = s;
    \\    return err;
    \\  };
    \\  var fail = function(e) { error = hasError ? new E(e, error, "An error was suppressed during disposal") : (hasError = true, e); };
    \\  var next = function(it) {
    \\    while (it = stack.pop()) {
    \\      try {
    \\        var result = it[1] && it[1].call(it[2]);
    \\        if (it[0]) return Promise.resolve(result).then(next, function(e) { fail(e); return next(); });
    \\      } catch (e) {
    \\        fail(e);
    \\      }
    \\    }
    \\    if (hasError) throw error;
    \\  };
    \\  return next();
    \\};
    \\
;
pub const USING_RUNTIME_ES5_MIN = "var __using=function(stack,value,async){if(value!=null){if(typeof value!==\"object\"&&typeof value!==\"function\")throw new TypeError(\"Object expected\");var dispose,inner;if(async)dispose=value[Symbol.asyncDispose];if(dispose===void 0){dispose=value[Symbol.dispose];if(async)inner=dispose}if(typeof dispose!==\"function\")throw new TypeError(\"Object not disposable\");if(inner)dispose=function(){try{inner.call(this)}catch(e){return Promise.reject(e)}};stack.push([async,dispose,value])}else if(async){stack.push([async])}return value};var __callDispose=function(stack,error,hasError){var E=typeof SuppressedError===\"function\"?SuppressedError:function(e,s,m){var err=new Error(m);err.error=e;err.suppressed=s;return err};var fail=function(e){error=hasError?new E(e,error,\"An error was suppressed during disposal\"):(hasError=true,e)};var next=function(it){while(it=stack.pop()){try{var result=it[1]&&it[1].call(it[2]);if(it[0])return Promise.resolve(result).then(next,function(e){fail(e);return next()})}catch(e){fail(e)}}if(hasError)throw error};return next()};";

// ============================================================
// Append Helper
// ============================================================

/// 런타임 헬퍼 문자열을 ArrayList에 주입한다.
/// standalone 트랜스파일(main.zig)에서도 사용할 수 있도록 pub으로 노출.
pub fn appendRuntimeHelpers(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, helpers: RuntimeHelpers, minify: bool, es5_compat: bool) !void {
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
        if (es5_compat) {
            try buf.appendSlice(allocator, if (minify) ASYNC_RUNTIME_ES5_MIN else ASYNC_RUNTIME_ES5);
        } else {
            try buf.appendSlice(allocator, if (minify) ASYNC_RUNTIME_MIN else ASYNC_RUNTIME);
        }
    }
    if (helpers.to_binary) {
        try buf.appendSlice(allocator, if (minify) TO_BINARY_RUNTIME_MIN else TO_BINARY_RUNTIME);
    }
    if (helpers.keep_names) {
        try buf.appendSlice(allocator, if (minify) KEEP_NAMES_RUNTIME_MIN else KEEP_NAMES_RUNTIME);
    }
    if (helpers.class_private_method_init) {
        try buf.appendSlice(allocator, if (minify) PRIVATE_METHOD_INIT_RUNTIME_MIN else PRIVATE_METHOD_INIT_RUNTIME);
    }
    if (helpers.class_private_method_get) {
        try buf.appendSlice(allocator, if (minify) PRIVATE_METHOD_GET_RUNTIME_MIN else PRIVATE_METHOD_GET_RUNTIME);
    }
    if (helpers.class_call_check) {
        try buf.appendSlice(allocator, if (minify) CLASS_CALL_CHECK_RUNTIME_MIN else CLASS_CALL_CHECK_RUNTIME);
    }
    if (helpers.call_super) {
        try buf.appendSlice(allocator, if (minify) CALL_SUPER_RUNTIME_MIN else CALL_SUPER_RUNTIME);
    }
    if (helpers.tagged_template_literal) {
        try buf.appendSlice(allocator, if (minify) TAGGED_TEMPLATE_RUNTIME_MIN else TAGGED_TEMPLATE_RUNTIME);
    }
    if (helpers.using_ctx) {
        if (es5_compat) {
            try buf.appendSlice(allocator, if (minify) USING_RUNTIME_ES5_MIN else USING_RUNTIME_ES5);
        } else {
            try buf.appendSlice(allocator, if (minify) USING_RUNTIME_MIN else USING_RUNTIME);
        }
    }
}

/// CJS interop 런타임을 주입한다 (__commonJS + __toESM).
/// configurable=true(RN)이면 ES5 호환 버전 사용.
pub fn appendCjsRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool, configurable: bool) !void {
    if (minify) {
        try buf.appendSlice(allocator, if (configurable) CJS_RUNTIME_ES5_MIN else CJS_RUNTIME_MIN);
        try buf.appendSlice(allocator, if (configurable) TOESM_RUNTIME_CONFIGURABLE_MIN else TOESM_RUNTIME_MIN);
    } else {
        try buf.appendSlice(allocator, if (configurable) CJS_RUNTIME_ES5 else CJS_RUNTIME);
        try buf.appendSlice(allocator, if (configurable) TOESM_RUNTIME_CONFIGURABLE else TOESM_RUNTIME);
    }
}

/// ESM wrap 런타임을 주입한다 (__esm + __export + __toCommonJS).
/// WrapKind.esm 모듈이 하나라도 있을 때 호출.
/// __toCommonJS는 __copyProps/__defProp에 의존하므로 __toESM 런타임 후에 주입해야 함.
/// configurable=true(RN)이면 ES5 호환 버전 사용.
pub fn appendEsmWrapRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool, configurable: bool) !void {
    if (minify) {
        try buf.appendSlice(allocator, if (configurable) ESM_RUNTIME_ES5_MIN else ESM_RUNTIME_MIN);
        try buf.appendSlice(allocator, if (configurable) EXPORT_RUNTIME_CONFIGURABLE_MIN else EXPORT_RUNTIME_MIN);
        try buf.appendSlice(allocator, if (configurable) TOCOMMONJS_RUNTIME_CONFIGURABLE_MIN else TOCOMMONJS_RUNTIME_MIN);
    } else {
        try buf.appendSlice(allocator, if (configurable) ESM_RUNTIME_ES5 else ESM_RUNTIME);
        try buf.appendSlice(allocator, if (configurable) EXPORT_RUNTIME_CONFIGURABLE else EXPORT_RUNTIME);
        try buf.appendSlice(allocator, if (configurable) TOCOMMONJS_RUNTIME_CONFIGURABLE else TOCOMMONJS_RUNTIME);
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
pub fn appendAsyncRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool, es5_compat: bool) !void {
    if (es5_compat) {
        try buf.appendSlice(allocator, if (minify) ASYNC_RUNTIME_ES5_MIN else ASYNC_RUNTIME_ES5);
    } else {
        try buf.appendSlice(allocator, if (minify) ASYNC_RUNTIME_MIN else ASYNC_RUNTIME);
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
