//! module 결합 codec — source+AST+semantic 한 캐시 엔트리. 디스크 캐시(#4438) PR4.
//!
//! PR1 `ast_codec`(AST+source) 와 PR2/PR3 `semantic_codec`(ModuleSemanticData) 를 **하나의
//! 바이트 스트림**으로 묶는다. 한 파일 = 한 모듈의 **AST+semantic** 직렬화.
//!
//! ⚠️ 범위: AST+semantic 만이다. graph 레벨 상태(`import_records`/`resolved_deps`/
//! `legal_comments`/`line_offsets`/`mtime` 등 Module 필드)는 **포함하지 않는다** — cache-hit
//! 으로 Module 을 복원하는 후속 graph 통합 PR 이 재-scan 하거나 별도 직렬화해야 한다(여기서
//! 다 담았다고 가정하면 import 미링크 등으로 깨진다).
//!
//! ## 결합 레이어의 책임 (얇은 래퍼가 아니다)
//! 1. **framing**: `[MAGIC][VERSION][ast_block][sem_block]`. 번들 포맷이 하위 codec 버전과
//!    독립적으로 진화할 수 있도록 결합 레벨 버전을 둔다.
//! 2. **소유권 단일화 (핵심)**: 두 하위 codec 에 **같은 arena 를 주입**한다. `ast_codec` 은
//!    source/nodes/extra_data/string_table 를, `semantic_codec` 은 symbols/scopes/맵을 모두
//!    그 arena 에 복원 → `arena.deinit()` 하나로 일괄 해제. 이는 원본의 `Module.parse_arena`
//!    가 AST+source+semantic 를 통째 소유하는 모델과 **정확히 동일**하다. graph 통합(후속 PR)
//!    이 의존할 불변식을 여기서 확립한다.
//! 3. **fail-safe 합성**: 어느 하위 블록이든 손상되면 그 codec 의 magic/checksum 검증이
//!    error 를 내고, 결합 레이어는 그 error 를 그대로 전파(부분 복원 없음). 잘못된 캐시를
//!    조용히 쓰는 것보다 재파싱이 항상 안전하다는 비대칭 원칙.
//!
//! ## 결합 레벨 checksum 을 두지 않는 이유
//! 두 하위 블록은 각자 payload 전체에 대한 wyhash checksum 을 이미 가진다. 결합 레이어가
//! 다시 전체를 해싱하면 같은 바이트를 두 번 해싱하는 낭비(디스크 캐시의 존재 이유=속도)다.
//! checksum 밖에 남는 바이트는 결합 `MAGIC`/`VERSION`/두 길이 prefix 뿐인데, 손상 시 각각
//! BadMagic / UnsupportedVersion / (잘못된 경계→하위 codec magic·checksum 실패) 로 전부
//! error 로 수렴하므로 silent miscompile 이 불가능하다. → 결합 checksum 불필요.
//!
//! 포맷은 host endian/정렬 native — 로컬 캐시 전제(하위 codec 과 동일).

const std = @import("std");
const ast_codec = @import("../parser/ast_codec.zig");
const semantic_codec = @import("semantic_codec.zig");
const Ast = @import("../parser/ast.zig").Ast;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;

pub const MAGIC: u32 = 0x5A4D4F44; // "ZMOD"
pub const FORMAT_VERSION: u32 = 1;
/// header = magic(4) + version(4). 결합 checksum 없음(위 doc 참조).
const HEADER_LEN: usize = 8;

/// 하위 codec 의 error 집합을 그대로 흡수(BadMagic/UnsupportedVersion/ChecksumMismatch/
/// Truncated + Allocator.Error). 결합 레벨 검증 실패도 같은 집합으로 보고.
pub const Error = ast_codec.Error || semantic_codec.Error;

/// deserialize 결과. `source` 는 `ast.source` 로 접근한다 — ast_codec 이 이미 source 를
/// 복원하므로 중복 저장하지 않는다(Span/심볼 offset 의 진실소스 = ast.source).
///
/// ⚠️ 소유권: `ast`/`semantic` 의 모든 메모리는 deserialize 에 주입한 **arena 가 단독 소유**한다.
/// 개별 `ast.deinit()` 를 호출하지 말 것 — `arena.deinit()` 하나로 일괄 해제한다(CLAUDE.md #1287:
/// arena 리소스 개별 deinit + arena.deinit 동시 호출 = segfault). 원본 `Module.parse_arena` 모델과 동일.
pub const DeserializedModule = struct {
    ast: Ast,
    semantic: ModuleSemanticData,
};

comptime {
    // serialize/deserialize 가 이 struct 의 2개 필드를 손으로 열거한다. 3번째 캐시 구성요소
    // (예: import_records)가 추가되면 직렬화에서 silently 누락 → cache-hit 연결 시 drift.
    // 필드 수를 못박아 codec 갱신을 컴파일 에러로 강제(semantic_codec 의 ModuleSemanticData
    // 가드와 동일 철학).
    if (@typeInfo(DeserializedModule).@"struct".fields.len != 2) {
        @compileError("DeserializedModule 필드 수가 바뀜 — module_codec serialize/deserialize 갱신 필요.");
    }
}

// ── serialize ───────────────────────────────────────────────────────────────

fn putU32(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    try buf.appendSlice(alloc, std.mem.asBytes(&v));
}

/// `out.items[at..][0..4]` 에 u32 를 덮어쓴다(길이 prefix backpatch).
fn patchU32(out: *std.ArrayList(u8), at: usize, v: u32) void {
    @memcpy(out.items[at..][0..4], std.mem.asBytes(&v));
}

/// 하위 codec 출력을 `out` 에 직접 append 하고 길이 prefix 만 backpatch. 임시 버퍼+복사를 피해
/// alloc/memcpy 를 절약한다(out 이 재할당돼도 slot 은 인덱스라 유효).
fn appendBlock(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    comptime serializeFn: anytype,
    payload: anytype,
) !void {
    const slot = out.items.len;
    try putU32(out, alloc, 0); // 길이 placeholder
    const start = out.items.len;
    try serializeFn(payload, out, alloc);
    patchU32(out, slot, @intCast(out.items.len - start));
}

/// source+AST+semantic 을 `out` 에 직렬화(append). ast/sem 은 같은 모듈의 것이어야 한다
/// (semantic 의 Span/키 offset 이 ast.source 를 기준으로 하므로).
pub fn serialize(
    ast: *const Ast,
    sem: *const ModuleSemanticData,
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
) !void {
    try putU32(out, alloc, MAGIC);
    try putU32(out, alloc, FORMAT_VERSION);

    // 각 하위 블록은 자체 [magic/version/checksum] 헤더를 가지므로 결합 레이어는 길이 framing 만.
    try appendBlock(out, alloc, ast_codec.serialize, ast);
    try appendBlock(out, alloc, semantic_codec.serialize, sem);
}

// ── deserialize ──────────────────────────────────────────────────────────────

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) Error![]const u8 {
        // checked add — 손상된 length-prefix 가 pos+n 을 오버플로우시켜 경계검사를 우회하는 것 방지.
        const end = std.math.add(usize, self.pos, n) catch return error.Truncated;
        if (end > self.buf.len) return error.Truncated;
        const b = self.buf[self.pos..][0..n];
        self.pos = end;
        return b;
    }
    fn u32v(self: *Reader) Error!u32 {
        return std.mem.bytesToValue(u32, (try self.take(4))[0..4]);
    }
    fn block(self: *Reader) Error![]const u8 {
        const n = try self.u32v();
        return self.take(n);
    }
};

/// flat bytes → source+AST+semantic. magic/version 검증 후 두 하위 블록을 같은 `arena` 에
/// 복원한다(소유권 단일화 — 위 doc 참조). 검증/손상 실패는 항상 error 이며, 부분 복원분은
/// **caller 의 `arena.deinit()` 가 일괄 회수**한다(원본 parse_arena 모델과 동일).
///
/// `arena` 는 반드시 ArenaAllocator 의 allocator 여야 한다 — ast_codec 이 dupe 한 `ast.source` 는
/// `Ast.deinit` 가 해제하지 않으므로, 비-arena allocator 를 넘기면 source 가 누수된다.
///
/// ⚠️ codec 자체는 완전하나, 무효화 키(버전·옵션·tsconfig·.env) 정합성이 후속 PR 전까지
/// 미비하므로 그 전에 graph cache-hit 경로에 연결하면 stale 캐시로 잘못된 결과가 나온다.
/// 현재는 codec 단위 테스트 전용.
pub fn deserialize(data: []const u8, arena: std.mem.Allocator) Error!DeserializedModule {
    if (data.len < HEADER_LEN) return error.Truncated;
    if (std.mem.bytesToValue(u32, data[0..4]) != MAGIC) return error.BadMagic;
    if (std.mem.bytesToValue(u32, data[4..8]) != FORMAT_VERSION) return error.UnsupportedVersion;

    var r = Reader{ .buf = data[HEADER_LEN..] };
    const ast_block = try r.block();
    const sem_block = try r.block();

    // 같은 arena 주입 → ast(source 포함)+semantic 이 한 소유권. 하위 codec 의 errdefer/free 는
    // arena 에서 no-op 이고, ast 가 성공한 뒤 semantic 이 실패해도 caller 의 arena.deinit 이 회수.
    const ast = try ast_codec.deserialize(ast_block, arena);
    const semantic = try semantic_codec.deserialize(sem_block, arena);

    return .{ .ast = ast, .semantic = semantic };
}
