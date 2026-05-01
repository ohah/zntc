//! schema_builder.zig 단위 테스트.
//!
//! 입력 패턴 (TS / Flow):
//!   - 직접 object body
//!   - `Readonly<{...}>` / `$ReadOnly<{...}>` wrapper unwrap
//!   - primitive type, reserved type reference, function type (event)
//!
//! Cross-file type reference 는 의도적 fail-fast → UnresolvedTypeReference (#2348 § 5).

const std = @import("std");
const Scanner = @import("../../../lexer/scanner.zig").Scanner;
const Parser = @import("../../../parser/parser.zig").Parser;
const ast_mod = @import("../../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;

const schema = @import("schema.zig");
const type_index_mod = @import("type_index.zig");
const schema_builder = @import("schema_builder.zig");

const ParseMode = enum { ts, flow };

const Parsed = struct {
    scanner: *Scanner,
    parser: *Parser,
    program: NodeIndex,
    type_index: type_index_mod.TypeIndex,
    alloc: std.mem.Allocator,

    fn deinit(self: *Parsed) void {
        self.type_index.deinit(self.alloc);
        self.parser.deinit();
        self.alloc.destroy(self.parser);
        self.scanner.deinit();
        self.alloc.destroy(self.scanner);
    }
};

fn parseAndIndex(alloc: std.mem.Allocator, source: []const u8, mode: ParseMode) !Parsed {
    const scanner = try alloc.create(Scanner);
    errdefer alloc.destroy(scanner);
    scanner.* = try Scanner.init(alloc, source);
    errdefer scanner.deinit();

    const parser = try alloc.create(Parser);
    errdefer alloc.destroy(parser);
    parser.* = Parser.init(alloc, scanner);
    errdefer parser.deinit();

    switch (mode) {
        .ts => parser.configureFromExtension(".ts"),
        .flow => parser.is_flow = true,
    }
    const program = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);

    const type_index = try type_index_mod.build(&parser.ast, program, alloc);

    return .{
        .scanner = scanner,
        .parser = parser,
        .program = program,
        .type_index = type_index,
        .alloc = alloc,
    };
}

/// `name` 의 declaration NodeIndex 로부터 ComponentShape 빌드. caller 가 프리 free.
fn buildShape(p: *Parsed, type_name: []const u8, component_name: []const u8) !schema.ComponentShape {
    const decl_idx = p.type_index.get(type_name) orelse return error.TypeNotIndexed;
    return schema_builder.build(&p.parser.ast, &p.type_index, component_name, decl_idx, p.alloc);
}

fn freeShape(alloc: std.mem.Allocator, shape: schema.ComponentShape) void {
    alloc.free(shape.props);
    alloc.free(shape.events);
}

test "schema_builder: TS interface with primitive props" {
    var p = try parseAndIndex(std.testing.allocator,
        \\interface NativeProps {
        \\  color: string;
        \\  enabled: boolean;
        \\  count: number;
        \\}
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "NativeProps", "MyComponent");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqualStrings("MyComponent", shape.name);
    try std.testing.expectEqual(@as(usize, 3), shape.props.len);
    try std.testing.expectEqualStrings("color", shape.props[0].name);
    try std.testing.expect(shape.props[0].type_annotation == .string);
    try std.testing.expectEqualStrings("enabled", shape.props[1].name);
    try std.testing.expect(shape.props[1].type_annotation == .boolean);
    try std.testing.expectEqualStrings("count", shape.props[2].name);
    try std.testing.expect(shape.props[2].type_annotation == .float);
}

test "schema_builder: TS type alias with object body" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { name: string };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("name", shape.props[0].name);
}

test "schema_builder: Readonly<{...}> wrapper unwrap (TS)" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = Readonly<{ color: string }>;
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("color", shape.props[0].name);
    try std.testing.expect(shape.props[0].type_annotation == .string);
}

test "schema_builder: $ReadOnly<{...}> wrapper unwrap (Flow inexact)" {
    // 주의: `$ReadOnly<{|...|}>` (exact 안에 generic) 은 Flow 파서가 type argument
    // 의 `|` 를 union 으로 흡수해서 파싱 실패 — RN spec 엔 거의 안 쓰이지만 별개 이슈.
    // 본 테스트는 일반 inexact 케이스만 검증.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = $ReadOnly<{ color: string }>;
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("color", shape.props[0].name);
}

test "schema_builder: ColorValue → reserved.color" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { tint: ColorValue };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expect(shape.props[0].type_annotation == .reserved);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.color, shape.props[0].type_annotation.reserved);
}

test "schema_builder: ImageSource / PointValue / EdgeInsetsValue 매핑" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = {
        \\  src: ImageSource;
        \\  origin: PointValue;
        \\  insets: EdgeInsetsValue;
        \\};
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 3), shape.props.len);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.image_source, shape.props[0].type_annotation.reserved);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.point, shape.props[1].type_annotation.reserved);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.edge_insets, shape.props[2].type_annotation.reserved);
}

test "schema_builder: optional prop sets NamedShape.optional" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { color?: string };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expect(shape.props[0].optional);
}

test "schema_builder: function-typed prop is classified as event" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = {
        \\  color: string;
        \\  onChange: (event: SyntheticEvent) => void;
        \\};
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqual(@as(usize, 1), shape.events.len);
    try std.testing.expectEqualStrings("onChange", shape.events[0].name);
    try std.testing.expectEqual(schema.BubblingType.bubble, shape.events[0].bubbling_type);
}

test "schema_builder: event with `Capture` suffix → direct" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = {
        \\  onChangeCapture: () => void;
        \\};
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.events.len);
    try std.testing.expectEqual(schema.BubblingType.direct, shape.events[0].bubbling_type);
}

test "schema_builder: alias 펼치기 — 같은 파일 type X 를 재귀 매핑" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type MyColor = ColorValue;
        \\type Props = { tint: MyColor };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expect(shape.props[0].type_annotation == .reserved);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.color, shape.props[0].type_annotation.reserved);
}

test "schema_builder: cross-file reference → UnresolvedTypeReference" {
    // ViewProps 가 type_index 에 없음 (실제로는 react-native 에서 import).
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { extra: ViewProps };
    , .ts);
    defer p.deinit();

    const result = buildShape(&p, "Props", "X");
    try std.testing.expectError(error.UnresolvedTypeReference, result);
}

test "schema_builder: alias cycle → UnsupportedPropType (depth limit)" {
    // type A = B; type B = A; — cycle. depth 가드가 발동해야 함 (MAX_ALIAS_DEPTH).
    // 미가드 시 stack overflow.
    var p = try parseAndIndex(std.testing.allocator,
        \\type A = B;
        \\type B = A;
        \\type Props = { x: A };
    , .ts);
    defer p.deinit();

    const result = buildShape(&p, "Props", "X");
    try std.testing.expectError(error.UnsupportedPropType, result);
}

test "schema_builder: invalid declaration → InvalidNativePropsBody" {
    // ts_type_alias 가 아닌 노드 (variable_declaration) 를 native_props_idx 로 줌.
    var p = try parseAndIndex(std.testing.allocator,
        \\const x = 1;
    , .ts);
    defer p.deinit();

    const program_node = p.parser.ast.getNode(p.program);
    const list = program_node.data.list;
    try std.testing.expect(list.len > 0);
    const stmt: NodeIndex = @enumFromInt(p.parser.ast.extra_data.items[list.start]);

    const result = schema_builder.build(&p.parser.ast, &p.type_index, "X", stmt, std.testing.allocator);
    try std.testing.expectError(error.InvalidNativePropsBody, result);
}

test "schema_builder: WithDefault<T, D> wrapper — inner T 만 추출 (TS)" {
    // RN codegen 의 default value wrapper. RN 0.85 코어 spec 40개 중 10개에서 사용.
    // 첫 type 인자만 추출하여 재귀 매핑 — D (default literal) 는 향후 PR.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { disabled: WithDefault<boolean, false> };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("disabled", shape.props[0].name);
    try std.testing.expect(shape.props[0].type_annotation == .boolean);
}

test "schema_builder: WithDefault<Float, 0> → float (Flow)" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { rate: WithDefault<Float, 0> };
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("rate", shape.props[0].name);
    try std.testing.expect(shape.props[0].type_annotation == .float);
}

test "schema_builder: DirectEventHandler<T> → direct event" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { onLayout: DirectEventHandler<LayoutEvent> };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 0), shape.props.len);
    try std.testing.expectEqual(@as(usize, 1), shape.events.len);
    try std.testing.expectEqualStrings("onLayout", shape.events[0].name);
    try std.testing.expectEqual(schema.BubblingType.direct, shape.events[0].bubbling_type);
}

test "schema_builder: BubblingEventHandler<T> → bubble event" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { onChange: BubblingEventHandler<ChangeEvent> };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.events.len);
    try std.testing.expectEqual(schema.BubblingType.bubble, shape.events[0].bubbling_type);
}

test "schema_builder: TS string union → string_enum" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { rate: 'fast' | 'normal' };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expect(shape.props[0].type_annotation == .string_enum);
}

test "schema_builder: TS mixed union → mixed" {
    // string literal 아닌 element 가 섞이면 string_enum 안 되고 mixed.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { fill: ColorValue | string };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expect(shape.props[0].type_annotation == .mixed);
}

test "schema_builder: UnsafeMixed<T> identity unwrap" {
    // react-native-svg 의 `UnsafeMixed<T> = T` identity wrapper. fabric spec 30개
    // 거의 모두 사용. 의미상 T 그대로 → first type arg 만 추출해 재귀.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { color: UnsafeMixed<ColorValue> };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expect(shape.props[0].type_annotation == .reserved);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.color, shape.props[0].type_annotation.reserved);
}

test "schema_builder: Flow nullable ?ColorValue → reserved.color" {
    // RN core spec 에서 매우 흔한 패턴: `tintColor?: ?ColorValue`. nullable wrapper 풀고
    // inner 만 매핑 — RN runtime 의 validAttributes 가 nullable semantics 자체 처리.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { tintColor: ?ColorValue };
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("tintColor", shape.props[0].name);
    try std.testing.expect(shape.props[0].type_annotation == .reserved);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.color, shape.props[0].type_annotation.reserved);
}

test "schema_builder: nullable inside WithDefault — WithDefault<?ColorValue, null>" {
    // RN spec 흔한 조합 — wrapper 안 nullable.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { color: WithDefault<?ColorValue, null> };
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expect(shape.props[0].type_annotation == .reserved);
}

test "schema_builder: ReadonlyArray<ColorValue> → array.reserved.color" {
    // RN core 의 ~10 spec 에서 사용하는 array prop. 예: `colors?: ReadonlyArray<ColorValue>`.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { colors: ReadonlyArray<ColorValue> };
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("colors", shape.props[0].name);
    try std.testing.expect(shape.props[0].type_annotation == .array);
    try std.testing.expect(shape.props[0].type_annotation.array == .reserved);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.color, shape.props[0].type_annotation.array.reserved);
}

test "schema_builder: Array<string> → array.string (TS)" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { tags: Array<string> };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expect(shape.props[0].type_annotation == .array);
    try std.testing.expect(shape.props[0].type_annotation.array == .string);
}

test "schema_builder: WithDefault<ColorValue, null> → reserved.color" {
    // RN 의 nullable color: `WithDefault<?ColorValue, null>` 흔한 패턴.
    // 단순화: nullable 없이 ColorValue 직접 — wrapper 만 검증.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { tint: WithDefault<ColorValue, null> };
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("tint", shape.props[0].name);
    try std.testing.expect(shape.props[0].type_annotation == .reserved);
    try std.testing.expectEqual(schema.ReservedPropPrimitive.color, shape.props[0].type_annotation.reserved);
}
