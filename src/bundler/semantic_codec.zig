//! semantic 직렬화 codec — 디스크 캐시(#4438) PR2.
//!
//! `ModuleSemanticData` 의 **relocatable 부분만** 직렬화한다 (사용자 결정: 점진 PR).
//! - `scopes` / `symbol_ids` / `references`: 전부 인덱스·스칼라라 통째 memcpy.
//! - `symbols`(ArrayList): Symbol 도 대부분 인덱스/Span 이라 memcpy, 단 `synthetic_name`
//!   (`[]const u8`, 합성 심볼만 non-empty)만 별도 — memcpy 후 ""로 리셋하고 사이드테이블에서
//!   복원(arena dupe).
//! - HashMap 5개(scope_maps/exported_names/unresolved_references/numeric_const_texts/
//!   helper_scope_map)는 **PR3**에서 복원한다. 키 문자열은 source/string_table(parse_arena)
//!   슬라이스라 deserialize 가 주입 arena 에 dupe; 값은 심볼인덱스(usize→u32)/Span/void/텍스트.
//!
//! 소유권: `ModuleSemanticData` 는 deinit 이 없고 원본은 `parse_arena` 가 일괄 소유한다.
//! deserialize 본은 parse_arena 가 없으므로 **caller 가 arena 를 주입** — 모든 배열·문자열을
//! 그 arena 에 alloc 하고 `arena.deinit()` 가 일괄 해제(원본 모델과 동일).
//!
//! 안전: PR1 ast_codec 과 동일하게 `[MAGIC][VERSION][checksum]` 헤더 + 비배수/오버플로우
//! 검증 → 실패는 항상 error(fail-safe). host endian/정렬 native(로컬 캐시 전제).

const std = @import("std");
const module = @import("module.zig");
const ModuleSemanticData = module.ModuleSemanticData;
const symbol_mod = @import("../semantic/symbol.zig");
const Symbol = symbol_mod.Symbol;
const Reference = symbol_mod.Reference;
const scope_mod = @import("../semantic/scope.zig");
const Scope = scope_mod.Scope;
const Span = @import("../lexer/token.zig").Span;
const wyhash = @import("../util/wyhash.zig");
const codec_io = @import("../util/codec_io.zig");

pub const MAGIC: u32 = 0x5A53454D; // "ZSEM"
pub const FORMAT_VERSION: u32 = 1;
const HEADER_LEN: usize = 16;

/// `?u32`(symbol_ids) 의 null 표식. 값은 symbols 배열 인덱스라 maxInt 에 도달하지 않으므로
/// 안전한 sentinel(SymbolId.none/ScopeId.none 과 동일 패턴).
const NULL_U32: u32 = std.math.maxInt(u32);

comptime {
    // Symbol/Scope/Reference 는 일반 struct 라 통째 memcpy 가 padding/미초기화 바이트를 직렬화
    // stream 에 섞어 비결정적이었다(#4438). 이제 `putSymbol`/`putScope`/`putReference` 가 필드별
    // 명시 직렬화한다. 새 필드 추가 시 직렬화에서 silently 누락 → cache-hit drift 이므로 필드
    // 수를 못박아 codec 갱신을 컴파일 에러로 강제한다. 새 필드가 슬라이스/포인터면 side-table
    // 복원(synthetic_name 패턴)이 추가로 필요하다.
    if (@typeInfo(Symbol).@"struct".fields.len != 11)
        @compileError("Symbol 필드 수가 바뀜 — putSymbol/readSymbol 의 명시 직렬화 갱신 후 이 가드를 갱신.");
    if (@typeInfo(Scope).@"struct".fields.len != 6)
        @compileError("Scope 필드 수가 바뀜 — putScope/readScope 의 명시 직렬화 갱신 후 이 가드를 갱신.");
    if (@typeInfo(Reference).@"struct".fields.len != 6)
        @compileError("Reference 필드 수가 바뀜 — putReference/readReference 의 명시 직렬화 갱신 후 이 가드를 갱신.");
    // serialize/deserialize 는 ModuleSemanticData 의 9개 필드를 손으로 열거한다. 필드가 추가되면
    // 직렬화에서 silently 누락 → PR4 cache-hit 연결 시 그 필드만 default 로 stale miscompile.
    // 필드 수를 못박아 새 필드 추가를 컴파일 에러로 만들어 codec 갱신을 강제한다.
    if (@typeInfo(ModuleSemanticData).@"struct".fields.len != 9) {
        @compileError("ModuleSemanticData 필드 수가 바뀜 — semantic_codec 의 serialize/deserialize 에 새 필드 직렬화 추가 후 이 가드를 갱신.");
    }
}

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    ChecksumMismatch,
    Truncated,
} || std.mem.Allocator.Error;

// ── serialize ───────────────────────────────────────────────────────────────

// IO 원시함수/Reader 는 공유 `util/codec_io.zig` 사용(ast_codec/module_codec 와 동일 1벌).
const putU32 = codec_io.putU32;
const putU64 = codec_io.putU64;
const putBytes = codec_io.putBytes;

// 작은 스칼라 — codec_io 엔 u32/u64 만 있으므로 여기서 직접 append.
fn putU16(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    try buf.appendSlice(alloc, std.mem.asBytes(&v));
}
fn putU8(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u8) !void {
    try buf.append(alloc, v);
}

// Symbol/Scope/Reference 필드별 직렬화(#4438). 일반 struct 의 padding/미초기화 꼬리를
// stream 에서 제외해 결정성을 보장한다. enum 은 `@intFromEnum`, packed struct 는 정수
// 표현으로 쓴다. synthetic_name(슬라이스)은 length-prefixed 텍스트로 인라인 직렬화 —
// 필드별 직렬화는 memcpy 가 아니므로 dangling 위험이 없고, deserialize 가 arena dupe 로 복원.
fn putSymbol(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: Symbol) !void {
    try putU32(buf, alloc, s.name.start);
    try putU32(buf, alloc, s.name.end);
    try putU32(buf, alloc, @intFromEnum(s.scope_id));
    try putU32(buf, alloc, @intFromEnum(s.origin_scope));
    try putU8(buf, alloc, @intFromEnum(s.kind));
    try putU16(buf, alloc, s.decl_flags.toInt());
    try putU32(buf, alloc, s.declaration_span.start);
    try putU32(buf, alloc, s.declaration_span.end);
    try putU32(buf, alloc, s.reference_count);
    try putU32(buf, alloc, s.write_count);
    try putU8(buf, alloc, @intFromEnum(s.const_kind));
    // ?SyntheticKind → 0xFF=null, 아니면 enum 값(SyntheticKind 변형 수가 4개라 충돌 없음).
    try putU8(buf, alloc, if (s.synthetic_kind) |k| @intFromEnum(k) else 0xFF);
    try putBytes(buf, alloc, s.synthetic_name);
}
fn putScope(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: Scope) !void {
    try putU32(buf, alloc, @intFromEnum(s.parent));
    try putU8(buf, alloc, @intFromEnum(s.kind));
    try putU8(buf, alloc, @intFromBool(s.is_strict));
    try putU8(buf, alloc, @intFromBool(s.subtree_has_direct_eval));
    try putU8(buf, alloc, @intFromBool(s.subtree_has_with));
    try putU16(buf, alloc, s.symbol_count);
}
fn putReference(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, ref: Reference) !void {
    try putU32(buf, alloc, @intFromEnum(ref.node_index));
    try putU32(buf, alloc, @intFromEnum(ref.scope_id));
    try putU32(buf, alloc, @intFromEnum(ref.symbol_id));
    try putU32(buf, alloc, ref.stmt_idx);
    try putU32(buf, alloc, ref.scope_stmt_idx);
    try putU8(buf, alloc, @as(u8, @bitCast(ref.flags)));
}

// HashMap 직렬화 (PR3). 모두 `[count][entry…]`. 키 문자열은 putBytes 로 그대로 (deserialize
// 가 arena dupe). 값 usize 는 심볼 인덱스(symbol_ids 와 동일하게 u32 범위)라 u32 로 고정 —
// disk 크기 절감 + host arch 무관.
//
// ⚠️ HashMap iteration 순서는 비결정적이라 정렬 없이 직렬화하면 같은 입력도 byte stream 이
// 달라진다(#4438). 모든 helper 가 키를 정렬(string=lexicographic, u32=오름차순)한 뒤 쓴다.
// 키는 module 내 유일(맵의 키)하므로 정렬이 안정적 total order 를 준다. deserialize 는 순서
// 무관(맵 재구성)이라 짝 변경 불필요.
fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// StringHashMap 의 키를 lexicographic 정렬해 반환(caller free). 빈 맵이면 빈 슬라이스.
/// 키는 맵 내 유일하므로 안정적 total order. 값 조회는 호출자가 `m.get(k)` 로.
fn sortedStrKeys(alloc: std.mem.Allocator, m: anytype) ![]const []const u8 {
    const keys = try alloc.alloc([]const u8, m.count());
    var it = m.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) keys[i] = k.*;
    std.mem.sortUnstable([]const u8, keys, {}, lessThanStr);
    return keys;
}

fn putStrMapUsize(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(usize)) !void {
    try putU32(buf, alloc, m.count());
    const keys = try sortedStrKeys(alloc, m);
    defer alloc.free(keys);
    for (keys) |k| {
        try putBytes(buf, alloc, k);
        try putU32(buf, alloc, @intCast(m.get(k).?));
    }
}
fn putStrMapSpan(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(Span)) !void {
    try putU32(buf, alloc, m.count());
    const keys = try sortedStrKeys(alloc, m);
    defer alloc.free(keys);
    for (keys) |k| {
        const v = m.get(k).?;
        try putBytes(buf, alloc, k);
        try putU32(buf, alloc, v.start);
        try putU32(buf, alloc, v.end);
    }
}
fn putStrSet(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(void)) !void {
    try putU32(buf, alloc, m.count());
    const keys = try sortedStrKeys(alloc, m);
    defer alloc.free(keys);
    for (keys) |k| try putBytes(buf, alloc, k);
}
fn putNumTexts(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.AutoHashMapUnmanaged(u32, []const u8)) !void {
    try putU32(buf, alloc, m.count());
    if (m.count() > 0) {
        const keys = try alloc.alloc(u32, m.count());
        defer alloc.free(keys);
        var it = m.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) keys[i] = k.*;
        std.mem.sortUnstable(u32, keys, {}, std.sort.asc(u32));
        for (keys) |k| {
            try putU32(buf, alloc, k);
            try putBytes(buf, alloc, m.get(k).?);
        }
    }
}

/// semantic 의 relocatable 부분을 `out` 에 직렬화 (append).
pub fn serialize(sem: *const ModuleSemanticData, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    // Symbol/Scope/Reference 는 일반(non-extern) struct 라 `sliceAsBytes` 통째 memcpy 는
    // struct 꼬리 padding 과 미초기화 바이트를 stream 에 섞어 같은 입력도 byte 가 달라진다
    // (#4438). 필드별로 명시 직렬화해 결정성을 코드 레벨로 보장한다. synthetic_name(슬라이스)은
    // Symbol 직렬화에 포함하지 않고 — memcpy 가 아니므로 dangling 위험 없음 — 텍스트를 직접 쓴다.
    try putU32(&payload, alloc, @intCast(sem.symbols.items.len));
    for (sem.symbols.items) |s| try putSymbol(&payload, alloc, s);

    try putU32(&payload, alloc, @intCast(sem.scopes.len));
    for (sem.scopes) |s| try putScope(&payload, alloc, s);

    try putU32(&payload, alloc, @intCast(sem.symbol_ids.len));
    for (sem.symbol_ids) |id| try putU32(&payload, alloc, if (id) |v| v else NULL_U32);

    try putU32(&payload, alloc, @intCast(sem.references.len));
    for (sem.references) |ref| try putReference(&payload, alloc, ref);

    // HashMap 5개 (PR3). scope_maps 는 scopes 와 동일 인덱스를 공유하는 맵 배열.
    try putU32(&payload, alloc, @intCast(sem.scope_maps.len));
    for (sem.scope_maps) |*m| try putStrMapUsize(&payload, alloc, m);
    try putStrMapSpan(&payload, alloc, &sem.exported_names);
    try putStrSet(&payload, alloc, &sem.unresolved_references);
    try putNumTexts(&payload, alloc, &sem.numeric_const_texts);
    try putStrMapUsize(&payload, alloc, &sem.helper_scope_map);

    const checksum = wyhash.hashU64(payload.items);
    try putU32(out, alloc, MAGIC);
    try putU32(out, alloc, FORMAT_VERSION);
    try putU64(out, alloc, checksum);
    try out.appendSlice(alloc, payload.items);
}

// ── deserialize ──────────────────────────────────────────────────────────────

const Reader = codec_io.Reader;

// HashMap 역직렬화 (PR3). checksum 통과 후 호출되므로 count 는 신뢰 가능 → ensureTotalCapacity
// 후 putAssumeCapacity. 키는 payload 슬라이스를 arena 에 dupe(arena.deinit 이 일괄 해제).
fn readStrMapUsize(r: *Reader, arena: std.mem.Allocator) Error!std.StringHashMapUnmanaged(usize) {
    var m: std.StringHashMapUnmanaged(usize) = .empty;
    const n = try r.u32v();
    try m.ensureTotalCapacity(arena, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try arena.dupe(u8, try r.bytes());
        m.putAssumeCapacity(key, @intCast(try r.u32v()));
    }
    return m;
}
fn readStrMapSpan(r: *Reader, arena: std.mem.Allocator) Error!std.StringHashMapUnmanaged(Span) {
    var m: std.StringHashMapUnmanaged(Span) = .empty;
    const n = try r.u32v();
    try m.ensureTotalCapacity(arena, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try arena.dupe(u8, try r.bytes());
        const start = try r.u32v();
        const end = try r.u32v();
        m.putAssumeCapacity(key, .{ .start = start, .end = end });
    }
    return m;
}
fn readStrSet(r: *Reader, arena: std.mem.Allocator) Error!std.StringHashMapUnmanaged(void) {
    var m: std.StringHashMapUnmanaged(void) = .empty;
    const n = try r.u32v();
    try m.ensureTotalCapacity(arena, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try arena.dupe(u8, try r.bytes());
        m.putAssumeCapacity(key, {});
    }
    return m;
}
fn readNumTexts(r: *Reader, arena: std.mem.Allocator) Error!std.AutoHashMapUnmanaged(u32, []const u8) {
    var m: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    const n = try r.u32v();
    try m.ensureTotalCapacity(arena, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const key = try r.u32v();
        const text = try arena.dupe(u8, try r.bytes());
        m.putAssumeCapacity(key, text);
    }
    return m;
}

// 작은 스칼라 read — codec_io.Reader 엔 u16/u8 helper 가 없어 take 로 직접.
fn readU16(r: *Reader) Error!u16 {
    return std.mem.bytesToValue(u16, (try r.take(2))[0..2]);
}

// Symbol/Scope/Reference 필드별 역직렬화(#4438 put* 의 짝). 0-init 후 의미 필드만 채운다 —
// padding 은 0 으로 남아 결정적. enum 은 `enums.fromInt`(손상 캐시의 잘못된 tag 도 fail-safe error).
fn readSymbol(r: *Reader, arena: std.mem.Allocator) Error!Symbol {
    var s = std.mem.zeroes(Symbol);
    s.name = .{ .start = try r.u32v(), .end = try r.u32v() };
    s.scope_id = @enumFromInt(try r.u32v());
    s.origin_scope = @enumFromInt(try r.u32v());
    s.kind = std.enums.fromInt(symbol_mod.SymbolKind, try r.byte()) orelse return error.Truncated;
    s.decl_flags = symbol_mod.DeclFlags.fromInt(try readU16(r));
    s.declaration_span = .{ .start = try r.u32v(), .end = try r.u32v() };
    s.reference_count = try r.u32v();
    s.write_count = try r.u32v();
    s.const_kind = std.enums.fromInt(symbol_mod.ConstValue.Kind, try r.byte()) orelse return error.Truncated;
    const syn = try r.byte();
    s.synthetic_kind = if (syn == 0xFF) null else (std.enums.fromInt(symbol_mod.SyntheticKind, syn) orelse return error.Truncated);
    const name_text = try r.bytes();
    s.synthetic_name = if (name_text.len == 0) "" else try arena.dupe(u8, name_text);
    return s;
}
fn readScope(r: *Reader) Error!Scope {
    var s = std.mem.zeroes(Scope);
    s.parent = @enumFromInt(try r.u32v());
    s.kind = std.enums.fromInt(scope_mod.ScopeKind, try r.byte()) orelse return error.Truncated;
    s.is_strict = (try r.byte()) != 0;
    s.subtree_has_direct_eval = (try r.byte()) != 0;
    s.subtree_has_with = (try r.byte()) != 0;
    s.symbol_count = try readU16(r);
    return s;
}
fn readReference(r: *Reader) Error!Reference {
    var ref = std.mem.zeroes(Reference);
    ref.node_index = @enumFromInt(try r.u32v());
    ref.scope_id = @enumFromInt(try r.u32v());
    ref.symbol_id = @enumFromInt(try r.u32v());
    ref.stmt_idx = try r.u32v();
    ref.scope_stmt_idx = try r.u32v();
    ref.flags = @bitCast(try r.byte());
    return ref;
}

/// `arena` 에 모든 배열·문자열·HashMap 을 alloc 하여 ModuleSemanticData 전체를 복원(PR3 로
/// HashMap 5개 포함). caller 가 `arena.deinit()` 로 일괄 해제(원본 parse_arena 모델과 동일).
/// 검증 실패는 항상 error(fail-safe 재파싱).
///
/// ⚠️ codec 자체는 완전하나 graph 통합(buildIncremental 의 디스크 cache-hit 분기)은 **PR4**
/// 에서 한다 — 무효화 키(버전·옵션·tsconfig·.env) 정합성이 PR5 전까지 미비하므로 그 전에
/// 파이프라인에 연결하면 stale 캐시로 잘못된 결과가 나온다. 현재는 codec 단위 테스트 전용.
pub fn deserialize(data: []const u8, arena: std.mem.Allocator) Error!ModuleSemanticData {
    if (data.len < HEADER_LEN) return error.Truncated;
    if (std.mem.bytesToValue(u32, data[0..4]) != MAGIC) return error.BadMagic;
    if (std.mem.bytesToValue(u32, data[4..8]) != FORMAT_VERSION) return error.UnsupportedVersion;
    const checksum = std.mem.bytesToValue(u64, data[8..16]);
    const payload = data[HEADER_LEN..];
    if (wyhash.hashU64(payload) != checksum) return error.ChecksumMismatch;

    var r = Reader{ .buf = payload };

    // 필드별 역직렬화(#4438 put* 의 짝). 각 배열은 `[count]` 후 레코드별 명시 read.
    // count 는 checksum 통과 후라 신뢰 가능하지만, 손상 캐시가 거대 count 를 줘도 take 의
    // 경계검사가 read 도중 Truncated 를 낸다(over-alloc 만 가능, OOB read 불가) → fail-safe.
    const symbols_len = try r.u32v();
    const symbols_slice = try arena.alloc(Symbol, symbols_len);
    for (symbols_slice) |*s| s.* = try readSymbol(&r, arena);

    const scopes_len = try r.u32v();
    const scopes = try arena.alloc(Scope, scopes_len);
    for (scopes) |*s| s.* = try readScope(&r);

    const symbol_ids_len = try r.u32v();
    const symbol_ids = try arena.alloc(?u32, symbol_ids_len);
    for (symbol_ids) |*id| {
        const v = try r.u32v();
        id.* = if (v == NULL_U32) null else v;
    }

    const references_len = try r.u32v();
    const references = try arena.alloc(Reference, references_len);
    for (references) |*ref| ref.* = try readReference(&r);

    // HashMap 5개 (PR3). scope_maps 는 맵 배열 — 길이만큼 alloc 후 각 맵 복원.
    const scope_maps_len = try r.u32v();
    const scope_maps = try arena.alloc(std.StringHashMapUnmanaged(usize), scope_maps_len);
    for (scope_maps) |*m| m.* = try readStrMapUsize(&r, arena);
    const exported_names = try readStrMapSpan(&r, arena);
    const unresolved_references = try readStrSet(&r, arena);
    const numeric_const_texts = try readNumTexts(&r, arena);
    const helper_scope_map = try readStrMapUsize(&r, arena);

    return .{
        .symbols = .{ .items = symbols_slice, .capacity = symbols_slice.len },
        .scopes = scopes,
        .scope_maps = scope_maps,
        .exported_names = exported_names,
        .symbol_ids = symbol_ids,
        .unresolved_references = unresolved_references,
        .references = references,
        .numeric_const_texts = numeric_const_texts,
        .helper_scope_map = helper_scope_map,
    };
}
