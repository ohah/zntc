# RFC: Mangler Size-Gap — 측정 종결 (CLOSED)

상태: **CLOSED · 결정 문서 (재시도 금지)** · 분류: 종합 정리
관련: `RFC_NESTED_SCOPE_RENAMER.md` · `project_nested_scope_renamer_epic` · `project_minify_per_lib_gap_quantified` · `project_combined_scope_tree_rfc` · `project_minify_gap_S_series` · `project_object_key_unquote_win`

이 문서는 "ZNTC minify 출력이 일부 라이브러리에서 경쟁사보다 크다"는 문제에 대해 **mangler(식별자 압축) 아키텍처가 원인인 격차**를 닫으려는 모든 접근이 measure-first 로 NO-GO/ROI-음성 종결됐음을 단일 결정으로 정리한다. 흩어진 메모리 박제의 통합 참조점이며, 동일 방향 재질문/재시도를 차단한다.

## 1. 문제 (실측 확정)

ZNTC 트리셰이킹은 경쟁사 대비 최강(144-lib non-minify 총합 ~0.76x). 격차는 **100% minify 단계**에서 발생한다. CJS-wrapper / 객체키-quote 같은 *별개 codegen 루트커즈*(§4, 머지 완료)를 제거한 뒤에도 남는 격차는 거의 전부 mangler 격차이며 닫히지 않는다.

머지 후 재측정(2026-05-18, 119-lib): ZNTC > min(esbuild/rolldown/rspack) 93 lib. 분해 결과 대표 케이스:

| lib | ratio | 원인 |
|---|---|---|
| zlib | 1.15x | mangler — ZNTC 1글자 식별자 1,694 vs esbuild/rolldown ~5,200, 2글자로 대량 밀림 |
| zod / rxjs | 1.09~1.13x | mangler (확정) |
| vue / express | 1.02~1.04x | mangler 분산 (대형 lib top-level 1글자 풀 잠식) |
| ts-pattern 1.69x / typebox 1.28x | — | **착시** — ZNTC ≈ esbuild ≈ rolldown. rspack(SWC multi-pass compress)만 outlier로 작음. ZNTC 문제 아님 |

**재검증 도장 (2026-05-18, 141-lib, main `96579159`, `smoke.ts --minify-all` ReleaseFast)**: 표본을 119→141 lib 으로 확대 재측정해도 결론 동일. corpus ZNTC 4,768,602 / gap(>0 합) 196,906 = **4.13%** (ZNTC 최소 34 lib / 최대 107 lib). 절대 gap 상위 = vue +24,209(1.04x mangler 분산) · express +14,097(vs rolldown, esbuild 는 827,763 으로 더 큼) · rxjs +12,772(1.09x) · zod +7,423(1.13x) · zlib +6,863(1.13x, 1글자풀) — 전부 §1 표의 mangler 분류 그대로. ts-pattern 1.69x / typebox 1.28x 도 ZNTC≈esbuild≈rolldown·rspack-only outlier 재확인(착시). **표본 확대로도 별개 codegen 루트커즈 0 신규·결론 불변** = §3~§6 종결 유효.

## 2. 루트커즈 (코드 확정)

ZNTC mangler 2-phase:
- **Phase A** (`src/codegen/unified_mangler.zig`): cross-module top-level, 전역 counter + reserved, 빈도순 base54.
- **Phase B** (`src/codegen/mangler.zig`): per-module nested, flat per-module mangle.

bare scope-hoist 에서 Phase A internal(zod 86% / three 99% / effect 94%) 이 전역 54개 1-char 풀을 선점 → 같은 모듈 nested + 타 모듈 전부 2-char fallback. 보수책으로 `src/bundler/linker.zig:799-816` 이 *모든 scope* 의 1-char 식별자를 Phase A reserved 에 등록(nested `for(let i)` shadow 안전) → 1-char 풀이 구조적으로 고갈된다. 경쟁사(esbuild/oxc/SWC/Terser)는 전부 "안정된 단일 scope-tree 위 mangle"로 1-char 를 공격적으로 재사용한다.

근본은 알고리즘이 아니라 **mangler 가 받는 입력(scope 추적·빈도 집계 단위·reserved 분포)이 esbuild 와 다르다**는 것. ZNTC 가 2-phase + 보수적 reserved 를 택한 건 병렬·증분 빌드의 의도적 지름길이며, 성능은 얻고 압축률을 구조적으로 양보했다.

## 3. 측정 종결된 접근 (전부 재시도 금지)

| 접근 | 실행 | 결과 | 판정 |
|---|---|---|---|
| esbuild `renamer.go` 1:1 이식 (nested-scope slot + 통합 빈도풀) | PR #3393 + #3395, epic `nested-scope-renamer-3392`, 런타임 MATCH 100%·회귀0 | 144-lib **+174B (+0.003%)** — zod −2.3K 등 타깃 개선이 wrapper/CJS-heavy(vue +1.4K 등) 상쇄 | RFC #3391 §7 게이트 발동, epic 미머지. **영구 재시도 금지** |
| 사전계산(nested+top-level 통합 빈도풀) 실측 PoC | `feat/nested-scope-names-pr2` 6파일 cherry-pick, 144-lib | **−1,974B wash** (개선 10 / 회귀 47). 회귀 원인 = 통합 풀이 top-level-heavy lib 의 1글자 슬롯 잠식(vue ident diff 확정) | NO-GO |
| chunk-reparse emit 오버홀 PoC | `bundler.zig` 최종 chunk → `transpile()` 재mangle, kill-switch | zod 상한의 **2%만 회수** (esbuild 재mangle 59% 는 chunk 재파싱 효과가 아니라 esbuild mangler 가 ZNTC 보다 강한 것 — 분리 검증) | ROI 0, 가설 반증 |
| combined scope-tree 정공법 | 스파이크 (로컬 revert) | size ~parity (zod +0.1% / effect +0.2%) | RFC CLOSED |
| S-series top-level→per-module Phase B | RFC #3288 (c2+M2 측정) | zod +3.2KB / effect +64KB 회귀 (빈도 보존해도) | **절대 재시도 금지** |
| 앞단(scope-hoist/wrapper emit) 단일모델 통일 XXL — ROI 선검증 | smoke 119-lib, 코드 0 | ZNTC corpus 는 이미 esbuild −45%/rolldown −23%. XXL 도달 상한: 낙관 **−1.7%** / esbuild 동형 **+45% 회귀** / 절대천장 −5%. 낙관 −1.7% 도 트리쉐이크 우위 54 lib 완벽보존 전제(PoC 가 vue 회귀로 이미 실패) | 착수 ROI 음성 |

핵심: esbuild mangler **알고리즘**은 이미 가장 충실히 이식됐고(런타임 정확·회귀0), 그래도 corpus 가 안 줄었다. 막힌 건 알고리즘이 아니라 입력 파이프라인(scope-hoist reserved 생성·CJS wrapper emit 모델). 그것까지 통일하는 XXL 은 번들러 코어 재설계이며 ROI 선검증에서 corpus 최대 −1.7%(도달 불가능 낙관)로 음성.

## 4. 별개 codegen 루트커즈와의 구분 (이건 mangler 아님 — 성공·머지)

mangler 종결 ≠ size 최적화 종결. *특정 lib 만 ZNTC 가 큰* 경우 상당수는 mangler 가 아닌 별개 codegen 누락이고, measure-first diff(ZNTC vs esbuild 출력 직접 비교)로 잡으면 corpus win·회귀0 가능. 성공·머지 계보:

- `member-augment` (#3359): `sideEffects:false` top-level `X.member=pureRHS` dead 귀속 — three 206→12KB
- `shared-ns-dead-emit` (#3399): `X_ns` 스캐폴드 dead → effect −20.6%
- `decl-coalescing` (#3412): bundle-context `export const` wrapper 병합 — effect −2.0%
- `object-key unquote` (#3446): minify 시 valid-ident 객체 키 quote 제거 — corpus −0.587%
- `cjs-wrap-mangle` (#3458): CJS wrapper `exports`/`module` arrow 파라미터 mangle — corpus −0.533%

**판별 원칙**: "큰 lib 어떻게?" → ① mangler 격차(§1~3, 닫기 불가) ② 별개 루트커즈(diff 로 정밀수정 가능) 2부류 구분. ROI 선검증은 실 lib byte diff(proxy 금지). 단 객체키+CJS wrapper 머지 후 재분석(§1) 결과 **새로 잡을 별개 codegen 루트커즈는 소진**됐다. 미미 잔여 = zlib `inf_leave` label mangle ~342B(단일 lib 특수, 일반화 ROI 극소).

## 5. 잔존 경로 평가

이론상 유일하게 남은 것은 rolldown 식 "chunk 재파싱 후 깨끗한 단일 scope re-mangle" 의 *전면* emit 오버홀(parser→semantic→scope-hoist→wrapper emit 을 esbuild 단일 symbol-slot 모델로 재설계, XXL). 그러나 §3 의 chunk-reparse PoC 가 그 효과의 상한을 측정해 ROI 0 으로 반증했고(esbuild 재mangle 이득은 chunk 재파싱이 아니라 mangler 코어 우위), §3 앞단통일 ROI 선검증이 corpus 최대 −1.7%(낙관·도달불가)로 닫았다. **사실상 닫힘.**

## 6. 결론 / 운영 규칙

- mangler 아키텍처 격차(zod/rxjs/zlib/vue/effect 류)는 **측정으로 닫기 불가 확정**. renamer 이식 / 사전계산 / chunk-reparse / combined-tree / per-module / 앞단통일 XXL — 전부 NO-GO·재시도 금지.
- size 단일/중간-PR 레버는 별개 codegen 루트커즈(§4)로 소진. 잔존 격차는 mangler 종결 영역.
- 새 size 아이디어는 (a) 실 lib byte diff 로 ROI 선검증(proxy 금지), (b) mangler 격차인지 별개 루트커즈인지 먼저 판별, (c) mangler 영역이면 본 RFC 로 즉시 종결.
- ts-pattern/typebox 류 "ZNTC 가 큰 것처럼 보이는" 케이스는 rspack(SWC) outlier 착시 — ZNTC vs 동계열(esbuild/rolldown) 로 검증.

이 문서가 "큰 격차 또 파보자" / "사전계산으로 바꾸면?" / "esbuild mangler 따라가면?" / "emit 오버홀?" 재질문의 단일 종결 답이다.

## 7. 2026-05-27 재검증 도장 (corpus 144-lib)

**조건**: main HEAD `c39c5c0a` · ReleaseFast · `bun run smoke.ts` (fixture default minify, 별도 `--minify-all` 보강).

**corpus 합계 (smoke fixture default)**:

| 항목 | 값 |
|---|---|
| ZNTC corpus | **8,619,393 B (≈ 8.2 MB)** |
| best 3-tool corpus | 11,335,397 B (≈ 10.8 MB) |
| ZNTC / best | **0.760x** — ZNTC 가 corpus 합계로 24% 작음 |
| ZNTC ≤ best (가장 작음) | **117 / 144 (81.2%)** |
| 1.0 ~ 1.1x | 17 / 144 (11.8%) |
| 1.1 ~ 1.5x | 10 / 144 (6.9%) |
| > 1.5x | **0** (최대 격차 1.439x) |
| Output runtime MATCH | **144 / 144 (100%)** |
| ZNTC build OK | 144 / 144 (100%) |
| esbuild build FAIL | 3 (`axios`, `debug`, `semver@es5`) |
| rspack build FAIL | 22 (대부분 `@target` downlevel fixture) |

**§1 ~ §3 잔존 격차 카테고리 재확인 (변동 없음)**:

| 카테고리 | 대표 lib | 비고 |
|---|---|---|
| A. mangler 분산 | rxjs (1.04x), zod (1.03x), three (1.02x), vue (≈1.00x mangler 분산), uuid (1.14x · 작은 절대치) | §2 root cause 그대로. 측정 종결 |
| B. rspack outlier (착시) | ts-pattern (1.16x), dayjs (1.17x), lru-cache (1.21x), svelte-full-min (1.14x), svelte-mount-min (1.13x), mime-types (1.09x), type-is (1.04x) | ZNTC ≈ esbuild ≈ rolldown, rspack(SWC multi-pass) 만 작음. ZNTC 문제 아님 |
| C. target downlevel | lru-cache@es2021 (1.44x), semver@es5 (1.21x), semver/@es2019 (≈1.01x) | private-field per-access 등은 별개 영역 (`project_private_field_downlevel_gap` deferred) |
| D. micro-gap (<300 B) | destr, supports-color, preact, hookable, cac, defu, pathe, type-fest 등 | 절대치 미미 · mangler 미세 분산 |

**`--minify-all` 보강 측정 (B/D 영역의 fixture default 효과 분리)**:

smoke fixture 의 `minify: true` 명시는 일부 (예: `svelte-full-min`). mime-types/type-is/lru-cache/dayjs/ts-pattern 등은 fixture default 가 minify=false 라 ZNTC가 정상적으로 indented codegen output 을 emit → "객체 리터럴 공백 보존" / "`\n\t` indent 보존" 처럼 보이는 차이가 발생. `--minify-all` 로 강제 측정 시:

| lib | fixture default | `--minify-all` |
|---|---|---|
| mime-types | ZNTC 182 / rspack 168 (1.09x) | ZNTC **149** = esbuild 149 = rolldown 149 / rspack 159 (1.00x ✅) |
| type-is | 1.04x | ZNTC **154** ≈ esbuild 154 ≈ rolldown 153 (1.01x ✅) |
| lru-cache | 1.21x | ZNTC **17** = esbuild 17 = rolldown 17 (1.00x ✅) |
| dayjs | 1.17x | ZNTC **7.2** < esbuild 7.6 / rolldown 7.5 (**0.99x ZNTC win** ✅) |
| ts-pattern | 1.16x | 1.69x (rspack 4.7 outlier 유지) |
| svelte-full-min | 1.14x | 1.14x (rspack outlier 유지) |
| lru-cache@es2021 | 1.44x | 1.33x (private-field downlevel 잔존) |

→ **fixture default 의 indented output 은 minify 미적용 시 ZNTC codegen 의 정상 동작**. `writeNewline`/`writeIndent` (writer.zig:40-58) 은 `minify_whitespace` 시 정확히 skip — 누락 분기 없음. "객체 리터럴 공백" / "`\n\t` indent" 를 신규 codegen root cause 로 본 가설은 **측정 아티팩트로 폐기**, §4 "별개 codegen 루트커즈 소진" 결정 **유효**.

**해석**: corpus 0.760x 의 우위 24% 는 트리쉐이킹 + 별개 codegen 루트커즈 누적 (§4 머지 PR 들) 효과이며, 잔존 격차 27 lib 는 §1 ~ §3 분류 그대로. `--minify-all` 측정 시 B/D 카테고리 일부가 fixture default 의 측정 인공물로 회복되어 mangler 영역 격차는 [[project_object_key_unquote_win]] 의 141-lib 도장 (corpus gap 4.13%) 과 정합.

**메타 원칙**: 신규 codegen root cause 후보가 보이면 `--minify-all` / `--minify-whitespace` 같은 강제 flag 측정으로 fixture-condition 인공물 부터 분리. fixture default 출력은 ZNTC codegen 의 비-minify 정상 동작 (인덴트 보존) 을 포함한다.
