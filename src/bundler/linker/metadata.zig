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
const profile = @import("../../profile.zig");
const debug_log = @import("../../debug_log.zig");
const makeExportKey = types.makeModuleKey;
const makeExportKeyBuf = types.makeModuleKeyBuf;
const PreambleWriter = linker_mod.PreambleWriter;
const NsExportPair = Linker.NsExportPair;
const getOrCreateRequireVar = linker_mod.getOrCreateRequireVar;
const isNamespaceUsedAsValue = Linker.isNamespaceUsedAsValue;
const isReservedName = Linker.isReservedName;
const NamePair = PreambleWriter.NamePair;
const NS_VAR_PREFIX = linker_mod.NS_VAR_PREFIX;
const EXPR_RENAME_MARKER = linker_mod.EXPR_RENAME_MARKER;

inline fn cjsInteropMode(self: *const Linker, importer: *const Module) types.Interop {
    if (self.graph.resolve_cache.platform == .react_native) return .babel;
    return if (importer.def_format.isEsm()) .node else .babel;
}

/// #1791 Phase D: import binding 의 local 이 value 로 참조된 적이 있는지 조회.
/// analyzer 가 각 Reference 에 `type_context` / `value_as_type` flag 를 기록하므로,
/// symbol 의 Reference 들 중 **순수 value read** 가 하나라도 있으면 false. 하나도 없으면
/// true → preamble / canonical rename 을 skip 해 bare `require()` fallback (RN factory
/// ReferenceError) 을 방지.
///
/// 기존 `reference_count == 0` 접근은 mangler 전용 카운트를 재활용해 false positive 가
/// 났음 (#1793 revert). 이제 Reference 단위로 value/type 문맥을 구분.
///
/// synthetic binding (JSX runtime 등) 은 semantic 이 추적하지 않으므로 "사용 중" 간주.
/// `references` 가 비어있어도 보수적 보존. 호출자가 `verbatim_module_syntax` 를 먼저
/// 확인해 true 이면 이 경로를 bypass.
/// #1824: IIFE/UMD/AMD wrapper 의 external → factory-param 이름 결정.
/// 정책:
///   - IIFE: `--globals` 매핑된 spec 만 반환 (없으면 null → linker 가 fatal #1791).
///     caller args 가 글로벌 변수 참조라 사용자가 명시 안 하면 어떤 이름인지 알 수 없음.
///   - UMD/AMD: 매핑 우선, 없으면 specifier 의 PascalCase 자동 추정 (rollup/rolldown 관행).
///     emitter 가 동일 정책으로 wrapper 의 factory param 을 만들기 때문에 일관 유지.
/// 반환 slice 는 allocator 소유 — 호출자가 free.
inline fn mappedExternalParam(
    format: types.Format,
    globals: []const types.GlobalEntry,
    rec: types.ImportRecord,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!?[]const u8 {
    if (!rec.is_external) return null;
    const mapped = types.GlobalEntry.lookup(globals, rec.specifier);
    switch (format) {
        .iife => {
            const gname = mapped orelse return null;
            return try allocator.dupe(u8, gname);
        },
        .umd, .amd => {
            if (mapped) |gname| return try allocator.dupe(u8, gname);
            return try types.specifierToParamName(allocator, rec.specifier);
        },
        else => return null,
    }
}

pub fn isImportBindingTypeOnly(sem: *const @import("../module.zig").ModuleSemanticData, ib: ImportBinding) bool {
    // helper binding (JSX runtime / runtime helper) 은 런타임 호출이라 type-only 가 아니다.
    if (ib.is_helper) return false;
    // named 한정 — default / namespace 는 JSX pragma 등 implicit value use 위험이
    // 큼 (#1793 revert 원인). transformer 와 동일 제한.
    if (ib.kind != .named) return false;
    const sym_idx = ib.local_symbol.semanticIndex() orelse return false;
    if (sym_idx >= sem.symbols.items.len) return false;
    // 판정 로직은 `Reference.isValueUse` 에 집약 — transformer 의
    // `isImportSpecifierUnused` 와 동일 기준. TODO #1791: `references` 를 매번 linear
    // scan 하는 대신 모듈별 `symbol_id → Reference indices` 맵 사전 구축 고려 (실측 후).
    for (sem.references) |r| {
        if (@intFromEnum(r.symbol_id) != sym_idx) continue;
        if (r.isValueUse()) return false;
    }
    return true;
}

fn allocEsmInitExpr(self: *const Linker, target_mod: *const Module) ![]const u8 {
    const guard_close_expr = "})";
    const guard = target_mod.shouldGuard(self.entry_error_guard);
    if (self.dev_mode) {
        if (guard) {
            return try std.fmt.allocPrint(
                self.allocator,
                "{s}__zntc_modules[\"{s}\"].fn(){s}",
                .{ if (self.minify_whitespace) rt.GUARD_LAMBDA_OPEN_MIN else rt.GUARD_LAMBDA_OPEN, target_mod.dev_id, guard_close_expr },
            );
        }
        return try std.fmt.allocPrint(self.allocator, "__zntc_modules[\"{s}\"].fn()", .{target_mod.dev_id});
    }

    const init_name = try target_mod.allocInitName(self.allocator);
    defer self.allocator.free(init_name);
    if (guard) {
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}{s}(){s}",
            .{ if (self.minify_whitespace) rt.GUARD_LAMBDA_OPEN_MIN else rt.GUARD_LAMBDA_OPEN, init_name, guard_close_expr },
        );
    }
    return try std.fmt.allocPrint(self.allocator, "{s}()", .{init_name});
}

fn allocLazyEsmImportExpr(self: *const Linker, import_mod: *const Module, value_mod: *const Module, target_name: []const u8) ![]const u8 {
    const sep = if (self.minify_whitespace) "," else ", ";
    const import_init = try allocEsmInitExpr(self, import_mod);
    defer self.allocator.free(import_init);
    if (import_mod.index == value_mod.index) {
        return try std.fmt.allocPrint(self.allocator, "({s}{s}{s})", .{ import_init, sep, target_name });
    }

    const value_init = try allocEsmInitExpr(self, value_mod);
    defer self.allocator.free(value_init);
    return try std.fmt.allocPrint(self.allocator, "({s}{s}{s}{s}{s})", .{ import_init, sep, value_init, sep, target_name });
}

fn appendEsmInitCall(self: *const Linker, preamble: anytype, target_mod: *const Module) !void {
    const is_tla = target_mod.uses_top_level_await;
    const guard = target_mod.shouldGuard(self.entry_error_guard);
    if (is_tla) try preamble.write("await ");
    if (guard) try preamble.write(if (self.minify_whitespace) rt.GUARD_LAMBDA_OPEN_MIN else rt.GUARD_LAMBDA_OPEN);
    if (self.dev_mode) {
        try preamble.write("__zntc_modules[\"");
        try preamble.write(target_mod.dev_id);
        try preamble.write("\"].fn()");
    } else {
        const init_name = try target_mod.allocInitName(self.allocator);
        defer self.allocator.free(init_name);
        try preamble.write(init_name);
        try preamble.write("()");
    }
    try preamble.write(if (guard) rt.GUARD_LAMBDA_CLOSE else rt.INIT_CALL_END);
}

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

/// rename 문자열을 dupe 해서 metadata 가 소유하도록 저장 (#2429). canonical_strings /
/// unified_result 의 borrowed slice 는 per-chunk recompute 또는 deinit 시 freed →
/// 0xAA UAF 발생. dupe + owned 추적으로 회피.
fn putOwnedRename(
    self: *const Linker,
    renames: *std.AutoHashMap(u32, []const u8),
    owned: *std.ArrayListUnmanaged([]const u8),
    sid: u32,
    src: []const u8,
) !void {
    const v = try self.allocator.dupe(u8, src);
    try owned.append(self.allocator, v);
    try renames.put(sid, v);
}

/// identifier 의 첫 byte 가 정상 ASCII (0x21-0x7F) 인지. UAF 시 채워지는 0xAA / 0 등
/// invalid byte 를 reject — `target_name` 이 freed memory 면 rename 등록 skip.
fn isValidIdentStartByte(b: u8) bool {
    return b >= 0x21 and b < 0x80;
}

/// `Linker.unified_result` 에서 현재 모듈의 Phase B (nested) rename 을
/// `renames` 에 merge. Phase A 심볼 (module_scope_symbols bitset set) 은
/// 스킵 — self-rename 루프가 canonical_name 경로로 이미 처리했음.
fn mergeUnifiedPhaseB(
    self: *const Linker,
    module_index: u32,
    renames: *std.AutoHashMap(u32, []const u8),
    owned: *std.ArrayListUnmanaged([]const u8),
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
        try putOwnedRename(self, renames, owned, sid, entry.value_ptr.*);
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
    var skip_nodes = blk: {
        var sn_scope = profile.begin(.metadata_skip_nodes);
        defer sn_scope.end();
        var audit = debug_log.auditScope(.metadata_audit);
        const result = try buildSkipNodes(self.allocator, ast, skip_imports);
        if (audit.on) debug_log.print(.metadata_audit, "sn wrap={s} nodes={d} ns={d}\n", .{ @tagName(m.wrap_kind), ast.nodes.items.len, audit.elapsedNs() });
        break :blk result;
    };
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

    // 같은 importer 안에서 여러 namespace import 가 같은 source 의 hoisted ns_var 를
    // 공유하도록 caller-owned cache. registerNamespaceRewrites 가 source mod_idx 별로
    // ns_var_name 을 dedup. 값 (var_name) 의 owner 는 ns_inline_list — 중복 free 안 함.
    var ns_target_to_var = std.AutoHashMap(u32, []const u8).init(self.allocator);
    defer ns_target_to_var.deinit();

    // CJS 모듈별 require_xxx 변수명 캐시 (같은 모듈에서 여러 named import 시 중복 생성 방지)
    var cjs_var_cache = std.AutoHashMap(u32, []const u8).init(self.allocator);
    defer {
        var vit = cjs_var_cache.valueIterator();
        while (vit.next()) |v| self.allocator.free(v.*);
        cjs_var_cache.deinit();
    }

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
        var ib_scope = profile.begin(.metadata_import_bindings);
        defer ib_scope.end();
        var audit = debug_log.auditScope(.metadata_audit);
        const ib_preamble_start: usize = if (audit.on) preamble.buf.items.len else 0;
        defer if (audit.on) debug_log.print(.metadata_audit, "ib wrap={s} bindings={d} scopes={d} renames={d} preamble_bytes={d} ns={d}\n", .{ @tagName(m.wrap_kind), m.import_bindings.len, sem.scope_maps.len, renames.count(), preamble.buf.items.len - ib_preamble_start, audit.elapsedNs() });
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

            // Phase D elision: transformer 가 AST 에서 specifier 를 drop 하는 것과 대칭으로
            // linker 도 preamble 생성을 건너뛴다. verbatim_module_syntax=true 면 양쪽 모두 보존.
            if (!self.verbatim_module_syntax and isImportBindingTypeOnly(&sem, ib)) continue;

            // resolve 미완료: external 또는 resolve 실패.
            if (rec.resolved.isNone()) {
                if (rec.is_lazy_resolved) continue;
                if (rec.kind == .static_import or rec.kind == .side_effect or rec.kind == .re_export) {
                    if (!ib.is_helper and !ib.local_symbol.isValid()) continue;
                    const preamble_name = self.getCanonicalByRef(ib.local_symbol) orelse m.importBindingLocalName(ib);
                    // helper binding (JSX runtime 등) + ESM-wrapped 모듈 조합에서는 top-level
                    // 에 이미 `var _jsxDEV, _Fragment;` 선언이 호이스팅됨 (esm_wrap). init 함수
                    // 본문에서 `var` 로 재선언하면 outer scope 를 shadow → #1209.
                    const is_helper_esm = ib.is_helper and m.wrap_kind == .esm;
                    const mapped_param = try mappedExternalParam(self.format, self.iife_globals, rec, self.allocator);
                    if (mapped_param) |param_name| {
                        defer self.allocator.free(param_name);
                        // IIFE/UMD/AMD: factory 매개변수에서 직접 참조. emitter 의 wrapper
                        // factory 시그니처와 동일 이름 (rollup `output.globals` 호환).
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
                    } else if (self.format == .iife and !ib.is_helper) {
                        // #1791 IIFE: 매핑 안 된 unresolved external 은 의미 자체가 성립 안 함
                        // (factory 스코프에 require 없음, top-level import 도 불가).
                        // #1824: --globals 로 매핑된 external 은 위 `is_iife_mapped` 브랜치에서 처리됨.
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
                    } else if (self.format == .esm and rec.is_external and !is_helper_esm) {
                        // #1962 ESM external: chunk top 의 ESM `import` 구문이 binding 을
                        // 제공하므로 모듈 preamble 에 require() 를 두지 않는다.
                        // - emitter 의 `external_imports.emitChunkExternalImports` 가 dedup 후 emit.
                        // - codegen 은 import_declaration 노드를 skip (skip_imports=true).
                        // - canonical rename 은 emitter 측에서 동일 ImportBinding 을 보고 적용.
                        // helper binding + ESM-wrapped 모듈은 init 함수 본문에서 var 할당이
                        // 필요해 require() 경로를 유지한다 (#1209).
                    } else {
                        // CJS / ESM-wrapped + helper / 그 외: require() preamble 생성.
                        if (is_helper_esm) {
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
            // ESM-wrapped 모듈에서 CJS target을 import하는 경우:
            // named import는 `require_xxx().name` 직접 참조로 치환해 top-level
            // binding을 만들지 않는다. default/namespace는 interop 값 자체가 필요하므로
            // outer var를 선언하고 init preamble에서 할당한다.
            const is_helper_binding = ib.is_helper;
            const canonical_m_opt = self.getModule(canonical_mod);
            if (!is_helper_binding and m.wrap_kind == .esm and canonical_m_opt != null and
                (canonical_m_opt.?.wrap_kind == .cjs or canonical_mod == module_index))
            {
                if (canonical_m_opt.?.wrap_kind == .cjs) {
                    const req_var = try getOrCreateRequireVar(self, &cjs_var_cache, @intCast(canonical_mod));
                    if (ib.kind == .named and !std.mem.eql(u8, ib.imported_name, "default")) {
                        if (ib.local_symbol.semanticIndex()) |sym_idx| {
                            const direct_access = try std.fmt.allocPrint(self.allocator, "{s}" ++ EXPR_RENAME_MARKER ++ "{s}", .{ req_var, ib.imported_name });
                            errdefer self.allocator.free(direct_access);
                            try owned_nested_renames.append(self.allocator, direct_access);
                            try renames.put(sym_idx, direct_access);
                        }
                    } else {
                        const interop_mode = cjsInteropMode(self, &m);
                        const preamble_name = self.getCanonicalByRef(ib.local_symbol) orelse m.importBindingLocalName(ib);
                        const hoisted_name = try self.allocator.dupe(u8, preamble_name);
                        errdefer self.allocator.free(hoisted_name);
                        try ns_var_list.append(self.allocator, hoisted_name);
                        if (ib.importsDefault() and m.canUseDirectCjsDefaultImport(canonical_m_opt.?)) {
                            try preamble.writeCjsDirectDefault(preamble_name, req_var, true);
                        } else {
                            try preamble.writeCjsImportAssignOnly(preamble_name, ib.imported_name, req_var, ib.kind == .namespace, interop_mode);
                        }

                        if (ib.local_symbol.semanticIndex()) |sym_idx| {
                            try putOwnedRename(self, &renames, &owned_nested_renames, sym_idx, preamble_name);
                        }
                    }
                }
                continue;
            }

            // CJS 모듈에서 import하는 경우: preamble에서 require_xxx() 호출 생성
            if (canonical_m_opt != null and canonical_m_opt.?.wrap_kind == .cjs) {
                // Tree-shake 가 target 을 번들에서 제외했으면 `__commonJS` wrapper 자체가
                // emit 되지 않아 `require_xxx is not defined` ReferenceError 가 난다.
                // namespace import (`import * as undici`) 의 모든 소비자가 다른 export 의
                // tree-shake 로 사라진 케이스 (cheerio 회귀 #2051) 에서 발생하므로 preamble
                // 도 같이 drop 한다. `tree_shaker_active` 가 false (linker 단독 unit test)
                // 면 `is_included` 비트가 신뢰할 수 없으므로 가드를 적용하지 않는다.
                if (self.tree_shaker_active and !canonical_m_opt.?.is_included) continue;
                const preamble_name = self.getCanonicalByRef(ib.local_symbol) orelse m.importBindingLocalName(ib);
                const req_var = try getOrCreateRequireVar(self, &cjs_var_cache, @intCast(canonical_mod));
                const interop_mode = cjsInteropMode(self, &m);
                // ESM-wrapped + helper binding: top-level 에 이미 var 선언됨 (esm_wrap) → 할당만
                if (is_helper_binding and m.wrap_kind == .esm) {
                    if (ib.importsDefault() and m.canUseDirectCjsDefaultImport(canonical_m_opt.?)) {
                        try preamble.writeCjsDirectDefault(preamble_name, req_var, true);
                    } else {
                        try preamble.writeCjsImportAssignOnly(preamble_name, ib.imported_name, req_var, ib.kind == .namespace, interop_mode);
                    }
                } else {
                    if (ib.importsDefault() and m.canUseDirectCjsDefaultImport(canonical_m_opt.?)) {
                        try preamble.writeCjsDirectDefault(preamble_name, req_var, false);
                    } else {
                        try preamble.writeCjsImport(preamble_name, ib.imported_name, req_var, ib.kind == .namespace, interop_mode);
                    }
                }
                continue;
            }

            // resolveImports()에서 이미 해결한 바인딩을 조회하거나, 직접 해결
            const resolved = self.getResolvedBinding(module_index, ib.local_span);

            // __esm 래핑 모듈에서 import: init_xxx() 호출을 preamble에 추가.
            // 호이스팅된 함수는 top-level에 있으므로 rename으로 참조 가능.
            // init 호출은 모듈당 1회만 (중복 방지는 esm_init_set으로).
            // `entry_error_guard` 활성 시 wrap. TLA 는 await 가 lambda 안에 못 들어가서 제외.
            var lazy_esm_import = false;
            var lazy_esm_import_mod: ?*const Module = null;
            if (canonical_m_opt != null and canonical_m_opt.?.wrap_kind == .esm) {
                // CJS path 와 동일하게 tree-shake 결과 반영 (#2398). `sideEffects: false`
                // 인 .esm wrap 모듈이 unused 로 drop 되면 `init_xxx is not defined` 가
                // 나므로 preamble 도 함께 생략. `tree_shaker_active=false` 인 단위 테스트
                // 환경에서는 is_included bit 가 신뢰 불가라 가드 미적용 (line 408 동일 정책).
                if (self.tree_shaker_active and !canonical_m_opt.?.is_included) continue;
                const target_mod = canonical_m_opt.?;
                // RN inlineRequires 정책: named import 만 `(__zntc_modules[...].
                // fn(), name)` 위치로 lazy 화하고 default / namespace import 는
                // eager require 로 유지한다.
                //
                // Metro 자체의 `inline-requires` Babel plugin 은 default 포함
                // 모든 import 를 `require()` access 로 inline 화한다. Metro 가 그렇게
                // 해도 안전한 이유는 모듈별 side-effect-free 여부를 transformer 단계
                // 에서 분석하기 때문이고 — ZNTC 는 그 정적 안전성 분석을 (아직) 갖고
                // 있지 않다. 그래서 보수적으로 default 만 eager 유지: top-level
                // provider 등록을 하는 모듈 (예: RNFirebase Firestore) 의 부작용이
                // lazy 화로 누락되어 Metro 와 다른 초기화 순서가 되는 것을 차단.
                var value_init_mod = target_mod;
                var value_init_mod_idx = canonical_mod;
                if (resolved) |rb| {
                    const rb_idx = @intFromEnum(rb.canonical.module_index);
                    if (rb_idx != canonical_mod) {
                        if (self.graph.getModule(rb.canonical.module_index)) |rb_mod| {
                            if (rb_mod.wrap_kind == .esm) {
                                value_init_mod = rb_mod;
                                value_init_mod_idx = @intCast(rb_idx);
                            }
                        }
                    }
                }
                if (self.tree_shaker_active and !value_init_mod.is_included) continue;

                lazy_esm_import = self.inline_requires and
                    m.wrap_kind == .esm and
                    rec.kind == .static_import and
                    canonical_mod != module_index and
                    !is_helper_binding and
                    ib.kind == .named and
                    !ib.importsDefault() and
                    !target_mod.uses_top_level_await and
                    !value_init_mod.uses_top_level_await and
                    !exported_locals.contains(m.importBindingLocalName(ib));
                if (lazy_esm_import) {
                    lazy_esm_import_mod = value_init_mod;
                }
                if (!lazy_esm_import and !esm_init_set.contains(@intCast(canonical_mod))) {
                    try esm_init_set.put(@intCast(canonical_mod), {});
                    try appendEsmInitCall(self, &preamble, target_mod);
                }
                if (!lazy_esm_import and value_init_mod_idx != canonical_mod and !esm_init_set.contains(@intCast(value_init_mod_idx))) {
                    try esm_init_set.put(@intCast(value_init_mod_idx), {});
                    try appendEsmInitCall(self, &preamble, value_init_mod);
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
                // shadow 충돌은 registerNamespaceRewrites 가 자체 감지해 ns_inline_list 활성화.
                const force_inline = isNamespaceUsedAsValue(self.allocator, ast, effective_syms, ns_sym_id) or
                    exported_locals.contains(local_name);
                try self.registerNamespaceRewrites(
                    &ns_rewrite_list,
                    &ns_inline_list,
                    &owned_nested_renames,
                    &ns_target_to_var,
                    force_inline,
                    module_index,
                    ns_sym_id,
                    @intCast(canonical_mod),
                    local_name,
                );
                continue;
            }

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
                    const interop_mode2 = cjsInteropMode(self, &m);
                    const effective_name = rb.canonical.export_name;
                    if (std.mem.eql(u8, effective_name, "default") and m.canUseDirectCjsDefaultImport(cjs_mod_opt.?)) {
                        try preamble.writeCjsDirectDefault(preamble_name, req_var, false);
                    } else {
                        try preamble.writeCjsImport(preamble_name, effective_name, req_var, false, interop_mode2);
                    }
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
                                                &owned_nested_renames,
                                                &ns_target_to_var,
                                                true,
                                                module_index,
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
                                    &owned_nested_renames,
                                    &ns_target_to_var,
                                    true,
                                    module_index,
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
            // 방어 — target_name 이 use-after-free 로 0xAA / 0 등 invalid byte 로
            // 채워졌으면 rename 스킵 (#2429).
            if (!isReservedName(target_name) and target_name.len > 0 and isValidIdentStartByte(target_name[0])) {
                if (ib.local_symbol.semanticIndex()) |sym_idx| {
                    const rename_value = if (lazy_esm_import)
                        try allocLazyEsmImportExpr(self, canonical_m_opt.?, lazy_esm_import_mod orelse canonical_m_opt.?, target_name)
                    else
                        target_name;
                    if (lazy_esm_import) {
                        var rename_owned_by_list = false;
                        errdefer if (!rename_owned_by_list) self.allocator.free(rename_value);
                        try owned_nested_renames.append(self.allocator, rename_value);
                        rename_owned_by_list = true;
                        try renames.put(sym_idx, rename_value);
                    } else {
                        try putOwnedRename(self, &renames, &owned_nested_renames, sym_idx, rename_value);
                    }
                    // __esm → __esm live binding: __export getter override 등록 +
                    // 자체 rename 루프에서 덮어쓰기 방지
                    if (m.wrap_kind == .esm and canonical_m_opt != null and
                        canonical_m_opt.?.wrap_kind == .esm)
                    {
                        try export_getter_overrides.put(self.allocator, m.importBindingLocalName(ib), rename_value);
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
                } else if (tmod.wrap_kind == .cjs) {
                    // CJS target의 value import는 metadata rename 또는 preamble에서
                    // 처리한다. 원본 import_declaration을 남기면 body에서 raw
                    // require/destructuring이 다시 emit된다. side-effect-only import는
                    // binding 처리가 없으므로 유지한다.
                    const has_binding = for (m.import_bindings) |ib| {
                        if (ib.import_record_index == rec_i) break true;
                    } else false;
                    if (has_binding) {
                        try hoisted_specifiers.put(rec.specifier, {});
                    }
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
                    try putOwnedRename(self, &renames, &owned_nested_renames, @intCast(scope_entry.value_ptr.*), renamed);
                }
            }
        }

        // nested rename 을 `Linker.unified_result` 에서 조회. Phase A (module
        // scope) 은 위 self-rename 루프에서 canonical_name 경유로 이미 처리됨.
        // metadata 가 dupe 하여 소유 — unified_result 가 deinit 되어도 안전.
        {
            var mb_scope = profile.begin(.metadata_merge_phase_b);
            defer mb_scope.end();
            mergeUnifiedPhaseB(self, module_index, &renames, &owned_nested_renames) catch {};
        }
    }

    // Side-effect-only import has no ImportBinding, so scope-hoisted modules that
    // skip raw import declarations still need an explicit evaluation preamble for
    // wrapped targets.
    if (!m.wrap_kind.isWrapped()) {
        for (m.import_records) |rec| {
            if (rec.kind != .side_effect) continue;
            if (rec.resolved.isNone()) continue;
            const target_mod = self.graph.getModule(rec.resolved) orelse continue;
            if (self.tree_shaker_active and !target_mod.is_included) continue;

            switch (target_mod.wrap_kind) {
                .none => {},
                .cjs => {
                    const req_var = try getOrCreateRequireVar(self, &cjs_var_cache, @intCast(@intFromEnum(rec.resolved)));
                    try preamble.write(req_var);
                    try preamble.write("();\n");
                },
                .esm => {
                    const target = @intFromEnum(rec.resolved);
                    if (esm_init_set.contains(@intCast(target))) continue;
                    try esm_init_set.put(@intCast(target), {});
                    const is_tla = target_mod.uses_top_level_await;
                    const guard = target_mod.shouldGuard(self.entry_error_guard);
                    if (is_tla) try preamble.write("await ");
                    if (guard) try preamble.write(if (self.minify_whitespace) rt.GUARD_LAMBDA_OPEN_MIN else rt.GUARD_LAMBDA_OPEN);
                    if (self.dev_mode) {
                        try preamble.write("__zntc_modules[\"");
                        try preamble.write(target_mod.dev_id);
                        try preamble.write("\"].fn()");
                    } else {
                        const init_name = try target_mod.allocInitName(self.allocator);
                        defer self.allocator.free(init_name);
                        try preamble.write(init_name);
                        try preamble.write("()");
                    }
                    try preamble.write(if (guard) rt.GUARD_LAMBDA_CLOSE else rt.INIT_CALL_END);
                },
            }
        }
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
    const final_export_entries = blk: {
        var fe_scope = profile.begin(.metadata_final_exports);
        defer fe_scope.end();
        break :blk try self.buildFinalExports(
            is_entry,
            module_index,
            m.export_bindings,
            &owned_nested_renames,
        );
    };

    // 크로스-모듈 상수 인라인: import binding의 canonical export가 상수이면 매핑
    const const_values = try self.buildCrossModuleConstValues(self.getModule(module_index).?, sem);

    // ns_member_rewrites / ns_inline_objects 소유권 이동 + namespace preamble 생성.
    // finalizeNamespaceData가 리스트를 소비(deinit)하므로, 이후 에러 시
    // errdefer가 이미 해제된 리스트에 접근하지 않도록 마지막에 호출한다.
    const ns_result = blk: {
        var ns_scope = profile.begin(.metadata_finalize_ns);
        defer ns_scope.end();
        break :blk try finalizeNamespaceData(self.allocator, &ns_rewrite_list, &ns_inline_list, cjs_import_preamble);
    };
    const ns_rewrites = ns_result.rewrites;
    const ns_inlines = ns_result.inlines;
    const combined_preamble = ns_result.combined_preamble;

    // ESM+CJS 혼합 모듈(esm_with_dynamic_fallback)이 scope hoisting될 때
    // 내부 require() 호출도 require_xxx()로 치환해야 함.
    const require_rewrites = blk: {
        var rr_scope = profile.begin(.metadata_require_rewrites);
        defer rr_scope.end();
        break :blk try self.buildRequireRewrites(&m);
    };

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
        .final_exports = null,
        .final_export_entries = final_export_entries,
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
    var audit = debug_log.auditScope(.metadata_audit);
    defer if (audit.on) debug_log.print(.metadata_audit, "rr wrap={s} imports={d} result={d} ns={d}\n", .{ @tagName(m.wrap_kind), m.import_records.len, require_rewrites.count(), audit.elapsedNs() });
    for (m.import_records) |rec| {
        if (rec.resolved.isNone()) {
            // UMD/AMD/IIFE+globals: external require → factory 매개변수 참조.
            // require("react") → React (factory params에서 주입, #1824 IIFE 확장).
            if (try mappedExternalParam(self.format, self.iife_globals, rec, self.allocator)) |param| {
                defer self.allocator.free(param);
                if (!require_rewrites.contains(rec.specifier)) {
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
            const var_name = try target_mod.allocRequireName(self.allocator);
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

/// 엔트리 포인트의 최종 export entry를 생성한다.
/// is_entry가 false이거나 emit 대상 export가 없으면 null 반환. 반환 slice 의
/// `local`/`exported` 는 모듈 소유 — caller 는 slice 자체만 free.
///
/// `export * from "./x"` (re-export-all) 의 경우 source 모듈의 named export 를
/// `collectExportsRecursive` 로 평탄화해 entry 의 export 로 포함시킨다 — ECMAScript
/// 15.2.3.5 의 default 제외 규정 포함. scope-hoisted ESM 출력 (#2576).
///
/// `owned_strings` 는 caller 의 `owned_rename_values` (LinkingMetadata 의 owned
/// slice 영역). collectExportsRecursive 가 NsExportPair.owned=true 를 emit 하는
/// case (e.g. namespace inline literal 의 안전한 식별자) 시 ownership 을 caller
/// 로 이전 — LinkingMetadata.deinit 시 free.
pub fn buildFinalExports(
    self: *const Linker,
    is_entry: bool,
    module_index: u32,
    export_bindings: []const ExportBinding,
    owned_strings: *std.ArrayListUnmanaged([]const u8),
) !?[]const LinkingMetadata.FinalExportEntry {
    if (!is_entry or export_bindings.len == 0) return null;

    // collectExportsRecursive 가 직접 export + re-export-star 재귀 + diamond/circular
    // 를 한 번에 평탄화. ESM 스펙 (export * 는 default 제외) 도 처리.
    var pairs: std.ArrayList(@import("../linker.zig").Linker.NsExportPair) = .empty;
    defer {
        // owned=true 가 아직 살아있는 (caller 로 이전 안 된) item 은 여기서 free.
        // 정상 path 에선 모두 owned=false 로 reset 후 ownership 이전됐어야 함.
        for (pairs.items) |p| if (p.owned) self.allocator.free(p.local);
        pairs.deinit(self.allocator);
    }
    var seen = std.StringHashMap(void).init(self.allocator);
    defer seen.deinit();
    var visited = std.AutoHashMap(u32, void).init(self.allocator);
    defer visited.deinit();

    try self.collectExportsRecursive(
        &pairs,
        &seen,
        &visited,
        @enumFromInt(module_index),
        0,
    );

    if (pairs.items.len == 0) return null;

    var entries: std.ArrayListUnmanaged(LinkingMetadata.FinalExportEntry) = .empty;
    errdefer entries.deinit(self.allocator);
    try entries.ensureTotalCapacityPrecise(self.allocator, pairs.items.len);
    for (pairs.items) |*p| {
        // owned=true 는 buildInlineObjectStr 가 만든 namespace inline literal.
        // ownership 을 caller 의 owned_rename_values 로 이전해 LinkingMetadata.deinit
        // 시 free 되도록 — entries 의 .local 은 그 slice 를 borrow.
        if (p.owned) {
            try owned_strings.append(self.allocator, p.local);
            p.owned = false;
        }
        entries.appendAssumeCapacity(.{
            .local = p.local,
            .exported = p.exported,
        });
    }
    return try entries.toOwnedSlice(self.allocator);
}

/// 크로스-모듈 상수 인라인 맵을 생성한다.
/// import binding의 canonical export가 상수이면 symbol_id → ConstValue 매핑을 반환.
pub const ConstValuesProfile = struct {
    resolve: ?profile.Category = null,
    lookup: ?profile.Category = null,
};

pub fn buildCrossModuleConstValues(
    self: *const Linker,
    m: *const Module,
    sem: @import("../module.zig").ModuleSemanticData,
) !std.AutoHashMapUnmanaged(u32, semantic_symbol.ConstValue) {
    return buildCrossModuleConstValuesProfiled(self, m, sem, .{});
}

pub fn buildCrossModuleConstValuesProfiled(
    self: *const Linker,
    m: *const Module,
    _: @import("../module.zig").ModuleSemanticData,
    profile_cats: ConstValuesProfile,
) !std.AutoHashMapUnmanaged(u32, semantic_symbol.ConstValue) {
    var const_values: std.AutoHashMapUnmanaged(u32, semantic_symbol.ConstValue) = .{};
    if (m.import_bindings.len == 0) return const_values;
    for (m.import_bindings) |ib| {
        if (ib.kind == .namespace) continue;
        if (ib.import_record_index >= m.import_records.len) continue;
        const rec = m.import_records[ib.import_record_index];
        if (rec.resolved.isNone()) continue;
        const canon = blk: {
            var scope = profile.beginMaybe(profile_cats.resolve);
            defer scope.end();
            break :blk self.resolveExportChain(rec.resolved, ib.imported_name, 0) orelse continue;
        };
        const Lookup = struct {
            sem: @import("../module.zig").ModuleSemanticData,
            sym_idx: usize,
        };
        const lookup = blk: {
            var scope = profile.beginMaybe(profile_cats.lookup);
            defer scope.end();
            const target_module = self.graph.getModule(canon.module_index) orelse continue;
            // 순환 그룹 멤버는 ESM TDZ 순서 보장이 깨져 const inline 안전성을 잃는다 (D065).
            if (target_module.isInCycle()) continue;
            const target_sem = target_module.semantic orelse continue;
            if (target_sem.scope_maps.len == 0) continue;
            // export_name → local_name 매핑. namespace object export 는 scalar const 가 아니므로
            // symbol lookup 전에 제외한다.
            const local_name = local: {
                var key_buf: [4096]u8 = undefined;
                const key = makeExportKeyBuf(&key_buf, canon.module_index.toU32(), canon.export_name);
                if (self.export_map.get(key)) |entry| {
                    if (entry.binding.kind == .re_export_namespace) continue;
                    break :local target_module.exportBindingLocalName(entry.binding);
                }
                break :local canon.export_name;
            };
            const target_sym_idx = target_sem.scope_maps[0].get(local_name) orelse continue;
            if (target_sym_idx >= target_sem.symbols.items.len) continue;
            break :blk Lookup{
                .sem = target_sem,
                .sym_idx = target_sym_idx,
            };
        };
        const target_sym_idx = lookup.sym_idx;
        const target_sym = lookup.sem.symbols.items[target_sym_idx];
        // Symbol 은 kind 만 들고 numeric text 는 사이드테이블에서 lookup (#2505).
        const cv = blk: {
            if (target_sym.const_kind == .none) break :blk semantic_symbol.ConstValue{};
            const text = if (target_sym.const_kind == .number)
                lookup.sem.numericConstText(@intCast(target_sym_idx))
            else
                "";
            break :blk semantic_symbol.ConstValue{ .kind = target_sym.const_kind, .number_text = text };
        };
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
        if (entry.object_literal.len == 0) continue;
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
///   - cjs_import_preamble: `__ns_N = __zntc_require("./path")` 형태 (namespace 할당)
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

    // 2. __zntc_require preamble 생성
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
    // Before: var { useState } = __zntc_require("react");  (inside __esm, function-scoped)
    // After:  __ns_0 = __zntc_require("react");             (inside __esm, assign-only)
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
            // re-export의 경우: exports.name = __zntc_require("./dep").name;
            if (eb.kind == .re_export) {
                if (eb.import_record_index) |iri| {
                    if (iri < m.import_records.len) {
                        const irec = m.import_records[iri];
                        if (!irec.resolved.isNone()) {
                            const re_path = if (self.graph.getModule(irec.resolved)) |re_m| re_m.dev_id else irec.specifier;
                            try buf.appendSlice(self.allocator, "exports.");
                            try buf.appendSlice(self.allocator, eb.exported_name);
                            try buf.appendSlice(self.allocator, " = __zntc_require(\"");
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
    var owned_rename_values: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (owned_rename_values.items) |v| self.allocator.free(v);
        owned_rename_values.deinit(self.allocator);
    }
    const final_export_entries = try self.buildFinalExports(
        is_entry,
        module_index,
        m.export_bindings,
        &owned_rename_values,
    );

    return .{
        .skip_nodes = skip_nodes,
        .renames = renames,
        .final_exports = null,
        .final_export_entries = final_export_entries,
        .symbol_ids = sem.symbol_ids,
        .owned_rename_values = owned_rename_values,
        .allocator = self.allocator,
    };
}
