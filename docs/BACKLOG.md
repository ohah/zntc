# ZNTC Backlog

구현 중 발견된 개선 사항을 추적한다. 해결된 항목은 제거.

---

## 성능 최적화 (SIMD/프로파일링 후)

| # | 항목 | 비고 |
|---|------|------|
| 1 | `Span`에 `source_id` 추가 (multi-file) | 번들러에서 필요 |
| 4 | `StaticStringMap` → perfect hash 최적화 | 프로파일링 후 |
| 5 | scan* 함수 테이블 기반 통합 | 구조 리팩토링 |
| 6 | skipWhitespace/scanIdentifierTail → local pos 패턴 | SIMD PR |
| 7 | handleNewline 특수화 (handleLF/handleCR) | SIMD PR |
| 8 | keyword lookup 길이 체크 early-exit | 최적화 PR |
| 9 | getLineColumn hint 캐싱 | 최적화 PR |
| 10 | line_offsets Small Buffer Optimization | 최적화 PR |
| 14 | scanHexDigits/scanOctalDigits/scanBinaryDigits 통합 | 최적화 PR |
| 15 | scanHexLiteral/scanOctalLiteral/scanBinaryLiteral 통합 | 최적화 PR |
| 17 | skipUnicodeEscape 헬퍼 추출 | 최적화 PR |
| 18 | isAsciiIdentStart/Continue를 unicode.zig로 이동 | 최적화 PR |
| 19 | pragma dead guard 제거 | 최적화 PR |
| 20 | checkPureComment 최적화 (단일 패스) | 최적화 PR |
| 21 | checkJSXPragma early-exit | 최적화 PR |
| 22 | peek() 캐싱 | 최적화 PR |
| 23 | isAsciiIdentContinue → lookup table | SIMD PR |
| 24 | line_offsets/template_depth_stack 초기 용량 | 최적화 PR |
| 25 | unicode.zig 범위 테이블 불완전 (Georgian 등) | 별도 PR |
| 28 | runner.zig failed_list 메모리 누수 | Arena 도입 시 해결 |
| 31 | scratch ArrayList 미적용 일부 파싱 함수 | 최적화 PR |
| 34 | parseForIn/parseForOf 통합 | 최적화 PR |

---

## Phase 6 semantic 확장 — 미구현 / 대체됨

D053에서 "Phase 6(minifier/bundler)에서 추가"로 예정됐던 semantic 확장 항목. 번들러는 별도 자료구조로 우회 구현되어 필수 기능은 충족됐으나, 아래는 남은 갭.

| # | 항목 | 상태 | 대체물 / 영향 |
|---|------|------|---------------|
| 61 | `Reference[]` 배열 (read/write 종류 + 정확한 위치) | ✅ RFC #1634 완료 | `references: ArrayList(Reference)` 재도입 (`node_index, scope_id, symbol_id, stmt_idx, kind`). mangler liveness / StmtInfo / 후속 최적화의 공통 입력. `ReferenceFlags` bitset 풍부화 (declare/type 구분) 는 별도 후속 이슈 |
| 62 | `is_reassigned` / `is_read` 개별 플래그 | ⚪ 필드 자체 미추가 | `write_count`/`reference_count` scalar가 같은 정보 제공 (let const promotion, tree-shake 기준) — 실질 대체 완료 |
| 63 | Dead store 분석 | 🟡 부분 완료 | top-level/direct block/function declaration body의 straight-line pure overwrite 제거 완료. #61 `Reference[]` 기반 일반 dead store와 branch/loop/try control-flow 분석은 후속 이슈 |

※ #60 (`is_exported`/`is_default_export` 세팅) 은 #1633 에서 해결됨.

---

## App pipeline 성능 / 테스트 인프라

CSS Modules + Sass 도입 (PR #2225) 후 식별된 후속 작업.

| # | 항목 | 비고 |
|---|------|------|
| ~~70~~ | ~~dev rebuild full re-prep (cpSync) 비용~~ | ✅ 해결: `prepare(dirtyPaths)` 가 incremental — 변경 파일만 cpSync, sass/css-modules transform 도 dirty 입력만 재처리, postcss prep 호출 자체도 CSS 관련 dirty 가 없으면 skip. JS-only 변경은 cpSync (dirty 만) + rewriter (dirty 만) 만 수행 — 풀 prep 의 비용 거의 전부 회피. |
| ~~71~~ | ~~`.scss` 단일 파일 fast-path~~ | ✅ 해결: 단일 non-module `.scss/.sass` 변경은 `isCssOnlyChange=true` 로 분류되어 `rebuildScssIncremental` 진입 — 그 파일만 sass.compile + tempRoot/outdir 갱신 + `CssUpdate` broadcast. import dep 추적 없으므로 다른 sass 파일이 이 파일을 import 하면 갱신 누락 (별 issue 로 sass loadPaths dep tracking) |
| ~~72~~ | ~~E2E `setTimeout(2000-2500)` → readiness poll~~ | ✅ 해결 (PR #3532): `tests/e2e/tests/wait-for-server.ts` 폴링 helper 도입, `zntc-app-builder-e2e.test.ts` 의 서버 기동 `setTimeout` 12곳 일괄 대체 + 로컬 중복 helper 제거. 200 한정이 아니라 **임의 HTTP 응답 = bind 완료** (error-overlay fixture 가 500/에러 HTML 을 주므로). |
| 74 | 크로스-스위트 `waitForServer` 통합 | server-readiness 폴링이 3곳에 중복: `packages/core/test/cli/helpers.ts` (positional args), `tests/integration/tests/devserver-sse-mcp.test.ts` 인라인 루프, `tests/e2e/tests/wait-for-server.ts`. 워크스페이스 분리 + `bun:test`↔Playwright 런너 결합으로 직접 import 불가 — runner-agnostic 공유 모듈로 추출해야 단일화 가능. (#3533 /simplify 에서 식별, 범위 초과로 보류) |
| ~~73~~ | ~~Dev mode 에서 bundler 가 CSS chunk 를 emit 하지 않음~~ | ✅ 해결: bundler 측은 그대로 두고, JS 파이프라인이 sass / css-modules 컴파일 산출물을 tempRoot → outdir 로 mirror 하고 HTML 에 `<link>` 를 주입. inline `<style>` 우회 (`buildDevStyleInjector`) 제거. |

---

## TS 타입 전용 (d.ts 생성 시 필요)

ZNTC는 타입 체크를 하지 않으므로 (스트리핑만) 당장 필요하지 않음.
AST Tag는 정의되어 있으나 파싱 미구현 — isolatedDeclarations 구현 시 추가.

| # | 항목 | 비고 |
|---|------|------|
| 49 | conditional type `T extends U ? X : Y` | Tag 정의됨, 파싱 미구현 |
| 50 | mapped type `{ [K in keyof T]: V }` | Tag 정의됨, 파싱 미구현 |
| 51 | infer type `infer T` | Tag 정의됨, 파싱 미구현 |
| 52 | template literal type `` `hello ${string}` `` | Tag 정의됨, 파싱 미구현 |
| 53 | declare 문 wrapper 노드 (ambient 구분) | .d.ts용 |
| 55 | declare global 미지원 | .d.ts용 |
| 56 | module "string" (문자열 모듈 이름) 미지원 | .d.ts용 |
