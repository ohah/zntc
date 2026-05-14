//! Cover grammar conversion helpers for expression/arrow parameters.

const std = @import("std");
const ast_mod = @import("ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Span = @import("../lexer/token.zig").Span;
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;
const ParseError2 = parser_mod.ParseError2;

const rest_init_error = Parser.rest_init_error;
const shorthand_with_default = Parser.shorthand_with_default;
const spread_trailing_comma = Parser.spread_trailing_comma;

// Cover Grammar: expression → assignment target 재해석 (oxc 방식)
// ================================================================
//
// ECMAScript의 "cover grammar"은 expression과 pattern이 같은 구문 형태를
// 공유하기 때문에 파서가 expression으로 먼저 파싱한 후, 문맥에 따라
// assignment target으로 재해석하는 메커니즘이다.
//
// 예: `[a, b] = [1, 2]` — 좌변은 array_expression으로 파싱되지만
//     `=`를 만나는 순간 array destructuring pattern으로 재해석된다.
//
// 기존에는 이 재해석을 위한 검증이 6개 함수에 분산되어 있었다.
// coverExpressionToAssignmentTarget은 이를 단일 재귀 walk로 통합한다.
//
// 한 번의 순회에서 검증하는 규칙:
// 1. 구조적 유효성: identifier, member expr, destructuring만 assignment target
// 2. rest/spread initializer 금지: [...x = 1] = arr → SyntaxError
// 3. escaped keyword 금지: ({ v\u0061r }) = x → SyntaxError
// 4. strict mode eval/arguments 할당 금지
// 5. parenthesized destructuring 금지: ({x}) = 1 → SyntaxError

/// expression을 assignment target으로 검증하는 단일 재귀 walk.
/// 기존의 isValidAssignmentTarget + checkRestInitInAssignmentPattern +
/// checkSpreadRestInit + checkEscapedKeywordInPattern +
/// checkStrictAssignmentTarget 5개 함수를 하나로 통합한다.
///
/// cover grammar: expression → assignment target으로 변환.
/// 태그를 변환하고 (setTag) 검증도 수행한다.
/// 반환값: true면 valid assignment target, false면 에러를 이미 추가했거나 invalid.
/// is_top이 true면 최상위 호출 (invalid일 때 "Invalid assignment target" 에러 추가).
pub fn coverExpressionToAssignmentTarget(self: *Parser, idx: NodeIndex, is_top: bool) ParseError2!bool {
    if (idx.isNone()) return false;
    const node = self.ast.getNode(idx);
    return switch (node.tag) {
        // 1) identifier — valid target. 태그를 assignment_target_identifier로 변환.
        .identifier_reference => {
            // escaped keyword 검증: v\u0061r → "var"이면 에러
            try self.checkIdentifierEscapedKeyword(node.span);
            // strict mode: eval/arguments에 할당 금지 (checkStrictBinding 내부에서 strict 체크)
            try self.checkStrictBinding(node.span);
            self.ast.setTag(idx, .assignment_target_identifier);
            return true;
        },
        .private_identifier, .private_field_expression => true,

        // 2) member expression — optional chaining이 아니면 valid (태그 유지)
        .static_member_expression, .computed_member_expression => {
            if (self.ast.readExtra(node.data.extra, 2) == 0) return true; // normal (not optional chain)
            // optional chaining (a?.b, a?.[b])은 assignment target이 아님
            if (is_top) try self.addErrorCode(node.span, "Invalid assignment target", .invalid_assignment_target);
            return false;
        },

        // 3) array destructuring — 태그를 array_assignment_target으로 변환 + 자식 재귀
        .array_expression => {
            self.ast.setTag(idx, .array_assignment_target);
            try self.coverArrayExpressionToTarget(node);
            return true;
        },

        // 4) object destructuring — 태그를 object_assignment_target으로 변환 + 자식 재귀
        .object_expression => {
            self.ast.setTag(idx, .object_assignment_target);
            try self.coverObjectExpressionToTarget(node);
            // CoverInitializedName이 destructuring으로 정상 소비됨
            self.has_cover_init_name = false;
            return true;
        },

        // 5) parenthesized expression — 내부를 벗겨서 검증
        .parenthesized_expression => {
            const inner = node.data.unary.operand;
            if (inner.isNone()) {
                if (is_top) try self.addErrorCode(node.span, "Invalid assignment target", .invalid_assignment_target);
                return false;
            }
            const inner_tag = self.ast.getNode(inner).tag;
            // ({x}) = 1, ([x]) = 1 → parenthesized destructuring 금지
            if (inner_tag == .array_expression or inner_tag == .object_expression) {
                try self.addErrorCode(node.span, "Invalid assignment target", .invalid_assignment_target);
                return false;
            }
            // (x) = 1 → 내부가 simple target이면 OK
            return try self.coverExpressionToAssignmentTarget(inner, is_top);
        },

        // 6) 이미 변환된 assignment target 태그는 유지
        .assignment_target_identifier,
        .array_assignment_target,
        .object_assignment_target,
        => true,

        // 6b) TS as/satisfies expression — 내부 expression을 assignment target으로 검증
        // (z as any) = 1 → z가 valid target이면 OK (esbuild/TS 호환)
        .ts_as_expression, .ts_satisfies_expression => {
            const inner = node.data.binary.left;
            return try self.coverExpressionToAssignmentTarget(inner, is_top);
        },

        // 6c) TS non-null assertion — 같은 원리. `x!--`, `a[i]!++`, `x! = 1` 같은
        // 패턴이 TS 에선 valid (TS spec: `NonNullExpression` 은 assignment target).
        .ts_non_null_expression => {
            const inner = node.data.unary.operand;
            return try self.coverExpressionToAssignmentTarget(inner, is_top);
        },

        // 7) meta_property (import.meta, new.target) — 절대로 assignment target이 될 수 없음.
        //    is_top 여부와 무관하게 항상 에러. else 분기는 is_top=false일 때 에러를 내지 않으므로
        //    destructuring 내부([import.meta] = arr)에서 잘못 통과하는 것을 방지.
        .meta_property => {
            try self.addErrorCode(node.span, "Invalid assignment target", .invalid_assignment_target);
            return false;
        },

        else => {
            if (is_top) try self.addErrorCode(node.span, "Invalid assignment target", .invalid_assignment_target);
            return false;
        },
    };
}

/// spread element의 operand를 검증하는 cover grammar 헬퍼.
/// rest에 initializer가 있으면 에러를 내고, operand를 재귀 검증한다.
/// coverArrayExpressionToTarget과 coverObjectExpressionToTarget에서 공통 사용.
pub fn coverSpreadElementToTarget(self: *Parser, spread_idx: NodeIndex, operand_idx: NodeIndex) ParseError2!void {
    const operand = self.ast.getNode(operand_idx);
    if (operand.tag == .assignment_expression) {
        try self.addError(operand.span, rest_init_error);
    }
    // spread_element → assignment_target_rest로 변환
    self.ast.setTag(spread_idx, .assignment_target_rest);
    _ = try self.coverExpressionToAssignmentTarget(operand_idx, true);
}

/// array expression 내부를 assignment target으로 검증 (coverExpressionToAssignmentTarget 헬퍼).
/// 각 요소의 spread rest-init 금지 + nested pattern 재귀 검증.
pub fn coverArrayExpressionToTarget(self: *Parser, node: Node) ParseError2!void {
    const list = node.data.list;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        if (elem_idx.isNone()) continue; // elision (none)
        const elem = self.ast.getNode(elem_idx);
        if (elem.tag == .elision) continue; // elision node — destructuring에서는 무시
        switch (elem.tag) {
            .spread_element => {
                // rest는 마지막 요소여야 함: [...x, y] → SyntaxError
                if (i + 1 < list.len) {
                    try self.addErrorCode(elem.span, "Rest element must be last element", .rest_must_be_last);
                }
                // rest 뒤 trailing comma 금지: [...x,] → SyntaxError
                // parseArrayExpression에서 spread_trailing_comma로 마킹됨
                if ((elem.data.unary.flags & spread_trailing_comma) != 0) {
                    try self.addErrorCode(elem.span, "Rest element may not have a trailing comma", .rest_trailing_comma);
                }
                try self.coverSpreadElementToTarget(elem_idx, elem.data.unary.operand);
            },
            .assignment_expression => {
                // [x = 1] → assignment_target_with_default로 변환
                self.ast.setTag(elem_idx, .assignment_target_with_default);
                _ = try self.coverExpressionToAssignmentTarget(elem.data.binary.left, true);
            },
            else => {
                // identifier, nested array/object/member 등 → 재귀 검증
                _ = try self.coverExpressionToAssignmentTarget(elem_idx, true);
            },
        }
    }
}

/// object expression 내부를 assignment target으로 검증 (coverExpressionToAssignmentTarget 헬퍼).
/// 각 프로퍼티의 shorthand escaped keyword + strict eval/arguments + spread rest-init + nested value 재귀 검증.
pub fn coverObjectExpressionToTarget(self: *Parser, node: Node) ParseError2!void {
    const list = node.data.list;
    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
        if (elem_idx.isNone()) continue;
        const elem = self.ast.getNode(elem_idx);
        if (elem.tag == .object_property) {
            const is_shorthand_default = (elem.data.binary.flags & shorthand_with_default) != 0;
            if (!elem.data.binary.left.isNone() and elem.data.binary.right.isNone()) {
                // shorthand without value: { eval } — right가 none인 경우
                // parseObjectProperty에서 shorthand는 value를 생성하지 않으므로 right=none
                const key_span = self.ast.getNode(elem.data.binary.left).span;
                try self.checkIdentifierEscapedKeyword(key_span);
                try self.checkStrictBinding(key_span);
                self.ast.setTag(elem_idx, .assignment_target_property_identifier);
            } else if (!elem.data.binary.left.isNone() and !elem.data.binary.right.isNone()) {
                // shorthand 검증: key와 value가 같은 span이면 shorthand
                const key_span = self.ast.getNode(elem.data.binary.left).span;
                const val_node = self.ast.getNode(elem.data.binary.right);
                const is_shorthand = key_span.start == val_node.span.start and key_span.end == val_node.span.end;
                if (is_shorthand) {
                    try self.checkIdentifierEscapedKeyword(key_span);
                    // strict mode: shorthand에서 eval/arguments 할당 금지
                    try self.checkStrictBinding(key_span);
                    // shorthand → assignment_target_property_identifier
                    self.ast.setTag(elem_idx, .assignment_target_property_identifier);
                } else if (is_shorthand_default) {
                    // shorthand with default: { eval = 0 } — key가 target, value가 default
                    // key의 eval/arguments 검증이 필요 (strict mode)
                    try self.checkIdentifierEscapedKeyword(key_span);
                    try self.checkStrictBinding(key_span);
                    self.ast.setTag(elem_idx, .assignment_target_property_identifier);
                    // value(default)는 assignment target이 아니므로 검증하지 않음
                } else {
                    // long-form → assignment_target_property_property
                    self.ast.setTag(elem_idx, .assignment_target_property_property);
                    // value가 assignment_expression이면 default-value 구문:
                    // { key: target = default } → target을 검증, default는 검증하지 않음
                    if (val_node.tag == .assignment_expression) {
                        self.ast.setTag(elem.data.binary.right, .assignment_target_with_default);
                        _ = try self.coverExpressionToAssignmentTarget(val_node.data.binary.left, true);
                    } else {
                        // value를 재귀 검증 (nested pattern일 수 있음)
                        _ = try self.coverExpressionToAssignmentTarget(elem.data.binary.right, true);
                    }
                }
            }
        } else if (elem.tag == .spread_element) {
            // rest는 마지막 요소여야 함: {...x, y} → SyntaxError
            if (i + 1 < list.len) {
                try self.addErrorCode(elem.span, "Rest element must be last element", .rest_must_be_last);
            }
            // object rest: {...x} = obj
            try self.coverSpreadElementToTarget(elem_idx, elem.data.unary.operand);
        } else if (elem.tag == .method_definition) {
            // method/getter/setter/async/generator는 destructuring target이 아님
            try self.addErrorCode(elem.span, "Invalid assignment target", .invalid_assignment_target);
        }
    }
}

/// cover grammar 표현식에서 바인딩 이름의 span을 재귀 수집하여 중복 검사한다.
/// 중복 발견 시 즉시 에러를 추가한다.
pub fn collectCoverParamNames(self: *Parser, idx: NodeIndex) ParseError2!void {
    if (idx.isNone()) return;
    const node = self.ast.getNode(idx);
    switch (node.tag) {
        .identifier_reference, .binding_identifier, .assignment_target_identifier => {
            const name = self.ast.source[node.span.start..node.span.end];
            // 이전에 수집된 이름과 비교하여 중복 검사
            // param_name_spans를 사용 — coverExpressionToArrowParams에서 초기화
            for (self.param_name_spans.items) |prev_span| {
                const prev_name = self.ast.source[prev_span.start..prev_span.end];
                if (std.mem.eql(u8, name, prev_name)) {
                    try self.addErrorCodeWithPrevious(node.span, "Duplicate parameter name", .duplicate_parameter, prev_span);
                    return;
                }
            }
            try self.param_name_spans.append(self.allocator, node.span);
        },
        .parenthesized_expression => try self.collectCoverParamNames(node.data.unary.operand),
        .sequence_expression => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                try self.collectCoverParamNames(elem_idx);
            }
        },
        .object_expression, .array_expression, .object_assignment_target, .array_assignment_target => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                try self.collectCoverParamNames(elem_idx);
            }
        },
        .assignment_target_property_identifier => {
            // shorthand property (identifier): { x }, { x = default }
            // left = key(identifier_reference) = 바인딩, right = default value 또는 none
            // 항상 left(key)에서 바인딩 이름을 수집한다. right는 default value이므로 수집하지 않는다.
            try self.collectCoverParamNames(node.data.binary.left);
        },
        .object_property => {
            // cover grammar 변환 전의 object property.
            // shorthand_with_default({ x = val }): left=key(바인딩), right=default value
            // shorthand({ x }): right=none, left=key(바인딩)
            // long-form({ key: value }): left=key, right=value(바인딩)
            const is_shorthand_default = (node.data.binary.flags & shorthand_with_default) != 0;
            if (node.data.binary.right.isNone()) {
                // shorthand: { x } — key가 바인딩
                try self.collectCoverParamNames(node.data.binary.left);
            } else if (is_shorthand_default) {
                // shorthand with default: { x = val } — key가 바인딩, value는 default
                try self.collectCoverParamNames(node.data.binary.left);
            } else {
                // long-form: { key: value } — value가 바인딩
                try self.collectCoverParamNames(node.data.binary.right);
            }
        },
        .assignment_target_property_property => {
            // long-form property: { key: target } 또는 { key: target = default }
            // right(value)에서 바인딩 이름을 수집한다.
            try self.collectCoverParamNames(node.data.binary.right);
        },
        .binding_property => {
            try self.collectCoverParamNames(node.data.binary.right);
        },
        .assignment_expression, .assignment_pattern, .assignment_target_with_default => {
            // default value: left = binding, right = default_value
            try self.collectCoverParamNames(node.data.binary.left);
            // default value 내부의 yield/await 검사 (이름 수집하지 않고 검사만)
            try self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
        },
        .spread_element, .assignment_target_rest, .binding_rest_element, .rest_element => {
            try self.collectCoverParamNames(node.data.unary.operand);
        },
        else => {},
    }
}

/// expression이 arrow function 파라미터로 유효한 형태인지 확인한다.
/// parenthesized_expression, identifier_reference 등만 arrow 파라미터가 될 수 있다.
/// call_expression, member_expression 등은 불가능.
pub fn isValidArrowParamForm(self: *const Parser, idx: NodeIndex) bool {
    if (idx.isNone()) return false;
    const node = self.ast.getNode(idx);
    return switch (node.tag) {
        .parenthesized_expression, .identifier_reference, .binding_identifier => true,
        else => false,
    };
}

/// async arrow 파라미터에서 'await' 식별자 사용을 금지한다.
/// async arrow의 파라미터는 async context 진입 전에 파싱되므로 await가 identifier로 파싱된다.
/// 이 함수는 cover grammar 변환 후 호출하여 identifier 이름이 "await"인 경우를 검출한다.
pub fn checkAsyncArrowParamsForAwait(self: *Parser, idx: NodeIndex) ParseError2!void {
    if (idx.isNone()) return;
    if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;
    const node = self.ast.getNode(idx);
    switch (node.tag) {
        .identifier_reference, .binding_identifier, .assignment_target_identifier => {
            const name = self.ast.source[node.span.start..node.span.end];
            if (std.mem.eql(u8, name, "await")) {
                try self.addErrorCode(node.span, "'await' is not allowed in async arrow function parameters", .await_in_async_arrow_params);
            }
        },
        .parenthesized_expression,
        .spread_element,
        .assignment_target_rest,
        .rest_element,
        .binding_rest_element,
        => {
            try self.checkAsyncArrowParamsForAwait(node.data.unary.operand);
        },
        .sequence_expression,
        .array_expression,
        .object_expression,
        .array_assignment_target,
        .object_assignment_target,
        .formal_parameters,
        => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                try self.checkAsyncArrowParamsForAwait(elem_idx);
            }
        },
        .assignment_expression,
        .assignment_pattern,
        .assignment_target_with_default,
        .object_property,
        .assignment_target_property_identifier,
        .assignment_target_property_property,
        .binding_property,
        => {
            try self.checkAsyncArrowParamsForAwait(node.data.binary.left);
            try self.checkAsyncArrowParamsForAwait(node.data.binary.right);
        },
        // 중첩 arrow: params (extra[0]) 만 검사 — body 는 별개 scope 라 무관.
        .arrow_function_expression => {
            const params_idx = self.ast.readExtraNode(node.data.extra, 0);
            try self.checkAsyncArrowParamsForAwait(params_idx);
        },
        else => {},
    }
}

/// arrow 파라미터 default value 내부에 yield/await가 있는지 검사한다.
/// 이름 수집은 하지 않고 yield/await expression만 검출한다.
pub fn checkCoverParamDefaultForYieldAwait(self: *Parser, idx: NodeIndex) ParseError2!void {
    if (idx.isNone()) return;
    if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;
    const node = self.ast.getNode(idx);
    switch (node.tag) {
        .yield_expression => {
            try self.addErrorCode(node.span, "'yield' is not allowed in arrow function parameters", .yield_in_arrow_params);
        },
        .await_expression => {
            try self.addErrorCode(node.span, "'await' is not allowed in arrow function parameters", .await_in_arrow_params);
        },
        // unary node — operand만 검사
        .parenthesized_expression,
        .spread_element,
        => try self.checkCoverParamDefaultForYieldAwait(node.data.unary.operand),
        // unary/update: extra = [operand, operator_and_flags]
        .unary_expression,
        .update_expression,
        => {
            const e = node.data.extra;
            if (e < self.ast.extra_data.items.len) {
                try self.checkCoverParamDefaultForYieldAwait(@enumFromInt(self.ast.extra_data.items[e]));
            }
        },
        // list node — 각 요소 검사
        .sequence_expression,
        .array_expression,
        .object_expression,
        => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                try self.checkCoverParamDefaultForYieldAwait(elem_idx);
            }
        },
        // binary node — 양쪽 자식 검사
        .assignment_expression,
        .binary_expression,
        .logical_expression,
        .object_property,
        => {
            try self.checkCoverParamDefaultForYieldAwait(node.data.binary.left);
            try self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
        },
        // conditional은 ternary이지만 binary data 사용 (condition=left, consequent/alternate 조합=right)
        .conditional_expression => {
            try self.checkCoverParamDefaultForYieldAwait(node.data.binary.left);
            try self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
        },
        // 리프 노드 (identifier, literal 등)나 기타 — 더 이상 탐색 불필요
        else => {},
    }
}

/// 단일 파라미터 NodeIndex를 `formal_parameters` list 노드로 감싼다.
/// 빈 arrow(`() =>`)와 단일 식별자(`x =>`) 공용 헬퍼.
pub fn wrapAsFormalParameters(self: *Parser, params: []const NodeIndex, span: Span) !NodeIndex {
    const list = try self.ast.addNodeList(params);
    return try self.ast.addNode(.{
        .tag = .formal_parameters,
        .span = span,
        .data = .{ .list = list },
    });
}

/// 이미 만든 NodeList(extra_data에 연속 저장된 NodeIndex 리스트)를 formal_parameters 노드로 감싼다.
/// function/method/arrow가 공유하는 정규화 계약. arrow는 coverExpressionToArrowParams에서,
/// function/method는 parse* 함수들의 마지막 단계에서 사용.
pub fn wrapAsFormalParametersFromList(self: *Parser, list: NodeList, span: Span) !NodeIndex {
    return try self.ast.addNode(.{
        .tag = .formal_parameters,
        .span = span,
        .data = .{ .list = list },
    });
}

/// arrow function 파라미터를 cover grammar으로 검증 + **formal_parameters 노드로 정규화**.
///
/// 입력: parseAssignmentExpression으로 파싱된 원형 (identifier / parenthesized / sequence / spread / formal_parameters).
/// 출력: `formal_parameters` list 노드 (모든 arrow 공통 계약). ESTree/Babel/esbuild/SWC 동일.
///
/// 정규화 없이 원형을 유지하면 downstream consumer마다 cover grammar 해석 로직이 필요해지고
/// (params_start/len 계약 위반), worklet plugin 등에서 파라미터를 closure로 오인하는 버그가 발생.
/// 관련: #1283 (worklet arrow param ReferenceError).
pub fn coverExpressionToArrowParams(self: *Parser, idx: NodeIndex) ParseError2!NodeIndex {
    if (idx.isNone()) {
        // `() => ...` 같은 빈 arrow
        return self.wrapAsFormalParameters(&.{}, .{ .start = 0, .end = 0 });
    }
    const node = self.ast.getNode(idx);

    // 이미 formal_parameters면 그대로 (TS 타입 어노테이션 있는 경우 parser가 먼저 생성)
    if (node.tag == .formal_parameters) return idx;

    // 중복 파라미터 이름 검사는 원형 idx 기준으로 수행 (정규화 전)
    self.param_name_spans.clearRetainingCapacity();
    try self.collectCoverParamNames(idx);

    const scratch_top = self.scratch.items.len;
    defer self.restoreScratch(scratch_top);

    if (node.tag == .parenthesized_expression) {
        // (expr) → 내부를 풀어서 재귀 처리
        return self.coverExpressionToArrowParams(node.data.unary.operand);
    } else if (node.tag == .sequence_expression) {
        const list = node.data.list;
        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
            const elem = self.ast.getNode(elem_idx);
            if (elem.tag == .spread_element) {
                if (i + 1 < list.len) {
                    try self.addErrorCode(elem.span, "Rest element must be last element", .rest_must_be_last);
                }
                if ((elem.data.unary.flags & spread_trailing_comma) != 0) {
                    try self.addErrorCode(elem.span, "Rest element may not have a trailing comma", .rest_trailing_comma);
                }
                try self.checkBindingRestInit(elem.data.unary.operand);
                _ = try self.coverExpressionToAssignmentTarget(elem.data.unary.operand, false);
                // binding 컨텍스트로 reinterpret했으므로 태그도 rest_element로 정규화
                self.ast.setTag(elem_idx, .rest_element);
            } else {
                _ = try self.coverExpressionToAssignmentTarget(elem_idx, false);
            }
            try self.scratch.append(self.allocator, elem_idx);
        }
    } else if (node.tag == .spread_element) {
        if ((node.data.unary.flags & spread_trailing_comma) != 0) {
            try self.addErrorCode(node.span, "Rest element may not have a trailing comma", .rest_trailing_comma);
        }
        try self.checkBindingRestInit(node.data.unary.operand);
        _ = try self.coverExpressionToAssignmentTarget(node.data.unary.operand, false);
        self.ast.setTag(idx, .rest_element);
        try self.scratch.append(self.allocator, idx);
    } else {
        _ = try self.coverExpressionToAssignmentTarget(idx, false);
        try self.scratch.append(self.allocator, idx);
    }

    return self.wrapAsFormalParameters(self.scratch.items[scratch_top..], node.span);
}
