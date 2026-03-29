//! ZTS Bundler — Binding Scanner
//!
//! AST에서 import/export의 바인딩 상세를 추출한다.
//! import_scanner.zig는 specifier 경로만 추출하지만,
//! 이 모듈은 "어떤 이름이 어떤 이름으로 바인딩되는지"를 추출한다.
//!
//! 예:
//!   import { foo as bar } from './dep'
//!   → ImportBinding { kind=.named, local_name="bar", imported_name="foo" }
//!
//!   export const x = 1;
//!   → ExportBinding { exported_name="x", local_name="x", kind=.local }

const std = @import("std");
const Ast = @import("../parser/ast.zig").Ast;
const Node = @import("../parser/ast.zig").Node;
const NodeIndex = @import("../parser/ast.zig").NodeIndex;
const Span = @import("../lexer/token.zig").Span;
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;

pub const ImportBinding = struct {
    kind: Kind,
    /// 이 모듈에서 사용하는 로컬 이름 (e.g. "bar" in `import { foo as bar }`)
    local_name: []const u8,
    /// 상대 모듈에서 export된 이름 (e.g. "foo", "default", "*")
    imported_name: []const u8,
    /// 로컬 바인딩의 소스 위치 (linker의 rename 키로 사용)
    local_span: Span,
    /// 어떤 import 문에서 왔는지 (ImportRecord 인덱스)
    import_record_index: u32,
    /// namespace import에서 실제 접근된 프로퍼티 목록 (v.object → "object")
    /// null = 전체 사용 (동적 접근, namespace 탈출 등 fallback)
    namespace_used_properties: ?[]const []const u8 = null,

    pub const Kind = enum {
        default,
        named,
        namespace,
    };
};

pub const ExportBinding = struct {
    /// 외부에 노출되는 이름 (e.g. "x", "default", "b" in `export { a as b }`)
    exported_name: []const u8,
    /// 모듈 내부 이름 (e.g. "x", "a")
    local_name: []const u8,
    local_span: Span,
    kind: Kind,
    /// re-export 시 소스 모듈의 ImportRecord 인덱스
    import_record_index: ?u32 = null,

    pub const Kind = enum {
        local,
        re_export,
        re_export_all,
    };
};

/// AST에서 import 바인딩 상세를 추출한다.
/// import_record_map: import source span → ImportRecord 인덱스 매핑
pub fn extractImportBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    import_records: []const types.ImportRecord,
) ![]ImportBinding {
    var bindings: std.ArrayList(ImportBinding) = .empty;
    errdefer bindings.deinit(allocator);

    // import source span → import_record 인덱스 매핑
    var source_to_record = std.AutoHashMap(u64, u32).init(allocator);
    defer source_to_record.deinit();
    for (import_records, 0..) |rec, i| {
        const key = types.spanKey(rec.span);
        try source_to_record.put(key, @intCast(i));
    }

    for (ast.nodes.items) |node| {
        if (node.tag != .import_declaration) continue;

        const e = node.data.extra;
        if (e + 2 >= ast.extra_data.items.len) continue;

        const extras = ast.extra_data.items[e .. e + 3];
        const specs_start = extras[0];
        const specs_len = extras[1];
        const source_idx: NodeIndex = @enumFromInt(extras[2]);
        if (source_idx.isNone()) continue;

        // source span으로 ImportRecord 인덱스 찾기
        const source_node = ast.getNode(source_idx);
        const rec_idx = source_to_record.get(types.spanKey(source_node.span)) orelse continue;

        if (specs_len == 0) continue; // side-effect import

        const spec_indices = ast.extra_data.items[specs_start .. specs_start + specs_len];
        for (spec_indices) |raw_idx| {
            const spec: NodeIndex = @enumFromInt(raw_idx);
            if (spec.isNone()) continue;
            if (@intFromEnum(spec) >= ast.nodes.items.len) continue;

            const spec_node = ast.getNode(spec);
            switch (spec_node.tag) {
                .import_default_specifier => {
                    const name = ast.source[spec_node.span.start..spec_node.span.end];
                    try bindings.append(allocator, .{
                        .kind = .default,
                        .local_name = name,
                        .imported_name = "default",
                        .local_span = spec_node.span,
                        .import_record_index = rec_idx,
                    });
                },
                .import_namespace_specifier => {
                    const name = ast.source[spec_node.span.start..spec_node.span.end];
                    try bindings.append(allocator, .{
                        .kind = .namespace,
                        .local_name = name,
                        .imported_name = "*",
                        .local_span = spec_node.span,
                        .import_record_index = rec_idx,
                    });
                },
                .import_specifier => {
                    // binary { left=imported, right=local, flags }
                    // flags & 1 → inline type import (import { type X }) → 런타임 바인딩 불필요
                    if (spec_node.data.binary.flags & 1 != 0) continue;
                    const imported_idx = spec_node.data.binary.left;
                    const local_idx = spec_node.data.binary.right;
                    if (imported_idx.isNone()) continue;

                    const imported_node = ast.getNode(imported_idx);
                    const imported_name = ast.source[imported_node.span.start..imported_node.span.end];

                    const local_node = if (!local_idx.isNone() and @intFromEnum(local_idx) != @intFromEnum(imported_idx))
                        ast.getNode(local_idx)
                    else
                        imported_node;
                    const local_name = ast.source[local_node.span.start..local_node.span.end];

                    try bindings.append(allocator, .{
                        .kind = .named,
                        .local_name = local_name,
                        .imported_name = imported_name,
                        .local_span = local_node.span,
                        .import_record_index = rec_idx,
                    });
                },
                else => {},
            }
        }
    }

    return bindings.toOwnedSlice(allocator);
}

/// AST에서 export 바인딩 상세를 추출한다.
/// import_bindings가 주어지면 barrel re-export 패턴을 자동 감지한다.
/// (Rolldown 방식: export symbol이 import binding에 있으면 .re_export로 분류)
pub fn extractExportBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    import_records: []const types.ImportRecord,
    import_bindings: []const ImportBinding,
) ![]ExportBinding {
    var bindings: std.ArrayList(ExportBinding) = .empty;
    errdefer bindings.deinit(allocator);

    // import source span → import_record 인덱스 매핑 (re-export용)
    var source_to_record = std.AutoHashMap(u64, u32).init(allocator);
    defer source_to_record.deinit();
    for (import_records, 0..) |rec, i| {
        const key = types.spanKey(rec.span);
        try source_to_record.put(key, @intCast(i));
    }

    // import local_name → ImportBinding 매핑 (barrel re-export O(1) 조회)
    var import_by_name: std.StringHashMapUnmanaged(ImportBinding) = .{};
    defer import_by_name.deinit(allocator);
    for (import_bindings) |ib| {
        try import_by_name.put(allocator, ib.local_name, ib);
    }

    for (ast.nodes.items) |node| {
        switch (node.tag) {
            .export_named_declaration => {
                const e = node.data.extra;
                if (e + 3 >= ast.extra_data.items.len) continue;

                const extras = ast.extra_data.items[e .. e + 4];
                const decl_idx: NodeIndex = @enumFromInt(extras[0]);
                const specs_start = extras[1];
                const specs_len = extras[2];
                const source_idx: NodeIndex = @enumFromInt(extras[3]);

                // export const x = 1; / export function f() {}
                if (!decl_idx.isNone()) {
                    const decl_node = ast.getNode(decl_idx);
                    // variable_declaration은 여러 declarator를 가질 수 있음 (export const x=1, y=2)
                    const names = try extractDeclExportNames(allocator, ast, decl_node);
                    defer allocator.free(names);
                    for (names) |name_info| {
                        // destructuring은 local export로 유지.
                        // export const { X } = importedDefault → 코드가 번들에 포함되어야 함
                        // (esbuild 동일: ESM 래퍼 코드를 유지하고 CJS preamble 생성)
                        try bindings.append(allocator, .{
                            .exported_name = name_info.name,
                            .local_name = name_info.name,
                            .local_span = name_info.span,
                            .kind = .local,
                        });
                    }
                    continue;
                }

                // export { a, b } 또는 export { a } from './dep'
                const has_source = !source_idx.isNone();
                const rec_idx: ?u32 = if (has_source) blk: {
                    const src_node = ast.getNode(source_idx);
                    break :blk source_to_record.get(types.spanKey(src_node.span));
                } else null;

                if (specs_len > 0) {
                    const spec_indices = ast.extra_data.items[specs_start .. specs_start + specs_len];
                    for (spec_indices) |raw_idx| {
                        const spec: NodeIndex = @enumFromInt(raw_idx);
                        if (spec.isNone()) continue;
                        if (@intFromEnum(spec) >= ast.nodes.items.len) continue;
                        const spec_node = ast.getNode(spec);
                        if (spec_node.tag != .export_specifier) continue;

                        // binary { left=local, right=exported }
                        const local_idx = spec_node.data.binary.left;
                        const exported_idx = spec_node.data.binary.right;
                        if (local_idx.isNone()) continue;

                        const local_node = ast.getNode(local_idx);
                        const local_name = ast.source[local_node.span.start..local_node.span.end];

                        const exported_node = if (!exported_idx.isNone() and @intFromEnum(exported_idx) != @intFromEnum(local_idx))
                            ast.getNode(exported_idx)
                        else
                            local_node;
                        const exported_name = ast.source[exported_node.span.start..exported_node.span.end];

                        // Rolldown 방식: from 절이 없어도 local_name이 import binding이면
                        // barrel re-export로 분류 (import { X } from './a'; export { X })
                        var kind: ExportBinding.Kind = if (has_source) .re_export else .local;
                        var final_rec_idx: ?u32 = rec_idx;
                        var final_local_name = local_name;
                        // Rolldown 방식: namespace가 아닌 named import만 .re_export로 분류.
                        // namespace barrel re-export(import * as z; export { z })는
                        // .local 유지 — linker가 namespace 객체를 별도 생성.
                        if (!has_source) {
                            if (import_by_name.get(local_name)) |ib| {
                                if (ib.kind != .namespace) {
                                    kind = .re_export;
                                    final_rec_idx = ib.import_record_index;
                                    final_local_name = ib.imported_name;
                                }
                            }
                        }

                        try bindings.append(allocator, .{
                            .exported_name = exported_name,
                            .local_name = final_local_name,
                            .local_span = local_node.span,
                            .kind = kind,
                            .import_record_index = final_rec_idx,
                        });
                    }
                }
            },
            .export_default_declaration => {
                // rolldown 방식: export default의 inner가 선언/식별자이면 해당 이름을 재사용.
                // export default function greet() → local_name = "greet"
                // export default class Foo → local_name = "Foo"
                // export default someVar → local_name = "someVar" (rolldown: 심볼 재사용)
                // export default 42 → local_name = "_default"
                const inner_idx = node.data.unary.operand;
                var local_name: []const u8 = "_default";
                if (!inner_idx.isNone()) {
                    const inner = ast.getNode(inner_idx);
                    if (inner.tag == .function_declaration or inner.tag == .class_declaration) {
                        const e = inner.data.extra;
                        if (e < ast.extra_data.items.len) {
                            const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
                            if (!name_idx.isNone()) {
                                const name_node = ast.getNode(name_idx);
                                local_name = ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
                            }
                        }
                    } else if (inner.tag == .identifier_reference) {
                        // export default someVar → 해당 변수의 심볼을 default export로 재사용
                        const name = ast.getText(inner.span);
                        if (name.len > 0) local_name = name;
                    }
                }
                // export { X }와 동일: local_name이 import binding이면 re_export로 분류
                // (export default EventEmitter where EventEmitter is imported)
                var kind: ExportBinding.Kind = .local;
                var final_rec_idx: ?u32 = null;
                var final_local_name = local_name;
                if (import_by_name.get(local_name)) |ib| {
                    if (ib.kind != .namespace) {
                        kind = .re_export;
                        final_rec_idx = ib.import_record_index;
                        final_local_name = ib.imported_name;
                    }
                }
                try bindings.append(allocator, .{
                    .exported_name = "default",
                    .local_name = final_local_name,
                    .local_span = node.span,
                    .kind = kind,
                    .import_record_index = final_rec_idx,
                });
            },
            .export_all_declaration => {
                // binary { left=exported_name, right=source_node }
                const exported_name_idx = node.data.binary.left;
                const source_idx = node.data.binary.right;
                if (source_idx.isNone()) continue;
                const src_node = ast.getNode(source_idx);
                const rec_idx = source_to_record.get(types.spanKey(src_node.span));

                if (!exported_name_idx.isNone()) {
                    // export * as ns from './mod' — namespace re-export
                    // exported_name = "ns", local_name = "ns" (preamble에서 var ns = {...} 생성)
                    const name_node = ast.getNode(exported_name_idx);
                    const name_text = ast.source[name_node.data.string_ref.start..name_node.data.string_ref.end];
                    try bindings.append(allocator, .{
                        .exported_name = name_text,
                        .local_name = name_text,
                        .local_span = node.span,
                        .kind = .re_export_all,
                        .import_record_index = rec_idx,
                    });
                } else {
                    // export * from './mod' — 일반 re-export all
                    try bindings.append(allocator, .{
                        .exported_name = "*",
                        .local_name = "*",
                        .local_span = node.span,
                        .kind = .re_export_all,
                        .import_record_index = rec_idx,
                    });
                }
            },
            else => {},
        }
    }

    return bindings.toOwnedSlice(allocator);
}

const NameInfo = struct { name: []const u8, span: Span };

/// export 선언에서 이름들을 추출. export const x, y / export function f / export class C
fn extractDeclExportNames(allocator: std.mem.Allocator, ast: *const Ast, decl: Node) ![]NameInfo {
    var names: std.ArrayList(NameInfo) = .empty;
    errdefer names.deinit(allocator);

    switch (decl.tag) {
        .variable_declaration => {
            // extra [kind_flags, list.start, list.len]
            const e = decl.data.extra;
            if (e + 2 >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const list_start = ast.extra_data.items[e + 1];
            const list_len = ast.extra_data.items[e + 2];
            if (list_len == 0) return names.toOwnedSlice(allocator);

            // 모든 declarator 순회
            var i: u32 = 0;
            while (i < list_len) : (i += 1) {
                const idx = list_start + i;
                if (idx >= ast.extra_data.items.len) break;
                const decl_idx: NodeIndex = @enumFromInt(ast.extra_data.items[idx]);
                if (decl_idx.isNone()) continue;
                if (@intFromEnum(decl_idx) >= ast.nodes.items.len) continue;
                const decl_node = ast.getNode(decl_idx);
                if (decl_node.tag != .variable_declarator) continue;
                // variable_declarator: extra [name, type_ann, init_expr]
                const de = decl_node.data.extra;
                if (de >= ast.extra_data.items.len) continue;
                const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[de]);
                if (name_idx.isNone()) continue;
                if (@intFromEnum(name_idx) >= ast.nodes.items.len) continue;
                const name_node = ast.getNode(name_idx);

                // destructuring: export const { X, Y } = obj
                if (name_node.tag == .object_pattern) {
                    try extractObjectPatternNames(&names, allocator, ast, name_node);
                } else {
                    try names.append(allocator, .{
                        .name = ast.source[name_node.span.start..name_node.span.end],
                        .span = name_node.span,
                    });
                }
            }
        },
        .function_declaration => {
            const e = decl.data.extra;
            if (e >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
            if (name_idx.isNone()) return names.toOwnedSlice(allocator);
            const name_node = ast.getNode(name_idx);
            try names.append(allocator, .{
                .name = ast.source[name_node.span.start..name_node.span.end],
                .span = name_node.span,
            });
        },
        .class_declaration => {
            const e = decl.data.extra;
            if (e >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
            if (name_idx.isNone()) return names.toOwnedSlice(allocator);
            const name_node = ast.getNode(name_idx);
            try names.append(allocator, .{
                .name = ast.source[name_node.span.start..name_node.span.end],
                .span = name_node.span,
            });
        },
        else => {},
    }

    return names.toOwnedSlice(allocator);
}

/// object_pattern의 각 프로퍼티 이름을 추출한다.
/// `{ Command, Option }` → ["Command", "Option"]
fn extractObjectPatternNames(
    names: *std.ArrayList(NameInfo),
    allocator: std.mem.Allocator,
    ast: *const Ast,
    pattern: Node,
) !void {
    const list = pattern.data.list;
    if (list.len == 0) return;
    if (list.start + list.len > ast.extra_data.items.len) return;
    const indices = ast.extra_data.items[list.start .. list.start + list.len];
    for (indices) |raw_idx| {
        const prop_idx: NodeIndex = @enumFromInt(raw_idx);
        if (prop_idx.isNone() or @intFromEnum(prop_idx) >= ast.nodes.items.len) continue;
        const prop = ast.getNode(prop_idx);
        switch (prop.tag) {
            .binding_property => {
                // binary: left=key, right=value
                // shorthand { X } → left == right (같은 노드), exported_name = "X"
                // rename { X: Y } → left=key "X", right=value "Y", exported_name = key
                const key = ast.getNode(prop.data.binary.left);
                const exported_name = ast.source[key.span.start..key.span.end];
                try names.append(allocator, .{
                    .name = exported_name,
                    .span = key.span,
                });
            },
            else => {},
        }
    }
}

/// namespace import의 실제 프로퍼티 접근을 수집한다.
/// `import * as v from 'mod'; v.object(); v.parse();`
/// → v의 namespace_used_properties = ["object", "parse"]
///
/// namespace가 member access 외의 방식으로 사용되면 (함수 인자, 대입 등)
/// fallback으로 null (전체 사용)을 유지한다.
pub fn collectNamespaceAccesses(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    bindings: []ImportBinding,
) !void {
    var ns_map: std.StringHashMapUnmanaged(usize) = .{};
    defer ns_map.deinit(allocator);
    for (bindings, 0..) |ib, i| {
        if (ib.kind == .namespace) {
            try ns_map.put(allocator, ib.local_name, i);
        }
    }
    if (ns_map.count() == 0) return;

    // member access의 object로 사용된 identifier 노드 인덱스
    var member_obj_set = std.AutoHashMap(u32, void).init(allocator);
    defer member_obj_set.deinit();

    // binding index → 사용된 프로퍼티 이름 (자연 중복 제거)
    var props_map = std.AutoHashMap(usize, std.StringHashMapUnmanaged(void)).init(allocator);
    defer {
        var it = props_map.valueIterator();
        while (it.next()) |set| set.deinit(allocator);
        props_map.deinit();
    }

    // 탈출된 namespace identifier 노드 인덱스 (후처리용)
    const EscapedRef = struct { ni: u32, binding_idx: usize };
    var escaped_refs: std.ArrayListUnmanaged(EscapedRef) = .empty;
    defer escaped_refs.deinit(allocator);

    // 단일 패스: member access 수집 + 탈출 후보 기록
    for (ast.nodes.items, 0..) |node, ni| {
        switch (node.tag) {
            .static_member_expression => {
                const me = node.data.extra;
                if (!ast.hasExtra(me, 1)) continue;

                const obj_idx = ast.readExtraNode(me, 0);
                const obj_ni = @intFromEnum(obj_idx);
                if (obj_ni >= ast.nodes.items.len) continue;
                const obj = ast.nodes.items[obj_ni];
                if (obj.tag != .identifier_reference) continue;

                const obj_name = ast.getText(obj.span);
                const binding_idx = ns_map.get(obj_name) orelse continue;

                const prop_idx = ast.readExtraNode(me, 1);
                const prop_ni = @intFromEnum(prop_idx);
                if (prop_ni >= ast.nodes.items.len) continue;
                const prop = ast.nodes.items[prop_ni];

                try member_obj_set.put(@intCast(obj_ni), {});

                const entry = try props_map.getOrPut(binding_idx);
                if (!entry.found_existing) entry.value_ptr.* = .{};
                try entry.value_ptr.put(allocator, ast.getText(prop.span), {});
            },
            .identifier_reference => {
                const name = ast.getText(node.span);
                if (ns_map.get(name)) |binding_idx| {
                    try escaped_refs.append(allocator, .{ .ni = @intCast(ni), .binding_idx = binding_idx });
                }
            },
            .computed_member_expression => {
                // v[dynamic] → namespace 탈출
                const me = node.data.extra;
                if (!ast.hasExtra(me, 0)) continue;
                const obj_idx = ast.readExtraNode(me, 0);
                const obj_ni = @intFromEnum(obj_idx);
                if (obj_ni >= ast.nodes.items.len) continue;
                const obj = ast.nodes.items[obj_ni];
                if (obj.tag != .identifier_reference) continue;
                if (ns_map.get(ast.getText(obj.span))) |binding_idx| {
                    bindings[binding_idx].namespace_used_properties = null;
                    _ = ns_map.remove(ast.getText(obj.span));
                }
            },
            else => {},
        }
    }

    // 후처리: member access object가 아닌 identifier_reference → 탈출
    for (escaped_refs.items) |ref| {
        if (!ns_map.contains(bindings[ref.binding_idx].local_name)) continue;
        if (!member_obj_set.contains(ref.ni)) {
            bindings[ref.binding_idx].namespace_used_properties = null;
            _ = ns_map.remove(bindings[ref.binding_idx].local_name);
        }
    }

    // 결과를 ImportBinding에 반영
    for (bindings, 0..) |*ib, idx| {
        if (ib.kind != .namespace) continue;
        if (!ns_map.contains(ib.local_name)) continue; // 탈출됨 → null 유지

        if (props_map.getPtr(idx)) |set| {
            const props = try allocator.alloc([]const u8, set.count());
            var i: usize = 0;
            var kit = set.keyIterator();
            while (kit.next()) |key| : (i += 1) {
                props[i] = key.*;
            }
            ib.namespace_used_properties = props;
        } else {
            ib.namespace_used_properties = &.{};
        }
    }
}

