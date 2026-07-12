//! Regression: ES2015 block scoping lowering 시 `block_rename_stack` 가 inner `let` 을
//! `name$N` 으로 rename 하면, identifier_reference / binding_identifier 분기는
//! rename 을 적용하는데 **`assignment_target_identifier` 분기가 누락** 되어 있었음.
//! 결과: `acc = acc + n` 이 `acc = acc$1 + n` 으로 변환 (LHS 만 rename 누락) →
//! strict-mode 에서 free variable `acc` 참조 → ReferenceError.
//!
//! 실제 사례: bungae + RN 환경의 `whatwg-url-minimum.mjs` `serializePath`:
//! ```js
//! let t = "";
//! for (const r of e.path) { t += `/${r}`; }
//! ```
//! `t` 는 module-scope 의 다른 `t` 와 충돌해 `t$82` 로 rename. for body 의 `t += ...`
//! 의 좌변이 누락되어 `t += "/" + r` 그대로 emit → ReferenceError.

const std = @import("std");
const testing = std.testing;
const helpers = @import("../test_helpers.zig");
const compat = @import("../../transformer/compat.zig");
const writeFile = helpers.writeFile;

/// fn 정의 한 개의 body 만 잘라낸다 — `function <sig>` ~ `return <ret>` 까지.
/// 그 다음 정의로 spill 하지 않도록 trailing slack 없이 정확히 자른다.
fn fnBody(code: []const u8, sig: []const u8, ret_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, code, sig) orelse return null;
    const ret_idx = std.mem.indexOfPos(u8, code, start, ret_marker) orelse return null;
    return code[start .. ret_idx + ret_marker.len];
}

fn bundleEntry(backing: std.mem.Allocator, tmp: *std.testing.TmpDir, entry_name: []const u8) !helpers.Bundled {
    // RN/Hermes 환경 시뮬레이션: block_scoping (let → var) 강제 lowering.
    return helpers.bundleEntry(backing, tmp, entry_name, .{
        .dev_mode = true,
        .unsupported = compat.UnsupportedFeatures{ .block_scoping = true },
    });
}

// outer module-scope `let acc` + inner function-scope `let acc` → block_rename_stack
// 가 inner 를 `acc$1` 으로 rename. for-loop body 의 `acc = acc + i` 좌변/우변 모두
// `acc$1` 으로 일관 rename 되어야.
test "rename leak: assignment LHS 가 block-rename suffix 적용됨 (compound for-loop)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\let acc = "module-level";
        \\export function sum(n) {
        \\  let acc = 0;
        \\  for (let i = 0; i < n; i++) {
        \\    acc = acc + i;
        \\  }
        \\  return acc;
        \\}
        \\export function getModuleAcc() { return acc; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { sum, getModuleAcc } from './lib.js';
        \\sum(3); getModuleAcc();
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // `var acc$1 = 0` 정의 + `acc$1 = acc$1 + i` 로 양쪽 rename. 좌변 `acc =` (suffix 없음) 가
    // 함수 body 안에 있으면 BUG.
    const body = fnBody(code, "function sum(n)", "return acc") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, body, "var acc$1 = 0") != null);
    try testing.expect(std.mem.indexOf(u8, body, "acc = acc$1 + i") == null);
    try testing.expect(std.mem.indexOf(u8, body, "acc$1 = acc$1 + i") != null);
}

// for-of + template literal 조합 (실제 whatwg-url-minimum.mjs 패턴).
test "rename leak: for-of body 의 template literal compound assign 도 일관 rename" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\let t = "module-level";
        \\export function serializePath(e) {
        \\  let t = "";
        \\  for (const r of e.path) {
        \\    t += `/${r}`;
        \\  }
        \\  return t;
        \\}
        \\export function getModuleT() { return t; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { serializePath, getModuleT } from './lib.js';
        \\serializePath({ path: ['a', 'b'] }); getModuleT();
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    const body = fnBody(code, "function serializePath(e)", "return t") orelse return error.TestUnexpectedResult;
    // 정의 + compound assign 좌변 모두 `t$1` suffix.
    // 좌변 `t +=` (suffix 없음) 검색은 substring 매칭이 식별자 경계를 자동으로 인식 —
    // `t$1 += ` 는 `t += ` 와 매칭되지 않으므로 indexOf 만으로 충분.
    try testing.expect(std.mem.indexOf(u8, body, "var t$1 = \"\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "t$1 += ") != null);
    try testing.expect(std.mem.indexOf(u8, body, "t += ") == null);
}

test "rename leak: for-of header binding 이 outer 함수 이름을 덮지 않음" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\export function matchKeys(n, s, c) {
        \\  let o = (item, expected, check) => check(item, expected);
        \\  let values = [];
        \\  for (const o of n.keys()) {
        \\    values.push(n[o]);
        \\  }
        \\  return values.every((item, index) => o(item, s[index], c));
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { matchKeys } from './lib.js';
        \\matchKeys([1], [1], (a, b) => a === b);
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // ts-pattern 실제 패턴: `for (const o of n.keys())` 가 `var o` 로 내려가면
    // 뒤의 `o(...)` 호출까지 숫자 loop key 를 바라봐 `1 is not a function` 이 된다.
    try testing.expect(std.mem.indexOf(u8, code, "for (var o of") == null);
    try testing.expect(std.mem.indexOf(u8, code, "for (var o$") != null);
}

test "rename leak: for header binding 이 outer 함수 이름을 덮지 않음" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\export function visit(values) {
        \\  let i = (value) => value;
        \\  for (let i = 0; i < values.length; i++) {
        \\    values[i] = values[i] + 1;
        \\  }
        \\  return values.map((value) => i(value));
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { visit } from './lib.js';
        \\visit([1]);
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();
    const body = fnBody(code, "function visit(values)", "return values.map") orelse return error.TestUnexpectedResult;

    try testing.expect(std.mem.indexOf(u8, body, "for (var i = 0;") == null);
    try testing.expect(std.mem.indexOf(u8, body, "for (var i$") != null);
}

test "rename leak: object shorthand 는 block-rename 된 value 로 확장됨" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\let routes = "module-level";
        \\export function derive(cond, state, props) {
        \\  if (cond) {
        \\    let routes = state.routes;
        \\    let previousRoutes = state.previousRoutes;
        \\    let descriptors = props.descriptors;
        \\    let previousDescriptors = state.previousDescriptors;
        \\    return { routes, previousRoutes, descriptors, previousDescriptors };
        \\  }
        \\  let routes = props.routes;
        \\  return { routes };
        \\}
        \\export function getModuleRoutes() { return routes; }
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { derive, getModuleRoutes } from './lib.js';
        \\derive(true, { routes: ['a'], previousRoutes: [], previousDescriptors: {} }, { routes: ['b'], descriptors: {} });
        \\getModuleRoutes();
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    try testing.expect(std.mem.indexOf(u8, code, "routes: routes$") != null);
    try testing.expect(std.mem.indexOf(u8, code, "return { routes, previousRoutes") == null);
}

// 충돌 없는 단일 let 은 rename 없이 유지 (over-fix 방지).
test "rename leak: 충돌 없는 let 은 suffix 없이 그대로" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "lib.js",
        \\export function lonely(n) {
        \\  let counter = 0;
        \\  for (let i = 0; i < n; i++) {
        \\    counter = counter + i;
        \\  }
        \\  return counter;
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { lonely } from './lib.js';
        \\lonely(3);
    );

    var r = try bundleEntry(testing.allocator, &tmp, "entry.js");
    defer r.deinit();
    const code = r.code();

    // suffix 없는 base 이름 유지
    try testing.expect(std.mem.indexOf(u8, code, "var counter = 0") != null);
    try testing.expect(std.mem.indexOf(u8, code, "counter = counter + i") != null);
    // suffix 가 붙은 변형이 있으면 over-fix
    try testing.expect(std.mem.indexOf(u8, code, "counter$") == null);
}

// ============================================================
// #4468 — class static block 이 AST 로 emit 되지 않아 생긴 누수
// ============================================================
//
// 근본: codegen 의 emitStaticBlock 이 non-minify 경로에서 `writeNodeSpan` 으로
// **소스 원문을 그대로 복사**했다 → static block 안에서는 AST 에 가해진 모든 변형
// (deconflict rename, --define 치환, TS/JSX transform, 다운레벨)이 통째로 유실됐다.

test "#4468 static block: 클래스 자기참조가 deconflict rename 을 따라간다 (프로덕션 경로)" {
    // monaco-editor 의 vs/base/common/linkedList.js 패턴.
    // 전역 `Node`(DOM) 때문에 두 클래스가 모두 rename 되는데, static block 안의
    // 자기참조만 옛 이름으로 남으면 → 번들에 `Node` 선언이 없으므로 그 참조가
    // **전역 DOM Node 를 탈취** → `new Node()` = TypeError: Illegal constructor.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js",
        \\export class Node {
        \\  static { this.Undefined = new Node("from-a"); }
        \\  constructor(v) { this.v = v; }
        \\}
    );
    try writeFile(tmp.dir, "b.js",
        \\export class Node { constructor(k) { this.k = k; } }
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { Node as A } from './a.js';
        \\import { Node as B } from './b.js';
        \\console.log(Node.ELEMENT_NODE);
        \\console.log(A.Undefined.v, new B("x").k);
    );

    // 파일 로컬 bundleEntry 래퍼는 dev_mode + block_scoping 을 강제한다 — monaco 가
    // 깨진 건 그냥 `zntc build`(기본 옵션) 였으므로 그 경로를 그대로 탄다.
    var r = try helpers.bundleEntry(testing.allocator, &tmp, "entry.js", .{});
    defer r.deinit();
    const code = r.code();

    // 두 클래스 모두 rename 됐어야 한다 (전역 Node 가 이름을 예약).
    try testing.expect(std.mem.indexOf(u8, code, "class Node$1") != null);
    try testing.expect(std.mem.indexOf(u8, code, "class Node$2") != null);

    // 핵심: static block 안의 자기참조가 rename 을 따라가야 한다.
    // `new Node(` 가 남아 있으면 전역 DOM Node 로 해석돼 런타임 크래시.
    try testing.expect(std.mem.indexOf(u8, code, "new Node(") == null);
    try testing.expect(std.mem.indexOf(u8, code, "new Node$1(") != null);
}

test "#4468 static block: --define 치환이 블록 안에서도 적용된다" {
    // static block 이 소스 복사되면 `__MODE__` 가 그대로 남아 런타임 ReferenceError.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.js",
        \\class C {
        \\  static { this.mode = __MODE__; }
        \\  static viaField = __MODE__;
        \\}
        \\console.log(C.mode, C.viaField);
    );

    var r = try helpers.bundleEntry(testing.allocator, &tmp, "entry.js", .{
        .define = &[_]@import("../../transformer/transformer.zig").DefineEntry{
            .{ .key = "__MODE__", .value = "\"prod\"" },
        },
    });
    defer r.deinit();
    const code = r.code();

    // 필드 초기화자와 static block 양쪽 모두 치환돼야 한다.
    try testing.expect(std.mem.indexOf(u8, code, "__MODE__") == null);
    try testing.expect(std.mem.indexOf(u8, code, "this.mode = \"prod\"") != null);
}

test "#4468 static block: --minify-identifiers 경로에서도 rename 을 따라간다" {
    // 옛 span-copy 게이트는 `minify_whitespace AND minify_syntax` 였다 — 즉
    // `--minify-identifiers` 만 켠 빌드도 원문 복사 경로를 탔고, 클래스가 `a` 로
    // mangle 되는 동안 static block 은 `new Node(...)` 를 그대로 들고 있었다.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.js",
        \\export class Node {
        \\  static { this.Undefined = new Node("from-a"); }
        \\  constructor(v) { this.v = v; }
        \\}
    );
    try writeFile(tmp.dir, "entry.js",
        \\import { Node as A } from './a.js';
        \\console.log(Node.ELEMENT_NODE, A.Undefined.v);
    );

    var r = try helpers.bundleEntry(testing.allocator, &tmp, "entry.js", .{
        .minify_identifiers = true,
    });
    defer r.deinit();
    const code = r.code();

    // mangle 된 클래스 이름이 static block 안에서도 동일하게 쓰여야 한다.
    // 원본 이름 `new Node(` 가 남아 있으면 전역 DOM Node 로 해석돼 크래시.
    try testing.expect(std.mem.indexOf(u8, code, "new Node(") == null);
}

// ============================================================
// #4470 — `--jsx=preserve` + `--bundle` 시 JSX 태그 이름이 rename 을 따라간다
// ============================================================

test "#4470 preserve: JSX 엘리먼트/member 태그가 deconflict rename 을 따라간다" {
    // scope hoisting 후 import local 이름(`A`/`B`)은 번들에 존재하지 않는다.
    // JSX 태그가 그 이름을 그대로 들고 있으면 downstream 변환 결과가
    // `ReferenceError: A is not defined`.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.jsx", "export const Widget = { Panel: () => null };");
    try writeFile(tmp.dir, "b.jsx", "export const Widget = { Panel: () => null };");
    try writeFile(tmp.dir, "entry.jsx",
        \\import { Widget as A } from './a.jsx';
        \\import { Widget as B } from './b.jsx';
        \\export const p = <A x={1} />;
        \\export const q = <B.Panel y={2} />;
    );

    var r = try helpers.bundleEntry(testing.allocator, &tmp, "entry.jsx", .{
        .jsx_runtime = .preserve,
    });
    defer r.deinit();
    const code = r.code();

    // 두 Widget 이 deconflict 됐어야 한다.
    try testing.expect(std.mem.indexOf(u8, code, "Widget$1") != null);
    // 태그가 번들에 없는 import local 이름을 참조하면 BUG.
    try testing.expect(std.mem.indexOf(u8, code, "<A ") == null);
    try testing.expect(std.mem.indexOf(u8, code, "<B.") == null);
    // 실제 심볼을 가리켜야 한다.
    try testing.expect(std.mem.indexOf(u8, code, "<Widget ") != null);
    try testing.expect(std.mem.indexOf(u8, code, ".Panel") != null);
}
