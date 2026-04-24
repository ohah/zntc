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
    return code[start..ret_idx + ret_marker.len];
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
