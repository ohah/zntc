const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const es_helpers = @import("es_helpers.zig");

test "private helper names share IdentifierName StringValue reservations" {
    const allocator = std.testing.allocator;
    var scanner = try Scanner.init(allocator,
        \\const _a = 1;
        \\const _\u0062 = 2;
        \\class Box { #\u0061 = _a; }
        \\class Pair { get #\u0062() {} set #b(value) {} }
    );
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    var private_names = try es_helpers.PrivateNameAllocator.init(allocator, &parser.ast);
    defer private_names.deinit();

    const field_name = try private_names.makePrivateVarName("#\\u0061");
    defer allocator.free(field_name);
    try std.testing.expectEqualStrings("_\\u00612", field_name);

    const escaped_source_collision = try private_names.makePrivateVarName("#b");
    defer allocator.free(escaped_source_collision);
    try std.testing.expectEqualStrings("_b2", escaped_source_collision);

    const getter = try private_names.makePrivateMethodNames("#\\u0062", .getter);
    defer allocator.free(getter.ws_name);
    defer allocator.free(getter.fn_name);
    const setter = try private_names.makePrivateMethodNames("#b", .setter);
    defer allocator.free(setter.ws_name);
    defer allocator.free(setter.fn_name);
    try std.testing.expectEqualStrings(getter.ws_name, setter.ws_name);
}
