# ZTS Backlog

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
| 70 | dev rebuild full re-prep (cpSync) 비용 | `createAppDevController.prepare()` 가 매 full reload 마다 `copyAppRootForPostcss` (전체 트리 cpSync) + postcss + Sass + CSS Modules 재실행. 1k 파일 앱이면 prepare 만 수백 ms. incremental sync (변경 파일만 mirror) 또는 in-memory VFS overlay 가 근본 해결 |
| 71 | `.scss` 단일 파일 fast-path | `.scss/.sass` 단일 변경은 `isCssOnlyChange=false` 라 `rebuildAppDevFull` → 전체 cpSync 트리거. self-contained transform 이라 (해당 파일만 sass.compile + css 갱신 + `CssUpdate` HMR broadcast) fast-path 가능. #70 의 pipelineRoot incremental 모델 의존 |
| 72 | E2E `setTimeout(2000-2500)` → readiness poll | `tests/e2e/tests/zts-app-builder-e2e.test.ts` 가 dev/preview 서버 기동 대기로 fixed `setTimeout` 사용 — 느린 CI 에서 flaky 가능성. `fetch(url)` 폴링 helper (ECONNREFUSED 재시도 / 200 까지) 도입해 일괄 대체 |
| 73 | Dev mode 에서 bundler 가 CSS chunk 를 emit 하지 않음 | Build mode 는 splitting 으로 `*.css` 를 별도 chunk 로 출력해 `<link>` 로 서빙되지만, Dev mode 는 `bundle.js` + `index.html` 만 outdir 에 만들어진다. 그래서 Sass / CSS Modules 의 컴파일된 CSS (tempRoot 에만 존재) 가 브라우저에 도달할 길이 없어, proxy 의 `import.meta.env.DEV` inline `<style>` 주입이 다리 역할 중. 문제: 같은 CSS 가 두 번 (bundle 후 link + inline) DOM 에 들어가는 case 도 있고, dev 와 build 의 CSS 처리 경로가 갈려 유지보수 비용. Dev bundler 가 CSS chunk 도 emit 하게 통일하고 inline 주입 (`buildDevStyleInjector`) 제거가 목표. |

---

## TS 타입 전용 (d.ts 생성 시 필요)

ZTS는 타입 체크를 하지 않으므로 (스트리핑만) 당장 필요하지 않음.
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
