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
        // This flag controls top-level constant/function inlining, not
        // module-level dead-store removal. `MinifyCtx.allow_top_level_dead`
        // remains false here; top-level pruning is owned by the resynced
        // tree-shaker/emitter path.
        const allow_top_level_inline = true;
        var ctx: minify_mod.MinifyCtx = if (module.semantic != null)
            minify_mod.MinifyCtx.fromSemantic(&module.semantic.?, transformer.symbol_ids.items, allow_top_level_inline)
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

    resyncAfterAstMutation(self, module, arena_alloc, null) catch {
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
/// **RFC #3940 L.5a — carry-over 를 build-scope `rename_table` 기반으로 재설계**.
/// post-link tree-shake (const-materialize 등) 의 semantic resync 가 symbols 배열을 재생성하면
/// old idx 기준 rename 정보가 stale 해진다. resync **전** old_sem 각 symbol 의 rename 을
/// `rename_table.get(SymbolID(module.index, old_idx))` 로 읽어, resync **후** new_sem 에서
/// name-based 로 new_idx 를 찾아 `module.pending_renames` 에
/// `SymbolID(module.index, new_idx) → name` 으로 stash 한다.
/// bundler 의 post-shake finalize 가 `Linker.applyPendingRenames` 로 mutable `rename_table` 에
/// 반영한다 (tree_shaker.linker 는 *const 라 put 불가 — capture=read, apply=write 분리).
/// `rename_table == null` (graph pre-pass, link 전) 이면 rename 미설정이라 no-op.
///
/// **Multi-pass 정합 (RFC #3940 L.5c review fix)**: 같은 모듈이 한 build 에서 2회 이상 resync
/// 되면 (pre-shake `applyNodeBufferCapabilityFacts` markAst + numeric post-pass markConst 등)
/// `rename_table` (link 시점 = pass0 idx) 만으로는 2차 capture 의 old_idx (= 1차 resync 후 idx)
/// 와 어긋나 stale lookup 이 된다. 그러나 **직전 resync 가 이미 old_sem(=현재) idx 기준으로
/// `pending_renames` 에 stash** 했으므로, rename source 를 `pending_renames` (직전 결과) 우선 +
/// `rename_table` (link 시점) 폴백으로 잡으면 idx-shift 와 무관하게 정합한다. 또 매 resync 마다
/// old_sem 기준으로 **새 맵을 rebuild(교체)** 해 이전 idx 의 stale entry 를 제거 — 다른 심볼이
/// 잘못된 rename 으로 오염되는 것을 막는다. 단일 resync (대부분) 는 pending 이 비어 폴백만 타므로
/// 기존과 byte-identical.
fn captureRenamesToPending(
    module: *Module,
    rename_table: *const bundler_symbol.RenameTable,
    old_sem: ModuleSemanticData,
    new_sem: *const ModuleSemanticData,
    source: []const u8,
    arena: std.mem.Allocator,
) !void {
    const module_scope: ?*const std.StringHashMapUnmanaged(usize) = if (new_sem.scope_maps.len > 0) &new_sem.scope_maps[0] else null;
    // old_sem 기준 새 맵을 만들어 교체 — 이전 idx 의 stale entry 누적/오염 방지 (multi-pass).
    var rebuilt: bundler_symbol.RenameTable = .{};
    // `rename_table` (link 시점 = pass0 idx) 폴백은 **첫 capture (pending 비어있음)** 에서만
    // 허용한다. 2차+ resync 는 old_sem idx 가 pass1+ 라, pass0 키 폴백 시 그 슬롯의 *다른* 심볼
    // rename 을 오인해 잘못 적용할 수 있다 (idx-space mismatch). 직전 resync 가 old_sem idx 로
    // stash 한 `pending_renames` 가 2차+ 의 유일한 정합 source 다. apply 가 build 끝에 pending 을
    // clear 하므로 다음 build 의 첫 capture 는 다시 count==0 — cross-build 안전.
    const allow_table_fallback = module.pending_renames.count() == 0;
    for (old_sem.symbols.items, 0..) |old_sym, old_idx| {
        const old_id = bundler_symbol.SymbolID.make(module.index, old_idx);
        // 직전 resync 결과(pending) 우선; 첫 capture 만 link 시점 rename_table 폴백.
        const rename = module.pending_renames.get(old_id) orelse
            (if (allow_table_fallback) rename_table.get(old_id) else null) orelse continue;

        if (old_sym.synthetic_kind == null) {
            const name = old_sym.nameText(source);
            const new_idx = if (module_scope) |scope| scope.get(name) else null;
            if (new_idx) |idx| {
                if (idx < new_sem.symbols.items.len and new_sem.symbols.items[idx].synthetic_kind == null) {
                    try rebuilt.put(arena, bundler_symbol.SymbolID.make(module.index, idx), rename);
                }
            }
            continue;
        }

        for (new_sem.symbols.items, 0..) |new_sym, new_idx| {
            if (new_sym.synthetic_kind != old_sym.synthetic_kind) continue;
            if (!std.mem.eql(u8, new_sym.synthetic_name, old_sym.synthetic_name)) continue;
            try rebuilt.put(arena, bundler_symbol.SymbolID.make(module.index, new_idx), rename);
            break;
        }
    }
    module.pending_renames = rebuilt;
}

fn refreshSemanticAndStmtInfoAfterAstMutation(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    rename_table: ?*const bundler_symbol.RenameTable,
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
            if (rename_table) |rt| {
                if (previous_semantic) |old_sem| {
                    try captureRenamesToPending(module, rt, old_sem, &module.semantic.?, module.source, arena_alloc);
                }
            }
        }
        suppressRuntimeHelperInternalUnresolved(module);
        module.uses_top_level_await = analyzer.has_top_level_await;
        // base(self) 값 보존 — propagateTopLevelAwait 가 매 빌드 이 값으로 reset 후 전파.
        module.self_uses_top_level_await = analyzer.has_top_level_await;
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
            // 주의: package sideEffects 는 이 시점(parseModule 내부 prepass)
            // **이후** applySideEffectsFromPackageJson 으로 적용되므로 여기서는
            // isUserDeclaredPure() 가 거의 항상 false → 게이트 off. 실제 게이트
            // 적용은 tree_shaker 가 정확한 side-effect 상태로 재빌드할 때 일어난다.
            const gate_member_augment =
                module.memberAugmentGate(self.transform_options_base.minify_syntax);
            module.prebuilt_stmt_info = try stmt_info_mod.buildFromSemantic(
                arena_alloc,
                ast,
                analyzer.symbols.items,
                analyzer.scopes.items,
                analyzer.references.items,
                if (module.semantic) |*s| &s.unresolved_references else null,
                false,
                gate_member_augment,
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
    const scope0: ?std.StringHashMapUnmanaged(usize) =
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
    rename_table: ?*const bundler_symbol.RenameTable,
) !void {
    var resync_scope = profile.begin(.graph_resync);
    defer resync_scope.end();
    var const_scope = profile.begin(.graph_resync_const);
    defer const_scope.end();

    _ = &(module.ast orelse return);
    try refreshSemanticAndStmtInfoAfterAstMutation(self, module, arena_alloc, rename_table);
    try refreshStableBindingRefsAfterSemanticResync(self, module, arena_alloc, .graph_resync_binding_refs);
}

pub fn resyncAfterAstMutation(
    self: anytype,
    module: *Module,
    arena_alloc: std.mem.Allocator,
    rename_table: ?*const bundler_symbol.RenameTable,
) !void {
    var resync_scope = profile.begin(.graph_resync);
    defer resync_scope.end();

    const ast = &(module.ast orelse return);
    const previous_import_records = module.import_records;

    try refreshSemanticAndStmtInfoAfterAstMutation(self, module, arena_alloc, rename_table);

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

        // counter$4 진짜 근본 fix: 1차 (parse 단계 parser_metadata.zig) 의
        // collectNamespaceAccesses 결과를 local→props 맵으로 백업. transformer 가
        // `metric.counter(...)` 같은 namespace access 를 inline / helper substitution 으로
        // 변형하면 2차 collectNamespaceAccesses (post-transform AST 기반) 가 못 잡아
        // `namespace_used_properties=&.{}` (length=0) 로 reset → tree-shake 가 그 module 의
        // export reachable seed 안 함 → namespace getter dangling (effect-ts 의
        // `counter$4 is not defined`). 1차 가 잡은 props 를 2차 결과와 union 으로 keep.
        var prev_props_map = std.StringHashMapUnmanaged([]const []const u8){};
        defer prev_props_map.deinit(arena_alloc);
        for (module.import_bindings) |ib_prev| {
            if (ib_prev.kind != .namespace) continue;
            if (ib_prev.namespace_used_properties) |props| {
                if (props.len > 0) {
                    prev_props_map.put(arena_alloc, ib_prev.local_name, props) catch continue;
                }
            }
        }

        module.import_bindings = try binding_scanner_mod.extractImportBindings(arena_alloc, ast, module.import_records, helper_refs);

        // PR #3738 (C6 perf): namespace 외 모든 import local 도 interest 에 추가 — linker 의
        // .named / cjs default / esm wrapper default 분석에 share. transform_prepass 시점에는
        // resolve 미완료라 정확한 4 kind 판별 불가, 보수적으로 모든 import local 색인.
        // 일반 모듈은 import binding 수가 작아 (수개~수십개) 색인 size 영향 무시 가능.
        var extra_locals: std.ArrayListUnmanaged([]const u8) = .empty;
        defer extra_locals.deinit(arena_alloc);
        for (module.import_bindings) |ib_extra| {
            if (ib_extra.kind == .namespace) continue;
            if (ib_extra.local_name.len > 0) try extra_locals.append(arena_alloc, ib_extra.local_name);
        }
        // index 를 module 에 store — linker 가 fetch (모듈당 build 1회 절약).
        const ns_idx = try binding_scanner_mod.collectNamespaceAccessesAndBuildIndex(
            arena_alloc,
            ast,
            module.import_bindings,
            extra_locals.items,
            .{ .reachable_only = false }, // linker 호환 (orphan node 포함)
        );
        // 옛 index 는 parse_arena 소유 — 별도 deinit 불필요 (arena 통째 free). null 으로만 덮어씀.
        module.namespace_access_index = ns_idx;

        // 1차 결과와 union: 2차 가 못 잡은 access 도 keep.
        for (module.import_bindings) |*ib_new| {
            if (ib_new.kind != .namespace) continue;
            const new_props = ib_new.namespace_used_properties orelse continue;
            const prev_props = prev_props_map.get(ib_new.local_name) orelse continue;
            if (new_props.len == 0) {
                ib_new.namespace_used_properties = prev_props;
                continue;
            }
            // 둘 다 non-empty — union.
            var seen = std.StringHashMapUnmanaged(void){};
            defer seen.deinit(arena_alloc);
            for (new_props) |p| seen.put(arena_alloc, p, {}) catch {};
            var added: usize = 0;
            for (prev_props) |p| {
                if (!seen.contains(p)) added += 1;
            }
            if (added == 0) continue;
            const merged = arena_alloc.alloc([]const u8, new_props.len + added) catch continue;
            @memcpy(merged[0..new_props.len], new_props);
            var mi: usize = new_props.len;
            for (prev_props) |p| {
                if (!seen.contains(p)) {
                    merged[mi] = p;
                    mi += 1;
                }
            }
            ib_new.namespace_used_properties = merged;
        }
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
        @import("requested_exports.zig").populateExportIndexByName(module, self.allocator) catch {};
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
        module.has_esmodule_marker = refreshed_scan_result.has_esmodule_marker;
        module.can_skip_cjs_default_interop = Module.computeCanSkipCjsDefaultInterop(
            module.wrap_kind == .cjs,
            refreshed_scan_result.has_module_exports,
            refreshed_scan_result.has_exports_dot,
            refreshed_scan_result.has_esmodule_marker,
        );
    }

    try refreshStableBindingRefsAfterSemanticResync(self, module, arena_alloc, .graph_resync_alias);
}
