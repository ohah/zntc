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
