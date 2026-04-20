//! Private field name mangler (#1632 Phase 1).
//!
//! class body 내부의 `#private` 식별자를 class 별 독립 범위로 짧은 이름 (`#a`, `#b`, …,
//! `#a0`, `#a1`, …) 으로 교체한다. JS 언어 규약상 private name 은 **자신을 선언한
//! class body 바깥에서는 referenceable 하지 않다** — 따라서 외부 이름 충돌 걱정 없이
//! per-class 안전하게 rename.
//!
//! svelte-mount-min 실측: `#commit_callbacks`, `#maybe_dirty_effects` 같은 긴 이름이
//! 10+회 사용되어 전체 번들에 2077 B 축적. 이 패스만으로 ~2KB 절감.
//!
//! 구현:
//!   - 각 class body 안의 `private_identifier` 를 descent-walk 로 수집 (nested class 는
//!     내부 private scope 가 독립이므로 walk 경계에서 멈춤 — nested class 는 재귀 진입).
//!   - 수집된 name → 새 이름 map 을 만든 뒤, body 를 다시 walk 하며 각 private_identifier
//!     노드의 `span` 을 string_table 에 추가한 새 이름 span 으로 교체.
//!   - codegen 은 private_identifier 의 span 을 그대로 출력 (`writeSpan`) 하므로 AST 만
//!     갱신하면 최종 출력에 mangle 이 반영됨.
//!
//! **안전성 (보수적 skip)**:
//!   - class body 어딘가에 direct `eval(...)` 호출이 있으면 skip — eval 이 private name 을
//!     동적으로 참조할 수 있음 (실제론 eval 안에서 private 접근 불가하지만 보수적).
//!   - TS `declare class` 는 emit 대상 아님 — parser 가 이미 walk 안 함.
//!   - decorator metadata 에 영향 — `emit_decorator_metadata` 와 private field 조합은 드물어
//!     현 단계에서 별도 처리 없음 (추후 필요 시 class-level skip).

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Ast = ast_mod.Ast;
const Span = @import("../lexer/token.zig").Span;
const ast_walk = @import("../parser/ast_walk.zig");

/// 모든 class 의 private field 이름을 mangle 한다. ast 를 in-place 수정.
pub fn manglePrivateFields(ast: *Ast) void {
    var i: u32 = 0;
    while (i < ast.nodes.items.len) : (i += 1) {
        const tag = ast.nodes.items[i].tag;
        if (tag == .class_declaration or tag == .class_expression) {
            processClass(ast, i);
        }
    }
}

fn processClass(ast: *Ast, class_ni: u32) void {
    const class = ast.nodes.items[class_ni];
    const e = class.data.extra;
    // ClassExtra.body = 2
    if (!ast.hasExtra(e, 2)) return;
    const body_idx: NodeIndex = @enumFromInt(ast.readExtra(e, 2));
    if (body_idx.isNone()) return;
    const body_ni = @intFromEnum(body_idx);
    if (body_ni >= ast.nodes.items.len) return;
    if (ast.nodes.items[body_ni].tag != .class_body) return;

    // 보수적 safety: body 안 direct eval 이 있으면 전체 skip.
    if (containsDirectEval(ast, body_idx)) return;

    // Phase 1: body 안 private_identifier 수집 (nested class 제외).
    // Ordered HashMap — 등장 순서대로 rename 할당해 결정론적 결과.
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer names.deinit(ast.allocator);
    collectPrivateNames(ast, body_idx, &names);

    if (names.count() == 0) return;

    // Phase 2: rename 할당 — `#a`, `#b`, ..., `#z`, `#A`, ... `#a0`, `#a1`, ...
    // 원본 이름보다 짧아지는 경우만 rename (2 글자 이상). 대부분 private field 는
    // `#name` 식으로 5자 이상이라 rename 이득.
    // 새 span 은 string_table 에 저장 — AST allocator 가 소유.
    var renames: std.StringHashMapUnmanaged(Span) = .empty;
    defer renames.deinit(ast.allocator);
    var counter: u32 = 0;
    for (names.keys()) |orig| {
        var buf: [8]u8 = undefined;
        const new_text = formatPrivateName(&buf, counter) orelse break;
        if (new_text.len >= orig.len) {
            // 원본보다 길어지면 rename 이득 없음 — skip (원본 유지)
            counter += 1;
            continue;
        }
        const new_span = ast.addString(new_text) catch break;
        renames.put(ast.allocator, orig, new_span) catch break;
        counter += 1;
    }

    if (renames.count() == 0) return;

    // Phase 3: private_identifier 의 span 교체.
    applyRenames(ast, body_idx, &renames);
}

/// class body 안의 private_identifier 이름 수집 (nested class 는 독립 scope 라 제외 —
/// 재귀 `processClass` 에서 별도 처리).
fn collectPrivateNames(ast: *const Ast, idx: NodeIndex, out: *std.StringArrayHashMapUnmanaged(void)) void {
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return;
    const node = ast.nodes.items[ni];

    if (node.tag == .private_identifier) {
        const text = ast.getText(node.span);
        out.put(ast.allocator, text, {}) catch {};
        return;
    }

    // nested class / class expression 은 내부 private 이 독립 — skip.
    if (node.tag == .class_declaration or node.tag == .class_expression) return;

    var it = ast_walk.children(ast, node);
    while (it.next()) |child| {
        if (child.isNone()) continue;
        collectPrivateNames(ast, child, out);
    }
}

fn applyRenames(ast: *Ast, idx: NodeIndex, renames: *const std.StringHashMapUnmanaged(Span)) void {
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return;
    const node = ast.nodes.items[ni];

    if (node.tag == .private_identifier) {
        const text = ast.getText(node.span);
        if (renames.get(text)) |new_span| {
            // span 과 data.string_ref 둘 다 — codegen 은 string_ref 를 읽음.
            ast.nodes.items[ni].span = new_span;
            ast.nodes.items[ni].data = .{ .string_ref = new_span };
        }
        return;
    }

    // nested class 는 외부 rename 적용 안 함.
    if (node.tag == .class_declaration or node.tag == .class_expression) return;

    var it = ast_walk.children(ast, node);
    while (it.next()) |child| {
        if (child.isNone()) continue;
        applyRenames(ast, child, renames);
    }
}

/// Direct `eval("...")` 호출이 class body 안에 있는지 보수적 탐지. 있으면 private mangle
/// 전체 skip (eval 이 private name 을 동적으로 재작성할 가능성에 대비 — 실제 runtime 에선
/// eval 안에서 private 접근이 language level 로 금지되어 있지만 안전 측면 보수 유지).
fn containsDirectEval(ast: *const Ast, idx: NodeIndex) bool {
    const ni = @intFromEnum(idx);
    if (ni >= ast.nodes.items.len) return false;
    const node = ast.nodes.items[ni];

    if (node.tag == .call_expression) {
        // callee 가 identifier_reference "eval" 인지
        const e = node.data.extra;
        if (ast.hasExtra(e, 0)) {
            const callee_ni = ast.readExtra(e, 0);
            if (callee_ni < ast.nodes.items.len) {
                const callee = ast.nodes.items[callee_ni];
                if (callee.tag == .identifier_reference and
                    std.mem.eql(u8, ast.getText(callee.span), "eval")) return true;
            }
        }
    }

    // Nested class 는 자체 eval 이 있어도 그 class 의 처리 문제 — outer 에 영향 없음.
    if (node.tag == .class_declaration or node.tag == .class_expression) return false;

    var it = ast_walk.children(ast, node);
    while (it.next()) |child| {
        if (child.isNone()) continue;
        if (containsDirectEval(ast, child)) return true;
    }
    return false;
}

/// counter -> `#a`, `#b`, ..., `#z`, `#A`, ..., `#Z`, `#a0`, `#a1`, ...
/// 52 개 이후엔 `#a0`, `#a1`, ... 로 숫자 접미사. 충분.
fn formatPrivateName(buf: []u8, counter: u32) ?[]const u8 {
    const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    buf[0] = '#';
    if (counter < letters.len) {
        buf[1] = letters[counter];
        return buf[0..2];
    }
    const idx = counter - @as(u32, letters.len);
    const first = letters[idx % letters.len];
    const suffix = idx / letters.len;
    buf[1] = first;
    const formatted = std.fmt.bufPrint(buf[2..], "{d}", .{suffix}) catch return null;
    return buf[0 .. 2 + formatted.len];
}

test "formatPrivateName basic" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("#a", formatPrivateName(&buf, 0).?);
    try std.testing.expectEqualStrings("#b", formatPrivateName(&buf, 1).?);
    try std.testing.expectEqualStrings("#z", formatPrivateName(&buf, 25).?);
    try std.testing.expectEqualStrings("#A", formatPrivateName(&buf, 26).?);
    try std.testing.expectEqualStrings("#Z", formatPrivateName(&buf, 51).?);
    try std.testing.expectEqualStrings("#a0", formatPrivateName(&buf, 52).?);
    try std.testing.expectEqualStrings("#b0", formatPrivateName(&buf, 53).?);
}
