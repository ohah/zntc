//! Synthetic import helpers for ModuleGraph.

const std = @import("std");
const types = @import("../types.zig");
const ImportRecord = types.ImportRecord;
const Span = @import("../../lexer/token.zig").Span;
const runtime_helpers = @import("../runtime_helpers.zig");
const JsxRuntime = @import("../../codegen/codegen.zig").JsxRuntime;
const binding_scanner = @import("../binding_scanner.zig");
const ImportBinding = binding_scanner.ImportBinding;

/// JSX automatic import를 synthetic하게 추가한다.
/// 기존 import_records 배열 끝에 각 specifier 를 static_import record 로 append.
/// 한 번의 alloc + memcpy 로 처리해 중간 버퍼 낭비를 피한다.
pub fn injectJsxRuntimeImports(
    specifiers: []const []const u8,
    arena_alloc: std.mem.Allocator,
    existing_records: []ImportRecord,
) ![]ImportRecord {
    const new_records = try arena_alloc.alloc(ImportRecord, existing_records.len + specifiers.len);
    @memcpy(new_records[0..existing_records.len], existing_records);
    for (specifiers, 0..) |specifier, i| {
        new_records[existing_records.len + i] = .{
            .specifier = specifier,
            .kind = .static_import,
            .span = Span.EMPTY,
        };
    }
    return new_records;
}

pub fn injectFlowEnumRuntimeImport(
    arena_alloc: std.mem.Allocator,
    existing_records: []ImportRecord,
) ![]ImportRecord {
    const specifier = runtime_helpers.FLOW_ENUMS_RUNTIME_SPECIFIER;
    for (existing_records) |record| {
        if (std.mem.eql(u8, record.specifier, specifier)) return existing_records;
    }

    const new_records = try arena_alloc.alloc(ImportRecord, existing_records.len + 1);
    @memcpy(new_records[0..existing_records.len], existing_records);
    new_records[existing_records.len] = .{
        .specifier = specifier,
        .kind = .require,
        .span = Span.EMPTY,
    };
    return new_records;
}

/// JSX automatic import 의 synthetic bindings. `react_record_index` 가 있으면
/// key-after-spread fallback 용 `_createElement` 도 포함.
pub fn createJsxImportBindings(
    jsx_runtime: JsxRuntime,
    arena_alloc: std.mem.Allocator,
    existing_bindings: []ImportBinding,
    jsx_record_index: u32,
    react_record_index: ?u32,
) ![]ImportBinding {
    const is_dev = jsx_runtime == .automatic_dev;

    const Entry = struct { local: []const u8, imported: []const u8, record: u32 };
    var buf: [4]Entry = undefined;
    var len: usize = 0;
    if (is_dev) {
        buf[len] = .{ .local = "_jsxDEV", .imported = "jsxDEV", .record = jsx_record_index };
        len += 1;
        buf[len] = .{ .local = "_Fragment", .imported = "Fragment", .record = jsx_record_index };
        len += 1;
    } else {
        buf[len] = .{ .local = "_jsx", .imported = "jsx", .record = jsx_record_index };
        len += 1;
        buf[len] = .{ .local = "_jsxs", .imported = "jsxs", .record = jsx_record_index };
        len += 1;
        buf[len] = .{ .local = "_Fragment", .imported = "Fragment", .record = jsx_record_index };
        len += 1;
    }
    if (react_record_index) |rr| {
        buf[len] = .{ .local = "_createElement", .imported = "createElement", .record = rr };
        len += 1;
    }

    const entries = buf[0..len];
    const new_bindings = try arena_alloc.alloc(ImportBinding, existing_bindings.len + entries.len);
    @memcpy(new_bindings[0..existing_bindings.len], existing_bindings);
    for (entries, 0..) |e, i| {
        // 각 synthetic binding에 고유 sentinel span 부여.
        // Span.EMPTY(0,0)를 공유하면 linker의 spanKey 기반 HashMap에서 덮어쓰기 발생.
        const sentinel_start: u32 = ImportBinding.SYNTHETIC_SPAN_BASE + @as(u32, @intCast(i));
        new_bindings[existing_bindings.len + i] = .{
            .kind = .named,
            .local_name = e.local,
            .imported_name = e.imported,
            .local_span = .{ .start = sentinel_start, .end = sentinel_start },
            .import_record_index = e.record,
        };
    }
    return new_bindings;
}
