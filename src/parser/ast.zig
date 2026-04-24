//! ZTS AST Node Definitions
//!
//! ECMAScript / TypeScript / JSX AST 노드를 정의한다.
//! oxc/SWC를 참고하여 ~200개 세분화 노드 (D037).
//!
//! 설계 원칙:
//! - 고정 24바이트 노드 (Bun 참고, D037)
//! - 인덱스 기반 참조 (포인터 대신, D004)
//! - 카테고리별 파일 분리 (js, ts, jsx, literal)
//!
//! 참고:
//! - references/oxc/crates/oxc_ast/src/ast/
//! - references/swc/crates/swc_ecma_ast/src/

const std = @import("std");
const Span = @import("../lexer/token.zig").Span;

// ============================================================
// 인덱스 타입 — 포인터 대신 u32 인덱스로 노드를 참조 (D004)
// ============================================================

/// AST 노드 인덱스. 노드 배열의 위치를 가리킨다.
pub const NodeIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: NodeIndex) bool {
        return self == .none;
    }
};

/// 노드 인덱스 리스트 (가변 길이 자식을 표현).
/// extra_data 배열에서 시작 위치와 길이로 참조.
/// extern struct: Data extern union의 필드로 사용하기 위해 C ABI 호환.
pub const NodeList = extern struct {
    start: u32,
    len: u32,
};

/// 문자열 참조. 소스 코드의 byte offset 범위를 가리킨다.
/// 별도 문자열 테이블 없이 소스를 직접 참조 (zero-copy).
pub const StringRef = Span;

// ============================================================
// 최상위 노드 — 24바이트 고정 크기 (D037)
// ============================================================

/// AST 노드. 모든 노드가 이 구조체로 표현된다.
/// 24바이트 고정 크기 — 캐시 라인(64B)에 2.6개 들어감.
///
/// 작은 데이터는 `data` union에 인라인,
/// 큰 데이터는 extra_data 배열의 인덱스로 참조.
pub const Node = struct {
    /// 노드 종류 (2바이트)
    tag: Tag,

    /// 소스 위치 (8바이트)
    span: Span,

    /// 노드별 데이터 (union, Tag에 의해 어떤 variant인지 결정)
    /// 작은 데이터는 인라인, 큰 데이터는 extra_data 인덱스
    data: Data,

    comptime {
        // 24바이트 고정 크기 검증
        std.debug.assert(@sizeOf(Node) == 24);
    }

    /// 노드 종류. ~200개. u16으로 표현 (256 초과 가능).
    pub const Tag = enum(u16) {
        // ==============================================================
        // Special
        // ==============================================================
        invalid = 0,
        /// 배열 패턴/리터럴의 빈 슬롯 ([, , x] 의 빈 부분)
        elision,

        // ==============================================================
        // Program
        // ==============================================================
        program,

        // ==============================================================
        // Literals (7개)
        // ==============================================================
        boolean_literal,
        null_literal,
        numeric_literal,
        string_literal,
        bigint_literal,
        regexp_literal,
        template_literal,

        // ==============================================================
        // Expressions
        // ==============================================================
        this_expression,
        identifier_reference,
        private_identifier,
        array_expression,
        object_expression,
        function_expression,
        arrow_function_expression,
        class_expression,
        // 단항
        unary_expression,
        update_expression,
        await_expression,
        yield_expression,
        // 이항
        binary_expression,
        logical_expression,
        // 멤버 접근
        computed_member_expression,
        static_member_expression,
        private_field_expression,
        // 호출
        call_expression,
        new_expression,
        import_expression,
        // 기타 표현식
        conditional_expression,
        assignment_expression,
        sequence_expression,
        spread_element,
        parenthesized_expression,
        chain_expression,
        tagged_template_expression,
        meta_property,
        super_expression,
        template_element,

        // ==============================================================
        // Statements
        // ==============================================================
        block_statement,
        empty_statement,
        expression_statement,
        if_statement,
        switch_statement,
        switch_case,
        while_statement,
        do_while_statement,
        for_statement,
        for_in_statement,
        for_of_statement,
        /// for await (x of iter) {} — for_of_statement와 동일한 데이터 레이아웃
        for_await_of_statement,
        break_statement,
        continue_statement,
        return_statement,
        throw_statement,
        try_statement,
        catch_clause,
        with_statement,
        labeled_statement,
        debugger_statement,
        directive,
        hashbang,

        // ==============================================================
        // Declarations
        // ==============================================================
        variable_declaration,
        variable_declarator,
        function_declaration,
        class_declaration,
        import_declaration,
        import_specifier,
        import_default_specifier,
        import_namespace_specifier,
        import_attribute,
        export_named_declaration,
        export_default_declaration,
        export_all_declaration,
        export_specifier,

        // ==============================================================
        // Functions / Classes
        // ==============================================================
        function,
        formal_parameters,
        formal_parameter,
        rest_element,
        function_body,
        class_body,
        method_definition,
        property_definition,
        static_block,
        accessor_property,
        decorator,

        // ==============================================================
        // Patterns
        // ==============================================================
        binding_identifier,
        array_pattern,
        object_pattern,
        assignment_pattern,
        binding_property,
        binding_rest_element,
        array_assignment_target,
        object_assignment_target,
        assignment_target_with_default,
        /// destructuring LHS에서 identifier_reference를 대체.
        /// 예: `[x] = arr` → x가 assignment_target_identifier로 변환.
        /// data: string_ref (identifier의 소스 위치)
        assignment_target_identifier,
        /// destructuring LHS에서 shorthand property를 대체.
        /// 예: `{x} = obj` → x가 assignment_target_property_identifier로 변환.
        /// data: binary (left=key, right=value, shorthand)
        assignment_target_property_identifier,
        /// destructuring LHS에서 long-form property를 대체.
        /// 예: `{x: y} = obj` → assignment_target_property_property로 변환.
        /// data: binary (left=key, right=value)
        assignment_target_property_property,
        /// destructuring LHS에서 spread_element을 대체.
        /// 예: `[...x] = arr` → ...x가 assignment_target_rest로 변환.
        /// data: unary (operand = target)
        assignment_target_rest,

        // ==============================================================
        // Object Properties
        // ==============================================================
        object_property,
        computed_property_key,

        // ==============================================================
        // JSX
        // ==============================================================
        jsx_element,
        jsx_opening_element,
        jsx_closing_element,
        jsx_fragment,
        jsx_opening_fragment,
        jsx_closing_fragment,
        jsx_attribute,
        jsx_spread_attribute,
        jsx_expression_container,
        jsx_empty_expression,
        jsx_text,
        jsx_namespaced_name,
        jsx_member_expression,
        jsx_identifier,
        jsx_spread_child,

        // ==============================================================
        // TypeScript Types
        // ==============================================================
        ts_any_keyword,
        ts_string_keyword,
        ts_boolean_keyword,
        ts_number_keyword,
        ts_never_keyword,
        ts_unknown_keyword,
        ts_null_keyword,
        ts_undefined_keyword,
        ts_void_keyword,
        ts_symbol_keyword,
        ts_object_keyword,
        ts_bigint_keyword,
        ts_this_type,
        ts_intrinsic_keyword,
        ts_type_reference,
        ts_qualified_name,
        ts_array_type,
        ts_tuple_type,
        ts_named_tuple_member,
        ts_union_type,
        ts_intersection_type,
        ts_conditional_type,
        ts_type_operator,
        ts_optional_type,
        ts_rest_type,
        ts_indexed_access_type,
        ts_type_literal,
        ts_function_type,
        ts_constructor_type,
        ts_mapped_type,
        ts_template_literal_type,
        ts_infer_type,
        ts_parenthesized_type,
        ts_import_type,
        ts_type_query,
        ts_literal_type,
        ts_type_predicate,

        // ==============================================================
        // TypeScript Declarations
        // ==============================================================
        ts_type_alias_declaration,
        ts_interface_declaration,
        ts_interface_body,
        ts_property_signature,
        ts_method_signature,
        ts_call_signature,
        ts_construct_signature,
        ts_index_signature,
        ts_getter_signature,
        ts_setter_signature,
        ts_enum_declaration,
        ts_enum_body,
        ts_enum_member,
        ts_module_declaration,
        ts_module_block,
        ts_import_equals_declaration,
        ts_external_module_reference,
        ts_export_assignment,
        ts_namespace_export_declaration,
        ts_type_parameter,
        ts_type_parameter_declaration,
        ts_type_parameter_instantiation,
        ts_this_parameter,
        ts_class_implements,

        // ==============================================================
        // Flow Types
        // ==============================================================
        flow_any_keyword,
        flow_string_keyword,
        flow_boolean_keyword,
        flow_number_keyword,
        flow_never_keyword,
        flow_null_keyword,
        flow_void_keyword,
        flow_symbol_keyword,
        flow_bigint_keyword,
        flow_this_type,
        /// mixed — Flow의 unknown에 해당하는 top type
        flow_mixed_keyword,
        /// empty — Flow의 never에 해당하는 bottom type
        flow_empty_keyword,
        flow_type_reference,
        flow_qualified_name,
        flow_array_type,
        flow_tuple_type,
        flow_union_type,
        flow_intersection_type,
        flow_function_type,
        flow_parenthesized_type,
        flow_literal_type,
        flow_type_query,
        /// ?Type — Flow nullable type (TS에 없는 전용 구문)
        flow_nullable_type,
        flow_type_parameter,
        flow_type_parameter_declaration,
        flow_type_parameter_instantiation,
        flow_this_parameter,
        /// type Foo = Type — Flow type alias
        flow_type_alias_declaration,
        /// opaque type Foo = Type — Flow opaque type (supertype constraint 포함 가능)
        flow_opaque_type,
        /// interface Foo extends Bar { ... } — Flow interface declaration
        flow_interface_declaration,
        /// expr as Type — Flow type cast expression
        flow_as_expression,
        /// (expr: Type) — Flow TypeCast expression
        flow_type_cast_expression,
        /// {| key: Type |} — Flow exact object type
        flow_exact_object_type,
        /// match (expr) { ... } — Flow match expression
        flow_match_expression,
        /// match expression 의 개별 arm: `pattern => body`. binary = { left=pattern,
        /// right=body }. `visitFlowMatch` 가 arms list 를 iterate 하며 각 arm 의
        /// binary.left/right 를 읽는다. `#1822` 에서 outer expr 와 tag 분리.
        flow_match_arm,
        /// Flow component with ref → React.forwardRef wrapper
        /// extra = [func_decl, const_decl]
        /// func_decl: function Name_withRef({...props}, ref) { body }
        /// const_decl: const Name = React.forwardRef(Name_withRef)
        flow_component_wrapper,

        // ==============================================================
        // TypeScript Expressions
        // ==============================================================
        ts_as_expression,
        ts_satisfies_expression,
        ts_non_null_expression,
        ts_type_assertion,
        ts_instantiation_expression,

        // ==============================================================
        // 합계: 개수는 컴파일 타임에 Tag 필드 수로 자동 검증
        // ==============================================================

        /// type-only 선언 태그 판별.
        /// export 문에서 이 태그의 decl은 런타임 코드를 생성하지 않으므로
        /// export_named_declaration으로 래핑하지 않아야 함.
        pub fn isTypeOnlyDeclaration(tag: Tag) bool {
            return switch (tag) {
                .ts_type_alias_declaration,
                .ts_interface_declaration,
                .flow_type_alias_declaration,
                .flow_opaque_type,
                .flow_interface_declaration,
                => true,
                else => false,
            };
        }

        /// 노드 데이터의 종류. AST 워커가 자식 노드를 일관되게 탐색하기 위해 사용.
        pub const DataKind = enum {
            /// 리프 노드: 자식 없음 (none, string_ref, number_bytes)
            leaf,
            /// unary: operand 1개 (data.unary.operand)
            unary,
            /// binary: left + right (data.binary.left, data.binary.right)
            binary,
            /// ternary: a + b + c (data.ternary.a, data.ternary.b, data.ternary.c)
            ternary,
            /// list: 가변 자식 목록 (data.list.start, data.list.len)
            list,
            /// extra: extra_data 기반 가변 레이아웃 (태그별 구조 다름)
            extra,
        };

        /// 노드 레이아웃 정의 (Single Source of Truth).
        /// 모든 Tag는 반드시 여기에 등록되어야 한다.
        /// extra 노드의 child_offsets는 NodeIndex인 필드의 오프셋만 포함.
        const Layout = struct {
            kind: DataKind,
            /// extra 노드의 NodeIndex 필드 오프셋. leaf/unary/binary/ternary/list는 비어 있음.
            child_offsets: []const u8 = &.{},
            /// extra 노드의 간접 NodeIndex 리스트 필드. {start_offset, len_offset} 쌍.
            /// extra_data[e + start_offset .. + start_offset + extra_data[e + len_offset]]가 NodeIndex 리스트.
            list_offsets: []const [2]u8 = &.{},
        };

        // ────────────────────────────────────────────────────
        // 노드 레이아웃 테이블 — 태그 추가 시 반드시 여기에 등록.
        // comptime 검증으로 누락 시 컴파일 에러.
        // ────────────────────────────────────────────────────
        fn getLayout(tag: Tag) Layout {
            return switch (tag) {
                // === leaf ===
                .invalid,
                .elision,
                .boolean_literal,
                .null_literal,
                .numeric_literal,
                .bigint_literal,
                .string_literal,
                .regexp_literal,
                .this_expression,
                .identifier_reference,
                .private_identifier,
                .empty_statement,
                .debugger_statement,
                .directive,
                .hashbang,
                .super_expression,
                .meta_property,
                .template_element,
                .binding_identifier,
                .assignment_target_identifier,
                .import_default_specifier,
                .import_namespace_specifier,
                .jsx_empty_expression,
                .jsx_text,
                .jsx_identifier,
                .jsx_closing_element,
                .jsx_opening_fragment,
                .jsx_closing_fragment,
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
                // literal type: 파서가 키워드 리터럴(true/false)일 때 .none,
                // 값 리터럴(string/number/bigint/template)일 때 .string_ref 로 저장.
                // 실체가 leaf 이며 codegen 이 data 를 읽지 않음 (TS/Flow strip 대상).
                .ts_literal_type,
                .flow_literal_type,
                => .{ .kind = .leaf },

                // === unary ===
                .expression_statement,
                .return_statement,
                .throw_statement,
                .spread_element,
                .parenthesized_expression,
                .await_expression,
                .yield_expression,
                .rest_element,
                .decorator,
                .chain_expression,
                .computed_property_key,
                .break_statement,
                .continue_statement,
                .static_block,
                // unary_expression, update_expression → extra 섹션에서 처리
                .assignment_target_rest,
                .binding_rest_element,
                .jsx_spread_attribute,
                .jsx_expression_container,
                .jsx_spread_child,
                .ts_optional_type,
                .ts_rest_type,
                .ts_type_operator,
                .ts_non_null_expression,
                .flow_nullable_type,
                // TS/Flow type-cast / assertion expressions — codegen emitter 가
                // data.unary.operand 만 출력 (type 부분 스트리핑).
                // codegen.zig::emitExpression 의 .ts_as_expression 등 arm 참고.
                .ts_as_expression,
                .ts_satisfies_expression,
                .ts_type_assertion,
                .ts_instantiation_expression,
                .flow_as_expression,
                .flow_type_cast_expression,
                => .{ .kind = .unary },

                // === binary ===
                .binary_expression,
                .logical_expression,
                .assignment_expression,
                // switch_case → extra (아래에서 처리)
                .catch_clause,
                .labeled_statement,
                .while_statement,
                .do_while_statement,
                .with_statement,
                // static_member_expression, private_field_expression → extra (아래에서 처리)
                .assignment_target_property_identifier,
                .assignment_target_property_property,
                .binding_property,
                .assignment_pattern,
                .assignment_target_with_default,
                .import_specifier,
                .export_specifier,
                .jsx_attribute,
                .jsx_namespaced_name,
                .jsx_member_expression,
                .ts_qualified_name,
                .ts_type_predicate,
                .ts_enum_member,
                .flow_qualified_name,
                // ts_module_declaration: binary = { left=name, right=body_or_inner, flags }
                // codegen::emitNamespaceIIFEInner 가 data.binary.left/right 를 읽는다.
                .ts_module_declaration,
                // ts_import_equals_declaration: binary = { left=name, right=value, flags }
                // transformer::visitImportEqualsDeclaration 가 data.binary.left/right
                // 를 읽어 `const X = require(...)` 런타임 코드로 변환한다.
                .ts_import_equals_declaration,
                // import_attribute: binary = { left=key, right=value, flags }
                // ESM `import ... with { type: "json" }` 의 각 attr. key/value 가
                // 실존하므로 leaf 가 아닌 binary layout.
                .import_attribute,
                // import_expression: binary = { left=arg, right=options, flags }
                // `import(x)` 는 right=none. `import(x, { with: {...} })` 는 options 를
                // 일반 ObjectExpression 으로 보존. codegen 이 right 유무로 ", opts" 출력 결정.
                .import_expression,
                // flow_match_arm: binary = { left=pattern, right=body, flags }
                // outer flow_match_expression (extra layout) 의 arms list 구성원.
                .flow_match_arm,
                => .{ .kind = .binary },

                // === ternary ===
                .conditional_expression,
                .for_in_statement,
                .for_of_statement,
                .for_await_of_statement,
                .if_statement,
                .try_statement,
                => .{ .kind = .ternary },

                // === list ===
                .program,
                .block_statement,
                .sequence_expression,
                .class_body,
                .formal_parameters,
                .function_body,
                .template_literal,
                .array_expression,
                .object_expression,
                .array_pattern,
                .object_pattern,
                .array_assignment_target,
                .object_assignment_target,
                .ts_union_type,
                .ts_intersection_type,
                .ts_tuple_type,
                .ts_type_literal,
                .ts_interface_body,
                .ts_enum_body,
                .ts_module_block,
                .ts_type_parameter_declaration,
                .ts_type_parameter_instantiation,
                .flow_union_type,
                .flow_intersection_type,
                .flow_tuple_type,
                .flow_exact_object_type,
                .flow_type_parameter_declaration,
                .flow_type_parameter_instantiation,
                => .{ .kind = .list },

                // === extra: 태그별 NodeIndex 오프셋 명시 ===
                // 호출: extra = [callee(0), args_start(1), args_len(2), flags]
                .call_expression, .new_expression => .{ .kind = .extra, .child_offsets = &.{0}, .list_offsets = &.{.{ 1, 2 }} },
                // tagged template: extra = [tag(0), template(1), flags]
                .tagged_template_expression => .{ .kind = .extra, .child_offsets = &.{ 0, 1 } },
                // member: extra = [object(0), property(1), flags]
                .static_member_expression,
                .private_field_expression,
                .computed_member_expression,
                => .{ .kind = .extra, .child_offsets = &.{ 0, 1 } },
                // function: extra = [name(0), params(1), body(2), flags(3), ret_type(4)]
                .function_expression, .function_declaration, .function => .{ .kind = .extra, .child_offsets = &.{ 0, 1, 2 } },
                // arrow: extra = [params(0), body(1), flags]
                .arrow_function_expression => .{ .kind = .extra, .child_offsets = &.{ 0, 1 } },
                // class: extra = [name(0), super(1), body(2), type_params(3), impl_start, impl_len, deco_start, deco_len]
                .class_expression, .class_declaration => .{ .kind = .extra, .child_offsets = &.{ 0, 1, 2 } },
                // method: extra = [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
                .method_definition => .{ .kind = .extra, .child_offsets = &.{ 0, 1, 2 } },
                // property_definition: extra = [key(0), init(1), flags, deco_start, deco_len]
                .property_definition, .accessor_property => .{ .kind = .extra, .child_offsets = &.{ 0, 1 } },
                // for_statement: extra = [init(0), test(1), update(2), body(3)]
                .for_statement => .{ .kind = .extra, .child_offsets = &.{ 0, 1, 2, 3 } },
                // switch_statement: extra = [discriminant(0), cases_start(1), cases_len(2)]
                .switch_statement => .{ .kind = .extra, .child_offsets = &.{0}, .list_offsets = &.{.{ 1, 2 }} },
                // switch_case: extra = [test(0), stmts_start(1), stmts_len(2)]
                .switch_case => .{ .kind = .extra, .child_offsets = &.{0}, .list_offsets = &.{.{ 1, 2 }} },
                // variable_declaration: extra = [kind_flags, list_start(1), list_len(2)]
                .variable_declaration => .{ .kind = .extra, .child_offsets = &.{}, .list_offsets = &.{.{ 1, 2 }} },
                // variable_declarator: extra = [name(0), type_ann(1), init(2)]
                .variable_declarator => .{ .kind = .extra, .child_offsets = &.{ 0, 2 } },
                // formal_parameter: extra = [pattern(0), type_ann(1), default(2), flags, deco_start, deco_len]
                .formal_parameter => .{ .kind = .extra, .child_offsets = &.{ 0, 2 } },
                // unary/update_expression: 파서에서 data.extra로 생성 — extra = [operand(0), flags]
                .unary_expression, .update_expression => .{ .kind = .extra, .child_offsets = &.{0} },
                // object_property: binary = { left: key, right: value, flags: prop_flags }
                .object_property => .{ .kind = .binary },
                // import_declaration: extra = [specs_start, specs_len, source(2)]
                // import_declaration: extra = [specs_start, specs_len, source(2), phase_flags, attrs_start, attrs_len]
                // phase_flags: u32. low 4 bits = ImportPhase (0=none, 1=defer, 2=source)
                .import_declaration => .{ .kind = .extra, .child_offsets = &.{2} },
                // export_named: extra = [decl(0), specs_start, specs_len, source(3), attrs_start(4), attrs_len(5)]
                .export_named_declaration => .{ .kind = .extra, .child_offsets = &.{ 0, 3 } },
                // export_all: extra = [exported_name(0), source(1), attrs_start(2), attrs_len(3)]
                // `export *` 은 exported_name = .none, `export * as ns` 는 namespace identifier.
                .export_all_declaration => .{ .kind = .extra, .child_offsets = &.{ 0, 1 } },
                // export_default: unary = { operand: decl, flags: 0 }
                .export_default_declaration => .{ .kind = .unary },
                // jsx_element: extra = [tag(0), attrs_start, attrs_len, children_start, children_len]
                .jsx_element => .{ .kind = .extra, .child_offsets = &.{0} },
                // jsx_opening_element: extra = [tag(0), attrs_start, attrs_len]
                .jsx_opening_element => .{ .kind = .extra, .child_offsets = &.{0} },
                // jsx_fragment: list = children (파서에서 .list로 저장)
                .jsx_fragment => .{ .kind = .list },
                // flow_component_wrapper: extra = [func_decl(0), const_decl(1)]
                .flow_component_wrapper => .{ .kind = .extra, .child_offsets = &.{ 0, 1 } },
                // TS declarations — 대부분 타입 전용이므로 런타임 워커에서 무시 가능
                .ts_type_reference,
                .ts_array_type,
                .ts_named_tuple_member,
                .ts_conditional_type,
                .ts_indexed_access_type,
                .ts_function_type,
                .ts_constructor_type,
                .ts_mapped_type,
                .ts_template_literal_type,
                .ts_infer_type,
                .ts_parenthesized_type,
                .ts_import_type,
                .ts_type_query,
                .ts_type_alias_declaration,
                .ts_interface_declaration,
                .ts_property_signature,
                .ts_method_signature,
                .ts_call_signature,
                .ts_construct_signature,
                .ts_index_signature,
                .ts_getter_signature,
                .ts_setter_signature,
                .ts_enum_declaration,
                .ts_external_module_reference,
                .ts_export_assignment,
                .ts_namespace_export_declaration,
                .ts_type_parameter,
                .ts_this_parameter,
                .ts_class_implements,
                => .{ .kind = .extra, .child_offsets = &.{} },
                // Flow declarations — 타입 전용
                .flow_type_reference,
                .flow_array_type,
                .flow_function_type,
                .flow_parenthesized_type,
                .flow_type_query,
                .flow_type_parameter,
                .flow_this_parameter,
                .flow_type_alias_declaration,
                .flow_opaque_type,
                .flow_interface_declaration,
                .flow_match_expression,
                => .{ .kind = .extra, .child_offsets = &.{} },
            };
        }

        // ────────────────────────────────────────────────────
        // comptime 전수 검증: 모든 Tag가 getLayout에 등록되어 있는지 확인.
        // 태그를 추가하고 getLayout에 등록하지 않으면 컴파일 에러.
        // ────────────────────────────────────────────────────
        comptime {
            for (std.enums.values(Tag)) |t| {
                _ = getLayout(t);
            }
        }

        /// 태그의 데이터 레이아웃 종류를 반환한다.
        pub fn dataKind(tag: Tag) DataKind {
            return getLayout(tag).kind;
        }

        /// extra 노드의 NodeIndex 자식 필드 오프셋을 반환한다.
        /// extra가 아닌 노드는 빈 배열 반환.
        pub fn extraChildOffsets(tag: Tag) []const u8 {
            return getLayout(tag).child_offsets;
        }

        /// extra 노드의 간접 NodeIndex 리스트 필드 오프셋을 반환한다.
        /// 각 항목은 {start_offset, len_offset} 쌍.
        /// extra_data[e + start]부터 len개의 NodeIndex가 자식 리스트.
        pub fn extraListOffsets(tag: Tag) []const [2]u8 {
            return getLayout(tag).list_offsets;
        }
    };

    /// 노드별 인라인 데이터 (12바이트).
    /// 작은 데이터는 여기에 직접 저장, 큰 데이터는 extra 인덱스로 참조.
    ///
    /// f64를 [8]u8로 저장하는 이유:
    ///   f64의 정렬이 8바이트 → union 전체 정렬이 8 → 패딩으로 16바이트가 됨.
    ///   [8]u8은 정렬 1이므로 union 크기가 12바이트(ternary)로 유지된다.
    ///   Node = tag(2) + pad(2) + span(8) + data(12) = 24바이트.
    ///   읽기/쓰기는 @bitCast로 변환 (컴파일타임, 런타임 비용 0).
    /// extern union으로 safety 태그 없이 정확한 크기 보장.
    ///
    /// 왜 extern인가?
    ///   Zig bare union은 Debug 빌드에서 active 필드 추적 태그(4바이트)를
    ///   추가하여 Node가 24바이트를 초과한다.
    ///   extern union은 C ABI 레이아웃을 따르므로 태그 없이 가장 큰 필드의
    ///   크기(12바이트, ternary)가 곧 union 크기가 된다.
    ///
    /// f64를 [8]u8로 저장하는 이유:
    ///   f64의 정렬이 8바이트 → union 정렬이 8 → 패딩으로 16바이트가 됨.
    ///   [8]u8은 정렬 1이므로 union 크기가 12바이트로 유지된다.
    ///   읽기/쓰기는 @bitCast로 변환 (컴파일타임, 런타임 비용 0).
    pub const Data = extern union {
        /// 단순 노드 (자식 없음)
        none: u32,

        /// 단항 (자식 1개)
        unary: extern struct {
            operand: NodeIndex,
            flags: u16,
            _pad: u16 = 0,
        },

        /// 이항 (자식 2개)
        binary: extern struct {
            left: NodeIndex,
            right: NodeIndex,
            flags: u16,
            _pad: u16 = 0,
        },

        /// 삼항 (자식 3개)
        ternary: extern struct {
            a: NodeIndex,
            b: NodeIndex,
            c: NodeIndex,
        },

        /// 리스트 참조 (가변 길이 자식)
        list: NodeList,

        /// 문자열 참조 (식별자, 리터럴 값 등)
        string_ref: StringRef,

        /// 숫자 리터럴 값 (f64를 [8]u8로 저장, 정렬 패딩 방지)
        /// 쓰기: .{ .number_bytes = @bitCast(my_f64) }
        /// 읽기: const val: f64 = @bitCast(node.data.number_bytes);
        number_bytes: [8]u8,

        /// extra_data 배열 인덱스 (큰 데이터용)
        extra: u32,
    };
};

// ============================================================
// AST 저장소
// ============================================================

/// AST 전체를 저장하는 구조체.
/// 모든 노드는 nodes 배열에, 가변 길이 데이터는 extra_data에 저장.
pub const Ast = struct {
    /// 노드 배열 (24바이트 × N)
    nodes: std.ArrayList(Node),

    /// 추가 데이터 (NodeIndex 배열, 가변 길이 리스트 등)
    extra_data: std.ArrayList(u32),

    /// 소스 코드 참조 (zero-copy)
    source: []const u8,

    /// 합성 문자열 저장소.
    /// 트랜스포머가 소스에 없는 텍스트를 생성할 때 사용 (예: enum IIFE의 숫자 리터럴).
    /// Span의 bit 31이 1이면 source 대신 string_table에서 읽는다.
    /// getText(span)으로 투명하게 접근.
    string_table: std.ArrayList(u8),

    /// 파싱 중 JSX element/fragment가 발견되었는지 (automatic JSX import 주입용)
    has_jsx: bool = false,

    /// `<Tag {...props} key={k} />` 가 있는가. jsx_lowering 이 이 패턴에 대해
    /// `_createElement` fallback 을 emit 하므로 bundler 가 `react` synthetic import
    /// 주입 여부를 이 플래그로 결정.
    has_jsx_key_after_spread: bool = false,

    /// D1 (RFC #1672) 디버그 인프라. Transformer.init 시점의 `nodes.items.len` snapshot.
    /// null = 미변환. boundary 이상의 노드는 transformer 가 append 한 것.
    /// D1a 부터 clone 경로 (Transformer.init → cloneForTransformer) 에서 활성.
    /// D1b 이후 in-place mutation 경로에서도 동일 의미 유지. debug_log 의
    /// `ast_mutation` 카테고리 + `assertInvariants` 에서 활용.
    transform_boundary: ?u32 = null,

    /// D1 디버그 인프라. transform() 완료 시 root NodeIndex snapshot.
    /// D1a 부터 clone AST 에 기록 — 같은 Transformer 인스턴스의 이중 transform 을
    /// `assertInvariants` 가 탐지. D1b (in-place) 전환 시 shared module 재진입
    /// 탐지/차단 용도로 확장 예정.
    transformed_root: ?NodeIndex = null,

    /// 메모리 할당자 (Zig 0.15: ArrayList가 더 이상 allocator를 저장하지 않음)
    allocator: std.mem.Allocator,

    /// string_table 마커. Span.start의 bit 31이 1이면 string_table 참조.
    pub const STRING_TABLE_BIT: u32 = 0x80000000;

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Ast {
        return .{
            .nodes = .empty,
            .extra_data = .empty,
            .string_table = .empty,
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.allocator);
        self.extra_data.deinit(self.allocator);
        self.string_table.deinit(self.allocator);
    }

    /// 트랜스포머용 AST 복제본을 생성한다.
    /// 파서의 nodes/extra_data/string_table을 새 allocator로 복사한다.
    /// 이후 addNode/addString 등은 새 allocator로 append된다.
    ///
    /// 원본 AST는 변경되지 않으므로 HMR 재처리 등에 안전하다.
    pub fn cloneForTransformer(source_ast: *const Ast, allocator: std.mem.Allocator) !Ast {
        var cloned: Ast = .{
            .nodes = .empty,
            .extra_data = .empty,
            .string_table = .empty,
            .source = source_ast.source,
            .has_jsx = source_ast.has_jsx,
            .has_jsx_key_after_spread = source_ast.has_jsx_key_after_spread,
            .allocator = allocator,
        };
        // 세 appendSlice 중 하나라도 실패하면 이미 할당된 ArrayList 버퍼를 정리해야 한다.
        errdefer cloned.deinit();
        try cloned.nodes.appendSlice(allocator, source_ast.nodes.items);
        try cloned.extra_data.appendSlice(allocator, source_ast.extra_data.items);
        try cloned.string_table.appendSlice(allocator, source_ast.string_table.items);
        return cloned;
    }

    /// 노드를 추가하고 인덱스를 반환한다.
    ///
    /// 가능하면 `addBinaryNode` / `addUnaryNode` / `addTernaryNode` / `addExtraNode` /
    /// `addListNode` / `addLeafNode` 같은 variant-typed helper 를 사용할 것. Debug
    /// 빌드에서 tag 의 `dataKind()` 와 전달한 variant 의 매칭을 assertion 으로 검증해
    /// `object_property` 에 `.extra` 를, `unary_expression` 에 `.unary` 를 쓰는 식의
    /// silent failure (#1797) 를 조기 포착. release 에선 zero-cost.
    pub fn addNode(self: *Ast, node: Node) !NodeIndex {
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        const debug_log = @import("../debug_log.zig");
        if (debug_log.enabled(.ast_mutation)) {
            debug_log.print(
                .ast_mutation,
                "addNode idx={d} tag={s} (total={d}, boundary={?})\n",
                .{ index, @tagName(node.tag), self.nodes.items.len, self.transform_boundary },
            );
        }
        return @enumFromInt(index);
    }

    /// `binary` variant 를 쓰는 노드 (object_property, assignment_expression 등) 를
    /// 안전하게 추가. Debug 빌드에서 tag↔variant 매칭 assertion.
    pub fn addBinaryNode(self: *Ast, tag: Node.Tag, span: Span, left: NodeIndex, right: NodeIndex, flags: u16) !NodeIndex {
        assertDataKind(tag, .binary);
        return self.addNode(.{
            .tag = tag,
            .span = span,
            .data = .{ .binary = .{ .left = left, .right = right, .flags = flags } },
        });
    }

    /// `unary` variant 를 쓰는 노드 (return_statement, expression_statement 등).
    pub fn addUnaryNode(self: *Ast, tag: Node.Tag, span: Span, operand: NodeIndex, flags: u16) !NodeIndex {
        assertDataKind(tag, .unary);
        return self.addNode(.{
            .tag = tag,
            .span = span,
            .data = .{ .unary = .{ .operand = operand, .flags = flags } },
        });
    }

    /// `ternary` variant 를 쓰는 노드 (if_statement, conditional_expression 등).
    pub fn addTernaryNode(self: *Ast, tag: Node.Tag, span: Span, a: NodeIndex, b: NodeIndex, c: NodeIndex) !NodeIndex {
        assertDataKind(tag, .ternary);
        return self.addNode(.{
            .tag = tag,
            .span = span,
            .data = .{ .ternary = .{ .a = a, .b = b, .c = c } },
        });
    }

    /// `extra` variant 를 쓰는 노드 (function_declaration, call_expression 등).
    /// `extra_idx` 는 사전에 `addExtras` 로 얻은 인덱스.
    pub fn addExtraNode(self: *Ast, tag: Node.Tag, span: Span, extra_idx: u32) !NodeIndex {
        assertDataKind(tag, .extra);
        return self.addNode(.{
            .tag = tag,
            .span = span,
            .data = .{ .extra = extra_idx },
        });
    }

    /// 자식 없는 `extra` 노드 — TS/Flow strip-target 타입 표기 전용 (#1802 B2).
    /// getLayout 이 `.extra, child_offsets = &.{}` 로 선언되어 있고 codegen/
    /// transformer/semantic 어디도 data 를 읽지 않는 tag 에 사용. parse 부수효과
    /// (advance, parseX) 만 필요한 경우 이 helper 로 node 만 등록.
    /// empty `addExtras` 호출은 zero-alloc (ensureUnusedCapacity(0) no-op).
    pub fn addEmptyExtraNode(self: *Ast, tag: Node.Tag, span: Span) !NodeIndex {
        assertDataKind(tag, .extra);
        const extra_idx = try self.addExtras(&.{});
        return self.addNode(.{
            .tag = tag,
            .span = span,
            .data = .{ .extra = extra_idx },
        });
    }

    /// `list` variant 를 쓰는 노드 (block_statement, array_expression 등).
    pub fn addListNode(self: *Ast, tag: Node.Tag, span: Span, list: NodeList) !NodeIndex {
        assertDataKind(tag, .list);
        return self.addNode(.{
            .tag = tag,
            .span = span,
            .data = .{ .list = list },
        });
    }

    /// `leaf` variant (자식 없음) — `none` / `string_ref` / `number_bytes` 서브 variant
    /// 중 하나. 호출자가 이미 Data union 을 구성해 전달.
    pub fn addLeafNode(self: *Ast, tag: Node.Tag, span: Span, data: Node.Data) !NodeIndex {
        assertDataKind(tag, .leaf);
        return self.addNode(.{ .tag = tag, .span = span, .data = data });
    }

    inline fn assertDataKind(tag: Node.Tag, expected: Node.Tag.DataKind) void {
        if (@import("builtin").mode != .Debug) return;
        const actual = tag.dataKind();
        if (actual != expected) {
            std.debug.panic(
                "addNode: tag '{s}' expects dataKind .{s} but .{s} was passed",
                .{ @tagName(tag), @tagName(actual), @tagName(expected) },
            );
        }
    }

    /// Debug-only invariant 검증 (D1 디버깅 인프라).
    /// `transform_boundary` 가 설정됐다면 boundary 이하의 노드는 parser 가 채운 것,
    /// 이상의 노드는 transformer 가 append 한 것. 이 영역이 명확한지 확인한다.
    /// 프로덕션에서는 no-op — Debug 빌드에서만 실행.
    pub fn assertInvariants(self: *const Ast) void {
        if (@import("builtin").mode != .Debug) return;
        if (self.transform_boundary) |boundary| {
            // boundary 는 nodes.items.len 을 넘지 않아야 — transformer 가 노드를
            // 제거하지 않고 append 만 한다는 설계 규약.
            std.debug.assert(boundary <= self.nodes.items.len);
        }
        // transformed_root 가 있다면 valid index 여야.
        if (self.transformed_root) |root| {
            const idx = @intFromEnum(root);
            if (!root.isNone()) {
                std.debug.assert(idx < self.nodes.items.len);
            }
        }
    }

    /// 인덱스로 노드를 가져온다.
    pub fn getNode(self: *const Ast, index: NodeIndex) Node {
        return self.nodes.items[@intFromEnum(index)];
    }

    /// 노드의 태그를 변경한다 (cover grammar 변환용).
    /// 24바이트 고정 크기이므로 태그만 바꾸면 새 노드 할당 없이 변환 가능.
    pub fn setTag(self: *Ast, index: NodeIndex, new_tag: Node.Tag) void {
        self.nodes.items[@intFromEnum(index)].tag = new_tag;
    }

    /// variable_declaration 노드의 kind를 typed enum으로 반환.
    /// node.tag == .variable_declaration 가정. extra[0]에 저장된 u32를 디코드.
    pub inline fn variableDeclarationKind(self: *const Ast, node: Node) VariableDeclarationKind {
        return VariableDeclarationKind.fromU32(self.extra_data.items[node.data.extra]);
    }

    /// `formal_parameters` 노드를 생성한다. transformer가 function/method를 새로 만들 때
    /// slot 1(arrow는 slot 0)에 넣을 NodeIndex를 반환 — caller는 `@intFromEnum(...)` 으로 extras에 기록.
    pub fn addFormalParameters(self: *Ast, list: NodeList, span: Span) !NodeIndex {
        return self.addNode(.{
            .tag = .formal_parameters,
            .span = span,
            .data = .{ .list = list },
        });
    }

    /// 함수형 노드의 formal_parameters NodeList를 반환한다 (extra_data 인덱스 + len).
    /// 지원 태그: function_declaration / function_expression / function /
    /// arrow_function_expression / method_definition.
    /// formal_parameters 노드가 없거나 잘못된 경우 빈 NodeList 반환.
    /// consumer에서 registerParams/checkDuplicateParams 등 (start, len) 시그니처 호출에 사용.
    pub fn functionParamsList(self: *const Ast, node: Node) NodeList {
        const params_slot: u32 = switch (node.tag) {
            .arrow_function_expression => 0,
            .function_declaration, .function_expression, .function, .method_definition => 1,
            else => return .{ .start = 0, .len = 0 },
        };
        if (node.data.extra + params_slot >= self.extra_data.items.len) return .{ .start = 0, .len = 0 };
        const params_idx: NodeIndex = @enumFromInt(self.extra_data.items[node.data.extra + params_slot]);
        if (params_idx.isNone() or @intFromEnum(params_idx) >= self.nodes.items.len) return .{ .start = 0, .len = 0 };
        const params_node = self.getNode(params_idx);
        if (params_node.tag != .formal_parameters) return .{ .start = 0, .len = 0 };
        return params_node.data.list;
    }

    /// 함수형 노드의 파라미터 슬라이스를 반환한다 (각 element는 NodeIndex의 raw u32).
    /// 지원 태그: function_declaration / function_expression / function /
    /// arrow_function_expression / method_definition.
    /// 모두 `formal_parameters` 노드를 unwrap (arrow는 extra[0], 나머지는 extra[1]).
    /// formal_parameters 노드가 비어 있거나 params가 없으면 빈 슬라이스 반환.
    pub fn functionParams(self: *const Ast, node: Node) []const u32 {
        const params_slot: u32 = switch (node.tag) {
            .arrow_function_expression => 0,
            .function_declaration, .function_expression, .function, .method_definition => 1,
            else => return &[_]u32{},
        };
        const params_idx: NodeIndex = @enumFromInt(self.extra_data.items[node.data.extra + params_slot]);
        if (params_idx.isNone()) return &[_]u32{};
        const params_node = self.getNode(params_idx);
        if (params_node.tag != .formal_parameters) return &[_]u32{};
        const list = params_node.data.list;
        if (list.len == 0) return &[_]u32{};
        return self.extra_data.items[list.start .. list.start + list.len];
    }

    /// binding-pattern 컨테이너의 elements와 rest를 분리해 반환한다.
    /// 모든 walker가 이 helper 한 곳을 거치면 rest 태그 case set이 캡슐화되어
    /// 새 walker 추가 시 누락 위험이 사라진다.
    pub const ContainerRestSplit = struct {
        /// rest의 inner binding. rest가 없거나 컨테이너 노드가 아니면 null.
        rest_operand: ?NodeIndex,
        /// rest를 제외한 일반 element들의 raw 인덱스 슬라이스.
        elements: []const u32,
    };

    /// binding-pattern 컨테이너(array_pattern / object_pattern / formal_parameters /
    /// array_assignment_target / object_assignment_target)의 NodeList에서
    /// 마지막 element가 rest 노드(rest_element / binding_rest_element /
    /// assignment_target_rest)인지 검사하고 분리해 반환한다.
    /// 호출자는 보통 switch arm 안에서 컨테이너 태그를 이미 확인했으므로 NodeList만 넘긴다.
    pub inline fn nodeListSplitRest(self: *const Ast, list: NodeList) ContainerRestSplit {
        const empty: ContainerRestSplit = .{ .rest_operand = null, .elements = &[_]u32{} };
        if (list.len == 0) return empty;
        if (list.start + list.len > self.extra_data.items.len) return empty;
        const all = self.extra_data.items[list.start .. list.start + list.len];
        const last_idx: NodeIndex = @enumFromInt(all[all.len - 1]);
        if (last_idx.isNone() or @intFromEnum(last_idx) >= self.nodes.items.len) {
            return .{ .rest_operand = null, .elements = all };
        }
        const last_node = self.getNode(last_idx);
        return switch (last_node.tag) {
            .rest_element, .binding_rest_element, .assignment_target_rest => .{
                .rest_operand = last_node.data.unary.operand,
                .elements = all[0 .. all.len - 1],
            },
            else => .{ .rest_operand = null, .elements = all },
        };
    }

    /// extra_data에 값을 추가하고 시작 인덱스를 반환한다.
    pub fn addExtra(self: *Ast, value: u32) !u32 {
        const index: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(self.allocator, value);
        return index;
    }

    /// extra_data에 NodeIndex 리스트를 추가한다.
    /// 한 번의 capacity check로 전체 리스트를 추가 (O(1) alloc check).
    pub fn addNodeList(self: *Ast, indices: []const NodeIndex) !NodeList {
        const start: u32 = @intCast(self.extra_data.items.len);
        const len: u32 = @intCast(indices.len);
        try self.extra_data.ensureUnusedCapacity(self.allocator, len);
        for (indices) |idx| {
            self.extra_data.appendAssumeCapacity(@intFromEnum(idx));
        }
        return .{ .start = start, .len = len };
    }

    /// extra_data에 여러 u32 값을 한 번에 추가하고 시작 인덱스를 반환한다.
    /// 한 번의 capacity check로 전체를 추가 (개별 addExtra N번보다 효율적).
    pub fn addExtras(self: *Ast, values: []const u32) !u32 {
        const start: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.ensureUnusedCapacity(self.allocator, values.len);
        for (values) |v| {
            self.extra_data.appendAssumeCapacity(v);
        }
        return start;
    }

    /// extra_data에서 u32 값을 읽는다. 범위 밖이면 0 반환.
    pub fn readExtra(self: *const Ast, base: u32, offset: u32) u32 {
        const idx = base + offset;
        if (idx >= self.extra_data.items.len) return 0;
        return self.extra_data.items[idx];
    }

    /// extra_data에서 NodeIndex를 읽는다. 범위 밖이면 NodeIndex.none.
    pub fn readExtraNode(self: *const Ast, base: u32, offset: u32) NodeIndex {
        return @enumFromInt(self.readExtra(base, offset));
    }

    /// extra_data가 base+max_offset까지 유효한지 확인.
    pub fn hasExtra(self: *const Ast, base: u32, max_offset: u32) bool {
        return base + max_offset < self.extra_data.items.len;
    }

    /// span이 가리키는 소스 텍스트를 반환한다.
    /// source와 string_table 모두 지원 (getText에 위임).
    pub fn getSourceText(self: *const Ast, span: Span) []const u8 {
        return self.getText(span);
    }

    /// 합성 문자열을 string_table에 추가하고, 이를 가리키는 Span을 반환한다.
    /// 반환된 Span의 start에는 bit 31이 설정되어 getText()가 string_table에서 읽도록 한다.
    ///
    /// 사용 예:
    ///   const span = try ast.addString("React");
    ///   // 나중에 ast.getText(span)으로 "React" 반환
    pub fn addString(self: *Ast, text: []const u8) !Span {
        // string_table은 bit 31 미만이어야 함 (bit 31은 마커로 사용)
        std.debug.assert(self.string_table.items.len + text.len < STRING_TABLE_BIT);
        const start: u32 = @intCast(self.string_table.items.len);

        // text가 string_table 자기 자신의 슬라이스일 수 있다.
        // appendSlice는 ensureUnusedCapacity에서 realloc을 일으키면서
        // 원본 버퍼를 freed로 만들고 text.ptr을 dangling으로 만든다.
        // 또한 같은 allocation 내의 memcpy는 debug 모드에서 alias panic을 낸다.
        // offset을 먼저 저장한 뒤 realloc을 유도하고, 새 버퍼의 동일 offset에서
        // 바이트 단위로 복사하면 두 문제 모두 안전하게 처리된다.
        const table_base = self.string_table.items.ptr;
        const base_addr = @intFromPtr(table_base);
        const items_end = base_addr + self.string_table.items.len;
        const tp = @intFromPtr(text.ptr);
        const text_in_table = tp >= base_addr and tp + text.len <= items_end;

        if (text_in_table) {
            const offset: usize = tp - base_addr;
            try self.string_table.ensureUnusedCapacity(self.allocator, text.len);
            const dest_start = self.string_table.items.len;
            self.string_table.items.len = dest_start + text.len;
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                self.string_table.items[dest_start + i] = self.string_table.items[offset + i];
            }
        } else {
            try self.string_table.appendSlice(self.allocator, text);
        }
        const end: u32 = @intCast(self.string_table.items.len);
        return .{
            .start = start | STRING_TABLE_BIT,
            .end = end | STRING_TABLE_BIT,
        };
    }

    /// Span이 가리키는 텍스트를 반환한다.
    /// bit 31이 설정되어 있으면 string_table에서, 아니면 source에서 읽는다.
    /// 기존 getSourceText와 달리, 합성 문자열도 투명하게 처리한다.
    /// string_literal의 raw 텍스트에서 따옴표를 제거한 specifier 반환.
    /// "path" → path, 'path' → path. 따옴표가 없으면 그대로 반환.
    pub fn stripStringQuotes(raw: []const u8) []const u8 {
        if (raw.len >= 2 and (raw[0] == '"' or raw[0] == '\''))
            return raw[1 .. raw.len - 1];
        return raw;
    }

    pub fn getText(self: *const Ast, span: Span) []const u8 {
        if (span.start & STRING_TABLE_BIT != 0) {
            // string_table 참조
            const start = span.start & ~STRING_TABLE_BIT;
            const end = span.end & ~STRING_TABLE_BIT;
            return self.string_table.items[start..end];
        }
        return self.source[span.start..span.end];
    }
};

// ============================================================
// Function Declaration Flags (extra_data에 저장되는 비트 플래그)
// parser와 semantic analyzer가 공유.
// ============================================================

/// function declaration/expression의 flags 비트.
/// extra: [name, params.start, params.len, body, flags, return_type]
pub const FunctionFlags = struct {
    pub const is_async: u32 = 0x01;
    pub const is_generator: u32 = 0x02;
    pub const no_side_effects: u32 = 0x04; // @__NO_SIDE_EFFECTS__
};

/// method_definition의 flags 비트 (extra[3] u16).
/// parser/object.zig + parser/class.zig에서 동일하게 기록하고 semantic/transformer가 읽음.
pub const MethodFlags = struct {
    pub const is_static: u32 = 0x01;
    pub const is_getter: u32 = 0x02;
    pub const is_setter: u32 = 0x04;
    pub const is_async: u32 = 0x08;
    pub const is_generator: u32 = 0x10;
    pub const is_abstract: u32 = 0x20;
    pub const is_declare: u32 = 0x40;
};

/// method_definition → function_declaration/expression으로 추출할 때
/// async/generator 비트를 FunctionFlags 위치로 옮긴다.
/// 두 공간의 비트 위치가 달라 복사할 때마다 같은 매핑이 반복되던 것을 한 곳에 모았다.
/// (method의 static/getter/setter 비트는 function에 해당 개념 없음 — 폐기)
pub fn methodFlagsToFunctionFlags(method_flags: u32) u32 {
    var fn_flags: u32 = 0;
    if ((method_flags & MethodFlags.is_async) != 0) fn_flags |= FunctionFlags.is_async;
    if ((method_flags & MethodFlags.is_generator) != 0) fn_flags |= FunctionFlags.is_generator;
    return fn_flags;
}

/// method_definition extras 레이아웃: [key, params, body, flags, deco_start, deco_len] (#1513).
/// 매직 offset 숫자 (`readU32(e, 3)`) 대신 `MethodExtra.flags` 사용.
pub const MethodExtra = struct {
    pub const key: u32 = 0;
    pub const params: u32 = 1;
    pub const body: u32 = 2;
    pub const flags: u32 = 3;
    pub const deco_start: u32 = 4;
    pub const deco_len: u32 = 5;
};

/// property_definition / accessor_property extras 레이아웃: [key, init, flags, deco_start, deco_len] (#1513).
pub const PropertyExtra = struct {
    pub const key: u32 = 0;
    pub const init: u32 = 1;
    pub const flags: u32 = 2;
    pub const deco_start: u32 = 3;
    pub const deco_len: u32 = 4;
};

/// property_definition / accessor_property의 flags 비트 (PropertyExtra.flags).
/// class member parser가 method/property를 같은 함수에서 파싱하므로
/// `MethodFlags`와 비트 위치를 공유한다. property에서 의미있는 비트만 expose.
/// (getter/setter/async/generator는 method 전용 — property에선 parser가 기록하지 않음)
pub const PropertyFlags = struct {
    pub const is_static: u32 = 0x01;
    pub const is_abstract: u32 = 0x20;
    pub const is_declare: u32 = 0x40;
    pub const flow_variance: u32 = 0x80; // Flow covariant(+)/contravariant(-) — type-only property
};

/// class_declaration / class_expression extras 레이아웃:
/// [name, super, body, type_params, impl_start, impl_len, deco_start, deco_len] (#1513).
pub const ClassExtra = struct {
    pub const name: u32 = 0;
    pub const super: u32 = 1;
    pub const body: u32 = 2;
    pub const type_params: u32 = 3;
    pub const impl_start: u32 = 4;
    pub const impl_len: u32 = 5;
    pub const deco_start: u32 = 6;
    pub const deco_len: u32 = 7;
};

/// formal_parameter extras 레이아웃: [pattern, type_ann, default, flags, deco_start, deco_len] (#1513).
pub const FormalParameterExtra = struct {
    pub const pattern: u32 = 0;
    pub const type_ann: u32 = 1;
    pub const default: u32 = 2;
    pub const flags: u32 = 3;
    pub const deco_start: u32 = 4;
    pub const deco_len: u32 = 5;
};

/// call_expression / new_expression의 flags 비트 (D082).
/// extra: [callee, args_start, args_len, flags]
pub const CallFlags = struct {
    pub const is_pure: u32 = 0x01; // @__PURE__ / #__PURE__
    pub const optional_chain: u32 = 0x02; // a?.()
};

/// static_member_expression / computed_member_expression / private_field_expression의 flags (D082).
/// extra: [object, property, flags]
pub const MemberFlags = struct {
    pub const optional_chain: u32 = 0x01; // a?.b, a?.[b]
};

/// unary_expression의 flags (D082).
/// extra: [operand, operator_and_flags]
/// operator_and_flags: bits [0-7] = operator Kind, bit 8 = postfix, bits [16-31] = 확장 플래그
pub const UnaryFlags = struct {
    pub const postfix: u32 = 0x100; // x++ / x--
};

/// arrow_function_expression의 flags (D082).
/// extra: [params, body, flags]
pub const ArrowFlags = struct {
    pub const is_async: u32 = 0x01;
    pub const no_side_effects: u32 = 0x02; // @__NO_SIDE_EFFECTS__
};

/// tagged_template_expression의 flags (D082).
/// extra: [tag, template, flags]
pub const TaggedTemplateFlags = struct {
    pub const is_pure: u32 = 0x01; // @__PURE__
};

/// variable_declaration의 kind. extra[0]에 u32로 저장.
/// 매직넘버(0~4) 대신 typed enum 사용. 값은 wire-compat 유지를 위해 고정.
pub const VariableDeclarationKind = enum(u32) {
    @"var" = 0,
    let = 1,
    @"const" = 2,
    using = 3,
    await_using = 4,

    pub inline fn fromU32(v: u32) VariableDeclarationKind {
        return switch (v) {
            0 => .@"var",
            1 => .let,
            2 => .@"const",
            3 => .using,
            4 => .await_using,
            else => .@"var", // 미지값은 var로 fallback (parser fallback과 일치)
        };
    }

    pub inline fn isLexical(self: VariableDeclarationKind) bool {
        return self != .@"var";
    }

    pub inline fn isUsing(self: VariableDeclarationKind) bool {
        return self == .using or self == .await_using;
    }
};
