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

/// 재선언 계열 에러의 secondary label 문구.
/// ZTS1000/1100/1200/1202/1300/515/703 등에서 원본 선언 위치를 가리킬 때 재사용.
pub const PREVIOUSLY_DECLARED_HERE = "previously declared here";

/// 진단 라벨 — 에러의 primary span(`Diagnostic.span`) 외 관련 위치를 가리킨다.
/// 재선언 에러의 "previously declared here", 브래킷 매칭 에러의 "opening '{' is here" 등.
pub const Label = struct {
    span: Span,
    /// 라벨 메시지. null이면 밑줄만 표시.
    message: ?[]const u8 = null,
};

/// 통합 진단 정보.
/// 파서와 시맨틱 분석기 모두 이 타입으로 에러를 보고한다.
pub const Diagnostic = struct {
    /// 에러 발생 위치 (primary span)
    span: Span,
    /// 에러 메시지 (예: "Expected ';'", "Identifier 'x' has already been declared")
    message: []const u8,
    /// 에러 코드 (예: .import_in_script → ZTS0300). null이면 kind 기반 기본 코드 사용.
    code: ?ErrorCode = null,
    /// 실제로 발견된 토큰 (예: "'}'"). null이면 표시하지 않음.
    found: ?[]const u8 = null,
    /// 추가 라벨 — primary span 외의 관련 위치.
    /// 재선언/참조 연결 에러에서 "원본 선언 위치" 등을 가리킨다. arena 소유.
    labels: []const Label = &.{},
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
    labels: []const Label = &.{},
    hint: ?[]const u8 = null,
    kind: Diagnostic.Kind = .parse,

    /// Diagnostic을 allocator 소유로 복사해 OwnedDiagnostic을 만든다.
    /// 실패 시 이미 복사된 필드를 되돌려 free하고 error.OutOfMemory 반환.
    pub fn init(d: Diagnostic, allocator: std.mem.Allocator) !OwnedDiagnostic {
        const message = try allocator.dupe(u8, d.message);
        errdefer allocator.free(message);

        const found = if (d.found) |s| try allocator.dupe(u8, s) else null;
        errdefer if (found) |s| allocator.free(s);

        const labels = try dupeLabels(d.labels, allocator);
        errdefer freeLabels(labels, allocator);

        const hint = if (d.hint) |s| try allocator.dupe(u8, s) else null;

        return .{
            .span = d.span,
            .code = d.code,
            .kind = d.kind,
            .message = message,
            .found = found,
            .labels = labels,
            .hint = hint,
        };
    }

    pub fn deinit(self: OwnedDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.found) |s| allocator.free(s);
        if (self.hint) |s| allocator.free(s);
        freeLabels(self.labels, allocator);
    }

    /// 같은 필드를 가진 Diagnostic 값으로 변환. 렌더러의 fromDiagnostic() 재사용용.
    /// 반환값은 self의 포인터만 빌리므로 self의 수명 안에서만 유효.
    pub fn asDiagnostic(self: OwnedDiagnostic) Diagnostic {
        return .{
            .span = self.span,
            .message = self.message,
            .code = self.code,
            .found = self.found,
            .labels = self.labels,
            .hint = self.hint,
            .kind = self.kind,
        };
    }
};

fn dupeLabels(labels: []const Label, allocator: std.mem.Allocator) ![]const Label {
    if (labels.len == 0) return &.{};
    const buf = try allocator.alloc(Label, labels.len);
    var filled: usize = 0;
    errdefer {
        for (buf[0..filled]) |l| if (l.message) |m| allocator.free(m);
        allocator.free(buf);
    }
    for (labels) |l| {
        const msg = if (l.message) |m| try allocator.dupe(u8, m) else null;
        buf[filled] = .{ .span = l.span, .message = msg };
        filled += 1;
    }
    return buf;
}

fn freeLabels(labels: []const Label, allocator: std.mem.Allocator) void {
    for (labels) |l| if (l.message) |m| allocator.free(m);
    if (labels.len > 0) allocator.free(labels);
}

// ─── 테스트 ───

test "OwnedDiagnostic.init: duplicates all strings and frees on deinit" {
    const allocator = std.testing.allocator;
    const sample_labels = [_]Label{
        .{ .span = .{ .start = 0, .end = 1 }, .message = "previously declared here" },
    };
    const d = Diagnostic{
        .span = .{ .start = 3, .end = 7 },
        .message = "Identifier 'x' has already been declared",
        .code = .identifier_redeclared,
        .found = "x",
        .labels = &sample_labels,
        .hint = "Use a different name",
        .kind = .semantic,
    };

    const owned = try OwnedDiagnostic.init(d, allocator);
    defer owned.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 3), owned.span.start);
    try std.testing.expectEqual(ErrorCode.identifier_redeclared, owned.code.?);
    try std.testing.expectEqualStrings("Identifier 'x' has already been declared", owned.message);
    try std.testing.expectEqualStrings("x", owned.found.?);
    try std.testing.expectEqual(@as(usize, 1), owned.labels.len);
    try std.testing.expectEqualStrings("previously declared here", owned.labels[0].message.?);
    try std.testing.expectEqualStrings("Use a different name", owned.hint.?);
    try std.testing.expectEqual(Diagnostic.Kind.semantic, owned.kind);

    // allocator dup 검증 — 원본과 독립된 포인터
    try std.testing.expect(owned.message.ptr != d.message.ptr);
    try std.testing.expect(owned.labels.ptr != d.labels.ptr);
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
    try std.testing.expectEqual(@as(usize, 0), owned.labels.len);
    try std.testing.expect(owned.hint == null);
}
