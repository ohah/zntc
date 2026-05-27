# ZNTC Backlog

구현 중 발견된 개선 사항을 추적한다. 해결된 항목은 제거.

---

## 성능 최적화 (SIMD/프로파일링 후)

> **2026-05-22 measure-first 결과 (typescript.js 9MB / ReleaseFast / `zntc bench`)**
> lexer scan 의 식별자·공백·문자열 스캔은 이미 16바이트 SIMD 적용 완료. 키워드 조회·lookup table 계열(#4/#8/#23)은 실측상 noise floor 아래로 **ROI ≈ 0** 확인.
> `parse.expression.assignment` 가 profile self 45% 로 최대처럼 보이나, scope 제거 A/B 시 parse −100ms — 대부분 `profile.begin/end` timer 계측 오버헤드(count 큰 scope 의 self 절대값은 신뢰 불가). 새 lexer/parser 최적화 아이디어는 scope 제거 A/B 로 실측 후 진행할 것.
>
> **lexer 마이크로 3부류 A/B 측정 전부 ROI ≈ 0 (2026-05-22, scan ~95–101ms 불변):** ①연산(#6 local pos) — LLVM 이 이미 self.current 레지스터 유지 ②할당(#24 line_offsets prealloc) — ArrayList doubling 이 amortized O(n) 이라 201K 줄도 realloc 비용 ~수십µs(scan 80ms 의 0.1% 미만) ③주석(#20/#21 pragma 우회) — `@`/`#` early-exit + 주석이 1.6M 토큰 중 소수. **scan 은 SIMD/메모리 바운드 확정 — 스칼라 마이크로 최적화 여지 없음, 재시도 금지.** #5/#14/#15/#18/#34 는 동작 동일 순수 리팩토링(성능 무관). #10(=#24 자료구조)/#22(이미 단순 인덱스)/#31(amortized)/#9·#19(핫패스 밖)도 동류 ROI 0.

| # | 항목 | 비고 |
|---|------|------|
| 1 | `Span`에 `source_id` 추가 (multi-file) | **비표준 설계 — 보류 (2026-05-22 references 4종 실측).** 어느 메이저 번들러도 AST 노드에 source_id 안 박음: esbuild=`Loc{Start int32}` 오프셋만(SourceIndex u32 는 심볼 Ref 전용), rolldown=oxc 동일, rspack=소스맵 합성. 출처는 "번들 줄 위치 + 모듈별 루프(module_id 명시)" 로 추적(현 zts 방식=esbuild 와 동일·정석). 함수 본문 인라인(노드 통째 이동)은 rspack 만 하며, 그조차 인라인 코드를 정의처로 **소스맵 합성(compose)** 으로 매핑 — 노드 확장 아님. Node 24B(`ast.zig:67`) 깨면 캐시 효율 하락(2.6→2.0/line). 진짜 트리거=함수 인라인 도입 시이고 그때도 정석은 소스맵 합성. 굳이 노드에 넣어야 하면 노는 pad 2B(u16=65536 모듈)로 크기 무증가 가능 |
| 4 | `StaticStringMap` → perfect hash 최적화 | ROI ≈ 0 확인 (2026-05-22) — 키워드 조회 우회 A/B 시 scan 변화 noise floor 아래 |
| 5 | scan* 함수 테이블 기반 통합 | 순수 리팩토링 (성능 무관) |
| 6 | skipWhitespace/scanIdentifierTail → local pos 패턴 | ROI ≈ 0 측정 (2026-05-22) — SIMD 완료, local pos A/B 무효 (LLVM 레지스터 유지) |
| 7 | handleNewline 특수화 (handleLF/handleCR) | LF/CR/LS 분기 이미 인라인. 함수 분리는 줄바꿈 cold 라 무의미 |
| 8 | keyword lookup 길이 체크 early-exit | ROI ≈ 0 확인 (2026-05-22) — #4 와 동일 측정. 키워드 조회 자체가 noise floor 아래 |
| 9 | getLineColumn hint 캐싱 | 핫패스 밖 (에러/소스맵 경로) — ROI ≈ 0 |
| 10 | line_offsets Small Buffer Optimization | #24 와 동일 자료구조 — amortized 라 ROI ≈ 0 |
| 14 | scanHexDigits/scanOctalDigits/scanBinaryDigits 통합 | 순수 리팩토링 (성능 무관) |
| 15 | scanHexLiteral/scanOctalLiteral/scanBinaryLiteral 통합 | 순수 리팩토링 (성능 무관) |
| 18 | isAsciiIdentStart/Continue를 unicode.zig로 이동 | 순수 리팩토링 (성능 무관) |
| 19 | pragma dead guard 제거 | 핫패스 밖 — ROI ≈ 0 |
| 20 | checkPureComment 최적화 (단일 패스) | ROI ≈ 0 측정 (2026-05-22) — 함수 전체 우회 A/B 무효 (@/# early-exit + 주석 소수) |
| 21 | checkJSXPragma early-exit | ROI ≈ 0 측정 (2026-05-22) — #20 과 동일 (comment pragma 우회) |
| 22 | peek() 캐싱 | 이미 단순 배열 인덱스 — 캐싱 무의미, ROI ≈ 0 |
| 23 | isAsciiIdentContinue → lookup table | ROI ≈ 0 확인 (2026-05-22) — 식별자 스캔 inner loop 는 이미 16B SIMD fast path, 이 함수는 16B 미만 tail 스칼라 fallback 에만 쓰임 |
| 24 | line_offsets/template_depth_stack 초기 용량 | ROI ≈ 0 측정 (2026-05-22) — prealloc A/B 무효 (doubling amortized) |
| 31 | scratch ArrayList 미적용 일부 파싱 함수 | amortized 할당 — ROI ≈ 0 (미측정, 동류) |
| 34 | parseForIn/parseForOf 통합 | 순수 리팩토링 (성능 무관) |

---

## Phase 6 semantic 확장 — 미구현 / 대체됨

D053에서 "Phase 6(minifier/bundler)에서 추가"로 예정됐던 semantic 확장 항목. 번들러는 별도 자료구조로 우회 구현되어 필수 기능은 충족됐으나, 아래는 남은 갭.

| # | 항목 | 상태 | 대체물 / 영향 |
|---|------|------|---------------|
| 61 | `Reference[]` 배열 (read/write 종류 + 정확한 위치) | ✅ RFC #1634 완료 | `references: ArrayList(Reference)` 재도입 (`node_index, scope_id, symbol_id, stmt_idx, kind`). mangler liveness / StmtInfo / 후속 최적화의 공통 입력. `ReferenceFlags` bitset 풍부화 (declare/type 구분) 는 별도 후속 이슈 |
| 62 | `is_reassigned` / `is_read` 개별 플래그 | ⚪ 필드 자체 미추가 | `write_count`/`reference_count` scalar가 같은 정보 제공 (let const promotion, tree-shake 기준) — 실질 대체 완료 |
| 63 | Dead store 분석 | 부분 완료 + 종결 | straight-line pure overwrite(top-level/direct block/function body) 제거 완료. 일반 dead store/branch·loop·try control-flow 는 measure 상 **ROI 0 확정으로 종결** (esbuild 도 부작용 RHS 보존, dead_store ON/OFF 절감 0%; 이슈 #1644 closed) |

※ #60 (`is_exported`/`is_default_export` 세팅) 은 #1633 에서 해결됨.

---

## App pipeline 성능 / 테스트 인프라

CSS Modules + Sass 도입 (PR #2225) 후 식별된 후속 작업.

| # | 항목 | 비고 |
|---|------|------|
| ~~70~~ | ~~dev rebuild full re-prep (cpSync) 비용~~ | ✅ 해결: `prepare(dirtyPaths)` 가 incremental — 변경 파일만 cpSync, sass/css-modules transform 도 dirty 입력만 재처리, postcss prep 호출 자체도 CSS 관련 dirty 가 없으면 skip. JS-only 변경은 cpSync (dirty 만) + rewriter (dirty 만) 만 수행 — 풀 prep 의 비용 거의 전부 회피. |
| ~~71~~ | ~~`.scss` 단일 파일 fast-path + dep tracking~~ | ✅ 해결: 단일 non-module `.scss/.sass` 변경은 `rebuildScssIncremental` fast-path. **dep tracking 도 해결**(PR #3675): dart-sass `loadedUrls`(전이 @import)로 reverse-dep 맵 구축 → partial(`_x.scss`) 변경 시 그것을 @import 한 root scss 를 transitive 재컴파일(dependents 있으면 fast-path 박탈 → full pipeline rebuild). |
| ~~72~~ | ~~E2E `setTimeout(2000-2500)` → readiness poll~~ | ✅ 해결 (PR #3532): `tests/e2e/tests/wait-for-server.ts` 폴링 helper 도입, `zntc-app-builder-e2e.test.ts` 의 서버 기동 `setTimeout` 12곳 일괄 대체 + 로컬 중복 helper 제거. 200 한정이 아니라 **임의 HTTP 응답 = bind 완료** (error-overlay fixture 가 500/에러 HTML 을 주므로). |
| ~~74~~ | ~~크로스-스위트 `waitForServer` 통합~~ | ✅ 해결: `tests/test-helpers/wait-for-server.ts` 정본을 `@zntc/test-helpers` 워크스페이스로 추출, `packages/core/test/cli/helpers.ts`(호환 wrapper)·`tests/integration/tests/devserver-sse.test.ts`(직접 사용)가 공유 모듈 import. 실질 중복 제거 완료. |
| ~~73~~ | ~~Dev mode 에서 bundler 가 CSS chunk 를 emit 하지 않음~~ | ✅ 해결: bundler 측은 그대로 두고, JS 파이프라인이 sass / css-modules 컴파일 산출물을 tempRoot → outdir 로 mirror 하고 HTML 에 `<link>` 를 주입. inline `<style>` 우회 (`buildDevStyleInjector`) 제거. |
