const std = @import("std");
const binding_scanner = @import("binding_scanner.zig");
const ImportBinding = binding_scanner.ImportBinding;
const ExportBinding = binding_scanner.ExportBinding;
const extractImportBindings = binding_scanner.extractImportBindings;
const extractExportBindings = binding_scanner.extractExportBindings;
const types = @import("types.zig");
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

test "populateSyntheticSymbols: 리터럴 default만 _default 등록 (로컬 var 재사용은 제외)" {
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

    try binding_scanner.populateSyntheticSymbols(&table, @enumFromInt(0), r.export_bindings, &sem_syms, alloc, null, null);
    const idx = findDefaultSymbol(sem_syms.items) orelse return error.NotFound;
    try std.testing.expectEqualStrings("_default", sem_syms.items[idx].synthetic_name);
}

test "populateSyntheticSymbols: `export default x`(x는 로컬)은 _default 미등록" {
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

    try binding_scanner.populateSyntheticSymbols(&table, @enumFromInt(0), r.export_bindings, &sem_syms, alloc, null, null);
    try std.testing.expectEqual(@as(?usize, null), findDefaultSymbol(sem_syms.items));
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

    try binding_scanner.populateSyntheticSymbols(&table, @enumFromInt(0), r.export_bindings, &sem_syms, alloc, null, null);
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

    const m: types.ModuleIndex = @enumFromInt(7);
    try binding_scanner.populateSyntheticSymbols(&table, m, r.export_bindings, &sem_syms, alloc, null, null);

    try std.testing.expect(r.export_bindings[0].symbol.isValid());
    try std.testing.expectEqual(m, r.export_bindings[0].symbol.moduleIndex());
    switch (r.export_bindings[0].symbol) {
        .alias => return error.UnexpectedSpace,
        .semantic => |s| {
            const idx: u32 = @intFromEnum(s.symbol);
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

    try binding_scanner.populateSyntheticSymbols(&table, @enumFromInt(0), r.export_bindings, &sem_syms, alloc, null, null);

    try std.testing.expect(!r.export_bindings[0].symbol.isValid());
}

fn expectDefaultExportIdentity(source: []const u8, expects_facade: bool) !void {
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
    var source_binding_id: ?u32 = null;
    for (parser.ast.nodes.items, 0..) |node, index| {
        if (node.tag == .export_default_declaration) {
            export_node_index = index;
            export_node_id = analyzer.symbol_ids.items[index];
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
    try std.testing.expectEqual(expects_facade, scan_export.has_default_export_facade);

    var alias_table = symbol.AliasTable.init(allocator);
    defer alias_table.deinit();
    if (expects_facade) {
        const node_index = export_node_index orelse return error.MissingExpectedFacadeNode;
        const saved_id = analyzer.symbol_ids.items[node_index] orelse return error.MissingExpectedFacade;

        var missing_node_bindings = try allocator.dupe(ExportBinding, export_bindings);
        defer allocator.free(missing_node_bindings);
        missing_node_bindings[0].default_export_node = null;
        try std.testing.expectError(
            error.MissingDefaultExportFacadeNode,
            binding_scanner.populateSyntheticSymbols(
                &alias_table,
                @enumFromInt(0),
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
                @enumFromInt(0),
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
                @enumFromInt(0),
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
        @enumFromInt(0),
        export_bindings,
        &analyzer.symbols,
        arena_allocator,
        if (analyzer.scope_maps.items.len > 0) analyzer.scope_maps.items[0] else null,
        analyzer.symbol_ids.items,
    );

    const actual_id = switch (export_bindings[0].symbol) {
        .alias => return error.UnexpectedAlias,
        .semantic => |reference| @intFromEnum(reference.symbol),
    };
    if (expects_facade) {
        const facade_id = export_node_id orelse return error.MissingExpectedFacade;
        try std.testing.expect(source_binding_id != null);
        try std.testing.expect(facade_id != source_binding_id.?);
        try std.testing.expectEqual(facade_id, actual_id);
        try std.testing.expect(analyzer.symbols.items[source_binding_id.?].synthetic_kind == null);
    } else {
        try std.testing.expect(export_node_id == null);
        const binding_id = source_binding_id orelse return error.MissingSourceBinding;
        try std.testing.expectEqual(binding_id, actual_id);
        try std.testing.expect(analyzer.symbols.items[binding_id].synthetic_kind == null);
    }
}

test "#4819 default export facade uses its exact analyzer SymbolId despite `_default` collision" {
    try expectDefaultExportIdentity("const _default = 7; export default 42;", true);
}

test "#4819 default export of source `_default` stays a regular local binding" {
    try expectDefaultExportIdentity("const _default = 42; export default _default;", false);
}
