//! ZNTC Bundler — Runtime Helpers
//!
//! 번들 출력에 주입되는 런타임 헬퍼 상수 모음.
//! emitter.zig, emitChunks, main.zig 등에서 공용으로 사용한다.
//!
//! 각 헬퍼는 normal(포맷팅) + minified 두 벌로 제공.

const std = @import("std");
const RuntimeHelpers = @import("../transformer/runtime_helper_bits.zig").RuntimeHelpers;

// ============================================================
// External runtime package specifiers
// ============================================================

/// `babel-plugin-transform-flow-enums` 호환 runtime helper. Flow enum codegen 과
/// graph 의 synthetic require 주입이 같은 specifier 를 공유해야 require_rewrites
/// 매핑이 hit 한다 (#2401).
pub const FLOW_ENUMS_RUNTIME_SPECIFIER = "flow-enums-runtime";

// ============================================================
// CJS Interop
// ============================================================

/// Node ESM 환경에서 전역 `require` 부재 문제를 `createRequire(import.meta.url)`로 해결하는 shim.
/// 참고: esbuild `internal/linker/linker.go`의 `needsCreateRequireShim`.
pub const REQUIRE_SHIM = "import { createRequire } from \"node:module\";\nconst require = createRequire(import.meta.url);\n";
pub const REQUIRE_SHIM_MIN = "import{createRequire}from\"node:module\";const require=createRequire(import.meta.url);";

/// ESM 번들에 CJS wrapper가 섞일 때 preamble에 require shim을 주입.
/// 호출부에서 `platform=node + format=esm + CJS wrap 존재` 조건을 판정하고 호출한다.
pub fn appendRequireShim(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool) !void {
    try buf.appendSlice(allocator, if (minify) REQUIRE_SHIM_MIN else REQUIRE_SHIM);
}

// #1618 / #1621 / #1752: runtime helper 축약 이름 테이블은 `src/runtime_helper_names.zig`
// 공용 모듈로 이전. transformer (`es_helpers.makeRuntimeHelperRef`) 와 bundler (이 파일의
// preamble 템플릿 + `mangler.isReservedOrGlobal`) 가 해당 공용 모듈에만 의존하여 레이어
// 역전이 없다. 기존 `runtime_helpers.NAMES` / `PAIRS` / `helperName` 접근 경로는
// re-export 로 호환 유지.
const names_mod = @import("../runtime_helper_names.zig");
pub const NAMES = names_mod.NAMES;
pub const PAIRS = names_mod.PAIRS;
pub const ALL_SHORT_NAMES = names_mod.ALL_SHORT_NAMES;
pub const helperName = names_mod.helperName;

// non-minify wrapper 는 cb 가 *object* (디버깅 친화 — `{"path"(exports, module){...}}`
// 의 module path 보존). minify wrapper 는 cb 가 *함수* — emit 도 직접 함수 인자
// (`$c((exports,module)=>{...})`) 와 한 쌍. HMR 의 `Object.keys(cb)[0]` module id
// 추적은 dev_mode 전용 (minify 시 HMR runtime 자체가 emit 안 됨) 이므로 호환.
//
// minify 의 returned function 은 anonymous arrow — stack trace 의 함수 이름 손실은
// production 빌드에서 trade-off 수용.
//
// Node/Metro 처럼 factory 가 throw 하면 미완성 module 캐시를 버린다. RN dev 의
// ErrorUtils guard 가 첫 예외를 보고만 하고 계속 진행해도 빈 exports 객체가 이후
// require 결과로 고정되지 않아야 한다.
pub const CJS_RUNTIME = "var __commonJS = (cb, mod) => function __require() {\n\tif (mod) return mod.exports;\n\tmod = { exports: {} };\n\ttry { (0, cb[Object.keys(cb)[0]])(mod.exports, mod); }\n\tcatch (e) { mod = void 0; throw e; }\n\treturn mod.exports;\n};\n";
pub const CJS_RUNTIME_MIN = "var " ++ NAMES.CJS_FACTORY_MIN ++ "=(cb,mod)=>()=>{if(mod)return mod.exports;mod={exports:{}};try{cb(mod.exports,mod)}catch(e){mod=void 0;throw e}return mod.exports};";

// __commonJS ES5 호환 (RN/Hermes — `configurable_exports=true`): arrow → function.
// ES5 는 arrow expression body 가 없어 function expression 그대로지만, 이름은 제거.
// #1751: trailing `;` — 뒤따르는 `var __xxx=...` 와 문법 구분 필수 (minify 연속 emit).
pub const CJS_RUNTIME_ES5 = "var __commonJS = function(cb, mod) { return function __require() {\n\tif (mod) return mod.exports;\n\tmod = { exports: {} };\n\ttry { (0, cb[Object.keys(cb)[0]])(mod.exports, mod); }\n\tcatch (e) { mod = void 0; throw e; }\n\treturn mod.exports;\n}; };\n";
pub const CJS_RUNTIME_ES5_MIN = "var " ++ NAMES.CJS_FACTORY_MIN ++ "=function(cb,mod){return function(){if(mod)return mod.exports;mod={exports:{}};try{cb(mod.exports,mod)}catch(e){mod=void 0;throw e}return mod.exports}};";

/// __toESM: CJS 모듈을 ESM namespace로 변환 (rolldown 호환).
/// isNodeMode=true(--platform=node)이면 항상 default: mod를 설정.
/// __esModule=true이면 원본 프로퍼티를 사용하되 default는 추가하지 않음.
///
/// __copyProps: getOwnPropertyNames로 non-enumerable 포함 전체 프로퍼티를 복사하고,
/// 원본 descriptor의 enumerable 플래그를 보존한다. key는 per-iteration으로 capture
/// (비-min: bind, min: IIFE) 하여 var 루프에서도 안전.
/// 호출자는 모두 2-arg (`__toESM`, `__toCommonJS`) 이므로 except 매개변수는 사용되지 않는다.
/// 참고: references/rolldown/crates/rolldown/src/runtime/index.js:86
pub const TOESM_RUNTIME =
    \\var __create = Object.create;
    \\var __getProtoOf = Object.getPrototypeOf;
    \\var __defProp = Object.defineProperty;
    \\var __getOwnPropNames = Object.getOwnPropertyNames;
    \\var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
    \\var __hasOwn = Object.prototype.hasOwnProperty;
    \\var __copyProps = (to, from, desc) => {
    \\  if (from && typeof from === "object" || typeof from === "function") {
    \\    for (var keys = __getOwnPropNames(from), i = 0, key; i < keys.length; i++) {
    \\      key = keys[i];
    \\      if (!__hasOwn.call(to, key))
    \\        __defProp(to, key, { get: ((k) => from[k]).bind(null, key), enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    \\    }
    \\  }
    \\  return to;
    \\};
    \\var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target, mod));
    \\
;
pub const TOESM_RUNTIME_MIN =
    "var " ++ NAMES.CREATE_MIN ++ "=Object.create," ++
    NAMES.GET_PROTO_OF_MIN ++ "=Object.getPrototypeOf," ++
    NAMES.DEF_PROP_MIN ++ "=Object.defineProperty," ++
    NAMES.GET_OWN_PROP_NAMES_MIN ++ "=Object.getOwnPropertyNames," ++
    NAMES.GET_OWN_PROP_DESC_MIN ++ "=Object.getOwnPropertyDescriptor," ++
    NAMES.HAS_OWN_MIN ++ "=Object.prototype.hasOwnProperty," ++
    NAMES.COPY_PROPS_MIN ++ "=(to,from,desc)=>{" ++
    "if(from&&typeof from===\"object\"||typeof from===\"function\"){" ++
    "for(var keys=" ++ NAMES.GET_OWN_PROP_NAMES_MIN ++ "(from),i=0,key;i<keys.length;i++){" ++
    "key=keys[i];" ++
    "if(!" ++ NAMES.HAS_OWN_MIN ++ ".call(to,key))" ++
    NAMES.DEF_PROP_MIN ++ "(to,key,{get:(k=>()=>from[k])(key),enumerable:!(desc=" ++ NAMES.GET_OWN_PROP_DESC_MIN ++ "(from,key))||desc.enumerable})" ++
    "}}return to};" ++
    "var " ++ NAMES.TOESM_MIN ++ "=(mod,isNodeMode,target)=>(" ++
    "target=mod!=null?" ++ NAMES.CREATE_MIN ++ "(" ++ NAMES.GET_PROTO_OF_MIN ++ "(mod)):{}," ++
    NAMES.COPY_PROPS_MIN ++ "(isNodeMode||!mod||!mod.__esModule?" ++ NAMES.DEF_PROP_MIN ++ "(target,\"default\",{value:mod,enumerable:true}):target,mod));";

/// __toESM configurable + ES5 호환: RN/Hermes용.
/// arrow → function, configurable: true. --platform=react-native에서 자동 활성화.
pub const TOESM_RUNTIME_CONFIGURABLE =
    \\var __create = Object.create;
    \\var __getProtoOf = Object.getPrototypeOf;
    \\var __defProp = Object.defineProperty;
    \\var __getOwnPropNames = Object.getOwnPropertyNames;
    \\var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
    \\var __hasOwn = Object.prototype.hasOwnProperty;
    \\var __copyProps = function(to, from, desc) {
    \\  if (from && typeof from === "object" || typeof from === "function") {
    \\    for (var keys = __getOwnPropNames(from), i = 0, key; i < keys.length; i++) {
    \\      key = keys[i];
    \\      if (!__hasOwn.call(to, key))
    \\        __defProp(to, key, { get: (function(k) { return from[k]; }).bind(null, key), enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable, configurable: true });
    \\    }
    \\  }
    \\  return to;
    \\};
    \\var __toESM = function(mod, isNodeMode, target) { return target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true, configurable: true }) : target, mod); };
    \\
;
pub const TOESM_RUNTIME_CONFIGURABLE_MIN =
    "var " ++ NAMES.CREATE_MIN ++ "=Object.create," ++
    NAMES.GET_PROTO_OF_MIN ++ "=Object.getPrototypeOf," ++
    NAMES.DEF_PROP_MIN ++ "=Object.defineProperty," ++
    NAMES.GET_OWN_PROP_NAMES_MIN ++ "=Object.getOwnPropertyNames," ++
    NAMES.GET_OWN_PROP_DESC_MIN ++ "=Object.getOwnPropertyDescriptor," ++
    NAMES.HAS_OWN_MIN ++ "=Object.prototype.hasOwnProperty," ++
    NAMES.COPY_PROPS_MIN ++ "=function(to,from,desc){" ++
    "if(from&&typeof from===\"object\"||typeof from===\"function\"){" ++
    "for(var keys=" ++ NAMES.GET_OWN_PROP_NAMES_MIN ++ "(from),i=0,key;i<keys.length;i++){" ++
    "key=keys[i];" ++
    "if(!" ++ NAMES.HAS_OWN_MIN ++ ".call(to,key))" ++
    NAMES.DEF_PROP_MIN ++ "(to,key,{get:(function(k){return from[k]}).bind(null,key),enumerable:!(desc=" ++ NAMES.GET_OWN_PROP_DESC_MIN ++ "(from,key))||desc.enumerable,configurable:true})" ++
    "}}return to};" ++
    "var " ++ NAMES.TOESM_MIN ++ "=function(mod,isNodeMode,target){" ++
    "return target=mod!=null?" ++ NAMES.CREATE_MIN ++ "(" ++ NAMES.GET_PROTO_OF_MIN ++ "(mod)):{}," ++
    NAMES.COPY_PROPS_MIN ++ "(isNodeMode||!mod||!mod.__esModule?" ++ NAMES.DEF_PROP_MIN ++ "(target,\"default\",{value:mod,enumerable:true,configurable:true}):target,mod)};";

/// __esm: ESM 모듈의 지연 초기화 팩토리.
/// factory throw 시 fn을 복원하여 cascade 실패 방지.
/// circular dep 재진입 시 fn=0(진행 중)이므로 skip.
pub const ESM_RUNTIME = "var __esm = (fn, res) => function __init() {\n\tif (!fn) return res;\n\tvar f = fn; fn = 0;\n\ttry { res = (0, f[Object.keys(f)[0]])(); }\n\tcatch(e) { fn = f; throw e; }\n\treturn res;\n};\n";
pub const ESM_RUNTIME_MIN = "var " ++ NAMES.ESM_FACTORY_MIN ++ "=(fn,res)=>function __init(){if(!fn)return res;var f=fn;fn=0;try{res=(0,f[Object.keys(f)[0]])()}catch(e){fn=f;throw e}return res};";

/// __esm ES5 호환: arrow → function.
pub const ESM_RUNTIME_ES5 = "var __esm = function(fn, res) { return function __init() {\n\tif (!fn) return res;\n\tvar f = fn; fn = 0;\n\ttry { res = (0, f[Object.keys(f)[0]])(); }\n\tcatch(e) { fn = f; throw e; }\n\treturn res;\n}; };\n";
// #1751: trailing `;` — 뒤따르는 `var __xxx=...` 와 문법 구분 필수.
pub const ESM_RUNTIME_ES5_MIN = "var " ++ NAMES.ESM_FACTORY_MIN ++ "=function(fn,res){return function __init(){if(!fn)return res;var f=fn;fn=0;try{res=(0,f[Object.keys(f)[0]])()}catch(e){fn=f;throw e}return res}};";

// ============================================================
// 런타임 require 레지스트리 코어 (P3-B / P3-C 수렴점)
// ============================================================
//
// **단일 canonical 레지스트리 코어 = `ZNTC_IIFE_RESOLVE_BROWSER`(아래).**
// PR1 의 `ZNTC_REGISTRY_RUNTIME`(CJS-Node require 로더 변형)은 한 번도
// 활성화되지 않은 초기 초안이었고(PR2 는 Node native require, PR3/4 는
// self-installing register + env-detect 로더 = active 코어), 실호출 0 의
// dead code 라 P3-C 에서 제거했다 — `__zntc_require`/cache 코어 중복 spell
// 해소(중복 구현 금지, MF RFC §4.1/§6.1). MF P1 의 container/shared scope
// 는 아래 active 코어(`ZNTC_REGISTER_INSTALL`+`ZNTC_IIFE_RESOLVE_BROWSER`
// 의 `__zntc_require`/`__zntc_mods`/`__zntc_cache`) 위에 얹는다.

// ============================================================
// IIFE code splitting 런타임 (P3-B PR3)
// ============================================================
//
// IIFE/브라우저는 네이티브 require 가 없어 PR1 레지스트리를 *활성화*한다.
// 디리스크 스파이크(RFC §6 IIFE)가 잡은 제약: 정적 dep 청크가 entry(해석
// 계층)보다 먼저 평가되면 `__zntc_register` 미존재로 실패. → **등록/해석
// 분리**:
//  - 등록(`__zntc_register`)은 **자기설치형** — 모든 청크 wrapper 가 멱등
//    prelude 로 보유, `g.__zntc_mods` 맵만 건드림. 코어보다 먼저여도 안전.
//  - 해석(`__zntc_require` + 브라우저 `<script>` 로더)은 entry 전용·멱등.
// load-order 요구는 "entry 가 정적 dep 들 뒤에 평가" 하나로 축소(호스트
// 책임 — RFC §5/§7). 이름은 cross-file 계약이라 mangle 금지(리터럴 emit).

/// 모든 IIFE 청크 wrapper 가 보유하는 자기설치형 register 식.
/// 사용: `(function(g){` ++ THIS ++ `({"<id>":function(exports,module,require){`
///       ++ <hoisted body+exports> ++ `}});})(typeof globalThis...)`
pub const ZNTC_REGISTER_INSTALL =
    "(g.__zntc_register||(g.__zntc_register=function(map){var M=g.__zntc_mods||(g.__zntc_mods={});for(var k in map)M[k]=map[k];}))";

pub const ZNTC_IIFE_GLOBAL = "(typeof globalThis!==\"undefined\"?globalThis:this)";

/// entry 청크 전용 해석 계층 — `__zntc_require`(모듈ID→factory, 캐시) +
/// 환경 감지 동적 로더(`__zntc_load_chunk`, public_path 기반, Promise 캐시):
/// DOM → `<script>` 주입 / Web Worker(`importScripts`) → importScripts /
/// 그 외(Deno·Node-ESM·번들 eval) → 동적 `import(url)`. self-register
/// payload 라 평가만 되면 됨. `if(!g.__zntc_require)` 멱등 가드. (PR4 비-DOM
/// 폴백 — 기존 DOM 전용은 worker/Deno 에서 `document is not defined`.)
/// 베이스라인: 동적 `import()` 지원(code-splitting 가능한 모든 현대 엔진의
/// 공통 전제 — webpack/rollup/esbuild splitting 런타임과 동일하게 리터럴
/// emit; eval/Function 우회는 CSP 적대적이라 미채택). 비-DOM 분기는 url 이
/// 해석 가능해야 함 → public_path 를 절대/URL 로 설정(호스트 책임).
/// CSP: strict `script-src 'nonce-..'` 환경에선 호스트가
/// `globalThis.__zntc_nonce` 를 설정 → 주입 `<script>` 에 `nonce` 부여
/// (webpack `__webpack_nonce__` 대응; `__zntc_public_path` 와 동일하게
/// 호스트-set 런타임 변수, 빌드 옵션 불필요).
///
/// P3-C(해소): PR1 의 dormant `ZNTC_REGISTRY_RUNTIME`(중복 `__zntc_require`/
/// cache spell, 실호출 0)를 제거 — 본 상수가 **단일 canonical 레지스트리
/// 코어**다. MF P1 의 container/shared scope 는 여기 `__zntc_require`/
/// `__zntc_mods`/`__zntc_cache` + `ZNTC_REGISTER_INSTALL` 위에 얹는다
/// (중복 구현 금지, MF RFC §4.1/§6.1).
pub const ZNTC_IIFE_RESOLVE_BROWSER =
    \\(function (g) {
    \\  if (g.__zntc_require) return;
    \\  var __zntc_cache = {};
    \\  var __zntc_cs = {};
    \\  g.__zntc_require = function (id) {
    \\    var c = __zntc_cache[id];
    \\    if (c) return c.exports;
    \\    var m = { exports: {} };
    \\    __zntc_cache[id] = m;
    \\    (0, g.__zntc_mods[id])(m.exports, m, g.__zntc_require);
    \\    return m.exports;
    \\  };
    \\  g.__zntc_load_chunk = function (spec) {
    \\    if (__zntc_cs[spec]) return __zntc_cs[spec];
    \\    var url = (g.__zntc_public_path || "") + spec;
    \\    return (__zntc_cs[spec] = new Promise(function (res, rej) {
    \\      if (typeof document !== "undefined" && document.createElement) {
    \\        var s = document.createElement("script");
    \\        s.src = url;
    \\        if (g.__zntc_nonce) s.setAttribute("nonce", g.__zntc_nonce);
    \\        s.onload = function () { res(); };
    \\        s.onerror = function () { rej(new Error("chunk load failed: " + spec)); };
    \\        document.head.appendChild(s);
    \\      } else if (typeof importScripts === "function") {
    \\        try { importScripts(url); res(); } catch (e) { rej(e); }
    \\      } else {
    \\        Promise.resolve().then(function () { return import(url); }).then(function () { res(); }, rej);
    \\      }
    \\    }));
    \\  };
    \\})(typeof globalThis !== "undefined" ? globalThis : this);
    \\
;
pub const ZNTC_IIFE_RESOLVE_BROWSER_MIN =
    "(function(g){if(g.__zntc_require)return;var __zntc_cache={},__zntc_cs={};" ++
    "g.__zntc_require=function(id){var c=__zntc_cache[id];if(c)return c.exports;" ++
    "var m={exports:{}};__zntc_cache[id]=m;(0,g.__zntc_mods[id])(m.exports,m,g.__zntc_require);return m.exports};" ++
    "g.__zntc_load_chunk=function(spec){if(__zntc_cs[spec])return __zntc_cs[spec];" ++
    "var url=(g.__zntc_public_path||\"\")+spec;" ++
    "return __zntc_cs[spec]=new Promise(function(res,rej){" ++
    "if(typeof document!==\"undefined\"&&document.createElement){var s=document.createElement(\"script\");" ++
    "s.src=url;if(g.__zntc_nonce)s.setAttribute(\"nonce\",g.__zntc_nonce);s.onload=function(){res()};" ++
    "s.onerror=function(){rej(new Error(\"chunk load failed: \"+spec))};document.head.appendChild(s)}" ++
    "else if(typeof importScripts===\"function\"){try{importScripts(url);res()}catch(e){rej(e)}}" ++
    "else{Promise.resolve().then(function(){return import(url)}).then(function(){res()},rej)}})};" ++
    "})(typeof globalThis!==\"undefined\"?globalThis:this);";

/// entry 청크에 해석 계층(브라우저)을 1회 주입.
pub fn appendZntcResolveBrowser(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool) !void {
    try buf.appendSlice(allocator, if (minify) ZNTC_IIFE_RESOLVE_BROWSER_MIN else ZNTC_IIFE_RESOLVE_BROWSER);
}

/// __export: ESM namespace 객체에 live getter 등록 (esbuild 호환).
/// var foo_exports = {}; __export(foo_exports, { greet: () => greet });
/// __defProp은 __toESM 런타임에 이미 정의됨.
/// 참고: references/esbuild/internal/runtime/runtime.go:187
pub const EXPORT_RUNTIME = "var __export = (target, all) => {\n\tfor (var name in all)\n\t\t__defProp(target, name, { get: all[name], enumerable: true });\n};\n";
pub const EXPORT_RUNTIME_MIN = "var " ++ NAMES.EXPORT_MIN ++ "=(target,all)=>{for(var name in all)" ++ NAMES.DEF_PROP_MIN ++ "(target,name,{get:all[name],enumerable:true})};";

/// __export configurable 버전: RN/Hermes 호환.
pub const EXPORT_RUNTIME_CONFIGURABLE = "var __export = function(target, all) {\n\tfor (var name in all)\n\t\t__defProp(target, name, { get: all[name], enumerable: true, configurable: true });\n};\n";
pub const EXPORT_RUNTIME_CONFIGURABLE_MIN = "var " ++ NAMES.EXPORT_MIN ++ "=function(target,all){for(var name in all)" ++ NAMES.DEF_PROP_MIN ++ "(target,name,{get:all[name],enumerable:true,configurable:true})};";

/// __toCommonJS: ESM namespace → CJS 호환 객체 변환 (rolldown 호환).
/// __commonJS로 래핑된 모듈은 mod["module.exports"]에 원본 exports가 있으므로
/// 복사 없이 직접 반환하여 getter/non-enumerable 프로퍼티를 보존한다.
/// 그 외에는 { __esModule: true } + 원본 프로퍼티 복사.
/// 참고: references/rolldown/crates/rolldown/src/runtime/index.js:105
/// __copyProps, __defProp, __hasOwn은 __toESM 런타임에 이미 정의됨.
pub const TOCOMMONJS_RUNTIME = "var __toCommonJS = mod => __hasOwn.call(mod, 'module.exports') ? mod['module.exports'] : __copyProps(__defProp({}, '__esModule', { value: true }), mod);\n";
pub const TOCOMMONJS_RUNTIME_MIN = "var " ++ NAMES.TOCOMMONJS_MIN ++ "=mod=>" ++ NAMES.HAS_OWN_MIN ++ ".call(mod,\"module.exports\")?mod[\"module.exports\"]:" ++ NAMES.COPY_PROPS_MIN ++ "(" ++ NAMES.DEF_PROP_MIN ++ "({},\"__esModule\",{value:true}),mod);";

/// __toCommonJS configurable 버전: RN/Hermes 호환.
pub const TOCOMMONJS_RUNTIME_CONFIGURABLE = "var __toCommonJS = function(mod) { return __hasOwn.call(mod, 'module.exports') ? mod['module.exports'] : __copyProps(__defProp({}, '__esModule', { value: true, configurable: true }), mod); };\n";
pub const TOCOMMONJS_RUNTIME_CONFIGURABLE_MIN = "var " ++ NAMES.TOCOMMONJS_MIN ++ "=function(mod){return " ++ NAMES.HAS_OWN_MIN ++ ".call(mod,\"module.exports\")?mod[\"module.exports\"]:" ++ NAMES.COPY_PROPS_MIN ++ "(" ++ NAMES.DEF_PROP_MIN ++ "({},\"__esModule\",{value:true,configurable:true}),mod)};";

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
pub const DECORATOR_RUNTIME_MIN =
    "var " ++ NAMES.DEF_PROP_2_MIN ++ "=Object.defineProperty," ++
    NAMES.GET_OWN_PROP_DESC_MIN ++ "=Object.getOwnPropertyDescriptor," ++
    NAMES.DECORATE_CLASS_MIN ++ "=(decorators,target,key,kind)=>{" ++
    "var result=kind>1?void 0:kind?" ++ NAMES.GET_OWN_PROP_DESC_MIN ++ "(target,key):target;" ++
    "for(var i=decorators.length-1,decorator;i>=0;i--)" ++
    "if(decorator=decorators[i])result=(kind?decorator(target,key,result):decorator(result))||result;" ++
    "if(kind&&result)" ++ NAMES.DEF_PROP_2_MIN ++ "(target,key,result);" ++
    "return result}," ++
    NAMES.DECORATE_PARAM_MIN ++ "=(index,decorator)=>(target,key)=>decorator(target,key,index);";

/// __metadata: emitDecoratorMetadata 시 Reflect.metadata 호출 (TypeScript 호환).
/// design:type, design:paramtypes, design:returntype 메타데이터를 클래스/멤버에 부착.
pub const METADATA_RUNTIME =
    \\var __metadata = (key, value) => {
    \\  if (typeof Reflect !== "undefined" && typeof Reflect.metadata === "function")
    \\    return Reflect.metadata(key, value);
    \\};
    \\
;
pub const METADATA_RUNTIME_MIN = "var " ++ NAMES.METADATA_MIN ++ "=(key,value)=>{if(typeof Reflect!==\"undefined\"&&typeof Reflect.metadata===\"function\")return Reflect.metadata(key,value)};";

// ============================================================
// TC39 Stage 3 Decorators (TypeScript 5.0+ / tslib 호환)
// ============================================================

/// __esDecorate: Stage 3 decorator를 class/member에 적용 (tslib 호환).
/// ctor=null이면 field/class, descriptorIn=null이면 prototype/constructor에서 descriptor 조회.
/// contextIn.kind에 따라 "class", "method", "getter", "setter", "field", "accessor" 분기.
pub const ES_DECORATOR_RUNTIME =
    \\var __esDecorate = function(ctor, descriptorIn, decorators, contextIn, initializers, extraInitializers) {
    \\  function accept(f) { if (f !== void 0 && typeof f !== "function") throw new TypeError("Function expected"); return f; }
    \\  var kind = contextIn.kind, key = kind === "getter" ? "get" : kind === "setter" ? "set" : "value";
    \\  var target = !descriptorIn && ctor ? contextIn["static"] ? ctor : ctor.prototype : null;
    \\  var descriptor = descriptorIn || (target ? Object.getOwnPropertyDescriptor(target, contextIn.name) : {});
    \\  var _, done = false;
    \\  for (var i = decorators.length - 1; i >= 0; i--) {
    \\    var context = {};
    \\    for (var p in contextIn) context[p] = p === "access" ? {} : contextIn[p];
    \\    for (var p in contextIn.access) context.access[p] = contextIn.access[p];
    \\    context.addInitializer = function(f) { if (done) throw new TypeError("Cannot add initializers after decoration has completed"); extraInitializers.push(accept(f || null)); };
    \\    var result = (0, decorators[i])(kind === "accessor" ? { get: descriptor.get, set: descriptor.set } : descriptor[key], context);
    \\    if (kind === "accessor") {
    \\      if (result === void 0) continue;
    \\      if (result === null || typeof result !== "object") throw new TypeError("Object expected");
    \\      if (_ = accept(result.get)) descriptor.get = _;
    \\      if (_ = accept(result.set)) descriptor.set = _;
    \\      if (_ = accept(result.init)) initializers.unshift(_);
    \\    } else if (_ = accept(result)) {
    \\      if (kind === "field") initializers.unshift(_);
    \\      else descriptor[key] = _;
    \\    }
    \\  }
    \\  if (target) Object.defineProperty(target, contextIn.name, descriptor);
    \\  done = true;
    \\};
    \\var __runInitializers = function(thisArg, initializers, value) {
    \\  var useValue = arguments.length > 2;
    \\  for (var i = 0; i < initializers.length; i++) {
    \\    value = useValue ? initializers[i].call(thisArg, value) : initializers[i].call(thisArg);
    \\  }
    \\  return useValue ? value : void 0;
    \\};
    \\var __setFunctionName = function(f, name, prefix) {
    \\  if (typeof name === "symbol") name = name.description ? "[".concat(name.description, "]") : "";
    \\  return Object.defineProperty(f, "name", { configurable: true, value: prefix ? "".concat(prefix, " ", name) : name });
    \\};
    \\var __propKey = function(x) {
    \\  return typeof x === "symbol" ? x : "".concat(x);
    \\};
    \\
;

pub const ES_DECORATOR_RUNTIME_MIN =
    "var " ++ NAMES.ES_DECORATE_MIN ++ "=function(ctor,descriptorIn,decorators,contextIn,initializers,extraInitializers){" ++
    "function accept(f){if(f!==void 0&&typeof f!==\"function\")throw new TypeError(\"Function expected\");return f}" ++
    "var kind=contextIn.kind,key=kind===\"getter\"?\"get\":kind===\"setter\"?\"set\":\"value\";" ++
    "var target=!descriptorIn&&ctor?contextIn[\"static\"]?ctor:ctor.prototype:null;" ++
    "var descriptor=descriptorIn||(target?Object.getOwnPropertyDescriptor(target,contextIn.name):{});" ++
    "var _,done=false;" ++
    "for(var i=decorators.length-1;i>=0;i--){" ++
    "var context={};for(var p in contextIn)context[p]=p===\"access\"?{}:contextIn[p];" ++
    "for(var p in contextIn.access)context.access[p]=contextIn.access[p];" ++
    "context.addInitializer=function(f){if(done)throw new TypeError(\"Cannot add initializers after decoration has completed\");extraInitializers.push(accept(f||null))};" ++
    "var result=(0,decorators[i])(kind===\"accessor\"?{get:descriptor.get,set:descriptor.set}:descriptor[key],context);" ++
    "if(kind===\"accessor\"){if(result===void 0)continue;if(result===null||typeof result!==\"object\")throw new TypeError(\"Object expected\");" ++
    "if(_=accept(result.get))descriptor.get=_;if(_=accept(result.set))descriptor.set=_;if(_=accept(result.init))initializers.unshift(_)}" ++
    "else if(_=accept(result)){if(kind===\"field\")initializers.unshift(_);else descriptor[key]=_}}" ++
    "if(target)Object.defineProperty(target,contextIn.name,descriptor);done=true};" ++
    "var " ++ NAMES.RUN_INITIALIZERS_MIN ++ "=function(thisArg,initializers,value){var useValue=arguments.length>2;for(var i=0;i<initializers.length;i++){value=useValue?initializers[i].call(thisArg,value):initializers[i].call(thisArg)}return useValue?value:void 0};" ++
    "var " ++ NAMES.SET_FUNCTION_NAME_MIN ++ "=function(f,name,prefix){if(typeof name===\"symbol\")name=name.description?\"[\".concat(name.description,\"]\"):\"\";return Object.defineProperty(f,\"name\",{configurable:true,value:prefix?\"\".concat(prefix,\" \",name):name})};" ++
    "var " ++ NAMES.PROP_KEY_MIN ++ "=function(x){return typeof x===\"symbol\"?x:\"\".concat(x)};";

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
pub const CLASS_CALL_CHECK_RUNTIME_MIN = "var " ++ NAMES.CLASS_CALL_CHECK_MIN ++ "=function(instance,Constructor){if(!(instance instanceof Constructor))throw new TypeError(\"Cannot call a class as a function\")};";

/// __callSuper: super() 호출을 Reflect.construct로 래핑 (SWC _call_super 호환).
/// 네이티브 ES6 클래스(Error, Map 등)를 extends할 때 .call()이 불가하므로
/// Reflect.construct를 사용하여 올바른 내부 슬롯을 가진 인스턴스를 생성.
/// 트랜스파일된 클래스에는 fallback으로 .apply()를 사용.
pub const CALL_SUPER_RUNTIME =
    \\var __callSuper = function(Parent, args, NewTarget) {
    \\  if (typeof Reflect !== "undefined" && typeof Reflect.construct === "function") {
    \\    return Reflect.construct(Parent, args || [], NewTarget);
    \\  }
    \\  var _this = Object.create(NewTarget.prototype);
    \\  var result = Parent.apply(_this, args);
    \\  if (result && (typeof result === "object" || typeof result === "function")) return result;
    \\  return _this;
    \\};
    \\
;
pub const CALL_SUPER_RUNTIME_MIN = "var " ++ NAMES.CALL_SUPER_MIN ++ "=function(Parent,args,NewTarget){if(typeof Reflect!==\"undefined\"&&typeof Reflect.construct===\"function\")return Reflect.construct(Parent,args||[],NewTarget);var _this=Object.create(NewTarget.prototype);var result=Parent.apply(_this,args);if(result&&(typeof result===\"object\"||typeof result===\"function\"))return result;return _this};";

/// __superGet/__superSet: super property 접근 시 receiver(this)를 보존한다.
/// `Parent.prototype.x` 직접 접근은 getter/setter의 this를 Parent.prototype으로 바꾸므로
/// ES2015 [[Get]]/[[Set]]의 receiver 인자를 helper에서 명시적으로 전달한다.
pub const SUPER_GET_RUNTIME =
    \\var __superGet = function(parent, prop, receiver) {
    \\  var desc;
    \\  while (parent) {
    \\    desc = Object.getOwnPropertyDescriptor(parent, prop);
    \\    if (desc) {
    \\      if (desc.get) return desc.get.call(receiver);
    \\      return desc.value;
    \\    }
    \\    parent = Object.getPrototypeOf(parent);
    \\  }
    \\};
    \\
;
pub const SUPER_GET_RUNTIME_MIN = "var " ++ NAMES.SUPER_GET_MIN ++ "=function(parent,prop,receiver){var desc;while(parent){desc=Object.getOwnPropertyDescriptor(parent,prop);if(desc){if(desc.get)return desc.get.call(receiver);return desc.value}parent=Object.getPrototypeOf(parent)}};";

pub const SUPER_SET_RUNTIME =
    \\var __superSet = function(parent, prop, value, receiver) {
    \\  var desc;
    \\  while (parent) {
    \\    desc = Object.getOwnPropertyDescriptor(parent, prop);
    \\    if (desc) {
    \\      if (desc.set) {
    \\        desc.set.call(receiver, value);
    \\        return value;
    \\      }
    \\      if (desc.writable) {
    \\        receiver[prop] = value;
    \\        return value;
    \\      }
    \\      throw new TypeError("Cannot set property");
    \\    }
    \\    parent = Object.getPrototypeOf(parent);
    \\  }
    \\  receiver[prop] = value;
    \\  return value;
    \\};
    \\
;
pub const SUPER_SET_RUNTIME_MIN = "var " ++ NAMES.SUPER_SET_MIN ++ "=function(parent,prop,value,receiver){var desc;while(parent){desc=Object.getOwnPropertyDescriptor(parent,prop);if(desc){if(desc.set){desc.set.call(receiver,value);return value}if(desc.writable){receiver[prop]=value;return value}throw new TypeError(\"Cannot set property\")}parent=Object.getPrototypeOf(parent)}receiver[prop]=value;return value};";

/// derived constructor의 `this` 초기화 상태를 ES5 출력에서 보존한다.
/// Babel/SWC helper와 같은 역할: super() 전 this 접근, super() 중복 호출,
/// primitive return을 런타임에서 spec에 맞게 throw한다.
pub const DERIVED_CONSTRUCTOR_RUNTIME =
    \\var __assertThisInitialized = function(self) {
    \\  if (self === void 0) throw new ReferenceError("this hasn't been initialised - super() hasn't been called");
    \\  return self;
    \\};
    \\var __assertThisUninitialized = function(self) {
    \\  if (self !== void 0) throw new ReferenceError("Super constructor may only be called once");
    \\};
    \\var __possibleConstructorReturn = function(call, self) {
    \\  if (call && (typeof call === "object" || typeof call === "function")) return call;
    \\  if (call !== void 0) throw new TypeError("Derived constructors may only return object or undefined");
    \\  return __assertThisInitialized(self);
    \\};
    \\
;
pub const DERIVED_CONSTRUCTOR_RUNTIME_MIN =
    "var " ++ NAMES.ASSERT_THIS_INITIALIZED_MIN ++ "=function(self){if(self===void 0)throw new ReferenceError(\"this hasn't been initialised - super() hasn't been called\");return self};" ++
    "var " ++ NAMES.ASSERT_THIS_UNINITIALIZED_MIN ++ "=function(self){if(self!==void 0)throw new ReferenceError(\"Super constructor may only be called once\")};" ++
    "var " ++ NAMES.POSSIBLE_CONSTRUCTOR_RETURN_MIN ++ "=function(call,self){if(call&&(typeof call===\"object\"||typeof call===\"function\"))return call;if(call!==void 0)throw new TypeError(\"Derived constructors may only return object or undefined\");return " ++ NAMES.ASSERT_THIS_INITIALIZED_MIN ++ "(self)};";

/// ES2015 TDZ read helper. Babel/OXC runtime의 tdz helper와 같은 역할이다.
pub const TDZ_RUNTIME =
    \\var __tdz = function(name) {
    \\  throw new ReferenceError(name + " is not defined - temporal dead zone");
    \\};
    \\
;
pub const TDZ_RUNTIME_MIN = "var " ++ NAMES.TDZ_MIN ++ "=function(name){throw new ReferenceError(name+\" is not defined - temporal dead zone\")};";

/// array destructuring의 iterable protocol read helper. TypeScript __read와 같은
/// 구조로 limit 개수만 읽고 iterator.return()으로 close한다.
pub const READ_RUNTIME =
    \\var __read = function(o, n) {
    \\  var m = typeof Symbol === "function" && o[Symbol.iterator];
    \\  if (!m) return o;
    \\  var i = m.call(o), r, ar = [], e;
    \\  try {
    \\    while ((n === void 0 || n-- > 0) && !(r = i.next()).done) ar.push(r.value);
    \\  } catch (error) {
    \\    e = { error: error };
    \\  } finally {
    \\    try {
    \\      if (r && !r.done && (m = i.return)) m.call(i);
    \\    } finally {
    \\      if (e) throw e.error;
    \\    }
    \\  }
    \\  return ar;
    \\};
    \\
;
pub const READ_RUNTIME_MIN = "var " ++ NAMES.READ_MIN ++ "=function(o,n){var m=typeof Symbol===\"function\"&&o[Symbol.iterator];if(!m)return o;var i=m.call(o),r,ar=[],e;try{while((n===void 0||n-- >0)&&!(r=i.next()).done)ar.push(r.value)}catch(error){e={error:error}}finally{try{if(r&&!r.done&&(m=i.return))m.call(i)}finally{if(e)throw e.error}}return ar};";

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
pub const ASYNC_RUNTIME_MIN = "var " ++ NAMES.ASYNC_MIN ++ "=(fn)=>function(...args){return new Promise((resolve,reject)=>{var gen=fn.apply(this,args);function step(key,arg){try{var info=gen[key](arg);var value=info.value}catch(error){reject(error);return}if(info.done)resolve(value);else Promise.resolve(value).then(val=>step(\"next\",val),err=>step(\"throw\",err))}step(\"next\")})};";

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
pub const ASYNC_RUNTIME_ES5_MIN = "var " ++ NAMES.ASYNC_MIN ++ "=function(fn){return function(){var args=Array.prototype.slice.call(arguments);var self=this;return new Promise(function(resolve,reject){var gen=fn.apply(self,args);function step(key,arg){try{var info=gen[key](arg);var value=info.value}catch(error){reject(error);return}if(info.done)resolve(value);else Promise.resolve(value).then(function(val){step(\"next\",val)},function(err){step(\"throw\",err)})}step(\"next\")})}};";

/// __asyncValues: for-await-of 다운레벨 시 주입 (tslib 호환).
/// Async iterator (Symbol.asyncIterator) 가 있으면 그대로 사용, 아니면 sync iterator 를
/// async wrapper 로 래핑. (ES2018 for-await-of 스펙의 GetIterator 와 동일 동작.)
///
/// ES2015 preset (Promise / Symbol 필수) — 순수 ES5 환경에서는 Promise 폴리필 필요.
/// Hermes 는 Promise/Symbol.iterator 지원하므로 문제 없음.
pub const ASYNC_VALUES_RUNTIME =
    \\var __asyncValues = function(o) {
    \\  if (!Symbol.asyncIterator) throw new TypeError("Symbol.asyncIterator is not defined.");
    \\  var m = o[Symbol.asyncIterator], i;
    \\  return m ? m.call(o) : (o = typeof __values === "function" ? __values(o) : o[Symbol.iterator](),
    \\    i = {},
    \\    verb("next"),
    \\    verb("throw"),
    \\    verb("return"),
    \\    i[Symbol.asyncIterator] = function() { return this; },
    \\    i);
    \\  function verb(n) {
    \\    i[n] = o[n] && function(v) {
    \\      return new Promise(function(resolve, reject) {
    \\        v = o[n](v);
    \\        settle(resolve, reject, v.done, v.value);
    \\      });
    \\    };
    \\  }
    \\  function settle(resolve, reject, d, v) {
    \\    Promise.resolve(v).then(function(v) { resolve({ value: v, done: d }); }, reject);
    \\  }
    \\};
    \\
;
pub const ASYNC_VALUES_RUNTIME_MIN = "var " ++ NAMES.ASYNC_VALUES_MIN ++ "=function(o){if(!Symbol.asyncIterator)throw new TypeError(\"Symbol.asyncIterator is not defined.\");var m=o[Symbol.asyncIterator],i;return m?m.call(o):(o=typeof __values===\"function\"?__values(o):o[Symbol.iterator](),i={},verb(\"next\"),verb(\"throw\"),verb(\"return\"),i[Symbol.asyncIterator]=function(){return this},i);function verb(n){i[n]=o[n]&&function(v){return new Promise(function(resolve,reject){v=o[n](v);settle(resolve,reject,v.done,v.value)})}}function settle(resolve,reject,d,v){Promise.resolve(v).then(function(v){resolve({value:v,done:d})},reject)}};";

/// __extends: class 상속 prototype chain + static (ES2015). TypeScript __extends 호환.
///
/// `Object.setPrototypeOf(d, b)` 가 enumerable 무관 모든 static 을 prototype chain 으로
/// 잇는다. 이전엔 `for...in` 만 써서 `Object.defineProperty(C, ..., { configurable, writable, value })`
/// (enumerable 기본값 false) 로 정의된 static 이 누락 — Reanimated 의
/// `LinearTransition.springify` 같은 케이스. Hermes/V8 모두 setPrototypeOf 지원.
pub const EXTENDS_RUNTIME = "var __extends = function(d, b) {\n  Object.setPrototypeOf(d, b);\n  function __() { this.constructor = d; }\n  d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());\n};\n";
pub const EXTENDS_RUNTIME_MIN = "var " ++ NAMES.EXTENDS_MIN ++ "=function(d,b){Object.setPrototypeOf(d,b);function __(){this.constructor=d}d.prototype=b===null?Object.create(b):(__.prototype=b.prototype,new __())};";

/// __generator: generator 상태 머신 (ES2015). TypeScript __generator 호환.
/// signature: `__generator(thisArg, body, genFn)` — body 안 `this` 가 enclosing function 의
/// this 가 되도록 thisArg 첫 인자로 받음 (#1909). `body.call(thisArg, _)`.
/// genFn 은 프로토타입 체인 설정용 (compat-table generator prototype 호환):
///   g -> genFn.prototype -> __GeneratorPrototype -> IteratorPrototype (Symbol.iterator)
pub const GENERATOR_RUNTIME =
    \\var __generator = function() {
    \\  var __iterProto = {};
    \\  __iterProto[Symbol.iterator] = function() { return this; };
    \\  var __genProto = Object.create(__iterProto);
    \\  var __protoSet = typeof Symbol !== "undefined" ? Symbol("__protoSet") : "__gen_proto_set__";
    \\  return function(thisArg, body, genFn) {
    \\    var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g;
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
    \\        op = body.call(thisArg, _);
    \\      } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
    \\      if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    \\    }
    \\  };
    \\}();
    \\
;
pub const GENERATOR_RUNTIME_MIN = "var " ++ NAMES.GENERATOR_MIN ++ "=function(){var __iterProto={};__iterProto[Symbol.iterator]=function(){return this};var __genProto=Object.create(__iterProto);return function(thisArg,body,genFn){var _={label:0,sent:function(){if(t[0]&1)throw t[1];return t[1]},trys:[],ops:[]},f,y,t,g;if(genFn){if(!genFn.__proto_set){Object.setPrototypeOf(genFn.prototype,__genProto);genFn.__proto_set=true}g=Object.create(genFn.prototype)}else{g={};g[Symbol.iterator]=function(){return this}}g.next=verb(0);g[\"throw\"]=verb(1);g[\"return\"]=verb(2);return g;function verb(n){return function(v){return step([n,v])}}function step(op){if(f)throw new TypeError(\"Generator is already executing.\");while(g&&(g=0,op[0]&&(_=0)),_)try{if(f=1,y&&(t=op[0]&2?y[\"return\"]:op[0]?y[\"throw\"]||((t=y[\"return\"])&&t.call(y),0):y.next)&&!(t=t.call(y,op[1])).done)return t;if(y=0,t)op=[op[0]&2,t.value];switch(op[0]){case 0:case 1:t=op;break;case 4:_.label++;return{value:op[1],done:false};case 5:_.label++;y=op[1];op=[0];continue;case 7:op=_.ops.pop();_.trys.pop();continue;default:if(!(t=_.trys,t=t.length>0&&t[t.length-1])&&(op[0]===6||op[0]===2)){_=0;continue}if(op[0]===3&&(!t||(op[1]>t[0]&&op[1]<t[3]))){_.label=op[1];break}if(op[0]===6&&_.label<t[1]){_.label=t[1];t=op;break}if(t&&_.label<t[2]){_.label=t[2];_.ops.push(op);break}if(t[2])_.ops.pop();_.trys.pop();continue}op=body.call(thisArg,_)}catch(e){op=[6,e];y=0}finally{f=t=0}if(op[0]&5)throw op[1];return{value:op[0]?op[1]:void 0,done:true}}}}();";

/// __wrapRegExp: named capture group 다운레벨 (#1063). Hermes/ES5 등 named capture 미지원
/// 환경에서 strip 후에도 `re.exec(s).groups.NAME` / `s.replace(re, "$<NAME>")` 가 동작하도록
/// RegExp 를 wrap 한다. Babel `_wrapRegExp` 와 동일 패턴 (RegExp 상속 + exec/Symbol.replace
/// override + WeakMap 으로 groups map 보유).
///
/// constructor-side `setPrototypeOf(BabelRegExp, RegExp)` 는 `Symbol.species` 상속용 (#4200):
/// 없으면 `matchAll`/`split` 의 SpeciesConstructor 가 %RegExp% 로 폴백해 strip 된 패턴의
/// plain RegExp 를 새로 만들어 exec override 를 우회 → `.groups` 전부 유실. species 가
/// BabelRegExp 를 반환해야 `new BabelRegExp(re, flags)` 가 `_groups.get(re)` 폴백으로
/// 원본의 groups map 을 물려받는다 (babel `_inherits` 동형).
pub const WRAP_REGEXP_RUNTIME =
    \\var __wrapRegExp = function() {
    \\  __wrapRegExp = function(re, groups) { return new BabelRegExp(re, undefined, groups); };
    \\  var _super = RegExp.prototype;
    \\  var _groups = new WeakMap();
    \\  function BabelRegExp(re, flags, groups) {
    \\    var _this = new RegExp(re, flags);
    \\    _groups.set(_this, groups || _groups.get(re));
    \\    return Object.setPrototypeOf(_this, BabelRegExp.prototype);
    \\  }
    \\  Object.setPrototypeOf(BabelRegExp.prototype, RegExp.prototype);
    \\  Object.setPrototypeOf(BabelRegExp, RegExp);
    \\  BabelRegExp.prototype.exec = function(str) {
    \\    var result = _super.exec.call(this, str);
    \\    if (result) {
    \\      result.groups = buildGroups(result, this);
    \\      var indices = result.indices;
    \\      if (indices) indices.groups = buildGroups(indices, this);
    \\    }
    \\    return result;
    \\  };
    \\  BabelRegExp.prototype[Symbol.replace] = function(str, substitution) {
    \\    if (typeof substitution === "string") {
    \\      var groups = _groups.get(this);
    \\      return _super[Symbol.replace].call(this, str, substitution.replace(/\$<([^>]+)(>|$)/g, function(match, name, end) {
    \\        if (end === "") return match;
    \\        var group = groups[name];
    \\        return Array.isArray(group) ? "$" + group.join("$") : typeof group === "number" ? "$" + group : "";
    \\      }));
    \\    } else if (typeof substitution === "function") {
    \\      var _this = this;
    \\      return _super[Symbol.replace].call(this, str, function() {
    \\        var args = arguments;
    \\        if (typeof args[args.length - 1] !== "object") {
    \\          args = [].slice.call(args);
    \\          args.push(buildGroups(args, _this));
    \\        }
    \\        return substitution.apply(this, args);
    \\      });
    \\    }
    \\    return _super[Symbol.replace].call(this, str, substitution);
    \\  };
    \\  function buildGroups(result, re) {
    \\    var g = _groups.get(re);
    \\    return Object.keys(g).reduce(function(groups, name) {
    \\      var i = g[name];
    \\      if (typeof i === "number") groups[name] = result[i];
    \\      else {
    \\        var k = 0;
    \\        while (result[i[k]] === undefined && k + 1 < i.length) k++;
    \\        groups[name] = result[i[k]];
    \\      }
    \\      return groups;
    \\    }, Object.create(null));
    \\  }
    \\  return __wrapRegExp.apply(this, arguments);
    \\};
    \\
;
pub const WRAP_REGEXP_RUNTIME_MIN = "var " ++ NAMES.WRAP_REGEXP_MIN ++ "=function(){" ++ NAMES.WRAP_REGEXP_MIN ++ "=function(re,groups){return new BabelRegExp(re,undefined,groups)};var _super=RegExp.prototype;var _groups=new WeakMap();function BabelRegExp(re,flags,groups){var _this=new RegExp(re,flags);_groups.set(_this,groups||_groups.get(re));return Object.setPrototypeOf(_this,BabelRegExp.prototype)}Object.setPrototypeOf(BabelRegExp.prototype,RegExp.prototype);Object.setPrototypeOf(BabelRegExp,RegExp);BabelRegExp.prototype.exec=function(str){var result=_super.exec.call(this,str);if(result){result.groups=buildGroups(result,this);var indices=result.indices;if(indices)indices.groups=buildGroups(indices,this)}return result};BabelRegExp.prototype[Symbol.replace]=function(str,substitution){if(typeof substitution===\"string\"){var groups=_groups.get(this);return _super[Symbol.replace].call(this,str,substitution.replace(/\\$<([^>]+)(>|$)/g,function(match,name,end){if(end===\"\")return match;var group=groups[name];return Array.isArray(group)?\"$\"+group.join(\"$\"):typeof group===\"number\"?\"$\"+group:\"\"}))}else if(typeof substitution===\"function\"){var _this=this;return _super[Symbol.replace].call(this,str,function(){var args=arguments;if(typeof args[args.length-1]!==\"object\"){args=[].slice.call(args);args.push(buildGroups(args,_this))}return substitution.apply(this,args)})}return _super[Symbol.replace].call(this,str,substitution)};function buildGroups(result,re){var g=_groups.get(re);return Object.keys(g).reduce(function(groups,name){var i=g[name];if(typeof i===\"number\")groups[name]=result[i];else{var k=0;while(result[i[k]]===undefined&&k+1<i.length)k++;groups[name]=result[i[k]]}return groups},Object.create(null))}return " ++ NAMES.WRAP_REGEXP_MIN ++ ".apply(this,arguments)};";

/// __await: async generator 안 await 표현의 wrapper. (#1911)
/// `await x` 는 async generator body 안에서 `yield __await(x)` 로 변환되며,
/// `__asyncGenerator` 의 step() 가 `r.value instanceof __await` 으로 인식해 Promise resolve.
pub const AWAIT_RUNTIME =
    \\var __await = function(v) {
    \\  return this instanceof __await ? (this.v = v, this) : new __await(v);
    \\};
    \\
;
pub const AWAIT_RUNTIME_MIN = "var __await=function(v){return this instanceof __await?(this.v=v,this):new __await(v)};";

/// __asyncGenerator: async generator (`async function*`) → Symbol.asyncIterator 객체 반환.
/// tslib 호환. (#1911) `yield value` 는 그대로 yield, `await x` 는 `yield __await(x)` 로
/// transform 단계에서 변환되어 step() 가 `__await` instance 인 경우 Promise.resolve 후 resume.
pub const ASYNC_GENERATOR_RUNTIME =
    \\var __asyncGenerator = function(thisArg, _arguments, generator) {
    \\  if (!Symbol.asyncIterator) throw new TypeError("Symbol.asyncIterator is not defined.");
    \\  var g = generator.apply(thisArg, _arguments || []), q = [], i;
    \\  return i = {}, verb("next"), verb("throw"), verb("return"),
    \\    i[Symbol.asyncIterator] = function() { return this; }, i;
    \\  function verb(n, f) {
    \\    if (g[n]) i[n] = function(v) { return new Promise(function(a, b) { q.push([n, v, a, b]) > 1 || resume(n, v); }); };
    \\    if (f) i[n] = f(i[n]);
    \\  }
    \\  function resume(n, v) { try { step(g[n](v)); } catch (e) { settle(q[0][3], e); } }
    \\  function step(r) {
    \\    r.value instanceof __await
    \\      ? Promise.resolve(r.value.v).then(fulfill, reject)
    \\      : settle(q[0][2], r);
    \\  }
    \\  function fulfill(value) { resume("next", value); }
    \\  function reject(value) { resume("throw", value); }
    \\  function settle(f, v) { if (f(v), q.shift(), q.length) resume(q[0][0], q[0][1]); }
    \\};
    \\
;
pub const ASYNC_GENERATOR_RUNTIME_MIN = "var __asyncGenerator=function(thisArg,_arguments,generator){if(!Symbol.asyncIterator)throw new TypeError(\"Symbol.asyncIterator is not defined.\");var g=generator.apply(thisArg,_arguments||[]),q=[],i;return i={},verb(\"next\"),verb(\"throw\"),verb(\"return\"),i[Symbol.asyncIterator]=function(){return this},i;function verb(n,f){if(g[n])i[n]=function(v){return new Promise(function(a,b){q.push([n,v,a,b])>1||resume(n,v)})};if(f)i[n]=f(i[n])}function resume(n,v){try{step(g[n](v))}catch(e){settle(q[0][3],e)}}function step(r){r.value instanceof __await?Promise.resolve(r.value.v).then(fulfill,reject):settle(q[0][2],r)}function fulfill(value){resume(\"next\",value)}function reject(value){resume(\"throw\",value)}function settle(f,v){if(f(v),q.shift(),q.length)resume(q[0][0],q[0][1])}};";

/// __values: iterable → iterator 변환 (ES2015 yield* / for-of helper). tslib 호환.
/// `Symbol.iterator` 호출 가능하면 그 결과 반환. 없으면 `length` 기반 array-like fallback.
/// (#1910) `yield* 'abc'` 같이 raw iterable 을 generator state machine 의 op[5] 가 받을 때
/// `.next` 호출 가능한 iterator 로 wrap 필요.
pub const VALUES_RUNTIME =
    \\var __values = function(o) {
    \\  var s = typeof Symbol === "function" && Symbol.iterator, m = s && o[s], i = 0;
    \\  if (m) return m.call(o);
    \\  if (o && typeof o.length === "number") return {
    \\    next: function() {
    \\      if (o && i >= o.length) o = void 0;
    \\      return { value: o && o[i++], done: !o };
    \\    }
    \\  };
    \\  throw new TypeError(s ? "Object is not iterable." : "Symbol.iterator is not defined.");
    \\};
    \\
;
pub const VALUES_RUNTIME_MIN = "var __values=function(o){var s=typeof Symbol===\"function\"&&Symbol.iterator,m=s&&o[s],i=0;if(m)return m.call(o);if(o&&typeof o.length===\"number\")return{next:function(){if(o&&i>=o.length)o=void 0;return{value:o&&o[i++],done:!o}}};throw new TypeError(s?\"Object is not iterable.\":\"Symbol.iterator is not defined.\")};";

/// __taggedTemplateLiteral: tagged template literal의 template 객체 생성 (ES2015).
/// cooked 배열에 raw 프로퍼티를 추가하여 Object.freeze로 불변 처리.
/// raw가 cooked와 동일하면 생략 가능 (두 번째 인자 없이 호출).
pub const TAGGED_TEMPLATE_RUNTIME = "var __taggedTemplateLiteral = function(cooked, raw) {\n\tif (!raw) raw = cooked.slice(0);\n\treturn Object.freeze(Object.defineProperty(cooked, \"raw\", { value: Object.freeze(raw) }));\n};\n";
pub const TAGGED_TEMPLATE_RUNTIME_MIN = "var " ++ NAMES.TAGGED_TEMPLATE_MIN ++ "=function(cooked,raw){if(!raw)raw=cooked.slice(0);return Object.freeze(Object.defineProperty(cooked,\"raw\",{value:Object.freeze(raw)}))};";

/// __rest: object destructuring rest (ES2018). TypeScript __rest 호환.
/// exclude 배열에 없는 own 프로퍼티 + Symbol 프로퍼티 복사.
/// `e[]` in-place String 정규화: computed key 가 number/Symbol 일 수 있어 indexOf 비교 전에 String 화 (Symbol 제외).
/// transformer 가 매 호출마다 새 array literal 을 만드므로 (es2015_destructuring.buildRestCall) cache 충돌 없음.
pub const REST_RUNTIME =
    \\var __rest = function(s, e) {
    \\  var t = {};
    \\  for (var i = 0; i < e.length; i++) e[i] = typeof e[i] === "symbol" ? e[i] : String(e[i]);
    \\  for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p) && e.indexOf(p) < 0) t[p] = s[p];
    \\  if (typeof Object.getOwnPropertySymbols === "function")
    \\    for (var i = 0, symbols = Object.getOwnPropertySymbols(s); i < symbols.length; i++)
    \\      if (e.indexOf(symbols[i]) < 0 && Object.prototype.propertyIsEnumerable.call(s, symbols[i]))
    \\        t[symbols[i]] = s[symbols[i]];
    \\  return t;
    \\};
    \\
;
pub const REST_RUNTIME_MIN = "var " ++ NAMES.REST_MIN ++ "=function(s,e){var t={};for(var i=0;i<e.length;i++)e[i]=typeof e[i]===\"symbol\"?e[i]:String(e[i]);for(var p in s)if(Object.prototype.hasOwnProperty.call(s,p)&&e.indexOf(p)<0)t[p]=s[p];if(typeof Object.getOwnPropertySymbols===\"function\")for(var i=0,symbols=Object.getOwnPropertySymbols(s);i<symbols.length;i++)if(e.indexOf(symbols[i])<0&&Object.prototype.propertyIsEnumerable.call(s,symbols[i]))t[symbols[i]]=s[symbols[i]];return t};";

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
pub const TO_BINARY_RUNTIME_MIN = "var " ++ NAMES.TO_BINARY_MIN ++ "=function(b64){var str=atob(b64),arr=new Uint8Array(str.length);for(var i=0;i<str.length;i++)arr[i]=str.charCodeAt(i);return arr};";

/// __name: 함수/클래스의 .name 프로퍼티를 보존 (esbuild --keep-names 호환).
/// minify로 식별자가 축약되어도 원래 이름을 .name에 설정.
pub const KEEP_NAMES_RUNTIME = "var __name = (target, value) => Object.defineProperty(target, \"name\", { value, configurable: true });\n";
pub const KEEP_NAMES_RUNTIME_MIN = "var " ++ NAMES.NAME_MIN ++ "=(target,value)=>Object.defineProperty(target,\"name\",{value,configurable:true});";

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
// MIN 변형은 진단 메시지 축약 (esbuild/terser 관행 — TypeError 타입·throw
// 조건 동일, message 텍스트는 비계약. dev 변형은 descriptive 유지).
pub const PRIVATE_METHOD_INIT_RUNTIME_MIN = "var " ++ NAMES.PRIVATE_METHOD_INIT_MIN ++ "=function(obj,privateSet){if(privateSet.has(obj))throw new TypeError(\"private re-init\");privateSet.add(obj)};";

/// __classPrivateMethodGet: brand check + private method 접근 (SWC 호환).
/// this.#method() 호출 시 brand check 후 함수 참조 반환.
pub const PRIVATE_METHOD_GET_RUNTIME =
    \\var __classPrivateMethodGet = function(receiver, privateSet, fn) {
    \\  if (!privateSet.has(receiver)) throw new TypeError("attempted to get private field on non-instance");
    \\  return fn;
    \\};
    \\
;
// #1751: trailing `;` — 뒤따르는 `var __xxx=...` 와 문법 구분 필수.
pub const PRIVATE_METHOD_GET_RUNTIME_MIN = "var " ++ NAMES.PRIVATE_METHOD_GET_MIN ++ "=function(receiver,privateSet,fn){if(!privateSet.has(receiver))throw new TypeError(\"private brand\");return fn};";

// ============================================================
// Static Private Field (ES2022 downlevel)
// ============================================================

/// __classCheckPrivateStaticAccess: receiver가 classConstructor와 동일한지 확인.
/// static private field 접근 시 brand check.
///
/// __classCheckPrivateStaticFieldDescriptor: descriptor가 정의되었는지 확인.
/// 선언 전 접근 방지 (TDZ).
///
/// __classStaticPrivateFieldSpecGet: static private field 읽기.
/// descriptor.get이 있으면 getter 호출, 없으면 descriptor.value 반환.
///
/// __classStaticPrivateFieldSpecSet: static private field 쓰기.
/// descriptor.set이 있으면 setter 호출, 없으면 descriptor.value에 직접 대입.
pub const STATIC_PRIVATE_FIELD_RUNTIME =
    \\var __classCheckPrivateStaticAccess = function(receiver, classConstructor) {
    \\  if (receiver !== classConstructor)
    \\    throw new TypeError("Private static access of wrong provenance");
    \\};
    \\var __classCheckPrivateStaticFieldDescriptor = function(descriptor, action) {
    \\  if (descriptor === undefined)
    \\    throw new TypeError("attempted to " + action + " private static field before its declaration");
    \\};
    \\var __classStaticPrivateFieldSpecGet = function(receiver, classConstructor, descriptor) {
    \\  __classCheckPrivateStaticAccess(receiver, classConstructor);
    \\  __classCheckPrivateStaticFieldDescriptor(descriptor, "get");
    \\  return descriptor.get ? descriptor.get.call(receiver) : descriptor.value;
    \\};
    \\var __classStaticPrivateFieldSpecSet = function(receiver, classConstructor, descriptor, value) {
    \\  __classCheckPrivateStaticAccess(receiver, classConstructor);
    \\  __classCheckPrivateStaticFieldDescriptor(descriptor, "set");
    \\  if (descriptor.set) descriptor.set.call(receiver, value);
    \\  else descriptor.value = value;
    \\  return value;
    \\};
    \\
;
pub const STATIC_PRIVATE_FIELD_RUNTIME_MIN =
    "var " ++ NAMES.STATIC_PRIVATE_ACCESS_MIN ++ "=function(receiver,classConstructor){if(receiver!==classConstructor)throw new TypeError(\"private static\")};" ++
    "var " ++ NAMES.STATIC_PRIVATE_DESC_MIN ++ "=function(descriptor,action){if(descriptor===undefined)throw new TypeError(\"private static \"+action)};" ++
    "var " ++ NAMES.STATIC_PRIVATE_GET_MIN ++ "=function(receiver,classConstructor,descriptor){" ++
    NAMES.STATIC_PRIVATE_ACCESS_MIN ++ "(receiver,classConstructor);" ++
    NAMES.STATIC_PRIVATE_DESC_MIN ++ "(descriptor,\"get\");" ++
    "return descriptor.get?descriptor.get.call(receiver):descriptor.value};" ++
    "var " ++ NAMES.STATIC_PRIVATE_SET_MIN ++ "=function(receiver,classConstructor,descriptor,value){" ++
    NAMES.STATIC_PRIVATE_ACCESS_MIN ++ "(receiver,classConstructor);" ++
    NAMES.STATIC_PRIVATE_DESC_MIN ++ "(descriptor,\"set\");" ++
    "if(descriptor.set)descriptor.set.call(receiver,value);else descriptor.value=value;return value};";

/// __classPrivateFieldSet: instance private field 쓰기 + 값 반환.
/// `wm.set(obj, value)` 는 WeakMap을 반환하므로 expression 값이 값 자체가 되도록 helper 사용.
/// 통합 spec: `this.#x = v` expression value === v, `this.#x += 5` === new value.
pub const PRIVATE_FIELD_SET_RUNTIME =
    \\var __zntcClassPrivateFieldSet = function(wm, obj, value) {
    \\  wm.set(obj, value);
    \\  return value;
    \\};
    \\
;
pub const PRIVATE_FIELD_SET_RUNTIME_MIN = "var " ++ NAMES.PRIVATE_FIELD_SET_MIN ++ "=function(wm,obj,value){wm.set(obj,value);return value};";

// ============================================================
// HMR (Dev Server)
// ============================================================

/// HMR 런타임: 모듈별 $RefreshReg$ save/restore + globalEvalWithSourceUrl 기반.
/// dev mode 번들 상단에 주입된다.
///
/// 구조:
///   __commonJS/__esm → __zntc_modules[id]에 자동 등록 (reset 기능 포함)
///   __zntc_make_hot(id) → import.meta.hot 호환 API (refresh, refreshUtils 포함)
///   __zntc_apply_update([{id, code}]) → globalEvalWithSourceUrl/eval + accept 콜백
///   __zntc_isReactRefreshBoundary(exports) → 모든 export가 React 컴포넌트인지 확인
///   __zntc_enqueueUpdate() → 50ms debounce로 performReactRefresh 배칭
///   모듈별 $RefreshReg$/$RefreshSig$ save/restore (emitter에서 주입)
pub const HMR_RUNTIME =
    \\// issue #3869 — Proxy wrap. CSS module (.module.zntc.css) side-effect
    \\// import 가 transpile 시 .fn() 호출로 변환되나 bundler 가 CSS module
    \\// 의 __esm wrap entry 등록 안 함 → undefined.fn() TypeError → script 중단.
    \\// /code-review max #2/#6: noop fallback 을 .css key 만 한정 — JS module
    \\// 의 missing entry 는 undefined 유지하여 기존 fallthrough 동작 (HMR update
    \\// 의 silent loss / dev 의 noisy TypeError 진단 가시성) 보존.
    \\var __zntc_g = typeof globalThis !== "undefined" ? globalThis : typeof global !== "undefined" ? global : typeof window !== "undefined" ? window : this;
    \\var __zntc_modules = __zntc_g.__zntc_modules || (__zntc_g.__zntc_modules = typeof Proxy !== "undefined"
    \\  ? new Proxy({}, { get: function(t, k) {
    \\      if (Object.prototype.hasOwnProperty.call(t, k)) return t[k];
    \\      if (typeof k === "string" && k.length >= 4 && k.slice(-4) === ".css") {
    \\        return { fn: function() {}, exports: {} };
    \\      }
    \\      return undefined;
    \\    } })
    \\  : {});
    \\var __zntc_hot_cbs = {};
    \\var __zntc_hot_data = {};
    \\function __zntc_schedule(fn) {
    \\  if (typeof setTimeout === "function") setTimeout(fn, 0);
    \\  else fn();
    \\}
    \\var __zntc_reload = function(reason) {
    \\  __zntc_schedule(function() {
    \\    var why = reason || "ZNTC HMR fallback";
    \\    if (typeof require === "function") {
    \\      try {
    \\        var rn = require("react-native");
    \\        if (rn && rn.DevSettings && typeof rn.DevSettings.reload === "function") {
    \\          rn.DevSettings.reload(why);
    \\          return;
    \\        }
    \\      } catch (_e) {}
    \\    }
    \\    if (typeof location !== "undefined" && location && typeof location.reload === "function") {
    \\      location.reload();
    \\      return;
    \\    }
    \\    if (__zntc_g.nativeModuleProxy && __zntc_g.nativeModuleProxy.DevSettings) {
    \\      var ds = __zntc_g.nativeModuleProxy.DevSettings;
    \\      if (typeof ds.reloadWithReason === "function") ds.reloadWithReason(why);
    \\      else if (typeof ds.reload === "function") ds.reload();
    \\    }
    \\  });
    \\};
    \\// react-refresh/runtime resolve: 번들 모듈 레지스트리(__zntc_modules[__zntc_refresh_id])
    \\// 를 우선 사용 — RN(Hermes)엔 전역 require 가 없어 setUpReactRefresh 가 require 한 것과
    \\// 동일 인스턴스를 공유해야 한다. 전역 require() 는 브라우저/fallback 경로.
    \\function __zntc_resolveRefresh() {
    \\  if (__zntc_g.__ReactRefresh) return __zntc_g.__ReactRefresh;
    \\  var __rid = __zntc_g.__zntc_refresh_id;
    \\  if (__rid && __zntc_g.__zntc_modules) {
    \\    try {
    \\      var __e = __zntc_g.__zntc_modules[__rid];
    \\      if (__e) {
    \\        var __fr = __e.fn ? __e.fn() : null;   // cjs: module.exports 반환
    \\        var __re = __e.exports || __fr;        // esm: exports 객체
    \\        if (__re && __re.injectIntoGlobalHook) { __zntc_g.__ReactRefresh = __re; __zntc_g.__REACT_REFRESH_RUNTIME__ = __re; __re.injectIntoGlobalHook(__zntc_g); return __re; }
    \\      }
    \\    } catch(_e) {}
    \\  }
    \\  try { var r = require("react-refresh/runtime"); __zntc_g.__ReactRefresh = r; __zntc_g.__REACT_REFRESH_RUNTIME__ = r; return r; } catch(e) {}
    \\  return null;
    \\}
    \\// isReactRefreshBoundary: 모든 export가 React 컴포넌트면 true.
    \\// mixed export 모듈은 HMR 대상에서 제외 → full reload.
    \\function __zntc_isReactRefreshBoundary(moduleExports) {
    \\  var rt = __zntc_g.__ReactRefresh || __zntc_resolveRefresh();
    \\  if (!rt) return false;
    \\  if (rt.isLikelyComponentType(moduleExports)) return true;
    \\  if (moduleExports == null || typeof moduleExports !== "object") return false;
    \\  var hasExports = false;
    \\  for (var key in moduleExports) {
    \\    if (key === "__esModule") continue;
    \\    hasExports = true;
    \\    if (!rt.isLikelyComponentType(moduleExports[key])) return false;
    \\  }
    \\  return hasExports;
    \\}
    \\// enqueueUpdate: 50ms debounce로 performReactRefresh 배칭.
    \\// 여러 모듈 업데이트를 한 번의 React refresh 사이클로 처리.
    \\var __zntc_refreshTimer;
    \\function __zntc_enqueueUpdate() {
    \\  if (__zntc_refreshTimer != null) return;
    \\  __zntc_refreshTimer = setTimeout(function() {
    \\    __zntc_refreshTimer = null;
    \\    var rt = __zntc_g.__ReactRefresh || __zntc_resolveRefresh();
    \\    if (rt) rt.performReactRefresh();
    \\  }, 50);
    \\}
    \\function __zntc_make_hot(id) {
    \\  if (!__zntc_hot_cbs[id]) __zntc_hot_cbs[id] = {};
    \\  return {
    \\    get data() { return __zntc_hot_data[id]; },
    \\    accept: function(deps, cb) {
    \\      if (typeof deps === "function") { cb = deps; deps = undefined; }
    \\      __zntc_hot_cbs[id].accept = cb || true;
    \\      if (Array.isArray(deps)) __zntc_hot_cbs[id].acceptDeps = deps;
    \\    },
    \\    dispose: function(cb) { __zntc_hot_cbs[id].dispose = cb; },
    \\    prune: function(cb) { __zntc_hot_cbs[id].prune = cb; },
    \\    invalidate: function() { __zntc_reload(); },
    \\    get refresh() { return __zntc_g.__ReactRefresh || __zntc_resolveRefresh(); },
    \\    refreshUtils: {
    \\      isReactRefreshBoundary: __zntc_isReactRefreshBoundary,
    \\      enqueueUpdate: __zntc_enqueueUpdate
    \\    }
    \\  };
    \\}
    \\// __commonJS/__esm HMR 래핑: 모듈을 __zntc_modules에 자동 등록.
    \\// 기존 __commonJS/__esm을 래핑하여 reset 기능 추가.
    \\var __zntc_orig_commonJS = typeof __commonJS !== "undefined" ? __commonJS : null;
    \\var __zntc_orig_esm = typeof __esm !== "undefined" ? __esm : null;
    \\if (__zntc_orig_commonJS) __commonJS = function(cb, mod) {
    \\  var id = Object.keys(cb)[0];
    \\  var fn = __zntc_orig_commonJS(cb, mod);
    \\  __zntc_modules[id] = { type: "cjs", fn: fn, reset: function() {
    \\    fn = __zntc_orig_commonJS(cb);
    \\    __zntc_modules[id].fn = fn;
    \\  }};
    \\  return fn;
    \\};
    \\if (__zntc_orig_esm) __esm = function(fn, res, exportsObj) {
    \\  var id = Object.keys(fn)[0];
    \\  var init = __zntc_orig_esm(fn, res);
    \\  __zntc_modules[id] = { type: "esm", fn: init, exports: exportsObj, reset: function() {
    \\    init = __zntc_orig_esm(fn);
    \\    __zntc_modules[id].fn = init;
    \\  }};
    \\  return init;
    \\};
    \\// HMR 업데이트: globalEvalWithSourceUrl (RN) 또는 indirect eval (브라우저).
    \\// per-module IIFE에 런타임 헬퍼 로컬 alias가 포함되므로 파라미터 전달 불필요.
    \\function __zntc_apply_update(updates) {
    \\  for (var i = 0; i < updates.length; i++) {
    \\    var id = updates[i].id;
    \\    var cbs = __zntc_hot_cbs[id];
    \\    if (!cbs || !cbs.accept) { __zntc_reload(); return; }
    \\    try {
    \\      if (cbs.dispose) {
    \\        __zntc_hot_data[id] = {};
    \\        cbs.dispose(__zntc_hot_data[id]);
    \\      }
    \\      var evalFn = __zntc_g.globalEvalWithSourceUrl;
    \\      if (evalFn) {
    \\        evalFn(updates[i].code, "hmr-update:" + id);
    \\      } else {
    \\        (0, eval)(updates[i].code);
    \\      }
    \\      // eval은 __esm factory를 등록만 함 — fn()을 호출해야 모듈 본문 실행 + $RefreshReg$ 트리거
    \\      var entry = __zntc_modules[id];
    \\      if (entry && entry.fn) entry.fn();
    \\      if (typeof cbs.accept === "function") {
    \\        cbs.accept(entry && entry.exports ? entry.exports : {});
    \\      }
    \\    } catch(e) { console.error("[zntc] HMR update failed:", e); __zntc_reload(); }
    \\  }
    \\}
    \\// 글로벌 $RefreshReg$/$RefreshSig$ + HMR API + 런타임 헬퍼 전역 노출.
    \\// Metro 와 동등하게 IIFE 안 function scope 에서 globalThis assignment 수행.
    \\// top-level 의 `globalThis.X = ...` 구문은 Hermes 가 (특히 iOS 26+) spec global
    \\// (`Location`, `TextEncoderStream` 등) placeholder lazy registration 을 trigger
    \\// 할 수 있으므로 IIFE 로 scope 격리. Metro bundle 의 `(function(global){ ...
    \\// global.__r = metroRequire; ... })(globalThis)` 패턴과 동등.
    \\(function(g) {
    \\  'use strict';
    \\  g.$RefreshReg$ = function() {};
    \\  g.$RefreshSig$ = function() { return function(type) { return type; }; };
    \\  g.__zntc_apply_update = __zntc_apply_update;
    \\  g.__zntc_reload = __zntc_reload;
    \\  g.__zntc_make_hot = __zntc_make_hot;
    \\  g.__zntc_modules = __zntc_modules;
    \\  g.__zntc_resolveRefresh = __zntc_resolveRefresh;
    \\  g.__zntc_isReactRefreshBoundary = __zntc_isReactRefreshBoundary;
    \\  g.__zntc_enqueueUpdate = __zntc_enqueueUpdate;
    \\  if (typeof __esm !== "undefined") g.__esm = __esm;
    \\  if (typeof __export !== "undefined") g.__export = __export;
    \\  if (typeof __commonJS !== "undefined") g.__commonJS = __commonJS;
    \\  if (typeof __defProp !== "undefined") g.__defProp = __defProp;
    \\  if (typeof __toESM !== "undefined") g.__toESM = __toESM;
    \\  if (typeof __toCommonJS !== "undefined") g.__toCommonJS = __toCommonJS;
    \\})(__zntc_g);
    \\
;

/// HMR_CHUNK_REGISTER (RFC_LAZY_DEV_MODULE_HMR PR-2): dev_split 의 **비-entry 청크**
/// (shared/dynamic)가 자기 모듈을 글로벌 `__zntc_modules` 에 등록하게 하는 최소 prelude.
/// = 글로벌 `__zntc_modules`(멱등 `||`) + `__commonJS`/`__esm` wrap(청크-로컬 factory 를
/// 재할당해 등록). entry 청크/단일번들은 `HMR_RUNTIME`(register+core 전부)을 쓰므로 이건
/// 비-entry 전용. ⚠️ 글로벌 `__zntc_modules`(`__zntc_g.__zntc_modules || (...)`) + wrap
/// 로직은 **3곳에 미러**다: `HMR_RUNTIME`, `HMR_RUNTIME_MIN`, 그리고 여기. 한 곳을
/// 바꾸면 셋 다 동반 수정(특히 글로벌-백킹 `||` 패턴이 한 곳이라도 빠지면 minify
/// 경로에서 entry/비-entry 레지스트리가 갈려 cross-chunk lookup 이 깨진다).
/// 후속 cleanup = 공통 wrap 상수(HMR_REGISTRY_CORE) 추출 후 세 곳이 compose.
/// ⚠️ minify(`$c`/`$e`) 경로: 세 상수 모두 wrap 이 `__commonJS`/`__esm`(non-min) 이름을
/// 참조하므로 minify 빌드에선 모듈 등록이 inert(=dev 는 minify 안 함 전제, 사전 한계).
/// 청크 factory 안에서 `var __esm`(emitChunkRuntimeHelpers 가 정의) **뒤**에 주입돼야
/// orig 를 캡처해 재래핑. 글로벌이라 청크 평가 순서 무관.
pub const HMR_CHUNK_REGISTER =
    \\var __zntc_g = typeof globalThis !== "undefined" ? globalThis : typeof global !== "undefined" ? global : typeof window !== "undefined" ? window : this;
    \\var __zntc_modules = __zntc_g.__zntc_modules || (__zntc_g.__zntc_modules = typeof Proxy !== "undefined"
    \\  ? new Proxy({}, { get: function(t, k) {
    \\      if (Object.prototype.hasOwnProperty.call(t, k)) return t[k];
    \\      if (typeof k === "string" && k.length >= 4 && k.slice(-4) === ".css") {
    \\        return { fn: function() {}, exports: {} };
    \\      }
    \\      return undefined;
    \\    } })
    \\  : {});
    \\var __zntc_orig_commonJS = typeof __commonJS !== "undefined" ? __commonJS : null;
    \\var __zntc_orig_esm = typeof __esm !== "undefined" ? __esm : null;
    \\if (__zntc_orig_commonJS) __commonJS = function(cb, mod) {
    \\  var id = Object.keys(cb)[0];
    \\  var fn = __zntc_orig_commonJS(cb, mod);
    \\  __zntc_modules[id] = { type: "cjs", fn: fn, reset: function() {
    \\    fn = __zntc_orig_commonJS(cb);
    \\    __zntc_modules[id].fn = fn;
    \\  }};
    \\  return fn;
    \\};
    \\if (__zntc_orig_esm) __esm = function(fn, res, exportsObj) {
    \\  var id = Object.keys(fn)[0];
    \\  var init = __zntc_orig_esm(fn, res);
    \\  __zntc_modules[id] = { type: "esm", fn: init, exports: exportsObj, reset: function() {
    \\    init = __zntc_orig_esm(fn);
    \\    __zntc_modules[id].fn = init;
    \\  }};
    \\  return init;
    \\};
    \\
;

pub const HMR_RUNTIME_MIN =
    \\var __zntc_g=typeof globalThis!=="undefined"?globalThis:typeof global!=="undefined"?global:typeof window!=="undefined"?window:this,__zntc_modules=__zntc_g.__zntc_modules||(__zntc_g.__zntc_modules=typeof Proxy!=="undefined"?new Proxy({},{get:function(t,k){if(Object.prototype.hasOwnProperty.call(t,k))return t[k];if(typeof k==="string"&&k.length>=4&&k.slice(-4)===".css")return{fn:function(){},exports:{}};return undefined}}):{}),__zntc_hot_cbs={},__zntc_hot_data={};function __zntc_schedule(f){typeof setTimeout=="function"?setTimeout(f,0):f()}var __zntc_reload=function(reason){__zntc_schedule(function(){var why=reason||"ZNTC HMR fallback";if(typeof require=="function")try{var rn=require("react-native");if(rn&&rn.DevSettings&&typeof rn.DevSettings.reload=="function"){rn.DevSettings.reload(why);return}}catch(_e){}if(typeof location!="undefined"&&location&&typeof location.reload=="function"){location.reload();return}if(__zntc_g.nativeModuleProxy&&__zntc_g.nativeModuleProxy.DevSettings){var ds=__zntc_g.nativeModuleProxy.DevSettings;if(typeof ds.reloadWithReason=="function")ds.reloadWithReason(why);else if(typeof ds.reload=="function")ds.reload()}})};function __zntc_resolveRefresh(){if(__zntc_g.__ReactRefresh)return __zntc_g.__ReactRefresh;var __rid=__zntc_g.__zntc_refresh_id;if(__rid&&__zntc_g.__zntc_modules){try{var __e=__zntc_g.__zntc_modules[__rid];if(__e){var __fr=__e.fn?__e.fn():null;var __re=__e.exports||__fr;if(__re&&__re.injectIntoGlobalHook){__zntc_g.__ReactRefresh=__re;__zntc_g.__REACT_REFRESH_RUNTIME__=__re;__re.injectIntoGlobalHook(__zntc_g);return __re}}}catch(_e){}}try{var r=require("react-refresh/runtime");__zntc_g.__ReactRefresh=r;__zntc_g.__REACT_REFRESH_RUNTIME__=r;return r}catch(e){}return null}function __zntc_isReactRefreshBoundary(m){var rt=__zntc_g.__ReactRefresh||__zntc_resolveRefresh();if(!rt)return false;if(rt.isLikelyComponentType(m))return true;if(m==null||typeof m!="object")return false;var h=false;for(var k in m){if(k==="__esModule")continue;h=true;if(!rt.isLikelyComponentType(m[k]))return false}return h}var __zntc_refreshTimer;function __zntc_enqueueUpdate(){if(__zntc_refreshTimer!=null)return;__zntc_refreshTimer=setTimeout(function(){__zntc_refreshTimer=null;var rt=__zntc_g.__ReactRefresh||__zntc_resolveRefresh();if(rt)rt.performReactRefresh()},50)}function __zntc_make_hot(id){if(!__zntc_hot_cbs[id])__zntc_hot_cbs[id]={};return{get data(){return __zntc_hot_data[id]},accept:function(d,c){if(typeof d==="function"){c=d;d=void 0}__zntc_hot_cbs[id].accept=c||true;if(Array.isArray(d))__zntc_hot_cbs[id].acceptDeps=d},dispose:function(c){__zntc_hot_cbs[id].dispose=c},prune:function(c){__zntc_hot_cbs[id].prune=c},invalidate:function(){__zntc_reload()},get refresh(){return __zntc_g.__ReactRefresh||__zntc_resolveRefresh()},refreshUtils:{isReactRefreshBoundary:__zntc_isReactRefreshBoundary,enqueueUpdate:__zntc_enqueueUpdate}}}var __zntc_oc=typeof __commonJS!="undefined"?__commonJS:null,__zntc_oe=typeof __esm!="undefined"?__esm:null;if(__zntc_oc)__commonJS=function(cb,mod){var id=Object.keys(cb)[0];var fn=__zntc_oc(cb,mod);__zntc_modules[id]={type:"cjs",fn:fn,reset:function(){fn=__zntc_oc(cb);__zntc_modules[id].fn=fn}};return fn};if(__zntc_oe)__esm=function(fn,res,eo){var id=Object.keys(fn)[0];var init=__zntc_oe(fn,res);__zntc_modules[id]={type:"esm",fn:init,exports:eo,reset:function(){init=__zntc_oe(fn);__zntc_modules[id].fn=init}};return init};function __zntc_apply_update(u){for(var i=0;i<u.length;i++){var id=u[i].id;var c=__zntc_hot_cbs[id];if(!c||!c.accept){__zntc_reload();return}try{if(c.dispose){__zntc_hot_data[id]={};c.dispose(__zntc_hot_data[id])}var ev=__zntc_g.globalEvalWithSourceUrl;if(ev){ev(u[i].code,"hmr-update:"+id)}else{(0,eval)(u[i].code)}var ent=__zntc_modules[id];if(ent&&ent.fn)ent.fn();if(typeof c.accept==="function"){c.accept(ent&&ent.exports?ent.exports:{})}}catch(e){console.error("[zntc] HMR update failed:",e);__zntc_reload()}}}(function(g){"use strict";g.$RefreshReg$=function(){};g.$RefreshSig$=function(){return function(t){return t}};g.__zntc_apply_update=__zntc_apply_update;g.__zntc_reload=__zntc_reload;g.__zntc_make_hot=__zntc_make_hot;g.__zntc_modules=__zntc_modules;g.__zntc_resolveRefresh=__zntc_resolveRefresh;g.__zntc_isReactRefreshBoundary=__zntc_isReactRefreshBoundary;g.__zntc_enqueueUpdate=__zntc_enqueueUpdate;if(typeof __esm!="undefined")g.__esm=__esm;if(typeof __export!="undefined")g.__export=__export;if(typeof __commonJS!="undefined")g.__commonJS=__commonJS;if(typeof __defProp!="undefined")g.__defProp=__defProp;if(typeof __toESM!="undefined")g.__toESM=__toESM;if(typeof __toCommonJS!="undefined")g.__toCommonJS=__toCommonJS})(__zntc_g)
;

/// HMR 런타임의 줄 수 (소스맵 오프셋 계산용, comptime)
pub const HMR_RUNTIME_LINES = blk: {
    @setEvalBranchQuota(10000);
    break :blk @as(u32, std.mem.count(u8, HMR_RUNTIME, "\n"));
};

/// React Refresh 스텁: HMR 런타임 없이도 $RefreshReg$/$RefreshSig$ ReferenceError 방지.
/// dev mode + react_refresh에서 번들 prologue에 주입.
pub const REFRESH_STUB =
    "var $RefreshReg$ = function() {};\n" ++
    "var $RefreshSig$ = function() { return function(type) { return type; }; };\n";

/// `entry_error_guard` 활성 시 prologue 에 주입. `__zntc_guarded(fn)` helper —
/// 각 module init 호출 site (entry trigger / linker preamble / re-export / side-effect
/// init) 가 통과. Metro 의 `metro-runtime/src/polyfills/require.js` `guardedLoadModule`
/// 과 같은 의미를 유지한다:
///
/// - outermost 호출이고 `global.ErrorUtils` 가 있으면 try/catch 후
///   `ErrorUtils.reportFatalError(e)` 로 전달한다.
/// - 이미 guard 안이거나 `ErrorUtils` 가 없으면 unguarded 로 실행해 예외를 그대로
///   다시 던진다.
///
/// RN 초기화 중 `InitializeCore` 이전 예외를 silent swallow 하면 `setUpXHR` /
/// `setUpBatchedBridge` 가 건너뛰어 `AbortController`, `HMRClient`, `RCTDeviceEventEmitter`
/// 가 등록되지 않고, 후속 `AppRegistry.registerComponent` 미호출처럼 보이는 2차 오류로
/// 번진다. 따라서 Metro 와 동일하게 ErrorUtils 미설치 구간에서는 반드시 throw 를 보존한다.
///
/// 별도 `console.error` setter intercept (`emitConsoleErrorIntercept`) 는 RN preset 자동
/// 활성 안 함 — `silent_console_error_patterns` 옵션이 비어있으면 emit X. trigger 가
/// expo winter polyfill (TextEncoderStream/TextDecoderStream/Location) ↔ iOS native
/// immutable 충돌처럼 specific 환경에서만 발생하므로, consumer (bungae 등) 가 환경 감지
/// 후 패턴 주입. vanilla RN CLI 빌드는 dead code 0.
pub const GUARDED_RUNTIME =
    \\var __zntc_in_guard = false;
    \\var __zntc_guard_global = typeof global !== "undefined" ? global :
    \\  typeof globalThis !== "undefined" ? globalThis :
    \\  typeof self !== "undefined" ? self :
    \\  typeof window !== "undefined" ? window : void 0;
    \\function __zntc_guarded(fn) {
    \\  if (!__zntc_in_guard && __zntc_guard_global && __zntc_guard_global.ErrorUtils) {
    \\    __zntc_in_guard = true;
    \\    var returnValue;
    \\    try {
    \\      returnValue = fn();
    \\    } catch (e) {
    \\      __zntc_guard_global.ErrorUtils.reportFatalError(e);
    \\    }
    \\    __zntc_in_guard = false;
    \\    return returnValue;
    \\  }
    \\  return fn();
    \\}
    \\
;

pub const GUARDED_RUNTIME_MIN =
    "var $zi=false,$zgG=typeof global!==\"undefined\"?global:typeof globalThis!==\"undefined\"?globalThis:typeof self!==\"undefined\"?self:typeof window!==\"undefined\"?window:void 0;function $zg(fn){if(!$zi&&$zgG&&$zgG.ErrorUtils){$zi=true;var r;try{r=fn()}catch(e){$zgG.ErrorUtils.reportFatalError(e)}$zi=false;return r}return fn()}\n";

/// `silent_console_error_patterns` 가 비어있지 않을 때 prologue 에 주입.
/// `Object.defineProperty(console, "error", { set })` setter intercept — RN
/// `setUpDeveloperTools` 가 console.error 를 LogBox/ExceptionsManager 로 wrap 하지만
/// 우리 setter 가 그 위에 한 번 더 wrap 을 덧씌워 영구 outermost 필터 유지.
///
/// 현재 알려진 trigger:
/// - expo `installGlobal.ts:96` — winter polyfill (TextEncoderStream/TextDecoderStream/
///   Location) 이 iOS native immutable global 위에 redefine 시도 → console.error (throw 안 함)
/// - vanilla RN `Libraries/Utilities/PolyfillFunctions.js:41` — 동일 메시지 형식이지만
///   RN core 가 polyfill 하는 globals (Promise/setTimeout/URL 등) 가 iOS native immutable
///   대상과 안 겹쳐 실측에선 trigger 안 됨. 미래 OS 가 RN core polyfill 영역도 immutable 로
///   깔면 그때 trigger 가능.
///
/// 패턴은 사용자가 RegExp source string 으로 주입. ZNTC 는 expo 모름.
pub fn emitConsoleErrorInterceptInto(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    patterns: []const []const u8,
    minify: bool,
) !void {
    if (patterns.len == 0) return;
    if (minify) {
        try buf.appendSlice(allocator, "(function(){if(typeof console===\"undefined\"||typeof console.error!==\"function\")return;var I=[");
        for (patterns, 0..) |p, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '/');
            try buf.appendSlice(allocator, p);
            try buf.append(allocator, '/');
        }
        try buf.appendSlice(allocator, "];function w(fn){return function(){var f=arguments[0];if(typeof f===\"string\"){for(var i=0;i<I.length;i++){if(I[i].test(f))return}}return fn.apply(this,arguments)}}var c=w(console.error);try{Object.defineProperty(console,\"error\",{configurable:true,get:function(){return c},set:function(fn){c=w(fn)}})}catch(e){}})();\n");
        return;
    }
    try buf.appendSlice(allocator,
        \\(function() {
        \\  if (typeof console === "undefined" || typeof console.error !== "function") return;
        \\  var IGNORE = [
    );
    try buf.append(allocator, '\n');
    for (patterns, 0..) |p, i| {
        try buf.appendSlice(allocator, "    /");
        try buf.appendSlice(allocator, p);
        try buf.append(allocator, '/');
        if (i + 1 < patterns.len) try buf.append(allocator, ',');
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator,
        \\  ];
        \\  function wrap(fn) {
        \\    return function() {
        \\      var first = arguments[0];
        \\      if (typeof first === "string") {
        \\        for (var i = 0; i < IGNORE.length; i++) {
        \\          if (IGNORE[i].test(first)) return;
        \\        }
        \\      }
        \\      return fn.apply(this, arguments);
        \\    };
        \\  }
        \\  var current = wrap(console.error);
        \\  try {
        \\    Object.defineProperty(console, "error", {
        \\      configurable: true,
        \\      get: function() { return current; },
        \\      set: function(fn) { current = wrap(fn); }
        \\    });
        \\  } catch (e) {}
        \\})();
        \\
    );
}

/// `__zntc_guarded(function(){return <expr>;})` wrap 매크로 — esm_wrap / linker preamble /
/// emitter 의 entry chain unroll 모두 같은 형식이라 한 곳에서 정의. 패턴 변경 시 여기만.
pub const GUARD_LAMBDA_OPEN = "__zntc_guarded(function(){return ";
pub const GUARD_LAMBDA_OPEN_MIN = "$zg(function(){return ";
pub const GUARD_LAMBDA_CLOSE = ";});\n";
pub const GUARD_FN_NAME = "__zntc_guarded";
pub const GUARD_FN_NAME_MIN = "$zg";
pub const INIT_CALL_END = ";\n";

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
pub const USING_RUNTIME_MIN = "var " ++ NAMES.USING_MIN ++ "=(stack,value,async)=>{if(value!=null){if(typeof value!==\"object\"&&typeof value!==\"function\")throw new TypeError(\"Object expected\");var dispose,inner;if(async)dispose=value[Symbol.asyncDispose];if(dispose===void 0){dispose=value[Symbol.dispose];if(async)inner=dispose}if(typeof dispose!==\"function\")throw new TypeError(\"Object not disposable\");if(inner)dispose=function(){try{inner.call(this)}catch(e){return Promise.reject(e)}};stack.push([async,dispose,value])}else if(async){stack.push([async])}return value};var " ++ NAMES.CALL_DISPOSE_MIN ++ "=(stack,error,hasError)=>{var E=typeof SuppressedError===\"function\"?SuppressedError:function(e,s,m){var err=new Error(m);err.error=e;err.suppressed=s;return err};var fail=(e)=>error=hasError?new E(e,error,\"An error was suppressed during disposal\"):(hasError=true,e);var next=(it)=>{while(it=stack.pop()){try{var result=it[1]&&it[1].call(it[2]);if(it[0])return Promise.resolve(result).then(next,(e)=>{fail(e);return next()})}catch(e){fail(e)}}if(hasError)throw error};return next()};";

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
pub const USING_RUNTIME_ES5_MIN = "var " ++ NAMES.USING_MIN ++ "=function(stack,value,async){if(value!=null){if(typeof value!==\"object\"&&typeof value!==\"function\")throw new TypeError(\"Object expected\");var dispose,inner;if(async)dispose=value[Symbol.asyncDispose];if(dispose===void 0){dispose=value[Symbol.dispose];if(async)inner=dispose}if(typeof dispose!==\"function\")throw new TypeError(\"Object not disposable\");if(inner)dispose=function(){try{inner.call(this)}catch(e){return Promise.reject(e)}};stack.push([async,dispose,value])}else if(async){stack.push([async])}return value};var " ++ NAMES.CALL_DISPOSE_MIN ++ "=function(stack,error,hasError){var E=typeof SuppressedError===\"function\"?SuppressedError:function(e,s,m){var err=new Error(m);err.error=e;err.suppressed=s;return err};var fail=function(e){error=hasError?new E(e,error,\"An error was suppressed during disposal\"):(hasError=true,e)};var next=function(it){while(it=stack.pop()){try{var result=it[1]&&it[1].call(it[2]);if(it[0])return Promise.resolve(result).then(next,function(e){fail(e);return next()})}catch(e){fail(e)}}if(hasError)throw error};return next()};";

// ============================================================
// Spread Array (ES2015)
// ============================================================

/// __toConsumableArray: spread 배열 변환 (SWC 호환).
/// 배열이면 직접 복사, iterable이면 Array.from(), array-like면 수동 복사.
/// [...map.values()] → [].concat(__toConsumableArray(map.values()))
pub const SPREAD_ARRAY_RUNTIME =
    \\var __arrayLikeToArray = function(arr, len) {
    \\  if (len == null || len > arr.length) len = arr.length;
    \\  for (var i = 0, arr2 = new Array(len); i < len; i++) arr2[i] = arr[i];
    \\  return arr2;
    \\};
    \\var __toConsumableArray = function(arr) {
    \\  if (Array.isArray(arr)) return __arrayLikeToArray(arr);
    \\  if (typeof Symbol !== "undefined" && arr[Symbol.iterator] != null) return Array.from(arr);
    \\  if (arr && typeof arr.length === "number") return __arrayLikeToArray(arr);
    \\  throw new TypeError("Invalid attempt to spread non-iterable instance.");
    \\};
    \\
;
pub const SPREAD_ARRAY_RUNTIME_MIN =
    "var " ++ NAMES.ARRAY_LIKE_TO_ARRAY_MIN ++ "=function(arr,len){if(len==null||len>arr.length)len=arr.length;for(var i=0,arr2=new Array(len);i<len;i++)arr2[i]=arr[i];return arr2};" ++
    "var " ++ NAMES.TO_CONSUMABLE_ARRAY_MIN ++ "=function(arr){" ++
    "if(Array.isArray(arr))return " ++ NAMES.ARRAY_LIKE_TO_ARRAY_MIN ++ "(arr);" ++
    "if(typeof Symbol!==\"undefined\"&&arr[Symbol.iterator]!=null)return Array.from(arr);" ++
    "if(arr&&typeof arr.length===\"number\")return " ++ NAMES.ARRAY_LIKE_TO_ARRAY_MIN ++ "(arr);" ++
    "throw new TypeError(\"Invalid attempt to spread non-iterable instance.\")};";

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
    if (helpers.async_values) {
        try buf.appendSlice(allocator, if (minify) ASYNC_VALUES_RUNTIME_MIN else ASYNC_VALUES_RUNTIME);
    }
    // __values 는 yield* / for-of / __asyncValues fallback 모두 사용 — async_values 가 켜져 있으면
    // 그 안에서 typeof __values 체크하므로 함께 emit 필요.
    if (helpers.values or helpers.async_values) {
        try buf.appendSlice(allocator, if (minify) VALUES_RUNTIME_MIN else VALUES_RUNTIME);
    }
    // __await 는 async generator step() 안에서 instanceof check 사용 — async_generator 가
    // 켜져 있으면 함께 emit. (#1911)
    if (helpers.await_helper or helpers.async_generator) {
        try buf.appendSlice(allocator, if (minify) AWAIT_RUNTIME_MIN else AWAIT_RUNTIME);
    }
    if (helpers.async_generator) {
        try buf.appendSlice(allocator, if (minify) ASYNC_GENERATOR_RUNTIME_MIN else ASYNC_GENERATOR_RUNTIME);
    }
    if (helpers.to_binary) {
        try buf.appendSlice(allocator, if (minify) TO_BINARY_RUNTIME_MIN else TO_BINARY_RUNTIME);
    }
    if (helpers.wrap_regex) {
        try buf.appendSlice(allocator, if (minify) WRAP_REGEXP_RUNTIME_MIN else WRAP_REGEXP_RUNTIME);
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
    if (helpers.class_static_private_field) {
        try buf.appendSlice(allocator, if (minify) STATIC_PRIVATE_FIELD_RUNTIME_MIN else STATIC_PRIVATE_FIELD_RUNTIME);
    }
    if (helpers.class_private_field_set) {
        try buf.appendSlice(allocator, if (minify) PRIVATE_FIELD_SET_RUNTIME_MIN else PRIVATE_FIELD_SET_RUNTIME);
    }
    if (helpers.call_super) {
        try buf.appendSlice(allocator, if (minify) CALL_SUPER_RUNTIME_MIN else CALL_SUPER_RUNTIME);
    }
    if (helpers.super_get) {
        try buf.appendSlice(allocator, if (minify) SUPER_GET_RUNTIME_MIN else SUPER_GET_RUNTIME);
    }
    if (helpers.super_set) {
        try buf.appendSlice(allocator, if (minify) SUPER_SET_RUNTIME_MIN else SUPER_SET_RUNTIME);
    }
    if (helpers.derived_constructor) {
        try buf.appendSlice(allocator, if (minify) DERIVED_CONSTRUCTOR_RUNTIME_MIN else DERIVED_CONSTRUCTOR_RUNTIME);
    }
    if (helpers.tdz) {
        try buf.appendSlice(allocator, if (minify) TDZ_RUNTIME_MIN else TDZ_RUNTIME);
    }
    if (helpers.read) {
        try buf.appendSlice(allocator, if (minify) READ_RUNTIME_MIN else READ_RUNTIME);
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
    if (helpers.es_decorator) {
        try buf.appendSlice(allocator, if (minify) ES_DECORATOR_RUNTIME_MIN else ES_DECORATOR_RUNTIME);
    }
    if (helpers.legacy_decorator) {
        try buf.appendSlice(allocator, if (minify) DECORATOR_RUNTIME_MIN else DECORATOR_RUNTIME);
    }
    if (helpers.spread_array) {
        try buf.appendSlice(allocator, if (minify) SPREAD_ARRAY_RUNTIME_MIN else SPREAD_ARRAY_RUNTIME);
    }
}

/// __commonJS factory 만 주입. named-only CJS import (`require_xxx().name`) 는
/// __toESM 클러스터가 필요 없으므로, namespace/default import 가 없을 때 호출.
/// configurable=true(RN)이면 ES5 호환 버전 사용.
pub fn appendCommonJsFactoryRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool, configurable: bool) !void {
    if (minify) {
        try buf.appendSlice(allocator, if (configurable) CJS_RUNTIME_ES5_MIN else CJS_RUNTIME_MIN);
    } else {
        try buf.appendSlice(allocator, if (configurable) CJS_RUNTIME_ES5 else CJS_RUNTIME);
    }
}

/// ESM namespace interop 헬퍼 (__toESM 와 __copyProps/__defProp 등 Object.* 별칭).
pub fn appendToEsmRuntime(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, minify: bool, configurable: bool) !void {
    if (minify) {
        try buf.appendSlice(allocator, if (configurable) TOESM_RUNTIME_CONFIGURABLE_MIN else TOESM_RUNTIME_MIN);
    } else {
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
