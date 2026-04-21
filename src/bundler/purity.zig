//! ZTS Bundler — Expression Purity Analysis
//!
//! tree_shaker(모듈 수준)와 statement_shaker(문 수준) 양쪽에서 공유하는
//! 표현식 순수성 판정 로직. 순수 표현식은 side effect가 없어 안전하게 제거 가능.
//!
//! 판정 기준 (esbuild/rolldown 동일):
//!   - 리터럴, 식별자 참조, 함수/arrow 표현식 → 순수
//!   - 객체/배열 리터럴 → 원소가 모두 순수이면 순수 (computed key, spread 제외)
//!   - 삼항/이항/논리/단항 → 재귀 검사 (delete 제외)
//!   - 멤버 접근 → 순수 (getter side effect는 실전에서 극히 드물어 무시, esbuild 동일)
//!   - @__PURE__ call/new → 순수
//!   - 빌트인 pure 생성자 (Set/Map/WeakMap/WeakSet 등): callee가 unresolved
//!     global이고 인자가 모두 pure이면 순수 (esbuild isPrimitiveConstructor,
//!     rolldown is_primitive_constructor 동일). `unresolved_globals` 전달 시 활성화.
//!   - 나머지 → 보수적으로 불순

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const CallFlags = @import("../parser/ast.zig").CallFlags;
const Token = @import("../lexer/token.zig");

/// 재귀 깊이 제한. 초과 시 보수적으로 불순 처리.
const max_depth: u32 = 128;

/// 모듈별 unresolved 참조 집합 (semantic analyzer 산출).
/// 이 집합에 속한 이름은 이 모듈 스코프에서 선언/import가 없는 전역 참조.
/// `new Set()`의 `Set`이 이 집합에 있으면 shadowing 없이 전역 빌트인임이 확정된다.
pub const GlobalRefSet = std.StringHashMap(void);

/// NodeIndex를 받아 순수성을 판정한다.
/// `unresolved_globals`가 주어지면 빌트인 pure 생성자(`new Set()` 등)도 순수로 인식한다.
/// null이면 기존 보수적 동작 (`@__PURE__` 플래그가 있을 때만 call/new 순수).
pub fn isExprPure(ast: *const Ast, idx: NodeIndex, unresolved_globals: ?*const GlobalRefSet) bool {
    return isExprPureDepth(ast, idx, unresolved_globals, 0);
}

fn isExprPureDepth(ast: *const Ast, idx: NodeIndex, unresolved_globals: ?*const GlobalRefSet, depth: u32) bool {
    if (depth >= max_depth) return false;
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return true;
    return isNodePureDepth(ast, ast.nodes.items[@intFromEnum(idx)], unresolved_globals, depth);
}

/// Node를 받아 순수성을 판정한다.
pub fn isNodePure(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet) bool {
    return isNodePureDepth(ast, node, unresolved_globals, 0);
}

fn isNodePureDepth(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet, depth: u32) bool {
    if (depth >= max_depth) return false;
    const d = depth + 1;
    return switch (node.tag) {
        .boolean_literal,
        .null_literal,
        .numeric_literal,
        .string_literal,
        .bigint_literal,
        .regexp_literal,
        => true,

        .identifier_reference => true,

        .function_expression,
        .arrow_function_expression,
        => true,

        // class expression — extends/static 초기화에 side effect 가능
        .class_expression => false,

        .object_expression => isObjectPure(ast, node, unresolved_globals, d),
        .array_expression => isArrayPure(ast, node, unresolved_globals, d),

        .call_expression, .new_expression => isCallOrNewPure(ast, node, unresolved_globals, d),

        .parenthesized_expression => isExprPureDepth(ast, node.data.unary.operand, unresolved_globals, d),

        .conditional_expression => {
            const t = node.data.ternary;
            return isExprPureDepth(ast, t.a, unresolved_globals, d) and
                isExprPureDepth(ast, t.b, unresolved_globals, d) and
                isExprPureDepth(ast, t.c, unresolved_globals, d);
        },

        .binary_expression, .logical_expression => {
            return isExprPureDepth(ast, node.data.binary.left, unresolved_globals, d) and
                isExprPureDepth(ast, node.data.binary.right, unresolved_globals, d);
        },

        .unary_expression => {
            const e = node.data.extra;
            if (!ast.hasExtra(e, 1)) return false;
            const op_kind: u8 = @truncate(ast.readExtra(e, 1) & 0xFF);
            if (op_kind == @intFromEnum(Token.Kind.kw_delete)) return false;
            return isExprPureDepth(ast, @enumFromInt(ast.readExtra(e, 0)), unresolved_globals, d);
        },

        // 멤버 접근 — getter side effect는 무시 (esbuild 동일)
        .static_member_expression, .computed_member_expression => true,

        else => false,
    };
}

/// call/new expression 순수성. (oxc `known_globals.rs` 포팅)
///
/// 판정 순서:
///   1. `@__PURE__` 플래그 → 무조건 pure
///   2. callee 가 identifier_reference + unresolved global 이어야 함 (사용자 shadow 차단)
///   3. 이름별 category 판정:
///      - collection (Set/Map/WeakSet/WeakMap): `new` 전용 (call 은 throw). 인자는
///        엄격 — 무인자/null/undefined/ArrayExpression 만. 그 외는 iterator protocol
///        의 Symbol.iterator getter side-effect 를 놓칠 위험 있어 보수적 impure.
///      - dotcall_only (Symbol): call 전용 (new Symbol() 은 throw).
///      - unconditional / either (Object/Boolean/Array/Date/String + Error 계열):
///        new/call 양쪽 safe. 인자는 재귀 pure 검사.
fn isCallOrNewPure(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet, depth: u32) bool {
    // (1) @__PURE__ 플래그
    if (ast.hasExtra(node.data.extra, 3)) {
        if ((ast.readExtra(node.data.extra, 3) & CallFlags.is_pure) != 0) return true;
    }

    // (2) 빌트인 화이트리스트 — unresolved_globals 컨텍스트 + identifier_reference callee
    const globals = unresolved_globals orelse return false;
    if (!ast.hasExtra(node.data.extra, 2)) return false;

    const callee_idx: NodeIndex = @enumFromInt(ast.readExtra(node.data.extra, 0));
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.nodes.items[@intFromEnum(callee_idx)];
    if (callee.tag != .identifier_reference) return false;

    const name = ast.getText(callee.span);

    // 모듈 스코프에서 선언/import 없는 전역 참조여야 함.
    // 로컬 `const Set = ...` / `import { Set }` / `class Set {}` 는 shadow → unresolved
    // 에 없음 → 안전하게 false.
    if (!globals.contains(name)) return false;

    const kind = categorizeBuiltin(name);
    const is_new = node.tag == .new_expression;
    const args_start = ast.readExtra(node.data.extra, 1);
    const args_len = ast.readExtra(node.data.extra, 2);

    return switch (kind) {
        .unknown => false,
        .collection => blk: {
            if (!is_new) break :blk false; // `Set()` / `Map()` 등 call 은 TypeError
            break :blk isPureCollectionArgs(ast, name, args_start, args_len, unresolved_globals, depth);
        },
        .dotcall_only => blk: {
            if (is_new) break :blk false; // `new Symbol()` 은 TypeError
            break :blk allArgsPure(ast, args_start, args_len, unresolved_globals, depth);
        },
        .error_ctor => isPureErrorArgs(ast, args_start, args_len, unresolved_globals, depth),
        .unconditional, .either => allArgsPure(ast, args_start, args_len, unresolved_globals, depth),
    };
}

/// 빌트인 이름별 분류.
///
/// - `collection` (new 전용, strict args): `Set` / `Map` / `WeakSet` / `WeakMap`
///   call 로 쓰면 TypeError.
/// - `dotcall_only` (call 전용): `Symbol` — `new Symbol()` 은 TypeError.
/// - `unconditional` (new/call 어느 쪽도 safe, 인자 무관한 내부 연산만): `Object`,
///   `Boolean` — ToBoolean 은 user code 호출 없음.
/// - `either` (new/call 모두 safe, 인자는 재귀 pure): `Array`, `Date`, `String`.
/// - `error_ctor` (new/call 양쪽 OK 이지만 msg 인자가 Symbol 이면 TypeError throw —
///   ECMA-262 §20.5.1 Error constructor 가 `ToString(msg)` 호출, `ToString(Symbol)` 은
///   TypeError): `Error` + 하위 타입 (EvalError/RangeError/ReferenceError/SyntaxError/
///   TypeError/URIError). 인자가 Symbol 이 **아님** 을 정적으로 증명 가능할 때만 pure.
/// - `unknown`: 위 목록 외.
///
/// 제외된 것들:
/// - `RegExp(pattern, flags)` — invalid pattern SyntaxError 가능
/// - `BigInt(x)` — invalid value TypeError
/// - `Number(x)` — Symbol 피연산자에 ToNumber → TypeError
/// - `Proxy`, `WeakRef`, `Function` — 임의 사용자 코드 실행
/// - TypedArray (`Int8Array` 등) — iteration side-effect 가능
const BuiltinKind = enum { unknown, collection, dotcall_only, unconditional, either, error_ctor };

fn categorizeBuiltin(name: []const u8) BuiltinKind {
    const eql = std.mem.eql;
    if (eql(u8, name, "Set") or eql(u8, name, "Map") or eql(u8, name, "WeakSet") or eql(u8, name, "WeakMap")) {
        return .collection;
    }
    if (eql(u8, name, "Symbol")) return .dotcall_only;
    if (eql(u8, name, "Object") or eql(u8, name, "Boolean")) return .unconditional;
    if (eql(u8, name, "Array") or eql(u8, name, "Date") or eql(u8, name, "String")) return .either;
    if (eql(u8, name, "Error") or eql(u8, name, "EvalError") or eql(u8, name, "RangeError") or
        eql(u8, name, "ReferenceError") or eql(u8, name, "SyntaxError") or
        eql(u8, name, "TypeError") or eql(u8, name, "URIError")) return .error_ctor;
    return .unknown;
}

/// Collection constructor (new Set/Map/WeakSet/WeakMap) 의 인자 safety.
/// ECMAScript 명세상 인자는 단일 iterable — iterator protocol 발동이 Symbol.iterator
/// getter side-effect 를 트리거할 수 있어, 아래 형태만 pure:
/// - 무인자
/// - `null` literal
/// - 전역 `undefined` identifier
/// - ArrayExpression — Set/WeakSet 은 원소 각각 재귀 pure, Map/WeakMap 은 각 원소가
///   추가로 ArrayExpression ([k,v] 쌍) 이어야 + 재귀 pure.
///
/// 그 외 (identifier / call / member_expression / object_expression / spread) 는
/// iterator 가 custom 구현/Proxy/getter 일 수 있어 보수적 impure.
fn isPureCollectionArgs(
    ast: *const Ast,
    name: []const u8,
    args_start: u32,
    args_len: u32,
    unresolved_globals: ?*const GlobalRefSet,
    depth: u32,
) bool {
    if (args_len == 0) return true;
    if (args_len > 1) return false; // spec: 단일 인자. 초과면 보수적
    if (args_start >= ast.extra_data.items.len) return false;

    const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= ast.nodes.items.len) return false;
    const arg = ast.nodes.items[@intFromEnum(arg_idx)];

    return switch (arg.tag) {
        .null_literal => true,
        .identifier_reference => blk: {
            const arg_name = ast.getText(arg.span);
            if (!std.mem.eql(u8, arg_name, "undefined")) break :blk false;
            const g = unresolved_globals orelse break :blk false;
            break :blk g.contains("undefined");
        },
        .array_expression => blk: {
            const is_map = std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "WeakMap");
            const list = arg.data.list;
            if (list.start + list.len > ast.extra_data.items.len) break :blk false;
            for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_el| {
                const el_idx: NodeIndex = @enumFromInt(raw_el);
                if (el_idx.isNone()) continue; // elision NodeIndex.none
                if (@intFromEnum(el_idx) >= ast.nodes.items.len) break :blk false;
                const el = ast.nodes.items[@intFromEnum(el_idx)];
                if (el.tag == .elision) continue;
                if (el.tag == .spread_element) break :blk false;
                // Map/WeakMap: 각 원소가 [k,v] ArrayExpression 이어야
                if (is_map and el.tag != .array_expression) break :blk false;
                // 재귀 pure — foo()/identifier 등 side-effect 방지
                if (!isNodePureDepth(ast, el, unresolved_globals, depth + 1)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

/// Error 계열 생성자의 msg 인자 safety.
/// ECMA-262 §20.5.1 Error 는 `ToString(msg)` 호출 — Symbol 이면 TypeError throw.
/// msg 가 Symbol 이 아님을 정적으로 보장할 수 있는 케이스만 pure.
/// 기존 `canBeSymbol` 을 재사용 (literal/template_literal/array/object/function/unary/
/// binary/update 는 non-Symbol 확정, identifier/call/member 는 보수적 Symbol 가능).
/// - 무인자: 항상 pure
/// - 단일 msg 인자: non-Symbol 확정 + 재귀 pure
/// - 2개 이상 인자: 보수적 impure (spec: `options.cause` 는 실사용 드묾 + toString 부수효과 가능)
/// - `undefined` 전역 identifier 는 Symbol 아닌 게 확정이므로 특수 허용
fn isPureErrorArgs(
    ast: *const Ast,
    args_start: u32,
    args_len: u32,
    unresolved_globals: ?*const GlobalRefSet,
    depth: u32,
) bool {
    if (args_len == 0) return true;
    if (args_len > 1) return false;
    if (args_start >= ast.extra_data.items.len) return false;

    const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= ast.nodes.items.len) return false;
    const arg = ast.nodes.items[@intFromEnum(arg_idx)];
    if (arg.tag == .spread_element) return false;

    // Symbol 가능성 배제: canBeSymbol + 전역 undefined 특수 허용.
    const undef_ok = arg.tag == .identifier_reference and blk: {
        const name = ast.getText(arg.span);
        if (!std.mem.eql(u8, name, "undefined")) break :blk false;
        const g = unresolved_globals orelse break :blk false;
        break :blk g.contains("undefined");
    };
    if (!undef_ok and canBeSymbol(ast, arg_idx)) return false;

    return isNodePureDepth(ast, arg, unresolved_globals, depth);
}

/// 인자 전체가 pure + spread 없음 체크. collection 외 category 용.
fn allArgsPure(
    ast: *const Ast,
    args_start: u32,
    args_len: u32,
    unresolved_globals: ?*const GlobalRefSet,
    depth: u32,
) bool {
    if (args_len == 0) return true;
    if (args_start + args_len > ast.extra_data.items.len) return false;
    for (ast.extra_data.items[args_start .. args_start + args_len]) |raw| {
        const arg_idx: NodeIndex = @enumFromInt(raw);
        if (arg_idx.isNone() or @intFromEnum(arg_idx) >= ast.nodes.items.len) continue;
        const arg = ast.nodes.items[@intFromEnum(arg_idx)];
        if (arg.tag == .spread_element) return false;
        if (!isNodePureDepth(ast, arg, unresolved_globals, depth)) return false;
    }
    return true;
}

fn isObjectPure(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet, depth: u32) bool {
    const list = node.data.list;
    if (list.len == 0) return true;
    if (list.start + list.len > ast.extra_data.items.len) return false;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const prop_idx: NodeIndex = @enumFromInt(raw_idx);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) continue;
        const prop = ast.nodes.items[@intFromEnum(prop_idx)];
        if (prop.tag != .object_property) return false;
        const key_idx = prop.data.binary.left;
        if (!key_idx.isNone() and @intFromEnum(key_idx) < ast.nodes.items.len) {
            if (ast.nodes.items[@intFromEnum(key_idx)].tag == .computed_property_key) return false;
        }
        if (!isExprPureDepth(ast, prop.data.binary.right, unresolved_globals, depth)) return false;
    }
    return true;
}

fn isArrayPure(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet, depth: u32) bool {
    const list = node.data.list;
    if (list.len == 0) return true;
    if (list.start + list.len > ast.extra_data.items.len) return false;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const elem_idx: NodeIndex = @enumFromInt(raw_idx);
        if (elem_idx.isNone() or @intFromEnum(elem_idx) >= ast.nodes.items.len) continue;
        const elem = ast.nodes.items[@intFromEnum(elem_idx)];
        if (elem.tag == .spread_element) return false;
        if (!isNodePureDepth(ast, elem, unresolved_globals, depth)) return false;
    }
    return true;
}

/// variable declaration의 순수성 판정.
/// 모든 declarator의 초기값이 순수이면 순수.
pub fn isVarDeclPure(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet) bool {
    const e = node.data.extra;
    if (e + 2 >= ast.extra_data.items.len) return false;
    const list_start = ast.extra_data.items[e + 1];
    const list_len = ast.extra_data.items[e + 2];
    if (list_len == 0) return true;
    if (list_start + list_len > ast.extra_data.items.len) return false;
    const decls = ast.extra_data.items[list_start .. list_start + list_len];
    for (decls) |raw| {
        const idx: NodeIndex = @enumFromInt(raw);
        if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) continue;
        const decl = ast.nodes.items[@intFromEnum(idx)];
        if (decl.tag != .variable_declarator) return false;
        const de = decl.data.extra;
        if (de + 2 >= ast.extra_data.items.len) return false;
        const init_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de + 2]);
        if (init_idx.isNone()) continue;
        if (!isExprPureDepth(ast, init_idx, unresolved_globals, 0)) return false;
    }
    return true;
}

/// top-level statement가 side effects를 가지는지 판정.
/// tree_shaker, statement_shaker, stmt_info에서 공유.
pub fn stmtHasSideEffects(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet) bool {
    return switch (node.tag) {
        .function_declaration => false,
        .class_declaration => classHasSideEffects(ast, node, unresolved_globals),
        .variable_declaration => !isVarDeclPure(ast, node, unresolved_globals),
        .export_named_declaration => {
            const e = node.data.extra;
            if (e + 3 < ast.extra_data.items.len) {
                const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
                if (!decl_idx.isNone() and @intFromEnum(decl_idx) < ast.nodes.items.len) {
                    return stmtHasSideEffects(ast, ast.nodes.items[@intFromEnum(decl_idx)], unresolved_globals);
                }
                return false;
            }
            return true;
        },
        .export_default_declaration => {
            const inner_idx = node.data.unary.operand;
            if (inner_idx.isNone() or @intFromEnum(inner_idx) >= ast.nodes.items.len) return true;
            const inner = ast.nodes.items[@intFromEnum(inner_idx)];
            return switch (inner.tag) {
                .function_declaration => false,
                .class_declaration => classHasSideEffects(ast, inner, unresolved_globals),
                else => !isNodePureDepth(ast, inner, unresolved_globals, 0),
            };
        },
        .import_declaration, .empty_statement => false,
        .export_all_declaration => true,
        else => true,
    };
}

/// class declaration/expression의 side effect 판정.
/// esbuild ClassCanBeRemovedIfUnused 동일: extends + body 멤버 전체 검사.
/// 미사용 class는 순수하면 제거 가능 — 실제 사용 시 referenced_symbols로 포함됨.
pub fn classHasSideEffects(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet) bool {
    const e = node.data.extra;
    if (e + 7 >= ast.extra_data.items.len) return true;

    // extends 절이 불순이면 side-effect
    const super_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 1]);
    if (!isExprPureDepth(ast, super_idx, unresolved_globals, 0)) return true;

    // decorator가 있으면 side-effect
    const deco_len = ast.extra_data.items[e + 7];
    if (deco_len > 0) return true;

    // class body 멤버 순회
    const body_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e + 2]);
    if (body_idx.isNone()) return false;
    if (@intFromEnum(body_idx) >= ast.nodes.items.len) return true;

    const body_node = ast.nodes.items[@intFromEnum(body_idx)];
    if (body_node.tag != .class_body) return true;

    const members = body_node.data.list;
    if (members.start + members.len > ast.extra_data.items.len) return true;

    for (ast.extra_data.items[members.start .. members.start + members.len]) |raw_idx| {
        const mi: NodeIndex = @enumFromInt(raw_idx);
        if (mi.isNone() or @intFromEnum(mi) >= ast.nodes.items.len) continue;
        const member = ast.nodes.items[@intFromEnum(mi)];

        switch (member.tag) {
            .static_block => return true,
            .property_definition, .accessor_property => {
                const me = member.data.extra;
                if (me + 4 >= ast.extra_data.items.len) return true;
                if (computedKeyHasSideEffects(ast, me, unresolved_globals)) return true;
                // static field의 불순 초기화: static flag (bit 0)
                if ((ast.extra_data.items[me + 2] & 1) != 0) {
                    const init_idx: NodeIndex = @enumFromInt(ast.extra_data.items[me + 1]);
                    if (!isExprPureDepth(ast, init_idx, unresolved_globals, 0)) return true;
                }
                if (ast.extra_data.items[me + 4] > 0) return true; // decorator
            },
            .method_definition => {
                // method_definition: [key(0), params(1), body(2), flags(3), deco_start(4), deco_len(5)]
                const me = member.data.extra;
                if (me + 5 >= ast.extra_data.items.len) return true;
                if (computedKeyHasSideEffects(ast, me, unresolved_globals)) return true;
                if (ast.extra_data.items[me + 5] > 0) return true; // decorator
            },
            else => {},
        }
    }
    return false;
}

/// class member의 computed key가 불순인지 검사. extra_data[extra_offset]에서 key NodeIndex를 읽는다.
fn computedKeyHasSideEffects(ast: *const Ast, extra_offset: u32, unresolved_globals: ?*const GlobalRefSet) bool {
    if (extra_offset >= ast.extra_data.items.len) return true;
    const key_idx: NodeIndex = @enumFromInt(ast.extra_data.items[extra_offset]);
    if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len) return false;
    const key_node = ast.nodes.items[@intFromEnum(key_idx)];
    if (key_node.tag == .computed_property_key) {
        return !isExprPureDepth(ast, key_node.data.unary.operand, unresolved_globals, 0);
    }
    return false;
}

/// expression 이 **Symbol 값** 일 가능성이 있는지 정적 판정. 보수적 — 확실히 아니면 false,
/// 그 외는 true. 주로 template literal substitution 의 ToString 변환 시
/// `TypeError: Cannot convert a Symbol value to a string` 회피 판정에 쓴다.
///
/// 확실히 non-Symbol 케이스 (false):
///   - primitive 리터럴 (numeric/string/boolean/null/bigint/regex)
///   - template_literal (항상 String)
///   - array/object/function/arrow/class expression (항상 Object 아니면 non-Symbol)
///   - unary (`!`, `+`, `-`, `~`, `typeof`, `void`, `delete`) — 결과가 Boolean/Number/String/Undefined
///   - binary (산술/비교/bitwise/논리/nullish) — Number/Boolean/String/BigInt
///   - update (`++`/`--`) — Number/BigInt
///
/// Symbol 가능 (true, 보수적):
///   - identifier_reference, this, call/new, member, meta_property, 기타
pub fn canBeSymbol(ast: *const Ast, idx: NodeIndex) bool {
    return canBeSymbolDepth(ast, idx, 0);
}

fn canBeSymbolDepth(ast: *const Ast, idx: NodeIndex, depth: u32) bool {
    if (depth >= max_depth) return true;
    if (idx.isNone()) return false;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return true;
    const node = ast.nodes.items[ni];
    const d = depth + 1;
    return switch (node.tag) {
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regexp_literal,
        .template_literal,
        .array_expression,
        .object_expression,
        .function_expression,
        .arrow_function_expression,
        .class_expression,
        .unary_expression,
        .binary_expression,
        .update_expression,
        => false,

        .parenthesized_expression => canBeSymbolDepth(ast, node.data.unary.operand, d),

        .sequence_expression => blk: {
            const list = node.data.list;
            if (list.len == 0 or list.start + list.len > ast.extra_data.items.len) break :blk true;
            const last_raw = ast.extra_data.items[list.start + list.len - 1];
            break :blk canBeSymbolDepth(ast, @enumFromInt(last_raw), d);
        },

        .conditional_expression => blk: {
            const t = node.data.ternary;
            break :blk canBeSymbolDepth(ast, t.b, d) or canBeSymbolDepth(ast, t.c, d);
        },

        .logical_expression => canBeSymbolDepth(ast, node.data.binary.left, d) or
            canBeSymbolDepth(ast, node.data.binary.right, d),

        .assignment_expression => canBeSymbolDepth(ast, node.data.binary.right, d),

        else => true,
    };
}
