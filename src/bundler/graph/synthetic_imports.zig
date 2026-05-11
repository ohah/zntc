//! Synthetic import helpers for ModuleGraph.
//!
//! NOTE: JSX runtime synthetic 우회 경로 (`injectJsxRuntimeImports` /
//! `createJsxImportBindings`) 는 transformer 가 정식 AST 노드로 import_declaration 을
//! 추가하는 새 경로 (`src/transformer/jsx_runtime_imports.zig`) 로 대체됐다 (#3062).
//! Flow enum runtime 등 다른 synthetic 케이스도 같은 패턴으로 마이그레이션 예정.

const std = @import("std");
const types = @import("../types.zig");
const ImportRecord = types.ImportRecord;
const Span = @import("../../lexer/token.zig").Span;
const runtime_helpers = @import("../runtime_helpers.zig");

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
