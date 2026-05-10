//! Main AST node dispatch for Codegen.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const statement_emit = @import("statements.zig");
const module_emit = @import("modules.zig");
const type_runtime_emit = @import("type_runtime.zig");
const expression_emit = @import("expressions.zig");
const call_emit = @import("calls.zig");
const function_class_emit = @import("function_class.zig");
const binding_emit = @import("bindings.zig");

const Error = std.mem.Allocator.Error;

pub fn emitNode(self: anytype, idx: NodeIndex) Error!void {
    if (idx.isNone()) return;

    // 번들 모드: skip_nodes에 있으면 출력하지 않음 (import/export 제거)
    if (statement_emit.isSkipped(self, idx)) return;

    const node = self.ast.getNode(idx);

    // 이 노드 이전에 위치한 주석들을 출력.
    // STRING_TABLE_BIT가 설정된 span은 합성 노드(string_table 참조)이므로
    // 원본 소스 위치가 아님 → 주석 위치 비교를 건너뛴다.
    if (node.span.start != node.span.end and node.span.start & Ast.STRING_TABLE_BIT == 0) {
        try statement_emit.emitComments(self, node.span.start);
    }

    // 소스맵 매핑은 각 emitter / inline case 가 명시 발행 (oxc/esbuild 패턴).
    // 컨테이너 노드 (program, block_statement, function_body, class_body, static_block,
    // switch_statement, try_statement) 는 자식이 매핑하므로 자체 발행 안 함.

    switch (node.tag) {
        .program => try statement_emit.emitProgram(self, node),
        .block_statement => try statement_emit.emitBlock(self, node),
        .empty_statement => {
            try self.addSourceMapping(node.span);
            try self.writeByte(';');
        },
        .expression_statement => try statement_emit.emitExpressionStatement(self, node),
        .variable_declaration => try binding_emit.emitVariableDeclaration(self, node),
        .variable_declarator => try binding_emit.emitVariableDeclarator(self, node),
        .return_statement => try statement_emit.emitReturn(self, node),
        .throw_statement => try statement_emit.emitThrow(self, node),
        .if_statement => try statement_emit.emitIf(self, node),
        .while_statement => try statement_emit.emitWhile(self, node),
        .do_while_statement => try statement_emit.emitDoWhile(self, node),
        .for_statement => try statement_emit.emitFor(self, node),
        .for_in_statement => try statement_emit.emitForInOf(self, node, "in"),
        .for_of_statement => try statement_emit.emitForInOf(self, node, "of"),
        .for_await_of_statement => try statement_emit.emitForAwaitOf(self, node),
        .switch_statement => try statement_emit.emitSwitch(self, node),
        .switch_case => try statement_emit.emitSwitchCase(self, node),
        .break_statement => try statement_emit.emitSimpleStmt(self, node, "break"),
        .continue_statement => try statement_emit.emitSimpleStmt(self, node, "continue"),
        .debugger_statement => {
            try self.addSourceMapping(node.span);
            try self.write("debugger;");
        },
        .try_statement => try statement_emit.emitTry(self, node),
        .catch_clause => try statement_emit.emitCatch(self, node),
        .labeled_statement => try statement_emit.emitLabeled(self, node),
        .with_statement => try statement_emit.emitWith(self, node),
        .directive => {
            try self.addSourceMapping(node.span);
            // span 은 문자열 리터럴 범위 (따옴표 포함). quote_style 정규화를 적용해
            // `'use server'` → `"use server"` 같은 변환이 일반 string_literal 과 동일하게
            // 일어나도록 writeStringLiteral 사용. 항상 `;` 를 붙여 ASI 의존을 피한다.
            try self.writeStringLiteral(node.span);
            try self.writeByte(';');
        },
        .hashbang => {
            if (!self.options.strip_hashbang) {
                try self.addSourceMapping(node.span);
                try self.writeNodeSpan(node);
            }
        },

        // Literals
        .boolean_literal => {
            try self.addSourceMapping(node.span);
            // Peephole: true → !0, false → !1 (minify_syntax 활성화 시).
            // #1552: 각 리터럴당 2-3 byte 절감. 출현 빈도 높아 총 크기 영향 있음.
            // span의 첫 byte는 `t` 또는 `f`로 고정(렉서 불변식) — 한 byte 검사로 판별.
            if (self.options.minify_syntax) {
                const text = self.ast.getText(node.span);
                try self.write(if (text.len > 0 and text[0] == 't') "!0" else "!1");
            } else {
                try self.writeNodeSpan(node);
            }
        },
        .null_literal,
        .numeric_literal,
        .bigint_literal,
        .regexp_literal,
        => {
            try self.addSourceMapping(node.span);
            try self.writeNodeSpan(node);
        },

        .string_literal => {
            try self.addSourceMapping(node.span);
            try self.writeStringLiteral(node.span);
        },

        // Identifiers — 번들 모드에서 symbol_id 기반 리네임 적용
        .identifier_reference,
        .private_identifier,
        .binding_identifier,
        .assignment_target_identifier,
        => {
            try self.addSourceMapping(node.span);
            // Peephole: global `undefined` → `(void 0)` (minify_syntax 활성화 시).
            // 9 bytes → 8 bytes, 1 byte 절감. parens는 member/call/new 등 모든 parent
            // context에서 안전하게 해석되도록 유지 — `undefined.x`/`undefined()` 같은
            // 경로를 간단한 치환으로 깨지 않기 위함 (`void 0.x`는 `void (0.x)`로 오파싱).
            // global binding일 때만 치환 (shadow rebind 드물지만 보호).
            if (self.options.minify_syntax and node.tag == .identifier_reference) {
                const text = self.ast.getText(node.span);
                if (std.mem.eql(u8, text, "undefined")) {
                    const is_global = if (self.options.linking_metadata) |meta|
                        self.resolveSymbolId(idx, meta) == null
                    else
                        true;
                    if (is_global) {
                        try self.write("(void 0)");
                        return;
                    }
                }
            }

            if (self.options.linking_metadata) |meta| {
                const sym_id = self.resolveSymbolId(idx, meta);
                if (sym_id) |sid| {
                    // 상수 인라인: import symbol이 상수이면 리터럴로 대체
                    if (node.tag == .identifier_reference) {
                        if (meta.const_values.get(sid)) |cv| {
                            try self.writeConstValue(cv);
                            return;
                        }
                    }
                    // namespace 변수 참조: ns를 값으로 사용 → 변수명으로 치환
                    if (meta.ns_inline_objects.get(sid)) |entry| {
                        try self.write(entry.var_name);
                        return;
                    }
                    if (meta.renames.get(sid)) |new_name| {
                        try self.write(new_name);
                        return;
                    }
                }
            }
            // namespace IIFE 내부: export된 변수의 "참조"를 ns.name으로 치환.
            // identifier_reference(값 참조)와 assignment_target_identifier(대입 대상) 모두 치환.
            // binding_identifier(선언 위치)는 치환하지 않음 — 선언은 emitNamespaceVarDirectAssign에서 처리.
            if (self.ns_prefix) |prefix| {
                if (node.tag == .identifier_reference or node.tag == .assignment_target_identifier) {
                    const name = self.ast.getText(node.data.string_ref);
                    if (self.ns_exports) |exports| {
                        if (exports.contains(name)) {
                            try self.write(prefix);
                            try self.writeByte('.');
                            try self.write(name);
                            return;
                        }
                    }
                }
            }
            try self.writeSpan(node.data.string_ref);
        },

        .this_expression => {
            try self.addSourceMapping(node.span);
            try self.write("this");
        },
        .super_expression => {
            try self.addSourceMapping(node.span);
            try self.write("super");
        },

        // Expressions
        .unary_expression => try expression_emit.emitUnary(self, node),
        .update_expression => try expression_emit.emitUpdate(self, node),
        .binary_expression, .logical_expression => try expression_emit.emitBinary(self, node),
        .assignment_expression => try expression_emit.emitAssignment(self, node),
        .conditional_expression => try expression_emit.emitConditional(self, node),
        .sequence_expression => try expression_emit.emitSequence(self, node),
        .parenthesized_expression => try expression_emit.emitParen(self, node),
        .spread_element => try expression_emit.emitSpread(self, node),
        .await_expression => try expression_emit.emitAwait(self, node),
        .yield_expression => try expression_emit.emitYield(self, node),
        .array_expression => try expression_emit.emitArray(self, node),
        .object_expression => try expression_emit.emitObject(self, node),
        .object_property => try expression_emit.emitObjectProperty(self, node),
        .computed_property_key => try expression_emit.emitComputedKey(self, node),
        .static_member_expression => try expression_emit.emitStaticMember(self, node),
        .computed_member_expression => try expression_emit.emitComputedMember(self, node),
        .private_field_expression => try expression_emit.emitStaticMember(self, node),
        .call_expression => try call_emit.emitCall(self, node),
        .new_expression => try call_emit.emitNew(self, node),
        .template_literal => try function_class_emit.emitTemplateLiteral(self, node),
        .template_element => {
            try self.addSourceMapping(node.span);
            try self.writeNodeSpan(node);
        },
        .tagged_template_expression => try function_class_emit.emitTaggedTemplate(self, node),
        .import_expression => try call_emit.emitImportExpr(self, node),
        .meta_property => try call_emit.emitMetaProperty(self, node),
        // chain_expression / TS·Flow type-cast: transparent wrapper — operand 가 자기 매핑 발행.
        .chain_expression => try self.emitNode(node.data.unary.operand),

        // Functions / Classes
        .function_declaration, .function_expression, .function => try function_class_emit.emitFunction(self, node),
        .arrow_function_expression => try function_class_emit.emitArrow(self, node),
        .class_declaration, .class_expression => try function_class_emit.emitClass(self, node),
        .class_body => try function_class_emit.emitClassBody(self, node),
        .method_definition => try function_class_emit.emitMethodDef(self, node),
        .property_definition => try function_class_emit.emitPropertyDef(self, node),
        .static_block => try function_class_emit.emitStaticBlock(self, node),
        .decorator => try function_class_emit.emitDecorator(self, node),
        .accessor_property => try function_class_emit.emitAccessorProp(self, node),

        // Patterns
        .array_pattern, .array_assignment_target => try expression_emit.emitArray(self, node),
        .object_pattern, .object_assignment_target => try expression_emit.emitObject(self, node),
        .assignment_pattern => try binding_emit.emitAssignmentPattern(self, node),
        .binding_property => try binding_emit.emitBindingProperty(self, node),
        .rest_element, .binding_rest_element, .assignment_target_rest => try binding_emit.emitRest(self, node),
        .assignment_target_with_default => try binding_emit.emitAssignmentPattern(self, node),
        .assignment_target_property_identifier,
        .assignment_target_property_property,
        => try binding_emit.emitBindingProperty(self, node),
        .elision => {},

        // Import/Export
        .import_declaration => try module_emit.emitImport(self, node),
        .import_specifier,
        .import_default_specifier,
        .import_namespace_specifier,
        .import_attribute,
        => {
            try self.addSourceMapping(node.span);
            try self.writeNodeSpan(node);
        },
        .export_named_declaration => try module_emit.emitExportNamed(self, node),
        .export_default_declaration => try module_emit.emitExportDefault(self, node),
        .export_all_declaration => try module_emit.emitExportAll(self, node),
        .export_specifier => try module_emit.emitExportSpecifier(self, node),

        // Formal parameters
        .formal_parameters, .function_body => try self.emitList(node, self.listSep()),

        .formal_parameter => try binding_emit.emitFormalParam(self, node),

        // Flow match expression — transformer에서 if-else IIFE로 변환됨
        // 변환되지 않은 경우 (non-bundle 등) span 텍스트 그대로 출력
        .flow_match_expression => {
            try self.addSourceMapping(node.span);
            try self.writeNodeSpan(node);
        },

        // JSX: Transformer의 jsx_lowering이 call_expression으로 변환 완료.
        // codegen은 JSX AST 노드를 만나지 않아야 함.
        .jsx_element,
        .jsx_fragment,
        .jsx_expression_container,
        .jsx_text,
        .jsx_spread_attribute,
        .jsx_spread_child,
        => unreachable,

        // TS enum/namespace → IIFE 출력
        .ts_enum_declaration => try type_runtime_emit.emitEnumIIFE(self, node),
        .ts_module_declaration => try type_runtime_emit.emitNamespaceIIFE(self, node),
        // Flow enum (#2401) → `const Name = Object.freeze({...})` 출력. members 의
        // init expression 이 없으면 base_type 에 따라 default value (string/number/...).
        .flow_enum_declaration => try type_runtime_emit.emitFlowEnum(self, node),

        // TS/Flow expression 노드: operand만 출력 (type 부분 스트리핑).
        // pre-visit body를 codegen할 때 (e.g. worklet __initData.code) TS/Flow 노드가 남아있을 수 있음.
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_non_null_expression,
        .ts_type_assertion,
        .ts_instantiation_expression,
        .flow_as_expression,
        .flow_type_cast_expression,
        => try self.emitNode(node.data.unary.operand),

        // TS 타입 전용 노드: 출력 안 함
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        .ts_import_equals_declaration,
        => {},

        // 그 외 — 소스 텍스트 그대로 출력
        else => {
            try self.addSourceMapping(node.span);
            try self.writeNodeSpan(node);
        },
    }
}
