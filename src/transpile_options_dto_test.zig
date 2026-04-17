//! `TranspileOptionsDto` (Zig) ↔ `TranspileOptions` (TS) 필드 동기화 검증.
//!
//! #1446에서 Zig struct가 JSON schema의 단일 소스가 됐지만, TS 쪽의
//! `TranspileOptions` interface는 JSDoc/union 유지를 위해 handwritten으로
//! 남았다. 두 표현이 드리프트하지 않도록 CI에서 자동 검증한다.
//!
//! 검증 원칙:
//!   - Zig DTO 필드는 전부 TS interface에 존재해야 함 (WASM/NAPI로 전달되려면
//!     TS 사용자가 해당 필드를 쓸 수 있어야 함).
//!   - TS에만 있고 Zig에 없는 필드는 allowlist에 있어야 함 (JS 래퍼가
//!     자체 처리하는 필드들 — filename/browserslist/minify 등).

const std = @import("std");
const TranspileOptionsDto = @import("transpile.zig").TranspileOptionsDto;

/// TS `TranspileOptions`에만 있는 (Zig로 전달되지 않거나 JS 래퍼가 해석하는)
/// 필드. 리스트에 없는 TS-only 필드가 발견되면 테스트 실패 — 의도된 추가라면
/// 이 리스트에 등록할 것.
const ts_only_allowlist = [_][]const u8{
    "filename", // CLI/API의 별도 인자로 전달, 옵션 DTO에 안 들어감
    "browserslist", // JS 쪽에서 unsupported bitmask로 해석 후 주입
    "minify", // minifyWhitespace/Identifiers/Syntax all-in-one alias
};

/// Zig DTO에만 있는 (JS 래퍼가 내부적으로만 쓰는) 필드.
/// TS 공개 API에 노출할 필요가 없는 internal 전달 경로 — 리스트에 없는 필드가
/// TS에 누락되면 드리프트로 간주하고 실패.
const zig_only_allowlist = [_][]const u8{
    "unsupported", // JS wrapper가 browserslist 해석 후 주입. 사용자가 직접 쓸 일 없음.
};

/// TS `packages/shared/index.ts`의 `TranspileOptions` interface에서 필드명을
/// 추출한다. 간단 파서: `interface TranspileOptions {` 블록 본문의 각 줄에서
/// 첫 식별자(optional `?` 직전의 `:`까지)를 긁는다. 주석(`//`, `/**`)과 빈 줄은
/// 스킵.
fn parseTsInterface(source: []const u8, list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    const marker = "interface TranspileOptions {";
    const body_start = (std.mem.indexOf(u8, source, marker) orelse return error.InterfaceNotFound) + marker.len;
    var depth: usize = 1;
    var i: usize = body_start;
    while (i < source.len and depth > 0) : (i += 1) {
        switch (source[i]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
    const body = source[body_start .. i - 1];

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "*")) continue;
        if (std.mem.startsWith(u8, line, "/*")) continue;

        // `fieldName?:` 또는 `fieldName:` 패턴. 첫 non-identifier 문자까지가 필드명.
        var end: usize = 0;
        while (end < line.len and (std.ascii.isAlphanumeric(line[end]) or line[end] == '_')) end += 1;
        if (end == 0) continue;
        const name = line[0..end];
        // `:` 또는 `?:`가 이어져야 필드 선언.
        const after = line[end..];
        if (!std.mem.startsWith(u8, after, ":") and !std.mem.startsWith(u8, after, "?:")) continue;
        try list.append(allocator, name);
    }
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

test "schema diff: Zig DTO fields are covered by TS TranspileOptions" {
    const allocator = std.testing.allocator;

    // 저장소 루트에서 테스트 실행 가정 (zig build test 기본).
    const ts_source = std.fs.cwd().readFileAlloc(allocator, "packages/shared/index.ts", 1 * 1024 * 1024) catch |err| {
        // CI 외 환경에서 경로가 다를 수 있음 → skip 처리
        if (err == error.FileNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(ts_source);

    var ts_fields: std.ArrayList([]const u8) = .empty;
    defer ts_fields.deinit(allocator);
    try parseTsInterface(ts_source, &ts_fields, allocator);
    try std.testing.expect(ts_fields.items.len > 0);

    // 1. Zig DTO 필드가 TS에 모두 있는지 (internal 필드는 zig_only_allowlist에서 제외)
    const zig_fields = @typeInfo(TranspileOptionsDto).@"struct".fields;
    inline for (zig_fields) |f| {
        const is_internal = comptime contains(&zig_only_allowlist, f.name);
        if (!is_internal and !contains(ts_fields.items, f.name)) {
            std.debug.print(
                "\n[schema drift] Zig TranspileOptionsDto.{s} is missing from TS TranspileOptions in packages/shared/index.ts\n",
                .{f.name},
            );
            return error.ZigFieldMissingFromTs;
        }
    }

    // 2. TS에만 있는 필드는 allowlist에 있어야 함
    for (ts_fields.items) |ts_name| {
        // Zig에 있으면 OK
        var found = false;
        inline for (zig_fields) |f| {
            if (std.mem.eql(u8, f.name, ts_name)) found = true;
        }
        if (found) continue;
        if (contains(&ts_only_allowlist, ts_name)) continue;
        std.debug.print(
            "\n[schema drift] TS TranspileOptions.{s} is not in Zig DTO — add to ts_only_allowlist if intentional\n",
            .{ts_name},
        );
        return error.TsFieldNotAllowlisted;
    }
}

test "parseTsInterface: basic extraction" {
    const source =
        \\export interface Other { x: number }
        \\export interface TranspileOptions {
        \\  /** Filename */
        \\  filename?: string;
        \\  sourcemap?: boolean;
        \\  // inline comment
        \\  target?: Target;
        \\  nested?: { inner: string };
        \\}
    ;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(std.testing.allocator);
    try parseTsInterface(source, &list, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqualStrings("filename", list.items[0]);
    try std.testing.expectEqualStrings("sourcemap", list.items[1]);
    try std.testing.expectEqualStrings("target", list.items[2]);
    try std.testing.expectEqualStrings("nested", list.items[3]);
}
