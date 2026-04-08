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
