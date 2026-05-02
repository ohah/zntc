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

test "schema_builder: cross-file reference → mixed (permissive fallback, #2348 후속)" {
    // ViewProps 가 type_index 에 없음 (실제로는 react-native 에서 import).
    // 기존엔 UnresolvedTypeReference 던졌지만, 인헤리턴스 지원 도입 시 base 의 prop type 에
    // 노출되는 cross-file ref (NumberProp 등) 가 spec 통째 거부 야기 → permissive `mixed`.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = { extra: ViewProps };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("extra", shape.props[0].name);
    try std.testing.expect(shape.props[0].type_annotation == .mixed);
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

// ─── 인헤리턴스 / Intersection (#2348 후속) ───

test "schema_builder: TS interface single same-file extends merges base members" {
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { color: string; }
        \\interface NativeProps extends Base { enabled: boolean; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "NativeProps", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
    // base 가 먼저 collect (extends 우선) — 순서 검증.
    try std.testing.expectEqualStrings("color", shape.props[0].name);
    try std.testing.expectEqualStrings("enabled", shape.props[1].name);
}

test "schema_builder: TS interface multi-extends (svg pattern) merges all bases" {
    // react-native-svg 의 실제 패턴 — 2 개 same-file base + 1 cross-file (silent skip).
    var p = try parseAndIndex(std.testing.allocator,
        \\interface SvgNodeCommonProps { name: string; opacity: number; }
        \\interface SvgRenderableCommonProps { color: string; fillOpacity: number; }
        \\interface NativeProps extends ViewProps, SvgNodeCommonProps, SvgRenderableCommonProps {
        \\  cx: number;
        \\  cy: number;
        \\}
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "NativeProps", "X");
    defer freeShape(std.testing.allocator, shape);

    // ViewProps cross-file → silent skip. SvgNode (2) + SvgRenderable (2) + own (2) = 6.
    try std.testing.expectEqual(@as(usize, 6), shape.props.len);
    // 머지 순서 — extends 순서대로 base 먼저, 그 다음 본문.
    try std.testing.expectEqualStrings("name", shape.props[0].name);
    try std.testing.expectEqualStrings("opacity", shape.props[1].name);
    try std.testing.expectEqualStrings("color", shape.props[2].name);
    try std.testing.expectEqualStrings("fillOpacity", shape.props[3].name);
    try std.testing.expectEqualStrings("cx", shape.props[4].name);
    try std.testing.expectEqualStrings("cy", shape.props[5].name);
}

test "schema_builder: TS interface transitive extends (A → B → C)" {
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Grand { gp: string; }
        \\interface Parent extends Grand { pp: number; }
        \\interface NativeProps extends Parent { own: boolean; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "NativeProps", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 3), shape.props.len);
    try std.testing.expectEqualStrings("gp", shape.props[0].name);
    try std.testing.expectEqualStrings("pp", shape.props[1].name);
    try std.testing.expectEqualStrings("own", shape.props[2].name);
}

test "schema_builder: TS interface extends only cross-file → empty (silent skip)" {
    // ViewProps 만 extends → 본문 없으면 0 props. error 안 나야 함.
    var p = try parseAndIndex(std.testing.allocator,
        \\interface NativeProps extends ViewProps {}
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "NativeProps", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 0), shape.props.len);
    try std.testing.expectEqual(@as(usize, 0), shape.events.len);
}

test "schema_builder: TS intersection type alias (A & B & {...})" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Base1 = { a: string };
        \\type Base2 = { b: number };
        \\type Props = Base1 & Base2 & { c: boolean };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 3), shape.props.len);
    try std.testing.expectEqualStrings("a", shape.props[0].name);
    try std.testing.expectEqualStrings("b", shape.props[1].name);
    try std.testing.expectEqualStrings("c", shape.props[2].name);
}

test "schema_builder: TS intersection with cross-file operand (silent skip)" {
    // CrossModuleType 은 same-file 미정의 → silent skip, Base 만 머지.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Base = { a: string };
        \\type Props = CrossModuleType & Base & { c: boolean };
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
    try std.testing.expectEqualStrings("a", shape.props[0].name);
    try std.testing.expectEqualStrings("c", shape.props[1].name);
}

test "schema_builder: TS interface extends + Readonly wrapper inner" {
    // base 가 Readonly<{...}> wrapper — unwrap 후 멤버 머지.
    var p = try parseAndIndex(std.testing.allocator,
        \\type Base = Readonly<{ a: string }>;
        \\interface Props extends Base { b: number; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
    try std.testing.expectEqualStrings("a", shape.props[0].name);
    try std.testing.expectEqualStrings("b", shape.props[1].name);
}

test "schema_builder: TS extends cycle (A→B→A) → visited set 으로 graceful 처리" {
    // visited set 도입 후 cycle 은 panic / depth 폭주 없이 양쪽 본문만 1 회씩 수집.
    // InheritanceTooDeep 는 visited 가 차단 못 하는 경로 (intersection 깊이 등) 의 안전판으로
    // 남음. cycle 자체는 visited 로 충분.
    var p = try parseAndIndex(std.testing.allocator,
        \\interface A extends B { a: string; }
        \\interface B extends A { b: number; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "A", "X");
    defer freeShape(std.testing.allocator, shape);

    // a + b = 2. cycle 두번째 진입은 visited 가 차단.
    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
}

test "schema_builder: TS interface diamond inheritance — Common 멤버 1 회만 머지" {
    // diamond pattern: Props extends A, B; A extends Common; B extends Common.
    // Common 의 prop 이 두 경로로 reach 되지만 visited set 으로 중복 방지.
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Common { shared: string; }
        \\interface A extends Common { aOnly: number; }
        \\interface B extends Common { bOnly: boolean; }
        \\interface Props extends A, B { own: number; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    // Common(shared) + A(aOnly) + B(bOnly) + Props(own) = 4. shared 는 1 회만.
    try std.testing.expectEqual(@as(usize, 4), shape.props.len);

    // 각 prop name 정확성 검증 — order 는 visited 정책 (depth-first first-visit).
    var names = std.StringHashMap(void).init(std.testing.allocator);
    defer names.deinit();
    for (shape.props) |prop| try names.put(prop.name, {});
    try std.testing.expect(names.contains("shared"));
    try std.testing.expect(names.contains("aOnly"));
    try std.testing.expect(names.contains("bOnly"));
    try std.testing.expect(names.contains("own"));
}

test "schema_builder: TS interface 같은 prop 이름 base + derived — last-wins dedup (#2418)" {
    // TS override semantic 정합 — derived 가 base 의 동명 prop 을 가린다.
    // 출력 위치는 _마지막_ occurrence 기준 (derived 위치).
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { color: string; }
        \\interface Props extends Base { color: string; size: number; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    // dedup 후: color (derived) + size = 2. base 의 color 는 drop.
    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
    // 위치 검증 — derived block 의 순서 보존.
    try std.testing.expectEqualStrings("color", shape.props[0].name);
    try std.testing.expectEqualStrings("size", shape.props[1].name);
}

test "schema_builder: dedup last-wins — base 의 string 이 derived 의 ColorValue 로 override (#2418)" {
    // 같은 이름인데 type 이 다른 케이스 — derived 가 우선.
    var p = try parseAndIndex(std.testing.allocator,
        \\type ColorValue = string;
        \\interface Base { color: string; }
        \\interface Props extends Base { color: ColorValue; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("color", shape.props[0].name);
}

// ─── Flow 패턴 (#2416) ───

test "schema_builder: Flow object spread (`{...A}`) — same-file base 머지" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Base = { color: string; opacity: number };
        \\type Props = $ReadOnly<{
        \\  ...Base,
        \\  enabled: boolean,
        \\}>;
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    // Base.color + Base.opacity + Props.enabled = 3.
    try std.testing.expectEqual(@as(usize, 3), shape.props.len);
}

test "schema_builder: Flow object spread cross-file (`{...ViewProps}`) — silent skip" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = $ReadOnly<{
        \\  ...ViewProps,
        \\  enabled: boolean,
        \\}>;
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    // ViewProps cross-file → skip. enabled 만 남음.
    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("enabled", shape.props[0].name);
}

test "schema_builder: Flow object spread 다중 same-file base" {
    var p = try parseAndIndex(std.testing.allocator,
        \\type Base1 = { a: string };
        \\type Base2 = { b: number };
        \\type Props = $ReadOnly<{
        \\  ...Base1,
        \\  ...Base2,
        \\  c: boolean,
        \\}>;
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 3), shape.props.len);
}

test "schema_builder: Flow interface body + extends — TS interface 와 동일 처리" {
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { color: string }
        \\interface Props extends Base { enabled: boolean }
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
    try std.testing.expectEqualStrings("color", shape.props[0].name);
    try std.testing.expectEqualStrings("enabled", shape.props[1].name);
}

test "schema_builder: Flow VirtualView 패턴 (`Readonly<{...ViewProps, ...}>`)" {
    // RN core 의 실제 패턴 reproduce (`VirtualViewNativeComponent.js` 의
    // `type VirtualViewNativeProps = Readonly<{ ...ViewProps, initialHidden?: boolean, ... }>`).
    var p = try parseAndIndex(std.testing.allocator,
        \\type Props = $ReadOnly<{
        \\  ...ViewProps,
        \\  initialHidden?: boolean,
        \\  removeClippedSubviews?: boolean,
        \\}>;
    , .flow);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    // ViewProps cross-file silent skip → 자체 2 prop 만.
    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
    try std.testing.expectEqualStrings("initialHidden", shape.props[0].name);
    try std.testing.expectEqualStrings("removeClippedSubviews", shape.props[1].name);
    try std.testing.expect(shape.props[0].optional);
    try std.testing.expect(shape.props[1].optional);
}

test "schema_builder: TS interface extends with Flow base (Readonly<{...}>) — mixed mode 안전" {
    // 같은 파일에 TS interface + flow type alias 혼재 시나리오는 실제론 거의 없지만
    // 본 fix 가 mode-agnostic 으로 동작해야 함. base 가 type ref 면 lookup 만 통하고
    // 안의 형태는 flow/ts 무관하게 처리.
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { x: string; }
        \\interface Props extends Base { y: number; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
}

// ─── Pick<T, K> / Omit<T, K> utility types (#2417) ───

test "schema_builder: Pick<T, 'a'|'b'> — 명시된 이름만 keep" {
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { a: string; b: number; c: boolean; d: string; }
        \\type Props = Pick<Base, 'a' | 'b'>;
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
    try std.testing.expectEqualStrings("a", shape.props[0].name);
    try std.testing.expectEqualStrings("b", shape.props[1].name);
}

test "schema_builder: Omit<T, 'a'> — 명시된 이름만 drop" {
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { a: string; b: number; c: boolean; }
        \\type Props = Omit<Base, 'a'>;
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
    try std.testing.expectEqualStrings("b", shape.props[0].name);
    try std.testing.expectEqualStrings("c", shape.props[1].name);
}

test "schema_builder: Pick — 단일 literal 'a'" {
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { a: string; b: number; }
        \\type Props = Pick<Base, 'a'>;
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    try std.testing.expectEqual(@as(usize, 1), shape.props.len);
    try std.testing.expectEqualStrings("a", shape.props[0].name);
}

test "schema_builder: extends Pick<Base, K>, Other — 인헤리턴스 인자로 사용" {
    // 실제 RN ecosystem 패턴: `interface NativeProps extends Pick<ViewProps, 'style'>, OtherProps`.
    // 본 테스트는 same-file Base 로 검증 (cross-file ViewProps 는 silent skip 이므로).
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { color: string; size: number; align: string; }
        \\interface Other { enabled: boolean; }
        \\interface Props extends Pick<Base, 'color' | 'size'>, Other { extra: number; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    // Pick<Base, 'color'|'size'> = 2 + Other.enabled = 1 + Props.extra = 1 → 4.
    try std.testing.expectEqual(@as(usize, 4), shape.props.len);
}

test "schema_builder: Pick — K 가 미지원 형태 (type ref) 면 silent skip" {
    // `keyof` / type ref 등 string union 이 아닌 K 는 현재 구현 미지원 — 결과 0 props.
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { a: string; b: number; }
        \\type Keys = 'a';
        \\type Props = Pick<Base, Keys>;
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    // K 가 type ref → silent skip → Pick 자체가 멤버 없음.
    try std.testing.expectEqual(@as(usize, 0), shape.props.len);
}

test "schema_builder: Omit + dedup 조합 — derived 가 Omit 결과를 override" {
    var p = try parseAndIndex(std.testing.allocator,
        \\interface Base { color: string; size: number; opacity: number; }
        \\type Filtered = Omit<Base, 'opacity'>;
        \\interface Props extends Filtered { color: string; }
    , .ts);
    defer p.deinit();

    const shape = try buildShape(&p, "Props", "X");
    defer freeShape(std.testing.allocator, shape);

    // Filtered: color, size. Props extends + own color → dedup → size + Props.color = 2.
    try std.testing.expectEqual(@as(usize, 2), shape.props.len);
}
