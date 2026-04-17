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

## 설정 파일 (`zts.config.json` / `zts.config.{ts,js,mjs,cjs,mts,cts}`)

### `zts.config.json` — TranspileOptions defaults
CLI 실행 시 cwd에 `zts.config.json`이 있으면 자동으로 로드되어 기본값으로 사용된다.
**우선순위: CLI 인자 > config.json**.

스키마는 `zig build schema`로 생성되는 `transpile-options.schema.json`과 일치하며,
`"$schema": "./transpile-options.schema.json"` 선언으로 VSCode 등에서 자동완성된다.

매핑되는 필드: `target`, `sourcemap`, `minify`, `jsx*`, `platform`, `format`, `quotes`,
`drop*`, `flow`, `experimentalDecorators`, `emitDecoratorMetadata`,
`minifyWhitespace/Identifiers/Syntax`, `sourcemapDebugIds`, `sourcesContent`, `sourceRoot` 등.
번들러 전용 필드(`external`, `alias` 등)는 **미처리** — CLI 또는 JS 빌드 API에서 지정.

### 플러그인은 `@zts/core` JS API로 (npm 배포 CLI)
JS 플러그인을 쓰려면 npm 배포 CLI(`packages/core/bin/zts.mjs`)를 사용. 내부적으로
`@zts/core` NAPI로 in-process 실행하여 Vite/Rollup 스타일 플러그인(`resolveId`,
`load`, `transform`, `renderChunk`, `generateBundle`)을 지원. 상세: [PLUGINS.md](./PLUGINS.md).

> Zig 독립 바이너리(`zig-out/bin/zts`)는 JS 플러그인 비지원 (builtin 플러그인만).
> 이전의 `--plugin` / `zts.config.{ts,js}` 자동 로드는 D101로 제거됨.

## @zts/core 요약

```typescript
import { init, transpile, buildSync, build, watch, vitePlugin } from "@zts/core";
init();

transpile(src, opts);      // 단일 파일 in-memory 변환
buildSync(opts);           // 동기 번들링 (JS 플러그인 미지원 — 데드락 방지)
await build(opts);         // 비동기 번들링 (플러그인 가능)
watch(opts);               // 증분 빌드 + 파일 감시 (WatchHandle.stop()으로 종료)
```

### TranspileOptions 주요 필드
`target`, `sourcemap`, `minify`, `jsx`, `jsxImportSource`, `flow`, `format`,
`platform`, `quotes`, `dropConsole/Debugger`, `experimentalDecorators`,
`emitDecoratorMetadata`, `useDefineForClassFields`, `asciiOnly`, `browserslist`, `define`.

### TranspileResult
```typescript
{ code: string; map?: string; errors?: string }
```
`errors`는 시맨틱 에러가 있을 때 CLI와 동일한 rich diagnostic 텍스트로 렌더링된 문자열
(**tsc 호환 정책**: 에러가 있어도 `code`는 함께 반환). 플레이그라운드/IDE는 이 필드를 파싱해 마커로 표시.

### BuildOptions — 플러그인 훅
esbuild 스타일: `onResolve`, `onLoad`, `onTransform`, `onRenderChunk`, `onGenerateBundle`.
- `onResolve`는 `{ disabled: true }` 반환 시 해당 import를 빈 모듈로 처리.

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
- `watchFolders` (JS API / config) — 모듈 그래프 바깥 루트까지 감시 대상에 포함 (Metro 호환)
- `resolver.blockList` — 특정 경로를 resolve에서 제외 (Metro `resolver.blockList` 호환)
- `resolve.fallback` — 해석 실패 시 대체 매핑 (webpack `resolve.fallback` / Metro `extraNodeModules` 호환)

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

### 진단 (Diagnostics)
파서/시맨틱 에러는 rich diagnostic 포맷으로 렌더된다 — 파일 경로, 라인/컬럼, 코드 프레임,
multi-span label(선언 위치 hint, 참조→정의 label), help hint, `ZTSxxxx` 코드별 docs URL 포함.
CLI는 에러 시 exit 1, `@zts/core`는 `TranspileResult.errors`에 문자열로 노출.

### Asset / RN
- `@2x` / `@3x` scale variant 자동 감지 + emit
- Metro AssetRegistry 호환 출력 (`--platform=react-native`)

### Crash report
panic 발생 시 Bun 스타일 crash report 출력 — repro 정보 + GitHub 레포 링크.
