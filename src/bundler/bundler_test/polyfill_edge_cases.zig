// polyfill_edge_cases.zig — RN polyfill transpile/minify 처리 엣지 케이스.
//
// 배경: RN polyfill 은 모듈 그래프를 우회해 bundler 가 파일을 직접 읽어 prepend 한다
// (src/bundler/bundler.zig 의 polyfill loop ~1365-1420). transpile/minify 동작:
//   - should_transpile = (flow or minify_ws) and (!is_console or minify_ws)
//   - transpile 실패 시 raw fallback(경고만 남기고 크래시 없음), trailing newline 보장
//   - emitter 는 polyfill 을 `(function(){` + content + `})();` 로 wrap
//     (minify 시 separator 없음, src/bundler/emitter.zig ~478-513).
//
// splitting_dev.zig 의 기존 polyfill 테스트 3개(dev 포함, #3649 minify, 누수 가드)와
// 중복하지 않는, 빠진 엣지만 다룬다. assert 는 모두 실제 번들 출력 기준(추측 금지).
//
// transpile-실패 입력 검증: `function f() {`(닫히지 않은 brace), `const = ;` 모두
// ZNTC transpile() 이 안정적으로 error.ParseError 를 낸다(probe 로 확인). raw fallback
// 경로(bundler.zig ~1394-1404)가 타게 된다.

const std = @import("std");
const Bundler = @import("../bundler.zig").Bundler;
const test_helpers = @import("../test_helpers.zig");
const writeFile = test_helpers.writeFile;
const absPath = test_helpers.absPath;

// 1. transpile 실패 → raw fallback (크래시 없음).
//    명백한 parse error polyfill + minify 빌드 → 번들이 죽지 않고 생성되며 raw 가 포함.
test "Polyfill: transpile 실패 시 raw fallback — 크래시 없이 번들 생성 + raw 포함" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");
    // 닫히지 않은 brace — transpile() 이 error.ParseError 를 낸다(probe 확인).
    // 식별 가능한 토큰 POLY_RAW_MARKER 를 raw 에 둬 fallback 포함 여부를 검증.
    try writeFile(tmp.dir, "bad-polyfill.js", "var POLY_RAW_MARKER = 1;\nfunction f() {\n");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "bad-polyfill.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .polyfills = &.{polyfill},
        .minify_whitespace = true,
    });
    defer b.deinit();

    // transpile 실패는 경고만 — 번들 자체는 성공.
    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // raw 가 그대로 포함 (transpile 됐다면 minify 로 형태가 바뀌었겠지만 raw 보존).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "POLY_RAW_MARKER") != null);
    // entry 코드도 정상 포함.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
}

// 2. raw fallback + trailing newline 없는 입력.
//    transpile 실패 polyfill 을 trailing `\n` 없이 작성 → 출력에서 polyfill content 와
//    `})()` 사이에 개행이 보장돼 `})()` 가 content 마지막 줄에 안 붙는지.
//    (붙으면 minify IIFE wrap `(function(){<content>})();` 에서 SyntaxError 위험.)
test "Polyfill: raw fallback + trailing newline 없음 — })() 가 content 마지막 줄에 안 붙음" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");
    // ParseError 나는 입력 + trailing newline 없음. 마지막 줄이 `function f() {`.
    try writeFile(tmp.dir, "no-nl-polyfill.js", "var POLY_NO_NL = 1;\nfunction f() {");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "no-nl-polyfill.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .polyfills = &.{polyfill},
        .minify_whitespace = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "POLY_NO_NL") != null);
    // 핵심: raw 의 마지막 토큰 `{` 바로 뒤에 `})()` 가 붙지 않아야 함.
    // bundler 가 trailing newline 을 보장하므로 `{\n})()` 형태여야 한다.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "{})()") == null);
    // 개행으로 분리된 형태가 실제로 존재.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "{\n})()") != null);
}

// 3a. console.js dev(비-minify) — raw 보존 (주석/들여쓰기 남음).
//     should_transpile = (flow or minify_ws) and (!is_console or minify_ws).
//     console.js + minify_ws=false → false → transpile 안 함 → raw 그대로.
test "Polyfill: console.js 비-minify — raw 보존(주석/들여쓰기 남음)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");
    try writeFile(tmp.dir, "console.js", "// console polyfill banner\nfunction setupConsole(argName) {\n    return argName;\n}\nglobal.ConsolePoly = setupConsole;\n");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "console.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .polyfills = &.{polyfill},
        .minify_whitespace = false,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ConsolePoly") != null);
    // raw 보존: 주석과 4-space 들여쓰기가 남아 있어야 함.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console polyfill banner") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "    return argName") != null);
}

// 3b. console.js minify — transpile 되어 주석/들여쓰기 제거.
//     console.js + minify_ws=true → (false or true) and (false or true) = true → transpile.
test "Polyfill: console.js minify — transpile 되어 주석/들여쓰기 제거" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");
    try writeFile(tmp.dir, "console.js", "// console polyfill banner\nfunction setupConsole(argName) {\n    return argName;\n}\nglobal.ConsolePoly = setupConsole;\n");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "console.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .polyfills = &.{polyfill},
        .minify_whitespace = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // content 는 여전히 포함.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "ConsolePoly") != null);
    // minify: 주석 제거 + 4-space 들여쓰기 제거.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console polyfill banner") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "    return argName") == null);
}

// 4. flow polyfill (@flow pragma) — flow=true 빌드에서 Flow 타입 strip.
test "Polyfill: flow pragma polyfill — flow=true 빌드에서 Flow 타입 strip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");
    try writeFile(tmp.dir, "flow-polyfill.js", "/* @flow */\nconst flowVal: number = 1;\nglobal.FlowPoly = flowVal;\n");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "flow-polyfill.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .polyfills = &.{polyfill},
        .flow = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "FlowPoly") != null);
    // Flow 타입 어노테이션이 strip 되어야 함 — `: number` 사라짐.
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
    // 선언 자체는 보존 (값 1).
    try std.testing.expect(std.mem.indexOf(u8, result.output, "flowVal") != null);
}

// 4b. flow polyfill + minify 조합 — Flow strip 과 whitespace minify 동시.
test "Polyfill: flow pragma polyfill + minify — Flow strip + 주석/들여쓰기 제거" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");
    try writeFile(tmp.dir, "flow-polyfill.js", "/* @flow */\n// flow helper banner\nfunction flowHelper(argName: number): number {\n    return argName;\n}\nglobal.FlowPoly = flowHelper;\n");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "flow-polyfill.js");
    defer std.testing.allocator.free(polyfill);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .polyfills = &.{polyfill},
        .flow = true,
        .minify_whitespace = true,
    });
    defer b.deinit();

    const result = try b.bundle(std.testing.io);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "FlowPoly") != null);
    // Flow 타입 strip.
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
    // minify: 주석 + 4-space 들여쓰기 제거.
    try std.testing.expect(std.mem.indexOf(u8, result.output, "flow helper banner") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "    return") == null);
}

// 5. 정상 JS polyfill minify on/off 대조.
//    동일 polyfill 을 두 빌드로 → minify on 은 공백/주석 제거, off 는 원본 유지.
test "Polyfill: 정상 JS polyfill — minify on/off 대조" {
    const src = "// poly contrast banner\nfunction contrastHelper(argName) {\n    return argName + 1;\n}\nglobal.ContrastPoly = contrastHelper;\n";

    // (a) minify off — 원본(주석/들여쓰기) 유지.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "index.ts", "console.log('hi');");
        try writeFile(tmp.dir, "contrast-polyfill.js", src);

        const entry = try absPath(&tmp, "index.ts");
        defer std.testing.allocator.free(entry);
        const polyfill = try absPath(&tmp, "contrast-polyfill.js");
        defer std.testing.allocator.free(polyfill);

        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .polyfills = &.{polyfill},
            .minify_whitespace = false,
        });
        defer b.deinit();

        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "ContrastPoly") != null);
        // off: 주석 + 4-space 들여쓰기 보존.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "poly contrast banner") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "    return argName") != null);
    }

    // (b) minify on — 공백/주석 제거.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFile(tmp.dir, "index.ts", "console.log('hi');");
        try writeFile(tmp.dir, "contrast-polyfill.js", src);

        const entry = try absPath(&tmp, "index.ts");
        defer std.testing.allocator.free(entry);
        const polyfill = try absPath(&tmp, "contrast-polyfill.js");
        defer std.testing.allocator.free(polyfill);

        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .polyfills = &.{polyfill},
            .minify_whitespace = true,
        });
        defer b.deinit();

        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);

        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "ContrastPoly") != null);
        // on: 주석 + 4-space 들여쓰기 제거.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "poly contrast banner") == null);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "    return argName") == null);
    }
}

// 6. 빈 polyfill 파일 — 0-byte → 크래시 없이 번들 생성(raw.len==0 가드).
test "Polyfill: 빈 polyfill 파일(0-byte) — 크래시 없이 번들 생성" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "console.log('hi');");
    try writeFile(tmp.dir, "empty-polyfill.js", "");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);
    const polyfill = try absPath(&tmp, "empty-polyfill.js");
    defer std.testing.allocator.free(polyfill);

    // minify on/off 둘 다 — minify 경로(transpile)도 0-byte 에서 안전한지 확인.
    inline for (.{ true, false }) |minify| {
        var b = Bundler.init(std.testing.allocator, .{
            .entry_points = &.{entry},
            .polyfills = &.{polyfill},
            .minify_whitespace = minify,
        });
        defer b.deinit();

        const result = try b.bundle(std.testing.io);
        defer result.deinit(std.testing.allocator);

        // 빈 polyfill 이어도 번들은 정상 생성, entry 코드 포함.
        try std.testing.expect(!result.hasErrors());
        try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
        // 빈 IIFE wrap 이 생성됨.
        try std.testing.expect(std.mem.indexOf(u8, result.output, "(function(){") != null);
    }
}
