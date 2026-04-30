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

test "emotion: { autoLabel: false } 옵션 — emotion 활성이지만 label skip" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const button = css`color: red;`;
    ,
        .{ .emotion = true, .emotion_auto_label = false, .jsx_filename = "test.tsx" },
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

test "emotion: JSX inline css — emotion_auto_label=false 면 skip" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import { css } from "@emotion/react";
        \\const el = <div css={css`color: red;`} />;
    ,
        .{ .emotion = true, .emotion_auto_label = false, .jsx_transform = true, .jsx_runtime = .automatic, .jsx_filename = "test.tsx" },
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
