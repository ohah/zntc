const std = @import("std");
const binding_scanner = @import("binding_scanner.zig");
const ImportBinding = binding_scanner.ImportBinding;
const ExportBinding = binding_scanner.ExportBinding;
const extractImportBindings = binding_scanner.extractImportBindings;
const extractExportBindings = binding_scanner.extractExportBindings;
const types = @import("types.zig");
const scan_results_mod = @import("../parser/scan_results.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const ts_auto_export = @import("../parser/ts_auto_export.zig");
const import_scanner = @import("import_scanner.zig");
const symbol = @import("symbol.zig");
const semantic_symbol = @import("../semantic/symbol.zig");
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

// ============================================================
// Tests
// ============================================================

fn parseAndExtractBindings(allocator: std.mem.Allocator, source: []const u8) !struct {
    import_bindings: []ImportBinding,
    export_bindings: []ExportBinding,
    import_records: []types.ImportRecord,
    arena: std.heap.ArenaAllocator,
} {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    const records = try import_scanner.extractImports(allocator, &parser.ast);

    const import_bindings = try extractImportBindings(allocator, &parser.ast, records, null);
    const export_bindings = try extractExportBindings(allocator, &parser.ast, records, import_bindings);

    return .{
        .import_bindings = import_bindings,
        .export_bindings = export_bindings,
        .import_records = records,
        .arena = arena,
    };
}

test "import binding: named import" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import { foo } from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);
    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("foo", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("foo", r.import_bindings[0].imported_name);
    try std.testing.expectEqual(ImportBinding.Kind.named, r.import_bindings[0].kind);
}

test "import binding: named import with alias" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import { foo as bar } from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("bar", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("foo", r.import_bindings[0].imported_name);
}

test "import binding: escaped names use identifier StringValue" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import { c\\u0073s as v\\u0061lue } from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);
    defer alloc.free(r.import_bindings[0].local_name);
    defer alloc.free(r.import_bindings[0].imported_name);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("value", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("css", r.import_bindings[0].imported_name);
}

test "parser scan metadata canonicalizes escaped identifiers and preserves string export names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "import { c\\u0073s as v\\u0061lue } from './dep'; import { \"hy-phen\" as str\\u0069ngName } from './dep'; import \\u0064efaultLocal from './dep'; export { v\\u0061lue as c\\u0073s, str\\u0069ngName as \"hy-phen\" }; export * as n\\u0073 from './dep'; export const d\\u0069rect = 1;";
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.enable_scan = true;
    parser.configureForBundler(".mjs");
    _ = try parser.parse();

    try std.testing.expectEqual(@as(usize, 3), parser.scan_import_bindings.items.len);
    try std.testing.expectEqualStrings("value", parser.scan_import_bindings.items[0].local_name);
    try std.testing.expectEqualStrings("css", parser.scan_import_bindings.items[0].imported_name);
    try std.testing.expectEqualStrings("stringName", parser.scan_import_bindings.items[1].local_name);
    try std.testing.expectEqualStrings("\"hy-phen\"", parser.scan_import_bindings.items[1].imported_name);
    try std.testing.expectEqualStrings("defaultLocal", parser.scan_import_bindings.items[2].local_name);
    try std.testing.expectEqualStrings("default", parser.scan_import_bindings.items[2].imported_name);

    try std.testing.expectEqual(@as(usize, 4), parser.scan_export_bindings.items.len);
    try std.testing.expectEqual(scan_results_mod.ExportBindingKind.re_export, parser.scan_export_bindings.items[0].kind);
    try std.testing.expectEqualStrings("css", parser.scan_export_bindings.items[0].local_name);
    try std.testing.expectEqualStrings("css", parser.scan_export_bindings.items[0].exported_name);
    try std.testing.expectEqual(scan_results_mod.ExportBindingKind.re_export, parser.scan_export_bindings.items[1].kind);
    try std.testing.expectEqualStrings("\"hy-phen\"", parser.scan_export_bindings.items[1].local_name);
    try std.testing.expectEqualStrings("\"hy-phen\"", parser.scan_export_bindings.items[1].exported_name);
    try std.testing.expectEqual(scan_results_mod.ExportBindingKind.re_export_namespace, parser.scan_export_bindings.items[2].kind);
    try std.testing.expectEqualStrings("ns", parser.scan_export_bindings.items[2].exported_name);
    try std.testing.expectEqualStrings("ns", parser.scan_export_bindings.items[2].local_name);
    try std.testing.expectEqual(scan_results_mod.ExportBindingKind.local, parser.scan_export_bindings.items[3].kind);
    try std.testing.expectEqualStrings("direct", parser.scan_export_bindings.items[3].exported_name);
    try std.testing.expectEqualStrings("direct", parser.scan_export_bindings.items[3].local_name);
}

test "import binding: default import" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import myDefault from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("myDefault", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("default", r.import_bindings[0].imported_name);
    try std.testing.expectEqual(ImportBinding.Kind.default, r.import_bindings[0].kind);
}

test "import binding: namespace import" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import * as ns from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("ns", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("*", r.import_bindings[0].imported_name);
    try std.testing.expectEqual(ImportBinding.Kind.namespace, r.import_bindings[0].kind);
}

test "import binding: side-effect import — no bindings" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import './side-effect';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 0), r.import_bindings.len);
}

test "export binding: export const" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export const x = 1;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].exported_name);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].local_name);
    try std.testing.expectEqual(ExportBinding.Kind.local, r.export_bindings[0].kind);
}

test "#4819 namespace member exports are not module exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, "export namespace N { export const value = 1; export function read() { return value; } }");
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".ts");
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();
    const records = try import_scanner.extractImports(alloc, &parser.ast);
    const imports = try extractImportBindings(alloc, &parser.ast, records, null);
    const exports = try extractExportBindings(alloc, &parser.ast, records, imports);
    try std.testing.expectEqual(@as(usize, 1), exports.len);
    try std.testing.expectEqualStrings("N", exports[0].exported_name);
}

test "export binding: export { a as b }" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "const a = 1; export { a as b };");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("b", r.export_bindings[0].exported_name);
    try std.testing.expectEqualStrings("a", r.export_bindings[0].local_name);
}

test "export binding: escaped public name uses identifier StringValue" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "const css = 1; export { css as c\\u0073s };");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);
    defer alloc.free(r.export_bindings[0].exported_name);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("css", r.export_bindings[0].exported_name);
    try std.testing.expectEqualStrings("css", r.export_bindings[0].local_name);
}

test "export binding: inferred type-only local aliases are omitted from scan and graph metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var scanner = try Scanner.init(alloc, "interface _Shape { value: number } export { _Shape as PublicShape };");
    var parser = Parser.init(alloc, &scanner);
    parser.configureFromExtension(".ts");
    parser.is_module = true;
    parser.enable_scan = true;
    scanner.is_module = true;
    _ = try parser.parse();

    try ts_auto_export.markAutoTypeOnlyExportSpecifiers(alloc, &parser.ast, &parser.scan_export_bindings);
    try std.testing.expectEqual(@as(usize, 0), parser.scan_export_bindings.items.len);

    const records = try import_scanner.extractImports(alloc, &parser.ast);
    const imports = try extractImportBindings(alloc, &parser.ast, records, null);
    const exports = try extractExportBindings(alloc, &parser.ast, records, imports);
    try std.testing.expectEqual(@as(usize, 0), exports.len);
}

test "export binding: re-export" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export { x } from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.re_export, r.export_bindings[0].kind);
    try std.testing.expect(r.export_bindings[0].import_record_index != null);
}

test "export binding: export default" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export default 42;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("default", r.export_bindings[0].exported_name);
}

test "export binding: export all" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export * from './dep';");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("*", r.export_bindings[0].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.re_export_star, r.export_bindings[0].kind);
}

test "export binding: export function" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export function greet() { return 'hi'; }");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("greet", r.export_bindings[0].exported_name);
}

test "export binding: export enum" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export enum RuntimeKind { ReactNative = 1, UI = 2 }");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("RuntimeKind", r.export_bindings[0].exported_name);
    try std.testing.expectEqualStrings("RuntimeKind", r.export_bindings[0].local_name);
    try std.testing.expectEqual(ExportBinding.Kind.local, r.export_bindings[0].kind);
}

test "export binding: multi-declarator (export const x=1, y=2)" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export const x = 1, y = 2;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 2), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].exported_name);
    try std.testing.expectEqualStrings("y", r.export_bindings[1].exported_name);
}

test "mixed: import + export" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "import { x } from './a'; export const y = x + 1;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("y", r.export_bindings[0].exported_name);
}

test "destructuring re-export: export const { X } = importDefault" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc,
        \\import pkg from './index.js';
        \\export const { Command, Option } = pkg;
    );
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_records.len);
    try std.testing.expectEqual(@as(usize, 2), r.export_bindings.len);
    // destructuring export → kind = .local (esbuild 방식: ESM 래퍼 코드를 유지)
    try std.testing.expectEqualStrings("Command", r.export_bindings[0].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.local, r.export_bindings[0].kind);
    try std.testing.expectEqualStrings("Option", r.export_bindings[1].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.local, r.export_bindings[1].kind);
}

test "barrel re-export: import then export (Rolldown classification)" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc,
        \\import { x } from './a';
        \\export { x };
    );
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("x", r.export_bindings[0].exported_name);
    // barrel re-export는 .re_export로 분류되어야 함 (이전에는 .local이었음)
    try std.testing.expectEqual(ExportBinding.Kind.re_export, r.export_bindings[0].kind);
    try std.testing.expect(r.export_bindings[0].import_record_index != null);
    // local_name은 소스 모듈의 export 이름 (imported_name)
    try std.testing.expectEqualStrings("x", r.export_bindings[0].local_name);
}

test "barrel re-export with alias: import { foo as bar }; export { bar }" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc,
        \\import { foo as bar } from './a';
        \\export { bar };
    );
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("bar", r.export_bindings[0].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.re_export, r.export_bindings[0].kind);
    // local_name은 소스 모듈의 export 이름 "foo" (imported_name, not local alias)
    try std.testing.expectEqualStrings("foo", r.export_bindings[0].local_name);
}

test "barrel re-export: default import then named export" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc,
        \\import Path from './Path';
        \\export { Path };
    );
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.import_bindings.len);
    try std.testing.expectEqualStrings("Path", r.import_bindings[0].local_name);
    try std.testing.expectEqualStrings("default", r.import_bindings[0].imported_name);
    try std.testing.expectEqual(ImportBinding.Kind.default, r.import_bindings[0].kind);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("Path", r.export_bindings[0].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.re_export, r.export_bindings[0].kind);
    try std.testing.expect(r.export_bindings[0].import_record_index != null);
    try std.testing.expectEqualStrings("default", r.export_bindings[0].local_name);
}

test "barrel re-export: namespace import stays local" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc,
        \\import * as ns from './dep';
        \\export { ns };
    );
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 1), r.export_bindings.len);
    try std.testing.expectEqualStrings("ns", r.export_bindings[0].exported_name);
    // namespace barrel re-export는 .local로 유지 (linker가 namespace import를 별도 처리)
    try std.testing.expectEqual(ExportBinding.Kind.local, r.export_bindings[0].kind);
    try std.testing.expectEqualStrings("ns", r.export_bindings[0].local_name);
}

test "barrel re-export: mixed local and re-export" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc,
        \\import { x } from './a';
        \\const y = 1;
        \\export { x, y };
    );
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    try std.testing.expectEqual(@as(usize, 2), r.export_bindings.len);
    // x는 import binding이므로 .re_export
    try std.testing.expectEqualStrings("x", r.export_bindings[0].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.re_export, r.export_bindings[0].kind);
    // y는 로컬 변수이므로 .local
    try std.testing.expectEqualStrings("y", r.export_bindings[1].exported_name);
    try std.testing.expectEqual(ExportBinding.Kind.local, r.export_bindings[1].kind);
}

// #1328 Phase 1: synthetic symbol population

fn findDefaultSymbol(syms: []const semantic_symbol.Symbol) ?usize {
    for (syms, 0..) |s, i| {
        const sk = s.synthetic_kind orelse continue;
        if (sk == .default_export) return i;
    }
    return null;
}

test "populateSyntheticSymbols: default literal creates a facade" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export default 42;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    var table = symbol.AliasTable.init(alloc);
    defer table.deinit();
    var sem_syms: std.ArrayList(semantic_symbol.Symbol) = .empty;
    defer sem_syms.deinit(alloc);

    try binding_scanner.populateSyntheticSymbols(&table, @fromBackingInt(@intCast(0)), r.export_bindings, &sem_syms, alloc, null, null);
    const idx = findDefaultSymbol(sem_syms.items) orelse return error.NotFound;
    try std.testing.expectEqualStrings("_default", sem_syms.items[idx].synthetic_name);
}

test "populateSyntheticSymbols: `export default x` registers a distinct _default facade" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "const x = 1; export default x;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    var table = symbol.AliasTable.init(alloc);
    defer table.deinit();
    var sem_syms: std.ArrayList(semantic_symbol.Symbol) = .empty;
    defer sem_syms.deinit(alloc);

    try binding_scanner.populateSyntheticSymbols(&table, @fromBackingInt(@intCast(0)), r.export_bindings, &sem_syms, alloc, null, null);
    const idx = findDefaultSymbol(sem_syms.items) orelse return error.MissingDefaultFacade;
    try std.testing.expectEqualStrings("_default", sem_syms.items[idx].synthetic_name);
    try std.testing.expect(r.export_bindings[0].has_default_export_facade);
    try std.testing.expect(sem_syms.items[idx].synthetic_kind == .default_export);
}

test "populateSyntheticSymbols: default 없으면 빈 테이블" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export const x = 1;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    var table = symbol.AliasTable.init(alloc);
    defer table.deinit();
    var sem_syms: std.ArrayList(semantic_symbol.Symbol) = .empty;
    defer sem_syms.deinit(alloc);

    try binding_scanner.populateSyntheticSymbols(&table, @fromBackingInt(@intCast(0)), r.export_bindings, &sem_syms, alloc, null, null);
    try std.testing.expectEqual(@as(u32, 0), table.count());
    try std.testing.expectEqual(@as(usize, 0), sem_syms.items.len);
}

test "populateSyntheticSymbols Phase 2: ExportBinding.symbol 연결" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export default 42;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    var table = symbol.AliasTable.init(alloc);
    defer table.deinit();
    var sem_syms: std.ArrayList(semantic_symbol.Symbol) = .empty;
    defer sem_syms.deinit(alloc);

    const m: types.ModuleIndex = @fromBackingInt(@intCast(7));
    try binding_scanner.populateSyntheticSymbols(&table, m, r.export_bindings, &sem_syms, alloc, null, null);

    try std.testing.expect(r.export_bindings[0].symbol.isValid());
    try std.testing.expectEqual(m, r.export_bindings[0].symbol.moduleIndex());
    switch (r.export_bindings[0].symbol) {
        .alias => return error.UnexpectedSpace,
        .semantic => |s| {
            const idx: u32 = @backingInt(s.symbol);
            try std.testing.expectEqualStrings("_default", sem_syms.items[idx].synthetic_name);
            const sk = sem_syms.items[idx].synthetic_kind orelse return error.NoSyntheticKind;
            try std.testing.expectEqual(semantic_symbol.SyntheticKind.default_export, sk);
        },
    }
}

test "populateSyntheticSymbols Phase 2: 비-default export는 invalid 유지" {
    const alloc = std.testing.allocator;
    var r = try parseAndExtractBindings(alloc, "export const x = 1;");
    defer r.arena.deinit();
    defer alloc.free(r.import_bindings);
    defer alloc.free(r.export_bindings);
    defer alloc.free(r.import_records);

    var table = symbol.AliasTable.init(alloc);
    defer table.deinit();
    var sem_syms: std.ArrayList(semantic_symbol.Symbol) = .empty;
    defer sem_syms.deinit(alloc);

    try binding_scanner.populateSyntheticSymbols(&table, @fromBackingInt(@intCast(0)), r.export_bindings, &sem_syms, alloc, null, null);

    try std.testing.expect(!r.export_bindings[0].symbol.isValid());
}

test "populateSyntheticSymbols: low-level caller without SymbolId map retains scope lookup" {
    const allocator = std.testing.allocator;
    var r = try parseAndExtractBindings(allocator, "const value = 1; export { value };");
    defer r.arena.deinit();
    defer allocator.free(r.import_bindings);
    defer allocator.free(r.export_bindings);
    defer allocator.free(r.import_records);

    var table = symbol.AliasTable.init(allocator);
    defer table.deinit();
    var sem_syms: std.ArrayList(semantic_symbol.Symbol) = .empty;
    defer sem_syms.deinit(allocator);
    try sem_syms.append(allocator, std.mem.zeroInit(semantic_symbol.Symbol, .{}));

    var scope: std.StringHashMapUnmanaged(usize) = .empty;
    defer scope.deinit(allocator);
    try scope.put(allocator, "value", 0);

    try binding_scanner.populateSyntheticSymbols(
        &table,
        @fromBackingInt(@intCast(0)),
        r.export_bindings,
        &sem_syms,
        allocator,
        scope,
        null,
    );
    try expectSemanticExportSymbol(r.export_bindings[0], 0);
}

fn expectDefaultExportIdentity(source: []const u8, expects_facade: bool, parser_expects_facade: bool) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var scanner = try Scanner.init(arena_allocator, source);
    scanner.is_module = true;
    var parser = Parser.init(arena_allocator, &scanner);
    parser.is_module = true;
    parser.enable_scan = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(arena_allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    const import_records = try import_scanner.extractImports(allocator, &parser.ast);
    defer allocator.free(import_records);
    const import_bindings = try extractImportBindings(allocator, &parser.ast, import_records, null);
    defer allocator.free(import_bindings);
    const export_bindings = try extractExportBindings(allocator, &parser.ast, import_records, import_bindings);
    defer allocator.free(export_bindings);
    try std.testing.expectEqual(@as(usize, 1), export_bindings.len);

    var export_node_index: ?usize = null;
    var export_node_id: ?u32 = null;
    var source_expression_id: ?u32 = null;
    var source_binding_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .export_default_declaration) {
            export_node_index = index;
            export_node_id = analyzer.symbol_ids.items[index];
            const inner_idx = node.data.unary.operand;
            if (!inner_idx.isNone() and @backingInt(inner_idx) < analyzer.symbol_ids.items.len) {
                source_expression_id = analyzer.symbol_ids.items[@backingInt(inner_idx)];
            }
        } else if (node.tag == .binding_identifier and
            std.mem.eql(u8, parser.ast.getText(node.data.string_ref), "_default"))
        {
            source_binding_id = analyzer.symbol_ids.items[index];
        }
    }
    try std.testing.expectEqual(@as(usize, 1), parser.scan_export_bindings.items.len);
    const scan_export = parser.scan_export_bindings.items[0];
    try std.testing.expectEqual(
        @as(?u32, @intCast(export_node_index orelse return error.MissingExpectedFacadeNode)),
        scan_export.default_export_node_index,
    );
    try std.testing.expectEqual(parser_expects_facade, scan_export.has_default_export_facade);
    const default_inner = parser.ast.nodes.items[export_node_index.?].data.unary.operand;
    if (!default_inner.isNone() and parser.ast.getNode(default_inner).tag == .identifier_reference) {
        try std.testing.expectEqual(scan_results_mod.ExportBindingKind.local, scan_export.kind);
        try std.testing.expectEqual(@as(?u32, @intCast(@backingInt(default_inner))), scan_export.local_symbol_node_index);
        try std.testing.expectEqual(ExportBinding.Kind.local, export_bindings[0].kind);
        try std.testing.expectEqual(default_inner, export_bindings[0].local_symbol_node orelse return error.MissingDefaultExpressionNode);
    }
    binding_scanner.markDefaultExportFacadesFromSemantic(
        export_bindings,
        analyzer.symbol_ids.items,
        analyzer.symbols.items,
    );
    try std.testing.expectEqual(expects_facade, export_bindings[0].has_default_export_facade);

    var alias_table = symbol.AliasTable.init(allocator);
    defer alias_table.deinit();
    if (expects_facade and source_binding_id != null) {
        const node_index = export_node_index orelse return error.MissingExpectedFacadeNode;
        const saved_id = analyzer.symbol_ids.items[node_index] orelse return error.MissingExpectedFacade;

        var missing_node_bindings = try allocator.dupe(ExportBinding, export_bindings);
        defer allocator.free(missing_node_bindings);
        missing_node_bindings[0].default_export_node = null;
        try std.testing.expectError(
            error.MissingDefaultExportFacadeNode,
            binding_scanner.populateSyntheticSymbols(
                &alias_table,
                @fromBackingInt(@intCast(0)),
                missing_node_bindings,
                &analyzer.symbols,
                arena_allocator,
                if (analyzer.scope_maps.items.len > 0) analyzer.scope_maps.items[0] else null,
                analyzer.symbol_ids.items,
            ),
        );

        analyzer.symbol_ids.items[node_index] = null;
        try std.testing.expectError(
            error.MissingDefaultExportFacadeSymbol,
            binding_scanner.populateSyntheticSymbols(
                &alias_table,
                @fromBackingInt(@intCast(0)),
                export_bindings,
                &analyzer.symbols,
                arena_allocator,
                if (analyzer.scope_maps.items.len > 0) analyzer.scope_maps.items[0] else null,
                analyzer.symbol_ids.items,
            ),
        );

        analyzer.symbol_ids.items[node_index] = source_binding_id orelse return error.MissingSourceBinding;
        try std.testing.expectError(
            error.InvalidDefaultExportFacadeSymbol,
            binding_scanner.populateSyntheticSymbols(
                &alias_table,
                @fromBackingInt(@intCast(0)),
                export_bindings,
                &analyzer.symbols,
                arena_allocator,
                if (analyzer.scope_maps.items.len > 0) analyzer.scope_maps.items[0] else null,
                analyzer.symbol_ids.items,
            ),
        );
        analyzer.symbol_ids.items[node_index] = saved_id;
    }
    try binding_scanner.populateSyntheticSymbols(
        &alias_table,
        @fromBackingInt(@intCast(0)),
        export_bindings,
        &analyzer.symbols,
        arena_allocator,
        if (analyzer.scope_maps.items.len > 0) analyzer.scope_maps.items[0] else null,
        analyzer.symbol_ids.items,
    );

    const actual_id = switch (export_bindings[0].symbol) {
        .alias => return error.UnexpectedAlias,
        .semantic => |reference| @backingInt(reference.symbol),
    };
    if (expects_facade) {
        const facade_id = export_node_id orelse return error.MissingExpectedFacade;
        try std.testing.expectEqual(facade_id, actual_id);
        if (source_expression_id) |source_id| try std.testing.expect(facade_id != source_id);
        const facade = analyzer.symbols.items[facade_id];
        try std.testing.expectEqual(@as(?semantic_symbol.SyntheticKind, .default_export), facade.synthetic_kind);
        try std.testing.expect(!facade.scope_id.isNone());
        try std.testing.expectEqual(@as(u32, 0), facade.scope_id.toIndex());
        if (source_binding_id) |source_id| {
            try std.testing.expect(facade_id != source_id);
            try std.testing.expect(analyzer.symbols.items[source_id].synthetic_kind == null);
        }
    } else {
        try std.testing.expect(export_node_id == null);
        const binding_id = source_binding_id orelse return error.MissingSourceBinding;
        try std.testing.expectEqual(binding_id, actual_id);
        try std.testing.expect(analyzer.symbols.items[binding_id].synthetic_kind == null);
    }
}

test "#4819 default export facade uses its exact analyzer SymbolId despite `_default` collision" {
    try expectDefaultExportIdentity("const _default = 7; export default 42;", true, true);
}

test "#4819 local identifier default expression gets a distinct facade SymbolId" {
    try expectDefaultExportIdentity("const value = 42; export default value;", true, true);
}

test "#4819 imported identifier default expression stays local and gets a facade" {
    try expectDefaultExportIdentity("import { value } from './dep'; export default value;", true, true);
}

test "#4819 source facade-name expression retains separate source and facade anchors" {
    try expectDefaultExportIdentity("const _default = 42; export default _default;", true, true);
}

test "#4819 imported facade-name expression retains a local snapshot export" {
    try expectDefaultExportIdentity("import{value as _default}from'./dep';export default _default;", true, true);
}

test "#4819 unresolved default identifier facade comes from its exact analyzer node" {
    try expectDefaultExportIdentity(
        "globalThis.snapshot = 7; export default snapshot; globalThis.snapshot = 9;",
        true,
        true,
    );
}

test "#4819 local exports use their exact analyzer SymbolId instead of scope name lookup" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const source = "const source = 1; const decoy = 2; export const declared = 3; export { source as publicSource }; export default source;";
    var scanner = try Scanner.init(arena_allocator, source);
    scanner.is_module = true;
    var parser = Parser.init(arena_allocator, &scanner);
    parser.is_module = true;
    parser.enable_scan = true;
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(arena_allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    const import_records = try import_scanner.extractImports(allocator, &parser.ast);
    defer allocator.free(import_records);
    const import_bindings = try extractImportBindings(allocator, &parser.ast, import_records, null);
    defer allocator.free(import_bindings);
    const export_bindings = try extractExportBindings(allocator, &parser.ast, import_records, import_bindings);
    defer allocator.free(export_bindings);
    try std.testing.expectEqual(@as(usize, 3), export_bindings.len);
    try std.testing.expectEqual(@as(usize, 3), parser.scan_export_bindings.items.len);

    var source_symbol: ?u32 = null;
    var decoy_symbol: ?u32 = null;
    var declared_symbol: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, node_index| {
        if (node.tag != .binding_identifier) continue;
        const name = parser.ast.getText(node.span);
        if (std.mem.eql(u8, name, "source")) {
            source_symbol = analyzer.symbol_ids.items[node_index];
        } else if (std.mem.eql(u8, name, "decoy")) {
            decoy_symbol = analyzer.symbol_ids.items[node_index];
        } else if (std.mem.eql(u8, name, "declared")) {
            declared_symbol = analyzer.symbol_ids.items[node_index];
        }
    }
    const expected_source = source_symbol orelse return error.MissingSourceSymbol;
    const wrong_symbol = decoy_symbol orelse return error.MissingDecoySymbol;
    const expected_declared = declared_symbol orelse return error.MissingDeclaredSymbol;
    try std.testing.expect(expected_source != wrong_symbol);

    var alias_export_index: ?usize = null;
    var default_export_index: ?usize = null;
    var declaration_export_index: ?usize = null;
    for (export_bindings, 0..) |eb, i| {
        if (std.mem.eql(u8, eb.exported_name, "publicSource")) alias_export_index = i;
        if (std.mem.eql(u8, eb.exported_name, "default")) default_export_index = i;
        if (std.mem.eql(u8, eb.exported_name, "declared")) declaration_export_index = i;
    }
    const alias_index = alias_export_index orelse return error.MissingAliasExport;
    const default_index = default_export_index orelse return error.MissingDefaultExport;
    const declaration_index = declaration_export_index orelse return error.MissingDeclarationExport;
    const facade_node = export_bindings[default_index].default_export_node orelse return error.MissingDefaultFacadeNode;
    const expected_facade = analyzer.symbol_ids.items[@backingInt(facade_node)] orelse return error.MissingDefaultFacade;
    try std.testing.expect(expected_facade != expected_source);

    // Local aliases retain their exact operand; a default expression instead
    // publishes the distinct facade anchored at its export declaration.
    for (parser.scan_export_bindings.items) |scan_export| {
        if (std.mem.eql(u8, scan_export.exported_name, "default")) {
            const operand = scan_export.local_symbol_node_index orelse return error.MissingSourceOperand;
            try std.testing.expectEqual(expected_source, analyzer.symbol_ids.items[operand].?);
            try std.testing.expect(scan_export.has_default_export_facade);
            try std.testing.expectEqual(expected_facade, analyzer.symbol_ids.items[scan_export.default_export_node_index.?].?);
            continue;
        }
        const expected = if (std.mem.eql(u8, scan_export.exported_name, "publicSource"))
            expected_source
        else if (std.mem.eql(u8, scan_export.exported_name, "declared"))
            expected_declared
        else
            return error.UnexpectedExport;
        const node_index = scan_export.local_symbol_node_index orelse return error.MissingScannedLocalNode;
        try std.testing.expectEqual(expected, analyzer.symbol_ids.items[node_index] orelse return error.MissingScannedLocalSymbol);
    }
    try std.testing.expect(export_bindings[alias_index].local_symbol_node != null);
    try std.testing.expect(export_bindings[default_index].local_symbol_node != null);
    try std.testing.expect(export_bindings[declaration_index].local_symbol_node != null);

    // Hostile name-map corruption: old code follows this wrong mapping. Exact
    // node IDs must still bind the alias, declaration, and default local.
    try analyzer.scope_maps.items[0].put(allocator, "source", wrong_symbol);
    try analyzer.scope_maps.items[0].put(allocator, "declared", wrong_symbol);
    try analyzer.scope_maps.items[0].put(allocator, "_default", wrong_symbol);
    try std.testing.expectEqual(wrong_symbol, analyzer.scope_maps.items[0].get("source").?);
    try std.testing.expectEqual(wrong_symbol, analyzer.scope_maps.items[0].get("declared").?);
    var alias_table = symbol.AliasTable.init(allocator);
    defer alias_table.deinit();
    try binding_scanner.populateSyntheticSymbols(
        &alias_table,
        @fromBackingInt(@intCast(0)),
        export_bindings,
        &analyzer.symbols,
        arena_allocator,
        analyzer.scope_maps.items[0],
        analyzer.symbol_ids.items,
    );
    try expectSemanticExportSymbol(export_bindings[alias_index], expected_source);
    try expectSemanticExportSymbol(export_bindings[default_index], expected_facade);
    try expectSemanticExportSymbol(export_bindings[declaration_index], expected_declared);

    // Missing exact node or ID must fail closed instead of reverting to the
    // poisoned scope map; an out-of-range SID is rejected immediately.
    var missing_node = try allocator.dupe(ExportBinding, export_bindings);
    defer allocator.free(missing_node);
    missing_node[alias_index].local_symbol_node = null;
    try std.testing.expectError(
        error.MissingLocalExportSymbolNode,
        binding_scanner.populateSyntheticSymbols(
            &alias_table,
            @fromBackingInt(@intCast(0)),
            missing_node,
            &analyzer.symbols,
            arena_allocator,
            analyzer.scope_maps.items[0],
            analyzer.symbol_ids.items,
        ),
    );

    const alias_node = export_bindings[alias_index].local_symbol_node.?;
    const alias_node_index = @backingInt(alias_node);
    var missing_id_map = try allocator.dupe(?u32, analyzer.symbol_ids.items);
    defer allocator.free(missing_id_map);
    missing_id_map[alias_node_index] = null;
    try std.testing.expectError(
        error.MissingLocalExportSymbol,
        binding_scanner.populateSyntheticSymbols(
            &alias_table,
            @fromBackingInt(@intCast(0)),
            export_bindings,
            &analyzer.symbols,
            arena_allocator,
            analyzer.scope_maps.items[0],
            missing_id_map,
        ),
    );

    missing_id_map[alias_node_index] = @intCast(analyzer.symbols.items.len);
    try std.testing.expectError(
        error.InvalidLocalExportSymbol,
        binding_scanner.populateSyntheticSymbols(
            &alias_table,
            @fromBackingInt(@intCast(0)),
            export_bindings,
            &analyzer.symbols,
            arena_allocator,
            analyzer.scope_maps.items[0],
            missing_id_map,
        ),
    );
}

fn expectSemanticExportSymbol(export_binding: ExportBinding, expected_symbol: u32) !void {
    switch (export_binding.symbol) {
        .alias => return error.UnexpectedAliasSymbol,
        .semantic => |semantic_ref| try std.testing.expectEqual(expected_symbol, @backingInt(semantic_ref.symbol)),
    }
}

test "#4819 import local identity rejects malformed exact anchors without name recovery" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    const source = "import { value as local, extra } from './dep'; const decoy = 1; console.log(local, extra, decoy);";
    var scanner = try Scanner.init(arena_alloc, source);
    scanner.is_module = true;
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    const root = try parser.parse();
    var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
    analyzer.is_module = true;
    analyzer.enable_stmt_info = true;
    analyzer.collect_unresolved_reference_nodes = true;
    try analyzer.analyze();
    const records = try import_scanner.extractImports(arena_alloc, &parser.ast);
    const imports = try extractImportBindings(arena_alloc, &parser.ast, records, null);
    try std.testing.expectEqual(@as(usize, 2), imports.len);
    const binding = imports[0];
    const node = binding.local_symbol_node orelse return error.MissingImportAnchor;
    const raw = @backingInt(node);
    const expected = analyzer.symbol_ids.items[raw] orelse return error.MissingImportSymbol;
    const decoy = analyzer.scope_maps.items[0].get("decoy") orelse return error.MissingImportDecoy;
    const context: binding_scanner.ImportLocalSymbolContext = .{
        .module_index = types.ModuleIndex.fromUsize(3),
        .ast = &parser.ast,
        .symbol_ids = analyzer.symbol_ids.items,
        .symbols = analyzer.symbols.items,
        .module_scope = analyzer.scope_maps.items[0],
    };
    const resolved = binding_scanner.resolveImportLocalSymbol(binding, context);
    try std.testing.expectEqual(expected, resolved.semanticIndex().?);
    try std.testing.expectEqual(context.module_index, resolved.moduleIndex());

    // A same-kind, in-range wrong SID corrupts the authoritative producer map.
    // Consumers must not guess a repair from spelling; the existing exact
    // declaration audit rejects that graph before output is trusted.
    const other_import = analyzer.scope_maps.items[0].get("extra") orelse return error.MissingOtherImportSymbol;
    const coverage = @import("../transformer/symbol_coverage.zig");
    const origins: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for ([_]u32{ expected, @intCast(other_import) }) |mapped| {
        analyzer.symbol_ids.items[raw] = mapped;
        try std.testing.expectEqual(mapped, binding_scanner.resolveImportLocalSymbol(binding, context).semanticIndex().?);
        const report = try coverage.checkExactWithDeclarationAnchors(
            allocator,
            &parser.ast,
            root,
            @intCast(parser.ast.nodes.items.len),
            analyzer.symbol_ids.items,
            analyzer.symbols.items,
            analyzer.scopes.items,
            analyzer.scope_maps.items,
            &analyzer.scope_owner_map,
            analyzer.references.items,
            analyzer.helper_ref_nodes,
            &analyzer.helper_scope_map,
            &analyzer.unresolved_reference_nodes,
            &.{},
            &origins,
        );
        if (mapped == expected) {
            if (!report.isClean()) std.debug.print("import declaration audit: {any}\n", .{report});
            try std.testing.expect(report.isClean());
        } else {
            try std.testing.expect(!report.isClean());
            try std.testing.expect(report.declaration_identity_mismatch + report.declaration_anchor_mismatch > 0);
        }
    }
    analyzer.symbol_ids.items[raw] = expected;

    var malformed_binding = binding;
    malformed_binding.local_symbol_node = null;
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(malformed_binding, context).isValid());
    malformed_binding.local_symbol_node = .none;
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(malformed_binding, context).isValid());
    malformed_binding.local_symbol_node = @fromBackingInt(@as(u32, @intCast(parser.ast.nodes.items.len)));
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(malformed_binding, context).isValid());

    analyzer.symbol_ids.items[raw] = null;
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(binding, context).isValid());
    analyzer.symbol_ids.items[raw] = @intCast(analyzer.symbols.items.len);
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(binding, context).isValid());
    analyzer.symbol_ids.items[raw] = @intCast(decoy);
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(binding, context).isValid());
    analyzer.symbol_ids.items[raw] = expected;

    const original_tag = parser.ast.nodes.items[raw].tag;
    // Emotion's CSS import alias is a generated binding_identifier rather
    // than the parser's identifier_reference import-local representation.
    parser.ast.nodes.items[raw].tag = .binding_identifier;
    try std.testing.expectEqual(expected, binding_scanner.resolveImportLocalSymbol(binding, context).semanticIndex().?);
    parser.ast.nodes.items[raw].tag = .numeric_literal;
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(binding, context).isValid());
    parser.ast.nodes.items[raw].tag = original_tag;
    var missing_ast = context;
    missing_ast.ast = null;
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(binding, missing_ast).isValid());
    var empty_map = context;
    empty_map.symbol_ids = &.{};
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(binding, empty_map).isValid());

    // The explicit semantic-less API retains the old scope contract; helper
    // selection stays separate from a same-spelling source binding.
    var helper_scope: std.StringHashMapUnmanaged(usize) = .empty;
    try helper_scope.put(arena_alloc, "local", decoy);
    const legacy_context: binding_scanner.ImportLocalSymbolContext = .{
        .module_index = context.module_index,
        .module_scope = analyzer.scope_maps.items[0],
        .helper_scope = helper_scope,
    };
    try std.testing.expectEqual(expected, binding_scanner.resolveImportLocalSymbol(binding, legacy_context).semanticIndex().?);
    malformed_binding = binding;
    malformed_binding.is_helper = true;
    try std.testing.expectEqual(@as(u32, @intCast(decoy)), binding_scanner.resolveImportLocalSymbol(malformed_binding, legacy_context).semanticIndex().?);
    var no_helper_scope = legacy_context;
    no_helper_scope.helper_scope = null;
    try std.testing.expect(!binding_scanner.resolveImportLocalSymbol(malformed_binding, no_helper_scope).isValid());
}

test "default declarations inside ambient modules never publish runtime export records" {
    for ([_][]const u8{
        "declare module '*.css'{const css:string;export default css;}export function run(){}",
        "declare module '*.svg'{const src:string;export default src;}export function run(){}",
        "declare namespace Types{export default class Shape{}}export function run(){}",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, source);
        scanner.is_module = true;
        var parser = Parser.init(allocator, &scanner);
        parser.source_mode = .ts;
        parser.is_module = true;
        parser.enable_scan = true;
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        try std.testing.expectEqual(@as(usize, 1), parser.scan_export_bindings.items.len);
        try std.testing.expectEqualStrings("run", parser.scan_export_bindings.items[0].exported_name);
        const records = try import_scanner.extractImports(allocator, &parser.ast);
        const bindings = try extractExportBindings(allocator, &parser.ast, records, &.{});
        try std.testing.expectEqual(@as(usize, 1), bindings.len);
        try std.testing.expectEqualStrings("run", bindings[0].exported_name);
        try std.testing.expect(!bindings[0].has_default_export_facade);
    }
}

test "import declaration owners are captured by both initial producers in ten forms" {
    const sources = [_][]const u8{
        "import local from './dep.cjs';",
        "import * as local from './dep.cjs';",
        "import {value as local} from './dep.cjs';",
        "import {local} from './dep.cjs';",
        "import local,{value as other} from './dep.cjs';",
        "import local,* as other from './dep.cjs';",
        "import {value as first} from './dep.cjs';import {value as second} from './dep.cjs';",
        "import {type Type,value as local} from './dep.cjs';",
        "import d\\u0065f from './dep.cjs';import * as n\\u0073 from './dep.cjs';",
        "import {'x-y' as local} from './dep.cjs';",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var scanner = try Scanner.init(allocator, source);
        scanner.is_module = true;
        var parser = Parser.init(allocator, &scanner);
        parser.is_module = true;
        parser.enable_scan = true;
        _ = try parser.parse();
        try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
        const records = try import_scanner.extractImports(allocator, &parser.ast);
        const fallback = try extractImportBindings(allocator, &parser.ast, records, null);
        try std.testing.expectEqual(parser.scan_import_bindings.items.len, fallback.len);
        for (parser.scan_import_bindings.items) |initial| {
            const anchor = initial.local_symbol_node_index.?;
            const owner = initial.local_declaration_node_index.?;
            try std.testing.expectEqual(@import("../parser/ast.zig").Node.Tag.import_declaration, parser.ast.nodes.items[owner].tag);
            var matching: ?ImportBinding = null;
            for (fallback) |binding| {
                if (@backingInt(binding.local_symbol_node.?) == anchor) {
                    try std.testing.expect(matching == null);
                    matching = binding;
                }
            }
            try std.testing.expectEqual(owner, @backingInt(matching.?.local_declaration_node.?));
            // An unreachable clone can share every source/local node. It must
            // not alter the producer's already selected declaration identity.
            const clone = try parser.ast.addNode(parser.ast.nodes.items[owner]);
            try std.testing.expect(@backingInt(clone) != owner);
            try std.testing.expectEqual(owner, initial.local_declaration_node_index.?);
        }
    }
}
