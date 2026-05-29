//! Runtime helper emission policy for bundle and chunk outputs.

const std = @import("std");
const rt = @import("../runtime_helpers.zig");
const Module = @import("../module.zig").Module;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const Chunk = @import("../chunk.zig").Chunk;
const linker_mod = @import("../linker.zig");
const Linker = linker_mod.Linker;
const RuntimeHelpers = @import("../../transformer/runtime_helper_bits.zig").RuntimeHelpers;
const parent = @import("../emitter.zig");
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
        if (m.loader == .binary) needs_to_binary = true;
        if (needs_cjs_runtime and needs_esm_wrap_runtime and needs_to_esm_runtime and needs_to_binary) break;
    }
    if (needs_cjs_runtime or needs_esm_wrap_runtime) {
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
