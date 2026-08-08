const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const types = @import("../types.zig");
const emitter = @import("../emitter.zig");
const ResolveCache = @import("../resolve_cache.zig").ResolveCache;
const ModuleGraph = @import("../graph.zig").ModuleGraph;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// JSX component patterns
// ============================================================

test "JSX: component composition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Header } from './Header';
        \\import { Footer } from './Footer';
        \\function App() { return <div><Header /><Footer /></div>; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "Header.tsx", "export function Header() { return <header>H</header>; }");
    try writeFile(tmp.dir, "Footer.tsx", "export function Footer() { return <footer>F</footer>; }");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Header") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Footer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<div>") == null);
}

/// `s[start..]` 앞쪽 공백을 건너뛰고 식별자 하나를 잘라 반환. 식별자로 시작하지 않으면 null
/// (JSX intrinsic 태그는 `_jsx("div", ...)` 처럼 문자열 리터럴이라 여기서 걸러진다).
fn identAfter(s: []const u8, start: usize) ?[]const u8 {
    const isPart = struct {
        fn f(c: u8) bool {
            return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '_' or c == '$';
        }
    }.f;
    var i = start;
    // 공백류 전부 skip — codegen 은 탭으로 들여쓰고 긴 호출을 줄바꿈할 수 있다. 탭을 빼먹으면
    // callee 추출이 null 로 떨어지고 호출자가 `orelse continue` 로 넘겨 검사가 조용히 무력화된다.
    while (i < s.len and (s[i] == ' ' or s[i] == '\n' or s[i] == '\t' or s[i] == '\r')) i += 1;
    if (i >= s.len) return null;
    const c0 = s[i];
    if ((c0 >= '0' and c0 <= '9') or !isPart(c0)) return null;
    var j = i;
    while (j < s.len and isPart(s[j])) j += 1;
    return s[i..j];
}

fn isIdentChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// `output` 안에 `name` 의 *선언* 이 있는지.
///
/// 두 형태를 인정한다:
///  1. 키워드 직후 — `function Root(`, `var Root`, `let/const/class Root`
///  2. 병합 선언자 — `var a = 1, Root = 2;` (decl coalescing #3417 / `--minify-syntax`).
///     `, Root` 만 보면 `f(a, Root)` 같은 호출 인자도 선언으로 오인하므로, 같은 줄에서 콤마보다
///     **앞에** var/let/const 가 있는지 역방향으로 확인한다. 이 구분이 없으면 가드가 약해지고,
///     반대로 2번을 빼면 정상 번들에서 "dangling" 오탐이 나 없는 버그를 쫓게 된다.
fn declaresName(output: []const u8, name: []const u8, buf: []u8) bool {
    const kws = [_][]const u8{ "function ", "var ", "let ", "const ", "class " };
    for (kws) |kw| {
        const pat = std.fmt.bufPrint(buf, "{s}{s}", .{ kw, name }) catch continue;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, output, from, pat)) |idx| {
            const after = idx + pat.len;
            if (after >= output.len or !isIdentChar(output[after])) return true;
            from = idx + 1;
        }
    }

    // 병합 선언자: `name` 을 온전한 단어로 찾고, 바로 앞이 (공백 무시) 콤마이며 같은 줄에서
    // 그보다 앞에 선언 키워드가 있으면 선언으로 인정. `, Root` / `,Root` 양쪽 표기 모두 커버.
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, output, from, name)) |idx| {
        from = idx + 1;
        const after = idx + name.len;
        if (after < output.len and isIdentChar(output[after])) continue;
        if (idx == 0) continue;
        var b = idx;
        while (b > 0 and (output[b - 1] == ' ' or output[b - 1] == '\t')) b -= 1;
        if (b == 0 or output[b - 1] != ',') continue;
        const line_start = if (std.mem.lastIndexOfScalar(u8, output[0..b], '\n')) |nl| nl + 1 else 0;
        const line_head = output[line_start .. b - 1];
        if (std.mem.indexOf(u8, line_head, "var ") != null or
            std.mem.indexOf(u8, line_head, "let ") != null or
            std.mem.indexOf(u8, line_head, "const ") != null) return true;
    }
    return false;
}

/// 모든 `_jsx(IDENT` / `_jsxs(IDENT` / `_jsxDEV(IDENT` 호출의 callee 가 선언돼 있는지.
/// provider 쪽 마커 grep 만으로는 "모듈은 살았지만 consumer 참조가 dangling" (#4560/#4564/#4566 류)
/// 을 못 잡으므로, 참조된 식별자마다 선언 존재를 확인한다.
fn allJsxCalleesDeclared(output: []const u8, buf: []u8) bool {
    const calls = [_][]const u8{ "_jsx(", "_jsxs(", "_jsxDEV(" };
    for (calls) |call| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, output, from, call)) |idx| {
            from = idx + call.len;
            const name = identAfter(output, from) orelse continue;
            if (!declaresName(output, name, buf)) {
                std.debug.print("\n[dangling] _jsx callee `{s}` 선언 없음\n", .{name});
                return false;
            }
        }
    }
    return true;
}

// (#4596) `import * as NS` 후 `NS.Root` 를 JSX 엘리먼트 이름으로만 쓰면 Root/Button export 가
// tree-shake 되고 출력엔 `_jsx(Root)` dangling 참조만 남아 ReferenceError 였다(named import 은 정상).
//
// 두 결함의 합이었다:
//  1. 합성 JSX runtime import 노드의 span 이 program root span (파일 전체) → `decl_ranges` 를
//     오염시켜 그 모듈의 모든 namespace 접근이 "import 선언 내부" 로 skip
//  2. `NamespaceAccessIndex` 가 `jsx_member_expression` 을 색인하지 않아 lowering 전 AST 에서
//     JSX 멤버 사용이 안 보임
//
// **`jsx_runtime` 이 `.classic` 이면 (1) 의 주입 자체가 없어 재현되지 않는다** — 이슈와 동일한
// `.automatic` 으로 고정해야 실제 가드가 된다(실측: classic 은 수정 전에도 통과).
test "JSX: namespace member (`<NS.X>`) keeps target export from tree-shaking (#4596)" {
    const cases = [_]struct { name: []const u8, rt: @import("../../codegen/codegen.zig").JsxRuntime, ext: []const u8 }{
        .{ .name = "automatic", .rt = .automatic, .ext = "react/jsx-runtime" },
        .{ .name = "automatic_dev", .rt = .automatic_dev, .ext = "react/jsx-dev-runtime" },
    };
    for (cases) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "app.tsx",
            \\import * as NS from './ns';
            \\export function App() { return <NS.Root><NS.Button>hi</NS.Button></NS.Root>; }
            \\console.log(App);
        );
        try writeFile(tmp.dir, "ns.tsx",
            \\export function Root(p: any) { return "NS_ROOT_MARKER_" + p.children; }
            \\export function Button(p: any) { return "NS_BTN_MARKER_" + p.children; }
            \\export function Unused(p: any) { return "NS_UNUSED_MARKER_" + p.children; }
        );

        const entry = try absPath(&tmp, "app.tsx");
        defer std.testing.allocator.free(entry);
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .jsx_runtime = c.rt,
            .external = &.{c.ext},
        });
        defer b.deinit();
        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        // 1) 두 컴포넌트 body 가 살아야 한다 (provider 쪽).
        try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_ROOT_MARKER_") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_BTN_MARKER_") != null);
        // 2) consumer 쪽 `_jsx(...)` callee 가 전부 선언돼 있어야 한다 (dangling 참조 금지).
        var buf: [128]u8 = undefined;
        try std.testing.expect(allJsxCalleesDeclared(result.output, &buf));
        // 3) 과보존 회귀 방지 — 안 쓴 export 는 여전히 제거돼야 한다.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_UNUSED_MARKER_") == null);
    }
}

// (#4596) 중첩 멤버 체인 `<NS.Grp.Item>` — 바깥 jsx_member 의 object 는 다시 jsx_member 라
// skip 되고 안쪽 노드가 NS→Grp 를 기록해야 한다. 이 규칙이 뒤집히면 `Item`(Grp 의 프로퍼티)을
// NS 의 export 로 잘못 기록하거나 아무것도 기록하지 않아, `<Icons.Group.Item/>` 같은 흔한 형태가
// dangling 이 된다.
test "JSX: nested namespace member chain (`<NS.A.B>`) keeps target export (#4596)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import * as NS from './ns';
        \\export function App() { return <NS.Grp.Item>hi</NS.Grp.Item>; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "ns.tsx",
        \\export const Grp = { Item: (p: any) => "NS_GRP_ITEM_MARKER_" + p.children };
        \\export function Unused(p: any) { return "NS_UNUSED_MARKER_" + p.children; }
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .jsx_runtime = .automatic,
        .external = &.{"react/jsx-runtime"},
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_GRP_ITEM_MARKER_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_UNUSED_MARKER_") == null);
}

test "JSX: RN dev default component import from directory index keeps target module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "Widget");
    try writeFile(tmp.dir, "app.tsx",
        \\import Widget from './Widget';
        \\export function App() { return <Widget label="ok" />; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "Widget/index.tsx",
        \\function Carousel(props: { data: string[] }) {
        \\  return <span>{props.data.length}</span>;
        \\}
        \\const Widget = (props: { label: string }) => {
        \\  const data = [props.label];
        \\  return <Carousel data={data} />;
        \\};
        \\export default Widget;
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .dev_mode = true,
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
        .strict_execution_order = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    if (std.mem.indexOf(u8, result.output, "const Widget") == null and
        std.mem.indexOf(u8, result.output, "Widget =") == null)
    {
        std.debug.print("\n=== output ===\n{s}\n=== /output ===\n", .{result.output});
    }
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Widget =") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var Widget = void 0") == null);
}

test "JSX: RN dev TSX generic component import keeps target module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "BannerCarousel");
    try writeFile(tmp.dir, "app.tsx",
        \\import BannerCarousel from './BannerCarousel';
        \\const data = [{ id: '1' }];
        \\export function App() {
        \\  return <BannerCarousel banners={data} />;
        \\}
        \\console.log(App);
    );
    try writeFile(tmp.dir, "BannerCarousel/index.tsx",
        \\interface Banner { id: string }
        \\interface Props { banners: Banner[] }
        \\function Carousel<T>(props: { data: T[] }) {
        \\  return <span>{props.data.length}</span>;
        \\}
        \\const BannerCarousel = ({ banners }: Props) => {
        \\  return <Carousel<Banner> data={banners} />;
        \\};
        \\export default BannerCarousel;
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .dev_mode = true,
        .jsx_runtime = .automatic_dev,
        .external = &.{"react/jsx-dev-runtime"},
        .strict_execution_order = true,
    });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    if (result.hasErrors() or
        std.mem.indexOf(u8, result.output, "BannerCarousel/index.tsx") == null or
        std.mem.indexOf(u8, result.output, "var BannerCarousel = void 0") != null)
    {
        std.debug.print("\n=== output ===\n{s}\n=== /output ===\n", .{result.output});
    }
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "BannerCarousel/index.tsx") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var BannerCarousel = void 0") == null);
}

test "JSX: component with props" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Button } from './Button';
        \\function App() { return <Button label="Click" />; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "Button.tsx",
        \\export function Button(props: any) {
        \\  return <button>{props.label}</button>;
        \\}
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Button") != null);
}

test "JSX: fragment syntax" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Item } from './Item';
        \\function List() { return <><Item /><Item /></>; }
        \\console.log(List);
    );
    try writeFile(tmp.dir, "Item.tsx", "export function Item() { return <li>item</li>; }");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Item") != null);
}

test "JSX: three self-closing siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { A } from './A';
        \\import { B } from './B';
        \\import { C } from './C';
        \\function App() { return <div><A /><B /><C /></div>; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "A.tsx", "export function A() { return <span>a</span>; }");
    try writeFile(tmp.dir, "B.tsx", "export function B() { return <span>b</span>; }");
    try writeFile(tmp.dir, "C.tsx", "export function C() { return <span>c</span>; }");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function A") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function B") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function C") != null);
}

test "JSX: nested self-closing inside open/close element" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><span><img /></span></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement") != null);
}

test "JSX: mixed self-closing and open/close siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><br /><p>text</p><hr /></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // br, p, hr 모두 createElement 호출로 변환
    const output = result.output;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, output, pos, "createElement")) |p| {
        count += 1;
        pos = p + 1;
    }
    // div + br + p + hr = 최소 4개 createElement
    try std.testing.expect(count >= 4);
}

test "JSX: expression container between self-closing siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><br />{42}<hr /></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "JSX: deeply nested components" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><section><article><p>deep</p></article></section></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"deep\"") != null);
}

test "JSX: self-closing with attributes between siblings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><input type="text" /><input type="password" /><button>go</button></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"password\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"go\"") != null);
}

test "JSX: component with children + self-closing sibling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <div><p>hello</p><br /><p>world</p></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"world\"") != null);
}

test "JSX: fragment with mixed children types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <><h1>title</h1>{42}<br /><p>body</p></>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"title\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"body\"") != null);
}

test "JSX: nested components with props and children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Card } from './Card';
        \\import { Badge } from './Badge';
        \\function App() { return <div><Card title="hello"><Badge count={3} /><p>content</p></Card></div>; }
        \\console.log(App);
    );
    try writeFile(tmp.dir, "Card.tsx", "export function Card(props) { return <div>{props.children}</div>; }");
    try writeFile(tmp.dir, "Badge.tsx", "export function Badge(props) { return <span>{props.count}</span>; }");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Card") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Badge") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"hello\"") != null);
}

test "JSX: five siblings stress test" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <ul><li>1</li><li>2</li><li>3</li><li>4</li><li>5</li></ul>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    for ([_][]const u8{ "\"1\"", "\"2\"", "\"3\"", "\"4\"", "\"5\"" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
}

test "JSX: conditional expression inside element" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App(props) { return <div>{props.show ? <span>yes</span> : <span>no</span>}</div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"yes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"no\"") != null);
}

test "JSX: spread attributes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App(props) { return <div {...props}><span>child</span></div>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"child\"") != null);
}

test "JSX: self-closing after text content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\function App() { return <p>hello<br />world</p>; }
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "createElement") != null);
}

// ============================================================
// Complex TypeScript: type guards, mapped types, overloads, tuples
// ============================================================

test "TypeScript: type guard function" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { isString } from './guards';
        \\const x: unknown = 'hello';
        \\if (isString(x)) console.log(x.length);
    );
    try writeFile(tmp.dir, "guards.ts",
        \\export function isString(val: unknown): val is string {
        \\  return typeof val === 'string';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function isString") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "val is string") == null);
}

test "TypeScript: overloaded function stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { format } from './format';
        \\console.log(format(42));
    );
    try writeFile(tmp.dir, "format.ts",
        \\export function format(val: number): string;
        \\export function format(val: string): string;
        \\export function format(val: any): string {
        \\  return String(val);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function format") != null);
}

// ============================================================
// Complex deconflicting
// ============================================================

test "Deconflict: imported name shadowed in nested scope" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { data } from './data';
        \\function process() {
        \\  const data = 'local';
        \\  return data;
        \\}
        \\console.log(data, process());
    );
    try writeFile(tmp.dir, "data.ts", "export const data = 'module';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"module\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"local\"") != null);
}

test "Deconflict: seven modules same name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a'; import './b'; import './c';
        \\import './d'; import './e'; import './f';
        \\const handler = 'entry';
        \\console.log(handler);
    );
    try writeFile(tmp.dir, "a.ts", "const handler = 'a'; console.log(handler);");
    try writeFile(tmp.dir, "b.ts", "const handler = 'b'; console.log(handler);");
    try writeFile(tmp.dir, "c.ts", "const handler = 'c'; console.log(handler);");
    try writeFile(tmp.dir, "d.ts", "const handler = 'd'; console.log(handler);");
    try writeFile(tmp.dir, "e.ts", "const handler = 'e'; console.log(handler);");
    try writeFile(tmp.dir, "f.ts", "const handler = 'f'; console.log(handler);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    var rename_count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "handler$")) |pos| {
        rename_count += 1;
        sf = pos + 1;
    }
    try std.testing.expect(rename_count >= 6);
}

// ============================================================
// Re-export advanced
// ============================================================

test "Re-export: rename chain (A→B→C→D)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { z } from './c';
        \\console.log(z);
    );
    try writeFile(tmp.dir, "c.ts", "export { y as z } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x as y } from './a';");
    try writeFile(tmp.dir, "a.ts", "export const x = 'renamed-three-times';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"renamed-three-times\"") != null);
}

test "Re-export: overlapping export * names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y, z } from './barrel';
        \\console.log(x, y, z);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './a';
        \\export * from './b';
    );
    try writeFile(tmp.dir, "a.ts", "export const x = 'from-a';\nexport const y = 'from-a';");
    try writeFile(tmp.dir, "b.ts", "export const x = 'from-b';\nexport const z = 'from-b';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // (#3982) x 는 a/b 양쪽에서 export * 로 도달 → ESM spec 상 ambiguous → named
    // import 는 build error(esbuild/rolldown/Node 동형). y(a만)·z(b만)는 정상.
    try std.testing.expect(result.hasErrors());
    var found_ambiguous = false;
    if (result.diagnostics) |diags| {
        for (diags) |d| {
            if (d.code == .ambiguous_export) {
                found_ambiguous = true;
                break;
            }
        }
    }
    try std.testing.expect(found_ambiguous);
}

// ============================================================
// Real-world patterns: CLI, validation, i18n
// ============================================================

test "Real-world: CLI tool pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "cli.ts",
        \\import { parseArgs } from './args';
        \\import { runCommand } from './commands';
        \\import { VERSION } from './version';
        \\const args = parseArgs();
        \\if (args.version) console.log(VERSION);
        \\else runCommand(args);
    );
    try writeFile(tmp.dir, "args.ts", "export function parseArgs() { return { version: false, command: 'help' }; }");
    try writeFile(tmp.dir, "commands.ts",
        \\import { log } from './logger';
        \\export function runCommand(args: any) { log('Running: ' + args.command); }
    );
    try writeFile(tmp.dir, "logger.ts", "export function log(msg: string) { console.log('[CLI]', msg); }");
    try writeFile(tmp.dir, "version.ts", "export const VERSION = '3.1.4';");

    const entry = try absPath(&tmp, "cli.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    for ([_][]const u8{ "function parseArgs", "function runCommand", "function log", "\"3.1.4\"" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
}

test "Real-world: validation library" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { validate, isEmail, minLength } from './validator';
        \\const ok = validate('test@email.com', [isEmail, minLength(5)]);
        \\console.log(ok);
    );
    try writeFile(tmp.dir, "validator/index.ts",
        \\export { validate } from './core';
        \\export { isEmail } from './rules/email';
        \\export { minLength } from './rules/length';
    );
    try writeFile(tmp.dir, "validator/core.ts", "export function validate(v: string, rules: Function[]) { return rules.every(r => r(v)); }");
    try writeFile(tmp.dir, "validator/rules/email.ts", "export function isEmail(v: string) { return v.includes('@'); }");
    try writeFile(tmp.dir, "validator/rules/length.ts", "export function minLength(n: number) { return (v: string) => v.length >= n; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function validate") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function isEmail") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function minLength") != null);
}

// ============================================================
// Edge cases: unusual but valid JS
// ============================================================

test "Edge: void operator across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { noop } from './utils';
        \\noop();
    );
    try writeFile(tmp.dir, "utils.ts", "export function noop() { return void 0; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "void 0") != null);
}

test "Edge: typeof imported value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { maybe } from './maybe';
        \\console.log(typeof maybe);
    );
    try writeFile(tmp.dir, "maybe.ts", "export const maybe = undefined;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "typeof") != null);
}

test "Edge: instanceof with imported class" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Animal } from './animal';
        \\const a = new Animal();
        \\console.log(a instanceof Animal);
    );
    try writeFile(tmp.dir, "animal.ts", "export class Animal {}");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "instanceof") != null);
}

test "Edge: labeled statement across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { search } from './search';
        \\console.log(search([[1, 2], [3, 4]], 3));
    );
    try writeFile(tmp.dir, "search.ts",
        \\export function search(matrix: number[][], target: number) {
        \\  outer: for (const row of matrix) {
        \\    for (const val of row) {
        \\      if (val === target) break outer;
        \\    }
        \\  }
        \\  return false;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function search") != null);
}

test "Edge: comma operator in export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { result } from './comma';
        \\console.log(result);
    );
    try writeFile(tmp.dir, "comma.ts", "export const result = (1, 2, 3);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

// ============================================================
// Stress: extreme patterns
// ============================================================

test "Stress: MVC 7-module framework" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.ts",
        \\import { App } from './framework/app';
        \\import { UserModel } from './models/user';
        \\import { UserView } from './views/user';
        \\const app = new App();
        \\const model = new UserModel();
        \\const view = new UserView();
        \\console.log(app, model, view);
    );
    try writeFile(tmp.dir, "framework/app.ts",
        \\import { Router } from './router';
        \\export class App { router = new Router(); }
    );
    try writeFile(tmp.dir, "framework/router.ts", "export class Router { routes: string[] = []; }");
    try writeFile(tmp.dir, "models/user.ts",
        \\import { BaseModel } from './base';
        \\export class UserModel extends BaseModel { table = 'users'; }
    );
    try writeFile(tmp.dir, "models/base.ts", "export class BaseModel { id = 0; }");
    try writeFile(tmp.dir, "views/user.ts",
        \\import { BaseView } from './base';
        \\export class UserView extends BaseView { template = '<div/>'; }
    );
    try writeFile(tmp.dir, "views/base.ts", "export class BaseView { el = 'body'; }");

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    for ([_][]const u8{ "class App", "class Router", "class UserModel", "class BaseModel", "class UserView", "class BaseView" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
}

test "JSX: @jsx pragma + automatic runtime → warning diagnostic (D026)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 프로젝트는 automatic 인데 파일에 classic factory pragma — factory 가 무시됨.
    try writeFile(tmp.dir, "app.tsx",
        \\/** @jsx h */
        \\export const App = () => <p>x</p>;
        \\console.log(App);
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .jsx_runtime = .automatic });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    // (react/jsx-runtime 미설치라 resolve error 도 같이 나지만) jsx_pragma_ignored warning 은 와야 함.
    var has_pragma_warning = false;
    for (result.getDiagnostics()) |d| {
        if (d.code == .jsx_pragma_ignored and d.severity == .warning) {
            has_pragma_warning = true;
            break;
        }
    }
    try std.testing.expect(has_pragma_warning);
}

/// preserve 출력의 JSX 태그 root 가 모두 선언돼 있는지. `<NS.Root>` / `<NS>` 형태를 훑는다.
/// preserve 경로엔 `_jsx(` 가 아예 없으므로 `allJsxCalleesDeclared` 로는 검사되지 않는다 —
/// 이 검사가 없으면 "태그는 남고 선언은 없는" #4596 회귀가 마커 단언만으로 green 하게 통과한다.
fn allJsxTagRootsDeclared(output: []const u8, buf: []u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, output, from, '<')) |lt| {
        from = lt + 1;
        if (lt + 1 >= output.len) break;
        const name = identAfter(output, lt + 1) orelse continue;
        // 소문자 시작 = intrinsic element (`<div>`) — 값 참조가 아니다.
        if (name[0] >= 'a' and name[0] <= 'z') continue;
        if (!declaresName(output, name, buf)) {
            std.debug.print("\n[dangling] JSX 태그 root `{s}` 선언 없음\n", .{name});
            return false;
        }
    }
    return true;
}

// (#4596) `jsx_runtime = .preserve` — JSX 가 link 시점까지 원형으로 남는 유일한 경로.
// 여기선 `NamespaceAccessIndex` 의 JSX 색인이 tree-shake 판단의 유일한 근거다(lowering 이 없어
// static_member 로 회수될 기회가 없음). 세 가지를 함께 단언한다:
//   1. 멤버로 쓴 export 는 살아야 한다
//   2. 안 쓴 export 는 제거돼야 한다 (정밀도)
//   3. **남은 JSX 태그 root 가 선언돼 있어야 한다** — codegen 은 preserve JSX 의 멤버를
//      재작성하지 않으므로 namespace 객체가 실체화돼야 한다. 이 단언이 없으면
//      `isNamespaceUsedAsValue` 에 JSX arm 을 넣어 force_inline 을 켜는 순간
//      `<NS.Root>` 만 남고 `NS` 선언이 사라지는 회귀가 green 하게 통과한다.
test "JSX: preserve runtime — namespace member drives tree-shaking precisely (#4596)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import * as NS from './ns';
        \\export function App() { return <NS.Root>hi</NS.Root>; }
        \\console.log(NS.helper());
        \\console.log(App);
    );
    try writeFile(tmp.dir, "ns.tsx",
        \\export function Root(p: any) { return "NS_ROOT_MARKER_" + p.children; }
        \\export function helper() { return "NS_HELPER_MARKER_"; }
        \\export function Unused(p: any) { return "NS_UNUSED_MARKER_" + p.children; }
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .jsx_runtime = .preserve });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_ROOT_MARKER_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_HELPER_MARKER_") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_UNUSED_MARKER_") == null);
    // JSX 가 원형으로 남았음을 확인한 뒤(전제 검증) 태그 root 선언을 단언.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<") != null);
    var buf: [128]u8 = undefined;
    try std.testing.expect(allJsxTagRootsDeclared(result.output, &buf));
}

// (#4596) bare `<NS/>` (namespace 자체를 JSX 값 위치에 전달) 의 escape 감지는 **번들 레벨에서
// 가드할 수 없다** — 대문자로 시작하는 namespace local 이면 linker 의 symbol-aware 경로가
// `prop_by_obj` 에 없는 태그 root 를 보고 독립적으로 opaque 를 반환해 전체를 보존하기 때문이다.
// 실측: `NamespaceAccessIndex` 의 `jsx_element` escape 브랜치를 무력화해도 번들 출력이 동일했다.
// 따라서 이 브랜치의 가드는 text-only 경로를 직접 찌르는 유닛 테스트가 담당한다 —
// `linker/namespace_access_test.zig` 의 "bare JSX namespace tag (`<NS/>`) is an escape → opaque".
// (여기에 번들 테스트를 두면 브랜치를 지워도 green 인 공허한 가드가 된다.)

// (#4599) `jsx: preserve` 에서 실체화된 namespace 변수가 **JSX 태그 자리**에 그대로 남는데,
// 이름이 소문자로 시작하면 downstream 툴이 **intrinsic 태그**(문자열)로 바꾼다:
// `<ns_ns>` → `jsx("ns_ns", …)`. 컴포넌트가 실행되지 않고 알 수 없는 DOM 엘리먼트가 마운트되며
// 에러도 나지 않는다. esbuild 로 실측 확인 — 수정 전 `jsx("ns_ns", …)`, 수정 후 `jsx(Ns_ns, …)`.
//
// base 는 모듈 파일명에서 오므로(`ns.tsx` → `ns`) 소문자 모듈명이면 항상 걸린다.
test "JSX: preserve — 실체화된 namespace 변수는 컴포넌트로 해석되는 이름이어야 (#4599)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import * as NS from './ns';
        \\export function Raw() { return <NS>x</NS>; }
        \\export function Member() { return <NS.Root/>; }
    );
    try writeFile(tmp.dir, "ns.tsx",
        \\export const Root = () => null;
        \\export const Other = () => null;
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .jsx_runtime = .preserve });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 전제 검증 — JSX 가 원형으로 남았고 namespace 가 실체화됐는지 먼저 확인한다.
    // 이게 없으면 (실체화가 아예 안 되는 회귀에서도) 아래 단언이 공허하게 통과한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "_ns = {get Root()") != null);

    // 소문자로 시작하는 태그가 남아 있으면 안 된다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<ns_ns>") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Ns_ns") != null);
}

test "JSX: 소문자로 시작하지 않는 bare 태그는 변수 참조로 잡힌다 (#4599 잔여)" {
    // `<_ns/>` 처럼 밑줄/달러로 시작하는 태그는 intrinsic 이 아니라 **식별자**다
    // (babel·tsc·esbuild 공통 관례). analyzer 가 `isUpper` 로만 resolve 하면 이 참조가
    // 안 잡혀 대상 import 가 통째로 tree-shake 되고, **선언 없는 `<_ns/>` 가 방출**된다.
    // esbuild 실측: namespace 를 살려 `<Ns_exports />` 로 재작성한다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import * as _ns from './ns';
        \\export function Raw() { return <_ns/>; }
    );
    try writeFile(tmp.dir, "ns.tsx",
        \\export const Root = () => null;
        \\export const Other = "NS_OTHER_MARKER";
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .jsx_runtime = .preserve });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 대상 모듈이 살아 있어야 한다 (tree-shake 되면 이 마커가 사라진다).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "NS_OTHER_MARKER") != null);
    // 실체화된 이름은 컴포넌트로 해석되도록 대문자 시작.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Ns_ns") != null);
}

test "JSX: 소문자 시작 태그는 intrinsic 으로 남는다 (#4599 범위 가드)" {
    // 위 수정이 과하면(모든 bare 태그를 resolve) `<div>` 가 변수 참조가 돼
    // 없는 심볼을 찾거나 동명 로컬에 잘못 묶인다. 이 대조군이 그걸 막는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\export function A() { return <div>hi</div>; }
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .jsx_runtime = .preserve });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<div>hi</div>") != null);
}

// 대조군 — preserve 가 아니면 이름을 건드리지 않는다. 변수는 식별자 표현식으로만 쓰여
// 대소문자가 무의미한데, 전역으로 바꾸면 기존 출력의 변수명이 통째로 흔들린다.
// 이 테스트가 없으면 "항상 대문자화" 로 바꿔도 위 테스트가 통과해 범위 가드가 사라진다.
test "JSX: classic 런타임에서는 namespace 변수명을 바꾸지 않는다 (#4599 범위 가드)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import * as NS from './ns';
        \\export const v = NS;
    );
    try writeFile(tmp.dir, "ns.tsx", "export const Root = () => null;\n");

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);
    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .jsx_runtime = .classic });
    defer b.deinit();
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ns_ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Ns_ns") == null);
}
