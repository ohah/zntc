//! Final graph promotion/wrapping passes for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const module_mod = @import("../module.zig");
const Module = module_mod.Module;
const ModuleSemanticData = module_mod.ModuleSemanticData;
const CjsRuntimeInternalSymbolIds = @import("../module.zig").CjsRuntimeInternalSymbolIds;
const semantic_symbol = @import("../../semantic/symbol.zig");
const scope_mod = @import("../../semantic/scope.zig");
const Scope = scope_mod.Scope;
const ScopeId = scope_mod.ScopeId;
const Scanner = @import("../../lexer/scanner.zig").Scanner;
const Ast = @import("../../parser/ast.zig").Ast;
const Span = @import("../../lexer/token.zig").Span;
const runtime_helper_names = @import("../../runtime_helper_names.zig");
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;

/// 모듈의 exports_kind와 wrap_kind를 소비자에 따라 결정한다. (esbuild 모델)
/// 2-pass: require()를 먼저 처리하여 래핑을 결정하고, import는 나중에 처리.
/// - ESM 모듈 + require 소비 → WrapKind.esm (__esm 래퍼)
/// - CJS/none 모듈 + require 소비 → WrapKind.cjs (__commonJS 래퍼)
/// - .none 모듈 + import 소비 → .esm 승격 (래핑된 모듈은 변경하지 않음)
pub fn promoteExportsKinds(self: *ModuleGraph) void {
    // Pass 1: require() 소비 처리 (래핑 결정)
    // 모든 모듈의 require를 먼저 처리해야 함 — 다른 모듈의 import가
    // 같은 타겟을 ESM으로 승격시키기 전에 wrap_kind가 결정되어야 한다.
    {
        var it = self.modules.iterator(0);
        while (it.next()) |m| {
            for (m.import_records) |rec| {
                if (rec.kind != .require) continue;
                if (rec.resolved.isNone()) continue;
                const target_idx = @intFromEnum(rec.resolved);
                if (target_idx >= self.modules.count()) continue;

                var target = self.modules.at(target_idx);

                if (target.module_type == .json) {
                    target.exports_kind = .commonjs;
                    target.wrap_kind = .cjs;
                } else if (shouldUseMetroCjsForMixedModule(self, target)) {
                    // 분기 순서 invariant: mixed (`.esm_with_dynamic_fallback` +
                    // CJS export signal) 분기는 반드시 `.isEsm()` 분기보다 위에
                    // 있어야 한다 (#3141 2dfb2620). `esm_with_dynamic_fallback` 도
                    // `isEsm()==true` 라 순서가 뒤집히면 mixed 가 강제로 ESM 으로
                    // 처리되어 `module.exports =` 가 wrapper 안에서 ReferenceError.
                    target.exports_kind = .commonjs;
                    target.wrap_kind = .cjs;
                } else if (target.exports_kind.isEsm()) {
                    target.wrap_kind = .esm;
                } else {
                    target.exports_kind = .commonjs;
                    target.wrap_kind = .cjs;
                }
            }
        }
    }

    // Pass 2: import 소비 처리 (래핑 안 된 .none 모듈만 승격)
    {
        var it = self.modules.iterator(0);
        while (it.next()) |m| {
            for (m.import_records) |rec| {
                if (!rec.kind.isEagerEvalDependency()) continue;
                if (rec.resolved.isNone()) continue;
                const target_idx = @intFromEnum(rec.resolved);
                if (target_idx >= self.modules.count()) continue;

                var target = self.modules.at(target_idx);

                // 이미 래핑된 모듈은 건드리지 않음
                if (target.wrap_kind != .none) continue;

                if (target.exports_kind == .none) {
                    if (isImplicitCjs(target)) {
                        target.exports_kind = .commonjs;
                        target.wrap_kind = .cjs;
                    } else {
                        target.exports_kind = .esm;
                    }
                }
            }
        }
    }

    // Pass 2.5: 래핑된 모듈의 re_export source는 lazy 체인 보존을 위해
    // __esm 래핑 (#1340). barrel `export { default as X } from './m'` 패턴에서
    // m이 scope-hoist되면 barrel의 init body가 비고 `_default = ...` 할당이
    // 누락된다. re_export만 cascade — static_import는 binding rewrite로 해결됨.
    // wrap_kind 변경이 또 다른 모듈을 promote할 수 있어 iterative 수행.
    {
        var changed = true;
        while (changed) {
            changed = false;
            var it = self.modules.iterator(0);
            while (it.next()) |m| {
                if (m.wrap_kind == .none) continue;
                for (m.export_bindings) |eb| {
                    if (!eb.kind.isAnyReExport()) continue;
                    const rec_idx = eb.import_record_index orelse continue;
                    const target = resolveImportTarget(self, m, rec_idx) orelse continue;
                    if (promoteToEsmWrap(target)) changed = true;
                }
            }
        }
    }

    // Pass 3: 모든 ESM 모듈을 __esm 래핑 (RN + dev mode).
    // - RN: circular dep 체인에서 초기화 순서 보장 (Rolldown 호환 lazy loading)
    // - dev mode: HMR을 위해 모든 모듈이 개별 팩토리 함수로 래핑되어야 함
    //   (scope-hoisted flat 모듈은 개별 교체 불가)
    // - dev + code_splitting: 단일번들 HMR wrap-all 을 끄고 프로덕션 wrapping 을 쓴다.
    //   dev 의 cross-module init(__zntc_modules[dev_id])이 청크 경계를 못 넘기 때문(issue #4038).
    //   → entry 가 scope-hoist(.none)로 인라인 실행되어 BUG2(entry 미실행)도 함께 해소.
    // dev_split (RFC_LAZY_DEV_MODULE_HMR PR-2): dev+code_splitting+lazy_compilation 도
    // wrap-all 을 켠다 — 모듈이 개별 __esm/__commonJS factory 가 되어 글로벌
    // __zntc_modules 에 per-module 등록 가능(cross-chunk hot-replace). cross-chunk
    // static 해석은 production __zntc_require 가 담당(metadata 불변, #4038 회피).
    const dev_split = self.dev_mode and self.code_splitting and self.lazy_compilation;
    if (self.resolve_cache.platform == .react_native or (self.dev_mode and !self.code_splitting) or dev_split) {
        var it = self.modules.iterator(0);
        while (it.next()) |m| {
            if (m.wrap_kind != .none) continue;
            // 분기 순서 invariant: Pass 1 과 동일 — mixed 분기는 반드시 `.isEsm()`
            // 분기보다 위. Pass 3 의 wrap-all 로 흘러올 때도 같은 함정.
            if (shouldUseMetroCjsForMixedModule(self, m)) {
                m.exports_kind = .commonjs;
                m.wrap_kind = .cjs;
                continue;
            }
            if (!m.exports_kind.isEsm()) continue;
            // RN production: side-effect free + non-cyclic + no TLA + no re_export 모듈은
            // scope-hoist 유지. re_export 가 있는 barrel 은 wrap 필수 (#1340/#1193 —
            // barrel factory body 의 init 호출이 side-effect import 전파).
            // dev_mode 는 HMR 위해 모두 wrap (factory 단위 swap).
            if (!self.dev_mode and !m.side_effects and m.cycle_group == 0 and !m.uses_top_level_await and !m.is_context_dep and !moduleHasReExport(m)) continue;
            m.wrap_kind = .esm;
        }
    }

    // Pass 3b: require.context 매치 모듈(is_context_dep)은 런타임 `ctx(req)` 가 모듈을
    // init-call(`(init_X(),__toCommonJS(exports_X))`)로 참조하므로 **항상 wrap** 되어
    // init_X/exports_X 를 가져야 한다. Pass 3 은 dev/RN 게이트라 production·code_splitting
    // 에선 안 돌아 매치 모듈이 scope-hoist 되어 init_X 가 없었다(issue #4039 + production
    // require.context). 게이트 무관 별도 pass 로 강제 wrap.
    {
        var it = self.modules.iterator(0);
        while (it.next()) |m| {
            if (!m.is_context_dep or m.wrap_kind != .none) continue;
            m.wrap_kind = if (m.exports_kind.isEsm()) .esm else .cjs;
        }
    }

    // Pass 4: inlineDynamicImports — dynamic-import target 만 __esm 래핑.
    // 일반 모듈은 scope-hoisting 그대로, dynamic target 만 lazy factory 로
    // 묶어서 emitter 가 `import("./x")` 호출을 init/exports 호출로 재작성.
    //
    // exports_kind 검사: `.commonjs` 는 Pass 1 의 require 처리에서 이미 wrap_kind
    // =.cjs 로 set 됐어야 (require 안 받은 CJS 도 exports_kind 만 있고 .none 인
    // wrap_kind 면 여기서 wrap 안전). `.none` (script / side-effect only) 도
    // ESM lazy wrap 으로 승격해야 호출이 init() 으로 재작성됨 — 그렇지 않으면
    // codegen 의 `.none` arm fallback 으로 외부 sibling 파일 의존 (#2211 후속).
    if (self.inline_dynamic_imports) {
        var it = self.modules.iterator(0);
        while (it.next()) |m| {
            if (m.dynamic_importers.items.len == 0) continue;
            if (m.wrap_kind != .none) continue;
            if (m.exports_kind == .commonjs) continue; // Pass 1 책임
            if (m.exports_kind == .none) m.exports_kind = .esm;
            m.wrap_kind = .esm;
        }
    }

    // #4520: 여기까지가 wrap_kind 의 그래프 전역 결정. 이후 AST 변형 resync 가
    // 단일 모듈 재스캔으로 이 결과를 덮어쓰지 못하게 잠근다.
    self.wrap_kinds_finalized = true;
}

fn shouldUseMetroCjsForMixedModule(self: *ModuleGraph, module: *const Module) bool {
    return self.resolve_cache.platform == .react_native and
        module.exports_kind == .esm_with_dynamic_fallback and
        module.has_cjs_export_signal;
}

pub fn promoteRunBeforeMainModules(self: *ModuleGraph) void {
    for (self.run_before_main_files) |rbm_path| {
        const idx = self.path_to_module.get(rbm_path) orelse continue;
        const i = @intFromEnum(idx);
        if (i >= self.modules.count()) continue;
        var m = self.modules.at(i);
        if (!m.module_type.isJavaScriptLike() or m.wrap_kind != .none) continue;
        if (m.exports_kind == .none) m.exports_kind = .esm;
        if (m.exports_kind.isEsm()) m.wrap_kind = .esm;
    }
}

/// wrap_kind 확정 후 모든 래핑 모듈에 `init_<path>` + `exports_<path>` 합성
/// 심볼을 semantic 공간에 등록한다. Emitter/linker가 Module.getInitName/
/// getExportsName으로 이름을 조회해 중복 할당을 피한다.
/// OOM/semantic 누락은 그래프 빌드 오류로 전파한다. fallback 이름으로 진행하면
/// wrapper declaration/reference가 rename graph 밖에 남는다.
///
/// `makeVarNameWithPrefix` 는 path 의 마지막 `node_modules/` 이후만 사용해 이름을
/// 생성하므로, bun lockfile 처럼 `node_modules/.bun/<HASH>/node_modules/<pkg>/...`
/// 형태로 같은 패키지의 다른 hash 사본이 동시에 존재하면 두 사본의 init/exports
/// 변수 이름이 동일해진다. emitter 가 같은 변수를 두 번 선언 + 같은 export object 의
/// getter 를 두 번 정의 → 두번째가 첫번째를 덮어써서 사용처에서 undefined 참조.
/// 충돌 감지 시 `$<N>` suffix 로 deconflict.
pub fn registerWrapperSymbols(self: *ModuleGraph) !void {
    // key 들은 module 의 parse_arena (graph teardown 까지 살아있음 — `Module.deinit`
    // 까지) 에서 빌리거나 본 함수 안의 arena 에서 새로 할당. used_names 는 이 함수
    // 안에서 defer deinit 되므로 모든 키가 map 보다 오래 산다.
    var used_names: std.StringHashMapUnmanaged(u32) = .empty;
    defer used_names.deinit(self.allocator);

    // 이미 등록된 모듈 (incremental rebuild) 의 이름을 먼저 seed — 새 모듈이 같은
    // base 를 쓰면 collision 이 재발하므로. seed 후 카운터는 1 (다음 충돌 시 $2 부여).
    // base 자체가 이미 suffix 형태일 수도 있지만 contains-check 만 쓰는 uniqueName
    // 의 retry 루프로 안전하게 처리.
    var seed_it = self.modules.iterator(0);
    while (seed_it.next()) |m| {
        if (m.wrap_kind == .none) continue;
        _ = findWrapperSymbol(m, &m.init_symbol, .esm_init);
        _ = findWrapperSymbol(m, &m.exports_symbol, .cjs_exports);
        _ = findWrapperSymbol(m, &m.require_symbol, .cjs_require);
        // RFC #3940 L.4c-2a-i: mangle 전 단계 (canonical 미설정) → rt null, synthetic_name 조회.
        if (m.getInitName(null)) |n| try used_names.put(self.allocator, n, 1);
        if (m.getExportsName(null)) |n| try used_names.put(self.allocator, n, 1);
        if (m.getRequireName(null)) |n| try used_names.put(self.allocator, n, 1);
    }

    var cjs_runtime_identity_registered = false;
    var to_binary_runtime_identity_registered = false;
    var esm_runtime_identity_registered = false;
    var existing_cjs_it = self.modules.iterator(0);
    while (existing_cjs_it.next()) |m| {
        // The module that originally owned this graph-level identity can stop
        // being wrapped after an incremental rebuild. Its cached semantic row
        // still represents the same graph identity, so recover it before
        // considering a new CJS owner.
        if (findCjsRuntimeFactorySymbol(m) != null) {
            try registerCjsRuntimeFactorySymbol(m);
            cjs_runtime_identity_registered = true;
        }
        if (!to_binary_runtime_identity_registered and findBundlerRuntimeHelperSymbol(m, &m.to_binary_runtime_symbol, "__toBinary") != null) {
            try registerBundlerRuntimeHelperSymbol(m, &m.to_binary_runtime_symbol, "__toBinary");
            to_binary_runtime_identity_registered = true;
        }
        if (!esm_runtime_identity_registered and findBundlerRuntimeHelperSymbol(m, &m.esm_runtime_factory_symbol, "__esm") != null) {
            try registerBundlerRuntimeHelperSymbol(m, &m.esm_runtime_factory_symbol, "__esm");
            esm_runtime_identity_registered = true;
        }
        if (cjs_runtime_identity_registered and to_binary_runtime_identity_registered and esm_runtime_identity_registered) break;
    }
    var it = self.modules.iterator(0);
    while (it.next()) |m| {
        if (m.wrap_kind == .none) continue;
        // Runtime helpers are graph-owned symbols too. Establish the semantic
        // shell before registering them for AST-less wrappers, and reject an
        // AST-bearing module whose analysis data disappeared.
        if (m.semantic == null) {
            if (m.ast != null) return error.MissingSemantic;
            try ensureSyntheticModuleSemantic(self, m);
        }
        if (m.wrap_kind == .cjs) {
            try registerCjsWrapperParameters(m);
            if (!cjs_runtime_identity_registered and m.ast != null) {
                try registerCjsRuntimeFactorySymbol(m);
                cjs_runtime_identity_registered = true;
            }
        }
        if (m.wrap_kind == .esm and !esm_runtime_identity_registered and m.ast != null) {
            try registerBundlerRuntimeHelperSymbol(m, &m.esm_runtime_factory_symbol, "__esm");
            esm_runtime_identity_registered = true;
        }
        const needs_init = (m.ast != null or m.wrap_kind == .esm) and m.init_symbol == null;
        const needs_exports = (m.ast != null or m.wrap_kind == .esm) and m.exports_symbol == null;
        const needs_require = m.wrap_kind == .cjs and m.require_symbol == null;
        if (!needs_init and !needs_exports and !needs_require) continue;

        const arena = if (m.parse_arena) |a| a.allocator() else return error.OutOfMemory;
        const sem_ptr = if (m.semantic) |*s| s else return error.MissingSemantic;

        if (needs_init) {
            const init_base = try types.makeInitVarName(arena, m.path);
            const init_name = try uniqueName(arena, init_base, &used_names, self.allocator);
            m.init_symbol = semantic_symbol.extendSymbol(
                arena,
                &sem_ptr.symbols,
                .function_decl,
                .esm_init,
                init_name,
                Span.EMPTY,
            ) catch return error.OutOfMemory;
        }

        if (needs_exports) {
            const exports_base = try types.makeExportsVarName(arena, m.path);
            const exports_name = try uniqueName(arena, exports_base, &used_names, self.allocator);
            m.exports_symbol = semantic_symbol.extendSymbol(
                arena,
                &sem_ptr.symbols,
                .variable_var,
                .cjs_exports,
                exports_name,
                Span.EMPTY,
            ) catch return error.OutOfMemory;
        }

        if (needs_require) {
            const require_base = try types.makeRequireVarName(arena, m.path);
            const require_name = try uniqueName(arena, require_base, &used_names, self.allocator);
            m.require_symbol = semantic_symbol.extendSymbol(
                arena,
                &sem_ptr.symbols,
                .function_decl,
                .cjs_require,
                require_name,
                Span.EMPTY,
            ) catch return error.OutOfMemory;
        }
    }

    // If the graph still contains parsed JavaScript, anchor the graph-level
    // runtime factory identity to a parsed module. For an entirely generated
    // graph, reuse an AST-less module's synthetic semantic shell so the factory
    // still has a normal SymbolID owner.
    if (!cjs_runtime_identity_registered) {
        var has_cjs_wrapper = false;
        var cjs_it = self.modules.iterator(0);
        while (cjs_it.next()) |m| {
            if (m.wrap_kind == .cjs) {
                has_cjs_wrapper = true;
                break;
            }
        }
        if (has_cjs_wrapper) {
            var semantic_it = self.modules.iterator(0);
            while (semantic_it.next()) |m| {
                if (m.ast == null or m.semantic == null or m.parse_arena == null) continue;
                try registerCjsRuntimeFactorySymbol(m);
                cjs_runtime_identity_registered = true;
                break;
            }
            if (!cjs_runtime_identity_registered) {
                var synthetic_it = self.modules.iterator(0);
                while (synthetic_it.next()) |m| {
                    if (m.ast != null) continue;
                    try ensureSyntheticModuleSemantic(self, m);
                    try registerCjsRuntimeFactorySymbol(m);
                    cjs_runtime_identity_registered = true;
                    break;
                }
            }
            if (!cjs_runtime_identity_registered) return error.MissingRuntimeHelperSymbol;
        }
    }

    // Binary loader modules are semantic-less and their call expression is
    // generated from asset bytes. Anchor the shared preamble/call identity to
    // parsed semantics when available, or to an AST-less module's synthetic
    // semantic shell in an entirely generated graph.
    if (!to_binary_runtime_identity_registered) {
        var has_binary_asset = false;
        var binary_it = self.modules.iterator(0);
        while (binary_it.next()) |m| {
            if (m.loader == .binary and m.source.len > 0) {
                has_binary_asset = true;
                break;
            }
        }
        if (has_binary_asset) {
            var semantic_it = self.modules.iterator(0);
            while (semantic_it.next()) |m| {
                if (m.ast == null or m.semantic == null or m.parse_arena == null) continue;
                try registerBundlerRuntimeHelperSymbol(m, &m.to_binary_runtime_symbol, "__toBinary");
                to_binary_runtime_identity_registered = true;
                break;
            }
            if (!to_binary_runtime_identity_registered) {
                var synthetic_binary_it = self.modules.iterator(0);
                while (synthetic_binary_it.next()) |m| {
                    if (m.loader != .binary or m.source.len == 0 or m.ast != null) continue;
                    try ensureSyntheticModuleSemantic(self, m);
                    try registerBundlerRuntimeHelperSymbol(m, &m.to_binary_runtime_symbol, "__toBinary");
                    to_binary_runtime_identity_registered = true;
                    break;
                }
            }
            if (!to_binary_runtime_identity_registered) return error.MissingRuntimeHelperSymbol;
        }
    }

    // ESM wrappers can be emitted from semantic-less modules in plugin or
    // incremental paths. Anchor their graph-level factory identity to parsed
    // semantics when available, or use an AST-less module's synthetic semantic
    // shell in an entirely generated graph.
    if (!esm_runtime_identity_registered) {
        var has_esm_wrapper = false;
        var esm_it = self.modules.iterator(0);
        while (esm_it.next()) |m| {
            if (m.wrap_kind == .esm) {
                has_esm_wrapper = true;
                break;
            }
        }
        if (has_esm_wrapper) {
            var semantic_it = self.modules.iterator(0);
            while (semantic_it.next()) |m| {
                if (m.ast == null or m.semantic == null or m.parse_arena == null) continue;
                try registerBundlerRuntimeHelperSymbol(m, &m.esm_runtime_factory_symbol, "__esm");
                esm_runtime_identity_registered = true;
                break;
            }
            if (!esm_runtime_identity_registered) {
                var synthetic_it = self.modules.iterator(0);
                while (synthetic_it.next()) |m| {
                    if (m.ast != null) continue;
                    try ensureSyntheticModuleSemantic(self, m);
                    try registerBundlerRuntimeHelperSymbol(m, &m.esm_runtime_factory_symbol, "__esm");
                    esm_runtime_identity_registered = true;
                    break;
                }
            }
            if (!esm_runtime_identity_registered) return error.MissingRuntimeHelperSymbol;
        }
    }
}

/// Runtime helpers and wrappers can be emitted for modules without source ASTs
/// (for example, assets and disabled modules). Keep their virtual symbols in
/// the usual module-owned semantic storage without pretending that the module
/// has source scopes or an AST. `parse_arena` owns the symbol array, matching
/// ordinary semantic data and its incremental lifetime.
fn ensureSyntheticModuleSemantic(graph: *ModuleGraph, m: *Module) !void {
    if (m.semantic != null) return;
    if (m.ast != null) return error.MissingSemantic;
    if (m.parse_arena == null) {
        m.parse_arena = module_mod.createParseArena(graph.allocator) orelse return error.OutOfMemory;
    }
    m.semantic = .{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
}

fn findWrapperSymbol(
    m: *Module,
    identity: *?semantic_symbol.SymbolId,
    expected_kind: semantic_symbol.SyntheticKind,
) ?semantic_symbol.SymbolId {
    const sem = if (m.semantic) |*value| value else {
        identity.* = null;
        return null;
    };
    if (identity.*) |existing| {
        const raw: usize = @intFromEnum(existing);
        if (raw < sem.symbols.items.len and sem.symbols.items[raw].synthetic_kind == expected_kind) return existing;
        identity.* = null;
    }
    for (sem.symbols.items, 0..) |symbol, index| {
        if (symbol.synthetic_kind != expected_kind) continue;
        identity.* = @enumFromInt(index);
        return identity.*;
    }
    return null;
}

fn registerBundlerRuntimeHelperSymbol(m: *Module, identity: *?semantic_symbol.SymbolId, name: []const u8) !void {
    const sem = if (m.semantic) |*value| value else return error.MissingSemantic;
    const arena = if (m.parse_arena) |value| value.allocator() else return error.MissingSemantic;
    if (findBundlerRuntimeHelperSymbol(m, identity, name) == null) {
        identity.* = semantic_symbol.extendSymbol(
            arena,
            &sem.symbols,
            .variable_var,
            .bundler_runtime_helper,
            name,
            Span.EMPTY,
        ) catch return error.OutOfMemory;
    }
    if (findBundlerRuntimeHelperSymbol(m, identity, name) == null) return error.MissingRuntimeHelperSymbol;
    if (std.mem.eql(u8, name, "__esm")) try registerEsmRuntimeInternalSymbols(m, sem, arena);
}

fn registerEsmRuntimeInternalSymbols(m: *Module, sem: *ModuleSemanticData, arena: std.mem.Allocator) !void {
    const names: runtime_helper_names.EsmRuntimeInternalNames = .{};
    const existing = m.esm_runtime_internal_symbols;
    m.esm_runtime_internal_symbols = .{
        .factory_parameter = try ensureEsmRuntimeInternalSymbol(sem, arena, if (existing) |ids| ids.factory_parameter else null, names.factory_parameter, .parameter),
        .result_parameter = try ensureEsmRuntimeInternalSymbol(sem, arena, if (existing) |ids| ids.result_parameter else null, names.result_parameter, .parameter),
        .catch_parameter = try ensureEsmRuntimeInternalSymbol(sem, arena, if (existing) |ids| ids.catch_parameter else null, names.catch_parameter, .catch_binding),
        .init_function = try ensureEsmRuntimeInternalSymbol(sem, arena, if (existing) |ids| ids.init_function else null, names.init_function, .function_decl),
        .factory_local = try ensureEsmRuntimeInternalSymbol(sem, arena, if (existing) |ids| ids.factory_local else null, names.factory_local, .variable_var),
    };
}

fn ensureEsmRuntimeInternalSymbol(
    sem: *ModuleSemanticData,
    arena: std.mem.Allocator,
    existing: ?semantic_symbol.SymbolId,
    name: []const u8,
    kind: semantic_symbol.SymbolKind,
) !semantic_symbol.SymbolId {
    if (existing) |symbol_id| {
        const raw: usize = @intFromEnum(symbol_id);
        if (raw < sem.symbols.items.len) {
            const symbol = sem.symbols.items[raw];
            if (symbol.synthetic_kind == .esm_runtime_internal_local and symbol.kind == kind and std.mem.eql(u8, symbol.synthetic_name, name)) return symbol_id;
        }
    }
    for (sem.symbols.items, 0..) |symbol, index| {
        if (symbol.synthetic_kind != .esm_runtime_internal_local or symbol.kind != kind or !std.mem.eql(u8, symbol.synthetic_name, name)) continue;
        return @enumFromInt(index);
    }
    return try semantic_symbol.extendSymbol(arena, &sem.symbols, kind, .esm_runtime_internal_local, name, Span.EMPTY);
}

fn findBundlerRuntimeHelperSymbol(m: *Module, identity: *?semantic_symbol.SymbolId, name: []const u8) ?semantic_symbol.SymbolId {
    const sem = if (m.semantic) |*value| value else return null;
    if (identity.*) |existing| {
        const raw: usize = @intFromEnum(existing);
        if (raw < sem.symbols.items.len) {
            const symbol = sem.symbols.items[raw];
            if (symbol.synthetic_kind == .bundler_runtime_helper and
                std.mem.eql(u8, symbol.synthetic_name, name)) return existing;
        }
        identity.* = null;
    }
    for (sem.symbols.items, 0..) |symbol, index| {
        if (symbol.synthetic_kind != .bundler_runtime_helper or
            !std.mem.eql(u8, symbol.synthetic_name, name)) continue;
        identity.* = @enumFromInt(index);
        return identity.*;
    }
    return null;
}

/// Add a semantic identity for the graph-level CJS runtime factory. The helper
/// body and wrapper callsites are emitted outside source AST nodes, so this is
/// a virtual bundler symbol like the other wrapper symbols. The cached semantic
/// row remains the graph identity if its original module stops being CJS.
fn registerCjsRuntimeFactorySymbol(m: *Module) !void {
    const sem = if (m.semantic) |*value| value else return error.MissingSemantic;
    const arena = if (m.parse_arena) |value| value.allocator() else return error.MissingSemantic;
    if (findCjsRuntimeFactorySymbol(m) == null) {
        m.cjs_runtime_factory_symbol = semantic_symbol.extendSymbol(
            arena,
            &sem.symbols,
            .variable_var,
            .cjs_runtime_factory,
            "__commonJS",
            Span.EMPTY,
        ) catch return error.OutOfMemory;
    }
    if (m.cjs_runtime_factory_symbol == null) return error.MissingRuntimeHelperSymbol;

    const names: runtime_helper_names.CjsRuntimeInternalNames = .{};
    const callback_parameter = ensureCjsRuntimeInternalSymbol(
        sem,
        arena,
        if (m.cjs_runtime_internal_symbols) |ids| ids.callback_parameter else null,
        names.callback_parameter,
        .parameter,
    ) catch return error.OutOfMemory;
    const module_parameter = ensureCjsRuntimeInternalSymbol(
        sem,
        arena,
        if (m.cjs_runtime_internal_symbols) |ids| ids.module_parameter else null,
        names.module_parameter,
        .parameter,
    ) catch return error.OutOfMemory;
    const catch_parameter = ensureCjsRuntimeInternalSymbol(
        sem,
        arena,
        if (m.cjs_runtime_internal_symbols) |ids| ids.catch_parameter else null,
        names.catch_parameter,
        .catch_binding,
    ) catch return error.OutOfMemory;
    const require_function = ensureCjsRuntimeInternalSymbol(
        sem,
        arena,
        if (m.cjs_runtime_internal_symbols) |ids| ids.require_function else null,
        names.require_function,
        .function_decl,
    ) catch return error.OutOfMemory;
    m.cjs_runtime_internal_symbols = .{
        .callback_parameter = callback_parameter,
        .module_parameter = module_parameter,
        .catch_parameter = catch_parameter,
        .require_function = require_function,
    };
}

fn ensureCjsRuntimeInternalSymbol(
    sem: *ModuleSemanticData,
    arena: std.mem.Allocator,
    existing: ?semantic_symbol.SymbolId,
    name: []const u8,
    kind: semantic_symbol.SymbolKind,
) !semantic_symbol.SymbolId {
    if (existing) |symbol_id| {
        const raw: usize = @intFromEnum(symbol_id);
        if (raw < sem.symbols.items.len) {
            const symbol = sem.symbols.items[raw];
            if (symbol.synthetic_kind == .cjs_runtime_internal_local and symbol.kind == kind and std.mem.eql(u8, symbol.synthetic_name, name)) {
                return symbol_id;
            }
        }
    }
    for (sem.symbols.items, 0..) |symbol, index| {
        if (symbol.synthetic_kind != .cjs_runtime_internal_local or symbol.kind != kind or !std.mem.eql(u8, symbol.synthetic_name, name)) continue;
        return @enumFromInt(index);
    }
    return try semantic_symbol.extendSymbol(
        arena,
        &sem.symbols,
        kind,
        .cjs_runtime_internal_local,
        name,
        Span.EMPTY,
    );
}

fn findCjsRuntimeFactorySymbol(m: *Module) ?semantic_symbol.SymbolId {
    const sem = if (m.semantic) |*value| value else return null;
    if (m.cjs_runtime_factory_symbol) |existing| {
        const raw: usize = @intFromEnum(existing);
        if (raw < sem.symbols.items.len and sem.symbols.items[raw].synthetic_kind == .cjs_runtime_factory) return existing;
        m.cjs_runtime_factory_symbol = null;
    }
    for (sem.symbols.items, 0..) |symbol, index| {
        if (symbol.synthetic_kind != .cjs_runtime_factory) continue;
        m.cjs_runtime_factory_symbol = @enumFromInt(index);
        return m.cjs_runtime_factory_symbol;
    }
    return null;
}

/// Register the implicit callback scope and its two CommonJS parameter bindings.
/// The parsed Program scope remains the body scope, with the emitted callback
/// function scope as its parent. `scope_maps[0]` keeps its historical module
/// lookup entries; parent bindings are also present in the callback scope map.
fn registerCjsWrapperParameters(m: *Module) !void {
    const sem_ptr = if (m.semantic) |*sem| sem else return error.MissingSemantic;
    const arena = if (m.parse_arena) |a| a.allocator() else return error.MissingSemantic;

    // AST-less CJS wrappers have no body scope tree. Keep their output
    // identities detached; the parsed path below always assigns a real scope.
    const ast_ptr = if (m.ast) |*ast| ast else {
        const existing_exports = findCjsWrapperParameter(sem_ptr.symbols.items, .cjs_wrapper_exports_parameter, "exports");
        const existing_module = findCjsWrapperParameter(sem_ptr.symbols.items, .cjs_wrapper_module_parameter, "module");
        const new_symbol_count: usize = @as(usize, @intFromBool(existing_exports == null)) +
            @as(usize, @intFromBool(existing_module == null));
        try sem_ptr.symbols.ensureUnusedCapacity(arena, new_symbol_count);
        const old_symbol_count = sem_ptr.symbols.items.len;
        m.cjs_wrapper_exports_parameter_symbol = existing_exports orelse try addDetachedCjsWrapperParameter(
            sem_ptr,
            arena,
            "exports",
            .cjs_wrapper_exports_parameter,
        );
        m.cjs_wrapper_module_parameter_symbol = existing_module orelse try addDetachedCjsWrapperParameter(
            sem_ptr,
            arena,
            "module",
            .cjs_wrapper_module_parameter,
        );
        if (new_symbol_count > 0) extendCachedRefDeltas(arena, m, old_symbol_count, sem_ptr.symbols.items.len);
        return;
    };
    if (sem_ptr.scopes.len == 0 or sem_ptr.scope_maps.len != sem_ptr.scopes.len) return error.MissingSemantic;

    const wrapper_scope = try ensureCjsWrapperParameterScope(sem_ptr, arena);
    const wrapper_scope_raw: usize = @intFromEnum(wrapper_scope);
    const root_scope_ptr = @constCast(&sem_ptr.scopes[0]);
    const wrapper_scope_ptr = @constCast(&sem_ptr.scopes[wrapper_scope_raw]);
    const root_map = @constCast(&sem_ptr.scope_maps[0]);
    const wrapper_map = @constCast(&sem_ptr.scope_maps[wrapper_scope_raw]);

    const exports_conflict = hasIncompatibleCjsRootBinding(sem_ptr, ast_ptr, "exports", .cjs_wrapper_exports_parameter);
    const module_conflict = hasIncompatibleCjsRootBinding(sem_ptr, ast_ptr, "module", .cjs_wrapper_module_parameter);
    const existing_exports = if (exports_conflict)
        findCjsWrapperParameter(sem_ptr.symbols.items, .cjs_wrapper_exports_parameter, "exports")
    else
        cjsRootBinding(sem_ptr, ast_ptr, "exports", .cjs_wrapper_exports_parameter);
    const existing_module = if (module_conflict)
        findCjsWrapperParameter(sem_ptr.symbols.items, .cjs_wrapper_module_parameter, "module")
    else
        cjsRootBinding(sem_ptr, ast_ptr, "module", .cjs_wrapper_module_parameter);
    if (existing_exports != null and existing_exports == existing_module) return error.CjsWrapperParameterIdentityCollision;

    const new_symbol_count: usize = @as(usize, @intFromBool(existing_exports == null)) +
        @as(usize, @intFromBool(existing_module == null));
    const new_root_map_count: usize = @as(usize, @intFromBool(!exports_conflict and !root_map.contains("exports"))) +
        @as(usize, @intFromBool(!module_conflict and !root_map.contains("module")));
    const new_wrapper_map_count: usize = @as(usize, @intFromBool(!wrapper_map.contains("exports"))) +
        @as(usize, @intFromBool(!wrapper_map.contains("module")));
    const wrapper_owner_count: usize =
        @as(usize, @intFromBool(existing_exports == null or sem_ptr.symbols.items[@intFromEnum(existing_exports.?)].scope_id != wrapper_scope)) +
        @as(usize, @intFromBool(existing_module == null or sem_ptr.symbols.items[@intFromEnum(existing_module.?)].scope_id != wrapper_scope));
    const root_move_count: usize =
        @as(usize, @intFromBool(existing_exports != null and sem_ptr.symbols.items[@intFromEnum(existing_exports.?)].scope_id == @as(ScopeId, @enumFromInt(0)))) +
        @as(usize, @intFromBool(existing_module != null and sem_ptr.symbols.items[@intFromEnum(existing_module.?)].scope_id == @as(ScopeId, @enumFromInt(0))));
    if (wrapper_owner_count > 0 and @as(usize, wrapper_scope_ptr.symbol_count) > std.math.maxInt(u16) - wrapper_owner_count) {
        return error.CjsWrapperParameterScopeOverflow;
    }
    if (root_move_count > @as(usize, root_scope_ptr.symbol_count)) return error.CjsWrapperParameterScopeMismatch;

    // Reserve both parameter maps before publishing any binding. The root map
    // remains a compatibility lookup for no-conflict callback names; conflicting
    // source lexical bindings keep their original root entries.
    try sem_ptr.symbols.ensureUnusedCapacity(arena, new_symbol_count);
    try root_map.ensureUnusedCapacity(arena, @intCast(new_root_map_count));
    try wrapper_map.ensureUnusedCapacity(arena, @intCast(new_wrapper_map_count));

    const old_symbol_count = sem_ptr.symbols.items.len;
    const exports_symbol = existing_exports orelse try addCjsWrapperParameter(
        sem_ptr,
        arena,
        "exports",
        .cjs_wrapper_exports_parameter,
    );
    const module_symbol = existing_module orelse try addCjsWrapperParameter(
        sem_ptr,
        arena,
        "module",
        .cjs_wrapper_module_parameter,
    );
    try attachCjsWrapperParameter(sem_ptr, root_scope_ptr, wrapper_scope_ptr, root_map, wrapper_map, wrapper_scope, exports_symbol, "exports");
    try attachCjsWrapperParameter(sem_ptr, root_scope_ptr, wrapper_scope_ptr, root_map, wrapper_map, wrapper_scope, module_symbol, "module");

    // Keep the historic module-root lookup for parameters that are visible
    // without a lexical source binding. Conflicting body locals remain mapped
    // only in the body scope and shadow their callback parameter normally.
    if (!exports_conflict) {
        const raw: usize = @intFromEnum(exports_symbol);
        if (root_map.get("exports")) |existing| {
            if (existing != raw) return error.CjsWrapperParameterScopeMismatch;
        } else root_map.putAssumeCapacity("exports", raw);
    }
    if (!module_conflict) {
        const raw: usize = @intFromEnum(module_symbol);
        if (root_map.get("module")) |existing| {
            if (existing != raw) return error.CjsWrapperParameterScopeMismatch;
        } else root_map.putAssumeCapacity("module", raw);
    }

    try validateCjsWrapperParameterScope(
        sem_ptr,
        ast_ptr,
        wrapper_scope,
        exports_symbol,
        module_symbol,
        exports_conflict,
        module_conflict,
    );

    const exports_reference_symbol = if (exports_conflict)
        cjsRootBinding(sem_ptr, ast_ptr, "exports", .cjs_wrapper_exports_parameter) orelse return error.CjsWrapperSourceBindingMissing
    else
        exports_symbol;
    const module_reference_symbol = if (module_conflict)
        cjsRootBinding(sem_ptr, ast_ptr, "module", .cjs_wrapper_module_parameter) orelse return error.CjsWrapperSourceBindingMissing
    else
        module_symbol;
    const explicit_globals = if (m.transform_cache) |cache| cache.explicit_global_ref_nodes else &.{};
    const cache_symbol_ids: ?[]?u32 = if (m.transform_cache) |cache| @constCast(cache.symbol_ids) else null;

    // Parser semantic analysis predates the CJS wrapper environment. Resolve
    // only references that remain unresolved in the exact AST/SymbolId table;
    // nested source bindings and explicit globals therefore keep their IDs.
    const bound_refs = bindCjsWrapperReferences(
        ast_ptr,
        @constCast(sem_ptr.symbol_ids),
        cache_symbol_ids,
        &sem_ptr.symbols,
        explicit_globals,
        exports_reference_symbol,
        module_reference_symbol,
    );
    if (!bound_refs.has_unbound_exports) {
        _ = sem_ptr.unresolved_references.remove("exports");
    }
    if (!bound_refs.has_unbound_module) {
        _ = sem_ptr.unresolved_references.remove("module");
    }

    if (new_symbol_count > 0) extendCachedRefDeltas(arena, m, old_symbol_count, sem_ptr.symbols.items.len);

    m.cjs_wrapper_exports_parameter_symbol = exports_symbol;
    m.cjs_wrapper_module_parameter_symbol = module_symbol;
}

fn ensureCjsWrapperParameterScope(sem: *ModuleSemanticData, allocator: std.mem.Allocator) !ScopeId {
    if (sem.scopes.len == 0 or sem.scope_maps.len != sem.scopes.len) return error.MissingSemantic;
    const root_parent = sem.scopes[0].parent;
    if (!root_parent.isNone()) {
        const parent_raw: usize = @intFromEnum(root_parent);
        if (parent_raw >= sem.scopes.len or sem.scopes[parent_raw].kind != .function or
            !sem.scopes[parent_raw].parent.isNone()) return error.InvalidCjsWrapperParameterScope;
        return root_parent;
    }
    if (sem.scopes.len >= @as(usize, std.math.maxInt(u32))) return error.CjsWrapperParameterScopeOverflow;

    const old_len = sem.scopes.len;
    const new_len = old_len + 1;
    const wrapper_scope: ScopeId = @enumFromInt(@as(u32, @intCast(old_len)));
    const source_root = sem.scopes[0];
    const scopes = try allocator.alloc(Scope, new_len);
    @memcpy(scopes[0..old_len], sem.scopes);
    scopes[0].parent = wrapper_scope;
    scopes[old_len] = .{
        .parent = .none,
        .kind = .function,
        .is_strict = source_root.is_strict,
        .subtree_has_direct_eval = source_root.subtree_has_direct_eval,
        .subtree_has_with = source_root.subtree_has_with,
    };
    const maps = try allocator.alloc(std.StringHashMapUnmanaged(usize), new_len);
    @memcpy(maps[0..old_len], sem.scope_maps);
    maps[old_len] = .empty;
    sem.scopes = scopes;
    sem.scope_maps = maps;
    return wrapper_scope;
}

fn cjsRootBinding(
    sem: *const @import("../module.zig").ModuleSemanticData,
    ast: *const @import("../../parser/ast.zig").Ast,
    name: []const u8,
    kind: semantic_symbol.SyntheticKind,
) ?semantic_symbol.SymbolId {
    var bindings = sem.scope_maps[0].valueIterator();
    while (bindings.next()) |raw_ptr| {
        const raw = raw_ptr.*;
        if (raw < sem.symbols.items.len and cjsWrapperIdentifierEquals(sem.symbols.items[raw].nameText(ast.source), name)) {
            return @enumFromInt(@as(u32, @intCast(raw)));
        }
    }
    return findCjsWrapperParameter(sem.symbols.items, kind, name);
}

fn hasIncompatibleCjsRootBinding(
    sem: *const @import("../module.zig").ModuleSemanticData,
    ast: *const @import("../../parser/ast.zig").Ast,
    name: []const u8,
    kind: semantic_symbol.SyntheticKind,
) bool {
    var bindings = sem.scope_maps[0].valueIterator();
    while (bindings.next()) |raw_ptr| {
        const raw = raw_ptr.*;
        if (raw >= sem.symbols.items.len) continue;
        const symbol = sem.symbols.items[raw];
        if (!cjsWrapperIdentifierEquals(symbol.nameText(ast.source), name)) continue;
        if (symbol.synthetic_kind == kind) return false;
        return symbol.kind != .variable_var and !symbol.kind.isFunctionLike();
    }
    return false;
}

fn cjsWrapperIdentifierEquals(raw: []const u8, expected: []const u8) bool {
    var scratch: [7]u8 = undefined;
    return expected.len <= scratch.len and Scanner.identifierTextEqualsAscii(raw, expected, scratch[0..expected.len]);
}

fn addCjsWrapperParameter(
    sem: *@import("../module.zig").ModuleSemanticData,
    allocator: std.mem.Allocator,
    name: []const u8,
    kind: semantic_symbol.SyntheticKind,
) !semantic_symbol.SymbolId {
    return semantic_symbol.extendSymbol(
        allocator,
        &sem.symbols,
        .parameter,
        kind,
        name,
        Span.EMPTY,
    );
}

fn addDetachedCjsWrapperParameter(
    sem: *@import("../module.zig").ModuleSemanticData,
    allocator: std.mem.Allocator,
    name: []const u8,
    kind: semantic_symbol.SyntheticKind,
) !semantic_symbol.SymbolId {
    return semantic_symbol.extendSymbol(
        allocator,
        &sem.symbols,
        .parameter,
        kind,
        name,
        Span.EMPTY,
    );
}

fn attachCjsWrapperParameter(
    sem: *@import("../module.zig").ModuleSemanticData,
    root_scope: *Scope,
    wrapper_scope: *Scope,
    root_map: *std.StringHashMapUnmanaged(usize),
    wrapper_map: *std.StringHashMapUnmanaged(usize),
    wrapper_scope_id: ScopeId,
    id: semantic_symbol.SymbolId,
    name: []const u8,
) !void {
    const raw: usize = @intFromEnum(id);
    if (raw >= sem.symbols.items.len) return error.InvalidCjsWrapperParameterSymbol;
    const symbol = &sem.symbols.items[raw];
    if (wrapper_map.get(name)) |existing| {
        if (existing != raw) return error.CjsWrapperParameterScopeMismatch;
    } else {
        wrapper_map.putAssumeCapacity(name, raw);
    }

    if (symbol.scope_id == wrapper_scope_id) return;
    if (symbol.scope_id == @as(ScopeId, @enumFromInt(0))) {
        if (!scopeMapContainsIdentifier(root_map, name, raw)) {
            return error.CjsWrapperParameterScopeMismatch;
        }
        if (root_scope.symbol_count == 0) return error.CjsWrapperParameterScopeMismatch;
        root_scope.symbol_count -= 1;
    } else if (symbol.scope_id.isNone()) {
        symbol.origin_scope = wrapper_scope_id;
    } else {
        return error.CjsWrapperParameterScopeMismatch;
    }
    symbol.scope_id = wrapper_scope_id;
    wrapper_scope.symbol_count += 1;
}

fn scopeMapContainsIdentifier(
    map: *const std.StringHashMapUnmanaged(usize),
    name: []const u8,
    raw_symbol_id: usize,
) bool {
    var found = false;
    var entries = map.iterator();
    while (entries.next()) |entry| {
        if (!cjsWrapperIdentifierEquals(entry.key_ptr.*, name)) continue;
        if (entry.value_ptr.* != raw_symbol_id) return false;
        found = true;
    }
    return found;
}

fn validateCjsWrapperParameterScope(
    sem: *const ModuleSemanticData,
    ast: *const @import("../../parser/ast.zig").Ast,
    wrapper_scope_id: ScopeId,
    exports_id: semantic_symbol.SymbolId,
    module_id: semantic_symbol.SymbolId,
    exports_conflict: bool,
    module_conflict: bool,
) !void {
    if (sem.scopes.len == 0 or sem.scope_maps.len != sem.scopes.len or wrapper_scope_id.isNone())
        return error.CjsWrapperParameterScopeMismatch;
    const wrapper_raw: usize = @intFromEnum(wrapper_scope_id);
    if (wrapper_raw >= sem.scopes.len or sem.scopes[0].parent != wrapper_scope_id) return error.CjsWrapperParameterScopeMismatch;
    const wrapper_scope = sem.scopes[wrapper_raw];
    if (wrapper_scope.kind != .function or !wrapper_scope.parent.isNone() or wrapper_scope.symbol_count != 2)
        return error.CjsWrapperParameterScopeMismatch;
    if (exports_id == module_id) return error.CjsWrapperParameterIdentityCollision;

    const params = .{
        .{ .id = exports_id, .name = "exports", .kind = semantic_symbol.SyntheticKind.cjs_wrapper_exports_parameter, .conflict = exports_conflict },
        .{ .id = module_id, .name = "module", .kind = semantic_symbol.SyntheticKind.cjs_wrapper_module_parameter, .conflict = module_conflict },
    };
    inline for (params) |param| {
        const raw: usize = @intFromEnum(param.id);
        if (raw >= sem.symbols.items.len or sem.scope_maps[wrapper_raw].get(param.name) != raw)
            return error.CjsWrapperParameterScopeMismatch;
        const symbol = sem.symbols.items[raw];
        if (symbol.scope_id != wrapper_scope_id) return error.CjsWrapperParameterScopeMismatch;
        if (symbol.synthetic_kind) |synthetic_kind| {
            if (synthetic_kind != param.kind or symbol.kind != .parameter) return error.CjsWrapperParameterScopeMismatch;
        } else if (symbol.kind != .variable_var and !symbol.kind.isFunctionLike()) {
            return error.CjsWrapperParameterScopeMismatch;
        }

        if (param.conflict) {
            const source_id = cjsRootBinding(sem, ast, param.name, param.kind) orelse return error.CjsWrapperParameterScopeMismatch;
            if (source_id == param.id) return error.CjsWrapperParameterScopeMismatch;
            const source_raw: usize = @intFromEnum(source_id);
            if (source_raw >= sem.symbols.items.len or sem.symbols.items[source_raw].scope_id != @as(ScopeId, @enumFromInt(0)))
                return error.CjsWrapperParameterScopeMismatch;
        } else if (!scopeMapContainsIdentifier(&sem.scope_maps[0], param.name, raw)) {
            return error.CjsWrapperParameterScopeMismatch;
        }
    }
}

fn findCjsWrapperParameter(
    symbols: []const semantic_symbol.Symbol,
    kind: semantic_symbol.SyntheticKind,
    name: []const u8,
) ?semantic_symbol.SymbolId {
    for (symbols, 0..) |symbol, raw| {
        if (symbol.synthetic_kind != kind or !std.mem.eql(u8, symbol.synthetic_name, name)) continue;
        return @enumFromInt(@as(u32, @intCast(raw)));
    }
    return null;
}

const CjsWrapperBindings = struct {
    has_unbound_exports: bool = false,
    has_unbound_module: bool = false,
};

fn bindCjsWrapperReferences(
    ast: *const @import("../../parser/ast.zig").Ast,
    symbol_ids: []?u32,
    cache_symbol_ids: ?[]?u32,
    symbols: *std.ArrayList(semantic_symbol.Symbol),
    explicit_global_ref_nodes: []const u32,
    exports_symbol: ?semantic_symbol.SymbolId,
    module_symbol: ?semantic_symbol.SymbolId,
) CjsWrapperBindings {
    var result: CjsWrapperBindings = .{};
    var exports_bound_count: u32 = 0;
    var module_bound_count: u32 = 0;
    for (ast.nodes.items, 0..) |node, raw| {
        var reference_raw = raw;
        var name: []const u8 = "";
        switch (node.tag) {
            .identifier_reference, .assignment_target_identifier => name = ast.getText(node.data.string_ref),
            .jsx_identifier => {
                name = ast.getSourceText(node.span);
                if (name.len == 0 or std.ascii.isLower(name[0])) continue;
            },
            .jsx_member_expression => {
                var root_idx = node.data.binary.left;
                while (ast.getNode(root_idx).tag == .jsx_member_expression) {
                    root_idx = ast.getNode(root_idx).data.binary.left;
                }
                const root = ast.getNode(root_idx);
                if (root.tag != .jsx_identifier) continue;
                reference_raw = @intFromEnum(root_idx);
                name = ast.getSourceText(root.span);
            },
            else => continue,
        }
        const is_exports = std.mem.eql(u8, name, "exports");
        const is_module = std.mem.eql(u8, name, "module");
        const symbol_id = if (is_exports) exports_symbol else if (is_module) module_symbol else null;
        const id = symbol_id orelse continue;
        if (reference_raw >= symbol_ids.len) {
            if (is_exports) result.has_unbound_exports = true else result.has_unbound_module = true;
            continue;
        }
        if (containsSortedNode(explicit_global_ref_nodes, @intCast(reference_raw))) {
            if (is_exports) result.has_unbound_exports = true else result.has_unbound_module = true;
            continue;
        }
        const raw_id = @intFromEnum(id);
        if (symbol_ids[reference_raw]) |existing_raw| {
            if (existing_raw == raw_id) continue;
            if (existing_raw >= symbols.items.len or raw_id >= symbols.items.len) continue;

            // A previous wrapper-registration pass may have attached this
            // unresolved source reference to the callback parameter before a
            // canonical escaped lexical binding was recovered. The current
            // root binding shadows that parameter, so repair only that exact
            // stale wrapper edge; nested source bindings remain untouched.
            const expected_kind: semantic_symbol.SyntheticKind = if (is_exports)
                .cjs_wrapper_exports_parameter
            else
                .cjs_wrapper_module_parameter;
            if (symbols.items[existing_raw].synthetic_kind != expected_kind) continue;
            symbols.items[existing_raw].reference_count -|= 1;
            symbol_ids[reference_raw] = raw_id;
            if (cache_symbol_ids) |cache_ids| {
                if (reference_raw < cache_ids.len) cache_ids[reference_raw] = raw_id;
            }
            if (is_exports) {
                exports_bound_count +|= 1;
            } else {
                module_bound_count +|= 1;
            }
            continue;
        }
        symbol_ids[reference_raw] = raw_id;
        if (cache_symbol_ids) |cache_ids| {
            if (reference_raw < cache_ids.len and cache_ids[reference_raw] == null) cache_ids[reference_raw] = raw_id;
        }
        if (is_exports) {
            exports_bound_count +|= 1;
        } else {
            module_bound_count +|= 1;
        }
    }
    // Any unresolved source reference bound here contributes to its target's
    // final symbol frequency. Already-resolved source references were counted
    // by the analyzer and are skipped above.
    if (exports_symbol) |id| {
        const raw: usize = @intFromEnum(id);
        if (raw < symbols.items.len) symbols.items[raw].reference_count +|= exports_bound_count;
    }
    if (module_symbol) |id| {
        const raw: usize = @intFromEnum(id);
        if (raw < symbols.items.len) symbols.items[raw].reference_count +|= module_bound_count;
    }
    return result;
}

fn containsSortedNode(nodes: []const u32, target: u32) bool {
    var low: usize = 0;
    var high = nodes.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (nodes[mid] < target) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low < nodes.len and nodes[low] == target;
}

fn extendCachedRefDeltas(allocator: std.mem.Allocator, m: *Module, old_symbol_count: usize, new_symbol_count: usize) void {
    const cache = if (m.transform_cache) |*value| value else return;
    if (cache.ref_deltas.len == 0 or cache.ref_deltas.len != old_symbol_count) return;
    const deltas = allocator.alloc(u32, new_symbol_count) catch return;
    @memset(deltas, 0);
    @memcpy(deltas[0..cache.ref_deltas.len], cache.ref_deltas);
    cache.ref_deltas = deltas;
}

/// 같은 base name 이 여러 모듈에서 나오면 `$2`, `$3`... suffix 로 unique 화.
/// 이미 등록된 suffix 와도 충돌하면 다음 N 으로 retry — incremental rebuild 에서
/// `{base, base$2}` 가 이미 seed 된 상태에서 새 모듈이 들어오면 `$3` 으로 회피.
fn uniqueName(
    name_arena: std.mem.Allocator,
    base: []const u8,
    used: *std.StringHashMapUnmanaged(u32),
    map_alloc: std.mem.Allocator,
) std.mem.Allocator.Error![]const u8 {
    if (!used.contains(base)) {
        try used.put(map_alloc, base, 1);
        return base;
    }
    var n: u32 = 2;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(name_arena, "{s}${d}", .{ base, n });
        if (!used.contains(candidate)) {
            try used.put(map_alloc, candidate, 1);
            return candidate;
        }
    }
}

/// `m.import_records[rec_idx].resolved`를 따라 target Module 포인터를 얻는다.
/// bounds/none 체크 실패 시 null. wrap_kind 결정 패스들의 공통 진입점.
fn resolveImportTarget(self: *ModuleGraph, m: anytype, rec_idx: usize) ?*Module {
    if (rec_idx >= m.import_records.len) return null;
    const target_mod_idx = m.import_records[rec_idx].resolved;
    if (target_mod_idx.isNone()) return null;
    const target_idx = @intFromEnum(target_mod_idx);
    if (target_idx >= self.modules.count()) return null;
    return self.modules.at(target_idx);
}

/// 모듈에 re_export binding 이 하나라도 있는지. Pass 3 의 selective scope-hoist
/// 가드용 — barrel 모듈은 factory body 의 init 호출로 source 의 side-effect 를
/// 전파해야 하므로 wrap 유지 (#1340/#1193).
fn moduleHasReExport(m: *const Module) bool {
    for (m.export_bindings) |eb| {
        if (eb.kind.isAnyReExport()) return true;
    }
    return false;
}

/// `.none` 상태의 ESM 모듈을 `.esm`으로 promote. 이미 래핑됐거나 ESM이 아니면
/// no-op. 변경 발생 시 true (Pass 2.5 fixpoint loop의 changed 플래그용).
fn promoteToEsmWrap(target: *Module) bool {
    if (target.wrap_kind != .none) return false;
    if (!target.exports_kind.isEsm()) return false;
    target.wrap_kind = .esm;
    return true;
}

/// node_modules 내 .js 파일이 ESM/CJS 신호 없으면 CJS로 간주.
/// Node.js 규칙: package.json "type": "module"이 없으면 .js는 CJS.
fn isImplicitCjs(module: *const Module) bool {
    // node_modules 밖이면 ESM으로 간주 (사용자 코드)
    const nm = "node_modules" ++ std.fs.path.sep_str;
    if (std.mem.indexOf(u8, module.path, nm) == null) return false;
    // def_format이 파싱 시점에 이미 결정됨 — 디스크 I/O 불필요
    return switch (module.def_format) {
        .cjs, .cts, .cjs_package_json => true,
        .esm_mjs, .esm_mts, .esm_package_json, .esm_module_field => false,
        .unknown => true, // node_modules 내 .js는 기본 CJS
    };
}

/// TLA 전이적 전파: TLA 모듈을 static import하는 모듈도 TLA로 표시.
/// await가 포함된 모듈의 실행이 완료되기 전에 이를 import하는 모듈이
/// 실행될 수 없으므로, import하는 쪽도 TLA로 간주해야 한다.
/// 동적 import는 비동기이므로 전파하지 않는다.
///
/// 역방향 BFS O(n + edges): 역의존성 맵을 빌드한 뒤,
/// TLA 모듈에서 시작하여 importers를 따라 전파한다.
pub fn propagateTopLevelAwait(self: *ModuleGraph) void {
    const count = self.modules.count();
    if (count == 0) return;

    // Base reset: `uses_top_level_await` 를 각 모듈의 self(자기 await) 값으로 되돌린 뒤 전파.
    // 이 함수의 전파는 set-only(아래 BFS 는 true 만 set, 절대 demote 안 함)라, HMR 위상 보존
    // (Phase B) 처럼 unchanged 모듈을 reparse 하지 않는 경로에서 직전 빌드의 transitive true 가
    // stale 로 남는다 — 예: dep 가 await 를 제거했는데 그 importer 가 여전히 true → emit 이
    // fresh(sync) 와 달리 async wrapper 를 박아 byte 가 갈린다. self 로 base 를 깔면 그 stale 이
    // 지워진다. fresh full 빌드에선 모든 모듈이 reparse 되어 `uses==self` 라 이 loop 는 no-op.
    {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const m = self.modules.at(i);
            m.uses_top_level_await = m.self_uses_top_level_await;
        }
    }

    // Fast path: TLA 모듈이 없으면 전파할 것도 없다.
    var has_tla = false;
    {
        var it = self.modules.iterator(0);
        while (it.next()) |m| {
            if (m.uses_top_level_await) {
                has_tla = true;
                break;
            }
        }
    }
    if (!has_tla) return;

    // 역의존성 맵 빌드: reverse_deps[target] = [importers...]
    var reverse_deps = self.allocator.alloc(std.ArrayListUnmanaged(u32), count) catch return;
    defer {
        for (reverse_deps) |*list| list.deinit(self.allocator);
        self.allocator.free(reverse_deps);
    }
    for (reverse_deps) |*list| list.* = .empty;

    {
        var it = self.modules.iterator(0);
        var src_idx: usize = 0;
        while (it.next()) |m| : (src_idx += 1) {
            for (m.import_records) |rec| {
                if (rec.resolved.isNone()) continue;
                if (!rec.kind.isEagerEvalDependency()) continue;
                const target_idx = @intFromEnum(rec.resolved);
                if (target_idx >= count) continue;
                reverse_deps[target_idx].append(self.allocator, @intCast(src_idx)) catch return;
            }
        }
    }

    // BFS: TLA 모듈 → importers 전파
    var visited = std.DynamicBitSet.initEmpty(self.allocator, count) catch return;
    defer visited.deinit();
    var queue: std.ArrayListUnmanaged(u32) = .empty;
    defer queue.deinit(self.allocator);

    {
        var it = self.modules.iterator(0);
        var idx: usize = 0;
        while (it.next()) |m| : (idx += 1) {
            if (m.uses_top_level_await) {
                visited.set(idx);
                queue.append(self.allocator, @intCast(idx)) catch return;
            }
        }
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const tla_idx = queue.items[head];
        head += 1;
        for (reverse_deps[tla_idx].items) |importer_idx| {
            if (visited.isSet(importer_idx)) continue;
            visited.set(importer_idx);
            self.modules.at(importer_idx).uses_top_level_await = true;
            queue.append(self.allocator, importer_idx) catch return;
        }
    }
}

/// #4598: **async cone** 계산 — TLA 모듈과, 그것을 동기 소비하는 모든 모듈.
///
/// `propagateTopLevelAwait` 와 두 가지가 다르다:
/// 1. **`require` 엣지도 탄다.** CJS 모듈이 TLA 모듈을 동기 require 하는 위상을 잡아야
///    한다 — Node 도 그 조합을 `ERR_REQUIRE_ASYNC_MODULE` 로 거부한다.
/// 2. **판정 전용 필드**(`in_async_cone`)에만 쓴다. `uses_top_level_await` 를 넓히면
///    `appendModuleCall`(`await init_X()`) 등이 함께 바뀐다(#4598 4차 회귀 원인).
///
/// dynamic import 는 이미 promise 경계라 전파하지 않는다.
pub fn computeAsyncCone(self: *ModuleGraph) void {
    const count = self.modules.count();
    if (count == 0) return;

    var seed = false;
    {
        var it = self.modules.iterator(0);
        while (it.next()) |m| {
            // ⚠️ `self_uses_top_level_await` 만으로는 부족하다. 그 값은 **변환 뒤** analyzer
            // 가 세우는데, TLA lowering 이 await 를 async IIFE 안으로 옮기면
            // `isInsideFunctionScope()` 가 true 라 false 가 된다. lowering 이 IIFE 를
            // 만들었다는 사실(`tla_iife_stmt`)이 정확한 신호다.
            m.in_async_cone = m.self_uses_top_level_await or m.tla_iife_stmt != null;
            if (m.in_async_cone) seed = true;
        }
    }
    if (!seed) return;

    // 역의존성 맵: static import 계열 + require.
    var rdeps = self.allocator.alloc(std.ArrayListUnmanaged(u32), count) catch return;
    defer {
        for (rdeps) |*l| l.deinit(self.allocator);
        self.allocator.free(rdeps);
    }
    for (rdeps) |*l| l.* = .empty;
    {
        var it = self.modules.iterator(0);
        var src: usize = 0;
        while (it.next()) |m| : (src += 1) {
            for (m.import_records) |rec| {
                if (rec.resolved.isNone()) continue;
                const eager = rec.kind.isEagerEvalDependency() or rec.kind == .require;
                if (!eager) continue;
                const t = @intFromEnum(rec.resolved);
                if (t >= count) continue;
                rdeps[t].append(self.allocator, @intCast(src)) catch return;
            }
        }
    }

    var queue: std.ArrayListUnmanaged(u32) = .empty;
    defer queue.deinit(self.allocator);
    {
        var it = self.modules.iterator(0);
        var i: usize = 0;
        while (it.next()) |m| : (i += 1) {
            if (m.in_async_cone) queue.append(self.allocator, @intCast(i)) catch return;
        }
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        for (rdeps[cur].items) |imp| {
            const m = self.modules.at(imp);
            if (m.in_async_cone) continue;
            m.in_async_cone = true;
            queue.append(self.allocator, imp) catch return;
        }
    }
}

/// #4598: async cone 모듈을 `__esm` 래퍼로 승격.
///
/// 래핑돼야 소비자가 `await init_X()` 로 **기다릴 대상**을 갖는다. scope-hoist 된 채로는
/// 기다릴 것이 없어 최상위 await(=타겟 위반) 말고는 방법이 없다.
///
/// ⚠️ 폐기된 시도(`ba943dec`)가 깨진 원인을 전부 가드로 막는다:
/// - **entry 는 export 가 없을 때만** 승격. export 가 있는 라이브러리 entry 를 래핑하면
///   `export { ... }` 가 래퍼 심볼로 바뀌어 **공개 API 가 통째로 사라진다**(실측).
/// - `.cjs` 래퍼는 제외 — `__commonJS` 는 factory 반환값을 버려 promise 를 못 흘린다.
///   그 위상은 별도 진단 대상이다(Node 도 `ERR_REQUIRE_ASYNC_MODULE` 로 거부).
/// - splitting / preserve-modules / multi-format 제외 — 각각 진입·청크 계약이 달라
///   폐기본에서 개별 결함이 났다.
/// - async 문법이 없는 타겟(es5)은 상태머신 낮추기가 선행돼야 한다.
///
/// `computeAsyncCone` **뒤에**, `registerWrapperSymbols` **앞에** 불러야 한다.
pub fn promoteAsyncConeToEsmWrap(self: *ModuleGraph) void {
    const base = &self.transform_options_base;
    if (!base.unsupported.top_level_await) return; // 타겟이 TLA 지원 → 손대지 않음
    if (base.unsupported.async_await) return; // es5 는 아직 대상 아님
    if (self.code_splitting or self.preserve_modules) return;
    // 청크 위임(#4625)이 이 청크를 async factory 로 감싸면 모듈을 또 래핑하지 않는다.
    // 위임 산물이 scope-hoist 라 더 작고 이미 검증돼 있다 — 겹치면 커지기만 한다.
    if (base.tla_chunk_wrapped) return;

    var it = self.modules.iterator(0);
    while (it.next()) |m| {
        if (!m.in_async_cone) continue;
        if (!m.module_type.isJavaScriptLike()) continue;
        if (m.wrap_kind != .none) continue; // 이미 래핑(cjs 포함) → 그 기계에 맡긴다
        // 라이브러리 entry(= export 가 있는 entry)는 승격하지 않는다 — 래핑하면
        // `export { … }` 가 래퍼 심볼로 바뀌어 **공개 API 가 사라진다**(실측).
        // ⚠️ 대신 emitter 가 승격 안 된 TLA 모듈에 최상위 `await <temp>;` 를 낸다.
        //    안 그러면 `lowerProgram` 이 옮긴 초기화식을 아무도 기다리지 않아 export 값이
        //    조용히 `undefined` 가 된다(리뷰 실측: main `V= 41` → `V= undefined`).
        if (m.is_entry_point and m.export_bindings.len > 0) continue;
        // ⚠️ **순수 re-export entry**(`export { v } from './dep'`)가 소비자면 승격하면 안 된다.
        //    그 위상엔 `init_X()` 를 부르는 경로가 아예 없어(import 바인딩도 wrap 도 없음)
        //    factory 가 정의만 되고 호출되지 않는다 → export 값이 영구히 `undefined`
        //    (리뷰 실측: main `v= 41` → `v= undefined`). 승격 안 하면 scope-hoist 로
        //    남아 emitter 의 최상위 await fallback 이 처리한다.
        if (hasOnlyReExportImporters(self, m)) continue;
        if (m.exports_kind == .none) m.exports_kind = .esm;
        if (m.exports_kind.isEsm()) m.wrap_kind = .esm;
    }
}

/// #4598: 이 모듈을 소비하는 importer 가 **전부 re-export 뿐**인지.
/// 그 위상엔 `init_X()` 호출 경로가 없어 승격하면 factory 가 영영 안 돈다.
fn hasOnlyReExportImporters(self: *ModuleGraph, target: *const Module) bool {
    const t_idx = blk: {
        var it = self.modules.iterator(0);
        var i: u32 = 0;
        while (it.next()) |m| : (i += 1) {
            if (m == target) break :blk i;
        }
        return false;
    };
    var saw_any = false;
    var it = self.modules.iterator(0);
    while (it.next()) |m| {
        for (m.import_records) |rec| {
            if (rec.resolved.isNone()) continue;
            if (@intFromEnum(rec.resolved) != t_idx) continue;
            saw_any = true;
            if (rec.kind != .re_export) return false;
        }
    }
    return saw_any;
}

test "finalize: runtime synthetic symbol registration propagates OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var arena = std.heap.ArenaAllocator.init(failing.allocator());
    defer arena.deinit();

    var module = Module.init(@enumFromInt(0), "generated.cjs");
    module.parse_arena = &arena;
    module.semantic = .{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };

    try std.testing.expectError(
        error.OutOfMemory,
        registerBundlerRuntimeHelperSymbol(&module, &module.to_binary_runtime_symbol, "__toBinary"),
    );
    try std.testing.expectError(error.OutOfMemory, registerCjsRuntimeFactorySymbol(&module));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(module.to_binary_runtime_symbol == null);
    try std.testing.expect(module.cjs_runtime_factory_symbol == null);
    try std.testing.expectEqual(@as(usize, 0), module.semantic.?.symbols.items.len);
}

test "finalize: CJS wrapper parameter allocation propagates OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var arena = std.heap.ArenaAllocator.init(failing.allocator());
    defer arena.deinit();

    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();
    var scopes = [_]Scope{.{
        .parent = ScopeId.none,
        .kind = .module,
        .is_strict = true,
    }};
    var scope_maps = [_]std.StringHashMapUnmanaged(usize){.empty};
    var module = Module.init(@enumFromInt(0), "entry.cjs");
    module.ast = ast;
    module.parse_arena = &arena;
    module.semantic = .{
        .symbols = .empty,
        .scopes = &scopes,
        .scope_maps = &scope_maps,
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };

    try std.testing.expectError(error.OutOfMemory, registerCjsWrapperParameters(&module));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), module.semantic.?.symbols.items.len);
}
