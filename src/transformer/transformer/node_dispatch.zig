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
const object_super = @import("../object_super.zig");
const es2025_using = @import("../es2025_using.zig");
const es2015_spread = @import("../es2015_spread.zig");
const es2015_arrow = @import("../es2015_arrow.zig");
const es2015_for_of = @import("../es2015_for_of.zig");
const es2018_for_await = @import("../es2018_for_await.zig");
const es2015_destructuring = @import("../es2015_destructuring.zig");
const es2015_class = @import("../es2015_class.zig");
const es2015_generator = @import("../es2015_generator.zig");
const regex_lower = @import("../regex_lower.zig");
const group_name = @import("../../regexp/group_name.zig");
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
    // TS/Flow type wrapper: 타입 부분만 제거, 값 보존 (#3129 단일 source).
    if (ast_mod.Node.Tag.isTransparentTypeWrapper(node.tag)) return self.visitTsExpression(idx);

    return switch (node.tag) {
        .flow_match_expression => self.visitFlowMatch(node),

        // Flow component with ref → function Name_withRef + const Name = React.forwardRef(...)
        .flow_component_wrapper => self.visitFlowComponentWrapper(node),

        // === 리스트 노드: 자식을 하나씩 방문하며 복사 ===
        .program => {
            // Plugin visitor 훅 선취권 (file-level worklet directive 등)
            if (try self.dispatchVisitor(.on_program, idx)) |replacement| return replacement;
            // ES2022 top-level await 다운레벨링: 미지원 타겟에서 async IIFE 로 wrap (#1384).
            // wrap 결과도 `.program` 노드라 아래 css_prop hoist 가 동일 적용돼야 한다 — 과거엔
            // 여기서 early-return 해 TLA+styled-components(css-prop) 동시 사용 시 추출된
            // module-level decl 이 hoist 되지 않고 소실됐다.
            const result = blk: {
                if (self.options.unsupported.top_level_await and !self.options.tla_chunk_wrapped) {
                    if (try es2022_tla.lowerProgram(Transformer, self, node)) |wrapped| break :blk wrapped;
                }
                break :blk try self.visitListNode(idx);
            };
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
            // raw-span shorthand (#2957): transformer(emotion/styled) 가 만든 list.len==0
            // template 만 리프로 복사. parser-created template 은 quasi 가 최소 1개라
            // 항상 list.len>0 이므로 children 을 visit 한다. (과거 `data.none == 0` 은
            // data.list.start 와 alias 라, 치환 template 이 extra_data[0] 에서 시작하면
            // start==0 → 리프 오판 → expression 의 transform-pass 변환(ES 다운레벨 등)이
            // 통째로 누락됐다. codegen emitTemplateLiteral 과 동일한 list.len 기준으로 통일.)
            if (node.data.list.len == 0) return self.copyNodeDirect(idx);
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
            // V7 fix: 이전 F7 가 object_expression 진입 시 super context 5종을 일괄 reset 했으나,
            // 그러면 object 의 property VALUE 위치 (`{ y: super.foo() }`) 의 super 도 reset 되어
            // outer class 의 super lowering 이 비활성화됨 → ES5 등 class-lowering 타깃에서 raw super
            // leak. spec: object literal METHOD body 만 home object [[Prototype]]=Object.prototype
            // 으로 super 가 다르고, VALUE position 의 super 는 enclosing class 의 super 그대로.
            // 따라서 reset 은 method 진입 시점 (visitMethodDefinition) 으로 좁히고, 여기서는
            // depth 만 증감해 method 가 자신이 object literal 의 일부인지 알 수 있게 한다.
            self.in_object_literal_depth += 1;
            defer self.in_object_literal_depth -= 1;

            // Plugin visitor 훅 — 기본 방문 전 선취권 (null 반환 시 default 진행)
            if (try self.dispatchVisitor(.on_object_expression, idx)) |replacement| return replacement;

            // 객체 리터럴 메서드의 `super` 가 낮춰져야 하면 객체를 home 임시 변수에 담는다 (#4729).
            const home_mark = self.object_super_homes.items.len;
            defer object_super.release(self, home_mark);
            const home = try object_super.prepareHome(self, node);
            const lowered = try visitObjectExpressionLowering(self, idx, node);
            if (home) |h| return object_super.wrapWithHome(self, h, lowered, node.span);
            return lowered;
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
            // (expr as T) → expr: 타입 래퍼는 noop 이라 보통 괄호가 불필요.
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
                    // 단, 타입 래퍼 안쪽 operand 가 load-bearing 이면 괄호를 떼면 의미가 바뀐다:
                    //   - optional chain: `(a?.b as T).c` 는 `(a?.b).c`(nullish 면 throw) ≠ `a?.b.c`
                    //   - numeric: `(42 as T).x` 는 `(42).x` — `42.x` 는 float 오파싱 invalid
                    //   - statement-start: `({x:1} as T).c` 는 `({x:1}).c` — `{x:1}.c` 는 블록 오파싱
                    //   - arrow 등 저우선순위 callee: `(()=>{} as T)()` 등
                    // castOperandNeedsParen 이 true 면 괄호 유지(visitUnaryNode 가 `(`+visitNode(inner)+`)`,
                    // visitNode 가 래퍼를 벗겨 `(a?.b)`/`(42)` 산출). 안전한 primary/postfix 면 제거(최소).
                    if (es_helpers.castOperandNeedsParen(self.ast, inner)) {
                        return self.visitUnaryNode(idx);
                    }
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
            // `shouldLowerJsx()` = jsx_transform && runtime != .preserve (#4470).
            // 예전엔 `jsx_transform` 만 봐서, preserve 모드인데도 container/text 만
            // lowering 됐다 → jsx_element 는 남아 있는데 그 자식은 string_literal /
            // bare expression 으로 바뀌어 `<div>{x}</div>` 가 `<div>"..."x</div>` 로
            // 나가는 깨진 JSX 가 됐다. element/fragment 와 같은 게이트를 쓴다.
            if (self.options.shouldLowerJsx()) {
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
                        const has_private = self.hasActivePrivateFieldLowering() and
                            es2015_class.ES2015Class(Transformer).destructuringTargetHasPrivateField(self, left_idx);
                        // #4251(+#4261): object rest (`({a, ...r} = o)`, ES2018) 는
                        // destructuring 지원 타겟(es2017)에서도 lowering 필요 — 게이트가
                        // destructuring(ES2015)만 보면 native 잔존(es2017 엔진 SyntaxError).
                        // object/array_assignment_target 트리에 object rest 가 중첩
                        // (`([b, {a,...r}] = o)`)되어도 검출(top-level rest 만 보면 누락).
                        const has_object_rest = self.options.unsupported.object_spread and
                            es2015_destructuring.ES2015Destructuring(Transformer).destructuringTargetHasObjectRest(self, left_idx);
                        // #4244: destructuring 이 native(es2017+)라도 super lowering 이
                        // 활성(extracted private/static method 등)이면 super member
                        // target 이 READ-lowering 돼 `[__superGet(...)]=v` Invalid LHS.
                        // super target 실재 시 lowering 강제(trySuperAssignTarget 경로).
                        const has_super = self.needsSuperLowering() and
                            es2015_class.ES2015Class(Transformer).destructuringTargetHasSuper(self, left_idx);
                        if (self.options.unsupported.destructuring or has_private or has_object_rest or has_super) {
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
        => @import("control_flow.zig").visitWhileLoop(self, idx),
        .with_statement => self.visitBinaryStatementBody(idx),

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
        .if_statement => self.visitIfStatement(node),
        .conditional_expression => self.visitTernaryNode(node),
        .for_in_statement => {
            if (node.tag == .for_in_statement and self.hasActivePrivateFieldLowering()) {
                if (try self.tryLowerForInOfPrivateTarget(node)) |result| return result;
            }
            if (try self.maybeLowerForInOfDestructuring(node)) |result| return result;
            return self.visitForInOfTernary(node);
        },
        .try_statement,
        => self.visitTernaryNode(node),
        .for_await_of_statement => {
            if (try es2025_using.ES2025Using(Transformer).normalizeForOfUsingHead(self, idx)) return self.visitNode(idx);
            // for-await 키워드는 ES2018. ES2018 미만 타겟에서는 async function 자체를
            // 보존하더라도 for-await 구문만 __asyncValues + while 로 제거해야 한다.
            if (self.options.unsupported.needsForAwaitOfDownlevel()) {
                return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOf(self, node);
            }
            return self.visitForInOfTernary(node);
        },
        .for_of_statement => {
            // `for (using x of …)` 헤더를 본문 블록의 using 으로 옮긴다 (#4730).
            if (try es2025_using.ES2025Using(Transformer).normalizeForOfUsingHead(self, idx)) return self.visitNode(idx);
            // for-of 를 낮추는 타겟: 반복자 for 루프로 풀어 쓴 뒤 방문한다. 루프 변수 대입은
            // 본문의 평범한 선언/대입이 되므로 private 필드·구조분해 좌변도 일반 경로가 처리한다.
            if (self.options.unsupported.for_of) {
                return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatement(self, idx, node);
            }
            // private field target은 그대로 두면 `for (_x.get(this) of arr)` → invalid.
            // 임시 binding + body prefix assignment 패턴으로 변환 (#1491).
            if (self.hasActivePrivateFieldLowering()) {
                if (try self.tryLowerForInOfPrivateTarget(node)) |result| return result;
            }
            // #4254: for_of 가 native(es2015~17)인데 LHS binding 이 object rest 면
            // LHS 슬롯에 destructuring expand 불가 → body-destructure 로.
            if (!self.options.unsupported.for_of) {
                if (try self.maybeLowerForInOfDestructuring(node)) |result| return result;
            }
            return self.visitForInOfTernary(node);
        },
        .labeled_statement => {
            // for-of/for-await-of를 block으로 lowering할 때, label이 block에 남으면
            // 바디의 `continue LABEL` 이 iteration statement를 못 찾는다.
            // label을 lowered inner while/for_statement에 직접 부여해 이를 회피.
            const child_idx = node.data.binary.right;
            // 이 라벨은 본문 안에서 보인다 — 추출된 루프 호출부가 점프/전달을 고를 때 쓴다 (#4722).
            if (!node.data.binary.left.isNone()) {
                try self.label_scope.append(self.allocator, try self.stableName(self.ast.getText(self.ast.getNode(node.data.binary.left).span)));
            } else try self.label_scope.append(self.allocator, "");
            defer _ = self.label_scope.pop();
            if (!child_idx.isNone()) {
                _ = try es2025_using.ES2025Using(Transformer).normalizeForOfUsingHead(self, child_idx);
                const child = self.ast.getNode(child_idx);
                if (self.options.unsupported.needsForAwaitOfDownlevel() and child.tag == .for_await_of_statement) {
                    return es2018_for_await.ES2018ForAwait(Transformer).lowerForAwaitOfLabeled(self, child, node.data.binary.left);
                }
                if (self.options.unsupported.for_of and child.tag == .for_of_statement) {
                    return es2015_for_of.ES2015ForOf(Transformer).lowerForOfStatementLabeled(self, child_idx, child, node.data.binary.left);
                }
            }
            // 루프가 `_loop` 추출로 `{ var _loop = …; for (…) {…} }` 블록이 되면 라벨이 블록에
            // 붙어 `continue L` 이 갈 곳이 없어진다(SyntaxError / 조용한 오동작). 라벨을 블록 안의
            // 그 루프로 옮긴다 — for-of 가 위에서 하는 것과 같은 처리 (#4722).
            if (!child_idx.isNone()) {
                const child_tag = self.ast.getNode(child_idx).tag;
                if (child_tag == .for_statement or child_tag == .for_in_statement or
                    child_tag == .while_statement or child_tag == .do_while_statement)
                {
                    const new_label = try self.visitNode(node.data.binary.left);
                    const new_child = try self.visitNode(child_idx);
                    if (!new_child.isNone()) {
                        if (try moveLabelOntoLoopInBlock(self, new_label, new_child, node.span)) |moved| return moved;
                    }
                    return self.ast.addNode(.{ .tag = .labeled_statement, .span = node.span, .data = .{ .binary = .{
                        .left = new_label,
                        .right = new_child,
                        .flags = node.data.binary.flags,
                    } } });
                }
            }
            return self.visitBinaryStatementBody(idx);
        },

        // === extra 기반 노드: 별도 처리 ===
        .variable_declaration => self.visitVariableDeclaration(node),
        .variable_declarator => self.visitVariableDeclarator(node),
        .function_declaration,
        .function_expression,
        => {
            const e = node.data.extra;
            const flags = self.readU32(e, ast_mod.FunctionExtra.flags);
            const is_async = (flags & ast_mod.FunctionFlags.is_async) != 0;
            const is_generator = (flags & ast_mod.FunctionFlags.is_generator) != 0;
            // async generator (`async function*`) → __asyncGenerator wrapper. (#1911)
            // 자기 비트로 게이트한다. 예전엔 이 검사가 `async_await` 안에 **중첩**돼 있어
            // async 와 generator 를 둘 다 네이티브로 갖는 es2017 이 여기 도달하지 못했고,
            // ES2018 문법인 `async function*` 이 그대로 방출됐다 (#4628). es5/es2015/es2016
            // 이 멀쩡했던 건 `async_await` 가 켜져 **우연히** 걸렸기 때문이다.
            if (is_async and is_generator and self.options.unsupported.async_generator) {
                return es2017_mod.ES2017(Transformer).lowerAsyncGeneratorToStateMachine(self, if (idx == self.synthetic_function_node) self.synthetic_function_source_owner else idx, node);
            }
            if (self.options.unsupported.async_await and is_async) {
                // async + generator 둘 다 unsupported → 직접 state machine 생성
                if (self.options.unsupported.generator) {
                    return es2017_mod.ES2017(Transformer).lowerAsyncToStateMachine(self, if (idx == self.synthetic_function_node) self.synthetic_function_source_owner else idx, node);
                }
                return es2017_mod.ES2017(Transformer).lowerAsyncFunction(self, if (idx == self.synthetic_function_node) self.synthetic_function_source_owner else idx, node);
            }
            if (self.options.unsupported.generator and is_generator) {
                return es2015_generator.ES2015Generator(Transformer).lowerGeneratorFunction(self, if (idx == self.synthetic_function_node) self.synthetic_function_source_owner else idx, node);
            }
            return self.visitFunction(node, idx);
        },
        .function,
        => self.visitFunction(node, idx),
        .arrow_function_expression => {
            if (self.options.unsupported.async_await) {
                const extras = self.ast.extra_data.items;
                const e = node.data.extra;
                if (e + 2 < extras.len and (extras[e + 2] & ast_mod.ArrowFlags.is_async) != 0) {
                    // async + generator 둘 다 unsupported → 직접 state machine 생성
                    if (self.options.unsupported.generator) {
                        return es2017_mod.ES2017(Transformer).lowerAsyncArrowToStateMachine(self, idx, node);
                    }
                    return es2017_mod.ES2017(Transformer).lowerAsyncArrow(self, idx, node);
                }
            }
            if (self.options.unsupported.arrow) {
                return es2015_arrow.ES2015Arrow(Transformer).lowerArrowFunction(self, node);
            }
            return self.visitArrowFunction(node);
        },
        .class_declaration => {
            // static 초기값·static 블록 안의 중첩 클래스는 자기 `this` 를 가진다 — 바깥 클래스 이름으로
            // 치환하지 않게 함수 경계처럼 깊이를 올린다 (#4801).
            const in_static_ctx = self.static_block_class_name != null;
            if (in_static_ctx) self.this_depth += 1;
            defer if (in_static_ctx) {
                self.this_depth -= 1;
            };
            const replacement_idx = try self.dispatchVisitor(.on_class_declaration, idx);
            const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
            // Stage 3 decorator는 unsupported.class 분기보다 먼저 돌려야 한다 — 반대면 decorator가 silent drop.
            // 이름 있는 class_declaration은 Stage 3 내부에서 outer_var_decl을 pending_nodes로 hoist하고
            // `.none`을 반환하므로, export_named/default declaration이 이름을 감지해 `export { X };` 또는
            // `export default X;` 형태로 분리한다 (#1538). 익명/class_expression은 iife_call을 직접 반환해
            // 아래 visitNode 재방문이 arrow/let/static block을 ES5로 마저 다운레벨링한다.
            if (try self.tryTransformStage3(idx, target_node)) |stage3_result| {
                if (self.options.unsupported.class) return self.visitNode(stage3_result);
                return stage3_result;
            }
            if (self.options.unsupported.class) {
                return self.lowerClassWithPrehoistedKeys(idx, target_node, es2015_class.ES2015Class(Transformer).lowerClassDeclaration);
            }
            if (replacement_idx) |r| return r;
            return self.visitClass(node);
        },
        .class_expression => {
            const in_static_ctx = self.static_block_class_name != null;
            if (in_static_ctx) self.this_depth += 1;
            defer if (in_static_ctx) {
                self.this_depth -= 1;
            };
            const replacement_idx = try self.dispatchVisitor(.on_class_expression, idx);
            const target_node = if (replacement_idx) |r| self.ast.getNode(r) else node;
            if (try self.tryTransformStage3(idx, target_node)) |stage3_result| {
                if (self.options.unsupported.class) return self.visitNode(stage3_result);
                return stage3_result;
            }
            if (self.options.unsupported.class) {
                return self.lowerClassWithPrehoistedKeys(idx, target_node, es2015_class.ES2015Class(Transformer).lowerClassExpression);
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
        .method_definition => self.visitMethodDefinition(idx, node),
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
        .binding_property => visitBindingProperty(self, idx, node),
        .assignment_pattern => self.visitBinaryNode(idx),
        .accessor_property => self.visitAccessorProperty(node),

        // === 리프 노드: 그대로 복사 (자식 없음) ===
        // this_expression: static block 안에서 클래스 이름으로 치환 가능
        .this_expression => {
            // ES2022 static block 다운레벨링 중이고, 일반 함수 안이 아니면 치환
            if (self.static_block_class_name) |class_span| {
                if (self.this_depth == 0) {
                    return self.makeCurrentClassRef(class_span);
                }
            }
            // ES2015 arrow this 캡처: arrow body 안의 this → _this
            if (self.options.unsupported.arrow and self.arrow_this_depth > 0) {
                self.needs_this_var = true;
                return es_helpers.makeSyntheticRef(self, "_this");
            }
            // ES2015 class super() 후 this → _this
            if (self.super_call_this_alias) {
                const helper = try es_helpers.makeRuntimeHelperRef(self, "__assertThisInitialized");
                const this_ref = try es_helpers.makeSyntheticRef(self, "_this");
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
            if (!u.needsRegexLowering()) {
                break :blk self.copyNodeDirect(idx);
            }
            const raw = self.ast.getText(node.span);
            const result = try regex_lower.lower(self.allocator, raw, .{ .unsupported = u });
            defer if (result.named_groups) |ng| self.allocator.free(ng);
            // #4210: 다운레벨 못해 보존된 modifier 그룹 → 진단 신호(transpile/prepass).
            if (result.kept_modifier) self.used_unsupported_modifier = true;
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

                // 그룹 이름이 문자 그대로 __proto__ 면 객체 리터럴 키는 (quoted 포함)
                // B.3.1 proto setter 라 own property 가 안 생긴다 (#4204). es2015+ 는
                // computed key 로 회피하지만 computed key 자체가 ES2015 문법이라
                // es5 (object_extensions 미지원) 는 JSON.parse('{...}') 폴백 — B.3.1
                // 은 JSON.parse 평가를 면제하므로 모든 키가 own property 로 생긴다.
                // (canonical 이름은 quote/backslash/개행 불포함 → escape 불요)
                var has_proto = false;
                for (ng) |entry| {
                    if (group_name.eqlCanonical(entry.name, "__proto__")) {
                        has_proto = true;
                        break;
                    }
                }
                if (has_proto and self.options.unsupported.object_extensions) {
                    var json: std.ArrayList(u8) = .empty;
                    defer json.deinit(self.allocator);
                    try json.appendSlice(self.allocator, "'{");
                    var first = true;
                    for (ng, 0..) |entry, ei| {
                        var seen_before = false;
                        for (ng[0..ei]) |prev| {
                            if (group_name.eqlCanonical(prev.name, entry.name)) {
                                seen_before = true;
                                break;
                            }
                        }
                        if (seen_before) continue;
                        if (!first) try json.append(self.allocator, ',');
                        first = false;
                        try json.append(self.allocator, '"');
                        try group_name.appendCanonical(self.allocator, &json, entry.name);
                        try json.appendSlice(self.allocator, "\":");
                        var count: u32 = 0;
                        for (ng[ei..]) |later| {
                            if (group_name.eqlCanonical(later.name, entry.name)) count += 1;
                        }
                        if (count > 1) try json.append(self.allocator, '[');
                        var first_idx = true;
                        for (ng[ei..]) |later| {
                            if (group_name.eqlCanonical(later.name, entry.name)) {
                                if (!first_idx) try json.append(self.allocator, ',');
                                first_idx = false;
                                try json.print(self.allocator, "{d}", .{later.index});
                            }
                        }
                        if (count > 1) try json.append(self.allocator, ']');
                    }
                    try json.appendSlice(self.allocator, "}'");
                    const json_span = try self.ast.addString(json.items);
                    const json_node = try self.ast.addNode(.{
                        .tag = .string_literal,
                        .span = json_span,
                        .data = .{ .string_ref = json_span },
                    });
                    const json_ident = try es_helpers.makeGlobalRef(self, "JSON");
                    const parse_ident = try es_helpers.makePropertyName(self, "parse");
                    const json_parse = try es_helpers.makeStaticMember(self, json_ident, parse_ident, node.span);
                    const map_call = try es_helpers.makeCallExpr(self, json_parse, &.{json_node}, node.span);
                    const wrap_ref_json = try es_helpers.makeRuntimeHelperRef(self, "__wrapRegExp");
                    break :blk try es_helpers.makeCallExpr(self, wrap_ref_json, &.{ new_regex, map_call }, node.span);
                }

                // {name1: 1, name2: 2, ...} object literal 합성. property key 는 quoted
                // string literal (`"name"`) — reserved word/하이픈 등 고려 않게 일관 처리.
                // 키는 canonical UTF-8 디코드라 ArrayList 합성 (#4201).
                const props_top = self.scratch.items.len;
                defer self.scratch.shrinkRetainingCapacity(props_top);
                // ES2025 duplicate named group 의 value 노드 수집 버퍼.
                var dup_vals: std.ArrayList(NodeIndex) = .empty;
                defer dup_vals.deinit(self.allocator);
                for (ng, 0..) |entry, ei| {
                    // ES2025 duplicate named group: 같은 이름은 첫 등장에서 array 값
                    // (`{"y": [1, 2]}`) 으로 합쳐 emit. 객체 리터럴 중복 키는 last-win
                    // 이라 첫 분기 매치 시 groups.NAME 이 undefined 가 되는 silent
                    // miscompile (#4198). 런타임 buildGroups/Symbol.replace 는 array
                    // 값을 이미 지원 (babel 동형).
                    var seen_before = false;
                    for (ng[0..ei]) |prev| {
                        // #4201: 이름 정체성 = escape 디코드된 코드포인트 시퀀스
                        // ((?<y>) ≡ (?<y>)). raw byte 비교는 escape 표기 혼용 시
                        // dedup 을 놓쳐 중복 JS 키(last-win) miscompile 재발.
                        if (group_name.eqlCanonical(prev.name, entry.name)) {
                            seen_before = true;
                            break;
                        }
                    }
                    if (seen_before) continue;
                    // 키는 canonical UTF-8 로 emit — escape 표기가 키에 남으면 JS 쪽
                    // 디코드 결과가 같은 키로 충돌할 수 있다. escape 없는 이름은
                    // byte-identical (#4201).
                    var quoted: std.ArrayList(u8) = .empty;
                    defer quoted.deinit(self.allocator);
                    try quoted.append(self.allocator, '"');
                    try group_name.appendCanonical(self.allocator, &quoted, entry.name);
                    try quoted.append(self.allocator, '"');
                    const key_span = try self.ast.addString(quoted.items);
                    const str_key = try self.ast.addNode(.{
                        .tag = .string_literal,
                        .span = key_span,
                        .data = .{ .string_ref = key_span },
                    });
                    // 그룹 이름이 문자 그대로 __proto__ 면 (합법 ES 이름) 객체 리터럴
                    // 키 `"__proto__"` 는 B.3.1 proto setter 로 동작 — own property 가
                    // 안 생기고 (array 값이면 map 의 prototype 오염) groups 전체 무효.
                    // computed key `["__proto__"]` 는 항상 own property 정의 (#4204).
                    // minify 는 computed key 를 변형 대상에서 제외하므로 보존됨.
                    // 단 computed key 자체가 ES2015 문법 — es5 등 object_extensions
                    // 미지원 타겟에선 quoted key 폴백 (합성 노드는 visit 을 안 거쳐
                    // es2015_computed lowering 미적용 — #4214 와 같은 클래스).
                    const key_node = if (!self.options.unsupported.object_extensions and
                        std.mem.eql(u8, quoted.items[1 .. quoted.items.len - 1], "__proto__"))
                        try self.ast.addNode(.{
                            .tag = .computed_property_key,
                            .span = node.span,
                            .data = .{ .unary = .{ .operand = str_key, .flags = 0 } },
                        })
                    else
                        str_key;
                    dup_vals.clearRetainingCapacity();
                    for (ng[ei..]) |later| {
                        if (group_name.eqlCanonical(later.name, entry.name)) {
                            try dup_vals.append(self.allocator, try es_helpers.makeNumericLiteral(self, later.index));
                        }
                    }
                    const val_node = if (dup_vals.items.len == 1) dup_vals.items[0] else val_blk: {
                        const vals_list = try self.ast.addNodeList(dup_vals.items);
                        break :val_blk try self.ast.addNode(.{
                            .tag = .array_expression,
                            .span = node.span,
                            .data = .{ .list = vals_list },
                        });
                    };
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
            // arguments 캡처: 본문이 **다른 함수 안으로 옮겨질 때** 필요하다.
            // arrow 다운레벨(`arrow_this_depth`)과 async/generator 다운레벨
            // (`in_extracted_fn_body`)이 같은 이유로 같은 처리를 쓴다 — 예전엔 arrow
            // 조건만 있어서 async/generator 경로에서 `arguments` 가 안쪽 함수 것을
            // 가리켰다(es2015 에서 빈 배열, es5 에선 `[object Object]`).
            if ((self.options.unsupported.arrow and self.arrow_this_depth > 0) or
                self.in_extracted_fn_body)
            {
                const text = self.ast.getText(node.data.string_ref);
                if (std.mem.eql(u8, text, "arguments")) {
                    self.needs_arguments_var = true;
                    // 원래 `arguments` 참조의 심볼을 그대로 물려준다 — 사용자가 `arguments` 라는
                    // 바인딩을 선언한 경우(sloppy 스크립트) 그 바인딩을 계속 가리키게 한다.
                    return self.makeUserRefNamed(try es_helpers.resolveSyntheticName(self, "_arguments"), idx);
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

        // JSX leaf — jsx_text는 별도 처리 (lowering 시 lowerJSXText).
        // preserve 모드에서는 원문 텍스트 노드를 그대로 둔다 (#4470).
        .jsx_text => {
            if (self.options.shouldLowerJsx()) {
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

/// `block` 이 `{ …; <loop> }` 꼴(루프 추출 결과)이면 마지막 루프에 라벨을 붙인 새 블록을 돌려준다.
fn moveLabelOntoLoopInBlock(self: *Transformer, label: NodeIndex, block_idx: NodeIndex, span: @import("../../lexer/token.zig").Span) Error!?NodeIndex {
    const block = self.ast.getNode(block_idx);
    if (block.tag != .block_statement or block.data.list.len == 0) return null;
    const last_pos = block.data.list.start + block.data.list.len - 1;
    const last_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[last_pos]);
    const last_tag = self.ast.getNode(last_idx).tag;
    if (last_tag != .for_statement and last_tag != .for_in_statement and
        last_tag != .while_statement and last_tag != .do_while_statement) return null;

    const labeled_loop = try self.ast.addNode(.{ .tag = .labeled_statement, .span = span, .data = .{ .binary = .{
        .left = label,
        .right = last_idx,
        .flags = 0,
    } } });
    var items: std.ArrayListUnmanaged(NodeIndex) = .empty;
    defer items.deinit(self.allocator);
    var i: u32 = 0;
    while (i + 1 < block.data.list.len) : (i += 1) {
        try items.append(self.allocator, @enumFromInt(self.ast.extra_data.items[block.data.list.start + i]));
    }
    try items.append(self.allocator, labeled_loop);
    const list = try self.ast.addNodeList(items.items);
    return try self.ast.addNode(.{ .tag = .block_statement, .span = block.span, .data = .{ .list = list } });
}

/// object_expression 의 문법 다운레벨링: spread(ES2018) / method shorthand / computed property(ES2015).
fn visitObjectExpressionLowering(self: *Transformer, idx: NodeIndex, node: ast_mod.Node) Error!NodeIndex {
    if (self.options.unsupported.object_spread) {
        if (es2018.ES2018(Transformer).hasSpreadProperty(self, node)) {
            return es2018.ES2018(Transformer).lowerObjectSpread(self, node);
        }
    }
    // method shorthand → { key: function() {} } 를 먼저 처리.
    // function_expression 내부 async/generator lowering까지 visitNode 경로로 수행한 뒤,
    // computed key가 남아 있으면 아래 ES2015Computed가 후속 처리한다.
    if (self.options.unsupported.needsObjectMethodDownlevel() and
        es2015_object_methods.ES2015ObjectMethods(Transformer).needsObjectMethodLowering(self, node))
    {
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
}

/// 구조분해 패턴 속성 `{ key: value }` / 축약형 `{ key }`·`{ key = d }`.
/// 계산되지 않은 키는 **속성 이름**이라 블록 스코핑 리네임을 받으면 안 된다. 축약형은 키와
/// 값이 같은 바인딩 노드라 통째로 방문하면 키까지 `key$N` 이 되어 다른 속성을 읽는다 —
/// 리네임이 걸리면 `key: key$N` 긴 형태로 푼다 (#4712: 상태 기계의 catch 파라미터·블록
/// 바인딩 리네임에서 드러남).
fn visitBindingProperty(self: *Transformer, idx: NodeIndex, node: ast_mod.Node) Error!NodeIndex {
    const key = node.data.binary.left;
    const value = node.data.binary.right;
    if (key.isNone()) return self.visitBinaryNode(idx);
    const key_node = self.ast.getNode(key);
    if (key_node.tag == .computed_property_key) return self.visitBinaryNode(idx);

    const shorthand = value == key or (!value.isNone() and blk: {
        const vn = self.ast.getNode(value);
        break :blk vn.tag == .assignment_pattern and vn.data.binary.left == key;
    });
    if (shorthand) {
        const renamed = key_node.tag == .binding_identifier and self.options.unsupported.block_scoping and
            self.renamedNameOf(key) != null;
        if (!renamed) return self.visitBinaryNode(idx);
    }

    const new_key = try self.copyNodeDirect(key);
    try self.propagateSymbolId(key, new_key);
    const new_value = try self.visitNode(value);
    return self.ast.addNode(.{
        .tag = .binding_property,
        .span = node.span,
        .data = .{ .binary = .{ .left = new_key, .right = new_value, .flags = node.data.binary.flags } },
    });
}
