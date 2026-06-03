//! Main AST node dispatch for Codegen.

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = ast_mod.Ast;
const NodeIndex = ast_mod.NodeIndex;
const cg_options = @import("options.zig");
const statement_emit = @import("statements.zig");
const module_emit = @import("modules.zig");
const type_runtime_emit = @import("type_runtime.zig");
const expression_emit = @import("expressions.zig");
const call_emit = @import("calls.zig");
const function_class_emit = @import("function_class.zig");
const binding_emit = @import("bindings.zig");
const precedence = @import("precedence.zig");
const Level = precedence.Level;
const ExprFlags = precedence.ExprFlags;
const Kind = @import("../lexer/token.zig").Kind;

const Error = std.mem.Allocator.Error;

pub fn emitNode(self: anytype, idx: NodeIndex) Error!void {
    return emitExpr(self, idx, .lowest, .{});
}

/// Expression 전용 emit 진입점 (esbuild `printExpr(expr, level, flags)`). 전처리
/// (skip/comments/transparent-wrapper)부터 dispatch 까지 모든 노드를 처리하는 단일
/// 진입점이며, `emitNode` 는 `emitExpr(.lowest, .{})` 의 alias 다 (esbuild 가
/// printStmt 와 printExpr 를 분리하되 둘 다 같은 노드 dispatch 로 들어가는 것과
/// 동형). `level` 은 "이 위치에서 괄호 없이 허용되는 최소 결합 강도", `flags` 는
/// precedence 만으로 표현 못 하는 컨텍스트 괄호 조건이다.
///
/// PR4 단계: `level`/`flags` 는 transparent wrapper 의 level 투과를 빼면 받기만 하고
/// 사용하지 않는다 — 괄호는 여전히 `parenthesized_expression` 노드(emitParen)가
/// 담당하므로 출력은 byte-identical. PR5 에서 각 expression case 진입부에 `wrap`
/// 계산이 채워지고, 자식 emit 이 적절한 child level/flags 를 받아 precedence 로
/// 괄호를 재유도한다.
pub fn emitExpr(self: anytype, idx: NodeIndex, level: Level, flags: ExprFlags) Error!void {
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

    // TS/Flow type wrapper: operand 만 출력 (type 스트리핑, #3129 단일 source).
    // pre-visit body codegen 시 TS/Flow 노드가 남아있을 수 있어 명시 처리.
    if (ast_mod.Node.Tag.isTransparentTypeWrapper(node.tag)) return self.emitExpr(node.data.unary.operand, level, flags);

    // precedence wrap: 자기 결합강도가 부모가 요구한 최소 level 이하면 괄호 (esbuild printExpr).
    // wrap 을 emitExpr 한 곳에 집중해 emitter 내부 early-return 과 무관하게 정확히 닫는다.
    // (PR6a: 연산자만. member/call/new wrap·emitParen 투명화·statement-start 는 ad-hoc 제거와
    //  함께 PR6b. 소스 괄호는 paren 노드가 유지 → 합성 AST 에서만 괄호 추가.)
    const wrap = exprNeedsParens(self, node, level, flags);
    if (wrap) try self.writeByte('(');

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
        .numeric_literal => {
            try self.addSourceMapping(node.span);
            try self.writeNodeSpan(node);
            // 정수 형태(`42`)면 바로 뒤 `.` 가 소수점으로 오파싱됨 → member 의 `.` 가
            // 공백을 끼우도록 위치 마킹 (`42 .toString()`). `.`/`e`/`x`/`b`/`o` 가 있는
            // float/hex/exp/radix(`1.5`/`0xff`/`1e3`)는 `.` 가 멤버로 안전 → 마킹 안 함.
            // esbuild needSpaceBeforeDot (정수만). bigint(`42n`)는 별도 노드라 제외.
            if (numericIsPlainInteger(self.ast.getText(node.span))) {
                self.need_space_before_dot = self.buf.items.len;
            }
        },
        .null_literal,
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
            // mangler / ns_prefix 치환 / inline 치환이 발생하면 원본 이름을 sourcemap
            // names 배열에 등록해 mapping.name_index 로 참조 — Sentry / DevTools 가
            // minified `f` 의 원본 `originalName` 을 stack frame variable / hover 에서
            // 복원. 치환 안 일어나는 일반 경로는 names 발행 X (size 폭증 회피, esbuild
            // 동일 정책).

            // 3 substitute path (undefined→void 0, linking_metadata renames, cjs_wrap)
            // 가 모두 sym_id 를 본다 — 단일 호출로 hoist (per-identifier hot path).
            const sym_id: ?u32 = if (self.options.linking_metadata) |meta|
                self.resolveSymbolId(idx, meta)
            else
                null;

            // Peephole: global `undefined` → `void 0` (minify_syntax 활성화 시).
            // 9 bytes → 6 bytes, 3 bytes 절감 (esbuild/rolldown/rspack 동일).
            // call.callee / member.object / new.callee 슬롯에서는 caller 가 paren 추가
            // (`void 0.x` 가 `void (0.x)` 로 오파싱 되는 위험 회피) — 그 외는 paren 불필요.
            // global binding 일 때만 치환 (shadow rebind 드물지만 보호).
            if (self.options.minify_syntax and node.tag == .identifier_reference and sym_id == null) {
                const text = self.ast.getText(node.span);
                if (std.mem.eql(u8, text, "undefined")) {
                    try self.addSourceMapping(node.span);
                    try self.write("void 0");
                    return;
                }
            }

            if (self.options.linking_metadata) |meta| {
                if (sym_id) |sid| {
                    // 상수 인라인: import symbol이 상수이면 리터럴로 대체
                    if (node.tag == .identifier_reference) {
                        if (meta.const_values.get(sid)) |cv| {
                            try self.addSourceMapping(node.span);
                            try self.writeConstValue(cv);
                            return;
                        }
                    }
                    // namespace 변수 참조: ns를 값으로 사용 → 변수명으로 치환.
                    // 원본 식별자 이름을 names 에 등록해 디버거가 원형 lookup 가능.
                    if (meta.ns_inline_objects.get(sid)) |entry| {
                        const original = self.ast.getText(node.data.string_ref);
                        try self.addSourceMappingWithName(node.span, original);
                        try self.write(entry.var_name);
                        return;
                    }
                    // mangler rename — 원본 이름 names 등록.
                    if (meta.renames.get(sid)) |new_name| {
                        const original = self.ast.getText(node.data.string_ref);
                        try self.addSourceMappingWithName(node.span, original);
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
                            try self.addSourceMappingWithName(node.span, name);
                            try self.write(prefix);
                            try self.writeByte('.');
                            try self.write(name);
                            return;
                        }
                    }
                }
            }
            // CJS wrapper free `exports`/`module` 참조 치환 (RFC PR-2). wrapper
            // 파라미터를 짧은 이름으로 바꿀 때 본문 자유참조도 동기화한다.
            // sym_id == null = 모듈 내 로컬 선언 없음 = __commonJS arrow 파라미터
            // 를 가리킴 → 사용자 shadow(`var exports`)는 sym_id 가 잡혀 이 분기에
            // 도달하지 않으므로 자동 제외. property key(`obj.exports`)·string·
            // computed 는 다른 노드 태그라 미해당. 기본 이름이면 no-op (회귀 0).
            if (self.options.module_format == .cjs and sym_id == null and
                (node.tag == .identifier_reference or node.tag == .assignment_target_identifier))
            {
                const ident = self.ast.getText(node.data.string_ref);
                const repl: ?[]const u8 =
                    if (std.mem.eql(u8, ident, "exports") and
                    !std.mem.eql(u8, self.options.cjs_exports_name, cg_options.default_cjs_exports_name))
                        self.options.cjs_exports_name
                    else if (std.mem.eql(u8, ident, "module") and
                    !std.mem.eql(u8, self.options.cjs_module_name, cg_options.default_cjs_module_name))
                        self.options.cjs_module_name
                    else
                        null;
                if (repl) |name| {
                    try self.addSourceMappingWithName(node.span, ident);
                    try self.write(name);
                    return;
                }
            }
            try self.addSourceMapping(node.span);
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

        // Expressions — 자식 emit 은 후속 PR 에서 child level/flags 를 받는다(PR4:
        // 아직 emitNode=.lowest fallback, byte-identical).
        .unary_expression => try expression_emit.emitUnary(self, node, level, flags),
        .update_expression => try expression_emit.emitUpdate(self, node, level, flags),
        .binary_expression, .logical_expression => try expression_emit.emitBinary(self, node, level, flags),
        .assignment_expression => try expression_emit.emitAssignment(self, node, level, flags),
        .conditional_expression => try expression_emit.emitConditional(self, node, level, flags),
        .sequence_expression => try expression_emit.emitSequence(self, node),
        .parenthesized_expression => try expression_emit.emitParen(self, node, level, flags),
        .spread_element => try expression_emit.emitSpread(self, node, level, flags),
        .await_expression => try expression_emit.emitAwait(self, node, level, flags),
        .yield_expression => try expression_emit.emitYield(self, node, level, flags),
        .array_expression => try expression_emit.emitArray(self, node),
        .object_expression => try expression_emit.emitObject(self, node),
        .object_property => try expression_emit.emitObjectProperty(self, node),
        .computed_property_key => try expression_emit.emitComputedKey(self, node),
        .static_member_expression => try expression_emit.emitStaticMember(self, node, level, flags),
        .computed_member_expression => try expression_emit.emitComputedMember(self, node, level, flags),
        .private_field_expression => try expression_emit.emitStaticMember(self, node, level, flags),
        .call_expression => try call_emit.emitCall(self, node, level, flags),
        .new_expression => try call_emit.emitNew(self, node, level, flags),
        .template_literal => try function_class_emit.emitTemplateLiteral(self, node),
        .template_element => {
            try self.addSourceMapping(node.span);
            try self.writeNodeSpan(node);
        },
        .tagged_template_expression => try function_class_emit.emitTaggedTemplate(self, node),
        .import_expression => try call_emit.emitImportExpr(self, node, level, flags),
        .meta_property => try call_emit.emitMetaProperty(self, node),
        // chain_expression: optional-chain wrapper — operand 가 자기 매핑 발행.
        // (TS·Flow type-cast 는 위 transparent-wrapper 분기에서 처리됨.) level/flags 투과.
        .chain_expression => try self.emitExpr(node.data.unary.operand, level, flags),

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

        // JSX: 일반적으로 Transformer 의 jsx_lowering 이 call_expression 으로 변환.
        // jsx_runtime == .preserve 면 JSX 노드가 codegen 까지 도달 — 원본 소스
        // slice 를 그대로 emit (downstream tool 이 처리하도록 위임).
        //
        // 알려진 제약: JSX 자식 (attribute value / expression container) 내부의
        // TypeScript 어노테이션 (e.g. `<Foo prop={value as Type}>`) 은 strip 되지
        // 않은 채 raw 로 남는다. preserve 모드의 주 사용처가 vite plugin chain 의
        // downstream tool 위임이라 그쪽이 TS 까지 함께 처리하는 것으로 가정.
        .jsx_element,
        .jsx_fragment,
        .jsx_opening_element,
        .jsx_closing_element,
        .jsx_attribute,
        .jsx_spread_attribute,
        .jsx_spread_child,
        .jsx_expression_container,
        .jsx_text,
        .jsx_namespaced_name,
        .jsx_member_expression,
        => {
            try self.addSourceMapping(node.span);
            try self.writeNodeSpan(node);
        },

        // TS enum/namespace → IIFE 출력
        .ts_enum_declaration => try type_runtime_emit.emitEnumIIFE(self, node),
        .ts_module_declaration => try type_runtime_emit.emitNamespaceIIFE(self, node),
        // Flow enum (#2401) → `const Name = Object.freeze({...})` 출력. members 의
        // init expression 이 없으면 base_type 에 따라 default value (string/number/...).
        .flow_enum_declaration => try type_runtime_emit.emitFlowEnum(self, node),

        // (TS/Flow type wrapper 는 switch 진입 전 #3129 single-source 처리)

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

    if (wrap) try self.writeByte(')');
}

/// 이 expression 노드가 부모가 요구한 `level`/`flags` 에서 괄호가 필요한지 (esbuild
/// `printExpr` 진입부의 `wrap := level >= entry.Level`). wrap 을 emitExpr 한 곳에
/// 모아, emitter 내부 early-return 과 무관하게 정확히 여닫는다.
///
/// 전 표현식 커버: 연산자(unary/update/binary/conditional/assignment/sequence/yield/
/// await) + statement-start primary(object/function/class/destructuring) + member/
/// call/new/import optional-chain·precedence wrap + arrow. precedence 로 표현 불가한
/// 잔여 ad-hoc 은 newCalleeNeedsRenameParens(rename→call 체인)·emitNodeMaybeUndefParen
/// (`void 0` peephole)·emitStaticMember 의 ns 미존재 `(void 0)` 뿐.
///
/// 주의 — identifier_reference 처럼 dispatch case 안에 early-return 이 있는 노드는
/// 여기서 wrap 을 켜면 닫는 `)` 가 누락된다(전부 별도 fn 으로 dispatch 되는 노드만 안전).
fn exprNeedsParens(self: anytype, node: ast_mod.Node, level: Level, flags: ExprFlags) bool {
    return switch (node.tag) {
        .unary_expression, .await_expression => level.gte(.prefix),
        .update_expression => blk: {
            const e = node.data.extra;
            const extras = self.ast.extra_data.items;
            if (e + 1 >= extras.len) break :blk false;
            const is_postfix = (extras[e + 1] & ast_mod.UnaryFlags.postfix) != 0;
            break :blk level.gte(if (is_postfix) Level.postfix else Level.prefix);
        },
        .binary_expression, .logical_expression => blk: {
            const op: Kind = @enumFromInt(node.data.binary.flags);
            const entry = precedence.binaryOpLevel(op) orelse break :blk false;
            // logical 단락 폴드 시 right 가 logical 자리에 옴 → 자기(right) wrap 으로
            // 위임하고 여기선 wrap 안 함(emitBinary 가 right 를 부모 level 로 투과).
            if (node.tag == .logical_expression and self.options.linking_metadata != null) {
                if (self.evalBooleanCondition(node.data.binary.left) != null) break :blk false;
            }
            break :blk level.gte(entry) or (op == .kw_in and flags.forbid_in);
        },
        .conditional_expression => blk: {
            // conditional 폴드(상수 test) 시 분기가 그 자리 → 자기 wrap 으로 위임.
            if (self.options.linking_metadata != null) {
                if (self.evalBooleanCondition(node.data.ternary.a) != null) break :blk false;
            }
            break :blk level.gte(.conditional);
        },
        .assignment_expression => level.gte(.assign) or
            // destructuring 할당(`({a}=b)`)이 statement-start / arrow body-start 면 괄호
            // 필수 — `{` 가 block 으로 오파싱되는 것을 막는다 (esbuild binaryExprVisitor).
            (self.atStmtOrArrowStart() and assignTargetIsObject(self, node.data.binary.left)),
        .sequence_expression => level.gte(.comma),
        .yield_expression => level.gte(.assign),
        // object literal 이 statement-start / arrow body-start 면 `{` block 오파싱 방지
        // 괄호 (`({})`, `()=>({})`). esbuild EObject wrap.
        .object_expression => self.atStmtOrArrowStart(),
        // function/class expression 이 statement-start / export-default-start 면 선언문
        // 형태와의 혼동을 막는 괄호 (`(function(){})()`, `export default (class{})`).
        // 선언 노드(function_declaration/class_declaration)는 제외 — 그쪽은 마킹이
        // 안 걸리고, 걸려도 선언을 식으로 바꾸면 안 된다. esbuild EFunction/EClass wrap.
        .function_expression, .function, .class_expression => self.atStmtOrExportDefaultStart(),
        // arrow 는 .assign 미만에서만 괄호 없이 올 수 있다 (esbuild EArrow:
        // `level >= LAssign`). `new (()=>{})()`, `(()=>{}).x`, `a ? ()=>b : c` 등.
        .arrow_function_expression => level.gte(.assign),
        // member optional-chain 끊기: 이 멤버가 체인 내부(Start=`?.` 또는 Continue=체인 안
        // `.`)이고 부모가 non-optional 이면 괄호로 끊어 보존 (`(a?.b).c`). `a?.b.c` 의 `.c`
        // 는 Continue 라 끊지 않는다. 그 외 멤버는 precedence 최고(member)라 wrap 없음 (esbuild EDot/EIndex).
        .static_member_expression, .computed_member_expression, .private_field_expression => blk: {
            if (!flags.has_non_optional_chain_parent) break :blk false;
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 2)) break :blk false;
            const member_flags = self.ast.readExtra(e, 2);
            // self 가 체인 내부(Start=`?.` 또는 Continue=object 가 체인)이고 부모가 None 이면 끊는다.
            const self_in_chain = (member_flags & ast_mod.MemberFlags.optional_chain) != 0 or
                call_emit.objectContinuesOptionalChain(self, self.ast.readExtraNode(e, 0));
            break :blk self_in_chain;
        },
        // call wrap = level>=new(즉 new 의 callee) | forbid_call | optional-chain 끊기
        // | pure-comment at postfix (esbuild ECall). `new (foo())`, `(a?.())()` 등.
        .call_expression => blk: {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) break :blk false;
            const call_flags = self.ast.readExtra(e, 3);
            const is_pure = (call_flags & ast_mod.CallFlags.is_pure) != 0;
            const chain_break = flags.has_non_optional_chain_parent and
                ((call_flags & ast_mod.CallFlags.optional_chain) != 0 or
                    call_emit.objectContinuesOptionalChain(self, self.ast.readExtraNode(e, 0)));
            break :blk level.gte(.new) or flags.forbid_call or chain_break or
                (is_pure and !self.options.minify_whitespace and level.gte(.postfix));
        },
        // new wrap = level>=call (member/call 의 타겟) | pure-comment at postfix
        // (esbuild ENew). `(new X).y`, `(new X)()` 처럼 뒤에 `.`/`()` 가 붙는 경우.
        .new_expression => blk: {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) break :blk false;
            const new_flags = self.ast.readExtra(e, 3);
            const is_pure = (new_flags & ast_mod.CallFlags.is_pure) != 0;
            break :blk level.gte(.call) or
                (is_pure and !self.options.minify_whitespace and level.gte(.postfix));
        },
        // import() call (esbuild EImportCall): call 과 동일 (level>=new | forbid_call).
        .import_expression => level.gte(.new) or flags.forbid_call,
        // (for-of init `let`/`async` 식별자 wrap 은 identifier_reference 의 inline
        //  early-return 들과 충돌하므로 중앙 wrap 으로 처리하지 않는다.)
        else => false,
    };
}

/// numeric literal 텍스트가 정수 형태(ASCII 숫자만)인지 — 바로 뒤 `.` 가 소수점으로
/// 오파싱되는 형태. `1.5`/`0xff`/`1e3`/`0b1`/`0o7`/`42n` 등은 false(그 뒤 `.` 안전).
fn numericIsPlainInteger(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// 할당식의 좌변(lvalue 타겟)이 object destructuring 패턴인지. `({a}=b)` 처럼
/// statement-start 에서 `{` 가 block 으로 오파싱되는 것을 막는 wrap 판정용.
/// 배열 패턴(`[a]=b`)은 `[` 가 statement-start 에서 모호하지 않아 제외 (esbuild 동일).
fn assignTargetIsObject(self: anytype, left: NodeIndex) bool {
    if (left.isNone() or @intFromEnum(left) >= self.ast.nodes.items.len) return false;
    return switch (self.ast.getNode(left).tag) {
        .object_expression, .object_pattern, .object_assignment_target => true,
        else => false,
    };
}
