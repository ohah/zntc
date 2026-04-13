# ZTS - Zig TypeScript Transpiler

Zig로 작성하는 JS/TS/Flow 트랜스파일러 + 번들러 (SWC/oxc 수준 목표).
C NAPI 바인딩으로 Node.js/Bun에서 in-process 사용, Vite/Rollup 플러그인 어댑터 지원.

## Tech Stack
Zig 0.15.2 · C NAPI v8 (vendor/node-api-headers/) · Node.js 24+ / Bun 1.3+ · mise · `zig build`

## Documentation
- [docs/STRUCTURE.md](./docs/STRUCTURE.md) — 디렉토리 구조
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — 파이프라인 아키텍처
- [docs/ROADMAP.md](./docs/ROADMAP.md) — Phase 현황, 성능, 미지원, 기술부채
- [docs/TESTING.md](./docs/TESTING.md) — Test262, 유닛/통합/스모크 테스트
- [BUNDLER.md](./BUNDLER.md), [PLUGINS.md](./PLUGINS.md), [HMR.md](./HMR.md), [DECISIONS.md](./DECISIONS.md), [FLOW.md](./FLOW.md)
- CLI 옵션 전체: `zts --help` / JS API: `packages/core/index.ts` / README

## Commands
```bash
zig build [test|test262|napi|wasm|run]
```
- NAPI 테스트: `cd packages/core && bun test` (또는 `node --test napi.test.mjs`)
- 통합 테스트: `cd tests/integration && bun test` (**반드시 이 디렉토리에서 실행** — 루트에서 실행 시 경로 해석 실패)

## @zts/core 요약
`init()` → `transpile(src)` / `buildSync(opts)` / `await build(opts)`.
플러그인 훅: `onResolve`, `onLoad`, `onTransform`, `onRenderChunk`, `onGenerateBundle`.
Rollup/Vite 어댑터: `vitePlugin({...})` (모든 훅 async 지원).
`vite-plugin-zts`: Vite의 esbuild transform을 ZTS로 교체 (`zts()` 플러그인).

## 주요 동작 포인트
- `--platform=browser` + `--bundle` → IIFE + `NODE_ENV=production` 자동 define, Node 빌트인 빈 모듈
- `--platform=node` → Node 빌트인 자동 external
- `--platform=react-native` → RN 프리셋: `.ios.*`/`.android.*`/`.native.*` 확장자, `react-native` main-field/exports 조건, `--flow` 자동
- `--watch`/`--serve` → 증분 빌드, `--watch-json`은 NDJSON 이벤트 stdout 출력 (외부 HMR 연동)
- Dev server 외부 인터페이스: `/sse/events` (SSE 빌드 이벤트), `/reset-cache` (Control API), `/mcp` (Model Context Protocol — Claude Code 등 LLM 에이전트 연동)
- ES 다운레벨: `es5`~`es2025`/`esnext` (ES2023 hashbang strip, ES2025 `using` 다운레벨)
- `import './x.css'` → 별도 CSS 파일 자동 생성 (Lightning CSS minify)

## Development Workflow
1. 작업 단위 작게 (하나의 PR = 하나의 기능)
2. 독립 작업은 서브에이전트로 병렬
3. main 직접 push 금지 — feature branch → PR → merge
4. PR 후 `/simplify` 필수 (파일 간 상호작용까지 검토)
5. 구현 전 Test262/유닛 테스트 먼저
6. Zig 초보자에게 설명 포함

PR 제목: `feat(lexer): add numeric literal tokenization` 형식.

## References
Bun (src/js_parser.zig, js_lexer.zig) · oxc · SWC · esbuild · Hermes (Flow) · Metro (RN) · TypeScript · Test262 · tc39.es/ecma262
