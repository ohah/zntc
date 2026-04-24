//! Linker metadata 빌드 — buildMetadataForAst, buildDevMetadataForAst, buildMetadata

const std = @import("std");
const types = @import("../types.zig");
const rt = @import("../runtime_helpers.zig");
const ModuleIndex = types.ModuleIndex;
const BundlerDiagnostic = types.BundlerDiagnostic;
const Module = @import("../module.zig").Module;
const ImportBinding = @import("../binding_scanner.zig").ImportBinding;
const ExportBinding = @import("../binding_scanner.zig").ExportBinding;
const Span = @import("../../lexer/token.zig").Span;
const NodeIndex = @import("../../parser/ast.zig").NodeIndex;
const Ast = @import("../../parser/ast.zig").Ast;
const semantic_symbol = @import("../../semantic/symbol.zig");
const linker_mod = @import("../linker.zig");
const Linker = linker_mod.Linker;
const LinkingMetadata = linker_mod.LinkingMetadata;
const SymbolRef = linker_mod.SymbolRef;
const ResolvedBinding = linker_mod.ResolvedBinding;
const makeExportKey = types.makeModuleKey;
const makeExportKeyBuf = types.makeModuleKeyBuf;
const PreambleWriter = linker_mod.PreambleWriter;
const NsExportPair = Linker.NsExportPair;
const getOrCreateRequireVar = linker_mod.getOrCreateRequireVar;
const isNamespaceUsedAsValue = Linker.isNamespaceUsedAsValue;
const isReservedName = Linker.isReservedName;
const NamePair = PreambleWriter.NamePair;
const NS_VAR_PREFIX = linker_mod.NS_VAR_PREFIX;

pub fn buildSkipNodes(allocator: std.mem.Allocator, ast: *const Ast, skip_imports: bool) !std.DynamicBitSet {
    const node_count = ast.nodes.items.len;
    var skip_nodes = try std.DynamicBitSet.initEmpty(allocator, node_count);
    errdefer skip_nodes.deinit();

    for (ast.nodes.items, 0..) |node, node_idx| {
        switch (node.tag) {
            // 래핑 모듈: import는 emitImportCJS가 처리 → skip하지 않음.
            // scope hoisted 타겟 import만 import_bindings 루프에서 개별 skip.
            .import_declaration => if (skip_imports) skip_nodes.set(node_idx),
            .export_named_declaration => {
                const e = node.data.extra;
                if (e + 3 < ast.extra_data.items.len) {
                    const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
                    if (decl_idx.isNone()) {
                        skip_nodes.set(node_idx); // export { } 또는 re-export
                    }
                    // export const → codegen에서 export 키워드만 생략
                }
            },
            // export default → codegen이 linking_metadata 체크하여 키워드만 생략
            .export_default_declaration => {},
            .export_all_declaration => skip_nodes.set(node_idx),
            else => {},
        }
    }
    return skip_nodes;
}

/// `Linker.unified_result` 에서 현재 모듈의 Phase B (nested) rename 을
/// `renames` 에 merge. Phase A 심볼 (module_scope_symbols bitset set) 은
/// 스킵 — self-rename 루프가 canonical_name 경로로 이미 처리했음.
fn mergeUnifiedPhaseB(
    self: *const Linker,
    module_index: u32,
    renames: *std.AutoHashMap(u32, []const u8),
) !void {
    const ur = &(self.unified_result orelse return);
    if (module_index >= self.unified_module_scopes.len) return;
    const module_bits = &self.unified_module_scopes[module_index];

    var it = ur.renames.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.module_index != module_index) continue;
        const sid = entry.key_ptr.symbol_id;
        if (sid < module_bits.capacity() and module_bits.isSet(sid)) continue;
        if (renames.contains(sid)) continue;
        try renames.put(sid, entry.value_ptr.*);
    }
}

/// transformer 이후의 ast를 기반으로 LinkingMetadata를 생성한다.
/// skip_nodes와 renames가 ast의 노드 인덱스와 일치.
pub fn buildMetadataForAst(
    self: *const Linker,
    ast: *const Ast,
    module_index: u32,
    is_entry: bool,
    override_symbol_ids: ?[]const ?u32,
) !LinkingMetadata {
    var scope = @import("../../profile.zig").begin(.metadata);
    defer scope.end();

    const m_opt = self.getModule(module_index);
    if (m_opt == null) {
        return .{
            .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };
    }

    const m = m_opt.?.*;

    // 래핑 모듈 + semantic 없음: require_rewrites만 구축하고 조기 반환.
    // semantic 있으면 import_bindings 처리 경로로 진행하여
    // scope hoisted ESM 타겟에 대한 rename/preamble도 생성.
    if (m.wrap_kind.isWrapped() and m.semantic == null) {
        const node_count = ast.nodes.items.len;
        return .{
            .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count),
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = null,
            .symbol_ids = &.{},
            .cjs_import_preamble = null,
            .require_rewrites = try self.buildRequireRewrites(&m),
            .allocator = self.allocator,
        };
    }

    // 래핑 모듈: import를 skip하지 않음 (emitImportCJS가 처리).
    // scope hoisted 타겟 import만 import_bindings 루프에서 개별 skip.
    const skip_imports = !m.wrap_kind.isWrapped();
    var skip_nodes = try buildSkipNodes(self.allocator, ast, skip_imports);
    errdefer skip_nodes.deinit();

    var renames = std.AutoHashMap(u32, []const u8).init(self.allocator);
    errdefer renames.deinit();

    // nested mangling에서 소유권을 이전받은 문자열 추적 (deinit에서 해제)
    var owned_nested_renames: std.ArrayListUnmanaged([]const u8) = .empty;

    // __esm live binding: __export getter에서 사용할 이름 override
    var export_getter_overrides: std.StringHashMapUnmanaged([]const u8) = .{};
    errdefer {
        export_getter_overrides.deinit(self.allocator);
        for (owned_nested_renames.items) |v| self.allocator.free(v);
        owned_nested_renames.deinit(self.allocator);
    }

    // 2. import 바인딩 리네임 (모듈의 semantic 기반)
    const sem = m.semantic orelse return .{
        .skip_nodes = skip_nodes,
        .renames = renames,
        .final_exports = null,
        .symbol_ids = &.{},
        .allocator = self.allocator,
    };

    // CJS import preamble writer (#1621: minify 시 __toESM → $tE 등 축약)
    var preamble = PreambleWriter.init(self.allocator);
    preamble.minify = self.minify_whitespace;

    // __esm 모듈의 init_xxx() 호출 중복 방지 (같은 모듈을 여러 binding이 참조할 때)
    var esm_init_set = std.AutoHashMap(u32, void).init(self.allocator);
    defer esm_init_set.deinit();
    defer preamble.deinit();

    // namespace member rewrite 엔트리 수집 (esbuild 방식)
    var ns_rewrite_list: std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry) = .empty;
    errdefer {
        for (ns_rewrite_list.items) |*e| e.map.deinit();
        ns_rewrite_list.deinit(self.allocator);
    }
    // namespace 인라인 객체 수집 (값 사용 시)
    var ns_inline_list: std.ArrayList(LinkingMetadata.NsInlineObjects.Entry) = .empty;
    errdefer {
        for (ns_inline_list.items) |e| {
            self.allocator.free(e.object_literal);
            self.allocator.free(e.var_name);
        }
        ns_inline_list.deinit(self.allocator);
    }

    // CJS 모듈별 require_xxx 변수명 캐시 (같은 모듈에서 여러 named import 시 중복 생성 방지)
    var cjs_var_cache = std.AutoHashMap(u32, []const u8).init(self.allocator);
    defer {
        var vit = cjs_var_cache.valueIterator();
        while (vit.next()) |v| self.allocator.free(v.*);
        cjs_var_cache.deinit();
    }

    // CJS 모듈별 namespace 변수명 캐시 (ESM-wrapped → CJS named import의 namespace 접근 패턴)
    var cjs_ns_cache = std.AutoHashMap(u32, []const u8).init(self.allocator);
    defer cjs_ns_cache.deinit(); // 값은 ns_var_list가 소유
    var ns_var_list: std.ArrayListUnmanaged([]const u8) = .empty;
    // ns_var_list 소유권은 metadata.dev_ns_vars로 이전됨 (정상 경로)
    // 에러 시에만 여기서 해제
    errdefer {
        for (ns_var_list.items) |v| self.allocator.free(v);
        ns_var_list.deinit(self.allocator);
    }

    // #1791 IIFE unresolved build-time diag. 정상 경로에서는 emitter 가 serial 로
    // `linker.fatal_diagnostics` 에 flush. item.message 는 allocator 소유.
    var pending_diags: std.ArrayListUnmanaged(@import("../types.zig").BundlerDiagnostic) = .empty;
    errdefer {
        for (pending_diags.items) |d| self.allocator.free(d.message);
        pending_diags.deinit(self.allocator);
    }
    // IIFE dedupe 맵은 실제 IIFE 포맷 + unresolved 발생 시에만 lazy init — ESM/CJS
    // 빌드 (실측 99%+ 모듈) 에서 해시맵 backing alloc 비용을 피한다.
    var iife_diag_seen: ?std.StringHashMap(void) = null;
    defer if (iife_diag_seen) |*seen_map| seen_map.deinit();

    // namespace import / inline object 캐시는 linker 전역 필드(`self.ns_export_cache`,
    // `self.ns_inline_cache`) 로 이동 — 같은 target 을 여러 모듈이 namespace import 해도
    // collectExportsRecursive DFS 를 한 번만 수행하도록 공유 (#1734).

    if (sem.scope_maps.len > 0) {
        const module_scope = sem.scope_maps[0];

        // export된 local name을 미리 수집 — namespace import가 re-export되는지 O(1) 확인용
        var exported_locals = std.StringHashMap(void).init(self.allocator);
        defer exported_locals.deinit();
        for (m.export_bindings) |eb| {
            if (eb.kind == .local) try exported_locals.put(m.exportBindingLocalName(eb), {});
        }

        // import 바인딩 → canonical 이름
        for (m.import_bindings) |ib| {
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];

            // resolve 미완료: external 또는 resolve 실패.
            if (rec.resolved.isNone()) {
                if (rec.kind == .static_import or rec.kind == .side_effect or rec.kind == .re_export) {
                    const preamble_name = self.getCanonicalByRef(ib.local_symbol) orelse m.importBindingLocalName(ib);
                    // synthetic binding(JSX runtime 등) + ESM-wrapped 모듈 조합에서는
                    // top-level에 이미 `var _jsxDEV, _Fragment;` 선언이 호이스팅됨.
                    // init 함수 본문에서 `var`로 재선언하면 outer scope를 shadow → #1209.
                    const is_synthetic_esm = ib.isSynthetic() and m.wrap_kind == .esm;
                    if (rec.is_external and (self.format == .umd or self.format == .amd)) {
                        // UMD/AMD: factory 매개변수에서 직접 참조
                        const param_name = try types.specifierToParamName(self.allocator, rec.specifier);
                        defer self.allocator.free(param_name);
                        if (ib.kind == .namespace or ib.importsDefault()) {
                            // import * as React / import React → factory param 직접 사용
                            if (!std.mem.eql(u8, preamble_name, param_name)) {
                                try preamble.write("var ");
                                try preamble.write(preamble_name);
                                try preamble.write(" = ");
                                try preamble.write(param_name);
                                try preamble.write(";\n");
                            }
                        } else {
                            // import { useState } → var useState = React.useState
                            try preamble.write("var ");
                            try preamble.write(preamble_name);
                            try preamble.write(" = ");
                            try preamble.write(param_name);
                            try preamble.write(".");
                            try preamble.write(ib.imported_name);
                            try preamble.write(";\n");
                        }
                    } else if (self.format == .iife and !ib.isSynthetic()) {
                        // #1791 IIFE: unresolved external 은 의미 자체가 성립 안 함
                        // (factory 스코프에 require 없음, top-level import 도 불가).
                        // build-time 에러로 pending_diagnostics 에 쌓고 emitter 가 flush.
                        // specifier 단위로 dedupe — 같은 spec 의 binding 여러 개에 대해 한 번만.
                        if (iife_diag_seen == null) iife_diag_seen = std.StringHashMap(void).init(self.allocator);
                        const seen_gop = try iife_diag_seen.?.getOrPut(rec.specifier);
                        if (!seen_gop.found_existing) {
                            const msg = try std.fmt.allocPrint(
                                self.allocator,
                                "unresolved import \"{s}\" cannot be emitted in IIFE format (no require/import available in factory scope)",
                                .{rec.specifier},
                            );
                            errdefer self.allocator.free(msg);
                            try pending_diags.append(self.allocator, .{
                                .code = .unresolved_import,
                                .severity = .@"error",
                                .message = msg,
                                .file_path = m.path,
                                .span = rec.span,
                                .step = .resolve,
                                .suggestion = null,
                            });
                        }
                    } else {
                        // ESM/CJS: require() preamble 생성. ESM 출력에서도 esbuild 호환으로
                        // require() 를 유지 — Node.js 가 `import` 없는 출력을 CJS 로 파싱하여
                        // `var X; var X;` 재선언을 허용하게 한다 (`emitter.zig` 상단 주석 참조).
                        if (is_synthetic_esm) {
                            try preamble.writeUnresolvedRequireAssignOnly(preamble_name, rec.specifier, ib.imported_name, ib.kind == .namespace);
                        } else {
                            try preamble.writeUnresolvedRequire(preamble_name, rec.specifier, ib.imported_name, ib.kind == .namespace);
                        }
                    }
                }
                continue;
            }

            const canonical_mod = @intFromEnum(rec.resolved);

            // __esm 모듈에서 CJS 타겟 또는 self-import: body의 require_rewrites가
            // 할당문 + init 호출을 처리하므로 preamble 생성 skip.
            // __esm → __esm은 live binding (preamble init + canonical rename) 사용.
            // 단, synthetic binding(JSX runtime 등)은 AST body에 require()가 없으므로 skip하지 않음.
            //
            // named import from CJS in ESM-wrapped → namespace 접근 패턴:
            // 호이스팅된 함수에서 import binding을 안전하게 참조하기 위해
            // 개별 구조분해 대신 namespace 객체 프로퍼티 접근을 사용한다 (rolldown 방식).
            // preamble에서 ns_var = __toESM(require_xxx()) 생성 + rename 등록.
            const is_synthetic = ib.isSynthetic();
            const canonical_m_opt = self.getModule(canonical_mod);
            if (!is_synthetic and m.wrap_kind == .esm and canonical_m_opt != null and
                (canonical_m_opt.?.wrap_kind == .cjs or canonical_mod == module_index))
            {
                if (ib.kind == .named and canonical_m_opt.?.wrap_kind == .cjs) {
                    const req_var = try getOrCreateRequireVar(self, &cjs_var_cache, @intCast(canonical_mod));
                    const interop_mode: types.Interop = if (m.def_format.isEsm()) .node else .babel;

                    // CJS 모듈별 namespace var 생성 (한 번만)
                    const ns_var = if (cjs_ns_cache.get(@intCast(canonical_mod))) |cached| cached else blk: {
                        const ns_name = try std.fmt.allocPrint(self.allocator, NS_VAR_PREFIX ++ "{d}_{d}", .{ module_index, cjs_ns_cache.count() });
                        try cjs_ns_cache.put(@intCast(canonical_mod), ns_name);
                        try ns_var_list.append(self.allocator, ns_name);
                        try preamble.writeCjsImportInner(ns_name, "", req_var, true, interop_mode, true);
                        break :blk ns_name;
                    };

                    if (ib.local_symbol.semanticIndex()) |sym_idx| {
                        const rename = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_var, ib.imported_name });
                        try owned_nested_renames.append(self.allocator, rename);
                        try renames.put(sym_idx, rename);
                    }
                }
                continue;
            }

            // CJS 모듈에서 import하는 경우: preamble에서 require_xxx() 호출 생성
            if (canonical_m_opt != null and canonical_m_opt.?.wrap_kind == .cjs) {
                const preamble_name = self.getCanonicalByRef(ib.local_symbol) orelse m.importBindingLocalName(ib);
                const req_var = try getOrCreateRequireVar(self, &cjs_var_cache, @intCast(canonical_mod));
                const interop_mode: types.Interop = if (m.def_format.isEsm()) .node else .babel;
                // ESM-wrapped + synthetic binding: top-level에 이미 var 선언됨 → 할당만
                if (is_synthetic and m.wrap_kind == .esm) {
                    try preamble.writeCjsImportAssignOnly(preamble_name, ib.imported_name, req_var, ib.kind == .namespace, interop_mode);
                } else {
                    try preamble.writeCjsImport(preamble_name, ib.imported_name, req_var, ib.kind == .namespace, interop_mode);
                }
                continue;
            }

            // __esm 래핑 모듈에서 import: init_xxx() 호출을 preamble에 추가.
            // 호이스팅된 함수는 top-level에 있으므로 rename으로 참조 가능.
            // init 호출은 모듈당 1회만 (중복 방지는 esm_init_set으로).
            if (canonical_m_opt != null and canonical_m_opt.?.wrap_kind == .esm) {
                if (!esm_init_set.contains(@intCast(canonical_mod))) {
                    try esm_init_set.put(@intCast(canonical_mod), {});
                    const target_mod = canonical_m_opt.?;
                    if (target_mod.uses_top_level_await) try preamble.write("await ");
                    if (self.dev_mode) {
                        try preamble.write("__zts_modules[\"");
                        try preamble.write(target_mod.dev_id);
                        try preamble.write("\"].fn();\n");
                    } else {
                        const init_name = try target_mod.allocInitName(self.allocator);
                        defer self.allocator.free(init_name);
                        try preamble.write(init_name);
                        try preamble.write("();\n");
                    }
                }
                // import binding은 아래의 rename 경로로 처리 (continue하지 않음)
            }

            // namespace import: esbuild 방식 — ns.prop → canonical_name 직접 치환.
            // __esm 타겟도 동일: rolldown 방식으로 변수가 래퍼 밖에 호이스팅되므로
            // canonical name으로 직접 치환 가능. exports_xxx rename은 변수 덮어쓰기 버그 유발.
            if (ib.kind == .namespace) {
                const ns_sym_id = ib.local_symbol.semanticIndex() orelse continue;
                const local_name = m.importBindingLocalName(ib);
                const effective_syms = override_symbol_ids orelse sem.symbol_ids;

                // esbuild 방식: ns.prop → 직접 치환, ns 값 사용 → 변수 선언 + 참조.
                // export { ns } 패턴도 값 사용 — namespace 객체를 preamble 변수로 생성 필요.
                const need_inline = isNamespaceUsedAsValue(self.allocator, ast, effective_syms, ns_sym_id) or
                    exported_locals.contains(local_name);
                try self.registerNamespaceRewrites(
                    &ns_rewrite_list,
                    if (need_inline) &ns_inline_list else null,
                    ns_sym_id,
                    @intCast(canonical_mod),
                    local_name,
                );
                continue;
            }

            // resolveImports()에서 이미 해결한 바인딩을 조회하거나, 직접 해결
            const resolved = self.getResolvedBinding(module_index, ib.local_span);

            // 롤다운 shimMissingExports 호환: 소스 모듈에 해당 export가 없으면
            // strict mode ReferenceError 대신 undefined를 반환하도록 shim 생성.
            if (resolved == null and self.shim_missing_exports) {
                const shim_name = self.getCanonicalByRef(ib.local_symbol) orelse m.importBindingLocalName(ib);
                try preamble.write("var ");
                try preamble.write(shim_name);
                try preamble.write(" = void 0;\n");
                continue;
            }

            // re-export → CJS 패턴: canonical이 CJS 모듈을 가리키면
            // rename 대신 CJS preamble을 생성한다.
            // canonical.export_name을 사용하여 re-export 체인을 올바르게 추적:
            // import fn from './reexport' (default) → reexport: import { x } from 'cjs'; export default x
            // → canonical = { cjs, "x" } → req_cjs().x (not .default)
            if (resolved) |rb| {
                const cjs_mod: u32 = @intCast(@intFromEnum(rb.canonical.module_index));
                const cjs_mod_opt = self.graph.getModule(rb.canonical.module_index);
                if (cjs_mod_opt != null and cjs_mod_opt.?.wrap_kind == .cjs) {
                    const preamble_name = self.getCanonicalByRef(ib.local_symbol) orelse m.importBindingLocalName(ib);
                    const req_var = try getOrCreateRequireVar(self, &cjs_var_cache, cjs_mod);
                    const interop_mode2: types.Interop = if (m.def_format.isEsm()) .node else .babel;
                    const effective_name = rb.canonical.export_name;
                    try preamble.writeCjsImport(preamble_name, effective_name, req_var, false, interop_mode2);
                    continue;
                }
            }

            const target_name = blk: {
                if (resolved) |rb| {
                    const local = self.resolveToLocalName(rb.canonical);
                    // namespace re-export 감지: export * as X → local_name == exported_name
                    // 이 경우 소스 모듈의 namespace 객체 preamble을 importer에 생성
                    if (self.graph.getModule(rb.canonical.module_index)) |cmod_ptr| {
                        for (cmod_ptr.export_bindings) |eb| {
                            if (eb.kind.isReExportAll() and
                                std.mem.eql(u8, eb.exported_name, rb.canonical.export_name) and
                                !std.mem.eql(u8, eb.exported_name, "*"))
                            {
                                // namespace re-export: ns_member_rewrites + 인라인 객체 등록
                                if (eb.import_record_index) |rec_idx| {
                                    if (rec_idx < cmod_ptr.import_records.len) {
                                        const src = cmod_ptr.import_records[rec_idx].resolved;
                                        if (!src.isNone()) {
                                            const import_sym_id = module_scope.get(ib.local_name) orelse break :blk ib.imported_name;
                                            try self.registerNamespaceRewrites(
                                                &ns_rewrite_list,
                                                &ns_inline_list,
                                                @intCast(import_sym_id),
                                                @intFromEnum(src),
                                                ib.local_name,
                                            );
                                            break :blk ib.local_name;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // canonical의 export local_name이 namespace import인 경우 → 인라인 객체
                    const cmod2: u32 = @intCast(@intFromEnum(rb.canonical.module_index));
                    const export_local = self.getExportLocalName(cmod2, rb.canonical.export_name) orelse rb.canonical.export_name;
                    if (self.graph.getModule(rb.canonical.module_index)) |cmod2_ptr| {
                        for (cmod2_ptr.import_bindings) |cib| {
                            if (cib.kind == .namespace and std.mem.eql(u8, cib.local_name, export_local)) {
                                // namespace import → 인라인 객체로 처리
                                const imp_sym = module_scope.get(ib.local_name) orelse break;
                                const ns_target_mod = if (cib.import_record_index < cmod2_ptr.import_records.len)
                                    @intFromEnum(cmod2_ptr.import_records[cib.import_record_index].resolved)
                                else
                                    break;
                                try self.registerNamespaceRewrites(
                                    &ns_rewrite_list,
                                    &ns_inline_list,
                                    @intCast(imp_sym),
                                    @intCast(ns_target_mod),
                                    ib.local_name,
                                );
                                break :blk ib.local_name;
                            }
                        }
                    }
                    break :blk local;
                }
                break :blk ib.imported_name;
            };

            // import binding → target module의 canonical name으로 rename.
            // scope hoisting 후 import가 제거되므로, 같은 이름이라도
            // 항상 renames에 등록하여 codegen이 target 변수를 참조하도록 함.
            // 중첩 스코프 충돌은 resolveNestedShadowConflicts에서 이미 처리됨.
            if (!isReservedName(target_name)) {
                if (ib.local_symbol.semanticIndex()) |sym_idx| {
                    try renames.put(sym_idx, target_name);
                    // __esm → __esm live binding: __export getter override 등록 +
                    // 자체 rename 루프에서 덮어쓰기 방지
                    if (m.wrap_kind == .esm and canonical_m_opt != null and
                        canonical_m_opt.?.wrap_kind == .esm)
                    {
                        try export_getter_overrides.put(self.allocator, m.importBindingLocalName(ib), target_name);
                    }
                }
            }
        }

        // 래핑 모듈: preamble이 처리하는 import_declaration을 skip.
        // - scope hoisted 타겟: rename으로 직접 참조 → import 불필요
        // - __esm 모듈: preamble이 init 호출 + CJS require를 처리 → body에서 중복 방지
        if (m.wrap_kind.isWrapped()) {
            var hoisted_specifiers = std.StringHashMap(void).init(self.allocator);
            defer hoisted_specifiers.deinit();
            for (m.import_records, 0..) |rec, rec_i| {
                if (rec.resolved.isNone()) continue;
                const tidx = @intFromEnum(rec.resolved);
                const tmod = self.graph.getModule(rec.resolved) orelse continue;
                if (tmod.wrap_kind == .none) {
                    try hoisted_specifiers.put(rec.specifier, {});
                } else if (tmod.wrap_kind == .esm and tidx != module_index) {
                    // __esm → __esm live binding: named import만 skip.
                    // namespace import는 body codegen이 exports_xxx 할당을 생성해야 함.
                    // self-import는 제외 (순환 자기 참조 시 body codegen이 처리).
                    const has_namespace = for (m.import_bindings) |ib| {
                        if (ib.import_record_index == rec_i and ib.kind == .namespace)
                            break true;
                    } else false;
                    if (!has_namespace) {
                        try hoisted_specifiers.put(rec.specifier, {});
                    }
                }
            }
            // AST에서 해당 specifier의 import_declaration 노드를 skip
            if (hoisted_specifiers.count() > 0) {
                for (ast.nodes.items, 0..) |inode, inode_idx| {
                    if (inode.tag != .import_declaration) continue;
                    const ie = inode.data.extra;
                    if (ie + 3 > ast.extra_data.items.len) continue;
                    const source_idx: NodeIndex = @enumFromInt(ast.extra_data.items[ie + 2]);
                    if (source_idx.isNone()) continue;
                    const src_node = ast.getNode(source_idx);
                    if (src_node.tag != .string_literal) continue;
                    const raw = ast.getText(src_node.data.string_ref);
                    const spec = Ast.stripStringQuotes(raw);
                    if (hoisted_specifiers.contains(spec)) {
                        skip_nodes.set(inode_idx);
                    }
                }
            }
        }

        // 자체 top-level 심볼 리네임 (이름 충돌 + mangling)
        // live binding으로 설정된 심볼은 skip (source 모듈의 canonical name 유지)
        var sit = module_scope.iterator();
        while (sit.next()) |scope_entry| {
            const sym_name = scope_entry.key_ptr.*;
            if (self.getCanonicalName(module_index, sym_name)) |renamed| {
                if (!export_getter_overrides.contains(sym_name)) {
                    const sym_idx = scope_entry.value_ptr.*;
                    try renames.put(@intCast(sym_idx), renamed);
                }
            }
        }

        // nested rename 을 `Linker.unified_result` 에서 조회. Phase A (module
        // scope) 은 위 self-rename 루프에서 canonical_name 경유로 이미 처리됨.
        // 값은 linker 소유 (borrowed) — metadata 는 참조만.
        mergeUnifiedPhaseB(self, module_index, &renames) catch {};
    }

    // CJS import preamble 저장
    const cjs_import_preamble = try preamble.toOwned();

    // collectModuleNames에서 등록한 _default 충돌의 canonical name을 조회.
    var default_export_name: []const u8 = "_default";
    for (m.export_bindings) |eb| {
        if (eb.hasSyntheticDefault(m.semanticSymbols())) {
            default_export_name = self.getCanonicalName(module_index, "_default") orelse "_default";
            break;
        }
        if (eb.kind == .local and std.mem.eql(u8, eb.exported_name, "default")) {
            default_export_name = self.getCanonicalByRef(eb.symbol) orelse m.exportBindingLocalName(eb);
            break;
        }
    }

    // 3. 엔트리 포인트 final exports
    const final_exports = try self.buildFinalExports(is_entry, module_index, m.export_bindings);

    // 크로스-모듈 상수 인라인: import binding의 canonical export가 상수이면 매핑
    const const_values = try self.buildCrossModuleConstValues(self.getModule(module_index).?, sem);

    // ns_member_rewrites / ns_inline_objects 소유권 이동 + namespace preamble 생성.
    // finalizeNamespaceData가 리스트를 소비(deinit)하므로, 이후 에러 시
    // errdefer가 이미 해제된 리스트에 접근하지 않도록 마지막에 호출한다.
    const ns_result = try finalizeNamespaceData(self.allocator, &ns_rewrite_list, &ns_inline_list, cjs_import_preamble);
    const ns_rewrites = ns_result.rewrites;
    const ns_inlines = ns_result.inlines;
    const combined_preamble = ns_result.combined_preamble;

    // ESM+CJS 혼합 모듈(esm_with_dynamic_fallback)이 scope hoisting될 때
    // 내부 require() 호출도 require_xxx()로 치환해야 함.
    const require_rewrites = try self.buildRequireRewrites(&m);

    // ns_var_list → dev_ns_vars: backing slice 소유권 이전 (복사 없음)
    const dev_ns_vars: ?[]const []const u8 = if (ns_var_list.items.len > 0)
        try ns_var_list.toOwnedSlice(self.allocator)
    else
        null;

    // #1791 IIFE unresolved 진단 소유권 이전
    const pending_diags_slice: []const @import("../types.zig").BundlerDiagnostic = if (pending_diags.items.len > 0)
        try pending_diags.toOwnedSlice(self.allocator)
    else
        &.{};

    return .{
        .skip_nodes = skip_nodes,
        .renames = renames,
        .final_exports = final_exports,
        .symbol_ids = sem.symbol_ids,
        .cjs_import_preamble = combined_preamble,
        .require_rewrites = require_rewrites,
        .default_export_name = default_export_name,
        .ns_member_rewrites = ns_rewrites,
        .ns_inline_objects = ns_inlines,
        .const_values = const_values,
        .export_getter_overrides = export_getter_overrides,
        .owned_rename_values = owned_nested_renames,
        .dev_ns_vars = dev_ns_vars,
        .pending_diagnostics = pending_diags_slice,
        .allocator = self.allocator,
    };
}

/// 모듈의 import_records에서 require() → CJS 모듈 대상의 specifier → require_xxx() 맵 구축.
/// CJS 래핑 모듈과 scope hoisted ESM+CJS 혼합 모듈 모두에서 사용.
pub fn buildRequireRewrites(self: *const Linker, m: *const Module) !std.StringHashMapUnmanaged([]const u8) {
    var require_rewrites: std.StringHashMapUnmanaged([]const u8) = .{};
    const self_idx = m.index.toU32();
    for (m.import_records) |rec| {
        if (rec.resolved.isNone()) {
            // UMD/AMD: external require → factory 매개변수 참조.
            // require("react") → React (factory params에서 주입)
            if (rec.is_external and (self.format == .umd or self.format == .amd)) {
                if (!require_rewrites.contains(rec.specifier)) {
                    const param = try types.specifierToParamName(self.allocator, rec.specifier);
                    defer self.allocator.free(param);
                    // "(React)" 형태로 저장 — emitRewriteValue가 '('로 시작하면 ()를 붙이지 않음
                    const owned = try std.fmt.allocPrint(self.allocator, "({s})", .{param});
                    try require_rewrites.put(self.allocator, rec.specifier, owned);
                }
            }
            continue;
        }
        const target = @intFromEnum(rec.resolved);
        const target_mod = self.graph.getModule(rec.resolved) orelse continue;

        // 자기 자신을 require하는 경우: init 재귀 호출 없이 자신의 exports만 참조.
        // RN 패턴: ProgressBarAndroid.js가 require('./ProgressBarAndroid')로 자신을 참조.
        if (target == self_idx) {
            if (m.wrap_kind == .esm) {
                if (require_rewrites.get(rec.specifier)) |old| {
                    self.allocator.free(old);
                }
                const exports_name = try m.allocExportsName(self.allocator);
                defer self.allocator.free(exports_name);
                // #1621: minify 시 __toCommonJS → $tC 축약.
                const to_cjs_name: []const u8 = if (self.minify_whitespace) rt.NAMES.TOCOMMONJS_MIN else "__toCommonJS";
                const call_expr = try std.fmt.allocPrint(self.allocator, "{s}({s})", .{ to_cjs_name, exports_name });
                try require_rewrites.put(self.allocator, rec.specifier, call_expr);
            } else if (m.wrap_kind == .cjs) {
                if (require_rewrites.get(rec.specifier)) |old| {
                    self.allocator.free(old);
                }
                const call_expr = try self.allocator.dupe(u8, "module.exports");
                try require_rewrites.put(self.allocator, rec.specifier, call_expr);
            }
            continue;
        }

        if (target_mod.wrap_kind == .cjs) {
            // CJS 타겟: require("spec") → require_xxx()
            if (require_rewrites.get(rec.specifier)) |old| {
                self.allocator.free(old);
            }
            const var_name = try types.makeRequireVarName(self.allocator, target_mod.path);
            try require_rewrites.put(self.allocator, rec.specifier, var_name);
        } else if (target_mod.wrap_kind == .esm) {
            // ESM 타겟: require("spec") → (init_xxx(), __toCommonJS(exports_xxx))
            if (require_rewrites.get(rec.specifier)) |old| {
                self.allocator.free(old);
            }
            if (self.dev_mode) {
                const call_expr = try types.fmtDevRequireExpr(self.allocator, target_mod.dev_id);
                try require_rewrites.put(self.allocator, rec.specifier, call_expr);
            } else {
                const init_name = try target_mod.allocInitName(self.allocator);
                defer self.allocator.free(init_name);
                const exports_name = try target_mod.allocExportsName(self.allocator);
                defer self.allocator.free(exports_name);
                // #1621: minify 시 __toCommonJS → $tC 축약.
                const to_cjs_name: []const u8 = if (self.minify_whitespace) rt.NAMES.TOCOMMONJS_MIN else "__toCommonJS";
                const call_expr = try std.fmt.allocPrint(self.allocator, "({s}(), {s}({s}))", .{ init_name, to_cjs_name, exports_name });
                try require_rewrites.put(self.allocator, rec.specifier, call_expr);
            }
        }
    }
    return require_rewrites;
}

/// 엔트리 포인트의 최종 export 문을 생성한다. (e.g. "export { x, y$1 as y };\n")
/// is_entry가 false이거나 export가 없으면 null 반환.
pub fn buildFinalExports(
    self: *const Linker,
    is_entry: bool,
    module_index: u32,
    export_bindings: []const ExportBinding,
) !?[]const u8 {
    if (!is_entry or export_bindings.len == 0) return null;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(self.allocator);
    try buf.appendSlice(self.allocator, "export {");
    var first = true;
    for (export_bindings) |eb| {
        if (eb.kind.isReExportAll()) continue;
        if (std.mem.eql(u8, eb.exported_name, "*")) continue;
        if (!first) try buf.appendSlice(self.allocator, ",");
        first = false;
        const actual_name = self.getCanonicalForExport(eb, module_index);
        try buf.append(self.allocator, ' ');
        try buf.appendSlice(self.allocator, actual_name);
        if (!std.mem.eql(u8, actual_name, eb.exported_name)) {
            try buf.appendSlice(self.allocator, " as ");
            try buf.appendSlice(self.allocator, eb.exported_name);
        }
    }
    try buf.appendSlice(self.allocator, " };\n");
    if (!first) {
        return try self.allocator.dupe(u8, buf.items);
    }
    return null;
}

/// 크로스-모듈 상수 인라인 맵을 생성한다.
/// import binding의 canonical export가 상수이면 symbol_id → ConstValue 매핑을 반환.
pub fn buildCrossModuleConstValues(
    self: *const Linker,
    m: *const Module,
    _: @import("../module.zig").ModuleSemanticData,
) !std.AutoHashMapUnmanaged(u32, @import("../../semantic/symbol.zig").ConstValue) {
    var const_values: std.AutoHashMapUnmanaged(u32, @import("../../semantic/symbol.zig").ConstValue) = .{};
    for (m.import_bindings) |ib| {
        if (ib.import_record_index >= m.import_records.len) continue;
        const rec = m.import_records[ib.import_record_index];
        if (rec.resolved.isNone()) continue;
        const canon = self.resolveExportChain(rec.resolved, ib.imported_name, 0) orelse continue;
        const target_module = self.graph.getModule(canon.module_index) orelse continue;
        const target_sem = target_module.semantic orelse continue;
        if (target_sem.scope_maps.len == 0) continue;
        // export_name → local_name 매핑
        var local_name = canon.export_name;
        for (target_module.export_bindings) |eb| {
            if (std.mem.eql(u8, eb.exported_name, canon.export_name)) {
                local_name = target_module.exportBindingLocalName(eb);
                break;
            }
        }
        const target_sym_idx = target_sem.scope_maps[0].get(local_name) orelse continue;
        if (target_sym_idx >= target_sem.symbols.items.len) continue;
        const target_sym = target_sem.symbols.items[target_sym_idx];
        const cv = target_sym.const_value;
        if (cv.kind == .none or !cv.isSafeToInline()) continue;
        // const promotion: `let` 선언에 const_value가 설정되어 있어도 재할당이 있다면 skip.
        // `const`는 재할당 불가라 write_count가 무조건 0. `let` + write_count>0는 inline 금지.
        // 예: `export let counter = 42; counter++;` → counter 참조를 42로 inline하면 버그.
        if (target_sym.write_count > 0) continue;
        // import binding의 local symbol에 매핑
        if (ib.local_symbol.semanticIndex()) |local_sym| {
            try const_values.put(self.allocator, local_sym, cv);
        }
    }
    return const_values;
}

/// namespace 리스트의 소유권을 이동하고, namespace preamble을 CJS preamble과 합친다.
/// ns_rewrite_list와 ns_inline_list는 이 함수 호출 후 deinit된다.
pub fn finalizeNamespaceData(
    allocator: std.mem.Allocator,
    ns_rewrite_list: *std.ArrayList(LinkingMetadata.NsMemberRewrites.Entry),
    ns_inline_list: *std.ArrayList(LinkingMetadata.NsInlineObjects.Entry),
    cjs_import_preamble: ?[]const u8,
) !struct {
    rewrites: LinkingMetadata.NsMemberRewrites,
    inlines: LinkingMetadata.NsInlineObjects,
    combined_preamble: ?[]const u8,
} {
    const ns_rewrites: LinkingMetadata.NsMemberRewrites = if (ns_rewrite_list.items.len > 0)
        .{ .entries = try allocator.dupe(LinkingMetadata.NsMemberRewrites.Entry, ns_rewrite_list.items) }
    else
        .{};
    ns_rewrite_list.deinit(allocator);

    const ns_inlines: LinkingMetadata.NsInlineObjects = if (ns_inline_list.items.len > 0)
        .{ .entries = try allocator.dupe(LinkingMetadata.NsInlineObjects.Entry, ns_inline_list.items) }
    else
        .{};
    ns_inline_list.deinit(allocator);

    // namespace 변수 선언을 preamble에 추가: var gql = {parse: parse, ...};
    var ns_preamble = PreambleWriter.init(allocator);
    defer ns_preamble.deinit();
    for (ns_inlines.entries) |entry| {
        try ns_preamble.writeNamespaceObject(entry.var_name, entry.object_literal);
    }
    const combined_preamble = try ns_preamble.concatWith(cjs_import_preamble);

    return .{
        .rewrites = ns_rewrites,
        .inlines = ns_inlines,
        .combined_preamble = combined_preamble,
    };
}

/// import binding의 local_span으로 symbol_id를 탐색한다.
/// 파서에서 import specifier의 로컬 이름은 identifier_reference 또는 binding_identifier로 생성되므로
/// 두 태그 모두 매칭한다.
fn findSymbolIdBySpan(symbol_ids: []const ?u32, ast: *const Ast, span: Span) ?u32 {
    const node_count = ast.nodes.items.len;
    for (symbol_ids, 0..) |maybe_sid, node_i| {
        if (maybe_sid) |sid| {
            if (node_i >= node_count) continue;
            const node = ast.nodes.items[node_i];
            if ((node.tag == .binding_identifier or node.tag == .identifier_reference) and
                node.span.start == span.start and node.span.end == span.end)
            {
                return sid;
            }
        }
    }
    return null;
}

/// Dev mode용 LinkingMetadata를 생성한다.
///
/// 프로덕션 buildMetadataForAst와의 차이:
///   - renames: named import에 한해 namespace 접근 패턴 renames 생성
///   - cjs_import_preamble: `__ns_N = __zts_require("./path")` 형태 (namespace 할당)
///   - final_exports: 모든 모듈에 `exports.x = x;` 형태 (entry만이 아닌 전체)
pub fn buildDevMetadataForAst(
    self: *const Linker,
    ast: *const Ast,
    module_index: u32,
) !LinkingMetadata {
    const m_opt = self.getModule(module_index);
    if (m_opt == null) {
        return .{
            .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };
    }

    const m = m_opt.?.*;

    // CJS 래핑 모듈은 dev mode에서도 기존대로 유지
    if (m.wrap_kind == .cjs) {
        const node_count = ast.nodes.items.len;
        return .{
            .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count),
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = null,
            .symbol_ids = if (m.semantic) |sem| sem.symbol_ids else &.{},
            .cjs_import_preamble = null,
            .allocator = self.allocator,
        };
    }

    var skip_nodes = try buildSkipNodes(self.allocator, ast, true);
    errdefer skip_nodes.deinit();

    // 2. __zts_require preamble 생성
    var dev_preamble = PreambleWriter.init(self.allocator);
    defer dev_preamble.deinit();

    // bindings를 import_record_index별로 분류
    const RecordInfo = struct {
        default_local: ?[]const u8 = null,
        namespace_local: ?[]const u8 = null,
        named_start: u32 = 0,
        named_count: u32 = 0,
    };
    const record_infos = try self.allocator.alloc(RecordInfo, m.import_records.len);
    defer self.allocator.free(record_infos);
    @memset(record_infos, RecordInfo{});

    var total_named: u32 = 0;
    for (m.import_bindings) |ib| {
        if (ib.import_record_index >= m.import_records.len) continue;
        const info = &record_infos[ib.import_record_index];
        switch (ib.kind) {
            .default => info.default_local = ib.local_name,
            .namespace => info.namespace_local = ib.local_name,
            .named => {
                info.named_count += 1;
                total_named += 1;
            },
        }
    }

    // prefix sum + write cursor 리셋을 한 패스로
    var prefix: u32 = 0;
    for (record_infos) |*info| {
        info.named_start = prefix;
        prefix += info.named_count;
        info.named_count = 0;
    }

    const named_bindings = try self.allocator.alloc(PreambleWriter.NamePair, total_named);
    defer self.allocator.free(named_bindings);

    for (m.import_bindings) |ib| {
        if (ib.import_record_index >= m.import_records.len) continue;
        if (ib.kind != .named) continue;
        const info = &record_infos[ib.import_record_index];
        named_bindings[info.named_start + info.named_count] = .{ .local = ib.local_name, .imported = ib.imported_name };
        info.named_count += 1;
    }

    // namespace 접근 패턴: named import → namespace 변수 프로퍼티 접근.
    // 호이스팅된 함수에서 import binding을 안전하게 참조하기 위해
    // 개별 구조분해 대신 namespace 객체를 사용한다 (rolldown 방식).
    //
    // Before: var { useState } = __zts_require("react");  (inside __esm, function-scoped)
    // After:  __ns_0 = __zts_require("react");             (inside __esm, assign-only)
    //         var __ns_0;                                   (hoisted outside __esm)
    //         → codegen: useState → __ns_0.useState

    // record별 namespace 변수명 생성
    var ns_record_count: u32 = 0;
    for (record_infos[0..m.import_records.len]) |info_r| {
        if (info_r.named_count > 0) ns_record_count += 1;
    }

    var dev_ns_vars: ?[][]const u8 = null;
    const ns_var_for_record = try self.allocator.alloc(?[]const u8, m.import_records.len);
    defer self.allocator.free(ns_var_for_record);
    @memset(ns_var_for_record, null);

    if (ns_record_count > 0) {
        const vars = try self.allocator.alloc([]const u8, ns_record_count);
        var vi: u32 = 0;
        for (record_infos[0..m.import_records.len], 0..) |info_r, ri| {
            if (info_r.named_count > 0) {
                vars[vi] = try std.fmt.allocPrint(self.allocator, NS_VAR_PREFIX ++ "{d}_{d}", .{ module_index, vi });
                ns_var_for_record[ri] = vars[vi];
                vi += 1;
            }
        }
        dev_ns_vars = vars;
    }
    errdefer if (dev_ns_vars) |vars| {
        for (vars) |v| self.allocator.free(v);
        self.allocator.free(vars);
    };

    // named binding의 symbol_id → "ns_var.imported_name" renames 등록
    var renames = std.AutoHashMap(u32, []const u8).init(self.allocator);
    errdefer renames.deinit();
    var owned_rename_values: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (owned_rename_values.items) |v| self.allocator.free(v);
        owned_rename_values.deinit(self.allocator);
    }

    if (ns_record_count > 0) {
        if (m.semantic) |sem| {
            for (m.import_bindings) |ib| {
                if (ib.kind != .named) continue;
                if (ib.import_record_index >= m.import_records.len) continue;
                const ns_var = ns_var_for_record[ib.import_record_index] orelse continue;
                // binding_identifier의 span으로 symbol_id 탐색
                const sym_id = findSymbolIdBySpan(sem.symbol_ids, ast, ib.local_span) orelse continue;
                const rename = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ns_var, ib.imported_name });
                try owned_rename_values.append(self.allocator, rename);
                try renames.put(sym_id, rename);
            }
        }
    }

    for (m.import_records, 0..) |rec, i| {
        if (rec.resolved.isNone()) continue;
        if (rec.kind == .dynamic_import) continue;

        const info = record_infos[i];
        if (info.default_local == null and info.namespace_local == null and info.named_count == 0) continue;

        // dev_id: 번들 진입 시 한 번 계산된 모듈 ID (ID 일원화)
        const resolved_mod_ptr = self.graph.getModule(rec.resolved);
        const resolved_path = if (resolved_mod_ptr) |rmp| rmp.dev_id else rec.specifier;

        // CJS 타겟이면 __toESM 래핑 (default/namespace import에서 CJS interop 필요)
        const is_cjs_target = resolved_mod_ptr != null and resolved_mod_ptr.?.wrap_kind == .cjs;

        if (info.namespace_local) |ns_local| {
            try dev_preamble.writeDevRequireInterop(ns_local, resolved_path, null, is_cjs_target, false);
        }
        if (info.default_local) |def_local| {
            try dev_preamble.writeDevRequireInterop(def_local, resolved_path, ".default", is_cjs_target, false);
        }
        if (info.named_count > 0) {
            // namespace 접근 패턴: assign-only (var는 esm_wrap에서 호이스팅)
            if (ns_var_for_record[i]) |ns_var| {
                try dev_preamble.writeDevRequireInterop(ns_var, resolved_path, null, is_cjs_target, true);
            }
        }
    }

    const cjs_import_preamble = try dev_preamble.toOwned();

    // 3. exports 할당 생성 (모든 모듈, entry 여부 무관)
    var final_exports: ?[]const u8 = null;
    if (m.export_bindings.len > 0) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        for (m.export_bindings) |eb| {
            if (eb.kind.isReExportAll()) continue;
            if (std.mem.eql(u8, eb.exported_name, "*")) continue;

            // exports.name = local_name;
            // re-export의 경우: exports.name = __zts_require("./dep").name;
            if (eb.kind == .re_export) {
                if (eb.import_record_index) |iri| {
                    if (iri < m.import_records.len) {
                        const irec = m.import_records[iri];
                        if (!irec.resolved.isNone()) {
                            const re_path = if (self.graph.getModule(irec.resolved)) |re_m| re_m.dev_id else irec.specifier;
                            try buf.appendSlice(self.allocator, "exports.");
                            try buf.appendSlice(self.allocator, eb.exported_name);
                            try buf.appendSlice(self.allocator, " = __zts_require(\"");
                            try buf.appendSlice(self.allocator, re_path);
                            try buf.appendSlice(self.allocator, "\").");
                            try buf.appendSlice(self.allocator, m.exportBindingLocalName(eb));
                            try buf.appendSlice(self.allocator, ";\n");
                            continue;
                        }
                    }
                }
            }

            try buf.appendSlice(self.allocator, "exports.");
            try buf.appendSlice(self.allocator, eb.exported_name);
            try buf.appendSlice(self.allocator, " = ");
            try buf.appendSlice(self.allocator, m.exportBindingLocalName(eb));
            try buf.appendSlice(self.allocator, ";\n");
        }

        if (buf.items.len > 0) {
            final_exports = try self.allocator.dupe(u8, buf.items);
        }
    }

    const sem = m.semantic orelse return .{
        .skip_nodes = skip_nodes,
        .renames = renames,
        .final_exports = final_exports,
        .symbol_ids = &.{},
        .cjs_import_preamble = cjs_import_preamble,
        .dev_ns_vars = dev_ns_vars,
        .owned_rename_values = owned_rename_values,
        .allocator = self.allocator,
    };

    return .{
        .skip_nodes = skip_nodes,
        .renames = renames,
        .final_exports = final_exports,
        .symbol_ids = sem.symbol_ids,
        .cjs_import_preamble = cjs_import_preamble,
        .dev_ns_vars = dev_ns_vars,
        .owned_rename_values = owned_rename_values,
        .allocator = self.allocator,
    };
}

/// 특정 모듈에 대한 LinkingMetadata를 생성한다 (원본 AST 기준, 테스트용).
pub fn buildMetadata(self: *const Linker, module_index: u32, is_entry: bool) !LinkingMetadata {
    const m_opt = self.getModule(module_index);
    if (m_opt == null) {
        return .{
            .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };
    }

    const m = m_opt.?.*;
    const ast = m.ast orelse {
        return .{
            .skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, 0),
            .renames = std.AutoHashMap(u32, []const u8).init(self.allocator),
            .final_exports = null,
            .symbol_ids = &.{},
            .allocator = self.allocator,
        };
    };

    const node_count = ast.nodes.items.len;
    var skip_nodes = try std.DynamicBitSet.initEmpty(self.allocator, node_count);
    var renames = std.AutoHashMap(u32, []const u8).init(self.allocator);

    // 1. import_declaration → 전체 스킵
    for (ast.nodes.items, 0..) |node, node_idx| {
        if (node.tag == .import_declaration) {
            skip_nodes.set(node_idx);
        }
    }

    // 2. export 키워드 처리
    for (ast.nodes.items, 0..) |node, node_idx| {
        switch (node.tag) {
            .export_named_declaration => {
                const e = node.data.extra;
                if (e + 3 >= ast.extra_data.items.len) continue;
                const decl_idx_raw = ast.extra_data.items[e];
                const decl_idx: NodeIndex = @enumFromInt(decl_idx_raw);
                const source_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 3]);

                if (!decl_idx.isNone()) {
                    // export const x = 1; → export 노드 스킵, declaration은 유지
                    // codegen은 skip_nodes에 있으면 emitNode를 건너뜀.
                    // declaration을 직접 출력하기 위해 export_named_declaration을 스킵하고
                    // declaration 노드만 남김.
                    // 하지만 이렇게 하면 declaration도 스킵됨...
                    // 대신: export_named_declaration을 스킵하지 않고,
                    // codegen에서 linking 모드일 때 "export " 키워드만 생략하도록 함.
                    // → skip_nodes 대신 codegen 분기로 처리 (PR #5 codegen 수정에서)
                } else if (!source_idx.isNone()) {
                    // export { x } from './dep' — re-export: 전체 스킵
                    skip_nodes.set(node_idx);
                } else {
                    // export { x } — 로컬 export: 전체 스킵 (심볼은 이미 선언됨)
                    skip_nodes.set(node_idx);
                }
            },
            .export_default_declaration => {
                // export default expr — 비-엔트리 모듈에서는 스킵
                if (!is_entry) {
                    skip_nodes.set(node_idx);
                }
            },
            .export_all_declaration => {
                // export * from './dep' — 전체 스킵
                skip_nodes.set(node_idx);
            },
            else => {},
        }
    }

    const sem = m.semantic orelse return .{
        .skip_nodes = skip_nodes,
        .renames = renames,
        .final_exports = null,
        .symbol_ids = &.{},
        .allocator = self.allocator,
    };

    // 3. import 바인딩: import된 심볼을 canonical 이름으로 치환
    // import binding의 심볼 인덱스를 모듈 스코프에서 이름으로 조회
    if (sem.scope_maps.len > 0) {
        for (m.import_bindings) |ib| {
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (rec.resolved.isNone()) continue;
            const sym_idx = ib.local_symbol.semanticIndex() orelse continue;

            const target_name = self.getCanonicalByRef(ib.symbol) orelse ib.imported_name;
            const local_name = m.importBindingLocalName(ib);

            if (!std.mem.eql(u8, local_name, target_name)) {
                try renames.put(sym_idx, target_name);
            }
        }
    }

    // 4. 이 모듈 자체의 top-level 심볼 리네임 (이름 충돌로 인한)
    if (sem.scope_maps.len > 0) {
        const module_scope = sem.scope_maps[0];
        var sit = module_scope.iterator();
        while (sit.next()) |scope_entry| {
            const sym_name = scope_entry.key_ptr.*;
            if (self.getCanonicalName(module_index, sym_name)) |renamed| {
                const sym_idx = scope_entry.value_ptr.*;
                try renames.put(@intCast(sym_idx), renamed);
            }
        }
    }

    // 5. 엔트리 포인트: final exports
    var final_exports: ?[]const u8 = null;
    if (is_entry and m.export_bindings.len > 0) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "export {");
        var first = true;
        for (m.export_bindings) |eb| {
            if (eb.kind.isReExportAll()) continue;
            if (std.mem.eql(u8, eb.exported_name, "*")) continue;

            if (!first) try buf.appendSlice(self.allocator, ",");
            first = false;

            const actual_name = self.getCanonicalForExport(eb, module_index);

            try buf.append(self.allocator, ' ');
            try buf.appendSlice(self.allocator, actual_name);
            if (!std.mem.eql(u8, actual_name, eb.exported_name)) {
                try buf.appendSlice(self.allocator, " as ");
                try buf.appendSlice(self.allocator, eb.exported_name);
            }
        }
        try buf.appendSlice(self.allocator, " };\n");
        if (!first) {
            final_exports = try self.allocator.dupe(u8, buf.items);
        }
    }

    return .{
        .skip_nodes = skip_nodes,
        .renames = renames,
        .final_exports = final_exports,
        .symbol_ids = sem.symbol_ids,
        .allocator = self.allocator,
    };
}
