//! 통합 진단 데이터 타입 (RichDiagnostic)
//!
//! 파서, 시맨틱 분석기, 번들러 등 여러 컴포넌트에서 발생하는
//! 진단 정보를 하나의 타입으로 통합한다.
//!
//! 기존 Diagnostic/BundlerDiagnostic은 그대로 유지하고,
//! 렌더링 시 fromDiagnostic()/fromBundlerDiagnostic()으로 변환한다.
//!
//! 설계:
//!   - severity: error/warning/info
//!   - 멀티 스팬 라벨: 여러 위치에 밑줄 + 설명
//!   - help/note: 수정 제안, 추가 정보
//!   - 에러 코드: [ZTS0001] 형식

const std = @import("std");
const Span = @import("lexer/token.zig").Span;
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const BundlerDiagnostic = @import("bundler/types.zig").BundlerDiagnostic;
const error_codes = @import("error_codes.zig");

/// 통합 진단 정보. 렌더러가 이 타입을 받아 포맷팅한다.
pub const RichDiagnostic = struct {
    /// 심각도
    severity: Severity,
    /// 에러 코드 (예: "ZTS0001"). null이면 코드를 표시하지 않음.
    code: ?[]const u8 = null,
    /// 주 메시지 (예: "Top-level await is not available in the configured target environment")
    message: []const u8,
    /// 주 에러 위치 (소스에서의 바이트 범위)
    span: Span,
    /// 에러가 발생한 파일 경로
    file_path: []const u8,
    /// 추가 라벨 (멀티 스팬). 주 span 외에 관련 위치를 표시할 때 사용.
    labels: []const Label = &.{},
    /// 수정 제안 (예: "Set target to 'es2022' or higher")
    help: ?[]const u8 = null,
    /// 추가 정보 (예: "Top-level await is an ES2022 feature")
    note: ?[]const u8 = null,

    pub const Severity = enum {
        @"error",
        warning,
        info,
    };

    /// 소스 코드의 특정 위치에 붙이는 라벨.
    /// 주 span 외에 "여기서 선언됨", "여기서 참조됨" 등을 표시할 때 사용.
    pub const Label = struct {
        span: Span,
        /// 라벨 메시지. null이면 밑줄만 표시.
        message: ?[]const u8 = null,
        /// primary=true: ^^^ (주 원인), false: --- (보조 정보)
        primary: bool = false,
    };
};

/// 렌더러에 전달할 소스 정보.
/// Scanner에서 변환하거나 직접 구성할 수 있다.
pub const SourceInfo = struct {
    /// 원본 소스 코드 전체
    source: []const u8,
    /// 각 줄의 시작 바이트 오프셋 (0번째 줄 = 0, 1번째 줄 = 첫 \n 다음 위치, ...)
    line_offsets: []const u32,

    /// 바이트 오프셋에서 행/열(0-based)을 계산한다.
    /// Scanner.getLineColumn()과 동일한 이진 탐색 로직.
    pub fn getLineColumn(self: SourceInfo, offset: u32) struct { line: u32, column: u32 } {
        const offsets = self.line_offsets;
        var lo: u32 = 0;
        var hi: u32 = @intCast(offsets.len);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (offsets[mid] <= offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const line = if (lo > 0) lo - 1 else 0;
        const line_start = if (line < offsets.len) offsets[line] else 0;
        return .{
            .line = line,
            .column = if (offset >= line_start) offset - line_start else 0,
        };
    }

    /// 지정한 줄(0-based)의 텍스트를 반환한다.
    /// 줄 바꿈 문자(\n, \r)는 포함하지 않는다.
    pub fn getLineText(self: SourceInfo, line: u32) []const u8 {
        if (line >= self.line_offsets.len) return "";

        const start = self.line_offsets[line];
        // 다음 줄 시작이 있으면 거기까지, 없으면 소스 끝까지
        const end_limit: u32 = if (line + 1 < self.line_offsets.len)
            self.line_offsets[line + 1]
        else
            @intCast(self.source.len);

        // 줄 끝의 \r\n 또는 \n 제거
        var end = end_limit;
        if (end > start and end <= self.source.len) {
            if (self.source[end - 1] == '\n') end -= 1;
            if (end > start and self.source[end - 1] == '\r') end -= 1;
        }

        if (start >= self.source.len) return "";
        return self.source[start..@min(end, @as(u32, @intCast(self.source.len)))];
    }

    /// Scanner에서 SourceInfo를 생성한다.
    /// Scanner의 line_offsets.items 슬라이스를 빌린다 (Scanner가 유효한 동안만 사용 가능).
    pub fn fromScanner(scanner: anytype) SourceInfo {
        return .{
            .source = scanner.source,
            .line_offsets = scanner.line_offsets.items,
        };
    }
};

// ─── 변환 함수 ───

/// 파서/시맨틱 Diagnostic을 RichDiagnostic으로 변환한다.
///
/// Diagnostic에는 severity가 없으므로 항상 .error로 설정한다.
/// related_span이 있으면 related_label을 RichDiagnostic.note로 전달한다.
/// (멀티 스팬 labels는 allocator가 필요하므로, 단순 변환에서는 note로 대체)
pub fn fromDiagnostic(d: Diagnostic, file_path: []const u8) RichDiagnostic {
    // related_span이 있으면 note로 위치 정보를 포함
    const note_text: ?[]const u8 = if (d.related_label) |label| label else null;

    return .{
        .severity = .@"error",
        .code = switch (d.kind) {
            .parse => error_codes.Code.parse_error.format(),
            .semantic => error_codes.Code.semantic_error.format(),
        },
        .message = d.message,
        .span = d.span,
        .file_path = file_path,
        .help = d.hint,
        .note = note_text,
    };
}

/// BundlerDiagnostic을 RichDiagnostic으로 변환한다.
pub fn fromBundlerDiagnostic(d: BundlerDiagnostic) RichDiagnostic {
    return .{
        .severity = switch (d.severity) {
            .@"error" => .@"error",
            .warning => .warning,
            .info => .info,
        },
        .code = switch (d.code) {
            .unresolved_import => error_codes.Code.unresolved_import.format(),
            .missing_export => error_codes.Code.missing_export.format(),
            .circular_dependency => error_codes.Code.circular_dependency.format(),
            .parse_error => error_codes.Code.parse_error.format(),
            .read_error => error_codes.Code.read_error.format(),
            .json_parse_error => error_codes.Code.json_parse_error.format(),
            .no_loader => error_codes.Code.no_loader.format(),
            .resolve_error => null,
        },
        .message = d.message,
        .span = d.span,
        .file_path = d.file_path,
        .help = d.suggestion,
    };
}

// ─── 테스트 ───

test "SourceInfo.getLineColumn: single line" {
    const source = "hello world";
    const offsets = [_]u32{0};
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    const lc = info.getLineColumn(6);
    try std.testing.expectEqual(@as(u32, 0), lc.line);
    try std.testing.expectEqual(@as(u32, 6), lc.column); // 'w'
}

test "SourceInfo.getLineColumn: multi line" {
    const source = "line1\nline2\nline3";
    const offsets = [_]u32{ 0, 6, 12 };
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    // 'l' of "line2"
    const lc1 = info.getLineColumn(6);
    try std.testing.expectEqual(@as(u32, 1), lc1.line);
    try std.testing.expectEqual(@as(u32, 0), lc1.column);

    // '3' of "line3"
    const lc2 = info.getLineColumn(16);
    try std.testing.expectEqual(@as(u32, 2), lc2.line);
    try std.testing.expectEqual(@as(u32, 4), lc2.column);
}

test "SourceInfo.getLineText: basic" {
    const source = "aaa\nbbb\nccc";
    const offsets = [_]u32{ 0, 4, 8 };
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    try std.testing.expectEqualStrings("aaa", info.getLineText(0));
    try std.testing.expectEqualStrings("bbb", info.getLineText(1));
    try std.testing.expectEqualStrings("ccc", info.getLineText(2));
}

test "SourceInfo.getLineText: CRLF" {
    const source = "aaa\r\nbbb\r\n";
    const offsets = [_]u32{ 0, 5 };
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    try std.testing.expectEqualStrings("aaa", info.getLineText(0));
    try std.testing.expectEqualStrings("bbb", info.getLineText(1));
}

test "SourceInfo.getLineText: out of range" {
    const source = "hello";
    const offsets = [_]u32{0};
    const info = SourceInfo{ .source = source, .line_offsets = &offsets };

    try std.testing.expectEqualStrings("", info.getLineText(99));
}

test "fromDiagnostic: converts parse error" {
    const d = Diagnostic{
        .span = .{ .start = 10, .end = 15 },
        .message = "Expected ';'",
        .kind = .parse,
        .hint = "Insert a semicolon here",
    };
    const rich = fromDiagnostic(d, "test.ts");

    try std.testing.expectEqual(RichDiagnostic.Severity.@"error", rich.severity);
    try std.testing.expectEqualStrings("Expected ';'", rich.message);
    try std.testing.expectEqualStrings("test.ts", rich.file_path);
    try std.testing.expectEqualStrings("Insert a semicolon here", rich.help.?);
    try std.testing.expect(rich.code != null);
}

test "fromDiagnostic: includes related span as note" {
    const d = Diagnostic{
        .span = .{ .start = 20, .end = 25 },
        .message = "Unexpected '}'",
        .related_span = .{ .start = 5, .end = 6 },
        .related_label = "opening '{' is here",
        .kind = .parse,
    };
    const rich = fromDiagnostic(d, "test.ts");

    try std.testing.expect(rich.note != null);
    try std.testing.expectEqualStrings("opening '{' is here", rich.note.?);
}
