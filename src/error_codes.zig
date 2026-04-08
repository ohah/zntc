//! ZTS 에러 코드 레지스트리
//!
//! 모든 진단 메시지에 고유 코드를 부여한다.
//! 코드 형식: "ZTS" + 4자리 숫자 (예: ZTS0001)
//!
//! 용도:
//!   - 에러 메시지에 [ZTS0001] 형태로 표시
//!   - 향후 `zts --explain ZTS0001`로 상세 설명 출력
//!   - 문서 사이트에서 에러별 해결 가이드 링크

/// 에러 코드. 각 항목은 고유한 번호를 가진다.
/// 새 에러를 추가할 때 번호를 순차적으로 부여한다.
pub const Code = enum(u16) {
    // ─── 타겟/호환성 (0001-0099) ───

    /// Top-level await는 ES2022 이상에서만 사용 가능
    top_level_await_target = 1,

    // ─── 번들러: import/export (0100-0199) ───

    /// import 경로를 resolve할 수 없음
    unresolved_import = 100,
    /// export 이름을 찾을 수 없음
    missing_export = 101,
    /// 순환 참조 감지
    circular_dependency = 102,

    // ─── 번들러: 파일/로더 (0200-0299) ───

    /// 파일 읽기 실패
    read_error = 200,
    /// JSON 파싱 실패
    json_parse_error = 201,
    /// 확장자에 대한 로더 미설정
    no_loader = 202,

    // ─── 파서/시맨틱 (0300-0399) ───

    /// 구문 오류
    parse_error = 300,
    /// 시맨틱 오류 (재선언, private name 등)
    semantic_error = 301,

    /// 에러 코드를 "ZTS0001" 형식의 문자열로 반환한다.
    /// comptime에서 계산되므로 런타임 할당이 없다.
    pub fn format(self: Code) []const u8 {
        // 각 variant별 문자열을 inline switch로 반환 (comptime 보장)
        return switch (self) {
            inline else => |v| comptime std.fmt.comptimePrint("ZTS{d:0>4}", .{@intFromEnum(v)}),
        };
    }

    /// 이 에러 코드의 기본 메시지를 반환한다.
    pub fn message(self: Code) []const u8 {
        return switch (self) {
            .top_level_await_target => "Top-level await is not available in the configured target environment",
            .unresolved_import => "Could not resolve import",
            .missing_export => "Export not found in module",
            .circular_dependency => "Circular dependency detected",
            .read_error => "Failed to read file",
            .json_parse_error => "Failed to parse JSON",
            .no_loader => "No loader is configured for this file type",
            .parse_error => "Syntax error",
            .semantic_error => "Semantic error",
        };
    }
};

const std = @import("std");

// ─── 테스트 ───

test "Code.format: ZTS0001" {
    try std.testing.expectEqualStrings("ZTS0001", Code.top_level_await_target.format());
}

test "Code.format: ZTS0100" {
    try std.testing.expectEqualStrings("ZTS0100", Code.unresolved_import.format());
}

test "Code.format: ZTS0300" {
    try std.testing.expectEqualStrings("ZTS0300", Code.parse_error.format());
}

test "Code.message: returns non-empty" {
    const fields = @typeInfo(Code).@"enum".fields;
    inline for (fields) |f| {
        const code: Code = @enumFromInt(f.value);
        try std.testing.expect(code.message().len > 0);
    }
}
