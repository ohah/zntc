//! Module Federation 옵션 단일 소스. `MfConfigDto`(zntc.config 의 `mf`)
//! → `MfBundleConfig` 변환 + shared/remotes seam 유도를 **CLI(`src/cli/
//! options.zig`)와 NAPI(`packages/core/src/napi/options.zig`) 양쪽이 위임**
//! 한다. 과거 mf 변환·seam 이 cli/options.zig 에만 있어 NAPI 가 silent
//! 하게 갈라진 갭(발행 @zntc/core 에서 MF 미동작)을 구조적으로 봉인.
//!
//! seam* 는 **순수 유도 함수**(CliOptions/BundleOptions 비의존, 입력=mfb,
//! 출력=owned 슬라이스). 적용은 호출자가(CLI=ArrayList append, NAPI=napi
//! 배열 concat). 향후 seam 을 번들러 코어로 단일 적용점화(④)할 때 이
//! 순수 함수를 그대로 재사용 — 무손실 디딤돌.

const std = @import("std");
const types = @import("types.zig");
const federation = @import("federation.zig");
const transpile = @import("../transpile.zig");

pub const MfBundleConfig = types.MfBundleConfig;
const KV = MfBundleConfig.KV;
const SharedEntry = MfBundleConfig.SharedEntry;
const GlobalEntry = types.GlobalEntry;
const MfConfigDto = transpile.MfConfigDto;

/// 스펙 런타임 pkg/글로벌 — federation.zig 단일 소스 재노출(emitHostInit
/// 과 반드시 일치). 고정 상수라 alloc/소유 무관(static literal).
pub const MF_RUNTIME_PKG = federation.MF_RUNTIME_PKG;
pub const MF_RUNTIME_GLOBAL = federation.MF_RUNTIME_GLOBAL;

/// 한 SharedEntry 의 owned 필드 해제. fromDto 정상경로와 부분실패
/// errdefer 가 **동일 본문 공유**(필드 추가 시 한 곳만 — #4-0 share_scope
/// 가 양쪽 동기화 부담 노출).
pub fn freeSharedEntry(alloc: std.mem.Allocator, s: SharedEntry) void {
    alloc.free(s.name);
    if (s.required_version) |rv| alloc.free(rv);
    if (s.global_seam.len > 0) alloc.free(s.global_seam);
    alloc.free(s.share_scope); // name 과 동일 — 항상 owned(default 도 dup)
}

/// fromDto 가 allocator-dup 한 것 일괄 해제. 소유자(CLI=CliOptions.deinit,
/// NAPI=cleanup)의 정상 종료와 fromDto 의 errdefer 가 **공유**(해제 모델
/// 단일 소스 — 부분 실패/정상 종료 대칭). len>0 가드: exposes/remotes/
/// shared default 는 static `&.{}`(오해제 방지). name 은 set 시 항상 dup,
/// share_scope 는 항상 dup. **불변: mfb 는 fromDto 로만 생성**(외부 생성
/// 시 share_scope 리터럴 free 위험).
pub fn freeMfBundle(alloc: std.mem.Allocator, mfb: MfBundleConfig) void {
    if (mfb.name) |n| alloc.free(n);
    alloc.free(mfb.share_scope);
    alloc.free(mfb.share_strategy);
    for (mfb.exposes) |kv| {
        alloc.free(kv.key);
        alloc.free(kv.value);
    }
    if (mfb.exposes.len > 0) alloc.free(mfb.exposes);
    for (mfb.remotes) |kv| {
        alloc.free(kv.key);
        alloc.free(kv.value);
    }
    if (mfb.remotes.len > 0) alloc.free(mfb.remotes);
    for (mfb.shared) |s| freeSharedEntry(alloc, s);
    if (mfb.shared.len > 0) alloc.free(mfb.shared);
}

/// JSON record(`std.json.ArrayHashMap`)→`[]KV` deep-dupe. exposes/remotes
/// 공용(DRY). 중간 OOM 시 이미 dup 한 항목+list 해제(errdefer).
fn dupeKvMap(allocator: std.mem.Allocator, map: anytype) ![]const KV {
    const list = try allocator.alloc(KV, map.count());
    var done: usize = 0;
    errdefer {
        for (list[0..done]) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(list);
    }
    var it = map.iterator();
    while (it.next()) |kv| : (done += 1) list[done] = .{
        .key = try allocator.dupe(u8, kv.key_ptr.*),
        .value = try allocator.dupe(u8, kv.value_ptr.*),
    };
    return list;
}

/// `MfConfigDto`(arena, record) → `MfBundleConfig`(소유자 수명, 평탄화).
/// 모든 문자열 `allocator.dupe`(외부 mf list / emit 이 build 끝까지 참조).
/// 중간 OOM 시 freeMfBundle 로 일괄 해제(errdefer = 정상해제 대칭).
pub fn fromDto(
    allocator: std.mem.Allocator,
    dto: *const MfConfigDto,
) !MfBundleConfig {
    var out: MfBundleConfig = .{};
    errdefer freeMfBundle(allocator, out);
    if (dto.name) |n| out.name = try allocator.dupe(u8, n);
    // share_scope/share_strategy 는 항상 owned(default 도 dup) — freeMfBundle
    // 무조건 free 와 대칭(리터럴/owned 혼재 회피).
    out.share_scope = try allocator.dupe(u8, dto.shareScope orelse "default");
    out.share_strategy = try allocator.dupe(u8, dto.shareStrategy orelse "version-first");

    if (dto.exposes) |e| out.exposes = try dupeKvMap(allocator, &e.map);
    if (dto.remotes) |r| out.remotes = try dupeKvMap(allocator, &r.map);
    if (dto.shared) |sh| {
        const list = try allocator.alloc(SharedEntry, sh.map.count());
        errdefer allocator.free(list);
        var it = sh.map.iterator();
        var i: usize = 0;
        // 부분 실패 시: 이미 채운 항목 해제(list[0..i] — 실패 iteration 의
        // i 는 미증가라 제외, in-progress 는 아래 per-field errdefer 가).
        errdefer for (list[0..i]) |s| freeSharedEntry(allocator, s);
        while (it.next()) |kv| : (i += 1) {
            const c = kv.value_ptr.*; // MfSharedDto
            const nm = try allocator.dupe(u8, kv.key_ptr.*);
            errdefer allocator.free(nm);
            const rv = if (c.requiredVersion) |v| try allocator.dupe(u8, v) else null;
            errdefer if (rv) |r| allocator.free(r);
            // #4-0 해석 3-tier + 항상-owned 근거: SharedEntry.share_scope doc.
            const sc = try allocator.dupe(u8, c.shareScope orelse dto.shareScope orelse "default");
            errdefer allocator.free(sc);
            list[i] = .{
                .name = nm,
                .singleton = c.singleton orelse false,
                .required_version = rv,
                .strict_version = c.strictVersion orelse false,
                .eager = c.eager orelse false,
                // 글로벌명 1회 생성·소유(seam·init borrow). 단일 규칙.
                .global_seam = try federation.mfSharedGlobalName(allocator, nm),
                .share_scope = sc,
            };
        }
        out.shared = list;
    }
    return out;
}

/// shared/remotes → host 소비 seam 의 **external specifier** 집합(순수
/// 유도). shared pkg + remote key + (remotes 있으면)`@module-federation/
/// runtime`. 모든 원소 borrow(mfb 소유 / static MF_RUNTIME_PKG) — 컨테
/// 이너만 owned(호출자 free). CLI applyMf*Seam·NAPI concat 단일 소스.
pub fn seamExternals(allocator: std.mem.Allocator, mfb: MfBundleConfig) ![]const []const u8 {
    const has_remotes = mfb.remotes.len > 0;
    const n = mfb.shared.len + (if (has_remotes) mfb.remotes.len + 1 else 0);
    const out = try allocator.alloc([]const u8, n);
    var i: usize = 0;
    for (mfb.shared) |s| {
        out[i] = s.name; // borrow (mfb 소유)
        i += 1;
    }
    if (has_remotes) {
        for (mfb.remotes) |kv| {
            out[i] = kv.key; // borrow
            i += 1;
        }
        out[i] = MF_RUNTIME_PKG; // static
        i += 1;
    }
    return out;
}

/// shared/remotes → host 소비 seam 의 **GlobalEntry** 집합(순수 유도).
/// {shared.name → global_seam} + (remotes 있으면){MF_RUNTIME_PKG →
/// MF_RUNTIME_GLOBAL}. specifier/global_name borrow(mfb 소유 / static).
pub fn seamGlobals(allocator: std.mem.Allocator, mfb: MfBundleConfig) ![]const GlobalEntry {
    const has_remotes = mfb.remotes.len > 0;
    const n = mfb.shared.len + (if (has_remotes) @as(usize, 1) else 0);
    const out = try allocator.alloc(GlobalEntry, n);
    var i: usize = 0;
    for (mfb.shared) |s| {
        out[i] = .{ .specifier = s.name, .global_name = s.global_seam }; // borrow
        i += 1;
    }
    if (has_remotes) {
        out[i] = .{ .specifier = MF_RUNTIME_PKG, .global_name = MF_RUNTIME_GLOBAL };
        i += 1;
    }
    return out;
}

test "fromDto: 기본 dup + free 대칭(누수 0)" {
    const a = std.testing.allocator;
    const P = struct {
        fn p(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(MfConfigDto) {
            return std.json.parseFromSlice(MfConfigDto, alloc, s, .{ .ignore_unknown_fields = true });
        }
    };
    const v = try P.p(a, "{\"name\":\"app\",\"exposes\":{\"./W\":\"./w.ts\"}," ++
        "\"remotes\":{\"r\":\"r@u\"},\"shared\":{\"react\":{\"singleton\":true,\"shareScope\":\"ui\"}}}");
    defer v.deinit();
    const mfb = try fromDto(a, &v.value);
    defer freeMfBundle(a, mfb); // testing.allocator = 누수/이중해제 탐지
    try std.testing.expectEqualStrings("app", mfb.name.?);
    try std.testing.expectEqual(@as(usize, 1), mfb.shared.len);
    try std.testing.expectEqualStrings("ui", mfb.shared[0].share_scope);
}

test "seamExternals/seamGlobals: 순수 유도 형태 + 컨테이너만 owned" {
    const a = std.testing.allocator;
    const P = struct {
        fn p(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(MfConfigDto) {
            return std.json.parseFromSlice(MfConfigDto, alloc, s, .{ .ignore_unknown_fields = true });
        }
    };
    const v = try P.p(a, "{\"name\":\"app\",\"remotes\":{\"r\":\"r@u\"}," ++
        "\"shared\":{\"react\":{\"singleton\":true}}}");
    defer v.deinit();
    const mfb = try fromDto(a, &v.value);
    defer freeMfBundle(a, mfb);

    const ext = try seamExternals(a, mfb);
    defer a.free(ext); // 컨테이너만 — 원소는 mfb/static 소유(free 금지)
    // shared react + remote r + MF_RUNTIME_PKG
    try std.testing.expectEqual(@as(usize, 3), ext.len);
    try std.testing.expectEqualStrings("react", ext[0]);
    try std.testing.expectEqualStrings("r", ext[1]);
    try std.testing.expectEqualStrings(MF_RUNTIME_PKG, ext[2]);

    const gl = try seamGlobals(a, mfb);
    defer a.free(gl);
    // {react→seam} + {MF_RUNTIME_PKG→MF_RUNTIME_GLOBAL}
    try std.testing.expectEqual(@as(usize, 2), gl.len);
    try std.testing.expectEqualStrings("react", gl[0].specifier);
    try std.testing.expectEqualStrings(MF_RUNTIME_PKG, gl[1].specifier);
    try std.testing.expectEqualStrings(MF_RUNTIME_GLOBAL, gl[1].global_name);
}
