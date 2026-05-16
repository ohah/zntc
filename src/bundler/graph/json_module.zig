//! JSON module parse helper for ModuleGraph.

const std = @import("std");
const Module = @import("../module.zig").Module;
const module_mod = @import("../module.zig");
const json_to_esm = @import("../json_to_esm.zig");
const import_scanner = @import("../import_scanner.zig");
const binding_scanner_mod = @import("../binding_scanner.zig");
const stmt_info_mod = @import("../stmt_info.zig");
const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;
const Span = @import("../../lexer/token.zig").Span;
const graph_loaders = @import("loaders.zig");
const graph_parse_helpers = @import("parse_helpers.zig");
const projectExportedNames = graph_parse_helpers.projectExportedNames;
const graph_mod = @import("../graph.zig");
const ModuleGraph = graph_mod.ModuleGraph;

/// JSON 모듈: ESM AST로 변환 → 일반 JS와 동일한 파이프라인.
/// `export default <json_value>;` 형태의 AST를 생성하여
/// semantic → import_scanner → binding_scanner를 공유한다.
pub fn parse(self: *ModuleGraph, module: *Module) void {
    module.parse_arena = module_mod.createParseArena(self.allocator) orelse {
        module.state = .ready;
        return;
    };
    const arena_alloc = module.parse_arena.?.allocator();
    module.source = graph_loaders.readModuleSourceWithMtime(self, module, arena_alloc, 10 * 1024 * 1024, .parse) orelse return;

    module.ast = json_to_esm.convert(arena_alloc, module.source) catch {
        self.addDiag(.parse_error, .@"error", module.path, Span.EMPTY, .parse, "Invalid JSON", null);
        module.state = .ready;
        return;
    };

    // JSON은 항상 ESM, side-effects 없음
    module.exports_kind = .esm;
    module.wrap_kind = .none;
    module.side_effects = false;

    // semantic analysis — export default가 제대로 추적되도록
    var analyzer = SemanticAnalyzer.init(arena_alloc, &(module.ast.?));
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    if (analyzer.analyze()) |_| {
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
        if (analyzer.stmt_info_count > 0) {
            module.prebuilt_stmt_info = stmt_info_mod.buildFromSemantic(
                arena_alloc,
                &(module.ast.?),
                analyzer.symbols.items,
                analyzer.scopes.items,
                analyzer.references.items,
                if (module.semantic) |*s| &s.unresolved_references else null,
                false,
                // JSON 모듈엔 member-augment 패턴 없음 — 게이트 off.
                false,
            ) catch null;
        }
    } else |_| {}

    // import/export 스캔 — JSON에는 import가 없지만 export default가 있음
    const scan_result = import_scanner.extractImportsWithCjsDetectionAndDefines(arena_alloc, &(module.ast.?), self.defines) catch {
        module.state = .ready;
        return;
    };
    module.import_records = scan_result.records;
    // specifier 들이 ast.string_table 또는 ast.source 의 borrowed slice 인데, 후속 transform
    // 파스가 string_table 을 grow 시키면 dangling → 0xAA UAF (raw require leak, #raw-require).
    // arena_alloc 은 모듈 lifetime 동안 살아있어 module.import_records 와 동일 lifetime 보장.
    for (module.import_records) |*r| {
        if (arena_alloc.dupe(u8, r.specifier)) |owned| r.specifier = owned else |_| {}
    }
    // OOM 시 silent skip 하면 axios/follow-redirects 같은 optional require 가 hard
    // error 로 회귀해 build 자체가 깨진다. 1108줄 extractImports 와 동일하게 fallback.
    import_scanner.markPostScanFlags(arena_alloc, &(module.ast.?), module.import_records) catch {
        module.state = .ready;
        return;
    };
    module.import_bindings = binding_scanner_mod.extractImportBindings(arena_alloc, &(module.ast.?), scan_result.records, null) catch &.{};
    binding_scanner_mod.collectNamespaceAccesses(arena_alloc, &(module.ast.?), module.import_bindings) catch {};
    module.export_bindings = binding_scanner_mod.extractExportBindings(arena_alloc, &(module.ast.?), scan_result.records, module.import_bindings) catch &.{};
    module.exported_names = projectExportedNames(arena_alloc, module.export_bindings);
    @import("requested_exports.zig").computeBarrelFlags(module);

    // Phase 1 (#1328): 합성 심볼 테이블 초기화 + export default 등록.
    module.ensureAliasTable(self.allocator);
    if (module.semantic) |*sem| {
        const scope0: ?std.StringHashMap(usize) =
            if (sem.scope_maps.len > 0) sem.scope_maps[0] else null;
        binding_scanner_mod.populateSyntheticSymbols(
            &module.alias_table.?,
            module.index,
            module.export_bindings,
            &sem.symbols,
            arena_alloc,
            scope0,
        ) catch {};
    }

    module.state = .parsed;
}
