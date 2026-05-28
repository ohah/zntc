# RFC: Transformer ownership transfer — clone 회피 (transpile path)

`cloneForTransformer` 가 만든 *cloned AST* 가 87MB synthetic 측정 기준 **581 MB
(33% of peak RSS 1,749 MB)**. `parser.ast` (387 MB) 와 동시 hold 되는 시점이 *peak
RSS 의 root cause*. 이전 세션의 "arena 분리 + early deinit" (Step 2) 가 NO-GO
박제된 결정적 이유 — **peak 시점이 `cloneForTransformer` 직후** 라 그 후의 free
는 peak 안 줄임.

본 RFC 는 **transformer 가 parser.ast 의 ownership 을 양도받아 직접 mutate**
하는 새 API 를 도입한다. clone 자체를 회피해 peak RSS 의 33% 절감 (-580 MB
on 87MB synthetic, 추정). transpile path 한 곳만 적용 — bundler 의 두 호출처
는 *원본 보존 (graph module cache / HMR re-process)* 가 의무라 clone 유지.

## 1. 측정 데이터 (이전 세션 자료 박제)

### 1.1 87MB synthetic 메모리 분포

| 영역 | 메모리 | % of 1,749 MB |
| --- | ---: | ---: |
| **transformer.ast (cloned)** | **581 MB** | **33%** |
| **parser.ast (원본)** | **387 MB** | **22%** |
| analyzer | 221 MB | 13% |
| codegen.buf | 105 MB | 6% |
| scanner | 26 MB | 1.5% |
| known sum | 1,320 MB | 75% |
| peak RSS | 1,749 MB | 100% |

### 1.2 Step 2 NO-GO 박제 — peak timeline

```
main (single arena):
   parse → analyze → clone → [PEAK = parser.ast + cloned.ast = 968 MB] → transform → codegen
                              ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Step 2 (parser_arena 이른 deinit):
   parse → analyze → clone → [PEAK 동일 968 MB] → deinit → transform → codegen
                              ↑                              ↑ release 한 시점은 이미 peak 후
                              parser_arena.deinit() 가 여기서 호출돼야 효과 있음
```

**Step 2 측정** (n=5, 87MB synthetic):
- main: 1,748,805 KB
- Step 2: 1,761,047 KB
- **Δ = +11.7 MB 손해** (owned dupe 16 MB + mimalloc page 반환 지연)

→ peak 자체 회피 필요 = **clone 자체 제거**.

## 2. 현재 `cloneForTransformer` 의 의도

`src/parser/ast.zig:1147` 의 docstring:
> 원본 AST는 변경되지 않으므로 HMR 재처리 등에 안전하다.

호출 사이트 3 곳:

| caller | path | 원본 보존 필요? |
| --- | --- | --- |
| `transpile.zig:1295` | 단일 transpile | **❌ 없음** — transpile 종료 시 arena 통째 free |
| `bundler/emitter.zig:1432` | graph emit (init 분기) | ✅ 필수 — graph module cache, HMR re-process |
| `bundler/graph/transform_prepass.zig:130` | graph pre-pass | ✅ 필수 — pre-pass 후 emit transformer 가 borrow |

→ **transpile path 만 ownership transfer 가능**.

## 3. 대안 설계 (4 가지)

### A. **Transformer.initFromOwnedAst** (RFC 추천)

```zig
/// Transformer 가 source_ast 의 ownership 을 양도받아 직접 mutate.
/// cloneForTransformer 의 deep copy 없음 — peak RSS -580 MB (87MB synthetic).
/// 호출 후 source_ast 는 *transformer.ast 와 동일 instance* (dangling 아님).
/// 호출자는 source_ast 를 더 이상 직접 사용하지 않는다 (transformer.ast 로 통신).
pub fn initFromOwnedAst(
    allocator: std.mem.Allocator,
    source_ast: *Ast,
    options: TransformOptions,
) Error!Transformer {
    // 기존 init 과 같은 finishInit, 단 cloneForTransformer skip.
    source_ast.transform_boundary = @intCast(source_ast.nodes.items.len);
    return finishInit(allocator, source_ast, opts, .owned_from_caller);
}
```

`AstOwnership.owned_from_caller` enum variant 신규 — deinit 시 `noop` (호출자
가 ast struct 의 lifetime 보유, arena cleanup 의존).

### B. **Transformer.initBorrow** 확장

기존 `initBorrow` 는 *이미 transform 된 ast 의 cache hit 분기 전용* (lifecycle.zig:26-32). 일반적 transform 에 borrow 사용하면 transform() 이 *mutation* 시도 → const_cast 위반.

거부.

### C. **streaming clone**

cloneForTransformer 가 *source 의 chunk 별 copy + free*. Zig stdlib ArrayList 가 *partial deinit* 미지원. 큰 변경 + 위험.

거부.

### D. **arena merge** (Step 1 PR #3941 원복 + transformer_arena = parser_arena)

transformer 가 *parser_arena 그대로* 사용. cloneForTransformer 는 *unmove* 시점에 *no-op* 처리. 단순화 가능.

→ A 와 사실상 동등. A 가 더 명시적.

## 4. 추천 plan + sub-PR 분해

### PR-1: `Transformer.initFromOwnedAst` API 추가

- `lifecycle.zig` 에 새 함수 + `AstOwnership.owned_from_caller` enum variant
- `deinit()` 의 분기: `.owned_from_caller` 면 noop (호출자가 ast 보유)
- 호출자 없음 (다음 PR 에서 사용)
- 단위 test 로 새 API 의 정확성 (cloneForTransformer 없이 동일 결과) 검증
- Effort: S | Risk: L

### PR-2: transpile.zig 가 `initFromOwnedAst` 사용

- `Transformer.init(arena, &parser.ast, opts)` → `Transformer.initFromOwnedAst(arena, &parser.ast, opts)`
- parser.ast 가 transformer.ast 와 *동일 instance* — `transformer.ast.nodes` 가 `parser.ast.nodes`. 추가 alloc 도 같은 arena.
- 모든 *parser.ast 후속 사용* (transform_plan / analyzer / dumpStringInternStatsIfEnabled / scanner.line_offsets borrow / codegen) 도 같은 instance → 변경 없이 작동.
- arena 분리 (PR #3941) **원복** — single arena 로 복귀 (clone 회피 시 arena 분리 의미 없음).
- 측정 게이트: 87MB RSS **-300 MB 이상** + 회귀 0
- Effort: M | Risk: M

### PR-3: 측정 + 정밀화

PR-2 머지 후 samply 재측정:
- peak RSS 변동 + 잔여 영역
- transformer.ast 의 self time (cloned 아니라 parser.ast 가 됐으니 *동일*)
- 다른 부수효과 (mimalloc page reuse 패턴 변화)
- 가능하면 추가 win 영역 식별

## 5. 위험 + 가드

### 5.1 ast.transform_boundary

`cloneForTransformer` 가 *boundary snapshot* (transformer.init 의 nodes.items.len). 이 boundary 는 *parser 가 추가한 마지막 node + 1*. 새 `initFromOwnedAst` 도 같은 시점 (호출 시 nodes.items.len) snapshot 가능. **동일 의미 보존**.

### 5.2 parser.ast 의 후속 사용

`transpile.zig` 의 `parser.ast` 후속 사용 site (Step 1 PR 의 5 borrow site):
- `defer parser.ast.dumpStringInternStatsIfEnabled()` — transformer.ast 와 *동일 instance* 라 *둘 다 같은 데이터* → defer 둘 중 하나만 (또는 둘 다, idempotent).
- `transform_plan = buildTransformPlan(&parser.ast)` — *init 전* 시점 사용. 안전.
- `transformer.line_offsets = scanner.line_offsets.items` — scanner 는 arena 안. arena 통째 살아 있는 동안 OK.
- `cg.comments / cg.line_offsets = scanner.*` — 동일.
- `allocator.dupe(scanner.line_offsets.items)` — 동일.

**다 안전** — clone 회피 시 *parser.ast 도 transformer.ast 도 같은 데이터* 라 lifetime 동일.

### 5.3 analyzer.ast pointer

`analyzer.ast = &parser.ast` — *parser.ast == transformer.ast* 라 swap 불필요. *동일 instance*.

### 5.4 transformer.transform() 의 mutation

기존 cloned ast 에 mutate. 새 path 에서는 *원본 parser.ast 에 mutate*. 영향:
- *transpile 의 parser.ast 후속 사용 site* 가 mutation 후 데이터 보게 됨. 위의 5 borrow site 모두 *transform 후* 라 OK (transformer 가 끝낸 후).

### 5.5 회귀 가드

- `zig build test` 통과
- `tests/benchmark` bun test 16/0
- `tests/integration` bundle-smoke 151/0
- 87MB synthetic peak RSS **-300 MB 이상** (게이트)
- typescript.js wall n=30 *no regression* (트랜스폼 work 동일 — 변화 없어야)
- `/code-review max` 사전 1회

### 5.6 NO-GO 룰

- 87MB RSS Δ > -100 MB (절감 안 됨) → 박제 + 폐기
- 정확성 회귀 → 즉시 폐기
- mimalloc 의 page reuse 변화로 *peak 동일* 가능성 — 측정-first

## 6. 미해결 question (RFC pre-merge 답변 필요)

1. **`AstOwnership.owned_from_caller` 의 deinit 동작 정확**:
   - `.owned`: `self.ast.deinit(); allocator.destroy(self.ast);` (lifecycle.zig:67)
   - `.borrowed`: `noop`
   - `.owned_from_caller`: `noop` (caller 가 deinit 책임 — 더 단순)

2. **`dumpStringInternStatsIfEnabled` 중복 defer**:
   - 현재 `parser.ast.dumpStringInternStatsIfEnabled()` + `transformer.ast.dumpStringInternStatsIfEnabled()` 두 defer
   - 동일 instance 면 둘 중 하나 제거 또는 idempotent 보장

3. **measurement 게이트 수치**:
   - 추정 -580 MB (cloned.ast 자체 제거)
   - 실측은 *mimalloc page reuse 효율* 에 영향. 최소 -100 MB 면 GO?

## 7. 다음 세션 시작점

1. PR-1: `Transformer.initFromOwnedAst` API 추가 (작은 PR, infra) — **완료**
2. PR-2: transpile.zig 가 새 API 사용 + arena 분리 원복 + 측정 — **완료**

PR-1 머지 후 PR-2 의 측정 결과 따라 GO/NO-GO 결정. → §10 참조.

## 10. PR-2 측정 결과 + GO 판단 (실측)

87MB synthetic (`scripts/gen-synthetic-87mb.ts`, seed 0x1234abcd, 244K decls),
n=30 페어드 교대 실행, ReleaseFast, macOS, `scripts/measure-rss.ts`:

| | median peak RSS |
| --- | ---: |
| main (clone) | ~3266 MB |
| PR-2 (initFromOwnedAst) | ~3182 MB |
| **Δ** | **~-84 MB (-2.6%)** |

- sign-test: 30/30 b<a, two-sided p < 0.0001 — 통계적으로 명백히 유의
- correctness: main vs PR-2 output **byte-identical** (37.5 MB), bundle-smoke 151/0, bench 16/0

**RFC §5.5 게이트 (-300 MB) 미충족, §5.6 NO-GO 임계 (-100 MB) 도 미달.**
그러나:
- 추정 -580 MB 와 실측 -84 MB 의 격차 원인 = **clone 되는 `nodes`/`extra_data` 배열이
  이미 pre-warm 됨** (`project_arraylist_prewarm_session_2026_05_28.md` / #3928 에서
  -553 MB 선반영). 즉 §1.1 의 581 MB 분포는 prewarm 이전 stale 수치.
- mimalloc 의 page reuse 가 clone buffer 를 즉시 재사용 → peak 영향 제한적 (RFC §5.6
  에서 예견한 시나리오).

**GO 판단 (사용자 결정)**: 작은 절감이나 (1) 통계적으로 명백 (p<0.0001), (2) correctness
회귀 0 (byte-identical), (3) clone 제거로 코드도 단순화 (단일 arena) — 머지 진행.
대신 §5.5 의 -300 MB 게이트는 prewarm 선반영으로 *애초에 도달 불가* 였음을 기록.

**박제**: transpile path 의 *immutable parser.ast 안전성* 을 in-place mutation 과
맞바꾼 대가가 -2.6% 라는 점 — 이후 transpile path 에 parser.ast 재사용 코드를 추가하면
debug assert (transformed_root/transform_boundary == null) 가 깨진다. PR-3 의 추가 정밀화는
이 -84 MB 가 ROI 하한임을 전제로 판단.

## 11. PR-3 측정 + 정밀화 (phase 별 분포)

`ZNTC_MEM_PROFILE=1` 계측 (`transpile.zig` 의 `MemProfile`, phase 경계마다
`arena.queryCapacity()` 스냅샷) 으로 87MB synthetic 의 phase 별 arena 누적 분포 측정
(instrumented ReleaseFast build, single run):

| phase | arena 누적 cap | Δ (증분) |
| --- | ---: | ---: |
| start | 0 MB | — |
| parse | 2049 MB | +2049 MB |
| semantic | 4303 MB | +2254 MB |
| transform | 4303 MB | +0 MB |
| generate | 4303 MB | +0 MB |
| emit | 4303 MB | +0 MB |

### 11.1 clone 의 peak RSS 기여 ≈ 80 MB (직접 증거는 RSS, capacity 아님)

`initFromOwnedAst` (own) 와 `init` (clone) 을 동일 fixture 로 비교 (둘 다 instrumented,
single run):

| 버전 | arena 누적 cap | peak RSS |
| --- | ---: | ---: |
| init (clone) | 4303 MB | ~3415 MB |
| initFromOwnedAst (own) | 4303 MB | ~3337 MB |
| **Δ** | **0 MB** | **~-78 MB** |

**arena capacity 동일 (4303 MB) 은 clone 비용을 증명하지 못한다 — measurement 한계의
귀결일 뿐이다.** `arena.queryCapacity()` 는 모든 BufNode backing 의 *합* 이고, arena alloc
은 가장 최근 BufNode 의 tail 만 사용한다 (이전 node 의 tail 은 backfill 안 함). semantic
단계가 마지막에 큰 BufNode (+2254 MB) 를 만들면서 그 node 에 큰 미사용 tail 이 남고 →
이후 transform 의 clone / generate output / emit 가 모두 그 tail 에 fit → 새 BufNode 가
안 생겨 capacity 의 합이 불변. 즉 **capacity 가 clone/own 동일한 것은 clone 이 싸든 비싸든
*예상되는* 결과** 이며 (§11.3 의 과소측정 한계), clone 비용에 대해 아무 정보도 주지 않는다.

clone 의 실제 비용을 측정하는 유일한 직접 지표는 **peak RSS 차이 (~-78 MB)** 다. clone 이
tail 페이지를 touch 하는 만큼만 RSS 가 늘기 때문. §1.1 의 "transformer.ast cloned 581 MB"
는 *논리적 복제 크기* 일 뿐, arena+mimalloc 환경에서 *touch 되어 RSS 에 기여하는 부분은
~80 MB*. 따라서 §5.5 의 -300 MB 게이트는 clone 의 실제 RSS 비용 자체가 ~80 MB 라
**도달 불가** 였다.

### 11.1.1 §10 (prewarm) 과 §11 은 같은 root cause

§10 의 "clone 배열 prewarm (#3928, -553 MB 선반영)" 과 §11 의 "clone 이 arena tail/page
reuse 에 흡수" 는 *독립 확증이 아니라 동일 현상의 두 각도* 다. clone 의 marginal RSS 비용이
~80 MB 로 작은 근본 이유는 prewarm 이 clone 대상 배열의 capacity 를 미리 키워 둔 것 +
arena/mimalloc 의 page reuse — 둘은 같은 메커니즘을 allocator 층위와 array 층위에서 본 것.
"두 개의 독립 증거" 로 읽으면 안 된다.

### 11.2 잔여 dominant 영역 (이 fixture 기준, 일반화 주의)

clone 영역 소진 후 **이 87MB synthetic 에서** arena 의 capacity high-water 는 거의 전부
parse (2049 MB) + semantic (2254 MB). 단 이 fixture 는 244K decl 의 **TS-type-heavy**
synthetic 이라 semantic (scope/symbol/reference) 비중이 과대 — §1.1 의 이전 baseline 은
analyzer 13% / codegen 6% 였다. **일반 JS corpus 는 분포가 크게 다를 수 있으므로**, parse/
semantic 을 "다음 레버" 로 단정하지 말고 *후보* 로만 본다. 실제 착수 전 대표 corpus 로 재측정
필수. 후보 영역:

- **semantic (analyzer)**: scopes / symbols / references 배열.
- **parse (parser.ast)**: nodes / extra_data / string_table.

둘 다 본 RFC 범위 밖 — `RFC_LIFECYCLE_SCOPE_REDESIGN` (cross-build memory ownership)
또는 별도 analyzer/parser 메모리 RFC 후보.

### 11.3 측정 인프라 한계 (중요)

- `arena.queryCapacity()` 는 모든 BufNode backing 의 합 = *reserved high-water mark*
  이지 *used* 가 아니다. arena 는 최근 BufNode tail 만 쓰므로, 그 tail 에 fit 하는 alloc
  (clone / generate output / emit) 은 새 node 를 안 만들어 **증분 0 으로 과소측정**.
  위 phase 표의 transform/generate/emit +0 은 "메모리를 안 썼다" 가 아니라 "queryCapacity
  가 못 본다" 는 뜻. 실제 phase 비용은 peak RSS 로만 봐야 한다 (§11.1).
- §11 의 절대 peak RSS (own 3337 / clone 3415 MB) 는 §10 의 n=30 측정 (3182 / 3266 MB)
  보다 ~150 MB 높다 — instrumented build (계측 + single run) 의 오버헤드. Δ 도 §11
  은 single-run -78 MB, §10 은 n=30 median -84 MB 로 *측정 방법이 다르다*. 둘 다 "~80 MB
  영역" 으로 정합하나 ±수 MB 정밀 일치를 주장하지 않는다 (single-run 은 분산 큼).
- `ZNTC_MEM_PROFILE` 계측 자체는 enabled=false 시 즉시 return + `env_flag.Once` (std.once
  프로세스 1회 캐시) — production hot path 영향 0.

### 11.4 RFC 종결

clone 회피 (PR-1 API + PR-2 적용) 로 transformer 영역의 RSS 기여 (~80 MB) 소진.
잔여는 parse/semantic 으로 본 RFC 범위 밖. **추가 정밀화는 별도 epic** (analyzer/parser
메모리 또는 lifecycle redesign) 으로 분리. 본 RFC 의 transformer-ownership 레버는 종결.

## 8. 박제 (재시도 금지)

- **PR #3941 의 arena 분리만으로는 RSS 절약 0** — clone 회피 필수
- **early deinit (Step 2 패턴)** = peak 후 release 라 효과 없음 (+11.7 MB 손해)
- **cloneForTransformer 의 deep copy 자체 회피** 가 진짜 root cause 해결책

## 9. References

- `src/parser/ast.zig:1147` cloneForTransformer
- `src/transformer/transformer/lifecycle.zig` Transformer.init / initBorrow / initFromOwnedAst
- `src/transpile.zig` transpile path 의 `initFromOwnedAst` 호출 (PR-2)
- `src/bundler/emitter.zig:1431-1432` bundler path (clone 유지)
- `scripts/gen-synthetic-87mb.ts` / `scripts/measure-rss.ts` — 측정 재현 도구 (PR-3 재사용)
- 메모리 박제: `project_arraylist_prewarm_session_2026_05_28.md` 의 Step 2 NO-GO 분석
