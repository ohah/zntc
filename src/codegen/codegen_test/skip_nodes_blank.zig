//! #1602 회귀 테스트: skip_nodes로 마킹된 statement가 빈 줄을 남기지 않는지 검증.
//!
//! 버그: emitProgram/emitBracedList가 emitNode 호출 전에 newline/indent를 먼저 쓰므로,
//! emitNode가 skip_nodes로 early return하면 해당 slot에 빈 줄이 남았다.
//! 수정: newline/indent 쓰기 전에 `isSkipped`로 사전 체크 → slot 전체를 건너뜀.

const std = @import("std");
const helpers = @import("helpers.zig");
const Codegen = helpers.Codegen;
const Scanner = helpers.Scanner;
const Parser = helpers.Parser;
const Transformer = helpers.Transformer;
const LinkingMetadata = @import("../../bundler/linker.zig").LinkingMetadata;
const Ast = @import("../../parser/ast.zig").Ast;

/// 소스를 파싱/트랜스폼 후 지정한 substring으로 시작하는 statement를 skip_nodes에 마킹하고
/// codegen을 돌려 출력을 반환한다.
fn codegenWithSkippedStatements(
    backing: std.mem.Allocator,
    source: []const u8,
    skip_substrs: []const []const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();

    var scanner = try Scanner.init(a, source);
    var parser = Parser.init(a, &scanner);
    _ = try parser.parse();

    var t = try Transformer.init(a, &parser.ast, .{});
    const root = try t.transform();

    var skip = try std.DynamicBitSet.initEmpty(a, t.ast.nodes.items.len);
    for (skip_substrs) |needle| {
        const pos = std.mem.indexOf(u8, source, needle) orelse continue;
        const start: u32 = @intCast(pos);
        for (t.ast.nodes.items, 0..) |n, i| {
            // program statement list의 top-level 노드(대부분 variable_declaration / function_declaration)
            // 에서 시작 위치가 일치하는 것을 전부 마킹 — transformer가 clone한 노드까지 커버.
            if (n.span.start == start) skip.set(i);
        }
    }

    var md: LinkingMetadata = .{
        .skip_nodes = skip,
        .renames = std.AutoHashMap(u32, []const u8).init(a),
        .final_exports = null,
        .symbol_ids = &.{},
        .allocator = a,
    };

    var cg = Codegen.initWithOptions(a, &t.ast, .{ .linking_metadata = &md });
    const out = try cg.generate(root);
    return backing.dupe(u8, out);
}

test "skip_nodes 회귀 (#1602): program level에서 skip된 선언이 빈 줄 남기지 않음" {
    const source =
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
    ;
    const out = try codegenWithSkippedStatements(std.testing.allocator, source, &.{"const b = 2;"});
    defer std.testing.allocator.free(out);

    // b가 skip되었으므로 "const b" 출력에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, out, "const b") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const a = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const c = 3") != null);

    // 빈 줄 없음 — 이전 버그는 "const a=1;\n\nconst c=3;" 형태로 출력
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n") == null);
}

test "skip_nodes 회귀 (#1602): 여러 연속 skip도 빈 줄 미발생" {
    const source =
        \\const a = 1;
        \\const b = 2;
        \\const c = 3;
        \\const d = 4;
    ;
    const out = try codegenWithSkippedStatements(
        std.testing.allocator,
        source,
        &.{ "const b = 2;", "const c = 3;" },
    );
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "const b") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "const c") == null);
    // 연속 2개 skip이어도 두 줄 공백이 남지 않음
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n") == null);
}

test "skip_nodes 회귀 (#1602): block statement 내부 skip도 빈 줄 미발생" {
    const source =
        \\function f() {
        \\  const a = 1;
        \\  const b = 2;
        \\  const c = 3;
        \\}
    ;
    const out = try codegenWithSkippedStatements(
        std.testing.allocator,
        source,
        &.{"const b = 2;"},
    );
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "const b") == null);
    // block 내부에서도 연속 빈 줄 발생 안 함 (들여쓰기 포함 `\n\t\n` 형태도 체크)
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\t\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n") == null);
}
