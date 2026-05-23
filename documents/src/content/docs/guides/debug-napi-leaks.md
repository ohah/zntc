---
title: NAPI 누수 측정 (Debug GPA leak detector)
description: dev/watch RSS 누수 / NAPI native_alloc 누수 추적용 측정 도구 사용법 — Debug 빌드 한정 std.heap.DebugAllocator + atexit dump
---

ZNTC 내부 contributor 용 측정 인프라. `packages/core/src/napi/common.zig` 의
`debug_gpa` (Debug 빌드 한정, `std.heap.DebugAllocator`) 가 모든 NAPI 진입점
의 `native_alloc` 을 공유, process 종료 시 `atexit` 가 `detectLeaks()` 호출
→ stack trace 포함 leak 리포트를 stderr 로 dump.

**Production 사용자 영향 0** — ReleaseFast 빌드는 `comptime builtin.mode != .Debug`
early-out 으로 dead code 제거, `std.heap.c_allocator` 그대로 사용.

## 언제 쓰나

- `zntc dev` / `zntc watch` 의 RSS 가 시간 따라 증가 (외부 측정 `ps -o rss=`,
  `process.memoryUsage()` 의 `rss` 필드)
- `process.memoryUsage()` 의 `heapUsed` / `external` / `arrayBuffers` 는 안정
  하지만 `rss` 만 증가 → V8 측이 아닌 NAPI 측의 native_alloc 누수 의심
- transpile worker / bundler / plugin 같은 NAPI 호출 빈도 높은 영역의 누수
  추적

## 활성화

```bash
zig build napi -Dnapi-optimize=Debug
cp zig-out/lib/zntc.node packages/core/zntc.node
```

`-Dnapi-optimize=Debug` 가 핵심 — default `ReleaseFast` 는 c_allocator 사용,
측정 도구 비활성.

## 1분 dev probe 측정 스크립트

```bash
mkdir -p /tmp/leak-probe
cd examples/web

# touch-probe marker 1회 setup
grep -q "// touch-probe" src/App.tsx || echo "// touch-probe 0" >> src/App.tsx

# dev background 실행
nohup bun run dev > /tmp/leak-probe/stdout.log 2> /tmp/leak-probe/stderr.log &
DEV_PID=$!
sleep 5  # warmup

# 3s 간격 touch 루프 × 20회 = 1분 (rebuild trigger)
for i in $(seq 1 20); do
  sed -i.bak "s|// touch-probe .*|// touch-probe $i|" src/App.tsx
  sleep 3
done

# SIGTERM → atexit 발화 → leak dump
kill -TERM $DEV_PID
sleep 3
kill -KILL $DEV_PID 2>/dev/null
wait $DEV_PID 2>/dev/null

# cleanup marker
sed -i.bak '/\/\/ touch-probe/d' src/App.tsx && rm -f src/App.tsx.bak

# 결과 분석
echo "rebuilt:      $(grep -c rebuilt /tmp/leak-probe/stderr.log)"
echo "leak entries: $(grep -c 'error(gpa): memory address' /tmp/leak-probe/stderr.log)"
echo "panics:       $(grep -ciE 'panic|invalid free|abort|segfault' /tmp/leak-probe/stderr.log)"

# leak alloc-site 분포 (가장 자주 발생하는 누수 상위 20개)
grep "in _" /tmp/leak-probe/stderr.log | sort | uniq -c | sort -rn | head -20
```

**정상 기준** (회귀 가드):

| 지표 | 기대값 |
|---|---|
| `leak entries` | `0` |
| `panics` | `0` |
| `rebuilt` | `20` (정상 watch trigger) |

## Leak 리포트 해석

```text
error(gpa): memory address 0x1234 leaked:
    0xABC in _bundler.fs.RealFS.listDir (???)
    0xDEF in _bundler.fs.listDir (???)
    0x123 in _bundler.resolver.DirEntryCache.buildEntrySet (???)
    ...
    0x789 in _napi.build_sync_entry.napiBuildSync (???)
```

bottom-up stack trace — NAPI 진입점 (가장 깊은 프레임) 부터 실제 누수 alloc
함수 (가장 얕은 프레임) 까지의 chain.

`stack_trace_frames = 16` 으로 설정 (common.zig 에서 변경 가능) — default 6
은 HashMap 같은 자료구조 내부 6 프레임에 caller 가 가려져 불충분.

## 측정 시 trade-off

**임시 디버깅 인프라** 라 다음 trade-off 수용:

- **RSS 인플레이션**: DebugAllocator stack-trace metadata (per-alloc ~128B) +
  *never reuse memory addresses* 정책. ReleaseFast c_allocator baseline 과
  **직접 비교 금지**. Debug↔Debug, before↔after fix delta 만 valid
- **perf 왜곡**: `thread_safe=true` mutex 로 모든 alloc 직렬화. wall-clock /
  sub-phase ns 절대값 무의미, 상대 ratio 만
- **SIGTERM atexit 발동**: 호스트 런타임 의존. Bun 환경 검증, Node 환경에선
  `process.exit(0)` 명시 권장
- **`tryLock`-based detectLeaks**: worker thread 가 mid-alloc 시 leak dump
  일부 손실 (희박, deadlock 회피 trade-off)
- **shutdown noise**: watch 의 long-lived cache (`PersistentModuleStore` /
  `ResolveCache` 등) `handle.stop()` 없이 종료 시 의도된 retention 이 leak
  으로 표시 — manualChunks / persistent cache 사용 시 측정자 noise

## EPIC 결과 (2026-05-23, 9 PR 누적)

dev/watch RSS 233MB/5분 누수 epic close. 핵심 root cause:

**`Bundler.deinit()` 누락 — 3 사이트 / 3줄**

```zig
// packages/core/src/napi/watch.zig:534
// packages/core/src/napi/build_sync_entry.zig:81
// packages/core/src/napi/build_async_entry.zig:51 (worker thread)

var bundler = Bundler.init(allocator, opts);
defer bundler.deinit();  // ← 이 줄이 빠져있었음
var result = bundler.bundle() catch ...;
```

`Bundler.init` 가 내부적으로 owned `ResolveCache` (= `DirEntryCache` +
`RealpathCache` + cache_shards) 를 생성. `Bundler.deinit` 가 `resolve_cache_ref
== null` (owned 인 경우) 일 때 `resolve_cache.deinit()` cascade → 모든 cache
정리. `Bundler.deinit` 미호출 시 그 모든 cache 가 process 종료까지 누수.

**측정 도구의 가치**: 코드 reading 만으로는 `Bundler.init` 후 `result` 만
처리하는 패턴이 자연스러워 보여 root 식별 어려움. measurement stack trace
가 `dupe ← listDir ← DirEntryCache.buildEntrySet ← ResolveCache → Bundler.bundle()
← napiBuildSync` chain 을 정확히 보여줘서 ownership 추적 가능. 추측 fix 0회로
3줄 fix 완료.

## 향후 활용 (재사용)

다른 영역의 native_alloc 누수 의심 시:

1. examples/ 의 해당 시나리오 (web / RN bundle / library build / plugin
   사용) 1분 probe 실행
2. `leak entries > 0` 또는 `panics > 0` 시 stack trace 분석
3. NAPI 진입점 (가장 깊은 frame) → alloc 함수 (가장 얕은 frame) chain 으로
   ownership 추적
4. `Bundler.deinit` / `ResolveCache.deinit` / 사용자 정의 cache 의 deinit
   호출 누락 패턴 확인

회귀 가드로 PR CI 또는 nightly 에서 위 스크립트 자동화 + `leak entries == 0`
assertion 추가 가능 (현재 수동).

## 관련 자료

- 저장소 내부: [`docs/DEBUG.md`](https://github.com/ohah/zntc/blob/main/docs/DEBUG.md) 의 동일 섹션
- 측정 인프라 코드: [`packages/core/src/napi/common.zig`](https://github.com/ohah/zntc/blob/main/packages/core/src/napi/common.zig)
  의 `debug_gpa` / `nativeAlloc` / `dumpLeaksAtExit` / `registerLeakDump`
- 9 PR EPIC history: PR #3691 / #3695 / #3696 / #3705 / #3707 / #3709 / #3711 /
  #3713
