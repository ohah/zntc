//! ZNTC Bundler — Binding Scanner
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
const ast_walk = @import("../parser/ast_walk.zig");
const Span = @import("../lexer/token.zig").Span;
const types = @import("types.zig");
const module_parser = @import("../parser/module.zig");
const ModuleIndex = types.ModuleIndex;
const symbol_mod = @import("symbol.zig");
const AliasTable = symbol_mod.AliasTable;
const semantic_symbol = @import("../semantic/symbol.zig");
const SemanticSymbol = semantic_symbol.Symbol;

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
    /// `namespace_used_properties[i]`가 접근된 top-level statement 인덱스 목록.
    /// `module.prebuilt_stmt_info.stmts` 인덱스 기준. 길이는 `namespace_used_properties`와 같다.
    /// null = 정보 없음 (fallback: 전체 seed). BFS가 dead-scope access를 걸러내는 근거.
    namespace_used_property_stmts: ?[]const []const u32 = null,
    /// #1328 Phase 2: source 모듈의 export 심볼 참조. invalid = 미해결.
    /// Phase 3에서 linker가 cross-module resolve로 채움. 기존 문자열 로직은
    /// 병존 (Phase 4에서 제거).
    symbol: symbol_mod.SymbolRef = symbol_mod.SymbolRef.invalid,
    /// #1328 Phase 4c-3b: 현재 모듈의 로컬 바인딩 심볼 (semantic scope).
    /// import preamble/rename 경로에서 "현재 모듈 기준" canonical 조회에 사용.
    /// `symbol`은 source 모듈 쪽을 가리키므로 local 경로에는 쓸 수 없다.
    /// linker.populateImportSymbols가 채움. invalid = synthetic binding 등
    /// semantic scope에 로컬이 없는 경우.
    local_symbol: symbol_mod.SymbolRef = symbol_mod.SymbolRef.invalid,
    /// #3068: helper marker (runtime helper / JSX runtime) 가 적용된 binding.
    /// linker 의 local_symbol lookup 이 일반 `module_scope` 가 아닌 격리된
    /// `helper_scope_map` 에서 sym_index 를 찾아야 사용자가 같은 이름의 식별자를
    /// 선언한 경우에도 충돌이 일어나지 않는다.
    is_helper: bool = false,

    pub const Kind = enum {
        default,
        named,
        namespace,
    };

    /// `import x from './m'` (kind=.default) 또는 `import { default as X }`
    /// (kind=.named, imported_name="default") 어느 쪽이든 source의 default를
    /// import하는 케이스 통칭.
    pub fn importsDefault(self: ImportBinding) bool {
        return self.kind == .default or
            (self.kind == .named and std.mem.eql(u8, self.imported_name, "default"));
    }
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
    /// #1328 Phase 2: 이 export가 가리키는 심볼.
    ///   - .local: 현재 모듈의 심볼 (semantic 선언 또는 bundler 합성 `_default`)
    ///   - .re_export: source 모듈의 export 심볼 (Phase 3에서 linker가 채움)
    /// invalid = 미해결. 기존 문자열 로직은 병존 (Phase 4에서 제거).
    symbol: symbol_mod.SymbolRef = symbol_mod.SymbolRef.invalid,

    pub const Kind = enum {
        /// 현재 모듈에서 직접 선언/할당된 export.
        local,
        /// source에서 명시적으로 가져온 named re-export (예: `export { x } from`).
        re_export,
        /// `export * from './m'` — 모든 export 합치기 (alias 없음).
        re_export_star,
        /// `export * as ns from './m'` — namespace 객체로 노출.
        re_export_namespace,

        /// `re_export_star`/`re_export_namespace` 통칭 (구 `re_export_all`).
        pub fn isReExportAll(self: Kind) bool {
            return self == .re_export_star or self == .re_export_namespace;
        }

        /// `.re_export` + `.re_export_*` 모두 포함 — 임의의 cross-module re-export.
        pub fn isAnyReExport(self: Kind) bool {
            return self == .re_export or self == .re_export_star or self == .re_export_namespace;
        }
    };

    /// `export { default } from './m'` 같이 default → default 직진 named re-export
    /// 인지. wrapper-barrel pattern (lodash-es lodash.js → lodash.default.js) detection
    /// 의 한 부분. `default as X` 같이 alias 가 들어가는 케이스는 false.
    pub fn isDefaultDirectReExport(self: ExportBinding) bool {
        return self.kind == .re_export and
            std.mem.eql(u8, self.exported_name, "default") and
            std.mem.eql(u8, self.local_name, "default");
    }

    /// `export default <named-local>` (예: `var lib={}; export default lib`,
    /// lodash-es lodash.default.js) — default 가 이름 있는 로컬 바인딩.
    /// 표현식 default 는 binding_scanner 가 합성 `_default` 를 local_name 으로
    /// 쓰므로 제외. `isDefaultDirectReExport`(re-export 형) 와 상보적.
    pub fn isNamedLocalDefault(self: ExportBinding) bool {
        return self.kind == .local and
            std.mem.eql(u8, self.exported_name, "default") and
            !std.mem.eql(u8, self.local_name, "_default");
    }

    /// 이 export 때문에 현재 모듈에 `_default` 합성 변수가 생기는지 확인.
    /// #1338 Phase 4e-2d-a: synthetic_default는 항상 semantic 공간에 등록됨.
    pub fn hasSyntheticDefault(
        self: ExportBinding,
        symbols: []const SemanticSymbol,
    ) bool {
        return switch (self.symbol) {
            .alias => false,
            .semantic => |s| blk: {
                if (s.symbol.isNone()) break :blk false;
                const idx: u32 = @intFromEnum(s.symbol);
                if (idx >= symbols.len) break :blk false;
                const sk = symbols[idx].synthetic_kind orelse break :blk false;
                break :blk sk == .default_export;
            },
        };
    }
};

/// AST에서 import 바인딩 상세를 추출한다.
/// import_record_map: import source span → ImportRecord 인덱스 매핑
/// `helper_ref_nodes` 가 non-null 이면 import_specifier 의 local_node idx 가 그 slice 에
/// 있을 때 해당 binding 에 `is_helper=true` 를 set 한다. linker 가 이 binding 의 local_symbol
/// 을 일반 module_scope 가 아닌 격리된 helper_scope_map 에서 찾도록 보장 — 사용자가 같은
/// 식별자를 선언해도 충돌 회피 (#3068).
///
/// `helper_ref_nodes` 는 ascending sorted 여야 한다 (binary search 전제). transformer 의
/// `markRuntimeHelperRef` 가 새 NodeIndex 만 단조 증가로 append → `ownedHelperRefNodes` 가
/// 그 invariant 를 보존하며 sort 한다 (analyzer.zig 의 `isHelperRefNode` 도 동일 가정).
pub fn extractImportBindings(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    import_records: []const types.ImportRecord,
    helper_ref_nodes: ?[]const u32,
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

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, ast);
    defer allocator.free(reachable);

    for (reachable) |ni| {
        const node = ast.nodes.items[ni];
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
                    const name = try ast.getTextStable(allocator, spec_node.span);
                    try bindings.append(allocator, .{
                        .kind = .default,
                        .local_name = name,
                        .imported_name = "default",
                        .local_span = spec_node.span,
                        .import_record_index = rec_idx,
                    });
                },
                .import_namespace_specifier => {
                    const name = try ast.getTextStable(allocator, spec_node.span);
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
                    // SPEC_FLAG_TYPE_ONLY → inline type import (import { type X }) → 런타임 바인딩 불필요
                    if ((spec_node.data.binary.flags & module_parser.SPEC_FLAG_TYPE_ONLY) != 0) continue;
                    const imported_idx = spec_node.data.binary.left;
                    const local_idx = spec_node.data.binary.right;
                    if (imported_idx.isNone()) continue;

                    const imported_node = ast.getNode(imported_idx);
                    const imported_name = try ast.getTextStable(allocator, imported_node.span);

                    const local_node_idx = if (!local_idx.isNone() and @intFromEnum(local_idx) != @intFromEnum(imported_idx))
                        local_idx
                    else
                        imported_idx;
                    const local_node = ast.getNode(local_node_idx);
                    const local_name = try ast.getTextStable(allocator, local_node.span);

                    const is_helper = if (helper_ref_nodes) |refs|
                        std.sort.binarySearch(u32, refs, @intFromEnum(local_node_idx), struct {
                            fn cmp(needle: u32, item: u32) std.math.Order {
                                return std.math.order(needle, item);
                            }
                        }.cmp) != null
                    else
                        false;

                    try bindings.append(allocator, .{
                        .kind = .named,
                        .local_name = local_name,
                        .imported_name = imported_name,
                        .local_span = local_node.span,
                        .import_record_index = rec_idx,
                        .is_helper = is_helper,
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

    const reachable = try ast_walk.collectReachableNodeIndices(allocator, ast);
    defer allocator.free(reachable);

    for (reachable) |ni| {
        const node = ast.nodes.items[ni];
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
                        const local_name = ast.getText(local_node.span);

                        const exported_node = if (!exported_idx.isNone() and @intFromEnum(exported_idx) != @intFromEnum(local_idx))
                            ast.getNode(exported_idx)
                        else
                            local_node;
                        const exported_name = ast.getText(exported_node.span);

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
                                local_name = ast.getText(name_node.data.string_ref);
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
                const x = module_parser.readExportAllExtras(ast, node.data.extra);
                const exported_name_idx = x.exported_name;
                const source_idx = x.source;
                if (source_idx.isNone()) continue;
                const src_node = ast.getNode(source_idx);
                const rec_idx = source_to_record.get(types.spanKey(src_node.span));

                if (!exported_name_idx.isNone()) {
                    // export * as ns from './mod' — namespace re-export
                    // exported_name = "ns", local_name = "ns" (preamble에서 var ns = {...} 생성)
                    const name_node = ast.getNode(exported_name_idx);
                    const name_text = ast.getText(name_node.data.string_ref);
                    try bindings.append(allocator, .{
                        .exported_name = name_text,
                        .local_name = name_text,
                        .local_span = node.span,
                        .kind = .re_export_namespace,
                        .import_record_index = rec_idx,
                    });
                } else {
                    // export * from './mod' — 일반 re-export all
                    try bindings.append(allocator, .{
                        .exported_name = "*",
                        .local_name = "*",
                        .local_span = node.span,
                        .kind = .re_export_star,
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

                try extractBindingPatternNames(&names, allocator, ast, name_idx);
            }
        },
        // 모두 extra[0] 이 이름 노드 (function: [name, ...], class: [name, ...],
        // enum: [name, members_start, members_len, flags]).
        .function_declaration, .class_declaration, .ts_enum_declaration => {
            const e = decl.data.extra;
            if (e >= ast.extra_data.items.len) return names.toOwnedSlice(allocator);
            const name_idx: NodeIndex = @enumFromInt(ast.extra_data.items[e]);
            if (name_idx.isNone()) return names.toOwnedSlice(allocator);
            const name_node = ast.getNode(name_idx);
            try names.append(allocator, .{
                .name = ast.getText(name_node.span),
                .span = name_node.span,
            });
        },
        else => {},
    }

    return names.toOwnedSlice(allocator);
}

/// declaration binding pattern의 BoundNames를 export 이름으로 추출한다.
/// `export const [a, b] = ...` → ["a", "b"]
/// `export const { key: local } = ...` → ["local"]
fn extractBindingPatternNames(
    names: *std.ArrayList(NameInfo),
    allocator: std.mem.Allocator,
    ast: *const Ast,
    pattern_idx: NodeIndex,
) !void {
    var w = try ast_walk.bindingIdentifiers(allocator, ast, pattern_idx, .{});
    defer w.deinit();
    while (try w.next()) |name_idx| {
        const name_node = ast.getNode(name_idx);
        try names.append(allocator, .{
            .name = ast.getText(name_node.span),
            .span = name_node.span,
        });
    }
}

/// namespace import의 실제 프로퍼티 접근을 수집한다.
/// `import * as v from 'mod'; v.object(); v.parse();`
/// → v의 namespace_used_properties = ["object", "parse"]
///
/// namespace가 member access 외의 방식으로 사용되면 (함수 인자, 대입 등)
/// fallback으로 null (전체 사용)을 유지한다.
/// 통합 namespace access 분석 (#3680 PR #3736).
/// 옛 collectNamespaceAccesses 의 text-based 로직을 `linker/namespace_access.zig` 의
/// `analyzeNamespaceAccessTextOnly` 로 위임 — 두 path 가 동일 분석기 사용.
/// 결과 매핑:
///   - opaque (escape / computed access) → `namespace_used_properties = null`
///   - member_only with props → `namespace_used_properties = [props...]`
///   - member_only empty → `namespace_used_properties = &.{}`
pub fn collectNamespaceAccesses(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    bindings: []ImportBinding,
) !void {
    var index = try collectNamespaceAccessesAndBuildIndex(allocator, ast, bindings, &.{}, .{});
    index.deinit(allocator);
}

/// PR #3738 (C6 perf): `collectNamespaceAccesses` 와 동일 분석 + index 반환.
/// `extra_interest_locals` 가 주어지면 (linker 의 named/cjs/esm 같이) 그 local 들도 색인 →
/// linker 가 같은 index 를 share 가능.
/// `opts.reachable_only` 가 false 면 모든 nodes 색인 (linker 호환).
///
/// caller 가 index ownership — `defer index.deinit(allocator)` 또는 module 에 store.
pub fn collectNamespaceAccessesAndBuildIndex(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    bindings: []ImportBinding,
    extra_interest_locals: []const []const u8,
    opts: struct { reachable_only: bool = true },
) !@import("linker/namespace_access.zig").NamespaceAccessIndex {
    const ns_module = @import("linker/namespace_access.zig");

    var has_any_interest = extra_interest_locals.len > 0;
    if (!has_any_interest) {
        for (bindings) |ib| {
            if (ib.kind == .namespace) {
                has_any_interest = true;
                break;
            }
        }
    }
    // 빈 index 반환 — caller 가 deinit (no-op).
    if (!has_any_interest) return .{};

    // interest set — namespace local + extra (linker 의 named/cjs/esm).
    var interest: std.StringHashMapUnmanaged(void) = .{};
    defer interest.deinit(allocator);
    for (bindings) |ib| {
        if (ib.kind == .namespace and ib.local_name.len > 0) {
            try interest.put(allocator, ib.local_name, {});
        }
    }
    for (extra_interest_locals) |name| {
        if (name.len > 0) try interest.put(allocator, name, {});
    }

    var index = try ns_module.NamespaceAccessIndex.buildOpt(allocator, ast, opts.reachable_only, &interest);
    errdefer index.deinit(allocator);

    for (bindings) |*ib| {
        if (ib.kind != .namespace) continue;
        var access = try ns_module.analyzeNamespaceAccessTextOnly(allocator, ast, &index, ib.local_name, null);
        defer access.deinit(allocator);

        if (access.kind == .@"opaque") {
            ib.namespace_used_properties = null;
            continue;
        }
        const count = access.members.count();
        if (count == 0) {
            ib.namespace_used_properties = &.{};
            continue;
        }
        const props = try allocator.alloc([]const u8, count);
        var i: usize = 0;
        var it = access.members.iterator();
        while (it.next()) |entry| : (i += 1) {
            props[i] = entry.key_ptr.*;
        }
        // C4 fix (#3736): 결정성 — HashMap iter 순서 → sort 로 stable.
        std.mem.sort([]const u8, props, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        ib.namespace_used_properties = props;
    }
    return index;
}

/// 모든 ExportBinding의 `symbol` 필드를 채운다. 세 경로:
///   1. `_default = <expr>` 패턴 → semantic 합성 심볼(`default_export`) 등록
///   2. `.re_export` → AliasTable에 alias 등록
///   3. `.local` → `module_scope`에서 동명 심볼 lookup → semantic ref
/// Cross-module re-export 체인 resolve는 linker가 `populateReExportAliases`에서 수행.
pub fn populateSyntheticSymbols(
    table: *AliasTable,
    module_index: ModuleIndex,
    export_bindings: []ExportBinding,
    sem_symbols: *std.ArrayList(SemanticSymbol),
    arena: std.mem.Allocator,
    /// 모듈 top-level scope (scope_maps[0]). 일반 .local export의 eb.symbol을
    /// scope_maps에서 lookup해 미리 채우는 데 사용. null이면 skip — linker가
    /// 후속 패스에서 fallback 처리.
    module_scope: ?std.StringHashMap(usize),
) !void {
    for (export_bindings) |*eb| {
        // codegen이 `_default = <expr>` 할당을 emit하는 export만 synthetic_default 등록.
        if ((eb.kind == .local or eb.kind == .re_export) and
            std.mem.eql(u8, eb.exported_name, "default") and
            (std.mem.eql(u8, eb.local_name, "_default") or std.mem.eql(u8, eb.local_name, "default")))
        {
            // #1598: semantic analyzer의 visitExportDefaultDeclaration이 `_default` facade
            // 심볼을 이미 scope_maps[0]에 등록했다면 그걸 재사용 — extend하면 동일 이름이
            // 중복 등록되어 collectModuleNames가 `_default$1` 충돌 회피 이름을 생성한다.
            if (module_scope) |scope| {
                if (scope.get("_default")) |existing_idx| {
                    if (existing_idx < sem_symbols.items.len) {
                        // 기존 심볼에 default_export synthetic_kind 마킹.
                        // synthetic_name은 mangler(#1585) lookup key로 쓰이므로 함께 설정.
                        sem_symbols.items[existing_idx].synthetic_kind = .default_export;
                        sem_symbols.items[existing_idx].synthetic_name = "_default";
                        const sym_id: semantic_symbol.SymbolId = @enumFromInt(@as(u32, @intCast(existing_idx)));
                        eb.symbol = .{ .semantic = .{ .module = module_index, .symbol = sym_id } };
                        continue;
                    }
                }
            }
            const sem_id = try semantic_symbol.extendSymbol(
                arena,
                sem_symbols,
                .variable_var,
                .default_export,
                "_default",
                eb.local_span,
            );
            eb.symbol = .{ .semantic = .{ .module = module_index, .symbol = sem_id } };
        } else if (eb.kind == .re_export) {
            // re_export_alias는 bundler 전용 — linker가 post-link 단계에서
            // resolveExportChain 결과를 canonical_name으로 저장한다.
            const id = try table.declare(eb.exported_name);
            eb.symbol = .{ .alias = .{ .module = module_index, .symbol = id } };
        } else if (eb.kind == .local) {
            // 일반 .local export: scope_maps[0]에서 로컬 심볼 lookup → semantic ref.
            // synthetic_default 케이스는 위에서 이미 처리됨.
            const scope = module_scope orelse continue;
            const sym_idx = scope.get(eb.local_name) orelse continue;
            eb.symbol = symbol_mod.SymbolRef.makeSemantic(module_index, sym_idx);
        }
    }
}
