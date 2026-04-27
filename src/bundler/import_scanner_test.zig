const std = @import("std");
const import_scanner = @import("import_scanner.zig");
const extractImports = import_scanner.extractImports;
const extractImportsWithCjsDetection = import_scanner.extractImportsWithCjsDetection;
const extractImportsWithCjsDetectionAndDefines = import_scanner.extractImportsWithCjsDetectionAndDefines;
const ScanResult = import_scanner.ScanResult;
const stripQuotes = import_scanner.stripQuotes;
const types = @import("types.zig");
const ImportRecord = types.ImportRecord;
const ImportKind = types.ImportKind;
const RequireContextMode = types.RequireContextMode;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;

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

fn parseAndExtractFullWithDefines(
    allocator: std.mem.Allocator,
    source: []const u8,
    defines: []const DefineEntry,
) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    _ = try parser.parse();

    return extractImportsWithCjsDetectionAndDefines(allocator, &parser.ast, defines);
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

test "transformed_root: orphan import declaration is ignored" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc,
        \\import { unused } from './dead';
        \\console.log('entry');
    );
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    const old_root_idx: NodeIndex = @enumFromInt(@as(u32, @intCast(parser.ast.nodes.items.len - 1)));
    const old_root = parser.ast.getNode(old_root_idx);
    const old_body = old_root.data.list;
    try std.testing.expectEqual(@as(u32, 2), old_body.len);

    const expr_idx: NodeIndex = @enumFromInt(parser.ast.extra_data.items[old_body.start + 1]);
    const new_body = try parser.ast.addNodeList(&.{expr_idx});
    const new_root = try parser.ast.addNode(.{
        .tag = .program,
        .span = old_root.span,
        .data = .{ .list = new_body },
    });
    parser.ast.transformed_root = new_root;

    const records = try extractImports(alloc, &parser.ast);
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
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

test "CJS: define으로 죽은 if 분기의 require는 스캔하지 않음" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFullWithDefines(
        alloc,
        \\if (process.env.NODE_ENV === 'production') {
        \\  module.exports = require('./prod');
        \\} else {
        \\  module.exports = require('./dev');
        \\}
    ,
        &.{.{ .key = "process.env.NODE_ENV", .value = "\"production\"" }},
    );
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 1), result.records.len);
    try std.testing.expectEqualStrings("./prod", result.records[0].specifier);
    try std.testing.expect(result.has_cjs_require);
    try std.testing.expect(result.has_module_exports);
}

/// try-block 안의 require/import 가 `is_optional` 로 마킹되는지 검증하는 헬퍼.
/// `markOptionalRequiresInTryBlocks` 는 ast 를 borrow 하므로 arena 가 살아있을 때
/// 호출해야 한다.
fn parseExtractAndMarkOptional(allocator: std.mem.Allocator, source: []const u8) ![]ImportRecord {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    _ = try parser.parse();

    const result = try extractImportsWithCjsDetection(allocator, &parser.ast);
    try import_scanner.markOptionalRequiresInTryBlocks(allocator, &parser.ast, result.records);
    return result.records;
}

test "optional: try-block 안의 require 는 is_optional=true 로 마킹" {
    const alloc = std.testing.allocator;
    const records = try parseExtractAndMarkOptional(
        alloc,
        \\let dbg;
        \\try { dbg = require("debug"); } catch (e) {}
        ,
    );
    defer alloc.free(records);

    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("debug", records[0].specifier);
    try std.testing.expectEqual(ImportKind.require, records[0].kind);
    try std.testing.expect(records[0].is_optional);
}

test "optional: try-block 바깥의 require 는 is_optional=false 유지 (회귀 가드)" {
    const alloc = std.testing.allocator;
    const records = try parseExtractAndMarkOptional(
        alloc,
        \\const x = require("./hard");
        \\try { const y = require("./soft"); } catch (e) {}
        ,
    );
    defer alloc.free(records);

    try std.testing.expectEqual(@as(usize, 2), records.len);
    // 첫 require — try 바깥
    try std.testing.expectEqualStrings("./hard", records[0].specifier);
    try std.testing.expect(!records[0].is_optional);
    // 두 번째 require — try 안
    try std.testing.expectEqualStrings("./soft", records[1].specifier);
    try std.testing.expect(records[1].is_optional);
}

test "optional: try-block 안의 dynamic import 도 is_optional=true" {
    const alloc = std.testing.allocator;
    const records = try parseExtractAndMarkOptional(
        alloc,
        \\async function f() {
        \\  try { await import("optdep"); } catch (e) {}
        \\}
        ,
    );
    defer alloc.free(records);

    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("optdep", records[0].specifier);
    try std.testing.expectEqual(ImportKind.dynamic_import, records[0].kind);
    try std.testing.expect(records[0].is_optional);
}

test "optional: follow-redirects/debug.js 패턴 (require(...)(...))" {
    const alloc = std.testing.allocator;
    const records = try parseExtractAndMarkOptional(
        alloc,
        \\var debug;
        \\try {
        \\  debug = require("debug")("follow-redirects");
        \\} catch (e) {}
        ,
    );
    defer alloc.free(records);

    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("debug", records[0].specifier);
    try std.testing.expect(records[0].is_optional);
}

test "optional: try-block 이 없으면 모든 require 가 is_optional=false" {
    const alloc = std.testing.allocator;
    const records = try parseExtractAndMarkOptional(
        alloc,
        \\const a = require("./a");
        \\const b = require("./b");
        ,
    );
    defer alloc.free(records);

    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expect(!records[0].is_optional);
    try std.testing.expect(!records[1].is_optional);
}

test "CJS: define boolean으로 죽은 if 분기의 require는 스캔하지 않음" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFullWithDefines(
        alloc,
        \\if (__DEV__) {
        \\  require('./dev-only');
        \\} else {
        \\  require('./prod-only');
        \\}
    ,
        &.{.{ .key = "__DEV__", .value = "false" }},
    );
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 1), result.records.len);
    try std.testing.expectEqualStrings("./prod-only", result.records[0].specifier);
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

test "CJS: Object.defineProperty(exports) detected" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "Object.defineProperty(exports, '__esModule', { value: true });");
    defer alloc.free(result.records);

    try std.testing.expect(result.has_exports_dot);
    try std.testing.expect(!result.has_module_exports);
    try std.testing.expect(!result.has_esm_syntax);
}

test "CJS: Object.defineProperty(module.exports) detected" {
    const alloc = std.testing.allocator;
    const result = try parseAndExtractFull(alloc, "Object.defineProperty(module.exports, 'x', { value: 1 });");
    defer alloc.free(result.records);

    try std.testing.expect(result.has_exports_dot);
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

test "glob: import.meta.glob with eager option" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, "const m = import.meta.glob('./dir/*.ts', { eager: true });");
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    const result = try extractImportsWithCjsDetection(alloc, &parser.ast);
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 1), result.records.len);
    try std.testing.expectEqual(ImportKind.glob, result.records[0].kind);
    try std.testing.expectEqualStrings("./dir/*.ts", result.records[0].specifier);
    try std.testing.expect(result.records[0].glob_eager);
}

test "glob: import.meta.glob with import option" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, "const m = import.meta.glob('./dir/*.ts', { import: 'setup' });");
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    _ = try parser.parse();

    const result = try extractImportsWithCjsDetection(alloc, &parser.ast);
    defer alloc.free(result.records);

    try std.testing.expectEqual(@as(usize, 1), result.records.len);
    try std.testing.expectEqual(ImportKind.glob, result.records[0].kind);
    try std.testing.expect(result.records[0].glob_import_name != null);
    try std.testing.expectEqualStrings("setup", result.records[0].glob_import_name.?);
    try std.testing.expect(!result.records[0].glob_eager);
}

// ============================================================
// require.context (#1579 Phase 1)
// Reference: Metro `collectDependencies-test.js`,
//            ZTS 의 기존 tryExtractGlob mirror 패턴
// ============================================================

/// require_context kind 인 첫 record 만 반환.
fn findContextRecord(records: []const ImportRecord) ?ImportRecord {
    for (records) |r| {
        if (r.kind == .require_context) return r;
    }
    return null;
}

/// 모든 require_context record 개수.
fn countContextRecords(records: []const ImportRecord) usize {
    var n: usize = 0;
    for (records) |r| {
        if (r.kind == .require_context) n += 1;
    }
    return n;
}

/// valid require.context record 검증 (invalid_reason==null + 필드 일치).
fn expectValidContext(
    record: ImportRecord,
    dir: []const u8,
    recursive: bool,
    filter: ?[]const u8,
    filter_flags: ?[]const u8,
    mode: RequireContextMode,
) !void {
    try std.testing.expectEqual(ImportKind.require_context, record.kind);
    try std.testing.expect(record.context_invalid_reason == null);
    try std.testing.expectEqualStrings(dir, record.specifier);
    try std.testing.expectEqual(recursive, record.context_recursive);
    if (filter) |f| {
        try std.testing.expect(record.context_filter != null);
        try std.testing.expectEqualStrings(f, record.context_filter.?);
    } else {
        try std.testing.expect(record.context_filter == null);
    }
    if (filter_flags) |ff| {
        try std.testing.expect(record.context_filter_flags != null);
        try std.testing.expectEqualStrings(ff, record.context_filter_flags.?);
    } else {
        // null 또는 빈 string 둘 다 허용
        if (record.context_filter_flags) |actual| {
            try std.testing.expectEqualStrings("", actual);
        }
    }
    try std.testing.expectEqual(mode, record.context_mode);
}

// ─── A. 기본 인지 + 정상 평가 ────────────────────────────

test "require.context: bare call — all defaults" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const ctx = require.context('./pages');");
    defer alloc.free(records);

    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

test "require.context: explicit recursive=false" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./pages', false);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", false, null, null, .sync);
}

test "require.context: explicit recursive=true" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./pages', true);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

test "require.context: filter regex without flags" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', true, /foo/);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, "foo", null, .sync);
}

test "require.context: filter regex with single flag" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', true, /custom/i);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, "custom", "i", .sync);
}

test "require.context: filter regex with multiple flags" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', true, /foo/im);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, "foo", "im", .sync);
}

test "require.context: filter regex complex pattern" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./app', true, /\\.tsx?$/);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./app", true, "\\.tsx?$", null, .sync);
}

test "require.context: mode 'sync' explicit" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', true, /.*/, 'sync');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, ".*", null, .sync);
}

test "require.context: mode 'eager'" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', true, /.*/, 'eager');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, ".*", null, .eager);
}

test "require.context: mode 'lazy'" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', true, /.*/, 'lazy');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, ".*", null, .lazy);
}

test "require.context: mode 'lazy-once'" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', true, /.*/, 'lazy-once');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, ".*", null, .lazy_once);
}

// ─── B. undefined 명시 → default 폴백 ────────────────────

test "require.context: explicit undefined for all optional args" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./', undefined, undefined, undefined);",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, null, null, .sync);
}

test "require.context: undefined filter only" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./', false, undefined, 'eager');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", false, null, null, .eager);
}

test "require.context: undefined mode only" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./', true, /foo/, undefined);",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, "foo", null, .sync);
}

// ─── C. directory 형태 변형 ───────────────────────────────

test "require.context: directory '.'" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('.');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, ".", true, null, null, .sync);
}

test "require.context: directory './'" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./", true, null, null, .sync);
}

test "require.context: directory '../parent'" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('../parent');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "../parent", true, null, null, .sync);
}

test "require.context: directory deep nested './a/b/c'" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./a/b/c');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./a/b/c", true, null, null, .sync);
}

// ─── D. string literal 형태 ───────────────────────────────

test "require.context: directory with double quotes" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context(\"./pages\");");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

test "require.context: trailing comma in args" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./pages',);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

// ─── E. TS 통합 ────────────────────────────────────────────

test "require.context: TS generic on callee" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "const ctx = require.context<unknown>('./pages');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

// ─── F. 사용처 (어디서든 인지) ─────────────────────────────

test "require.context: in function body" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "function makeCtx() { return require.context('./pages'); }",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

test "require.context: in arrow function body" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "const f = () => require.context('./pages');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

test "require.context: in export const declaration" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "export const ctx = require.context('./pages');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

test "require.context: as argument to another call" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "registerCtx(require.context('./pages'));",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

// ─── G. 격리 / 무시 (다른 callee 는 require_context 가 아님) ───────

test "require.context: plain require is not require_context" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const x = require('./pages');");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), countContextRecords(records));
    // 일반 require record 는 있어야 함
    var has_require = false;
    for (records) |r| if (r.kind == .require) {
        has_require = true;
    };
    try std.testing.expect(has_require);
}

test "require.context: Symbol.context is ignored" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "Symbol.context('./pages');");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), countContextRecords(records));
}

test "require.context: req.context (different identifier) is ignored" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "const req = {}; req.context('./pages');",
    );
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), countContextRecords(records));
}

test "require.context: require['context'] (computed access) is ignored" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require['context']('./pages');");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), countContextRecords(records));
}

test "require.context: require?.context (optional chaining) is ignored" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require?.context('./pages');");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), countContextRecords(records));
}

test "require.context: require.contextFoo (different prop) is ignored" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.contextFoo('./pages');");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), countContextRecords(records));
}

test "require.context: require.context.foo (deep member call) is ignored" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context.foo('./pages');");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), countContextRecords(records));
}

// ─── H. Multiple calls — 각각 별개 record ─────────────────

test "require.context: same dir twice — two records" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc,
        \\require.context('./pages');
        \\require.context('./pages');
    );
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 2), countContextRecords(records));
}

test "require.context: different dirs — two records" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc,
        \\require.context('./a');
        \\require.context('./b');
    );
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 2), countContextRecords(records));
}

test "require.context: mixed with plain require — both kinds present" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc,
        \\const ctx = require.context('./pages');
        \\const lib = require('./lib');
    );
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 1), countContextRecords(records));
    var has_require = false;
    for (records) |r| if (r.kind == .require) {
        has_require = true;
    };
    try std.testing.expect(has_require);
}

// ─── I. 호출 결과 chaining ─────────────────────────────────

test "require.context: chained .keys() — context call still recognized" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const k = require.context('./pages').keys();");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

test "require.context: immediately invoked result — context call still recognized" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const m = require.context('./pages')('./foo');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

// ─── J. 에러 케이스 (context_invalid_reason 채워짐) ────────

test "require.context: no args — invalid (no directory)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context();");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: numeric directory — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context(42);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: null directory — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context(null);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: boolean directory — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context(true);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: template literal directory — invalid (literal-only policy)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context(`./pages`);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: identifier directory — invalid (literal-only policy)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "const dir = './pages'; require.context(dir);",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: string recursive — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', 'hey');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: numeric recursive — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', 0);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: NewExpression as filter — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./', false, new RegExp('foo'));",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: string filter — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', false, 'foo');");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: numeric mode — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "require.context('./', false, /foo/, 42);");
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: invalid mode value 'invalid' — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./', false, /foo/, 'invalid');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: too many args (5) — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./', false, /foo/, 'sync', 'extra');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: spread argument — invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "const args = ['./']; require.context(...args);",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

// ─── K. Expo Router 실제 사용 패턴 ───────────────────────

test "require.context: Expo Router _ctx.ios.js pattern (filter regex with negative lookahead)" {
    // expo-router/_ctx.ios.tsx 의 실제 호출. process.env 인자는 Phase 1 이후 다룸.
    // 여기서는 인자가 모두 literal 인 변형으로 검증.
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./app', true, /^(?:\\.\\/)(?!.*\\+api).*\\.[tj]sx?$/, 'sync');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(
        r,
        "./app",
        true,
        "^(?:\\.\\/)(?!.*\\+api).*\\.[tj]sx?$",
        null,
        .sync,
    );
}

// ─── L. Edge — JSX/TSX 컨텍스트 ──────────────────────────

// ─── P. Define table evaluator (#1579 Phase 2.6) ─────────

const DefineEntry = @import("../parser/scan_results.zig").DefineEntry;

fn parseAndExtractWithDefines(
    allocator: std.mem.Allocator,
    source: []const u8,
    defines: []const DefineEntry,
) ![]ImportRecord {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    scanner.is_module = true;
    parser.scan_defines = defines;
    _ = try parser.parse();

    const result = try import_scanner.extractImportsWithCjsDetectionAndDefines(allocator, &parser.ast, defines);
    return result.records;
}

test "require.context: process.env.X with define → string literal evaluation" {
    const defines = [_]DefineEntry{
        .{ .key = "process.env.EXPO_ROUTER_APP_ROOT", .value = "\"./app\"" },
    };
    const alloc = std.testing.allocator;
    const records = try parseAndExtractWithDefines(
        alloc,
        "require.context(process.env.EXPO_ROUTER_APP_ROOT, true, /\\.tsx?$/, 'sync');",
        &defines,
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./app", true, "\\.tsx?$", null, .sync);
}

test "require.context: process.env.X without define → invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtractWithDefines(
        alloc,
        "require.context(process.env.EXPO_ROUTER_APP_ROOT, true, /.*/, 'sync');",
        &.{},
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: process.env mode with define" {
    const defines = [_]DefineEntry{
        .{ .key = "process.env.EXPO_ROUTER_IMPORT_MODE", .value = "\"eager\"" },
    };
    const alloc = std.testing.allocator;
    const records = try parseAndExtractWithDefines(
        alloc,
        "require.context('./app', true, /.*/, process.env.EXPO_ROUTER_IMPORT_MODE);",
        &defines,
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./app", true, ".*", null, .eager);
}

test "require.context: identifier reference with define" {
    const defines = [_]DefineEntry{
        .{ .key = "MY_DIR", .value = "\"./pages\"" },
    };
    const alloc = std.testing.allocator;
    const records = try parseAndExtractWithDefines(
        alloc,
        "require.context(MY_DIR);",
        &defines,
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

test "require.context: define with non-string value (bool) → invalid" {
    // value 가 quoted string 아니므로 evaluator 가 매칭 못 함
    const defines = [_]DefineEntry{
        .{ .key = "MY_FLAG", .value = "true" },
    };
    const alloc = std.testing.allocator;
    const records = try parseAndExtractWithDefines(
        alloc,
        "require.context(MY_FLAG);",
        &defines,
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: Expo Router _ctx.ios.js full pattern with defines" {
    const defines = [_]DefineEntry{
        .{ .key = "process.env.EXPO_ROUTER_APP_ROOT", .value = "\"./app\"" },
        .{ .key = "process.env.EXPO_ROUTER_IMPORT_MODE", .value = "\"sync\"" },
    };
    const alloc = std.testing.allocator;
    const records = try parseAndExtractWithDefines(
        alloc,
        "export const ctx = require.context(process.env.EXPO_ROUTER_APP_ROOT, true, /^(?:\\.\\/)(?!.*\\+api).*\\.[tj]sx?$/, process.env.EXPO_ROUTER_IMPORT_MODE);",
        &defines,
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expectEqual(ImportKind.require_context, r.kind);
    try std.testing.expect(r.context_invalid_reason == null);
    try std.testing.expectEqualStrings("./app", r.specifier);
    try std.testing.expectEqual(true, r.context_recursive);
    try std.testing.expectEqual(RequireContextMode.sync, r.context_mode);
}

test "require.context: inside JSX expression container" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var scanner = try Scanner.init(arena_alloc, "const e = <div>{require.context('./pages')}</div>;");
    var parser = Parser.init(arena_alloc, &scanner);
    parser.is_module = true;
    parser.is_jsx = true;
    scanner.is_module = true;
    _ = try parser.parse();
    const records = try extractImports(alloc, &parser.ast);
    defer alloc.free(records);

    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./pages", true, null, null, .sync);
}

// ─── M. babel-plugin-transform-require-context (asapach) 추가 케이스 ────

test "require.context: bare member access without invocation is ignored" {
    // `const x = require.context;` — call_expression 이 아니므로 인지 안 함.
    // babel-plugin 의 "doesn't transform require.context property" 와 동일.
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc, "const x = require.context;");
    defer alloc.free(records);
    try std.testing.expectEqual(@as(usize, 0), countContextRecords(records));
}

test "require.context: shadowed `require` parameter — currently still recognized" {
    // babel-plugin 은 scope tracking 으로 shadowing 시 무시. ZTS 의 tryExtractRequire 도
    // scope 추적 안 하므로 일관성 차원에서 인지함. shadowing 시 무시는 별도 정책 결정 필요
    // (Phase 2 또는 별도 이슈). 이 테스트는 현재 정책 (인지) 을 명시한다.
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(alloc,
        \\function test(require) {
        \\  const ctx = require.context('foo', false);
        \\}
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "foo", false, null, null, .sync);
}

test "require.context: babel-plugin chained result pattern `requireAll(require.context(...))`" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "var modules = requireAll(require.context('./spec', true, /^\\.\\/.*\\.js$/));",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./spec", true, "^\\.\\/.*\\.js$", null, .sync);
}

// ─── N. Expo Router 실제 _ctx 시리즈 (literal-only 변형) ──────────────

test "require.context: Expo Router _ctx-html.js pattern (recursive=false + +html regex + 'sync')" {
    // packages/expo-router/_ctx-html.js 의 실제 호출. EXPO_ROUTER_APP_ROOT 만 literal 로 치환.
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "export const ctx = require.context('./app', false, /\\+html\\.[tj]sx?$/, 'sync');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try expectValidContext(r, "./app", false, "\\+html\\.[tj]sx?$", null, .sync);
}

test "require.context: Expo Router _ctx.android.js pattern (.android|.ios|.native variant)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./app', true, /^(?:\\.\\/)(?!(?:(?:(?:.*\\+api)|(?:\\+middleware)|(?:\\+(html|native-intent))))\\.[tj]sx?$).*(?:\\.android|\\.ios|\\.native)?\\.[tj]sx?$/, 'sync');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expectEqual(ImportKind.require_context, r.kind);
    try std.testing.expect(r.context_invalid_reason == null);
    try std.testing.expectEqualStrings("./app", r.specifier);
    try std.testing.expectEqual(true, r.context_recursive);
    try std.testing.expectEqual(RequireContextMode.sync, r.context_mode);
}

test "require.context: Expo Router _ctx.web.js pattern (.android|.web variant)" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./app', true, /^(?:\\.\\/)(?!(?:(?:(?:.*\\+api)|(?:\\+html)|(?:\\+middleware)))\\.[tj]sx?$).*(?:\\.android|\\.web)?\\.[tj]sx?$/, 'sync');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expectEqual(ImportKind.require_context, r.kind);
    try std.testing.expect(r.context_invalid_reason == null);
    try std.testing.expectEqualStrings("./app", r.specifier);
}

// ─── O. Phase 2 candidate — process.env.* 인자 (현재는 invalid) ───────

test "require.context: process.env.EXPO_ROUTER_APP_ROOT directory — Phase 1 invalid (Phase 2 valid via define)" {
    // expo-router/_ctx.ios.js 의 원본 형태. Phase 1 에서는 identifier-like 이므로 invalid.
    // Phase 2 에서 define 치환 후 string literal 로 평가되어 valid 되도록 발전 예정.
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context(process.env.EXPO_ROUTER_APP_ROOT, true, /.*/, 'sync');",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}

test "require.context: process.env.EXPO_ROUTER_IMPORT_MODE mode — Phase 1 invalid" {
    const alloc = std.testing.allocator;
    const records = try parseAndExtract(
        alloc,
        "require.context('./app', true, /.*/, process.env.EXPO_ROUTER_IMPORT_MODE);",
    );
    defer alloc.free(records);
    const r = findContextRecord(records) orelse return error.TestExpectedRecord;
    try std.testing.expect(r.context_invalid_reason != null);
}
