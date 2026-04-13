var __commonJS = (cb, mod) => function __require() {
	return mod || (0, cb[Object.keys(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
};
var __create = Object.create;
var __getProtoOf = Object.getPrototypeOf;
var __defProp = Object.defineProperty;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __hasOwn = Object.prototype.hasOwnProperty;
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (var keys = __getOwnPropNames(from), i = 0, n = keys.length, key; i < n; i++) {
      key = keys[i];
      if (!__hasOwn.call(to, key) && key !== except)
        __defProp(to, key, { get: ((k) => from[k]).bind(null, key), enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
  }
  return to;
};
var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target, mod));
var __esm = (fn, res) => function __init() {
	if (!fn) return res;
	var f = fn; fn = 0;
	try { res = (0, f[Object.keys(f)[0]])(); }
	catch(e) { fn = f; throw e; }
	return res;
};
var __export = (target, all) => {
	for (var name in all)
		__defProp(target, name, { get: all[name], enumerable: true });
};
var __toCommonJS = mod => __hasOwn.call(mod, 'module.exports') ? mod['module.exports'] : __copyProps(__defProp({}, '__esModule', { value: true }), mod);
var __zts_modules = {};
var __zts_hot_cbs = {};
var __zts_hot_data = {};
var __zts_g = typeof globalThis !== "undefined" ? globalThis : typeof global !== "undefined" ? global : typeof window !== "undefined" ? window : this;
var __zts_reload = function() {
  if (typeof location !== "undefined") location.reload();
  else if (__zts_g.nativeModuleProxy && __zts_g.nativeModuleProxy.DevSettings) __zts_g.nativeModuleProxy.DevSettings.reload();
};
// react-refresh/runtime lazy resolve: 모듈 컨텍스트에서 require()로 로드 후 캐싱.
function __zts_resolveRefresh() {
  if (__zts_g.__ReactRefresh) return __zts_g.__ReactRefresh;
  try { var r = require("react-refresh/runtime"); __zts_g.__ReactRefresh = r; __zts_g.__REACT_REFRESH_RUNTIME__ = r; return r; } catch(e) {}
  return null;
}
// isReactRefreshBoundary: 모든 export가 React 컴포넌트면 true.
// mixed export 모듈은 HMR 대상에서 제외 → full reload.
function __zts_isReactRefreshBoundary(moduleExports) {
  var rt = __zts_g.__ReactRefresh || __zts_resolveRefresh();
  if (!rt) return false;
  if (rt.isLikelyComponentType(moduleExports)) return true;
  if (moduleExports == null || typeof moduleExports !== "object") return false;
  var hasExports = false;
  for (var key in moduleExports) {
    if (key === "__esModule") continue;
    hasExports = true;
    if (!rt.isLikelyComponentType(moduleExports[key])) return false;
  }
  return hasExports;
}
// enqueueUpdate: 50ms debounce로 performReactRefresh 배칭.
// 여러 모듈 업데이트를 한 번의 React refresh 사이클로 처리.
var __zts_refreshTimer;
function __zts_enqueueUpdate() {
  if (__zts_refreshTimer != null) return;
  __zts_refreshTimer = setTimeout(function() {
    __zts_refreshTimer = null;
    var rt = __zts_g.__ReactRefresh || __zts_resolveRefresh();
    if (rt) rt.performReactRefresh();
  }, 50);
}
function __zts_make_hot(id) {
  if (!__zts_hot_cbs[id]) __zts_hot_cbs[id] = {};
  return {
    get data() { return __zts_hot_data[id]; },
    accept: function(deps, cb) {
      if (typeof deps === "function") { cb = deps; deps = undefined; }
      __zts_hot_cbs[id].accept = cb || true;
      if (Array.isArray(deps)) __zts_hot_cbs[id].acceptDeps = deps;
    },
    dispose: function(cb) { __zts_hot_cbs[id].dispose = cb; },
    prune: function(cb) { __zts_hot_cbs[id].prune = cb; },
    invalidate: function() { __zts_reload(); },
    get refresh() { return __zts_g.__ReactRefresh || __zts_resolveRefresh(); },
    refreshUtils: {
      isReactRefreshBoundary: __zts_isReactRefreshBoundary,
      enqueueUpdate: __zts_enqueueUpdate
    }
  };
}
// __commonJS/__esm HMR 래핑: 모듈을 __zts_modules에 자동 등록.
// 기존 __commonJS/__esm을 래핑하여 reset 기능 추가.
var __zts_orig_commonJS = typeof __commonJS !== "undefined" ? __commonJS : null;
var __zts_orig_esm = typeof __esm !== "undefined" ? __esm : null;
if (__zts_orig_commonJS) __commonJS = function(cb, mod) {
  var id = Object.keys(cb)[0];
  var fn = __zts_orig_commonJS(cb, mod);
  __zts_modules[id] = { type: "cjs", fn: fn, reset: function() {
    fn = __zts_orig_commonJS(cb);
    __zts_modules[id].fn = fn;
  }};
  return fn;
};
if (__zts_orig_esm) __esm = function(fn, res, exportsObj) {
  var id = Object.keys(fn)[0];
  var init = __zts_orig_esm(fn, res);
  __zts_modules[id] = { type: "esm", fn: init, exports: exportsObj, reset: function() {
    init = __zts_orig_esm(fn);
    __zts_modules[id].fn = init;
  }};
  return init;
};
// HMR 업데이트: globalEvalWithSourceUrl (RN) 또는 indirect eval (브라우저).
// per-module IIFE에 런타임 헬퍼 로컬 alias가 포함되므로 파라미터 전달 불필요.
function __zts_apply_update(updates) {
  for (var i = 0; i < updates.length; i++) {
    var id = updates[i].id;
    var cbs = __zts_hot_cbs[id];
    if (!cbs || !cbs.accept) { __zts_reload(); return; }
    try {
      if (cbs.dispose) {
        __zts_hot_data[id] = {};
        cbs.dispose(__zts_hot_data[id]);
      }
      var evalFn = __zts_g.globalEvalWithSourceUrl;
      if (evalFn) {
        evalFn(updates[i].code, "hmr-update:" + id);
      } else {
        (0, eval)(updates[i].code);
      }
      // eval은 __esm factory를 등록만 함 — fn()을 호출해야 모듈 본문 실행 + $RefreshReg$ 트리거
      var entry = __zts_modules[id];
      if (entry && entry.fn) entry.fn();
      if (typeof cbs.accept === "function") {
        cbs.accept(entry && entry.exports ? entry.exports : {});
      }
    } catch(e) { console.error("[zts] HMR update failed:", e); __zts_reload(); }
  }
}
// 글로벌 $RefreshReg$/$RefreshSig$ fallback (noop).
// 실제 등록은 emitter가 모듈별로 save/restore 패턴을 주입하여 처리.
__zts_g.$RefreshReg$ = function() {};
__zts_g.$RefreshSig$ = function() { return function(type) { return type; }; };
// HMR API + 런타임 헬퍼를 전역에 노출 (모듈 스코프에서 eval 접근용)
__zts_g.__zts_apply_update = __zts_apply_update;
__zts_g.__zts_reload = __zts_reload;
__zts_g.__zts_make_hot = __zts_make_hot;
__zts_g.__zts_modules = __zts_modules;
__zts_g.__zts_resolveRefresh = __zts_resolveRefresh;
__zts_g.__zts_isReactRefreshBoundary = __zts_isReactRefreshBoundary;
__zts_g.__zts_enqueueUpdate = __zts_enqueueUpdate;
if (typeof __esm !== "undefined") __zts_g.__esm = __esm;
if (typeof __export !== "undefined") __zts_g.__export = __export;
if (typeof __commonJS !== "undefined") __zts_g.__commonJS = __commonJS;
if (typeof __defProp !== "undefined") __zts_g.__defProp = __defProp;
if (typeof __toESM !== "undefined") __zts_g.__toESM = __toESM;
if (typeof __toCommonJS !== "undefined") __zts_g.__toCommonJS = __toCommonJS;
// --- a.ts ---
var exports_a = {};
var A;
__export(exports_a, {
	A: () => A,
});
var init_a = __esm({
	"/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/zts-hmr-partial-C95gwn/a.ts"() {
	A = "A-changed";
	
	}
}, void 0, exports_a);

// --- b.ts ---
var exports_b = {};
var B;
__export(exports_b, {
	B: () => B,
});
var init_b = __esm({
	"/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/zts-hmr-partial-C95gwn/b.ts"() {
	B = "B-changed";
	
	}
}, void 0, exports_b);

// --- entry.ts ---
var exports_entry = {};
var init_entry = __esm({
	"/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/zts-hmr-partial-C95gwn/entry.ts"() {
	__zts_modules["/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/zts-hmr-partial-C95gwn/a.ts"].fn();
	__zts_modules["/private/var/folders/51/mr5cjhg13v324f1vgg9m237c0000gn/T/zts-hmr-partial-C95gwn/b.ts"].fn();
		
	
	console.log(A, B);
	
	}
}, void 0, exports_entry);

init_entry();
//# sourceMappingURL=/bundle.js.map
