# ZNTC - Zig Native Transpiler Compiler

JavaScript / TypeScript / Flow 를 네이티브 속도로 처리하는 Zig Native Transpiler Compiler.
트랜스파일과 번들링 파이프라인을 함께 제공합니다.

> **Status**: Phase 1–6 전반 완료 (렉서/파서/세만틱/트랜스포머/코드젠/번들러/Dev 서버/HMR).
> Test262 50,504건 / 50,504 통과 (100%, 0 fail). 144 npm 패키지 스모크 테스트 통과 (esbuild 대비 평균 0.82x 사이즈, 합성 벤치 7ms vs Bun 10ms / esbuild 13ms / rolldown 62ms).
> 상세: [docs/ROADMAP.md](./docs/ROADMAP.md)

## Goals

- **Fast**: SIMD(@Vector) 렉서, 파일당 Arena + mimalloc, 인덱스 기반 24B 고정 AST, parse / resolve / emit 멀티스레드 + Producer-Consumer 파이프라인
- **Correct**: Test262 100% 통과, 스모크 + kangax compat-table + SWC 비교 + Hermes 런타임 / Metro Flow 정합성 CI
- **Compatible**: TS / TSX / JSX / Flow 전부, 엔진 타겟 (es5~esnext, chrome / safari / node / hermes), Vite / Rollup / esbuild / Metro 호환 플러그인
- **Small**: WASM 빌드 (transpile-only + bundler 포함), 외부 C/C++ 의존성은 mimalloc 만

## Build

```bash
# Prerequisites: Zig 0.15.2 (mise 권장)
mise install

# 빌드
zig build                       # zntc CLI + lib (Debug)
zig build -Doptimize=ReleaseFast  # 성능 측정용
zig build run -- src/index.ts   # CLI 직접 실행

# 테스트
zig build test                  # Zig 유닛 / 통합 테스트
zig build test262-run           # Test262 50,504건 실행
zig build napi                  # @zntc/core 용 NAPI .node
zig build wasm                  # transpile-only WASM
zig build wasm-bundler          # bundler 포함 WASM (wasm32-wasi + threads)
zig build schema                # BuildOptions JSON 스키마 자동 생성
```

JS 사이드 테스트:
```bash
cd tests/integration && bun test         # CLI / NAPI 통합 테스트
cd tests/e2e && bun test                 # Playwright E2E
cd tests/benchmark && bun run smoke.ts   # 144 패키지 빌드+실행 vs esbuild/rolldown/rspack
```

## Usage (JS / NAPI)

```typescript
import { init, transpile, build } from "@zntc/core";
init();

// 단일 파일 트랜스파일
const { code, map } = transpile(source, {
  filename: "input.ts", // TS/TSX syntax requires an explicit .ts/.tsx filename
  jsx: "automatic",
  target: "es2022",
  sourcemap: true,
});

// 번들링 (esbuild / Vite / Rollup 호환 플러그인 훅)
const result = await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: ["chrome100", "safari16"],
  define: { "process.env.NODE_ENV": '"production"' },
  plugins: [
    {
      name: "my-plugin",
      setup(build) {
        build.onResolve({ filter: /^virtual:/ }, (args) => ({ path: args.path, namespace: "virtual" }));
        build.onLoad({ filter: /.*/, namespace: "virtual" }, () => ({ contents: "export const x = 1" }));
      },
    },
  ],
});
```

CLI:
```bash
zntc src/index.ts --bundle --outdir dist --format=esm --target=es2022
zntc --watch src/index.ts                           # NDJSON 이벤트 (--watch-json)
zntc serve src/main.tsx --port 5173                 # Dev 서버 + HMR + Fast Refresh
```

Vite 어댑터 — `vite-plugin-zntc` 가 Vite 의 esbuild transform 을 ZNTC 로 교체합니다.

## Documentation

- [CLAUDE.md](./CLAUDE.md) — 프로젝트 요약 + Dev workflow
- [docs/USAGE.md](./docs/USAGE.md) — CLI / `@zntc/core` JS API / 플랫폼 / watch / ES 타겟 / CSS
- [docs/CONFIG.md](./docs/CONFIG.md) — `zntc.config.{ts,js,json}` / tsconfig / .env / CLI flag 우선순위
- [docs/STRUCTURE.md](./docs/STRUCTURE.md) — 디렉토리 구조
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — 파이프라인 / 메모리 / 설계 결정
- [docs/ROADMAP.md](./docs/ROADMAP.md) — Phase 현황, 성능, 미지원
- [docs/TESTING.md](./docs/TESTING.md) — Test262 / 유닛 / 통합 / 스모크 / perf 가드
- [docs/BUNDLER.md](./docs/BUNDLER.md) — 번들러 상세 설계
- [docs/PLUGINS.md](./docs/PLUGINS.md) / [docs/AST_PLUGINS.md](./docs/AST_PLUGINS.md) — 플러그인 시스템
- [docs/HMR.md](./docs/HMR.md) — Dev 서버 + HMR
- [docs/FLOW.md](./docs/FLOW.md) — Flow 지원 전략
- [docs/DECISIONS.md](./docs/DECISIONS.md) / [docs/INVARIANTS.md](./docs/INVARIANTS.md) — 설계 결정 / 불변
- [docs/DEBUG.md](./docs/DEBUG.md) — 디버그 / 진단
- [docs/BACKLOG.md](./docs/BACKLOG.md) — 백로그 (미해결 버그는 [GitHub Issues](https://github.com/ohah/zntc/issues))

## Packages

| 패키지 | 역할 |
|--------|------|
| `@zntc/core` | NAPI .node 바인딩 + Node.js / Bun CLI (`zntc` 커맨드) + transpile / bundle / lightningcss |
| `@zntc/web` | dev server + HMR overlay + postcss / sass pipeline + dev controller (#2539) |
| `@zntc/server` | private — protocol / WS frame / watcher / HMR channel (web 의 dist 에 inline, 사용자 install 불필요) |
| `@zntc/wasm` | WASM 빌드 (브라우저 playground / Deno / Workers) |
| `@zntc/shared` | core / wasm 공유 타입 (TranspileOptions, Target, compat-engines) |
| `vite-plugin-zntc` | Vite 의 esbuild transform 을 ZNTC 로 교체 (`@zntc/core` 만 사용) |

### Install matrix

- `@zntc/core` 단독 — `zntc transpile` / `zntc bundle` (라이브러리 모드) / WASM 환경
- `@zntc/core` + `@zntc/web` — `zntc dev` / `zntc preview` / `zntc build` (app 모드 with postcss / sass / CSS Modules / HMR overlay)
- `vite-plugin-zntc` — Vite 사용자 (Vite 자체 dev server / HMR — `@zntc/web` 불필요)

## References

- [Bun JS Parser](https://github.com/oven-sh/bun) (Zig, MIT) — 파서 / 렉서 / SIMD
- [oxc](https://github.com/oxc-project/oxc) (Rust, MIT) — 트랜스포머 / Reference flags
- [SWC](https://github.com/swc-project/swc) (Rust, Apache-2.0) — 다운레벨 비교
- [esbuild](https://github.com/evanw/esbuild) (Go, MIT) — 번들러 아키텍처 / 호환
- [Rolldown](https://github.com/rolldown/rolldown) (Rust, MIT) — Rollup 호환 / Vite 통합
- [Hermes](https://github.com/facebook/hermes) (C++, MIT) — Flow 파서 임베딩 + RN 런타임
- [Metro](https://github.com/facebook/metro) (JS, MIT) — React Native 번들러 호환
- [TypeScript](https://github.com/microsoft/TypeScript) (TS, Apache-2.0) — 다운레벨 / decorator 케이스
- [Test262](https://github.com/tc39/test262) — TC39 정합성 50,504건

## License

MIT
