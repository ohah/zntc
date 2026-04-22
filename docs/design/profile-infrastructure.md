# Profile & Benchmark Infrastructure 설계

> **Status**: design agreed (2026-04-22) — 구현 시작 예정
> **Owner**: @ohah
> **Related epics**: `#1672` (transformer), HMR performance roadmap

## 1. 배경

### 1.1 현재 측정 인프라의 파편화

ZTS 에는 여러 측정 도구가 독립적으로 존재한다:

| 도구 | 범위 | 상세도 |
|------|------|--------|
| `src/debug_log.zig` | 카테고리 토글 로그 (`compiled_cache`, `ast_mutation`) | 이벤트 로그 (타이밍 아님) |
| `--timing` CLI | single-file transpile | `scan / parse / semantic / transform / codegen` 5단계 |
| `BundleTimings` struct | bundle 모드 내부 | `graph_ns / link_ns / shake_ns / emit_ns` 4 field |
| HMR `phaseDurations` | NAPI watch 이벤트 | `detect / graph / link / shake / emit / delta / total` + sub |
| `BUNGAE_HMR_PROFILE=1` | 번개 opt-in 로그 | phase breakdown 한 줄 |

### 1.2 파편화의 문제

1. **의미 혼재 (해소, 2026-04-22)**: 이전엔 `phaseDurations.parse` 가 graph build 전체 (resolve + parse + semantic + finalize), `phaseDurations.sem` 은 link + shake 였다. 기본 phase 를 `graph`/`link`/`shake` 로 분리하고 sub-phase 의 `parse`/`semantic` 은 진짜 parser/analyzer 시간을 의미하도록 rename 완료.
2. **CLI ↔ NAPI 불일치**: `--timing` 은 single-file 만. NAPI watch 는 HMR 전용 포맷. 공통 출력 형식/옵션 없음.
3. **Sub-phase 없음**: `emit 67ms` 안의 transform / codegen / metadata 비중 모름.
4. **벤치마크 부재**: 특정 phase 만 반복 측정하는 도구가 없음. 최적화 전후 비교 수동.
5. **활성화 방식 파편화**: `ZTS_DEBUG=`, `--timing`, `BUNGAE_HMR_PROFILE=1`, `BundleOptions.debug` 각각 다른 규칙.

### 1.3 요구사항 (2026-04-22 합의)

1. **모든 진입점 (CLI / NAPI / env) 에서 활성 가능**
2. **CLI ↔ NAPI feature parity** — 같은 기능 같은 방식
3. **Category 별 활성화** — 특정 phase 만 측정 가능
4. **Sub-phase 계층적 상세도** — summary / detailed / per-module / per-pass
5. **Phase 격리 실행** — `--stop-after` 또는 `zts bench` 로 특정 phase 만 반복 측정
6. **통계 기반 벤치마크** — mean/median/p95/stddev + baseline save/compare
7. **상세한 CLI help + 문서** — 모든 옵션에 예제
8. **Zero-overhead when disabled** — Release 빌드에서 비활성 category 는 branch 한 번
9. **확실한 테스트** — 유닛 + 통합 + CLI ⟷ NAPI parity
10. **기존 `--timing` / `BundleTimings` 구조 제거** — `--profile` 로 통일 (출시 전이므로 breaking OK)

---

## 2. 설계

### 2.1 3축 모델

프로파일링은 **세 개의 독립적 축** 으로 구성:

```
┌──────────────────────────────────────────────────────┐
│ Axis 1: Entry Point                                  │
│   CLI --profile=... | NAPI option | ZTS_PROFILE env  │
└──────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────┐
│ Axis 2: Category (무엇을 측정)                        │
│   scan / parse / semantic / transform / codegen /    │
│   link / shake / emit / hmr / cache / all            │
│   (dot notation: transform.jsx, parse.scan, ...)     │
└──────────────────────────────────────────────────────┘
                         ↓
┌──────────────────────────────────────────────────────┐
│ Axis 3: Level (얼마나 깊이)                           │
│   summary | detailed | per-module | per-pass         │
└──────────────────────────────────────────────────────┘
```

### 2.2 Category 전체 목록

| Category | 측정 대상 | 구현 위치 |
|----------|---------|-----------|
| `scan` | Scanner tokenization | `src/lexer/scanner.zig` |
| `parse` | Parser AST build | `src/parser/parser.zig` |
| `parse.ast_build` | AST 노드 구축 (detailed) | ibid |
| `semantic` | Semantic analyzer (scope/symbol) | `src/semantic/analyzer.zig` |
| `resolve` | Dependency resolution | `src/bundler/graph.zig` |
| `graph` | Module graph build (resolve + parse + semantic 상위) | `src/bundler/graph.zig` |
| `link` | Linker (scope hoisting) | `src/bundler/linker.zig` |
| `shake` | Tree shaker | `src/bundler/tree_shaker.zig` |
| `transform` | Transformer 전체 | `src/transformer/transformer.zig` |
| `transform.ts_strip` | TS 타입 스트리핑 (detailed) | ibid |
| `transform.jsx` | JSX lowering (detailed) | ibid |
| `transform.class_field` | Class field transform (detailed) | ibid |
| `transform.decorator` | Decorator transform (detailed) | ibid |
| `transform.pass2` | `lowerAllFunctionParams` (detailed) | ibid |
| `codegen` | Codegen emit | `src/codegen/codegen.zig` |
| `codegen.walk` | AST walk (detailed) | ibid |
| `codegen.sourcemap` | Source map construction (detailed) | ibid |
| `metadata` | Linker metadata build | `src/bundler/emitter.zig` |
| `emit` | `transform + codegen + metadata` 상위 | `src/bundler/emitter.zig` |
| `hmr` | HMR watch loop 전체 | `packages/core/src/napi_entry.zig` |
| `hmr.detect` | File watcher debounce (detailed) | ibid |
| `hmr.delta` | HMR payload build (detailed) | ibid |
| `cache` | compiled_cache hit/miss events | `src/bundler/compiled_module.zig` |
| `all` | 위 모든 category 합집합 (키워드) | — |
| `none` | 비활성 (기본값) | — |

**Dot notation 규칙**:
- Parent category 활성화 → child 자동 활성 (`parse` 켜면 `parse.ast_build` 도 수집)
- Child 만 선별 활성 가능 (`parse.ast_build` 만 지정하면 parse 의 다른 sub 제외)

### 2.3 Level

| Level | 의미 |
|-------|------|
| `summary` | Phase 총합만 (default) |
| `detailed` | Sub-phase 까지 표시 |
| `per-module` | 모듈별 breakdown |
| `per-pass` | Transformer pass 별 (visit 함수 수준) |

### 2.4 핵심 API (`src/profile.zig`)

```zig
pub const Category = enum {
    scan, parse, semantic, resolve, graph,
    link, shake, transform, codegen, metadata, emit,
    hmr, cache,
    // ... sub-categories
};

pub const Level = enum { summary, detailed, per_module, per_pass };

/// Scope 는 RAII-style timer.
pub const Scope = struct {
    timer: ?std.time.Timer = null,
    cat: Category = .none,
    parent: ?Category = null,

    pub fn end(self: *Scope) void { ... }
};

/// Hot path 용 inline 함수 — 비활성 category 면 zero-cost branch.
pub inline fn begin(cat: Category) Scope {
    if (!enabled(cat)) return .{};  // no-op sentinel
    return Scope.start(cat);
}

/// Per-module 추적용 (예: emit 안에서 모듈별 시간).
pub inline fn beginPerModule(cat: Category, module_path: []const u8) Scope { ... }

/// 활성화 API (CLI/NAPI/env 공용).
pub fn addCategories(names: []const []const u8) void;
pub fn addFromCsv(csv: []const u8) void;
pub fn initFromEnv(allocator: std.mem.Allocator) void;  // ZTS_PROFILE 읽음
pub fn setLevel(level: Level) void;

/// Reporting.
pub fn report(writer: anytype, format: Format) !void;

pub const Format = enum { table, tree, json, csv };
```

### 2.5 사용자 입장 API

#### CLI

```bash
# Summary (기존 --timing 완전 대체)
zts transpile --profile=all ./input.ts

# 특정 category 만
zts transpile --profile=parse,transform ./input.ts

# 상세 level
zts transpile --profile=all --profile-level=detailed ./input.ts

# JSON output (스크립트 용)
zts bundle --profile=all --profile-format=json ./src/index.ts

# 특정 phase 까지만 실행
zts transpile --stop-after=semantic ./input.ts

# Repeat-measure benchmark
zts bench --phase=parse --iterations=100 ./App.tsx
zts bench --phase=parse --iterations=100 ./App.tsx --save=./baseline.json
zts bench --phase=parse --iterations=100 ./App.tsx --compare=./baseline.json
```

#### NAPI

```typescript
// Profile
const result = await bundle({
    entryPoints: ["./src/index.ts"],
    profile: ["parse", "transform"],
    profileLevel: "detailed",
    profileFormat: "json",  // optional: returns structured timings
});
console.log(result.timings);  // { parse: { total_ms, sub_phases: [...] }, ... }

// Stop-after (partial pipeline)
const partial = await transpile({
    source: "...",
    stopAfter: "parse",  // returns AST only, no codegen
});

// Benchmark
const benchResult = await benchmark({
    file: "./App.tsx",
    phases: ["parse"],
    iterations: 100,
    warmup: 10,
});
// benchResult = {
//   parse: { mean: 42.3, median: 41.8, p95: 48.2, stddev: 2.1, samples: [...] }
// }

// Compare
const comparison = await benchmark({
    file: "./App.tsx",
    phases: ["parse"],
    iterations: 100,
    compareBaseline: "./baseline.json",
});
// comparison.parse.improvement = { delta_ms: -10.5, pct: -24.8 }
```

#### Env

```bash
# All phases
ZTS_PROFILE=all zts bundle ...

# Specific
ZTS_PROFILE=parse,transform ZTS_PROFILE_LEVEL=detailed zts bundle ...

# 번개 호환
BUNGAE_HMR_PROFILE=1 npm run start:bungae
# → 내부적으로 ZTS_PROFILE=hmr 매핑
```

### 2.6 출력 포맷

#### `table` (default)

```
=== ZTS Profile ===
Phase             Total   %       Count
-----------------|-------|-------|-------
scan               18ms   10.4%     1
parse              44ms   25.4%     1
semantic            5ms    2.9%     1
transform          40ms   23.1%     1
codegen            24ms   13.9%     1
link                3ms    1.7%     1
shake               2ms    1.2%     1
other              37ms   21.4%     -
-----------------|-------|-------|-------
total             173ms  100.0%
```

#### `tree` (detailed level)

```
=== ZTS Profile (detailed) ===
total: 173ms
├─ scan              18ms  (10.4%)
├─ parse             44ms  (25.4%)
│  └─ ast_build      42ms  (95.5% of parse)
├─ semantic           5ms  ( 2.9%)
├─ transform         40ms  (23.1%)
│  ├─ ts_strip       12ms  (30.0% of transform)
│  ├─ jsx             8ms  (20.0% of transform)
│  ├─ class_field     6ms  (15.0% of transform)
│  ├─ pass2           5ms  (12.5% of transform)
│  └─ (other)         9ms  (22.5% of transform)
├─ codegen           24ms  (13.9%)
│  ├─ walk           18ms  (75.0% of codegen)
│  └─ sourcemap       6ms  (25.0% of codegen)
├─ link               3ms  ( 1.7%)
└─ shake              2ms  ( 1.2%)
```

#### `json`

```json
{
  "profile_version": 1,
  "total_ms": 173.2,
  "level": "detailed",
  "phases": {
    "parse": {
      "total_ms": 44.1,
      "count": 1,
      "pct": 25.4,
      "sub_phases": {
        "ast_build": { "total_ms": 42.1, "pct_of_parent": 95.5 }
      }
    },
    ...
  }
}
```

#### `csv`

```csv
phase,sub_phase,total_ms,pct,count
scan,,18.1,10.4,1
parse,,44.1,25.4,1
parse,ast_build,42.1,95.5,1
...
```

### 2.7 Benchmark 출력 포맷

```
=== Benchmark: parse ===
file:          src/App.tsx
iterations:    100
warmup:        10 (discarded)

Phase       mean     median   p95      p99      stddev  min    max
----------|--------|--------|--------|--------|--------|------|--------
parse       42.3ms   41.8ms   48.2ms   52.1ms    2.1ms  40.1  55.3
```

With `--compare=baseline.json`:

```
=== Benchmark: parse (vs baseline) ===

                before    after    delta      %       verdict
parse           42.3ms    31.8ms   -10.5ms   -24.8%   ✓ improved
```

---

## 3. 구현 Plan (12 PR)

| PR | 내용 | LOC | 기간 |
|----|------|-----|------|
| **0** | 본 설계 문서 | 150 | 0.5일 |
| **1** | `src/profile.zig` 기반 모듈 + 유닛 테스트 | 300 | 1일 |
| **2** | CLI/NAPI/env 진입점 + `--timing` 제거 + help 1차 | 300 | 1.5일 |
| **3** | Scanner + Parser timer 삽입 | 50 | 0.5일 |
| **4** | `--stop-after` + NAPI `stopAfter` | 150 | 1일 |
| **5** | `zts bench` + NAPI `benchmark()` + 통계 + save/compare | 400 | 2일 |
| **6** | Semantic + Graph + Bundler timer | 100 | 0.5일 |
| **7** | Emitter + Transformer + Codegen timer + Release overhead benchmark | 150 | 1일 |
| **8** | Linker + TreeShaker timer | 50 | 0.5일 |
| **9** | HMR `phaseDurations` sub-phase 노출 + 번개 호환 | 150 | 1일 |
| **10** | Report formats (table/tree/json/csv) + `tests/benchmark/pipeline.ts` 업데이트 | 200 | 1일 |
| **11** | 문서 (DEBUG/USAGE/HMR) + `zts help` 최종 + CLI↔NAPI parity 통합 테스트 | 300 | 1일 |

**총**: ~2300 LOC, **10-11일**

**마일스톤**:
- **PR 5 완료 시점** (~5일): `zts bench --phase=parse` 로 **파서만 격리 측정 가능**
- **PR 9 완료 시점** (~8일): HMR detailed breakdown 번개에서 실측 가능
- **PR 11 완료**: 설계 완성

---

## 4. 테스트 전략

### 4.1 계층별 테스트

**1. 유닛 테스트 (Zig `test` 블록)**
- `src/profile.zig` 의 모든 pub 함수
- Category parse / level parse / activation mask / Scope lifecycle
- Report format 각각 snapshot test
- Zero-overhead 검증 (비활성 시 Timer.start 미호출 확인)

**2. 통합 테스트 (Zig `test` 블록 + 파이프라인 통과)**
- 각 phase timer 가 실제로 수치를 기록하는지
- sub-phase 합이 parent 에 근접 (±2% 허용 — overhead 고려)
- `--stop-after` 가 정확히 거기까지만 실행하는지

**3. CLI 테스트 (`tests/integration/tests/profile.test.ts`)**
- `zts transpile --profile=all --profile-format=json input.ts` output 검증
- `zts bench --phase=parse --iterations=5 input.ts` 통계 필드 검증
- `--stop-after=parse` 후 output 없음 확인
- 모든 format (table/tree/json/csv) snapshot test

**4. NAPI 테스트 (`packages/core/index.test.ts`)**
- `bundle({ profile: [...] })` 의 `result.timings` 구조 검증
- `benchmark({ ... })` 의 통계 필드 검증
- `stopAfter` 옵션 동작 검증
- CLI 와 동일한 json 구조 생성하는지 parity test

**5. CLI ↔ NAPI Parity 테스트** (핵심 — 사용자 요구)
- `tests/integration/tests/profile-parity.test.ts`
- 같은 입력으로 CLI JSON output 과 NAPI JSON output 이 **동일한 구조** 생성
- 모든 category / level / format 조합 교차 검증

**6. Overhead benchmark (PR 7 안에 포함)**
- `tests/benchmark/profile-overhead.ts`
- Release 빌드, 같은 파일 100회:
  - baseline (profile 비활성)
  - `--profile=all` 활성
- 차이 < 1% 여야 통과

### 4.2 회귀 방지

모든 PR 에 **before/after 실측** 필수 (사용자 피드백 `feedback_measure_before_optimize.md`):
- Release 빌드 build time
- bundle 평균 시간
- HMR rebuild 시간

특히 PR 3, 6, 7, 8 (timer 삽입 PR) 은 overhead 0% 증명 필요.

---

## 5. CLI Help 원칙

### 5.1 상세도

- 각 서브커맨드 `--help` 에 **예제 최소 3개**
- `zts help profile` / `zts help bench` 전용 페이지
- 모든 category 명시 나열 (dot notation 포함)
- `--profile-level` 각 값의 의미 설명
- `--profile-format` 각 형식의 용도 설명

### 5.2 예시

`zts help profile` 출력은 본 문서의 2.5 절 내용을 바탕으로 작성. `docs/DEBUG.md` 로 링크.

---

## 6. 설계 결정 기록 (2026-04-22)

| 결정 | 선택 | 이유 |
|------|------|------|
| `debug_log` 와 별도 모듈? | **별도 (`profile.zig`)** | 용도 다름 (이벤트 로그 vs 타이밍) |
| 활성화 문법 | **`all` / `none` 키워드 + dot** | 직관적, parent 키면 child 자동 |
| Per-module overhead | per-thread 수집 + merge | 정확성 |
| Thread safety | **per-thread Profiler + merge** | atomic 보다 정확 |
| Legacy `--timing` 호환 | **제거** | 출시 전 |
| CLI ↔ NAPI parity | **필수** | 같은 JSON 구조 생성 |
| NAPI `benchmark()` 노출 | **노출** | CLI ↔ NAPI parity |

---

## 7. 참고 (다른 번들러 비교, 2026-04-22 조사)

| 도구 | Timing 노출 | 벤치마크 | 사용자 접근성 |
|------|-----------|---------|--------------|
| **oxc** | ❌ CLI 에 없음 | `cargo bench` (criterion.rs internal) | 개발자 only |
| **swc** | ❌ | `cargo bench` per-crate | internal |
| **esbuild** | `--log-level=info` 약간 | ❌ | 제한적 |
| **TypeScript (tsc)** | `--extendedDiagnostics` 로 phase breakdown | ❌ | 노출 O, 가장 근접 |
| **Biome** | `--verbose` | ❌ | 제한적 |
| **Rolldown** | ❌ | 내부 bench repo 별도 | 개발자 only |
| **ZTS (계획)** | `--profile=...` + `--profile-level` | `zts bench` + NAPI | **CLI/NAPI 모두 노출** |

ZTS 의 `zts bench` 는 JS 번들러 분야에서 unique.

---

## 8. Open questions (향후 재검토)

1. **Flamegraph 연동** (`--profile-format=flamegraph`) — 대형 프로젝트 분석용. 범위 크므로 본 epic 외.
2. **Continuous benchmark** — CI 에서 regression 감지 자동화. PR 별 실측 수치 비교. 본 epic 이후.
3. **Memory profiling** — 현재는 시간만. allocator hook 으로 RSS / peak alloc 측정 가능. 본 epic 외.
4. **GC pressure metric** — arena grow 횟수, shrink 호출 수 등. profile 의 sub-metric 으로 추가 고려.

---

## 9. 참조

- `#1672 project_transformer_epic.md` — D2 (길 A) 작업 시 본 인프라 활용
- `project_hmr_breakdown_2026_04_21.md` — HMR 성능 측정의 근거
- `docs/DEBUG.md` — 최종 사용자 문서 (PR 11 에서 업데이트)
- `docs/HMR.md` — HMR profiling 섹션 (PR 11)
- oxc benchmark: https://github.com/oxc-project/oxc/tree/main/tasks/coverage
- TypeScript `--extendedDiagnostics`: https://www.typescriptlang.org/docs/handbook/compiler-options.html
