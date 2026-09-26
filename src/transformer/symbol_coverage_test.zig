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
const SemanticEditor = @import("../semantic/editor.zig").SemanticEditor;

fn firstHoistedTempSpan(ast: *const @import("../parser/ast.zig").Ast, program_idx: @import("../parser/ast.zig").NodeIndex) @import("../lexer/token.zig").Span {
    const program = ast.getNode(program_idx);
    const declaration = ast.getNode(@enumFromInt(ast.extra_data.items[program.data.list.start]));
    const declarator_start = ast.extra_data.items[declaration.data.extra + 1];
    const declarator = ast.getNode(@enumFromInt(ast.extra_data.items[declarator_start]));
    const binding = ast.getNode(@enumFromInt(ast.extra_data.items[declarator.data.extra]));
    return binding.data.string_ref;
}

test "#4819 temp hoist keeps allocation identity across counter reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "");
    var parser = Parser.init(allocator, &scanner);
    _ = try parser.parse();
    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    const root = try transformer.transform();
    const helpers = @import("es_helpers.zig");

    const first = try helpers.makeTempVarSpan(&transformer);
    const first_body = try transformer.hoistTempVars(root, 0, .EMPTY);
    try std.testing.expectEqual(first.start, firstHoistedTempSpan(transformer.ast, first_body).start);

    // 다른 함수가 끝난 것처럼 counter를 되감으면 출력 이름은 같아도 변수는 다르다.
    transformer.temp_var_counter = 0;
    const second = try helpers.makeTempVarSpan(&transformer);
    // 상태 기계의 이전 temp와 이름만 같은 새 temp를 잘못 제외하면 안 된다.
    const second_body = try transformer.hoistTempVarsSkippingSpans(root, 0, .EMPTY, &.{first});
    try std.testing.expectEqualStrings("_a", transformer.ast.getText(first));
    try std.testing.expectEqualStrings("_a", transformer.ast.getText(second));
    try std.testing.expect(first.start != second.start);
    try std.testing.expectEqual(second.start, firstHoistedTempSpan(transformer.ast, second_body).start);
    const skipped = try transformer.hoistTempVarsSkippingSpans(root, 0, .EMPTY, &.{second});
    try std.testing.expectEqual(root, skipped);
}

test "#4819 function and top-level nullish temps keep separate SymbolIds through deferred hoist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 7; function read() { return null; } function local() { return read() ?? 0; } function local2() { return read() ?? 3; } console.log(read() ?? 1, read() ?? 2, _a);");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 4, edited.symbols.items.len);
    for (edited.symbols.items[original_symbols..], 0..) |generated, offset| {
        try std.testing.expectEqualStrings(if (offset == 3) "_c" else "_b", transformer.ast.getText(generated.name));
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
        const generated_id: u32 = @intCast(original_symbols + offset);
        var bindings: usize = 0;
        var refs: usize = 0;
        for (edited.symbol_ids, 0..) |maybe_id, i| {
            if (maybe_id != generated_id) continue;
            switch (transformer.ast.nodes.items[i].tag) {
                .binding_identifier => bindings += 1,
                .identifier_reference => refs += 1,
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 1), bindings);
        try std.testing.expectEqual(@as(usize, 2), refs);
    }
    try std.testing.expect(edited.symbols.items[original_symbols].scope_id != edited.symbols.items[original_symbols + 1].scope_id);
    try std.testing.expect(edited.symbols.items[original_symbols + 1].scope_id != edited.symbols.items[original_symbols + 2].scope_id);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 optional call captures bind their writes and reads across scopes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 7; const obj = { method: function() { return 3; } }; function get() { return obj; } function f() { return get()?.method?.(); } console.log(get()?.method?.(), f(), _a);");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expect(edited.symbols.items.len >= original_symbols + 4);
    var top_level_count: usize = 0;
    var function_count: usize = 0;
    for (edited.symbols.items[original_symbols..]) |generated| {
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.variable_var, generated.kind);
        try std.testing.expect(generated.reference_count >= 2);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
        if (edited.scopes[generated.scope_id.toIndex()].kind == .function) function_count += 1 else top_level_count += 1;
    }
    try std.testing.expect(top_level_count >= 2);
    try std.testing.expect(function_count >= 2);
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 spread-new callee captures keep distinct function and module symbols" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 7; const holder = { Box: function(x) { this.x = x; } }; function local(v) { return new holder.Box(...[v]); } console.log(new holder.Box(...[8]).x, local(9).x, _a);");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 2, edited.symbols.items.len);
    const local = edited.symbols.items[original_symbols];
    const module = edited.symbols.items[original_symbols + 1];
    try std.testing.expectEqualStrings("_b", transformer.ast.getText(local.name));
    try std.testing.expectEqualStrings("_b", transformer.ast.getText(module.name));
    try std.testing.expect(local.scope_id != module.scope_id);
    for (edited.symbols.items[original_symbols..]) |generated| {
        try std.testing.expectEqual(@as(u32, 2), generated.reference_count);
        try std.testing.expectEqual(@as(u32, 1), generated.write_count);
    }
    try std.testing.expectEqual(@as(usize, 0), transformer.pending_temp_ref_chains.count());
}

test "#4819 transformed scope owners retain their original ScopeId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "function outer() { function inner() { return 1; } return inner(); }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();

    var transformer = try Transformer.init(allocator, &parser.ast, .{});
    transformer.scope_owner_map = analyzer.scope_owner_map;
    _ = try transformer.transform();
    try std.testing.expect(transformer.scope_owner_remaps.count() >= 2);

    var editor = try SemanticEditor.init(
        allocator,
        transformer.ast,
        analyzer.symbols.items,
        analyzer.scopes.items,
        analyzer.scope_maps.items,
        analyzer.scope_owner_map,
        analyzer.references.items,
        analyzer.symbol_ids.items,
    );
    defer editor.deinit();
    var owners = analyzer.scope_owner_map.iterator();
    var first_key: ?u32 = null;
    var second_key: ?u32 = null;
    while (owners.next()) |owner| {
        if (transformer.ast.nodes.items[owner.key_ptr.*].tag != .function_declaration) continue;
        if (first_key == null) first_key = owner.key_ptr.* else second_key = owner.key_ptr.*;
    }
    const first_owner: @import("../parser/ast.zig").NodeIndex = @enumFromInt(first_key.?);
    const second_owner: @import("../parser/ast.zig").NodeIndex = @enumFromInt(second_key.?);
    const first_scope = analyzer.scope_owner_map.get(first_key.?).?;
    const second_scope = analyzer.scope_owner_map.get(second_key.?).?;
    try std.testing.expectError(error.ScopeOwnerConflict, editor.remapScopeOwner(first_owner, second_owner));
    try std.testing.expectEqual(first_scope, editor.scope_owner_map.get(first_key.?).?);
    try std.testing.expectEqual(second_scope, editor.scope_owner_map.get(second_key.?).?);
    const unrelated = try transformer.ast.addNode(.{
        .tag = .identifier_reference,
        .span = .EMPTY,
        .data = .{ .string_ref = try transformer.ast.addString("unrelated") },
    });
    try std.testing.expectError(error.InvalidNode, editor.remapScopeOwner(first_owner, unrelated));
    try std.testing.expectEqual(first_scope, editor.scope_owner_map.get(first_key.?).?);
    var remaps = transformer.scope_owner_remaps.iterator();
    while (remaps.next()) |entry| {
        const old: @import("../parser/ast.zig").NodeIndex = @enumFromInt(entry.key_ptr.*);
        const new: @import("../parser/ast.zig").NodeIndex = @enumFromInt(entry.value_ptr.*);
        const original_scope = analyzer.scope_owner_map.get(entry.key_ptr.*).?;
        try editor.remapScopeOwner(old, new);
        try std.testing.expectEqual(@as(?u32, original_scope), editor.scope_owner_map.get(entry.value_ptr.*));
        try std.testing.expectEqual(@as(?u32, null), editor.scope_owner_map.get(entry.key_ptr.*));
    }
}

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
    transformer.synthetic_idents = .empty;
    const root = try transformer.transform();

    var report = try coverage.check(allocator, transformer.ast, root, transformer.parser_node_count, transformer.symbol_ids.items, analyzer.symbols.items, if (transformer.synthetic_idents) |*s| s else null);
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

test "#4819 generated loop binding and call share one appended SymbolId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator,
        \\export function collect(limit) {
        \\  const _loop = 7;
        \\  const getters = [];
        \\  for (let index = 0; index < limit; index++) getters.push(() => index + _loop);
        \\  return getters;
        \\}
    );
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 1, edited.symbols.items.len);
    const generated_id: u32 = @intCast(original_symbols);
    try std.testing.expectEqualStrings("_loop2", transformer.ast.getText(edited.symbols.items[generated_id].name));
    var bindings: usize = 0;
    var calls: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, i| {
        if (maybe_id != generated_id) continue;
        switch (transformer.ast.nodes.items[i].tag) {
            .binding_identifier => bindings += 1,
            .identifier_reference => calls += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), bindings);
    try std.testing.expect(calls >= 1);
    try std.testing.expectEqual(@as(u32, 1), edited.symbols.items[generated_id].reference_count);
}

test "#4819 optional catch binding gets a symbol in its catch scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scanner = try Scanner.init(allocator, "const _a = 9; try { throw 1; } catch { console.log(_a); } try { throw 2; } catch { console.log(_a); }");
    var parser = Parser.init(allocator, &scanner);
    parser.configureFromExtension(".mjs");
    _ = try parser.parse();
    var analyzer = SemanticAnalyzer.init(allocator, &parser.ast);
    analyzer.is_module = true;
    try analyzer.analyze();
    const original_symbols = analyzer.symbols.items.len;

    var transformer = try Transformer.init(allocator, &parser.ast, .{
        .unsupported = TransformOptions.compat.fromESTarget(.es5),
    });
    try transformer.initSymbolIds(analyzer.symbol_ids.items);
    transformer.symbols = analyzer.symbols.items;
    transformer.references = analyzer.references.items;
    transformer.scopes = analyzer.scopes.items;
    transformer.scope_maps = analyzer.scope_maps.items;
    transformer.scope_owner_map = analyzer.scope_owner_map;
    transformer.semantic_edit_enabled = true;
    _ = try transformer.transform();
    const edited = (try transformer.finishSemanticEdit()).?;
    try std.testing.expectEqual(original_symbols + 2, edited.symbols.items.len);
    try std.testing.expect(edited.symbols.items[original_symbols].scope_id != edited.symbols.items[original_symbols + 1].scope_id);
    for (edited.symbols.items[original_symbols..]) |generated| {
        try std.testing.expectEqual(@import("../semantic/symbol.zig").SymbolKind.catch_binding, generated.kind);
        try std.testing.expectEqual(@import("../semantic/scope.zig").ScopeKind.catch_clause, edited.scopes[generated.scope_id.toIndex()].kind);
        try std.testing.expectEqualStrings("_b", transformer.ast.getText(generated.name));
        try std.testing.expectEqual(@as(u32, 0), generated.reference_count);
    }
    var bindings: usize = 0;
    for (edited.symbol_ids, 0..) |maybe_id, i| {
        if (maybe_id != null and maybe_id.? >= original_symbols and transformer.ast.nodes.items[i].tag == .binding_identifier) bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), bindings);
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

test "#4819 static private initializer this uses the active class symbol" {
    const src =
        \\class A {
        \\  static y = 1;
        \\  static #x = () => this.y;
        \\  static get() { return A.#x(); }
        \\}
        \\function nested() {
        \\  class A {
        \\    static y = 2;
        \\    static #x = () => this.y;
        \\    static get() { return A.#x(); }
        \\  }
        \\  return A.get();
        \\}
        \\console.log(A.get(), nested());
    ;
    for ([_]TransformOptions.compat.ESTarget{ .es5, .es2015, .es2017 }) |target| {
        const c = try countsFor(src, target);
        try std.testing.expectEqual(@as(usize, 0), c.missing);
        try std.testing.expectEqual(@as(usize, 0), c.wrong);
    }
}
