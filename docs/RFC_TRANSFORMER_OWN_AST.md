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

1. PR-1: `Transformer.initFromOwnedAst` API 추가 (작은 PR, infra)
2. PR-2: transpile.zig 가 새 API 사용 + arena 분리 원복 + 측정

PR-1 머지 후 PR-2 의 측정 결과 따라 GO/NO-GO 결정.

## 8. 박제 (재시도 금지)

- **PR #3941 의 arena 분리만으로는 RSS 절약 0** — clone 회피 필수
- **early deinit (Step 2 패턴)** = peak 후 release 라 효과 없음 (+11.7 MB 손해)
- **cloneForTransformer 의 deep copy 자체 회피** 가 진짜 root cause 해결책

## 9. References

- `src/parser/ast.zig:1147` cloneForTransformer
- `src/transformer/transformer/lifecycle.zig:13-37` Transformer.init / initBorrow
- `src/transpile.zig:1295` transpile path 의 Transformer.init 호출
- `src/bundler/emitter.zig:1431-1432` bundler path (clone 유지)
- 메모리 박제: `project_arraylist_prewarm_session_2026_05_28.md` 의 Step 2 NO-GO 분석
