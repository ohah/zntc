# RFC: Release Profiling Harness — Debug Profile + Release Wall 측정 통합

상태: **DRAFT · Sub-PR-L.0 prerequisite** · 분류: 측정 도구 / dev tooling
부모 RFC: [RFC_LIFECYCLE_SCOPE_REDESIGN](./RFC_LIFECYCLE_SCOPE_REDESIGN.md) Phase 1
관련: `src/profile.zig`, `src/server/dev_server.zig`, `tests/benchmark/`
예상 작업량: **1-2주**

## 1. 배경 — 측정 괴리 문제

RFC #3939 (emit incremental) Sub-PR-C.2 의 3가지 PoC 가 모두 noise/회귀로 NO-GO 됐다. 진짜 root 는 fix 자체가 아니라 **측정 도구의 한계**.

### 1.1 두 측정 path 의 결과 괴리

| 측정 | lodash 641 modules incremental rebuild | 비고 |
|---|---|---|
| **Debug profile** (`ZNTC_PROFILE=all`) | `emit_concat 95ms`, `emit.css 24ms`, `emit.module.pass 16ms` | sub-phase ms 단위 정확 |
| **Release wall** (dev_server WS HMR `bundle_build_done.duration`) | 307ms total | sub-phase 분해 없음 |

Sub-PR-C.2 시도 결과:
- Phase 1.5 parallel: Debug 측정 안 함, Release 307→323ms (-16ms 회귀)
- CSS short-circuit: Debug emit.css 24ms, Release 307→307ms (변화 없음)
- dev_codes module cache: Debug 측정 안 함, Release 307→304ms (3ms noise)

**모순**: Debug 의 95ms emit_concat 이 Release 에선 ~? ms (모름) — 그 영역의 fix 가 Release 에서 noise 안에 묻힘. *어느 sub-phase 가 Release 에서 진짜 큰지 모름*.

### 1.2 진짜 원인 — Build mode 별 코드 최적화 차이

`zig` 의 Debug vs ReleaseFast 의 차이:
- Debug: optimization 없음, sub-phase 의 *실제 작업량* 이 ms 단위로 visible
- Release: aggressive inline + optimization, sub-phase 들이 통합되어 ms 가 *훨씬 작아짐*

emit_concat 의 Debug 95ms 가 Release 에선 ~10ms 일 수도 있고 ~50ms 일 수도. **알 수 없음** — 측정 도구 없음.

### 1.3 영향

본 RFC 없이는 RFC_LIFECYCLE_SCOPE_REDESIGN 의 각 sub-PR 의 ROI **측정 불가**:
- Sub-PR-L.5 (Symbol.canonical_name 제거) → graph/link/emit 의 *어디서* 얼마 절약?
- Sub-PR-L.7 (graph persistence) → graph phase 의 Release 측정값은?
- Sub-PR-L.9 (emit incremental) → emit phase 의 Release 측정값은?

각 phase 의 *Release 측정값* 없이는 *목표 ms 도 정의 불가*. RFC #3940 의 목표 (graph 146→30ms 등) 가 *Debug 기준* — Release 에선 의미가 다름.

## 2. 제안 — Release Build 에 Profile 활성화 + 측정 도구

### 2.1 핵심 발견

`src/profile.zig` 는 *build mode 무관* 작동:
- `inline fn begin(cat)` — 비활성 category 면 zero-overhead (return empty Scope)
- 활성 category 면 `std.time.Timer.start()` + `atomicAdd` — release build 에서도 동일 작동
- `ZNTC_PROFILE=all` env 가 release build 에서도 활성화 가능

**즉 Release build 에서 profile 측정 이미 가능.** 활용 안 한 게 문제.

### 2.2 dev_server 의 SSE event 에 profile breakdown 추가

현재 `bundle_build_done` SSE event:
```json
{"type":"bundle_build_done","id":"2","totalModules":641,"duration":307.0}
```

제안: `profile` 필드 추가 (opt-in, ZNTC_PROFILE 활성 시):
```json
{
  "type":"bundle_build_done",
  "id":"2",
  "totalModules":641,
  "duration":307.0,
  "profile": {
    "scan_ms": 38.0,
    "parse_ms": 54.0,
    "semantic_ms": 10.0,
    "resolve_ms": 3.0,
    "graph_ms": 146.0,
    "link_ms": 61.0,
    "emit_ms": 80.0,
    "emit_concat_ms": 35.0,
    "emit_module_pass_ms": 12.0,
    "emit_css_ms": 8.0
  }
}
```

watch 모드 (dev_server / NAPI) 의 무한 loop 라 `defer profile.report` 가 main 종료 시 안 호출 → **incremental.zig 의 doBuild 후 SSE event 에 직접 dump**.

### 2.3 bench 도구 강화

`tests/benchmark/devserver-hmr.ts` 에 *phase breakdown* 캡처 추가:
- SSE event 의 `profile` 필드 파싱
- iteration 별 phase 별 ms 출력
- median + percentile 통계

### 2.4 측정 일관성

| 환경 | 적용 |
|---|---|
| Debug build (`zig build test`) | 기존 ZNTC_PROFILE 출력 그대로 (변화 없음) |
| **Release build (dev_server)** | **ZNTC_PROFILE=all 활성화 시 SSE event 에 profile 포함** |
| Release build (CLI bench) | 기존 `--profile` CLI flag 그대로 (변화 없음) |
| Release build (NAPI watch) | `getProfile()` API (현재 미구현, 후속 PR) |

본 RFC scope = dev_server SSE wire-up 만. NAPI / 기타는 후속.

## 3. 변경 영역

### 3.1 `src/profile.zig`

**변경 없음.** 이미 build mode 무관 작동 — 검증만.

### 3.2 `src/bundler/incremental.zig`

`doBuild` 가 build 직후 profile snapshot 캡처 + RebuildResult 에 포함:

```zig
// 신규 RebuildResult field:
.success = .{
    ...
    .profile_snapshot: ?ProfileSnapshot = null,
},

// doBuild 안에서:
var result = bundler.bundle() catch return .fatal;
const _profile = @import("../profile.zig");
const snapshot: ?ProfileSnapshot = if (_profile.anyEnabled()) _profile.takeSnapshot() else null;
_profile.resetCounters();  // 다음 rebuild 측정 위해
```

`ProfileSnapshot` struct = phase 별 ns 의 snapshot (현재 `profile.report` 가 stderr 로 출력하는 데이터를 struct 로 캡처).

### 3.3 `src/server/dev_server.zig`

`bundle_build_done` event 생성 시 profile snapshot 도 JSON 직렬화:

```zig
// 현재:
"{\"type\":\"bundle_build_done\",\"id\":\"{d}\",\"totalModules\":{d},\"duration\":{d:.2}}"

// 신규:
if (rebuild_result.success.profile_snapshot) |snap| {
    // snap.toJsonInto(buf, ...)
    "..,\"profile\":{...}}"
}
```

### 3.4 `tests/benchmark/devserver-hmr.ts`

phase 별 ms 캡처:
```ts
if (j.type === 'bundle_build_done' && j.profile) {
    durations.push(j.duration);
    phases.push(j.profile);
}
```

iteration 후 phase 별 median 출력.

### 3.5 `src/profile.zig` 의 새 API

```zig
pub const ProfileSnapshot = struct {
    phases: [num_categories]u64, // total_ns per category
};

pub fn takeSnapshot() ProfileSnapshot { ... }
pub fn snapshotToJson(snap: ProfileSnapshot, writer: anytype, level: Level) !void { ... }
```

## 4. 측정 목표

본 RFC 자체는 *측정 도구* — ROI 는 *후속 sub-PR 의 ROI 측정 가능* 그 자체.

검증:
1. ZNTC_PROFILE=all + dev_server 실행 시 SSE event 에 phase breakdown 포함
2. lodash dev_server 의 *Release 측정* 의 phase 분포 첫 확정
3. 본 RFC 의 산출물 = "**lodash incremental rebuild 의 Release 측정 phase 분포**" 데이터

## 5. 단계별 PR 분할

**Sub-PR-L.0a**: ProfileSnapshot API (S, 영향 0)
- `profile.zig` 에 `takeSnapshot` + `snapshotToJson` 추가
- 단위 테스트
- 호출자 없음

**Sub-PR-L.0b**: incremental.zig 가 ProfileSnapshot 캡처 (S)
- RebuildResult 에 profile_snapshot field 추가
- doBuild 에서 캡처

**Sub-PR-L.0c**: dev_server SSE event 에 profile JSON (M)
- bundle_build_done event 에 profile 필드
- ZNTC_PROFILE 활성 시만 포함 (default off, 영향 0)

**Sub-PR-L.0d**: devserver-hmr.ts bench 강화 (S)
- phase 별 median 출력
- baseline 측정 — **lodash incremental rebuild 의 Release phase 분포 첫 확정**

**Sub-PR-L.0e**: NAPI watch profile API (S, 후속)
- `getProfile()` API on WatchHandle
- @zntc/core 의 TS type 추가

## 6. 회귀 가드

- Profile 비활성 (default) 시 zero overhead 검증 — bench corpus 의 measurement (예: bundle-perf) 변화 없음
- Profile 활성 시 dev_server SSE event JSON schema 정확성 (TypeScript type 으로 검증)
- ZNTC_PROFILE 의 environment variable 처리 정확성

## 7. React Native 영향

| Sub-PR | RN 영향 |
|---|---|
| L.0a (ProfileSnapshot API) | 0 |
| L.0b (incremental.zig 캡처) | 0 (default off) |
| L.0c (dev_server SSE) | 0 (dev_server 는 web only) |
| L.0d (bench) | 0 |
| L.0e (NAPI watch) | **잠재 가치** — RN HMR 의 phase breakdown 도 같은 방식 측정 가능 |

## 8. 정책 / 결정

### Out of scope

- **external profiler 통합** (samply / Instruments / dtrace) — 별도 영역
- **persistent profile log** (디스크 저장) — 후속 옵션
- **Debug 측정의 정확성 개선** — 본 RFC 는 Release 측정 활성화만

### 진짜 의의

본 RFC 없이는 RFC_LIFECYCLE_SCOPE_REDESIGN 의 각 sub-PR ROI 측정 불가. *모든 sub-PR 이 sub-PR-C.2 처럼 noise 안에 묻힘 가능성*.

본 RFC 머지 후 첫 *Release phase 측정* — *RFC #3940 의 각 phase 목표 ms 가 Debug 기준 추정* 인 점 정정. *진짜 measurement-first epic* 가능.

### NO-GO 시나리오

- Release 측정의 phase 별 ms 가 noise (예: < 1ms 단위) → 측정 도구 자체로 의미 없음
- 또는 profile overhead 가 wall 의 5% 이상 → 측정 invariant 깨짐 (측정 자체가 측정 대상 영향)

이 경우 본 RFC 도 closed → external profiler 영역 (samply 등) 으로 전환.

### 진행 순서

L.0a → L.0b → L.0c (병행 가능) → L.0d 측정 → 확정 후 RFC #3940 의 Phase 1 (audit + measurement baseline) 진행.
