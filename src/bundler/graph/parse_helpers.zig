//! Parser and post-transform metadata helpers for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const Module = @import("../module.zig").Module;
const ModuleType = types.ModuleType;
const Parser = @import("../../parser/parser.zig").Parser;
const ImportRecord = types.ImportRecord;
const import_scanner = @import("../import_scanner.zig");
const binding_scanner = @import("../binding_scanner.zig");
const runtime_helper_modules = @import("../../runtime_helper_modules.zig");

pub fn suppressRuntimeHelperInternalUnresolved(module: *Module) void {
    if (!runtime_helper_modules.isVirtualId(module.path)) return;
    var semantic = &(module.semantic orelse return);
    runtime_helper_modules.removeRegisteredHelperBaseNames(&semantic.unresolved_references);
}

pub fn configureParserForModule(parser: *Parser, module: *const Module, ext: []const u8) void {
    parser.configureForBundler(ext);
    if (module.module_type.isJavaScriptLike()) {
        const flags = module.module_type.toParserFlags();
        parser.configureForBundlerKind(flags.is_ts, flags.is_jsx);
    }
}

pub fn moduleTypeForLoader(default_type: ModuleType, loader: types.Loader) ModuleType {
    return switch (loader) {
        .javascript => if (default_type.isJavaScriptLike()) default_type else .js,
        .json => .json,
        .css => .css,
        .none => default_type,
        else => if (loader.isAsset()) .asset else default_type,
    };
}

pub fn isFlowPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".js.flow") or std.mem.endsWith(u8, path, ".jsx.flow");
}

pub fn mergeImportRecords(
    arena_alloc: std.mem.Allocator,
    previous: []const ImportRecord,
    transformed: []const ImportRecord,
) ![]ImportRecord {
    var records: std.ArrayList(ImportRecord) = .empty;
    errdefer records.deinit(arena_alloc);
    try records.appendSlice(arena_alloc, previous);
    for (transformed) |rec| {
        if (hasImportRecord(records.items, rec)) continue;
        try records.append(arena_alloc, rec);
    }
    return records.toOwnedSlice(arena_alloc);
}

fn hasImportRecord(records: []const ImportRecord, needle: ImportRecord) bool {
    for (records) |rec| {
        if (rec.kind == needle.kind and
            rec.span.start == needle.span.start and
            rec.span.end == needle.span.end and
            std.mem.eql(u8, rec.specifier, needle.specifier))
        {
            return true;
        }
    }
    return false;
}

/// post-transform AST 의 binding 을 source of truth 로 삼고, `previous` 에서 transformer
/// 가 직접 추가한 synthetic binding (JSX runtime 등 - span sentinel 로 식별) 만 보존한다.
/// 단순 append 로 합치면 Phase D 가 elide 한 import specifier 에 대응하는 stale binding
/// 이 살아남아 linker preamble 이 `var err = require_xxx().err` 같은 죽은 코드를 emit
/// 하거나 `non-synthetic import binding 'err' has no semantic local symbol` panic 을 낸다.
pub fn mergeImportBindings(
    arena_alloc: std.mem.Allocator,
    previous: []const binding_scanner.ImportBinding,
    transformed: []const binding_scanner.ImportBinding,
) ![]binding_scanner.ImportBinding {
    var bindings: std.ArrayList(binding_scanner.ImportBinding) = .empty;
    errdefer bindings.deinit(arena_alloc);
    try bindings.appendSlice(arena_alloc, transformed);
    for (previous) |binding| {
        if (!binding.isSynthetic()) continue;
        if (hasImportBinding(bindings.items, binding)) continue;
        try bindings.append(arena_alloc, binding);
    }
    return bindings.toOwnedSlice(arena_alloc);
}

fn hasImportBinding(bindings: []const binding_scanner.ImportBinding, needle: binding_scanner.ImportBinding) bool {
    for (bindings) |binding| {
        if (binding.kind == needle.kind and
            binding.import_record_index == needle.import_record_index and
            binding.local_span.start == needle.local_span.start and
            binding.local_span.end == needle.local_span.end and
            std.mem.eql(u8, binding.local_name, needle.local_name) and
            std.mem.eql(u8, binding.imported_name, needle.imported_name))
        {
            return true;
        }
    }
    return false;
}

/// `ExportBinding[]` -> `[]const []const u8` 평탄 이름 슬라이스 (#1883).
/// `ModuleInfo` 가 binding_scanner internal struct 를 노출 안 하도록 사전 투영.
/// 실패 시 빈 슬라이스 - caller 가 fallback 가능하게.
pub fn projectExportedNames(allocator: std.mem.Allocator, bindings: []const binding_scanner.ExportBinding) []const []const u8 {
    if (bindings.len == 0) return &.{};
    const out = allocator.alloc([]const u8, bindings.len) catch return &.{};
    for (bindings, 0..) |b, i| out[i] = b.exported_name;
    return out;
}

/// 스캔 결과와 파일 확장자로 모듈의 export 방식을 결정한다.
/// 우선순위: 1) ESM+CJS 혼용 → esm_with_dynamic_fallback
///          2) ESM만 → esm
///          3) CJS 신호 → commonjs
///          4) 확장자 (.cjs/.mjs 등) → commonjs/esm
///          5) 판별 불가 → none
pub fn determineExportsKind(
    scan: import_scanner.ScanResult,
    path: []const u8,
) types.ExportsKind {
    const has_cjs = scan.has_cjs_require or scan.has_module_exports or scan.has_exports_dot;

    // ESM + CJS 혼용
    if (scan.has_esm_syntax and has_cjs) return .esm_with_dynamic_fallback;

    // ESM만
    if (scan.has_esm_syntax) return .esm;

    // CJS 신호
    if (has_cjs) return .commonjs;

    // 확장자로 판별
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".cjs") or std.mem.eql(u8, ext, ".cts")) return .commonjs;
    if (std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".mts")) return .esm;

    return .none;
}
