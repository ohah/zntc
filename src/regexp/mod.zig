//! ZNTC RegExp Validator
//!
//! ECMAScript 정규식 리터럴의 유효성을 검증한다.
//! 렉서에서 `/pattern/flags` 토큰을 스캔한 후 호출.
//!
//! 설계:
//!   - comptime emit_ast 파라미터로 검증/AST 모드 분리
//!   - emit_ast=false: 검증만, 할당 없음 (렉서에서 사용)
//!   - emit_ast=true: AST 빌드, allocator 필요 (트랜스포머에서 사용)
//!   - 파싱 로직은 하나, 모드만 다름
//!
//! 모듈 구조:
//!   - mod.zig: 공개 API (validate, parse)
//!   - ast.zig: AST 노드 타입 (Node, Tag, RegExpAst 등)
//!   - flags.zig: 플래그 검증 (d/g/i/m/s/u/v/y)
//!   - parser.zig: 패턴 파서 (comptime emit_ast 지원)
//!   - diagnostics.zig: 에러 메시지
//!
//! 참고: references/oxc/crates/oxc_regular_expression

pub const ast = @import("ast.zig");
pub const flags = @import("flags.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const parser = @import("parser.zig");
pub const printer = @import("printer.zig");
pub const transform = @import("transform.zig");
pub const codepoint_set = @import("codepoint_set.zig");
pub const iu_case_fold = @import("iu_case_fold.zig");
pub const unicode_property = @import("unicode_property.zig");

/// 정규식 리터럴을 검증한다.
/// pattern: `/` 사이의 패턴 텍스트 (예: "\\d{4}")
/// flag_text: 닫는 `/` 뒤의 플래그 텍스트 (예: "gi")
/// scratch_alloc: named group/backref 가 inline cap(16/32)을 초과할 때만
///   spill 에 사용. 일반 정규식은 무할당 (렉서 hot path 성능 무변).
/// 에러가 있으면 에러 메시지를 반환, 없으면 null.
pub fn validate(pattern: []const u8, flag_text: []const u8, scratch_alloc: std.mem.Allocator) ?[]const u8 {
    // 1. 플래그 검증 — 구체적인 에러 메시지를 보존
    if (flags.validate(flag_text)) |err| {
        return err.message;
    }

    // 2. 패턴 검증
    const parsed_flags = flags.parse(flag_text);
    const Validator = parser.PatternParser(false);
    var validator = Validator.init(pattern, parsed_flags);
    validator.ext_alloc = scratch_alloc;
    if (validator.validate()) |err| {
        return err;
    }

    return null;
}

/// 정규식 리터럴을 파싱하여 AST를 반환한다.
/// allocator: AST 노드 저장용.
/// 에러가 있으면 null, 성공 시 RegExpAst 반환.
/// 반환된 RegExpAst의 소유권은 호출자에게 있으며,
/// 사용 후 반드시 deinit()을 호출해야 한다.
///
/// 사용 예:
///   var tree = parse("\\d{4}", "gi", allocator) orelse return error;
///   defer tree.deinit();
pub fn parse(
    pattern: []const u8,
    flag_text: []const u8,
    allocator: std.mem.Allocator,
) ?ast.RegExpAst {
    // 1. 플래그 검증
    // 반환 타입이 ?RegExpAst이므로 에러 메시지는 전달할 수 없음.
    // 구체적 에러가 필요하면 flags.validate()를 직접 호출.
    if (flags.validate(flag_text) != null) {
        return null;
    }

    // 2. 패턴 파싱 + AST 빌드
    // 성공 시 parse()가 toOwnedSlice 로 소유권 이전 → p.deinit()은 빈
    // ArrayList 해제(no-op). 에러 시 parse()는 ast_nodes/ast_extra 를
    // 해제하지 않으므로 defer p.deinit()이 누수를 막는다 (#3503).
    const parsed_flags = flags.parse(flag_text);
    const Parser = parser.PatternParser(true);
    var p = Parser.initWithAllocator(pattern, parsed_flags, allocator);
    defer p.deinit();
    return p.parse();
}

const std = @import("std");

test {
    _ = ast;
    _ = flags;
    _ = diagnostics;
    _ = parser;
    _ = printer;
    _ = transform;
    _ = codepoint_set;
    _ = iu_case_fold;
    _ = unicode_property;

    // test files
    _ = @import("parser_test.zig");
    _ = @import("unicode_property_test.zig");
    _ = @import("flags_test.zig");
    _ = @import("ast_test.zig");
    _ = @import("printer_test.zig");
    _ = @import("transform_test.zig");
    _ = @import("codepoint_set_test.zig");
}
