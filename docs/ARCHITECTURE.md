# Architecture

## 트랜스파일 파이프라인
```
Input (.ts/.tsx/.js/.jsx)
  → Scanner (토큰 스트림, SIMD 최적화)
  → Parser (AST, 24B 고정 노드, 인덱스 기반)
  → Semantic Analyzer (스코프 + 심볼 + 검증)
  → Transformer (TS 스트리핑, ES 다운레벨링, JSX, decorator)
  → Minifier (--minify 시: constant folding, DCE, boolean simplification)
  → Codegen (JavaScript + SourceMap V3)
  → Output (.js + .js.map)
```

## 번들러 파이프라인
```
Entry Points
  → Resolver (경로 → 파일, node_modules, package.json exports)
  → Module Graph (BFS 파싱, DFS exec_index, 순환 감지)
  → Linker (스코프 호이스팅, 심볼 바인딩, 이름 충돌 해결)
  → Tree Shaker (export 추적, @__PURE__, sideEffects, fixpoint, StmtInfo 도달성)
  → Chunker (BitSet 도달 가능성, 공통 청크 추출)
  → Emitter (모듈별 transform+codegen, StmtInfo DCE, ESM/CJS/IIFE 출력)
  → Output (bundle.js + chunks + .map)
```

## 메모리 관리 (파일당 Arena)
```
Per-File Arena (단일 할당자, 파일 처리 후 한 번에 해제)
  ├─ Scanner: comments, line_offsets
  ├─ Parser: AST nodes (인덱스 기반, 24B 고정)
  ├─ Semantic: scope chain, symbols
  ├─ Transformer: new_ast
  └─ Codegen: code string, sourcemap
```

## Architecture Decisions (요약, 전체는 [DECISIONS.md](./DECISIONS.md) 참조)

### Lexer Design (D015, D019, D025, D026, D034-D036)
- **토큰 enum**: oxc 방식 — ~208개 u8 플랫 enum. TS 키워드 개별 토큰, 숫자 11가지 세분화
- **소스 위치**: start + end byte offset (8바이트). line/column은 line offset 테이블에서 lazy 계산
- **문자열 인코딩**: UTF-8 기본, lazy UTF-16 (Bun 방식)
- **렉서-파서 연동**: 파서가 렉서 호출 + 옵션으로 토큰 저장
- **SIMD**: Zig @Vector로 공백 스킵, 식별자 스캔, 문자열 스캔
- **추가 기능**: hashbang, BOM, 유니코드 식별자, import attributes, `@__PURE__` 추적, JSX pragma 감지

### Memory Strategy (D004)
- Phase-based arena allocator
- AST 노드는 포인터 대신 인덱스 기반 참조 (use-after-free 방지)
- **Backing allocator**: mimalloc (v3.2.8, vendor/mimalloc)
  - Debug: GPA (leak detection, double-free 감지)
  - ReleaseFast/ReleaseSafe: mimalloc (스레드별 힙 자동 격리, 페이지 캐싱)
  - GPA → c_allocator 전환으로 번들 200모듈 267ms → 30ms, mimalloc으로 추가 개선
  - GPA의 page_allocator(mmap 직접 호출)가 page fault 164K를 일으킨 것이 병목이었음
- **mimalloc 기본 API 사용 (mi_malloc/mi_free)**: Bun처럼 명시적 mi_heap API는 미사용
  - mimalloc 내부에서 자동으로 스레드별 힙 격리 수행
  - ZTS의 모듈별 Arena가 이미 스레드 내 일괄 해제를 담당
  - 수천 개 파일 번들링에서 병목 관찰 시 mi_heap API(힙 단위 일괄 해제)로 전환 검토

### Parser Design
- comptime으로 JS/JSX/TS/TSX/Flow 파서 각각 생성 (런타임 분기 없음)
- 에러 복구 지원 (첫 에러에서 멈추지 않음)
- Test262로 정합성 검증
- **Context**: packed struct(u8) — ECMAScript 문법 파라미터 8개만. SavedState로 함수 경계 save/restore.
- **Cover Grammar**: expression → assignment target 노드 변환. setTag로 24B 노드의 태그만 교체.
- **AST 정규화**: function/method/arrow params는 모두 `formal_parameters` 노드로 wrap (arrow 기준 통일). `Ast.functionParamsList()` 로 태그 무관 unwrap. 범용 리스트 순회는 `visitExtraList(NodeList)` 시그니처. Class `get x() {} / set x() {}` 는 object와 동일하게 `method_definition + flags 0x02/0x04` (별도 태그 없음). `accessor_property` 태그는 TC39 auto-accessor 필드 전용.

### TypeScript/Flow Handling (D002, D005, D024)
- 타입 체크 안 함 (스트리핑만)
- TS 5.8까지 전체 지원
- ✅ Flow: TIER 1+2+3 타입 스트리핑 완료 (flow.zig 독립 구현, Metro 410/410 통과. 상세: [FLOW.md](./FLOW.md))
- ✅ Legacy decorator 구현 완료 (experimentalDecorators)
- Stage 3 decorator: 후순위 (스펙 안정화 후)

### Output (D006, D008, D009, D012)
- ESM + CJS + IIFE (UMD/AMD는 후순위)
- JSX Classic + Automatic 둘 다
- 소스맵 inline + external + hidden 전부
- 에러 출력: 코드 프레임 + JSON

### Transformer Design (D041-D043)
- 새 AST 생성 + 별도 Codegen (oxc/SWC 방식). in-place 변환 대신 변환된 AST를 새로 빌드
- Switch 기반 visitor + comptime 보조 (esbuild/Bun 방식). 성능 핵심은 메모리 레이아웃
- 단일 패스, 변환 우선순위로 순서 제어

### Codegen Design (D044-D046)
- Tab 기본 + Space 옵션 (oxc 방식). IndentChar enum으로 Tab/Space 선택
- `\n` 정규화 + CRLF 옵션. 크로스 플랫폼 지원
- 소스맵 VLQ 자체 구현 (~30줄). 외부 의존성 없음
- 번들러 소스맵: AST span으로 원본→최종 직접 매핑 (esbuild 방식, 체이닝 불필요)

### Bundler Scope Hoisting & Interop
- **Symbol table** (#1328 완료): bundler 합성 심볼(default_export, cjs_exports, esm_init 등)은 전부 `semantic.Symbol`로 이전. bundler 잔여는 `AliasTable`(cross-module re-export redirect 전용). `SymbolRef = union { semantic, alias }`. mangler/rename 결정은 SymbolRef 기반이고 `Symbol.canonical_name` 필드에 저장 — 문자열 이름 기반 해시맵(canonical_names) 폐기로 `"default"` 같은 예약어 충돌 원천 봉쇄
- **이름 충돌 해결**: `Symbol.canonical_name` + `canonical_symbols` dirty list로 O(1) 등록/충돌 확인
- **CJS→ESM Interop**: Rolldown 방식 — Interop enum (babel/node) + ModuleDefFormat enum
  - ESM importer (.mjs/.mts/type:module) → `__toESM(req(), 1)` (Node 모드)
  - 기타 importer → `__toESM(req())` (Babel 모드, __esModule 존중)
- **export * default 제외**: ESM 스펙 15.2.3.5 준수 — `export *`는 default를 포함하지 않음
- **namespace barrel re-export**: `import * as X; export { X }` 패턴 → 인라인 객체 생성
- **.js Unambiguous 파싱**: oxc 방식 — import/export 유무로 module/script 자동 결정
- **Parser API**: `configureFromExtension()` (CLI) / `configureForBundler()` (번들러) 분리

### Tree-shaking Design (#458, #460)
- **1단계 (모듈 수준)**: fixpoint 방식 export 사용 추적 + sideEffects + 자동 순수 판별
- **2단계 (export 수준)**: purity.zig로 expression 순수성 분석 확장 (object/array/conditional/binary/unary/member)
  - export_default_declaration 순수성 검사 → 미사용 `export default { ... }` 제거 (tslib 패턴)
  - 재귀 깊이 128 제한 (stack overflow 방지)
- **StmtInfo (rolldown 방식)**: stmt_info.zig — 심볼 인덱스 기반 statement 도달성 분석
  - semantic analyzer의 `symbol_ids[node_index]` 재활용 → span 기반 이름 매칭 대체
  - import 문을 side-effect-free로 처리 → 미사용 import가 다른 코드를 reachable로 만들지 않음
  - emitter에서 new_ast + `transformer.new_symbol_ids`로 StmtInfo 구축 → linker rename 후에도 정확
  - cross-module import 필터: importer의 도달성으로 dead import binding 스킵

### AST Minifier Design
- **별도 패스 (oxc 방식)**: transformer 완료 후 new_ast를 in-place 수정
  - transformer 통합(esbuild 방식)은 visitNodeInner 복잡도 증가 + 테스트 격리 불가
  - 별도 패스는 minify 대상 태그(~10개)만 switch, 끄면 기존 동작 보장
  - new_ast의 24B 고정 노드를 tag+data 교체로 in-place 수정 (추가 copy 없음)
- **파일 구조**: `src/transformer/minify.zig` (Phase별 분리 가능)
- **파이프라인**: Scanner → Parser → Semantic → Transformer → **Minifier** → Codegen
- **Phase 1: Constant folding** ✅ — `1+2`→`3`, `"a"+"b"`→`"ab"`, `!true`→`false`, `typeof "x"`→`"string"`
  - 결과가 원본보다 긴 경우 fold 안 함 (esbuild `ShouldFoldBinaryOperatorWhenMinifying` 기준)
  - NaN, Infinity, -0 등 특수값 처리
- **Phase 2: Dead code elimination** ✅ — `if(false){A}else{B}`→`B`, `while(false){}`→삭제, logical/nullish 축약
- **Phase 3: Boolean simplification** ✅ — `!!x`→`x`, `x===true`→`x`, `x===false`→`!x`
- **Phase 4: Comma operator** ✅ — `(0,foo)`→`foo`, `(0,1,foo)`→`foo` (N개 선행 리터럴 제거)
- **실측**: three.js 번들 1,149KB → 761KB (**-34%**, --minify)
- **추후**: ES 다운레벨링 mixin도 같은 별도 패스 구조로 마이그레이션 검토
- **참고**: oxc peephole (fold_constants.rs, remove_dead_code.rs), esbuild js_ast_helpers.go

### Semantic Analysis Design (D051-D055)
- 파서에서 구문 컨텍스트 추적, Semantic 패스에서 스코프/심볼
- 스코프: 플랫 배열 + 부모 인덱스. 심볼: 최소 모델 (name/scope/kind/flags/span)
- Strict mode는 파서에서 추적 ("use strict" directive + module mode)
