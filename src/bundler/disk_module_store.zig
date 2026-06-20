//! 디스크 모듈 store — #4438. `disk_cache`(영속화) + `module_codec`(직렬화)를 묶어
//! "캐시 키(u64) → 한 모듈의 AST+semantic" 을 디스크에 저장/복원한다.
//!
//! 캐시 키 계산은 `cache_key.compute` 의 몫이고, 여기선 그 키를 받아 바이트를 읽고 쓴다.
//! graph 통합 PR 이 buildIncremental 의 cache-hit 경로에 연결할 때까지는 **단위 테스트 전용**
//! (파이프라인 미연결 → HMR/RN/빌드 출력 영향 0).
//!
//! ## 범위: AST+semantic 만 (graph 통합 시 필독)
//! `load` 는 한 모듈의 **AST+semantic 만** 복원한다 — `import_records`/`resolved_deps`/
//! `alias_table` 등 graph 레벨 Module 상태는 **포함하지 않는다**(module_codec 범위와 동일).
//! 이는 in-memory `module_store.PersistentModuleStore.getIfFresh`(전체 Module 을 struct-assign)
//! 와 **다르다** — 이름이 비슷하니 혼동 주의. graph cache-hit 경로가 load() 결과를 full Module 로
//! 착각해 import_records 를 재구성하지 않으면 import 미링크로 번들이 깨진다.
//!
//! `load` 가 `null`(miss/손상)을 돌려줄 때 주입한 `arena` 에 **부분 복원분이 남을 수 있다**
//! (codec 이 ast 블록까지 alloc 한 뒤 sem 블록에서 실패하는 경우). caller 는 miss 시 그 arena 를
//! 재사용하지 말고 **모듈별 새 parse_arena** 에 load 를 시도할 것(arena.deinit 가 일괄 회수).
//!
//! 동시성: `DiskCache` 와 동일 — 한 인스턴스를 여러 스레드가 공유하면 thread-safe allocator 가
//! 필요하다(경로 문자열 할당). graph 통합이 worker 에서 호출할 때 주의.
//!
//! ## fail-safe (캐시는 no-cache 보다 빌드를 더 깨뜨리지 않는다)
//! - `store` 는 best-effort: caller 가 `store(...) catch {}` 로 감싸 쓰기 실패가 빌드를 막지
//!   않게 한다(디스크 풀 등). 여기선 propagate 하고 정책은 caller 가 정한다.
//! - `load` 는 miss(파일 없음, `disk_cache.get`→null)뿐 아니라 **손상**(magic/checksum/truncated)
//!   도 `null` 로 degrade → 재파싱. codec 의 fail-safe 검증이 잘못된 캐시를 조용히 쓰는 것을
//!   막는다. `OutOfMemory` 만 전파.

const std = @import("std");
const DiskCache = @import("disk_cache.zig").DiskCache;
const module_codec = @import("module_codec.zig");
const Ast = @import("../parser/ast.zig").Ast;
const ModuleSemanticData = @import("module.zig").ModuleSemanticData;

/// 한 캐시 엔트리(한 모듈) 크기 상한 — 손상/거대 파일 방어. 초과 시 load 는 miss 로 degrade.
/// 정상 모듈(typescript.js ~9MB src → 직렬화 수십 MB)보다 넉넉하되, **너무 크면 안 된다**:
/// 손상 캐시의 거대 length-prefix 가 이 상한까지 read alloc 을 시도하다 OOM 으로 전파되면
/// 손상 엔트리가 빌드를 hard-fail 시켜 fail-safe 를 깨므로(code-review 종합), 손상이 현실적
/// 메모리 압박 없이 miss 로 degrade 하도록 64MB 로 둔다.
pub const MAX_ENTRY_BYTES: usize = 64 * 1024 * 1024;

pub const DiskModuleStore = struct {
    disk: DiskCache,

    pub fn init(allocator: std.mem.Allocator, root_dir: []const u8) std.mem.Allocator.Error!DiskModuleStore {
        return .{ .disk = try DiskCache.init(allocator, root_dir) };
    }

    pub fn deinit(self: *DiskModuleStore) void {
        self.disk.deinit();
    }

    /// 한 모듈의 AST+semantic 을 직렬화해 key 에 atomic 저장. best-effort(caller 가 catch).
    /// `alloc` 은 직렬화 임시 버퍼용(반환 없음 — 디스크에만 남는다).
    pub fn store(
        self: *const DiskModuleStore,
        io: std.Io,
        alloc: std.mem.Allocator,
        key: u64,
        ast: *const Ast,
        sem: *const ModuleSemanticData,
    ) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try module_codec.serialize(ast, sem, &buf, alloc);
        try self.disk.put(io, key, buf.items);
    }

    /// key 의 캐시를 `arena` 에 복원. **miss/손상은 모두 `null`**(재파싱) — `OutOfMemory` 만 전파.
    /// `alloc` 은 디스크 바이트 읽기용 임시(복원 후 free), 복원본은 `arena` 소유.
    pub fn load(
        self: *const DiskModuleStore,
        io: std.Io,
        alloc: std.mem.Allocator,
        arena: std.mem.Allocator,
        key: u64,
    ) !?module_codec.DeserializedModule {
        const bytes = (try self.disk.get(io, alloc, key, MAX_ENTRY_BYTES)) orelse return null;
        defer alloc.free(bytes);
        return module_codec.deserialize(bytes, arena) catch |err| switch (err) {
            error.OutOfMemory => err, // 자원 고갈은 캐시 문제 아님 → 전파
            else => null, // magic/checksum/truncated 손상 = miss → 재파싱(fail-safe)
        };
    }
};
