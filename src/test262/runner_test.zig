const std = @import("std");
const runner = @import("runner.zig");
const parseMetadata = runner.parseMetadata;
const TestSummary = runner.TestSummary;

test "parseMetadata: negative parse test" {
    const source =
        \\// some comment
        \\/*---
        \\negative:
        \\  phase: parse
        \\  type: SyntaxError
        \\---*/
        \\$DONOTEVALUATE();
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(meta.is_negative_parse);
    try std.testing.expectEqualStrings("SyntaxError", meta.negative_type.?);
    try std.testing.expect(!meta.is_module);
}

test "parseMetadata: normal test (no negative)" {
    const source =
        \\/*---
        \\description: basic test
        \\---*/
        \\if (1 !== 1) throw new Test262Error();
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(!meta.is_negative_parse);
    try std.testing.expect(meta.negative_type == null);
}

test "parseMetadata: module flag" {
    const source =
        \\/*---
        \\flags: [module]
        \\---*/
        \\export default 42;
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(meta.is_module);
}

test "parseMetadata: onlyStrict flag" {
    const source =
        \\/*---
        \\flags: [onlyStrict]
        \\---*/
        \\var x = 1;
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(meta.is_only_strict);
    try std.testing.expect(!meta.is_no_strict);
}

test "parseMetadata: multiple flags" {
    const source =
        \\/*---
        \\flags: [module, noStrict]
        \\---*/
        \\export var x = 1;
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(meta.is_module);
    try std.testing.expect(meta.is_no_strict);
}

test "parseMetadata: early phase treated as parse (D055)" {
    const source =
        \\/*---
        \\negative:
        \\  phase: early
        \\  type: SyntaxError
        \\---*/
        \\var x = 1;
    ;
    const meta = parseMetadata(source);
    // early phase는 parse와 동일하게 is_negative_parse = true (D055)
    try std.testing.expect(meta.is_negative_parse);
    try std.testing.expectEqualStrings("SyntaxError", meta.negative_type.?);
}

test "passRate calculation" {
    const summary = TestSummary{
        .total = 100,
        .passed = 80,
        .failed = 10,
        .skipped = 10,
    };
    // 90개 중 80개 통과 = 88.8...%
    try std.testing.expectApproxEqAbs(@as(f64, 88.88), summary.passRate(), 0.1);
}
