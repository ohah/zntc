//! validator.zig 단위 테스트.

const std = @import("std");
const schema = @import("schema.zig");
const validator = @import("validator.zig");
const Code = @import("../../../error_codes.zig").Code;

test "validator: empty schema → null" {
    const cs: schema.ComponentSchema = .{ .components = &.{} };
    try std.testing.expect(validator.validate(cs) == null);
}

test "validator: single component → null" {
    const cs: schema.ComponentSchema = .{ .components = &[_]schema.ComponentShape{
        .{ .name = "MyView", .props = &.{}, .events = &.{} },
    } };
    try std.testing.expect(validator.validate(cs) == null);
}

test "validator: distinct component names → null" {
    const cs: schema.ComponentSchema = .{ .components = &[_]schema.ComponentShape{
        .{ .name = "View", .props = &.{}, .events = &.{} },
        .{ .name = "Text", .props = &.{}, .events = &.{} },
        .{ .name = "Image", .props = &.{}, .events = &.{} },
    } };
    try std.testing.expect(validator.validate(cs) == null);
}

test "validator: duplicate component name → returns first conflict" {
    const cs: schema.ComponentSchema = .{
        .components = &[_]schema.ComponentShape{
            .{ .name = "View", .props = &.{}, .events = &.{} },
            .{ .name = "Text", .props = &.{}, .events = &.{} },
            .{ .name = "View", .props = &.{}, .events = &.{} }, // 중복
        },
    };
    const dup = validator.validate(cs);
    try std.testing.expect(dup != null);
    try std.testing.expectEqualStrings("View", dup.?);
}

test "validator: error code mapping — schema_builder errors" {
    try std.testing.expectEqual(
        Code.codegen_unresolved_type_reference,
        validator.schemaBuilderErrorCode(error.UnresolvedTypeReference),
    );
    try std.testing.expectEqual(
        Code.codegen_unsupported_prop_type,
        validator.schemaBuilderErrorCode(error.UnsupportedPropType),
    );
    try std.testing.expectEqual(
        Code.codegen_invalid_native_props_body,
        validator.schemaBuilderErrorCode(error.InvalidNativePropsBody),
    );
}

test "validator: error codes resolve to ZTS1400 series" {
    try std.testing.expectEqualStrings("ZTS1400", Code.codegen_unresolved_type_reference.format());
    try std.testing.expectEqualStrings("ZTS1401", Code.codegen_unsupported_prop_type.format());
    try std.testing.expectEqualStrings("ZTS1402", Code.codegen_invalid_native_props_body.format());
    try std.testing.expectEqualStrings("ZTS1403", Code.codegen_duplicate_component.format());
}
