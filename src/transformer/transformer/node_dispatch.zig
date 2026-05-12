//! Node dispatch visitor for Transformer.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const NodeIndex = ast_mod.NodeIndex;
const module_parser = @import("../../parser/module.zig");
const token_mod = @import("../../lexer/token.zig");
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

const es2016 = @import("../es2016.zig");
const es2018 = @import("../es2018.zig");
const es2017_mod = @import("../es2017.zig");
const es2019 = @import("../es2019.zig");
const es2020 = @import("../es2020.zig");
const es2021 = @import("../es2021.zig");
const es2022 = @import("../es2022.zig");
const es2015_template = @import("../es2015_template.zig");
const es2015_computed = @import("../es2015_computed.zig");
const es2015_object_methods = @import("../es2015_object_methods.zig");
const es2015_spread = @import("../es2015_spread.zig");
const es2015_arrow = @import("../es2015_arrow.zig");
const es2015_for_of = @import("../es2015_for_of.zig");
const es2018_for_await = @import("../es2018_for_await.zig");
const es2015_destructuring = @import("../es2015_destructuring.zig");
const es2015_class = @import("../es2015_class.zig");
const es2015_generator = @import("../es2015_generator.zig");
const regex_lower = @import("../regex_lower.zig");
const unicode_escape_lower = @import("../unicode_escape_lower.zig");
const es2022_tla = @import("../es2022_tla.zig");
const jsx_lowering_mod = @import("../jsx_lowering.zig");
const es_helpers = @import("../es_helpers.zig");
const styled_components_mod = @import("styled_components.zig");
const emotion_mod = @import("emotion.zig");
const type_only_mod = @import("type_only.zig");
const isTypeOnlyNode = type_only_mod.isTypeOnlyNode;

pub fn visitNodeInner(self: *Transformer, idx: NodeIndex) Error!NodeIndex {
    const node = self.ast.getNode(idx);

    // --------------------------------------------------------
    // 1단계: TS 타입 전용 노드는 통째로 삭제
    // --------------------------------------------------------
    if (self.options.strip_types and isTypeOnlyNode(node.tag)) {
        return .none;
    }

    // --------------------------------------------------------
    // 2단계: --drop 처리
    // --------------------------------------------------------
    if (self.shouldDropNode(node)) return .none;

    // --------------------------------------------------------
    // 3단계: define 글로벌 치환
    // --------------------------------------------------------
    // worklet body 내부에서는 억제: UI 런타임은 bundler prelude의 polyfill 심볼을 모름.
    if (self.options.define.len > 0 and self.plugins.worklet.body_depth == 0) {
        if (self.tryDefineReplace(node)) |new_node| {
            return try new_node;
        }
    }

    // --------------------------------------------------------
    // 4단계: 태그별 분기 (switch 기반 visitor)
    // --------------------------------------------------------
    return switch (node.tag) {
        // === TS expressions: 타입 부분만 제거, 값 보존 ===
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_non_null_expression,
        .ts_type_assertion,
        .ts_instantiation_expression,
        .flow_as_expression,
        .flow_type_cast_expression,
        => self.visitTsExpression(idx),

        .flow_match_expression => self.visitFlowMatch(node),

        // Flow component with ref → function Name_withRef + const Name = React.forwardRef(...)
        .flow_component_wrapper => self.visitFlowComponentWrapper(node),

        // === 리스트 노드: 자식을 하나씩 방문하며 복사 ===
        .program => {
            // Plugin visitor 훅 선취권 (file-level worklet directive 등)
            if (try self.dispatchVisitor(.on_program, idx)) |replacement| return replacement;
            // ES2022 top-level await 다운레벨링: 미지원 타겟에서 async IIFE 로 wrap. (#1384)
            if (self.options.unsupported.top_level_await) {
                if (try es2022_tla.lowerProgram(Transformer, self, node)) |wrapped| {
                    return wrapped;
                }
            }
            const result = try self.visitListNode(idx);
            // styled-components cssProp transform 으로 추출된 module-level decl 들을
            // program body 끝에 hoist. trailing_nodes 가 nearest list (declarator list 등)
            // 에 들어가는 케이스 회피.
            const pending = &self.plugins.styled_components.css_prop_pending_decls;
            if (pending.items.len > 0) {
                const result_node = self.ast.getNode(result);
                const old_list = result_node.data.list;
                const top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(top);
                for (self.ast.extra_data.items[old_list.start .. old_list.start + old_list.len]) |raw| {
                    try self.scratch.append(self.allocator, @as(NodeIndex, @enumFromInt(raw)));
                }
                for (pending.items) |decl_idx| {
                    try self.scratch.append(self.allocator, decl_idx);
                }
                const new_list = try self.ast.addNodeList(self.scratch.items[top..]);
                pending.clearRetainingCapacity();
                return self.ast.addNode(.{
                    .tag = .program,
                    .span = result_node.span,
                    .data = .{ .list = new_list },
                });
            }
            return result;
        },
        .block_statement,
        .sequence_expression,
        .class_body,
        .formal_parameters,
        .function_body,
        => self.visitListNode(idx),

        // JSX — fragment는 .list, element/opening_element는 .extra
        .jsx_fragment => {
            // preserve 모드면 lowering skip — visitJSXElement / visitListNode 가 자식만
            // visit (TS strip 적용) 하고 JSX 노드 자체는 유지. downstream tool 이 JSX 를
            // 처리할 때 (vite plugin chain 등) 활용.
            if (self.options.shouldLowerJsx()) {
                return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXFragment(self, node);
            }
            return self.visitListNode(idx);
        },

        .template_literal => {
            if (self.options.unsupported.template_literal) {
                return es2015_template.ES2015Template(Transformer).lowerTemplateLiteral(self, node);
            }
            // no-substitution template (data.none == 0)은 리프 노드 — visitListNode으로 처리하면
            // data.list = {start: X, len: 0}이 되어 codegen의 data.none == 0 체크가 깨짐
            if (node.data.none == 0) return self.copyNodeDirect(idx);
            return self.visitListNode(idx);
        },

        // array_expression: spread(ES2015) 다운레벨링
        .array_expression => {
            if (self.options.unsupported.spread) {
                if (es2015_spread.ES2015Spread(Transformer).hasSpreadInArray(self, node)) {
                    return es2015_spread.ES2015Spread(Transformer).lowerSpreadArray(self, node);
                }
            }
            return self.visitListNode(idx);
        },

        // object_expression: spread(ES2018) / method shorthand / computed property(ES2015) 다운레벨링
        .object_expression => {
            // Plugin visitor 훅 — 기본 방문 전 선취권 (null 반환 시 default 진행)
            if (try self.dispatchVisitor(.on_object_expression, idx)) |replacement| return replacement;
            if (self.options.unsupported.object_spread) {
                if (es2018.ES2018(Transformer).hasSpreadProperty(self, node)) {
                    return es2018.ES2018(Transformer).lowerObjectSpread(self, node);
                }
            }
            // method shorthand → { key: function() {} } 를 먼저 처리.
            // function_expression 내부 async/generator lowering까지 visitNode 경로로 수행한 뒤,
            // computed key가 남아 있으면 아래 ES2015Computed가 후속 처리한다.
            if (es2015_object_methods.ES2015ObjectMethods(Transformer).needsObjectMethodLowering(self, node)) {
                const lowered = try es2015_object_methods.ES2015ObjectMethods(Transformer).lowerObjectMethods(self, node);
                const lowered_node = self.ast.getNode(lowered);
                if (self.options.unsupported.object_extensions) {
                    if (es2015_computed.ES2015Computed(Transformer).hasComputedProperty(self, lowered_node)) {
                        return es2015_computed.ES2015Computed(Transformer).lowerComputedProperties(self, lowered_node);
                    }
                }
                return lowered;
            }
            if (self.options.unsupported.object_extensions) {
                if (es2015_computed.ES2015Computed(Transformer).hasComputedProperty(self, node)) {
                    return es2015_computed.ES2015Computed(Transformer).lowerComputedProperties(self, node);
                }
            }
            return self.visitListNode(idx);
        },

        // JSX element/opening_element: .extra 형식 (tag, attrs, children)
        .jsx_element => {
            // `<ClassNames>{({css}) => ...}</ClassNames>` 진입 시 destructured `css`
            // 의 local 이름을 scope frame 에 push — render-prop 함수 안의
            // tagged_template_expression 이 visit 될 때 인식되도록.
            const pushed_emotion_scope = try emotion_mod.maybeEnterClassNamesScope(self, node);
            defer if (pushed_emotion_scope) emotion_mod.exitClassNamesScope(self);

            if (self.options.shouldLowerJsx()) {
                return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXElement(self, node);
            }
            return self.visitJSXElement(node);
        },
        .jsx_opening_element => self.visitJSXOpeningElement(node),

        // === 단항 노드: 자식 1개 재귀 방문 ===
        .expression_statement => {
            // emotion `injectGlobal\`...\`;` 같은 expression-statement form 에 sourceMap
            // 적용. autoLabel 은 var 이름이 없어 미적용 — sourceMap 만 부여.
            if (self.options.emotion and self.options.emotion_source_map) {
                const new_idx = try self.visitUnaryNode(idx);
                return emotion_mod.maybeTransformExpressionStatement(self, new_idx);
            }
            return self.visitUnaryNode(idx);
        },
        .return_statement,
        .throw_statement,
        .spread_element,
        => self.visitUnaryNode(idx),
        .parenthesized_expression => {
            // (expr as T) → expr: TS expression이면 괄호 불필요
            const inner = node.data.unary.operand;
            if (!inner.isNone()) {
                const inner_tag = self.ast.getNode(inner).tag;
                if (inner_tag == .ts_as_expression or
                    inner_tag == .ts_satisfies_expression or
                    inner_tag == .ts_non_null_expression or
                    inner_tag == .ts_type_assertion or
                    inner_tag == .flow_as_expression or
                    inner_tag == .flow_type_cast_expression)
                {
                    return self.visitNode(inner);
                }
            }
            return self.visitUnaryNode(idx);
        },
        .await_expression => {
            if (self.options.unsupported.async_await) {
                return es2017_mod.ES2017(Transformer).lowerAwaitExpression(self, node);
            }
            return self.visitUnaryNode(idx);
        },
        .yield_expression,
        .rest_element,
        .decorator,
        => self.visitUnaryNode(idx),
        // JSX
        .jsx_spread_attribute,
        .jsx_expression_container,
        => {
            if (self.options.jsx_transform) {
                return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXExpressionContainer(self, node);
            }
            return self.visitUnaryNode(idx);
        },
        .jsx_spread_child,
        .chain_expression,
        .computed_property_key,
        .break_statement,
        .continue_statement,
        .static_block,
        => self.visitUnaryNode(idx),

        // === 이항 노드: 자식 2개 재귀 방문 ===
        .binary_expression,
        .logical_expression,
        => {
            // ES 다운레벨링: ** → Math.pow (target < es2016)
            if (self.options.unsupported.exponentiation and node.tag == .binary_expression) {
                const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                if (op == .star2) {
                    return es2016.ES2016(Transformer).lowerExponentiation(self, node);
                }
            }
            // ES 다운레벨링: ?? → ternary
            if (self.options.unsupported.nullish_coalescing and node.tag == .logical_expression) {
                const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                if (op == .question2) {
                    return es2020.ES2020(Transformer).lowerNullishCoalescing(self, node);
                }
            }
            // ES2022 Ergonomic Brand Checks: #x in obj → _x.has(obj) 등
            // private mapping이 설정돼 있을 때만 변환 (class 다운레벨 경로가 활성화된 경우).
            if (node.tag == .binary_expression and
                (self.current_private_fields.len > 0 or self.current_private_methods.len > 0))
            {
                const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                if (op == .kw_in) {
                    if (es2015_class.ES2015Class(Transformer).lowerPrivateIn(self, node)) |result| {
                        return result;
                    }
                }
            }
            return self.visitBinaryNode(idx);
        },
        .assignment_expression => {
            // ES2015: super.x = v / super.x += v / super.x ||= v 는
            // Parent.prototype.x 직접 접근이 아니라 receiver(this)를 보존하는 get/set
            // 헬퍼로 먼저 lowering한다. 이후 generic logical/compound lowering으로 넘기면
            // helper call에 대입하는 잘못된 target이 생성된다.
            if (self.needsSuperLowering()) {
                if (es2015_class.ES2015Class(Transformer).lowerSuperPropertyAssignment(self, node)) |result| {
                    return result;
                }
            }
            // Private field 좌변은 모든 assignment 연산자(=, +=, ??=, ||=, &&= ...)를
            // lowerPrivateFieldSet 단일 경로에서 처리 — es2021/es2016 등은 좌변에
            // `(a = b)` 패턴을 만들어 get()/helper call에 대입하게 되므로 먼저 가로챈다.
            // (esbuild의 lowerAssign이나 SWC/Babel plugin 순서와 동일한 선점 패턴.)
            if (self.hasActivePrivateFieldLowering()) {
                const left_idx = node.data.binary.left;
                if (!left_idx.isNone()) {
                    const left_node = self.ast.getNode(left_idx);
                    if (left_node.tag == .private_field_expression) {
                        if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldSet(self, node)) |result| {
                            return result;
                        }
                    }
                }
            }
            // ES 다운레벨링: **= → a = Math.pow(a, b) (es2016)
            if (self.options.unsupported.exponentiation) {
                const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                if (op == .star2_eq) {
                    return es2016.ES2016(Transformer).lowerExponentiationAssignment(self, node);
                }
            }
            // ES 다운레벨링: ??=, ||=, &&= (es2021)
            if (self.options.unsupported.logical_assignment) {
                const op: token_mod.Kind = @enumFromInt(node.data.binary.flags);
                if (op == .question2_eq) {
                    return es2021.ES2021(Transformer).lowerNullishAssignment(self, node);
                } else if (op == .pipe2_eq) {
                    return es2021.ES2021(Transformer).lowerLogicalAssignment(self, node, .pipe2);
                } else if (op == .amp2_eq) {
                    return es2021.ES2021(Transformer).lowerLogicalAssignment(self, node, .amp2);
                }
            }
            // ES2015: assignment destructuring → sequence expression.
            // destructuring 자체가 지원되더라도 target에 private field가 있으면 강제 lowering —
            // 일반 visit 경로가 `this.#x` 를 `_x.get(this)` 로 만들어 invalid assignment target이 됨 (#1485).
            {
                const left_idx = node.data.binary.left;
                if (!left_idx.isNone()) {
                    const left_node = self.ast.getNode(left_idx);
                    if (left_node.tag == .object_assignment_target or left_node.tag == .array_assignment_target) {
                        const has_private = self.current_private_fields.len > 0 and
                            es2015_class.ES2015Class(Transformer).destructuringTargetHasPrivateField(self, left_idx);
                        if (self.options.unsupported.destructuring or has_private) {
                            return es2015_destructuring.ES2015Destructuring(Transformer).lowerDestructuringAssignment(self, node);
                        }
                    }
                }
            }
            // styled-components: `Component = styled.div\`...\`` 도 wrap 대상.
            // visitBinaryNode 결과의 right 가 styled tagged template 이면 LHS identifier
            // 이름을 displayName 으로 사용해 wrap. =, +=, ||= 등 모든 연산자에서 동작
            // (의미상 = 만 styled component 할당이지만 가드 추가 비용 vs 자연스러운 케이스
            // 커버 trade-off — 비-= 연산자 + tagged template 조합은 거의 없음).
            if (self.options.styled_components and self.plugins.styled_components.default_binding != null) {
                const new_idx = try self.visitBinaryNode(idx);
                return styled_components_mod.maybeWrapAssignment(self, new_idx);
            }
            return self.visitBinaryNode(idx);
        },
        .while_statement,
        .do_while_statement,
        .with_statement,
        // JSX
        .jsx_attribute,
        .jsx_namespaced_name,
        .jsx_member_expression,
        // ES2024: import(x, opts) — binary { left=arg, right=options }
        .import_expression,
        => self.visitBinaryNode(idx),

        // === member expression: extra = [object, property, flags] ===
        .static_member_expression => {
            // ES 다운레벨링: ?. → ternary (target < es2020)
            if (self.options.unsupported.optional_chaining) {
                if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                    return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                }
            }
            // ES2015: super.method → Parent.prototype.method
            if (self.needsSuperLowering()) {
                if (es2015_class.ES2015Class(Transformer).isSuperMember(self, node)) {
                    return es2015_class.ES2015Class(Transformer).lowerSuperMember(self, node);
                }
            }
            return self.visitMemberExpression(node);
        },
        .private_field_expression => {
            // 순서 중요: `?.` 를 먼저 ternary 로 풀어야 한다. 아래의 lowerPrivateMethodGet /
            // lowerPrivateFieldGet 이 만든 `_x.get(this)` 호출이 `?.` short-circuit 안에 들어가면
            // base 가 null/undefined 일 때도 evaluate 되어 spec 위반이다.
            // class_private_field 가 lowering 대상이면 target 이 ES2020+ 라도 chain 자체를
            // 미리 풀어야 같은 회피가 가능 — `unsupported.optional_chaining` 만으로는 부족.
            if (self.options.unsupported.optional_chaining or self.hasActivePrivateFieldLowering()) {
                if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                    return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                }
            }
            // ES2022: this.#method → _method_fn.bind(this) (참조만, 호출 아닌 경우)
            if (self.current_private_methods.len > 0) {
                if (es2022.ES2022(Transformer).lowerPrivateMethodGet(self, node)) |result| {
                    return result;
                }
            }
            // ES2015/ES2022: this.#x → _x.get(this)
            if (self.hasActivePrivateFieldLowering()) {
                if (es2015_class.ES2015Class(Transformer).lowerPrivateFieldGet(self, node)) |result| {
                    return result;
                }
            }
            return self.visitMemberExpression(node);
        },
        .computed_member_expression => {
            // ES 다운레벨링: ?. → ternary (target < es2020)
            if (self.options.unsupported.optional_chaining) {
                if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                    return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                }
            }
            // ES2015: super["prop"] → Parent.prototype["prop"]
            if (self.needsSuperLowering()) {
                if (es2015_class.ES2015Class(Transformer).isSuperComputedMember(self, node)) {
                    return es2015_class.ES2015Class(Transformer).lowerSuperComputedMember(self, node);
                }
            }
            return self.visitMemberExpression(node);
        },

        // === unary/update expression: extra = [operand, operator_and_flags] ===
        .unary_expression,
        .update_expression,
        => self.visitUnaryExtra(node),

        // === 삼항 노드: 자식 3개 재귀 방문 ===
        .if_statement, .conditional_expression, .for_in_statement => {
            if (node.tag == .for_in_statement and self.current_private_fields.len > 0) {
                if (try self.tryLowerForInOfPrivateTarget(node)) |result| return result;
            }
            if (self.options.unsupported.destructuring) {
                // for (var [i,j,k] in obj) → for (var _ref in obj) { var i=_ref[0],...; body }
                const left = node.data.ternary.a;
                if (!left.isNone()) {
                    const left_node = self.ast.getNode(left);
                    if (left_node.tag == .variable_declaration and
                        es2015_destructuring.ES2015Destructuring(Transformer).hasDestructuring(self, left_node))
                    {
                        return es2015_destructuring.ES2015Destructuring(Transformer).lowerForInDestructuring(self, node);
                    }
                }
            }
            return self.visitForInOfTernary(node);
        },
        .try_statement,
        => self.visitTernaryNode(node),
        .for_await_of_statement => {
            // for-await 키워드는 ES2018. ES2018 미만 타겟에서는 async function 자체를
            // 보존하더라도 for-await 구문만 __asyncValues + while 로 제거해야 한다.
            if (self.options.unsupported.needsForAwaitOfDownlevel()) {
                return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOf(self, node);
            }
            return self.visitForInOfTernary(node);
        },
        .for_of_statement => {
            // private field target은 그대로 두면 `for (_x.get(this) of arr)` → invalid.
            // 임시 binding + body prefix assignment 패턴으로 변환 (#1491).
            if (self.current_private_fields.len > 0) {
                if (try self.tryLowerForInOfPrivateTarget(node)) |result| return result;
            }
            if (self.options.unsupported.for_of) {
                return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatement(self, node);
            }
            return self.visitForInOfTernary(node);
        },
        .labeled_statement => {
            // for-of/for-await-of를 block으로 lowering할 때, label이 block에 남으면
            // 바디의 `continue LABEL` 이 iteration statement를 못 찾는다.
            // label을 lowered inner while/for_statement에 직접 부여해 이를 회피.
            const child_idx = node.data.binary.right;
            if (!child_idx.isNone()) {
                const child = self.ast.getNode(child_idx);
                if (self.options.unsupported.needsForAwaitOfDownlevel() and child.tag == .for_await_of_statement) {
                    const new_label = try self.visitNode(node.data.binary.left);
                    return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOfLabeled(self, child, new_label);
                }
                if (self.options.unsupported.for_of and child.tag == .for_of_statement) {
                    const new_label = try self.visitNode(node.data.binary.left);
                    return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatementLabeled(self, child, new_label);
                }
            }
            return self.visitBinaryNode(idx);
        },

        // === extra 기반 노드: 별도 처리 ===
        .variable_declaration => self.visitVariableDeclaration(node),
        .variable_declarator => self.visitVariableDeclarator(node),
        .function_declaration,
        .function_expression,
        => {
            const e = node.data.extra;
            const flags = self.readU32(e, ast_mod.FunctionExtra.flags);
            if (self.options.unsupported.async_await and (flags & ast_mod.FunctionFlags.is_async) != 0) {
                // async generator (`async function*`) → __asyncGenerator wrapper. (#1911)
                if ((flags & ast_mod.FunctionFlags.is_generator) != 0) {
                    return es2017_mod.ES2017(Transformer).lowerAsyncGeneratorToStateMachine(self, node);
                }
                // async + generator 둘 다 unsupported → 직접 state machine 생성
                if (self.options.unsupported.generator) {
                    return es2017_mod.ES2017(Transformer).lowerAsyncToStateMachine(self, node);
                }
                return es2017_mod.ES2017(Transformer).lowerAsyncFunction(self, node);
            }
            if (self.options.unsupported.generator and (flags & ast_mod.FunctionFlags.is_generator) != 0) {
                return es2015_generator.ES2015Generator(Transformer).lowerGeneratorFunction(self, node);
            }
            return self.visitFunction(node);
        },
        .function,
        => self.visitFunction(node),
        .arrow_function_expression => {
            if (self.options.unsupported.async_await) {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 < extras.len and (extras[e + 2] & ast_mod.ArrowFlags.is_async) != 0) {
                    // async + generator 둘 다 unsupported → 직접 state machine 생성
                    if (self.options.unsupported.generator) {
                        return es2017_mod.ES2017(Transformer).lowerAsyncArrowToStateMachine(self, node);
                    }
                    return es2017_mod.ES2017(Transformer).lowerAsyncArrow(self, node);
                }
            }
            if (self.options.unsupported.arrow) {
                return es2015_arrow.ES2015Arrow(Transformer).lowerArrowFunction(self, node);
            }
            return self.visitArrowFunction(node);
        },
        .class_declaration => {
            const replacement_idx = try self.dispatchVisitor(.on_class_declaration, idx);
            const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
            // Stage 3 decorator는 unsupported.class 분기보다 먼저 돌려야 한다 — 반대면 decorator가 silent drop.
            // 이름 있는 class_declaration은 Stage 3 내부에서 outer_var_decl을 pending_nodes로 hoist하고
            // `.none`을 반환하므로, export_named/default declaration이 이름을 감지해 `export { X };` 또는
            // `export default X;` 형태로 분리한다 (#1538). 익명/class_expression은 iife_call을 직접 반환해
            // 아래 visitNode 재방문이 arrow/let/static block을 ES5로 마저 다운레벨링한다.
            if (try self.tryTransformStage3(target_node)) |stage3_result| {
                if (self.options.unsupported.class) return self.visitNode(stage3_result);
                return stage3_result;
            }
            if (self.options.unsupported.class) {
                return es2015_class.ES2015Class(Transformer).lowerClassDeclaration(self, target_node);
            }
            if (replacement_idx) |r| return r;
            return self.visitClass(node);
        },
        .class_expression => {
            const replacement_idx = try self.dispatchVisitor(.on_class_expression, idx);
            const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
            if (try self.tryTransformStage3(target_node)) |stage3_result| {
                if (self.options.unsupported.class) return self.visitNode(stage3_result);
                return stage3_result;
            }
            if (self.options.unsupported.class) {
                return es2015_class.ES2015Class(Transformer).lowerClassExpression(self, target_node);
            }
            if (replacement_idx) |r| return r;
            return self.visitClass(node);
        },
        .for_statement => self.visitForStatement(node),
        .switch_statement => self.visitSwitchStatement(node),
        .switch_case => self.visitSwitchCase(node),
        .call_expression => {
            // ES2022: this.#method(args) → _method_fn.call(this, args)
            if (self.current_private_methods.len > 0) {
                if (es2022.ES2022(Transformer).lowerPrivateMethodCall(self, node)) |result| {
                    return result;
                }
            }
            // ES 다운레벨링: ?.() → ternary (target < es2020)
            if (self.options.unsupported.optional_chaining) {
                if (es2020.ES2020(Transformer).findOptionalChainBase(self, node)) |base_idx| {
                    return es2020.ES2020(Transformer).lowerOptionalChain(self, node, base_idx);
                }
            }
            // ES2015: super(args) → Parent.call(this, args)
            // ES2015: super.method(args) → Parent.prototype.method.call(this, args)
            if (self.needsSuperLowering()) {
                if (es2015_class.ES2015Class(Transformer).isSuperCall(self, node)) {
                    return es2015_class.ES2015Class(Transformer).lowerSuperCall(self, node);
                }
                if (es2015_class.ES2015Class(Transformer).isSuperMethodCall(self, node)) {
                    return es2015_class.ES2015Class(Transformer).lowerSuperMethodCall(self, node);
                }
                if (es2015_class.ES2015Class(Transformer).isSuperComputedMethodCall(self, node)) {
                    return es2015_class.ES2015Class(Transformer).lowerSuperComputedMethodCall(self, node);
                }
            }
            // Plugin visitor 훅 — web-check 치환 등
            if (try self.dispatchVisitor(.on_call_expression, idx)) |replacement| return replacement;
            // ES2015: spread in call → .apply()
            if (self.options.unsupported.spread) {
                if (es2015_spread.ES2015Spread(Transformer).hasSpreadArg(self, node)) {
                    return es2015_spread.ES2015Spread(Transformer).lowerSpreadCall(self, node);
                }
            }
            return self.visitCallExpression(node);
        },
        .new_expression => {
            if (self.options.unsupported.spread) {
                if (es2015_spread.ES2015Spread(Transformer).hasSpreadArg(self, node)) {
                    return es2015_spread.ES2015Spread(Transformer).lowerSpreadNew(self, node);
                }
            }
            return self.visitNewExpression(node);
        },
        .tagged_template_expression => self.visitTaggedTemplate(node),
        .method_definition => self.visitMethodDefinition(node),
        .property_definition => self.visitPropertyDefinition(node),
        .object_property => self.visitObjectProperty(node),
        .formal_parameter => self.visitFormalParameter(node),
        .import_declaration => self.visitImportDeclaration(node),
        .export_named_declaration => self.visitExportNamedDeclaration(node),
        .export_default_declaration => self.visitExportDefaultDeclaration(node),
        .export_all_declaration => self.visitExportAllDeclaration(node),
        .catch_clause => {
            if (self.options.unsupported.optional_catch_binding) {
                return es2019.ES2019(Transformer).lowerOptionalCatchBinding(self, node);
            }
            return self.visitBinaryNode(idx);
        },
        .binding_property,
        .assignment_pattern,
        => self.visitBinaryNode(idx),
        .accessor_property => self.visitAccessorProperty(node),

        // === 리프 노드: 그대로 복사 (자식 없음) ===
        // this_expression: static block 안에서 클래스 이름으로 치환 가능
        .this_expression => {
            // ES2022 static block 다운레벨링 중이고, 일반 함수 안이 아니면 치환
            if (self.static_block_class_name) |class_span| {
                if (self.this_depth == 0) {
                    return self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = class_span,
                        .data = .{ .string_ref = class_span },
                    });
                }
            }
            // ES2015 arrow this 캡처: arrow body 안의 this → _this
            if (self.options.unsupported.arrow and self.arrow_this_depth > 0) {
                self.needs_this_var = true;
                return es_helpers.makeIdentifierRef(self, "_this");
            }
            // ES2015 class super() 후 this → _this
            if (self.super_call_this_alias) {
                const helper = try es_helpers.makeRuntimeHelperRef(self, "__assertThisInitialized");
                const this_ref = try es_helpers.makeIdentifierRef(self, "_this");
                self.runtime_helpers.derived_constructor = true;
                return es_helpers.makeCallExpr(self, helper, &.{this_ref}, node.span);
            }
            return self.copyNodeDirect(idx);
        },

        // meta_property: new.target / import.meta
        .meta_property => {
            // new.target (data.none == 1) 다운레벨링
            if (node.data.none == 1 and self.options.unsupported.new_target) {
                return self.lowerNewTarget(node.span);
            }
            return self.copyNodeDirect(idx);
        },

        .boolean_literal,
        .null_literal,
        .numeric_literal,
        .bigint_literal,
        => self.copyNodeDirect(idx),
        .string_literal => blk: {
            if (!self.options.unsupported.unicode_brace_escape) break :blk self.copyNodeDirect(idx);
            const raw = self.ast.getText(node.span);
            // raw는 따옴표를 포함. content 만 변환 후 다시 조립.
            if (raw.len < 2) break :blk self.copyNodeDirect(idx);
            const quote = raw[0];
            if (quote != '"' and quote != '\'') break :blk self.copyNodeDirect(idx);
            const content = raw[1 .. raw.len - 1];
            const lowered = (try unicode_escape_lower.lowerContent(self.allocator, content)) orelse break :blk self.copyNodeDirect(idx);
            defer self.allocator.free(lowered);
            const new_raw = try std.fmt.allocPrint(self.allocator, "{c}{s}{c}", .{ quote, lowered, quote });
            defer self.allocator.free(new_raw);
            const new_span = try self.ast.addString(new_raw);
            break :blk try self.ast.addNode(.{
                .tag = .string_literal,
                .span = new_span,
                .data = .{ .string_ref = new_span },
            });
        },
        .regexp_literal => blk: {
            const u = self.options.unsupported;
            if (!(u.regex_dotall or u.regex_named_groups or u.regex_sticky or u.unicode_brace_escape)) {
                break :blk self.copyNodeDirect(idx);
            }
            const raw = self.ast.getText(node.span);
            const result = try regex_lower.lower(self.allocator, raw, .{ .unsupported = u });
            defer if (result.named_groups) |ng| self.allocator.free(ng);
            const new_text = result.text orelse break :blk self.copyNodeDirect(idx);
            defer self.allocator.free(new_text);

            const new_span = try self.ast.addString(new_text);
            const new_regex = try self.ast.addNode(.{
                .tag = .regexp_literal,
                .span = new_span,
                .data = .{ .string_ref = new_span },
            });

            // named capture group 이 있고 strip 됐으면 `__wrapRegExp(/.../, {n:1,...})` 로 wrap
            // — exec().groups.NAME / replace(re, "$<NAME>") semantic 보존. graph 가 helper
            // module (`runtime_helper_modules.zig` 의 wrap-regex) 을 import 해서 chunk
            // 분배까지 자동 처리.
            if (result.named_groups) |ng| {
                self.runtime_helpers.wrap_regex = true;

                // {name1: 1, name2: 2, ...} object literal 합성. property key 는 quoted
                // string literal (`"name"`) — reserved word/하이픈 등 고려 않게 일관 처리.
                // identifier 는 실무상 짧으므로 256 byte 스택 버퍼로 heap alloc 회피.
                const props_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(props_top);
                for (ng) |entry| {
                    var stack_buf: [256]u8 = undefined;
                    const need_heap = entry.name.len + 2 > stack_buf.len;
                    const quoted = if (need_heap)
                        try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{entry.name})
                    else
                        std.fmt.bufPrint(&stack_buf, "\"{s}\"", .{entry.name}) catch unreachable;
                    defer if (need_heap) self.allocator.free(quoted);
                    const key_span = try self.ast.addString(quoted);
                    const key_node = try self.ast.addNode(.{
                        .tag = .string_literal,
                        .span = key_span,
                        .data = .{ .string_ref = key_span },
                    });
                    const val_node = try es_helpers.makeNumericLiteral(self, entry.index);
                    const prop_node = try self.ast.addNode(.{
                        .tag = .object_property,
                        .span = node.span,
                        .data = .{ .binary = .{ .left = key_node, .right = val_node, .flags = 0 } },
                    });
                    try self.scratch.append(self.allocator, prop_node);
                }
                const props_list = try self.ast.addNodeList(self.scratch.items[props_top..]);
                const groups_obj = try self.ast.addNode(.{
                    .tag = .object_expression,
                    .span = node.span,
                    .data = .{ .list = props_list },
                });

                const wrap_ref = try es_helpers.makeRuntimeHelperRef(self, "__wrapRegExp");
                break :blk try es_helpers.makeCallExpr(self, wrap_ref, &.{ new_regex, groups_obj }, node.span);
            }

            break :blk new_regex;
        },
        .identifier_reference => {
            // ES2015 arrow arguments 캡처: arrow body 안의 arguments → _arguments
            if (self.options.unsupported.arrow and self.arrow_this_depth > 0) {
                const text = self.ast.getText(node.data.string_ref);
                if (std.mem.eql(u8, text, "arguments")) {
                    self.needs_arguments_var = true;
                    const args_span = try self.ast.addString("_arguments");
                    const new_idx = try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = args_span,
                        .data = .{ .string_ref = args_span },
                    });
                    self.propagateSymbolId(idx, new_idx);
                    return new_idx;
                }
            }
            if (try self.tryRenameIdentifierLike(idx, .identifier_reference)) |i| return i;
            return self.copyNodeDirect(idx);
        },
        .binding_identifier => {
            if (try self.tryRenameIdentifierLike(idx, .binding_identifier)) |i| return i;
            return self.copyNodeDirect(idx);
        },
        .assignment_target_identifier => {
            if (try self.tryRenameIdentifierLike(idx, .assignment_target_identifier)) |i| return i;
            return self.copyNodeDirect(idx);
        },
        .template_element => blk: {
            if (!self.options.unsupported.unicode_brace_escape) break :blk self.copyNodeDirect(idx);
            const raw = self.ast.getText(node.span);
            const lowered = (try unicode_escape_lower.lowerContent(self.allocator, raw)) orelse break :blk self.copyNodeDirect(idx);
            defer self.allocator.free(lowered);
            const new_span = try self.ast.addString(lowered);
            break :blk try self.ast.addNode(.{
                .tag = .template_element,
                .span = new_span,
                .data = node.data,
            });
        },
        .private_identifier,
        .empty_statement,
        .debugger_statement,
        .directive,
        .hashbang,
        .super_expression,
        .elision,
        .jsx_empty_expression,
        .jsx_identifier,
        .jsx_closing_element,
        .jsx_opening_fragment,
        .jsx_closing_fragment,
        => self.copyNodeDirect(idx),

        // JSX leaf — jsx_text는 별도 처리 (jsx_transform 시 lowerJSXText)
        .jsx_text => {
            if (self.options.jsx_transform) {
                return jsx_lowering_mod.JsxLowering(Transformer).lowerJSXText(self, node);
            }
            return self.copyNodeDirect(idx);
        },

        // === import/export specifiers ===
        // #1791 Phase D: inline `type` modifier (SPEC_FLAG_TYPE_ONLY) 또는 named specifier 의
        // value-ref 0 (type 위치에서만 사용) 이면 elide. visitExtraList 가 `.none` 을
        // 필터링. default/namespace 는 JSX pragma 등 implicit value use 위험이 커
        // `shouldElideImportSpecifier` 에서 이미 false 를 반환하므로 elision 비활성.
        .import_specifier => blk: {
            if ((node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) break :blk NodeIndex.none;
            if (self.shouldElideImportSpecifier(idx, node)) break :blk NodeIndex.none;
            break :blk self.visitBinaryNode(idx);
        },
        .export_specifier => if ((node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) .none else self.visitBinaryNode(idx),
        // default/namespace specifier는 string_ref(span) 복사 — 자식 노드 없음
        .import_default_specifier,
        .import_namespace_specifier,
        .import_attribute,
        => self.copyNodeDirect(idx),

        // === Pattern 노드: 자식 재귀 방문 ===
        .array_pattern,
        .object_pattern,
        .array_assignment_target,
        .object_assignment_target,
        => self.visitListNode(idx),

        .binding_rest_element,
        .assignment_target_rest,
        => self.visitUnaryNode(idx),
        .assignment_target_with_default,
        .assignment_target_property_identifier,
        .assignment_target_property_property,
        => self.visitBinaryNode(idx),
        // assignment_target_identifier: string_ref → 변환 불필요 (identifier와 동일)

        // === TS enum/namespace: 런타임 코드 생성 (codegen에서 IIFE 출력) ===
        .ts_enum_declaration => self.visitEnumDeclaration(node),
        .ts_enum_member => self.visitBinaryNode(idx),
        .ts_enum_body => self.visitListNode(idx),
        // === Flow enum (#2401): codegen 에서 Object.freeze({...}) 출력. members 의
        // init expression 만 visit 필요 (다른 변환 영향 없음).
        .flow_enum_declaration => self.visitFlowEnumDeclaration(node),
        .flow_enum_member => self.visitBinaryNode(idx),
        .ts_module_declaration => self.visitNamespaceDeclaration(node),
        .ts_module_block => self.visitListNode(idx),

        // import x = require('y') → const x = require('y')
        .ts_import_equals_declaration => self.visitImportEqualsDeclaration(node),

        // export = expr → module.exports = expr;
        .ts_export_assignment => self.visitExportAssignment(node),

        // === 나머지: invalid + TS 타입 전용 노드 ===
        // TS 타입 노드는 isTypeOnlyNode 검사(위)에서 이미 .none으로 반환됨.
        // 여기 도달하면 strip_types=false인 경우 → 그대로 복사.
        .invalid => .none,
        else => self.copyNodeDirect(idx),
    };
}
