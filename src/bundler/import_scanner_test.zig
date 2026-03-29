const std = @import("std");
const import_scanner = @import("import_scanner.zig");
const extractImports = import_scanner.extractImports;
const extractImportsWithCjsDetection = import_scanner.extractImportsWithCjsDetection;
const ScanResult = import_scanner.ScanResult;
const stripQuotes = import_scanner.stripQuotes;
const types = @import("types.zig");
const ImportRecord = types.ImportRecord;
const ImportKind = types.ImportKind;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;

// ============================================================
// Tests
// ============================================================

/// 테스트용 헬퍼. Arena로 파싱 후 import 추출.
/// 반환된 records는 testing.allocator 소유 (caller가 free).
/// Arena는 파싱 완료 후 해제되므로 specifier는 source를 직접 참조해야 동작.
fn parseAndExtract(allocator: std.mem.Allocator, source: []const u8) ![]ImportRecord {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    // records는 caller의 allocator로 할당 (arena 해제 후에도 유효).
    // specifier는 source 슬라이스를 참조하므로 arena와 무관.
    return extractImports(allocator, &parser.ast);
}

/// 테스트용 헬퍼. CJS 감지를 포함한 전체 스캔 결과 반환.
/// CJS 코드는 is_module=false로 파싱해야 정확한 AST가 생성됨.
fn parseAndExtractFull(allocator: std.mem.Allocator, source: []const u8) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    // CJS 테스트를 위해 is_module을 설정하지 않음 (기본값 false)
    _ = try parser.parse();

    return extractImportsWithCjsDetection(allocator, &parser.ast);
}

test "side-effect import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import './styles.css';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./styles.css", records[0].specifier);
    try std.testing.expectEqual(ImportKind.side_effect, records[0].kind);
}

test "default import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import foo from './foo';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./foo", records[0].specifier);
    try std.testing.expectEqual(ImportKind.static_import, records[0].kind);
}

test "named import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import { a, b } from './bar';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./bar", records[0].specifier);
    try std.testing.expectEqual(ImportKind.static_import, records[0].kind);
}

test "namespace import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import * as ns from './baz';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./baz", records[0].specifier);
    try std.testing.expectEqual(ImportKind.static_import, records[0].kind);
}

test "export all (re-export)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "export * from './all';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./all", records[0].specifier);
    try std.testing.expectEqual(ImportKind.re_export, records[0].kind);
}

test "export named re-export" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "export { x, y } from './utils';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./utils", records[0].specifier);
    try std.testing.expectEqual(ImportKind.re_export, records[0].kind);
}

test "export named local (no source) — not extracted" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const x = 1; export { x };");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "export declaration (no source) — not extracted" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "export const x = 1;");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "dynamic import (string literal)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const m = import('./lazy');");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./lazy", records[0].specifier);
    try std.testing.expectEqual(ImportKind.dynamic_import, records[0].kind);
}

test "dynamic import (computed) — not extracted" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const m = import(foo);");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "multiple imports" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc,
        \\import './a';
        \\import b from './b';
        \\import { c } from './c';
        \\export * from './d';
        \\export { e } from './e';
    );
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 5), records.len);
    try std.testing.expectEqualStrings("./a", records[0].specifier);
    try std.testing.expectEqualStrings("./b", records[1].specifier);
    try std.testing.expectEqualStrings("./c", records[2].specifier);
    try std.testing.expectEqualStrings("./d", records[3].specifier);
    try std.testing.expectEqualStrings("./e", records[4].specifier);
}

test "no imports" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const x = 1;");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}

test "double-quoted import" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import foo from \"./foo\";");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./foo", records[0].specifier);
}

test "bare specifier (npm package)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "import React from 'react';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("react", records[0].specifier);
    try std.testing.expectEqual(ImportKind.static_import, records[0].kind);
}

test "export all with alias" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "export * as ns from './ns';");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("./ns", records[0].specifier);
    try std.testing.expectEqual(ImportKind.re_export, records[0].kind);
}

test "stripQuotes" {
    try std.testing.expectEqualStrings("foo", stripQuotes("'foo'").?);
    try std.testing.expectEqualStrings("bar", stripQuotes("\"bar\"").?);
    try std.testing.expect(stripQuotes("x") == null);
    try std.testing.expect(stripQuotes("") == null);
}

// ============================================================
// CJS 감지 테스트
// ============================================================

test "CJS: require() call detected" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "const x = require('./foo');");
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 1), result.records.len);
    try std.testing.expectEqualStrings("./foo", result.records[0].specifier);
    try std.testing.expectEqual(ImportKind.require, result.records[0].kind);
    try std.testing.expect(result.has_cjs_require);
    try std.testing.expect(!result.has_esm_syntax);
}

test "CJS: require with non-string argument ignored" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "const x = require(variable);");
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 0), result.records.len);
    try std.testing.expect(!result.has_cjs_require);
}

test "CJS: module.exports detected" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "module.exports = {};");
    defer alloc.free(result.records);

    try std.testing.expect(result.has_module_exports);
    try std.testing.expect(!result.has_esm_syntax);
}

test "CJS: exports.x detected" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "exports.x = 1;");
    defer alloc.free(result.records);

    try std.testing.expect(result.has_exports_dot);
    try std.testing.expect(!result.has_module_exports);
    try std.testing.expect(!result.has_esm_syntax);
}

test "CJS: ESM syntax flag set" {
    const alloc = std.testing.allocator;
    // is_module=false에서도 ESM 구문 감지 테스트를 위해 parseAndExtract 사용
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, "import x from './foo';");
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    const result = try extractImportsWithCjsDetection(alloc, &parser.ast);
    defer alloc.free(result.records);

    try std.testing.expect(result.has_esm_syntax);
    try std.testing.expectEqual(@as(usize, 1), result.records.len);
}

test "CJS: mixed ESM and CJS" {
    const alloc = std.testing.allocator;
    // ESM + CJS 혼용 — is_module=true로 파싱해야 import 구문이 인식됨
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, "import './a'; const b = require('./b');");
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    const result = try extractImportsWithCjsDetection(alloc, &parser.ast);
    defer alloc.free(result.records);

    try std.testing.expect(result.has_esm_syntax);
    try std.testing.expect(result.has_cjs_require);
    try std.testing.expectEqual(@as(usize, 2), result.records.len);
}

test "CJS: multiple require calls" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc,
        \\const a = require('./a');
        \\const b = require('./b');
    );
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 2), result.records.len);
    try std.testing.expectEqualStrings("./a", result.records[0].specifier);
    try std.testing.expectEqual(ImportKind.require, result.records[0].kind);
    try std.testing.expectEqualStrings("./b", result.records[1].specifier);
    try std.testing.expectEqual(ImportKind.require, result.records[1].kind);
    try std.testing.expect(result.has_cjs_require);
}
