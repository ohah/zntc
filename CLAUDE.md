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
    minify.zig              #   AST 미니파이어 (별도 패스, new_ast in-place 수정)
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
  → Minifier (--minify 시: constant folding, DCE, boolean simplification)
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
| Smoke | 125개 패키지, avg 0.94x, ❌ 0개 | ✅ |
| 7-2. emit 병렬화 | 모듈별 transform+codegen 스레드 풀 실행 | ✅ |
| 7-3. resolve 병렬화 | 배치 내 resolve 스레드 풀 + ResolveCache Mutex | ✅ |
| 7-fix. fixpoint oscillation | 미사용 모듈 제거를 fixpoint 후로 이동 (100회→2회) | ✅ |
| 8. AST 미니파이어 | constant folding, DCE, boolean simplification, comma operator | ✅ |
| 9. 배치 A | 번들러 옵션 10개 (alias, banner, globalName, publicPath, JSON ESM 등) | ✅ |
| 10. 배치 B | content hash + naming 패턴 (--entry-names, --chunk-names) | ✅ |

### 번들러 성능 현황 (3242모듈, 2026-03-29 실측)
ZTS 279ms vs esbuild 182ms (**1.5배**).

| 단계 | ZTS | esbuild | 배율 | 비고 |
|------|-----|---------|------|------|
| scan (resolve+parse) | 240ms | 125ms | 1.9x | 배치 구조 한계 |
| tree-shake | 51ms | 1ms | 51x | fixpoint+stmtinfo+crossBFS |
| link | 16ms | 54ms | 0.3x | ZTS가 빠름 |
| emit | 15ms | 32ms | 0.5x | ZTS가 빠름 |
| **총합** | **279ms** | **182ms** | **1.5x** | |

### 🔜 다음 우선순위

**scan 파이프라인화 (배치 경계 제거)**
- 현재: parse 배치 → resolve 배치 → parse 배치 (배치 경계에서 대기 발생)
- 목표: Bun/esbuild처럼 모듈 발견 즉시 다음 파싱 시작 (태스크 큐 기반 파이프라인)
  - Bun: io_pool + worker_pool 2단계 ParseTask
  - esbuild: goroutine + channel
  - ZTS: 스레드 풀 + atomic 큐로 구현 가능 (Zig 0.16 async 불필요)
- 예상: scan 240ms → ~130ms

**tree-shake 알고리즘 개선**
- 현재: fixpoint 2회 + stmtinfo 15ms + crossBFS 25ms = 51ms
- esbuild는 Part 시스템으로 단일 패스 1ms
- 점진적 개선: stmtinfo 병렬화, used_exports를 BitSet으로 교체 등

### ⏳ 미완료
- **.d.ts 생성** (isolatedDeclarations) — 후순위, 당분간 tsc에 위임
- **SIMD** — 렉서 공백/식별자/문자열 스캔 가속 (parse 10-20% 개선 예상)
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

번들러 성능 ─────────────┬──→ scan 파이프라인화 (배치 경계 제거)
                         └──→ tree-shake 알고리즘 개선 (stmtinfo/crossBFS)

번들러 기능 ─────────────┬──→ 로더 시스템 (JSON, text, file, dataurl)
                         ├──→ CSS 번들링 (별도 파서)
                         └──→ 플러그인 API (Zig builtin → N-API JS)

독립 (아무 때나): Flow, SIMD
```

### 미지원 기능 (상용 번들러 대비)

esbuild / rolldown / rspack 기준으로 ZTS에 빠진 기능 목록.
- **난이도**: S(반나절) / M(1~2일) / L(3~5일) / XL(1주+)
- **선행**: 먼저 구현해야 하는 기능. 없으면 독립
- **배치**: 같이 묶어서 한 PR로 할 수 있는 그룹

#### Critical (없으면 실사용 어려움)

- **Asset 로더** (file, dataurl, text, binary, copy) — `L` | 선행: ✅ content hash, naming 패턴 | 배치: C
  이미지, 폰트, SVG, `.txt`, `.wasm` 등 non-JS 파일을 import할 수 없음.
  esbuild는 `--loader:.png=file` 형태로 파일 타입별 로더 지정. file 로더는 해시 파일명으로 복사 + URL 문자열 export, dataurl은 base64 인라인.
  React/Vue 프로젝트에서 `import logo from './logo.png'` 패턴이 매우 흔하므로 없으면 프론트엔드 프로젝트 빌드 불가.
  **현황**: ModuleType.asset 정의만 있고 parseModule()에서 source도 안 읽음. emitter에서 완전 제외. 로더별 emit 로직 + 출력 다중화 필요.

- **CSS 번들링** — `XL (2~3주)` | 선행: emitter 출력 다중화 | 배치: 단독
  JS에서 `import './style.css'`를 처리하지 못함. CSS Modules (`import styles from './foo.module.css'`)도 미지원.
  esbuild는 CSS 파서를 내장하여 `@import` 해석 + 중복 제거 + minify까지 처리. rolldown/rspack은 PostCSS/Lightning CSS 통합.
  프론트엔드 앱의 거의 100%가 CSS import를 사용하므로, JSON 로더와 함께 가장 시급한 기능.
  **현황**: CSS 파서를 새로 작성해야 함. ModuleType.css는 정의되어 있으나 파싱/emit 로직 전무. 가장 큰 작업.

- **플러그인 API** — `XL (2~3주)` | 선행: 로더 시스템 안정화 | 배치: 단독
  사용자가 빌드 파이프라인을 확장할 수 없음. 커스텀 로더, 가상 모듈, 코드 변환 등 모두 불가.
  esbuild는 onResolve/onLoad 훅, rolldown은 Rollup 호환 resolveId/load/transform 훅 제공.
  위의 JSON/Asset/CSS도 플러그인 없이는 사용자가 직접 해결할 방법이 없으므로, 생태계 확장의 전제 조건.
  **현황**: 훅 포인트 설계 + Zig 인터페이스 + (이후) N-API JS 바인딩. resolver/graph/emitter 모두 수정 필요.

- **metafile** — `M` | 선행: 없음 | 배치: D
  빌드 결과의 입출력 파일, 사이즈, import 관계를 JSON으로 출력하는 기능이 없음.
  esbuild는 `--metafile=meta.json` 으로 번들 구성 분석 데이터 생성. bundle-buddy, esbuild-visualizer 등 시각화 도구의 입력.
  CI에서 번들 사이즈 회귀 감지, PR 코멘트에 사이즈 변화 표시 등 프로덕션 워크플로에 필수.
  **현황**: emitter에서 모듈/청크 정보는 이미 가지고 있음. JSON 직렬화 + CLI 옵션만 추가.

#### Important (프로덕션 배포에 자주 필요)

- **inject** — `M` | 선행: 없음 | 배치: D
  모든 파일에 특정 모듈을 자동 import하는 기능이 없음.
  esbuild는 `--inject:./polyfill.js`로 React import 자동 삽입, process 심 주입, 글로벌 폴리필 등에 활용.
  JSX 자동 런타임(`react/jsx-runtime`) 도입 전에는 매 파일에 `import React` 필요했고, inject로 해결하는 패턴이 여전히 흔함.
  **현황**: graph 빌드 시 각 모듈의 import_records에 가상 import 삽입. inject 파일 자체도 모듈 그래프에 포함시켜야 함.

- **legal comments** — `M` | 선행: 없음 | 배치: D
  `@license`, `@preserve`, `/*!` 로 시작하는 라이센스 주석의 처리 방식을 지정할 수 없음.
  esbuild는 `--legal-comments=eof|linked|external|none` — eof는 파일 끝에 모음, linked는 별도 `.LEGAL.txt` + 참조 주석.
  오픈소스 라이센스 준수를 위해 프로덕션 빌드에서 라이센스 주석을 보존하거나 별도 파일로 추출하는 것이 법적으로 필요.
  **현황**: scanner에서 주석 위치는 이미 추적. 특정 패턴 주석을 수집 + codegen/emitter에서 출력 모드 분기 필요.

- **keepNames** — `M` | 선행: 없음 | 배치: D
  minify 시 함수/클래스의 `.name` 프로퍼티가 축약되는 것을 방지할 수 없음.
  esbuild는 `--keep-names` 플래그로 `Object.defineProperty(fn, "name", { value: "originalName" })` 자동 삽입.
  React DevTools, 에러 스택 트레이스, `Function.name` 기반 로직(직렬화, DI 컨테이너 등)이 깨지는 것을 방지.
  **현황**: mangler에서 이름 축약 후 원본 이름을 보존하는 AST 변환 추가. transformer에서 defineProperty 호출 삽입 필요.

- **엔진 타겟** (chrome, firefox, safari, node 버전) — `XL` | 선행: 없음 | 배치: 단독
  현재 `--target=es2020` 같은 ES 스펙 버전만 지원. 특정 브라우저/Node 버전 지정 불가.
  esbuild는 `--target=chrome90,firefox88,safari14` → 해당 엔진이 지원하지 않는 문법만 다운레벨링.
  ES 버전 기반은 보수적이라 불필요한 다운레벨링이 발생. 엔진 버전은 caniuse 데이터 기반으로 정밀 제어 가능.
  **현황**: caniuse 호환 데이터 테이블(엔진 버전 → ES 기능 매핑) 구축 필요. esbuild는 ~2000줄 테이블. 데이터 수집이 핵심 작업.

#### Nice to Have

- **analyze** — `S` | 선행: metafile | 배치: D
  번들 사이즈를 모듈/청크별로 분석하는 리포트 기능이 없음.
  esbuild는 `--analyze` 플래그로 터미널에 사이즈 트리 출력. metafile + 시각화 도구(bundle-visualizer)로 더 상세 분석 가능.
  "어떤 모듈이 번들을 크게 만드는가"를 파악하는 데 필수. 없으면 수동으로 external하면서 이진 탐색해야 함.
  **현황**: metafile 데이터를 트리 형태로 포맷팅하여 stdout 출력. metafile 구현 후 부산물.

- **mangleProps** — `XL` | 선행: 없음 | 배치: 단독
  객체 프로퍼티 이름을 축약하는 기능이 없음 (`{ longPropertyName: 1 }` → `{ a: 1 }`).
  esbuild는 `--mangle-props=_$` (접미사 패턴), `--reserve-props`, `--mangle-cache` (빌드 간 일관성) 지원.
  minify-identifiers보다 훨씬 공격적인 압축. 내부 API에만 적용해야 하므로 패턴 필터가 중요.
  **현황**: cross-module 프로퍼티 추적 + 패턴 매칭 + 캐시 파일 I/O. mangler.zig 확장이지만 복잡도 높음.

- **import.meta.glob** — `M` | 선행: 없음 (플러그인 API 없이 builtin 가능) | 배치: 단독
  `import.meta.glob('./pages/*.tsx')` 같은 파일시스템 글로브 패턴 import가 없음.
  Vite가 도입한 기능으로, rolldown/rspack도 지원. 빌드 타임에 매칭 파일들을 lazy import 객체로 변환.
  라우팅 자동 생성, i18n 파일 일괄 로딩 등 DX 편의 기능. 없어도 수동 import로 대체 가능.
  **현황**: transformer에서 import.meta.glob 호출 감지 → 파일시스템 글로브 → 동적 import 객체로 AST 치환.

- **Virtual modules** — `M` | 선행: 플러그인 API | 배치: 플러그인과 함께
  플러그인에서 파일시스템에 없는 가상 모듈을 생성할 수 없음 (`import env from 'virtual:env'`).
  esbuild는 onResolve + onLoad 훅으로 구현, rolldown은 `\0` prefix resolveId 컨벤션.
  환경변수 주입, 빌드타임 코드 생성, 프레임워크 매직 모듈(Vite의 `import.meta.env` 등)의 기반.
  **현황**: 플러그인 API의 onResolve/onLoad가 있으면 자연스럽게 지원됨. 플러그인 없이는 resolver에 가상 모듈 맵 하드코딩 필요.

#### 배치 그룹 & 구현 순서

```
배치 A ✅ 완료 ─────────────────────────────────────────────────
  JSON 로더 강화, resolve.alias, publicPath, banner/footer,
  globalName, out-extension, source-root/sources-content,
  log-level, charset, preserve-symlinks
  → 전부 옵션 추가 + 1~2줄 로직. 독립적이라 한번에 완료.

배치 B (1~2일) ✅ 완료 ──────────────────────────────────────────
  content hash (파일 내용 기반) + naming 패턴 ([name].[hash])
  → 2패스 placeholder 치환 (esbuild 방식). --entry-names, --chunk-names.

배치 C (3~5일, 배치 B 후) ──────────────────────────────────────
  Asset 로더 (file/dataurl/text/binary/copy)
  + emitter 출력 다중화 (JS 외 파일 출력)
  → content hash + naming 패턴 위에 구축.

배치 D (2~3일, 독립) ───────────────────────────────────────────
  metafile + analyze + inject + legal comments + keepNames
  → 각각 M 난이도지만 서로 독립. 2~3개씩 묶어서 PR 가능.

단독 XL ────────────────────────────────────────────────────────
  CSS 번들링 (2~3주) — CSS 파서 새로 작성
  플러그인 API (2~3주) — 파이프라인 훅 설계 + N-API
  엔진 타겟 (1주+) — caniuse 데이터 테이블 구축
  mangleProps (1주+) — cross-module 프로퍼티 추적
```

#### 기술부채 & 구조적 제약

현재 번들러는 **JS 전용으로 설계**되어 있음. 배치 A~D는 이 구조에 영향 없이 안전하게 구현 가능.
CSS 번들링/Asset 로더/플러그인 API는 아래 JS 전용 경계를 넘어야 함.

**배치별 기술부채 영향:**
| 작업 | JS 전용 구조에 부딪히나? | 새 부채 생성 위험? |
|------|----------------------|-----------------|
| 배치 A (옵션 10개) ✅ | 아니오 — 옵션 추가 + 출력 문자열 수준 | 없음 |
| 배치 B (content hash) | ✅ 완료 | 없음 |
| 배치 C (Asset 로더) | **예** — emitter/linker 분기 필요 | 접근 방식에 따라 다름 (아래 참고) |
| 배치 D (metafile 등) | 아니오 — 각각 독립적 | 없음 |
| CSS 번들링 | **예** — 구조 전면 수정 | CSS 파서 자체가 새 코드라 부채 아님 |
| 플러그인 API | **예** — 훅 포인트 삽입 | 설계만 잘하면 없음 |

**JS 전용 구조 — 수정이 필요한 계층 (배치 C/CSS/플러그인 시):**
| 계층 | 파일 | 현재 상태 | 필요한 변경 |
|------|------|----------|-----------|
| Module 구조체 | module.zig | `semantic`, `import_bindings`, `export_bindings`가 JS 전용 | CSS/asset 모듈 진입 시 null → 접근 코드마다 방어 체크, 또는 `asset_output` 필드 추가 |
| Linker | linker.zig | `export_map`이 JS 심볼 기반 | CSS/asset 모듈은 link() 시 스킵하거나 별도 경로 |
| Tree Shaker | tree_shaker.zig | `ast` 존재 + `export_bindings` 의존 | CSS/asset은 ast=null → side_effects=true 고정, 분석 스킵 |
| Emitter 필터 | emitter.zig | `is_js or is_json`만 sorted에 포함 | CSS/asset 포함으로 필터 확장 + 타입별 emit 분기 |
| Chunk | chunk.zig | "하나의 JS 파일" 가정, ChunkKind=entry/common만 | CSS 별도 청크 타입 추가 |
| BundleResult | bundler.zig | JS 출력만 반환 | `css_outputs`, `asset_outputs` 추가 |

**⚠️ Asset 로더 구현 시 반드시 피해야 할 접근:**
```
❌ asset을 가짜 JS 모듈로 위장 (fake AST + exports_kind=.esm)
   → linker/tree-shaker/codegen이 "JS인 척"하는 모듈로 처리
   → 나중에 CSS 번들링할 때 이 가정을 다시 뜯어야 하는 부채 발생

✅ 타입별 분기를 명시적으로 (asset_output 필드 + linker/tree-shaker 스킵)
   → CSS 추가 시 같은 패턴으로 확장 가능
```

**결론**: 배치 A~D를 먼저 해도 CSS/플러그인이 더 어려워지지 않음. JS 전용 경계는 어차피 CSS/Asset 구현 시점에 한 번 넘어야 하는 것이고, 다른 기능이 이 경계를 두껍게 만들지 않음.

### 성능 최적화 현황
| 최적화 | 상태 | 효과 |
|--------|------|------|
| Arena allocator | ✅ 완료 | 번들러 기반 |
| mimalloc | ✅ 완료 | c_allocator 대비 8% 추가 개선 |
| 멀티스레드 parse+finalize | ✅ 완료 | finalize를 parseModule에 통합 |
| tree-shaker 역인덱스 | ✅ 완료 | stmt_info O(N log S) + sym→stmt 역인덱스 |
| emit 병렬화 | ✅ 완료 | 74ms → 15ms (-80%) |
| resolve 병렬화 | ✅ 완료 | 191ms → 134ms (-30%, 캐시 히트율 높아 제한적) |
| fixpoint oscillation 수정 | ✅ 완료 | 100회 → 2회 수렴, tree-shake 238ms → 51ms |
| scan 파이프라인화 | 🔜 | 배치 경계 제거 → 240ms → ~130ms 예상 |
| SIMD | 미착수 | 렉서 공백/식별자/문자열 스캔 가속 |

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
--alias:FROM=TO              import 경로 별칭 (--alias:react=preact/compat)
--public-path=<url>          에셋/청크 URL prefix (CDN 배포용)
--banner:js=<text>           출력 파일 앞에 텍스트 삽입
--footer:js=<text>           출력 파일 뒤에 텍스트 삽입
--global-name=<name>         IIFE export 글로벌 변수명
--out-extension:.js=<ext>    출력 파일 확장자 변경 (.mjs, .cjs)
--source-root=<url>          소스맵 sourceRoot
--sources-content=false      소스맵에서 원본 소스 제외
--log-level=<level>          로그 레벨 (silent|error|warning|info)
--charset=utf8               non-ASCII를 이스케이프하지 않음
--preserve-symlinks          심링크를 따라가지 않고 링크 경로로 해석
--entry-names=<pattern>      엔트리 파일명 패턴 (기본: [name], 예: [name]-[hash])
--chunk-names=<pattern>      공통 청크 파일명 패턴 (기본: [name]-[hash], 예: chunks/[name]-[hash])
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
