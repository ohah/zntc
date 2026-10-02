const std = @import("std");
const mangler = @import("mangler.zig");
const base54 = mangler.base54;
const isReservedOrGlobal = mangler.isReservedOrGlobal;
const Scope = @import("../semantic/scope.zig").Scope;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const SyntheticKind = @import("../semantic/symbol.zig").SyntheticKind;

test "base54: basic encoding" {
    var buf: [8]u8 = undefined;
    // 0 -> "e" (첫 번째 BASE54_CHARS 문자)
    try std.testing.expectEqualStrings("e", base54(0, &buf));
    // 1 -> "t"
    try std.testing.expectEqualStrings("t", base54(1, &buf));
    // 53 -> "$" (마지막 1글자)
    try std.testing.expectEqualStrings("$", base54(53, &buf));
    // 54 -> "ee" (2글자 시작)
    const two = base54(54, &buf);
    try std.testing.expect(two.len == 2);
    try std.testing.expect(two[0] == 'e');
}

test "#4819 mangle reserves fixed-name synthetic output bindings" {
    const allocator = std.testing.allocator;
    const Span = @import("../lexer/token.zig").Span;

    // Start directly at the two-character candidate to isolate the collision
    // without manufacturing thousands of ordinary bindings.
    var counter: u32 = 0;
    var buf: [8]u8 = undefined;
    while (!std.mem.eql(u8, base54(counter, &buf), "_N")) : (counter += 1) {}

    var root_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer root_map.deinit(allocator);
    try root_map.put(allocator, "outer", 0);
    var namespace_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer namespace_map.deinit(allocator);
    try namespace_map.put(allocator, "_N", 1);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ root_map, namespace_map };
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = true, .symbol_count = 1 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = true, .symbol_count = 1 },
    };
    var symbols = [_]Symbol{
        .{
            .name = .{ .start = 0, .end = 5 },
            .scope_id = @enumFromInt(0),
            .origin_scope = @enumFromInt(0),
            .kind = .variable_const,
            .declaration_span = Span{ .start = 0, .end = 5 },
            .reference_count = 10,
        },
        .{
            .name = .{ .start = 0, .end = 0 },
            .scope_id = @enumFromInt(1),
            .origin_scope = @enumFromInt(1),
            .kind = .parameter,
            .declaration_span = Span{ .start = 0, .end = 0 },
            .synthetic_kind = .namespace_iife_parameter,
            .synthetic_name = "_N",
        },
    };
    const fixed_kinds = [_]SyntheticKind{
        .namespace_iife_parameter,
        .enum_iife_parameter,
        .runtime_helper_preamble,
    };
    for (fixed_kinds) |kind| {
        symbols[1].synthetic_kind = kind;
        var result = try mangler.mangle(allocator, .{
            .scopes = &scopes,
            .symbols = &symbols,
            .scope_maps = &scope_maps,
            .references = &.{},
            .source = "outer",
            .starting_name_counter = counter,
        });
        defer result.deinit();

        try std.testing.expectEqual(@as(usize, 1), result.stats.slot_count);
        const outer_name = result.renames.get(0) orelse return error.MissingRename;
        try std.testing.expect(!std.mem.eql(u8, outer_name, "_N"));
    }
}

test "mangle reserves preserved short module names before skipping Phase A symbols" {
    const allocator = std.testing.allocator;
    const Span = @import("../lexer/token.zig").Span;

    var counter: u32 = 0;
    var buf: [8]u8 = undefined;
    while (!std.mem.eql(u8, base54(counter, &buf), "a")) : (counter += 1) {}

    var root_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer root_map.deinit(allocator);
    try root_map.put(allocator, "a", 0);
    var function_map: std.StringHashMapUnmanaged(usize) = .empty;
    defer function_map.deinit(allocator);
    try function_map.put(allocator, "outer", 1);
    const scope_maps = [_]std.StringHashMapUnmanaged(usize){ root_map, function_map };
    const scopes = [_]Scope{
        .{ .parent = .none, .kind = .global, .is_strict = true, .symbol_count = 1 },
        .{ .parent = @enumFromInt(0), .kind = .function, .is_strict = true, .symbol_count = 1 },
    };
    const symbols = [_]Symbol{
        .{
            .name = .{ .start = 0, .end = 1 },
            .scope_id = @enumFromInt(0),
            .origin_scope = @enumFromInt(0),
            .kind = .variable_const,
            .declaration_span = Span{ .start = 0, .end = 1 },
            .reference_count = 1,
        },
        .{
            .name = .{ .start = 1, .end = 6 },
            .scope_id = @enumFromInt(1),
            .origin_scope = @enumFromInt(1),
            .kind = .parameter,
            .declaration_span = Span{ .start = 1, .end = 6 },
            .reference_count = 1,
        },
    };
    var skip_symbols = try std.DynamicBitSet.initEmpty(allocator, symbols.len);
    defer skip_symbols.deinit();
    skip_symbols.set(0);

    var result = try mangler.mangle(allocator, .{
        .scopes = &scopes,
        .symbols = &symbols,
        .scope_maps = &scope_maps,
        .references = &.{},
        .source = "aouter",
        .skip_symbols = skip_symbols,
        .starting_name_counter = counter,
    });
    defer result.deinit();

    const outer_name = result.renames.get(1) orelse return error.MissingRename;
    try std.testing.expect(!std.mem.eql(u8, outer_name, "a"));
}

test "base54: 1글자 'e'/'m' 만 reserved (legacy CJS alias 충돌 방지)" {
    var buf: [8]u8 = undefined;
    // base54 첫 54개 (1글자) 중 'e' (idx 0) 와 'm' (idx 14) 만 reserved.
    // 다른 1글자 이름은 free.
    for (0..54) |i| {
        const name = base54(@intCast(i), &buf);
        const expect_reserved = name.len == 1 and (name[0] == 'e' or name[0] == 'm');
        try std.testing.expectEqual(expect_reserved, isReservedOrGlobal(name));
    }
}

test "isReservedOrGlobal" {
    try std.testing.expect(isReservedOrGlobal("do"));
    try std.testing.expect(isReservedOrGlobal("if"));
    try std.testing.expect(isReservedOrGlobal("in"));
    try std.testing.expect(isReservedOrGlobal("for"));
    try std.testing.expect(isReservedOrGlobal("var"));
    try std.testing.expect(isReservedOrGlobal("null"));
    try std.testing.expect(isReservedOrGlobal("true"));
    try std.testing.expect(isReservedOrGlobal("false"));
    try std.testing.expect(isReservedOrGlobal("this"));
    try std.testing.expect(isReservedOrGlobal("void"));
    try std.testing.expect(isReservedOrGlobal("class"));
    try std.testing.expect(isReservedOrGlobal("return"));
    try std.testing.expect(!isReservedOrGlobal("a"));
    try std.testing.expect(!isReservedOrGlobal("foo"));
    // #4312: strict mode(ESM) 에서 `eval` 은 BindingIdentifier 금지 → base54 가 배정 못 하게 reserve.
    try std.testing.expect(isReservedOrGlobal("eval"));
    // 'e', 'm' 은 legacy CJS alias path 용으로 reserved.
    try std.testing.expect(isReservedOrGlobal("e"));
    try std.testing.expect(isReservedOrGlobal("m"));
}

// #1618 / #1621: minify 모드에서 runtime helper 이름이 `$xx` 형태로 축약된다.
// base54가 사용자 심볼에 동일 이름을 배정하면 preamble 정의(`var $cj=...`, `var $tE=...`
// 등)를 덮어써 runtime 파괴. isReservedOrGlobal 에 전부 등록되어 nextBase54Name
// 가 자동 skip 해야 함.
// #1618 / #1621: runtime helper 축약 이름이 모두 mangler 예약 목록에 등록되어 있는지.
// `runtime_helpers.PAIRS` 가 단일 소스 — 빌드 타임에 순회해 drift 를 잡는다.
test "isReservedOrGlobal: all #1621 runtime helper short names registered" {
    const rt = @import("../runtime_helper_names.zig");
    inline for (rt.PAIRS) |p| {
        try std.testing.expect(isReservedOrGlobal(p.short));
    }
    // 경계 케이스: 정확히 일치할 때만 reserved (prefix/suffix, case 구별).
    // 주의: `$c` 는 CJS_FACTORY_MIN 이라 reserved (#3256 후 단축).
    try std.testing.expect(!isReservedOrGlobal("$j"));
    try std.testing.expect(!isReservedOrGlobal("$cjq"));
    try std.testing.expect(!isReservedOrGlobal("$te"));
    try std.testing.expect(!isReservedOrGlobal("$tc"));
    try std.testing.expect(!isReservedOrGlobal("$eX2"));
}

test "#4491 nextBase54Name: CJS 래퍼 파라미터 이름($e/$m)도 건너뛴다" {
    // 래퍼 파라미터는 helper 가 아니라 PAIRS 에 없다. 예약하지 않으면 mangler 가 모듈
    // 게터에 `$m` 을 배정하고, 다른 CJS 래퍼 안에서 그 게터를 참조하면 래퍼의 `$m`
    // 파라미터(= module 객체)가 게터를 섀도잉한다 → `TypeError: $m is not a function`.
    // **빌드도 파싱도 통과하고 런타임에만** 터지는 계열이라 재파싱 게이트로는 못 잡는다.
    const rt = @import("../runtime_helper_names.zig");
    const nextBase54Name = mangler.nextBase54Name;
    var buf: [8]u8 = undefined;
    var counter: u32 = 0;
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        const name = nextBase54Name(&counter, &buf);
        for (rt.CJS_WRAPPER_PARAM_NAMES) |s| {
            try std.testing.expect(!std.mem.eql(u8, name, s));
        }
    }
    // 이름 풀이 실제로 `$` 영역까지 내려오는지 (테스트가 헛돌지 않는지) 확인.
    try std.testing.expect(mangler.isReservedOrGlobal("$m"));
    try std.testing.expect(mangler.isReservedOrGlobal("$e"));
}

test "nextBase54Name: skips all runtime helper short names" {
    const rt = @import("../runtime_helper_names.zig");
    const nextBase54Name = mangler.nextBase54Name;
    var buf: [8]u8 = undefined;
    var counter: u32 = 0;
    // base54 에서 각 축약 이름이 나타나는 카운터를 모르므로 많은 이름을 생성해 검증.
    var i: usize = 0;
    while (i < 50_000) : (i += 1) {
        const name = nextBase54Name(&counter, &buf);
        for (rt.ALL_SHORT_NAMES) |s| {
            try std.testing.expect(!std.mem.eql(u8, name, s));
        }
    }
}

// `helperName` 분배 함수가 각 base_name 에 대해 올바른 축약 이름을 반환하는지.
// transformer 가 이 함수를 통해 AST identifier 이름을 결정하므로 정의 ↔ 매핑 drift 검증.
test "helperName: base_name → short mapping for every PAIR" {
    const rt = @import("../runtime_helper_names.zig");
    inline for (rt.PAIRS) |p| {
        const plain = if (std.mem.eql(u8, p.base, "__classPrivateFieldSet"))
            rt.NAMES.PRIVATE_FIELD_SET_LOCAL
        else
            p.base;
        try std.testing.expectEqualStrings(plain, rt.helperName(p.base, false));
        try std.testing.expectEqualStrings(p.short, rt.helperName(p.base, true));
    }
    // 알 수 없는 이름 → 원본 반환 (fallback 안전성)
    try std.testing.expectEqualStrings("__unknown", rt.helperName("__unknown", true));
}
