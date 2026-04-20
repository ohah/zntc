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

/// call/new expression 순수성.
/// 1) `@__PURE__` 플래그가 있으면 순수
/// 2) callee가 `new Set()`/`new Map()` 등 빌트인 pure 생성자이고 인자가 모두 순수이면 순수
fn isCallOrNewPure(ast: *const Ast, node: Node, unresolved_globals: ?*const GlobalRefSet, depth: u32) bool {
    // (1) @__PURE__ 플래그
    if (ast.hasExtra(node.data.extra, 3)) {
        if ((ast.readExtra(node.data.extra, 3) & CallFlags.is_pure) != 0) return true;
    }

    // (2) 빌트인 화이트리스트. unresolved_globals 컨텍스트가 있을 때만 활성.
    const globals = unresolved_globals orelse return false;
    if (!ast.hasExtra(node.data.extra, 2)) return false;

    const callee_idx: NodeIndex = @enumFromInt(ast.readExtra(node.data.extra, 0));
    if (callee_idx.isNone() or @intFromEnum(callee_idx) >= ast.nodes.items.len) return false;
    const callee = ast.nodes.items[@intFromEnum(callee_idx)];
    if (callee.tag != .identifier_reference) return false;

    const name = ast.getText(callee.span);
    if (!isPureBuiltinConstructor(name)) return false;

    // 모듈 스코프에서 선언/import가 없어야 전역 빌트인임이 확정된다.
    // 로컬 `const Set = ...` 또는 `import { Set }`가 있으면 unresolved에 없으므로 pure 판정 안 됨.
    if (!globals.contains(name)) return false;

    // 인자 순회: 모두 순수여야 함. spread는 iterator 호출 side effect가 있으므로 제외.
    const args_start = ast.readExtra(node.data.extra, 1);
    const args_len = ast.readExtra(node.data.extra, 2);
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

/// 빌트인 pure 생성자 이름. (esbuild `isPrimitiveConstructor`, rolldown `is_primitive_constructor`)
///
/// RegExp는 invalid pattern이 SyntaxError를 throw할 수 있어 제외.
/// Boolean/Number/String/BigInt는 coercion으로 인자 평가 외 부수효과 없지만
/// 실사용이 드물어 당장은 생략 (필요 시 추가).
fn isPureBuiltinConstructor(name: []const u8) bool {
    const pure_names = [_][]const u8{
        "Set",    "Map",   "WeakMap", "WeakSet",
        "Symbol", "Array", "Object",  "Date",
        "Error",
    };
    for (pure_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
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
