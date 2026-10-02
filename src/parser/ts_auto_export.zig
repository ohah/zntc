//! TS의 자동 type-only export elision 공용 처리.

const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const ast_walk = @import("ast_walk.zig");
const module_parser = @import("module.zig");
const scan_results = @import("scan_results.zig");

/// Babel `preset-typescript` 의 자동 type-only export elision 을 모든 변환 경로에서
/// 재현. transformer 의 `.export_specifier` 디스패치가 SPEC_FLAG_TYPE_ONLY 비트를 보고
/// 자동 drop 하므로, 비트만 일관되게 마킹하면 .none / .bindings / .full 모두 동일 출력.
///
/// **호출 시점**: `SemanticAnalyzer.analyze()` 호출 전. .full 경로의 analyzer 가
/// 마킹된 비트를 보고 specifier 검증을 skip 한다. .none / .bindings 도 동일 비트 기반.
///
/// **두 패스**:
///   pass 1 (top-level statement walk): value binding name (var/let/const/function/class
///   /enum, import default/namespace/named-value) 과 type-only binding name (type alias,
///   interface, import-type specifier) 을 각각 set 에 수집. declaration merging
///   (`const X = 1; type X = ...;`) 처리를 위해 value 가 type 보다 우선.
///   pass 2 (export_named_declaration scan): source 없는 `export { x }` 의 specifier
///   중 local 이 value_names 에 없고 type_only_names 에 있는 것만 비트 OR.
///
/// 재-export (`export { x } from './y'`) 는 로컬 binding 과 무관 → skip.
/// `export { 'name' }` string literal local 도 식별자가 아니라 skip.
pub fn markAutoTypeOnlyExportSpecifiers(
    allocator: std.mem.Allocator,
    ast: *Ast,
    scan_export_bindings: ?*std.ArrayListUnmanaged(scan_results.ScanExportBinding),
) error{OutOfMemory}!void {
    // program 의 top-level statements 만 본다. ES module spec: export 는 모듈 scope
    // binding 만 reference. nested function 의 local var/type alias 는 export 와 무관.
    var program_idx: ast_mod.NodeIndex = .none;
    for (ast.nodes.items, 0..) |node, raw_idx| {
        if (node.tag == .program) {
            program_idx = @enumFromInt(raw_idx);
            break;
        }
    }
    if (program_idx.isNone()) return;
    const prog_node = ast.getNode(program_idx);
    const stmt_start = prog_node.data.list.start;
    const stmt_len = prog_node.data.list.len;
    if (stmt_len == 0) return;

    var value_names: std.StringHashMapUnmanaged(void) = .empty;
    defer value_names.deinit(allocator);
    var type_only_names: std.StringHashMapUnmanaged(void) = .empty;
    defer type_only_names.deinit(allocator);

    // pass 1
    var i: u32 = 0;
    while (i < stmt_len) : (i += 1) {
        const stmt_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[stmt_start + i]);
        if (stmt_idx.isNone()) continue;
        if (@intFromEnum(stmt_idx) >= ast.nodes.items.len) continue;
        try collectAutoTypeOnlyDeclNames(allocator, ast, stmt_idx, &value_names, &type_only_names);
    }

    // ast.type_only_binding_names: `declare` 와 `export default interface`처럼 parser가
    // AST에서 제거한 type-only 선언의 이름을 사이드테이블에서 읽는다.
    if (type_only_names.count() == 0 and ast.type_only_binding_names.count() == 0) return;

    // pass 2: program root의 직접 자식만 방문한다. namespace body의 export는
    // 같은 철자의 top-level type alias와 무관한 runtime namespace member일 수 있다.
    i = 0;
    while (i < stmt_len) : (i += 1) {
        const stmt_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[stmt_start + i]);
        if (stmt_idx.isNone() or @intFromEnum(stmt_idx) >= ast.nodes.items.len) continue;
        const node = ast.getNode(stmt_idx);
        if (node.tag != .export_named_declaration) continue;
        const extra_start = node.data.extra;
        const extras = ast.extra_data.items;
        if (extra_start > extras.len or extras.len - extra_start < 6) continue;
        const export_decl = module_parser.readExportNamedExtras(ast, extra_start);
        if (!export_decl.decl.isNone() or !export_decl.source.isNone()) continue;
        if (export_decl.specs_len == 0 or
            export_decl.specs_start > extras.len or
            export_decl.specs_len > extras.len - export_decl.specs_start) continue;

        const spec_indices = extras[export_decl.specs_start .. export_decl.specs_start + export_decl.specs_len];
        for (spec_indices) |raw_idx| {
            const spec_idx: ast_mod.NodeIndex = @enumFromInt(raw_idx);
            if (spec_idx.isNone()) continue;
            if (@intFromEnum(spec_idx) >= ast.nodes.items.len) continue;
            const spec_node = ast.getNode(spec_idx);
            if (spec_node.tag != .export_specifier) continue;
            if ((spec_node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;

            const local_idx = spec_node.data.binary.left;
            if (local_idx.isNone()) continue;
            if (@intFromEnum(local_idx) >= ast.nodes.items.len) continue;
            const local_node = ast.getNode(local_idx);
            if (local_node.tag == .string_literal) continue;

            const local_name = ast.getText(local_node.span);
            // declaration merging: 동명의 value binding 이 있으면 type-only 마킹 skip.
            // `const X = 1; type X = ...; export { X };` 또는
            // `class A {}; declare class A; export { A };` 양쪽에서 value 우선.
            if (value_names.contains(local_name)) continue;
            if (type_only_names.contains(local_name) or
                ast.type_only_binding_names.contains(local_name))
            {
                ast.setBinaryFlags(spec_idx, spec_node.data.binary.flags | module_parser.SPEC_FLAG_TYPE_ONLY);
            }
        }
    }

    if (scan_export_bindings) |bindings| {
        try pruneMarkedScanExportBindings(allocator, ast, bindings);
    }
}

/// Parser inline scan이 semantic 분류 전에 기록한 export 중, 방금 type-only로
/// 마킹된 최상위 local specifier의 scan record를 제거한다. bundler가 semantic 분석
/// 전에 ExportBinding을 materialize하므로 AST flag와 scan metadata를 함께 갱신해야 한다.
fn pruneMarkedScanExportBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    bindings: *std.ArrayListUnmanaged(scan_results.ScanExportBinding),
) error{OutOfMemory}!void {
    if (bindings.items.len == 0 or ast.nodes.items.len == 0) return;

    var program_idx: ast_mod.NodeIndex = .none;
    for (ast.nodes.items, 0..) |node, raw_idx| {
        if (node.tag == .program) {
            program_idx = @enumFromInt(raw_idx);
            break;
        }
    }
    if (program_idx.isNone()) return;
    const program = ast.getNode(program_idx);
    const statements = program.data.list;
    if (statements.start > ast.extra_data.items.len or
        statements.len > ast.extra_data.items.len - statements.start) return;

    var marked_local_starts: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer marked_local_starts.deinit(allocator);

    for (ast.extra_data.items[statements.start .. statements.start + statements.len]) |raw_stmt_idx| {
        if (raw_stmt_idx >= ast.nodes.items.len) continue;
        const statement = ast.getNode(@enumFromInt(raw_stmt_idx));
        if (statement.tag != .export_named_declaration) continue;
        const extra_start = statement.data.extra;
        if (extra_start > ast.extra_data.items.len or ast.extra_data.items.len - extra_start < 6) continue;
        const export_decl = module_parser.readExportNamedExtras(ast, extra_start);
        if (!export_decl.decl.isNone() or !export_decl.source.isNone()) continue;
        if (export_decl.specs_start > ast.extra_data.items.len or
            export_decl.specs_len > ast.extra_data.items.len - export_decl.specs_start) continue;

        for (ast.extra_data.items[export_decl.specs_start .. export_decl.specs_start + export_decl.specs_len]) |raw_spec_idx| {
            if (raw_spec_idx >= ast.nodes.items.len) continue;
            const spec_idx: ast_mod.NodeIndex = @enumFromInt(raw_spec_idx);
            const specifier = ast.getNode(spec_idx);
            if (specifier.tag != .export_specifier or
                (specifier.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) == 0) continue;
            const local_idx = specifier.data.binary.left;
            if (local_idx.isNone() or @intFromEnum(local_idx) >= ast.nodes.items.len) continue;
            const local = ast.getNode(local_idx);
            if (local.tag == .string_literal) continue;
            try marked_local_starts.put(allocator, local.span.start, {});
        }
    }

    if (marked_local_starts.count() == 0) return;
    var write_index: usize = 0;
    for (bindings.items) |binding| {
        if (marked_local_starts.contains(binding.local_span.start)) continue;
        bindings.items[write_index] = binding;
        write_index += 1;
    }
    bindings.items.len = write_index;
}

/// `markAutoTypeOnlyExportSpecifiers` pass 1 의 statement-level 분기. top-level
/// program statement 한 개를 처리.
fn collectAutoTypeOnlyDeclNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    stmt_idx: ast_mod.NodeIndex,
    value_names: *std.StringHashMapUnmanaged(void),
    type_only_names: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    const stmt = ast.getNode(stmt_idx);
    switch (stmt.tag) {
        // value bindings: function / class / enum — extras[0] = name
        .function_declaration,
        .class_declaration,
        .ts_enum_declaration,
        => try putNameAtExtraSlot(allocator, ast, stmt, 0, value_names),

        // ts_module_declaration: binary layout — binary.left = name (namespace) 또는
        // string_literal (declare module "..."). 후자는 binding 이름이 아니라 skip.
        .ts_module_declaration => {
            const name_idx = stmt.data.binary.left;
            if (name_idx.isNone()) return;
            if (@intFromEnum(name_idx) >= ast.nodes.items.len) return;
            const name_node = ast.getNode(name_idx);
            if (name_node.tag == .string_literal) return;
            try putNodeIdName(allocator, ast, name_idx, value_names);
        },

        // import X = require(...) — runtime value
        .ts_import_equals_declaration => {
            // binary: left=name, right=value
            const left = stmt.data.binary.left;
            try putNodeIdName(allocator, ast, left, value_names);
        },

        // variable_declaration: destructuring 포함 모든 binding identifier 추출.
        // extras = [kind_flags, list_start, list_len]
        .variable_declaration => {
            const list_start = ast.extra_data.items[stmt.data.extra + 1];
            const list_len = ast.extra_data.items[stmt.data.extra + 2];
            var j: u32 = 0;
            while (j < list_len) : (j += 1) {
                const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[list_start + j]);
                if (decl_idx.isNone()) continue;
                const decl = ast.getNode(decl_idx);
                if (decl.tag != .variable_declarator) continue;
                // variable_declarator extras[0] = binding pattern (또는 simple identifier)
                const binding_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.data.extra]);
                try collectBindingIdentifierNames(allocator, ast, binding_idx, value_names);
            }
        },

        // type-only declarations
        .ts_type_alias_declaration,
        .ts_interface_declaration,
        => try putNameAtExtraSlot(allocator, ast, stmt, 0, type_only_names),

        // import declaration: type-only spec / inline `type X` 는 type_only_names,
        // 나머지 (default / namespace / named-value) 는 value_names
        .import_declaration => {
            const decl = module_parser.readImportDeclExtras(ast, stmt.data.extra);
            var j: u32 = 0;
            while (j < decl.specs_len) : (j += 1) {
                const spec_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[decl.specs_start + j]);
                if (spec_idx.isNone()) continue;
                if (@intFromEnum(spec_idx) >= ast.nodes.items.len) continue;
                const spec = ast.getNode(spec_idx);
                switch (spec.tag) {
                    // import_specifier: binary { left=imported, right=local }
                    .import_specifier => {
                        const local_idx = spec.data.binary.right;
                        if (local_idx.isNone()) continue;
                        const is_type_only = decl.is_type_only or
                            (spec.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0;
                        const bucket = if (is_type_only) type_only_names else value_names;
                        try putNodeIdName(allocator, ast, local_idx, bucket);
                    },
                    // import_default_specifier / import_namespace_specifier: 파서가 local
                    // 이름을 spec_node.span (string_ref) 에 직접 저장 — 별도 name 노드
                    // 없음 (module.zig parseImportClause). codegen/analyzer 와 동일하게
                    // span 텍스트로 읽는다 (D13 layout: 이전엔 extra_data 인덱스로 오독).
                    .import_default_specifier, .import_namespace_specifier => {
                        const name_text = ast.getText(spec.span);
                        if (name_text.len == 0) continue;
                        const bucket = if (decl.is_type_only) type_only_names else value_names;
                        try bucket.put(allocator, name_text, {});
                    },
                    else => {},
                }
            }
        },

        // export declaration 안의 nested decl 도 처리 (export const / type / interface / ...).
        // extras = [decl, specs_start, specs_len, source, ...]
        .export_named_declaration => {
            const extra_start = stmt.data.extra;
            if (extra_start >= ast.extra_data.items.len) return;
            const decl_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra_start]);
            if (decl_idx.isNone()) return;
            if (@intFromEnum(decl_idx) >= ast.nodes.items.len) return;
            // 재귀 분기 — declaration 자체의 binding 만 등록 (specifier 는 pass 2 에서 처리)
            try collectAutoTypeOnlyDeclNames(allocator, ast, decl_idx, value_names, type_only_names);
        },

        else => {},
    }
}

fn putNameAtExtraSlot(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node: ast_mod.Node,
    slot: u32,
    bucket: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    const extra_start = node.data.extra;
    if (extra_start + slot >= ast.extra_data.items.len) return;
    const name_idx: ast_mod.NodeIndex = @enumFromInt(ast.extra_data.items[extra_start + slot]);
    try putNodeIdName(allocator, ast, name_idx, bucket);
}

fn putNodeIdName(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    name_idx: ast_mod.NodeIndex,
    bucket: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    if (name_idx.isNone()) return;
    if (@intFromEnum(name_idx) >= ast.nodes.items.len) return;
    const name_node = ast.getNode(name_idx);
    const name_text = ast.getText(name_node.span);
    if (name_text.len == 0) return;
    try bucket.put(allocator, name_text, {});
}

/// binding pattern (identifier / array / object pattern) 안의 모든 binding identifier
/// 텍스트를 bucket 에 모은다. `const { a: b, c = 1, ...rest } = x;` 같은 destructuring
/// 도 b / c / rest 가 value binding.
fn collectBindingIdentifierNames(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    idx: ast_mod.NodeIndex,
    bucket: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!void {
    if (idx.isNone()) return;
    if (@intFromEnum(idx) >= ast.nodes.items.len) return;
    var it = try ast_walk.bindingIdentifiers(ast.allocator, ast, idx, .{ .cover_grammar_assignment = false });
    defer it.deinit();
    while (try it.next()) |leaf_idx| {
        const leaf = ast.getNode(leaf_idx);
        const name = ast.getText(leaf.span);
        if (name.len > 0) try bucket.put(allocator, name, {});
    }
}
