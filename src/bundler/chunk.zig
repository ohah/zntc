//! ZNTC Bundler — Chunk / ChunkGraph
//!
//! Code splitting의 기본 자료구조: BitSet, Chunk, ChunkGraph.
//!
//! 각 진입점(entry point)마다 하나의 비트를 할당하고,
//! 모듈이 어떤 진입점들에서 도달 가능한지를 BitSet으로 추적한다.
//! 동일한 BitSet을 가진 모듈들은 같은 Chunk로 묶인다.
//!
//! 설계:
//!   - esbuild/Rolldown 방식: 진입점 비트 마스크로 청크 분할
//!   - BitSet: 값 타입, HashMap 키로 사용 가능 (hash/eql 구현)
//!   - ChunkGraph: 청크 목록 + 모듈→청크 매핑
//!
//! 참고:
//!   - references/esbuild/pkg/api/api_impl.go (computeChunks)
//!   - references/rolldown/crates/rolldown/src/chunk_graph/

const std = @import("std");
const wyhash = @import("../util/wyhash.zig");
const types = @import("types.zig");
const ModuleIndex = types.ModuleIndex;
pub const ChunkIndex = types.ChunkIndex;
const Module = @import("module.zig").Module;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const TreeShaker = @import("tree_shaker.zig").TreeShaker;
const linker_mod = @import("linker.zig");
const Linker = linker_mod.Linker;
const SymbolRef = linker_mod.SymbolRef;
const metadata_mod = @import("linker/metadata.zig");
const preamble_writer = @import("linker/preamble_writer.zig");

// ============================================================
// BitSet — 진입점 비트 마스크
// ============================================================

/// 고정 크기 비트 집합. 진입점 도달 가능성을 추적하는 데 사용.
/// `[]u8` 기반 — `std.DynamicBitSet`(`[]usize`)와 달리 hash/eql이 바이트 단위로 동작하여
/// 엔디안/패딩 영향 없이 HashMap 키로 안전하게 사용 가능.
pub const BitSet = struct {
    entries: []u8,

    /// max_bits 크기의 빈 BitSet을 생성한다.
    pub fn init(allocator: std.mem.Allocator, max_bits: u32) !BitSet {
        const byte_count = (max_bits + 7) / 8;
        const entries = try allocator.alloc(u8, byte_count);
        @memset(entries, 0);
        return .{ .entries = entries };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *BitSet, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.entries = &.{};
    }

    /// 독립적인 복사본을 만든다.
    pub fn clone(self: BitSet, allocator: std.mem.Allocator) !BitSet {
        return .{ .entries = try allocator.dupe(u8, self.entries) };
    }

    /// 특정 비트가 설정되어 있는지 확인한다.
    pub fn hasBit(self: BitSet, bit: u32) bool {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return false;
        return (self.entries[byte_idx] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
    }

    /// 특정 비트를 설정한다.
    pub fn setBit(self: *BitSet, bit: u32) void {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return;
        self.entries[byte_idx] |= @as(u8, 1) << @intCast(bit % 8);
    }

    /// 특정 비트를 해제한다.
    pub fn clearBit(self: *BitSet, bit: u32) void {
        const byte_idx = bit / 8;
        if (byte_idx >= self.entries.len) return;
        self.entries[byte_idx] &= ~(@as(u8, 1) << @intCast(bit % 8));
    }

    /// [start, start+count) 범위에 설정된 비트가 하나라도 있는지.
    pub fn hasAnyBitInRange(self: BitSet, start: u32, count: u32) bool {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.hasBit(start + i)) return true;
        }
        return false;
    }

    /// [start, start+count) 범위의 모든 비트를 해제한다.
    pub fn clearBitRange(self: *BitSet, start: u32, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            self.clearBit(start + i);
        }
    }

    /// 설정된 비트의 개수를 반환한다.
    pub fn bitCount(self: BitSet) u32 {
        var count: u32 = 0;
        for (self.entries) |byte| {
            count += @popCount(byte);
        }
        return count;
    }

    /// 설정된 비트가 하나도 없는지 확인한다.
    pub fn isEmpty(self: BitSet) bool {
        for (self.entries) |byte| {
            if (byte != 0) return false;
        }
        return true;
    }

    /// other의 비트를 self에 합집합(OR)한다.
    pub fn setUnion(self: *BitSet, other: BitSet) void {
        const len = @min(self.entries.len, other.entries.len);
        for (self.entries[0..len], other.entries[0..len]) |*a, b| {
            a.* |= b;
        }
    }

    /// 두 BitSet이 동일한지 비교한다. 같은 max_bits로 생성된 BitSet끼리 비교해야 정확.
    pub fn eql(self: BitSet, other: BitSet) bool {
        return std.mem.eql(u8, self.entries, other.entries);
    }

    /// self 의 모든 set 비트가 other 에도 set 인지 (self ⊆ other).
    /// 청크 병합 안전성: src ⊆ dst 면 dst 가 로드될 때 항상 src 도 로드되므로
    /// src 모듈을 dst 로 옮겨도 어떤 entry 도 불필요 코드를 받지 않는다.
    pub fn isSubsetOf(self: BitSet, other: BitSet) bool {
        const len = @min(self.entries.len, other.entries.len);
        for (self.entries[0..len], other.entries[0..len]) |a, b| {
            if (a & ~b != 0) return false;
        }
        if (self.entries.len > len) for (self.entries[len..]) |a| {
            if (a != 0) return false;
        };
        return true;
    }

    /// 해시값을 계산한다 (HashMap 키로 사용).
    pub fn hash(self: BitSet) u64 {
        return wyhash.hashU64(self.entries);
    }
};

/// BitSet을 HashMap 키로 사용하기 위한 컨텍스트.
pub const BitSetContext = struct {
    pub fn hash(_: BitSetContext, key: BitSet) u64 {
        return key.hash();
    }
    pub fn eql(_: BitSetContext, a: BitSet, b: BitSet) bool {
        return a.eql(b);
    }
};

// ============================================================
// ChunkKind — 청크 종류
// ============================================================

/// 청크의 종류: 진입점(entry_point) / 공통(common) / 사용자 정의(manual).
pub const ChunkKind = union(enum) {
    /// 진입점에서 생성된 청크
    entry_point: struct {
        /// 이 진입점의 비트 인덱스 (BitSet에서의 위치)
        bit: u32,
        /// 진입점 모듈의 인덱스
        module: ModuleIndex,
        /// 동적 import로 생성된 진입점인지 여부
        is_dynamic: bool,
        /// (#4522) 그 dynamic entry 가 **진짜 `import()` 대상**인지. federation expose /
        /// plugin `emitFile({type:'chunk'})` 도 같은 dynamic entry 모양을 쓰지만, 그쪽
        /// 소비자는 zntc 가 아니라 **container factory / 사용자 코드**다. 그래서 CJS 청크의
        /// `default` 슬롯 의미를 바꾸면(값 → namespace) 조용히 깨진다 — 그 둘은 제외한다.
        is_import_call: bool = false,
    },
    /// 여러 진입점이 공유하는 공통 청크
    common,
    /// `manual_chunks` 옵션이 지정한 사용자 정의 청크 (#1027).
    /// 이 청크에 해당하는 BitSet bit 를 소유하며, 매칭된 모듈은 항상 이 청크로 간다.
    manual: struct {
        bit: u32,
        name: []const u8,
    },
};

// ============================================================
// Chunk — 단일 청크
// ============================================================

/// 심볼 수준 cross-chunk import 한 건. `imports_from` 값 목록의 원소.
/// `name` 은 dep 청크가 노출하는 **export 키**(destructuring 좌변; `default`
/// 같은 예약어일 수 있다). `canonical_module` 은 그 export 의 canonical 정의
/// 모듈 — emitter 가 예약어 키일 때 `resolveToLocalName(SymbolRef)` 로 소비자
/// 가 실제 참조하는 local 바인딩명(예: `_default`)을 해석하는 데 쓴다. 비예약어
/// 키는 export 명 == 바인딩명이라 canonical_module 을 보지 않는다(기존 동작).
pub const CrossChunkSym = struct {
    name: []const u8,
    canonical_module: u32,
};

/// 번들 출력의 단위. 하나의 JS 파일로 출력된다.
/// 동일한 BitSet(진입점 집합)을 가진 모듈들이 하나의 Chunk에 묶인다.
pub const Chunk = struct {
    /// 청크 그래프에서의 인덱스
    index: ChunkIndex,
    /// 청크 종류 (진입점 / 공통)
    kind: ChunkKind,
    /// 어떤 진입점들에서 도달 가능한지 (비트 마스크)
    bits: BitSet,
    /// 이 청크에 포함된 모듈 목록
    modules: std.ArrayListUnmanaged(ModuleIndex),
    /// 출력 파일명 (stem, 예: "index"). 빌림 — deinit에서 해제하지 않음.
    name: ?[]const u8,
    /// 최종 출력 경로 (예: "dist/index-abc123.js"). 빌림 — deinit에서 해제하지 않음.
    filename: ?[]const u8,
    /// plugin `emitFile({ type:'chunk', fileName })` 의 verbatim 출력 경로 (#1880 PR7-2d).
    /// non-null 이면 naming pattern([name]-[hash]) / content-hash placeholder / 확장자 append 를
    /// 모두 우회해 이 문자열을 그대로 출력 파일명·import 경로로 쓴다. emit_store 소유 — 빌림(미해제).
    explicit_file_name: ?[]const u8 = null,
    /// PR-3a-ii (lazy compilation): 이 청크의 entry 모듈이 미파싱 lazy seed 다
    /// (`Module.is_lazy_seed`). 미생성(미파싱)이라 emit 에서 skip 되고, 파일명은
    /// content-hash 가 아닌 `lazy_path_hash`(경로 기반) 로 안정화 — entry 가 아직
    /// 안 만든 청크를 안정 이름으로 선참조할 수 있게 한다.
    is_lazy_seed: bool = false,
    /// #4079: 파일명을 content-hash 가 아니라 `lazy_path_hash`(경로 기반)로 쓸지 여부.
    /// `is_lazy_seed`(미파싱·emit-skip)와 분리된 개념 — lazy 빌드의 *동적 import 타겟*
    /// 청크는 force-parse 되어 본문이 있어도(=emit 됨, is_lazy_seed=false) path-hash
    /// 이름을 유지해야 브라우저가 박은 `__zntc_load_chunk` URL 이 lazy↔force-parse 전환에
    /// 불변이다(dev materialize 토대). is_lazy_seed ⊂ use_lazy_path_name.
    use_lazy_path_name: bool = false,
    /// lazy seed 청크의 경로 기반 안정 hash (entry 모듈 path 의 Wyhash). content-hash
    /// 와 달리 청크 본문이 없어도 결정되며, PR-3b 가 on-demand 빌드 시 같은 이름 재현.
    lazy_path_hash: u64 = 0,
    /// 실행 순서 (exec_index 기준 정렬에 사용)
    exec_order: u32,
    /// preserve-modules: 원본 모듈의 절대 경로 (출력 디렉토리 구조 결정용).
    /// null이면 일반 청크 (preserve-modules 아님).
    rel_dir: ?[]const u8 = null,
    /// 출력 경로 패턴 `[dir]` 토큰 치환용 — entry 의 `entry_dir` 기준 상대
    /// 디렉토리. `rel_dir`(= 절대경로 + 파일명 + ext, preserve-modules 한정)
    /// 의 misnomer 와 분리된 안전한 필드. sanitize 거친 결과:
    ///   - Windows 백슬래시 → `/` 정규화
    ///   - leading/trailing `/` 제거
    ///   - `..` 세그먼트 / NUL 발견 시 빈 문자열(불안전 거부)
    /// **소유권**: `sanitizeNameDir` 가 alloc 한 메모리 — chunk 가 own,
    /// `Chunk.deinit` 에서 free. (`chunk.rel_dir` 와 다름 — 그쪽은 빌림.)
    /// 현재 PR(B-1)에서는 채워두기만 하고, `chunkPlaceholderStem` 등
    /// 호출자가 활성화하는 시점은 PR B-4 (default 변경) 에서.
    name_dir: ?[]const u8 = null,

    // Cross-chunk linking
    /// 이 청크가 import하는 다른 청크 목록
    cross_chunk_imports: std.ArrayListUnmanaged(ChunkIndex),
    /// 이 청크가 동적 import하는 다른 청크 목록
    cross_chunk_dynamic_imports: std.ArrayListUnmanaged(ChunkIndex),

    /// 심볼 수준 크로스 청크 import: source_chunk_index → 가져올 심볼 목록.
    /// computeCrossChunkLinks에서 linker가 있을 때만 채워진다. 각 원소는 export
    /// 키 + canonical 모듈(예약어 키의 바인딩명 해석용) — `CrossChunkSym` 참조.
    imports_from: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(CrossChunkSym)),
    /// 이 청크에서 다른 청크로 내보내는 심볼 이름 집합.
    /// 공통 청크에서 export 문을 생성할 때 사용.
    exports_to: std.StringHashMapUnmanaged(void),

    /// (#4541) raw `require("./x.cjs")` 로 **다른 청크**의 CJS 모듈을 참조하면 그 `require_X` 썽크를
    /// cross-chunk export/import 해야 한다(esbuild/rolldown 동형: provider `export{require_X}`,
    /// 소비자 `import{require_X}` 후 `require_X()`). import binding 이 없는 raw require 라 기존
    /// exports_to/imports_from(심볼 export명 키) 기계가 못 봐 별도 트랙으로 둔다(래퍼는 scope_id
    /// =.none 이라 rename 풀에도 없음, canonical 이름은 reserveWrapperNames 로 전역 유일).
    /// wrapper_cross_exports = 이 청크가 썽크로 export 해야 할 (CJS wrap) 모듈 index 집합.
    wrapper_cross_exports: std.AutoHashMapUnmanaged(u32, void),
    /// src_chunk_index → 이 청크가 그 청크에서 import 해야 할 wrapper(CJS) 모듈 index 목록.
    wrapper_cross_imports: std.AutoHashMapUnmanaged(u32, std.ArrayListUnmanaged(u32)),

    /// 기본값으로 Chunk를 생성한다.
    pub fn init(index: ChunkIndex, kind: ChunkKind, bits: BitSet) Chunk {
        return .{
            .index = index,
            .kind = kind,
            .bits = bits,
            .modules = .empty,
            .name = null,
            .filename = null,
            .exec_order = std.math.maxInt(u32),
            .cross_chunk_imports = .empty,
            .cross_chunk_dynamic_imports = .empty,
            .imports_from = .empty,
            .exports_to = .empty,
            .wrapper_cross_exports = .empty,
            .wrapper_cross_imports = .empty,
        };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        self.bits.deinit(allocator);
        self.modules.deinit(allocator);
        self.cross_chunk_imports.deinit(allocator);
        self.cross_chunk_dynamic_imports.deinit(allocator);
        // imports_from: 각 값(ArrayListUnmanaged)도 해제
        var it = self.imports_from.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.imports_from.deinit(allocator);
        self.exports_to.deinit(allocator);
        self.wrapper_cross_exports.deinit(allocator);
        var wit = self.wrapper_cross_imports.iterator();
        while (wit.next()) |entry| entry.value_ptr.deinit(allocator);
        self.wrapper_cross_imports.deinit(allocator);
        // PR B-1: name_dir 은 sanitizeNameDir 의 결과 — chunk 가 owning.
        // doc 의 "빌림" 표현은 부정확 — 실제로는 chunk lifetime 와 일치하므로
        // 여기서 free 한다(chunk.rel_dir 와 달리 항상 alloc 된 메모리).
        if (self.name_dir) |nd| allocator.free(nd);
    }

    /// 청크에 모듈을 추가한다.
    pub fn addModule(self: *Chunk, allocator: std.mem.Allocator, module_idx: ModuleIndex) !void {
        try self.modules.append(allocator, module_idx);
    }

    /// 진입점 청크인지 확인한다.
    pub fn isEntryPoint(self: Chunk) bool {
        return self.kind == .entry_point;
    }
};

// ============================================================
// ChunkGraph — 청크 그래프
// ============================================================

/// 모든 청크와 모듈→청크 매핑을 관리한다.
/// code splitting 알고리즘의 결과를 저장하는 자료구조.
pub const ChunkGraph = struct {
    allocator: std.mem.Allocator,
    /// 모든 청크 목록
    chunks: std.ArrayListUnmanaged(Chunk),
    /// 모듈 인덱스 → 청크 인덱스 매핑 (고정 크기 배열)
    module_to_chunk: []ChunkIndex,
    /// preserve-modules 로 생성된 청크 그래프인가 (`generatePreserveModulesChunks`).
    /// (#4494) cross-chunk **CJS-interop** 배선은 preserve-modules 에서 금지 — bundler 가
    /// 이 모드에선 `cross_chunk_global_names` 를 채우지 않고(전역명 없음) emit 의 xchunk
    /// export 블록도 `!preserve_modules` 게이트라, 등록만 하면 provider 가 노출하지 않는
    /// 이름을 소비자가 `import { default as … }` 로 가져와 링크 에러가 난다.
    preserve_modules: bool = false,

    /// (#4532) preserve-modules(ESM/CJS·non-minify·non-dev) cross-file 심볼 네이밍이 켜졌는지.
    /// bundler.zig 가 computeCrossChunkLinks 전에 세팅. direct `import * as ns`(ESM-wrap dep)
    /// fan-out(증상2)을 이 게이트 + dep `wrap_kind==.esm` 로 한정해, 네이밍이 켜진 경우에만
    /// imports_from 에 등록한다. CJS 출력도 forwarding 썽크로 전역명을 materialize 하므로 포함(증상1).
    pm_xchunk_naming: bool = false,

    /// module_count 크기의 빈 ChunkGraph를 생성한다.
    pub fn init(allocator: std.mem.Allocator, module_count: usize) !ChunkGraph {
        const module_to_chunk = try allocator.alloc(ChunkIndex, module_count);
        @memset(module_to_chunk, .none);
        return .{
            .allocator = allocator,
            .chunks = .empty,
            .module_to_chunk = module_to_chunk,
        };
    }

    /// 메모리를 해제한다.
    pub fn deinit(self: *ChunkGraph) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks.deinit(self.allocator);
        self.allocator.free(self.module_to_chunk);
    }

    /// 청크를 추가하고 할당된 ChunkIndex를 반환한다.
    pub fn addChunk(self: *ChunkGraph, chunk: Chunk) !ChunkIndex {
        const idx: ChunkIndex = @enumFromInt(@as(u32, @intCast(self.chunks.items.len)));
        var c = chunk;
        c.index = idx;
        try self.chunks.append(self.allocator, c);
        return idx;
    }

    /// 읽기 전용으로 청크를 가져온다.
    pub fn getChunk(self: *const ChunkGraph, idx: ChunkIndex) *const Chunk {
        return &self.chunks.items[@intFromEnum(idx)];
    }

    /// 수정 가능한 청크를 가져온다.
    pub fn getChunkMut(self: *ChunkGraph, idx: ChunkIndex) *Chunk {
        return &self.chunks.items[@intFromEnum(idx)];
    }

    /// 모듈을 청크에 할당한다.
    pub fn assignModuleToChunk(self: *ChunkGraph, module_idx: ModuleIndex, chunk_idx: ChunkIndex) void {
        const mi = @intFromEnum(module_idx);
        if (mi < self.module_to_chunk.len) {
            self.module_to_chunk[mi] = chunk_idx;
        }
    }

    /// 모듈이 속한 청크의 인덱스를 반환한다.
    pub fn getModuleChunk(self: *const ChunkGraph, module_idx: ModuleIndex) ChunkIndex {
        const mi = @intFromEnum(module_idx);
        if (mi >= self.module_to_chunk.len) return .none;
        return self.module_to_chunk[mi];
    }

    /// 총 청크 수를 반환한다.
    pub fn chunkCount(self: *const ChunkGraph) usize {
        return self.chunks.items.len;
    }
};

// ============================================================
// entryRelativeDir — abs path → entry_dir 기준 relative
// ============================================================

/// dirname(entry path) 를 graph.entry_dir 기준 *상대 디렉토리* 로 변환.
/// PR B-4b sub-1b 의 핵심 안전망 — 사용자 머신 절대경로(예:
/// `Users/me/proj/src/pages`) 가 `[dir]` 토큰 출력에 누설되는 사고 차단.
///
/// **정책**:
/// 1. entry_dir 가 빈 문자열이면 fallback `""`.
/// 2. abs_dir 가 entry_dir 의 *디렉토리 경계* prefix 가 아니면 fallback `""`
///    — `entry_dir="src/pages"` 가 `abs_dir="src/pages2/a"` 와 byte-startsWith
///    match 해도 sibling dir 라 *false prefix*. boundary 조건: prefix 직후가
///    path-separator(`/`/`\`)이거나 정확히 같은 길이.
/// 3. Windows/POSIX path-separator 양쪽 (`/`/`\`) 정규화 — 양쪽 dir 의 byte
///    비교를 separator-aware 로.
///
/// **반환**: borrow slice (abs_dir 또는 ""). caller 가 sanitize/dupe.
pub fn entryRelativeDir(entry_dir: []const u8, abs_dir: []const u8) []const u8 {
    if (entry_dir.len == 0) return "";
    if (abs_dir.len < entry_dir.len) return "";

    // separator-agnostic byte 비교 (`/`/`\\` 둘 다 separator 로 동등).
    var i: usize = 0;
    while (i < entry_dir.len) : (i += 1) {
        const a = entry_dir[i];
        const b = abs_dir[i];
        const a_norm: u8 = if (a == '\\') '/' else a;
        const b_norm: u8 = if (b == '\\') '/' else b;
        if (a_norm != b_norm) return "";
    }
    // boundary 검사: prefix 직후가 separator 거나 정확히 entry_dir 와 같은 길이.
    if (abs_dir.len == entry_dir.len) return "";
    const sep = abs_dir[entry_dir.len];
    if (sep != '/' and sep != '\\') return ""; // sibling-prefix 차단
    // leading separator 한 개 skip 후 반환.
    return abs_dir[entry_dir.len + 1 ..];
}

// ============================================================
// sanitizeNameDir — Chunk.name_dir 채울 raw dir 정규화
// ============================================================

/// Chunk.name_dir 채우기 전에 raw dir 슬라이스를 안전 형태로 변환한다.
/// 정책 (PR B-1 기반, PR B-3 정밀화):
///   - **거부** (빈 문자열 반환):
///     - NUL 바이트
///     - `..` 단일 segment (path traversal)
///     - Windows drive letter prefix (`^[A-Za-z]:` 첫 2 바이트)
///     - control byte (0x01-0x1F, 0x7F)
///     - Windows-reserved char (`<>:"|?*`)
///     - 단독 `.` (current dir reference)
///   - **정규화**:
///     - Windows 백슬래시 → forward `/`
///     - leading/trailing `/` 제거 (절대경로 흡수, double-slash 방지)
///     - mid-path 중복 `/` → 단일 `/` 압축
///     - mid-path `.` segment strip (`a/./b` → `a/b`)
/// **소유권 / 해제**: 반환 슬라이스는 항상 `allocator` 가 alloc 한 owned
/// 메모리(빈 문자열 `""` 도 0-len allocation). caller 는 반드시 `allocator.free`
/// 또는 owning struct 의 deinit 으로 해제해야 한다(길이 0 라도 free 호출은 안전).
/// `Chunk.name_dir` 에 저장 시 `Chunk.deinit` 가 일괄 free.
pub fn sanitizeNameDir(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // 빠른 거부: NUL.
    if (std.mem.indexOfScalar(u8, raw, 0) != null) {
        return allocator.dupe(u8, "");
    }
    // 빠른 거부: Windows drive letter — `^[A-Za-z]:` 가 *path-like* 일 때만
    // (raw 가 정확히 2글자이거나 다음이 `/`/`\\`). `node:fs`, `http:host` 같은
    // virtual-id/namespace prefix 는 path 가 아니므로 통과시킨다(B-3 정밀화).
    if (raw.len >= 2 and raw[1] == ':' and isAsciiAlpha(raw[0])) {
        const is_drive_path = raw.len == 2 or raw[2] == '/' or raw[2] == '\\';
        if (is_drive_path) return allocator.dupe(u8, "");
    }
    // 빠른 거부: control byte / Windows-reserved char.
    for (raw) |c| {
        if (c <= 0x1F or c == 0x7F) return allocator.dupe(u8, "");
        switch (c) {
            '<', '>', '"', '|', '?', '*' => return allocator.dupe(u8, ""),
            else => {},
        }
    }
    // `..` 가 단일 segment 인지 확인: 시작/끝 또는 `/`/`\\` 로 둘러싸여 있음.
    if (raw.len >= 2) {
        var i: usize = 0;
        while (i + 1 < raw.len) : (i += 1) {
            if (raw[i] != '.' or raw[i + 1] != '.') continue;
            const before_ok = (i == 0) or raw[i - 1] == '/' or raw[i - 1] == '\\';
            const after_ok = (i + 2 == raw.len) or raw[i + 2] == '/' or raw[i + 2] == '\\';
            if (before_ok and after_ok) return allocator.dupe(u8, "");
        }
    }

    // 1단계 정규화: 백슬래시 → `/`.
    var norm: std.ArrayListUnmanaged(u8) = .empty;
    defer norm.deinit(allocator);
    try norm.ensureTotalCapacity(allocator, raw.len);
    for (raw) |c| {
        norm.appendAssumeCapacity(if (c == '\\') '/' else c);
    }

    // 2단계 segment 분해 + 단일 `.` strip + 중복 슬래시 압축.
    // `/` 로 split, 빈 segment 와 `.` segment 를 건너뛰고 `/` 로 join.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var first = true;
    var seg_start: usize = 0;
    var k: usize = 0;
    while (k <= norm.items.len) : (k += 1) {
        const at_end = k == norm.items.len;
        const is_sep = !at_end and norm.items[k] == '/';
        if (!is_sep and !at_end) continue;
        const seg = norm.items[seg_start..k];
        seg_start = k + 1;
        // 빈 segment(leading/trailing/double-slash) 와 단일 `.` 은 skip.
        if (seg.len == 0) continue;
        if (seg.len == 1 and seg[0] == '.') continue;
        if (!first) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
        first = false;
    }
    return try out.toOwnedSlice(allocator);
}

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ============================================================
// generateChunks — 모듈 그래프에서 청크 생성
// ============================================================

/// 엔트리 정보. 유저 엔트리와 dynamic import 대상을 구분.
const EntryInfo = struct {
    module_idx: ModuleIndex,
    is_dynamic: bool,
    /// (#4522) 진짜 `import()` 대상인가 (federation expose / plugin emitFile 은 false).
    is_import_call: bool = false,
};

/// 모듈 그래프에서 청크를 생성한다 (esbuild/rolldown 패턴).
///
/// Phase 1: 엔트리 초기화 — 유저 엔트리 + dynamic import 대상을 수집하고,
///          각 엔트리마다 Chunk를 생성한다.
/// Phase 2: 도달 가능성 마킹 — 각 엔트리에서 BFS로 정적 import를 따라가며
///          모듈별 BitSet에 도달 가능한 엔트리 비트를 설정한다.
/// Phase 3: 청크 할당 — 동일한 BitSet을 가진 모듈들을 같은 Chunk에 묶는다.
///          여러 엔트리에서 도달 가능한 모듈은 공통 청크(common chunk)로 분리.
///
/// shaker가 null이 아니면 tree-shaking 결과를 반영하여 미포함 모듈을 스킵한다.
/// manual chunk 이름을 slot index 로 매핑. 이미 있으면 기존 slot 반환, 없으면 새 slot 생성.
/// record entries + resolver 동적 결과의 dedup 통합 지점.
/// (#4553) manualChunks 가 user entry 를 매칭했을 때 1회 경고 — entry 는 relocate 되지 않고 자기
/// 청크에 유지된다(rollup/esbuild 동일). `warned` 로 entry 당 중복 emit 을 막는다.
fn warnManualChunksEntry(
    warned: *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
    mi: u32,
    entry_path: []const u8,
    chunk_name: []const u8,
) !void {
    const gop = try warned.getOrPut(allocator, mi);
    if (gop.found_existing) return;
    std.log.warn("zntc: manualChunks 가 entry '{s}' 를 청크 '{s}' 로 지정했으나, entry 는 relocate 되지 않고 자기 청크에 유지됩니다 (rollup/esbuild 동일).", .{ entry_path, chunk_name });
}

fn ensureNameSlot(
    name_to_slot: *std.StringHashMapUnmanaged(usize),
    effective_names: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    name: []const u8,
) !usize {
    const gop = try name_to_slot.getOrPut(allocator, name);
    if (!gop.found_existing) {
        gop.value_ptr.* = effective_names.items.len;
        try effective_names.append(allocator, name);
    }
    return gop.value_ptr.*;
}

pub const GenerateOptions = struct {
    /// Tree-shaker — 제공되면 unreachable export/모듈을 chunk 에서 제외.
    shaker: ?*const TreeShaker = null,
    /// Rollup record-form `manualChunks` (#1027). substring pattern → chunk name.
    manual_chunks: []const types.ManualChunkEntry = &.{},
    /// Rollup function-form `manualChunks(id, meta)` resolver. resolver 결과가 record 보다 우선.
    manual_resolver: ?types.ManualChunksResolveFn = null,
    /// resolver 에 전달할 user context (TSFN 핸들 등).
    manual_resolver_ctx: ?*anyopaque = null,
    /// Rollup `output.inlineDynamicImports` — dynamic import target 을 importer 의 chunk 로 흡수.
    inline_dynamic_imports: bool = false,
    /// (#4552) run_before_main(Metro runBeforeMainModule) 모듈 경로. entry 앞에서 실행돼야 하므로
    /// **entry 청크에 co-locate** — manual 청크로 relocate 안 함(reg_split 에서 cross-chunk RBM 는
    /// lazy __esm+factory 스코프라 근본적으로 실행 불가). Metro 도 RBM 을 split 하지 않고 번들 최상단.
    run_before_main: []const []const u8 = &.{},
    /// (#4552) reg_split(iife/umd/amd) 출력 여부. RBM co-location 은 reg_split 에서만 적용한다 —
    /// esm/cjs 는 cross-chunk RBM 이 valid ESM `import` 로 동작하므로 사용자의 manualChunks 배치를
    /// 존중(강제 co-locate 하면 caching/split 전략을 무성 무효화).
    reg_split: bool = false,
};

/// 너무 작은 `common` 청크를, 그 청크가 도달 가능한 모든 entry 가 항상 함께
/// 로드하는(= src.bits ⊆ dst.bits) 다른 청크로 병합한다 — 어떤 entry 도 불필요
/// 코드를 받지 않음(over-fetch 없음). entry/manual/dynamic 청크는 보존(사용자가
/// 요청한 출력/명시 의도/지연 로딩). Rollup `output.experimentalMinChunkSize` 류.
/// 크기는 모듈 source 길이 합(minify 전 추정) — 작은 청크 판별엔 충분.
/// `computeCrossChunkLinks` *전* 에 호출해야 cross-chunk import 가 병합 후
/// 기준으로 정확히 재계산된다(빈 청크는 emit 단계가 skip).
/// side-effect 순서: src.bits ⊆ dst.bits 이므로 src 를 import 하는 모든 모듈이
/// dst 가 로드되는 entry 집합에 포함 → src side-effect 가 dst 의 일부로 그대로
/// 실행되어 순서 보존. single-pass(cascade 없음) — A→B 후 B 는 재검사 안 함.
pub fn mergeSmallChunks(
    chunk_graph: *ChunkGraph,
    graph: *const ModuleGraph,
    min_size: usize,
) void {
    if (min_size == 0) return;
    const n = chunk_graph.chunks.items.len;
    if (n < 2) return;

    for (0..n) |si| {
        const src = &chunk_graph.chunks.items[si];
        if (src.modules.items.len == 0) continue; // 이미 병합돼 빈 청크
        if (src.kind != .common) continue; // entry/manual/dynamic 보존
        var size: usize = 0;
        for (src.modules.items) |mi| {
            if (graph.getModule(mi)) |m| size += m.source.len;
        }
        if (size >= min_size) continue;

        // src.bits ⊆ dst.bits 인 비어있지 않은 다른 청크 중 첫째(결정적).
        var target: ?usize = null;
        for (0..n) |ti| {
            if (ti == si) continue;
            const t = &chunk_graph.chunks.items[ti];
            if (t.modules.items.len == 0) continue;
            if (!src.bits.isSubsetOf(t.bits)) continue;
            target = ti;
            break;
        }
        const ti = target orelse continue;
        const dst = &chunk_graph.chunks.items[ti];
        const dst_idx: ChunkIndex = @enumFromInt(@as(u32, @intCast(ti)));
        // 사전 예약 → 루프 중 append 실패로 부분 병합/매핑 불일치 없음(원자적).
        dst.modules.ensureUnusedCapacity(chunk_graph.allocator, src.modules.items.len) catch continue;
        for (src.modules.items) |mi| {
            dst.modules.appendAssumeCapacity(mi);
            chunk_graph.assignModuleToChunk(mi, dst_idx); // 경계검사 포함 기존 헬퍼
        }
        src.modules.clearRetainingCapacity(); // 빈 청크 — emitChunks 가 skip
    }
}

/// 모듈 `idx` 를 동적(lazy) entry 로 등록 — external 제외, `dynamic_seen`
/// 멱등, 이미 user-entry(non-dynamic)면 skip. Phase 1b 동적-import 블록과
/// P1-3 (#3385) federation-expose 블록이 **공유**(dedup/append 규칙 단일
/// 소스 — 한쪽만 바뀌어 규칙 드리프트 방지).
fn addDynamicEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(EntryInfo),
    dynamic_seen: *std.AutoHashMapUnmanaged(u32, void),
    graph: *const ModuleGraph,
    idx: ModuleIndex,
    is_import_call: bool,
) !void {
    if (graph.getModule(idx)) |m| {
        if (m.is_external) return; // external phantom 은 async chunk 불요(번들 외부)
    }
    const di = @intFromEnum(idx);
    const gop = try dynamic_seen.getOrPut(allocator, di);
    if (gop.found_existing) return;
    for (entries.items) |e| {
        if (@intFromEnum(e.module_idx) == di and !e.is_dynamic) return; // 이미 user entry
    }
    try entries.append(allocator, .{ .module_idx = idx, .is_dynamic = true, .is_import_call = is_import_call });
}

/// entries 에서 module_idx 의 entry bit(= entries 인덱스)를 찾는다. 없으면 null(entry 청크 아님).
/// #3664 (2) implicitlyLoadedAfterOneOf bit-collapse 의 parent/E bit lookup 용.
fn entryBit(entries: []const EntryInfo, idx: ModuleIndex) ?u32 {
    for (entries, 0..) |e, bit| {
        if (e.module_idx == idx) return @intCast(bit);
    }
    return null;
}

pub fn generateChunks(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    entry_points: []const []const u8,
    options: GenerateOptions,
) !ChunkGraph {
    const shaker = options.shaker;
    const manual_chunks = options.manual_chunks;
    const manual_resolver = options.manual_resolver;
    const manual_resolver_ctx = options.manual_resolver_ctx;
    const inline_dynamic_imports = options.inline_dynamic_imports;
    const module_count = graph.moduleCount();

    // ── Phase 1: 엔트리 수집 ──
    // 유저 엔트리 (CLI 진입점) + dynamic import 대상을 모두 모은다.
    // 각각이 하나의 출력 청크가 된다.
    var entries: std.ArrayList(EntryInfo) = .empty;
    defer entries.deinit(allocator);

    // Phase 1a: 유저 엔트리 — entry_points 경로와 일치하는 모듈을 찾는다.
    // External phantom 은 chunk 배정 대상이 아니므로 모든 phase 에서 skip.
    {
        var it = graph.modulesIterator();
        var i: usize = 0;
        while (it.next()) |m| : (i += 1) {
            if (m.is_external) continue;
            for (entry_points) |ep| {
                if (std.mem.eql(u8, m.path, ep)) {
                    try entries.append(allocator, .{
                        .module_idx = ModuleIndex.fromUsize(i),
                        .is_dynamic = false,
                    });
                    break;
                }
            }
        }
    }

    // Phase 1b: dynamic import 대상 — 이미 유저 엔트리인 모듈은 스킵.
    // dynamic import 대상은 별도의 청크 경계를 형성한다 (code splitting의 핵심).
    // `inline_dynamic_imports` 가 true 면 이 단계 전체를 skip → dynamic target 이
    // 별도 chunk 로 나뉘지 않고 Phase 2 BFS 에서 importer 와 같은 chunk 로 흡수.
    var dynamic_seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer dynamic_seen.deinit(allocator);

    if (!inline_dynamic_imports) {
        var it = graph.modulesIterator();
        while (it.next()) |m| {
            for (m.dynamic_imports.items) |dyn_idx|
                try addDynamicEntry(allocator, &entries, &dynamic_seen, graph, dyn_idx, true);
        }
    }

    // P1-3 (#3385): MF expose 타깃 → 동적-import 타깃과 동일한 lazy 청크.
    // entry 모듈 reg_id = module_id.moduleId(path, root) = federation_id 가
    // 되어 container.get 이 `__zntc_load_chunk().then(()=>__zntc_require(id))`
    // (동적 wrapper) 를 그대로 재사용. inline_dynamic_imports 와 무관 —
    // 연합 경계는 항상 분리(아니면 container 가 expose 에 도달 불가).
    // dedup/append 은 addDynamicEntry 공유(위 동적 블록과 동일 규칙).
    {
        var mi: usize = 0;
        while (mi < module_count) : (mi += 1) {
            const fidx = ModuleIndex.fromUsize(mi);
            const fm = graph.getModule(fidx) orelse continue;
            if (!fm.is_federation_expose) continue;
            try addDynamicEntry(allocator, &entries, &dynamic_seen, graph, fidx, false); // MF expose — 소비자는 container factory
        }
    }

    // PR7-2b (#1880): plugin this.emitFile({type:'chunk'}) 로 별도 chunk 요청된 모듈 →
    // federation expose 와 동형으로 dynamic entry(lazy 청크) 로 분리. dedup/append 동일 규칙.
    {
        var mi: usize = 0;
        while (mi < module_count) : (mi += 1) {
            const eidx = ModuleIndex.fromUsize(mi);
            const em = graph.getModule(eidx) orelse continue;
            if (!em.is_emitted_chunk_entry) continue;
            try addDynamicEntry(allocator, &entries, &dynamic_seen, graph, eidx, false); // plugin emitFile — 소비자는 사용자 코드
        }
    }

    const entry_count = entries.items.len;
    if (entry_count == 0) {
        return ChunkGraph.init(allocator, module_count);
    }

    // manual chunks 는 entry 뒤에 bit 를 할당 — splitting_info 총 비트폭 = entry + manual.
    // BFS 단계에서 매칭 모듈의 transitive deps 에 manual bit 가 전파되어
    // `rolldown advanced_chunks/include_dependencies_recursively` 와 동일한
    // 정책 (dep 도 같은 manual 청크로) 을 자동으로 얻는다.
    //
    // effective_names[i] = i 번째 manual slot 의 청크 이름. record + resolver 동적
    // 결과를 순서대로 병합. resolver 가 반환한 name 이 record 와 겹치면 동일 slot.
    var effective_names: std.ArrayList([]const u8) = .empty;
    defer effective_names.deinit(allocator);
    var name_to_slot: std.StringHashMapUnmanaged(usize) = .empty;
    defer name_to_slot.deinit(allocator);
    for (manual_chunks) |mc| {
        _ = try ensureNameSlot(&name_to_slot, &effective_names, allocator, mc.name);
    }

    // Dynamic import target 모듈은 manual chunk 에서 제외 (정책 — Rollup/rolldown 동일).
    // lazy load 의미상 vendor 합치면 의도 반전 + scope hoisting 후 namespace 전체 export
    // 재구성 이슈 (#1848/#1849). 강제 흡수는 #1850 에서 근본 수정 검토.
    var dynamic_entry_modules: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer dynamic_entry_modules.deinit(allocator);
    for (entries.items) |e| {
        if (e.is_dynamic) try dynamic_entry_modules.put(allocator, @intFromEnum(e.module_idx), {});
    }

    // (#4553) user(비-dynamic) entry 모듈은 manual 청크에서 제외 — dynamic import 대상과 동일 정책.
    // user entry 는 **항상 자기 entry_point 청크**에 있어야 한다(rollup/esbuild 불변식): entry 실행에
    // 딸린 인프라(bootstrap·보편 wrapper·"use client" 호이스팅·run_before_main·HMR runtime·dev_split
    // 선-init)가 전부 "entry 는 자기 청크에 산다"는 전제에 묶여 있어, manualChunks 로 entry 를 옮기면
    // 그 전제를 쓰는 emit site 전부가 깨진다(#4542/#4548/#4549/#4551 계열). manualChunks 로 entry 이동
    // 은 rollup/esbuild 도 지원하지 않는다 — entry 는 옮기지 않고 매칭 시 warn(아래).
    var user_entry_modules: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer user_entry_modules.deinit(allocator);
    for (entries.items) |e| {
        if (!e.is_dynamic) try user_entry_modules.put(allocator, @intFromEnum(e.module_idx), {});
    }
    // (#4552) run_before_main **클로저**(RBM 모듈 + transitive static deps)를 manual 청크에서 제외 —
    // entry 앞에서 실행돼야 하므로 entry 청크에 co-locate. reg_split(iife/umd/amd)은 cross-chunk RBM 를
    // 근본적으로 못 실행한다(다른 청크의 RBM 은 lazy `__esm` 로 감싸지고 그 init 심볼이 factory 스코프
    // 밖으로 안 나와, entry 청크가 ESM import(IIFE 서 SyntaxError)·미접근 init 호출로 깨짐). Metro 도
    // RBM 을 split 하지 않는다.
    // ⚠️ **reg_split 한정** — esm/cjs 는 cross-chunk RBM 이 valid ESM import 로 동작하므로 사용자
    // manualChunks 배치를 존중(강제 co-locate 금지). ⚠️ **최상위 RBM 만이 아니라 클로저 전체** — RBM 이
    // import 한 모듈이 manual 로 빠지면 entry prelude(emitter collectRunBeforeMainClosure)가 그걸
    // cross-chunk 참조해 똑같이 깨진다. manual 미설정이면 스캔 자체를 skip(불필요 작업 회피).
    var rbm_modules: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer rbm_modules.deinit(allocator);
    if (options.reg_split and (manual_resolver != null or manual_chunks.len > 0)) {
        var rbm_stack: std.ArrayList(ModuleIndex) = .empty;
        defer rbm_stack.deinit(allocator);
        for (options.run_before_main) |rbm_path| {
            const m = graph.findModuleByPath(rbm_path) orelse continue;
            try rbm_stack.append(allocator, m.index);
        }
        while (rbm_stack.pop()) |idx| {
            const gop = try rbm_modules.getOrPut(allocator, @intFromEnum(idx));
            if (gop.found_existing) continue;
            const m = graph.getModule(idx) orelse continue;
            for (m.dependencies.items) |dep| try rbm_stack.append(allocator, dep);
        }
    }
    // 같은 entry 를 resolver·record 양쪽이 매칭해도 warn 은 entry 당 1회만 (이중 emit 방지).
    var warned_manual_entries: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer warned_manual_entries.deinit(allocator);

    // Resolver 결과 미리 수집 — 모듈당 1회 호출. NAPI TSFN 경로에서도 재호출 없음.
    // resolver 없으면 배열 할당 자체 skip (빌드당 module_count × 16B 절약).
    var resolver_assignments: ?[]?usize = null;
    defer if (resolver_assignments) |ra| allocator.free(ra);
    if (manual_resolver) |fn_ptr| {
        const ra = try allocator.alloc(?usize, module_count);
        resolver_assignments = ra;
        @memset(ra, null);
        var it = graph.modulesIterator();
        var mi: usize = 0;
        while (it.next()) |m| : (mi += 1) {
            if (m.is_external) continue;
            if (dynamic_entry_modules.contains(@intCast(mi))) continue;
            if (fn_ptr(manual_resolver_ctx, m.path, @ptrCast(graph))) |chunk_name| {
                // (#4553) user entry 는 manual 로 안 옮긴다 — resolver 는 **호출하되**(getModuleInfo
                // 등 hook 부작용 보존) 배정 결과만 무시하고 warn. resolver 를 아예 안 부르면 inspection
                // hook 을 쓰는 소비자가 깨진다.
                if (user_entry_modules.contains(@intCast(mi))) {
                    try warnManualChunksEntry(&warned_manual_entries, allocator, @intCast(mi), m.path, chunk_name);
                    continue;
                }
                // (#4552) RBM 은 entry 와 co-locate — 배정 무시(dynamic 대상처럼 silent).
                if (rbm_modules.contains(@intCast(mi))) continue;
                ra[mi] = try ensureNameSlot(&name_to_slot, &effective_names, allocator, chunk_name);
            }
        }
    }

    const manual_count = effective_names.items.len;
    const total_bits = entry_count + manual_count;

    // ChunkGraph 생성 — 모듈→청크 매핑 배열을 module_count 크기로 할당.
    var chunk_graph = try ChunkGraph.init(allocator, module_count);
    errdefer chunk_graph.deinit();

    // 모듈별 도달 가능성 BitSet — splitting_info[module_index]는
    // 그 모듈이 어떤 엔트리/manual 청크에서 도달 가능한지를 나타낸다.
    var splitting_info = try allocator.alloc(BitSet, module_count);
    // 안전한 초기값 — init 실패 시 defer에서 deinit 호출해도 안전
    @memset(splitting_info, .{ .entries = &.{} });
    defer {
        for (splitting_info) |*bs| bs.deinit(allocator);
        allocator.free(splitting_info);
    }
    for (splitting_info) |*bs| {
        bs.* = try BitSet.init(allocator, @intCast(total_bits));
    }

    // BitSet → ChunkIndex HashMap (Phase 3에서 O(1) 청크 lookup에 사용).
    // 주의: HashMap key의 BitSet.entries 포인터가 Chunk.bits와 동일한 메모리를 가리킴 (aliased).
    // Chunk.deinit이 []u8를 해제하므로 HashMap.deinit에서는 key를 해제하지 않음.
    // 이 HashMap은 generateChunks 내에서만 사용되고 Chunk보다 먼저 해제됨.
    var bits_to_chunk: std.HashMapUnmanaged(BitSet, ChunkIndex, BitSetContext, 80) = .empty;
    defer bits_to_chunk.deinit(allocator);

    // Phase 1c: 엔트리별 Chunk 생성
    for (entries.items, 0..) |entry, bit_idx| {
        var bits = try BitSet.init(allocator, @intCast(total_bits));
        errdefer bits.deinit(allocator);
        bits.setBit(@intCast(bit_idx));

        // 출력 파일명 = 모듈 파일명의 stem (확장자 제거). plugin emit chunk(name 지정)면 그 name 우선
        // (#1880 PR7-2c) — [name]-[hash] 의 [name] 으로 쓰여 plugin 이 chunk 이름을 제어한다.
        // 명시 fileName(#1880 PR7-2d)이면 verbatim 출력 — explicit_file_name 으로 캐리해 패턴/hash 우회.
        const entry_mod = graph.getModule(entry.module_idx) orelse return error.InvalidEntryModule;
        var explicit_file_name: ?[]const u8 = null;
        const name = blk: {
            if (entry_mod.is_emitted_chunk_entry) {
                if (graph.emit_store) |sp| {
                    const store: *const @import("emit_store.zig").EmitStore = @ptrCast(@alignCast(sp));
                    for (store.chunks.items) |chk| {
                        if (std.mem.eql(u8, chk.id, entry_mod.path)) {
                            explicit_file_name = chk.file_name; // 명시 fileName 이면 verbatim (없으면 null)
                            if (chk.name) |n| break :blk n;
                            break;
                        }
                    }
                }
            }
            break :blk std.fs.path.stem(std.fs.path.basename(entry_mod.path));
        };

        var chunk = Chunk.init(.none, .{ .entry_point = .{
            .bit = @intCast(bit_idx),
            .module = entry.module_idx,
            .is_dynamic = entry.is_dynamic,
            .is_import_call = entry.is_import_call,
        } }, bits);
        chunk.name = name;
        chunk.explicit_file_name = explicit_file_name;
        // PR-3a-ii / #4079: lazy 빌드의 동적 import 타겟 청크는 parse 여부와 무관히 path-hash
        // 안정 이름을 쓴다 — 브라우저가 박은 `__zntc_load_chunk("<stem>-<pathhash>.js")` URL 이
        // lazy(미파싱)↔force-parse(파싱·emit) 전환에도 불변이어야 dev materialize(#4079)가 성립.
        // emit-skip 은 별개로 is_lazy_seed(미파싱)일 때만 — force-parse 면 본문이 있어 emit 한다.
        // lazy_path_hash 는 entry path 의 Wyhash(content 무관, on-demand 빌드가 같은 이름 재현).
        if (entry_mod.is_lazy_seed or (entry.is_dynamic and graph.lazy_compilation)) {
            chunk.use_lazy_path_name = true;
            chunk.lazy_path_hash = std.hash.Wyhash.hash(0, entry_mod.path);
        }
        if (entry_mod.is_lazy_seed) chunk.is_lazy_seed = true;

        // PR B-1: [dir] 토큰 치환용 raw dir. PR B-4b sub-1b: dirname(entry path)
        // 를 *graph.entry_dir 기준 relative* 로 변환해 사용자 머신 절대경로
        // 누설 차단 + sibling-prefix(`src/pages` vs `src/pages2/`) boundary
        // 가드 + Windows 백슬래시 separator 정규화. `entryRelativeDir` 가
        // 모든 invariant 캡슐화 — 회귀 가드 단위 테스트 동반.
        const abs_dir = std.fs.path.dirname(entry_mod.path) orelse "";
        const raw_dir = entryRelativeDir(graph.entry_dir, abs_dir);
        chunk.name_dir = sanitizeNameDir(allocator, raw_dir) catch null;
        // addChunk 가 OOM 으로 실패하면 chunk 가 graph 로 옮겨가지 않아 local
        // chunk 의 name_dir alloc 이 leak. errdefer 로 보호.
        // 단 addChunk 가 *성공* 하면 graph copy 와 local 이 같은 name_dir
        // pointer 를 alias — 후속 try (bits_to_chunk.put) 가 실패할 때 errdefer
        // 가 local 을 free 하고 outer chunk_graph.deinit 가 graph copy 를
        // 또 free 해 double-free 가 된다. ownership transfer 명시로 차단.
        errdefer if (chunk.name_dir) |nd| allocator.free(nd);

        const ci = try chunk_graph.addChunk(chunk);
        chunk.name_dir = null; // ownership → graph copy; errdefer no-op.
        try bits_to_chunk.put(allocator, bits, ci);
    }

    // Phase 1d: manual chunks — 실제 매칭 모듈 seed 수집 + 비어있지 않으면 Chunk 등록.
    // 매칭 없는 manual chunk 는 빈 출력 파일을 만들지 않도록 skip. 실제 BFS 전파는 Phase 2.5.
    // Resolver 결과 우선, 없으면 record substring 매칭으로 fallback.
    const manual_seeds = try allocator.alloc(std.ArrayList(ModuleIndex), manual_count);
    defer {
        for (manual_seeds) |*s| s.deinit(allocator);
        allocator.free(manual_seeds);
    }
    for (manual_seeds) |*s| s.* = .empty;

    if (manual_count > 0) {
        var it = graph.modulesIterator();
        var mi: usize = 0;
        while (it.next()) |m| : (mi += 1) {
            if (m.is_external) continue;
            // dynamic import target 은 정책상 manual 청크 제외 (#1848/#1849, 근본수정 #1850)
            if (dynamic_entry_modules.contains(@intCast(mi))) continue;
            if (rbm_modules.contains(@intCast(mi))) continue; // (#4552) RBM 은 entry 와 co-locate
            if (resolver_assignments) |ra| {
                if (ra[mi]) |slot| {
                    try manual_seeds[slot].append(allocator, ModuleIndex.fromUsize(mi));
                    continue;
                }
            }
            const rec_idx = types.ManualChunkEntry.lookup(manual_chunks, m.path) orelse continue;
            // ⚠️ `lookup` 은 **raw record index** 를 준다. 중복 이름 record(예: 두 pattern group 을
            // 같은 청크명으로)는 `ensureNameSlot` 이 한 slot 으로 dedupe 하므로 raw index 가
            // manual_count 를 넘을 수 있다 → `manual_seeds[idx]`/`effective_names[idx]` OOB. name 으로
            // deduped slot 을 되찾아 쓴다.
            const slot = name_to_slot.get(manual_chunks[rec_idx].name) orelse continue;
            // (#4553) user entry 는 pattern 매칭돼도 manual 로 안 옮긴다 — 배정 무시 + warn.
            // (resolver 경로는 위에서 처리 — ra[mi] 가 null 이라 여기까지 오는 건 record pattern.)
            if (user_entry_modules.contains(@intCast(mi))) {
                try warnManualChunksEntry(&warned_manual_entries, allocator, @intCast(mi), m.path, effective_names.items[slot]);
                continue;
            }
            try manual_seeds[slot].append(allocator, ModuleIndex.fromUsize(mi));
        }
    }

    for (effective_names.items, 0..) |name, i| {
        if (manual_seeds[i].items.len == 0) continue;
        const manual_bit: u32 = @intCast(entry_count + i);
        var bits = try BitSet.init(allocator, @intCast(total_bits));
        errdefer bits.deinit(allocator);
        bits.setBit(manual_bit);

        var chunk = Chunk.init(.none, .{ .manual = .{ .bit = manual_bit, .name = name } }, bits);
        chunk.name = name;

        const ci = try chunk_graph.addChunk(chunk);
        try bits_to_chunk.put(allocator, bits, ci);
    }

    // ── Phase 2: BFS 도달 가능성 마킹 ──
    // 각 엔트리에서 정적 import(dependencies)만 따라가며 BFS 순회.
    // dynamic import는 청크 경계이므로 따라가지 않는다.
    // 결과: splitting_info[모듈]에 도달 가능한 엔트리 비트가 설정됨.
    var queue: std.ArrayList(ModuleIndex) = .empty;
    defer queue.deinit(allocator);

    for (entries.items, 0..) |entry, bit_idx| {
        queue.clearRetainingCapacity();
        try queue.append(allocator, entry.module_idx);

        while (queue.items.len > 0) {
            const mod_idx = queue.pop() orelse break;
            const m = graph.getModule(mod_idx) orelse continue;
            const mi = @intFromEnum(mod_idx);
            // External phantom 은 chunk 에 안 들어감 — 비트 설정 / 큐 추가 모두 skip.
            if (m.is_external) continue;

            // 이미 이 비트가 설정되어 있으면 스킵 (순환 참조 방지)
            if (splitting_info[mi].hasBit(@intCast(bit_idx))) continue;
            splitting_info[mi].setBit(@intCast(bit_idx));

            // 정적 의존성 + (inline_dynamic_imports 일 때) dynamic edge 도 따라감.
            // 후자는 dynamic target 이 별도 entry 가 아니기 때문에 importer 경로로
            // 흡수시키기 위함.
            for (m.dependencies.items) |dep_idx| {
                const dep_i = @intFromEnum(dep_idx);
                if (dep_i < module_count and !splitting_info[dep_i].hasBit(@intCast(bit_idx))) {
                    try queue.append(allocator, dep_idx);
                }
            }
            if (inline_dynamic_imports) {
                for (m.dynamic_imports.items) |dep_idx| {
                    const dep_i = @intFromEnum(dep_idx);
                    if (dep_i < module_count and !splitting_info[dep_i].hasBit(@intCast(bit_idx))) {
                        try queue.append(allocator, dep_idx);
                    }
                }
            }
        }
    }

    // ── Phase 2.5: manual chunks — 매칭 모듈 + transitive dep 에 manual bit 전파 ──
    // rolldown advanced_chunks/include_dependencies_recursively 와 동일 정책:
    // 매칭 모듈만이 아니라 그 의존성까지 같은 청크로 내려야 cross-chunk 순환을 피할 수 있음.
    //
    // 다른 slot 의 seed 인 모듈은 BFS 에서 skip — 그 모듈은 자기 slot 에서 처리됨.
    // 이 가드 없으면 multi-group (vendor + ui) 에서 ui seed 의 dep (vendor seed 인 모듈)
    // 이 두 manual bit 모두 켜져 공통 청크로 빠짐.
    if (manual_count > 0) {
        var module_primary_slot = try allocator.alloc(?usize, module_count);
        defer allocator.free(module_primary_slot);
        @memset(module_primary_slot, null);
        for (0..manual_count) |i| {
            for (manual_seeds[i].items) |seed| {
                const si = @intFromEnum(seed);
                if (module_primary_slot[si] == null) module_primary_slot[si] = i;
            }
        }

        for (0..manual_count) |i| {
            if (manual_seeds[i].items.len == 0) continue;
            const manual_bit: u32 = @intCast(entry_count + i);
            queue.clearRetainingCapacity();
            for (manual_seeds[i].items) |seed| try queue.append(allocator, seed);

            while (queue.items.len > 0) {
                const mod_idx = queue.pop() orelse break;
                const m = graph.getModule(mod_idx) orelse continue;
                const mi = @intFromEnum(mod_idx);
                if (m.is_external) continue;
                if (splitting_info[mi].hasBit(manual_bit)) continue;
                // (#4553) user entry 는 manual bit 를 받지 않는다 — seed 로 안 걸러졌어도(vendor seed 의
                // transitive dep 로 도달) 여기서 막아 entry 가 manual 청크로 빨려가지 않게 한다. entry 를
                // 통해 dep 로 전파도 중단(entry 의 exclusive dep 는 entry 청크에 남음).
                if (user_entry_modules.contains(@intCast(mi))) continue;
                if (rbm_modules.contains(@intCast(mi))) continue; // (#4552) RBM 은 manual bit 안 받음
                // 다른 slot 의 seed 면 skip — 그쪽에서 처리됨
                if (module_primary_slot[mi]) |other| {
                    if (other != i) continue;
                }
                splitting_info[mi].setBit(manual_bit);
                for (m.dependencies.items) |dep_idx| {
                    const dep_i = @intFromEnum(dep_idx);
                    if (dep_i < module_count and !splitting_info[dep_i].hasBit(manual_bit)) {
                        try queue.append(allocator, dep_idx);
                    }
                }
                if (inline_dynamic_imports) {
                    for (m.dynamic_imports.items) |dep_idx| {
                        const dep_i = @intFromEnum(dep_idx);
                        if (dep_i < module_count and !splitting_info[dep_i].hasBit(manual_bit)) {
                            try queue.append(allocator, dep_idx);
                        }
                    }
                }
            }
        }

        // manual bit 가 켜진 모듈은 entry bit 를 모두 제거 — Phase 3 BitSet lookup 이
        // `{entry=n, manual=1}` 이 아닌 정확히 `{manual=1}` 패턴으로 manual 청크에 귀속.
        // dynamic import target 도 여기서 async chunk 에서 빠져나와 manual 청크로 합류.
        for (splitting_info) |*bs| {
            if (!bs.hasAnyBitInRange(@intCast(entry_count), @intCast(manual_count))) continue;
            bs.clearBitRange(0, @intCast(entry_count));
        }
    }

    // #3664 (2): implicitlyLoadedAfterOneOf bit-collapse. emit chunk E 가 "parent 중 하나 로드 후
    // 로드"됨이 plugin 보장이면, E 와 parent 가 공유하는 모듈에서 E 비트를 지워 parent 의 청크
    // 패턴으로 흡수한다 → 별도 공통 청크(파일) 1개를 줄인다(Rollup #3606 의 chunk-shape 최적화).
    // ※ byte 중복은 ZNTC BitSet 모델상 원래 없음(공유 모듈은 항상 단일 공통 청크) — 이건 파일 수
    //   감소이지 중복 제거가 아니다.
    // soundness: parent 는 실제 entry 청크(bit 보유)여야 흡수가 안전(E 보다 먼저 로드 보장). entry
    // 가 아니면 보수적으로 skip(정확성 유지, 최적화만 포기). E 의 facade(자기 모듈)는 e_bit 유지.
    {
        var ei: usize = 0;
        while (ei < module_count) : (ei += 1) {
            const em = graph.getModule(ModuleIndex.fromUsize(ei)) orelse continue;
            if (!em.is_emitted_chunk_entry) continue;
            const parents = em.implicitly_loaded_after_one_of.items;
            // soundness — "one-of" 는 parent 중 *하나만* 로드 보장한다. parent 가 여럿이면 E 가 어느
            // parent 뒤에 로드될지 알 수 없어, 한 parent 와만 공유하는 모듈을 그 parent chunk 로
            // 합치면 다른 경로(다른 parent 뒤)에서 미로드 → 런타임 깨짐. 올바른 흡수는 "모든 parent
            // 경로에서 보장되는 모듈"(intersection)뿐인데, 단일 parent 면 그게 곧 그 parent 와의
            // 공유다. 따라서 **단일 parent 일 때만** 흡수하고, 다중 parent 는 보수적으로 skip한다
            // (별도 공통 청크 유지 — 정확성 보존, 파일수 최적화만 포기). (Rollup #3606 intersection 의미)
            if (parents.len != 1) continue;
            const e_bit = entryBit(entries.items, ModuleIndex.fromUsize(ei)) orelse continue;
            const p_bit = entryBit(entries.items, parents[0]) orelse continue; // parent 가 entry 청크 아니면 skip
            if (p_bit == e_bit) continue;
            // parent 는 eager(non-dynamic user entry)여야 E 보다 먼저 로드됨이 보장된다. lazy(dynamic
            // import / 다른 emit chunk) parent 는 자기도 로드 안 될 수 있어 흡수가 unsound → skip.
            if (entries.items[p_bit].is_dynamic) continue;
            for (splitting_info, 0..) |*bs, mi| {
                if (mi == ei) continue; // E facade 모듈은 e_bit 유지(E 청크 보존)
                if (!bs.hasBit(e_bit)) continue;
                if (!bs.hasBit(p_bit)) continue;
                bs.clearBit(e_bit); // 단일 eager parent 와 공유 → parent 청크 패턴으로 흡수
            }
        }
    }

    // PR-3b-ii (RFC §6.3): lazy(dev on-demand) 면 shared splitting off. static(비-dynamic)
    // entry 비트가 있는 모듈에서 dynamic entry 비트를 제거 → {E,D}→{E} collapse. 그 모듈은
    // 공통 청크가 아니라 entry 청크에 남고, 동적 청크는 그것을 __zntc_require 로 단방향 조회
    // (entry 청크가 lazy 시 hoisted export 를 local name 으로 전부 노출 — emitter
    // emitLazyEntryExportAll). 효과: 동적 seed 를 나중에 force-parse 해도 entry 청크가
    // 불변(결정론) → on-demand 단일청크가 초기 entry 와 정합. entry 에 없는 동적 전용 deps 는
    // 그대로 동적 청크에 남는다(on-demand 는 seed 1개만 parse 라 dynamic-dynamic 공유 미발생).
    if (graph.lazy_compilation) {
        for (splitting_info) |*bs| {
            var has_static = false;
            for (entries.items, 0..) |e, b| {
                if (!e.is_dynamic and bs.hasBit(@intCast(b))) {
                    has_static = true;
                    break;
                }
            }
            if (!has_static) continue;
            for (entries.items, 0..) |e, b| {
                if (e.is_dynamic) bs.clearBit(@intCast(b));
            }
        }
    }

    // ── Phase 3: 모듈을 청크에 할당 ──
    // exec_index 순으로 처리하여 청크 내 모듈 순서(=ESM 실행 순서)를 보장.
    // 동일한 BitSet을 가진 모듈들은 같은 청크에 묶인다.
    // 엔트리 청크의 BitSet과 일치하지 않는 새로운 BitSet 패턴이 나오면
    // 공통 청크(common chunk)를 새로 생성한다.
    const sorted_indices = try allocator.alloc(usize, module_count);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;
    const SortCtx = struct {
        graph: *const ModuleGraph,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ma = ctx.graph.getModule(ModuleIndex.fromUsize(a)).?;
            const mb = ctx.graph.getModule(ModuleIndex.fromUsize(b)).?;
            return ma.exec_index < mb.exec_index;
        }
    };
    std.mem.sort(usize, sorted_indices, SortCtx{ .graph = graph }, SortCtx.lessThan);

    for (sorted_indices) |mi| {
        // tree-shaking: 미포함 모듈 스킵
        if (shaker) |s| {
            if (!s.isIncluded(@intCast(mi))) continue;
        }

        const m = graph.getModule(ModuleIndex.fromUsize(mi)) orelse continue;
        // JS 모듈만 청크에 할당 (JSON, CSS 등은 별도 처리)
        if (!m.module_type.isJavaScriptLike()) continue;

        // 비트가 비어있으면 어떤 엔트리에서도 도달 불가 → 스킵
        if (splitting_info[mi].isEmpty()) continue;

        // BitSet → ChunkIndex O(1) lookup (esbuild/rolldown 패턴)
        const chunk_idx = if (bits_to_chunk.get(splitting_info[mi])) |ci| ci else blk: {
            // 새로운 BitSet 패턴 → 공통 청크 생성
            var bits = try splitting_info[mi].clone(allocator);
            errdefer bits.deinit(allocator);
            const new_chunk = Chunk.init(.none, .common, bits);
            const ci = try chunk_graph.addChunk(new_chunk);
            try bits_to_chunk.put(allocator, bits, ci);
            break :blk ci;
        };

        chunk_graph.assignModuleToChunk(
            @enumFromInt(@as(u32, @intCast(mi))),
            chunk_idx,
        );
        try chunk_graph.getChunkMut(chunk_idx).addModule(
            allocator,
            @enumFromInt(@as(u32, @intCast(mi))),
        );
    }

    // 엔트리 모듈은 반드시 자신의 엔트리 청크에 할당되어야 함.
    // Phase 3에서 공통 청크에 배정되었을 수 있으므로, 강제로 엔트리 청크로 이동.
    for (entries.items, 0..) |entry, ci| {
        const chunk_idx: ChunkIndex = @enumFromInt(@as(u32, @intCast(ci)));
        const current = chunk_graph.getModuleChunk(entry.module_idx);
        if (current.isNone()) {
            // 아직 미할당 → 엔트리 청크에 할당
            chunk_graph.assignModuleToChunk(entry.module_idx, chunk_idx);
            try chunk_graph.getChunkMut(chunk_idx).addModule(allocator, entry.module_idx);
        } else if (current != chunk_idx) {
            // manual chunk 에 있으면 그대로 유지. (#4553) **user entry** 는 위 seed/BFS 에서 이미
            // manual 제외라 여기 걸리지 않는다 — 이 예외가 지금 보호하는 건 **dynamic import 대상**이
            // manual seed 의 static dep 로 Phase 2.5 전파돼 manual 청크에 흡수된 경우다(seed 는 dynamic
            // 을 빼지만 전파는 안 뺌 — 기존 동작). 그걸 자기 dynamic 청크로 도로 빼내면 manual 청크의
            // static import 가 cross-chunk 로 바뀌며 미노출 심볼 ReferenceError.
            if (chunk_graph.getChunk(current).kind == .manual) continue;
            // 공통 청크에 잘못 배정됨 → 이전 청크에서 제거 후 엔트리 청크로 이동
            const old_chunk = chunk_graph.getChunkMut(current);
            removeModuleFromList(&old_chunk.modules, entry.module_idx);
            chunk_graph.assignModuleToChunk(entry.module_idx, chunk_idx);
            try chunk_graph.getChunkMut(chunk_idx).addModule(allocator, entry.module_idx);
        }
    }

    return chunk_graph;
}

/// preserve-modules 모드: 모듈 1개 = 청크 1개.
/// 라이브러리 빌드에서 원본 디렉토리 구조를 유지하기 위해 사용한다.
/// 각 모듈이 개별 출력 파일이 되며, cross-chunk import로 서로 연결된다.
pub fn generatePreserveModulesChunks(
    allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    entry_points: []const []const u8,
    shaker: ?*const TreeShaker,
) !ChunkGraph {
    const module_count = graph.moduleCount();
    var chunk_graph = try ChunkGraph.init(allocator, module_count);
    errdefer chunk_graph.deinit();
    // (#4494) cross-chunk CJS-interop 배선 금지 표식 — 이 모드는 전역명/xchunk export 를 안 쓴다.
    chunk_graph.preserve_modules = true;

    // 엔트리 모듈 인덱스를 미리 수집 (entry_point 청크 판별용)
    var entry_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer entry_set.deinit(allocator);
    {
        var it = graph.modulesIterator();
        var i: usize = 0;
        while (it.next()) |m| : (i += 1) {
            for (entry_points) |ep| {
                if (std.mem.eql(u8, m.path, ep)) {
                    try entry_set.put(allocator, @intCast(i), {});
                    break;
                }
            }
        }
    }

    // exec_index 순으로 정렬하여 결정론적 청크 순서 보장
    const sorted_indices = try allocator.alloc(usize, module_count);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*idx, i| idx.* = i;
    const SortCtx = struct {
        graph: *const ModuleGraph,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            const ma = ctx.graph.getModule(ModuleIndex.fromUsize(a)).?;
            const mb = ctx.graph.getModule(ModuleIndex.fromUsize(b)).?;
            return ma.exec_index < mb.exec_index;
        }
    };
    std.mem.sort(usize, sorted_indices, SortCtx{ .graph = graph }, SortCtx.lessThan);

    for (sorted_indices) |mi| {
        // tree-shaking: 미포함 모듈 스킵
        if (shaker) |s| {
            if (!s.isIncluded(@intCast(mi))) continue;
        }

        const m = graph.getModule(ModuleIndex.fromUsize(mi)) orelse continue;
        // JS 모듈만 청크에 할당
        if (!m.module_type.isJavaScriptLike()) continue;

        // 모듈 1개 = 청크 1개
        // BitSet은 비어있는 상태로 생성 (preserve-modules에서는 reachability 불필요)
        var bits = try BitSet.init(allocator, 1);
        errdefer bits.deinit(allocator);

        const mod_idx: ModuleIndex = @enumFromInt(@as(u32, @intCast(mi)));
        const name = std.fs.path.stem(std.fs.path.basename(m.path));

        // 엔트리 모듈이면 bit 설정 (출력 시 엔트리 청크로 인식)
        if (entry_set.contains(@intCast(mi))) bits.setBit(0);

        var chunk = Chunk.init(.none, .{ .entry_point = .{
            .bit = 0,
            .module = mod_idx,
            .is_dynamic = false,
        } }, bits);
        chunk.name = name;

        chunk.exec_order = m.exec_index;
        // preserve-modules에서 chunk.rel_dir을 설정하여 디렉토리 구조 유지.
        // helper virtual module (`\x00zntc:runtime/...`) 의 NULL byte 가 fs path / cross-chunk
        // import specifier 로 새지 않도록 sanitize. caller 가 owner 인 m.path 와 다른 메모리 —
        // graph allocator 로 alloc (chunk_graph 와 동일 lifetime).
        const helper_modules = @import("../runtime_helper_modules.zig");
        chunk.rel_dir = if (helper_modules.isVirtualId(m.path))
            helper_modules.sanitizeId(allocator, m.path) catch m.path
        else
            m.path;

        // PR B-1: [dir] 토큰 치환용 raw dir. preserve-modules 의 `rel_dir` 은
        // 모듈 절대경로+파일명+ext 의 misnomer 라 [dir] 토큰에 직접 노출하면
        // 출력이 깨진다. 안전한 신규 필드 `name_dir` 에는 *dirname* 만 sanitize
        // 거쳐 저장. PR B-4b sub-1b: entry_dir 기준 relative + boundary 가드 +
        // 백슬래시 정규화 (entry 분기와 동일 helper).
        const abs_dir_pm = std.fs.path.dirname(m.path) orelse "";
        const raw_dir_pm = entryRelativeDir(graph.entry_dir, abs_dir_pm);
        chunk.name_dir = sanitizeNameDir(allocator, raw_dir_pm) catch null;
        // addChunk OOM 시 leak 방지(entry chunk 분기와 대칭). ownership transfer
        // 후 local pointer 를 null 로 비워 후속 try 실패 시 double-free 차단.
        errdefer if (chunk.name_dir) |nd| allocator.free(nd);

        const ci = try chunk_graph.addChunk(chunk);
        chunk.name_dir = null; // ownership → graph copy; errdefer no-op.
        chunk_graph.assignModuleToChunk(mod_idx, ci);
        try chunk_graph.getChunkMut(ci).addModule(allocator, mod_idx);
    }

    return chunk_graph;
}

/// ArrayListUnmanaged에서 특정 ModuleIndex를 제거한다 (순서 유지).
fn removeModuleFromList(list: *std.ArrayListUnmanaged(ModuleIndex), target: ModuleIndex) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == target) {
            _ = list.orderedRemove(i);
            return; // 중복 없으므로 첫 번째만 제거
        }
        i += 1;
    }
}

// ============================================================
// computeCrossChunkLinks — 크로스 청크 의존성 계산
// ============================================================

/// (#4495) 이 (canonical 모듈, export 이름) 심볼의 **선언이 emit 되지 않는지** 판정.
///
/// `exports_to`/`imports_from` 은 스캐너 시점 메타데이터(`import_bindings` /
/// `export_bindings`)만 보고 만들어진다. 그런데 그 사이에 tree-shaker 가
///   - 크로스-모듈 const-inline: `export const extra = 1` 이 소비자 AST 에 리터럴 `1`
///     로 박히고 나면 참조가 0 → 선언 statement 가 DCE
///   - 단순 미사용 named import: 참조가 애초에 0 → 선언 statement 가 DCE
/// 로 **선언을 지운다**. 그런데도 심볼이 목록에 남으면 provider 청크가 선언 없이
/// `export { extra };` 를 내보내고, node 는 모듈 로드 자체를 거부한다
/// (`SyntaxError: Export 'extra' is not defined in module`). 소비자 청크 쪽
/// `import { extra }` 도 같은 목록에서 나오므로 두 목록을 한 지점에서 함께 막는다.
///
/// **판정 실패 방향은 항상 "유지"(false)**. emitter 가 statement DCE 를 *건너뛰는*
/// 모듈은 선언이 그대로 남으므로 export 를 지우면 안 된다:
///   - tree-shaker 비활성(dev / `--no-tree-shaking`) → `tree_shaker_active == false`
///   - 래핑 모듈(`__esm`/`__commonJS`) → emitter 의 statement-shake 게이트가 제외
///   - `export * from` 소스 → emitter 가 `all_used` 로 DCE 자체를 끈다
///   - 청크 entry 모듈 + `minify_syntax=false` → 같은 게이트가 statement-shake 를 끈다
/// canonical 이 `.local` 선언이 아닐 때(re-export/star/합성 ns 변수/CJS 런타임 멤버)도
/// 로컬 선언 유무로 판정할 수 없으므로 유지한다.
///
/// 순수 판정부 — Linker/ChunkGraph 조회와 분리해 유닛 테스트 대상으로 노출한다.
/// `is_chunk_entry` / `minify_syntax` / `is_star_target` 은 emitter 의
/// statement-shake 게이트를 그대로 옮긴 입력이다.
pub fn crossChunkExportShakenDecision(
    m: *const Module,
    export_name: []const u8,
    is_chunk_entry: bool,
    minify_syntax: bool,
    is_star_target: bool,
) bool {
    if (!m.tree_shaker_active) return false;
    if (m.wrap_kind != .none) return false;
    if (is_star_target) return false;
    if (is_chunk_entry and !minify_syntax) return false;
    const eb = m.findExportBinding(export_name) orelse return false;
    if (eb.kind != .local) return false;
    return !m.isLocalBindingAlive(m.exportBindingLocalName(eb.*));
}

fn crossChunkExportIsShaken(
    chunk_graph: *const ChunkGraph,
    lnk: *const Linker,
    src_chunk_idx: ChunkIndex,
    canonical_module: u32,
    export_name: []const u8,
) bool {
    const m = lnk.getModule(canonical_module) orelse return false;
    const is_star_target = if (lnk.tree_shaker) |s| s.isReExportStarTarget(canonical_module) else false;
    const src_ci = @intFromEnum(src_chunk_idx);
    const is_chunk_entry = blk: {
        if (src_ci >= chunk_graph.chunks.items.len) break :blk true; // 알 수 없으면 보수적(=유지 쪽)
        break :blk switch (chunk_graph.chunks.items[src_ci].kind) {
            .entry_point => |info| @intFromEnum(info.module) == canonical_module,
            .common, .manual => false,
        };
    };
    return crossChunkExportShakenDecision(
        m,
        export_name,
        is_chunk_entry,
        lnk.graph.transform_options_base.minify_syntax,
        is_star_target,
    );
}

/// 각 청크의 크로스 청크 의존성을 계산한다.
///
/// 청크 A의 모듈이 청크 B의 모듈을 정적 import하면 A.cross_chunk_imports에 B가 추가된다.
/// 청크 A의 모듈이 청크 B의 모듈을 동적 import하면 A.cross_chunk_dynamic_imports에 B가 추가된다.
/// 같은 청크 내의 의존성은 무시하고, 중복 청크 인덱스도 제거한다.
///
/// linker가 있으면 심볼 수준 크로스 청크 바인딩도 추적한다:
///   - chunk.imports_from[source_chunk] = 해당 청크에서 가져올 심볼 이름 목록
///   - source_chunk.exports_to에 해당 심볼 이름 추가
/// linker가 null이면 청크 수준 의존성만 계산 (side-effect import).
///
/// 이 함수는 generateChunks 이후에 호출한다.
/// cross-chunk 심볼(src 청크 + export 이름)을 chunk.imports_from +
/// src.exports_to + chunk.cross_chunk_imports 에 등록. import_bindings 경로와
/// re-export 경로가 **동일 로직**을 쓰도록 단일화 — 두 경로 divergence 가 곧
/// 이 버그였다(#3321 후속). `seen_static` 로 cross_chunk_imports dedup.
/// imports_from 중복 검사는 O(n) 선형(소스별 심볼 수 작음, import_bindings
/// 기존 패턴과 동일 — 프로파일 시 set 전환은 양 경로 공동 과제).
fn addCrossChunkSymbol(
    allocator: std.mem.Allocator,
    chunk_graph: *ChunkGraph,
    chunk: *Chunk,
    lnk: *const Linker,
    seen_static: *std.AutoHashMapUnmanaged(u32, void),
    src_chunk_idx: ChunkIndex,
    export_name: []const u8,
    /// `export_name` 의 canonical 정의 모듈 인덱스. 예약어 export 키(`default`)일
    /// 때 emitter 가 소비자 바인딩명을 `resolveToLocalName` 으로 해석하는 데 쓴다.
    canonical_module: u32,
) !void {
    const src_ci = @intFromEnum(src_chunk_idx);

    // (#4495) 선언이 DCE 된 심볼은 어떤 목록에도 올리지 않는다 — provider 의
    // `export {}` 도, 소비자의 `import {}` 도 여기 한 곳에서만 나온다.
    if (crossChunkExportIsShaken(chunk_graph, lnk, src_chunk_idx, canonical_module, export_name)) return;

    // 심볼의 canonical 청크가 *직접 의존*이 아닐 수 있다(re-export 체인
    // importer→page→inner: importer 는 inner 를 직접 의존 안 함). emitter 는
    // cross_chunk_imports 를 순회하며 imports_from 을 조회하므로, canonical
    // 청크가 거기 없으면 named import 누락 → 심볼 미바인딩(ReferenceError).
    const gop = try seen_static.getOrPut(allocator, src_ci);
    if (!gop.found_existing)
        try chunk.cross_chunk_imports.append(allocator, src_chunk_idx);

    const ifgop = try chunk.imports_from.getOrPut(allocator, src_ci);
    if (!ifgop.found_existing) ifgop.value_ptr.* = .empty;
    // dedup 은 (export 이름, canonical 모듈) 둘 다로 — 서로 다른 모듈이 *같은* export
    // 이름(두 `v`)을 내고 한 소비자가 둘 다 가져오면 이름만으론 하나로 붕괴(#B). canonical
    // 모듈이 다르면 별개 심볼이라 둘 다 유지(전역 네이밍이 `v`/`v$1` 로 구분, #4101).
    for (ifgop.value_ptr.items) |existing| {
        if (std.mem.eql(u8, existing.name, export_name) and existing.canonical_module == canonical_module) break;
    } else {
        try ifgop.value_ptr.append(allocator, .{ .name = export_name, .canonical_module = canonical_module });
    }

    try chunk_graph.chunks.items[src_ci].exports_to.put(allocator, export_name, {});
}

/// re-export 이름의 canonical 을 resolveExportChain 으로 추적해, canonical 이
/// 다른 청크면 cross-chunk named 바인딩을 등록. named(`export {x} from`)·
/// star(`export *`) 루프 공용 — 두 경로가 같은 해석을 쓰도록 단일화(#3321
/// 후속; #3350 의 addCrossChunkSymbol 추출 규율 연장).
fn linkReExportName(
    allocator: std.mem.Allocator,
    chunk_graph: *ChunkGraph,
    chunk: *Chunk,
    seen_static: *std.AutoHashMapUnmanaged(u32, void),
    lnk: *const Linker,
    mod_idx: ModuleIndex,
    name: []const u8,
    module_count: usize,
) !void {
    const canon = lnk.resolveExportChain(mod_idx, name, 0) orelse return;
    if (@intFromEnum(canon.module_index) >= module_count) return;
    const src_chunk_idx = chunk_graph.getModuleChunk(canon.module_index);
    if (src_chunk_idx.isNone()) return;
    if (src_chunk_idx == chunk.index) return; // 같은 청크 → 스킵
    try addCrossChunkSymbol(allocator, chunk_graph, chunk, lnk, seen_static, src_chunk_idx, canon.export_name, @intFromEnum(canon.module_index));
}

/// `mod_idx` 의 `export_name` 이 namespace re-export 인지 판정하고, 맞으면
/// namespace 대상(소스) 모듈을 반환. 두 형태 모두 인식:
///  - `export * as X from "m"` (re_export_namespace)
///  - `import * as X from "m"; export { X }` (namespace import 후 named export)
///  - `export { X } from "m"` 가 m 에서 위 둘 중 하나면 체인을 따라간다
///    (중첩 re-export, bounded depth).
/// namespace 가 아니면 null.
pub fn nsReExportTarget(
    graph: *const ModuleGraph,
    mod_idx: ModuleIndex,
    export_name: []const u8,
) ?ModuleIndex {
    return nsReExportTargetDepth(graph, mod_idx, export_name, 0);
}

/// namespace re-export 체인(`export {X} from`) 추적 최대 깊이. linker
/// resolveExportChain/collectExportsRecursive 의 max_chain_depth(100) 와
/// 동일 성격 — 실세계 barrel 깊이를 넘는 cycle 방어용 상한.
const ns_chain_max_depth = 100;

fn nsReExportTargetDepth(
    graph: *const ModuleGraph,
    mod_idx: ModuleIndex,
    export_name: []const u8,
    depth: u8,
) ?ModuleIndex {
    if (depth > ns_chain_max_depth) return null;
    const m = graph.getModule(mod_idx) orelse return null;
    for (m.export_bindings) |eb| {
        if (!std.mem.eql(u8, eb.exported_name, export_name)) continue;
        if (eb.kind == .re_export_namespace) {
            if (eb.import_record_index) |rec| {
                if (rec < m.import_records.len) {
                    const src = m.import_records[rec].resolved;
                    if (!src.isNone()) return src;
                }
            }
            return null;
        }
        // 중첩 re-export: `export { X } from "m"` 가 m 에서 다시 namespace
        // re-export 면 체인을 따라간다. m 측 이름은 eb.local_name.
        if (eb.kind == .re_export) {
            if (eb.import_record_index) |rec| {
                if (rec < m.import_records.len) {
                    const src = m.import_records[rec].resolved;
                    if (!src.isNone())
                        return nsReExportTargetDepth(graph, src, m.exportBindingLocalName(eb), depth + 1);
                }
            }
            return null;
        }
        // namespace import 를 그대로 named export: local 이 `import * as` 바인딩.
        const local = m.exportBindingLocalName(eb);
        for (m.import_bindings) |ib| {
            if (ib.kind != .namespace) continue;
            if (!std.mem.eql(u8, ib.local_name, local)) continue;
            if (ib.import_record_index < m.import_records.len) {
                const src = m.import_records[ib.import_record_index].resolved;
                if (!src.isNone()) return src;
            }
            return null;
        }
        return null;
    }
    return null;
}

/// `src_mod` 의 effective export(nested export*/diamond/체인 평탄화)를 전부
/// 열거해 canonical 이 다른 청크면 named cross-chunk 바인딩+재노출. `export *`
/// (star) 와 namespace re-export 가 공유 — 둘 다 소스 전체 export 를 importer
/// 청크에 노출해야 미바인딩 link error 를 막는다.
fn fanOutModuleExports(
    allocator: std.mem.Allocator,
    chunk_graph: *ChunkGraph,
    chunk: *Chunk,
    seen_static: *std.AutoHashMapUnmanaged(u32, void),
    lnk: *const Linker,
    src_mod: ModuleIndex,
    module_count: usize,
) !void {
    // collectExportsRecursive 는 lnk.allocator 로 append. OOM 은 named 루프와
    // 일관되게 전파(silent partial-link 방지).
    var exps: std.ArrayList(Linker.NsExportPair) = .empty;
    var seen_e: std.StringHashMapUnmanaged(void) = .empty;
    var visited_e: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer {
        for (exps.items) |e| if (e.owned) lnk.allocator.free(e.local);
        exps.deinit(lnk.allocator);
        seen_e.deinit(lnk.allocator);
        visited_e.deinit(lnk.allocator);
    }
    try lnk.collectExportsRecursive(&exps, &seen_e, &visited_e, src_mod, 0);
    for (exps.items) |e|
        try linkReExportName(allocator, chunk_graph, chunk, seen_static, lnk, src_mod, e.exported, module_count);
}

/// `linkNamespaceCrossChunk` 의 청크-단위 dedup 래퍼. 3경로(consumer
/// import_binding/import_record, re-exporter export_binding)에서 같은 target
/// 재발견 시 DFS·할당 반복을 막는다.
fn linkNamespaceCrossChunkOnce(
    allocator: std.mem.Allocator,
    chunk_graph: *ChunkGraph,
    chunk: *Chunk,
    seen_static: *std.AutoHashMapUnmanaged(u32, void),
    seen_ns_target: *std.AutoHashMapUnmanaged(u32, void),
    lnk: *const Linker,
    target: ModuleIndex,
    module_count: usize,
) !void {
    const gop = try seen_ns_target.getOrPut(allocator, @intFromEnum(target));
    if (gop.found_existing) return;
    try linkNamespaceCrossChunk(allocator, chunk_graph, chunk, seen_static, lnk, target, module_count);
}

/// namespace re-export 대상 `target` 을 cross-chunk 로 배선. 정의자 청크가
/// 다르면 합성 ns 객체 변수 + target 의 effective export(정적 멤버 elision
/// 로컬)를 정의자 청크 export → `chunk` import 1급 심볼로 등록 — 값/동적
/// re-import/정적 멤버 경로를 한 번에 커버 (#3321 후속).
fn linkNamespaceCrossChunk(
    allocator: std.mem.Allocator,
    chunk_graph: *ChunkGraph,
    chunk: *Chunk,
    seen_static: *std.AutoHashMapUnmanaged(u32, void),
    lnk: *const Linker,
    target: ModuleIndex,
    module_count: usize,
) !void {
    const tgt_chunk = chunk_graph.getModuleChunk(target);
    if (tgt_chunk.isNone()) return;
    if (tgt_chunk == chunk.index) return; // 같은 청크 → 배선 불필요

    // cross-chunk 확정 — registerNamespaceRewrites 가 shared 경로를 쓰도록
    // 마킹. same-chunk(여기 도달 안 함)는 비-shared self-contained 경로 (#3367).
    try @constCast(lnk).markNsCrossChunk(target);

    // computeCrossChunkLinks 가 namespace 메타데이터보다 먼저 도는 timing
    // seam — ensureSharedNsVar 가 선제 materialize. 상세는 그 doc 참조.
    const ns_var = try lnk.ensureSharedNsVar(target);
    // ns_var 는 합성 namespace 변수명(예약어 아님) → canonical_module 미사용.
    try addCrossChunkSymbol(allocator, chunk_graph, chunk, lnk, seen_static, tgt_chunk, ns_var, @intFromEnum(target));
    try fanOutModuleExports(allocator, chunk_graph, chunk, seen_static, lnk, target, module_count);
}

/// RFC #3940 / 이슈 #4101 — cross-chunk 심볼에 **전역 일관 이름**을 배정한다.
/// 모든 청크의 imports_from(`CrossChunkSym`=canonical_module+export_name)을 enumerate 해
/// `(canonical_module, export_name)` 집합을 만들고, **occupied(per-chunk rename 입력)와 무관
/// 하게** 전역 deconflict 한다 — 이 self-contained 성질이 occupied↔이름 순환을 끊는 핵심.
/// 결과는 `linker.cross_chunk_global_names` 에 owned 로 저장(provider/consumer 단일 출처).
///
/// **Inc-1(본 변경): 채우기만 — read 비활성**. metadata/emit/per-chunk-rename 은 아직 이 맵을
/// 안 본다 → 동작 변경 0. 후속 increment 가 ① per-chunk rename 이 전역 이름 reserve+사용,
/// ② metadata import 바인딩 read 로 wire 한다(그때 #B test.todo flip).
/// `computeCrossChunkLinks` 직후(imports_from 확정 후)에 호출.
pub fn computeCrossChunkGlobalNames(
    allocator: std.mem.Allocator,
    chunk_graph: *const ChunkGraph,
    lnk: *Linker,
) !void {
    lnk.clearCrossChunkGlobalNames();

    // 1. cross-chunk 심볼 enumerate + (mod, name) dedup.
    const Sym = struct { mod: u32, name: []const u8 };
    var syms: std.ArrayListUnmanaged(Sym) = .empty;
    defer syms.deinit(allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var kit = seen.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        seen.deinit(allocator);
    }
    for (chunk_graph.chunks.items) |*chunk| {
        var it = chunk.imports_from.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |sym| {
                const key = try std.fmt.allocPrint(allocator, "{d}\x00{s}", .{ sym.canonical_module, sym.name });
                const gop = try seen.getOrPut(allocator, key);
                if (gop.found_existing) {
                    allocator.free(key);
                    continue;
                }
                try syms.append(allocator, .{ .mod = sym.canonical_module, .name = sym.name });
            }
        }
    }

    // 2. 결정론적 정렬 (mod, name) — 같은 입력 → 같은 전역 이름.
    const SymSort = struct {
        fn lt(_: void, a: Sym, b: Sym) bool {
            if (a.mod != b.mod) return a.mod < b.mod;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    };
    std.mem.sort(Sym, syms.items, {}, SymSort.lt);

    // 3. 전역 deconflict — preferred(원본 local 명)로 시도, 충돌/예약이면 `$N`.
    var used: std.StringHashMapUnmanaged(void) = .empty;
    defer used.deinit(allocator);
    for (syms.items) |s| {
        // (#4532 증상1) preserve-modules 는 전역명을 **ESM-wrap owner 로 한정**한다.
        // preserve-modules 는 모든 모듈이 자기 청크라 모든 import 가 cross-chunk 로 잡히는데:
        //  - non-wrap ESM provider(.none): codegen 이 소스 `export { tag }` 를 자연명 재방출 →
        //    전역명 붙이면 consumer 만 `import { tag$1 }`, provider 는 `export { tag }` 로 어긋남.
        //  - CJS owner(.cjs): re-export barrel 등 소비 경로의 전역명 배선(`foo$legacy`)이 아직
        //    없어(증상3 영역, 후속) 켜면 barrel 이 미정의 이름을 export → SyntaxError.
        // ESM-wrap owner(.esm)만 provider emit 이 `pm_wrapped_esm_provider` 로 전역명(`local as
        // global`)을 노출하므로 consumer/​provider 가 합의된다 → 동명 심볼 붕괴(증상1)를 여기서 해소.
        // (splitting 은 non-wrap ESM·CJS 도 emit 측이 브리지하므로 전부 네이밍 → preserve 한정 skip.)
        if (chunk_graph.preserve_modules) {
            const owner = lnk.getModule(s.mod);
            if (owner == null or owner.?.wrap_kind != .esm) continue;
        }
        // (#4494) **CJS owner 의 공개명은 원문 멤버명을 쓰면 안 된다.** CJS 멤버는 provider 청크
        // top-level 에 `var <공개명> = require_X().<멤버>;` 로 *새 식별자를 만들어* 노출된다
        // (#4120 materialize). 멤버명을 그대로 쓰면:
        //   - `exports.Buffer` 같은 멤버가 청크 안의 진짜 전역(`Buffer`)을 가려 다른 모듈이 깨지고,
        //   - entry 모듈의 동명 export 와 충돌하며(중복 export / 잘못된 바인딩),
        //   - 동명 청크 로컬(`const named`)과 `var`↔`const` 재선언 SyntaxError 가 난다.
        // 공개명은 provider/consumer 가 합의만 하면 되는 **내부 이름**이라 자유롭게 지어도 된다 →
        // `<멤버>$<모듈 태그>`(`default$cjslib` / `named$second`) 합성명으로 충돌 가능성을 원천 차단.
        // 모듈 태그는 래퍼 이름(`require_x`, #4475 가 basename 충돌까지 deconflict)에서 `require_`
        // 접두사를 뗀 것 — 결정론적이고 모듈마다 유니크하다. deconflict 는 안전망으로만 동작.
        //  - 멤버명을 **앞**에 두는 건 #4096 계약("예약어를 bare 로 쓰지 않는다" — `default` 뒤에 `$…`
        //    가 붙어 유효 식별자가 된다) 유지를 위함.
        //  - `require_` 접두사를 **떼는** 건 dev/lazy 계약(정의자 청크에 갇힌 `require_x` 를 lazy 청크가
        //    렉시컬 참조하면 안 된다) 과 텍스트로도 헷갈리지 않게 하기 위함.
        // (ESM owner 는 진짜 로컬을 `local as 공개명` 으로 브리지하므로 기존대로 로컬명 우선 — 바이트 동일.)
        //
        // (#4510) 공개명의 **앞부분** 은 항상 유효 식별자여야 한다:
        //  - namespace 키("*", CJS_NS_EXPORT_NAME)는 `ns` 로 대체 → `ns$single`.
        //  - 비-식별자 멤버명(`'foo-bar'`)은 식별자 문자만 남기고 sanitize → `foo_bar$x`.
        //    (키는 여전히 원문 멤버명이라 materialize 는 `require_x()["foo-bar"]` 로 정확히 나온다.)
        var synth: ?[]const u8 = null;
        defer if (synth) |b| allocator.free(b);
        const preferred = blk: {
            const om = lnk.getModule(s.mod);
            const is_cjs = if (om) |m| m.wrap_kind == .cjs else false;
            if (!is_cjs) {
                // ESM owner 는 진짜 로컬(항상 유효 식별자)을 `local as 공개명` 으로 브리지한다.
                if (lnk.getExportLocalName(s.mod, s.name)) |local| break :blk local;
                // 로컬이 없으면(re-export 등) export 명이 그대로 공개명이 되는데, ES2022
                // arbitrary module namespace name(`export { v as "a-b" }`)이면 **식별자가
                // 아니다** → `var "a-b"` / `import { "a-b" }` 로 파싱 불가 산출물이 된다.
                if (preamble_writer.isPlainMemberName(s.name)) break :blk s.name;
                const h = try sanitizeGlobalNameHead(allocator, s.name);
                synth = h;
                break :blk h;
            }
            const req = try om.?.allocRequireName(allocator, null);
            defer allocator.free(req);
            const req_prefix = "require_";
            const tag = if (std.mem.startsWith(u8, req, req_prefix) and req.len > req_prefix.len)
                req[req_prefix.len..]
            else
                req;
            const head = try sanitizeGlobalNameHead(allocator, s.name);
            defer allocator.free(head);
            const b = try std.fmt.allocPrint(allocator, "{s}${s}", .{ head, tag });
            synth = b;
            break :blk b;
        };
        const candidate = try deconflictGlobalName(allocator, &used, preferred);
        // candidate 소유권을 맵으로 이전. used 는 맵의 저장본을 borrow(used.deinit 가 키 미해제).
        try lnk.putCrossChunkGlobalName(s.mod, s.name, candidate);
        try used.put(allocator, lnk.getCrossChunkGlobalName(s.mod, s.name).?, {});
    }
}

/// (#4510) cross-chunk 공개명(`<head>$<모듈 태그>`)의 head 를 유효 식별자로 만든다.
///  - namespace 키("*") → `ns`
///  - 비-식별자 멤버명(`'foo-bar'` — binding_scanner 가 따옴표까지 담아 둔 원문) → 따옴표를
///    벗기고 식별자 문자만 남긴다(`foo_bar`).
/// 서로 다른 멤버명이 같은 head 로 접히더라도 `deconflictGlobalName` 이 `$N` 으로 갈라준다
/// (맵 키는 원문 export 명이라 값 해석은 영향 없음). 반환값은 caller 소유.
pub fn sanitizeGlobalNameHead(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, linker_mod.CJS_NS_EXPORT_NAME)) return allocator.dupe(u8, "ns");
    if (preamble_writer.isPlainMemberName(name)) return allocator.dupe(u8, name);
    const inner = if (preamble_writer.isQuotedName(name)) name[1 .. name.len - 1] else name;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (inner) |c| {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or c == '$' or
            (buf.items.len > 0 and std.ascii.isDigit(c));
        try buf.append(allocator, if (ok) c else '_');
    }
    if (buf.items.len == 0) try buf.append(allocator, '_');
    return buf.toOwnedSlice(allocator);
}

/// `preferred` 이름을 `used`(이미 배정된 전역 이름) + JS 예약어를 회피해 유니크화.
/// 충돌 없으면 preferred dupe, 있으면 `preferred$1`, `preferred$2`... 반환값은 **owned**
/// (caller 소유). `computeCrossChunkGlobalNames` 의 deconflict 코어 — 단위 테스트 대상.
pub fn deconflictGlobalName(
    allocator: std.mem.Allocator,
    used: *const std.StringHashMapUnmanaged(void),
    preferred: []const u8,
) ![]const u8 {
    var candidate = try allocator.dupe(u8, preferred);
    var suffix: u32 = 0;
    while (used.contains(candidate) or Linker.isReservedName(candidate)) {
        allocator.free(candidate);
        suffix += 1;
        candidate = try std.fmt.allocPrint(allocator, "{s}${d}", .{ preferred, suffix });
    }
    return candidate;
}

/// (#4494) **직접 CJS import** 바인딩이 cross-chunk 배선 대상이면 그 canonical 을 반환.
///
/// `import x from './a.cjs'` 는 CJS 에 정적 export 가 없어 resolved binding 이 없다(=호출부의
/// `getResolvedBinding` 이 null). 그대로 두면 소비자 청크가 provider 청크에만 있는 `require_X()`
/// 썽크를 참조해 ReferenceError 가 난다(#4494). 등록하면 #4120 경로(provider 가 interop 값을
/// 전역명으로 materialize + export, 소비자는 preamble 억제 후 일반 import)가 발화한다.
///
/// **provider 가 실제로 materialize 하는 구성에서만** 등록해야 한다 — 안 그러면 소비자만 preamble
/// 을 억제해 값이 조용히 `undefined` 가 된다(기존의 시끄러운 ReferenceError 보다 나쁘다):
///  - preserve-modules: 전역명 자체를 안 만들고 emit 의 xchunk export 블록도 통째로 skip.
///  - 비-ESM(cjs/iife/umd/amd) + provider 가 **entry 청크**: emit 이 `emitCjsEntryExports` 에
///    일임하며 xchunk 블록을 early-break → materialize 가 방출되지 않는다.
/// 그 외 제외: namespace(`cjsNsCrossChunkCanonical` 이 따로 처리) · helper(esm_wrap 경로) ·
/// type-only(런타임에 존재하지 않음).
/// (#4510) 비-식별자 멤버명(`import { 'a-b' as x }`)도 이제 배선한다 — interop 식은 computed
/// 접근(`require_X()['a-b']`)으로, 공개명은 sanitize 한 합성명으로 만들 수 있다. 멤버명이 bare
/// `*` 인 경우만 방어적으로 제외 — namespace 키(`CJS_NS_EXPORT_NAME`)와 충돌하면 materialize
/// 가 서로를 덮어쓴다.
fn cjsDirectCrossChunkCanonical(
    lnk: *const Linker,
    chunk_graph: *const ChunkGraph,
    m: *const Module,
    ib: anytype,
) ?SymbolRef {
    if (chunk_graph.preserve_modules) return null;
    if (ib.kind == .namespace or ib.is_helper) return null;
    if (std.mem.eql(u8, ib.imported_name, linker_mod.CJS_NS_EXPORT_NAME)) return null;
    if (m.semantic) |*sem| {
        if (metadata_mod.isImportBindingTypeOnly(sem, ib)) return null;
    }
    const canon = lnk.cjsDirectCanonical(m, ib) orelse return null;
    return cjsCrossChunkProviderOk(lnk, chunk_graph, canon);
}

/// (#4510) **CJS namespace import**(`import * as ns from './x.cjs'`) 바인딩이 cross-chunk
/// 배선 대상이면 그 canonical(키 = "*") 을 반환.
///
/// CJS ns 는 `var ns = __toESM(require_X())` preamble 로만 만들 수 있는데 `require_X` 는
/// provider 청크에 갇혀 있다 → 소비자 청크에서 `require_X is not defined`(#4510-1). 등록하면
/// #4120 경로(provider 가 ns 객체를 전역명으로 materialize + export, 소비자는 preamble 억제 후
/// 일반 cross-chunk import)가 default/named 와 동일하게 발화한다.
fn cjsNsCrossChunkCanonical(
    lnk: *const Linker,
    chunk_graph: *const ChunkGraph,
    m: *const Module,
    ib: anytype,
) ?SymbolRef {
    if (chunk_graph.preserve_modules) return null;
    if (ib.kind != .namespace or ib.is_helper) return null;
    if (m.semantic) |*sem| {
        if (metadata_mod.isImportBindingTypeOnly(sem, ib)) return null;
    }
    const canon = lnk.cjsNamespaceCanonical(m, ib) orelse return null;
    return cjsCrossChunkProviderOk(lnk, chunk_graph, canon);
}

/// provider 가 실제로 materialize 하는 구성인지 확인하고 canonical 을 그대로 통과시킨다.
/// (#4494) **provider 가 materialize 하지 못하면 등록하면 안 된다** — 소비자만 preamble 을
/// 억제해 값이 조용히 `undefined` 가 된다(기존의 시끄러운 ReferenceError 보다 나쁘다).
///  - 비-ESM(cjs/iife/umd/amd) + provider 가 **entry 청크**: emit 이 `emitCjsEntryExports` 에
///    일임하며 xchunk export 블록을 early-break → materialize 가 방출되지 않는다.
fn cjsCrossChunkProviderOk(
    lnk: *const Linker,
    chunk_graph: *const ChunkGraph,
    canon: SymbolRef,
) ?SymbolRef {
    const cjs_chunk = chunk_graph.getModuleChunk(canon.module_index);
    if (cjs_chunk.isNone()) return null;
    if (lnk.format != .esm and chunk_graph.getChunk(cjs_chunk).kind == .entry_point) return null;
    return canon;
}

pub fn computeCrossChunkLinks(
    chunk_graph: *ChunkGraph,
    graph: *const ModuleGraph,
    allocator: std.mem.Allocator,
    linker: ?*const Linker,
) !void {
    const module_count = graph.moduleCount();

    // 먼저 모든 청크의 기존 데이터를 초기화 (exports_to는 다른 청크에서 기록하므로 분리)
    for (chunk_graph.chunks.items) |*chunk| {
        chunk.cross_chunk_imports.clearAndFree(allocator);
        chunk.cross_chunk_dynamic_imports.clearAndFree(allocator);
        {
            var it = chunk.imports_from.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(allocator);
            chunk.imports_from.clearAndFree(allocator);
        }
        chunk.exports_to.clearAndFree(allocator);
        // (#4541) 재실행(HMR re-link) 멱등 — 새 wrapper 맵도 초기화(안 하면 stale export/import).
        chunk.wrapper_cross_exports.clearAndFree(allocator);
        {
            var wit = chunk.wrapper_cross_imports.iterator();
            while (wit.next()) |entry| entry.value_ptr.deinit(allocator);
            chunk.wrapper_cross_imports.clearAndFree(allocator);
        }
    }

    for (chunk_graph.chunks.items) |*chunk| {
        // 중복 방지용 해시맵
        var seen_static: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen_static.deinit(allocator);
        var seen_dynamic: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen_dynamic.deinit(allocator);
        // namespace re-export fan-out 은 consumer(import_binding/import_record)·
        // re-exporter(export_binding) 3경로에서 같은 target 을 중복 발견할 수
        // 있다. ensureSharedNsVar/addCrossChunkSymbol 은 멱등이나 DFS·할당
        // churn 을 피하려 청크 단위로 target dedup.
        var seen_ns_target: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen_ns_target.deinit(allocator);
        // (#4560) direct-leaf `import * as ns` fan-out 은 **부분 작업**(fanOutModuleExports 만)이라
        // linkNamespaceCrossChunk 의 풀 작업(markNsCrossChunk+ensureSharedNsVar+ns 객체 등록)과 dedup
        // 도메인이 다르다. seen_ns_target 을 공유하면 이 브랜치가 먼저 dep 를 넣어 뒤이은
        // linkNamespaceCrossChunkOnce(같은 청크의 `export * as ns`·값-사용)를 조기 return 시켜 ns 객체
        // 합성이 누락된다(code-review). 별도 set 으로 격리 — fanOut 은 seen_static 으로 멱등이라 안전.
        var seen_ns_fanout: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen_ns_fanout.deinit(allocator);

        for (chunk.modules.items) |mod_idx| {
            // 청크에 포함된 모듈은 반드시 graph 범위 내에 있어야 함
            const m = graph.getModule(mod_idx) orelse {
                std.debug.assert(false);
                continue;
            };
            const mi = @intFromEnum(mod_idx);

            // 정적 의존성 → cross_chunk_imports
            for (m.dependencies.items) |dep_idx| {
                if (dep_idx.isNone()) continue;
                const dep_chunk = chunk_graph.getModuleChunk(dep_idx);
                if (dep_chunk.isNone()) continue;
                if (dep_chunk == chunk.index) continue; // 같은 청크 → 스킵
                const dci = @intFromEnum(dep_chunk);
                const gop = try seen_static.getOrPut(allocator, dci);
                if (!gop.found_existing) {
                    try chunk.cross_chunk_imports.append(allocator, dep_chunk);
                }
            }

            // 심볼 수준 크로스 청크 바인딩 추적 (linker가 있을 때만)
            if (linker) |lnk| {
                for (m.import_bindings) |ib| {
                    // canonical 모듈: resolved binding 이 있으면 그것, 없으면 **직접 CJS import** fallback.
                    //
                    // (#4494) CJS 는 정적 export 가 없어 resolveExportChain 이 null → `import x from
                    // './a.cjs'` 는 resolved binding 이 **아예 없다**(re-export 포워딩만 resolveOrCjsFallback
                    // 로 등록됨). 예전엔 여기서 그대로 skip 해 cross-chunk 심볼이 등록되지 않았고, 그 결과
                    // (a) provider 가 interop 값을 export 하지 않고 (b) metadata 의 #4120 억제 게이트도
                    // 전역명을 못 찾아 발화하지 않아 → 소비자 청크가 provider 청크에만 있는 `require_X()`
                    // 썽크를 참조 = ReferenceError. import_record 로 canonical(CJS)+export 명(`default`/
                    // 멤버명)을 만들어 등록하면 기존 #4120 경로(provider materialize + 소비자 preamble
                    // 억제)가 그대로 발화한다. helper 는 esm_wrap 경로가 담당하므로 제외.
                    //
                    // (#4510) CJS **namespace** import 도 같은 기계로 등록(키 = "*"). ESM ns 는
                    // cjsNsCrossChunkCanonical 이 null 을 주고 기존 ns 합성 경로
                    // (linkNamespaceCrossChunkOnce)가 그대로 담당한다. CJS ns 는 resolved binding 이
                    // 없으므로 rb 분기보다 **먼저** 봐야 한다.
                    const canonical: SymbolRef = if (cjsNsCrossChunkCanonical(lnk, chunk_graph, m, ib)) |c|
                        c
                    else if (lnk.getResolvedBinding(@intCast(mi), ib.local_span)) |rb|
                        rb.canonical
                    else if (cjsDirectCrossChunkCanonical(lnk, chunk_graph, m, ib)) |c|
                        c
                    else
                        continue;

                    const canonical_mi = @intFromEnum(canonical.module_index);
                    if (canonical_mi >= module_count) continue;

                    const src_chunk_idx = chunk_graph.getModuleChunk(canonical.module_index);
                    if (src_chunk_idx.isNone()) continue;
                    if (src_chunk_idx == chunk.index) continue; // 같은 청크 → 스킵

                    try addCrossChunkSymbol(allocator, chunk_graph, chunk, lnk, &seen_static, src_chunk_idx, canonical.export_name, canonical_mi);

                    // canonical 이 namespace re-export 면 그 이름만 가져와선
                    // 안 된다 — 정적 멤버는 정의자 export 로 elision, 값/동적은
                    // 합성 ns 객체 필요. 대상 모듈을 cross-chunk fan-out.
                    // (CJS canonical 은 export_bindings 가 없어 항상 null → no-op.)
                    if (nsReExportTarget(graph, canonical.module_index, canonical.export_name)) |ns_target|
                        try linkNamespaceCrossChunkOnce(allocator, chunk_graph, chunk, &seen_static, &seen_ns_target, lnk, ns_target, module_count);
                }

                // named re-export (`export { x } from "./y"`): import_binding 이
                // 없어(P 가 x 를 *사용*하지 않고 *전달*만 함) 위 루프가 놓친다.
                // canonical 이 다른 청크면 P 의 청크가 named 로 가져와야 (a) P 가
                // `exports.x=x`/`export {x}` 의 로컬 x 를 바인딩하고 (b) 소스
                // 청크가 x 를 노출한다. 없으면 side-effect import 만 나와
                // ReferenceError (#3321 후속, esm/cjs/iife 공통 선재 버그).
                // star/namespace re-export 는 별도 케이스 — 후속.
                for (m.export_bindings) |eb| {
                    if (eb.kind != .re_export) continue;
                    try linkReExportName(allocator, chunk_graph, chunk, &seen_static, lnk, mod_idx, eb.exported_name, module_count);
                }

                // re-exporter 측: 이 모듈이 namespace 를 re-export 하면 동적
                // re-import·재노출을 위해 자기 청크가 합성 ns 객체 + 대상
                // export 를 가져와야 한다. import_binding 없어 위 루프가 놓침.
                // .local/.re_export(_namespace) 만 namespace 후보 — kind gate 로
                // barrel 의 대다수 binding 에서 nsReExportTarget 스캔 회피.
                for (m.export_bindings) |eb| {
                    switch (eb.kind) {
                        .local, .re_export, .re_export_namespace => {},
                        else => continue,
                    }
                    const ns_target = nsReExportTarget(graph, mod_idx, eb.exported_name) orelse continue;
                    try linkNamespaceCrossChunkOnce(allocator, chunk_graph, chunk, &seen_static, &seen_ns_target, lnk, ns_target, module_count);
                }

                // consumer 측 (import_record 기반, getResolvedBinding 비의존):
                // namespace import 는 binding 이 안 잡혀 위 import_bindings
                // 루프가 놓치는 케이스 보완.
                for (m.import_bindings) |ib| {
                    if (ib.import_record_index >= m.import_records.len) continue;
                    const src_mod = m.import_records[ib.import_record_index].resolved;
                    if (src_mod.isNone()) continue;
                    if (nsReExportTarget(graph, src_mod, ib.imported_name)) |ns_target| {
                        try linkNamespaceCrossChunkOnce(allocator, chunk_graph, chunk, &seen_static, &seen_ns_target, lnk, ns_target, module_count);
                        continue;
                    }
                    // (#4532 증상2 / #4560) direct leaf `import * as ns from "./dep"` 의 멤버 접근
                    // (`ns.channel`)은 registerNamespaceRewrites 가 bare 멤버로 평탄화하는데,
                    // nsReExportTarget 은 namespace **re-export**(imported="*")만 잡아 이 direct leaf import
                    // 를 놓쳐 멤버가 cross-chunk 등록 안 됨 → 소비자 청크서 미정의 ReferenceError.
                    // dep 의 export 를 fan-out 해 imports_from 에 넣으면 computeCrossChunkGlobalNames(전역명)
                    // + provider export + rewrite 가 발화한다. linkReExportName 이 crossChunkExportIsShaken
                    // 으로 **전역 dead export** 는 거르지만, 소비자가 실제 쓰는 멤버만 추리진 않아 dep 의
                    // live export 를 통째로 등록한다 — rolldown 의 per-usage canonical-ref 보다 약간
                    // 과등록(mermaid 실측 ~0.08% dead import, correctness 무해). CJS dep 은 cjsNs interop
                    // 별경로라 제외, seen_ns_fanout(별도 set)로 dedup — seen_ns_target 공유 시 이 부분
                    // 작업이 뒤이은 풀 ns-object 배선을 조기 return 시킨다(위 선언부 주석).
                    //   - **splitting**(#4560): dev 제외. mermaid `import * as khroma; khroma.channel(color,"r")`
                    //     가 lazy 다이어그램 청크서 bare `channel` → render() ReferenceError 였다. dev 는
                    //     member rewrite 가 wrapped local 을 써 전역명 경로를 안 타므로 preserve-modules 와
                    //     동일하게 제외한다.
                    //   - **preserve-modules**(#4532): pm_xchunk_naming(ESM/CJS·non-minify·non-dev) 한정.
                    const ns_fanout_ok = if (chunk_graph.preserve_modules) chunk_graph.pm_xchunk_naming else !graph.dev_mode;
                    if (ns_fanout_ok and ib.kind == .namespace) {
                        if (graph.getModule(src_mod)) |dep| {
                            if (dep.wrap_kind != .cjs) {
                                const dep_chunk = chunk_graph.getModuleChunk(src_mod);
                                if (!dep_chunk.isNone() and dep_chunk != chunk.index) {
                                    const gop = try seen_ns_fanout.getOrPut(allocator, @intFromEnum(src_mod));
                                    if (!gop.found_existing)
                                        try fanOutModuleExports(allocator, chunk_graph, chunk, &seen_static, lnk, src_mod, module_count);
                                }
                            }
                        }
                    }
                }

                // `export * from "./y"` (re_export_star, y 별도 청크): 위 named
                // 루프는 `.re_export` 만 본다 — star 는 소스 전체 export 를
                // 열거해야 하므로 누락(재-exporter 가 side-effect import 만 받아
                // 미바인딩 link error). collectExportsRecursive 로 m 의 effective
                // export(nested export */diamond 포함)를 전부 열거, canonical 이
                // 다른 청크인 이름마다 addCrossChunkSymbol 로 named 바인딩+재노출
                // (#3350 named 의 star 버전). `.re_export_namespace`(export * as
                // ns — namespace 객체 합성)는 emit-side 별도 후속(미처리).
                var has_star = false;
                for (m.export_bindings) |eb| {
                    if (eb.kind == .re_export_star) {
                        has_star = true;
                        break;
                    }
                }
                if (has_star)
                    try fanOutModuleExports(allocator, chunk_graph, chunk, &seen_static, lnk, mod_idx, module_count);

                // (#4541) raw `require("./x.cjs")` 로 **다른 청크**의 CJS 를 참조: import binding 이
                // 없어 위 심볼 루프가 못 보고 chunk-level 의존 edge(side-effect import)만 생긴다.
                // 그 결과 소비자가 provider 청크에만 있는 `require_X()` 썽크를 미-import 참조 →
                // ReferenceError(#4541). 여기서 provider 는 썽크를 export, 소비자는 import 하도록
                // 표시한다(esbuild/rolldown 동형). ⚠️ require_X 는 **lazy**(호출 시점 평가)라 provider
                // 에서 eager materialize(default$X=require_X())하지 않고 썽크 자체를 넘긴다.
                for (m.import_records) |rec| {
                    if (rec.kind != .require) continue;
                    if (rec.resolved.isNone()) continue;
                    const tmod = graph.getModule(rec.resolved) orelse continue;
                    if (tmod.wrap_kind != .cjs) continue; // require_X 썽크(CJS)만 — ESM-wrap 은 후속
                    const target_chunk = chunk_graph.getModuleChunk(rec.resolved);
                    if (target_chunk.isNone() or target_chunk == chunk.index) continue;
                    const ti = @intFromEnum(rec.resolved);
                    const tci = @intFromEnum(target_chunk);
                    try chunk_graph.chunks.items[tci].wrapper_cross_exports.put(allocator, ti, {});
                    const wgop = try chunk.wrapper_cross_imports.getOrPut(allocator, tci);
                    if (!wgop.found_existing) wgop.value_ptr.* = .empty;
                    for (wgop.value_ptr.items) |e| {
                        if (e == ti) break;
                    } else try wgop.value_ptr.append(allocator, ti);
                    // cross_chunk_imports 보장: 위 정적-의존 루프(m.dependencies)가 보통 이미 이
                    // provider 를 추가하지만(raw require = 의존 edge), 그 edge 가 없는 경우를 대비해
                    // seen_static dedup 으로 방어적 append(중복 없음 — 소비자 import emit 이 이 목록 순회).
                    const sgop = try seen_static.getOrPut(allocator, tci);
                    if (!sgop.found_existing) try chunk.cross_chunk_imports.append(allocator, target_chunk);
                }
            }

            // 동적 의존성 → cross_chunk_dynamic_imports
            for (m.dynamic_imports.items) |dyn_idx| {
                if (dyn_idx.isNone()) continue;
                const dyn_chunk = chunk_graph.getModuleChunk(dyn_idx);
                if (dyn_chunk.isNone()) continue;
                if (dyn_chunk == chunk.index) continue; // 같은 청크 → 스킵
                const dci = @intFromEnum(dyn_chunk);
                const gop = try seen_dynamic.getOrPut(allocator, dci);
                if (!gop.found_existing) {
                    try chunk.cross_chunk_dynamic_imports.append(allocator, dyn_chunk);
                }
            }
        }
    }
}

test "BitSet.isSubsetOf: empty is subset of anything; self is subset of self" {
    const a = std.testing.allocator;
    var s = try BitSet.init(a, 8);
    defer s.deinit(a);
    var t = try BitSet.init(a, 8);
    defer t.deinit(a);
    // 둘 다 빈 BitSet: ∅ ⊆ ∅
    try std.testing.expect(s.isSubsetOf(t));
    t.setBit(1);
    t.setBit(3);
    // ∅ ⊆ {1,3}
    try std.testing.expect(s.isSubsetOf(t));
    // {1,3} ⊆ {1,3}
    try std.testing.expect(t.isSubsetOf(t));
    // {1,3} ⊄ ∅
    try std.testing.expect(!t.isSubsetOf(s));
}

test "BitSet.isSubsetOf: proper subset true, extra bit false" {
    const a = std.testing.allocator;
    var sub = try BitSet.init(a, 16);
    defer sub.deinit(a);
    var sup = try BitSet.init(a, 16);
    defer sup.deinit(a);
    sub.setBit(2);
    sub.setBit(9);
    sup.setBit(2);
    sup.setBit(9);
    sup.setBit(12);
    // {2,9} ⊆ {2,9,12}
    try std.testing.expect(sub.isSubsetOf(sup));
    // {2,9,12} ⊄ {2,9}
    try std.testing.expect(!sup.isSubsetOf(sub));
    sub.setBit(5); // {2,5,9} — 5 not in sup
    try std.testing.expect(!sub.isSubsetOf(sup));
}

test "BitSet.isSubsetOf: differing entries length safe" {
    const a = std.testing.allocator;
    var short = try BitSet.init(a, 4); // 1 byte
    defer short.deinit(a);
    var long = try BitSet.init(a, 64); // 8 bytes
    defer long.deinit(a);
    short.setBit(1);
    long.setBit(1);
    // {1}(short) ⊆ {1}(long) — 길이 달라도 안전
    try std.testing.expect(short.isSubsetOf(long));
    long.setBit(40); // long 의 초과 바이트 비트
    try std.testing.expect(short.isSubsetOf(long));
    // long 의 set 비트가 short 범위 밖이면 long ⊄ short
    try std.testing.expect(!long.isSubsetOf(short));
}

test "sanitizeNameDir: 기본 — 그대로" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src/pages");
    defer a.free(r);
    try std.testing.expectEqualStrings("src/pages", r);
}

test "sanitizeNameDir: leading slash 제거(절대경로 흡수)" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "/abs/path");
    defer a.free(r);
    try std.testing.expectEqualStrings("abs/path", r);
}

test "sanitizeNameDir: trailing slash 제거" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src/");
    defer a.free(r);
    try std.testing.expectEqualStrings("src", r);
}

test "sanitizeNameDir: 양쪽 slash 제거" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "/src/");
    defer a.free(r);
    try std.testing.expectEqualStrings("src", r);
}

test "sanitizeNameDir: Windows 백슬래시 정규화" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "win\\sub");
    defer a.free(r);
    try std.testing.expectEqualStrings("win/sub", r);
}

test "sanitizeNameDir: mixed backslash + leading/trailing" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "\\abs\\foo\\");
    defer a.free(r);
    try std.testing.expectEqualStrings("abs/foo", r);
}

test "sanitizeNameDir: .. 세그먼트 거부 — 빈 문자열" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src/../etc");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: literal `..` 가 segment 안에 있으면 허용" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "foo..bar");
    defer a.free(r);
    try std.testing.expectEqualStrings("foo..bar", r);
}

test "sanitizeNameDir: NUL 바이트 거부" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src\x00bad");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: 빈 입력 → 빈 출력" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: 시작에 .. 거부" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "../etc");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: 끝에 .. 거부" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "foo/..");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

// PR B-3: sanitize 정밀화 — sharp-edge 가드 (F2/F3/F4/F7).

test "sanitizeNameDir: Windows drive letter 거부 (대문자)" {
    // C:/foo 또는 C:\\foo → 빈 문자열. PR B-4 활성화 후 [dir] 토큰 출력에
    // 절대 path 가 들어가 outDir escape 위험 차단.
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "C:/foo");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: Windows drive letter 거부 (소문자)" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "c:/Users/me");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: Windows drive letter 거부 (백슬래시)" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "D:\\projects");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: 'C:' 만 (path 없음) 거부" {
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "C:");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: drive-letter-like 가 path 중간에 있으면 통과" {
    // "src/c:abc" 처럼 drive letter 패턴이 path *중간* 에 있으면 OS 가 drive
    // 로 해석하지 않으므로 통과 (정확히 raw[0..2] == [A-Za-z]:'' 만 거부).
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src/c:abc");
    defer a.free(r);
    try std.testing.expectEqualStrings("src/c:abc", r);
}

test "sanitizeNameDir: virtual-id / namespace prefix 통과 ('node:fs', 'http:host')" {
    // ^[A-Za-z]: 뒤에 `/` 도 `\\` 도 아닌 character 가 오면 path 가 아닌
    // namespace 라 통과. plugin-emitted virtual chunks 의 dirname 손실 방지.
    const a = std.testing.allocator;
    {
        const r = try sanitizeNameDir(a, "node:fs");
        defer a.free(r);
        try std.testing.expectEqualStrings("node:fs", r);
    }
    {
        const r = try sanitizeNameDir(a, "http:example.com");
        defer a.free(r);
        try std.testing.expectEqualStrings("http:example.com", r);
    }
}

test "sanitizeNameDir: control byte (CR/LF/TAB/DEL) 거부" {
    const a = std.testing.allocator;
    inline for (.{ "foo\nbar", "foo\rbar", "foo\tbar", "foo\x01bar", "foo\x7fbar" }) |raw| {
        const r = try sanitizeNameDir(a, raw);
        defer a.free(r);
        try std.testing.expectEqualStrings("", r);
    }
}

test "sanitizeNameDir: Windows-reserved char 거부" {
    const a = std.testing.allocator;
    // `:` 는 drive letter 검사로 따로 처리되므로 여기선 다른 reserved 만.
    inline for (.{ "foo<bar", "foo>bar", "foo\"bar", "foo|bar", "foo?bar", "foo*bar" }) |raw| {
        const r = try sanitizeNameDir(a, raw);
        defer a.free(r);
        try std.testing.expectEqualStrings("", r);
    }
}

test "sanitizeNameDir: mid-path 중복 슬래시 압축" {
    // "src//pages///deep" → "src/pages/deep".
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src//pages///deep");
    defer a.free(r);
    try std.testing.expectEqualStrings("src/pages/deep", r);
}

test "sanitizeNameDir: 백슬래시 정규화 후에도 mid-path 압축" {
    // "src\\\\pages" → 정규화 후 "src//pages" → 압축 "src/pages".
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src\\\\pages");
    defer a.free(r);
    try std.testing.expectEqualStrings("src/pages", r);
}

test "sanitizeNameDir: 단일 '.' segment 거부" {
    // path component '.' 은 current dir 참조 — sanitize 결과 빈 문자열로
    // fallback (PR B-4 시 [dir] 가 빈 dir 분기로 leading-slash skip).
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, ".");
    defer a.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "sanitizeNameDir: mid-path '.' segment strip" {
    // "src/./pages" → "src/pages".
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src/./pages");
    defer a.free(r);
    try std.testing.expectEqualStrings("src/pages", r);
}

test "sanitizeNameDir: 시작/끝의 '.' segment strip" {
    const a = std.testing.allocator;
    {
        const r = try sanitizeNameDir(a, "./src");
        defer a.free(r);
        try std.testing.expectEqualStrings("src", r);
    }
    {
        const r = try sanitizeNameDir(a, "src/.");
        defer a.free(r);
        try std.testing.expectEqualStrings("src", r);
    }
}

test "sanitizeNameDir: literal dot 이 segment 안에 있으면 보존" {
    // ".eslintrc" 처럼 path component 가 점으로 시작하는 hidden 파일 디렉토리
    // 는 정상 — '.' segment 가 *단독* 일 때만 strip.
    const a = std.testing.allocator;
    const r = try sanitizeNameDir(a, "src/.config/dist");
    defer a.free(r);
    try std.testing.expectEqualStrings("src/.config/dist", r);
}

// PR B-4b sub-1b: entryRelativeDir 회귀 가드 — abs path → entry_dir-relative.

test "entryRelativeDir: 기본 — abs 가 entry_dir 안에 있으면 relative" {
    try std.testing.expectEqualStrings(
        "a",
        entryRelativeDir("/proj/src", "/proj/src/a"),
    );
    try std.testing.expectEqualStrings(
        "a/b/c",
        entryRelativeDir("/proj/src", "/proj/src/a/b/c"),
    );
}

test "entryRelativeDir: abs == entry_dir → 빈 문자열" {
    try std.testing.expectEqualStrings("", entryRelativeDir("/proj/src", "/proj/src"));
}

test "entryRelativeDir: entry_dir 빈 문자열 → 빈 fallback" {
    try std.testing.expectEqualStrings("", entryRelativeDir("", "/proj/src/a"));
}

test "entryRelativeDir: abs 가 entry_dir 보다 짧으면 빈 fallback" {
    try std.testing.expectEqualStrings("", entryRelativeDir("/proj/src", "/proj"));
}

test "entryRelativeDir: F1 sibling-prefix 차단 (CRITICAL)" {
    // entry_dir='src/pages' 가 abs='src/pages2/a' 의 byte-startsWith match
    // 하지만 separator boundary 안 맞으므로 빈 fallback. 옛 코드는 잘못된
    // rel='2/a' 만들었음. 회귀 시 sibling dir 가 잘못 묶임.
    try std.testing.expectEqualStrings(
        "",
        entryRelativeDir("src/pages", "src/pages2/a"),
    );
    try std.testing.expectEqualStrings(
        "",
        entryRelativeDir("/proj/src", "/proj/src-tests/x"),
    );
}

test "entryRelativeDir: Windows 백슬래시 separator 정규화" {
    // entry_dir 가 forward slash, abs 가 backslash 인 (Windows OS API) 케이스 —
    // separator-agnostic byte 비교로 정상 match.
    try std.testing.expectEqualStrings(
        "Card.tsx",
        entryRelativeDir("C:/proj/src", "C:\\proj\\src\\Card.tsx"),
    );
    // 반대 방향 — entry_dir 백슬래시, abs forward slash.
    try std.testing.expectEqualStrings(
        "Card.tsx",
        entryRelativeDir("C:\\proj\\src", "C:/proj/src/Card.tsx"),
    );
}

test "entryRelativeDir: nested abs 가 깊은 경로면 깊이 보존" {
    try std.testing.expectEqualStrings(
        "pages/a/components",
        entryRelativeDir("/proj/src", "/proj/src/pages/a/components"),
    );
}

test "entryRelativeDir: 결과는 sanitizeNameDir 와 호환" {
    // entryRelativeDir 결과를 sanitizeNameDir 에 통과 — 일관성 검증.
    const a = std.testing.allocator;
    const rel = entryRelativeDir("/proj/src", "/proj/src/pages/a");
    const s = try sanitizeNameDir(a, rel);
    defer a.free(s);
    try std.testing.expectEqualStrings("pages/a", s);
}
