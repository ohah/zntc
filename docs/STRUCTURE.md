# Project Structure

```
src/
  main.zig                  # CLI 엔트리포인트 (zntc 커맨드, zntc.config.json 자동 로드)
  root.zig                  # 라이브러리 엔트리포인트 (모든 모듈 re-export)
  transpile.zig             # 트랜스파일 파이프라인 통합 (파일/stdin → JS 출력)
  diagnostic.zig            # 진단 (ParseError, SemanticError 통합, multi-span label)
  diagnostic_renderer.zig   # rich diagnostic 렌더러 (코드 프레임, ANSI, multi-span)
  rich_diagnostic.zig       # 렌더링 기반 구조 (SourceInfo, RenderOptions)
  error_codes.zig           # ZNTCxxxx 에러 코드 + docs URL 매핑
  ansi.zig                  # ANSI 컬러 유틸
  levenshtein.zig           # "did you mean?" 제안
  string_escape.zig         # 공용 문자열 escape 유틸
  crash_handler.zig         # panic handler (Bun 스타일 crash report)
  debug_log.zig             # 디버그 로깅 유틸
  config.zig                # 설정 구조 (CompilerOptions, ResolverOptions, BundlerOptions)
  config_test.zig           # 설정 로딩 테스트
  config_options_dto_test.zig  # Zig DTO ↔ TS BuildOptions 필드 sync 검증
  tsconfig_merge.zig        # tsconfig.json extends/머지 로직
  profile.zig               # --profile / phaseDurations 측정 (cold/HMR 진단)
  bench.zig                 # 내부 마이크로벤치 진입점
  mimalloc.zig              # mimalloc 바인딩 (릴리즈 빌드 backing allocator)
  runtime_helper_modules.zig  # __esm/__commonJS/__export 등 헬퍼 가상 모듈 정의
  runtime_helper_names.zig    # 헬퍼 식별자 매핑
  test_arena.zig            # 테스트 Arena 헬퍼
  test_fixtures.zig         # 통합 테스트용 fixture 로더
  test_regression.zig       # round1/2/4 회귀 fuzz 테스트 진입점
  fixtures/                 # Zig 단위 테스트 입력 자료 (transform 등)
  app/                      # zntc.app builder (Vite 대체 진입 — entry HTML/CSS/asset)
    mod.zig                 #   builder 엔트리
    build.zig               #   HTML 진입 그래프 + asset emit
    env.zig                 #   .env 처리, define 주입
  lexer/                    # Phase 1: 렉서 ✅
    mod.zig                 #   렉서 엔트리 + re-export
    token.zig               #   토큰 종류(Kind ~208개), Span, Token, 키워드 맵
    scanner.zig             #   스캔 로직 (모든 토큰 타입 처리)
    unicode.zig             #   유니코드 식별자 (UTF-8 디코딩, ID_Start/ID_Continue)
  parser/                   # Phase 2: 파서 ✅
    mod.zig                 #   파서 엔트리 + re-export
    parser.zig              #   파서 메인 로직
    ast.zig                 #   AST 노드 정의 (~200개 Tag, 24B 고정)
    ast_walk.zig            #   variant-typed AST walker (Reference flags, identity)
    expression.zig          #   표현식 파싱 (precedence climbing, cover grammar)
    statement.zig           #   문 파싱 (if/for/while/switch 등)
    declaration.zig         #   선언 파싱 (function/class/const 등)
    binding.zig             #   바인딩 패턴 (destructuring, rest, default)
    object.zig              #   객체/클래스 멤버 파싱
    jsx.zig                 #   JSX 파싱 (element, fragment, attributes)
    module.zig              #   import/export 파싱
    ts.zig                  #   TypeScript 타입 어노테이션 파싱
    flow.zig                #   Flow 타입 어노테이션 파싱 (TIER 1+2+3, Metro 검증)
    scan_results.zig        #   파싱 부산물 (binding/import scan 결과 캐시)
  semantic/                 # 의미 분석 ✅
    mod.zig                 #   의미 분석 엔트리 + re-export
    analyzer.zig            #   의미 분석기 (스코프/심볼/Reference flags)
    checker.zig             #   검증 (엄격 모드, 예약어, 중복 선언)
    scope.zig               #   스코프 체인 (플랫 배열 + 부모 인덱스)
    symbol.zig              #   심볼 테이블 (이름, 종류, 플래그, 참조 수)
  transformer/              # Phase 3: 트랜스포머 ✅ + ES 다운레벨링 ✅
    mod.zig                 #   트랜스포머 엔트리 + re-export
    transformer.zig         #   Visitor 기반 순회 + AST 변환 (core dispatch)
    transformer/            #   transformer 서브 모듈 (delegation 패턴)
      refresh.zig           #     React Fast Refresh ($RefreshReg$/$RefreshSig$)
      class_decorator.zig   #     class 변환 + experimental decorators
      worklet.zig           #     react-native-reanimated worklet 추출
    plugins/                #   trampoline AST 플러그인 (Zig builtin)
      builtin.zig           #     기본 셋업
      worklet.zig           #     worklet plugin entry
    ast_plugin.zig          #   AST 플러그인 트램폴린 디스패처
    plugin_state.zig        #   플러그인 공유 상태/심볼 매니저
    runtime_helper_imports.zig  # 헬퍼 import 자동 주입
    compat.zig              #   엔진 타겟 호환성 매핑 (chrome/safari/node feature-level)
    jsx_lowering.zig        #   JSX lowering (classic/automatic/automatic-dev)
    regex_lower.zig         #   RegExp 다운레벨링 (named groups, dotAll, sticky 등)
    unicode_escape_lower.zig  # 식별자/문자열 \u{...} 다운레벨
    es2025_using.zig        #   ES2025 다운레벨링 (using/await using)
    es2024.zig              #   ES2024 다운레벨링
    es2022.zig              #   ES2022 다운레벨링 (class static block, this 치환)
    es2022_tla.zig          #   Top-level await 다운레벨
    es2021.zig              #   ES2021 다운레벨링 (??=, ||=, &&=)
    es2020.zig              #   ES2020 다운레벨링 (??, ?.)
    es2019.zig              #   ES2019 다운레벨링 (optional catch binding)
    es2018.zig              #   ES2018 다운레벨링 (object spread)
    es2018_for_await.zig    #   for-await-of → 상태 머신
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
    es2015_object_methods.zig  # 메서드 단축 → function expression
    es_helpers.zig          #   다운레벨링 헬퍼 유틸
    minify.zig              #   AST 미니파이어 (별도 패스, new_ast in-place 수정)
  codegen/                  # Phase 4: 코드 생성 ✅
    mod.zig                 #   코드젠 엔트리 + re-export
    codegen.zig             #   코드 생성 (formatting, minify, indentation)
    sourcemap.zig           #   V3 소스맵 생성 (VLQ 인코딩, lazy build)
    mangler.zig             #   식별자 축약 (번들러 심볼 데이터 활용)
    private_mangler.zig     #   private field/method 축약
    unified_mangler.zig     #   통합 mangler 엔트리
    function_map.zig        #   sourcemap names + function range 매핑
    codegen_test/           #   코드젠 테스트 (분리 모음)
      helpers.zig           #     공용 헬퍼 (TestResult, e2e*, SourceMapTestResult)
      basic.zig             #     기본 codegen 출력
      features.zig          #     E2E 기능 (class, arrow, async, destructuring 등)
      cjs_importmeta.zig    #     CJS 포맷 + import.meta
      es_downlevel.zig      #     ES 버전별 다운레벨링
      minify_sourcemap.zig  #     minify + source map
      flow.zig              #     Flow 타입 스트리핑
      engine_jsx.zig        #     엔진 타겟 + JSX 런타임
      private_jsx_advanced.zig #  private method, JSX auto, ES2025
      class_expr_anonymize.zig # 미참조 class expression 익명화
      decorator.zig         #     Stage 3 decorator
      function_map.zig      #     sourcemap names 보존
      import_attributes.zig #     ES2024 with {...}
      skip_nodes_blank.zig  #     skip-node 빈 블록 처리
  bundler/                  # Phase 6a: 번들러 ✅
    mod.zig                 #   번들러 엔트리 + 오케스트레이션
    bundler.zig             #   번들러 메인 로직
    resolver.zig            #   모듈 경로 해석 (node_modules, package.json, tsconfig)
    graph.zig               #   모듈 그래프 (DFS, exec_index, 순환 감지)
    module.zig              #   모듈 데이터 (AST, import/export, 심볼, def_format, interop)
    module_list.zig         #   증분 빌드 안전한 안정 인덱스 모듈 컨테이너
    module_store.zig        #   PersistentModuleStore (증분 빌드 파싱 캐시)
    linker.zig              #   스코프 호이스팅 + 이름 충돌 해결 + CJS↔ESM Interop
    linker/                 #   linker 서브 모듈
      metadata.zig          #     per-module LinkingMetadata 빌드
    tree_shaker.zig         #   Tree-shaking (export 추적, @__PURE__, sideEffects, 도달성)
    statement_shaker.zig    #   Statement-level DCE (span 기반 폴백)
    stmt_info.zig           #   StmtInfo (rolldown 방식 심볼 기반 statement 도달성 분석)
    purity.zig              #   순수성 분석 (expression/statement/varDecl/class 공유)
    constant_facts.zig      #   상수 사실 추적 (inline 가능 여부)
    chunk.zig               #   Code splitting (BitSet, 공통 청크, cross-chunk)
    emitter.zig             #   출력 생성 (exec_index 순서, ESM/CJS/IIFE)
    emitter/                #   emitter 서브 모듈
      dev.zig               #     dev mode 번들링 (HMR, __zntc_register)
      chunks.zig            #     code splitting + hash/naming
      esm_wrap.zig          #     __esm 래퍼 + export getter
      cjs_wrap.zig          #     __commonJS 래퍼
      external_imports.zig  #     external 의존성 import 헤더
    css_scanner.zig         #   CSS @import 추출기 (경량 상태 머신)
    css_emitter.zig         #   CSS 번들 생성 (@import strip + 연결 + 파일명 패턴)
    types.zig               #   번들러 자료 구조 (Interop, ModuleDefFormat, ExportsKind 등)
    symbol.zig              #   번들러 전용 심볼 테이블 (cross-module rename)
    package_json.zig        #   package.json 읽기 (exports, browser, sideEffects)
    resolve_cache.zig       #   해석 결과 캐싱 (import kind별)
    import_scanner.zig      #   import/export 문 추출
    binding_scanner.zig     #   심볼 바인딩 추적
    plugin.zig              #   Zig builtin 플러그인 (함수 포인터 기반, 내부 전용)
    json_to_esm.zig         #   JSON → ESM AST 변환 (export default <value>)
    asset_meta.zig          #   asset 로더 메타 (file/dataurl/text/binary/copy)
    block_list.zig          #   noExternal/exclude 패턴 매칭
    fs.zig                  #   번들러 fs 추상화 (in-mem fixture 지원)
    phase.zig               #   파이프라인 phase 정의 (scan/resolve/link/emit)
    mpsc_channel.zig        #   MPSC 채널 (Producer-Consumer 파이프라인)
    incremental.zig         #   증분 빌드 로직 (watch/serve 리빌드)
    compiled_module.zig     #   transform/codegen 결과 캐시 단위
    compiled_cache.zig      #   compiled module 캐시 매핑
    runtime_helpers.zig     #   런타임 헬퍼 (__esm, __commonJS, __export 등)
    test_helpers.zig        #   번들러 통합 테스트 헬퍼
    bundler_test/           #   번들러 통합 테스트 (분리 모음)
      basic.zig             #     기본 번들링, 링커, re-export, scope hoist
      typescript_format.zig #     TypeScript, format, edge, complex
      compat.zig            #     Rollup/esbuild/Bun/Rolldown/Webpack 호환
      default_deconflict.zig #    default export, deconflict, assignment
      patterns.zig          #     real-world 패턴, error, mixed
      expressions.zig       #     expression, class, control flow, async
      jsx.zig               #     JSX 컴포넌트, deconflict
      resolution.zig        #     package.json, extension, dynamic import
      tree_shake.zig        #     tree shaking, pure, sideEffects
      cjs_esm.zig           #     CJS interop, ESM wrap, TLA
      splitting_dev.zig     #     code splitting, dev mode
      minify_loader.zig     #     minify, asset loader
      plugin_misc.zig       #     plugin, worker, JSX auto, RN
      manual_chunks.zig     #     Rollup manualChunks 호환
      function_map.zig      #     sourcemap function 매핑
      exports_name_dedup.zig #    export 이름 중복 제거
      lowering_rename_leak.zig # 다운레벨/rename 누수 가드
      ns_member_shadow.zig  #     namespace member shadowing
      virtual_ns_treeshake.zig # virtual namespace tree-shake
  server/                   # Phase 6b: 개발 서버 + HMR ✅
    mod.zig                 #   서버 엔트리 + re-export
    dev_server.zig          #   HTTP + WebSocket 서버 (HMR, Fast Refresh, SSE, MCP, Control API)
    file_watcher.zig        #   파일 변경 감지 (watch/serve, watchFolders 지원)
    watch_scan.zig          #   공통 디렉토리 walker (TOCTOU-free, glob filter)
    tracked_file_set.zig    #   감시 대상 파일 추적 (StableSegmentedList 기반)
    mime.zig                #   MIME 타입 매핑
  regexp/                   # RegExp 검증 ✅
    mod.zig                 #   RegExp 엔트리 + re-export
    parser.zig              #   RegExp 패턴 파서 (comptime 모드 분리)
    ast.zig                 #   RegExp AST
    flags.zig               #   플래그 처리 (g, i, m, u, v, d, s)
    unicode_property.zig    #   유니코드 프로퍼티 (\p{Letter} 등)
    diagnostics.zig         #   RegExp 에러 메시지
  test262/                  # Test262 러너
    mod.zig                 #   Test262 엔트리
    runner.zig              #   메타데이터 파서 + 테스트 실행기
    main.zig                #   `zig build test262-run` 진입점
  util/                     # 공용 유틸
    mod.zig                 #   엔트리
    wyhash.zig              #   wyhash 해시 (콘텐츠 해시 / mangler)

packages/
  core/                     # @zntc/core — C NAPI .node addon + Node CLI + lightningcss
    bin/                    #   `zntc` CLI 엔트리 (zntc.mjs) — dev/preview/build app 시 @zntc/web 을 lazy import
    src/                    #   napi_entry.zig + JS 사이드 (config-loader/load-env/workspace 등)
    index.ts                #   JS API (init/transpile/build) — NAPI .node 로드 + 옵션 검증
    dist/                   #   bun build 산출물 (배포용)
  web/                      # @zntc/web — dev server / postcss·sass / HMR overlay (#2539)
    runtime/                #   APP_DEV_HMR_CLIENT (브라우저 inject 용)
    src/                    #   inject / dev-controller / style/ (postcss · sass · css-modules · css-parser · loader)
    dist/                   #   zntc self-build (server 가 inline)
  server/                   # @zntc/server — private (npm 미공개, web/RN 공통 protocol/watcher/HMR)
    src/                    #   protocol (HMR_MSG / 상수) / ws-frame (RFC 6455) / watcher / hmr-channel
    dist/                   #   zntc self-build — web 의 dist 에 자동 inline
  wasm/                     # @zntc/wasm — WASM 빌드 (브라우저 playground, Deno/Workers)
    src/wasm_entry.zig      #   transpile only WASM 진입
    src/wasm_bundler_entry.zig  # 번들러 포함 WASM 진입 (wasm32-wasi + threads)
  shared/                   # core/wasm 공유 타입 (TranspileOptions, Target, compat-engines)
  @zntc/vite-plugin/          # Vite 플러그인 (esbuild transform → ZNTC 교체, @zntc/core 만 사용)

tests/
  test262/                  # TC39 공식 Test262 (서브모듈, 50,504건)
  integration/              # Bun 기반 CLI/NAPI 통합 테스트 (60+ 스위트)
    tests/
      tsc/                  #   TypeScript 컴파일러 테스트케이스 포팅 (36개, ES 다운레벨/decorator/enum 등)
      fixtures/             #   round1/2/4 회귀, RN, RSC, AST 보존 등 fixture
      __snapshots__/        #   bun snapshot
  e2e/                      # Playwright E2E 테스트 (dev server, browser, sourcemap, vite/zntc builder)
  benchmark/                # 스모크 테스트 + 벤치마크
    smoke.ts                #   144 케이스 패키지 빌드+실행 검증 (vs esbuild/rolldown/rspack)
    bundle-perf.ts          #   번들 perf 회귀 가드 (small/medium/large × median 비교)
    bench.ts / pipeline.ts  #   합성 벤치 (200 모듈, 단계별 시간)
    napi-bench.ts           #   NAPI 콜백 hot-path 벤치 (#1891)
    minify-bench.ts / size-gap.ts / tree-shake-size.ts  # 사이즈/미니파이 비교
    mangler-property.ts     #   property mangler 안정성 fuzz
    transpile-conformance.ts #  TS strip + 다운레벨 정합성
    extract-esbuild-tests.ts #  esbuild 회귀 케이스 임포트
    smoke-diagnostics.test.ts # 스모크 결과 회귀 어서션
    baselines/              #   특수 목적 baseline JSON (예: mangler-property)

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

vendor/
  mimalloc/                 # mimalloc backing allocator (release 빌드)
  node-api-headers/         # NAPI v8 헤더

scripts/                    # 보조 스크립트 (release/audit/sync 등)
documents/                  # Vite/Tailwind 데모 (Vite 7 pin)
tools/                      # 개발 도구
```

## Build Steps (build.zig)

| Step | 설명 |
|------|------|
| `zig build` | `zntc` CLI + 정적 라이브러리 빌드 |
| `zig build run -- <args>` | CLI 직접 실행 |
| `zig build test` | 모든 모듈 유닛 테스트 |
| `zig build test262` | Test262 러너 자체 테스트 |
| `zig build test262-run` | Test262 50,504건 실행 (pass-rate 측정) |
| `zig build napi` | `@zntc/core` 용 NAPI .node 빌드 (`zig-out/lib/zntc.node`) |
| `zig build wasm` | `@zntc/wasm` transpile-only WASM |
| `zig build wasm-bundler` | bundler 포함 WASM (wasm32-wasi + threads) |
| `zig build schema` | `BuildOptions` JSON 스키마 자동 생성 |
| `zig build bench-callback` | NAPI 콜백 hot-path 마이크로벤치 (#1891) |
