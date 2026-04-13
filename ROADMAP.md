# ZTS Roadmap

## Vision
Zig로 작성된 고성능 JS/TS 트랜스파일러. SWC/oxc 수준의 품질과 성능.

> **현재 상태의 단일 소스는 [docs/ROADMAP.md](./docs/ROADMAP.md)** — 이 파일은 Phase 1–5 초기 기획 문서로, 특정 체크박스는 완료 이후 갱신되지 않았을 수 있음. 기능 상태를 확인할 땐 docs/ROADMAP.md를 참고.

---

## Phase 1: Lexer (렉서) ✅ 완료
JS/TS 소스 코드를 토큰으로 분리.

### 구현 완료 (PR #1-#14)
- [x] 토큰 enum (~130개, u8, oxc 방식 세분화) — PR #1
- [x] Scanner 구조체 (next(), 공백/줄바꿈 스킵, BOM, 연산자 51종) — PR #3
- [x] 주석 (single-line, multi-line, hashbang, @__PURE__ 감지) — PR #4
- [x] 숫자 리터럴 (decimal, hex, octal, binary, bigint, float, exponential, separator 유효성) — PR #5, #13
- [x] 문자열 리터럴 (escape sequence, \xHH, \uHHHH, \u{}, 줄 연속, 에러 감지) — PR #6
- [x] 템플릿 리터럴 (head/middle/tail, ${} 중첩, brace depth 스택) — PR #7
- [x] 정규식 리터럴 (character class, escape, flags, prev_token 컨텍스트) — PR #8
- [x] 유니코드 식별자 (UTF-8 디코딩, ID_Start/ID_Continue, \u 이스케이프) — PR #9
- [x] JSX 모드 (JSXText, JSXIdentifier 하이픈, JSX 속성 문자열) — PR #10
- [x] JSX pragma 감지 (@jsx, @jsxFrag, @jsxRuntime, @jsxImportSource) — PR #11
- [x] Test262 러너 + CLI (--test262, --tokenize) — PR #12
- [x] 소스 위치 추적 (start+end byte offset, line offset 테이블, getLineColumn) — PR #3
- [x] 줄 끝 문자 전부 인식 (\n, \r\n, \r, U+2028, U+2029) — PR #3, #14
- [x] BOM 스킵 — PR #3
- [x] /simplify 리뷰 2회 (PR #1, #3 이후) + 전체 리뷰 1회 (PR #14)

### 후속 작업
- [x] SIMD 최적화 — `@Vector(16, u8)` 공백/식별자 스캔 적용 (추가 확장 여지)
- [x] import attributes 토큰 (`with`, `assert`) — 파서에서 키워드로 처리
- [x] 자동 세미콜론 삽입 (ASI) — 파서에서 구현 (렉서는 has_newline_before 제공)

### Test262 통과율 (렉서 단독, 2026-03-18 기준)
| Category | Pass Rate | 남은 실패 원인 |
|----------|-----------|---------------|
| numeric | 81.5% | strict mode (파서 필요) |
| line-terminators | 78.0% | 파서 수준 검증 |
| white-space | 70.1% | 일부 유니코드 공백 |
| comments | 69.2% | hashbang negative test |
| null | 66.7% | escaped keyword (파서) |
| string | 63.0% | strict mode legacy octal |
| bigint | 62.7% | strict mode |
| boolean | 50.0% | escaped keyword (파서) |
| regexp | 26.5% | 대부분 파서 수준 |

> 남은 실패 대부분은 파서가 있어야 판정 가능한 테스트. 파서 구현 후 통과율 대폭 상승 예상.

### Test262 러너 ✅ 완료
- [x] Test262 메타데이터 파서 (YAML frontmatter: negative, flags, features)
- [x] 테스트 실행기 (pass/fail/skip 판정)
- [x] 카테고리별 실행 (`--test262 test/language/literals/`)
- [x] 통과율 리포트 (총 N개 중 M개 통과, X% pass rate)
- [x] 실패 테스트 목록 출력 (디버깅용)
- [x] CI 연동 (test262.yml 워크플로우)

---

## Phase 2: Parser (파서) ✅ 완료
토큰 스트림을 AST로 변환. PR #16-#33.

### 구현 완료
- [x] AST 노드 타입 정의 (~200개 Tag, 24바이트 고정) — PR #17
- [x] 인덱스 기반 노드 참조 (NodeIndex u32, D004) — PR #17
- [x] 재귀 하강 파서 + Precedence climbing — PR #18
- [x] 에러 복구 (다중 에러 수집, D039) — PR #18
- [x] 모든 JS statement (if, for, for-in/of, while, do-while, switch, try/catch, break, continue, return, throw, debugger) — PR #21-#22
- [x] 함수 (선언, 표현식, arrow, async, generator) — PR #23, #27
- [x] 클래스 (extends, implements, static, #private, decorator, generics) — PR #24, #28, #32
- [x] 구조분해 (array, object, nested, rest, default) — PR #25
- [x] import/export (ESM 전체 + dynamic import + import.meta) — PR #26, #29
- [x] TS 타입 (keyword, union, intersection, array, tuple, object literal, reference, generic, typeof, keyof, as, satisfies, non-null, indexed access) — PR #30
- [x] TS 선언 (interface, type alias, enum, namespace, declare, abstract) — PR #31
- [x] TS 변환 대상 (parameter property, decorator, implements) — PR #32
- [x] JSX (element, fragment, attributes, expression, text) — PR #33
- [x] spread/rest 연산자 — PR #23

### Test262 파서 통과율 (2026-03-19 기준)
| Category | Tests | Pass Rate |
|----------|-------|-----------|
| destructuring | - | **100%** |
| computed-property-names | - | **100%** |
| function-code | - | **100%** |
| import | 135 | **92.6%** |
| statements | - | **81.6%** |
| numeric | 157 | **81.5%** |
| expressions | - | **80.0%** |
| line-terminators | 41 | **78.0%** |
| module-code | 698 | **76.2%** |
| white-space | 67 | 70.1% |
| comments | 52 | 69.2% |
| null | 3 | 66.7% |
| asi | - | 65.7% |
| string | 73 | 63.0% |
| bigint | 59 | 62.7% |
| boolean | 4 | 50.0% |
| identifiers | 260 | 33.1% |
| block-scope | - | 29.7% |
| regexp | 238 | 26.5% |
| keywords | 25 | 0% |

> 3개 카테고리 100%, 5개 카테고리 80%+. keywords/identifiers 실패는 대부분 negative test (에러가 나야 통과) — semantic analysis 필요.

### 후속 작업
- [x] semantic analysis (스코프/심볼, 별도 패스, D038)
- [x] 에러 복구 강화 (negative test 통과율 개선 — Test262 100% 통과)
- [x] TS 타입 시스템 고급 기능 (BACKLOG #47-#58)

### ECMAScript 구문 (ES2024)
- [x] 리터럴 (string, number, boolean, null, undefined, regex, template)
- [x] 표현식 (binary, unary, ternary, assignment, comma, spread)
- [x] 화살표 함수
- [x] 구조분해 할당 (array, object, nested)
- [x] 클래스 (필드, 메서드, static, private `#`, computed property)
- [x] for...of, for...in, for await...of
- [x] async/await
- [x] generator (function*, yield)
- [x] import/export (ESM)
- [x] dynamic import (`import()`)
- [x] optional chaining (`?.`)
- [x] nullish coalescing (`??`)
- [x] logical assignment (`&&=`, `||=`, `??=`)
- [x] top-level await
- [x] class static block (`static { }`)
- [x] import attributes (`with { type: "json" }`)
- [x] using / await using (Explicit Resource Management)

### TypeScript 구문 (삭제 대상)
- [x] 타입 어노테이션 (변수, 파라미터, 리턴, 클래스 필드)
- [x] 제네릭 (파라미터, 제약, 기본값, const, in/out variance)
- [x] 타입 인자 (호출, new, tagged template, JSX)
- [x] type alias
- [x] interface (+ extends, call/construct/method/property/index signature)
- [x] as / as const / satisfies
- [x] non-null assertion (`!`)
- [x] angle bracket assertion (`<Type>expr`)
- [x] 인스턴스화 표현식 (`fn<string>` 호출 없이, TS 4.7)
- [x] import type / export type
- [x] inline type specifier (`import { type Foo }`, TS 4.5)
- [x] export type * / export type * as ns (TS 5.0)
- [x] declare (변수, 함수, 클래스, enum, module, global, 클래스 필드)
- [x] abstract (클래스, 메서드, 프로퍼티, accessor)
- [x] 접근 제어자 (public, private, protected)
- [x] readonly
- [x] override
- [x] implements
- [x] 함수 오버로드 시그니처
- [x] this 파라미터
- [x] definite assignment assertion (변수 `let x!`, 클래스 필드 `x!:`)
- [x] 옵셔널 클래스 프로퍼티 (`x?: number`)
- [x] 타입 가드 (x is string, asserts x is string)
- [x] .d.ts 파일 전체 무시
- [x] 트리플 슬래시 디렉티브
- [x] TSX 제네릭 화살표 함수 모호성 (`<T,>() => {}`)

### TypeScript 구문 (변환 대상)
- [x] enum → IIFE
- [x] const enum → 인라이닝 또는 IIFE (isolatedModules 시 IIFE 폴백)
- [x] namespace (단일) → IIFE
- [x] namespace (병합) → 다중 IIFE
- [x] namespace (중첩) → 중첩 IIFE
- [x] namespace + class/function/enum 선언 병합
- [x] 파라미터 프로퍼티 → this.x = x 생성
- [x] export = → module.exports =
- [x] import x = require("...") → const x = require("...")
- [x] import x = Namespace.Value → const x = Namespace.Value
- [x] legacy decorator (클래스, 메서드, 프로퍼티, 파라미터)
- [x] emitDecoratorMetadata → Reflect.metadata 호출 생성
- [x] accessor 키워드 (Stage 3 decorator용 backing field + getter/setter 자동 생성)
- [x] Stage 3 decorator (method/getter/setter/field/accessor/class, MobX 6 호환)
- [x] static block (ES2022, 클래스 정의 시점 1회 실행)

### JSX
- [x] JSX element → React.createElement / jsxs 호출
- [x] JSX fragment
- [x] JSX spread attributes
- [x] JSX namespace (`<xml:svg>`)
- [x] 자동 import (React 17+ jsx transform, `jsxDEV` 포함)

### 에러 처리
- [x] 에러 복구 (sync token까지 스킵 후 계속 파싱)
- [x] 에러 메시지 품질 (위치, 기대값, 실제값, `rich_diagnostic` 렌더링)
- [x] 다중 에러 수집

### 검증
- [x] Test262 language/ 테스트 통과율 추적 (50,504건 100% 통과)

---

## Phase 3: Transformer (트랜스포머) ✅ 완료
AST를 변환하여 JS로 출력 가능한 형태로 만듦.

### 목표
- [x] 타입 스트리핑 (삭제 대상 노드 제거)
- [x] enum 변환
- [x] const enum 인라이닝 (isolatedModules 폴백 포함)
- [x] namespace 변환 (단일, 병합, 중첩, 선언 병합)
- [x] 파라미터 프로퍼티 변환
- [x] export = / import = 변환
- [x] legacy decorator 변환
- [x] emitDecoratorMetadata (Reflect.metadata)
- [x] accessor 변환 (Stage 3 decorator backing)
- [x] Stage 3 decorator (method/getter/setter/field/accessor/class)
- [x] static block
- [x] JSX 변환 (Classic + Automatic + jsxDEV)
- [x] define (전역 치환: `process.env.NODE_ENV` → `"production"` 등)
- [x] import.meta CJS 변환
- [x] ESM → CJS 모듈 변환 (import→require, export→module.exports)
- [x] direct eval 감지 → 해당 스코프 최적화 비활성화
- [x] 헬퍼 함수 전략 (인라인 기본, 외부 tslib 옵션)
- [x] `--drop` console/debugger/labels 제거 (D032)
- [x] Flow 타입 스트리핑 (flow.zig 독립 파싱, Metro 410/410 통과) (D024)

---

## Phase 4: Code Generator (코드젠) ✅ 완료
변환된 AST를 JavaScript 문자열로 출력.

### 목표
- [x] AST → JS 문자열 출력
- [x] 소스맵 생성 (v3, inline + external + hidden)
- [x] 출력 포맷 옵션 (minify — AST 미니파이어)
- [x] 줄바꿈, 들여쓰기 보존
- [x] Legal 코멘트 처리 (`@license`, `@preserve` — none/inline/eof/external)
- [x] `"use strict"` 삽입 (CJS + alwaysStrict)
- [x] `--ascii-only` 출력 (non-ASCII → `\uXXXX` 이스케이프) (D031)

---

## Phase 5: CLI & Integration ✅ 완료
사용자가 실제로 쓸 수 있는 도구로 만듦.

### 목표
- [x] CLI 인터페이스 (`zts src/index.ts`) — Node.js/Bun CLI로 전환 (Rolldown 방식)
- [x] 설정 파일 지원 (tsconfig.json 전체 파싱, extends 상속)
- [x] 파일 단위 병렬 파싱 (scan 파이프라인 + Producer-Consumer)
- [x] 디렉토리 재귀 처리 (`--outdir` 미러링)
- [x] watch 모드 (kqueue/inotify 이벤트 기반 + content hash + 증분 빌드)
- [x] stdin/stdout 모드 (에디터 연동)
- [x] `--platform` 옵션 (browser/node/neutral/react-native)
- [x] `--format` 옵션 (esm/cjs/iife)
- [ ] .d.ts 생성 (isolatedDeclarations, TS 5.5+) — 후순위, tsc에 위임
- [x] React Fast Refresh ($RefreshReg$, $RefreshSig$) (D029)
- [x] WASM 빌드 타겟 (`zig build wasm`)

---

## Phase 6: Advanced
스펙 안정화 및 리소스 확보 후 진행.

### 완료
- [x] Stage 3 (TC39) decorator (method/getter/setter/field/accessor/class, MobX 6 호환)
- [x] ES 다운레벨링 (es2015~es2024 + esnext, 엔진 타겟 feature-level 다운레벨링)
- [x] 미니파이어 (constant folding, DCE, boolean simplification, comma operator)
- [x] 번들러 (resolver, 모듈 그래프, linker, tree-shaking, code splitting, CSS)
- [x] `--keep-names` (함수/클래스 이름 보존) (D033)

### 미완료
- [ ] loose 모드 (비표준이지만 빠른 다운레벨링)
- [ ] WASM 플러그인 시스템
- [ ] WASM 공개 AST API — AST 안정화 후
- [ ] Compiler Assumptions (pure_getters, set_public_class_fields 등) (D028)
- [ ] 미니파이 세분화 (whitespace / syntax / identifiers) (D030)
- [ ] import defer (TS 5.9)
- [ ] 증분 파싱 (에디터 LSP 연동) — 번들러 수준 증분 빌드만 존재

---

## Design Decisions Log

### 2026-03-18: Stage 3 Decorator 후순위
- **결정**: Stage 3 decorator는 스펙 안정화 후 구현
- **이유**: TC39 스펙이 Stage 3 도달 후에도 4회 이상 수정됨. oxc도 같은 이유로 구현 중단. SWC는 구현했으나 2년간 버그 수정 지속 중
- **대안**: Legacy decorator 우선 구현
- **후속(현재)**: Legacy + Stage 3 decorator 모두 구현 완료 (MobX 6 호환). static block / accessor 키워드 포함.

### 2026-03-18: 타입 체크 미지원
- **결정**: 타입 체크를 하지 않음. 타입 스트리핑만
- **이유**: SWC, oxc, Bun, esbuild 모두 같은 전략. 타입 체크는 tsc에 위임
- **범위**: 구문(syntax) 파싱 + 스트리핑/변환만

### 2026-03-18: 메모리 설계
- **결정**: 인덱스 기반 AST + phase-based arena allocator
- **이유**: Bun의 포인터 기반 AST가 segfault 원인 (4800+ 오픈 이슈). 인덱스 기반으로 use-after-free 원천 차단
- **참고**: Bun 24바이트 고정 노드, oxc의 arena 패턴

### 2026-03-18: comptime 파서 특수화
- **결정**: JS/JSX/TS/TSX 파서를 comptime으로 각각 생성
- **이유**: Bun과 동일 전략. 런타임 분기 0개로 성능 극대화

### 2026-03-18: SIMD Lexer
- **결정**: Zig @Vector로 SIMD 렉서 구현
- **이유**: oxc가 안 하고 있는 영역. Bun은 Highway로 사용 중. 차별화 포인트
