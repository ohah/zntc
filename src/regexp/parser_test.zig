const std = @import("std");
const parser_mod = @import("parser.zig");
const PatternParser = parser_mod.PatternParser;
const ast = @import("ast.zig");

// ============================================================
// Tests — 검증 모드 (emit_ast=false)
// ============================================================

test "basic patterns" {
    const P = PatternParser(false);
    {
        var p = P.init("abc", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("a|b|c", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("a*b+c?", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "character class" {
    const P = PatternParser(false);
    {
        var p = P.init("[abc]", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("[a-z]", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("[^abc]", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "groups" {
    const P = PatternParser(false);
    {
        var p = P.init("(abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("(?:abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("(?<name>abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "unterminated group" {
    const P = PatternParser(false);
    var p = P.init("(abc", .{});
    try std.testing.expect(p.validate() != null);
}

test "lone quantifier" {
    const P = PatternParser(false);
    {
        var p = P.init("*", .{});
        try std.testing.expect(p.validate() != null);
    }
    {
        var p = P.init("+abc", .{});
        try std.testing.expect(p.validate() != null);
    }
}

test "unicode mode identity escape" {
    const P = PatternParser(false);
    {
        // \M is invalid in unicode mode
        var p = P.init("\\M", .{ .u = true });
        try std.testing.expect(p.validate() != null);
    }
    {
        // \M is valid in non-unicode mode
        var p = P.init("\\M", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "duplicate named group" {
    const P = PatternParser(false);
    var p = P.init("(?<a>x)(?<a>y)", .{});
    try std.testing.expect(p.validate() != null);
}

test "braced quantifier without atom in unicode mode" {
    const P = PatternParser(false);
    var p = P.init("{2,3}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

// ============================================================
// Tests — AST 모드 (emit_ast=true)
// ============================================================

test "#4376 legacy octal escape 는 최대 3 digit (Annex B, 값 ≤ 255)" {
    // `\0777` 은 `\077`(octal 077 = 63) + 리터럴 '7' 이어야 한다(Annex B: 최대 3 octal digit).
    // 수정 전엔 4 digit 전부 소비해 511 로 디코드 → byte 범위 초과 + octal round-trip 깨짐.
    const P = PatternParser(true);
    var p = P.initWithAllocator("\\0777", .{}, std.testing.allocator);
    defer p.deinit();
    const result = p.parse();
    try std.testing.expect(result != null);
    var tree = result.?;
    defer tree.deinit();

    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    // octal atom + 리터럴 '7' = 2 terms (수정 전: 1 term, value 511).
    try std.testing.expectEqual(@as(u32, 2), terms.len);
    const ch0 = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(@as(u32, 0o77), ch0.data[0]); // 63
    const ch1 = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 1]));
    try std.testing.expectEqual(@as(u32, '7'), ch1.data[0]); // literal '7'
}

test "AST: basic literal pattern" {
    // "abc" → Disjunction > Alternative > [Character('a'), Character('b'), Character('c')]
    const P = PatternParser(true);
    var p = P.initWithAllocator("abc", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    try std.testing.expect(tree.nodeCount() > 0);

    // 루트는 disjunction
    const root = tree.getNode(tree.root);
    try std.testing.expectEqual(ast.Tag.disjunction, root.tag);

    // 1개 alternative
    const alts = root.getNodeList();
    try std.testing.expectEqual(@as(u32, 1), alts.len);

    // alternative 안에 3개 character
    const alt_idx: ast.NodeIndex = @enumFromInt(tree.extra_data[alts.start]);
    const alt = tree.getNode(alt_idx);
    try std.testing.expectEqual(ast.Tag.alternative, alt.tag);
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 3), terms.len);

    // 각 character 검증
    const ch0 = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character, ch0.tag);
    try std.testing.expectEqual(@as(u32, 'a'), ch0.data[0]);

    const ch1 = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 1]));
    try std.testing.expectEqual(@as(u32, 'b'), ch1.data[0]);

    const ch2 = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 2]));
    try std.testing.expectEqual(@as(u32, 'c'), ch2.data[0]);
}

test "AST: alternation" {
    // "a|b" → Disjunction > [Alternative('a'), Alternative('b')]
    const P = PatternParser(true);
    var p = P.initWithAllocator("a|b", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    try std.testing.expectEqual(ast.Tag.disjunction, root.tag);

    const alts = root.getNodeList();
    try std.testing.expectEqual(@as(u32, 2), alts.len);
}

test "AST: capturing group" {
    // "(a)" → Disjunction > Alternative > CapturingGroup > Disjunction > Alternative > Character('a')
    const P = PatternParser(true);
    var p = P.initWithAllocator("(a)", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt_idx: ast.NodeIndex = @enumFromInt(tree.extra_data[alts.start]);
    const alt = tree.getNode(alt_idx);
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 1), terms.len);

    // capturing group
    const group = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.capturing_group, group.tag);
    // unnamed: name_start == 0xFFFFFFFF
    try std.testing.expectEqual(std.math.maxInt(u32), group.data[0]);
}

test "AST: named group" {
    // "(?<foo>a)" → CapturingGroup with name
    const P = PatternParser(true);
    var p = P.initWithAllocator("(?<foo>a)", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const group = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.capturing_group, group.tag);
    // name_start != 0xFFFFFFFF (has name)
    try std.testing.expect(group.data[0] != std.math.maxInt(u32));
    // name은 "foo"
    const name = tree.source[group.data[0]..group.data[1]];
    try std.testing.expectEqualStrings("foo", name);
}

test "AST: quantifier" {
    // "a*" → Disjunction > Alternative > Quantifier(min=0, max=unbounded, greedy) > Character('a')
    const P = PatternParser(true);
    var p = P.initWithAllocator("a*", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 1), terms.len);

    const quant = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.quantifier, quant.tag);
    try std.testing.expectEqual(@as(u32, 0), quant.data[0]); // min = 0
    try std.testing.expectEqual(std.math.maxInt(u32), quant.data[1]); // max = unbounded
    try std.testing.expect(quant.isGreedy()); // greedy

    // body는 character
    const body = tree.getNode(quant.getQuantifierBody());
    try std.testing.expectEqual(ast.Tag.character, body.tag);
}

test "AST: lazy quantifier" {
    // "a+?" → Quantifier(min=1, max=unbounded, lazy)
    const P = PatternParser(true);
    var p = P.initWithAllocator("a+?", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const quant = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));

    try std.testing.expectEqual(ast.Tag.quantifier, quant.tag);
    try std.testing.expectEqual(@as(u32, 1), quant.data[0]); // min = 1
    try std.testing.expectEqual(std.math.maxInt(u32), quant.data[1]); // max = unbounded
    try std.testing.expect(!quant.isGreedy()); // lazy
}

test "AST: dot" {
    const P = PatternParser(true);
    var p = P.initWithAllocator(".", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const dot = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.dot, dot.tag);
}

test "AST: character class escape" {
    // "\\d" → CharacterClassEscape(d)
    const P = PatternParser(true);
    var p = P.initWithAllocator("\\d", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const node = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class_escape, node.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.CharacterClassEscapeKind.d)), node.data[0]);
}

test "AST: character class" {
    // "[abc]" → CharacterClass(negative=false) > [Character('a'), Character('b'), Character('c')]
    const P = PatternParser(true);
    var p = P.initWithAllocator("[abc]", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class, cc.tag);
    // not negated
    try std.testing.expectEqual(@as(u32, 0), cc.data[0] & 1);
    // 3 members
    const body = cc.getClassBody();
    try std.testing.expectEqual(@as(u32, 3), body.len);
}

test "AST: character class range" {
    // "[a-z]" → CharacterClass > [CharacterClassRange(a, z)]
    const P = PatternParser(true);
    var p = P.initWithAllocator("[a-z]", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    const body = cc.getClassBody();
    try std.testing.expectEqual(@as(u32, 1), body.len);

    const range = tree.getNode(@enumFromInt(tree.extra_data[body.start]));
    try std.testing.expectEqual(ast.Tag.character_class_range, range.tag);
    // min = 'a', max = 'z'
    const min_ch = tree.getNode(@enumFromInt(range.data[0]));
    const max_ch = tree.getNode(@enumFromInt(range.data[1]));
    try std.testing.expectEqual(@as(u32, 'a'), min_ch.data[0]);
    try std.testing.expectEqual(@as(u32, 'z'), max_ch.data[0]);
}

test "AST: negated character class" {
    // "[^x]" → CharacterClass(negative=true)
    const P = PatternParser(true);
    var p = P.initWithAllocator("[^x]", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class, cc.tag);
    // negated
    try std.testing.expectEqual(@as(u32, 1), cc.data[0] & 1);
}

test "AST: boundary assertion" {
    // "^a$" → [BoundaryAssertion(start), Character('a'), BoundaryAssertion(end)]
    const P = PatternParser(true);
    var p = P.initWithAllocator("^a$", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 3), terms.len);

    const caret = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.boundary_assertion, caret.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.BoundaryAssertionKind.start)), caret.data[0]);

    const dollar = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 2]));
    try std.testing.expectEqual(ast.Tag.boundary_assertion, dollar.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.BoundaryAssertionKind.end)), dollar.data[0]);
}

test "AST: non-capturing group" {
    // "(?:a)" → IgnoreGroup
    const P = PatternParser(true);
    var p = P.initWithAllocator("(?:a)", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const group = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.ignore_group, group.tag);
}

test "AST: indexed reference" {
    // "\\1" → IndexedReference(1)
    const P = PatternParser(true);
    var p = P.initWithAllocator("(a)\\1", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 2), terms.len);

    const ref = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 1]));
    try std.testing.expectEqual(ast.Tag.indexed_reference, ref.tag);
    try std.testing.expectEqual(@as(u32, 1), ref.data[0]);
}

test "AST: lookahead assertion" {
    // "(?=a)" → LookAroundAssertion(lookahead)
    const P = PatternParser(true);
    var p = P.initWithAllocator("(?=a)", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const la = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.lookaround_assertion, la.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.LookAroundAssertionKind.lookahead)), la.data[0]);
}

test "AST: escape characters" {
    // "\\n" → Character(0x0A, single_escape)
    const P = PatternParser(true);
    var p = P.initWithAllocator("\\n", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const ch = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character, ch.tag);
    try std.testing.expectEqual(@as(u32, 0x0A), ch.data[0]);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.CharacterKind.single_escape)), ch.data[1]);
}

test "AST: hex escape" {
    // "\\x41" → Character(0x41, hexadecimal_escape)
    const P = PatternParser(true);
    var p = P.initWithAllocator("\\x41", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const ch = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character, ch.tag);
    try std.testing.expectEqual(@as(u32, 0x41), ch.data[0]);
}

test "AST: braced quantifier" {
    // "a{2,5}" → Quantifier(min=2, max=5, greedy) wrapping Character('a')
    const P = PatternParser(true);
    var p = P.initWithAllocator("a{2,5}", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const quant = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.quantifier, quant.tag);
    try std.testing.expectEqual(@as(u32, 2), quant.data[0]); // min
    try std.testing.expectEqual(@as(u32, 5), quant.data[1]); // max
    try std.testing.expect(quant.isGreedy());
}

test "AST: error returns null" {
    const P = PatternParser(true);
    var p = P.initWithAllocator("(abc", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result == null);
    try std.testing.expect(p.getError() != null);
}

// ============================================================
// Tests — unicode property 검증
// ============================================================

test "unicode property: valid \\p{Lu}" {
    const P = PatternParser(false);
    var p = P.init("\\p{Lu}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "unicode property: valid \\p{gc=Lu}" {
    const P = PatternParser(false);
    var p = P.init("\\p{gc=Lu}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "unicode property: valid \\p{Script=Latin}" {
    const P = PatternParser(false);
    var p = P.init("\\p{Script=Latin}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "unicode property: valid \\p{ASCII}" {
    const P = PatternParser(false);
    var p = P.init("\\p{ASCII}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "unicode property: invalid name" {
    const P = PatternParser(false);
    var p = P.init("\\p{NotAProperty}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "unicode property: invalid gc value" {
    const P = PatternParser(false);
    var p = P.init("\\p{gc=NotACategory}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "unicode property: \\P{Basic_Emoji} negated string property" {
    const P = PatternParser(false);
    // v-flag에서 \P{Basic_Emoji}는 금지
    var p = P.init("\\P{Basic_Emoji}", .{ .v = true });
    try std.testing.expect(p.validate() != null);
}

test "unicode property: \\p{Basic_Emoji} valid with v-flag" {
    const P = PatternParser(false);
    var p = P.init("\\p{Basic_Emoji}", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

// ============================================================
// Tests — codepoint 범위 검증
// ============================================================

test "codepoint: \\u{10FFFF} valid" {
    const P = PatternParser(false);
    var p = P.init("\\u{10FFFF}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "codepoint: \\u{110000} invalid" {
    const P = PatternParser(false);
    var p = P.init("\\u{110000}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "codepoint: \\u{FFFFFF} invalid" {
    const P = PatternParser(false);
    var p = P.init("\\u{FFFFFF}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

// ============================================================
// Tests — character class range 검증
// ============================================================

test "range: [a-z] valid" {
    const P = PatternParser(false);
    var p = P.init("[a-z]", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "range: [z-a] out of order in unicode mode" {
    const P = PatternParser(false);
    var p = P.init("[z-a]", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "range: [z-a] error in non-unicode mode too" {
    const P = PatternParser(false);
    // ECMAScript 22.2.2.9.1: range 순서는 모든 모드에서 에러
    var p = P.init("[z-a]", .{});
    try std.testing.expect(p.validate() != null);
}

test "range: [\\d-x] class escape in range (unicode mode)" {
    const P = PatternParser(false);
    var p = P.init("[\\d-x]", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "range: [a-\\d] class escape in range (unicode mode)" {
    const P = PatternParser(false);
    var p = P.init("[a-\\d]", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "range: [\\d-x] allowed in non-unicode mode" {
    const P = PatternParser(false);
    var p = P.init("[\\d-x]", .{});
    try std.testing.expect(p.validate() == null);
}

// ============================================================
// Tests — v-flag (unicodeSets) character class
// ============================================================

test "v-flag: simple class [abc]" {
    const P = PatternParser(false);
    var p = P.init("[abc]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: intersection [a&&b]" {
    const P = PatternParser(false);
    var p = P.init("[a&&b]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: subtraction [a--b]" {
    const P = PatternParser(false);
    var p = P.init("[a--b]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: nested class [[a-z]&&[A-Z]]" {
    const P = PatternParser(false);
    var p = P.init("[[a-z]&&[A-Z]]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: class string disjunction [\\q{abc|def}]" {
    const P = PatternParser(false);
    var p = P.init("[\\q{abc|def}]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: mixing && and -- is error" {
    const P = PatternParser(false);
    var p = P.init("[a&&b--c]", .{ .v = true });
    try std.testing.expect(p.validate() != null);
}

test "v-flag: triple & is error" {
    const P = PatternParser(false);
    var p = P.init("[a&&&b]", .{ .v = true });
    try std.testing.expect(p.validate() != null);
}

test "v-flag: range [a-z]" {
    const P = PatternParser(false);
    var p = P.init("[a-z]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: range out of order [z-a]" {
    const P = PatternParser(false);
    var p = P.init("[z-a]", .{ .v = true });
    try std.testing.expect(p.validate() != null);
}

test "v-flag: property in class [\\p{ASCII}]" {
    const P = PatternParser(false);
    var p = P.init("[\\p{ASCII}]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag AST: intersection creates correct kind" {
    const P = PatternParser(true);
    var p = P.initWithAllocator("[a&&b]", .{ .v = true }, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);
    var tree = result.?;
    defer tree.deinit();

    // root > alt > character_class
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class, cc.tag);
    // kind bits at data[0] >> 1 = intersection(1)
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.CharacterClassContentsKind.intersection)), (cc.data[0] >> 1) & 3);
}

test "v-flag AST: subtraction creates correct kind" {
    const P = PatternParser(true);
    var p = P.initWithAllocator("[a--b]", .{ .v = true }, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);
    var tree = result.?;
    defer tree.deinit();

    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class, cc.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.CharacterClassContentsKind.subtraction)), (cc.data[0] >> 1) & 3);
}

// ============================================================
// Tests — ES2025 duplicate named groups
// ============================================================

test "ES2025: same name in different alternatives is allowed" {
    const P = PatternParser(false);
    // (?<a>x)|(?<a>y) — different alternatives → OK
    var p = P.init("(?<a>x)|(?<a>y)", .{});
    try std.testing.expect(p.validate() == null);
}

test "ES2025: same name in same alternative is error" {
    const P = PatternParser(false);
    // (?<a>x)(?<a>y) — same alternative → error
    var p = P.init("(?<a>x)(?<a>y)", .{});
    try std.testing.expect(p.validate() != null);
}

test "ES2025: nested different alternatives" {
    const P = PatternParser(false);
    // ((?<a>x)|(?<a>y)) — inner alternatives differ → OK
    var p = P.init("((?<a>x)|(?<a>y))", .{});
    try std.testing.expect(p.validate() == null);
}

test "ES2025: three alternatives" {
    const P = PatternParser(false);
    // (?<n>a)|(?<n>b)|(?<n>c) → all different alternatives → OK
    var p = P.init("(?<n>a)|(?<n>b)|(?<n>c)", .{});
    try std.testing.expect(p.validate() == null);
}

// ============================================================
// Tests — pre-parse + forward reference
// ============================================================

test "pre-parse: forward back reference valid" {
    const P = PatternParser(false);
    // \1(a) — forward reference to group 1 (defined after reference)
    var p = P.init("\\1(a)", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "pre-parse: back reference exceeds groups" {
    const P = PatternParser(false);
    // \2(a) — only 1 group, reference to 2 is error in unicode mode
    var p = P.init("\\2(a)", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "pre-parse: multiple groups valid" {
    const P = PatternParser(false);
    // (a)(b)\1\2 — 2 groups, references 1 and 2 are valid
    var p = P.init("(a)(b)\\1\\2", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

// ── Bug fix tests ──

test "bug1: \\b in character class is backspace (U+0008)" {
    const P = PatternParser(false);
    // [\b] is valid — \b means backspace inside character class
    var p1 = P.init("[\\b]", .{ .u = true });
    try std.testing.expect(p1.validate() == null);

    var p2 = P.init("[\\b]", .{});
    try std.testing.expect(p2.validate() == null);

    var p3 = P.init("[\\b]", .{ .v = true });
    try std.testing.expect(p3.validate() == null);
}

test "bug2: negated class with string property is error in v-flag" {
    const P = PatternParser(false);
    // [^\p{Basic_Emoji}]/v → SyntaxError
    var p1 = P.init("[^\\p{Basic_Emoji}]", .{ .v = true });
    try std.testing.expect(p1.validate() != null);

    // [\p{Basic_Emoji}]/v → valid (not negated)
    var p2 = P.init("[\\p{Basic_Emoji}]", .{ .v = true });
    try std.testing.expect(p2.validate() == null);

    // [^\p{Emoji_Keycap_Sequence}]/v → SyntaxError
    var p3 = P.init("[^\\p{Emoji_Keycap_Sequence}]", .{ .v = true });
    try std.testing.expect(p3.validate() != null);

    // [^\p{RGI_Emoji}]/v → SyntaxError
    var p4 = P.init("[^\\p{RGI_Emoji}]", .{ .v = true });
    try std.testing.expect(p4.validate() != null);

    // [^\q{abc}]/v → SyntaxError (string disjunction)
    var p5 = P.init("[^\\q{abc}]", .{ .v = true });
    try std.testing.expect(p5.validate() != null);
}

test "bug3: \\k<name> without named group in non-unicode is identity escape" {
    const P = PatternParser(false);
    // /\k<x>/ (non-unicode, no named groups) → valid per Annex B
    var p1 = P.init("\\k<x>", .{});
    try std.testing.expect(p1.validate() == null);

    // /\k<x>/u (unicode) → error (must have named group)
    var p2 = P.init("\\k<x>", .{ .u = true });
    try std.testing.expect(p2.validate() != null);

    // /\k<x>(?<x>a)/ (non-unicode, named group exists) → valid
    var p3 = P.init("\\k<x>(?<x>a)", .{});
    try std.testing.expect(p3.validate() == null);

    // /\k<y>(?<x>a)/ (non-unicode, named group exists but wrong name) → error
    var p4 = P.init("\\k<y>(?<x>a)", .{});
    try std.testing.expect(p4.validate() != null);
}

// ============================================================
// Tests — #3501: named-group/backref 버퍼 동적화
// (고정 [16]/[32] 가 유효한 17개+ named group / 33개+ backref 정규식을
//  오거부하던 버그. #1475 PR2 의 #2472(50 named) blocker.)
// ============================================================

/// `(?<n0>a)(?<n1>a)...(?<n{count-1}>a)` 패턴을 빌드.
fn buildNamedGroups(alloc: std.mem.Allocator, count: u32, with_last_backref: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var i: u32 = 0;
    while (i < count) : (i += 1) try buf.print(alloc, "(?<n{d}>a)", .{i});
    if (with_last_backref) try buf.print(alloc, "\\k<n{d}>", .{count - 1});
    return buf.toOwnedSlice(alloc);
}

test "#3501 validate: 17/50/100 distinct named groups accepted" {
    const a = std.testing.allocator;
    const P = PatternParser(false);
    for ([_]u32{ 17, 50, 100 }) |count| {
        const pat = try buildNamedGroups(a, count, false);
        defer a.free(pat);
        var p = P.init(pat, .{});
        p.ext_alloc = a; // 렉서는 scanner.allocator 를 mod.validate 로 주입
        try std.testing.expect(p.validate() == null);
    }
}

test "#3501 AST: 50 named groups + trailing backref parses (#2472)" {
    const a = std.testing.allocator;
    const pat = try buildNamedGroups(a, 50, true);
    defer a.free(pat);
    const P = PatternParser(true);
    var p = P.initWithAllocator(pat, .{}, a);
    defer p.deinit();
    var tree = p.parse() orelse return error.ParseFailed;
    defer tree.deinit();
    try std.testing.expect(tree.nodeCount() > 50);
}

test "#3501 correctness: duplicate name past inline cap still errors" {
    const a = std.testing.allocator;
    // 20개 그룹, 같은 alternative 에서 이름 `n3` 중복 → 16 초과 후에도 dup 검출 유지.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const nm: u32 = if (i == 19) 3 else i; // 마지막을 n3 으로 → n3 중복
        try buf.print(a, "(?<n{d}>a)", .{nm});
    }
    const P = PatternParser(false);
    var p = P.init(buf.items, .{});
    p.ext_alloc = a;
    try std.testing.expect(p.validate() != null);
}

test "#3501 validate: 40 named backrefs accepted (>[32] cap)" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var i: u32 = 0;
    while (i < 40) : (i += 1) try buf.print(a, "(?<n{d}>a)\\k<n{d}>", .{ i, i });
    const P = PatternParser(false);
    var p = P.init(buf.items, .{});
    p.ext_alloc = a;
    try std.testing.expect(p.validate() == null);
}

// ============================================================
// #3503: mod.parse 에러 경로에서 ast_nodes/ast_extra 미해제 누수
// ============================================================

test "#3503 mod.parse: 문법 에러 정규식 누수 없음" {
    const mod = @import("mod.zig");
    // flag 는 유효(flag 검증 통과) 하나 패턴이 문법 에러 →
    // parse() 가 ast 빌드 도중 err → null 반환. testing.allocator 가
    // ast_nodes/ast_extra 미해제 시 누수 패닉.
    for ([_][]const u8{ "(", "(?<n>", "[a-", "\\", "a{2,1}", "(?<n>a)(?<n>b)" }) |pat| {
        try std.testing.expect(mod.parse(pat, "", std.testing.allocator) == null);
    }
    // 성공 경로도 누수 0 (toOwnedSlice 후 p.deinit no-op 검증).
    var ok = mod.parse("(a)\\1", "", std.testing.allocator) orelse return error.ParseFailed;
    ok.deinit();
}
