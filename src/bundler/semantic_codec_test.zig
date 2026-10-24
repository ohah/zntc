// semantic_codec_test.zig — #4438 PR2 semantic 직렬화 round-trip + fail-safe.

const std = @import("std");
const testing = std.testing;
const codec = @import("semantic_codec.zig");
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;
const Symbol = @import("../semantic/symbol.zig").Symbol;
const Scope = @import("../semantic/scope.zig").Scope;
const Reference = @import("../semantic/symbol.zig").Reference;
const Span = @import("../lexer/token.zig").Span;
const Scanner = @import("../lexer/scanner.zig").Scanner;
const Parser = @import("../parser/parser.zig").Parser;
const SemanticAnalyzer = @import("../semantic/analyzer.zig").SemanticAnalyzer;

test "semantic_codec: analyzer round-trip — relocatable 필드 보존" {
    const alloc = testing.allocator;
    const source = "const a = 1; function f(x) { let y = x + a; return y; } class C { m() {} } let z = f(2);";

    var scanner = try Scanner.init(alloc, source);
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(alloc, &parser.ast);
    defer ana.deinit();
    ana.enable_stmt_info = true;
    try ana.analyze();

    try testing.expect(ana.symbols.items.len > 0); // 비어있으면 검증 무의미
    ana.symbols.items[0].output_name_hint = "deferred_output_name";
    ana.symbols.items[0].requires_uppercase_first_char = true;

    try testing.expect(ana.scope_maps.items.len > 0); // 맵 round-trip 검증 의미 보장
    try testing.expect(ana.scope_owner_map.count() > 0);
    try testing.expect(ana.class_self_symbol_map.count() > 0);
    var anchored_declaration = false;
    for (ana.references.items) |reference| {
        if (reference.flags.declare and !reference.declaration_node_index.isNone()) {
            anchored_declaration = true;
            break;
        }
    }
    try testing.expect(anchored_declaration);

    const sem = ModuleSemanticData{
        .symbols = ana.symbols,
        .scopes = ana.scopes.items,
        .scope_maps = ana.scope_maps.items,
        .scope_owner_map = ana.scope_owner_map,
        .class_self_symbol_map = ana.class_self_symbol_map,
        .exported_names = ana.exported_names,
        .symbol_ids = ana.symbol_ids.items,
        .unresolved_references = ana.unresolved_references,
        .references = ana.references.items,
        .numeric_const_texts = ana.numeric_const_texts,
        .helper_scope_map = ana.helper_scope_map,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sem2 = try codec.deserialize(buf.items, arena.allocator());

    try testing.expectEqual(sem.symbols.items.len, sem2.symbols.items.len);
    try testing.expectEqual(sem.scopes.len, sem2.scopes.len);
    try testing.expectEqual(sem.symbol_ids.len, sem2.symbol_ids.len);
    try testing.expectEqual(sem.references.len, sem2.references.len);
    try testing.expectEqual(sem.scope_owner_map.count(), sem2.scope_owner_map.count());
    var owner_it = sem.scope_owner_map.iterator();
    while (owner_it.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, sem2.scope_owner_map.get(entry.key_ptr.*).?);
    }
    try testing.expectEqual(sem.class_self_symbol_map.count(), sem2.class_self_symbol_map.count());
    var class_it = sem.class_self_symbol_map.iterator();
    while (class_it.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, sem2.class_self_symbol_map.get(entry.key_ptr.*).?);
    }

    // relocatable 슬라이스는 byte 동일
    try testing.expectEqualSlices(Scope, sem.scopes, sem2.scopes);
    try testing.expectEqualSlices(?u32, sem.symbol_ids, sem2.symbol_ids);
    try testing.expectEqualSlices(Reference, sem.references, sem2.references);

    // Symbol: synthetic_name(슬라이스)은 content 비교, 나머지는 memcpy 동일
    for (sem.symbols.items, sem2.symbols.items) |s1, s2| {
        try testing.expectEqual(s1.name, s2.name);
        try testing.expectEqual(s1.scope_id, s2.scope_id);
        try testing.expectEqual(s1.kind, s2.kind);
        try testing.expectEqual(s1.declaration_span, s2.declaration_span);
        try testing.expectEqualStrings(s1.synthetic_name, s2.synthetic_name);
        try testing.expectEqualStrings(s1.output_name_hint, s2.output_name_hint);
        try testing.expectEqual(s1.requires_uppercase_first_char, s2.requires_uppercase_first_char);
        try testing.expectEqual(s1.synthetic_owner_id, s2.synthetic_owner_id);
    }

    // scope_maps: 실 analyzer 출력 — 맵 개수 + 각 키→심볼인덱스 동일
    try testing.expectEqual(sem.scope_maps.len, sem2.scope_maps.len);
    for (sem.scope_maps, sem2.scope_maps) |*m1, *m2| {
        try testing.expectEqual(m1.count(), m2.count());
        var it = m1.iterator();
        while (it.next()) |e| {
            try testing.expectEqual(e.value_ptr.*, m2.get(e.key_ptr.*).?);
        }
    }
    try testing.expectEqual(sem.unresolved_references.count(), sem2.unresolved_references.count());
    try testing.expectEqual(sem.numeric_const_texts.count(), sem2.numeric_const_texts.count());
}

test "semantic_codec: merged namespace member owner IDs survive cache round-trip" {
    const alloc = testing.allocator;
    const source = "enum Color { Red = 1, Green = Color.Red + 1 } enum Bare { A = 1, B = A + 2 } namespace N { export let value = 1; } namespace N { export let next = value + 2; } namespace Outer { export namespace Inner { export let x = 1; } } namespace Outer { export namespace Inner { export let y = x + 2; } }";
    var scanner = try Scanner.init(alloc, source);
    defer scanner.deinit();
    var parser = Parser.init(alloc, &scanner);
    defer parser.deinit();
    parser.configureFromExtension(".ts");
    _ = try parser.parse();
    var ana = SemanticAnalyzer.init(alloc, &parser.ast);
    defer ana.deinit();
    ana.is_ts = true;
    try ana.analyze();
    try testing.expect(ana.namespace_member_owners.count() > 0);
    try testing.expect(ana.namespace_declaration_owners.count() > 0);
    const helper_name_span = try parser.ast.addString("__inlineRuntimeHelper");
    const helper_name = "__inlineRuntimeHelper";
    const helper_symbol_id = ana.symbols.items.len;
    try ana.symbols.append(alloc, .{
        .name = helper_name_span,
        .scope_id = @fromBackingInt(@intCast(0)),
        .origin_scope = @fromBackingInt(@intCast(0)),
        .kind = .import_binding,
        .decl_flags = @import("../semantic/symbol.zig").SymbolKind.import_binding.declFlags(),
        .declaration_span = Span.EMPTY,
        .synthetic_kind = .runtime_helper_preamble,
        .synthetic_name = helper_name,
    });
    try ana.helper_scope_map.put(alloc, helper_name, helper_symbol_id);
    try ana.symbols.append(alloc, .{
        .name = Span.EMPTY,
        .scope_id = .none,
        .kind = .variable_var,
        .declaration_span = Span.EMPTY,
        .synthetic_kind = .cjs_runtime_factory,
        .synthetic_name = "__commonJS",
    });
    const cjs_runtime_internal_names = [_][]const u8{ "cb", "mod", "e", "__require" };
    const cjs_runtime_internal_kinds = [_]@import("../semantic/symbol.zig").SymbolKind{
        .parameter,
        .parameter,
        .catch_binding,
        .function_decl,
    };
    for (cjs_runtime_internal_names, cjs_runtime_internal_kinds) |name, kind| {
        try ana.symbols.append(alloc, .{
            .name = Span.EMPTY,
            .scope_id = .none,
            .kind = kind,
            .decl_flags = kind.declFlags(),
            .declaration_span = Span.EMPTY,
            .synthetic_kind = .cjs_runtime_internal_local,
            .synthetic_name = name,
        });
    }
    const esm_runtime_internal_names = [_][]const u8{ "fn", "res", "e", "__init", "f" };
    const esm_runtime_internal_kinds = [_]@import("../semantic/symbol.zig").SymbolKind{
        .parameter,
        .parameter,
        .catch_binding,
        .function_decl,
        .variable_var,
    };
    for (esm_runtime_internal_names, esm_runtime_internal_kinds) |name, kind| {
        try ana.symbols.append(alloc, .{
            .name = Span.EMPTY,
            .scope_id = .none,
            .kind = kind,
            .decl_flags = kind.declFlags(),
            .declaration_span = Span.EMPTY,
            .synthetic_kind = .esm_runtime_internal_local,
            .synthetic_name = name,
        });
    }
    const esm_interop_internal_names = [_][]const u8{
        "copy_props.to",    "copy_props.from",     "copy_props.desc",        "copy_props.keys",
        "copy_props.index", "copy_props.key",      "copy_props.closure_key", "to_esm.module",
        "to_esm.node_mode", "to_esm.target",       "export.target",          "export.all",
        "export.name",      "to_common_js.module",
    };
    const esm_interop_internal_kinds = [_]@import("../semantic/symbol.zig").SymbolKind{
        .parameter, .parameter, .parameter, .variable_var, .variable_var, .variable_var, .parameter,
        .parameter, .parameter, .parameter, .parameter,    .parameter,    .variable_var, .parameter,
    };
    for (esm_interop_internal_names, esm_interop_internal_kinds) |name, kind| {
        try ana.symbols.append(alloc, .{
            .name = Span.EMPTY,
            .scope_id = .none,
            .kind = kind,
            .decl_flags = kind.declFlags(),
            .declaration_span = Span.EMPTY,
            .synthetic_kind = .esm_interop_runtime_internal_local,
            .synthetic_name = name,
        });
    }
    try ana.symbols.append(alloc, .{
        .name = Span.EMPTY,
        .scope_id = .none,
        .kind = .variable_var,
        .decl_flags = @import("../semantic/symbol.zig").SymbolKind.variable_var.declFlags(),
        .declaration_span = Span.EMPTY,
        .synthetic_kind = .bundler_runtime_helper,
        .synthetic_name = "__toBinary",
    });
    try ana.symbols.append(alloc, .{
        .name = Span.EMPTY,
        .scope_id = .none,
        .kind = .variable_var,
        .decl_flags = @import("../semantic/symbol.zig").SymbolKind.variable_var.declFlags(),
        .declaration_span = Span.EMPTY,
        .synthetic_kind = .bundler_runtime_helper,
        .synthetic_name = "__esm",
    });
    const sem = ModuleSemanticData{
        .symbols = ana.symbols,
        .scopes = ana.scopes.items,
        .scope_maps = ana.scope_maps.items,
        .scope_owner_map = ana.scope_owner_map,
        .class_self_symbol_map = ana.class_self_symbol_map,
        .namespace_member_owners = ana.namespace_member_owners,
        .namespace_declaration_owners = ana.namespace_declaration_owners,
        .exported_names = ana.exported_names,
        .symbol_ids = ana.symbol_ids.items,
        .unresolved_references = ana.unresolved_references,
        .references = ana.references.items,
        .numeric_const_texts = ana.numeric_const_texts,
        .helper_scope_map = ana.helper_scope_map,
    };
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    try codec.serialize(&sem, &bytes, alloc);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const decoded = try codec.deserialize(bytes.items, arena.allocator());
    var namespace_iife_parameters: usize = 0;
    var enum_iife_parameters: usize = 0;
    var enum_iife_members: usize = 0;
    var runtime_helper_preambles: usize = 0;
    var cjs_runtime_factories: usize = 0;
    var cjs_runtime_internal_locals: usize = 0;
    var esm_runtime_internal_locals: usize = 0;
    var esm_interop_runtime_internal_locals: usize = 0;
    var bundler_runtime_helpers: usize = 0;
    for (sem.symbols.items, 0..) |symbol, raw| {
        switch (symbol.synthetic_kind orelse continue) {
            .namespace_iife_parameter => {
                namespace_iife_parameters += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
            },
            .enum_iife_parameter => {
                enum_iife_parameters += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
            },
            .enum_iife_member => {
                enum_iife_members += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
                try testing.expectEqual(symbol.synthetic_owner_id, decoded.symbols.items[raw].synthetic_owner_id);
            },
            .runtime_helper_preamble => {
                runtime_helper_preambles += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
            },
            .cjs_runtime_factory => {
                cjs_runtime_factories += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
            },
            .cjs_runtime_internal_local => {
                cjs_runtime_internal_locals += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqual(symbol.kind, decoded.symbols.items[raw].kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
            },
            .esm_runtime_internal_local => {
                esm_runtime_internal_locals += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqual(symbol.kind, decoded.symbols.items[raw].kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
            },
            .esm_interop_runtime_internal_local => {
                esm_interop_runtime_internal_locals += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqual(symbol.kind, decoded.symbols.items[raw].kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
            },
            .bundler_runtime_helper => {
                bundler_runtime_helpers += 1;
                try testing.expectEqual(symbol.synthetic_kind, decoded.symbols.items[raw].synthetic_kind);
                try testing.expectEqualStrings(symbol.synthetic_name, decoded.symbols.items[raw].synthetic_name);
            },
            else => {},
        }
    }
    try testing.expect(namespace_iife_parameters >= 4);
    try testing.expectEqual(@as(usize, 2), enum_iife_parameters);
    try testing.expectEqual(@as(usize, 1), enum_iife_members);
    try testing.expectEqual(@as(usize, 1), runtime_helper_preambles);
    try testing.expectEqual(@as(usize, 1), cjs_runtime_factories);
    try testing.expectEqual(@as(usize, 4), cjs_runtime_internal_locals);
    try testing.expectEqual(@as(usize, 5), esm_runtime_internal_locals);
    try testing.expectEqual(@as(usize, 14), esm_interop_runtime_internal_locals);
    try testing.expectEqual(@as(usize, 2), bundler_runtime_helpers);
    try testing.expectEqual(@as(?usize, helper_symbol_id), decoded.helper_scope_map.get("__inlineRuntimeHelper"));
    try testing.expectEqual(sem.namespace_member_owners.count(), decoded.namespace_member_owners.count());
    var it = sem.namespace_member_owners.iterator();
    while (it.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, decoded.namespace_member_owners.get(entry.key_ptr.*).?);
    }
    try testing.expectEqual(sem.namespace_declaration_owners.count(), decoded.namespace_declaration_owners.count());
    var decl_it = sem.namespace_declaration_owners.iterator();
    while (decl_it.next()) |entry| {
        try testing.expectEqual(entry.value_ptr.*, decoded.namespace_declaration_owners.get(entry.key_ptr.*).?);
    }
}

test "semantic_codec: synthetic_name 보존 (합성 심볼)" {
    const alloc = testing.allocator;

    var symbols: std.ArrayList(Symbol) = .empty;
    defer symbols.deinit(alloc);
    try symbols.append(alloc, std.mem.zeroInit(Symbol, .{ .synthetic_name = @as([]const u8, "") }));
    try symbols.append(alloc, std.mem.zeroInit(Symbol, .{ .synthetic_name = @as([]const u8, "__syn_helper") }));

    const sem = ModuleSemanticData{
        .symbols = symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
        .references = &.{},
        .numeric_const_texts = .empty,
        .helper_scope_map = .empty,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sem2 = try codec.deserialize(buf.items, arena.allocator());

    try testing.expectEqual(@as(usize, 2), sem2.symbols.items.len);
    try testing.expectEqualStrings("", sem2.symbols.items[0].synthetic_name);
    try testing.expectEqualStrings("__syn_helper", sem2.symbols.items[1].synthetic_name);
}

test "semantic_codec: HashMap 5개 round-trip (값 타입별)" {
    const alloc = testing.allocator;

    // scope_maps: 2개 스코프(StringHashMap usize). 빈 맵도 1개 섞어 경계 확인.
    var sm0: std.StringHashMapUnmanaged(usize) = .empty;
    var sm1: std.StringHashMapUnmanaged(usize) = .empty;
    defer sm0.deinit(alloc);
    defer sm1.deinit(alloc);
    try sm0.put(alloc, "a", 0);
    try sm0.put(alloc, "f", 1);
    try sm1.put(alloc, "x", 2);
    var scope_maps = [_]std.StringHashMapUnmanaged(usize){ sm0, sm1, .empty };

    var exported: std.StringHashMapUnmanaged(Span) = .empty;
    defer exported.deinit(alloc);
    try exported.put(alloc, "f", .{ .start = 9, .end = 10 });

    var unres: std.StringHashMapUnmanaged(void) = .empty;
    defer unres.deinit(alloc);
    try unres.put(alloc, "globalThis", {});

    var nums: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer nums.deinit(alloc);
    try nums.put(alloc, 0, "1");
    try nums.put(alloc, 2, "42");

    var helper: std.StringHashMapUnmanaged(usize) = .empty;
    defer helper.deinit(alloc);
    try helper.put(alloc, "_jsx", 3);

    const sem = ModuleSemanticData{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = &scope_maps,
        .exported_names = exported,
        .symbol_ids = &.{},
        .unresolved_references = unres,
        .references = &.{},
        .numeric_const_texts = nums,
        .helper_scope_map = helper,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const sem2 = try codec.deserialize(buf.items, arena.allocator());

    try testing.expectEqual(@as(usize, 3), sem2.scope_maps.len);
    try testing.expectEqual(@as(?usize, 0), sem2.scope_maps[0].get("a"));
    try testing.expectEqual(@as(?usize, 1), sem2.scope_maps[0].get("f"));
    try testing.expectEqual(@as(?usize, 2), sem2.scope_maps[1].get("x"));
    try testing.expectEqual(@as(u32, 0), sem2.scope_maps[2].count());

    const exp = sem2.exported_names.get("f").?;
    try testing.expectEqual(@as(u32, 9), exp.start);
    try testing.expectEqual(@as(u32, 10), exp.end);

    try testing.expect(sem2.unresolved_references.contains("globalThis"));
    try testing.expectEqual(@as(u32, 1), sem2.unresolved_references.count());

    try testing.expectEqualStrings("1", sem2.numeric_const_texts.get(0).?);
    try testing.expectEqualStrings("42", sem2.numeric_const_texts.get(2).?);

    try testing.expectEqual(@as(?usize, 3), sem2.helper_scope_map.get("_jsx"));
}

// #4438 회귀 가드: Symbol/Scope/Reference 의 struct 꼬리 padding(미초기화)이 직렬화에 새지
// 않아야 한다(결정성). 통째 memcpy 는 poison 을 stream 에 섞어 같은 의미도 byte 가 달라졌다.
// 정반대 poison(0xAA/0x55)으로 raw 를 채우고 의미 필드만 동일 세팅 → byte-identical 이어야.
test "semantic_codec: struct padding poison 이 직렬화에 새지 않는다 (#4438 결정성)" {
    const alloc = testing.allocator;

    const build = struct {
        fn f(a: std.mem.Allocator, poison: u8) !struct {
            sem: ModuleSemanticData,
            symbols: std.ArrayList(Symbol),
            scopes: []Scope,
            refs: []Reference,
            ids: []?u32,
        } {
            var symbols: std.ArrayList(Symbol) = .empty;
            var s: Symbol = undefined;
            @memset(std.mem.asBytes(&s), poison);
            s.synthetic_name = ""; // 슬라이스는 명시 세팅(poison ptr 미사용)
            s.output_name_hint = "";
            s.name = .{ .start = 1, .end = 2 };
            s.scope_id = @fromBackingInt(@intCast(0));
            s.origin_scope = @fromBackingInt(@intCast(0));
            s.kind = .variable_const;
            s.decl_flags = .{ .block_scoped = true, .is_const = true };
            s.declaration_span = .{ .start = 1, .end = 2 };
            s.reference_count = 5;
            s.write_count = 0;
            s.const_kind = .number;
            s.synthetic_kind = null;
            s.requires_uppercase_first_char = false;
            s.synthetic_owner_id = null;
            try symbols.append(a, s);

            const scopes = try a.alloc(Scope, 1);
            @memset(std.mem.asBytes(&scopes[0]), poison);
            scopes[0].parent = @fromBackingInt(@intCast(std.math.maxInt(u32)));
            scopes[0].kind = .global;
            scopes[0].is_strict = true;
            scopes[0].subtree_has_direct_eval = false;
            scopes[0].subtree_has_with = false;
            scopes[0].symbol_count = 1;

            const refs = try a.alloc(Reference, 1);
            @memset(std.mem.asBytes(&refs[0]), poison);
            refs[0].node_index = @fromBackingInt(@intCast(3));
            refs[0].declaration_node_index = .none;
            refs[0].scope_id = @fromBackingInt(@intCast(0));
            refs[0].symbol_id = @fromBackingInt(@intCast(0));
            refs[0].stmt_idx = 0;
            refs[0].scope_stmt_idx = 0;
            refs[0].flags = .{ .read = true };

            const ids = try a.alloc(?u32, 2);
            ids[0] = 0;
            ids[1] = null;

            return .{
                .sem = .{
                    .symbols = symbols,
                    .scopes = scopes,
                    .scope_maps = &.{},
                    .exported_names = .empty,
                    .symbol_ids = ids,
                    .unresolved_references = .empty,
                    .references = refs,
                    .numeric_const_texts = .empty,
                    .helper_scope_map = .empty,
                },
                .symbols = symbols,
                .scopes = scopes,
                .refs = refs,
                .ids = ids,
            };
        }
    }.f;

    var r1 = try build(alloc, 0xAA);
    defer {
        r1.symbols.deinit(alloc);
        alloc.free(r1.scopes);
        alloc.free(r1.refs);
        alloc.free(r1.ids);
    }
    var r2 = try build(alloc, 0x55);
    defer {
        r2.symbols.deinit(alloc);
        alloc.free(r2.scopes);
        alloc.free(r2.refs);
        alloc.free(r2.ids);
    }

    var b1: std.ArrayList(u8) = .empty;
    defer b1.deinit(alloc);
    var b2: std.ArrayList(u8) = .empty;
    defer b2.deinit(alloc);
    try codec.serialize(&r1.sem, &b1, alloc);
    try codec.serialize(&r2.sem, &b2, alloc);

    try testing.expectEqualSlices(u8, b1.items, b2.items);

    // round-trip 의미 복원.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const rt = try codec.deserialize(b1.items, arena.allocator());
    try testing.expectEqual(@as(usize, 1), rt.symbols.items.len);
    try testing.expectEqual(@as(u32, 5), rt.symbols.items[0].reference_count);
    try testing.expectEqual(@as(?u32, 0), rt.symbol_ids[0]);
    try testing.expectEqual(@as(?u32, null), rt.symbol_ids[1]);
    try testing.expect(rt.references[0].flags.read);
}

test "semantic_codec: 변조/버전/매직/truncated 거부 (fail-safe)" {
    const alloc = testing.allocator;

    var symbols: std.ArrayList(Symbol) = .empty;
    defer symbols.deinit(alloc);
    try symbols.append(alloc, std.mem.zeroInit(Symbol, .{ .synthetic_name = @as([]const u8, "") }));

    const sem = ModuleSemanticData{
        .symbols = symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
        .references = &.{},
        .numeric_const_texts = .empty,
        .helper_scope_map = .empty,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // 정상은 성공
    _ = try codec.deserialize(buf.items, arena.allocator());

    inline for (.{
        .{ 0, @as(u8, 0xFF), error.BadMagic },
        .{ 4, @as(u8, 0xEE), error.UnsupportedVersion },
    }) |tc| {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[tc[0]] ^= tc[1];
        try testing.expectError(tc[2], codec.deserialize(dup, arena.allocator()));
    }
    // checksum (payload 변조)
    {
        const dup = try alloc.dupe(u8, buf.items);
        defer alloc.free(dup);
        dup[dup.len - 1] ^= 0xFF;
        try testing.expectError(error.ChecksumMismatch, codec.deserialize(dup, arena.allocator()));
    }
    // truncated
    try testing.expectError(error.Truncated, codec.deserialize(buf.items[0..8], arena.allocator()));
}

// #4438 결함2 회귀: checksum 은 유효하지만 HashMap count 가 거대한 손상 캐시는 panic 이 아니라
// error 로 거부돼야 한다. 빈 sem 직렬화의 runtime presence 앞 4B(= 마지막 map count)를 maxInt(u32)
// 로 바꾸고 checksum 을 재계산(=유효) → checkedMapCount 가 payload 길이 대비 상한해 Truncated.
// 가드 없으면 ensureTotalCapacity(maxInt) 의 ceilPowerOfTwo unreachable 로 panic(테스트 크래시).
test "semantic_codec: checksum 유효 + 거대 map count → panic 아닌 error (결함2)" {
    const alloc = testing.allocator;
    const wyhash = @import("../util/wyhash.zig");

    var symbols: std.ArrayList(Symbol) = .empty;
    defer symbols.deinit(alloc);
    const sem = ModuleSemanticData{
        .symbols = symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
        .references = &.{},
        .numeric_const_texts = .empty,
        .helper_scope_map = .empty,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    // 마지막 runtime presence 앞의 namespace_declaration_owners count를 변조.
    const dup = try alloc.dupe(u8, buf.items);
    defer alloc.free(dup);
    const HEADER_LEN: usize = 16; // magic(4)+version(4)+checksum(8)
    std.mem.writeInt(u32, dup[dup.len - 8 ..][0..4], std.math.maxInt(u32), .little);
    // checksum 재계산(payload = HEADER_LEN..). 변조했어도 checksum 은 유효하게 만들어 가드만 검증.
    const new_checksum = wyhash.hashU64(dup[HEADER_LEN..]);
    std.mem.writeInt(u64, dup[8..16], new_checksum, .little);

    // checksum 통과(ChecksumMismatch 아님) + count 상한 위반 → Truncated (panic 아님).
    try testing.expectError(error.Truncated, codec.deserialize(dup, arena.allocator()));
}

// Role IDs are graph-local. Malformed caches must fail before linker names
// can accidentally turn a corrupt role into another symbol.
test "semantic_codec: runtime identity roles reject malformed checksummed snapshots" {
    const alloc = testing.allocator;
    const module = @import("module.zig");
    const wyhash = @import("../util/wyhash.zig");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var symbols: std.ArrayList(Symbol) = .empty;
    defer symbols.deinit(alloc);
    for (0..12) |_| try symbols.append(alloc, std.mem.zeroInit(Symbol, .{ .synthetic_name = @as([]const u8, "") }));
    var snapshot: module.RuntimeIdentitySnapshot = .{
        .cjs_factory = @fromBackingInt(0),
        .cjs_internal = .{ .callback_parameter = @fromBackingInt(1), .module_parameter = @fromBackingInt(2), .catch_parameter = @fromBackingInt(3), .require_function = @fromBackingInt(4) },
        .esm_factory = @fromBackingInt(5),
        .esm_internal = .{ .factory_parameter = @fromBackingInt(6), .result_parameter = @fromBackingInt(7), .catch_parameter = @fromBackingInt(8), .init_function = @fromBackingInt(9), .factory_local = @fromBackingInt(10) },
        .to_binary = @fromBackingInt(11),
    };
    var sem: ModuleSemanticData = .{
        .symbols = symbols,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
        .references = &.{},
        .numeric_const_texts = .empty,
        .helper_scope_map = .empty,
        .runtime_identities = &snapshot,
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try codec.serialize(&sem, &buf, alloc);
    const restored = try codec.deserialize(buf.items, arena.allocator());
    try testing.expectEqualDeep(snapshot, restored.runtime_identities.?.*);
    // Snapshot tail: present, CJS factory, CJS present + four IDs,
    // ESM factory, ESM present + five IDs, binary (15 u32 words).
    const tail = buf.items.len - 15 * 4;
    const corruptions = [_]struct { word: usize, value: u32 }{
        .{ .word = 0, .value = 2 }, // invalid snapshot presence
        .{ .word = 1, .value = 12 }, // out-of-range factory
        .{ .word = 1, .value = 0xffffffff }, // partial CJS pair
        .{ .word = 2, .value = 2 }, // invalid group presence
        .{ .word = 3, .value = 0xffffffff }, // required role missing
        .{ .word = 4, .value = 1 }, // duplicate CJS role
        .{ .word = 7, .value = 0xffffffff }, // partial ESM pair
        .{ .word = 8, .value = 2 }, // invalid ESM presence
        .{ .word = 13, .value = 0 }, // cross-family duplicate
        .{ .word = 14, .value = 12 }, // out-of-range binary role
    };
    for (corruptions) |corruption| {
        const bytes = try arena.allocator().dupe(u8, buf.items);
        const offset = tail + corruption.word * 4;
        std.mem.writeInt(u32, bytes[offset..][0..4], corruption.value, .little);
        std.mem.writeInt(u64, bytes[8..16], wyhash.hashU64(bytes[16..]), .little);
        try testing.expectError(error.Truncated, codec.deserialize(bytes, arena.allocator()));
    }
    const trailing = try arena.allocator().alloc(u8, buf.items.len + 1);
    @memcpy(trailing[0..buf.items.len], buf.items);
    trailing[buf.items.len] = 0;
    std.mem.writeInt(u64, trailing[8..16], wyhash.hashU64(trailing[16..]), .little);
    try testing.expectError(error.Truncated, codec.deserialize(trailing, arena.allocator()));
    // The writer also rejects malformed in-memory handles.
    const valid = snapshot;
    snapshot.cjs_internal = null;
    try testing.expectError(error.Truncated, codec.serialize(&sem, &buf, alloc));
    snapshot = valid;
    snapshot.to_binary = @fromBackingInt(12);
    try testing.expectError(error.Truncated, codec.serialize(&sem, &buf, alloc));
    snapshot = valid;
    snapshot.to_binary = snapshot.cjs_factory;
    try testing.expectError(error.Truncated, codec.serialize(&sem, &buf, alloc));
    snapshot = valid;
    snapshot.to_binary = @fromBackingInt(0xffffffff);
    try testing.expectError(error.Truncated, codec.serialize(&sem, &buf, alloc));
}

test "semantic owner token is memory only and decode cannot reuse its owner" {
    const alloc = testing.allocator;
    var sem = ModuleSemanticData{
        .symbols = .empty,
        .scopes = &.{},
        .scope_maps = &.{},
        .exported_names = .empty,
        .symbol_ids = &.{},
        .unresolved_references = .empty,
    };
    var before: std.ArrayList(u8) = .empty;
    defer before.deinit(alloc);
    try codec.serialize(&sem, &before, alloc);
    const token = sem.captureOwnerToken();
    try testing.expect(token != .unassigned);
    try testing.expectEqual(token, sem.captureOwnerToken());
    var stamped: std.ArrayList(u8) = .empty;
    defer stamped.deinit(alloc);
    try codec.serialize(&sem, &stamped, alloc);
    try testing.expectEqualSlices(u8, before.items, stamped.items);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var decoded = try codec.deserialize(stamped.items, arena.allocator());
    try testing.expectEqual(@import("module.zig").SemanticOwnerToken.unassigned, decoded.owner_token);
    const decoded_token = decoded.captureOwnerToken();
    try testing.expect(decoded_token != .unassigned and decoded_token != token);
}
