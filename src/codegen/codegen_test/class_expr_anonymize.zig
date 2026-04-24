//! class expression name 익명화 유닛 테스트 — #1587 (fast path) + #1596 (non-fast-path).
//!
//! 번들러 없이 scan → parse → semantic → transform → codegen 파이프라인을 직접 구성해
//! 익명화 판정을 검증한다. semantic pass 가 없으면 reference_count 가 비어 익명화 자체가
//! 조기 false 로 빠지므로 본 파일은 전용 헬퍼로 직접 semantic 을 돌린다.
//! bundler 통합 테스트는 `src/bundler/bundler_test/minify_loader.zig` 에 별도 존재.

const std = @import("std");
const helpers = @import("helpers.zig");
const Scanner = helpers.Scanner;
const Parser = helpers.Parser;
const Transformer = helpers.Transformer;
const TransformOptions = helpers.TransformOptions;
const Codegen = helpers.Codegen;
const TestResult = helpers.TestResult;
const SemanticAnalyzer = @import("../../semantic/analyzer.zig").SemanticAnalyzer;

fn runSemanticPipeline(
    backing_allocator: std.mem.Allocator,
    source: []const u8,
    t_options: TransformOptions,
) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".ts");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.is_ts = parser.is_ts;
    analyzer.is_flow = parser.is_flow;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, t_options);
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.line_offsets = scanner.line_offsets.items;
    const root = try transformer.transform();

    var cg = Codegen.initWithOptions(allocator, transformer.ast, .{ .minify_whitespace = true });
    const output = try cg.generate(root);

    return .{ .output = output, .arena = arena };
}

/// fast path (useDefineForClassFields=true AND !experimentalDecorators) 기준.
fn eFast(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return runSemanticPipeline(allocator, source, .{
        .use_define_for_class_fields = true,
        .minify_syntax = true,
    });
}

/// non-fast-path via useDefineForClassFields=false.
fn eAssign(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return runSemanticPipeline(allocator, source, .{
        .use_define_for_class_fields = false,
        .minify_syntax = true,
    });
}

/// non-fast-path via experimentalDecorators=true.
fn eExpDeco(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return runSemanticPipeline(allocator, source, .{
        .experimental_decorators = true,
        .minify_syntax = true,
    });
}

fn eAssignKeepNames(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return runSemanticPipeline(allocator, source, .{
        .use_define_for_class_fields = false,
        .minify_syntax = true,
        .keep_names = true,
    });
}

fn eAssignNoMinify(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return runSemanticPipeline(allocator, source, .{
        .use_define_for_class_fields = false,
        .minify_syntax = false,
    });
}

// ============================================================
// fast path (#1587 회귀 가드)
// ============================================================

test "anonymize fast-path: unreferenced class expression (#1587)" {
    var r = try eFast(std.testing.allocator,
        \\const e = new (class StaleReactionError extends Error {})();
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class StaleReactionError") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "StaleReactionError") == null);
}

test "anonymize fast-path: class declaration never anonymized (#1587)" {
    var r = try eFast(std.testing.allocator,
        \\class Box {}
        \\const x = new Box();
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Box") != null);
}

// ============================================================
// non-fast-path via useDefineForClassFields=false (#1596)
// ============================================================

test "anonymize non-fast-path: unreferenced class expression (#1596)" {
    var r = try eAssign(std.testing.allocator,
        \\const e = new (class StaleReactionError extends Error {
        \\  name = "StaleReactionError";
        \\})();
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class StaleReactionError") == null);
    // property string literal 은 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"StaleReactionError\"") != null);
}

test "anonymize non-fast-path: instance field only → anonymized (#1596)" {
    // instance field 는 constructor 로 이동 → class name 런타임 참조 없음
    var r = try eAssign(std.testing.allocator,
        \\const e = new (class InstField extends Error {
        \\  count = 0;
        \\})();
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "InstField") == null);
}

test "anonymize non-fast-path: static field blocks (#1596)" {
    var r = try eAssign(std.testing.allocator,
        \\const c = class WithStatic extends Error {
        \\  static version = 1;
        \\};
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "WithStatic") != null);
}

test "anonymize non-fast-path: self-reference blocks (#1596)" {
    var r = try eAssign(std.testing.allocator,
        \\const c = class SelfRef {
        \\  static make() { return new SelfRef(); }
        \\};
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "SelfRef") != null);
}

test "anonymize non-fast-path: keep_names disables (#1596)" {
    var r = try eAssignKeepNames(std.testing.allocator,
        \\const c = class KeepMe extends Error {};
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "KeepMe") != null);
}

test "anonymize non-fast-path: minify_syntax=false disables (#1596)" {
    var r = try eAssignNoMinify(std.testing.allocator,
        \\const c = class UnusedName extends Error {};
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "UnusedName") != null);
}

// ============================================================
// non-fast-path via experimentalDecorators=true (#1596)
// ============================================================

test "anonymize non-fast-path: experimental_decorators flag without actual decorators → anonymized (#1596)" {
    var r = try eExpDeco(std.testing.allocator,
        \\const c = class NoDecorator extends Error {};
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "NoDecorator") == null);
}

test "anonymize non-fast-path: class decorator blocks (#1596)" {
    var r = try eExpDeco(std.testing.allocator,
        \\function Log(target: any) { return target; }
        \\const c = @Log class DecoratedClass extends Error {};
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "DecoratedClass") != null);
}

test "anonymize non-fast-path: method decorator blocks (#1596)" {
    var r = try eExpDeco(std.testing.allocator,
        \\function Log(target: any, key: any) {}
        \\const c = class WithMethodDeco {
        \\  @Log method() {}
        \\};
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "WithMethodDeco") != null);
}
