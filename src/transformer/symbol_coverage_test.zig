//! 트랜스포머가 새로 만든 사용자 식별자에 심볼 ID 가 빠지지 않는지 (#4760).
//!
//! 단일 파일 minify 는 변환 뒤 코드를 다시 분석해 이름을 짓는다(#4759) — 그래서 심볼 누락이
//! 출력으로는 드러나지 않는다. 대신 블록 스코핑을 심볼 기준으로 바꾸는 #4760 은 변환 **도중**
//! 심볼이 필요하므로, 고친 지점마다 누락 0 을 검사기로 직접 고정한다.

const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;
const transformer_mod = @import("transformer.zig");
const Transformer = transformer_mod.Transformer;
const TransformOptions = transformer_mod.TransformOptions;
const coverage = @import("symbol_coverage.zig");

/// es5 로 변환한 뒤 새로 만든 사용자 식별자 중 심볼이 없는 노드 수.
fn missingSymbols(source: []const u8) !usize {
    return missingSymbolsFor(source, .es5);
}

fn missingSymbolsFor(source: []const u8, target: TransformOptions.compat.ESTarget) !usize {
    return (try countsFor(source, target)).missing;
}

const Counts = struct { missing: usize, wrong: usize };

fn countsFor(source: []const u8, target: TransformOptions.compat.ESTarget) !Counts {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scanner = try Scanner.init(allocator, source);
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();

    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_strict_mode = parser.is_strict_mode;
    analyzer.is_module = parser.is_module;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(target),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    const root = try transformer.transform();

    var report = try coverage.check(allocator, transformer.ast, root, transformer.parser_node_count, transformer.symbol_ids.items, analyzer.symbols.items);
    defer report.deinit(allocator);
    try std.testing.expect(report.new_user_idents > 0);
    return .{ .missing = report.missing.items.len, .wrong = report.wrong.items.len };
}

test "#4762 es5 기본값 매개변수 검사의 참조는 매개변수 심볼을 가진다" {
    try std.testing.expectEqual(@as(usize, 0), try missingSymbols(
        \\export function f(alpha, opts = { k: 2 }) { return alpha + opts.k; }
    ));
}

test "#4760 es5 상태 기계가 대입·선언으로 접은 바인딩은 원래 심볼을 가진다" {
    try std.testing.expectEqual(@as(usize, 0), try missingSymbols(
        \\export function* gen(items) {
        \\  for (const value of items) {
        \\    const doubled = yield value;
        \\    record(doubled);
        \\  }
        \\}
    ));
    // catch 파라미터·블록 구조분해 선언은 이름만 모아 `name$N` 으로 바꾸는 경로로 올라간다.
    try std.testing.expectEqual(@as(usize, 0), try missingSymbols(
        \\export function* gen2(source) {
        \\  try { yield 1; } catch (failure) { record(failure); }
        \\  { const { first, second } = source; yield first; record(second); }
        \\}
    ));
}

test "#4760 es5 루프 캡처 `_loop` 의 매개변수·인자·끌어올린 var 는 원래 심볼을 가진다" {
    try std.testing.expectEqual(@as(usize, 0), try missingSymbols(
        \\export function collect(limit) {
        \\  const getters = [];
        \\  for (let index = 0; index < limit; index++) {
        \\    var latest = index * 2;
        \\    getters.push(() => index + latest);
        \\  }
        \\  return getters;
        \\}
    ));
}

test "#4760 static private 멤버를 낮출 때 만드는 클래스 참조는 클래스 심볼을 가진다" {
    // `Counter.#count` → `__classStaticPrivateFieldSpecGet(Counter, Counter, _count)` 의 클래스
    // 참조는 매핑에 이름만 있어 심볼이 없었다.
    try std.testing.expectEqual(@as(usize, 0), try missingSymbolsFor(
        \\export class Counter {
        \\  static #count = 0;
        \\  static #bump() { return ++Counter.#count; }
        \\  static run(other) { return #count in other ? Counter.#bump() : Counter.#count; }
        \\}
    , .es2020));
}

test "#4760 모듈 최상위 using 이 export 를 지정자로 바꿀 때 로컬 참조는 원래 심볼을 가진다" {
    try std.testing.expectEqual(@as(usize, 0), try missingSymbolsFor(
        \\using handle = open();
        \\export class Service { run() { return handle; } }
        \\export const { first, second } = handle;
        \\export default class Main {}
    , .es2022));
}

test "#4763 es5 클래스의 _super 참조는 부모 클래스 심볼을 갖지 않는다" {
    // es5 는 부모를 IIFE 매개변수 `_super` 로 넘긴다. `super.x()` 를 낮춘 `_super` 참조에 부모
    // 클래스의 심볼이 붙으면, 심볼 기준 리네임이 `_super` 대신 바깥 부모 바인딩을 가리킨다.
    const c = try countsFor(
        \\let Parent = class { hello() { return 'A'; } };
        \\export class Child extends Parent {
        \\  constructor() { super(); }
        \\  run() { return super.hello(); }
        \\  static make() { return super.name; }
        \\}
    , .es5);
    try std.testing.expectEqual(@as(usize, 0), c.wrong);
}

test "#4760 클래스 낮추기가 클래스·함수 이름을 span 으로 가리켜도 원래 심볼을 가진다" {
    // 클래스 이름·정적 메서드 수신자·new.target 함수 이름은 낮추기 함수 사이에 span 으로만
    // 전달된다. 지금 낮추는 클래스(`current_class_name_node`)·함수 노드에서 심볼을 얻는다.
    const src =
        \\export class Counter {
        \\  static #count = 0;
        \\  static total = 1;
        \\  static #bump() { return ++Counter.#count; }
        \\  static run(other) { return #count in other ? Counter.#bump() : Counter.#count + Counter.total; }
        \\}
        \\export const Named = class Inner { static who() { return Inner.name; } static base = 2; };
        \\export class Child extends Counter { static make() { return super.run(this); } }
        \\export function Ctor() { return new.target; }
    ;
    for ([_]TransformOptions.compat.ESTarget{ .es5, .es2015, .es2020 }) |target| {
        const c = try countsFor(src, target);
        try std.testing.expectEqual(@as(usize, 0), c.missing);
        try std.testing.expectEqual(@as(usize, 0), c.wrong);
    }
}
