//! ModuleGraph transformer pre-pass and post-transform metadata resync helpers.

const std = @import("std");
const Module = @import("../module.zig").Module;
const ModuleSemanticData = @import("../module.zig").ModuleSemanticData;
const AliasTable = @import("../module.zig").AliasTable;
const binding_scanner_mod = @import("../binding_scanner.zig");
const bundler_symbol = @import("../symbol.zig");
const import_scanner = @import("../import_scanner.zig");
const stmt_info_mod = @import("../stmt_info.zig");
const purity = @import("../purity.zig");
const profile = @import("../../profile.zig");
const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("../../transformer/transformer.zig").Transformer;
const TransformOptions = @import("../../transformer/transformer.zig").TransformOptions;
const builtin_plugins = @import("../../transformer/plugins/builtin.zig");
const Span = @import("../../lexer/token.zig").Span;
const parse_helpers = @import("parse_helpers.zig");

const isFlowPath = parse_helpers.isFlowPath;
const suppressRuntimeHelperInternalUnresolved = parse_helpers.suppressRuntimeHelperInternalUnresolved;
const mergeImportRecords = parse_helpers.mergeImportRecords;
const projectExportedNames = parse_helpers.projectExportedNames;
const determineExportsKind = parse_helpers.determineExportsKind;

/// 보수적 graph pre-pass 게이트.
///
/// graph 단계 pre-pass 는 helper/runtime import 를 link 전에 발견해야 하는 모듈에만
/// 필요하다. 단순 ESM/TS-strip 모듈은 parser scan + semantic 결과를 그대로 쓰고,
/// emit 단계의 legacy transformer/codegen 경로가 최종 출력 변환을 수행한다.
pub fn shouldRun(
    self: anytype,
    module: *const Module,
    plugin_transform_applied: bool,
) bool {
    {
        var gate_scope = profile.begin(.graph_discover_pm_prepass_decision_module_gate);
        defer gate_scope.end();
        if (!module.module_type.isJavaScriptLike()) return false;
        if (plugin_transform_applied) return true;

        // Check cheap single-byte flags before the heavier option predicate.
        if (self.minify_identifiers) return true;
        // react_refresh / styled-components / emotion 은 emitter·`run` 과 마찬가지로 user
        // code 에만 적용된다 (`/node_modules/` 밖). node_modules 의 plain ESM/ES5 dep 까지
        // pre-pass 를 돌리던 게 가장 큰 낭비였다 — 그 모듈들은 helper import 도 안 만든다.
        const is_user_code = std.mem.indexOf(u8, module.path, "/node_modules/") == null;
        if (is_user_code and (self.react_refresh or self.styled_components or self.emotion)) return true;
        // worklet 변환은 react-native / @react-native 코어를 제외한 모든 모듈 대상 (`run` 의
        // exclude_worklet 과 동일). 워크릿 디렉티브가 없으면 plugin 은 no-op 이지만, 변환이
        // helper 를 주입할 수 있으니 게이트는 보수적으로 유지.
        if (self.worklet_transform) {
            const is_rn_core = std.mem.indexOf(u8, module.path, "/node_modules/react-native/") != null or
                std.mem.indexOf(u8, module.path, "/node_modules/@react-native/") != null;
            if (!is_rn_core) return true;
        }
    }

    const ast = &module.ast.?;
    {
        var ast_flags_scope = profile.begin(.graph_discover_pm_prepass_decision_ast_flags);
        defer ast_flags_scope.end();
        if (ast.has_jsx or ast.has_decorator or ast.has_ts_namespace_or_enum or
            ast.has_ts_import_equals or ast.has_ts_export_equals)
        {
            return true;
        }
    }

    {
        var options_scope = profile.begin(.graph_discover_pm_prepass_decision_options);
        defer options_scope.end();
        return self.transform_options_base.requiresGraphPrePass(ast);
    }
}

/// transformer pre-pass — graph 단계에서 1회 실행.
/// 결과: `module.ast` 를 transformer 결과 AST 로 교체, `module.transform_cache` set,
/// final AST 기준 분석 데이터 refresh.
/// 실패 시 error diagnostic 을 남기고 모듈 파싱을 중단한다. stale semantic/binding
/// 데이터로 tree-shaker/linker 가 진행하는 silent bug 를 막기 위한 정책 (#1913).
pub fn run(self: anytype, module: *Module, arena_alloc: std.mem.Allocator) void {
    if (module.ast == null) return;
    const ast_ptr = &(module.ast.?);

    // emitter 와 동일한 옵션 결정 휴리스틱 — 결과 분기 시 cache mismatch.
    const is_user_code = std.mem.indexOf(u8, module.path, "/node_modules/") == null;
    // worklet 변환은 react-native/@react-native 코어 제외, 나머지 node_modules 포함.
    const exclude_worklet = self.worklet_transform and
        (std.mem.indexOf(u8, module.path, "/node_modules/react-native/") != null or
            std.mem.indexOf(u8, module.path, "/node_modules/@react-native/") != null);
    const merged_plugins = builtin_plugins.collect(.{
        .worklet = self.worklet_transform and !exclude_worklet,
    }, self.plugins, arena_alloc) catch return;

    const parser_node_count: u32 = @intCast(ast_ptr.nodes.items.len);

    var opts = self.transform_options_base;
    opts.react_refresh = self.react_refresh and is_user_code;
    opts.styled_components = self.styled_components and is_user_code;
    opts.styled_components_ssr = self.styled_components_ssr;
    opts.styled_components_minify = self.styled_components_minify;
    opts.styled_components_file_name = self.styled_components_file_name;
    opts.styled_components_pure = self.styled_components_pure;
    opts.styled_components_namespace = self.styled_components_namespace;
    opts.styled_components_meaningless_file_names = self.styled_components_meaningless_file_names;
    opts.styled_components_top_level_import_paths = self.styled_components_top_level_import_paths;
    opts.styled_components_css_prop = self.styled_components_css_prop;
    opts.emotion = self.emotion and is_user_code;
    opts.emotion_auto_label = self.emotion_auto_label;
    opts.emotion_source_map = self.emotion_source_map;
    opts.emotion_label_format = self.emotion_label_format;
    opts.emotion_extra_css_sources = self.emotion_extra_css_sources;
    opts.emotion_extra_styled_sources = self.emotion_extra_styled_sources;
    opts.plugins = merged_plugins;
    opts.jsx_transform = ast_ptr.has_jsx;
    opts.jsx_filename = module.path;
    // per-file JSX pragma (D026): `@jsxRuntime` / `@jsx` / `@jsxFrag` / `@jsxImportSource`
    // 가 tsconfig/CLI 보다 우선. lowering 전에 module 의 effective JSX 설정을 확정.
    opts = opts.withModuleJsxPragmas(ast_ptr);
    if (opts.jsxClassicPragmaIgnoredUnderAutomatic(ast_ptr)) {
        self.addDiag(.jsx_pragma_ignored, .warning, module.path, Span.EMPTY, .parse, TransformOptions.jsx_pragma_ignored_msg, null);
    }
    // #1961 PR 1h 후 splitting / single-bundle 양쪽에서 helper module virtual import
    // 모델 활성. mangler 가 helper module top-level 식별자를 reserved 처리
    // (linker.zig 의 candidates collect 에서 isVirtualId 분기) — cross-module binding
    // 안전. dev mode 모듈도 동일.
    opts.emit_runtime_helper_imports = true;

    var transformer = Transformer.init(arena_alloc, ast_ptr, opts) catch return;

    if (module.semantic) |sem| {
        transformer.initSymbolIds(sem.symbol_ids) catch return;
        transformer.symbols = sem.symbols.items;
        transformer.references = sem.references;
    }
    transformer.line_offsets = module.line_offsets;

    const root = transformer.transform() catch return;
    if (self.ignore_annotations) {
        purity.clearPureCallFlags(transformer.ast);
    } else {
        purity.markUserPureCalls(transformer.ast, self.pure);
    }
    // prepass minify 의 cascade ref decrement 결과 hydrate 용 (#3267 N-step4b).
    // minify 안에서 alloc 하던 ref_deltas 를 parse_arena 에 미리 잡아 외부 소유로
    // 만들어, transform_cache 에 같은 backing 을 store. emitter minify 가 이 결과를
    // 복사 후 hydrate → prepass 에서 fold 된 dead branch 안 ref 감산이 emitter 의
    // dead-store pass 에 전파되어 cascade dead binding 도 elide 가능.
    var prepass_ref_deltas: []u32 = &.{};
    if (self.transform_options_base.minify_syntax) {
        const minify_mod = @import("../../transformer/minify.zig");
        var ctx: minify_mod.MinifyCtx = if (module.semantic != null)
            minify_mod.MinifyCtx.fromSemantic(&module.semantic.?, transformer.symbol_ids.items, true)
        else
            .empty;
        if (ctx.hasSemantic()) {
            if (arena_alloc.alloc(u32, ctx.symbols.len)) |buf| {
                @memset(buf, 0);
                prepass_ref_deltas = buf;
                ctx.ref_deltas = buf;
            } else |_| {}
        }
        minify_mod.minify(transformer.ast, ctx, arena_alloc, root);
    }

    // transformer 가 새 ast (clone) 에 transform 결과를 보유. module.ast 를 그 새 ast 로
    // swap. arena_alloc 가 owner 라 backing 은 안전. emit 단계 transformer 가 module.ast
    // 를 clone 시 transformed_root 까지 복사되어 cache hit 분기 즉시 return.
    module.ast = transformer.ast.*;

    const owned_symbol_ids = transformer.symbol_ids.toOwnedSlice(arena_alloc) catch &[_]?u32{};
    // #2869 helper marker sidecar — sorted u32 slice. resync analyzer 가 binary search.
    const owned_helper_ref_nodes = transformer.ownedHelperRefNodes(arena_alloc) catch &[_]u32{};
    module.transform_cache = .{
        .runtime_helpers = transformer.runtime_helpers,
        .symbol_ids = owned_symbol_ids,
        .helper_ref_nodes = owned_helper_ref_nodes,
        .ref_deltas = prepass_ref_deltas,
    };

    _ = parser_node_count;

    resyncAfterAstMutation(self, module, arena_alloc) catch {
        self.addDiag(
            .parse_error,
            .@"error",
            module.path,
            Span.EMPTY,
            .parse,
            "Post-transform analysis refresh failed",
            "The transformed AST could not be re-analyzed safely.",
        );
        module.state = .ready;
        return;
    };
}

/// AST mutation 이후 module 의 graph-facing metadata 를 같은 AST 기준으로 재동기화한다.
///
/// 이 함수는 단순 semantic refresh 가 아니다. transformed/minified AST 를 기준으로
/// semantic symbol table, StmtInfo, import/require records, import/export bindings,
/// namespace access, exported_names, ESM/CJS classification, synthetic JSX imports,
/// alias table 을 다시 맞춘다.
///
/// 호출 후 invariant:
/// - `module.ast`, `module.semantic`, `module.prebuilt_stmt_info`,
///   `module.import_records`, `module.import_bindings`, `module.export_bindings`,
///   `module.exported_names`, `module.alias_table` 은 모두 같은 AST snapshot 기준이다.
/// - runtime helper virtual module 내부의 helper 이름은 unresolved global 에 남지 않는다.
///
/// 이 중앙 resync 경로를 우회해서 record/binding 만 수동 보정하면 linker, tree-shaker,
/// chunking 이 서로 다른 AST/semantic 상태를 보게 되므로 여기서만 metadata 재구축
/// 정책을 확장해야 한다 (#1913).
fn preserveCanonicalNamesAfterSemanticResync(
    source: []const u8,
    old_sem: ModuleSemanticData,
    new_sem: *ModuleSemanticData,
) void {
    const module_scope: ?*const std.StringHashMap(usize) = if (new_sem.scope_maps.len > 0) &new_sem.scope_maps[0] else null;
    for (old_sem.symbols.items) |old_sym| {
        if (old_sym.canonical_name.len == 0) continue;

        if (old_sym.synthetic_kind == null) {
            const name = old_sym.nameText(source);
            const new_idx = if (module_scope) |scope| scope.get(name) else null;
            if (new_idx) |idx| {
                if (idx < new_sem.symbols.items.len) {
                    const new_sym = &new_sem.symbols.items[idx];
                    if (new_sym.synthetic_kind == null) {
                        new_sym.canonical_name = old_sym.canonical_name;
                    }
                }
            }
            continue;
        }

        for (new_sem.symbols.items) |*new_sym| {
            if (new_sym.synthetic_kind != old_sym.synthetic_kind) continue;
            if (!std.mem.eql(u8, new_sym.synthetic_name, old_sym.synthetic_name)) continue;
            new_sym.canonical_name = old_sym.canonical_name;
            break;
        }
    }
}

fn refreshSemanticAndStmtInfoAfterAstMutation(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
) !void {
    const ast = &(module.ast orelse return);
    const previous_semantic = module.semantic;

    var analyzer = SemanticAnalyzer.init(arena_alloc, ast);
    {
        var semantic_scope = profile.begin(.graph_resync_semantic);
        defer semantic_scope.end();

        analyzer.is_strict_mode = true;
        analyzer.is_module = true;
        analyzer.is_ts = module.module_type.isTypeScript();
        analyzer.is_flow = self.flow or isFlowPath(module.path);
        analyzer.enable_stmt_info = true;
        // #2869 transformer pre-pass 가 표시한 runtime helper marker. analyzer 는
        // 이 marker 를 보고 helper import_specifier 와 helper call site 를 user scope
        // 가 아닌 helper_scope_map 으로 격리한다.
        if (module.transform_cache) |cache| {
            analyzer.helper_ref_nodes = cache.helper_ref_nodes;
        }
        try analyzer.analyze();

        module.semantic = .{
            .symbols = analyzer.symbols,
            .scopes = analyzer.scopes.items,
            .scope_maps = analyzer.scope_maps.items,
            .exported_names = analyzer.exported_names,
            .symbol_ids = analyzer.symbol_ids.items,
            .unresolved_references = analyzer.unresolved_references,
            .references = analyzer.references.items,
            .numeric_const_texts = analyzer.numeric_const_texts,
            .helper_scope_map = analyzer.helper_scope_map,
        };
        if (!self.minify_identifiers) {
            if (previous_semantic) |old_sem| {
                preserveCanonicalNamesAfterSemanticResync(module.source, old_sem, &module.semantic.?);
            }
        }
        suppressRuntimeHelperInternalUnresolved(module);
        module.uses_top_level_await = analyzer.has_top_level_await;
        if (module.transform_cache) |*cache| {
            cache.symbol_ids = analyzer.symbol_ids.items;
        }
    }

    if (self.ignore_annotations) {
        purity.clearPureCallFlags(ast);
    } else {
        purity.markUserPureCalls(ast, self.pure);
    }

    {
        var stmt_info_scope = profile.begin(.graph_resync_stmt_info);
        defer stmt_info_scope.end();

        module.prebuilt_stmt_info = null;
        if (analyzer.stmt_info_count > 0) {
            module.prebuilt_stmt_info = try stmt_info_mod.buildFromSemantic(
                arena_alloc,
                ast,
                analyzer.symbols.items,
                analyzer.scopes.items,
                analyzer.references.items,
                if (module.semantic) |*s| &s.unresolved_references else null,
                false,
            );
        }
    }
}

fn refreshStableBindingRefsAfterSemanticResync(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    cat: profile.Category,
) !void {
    var binding_refs_scope = profile.begin(cat);
    defer binding_refs_scope.end();

    const sem = if (module.semantic) |*s| s else return;
    const scope0: ?std.StringHashMap(usize) =
        if (sem.scope_maps.len > 0) sem.scope_maps[0] else null;
    for (module.import_bindings) |*ib| {
        ib.local_symbol = bundler_symbol.SymbolRef.invalid;
        // #3068: helper binding 은 user 가 같은 이름 점유 시에도 격리된 helper_scope_map
        // 에서 lookup — 일반 module_scope.get 면 user sym 을 잘못 가리킨다 (linker
        // populateImportSymbols 와 동일 정책).
        const sym_lookup: ?usize = if (ib.is_helper)
            sem.helper_scope_map.get(ib.local_name)
        else if (scope0) |module_scope| module_scope.get(ib.local_name) else null;
        if (sym_lookup) |sym_idx| {
            ib.local_symbol = bundler_symbol.SymbolRef.makeSemantic(module.index, sym_idx);
        }
    }

    if (module.alias_table) |*table| table.deinit();
    module.alias_table = AliasTable.init(self.allocator);
    try binding_scanner_mod.populateSyntheticSymbols(
        &module.alias_table.?,
        module.index,
        module.export_bindings,
        &sem.symbols,
        arena_alloc,
        scope0,
    );
}

/// Numeric const materialization replaces identifier reads and may let minify fold
/// expressions, but it does not add/remove import or export declarations. Keep the
/// expensive syntax-level scanners intact for general transforms and use this path
/// only when the caller owns that invariant.
pub fn resyncAfterConstMaterialization(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
) !void {
    var resync_scope = profile.begin(.graph_resync);
    defer resync_scope.end();
    var const_scope = profile.begin(.graph_resync_const);
    defer const_scope.end();

    _ = &(module.ast orelse return);
    try refreshSemanticAndStmtInfoAfterAstMutation(self, module, arena_alloc);
    try refreshStableBindingRefsAfterSemanticResync(self, module, arena_alloc, .graph_resync_binding_refs);
}

pub fn resyncAfterAstMutation(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
) !void {
    var resync_scope = profile.begin(.graph_resync);
    defer resync_scope.end();

    const ast = &(module.ast orelse return);
    const previous_import_records = module.import_records;

    try refreshSemanticAndStmtInfoAfterAstMutation(self, module, arena_alloc);

    var scan_result: import_scanner.ScanResult = undefined;
    {
        var import_scan_scope = profile.begin(.graph_resync_import_scan);
        defer import_scan_scope.end();

        scan_result = try import_scanner.extractImportsWithCjsDetectionAndDefines(arena_alloc, ast, self.defines);
        module.import_records = try mergeImportRecords(arena_alloc, previous_import_records, scan_result.records);
        // specifier dupe — arena 로 owned 화 (#raw-require UAF 회피).
        for (module.import_records) |*r| {
            if (arena_alloc.dupe(u8, r.specifier)) |owned| r.specifier = owned else |_| {}
        }
        try import_scanner.markPostScanFlags(arena_alloc, ast, module.import_records);
    }

    {
        var import_bindings_scope = profile.begin(.graph_resync_import_bindings);
        defer import_bindings_scope.end();

        // #3067 이후 transformer 가 직접 추가하던 synthetic ImportBinding (JSX runtime
        // 등) 이 정식 import 노드로 대체됐다 — post-transform AST 에서 일반 binding 으로
        // 추출되므로 previous 에서 따로 보존할 synthetic binding 이 없다.
        const helper_refs: ?[]const u32 = if (module.transform_cache) |cache| cache.helper_ref_nodes else null;
        module.import_bindings = try binding_scanner_mod.extractImportBindings(arena_alloc, ast, module.import_records, helper_refs);
        try binding_scanner_mod.collectNamespaceAccesses(arena_alloc, ast, module.import_bindings);
    }

    {
        var export_bindings_scope = profile.begin(.graph_resync_export_bindings);
        defer export_bindings_scope.end();

        module.export_bindings = try binding_scanner_mod.extractExportBindings(
            arena_alloc,
            ast,
            module.import_records,
            module.import_bindings,
        );
        module.exported_names = projectExportedNames(arena_alloc, module.export_bindings);
        @import("requested_exports.zig").computeBarrelFlags(module);
    }

    const has_refreshed_cjs = scan_result.has_cjs_require or
        scan_result.has_module_exports or
        scan_result.has_exports_dot;
    const has_refreshed_esm = if (module.exports_kind == .commonjs and has_refreshed_cjs)
        false
    else
        scan_result.has_esm_syntax;

    const refreshed_scan_result = import_scanner.ScanResult{
        .records = module.import_records,
        .has_esm_syntax = has_refreshed_esm,
        .has_cjs_require = scan_result.has_cjs_require,
        .has_module_exports = scan_result.has_module_exports,
        .has_exports_dot = scan_result.has_exports_dot,
        .has_esmodule_marker = scan_result.has_esmodule_marker,
    };

    {
        var classify_scope = profile.begin(.graph_resync_classify);
        defer classify_scope.end();

        // #3062: transformer 가 JSX runtime import 를 정식 AST 노드로 추가 → resync 의
        // import_scanner / binding_scanner 가 일반 import 로 detect. synthetic
        // ImportRecord/Binding inject 우회 경로 제거.

        // 기존 exports_kind 가 ESM 인데 post-transform scan 이 `.none` 으로 떨어지는 경우
        // (예: TS interface-only 파일의 `export {};` 를 transformer 가 drop) ESM 분류를 유지한다.
        // `.none` 으로 강등하면 Pass 2 markEsmCjsHybrid 가 node_modules + def_format unknown
        // 모듈을 implicit CJS 로 승격시켜, `export *` chain 의 빈 source 가 CJS wrapper 로
        // wrap 되고 `resolveOrCjsFallback` 이 잘못된 모듈을 named import 의 source 로 반환한다
        // (kysely/cheerio 회귀 #2052/#2051).
        const refreshed_kind = determineExportsKind(refreshed_scan_result, module.path);
        const previous_kind = module.exports_kind;
        const preserve_esm = refreshed_kind == .none and previous_kind.isEsm();
        module.exports_kind = if (preserve_esm) previous_kind else refreshed_kind;
        module.wrap_kind = if (module.exports_kind == .commonjs) .cjs else .none;
        module.has_cjs_export_signal = refreshed_scan_result.has_module_exports or refreshed_scan_result.has_exports_dot;
        module.can_skip_cjs_default_interop = Module.computeCanSkipCjsDefaultInterop(
            module.wrap_kind == .cjs,
            refreshed_scan_result.has_module_exports,
            refreshed_scan_result.has_exports_dot,
            refreshed_scan_result.has_esmodule_marker,
        );
    }

    try refreshStableBindingRefsAfterSemanticResync(self, module, arena_alloc, .graph_resync_alias);
}
