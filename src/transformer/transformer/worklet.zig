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

/// Closure 변수 정보. name + 원본 identifier_reference NodeIndex (scope hoisting rename용).
pub const ClosureVar = struct {
    name: []const u8,
    /// 원본 identifier_reference 노드 인덱스.
    /// buildClosureObject에서 symbol_id를 복사하여 scope hoisting rename을 지원.
    ref_idx: NodeIndex,
};

// ================================================================
// Phase 1: "worklet" 디렉티브 감지 + 제거
// ================================================================

/// 함수 body의 첫 문장이 지정된 디렉티브인지 확인한다 (범용).
/// 함수 body에서 지정된 디렉티브를 찾는다.
/// ES5 변환(rest params 등)이 body 앞에 문장을 삽입할 수 있으므로,
/// 첫 문장뿐 아니라 앞쪽 몇 문장 내에서 탐색한다.
/// 발견 시 해당 문장의 리스트 내 오프셋을 반환, 없으면 null.
pub fn findDirectiveOffset(self: *Transformer, body_idx: NodeIndex, directive: []const u8) ?u32 {
    if (body_idx.isNone()) return null;
    const body = self.ast.getNode(body_idx);
    if (body.tag != .block_statement and body.tag != .function_body) return null;

    const list = body.data.list;
    // 앞쪽 최대 5문장 내에서 탐색 (rest params, default params 등이 삽입될 수 있음)
    const search_len = @min(list.len, 5);
    var si: u32 = 0;
    while (si < search_len) : (si += 1) {
        const stmt_raw = self.ast.extra_data.items[list.start + si];
        const stmt_idx: NodeIndex = @enumFromInt(stmt_raw);
        if (stmt_idx.isNone()) continue;

        const stmt = self.ast.getNode(stmt_idx);

        if (stmt.tag == .directive) {
            const text = self.ast.getText(stmt.span);
            if (text.len >= 2 and std.mem.eql(u8, text[1 .. text.len - 1], directive)) {
                return si;
            }
        } else if (stmt.tag == .expression_statement) {
            const operand_idx = stmt.data.unary.operand;
            if (!operand_idx.isNone()) {
                const operand = self.ast.getNode(operand_idx);
                if (operand.tag == .string_literal) {
                    const text = self.ast.getText(operand.data.string_ref);
                    if (text.len >= 2 and std.mem.eql(u8, text[1 .. text.len - 1], directive)) {
                        return si;
                    }
                }
            }
        }
    }
    return null;
}

pub fn isWorkletDirectiveGeneric(self: *Transformer, body_idx: NodeIndex, directive: []const u8) bool {
    return findDirectiveOffset(self, body_idx, directive) != null;
}

/// 함수 body에서 worklet 디렉티브 문장을 제거한 새 body를 반환한다.
/// findDirectiveOffset()으로 위치를 찾아 해당 문장만 제거.
pub fn stripWorkletDirective(self: *Transformer, body_idx: NodeIndex) Error!NodeIndex {
    const body = self.ast.getNode(body_idx);
    const list = body.data.list;

    const dir_offset = findDirectiveOffset(self, body_idx, "worklet") orelse return body_idx;

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var i: u32 = 0;
    while (i < list.len) : (i += 1) {
        if (i == dir_offset) continue; // 디렉티브 문장 건너뜀
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
    .{ "undefined", {} },      .{ "NaN", {} },             .{ "Infinity", {} },              .{ "console", {} },
    .{ "Math", {} },           .{ "JSON", {} },            .{ "Object", {} },                .{ "Array", {} },
    .{ "String", {} },         .{ "Number", {} },          .{ "Boolean", {} },               .{ "Symbol", {} },
    .{ "Promise", {} },        .{ "Error", {} },           .{ "Map", {} },                   .{ "Set", {} },
    .{ "WeakMap", {} },        .{ "WeakSet", {} },         .{ "Date", {} },                  .{ "RegExp", {} },
    .{ "parseInt", {} },       .{ "parseFloat", {} },      .{ "isNaN", {} },                 .{ "isFinite", {} },
    .{ "globalThis", {} },     .{ "global", {} },          .{ "self", {} },                  .{ "window", {} },
    .{ "null", {} },           .{ "true", {} },            .{ "false", {} },                 .{ "process", {} },
    .{ "__DEV__", {} },        .{ "__filename", {} },      .{ "require", {} },               .{ "module", {} },
    .{ "exports", {} },        .{ "__dirname", {} },       .{ "setTimeout", {} },            .{ "setInterval", {} },
    .{ "clearTimeout", {} },   .{ "clearInterval", {} },   .{ "requestAnimationFrame", {} }, .{ "cancelAnimationFrame", {} },
    .{ "queueMicrotask", {} }, .{ "structuredClone", {} }, .{ "fetch", {} },                 .{ "AbortController", {} },
    .{ "URL", {} },            .{ "URLSearchParams", {} }, .{ "TextEncoder", {} },           .{ "TextDecoder", {} },
    .{ "Proxy", {} },          .{ "Reflect", {} },         .{ "ArrayBuffer", {} },           .{ "SharedArrayBuffer", {} },
    .{ "DataView", {} },       .{ "Uint8Array", {} },      .{ "Int8Array", {} },             .{ "Uint16Array", {} },
    .{ "Int16Array", {} },     .{ "Uint32Array", {} },     .{ "Int32Array", {} },            .{ "Float32Array", {} },
    .{ "Float64Array", {} },   .{ "BigInt64Array", {} },   .{ "BigUint64Array", {} },        .{ "Intl", {} },
    .{ "eval", {} },           .{ "arguments", {} },       .{ "this", {} },
});

/// 함수 body와 파라미터로부터 closure 변수(외부 참조)를 추출한다.
///
/// 알고리즘:
///   1. 함수 이름 + 파라미터 이름 → locals 집합에 추가
///   2. body 내 지역 선언(var/let/const/function) 이름 → locals 집합에 추가
///   3. body 내 identifier_reference 이름 → refs 집합에 추가
///   4. refs - locals - JS_GLOBALS = closure 변수
pub fn collectClosureVars(
    self: *Transformer,
    body_idx: NodeIndex,
    params_start: u32,
    params_len: u32,
    func_name: ?[]const u8,
) Error![]const ClosureVar {
    var locals = std.StringHashMap(void).init(self.allocator);
    defer locals.deinit();
    var refs = std.StringHashMap(NodeIndex).init(self.allocator);
    defer refs.deinit();

    // 0. 함수 이름 → locals (자기 참조 제외: JS 스펙상 함수 이름은 body 내에서 접근 가능)
    if (func_name) |name| {
        if (name.len > 0) locals.put(name, {}) catch return error.OutOfMemory;
    }

    // 1. 파라미터 이름 수집
    var pi: u32 = 0;
    while (pi < params_len) : (pi += 1) {
        const param_raw = self.ast.extra_data.items[params_start + pi];
        const param_idx: NodeIndex = @enumFromInt(param_raw);
        if (!param_idx.isNone()) {
            try collectBindingNames(self, param_idx, &locals);
        }
    }

    // 2-3. body 순회: 지역 선언 → locals, 식별자 참조 → refs (NodeIndex 포함)
    try walkBodyForClosureAnalysis(self, body_idx, &locals, &refs, 0);

    // 4. refs - locals - globals = closure vars
    // name을 복제: string_table 슬라이스는 이후 addString 호출로 무효화될 수 있음
    var result: std.ArrayList(ClosureVar) = .empty;
    var iter = refs.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        if (locals.contains(name)) continue;
        if (isGlobal(name)) continue;
        // 사용자 설정 globals (옵션)도 closure에서 제외
        var is_user_global = false;
        for (self.options.worklet_globals) |g| {
            if (std.mem.eql(u8, g, name)) {
                is_user_global = true;
                break;
            }
        }
        if (is_user_global) continue;
        const duped = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        try result.append(self.allocator, .{ .name = duped, .ref_idx = entry.value_ptr.* });
    }

    // 정렬 (결정론적 출력)
    std.mem.sort(ClosureVar, result.items, {}, struct {
        fn lessThan(_: void, a: ClosureVar, b: ClosureVar) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
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
        // arrow params without type annotations are parsed as expressions then
        // converted via coverExpressionToAssignmentTarget:
        //   identifier_reference → assignment_target_identifier
        .binding_identifier, .identifier_reference, .assignment_target_identifier => {
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
        .rest_element, .spread_element => {
            try collectBindingNames(self, node.data.unary.operand, locals);
        },
        .assignment_pattern, .assignment_expression => {
            // default value: left = pattern/identifier, right = default
            try collectBindingNames(self, node.data.binary.left, locals);
        },
        else => {},
    }
}

/// 별도 스코프로 body를 순회하고, free variable만 outer refs에 병합한다.
/// function/arrow/method의 공통 "scoped traversal + merge" 패턴.
/// param_nodes: 파라미터로 처리할 NodeIndex raw 값들 (collectAllIdentifiers로 수집).
fn walkScopedBody(
    self: *Transformer,
    body_idx: NodeIndex,
    param_nodes: []const u32,
    outer_locals: *std.StringHashMap(void),
    outer_refs: *std.StringHashMap(NodeIndex),
    depth: u32,
) Error!void {
    var inner_locals = std.StringHashMap(void).init(self.allocator);
    defer inner_locals.deinit();

    for (param_nodes) |raw| {
        try collectAllIdentifiers(self, @enumFromInt(raw), &inner_locals, 0);
    }

    var inner_refs = std.StringHashMap(NodeIndex).init(self.allocator);
    defer inner_refs.deinit();
    try walkBodyForClosureAnalysis(self, body_idx, &inner_locals, &inner_refs, depth + 1);

    var iter = inner_refs.iterator();
    while (iter.next()) |entry| {
        if (!inner_locals.contains(entry.key_ptr.*) and !outer_locals.contains(entry.key_ptr.*)) {
            outer_refs.put(entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
        }
    }
}

/// 노드 트리에서 모든 identifier (identifier_reference, binding_identifier 등)를 수집.
/// params에서 binding names를 추출하는 용도. generic 순회.
fn collectAllIdentifiers(self: *Transformer, idx: NodeIndex, locals: *std.StringHashMap(void), depth: u32) Error!void {
    if (idx.isNone()) return;
    if (depth > 32) return;
    if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;

    const node = self.ast.getNode(idx);
    switch (node.tag) {
        .identifier_reference, .binding_identifier, .assignment_target_identifier => {
            const name = self.ast.getText(node.data.string_ref);
            if (name.len > 0) locals.put(name, {}) catch return error.OutOfMemory;
            return;
        },
        else => {},
    }
    // generic 순회
    const kind = node.tag.dataKind();
    switch (kind) {
        .leaf => {},
        .unary => {
            if (!node.data.unary.operand.isNone()) try collectAllIdentifiers(self, node.data.unary.operand, locals, depth + 1);
        },
        .binary => {
            try collectAllIdentifiers(self, node.data.binary.left, locals, depth + 1);
            try collectAllIdentifiers(self, node.data.binary.right, locals, depth + 1);
        },
        .ternary => {
            try collectAllIdentifiers(self, node.data.ternary.a, locals, depth + 1);
            try collectAllIdentifiers(self, node.data.ternary.b, locals, depth + 1);
            try collectAllIdentifiers(self, node.data.ternary.c, locals, depth + 1);
        },
        .list => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                if (list.start + i < self.ast.extra_data.items.len)
                    try collectAllIdentifiers(self, @enumFromInt(self.ast.extra_data.items[list.start + i]), locals, depth + 1);
            }
        },
        .extra => {
            const e = node.data.extra;
            for (node.tag.extraChildOffsets()) |offset| {
                if (self.ast.hasExtra(e, @as(u32, offset) + 1))
                    try collectAllIdentifiers(self, @enumFromInt(self.ast.extra_data.items[e + offset]), locals, depth + 1);
            }
            for (node.tag.extraListOffsets()) |lo| {
                if (!self.ast.hasExtra(e, @as(u32, lo[1]) + 1)) continue;
                const ls = self.ast.extra_data.items[e + lo[0]];
                const ll = self.ast.extra_data.items[e + lo[1]];
                var li: u32 = 0;
                while (li < ll) : (li += 1) {
                    if (ls + li < self.ast.extra_data.items.len)
                        try collectAllIdentifiers(self, @enumFromInt(self.ast.extra_data.items[ls + li]), locals, depth + 1);
                }
            }
        },
    }
}

/// body를 재귀 순회하여 지역 선언(locals)과 식별자 참조(refs)를 수집한다.
///
/// Generic AST walker: nodeLayout() 메타데이터를 사용하여 모든 노드 타입을 자동 순회.
/// 특수 처리가 필요한 노드(함수, 변수, catch, method, object_property)만 명시적으로 처리하고,
/// 나머지는 layout 기반으로 자식 노드를 재귀 순회한다.
fn walkBodyForClosureAnalysis(
    self: *Transformer,
    idx: NodeIndex,
    locals: *std.StringHashMap(void),
    refs: *std.StringHashMap(NodeIndex),
    depth: u32,
) Error!void {
    if (idx.isNone()) return;
    if (depth > 64) return;
    if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;

    const node = self.ast.getNode(idx);
    const tag = node.tag;

    // --- 특수 처리 노드 ---
    switch (tag) {
        // 식별자 참조 수집
        .identifier_reference => {
            const name = self.ast.getText(node.data.string_ref);
            if (name.len > 0) {
                refs.put(name, idx) catch return error.OutOfMemory;
            }
            return;
        },

        // 중첩 함수/arrow/method: 별도 스코프로 body를 순회하여 외부 참조를 수집.
        // __initData.code에 body가 포함되므로, 그 안의 free variable을
        // worklet closure에 전파해야 함 (Babel scope chain과 동일).
        .function_declaration, .function_expression, .function => {
            const e = node.data.extra;
            if (tag == .function_declaration) {
                try collectBindingNames(self, @enumFromInt(self.ast.extra_data.items[e]), locals);
            }
            if (!self.ast.hasExtra(e, 4)) return;
            const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 3]);
            if (body_idx.isNone()) return;
            // name + params → param_nodes (extra_data 슬라이스 + name 앞에 추가)
            const p_start = self.ast.extra_data.items[e + 1];
            const p_len = self.ast.extra_data.items[e + 2];
            // name(e[0])은 항상 포함, params는 extra_data 슬라이스
            // 두 소스를 합치기 위해 단일 배열 사용은 불가 → 두 번 호출 대신 inline 처리
            var fn_locals = std.StringHashMap(void).init(self.allocator);
            defer fn_locals.deinit();
            try collectAllIdentifiers(self, @enumFromInt(self.ast.extra_data.items[e]), &fn_locals, 0); // name
            var fpi: u32 = 0;
            while (fpi < p_len) : (fpi += 1) {
                if (p_start + fpi < self.ast.extra_data.items.len)
                    try collectAllIdentifiers(self, @enumFromInt(self.ast.extra_data.items[p_start + fpi]), &fn_locals, 0);
            }
            var fn_refs = std.StringHashMap(NodeIndex).init(self.allocator);
            defer fn_refs.deinit();
            try walkBodyForClosureAnalysis(self, body_idx, &fn_locals, &fn_refs, depth + 1);
            var fr_iter = fn_refs.iterator();
            while (fr_iter.next()) |entry| {
                if (!fn_locals.contains(entry.key_ptr.*) and !locals.contains(entry.key_ptr.*)) {
                    refs.put(entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
                }
            }
            return;
        },
        .arrow_function_expression => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 2)) return;
            const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 1]);
            if (body_idx.isNone()) return;
            // arrow params: formal_parameters 노드를 param_node로 전달
            try walkScopedBody(self, body_idx, &.{self.ast.extra_data.items[e]}, locals, refs, depth);
            return;
        },
        .method_definition => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 4)) return;
            const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[e + 3]);
            if (body_idx.isNone()) return;
            const p_start = self.ast.extra_data.items[e + 1];
            const p_len = self.ast.extra_data.items[e + 2];
            if (p_start + p_len <= self.ast.extra_data.items.len) {
                try walkScopedBody(self, body_idx, self.ast.extra_data.items[p_start .. p_start + p_len], locals, refs, depth);
            }
            return;
        },

        // 변수 선언: binding name → locals, init → generic 순회
        .variable_declarator => {
            const e = node.data.extra;
            if (!self.ast.hasExtra(e, 3)) return;
            try collectBindingNames(self, @enumFromInt(self.ast.extra_data.items[e]), locals);
            // init(offset 2)만 순회 (name은 binding, type_ann은 TS 타입)
            try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + 2]), locals, refs, depth + 1);
            return;
        },

        // catch: param → locals, body만 순회
        .catch_clause => {
            try collectBindingNames(self, node.data.binary.left, locals);
            try walkBodyForClosureAnalysis(self, node.data.binary.right, locals, refs, depth + 1);
            return;
        },

        // object_property: binary = [key, value]
        // shorthand { x } → key는 참조 (value=none)
        // long-form { key: value } → value 순회 + computed key도 순회 ([expr]: value)
        .object_property => {
            if (node.data.binary.right.isNone()) {
                try walkBodyForClosureAnalysis(self, node.data.binary.left, locals, refs, depth + 1);
            } else {
                // computed key [expr] → expr 안의 identifier도 순회
                const key_idx = node.data.binary.left;
                if (!key_idx.isNone()) {
                    const key_node = self.ast.getNode(key_idx);
                    if (key_node.tag == .computed_property_key) {
                        try walkBodyForClosureAnalysis(self, key_idx, locals, refs, depth + 1);
                    }
                }
                try walkBodyForClosureAnalysis(self, node.data.binary.right, locals, refs, depth + 1);
            }
            return;
        },

        // TS/Flow type expression: 값(left)만 순회, 타입(right) 무시.
        // parser가 binary(left=expr, right=type)로 저장하지만 layout은 extra로 정의되어
        // generic walker가 자식을 찾지 못하므로 명시적 처리 필요.
        .ts_as_expression,
        .ts_satisfies_expression,
        .ts_type_assertion,
        .ts_instantiation_expression,
        .flow_as_expression,
        .flow_type_cast_expression,
        => {
            try walkBodyForClosureAnalysis(self, node.data.binary.left, locals, refs, depth + 1);
            return;
        },

        // static member: object만 순회 (property는 외부 참조가 아님)
        .static_member_expression, .private_field_expression => {
            const me = node.data.extra;
            if (self.ast.hasExtra(me, 2)) {
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[me]), locals, refs, depth + 1);
            }
            return;
        },

        else => {},
    }

    // --- Generic 순회: nodeLayout() 기반 ---
    const kind = tag.dataKind();
    switch (kind) {
        .leaf => {},
        .unary => {
            if (!node.data.unary.operand.isNone()) {
                try walkBodyForClosureAnalysis(self, node.data.unary.operand, locals, refs, depth + 1);
            }
        },
        .binary => {
            try walkBodyForClosureAnalysis(self, node.data.binary.left, locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, node.data.binary.right, locals, refs, depth + 1);
        },
        .ternary => {
            try walkBodyForClosureAnalysis(self, node.data.ternary.a, locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, node.data.ternary.b, locals, refs, depth + 1);
            try walkBodyForClosureAnalysis(self, node.data.ternary.c, locals, refs, depth + 1);
        },
        .list => {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                if (list.start + i >= self.ast.extra_data.items.len) break;
                try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[list.start + i]), locals, refs, depth + 1);
            }
        },
        .extra => {
            const e = node.data.extra;
            // child_offsets: 직접 NodeIndex 자식
            for (tag.extraChildOffsets()) |offset| {
                if (self.ast.hasExtra(e, @as(u32, offset) + 1)) {
                    try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[e + offset]), locals, refs, depth + 1);
                }
            }
            // list_offsets: 간접 NodeIndex 리스트 (e.g. args, statements)
            for (tag.extraListOffsets()) |lo| {
                const start_off = lo[0];
                const len_off = lo[1];
                if (!self.ast.hasExtra(e, @as(u32, len_off) + 1)) continue;
                const list_start = self.ast.extra_data.items[e + start_off];
                const list_len = self.ast.extra_data.items[e + len_off];
                var li: u32 = 0;
                while (li < list_len) : (li += 1) {
                    if (list_start + li >= self.ast.extra_data.items.len) break;
                    try walkBodyForClosureAnalysis(self, @enumFromInt(self.ast.extra_data.items[list_start + li]), locals, refs, depth + 1);
                }
            }
        },
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
fn buildPropAssignment(self: *Transformer, func_name_span: Span, prop_name: []const u8, value: NodeIndex, func_name_node_idx: NodeIndex) Error!NodeIndex {
    const zero_span = Span{ .start = 0, .end = 0 };

    // funcName (원본 binding_identifier의 symbol_id를 복사하여 scope hoisting rename 지원)
    const obj_ref = try self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = func_name_span,
        .data = .{ .string_ref = func_name_span },
    });
    if (!func_name_node_idx.isNone()) {
        // 원본 함수의 binding_identifier에서 symbol_id 복사
        const func_node = self.ast.getNode(func_name_node_idx);
        const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[func_node.data.extra]);
        self.copySymbolId(name_idx, obj_ref);
    }

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
/// 반환: 4개의 expression_statement NodeIndex 배열 (caller가 trailing_nodes에 추가)
pub fn buildWorkletPropertyAssignments(
    self: *Transformer,
    func_name: []const u8,
    closure_vars: []const ClosureVar,
    init_code: []const u8,
    hash: u32,
    source_location: []const u8,
    /// 원본 함수 노드 인덱스. 이 노드의 name span을 사용하면
    /// codegen의 scope hoisting rename이 자동 적용된다.
    func_node_idx: NodeIndex,
) Error![5]NodeIndex {
    // 원본 함수의 binding_identifier span 사용 (scope hoisting rename 호환)
    const func_name_span = blk: {
        if (!func_node_idx.isNone()) {
            const func_node = self.ast.getNode(func_node_idx);
            const name_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[func_node.data.extra]);
            if (!name_idx.isNone()) {
                const name_node = self.ast.getNode(name_idx);
                if (name_node.tag == .binding_identifier) {
                    break :blk name_node.data.string_ref;
                }
            }
        }
        // fallback: 새 span 생성
        break :blk try self.ast.addString(func_name);
    };
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
    const hash_stmt = try buildPropAssignment(self, func_name_span, "__workletHash", hash_node, func_node_idx);

    // 2. funcName.__closure = { var1: var1, var2: var2, ... };
    const closure_obj = try buildClosureObject(self, closure_vars);
    const closure_stmt = try buildPropAssignment(self, func_name_span, "__closure", closure_obj, func_node_idx);

    // 3. funcName.__initData = { code: "...", location: "..." };
    const init_data_obj = try buildInitDataObject(self, init_code, source_location, zero_span);
    const init_data_stmt = try buildPropAssignment(self, func_name_span, "__initData", init_data_obj, func_node_idx);

    // 4. funcName.__stackDetails = [];
    // Worklets runtime이 __DEV__ 모드에서 registerWorkletStackDetails(hash, __stackDetails)를
    // 호출하므로, 빈 배열이라도 설정해야 crash 방지.
    const empty_array = try self.ast.addNode(.{
        .tag = .array_expression,
        .span = zero_span,
        .data = .{ .list = try self.ast.addNodeList(&.{}) },
    });
    const stack_stmt = try buildPropAssignment(self, func_name_span, "__stackDetails", empty_array, func_node_idx);

    // 5. funcName.__pluginVersion = "<version>";
    // Reanimated dev mode가 jsVersion과 대조 (serializable.native.ts:464) —
    // 불일치 시 WorkletsError throw. 번들러가 사용자 react-native-worklets 버전을
    // 전달하지 않으면 WORKLET_PLUGIN_VERSION fallback.
    // 매 worklet당 allocPrint 방지를 위해 Transformer.init에서 pre-computed span 사용.
    const version_span = self.worklet_plugin_version_span orelse try self.ast.addString("\"" ++ WORKLET_PLUGIN_VERSION ++ "\"");
    const version_node = try self.ast.addNode(.{
        .tag = .string_literal,
        .span = version_span,
        .data = .{ .string_ref = version_span },
    });
    const version_stmt = try buildPropAssignment(self, func_name_span, "__pluginVersion", version_node, func_node_idx);

    return .{ hash_stmt, closure_stmt, init_data_stmt, stack_stmt, version_stmt };
}

/// Babel react-native-worklets/plugin 호환을 위한 worklet 플러그인 버전.
/// Babel은 package.json의 version을 주입 — ZTS는 정적 문자열 사용.
pub const WORKLET_PLUGIN_VERSION = "zts-0.0.1";

/// { var1: var1, var2: var2, ... } 객체 리터럴 노드를 생성한다.
/// explicit key-value 형식으로 생성하고, value의 identifier_reference에
/// 원본 참조의 symbol_id를 복사하여 scope hoisting rename을 지원한다.
fn buildClosureObject(self: *Transformer, closure_vars: []const ClosureVar) Error!NodeIndex {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    const zero_span = Span{ .start = 0, .end = 0 };

    for (closure_vars) |cv| {
        const name_span = try self.ast.addString(cv.name);
        // key: identifier (property name — rename 대상 아님)
        const key = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });
        // value: identifier_reference (scope hoisting rename 대상)
        const value = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });
        // 원본 참조의 symbol_id 복사 → scope hoisting rename 시 자동 갱신
        // (ref_idx는 walkBodyForClosureAnalysis에서 항상 유효한 identifier_reference 노드)
        self.copySymbolId(cv.ref_idx, value);
        // explicit key-value: { hue2rgb: hue2rgb } → rename 시 { hue2rgb: hue2rgb$1 }
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

const string_escape = @import("../../string_escape.zig");

fn escapeStringForJs(allocator: std.mem.Allocator, input: []const u8) Error![]const u8 {
    return string_escape.escapeToOwned(allocator, input);
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
    closure_vars: []const ClosureVar,
    params_start: u32,
    params_len: u32,
    flags: u32,
) Error![]const u8 {
    const zero_span = Span{ .start = 0, .end = 0 };

    // closure destructuring: const { v1, v2 } = this.__closure;
    var new_body_idx = body_idx;
    if (closure_vars.len > 0) {
        const destr_stmt = try buildClosureDestructuring(self, closure_vars, zero_span);
        new_body_idx = try self.prependStatementsToBody(body_idx, &.{destr_stmt});
    }

    // synthetic function: function funcName(params) { ...body... }
    const name_span = try self.ast.addString(func_name);
    const name_node = try self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
    const none = @intFromEnum(NodeIndex.none);

    const synthetic_func = try self.addExtraNode(.function_declaration, zero_span, &.{
        @intFromEnum(name_node),    params_start, params_len,
        @intFromEnum(new_body_idx), flags,        none,
    });

    // 단일 문장 프로그램 생성
    const prog_list = try self.ast.addNodeList(&.{synthetic_func});
    const program = try self.ast.addNode(.{
        .tag = .program,
        .span = zero_span,
        .data = .{ .list = prog_list },
    });

    // Codegen으로 code string 생성 (minified, TS 타입 스트리핑 완료된 AST 사용)
    const codegen_mod = @import("../../codegen/codegen.zig");
    var codegen = codegen_mod.Codegen.initWithOptions(self.allocator, &self.ast, .{
        .minify_whitespace = true,
    });
    const code = codegen.generate(program) catch return error.OutOfMemory;
    // codegen의 buf는 codegen이 소유 → 복제 필요
    const duped = self.allocator.dupe(u8, code) catch return error.OutOfMemory;
    codegen.deinit();
    return duped;
}

/// const { var1, var2, ... } = this.__closure; 문을 생성한다.
fn buildClosureDestructuring(self: *Transformer, closure_vars: []const ClosureVar, zero_span: Span) Error!NodeIndex {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);
    const none = @intFromEnum(NodeIndex.none);

    // object binding pattern: { var1, var2, ... }
    for (closure_vars) |cv| {
        const name_span = try self.ast.addString(cv.name);
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
