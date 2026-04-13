# 토론: estree 어댑터

> **상태**: 토론 단계. 각 결정과 단계 시작 전에 사용자 확인 필요.
> **선행 조건**: AST 안정화 (병행 진행 가능 — 어댑터 작업이 안정화 사용처 역할)

## 1. 한 줄 요약

ZTS 자체 AST를 **estree 표준 노드**로 변환·노출하여 eslint·prettier·babel-plugin·jscodeshift 등 estree 기반 도구 생태계에 직접 통합 가능하게 한다.

## 2. 동기 (Why)

### 현재 ZTS 약점
- estree 비호환 → ZTS AST를 외부 도구가 못 읽음
- 산업 표준 호환성 점수 C
- ZTS 사용자가 eslint·prettier 쓰려면 다른 parser로 다시 parse → 이중 비용

### 산업 추세
- Rust 기반 차세대 (swc/oxc/Rolldown) 모두 **native AST + estree 어댑터** 패턴
- Vite v6+가 esbuild → Rolldown으로 이동 = "성능 native + 호환성 어댑터" 모델 표준화
- esbuild/Bun은 어댑터 없음 → plugin 생태계 제약 (트레이드오프)

### 기대 효과
- eslint, prettier, babel-plugin, typescript-eslint, jscodeshift 등 **수백 개 도구 즉시 호환**
- ZTS의 "성능"과 "호환성" 둘 다 확보
- AST 안정화의 가장 명확한 외부 사용처
- ZTS 차별화: oxc/swc보다 빠른 어댑터 (Zig 활용) 가능

## 3. 산업 사례

| 도구 | estree 제공 | 방식 |
|---|---|---|
| Rollup | ✅ native | acorn 직접 |
| webpack | ✅ native | acorn (JavascriptParser) |
| Babel | ✅ native | babel-types = estree 슈퍼셋 |
| swc | 🟡 어댑터 | `swc_estree_compat` |
| oxc | 🟡 어댑터 | `oxc_estree` |
| Rolldown | 🟡 oxc 경유 | |
| Vite | 🟡 부분 | 번들 단계만 (Rollup) |
| esbuild | ❌ | plugin은 source string만 |
| Bun | ❌ | 자체 AST |
| Parcel | ❌ | SWC 사용 |
| Turbopack | ❌ | SWC 기반 |

ZTS 추천 진영: **Rust 차세대 (native + adapter)**.

## 4. 결정 항목 (각 결정 전 사용자 확인 필요)

각 항목에 추천만 적음. 시작 전 사용자에게 묻고 합의 후 본 문서에 결정 기록.

### 4.1 방향
- **추천**: producer 먼저 (ZTS → estree). consumer는 1년 후 재검토.
- **확인 필요**: 양방향 동시 진행 의향 있나?

### 4.2 출력 형태
- **추천**: NAPI = JS 객체 (V8 메모리 직접), WASM/CLI = JSON 문자열.
- **확인 필요**: NAPI에서도 JSON 출력 옵션 함께 노출할까? (외부 도구 piping용)

### 4.3 TypeScript AST 형식
- **추천**: typescript-eslint 확장 채용.
- **확인 필요**: babel-types(typescript)도 동시 지원 필요?

### 4.4 Flow AST 형식
- **추천**: babel-flow 형식.
- **확인 필요**: Hermes flow-parser 형식도 옵션으로 둘지?

### 4.5 Identifier 분리
- **추천**: 옵션 C — IdentifierName + LabelIdentifier 추가 분리.
- **확인 필요**: 분리 시 메모리/노드 수 증가 허용 범위?

### 4.6 Source location
- **추천**: 기본 byte offset(`start`/`end`)만, `--locations` 옵션으로 line/col 활성화.
- **확인 필요**: eslint/prettier가 line/col 필수면 기본 ON으로 갈지?

### 4.7 노출 위치
- **추천 (Phase A)**: NAPI + CLI (`zts --emit-ast`)
- **추천 (Phase B)**: WASM + Playground (후속)
- **확인 필요**: Phase A에 WASM도 포함할지? (Playground 가치)

## 5. Lossless 매핑 원칙

producer가 정보 drop하면 consumer가 복원 불가. 무조건 지킨다:

- **모든 ZTS 정보를 estree 노드에 담을 것** (필요시 비표준 필드 — `ts*`, `_zts*` 접두사)
- **매핑 표를 단일 source of truth로 분리** (`src/estree/mapping.zig` 또는 comptime)
- producer/consumer가 같은 표 참조 → 향후 consumer 작업 시 50% 재사용
- **snapshot 테스트 누적** — 미래 consumer 만들 때 입력 재활용

### Lossless 위반 예시
- `for_await_of_statement` → `ForOfStatement {}` ❌ (await flag drop)
- `for_await_of_statement` → `ForOfStatement { await: true }` ✅
- `binding_identifier`/`identifier_reference` → `Identifier {}` ❌
- 컨텍스트로 분류 가능하므로 노드 type 분리하여 emit ✅

## 6. 단계별 작업 (각 phase 시작 전 사용자 확인 필요)

각 phase에 추천 작업만 적음. 시작 전 사용자에게 알리고 합의.

| Phase | 내용 | 비용 (추정) |
|---|---|---|
| 0 | Tag → estree node 매핑 표 작성 (200개) | M (1주) |
| 1 | Identifier 분리 (IdentifierName + LabelIdentifier) | M (1주) |
| 2 | core converter (Zig): visitor → estree node builder | L (2주) |
| 3 | TypeScript 노드 typescript-eslint 매핑 | M (1주) |
| 4 | Flow 노드 babel-flow 매핑 | S (3~5일) |
| 5 | NAPI 노출 (JS 객체 빌더) | M (1~2주) |
| 6 | CLI `--emit-ast` (JSON 출력) | S (2~3일) |
| 7 | line/col 계산 (LineIndex + opt-in) | S (2~3일) |
| 8 | snapshot + reference parser 비교 검증 | M (1~2주) |
| **합계** | | **2~3개월** |

## 7. 검증 전략

estree 호환성 보장 방법:

### 7.1 Snapshot 테스트
- 100~200개 입력 → ZTS estree 출력 JSON snapshot
- 회귀 검출

### 7.2 Reference parser와 비교
- 같은 입력을 acorn / typescript-eslint / babel parse
- ZTS estree 출력과 diff
- 동일하지 않은 부분 = 알려진 차이로 문서화 또는 ZTS 수정

### 7.3 실제 도구 동작 검증
- ZTS estree → eslint 직접 통과 (실제 lint rule 동작)
- ZTS estree → prettier 직접 통과
- Round-trip: ZTS → estree → eslint AST visit → 에러 없음

## 8. 보안 / 안정성 고려

- estree JSON 직렬화 시 매우 큰 트리 → 메모리 폭발 가능 → **size limit 옵션** 권장
- 비표준 필드 prefix 컨벤션 (`zts*`/`ts*`) 명시 — 충돌 방지
- AST 버전 정보 estree 출력에 포함 (`{ "type": "Program", "_zts_version": 1, ... }`)

## 9. 결정 기록 (확정 후 채울 곳)

각 항목 결정 후 본 섹션에 기록 + DECISIONS.md에도 추가:

- D-XX: 방향 — TBD
- D-XX: 출력 형태 — TBD
- D-XX: TS 형식 — TBD
- D-XX: Flow 형식 — TBD
- D-XX: Identifier 분리 — TBD
- D-XX: Location 전략 — TBD
- D-XX: 노출 위치 — TBD

## 10. 후속 액션

- [ ] 4번 결정 항목별 사용자 확인 → 본 문서 결정 기록
- [ ] AST 안정화 design doc과 의존 관계 정리
- [ ] Phase 0 시작 전 사용자 확인 → 매핑 표 작성 PR
- [ ] CI에 reference parser 비교 인프라 추가 검토

## 11. 참고 자료

- estree spec: https://github.com/estree/estree
- typescript-eslint: https://github.com/typescript-eslint/typescript-eslint/tree/main/packages/types
- babel-types: https://babeljs.io/docs/babel-types
- oxc estree crate: `references/oxc/crates/oxc_ast/src/serialize/`
- swc estree compat: `references/swc/crates/swc_estree_compat/`
- acorn: https://github.com/acornjs/acorn
