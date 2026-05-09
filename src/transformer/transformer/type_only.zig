//! Type-only syntax classification for Transformer.

const Tag = @import("../../parser/ast.zig").Node.Tag;

/// TS/Flow 타입 전용 노드인지 판별한다.
///
/// tag의 정수 값 범위로 판별하지 않고 명시적으로 나열한다.
/// 이유: enum 값 순서가 바뀌어도 안전하게 동작하도록.
pub fn isTypeOnlyNode(tag: Tag) bool {
    return switch (tag) {
        // TS 타입 키워드 (14개)
        .ts_any_keyword,
        .ts_string_keyword,
        .ts_boolean_keyword,
        .ts_number_keyword,
        .ts_never_keyword,
        .ts_unknown_keyword,
        .ts_null_keyword,
        .ts_undefined_keyword,
        .ts_void_keyword,
        .ts_symbol_keyword,
        .ts_object_keyword,
        .ts_bigint_keyword,
        .ts_this_type,
        .ts_intrinsic_keyword,
        // TS 타입 구문 (23개)
        .ts_type_reference,
        .ts_qualified_name,
        .ts_array_type,
        .ts_tuple_type,
        .ts_named_tuple_member,
        .ts_union_type,
        .ts_intersection_type,
        .ts_conditional_type,
        .ts_type_operator,
        .ts_optional_type,
        .ts_rest_type,
        .ts_indexed_access_type,
        .ts_type_literal,
        .ts_function_type,
        .ts_constructor_type,
        .ts_mapped_type,
        .ts_template_literal_type,
        .ts_infer_type,
        .ts_parenthesized_type,
        .ts_import_type,
        .ts_type_query,
        .ts_literal_type,
        .ts_type_predicate,
        // TS/Flow 선언 (통째로 삭제) - isTypeOnlyDeclaration() 대상 포함
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        .ts_interface_body,
        .ts_property_signature,
        .ts_method_signature,
        .ts_call_signature,
        .ts_construct_signature,
        .ts_index_signature,
        .ts_getter_signature,
        .ts_setter_signature,
        // TS 타입 파라미터/this/implements
        .ts_type_parameter,
        .ts_type_parameter_declaration,
        .ts_type_parameter_instantiation,
        .ts_this_parameter,
        .ts_class_implements,
        // namespace는 런타임 코드 생성 -> visitNode에서 별도 처리
        // ts_namespace_export_declaration은 타입 전용 (export as namespace X)
        .ts_namespace_export_declaration,
        // TS import/export 특수 형태
        // ts_import_equals_declaration / ts_export_assignment 는 런타임 코드 생성
        // - visitNode 에서 별도 처리.
        .ts_external_module_reference,
        // enum은 타입 전용이 아님 - 런타임 코드 생성이 필요
        // visitNode의 switch에서 별도 처리
        // Flow 타입 (flow.zig에서 생성)
        .flow_any_keyword,
        .flow_string_keyword,
        .flow_boolean_keyword,
        .flow_number_keyword,
        .flow_never_keyword,
        .flow_null_keyword,
        .flow_void_keyword,
        .flow_symbol_keyword,
        .flow_bigint_keyword,
        .flow_this_type,
        .flow_mixed_keyword,
        .flow_empty_keyword,
        .flow_type_reference,
        .flow_qualified_name,
        .flow_array_type,
        .flow_tuple_type,
        .flow_union_type,
        .flow_intersection_type,
        .flow_function_type,
        .flow_parenthesized_type,
        .flow_literal_type,
        .flow_type_query,
        .flow_nullable_type,
        .flow_type_parameter,
        .flow_type_parameter_declaration,
        .flow_type_parameter_instantiation,
        .flow_this_parameter,
        .flow_type_alias_declaration,
        .flow_opaque_type,
        .flow_interface_declaration,
        .flow_object_type,
        .flow_exact_object_type,
        .flow_property_signature,
        .flow_object_spread_property,
        => true,
        else => false,
    };
}
