# AST 신규 노드 추가 체크리스트

ZTS는 AST tag 자동 생성을 아직 도입하지 않았기 때문에 (oxc는 `tasks/ast_tools/`로 1144개 자동), 새 노드를 추가할 때 수동으로 8~10곳을 수정해야 한다. 빠뜨리면 런타임 `unreachable` panic 또는 silent miss로 이어진다. 이 체크리스트는 추가 시 검토해야 할 곳을 한 번에 본다.

## 0. 사전 확인

- [ ] **데이터 레이아웃 재사용 가능?** 기존 노드와 같은 `data` 변종으로 표현 가능하면 새 Tag만 추가하고 끝 (예: `for_await_of_statement`는 `for_of_statement`와 동일 데이터). **저비용 전략 — 우선 검토.**
- [ ] **Tag 분리 vs flag 추가?** ES2025 import attributes처럼 기존 노드의 변형이면 `data` 안에 flag로 처리하는 쪽이 보통 더 단순.
- [ ] **TS/Flow는 독립 prefix 유지** (`feedback_flow_independent_tags.md`): Flow 노드는 `flow_*`, TS는 `ts_*`. 절대 재사용 금지.

## 1. 핵심 (필수)

### 1.1 `src/parser/ast.zig`
- [ ] `Tag` enum에 새 항목 추가 (카테고리 주석 블록에 맞춰 위치 선택)
- [ ] 새로운 데이터 레이아웃이 필요하면 `Data` union에 case 추가 + `@sizeOf(Node) == 24` 어서션 유지 검증
- [ ] doc-comment로 의미·data 의미·예시 코드 작성

### 1.2 파서 (`src/parser/{statement,expression,declaration}.zig`)
- [ ] 새 노드를 생성하는 파싱 함수 추가/수정
- [ ] 에러 복구 경로 확인 (다중 에러 수집 깨지지 않게)

### 1.3 코드젠 (`src/codegen/codegen.zig`)
- [ ] `emitNode`/관련 dispatch에 새 Tag case 추가
- [ ] minify (`minify_whitespace`, `minify_syntax`) 모두 동작 확인
- [ ] sourcemap mapping 추가 (정확한 source position)

### 1.4 트랜스포머 (`src/transformer/transformer.zig` + 관련 패스)
- [ ] visit dispatch에 새 Tag 분기 추가 (또는 default가 통과시키는지 확인)
- [ ] TS strip / decorator / JSX / enum 변환 패스 등 관련 transform이 새 노드와 상호작용하는지 점검

## 2. 번들러 통합 (대부분 노드에 필요)

### 2.1 `src/bundler/binding_scanner.zig`
- [ ] 노드가 **선언**(binding)을 만들면 scope에 등록
- [ ] 노드가 **참조**(reference)를 가지면 use-graph에 추가

### 2.2 `src/bundler/tree_shaker.zig`
- [ ] statement-level 노드면 side-effect 분류 (pure / has-side-effects / unknown)
- [ ] DCE 안전성 확인

### 2.3 `src/bundler/statement_shaker.zig`
- [ ] 새 statement면 statement-level shake 규칙 추가

## 3. 플러그인/외부 노출

### 3.1 `src/transformer/ast_plugin.zig`
- [ ] Visitor enum/dispatch에 새 Tag 노출
- [ ] NAPI plugin에서 새 노드를 hook으로 받을 수 있게 직렬화 추가

### 3.2 (해당 시) `packages/shared/index.ts`
- [ ] Plugin API 타입에 새 노드 type 정의 export

## 4. 테스트

### 4.1 단위
- [ ] `src/parser/parser_test.zig` — 파싱 입력/AST 덤프 비교
- [ ] codegen 라운드트립 (parse → print → parse 동일)
- [ ] minify 라운드트립

### 4.2 통합
- [ ] `tests/integration/tests/` 관련 영역에 회귀 테스트 추가
- [ ] Test262 영역에 해당하면 `zig build test262`로 회귀 점검 (전체 50,504건)

### 4.3 회귀 검증
- [ ] `zig build test` 전체 통과
- [ ] `cd tests/integration && bun test` 전체 통과 (사전 skip 외 fail 0)
- [ ] `cd packages/core && bun test index.test.ts` (NAPI 경로 영향 시)

## 5. 문서

- [ ] 노드 doc-comment에 의미/data 의미/예시 명시
- [ ] (스펙 변경 시) `docs/ROADMAP.md`의 미지원 → 지원 표 업데이트
- [ ] (Visitor API 노출 시) `AST_PLUGINS.md` 업데이트

## 6. 빠지면 조용히 깨지는 곳 (특히 주의)

| 위치 | 빠뜨릴 시 증상 |
|---|---|
| `transformer.zig` visit | 트랜스폼 시 `unreachable` panic |
| `codegen.zig` emit | 출력에 누락 (silent fail), 또는 panic |
| `binding_scanner.zig` | 선언 누락 → tree-shake 시 잘못 제거 |
| `tree_shaker.zig` side_effects | 의도와 다른 DCE |
| `ast_plugin.zig` | NAPI plugin이 새 노드 못 봄 (silent miss) |
| `@sizeOf(Node) == 24` 어서션 | 컴파일 실패 (즉시 발견 — 안전) |

## 7. PR 체크리스트 (요약)

PR 본문 상단에 아래 표 복사 후 체크:

```
## AST 신규 노드 체크리스트
- [ ] Tag enum + data 변종
- [ ] 파서
- [ ] 코드젠 (minify 포함)
- [ ] 트랜스포머 visit
- [ ] binding_scanner / tree_shaker / statement_shaker
- [ ] ast_plugin (NAPI 노출)
- [ ] 단위 + 통합 + Test262 회귀
- [ ] 문서 (doc-comment + ROADMAP)
```

## 향후 자동화

AST 안정화 작업 (ROADMAP "AST 안정화") 시점에 함께 진행 권장:

- Zig comptime 기반 노드 정의 DSL → Tag/Visitor/printer/test fixture 자동 생성
- 참고: oxc `tasks/ast_tools/` (Rust derive macro)
- 안정화 전에 codegen 만들면 Tag rename 시 codegen 인프라도 같이 흔들리므로 안정화와 묶어서.
