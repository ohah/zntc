//! styled-components 1st-party transform 회귀 테스트.

const std = @import("std");
const helpers = @import("../codegen/codegen_test/helpers.zig");
const e2eFull = helpers.e2eFull;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;

const default_cg: CodegenOptions = .{ .minify_whitespace = false };

/// 출력에 `withConfig({ displayName: "<expected>" })` + componentId 패턴이 나타나는지 검증.
/// componentId 는 `sc-<8hex>-<digit>` 형태만 확인 (정확 hash 는 file path 의존이라 변동 가능).
fn expectDisplayName(output: []const u8, expected: []const u8) !void {
    var quoted_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&quoted_buf, "displayName: \"{s}\"", .{expected}) catch return error.OutOfMemory;
    try std.testing.expect(std.mem.indexOf(u8, output, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "withConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "componentId: \"sc-") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"X\"") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Sp\"") != null);
    // displayName 이 spread 보다 먼저 나타나야 함.
    const display_pos = std.mem.indexOf(u8, r.output, "displayName: \"Sp\"") orelse return error.NotFound;
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Y\"") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Z\"") != null);
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
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, r.output, i, "displayName: \"Test\"")) |pos| : (i = pos + 1) {
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

test "styled-components: minify — interpolation 있는 template 은 보존 (후속 PR)" {
    // 보간 있는 template_literal (data.list.len > 0) 는 첫 iteration 에서 skip.
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Btn = styled.div`
        \\  color: ${color};
        \\`;
    ,
        .{ .styled_components = true, .jsx_filename = "test.tsx", .styled_components_minify = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectDisplayName(r.output, "Btn");
    // interpolation 있으면 minify skip — newline 보존.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\n  color") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.output, "displayName: \"Btn\"") != null);
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
