//! ZTS Diagnostic
//!
//! 파서와 시맨틱 분석기가 공통으로 사용하는 진단 정보 타입.
//! ParseError와 SemanticError를 통합한다.
//!
//! 설계:
//!   - ParseError의 풍부한 필드(found, related_span, hint)를 기본으로
//!   - SemanticError는 span + message만 사용하므로 나머지는 null
//!   - kind로 에러 출처를 구분 (parse, semantic)
//!   - CLI에서 동일한 코드 프레임 포맷으로 출력 가능

const std = @import("std");
const Span = @import("lexer/token.zig").Span;
const ErrorCode = @import("error_codes.zig").Code;

/// 통합 진단 정보.
/// 파서와 시맨틱 분석기 모두 이 타입으로 에러를 보고한다.
pub const Diagnostic = struct {
    /// 에러 발생 위치
    span: Span,
    /// 에러 메시지 (예: "Expected ';'", "Identifier 'x' has already been declared")
    message: []const u8,
    /// 에러 코드 (예: .import_in_script → ZTS0300). null이면 kind 기반 기본 코드 사용.
    code: ?ErrorCode = null,
    /// 실제로 발견된 토큰 (예: "'}'"). null이면 표시하지 않음.
    found: ?[]const u8 = null,
    /// 관련 위치 (예: 여는 괄호 위치). null이면 표시하지 않음.
    related_span: ?Span = null,
    /// 관련 위치 설명 (예: "opening bracket is here"). null이면 표시하지 않음.
    related_label: ?[]const u8 = null,
    /// 힌트 메시지 (예: "Try inserting a semicolon here"). null이면 표시하지 않음.
    hint: ?[]const u8 = null,
    /// 에러 출처
    kind: Kind = .parse,

    pub const Kind = enum {
        /// 파서 에러 (구문 오류)
        parse,
        /// 시맨틱 에러 (의미 오류: 재선언, private name 등)
        semantic,
    };
};

/// Arena 수명을 탈출한 Diagnostic. 모든 문자열 필드가 allocator 소유.
///
/// 파서/시맨틱 에러는 Parser/Analyzer의 arena에 살지만, WASM/NAPI/CLI가
/// transpile() 반환 이후에도 에러 정보를 참조해야 하므로 arena 해제 전에
/// allocator로 복사해 OwnedDiagnostic 배열로 result에 담는다.
///
/// deinit()은 각 문자열 필드를 allocator로 free한다.
pub const OwnedDiagnostic = struct {
    span: Span,
    message: []const u8,
    code: ?ErrorCode = null,
    found: ?[]const u8 = null,
    related_span: ?Span = null,
    related_label: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    kind: Diagnostic.Kind = .parse,

    /// Diagnostic을 allocator 소유로 복사해 OwnedDiagnostic을 만든다.
    /// 실패 시 이미 복사된 필드를 되돌려 free하고 error.OutOfMemory 반환.
    pub fn init(d: Diagnostic, allocator: std.mem.Allocator) !OwnedDiagnostic {
        const message = try allocator.dupe(u8, d.message);
        errdefer allocator.free(message);

        const found = if (d.found) |s| try allocator.dupe(u8, s) else null;
        errdefer if (found) |s| allocator.free(s);

        const related_label = if (d.related_label) |s| try allocator.dupe(u8, s) else null;
        errdefer if (related_label) |s| allocator.free(s);

        const hint = if (d.hint) |s| try allocator.dupe(u8, s) else null;

        return .{
            .span = d.span,
            .code = d.code,
            .kind = d.kind,
            .related_span = d.related_span,
            .message = message,
            .found = found,
            .related_label = related_label,
            .hint = hint,
        };
    }

    pub fn deinit(self: OwnedDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.found) |s| allocator.free(s);
        if (self.related_label) |s| allocator.free(s);
        if (self.hint) |s| allocator.free(s);
    }

    /// 같은 필드를 가진 Diagnostic 값으로 변환. 렌더러의 fromDiagnostic() 재사용용.
    /// 반환값은 self의 포인터만 빌리므로 self의 수명 안에서만 유효.
    pub fn asDiagnostic(self: OwnedDiagnostic) Diagnostic {
        return .{
            .span = self.span,
            .message = self.message,
            .code = self.code,
            .found = self.found,
            .related_span = self.related_span,
            .related_label = self.related_label,
            .hint = self.hint,
            .kind = self.kind,
        };
    }
};

// ─── 테스트 ───

test "OwnedDiagnostic.init: duplicates all strings and frees on deinit" {
    const allocator = std.testing.allocator;
    const d = Diagnostic{
        .span = .{ .start = 3, .end = 7 },
        .message = "Identifier 'x' has already been declared",
        .code = .identifier_redeclared,
        .found = "x",
        .related_span = .{ .start = 0, .end = 1 },
        .related_label = "previously declared here",
        .hint = "Use a different name",
        .kind = .semantic,
    };

    const owned = try OwnedDiagnostic.init(d, allocator);
    defer owned.deinit(allocator);

    // 필드 값은 보존
    try std.testing.expectEqual(@as(u32, 3), owned.span.start);
    try std.testing.expectEqual(ErrorCode.identifier_redeclared, owned.code.?);
    try std.testing.expectEqualStrings("Identifier 'x' has already been declared", owned.message);
    try std.testing.expectEqualStrings("x", owned.found.?);
    try std.testing.expectEqualStrings("previously declared here", owned.related_label.?);
    try std.testing.expectEqualStrings("Use a different name", owned.hint.?);
    try std.testing.expectEqual(Diagnostic.Kind.semantic, owned.kind);

    // 문자열이 원본과 독립된 포인터인지 (allocator dup 검증)
    try std.testing.expect(owned.message.ptr != d.message.ptr);
}

test "OwnedDiagnostic.init: all optional fields null" {
    const allocator = std.testing.allocator;
    const d = Diagnostic{
        .span = .{ .start = 0, .end = 1 },
        .message = "Expected ';'",
    };

    const owned = try OwnedDiagnostic.init(d, allocator);
    defer owned.deinit(allocator);

    try std.testing.expect(owned.code == null);
    try std.testing.expect(owned.found == null);
    try std.testing.expect(owned.related_span == null);
    try std.testing.expect(owned.related_label == null);
    try std.testing.expect(owned.hint == null);
}
