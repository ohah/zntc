# Debug & Profile

ZNTC 는 두 가지 경량 인프라를 제공한다:

1. **Debug Logging** (`src/debug_log.zig`) — 이벤트 로그 (AST mutation, cache hit/miss 등).
2. **Profile** (`src/profile.zig`) — 파이프라인 phase 별 **타이밍 측정** + CLI `zntc bench` 로 통계 벤치마크.

둘 다 ZNTC 바이너리와 `@zntc/core` NAPI 양쪽에서 동일 구조로 동작. 비활성 상태 hot path 오버헤드 < 1%.

---

# 1. Debug Logging

- 구현: `src/debug_log.zig`
- 활성 카테고리 enum: `src/debug_log.zig` 의 `Category`
- 동작: 프로세스 전역 비트마스크. 비활성 카테고리의 로그 호출은 단일 `bool` 분기 이후 바로 리턴 — hot path 에서도 부담 없음.

## 활성화

### 환경 변수

```bash
ZNTC_DEBUG=compiled_cache zntc --bundle entry.ts
ZNTC_DEBUG=compiled_cache,hmr zntc --watch entry.ts
```

쉼표 구분. 공백과 대소문자 무시. 알 수 없는 이름은 조용히 무시된다.

### NAPI 옵션

```ts
import { build } from '@zntc/core';

await build({
  entryPoints: ['src/index.ts'],
  debug: ['compiled_cache'],
});
```

`ZNTC_DEBUG` env 와 **합집합** — 한쪽만 설정해도 충분하고, 둘 다 설정하면 양쪽 카테고리 모두 활성.

### CLI 플래그

별도 플래그 없음. env 로 전달하는 게 충분하다고 판단 (개별 실행/watch/NAPI 에서 일관된 UX).

## 카테고리

현재 정의된 카테고리:

| 이름                | 출력 내용                                                                                            |
| ------------------- | ---------------------------------------------------------------------------------------------------- |
| `compiled_cache`    | HMR/watch 의 compiled output cache hit/miss 집계                                                     |
| `transform_plan`    | standalone transpile fast-path 라우팅 (`.none`/`.bindings`/`.full`) + `SemanticPlanReason` hit-rate   |
| `ast_mutation`      | `Ast.addNode`/`addString`/`addNodeList` 추적 (idx, tag, total, transform_boundary)                   |
| `string_intern`     | `Ast.addString` intern map hit/miss 통계 (모듈별)                                                    |
| `runtime_polyfills` | core-js 사용 감지 + graph prelude 결정                                                               |
| `module_stats`      | 빌드 끝에 모듈 분류 히스토그램 (출처·wrap 종류·변환 feature·semantic 보유) — 아래 §`module_stats` 참고 |
| `metadata_audit`    | `buildMetadataForAst` sub-phase (skip_nodes / import_bindings / require_rewrites) 의 per-module 분포 — 아래 §`*_audit` 참고 |
| `resolve_audit`     | resolver / file.exists 의 per-call 분포 (cache hit, dir/spec 길이, 경과 ns) — 아래 §`*_audit` 참고 |
| `graph_io_audit`    | `pm.setup.read.open` 의 per-call 분포 (dir-fd cache hit, path 길이, 경과 ns) — 아래 §`*_audit` 참고 |

추가 시: `src/debug_log.zig` 의 `Category` enum 에 이름만 추가 → 사용처에서 `debug_log.print(.new_category, ...)` 호출 → 이 표 업데이트.

> `--profile`(§2)은 phase 별 **타이밍 집계**, `ZNTC_DEBUG`는 **구조/상태/분포 진단**. `module_stats` 는 빌드의 *모양*, `*_audit` 카테고리는 hot phase 의 *분포 (per-call/per-module)* — 둘 다 후자에 속한다. 같이 보면 "`metadata.import.bindings` 가 metadata 의 63% 인데(`--profile`) 그게 esm-wrap 671 모듈에 쏠려있다(`metadata_audit`)" 식으로 읽힌다.

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

### `module_stats` 활용 (빌드 작업 분포 파악)

`ZNTC_DEBUG=module_stats` 로 빌드하면 그래프에 들어온 모듈을 출처·wrap 종류·변환 feature·semantic 보유 여부로 분류한 멀티라인 블록을 빌드 끝에 stderr 로 출력한다 (`src/bundler/bundler.zig` 의 `dumpModuleStats`). 다른 카테고리와 달리 `[cat] key=val` 한 줄이 아니라 헤더 한 줄 + 들여쓴 본문.

```
[module_stats] module stats
  total=954  node_modules=938 (98%)  has_semantic=954  prepass_ran(transform_cache)=681
  wrap_kind: none=173 cjs=92 esm=689
  features: jsx=61 decorator=0 ts(ns|enum|import=|export=)=14
  plain(no jsx/deco/ts) in node_modules: none=165 cjs=90 esm=609  | of which has_semantic=864
  module_type: ts=378 js=534 json=3 tsx=39
```

| 필드 | 의미 |
| --- | --- |
| `node_modules=N (P%)` | 그래프 모듈 중 `/node_modules/` 경로 비율 |
| `has_semantic=N` | semantic(scopes/symbols/refs) 데이터를 들고 있는 모듈 수 — linker 가 요구하므로 보통 전부 |
| `prepass_ran(transform_cache)=N` | transformer pre-pass 가 돈 모듈 수 (`module.transform_cache != null`) |
| `wrap_kind: none/cjs/esm` | scope-hoist(`none`) vs `__commonJS` vs `__esm` wrap |
| `features: jsx/decorator/ts(...)` | 무거운 변환이 실제로 필요한 모듈 수 |
| `plain(...) in node_modules` | "평범한"(jsx/deco/ts 없는) dep 을 wrap 종류별로 — `of which has_semantic` 이 곧 "모듈당 작업을 줄일 여지가 있는 후보 규모" |
| `module_type: ...` | 확장자/타입별 카운트 |

항목 추가 시 `dumpModuleStats` 와 이 표를 함께 갱신.

### `*_audit` 활용 (hot phase per-call 분포 — issue #3142)

`--profile` 이 sub-phase 별 **총합**을 주는 반면, `*_audit` 카테고리는 같은 sub-phase의 **모듈/호출 단위 분포**를 stderr 로 한 줄씩 출력한다. 어디서 시간이 가는지 보려면 `--profile` 부터 → 한 phase 가 크면 그 audit 카테고리로 분포 확인 → grep/awk 로 집계.

#### `metadata_audit`

`buildMetadataForAst` 의 3개 sub-phase (한 모듈당 3줄):

```
[metadata_audit] sn wrap=esm nodes=946 ns=833
[metadata_audit] ib wrap=esm bindings=5 scopes=12 renames=3 preamble_bytes=84 ns=3120
[metadata_audit] rr wrap=esm imports=4 result=3 ns=620
```

| 접두사 | sub-phase | 키 |
| --- | --- | --- |
| `sn` | `metadata.skip.nodes` | `wrap` · `nodes` (AST 노드 수) · `ns` |
| `ib` | `metadata.import.bindings` | `wrap` · `bindings` (import_bindings 길이) · `scopes` (scope_maps 길이) · `renames` (생성된 rename 수) · `preamble_bytes` (생성된 preamble byte 수) · `ns` |
| `rr` | `metadata.require.rewrites` | `wrap` · `imports` (import_records 길이) · `result` (require_rewrites map size) · `ns` |

집계 예시:

```bash
ZNTC_DEBUG=metadata_audit zntc --bundle entry.ts 2>/tmp/audit.log
awk '/^\[metadata_audit\] ib/ { match($0,/wrap=([a-z]+)/,w); match($0,/ns=([0-9]+)/,n); s[w[1]]+=n[1]; c[w[1]]++ } END { for(k in s) printf "%-4s n=%d ns=%d avg=%.0f\n",k,c[k],s[k],s[k]/c[k] }' /tmp/audit.log
```

#### `resolve_audit`

`fileExistsIn` (모든 호출) + `resolve_cache.resolve` (cache miss 만 — hit 는 진입 안 함):

```
[resolve_audit] exists cache=1 hit=0 dir_len=58 name_len=8 ns=412
[resolve_audit] resolve bare=1 spec_len=12 src_len=58 ns=341000
```

| 접두사 | 대상 | 키 |
| --- | --- | --- |
| `exists` | `resolve.file.exists` | `cache` (dir_cache 통과 여부) · `hit` (결과) · `dir_len` · `name_len` · `ns` |
| `resolve` | `resolve.resolver` (cache miss path) | `bare` (bare specifier 여부) · `spec_len` · `src_len` · `ns` |

`resolve` 호출의 `ns` 는 `Timer.read()` (wall) 라 sub-call 비용과 mutex/IO wait 까지 포함. `--profile=resolve.resolver` 의 self-time 보다 훨씬 클 수 있다 — 그 차이가 contention 신호.

#### `graph_io_audit`

`RealReadFileCache.openFile` 의 모든 호출:

```
[graph_io_audit] open path_len=72 dir_cache_hit=1 ns=24500
```

| 키 | 의미 |
| --- | --- |
| `path_len` | 파일 path 길이 |
| `dir_cache_hit` | dir-fd cache 가 dir 을 이미 열어둔 상태였는지 (1) / `openDir` 가 필요했는지 (0) |
| `ns` | open 호출 wall 시간 |

cache HIT/MISS 비율과 호출당 평균이 batching/pre-warm 여지를 보여준다.

## 코드 사용법

```zig
const debug_log = @import("debug_log.zig");  // 또는 @import("zntc_lib").debug_log

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

`enabled_mask` 는 단일 `u64`. `initFromEnv` / `addCategories` 는 프로세스 시작 직후 또는 `Bundler.init` 시점에만 호출된다고 가정하며, 로그 호출 시점에는 **read-only** 로 사용된다. 일반적인 ZNTC 호출 흐름에서는 mask 변경과 `enabled` 조회가 교차하지 않아 별도 동기화는 두지 않는다.

## 장기 확장

- 카테고리 세부 레벨 (info/debug/trace) 필요하면 `Category` 를 `{category, level}` 쌍으로 확장
- 구조화 출력 (JSON) 이 필요하면 별도 포매터 분기 — env `ZNTC_DEBUG_FORMAT=json` 등
- 와일드카드 (`ZNTC_DEBUG=*` 혹은 `ZNTC_DEBUG=bundler:*`) 는 현재 미지원. 카테고리 수가 많아지기 전에는 쉼표 구분이 충분

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
zntc input.ts --profile=all

# 특정 phase 만
zntc bundle entry.ts --profile=parse,transform

# 상세 level (sub-phase 포함)
zntc input.ts --profile=all --profile-level=detailed

# JSON output (스크립트 용)
zntc bundle entry.ts --profile=all --profile-format=json > profile.json
```

옵션:

- `--profile=<CSV>`: `all` / `none` / 구체 카테고리 CSV (dot notation 지원: `parse.ast_build`, `transform.jsx`)
- `--profile-level=<L>`: `summary` | `detailed` | `per-module` | `per-pass` (default `summary`)
- `--profile-format=<F>`: `table` | `tree` | `json` | `csv` (default `table`)
- `--tokenize`: 코드 생성 대신 scanner token stream 출력
- `--tokenize-format=<F>`: `text` | `json` (default `text`)
- `--stop-after=<P>`: `scan` | `parse` | `semantic` | `transform` | `codegen` — 지정 phase 이후 skip

### NAPI

```ts
import { build, transpile } from '@zntc/core';

await build({
  entryPoints: ['src/index.ts'],
  profile: ['parse', 'transform'],
  profileLevel: 'detailed',
  profileFormat: 'json',
});

transpile(source, {
  filename: 'input.ts',
  stopAfter: 'parse', // debug: AST 생성 후 종료
});
```

### Env

```bash
ZNTC_PROFILE=all ZNTC_PROFILE_LEVEL=detailed zntc bundle entry.ts
ZNTC_PROFILE=hmr zntc --watch entry.ts
```

## 2.2 카테고리

| Category                                                                                                     | 대상                                                         |
| ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| `scan`                                                                                                       | Scanner tokenization (현재 lazy 구조라 `.parse` 안에 포함됨) |
| `parse`                                                                                                      | Parser AST 구축                                              |
| `semantic`                                                                                                   | Semantic analyzer (scope/symbol)                             |
| `resolve`                                                                                                    | Dependency resolution                                        |
| `graph`                                                                                                      | Module graph build (resolve + parse + semantic 상위)         |
| `link`                                                                                                       | Linker (scope hoisting)                                      |
| `shake`                                                                                                      | Tree shaker                                                  |
| `shake.setup` / `shake.const_prepass` / `shake.purity` / `shake.stmt_info`                                   | Tree shaker setup, const pre-pass, purity, StmtInfo build    |
| `shake.const_prepass.*`                                                                                      | Const pre-pass fact build, gate, materialize, resync details |
| `shake.fixpoint.*` / `shake.prune` / `shake.numeric_postpass` / `shake.mirror`                               | Tree shaker fixpoint, pruning, numeric post-pass, mirror     |
| `transform`                                                                                                  | Transformer 전체                                             |
| `transform.ts_strip` / `transform.jsx` / `transform.class_field` / `transform.decorator` / `transform.pass2` | Transformer sub-pass (detailed level)                        |
| `codegen`                                                                                                    | Codegen emit                                                 |
| `codegen.walk` / `codegen.sourcemap`                                                                         | Codegen sub-phase                                            |
| `metadata`                                                                                                   | Linker metadata build                                        |
| `emit`                                                                                                       | `transform + codegen + metadata` 상위                        |
| `hmr` / `hmr.detect` / `hmr.delta`                                                                           | HMR watch loop                                               |
| `cache`                                                                                                      | compiled_cache hit/miss 이벤트                               |

**Parent/child 전파**: `--profile=transform` 지정 시 모든 `transform.*` sub-phase 도 자동 활성.
**`all` / `none`**: 전체 활성 / 전체 비활성 키워드.

## 2.3 출력 포맷

### table (default)

```
=== ZNTC Profile ===
Phase                Total       Self        %      Count
--------------------|-----------|-----------|-------|------
parse                   0.43ms     0.07ms  54.7%      1
semantic                0.36ms     0.36ms  45.3%      1
--------------------|-----------|-----------|-------|------
total                   0.78ms     0.78ms  100.0%   (Σ self, all threads)
wall                    0.50ms
```

- **Total** = phase 의 inclusive 시간 (자식 포함). **Self** = 자식 제외.
- **`total` 줄 = Σ self (모든 worker thread 합산)**. 번들러는 parse/resolve/emit 을 thread pool 에서 돌리므로 병렬 구간이 있으면 이 값이 `wall` 보다 크다 — 정상이다. "어느 phase 가 CPU 를 많이 먹나" 는 `%`(= self / Σself) 로 본다.
- **`wall` 줄** = 첫 측정부터 리포트까지 실제 경과 시간. `Σ self / wall` 가 대략 유효 병렬도.

### tree (detailed)

```
=== ZNTC Profile (detailed) ===
wall: 0.50ms   |   Σ self (all threads): 1.20ms
├─ parse             0.77ms total     0.07ms self  (64.2%)
│  └─ ast.build      0.72ms total     0.72ms self  (93.5% of parse)
├─ transform         0.34ms total     0.10ms self  (28.4%)
│  ├─ ts.strip       0.12ms total     0.12ms self  (35.1% of transform)
│  └─ jsx            0.08ms total     0.08ms self  (23.5% of transform)
└─ codegen           0.09ms total     0.09ms self  ( 7.5%)
```

### json (스크립팅)

```json
{
  "profile_version": 1,
  "total_ms": 1.196,
  "wall_ms": 0.500,
  "level": "summary",
  "phases": {
    "parse": { "total_ms": 0.767, "self_ms": 0.047, "count": 1, "pct": 64.17, "self_pct": 3.93 },
    "transform": { "total_ms": 0.339, "self_ms": 0.130, "count": 1, "pct": 28.37, "self_pct": 10.87 },
    "codegen": { "total_ms": 0.089, "self_ms": 0.089, "count": 1, "pct": 7.46, "self_pct": 7.46 }
  }
}
```

(`total_ms` = Σ self over all threads; `wall_ms` = elapsed wall time. `pct`/`self_pct` 는 Σself 대비 비율.)

### csv (스프레드시트)

```csv
phase,total_ms,self_ms,count,pct,self_pct
parse,0.767,0.047,1,64.17,3.93
transform,0.339,0.130,1,28.37,10.87
codegen,0.089,0.089,1,7.46,7.46
```

---

# 3. Benchmark (`zntc bench`)

특정 phase 를 N 회 반복 실행하며 통계 (mean/median/p95/p99/stddev/min/max) 출력. 최적화 전후 비교 가능.

## 3.1 CLI

```bash
# 100 회 반복 (기본)
zntc bench --phase=parse ./src/App.tsx

# 여러 phase 동시
zntc bench --phase=parse,transform,codegen ./src/App.tsx

# baseline 저장
zntc bench --phase=parse ./App.tsx --save=./perf/baseline.json

# baseline 과 비교
zntc bench --phase=parse ./App.tsx --compare=./perf/baseline.json
# Phase       before     after      delta     %         verdict
# parse        42.3ms    31.8ms   -10.5ms  -24.8%  + improved

# JSON / CSV
zntc bench --phase=parse ./App.tsx --format=json > stats.json
zntc bench --phase=parse ./App.tsx --format=csv >> history.csv
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
import { benchmark } from '@zntc/core';

const result = benchmark({
  source: '...', // 또는 file: "./App.tsx"
  filename: 'input.ts',
  phases: ['parse'],
  iterations: 100,
  warmup: 10,
});

result.phases.parse.mean_ms; // 42.3
result.phases.parse.p95_ms; // 48.2
result.phases.parse.stddev_ms; // 2.1
```

## 3.3 다른 번들러와 비교

| 도구             | CLI 벤치마크                                             |
| ---------------- | -------------------------------------------------------- |
| oxc / swc        | ❌ — `cargo bench` (criterion.rs) 개발자 전용            |
| esbuild          | ❌                                                       |
| TypeScript (tsc) | `--extendedDiagnostics` (반복/통계 없음)                 |
| **ZNTC**          | **`zntc bench` + NAPI `benchmark()` (CLI ↔ NAPI parity)** |

---

# 4. HMR Profile

HMR rebuild 의 각 phase 는 `WatchRebuildEvent.phaseDurations` 에 노출.

기본 phase (항상 측정, BundleTimings 기반):

- `detect` / `graph` / `link` / `shake` / `emit` / `delta` / `total`
- 필드 이름과 실제 값이 일치. 2026-04-22 이전의 `parse`/`semantic` 레거시 이름은 제거됨.

Sub-phase (`ZNTC_PROFILE=<cat>` 활성 시):

- 파이프라인: `scan` / `parse` / `resolve` / `semantic` / `transform` / `codegen` / `metadata`
- Graph 내부: `graphBuild` / `graphWorker` / `graphDiscover` (BFS 스캔) / `graphFinalize` (DFS+승격)
- Emit 내부 (bundler 수준): `emitPolyfill` / `emitRefresh` / `emitOutput` / `emitMetafile` / `emitCss`
- emit_output 내부 (emitter 수준): `emitPrelude` / `emitModulePass` / `emitConcat` / `emitSourcemapFinalize`
- 비활성 상태에선 모두 0. `parse`/`semantic` 은 진짜 parser/analyzer 시간.

## 4.1 profile 활성 후 세부 breakdown

```ts
import { watch } from '@zntc/core';

watch({
  entryPoints: ['src/index.ts'],
  profile: ['hmr'], // sub-phase 수집 활성
  onRebuild: (event) => {
    const pd = event.phaseDurations!;
    console.log(
      'parse=%d semantic=%d transform=%d codegen=%d resolve=%d',
      pd.parse,
      pd.semantic,
      pd.transform,
      pd.codegen,
      pd.resolve,
    );
  },
});
```

## 5. Local dev — `zig build napi` 와 `zig build test` 동시 실행 cache 분리

`zig build napi` (background) 와 `zig build test` 를 같은 `.zig-cache/` 공유로 동시에 돌리면 Zig 0.15.2 build system 의 cache 슬롯 corruption 으로 무관 영역 — 특히 `parser/ast_walk_test` 같은 단위 테스트 — 에서 25 fail flaky 가 일관 발생한다(Issue #54).

### 증상

```sh
# concurrent
$ bun run build:napi & zig build test
# → parser/ast_walk_test 영역 25 fail
```

직렬 실행 시 통과. fresh `.zig-cache` 단독 `zig build test` 도 통과. 트리거 = *concurrent build 가 같은 cache root* 사용.

### Fix

`packages/core/package.json` 의 `build:napi` script 는 `--cache-dir .zig-cache-napi` 로 별도 cache root 사용 (Issue #54). 다른 호출 사이트 (CI, 사용자 직접 `zig build napi` 호출) 도 concurrent test 와 같이 돌릴 때는 다음 패턴:

```sh
zig build napi --cache-dir .zig-cache-napi
```

`.gitignore` 에 `.zig-cache-napi/` 등록됨.

### CI 영향

현재 CI 는 napi 와 test 가 *별도 job* (또는 같은 job 안 sequential) 실행이라 concurrent 트리거 없음 — race 측면 영향 0.

CI workflows 의 모든 `zig build napi` 호출은 *일관성 + 향후 parallelize 대비* 로 `--cache-dir .zig-cache-napi` 적용(ci.yml/release.yml/benchmark.yml/actions/setup-zntc). trade-off:

- `mlugg/setup-zig@v2` 의 GH cache 가 default `.zig-cache/` 만 cache → `.zig-cache-napi/` 는 매 run cold. NAPI 빌드 wall-time 분 단위 증가 가능.
- setup-zntc composite action 은 `zig build` (core) 와 `zig build napi` 가 다른 cache dir 사용 → src/ 의 같은 module/.o 재사용 손실.

후속(별도 PR 후보): `actions/cache@v4` 로 `.zig-cache-napi/` 명시 cache 추가해 cold cache 회피.
