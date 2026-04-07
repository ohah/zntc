const std = @import("std");
const helpers = @import("helpers.zig");
const e2e = helpers.e2e;
const e2eCJS = helpers.e2eCJS;
const e2eJSX = helpers.e2eJSX;
const e2eFull = helpers.e2eFull;
const e2eWithOptions = helpers.e2eWithOptions;
const e2eSourceMap = helpers.e2eSourceMap;
const TransformOptions = helpers.TransformOptions;
const CodegenOptions = helpers.CodegenOptions;
const compat = helpers.compat;
const e2eEngine = helpers.e2eEngine;
const e2eFlow = helpers.e2eFlow;
const e2eFlowModule = helpers.e2eFlowModule;
const e2eJSXAutomatic = helpers.e2eJSXAutomatic;
const e2eJSXDev = helpers.e2eJSXDev;

// 엔진 타겟 통합 테스트
// ============================================================

// --- 엔진 타겟: arrow function ---

test "engine target: chrome48 → arrow 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "const f = () => 1;", &.{.{ .engine = .chrome, .major = 48 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function") != null);
}

test "engine target: chrome49 → arrow 유지" {
    var r = try e2eEngine(std.testing.allocator, "const f = () => 1;", &.{.{ .engine = .chrome, .major = 49 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=>") != null);
}

// --- 엔진 타겟: nullish coalescing ---

test "engine target: chrome79 → ?? 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b;", &.{.{ .engine = .chrome, .major = 79 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
}

test "engine target: chrome80 → ?? 유지" {
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b;", &.{.{ .engine = .chrome, .major = 80 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "??") != null);
}

// --- 엔진 타겟: optional chaining ---

test "engine target: chrome90 → ?. 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "const x = a?.b;", &.{.{ .engine = .chrome, .major = 90 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

test "engine target: chrome91 → ?. 유지" {
    var r = try e2eEngine(std.testing.allocator, "const x = a?.b;", &.{.{ .engine = .chrome, .major = 91 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "?.") != null);
}

// --- 엔진 타겟: async/await ---

test "engine target: chrome54 → async 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "async function foo() { await x; }", &.{.{ .engine = .chrome, .major = 54 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__async") != null);
}

test "engine target: chrome55 → async 유지" {
    var r = try e2eEngine(std.testing.allocator, "async function foo() { await x; }", &.{.{ .engine = .chrome, .major = 55 }});
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "async") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "__async") == null);
}

// --- 엔진 타겟: 복합 타겟 교집합 ---

test "engine target: chrome91+safari13 → safari가 ?? 미지원이므로 다운레벨링" {
    // chrome91: ?? 지원 (80), safari13.0: ?? 미지원 (13.1부터)
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b;", &.{
        .{ .engine = .chrome, .major = 91 },
        .{ .engine = .safari, .major = 13, .minor = 0 },
    });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "!=null") != null);
}

test "engine target: chrome91+safari13.1 → 둘 다 ?? 지원, 유지" {
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b;", &.{
        .{ .engine = .chrome, .major = 91 },
        .{ .engine = .safari, .major = 13, .minor = 1 },
    });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "??") != null);
}

// --- 엔진 타겟: feature 독립성 (한 feature만 다운레벨링, 나머지 유지) ---

test "engine target: chrome80 → ??는 유지하지만 ?.는 다운레벨링" {
    var r = try e2eEngine(std.testing.allocator, "const x = a ?? b; const y = c?.d;", &.{
        .{ .engine = .chrome, .major = 80 },
    });
    defer r.deinit();
    // ?? (chrome80 지원) → 유지
    try std.testing.expect(std.mem.indexOf(u8, r.output, "??") != null);
    // ?. (chrome91 미만) → 다운레벨링
    try std.testing.expect(std.mem.indexOf(u8, r.output, "void 0") != null);
}

// --- 엔진 타겟: safari minor 버전 정밀도 ---

test "engine target: safari11.0 → object spread 미지원 (11.1부터)" {
    var r = try e2eEngine(std.testing.allocator, "const x = { ...obj };", &.{
        .{ .engine = .safari, .major = 11, .minor = 0 },
    });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Object.assign") != null);
}

test "engine target: safari11.1 → object spread 지원" {
    var r = try e2eEngine(std.testing.allocator, "const x = { ...obj };", &.{
        .{ .engine = .safari, .major = 11, .minor = 1 },
    });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...") != null);
}

// ============================================================
// JSX Runtime 모드 테스트
// ============================================================

test "JSX automatic: simple element" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div id=\"app\">hello</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: \"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "id: \"app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import { jsx as _jsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"react/jsx-runtime\"") != null);
}

test "JSX automatic: multiple children uses jsxs" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div><span>a</span><span>b</span></div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxs(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import { jsx as _jsx, jsxs as _jsxs") != null);
}

test "JSX automatic: fragment" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <><span>a</span><span>b</span></>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxs(_Fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Fragment as _Fragment") != null);
}

test "JSX automatic: key is separated from props" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <App key=\"k\" name=\"zts\" />;");
    defer r.deinit();
    // key는 3번째 인수로 분리
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{ name: \"zts\" }, \"k\"") != null);
    // key는 props에 없어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "key:") == null);
}

test "JSX automatic: self-closing no children" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <br />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"br\", {})") != null);
}

test "JSX automatic: custom import source" {
    var r = try e2eFull(std.testing.allocator, "const x = <div />;", .{
        .jsx_transform = true,
        .jsx_runtime = .automatic,
        .jsx_import_source = "preact",
    }, .{}, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"preact/jsx-runtime\"") != null);
}

test "JSX dev: source info included" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div>hello</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxDEV(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "fileName: \"test.tsx\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "lineNumber: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "columnNumber: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", this)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"react/jsx-dev-runtime\"") != null);
}

test "JSX dev: isStaticChildren true for multiple children" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div><a/><b/></div>;");
    defer r.deinit();
    // 다수 children → isStaticChildren = true
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", true, {") != null);
}

test "JSX dev: isStaticChildren false for single child" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <div><a/></div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", false, {") != null);
}

test "JSX classic: custom factory" {
    var r = try e2eFull(std.testing.allocator, "const x = <div />;", .{
        .jsx_transform = true,
        .jsx_factory = "h",
        .jsx_fragment = "Fragment",
    }, .{ .minify_whitespace = true }, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "h(\"div\"") != null);
    // React.createElement가 아닌 h 사용
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement") == null);
}

test "JSX classic: custom fragment factory" {
    var r = try e2eFull(std.testing.allocator, "const x = <>hello</>;", .{
        .jsx_transform = true,
        .jsx_factory = "h",
        .jsx_fragment = "Fragment",
    }, .{ .minify_whitespace = true }, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "h(Fragment,") != null);
}

// --- automatic 모드: 누락 케이스 ---

test "JSX automatic: spread attribute" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div {...props} id=\"a\" />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "id: \"a\"") != null);
}

test "JSX automatic: nested elements" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div><span><b>deep</b></span></div>;");
    defer r.deinit();
    // 바깥: 단일 child → _jsx, 안쪽도 단일 → _jsx
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"div\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"span\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: \"deep\"") != null);
}

test "JSX automatic: expression child" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <div>{value}</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: value") != null);
}

test "JSX automatic: text and element mixed children" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <p>hello <b>world</b></p>;");
    defer r.deinit();
    // 다수 children → _jsxs + children 배열
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxs(\"p\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"hello \"") != null);
}

test "JSX automatic: component (uppercase tag)" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <MyComponent title=\"t\">child</MyComponent>;");
    defer r.deinit();
    // 대문자 태그는 문자열이 아닌 식별자로 출력
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(MyComponent") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"MyComponent\"") == null);
}

test "JSX automatic: empty fragment" {
    var r = try e2eJSXAutomatic(std.testing.allocator, "const x = <></>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsx(_Fragment, {})") != null);
}

test "JSX automatic: classic mode does NOT inject import" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import {") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement") != null);
}

test "JSX automatic: no JSX usage means no import" {
    // JSX가 없는 파일에서는 import 미주입
    var r = try e2eFull(std.testing.allocator, "const x = 42;", .{
        .jsx_transform = true,
        .jsx_runtime = .automatic,
        .jsx_import_source = "react",
    }, .{}, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import {") == null);
}

// --- dev 모드: 누락 케이스 ---

test "JSX dev: key in dev mode" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <Item key=\"k\" id=\"1\" />;");
    defer r.deinit();
    // key는 3번째 인수, props에서 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "{ id: \"1\" }, \"k\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "key:") == null);
}

test "JSX dev: fragment with children" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <><a/><b/></>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxDEV(_Fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "children: [") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, ", true, {") != null);
}

test "JSX dev: empty element has correct source info" {
    var r = try e2eJSXDev(std.testing.allocator, "const x = <br />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "_jsxDEV(\"br\", {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "fileName: \"test.tsx\"") != null);
}

test "JSX dev: custom import source" {
    var r = try e2eFull(std.testing.allocator, "const x = <div />;", .{
        .jsx_transform = true,
        .jsx_runtime = .automatic_dev,
        .jsx_import_source = "preact",
        .jsx_filename = "app.tsx",
    }, .{}, ".tsx");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"preact/jsx-dev-runtime\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "fileName: \"app.tsx\"") != null);
}

// --- classic 모드: 누락 케이스 ---

test "JSX classic: spread attribute preserved" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div {...props} />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "...props") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement") != null);
}

test "JSX classic: expression child" {
    var r = try e2eJSX(std.testing.allocator, "const x = <div>{val}</div>;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement(\"div\",null,val)") != null);
}

test "JSX classic: component uppercase" {
    var r = try e2eJSX(std.testing.allocator, "const x = <App name=\"z\" />;");
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.createElement(App,{name:\"z\"})") != null);
    // App은 문자열이 아닌 식별자
    try std.testing.expect(std.mem.indexOf(u8, r.output, "\"App\"") == null);
}

// ============================================================
// None-node safety: transformer/codegen must not crash on .none NodeIndex
// These tests ensure Flow type stripping produces valid AST without
// index-out-of-bounds panics (previously crashed with index 4294967295).
// ============================================================

test "Flow: import typeof does not crash" {
    // import typeof * as Foo from './bar' — Flow type-only import, should be stripped
    var r = try e2eFlowModule(std.testing.allocator,
        \\import typeof * as Foo from './bar';
        \\console.log("hello");
    );
    defer r.deinit();
    // import typeof should be removed, only console.log remains
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "console.log") != null);
}

test "Flow: import typeof named does not crash" {
    var r = try e2eFlowModule(std.testing.allocator,
        \\import typeof { Foo, Bar } from './baz';
        \\export const x = 1;
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "import") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "x=1") != null);
}

test "Flow: type alias with object type does not crash codegen" {
    var r = try e2eFlowModule(std.testing.allocator,
        \\type Props = { name: string, age: number };
        \\const x = 42;
    );
    defer r.deinit();
    // Flow type alias should be stripped
    try std.testing.expect(std.mem.indexOf(u8, r.output, "Props") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "42") != null);
}

test "Flow: mixed import type and value import does not crash" {
    var r = try e2eFlowModule(std.testing.allocator,
        \\import typeof * as API from './api';
        \\import { useState } from 'react';
        \\const x = useState(0);
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "useState") != null);
}

test "Flow: class with typed methods does not crash transformer" {
    var r = try e2eFlowModule(std.testing.allocator,
        \\class Foo {
        \\  bar(x: string): number { return 1; }
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "class Foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "bar") != null);
}

// ============================================================
// Flow: component declaration → props destructuring
// ============================================================

test "Flow: component with ref → React.forwardRef" {
    var r = try e2eFlow(std.testing.allocator,
        \\component View(ref, ...props: any) {
        \\  return null;
        \\}
    );
    defer r.deinit();
    // component View(ref, ...props) →
    //   function View_withRef({...props}, ref) { ... }
    //   const View = React.forwardRef(View_withRef);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function View_withRef(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "React.forwardRef(View_withRef)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "const View") != null);
    // ref는 두 번째 파라미터
    try std.testing.expect(std.mem.indexOf(u8, r.output, "},ref)") != null or
        std.mem.indexOf(u8, r.output, "}, ref)") != null or
        std.mem.indexOf(u8, r.output, " },ref)") != null);
}

test "Flow: component without ref → plain function" {
    var r = try e2eFlow(std.testing.allocator,
        \\component Bar(name: string, age: number) {
        \\  return null;
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Bar(") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "forwardRef") == null);
}

test "Flow: component rest only → single param" {
    var r = try e2eFlow(std.testing.allocator,
        \\component Baz(...props: any) {
        \\  return null;
        \\}
    );
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.output, "function Baz(props)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "forwardRef") == null);
}

test "Flow: component param with type annotation stripped" {
    var r = try e2eFlow(std.testing.allocator,
        \\component Foo(name: string, count: number) {
        \\  return null;
        \\}
    );
    defer r.deinit();
    // 타입 어노테이션이 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "string") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "number") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "name:name") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "count:count") != null);
}

test "Flow: component param with default value" {
    var r = try e2eFlow(std.testing.allocator,
        \\component Foo(x: number = 42) {
        \\  return x;
        \\}
    );
    defer r.deinit();
    // default가 보존되어야 함
    try std.testing.expect(std.mem.indexOf(u8, r.output, "42") != null);
    // 타입 어노테이션은 제거
    try std.testing.expect(std.mem.indexOf(u8, r.output, "number") == null);
}

test "Flow: component param with complex type annotation" {
    var r = try e2eFlow(std.testing.allocator,
        \\component Bar(cb: (x: string) => void = defaultCb) {
        \\  return null;
        \\}
    );
    defer r.deinit();
    // 함수 타입 어노테이션 제거, default 보존
    try std.testing.expect(std.mem.indexOf(u8, r.output, "defaultCb") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "=> void") == null);
}

// ============================================================
