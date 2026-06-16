//! semantic 직렬화 codec — 디스크 캐시(#4438) PR2.
//!
//! `ModuleSemanticData` 의 **relocatable 부분만** 직렬화한다 (사용자 결정: 점진 PR).
//! - `scopes` / `symbol_ids` / `references`: 전부 인덱스·스칼라라 통째 memcpy.
//! - `symbols`(ArrayList): Symbol 도 대부분 인덱스/Span 이라 memcpy, 단 `synthetic_name`
//!   (`[]const u8`, 합성 심볼만 non-empty)만 별도 — memcpy 후 ""로 리셋하고 사이드테이블에서
//!   복원(arena dupe).
//! - HashMap 5개(scope_maps/exported_names/unresolved_references/numeric_const_texts/
//!   helper_scope_map)는 **PR3**. 여기선 빈 맵으로 복원.
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

/// `arena` 에 모든 배열·문자열을 alloc 하여 ModuleSemanticData 복원. HashMap 5개는 빈 맵(PR3).
/// caller 가 `arena.deinit()` 로 일괄 해제(원본 parse_arena 모델과 동일). 검증 실패는 error.
///
/// ⚠️ HashMap 5개(scope_maps/exported_names/unresolved_references/numeric_const_texts/
/// helper_scope_map)가 빈 채로 복원되므로, 이 결과를 linker 의 cache-hit 경로에 연결하면
/// import 미링크 / 글로벌 shadowing / 잘못된 export 판정으로 **silent miscompile** 한다.
/// PR3(HashMap 복원) 전까지 파이프라인 연결 금지 — 현재는 codec 단위 테스트 전용.
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

    return .{
        .symbols = .{ .items = symbols_slice, .capacity = symbols_slice.len },
        .scopes = scopes,
        .scope_maps = &.{}, // PR3
        .exported_names = .empty, // PR3
        .symbol_ids = symbol_ids,
        .unresolved_references = .empty, // PR3
        .references = references,
        .numeric_const_texts = .empty, // PR3
        .helper_scope_map = .empty, // PR3
    };
}
