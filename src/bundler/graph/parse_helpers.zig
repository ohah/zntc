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

/// import record identity(kind + span + specifier) 해시맵 컨텍스트 — `mergeImportRecords` 의
/// 대형 fan-out O(N²) 선형 스캔을 O(1) 조회로 바꾸기 위함. zero-sized(필드 없음)라 Unmanaged
/// 해시맵의 non-Context 메서드를 그대로 쓴다.
const ImportRecordIdentityCtx = struct {
    pub fn hash(_: ImportRecordIdentityCtx, rec: ImportRecord) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&rec.kind));
        h.update(std.mem.asBytes(&rec.span.start));
        h.update(std.mem.asBytes(&rec.span.end));
        h.update(rec.specifier);
        return h.final();
    }
    pub fn eql(_: ImportRecordIdentityCtx, a: ImportRecord, b: ImportRecord) bool {
        return sameImportRecordIdentity(a, b);
    }
};

pub fn mergeImportRecords(
    arena_alloc: std.mem.Allocator,
    previous: []const ImportRecord,
    transformed: []const ImportRecord,
) ![]ImportRecord {
    var records: std.ArrayList(ImportRecord) = .empty;
    errdefer records.deinit(arena_alloc);

    // 대형 fan-out(mega-entry — HMR/resync 경로): previous/records 를 record 마다 identity 로
    // 선형 스캔하면 O(transformed×previous)+O(transformed×records)=O(N²). 임계값 초과 시
    // identity 해시맵으로 O(1) 조회. arena_alloc 은 module parse_arena(long-lived)라 개별
    // deinit 안 함(arena 일괄 해제 — #1287); 임계값으로 대형 모듈만 인덱싱해 arena 누적 제한.
    const Ctx = ImportRecordIdentityCtx;
    const use_index = previous.len + transformed.len > 64;
    var prev_index: std.HashMapUnmanaged(ImportRecord, ImportRecord, Ctx, 80) = .empty;
    var added: std.HashMapUnmanaged(ImportRecord, void, Ctx, 80) = .empty;
    // 이 함수는 arena 를 소유하지 않으므로(caller 가 deinit) 여기 deinit 은 함수 반환 시
    // 실행 = caller arena.deinit 보다 먼저라 #1287 순서 문제 없음. 실제 arena 면 free 는
    // 안전한 no-op(일괄 해제), non-arena caller(테스트 등)는 누수 방지. 미사용 시 .empty no-op.
    defer prev_index.deinit(arena_alloc);
    defer added.deinit(arena_alloc);
    if (use_index) {
        try prev_index.ensureTotalCapacity(arena_alloc, @intCast(previous.len));
        // `added` 는 loop1(transformed) + loop2(synthetic previous 만)에서 추가되므로
        // transformed.len + synthetic 수가 정확한 상한. previous 순회 김에 synthetic 카운트
        // (별도 스캔 없음) → previous.len 전체 예약 대비 과다예약 제거.
        var synthetic_prev: usize = 0;
        for (previous) |rec| {
            const gop = prev_index.getOrPutAssumeCapacity(rec);
            if (!gop.found_existing) gop.value_ptr.* = rec; // 첫 매칭 우선(findImportRecord 와 동일)
            if (isSyntheticImportRecord(rec)) synthetic_prev += 1;
        }
        try added.ensureTotalCapacity(arena_alloc, @intCast(transformed.len + synthetic_prev));
    }

    for (transformed) |rec| {
        if (use_index) {
            if (added.getOrPutAssumeCapacity(rec).found_existing) continue;
        } else if (hasImportRecord(records.items, rec)) continue;
        const merged = if (use_index)
            (prev_index.get(rec) orelse rec)
        else
            (findImportRecord(previous, rec) orelse rec);
        try records.append(arena_alloc, merged);
    }
    for (previous) |rec| {
        // transformer 가 type-only import 를 제거한 뒤에도 이전 parser record 를 되살리면
        // strictExecutionOrder 가 타입 전용 모듈까지 평가한다. AST 에 없는 record 는 버리고,
        // AST 노드가 없는 synthetic record(Flow enum runtime 등)만 보존한다.
        if (!isSyntheticImportRecord(rec)) continue;
        if (use_index) {
            if (added.getOrPutAssumeCapacity(rec).found_existing) continue;
        } else if (hasImportRecord(records.items, rec)) continue;
        try records.append(arena_alloc, rec);
    }
    return records.toOwnedSlice(arena_alloc);
}

fn findImportRecord(records: []const ImportRecord, needle: ImportRecord) ?ImportRecord {
    for (records) |rec| {
        if (sameImportRecordIdentity(rec, needle)) return rec;
    }
    return null;
}

fn hasImportRecord(records: []const ImportRecord, needle: ImportRecord) bool {
    return findImportRecord(records, needle) != null;
}

fn sameImportRecordIdentity(rec: ImportRecord, needle: ImportRecord) bool {
    return rec.kind == needle.kind and
        rec.span.start == needle.span.start and
        rec.span.end == needle.span.end and
        std.mem.eql(u8, rec.specifier, needle.specifier);
}

fn isSyntheticImportRecord(rec: ImportRecord) bool {
    return rec.span.start == 0 and rec.span.end == 0;
}

test "mergeImportRecords drops parser record removed by transform" {
    const Span = @import("../../lexer/token.zig").Span;
    const prev = [_]ImportRecord{.{
        .specifier = "./types",
        .kind = .static_import,
        .span = Span{ .start = 10, .end = 19 },
    }};
    const merged = try mergeImportRecords(std.testing.allocator, &prev, &.{});
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 0), merged.len);
}

test "mergeImportRecords preserves synthetic record without AST span" {
    const Span = @import("../../lexer/token.zig").Span;
    const prev = [_]ImportRecord{.{
        .specifier = "\x00zntc:flow-enums-runtime",
        .kind = .require,
        .span = Span.EMPTY,
    }};
    const merged = try mergeImportRecords(std.testing.allocator, &prev, &.{});
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqualStrings("\x00zntc:flow-enums-runtime", merged[0].specifier);
}

test "mergeImportRecords keeps previous resolved state for unchanged record" {
    const Span = @import("../../lexer/token.zig").Span;
    const span = Span{ .start = 10, .end = 17 };
    const prev = [_]ImportRecord{.{
        .specifier = "./dep",
        .kind = .static_import,
        .span = span,
        .resolved = @enumFromInt(7),
    }};
    const transformed = [_]ImportRecord{.{
        .specifier = "./dep",
        .kind = .static_import,
        .span = span,
    }};
    const merged = try mergeImportRecords(std.testing.allocator, &prev, &transformed);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqual(@as(u32, 7), @intFromEnum(merged[0].resolved));
}

test "mergeImportRecords: index 경로(>64 records) — dedup + previous 보존 + synthetic 보존" {
    const Span = @import("../../lexer/token.zig").Span;
    const N = 70; // > 64 임계값 → identity 해시맵(index) 경로 강제
    var prev_buf: [N + 1]ImportRecord = undefined;
    var trans_buf: [N + 1]ImportRecord = undefined;
    for (0..N) |i| {
        const s = Span{ .start = @intCast(i + 1), .end = @intCast(i + 1) }; // start!=0 → non-synthetic, 유니크 identity
        prev_buf[i] = .{ .specifier = "./dep", .kind = .static_import, .span = s, .resolved = @enumFromInt(@as(u32, @intCast(i + 100))) };
        trans_buf[i] = .{ .specifier = "./dep", .kind = .static_import, .span = s };
    }
    prev_buf[N] = .{ .specifier = "\x00synth", .kind = .require, .span = Span.EMPTY }; // synthetic, transformed 에 없음 → 보존
    trans_buf[N] = trans_buf[0]; // 첫 record 와 동일 identity → dedup 대상

    const merged = try mergeImportRecords(std.testing.allocator, prev_buf[0 .. N + 1], trans_buf[0 .. N + 1]);
    defer std.testing.allocator.free(merged);

    // transformed N개(중복 1개 제거) + synthetic 1개
    try std.testing.expectEqual(@as(usize, N + 1), merged.len);
    // 매칭된 transformed 는 previous 의 resolved 를 보존 (index 경로 = linear 경로 등가)
    for (0..N) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i + 100)), @intFromEnum(merged[i].resolved));
    }
    try std.testing.expectEqualStrings("\x00synth", merged[N].specifier);
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
