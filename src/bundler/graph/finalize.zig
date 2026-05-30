//! Final graph promotion/wrapping passes for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const Module = @import("../module.zig").Module;
const semantic_symbol = @import("../../semantic/symbol.zig");
const Span = @import("../../lexer/token.zig").Span;
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
    if (self.resolve_cache.platform == .react_native or (self.dev_mode and !self.code_splitting)) {
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
/// OOM/semantic 없음 → 조용히 skip, fallback 경로가 기존 동작 유지.
///
/// `makeVarNameWithPrefix` 는 path 의 마지막 `node_modules/` 이후만 사용해 이름을
/// 생성하므로, bun lockfile 처럼 `node_modules/.bun/<HASH>/node_modules/<pkg>/...`
/// 형태로 같은 패키지의 다른 hash 사본이 동시에 존재하면 두 사본의 init/exports
/// 변수 이름이 동일해진다. emitter 가 같은 변수를 두 번 선언 + 같은 export object 의
/// getter 를 두 번 정의 → 두번째가 첫번째를 덮어써서 사용처에서 undefined 참조.
/// 충돌 감지 시 `$<N>` suffix 로 deconflict.
pub fn registerWrapperSymbols(self: *ModuleGraph) void {
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
        // RFC #3940 L.4c-2a-i: mangle 전 단계 (canonical 미설정) → rt null, synthetic_name 조회.
        if (m.getInitName(null)) |n| _ = used_names.put(self.allocator, n, 1) catch {};
        if (m.getExportsName(null)) |n| _ = used_names.put(self.allocator, n, 1) catch {};
        if (m.getRequireName(null)) |n| _ = used_names.put(self.allocator, n, 1) catch {};
    }

    var it = self.modules.iterator(0);
    while (it.next()) |m| {
        if (m.wrap_kind == .none) continue;
        const needs_init = m.init_symbol == null;
        const needs_exports = m.exports_symbol == null;
        const needs_require = m.wrap_kind == .cjs and m.require_symbol == null;
        if (!needs_init and !needs_exports and !needs_require) continue;
        const sem_ptr = if (m.semantic) |*s| s else continue;
        const arena = if (m.parse_arena) |a| a.allocator() else continue;

        if (needs_init) {
            const init_base = types.makeInitVarName(arena, m.path) catch continue;
            const init_name = uniqueName(arena, init_base, &used_names, self.allocator) catch continue;
            m.init_symbol = semantic_symbol.extendSymbol(
                arena,
                &sem_ptr.symbols,
                .function_decl,
                .esm_init,
                init_name,
                Span.EMPTY,
            ) catch null;
        }

        if (needs_exports) {
            const exports_base = types.makeExportsVarName(arena, m.path) catch continue;
            const exports_name = uniqueName(arena, exports_base, &used_names, self.allocator) catch continue;
            m.exports_symbol = semantic_symbol.extendSymbol(
                arena,
                &sem_ptr.symbols,
                .variable_var,
                .cjs_exports,
                exports_name,
                Span.EMPTY,
            ) catch null;
        }

        if (needs_require) {
            const require_base = types.makeRequireVarName(arena, m.path) catch continue;
            const require_name = uniqueName(arena, require_base, &used_names, self.allocator) catch continue;
            m.require_symbol = semantic_symbol.extendSymbol(
                arena,
                &sem_ptr.symbols,
                .function_decl,
                .cjs_require,
                require_name,
                Span.EMPTY,
            ) catch null;
        }
    }
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
        .esm_mjs, .esm_mts, .esm_package_json => false,
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
