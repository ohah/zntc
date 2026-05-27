# RFC: Scanner.next 점진적 refactor

`Scanner.next` 는 samply self **19.73%** (typescript.js 9MB) — ZNTC 의 *단일 최대* hot function. ArrayList prewarm 영역이 소진 (PR #3925~#3930, RSS -41.4%) 된 뒤 남은 **유일한 single-function 최대 ROI**.

본 RFC 는 oxc / swc / ZNTC 측정 데이터를 기반으로 **점진적 sub-PR 분해** 를 정의한다. PR-1 / PR-2 / PR-8 / PoC-9 / PoC-3 의 ROI 0 박제를 우회하기 위해 **measurement-first + sub-PR 별 게이트** 룰을 강제한다.

## 1. 측정 데이터 (Step 1)

### 1.1 token 분포 (8 corpus 일관)

| token | typescript.js | _tsc.js | svelte | vue | date-fns | pako |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **identifier** | **30.47%** | **30.33%** | 28.78% | 29.76% | 27.35% | 26.96% |
| paren (l+r) | 19.0% | 18.9% | 14.3% | 18.1% | 14.9% | 17.4% |
| comma | 7.01% | 7.02% | 8.76% | 5.91% | 6.72% | 6.59% |
| dot | 5.94% | 5.67% | 9.41% | 5.44% | 4.06% | 4.31% |
| semicolon | 5.23% | 5.41% | ~2% | 6.28% | 4.98% | 5.74% |
| eq family | 3.56% | 3.73% | 3.59% | 4.88% | 4.09% | 4.95% |
| numeric (decimal) | 3.57% | 4.17% | 3.29% | ~3% | 4.38% | 4.51% |
| curly (l+r) | 5.74% | 5.70% | ~5% | 8.52% | ~3% | 4.20% |
| keyword (subset) | ~7-10% | ~7-10% | ~5% | ~6% | ~6% | ~5% |

**핵심**: identifier 27-30% (모든 corpus). 그 중 keyword 인 비율은 30-50% (function/return/if/const/var 등 자주 등장).

### 1.2 comment outer-loop ratio

| corpus | iter ratio |
| --- | ---: |
| typescript.js | 2.51% |
| _tsc.js | 2.83% |
| svelte (minified) | 0% |
| mobx | 1.70% |
| vue | 0.59% |
| date-fns | 0.60% |
| pako (license-heavy) | 5.58% |

대부분 < 3%. `while (true)` outer loop 의 overhead 작음.

### 1.3 단순 PoC ROI 0 박제

| PoC | 측정 (n=30) | 결론 |
| --- | --- | --- |
| PR-1 inline `Scope.end` | wall ~0 / RSS noise | 박제 |
| PR-2 case `'a'...'z'` 명시 | wall ~0 / 유의차 없음 | 박제 |
| PoC-9 5 bool → struct reset | trim10 -0.14%, p=0.585 | LLVM 가 이미 최적화 |
| PoC-3 oxc branchless space skip | trim10 **+0.62%, p=0.0001** | **반증** (ZNTC ≠ oxc 아키텍처) |
| PoC keyword.get bypass (정확성 깨짐) | parse error → 측정 불가 | XL refactor 필수 |

**진짜 win 은 모두 XL refactor 영역**. single-PR PoC 영역 소진.

## 2. audit 결과 (Step 2, oxc + swc)

### 2.1 oxc 의 진짜 trick = **byte_handlers + per-letter keyword handler**

```rust
// references/oxc/crates/oxc_parser/src/lexer/byte_handlers.rs
pub type ByteHandler<C> = unsafe fn(&mut Lexer<'_, C>) -> Kind;
pub type ByteHandlers<C> = [ByteHandler<C>; 256];

// L_A 같은 per-letter handler:
fn L_A(lexer) -> Kind {
    let id = scan_id_continue(lexer);
    match &id[1..] {
        "wait" => Kind::Await,
        "sync" => Kind::Async,
        // ... 'a' 로 시작하는 keyword 만 비교
        _ => Kind::Ident,
    }
}
```

**핵심 win**: identifier 27-30% × 그 중 keyword 비율 ~30% = **~9% token 의 keyword check** 가 HashMap.get → byte-level match 로 전환.

### 2.2 cold path 추출

oxc 는 `#[cold] #[inline(never)]` 로 escape / non-ASCII / EOF / unterminated 를 별도 함수로 분리 → hot path icache 압력 ↓.

ZNTC 현재 `scanner.zig:561-649` 의 90-line `else` 가 비슷한 cold case 인데 *hot path 안에 inline*. Zig 의 `@branchHint(.cold)` 또는 `@call(.never_inline)` 로 분리 가능.

### 2.3 SIMD batch — ZNTC 이미 적용

oxc 의 32-byte `byte_search!` 는 ZNTC 16-byte SIMD 와 동급. 변경 ROI 낮음.

## 3. 점진적 sub-PR 분해 (제안)

### PR-A: cold path 추출 (`@branchHint(.cold)`)

**변경**: `scanner.zig:561-649` 의 `else` 분기 (escape / non-ASCII / syntax error) 를 별도 함수로 추출 + `@branchHint(.cold)` 적용.

- Effort: **S** (~50 LOC 함수 추출)
- Risk: **L** (정확성 보존, 동작 무변경 — 동일 코드 path 의 위치만 옮김)
- 측정 게이트: typescript.js wall n=30 median + binomial p<0.05
- 예상 ROI: **0.5-1.5%** (cold path 의 icache 압력 회피)
- 의도 검증: instrument 안 됨 (icache miss 직접 측정 어려움). wall A/B 만.

### PR-B: per-letter keyword switch (comptime auto-gen)

**변경**: `token.zig` 의 `keywords` (`StaticStringMap`) 옆에 `comptime` generator 로 *첫 char × 길이 × 직접 비교* switch 를 만든다. `scanner.zig:585` 의 `token.keywords.get(text)` 를 새 함수 `lookupKeyword(text)` 로 교체.

```zig
inline fn lookupKeyword(text: []const u8) ?Kind {
    if (text.len < 2 or text.len > 10) return null;
    return switch (text[0]) {
        'a' => switch (text.len) {
            5 => if (mem.eql(u8, text[1..], "wait")) .kw_await
                 else if (mem.eql(u8, text[1..], "sync")) .kw_async
                 else null,
            8 => if (mem.eql(u8, text[1..], "ccessor")) .kw_accessor else null,
            else => null,
        },
        'b' => if (text.len == 5 and mem.eql(u8, text[1..], "reak")) .kw_break else null,
        // ... 'c' .. 'y' (per-letter)
        else => null,
    };
}
```

- Effort: **M** (~200 LOC 자동 생성 또는 수동)
- Risk: **M** (60 keyword 모든 case 의 정확성)
- 측정 게이트: wall n=30 median + binomial p<0.05 + `tests/integration` 전체 회귀 0
- 예상 ROI: **2-4%** (가장 큰 ROI 후보)
- 의도 검증: PR-A 와 비교. keyword count metric (`identifier_count` vs `keyword_count`) instrument 로 *호출 횟수* 확인.

### PR-C: byte_handlers dispatch table (XL)

**변경**: `Scanner.next` 의 `switch (c)` 를 256-entry function table dispatch 로 교체.

- Effort: **L** (~400-600 LOC, 새 파일 `byte_handlers.zig`)
- Risk: **H** (모든 token case 의 정확성 + Zig function pointer 의 indirect call cost)
- 측정 게이트: typescript.js wall n=30 + 144-lib bench 회귀 0
- 예상 ROI: **1-3%** (PR-B 후 잔여 — LLVM 의 현 switch 가 이미 jump-table 일 가능성)
- **PR-B 머지 + 측정 후 시도 결정**. 만약 PR-B 가 충분히 큰 win 이면 PR-C 는 ROI 작음.

### PR-D: memchr-style `*/` for multi-line comment

**변경**: `scanner.zig` 의 multi-line comment close 검색 byte-by-byte → `std.mem.indexOf(u8, ..., "*/")` SIMD.

- Effort: **XS**
- Risk: **XS**
- 예상 ROI: **negligible** (corpus 의존, pako 같이 license-heavy 만 영향)
- **PR-A/B/C 머지 후 가벼운 cleanup PR** 로 분리.

## 4. ROI 0 박제 (재시도 금지)

- **PR-2 패턴** (switch case 명시) — LLVM 가 이미 dense ASCII jump table 생성. 추가 case 명시는 의미 없음.
- **PR-1 패턴** (Scope.end inline) — Scope.end self 1.36% 가 사라졌지만 wall noise floor 안.
- **PoC-9 패턴** (struct reset) — LLVM peephole 이 이미 single store optimization.
- **PoC-3 패턴** (branchless space skip) — ZNTC 의 always-call `skipWhitespace` SIMD setup 과 충돌해 *역효과 +0.62% wall*.
- **token batching** — parser 인터페이스 refactor 필요, 본 RFC 범위 밖.

## 5. 진행 순서 + 측정 룰

1. **PR-A 먼저** (cold path 추출) — risk 낮음 / 정확성 보존 / 측정 단순.
2. PR-A 머지 후 samply 재측정 → `Scanner.next` self 변동 + `else` 분기 cold function 의 self 확인.
3. **PR-B 다음** (keyword switch) — 가장 큰 ROI 후보. 자동 코드 생성 시도 (`token.zig` comptime).
4. PR-B 머지 후 samply 재측정 → `wyhash` self 변동 확인 (현 2.59% 의 큰 부분이 keyword.get 경로).
5. **PR-C 결정**: PR-A+B 합산 ROI 가 audit 예상 (3-5%) 의 80% 이상 회수했으면 PR-C skip. 잔여 크면 시도.

### 측정 룰 (강제)

매 PR:
- typescript.js 9MB wall **n=30** (paired interleave A/B) + binomial sign test **p<0.05**
- `zig build test` 통과
- `tests/benchmark` bun test 16/0
- `tests/integration` 전체 회귀 0 (3,951 baseline)
- `/code-review max` 사전 1회 (PR #3929 누락 사례 재현 금지)

### NO-GO 결정 룰

PR-A / PR-B / PR-C 각각 측정 후:
- wall median Δ < -0.5% AND binomial p > 0.05 → **NO-GO + 박제 update**
- 정확성 회귀 발견 → **즉시 폐기**
- /code-review max 의 HIGH finding 미해소 → **머지 보류**

## 6. 다음 세션 시작점

1. **PR-A (cold path 추출)** 부터 시작 — risk 최저 + 측정 단순. `@branchHint(.cold)` 적용 + `else` 분기 별도 함수로.
2. 결과 따라 PR-B (per-letter keyword switch) 또는 NO-GO.
3. PR-C (byte_handlers table) 는 PR-A+B 결과의 잔여 ROI 평가 후 결정.
