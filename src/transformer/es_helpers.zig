//! ES 다운레벨링 공통 헬퍼
//!
//! 임시 변수 생성, void 0, null 비교 등 여러 ES 버전 변환에서 공유하는 유틸리티.
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower_class.go (privateTempRef 패턴)
//! - `== null` vs `=== null`: JS에서 `x == null`은 null과 undefined 모두 체크 (loose equality)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

/// 인덱스로부터 임시 변수명 생성: _a, _b, _c, ..., _a2, _b2, ...
/// makeTempVarSpan과 hoistTempVars에서 공용.
pub fn tempVarName(idx: u32, buf: *[16]u8) []const u8 {
    const letter: u8 = 'a' + @as(u8, @intCast(idx % 26));
    const cycle = idx / 26;
    return if (cycle == 0)
        std.fmt.bufPrint(buf, "_{c}", .{letter}) catch "_"
    else
        std.fmt.bufPrint(buf, "_{c}{d}", .{ letter, cycle + 1 }) catch "_";
}

/// 임시 변수명 생성: _a, _b, _c, ..., _a2, _b2, ...
pub fn makeTempVarSpan(self: anytype) !Span {
    const idx = self.temp_var_counter;
    self.temp_var_counter += 1;
    var buf: [16]u8 = undefined;
    const name = tempVarName(idx, &buf);
    return self.ast.addString(name);
}

/// 임시 변수 identifier_reference 노드 생성.
pub fn makeTempVarRef(self: anytype, span: Span, node_span: Span) !NodeIndex {
    return self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = node_span,
        .data = .{ .string_ref = span },
    });
}

/// left 노드가 단순 식별자(부작용 없음)인지 판단.
pub fn isSimpleIdentifier(self: anytype, left_idx: NodeIndex) bool {
    const left_node = self.ast.getNode(left_idx);
    return left_node.tag == .identifier_reference;
}

/// `void 0` 노드를 새 AST에 생성.
pub fn makeVoidZero(self: anytype, span: Span) !NodeIndex {
    const zero_span = try self.ast.addString("0");
    const zero_node = try self.ast.addNode(.{
        .tag = .numeric_literal,
        .span = zero_span,
        .data = .{ .none = 0 },
    });
    const void_extra = try self.ast.addExtras(&.{
        @intFromEnum(zero_node),
        @intFromEnum(token_mod.Kind.kw_void),
    });
    return self.ast.addNode(.{
        .tag = .unary_expression,
        .span = span,
        .data = .{ .extra = void_extra },
    });
}

/// 식을 괄호로 감싼 parenthesized_expression 생성.
pub fn makeParenExpr(self: anytype, inner: NodeIndex, span: Span) !NodeIndex {
    return self.ast.addNode(.{
        .tag = .parenthesized_expression,
        .span = span,
        .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
    });
}

/// 이름 문자열로 identifier_reference 노드 생성.
/// addString + addNode를 한 번에 수행.
pub fn makeIdentifierRef(self: anytype, name: []const u8) !NodeIndex {
    const name_span = try self.ast.addString(name);
    return self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
}

/// Span으로 identifier_reference 노드 생성 (이미 addString된 span 사용).
pub fn makeIdentifierRefFromSpan(self: anytype, name_span: Span) !NodeIndex {
    return self.ast.addNode(.{
        .tag = .identifier_reference,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
}

/// obj.prop static member expression 생성.
/// extra = [object, property, flags=0]
pub fn makeStaticMember(self: anytype, obj: NodeIndex, prop: NodeIndex, span: Span) !NodeIndex {
    const me = try self.ast.addExtras(&.{ @intFromEnum(obj), @intFromEnum(prop), 0 });
    return self.ast.addNode(.{
        .tag = .static_member_expression,
        .span = span,
        .data = .{ .extra = me },
    });
}

/// obj[prop] computed member expression 생성.
/// 문자열 키("aria-busy")나 숫자 키처럼 dot notation이 불가능한 경우 사용.
/// extra = [object, property, flags=0]
pub fn makeComputedMember(self: anytype, obj: NodeIndex, prop: NodeIndex, span: Span) !NodeIndex {
    const me = try self.ast.addExtras(&.{ @intFromEnum(obj), @intFromEnum(prop), 0 });
    return self.ast.addNode(.{
        .tag = .computed_member_expression,
        .span = span,
        .data = .{ .extra = me },
    });
}

/// 프로퍼티 키의 타입에 따라 static(dot) 또는 computed(bracket) member expression 생성.
/// string_literal, numeric_literal → bracket notation (_ref["aria-busy"], _ref[0])
/// 그 외 (identifier 등) → dot notation (_ref.key)
pub fn makeMemberFromKey(self: anytype, obj: NodeIndex, prop: NodeIndex, key_tag: ast_mod.Node.Tag, span: Span) !NodeIndex {
    return switch (key_tag) {
        .string_literal, .numeric_literal => makeComputedMember(self, obj, prop, span),
        else => makeStaticMember(self, obj, prop, span),
    };
}

/// ast의 key_idx로부터 obj.key 또는 obj[key] member expression 생성.
/// computed_property_key → 내부 표현식을 unwrap하여 bracket notation.
/// string_literal, numeric_literal → bracket notation.
/// 그 외 (identifier) → dot notation (symbol 전파 없음 — 프로퍼티 이름은 리네이밍 대상이 아님).
pub fn makeMemberFromKeyIdx(self: anytype, obj: NodeIndex, key_idx: NodeIndex, span: Span) !NodeIndex {
    const key_node = self.ast.getNode(key_idx);
    if (key_node.tag == .computed_property_key) {
        const inner = try self.visitNode(key_node.data.unary.operand);
        return makeComputedMember(self, obj, inner, span);
    } else {
        // 프로퍼티 키는 문자열 이름이므로 visitNode(symbol 전파) 대신 span만 복사.
        // destructuring { polyfillGlobal: renamed } → _ref.polyfillGlobal 에서
        // linker가 polyfillGlobal → polyfillGlobal$4 로 잘못 리네이밍하는 것을 방지.
        const new_key = try makeIdentifierRefFromSpan(self, key_node.data.string_ref);
        return makeMemberFromKey(self, obj, new_key, key_node.tag, span);
    }
}

/// callee(args...) call expression 생성.
/// extra = [callee, args_start, args_len, flags=0]
pub fn makeCallExpr(self: anytype, callee: NodeIndex, args: []const NodeIndex, span: Span) !NodeIndex {
    const args_list = try self.ast.addNodeList(args);
    const call_extra = try self.ast.addExtras(&.{
        @intFromEnum(callee), args_list.start, args_list.len, 0,
    });
    return self.ast.addNode(.{
        .tag = .call_expression,
        .span = span,
        .data = .{ .extra = call_extra },
    });
}

/// u32 값으로 numeric_literal 노드 생성.
pub fn makeNumericLiteral(self: anytype, value: u32) !NodeIndex {
    var buf: [16]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
    const num_span = try self.ast.addString(str);
    return self.ast.addNode(.{
        .tag = .numeric_literal,
        .span = num_span,
        .data = .{ .none = 0 },
    });
}

/// 문자열 리터럴 노드를 새 AST에 생성. text는 따옴표 포함 (예: "\"hello\"").
pub fn buildStringNode(self: anytype, text: []const u8, _: Span) !NodeIndex {
    const str_span = try self.ast.addString(text);
    return self.ast.addNode(.{
        .tag = .string_literal,
        .span = str_span,
        .data = .{ .string_ref = str_span },
    });
}

/// `base == null` 노드를 새 AST에 생성.
pub fn makeEqNull(self: anytype, base: NodeIndex, span: Span) !NodeIndex {
    const null_span = try self.ast.addString("null");
    const null_node = try self.ast.addNode(.{
        .tag = .null_literal,
        .span = null_span,
        .data = .{ .none = 0 },
    });
    return self.ast.addNode(.{
        .tag = .binary_expression,
        .span = span,
        .data = .{ .binary = .{
            .left = base,
            .right = null_node,
            .flags = @intFromEnum(token_mod.Kind.eq2),
        } },
    });
}

/// binding_identifier 노드 생성 (변수 바인딩용).
/// span은 이미 addString된 이름 span.
pub fn makeBindingIdentifier(self: anytype, name_span: Span) !NodeIndex {
    return self.ast.addNode(.{
        .tag = .binding_identifier,
        .span = name_span,
        .data = .{ .string_ref = name_span },
    });
}

/// variable_declarator 노드 생성 (binding + optional init).
/// extra = [binding, type_annotation(none), init]
pub fn makeDeclarator(self: anytype, binding: NodeIndex, init: NodeIndex, span: Span) !NodeIndex {
    const de = try self.ast.addExtras(&.{
        @intFromEnum(binding), @intFromEnum(NodeIndex.none), @intFromEnum(init),
    });
    return self.ast.addNode(.{
        .tag = .variable_declarator,
        .span = span,
        .data = .{ .extra = de },
    });
}

/// variable_declaration 노드 생성 (var 키워드, declarators 배열).
/// kind_flags: 0 = var, 1 = let, 2 = const
pub fn makeVarDeclaration(self: anytype, declarators: []const NodeIndex, kind_flags: u32, span: Span) !NodeIndex {
    const decl_list = try self.ast.addNodeList(declarators);
    const var_extra = try self.ast.addExtras(&.{ kind_flags, decl_list.start, decl_list.len });
    return self.ast.addNode(.{
        .tag = .variable_declaration,
        .span = span,
        .data = .{ .extra = var_extra },
    });
}

/// expression을 expression_statement로 감싸기.
pub fn makeExprStmt(self: anytype, expr: NodeIndex, span: Span) !NodeIndex {
    return self.ast.addNode(.{
        .tag = .expression_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
    });
}

// ============================================================
// Object spread lowering 공용 헬퍼
// ============================================================

/// Object.assign(arg0, arg1, ...) 호출 노드를 생성.
/// es2018, jsx_lowering 등에서 공용.
pub fn makeObjectAssignCall(self: anytype, args: []const NodeIndex, span: Span) !NodeIndex {
    const obj_ref = try makeIdentifierRef(self, "Object");
    const assign_ref = try makeIdentifierRef(self, "assign");
    const callee = try makeStaticMember(self, obj_ref, assign_ref, span);
    return makeCallExpr(self, callee, args, span);
}

/// 이미 변환된 프로퍼티 목록(ast 노드, spread 포함)을 Object.assign()으로 변환.
///
/// { a: 1, ...obj, b: 2 } → Object.assign({ a: 1 }, obj, { b: 2 })
///
/// 알고리즘:
/// 1. 프로퍼티를 순회하면서 spread/non-spread 그룹으로 분할
/// 2. 연속된 non-spread 프로퍼티는 하나의 object literal로 묶음
/// 3. spread 프로퍼티는 피연산자만 추출 (spread를 벗김)
/// 4. 첫 번째 인자가 이미 object literal이면 그것이 target, 아니면 {}를 삽입
/// 5. Object.assign(target, ...groups) 호출로 변환
pub fn lowerObjectSpreadProps(self: anytype, properties: []const NodeIndex, span: Span) !NodeIndex {
    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var group_start: usize = scratch_top;

    for (properties) |prop_idx| {
        const prop = self.ast.getNode(prop_idx);
        if (prop.tag == .spread_element) {
            // 쌓아둔 non-spread 그룹을 object literal로 플러시
            if (self.scratch.items.len > group_start) {
                const obj = try makeObjectLiteral(self, self.scratch.items[group_start..], span);
                self.scratch.shrinkRetainingCapacity(group_start);
                try self.scratch.append(self.allocator, obj);
                group_start = self.scratch.items.len;
            }

            // spread의 피연산자를 인자로 추가
            try self.scratch.append(self.allocator, prop.data.unary.operand);
            group_start = self.scratch.items.len;
        } else {
            // non-spread: 그룹에 추가
            try self.scratch.append(self.allocator, prop_idx);
        }
    }

    // 마지막 남은 non-spread 그룹 플러시
    if (self.scratch.items.len > group_start) {
        const obj = try makeObjectLiteral(self, self.scratch.items[group_start..], span);
        self.scratch.shrinkRetainingCapacity(group_start);
        try self.scratch.append(self.allocator, obj);
    }

    const args_slice = self.scratch.items[scratch_top..];

    // 첫 인자가 object literal이 아니면 빈 {}를 target으로 삽입
    const need_empty_target = args_slice.len == 0 or blk: {
        const first_node = self.ast.getNode(args_slice[0]);
        break :blk first_node.tag != .object_expression;
    };

    if (need_empty_target) {
        const empty_obj = try makeObjectLiteral(self, &.{}, span);
        try self.scratch.ensureUnusedCapacity(self.allocator, 1);
        const old_args_len = args_slice.len;
        if (old_args_len > 0) {
            self.scratch.appendAssumeCapacity(.none);
            const items = self.scratch.items;
            std.mem.copyBackwards(NodeIndex, items[scratch_top + 1 .. scratch_top + 1 + old_args_len], items[scratch_top .. scratch_top + old_args_len]);
        }
        self.scratch.items[scratch_top] = empty_obj;
    }

    const final_args = self.scratch.items[scratch_top..];
    return makeObjectAssignCall(self, final_args, span);
}

/// 프로퍼티 배열로 object_expression 생성 (spread 없는 단순 객체).
fn makeObjectLiteral(self: anytype, props: []const NodeIndex, span: Span) !NodeIndex {
    const list = try self.ast.addNodeList(props);
    return self.ast.addNode(.{
        .tag = .object_expression,
        .span = span,
        .data = .{ .list = list },
    });
}

// ============================================================
// Private Method 공용 헬퍼
// ============================================================

pub const PrivateMethodNames = struct {
    ws_name: []const u8,
    fn_name: []const u8,
};

/// "#bar" → { ws_name="_bar", fn_name="_bar_fn" }
/// allocator로 직접 할당하여 버퍼 크기 제한 없음.
pub fn makePrivateMethodNames(allocator: std.mem.Allocator, orig_name: []const u8) !PrivateMethodNames {
    const bare_name = orig_name[1..]; // # 제거
    const ws_name = try allocator.alloc(u8, 1 + bare_name.len);
    ws_name[0] = '_';
    @memcpy(ws_name[1..], bare_name);
    const fn_name = try allocator.alloc(u8, 1 + bare_name.len + 3);
    fn_name[0] = '_';
    @memcpy(fn_name[1 .. 1 + bare_name.len], bare_name);
    @memcpy(fn_name[1 + bare_name.len ..], "_fn");
    return .{ .ws_name = ws_name, .fn_name = fn_name };
}

/// var _name = new Constructor(); 선언 생성. (WeakMap, WeakSet 등)
pub fn buildWeakCollectionDecl(self: anytype, constructor_name: []const u8, var_name: []const u8, span: Span) !NodeIndex {
    const ctor_ref = try makeIdentifierRef(self, constructor_name);
    const empty_args = try self.ast.addNodeList(&.{});
    const new_extra = try self.ast.addExtras(&.{
        @intFromEnum(ctor_ref), empty_args.start, empty_args.len, 0,
    });
    const new_expr = try self.ast.addNode(.{
        .tag = .new_expression,
        .span = span,
        .data = .{ .extra = new_extra },
    });
    return self.buildVarDecl(var_name, new_expr, span);
}

/// method_definition → standalone function declaration으로 추출.
/// method_definition: extra = [key, params_start, params_len, body, flags, ...]
pub fn buildStandaloneFunc(self: anytype, name: []const u8, method_idx: NodeIndex, span: Span) !NodeIndex {
    const method_node = self.ast.getNode(method_idx);
    const me = method_node.data.extra;
    const params_start = self.ast.extra_data.items[me + 1];
    const params_len = self.ast.extra_data.items[me + 2];
    const body_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[me + 3]);

    const new_params = try self.visitExtraList(params_start, params_len);

    const new_body = try self.visitNode(body_idx);

    const name_span = try self.ast.addString(name);
    const name_node = try makeBindingIdentifier(self, name_span);

    const none = @intFromEnum(NodeIndex.none);
    const func_extra = try self.ast.addExtras(&.{
        @intFromEnum(name_node),
        new_params.start,
        new_params.len,
        @intFromEnum(new_body),
        0,
        none,
    });
    return self.ast.addNode(.{
        .tag = .function_declaration,
        .span = span,
        .data = .{ .extra = func_extra },
    });
}

/// __classPrivateMethodInit(this, _set) expression_statement 생성.
pub fn buildPrivateMethodInit(self: anytype, ws_name: []const u8, span: Span) !NodeIndex {
    self.runtime_helpers.class_private_method_init = true;
    const callee = try makeIdentifierRef(self, "__classPrivateMethodInit");
    const this_node = try self.ast.addNode(.{
        .tag = .this_expression,
        .span = span,
        .data = .{ .none = 0 },
    });
    const ws_ref = try makeIdentifierRef(self, ws_name);
    const call = try makeCallExpr(self, callee, &.{ this_node, ws_ref }, span);
    return makeExprStmt(self, call, span);
}

// ============================================================
// Async/Generator 공용 헬퍼
// ============================================================

/// expr을 body로 하는 function expression 생성: function() { return expr; }
pub fn wrapInFunction(self: anytype, expr: NodeIndex, span: Span) !NodeIndex {
    const ret = try self.ast.addNode(.{
        .tag = .return_statement,
        .span = span,
        .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
    });
    const body_list = try self.ast.addNodeList(&.{ret});
    const body_block = try self.ast.addNode(.{
        .tag = .block_statement,
        .span = span,
        .data = .{ .list = body_list },
    });
    const empty_params = try self.ast.addNodeList(&.{});
    const func_extra = try self.ast.addExtras(&.{
        @intFromEnum(NodeIndex.none),
        empty_params.start,
        empty_params.len,
        @intFromEnum(body_block),
        0,
        @intFromEnum(NodeIndex.none),
    });
    return self.ast.addNode(.{
        .tag = .function_expression,
        .span = span,
        .data = .{ .extra = func_extra },
    });
}

/// body를 감싸는 generator function expression 생성: function*() { ...body... }
pub fn buildGeneratorWrapper(self: anytype, body: NodeIndex, span: Span) !NodeIndex {
    const empty_params = try self.ast.addNodeList(&.{});
    const gen_extra = try self.ast.addExtras(&.{
        @intFromEnum(NodeIndex.none),
        empty_params.start,
        empty_params.len,
        @intFromEnum(body),
        ast_mod.FunctionFlags.is_generator,
        @intFromEnum(NodeIndex.none),
    });
    return self.ast.addNode(.{
        .tag = .function_expression,
        .span = span,
        .data = .{ .extra = gen_extra },
    });
}

/// __async(gen).call(this) — this 바인딩 보존.
pub fn buildAsyncHelperCall(self: anytype, gen_func: NodeIndex, span: Span) !NodeIndex {
    self.runtime_helpers.async_helper = true;
    const async_ref = try makeIdentifierRef(self, "__async");
    const inner_call = try makeCallExpr(self, async_ref, &.{gen_func}, span);
    const call_prop = try makeIdentifierRef(self, "call");
    const member = try makeStaticMember(self, inner_call, call_prop, span);
    const this_ref = try makeIdentifierRef(self, "this");
    return makeCallExpr(self, member, &.{this_ref}, span);
}
