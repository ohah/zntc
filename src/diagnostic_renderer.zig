//! 진단 렌더러 — rustc/oxc 수준의 친절한 에러 출력
//!
//! RichDiagnostic + SourceInfo를 받아 코드 프레임이 포함된
//! 구조화된 진단 메시지를 출력한다.
//!
//! 출력 포맷 (unicode + color):
//!   × Top-level await is not available in the configured target environment [ZTS0001]
//!    ╭─[src/app.ts:5:14]
//!  4 │ const data = fetch('/api');
//!  5 │ const res = await data;
//!    · ·············^^^^^^^^^^
//!    ╰────
//!   help: Set target to 'es2022' or higher to use top-level await
//!
//! 비-Unicode 폴백:
//!   x Top-level await is not available... [ZTS0001]
//!    +-[src/app.ts:5:14]
//!  5 | const res = await data;
//!    . .............^^^^^^^^^^
//!    +----
//!   help: ...

const std = @import("std");
const ansi = @import("ansi.zig");
const rich_diagnostic = @import("rich_diagnostic.zig");
const RichDiagnostic = rich_diagnostic.RichDiagnostic;
const SourceInfo = rich_diagnostic.SourceInfo;
const Diagnostic = @import("diagnostic.zig").Diagnostic;

pub const RenderOptions = struct {
    /// ANSI 컬러 코드 활성화 여부. isTty()로 자동 감지 가능.
    color: bool = true,
    /// Unicode 박스 드로잉 문자 사용 여부.
    /// false이면 ASCII 폴백 (|, +, . 등).
    unicode: bool = true,
};

/// 코드 프레임 포함 진단 메시지를 렌더링한다.
///
/// writer: std.io.fixedBufferStream(...).writer(), std.io.getStdErr().writer() 등
/// diag: 렌더링할 진단 정보
/// source_info: 소스 코드 + 줄 오프셋
/// options: 컬러/유니코드 옵션
pub fn render(
    writer: anytype,
    diag: RichDiagnostic,
    source_info: SourceInfo,
    options: RenderOptions,
) !void {
    const color = options.color;

    // ── 1. 헤더: severity 아이콘 + 메시지 + [코드] ──
    try renderHeader(writer, diag, color, options.unicode);

    // ── 2. 파일 참조 + 코드 프레임 ──
    const lc = source_info.getLineColumn(diag.span.start);
    const err_line = lc.line;
    const err_col = lc.column;

    // 줄 번호 너비 계산 (코드 프레임 정렬용)
    // 에러 줄 + 전후 컨텍스트 줄 중 가장 큰 번호의 자릿수
    const max_line_num = err_line + 2; // 1-based, +1 for after context
    const gutter_width = digitCount(max_line_num + 1);

    // 파일 참조: " ╭─[file:line:col]"
    try writeGutter(writer, gutter_width, null, color);
    if (options.unicode) {
        try writer.writeAll(" \xe2\x95\xad\xe2\x94\x80["); // ╭─[
    } else {
        try writer.writeAll(" +-[");
    }
    try ansi.styled(writer, .cyan, diag.file_path, color);
    try writer.print(":{d}:{d}]\n", .{ err_line + 1, err_col + 1 });

    // label이 이미 차지한 줄은 context에서 생략 (중복 방지)
    const label_before_err = err_line > 0 and hasLabelOnLine(diag.labels, source_info, err_line - 1);
    const label_after_err = err_line + 1 < source_info.line_offsets.len and hasLabelOnLine(diag.labels, source_info, err_line + 1);

    // ── 3. 컨텍스트 줄: 에러 줄 전 1줄 ──
    if (err_line > 0 and !label_before_err) {
        try renderSourceLine(writer, source_info, err_line - 1, gutter_width, color, options.unicode);
    }

    // primary 위쪽 label 먼저 출력 (줄 번호 오름차순 유지)
    if (label_before_err) {
        for (diag.labels) |label| {
            const l_lc = source_info.getLineColumn(label.span.start);
            if (l_lc.line == err_line - 1) {
                try renderSourceLine(writer, source_info, l_lc.line, gutter_width, color, options.unicode);
                try renderLabelUnderline(writer, source_info, label, l_lc.line, l_lc.column, gutter_width, color, options.unicode);
            }
        }
    }

    // ── 4. 에러 줄 ──
    try renderSourceLine(writer, source_info, err_line, gutter_width, color, options.unicode);

    // ── 5. 밑줄 + 라벨 ──
    try renderUnderline(writer, source_info, diag, err_line, err_col, gutter_width, color, options.unicode);

    // ── 5.25. primary와 같은 줄에 걸린 label 출력 (primary 밑줄 바로 아래) ──
    for (diag.labels) |label| {
        const l_lc = source_info.getLineColumn(label.span.start);
        if (l_lc.line == err_line) {
            try renderLabelUnderline(writer, source_info, label, l_lc.line, l_lc.column, gutter_width, color, options.unicode);
        }
    }

    // ── 5.5. primary 아래쪽 label 출력 (err_line보다 뒤) ──
    for (diag.labels) |label| {
        const l_lc = source_info.getLineColumn(label.span.start);
        if (l_lc.line <= err_line) continue;
        try renderSourceLine(writer, source_info, l_lc.line, gutter_width, color, options.unicode);
        try renderLabelUnderline(writer, source_info, label, l_lc.line, l_lc.column, gutter_width, color, options.unicode);
    }

    // ── 6. 에러 줄 후 1줄 (label이 이미 차지하지 않은 경우) ──
    if (err_line + 1 < source_info.line_offsets.len and !label_after_err) {
        try renderSourceLine(writer, source_info, err_line + 1, gutter_width, color, options.unicode);
    }

    // ── 7. 닫기: " ╰────" ──
    try writeGutter(writer, gutter_width, null, color);
    if (options.unicode) {
        try writer.writeAll(" \xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n"); // ╰────
    } else {
        try writer.writeAll(" +----\n");
    }

    // ── 8. help/note/url ──
    if (diag.help) |help_text| {
        try ansi.styled(writer, .bold_cyan, "  help", color);
        try writer.writeAll(": ");
        try writer.writeAll(help_text);
        try writer.writeByte('\n');
    }
    if (diag.note) |note_text| {
        try ansi.styled(writer, .bold_blue, "  note", color);
        try writer.writeAll(": ");
        try writer.writeAll(note_text);
        try writer.writeByte('\n');
    }
    if (diag.url) |url_text| {
        try ansi.styled(writer, .dim, "  url", color);
        try writer.writeAll(": ");
        try ansi.styled(writer, .dim, url_text, color);
        try writer.writeByte('\n');
    }

    // 빈 줄로 구분
    try writer.writeByte('\n');
}

/// 여러 Diagnostic을 순차로 렌더링한다. CLI/WASM/NAPI가 공용으로 쓰는 진입점.
/// OwnedDiagnostic 등 `asDiagnostic()` 메서드가 있는 타입도 같은 함수로 받는다.
/// 첫 에러 렌더 실패 시 루프를 중단한다 (writer가 망가진 상태).
pub fn renderAll(
    writer: anytype,
    diagnostics: anytype,
    source_info: SourceInfo,
    file_path: []const u8,
    options: RenderOptions,
) !void {
    for (diagnostics) |d| {
        const diag: Diagnostic = if (@TypeOf(d) == Diagnostic) d else d.asDiagnostic();
        const rich = rich_diagnostic.fromDiagnostic(diag, file_path);
        try render(writer, rich, source_info, options);
    }
}

/// 소스 코드 없이 간단하게 렌더링한다.
/// 번들러 에러 등 소스를 참조할 수 없는 경우에 사용.
///
/// 출력 포맷:
///   × Could not resolve import [ZTS0100]
///   ╭─ src/app.ts
///   help: Did you mean './utils.js'?
pub fn renderSimple(
    writer: anytype,
    diag: RichDiagnostic,
    options: RenderOptions,
) !void {
    const color = options.color;

    try renderHeader(writer, diag, color, options.unicode);

    // 파일 경로만 표시
    if (diag.file_path.len > 0) {
        if (options.unicode) {
            try writer.writeAll("   \xe2\x95\xad\xe2\x94\x80 "); // ╭─
        } else {
            try writer.writeAll("   +- ");
        }
        try ansi.styled(writer, .cyan, diag.file_path, color);
        try writer.writeByte('\n');
        if (options.unicode) {
            try writer.writeAll("   \xe2\x95\xb0\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n"); // ╰────
        } else {
            try writer.writeAll("   +----\n");
        }
    }

    if (diag.help) |help_text| {
        try ansi.styled(writer, .bold_cyan, "  help", color);
        try writer.writeAll(": ");
        try writer.writeAll(help_text);
        try writer.writeByte('\n');
    }
    if (diag.note) |note_text| {
        try ansi.styled(writer, .bold_blue, "  note", color);
        try writer.writeAll(": ");
        try writer.writeAll(note_text);
        try writer.writeByte('\n');
    }
    if (diag.url) |url_text| {
        try ansi.styled(writer, .dim, "  url", color);
        try writer.writeAll(": ");
        try ansi.styled(writer, .dim, url_text, color);
        try writer.writeByte('\n');
    }

    try writer.writeByte('\n');
}

// ─── 내부 헬퍼 ───

/// severity에 대응하는 ANSI 스타일.
fn severityStyle(severity: RichDiagnostic.Severity) ansi.Style {
    return switch (severity) {
        .@"error" => .bold_red,
        .warning => .bold_yellow,
        .info => .bold_cyan,
    };
}

/// 헤더 줄 렌더링: "  × message [CODE]"
fn renderHeader(writer: anytype, diag: RichDiagnostic, color: bool, unicode: bool) !void {
    // severity 아이콘
    const icon = switch (diag.severity) {
        .@"error" => if (unicode) "\xc3\x97" else "x", // × or x
        .warning => if (unicode) "\xe2\x9a\xa0" else "!", // ⚠ or !
        .info => if (unicode) "\xe2\x84\xb9" else "i", // ℹ or i
    };
    const style = severityStyle(diag.severity);

    try writer.writeAll("  ");
    try ansi.styled(writer, style, icon, color);
    try writer.writeByte(' ');
    try ansi.styled(writer, style, diag.message, color);

    // 에러 코드
    if (diag.code) |code_str| {
        try writer.writeAll(" ");
        try ansi.styled(writer, .dim, "[", color);
        try ansi.styled(writer, .dim, code_str, color);
        try ansi.styled(writer, .dim, "]", color);
    }
    try writer.writeByte('\n');
}

/// 소스 줄 렌더링: " N │ source text"
fn renderSourceLine(
    writer: anytype,
    source_info: SourceInfo,
    line: u32,
    gutter_width: u32,
    color: bool,
    unicode: bool,
) !void {
    const line_text = source_info.getLineText(line);
    try writeGutter(writer, gutter_width, line + 1, color); // 1-based 줄 번호
    if (unicode) {
        try writer.writeAll(" \xe2\x94\x82 "); // │
    } else {
        try writer.writeAll(" | ");
    }
    try writer.writeAll(line_text);
    try writer.writeByte('\n');
}

/// 밑줄 줄 렌더링: "   · ^^^^^^^^^^^^"
fn renderUnderline(
    writer: anytype,
    source_info: SourceInfo,
    diag: RichDiagnostic,
    err_line: u32,
    err_col: u32,
    gutter_width: u32,
    color: bool,
    unicode: bool,
) !void {
    const line_text = source_info.getLineText(err_line);

    // span 길이 계산 (같은 줄 내로 제한)
    const span_len = if (diag.span.end > diag.span.start)
        @min(diag.span.end - diag.span.start, @as(u32, @intCast(line_text.len)) -| err_col)
    else
        1;

    try writeGutter(writer, gutter_width, null, color);
    if (unicode) {
        try writer.writeAll(" \xc2\xb7 "); // ·
    } else {
        try writer.writeAll(" . ");
    }

    // 열 위치까지 공백 (탭 정렬 고려)
    var i: u32 = 0;
    while (i < err_col) : (i += 1) {
        if (i < line_text.len and line_text[i] == '\t') {
            try writer.writeByte('\t');
        } else {
            try writer.writeByte(' ');
        }
    }

    // ^^^ 밑줄
    try ansi.setStyle(writer, severityStyle(diag.severity), color);
    i = 0;
    while (i < span_len) : (i += 1) {
        try writer.writeByte('^');
    }
    try ansi.setStyle(writer, .reset, color);
    try writer.writeByte('\n');
}

/// labels 중 주어진 줄에 걸린 것이 하나라도 있는지.
fn hasLabelOnLine(labels: []const rich_diagnostic.Label, source_info: SourceInfo, line: u32) bool {
    for (labels) |label| {
        if (source_info.getLineColumn(label.span.start).line == line) return true;
    }
    return false;
}

/// Secondary label의 밑줄: ─── (primary의 ^^^ 대비). 메시지가 있으면 밑줄 뒤에 이어 출력.
fn renderLabelUnderline(
    writer: anytype,
    source_info: SourceInfo,
    label: anytype,
    line: u32,
    col: u32,
    gutter_width: u32,
    color: bool,
    unicode: bool,
) !void {
    const line_text = source_info.getLineText(line);
    const span_len = if (label.span.end > label.span.start)
        @min(label.span.end - label.span.start, @as(u32, @intCast(line_text.len)) -| col)
    else
        1;

    try writeGutter(writer, gutter_width, null, color);
    if (unicode) try writer.writeAll(" \xc2\xb7 ") else try writer.writeAll(" . "); // ·

    var i: u32 = 0;
    while (i < col) : (i += 1) {
        if (i < line_text.len and line_text[i] == '\t') try writer.writeByte('\t') else try writer.writeByte(' ');
    }

    try ansi.setStyle(writer, .cyan, color);
    const underline_char: []const u8 = if (unicode) "\xe2\x94\x80" else "-"; // ─
    i = 0;
    while (i < span_len) : (i += 1) try writer.writeAll(underline_char);
    try ansi.setStyle(writer, .reset, color);

    if (label.message) |msg| {
        try writer.writeByte(' ');
        try ansi.styled(writer, .cyan, msg, color);
    }
    try writer.writeByte('\n');
}

/// 거터(줄 번호 영역) 렌더링.
/// line_num=null이면 빈 공백, 숫자가 있으면 우측 정렬.
fn writeGutter(writer: anytype, width: u32, line_num: ?u32, color: bool) !void {
    if (line_num) |num| {
        // 숫자를 우측 정렬하여 출력
        const num_width = digitCount(num);
        var pad: u32 = 0;
        while (pad + num_width < width) : (pad += 1) {
            try writer.writeByte(' ');
        }
        try ansi.setStyle(writer, .dim, color);
        try writer.print("{d}", .{num});
        try ansi.setStyle(writer, .reset, color);
    } else {
        // 빈 거터: width만큼 공백
        var i: u32 = 0;
        while (i < width) : (i += 1) {
            try writer.writeByte(' ');
        }
    }
}

/// 숫자의 10진수 자릿수를 반환한다. 0이면 1.
fn digitCount(n: u32) u32 {
    if (n == 0) return 1;
    var count: u32 = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

// ─── 테스트 ───

test "render: basic error with code frame" {
    const source = "const x = await fetch('/');";
    const offsets = [_]u32{0};
    const diag = RichDiagnostic{
        .severity = .@"error",
        .code = "ZTS0001",
        .message = "Top-level await is not available in the configured target environment",
        .span = .{ .start = 10, .end = 26 },
        .file_path = "src/app.ts",
        .help = "Set target to 'es2022' or higher to use top-level await",
    };
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), diag, info, .{ .color = false, .unicode = true });
    const out = fbs.getWritten();

    // 헤더에 아이콘 + 메시지 + 코드
    try std.testing.expect(std.mem.indexOf(u8, out, "Top-level await") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[ZTS0001]") != null);
    // 파일 참조
    try std.testing.expect(std.mem.indexOf(u8, out, "src/app.ts:1:11") != null);
    // 소스 줄
    try std.testing.expect(std.mem.indexOf(u8, out, "const x = await fetch('/');") != null);
    // 밑줄
    try std.testing.expect(std.mem.indexOf(u8, out, "^^^^^^^^^^^^^^^^") != null);
    // help
    try std.testing.expect(std.mem.indexOf(u8, out, "help: Set target to 'es2022'") != null);
}

test "render: multi-line source with context" {
    const source = "const a = 1;\nconst b = await fetch('/');\nconst c = 3;";
    const offsets = [_]u32{ 0, 13, 41 };
    const diag = RichDiagnostic{
        .severity = .warning,
        .message = "Await used at top level",
        .span = .{ .start = 23, .end = 40 },
        .file_path = "test.ts",
    };
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), diag, info, .{ .color = false, .unicode = true });
    const out = fbs.getWritten();

    // 에러 줄 전 컨텍스트 (line 1)
    try std.testing.expect(std.mem.indexOf(u8, out, "const a = 1;") != null);
    // 에러 줄 (line 2)
    try std.testing.expect(std.mem.indexOf(u8, out, "const b = await fetch('/');") != null);
    // 에러 줄 후 컨텍스트 (line 3)
    try std.testing.expect(std.mem.indexOf(u8, out, "const c = 3;") != null);
}

test "render: ASCII fallback (unicode=false)" {
    const source = "let x = 1;";
    const offsets = [_]u32{0};
    const diag = RichDiagnostic{
        .severity = .@"error",
        .message = "Test error",
        .span = .{ .start = 4, .end = 5 },
        .file_path = "test.ts",
    };
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), diag, info, .{ .color = false, .unicode = false });
    const out = fbs.getWritten();

    // ASCII 아이콘과 박스 문자
    try std.testing.expect(std.mem.indexOf(u8, out, "x Test error") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+-[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+----") != null);
}

test "render: with note" {
    const source = "debugger;";
    const offsets = [_]u32{0};
    const diag = RichDiagnostic{
        .severity = .info,
        .message = "debugger statement found",
        .span = .{ .start = 0, .end = 8 },
        .file_path = "test.ts",
        .note = "debugger statements are removed in production builds",
    };
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try render(fbs.writer(), diag, info, .{ .color = false, .unicode = true });
    const out = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, out, "note: debugger statements are removed") != null);
}

test "renderSimple: without source" {
    const diag = RichDiagnostic{
        .severity = .@"error",
        .code = "ZTS0100",
        .message = "Could not resolve './missing'",
        .span = .{ .start = 0, .end = 0 },
        .file_path = "src/index.ts",
        .help = "Did you mean './missing.js'?",
    };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try renderSimple(fbs.writer(), diag, .{ .color = false, .unicode = true });
    const out = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, out, "Could not resolve") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[ZTS0100]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "src/index.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "help: Did you mean") != null);
}

test "digitCount" {
    try std.testing.expectEqual(@as(u32, 1), digitCount(0));
    try std.testing.expectEqual(@as(u32, 1), digitCount(1));
    try std.testing.expectEqual(@as(u32, 1), digitCount(9));
    try std.testing.expectEqual(@as(u32, 2), digitCount(10));
    try std.testing.expectEqual(@as(u32, 3), digitCount(100));
    try std.testing.expectEqual(@as(u32, 4), digitCount(1000));
}
