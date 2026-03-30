//! Arena Allocator 통합 테스트 + OOM 스트레스 테스트
//!
//! 1. Arena 파이프라인: Arena로 전체 파이프라인 실행하여 올바른 출력 확인
//! 2. OOM 시뮬레이션: Scanner.init에서 OOM 시 panic 없이 에러 반환 확인
//! 3. Arena reset 재사용: arena.reset() 후 다른 소스 처리 — 번들러 패턴 검증

const std = @import("std");
const Scanner = @import("lexer/scanner.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const SemanticAnalyzer = @import("semantic/analyzer.zig").SemanticAnalyzer;
const Transformer = @import("transformer/transformer.zig").Transformer;
const Codegen = @import("codegen/codegen.zig").Codegen;

/// Arena allocator로 전체 파이프라인을 실행하고 출력 문자열을 반환한다.
fn runPipeline(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();

    if (parser.errors.items.len > 0) return error.ParseError;

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    analyzer.is_ts = parser.is_ts;
    analyzer.is_flow = parser.is_flow;
    try analyzer.analyze();
    if (analyzer.errors.items.len > 0) return error.SemanticError;

    var transformer = Transformer.init(allocator, &parser.ast, .{});
    const root = try transformer.transform();

    var cg = Codegen.initWithOptions(allocator, &transformer.new_ast, .{ .minify_whitespace = true });
    return try cg.generate(root);
}

// ============================================================
// 1. Arena 파이프라인 테스트
// ============================================================

test "Arena 파이프라인: 기본 변수" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const output = try runPipeline(arena.allocator(), "const x: number = 1;");
    try std.testing.expectEqualStrings("const x=1;", output);
}

test "Arena 파이프라인: 인터페이스 스트리핑" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const output = try runPipeline(arena.allocator(), "interface Foo { bar: string; } const x: Foo = { bar: 'hello' };");
    try std.testing.expectEqualStrings("const x={bar:\"hello\"};", output);
}

test "Arena 파이프라인: 타입 별칭" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const output = try runPipeline(arena.allocator(), "type Point = { x: number; y: number }; const p: Point = { x: 1, y: 2 };");
    try std.testing.expectEqualStrings("const p={x:1,y:2};", output);
}

test "Arena 파이프라인: as/satisfies" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const output = try runPipeline(arena.allocator(), "const x = 'hello' as string; const y = 42 satisfies number;");
    try std.testing.expectEqualStrings("const x=\"hello\";const y=42;", output);
}

test "Arena 파이프라인: 제네릭 함수" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const output = try runPipeline(arena.allocator(), "function identity<T>(value: T): T { return value; }");
    try std.testing.expectEqualStrings("function identity(value){return value;}", output);
}

// ============================================================
// 2. OOM 시뮬레이션 — Scanner.init 실패 테스트
// ============================================================

test "OOM: Scanner init 실패 시 에러 반환 (panic 없음)" {
    var fa = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 0 });
    const result = Scanner.init(fa.allocator(), "const x = 1;");
    try std.testing.expectError(error.OutOfMemory, result);
}

// ============================================================
// 3. Arena reset 재사용 테스트 (번들러 패턴)
// ============================================================

test "Arena reset: 두 번 실행 시 올바른 출력" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // 첫 번째 실행
    const output1 = try runPipeline(arena.allocator(), "const x: number = 1;");
    // Arena 메모리 내 slice → reset 전에 비교
    try std.testing.expectEqualStrings("const x=1;", output1);

    // Arena reset — 모든 메모리 해제, backing 페이지는 재사용
    _ = arena.reset(.retain_capacity);

    // 두 번째 실행 (다른 소스)
    const output2 = try runPipeline(arena.allocator(), "const x = 'hello' as string;");
    try std.testing.expectEqualStrings("const x=\"hello\";", output2);
}
