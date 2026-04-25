//! ZTS 에러 코드 레지스트리
//!
//! 모든 진단 메시지에 고유 코드를 부여한다.
//! 코드 형식: "ZTS" + 4자리 숫자 (예: ZTS0001)
//!
//! 번호 체계:
//!   0001-0099  타겟/호환성
//!   0100-0199  번들러: import/export/resolve
//!   0200-0299  번들러: 파일/로더
//!   0300-0399  파서: import/export
//!   0400-0499  파서: 선언/클래스
//!   0500-0599  파서: 바인딩/식별자/파라미터
//!   0600-0699  파서: 식/연산자
//!   0700-0799  파서: 문/제어 흐름
//!   0800-0899  파서: strict mode
//!   0900-0999  파서: 템플릿/JSX/TS/Flow
//!   1000-1099  시맨틱: 재선언/스코프
//!   1100-1199  시맨틱: private member
//!   1200-1299  시맨틱: export/label
//!   1300-1399  시맨틱: class/getter/setter/object

/// 문서 사이트 에러 레퍼런스 base URL. Code.docsUrl이 여기에 코드를 붙여 전체 URL 생성.
const docs_url_base = "https://ohah.github.io/zts/reference/errors/";

/// 에러 코드. 각 항목은 고유한 번호를 가진다.
pub const Code = enum(u16) {
    // ═══════════════════════════════════════════════════════
    // 0001-0099: 타겟/호환성
    // ═══════════════════════════════════════════════════════
    top_level_await_target = 1,
    /// Top-level await는 ESM 포맷 전용 — CJS/IIFE/UMD/AMD 에서는 런타임 동작 불가.
    /// bundler emitter 에서 non-ESM 포맷 + TLA 조합 감지 시 경고로 emit.
    tla_requires_esm_format = 2,
    /// Code splitting / preserveModules 는 dynamic import 활용한 multi-chunk 시나리오 —
    /// ESM 만 지원 (cjs/iife/umd/amd 의 require/wrapper 시스템과 호환 X). esbuild/rollup 동일.
    splitting_requires_esm_format = 3,
    /// build / build_chunks 의 entry path 가 비어있거나 VFS 에 미등록.
    invalid_entry_path = 4,

    // ═══════════════════════════════════════════════════════
    // 0100-0199: 번들러 — import/export/resolve
    // ═══════════════════════════════════════════════════════
    unresolved_import = 100,
    missing_export = 101,
    circular_dependency = 102,
    resolve_error = 103,
    circular_reexport = 104,

    // ═══════════════════════════════════════════════════════
    // 0200-0299: 번들러 — 파일/로더
    // ═══════════════════════════════════════════════════════
    read_error = 200,
    json_parse_error = 201,
    no_loader = 202,

    // ═══════════════════════════════════════════════════════
    // 0300-0399: 파서 — import/export
    // ═══════════════════════════════════════════════════════
    import_in_script = 300,
    import_not_top_level = 301,
    import_defer_requires_binding = 302,
    import_string_requires_as = 303,
    duplicate_import_attribute = 304,
    export_in_script = 305,
    export_not_top_level = 306,
    export_string_local_binding = 307,
    module_source_expected = 308,
    export_in_statement = 309,
    import_in_statement = 310,
    import_cannot_new = 311,
    import_meta_in_script = 312,
    import_meta_expected = 313,
    import_source_requires_args = 314,

    // ═══════════════════════════════════════════════════════
    // 0400-0499: 파서 — 선언/클래스
    // ═══════════════════════════════════════════════════════
    anon_function_invoked = 400,
    function_in_statement = 401,
    function_in_statement_strict = 402,
    generator_in_statement = 403,
    async_function_in_statement = 404,
    class_in_statement = 405,
    class_constructor_invalid = 406,
    class_member_hash_constructor = 407,
    class_field_constructor = 408,
    static_field_prototype = 409,
    static_method_prototype = 410,
    class_after_decorator = 411,
    class_or_export_after_decorator = 412,
    labelled_function_in_loop = 413,
    lexical_in_statement = 414,

    // ═══════════════════════════════════════════════════════
    // 0500-0599: 파서 — 바인딩/식별자/파라미터
    // ═══════════════════════════════════════════════════════
    identifier_expected = 500,
    binding_pattern_expected = 501,
    escaped_reserved_word = 502,
    escaped_reserved_word_strict = 503,
    reserved_word_identifier = 504,
    reserved_word_identifier_strict = 505,
    keywords_escape = 506,
    let_in_lexical = 507,
    const_not_initialized = 508,
    async_identifier_for_of = 509,
    let_identifier_for_of = 510,
    single_var_for_in_of = 511,
    for_in_of_initializer = 512,
    rest_must_be_last = 513,
    rest_trailing_comma = 514,
    duplicate_parameter = 515,
    private_in_destructuring = 516,
    invalid_assignment_target = 517,
    assignment_eval_arguments_strict = 518,

    // ═══════════════════════════════════════════════════════
    // 0600-0699: 파서 — 식/연산자
    // ═══════════════════════════════════════════════════════
    expression_expected = 600,
    unary_exponentiation = 601,
    nullish_mix_logical = 602,
    private_outside_in = 603,
    private_rhs_in = 604,
    private_delete = 605,
    private_super_access = 606,
    super_outside_method = 620,
    super_call_outside_constructor = 621,
    tagged_template_optional = 607,
    property_key_expected = 608,
    property_colon_expected = 609,
    shorthand_initializer = 610,
    reserved_shorthand = 611,
    reserved_shorthand_strict = 612,
    yield_shorthand_generator = 613,
    await_shorthand_async = 614,
    private_object_key = 615,
    arguments_class_field = 616,
    arguments_class_static = 617,
    string_lone_surrogate = 618,
    new_target_outside_function = 619,

    // ═══════════════════════════════════════════════════════
    // 0700-0799: 파서 — 문/제어 흐름
    // ═══════════════════════════════════════════════════════
    return_outside_function = 700,
    break_outside = 701,
    continue_outside = 702,
    switch_duplicate_default = 703,
    case_default_expected = 704,
    catch_finally_expected = 705,
    throw_newline = 706,
    escaped_reserved_label = 707,
    escaped_reserved_label_strict = 708,
    reserved_label_strict = 709,

    // ═══════════════════════════════════════════════════════
    // 0800-0899: 파서 — strict mode
    // ═══════════════════════════════════════════════════════
    with_strict = 800,
    octal_literal_strict = 801,
    octal_escape_strict = 802,
    delete_identifier_strict = 803,
    use_strict_non_simple = 804,

    // ═══════════════════════════════════════════════════════
    // 0900-0999: 파서 — await/yield/템플릿/JSX/TS/Flow
    // ═══════════════════════════════════════════════════════
    await_identifier = 900,
    await_in_parameters = 901,
    await_in_static_initializer = 902,
    await_in_non_async_module = 903,
    await_in_arrow_params = 904,
    await_in_async_arrow_params = 905,
    yield_in_parameters = 906,
    yield_in_arrow_params = 907,
    template_invalid_escape = 908,
    template_continuation_expected = 909,
    jsx_tag_expected = 910,
    jsx_spread_expected = 911,
    ts_type_expected = 912,
    ts_mapped_type_in = 913,
    flow_opaque_type = 914,
    ts_index_sig_modifier = 915,
    ts_index_sig_optional = 916,

    // ═══════════════════════════════════════════════════════
    // 1000-1099: 시맨틱 — 재선언/스코프
    // ═══════════════════════════════════════════════════════
    identifier_redeclared = 1000,
    binding_strict_mode = 1001,

    // ═══════════════════════════════════════════════════════
    // 1100-1199: 시맨틱 — private member
    // ═══════════════════════════════════════════════════════
    private_redeclared = 1100,
    private_undeclared = 1101,

    // ═══════════════════════════════════════════════════════
    // 1200-1299: 시맨틱 — export/label
    // ═══════════════════════════════════════════════════════
    duplicate_export = 1200,
    export_not_defined = 1201,
    label_redeclared = 1202,
    continue_non_loop_label = 1203,
    undefined_label = 1204,

    // ═══════════════════════════════════════════════════════
    // 1300-1399: 시맨틱 — class/getter/setter/object
    // ═══════════════════════════════════════════════════════
    duplicate_constructor = 1300,
    proto_duplicate = 1301,
    getter_no_params = 1302,
    setter_one_param = 1303,

    /// 에러 코드를 "ZTS0001" 형식의 문자열로 반환한다.
    pub fn format(self: Code) []const u8 {
        @setEvalBranchQuota(100_000);
        return switch (self) {
            inline else => |v| comptime std.fmt.comptimePrint("ZTS{d:0>4}", .{@intFromEnum(v)}),
        };
    }

    /// 이 코드에 해당하는 문서 URL. comptime const 반환, 할당 없음.
    /// 문서 사이트 라우트는 소문자 `zts` 폴더를 사용 (사이트 빌더가 소문자 slug).
    pub fn docsUrl(self: Code) []const u8 {
        @setEvalBranchQuota(100_000);
        return switch (self) {
            inline else => |v| comptime std.fmt.comptimePrint(docs_url_base ++ "zts{d:0>4}/", .{@intFromEnum(v)}),
        };
    }

    /// 에러 수정 힌트. 없으면 null.
    /// comptime const 문자열만 반환 — 할당 없음. 렌더러가 "help: ..." 로 출력.
    pub fn help(self: Code) ?[]const u8 {
        return switch (self) {
            // 시맨틱 재선언/참조 (PR 2/2.5/3에서 커버한 에러들)
            .identifier_redeclared => "Use a different identifier, or change 'let'/'const' to 'var' if redeclaration is intended.",
            .private_redeclared => "Private field names must be unique within a class. Rename one of the declarations.",
            .private_undeclared => "Private fields must be declared in an enclosing class body before being referenced.",
            .duplicate_export => "Rename one of the exports, or use a single 'export { x as a, y as b }' form.",
            .export_not_defined => "Ensure the exported name is declared in module scope before the export statement.",
            .label_redeclared => "Label names must be unique within the enclosing function. Rename the inner label.",
            .undefined_label => "The 'break'/'continue' label must match a label declared in an enclosing statement.",
            .continue_non_loop_label => "'continue' requires the target label to be attached to a loop (for/while/do).",
            .duplicate_constructor => "Merge the constructor bodies into a single 'constructor()' method.",
            .duplicate_parameter => "Parameter names must be unique in strict mode and within destructuring patterns.",
            .switch_duplicate_default => "A 'switch' can have at most one 'default' case — remove the duplicate.",
            // 타겟
            .top_level_await_target => "Set --target=es2022 or later, or wrap the code in an 'async' function.",
            .tla_requires_esm_format => "Use --format=esm, or wrap the top-level await in an async IIFE.",
            .splitting_requires_esm_format => "Use --format=esm, or disable codeSplitting/preserveModules.",
            .invalid_entry_path => "Provide a non-empty entry path that exists in the VFS / file system.",
            // 번들러
            .unresolved_import => "Check the import path spelling and confirm the file exists.",
            .missing_export => "Verify the exported name. Use 'export * from' or named re-exports if needed.",
            else => null,
        };
    }

    /// Recoverable validation 에러인지 판정.
    /// true면 AST 구조는 정상이고 런타임(V8/Hermes 등)도 실행하므로, 번들러는
    /// 모듈을 스킵하지 말고 계속 진행해야 한다 (esbuild/rollup 동일 정책).
    ///
    /// 예: `"use strict"` + non-simple params는 ECMAScript 14.1.2상 SyntaxError
    /// 이지만 모든 실제 엔진에서 실행됨 — webpack UMD 번들에 흔히 존재 (#1291).
    pub fn isRecoverable(self: Code) bool {
        return switch (self) {
            .use_strict_non_simple => true,
            else => false,
        };
    }

    /// 이 에러 코드의 기본 메시지를 반환한다.
    pub fn message(self: Code) []const u8 {
        return switch (self) {
            // 타겟
            .top_level_await_target => "Top-level await is not available in the configured target environment",
            .tla_requires_esm_format => "Top-level await requires ESM output format",
            .splitting_requires_esm_format => "Code splitting / preserveModules requires ESM output format",
            .invalid_entry_path => "Entry path is empty or not found",
            // 번들러
            .unresolved_import => "Could not resolve import",
            .missing_export => "Export not found in module",
            .circular_dependency => "Circular dependency detected",
            .resolve_error => "Module resolution failed",
            .circular_reexport => "Re-export references the module itself (self-cycle)",
            .read_error => "Failed to read file",
            .json_parse_error => "Failed to parse JSON",
            .no_loader => "No loader is configured for this file type",
            // 파서: import/export
            .import_in_script => "'import' declaration is only allowed in module code",
            .import_not_top_level => "'import' declaration must be at the top level",
            .import_defer_requires_binding => "'import defer/source' requires a binding",
            .import_string_requires_as => "String literal in import specifier requires 'as' binding",
            .duplicate_import_attribute => "Duplicate import attribute key",
            .export_in_script => "'export' declaration is only allowed in module code",
            .export_not_top_level => "'export' declaration must be at the top level",
            .export_string_local_binding => "String literal cannot be used as local binding in export",
            .module_source_expected => "Module source string expected",
            .export_in_statement => "'export' is not allowed in statement position",
            .import_in_statement => "'import' is not allowed in statement position",
            .import_cannot_new => "'import' cannot be used with 'new'",
            .import_meta_in_script => "'import.meta' is only allowed in module code",
            .import_meta_expected => "Expected 'import.meta', 'import.source', or 'import.defer'",
            .import_source_requires_args => "'import.source'/'import.defer' requires arguments",
            // 파서: 선언/클래스
            .anon_function_invoked => "Anonymous function declaration cannot be invoked",
            .function_in_statement => "Function declaration is not allowed in statement position",
            .function_in_statement_strict => "Function declaration is not allowed in statement position in strict mode",
            .generator_in_statement => "Generator declaration is not allowed in statement position",
            .async_function_in_statement => "Async function declaration is not allowed in statement position",
            .class_in_statement => "Class declaration is not allowed in statement position",
            .class_constructor_invalid => "Class constructor cannot be a getter, setter, generator, or async",
            .class_member_hash_constructor => "Class member cannot be named '#constructor'",
            .class_field_constructor => "Class field cannot be named 'constructor'",
            .static_field_prototype => "Static class field cannot be named 'prototype'",
            .static_method_prototype => "Static class method cannot be named 'prototype'",
            .class_after_decorator => "Class expected after decorator",
            .class_or_export_after_decorator => "Class or export expected after decorator",
            .labelled_function_in_loop => "Labelled function declaration is not allowed in loop body",
            .lexical_in_statement => "Lexical declaration is not allowed in statement position",
            // 파서: 바인딩/식별자/파라미터
            .identifier_expected => "Identifier expected",
            .binding_pattern_expected => "Binding pattern expected",
            .escaped_reserved_word => "Escaped reserved word cannot be used as identifier",
            .escaped_reserved_word_strict => "Escaped reserved word cannot be used as identifier in strict mode",
            .reserved_word_identifier => "Reserved word cannot be used as identifier",
            .reserved_word_identifier_strict => "Reserved word in strict mode cannot be used as identifier",
            .keywords_escape => "Keywords cannot contain escape characters",
            .let_in_lexical => "'let' is not allowed as variable name in lexical declaration",
            .const_not_initialized => "Const declarations must be initialized",
            .async_identifier_for_of => "'async' is not allowed as identifier in for-of left-hand side",
            .let_identifier_for_of => "'let' is not allowed as identifier in for-of left-hand side",
            .single_var_for_in_of => "Only a single variable declaration is allowed in a for-in/for-of statement",
            .for_in_of_initializer => "For-in/for-of loop variable declaration may not have an initializer",
            .rest_must_be_last => "Rest element must be last element",
            .rest_trailing_comma => "Rest element may not have a trailing comma",
            .duplicate_parameter => "Duplicate parameter name",
            .private_in_destructuring => "Private name is not allowed in destructuring pattern",
            .invalid_assignment_target => "Invalid assignment target",
            .assignment_eval_arguments_strict => "Assignment to 'eval' or 'arguments' is not allowed in strict mode",
            // 파서: 식/연산자
            .expression_expected => "Expression expected",
            .unary_exponentiation => "Unary expression cannot be the left operand of '**'",
            .nullish_mix_logical => "Cannot mix '??' with '&&' or '||' without parentheses",
            .private_outside_in => "Private name is not valid outside of 'in' expression",
            .private_rhs_in => "Private name is not valid as right-hand side of 'in' expression",
            .private_delete => "Private fields cannot be deleted",
            .private_super_access => "Private field access on super is not allowed",
            .super_outside_method => "'super' is not allowed outside of a method",
            .super_call_outside_constructor => "'super()' is only allowed in a class constructor",
            .tagged_template_optional => "Tagged template cannot be used in optional chain",
            .property_key_expected => "Property key expected",
            .property_colon_expected => "Expected ':' after property key",
            .shorthand_initializer => "Invalid shorthand property initializer",
            .reserved_shorthand => "Reserved word cannot be used as shorthand property",
            .reserved_shorthand_strict => "Reserved word in strict mode cannot be used as shorthand property",
            .yield_shorthand_generator => "'yield' cannot be used as shorthand property in generator",
            .await_shorthand_async => "'await' cannot be used as shorthand property in async/module",
            .private_object_key => "Private identifier is not allowed as object property key",
            .arguments_class_field => "'arguments' is not allowed in class field initializer",
            .arguments_class_static => "'arguments' is not allowed in class static initializer",
            .string_lone_surrogate => "String literal contains lone surrogate",
            .new_target_outside_function => "'new.target' is not allowed outside of functions",
            // 파서: 문/제어 흐름
            .return_outside_function => "'return' outside of function",
            .break_outside => "'break' outside of loop or switch",
            .continue_outside => "'continue' outside of loop",
            .switch_duplicate_default => "Only one default clause is allowed in a switch statement",
            .case_default_expected => "Case or default expected",
            .catch_finally_expected => "Catch or finally expected",
            .throw_newline => "No line break is allowed after 'throw'",
            .escaped_reserved_label => "Escaped reserved word cannot be used as label",
            .escaped_reserved_label_strict => "Escaped reserved word cannot be used as label in strict mode",
            .reserved_label_strict => "Reserved word in strict mode cannot be used as label",
            // 파서: strict mode
            .with_strict => "'with' is not allowed in strict mode",
            .octal_literal_strict => "Octal literals are not allowed in strict mode",
            .octal_escape_strict => "Octal escape sequences are not allowed in strict mode",
            .delete_identifier_strict => "Deleting an identifier is not allowed in strict mode",
            .use_strict_non_simple => "\"use strict\" not allowed in function with non-simple parameters",
            // 파서: await/yield/템플릿/JSX/TS/Flow
            .await_identifier => "'await' cannot be used as identifier in this context",
            .await_in_parameters => "'await' expression is not allowed in formal parameters",
            .await_in_static_initializer => "'await' is not allowed in class static initializer",
            .await_in_non_async_module => "'await' is not allowed in non-async function in module code",
            .await_in_arrow_params => "'await' is not allowed in arrow function parameters",
            .await_in_async_arrow_params => "'await' is not allowed in async arrow function parameters",
            .yield_in_parameters => "'yield' expression is not allowed in formal parameters",
            .yield_in_arrow_params => "'yield' is not allowed in arrow function parameters",
            .template_invalid_escape => "Invalid escape sequence in template literal",
            .template_continuation_expected => "Expected template continuation",
            .jsx_tag_expected => "JSX tag name expected",
            .jsx_spread_expected => "Spread expected",
            .ts_type_expected => "Type expected",
            .ts_mapped_type_in => "Expected 'in' in mapped type",
            .flow_opaque_type => "Expected 'type' after 'opaque'",
            .ts_index_sig_modifier => "Modifiers cannot appear on index signature parameters",
            .ts_index_sig_optional => "An index signature parameter cannot have a question mark",
            // 시맨틱: 재선언
            .identifier_redeclared => "Identifier has already been declared",
            .binding_strict_mode => "Cannot be used as a binding identifier in strict mode",
            // 시맨틱: private member
            .private_redeclared => "Private field has already been declared",
            .private_undeclared => "Private field must be declared in an enclosing class",
            // 시맨틱: export/label
            .duplicate_export => "Duplicate export name",
            .export_not_defined => "Export is not defined",
            .label_redeclared => "Label has already been declared",
            .continue_non_loop_label => "Cannot continue to non-loop label",
            .undefined_label => "Undefined label",
            // 시맨틱: class/getter/setter/object
            .duplicate_constructor => "A class may only have one constructor",
            .proto_duplicate => "Property name __proto__ appears more than once in object literal",
            .getter_no_params => "Getter must not have any formal parameters",
            .setter_one_param => "Setter must have exactly one formal parameter",
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
    try std.testing.expectEqualStrings("ZTS0300", Code.import_in_script.format());
}

test "Code.format: ZTS1000" {
    try std.testing.expectEqualStrings("ZTS1000", Code.identifier_redeclared.format());
}

test "Code.message: returns non-empty for all codes" {
    const fields = @typeInfo(Code).@"enum".fields;
    inline for (fields) |f| {
        const code: Code = @enumFromInt(f.value);
        try std.testing.expect(code.message().len > 0);
    }
}
