//! Runtime helper emission policy for bundle and chunk outputs.

const std = @import("std");
const rt = @import("../runtime_helpers.zig");
const Module = @import("../module.zig").Module;
const ModuleIndex = @import("../types.zig").ModuleIndex;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const Chunk = @import("../chunk.zig").Chunk;
const linker_mod = @import("../linker.zig");
const Linker = linker_mod.Linker;
const RuntimeHelpers = @import("../../transformer/runtime_helper_bits.zig").RuntimeHelpers;
const parent = @import("../emitter.zig");
const chunks = @import("chunks.zig");
const EmitOptions = parent.EmitOptions;

/// 번들 레벨 런타임 헬퍼 주입 (CJS interop + decorator + async).
/// emitWithTreeShaking에서 사용.
pub fn emitBundleRuntimeHelpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    sorted_modules: []const *const Module,
    graph: *const ModuleGraph,
    linker: ?*const Linker,
    options: *const EmitOptions,
) !void {
    // 런타임 헬퍼 주입: 래핑 모듈 유형에 따라 필요한 헬퍼 결정.
    var needs_cjs_runtime = false;
    var needs_esm_wrap_runtime = false;
    var needs_to_esm_runtime = false;
    var needs_to_binary = false;
    for (sorted_modules) |m| {
        if (m.wrap_kind == .cjs) needs_cjs_runtime = true;
        if (m.wrap_kind == .esm) needs_esm_wrap_runtime = true;
        if (moduleNeedsToEsmInterop(m, graph, linker)) needs_to_esm_runtime = true;
        // (#4120) entry 가 `export { default } from './cjs'`(non can_skip)면 buildFinalExports 가
        // `var _default = __toESM(require_X()).default` 를 materialize 한다 — default 를 import 하는
        // consumer 가 없어 moduleNeedsToEsmInterop(import_bindings 만 스캔)이 못 잡는다(단일번들에서
        // `__toESM is not defined` ReferenceError). emitChunkRuntimeHelpers 와 동일 검사 추가.
        if (moduleReExportsCjsDefaultNeedsToEsm(m, graph, linker)) needs_to_esm_runtime = true;
        // (#4510) 인라인된 CJS 동적 import → `__toESM(require_x())` 로 재작성(rewriteDynamicImports*).
        // 단일 번들은 모든 모듈이 같은 파일이라 항상 인라인 대상.
        if (graph.inline_dynamic_imports and moduleInlinesDynamicCjsImport(m, graph, alwaysSameUnit, undefined)) {
            needs_to_esm_runtime = true;
        }
        if (m.loader == .binary) needs_to_binary = true;
        if (needs_cjs_runtime and needs_esm_wrap_runtime and needs_to_esm_runtime and needs_to_binary) break;
    }
    if (needs_cjs_runtime or needs_esm_wrap_runtime) {
        // Node ESM 출력에서 *external require 호출* (예: `require("fs")`) 이 bundle 에 emit
        // 되면 그 `require` 가 런타임에 미정의 — `createRequire(import.meta.url)` shim 필요.
        // `__commonJS` wrapper 자체는 cb 를 직접 호출하므로 shim 필요 조건은
        // `kind=.require and is_external` 한 import_record 의 존재로 좁혀진다.
        if (needsRequireShim(sorted_modules, options)) {
            try rt.appendRequireShim(output, allocator, options.minify_whitespace);
        }
        if (needs_cjs_runtime) {
            try rt.appendCommonJsFactoryRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
        }
        // __toCommonJS는 __copyProps/__defProp 에 의존 -> ESM wrap 런타임을 emit 하면
        // 어떤 import site 도 __toESM 을 부르지 않더라도 __toESM 클러스터가 필요.
        if (needs_to_esm_runtime or needs_esm_wrap_runtime) {
            try rt.appendToEsmRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
        }
    }
    if (needs_esm_wrap_runtime) {
        try rt.appendEsmWrapRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (options.experimental_decorators) {
        try rt.appendDecoratorRuntime(output, allocator, options.minify_whitespace);
    }
    // __async는 이후 appendRuntimeHelpers(collected_helpers)에서 실제 사용 여부 기반으로
    // 주입됨 — 여기서 target 기반으로 또 주입하면 중복 emit 된다.
    // dev mode: HMR 런타임 주입 (__zntc_modules, __zntc_require, __zntc_apply_update 등).
    // HMR 런타임이 $RefreshReg$/$RefreshSig$도 정의하므로 별도 스텁 불필요.
    if (options.dev_mode) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.HMR_RUNTIME_MIN else rt.HMR_RUNTIME);
        // RN: react-refresh/runtime 의 dev_id 를 전역(__zntc_g.__zntc_refresh_id)으로 주입.
        // __zntc_resolveRefresh()가 전역 require 대신 __zntc_modules[id] 로 runtime 을 꺼내
        // setUpReactRefresh 와 동일 인스턴스를 공유한다(Metro 호환). 브라우저는 null → 미주입.
        if (options.react_refresh_runtime_dev_id) |rid| {
            try output.appendSlice(allocator, "__zntc_g.__zntc_refresh_id=");
            try parent.appendJsonString(output, allocator, rid);
            try output.appendSlice(allocator, ";\n");
        }
    } else if (options.react_refresh) {
        // 비-dev 모드에서 react_refresh만 활성화된 경우 스텁 주입
        try output.appendSlice(allocator, rt.REFRESH_STUB);
    }
    // entry_error_guard: Metro `guardedLoadModule` 동등 mechanism 의 helper 주입.
    // 실제 wrap 은 emit 단계에서 module init 호출 site 별로 `__zntc_guarded(fn)` 으로 emit.
    if (options.entry_error_guard) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.GUARDED_RUNTIME_MIN else rt.GUARDED_RUNTIME);
    }
    // silent_console_error_patterns: 패턴 비어있으면 emit X — vanilla RN 등 trigger 없는
    // 환경에서 dead code 0. consumer 가 환경 (e.g. expo) 감지 후 패턴 주입.
    try rt.emitConsoleErrorInterceptInto(output, allocator, options.silent_console_error_patterns, options.minify_whitespace);
    try emitOptionPathHelpers(output, allocator, needs_to_binary, options);
}

/// 한 모듈이 어떤 식으로든 CJS 모듈의 default/namespace 를 가져오면 __toESM 래핑이 필요.
/// `linker.cjsImportNeedsToEsmInterop` 가 leaf predicate (linker 의 emit 분기와 공유).
///
/// linker 가 있으면 `getResolvedBinding` 의 chain 끝까지 따라가 ESM re-export
/// (`export { default } from "./cjs"`) 와 다단계 re-export 도 캐치. linker 가 없으면
/// (linker_test 단독 등) importer 의 직접 target 만 검사하는 보수적 fallback.
/// (#3975) 모듈이 *순수* CJS star re-export(ESM 이 단일 `export * from <CJS>` 만,
/// 자체 named/default export·다른 star 없음)인지. metadata.zig 의 pureCjsStarTarget
/// 와 동일 조건 — namespace import 가 이 모듈을 가리키면 underlying CJS 로 redirect 되어
/// `__toESM(require())` 가 emit 되므로 헬퍼 필요 판정에 쓴다.
fn isPureCjsStarReExport(target: *const Module, graph: *const ModuleGraph) bool {
    if (target.wrap_kind == .cjs) return false;
    var found_cjs_star = false;
    for (target.export_bindings) |eb| {
        if (eb.kind.isReExportAll() and std.mem.eql(u8, eb.exported_name, "*")) {
            const ri = eb.import_record_index orelse return false;
            if (ri >= target.import_records.len) return false;
            const src = target.import_records[ri].resolved;
            if (src.isNone()) return false;
            const sm = graph.getModule(src) orelse return false;
            if (sm.wrap_kind != .cjs) return false;
            if (found_cjs_star) return false; // 다중 star → 순수 아님
            found_cjs_star = true;
        } else {
            return false; // 자체 export 또는 export * as ns
        }
    }
    return found_cjs_star;
}

/// (#3975) namespace target(ESM)이 CJS 를 `export *`/`export * as` 로 재노출하는지
/// (혼합·다중·inner 포함, pure-single 상위집합). metadata.zig 의 namespaceHasCjsStar 와
/// 동일 조건 — 이 경로는 per-module preamble 이 `__copyProps(ns, require())`/`__toESM`
/// 을 emit 하므로 두 헬퍼가 필요하다. 두 함수는 lockstep 유지 (어긋나면 헬퍼 미정의 →
/// ReferenceError).
fn namespaceTargetHasCjsStar(target: *const Module, graph: *const ModuleGraph) bool {
    if (target.wrap_kind == .cjs) return false;
    for (target.export_bindings) |eb| {
        const is_star = eb.kind.isReExportAll() and std.mem.eql(u8, eb.exported_name, "*");
        const is_star_as = eb.kind == .re_export_namespace;
        if (!is_star and !is_star_as) continue;
        const ri = eb.import_record_index orelse continue;
        if (ri >= target.import_records.len) continue;
        const src = target.import_records[ri].resolved;
        if (src.isNone()) continue;
        const sm = graph.getModule(src) orelse continue;
        if (sm.wrap_kind == .cjs) return true;
    }
    return false;
}

fn moduleNeedsToEsmInterop(module: *const Module, graph: *const ModuleGraph, linker: ?*const Linker) bool {
    for (module.import_bindings) |ib| {
        if (ib.import_record_index >= module.import_records.len) continue;

        // namespace import: chain follow 가 아니라 importer 의 직접 target 만 확인.
        // (`import * as ns from "./cjs"` 면 항상 __toESM(req()) 로 emit.)
        if (ib.kind == .namespace) {
            const record = module.import_records[ib.import_record_index];
            if (record.resolved.isNone()) continue;
            const target = graph.getModule(record.resolved) orelse continue;
            if (target.wrap_kind == .cjs) return true;
            // (#3975) target 이 ESM 이라도 *pure* CJS-star re-export(단일 `export * from
            // <CJS>`, 자체 export 없음)면 metadata 가 underlying CJS 로 redirect 해 per-module
            // preamble 이 `var ns = __toESM(require())` 를 emit → __toESM 헬퍼 필요. redirect
            // 조건(metadata.zig pureCjsStarTarget)과 동일하게 감지한다.
            if (isPureCjsStarReExport(target, graph)) return true;
            // (#3975) 혼합/다중/inner: per-module preamble 이 `__copyProps(ns, require())`
            // (+ inner 는 __toESM) 를 emit → 헬퍼 필요.
            if (namespaceTargetHasCjsStar(target, graph)) return true;
            continue;
        }

        // default / named import: linker 가 있으면 re-export chain 끝까지 따라가
        // canonical 이 CJS 의 "default" 면 emit 시 `__toESM(req()).default` 가 나온다.
        // named (non-default) 는 chain 끝도 named 라 `req().name` 직접 접근 -> __toESM 불필요.
        if (linker) |l| {
            if (l.getResolvedBinding(module.index.toU32(), ib.local_span)) |rb| {
                const canonical_mod = graph.getModule(rb.canonical.module_index) orelse continue;
                if (canonical_mod.wrap_kind == .cjs and
                    linker_mod.cjsImportNeedsToEsmInterop(false, rb.canonical.export_name) and
                    !module.canUseDirectCjsDefaultImport(canonical_mod))
                {
                    return true;
                }
                continue;
            }
        }

        // Fallback: linker 없거나 binding 미해결. importer 의 직접 target 검사.
        if (!ib.importsDefault()) continue;
        const record = module.import_records[ib.import_record_index];
        if (record.resolved.isNone()) continue;
        const target = graph.getModule(record.resolved) orelse continue;
        if (target.wrap_kind == .cjs and !module.canUseDirectCjsDefaultImport(target)) return true;
    }
    return false;
}

/// (#4120) CJS 모듈 `m` 이 cross-chunk 으로 default 를 노출하고 그 default 가 __toESM interop 을
/// 거쳐야 하면 true. provider 청크가 `var g = __toESM(require_X()).default` 를 materialize 하므로
/// 그 청크에 __toESM 헬퍼가 필요하다. `module.exports = X` shape(can_skip)는 `require_X()` direct 라 제외.
fn cjsCrossChunkDefaultNeedsToEsm(m: *const Module, linker: ?*const Linker) bool {
    if (m.wrap_kind != .cjs) return false;
    const l = linker orelse return false;
    // (#4510) namespace 전역명(키 "*")이 있으면 provider 가 `var ns$x = __toESM(require_X())` 를
    // materialize 한다 — ns 객체는 can_skip shape 여도 __toESM 이 필요하다(default 만 있는 값이
    // 아니라 프로퍼티까지 복사한 객체라야 `ns.member` 가 동작).
    if (l.getCrossChunkGlobalName(m.index.toU32(), linker_mod.CJS_NS_EXPORT_NAME) != null) return true;
    if (m.can_skip_cjs_default_interop) return false;
    return l.getCrossChunkGlobalName(m.index.toU32(), "default") != null;
}

/// (#4120) 모듈 `m` 이 CJS default 를 ESM re-export(`export { default } from './cjs'`) 하고 그
/// default 가 __toESM interop 을 거쳐야 하면 true. entry/dynamic 청크의 buildFinalExports 가
/// `var _default = __toESM(require_X()).default` 를 materialize 하므로 __toESM 헬퍼가 필요하다.
/// named re-export 는 `require_X().m`(헬퍼 불요), `module.exports = X` shape(can_skip)는 direct 라 제외.
fn moduleReExportsCjsDefaultNeedsToEsm(m: *const Module, graph: *const ModuleGraph, linker: ?*const Linker) bool {
    const l = linker orelse return false;
    for (m.export_bindings) |eb| {
        if (eb.kind != .re_export) continue;
        const canon = l.resolveExportChain(m.index, eb.exported_name, 0) orelse continue;
        if (!std.mem.eql(u8, canon.export_name, "default")) continue;
        const cm = graph.getModule(canon.module_index) orelse continue;
        if (cm.wrap_kind != .cjs) continue;
        if (cm.can_skip_cjs_default_interop) continue;
        return true;
    }
    return false;
}

/// (#4510) 모듈 `m` 이 **같은 출력 단위 안에 인라인된 CJS 모듈** 을 동적 import 하는지.
/// 그 `import('./x.cjs')` 는 `Promise.resolve().then(()=>__toESM(require_x()))` 로 재작성되므로
/// (chunks.zig `dynamicCjsNamespaceExpr`) __toESM 헬퍼가 필요하다 — import_bindings 만 보는
/// `moduleNeedsToEsmInterop` 은 dynamic import record 를 못 잡는다.
/// `same_unit` 은 "대상이 이 출력 단위(번들/청크)에 함께 있는가" 판정 — 재작성 조건과 일치해야
/// 한다(다른 청크면 specifier 치환만 하므로 헬퍼 불요).
fn moduleInlinesDynamicCjsImport(
    m: *const Module,
    graph: *const ModuleGraph,
    same_unit: *const fn (ctx: *const anyopaque, target: ModuleIndex) bool,
    ctx: *const anyopaque,
) bool {
    for (m.import_records) |rec| {
        if (rec.kind != .dynamic_import) continue;
        if (rec.resolved == .none) continue;
        const target = graph.getModule(rec.resolved) orelse continue;
        if (target.wrap_kind != .cjs) continue;
        if (same_unit(ctx, rec.resolved)) return true;
    }
    return false;
}

/// (#4524) 모듈 `m` 이 CJS 모듈을 **동적 import** 하는가 (같은 단위 여부 무관).
/// preserve-modules 는 대상이 늘 다른 파일이라 `moduleInlinesDynamicCjsImport` 의
/// same-unit 판정으로는 못 잡는다.
fn moduleDynamicallyImportsCjs(m: *const Module, graph: *const ModuleGraph) bool {
    for (m.import_records) |rec| {
        if (rec.kind != .dynamic_import) continue;
        if (rec.resolved == .none) continue;
        const target = graph.getModule(rec.resolved) orelse continue;
        if (target.wrap_kind == .cjs) return true;
    }
    return false;
}

/// 단일 번들: 모든 모듈이 한 파일 → 대상이 항상 같은 단위.
fn alwaysSameUnit(_: *const anyopaque, _: ModuleIndex) bool {
    return true;
}

/// 청크: 대상 모듈이 이 청크의 module 목록에 있는지.
fn chunkContainsModule(ctx: *const anyopaque, target: ModuleIndex) bool {
    const chunk: *const Chunk = @ptrCast(@alignCast(ctx));
    for (chunk.modules.items) |mi| {
        if (mi == target) return true;
    }
    return false;
}

/// transformer 비트맵 외 경로의 helper (asset binary loader / `--keep-names` 옵션)
/// preamble. emitBundleRuntimeHelpers / emitChunkRuntimeHelpers 양쪽 공용 (#1961 PR 1h).
fn emitOptionPathHelpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    needs_to_binary: bool,
    options: *const EmitOptions,
) !void {
    if (needs_to_binary) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.TO_BINARY_RUNTIME_MIN else rt.TO_BINARY_RUNTIME);
    }
    if (options.keep_names) {
        try output.appendSlice(allocator, if (options.minify_whitespace) rt.KEEP_NAMES_RUNTIME_MIN else rt.KEEP_NAMES_RUNTIME);
    }
}

/// 청크별 런타임 헬퍼 주입.
/// emitChunks에서 사용.
pub fn emitChunkRuntimeHelpers(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    graph: *const ModuleGraph,
    linker: ?*const Linker,
    options: *const EmitOptions,
    collected_helpers: ?RuntimeHelpers,
) !void {
    var needs_cjs_runtime = false;
    var needs_esm_wrap_runtime = false;
    var needs_to_esm_runtime = false;
    var needs_to_binary = false;
    for (chunk.modules.items) |mod_idx| {
        const m = graph.getModule(mod_idx) orelse continue;
        if (m.wrap_kind == .cjs) needs_cjs_runtime = true;
        if (m.wrap_kind == .esm) needs_esm_wrap_runtime = true;
        if (moduleNeedsToEsmInterop(m, graph, linker)) needs_to_esm_runtime = true;
        // (#4120) cross-chunk 으로 default 를 노출하는 CJS 모듈은 provider 청크 자체가
        // `var g = __toESM(require_X()).default` 를 materialize(chunks.zig writeCjsInteropMaterialize)
        // 한다 — 그 모듈이 *직접 import* 를 안 해도 __toESM 가 필요하다. (consumer 의 preamble 은
        // #4120 가드로 억제돼 소비자 청크 헬퍼만으론 부족.) can_skip shape 는 direct(require_X())라 제외.
        if (cjsCrossChunkDefaultNeedsToEsm(m, linker)) needs_to_esm_runtime = true;
        // (#4120) entry/dynamic 청크: CJS default 를 ESM re-export(`export { default } from cjs`)하는
        // 모듈은 buildFinalExports 가 `var _default = __toESM(require_X()).default` 를 materialize →
        // 이 청크에 __toESM 필요. named 는 require_X().m(헬퍼 불요), can_skip shape 는 direct 라 제외.
        if (moduleReExportsCjsDefaultNeedsToEsm(m, graph, linker)) needs_to_esm_runtime = true;
        // (#4510) 같은 청크 안 CJS 를 동적 import → `__toESM(require_x())` 로 재작성(same_chunk 분기).
        if (moduleInlinesDynamicCjsImport(m, graph, chunkContainsModule, chunk)) needs_to_esm_runtime = true;
        // (#4524) preserve-modules: **다른 파일**의 CJS 를 동적 import 하면 소비자가
        // `.then((m)=>__toESM(m.default))` 로 namespace 를 합성한다(chunks.zig pm_dyn_cjs)
        // → 헬퍼가 **소비자 청크**에 필요하다. same-chunk 판정을 보는 위 검사로는 못 잡는다.
        if (options.preserve_modules and moduleDynamicallyImportsCjs(m, graph)) needs_to_esm_runtime = true;
        if (m.loader == .binary) needs_to_binary = true;
        if (needs_cjs_runtime and needs_esm_wrap_runtime and needs_to_esm_runtime and needs_to_binary) break;
    }
    // (#4510/#4522) dynamic entry 청크의 CJS entry 는 `export default __toESM(require_x())` 를
    // 깐다(chunks.zig cjs_dyn_entry) — 그 모듈을 import 하는 바인딩이 이 청크에 없어도 필요.
    //
    // 술어는 provider/consumer 와 **같은 소스**(chunks.dynamicCjsNamespaceEntry)를 봐야 한다.
    // 복붙해 두면 조용히 어긋난다 — 실제로 `linker == null` 을 provider 만 보고 있었다.
    //
    // ⚠️ can_skip shape 예외를 두면 안 된다. #4510 때는 `default` **값 하나**만 실어 보내서
    // can_skip 이면 `require_x()` direct(헬퍼 불요)였지만, #4522 부터는 **namespace 통째**를
    // 보내므로 shape 와 무관하게 항상 `__toESM` 이 필요하다. 예외를 남기면 청크가
    // `ReferenceError: __toESM is not defined` 로 죽는다.
    if (chunks.dynamicCjsNamespaceEntry(chunk, graph, linker != null, options.preserve_modules) != null) {
        needs_to_esm_runtime = true;
    } else if (!options.preserve_modules and chunk.kind == .entry_point and chunk.kind.entry_point.is_dynamic) {
        // federation expose / plugin emitFile 청크는 기존 계약(`default` = module.exports 값)
        // 을 유지한다 — non can_skip shape 만 `__toESM(require_x()).default` 라 헬퍼가 필요.
        if (graph.getModule(chunk.kind.entry_point.module)) |em| {
            if (em.wrap_kind == .cjs and !em.can_skip_cjs_default_interop) needs_to_esm_runtime = true;
        }
    }
    // (#4524) `needs_to_esm_runtime` 단독도 게이트를 통과해야 한다. preserve-modules 의
    // 소비자 청크는 CJS 도 ESM-wrap 도 없는 **순수 ESM 파일**인데, 다른 파일의 CJS 를
    // 동적 import 하면 자기가 `__toESM(m.default)` 로 namespace 를 합성한다 — 예전 게이트는
    // 그 청크를 통째로 건너뛰어 `ReferenceError: __toESM is not defined` 였다.
    if (needs_cjs_runtime or needs_esm_wrap_runtime or needs_to_esm_runtime) {
        // bundle 경로와 동일 정책. chunk 의 module index 들을 graph 로 resolve 후 동일 검사.
        if (needsRequireShimForChunk(chunk, graph, options)) {
            try rt.appendRequireShim(output, allocator, options.minify_whitespace);
        }
        if (needs_cjs_runtime) {
            try rt.appendCommonJsFactoryRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
        }
        if (needs_to_esm_runtime or needs_esm_wrap_runtime) {
            try rt.appendToEsmRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
        }
    }
    if (needs_esm_wrap_runtime) {
        try rt.appendEsmWrapRuntime(output, allocator, options.minify_whitespace, options.configurable_exports);
    }
    if (options.experimental_decorators) {
        try rt.appendDecoratorRuntime(output, allocator, options.minify_whitespace);
    }
    // #1961: RuntimeHelpers 비트맵 기반 helper (es_decorator / async_helper / generator
    // 등) 는 transformer 가 graph parse 단계에서 named import 으로 emit -> graph 가 chunk
    // 분배. chunk-level prepend 는 중복 정의를 만들기 때문에 제거.
    _ = collected_helpers;
    try emitOptionPathHelpers(output, allocator, needs_to_binary, options);
}

/// `kind=.require and is_external` import_record 가 어느 모듈에든 존재하는지 — node ESM
/// 빌드의 `createRequire` shim 필요성 검사. early-exit on first match.
fn anyExternalRequire(modules: []const *const Module) bool {
    for (modules) |m| {
        for (m.import_records) |rec| {
            if (rec.kind == .require and rec.is_external) return true;
        }
    }
    return false;
}

fn needsRequireShim(modules: []const *const Module, options: *const EmitOptions) bool {
    if (options.platform != .node or options.format != .esm) return false;
    return anyExternalRequire(modules);
}

fn needsRequireShimForChunk(chunk: *const Chunk, graph: *const ModuleGraph, options: *const EmitOptions) bool {
    if (options.platform != .node or options.format != .esm) return false;
    for (chunk.modules.items) |mod_idx| {
        const m = graph.getModule(mod_idx) orelse continue;
        for (m.import_records) |rec| {
            if (rec.kind == .require and rec.is_external) return true;
        }
    }
    return false;
}
