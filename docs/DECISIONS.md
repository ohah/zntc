# ZTS Decision Records

프로젝트 진행 중 내려야 할 의사결정 목록과 현재 상태.

---

## 결정 완료

### D001: 프로그래밍 언어
- **결정**: Zig
- **이유**: 학습 목적 + arena allocator가 언어 네이티브, SIMD @Vector 빌트인, 빠른 컴파일, C ABI 호환, 작은 WASM 출력

### D002: 타입 체크
- **결정**: 안 함
- **이유**: SWC/oxc/Bun/esbuild 전부 동일 전략. tsc에 위임

### D003: Stage 3 Decorator
- **결정**: 후순위 (스펙 안정화 후)
- **이유**: oxc와 같은 전략. 스펙 불안정 + 유지보수 부담

### D004: AST 메모리 설계
- **결정**: 인덱스 기반 + arena allocator
- **이유**: 안정성 (use-after-free 방지) + 성능 (캐시 효율)

### D005: TypeScript 버전 지원 범위
- **결정**: TS 5.8 (최신 stable) 전체 지원, 새 버전 나오면 점진적 추가
- **이유**: TS 구문은 누적(상위 호환). 5.8 파서를 만들면 4.x도 자동 파싱. 버전별 차이는 트랜스포머 분기로 처리

### D006: ESM / CJS 출력 형식
- **결정**: ESM + CJS 둘 다 지원. UMD는 Phase 6 (번들러)에서 추가
- **이유**: SWC/oxc 둘 다 지원. UMD는 사용 빈도가 낮아 후순위

### D007: ES 다운레벨링 타겟 범위
- **결정**: 처음엔 안 함 (TS 변환만). Phase 6에서 ES2024→ES2016 순으로 점진적 하향 추가. ES2015는 그 이후. ES5는 미정
- **이유**: oxc와 같은 전략. 최신 변환이 단순하므로 위에서 아래로 내려감. ES2015 변환(클래스, 구조분해 등)은 난이도가 급상승하므로 후순위
- **참고**: oxc는 ES2016 이상 완성, ES2015는 화살표 함수만 지원. SWC는 ES5까지 전부 지원

### D008: JSX Transform 방식
- **결정**: Classic + Automatic 둘 다 지원
- **이유**: 파서에는 영향 없음. JSX 구문 파싱은 동일하고 트랜스포머에서 설정으로 분기. SWC/oxc 둘 다 전부 지원

### D009: 소스맵
- **결정**: inline + external + hidden 전부 지원
- **이유**: 소스맵 코어를 한 번 만들면 출력 방식은 플래그 차이일 뿐. 프로덕션 도구라면 전부 필요
  - inline: JS 파일 끝에 base64로 삽입 (개발용)
  - external: 별도 .map 파일 생성 (프로덕션 표준)
  - hidden: .map 생성하지만 JS에 URL 주석 안 넣음 (Sentry 등 별도 업로드용)

### D010: tsconfig.json 지원 범위
- **결정**: 모든 옵션을 파싱하되, Phase별로 사용 범위를 구분
- **이유**: 추후 번들러 확장 시 tsconfig 파서를 다시 만들지 않도록 미리 전부 파싱

| 옵션 | 트랜스파일러 (Phase 3-5) | 번들러 (Phase 6) |
|------|------------------------|-----------------|
| target | O | O |
| module | O | O |
| jsx / jsxFactory / jsxFragmentFactory / jsxImportSource | O | O |
| experimentalDecorators / emitDecoratorMetadata | O | O |
| useDefineForClassFields | O | O |
| verbatimModuleSyntax | O | O |
| alwaysStrict | O (CJS 출력 시 "use strict" 삽입) | O |
| extends | O (tsconfig 상속) | O |
| isolatedModules | 읽되 false면 경고 출력 (항상 true 동작) | 번들러에서 false 지원 가능 |
| paths / baseUrl | 파싱만, 사용 안 함 | **활성화** |
| moduleResolution | 파싱만, 사용 안 함 | **활성화** |
| strict (하위 옵션들) | 무시 (타입 체크 전용, 출력 JS에 영향 없음) | 무시 |

### D011: isolatedModules 모드
- **결정**: 항상 isolatedModules 모드 (파일 단위 독립 처리)
- **이유**: SWC/oxc/esbuild/Bun 전부 이 방식. 크로스 파일 분석은 번들러 영역. const enum은 같은 파일 내에서만 인라이닝, 크로스 파일은 일반 enum으로 폴백

### D012: 에러 출력 형식
- **결정**: 코드 프레임(기본) + JSON (`--format json`)
- **이유**: CLI 도구의 첫인상이 에러 메시지에서 결정됨. 코드 프레임은 사람이 읽기 좋고, JSON은 에디터/CI 연동용. 렉서부터 line/column 추적 필수

### D013: Plugin / 확장 시스템
- **결정**: WASM 플러그인 (Phase 6)
- **이유**: 초기에는 코어에 집중. WASM 플러그인은 언어 무관 + 샌드박싱 가능. SWC도 WASM 플러그인 방식

### D014: 공개 AST API 제공 여부
- **결정**: WASM으로 공개 (Phase 6)
- **이유**: 브라우저 플레이그라운드, JS에서 AST 직접 조작 가능. Bun이 안 하는 것을 해서 차별화. linter/formatter/codemod가 zts 위에 올라올 수 있는 생태계 기반

### D015: 소스 위치 저장 방식
- **결정**: start + end byte offset (8바이트, oxc 방식). line/column은 별도 line offset 테이블에서 lazy 계산
- **이유**: 코드 프레임 에러 출력(D012)에서 밑줄(`^^^^`) 표시에 end가 필요. esbuild/Bun은 start만(4바이트)이지만 에러 범위 표시가 제한적. oxc/SWC도 start+end 방식
- **참고**: line/column은 AST 노드에 저장하지 않음 (4개 도구 모두 동일). 에러 출력이나 소스맵 생성 시 line offset 테이블에서 계산

### D016: 헬퍼 함수 전략
- **결정**: 인라인 + 외부(tslib) 둘 다 지원
- **이유**: 인라인은 의존성 없이 동작, 외부는 출력 크기 절약. SWC도 둘 다 지원 (`externalHelpers` 옵션)
  - 기본: 인라인 (파일마다 필요한 헬퍼를 삽입)
  - 옵션: 외부 (`import { __awaiter } from "tslib"`)

### D017: .d.ts 생성 (isolatedDeclarations)
- **결정**: 지원 (Phase 5)
- **이유**: TS 5.5의 isolatedDeclarations로 타입 체크 없이 .d.ts 생성 가능. oxc만 지원하고 SWC/esbuild는 미지원 → 큰 차별화 포인트. 파서가 타입 어노테이션을 AST에 보존해야 하므로 파서 설계에 영향

### D018: loose 모드
- **결정**: Phase 6에서 추가
- **이유**: 스펙 준수가 우선. loose 모드는 비표준이지만 빠른 출력이 필요한 프로젝트를 위해 추후 제공. Babel/SWC는 지원, esbuild는 미지원

### D019: 렉서 추가 기능
- **결정**: 아래 항목 전부 지원
  - **Hashbang (`#!`)**: 첫 줄의 `#!/usr/bin/env node`를 주석으로 인식 + 출력에 보존
  - **BOM 처리**: UTF-8 BOM(0xEF 0xBB 0xBF)을 파일 시작에서 스킵, 출력에는 넣지 않음
  - **줄 끝 문자**: `\n`, `\r\n`, `\r`, U+2028, U+2029 전부 줄바꿈으로 인식
  - **유니코드 식별자**: `\uXXXX`, `\u{XXXX}` 이스케이프 시퀀스 지원 + 정규화
  - **import attributes**: `with { type: "json" }` + deprecated `assert { type: "json" }` 둘 다 파싱
  - **direct eval 감지**: `eval()` 직접 호출 감지 → 해당 스코프 변수 최적화 비활성화

### D020: define (전역 치환)
- **결정**: 지원 (Phase 3)
- **이유**: `process.env.NODE_ENV` → `"production"` 등 거의 모든 프로젝트에서 필요. esbuild의 킬러 피처

### D021: import.meta CJS 변환
- **결정**: 지원 (Phase 3)
- **이유**: ESM→CJS 변환 시 `import.meta.url` → `require('url').pathToFileURL(__filename).href` 등 변환 필요. esbuild 방식 참고

### D022: Legal 코멘트 처리
- **결정**: 지원 (Phase 4)
- **이유**: `@license`, `@preserve` 주석 처리. esbuild의 `--legal-comments` 옵션 참고 (none/inline/eof/external)

### D023: --platform 옵션
- **결정**: browser / node / neutral 3가지 (Phase 5)
- **이유**: `import.meta`, `__dirname`, `require` 등의 변환 동작이 플랫폼에 따라 다름. esbuild와 동일

### D024: Flow 타입 시스템 지원
- **결정**: 지원 (Hermes C++ 파서를 Zig에서 C ABI로 링크)
- **이유**: React Native 프로젝트에서 Flow를 사용. 자체 구현 대신 Hermes 파서 임베딩으로 작업량 최소화
- **방식**: Hermes C++ 파서를 static library로 빌드 → Zig에서 @cImport로 호출 → ESTree AST 반환 → zts가 변환/코드젠
- **참고**: hermes-parser(npm)는 이미 WASM 빌드 존재. SWC는 자체 Flow 스트리핑 구현, oxc는 미지원

### D025: `@__PURE__` / `@__NO_SIDE_EFFECTS__` 주석 추적
- **결정**: 렉서에서 지원
- **이유**: 트리쉐이킹의 핵심. esbuild/Bun/oxc 전부 렉서에서 이 주석을 토큰에 달아줌. 함수 호출이 부작용 없음을 표시하는 사실상 표준

### D026: JSX pragma 주석 감지
- **결정**: 렉서에서 지원
- **이유**: `/** @jsx h */`, `/** @jsxRuntime automatic */` 등 파일 상단 주석에서 JSX 설정 오버라이드. esbuild/Bun/SWC 전부 지원. 렉서가 파일 시작 주석에서 추출

### D027: AMD / SystemJS 모듈 출력
- **결정**: 미지원
- **이유**: 거의 사장된 형식. SWC만 지원하고 esbuild/oxc/Bun은 미지원

### D028: Compiler Assumptions (Babel 호환)
- **결정**: Phase 6에서 점진적 추가
- **이유**: pure_getters, set_public_class_fields 등 20개+ 가정. 다운레벨링할 때만 의미 있으므로 ES 다운레벨링과 함께 추가. oxc 6개, SWC 20개+ 지원

### D029: React Fast Refresh
- **결정**: Phase 5에서 지원
- **이유**: HMR 필수. $RefreshReg$, $RefreshSig$ 헬퍼 삽입. Bun/SWC/oxc 전부 지원. 개발 서버(Vite, Next.js, Metro) 연동에 필요

### D030: 미니파이 세분화
- **결정**: Phase 6, 3가지 개별 제어 (whitespace / syntax / identifiers)
- **이유**: esbuild/Bun 방식. 디버깅용 공백만 제거, 프로덕션용 전부 등 유스케이스별 조합 가능

### D031: `--ascii-only` (ASCII 전용 출력)
- **결정**: Phase 4 코드젠에서 지원
- **이유**: non-ASCII를 `\uXXXX`로 이스케이프. 레거시 환경/빌드 파이프라인 호환. esbuild/SWC 지원

### D032: `--drop` (코드 제거)
- **결정**: Phase 3에서 지원 (console, debugger, labels)
- **이유**: 프로덕션 빌드 필수. `--drop=console`, `--drop=debugger`, `--drop-labels=DEV`. esbuild 방식 참고

### D033: `--keep-names` (함수/클래스 이름 보존)
- **결정**: Phase 6 미니파이어와 함께
- **이유**: 미니파이 시 Function.name 보존. React DevTools, 에러 스택트레이스에 필요. Object.defineProperty로 원래 이름 복원

---

### D034: 토큰 enum 설계
- **결정**: oxc 방식 — 세분화 `#[repr(u8)]` 플랫 enum (~208개)
- **이유**: TS 키워드를 개별 토큰으로 (파서에서 문자열 비교 불필요), 숫자를 11가지로 세분화 (Decimal/Float/Hex/Octal/Binary/BigInt 등), JSXText 전용 토큰. linter/AST API(D014) 확장 시 풍부한 토큰 정보가 유리. 208개도 u8에 들어가므로 성능 차이 없음
- **참고**: esbuild/Bun은 ~86-107개 (미니멀), SWC는 ~120개 (Token + TokenValue 분리)

### D035: 문자열 인코딩
- **결정**: UTF-8 기본, lazy UTF-16 변환 (Bun 방식)
- **이유**: 실제 JS 코드의 95%+가 ASCII라 변환 거의 안 일어남. UTF-8이면 소스를 슬라이스로 참조 가능 (복사 없음). 정확한 JS 문자열 시맨틱이 필요한 경우에만 UTF-16 변환

### D036: 렉서-파서 연동 방식
- **결정**: 파서가 렉서 호출 (esbuild/Bun 방식) + 옵션으로 토큰 저장 (oxc 방식)
- **이유**: 메모리 효율 (토큰 배열 없음), regex/JSX 컨텍스트 피드백이 자연스러움. 나중에 AST API(D014)/linter에서 토큰 저장 모드를 옵션으로 추가

---

## 전략적 의사결정 완료 (D001-D036)

---

## Phase별 미래 결정 사항 (구현 시작 시 논의)

### Phase 2 (파서) — 결정 완료

### D037: AST 노드 설계
- **결정**: 고정 24바이트 + 인덱스 참조 (Bun 방식)
- **이유**: 연속 메모리 배치 → 캐시 효율 최고. 작은 데이터는 인라인, 큰 데이터는 포인터로 arena에. 인덱스 참조로 use-after-free 원천 차단. Bun이 Zig로 검증. 나중에 C(16B 사이드 테이블)로 전환하기 어렵지만, 이미 최적에 가까움
- **참고**: oxc는 가변 크기(40-96B), esbuild는 Go GC

### D038: 스코프/심볼 테이블
- **결정**: 별도 패스 (파서와 분리, oxc 방식)
- **이유**: 파서는 AST만 생성, semantic analysis가 스코프/심볼을 구축. 관심사 분리로 유지보수/확장성 우수. linter/formatter/type checker가 semantic 모듈을 독립 재사용 가능. 속도 차이 30-50%이지만 oxc가 이 방식으로 SWC보다 3배 빠름 — 전체 아키텍처가 성능을 결정
- **참고**: Bun/esbuild는 파싱 중 구축 (A 방식)

### D039: 에러 복구 전략
- **결정**: 계속 파싱 (다중 에러 수집)
- **이유**: SWC/oxc/Bun/esbuild 전부 이 방식. 에러를 만나면 동기화 토큰(; } EOF)까지 스킵하고 계속 파싱. 한 번 실행에 여러 에러를 보여줘서 사용자 경험 좋음

### D040: 파서 패스 수
- **결정**: 2패스 (parse → visit, Bun 방식)
- **이유**: 각 패스가 한 가지 일만 해서 유지보수 쉬움. 새 변환 추가 시 visit에만 추가하면 됨. 속도 차이 20-30%이지만 Bun이 2패스로도 esbuild보다 빠름. 나중에 성능이 필요하면 패스 합치기 가능 (반대 방향은 재작성)

### Phase 3 (트랜스포머) — 결정 완료

### D041: Transformer 전략
- **결정**: 새 AST 생성 + 별도 Codegen (oxc/SWC 방식)
- **이유**: Phase 6에서 .d.ts 생성, 미니파이어, 번들러가 변환된 AST를 재사용해야 함. 24B 고정 노드 + ArrayList 구조에서 in-place 변환(노드 수 증가)은 매우 어려움. arena allocator로 원본 AST를 변환 후 한 번에 해제하면 메모리 2배 문제 완화
- **비교**: esbuild는 변환+출력 합침(빠르지만 확장 어려움), in-place 수정은 노드 증가 변환에 부적합
- **참고**: oxc(Visit+Traverse 분리), SWC(Fold+VisitMut) 모두 이 방식

### D042: Visitor 패턴
- **결정**: Switch 기반 + comptime 보조 (esbuild/Bun 방식)
- **이유**: 큰 switch문이 가장 단순하고 유지보수 쉬움. 새 변환 = case 추가. 점프 테이블 성능은 comptime 인라인과 실측 차이 미미 (노드당 3-5사이클, 초대형 파일에서 ~0.4ms). oxc를 이기는 핵심은 visitor 패턴이 아니라 메모리 레이아웃과 할당 최적화. comptime은 타입 삭제 대상 그룹 판별 등 반복적인 부분에만 보조 사용
- **비교**: comptime visitor(A)는 ~190개 인라인 함수로 icache 압박 위험. enter/exit 콜백(C)은 Zig에서 함수 포인터 간접 호출 오버헤드 + 과설계
- **참고**: esbuild(순수 switch), Bun(switch+comptime), oxc(trait visitor 코드생성), SWC(trait Fold/VisitMut)

### D043: 변환 순서 및 패스 전략
- **결정**: 단일 패스, 변환 우선순위로 순서 제어
- **이유**: 대부분의 변환이 독립적 (타입 스트리핑, JSX, 모듈). 의존성이 있는 경우(decorator→class) switch 내에서 순서 제어. 멀티 패스는 AST를 여러 번 순회하므로 성능 손해
- **변환 우선순위**: (1) 타입 스트리핑 (2) TS expression (as/satisfies/!) (3) enum→IIFE (4) namespace→IIFE (5) parameter property (6) JSX (7) ESM→CJS (8) decorator

### Phase 4 (코드젠) — 결정 완료

### D044: 들여쓰기 방식
- **결정**: Tab 기본 + Space 옵션 (oxc 방식)
- **이유**: Tab이 바이트 효율적 (1바이트 vs 2-4바이트). IndentChar enum으로 Tab/Space 선택 + indent_width로 Space일 때 너비 설정. minify 모드에서는 들여쓰기 완전 제거
- **비교**: esbuild(2 spaces 고정), SWC(4 spaces 고정, 변경 어려움), oxc(Tab/Space enum + width)
- **참고**: oxc가 가장 유연하고, 추후 Prettier 연동 시 Space 2/4 전환이 자연스러움

### D045: 줄바꿈 처리
- **결정**: `\n` 정규화 + CRLF 옵션 (SWC 방식)
- **이유**: 내부적으로 `\n`으로 통일하고, 출력 시 설정에 따라 `\n` 또는 `\r\n`으로 변환. 크로스 플랫폼(Windows/Unix) 지원. 원본 줄바꿈 보존은 소스맵으로 매핑하므로 불필요
- **비교**: esbuild(`\n` 정규화), oxc(원본 구조 유지), SWC(설정 가능)

### D046: 소스맵 V3 VLQ 인코딩
- **결정**: 자체 구현 (esbuild/SWC 방식, ~30줄)
- **이유**: VLQ는 표준 알고리즘(sign bit → 5bit chunks → continuation bit → base64). esbuild/oxc/SWC 모두 자체 구현. 외부 의존성 불필요. Zig로 포팅 간단
- **구현 세부**: sign bit은 bit 0, 값은 5bit씩 분할, continuation bit은 bit 5, base64 인코딩
- **참고**: oxc도 `oxc_sourcemap` 크레이트를 자체 개발 (외부 의존 아님)

### Phase 5 (CLI) — 결정 완료

### D047: 설정 파일
- **결정**: tsconfig.json만 지원 (별도 zts.config.json 없음)
- **이유**: 기존 TS 프로젝트와 호환성. tsconfig.json은 이미 표준. esbuild/oxc/SWC 모두 tsconfig.json 사용. 별도 설정 파일은 사용자 혼란만 야기
- **참고**: tsconfig.json의 extends, compilerOptions만 파싱. paths/baseUrl은 Phase 6(번들러)에서 활성화 (D010)

### D048: watch 구현 방식
- **결정**: polling 기본 + 플랫폼 네이티브 옵션 (추후)
- **이유**: Zig 표준 라이브러리에 fsevents/inotify 바인딩 없음. polling이 가장 이식성 높음. 성능이 필요하면 추후 플랫폼별 네이티브 추가. esbuild도 polling 폴백 있음

### D049: 출력 디렉토리 전략
- **결정**: rootDir/outDir 미러링 (tsc 방식)
- **이유**: rootDir 기준으로 소스 디렉토리 구조를 outDir에 복제. src/a/b.ts → dist/a/b.js. tsc/SWC와 동일한 동작. rootDir 미지정 시 모든 소스의 공통 조상 디렉토리를 자동 계산

### D050: stdin/stdout 프로토콜
- **결정**: 단순 파이프 (stdin → stdout, 추후 JSON-RPC)
- **이유**: `cat input.ts | zts > output.js` 형태의 파이프 지원이 1순위. JSON-RPC는 에디터 통합 시 추가. esbuild도 단순 stdin/stdout 먼저, serve API 나중에 추가

### Semantic Analysis — 결정 완료

### D051: 파서 vs Semantic 패스 경계
- **결정**: 파서에 풍부한 컨텍스트 추적 (strict mode + async/generator/loop/switch), Semantic 패스에 스코프/심볼
- **이유**: 파서가 이미 아는 구문 컨텍스트(loop/function/switch)를 버리지 않음. break/continue/return 검증은 파서가 자연스럽게 처리. Semantic 패스는 "이름 해결" 관련(스코프/심볼/재선언/예약어)만 담당. oxc도 이 방식
- **파서 담당**: strict mode, async/generator/loop/switch 컨텍스트, break/continue/return 유효성
- **Semantic 담당**: 스코프 구축, 심볼 수집, 재선언 검증, 예약어 검증, 미선언 export 검증

### D052: 스코프 모델
- **결정**: 플랫 배열 + 부모 인덱스 (oxc 방식)
- **이유**: D004 인덱스 참조 원칙과 일관. 캐시 효율 좋음. use-after-free 없음. Phase 6(minifier/bundler)에서 스코프 정보 재사용 가능
- **비교**: 포인터 기반 트리(A)는 use-after-free 위험, 스택만(C)은 Phase 6 차단

### D053: 심볼 모델
- **결정**: 최소 심볼 (name + scope_id + kind + flags + declaration_span)
- **이유**: 재선언 검증에 필요한 최소 정보만. references(참조 추적)는 Phase 6(minifier/bundler)에서 추가
- **SymbolKind**: var/let/const/function/class/parameter/catch_binding/import_binding (8가지). 재선언 규칙이 kind별로 다르므로 세분화

### D054: Strict Mode 추적
- **결정**: 파서에서 추적 ("use strict" directive + module mode)
- **이유**: directive는 구문 수준이므로 파서가 자연스럽게 처리. with문, 8진수 리터럴 등 strict 위반을 즉시 에러로 보고 가능. 함수 경계에서 strict 상태 저장/복원

### D055: Test262 early phase 통합
- **결정**: parse + early 통합 (is_negative_parse 하나로 처리)
- **이유**: ECMAScript에서 early error는 실행 전 검출 대상. 트랜스파일러 관점에서 parse/early 구분 불필요. oxc/SWC도 같은 파이프라인에서 처리

---

## 번들러 의사결정 요약 (D056~D079)

| # | 토픽 | 결정 | 참고한 번들러 | 배제한 방식 (이유) |
|---|------|------|-------------|-------------------|
| **D056** | 개발 전략 | 품질 먼저 → 속도 추가 | Rollup→Rolldown | esbuild/Bun 속도 먼저 (정교한 분석 끼워넣기 어려움) |
| **D057** | 최우선 구현 | 모듈 그래프 | 전체 공통 | — |
| **D058** | ESM 실행 순서 | DFS 후위 + 슬롯 예약 | Rollup, Rolldown | — |
| **D059** | 스코프 호이스팅 | Rollup 알고리즘 + Zig 속도 | Rolldown | webpack 래핑 (런타임 오버헤드), esbuild 보수적 (번들 품질 희생) |
| **D060** | 플러그인 | Rollup 호환 JS + Zig 네이티브 + WASM | Rolldown | esbuild IPC (느림), SWC WASM only (진입장벽) |
| **D061** | Arena | 파일당 1개, Phase 분리 불필요 | Bun | — |
| **D062** | WASM AST | 바이너리 우선 + ESTree 나중 | — | oxc JSON 직렬화 (병목) |
| **D063** | Tree-shaking | 점진적 (export→@__PURE__→사이드이펙트) | esbuild, Rolldown | — |
| **D064** | Conditional exports | import kind별 resolver 인스턴스 | Rolldown/oxc_resolver | esbuild (`module` 자동 제거 함정), webpack (기본값 없음) |
| **D065** | 순환 참조 | DFS + 경고 + 배열 스캔 | Rollup (알고리즘), Bun (구현) | esbuild (감지 안 함), SWC petgraph (과도) |
| **D066** | 에러 핸들링 | suggestion + step enum | esbuild (suggestion), Bun (step) | Rollup (전체 빌드 중단), webpack (문자열 기반) |
| **D067** | 워크스페이스 | MVP 제외, 심링크 충분 | 전체 (심링크 의존) | Bun 자체 패키지 매니저 (범위 과다) |
| **D068** | CJS/ESM 헬퍼 | `__` 프리픽스, 6개 핵심 헬퍼 | esbuild, Rolldown | SWC 인라인 (중복), webpack 축약 (가독성 희생) |
| **D069** | External 옵션 | 문자열 + `*` 글롭 | esbuild | Rolldown 정규식 (Zig에 엔진 없음, CLI에서 불편) |
| **D070** | 모듈 ID | `ModuleIndex = enum(u32)` | esbuild, Bun, Rolldown, SWC | Rollup 문자열 (해시맵 필요, 비교 O(n)) |
| **D071** | 소스맵 체이닝 | AST 직접 매핑 + 플러그인 collapse | Rolldown (~60줄) | Rollup 트리 (메모리 증가), Vite (JS 의존성) |
| **D072** | 청크 해싱 | xxhash64 + 플레이스홀더 2단계 | Rolldown | xxhash128 (불필요), md4 (느림) |
| **D073** | 모듈 타입/에셋 | ModuleType enum + ParserAndGenerator | rspack | esbuild 로더 (확장 불가), Rollup 전부 플러그인 (DX 나쁨) |
| **D074** | CSS | B1 복사 → B3 Lightning CSS C ABI | Rolldown, Vite v8 | 자체 파서 (수개월), PostCSS (JS 전용) |
| **D075** | 개발 서버 | 번들 모드 + SSE → WebSocket HMR | esbuild --serve, Vite v8 방향 | 언번들 ESM (대형 프로젝트 느림, Vite도 전환 중) |
| **D076** | 그래프 순회 | DFS | Rollup, Rolldown, SWC | BFS (exec_index/순환 감지에 별도 알고리즘 필요) |
| **D077** | 병렬 파싱 | 싱글 MVP → Rolldown 슬롯 예약 | Rolldown | 처음부터 병렬 (동기화 버그 디버깅 고통) |
| **D078** | 그래프 저장 | 양방향 인접 리스트 | — (HMR 고려) | 순방향만 (HMR 역추적 비효율), 엣지 배열 (O(1) 접근 불가) |
| **D079** | Import 추출 | 파싱 후 AST 순회 | Rollup, Rolldown | 파서에서 수집 (완성된 파서 수정 리스크) |
| **D080** | 옵션 스펙 + 플러그인 | Rollup 수준 옵션 + 함수 포인터 PluginDriver | Rolldown (pre-sort) | 문자열 라우팅 (오타), 매크로 (Zig 불가), trait (장황) |
| **D081** | Resolver 구조 | 3계층 (resolver + cache + plugin) | Rolldown/oxc | 단일 파일 (커지면 가독성↓), 기능별 5개+ (오버엔지니어링) |

---

### D056: 번들러 개발 전략
- **결정**: 품질 먼저 → 속도 추가 (방법 B)
- **비교**: 방법 A(속도 먼저, esbuild/Bun) vs 방법 B(품질 먼저, Rollup→Rolldown)
- **이유**: 속도 최적화된 구조에 정교한 분석을 끼워넣기 어려움 (esbuild가 tree-shaking 개선 못 하는 이유). 반대로 정확한 알고리즘을 Zig/Arena/SIMD로 빠르게 만드는 건 인프라 최적화로 가능. ZTS 파서가 이미 정확도 우선(Test262 99%+)으로 만들어졌으므로 방법 B가 자연스러움.

### D057: 모듈 그래프 최우선
- **결정**: 모듈 그래프가 번들러의 최우선 구현 대상
- **이유**: tree-shaking, code splitting, 스코프 호이스팅, HMR, 증분 재빌드 전부 모듈 그래프 위에서 동작. 그래프 없이는 나머지 기능 구현 불가. 구현 순서: 모듈 해석 → 모듈 그래프 → 단일 번들 → 스코프 호이스팅 → tree-shaking → code splitting.
- **참고**: Rollup `src/Graph.ts`, Rolldown `crates/rolldown/src/module_loader/`

### D058: ESM 실행 순서 보장
- **결정**: 모듈 그래프 설계 시점에 ESM 실행 순서를 보장하는 구조 확립
- **이유**: 나중에 끼워넣기 어려움. 병렬 파싱(속도) + 순서 보장(정확도)을 양립하려면 그래프에 슬롯을 import 순서대로 예약하고, 파싱은 병렬로 하되 슬롯 순서가 실행 순서를 결정하는 설계 필요. Rollup의 DFS 후위 순서 알고리즘(~100줄) 참고. Rollup 자체도 "현재 알고리즘이 불완전"이라 인정하므로, 더 정교한 설계 여지 있음.
- **참고**: Rollup `src/utils/executionOrder.ts`, Rolldown의 슬롯 예약 방식

### D059: 스코프 호이스팅 방식
- **결정**: Rolldown식 (Rollup 알고리즘 + 네이티브 속도)
- **비교**: Webpack식 래핑(A) vs esbuild식 보수적 호이스팅(B) vs Rolldown식 정교한 호이스팅(C)
- **이유**: 안정성과 성능 둘 다 추구 (방법 B 전략). Rollup이 10년간 검증한 알고리즘으로 안정성 확보, Zig 네이티브로 성능 확보. 보수적 폴백(esbuild)은 번들 품질을 희생. 래핑(Webpack)은 런타임 오버헤드.
- CJS 모듈은 래핑 폴백 (호이스팅 불가), 순환 참조는 Rollup 알고리즘으로 처리

### D060: 플러그인 시스템
- **결정**: Rolldown 방식 — Rollup 호환 JS 플러그인 + Zig 네이티브 + WASM (3층)
- **비교**: esbuild(Go↔JS IPC, 느림) vs SWC(WASM only, Rust 필수) vs Rolldown(Rollup 호환 + 네이티브)
- **이유**: Rollup 호환으로 Day 1부터 기존 생태계 활용 가능 (수천 개 플러그인). 성능 중요한 내장 기능(resolve, commonjs)은 Zig 네이티브. SWC처럼 WASM only로 가면 진입장벽 높고 생태계 부족.
- **구현**: 내부 Plugin 인터페이스 하나 + 어댑터 3개 (ZigPlugin/JsPlugin/WasmPlugin). 번들러 코드는 Plugin 인터페이스만 사용.
- **JS 플러그인**: N-API로 같은 프로세스에서 호출 (esbuild의 IPC 문제 없음)
- Rollup 핵심 훅: resolveId, load, transform (3개만 알면 대부분 구현 가능)

### D061: Arena Allocator 도입 전략
- **결정**: 번들러 전에 1~3단계 완료, 4단계는 번들러와 동시
- **이유**: 번들러 후 도입 시 변경 범위 3배. `std.heap.ArenaAllocator` 사용하면 `std.mem.Allocator` 인터페이스 동일하므로 기존 코드 변경 최소.
- **설계**: Arena = 소유권 경계. 각 모듈(Parser/Transformer/Codegen)은 할당만 수행, 해제는 호출자가 Arena 단위로. Phase별 Arena 분리 (parse arena → transform arena → codegen arena). 번들러에서는 파일별 독립 Arena로 멀티스레드 lock-free 달성.
- **단계**: 1) Parser (하루), 2) Semantic Analyzer, 3) Transformer/Codegen, 4) 번들러 파일별 Arena

### D062: WASM AST API 직렬화
- **결정**: 바이너리 우선 + ESTree 변환 나중에 (둘 다 제공)
- **이유**: 24B 고정 노드 + u32 인덱스가 WASM 메모리에서 직접 접근 가능 (직렬화 비용 0, ZTS만의 차별점). ESTree는 JS 래퍼로 바이너리 위에 변환 계층 추가. oxc는 JSON 직렬화로 병목 발생.

### D063: 트리쉐이킹 수준
- **결정**: 점진적 (보수적 → 정교)
- **이유**: false positive(잘못된 제거) 위험을 단계별로 격리. 사용자 입장에서 "빌드는 되는데 런타임 깨짐"이 최악. 보수적으로 시작하면 이 위험 없음. esbuild/Rolldown도 같은 전략.
- **1단계** (번들러 MVP): export 사용 추적 + `sideEffects` 필드 (~300줄, 2~3일)
- **2단계**: `@__PURE__` 활용 + 미사용 함수 선언 제거
- **3단계** (프로덕션 전): 함수 본문 사이드이펙트 분석, 참조 그래프 (Rollup 수준)

### D064: package.json conditional exports 처리
- **결정**: Rolldown 방식 — import kind별 resolver 인스턴스 분리
- **비교**: esbuild(3개 맵, 커스텀 조건 시 `module` 자동 제거 함정) vs webpack(기본값 없이 전체 대체, DX 나쁨) vs SWC(exports 미흡, main/module/browser 필드 중심) vs Rolldown/oxc_resolver(kind별 인스턴스, 조건 고정)
- **이유**: resolver 생성 시 조건 세트를 고정하면 resolve 호출마다 분기 없음(성능). ESM/CJS/CSS 각각 다른 조건 필요한 건 스펙상 사실. Zig에서도 구조체 3~4개로 자연스럽게 구현.
- **설계**:
  - `resolver_import`: `["import", "module", "browser"(플랫폼별), "default"]`
  - `resolver_require`: `["require", "node"(플랫폼별), "default"]`
  - `resolver_css`: prefer_relative=true
  - 커스텀 조건은 추가 방식 (Rollup처럼), `module` 절대 자동 제거 안 함
  - TS 확장자 매핑: `.js`→`[.js, .ts, .tsx]` (Rolldown 방식)
  - `default`는 항상 마지막 (Node.js 스펙)
- **참고**: `references/rolldown/crates/rolldown_resolver/src/resolver_config.rs`, `references/bun/src/resolver/package_json.zig`

### D065: 순환 참조 처리
- **결정**: Rollup 알고리즘 + Bun 구현 패턴
- **비교**: esbuild(감지 안 함, const→var 변환으로 회피) vs SWC(petgraph 전이 폐포, 메모리 O(n²)) vs webpack(플러그인 위임) vs Rollup(DFS + 부모 체인 역추적, ~100줄) vs Bun(배열 스캔, defer 정리)
- **이유**: Rollup이 10년간 검증한 알고리즘이 가장 신뢰할 수 있음. Bun의 "작은 배열 스캔"이 Zig에 딱 맞음 — 순환 경로는 보통 3~5개 모듈이라 O(n²)이 해시맵보다 빠르고, defer로 스택 정리가 Zig 관용구. 경고(에러 아님)가 맞음 — d3, three.js 등 실제 프로젝트에 순환 흔함.
- **배제 이유**:
  - esbuild: 감지 안 하면 사용자가 문제를 모름. const→var는 의미 변경이라 위험
  - SWC: petgraph는 Rust 전용. 전이 폐포 O(n²) 메모리는 MVP에 과도
  - webpack: 핵심 기능을 외부 플러그인에 맡기면 안 됨
- **설계**:
  - DFS 시 `visited` + `in_stack` 배열로 순환 감지
  - 순환 발견 시 `cycle_group: u32` 부여, 경고 emit
  - 순환 그룹 내: re-export 축약 비활성화, 원본 import 순서 보존
  - const/let 의미 유지 (esbuild 방식 거부)
- **참고**: `references/rollup/src/utils/executionOrder.ts`, `references/bun/src/bundler/LinkerContext.zig`

### D066: 번들러 에러 핸들링
- **결정**: esbuild의 suggestion + Bun의 step enum + ZTS 기존 Diagnostic 확장
- **비교**: Rollup(파싱 에러 시 전체 빌드 중단) vs SWC(miette/anyhow, Rust 전용) vs webpack(구조화 안 된 문자열) vs esbuild(suggestion 포함, 파일별 독립) vs Bun(step enum, Logger.Log 중앙 수집)
- **이유**: esbuild의 suggestion이 DX에서 압도적 — `import './foo'` 실패 시 `Did you mean './foo.js'?` 제안. Bun의 `step: Step` enum (read_file/parse/resolve)이 디버깅에 결정적.
- **배제 이유**:
  - Rollup: 파싱 에러 하나로 전체 빌드 중단은 대형 프로젝트에서 불편
  - SWC: miette는 Rust 전용 에코시스템, Zig에서 재현 불필요
  - webpack: 문자열 기반 에러는 프로그래밍적 처리 어려움
- **설계**:
  ```
  BundlerDiagnostic {
      code: ErrorCode,         // UNRESOLVED_IMPORT, MISSING_EXPORT, CIRCULAR_DEPENDENCY...
      severity: Severity,      // error, warning, info
      message: []const u8,
      file_path: []const u8,
      span: Span,              // 기존 ZTS Span 재사용
      step: Step,              // resolve, parse, transform, link
      suggestion: ?[]const u8, // "Did you mean './foo.js'?"
      notes: []Note,           // 보조 위치 ("opened here", "defined here")
  }
  ```
  - 파싱 에러: 해당 모듈만 실패, 나머지 그래프 계속 빌드
  - 모듈 못 찾음: 경로형(`./`)이면 에러, bare specifier면 경고+external
  - 에러 누적 후 마지막에 일괄 출력
- **참고**: `references/esbuild/internal/resolver/resolver.go`, `references/bun/src/bundler/ParseTask.zig`, `references/bun/src/logger.zig`

### D067: 워크스페이스/모노레포
- **결정**: MVP에서 제외, 심링크 지원으로 충분
- **비교**: Bun(자체 패키지 매니저로 워크스페이스 감지) vs 나머지 6개 도구(전부 심링크에 의존)
- **이유**: 7개 도구 중 모노레포를 특별 처리하는 건 Bun뿐 (자체 패키지 매니저 내장이라 가능). esbuild, Rollup, Rolldown, webpack, SWC 전부 심링크에 의존. 심링크 + preserveSymlinks + realpath 캐시면 npm/yarn/pnpm 워크스페이스 전부 동작.
- **배제 이유**:
  - 자체 패키지 매니저: 범위가 너무 큼
  - 워크스페이스 자동 감지: 심링크가 이미 해결
  - Yarn PnP 우선 지원: 사용률 대비 구현 비용이 안 맞음
- **설계**:
  - resolver에 `resolveRealPath()` + 캐시 (Bun의 entry.cache.symlink 패턴)
  - `preserveSymlinks: bool` 옵션
  - Yarn PnP: 번들러 MVP 이후, resolver에 분기 추가
- **참고**: `references/bun/src/resolver/resolver.zig`, `references/esbuild/internal/resolver/resolver.go`

### D068: CJS ↔ ESM 상호운용 런타임 헬퍼
- **결정**: `__` 프리픽스 + esbuild/Rolldown 호환 헬퍼 함수 주입
- **비교**: esbuild/Rolldown(`__toESM` 등 헬퍼 주입) vs Rollup(`_interopDefault` 등) vs webpack/rspack(`__webpack_require__.*` 축약 프로퍼티) vs SWC(헬퍼 없이 AST 직접 변환, 인라인)
- **이유**: esbuild/Rolldown과 동일한 `__` 프리픽스로 사용자 친숙도 확보. 디버깅 시 `__toESM` 검색하면 esbuild 문서도 참고 가능. SWC처럼 인라인하면 파일마다 같은 코드 반복으로 번들 크기 증가. webpack의 `.n`/`.t` 축약은 가독성 희생.
- **배제 이유**:
  - `__zts_` 고유 프리픽스: 이름이 길고 생태계에서 낯섦. 실무에서 번들러 출력 간 충돌은 발생하지 않음
  - SWC 인라인: 헬퍼 코드가 파일마다 중복. tree-shaking 불가
  - webpack `__webpack_require__.*`: 프로퍼티 기반 축약은 스코프 호이스팅과 맞지 않음 (Rollup 방식 추구)
- **핵심 헬퍼 목록**:
  - `__commonJS(cb, mod)` — CJS 모듈을 클로저로 래핑, require() 함수 반환
  - `__esm(fn, res)` — ESM 코드 lazy 초기화
  - `__toESM(mod, isNodeMode, target)` — CJS→ESM 변환 (__esModule 플래그 체크, default 처리)
  - `__toCommonJS(mod)` — ESM→CJS 변환 (__esModule 프로퍼티 추가)
  - `__export(target, all)` — ESM exports를 Object.defineProperty getter로 구현
  - `__reExport(target, mod, secondTarget)` — export * from 처리
- **구현**: Rolldown처럼 runtime-base.js에 헬퍼 정의, 사용된 헬퍼만 번들에 포함 (비트플래그로 추적)
- **참고**: `references/esbuild/internal/runtime/runtime.go`, `references/rolldown/crates/rolldown/src/runtime/runtime-base.js`

### D069: 외부 모듈(external) 옵션 스펙
- **결정**: esbuild 방식 — 문자열 배열 + `*` 글롭. N-API 단계에서 Rollup 호환 (정규식/함수) 추가
- **비교**: esbuild(문자열+글롭만, 가장 단순) vs Rollup/Rolldown(문자열+정규식+함수) vs webpack(문자열+정규식+함수+오브젝트 매핑+externalsPresets, 가장 복잡)
- **이유**: CLI/JSON 설정에서는 문자열+글롭이면 충분. `react`, `@mui/*`, `node:*` 전부 커버. Zig에 정규식 엔진 불필요 — N-API 단계에서 JS 쪽이 정규식/함수를 평가하고 bool만 전달하면 됨.
- **설계**:
  - CLI: `--external react --external '@mui/*' --external 'node:*'`
  - 글롭 매칭: `*`는 `/` 제외 모든 문자. `@mui/*`는 `@mui/material` 매칭, `@mui/icons/foo`는 불매칭
  - `node:*` 빌트인: 플랫폼이 node이면 자동 external (옵션 없이도)
  - resolve 실패 시: 경로형(`./`, `../`)이면 에러, bare specifier면 경고+external (D066과 일관)
  - N-API 단계: `external: (string | RegExp | Function)[]` Rollup 호환 시그니처 지원
- **참고**: `references/esbuild/pkg/api/api.go` (External []string)

### D070: 모듈 ID 체계
- **결정**: u32 정수 인덱스 (`ModuleIndex = enum(u32)`)
- **비교**: 정수 인덱스(esbuild/Bun/Rolldown/SWC) vs 파일 경로 문자열(Rollup) vs 해시(webpack 빌드 시 변환)
- **이유**: 기존 ZTS 패턴(`NodeIndex`, `SymbolId`, `ScopeId` 전부 u32 enum)과 일관. 배열 O(1) 접근, 정수 비교 1명령어, 4바이트. 문자열 ID는 해시맵 필요 + 비교 O(n). u16은 monorepo에서 node_modules 포함 시 65,535 초과 가능성 있고, 구조체 패딩으로 절약 효과 없음.
- **설계**:
  ```
  ModuleIndex = enum(u32) { none = maxInt(u32), _ }
  modules: ArrayList(Module)           // modules.items[@intFromEnum(id)]
  path_to_module: StringHashMap(ModuleIndex)  // resolve 캐시
  ```
- **참고**: `references/bun/src/bundler/Graph.zig` (Index), `references/rolldown/crates/rolldown_common/src/types/module_idx.rs`

### D071: 소스맵 체이닝
- **결정**: 자체 파이프라인은 AST span 직접 매핑 + 플러그인은 collapse_sourcemaps() 합성
- **비교**: esbuild(인라인 리맵핑만, 플러그인 제한적) vs Rollup(Source/Link 트리, ~270줄) vs Rolldown(lookup 테이블, ~60줄) vs Vite(`@jridgewell/remapping` JS 외부 의존)
- **이유**: ZTS는 파이프라인 전체를 소유하므로 자체 변환은 중간 소스맵 불필요 (이미 D046에서 설계). 하지만 Rollup 호환 플러그인 시스템(D060)을 목표로 하므로, 플러그인 transform 시 소스맵 체이닝을 처음부터 설계해야 함.
- **배제 이유**:
  - esbuild 인라인만: 플러그인이 제한적이라 가능한 것. ZTS는 Rollup 호환 플러그인을 목표로 하므로 부족
  - Rollup 트리 구조: 플러그인 체인 깊어질수록 메모리 증가. Rolldown이 lookup 테이블로 단순화한 이유 있음
  - Vite `@jridgewell/remapping`: JS 외부 의존성, Zig에서 사용 불가
- **설계**:
  - 자체 파이프라인: AST span → codegen 시 원본 위치 직접 매핑 (중간 소스맵 없음)
  - 플러그인: TransformResult에 소스맵 포함 → collapse_sourcemaps()로 VLQ 역추적 합성 (~200줄)
  ```
  TransformResult = struct {
      code: []const u8,
      map: ?SourceMap,  // 플러그인이 반환하면 체이닝
  }
  ```
- **참고**: `references/rolldown/crates/rolldown_sourcemap/src/lib.rs`, `references/esbuild/internal/sourcemap/sourcemap.go`

### D072: 청크 네이밍/해싱
- **결정**: Rolldown 호환 `[name]-[hash].js` + xxhash64 + 플레이스홀더 2단계
- **비교**: esbuild(xxhash64, goroutine별 격리) vs Rollup/Rolldown(xxhash128, 플레이스홀더 `!~{idx}~`) vs webpack/rspack(md4→xxhash64 전환 중, `[contenthash]`)
- **이유**: `[hash]` = content hash (Rollup/Rolldown/esbuild 공통). xxhash64은 Zig 표준 라이브러리에 `std.hash.XxHash64` 내장으로 외부 의존성 0. Rolldown 플레이스홀더 방식이 순환 import 해시 문제를 우아하게 해결.
- **배제 이유**:
  - xxhash128: xxhash64로 충분 (충돌 확률 무시 가능). 128비트는 해시 길이만 늘림
  - md4/sha256: 느림. webpack도 xxhash64로 전환 중
  - esbuild goroutine 격리: Go에 최적화된 설계. Zig에서는 플레이스홀더가 더 자연스러움
- **설계**:
  - 기본 패턴: `[name]-[hash].js` (entry/chunk), `assets/[name]-[hash][ext]` (asset)
  - 해시: xxhash64, 기본 8자, base64url 인코딩
  - 2단계: 코드젠 시 `!~{idx}~` 플레이스홀더 삽입 → 전체 청크 완성 후 content hash 계산 → 치환
  - 사용자 설정: `entryFileNames`, `chunkFileNames`, `assetFileNames` (Rollup 호환)
- **참고**: `references/rolldown/crates/rolldown_utils/src/hash_placeholder.rs`, `references/esbuild/internal/xxhash/`

### D073: 모듈 타입 + 에셋 처리
- **결정**: rspack의 ModuleType enum + ParserAndGenerator 트레이트 패턴
- **비교**: esbuild(고정 6종 로더, 확장 불가) vs Rollup(전부 플러그인, 내장 없음) vs Rolldown(내장 최소 + 플러그인) vs rspack(ModuleType enum + Custom + register_parser_and_generator_builder) vs webpack(문자열 타입 + 훅)
- **이유**: 하나의 인터페이스(ParserAndGenerator)로 JS, JSON, CSS, asset, WASM, 커스텀 전부 처리. rspack에서 CSS 플러그인이 에셋과 동일한 구조로 동작하는 것이 증명. 사용자가 `.graphql`, `.mdx` 등 커스텀 타입을 플러그인으로 추가 가능.
- **배제 이유**:
  - esbuild 로더: 고정 6종, 사용자 확장 불가. 플러그인 시스템(D060) 목표와 충돌
  - Rollup 전부 플러그인: JSON 같은 기본 타입도 플러그인 필요 → DX 나쁨
  - webpack 문자열 타입: 타입 안전성 없음. enum이 Zig에 더 적합
- **설계**:
  ```
  ModuleType = enum { javascript, json, css, asset, asset_inline, asset_resource, asset_source, custom }

  ParserAndGenerator = struct {
      parseFn: *const fn(*ParseContext) Error!ParseResult,
      generateFn: *const fn(*GenerateContext) Error!GenerateResult,
      sizeFn: *const fn(*Module) usize,
  }
  ```
  - 내장: JS (파서+트랜스포머+코드젠 재사용), JSON (키별 named export + tree-shake), asset (auto inline/emit, 8KB 임계값)
  - 플러그인: `registerParserAndGenerator(type, impl)` 로 확장
  - JSON tree-shaking: Rolldown 방식 (키별 named export, 미사용 키 제거)
- **참고**: `references/rspack/crates/rspack_plugin_asset/src/lib.rs`, `references/rspack/crates/rspack_core/src/parser_and_generator.rs`

### D074: CSS 번들링
- **결정**: Phase B1 최소 CSS (JS에서 import 해석 + 출력 복사) + Phase B3 Lightning CSS C ABI 연동
- **비교**: esbuild(자체 CSS 파서 ~20파일, 풀 내장) vs Rolldown(기본 CSS + Lightning CSS 미니파이) vs Vite(PostCSS→Lightning CSS 전환 중) vs rspack(내장 Rust CSS) vs Rollup(플러그인 전용)
- **이유**: CSS 파서 자체 구현은 규모가 매우 큼 (esbuild ~20파일). CSS 스펙은 JS만큼 복잡하고 벤더 프리픽스, CSS Modules, 중첩 등 끝이 없음. Lightning CSS가 C API 제공 → Zig `@cImport`로 호출 가능. Vite v8도 Lightning CSS 기본 전환.
- **배제 이유**:
  - 자체 CSS 파서: 구현 수개월. 번들러 핵심이 아닌 곳에 리소스 낭비
  - PostCSS: JS 런타임 필요. Zig에서 사용 불가
  - 플러그인 전용: 기본 CSS 처리도 못 하면 사용자 경험 나쁨
- **설계**:
  - B1: `import './style.css'` → 모듈 그래프에 CSS 노드 (ModuleType.css) → 출력에 복사
  - B3: Lightning CSS C ABI로 @import 해석, CSS Modules, 미니파이, 벤더 프리픽스
  - D073의 ParserAndGenerator로 CSS 처리 등록 (rspack과 동일 구조)
- **참고**: `references/esbuild/internal/css_parser/` (규모 참고), Lightning CSS C API

### D075: 개발 서버
- **결정**: 번들 개발 모드 (esbuild --serve) + SSE 라이브 리로드 → 이후 WebSocket HMR
- **비교**: Vite(언번들 ESM→v8에서 번들로 전환 중) vs esbuild(전체 리빌드+SSE, HMR 없음) vs webpack-dev-server(Express+WebSocket+증분) vs Turbopack(증분 번들+WebSocket) vs Bun(자체 HTTP+WebSocket)
- **이유**: Vite조차 v8에서 번들 개발 모드로 전환 중 — 언번들 ESM은 대형 프로젝트에서 네트워크 요청 폭발 (Vite 팀: 3배 빠른 시작, 10배 적은 요청). ZTS가 Zig 네이티브로 빌드 빠르면 전체 리빌드도 충분. SSE가 WebSocket보다 단순 (단방향 충분).
- **배제 이유**:
  - 언번들 ESM (Vite v7): 대형 프로젝트에서 느림 (Vite 팀 자체 인정). 모듈 그래프+on-demand transform 파이프라인이 번들러보다 복잡해짐
  - WebSocket HMR 먼저: 모듈 그래프 diff, HMR boundary 탐색, React Fast Refresh 통합 등 복잡도 높음. SSE로 시작 후 업그레이드
  - webpack-dev-server: Express+sockjs 스택이 JS 전용
- **설계**:
  - B2: Zig `std.http.Server`로 번들 출력 서빙 + SSE 변경 감지 → 브라우저 전체 리로드
  - B3: WebSocket 업그레이드 + 모듈 단위 HMR + React Fast Refresh
- **참고**: `references/esbuild/pkg/api/serve_other.go`, `references/vite/packages/vite/src/node/server/`

### D076: 모듈 그래프 순회 방식
- **결정**: DFS (깊이 우선) — 싱글스레드 MVP, 이후 병렬 파싱 추가
- **비교**: DFS(Rollup/Rolldown/SWC) vs BFS(esbuild, goroutine 병렬에 최적화)
- **이유**: DFS 후위 순서가 곧 ESM 실행 순서 (D058). 순환 참조 감지가 DFS 스택에서 공짜 (D065). BFS는 별도 위상 정렬 + 순환 감지 알고리즘 필요. 시간복잡도는 둘 다 O(V+E)로 동일.
- **배제 이유**:
  - BFS: esbuild가 쓰는 이유는 Go goroutine 병렬 파싱에 BFS 큐가 자연스러워서. Zig에서는 DFS가 더 단순하고, exec_index + 순환 감지가 한 패스에 끝남
- **설계**:
  - MVP: 싱글스레드 DFS. 정확한 그래프 먼저 (D056 품질 먼저 전략)
  - 이후: 프로파일링 후 파싱이 병목이면 병렬 추가
  - DFS 한 패스로: import 추출 → 의존성 재귀 방문 → 후위 순서로 exec_index → 순환 감지

### D077: 병렬 파싱 전략
- **결정**: 싱글스레드 MVP → 프로파일링 후 Rolldown 슬롯 예약 방식으로 병렬화
- **비교**: esbuild(goroutine BFS, 처음부터 병렬) vs Rolldown(슬롯 예약 + 스레드 풀) vs Rollup(싱글스레드, 10년간 충분) vs SWC(petgraph 싱글)
- **이유**: 싱글스레드 DFS가 정확하면 병렬은 스레드 풀 + 슬롯 예약만 추가하면 됨. Module.state `reserved→parsing→ready`가 이미 설계되어 슬롯 예약 패턴 지원. 대부분의 프로젝트에서 병목은 파싱이 아니라 파일 I/O.
- **배제 이유**:
  - 처음부터 병렬 (esbuild): 정확성 검증이 어려움. 동기화 버그는 재현이 어렵고 디버깅이 고통. 품질 먼저 전략(D056)과 충돌
  - 영원히 싱글: 대형 모노레포(수천 파일)에서 파싱이 병목이 될 수 있음. 옵션은 열어둬야 함
- **Rolldown 슬롯 예약 패턴**:
  1. import 발견 → 그래프에 슬롯 예약 (import 순서대로, 싱글스레드)
  2. 예약된 모듈들을 `std.Thread.Pool`에서 병렬 파싱 (파일별 Arena, lock-free)
  3. 파싱 완료 → 슬롯에 AST 채움 → 새 import 발견 → 다시 슬롯 예약
  4. 모든 파싱 완료 후 DFS 후위로 exec_index 부여 (싱글스레드)
  - 슬롯 예약 순서가 import 순서를 보장 → exec_index가 ESM 실행 순서 보장
- **참고**: `references/rolldown/crates/rolldown/src/module_loader/`, `references/rollup/src/utils/executionOrder.ts`

### D078: 모듈 그래프 저장 방식
- **결정**: 양방향 인접 리스트 (dependencies + importers)
- **비교**: 순방향만(A, esbuild/Rolldown/Bun) vs 별도 엣지 배열(B) vs 양방향(C)
- **이유**: HMR에서 "이 파일 바뀌면 누가 영향받나?" 역추적이 필수. 나중에 역방향 맵을 빌드하면 그래프 변경 시마다 재빌드해야 하는데, 양방향이면 항상 최신. 메모리 차이는 모듈 수천 개 × u32 인덱스라 무시 가능.
- **배제 이유**:
  - 순방향만: HMR/watch에서 매번 역방향 맵 재빌드 필요. 증분 재빌드 시 비효율
  - 별도 엣지 배열: 특정 모듈의 의존성 찾으려면 배열 스캔 필요. 인접 리스트가 O(1) 접근
- **설계**:
  ```
  Module = struct {
      dependencies: []ModuleIndex,    // 내가 import하는 것 (순방향)
      importers: []ModuleIndex,       // 나를 import하는 것 (역방향)
      dynamic_imports: []ModuleIndex, // 동적 import (별도)
  }
  ```
  - 모듈 추가 시 양쪽 동시 업데이트: `A.dependencies.append(B)` + `B.importers.append(A)`
  - 헬퍼 함수로 캡슐화하여 불일치 방지

### D079: import 추출 방식
- **결정**: 파싱 후 AST 순회 (방법 B)
- **비교**: 파서에서 바로 수집(A, esbuild/Bun — 파서가 수집) vs 파싱 후 AST 순회(B, Rollup/Rolldown)
- **이유**: ZTS 파서가 이미 완성됨 (Phase 2, Test262 100%). 번들러 때문에 파서를 수정하면 안정성 리스크. AST 순회는 O(N)이라 속도 영향 무시 가능. `import_declaration`, `export_named_declaration`, `import_expression` 태그만 찾으면 됨.
- **배제 이유**:
  - 파서에서 수집: 파서와 번들러 관심사가 섞임. 파서 수정 시 번들러 의존성 추출도 영향받음. esbuild/Bun은 파서를 번들러와 함께 만들었기 때문에 가능한 것
- **설계**:
  ```
  fn extractImports(ast: *const Ast) []ImportRecord {
      // AST 순회: import_declaration, export_named_declaration,
      // export_all_declaration, import_expression 태그 수집
      // 각각 specifier + kind (static/dynamic/reexport) 반환
  }
  ```

### D080: 번들러 옵션 스펙 + 플러그인 훅 포인트
- **결정**: Rollup/Rolldown 수준 옵션 세트. 플러그인 훅 포인트는 처음부터 설계에 포함.
- **비교**: webpack/rspack(수백 개, 과도) vs Rollup/Rolldown(~50개, 합리적) vs esbuild(~30개, 너무 적음)
- **이유**: webpack처럼 모든 걸 옵션으로 열면 유지보수 지옥. esbuild처럼 너무 적으면 유연성 부족. Rollup 수준이 실무 균형점.

**MVP (B1) 옵션**:
- `entry`, `output.dir`, `output.format` (esm/cjs/iife), `output.entryFileNames`
- `external`, `platform` (browser/node/neutral), `target` (es2020 등)
- `minify`, `sourcemap` (true/false/inline/hidden), `define`, `drop`

**B2 옵션**:
- `resolve.alias`, `resolve.extensions`, `resolve.conditionNames`, `resolve.mainFields`, `resolve.preserveSymlinks`
- `output.chunkFileNames`, `output.assetFileNames`, `output.banner`/`footer`
- `treeshake`, `treeshake.moduleSideEffects`, `jsx`, `tsconfig`

**B3 옵션**:
- `plugins`, `output.globals`, `output.intro`/`outro`
- `css.modules`, `css.minify`, `server.port`/`host`/`hmr`
- `worker`, `experimental.reactRefresh`

**안 할 것**: webpack `module.rules` (D073 ParserAndGenerator로 대체), `optimization.splitChunks` (자동 code splitting), `resolve.fallback` (플러그인으로), `externalsType` (후순위), `stats` (기본 출력 충분)

**플러그인 디스패치 방식**:
- **결정**: 함수 포인터 구조체 + Rolldown pre-sort (방식 E)
- **비교**: 문자열 라우팅(A, Rollup) vs trait vtable(B, Rolldown) vs 매크로 코드 생성(C, rspack) vs enum+comptime(D, Zig 전용) vs 함수 포인터 구조체(E)
- **이유**: Zig에서 가장 자연스러움. optional 함수 포인터로 미구현 훅은 null → O(1) 스킵. Rolldown처럼 초기화 시 훅별 플러그인 순서 미리 계산 → 매 호출 정렬 없음.
- **배제 이유**:
  - A (문자열): 런타임 문자열 비교, 오타 컴파일 타임에 못 잡음
  - B (trait): Zig에 trait 없음. 인터페이스로 대체 시 20개+ 메서드가 장황
  - C (매크로): Zig에 proc macro 없음
  - D (enum+comptime): `@field(plugin, @tagName(kind))`는 읽기 어렵고 디버깅 불편
- **설계**:
  ```
  Plugin = struct {
      name: []const u8,
      resolve_id: ?*const fn(*Context, ResolveIdArgs) Error!?ResolveResult = null,
      load: ?*const fn(*Context, LoadArgs) Error!?LoadResult = null,
      transform: ?*const fn(*Context, TransformArgs) Error!?TransformResult = null,
  }

  PluginDriver = struct {
      plugins: []const *const Plugin,
      resolve_order: []const usize,   // pre-sorted (Rolldown 패턴)
      load_order: []const usize,
      transform_order: []const usize,

      fn resolveId(self, ctx, args) !?ResolveResult {
          for (self.resolve_order) |idx| {
              if (self.plugins[idx].resolve_id) |hook| {
                  if (try hook(ctx, args)) |result| return result;  // bail
              }
          }
          return null;
      }
  }
  ```
  - MVP: PluginDriver 구조체만 두고 plugins 비어 있음. 플러그인 없으면 기본 동작
  - 새 훅 추가: Plugin 필드 1줄 + PluginDriver dispatch 함수 1개
- **참고**: `references/rolldown/crates/rolldown_plugin/src/plugin_driver/build_hooks.rs` (pre-sort), `references/rspack/crates/rspack_hook/` (실행 전략)

**처음부터 설계에 포함해야 하는 B3 항목**:
- **PluginDriver 구조체**: 위 설계대로 처음부터 배치. 플러그인이 없으면 모든 훅이 null → 오버헤드 0.

**나중에 끼워넣어도 되는 B3 항목** (아키텍처 변경 없음):
- `plugins` 실제 구현 (PluginDriver에 플러그인 등록 + N-API 바인딩)
- `output.globals`: emitter에서 external → 글로벌 변수 치환. IIFE 포맷 구현 시점에 추가
- `output.intro/outro`: codegen 앞뒤 문자열 추가 (1줄 변경)
- `css.*`: Lightning CSS C ABI 호출 (독립적)
- `server.*`: 번들러 위 레이어
- `worker`: code splitting 위에 올림
- `experimental.reactRefresh`: transformer visitor 추가 (독립적)

### D081: Resolver 코드 구조
- **결정**: Rolldown 3계층 (A 방식)
- **비교**: 3계층(A, Rolldown/oxc — resolver + cache + plugin) vs 단일 파일(B, esbuild/Bun — 한 파일에 전부) vs 기능별 분리(C, webpack — 5개+ 파일)
- **이유**: ZTS 코드베이스가 이미 모듈별 분리 패턴. Zig에서 파일=모듈이라 분리가 자연스러움. 각 계층이 독립 테스트 가능.
- **배제 이유**:
  - 단일 파일 (esbuild): Go는 패키지 내 큰 파일이 문화적으로 허용되지만, Zig에서는 파일 분리가 관용구. 3000줄 단일 파일은 가독성 나쁨
  - 기능별 5개+ (webpack): package.json exports 복잡도를 아직 모르는 상태에서 미리 나누면 오버엔지니어링
- **설계**:
  ```
  src/bundler/
    resolver.zig        — 순수 경로 해석 (node_modules, package.json exports, 확장자)
    resolve_cache.zig   — import kind별 조건 세트 관리 + 결과 캐시 (D064)
    (B3) PluginDriver를 통해 resolve 훅 확장
  ```
- **참고**: `references/rolldown/crates/rolldown_resolver/`, `references/rolldown/crates/rolldown_plugin_vite_resolve/`

### D082: Per-Node 플래그 저장 전략 (@__PURE__ 등)
- **결정**: extra_data 슬롯 확장 (기존 패턴 재사용)
- **배경**: tree-shaking에서 `@__PURE__`, `@__NO_SIDE_EFFECTS__` 등 per-node 플래그가 필요. 24B 고정 노드(D037) 안에 공간 없음.
- **비교**:
  - flags 비트 빌리기: call_expression의 u16 flags에서 1비트씩 사용. 단순하지만 arg_count 범위 축소 (32767→16383). 플래그 추가마다 범위 계속 축소.
  - node_flags 사이드 테이블 ([]u8/u16/u32): 노드당 별도 플래그 배열. 모든 노드에 +N 바이트 낭비 (리터럴/식별자 등 플래그 불필요한 노드 포함). 새로운 패턴 도입 필요.
  - **extra_data 슬롯 확장**: call_expression을 data.binary → data.extra로 변경. extra_data에 [callee, args_start, args_len, flags] 저장. flags가 u32이므로 32개 플래그 가능, 슬롯 추가하면 무제한.
  - 노드 크기 확장 (24B→32B): 캐시 효율 33% 감소, WASM 직접 접근 포맷 변경. 모든 노드에 영향.
  - 가변 크기 노드 (Bun/esbuild 방식): 프로젝트 전체 재작성. WASM 직접 접근(D037 차별점) 포기.
- **이유**: extra_data는 이미 function/class 등 복잡한 노드가 사용하는 검증된 패턴. 필요한 노드만 필요한 만큼 슬롯 추가 (메모리 효율). 새 배열 불필요. WASM 호환 유지 (extra_data 배열 하나로 통합). call_expression도 이미 args를 extra_data를 통해 접근하므로 성능 영향 미미.
- **배제 이유**:
  - flags 비트: 플래그 추가될 때마다 arg_count 범위 축소. 다른 번들러(esbuild/oxc/Bun)는 인자 수 제한 없음 — ZTS만 제한 생기는 건 비대칭
  - node_flags 배열: 10만 노드 × 4B = 400KB 추가인데, 대부분의 노드는 플래그 불필요. 메모리 낭비
  - 노드 크기 확장: 모든 AST 순회 성능에 영향. 캐시 라인당 노드 수 감소 (2.6 → 2개)
  - 가변 크기: WASM 직접 접근 포기 + 프로젝트 전체 재작성 비용
- **참고**: esbuild(`ECall.CanBeUnwrappedIfUnused: bool`), oxc(`CallExpression.pure: bool`), Bun(`E.Call.can_be_unwrapped_if_unused: CallUnwrap(u2)`) — 모두 가변 크기 노드라 필드 추가로 해결. ZTS는 24B 고정이므로 extra_data로 동등한 확장성 확보.
- **전환 완료 노드**: call_expression, new_expression, static_member_expression, computed_member_expression, private_field_expression, unary_expression, update_expression, arrow_function_expression, tagged_template_expression
- **inline 유지 노드**: identifier_reference, string_literal (분석 단계 플래그만 필요 → tree-shaker 자체 구조에서 관리), array/object_expression (포맷팅 힌트는 span에서 유추), binary/assignment_expression (연산자 종류만, 확장 불필요)
- **규칙**: "파싱 시 설정되는 플래그가 있는 노드 → extra_data. 분석 시 플래그만 필요한 노드 → 해당 분석 단계의 자체 구조. 플래그 불필요/유추 가능 → inline 유지"

### D090: CJS→ESM Interop — Rolldown 방식 (2026-03-27)
- **결정**: Rolldown의 `Interop` enum (`babel`/`node`) + `ModuleDefFormat` enum 도입
- **이유**: esbuild의 암묵적 인자(isNodeMode 유무)보다 타입으로 의도 표현이 유지보수에 유리. ZTS가 하드코딩 `1`로 버그가 발생했던 사례.
- **설계**: importer의 def_format(확장자/package.json)으로 interop 모드 결정. ESM importer → Node 모드, 기타 → Babel 모드.
- **참고**: Rolldown `normal_module.rs:interop()`, esbuild는 `isNodeMode` 인자 생략으로 Babel 모드

### D091: 번들러 .js 파싱 — Unambiguous 모드 (2026-03-27)
- **결정**: 번들러에서 .js/.jsx를 Unambiguous 모드로 파싱 (oxc 방식). .ts/.tsx는 확정 module.
- **이유**: .js 파일이 import/export 없이도 번들에 포함될 수 있으므로, script/module 자동 판별 필요.
- **설계**: `configureForBundler()` API 분리. .ts/.tsx는 `is_unambiguous=false` (확정 module), .js/.jsx는 `is_unambiguous=true` (자동 판별).
- **참고**: oxc `ModuleKind::Unambiguous`, esbuild는 package.json "type" 기반

### D092: export * default 제외 — ESM 스펙 준수 (2026-03-27)
- **결정**: `collectExportsRecursive`에서 `export *` 재귀 전에 seen에 "default" 추가
- **이유**: ECMAScript 15.2.3.5 — `export *`는 `default`를 제외해야 함. date-fns에서 불필요한 default 추가 발견.
- **참고**: esbuild, rolldown 모두 동일하게 default 제외

### D093: Tree-shaker 2단계 — export 수준 DCE (2026-03-27)
- **결정**: purity.zig 공유 모듈로 expression 순수성 분석 확장 + export_default_declaration 순수성 검사
- **이유**: tslib `export default { ... }` 패턴에서 33개 함수가 모두 살아남음 (15.9KB vs esbuild 847B)
- **설계**: object/array/conditional/binary/unary/member expression 순수성 판정. 재귀 깊이 128 제한.
- **결과**: tslib 15.9KB → 793B (95% 감소)

### D094: StmtInfo 기반 statement-level tree-shaking — rolldown 방식 (2026-03-27)
- **결정**: rolldown의 StmtInfo 방식 도입 — 심볼 인덱스 기반 도달성 분석
- **이유**: 기존 span 기반 이름 매칭은 linker rename 후 불일치 발생. import binding 추적 불가.
- **설계**: semantic analyzer의 `symbol_ids[node_index]` 재활용. import를 side-effect-free로 처리. emitter에서 `transformer.new_symbol_ids`로 new_ast 기반 StmtInfo 구축.
- **결과**: pathe 13.8KB → 3.2KB (ESM), fp-ts 11.3KB → 5.0KB, smoke ❌ 4→2개
- **참고**: rolldown `StmtInfo` + `declared_stmts_by_symbol`, esbuild `Part` 시스템

### D095: exports 조건 해석 Node.js 스펙 준수 (2026-03-27)
- **결정**: `resolveConditions`에서 exports 객체의 key 순서로 탐색 (이전: conditions 배열 순서)
- **이유**: tslib `import.node` → CJS wrapper로 오매칭. Node.js 스펙은 exports key 순서가 우선.
- **결과**: tslib --platform=node 22KB FAIL → 1KB OK
- **참고**: esbuild는 conditions를 set으로 처리 + exports key 순서 순회

### D096: 번들러 병렬화 개선 + tree-shaker 역인덱스 (2026-03-29)
- **결정**: (1) finalize를 parseModule에 통합 — parse_arena 소유로 스레드 안전 (2) stmt_info O(S×N)→O(N log S) 단일 패스 (3) sym→stmt 역인덱스로 enqueue/isImportLive O(1) 조회
- **이유**: 프로파일링 결과 two bottlenecks — lodash-es 641모듈에서 finalize+resolve 순차 실행 81%, three.js에서 tree-shaker 89% (O(S×N) + O(S²))
- **결과**: three.js 1095ms→233ms (4.7배), lodash-es 210ms→159ms (1.3배), smoke 125개 전체 통과
- **보류**: resolve 병렬화 (95ms, 모듈당 0.15ms) — Zig 0.16 async/await 지원 후 rolldown 방식(join_all) 또는 esbuild 방식(파일 단위 파이프라인) 비교하여 결정. 현재는 절대값이 작아 투자 대비 효과 낮음.
- **참고**: esbuild — goroutine+channel 파일 단위 파이프라인, rolldown — tokio::spawn+join_all import 단위 병렬

### D097: 플러그인 state를 PluginState 구조체로 분리 (2026-04-13)
- **결정**: Transformer core에 산재하던 plugin-specific runtime state를 `plugin_state.zig`의 `PluginState` 구조체로 이사. 각 플러그인은 sub-struct(`plugins.worklet`, `plugins.refresh`) 소유.
- **이유**: 기존 Transformer에 `auto_worklet_next`, `worklet_body_depth`, `refresh_registrations` 등 7개+ 플러그인 필드 혼재 → core가 "generic JS transformer"가 아닌 "React+Reanimated 특화"로 변질. 유지보수 시 관심사 혼동.
- **설계 원칙 (유지보수 안전장치)**:
  1. **Plugin state 접근은 자기 plugin만**. Cross-plugin 직접 접근 금지 (예: `refresh.zig`가 `plugins.worklet.*`를 읽으면 안 됨).
  2. **Core는 명명된 hook point 함수로만 plugin 상태 접근** (예: `visitBodyWorkletAware`, `dispatchFunctionPlugins`).
- **왜 Visitor-Hook 아키텍처(Option B)로 가지 않았나**: Zig는 trait/interface가 없어 hook dispatch가 타입 안전성을 약화시킴. ZTS는 내부 플러그인만 상정(써드파티 AST 플러그인 비목표)이라 hook 인프라는 과설계. 위 규칙을 지키면 추후 B로 전환 비용이 저렴 (state는 이미 plugin별로 뭉쳐있음 → dispatch만 간접화).
- **참고**: oxc의 `TransformCtx`도 동일 패턴 (내부 플러그인 state를 단일 ctx struct). oxlint만 외부 JS 플러그인을 별도 프로세스 경계로 분리.
- **관련**: #1195, PR #1196 (Phase 1a — worklet 이사), PR #1197 (Phase 1b — refresh 이사)
- **알려진 cross-plugin 위반**: `worklet_plugin.zig`가 `plugins.refresh.suppress_registration`을 직접 세팅. 후속 과제로 core에 중립 API(`t.suppressRefreshInScope(...)` 등) 도입하여 해소 예정.

### D098: TranspileOptions 전달을 단일 JSON payload로 통일 (2026-04-14)
- **결정**: CLI/NAPI/WASM 공용 경계에서 옵션을 필드별 인자 → 단일 JSON 페이로드로 전환. `transpile.zig`의 `optionsFromJson()`이 유일한 파서.
- **이유**: 필드별 인자는 타겟(CLI/NAPI/WASM)마다 파싱/검증을 중복 구현 → 필드 추가 시 3곳에 흩어진 변경. 실제로 `TranspileResult`의 `es_target` / `source_root` 같은 신규 필드가 일부 타겟에만 연결되어 있던 버그(2c63d360 수정) 발생.
- **효과**: `zts.config.json` 자동 로드(D099)도 동일 파서 재사용 → 옵션이 한 곳에 정의되면 모든 경로로 자동 전파. DTO ↔ TS `TranspileOptions` 필드 sync는 `src/transpile_options_dto_test.zig`로 자동 검증.
- **관련 커밋**: 8047603a(migrate), 0d1efd43(DTO sync test)

### D099: `zts.config.json` 자동 로드 + JSON Schema 자동 생성 (2026-04-14)
- **결정**:
  1. CLI가 cwd에서 `zts.config.json`을 찾으면 자동 로드하여 기본값으로 적용. CLI 인자가 이 값을 덮어쓴다 — **우선순위: CLI > config.json**.
  2. `zig build schema` → `transpile-options.schema.json`을 comptime reflection으로 생성 (biome 방식).
  3. config 파일에 `"$schema": "./transpile-options.schema.json"` 선언으로 VSCode/IntelliJ autocomplete.
- **이유**: 옵션 정의를 Zig 코드(`TranspileOptions`) **한 곳**에만 두고 JSON schema / TS 타입 / CLI flag / config 로더가 모두 이를 따르도록 단일 소스 진실(single source of truth) 확립. 수동 schema 유지 부담 제거.
- **제약**: 번들러 전용 필드(`external`, `alias`, `entryPoints` 등)는 자동 로드 대상이 아님. `zts.config.{ts,js,...}` 또는 CLI/JS API로 지정.
- **관련 커밋**: e9272ac1(schema gen), e8b8e9cf(config auto-load)

### D100: Rich Diagnostic 시스템 확장 (2026-04-14)
- **결정**: 단일 message + span 구조를 multi-span label + help hint + docs URL 구조로 확장.
- **구성**:
  - Primary span + 보조 `labels[]`: "previously declared here" (6개 재선언 에러), "referenced from" (3개 참조→정의 에러)
  - `help`: 수정 방향 hint
  - `docs_url`: `ZTSxxxx` 에러 코드별 Starlight 문서 URL (`documents/` 사이트, 소문자 `zts` 세그먼트 사용)
- **노출 경로**:
  - CLI: ANSI 컬러 코드 프레임 + exit 1
  - `@zts/core` `transpile()`: `TranspileResult.errors`에 렌더된 문자열 (tsc 호환 — 에러 있어도 `code` 반환)
  - `@zts/core` `build()`: `{ errors, warnings }` 구조화 배열 (`{ text, location }`)
- **이유**: 참조 관계가 있는 에러(재선언, undefined reference)는 single-span으로 "어디서 문제가 시작됐는지"를 보여줄 수 없음. rust/rolldown/Bun 모두 multi-span으로 전환. docs URL은 Starlight 사이트와 연결하여 CLI → 웹 연속성 확보.
- **관련 커밋**: 9dfea7dd, 9d9b3ab5, 75626350, 853ad5c2, fa257fed, 2698079e, abd1d11b(crash report)

### Phase 6 (Advanced) 미결정 사항
- 개발 서버 고급 기능 (증분 재빌드, 프레임워크 통합)
