# RFC: Dev Server Incremental Rebuild 재설계 (emit/graph cache-aware path)

상태: **DRAFT · 측정 기반 epic 시작** · 분류: dev UX / core 재설계
관련: `incremental.zig`, `dev_server.zig`, `bundler.zig`, `bundler/graph/build_flow.zig`, `bundler/emitter.zig`

## 1. 문제 (실측 확정)

ZNTC dev server HMR latency 가 큰 의존성 graph 에서 경쟁사 대비 결정적 손해.

### 측정 (lodash 641 modules, 2026-05-28, macOS arm64, ReleaseFast)

세 가지 *서로 다른 path* 의 측정. 직접 비교는 같은 path 끼리만 의미 있음:

**A) In-process programmatic API (worker thread / event subscription):**
| 도구 | tiny | lodash |
|---|---|---|
| esbuild `ctx.rebuild()` | 8.85ms | **50.3ms** |
| rolldown `watch()` event | 24ms | 59ms |
| ZNTC NAPI `watch()` callback | 54ms | 69ms |

**B) Dev server full HMR loop (WS subscribe + diff broadcast):**
| 도구 | tiny | lodash |
|---|---|---|
| **ZNTC `zntc dev` HMR WS** | **9.55ms** | **398ms** |
| esbuild `--serve` | 미측정 (별도 PR) |
| Vite (rolldown 기반) dev | 미측정 (별도 PR) |

**C) CLI watch (production-like build + fs polling):**
| 도구 | tiny | lodash |
|---|---|---|
| ZNTC `--watch` (500ms 폴링) | 311ms | 475ms |
| esbuild `--watch=forever` | 10ms | 54ms |
| rolldown `--watch` | 24ms | 0.1ms (cache hit) |

핵심 — A 와 B 비교는 path 가 달라 직접 비교 불가. ZNTC NAPI (A 의 in-process) = 69ms 가 ZNTC dev_server (B 의 WS HMR loop) = 398ms 보다 5.8× 빠름 → **path 별 격차의 진짜 root 가 IncrementalBundler 추상화 측면에 있음**. CLI 의 폴링 결함 (D048) 과 별개 root (별도 RFC).

### Phase breakdown — Cold vs Incremental (no-minify)

| Phase | Cold Σ (ms) | Incremental Σ (ms) | Δ |
|---|---|---|---|
| scan | 38 | 38 | 0 (cache 효과 없음) |
| parse | 89 | 54 | 35 saved |
| semantic | 87 | 10 | 77 saved |
| resolve | 191 | 2 | 189 saved |
| graph | 118 | **146** | **-28 (oversold)** |
| link | 62 | 61 | 1 |
| metadata | 2256 *(minify cold)* / 93 *(no-minify cold)* | 0.15 | full saved |
| transform | 459 *(minify)* / 70 *(no-minify)* | 0.17 | full saved |
| **emit** | **33** *(no-minify)* | **172** | **-139 (5.2× 손해)** |
| **TOTAL (Σ threads)** | ~580 | **382** | -34% |
| **WALL** | **214** | **398** | **+86% (1.86× 느림)** |

**핵심:** Σ 는 줄어드는데 *WALL 은 증가*. parallel speedup 가 cold 18.9× → incremental 0.96× 로 무너짐.

## 2. 루트커즈 분석

### 가설 1 (부분만 맞음): `changed_files` 만 미전달

dev_server 가 watcher event path 를 bundler 에 전달 안 함. NAPI watch (`packages/core/src/napi/watch.zig:1135`) 는 전달.

**`changed_files` 단독 wire-up 측정 결과: 효과 0.** lodash rebuild 401→401ms. 내장 incremental-bench (`zig build test` 출력) 재확인:

```
lodash-es 641 module, 3 case warm:
  warm null   : discover=27909us  (changed_files=null, 641 stat)
  warm empty  : discover=26378us  (changed_files={}, no-change)
  warm single : discover=26853us  (changed_files={1 path})
```

stat skip ratio 94-96% 인데 *discover 시간 차이는 5%* (~1.5ms). mtime stat 비용 자체가 매우 작음. **그러나 `changed_files` 는 NAPI 의 dev_mode 3-option 패키지의 일부일 뿐 — 단독으로는 효과 없음 (가설 2 참조).**

### 가설 2 (확정 — 진짜 root 추정): dev_server 가 NAPI 의 dev_mode 최적화 3종을 미활용

**NAPI watch lodash = 69ms vs dev_server lodash = 398ms (5.8× 격차).** 같은 graph (같은 lodash 641 modules) 측정 — graph 구조 차이 아님. 차이는 *path 의 옵션 활용*:

| 옵션 | NAPI watch | dev_server | 영향 |
|---|---|---|---|
| `incremental_opts.changed_files = &touched` | ✓ `watch.zig:1135` | ✗ 미전달 | ~1.5ms (가설 1 측정) |
| `incremental_opts.sourcemap.lazy = true` | ✓ `watch.zig:1138` | ✗ 미설정 | lazy SM finalize 효과 (정량 측정 필요) |
| **`incremental_opts.skip_bundle_output = true`** | ✓ `watch.zig:1142` | ✗ 미설정 | **emit_concat ~38ms + emit_sourcemap_finalize ~19ms 절감** (NAPI 코멘트 명시) |

NAPI watch.zig:1139-1142 코멘트 인용:
> `dev_mode + collect_module_codes 인 incremental rebuild 는 풀 bundle output 을 다시 concat 할 필요가 없다 — RN HMR client 는 dev_codes 만 사용. wall 시간이 emit_concat (~38ms) + emit_sourcemap_finalize (~19ms) 를 절감한다.`

웹 dev server 도 RN HMR client 와 동일 — `module_dev_codes` 만 broadcast 함 (`buildHmrUpdateFromModules`). 즉 같은 invariant 가 성립하지만 dev_server 가 옵션을 wire-up 하지 않아 *full bundle concat 을 매 rebuild 마다 수행*.

### 가설 2 (확정): cache hit path 자체가 cold path 보다 비싸다

cold no-minify lodash 의 `emit` Σ = 33ms. incremental 의 `emit` Σ = 172ms. **같은 emit 코드인데 incremental 이 5.2× 손해.**

원인 추정:
- `emit_module_pass` (`emitter.zig:563`): 매 rebuild 마다 *전체 641 모듈* 의 emit wrapper 재실행. compiled_cache 가 lookup 되더라도 module-level 처리 cost 자체가 있음.
- `emit_output` (`bundler.zig:1496`): 단일 chunk 안에 모든 모듈 emit. count=1 = chunk-level parallel 불가.
- `graph.buildIncremental` (`build_flow.zig:631`): 모든 모듈 walk + cache hit struct assign. 641 모듈 sequential.

### 가설 3 (확정, 단 가설 2 가 우선): parallel speedup 가 incremental 에서 깨짐

cold Σ/wall = 18.9× (thread pool 풀 활용). incremental Σ/wall = 0.96× (사실상 single thread).

`build_flow.zig:685` 의 주석: *"순차 처리 — 증분 빌드는 캐시 히트가 대부분이므로 스레드 풀 오버헤드보다 효율적"* — 이 가정이 N=641 같은 큰 case 에서 깨짐.

### 진짜 root cause (내장 bench 데이터로 확정)

내장 incremental-bench (lodash 641 module warm) 의 sub-phase 분해:

```
warm discover = 27ms (cold 242ms 의 11%)
  mtime           = 1.5ms (5%)    ← changed_files set 으로 줄일 수 있는 부분
  cache_lookup    = 0.2ms (1%)
  cache_hit_assign= 0.3ms (1%)
  replay          = 25.6ms (96%)  ← 진짜 병목
    add_module    = 8.2ms (32% of replay)
    request_export= 9.8ms (38% of replay)
      re_export   = 7.5ms (77% of request_export)
        copy      = 6.0ms (80% of re_export)
    record_dep    = 0.7ms (2% of replay)
```

**진짜 병목 = `replay` phase (96% of discover).** 모듈 단위 cache 는 hit 하지만 *graph edge 들을 매 rebuild 마다 재구성* — `add_module` (모듈 → graph 에 추가), `request_export` (export 요청 replay, 그 안에 re-export 카피), `record_dep` (의존성 edge 재기록).

**ZNTC incremental rebuild 모델 자체가 "cache hit per module + graph edge replay" 임.** esbuild 식 *"dirty marking + chunk-level diff emit"* 모델이 아니라, 매 rebuild 가 *전체 graph edge replay + 전체 emit* 을 수행하고 *모듈 AST 단위 cache* 만 hit. 그래서:

- Σ 시간은 cache 로 줄지만
- WALL 은 *sequential 641-module walk + single-chunk emit* 으로 결정됨
- 큰 graph 에서 cold WALL 보다 더 느림 (parallel 효과 손실)

**이 모델 변경 없이는 stat / dedup / mtime 차원의 fix 들은 모두 측정 가능한 효과 안 만듦.**

## 3. 제안 — Cache-Aware Path 재설계

### 핵심 원칙

1. **Dirty marking** — `changed_files` 가 알려준 path 들로부터 시작해 *변경 영향 graph segment* 를 마킹. 영향 받지 않은 모듈은 *완전히 skip* (walk 도 X).
2. **Diff emit** — 변경 영향 chunk 만 re-emit. 다른 chunk 는 byte stream 그대로 재사용.
3. **Parallelism 회복** — incremental walk 도 chunk 단위 parallel 가능 (스레드 풀 활용).

### 단계별 PR 분할

**PR-A: dev_server.watchLoop 가 NAPI 의 dev_mode 3-옵션 패키지 wire-up** *(진짜 PR-A — 가설 2 fix)*
- `IncrementalBundler.rebuild(changed_files)` 시그니처 + dev_server 가 전달 (가설 1 wire-up 자체는 효과 미미하지만 dev_mode 패키지의 일부)
- `IncrementalBundler` 가 dev_mode + collect_module_codes 일 때 `skip_bundle_output=true` + `sourcemap.lazy=true` 자동 적용 (NAPI watch.zig:1138-1142 패턴 그대로)
- 측정 목표: lodash dev_server HMR 398ms → ~330ms 이내 (가설 2 의 ~57ms 절약). 측정 결과로 PR-C 의 필요성 재판단
- 크기: S — NAPI 의 검증된 패턴 양도
- 가드: 회귀 fixture 로 *dev_codes 가 full bundle 과 동일한 wire form* 보장 (skip_bundle_output 가 HMR client 에 잘못된 payload 안 보내는지)

**PR-B: graph dirty walk (build_flow.zig:685 의 sequential loop 우회)**
- `changed_files` set 의 모듈 + 그 직접 ancestor/descendant 만 walk
- 나머지 모듈은 cache hit 으로 skip (struct assign 도 안 함, 이전 상태 그대로 reuse)
- 측정 목표: graph 146ms → ~30ms
- 크기: M, RFC 후속 단일 PR

**PR-C: emit chunk-level dirty marking** *(가장 큰 영향)*
- chunk-level cache: 변경 모듈이 포함되지 않은 chunk 는 *이전 emit byte stream 그대로 재사용*
- `emit_module_pass` 가 chunk 별 dirty bit 검사 후 dirty chunk 만 처리
- 측정 목표: emit 172ms → ~20ms
- 크기: L, 별도 RFC sub-doc 필요, 여러 sub-PR 로 분할

**PR-D: incremental walk parallelize (build_flow.zig:685)**
- N=641 큰 graph 에서 cache hit walk 도 thread pool 활용
- 작은 case (N<50) 는 기존 sequential 유지 (threshold)
- 측정 목표: graph cache hit walk 도 parallel speedup
- 크기: M

**PR-E: scan re-lex 제거**
- cold 와 incremental 의 scan profile 가 동일 (38ms) — cache hit 모듈이 매번 re-lex
- 원인 추적 후 cache 도입
- 측정 목표: scan 38ms → 0ms
- 크기: S

### 측정 목표 (RFC 전체 epic 완료 후)

| Phase | 현재 (incremental) | 목표 | 회수치 |
|---|---|---|---|
| scan | 38 | 0 | -38 |
| graph | 146 | 30 | -116 |
| emit | 172 | 20 | -152 |
| WALL | **398ms** | **~80ms** | **-318ms (5× 빠름)** |

esbuild lodash 50ms 와 동등 수준 (~1.6× 거리) 도달. dev_server HMR 마케팅상 "esbuild parity" 카드 확보.

## 4. PoC 계획

### Step 1 — emit_module_pass / emit_output 코드 정밀 독해

`emitter.zig:563` 의 emit_module_pass 가 *어떤 작업* 을 모듈마다 수행하는지 정확히 파악. 가능한 영역:
- runtime wrapper inject
- import/export hoist
- sourcemap segment generation
- minify pass (해당 모드일 때만)

각 작업의 cache-할 수 있는 단위 식별.

### Step 2 — chunk-level dirty marking PoC

작은 fixture (tiny + medium + lodash 3종) 에서 chunk-level cache 시뮬레이션:
- BundleResult 의 chunk 별 byte stream 캐시
- 변경 모듈 path → 영향 받는 chunk set 추적
- non-impacted chunk 는 캐시된 byte stream 재사용

ROI 선검증 — emit 172ms → ?ms 측정. 30ms 이내 도달 가능하면 GO.

### Step 3 — graph dirty walk PoC

`build_flow.zig:685` 의 walk 를 `changed_files` set 기반으로 변경:
- `changed_files` 의 path 만 cache miss check
- 나머지는 skip (cache 'still fresh' 가정)
- 의존성 변경 (새 import) 감지 시 full rebuild fallback

ROI 측정 — graph 146ms → ?ms.

### Step 4 — RFC 본격 구현 PRs

PoC GO 판정 후 PR-B / PR-C 본격. RFC § 3 의 단계별 분할 그대로.

## 5. 회귀 가드

### bench 가드 (follow-up PR 들에서 제공)

본 RFC 머지 시점에는 bench 도구가 *아직 활성 회귀 가드 아님*. PoC + 본격 구현 PR 들이 bench 도구와 함께 와야 함:

- **bench PR-α**: `tests/benchmark/napi-watch.ts` + `incremental-rebuild.ts` — NAPI/CLI 측정 도구 (단순, 검증 완료)
- **bench PR-β**: `tests/benchmark/devserver-hmr.ts` + `inprocess-rebuild.ts` — dev server WS + 공정 in-process 비교 (실행 가능성 fix 필요, esbuild --serve / vite dev tool 추가 필요)
- **bench PR-γ**: bench 도구들에 threshold-based 회귀 가드 (예: `--check-regression --baseline=baseline.json`) 추가 → CI 가 자동 catch
- bench PR-α/β/γ 가 본격 RFC 구현 PR (PR-B/PR-C) *이전* 에 머지돼야 회귀 가드로 기능

bench PR-α 가 가장 단순 — 측정 코드는 본 RFC 작성 중 작동 검증됨 (lodash 398ms 데이터 출처).

### 정확성 가드

- ZNTC dev server HMR 회귀 fixture: tiny / medium / lodash + 모듈 graph 변경 (새 import 추가) → full reload fallback 정상 동작
- chunk 단위 cache invalidation 정확성 — dirty marking 누락 시 stale chunk 가 serve 되면 안 됨

### kill-switch

각 PR 에 환경 변수 fallback (`ZNTC_INCREMENTAL_LEGACY=1`) — 기존 path 로 즉시 복귀 가능.

## 6. 정책 / 결정

### Out of scope (별도 RFC)

- **CLI `--watch` 의 500ms 폴링 제거** (D048 후속) — file_watcher.zig kqueue/inotify 가 이미 dev_server 영역에 있음. CLI 에 이식만 하면 됨. M 작업, 별도 PR. 본 RFC 영역 외.
- **mangler size gap** — RFC_MANGLER_SIZE_GAP_CLOSED.md 종결 영역. 본 RFC 와 무관.

### React Native 영향

| 영역 | RN 영향 | 비고 |
|---|---|---|
| RFC scope 의 web dev_server (`zntc dev`) | **0 (RN 미사용)** | RN HMR 은 NAPI watch path (`packages/core/src/napi/watch.zig`) 사용 |
| RN HMR 현황 | **이미 좋음 (~69ms lodash NAPI 측정)** | NAPI watch 가 이미 `changed_files` 전달 (line 1135). RFC 의 가설 1 = NAPI 가 이미 구현한 패턴 |
| PR-A (incremental.zig wire-up) | 0 | RN 은 IncrementalBundler 추상화 안 씀 |
| PR-B (graph dirty walk) | 0 | graph 영역, NAPI 의 자체 incremental loop 와 분리 |
| **PR-C (emit chunk-level dirty)** | **있음 — risk 영역** | emit 은 공유 코드. RN-specific 분기 보존 필수: `rn_codegen_plugin`, `RN_DEFAULT_ASSET_REGISTRY`, Hermes bytecode emit, Metro serializer 호환성, runtime helper |
| PR-D (parallel walk) | 0 | graph 영역 |
| PR-E (scan re-lex) | 0 | lex 영역, platform 중립 |

**PR-C 의 RN 가드 (필수):**
- 회귀 가드 fixture 에 RN bare/large/expo 3 종 추가 (Re.pack vs ZNTC RN0.85 측정 매트릭스 재사용)
- RN bundle 의 module dev_codes 가 *chunk dirty marking* 이후에도 ZNTC 의 `__zntc_register` 등 dev wrapper 형식 그대로 유지하는지 정확성 가드 (Metro `__d(...)` 형식과는 별개 — ZNTC 는 자체 wrapper)
- `--platform=react-native` + chunk-level emit cache 통합 케이스 e2e 테스트

**RN 사용자 관점:**
- 현재 (NAPI watch path): 이미 esbuild parity 근처 — 본 RFC 와 무관하게 좋음
- PR-C 머지 후: emit 공유 코드 변경 → RN 도 함께 우위 가능 (양산). 단 회귀 risk 가 가장 큰 영역. PR-C kill-switch (`ZNTC_INCREMENTAL_LEGACY=1`) 를 RN platform 에 자동 활성화하는 옵션도 고려.

### 결정

본 RFC 가 *측정 기반 epic* 시작. PoC (Step 2 + Step 3) 결과로 본격 진행 / NO-GO 결정. 측정으로 닫혀도 데이터는 본 RFC 에 결정 문서로 남김.

### 신호

- 진짜 GO: PoC emit chunk-level dirty 가 lodash 172ms → 30ms 이내 달성
- NO-GO: chunk-level dirty marking 의 invalidation 정확성이 구조적으로 깨짐, 또는 ROI < 50ms 절약

PoC 시작 1주, GO 판정 후 본격 1-2주.
