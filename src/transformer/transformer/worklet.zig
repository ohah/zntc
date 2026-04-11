//! Reanimated Worklet 변환 — "worklet" 디렉티브 감지 + 프로퍼티 할당 주입
//!
//! "worklet" 디렉티브가 있는 함수를 감지하고, scope hoisting 호환 형태로 변환한다:
//!   1. "worklet" 디렉티브 제거
//!   2. Closure 변수 추출 (함수 내 외부 참조)
//!   3. __initData.code 생성 (self-contained 코드 직렬화)
//!   4. __workletHash, __closure, __initData 프로퍼티 할당 emit
//!
//! Babel의 factory 패턴과 달리 함수 선언을 유지하고 프로퍼티만 추가하므로
//! strict_execution_order(scope hoisting)와 자연스럽게 호환된다.

const std = @import("std");
const ast_mod = @import("../../parser/ast.zig");
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const Ast = ast_mod.Ast;
const token_mod = @import("../../lexer/token.zig");
const Span = token_mod.Span;
const transformer_mod = @import("../transformer.zig");
const Transformer = transformer_mod.Transformer;
const Error = Transformer.Error;

// ================================================================
// Phase 1: "worklet" 디렉티브 감지 + 제거
// ================================================================

/// 함수 body의 첫 문장이 지정된 디렉티브인지 확인한다 (범용).
pub fn isWorkletDirectiveGeneric(self: *Transformer, body_idx: NodeIndex, directive: []const u8) bool {
    if (body_idx.isNone()) return false;
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .function_body) return false;

    const list = body.data.list;
    if (list.len == 0) return false;

    const first_stmt_raw = self.ast.extra_data.items[list.start];
    const first_stmt_idx: NodeIndex = @enumFromInt(first_stmt_raw);
    if (first_stmt_idx.isNone()) return false;

    const first_stmt = self.ast.getNode(first_stmt_idx);

    if (first_stmt.tag == .directive) {
        const text = self.ast.getText(first_stmt.span);
        if (text.len >= 2) {
            const inner = text[1 .. text.len - 1];
            return std.mem.eql(u8, inner, directive);
        }
        return false;
    }

    if (first_stmt.tag != .expression_statement) return false;
    const operand_idx = first_stmt.data.unary.operand;
    if (operand_idx.isNone()) return false;

    const operand = self.ast.getNode(operand_idx);
    if (operand.tag != .string_literal) return false;

    const text = self.ast.getText(operand.data.string_ref);
    if (text.len < 2) return false;
    const inner = text[1 .. text.len - 1];
    return std.mem.eql(u8, inner, directive);
}

/// 함수 body에서 첫 디렉티브 문장을 제거한 새 body를 반환한다.
/// isWorkletDirectiveGeneric()가 true인 경우에만 호출해야 한다.
pub fn stripWorkletDirective(self: *Transformer, body_idx: NodeIndex) Error!NodeIndex {
    const body = self.ast.getNode(body_idx);
    const list = body.data.list;

    // 첫 문장 제외한 나머지 복사
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var i: u32 = 1; // 첫 문장(worklet 디렉티브) 건너뜀
    while (i < list.len) : (i += 1) {
        const raw_idx = self.ast.extra_data.items[list.start + i];
        try self.scratch.append(self.allocator, @enumFromInt(raw_idx));
    }

    const new_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = body.tag,
        .span = body.span,
        .data = .{ .list = new_list },
    });
}

// ================================================================
// Phase 2: Closure 변수 추출
// ================================================================

/// JS 글로벌 식별자 — closure 변수에서 제외. comptime HashMap으로 O(1) 조회.
const JS_GLOBALS = std.StaticStringMap(void).initComptime(.{
    .{ "undefined", {} },             .{ "NaN", {} },                  .{ "Infinity", {} },       .{ "console", {} },
    .{ "Math", {} },                  .{ "JSON", {} },                 .{ "Object", {} },         .{ "Array", {} },
    .{ "String", {} },                .{ "Number", {} },               .{ "Boolean", {} },        .{ "Symbol", {} },
    .{ "Promise", {} },               .{ "Error", {} },                .{ "Map", {} },            .{ "Set", {} },
    .{ "WeakMap", {} },               .{ "WeakSet", {} },              .{ "Date", {} },           .{ "RegExp", {} },
    .{ "parseInt", {} },              .{ "parseFloat", {} },           .{ "isNaN", {} },          .{ "isFinite", {} },
    .{ "globalThis", {} },            .{ "null", {} },                 .{ "true", {} },           .{ "false", {} },
    .{ "require", {} },               .{ "module", {} },               .{ "exports", {} },        .{ "__dirname", {} },
    .{ "setTimeout", {} },            .{ "setInterval", {} },          .{ "clearTimeout", {} },   .{ "clearInterval", {} },
    .{ "requestAnimationFrame", {} }, .{ "cancelAnimationFrame", {} }, .{ "queueMicrotask", {} }, .{ "structuredClone", {} },
    .{ "fetch", {} },                 .{ "AbortController", {} },      .{ "URL", {} },            .{ "URLSearchParams", {} },
    .{ "TextEncoder", {} },           .{ "TextDecoder", {} },          .{ "Proxy", {} },          .{ "Reflect", {} },
    .{ "ArrayBuffer", {} },           .{ "SharedArrayBuffer", {} },    .{ "DataView", {} },       .{ "Uint8Array", {} },
    .{ "Int8Array", {} },             .{ "Uint16Array", {} },          .{ "Int16Array", {} },     .{ "Uint32Array", {} },
    .{ "Int32Array", {} },            .{ "Float32Array", {} },         .{ "Float64Array", {} },   .{ "BigInt64Array", {} },
    .{ "BigUint64Array", {} },        .{ "Intl", {} },                 .{ "eval", {} },           .{ "arguments", {} },
    .{ "this", {} },
});

/// 함수 body와 파라미터로부터 closure 변수(외부 참조)를 추출한다.
///
/// 알고리즘:
///   1. 파라미터 이름 → locals 집합에 추가
///   2. body 내 지역 선언(var/let/const/function) 이름 → locals 집합에 추가
///   3. body 내 identifier_reference 이름 → refs 집합에 추가
///   4. refs - locals - JS_GLOBALS = closure 변수
pub fn collectClosureVars(
    self: *Transformer,
    body_idx: NodeIndex,
    params_start: u32,
    params_len: u32,
) Error![]const []const u8 {
    var locals = std.StringHashMap(void).init(self.allocator);
    defer locals.deinit();
    var refs = std.StringHashMap(void).init(self.allocator);
    defer refs.deinit();

    // 1. 파라미터 이름 수집
    var pi: u32 = 0;
    while (pi < params_len) : (pi += 1) {
        const param_raw = self.ast.extra_data.items[params_start + pi];
        const param_idx: NodeIndex = @enumFromInt(param_raw);
        if (!param_idx.isNone()) {
            try collectBindingNames(self, param_idx, &locals);
        }
    }

    // 2-3. body 순회: 지역 선언 → locals, 식별자 참조 → refs
    try walkBodyForClosureAnalysis(self, body_idx, &locals, &refs, 0);

    // 4. refs - locals - globals = closure vars
    var result: std.ArrayList([]const u8) = .empty;
    var iter = refs.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (locals.contains(name)) continue;
        if (isGlobal(name)) continue;
        try result.append(self.allocator, name);
    }

    // 정렬 (결정론적 출력)
    std.mem.sort([]const u8, result.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return result.toOwnedSlice(self.allocator);
}

/// 바인딩 패턴에서 이름을 추출한다.
/// binding_identifier, array_binding_pattern, object_binding_pattern 처리.
fn collectBindingNames(self: *Transformer, idx: NodeIndex, locals: *std.StringHashMap(void)) Error!void {
    if (idx.isNone()) return;
    const node = self.ast.getNode(idx);

    switch (node.tag) {
        .binding_identifier => {
            const name = self.ast.getText(node.data.string_ref);
            if (name.len > 0) {
                locals.put(name, {}) catch return error.OutOfMemory;
            }
        },
        .formal_parameter => {
            // extra = [pattern, type_ann, default, flags, ...]
            const pattern_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[node.data.extra]);
            try collectBindingNames(self, pattern_idx, locals);
        },
        .array_pattern => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_raw = self.ast.extra_data.items[list.start + i];
                try collectBindingNames(self, @enumFromInt(elem_raw), locals);
            }
        },
        .object_pattern => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const prop_raw = self.ast.extra_data.items[list.start + i];
                const prop_idx: NodeIndex = @enumFromInt(prop_raw);
                if (prop_idx.isNone()) continue;
                const prop = self.ast.getNode(prop_idx);
                // binding_property: binary = { left: key, right: value }
                if (prop.tag == .binding_property) {
                    try collectBindingNames(self, prop.data.binary.right, locals);
                } else {
                    // shorthand 등
                    try collectBindingNames(self, prop_idx, locals);
                }
            }
        },
        .rest_element => {
            try collectBindingNames(self, node.data.unary.operand, locals);
        },
        .assignment_pattern => {
            // default value: left = pattern, right = default
            try collectBindingNames(self, node.data.binary.left, locals);
        },
        else => {},
    }
}

/// body를 재귀 순회하여 지역 선언(locals)과 식별자 참조(refs)를 수집한다.
fn walkBodyForClosureAnalysis(
    self: *Transformer,
    idx: NodeIndex,
    locals: *std.StringHashMap(void),
    refs: *std.StringHashMap(void),
    depth: u32,
) Error!void {
    if (idx.isNone()) return;
    if (depth > 64) return; // 재귀 깊이 제한
    if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;

    const node = self.ast.getNode(idx);

    switch (node.tag) {
        // 식별자 참조 수집
        .identifier_reference => {
            const name = self.ast.getText(node.data.string_ref);
            if (name.len > 0) {
                refs.put(name, {}) catch return error.OutOfMemory;
            }
        },

        // 중첩 함수/화살표 — 내부 body는 별도 스코프이므로 진입하지 않음.
        // 단, 함수 이름은 외부 스코프에 선언됨 (function_declaration).
        .function_declaration => {
            // 함수 이름 → 지역 선언
            const e = node.data.extra;
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            try collectBindingNames(self, name_idx, locals);
            // 함수 body는 진입하지 않음 (별도 스코프)
        },
        .function_expression, .arrow_function_expression, .function => {
            // 중첩 함수 body 진입 안 함
            return;
        },

        // 변수 선언: 이름 → locals, 초기값 → refs
        .variable_declaration => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            const list_start = self.ast.extra_data.items[e + 1];
            const list_len = self.ast.extra_data.items[e + 2];
            if (list_start + list_len > self.ast.extra_data.items.len) return;
            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const decl_raw = self.ast.extra_data.items[list_start + i];
                try walkBodyForClosureAnalysis(self, @enumFromInt(decl_raw), locals, refs, depth + 1);
            }
        },
        .variable_declarator => {
            // extra = [name, type_ann, init]
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            try collectBindingNames(self, name_idx, locals);
            // init → refs
            const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 2]);
            try walkBodyForClosureAnalysis(self, init_idx, locals, refs, depth + 1);
        },

        // 블록/리스트 노드: 자식들 순회
        .block_statement, .function_body, .program, .sequence_expression => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                if (list.start + i >= self.ast.extra_data.items.len) break;
                const child_raw = self.ast.extra_data.items[list.start + i];
                try walkBodyForClosureAnalysis(self, @enumFromInt(child_raw), locals, refs, depth + 1);
            }
        },

        // 단항 노드
        .expression_statement,
        .return_statement,
        .throw_statement,
        .spread_element,
        .parenthesized_expression,
        .await_expression,
        .yield_expression,
        .rest_element,
        .chain_expression,
        .import_expression,
        => {
            try walkBodyForClosureAnalysis(self, node.data.unary.operand, locals, refs, depth + 1);
        },

        // 이항 노드
        .binary_expression,
        .logical_expression,
        .assignment_expression,
        .while_statement,
        .do_while_statement,
        .labeled_statement,
        => {
            try walkBodyForClosureAnalysis(self, node.data.binary.left, locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, node.data.binary.right, locals, refs, depth + 1);
        },

        // call_expression: extra = [callee, args_start, args_len, flags]
        .call_expression => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 4)) return;
            const callee_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e]);
            try walkBodyForClosureAnalysis(self, callee_idx, locals, refs, depth + 1);
            const args_start = self.ast.extra_data.items[e + 1];
            const args_len = self.ast.extra_data.items[e + 2];
            var ai: u32 = 0;
            while (ai < args_len) : (ai += 1) {
                if (args_start + ai >= self.ast.extra_data.items.len) break;
                const arg_raw = self.ast.extra_data.items[args_start + ai];
                try walkBodyForClosureAnalysis(self, @enumFromInt(arg_raw), locals, refs, depth + 1);
            }
        },

        // member expression: extra = [object(0), property(1), flags]
        .static_member_expression, .private_field_expression => {
            // object만 순회 (property는 식별자이지만 외부 참조가 아님)
            const me = node.data.extra;
            if (self.ast.hasExtra(me, 2)) {
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[me]), locals, refs, depth + 1);
            }
        },
        .computed_member_expression => {
            // extra = [object(0), property(1), flags]
            const me = node.data.extra;
            if (self.ast.hasExtra(me, 2)) {
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[me]), locals, refs, depth + 1);
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[me + 1]), locals, refs, depth + 1);
            }
        },

        // 삼항 연산
        .conditional_expression => {
            try walkBodyForClosureAnalysis(self, node.data.ternary.a, locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, node.data.ternary.b, locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, node.data.ternary.c, locals, refs, depth + 1);
        },

        // if 문: extra = [condition, consequent, alternate]
        .if_statement => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 1]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 2]), locals, refs, depth + 1);
        },

        // for 문: extra = [init, test, update, body]
        .for_statement => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 4)) return;
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 1]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 2]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 3]), locals, refs, depth + 1);
        },

        // for-in/for-of: extra = [left, right, body]
        .for_in_statement, .for_of_statement => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 1]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 2]), locals, refs, depth + 1);
        },

        // try 문: extra = [block, handler, finalizer]
        .try_statement => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 1]), locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 2]), locals, refs, depth + 1);
        },

        // catch 절: binary = [param, body]
        .catch_clause => {
            // param → locals (catch 블록 스코프)
            try collectBindingNames(self, node.data.binary.left, locals);
            try walkBodyForClosureAnalysis(self, node.data.binary.right, locals, refs, depth + 1);
        },

        // switch: extra = [discriminant, cases_start, cases_len]
        .switch_statement => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e]), locals, refs, depth + 1);
            const cases_start = self.ast.extra_data.items[e + 1];
            const cases_len = self.ast.extra_data.items[e + 2];
            var ci: u32 = 0;
            while (ci < cases_len) : (ci += 1) {
                if (cases_start + ci >= self.ast.extra_data.items.len) break;
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[cases_start + ci]), locals, refs, depth + 1);
            }
        },

        // switch_case: extra = [test, stmts_start, stmts_len]
        .switch_case => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e]), locals, refs, depth + 1);
            const stmts_start = self.ast.extra_data.items[e + 1];
            const stmts_len = self.ast.extra_data.items[e + 2];
            var si: u32 = 0;
            while (si < stmts_len) : (si += 1) {
                if (stmts_start + si >= self.ast.extra_data.items.len) break;
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[stmts_start + si]), locals, refs, depth + 1);
            }
        },

        // array/object expression: list
        .array_expression, .object_expression => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                if (list.start + i >= self.ast.extra_data.items.len) break;
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[list.start + i]), locals, refs, depth + 1);
            }
        },

        // object_property: binary = [key, value] (shorthand: right=.none)
        .object_property => {
            if (node.data.binary.right.isNone()) {
                // shorthand { x } → key(x)는 참조
                try walkBodyForClosureAnalysis(self, node.data.binary.left, locals, refs, depth + 1);
            } else {
                // long-form { key: value } → value만 참조
                try walkBodyForClosureAnalysis(self, node.data.binary.right, locals, refs, depth + 1);
            }
        },

        // template literal: list (expressions + quasis interleaved)
        .template_literal => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                if (list.start + i >= self.ast.extra_data.items.len) break;
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[list.start + i]), locals, refs, depth + 1);
            }
        },

        // new expression: extra = [callee, args_start, args_len]
        .new_expression => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e]), locals, refs, depth + 1);
            const args_start = self.ast.extra_data.items[e + 1];
            const args_len = self.ast.extra_data.items[e + 2];
            var ai: u32 = 0;
            while (ai < args_len) : (ai += 1) {
                if (args_start + ai >= self.ast.extra_data.items.len) break;
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[args_start + ai]), locals, refs, depth + 1);
            }
        },

        // update/unary prefix/postfix: unary
        .update_expression, .unary_expression => {
            try walkBodyForClosureAnalysis(self, node.data.unary.operand, locals, refs, depth + 1);
        },

        // 리프 노드 (순회 불필요)
        .string_literal,
        .numeric_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regexp_literal,
        .this_expression,
        .super_expression,
        .directive,
        .break_statement,
        .continue_statement,
        .debugger_statement,
        .empty_statement,
        => {},

        // 그 외: 안전하게 무시 (TS 타입 노드, JSX 등)
        else => {},
    }
}

/// JS 글로벌 식별자인지 확인 (O(1) comptime HashMap 조회).
fn isGlobal(name: []const u8) bool {
    return JS_GLOBALS.has(name);
}

// ================================================================
// Phase 4: 프로퍼티 할당 AST 빌드
// ================================================================

/// funcName.__propName = value 형태의 assignment expression statement를 생성한다.
fn buildPropAssignment(self: *Transformer, func_name_span: Span, prop_name: []const u8, value: NodeIndex) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // funcName
    const obj_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = func_name_span,
        .data = .{ .string_ref = func_name_span },
    });

    // .__propName
    const prop_span = try self.ast.addString(prop_name);
    const prop_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = prop_span,
        .data = .{ .string_ref = prop_span },
    });

    // funcName.__propName (static_member_expression: extra = [object, property, flags])
    const member = try self.addExtraNode(.static_member_expression, zero_span, &.{
        @intFromEnum(obj_ref),
        @intFromEnum(prop_ref),
        0, // flags
    });

    // funcName.__propName = value
    const assign = try self.ast.addNode(.{
        .tag = .assignment_expression,
        .span = zero_span,
        .data = .{ .binary = .{ .left = member, .right = value, .flags = 0 } },
    });

    // expression statement wrapper
    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = zero_span,
        .data = .{ .unary = .{ .operand = assign, .flags = 0 } },
    });
}

/// worklet 함수에 대한 __workletHash, __closure, __initData 프로퍼티 할당문들을 생성한다.
///
/// 반환: 3개의 expression_statement NodeIndex 배열 (caller가 trailing_nodes에 추가)
pub fn buildWorkletPropertyAssignments(
    self: *Transformer,
    func_name: []const u8,
    closure_vars: []const []const u8,
    init_code: []const u8,
    hash: u32,
    source_location: []const u8,
) Error![3]NodeIndex {
    const func_name_span = try self.ast.addString(func_name);
    const zero_span = Span{ .start = 0, .end = 0 };

    // 1. funcName.__workletHash = <hash>;
    var hash_buf: [16]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_buf, "{d}", .{hash}) catch return error.OutOfMemory;
    const hash_span = try self.ast.addString(hash_str);
    const hash_node = try self.ast.addNode(.{
        .tag = .numeric_literal,
        .span = hash_span,
        .data = .{ .string_ref = hash_span },
    });
    const hash_stmt = try buildPropAssignment(self, func_name_span, "__workletHash", hash_node);

    // 2. funcName.__closure = { var1: var1, var2: var2, ... };
    const closure_obj = try buildClosureObject(self, closure_vars);
    const closure_stmt = try buildPropAssignment(self, func_name_span, "__closure", closure_obj);

    // 3. funcName.__initData = { code: "...", location: "..." };
    const init_data_obj = try buildInitDataObject(self, init_code, source_location, zero_span);
    const init_data_stmt = try buildPropAssignment(self, func_name_span, "__initData", init_data_obj);

    return .{ hash_stmt, closure_stmt, init_data_stmt };
}

/// { var1: var1, var2: var2, ... } 객체 리터럴 노드를 생성한다.
fn buildClosureObject(self: *Transformer, closure_vars: []const []const u8) Error!NodeIndex {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    const zero_span = Span{ .start = 0, .end = 0 };

    for (closure_vars) |var_name| {
        const name_span = try self.ast.addString(var_name);
        // key: identifier (shorthand { x } — right = .none)
        const key = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });
        // shorthand object_property: { x } → left=key, right=.none
        const prop = try self.ast.addNode(.{
            .tag = .object_property,
            .span = zero_span,
            .data = .{ .binary = .{ .left = key, .right = .none, .flags = 0 } },
        });
        try self.scratch.append(self.allocator, prop);
    }

    const obj_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = .object_expression,
        .span = zero_span,
        .data = .{ .list = obj_list },
    });
}

/// { code: "...", location: "..." } 객체 리터럴 노드를 생성한다.
fn buildInitDataObject(self: *Transformer, init_code: []const u8, source_location: []const u8, zero_span: Span) Error!NodeIndex {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    // code property
    {
        const key_span = try self.ast.addString("code");
        const key = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = key_span,
            .data = .{ .string_ref = key_span },
        });

        // escape the init code string for JS literal
        const escaped = try escapeStringForJs(self.allocator, init_code);
        var quoted_buf: std.ArrayList(u8) = .empty;
        defer quoted_buf.deinit(self.allocator);
        try quoted_buf.append(self.allocator, '"');
        try quoted_buf.appendSlice(self.allocator, escaped);
        try quoted_buf.append(self.allocator, '"');
        self.allocator.free(escaped);

        const value_span = try self.ast.addString(quoted_buf.items);
        const value = try self.ast.addNode(.{
            .tag = .string_literal,
            .span = value_span,
            .data = .{ .string_ref = value_span },
        });
        const prop = try self.ast.addNode(.{
            .tag = .object_property,
            .span = zero_span,
            .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
        });
        try self.scratch.append(self.allocator, prop);
    }

    // location property
    {
        const key_span = try self.ast.addString("location");
        const key = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = key_span,
            .data = .{ .string_ref = key_span },
        });

        var loc_buf: [1024]u8 = undefined;
        const loc_str = std.fmt.bufPrint(&loc_buf, "\"{s}\"", .{source_location}) catch return error.OutOfMemory;
        const value_span = try self.ast.addString(loc_str);
        const value = try self.ast.addNode(.{
            .tag = .string_literal,
            .span = value_span,
            .data = .{ .string_ref = value_span },
        });
        const prop = try self.ast.addNode(.{
            .tag = .object_property,
            .span = zero_span,
            .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
        });
        try self.scratch.append(self.allocator, prop);
    }

    const obj_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    return self.ast.addNode(.{
        .tag = .object_expression,
        .span = zero_span,
        .data = .{ .list = obj_list },
    });
}

/// JS 문자열 리터럴 이스케이프 (쌍따옴표 내부용).
fn escapeStringForJs(allocator: std.mem.Allocator, input: []const u8) Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (input) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

// ================================================================
// Phase 3: Init Code 생성
// ================================================================

/// worklet 함수의 __initData.code를 생성한다.
///
/// 문자열 기반 코드 생성: closure 변수 destructuring + 원본 함수 body를 조합.
/// Codegen 기반 AST 재생성은 향후 최적화로 전환 가능.
///
/// 생성 형태:
///   function funcName(params){const{v1,v2}=this.__closure;...originalBody...}
pub fn generateInitCode(
    self: *Transformer,
    func_name: []const u8,
    body_idx: NodeIndex,
    closure_vars: []const []const u8,
    params_start: u32,
    params_len: u32,
    flags: u32,
) Error![]const u8 {
    _ = flags;
    var buf: std.ArrayList(u8) = .empty;

    // function header
    try buf.appendSlice(self.allocator, "function ");
    try buf.appendSlice(self.allocator, func_name);
    try buf.append(self.allocator, '(');

    // parameters (소스에서 추출)
    var pi: u32 = 0;
    while (pi < params_len) : (pi += 1) {
        if (pi > 0) try buf.append(self.allocator, ',');
        const param_raw = self.ast.extra_data.items[params_start + pi];
        const param_idx: NodeIndex = @enumFromInt(param_raw);
        if (!param_idx.isNone()) {
            const param_node = self.ast.getNode(param_idx);
            const param_text = self.ast.getText(param_node.span);
            if (param_text.len > 0) {
                try buf.appendSlice(self.allocator, param_text);
            }
        }
    }

    try buf.appendSlice(self.allocator, "){");

    // closure destructuring
    if (closure_vars.len > 0) {
        try buf.appendSlice(self.allocator, "const{");
        for (closure_vars, 0..) |v, i| {
            if (i > 0) try buf.append(self.allocator, ',');
            try buf.appendSlice(self.allocator, v);
        }
        try buf.appendSlice(self.allocator, "}=this.__closure;");
    }

    // body statements (소스에서 추출 — worklet 디렉티브 제외)
    const body = self.ast.getNode(body_idx);
    if (body.tag == .block_statement or body.tag == .function_body) {
        const list = body.data.list;
        var si: u32 = 0;
        while (si < list.len) : (si += 1) {
            const stmt_raw = self.ast.extra_data.items[list.start + si];
            const stmt_idx: NodeIndex = @enumFromInt(stmt_raw);
            if (stmt_idx.isNone()) continue;
            const stmt_node = self.ast.getNode(stmt_idx);
            // span이 string_table 비트를 가지면 synthetic 노드 → 건너뜀
            if (stmt_node.span.start & 0x8000_0000 != 0) continue;
            if (stmt_node.span.start < stmt_node.span.end and
                stmt_node.span.end <= @as(u32, @intCast(self.ast.source.len)))
            {
                const stmt_text = self.ast.source[stmt_node.span.start..stmt_node.span.end];
                try buf.appendSlice(self.allocator, stmt_text);
                // 세미콜론이 없으면 추가
                if (stmt_text.len > 0 and stmt_text[stmt_text.len - 1] != ';' and stmt_text[stmt_text.len - 1] != '}') {
                    try buf.append(self.allocator, ';');
                }
            }
        }
    }

    try buf.append(self.allocator, '}');
    return buf.toOwnedSlice(self.allocator);
}

/// const { var1, var2, ... } = this.__closure; 문을 생성한다.
fn buildClosureDestructuring(self: *Transformer, closure_vars: []const []const u8, zero_span: Span) Error!NodeIndex {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    const none = @intFromEnum(NodeIndex.none);

    // object binding pattern: { var1, var2, ... }
    for (closure_vars) |var_name| {
        const name_span = try self.ast.addString(var_name);
        const key = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });
        const binding = try self.ast.addNode(.{
            .tag = .binding_identifier,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });
        // shorthand binding property: { varName } → key = varName, value = varName binding
        const prop = try self.ast.addNode(.{
            .tag = .binding_property,
            .span = zero_span,
            .data = .{ .binary = .{ .left = key, .right = binding, .flags = 0 } },
        });
        try self.scratch.append(self.allocator, prop);
    }

    const pattern_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    const pattern = try self.ast.addNode(.{
        .tag = .object_pattern,
        .span = zero_span,
        .data = .{ .list = pattern_list },
    });

    // this.__closure
    const this_node = try self.ast.addNode(.{
        .tag = .this_expression,
        .span = zero_span,
        .data = .{ .none = 0 },
    });
    const closure_span = try self.ast.addString("__closure");
    const closure_prop = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = closure_span,
        .data = .{ .string_ref = closure_span },
    });
    const this_closure = try self.addExtraNode(.static_member_expression, zero_span, &.{
        @intFromEnum(this_node),
        @intFromEnum(closure_prop),
        0, // flags
    });

    // variable_declarator: pattern = this.__closure
    const declarator = try self.addExtraNode(.variable_declarator, zero_span, &.{
        @intFromEnum(pattern),
        none, // type annotation
        @intFromEnum(this_closure), // init
    });

    // const 선언 (kind = 2: const)
    const decl_list = try self.ast.addNodeList(&.{declarator});
    return self.addExtraNode(.variable_declaration, zero_span, &.{
        2, // const
        decl_list.start,
        decl_list.len,
    });
}
