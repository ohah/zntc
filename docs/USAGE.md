# Usage

CLI 실행법, `@zts/core` JS API, 그리고 주요 옵션의 동작 규칙을 한곳에 정리한 문서.

## Commands

```bash
zig build [test|test262|napi|wasm|run]
```

- NAPI 테스트: `cd packages/core && bun test` (또는 `node --test napi.test.mjs`)
- 통합 테스트: `cd tests/integration && bun test` (**반드시 이 디렉토리에서 실행** — 루트에서 실행 시 경로 해석 실패)
- 스모크 테스트: `cd tests/benchmark && bun run smoke.ts` (실제 npm 패키지 빌드/실행 검증)
- 전체 CLI 옵션: `zts --help`

## @zts/core 요약

```typescript
import { init, transpile, buildSync, build } from "@zts/core";
init();

transpile(src, opts);      // 단일 파일 in-memory 변환
buildSync(opts);           // 동기 번들링 (JS 플러그인 미지원 — 데드락 방지)
await build(opts);         // 비동기 번들링 (플러그인 가능)
```

### 플러그인 훅
esbuild 스타일: `onResolve`, `onLoad`, `onTransform`, `onRenderChunk`, `onGenerateBundle`.

### Rollup/Vite 호환 어댑터
- `vitePlugin({ name, resolveId, load, transform, renderChunk, generateBundle })` — 모든 훅 async 지원
- `vite-plugin-zts` — Vite의 esbuild transform을 ZTS로 교체 (`zts()` 플러그인)

상세: [docs/PLUGINS.md](./PLUGINS.md)

## 주요 동작 포인트

### 플랫폼 프리셋
- `--platform=browser` + `--bundle` → IIFE 출력 + `NODE_ENV=production` 자동 define + Node 빌트인 빈 모듈 대체
- `--platform=node` → Node 빌트인(`node:fs`, `fs`, 서브패스 포함) 자동 external
- `--platform=react-native` → RN 프리셋: `.ios.*` / `.android.*` / `.native.*` 확장자, `react-native` main-field / exports 조건, `--flow` 자동 활성화

### Watch / Serve
- `--watch` / `--serve` — 증분 빌드 (PersistentModuleStore + ResolveCache 보존, 변경 모듈만 재파싱)
- `--watch-json` — NDJSON 이벤트를 stdout으로 출력 (외부 HMR 연동용)

### Dev server 외부 인터페이스
- `/sse/events` — SSE 빌드 이벤트 (`server_ready`, `watch_change`, `bundle_build_*`, `cache_reset`)
- `/reset-cache` — Control API, 외부에서 캐시 무효화 트리거
- `/mcp` — Model Context Protocol (JSON-RPC 2.0). Claude Code 등 LLM 에이전트가 `.mcp.json`으로 직접 연결 가능. 도구: `reset_cache`, `get_build_events`

상세: [docs/HMR.md](./HMR.md)

### ES 다운레벨링
- `--target=es5` ~ `es2025` / `esnext` 지원
- 엔진 타겟(`--target=chrome80,safari14,node16` 등)은 compat-table 기반 feature-level 다운레벨링
- ES2023: hashbang(`#!`) strip
- ES2025: `using` / `await using` 다운레벨

### CSS 번들링
- `import './x.css'` → 별도 CSS 파일 자동 생성
- `@import` 체인 인라이닝 (Zig 네이티브 스캐너)
- `--minify` 시 Lightning CSS (optionalDependency)로 CSS minify

상세: [docs/BUNDLER.md](./BUNDLER.md)
