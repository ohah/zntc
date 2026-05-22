//! Top-level/nested 식별자 mangle + shadow 회피 엣지 케이스 회귀 가드.
//!
//! `Bundler.computeMangling` (linker.zig) → `unified_mangler.mangleAll` 의
//! top-level + nested 통합 mangle (RFC #1760) 의 현재 동작을 고정한다.
//!
//! 핵심 불변식 (linker.zig:797~ collectUnifiedInput):
//!   - mangle 은 minify_identifiers 또는 minify_whitespace 시 동작.
//!   - candidate 제외(mangle 안 함): entry export 이름 + external import binding.
//!   - reserved set: unresolved global + 모든 scope 의 1-char 식별자(#2965/#2966)
//!     + entry export/import local.
//!   - dead 모듈 / helper virtual module 은 candidate skip.
//!
//! 이 파일의 assert 는 추측이 아니라 실제 번들 출력을 보고 고정한 것이다.

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// ============================================================
// 1. entry export 이름은 mangle 되지 않는다 (public API 계약).
// ============================================================

test "Mangle: entry 의 export const 이름은 minify 후에도 보존된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 비-entry 모듈을 하나 끼워 mangle 경로가 실제로 활성되도록 한다.
    try writeFile(tmp.dir, "entry.ts",
        \\import { internalLongHelperName } from './lib';
        \\export const fooBarBaz = internalLongHelperName() + 1;
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function internalLongHelperName() { return 41; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // entry 의 export 이름은 mangle 안 됨.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "fooBarBaz") != null);
    // 비-entry 모듈의 긴 이름은 mangle 되어 사라진다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "internalLongHelperName") == null);
}

// ============================================================
// 2. 비-entry 모듈의 top-level binding 은 짧은 이름으로 mangle 된다.
// ============================================================

test "Mangle: non-entry 모듈 top-level const/function 은 짧은 이름으로 바뀐다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { computeSomethingVeryLong, AVeryLongConstantName } from './lib';
        \\console.log(computeSomethingVeryLong(AVeryLongConstantName));
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export const AVeryLongConstantName = 7;
        \\export function computeSomethingVeryLong(x) { return x * 2; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 원본 긴 이름은 모두 사라진다 (import binding 까지 mangle 통일).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "computeSomethingVeryLong") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "AVeryLongConstantName") == null);
    // 동작 보존: `* 2` 표현식은 살아있어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "* 2") != null or
        std.mem.indexOf(u8, result.output, "*2") != null);
}

// ============================================================
// 3. shadow 회피 (#2965/#2966): nested 1-char 변수를 top-level mangle 이
//    shadow 하지 않는다.
// ============================================================

test "Mangle: nested 1-char 변수를 top-level mangled 이름이 shadow 하지 않는다 (#2965)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // lib 모듈은 nested scope 에 `i`, `j` 같은 1-char 변수를 사용한다.
    // entry 가 가리키는 export 이름이 mangle 될 때 그 1-char 를 재사용하면
    // for-loop 내부에서 shadow 가 발생한다.
    try writeFile(tmp.dir, "entry.ts",
        \\import { sumRange, productRange } from './lib';
        \\console.log(sumRange(5), productRange(4));
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function sumRange(n) {
        \\  let total = 0;
        \\  for (let i = 0; i < n; i++) { total += i; }
        \\  return total;
        \\}
        \\export function productRange(n) {
        \\  let total = 1;
        \\  for (let j = 1; j <= n; j++) { total *= j; }
        \\  return total;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const out = result.output;

    // for-loop 의 1-char init 변수 `i`/`j` 는 1-char 라 mangle skip → 원형 유지.
    try std.testing.expect(std.mem.indexOf(u8, out, "i++") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "j++") != null or
        std.mem.indexOf(u8, out, "j <=") != null or
        std.mem.indexOf(u8, out, "j<=") != null);

    // 현재 동작 고정: top-level mangle 은 1-char 이름을 새로 부여하지 않는다
    // (모든 scope 의 1-char 가 reserved). top-level declaration 으로
    // `function i(` / `var i=` / `let i=` 같은 1-char top-level binding 이
    // 생기면 회귀.
    for ([_][]const u8{ "function i(", "function j(", "var i=", "var j=" }) |needle| {
        if (std.mem.indexOf(u8, out, needle)) |pos| {
            std.debug.print(
                "Regression: 1-char top-level binding `{s}` at byte {d} shadows nested loop var.\nOutput:\n{s}\n",
                .{ needle, pos, out },
            );
            return error.OneCharTopLevelBindingShadowsNested;
        }
    }
}

// ============================================================
// 4. cross-module top-level 이름 충돌 deconflict (#2971 류).
// ============================================================

test "Mangle: 두 모듈이 같은 top-level 이름을 갖고 cross-import 시 deconflict (#2971)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 두 모듈 모두 `sharedName` 이라는 top-level 을 갖고 entry 가 둘 다 import.
    try writeFile(tmp.dir, "entry.ts",
        \\import { sharedName as a } from './a';
        \\import { sharedName as b } from './b';
        \\console.log(a(), b());
    );
    try writeFile(tmp.dir, "a.ts",
        \\export function sharedName() { return "from-a-module"; }
    );
    try writeFile(tmp.dir, "b.ts",
        \\export function sharedName() { return "from-b-module"; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 모듈의 동작이 모두 보존되어야 한다 (deconflict 성공 → 둘 다 살아있음).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from-a-module") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "from-b-module") != null);

    // 핵심 검증: 두 함수가 서로 다른 이름으로 deconflict 되어야 한다.
    // 같은 mangled 이름으로 병합되면 entry 호출이 `x(), x()` 가 되어 한 모듈이
    // 가려진다 — 이때도 두 함수 본문(문자열 리터럴 포함)은 모두 출력에 남으므로
    // 위의 리터럴 생존 체크만으로는 병합 회귀를 잡지 못한다. entry 호출부
    // `console.log(A(), B())` 의 두 callee 이름이 실제로 다른지 본다.
    const out = result.output;
    const log_marker = "console.log(";
    const log_at = std.mem.indexOf(u8, out, log_marker) orelse return error.MissingEntryCall;
    const a_start = log_at + log_marker.len;
    const a_paren = std.mem.indexOfScalarPos(u8, out, a_start, '(') orelse return error.MalformedEntryCall;
    const a_name = out[a_start..a_paren];
    const comma = std.mem.indexOfPos(u8, out, a_paren, ", ") orelse return error.MalformedEntryCall;
    const b_start = comma + 2;
    const b_paren = std.mem.indexOfScalarPos(u8, out, b_start, '(') orelse return error.MalformedEntryCall;
    const b_name = out[b_start..b_paren];
    if (std.mem.eql(u8, a_name, b_name)) {
        std.debug.print(
            "Regression: cross-module deconflict failed — both callees named `{s}` in `{s}...`.\nOutput:\n{s}\n",
            .{ a_name, log_marker, out },
        );
        return error.CrossModuleDeconflictMerged;
    }
}

test "Mangle: 1-char top-level binding `z` 가 entry import alias 와 충돌 회피 (#2971 zod)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // zod 의 `class z` ↔ entry import alias `z` 충돌 root cause 의 축소판.
    try writeFile(tmp.dir, "entry.ts",
        \\import { z } from './schema';
        \\console.log(z.parse(1));
    );
    try writeFile(tmp.dir, "schema.ts",
        \\function makeLongInternalName() { return { parse: (v) => v }; }
        \\export const z = makeLongInternalName();
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // entry 가 참조하는 `z` 는 1-char 라 reserved → mangle 안 됨, 동작 보존.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "z.parse") != null or
        std.mem.indexOf(u8, result.output, "z.parse(1)") != null);
    // 긴 internal 이름은 mangle 되어 사라진다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "makeLongInternalName") == null);
}

// ============================================================
// 5. external import binding 은 mangle 되지 않는다.
// ============================================================

test "Mangle: external import binding 은 mangle 되지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import reactDefaultExport from 'react';
        \\import { internalThing } from './lib';
        \\console.log(reactDefaultExport, internalThing());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function internalThing() { return 1; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
        .external = &.{"react"},
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // external import 의 local binding 은 contract → mangle 안 됨.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "reactDefaultExport") != null);
    // import 문 자체가 'react' 로 보존되어야 한다 (external).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"react\"") != null or
        std.mem.indexOf(u8, result.output, "'react'") != null);
}

// ============================================================
// 6. unresolved global (Promise/Set 등) 이름을 top-level mangle 이
//    재사용하지 않는다.
// ============================================================

test "Mangle: 모듈이 참조하는 unresolved global(Promise/Set)을 top-level mangle 이 재사용하지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // lib 가 Promise / Set 을 참조 → reserved_globals 에 등록.
    // 많은 top-level binding 을 만들어 mangler 가 짧은 이름 풀을 소진하도록 유도.
    try writeFile(tmp.dir, "entry.ts",
        \\import { runAll } from './lib';
        \\runAll();
    );
    try writeFile(tmp.dir, "lib.ts",
        \\const longNameOne = 1;
        \\const longNameTwo = 2;
        \\const longNameThree = 3;
        \\const longNameFour = 4;
        \\export function runAll() {
        \\  const p = Promise.resolve(longNameOne + longNameTwo);
        \\  const s = new Set([longNameThree, longNameFour]);
        \\  return p.then(() => s.size);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const out = result.output;
    // Promise / Set 참조가 보존되어야 한다.
    try std.testing.expect(std.mem.indexOf(u8, out, "Promise.resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "new Set(") != null);
    // 회귀 가드: top-level declaration 이 `Promise` / `Set` 이름을 재사용하면
    // hoist 되어 global 을 shadow 한다.
    for ([_][]const u8{ "var Promise=", "var Promise =", "function Promise(", "var Set=", "var Set =", "function Set(" }) |needle| {
        if (std.mem.indexOf(u8, out, needle)) |pos| {
            std.debug.print(
                "Regression: top-level binding reuses global name `{s}` at byte {d}.\nOutput:\n{s}\n",
                .{ needle, pos, out },
            );
            return error.TopLevelMangleShadowsGlobal;
        }
    }
}

// ============================================================
// 7. helper virtual module 식별자는 추가 rename 되지 않는다.
//    ES5 lowering 은 `__async` / `__generator` 런타임 helper 를 주입한다
//    (실제 출력 기준 — `$`-prefix 가 아니라 `__`-prefix). mangler 가 이 이름을
//    rename/분열시키면 정의(def)와 호출(call) site 가 어긋나 ReferenceError.
// ============================================================

test "Mangle: 런타임 helper(`__`-prefix) 식별자는 추가 rename 되지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // async/await → ES5 lower → runtime helper (`$aS` 등) 주입.
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchValue } from './lib';
        \\fetchValue().then((v) => console.log(v));
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export async function fetchValue() {
        \\  const a = await Promise.resolve(1);
        \\  const bbbbbbbb = await Promise.resolve(2);
        \\  return a + bbbbbbbb;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    const compat_mod = @import("../../transformer/compat.zig");
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .unsupported = compat_mod.fromESTarget(.es5),
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const out = result.output;

    // 전제 확인: ES5 lowering 으로 helper 가 실제 주입되었는지. 이게 깨지면
    // 아래 일관성 검사가 vacuous 해지므로 명시적으로 fail 시킨다.
    try std.testing.expect(std.mem.indexOf(u8, out, "__async") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "__generator") != null);

    // 각 helper 이름은 정의(`var __async =` / `function ...`)와 호출(`__async(`)
    // 양쪽에 동일하게 등장해야 한다 → 최소 2회. mangler 가 def 만(또는 call 만)
    // rename 하면 한쪽이 사라져 count 가 줄거나 dangling 참조가 된다.
    for ([_][]const u8{ "__async", "__generator" }) |helper| {
        var count: usize = 0;
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, out, idx, helper)) |pos| {
            count += 1;
            idx = pos + helper.len;
        }
        if (count < 2) {
            std.debug.print(
                "Helper rename leak: `{s}` appears {d}x (def+call 이면 >=2 여야 함).\nOutput:\n{s}\n",
                .{ helper, count, out },
            );
            return error.HelperIdentifierRenameLeak;
        }
        // deconflict suffix 로 분열되면 회귀: `__async$1` / `__async2` 같은 변형.
        var sfx_buf: [32]u8 = undefined;
        const dollar_sfx = std.fmt.bufPrint(&sfx_buf, "{s}$", .{helper}) catch unreachable;
        try std.testing.expect(std.mem.indexOf(u8, out, dollar_sfx) == null);
    }
}

// ============================================================
// 8. tree-shaken dead 모듈의 binding 은 짧은 이름 풀을 잠식하지 않는다.
// ============================================================

test "Mangle: dead 모듈 binding 은 included 모듈의 짧은 이름 풀을 잠식하지 않는다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { liveFunctionAlpha } from './live';
        \\console.log(liveFunctionAlpha());
    );
    try writeFile(tmp.dir, "live.ts",
        \\export function liveFunctionAlpha() { return 1; }
    );
    // dead 모듈: 아무도 import 하지 않음.
    try writeFile(tmp.dir, "dead.ts",
        \\export function deadFunctionBeta() { return 2; }
        \\export const deadConstGamma = 3;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    const out = result.output;
    // dead 모듈은 번들에서 제외 → 그 이름이 아예 안 나온다.
    try std.testing.expect(std.mem.indexOf(u8, out, "deadFunctionBeta") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "deadConstGamma") == null);
    // live 모듈은 mangle 되어 짧은 이름을 받는다 (긴 이름 사라짐).
    try std.testing.expect(std.mem.indexOf(u8, out, "liveFunctionAlpha") == null);
}

// ============================================================
// 9. 대조: minify off 면 mangle 안 됨 (원본 이름 유지).
// ============================================================

test "Mangle: minify off 시 비-entry 모듈 top-level 이름이 보존된다 (대조 케이스)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { keepThisLongName } from './lib';
        \\console.log(keepThisLongName());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function keepThisLongName() { return 42; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        // minify 옵션 모두 off.
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // mangle 비활성 → 원본 이름 그대로 유지.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "keepThisLongName") != null);
}

// ============================================================
// 9b. Bundler API 레벨에서 mangle 게이트는 minify_identifiers 단독이다.
//     (minify_whitespace 만으로는 식별자 mangle 이 일어나지 않는다 — 실증.
//      "minify_whitespace 가 mangle 을 함의" 는 CLI 레벨 매핑이지 Bundler
//      옵션의 동작이 아니다.)
// ============================================================

test "Mangle: minify_whitespace=true 단독으로는 식별자 mangle 이 일어나지 않는다 (게이트는 minify_identifiers)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { whitespaceModeLongName } from './lib';
        \\console.log(whitespaceModeLongName());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function whitespaceModeLongName() { return 99; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minify_whitespace 만으로는 mangle 안 됨 → 긴 이름 보존.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "whitespaceModeLongName") != null);
    // 값 보존.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "99") != null);
}

test "Mangle: minify_whitespace + minify_identifiers 함께면 비-entry top-level 이 mangle 된다" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { bothFlagsLongName } from './lib';
        \\console.log(bothFlagsLongName());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function bothFlagsLongName() { return 99; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify_whitespace = true,
        .minify_identifiers = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 플래그 함께면 mangle → 긴 이름 사라짐.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "bothFlagsLongName") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "99") != null);
}
