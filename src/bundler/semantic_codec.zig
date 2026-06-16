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
const Scope = @import("../semantic/scope.zig").Scope;
const Span = @import("../lexer/token.zig").Span;
const wyhash = @import("../util/wyhash.zig");

pub const MAGIC: u32 = 0x5A53454D; // "ZSEM"
pub const FORMAT_VERSION: u32 = 1;
const HEADER_LEN: usize = 16;

comptime {
    // memcpy round-trip 안전성: Symbol 의 top-level 슬라이스/포인터 필드는 `synthetic_name`
    // 하나만이어야 한다(deserialize 가 별도 복원). 새 슬라이스/포인터 필드가 추가되면 memcpy 가
    // dangling 을 복사하므로, 여기서 컴파일 에러로 codec 복원 로직 추가를 강제한다.
    for (@typeInfo(Symbol).@"struct".fields) |f| {
        if (@typeInfo(f.type) == .pointer and !std.mem.eql(u8, f.name, "synthetic_name")) {
            @compileError("Symbol." ++ f.name ++ ": semantic_codec 는 synthetic_name 외 슬라이스를 round-trip 처리하지 않는다 — codec 복원 로직 추가 필요.");
        }
    }
    // Scope/Reference 는 사이드테이블 없이 통째로 memcpy 한다(synthetic_name 같은 예외 없음).
    // 슬라이스/포인터 필드가 추가되면 dangling 을 복사 → UAF. 컴파일 에러로 복원 로직을 강제.
    for (.{ Scope, Reference }) |T| {
        for (@typeInfo(T).@"struct".fields) |f| {
            if (@typeInfo(f.type) == .pointer) {
                @compileError(@typeName(T) ++ "." ++ f.name ++ ": semantic_codec 는 통째 memcpy 한다 — 슬라이스/포인터는 round-trip 시 dangling. side-table 복원 로직 추가 필요.");
            }
        }
    }
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

fn putU32(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    try buf.appendSlice(alloc, std.mem.asBytes(&v));
}
fn putU64(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u64) !void {
    try buf.appendSlice(alloc, std.mem.asBytes(&v));
}
fn putBytes(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, b: []const u8) !void {
    try putU32(buf, alloc, @intCast(b.len));
    try buf.appendSlice(alloc, b);
}

// HashMap 직렬화 (PR3). 모두 `[count][entry…]`. 키 문자열은 putBytes 로 그대로 (deserialize
// 가 arena dupe). 값 usize 는 심볼 인덱스(symbol_ids 와 동일하게 u32 범위)라 u32 로 고정 —
// disk 크기 절감 + host arch 무관.
fn putStrMapUsize(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(usize)) !void {
    try putU32(buf, alloc, m.count());
    var it = m.iterator();
    while (it.next()) |e| {
        try putBytes(buf, alloc, e.key_ptr.*);
        try putU32(buf, alloc, @intCast(e.value_ptr.*));
    }
}
fn putStrMapSpan(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(Span)) !void {
    try putU32(buf, alloc, m.count());
    var it = m.iterator();
    while (it.next()) |e| {
        try putBytes(buf, alloc, e.key_ptr.*);
        try putU32(buf, alloc, e.value_ptr.start);
        try putU32(buf, alloc, e.value_ptr.end);
    }
}
fn putStrSet(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.StringHashMapUnmanaged(void)) !void {
    try putU32(buf, alloc, m.count());
    var it = m.keyIterator();
    while (it.next()) |k| try putBytes(buf, alloc, k.*);
}
fn putNumTexts(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, m: *const std.AutoHashMapUnmanaged(u32, []const u8)) !void {
    try putU32(buf, alloc, m.count());
    var it = m.iterator();
    while (it.next()) |e| {
        try putU32(buf, alloc, e.key_ptr.*);
        try putBytes(buf, alloc, e.value_ptr.*);
    }
}

/// semantic 의 relocatable 부분을 `out` 에 직렬화 (append).
pub fn serialize(sem: *const ModuleSemanticData, out: *std.ArrayList(u8), alloc: std.mem.Allocator) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);

    try putBytes(&payload, alloc, std.mem.sliceAsBytes(sem.symbols.items));
    try putBytes(&payload, alloc, std.mem.sliceAsBytes(sem.scopes));
    try putBytes(&payload, alloc, std.mem.sliceAsBytes(sem.symbol_ids));
    try putBytes(&payload, alloc, std.mem.sliceAsBytes(sem.references));

    // synthetic_name 사이드 (non-empty symbol 의 index + text). memcpy 로 온 dangling ptr 를
    // deserialize 가 ""로 리셋 후 여기서 복원.
    var syn_count: u32 = 0;
    for (sem.symbols.items) |s| {
        if (s.synthetic_name.len > 0) syn_count += 1;
    }
    try putU32(&payload, alloc, syn_count);
    for (sem.symbols.items, 0..) |s, i| {
        if (s.synthetic_name.len > 0) {
            try putU32(&payload, alloc, @intCast(i));
            try putBytes(&payload, alloc, s.synthetic_name);
        }
    }

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

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) Error![]const u8 {
        const end = std.math.add(usize, self.pos, n) catch return error.Truncated;
        if (end > self.buf.len) return error.Truncated;
        const b = self.buf[self.pos..][0..n];
        self.pos = end;
        return b;
    }
    fn u32v(self: *Reader) Error!u32 {
        return std.mem.bytesToValue(u32, (try self.take(4))[0..4]);
    }
    fn bytes(self: *Reader) Error![]const u8 {
        const n = try self.u32v();
        return self.take(n);
    }
};

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

    const symbols_bytes = try r.bytes();
    const scopes_bytes = try r.bytes();
    const symbol_ids_bytes = try r.bytes();
    const references_bytes = try r.bytes();

    // 비배수 길이는 @memcpy 패닉 → fail-safe 위반. error 로 거른다.
    if (symbols_bytes.len % @sizeOf(Symbol) != 0) return error.Truncated;
    if (scopes_bytes.len % @sizeOf(Scope) != 0) return error.Truncated;
    if (symbol_ids_bytes.len % @sizeOf(?u32) != 0) return error.Truncated;
    if (references_bytes.len % @sizeOf(Reference) != 0) return error.Truncated;

    const symbols_slice = try arena.alloc(Symbol, symbols_bytes.len / @sizeOf(Symbol));
    @memcpy(std.mem.sliceAsBytes(symbols_slice), symbols_bytes);

    const scopes = try arena.alloc(Scope, scopes_bytes.len / @sizeOf(Scope));
    @memcpy(std.mem.sliceAsBytes(scopes), scopes_bytes);

    const symbol_ids = try arena.alloc(?u32, symbol_ids_bytes.len / @sizeOf(?u32));
    @memcpy(std.mem.sliceAsBytes(symbol_ids), symbol_ids_bytes);

    const references = try arena.alloc(Reference, references_bytes.len / @sizeOf(Reference));
    @memcpy(std.mem.sliceAsBytes(references), references_bytes);

    // synthetic_name: symbols memcpy 는 원본 arena 를 가리키는 dangling slice ptr 를 그대로
    // 복사하므로, 전부 ""(len 0, ptr 무관)로 리셋한 뒤 사이드테이블에서 복원(arena dupe). 이
    // 리셋을 제거하면 UAF — 위 comptime 가드가 synthetic_name 이 유일한 슬라이스임을 보장한다.
    for (symbols_slice) |*s| s.synthetic_name = "";
    const syn_count = try r.u32v();
    var k: u32 = 0;
    while (k < syn_count) : (k += 1) {
        const idx = try r.u32v();
        const text = try r.bytes();
        if (idx >= symbols_slice.len) return error.Truncated;
        symbols_slice[idx].synthetic_name = try arena.dupe(u8, text);
    }

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
