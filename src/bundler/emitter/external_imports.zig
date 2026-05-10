//! ESM external imports — chunk top 에 dedup 된 `import` 구문 emit.
//!
//! `format=esm` 출력에서 external 모듈의 import 는 require() 로 변환하면 안 되고
//! 그대로 `import { x } from "spec"` 형태로 보존되어야 한다 (esbuild/rolldown 동등).
//!
//! 흐름:
//!   1. chunk 에 포함된 모듈들의 import_bindings 중 is_external 인 것 수집
//!   2. specifier 별로 묶고 (default / namespace / named) dedup
//!   3. canonical rename 적용된 local 이름으로 import 구문 한 번 emit
//!
//! linker 의 metadata 단계에서는 ESM external 분기에서 require() preamble 생성을
//! skip 하므로, codegen 이 import_declaration 노드를 skip 한 결과와 함께 chunk top
//! 의 ESM import 가 유일한 진입점이 된다.

const std = @import("std");
const types = @import("../types.zig");
const Module = @import("../module.zig").Module;
const ImportBinding = @import("../binding_scanner.zig").ImportBinding;
const Linker = @import("../linker.zig").Linker;
const isImportBindingTypeOnly = @import("../linker/metadata.zig").isImportBindingTypeOnly;

const NamedBinding = struct {
    imported: []const u8,
    local: []const u8,
};

/// `var target = source;` 형태의 보강 declaration.
/// 같은 specifier 의 default/namespace/named 슬롯이 첫 등장 local 로 차지된 후 다른
/// 모듈에서 mangled 이름이 들어온 경우 (axios `ZlibHeaderTransformStream.js` 의
/// `stream$1` 등) declaration 누락으로 dangling reference 가 되는 것을 회복.
const AliasBinding = struct {
    source: []const u8,
    target: []const u8,
};

const SpecifierGroup = struct {
    default_local: ?[]const u8 = null,
    namespace_local: ?[]const u8 = null,
    named: std.ArrayListUnmanaged(NamedBinding) = .empty,
    side_effect_only: bool = false,
    aliases: std.ArrayListUnmanaged(AliasBinding) = .empty,

    fn deinit(self: *SpecifierGroup, allocator: std.mem.Allocator) void {
        self.named.deinit(allocator);
        self.aliases.deinit(allocator);
    }
};

/// chunk 단위 ESM external import 구문 emit. format == .esm 이 아니면 no-op.
/// modules 는 chunk 가 포함하는 모듈 슬라이스 (단일 bundle 모드는 sorted 전체).
pub fn emitChunkExternalImports(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    modules: []const *const Module,
    linker: ?*const Linker,
    minify_whitespace: bool,
) !void {
    // specifier → group. ArrayHashMap 으로 첫 등장 순서 유지 → 결정론적 출력.
    var per_spec: std.StringArrayHashMapUnmanaged(SpecifierGroup) = .empty;
    defer {
        var it = per_spec.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        per_spec.deinit(allocator);
    }

    for (modules) |m| {
        // ESM-wrapped (init 함수로 둘러싼) 모듈은 require()/init 패턴이 필요.
        // 일반 scope-hoisted 모듈만 chunk-level ESM import 로 끌어올린다.
        if (m.wrap_kind.isWrapped()) continue;

        // (1) named/default/namespace bindings — import_bindings 에서 추출.
        // type-only binding 은 elide (linker 의 metadata 경로와 대칭, #1791 Phase D).
        const verbatim = if (linker) |l| l.verbatim_module_syntax else false;
        for (m.import_bindings) |ib| {
            if (ib.import_record_index >= m.import_records.len) continue;
            const rec = m.import_records[ib.import_record_index];
            if (!rec.is_external) continue;
            if (rec.kind != .static_import and rec.kind != .re_export) continue;
            if (!ib.isSynthetic() and !ib.local_symbol.isValid()) continue;

            // verbatim_module_syntax=true 면 모두 보존, 아니면 type-only 는 drop.
            if (!verbatim) {
                if (m.semantic) |sem| {
                    if (isImportBindingTypeOnly(&sem, ib)) continue;
                }
            }

            const local_name = if (linker) |l|
                (l.getCanonicalByRef(ib.local_symbol) orelse m.importBindingLocalName(ib))
            else
                m.importBindingLocalName(ib);

            const gop = try per_spec.getOrPut(allocator, rec.specifier);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try addBinding(gop.value_ptr, allocator, ib.kind, ib.imported_name, local_name);
        }

        // (2) side-effect import (specs 0개) — import_records 에서 직접 감지.
        for (m.import_records) |rec| {
            if (!rec.is_external) continue;
            if (rec.kind != .side_effect) continue;
            const gop = try per_spec.getOrPut(allocator, rec.specifier);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{ .side_effect_only = true };
            }
            // bindings 가 이미 있는 specifier 는 side_effect 만 별도로 표시할 필요 없음
            // (어차피 import 구문 한 줄로 동시 표현되므로).
        }
    }

    // emit
    var spec_it = per_spec.iterator();
    while (spec_it.next()) |e| {
        try emitOneImport(output, allocator, e.key_ptr.*, e.value_ptr, minify_whitespace);
    }
}

fn addBinding(
    group: *SpecifierGroup,
    allocator: std.mem.Allocator,
    kind: ImportBinding.Kind,
    imported: []const u8,
    local: []const u8,
) !void {
    switch (kind) {
        .default => try fillOrAlias(&group.default_local, &group.aliases, allocator, local),
        .namespace => try fillOrAlias(&group.namespace_local, &group.aliases, allocator, local),
        .named => {
            // `import { default as X }` 는 의미상 default import 와 동일 → default slot 으로 정규화.
            // 같은 specifier 의 `import D from ...` 와 `import { default as D } from ...` 가
            // 한 라인에서 중복 specifier 로 emit 되는 것을 막음 (esbuild/rolldown 동등).
            if (std.mem.eql(u8, imported, "default")) {
                try fillOrAlias(&group.default_local, &group.aliases, allocator, local);
                return;
            }
            // dedup: 여러 모듈이 같은 specifier 의 같은 binding 을 import 하면 SyntaxError
            // (`import { x, x } from ...`) — 사전 차단. n 은 specifier 당 보통 < 50 이라
            // linear scan 비용 무시 가능.
            // 같은 imported 다른 local 은 첫 등장을 canonical 로 두고 alias 추가.
            for (group.named.items) |nb| {
                if (!std.mem.eql(u8, nb.imported, imported)) continue;
                if (std.mem.eql(u8, nb.local, local)) return;
                try appendAliasOnce(&group.aliases, allocator, nb.local, local);
                return;
            }
            try group.named.append(allocator, .{ .imported = imported, .local = local });
        },
    }
}

/// slot 이 비어 있으면 local 로 채움. 이미 같은 local 로 차 있으면 no-op.
/// 다른 local 이면 `var local = slot.*;` alias 로 보강 (default/namespace 슬롯 공용).
fn fillOrAlias(
    slot: *?[]const u8,
    aliases: *std.ArrayListUnmanaged(AliasBinding),
    allocator: std.mem.Allocator,
    local: []const u8,
) !void {
    if (slot.* == null) {
        slot.* = local;
        return;
    }
    if (std.mem.eql(u8, slot.*.?, local)) return;
    try appendAliasOnce(aliases, allocator, slot.*.?, local);
}

fn appendAliasOnce(
    aliases: *std.ArrayListUnmanaged(AliasBinding),
    allocator: std.mem.Allocator,
    source: []const u8,
    target: []const u8,
) !void {
    for (aliases.items) |a| {
        if (std.mem.eql(u8, a.source, source) and std.mem.eql(u8, a.target, target)) return;
    }
    try aliases.append(allocator, .{ .source = source, .target = target });
}

fn emitOneImport(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    spec: []const u8,
    group: *const SpecifierGroup,
    minify_whitespace: bool,
) !void {
    const list_sep: []const u8 = if (minify_whitespace) "," else ", ";
    const brace_open: []const u8 = if (minify_whitespace) "{" else "{ ";
    const brace_close: []const u8 = if (minify_whitespace) "}" else " }";
    const eol: []const u8 = if (minify_whitespace) "" else "\n";

    // ESM token boundary 규칙 (#2955):
    //   - `import D from "x"` 의 D 는 식별자라서 keyword 와 인접하면 공백 필수.
    //   - `import{x}from"y"` 는 `{` / `}` 가 토큰 경계라 minify 시 공백 생략 가능.
    //   - `import * as N from "x"` 의 N 도 식별자라 from 앞 공백 필수.

    const has_default_or_named = group.default_local != null or group.named.items.len > 0;
    const has_any = has_default_or_named or group.namespace_local != null;

    // side-effect only: `import "spec";`
    if (!has_any and group.side_effect_only) {
        try output.appendSlice(allocator, "import\"");
        try output.appendSlice(allocator, spec);
        try output.appendSlice(allocator, "\";");
        try output.appendSlice(allocator, eol);
        return;
    }
    if (!has_any) return;

    // (1) default + named — 한 줄. rolldown 의 `create_import_declaration` 동일.
    //     ESM spec 상 `import D, { x } from "spec"` 합법. namespace 는 같이 못 묶음.
    if (has_default_or_named) {
        const import_kw: []const u8 = if (minify_whitespace and group.default_local == null) "import" else "import ";
        try output.appendSlice(allocator, import_kw);

        var has_pre = false;
        if (group.default_local) |d| {
            try output.appendSlice(allocator, d);
            has_pre = true;
        }
        var ends_with_brace = false;
        if (group.named.items.len > 0) {
            if (has_pre) try output.appendSlice(allocator, list_sep);
            try output.appendSlice(allocator, brace_open);
            for (group.named.items, 0..) |nb, i| {
                if (i > 0) try output.appendSlice(allocator, list_sep);
                if (std.mem.eql(u8, nb.imported, nb.local)) {
                    try output.appendSlice(allocator, nb.local);
                } else {
                    try output.appendSlice(allocator, nb.imported);
                    try output.appendSlice(allocator, " as ");
                    try output.appendSlice(allocator, nb.local);
                }
            }
            try output.appendSlice(allocator, brace_close);
            ends_with_brace = true;
        }
        const from_kw: []const u8 = blk: {
            if (!minify_whitespace) break :blk " from \"";
            if (ends_with_brace) break :blk "from\"";
            break :blk " from\"";
        };
        try output.appendSlice(allocator, from_kw);
        try output.appendSlice(allocator, spec);
        try output.appendSlice(allocator, "\";");
        try output.appendSlice(allocator, eol);
    }

    // (2) namespace — 별도 라인. rolldown `Specifier::Star` 분리 정책.
    //     `import * as ns, { x }` 는 ESM syntax error 라 묶을 수 없음.
    if (group.namespace_local) |n| {
        try output.appendSlice(allocator, if (minify_whitespace) "import*as " else "import * as ");
        try output.appendSlice(allocator, n);
        try output.appendSlice(allocator, if (minify_whitespace) " from\"" else " from \"");
        try output.appendSlice(allocator, spec);
        try output.appendSlice(allocator, "\";");
        try output.appendSlice(allocator, eol);
    }

    // (3) `var target = source;` alias — 슬롯 차지 후 다른 mangled local 이 들어온 binding 보강.
    const eq_op: []const u8 = if (minify_whitespace) "=" else " = ";
    for (group.aliases.items) |a| {
        try output.appendSlice(allocator, "var ");
        try output.appendSlice(allocator, a.target);
        try output.appendSlice(allocator, eq_op);
        try output.appendSlice(allocator, a.source);
        try output.appendSlice(allocator, ";");
        try output.appendSlice(allocator, eol);
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn runEmit(group: *const SpecifierGroup, spec: []const u8, minify: bool) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(testing.allocator);
    try emitOneImport(&output, testing.allocator, spec, group, minify);
    return output.toOwnedSlice(testing.allocator);
}

test "emitOneImport: default-only minify — 식별자↔keyword 토큰 경계 공백 (#2955)" {
    var group: SpecifierGroup = .{ .default_local = "process$1" };
    defer group.deinit(testing.allocator);

    const out = try runEmit(&group, "node:process", true);
    defer testing.allocator.free(out);

    // `importprocess$1from"…"` 가 아니라 양쪽에 공백.
    try testing.expectEqualStrings("import process$1 from\"node:process\";", out);
}

test "emitOneImport: default + named minify — brace 직후 from 공백 생략 (minify 효과)" {
    var group: SpecifierGroup = .{ .default_local = "D" };
    defer group.deinit(testing.allocator);
    try group.named.append(testing.allocator, .{ .imported = "x", .local = "x" });

    const out = try runEmit(&group, "spec", true);
    defer testing.allocator.free(out);

    // `}` 가 토큰 경계라 from 앞 공백 생략 가능 — 단 import↔D 사이는 공백 필수.
    try testing.expectEqualStrings("import D,{x}from\"spec\";", out);
}

test "emitOneImport: named-only minify — 양쪽 brace 가 경계라 공백 모두 생략" {
    var group: SpecifierGroup = .{};
    defer group.deinit(testing.allocator);
    try group.named.append(testing.allocator, .{ .imported = "createRequire", .local = "createRequire" });

    const out = try runEmit(&group, "node:module", true);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("import{createRequire}from\"node:module\";", out);
}

test "emitOneImport: namespace minify — 식별자 직후 from 공백 필수 (#2955)" {
    var group: SpecifierGroup = .{ .namespace_local = "ns" };
    defer group.deinit(testing.allocator);

    const out = try runEmit(&group, "spec", true);
    defer testing.allocator.free(out);

    // `*as N` 의 N 은 식별자라 from 앞 공백 필수. `nsfrom"…"` 형태 회귀 방지.
    try testing.expectEqualStrings("import*as ns from\"spec\";", out);
}

test "emitOneImport: side-effect minify — `\"` 가 토큰 경계라 공백 불필요" {
    var group: SpecifierGroup = .{ .side_effect_only = true };
    defer group.deinit(testing.allocator);

    const out = try runEmit(&group, "polyfill", true);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("import\"polyfill\";", out);
}

test "emitOneImport: non-minify default + named — 보수적 공백 + newline" {
    var group: SpecifierGroup = .{ .default_local = "D" };
    defer group.deinit(testing.allocator);
    try group.named.append(testing.allocator, .{ .imported = "x", .local = "y" });

    const out = try runEmit(&group, "spec", false);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("import D, { x as y } from \"spec\";\n", out);
}

test "emitOneImport: rename 없는 named 두 개 — list_sep 적용" {
    var group: SpecifierGroup = .{};
    defer group.deinit(testing.allocator);
    try group.named.append(testing.allocator, .{ .imported = "a", .local = "a" });
    try group.named.append(testing.allocator, .{ .imported = "b", .local = "b" });

    const min = try runEmit(&group, "x", true);
    defer testing.allocator.free(min);
    try testing.expectEqualStrings("import{a,b}from\"x\";", min);

    const pretty = try runEmit(&group, "x", false);
    defer testing.allocator.free(pretty);
    try testing.expectEqualStrings("import { a, b } from \"x\";\n", pretty);
}
