//! JavaScript-like module parsing pipeline for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const ModuleIndex = types.ModuleIndex;
const module_mod = @import("../module.zig");
const plugin_mod = @import("../plugin.zig");
const Scanner = @import("../../lexer/scanner.zig").Scanner;
const Parser = @import("../../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
const profile = @import("../../profile.zig");
const stmt_info_mod = @import("../stmt_info.zig");
const purity = @import("../purity.zig");
const Span = @import("../../lexer/token.zig").Span;
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;
const graph_assets = @import("assets.zig");
const moduleReadsSourceForAsset = graph_assets.loaderReadsSource;
const graph_parse_helpers = @import("parse_helpers.zig");
const suppressRuntimeHelperInternalUnresolved = graph_parse_helpers.suppressRuntimeHelperInternalUnresolved;
const getMtime = ModuleGraph.getMtime;

pub fn parseModule(self: *ModuleGraph, io: std.Io, idx: ModuleIndex) void {
    const mod_idx = @intFromEnum(idx);
    if (mod_idx >= self.modules.count()) return;

    var module = self.modules.at(mod_idx);
    module.state = .parsing;

    // Plugin runner: parseModule 내에서 load + transform 훅에 공용
    const plugin_runner: ?plugin_mod.PluginRunner = self.pluginRunnerWithBuiltins();

    // Plugin: load 훅 — 모든 module_type 분기 전에 플러그인에게 기회를 줌.
    // 플러그인이 내용을 반환하면 JS 모듈로 전환 (예: .css → JS export).
    const plugin_load_result = self.runPluginLoadForModule(module, plugin_runner);
    if (plugin_load_result == .done) return;
    const plugin_load_applied = plugin_load_result == .applied;

    // compiled_cache key 는 mtime 을 요구한다. 디스크 source 를 읽는 경로는
    // readModuleSourceWithMtime 가 같은 file handle 에서 source+mtime 을 채운다.
    // plugin load 는 플러그인이 생성한 source 일 수 있어 결합할 파일 read 가 없고,
    // empty/none 처럼 source read 가 없는 loader 는 기존처럼 여기서 stat 한다.
    if (module.mtime == 0) {
        const can_read_mtime_with_source = !plugin_load_applied and
            (module.module_type.isJavaScriptLike() or
                module.module_type == .json or
                (module.module_type == .css and module.loader == .css) or
                moduleReadsSourceForAsset(module.loader));
        if (!can_read_mtime_with_source) {
            module.mtime = getMtime(io, module.path) catch 0;
        }
    }

    // JSON 모듈: ESM AST로 변환 → 일반 JS와 동일한 파이프라인
    if (module.module_type == .json) {
        self.parseJsonModule(io, module);
        return;
    }

    // Asset 로더: 파일을 읽어서 fake JS 모듈로 변환 (rolldown 방식)
    // 플러그인이 이미 소스를 반환한 경우 건너뜀 (플러그인 우선)
    if (module.loader.isAsset() and module.source.len == 0) {
        self.parseAssetModule(io, module);
        // asset_registry 모드(.file/.copy)에서만 loader를 .javascript로 전환해
        // 일반 JS 파이프라인이 source의 require()를 ImportRecord로 추출하게 한다.
        // (plugin load hook과 동일한 fall-through 신호)
        if (module.loader != .javascript) return;
    }

    // CSS 모듈: @import 추출 → 모듈 그래프에 등록
    if (module.module_type == .css and module.loader == .css) {
        self.parseCssModule(io, module);
        return;
    }

    if (!module.module_type.isJavaScriptLike()) {
        // loader=.none + 알 수 없는 확장자: 빌드 에러 (esbuild 호환)
        if (module.loader == .none and module.module_type != .css) {
            self.addDiag(.no_loader, .@"error", module.path, Span.EMPTY, .parse, "No loader is configured for this file type", null);
        }
        module.state = .ready;
        return;
    }

    var setup_scope = profile.begin(.graph_discover_pm_setup);

    // 모듈별 Arena: Scanner/Parser/AST 메모리를 소유 (D061)
    // 플러그인 load 훅에서 이미 설정된 경우 건너뜀
    if (module.parse_arena == null) {
        module.parse_arena = module_mod.createParseArena(self.allocator) orelse {
            module.state = .ready;
            return;
        };
    }
    const arena_alloc = module.parse_arena.?.allocator();

    // 파일 시스템에서 읽기 (플러그인이 source를 이미 설정한 경우 건너뜀)
    {
        var read_scope = profile.begin(.graph_discover_pm_setup_read);
        defer read_scope.end();
        if (module.source.len == 0) {
            module.source = self.readModuleSourceWithMtime(io, module, arena_alloc, 100 * 1024 * 1024, .resolve) orelse return;
        }
    }

    // Plugin: transform 훅 — 소스 읽기 후, 파싱 전에 호출 (Rolldown 호환).
    // 플러그인이 코드를 변환하면 변환된 소스로 파싱한다.
    // Babel 플러그인(예: react-native-reanimated/plugin)이 유저 코드를 변환할 수 있다.
    const plugin_transform_result = self.runPluginTransformForModule(module, arena_alloc, plugin_runner);
    if (plugin_transform_result == .done) return;
    const plugin_transform_applied = plugin_transform_result == .applied;

    // Scanner + Parser (arena 할당)
    var scanner: Scanner = undefined;
    var parser: Parser = undefined;
    if (!self.initParserForModule(module, arena_alloc, &scanner, &parser)) return;

    setup_scope.end();
    {
        var parse_scope = profile.begin(.graph_discover_pm_parse);
        defer parse_scope.end();
        _ = parser.parse() catch {
            self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Parse failed", null);
            module.state = .ready;
            return;
        };
    }

    if (parser.errors.items.len > 0) {
        // 파싱 에러 기록. recoverable validation 에러(use_strict_non_simple 등)는
        // AST가 정상이고 런타임도 실행하므로 모듈을 스킵하지 않는다 (#1291).
        var has_fatal = false;
        for (parser.errors.items) |err| {
            const msg = if (err.message.len > 0) err.message else "Parse error";
            self.addDiag(.parse_error, .@"error", module.path, err.span, .parse, msg, null);
            const recoverable = if (err.code) |c| c.isRecoverable() else false;
            if (!recoverable) has_fatal = true;
        }
        if (has_fatal) {
            module.state = .ready;
            return;
        }
    }

    // Legal comments 수집 (eof/linked/external 모드용)
    {
        var legal_count: usize = 0;
        for (parser.scanner.comments.items) |c| {
            if (c.is_legal) legal_count += 1;
        }
        if (legal_count > 0) {
            if (arena_alloc.alloc([]const u8, legal_count)) |buf| {
                var li: usize = 0;
                for (parser.scanner.comments.items) |c| {
                    if (c.is_legal and c.start < module.source.len and c.end <= module.source.len) {
                        buf[li] = module.source[c.start..c.end];
                        li += 1;
                    }
                }
                module.legal_comments = buf[0..li];
            } else |_| {}
        }
    }

    // Semantic analysis — linker에 필요한 스코프/심볼/export 정보.
    // arena_alloc으로 실행: SemanticAnalyzer의 모든 데이터가 parse_arena에 할당.
    // analyzer.deinit()을 의도적으로 호출하지 않음 — arena가 일괄 해제.
    // 주의: 이후에 defer analyzer.deinit()을 추가하면 double-free 발생.
    {
        var semantic_scope = profile.begin(.graph_discover_pm_semantic);
        defer semantic_scope.end();

        if (self.ignore_annotations) {
            purity.clearPureCallFlags(&parser.ast);
        } else {
            purity.markUserPureCalls(&parser.ast, self.pure);
        }

        var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.is_ts = parser.source_mode == .ts;
        analyzer.is_flow = parser.is_flow;
        analyzer.enable_stmt_info = true; // tree_shaker가 AST 재순회 없이 StmtInfo 사용
        const analyze_ok = if (analyzer.analyze()) |_| true else |_| false;

        // OOM 시 semantic = null로 유지 (부분 데이터로 linker가 오동작하는 것 방지)
        if (analyze_ok) {
            module.semantic = .{
                .symbols = analyzer.symbols,
                .scopes = analyzer.scopes.items,
                .scope_maps = analyzer.scope_maps.items,
                .exported_names = analyzer.exported_names,
                .symbol_ids = analyzer.symbol_ids.items,
                .unresolved_references = analyzer.unresolved_references,
                .references = analyzer.references.items,
                .numeric_const_texts = analyzer.numeric_const_texts,
            };
            // TLA 감지: semantic analyzer가 스코프 체인을 추적하며 정확히 판별
            module.uses_top_level_await = analyzer.has_top_level_await;

            // Semantic Analyzer에서 사전 수집한 stmt↔symbol 매핑으로 StmtInfo 구축.
            // tree_shaker가 AST를 다시 순회하지 않아도 된다 (Phase 2 최적화).
            if (analyzer.stmt_info_count > 0) {
                // 파싱 시점엔 package sideEffects 가 아직 resolve 안 됐을 수
                // 있어 isUserDeclaredPure() 가 false 면 게이트 off — 이 경우
                // transform_prepass resync 가 정확한 게이트로 재빌드한다
                // (minify_identifiers 시 shouldRun=true).
                const gate_member_augment =
                    module.memberAugmentGate(self.transform_options_base.minify_syntax);
                module.prebuilt_stmt_info = stmt_info_mod.buildFromSemantic(
                    arena_alloc,
                    &parser.ast,
                    analyzer.symbols.items,
                    analyzer.scopes.items,
                    analyzer.references.items,
                    if (module.semantic) |*s| &s.unresolved_references else null,
                    false,
                    gate_member_augment,
                ) catch null;
            }
        }
    }

    var post_scope = profile.begin(.graph_discover_pm_post);
    defer post_scope.end();

    module.ast = parser.ast;
    module.line_offsets = scanner.line_offsets.items;

    if (!self.materializeParserMetadata(module, &parser, arena_alloc)) return;

    // #1961/#1913: transformer pre-pass. helper module 을 graph 의 1급 모듈로
    // 분배하려면 helper import 가 link 단계 전에 import_records 에 등록되어야 한다.
    // transformer 를 여기서 1회 실행해 final AST 를 module.ast 에 저장하고, 그 AST
    // 기준으로 semantic/import/export/StmtInfo 를 다시 만든다. emitter 는
    // module.transform_cache hit 시 transform skip.
    {
        var prepass_scope = profile.begin(.graph_discover_pm_prepass);
        defer prepass_scope.end();
        const run_prepass = blk: {
            var decision_scope = profile.begin(.graph_discover_pm_prepass_decision);
            defer decision_scope.end();
            break :blk self.shouldRunTransformerPrePass(module, plugin_transform_applied);
        };
        if (run_prepass) {
            var run_scope = profile.begin(.graph_discover_pm_prepass_run);
            defer run_scope.end();
            self.runTransformerPrePass(module, arena_alloc);
        } else {
            module.transform_cache = null;
            // PR #3738: prepass 미실행 — parser_metadata.zig:111 의 1차 index 가 module.
            // namespace_access_index 에 이미 store 됨. pre-transform AST = post-transform AST
            // (no mutation) → 그대로 linker 가 fetch.
            suppressRuntimeHelperInternalUnresolved(module);
        }
    }

    module.state = .parsed;
}
