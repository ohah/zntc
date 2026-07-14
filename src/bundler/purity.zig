//! ZNTC Bundler — Expression Purity Analysis
//!
//! tree_shaker(모듈 수준)와 statement_shaker(문 수준) 양쪽에서 공유하는
//! 표현식 순수성 판정 로직. 순수 표현식은 side effect가 없어 안전하게 제거 가능.
//!
//! 판정 기준 (esbuild/rolldown 동일):
//!   - 리터럴, 식별자 참조, 함수/arrow 표현식 → 순수
//!   - 객체/배열 리터럴 → 원소가 모두 순수이면 순수 (computed key는 key/value 모두 순수할 때 허용, spread 제외)
//!   - 삼항/이항/논리/단항 → 재귀 검사 (delete 제외)
//!   - 멤버 접근 → 순수 (getter side effect는 실전에서 극히 드물어 무시, esbuild 동일)
//!   - @__PURE__ call/new → 순수
//!   - 빌트인 pure 생성자 (Set/Map/WeakMap/WeakSet 등): callee가 unresolved
//!     global이고 인자가 모두 pure이면 순수 (esbuild isPrimitiveConstructor,
//!     rolldown is_primitive_constructor 동일). `unresolved_globals` 전달 시 활성화.
//!   - 나머지 → 보수적으로 불순

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const CallFlags = @import("../parser/ast.zig").CallFlags;
const Token = @import("../lexer/token.zig");
const symbol_mod = @import("../semantic/symbol.zig");

/// 재귀 깊이 제한. 초과 시 보수적으로 불순 처리.
const max_depth: u32 = 128;

/// 모듈별 unresolved 참조 집합 (semantic analyzer 산출).
/// 이 집합에 속한 이름은 이 모듈 스코프에서 선언/import가 없는 전역 참조.
/// `new Set()`의 `Set`이 이 집합에 있으면 shadowing 없이 전역 빌트인임이 확정된다.
pub const GlobalRefSet = std.StringHashMapUnmanaged(void);

/// 사용자 지정 pure callee hint (`--pure:<callee>` / BuildOptions.pure).
///
/// 지원 패턴:
/// - `fnName` — `fnName(...)` / `new fnName(...)` 매칭
/// - `Ns.fn` — `Ns.fn(...)` 같은 static member callee 매칭
/// - `Ns.*` — 해당 namespace 하위의 임의 깊이 static member call 매칭
///   (`Ns.fn(...)`, `Ns.deep.fn(...)`)
/// Computed callee (`a["b"]()`)와 optional chain callee (`a?.()`/`a.b?.c()`)는 의도적으로 미매칭.
pub fn markUserPureCalls(ast: *Ast, pure_patterns: []const []const u8) void {
    if (pure_patterns.len == 0) return;
    for (ast.nodes.items) |node| {
        if (node.tag != .call_expression and node.tag != .new_expression) continue;
        const e = node.data.extra;
        if (!ast.hasExtra(e, 3)) continue;
        if ((ast.readExtra(e, 3) & CallFlags.optional_chain) != 0) continue;

        const callee_idx = ast.readExtraNode(e, 0);
        if (calleeMatchesUserPure(ast, callee_idx, pure_patterns)) {
            ast.extra_data.items[e + 3] |= CallFlags.is_pure;
        }
    }
}

pub fn clearPureCallFlags(ast: *Ast) void {
    for (ast.nodes.items) |node| {
        if (node.tag != .call_expression and node.tag != .new_expression) continue;
        const e = node.data.extra;
        if (!ast.hasExtra(e, 3)) continue;
        ast.extra_data.items[e + 3] &= ~@as(u32, CallFlags.is_pure);
    }
}

fn calleeMatchesUserPure(ast: *const Ast, callee_idx: NodeIndex, pure_patterns: []const []const u8) bool {
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return false;

    var buf: [256]u8 = undefined;
    const callee_name = calleePath(ast, callee_idx, &buf) orelse return false;
    for (pure_patterns) |pattern| {
        if (pattern.len == 0) continue;
        if (std.mem.endsWith(u8, pattern, ".*")) {
            const prefix = pattern[0 .. pattern.len - 1]; // keep trailing dot
            if (callee_name.len > prefix.len and std.mem.startsWith(u8, callee_name, prefix)) return true;
        } else if (std.mem.eql(u8, callee_name, pattern)) {
            return true;
        }
    }
    return false;
}

fn calleePath(ast: *const Ast, idx: NodeIndex, buf: []u8) ?[]const u8 {
    if (idx.isNone() or @intFromEnum(idx) >= ast.nodes.items.len) return null;
    const node = ast.nodes.items[@intFromEnum(idx)];
    return switch (node.tag) {
        .identifier_reference => ast.getText(node.span),
        .static_member_expression => staticMemberPath(ast, node, buf),
        .parenthesized_expression => calleePath(ast, node.data.unary.operand, buf),
        else => null,
    };
}

fn staticMemberPath(ast: *const Ast, node: Node, buf: []u8) ?[]const u8 {
    const e = node.data.extra;
    if (!ast.hasExtra(e, 2)) return null;
    const member_flags = ast.readExtra(e, 2);
    if ((member_flags & ast_mod.MemberFlags.optional_chain) != 0) return null;

    const object_idx = ast.readExtraNode(e, 0);
    const property_idx = ast.readExtraNode(e, 1);
    if (property_idx.isNone() or @intFromEnum(property_idx) >= ast.nodes.items.len) return null;
    const property = ast.nodes.items[@intFromEnum(property_idx)];
    if (property.tag != .identifier_reference) return null;

    const object_name = calleePath(ast, object_idx, buf) orelse return null;
    const property_name = ast.getText(property.span);
    if (object_name.len == 0 or property_name.len == 0) return null;
    if (object_name.len + 1 + property_name.len > buf.len) return null;

    if (object_name.ptr != buf.ptr) {
        @memcpy(buf[0..object_name.len], object_name);
    }
    buf[object_name.len] = '.';
    @memcpy(buf[object_name.len + 1 .. object_name.len + 1 + property_name.len], property_name);
    return buf[0 .. object_name.len + 1 + property_name.len];
}

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

        // class expression — class declaration 과 같은 side-effect 규칙을 적용.
        .class_expression => !classHasSideEffects(ast, node, unresolved_globals),

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
    if (isKnownPureStaticCall(ast, node, callee, unresolved_globals, depth)) return true;
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

fn isKnownPureStaticCall(
    ast: *const Ast,
    node: Node,
    callee: Node,
    unresolved_globals: ?*const GlobalRefSet,
    depth: u32,
) bool {
    if (node.tag != .call_expression) return false;
    if (callee.tag != .static_member_expression) return false;
    const member_extra = callee.data.extra;
    if (!ast.hasExtra(member_extra, 2)) return false;
    const member_flags = ast.readExtra(member_extra, 2);
    if ((member_flags & ast_mod.MemberFlags.optional_chain) != 0) return false;

    const object_idx = ast.readExtraNode(member_extra, 0);
    const property_idx = ast.readExtraNode(member_extra, 1);
    if (object_idx.isNone() or property_idx.isNone()) return false;
    if (@intFromEnum(object_idx) >= ast.nodes.items.len or @intFromEnum(property_idx) >= ast.nodes.items.len) return false;

    const object = ast.nodes.items[@intFromEnum(object_idx)];
    const property = ast.nodes.items[@intFromEnum(property_idx)];
    if (object.tag != .identifier_reference or property.tag != .identifier_reference) return false;
    if (!std.mem.eql(u8, ast.getText(object.span), "Object")) return false;
    const globals = unresolved_globals orelse return false;
    if (!globals.contains("Object")) return false;
    const property_name = ast.getText(property.span);

    const call_extra = node.data.extra;
    const args_start = ast.readExtra(call_extra, 1);
    const args_len = ast.readExtra(call_extra, 2);

    if (std.mem.eql(u8, property_name, "freeze")) {
        if (args_len != 1 or args_start >= ast.extra_data.items.len) return false;
        const arg_idx: NodeIndex = @enumFromInt(ast.extra_data.items[args_start]);
        return isKnownPureFreezeArg(ast, arg_idx, unresolved_globals, depth);
    }

    if (std.mem.eql(u8, property_name, "assign")) {
        if (args_len < 2 or args_start + args_len > ast.extra_data.items.len) return false;
        for (ast.extra_data.items[args_start .. args_start + args_len]) |raw_arg| {
            const arg_idx: NodeIndex = @enumFromInt(raw_arg);
            if (!isKnownPureAssignObjectArg(ast, arg_idx, unresolved_globals, depth)) return false;
        }
        return true;
    }

    return false;
}

fn isKnownPureFreezeArg(
    ast: *const Ast,
    arg_idx: NodeIndex,
    unresolved_globals: ?*const GlobalRefSet,
    depth: u32,
) bool {
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= ast.nodes.items.len) return false;
    const arg = ast.nodes.items[@intFromEnum(arg_idx)];
    const fresh_arg = switch (arg.tag) {
        .object_expression,
        .array_expression,
        .function_expression,
        .arrow_function_expression,
        .class_expression,
        => true,
        .parenthesized_expression => return isKnownPureFreezeArg(ast, arg.data.unary.operand, unresolved_globals, depth),
        else => false,
    };
    return fresh_arg and isNodePureDepth(ast, arg, unresolved_globals, depth);
}

fn isKnownPureAssignObjectArg(
    ast: *const Ast,
    arg_idx: NodeIndex,
    unresolved_globals: ?*const GlobalRefSet,
    depth: u32,
) bool {
    if (arg_idx.isNone() or @intFromEnum(arg_idx) >= ast.nodes.items.len) return false;
    const arg = ast.nodes.items[@intFromEnum(arg_idx)];
    return switch (arg.tag) {
        .object_expression => isPlainObjectLiteralPure(ast, arg, unresolved_globals, depth),
        .parenthesized_expression => isKnownPureAssignObjectArg(ast, arg.data.unary.operand, unresolved_globals, depth),
        else => false,
    };
}

fn isPlainObjectLiteralPure(
    ast: *const Ast,
    node: Node,
    unresolved_globals: ?*const GlobalRefSet,
    depth: u32,
) bool {
    const list = node.data.list;
    if (list.start + list.len > ast.extra_data.items.len) return false;

    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw_prop| {
        const prop_idx: NodeIndex = @enumFromInt(raw_prop);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) return false;
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
        switch (prop.tag) {
            .object_property => {
                const key_idx = prop.data.binary.left;
                if (computedKeyNodeHasSideEffects(ast, key_idx, unresolved_globals, depth)) return false;
                if (!isExprPureDepth(ast, Ast.objectPropertyValue(prop), unresolved_globals, depth)) return false;
            },
            .method_definition => {
                if (objectMethodHasSideEffects(ast, prop, unresolved_globals)) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn objectMethodHasSideEffects(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet) bool {
    const e = node.data.extra;
    if (e + ast_mod.MethodExtra.deco_len >= ast.extra_data.items.len) return true;
    if (computedKeyHasSideEffects(ast, e + ast_mod.MethodExtra.key, unresolved_globals)) return true;

    // Object literal methods/getters/setters create function values. Their params/body
    // are not evaluated while the object itself is constructed.
    return ast.extra_data.items[e + ast_mod.MethodExtra.deco_len] > 0;
}

fn computedKeyNodeHasSideEffects(
    ast: *const Ast,
    key_idx: NodeIndex,
    unresolved_globals: ?*const GlobalRefSet,
    depth: u32,
) bool {
    if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len) return false;
    const key_node = ast.nodes.items[@intFromEnum(key_idx)];
    if (key_node.tag != .computed_property_key) return false;
    return !isExprPureDepth(ast, key_node.data.unary.operand, unresolved_globals, depth);
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
        .expression_statement => exprStmtHasSideEffects(ast, node.data.unary.operand, unresolved_globals),
        .if_statement => ifStmtHasSideEffects(ast, node, unresolved_globals),
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
                // `export default <id>` 는 codegen 이 `_default$N = <id>` 할당을
                // emit 한다. <id> 가 다른 stmt (import / var) 로 선언된 경우
                // synthetic _default 심볼의 declarer 가 그 stmt 라 BFS 가
                // export_default_declaration 자체에 닿지 않아 `_default = <id>`
                // 가 emit 안 됨 (lodash-es lodash.default.js
                // `import lodash from './wrapperLodash.js'; export default lodash;`).
                // 익명 expression default (`export default {...}`) 는 synthetic
                // _default 심볼이 export_default_declaration 을 declarer 로 가져
                // 기존 isNodePureDepth fallback 그대로 두어 unused default 의
                // tslib-style DCE 보존.
                .identifier_reference => true,
                else => !isNodePureDepth(ast, inner, unresolved_globals, 0),
            };
        },
        .import_declaration, .empty_statement => false,
        .export_all_declaration => true,
        else => true,
    };
}

fn exprStmtHasSideEffects(ast: *const Ast, expr_idx: NodeIndex, unresolved_globals: ?*const GlobalRefSet) bool {
    if (expr_idx.isNone() or @intFromEnum(expr_idx) >= ast.nodes.items.len) return false;
    const expr = ast.nodes.items[@intFromEnum(expr_idx)];
    if (expr.tag == .assignment_expression) {
        return assignmentHasSideEffects(ast, expr, unresolved_globals);
    }
    return !isExprPureDepth(ast, expr_idx, unresolved_globals, 0);
}

fn assignmentHasSideEffects(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet) bool {
    const left_idx = node.data.binary.left;
    const right_idx = node.data.binary.right;
    if (left_idx.isNone() or @intFromEnum(left_idx) >= ast.nodes.items.len) return true;
    const left = ast.nodes.items[@intFromEnum(left_idx)];

    // A top-level assignment to an unresolved global can mutate global state. A bare
    // identifier (read or assignment-target form) that is not unresolved is a module-local
    // binding, so the statement can be dropped when no live export observes that binding.
    if (left.tag != .identifier_reference and left.tag != .assignment_target_identifier) return true;
    if (unresolved_globals) |globals| {
        if (globals.contains(ast.getText(left.span))) return true;
    }
    return !isExprPureDepth(ast, right_idx, unresolved_globals, 0);
}

fn ifStmtHasSideEffects(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet) bool {
    const data = node.data.ternary;
    if (!isExprPureDepth(ast, data.a, unresolved_globals, 0)) return true;
    return childStmtHasSideEffects(ast, data.b, unresolved_globals) or
        childStmtHasSideEffects(ast, data.c, unresolved_globals);
}

fn childStmtHasSideEffects(ast: *const Ast, idx: NodeIndex, unresolved_globals: ?*const GlobalRefSet) bool {
    if (idx.isNone()) return false;
    if (@intFromEnum(idx) >= ast.nodes.items.len) return true;
    const node = ast.nodes.items[@intFromEnum(idx)];
    if (node.tag == .block_statement) {
        const list = node.data.list;
        if (list.start + list.len > ast.extra_data.items.len) return true;
        for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
            if (childStmtHasSideEffects(ast, @enumFromInt(raw), unresolved_globals)) return true;
        }
        return false;
    }
    return stmtHasSideEffects(ast, node, unresolved_globals);
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
    return computedKeyNodeHasSideEffects(ast, key_idx, unresolved_globals, 0);
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

// ================================================================
// Statement-position removability (#4514)
// ================================================================
//
// `isExprPure` 는 **"이 표현식을 값으로 쓰는 게 안전한가"** 가 아니라 tree-shaking 용
// **"이 선언을 통째로 안 만들어도 되는가"** 를 본다. 그래서 esbuild 와 마찬가지로
// `identifier_reference` 와 member access 를 pure 로 친다.
//
// 반면 **이미 실행되기로 확정된 표현식을 삭제** 하는 패스(문 자리 DCE, dead-store 제거)에서는
// 그 완화가 곧 무성 오컴파일이다:
//   - `obj.p` — p 가 getter / Proxy trap 이면 삭제 = 호출 소실
//   - `a.b.c` — `a.b` 가 nullish 면 삭제 = 던져야 할 TypeError 소실
//   - `undeclaredGlobal` / TDZ 읽기 — 삭제 = ReferenceError 소실
//
// 그래서 그 패스들은 아래 **엄격 술어** 를 쓴다. 판정 불가는 전부 "유지"(false).

/// `isRemovableAtStmtPos` 가 필요로 하는 semantic 컨텍스트.
pub const StmtRemovalCtx = struct {
    /// AST node index → symbol index. null = 미해결 전역(또는 심볼 아님).
    symbol_ids: []const ?u32,
    symbols: []const symbol_mod.Symbol,
    unresolved_globals: ?*const GlobalRefSet,
};

pub const max_stmt_removable_depth: u32 = 128;

/// expression 의 **평가 자체를 통째로 없애도 관측 불가능한지** 판정한다.
///
/// **호출 site contract**: 결과값이 버려지는 자리 전용 —
///   - statement 자리 (`foo;`) 또는 `sequence_expression` 의 비마지막 원소
///   - dead store 의 RHS / 초기화자 (그 값을 읽는 코드가 없음이 별도로 증명된 경우)
///
/// call callee (`(0, f)()` 의 `0`) 처럼 값이 관측되는 자리에 쓰면 semantic 위반.
///
/// **판정 기준: 평가가 (a) 사용자 코드(getter / valueOf / toString / Symbol.toPrimitive /
/// Proxy trap)를 부르지 않고 (b) throw 하지 않는가.** 둘 다 확실할 때만 true.
/// 그래서 값 계산으로는 "순수" 해 보이는 것도 아래는 전부 거부한다:
///   - member access (`o.p`, `o[k]`) — getter / Proxy trap / nullish base TypeError
///   - 산술·관계·`==`·`in`·`instanceof` — ToPrimitive 가 valueOf/toString 을 부르고
///     Symbol 피연산자면 TypeError. 변환이 아예 없는 `===` / `!==` 만 허용.
///   - 단항 `-` / `+` / `~` — ToNumeric 이 valueOf 를 부른다. `!` / `void` / `typeof` 만 허용.
///   - 치환이 있는 template literal — ToString 이 toString 을 부른다.
///   - pure call/new 의 **인자** — pure 판정은 callee 만 본다. 인자는 따로 엄격 검사.
pub fn isRemovableAtStmtPos(ast: *const Ast, idx: NodeIndex, ctx: StmtRemovalCtx) bool {
    return isRemovableAtStmtPosDepth(ast, idx, ctx, 0);
}

pub fn isRemovableAtStmtPosDepth(ast: *const Ast, idx: NodeIndex, ctx: StmtRemovalCtx, depth: u32) bool {
    if (depth >= max_stmt_removable_depth) return false;
    if (idx.isNone()) return true;
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[ni];
    const d = depth + 1;

    return switch (node.tag) {
        .numeric_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .bigint_literal,
        .regexp_literal,
        .this_expression,
        .function_expression,
        .arrow_function_expression,
        => true,

        .identifier_reference => isIdentRemovableAtStmtPos(ni, ctx),

        .parenthesized_expression => isRemovableAtStmtPosDepth(ast, node.data.unary.operand, ctx, d),

        .unary_expression => blk: {
            const e = node.data.extra;
            if (!ast.hasExtra(e, 1)) break :blk false;
            const op_kind: u8 = @truncate(ast.readExtra(e, 1) & 0xFF);
            // `!` / `void` / `typeof` 만 사용자 코드를 절대 안 부른다.
            // `-x` / `+x` / `~x` 는 ToNumeric → valueOf/Symbol.toPrimitive 호출 + Symbol
            // 피연산자면 TypeError. `delete` 는 mutation.
            const op: Token.Kind = @enumFromInt(op_kind);
            switch (op) {
                .bang, .kw_void, .kw_typeof => {},
                else => break :blk false,
            }
            break :blk isRemovableAtStmtPosDepth(ast, @enumFromInt(ast.readExtra(e, 0)), ctx, d);
        },

        .binary_expression => blk: {
            // ToPrimitive 가 전혀 안 도는 연산만 허용 — `===` / `!==`.
            // 나머지(`+`, `-`, `<`, `==`, `in`, `instanceof` …)는 valueOf/toString 호출
            // 또는 TypeError 가 가능하다.
            const op: Token.Kind = @enumFromInt(node.data.binary.flags);
            switch (op) {
                .eq3, .neq2 => {},
                else => break :blk false,
            }
            break :blk isRemovableAtStmtPosDepth(ast, node.data.binary.left, ctx, d) and
                isRemovableAtStmtPosDepth(ast, node.data.binary.right, ctx, d);
        },

        // `&&` / `||` / `??` — ToBoolean / nullish 검사는 사용자 코드를 부르지 않는다.
        .logical_expression => isRemovableAtStmtPosDepth(ast, node.data.binary.left, ctx, d) and
            isRemovableAtStmtPosDepth(ast, node.data.binary.right, ctx, d),

        .conditional_expression => blk: {
            const t = node.data.ternary;
            break :blk isRemovableAtStmtPosDepth(ast, t.a, ctx, d) and
                isRemovableAtStmtPosDepth(ast, t.b, ctx, d) and
                isRemovableAtStmtPosDepth(ast, t.c, ctx, d);
        },

        .sequence_expression => blk: {
            const list = node.data.list;
            if (list.start + list.len > ast.extra_data.items.len) break :blk false;
            for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
                if (!isRemovableAtStmtPosDepth(ast, @enumFromInt(raw), ctx, d)) break :blk false;
            }
            break :blk true;
        },

        .object_expression => isObjectRemovableAtStmtPos(ast, node, ctx, d),
        .array_expression => isArrayRemovableAtStmtPos(ast, node, ctx, d),

        .template_literal => blk: {
            // **치환이 있으면 무조건 유지**. `` `${o}` `` 는 ToString(o) → o.toString() /
            // Symbol.toPrimitive 를 부르고, Symbol 피연산자면 TypeError 다. 치환이 없는
            // template(리터럴 조각뿐)만 삭제 가능하다.
            // (list.len==0 = transformer raw-span shorthand — 치환 없음.)
            const list = node.data.list;
            if (list.len == 0) break :blk true;
            if (list.start + list.len > ast.extra_data.items.len) break :blk false;
            for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
                if (raw >= ast.nodes.items.len) break :blk false;
                if (ast.nodes.items[raw].tag != .template_element) break :blk false; // 치환 있음
            }
            break :blk true;
        },

        // `@__PURE__` 또는 빌트인 화이트리스트로 pure 가 확정된 call/new. 그 판정은 **callee**
        // 만 보므로 인자는 여기서 따로 엄격 검사한다 — `String(o.p)` 의 getter, `new Set([o.p])`
        // 의 getter 가 그대로 사라지기 때문(#4514 와 같은 계열).
        .call_expression, .new_expression => isExprPure(ast, idx, ctx.unresolved_globals) and
            argsRemovableAtStmtPos(ast, node, ctx, d),

        else => false,
    };
}

/// `identifier_reference` 하나를 삭제해도 되는지. 삭제 시 사라지는 관측 가능한 효과는
/// **ReferenceError** 뿐이므로(값은 버려짐), 그 가능성을 전부 배제할 수 있을 때만 true.
fn isIdentRemovableAtStmtPos(ni: u32, ctx: StmtRemovalCtx) bool {
    if (ni >= ctx.symbol_ids.len) return false;
    // 미해결 전역 — 존재하지 않으면 읽는 순간 ReferenceError (#4514 증상 3).
    const sid = ctx.symbol_ids[ni] orelse return false;
    if (sid >= ctx.symbols.len) return false;
    const sym = ctx.symbols[sid];

    // top-level(scope 0) 바인딩과 import 는 live binding — `import * as ns` 등의 초기화
    // 순서를 건드릴 수 있고 module TDZ 도 가능하다. 보수적으로 유지.
    if (@intFromEnum(sym.scope_id) == 0) return false;
    if (sym.decl_flags.is_import) return false;

    // **TDZ** — `let` / `const` / `class` 는 선언이 *실행되기 전* 읽으면 ReferenceError 다.
    // 소스 위치 비교로는 못 잡는다: 선언보다 텍스트상 뒤에 있어도, 그 읽기가 hoisting 된
    // 함수 안에 있고 그 함수가 선언 실행 전에 불리면 TDZ 다
    // (`function o(){ h(); let x = 1; function h(){ let a = x; a = 2; } }`).
    // 참조 노드가 어느 실행 단위인지는 이 술어가 알 수 없으므로 **block-scoped 선언 읽기는
    // 통째로 유지**한다. `var` / 파라미터 / `catch` 바인딩 / function 선언은 TDZ 가 없어
    // 그대로 제거 대상 — DSE 수익은 유지된다.
    // (generator/async function 선언에도 block_scoped 가 서므로 `is_function` 으로 제외.)
    if (sym.decl_flags.block_scoped and !sym.decl_flags.is_function) return false;

    return true;
}

/// 객체 리터럴 생성이 삭제 가능한지. 값 슬롯은 평가되므로 재귀 검사하고, **computed key** 는
/// ToPropertyKey → ToPrimitive 로 사용자 `toString` 을 부를 수 있어 전부 거부한다.
/// 메서드/getter/setter 는 **정의만** 될 뿐 생성 시 호출되지 않으므로 본문은 안 본다.
fn isObjectRemovableAtStmtPos(ast: *const Ast, node: Node, ctx: StmtRemovalCtx, depth: u32) bool {
    const list = node.data.list;
    if (list.len == 0) return true;
    if (list.start + list.len > ast.extra_data.items.len) return false;

    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
        if (raw >= ast.nodes.items.len) return false;
        const prop = ast.nodes.items[raw];
        switch (prop.tag) {
            .object_property => {
                if (isComputedKey(ast, prop.data.binary.left)) return false;
                if (!isRemovableAtStmtPosDepth(ast, Ast.objectPropertyValue(prop), ctx, depth)) return false;
            },
            .method_definition => {
                const e = prop.data.extra;
                if (e + ast_mod.MethodExtra.deco_len >= ast.extra_data.items.len) return false;
                if (isComputedKey(ast, @enumFromInt(ast.extra_data.items[e + ast_mod.MethodExtra.key]))) return false;
                if (ast.extra_data.items[e + ast_mod.MethodExtra.deco_len] > 0) return false; // decorator
            },
            // spread (`{...x}`) 는 iterator/Proxy trap → 거부. 그 외 미지 tag 도 보수적 거부.
            else => return false,
        }
    }
    return true;
}

fn isComputedKey(ast: *const Ast, key_idx: NodeIndex) bool {
    if (key_idx.isNone() or @intFromEnum(key_idx) >= ast.nodes.items.len) return false;
    return ast.nodes.items[@intFromEnum(key_idx)].tag == .computed_property_key;
}

/// 배열 리터럴 생성이 삭제 가능한지. hole(elision)은 평가가 없고, spread 는 iterator protocol
/// (Symbol.iterator getter / next 호출) 이라 거부한다.
fn isArrayRemovableAtStmtPos(ast: *const Ast, node: Node, ctx: StmtRemovalCtx, depth: u32) bool {
    const list = node.data.list;
    if (list.len == 0) return true;
    if (list.start + list.len > ast.extra_data.items.len) return false;

    for (ast.extra_data.items[list.start .. list.start + list.len]) |raw| {
        const elem_idx: NodeIndex = @enumFromInt(raw);
        if (elem_idx.isNone()) continue; // hole
        if (@intFromEnum(elem_idx) >= ast.nodes.items.len) return false;
        const elem = ast.nodes.items[@intFromEnum(elem_idx)];
        if (elem.tag == .elision) continue;
        if (elem.tag == .spread_element) return false;
        if (!isRemovableAtStmtPosDepth(ast, elem_idx, ctx, depth)) return false;
    }
    return true;
}

/// pure 로 확정된 call/new 의 **인자** 가 전부 삭제 가능한지. `isExprPure` 의 인자 검사는
/// 완화된 tree-shaking 기준(member = pure)이고 `@__PURE__` 는 인자를 아예 안 본다.
fn argsRemovableAtStmtPos(ast: *const Ast, node: Node, ctx: StmtRemovalCtx, depth: u32) bool {
    const e = node.data.extra;
    if (!ast.hasExtra(e, 2)) return false;
    const args_start = ast.readExtra(e, 1);
    const args_len = ast.readExtra(e, 2);
    if (args_len == 0) return true;
    if (args_start + args_len > ast.extra_data.items.len) return false;

    for (ast.extra_data.items[args_start .. args_start + args_len]) |raw| {
        const arg_idx: NodeIndex = @enumFromInt(raw);
        if (arg_idx.isNone()) continue;
        if (@intFromEnum(arg_idx) >= ast.nodes.items.len) return false;
        if (ast.nodes.items[@intFromEnum(arg_idx)].tag == .spread_element) return false;
        if (!isRemovableAtStmtPosDepth(ast, arg_idx, ctx, depth)) return false;
    }
    return true;
}
