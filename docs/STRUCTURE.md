# Project Structure

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
  core/                     # N-API 바인딩 (npm 패키지)
tests/
  test262/                  # TC39 공식 Test262 (서브모듈)
  integration/              # Bun 기반 CLI 통합 테스트
  e2e/                      # Playwright E2E 테스트 (dev server)
  benchmark/                # 스모크 테스트 + 벤치마크 (smoke.ts)
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
