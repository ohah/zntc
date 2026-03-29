# ZTS - Zig TypeScript Transpiler

## Project Overview
Zig로 작성하는 JavaScript/TypeScript/Flow 트랜스파일러. SWC/oxc 수준의 프로덕션 레벨 품질을 목표로 하는 학습 + 실용 프로젝트. 추후 번들러까지 확장 예정.

## Tech Stack
- **Language**: Zig 0.15.2
- **Version Manager**: mise
- **Build**: `zig build` (build.zig)
- **Test**: `zig build test`
- **Test262**: `zig build test262`

## Project Structure
```
src/
  main.zig                  # CLI 엔트리포인트 (zts 커맨드)
  root.zig                  # 라이브러리 엔트리포인트 (모든 모듈 re-export)
  diagnostic.zig            # 진단 시스템 (ParseError, SemanticError 통합)
  config.zig                # 설정 구조 (CompilerOptions, ResolverOptions, BundlerOptions)
  lexer/                    # Phase 1: 렉서 ✅
    mod.zig                 #   렉서 엔트리 + re-export
    token.zig               #   토큰 종류(Kind ~208개), Span, Token, 키워드 맵
    scanner.zig             #   스캔 로직 (~2400줄, 모든 토큰 타입 처리)
    unicode.zig             #   유니코드 식별자 (UTF-8 디코딩, ID_Start/ID_Continue)
  parser/                   # Phase 2: 파서 ✅
    mod.zig                 #   파서 엔트리 + re-export
    parser.zig              #   파서 메인 로직 (~4000줄)
    ast.zig                 #   AST 노드 정의 (~200개 Tag, 24B 고정)
    expression.zig          #   표현식 파싱 (precedence climbing, cover grammar)
    statement.zig           #   문 파싱 (if/for/while/switch 등)
    declaration.zig         #   선언 파싱 (function/class/const 등)
    binding.zig             #   바인딩 패턴 (destructuring, rest, default)
    object.zig              #   객체/클래스 멤버 파싱
    jsx.zig                 #   JSX 파싱 (element, fragment, attributes)
    module.zig              #   import/export 파싱
    ts.zig                  #   TypeScript 타입 어노테이션 파싱
  semantic/                 # 의미 분석 ✅
    mod.zig                 #   의미 분석 엔트리 + re-export
    analyzer.zig            #   의미 분석기 (~3000줄, 스코프/심볼 추적)
    checker.zig             #   검증 (~700줄, 엄격 모드, 예약어, 중복)
    scope.zig               #   스코프 체인 (플랫 배열 + 부모 인덱스)
    symbol.zig              #   심볼 테이블 (이름, 종류, 플래그, 참조 수)
  transformer/              # Phase 3: 트랜스포머 ✅ + ES 다운레벨링 ✅
    mod.zig                 #   트랜스포머 엔트리 + re-export
    transformer.zig         #   Visitor 기반 순회 + AST 변환
    es2022.zig              #   ES2022 다운레벨링 (class static block, this 치환)
    es2021.zig              #   ES2021 다운레벨링 (??=, ||=, &&=)
    es2020.zig              #   ES2020 다운레벨링 (??, ?.)
    es2019.zig              #   ES2019 다운레벨링 (optional catch binding)
    es2018.zig              #   ES2018 다운레벨링 (object spread)
    es2017.zig              #   ES2017 다운레벨링 (async/await → generator)
    es2016.zig              #   ES2016 다운레벨링 (**)
    es2015.zig              #   ES2015 엔트리 (기능별 모듈 re-export)
    es2015_template.zig     #   template literal → string concat
    es2015_shorthand.zig    #   shorthand property → full form
    es2015_computed.zig     #   computed property → sequence expression
    es2015_params.zig       #   default/rest params → body 삽입
    es2015_spread.zig       #   spread → .apply() / [].concat()
    es2015_arrow.zig        #   arrow function → function expression
    es2015_for_of.zig       #   for-of → index-based for loop
    es2015_destructuring.zig #  destructuring → 개별 변수/assignment
    es2015_block_scoping.zig #  let/const → var
    es2015_class.zig        #   class → function + prototype
    es2015_generator.zig    #   generator → 상태 머신 (__generator)
    es_helpers.zig          #   다운레벨링 헬퍼 유틸
  codegen/                  # Phase 4: 코드 생성 ✅
    mod.zig                 #   코드젠 엔트리 + re-export
    codegen.zig             #   코드 생성 (formatting, minify, indentation)
    sourcemap.zig           #   V3 소스맵 생성 (VLQ 인코딩)
    mangler.zig             #   식별자 축약 (번들러 심볼 데이터 활용)
  bundler/                  # Phase 6a: 번들러 ✅
    mod.zig                 #   번들러 엔트리 + 오케스트레이션
    bundler.zig             #   번들러 메인 로직
    resolver.zig            #   모듈 경로 해석 (node_modules, package.json, tsconfig)
    graph.zig               #   모듈 그래프 (DFS, exec_index, 순환 감지)
    module.zig              #   모듈 데이터 (AST, import/export, 심볼, def_format, interop)
    linker.zig              #   스코프 호이스팅 + 이름 충돌 해결 + CJS→ESM Interop
    tree_shaker.zig         #   Tree-shaking (export 추적, @__PURE__, sideEffects, 도달성)
    stmt_info.zig           #   StmtInfo (rolldown 방식 심볼 기반 statement 도달성 분석)
    statement_shaker.zig    #   Statement-level DCE (span 기반 폴백)
    purity.zig              #   순수성 분석 (expression/statement/varDecl/class 공유)
    chunk.zig               #   Code splitting (BitSet, 공통 청크, cross-chunk)
    emitter.zig             #   출력 생성 (exec_index 순서, ESM/CJS/IIFE)
    types.zig               #   번들러 자료 구조 (Interop, ModuleDefFormat, ExportsKind 등)
    package_json.zig        #   package.json 읽기 (exports, browser, sideEffects)
    resolve_cache.zig       #   해석 결과 캐싱 (import kind별)
    import_scanner.zig      #   import/export 문 추출
    binding_scanner.zig     #   심볼 바인딩 추적
  server/                   # Phase 6b: 개발 서버 + HMR ✅
    mod.zig                 #   서버 엔트리 + re-export
    dev_server.zig          #   HTTP + WebSocket 서버 (HMR, Fast Refresh)
    mime.zig                #   MIME 타입 매핑
  regexp/                   # RegExp 검증 ✅
    mod.zig                 #   RegExp 엔트리 + re-export
    parser.zig              #   RegExp 패턴 파서 (~2000줄, comptime 모드 분리)
    ast.zig                 #   RegExp AST
    flags.zig               #   플래그 처리 (g, i, m, u, v, d, s)
    unicode_property.zig    #   유니코드 프로퍼티 (\p{Letter} 등)
    diagnostics.zig         #   RegExp 에러 메시지
  test262/                  # Test262 러너
    mod.zig                 #   Test262 엔트리
    runner.zig              #   메타데이터 파서 + 테스트 실행기
packages/
  integration/              # Bun 기반 CLI 통합 테스트
  e2e/                      # Playwright E2E 테스트 (dev server)
  benchmark/                # 스모크 테스트 + 벤치마크 (smoke.ts)
tests/
  test262/                  # TC39 공식 Test262 (서브모듈)
references/                 # 레퍼런스 프로젝트 (.gitignore, 로컬만)
  bun/                      #   Zig — 파서/렉서/SIMD 참고
  esbuild/                  #   Go — 번들러 아키텍처/모듈 해석/설정 참고
  oxc/                      #   Rust — 트랜스포머/isolated declarations/파서 참고
  swc/                      #   Rust — 전체 기능/Flow 참고
  hermes/                   #   C++ — Flow 파서 임베딩 소스
  metro/                    #   JS — React Native 번들러/Metro 호환 참고
  rolldown/                 #   Rust — Rollup 호환 번들러/Vite 통합 참고
  vite/                     #   JS — 개발 서버/HMR/플러그인 API 참고
  babel/                    #   JS — 플러그인 시스템/스펙 추종 참고
  typescript/               #   TS — 공식 컴파일러, 다운레벨링/decorator 테스트케이스 참고
```

## Pipeline Architecture

### 트랜스파일 파이프라인
```
Input (.ts/.tsx/.js/.jsx)
  → Scanner (토큰 스트림, SIMD 최적화)
  → Parser (AST, 24B 고정 노드, 인덱스 기반)
  → Semantic Analyzer (스코프 + 심볼 + 검증)
  → Transformer (TS 스트리핑, ES 다운레벨링, JSX, decorator)
  → Codegen (JavaScript + SourceMap V3)
  → Output (.js + .js.map)
```

### 번들러 파이프라인
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

### 메모리 관리 (파일당 Arena)
```
Per-File Arena (단일 할당자, 파일 처리 후 한 번에 해제)
  ├─ Scanner: comments, line_offsets
  ├─ Parser: AST nodes (인덱스 기반, 24B 고정)
  ├─ Semantic: scope chain, symbols
  ├─ Transformer: new_ast
  └─ Codegen: code string, sourcemap
```

## Architecture Decisions (요약, 전체는 DECISIONS.md 참조)

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

### TypeScript/Flow Handling (D002, D005, D024)
- 타입 체크 안 함 (스트리핑만)
- TS 5.8까지 전체 지원
- Flow: 미지원 (현재 우선순위 낮음, RN 지원 시 결정. 상세: [FLOW.md](./FLOW.md))
- ✅ Legacy decorator 구현 완료 (experimentalDecorators)
- Stage 3 decorator: 후순위 (스펙 안정화 후)

### Output (D006, D008, D009, D012)
- ESM + CJS (UMD는 번들러 Phase)
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
- **이름 충돌 해결**: canonical_names + canonical_names_used 역방향 맵으로 O(1) 충돌 확인
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

### Semantic Analysis Design (D051-D055)
- 파서에서 구문 컨텍스트 추적, Semantic 패스에서 스코프/심볼
- 스코프: 플랫 배열 + 부모 인덱스. 심볼: 최소 모델 (name/scope/kind/flags/span)
- Strict mode는 파서에서 추적 ("use strict" directive + module mode)

## Phase 현황

### ✅ 완료
| Phase | 내용 | 상태 |
|-------|------|------|
| 1. 렉서 | 토큰 ~208개, SIMD, 유니코드, JSX, RegExp 검증 | ✅ |
| 2. 파서 | AST ~200 Tag, TS/JSX, 에러 복구, semantic analysis | ✅ |
| 3. 트랜스포머 | TS 스트리핑, enum/namespace IIFE, JSX, ESM→CJS, decorator | ✅ |
| 4. 코드젠+CLI | 포맷팅, minify, 소스맵 V3, --ascii-only | ✅ |
| 5. CLI 고급 | stdin, 에러 프레임, --outdir, tsconfig, --watch | ✅ |
| 6a. 번들러 | resolver, 모듈 그래프, linker, tree-shaking, code splitting | ✅ |
| 6a-ts | tree-shaker 2단계 — export 수준 DCE (purity.zig, tslib 95% 감소) | ✅ |
| 6a-si | StmtInfo 기반 statement DCE (rolldown 방식, pathe ESM 77% 감소) | ✅ |
| 6a-ex | exports 조건 해석 Node.js 스펙 준수 (tslib CJS→ESM 해결) | ✅ |
| 6b. Dev server | HTTP+WS, Live Reload, HMR, React Fast Refresh, CSS 핫 리로드 | ✅ |
| Test262 | 50,504건 100% 통과 | ✅ |
| Smoke | 125개 패키지, avg 0.74x, ❌ 0개 | ✅ |

### 🔜 다음 우선순위: 번들러 성능 — esbuild 수준 달성
현재 1102모듈 대형 번들 기준: ZTS 1502ms vs esbuild 77ms (20배 차이).
목표: ~120-180ms (esbuild의 1.5-2.3배).

**Phase 7-1: StmtInfo를 파서/semantic에서 구축 (Part 시스템)**
- 현재: 파싱 후 tree_shaker.analyze()에서 stmt_info.build()로 전체 AST 재순회 → 723ms
- 목표: semantic analyzer에서 파싱 중 per-statement declared/referenced 심볼을 구축
  - analyzer.symbol_ids + scope 정보를 활용해 Part 데이터를 파싱 시점에 채움
  - stmt_info.build() 완전 제거, tree-shake 단계는 이미 구축된 데이터로 즉시 시작
- 참고: esbuild Part 시스템, bun ast.zig Part 구조체
- 예상: tree-shake 723ms → ~10ms

**Phase 7-2: emit 병렬화 (모듈별 transform+codegen을 스레드 풀)**
- 현재: emitter에서 모듈을 순차적으로 transform+codegen → 164ms
- 목표: 각 모듈의 transform+codegen을 독립적으로 스레드 풀에서 병렬 실행
  - 모듈별 Arena가 이미 독립적이므로 스레드 안전
  - linker rename 결과를 읽기 전용으로 참조, 최종 출력만 메인 스레드에서 합침
- 참고: bun generateChunksInParallel (Part 범위별 병렬)
- 예상: 164ms → ~40ms (4코어 기준)

**Phase 7-3: resolve 파이프라인 (Zig 0.16 async/await 또는 esbuild 방식)**
- 현재: parse(병렬) → resolve(순차) 배치 구조 → resolve 194ms
- 목표: parse+resolve를 하나의 워커 단위로 통합, 채널 기반 파이프라인
  - resolve_cache에 Mutex 추가, 스레드 풀에서 resolve 호출
  - 메인 스레드는 결과 수신 → addModule → 즉시 새 워커 스폰 (배치 경계 제거)
  - Zig 0.16 async/await 지원 시 rolldown join_all 방식도 검토
- 참고: esbuild goroutine+channel, bun ParseTask 2단계 (io_pool + worker_pool)
- 예상: graph 414ms → ~100ms

**Phase 7-4: link 최적화**
- 현재: computeRenames + scope hoisting → 87ms
- 목표: canonical_names 구축 최적화, 불필요한 순회 제거
- 예상: 87ms → ~30ms

### ⏳ 진행 중 / 미완료
- **ES 다운레벨링**: ES2022~ES2015 ✅ (--target=es5 지원)
  - 런타임 헬퍼 자동 주입 ✅ (__extends, __generator, __rest, __async — tslib 불필요)
- **.d.ts 생성** (isolatedDeclarations) — 후순위, 당분간 tsc에 위임
- **프로파일링 → SIMD → 미니파이어** — 번들러 완료 후
- **WASM 공개 AST API** — AST 안정화 후

### 상세 설계 문서
- **[BUNDLER.md](./BUNDLER.md)** — 번들러 상세 설계 (경쟁 환경, 모듈 설계, tree-shaking, RN 지원, 외부 통합)
- **[PLUGINS.md](./PLUGINS.md)** — 플러그인 시스템 + 로더 + 특수 기능 + CLI 옵션 추가 계획
- **[HMR.md](./HMR.md)** — Dev server + HMR 의사결정/아키텍처
- **[DECISIONS.md](./DECISIONS.md)** — 전체 의사결정 기록
- **[FLOW.md](./FLOW.md)** — Flow 지원 전략

### 의존성 관계
```
AST 안정화 ──────────────┬──→ WASM 공개 AST API
                         └──→ .d.ts (isolatedDeclarations)

번들러 성능 ─────────────┬──→ 7-1: Part 시스템 (semantic에서 StmtInfo 구축)
                         ├──→ 7-2: emit 병렬화 (7-1과 독립)
                         ├──→ 7-3: resolve 파이프라인 (Zig 0.16 async 또는 Mutex)
                         └──→ 7-4: link 최적화 (독립)

독립 (아무 때나): ES 다운레벨링, Flow, SIMD, 미니파이어
```

### 성능 최적화 도입 시기
| 최적화 | 추천 시점 | 이유 |
|--------|-----------|------|
| Arena allocator | ✅ 완료 | 번들러에 필수 |
| SIMD | 번들러 MVP 후 | 렉서만 건드려서 언제든 동일 비용 |
| 멀티스레드 parse+finalize | ✅ 완료 | finalize를 parseModule에 통합, parse_arena 소유 |
| tree-shaker 역인덱스 | ✅ 완료 | stmt_info O(N log S) + sym→stmt 역인덱스 |
| 비동기 resolve 병렬화 | Zig 0.16 async/await 지원 후 | 현재 resolve 95ms (모듈당 0.15ms)로 급하지 않음. Zig 0.16에서 async/await 복귀 예정 → rolldown 방식(join_all 패턴)으로 파일 내 import 병렬 resolve 가능. 그때 esbuild 방식(파일 단위 파이프라인)과 비교하여 결정 |
| 프로파일링 | 번들러 MVP 후 | 실제 워크로드 필요 |

## Commands
```bash
zig build          # 빌드
zig build run      # 실행
zig build test     # 유닛 테스트
zig build test262  # Test262 러너 테스트
```

## ZTS CLI 옵션 (현재 지원)

### 트랜스파일
```bash
zts <file.ts>                    # 트랜스파일 → stdout
zts <file.ts> -o <out.js>       # 트랜스파일 → 파일
zts <dir/> --outdir <out/>      # 디렉토리 재귀 변환
zts - < input.ts                # stdin 입력
```

### 번들
```bash
zts --bundle <entry.ts>                          # 번들 → stdout
zts --bundle <entry.ts> -o out.js                # 번들 → 파일
zts --bundle <entry.ts> --splitting --outdir dist  # 코드 스플리팅
```

### 공통 옵션
```
--format=esm|cjs|iife            모듈 포맷 (기본: esm, --platform=browser 시 iife)
--platform=browser|node|neutral  타겟 플랫폼 (기본: browser)
--minify                         출력 압축
--sourcemap                      소스맵 생성 (.js.map)
--ascii-only                     non-ASCII를 \uXXXX로 이스케이프
--quotes=<style>                 문자열 따옴표 (double|single|preserve, 기본: double)
--drop=console                   console.* 호출 제거
--drop=debugger                  debugger 문 제거
--define:KEY=VALUE               글로벌 치환 (예: --define:DEBUG=false)
--external <pkg>                 패키지를 번들에서 제외 (반복 가능)
--experimental-decorators        legacy decorator 변환 (tsconfig compilerOptions 지원)
--use-define-for-class-fields=false  class field → constructor this.x = v 변환
-w, --watch                      파일 변경 감시
-p, --project <path>             tsconfig.json 경로
```

### Dev 서버
```
--serve [dir]                    정적 파일 서버 (기본: .)
--serve --bundle <entry.ts>      번들+서빙 (HMR 지원)
--port <number>                  서버 포트 (기본: 3000)
```

### 자동 동작 (esbuild 호환)
- `--platform=browser` + `--bundle` → format 기본값 IIFE (글로벌 스코프 오염 방지)
- `--platform=browser` + `--bundle` → `process.env.NODE_ENV`를 `"production"`으로 자동 define
- `--platform=browser` → Node 내장 모듈(fs, path, util 등) 빈 모듈로 대체
- `--platform=browser` → `package.json "browser"` 필드에서 disabled 파일 감지
- `--platform=node` → Node 내장 모듈 + 서브패스(fs/promises, stream/web) 자동 external
- `import.meta` → CJS+node: `require("url").pathToFileURL(__filename).href` / CJS+browser: `""`

## Test Suite

### Test262 (TC39 정합성)
```bash
zig build test262                       # 전체 실행 (50,504건)
zig build test262 -- --filter=language  # 언어 기능만
zig build test262 -- --verbose          # 상세 출력
```

### 유닛 테스트
```bash
zig build test                          # 모든 모듈 테스트
```
테스트 위치: 각 모듈 파일 하단 (`test "..." { ... }` 블록)
- `src/lexer/scanner.zig` — 렉서 유닛 테스트
- `src/parser/parser.zig` — 파서 유닛 테스트
- `src/transformer/transformer.zig` — 변환기 유닛 테스트
- `src/codegen/codegen.zig` — 코드젠 형식 테스트
- `src/bundler/bundler.zig` — 번들러 통합 테스트
- `src/semantic/analyzer.zig` — 의미 분석 테스트

### 통합 테스트 (Bun)
```bash
cd packages/integration && bun test     # CLI 통합 테스트
cd packages/e2e && bun test             # Playwright E2E (dev server)
```

### 스모크 테스트 (실제 패키지 빌드)
```bash
cd packages/benchmark && bun run smoke.ts  # 125개 패키지 빌드+실행 검증 (avg 0.74x)
```

## Development Workflow

### 구현 규칙
1. **작업 단위를 최대한 작게 나눈다** — 하나의 PR이 하나의 기능/토큰 그룹을 담당
2. **서브에이전트로 병렬 구현** — 독립적인 작업은 서브에이전트를 활용해 병렬 진행
3. **PR 단위로 올린다** — main에 직접 push하지 않고 feature branch → PR → merge
4. **`/simplify` 리뷰** — PR 올린 후 반드시 `/simplify`로 코드 품질 점검
   - 코드 재사용, 품질, 효율성 검토
   - 발견된 이슈 수정 후 merge
5. **테스트 먼저** — 구현 전에 해당 Test262 카테고리 또는 유닛 테스트 작성
6. **Zig 초보자에게 자세히 설명** — 모든 코드 작성 시 왜 이렇게 하는지 설명

### PR 네이밍 규칙
```
feat(lexer): add numeric literal tokenization
feat(parser): add expression parsing
fix(lexer): handle edge case in template literal nesting
```

### 브랜치 전략
```
main ← feature/lexer-token-enum
     ← feature/parser-expression
     ← fix/bundler-cjs-interop
     ...
```

## References
- Bun JS Parser: github.com/oven-sh/bun (src/js_parser.zig, src/js_lexer.zig)
- oxc: github.com/oxc-project/oxc (crates/oxc_parser/src/lexer/kind.rs — 토큰 enum 참고)
- SWC: github.com/swc-project/swc
- esbuild: github.com/evanw/esbuild
- Hermes: github.com/facebook/hermes (Flow 파서)
- Metro: github.com/facebook/metro (RN 번들러)
- TypeScript: github.com/microsoft/TypeScript (다운레벨링/decorator 테스트케이스)
- Test262: github.com/tc39/test262
- ECMAScript Spec: tc39.es/ecma262
