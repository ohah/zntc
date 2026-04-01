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

## 스모크 테스트 (실제 패키지 빌드)
```bash
cd tests/benchmark && bun run smoke.ts  # 125개 패키지 빌드+실행 검증 (avg 0.74x)
```
