//! styled-components 1st-party transform 회귀 테스트.

const std = @import("std");
const helpers = @import("../codegen/codegen_test/helpers.zig");
const e2eFull = helpers.e2eFull;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;

const default_cg: CodegenOptions = .{ .minify_whitespace = false };

test "styled-components: styled.X 선언에 displayName 주입" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Button = styled.div`color: red;`;
        ,
        .{ .styled_components = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, "Button.displayName=\"Button\"") != null or
        std.mem.indexOf(u8, r.output, "Button.displayName = \"Button\"") != null);
}

test "styled-components: styled(Component) 선언에 displayName 주입" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\import Inner from "./inner";
        \\const Wrapped = styled(Inner)`color: blue;`;
        ,
        .{ .styled_components = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, "Wrapped.displayName=\"Wrapped\"") != null or
        std.mem.indexOf(u8, r.output, "Wrapped.displayName = \"Wrapped\"") != null);
}

test "styled-components: 옵션 비활성 시 주입 없음" {
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

    try std.testing.expect(std.mem.indexOf(u8, r.output, ".displayName") == null);
}

test "styled-components: import 없으면 주입 없음" {
    // styled binding 이 없으므로 detection no-op. 옵션 활성이어도 변환 안 일어남.
    var r = try e2eFull(
        std.testing.allocator,
        \\const styled = { div: () => null };
        \\const Button = styled.div`color: red;`;
        ,
        .{ .styled_components = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, ".displayName") == null);
}

test "styled-components: @emotion/styled source 는 미감지" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "@emotion/styled";
        \\const Button = styled.div`color: red;`;
        ,
        .{ .styled_components = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, ".displayName") == null);
}

test "styled-components: .attrs(...) chain 은 skip (이번 PR 스코프 외)" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components";
        \\const Input = styled.input.attrs({ type: "text" })`padding: 4px;`;
        ,
        .{ .styled_components = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, "Input.displayName") == null);
}

test "styled-components: styled-components/native source 도 인식" {
    var r = try e2eFull(
        std.testing.allocator,
        \\import styled from "styled-components/native";
        \\const Box = styled.View`padding: 16px;`;
        ,
        .{ .styled_components = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, "Box.displayName=\"Box\"") != null or
        std.mem.indexOf(u8, r.output, "Box.displayName = \"Box\"") != null);
}

test "styled-components: import alias 도 추적" {
    // import 가 default alias 이면 그 alias 이름을 binding 으로 사용해야 함.
    var r = try e2eFull(
        std.testing.allocator,
        \\import s from "styled-components";
        \\const Btn = s.div`color: red;`;
        ,
        .{ .styled_components = true },
        default_cg,
        ".tsx",
    );
    defer r.deinit();

    try std.testing.expect(std.mem.indexOf(u8, r.output, "Btn.displayName=\"Btn\"") != null or
        std.mem.indexOf(u8, r.output, "Btn.displayName = \"Btn\"") != null);
}
