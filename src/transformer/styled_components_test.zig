//! styled-components 1st-party transform 회귀 테스트.

const std = @import("std");
const helpers = @import("../codegen/codegen_test/helpers.zig");
const e2eFull = helpers.e2eFull;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;

const default_cg: CodegenOptions = .{ .minify_whitespace = false };

/// 출력에 `withConfig({ displayName: ...<expected> })` + componentId 패턴이 나타나는지 검증.
/// fileName 옵션 (default true) 으로 displayName 에 `<basename>__` prefix 가 붙거나
/// 안 붙거나 양쪽 다 허용 — 본 테스트의 의도는 wrap 메커니즘 검증이라 형식 디테일은
/// fileName 전용 테스트가 따로 검증.
fn expectDisplayName(output: []const u8, expected: []const u8) !void {
    var direct_buf: [256]u8 = undefined;
    const direct = std.fmt.bufPrint(&direct_buf, "displayName: \"{s}\"", .{expected}) catch return error.OutOfMemory;
    var prefixed_buf: [256]u8 = undefined;
    const prefixed_suffix = std.fmt.bufPrint(&prefixed_buf, "__{s}\"", .{expected}) catch return error.OutOfMemory;
    const has_direct = std.mem.indexOf(u8, output, direct) != null;
    const has_prefixed = std.mem.indexOf(u8, output, prefixed_suffix) != null;
    try std.testing.expect(has_direct or has_prefixed);
    try std.testing.expect(std.mem.indexOf(u8, output, "withConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "componentId: \"sc-") != null);
}

/// 출력에 `displayName: "<name>"` 또는 prefixed `displayName: "<...>__<name>"` 가
/// 들어있는지 검사. fileName 옵션 (default true) 으로 prefix 가 붙거나 안 붙거나
/// 양쪽 다 인정 — 본 헬퍼는 wrap 작동 여부 검증용.
fn containsDisplayName(output: []const u8, name: []const u8) bool {
    var direct_buf: [256]u8 = undefined;
    const direct = std.fmt.bufPrint(&direct_buf, "displayName: \"{s}\"", .{name}) catch return false;
    if (std.mem.indexOf(u8, output, direct) != null) return true;
    var suffix_buf: [256]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "__{s}\"", .{name}) catch return false;
    return std.mem.indexOf(u8, output, suffix) != null;
}

/// 출력의 `withConfig(` 호출 횟수가 expected 인지 검증 — 다중 wrap 케이스 (ternary,
/// if-else, try/catch/finally, switch case) 에서 사용.
fn expectWithConfigCount(output: []const u8, expected: usize) !void {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, output, i, "withConfig(")) |pos| : (i = pos + 1) {
        count += 1;
    }
    try std.testing.expectEqual(expected, count);
}

test "styled-components: styled.X 선언 → withConfig({displayName}) 래핑" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Button = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Button");
}

test "styled-components: styled(Component) 선언 → withConfig({displayName})" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\import Inner from "./inner";
        \\const Wrapped = styled(Inner)`color: blue;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Wrapped");
}

test "styled-components: 옵션 비활성 시 변환 없음" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Button = styled.div`color: red;`;
    ,
        .{ .styled_components = false },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName") == null);
}

test "styled-components: import 없으면 변환 없음" {
    // styled binding 이 없으므로 detection no-op. 옵션 활성이어도 변환 안 일어남.
    var r = try e2eFull(
        std.testing.allocator,
        \\const styled = { div: () => null };
        \\const Button = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: @emotion/styled source 는 미감지" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@emotion/styled";
        \\const Button = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: .attrs(...) chain — 체인 끝에 withConfig 추가" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Input = styled.input.attrs({ type: "text" })`padding: 4px;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Input");
    // attrs 자체는 보존되어야 함 — chain 가 망가지면 안 됨.
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".attrs(") != null);
}

test "styled-components: 다중 체인 styled(X).attrs() 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\import Inner from "./inner";
        \\const Wrapped = styled(Inner).attrs(props => ({ id: props.id }))`color: blue;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Wrapped");
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".attrs(") != null);
}

test "styled-components: 다른 라이브러리의 비슷한 체인은 미인식" {
    // emotion 의 styled (다른 binding) 은 chain 이어도 우리 transform 영향 받지 않음.
    var r = try e2eFull(
        std.testing.allocator,
        \\import emotionStyled from "@emotion/styled";
        \\const X = emotionStyled.div.attrs({})`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: styled-components/native source 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components/native";
        \\const Box = styled.View`padding: 16px;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Box");
}

test "styled-components: import alias 도 추적" {
    // import 가 default alias 이면 그 alias 이름을 binding 으로 사용해야 함.
    var r = try e2eFull(
        std.testing.allocator,
        \\import s from "styled-components";
        \\const Btn = s.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Btn");
}

test "styled-components: template literal 내용은 그대로 보존" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const C = styled.div`width: 100%; color: ${'red'};`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "C");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "width: 100%") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color:") != null);
}

test "styled-components: object property { One: styled.div`` } 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const styles = { One: styled.div`color: red;`, Two: styled.span`color: blue;` };
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "One");
    try expectDisplayName(r.output, "Two");
}

test "styled-components: object property string-key { \"My Comp\": ... } 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const styles = { "MyComp": styled.div`color: red;` };
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "MyComp");
}

test "styled-components: IIFE `(() => styled.div\\`\\`)()` 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Lazy = (() => styled.div`color: red;`)();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Lazy");
    // IIFE 외형 보존 — wrap 이 안쪽에서 일어나야 함.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "()=>") != null or
        std.mem.indexOf(u8, r.output, "() =>") != null);
}

test "styled-components: IIFE 의 arrow params + closure 보존" {
    // arrow 가 param 받는 경우 — 우리 wrap 은 body 의 tagged_template 만 변환,
    // 원본 template 노드는 그대로 참조되므로 ${color} 같은 closure binding 유지.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Themed = ((color) => styled.div`color: ${color};`)("red");
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Themed");
    // closure binding `${color}` 보존 — wrap 이 template 변형 안 함.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color") != null);
}

test "styled-components: 다중 paren `((() => ...))()` 도 처리" {
    // formatter 가 보통 collapse 하지만 source 그대로 들어오면 다중 unwrap 필요.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Deep = ((() => styled.div`color: red;`))();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Deep");
}

test "styled-components: IIFE block body `(() => { return ... })()` 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Lazy = (() => { return styled.div`color: red;`; })();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Lazy");
}

test "styled-components: IIFE block body 다중 statement + return" {
    // pre-statement 가 있어도 return 의 operand 만 wrap.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Lazy = (() => { console.log("setup"); return styled.div`color: red;`; })();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Lazy");
    // pre-statement 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log") != null);
}

test "styled-components: IIFE block 안 if-statement 의 return 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Lazy = (() => { if (cond) return styled.div`color: red;`; return null; })();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Lazy");
}

test "styled-components: if-else 양쪽 branch 의 return 모두 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Pick = (() => {
        \\  if (cond) return styled.div`color: red;`;
        \\  else return styled.span`color: blue;`;
        \\})();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Pick");
    // 두 번 wrap 되었어야 — withConfig 가 2번 등장.
    try expectWithConfigCount(r.output, 2);
}

test "styled-components: 중첩 if 안 block 안의 return 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Deep = (() => {
        \\  if (cond) {
        \\    setup();
        \\    return styled.div`color: red;`;
        \\  }
        \\  return null;
        \\})();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Deep");
}

test "styled-components: try-block 안 return 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Tried = (() => { try { return styled.div`color: red;`; } catch {} })();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Tried");
}

test "styled-components: try/catch/finally 모든 block 안 return wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Multi = (() => {
        \\  try { return styled.div`color: red;`; }
        \\  catch (e) { return styled.span`color: blue;`; }
        \\  finally { return styled.section`color: green;`; }
        \\})();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Multi");
    try expectWithConfigCount(r.output, 3);
}

test "styled-components: switch case 의 return 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Switched = (() => {
        \\  switch (kind) {
        \\    case "a": return styled.div`color: red;`;
        \\    case "b": return styled.span`color: blue;`;
        \\    default: return styled.section`color: gray;`;
        \\  }
        \\})();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Switched");
    try expectWithConfigCount(r.output, 3);
}

test "styled-components: for/while/do-while body 안 return 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Looped = (() => {
        \\  while (cond) return styled.div`color: red;`;
        \\  for (let i = 0; i < 1; i++) return styled.span`color: blue;`;
        \\  do { return styled.section`color: green;`; } while (false);
        \\})();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Looped");
    try expectWithConfigCount(r.output, 3);
}

test "styled-components: for-in / for-of body 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Iter = (() => {
        \\  for (const k in obj) return styled.div`color: red;`;
        \\  for (const x of arr) return styled.span`color: blue;`;
        \\})();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Iter");
    try expectWithConfigCount(r.output, 2);
}

test "styled-components: labeled statement body 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Labeled = (() => {
        \\  outer: { return styled.div`color: red;`; }
        \\})();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Labeled");
}

test "styled-components: switch case + block 안 return 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Cases = (() => {
        \\  switch (kind) {
        \\    case "a": {
        \\      log();
        \\      return styled.div`color: red;`;
        \\    }
        \\  }
        \\})();
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Cases");
}

test "styled-components: 일반 함수 호출 `someFn(...)` 은 IIFE 가 아님 (회귀 가드)" {
    // call_expression 이 isWrappableExpr 에 추가되었지만 callee 가 arrow 가 아니면
    // 즉시 early-return 해야 함 — 일반 함수 호출에서 false-positive 없어야.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const X = createSomething(styled.div`color: red;`);
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: 클래스 정적 필드 `static Child = styled.div\\`\\``" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\class Comp {
        \\  static Child = styled.div`color: red;`;
        \\}
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Child");
}

test "styled-components: 클래스 인스턴스 필드 `field = styled.div\\`\\`` 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\class Comp {
        \\  Inner = styled.div`color: red;`;
        \\}
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Inner");
}

test "styled-components: 클래스 computed key `[expr] = ...` 는 미인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const key = "X";
        \\class Comp {
        \\  static [key] = styled.div`color: red;`;
        \\}
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: 논리 `cond && styled.div\\`\\`` 우변 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Lazy = enabled && styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Lazy");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "&&") != null); // wrapper 보존
}

test "styled-components: 논리 `default || styled.div\\`\\`` 우변 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Fallback = userOverride || styled.div`color: blue;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Fallback");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "||") != null); // wrapper 보존
}

test "styled-components: 좌변이 styled 인 `styled.div\\`\\` || fallback` 은 미인식 (의도)" {
    // 좌변 wrap 은 단락평가 시맨틱 영향 위험으로 skip — 가드 회귀 보호.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const X = styled.div`color: red;` || LegacyBtn;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: TS cast `styled.div\\`\\` as Component` 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Casted = styled.div`color: red;` as React.FC;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Casted");
    // TS cast 자체는 codegen 에서 strip — operand (= wrap 된 styled tag) 만 남음.
}

test "styled-components: TS satisfies `... satisfies T` 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Sat = styled.div`color: red;` satisfies React.FC;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Sat");
    // satisfies 는 codegen 에서 strip — wrap 된 operand 만 남음.
}

test "styled-components: TS non-null `...!` 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const NN = styled.div`color: red;`!;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "NN");
    // non-null assertion (!) 은 TS 전용 — codegen 에서 strip.
}

test "styled-components: 사용자 명시 .withConfig 에 displayName MERGE" {
    // 사용자 componentId 는 보존 + ZTS 가 displayName 자동 추가.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const X = styled.div.withConfig({ componentId: "user-id" })`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // user 의 componentId 그대로 보존.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "user-id") != null);
    // displayName 은 ZTS 가 추가.
    try std.testing.expect(containsDisplayName(r.output, "X"));
    // 추가 .withConfig 호출 없음 (merge 라 한 번만).
    try expectWithConfigCount(r.output, 1);
}

test "styled-components: spread element 도 prepend 전략으로 안전하게 MERGE" {
    // ZTS 자동값을 spread 보다 앞에 두면 user 의 spread 또는 explicit key 가 자연스럽게
    // 우리 값을 override (= user-intended). later-wins footgun 회피.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Sp = styled.div.withConfig({ ...userConfig, custom: 1 })`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // ZTS 자동 displayName 추가됨. spread 보다 앞에 있어야 user 의 spread 가 override 가능.
    try std.testing.expect(containsDisplayName(r.output, "Sp"));
    // displayName 이 spread 보다 먼저 나타나야 함.
    // displayName 위치 확인 — fileName prefix 까지 고려해 substring 검색.
    const display_pos = std.mem.indexOf(u8, r.output, "Sp\"") orelse return error.NotFound;
    const spread_pos = std.mem.indexOf(u8, r.output, "...userConfig") orelse return error.NotFound;
    try std.testing.expect(display_pos < spread_pos);
}

test "styled-components: 사용자가 displayName 도 박았으면 그대로 보존" {
    // 사용자가 자체 displayName 을 명시 — ZTS 자동값으로 override 안 함.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const X = styled.div.withConfig({ displayName: "Custom", componentId: "u" })`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Custom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"X\"") == null);
}

test "styled-components: outer .withConfig — .attrs 가 안에 있어도 MERGE" {
    // outer 가 .withConfig 면 (chain 의 마지막 호출) 해당 obj 에 displayName MERGE.
    // 가운데 .attrs 는 보존.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Y = styled.div.attrs({ id: "y" }).withConfig({ componentId: "y-id" })`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "y-id") != null);
    try std.testing.expect(containsDisplayName(r.output, "Y"));
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".attrs(") != null); // attrs 보존
}

test "styled-components: chain 중간 .withConfig 도 MERGE — outer 가 .attrs 여도 OK" {
    // chain 어디에 있든 .withConfig 의 args 에 prepend. rewriteChainAt 가 outer 까지 rebuild.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Z = styled.div.withConfig({ componentId: "z-id" }).attrs({ id: "z" })`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "z-id") != null);
    try std.testing.expect(containsDisplayName(r.output, "Z"));
    // attrs 도 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, ".attrs(") != null);
}

test "styled-components: .attrs 만 있는 chain 은 정상 wrap" {
    // attrs 는 user-config 가 아니므로 정상 wrap — 회귀 보호.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Z = styled.div.attrs({ id: "z" })`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Z");
}

test "styled-components: 조건부 ternary — 양쪽 branch 에 같은 displayName" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Test = isDark ? styled.div`color: white;` : styled.div`color: black;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // 두 branch 가 모두 wrap 되어야 함 — Test displayName 이 두 번 등장.
    // fileName=true (default) 면 prefix 포함 형태 검색.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, r.output, i, "Test\"")) |pos| : (i = pos + 1) {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "styled-components: 괄호 안 styled.div 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Wrapped = (styled.div`color: red;`);
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Wrapped");
}

test "styled-components: 조건부 한쪽 branch 만 styled — wrap 후에도 다른 쪽 보존" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Test = cond ? styled.div`color: red;` : null;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Test");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "null") != null);
}

test "styled-components: assignment `Component = styled.div\\`...\\`` 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\let Component;
        \\Component = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Component");
}

test "styled-components: assignment 의 LHS 가 member expression 이면 skip" {
    // obj.field = styled.div`` — 정적 이름 추출 불가 (member 의 어떤 이름을 쓸지 모호) → skip.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const obj = {};
        \\obj.field = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: object property string-key 의 escape 는 보수적으로 reject" {
    // plainStringLiteralValue 는 raw vs decoded 시맨틱 차이를 피하려고 backslash 포함 문자열을
    // 거절. 후속 PR 에서 decode 후 매칭 도입 시 이 케이스를 변환하도록 변경 가능.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const styles = { "A\"B": styled.div`color: red;` };
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: computed property key 는 미인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const key = "X";
        \\const styles = { [key]: styled.div`color: red;` };
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // computed key 는 displayName 추출 불가 — 변환 안 일어남.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled-components: minify=true 시 CSS whitespace collapse" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Card = styled.div`
        \\  color: red;
        \\  padding: 8px;
        \\`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx", .styled_components_minify = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Card");
    // newlines / 다중 스페이스가 single space 로 collapse — `\n  color` 같은 패턴 사라짐.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\n  color") == null);
    // 단일 space 로 분리된 ` color: red; padding: 8px;` 형태로 합쳐짐 (basic minify).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red; padding: 8px;") != null);
}

test "styled-components: minify=false (default) 면 CSS 보존" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Card = styled.div`
        \\  color: red;
        \\`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" }, // minify defaults false
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Card");
    // 원본 newline 보존 — minify 안 함.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\n  color") != null);
}

test "styled-components: minify — interpolation 있는 template 도 minify (각 quasi 별)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`
        \\  color: ${color};
        \\  padding: 8px;
        \\`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx", .styled_components_minify = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Btn");
    // 각 quasi 가 minify 됨 — 들여쓰기 제거.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\n  color") == null);
    // 보간 marker `${color}` 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${color}") != null);
}

test "styled-components: minify — 다중 보간 사이 quasi 도 처리" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Multi = styled.div`
        \\  color: ${a};
        \\  padding: ${b}px ${c}px;
        \\`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx", .styled_components_minify = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Multi");
    // 모든 보간 보존 (3개)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${a}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${b}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${c}") != null);
    // 들여쓰기 / newline 제거됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\n  ") == null);
}

test "styled-components: ssr=false 시 componentId 생략, displayName 만" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx", .styled_components_ssr = false },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(containsDisplayName(r.output, "Btn"));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "componentId") == null);
}

test "styled-components: ssr=true (default) 시 componentId emit" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" }, // ssr defaults to true
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "componentId: \"sc-") != null);
}

test "styled-components: jsx_filename 빈 문자열 시 componentId 생략 (displayName 만)" {
    // SSR 안전성: filename 없으면 cross-file ID 충돌 위험 → componentId 생략 (graceful degradation).
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const X = styled.div`color: red;`;
    ,
        .{ .styled_components = true }, // jsx_filename 미지정 (default "")
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"X\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "componentId") == null);
}

test "styled-components: componentId counter 가 같은 파일 내 0,1,2 로 증가" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const A = styled.div`color: red;`;
        \\const B = styled.div`color: blue;`;
        \\const C = styled.div`color: green;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // 같은 파일 내 file_hash 는 동일, counter 만 0/1/2 로 증가.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "-0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "-2\"") != null);
}

// ─── named helper imports (css / keyframes / createGlobalStyle / injectGlobal) ───
// `import { css, keyframes, ... } from "styled-components"` 인식 + minify 옵션
// 적용. helper 는 컴포넌트 아니라 CSS 조각이라 displayName/componentId 안 붙임.

test "styled (helper): import { css } 인식 + minify 옵션 적용" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "styled-components";
        \\const styles = css`
        \\  color:   red;
        \\  padding: 8px;
        \\`;
    ,
        .{ .styled_components = true, .styled_components_minify = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // CSS minify 적용 — 다중 공백 collapse
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
    // 원본 indented 다중라인 형태가 아니어야 함 (collapsed)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  color:   red;") == null);
    // helper 라 displayName 안 들어감
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName") == null);
}

test "styled (helper): import { keyframes } 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { keyframes } from "styled-components";
        \\const fadeIn = keyframes`
        \\  from { opacity: 0; }
        \\  to   { opacity: 1; }
        \\`;
    ,
        .{ .styled_components = true, .styled_components_minify = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "opacity: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  to   {") == null);
}

test "styled (helper): import { createGlobalStyle } 인식 + minify" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { createGlobalStyle } from "styled-components";
        \\const Global = createGlobalStyle`
        \\  body  {  margin: 0;  }
        \\`;
    ,
        .{ .styled_components = true, .styled_components_minify = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "margin: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  body  {  ") == null);
}

test "styled (helper): import alias `import { css as cx }` 도 추적" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css as cx } from "styled-components";
        \\const s = cx`
        \\  color:  blue;
        \\`;
    ,
        .{ .styled_components = true, .styled_components_minify = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: blue") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  color:  blue;") == null);
}

test "styled (helper): default `styled` 와 named `css` 동시 import" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled, { css } from "styled-components";
        \\const helper = css`
        \\  color:  red;
        \\`;
        \\const Btn = styled.div`color: blue;`;
    ,
        .{ .styled_components = true, .styled_components_minify = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // helper 의 css 도 minify, styled.div 도 wrap (displayName 등) + minify
    try std.testing.expect(containsDisplayName(r.output, "Btn"));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  color:  red;") == null);
}

test "styled (helper): non-styled-components source 의 css 는 미인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const styles = css`
        \\  color:   red;
        \\`;
    ,
        .{ .styled_components = true, .styled_components_minify = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // emotion 의 css 는 styled-components helper 로 인식 안 됨 — minify 적용 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  color:   red;") != null);
}

test "styled (helper): minify 옵션 비활성 — 인식만 하고 변환 안 함" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "styled-components";
        \\const styles = css`
        \\  color:  red;
        \\`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" }, // minify 미설정
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // minify 비활성 — 원본 그대로
    try std.testing.expect(std.mem.indexOf(u8, r.output, "  color:  red;") != null);
}

// ─── fileName 옵션 (default true, babel 동일) ───
// displayName 에 `<basename>__<var>` prefix 부여. SSR componentId 안정성 + DevTools 가독성.

test "styled (fileName): default true — displayName 에 `<basename>__` prefix" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "src/Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // basename "Button" ≠ var "Btn" → prefix 추가
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Button__Btn\"") != null);
}

test "styled (fileName): basename 이 var name 과 같으면 prefix 생략" {
    // `Button.tsx` 안의 `const Button = ...` → basename == var → 그냥 "Button"
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Button = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "src/Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Button\"") != null);
    // prefix 없이 단순히 "Button"
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Button__Button") == null);
}

test "styled (fileName): index.tsx → parent dir 명으로 fallback" {
    // src/Button/index.tsx → basename "index" 는 의미 없음 → parent "Button" 사용.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Inner = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "src/Button/index.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Button__Inner\"") != null);
}

test "styled (fileName): false 옵션 — prefix 없이 var 만" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .styled_components_file_name = false, .jsx_filename = "src/Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Btn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Button__") == null);
}

test "styled (meaninglessFileNames): 사용자 list 의 basename 도 fallback" {
    // 사용자 옵션으로 `styles` 도 의미 없는 basename 으로 등록 — parent dir 로 fallback.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Inner = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_meaningless_file_names = &.{ "index", "styles" },
            .jsx_filename = "src/Button/styles.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Button__Inner\"") != null);
}

test "styled (topLevelImportPaths): vendored fork 도 styled 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@my-org/styled";
        \\const Btn = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_top_level_import_paths = &.{"@my-org/styled"},
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // vendored fork 의 default import 도 styled 처럼 wrap → withConfig + displayName
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Btn") != null);
}

test "styled (topLevelImportPaths): glob `@my-org/*` 도 vendored fork 매칭" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@my-org/styled-fork";
        \\const Btn = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_top_level_import_paths = &.{"@my-org/*"},
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") != null);
}

test "styled (topLevelImportPaths): brace expansion 매칭" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@my-org/styled";
        \\const Btn = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_top_level_import_paths = &.{"@{my-org,co}/*"},
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") != null);
}

test "styled (topLevelImportPaths): glob 미매칭 fork 는 무시" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@other-org/styled";
        \\const Btn = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_top_level_import_paths = &.{"@my-org/*"},
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled (topLevelImportPaths): 미등록 source 는 무시 (보호 회귀)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@my-org/styled";
        \\const Btn = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_top_level_import_paths = &.{"@other-org/styled"},
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // 매칭 안 되는 fork 는 그대로 → withConfig 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "withConfig") == null);
}

test "styled (meaninglessFileNames): 빈 list 면 `index` fallback 도 비활성" {
    // 빈 array 로 override 하면 babel 기본 `index` fallback 도 안 적용 — 그대로 `index__Inner`.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Inner = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_meaningless_file_names = &.{},
            .jsx_filename = "src/Button/index.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"index__Inner\"") != null);
}

test "styled (fileName): jsx_filename 빈 문자열 — prefix 안 붙음" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true }, // jsx_filename 미지정
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Btn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__") == null);
}

test "styled (fileName): basename 이 digit 으로 시작 → `_` prefix" {
    // CSS class 첫 글자 digit 금지 → babel 의 prefixLeadingDigit 동작 매칭.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "src/123Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"_123Button__Btn\"") != null);
}

// ─── pure 옵션 (default false, babel 동일) ───
// `compiler.styledComponents: { pure: true }` 활성 시 styled component 생성 expression
// 앞에 `/* @__PURE__ */` annotation 부여 — minifier 가 미사용 component 를 tree-shake.

test "styled (pure): default false — annotation 없음" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") == null);
}

test "styled (pure): true — styled.div 앞에 annotation" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .styled_components_pure = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") != null);
    // annotation 이 styled.div.withConfig 앞에 와야
    const pure_pos = std.mem.indexOf(u8, r.output, "/* @__PURE__ */") orelse return error.NotFound;
    const styled_pos = std.mem.indexOf(u8, r.output, "styled.div") orelse return error.NotFound;
    try std.testing.expect(pure_pos < styled_pos);
}

test "styled (pure): styled(Component) chain 도 annotation" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\import Inner from "./inner";
        \\const Wrapped = styled(Inner)`color: blue;`;
    ,
        .{ .styled_components = true, .styled_components_pure = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") != null);
}

test "styled (pure): 사용자 .withConfig MERGE 케이스도 annotation" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const X = styled.div.withConfig({ componentId: "user-id" })`color: red;`;
    ,
        .{ .styled_components = true, .styled_components_pure = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "user-id") != null);
}

test "styled (pure): helper css`...` 도 annotation" {
    // css helper 도 PURE 적용 → 미사용 css fragment tree-shaking.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "styled-components";
        \\const styles = css`
        \\  color:  red;
        \\`;
    ,
        .{
            .styled_components = true,
            .styled_components_pure = true,
            .styled_components_minify = true,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") != null);
}

test "styled (pure): 옵션 비활성 시 helper 에도 annotation 없음" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "styled-components";
        \\const styles = css`color: red;`;
    ,
        .{ .styled_components = true, .styled_components_minify = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") == null);
}

// ─── namespace 옵션 (default "" 비활성) ───
// `compiler.styledComponents: { namespace: "myapp" }` 활성 시 componentId 에 prefix 부여.
// monorepo / library 환경에서 다른 의존성 트리에 같은 styled-components 가 존재해도
// componentId 충돌 회피.

test "styled (namespace): default 빈 문자열 — prefix 없음" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // componentId = sc-<hash>-0 (prefix 없음)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "componentId: \"sc-") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "myapp__sc-") == null);
}

test "styled (namespace): 'myapp' 설정 — componentId 에 prefix" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .styled_components = true, .styled_components_namespace = "myapp", .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // componentId = "myapp__sc-<hash>-0"
    try std.testing.expect(std.mem.indexOf(u8, r.output, "componentId: \"myapp__sc-") != null);
}

test "styled (namespace): 사용자 .withConfig MERGE 케이스도 적용" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const X = styled.div.withConfig({ displayName: "Custom" })`color: red;`;
    ,
        .{ .styled_components = true, .styled_components_namespace = "myorg", .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // 사용자 displayName 보존, ZTS 가 추가하는 componentId 에 prefix 적용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Custom") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "componentId: \"myorg__sc-") != null);
}

test "styled (namespace): displayName 은 영향 없음 (componentId 만 prefix)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_namespace = "myapp",
            .styled_components_file_name = false,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // displayName 은 그대로 var 이름 (namespace prefix 없음)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Btn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"myapp") == null);
    // componentId 만 prefix
    try std.testing.expect(std.mem.indexOf(u8, r.output, "componentId: \"myapp__sc-") != null);
}

// ─── cssProp transform (Round 4) ───
// 본 PR (Step 1) 은 hook entry + counter + stub. transform 검증 테스트는 후속 PR 에서.
// 옵션 켜도 transform 미적용 (사용자 코드 안전) 만 검증.

// ─── cssProp transform (Round 4 Step 1: MVP) ───
// `<div css={\`color: red;\`}>` → `<_styled_0>` + nearest list 에 styled.div 컴포넌트 decl.
// MVP 범위: intrinsic tag (lowercase) + template_literal css value + styled default_binding 존재 시.

test "styled (cssProp): intrinsic tag + template_literal css value 추출" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const el = <div css={`color: red;`}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // generated identifier `_styled_0` 가 module-level decl 로 추가되어야
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    // styled.div 호출이 있어야 (withConfig wrap 결과)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "styled.div") != null);
    // 원본 css 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "styled (cssProp): 옵션 비활성 시 변환 없음 (안전한 기본 동작)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const el = <div css={`color: red;`}>x</div>;
    ,
        .{
            .styled_components = true,
            // styled_components_css_prop 미지정 (default false)
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_") == null);
}

test "styled (cssProp Step 5): styled import 없으면 자동 import 추가" {
    var r = try e2eFull(
        std.testing.allocator,
        \\const el = <div css={`color: red;`}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    // 본 PR scope: transform 자체는 동작 + needs_import flag set. 실제 prepend 는
    // transpile.zig 의 6.6 hook 이 담당하므로 e2eFull 의 raw codegen 출력엔 import 가
    // 안 들어감 — 통합 테스트에서 검증.
    // hoisting 검증 — `const _styled_0` 이 별도 statement 로 program body 에 있어야 (이전
    // 버그: declarator list 안에 들어가서 `const el = ...,const _styled_0=...,;` 형태 invalid).
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const _styled_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ",const _styled_") == null);
}

test "styled (cssProp B2): collision 시 _styled mangling — `const styled` 충돌" {
    // 사용자 module-level 에 `const styled = ...` 이 이미 있으면 prepended import 와
    // redeclaration 충돌. 우리는 `_styled` 로 mangling 후 사용.
    var r = try e2eFull(
        std.testing.allocator,
        \\const styled = somethingElse;
        \\const el = <div css={`color: red;`}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // generated decl 의 RHS 가 `_styled.div` 형태여야 (mangled binding)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled.div") != null);
    // 사용자 const styled 는 그대로 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const styled = somethingElse") != null);
}

test "styled (cssProp B2): 다중 collision — `const styled, _styled` 둘 다 있으면 _styled2" {
    var r = try e2eFull(
        std.testing.allocator,
        \\const styled = a;
        \\const _styled = b;
        \\const el = <div css={`color: red;`}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled2.div") != null);
}

test "styled (cssProp Step 5): cssProp transform 안 일어나면 auto-inject 도 안 함" {
    // 옵션 활성이지만 jsx 안 쓰면 transform 자체가 안 일어남 → auto-inject 도 안 됨.
    var r = try e2eFull(
        std.testing.allocator,
        \\const x = 1;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import styled") == null);
}

test "styled (cssProp Step 2): css tagged template 도 인식 (quasi 만 추출)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled, { css } from "styled-components";
        \\const el = <div css={css`color: red;`}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "styled.div") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "styled (cssProp Step 2): css binding alias `import { css as cx }` 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled, { css as cx } from "styled-components";
        \\const el = <div css={cx`color: red;`}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "styled (cssProp Step 3): Custom component (PascalCase) 는 styled(Foo) 로 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Button = (props) => null;
        \\const el = <Button css={`color: red;`}>x</Button>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // styled(Button) 호출 형태로 변환
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "styled(Button)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "styled (cssProp A2): template `${expr}` interpolation prop forwarding" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const color = "red";
        \\const el = <div css={`color: ${color};`}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // 변환 결과:
    //   const _styled_0 = styled.div`color: ${p => p._css0};`;
    //   <_styled_0 _css0={color}>x</_styled_0>
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "p._css0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_css0:") != null or std.mem.indexOf(u8, r.output, "_css0=") != null or std.mem.indexOf(u8, r.output, "_css0\":") != null);
    // 원본 `color` 가 attr value 로 전달되어야
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color") != null);
}

test "styled (cssProp A2): 다중 interpolation 도 각각 _css0/_css1 로 forward" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const el = <div css={`color: ${color}; padding: ${padding}px;`}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "p._css0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "p._css1") != null);
}

test "styled (cssProp Step 4): object form `<div css={{...}}>` → styled.div({...})" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const el = <div css={{ color: "red" }}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    // styled.div({ ... }) call form
    try std.testing.expect(std.mem.indexOf(u8, r.output, "styled.div({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color:") != null);
}

test "styled (cssProp A1): object form dynamic value prop forwarding" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const theme = { primary: "red" };
        \\const el = <div css={{ color: theme.primary, fontSize: 14 }}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // 변환 결과:
    //   const _styled_0 = styled.div(p => ({ color: p._css0, fontSize: 14 }));
    //   <_styled_0 _css0={theme.primary}>x</_styled_0>
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "p._css0") != null);
    // primitive (14) 는 inline 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "fontSize: 14") != null or
        std.mem.indexOf(u8, r.output, "fontSize:14") != null);
}

test "styled (cssProp A1): object 안 모든 값이 primitive 면 forwarding 없음 (기본 call form)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const el = <div css={{ color: "red", fontSize: 14 }}>x</div>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // primitive 만 있으면 arrow wrap 안 함 (기존 Step 4 동작)
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_css") == null);
    // styled.div({...}) 는 그대로
    try std.testing.expect(std.mem.indexOf(u8, r.output, "styled.div({") != null);
}

test "styled (cssProp Step 4): object form 으로 Custom component 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Button = (props) => null;
        \\const el = <Button css={{ color: "red" }}>x</Button>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "styled(Button)({") != null);
}

test "styled (cssProp Step 3): jsx_member_expression `<Foo.Bar css>` → styled(Foo.Bar)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Foo = { Bar: (props) => null };
        \\const el = <Foo.Bar css={`color: red;`}>x</Foo.Bar>;
    ,
        .{
            .styled_components = true,
            .styled_components_css_prop = true,
            .jsx_transform = true,
            .jsx_runtime = .automatic,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_styled_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "styled(Foo.Bar)") != null);
}

test "styled (namespace): ssr=false 시 componentId 자체 생략 — namespace 도 영향 없음" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`color: red;`;
    ,
        .{
            .styled_components = true,
            .styled_components_namespace = "myapp",
            .styled_components_ssr = false,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // componentId 자체가 없어 namespace 도 emit 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "componentId") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "myapp__") == null);
}
