//! #2869 — runtime helper symbol-bound reference 회귀 가드.
//!
//! 사용자가 transformer 가 emit 하는 runtime helper 와 동일한 이름 (`__extends`,
//! `__classCallCheck` 등) 을 module top-level local 로 선언해도, helper call site 가
//! user binding 으로 잘못 resolve 되어 런타임 TypeError 가 발생하지 않아야 한다.
//!
//! 표준 (esbuild/swc/rollup/babel) 은 helper 호출을 symbol-bound reference 로 emit.
//! ZNTC 는 transformer 가 helper marker 를 sidecar 에 기록 → resync analyzer 가 user
//! scope 와 격리된 helper_scope_map 으로 binding → call site 의 sym_id 가 helper
//! import binding 을 가리킨다.

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;
const compat_mod = @import("../../transformer/compat.zig");

test "Runtime helper shadow: user `var __extends` 가 helper call binding 을 가리키지 않음" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // entry 가 helper 와 동일 이름 local 을 선언 + class extends 로 helper 사용.
    // 이슈 #2869 의 minimal repro.
    try writeFile(tmp.dir, "entry.ts",
        \\import { A } from './a';
        \\const __extends = "shadow";
        \\console.log(__extends);
        \\console.log(new A());
    );
    try writeFile(tmp.dir, "a.ts",
        \\export class A extends Object {}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        // ES5 target → class extends 가 `__extends(...)` 호출로 lower → helper import
        // 가 prepend → user `__extends` 와 동일 이름 collision 시나리오 활성.
        .unsupported = compat_mod.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // helper 정의가 함수 형태로 emit 되었는지 (declaration 보존 — #2866 회귀 가드).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function __extends") != null or
        std.mem.indexOf(u8, result.output, "var __extends = function") != null);

    // user 의 "shadow" string literal 이 보존되어야 함 (의미 보존).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"shadow\"") != null);

    // 핵심: helper 호출 (`__extends(A, _super)` 또는 rename 결과) 이 user 의 string
    // literal 을 함수 호출로 사용하지 않아야 한다. user binding 은 mangler 가 보통
    // `__extends$N` 으로 rename 하지만, helper call site 는 helper sym 의 canonical
    // 을 따라 `__extends(...)` 형태로 emit 되어야 한다.
    //
    // 회귀 시그니처: `__extends$N(...)` 같은 호출이 user "shadow" 와 같은 라인 근처에
    // 있어야 fail. 정확히는 user binding 의 rename 된 이름이 함수처럼 호출되는 경우.
    //
    // 단순화한 검증: user binding 이 rename 되었고 (collision 회피), helper call 은
    // 어떤 이름을 쓰든 그것이 user `"shadow"` 와 묶여있지 않아야 한다.
    //
    // user 의 `var __extends$N = "shadow"` 와 그 이름의 함수 호출 `__extends$N(`
    // 이 같은 출력에 공존하면 회귀.
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, scan, "= \"shadow\"")) |pos| {
        // `var XXX = "shadow"` 의 XXX 추출 (직전 식별자).
        // pos 직전이 `= ` 라 그 앞이 식별자.
        var name_end = pos;
        while (name_end > 0 and (result.output[name_end - 1] == ' ' or result.output[name_end - 1] == '\t')) {
            name_end -= 1;
        }
        var name_start = name_end;
        while (name_start > 0) {
            const c = result.output[name_start - 1];
            const is_ident = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_' or c == '$';
            if (!is_ident) break;
            name_start -= 1;
        }
        if (name_start < name_end) {
            const user_name = result.output[name_start..name_end];
            // 그 이름이 함수처럼 호출되는 패턴 `<name>(` 가 출력에 있으면 회귀.
            const call_pattern = try std.fmt.allocPrint(
                std.testing.allocator,
                "{s}(",
                .{user_name},
            );
            defer std.testing.allocator.free(call_pattern);
            if (std.mem.indexOf(u8, result.output, call_pattern)) |call_pos| {
                std.debug.print(
                    "Regression: user binding `{s}` (= \"shadow\") is called as a function at byte {d}.\nBundle output:\n{s}\n",
                    .{ user_name, call_pos, result.output },
                );
                return error.HelperCallShadowedByUserBinding;
            }
        }
        scan = pos + 1;
    }
}

test "Runtime helper shadow: minify 모드에서도 user shadow 가 격리됨" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\import { A } from './a';
        \\const __classCallCheck = "shadow-ccc";
        \\export const result = [__classCallCheck, new A()];
    );
    try writeFile(tmp.dir, "a.ts",
        \\export class A {
        \\  constructor() { this.x = 1; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat_mod.fromESTarget(.es5),
        .minify_whitespace = true,
        .minify_syntax = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());

    // user "shadow-ccc" 보존.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"shadow-ccc\"") != null);

    // helper 가 정의되어 있어야 함 (minify 모드에선 short name `$cC` 등으로 emit).
    // helper 정의가 사라지면 회귀.
    const has_helper_decl = std.mem.indexOf(u8, result.output, "function $cC") != null or
        std.mem.indexOf(u8, result.output, "function __classCallCheck") != null or
        std.mem.indexOf(u8, result.output, "$cC=function") != null or
        std.mem.indexOf(u8, result.output, "__classCallCheck=function") != null;
    try std.testing.expect(has_helper_decl);
}

test "Runtime helper shadow: helper 호출이 user binding 의 rename 결과를 따라가지 않음 (다른 helper)" {
    // `__assertThisInitialized` shadow — class constructor 의 super() 후 호출.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\import { Child } from './child';
        \\const __assertThisInitialized = "shadow-ati";
        \\console.log(__assertThisInitialized, new Child());
    );
    try writeFile(tmp.dir, "child.ts",
        \\class Parent { greet() { return 'hi'; } }
        \\export class Child extends Parent {
        \\  constructor() { super(); }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat_mod.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"shadow-ati\"") != null);
}

test "Runtime helper shadow: private field set helper avoids UMD global helper overwrite" {
    // RN/Metro 환경에서 tslib UMD는 helper를 module.exports와 global 양쪽에 export한다.
    // Metro+Babel의 class private helper는 모듈 래퍼 내부 local이라 global write에
    // 덮이지 않는다. ZNTC도 transformer helper call site가 global helper 이름
    // `__classPrivateFieldSet` 자체에 묶이면 tslib의 TS signature helper에 덮여
    // `state.has is not a function`으로 죽는다.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(tmp.dir, "entry.ts",
        \\import './tslib-umd.js';
        \\import { Box } from './box';
        \\export const value = new Box().set(1);
    );
    try writeFile(tmp.dir, "box.ts",
        \\export class Box {
        \\  #value = 0;
        \\  set(next: number) {
        \\    return this.#value = next;
        \\  }
        \\}
    );
    try writeFile(tmp.dir, "tslib-umd.js",
        \\const root = typeof globalThis === 'object' ? globalThis : global;
        \\root.__classPrivateFieldSet = function(receiver, state, value) {
        \\  if (!state.has(receiver)) throw new TypeError('tslib private field helper');
        \\  state.set(receiver, value);
        \\  return value;
        \\};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .react_native,
        .unsupported = compat_mod.fromESTarget(.es5),
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "root.__classPrivateFieldSet") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__zntcClassPrivateFieldSet(_value, this, next)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "__classPrivateFieldSet(_value, this, next)") == null);
}
