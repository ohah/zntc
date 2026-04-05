//! Fixture 기반 E2E 테스트
//!
//! tests/fixtures/transform/ 디렉토리의 입력 파일을 파싱 → 변환 → 코드젠하여
//! 기대 출력 파일과 비교한다.
//!
//! 파일 명명 규칙:
//!   <name>.input.ts  → TS 소스 (ESM 모드 기본)
//!   <name>.input.tsx → TSX 소스
//!   <name>.expected.js  → 기대 출력 (ESM 모드)
//!   <name>.expected.cjs → 기대 출력 (CJS 모드)
//!
//! 구현 방식: @embedFile로 컴파일 타임에 fixture 파일을 임베드한다.
//! 런타임 파일시스템 접근 없이 빠르게 실행된다.

const std = @import("std");
const Scanner = @import("lexer/scanner.zig").Scanner;
const Parser = @import("parser/parser.zig").Parser;
const Transformer = @import("transformer/transformer.zig").Transformer;
const Codegen = @import("codegen/codegen.zig").Codegen;
const CodegenOptions = @import("codegen/codegen.zig").CodegenOptions;
const ModuleFormat = @import("codegen/codegen.zig").ModuleFormat;

// ============================================================
// E2E 헬퍼
// ============================================================

/// Arena 기반 테스트 결과. deinit()으로 모든 메모리를 일괄 해제.
const TestResult = struct {
    output: []const u8,
    arena: std.heap.ArenaAllocator,

    fn deinit(self: *TestResult) void {
        self.arena.deinit();
    }
};

/// source를 파싱 → 변환 → 코드젠하여 minify된 JS 문자열을 반환한다.
fn runFixture(backing_allocator: std.mem.Allocator, source: []const u8, cg_options: CodegenOptions) !TestResult {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();

    var t = try Transformer.init(allocator, &parser.ast, .{});
    const root = try t.transform();

    var cg = Codegen.initWithOptions(allocator, &t.ast, cg_options);
    const output = try cg.generate(root);

    return .{ .output = output, .arena = arena };
}

/// ESM 모드로 변환 (기본값)
fn runEsm(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return runFixture(allocator, source, .{ .minify = true });
}

/// CJS 모드로 변환
fn runCjs(allocator: std.mem.Allocator, source: []const u8) !TestResult {
    return runFixture(allocator, source, .{ .module_format = .cjs, .minify = true });
}

/// 두 문자열을 비교하고, 불일치 시 diff를 출력한다.
///
/// 간단한 diff: 실제 출력과 기대 출력을 나란히 보여준다.
/// 더 정교한 diff는 현재 미구현 (라인 단위 비교는 fixture 특성상 불필요).
fn expectOutput(actual: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) {
        std.debug.print(
            \\
            \\--- FIXTURE MISMATCH ---
            \\Expected ({d} bytes):
            \\  {s}
            \\Actual ({d} bytes):
            \\  {s}
            \\-----------------------
            \\
        , .{
            expected.len, expected,
            actual.len,   actual,
        });
    }
    try std.testing.expectEqualStrings(expected, actual);
}

// ============================================================
// Fixture 테스트
// ============================================================
//
// 각 테스트는:
//   1. @embedFile로 컴파일 타임에 input과 expected를 임베드
//   2. runEsm / runCjs로 변환 실행
//   3. expectOutput으로 비교
//
// fixture 파일 경로는 src/test_fixtures.zig 기준으로 fixtures/transform/

test "fixture: basic_variable - TS 타입 어노테이션 제거" {
    // const x: number = 1; → const x=1;
    // 타입 어노테이션 `: number`가 제거된다.
    const input = @embedFile("fixtures/transform/basic_variable.input.ts");
    const expected = @embedFile("fixtures/transform/basic_variable.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: enum_iife - enum을 IIFE로 변환" {
    // enum Color { Red, Green, Blue }
    // → var Color;(function(Color){...})(Color||(Color={}));
    // TypeScript enum은 JS에서 IIFE 패턴으로 변환된다.
    const input = @embedFile("fixtures/transform/enum_iife.input.ts");
    const expected = @embedFile("fixtures/transform/enum_iife.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: namespace - namespace를 IIFE로 변환" {
    // namespace Foo { export const x = 1; }
    // → var Foo;(function(Foo){const x=1;Foo.x=x;})(Foo||(Foo={}));
    // export된 멤버는 Foo.x = x 형태로 네임스페이스 객체에 바인딩된다.
    const input = @embedFile("fixtures/transform/namespace.input.ts");
    const expected = @embedFile("fixtures/transform/namespace.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: class_basic - 클래스 메서드 타입 리턴 제거" {
    // class Foo { bar(): string { return 'hello'; } }
    // → class Foo{bar(){return 'hello';}}
    // 메서드의 리턴 타입 어노테이션 `: string`이 제거된다.
    const input = @embedFile("fixtures/transform/class_basic.input.ts");
    const expected = @embedFile("fixtures/transform/class_basic.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: arrow_function - 화살표 함수 minify" {
    // const f = (x) => x + 1;
    // → const f=(x)=>x + 1;
    // 공백이 제거되고 binary expression 연산자 주변 공백은 유지된다.
    const input = @embedFile("fixtures/transform/arrow_function.input.ts");
    const expected = @embedFile("fixtures/transform/arrow_function.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: async_function - async 함수 리턴 타입 제거" {
    // async function fetchData(): Promise<void> { await fetch('/api'); }
    // → async function fetchData(){await fetch('/api');}
    // 리턴 타입 `Promise<void>`가 제거된다.
    const input = @embedFile("fixtures/transform/async_function.input.ts");
    const expected = @embedFile("fixtures/transform/async_function.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: interface_strip - interface 완전 제거" {
    // interface Foo { bar: string; } const x = 1;
    // → const x=1;
    // interface는 JS 런타임에 존재하지 않으므로 완전히 제거된다.
    const input = @embedFile("fixtures/transform/interface_strip.input.ts");
    const expected = @embedFile("fixtures/transform/interface_strip.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: cjs_export - ESM export를 CJS로 변환" {
    // export const x = 1; export default 42;
    // → const x=1;exports.x=x;module.exports=42;
    // CJS 모드에서 named export는 exports.x=x, default export는 module.exports=...
    const input = @embedFile("fixtures/transform/cjs_export.input.ts");
    const expected = @embedFile("fixtures/transform/cjs_export.expected.cjs");

    var r = try runCjs(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: import_esm - ESM import 그대로 유지" {
    // import { foo } from './bar'; foo();
    // → import {foo} from './bar';foo();
    // ESM 모드에서는 import 문이 유지된다 (공백만 minify).
    const input = @embedFile("fixtures/transform/import_esm.input.ts");
    const expected = @embedFile("fixtures/transform/import_esm.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: type_assertions - as/! 타입 단언 제거" {
    // const x = y as number; const z = w!;
    // → const x=y;const z=w;
    // `as number`와 non-null assertion `!`은 런타임에 무의미하므로 제거된다.
    const input = @embedFile("fixtures/transform/type_assertions.input.ts");
    const expected = @embedFile("fixtures/transform/type_assertions.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: decorator - 클래스 데코레이터 유지" {
    // @sealed class Foo {}
    // → @sealed\nclass Foo{}
    // 데코레이터는 JS proposal이므로 그대로 유지되어 출력된다.
    const input = @embedFile("fixtures/transform/decorator.input.ts");
    const expected = @embedFile("fixtures/transform/decorator.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: template_literal - 템플릿 리터럴 그대로 유지" {
    // const s = `hello ${name}`;
    // → const s=`hello ${name}`;
    // 템플릿 리터럴은 ES6+ 문법이므로 그대로 출력된다.
    const input = @embedFile("fixtures/transform/template_literal.input.ts");
    const expected = @embedFile("fixtures/transform/template_literal.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: destructuring - 객체 구조분해 타입 제거" {
    // const { a, b: c }: { a: number; b: string } = obj;
    // → const {a:a,b:c}=obj;
    // 구조분해 패턴의 타입 어노테이션이 제거된다.
    // 단축 프로퍼티 `a`는 `a:a` 형태로 정규화된다.
    const input = @embedFile("fixtures/transform/destructuring.input.ts");
    const expected = @embedFile("fixtures/transform/destructuring.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: spread_rest - 배열 구조분해 + rest 타입 제거" {
    // const [first, ...rest]: number[] = arr;
    // → const [first,...rest]=arr;
    // 배열 타입 어노테이션 `number[]`가 제거된다.
    const input = @embedFile("fixtures/transform/spread_rest.input.ts");
    const expected = @embedFile("fixtures/transform/spread_rest.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}

test "fixture: decorator_member - class member decorator 유지" {
    // @log method(){} → @log\nmethod(){}
    // class member 앞의 decorator가 AST에 연결되어 출력된다.
    const input = @embedFile("fixtures/transform/decorator_member.input.ts");
    const expected = @embedFile("fixtures/transform/decorator_member.expected.js");

    var r = try runEsm(std.testing.allocator, input);
    defer r.deinit();
    try expectOutput(r.output, expected);
}
