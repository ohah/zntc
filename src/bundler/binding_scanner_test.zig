const std = @import("std");
const binding_scanner = @import("binding_scanner.zig");
const ImportBinding = binding_scanner.ImportBinding;
const ExportBinding = binding_scanner.ExportBinding;
const extractImportBindings = binding_scanner.extractImportBindings;
const extractExportBindings = binding_scanner.extractExportBindings;
const types = @import("types.zig");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const import_scanner = @import("import_scanner.zig");
const symbol = @import("symbol.zig");
const semantic_symbol = @import("../semantic/symbol.zig");

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

    const import_bindings = try extractImportBindings(allocator, &parser.ast, records);
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
    try std.testing.expectEqual(ExportBinding.Kind.re_export_all, r.export_bindings[0].kind);
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

    try binding_scanner.populateSyntheticSymbols(&table, @enumFromInt(0), r.export_bindings, &sem_syms, alloc);
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

    try binding_scanner.populateSyntheticSymbols(&table, @enumFromInt(0), r.export_bindings, &sem_syms, alloc);
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

    try binding_scanner.populateSyntheticSymbols(&table, @enumFromInt(0), r.export_bindings, &sem_syms, alloc);
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
    try binding_scanner.populateSyntheticSymbols(&table, m, r.export_bindings, &sem_syms, alloc);

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

    try binding_scanner.populateSyntheticSymbols(&table, @enumFromInt(0), r.export_bindings, &sem_syms, alloc);

    try std.testing.expect(!r.export_bindings[0].symbol.isValid());
}
