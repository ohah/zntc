//! ZTS Bundler — Emitter
//!
//! 모듈 그래프의 모듈들을 exec_index 순서로 변환+코드젠하여
//! 단일 파일 번들로 출력한다.
//!
//! 책임:
//!   - exec_index 순서 정렬
//!   - 각 모듈: Transformer → Codegen
//!   - 포맷별 래핑 (ESM/CJS/IIFE)
//!   - import/export 처리는 linker(별도 PR)에서 담당
//!
//! 설계:
//!   - Rollup 방식: emitter(finaliser)와 linker 분리 (유지보수 우선)
//!   - D058: exec_index 순서 = ESM 실행 순서

const std = @import("std");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
const ModuleType = types.ModuleType;
const WrapKind = types.WrapKind;

/// CJS 런타임 헬퍼: __commonJS 팩토리 함수 (esbuild 호환)
const CJS_RUNTIME = "var __commonJS = (cb, mod) => function __require() {\n\treturn mod || (0, cb[Object.keys(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;\n};\n";
const CJS_RUNTIME_MIN = "var __commonJS=(cb,mod)=>function __require(){return mod||(0,cb[Object.keys(cb)[0]])((mod={exports:{}}).exports,mod),mod.exports};";

/// __toESM 런타임 헬퍼: CJS 모듈을 ESM namespace로 변환 (esbuild/rolldown 호환).
/// isNodeMode=true(--platform=node)이면 항상 default: mod를 설정.
/// __esModule=true이면 원본 프로퍼티를 사용하되 default는 추가하지 않음.
/// 참고: references/esbuild/internal/runtime/runtime.go:231
///       references/rolldown/crates/rolldown/src/runtime/index.js:86
const TOESM_RUNTIME =
    \\var __getProtoOf = Object.getPrototypeOf;
    \\var __defProp = Object.defineProperty;
    \\var __hasOwn = Object.prototype.hasOwnProperty;
    \\var __copyProps = (to, from) => { for (let key in from) if (__hasOwn.call(from, key) && !__hasOwn.call(to, key)) __defProp(to, key, { get: () => from[key], enumerable: true }); return to; };
    \\var __toESM = (mod, isNodeMode, target) => (target = mod != null ? Object.create(__getProtoOf(mod)) : {}, __copyProps(isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target, mod));
    \\
;
const TOESM_RUNTIME_MIN = "var __getProtoOf=Object.getPrototypeOf;var __defProp=Object.defineProperty;var __hasOwn=Object.prototype.hasOwnProperty;var __copyProps=(to,from)=>{for(let key in from)if(__hasOwn.call(from,key)&&!__hasOwn.call(to,key))__defProp(to,key,{get:()=>from[key],enumerable:true});return to};var __toESM=(mod,isNodeMode,target)=>(target=mod!=null?Object.create(__getProtoOf(mod)):{},__copyProps(isNodeMode||!mod||!mod.__esModule?__defProp(target,\"default\",{value:mod,enumerable:true}):target,mod));";
/// __decorateClass 런타임 헬퍼: experimental decorators 변환 시 주입 (esbuild 호환).
/// __defProp은 __toESM 런타임에도 있지만, decorator 단독 사용 시를 위해 별도 선언.
const DECORATOR_RUNTIME =
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
const DECORATOR_RUNTIME_MIN = "var __defProp2=Object.defineProperty;var __getOwnPropDesc=Object.getOwnPropertyDescriptor;var __decorateClass=(decorators,target,key,kind)=>{var result=kind>1?void 0:kind?__getOwnPropDesc(target,key):target;for(var i=decorators.length-1,decorator;i>=0;i--)if(decorator=decorators[i])result=(kind?decorator(target,key,result):decorator(result))||result;if(kind&&result)__defProp2(target,key,result);return result};var __decorateParam=(index,decorator)=>(target,key)=>decorator(target,key,index);";

/// __async 런타임 헬퍼: async/await → generator 변환 시 주입 (esbuild 호환).
/// generator-to-Promise wrapper. this/arguments를 fn.apply로 보존.
///
/// 스펙 참고: esbuild internal/runtime/runtime.go __async
const ASYNC_RUNTIME =
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
const ASYNC_RUNTIME_MIN = "var __async=(fn)=>function(...args){return new Promise((resolve,reject)=>{var gen=fn.apply(this,args);function step(key,arg){try{var info=gen[key](arg);var value=info.value}catch(error){reject(error);return}if(info.done)resolve(value);else Promise.resolve(value).then(val=>step(\"next\",val),err=>step(\"throw\",err))}step(\"next\")})};";

/// HMR 런타임: 모듈 레지스트리 + __zts_require + import.meta.hot API.
/// dev mode 번들 상단에 주입된다.
///
/// 구조:
///   __zts_modules[id] = { factory, exports, hot }
///   __zts_require(id) → 모듈의 exports 반환
///   __zts_make_hot(id) → import.meta.hot 호환 API 객체
///   __zts_apply_update(id, code) → 모듈 재실행 (WS에서 호출)
const HMR_RUNTIME =
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

const HMR_RUNTIME_MIN =
    \\var __zts_modules={},__zts_hot_cbs={},__zts_hot_data={};function __zts_require(id){var m=__zts_modules[id];if(!m)throw new Error("[zts] Module not found: "+id);return m.exports}function __zts_make_hot(id){if(!__zts_hot_cbs[id])__zts_hot_cbs[id]={};return{get data(){return __zts_hot_data[id]},accept:function(d,c){if(typeof d==="function"){c=d;d=void 0}__zts_hot_cbs[id].accept=c||true;if(Array.isArray(d))__zts_hot_cbs[id].acceptDeps=d},dispose:function(c){__zts_hot_cbs[id].dispose=c},prune:function(c){__zts_hot_cbs[id].prune=c},invalidate:function(){location.reload()}}}function __zts_register(id,f){var p=__zts_modules[id];var m={exports:{},hot:__zts_make_hot(id),factory:f};__zts_modules[id]=m;f(m,m.exports);if(p){var c=__zts_hot_cbs[id];if(c&&c.dispose){__zts_hot_data[id]={};c.dispose(__zts_hot_data[id])}}}function __zts_apply_update(u){for(var i=0;i<u.length;i++){var id=u[i].id;var c=__zts_hot_cbs[id];if(!c||!c.accept){location.reload();return}try{var fn=new Function("__zts_register","__zts_require","__zts_make_hot",u[i].code);fn(__zts_register,__zts_require,__zts_make_hot);if(typeof c.accept==="function")c.accept()}catch(e){console.error("[zts] HMR update failed:",e);location.reload()}}}
;

const chunk_mod = @import("chunk.zig");
const ChunkGraph = chunk_mod.ChunkGraph;
const Chunk = chunk_mod.Chunk;
const ChunkIndex = types.ChunkIndex;
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const Ast = @import("../parser/ast.zig").Ast;
const Transformer = @import("../transformer/transformer.zig").Transformer;
const Codegen = @import("../codegen/codegen.zig").Codegen;
const CodegenOptions = @import("../codegen/codegen.zig").CodegenOptions;
const SourceMap = @import("../codegen/sourcemap.zig");
const Linker = @import("linker.zig").Linker;
const LinkingMetadata = @import("linker.zig").LinkingMetadata;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const statement_shaker = @import("statement_shaker.zig");
const stmt_info_mod = @import("stmt_info.zig");
const ExportBinding = @import("binding_scanner.zig").ExportBinding;

pub const EmitOptions = struct {
    format: Format = .esm,
    minify_whitespace: bool = false,
    minify_identifiers: bool = false,
    /// 소스맵 생성 활성화. dev mode에서는 번들 레벨 소스맵을 생성한다.
    sourcemap: bool = false,
    /// dev mode: 각 모듈을 __zts_register() 팩토리로 래핑하고
    /// HMR 런타임을 주입한다. import.meta.hot API 지원.
    dev_mode: bool = false,
    /// dev mode에서 모듈 ID 생성 시 기준 경로 (상대 경로 계산용).
    /// null이면 절대 경로를 그대로 사용.
    root_dir: ?[]const u8 = null,
    /// React Fast Refresh 활성화. $RefreshReg$/$RefreshSig$ 주입.
    react_refresh: bool = false,
    /// define 글로벌 치환 (--define:KEY=VALUE)
    define: []const @import("../transformer/transformer.zig").DefineEntry = &.{},
    /// legacy decorator 변환
    experimental_decorators: bool = false,
    /// useDefineForClassFields=false
    use_define_for_class_fields: bool = true,
    /// ES 타겟 레벨
    target: @import("../transformer/transformer.zig").TransformOptions.Target = .esnext,
    /// 타겟 플랫폼. import.meta polyfill 방식을 결정한다.
    platform: @import("../codegen/codegen.zig").Platform = .browser,

    pub const Format = enum {
        esm,
        cjs,
        iife,
    };
};

pub const OutputFile = struct {
    path: []const u8,
    contents: []const u8,
};

/// 모듈 그래프를 단일 번들로 출력한다.
/// 반환된 contents는 allocator 소유 (caller가 free).
pub fn emit(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
) ![]const u8 {
    return emitWithTreeShaking(allocator, graph, options, linker, null);
}

/// tree-shaking 적용된 번들 출력. shaker가 null이면 모든 모듈 포함 (기존 동작).
pub fn emitWithTreeShaking(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
    shaker: ?*const TreeShaker,
) ![]const u8 {
    // 1. JS/JSON 모듈 필터 + exec_index 순으로 정렬
    var sorted: std.ArrayList(*const Module) = .empty;
    defer sorted.deinit(allocator);

    for (graph.modules.items, 0..) |*m, i| {
        const is_js = m.module_type == .javascript and (m.ast != null or m.is_disabled);
        const is_json = m.module_type == .json;
        if (is_js or is_json) {
            // tree-shaking: 미포함 모듈 스킵
            if (shaker) |s| {
                if (!s.isIncluded(@intCast(i))) continue;
            }
            try sorted.append(allocator, m);
        }
    }

    std.mem.sort(*const Module, sorted.items, {}, struct {
        fn lessThan(_: void, a: *const Module, b: *const Module) bool {
            return a.exec_index < b.exec_index;
        }
    }.lessThan);

    // 2. 각 모듈을 변환 + 코드젠
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // 포맷별 prologue
    switch (options.format) {
        .iife => try output.appendSlice(allocator, "(function() {\n"),
        .cjs => try output.appendSlice(allocator, "\"use strict\";\n"),
        .esm => {},
    }

    // CJS 런타임 헬퍼 주입: CJS 래핑 모듈이 하나라도 있으면 주입
    var needs_cjs_runtime = false;
    for (sorted.items) |m| {
        if (m.wrap_kind == .cjs) {
            needs_cjs_runtime = true;
            break;
        }
    }
    if (needs_cjs_runtime) {
        if (options.minify_whitespace) {
            try output.appendSlice(allocator, CJS_RUNTIME_MIN);
            try output.appendSlice(allocator, TOESM_RUNTIME_MIN);
        } else {
            try output.appendSlice(allocator, CJS_RUNTIME);
            try output.appendSlice(allocator, TOESM_RUNTIME);
        }
    }

    // Decorator 런타임 주입: experimental decorators 사용 시
    if (options.experimental_decorators) {
        if (options.minify_whitespace) {
            try output.appendSlice(allocator, DECORATOR_RUNTIME_MIN);
        } else {
            try output.appendSlice(allocator, DECORATOR_RUNTIME);
        }
    }

    // Async 런타임 주입: target < es2017 시
    if (options.target.needsAsyncAwait()) {
        if (options.minify_whitespace) {
            try output.appendSlice(allocator, ASYNC_RUNTIME_MIN);
        } else {
            try output.appendSlice(allocator, ASYNC_RUNTIME);
        }
    }

    // TLA 검증: 비-ESM 출력에서 TLA 사용 시 경고 주석 삽입.
    // Top-Level Await는 ESM 전용 기능이므로 CJS/IIFE 포맷에서는 동작하지 않는다.
    // DFS로 exec_index가 부여된 모듈만 확인한다 — 동적 import로만 도달하는 모듈은
    // exec_index가 maxInt(u32)이며, 비동기 로딩이므로 경고 불필요.
    if (options.format != .esm) {
        for (sorted.items) |m| {
            if (m.uses_top_level_await and m.exec_index != std.math.maxInt(u32)) {
                try output.appendSlice(allocator, "/* [ZTS WARNING] Top-level await requires ESM output format. */\n");
                break;
            }
        }
    }

    // ESM 출력 + external: esbuild와 동일하게 require() preamble만 사용.
    // import 구문이 없으면 Node가 CJS로 파싱하여 require()가 동작한다.
    // (createRequire shim은 ESM 파싱을 유발하여 var 재선언 에러를 일으킴)

    // 엔트리 모듈 인덱스 (final exports용)
    const entry_idx: ?u32 = if (sorted.items.len > 0)
        @intFromEnum(sorted.items[sorted.items.len - 1].index)
    else
        null;

    for (sorted.items) |m| {
        const is_entry = if (entry_idx) |ei| @intFromEnum(m.index) == ei else false;

        // statement-level tree-shaking: used export names 계산
        var names_buf: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names_buf.deinit(allocator);
        const used_names: ?[]const []const u8 = if (shaker) |s| blk: {
            const mod_idx: u32 = @intFromEnum(m.index);
            // "*" 마킹이 있어도 BFS reachable_stmts로 정밀 필터링 가능하면 사용
            if (s.isExportUsed(mod_idx, "*") and s.getModuleStmtInfos(mod_idx) == null)
                break :blk null;
            for (m.export_bindings) |eb| {
                if (eb.kind == .re_export_all) continue;
                if (!s.isExportUsed(mod_idx, eb.exported_name)) continue;

                // 크로스-모듈 BFS 도달성: export의 선언 statement가 unreachable이면 제외
                if (s.getModuleStmtInfos(mod_idx)) |ts_infos| {
                    if (m.semantic) |sem| {
                        if (sem.scope_maps.len > 0) {
                            if (sem.scope_maps[0].get(eb.local_name)) |sym_idx| {
                                if (ts_infos.declaredStmtBySymbol(@intCast(sym_idx))) |stmt_idx| {
                                    if (!s.isStmtReachable(mod_idx, stmt_idx)) continue;
                                }
                            }
                        }
                    }
                }

                // StmtInfo 도달성: 모든 importer에서 이 export의 import가 dead이면 제외.
                if (eb.kind == .local and m.importers.items.len > 0) {
                    const is_dead = is_dead: {
                        var found_any = false;
                        for (m.importers.items) |importer_idx| {
                            const imp_i = @intFromEnum(importer_idx);
                            if (imp_i >= graph.modules.items.len) break :is_dead false;
                            const importer = &graph.modules.items[imp_i];
                            // re-export 경유 모듈은 보수적으로 live
                            // export * from './mod' 또는 export { x } from './mod'
                            for (importer.export_bindings) |ieb| {
                                if (ieb.kind == .re_export_all or ieb.kind == .re_export) {
                                    if (ieb.import_record_index) |rec_idx| {
                                        if (rec_idx < importer.import_records.len and
                                            importer.import_records[rec_idx].resolved == m.index)
                                        {
                                            // named re-export: 해당 이름이 매칭되는지 확인
                                            if (ieb.kind == .re_export) {
                                                if (std.mem.eql(u8, ieb.local_name, eb.exported_name))
                                                    break :is_dead false;
                                            } else {
                                                break :is_dead false;
                                            }
                                        }
                                    }
                                }
                            }
                            for (importer.import_bindings) |ib| {
                                if (ib.import_record_index >= importer.import_records.len) continue;
                                if (importer.import_records[ib.import_record_index].resolved != m.index) continue;
                                if (!std.mem.eql(u8, ib.imported_name, eb.exported_name)) continue;
                                found_any = true;
                                if (s.isImportLiveInModule(@intCast(imp_i), ib.local_name))
                                    break :is_dead false;
                            }
                        }
                        break :is_dead found_any;
                    };
                    if (is_dead) continue;
                }

                names_buf.append(allocator, eb.local_name) catch break :blk null;
                if (!std.mem.eql(u8, eb.exported_name, eb.local_name)) {
                    names_buf.append(allocator, eb.exported_name) catch break :blk null;
                }
            }
            // cross-module: 이 모듈을 import하는 모듈의 named binding도 포함
            // StmtInfo 도달성으로 dead import는 제외
            for (m.importers.items) |importer_idx| {
                const imp_i = @intFromEnum(importer_idx);
                if (imp_i >= graph.modules.items.len) continue;
                const importer = &graph.modules.items[imp_i];
                // export * as ns from './mod': 이 모듈의 모든 export를 사용
                for (importer.export_bindings) |eb| {
                    if (eb.kind == .re_export_all and !std.mem.eql(u8, eb.exported_name, "*")) {
                        if (eb.import_record_index) |rec_idx| {
                            if (rec_idx < importer.import_records.len and
                                importer.import_records[rec_idx].resolved == m.index)
                                break :blk null;
                        }
                    }
                }
                for (importer.import_bindings) |ib| {
                    if (ib.kind != .named) continue;
                    if (ib.import_record_index >= importer.import_records.len) continue;
                    if (importer.import_records[ib.import_record_index].resolved != m.index) continue;
                    if (shaker) |sk| {
                        if (!sk.isImportLiveInModule(@intCast(imp_i), ib.local_name)) continue;
                    }
                    names_buf.append(allocator, ib.imported_name) catch break :blk null;
                }
            }
            break :blk names_buf.items;
        } else null;

        const code = try emitModule(allocator, m, options, linker, is_entry, used_names, shaker) orelse continue;
        defer allocator.free(code);

        if (!options.minify_whitespace) {
            // 모듈 경계 주석 (디버깅용)
            try output.appendSlice(allocator, "// --- ");
            try output.appendSlice(allocator, std.fs.path.basename(m.path));
            try output.appendSlice(allocator, " ---\n");
        }

        try output.appendSlice(allocator, code);
        if (!options.minify_whitespace) {
            try output.append(allocator, '\n');
        }
    }

    // 포맷별 epilogue
    switch (options.format) {
        .iife => try output.appendSlice(allocator, "})();\n"),
        .cjs, .esm => {},
    }

    return output.toOwnedSlice(allocator);
}

/// Dev mode 번들 출력.
///
/// 각 모듈을 `__zts_register(id, factory)` 팩토리로 래핑하고
/// HMR 런타임을 번들 상단에 주입한다.
/// 스코프 호이스팅 대신 모듈 레지스트리 기반 import/export를 사용.
///
/// 출력 형태:
/// ```js
/// // HMR Runtime
/// var __zts_modules = {}; ...
///
/// // Module: ./src/utils.ts
/// __zts_register("./src/utils.ts", function(__zts_module, __zts_exports) {
///   var { add } = __zts_require("./src/math.ts");
///   const result = add(1, 2);
///   __zts_exports.result = result;
/// });
/// ```
/// Dev mode 번들 결과. 전체 번들 + per-module codes + 소스맵을 한 번의 transform 패스로 생성.
pub const DevBundleResult = struct {
    /// 전체 번들 출력 (HMR 런타임 + 모든 모듈 __zts_register). allocator 소유.
    output: []const u8,
    /// 모듈별 __zts_register() 코드. HMR 모듈 단위 업데이트용. allocator 소유.
    module_codes: []const ModuleDevCode,
    /// 번들 소스맵 JSON (V3). null이면 소스맵 미생성. allocator 소유.
    sourcemap: ?[]const u8 = null,

    pub const ModuleDevCode = struct {
        id: []const u8,
        code: []const u8,
    };

    pub fn deinitCodes(codes: []const ModuleDevCode, allocator: std.mem.Allocator) void {
        for (codes) |c| {
            allocator.free(c.id);
            allocator.free(c.code);
        }
        allocator.free(codes);
    }
};

pub fn emitDevBundle(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    options: EmitOptions,
    linker: ?*const Linker,
) !DevBundleResult {
    // 1. JS/JSON 모듈 필터 + exec_index 순 정렬
    var sorted: std.ArrayList(*const Module) = .empty;
    defer sorted.deinit(allocator);

    for (graph.modules.items) |*m| {
        if ((m.module_type == .javascript and (m.ast != null or m.is_disabled)) or m.module_type == .json) {
            try sorted.append(allocator, m);
        }
    }

    std.mem.sort(*const Module, sorted.items, {}, struct {
        fn lessThan(_: void, a: *const Module, b: *const Module) bool {
            return a.exec_index < b.exec_index;
        }
    }.lessThan);

    // 2. 출력 빌드
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // HMR 런타임 주입
    if (options.minify_whitespace) {
        try output.appendSlice(allocator, HMR_RUNTIME_MIN);
    } else {
        try output.appendSlice(allocator, HMR_RUNTIME);
    }

    // per-module codes 수집 (한 번의 transform 패스에서 동시 생성)
    var module_codes: std.ArrayList(DevBundleResult.ModuleDevCode) = .empty;
    errdefer {
        for (module_codes.items) |c| {
            allocator.free(c.id);
            allocator.free(c.code);
        }
        module_codes.deinit(allocator);
    }

    // 번들 레벨 소스맵 빌더 (소스맵 활성화 시)
    var bundle_sm: ?SourceMap.SourceMapBuilder = if (options.sourcemap)
        SourceMap.SourceMapBuilder.init(allocator)
    else
        null;
    defer if (bundle_sm) |*sm| sm.deinit();

    // HMR 런타임의 줄 수 (comptime 상수)
    const hmr_runtime_lines = comptime blk: {
        @setEvalBranchQuota(10000);
        break :blk @as(u32, std.mem.count(u8, HMR_RUNTIME, "\n"));
    };

    // 현재 번들 출력의 줄 번호 추적 (소스맵 오프셋용)
    var bundle_line: u32 = if (!options.minify_whitespace) hmr_runtime_lines else 1;

    // 3. 각 모듈을 __zts_register로 래핑
    for (sorted.items) |m| {
        const module_id = makeModuleId(m.path, options.root_dir);
        const emit_result = try emitDevModule(allocator, m, options, linker) orelse continue;
        defer allocator.free(emit_result.code);
        defer if (emit_result.mappings) |maps| allocator.free(maps);

        // __zts_register 래핑 코드 생성
        const wrapped = try wrapWithRegister(allocator, module_id, emit_result.code, options.minify_whitespace);
        errdefer allocator.free(wrapped);

        // per-module code 저장
        try module_codes.append(allocator, .{
            .id = try allocator.dupe(u8, module_id),
            .code = try allocator.dupe(u8, wrapped),
        });

        // 번들에 추가
        if (!options.minify_whitespace) {
            try output.appendSlice(allocator, "// --- ");
            try output.appendSlice(allocator, std.fs.path.basename(m.path));
            try output.appendSlice(allocator, " ---\n");
            bundle_line += 1; // comment line
        }
        try output.appendSlice(allocator, wrapped);

        // 소스맵: 모듈 매핑을 번들 오프셋으로 조정하여 추가
        if (bundle_sm) |*sm| {
            if (emit_result.mappings) |maps| {
                const source_idx = try sm.addSource(module_id);
                // __zts_register header는 1줄 ("__zts_register(..., function(...) {\n")
                const wrapper_header_lines: u32 = 1;
                // preamble(__zts_require 줄)은 mapping.generated_line에 포함되어 있으므로
                // 별도 offset 불필요 — emitDevModule이 preamble+code를 concat한 후 codegen 생성.

                for (maps) |mapping| {
                    try sm.addMapping(.{
                        .generated_line = bundle_line + wrapper_header_lines + mapping.generated_line,
                        .generated_column = if (mapping.generated_line == 0)
                            mapping.generated_column
                        else
                            mapping.generated_column + 1, // tab 들여쓰기 오프셋
                        .source_index = source_idx,
                        .original_line = mapping.original_line,
                        .original_column = mapping.original_column,
                    });
                }
            }
        }

        // 번들 줄 번호 추적
        bundle_line += @intCast(std.mem.count(u8, wrapped, "\n"));
        allocator.free(wrapped);
        if (!options.minify_whitespace) {
            bundle_line += 1; // trailing newline
            try output.append(allocator, '\n');
        }
    }

    // 소스맵 JSON 생성
    var sourcemap_json: ?[]const u8 = null;
    if (bundle_sm) |*sm| {
        const json = try sm.generateJSON("bundle.js");
        sourcemap_json = try allocator.dupe(u8, json);
    }

    // 소스맵 참조 추가
    if (sourcemap_json != null) {
        try output.appendSlice(allocator, "//# sourceMappingURL=/bundle.js.map\n");
    }

    return .{
        .output = try output.toOwnedSlice(allocator),
        .module_codes = try module_codes.toOwnedSlice(allocator),
        .sourcemap = sourcemap_json,
    };
}

/// __zts_register("id", function(...) { code }) 래핑 코드를 생성한다.
/// emitDevBundle과 외부에서 공용으로 사용.
pub fn wrapWithRegister(
    allocator: std.mem.Allocator,
    module_id: []const u8,
    code: []const u8,
    minify: bool,
) ![]const u8 {
    var wrapped: std.ArrayList(u8) = .empty;
    errdefer wrapped.deinit(allocator);

    try wrapped.appendSlice(allocator, "__zts_register(\"");
    try wrapped.appendSlice(allocator, module_id);

    if (minify) {
        try wrapped.appendSlice(allocator, "\",function(__zts_module,__zts_exports){");
        try wrapped.appendSlice(allocator, code);
        try wrapped.appendSlice(allocator, "});");
    } else {
        try wrapped.appendSlice(allocator, "\", function(__zts_module, __zts_exports) {\n");
        // 모듈 코드 들여쓰기
        var rest: []const u8 = code;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try wrapped.appendSlice(allocator, rest[0 .. nl + 1]);
            try wrapped.append(allocator, '\t');
            rest = rest[nl + 1 ..];
        }
        try wrapped.appendSlice(allocator, rest);
        try wrapped.appendSlice(allocator, "\n});");
    }

    return wrapped.toOwnedSlice(allocator);
}

/// Dev mode 단일 모듈 emit 결과.
pub const DevModuleEmitResult = struct {
    code: []const u8,
    /// 소스맵 매핑 (소스맵 활성화 시). generated_line/col은 code 기준 (오프셋 미적용).
    mappings: ?[]const SourceMap.Mapping = null,
};

/// Dev mode용 단일 모듈 변환.
/// 프로덕션 emitModule과의 차이:
///   - buildDevMetadataForAst 사용 (rename 없음, __zts_require preamble)
///   - final_exports → __zts_exports.x = x; 형태
pub fn emitDevModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: EmitOptions,
    linker: ?*const Linker,
) !?DevModuleEmitResult {
    const ast = &(module.ast orelse return null);

    var emit_arena = std.heap.ArenaAllocator.init(allocator);
    defer emit_arena.deinit();
    const arena_alloc = emit_arena.allocator();

    var transformer = Transformer.init(arena_alloc, ast, .{
        .react_refresh = options.react_refresh,
        .define = options.define,
        .experimental_decorators = options.experimental_decorators,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .target = options.target,
    });
    if (module.semantic) |sem| {
        transformer.old_symbol_ids = sem.symbol_ids;
    }
    const root = try transformer.transform();

    // Dev mode 메타데이터: rename 없음, __zts_require preamble, __zts_exports epilogue
    var metadata: ?LinkingMetadata = null;
    defer if (metadata) |*md| md.deinit();

    if (linker) |l| {
        var md = try l.buildDevMetadataForAst(
            &transformer.new_ast,
            @intFromEnum(module.index),
        );
        if (transformer.new_symbol_ids.items.len > 0) {
            md.symbol_ids = transformer.new_symbol_ids.items;
        }
        metadata = md;
    }

    // propagateCrossModulePurity 생략: dev mode에서는 tree-shaking이 꺼져 있으므로
    // @__NO_SIDE_EFFECTS__ cross-module 전파가 불필요하다.

    var cg = Codegen.initWithOptions(arena_alloc, &transformer.new_ast, .{
        .minify = options.minify_whitespace,
        .module_format = .esm,
        .sourcemap = options.sourcemap,
        .linking_metadata = if (metadata) |*md| md else null,
        .platform = options.platform,
    });
    // 소스맵용: line_offsets와 소스 파일 등록
    if (options.sourcemap) {
        cg.line_offsets = module.line_offsets;
        try cg.addSourceFile(makeModuleId(module.path, options.root_dir));
    }
    const code = try cg.generate(root);

    // 소스맵 매핑 복사 (arena 해제 전에)
    var mappings: ?[]SourceMap.Mapping = null;
    if (cg.sm_builder) |*sm| {
        if (sm.mappings.items.len > 0) {
            mappings = try allocator.dupe(SourceMap.Mapping, sm.mappings.items);
        }
    }

    // preamble (__zts_require) + code + epilogue (__zts_exports)
    const preamble = if (metadata) |md| md.cjs_import_preamble else null;
    const final_exports = if (metadata) |md| md.final_exports else null;

    // React Fast Refresh: 컴포넌트가 있는 모듈에 hot.accept() 자동 삽입
    const has_refresh = options.react_refresh and std.mem.indexOf(u8, code, "$RefreshReg$") != null;
    const hot_accept_suffix: []const u8 = if (has_refresh) "\n__zts_module.hot.accept();\n" else "";

    const needs_concat = preamble != null or final_exports != null or has_refresh;
    const final_code = if (needs_concat)
        try std.mem.concat(allocator, u8, &.{
            preamble orelse "",
            code,
            final_exports orelse "",
            hot_accept_suffix,
        })
    else
        try allocator.dupe(u8, code);

    return .{
        .code = final_code,
        .mappings = mappings,
    };
}

/// 모듈 경로를 dev bundle용 ID로 변환.
/// root_dir이 있으면 상대 경로, 없으면 절대 경로 그대로 사용.
pub fn makeModuleId(path: []const u8, root_dir: ?[]const u8) []const u8 {
    const root = root_dir orelse return path;
    if (root.len == 0) return path;

    // root_dir prefix를 제거하여 상대 경로 생성
    if (std.mem.startsWith(u8, path, root)) {
        var rel = path[root.len..];
        // 선행 '/' 제거
        if (rel.len > 0 and rel[0] == '/') rel = rel[1..];
        if (rel.len > 0) return rel;
    }
    return path;
}

/// 청크 그래프를 기반으로 다중 출력 파일을 생성한다 (code splitting).
///
/// 각 청크마다 하나의 OutputFile을 생성:
///   1. 크로스 청크 의존성에 대한 side-effect import 문 삽입 (실행 순서 보장)
///   2. 청크 내 모듈들을 exec_index 순서로 변환+코드젠
///   3. 출력 파일명은 엔트리 청크는 모듈명, 공통 청크는 chunk-{wyhash} 형식 (content-addressable)
///
/// 반환된 OutputFile 배열과 각 OutputFile의 path/contents는 모두 allocator 소유.
pub fn emitChunks(
    allocator: std.mem.Allocator,
    modules: []const Module,
    chunk_graph: *const ChunkGraph,
    options: EmitOptions,
    linker: ?*Linker,
) ![]OutputFile {
    // Code splitting은 ESM 출력만 지원 — CJS/IIFE에서는 네이티브 import()가 없음
    if (options.format != .esm) return error.CodeSplittingRequiresESM;

    var outputs: std.ArrayList(OutputFile) = .empty;
    errdefer {
        for (outputs.items) |o| {
            allocator.free(o.contents);
            allocator.free(o.path);
        }
        outputs.deinit(allocator);
    }

    // 청크를 exec_order 순으로 정렬하여 결정론적 출력 순서 보장.
    // 엔트리 청크가 먼저, 공통 청크가 나중에 오도록 정렬한다.
    const sorted_indices = try allocator.alloc(usize, chunk_graph.chunkCount());
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;

    const SortCtx = struct {
        chunks: []const Chunk,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ca = ctx.chunks[a];
            const cb = ctx.chunks[b];
            // 엔트리 청크 우선
            const a_is_entry: u1 = if (ca.isEntryPoint()) 0 else 1;
            const b_is_entry: u1 = if (cb.isEntryPoint()) 0 else 1;
            if (a_is_entry != b_is_entry) return a_is_entry < b_is_entry;
            // 같은 종류 내에서는 exec_order 순
            return ca.exec_order < cb.exec_order;
        }
    };
    std.mem.sort(usize, sorted_indices, SortCtx{ .chunks = chunk_graph.chunks.items }, SortCtx.lessThan);

    for (sorted_indices) |ci| {
        const chunk = &chunk_graph.chunks.items[ci];

        var chunk_output: std.ArrayList(u8) = .empty;
        errdefer chunk_output.deinit(allocator);

        // CJS 런타임 헬퍼: 이 청크에 CJS 래핑 모듈이 있으면 주입
        var needs_cjs_runtime = false;
        for (chunk.modules.items) |mod_idx| {
            const mi = @intFromEnum(mod_idx);
            if (mi < modules.len and modules[mi].wrap_kind == .cjs) {
                needs_cjs_runtime = true;
                break;
            }
        }
        if (needs_cjs_runtime) {
            if (options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, CJS_RUNTIME_MIN);
                try chunk_output.appendSlice(allocator, TOESM_RUNTIME_MIN);
            } else {
                try chunk_output.appendSlice(allocator, CJS_RUNTIME);
                try chunk_output.appendSlice(allocator, TOESM_RUNTIME);
            }
        }
        if (options.experimental_decorators) {
            if (options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, DECORATOR_RUNTIME_MIN);
            } else {
                try chunk_output.appendSlice(allocator, DECORATOR_RUNTIME);
            }
        }
        if (options.target.needsAsyncAwait()) {
            if (options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, ASYNC_RUNTIME_MIN);
            } else {
                try chunk_output.appendSlice(allocator, ASYNC_RUNTIME);
            }
        }

        // 크로스 청크 import deconfliction:
        // 여러 청크에서 같은 이름의 심볼을 import할 때 충돌 방지.
        // 1단계: 모든 청크로부터의 import 이름 출현 횟수 카운트
        // 2단계: 중복 이름은 `import { x as x$2 }` 형태로 alias 부여
        var name_total_count: std.StringHashMapUnmanaged(u32) = .empty;
        defer name_total_count.deinit(allocator);
        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_ci = @intFromEnum(dep_chunk_idx);
            if (chunk.imports_from.get(dep_ci)) |syms| {
                for (syms.items) |name| {
                    const gop = try name_total_count.getOrPut(allocator, name);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
            }
        }

        // 2단계: import 문 생성 (중복 이름은 alias 부여)
        var name_seen_count: std.StringHashMapUnmanaged(u32) = .empty;
        defer name_seen_count.deinit(allocator);

        // alias 문자열을 임시 저장 (defer free)
        var alias_strs: std.ArrayList([]const u8) = .empty;
        defer {
            for (alias_strs.items) |s| allocator.free(s);
            alias_strs.deinit(allocator);
        }

        for (chunk.cross_chunk_imports.items) |dep_chunk_idx| {
            const dep_chunk = chunk_graph.getChunk(dep_chunk_idx);
            var dep_buf: [64]u8 = undefined;
            const dep_stem = chunkStem(dep_chunk, &dep_buf);
            const dep_ci = @intFromEnum(dep_chunk_idx);

            // imports_from에서 이 청크→dep_chunk로 가져오는 심볼 목록 조회
            const symbols = chunk.imports_from.get(dep_ci);

            if (symbols != null and symbols.?.items.len > 0) {
                // 심볼 수준 import: import { a, b } from './chunk-xxx.js';
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, "import { ");
                } else {
                    try chunk_output.appendSlice(allocator, "import{");
                }
                // 결정론적 출력을 위해 심볼명 정렬
                std.mem.sort([]const u8, symbols.?.items, {}, struct {
                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lessThan);
                for (symbols.?.items, 0..) |name, si| {
                    const total = name_total_count.get(name) orelse 1;
                    const seen_gop = try name_seen_count.getOrPut(allocator, name);
                    if (!seen_gop.found_existing) seen_gop.value_ptr.* = 0;
                    seen_gop.value_ptr.* += 1;
                    const seen = seen_gop.value_ptr.*;

                    if (total > 1 and seen > 1) {
                        // 중복 이름 → alias 부여: import { x as x$2 }
                        const alias = try std.fmt.allocPrint(allocator, "{s}${d}", .{ name, seen });
                        try alias_strs.append(allocator, alias);
                        try chunk_output.appendSlice(allocator, name);
                        try chunk_output.appendSlice(allocator, " as "); // `as`는 키워드이므로 공백 필수
                        try chunk_output.appendSlice(allocator, alias);
                    } else {
                        try chunk_output.appendSlice(allocator, name);
                    }
                    if (si + 1 < symbols.?.items.len) {
                        if (!options.minify_whitespace) {
                            try chunk_output.appendSlice(allocator, ", ");
                        } else {
                            try chunk_output.append(allocator, ',');
                        }
                    }
                }
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, " } from \"./");
                    try chunk_output.appendSlice(allocator, dep_stem);
                    try chunk_output.appendSlice(allocator, ".js\";\n");
                } else {
                    try chunk_output.appendSlice(allocator, "}from\"./");
                    try chunk_output.appendSlice(allocator, dep_stem);
                    try chunk_output.appendSlice(allocator, ".js\";");
                }
            } else {
                // 심볼 정보 없음 → side-effect import (실행 순서 보장용)
                if (!options.minify_whitespace) {
                    try chunk_output.appendSlice(allocator, "import \"./");
                    try chunk_output.appendSlice(allocator, dep_stem);
                    try chunk_output.appendSlice(allocator, ".js\";\n");
                } else {
                    try chunk_output.appendSlice(allocator, "import\"./");
                    try chunk_output.appendSlice(allocator, dep_stem);
                    try chunk_output.appendSlice(allocator, ".js\";");
                }
            }
        }

        // 청크 내 모듈을 exec_index 순으로 정렬
        const sorted_mods = try allocator.alloc(ModuleIndex, chunk.modules.items.len);
        defer allocator.free(sorted_mods);
        @memcpy(sorted_mods, chunk.modules.items);

        const ModSortCtx = struct {
            mods: []const Module,
            fn lessThan(ctx: @This(), a: ModuleIndex, b: ModuleIndex) bool {
                const ai = @intFromEnum(a);
                const bi = @intFromEnum(b);
                const a_exec = if (ai < ctx.mods.len) ctx.mods[ai].exec_index else std.math.maxInt(u32);
                const b_exec = if (bi < ctx.mods.len) ctx.mods[bi].exec_index else std.math.maxInt(u32);
                return a_exec < b_exec;
            }
        };
        std.mem.sort(ModuleIndex, sorted_mods, ModSortCtx{ .mods = modules }, ModSortCtx.lessThan);

        // cross-chunk import 이름 수집 — 점유 이름으로 등록하여 로컬과 충돌 방지.
        // alias가 부여된 이름(x$2 등)도 점유 이름에 포함하여 로컬 변수와의 충돌 방지.
        var occupied: std.ArrayList([]const u8) = .empty;
        defer occupied.deinit(allocator);
        {
            var ifit = chunk.imports_from.iterator();
            while (ifit.next()) |if_entry| {
                for (if_entry.value_ptr.items) |name| {
                    try occupied.append(allocator, name);
                }
            }
            // deconfliction alias 이름도 점유 목록에 추가
            for (alias_strs.items) |alias| {
                try occupied.append(allocator, alias);
            }
        }

        // per-chunk 리네임 계산: 각 청크는 독립된 네임스페이스이므로
        // 청크 내 모듈들만 대상으로 이름 충돌을 감지한다.
        if (linker) |l| {
            try l.computeRenamesForModules(sorted_mods, occupied.items);
        }

        // 엔트리 모듈 인덱스 (final exports용)
        const entry_mod_idx: ?u32 = switch (chunk.kind) {
            .entry_point => |info| @intFromEnum(info.module),
            .common => null,
        };

        for (sorted_mods) |mod_idx| {
            const mi = @intFromEnum(mod_idx);
            if (mi >= modules.len) continue;
            const m = &modules[mi];

            const is_entry = if (entry_mod_idx) |ei| mi == ei else false;
            const raw_code = try emitModule(allocator, m, options, linker, is_entry, null, null) orelse continue;
            defer allocator.free(raw_code);

            // 동적 import 경로 리라이트: import('./page') → import('./page.js')
            const code = try rewriteDynamicImports(allocator, raw_code, m, chunk_graph);
            defer allocator.free(code);

            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, "// --- ");
                try chunk_output.appendSlice(allocator, std.fs.path.basename(m.path));
                try chunk_output.appendSlice(allocator, " ---\n");
            }
            try chunk_output.appendSlice(allocator, code);
            if (!options.minify_whitespace) {
                try chunk_output.append(allocator, '\n');
            }
        }

        // 크로스 청크 export: exports_to에 심볼이 있으면 export 문 생성.
        // 다른 청크가 이 청크에서 심볼을 가져가는 경우에만 출력.
        // linker가 심볼을 rename한 경우 export { local_name as export_name } 형태로 출력.
        if (chunk.exports_to.count() > 0) {
            // 결정론적 출력을 위해 이름을 정렬
            var export_names: std.ArrayList([]const u8) = .empty;
            defer export_names.deinit(allocator);
            var eit = chunk.exports_to.iterator();
            while (eit.next()) |entry| {
                try export_names.append(allocator, entry.key_ptr.*);
            }
            std.mem.sort([]const u8, export_names.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);

            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, "export { ");
            } else {
                try chunk_output.appendSlice(allocator, "export{");
            }
            for (export_names.items, 0..) |name, ni| {
                // export_name의 원본 심볼이 이 청크에서 rename되었는지 확인.
                // rename된 경우: export { local_name as export_name }
                // rename 안 된 경우: export { export_name }
                const local_name = if (linker) |l| blk: {
                    // exports_to의 이름은 canonical export name.
                    // 이 이름을 선언한 모듈을 찾아 linker의 canonical_names를 조회한다.
                    var found_local: ?[]const u8 = null;
                    for (sorted_mods) |mod_idx| {
                        const mi = @intFromEnum(mod_idx);
                        if (mi >= modules.len) continue;
                        if (l.getCanonicalName(@intCast(mi), name)) |renamed| {
                            found_local = renamed;
                            break;
                        }
                        // export의 local_name이 다를 수 있으므로 export_map도 확인
                        if (l.getExportLocalName(@intCast(mi), name)) |local| {
                            if (l.getCanonicalName(@intCast(mi), local)) |renamed| {
                                found_local = renamed;
                                break;
                            }
                        }
                    }
                    break :blk found_local orelse name;
                } else name;

                try chunk_output.appendSlice(allocator, local_name);
                // local_name과 export_name이 다르면 as 절 추가
                if (!std.mem.eql(u8, local_name, name)) {
                    try chunk_output.appendSlice(allocator, " as ");
                    try chunk_output.appendSlice(allocator, name);
                }
                if (ni + 1 < export_names.items.len) {
                    if (!options.minify_whitespace) {
                        try chunk_output.appendSlice(allocator, ", ");
                    } else {
                        try chunk_output.append(allocator, ',');
                    }
                }
            }
            if (!options.minify_whitespace) {
                try chunk_output.appendSlice(allocator, " };\n");
            } else {
                try chunk_output.appendSlice(allocator, "};");
            }
        }

        // 출력 파일명 생성: "{stem}.js"
        var stem_buf: [64]u8 = undefined;
        const stem = chunkStem(chunk, &stem_buf);
        const filename = try std.fmt.allocPrint(allocator, "{s}.js", .{stem});
        errdefer allocator.free(filename);

        try outputs.append(allocator, .{
            .path = filename,
            .contents = try chunk_output.toOwnedSlice(allocator),
        });
    }

    return outputs.toOwnedSlice(allocator);
}

/// 동적 import 경로를 청크 파일명으로 리라이트한다.
///
/// code splitting 시 `import('./page')` → `import('./page.js')` 변환.
/// 모듈의 import_records에서 dynamic_import 레코드를 찾아,
/// resolve된 대상 모듈이 속한 청크의 파일명으로 specifier를 교체한다.
///
/// 반환값은 항상 allocator 소유 — 리라이트 여부와 무관하게 caller가 free해야 한다.
fn rewriteDynamicImports(
    allocator: std.mem.Allocator,
    code: []const u8,
    module: *const Module,
    chunk_graph: *const ChunkGraph,
) ![]const u8 {
    // dynamic import가 없으면 그대로 복사해서 반환
    if (module.import_records.len == 0) {
        return try allocator.dupe(u8, code);
    }

    // 리라이트할 레코드가 있는지 먼저 확인 (불필요한 할당 방지)
    var has_dynamic = false;
    for (module.import_records) |rec| {
        if (rec.kind == .dynamic_import and rec.resolved != .none) {
            const target_chunk = chunk_graph.getModuleChunk(rec.resolved);
            if (target_chunk != .none) {
                has_dynamic = true;
                break;
            }
        }
    }
    if (!has_dynamic) {
        return try allocator.dupe(u8, code);
    }

    // 리라이트 수행: 각 dynamic import specifier를 청크 파일명으로 교체.
    // import_records를 순회하면서 코드 내의 specifier 문자열을 찾아 교체한다.
    // codegen이 specifier를 원본 그대로 출력하므로 정확한 문자열 매칭이 가능.
    var result = try allocator.dupe(u8, code);
    errdefer allocator.free(result);

    for (module.import_records) |rec| {
        if (rec.kind != .dynamic_import) continue;
        if (rec.resolved == .none) continue;

        const target_chunk_idx = chunk_graph.getModuleChunk(rec.resolved);
        if (target_chunk_idx == .none) continue;

        const target_chunk = chunk_graph.getChunk(target_chunk_idx);

        // 청크 파일명 생성: "./{stem}.js"
        var stem_buf: [64]u8 = undefined;
        const stem = chunkStem(target_chunk, &stem_buf);
        const replacement = try std.fmt.allocPrint(allocator, "./{s}.js", .{stem});
        defer allocator.free(replacement);

        // 코드에서 원본 specifier를 찾아 교체
        if (std.mem.indexOf(u8, result, rec.specifier)) |pos| {
            const new_result = try std.mem.concat(allocator, u8, &.{
                result[0..pos],
                replacement,
                result[pos + rec.specifier.len ..],
            });
            allocator.free(result);
            result = new_result;
        }
    }

    return result;
}

/// 청크의 출력 파일 stem을 반환한다 (확장자 없음).
/// 엔트리 청크: 모듈 파일의 stem (예: "index", "lazy")
/// 공통 청크: "chunk-{hash}" — 모듈 인덱스의 정렬된 Wyhash로 결정론적 파일명 생성.
/// 같은 모듈 조합이면 삽입 순서와 무관하게 항상 같은 해시.
fn chunkStem(chunk: *const Chunk, buf: []u8) []const u8 {
    if (chunk.name) |name| return name;
    // 모듈 인덱스를 정렬하여 삽입 순서 무관하게 결정론적 해시 생성
    var hasher = std.hash.Wyhash.init(0);
    // 임시 정렬: 스택 버퍼 사용 (모듈 수가 256 이하인 일반적 경우)
    var sort_buf: [256]u32 = undefined;
    const mod_count = @min(chunk.modules.items.len, 256);
    for (chunk.modules.items[0..mod_count], sort_buf[0..mod_count]) |mod_idx, *sb| {
        sb.* = @intFromEnum(mod_idx);
    }
    std.mem.sort(u32, sort_buf[0..mod_count], {}, std.sort.asc(u32));
    for (sort_buf[0..mod_count]) |idx| {
        hasher.update(std.mem.asBytes(&idx));
    }
    const h = hasher.final();
    return std.fmt.bufPrint(buf, "chunk-{x:0>8}", .{@as(u32, @truncate(h))}) catch "chunk";
}

/// 단일 모듈을 Transformer → Codegen 파이프라인으로 처리.
/// 모듈별 arena에 AST가 보존되어 있으므로 재파싱 불필요.
/// emitChunks에서도 사용하므로 pub으로 노출.
pub fn emitModule(
    allocator: std.mem.Allocator,
    module: *const Module,
    options: EmitOptions,
    linker: ?*const Linker,
    is_entry: bool,
    used_export_names: ?[]const []const u8,
    shaker: ?*const TreeShaker,
) !?[]const u8 {
    // JSON 모듈: 내용을 module.exports = <JSON>으로 래핑
    if (module.module_type == .json) {
        return emitJsonModule(allocator, module);
    }

    // Disabled 모듈 (platform=browser에서 Node 빌트인): 빈 __commonJS wrapper 출력.
    // esbuild 호환: var require_X = __commonJS({ "(disabled)"(exports, module) {} });
    if (module.is_disabled) {
        return emitDisabledModule(allocator, module, options.minify_whitespace);
    }

    const ast = &(module.ast orelse return null);

    // 변환용 arena (Transformer/Codegen 내부 메모리)
    var emit_arena = std.heap.ArenaAllocator.init(allocator);
    defer emit_arena.deinit();
    const arena_alloc = emit_arena.allocator();

    // Transformer: TS 타입 스트리핑, define 치환, decorator 변환 등
    var transformer = Transformer.init(arena_alloc, ast, .{
        .define = options.define,
        .experimental_decorators = options.experimental_decorators,
        .use_define_for_class_fields = options.use_define_for_class_fields,
        .target = options.target,
    });
    // symbol_ids 전파: semantic analyzer가 생성한 원본 AST의 symbol_ids를
    // transformer가 new_ast 기준으로 재매핑
    if (module.semantic) |sem| {
        transformer.old_symbol_ids = sem.symbol_ids;
    }
    const root = try transformer.transform();

    // Linker 메타데이터 생성 (있으면) — new_ast 기준으로 구축
    var metadata: ?LinkingMetadata = null;
    defer if (metadata) |*m| m.deinit();

    if (linker) |l| {
        // transformer가 생성한 new_symbol_ids (있으면 우선 사용)
        const override_syms: ?[]const ?u32 = if (transformer.new_symbol_ids.items.len > 0)
            transformer.new_symbol_ids.items
        else
            null;
        // new_ast 기준으로 skip_nodes 구축 (transformer 이후이므로 노드 인덱스가 new_ast와 일치)
        var md = try l.buildMetadataForAst(
            &transformer.new_ast,
            @intFromEnum(module.index),
            is_entry,
            override_syms,
        );
        // transformer가 전파한 new_symbol_ids를 메타데이터에 설정
        if (override_syms) |syms| {
            md.symbol_ids = syms;
        }
        // statement-level tree-shaking: StmtInfo 기반 도달성 분석으로 미사용 statement 제거.
        // rolldown 방식: 심볼 인덱스로 추적하여 linker rename 후에도 정확한 판정.
        if (used_export_names) |names| {
            if (!is_entry and module.wrap_kind != .cjs) {
                stmt_shake: {
                    const sem = module.semantic orelse {
                        statement_shaker.markUnusedStatements(
                            arena_alloc,
                            &transformer.new_ast,
                            root,
                            names,
                            &md.skip_nodes,
                        ) catch {};
                        break :stmt_shake;
                    };
                    const sym_ids: []const ?u32 = if (transformer.new_symbol_ids.items.len > 0)
                        transformer.new_symbol_ids.items
                    else
                        sem.symbol_ids;

                    // 크로스-모듈 BFS 결과: tree-shaker의 reachable_stmts로 skip_nodes 설정
                    const mod_idx: u32 = @intFromEnum(module.index);
                    if (shaker) |s| {
                        if (s.getModuleStmtInfos(mod_idx)) |ts_infos| {
                            // 변환 후 AST의 program statement list에서 span 매칭
                            const new_root = transformer.new_ast.nodes.items[transformer.new_ast.nodes.items.len - 1];
                            if (new_root.tag == .program and new_root.data.list.len > 0) {
                                const new_list = new_root.data.list;
                                if (new_list.start + new_list.len <= transformer.new_ast.extra_data.items.len) {
                                    const new_stmt_indices = transformer.new_ast.extra_data.items[new_list.start .. new_list.start + new_list.len];
                                    for (ts_infos.stmts, 0..) |ts_stmt, si| {
                                        if (s.isStmtReachable(mod_idx, @intCast(si))) continue;
                                        // 변환 후 top-level statement만 스캔 (O(stmts) not O(nodes))
                                        for (new_stmt_indices) |raw_ni| {
                                            const ni = @as(usize, raw_ni);
                                            if (ni >= transformer.new_ast.nodes.items.len) continue;
                                            const new_node = transformer.new_ast.nodes.items[ni];
                                            if (new_node.span.start == ts_stmt.span.start and
                                                new_node.span.end == ts_stmt.span.end and
                                                ni < md.skip_nodes.capacity())
                                            {
                                                md.skip_nodes.set(ni);
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // tree-shaker 없으면 기존 방식 (모듈 내부 computeReachable)
                        if (stmt_info_mod.build(arena_alloc, &transformer.new_ast, sem.symbols, sym_ids)) |maybe_infos| {
                            if (maybe_infos) |infos| {
                                var used_sym_buf: std.ArrayListUnmanaged(u32) = .empty;
                                defer used_sym_buf.deinit(arena_alloc);
                                if (sem.scope_maps.len > 0) {
                                    for (names) |name| {
                                        if (sem.scope_maps[0].get(name)) |sym_idx| {
                                            used_sym_buf.append(arena_alloc, @intCast(sym_idx)) catch continue;
                                        } else {
                                            for (module.export_bindings) |eb| {
                                                if (std.mem.eql(u8, eb.exported_name, name)) {
                                                    if (sem.scope_maps[0].get(eb.local_name)) |sym_idx| {
                                                        used_sym_buf.append(arena_alloc, @intCast(sym_idx)) catch {};
                                                    }
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                                if (infos.computeReachable(arena_alloc, used_sym_buf.items)) |reachable| {
                                    for (infos.stmts, 0..) |stmt, si| {
                                        if (!reachable.isSet(si) and stmt.node_idx < md.skip_nodes.capacity()) {
                                            md.skip_nodes.set(stmt.node_idx);
                                        }
                                    }
                                } else |_| {}
                            }
                        } else |_| {}
                    }
                }
            }
        }

        metadata = md;
    }

    // Cross-module @__NO_SIDE_EFFECTS__ 전파:
    // import한 함수가 원본 모듈에서 no_side_effects로 선언되었으면
    // 현재 모듈의 해당 호출에 is_pure 플래그를 자동 설정한다.
    if (linker) |l| {
        const sym_ids = if (metadata) |md| md.symbol_ids else &.{};
        propagateCrossModulePurity(l, module, &transformer.new_ast, sym_ids, arena_alloc);
    }

    // Identifier mangling은 단일 파일 트랜스파일(main.zig)에서만 적용.
    // 번들 모드에서는 linker의 scope hoisting과 이름 충돌 해결이 먼저 필요하므로
    // 별도 통합이 필요 (후속 PR).

    // Codegen: AST → JS 문자열
    var cg = Codegen.initWithOptions(arena_alloc, &transformer.new_ast, .{
        .minify = options.minify_whitespace,
        // scope-hoisted 모듈은 항상 ESM codegen 사용 (bare declarations).
        // __commonJS 래핑 모듈만 CJS codegen (module.exports = ...).
        .module_format = if (module.wrap_kind == .cjs) .cjs else .esm,
        .linking_metadata = if (metadata) |*m| m else null,
        // 번들 모드에서 ESM이 아니면 import.meta → {} 치환 (esbuild 호환)
        // Node.js는 import.meta를 보면 ESM으로 재파싱하려 해서 에러 발생
        .replace_import_meta = options.format != .esm,
        .platform = options.platform,
    });
    const code = try cg.generate(root);

    // CJS 래핑: __commonJS 팩토리 함수로 감싸기
    if (module.wrap_kind == .cjs) {
        const basename = std.fs.path.basename(module.path);

        const var_name = try types.makeRequireVarName(allocator, module.path);
        defer allocator.free(var_name);

        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(allocator);

        if (options.minify_whitespace) {
            try wrapped.appendSlice(allocator, "var ");
            try wrapped.appendSlice(allocator, var_name);
            try wrapped.appendSlice(allocator, "=__commonJS({\"");
            try wrapped.appendSlice(allocator, basename);
            try wrapped.appendSlice(allocator, "\"(exports,module){");
            try wrapped.appendSlice(allocator, code);
            try wrapped.appendSlice(allocator, "}});");
        } else {
            try wrapped.appendSlice(allocator, "var ");
            try wrapped.appendSlice(allocator, var_name);
            try wrapped.appendSlice(allocator, " = __commonJS({\n\t\"");
            try wrapped.appendSlice(allocator, basename);
            try wrapped.appendSlice(allocator, "\"(exports, module) {\n");
            // 내부 코드 들여쓰기
            for (code) |c| {
                try wrapped.append(allocator, c);
                if (c == '\n') try wrapped.append(allocator, '\t');
            }
            try wrapped.appendSlice(allocator, "\n\t}\n});\n");
        }

        return try allocator.dupe(u8, wrapped.items);
    }

    // CJS import preamble + final_exports를 하나의 concat으로 합침 (중간 할당 누수 방지)
    const preamble = if (metadata) |md| md.cjs_import_preamble else null;
    const final_exports = if (metadata) |md| md.final_exports else null;

    if (preamble != null or final_exports != null) {
        return try std.mem.concat(allocator, u8, &.{
            preamble orelse "",
            code,
            final_exports orelse "",
        });
    }

    // arena 해제 전에 복사 (caller 소유)
    return try allocator.dupe(u8, code);
}

/// JSON 모듈을 CJS 형태로 출력: __commonJS 래핑 + module.exports = <JSON content>
/// Disabled 모듈: platform=browser에서 Node 빌트인 모듈을 빈 __commonJS wrapper로 출력.
/// esbuild 호환 형식: var require_util = __commonJS({ "(disabled)"(exports, module) {} });
fn emitDisabledModule(allocator: std.mem.Allocator, module: *const Module, minify: bool) !?[]const u8 {
    const var_name = try types.makeRequireVarName(allocator, module.path);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    if (minify) {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, "=__commonJS({\"(disabled)\"(exports,module){}});");
    } else {
        try buf.appendSlice(allocator, "var ");
        try buf.appendSlice(allocator, var_name);
        try buf.appendSlice(allocator, " = __commonJS({\n\t\"(disabled)\"(exports, module) {\n\t}\n});\n");
    }
    return try buf.toOwnedSlice(allocator);
}

fn emitJsonModule(allocator: std.mem.Allocator, module: *const Module) !?[]const u8 {
    if (module.source.len == 0) return null;

    const var_name = try types.makeRequireVarName(allocator, module.path);
    defer allocator.free(var_name);

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, "var ");
    try buf.appendSlice(allocator, var_name);
    try buf.appendSlice(allocator, " = __commonJS({\n\t\"");
    try buf.appendSlice(allocator, std.fs.path.basename(module.path));
    try buf.appendSlice(allocator, "\"(exports, module) {\nmodule.exports=");
    try buf.appendSlice(allocator, module.source);
    try buf.appendSlice(allocator, ";\n\t}\n});\n");
    return try buf.toOwnedSlice(allocator);
}

/// Cross-module @__NO_SIDE_EFFECTS__ 전파.
///
/// 단일 모듈 내에서는 semantic analyzer가 callee symbol의 no_side_effects 플래그를 보고
/// call_expression에 is_pure를 자동 설정한다 (analyzer.zig:863-876).
/// 하지만 cross-module import의 경우, importing 모듈의 semantic analyzer는 원본 모듈의
/// symbol을 모르므로 is_pure가 설정되지 않는다.
///
/// 이 함수는 linker가 해석한 import→export 바인딩을 활용하여:
/// 1. import한 symbol이 원본 모듈에서 no_side_effects로 선언되었는지 확인
/// 2. 해당 symbol을 callee로 사용하는 call_expression에 is_pure 플래그 설정
fn propagateCrossModulePurity(
    linker: *const Linker,
    module: *const Module,
    new_ast: *Ast,
    symbol_ids: []const ?u32,
    allocator: std.mem.Allocator,
) void {
    const sem = module.semantic orelse return;
    if (sem.scope_maps.len == 0) return;
    if (module.import_bindings.len == 0) return;
    const module_scope = sem.scope_maps[0];
    const module_index: u32 = @intFromEnum(module.index);

    // 1단계: no_side_effects인 import binding의 local symbol_id를 수집한다.
    // 비트셋 대신 bool 배열 사용 — 스택 256개, 초과 시 arena fallback.
    var has_any_pure = false;
    const sym_count = sem.symbols.len;
    if (sym_count == 0) return;

    var pure_flags_buf: [256]bool = .{false} ** 256;
    const pure_flags: []bool = if (sym_count <= 256)
        pure_flags_buf[0..sym_count]
    else
        allocator.alloc(bool, sym_count) catch return;
    defer if (sym_count > 256) allocator.free(pure_flags);
    if (sym_count > 256) @memset(pure_flags, false);

    for (module.import_bindings) |ib| {
        if (ib.kind == .namespace) continue;

        const resolved = linker.getResolvedBinding(module_index, ib.local_span) orelse continue;

        const canon_mod_idx = @intFromEnum(resolved.canonical.module_index);
        if (canon_mod_idx >= linker.modules.len) continue;
        const target_module = linker.modules[canon_mod_idx];
        const target_sem = target_module.semantic orelse continue;

        if (target_sem.scope_maps.len == 0) continue;
        const target_scope = target_sem.scope_maps[0];

        // default export는 local_name이 다를 수 있음 ("default" → 실제 함수명)
        const target_sym_name = if (std.mem.eql(u8, resolved.canonical.export_name, "default"))
            linker.getExportLocalName(canon_mod_idx, "default") orelse resolved.canonical.export_name
        else
            resolved.canonical.export_name;

        const target_sym_idx = target_scope.get(target_sym_name) orelse continue;
        if (target_sym_idx >= target_sem.symbols.len) continue;
        if (!target_sem.symbols[target_sym_idx].decl_flags.no_side_effects) continue;

        const local_sym_idx = module_scope.get(ib.local_name) orelse continue;
        if (local_sym_idx >= sym_count) continue;

        pure_flags[local_sym_idx] = true;
        has_any_pure = true;
    }

    if (!has_any_pure) return;

    // 2단계: new_ast의 call/new expression 중 callee가 pure import이면 is_pure 설정
    const CallFlags = @import("../parser/ast.zig").CallFlags;

    for (new_ast.nodes.items) |node| {
        if (node.tag != .call_expression and node.tag != .new_expression) continue;

        const e = node.data.extra;
        if (!new_ast.hasExtra(e, 3)) continue;

        const callee_idx = new_ast.readExtraNode(e, 0);
        if (callee_idx.isNone()) continue;
        const callee_ni = @intFromEnum(callee_idx);

        if (callee_ni >= new_ast.nodes.items.len) continue;
        if (new_ast.nodes.items[callee_ni].tag != .identifier_reference) continue;

        if (callee_ni >= symbol_ids.len) continue;
        const sym_idx = symbol_ids[callee_ni] orelse continue;
        if (sym_idx >= sym_count) continue;

        if (pure_flags[sym_idx]) {
            new_ast.extra_data.items[e + 3] |= CallFlags.is_pure;
        }
    }
}

// ============================================================
// Tests
// ============================================================

const resolve_cache_mod = @import("resolve_cache.zig");

const writeFile = @import("test_helpers.zig").writeFile;

fn buildGraph(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !struct { graph: ModuleGraph, cache: resolve_cache_mod.ResolveCache } {
    const dp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dp);
    const entry = try std.fs.path.resolve(allocator, &.{ dp, entry_name });
    defer allocator.free(entry);

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .browser, &.{}, &.{});
    var graph = ModuleGraph.init(allocator, &cache);
    try graph.build(&.{entry});
    return .{ .graph = graph, .cache = cache };
}

test "emitter: single module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // TS 타입 스트리핑: "const x: number = 1;" → "const x = 1;"
    try std.testing.expect(std.mem.indexOf(u8, output, "const x = 1;") != null);
}

test "emitter: two modules exec order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 1;");
    try writeFile(tmp.dir, "b.ts", "const b = 2;");

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // b.ts가 a.ts보다 먼저 출력 (exec_index 순서)
    const b_pos = std.mem.indexOf(u8, output, "const b = 2;") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, output, "const a = 1;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b_pos < a_pos);
}

test "emitter: minified output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{ .minify_whitespace = true, .minify_identifiers = true }, null);
    defer std.testing.allocator.free(output);

    // minify: 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, output, "// ---") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const x=1;") != null);
}

test "emitter: IIFE format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{ .format = .iife }, null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, output, "})();\n"));
}

test "emitter: CJS format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{ .format = .cjs }, null);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.startsWith(u8, output, "\"use strict\";\n"));
}

test "emitter: empty graph" {
    var cache = resolve_cache_mod.ResolveCache.init(std.testing.allocator, .browser, &.{}, &.{});
    defer cache.deinit();
    var graph = ModuleGraph.init(std.testing.allocator, &cache);
    defer graph.deinit();

    const output = try emit(std.testing.allocator, &graph, .{}, null);
    defer std.testing.allocator.free(output);

    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "emitter: chain A → B → C order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 'a';");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconst b = 'b';");
    try writeFile(tmp.dir, "c.ts", "const c = 'c';");

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // C → B → A 순서
    const c_pos = std.mem.indexOf(u8, output, "const c = \"c\";") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, output, "const b = \"b\";") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, output, "const a = \"a\";") orelse return error.TestUnexpectedResult;
    try std.testing.expect(c_pos < b_pos);
    try std.testing.expect(b_pos < a_pos);
}

test "emitter: TS enum and interface stripping" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts",
        \\interface Foo { x: number; }
        \\enum Color { Red, Green, Blue }
        \\const x: Foo = { x: 1 };
    );

    var result = try buildGraph(std.testing.allocator, &tmp, "a.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const output = try emit(std.testing.allocator, &result.graph, .{}, null);
    defer std.testing.allocator.free(output);

    // interface 제거됨
    try std.testing.expect(std.mem.indexOf(u8, output, "interface") == null);
    // enum → IIFE 변환
    try std.testing.expect(std.mem.indexOf(u8, output, "Color") != null);
    // 일반 코드 유지
    try std.testing.expect(std.mem.indexOf(u8, output, "const x") != null);
}

// ============================================================
// emitChunks Tests
// ============================================================

fn buildGraphMultiEntry(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_names: []const []const u8) !struct { graph: ModuleGraph, cache: resolve_cache_mod.ResolveCache } {
    const dp = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dp);

    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e);
        entries.deinit(allocator);
    }
    for (entry_names) |name| {
        try entries.append(allocator, try std.fs.path.resolve(allocator, &.{ dp, name }));
    }

    var cache = resolve_cache_mod.ResolveCache.init(allocator, .browser, &.{}, &.{});
    var graph = ModuleGraph.init(allocator, &cache);
    try graph.build(entries.items);
    return .{ .graph = graph, .cache = cache };
}

test "emitChunks: single chunk produces one OutputFile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{entry_path}, null);
    defer cg.deinit();

    const outputs = try emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs);
    }

    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expectEqualStrings("index.js", outputs[0].path);
    try std.testing.expect(std.mem.indexOf(u8, outputs[0].contents, "const x = 1;") != null);
}

test "emitChunks: two entries with shared module — 3 OutputFiles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "console.log('shared');");

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, result.graph.modules.items, std.testing.allocator, null);

    const outputs = try emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs);
    }

    // 2 엔트리 + 1 공통 = 3 파일
    try std.testing.expectEqual(@as(usize, 3), outputs.len);

    // shared 코드는 정확히 1개의 출력에만 포함
    var shared_count: usize = 0;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.contents, "\"shared\"") != null) shared_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shared_count);
}

// ============================================================
// rewriteDynamicImports Tests
// ============================================================

test "CodeSplitting: dynamic import path rewritten to chunk filename" {
    // 설정: index.ts가 import('./lazy')로 lazy.ts를 동적 import.
    // lazy.ts가 별도 청크에 속할 때, import('./lazy') → import('./lazy.js')로 리라이트 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const load = () => import('./lazy');");
    try writeFile(tmp.dir, "lazy.ts", "export const x = 42;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);

    // lazy.ts를 별도 엔트리로도 추가하여 별도 청크가 생성되도록 함
    const lazy_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "lazy.ts" });
    defer std.testing.allocator.free(lazy_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ entry_path, lazy_path }, null);
    defer cg.deinit();

    const outputs = try emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs);
    }

    // index.js 출력에서 import 경로가 리라이트되었는지 확인
    var found_rewrite = false;
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.path, "index") != null) {
            // 리라이트 후: import('./lazy.js') 또는 import("./lazy.js")
            if (std.mem.indexOf(u8, o.contents, "./lazy.js") != null) {
                found_rewrite = true;
            }
            // 원본 specifier('./lazy')가 그대로 남아있으면 안 됨
            // (단, './lazy.js'에 './lazy'가 부분 매칭되므로 정확히 확인)
            if (std.mem.indexOf(u8, o.contents, "'./lazy'") != null or
                std.mem.indexOf(u8, o.contents, "\"./lazy\"") != null)
            {
                // 원본이 리라이트 없이 남아있음 — 실패
                try std.testing.expect(false);
            }
            break;
        }
    }
    try std.testing.expect(found_rewrite);
}

test "CodeSplitting: multiple dynamic imports rewritten" {
    // 설정: index.ts가 두 개의 동적 import를 가짐.
    // 둘 다 별도 청크에 속할 때, 양쪽 모두 리라이트 확인.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts",
        \\const a = () => import('./pageA');
        \\const b = () => import('./pageB');
    );
    try writeFile(tmp.dir, "pageA.ts", "export const a = 1;");
    try writeFile(tmp.dir, "pageB.ts", "export const b = 2;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);
    const pageA_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "pageA.ts" });
    defer std.testing.allocator.free(pageA_path);
    const pageB_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "pageB.ts" });
    defer std.testing.allocator.free(pageB_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ entry_path, pageA_path, pageB_path }, null);
    defer cg.deinit();

    const outputs = try emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs);
    }

    // index.js에서 두 경로 모두 리라이트 확인
    for (outputs) |o| {
        if (std.mem.indexOf(u8, o.path, "index") != null) {
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "./pageA.js") != null);
            try std.testing.expect(std.mem.indexOf(u8, o.contents, "./pageB.js") != null);
            break;
        }
    }
}

// ============================================================
// Content Hash Filename Tests
// ============================================================

test "chunkStem: common chunk uses hex hash, not index" {
    // 공통 청크의 파일명이 chunk-{hex} 형식인지 확인.
    // 같은 모듈 조합이면 항상 같은 해시가 나와야 한다 (결정론적).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 1;");

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg, result.graph.modules.items, std.testing.allocator, null);

    const outputs = try emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs);
    }

    // 공통 청크 파일명이 chunk-{8자리 hex}.js 형식인지 확인
    var found_hash_chunk = false;
    for (outputs) |o| {
        if (std.mem.startsWith(u8, o.path, "chunk-")) {
            found_hash_chunk = true;
            // "chunk-" 뒤에 8자리 hex + ".js"여야 함
            const after_prefix = o.path["chunk-".len..];
            try std.testing.expect(after_prefix.len == 8 + ".js".len); // "XXXXXXXX.js"
            // hex 문자만 포함되는지 확인
            for (after_prefix[0..8]) |c| {
                try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
            }
            try std.testing.expect(std.mem.endsWith(u8, o.path, ".js"));
        }
    }
    try std.testing.expect(found_hash_chunk);
}

test "chunkStem: same modules produce same hash (deterministic)" {
    // 같은 모듈 조합으로 두 번 빌드해도 같은 chunk 파일명이 나와야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './shared';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './shared';\nconsole.log('b');");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 1;");

    var result1 = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result1.graph.deinit();
    defer result1.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg1 = try chunk_mod.generateChunks(std.testing.allocator, result1.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg1.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg1, result1.graph.modules.items, std.testing.allocator, null);

    const outputs1 = try emitChunks(std.testing.allocator, result1.graph.modules.items, &cg1, .{}, null);
    defer {
        for (outputs1) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs1);
    }

    // 두 번째 빌드
    var result2 = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result2.graph.deinit();
    defer result2.cache.deinit();

    var cg2 = try chunk_mod.generateChunks(std.testing.allocator, result2.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg2.deinit();
    try chunk_mod.computeCrossChunkLinks(&cg2, result2.graph.modules.items, std.testing.allocator, null);

    const outputs2 = try emitChunks(std.testing.allocator, result2.graph.modules.items, &cg2, .{}, null);
    defer {
        for (outputs2) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs2);
    }

    // 공통 청크 파일명이 동일한지 확인
    var chunk_name1: ?[]const u8 = null;
    var chunk_name2: ?[]const u8 = null;
    for (outputs1) |o| {
        if (std.mem.startsWith(u8, o.path, "chunk-")) chunk_name1 = o.path;
    }
    for (outputs2) |o| {
        if (std.mem.startsWith(u8, o.path, "chunk-")) chunk_name2 = o.path;
    }
    try std.testing.expect(chunk_name1 != null);
    try std.testing.expect(chunk_name2 != null);
    try std.testing.expectEqualStrings(chunk_name1.?, chunk_name2.?);
}

// ============================================================
// CJS Runtime Deduplication Tests
// ============================================================

test "CJS runtime: __commonJS only in chunks containing CJS modules" {
    // CJS 모듈이 없는 청크에는 __commonJS 런타임이 주입되지 않아야 한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // a.ts는 ESM만 사용 — CJS 런타임 불필요
    try writeFile(tmp.dir, "a.ts", "export const a = 1;");
    // b.ts도 ESM만 사용
    try writeFile(tmp.dir, "b.ts", "export const b = 2;");

    var result = try buildGraphMultiEntry(std.testing.allocator, &tmp, &.{ "a.ts", "b.ts" });
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const ep_a = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "a.ts" });
    defer std.testing.allocator.free(ep_a);
    const ep_b = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "b.ts" });
    defer std.testing.allocator.free(ep_b);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{ ep_a, ep_b }, null);
    defer cg.deinit();

    const outputs = try emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs);
    }

    // 어떤 청크에도 __commonJS가 없어야 함 (순수 ESM이므로)
    for (outputs) |o| {
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "__commonJS") == null);
        try std.testing.expect(std.mem.indexOf(u8, o.contents, "__toESM") == null);
    }
}

test "CodeSplitting: static import not rewritten" {
    // 설정: index.ts가 static import만 사용 — 경로 리라이트 없어야 함.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 1;");

    var result = try buildGraph(std.testing.allocator, &tmp, "index.ts");
    defer result.graph.deinit();
    defer result.cache.deinit();

    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    const entry_path = try std.fs.path.resolve(std.testing.allocator, &.{ dp, "index.ts" });
    defer std.testing.allocator.free(entry_path);

    var cg = try chunk_mod.generateChunks(std.testing.allocator, result.graph.modules.items, &.{entry_path}, null);
    defer cg.deinit();

    const outputs = try emitChunks(std.testing.allocator, result.graph.modules.items, &cg, .{}, null);
    defer {
        for (outputs) |o| {
            std.testing.allocator.free(o.path);
            std.testing.allocator.free(o.contents);
        }
        std.testing.allocator.free(outputs);
    }

    // 단일 청크 — static import는 linker가 제거하므로 경로가 출력에 없음
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    // import('./lib.js') 같은 동적 import 경로가 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, outputs[0].contents, "import('./") == null);
    try std.testing.expect(std.mem.indexOf(u8, outputs[0].contents, "import(\"./") == null);
}
