# Test Suite

## Test262 (TC39 정합성)
```bash
zig build test262                       # 전체 실행 (50,504건)
zig build test262 -- --filter=language  # 언어 기능만
zig build test262 -- --verbose          # 상세 출력
```

## 유닛 테스트
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

## 통합 테스트 (Bun)
```bash
cd tests/integration && bun test     # CLI 통합 테스트
cd tests/e2e && bun test             # Playwright E2E (dev server)
```
테스트 파일:
- `tests/integration/tests/bundle-smoke.test.ts` — 번들 스모크 (99개 케이스)
- `tests/integration/tests/devserver.test.ts` — 개발 서버
- `tests/integration/tests/downlevel.test.ts` — ES 다운레벨링
- `tests/integration/tests/es5-rn.test.ts` — RN ES5 + Hermes
- `tests/integration/tests/flow-rn.test.ts` — Flow + React Native
- `tests/integration/tests/hermes-runtime.test.ts` — Hermes 런타임
- `tests/integration/tests/plugin.test.ts` — JS 플러그인
- `tests/integration/tests/polyfill-rbm.test.ts` — 폴리필 + run-before-main
- `tests/integration/tests/watch-json.test.ts` — watch-json NDJSON 이벤트
- `tests/integration/tests/compat-table.test.ts` — kangax compat-table ES5~ES2022 (237 subtests)
- `tests/integration/tests/swc-compare.test.ts` — ZTS vs SWC 다운레벨링 비교 (29 cases × 9 targets)
- `tests/integration/tests/css-bundle.test.ts` — CSS 번들링 (26개: @import 체인, 순환, 중복 제거, BOM, 대용량 등)
- `tests/integration/tests/css-library-smoke.test.ts` — CSS 라이브러리 스모크 (Emotion, Styled-Components, 네이티브 CSS)
- `tests/integration/tests/stage3-decorator-smoke.test.ts` — MobX 6 Stage 3 decorator 스모크
- `tests/e2e/tests/smoke.test.ts` — E2E 스모크 (브라우저 실행)
- `tests/e2e/tests/browser-smoke.test.ts` — 브라우저 번들 E2E

## 스모크 테스트 (실제 패키지 빌드)
```bash
cd tests/benchmark && bun run smoke.ts  # 143개 패키지 빌드+실행 검증
```
