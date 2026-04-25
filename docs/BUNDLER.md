# ZTS Bundler Design

번들러 상세 설계 문서.

## 경쟁 환경
- **Rolldown** (Rust, oxc 기반): Vite 생태계 백업, Rollup+esbuild 대체 목표. Rollup 플러그인 호환
- **esbuild** (Go): 속도 기준점, 범용 번들러, 플러그인 제한적
- **Bun** (Zig+C++): 런타임 내장 번들러, 속도 최우선
- **Turbopack** (Rust, SWC 기반): Next.js 전용, 증분 컴파일 특화

## ZTS 번들러 포지셔닝
- **전략: 품질 먼저 → 속도 추가 (방법 B)** — Rollup→Rolldown 전략을 Zig로
  - 1단계: 정확한 파서/트랜스포머 (✅ 완료, Test262 100%)
  - 2단계: 정확한 tree-shaking/스코프 호이스팅 (Rollup 알고리즘 참고)
  - 3단계: Arena + SIMD + 멀티스레드로 속도 확보 (알고리즘 타협 없이)
- **핵심 목표**: React Native 지원 (Metro 대체), ESM 순서 보장, WASM 임베디드 번들러
- **트레이드오프**: 코드베이스 최소화보다 정확도+기능 우선. 기능이 늘면 코드는 커짐을 수용

## Phase별 기능 분류
```
Phase B1: 기반 (✅ 완료)          Phase B2: 핵심 (✅ 대부분 완료) Phase B3: 고급
─────────────────                 ──────────────────          ──────────────
✅ 모듈 해석 (Node/TS)            ✅ CJS interop (입력)        플러그인 시스템
  ├ node_modules 탐색              ├ require() 감지/래핑        ├ resolve/load/transform 훅
  ├ package.json exports           ├ __commonJS/__toESM         ├ renderChunk/generateBundle 훅
  ├ tsconfig paths/baseUrl         └ ExportsKind 승격           ├ Plugin Context API (emitFile 등)
  └ 조건부 exports                                              ├ Rollup 플러그인 호환
✅ package.json browser 필드      ✅ Top-level await            └ Vite 플러그인 호환 (후순위)
  └ disabled 파일 → 빈 모듈       ✅ Code splitting            로더 시스템 (esbuild/Rolldown 호환)
✅ Node 빌트인 빈 모듈 대체         ├ BitSet 도달 가능성        ├ JSON (named export 지원)
  └ --platform=browser 시           ├ 공통 청크 자동 추출       ├ Text / Base64 / DataURL
    (disabled) CJS wrapper          ├ 멀티 파일 emitter         ├ Binary (Uint8Array)
✅ 모듈 그래프                       └ CLI --splitting          ├ File/Asset (해시 파일명)
  ├ 정적 import/export             개발 서버 + HMR              ├ Copy / Empty
  ├ 순환 참조 감지                  ├ ✅ HTTP + WS + Live Reload └ CLI: --loader:.ext=type
  └ 동적 import                    ├ ✅ 모듈 그래프 파일 감시  특수 기능
✅ 단일 파일 번들 생성              ├ ✅ 에러 오버레이 + 소스맵  ├ import.meta.glob (Vite 호환)
  └ 진입점 → 단일 출력             ├ ✅ import.meta.hot + FR    ├ Dynamic import variables
✅ 스코프 호이스팅                  └ ✅ CSS 핫 리로드           ├ Web Worker 번들링
  ├ 변수 이름 충돌 해결                                          └ Virtual modules (\0 prefix)
  ├ ESM 실행 순서 보장                                          CLI 옵션 확장
  └ CJS 호환 래핑                                                ├ --banner/--footer
✅ Tree-shaking (모듈 수준)                                      ├ --analyze (번들 사이즈)
  ├ export 사용 추적                                             ├ --minify-{whitespace|ids|syntax}
  ├ @__PURE__ / @__NO_SIDE_EFFECTS__                             ├ --pure:Name
  ├ sideEffects 필드                                             ├ --log-level
  └ cross-module 전파                                            ├ --legal-comments
                                                                 ├ --inject:file
                                                                 └ --target (엔진 버전)
                                                                React Native 지원
                                                                 ├ Metro 호환 해석
                                                                 ├ 플랫폼 확장자 (.ios/.android)
                                                                 ├ polyfill 주입
                                                                 └ Hermes 타겟 최적화
                                                                CSS 번들링 ✅
                                                                 ├ @import 인라이닝 (css_scanner.zig)
                                                                 ├ 별도 .css 파일 emit (css_emitter.zig)
                                                                 ├ Lightning CSS minify (optional)
                                                                 └ CSS modules (후순위)
```

## 모듈 설계 (책임 분리)
```
src/bundler/
  │
  ├─ mod.zig              # 번들러 엔트리 (파이프라인 오케스트레이션만)
  │
  ├─ resolver.zig         # 모듈 해석 (경로 → 파일)
  │   입력: import 경로 + 현재 파일 위치
  │   출력: 절대 파일 경로
  │   책임: node_modules, package.json, tsconfig paths
  │   의존: 파일시스템만. 파서 불필요.
  │
  ├─ graph.zig            # 모듈 그래프
  │   입력: 진입점 목록
  │   출력: 정렬된 모듈 목록 + 의존성 관계
  │   책임: DFS 순회, 순환 참조 감지, exec_index 부여
  │   의존: resolver + parser (파싱은 위임)
  │
  ├─ module.zig           # 모듈 단위 데이터
  │   입력: 파일 내용
  │   출력: AST + import/export 목록 + 심볼 테이블
  │   책임: 단일 모듈의 모든 정보 보유
  │   의존: parser, semantic analyzer
  │
  ├─ linker.zig           # 링킹 (스코프 호이스팅)
  │   입력: 모듈 그래프 + 각 모듈의 심볼
  │   출력: 글로벌 심볼 테이블 + 이름 충돌 해결
  │   책임: 심볼 바인딩, 이름 mangling, import→변수 교체
  │   의존: graph, module
  │
  ├─ tree_shaker.zig      # Tree-shaking
  │   입력: 링킹된 모듈 그래프
  │   출력: 사용/미사용 마킹
  │   책임: export 사용 추적, @__PURE__, sideEffects
  │   의존: linker
  │
  ├─ chunk.zig            # 청크 분할 (Code splitting)
  │   입력: tree-shaking된 모듈 그래프
  │   출력: 청크 목록 (어떤 모듈이 어떤 청크에)
  │   책임: 동적 import 분할, 공통 청크 추출
  │   의존: tree_shaker
  │
  ├─ emitter.zig          # 출력 생성
  │   입력: 청크 목록 + 링킹 정보
  │   출력: JS 파일 + 소스맵
  │   책임: exec_index 순서로 코드 배치, 런타임 로더 생성
  │   의존: codegen (기존 Phase 4 재사용)
  │
  ├─ css_scanner.zig      # CSS @import 추출기
  │   입력: CSS 소스 코드
  │   출력: CssImportRecord[] (specifier + span)
  │   책임: @import/@charset/주석 스킵, 첫 non-import 규칙에서 중단
  │
  └─ css_emitter.zig      # CSS 번들 생성
      입력: 모듈 그래프 + 엔트리 인덱스
      출력: 연결된 CSS OutputFile
      책임: DFS로 CSS 모듈 수집, exec_index 정렬, @import strip, 파일명 패턴
```

설계 원칙:
- **단방향 의존**: resolver → graph → linker → tree_shaker → chunk → emitter
- **독립 테스트 가능**: 각 모듈이 입력/출력 명확, 다른 모듈의 내부를 모름
- **기존 코드 재사용**: parser, semantic, codegen, transformer를 도구로 위임

## ESM 실행 순서 보장
- 스코프 호이스팅 시 원본 ESM의 top-level 코드 실행 순서가 바뀌면 안 됨
- 예: `import './a'; import './b';` → a.js의 사이드이펙트가 b.js보다 먼저 실행 보장
- 순환 참조 + 사이드이펙트 + 스코프 호이스팅이 충돌하는 복잡한 문제
- **모듈 그래프 설계 단계에서 잡아야 함** — 나중에 끼워넣기 어려움
- Rollup 참고: `rollup/src/utils/executionOrder.ts` (~100줄, DFS 후위 순서)
- Rolldown 참고: `rolldown/crates/rolldown/src/chunk_graph/`

## 모듈 그래프 설계 (Rollup 코드 분석 기반)
- Rollup의 `analyseModuleExecution`: DFS 후위 순서로 execIndex 부여
  - 정적 dependencies 재귀 방문
  - 순환 참조 → cyclePaths 기록 (에러 아닌 경고)
  - 동적 import → 별도 Set, 정적 의존성 처리 후 방문
  - top-level await 있는 동적 import → 정적 의존성으로 승격
- Rollup 자체도 "현재 알고리즘이 불완전" 인정 (주석에 명시)

**Module에 필요한 정보 (Rollup 분석 결과):**
```zig
const Module = struct {
    path: []const u8,
    ast: ?Ast,                     // 파싱된 AST (파싱 전에는 null)
    dependencies: []ModuleIndex,   // 정적 import (순서 보장 — 배열)
    dynamic_imports: []ModuleIndex,// 동적 import (별도 관리)
    implicit_before: []ModuleIndex,// 암시적 로딩 순서
    exports: ExportMap,            // export 이름 → 심볼
    side_effects: bool,            // tree-shaking 판단
    exec_index: u32,               // DFS 후위 순서 = 실행 순서
    cycle_group: u32,              // 순환 참조 그룹 ID
    uses_top_level_await: bool,    // 동적→정적 승격 판단
    state: enum { reserved, parsing, ready },
};
```

**병렬 파싱 + 순서 보장 전략 (Rolldown 방식):**
1. 진입점 파싱 → import 발견 → 그래프에 슬롯 예약 (import 순서대로)
2. 예약된 모듈을 병렬 파싱 (파일별 Arena, 멀티스레드)
3. 파싱 완료 → 예약 슬롯에 AST 채움 → 새로운 import 발견 → 다시 슬롯 예약
4. 모든 파싱 완료 후 DFS 후위 순서로 exec_index 부여 (싱글스레드)
5. 슬롯 예약 순서가 import 순서를 보장 → exec_index가 ESM 실행 순서 보장

## Tree-shaking 전략
- ✅ **1단계**: export 사용 추적 — 모듈 수준 tree-shaking (미사용 모듈 제거, fixpoint 분석)
- ✅ **2단계**: `@__PURE__` / `@__NO_SIDE_EFFECTS__` 활용 — 렉서 감지 → semantic/cross-module 전파 → 순수 호출 판별
- ✅ **2.5단계**: sideEffects 지원 — package.json `sideEffects: false` + 자동 순수 판별
- ✅ **2.5b**: sideEffects 글롭 패턴 — `sideEffects: ["*.css"]` 배열 형태 (matchGlob 기반)
- ⬜ **3단계**: 깊은 사이드 이펙트 분석 — getter/proxy/global 변수 판단 (후순위)
- **문장 수준 tree-shaking은 구현하지 않음** — esbuild/Bun과 동일하게 모듈 수준만 (Rollup만 문장 수준 지원)
- ZTS 유리점: semantic analyzer의 스코프/심볼이 이미 있고, `@__PURE__` 렉서 지원, 인덱스 기반 AST로 노드 제거가 태그 변경만으로 가능

## 스코프 호이스팅 deconflict 개선 (TODO — 구조적 수정 필요)
현재: well-known global 이름 목록(`isReservedName`)을 상수로 관리. 모듈의 top-level 변수가 글로벌을 shadowing하면 리네임.
- **문제**: 목록이 환경마다 다르고 (브라우저 vs Node.js), 수동 관리 필요. 누락 시 TDZ 버그.
- **목표**: Rolldown 방식 — `root_unresolved_references()` (실제 사용된 글로벌)를 자동 수집하여 예약. 상수 목록 불필요.
  - esbuild: `SymbolUnbound` (미해석 참조 = 글로벌)를 자동 예약 + 모듈 래핑으로 TDZ 방지
  - Rolldown: 2-phase renaming — root scope 글로벌 예약 → nested scope 캡처 방지 리네임
  - 참고: `references/rolldown/crates/rolldown/src/utils/renamer.rs`, `references/rolldown/crates/rolldown/src/utils/chunk/deconflict_chunk_symbols.rs`
  - 참고: `references/esbuild/internal/renamer/renamer.go` (ComputeReservedNames)
- **구현 시점**: semantic analyzer의 스코프/심볼 데이터가 이미 있으므로, 번들러 안정화 후 진행

## Code splitting 전략
- 동적 import (`import('./page')`) 기준 청크 분할
- 공통 모듈 추출: 여러 진입점이 공유하는 모듈 → 별도 청크
- 순환 참조: 같은 청크로 묶기
- 런타임 로더: 청크를 동적 로드하는 코드 생성 (ESM 기반)

## 테스트 전략 (TDD)
- **원칙**: 버그 하나 = 테스트 하나. 이슈 재현 테스트 먼저 → 수정 → 같은 버그 재발 방지
- **모듈별 유닛 테스트**: 파일시스템 없이 가짜 데이터로 격리 테스트
  - resolver ~50개, graph ~40개, linker ~30개, tree_shaker ~30개, emitter ~50개
- **픽스처 테스트**: `tests/bundler/fixtures/` — 입력 파일 → 기대 출력 비교
- **실행 비교 테스트 (핵심)**: 번들 결과를 실행해서 동작 확인 (출력 형태보다 실행 결과가 중요)
- **호환 테스트**: 같은 입력으로 Rollup과 실행 결과 비교 (Rolldown 방식)
- ✅ **스모크 테스트**: 111개 패키지 빌드+실행 검증 (CI 통합, tests/benchmark/smoke.ts)
- **도입 순서**: B1에서 유닛+픽스처 → B2에서 실행 비교+호환 → ✅ 프로덕션 전 스모크

## 실전 검증 로드맵
- **1단계 (지금 가능)**: 실제 .ts/.tsx 파일을 ZTS로 변환, esbuild/SWC 출력과 비교
- **2단계 (Arena 후)**: `hyperfine`으로 대형 파일 벤치마크 (ZTS vs esbuild vs SWC)
- **3단계 (N-API 후)**: `vite-plugin-zts`로 실제 React/Vue 프로젝트 개발 서버
- ✅ **4단계 (번들러 MVP)**: 실제 프로젝트 빌드 스모크 테스트 — 111/111 통과, CI 통합 완료

## 성능 저하 위험 포인트
| 기능 | 위험도 | 원인 | 대응 |
|------|--------|------|------|
| 모듈 해석 | **높음** | 파일시스템 I/O 폭발 (node_modules 탐색) | 해석 결과 캐시, 병렬 I/O |
| Tree-shaking (깊은) | **높음** | 전체 AST 재순회 | 1단계는 export 추적만, 점진적 |
| Code splitting | **높음** | 청크 분할이 NP-hard에 근접 | esbuild처럼 단순 자동 분리 먼저 |
| 스코프 호이스팅 | 중간 | 변수 충돌 해결에 심볼 테이블 필요 | semantic analyzer 재활용 |
| 모듈 그래프 | 중간 | 파싱 대기 | 파싱과 동시 구축 (esbuild 방식) |

## 멀티스레드 모델
- **파일 파싱**: 파일별 독립 Arena → lock-free 병렬 파싱
- **모듈 그래프**: 싱글 스레드 (의존성 순서가 중요)
- **변환/코드젠**: 파일별 병렬
- Zig의 `std.Thread.Pool` + 파일별 Arena 독립으로 Rust 대비 lock contention 최소화 가능

## 파일 변경 감지 전략
- **현재**: OS 파일시스템 이벤트 (macOS kqueue, Linux inotify, Windows ReadDirectoryChangesW) — 구현 완료
- **추가 예정**:
  - 폴링 폴백: Docker 볼륨/NFS 등 OS 이벤트가 불안정한 환경 대응 (mtime 비교)
  - LSP 연동: 에디터 didSave/didChange 이벤트로 파일 저장 전에도 감지 가능
  - io_uring (Linux): inotify보다 시스템콜 오버헤드 적은 비동기 I/O (성능 최적화 시점)
- **증분 재빌드**: 파일 변경 → 모듈 그래프에서 영향받는 모듈만 재빌드 → HMR 전송

## React Native 지원 (Rolldown 방식 — Metro 레거시 불필요)
- **방향**: 표준 ESM 번들러(Rolldown 계열) 위에 RN 특화 기능을 플러그인/코어 옵션으로 얹는 접근. Metro의 런타임 규약을 그대로 들고 가지 않음.
- **불필요한 Metro 레거시** (구현하지 않음):
  - `__d` 래핑 — 표준 스코프 호이스팅으로 대체
  - Haste 모듈 시스템 — Node.js 표준 해석으로 대체
  - 의존성 맵 (숫자 ID) — 표준 import로 대체
  - RAM 번들 — code splitting으로 대체
- **필요한 RN 특화 기능**:
  - ~~`platformResolverPlugin`~~ — ✅ 코어 옵션으로 구현 (`--resolve-extensions`, `--main-fields`)
  - ~~`flowStripPlugin`~~ — ✅ ZTS 코어에서 직접 구현 (`--flow`, flow.zig)
  - `preludePlugin` — polyfill/InitializeCore 주입 (플러그인으로)
  - `assetPlugin` — 이미지 등 에셋 처리 (플러그인으로)
  - ~~`hermesCompatPlugin`~~ — ✅ `--target=es5`로 대응
  - ~~`react-refresh`~~ — ✅ ZTS dev server에 내장
  - ~~글로벌 주입~~ — ✅ `--define:__DEV__=true` 등
- **핵심 설정**: `strictExecutionOrder: true` (ESM 실행 순서 보장)
- **Hermes 바이트코드**: `.hbc` 출력 — Hermes 컴파일러와 C ABI 연동

## 외부 통합 (플러그인/라이브러리)
```
Zig 코어 (parser + transformer + codegen)
    │
    ├─ CLI (직접 사용) — ✅ 이미 구현
    ├─ C ABI (.so/.dylib) — Zig export fn으로 노출
    │   └─ N-API 네이티브 모듈 (npm 패키지, 최고 속도)
    │       ├─ vite-plugin-zts    (esbuild 자리 대체)
    │       ├─ zts-loader         (swc-loader 자리 대체)
    │       └─ rollup-plugin-zts
    └─ WASM (.wasm) — ✅ 빌드 이미 가능
        └─ @zts/wasm (npm 패키지)
            ├─ 브라우저 playground / 온라인 REPL
            └─ Deno/Bun/Cloudflare Workers 호환
```
- **도입 시점**: Phase 6 초반에 C ABI 노출 → N-API 바인딩 → npm 패키지 → 플러그인 래퍼
- **핵심**: N-API 바인딩 하나만 만들면 Vite/Webpack/Rollup 플러그인은 JS 래퍼 수십 줄
- esbuild, SWC가 동일한 구조로 생태계 확장에 성공한 검증된 패턴

## WASM 빌드 사이즈 (#1885 / #1899)

WASM 모듈은 **transpile-only** 와 **bundler** 두 binary 로 분리해서 빌드한다 — bundler 는 graph/resolver/linker + wasi-libc (thread support) 가 포함되어 ~1.7배 크기.
playground 가 trans pile-only 모드에선 작은 binary 만 다운로드, bundler 모드 진입 시 lazy 로드 (`initBundler()`) — 두 함수가 별도 entry point 라 자연 lazy.

`zig build wasm wasm-bundler` (둘 다 `.optimize = .ReleaseSmall`) 후 `bun scripts/measure-wasm-size.ts` 로 측정한 사이즈:

| Target | Role | Raw | Gzip (-9) | Brotli (q=11) |
|---|---|---:|---:|---:|
| `zts.wasm` | transpile-only | 908.5 KiB | 321.0 KiB | 250.0 KiB |
| `zts-bundler.wasm` | bundler | 1.57 MiB | 512.6 KiB | 393.7 KiB |

- 분리 결정: 단일 binary (1.57 MiB) 면 transpile-only playground 도 풀 bundler 다운로드 강제 → 분리 우위. 후속 wasm-opt (binaryen) 적용 시 추가 10-30% 절감 가능 (별도 follow-up).
- `playground/bundler` 페이지에서만 `initBundler()` 호출 → bundler binary 가 lazy 로드.
- 회귀 추적: `bun scripts/measure-wasm-size.ts` 를 빌드 후 실행. CI 통합은 후속 PR.
