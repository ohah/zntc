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
