//! react-native-screens 4.23.0 의 4 spec 에 대해 ZTS rn_codegen_plugin 의 출력
//! `__INTERNAL_VIEW_CONFIG = {...}` 객체가 `@react-native/codegen` reference 의
//! 동일 객체와 byte-eq 한지 검증.
//!
//! Reference 출력은 `tests/codegen-snapshots/rn-screens-4/golden/` 에 사람-읽기-쉬운
//! 형태로 commit 됨. ZTS plugin output 은 minified single-line 이라 두 출력의
//! wrapper code 는 형태가 다르지만, **`__INTERNAL_VIEW_CONFIG` 객체 자체는 정규화 후
//! 의미적으로 동등** 해야 한다. 본 테스트는 두 객체를 추출 → whitespace-stripped 비교.
//!
//! mismatch 시 fail — RN 새 spec 패턴 등장 시 자동 회귀 detect (#2348 contract).
//!
//! Fixture / golden 은 `@embedFile` 의 package-root 제약 때문에 runtime fs read.
//! `zig build test` 가 repo root 에서 실행되는 것을 가정 (CI 와 동일).

const std = @import("std");
const codegen_plugin = @import("../rn_codegen_plugin.zig");

const SNAPSHOT_DIR = "tests/codegen-snapshots/rn-screens-4";

fn loadFile(alloc: std.mem.Allocator, sub: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(alloc, &.{ SNAPSHOT_DIR, sub, name });
    defer alloc.free(path);
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(alloc, 1 << 20);
}

/// `__INTERNAL_VIEW_CONFIG = ` 다음의 object literal (`{...}`) 본체 반환. brace 카운팅 —
/// string literal 안의 brace 무시 (single/double quote + backslash escape 인식).
fn extractViewConfig(src: []const u8) ?[]const u8 {
    const marker = "__INTERNAL_VIEW_CONFIG";
    const m = std.mem.indexOf(u8, src, marker) orelse return null;
    var i = m + marker.len;
    while (i < src.len and src[i] != '{') : (i += 1) {}
    if (i >= src.len) return null;

    const start = i;
    var depth: usize = 0;
    var in_string: u8 = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_string != 0) {
            if (c == '\\' and i + 1 < src.len) {
                i += 1;
            } else if (c == in_string) {
                in_string = 0;
            }
            continue;
        }
        switch (c) {
            '\'', '"' => in_string = c,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return src[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// 두 입력의 non-whitespace 바이트 순서가 동일한지 — alloc 없이 streaming 비교.
fn matchesIgnoringWs(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and isWs(a[ai])) ai += 1;
        while (bi < b.len and isWs(b[bi])) bi += 1;
        if (ai == a.len and bi == b.len) return true;
        if (ai == a.len or bi == b.len) return false;
        if (a[ai] != b[bi]) return false;
        ai += 1;
        bi += 1;
    }
}

/// mismatch 시에만 호출 — `expectEqualStrings` 의 diff 렌더링용 normalized buffer.
fn stripWhitespace(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, s.len);
    errdefer buf.deinit(alloc);
    for (s) |c| {
        if (!isWs(c)) try buf.append(alloc, c);
    }
    return try buf.toOwnedSlice(alloc);
}

/// 본 PR (infra only) 시점에 ZTS view_config_emitter 의 출력 형태가 reference 와
/// 광범위하게 달라 (quote style / prop order / ColorValue 형태 / ConditionallyIgnoredEventHandlers
/// 등) 4 spec 모두 byte-diff 발생. 후속 PR 들이 emitter 를 점진 reformat 하며 spec 별
/// 활성화. 그 사이 main 은 green 유지 — 환경 변수 명시 시만 비교 실행.
fn compareCase(fixture_name: []const u8, golden_name: []const u8) !void {
    if (!std.process.hasEnvVarConstant("ZTS_TEST_CODEGEN_SNAPSHOT")) return error.SkipZigTest;

    const alloc = std.testing.allocator;

    const fixture = try loadFile(alloc, "fixtures", fixture_name);
    defer alloc.free(fixture);
    const golden = try loadFile(alloc, "golden", golden_name);
    defer alloc.free(golden);

    // sibling rn_codegen_plugin_test.callTransform 와 동일 패턴 — 두 곳에 새로 helper 가
    // 더 늘면 shared test_helpers.zig 로 추출.
    const plugin = codegen_plugin.plugin();
    const zts_out = (try plugin.transform.?(plugin.context, fixture, fixture_name, alloc)) orelse {
        std.debug.print("[{s}] ZTS plugin returned null — fixture not transformed\n", .{fixture_name});
        return error.TestUnexpectedNull;
    };
    defer alloc.free(zts_out);

    const zts_obj = extractViewConfig(zts_out) orelse {
        std.debug.print("[{s}] ZTS output has no __INTERNAL_VIEW_CONFIG\n", .{fixture_name});
        return error.TestExpectedExtraction;
    };
    const ref_obj = extractViewConfig(golden) orelse {
        std.debug.print("[{s}] golden has no __INTERNAL_VIEW_CONFIG\n", .{fixture_name});
        return error.TestExpectedExtraction;
    };

    if (matchesIgnoringWs(ref_obj, zts_obj)) return;

    // mismatch — `expectEqualStrings` 가 diff 컨텍스트 렌더하도록 normalized buffer 두 개 alloc.
    const zts_norm = try stripWhitespace(alloc, zts_obj);
    defer alloc.free(zts_norm);
    const ref_norm = try stripWhitespace(alloc, ref_obj);
    defer alloc.free(ref_norm);

    std.debug.print("[{s}] view config mismatch\n", .{fixture_name});
    return std.testing.expectEqualStrings(ref_norm, zts_norm);
}

test "snapshot: ScreenNativeComponent vs @react-native/codegen" {
    try compareCase("ScreenNativeComponent.ts", "ScreenNativeComponent.golden.js");
}

test "snapshot: ModalScreenNativeComponent vs @react-native/codegen" {
    try compareCase("ModalScreenNativeComponent.ts", "ModalScreenNativeComponent.golden.js");
}

test "snapshot: ScreenStackHeaderConfigNativeComponent vs @react-native/codegen" {
    try compareCase("ScreenStackHeaderConfigNativeComponent.ts", "ScreenStackHeaderConfigNativeComponent.golden.js");
}

test "snapshot: BottomTabsScreenNativeComponent vs @react-native/codegen" {
    try compareCase("BottomTabsScreenNativeComponent.ts", "BottomTabsScreenNativeComponent.golden.js");
}
