//! emotion 1st-party transform 회귀 테스트.

const std = @import("std");
const helpers = @import("../codegen/codegen_test/helpers.zig");
const e2eFull = helpers.e2eFull;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;

const default_cg: CodegenOptions = .{ .minify_whitespace = false };

fn expectAutoLabel(output: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "label:{s};", .{expected}) catch return error.OutOfMemory;
    try std.testing.expect(std.mem.indexOf(u8, output, needle) != null);
}

test "emotion: const X = css`...` 에 label:X; prepend" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const button = css`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "button");
    // 원본 CSS 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red;") != null);
}

test "emotion: 보간 있는 css 도 첫 quasi 에 label prepend" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const themed = css`color: ${color}; padding: 8px;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "themed");
    // 보간 marker 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${color}") != null);
}

test "emotion: alias `import { css as cx }` 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css as cx } from "@emotion/react";
        \\const button = cx`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "button");
}

test "emotion: @emotion/css source 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/css";
        \\const card = css`padding: 8px;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card");
}

// `@emotion/core` 는 v10 의 메인 entry. v11 에서 `@emotion/react` 로 rename 됨 —
// 하위호환 유지 차원 (v10 사용자 코드 그대로 동작).

test "emotion: @emotion/core (v10) css 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/core";
        \\const card = css`padding: 8px;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card");
}

test "emotion: @emotion/core (v10) keyframes 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { keyframes } from "@emotion/core";
        \\const fadeIn = keyframes`from { opacity: 0; }`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "fadeIn");
}

test "emotion: @emotion/core (v10) css + keyframes 동시 import 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css, keyframes } from "@emotion/core";
        \\const spin = keyframes`from { rotate: 0; }`;
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "spin");
    try expectAutoLabel(r.output, "card");
}

test "emotion: @emotion/core (v10) JSX inline `<div css={css`...`}>` 도 동작" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/core";
        \\const el = <div css={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
}

test "emotion: @emotion/core (v10) alias `import { css as cx }` 도 추적" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css as cx } from "@emotion/core";
        \\const button = cx`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "button");
}

test "emotion: { autoLabel: false } 옵션 — emotion 활성이지만 label skip" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const button = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_auto_label = .never, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // emotion 활성이지만 autoLabel 명시적 disable — label 추가 안 됨.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
    // 원본 css 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red;") != null);
}

test "emotion: 옵션 비활성 시 변환 없음" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const button = css`color: red;`;
    ,
        .{ .emotion = false, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
}

test "emotion: import 없으면 binding 미감지 → no-op" {
    var r = try e2eFull(
        std.testing.allocator,
        \\const css = (s) => s;
        \\const button = css`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
}

test "emotion: @emotion/primitives source 도 인식 (RN)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/primitives";
        \\const card = css`padding: 8px;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card");
}

test "emotion: @emotion/styled-base default 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@emotion/styled-base";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Btn");
}

test "emotion: 다른 라이브러리 source (`stitches`) 는 미감지" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@stitches/react";
        \\const button = css`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
}

test "emotion: @emotion/styled default — styled.div`` 도 autoLabel" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@emotion/styled";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Btn");
}

test "emotion: @emotion/styled — styled(Component)`` 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@emotion/styled";
        \\import Inner from "./inner";
        \\const Wrapped = styled(Inner)`color: blue;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Wrapped");
}

test "emotion: styled alias `import s from \"@emotion/styled\"` 도 추적" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import s from "@emotion/styled";
        \\const Btn = s.button`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Btn");
}

test "emotion: keyframes`...` 도 autoLabel" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { keyframes } from "@emotion/react";
        \\const fadeIn = keyframes`from { opacity: 0; } to { opacity: 1; }`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "fadeIn");
}

test "emotion: 같은 import 의 css + keyframes 동시 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css, keyframes } from "@emotion/react";
        \\const spin = keyframes`from { rotate: 0; } to { rotate: 360deg; }`;
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "spin");
    try expectAutoLabel(r.output, "card");
}

test "emotion: keyframes alias `import { keyframes as kf }` 도 추적" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { keyframes as kf } from "@emotion/react";
        \\const fadeIn = kf`from { opacity: 0; }`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "fadeIn");
}

test "emotion: styled chain `styled.div.withComponent(\"button\")\\`\\`` 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@emotion/styled";
        \\const Btn = styled.div.withComponent("button")`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Btn");
}

test "emotion: styled chain `styled(X).attrs({})\\`\\`` 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@emotion/styled";
        \\import Inner from "./inner";
        \\const Wrapped = styled(Inner).attrs({ id: "w" })`color: blue;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Wrapped");
}

test "emotion: tag 가 css.something 같은 chain 이면 미인식" {
    // chain 형태는 후속 PR. 단순 css binding 만 인식.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const ext = css.x`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
}

test "emotion: JSX inline `<div css={css`...`}>` autoLabel — element 이름 prepend" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
    // 원본 css 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red;") != null);
}

test "emotion: JSX inline `<Button css={css`...`}>` — Component 이름 prepend" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <Button css={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Button");
}

test "emotion: JSX inline css — autoLabel .never 면 skip" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={css`color: red;`} />;
    ,
        .{ .emotion = true, .emotion_auto_label = .never, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red;") != null);
}

test "emotion: JSX 의 css 와 다른 attr 동시 — css 만 label 추가" {
    // pair-test: 같은 element 에 className+css 둘 다 있을 때 css 만 처리되는지.
    // label 갯수 1 이어야 함 — css 는 인식, className 은 인식 안 됨.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div className={css`padding: 8px;`} css={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // label:div; 가 정확히 1번 — css attr 의 value 에만.
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, r.output, search_from, "label:div;")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "emotion: JSX inline css — 보간 있는 css 도 첫 quasi 에 prepend" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={css`color: ${color}; padding: 8px;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${color}") != null);
}

test "emotion: JSX inline css — non-emotion tag (`<div css={foo`...`}>`) 미인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\const foo = (s) => s;
        \\const el = <div css={foo`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
}

test "emotion: JSX inline css — classic runtime 에서도 동작" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .classic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
}

// ─── Global / injectGlobal ───
// 글로벌 스타일 API. `injectGlobal\`...\`` 는 tagged template (binding 추적), `<Global
// styles={...}>` 는 JSX (element 매칭 + styles attr) — 두 시나리오 다 처리.

test "emotion: injectGlobal binding form 도 autoLabel" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { injectGlobal } from "@emotion/css";
        \\const reset = injectGlobal`* { box-sizing: border-box; }`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "reset");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "box-sizing: border-box") != null);
}

test "emotion: injectGlobal alias `import { injectGlobal as ig }` 도 추적" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { injectGlobal as ig } from "@emotion/css";
        \\const reset = ig`body { margin: 0; }`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "reset");
}

test "emotion: <Global styles={css`...`}> JSX — element 이름 (Global) 으로 label" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { Global, css } from "@emotion/react";
        \\const el = <Global styles={css`body { color: red; }`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Global");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "emotion: <Global> alias `import { Global as G }` 도 element 매칭" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { Global as G, css } from "@emotion/react";
        \\const el = <G styles={css`body { margin: 0; }`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // alias 된 이름 "G" 가 label 로 사용 (사용자가 코드에서 보는 이름)
    try expectAutoLabel(r.output, "G");
}

test "emotion: 비-Global element 의 styles attr 은 미인식 — false-positive 방지" {
    // `styles` 는 너무 일반적이라 다른 라이브러리/사용자 컴포넌트와 충돌 위험.
    // global_binding 매칭 시에만 처리.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <SomeComponent styles={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // Global binding 이 import 되지 않았으므로 SomeComponent.styles 는 처리 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "emotion: Global import 없이 <Global> 만 사용 — 미인식 (binding 없음)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <Global styles={css`body { color: red; }`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // emotion 의 Global 을 import 안 했으므로 styles attr 처리 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:Global;") == null);
}

test "emotion: <Global styles={css`color: ${x};`}> 보간 있는 styles 도 처리" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { Global, css } from "@emotion/react";
        \\const el = <Global styles={css`color: ${color}; padding: 8px;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Global");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "${color}") != null);
}

test "emotion: bare `injectGlobal`...`` (binding 없음) — no-op 으로 통과" {
    // 흔한 사용 패턴: side-effect call. binding 이 없으니 autoLabel 적용 안 됨 — 하지만
    // 변환이 깨지거나 크래시 나면 안 됨.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { injectGlobal } from "@emotion/css";
        \\injectGlobal`* { box-sizing: border-box; }`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // binding 없으므로 label 없음
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
    // 원본 css 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "box-sizing: border-box") != null);
}

// ─── JSX member expression ───
// `<Components.Button css={...}>` 같은 member expression 의 rightmost identifier 를
// label 로 사용 (babel-plugin-emotion 동작과 일치).

test "emotion: JSX member `<Foo.Bar css={...}>` — rightmost (Bar) 로 label" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <Foo.Bar css={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Bar");
}

test "emotion: JSX deep member `<Foo.Bar.Baz css={...}>` — rightmost (Baz) 로 label" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <Foo.Bar.Baz css={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Baz");
}

// ─── ClassNames render-prop ───
// `<ClassNames>{({css}) => <div className={css`...`}/>}</ClassNames>` 패턴.
// destructured `css` 는 import 가 아니라 render-prop 함수 매개변수 — scope frame
// infra 로 그 함수 안에서만 emotion css 로 인식.

test "emotion: <ClassNames> render-prop 의 destructured css 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { ClassNames } from "@emotion/react";
        \\const el = <ClassNames>{({ css }) => <div className={css`color: red;`} />}</ClassNames>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "emotion: ClassNames 의 const X = css`...` binding form 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { ClassNames } from "@emotion/react";
        \\const el = <ClassNames>{({ css }) => {
        \\  const card = css`color: red;`;
        \\  return <div className={card} />;
        \\}}</ClassNames>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // `const card = css`...`` 형태도 scope-local css binding 으로 인식 → label:card
    try expectAutoLabel(r.output, "card");
}

test "emotion: ClassNames destructure alias `{ css: cs }` 도 추적" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { ClassNames } from "@emotion/react";
        \\const el = <ClassNames>{({ css: cs }) => <div className={cs`color: blue;`} />}</ClassNames>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
}

test "emotion: ClassNames import alias `import { ClassNames as CN }` 도 추적" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { ClassNames as CN } from "@emotion/react";
        \\const el = <CN>{({ css }) => <div className={css`color: red;`} />}</CN>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
}

test "emotion: ClassNames scope 밖에서는 className attr 처리 안 함" {
    // `<div className={fn`...`}/>` 가 ClassNames 밖에서는 일반 className 으로 처리 →
    // autoLabel 적용 안 됨. scope 격리 검증.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div className={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // import 된 css 가 className 에 쓰여도 (ClassNames 밖이므로) 처리 안 됨.
    // css attr 만 인식 — className 은 ClassNames scope 안에서만.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
    // 원본 css 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "emotion: ClassNames nested — outer/inner scope frame 독립" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { ClassNames } from "@emotion/react";
        \\const el = <ClassNames>{({ css: outerCss }) =>
        \\  <ClassNames>{({ css: innerCss }) =>
        \\    <div className={innerCss`color: red;`} />
        \\  }</ClassNames>
        \\}</ClassNames>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // inner scope frame 의 innerCss 가 우선 — div 에 label 적용됨
    try expectAutoLabel(r.output, "div");
}

test "emotion: ClassNames function_expression render-prop 도 인식" {
    // arrow 가 아닌 function expression 도 처리.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { ClassNames } from "@emotion/react";
        \\const el = <ClassNames>{function ({ css }) {
        \\  return <div className={css`color: red;`} />;
        \\}}</ClassNames>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
}

test "emotion: ClassNames render-prop param 이 destructure 아니면 no-op" {
    // `(props) => ...` 형태는 css local 이 추출 안 됨 → scope frame push 안 함.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { ClassNames } from "@emotion/react";
        \\const el = <ClassNames>{(props) => <div className={props.css`color: red;`} />}</ClassNames>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // scope 미진입 — className 처리 안 됨. crash 도 없어야 함.
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
}

test "emotion: <ClassNames> 에 render-prop child 없어도 crash 없음" {
    // children 이 text/element/없음 — render-prop 함수 못 찾음 → no-op.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { ClassNames } from "@emotion/react";
        \\const el = <ClassNames>fallback text</ClassNames>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
}

test "emotion: ClassNames render-prop 안에 import css 가 있어도 scope-local 우선" {
    // import 된 `css` 와 destructured local `cs` 가 공존 — destructured 가 우선.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css, ClassNames } from "@emotion/react";
        \\const outer = css`color: blue;`;
        \\const el = <ClassNames>{({ css: cs }) => <div className={cs`color: red;`} />}</ClassNames>;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "outer"); // import css 의 binding form
    try expectAutoLabel(r.output, "div"); // ClassNames render-prop 의 className inline
}

// ─── emotion sourceMap (babel-plugin-emotion source-maps.js 호환) ───
// `compiler.emotion: { sourceMap: true }` 일 때 css template 끝에 inline sourceMap
// 주석을 append. DevTools 가 CSS 위치 → source 위치 추적 가능.

fn expectSourceMapComment(output: []const u8) !void {
    try std.testing.expect(
        std.mem.indexOf(u8, output, "/*# sourceMappingURL=data:application/json;charset=utf-8;base64,") != null,
    );
}

test "emotion (sourceMap): css binding form — 템플릿 끝에 sourceMappingURL 주석 append" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_source_map = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card"); // autoLabel 도 동시 적용
    try expectSourceMapComment(r.output);
}

test "emotion (sourceMap): autoLabel false + sourceMap true — sourceMap 만 적용" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_auto_label = .never, .emotion_source_map = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:card;") == null);
    try expectSourceMapComment(r.output);
}

test "emotion (sourceMap): 옵션 비활성 시 sourceMap 주석 추가 안 됨" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" }, // emotion_source_map 기본 false
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card");
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sourceMappingURL") == null);
}

test "emotion (sourceMap): 보간 있는 css — 마지막 quasi 끝에 append (첫 quasi 의 label 과 분리)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const themed = css`color: ${color}; padding: 8px;`;
    ,
        .{ .emotion = true, .emotion_source_map = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "themed");
    try expectSourceMapComment(r.output);
    // sourceMap 주석이 마지막 quasi 안에 있어야 — backtick 직전에 위치
    const backtick_pos = std.mem.lastIndexOf(u8, r.output, "`") orelse return error.NotFound;
    const sm_pos = std.mem.indexOf(u8, r.output, "sourceMappingURL") orelse return error.NotFound;
    try std.testing.expect(sm_pos < backtick_pos);
}

test "emotion (sourceMap): keyframes 도 sourceMap 적용" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { keyframes } from "@emotion/react";
        \\const fadeIn = keyframes`from { opacity: 0; }`;
    ,
        .{ .emotion = true, .emotion_source_map = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "fadeIn");
    try expectSourceMapComment(r.output);
}

test "emotion (sourceMap): styled.div 도 sourceMap 적용" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@emotion/styled";
        \\const Btn = styled.div`color: red;`;
    ,
        .{ .emotion = true, .emotion_source_map = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Btn");
    try expectSourceMapComment(r.output);
}

test "emotion (sourceMap): JSX inline `<div css={css`...`}>` 도 sourceMap 적용" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={css`color: red;`} />;
    ,
        .{ .emotion = true, .emotion_source_map = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "div");
    try expectSourceMapComment(r.output);
}

test "emotion (sourceMap): expression-statement `injectGlobal`...`;` 에도 sourceMap 적용" {
    // babel-plugin-emotion 동작: side-effect call 형태에도 dev-build sourceMap 부여.
    // autoLabel 은 var 이름이 없어 적용 안 됨 (tag binding 만 매칭하면 sourceMap 만).
    var r = try e2eFull(
        std.testing.allocator,
        \\import { injectGlobal } from "@emotion/css";
        \\injectGlobal`* { box-sizing: border-box; }`;
    ,
        .{ .emotion = true, .emotion_source_map = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectSourceMapComment(r.output);
    // var 이름이 없으니 label: 없음 — false-positive 방지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
    // 원본 css 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "box-sizing: border-box") != null);
}

test "emotion (sourceMap): expression-statement form — sourceMap 옵션 비활성 시 미변경" {
    // sourceMap 옵션 false 면 expression-statement hook 도 no-op 이어야 함.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { injectGlobal } from "@emotion/css";
        \\injectGlobal`* { box-sizing: border-box; }`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sourceMappingURL") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "box-sizing: border-box") != null);
}

test "emotion (sourceMap): base64 디코딩 → JSON 구조 정합성 검증" {
    // 실제 base64 를 디코딩해 JSON 이 valid 한지, 핵심 필드가 들어있는지 확인.
    // VLQ 인코딩 회귀 (sign bit / continuation bit 순서 등) 를 잡기 위함.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_source_map = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();

    // base64 추출 — `base64,` 와 ` */` 사이.
    const prefix = "base64,";
    const suffix = " */";
    const start = std.mem.indexOf(u8, r.output, prefix) orelse return error.NoBase64Prefix;
    const after_prefix = start + prefix.len;
    const end = std.mem.indexOfPos(u8, r.output, after_prefix, suffix) orelse return error.NoBase64Suffix;
    const b64 = r.output[after_prefix..end];

    // 디코드.
    const decoder = std.base64.standard.Decoder;
    const json_len = try decoder.calcSizeForSlice(b64);
    const json_buf = try std.testing.allocator.alloc(u8, json_len);
    defer std.testing.allocator.free(json_buf);
    try decoder.decode(json_buf, b64);

    // sourceMap v3 spec 의 핵심 필드 검증.
    try std.testing.expect(std.mem.startsWith(u8, json_buf, "{\"version\":3,"));
    try std.testing.expect(std.mem.indexOf(u8, json_buf, "\"sources\":[\"test.tsx\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_buf, "\"sourcesContent\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_buf, "\"mappings\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_buf, "\"names\":[]") != null);
}

// ─── autoLabel mode (never / always / dev-only) ───
// `.dev_only` 는 `process.env.NODE_ENV` define 이 `"production"` 이면 `.never`,
// 아니면 `.always`. compile-time 결정 — runtime conditional 아님.

const transformer_mod = @import("transformer.zig");

const define_prod = [_]transformer_mod.DefineEntry{
    .{ .key = "process.env.NODE_ENV", .value = "\"production\"" },
};
const define_dev = [_]transformer_mod.DefineEntry{
    .{ .key = "process.env.NODE_ENV", .value = "\"development\"" },
};

test "emotion (autoLabel mode): .always — 기존 동작 유지" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_auto_label = .always, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card");
}

test "emotion (autoLabel mode): .never — label 추가 안 됨" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_auto_label = .never, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "color: red") != null);
}

test "emotion (autoLabel mode): .dev_only + NODE_ENV=production → .never 동작" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{
            .emotion = true,
            .emotion_auto_label = .dev_only,
            .define = &define_prod,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // production define → label 안 들어감
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:card;") == null);
}

test "emotion (autoLabel mode): .dev_only + NODE_ENV=development → .always 동작" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{
            .emotion = true,
            .emotion_auto_label = .dev_only,
            .define = &define_dev,
            .jsx_filename = "test.tsx",
        },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card");
}

test "emotion (autoLabel mode): .dev_only — define 없으면 .always (기본 dev 가정)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_auto_label = .dev_only, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card");
}

// ─── labelFormat ───
// 토큰: `[local]`, `[filename]`, `[dirname]` (case-insensitive).
// var_name 자체도 sanitize — invalid CSS char (`$` `.` `/` 등) → `-`.

test "emotion (labelFormat): 기본 (빈 문자열) — 기존 [local] 동작 유지" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "src/Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "card");
}

test "emotion (labelFormat): `[filename]--[local]` — 토큰 치환" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_label_format = "[filename]--[local]", .jsx_filename = "src/Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Button--card");
}

test "emotion (labelFormat): `[dirname]-[filename]-[local]` 3 토큰 모두" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const btn = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_label_format = "[dirname]-[filename]-[local]", .jsx_filename = "src/components/Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "components-Button-btn");
}

test "emotion (labelFormat): `index` filename → parent dir 로 fallback" {
    // src/Button/index.tsx 의 [filename] 은 "Button" (basename "index" → dirname).
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_label_format = "[filename]--[local]", .jsx_filename = "src/Button/index.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Button--card");
}

test "emotion (labelFormat): 토큰 case-insensitive — `[Local]` 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_label_format = "[Filename]--[LOCAL]", .jsx_filename = "src/Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Button--card");
}

test "emotion (labelFormat): 알 수 없는 토큰은 그대로 통과" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_label_format = "[unknown]-[local]", .jsx_filename = "src/Button.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "[unknown]-card");
}

test "emotion (sanitize): var name 의 invalid CSS char → `-`" {
    // `$` 는 valid identifier char 이지만 invalid CSS class char → `-` 치환.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const $card = css`color: red;`;
    ,
        .{ .emotion = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // `$card` → `-card` (sanitized)
    try expectAutoLabel(r.output, "-card");
}

test "emotion (sanitize): labelFormat 의 [filename] 도 sanitize" {
    // filename 에 `.` 등이 들어가면 sanitize. 예: `Button.test.tsx` → basename
    // "Button.test" → 첫 `.` 가 invalid → `Button-test`.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_label_format = "[filename]--[local]", .jsx_filename = "src/Button.test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // basename "Button.test.tsx" → ext=".tsx" → basename_no_ext="Button.test" → sanitize → "Button-test"
    try expectAutoLabel(r.output, "Button-test--card");
}

test "emotion (labelFormat): jsx_filename 없으면 [filename]/[dirname] = 빈 문자열" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const card = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_label_format = "[filename]--[local]" }, // jsx_filename 미지정
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // [filename] = "" → "--card"
    try expectAutoLabel(r.output, "--card");
}

// ─── Object/Array css prop ───
// `<div css={{color:'red'}}>` / `<div css={[a, b]}>` 를 `css(value, "label:div;")` call
// 로 wrap. `/* @__PURE__ */` annotation 까지 부여 — minifier tree-shaking 활성.
// css binding 이 import 안 됐으면 no-op (auto-inject 별도 작업).

test "emotion (object css): `<div css={{color:'red'}}>` → css(...) call wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={{ color: 'red' }} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // css(...) call 로 wrap + label 인자 + PURE annotation
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"label:div;\"") != null);
}

test "emotion (object css): `<Button css={[a, b]}>` array literal 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <Button css={[styleA, styleB]} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css([") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"label:Button;\"") != null);
}

test "emotion (object css): css alias `import { css as cx }` 도 wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css as cx } from "@emotion/react";
        \\const el = <div css={{ color: 'red' }} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // alias 'cx' 가 callee
    try std.testing.expect(std.mem.indexOf(u8, r.output, "cx({") != null);
}

test "emotion (object css): css import 없으면 no-op" {
    // css binding 이 import 안 됐으니 wrap 안 함 — 사용자 코드 그대로.
    var r = try e2eFull(
        std.testing.allocator,
        \\const el = <div css={{ color: 'red' }} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // wrap 안 됨 → object literal 그대로 css prop 으로
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css({") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"label:") == null);
}

test "emotion (object css): autoLabel .never — wrap 은 하되 label 인자 생략" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={{ color: 'red' }} />;
    ,
        .{ .emotion = true, .emotion_auto_label = .never, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // wrap + PURE 는 적용, label 인자만 생략
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"label:") == null);
}

test "emotion (object css): non-css attr (className 등) 는 wrap 안 함" {
    // className 의 object literal 은 emotion css prop 이 아니므로 wrap 금지.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div className={{ foo: 'bar' }} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css({") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"label:") == null);
}

test "emotion (object css): non-object/array value (identifier) 는 wrap 안 함" {
    // someStyles 같은 변수 참조는 사용자가 이미 적절한 형태로 만들었다고 가정 — wrap 금지.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={someStyles} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css(someStyles") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"label:") == null);
}

test "emotion (object css): `<Global styles={obj}/>` 도 css(...) wrap" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { Global, css } from "@emotion/react";
        \\const el = <Global styles={{ body: { margin: 0 } }} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "/* @__PURE__ */") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"label:Global;\"") != null);
}

test "emotion (object css): non-Global element 의 styles 는 wrap 안 함" {
    // styles attr 의 element-match 가드는 wrap 경로에도 동일 적용.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <SomeComp styles={{ color: 'red' }} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // Global binding 없거나 element 가 Global 아님 → wrap 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css({") == null);
}

test "emotion (object css): tagged template + object 둘 다 처리 (분기 검증)" {
    // 같은 파일 안에 두 형태 공존 — tagged template 은 prepend, object 는 wrap.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const a = <div css={css`color: red;`} />;
        \\const b = <div css={{ color: 'blue' }} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // tagged template path: label 이 quasi 안에 prepend
    try expectAutoLabel(r.output, "div");
    // object path: css({...}) wrap 형태
    try std.testing.expect(std.mem.indexOf(u8, r.output, "css({") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"label:div;\"") != null);
}

test "emotion (sourceMap): non-emotion tag 는 sourceMap 도 추가 안 됨" {
    var r = try e2eFull(
        std.testing.allocator,
        \\const foo = (s) => s;
        \\const x = foo`color: red;`;
    ,
        .{ .emotion = true, .emotion_source_map = true, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // emotion binding 이 아니므로 sourceMap 도 적용 안 됨
    try std.testing.expect(std.mem.indexOf(u8, r.output, "sourceMappingURL") == null);
}

test "emotion: <Foo.Global styles={...}> false-positive 방지 — member 면 미인식" {
    // rightmost 가 "Global" 이라도 사용자 컴포넌트의 member 면 emotion Global 이 아님.
    // 단순 jsx_identifier 만 elementMatchesGlobal 매칭.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { Global, css } from "@emotion/react";
        \\const el = <Foo.Global styles={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    // <Foo.Global> 의 styles 는 처리 안 됨 — Foo.Global 은 emotion Global 이 아님
    try std.testing.expect(std.mem.indexOf(u8, r.output, "label:") == null);
}

test "emotion: <Global css={...}> 는 css attr 로 처리 (styles 가 아니라)" {
    // Global 이라도 css attr 을 쓰면 일반 inline css 경로 — 정상 동작 확인.
    var r = try e2eFull(
        std.testing.allocator,
        \\import { Global, css } from "@emotion/react";
        \\const el = <Global css={css`color: red;`} />;
    ,
        .{ .emotion = true, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
        default_cg,
        ".tsx",
    );
    defer r.deinit();
    try expectAutoLabel(r.output, "Global");
}
