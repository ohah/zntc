# Debug & Profile

ZTS 는 두 가지 경량 인프라를 제공한다:

1. **Debug Logging** (`src/debug_log.zig`) — 이벤트 로그 (AST mutation, cache hit/miss 등).
2. **Profile** (`src/profile.zig`) — 파이프라인 phase 별 **타이밍 측정** + CLI `zts bench` 로 통계 벤치마크.

둘 다 ZTS 바이너리와 `@zts/core` NAPI 양쪽에서 동일 구조로 동작. 비활성 상태 hot path 오버헤드 < 1%.

---

# 1. Debug Logging

- 구현: `src/debug_log.zig`
- 활성 카테고리 enum: `src/debug_log.zig` 의 `Category`
- 동작: 프로세스 전역 비트마스크. 비활성 카테고리의 로그 호출은 단일 `bool` 분기 이후 바로 리턴 — hot path 에서도 부담 없음.

## 활성화

### 환경 변수
```bash
ZTS_DEBUG=compiled_cache zts --bundle entry.ts
ZTS_DEBUG=compiled_cache,hmr bun run bungae:start
```

쉼표 구분. 공백과 대소문자 무시. 알 수 없는 이름은 조용히 무시된다.

### NAPI 옵션
```ts
import { build } from "@zts/core";

await build({
  entryPoints: ["src/index.ts"],
  debug: ["compiled_cache"],
});
```

`ZTS_DEBUG` env 와 **합집합** — 한쪽만 설정해도 충분하고, 둘 다 설정하면 양쪽 카테고리 모두 활성.

### CLI 플래그
별도 플래그 없음. env 로 전달하는 게 충분하다고 판단 (개별 실행/watch/NAPI 에서 일관된 UX).

## 카테고리

현재 정의된 카테고리:

| 이름 | 출력 내용 | 추가된 PR |
|------|-----------|-----------|
| `compiled_cache` | HMR/watch 의 compiled output cache hit/miss 집계 | RFC #1672 B2 |
| `ast_mutation` | `Ast.addNode` 추적 (idx, tag, total, transform_boundary) | RFC #1672 D1 prep |

추가 시: `src/debug_log.zig` 의 `Category` enum 에 이름만 추가 → 사용처에서 `debug_log.print(.new_category, ...)` 호출 → 이 표 업데이트.

## 출력 형식

```
[<category>] key1=value1 key2=value2 ...
```

- prefix: `[<category>]` — 카테고리 구분 + grep 친화
- 본문: 자유 형식 (사용처가 `std.fmt` 포맷 문자열 직접 제공). 권장은 `key=value` 공백 구분
- 목적지: `stderr` — stdout 이 bundle output 일 수 있으므로

예시:
```
[compiled_cache] first=false hits=3 misses=1 no_mtime_skipped=0 (entries=4)
[ast_mutation] addNode idx=42 tag=identifier_reference (total=43, boundary=37)
```

### `ast_mutation` 활용 (RFC #1672 D1 디버깅)

D1 (Ast mutable + clone 제거) 재개 시 transformer 가 parse_arena 의 AST 에 in-place
append 하는 흐름을 추적하는 데 사용. `transform_boundary` 는 parser 영역의 경계
(`Transformer.init` 시점의 `nodes.items.len`) — 이후 추가되는 노드는 transformer 의
결과. boundary 가 null 이면 아직 transform 전.

함께 제공되는 인프라:
- `Ast.transform_boundary: ?u32` — `Transformer.init` 시점 snapshot. D1a 부터 clone 경로에서 활성 (`cloneForTransformer` 가 생성한 AST 의 `nodes.items.len`).
- `Ast.transformed_root: ?NodeIndex` — `transform()` 종료 시 root 기록. D1a 부터 활성. 이중 호출 (재진입) 은 `transform()` 진입 시 null 검증으로 탐지.
- `Ast.assertInvariants()` — Debug 빌드 전용 invariant 검증. boundary 범위 + transformed_root 유효성.
- `Module.ast` 의 ownership 주석 — parse_arena 소유 규약 명시

## 코드 사용법

```zig
const debug_log = @import("debug_log.zig");  // 또는 @import("zts_lib").debug_log

// 단순 로그
debug_log.print(.compiled_cache, "hits={d} misses={d}\n", .{ hits, misses });

// 비싼 format 계산은 enabled 체크 후에
if (debug_log.enabled(.compiled_cache)) {
    const summary = try buildSummary(allocator);
    defer allocator.free(summary);
    debug_log.print(.compiled_cache, "{s}\n", .{summary});
}
```

## 초기화 시점

- **CLI (`src/main.zig`)**: `pub fn main()` 진입 직후 `debug_log.initFromEnv(allocator)` 호출
- **NAPI (`packages/core/src/napi_entry.zig`)**: `napi_register_module_v1` 에서 1회 호출
- **BundleOptions**: `Bundler.init` / `Bundler.initWithResolveCache` 가 `opts.debug` 리스트를 `addCategories` 로 merge

모든 진입점이 `addFromCsv` / `addCategories` 로 **합집합**을 갱신하므로 중복 호출 안전.

## 스레드 안전성

`enabled_mask` 는 단일 `u64`. `initFromEnv` / `addCategories` 는 프로세스 시작 직후 또는 `Bundler.init` 시점에만 호출된다고 가정하며, 로그 호출 시점에는 **read-only** 로 사용된다. 일반적인 ZTS 호출 흐름에서는 mask 변경과 `enabled` 조회가 교차하지 않아 별도 동기화는 두지 않는다.

## 장기 확장

- 카테고리 세부 레벨 (info/debug/trace) 필요하면 `Category` 를 `{category, level}` 쌍으로 확장
- 구조화 출력 (JSON) 이 필요하면 별도 포매터 분기 — env `ZTS_DEBUG_FORMAT=json` 등
- 와일드카드 (`ZTS_DEBUG=*` 혹은 `ZTS_DEBUG=bundler:*`) 는 현재 미지원. 카테고리 수가 많아지기 전에는 쉼표 구분이 충분

---

# 2. Profile (파이프라인 타이밍)

파이프라인 phase 별 (scan/parse/semantic/transform/codegen/...) 타이밍 측정. CLI/NAPI/env 동일 인터페이스.

- 설계 문서: [`docs/design/profile-infrastructure.md`](./design/profile-infrastructure.md)
- 구현: `src/profile.zig`
- Zero-overhead when disabled: 비활성 category 는 `Timer.start` 호출 없음 (single AND branch)

## 2.1 활성화

### CLI

```bash
# 전체 phase
zts input.ts --profile=all

# 특정 phase 만
zts bundle entry.ts --profile=parse,transform

# 상세 level (sub-phase 포함)
zts input.ts --profile=all --profile-level=detailed

# JSON output (스크립트 용)
zts bundle entry.ts --profile=all --profile-format=json > profile.json
```

옵션:
- `--profile=<CSV>`: `all` / `none` / 구체 카테고리 CSV (dot notation 지원: `parse.ast_build`, `transform.jsx`)
- `--profile-level=<L>`: `summary` | `detailed` | `per-module` | `per-pass` (default `summary`)
- `--profile-format=<F>`: `table` | `tree` | `json` | `csv` (default `table`)
- `--stop-after=<P>`: `scan` | `parse` | `semantic` | `transform` | `codegen` — 지정 phase 이후 skip

### NAPI

```ts
import { build, transpile } from "@zts/core";

await build({
  entryPoints: ["src/index.ts"],
  profile: ["parse", "transform"],
  profileLevel: "detailed",
  profileFormat: "json",
});

transpile(source, {
  filename: "input.ts",
  stopAfter: "parse",  // debug: AST 생성 후 종료
});
```

### Env

```bash
ZTS_PROFILE=all ZTS_PROFILE_LEVEL=detailed zts bundle entry.ts
BUNGAE_HMR_PROFILE=1 bun run start:bungae    # 내부적으로 ZTS_PROFILE=hmr 매핑
```

## 2.2 카테고리

| Category | 대상 |
|----------|------|
| `scan` | Scanner tokenization (현재 lazy 구조라 `.parse` 안에 포함됨) |
| `parse` | Parser AST 구축 |
| `semantic` | Semantic analyzer (scope/symbol) |
| `resolve` | Dependency resolution |
| `graph` | Module graph build (resolve + parse + semantic 상위) |
| `link` | Linker (scope hoisting) |
| `shake` | Tree shaker |
| `transform` | Transformer 전체 |
| `transform.ts_strip` / `transform.jsx` / `transform.class_field` / `transform.decorator` / `transform.pass2` | Transformer sub-pass (detailed level) |
| `codegen` | Codegen emit |
| `codegen.walk` / `codegen.sourcemap` | Codegen sub-phase |
| `metadata` | Linker metadata build |
| `emit` | `transform + codegen + metadata` 상위 |
| `hmr` / `hmr.detect` / `hmr.delta` | HMR watch loop |
| `cache` | compiled_cache hit/miss 이벤트 |

**Parent/child 전파**: `--profile=transform` 지정 시 모든 `transform.*` sub-phase 도 자동 활성.
**`all` / `none`**: 전체 활성 / 전체 비활성 키워드.

## 2.3 출력 포맷

### table (default)

```
=== ZTS Profile ===
Phase                Total       %      Count
--------------------|-----------|-------|------
parse                   0.43ms  54.7%      1
semantic                0.36ms  45.3%      1
total                   0.78ms  100.0%
```

### tree (detailed)

```
=== ZTS Profile (detailed) ===
total: 1.20ms
├─ parse             0.77ms  (64.2%)
│  └─ ast.build      0.72ms  (93.5% of parse)
├─ transform         0.34ms  (28.4%)
│  ├─ ts.strip       0.12ms  (35.1% of transform)
│  └─ jsx            0.08ms  (23.5% of transform)
└─ codegen           0.09ms  ( 7.5%)
```

### json (스크립팅)

```json
{
  "profile_version": 1,
  "total_ms": 1.196,
  "level": "summary",
  "phases": {
    "parse":     { "total_ms": 0.767, "count": 1, "pct": 64.17 },
    "transform": { "total_ms": 0.339, "count": 1, "pct": 28.37 },
    "codegen":   { "total_ms": 0.089, "count": 1, "pct":  7.46 }
  }
}
```

### csv (스프레드시트)

```csv
phase,total_ms,count,pct
parse,0.767,1,64.17
transform,0.339,1,28.37
codegen,0.089,1,7.46
```

---

# 3. Benchmark (`zts bench`)

특정 phase 를 N 회 반복 실행하며 통계 (mean/median/p95/p99/stddev/min/max) 출력. 최적화 전후 비교 가능.

## 3.1 CLI

```bash
# 100 회 반복 (기본)
zts bench --phase=parse ./src/App.tsx

# 여러 phase 동시
zts bench --phase=parse,transform,codegen ./src/App.tsx

# baseline 저장
zts bench --phase=parse ./App.tsx --save=./perf/baseline.json

# baseline 과 비교
zts bench --phase=parse ./App.tsx --compare=./perf/baseline.json
# Phase       before     after      delta     %         verdict
# parse        42.3ms    31.8ms   -10.5ms  -24.8%  + improved

# JSON / CSV
zts bench --phase=parse ./App.tsx --format=json > stats.json
zts bench --phase=parse ./App.tsx --format=csv >> history.csv
```

옵션:
- `--phase=<CATS>`: 측정 카테고리 (required, CSV, `all` / `none` 불허).
- `--iterations=<N>`: 반복 횟수 (default 100).
- `--warmup=<N>`: warmup 반복 (default 10, 결과에서 제외).
- `--profile-level=<L>`: `summary` | `detailed`.
- `--format=<F>`: `table` | `json` | `csv`.
- `--save=<PATH>` / `--compare=<PATH>`: baseline I/O.

## 3.2 NAPI

```ts
import { benchmark } from "@zts/core";

const result = benchmark({
  source: "...",         // 또는 file: "./App.tsx"
  filename: "input.ts",
  phases: ["parse"],
  iterations: 100,
  warmup: 10,
});

result.phases.parse.mean_ms;    // 42.3
result.phases.parse.p95_ms;     // 48.2
result.phases.parse.stddev_ms;  // 2.1
```

## 3.3 다른 번들러와 비교

| 도구 | CLI 벤치마크 |
|------|------------|
| oxc / swc | ❌ — `cargo bench` (criterion.rs) 개발자 전용 |
| esbuild | ❌ |
| TypeScript (tsc) | `--extendedDiagnostics` (반복/통계 없음) |
| **ZTS** | **`zts bench` + NAPI `benchmark()` (CLI ↔ NAPI parity)** |

---

# 4. HMR Profile

HMR rebuild 의 각 phase 는 `WatchRebuildEvent.phaseDurations` 에 노출.

기본 phase (항상 측정, BundleTimings 기반):
- `detect` / `graph` / `link` / `shake` / `emit` / `delta` / `total`
- 필드 이름과 실제 값이 일치. 2026-04-22 이전의 `parse`/`semantic` 레거시 이름은 제거됨.

Sub-phase (`ZTS_PROFILE=<cat>` / `BUNGAE_HMR_PROFILE=1` 활성 시):
- `scan` / `parse` / `resolve` / `semantic` / `transform` / `codegen` / `metadata`
- 비활성 상태에선 모두 0. `parse`/`semantic` 은 진짜 parser/analyzer 시간.

## 4.1 번개 (bungae) HMR 실측

```bash
BUNGAE_HMR_PROFILE=1 bun run start:bungae
# Rebuilt [ios] (1 files, 175ms) [detect=27 graph=65 link=3 shake=2 emit=67 delta=1]
```

번개는 `phaseDurations.*` 필드를 읽어 log formatting. ZTS 는 필드만 제공 — UI 는 번개 쪽 책임.

## 4.2 profile 활성 후 세부 breakdown

```ts
import { watch } from "@zts/core";

watch({
  entryPoints: ["src/index.ts"],
  profile: ["hmr"],  // sub-phase 수집 활성
  onRebuild: (event) => {
    const pd = event.phaseDurations!;
    console.log("parse=%d semantic=%d transform=%d codegen=%d resolve=%d",
      pd.parse, pd.semantic, pd.transform, pd.codegen, pd.resolve);
  },
});
```
