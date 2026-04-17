# zts

Zig로 작성한 고성능 JavaScript/TypeScript/Flow 트랜스파일러 + 번들러.

> **Status**: Phase 1–6 전반 완료 (렉서/파서/트랜스포머/코드젠/번들러/Dev 서버/HMR).
> Test262 50,504건 100% 통과. 131개 npm 패키지 스모크 테스트 통과. 상세: [docs/ROADMAP.md](./docs/ROADMAP.md).

## Goals

- **Fast**: SIMD(@Vector) 렉서, 파일당 Arena + mimalloc, 인덱스 기반 AST, 멀티스레드 parse/resolve/emit
- **Correct**: Test262 100% 통과, 스모크 테스트 + kangax compat-table + SWC 비교 CI 검증
- **Compatible**: TS/TSX/JSX/Flow 전부, 엔진 타겟(es5~esnext, chrome/safari/node 등), Rollup/Vite 플러그인 호환
- **Small**: WASM 빌드 지원, 외부 C/C++ 의존성 최소화

## Build

```bash
# Prerequisites: Zig 0.15.2 (use mise for version management)
mise install

# Build & run
zig build
zig build run -- src/index.ts

# Test
zig build test            # 유닛 테스트
zig build test262         # Test262 (50,504건)
zig build napi            # NAPI .node 애드온
zig build wasm            # WASM 타겟
```

통합 테스트 / 스모크 테스트:
```bash
cd tests/integration && bun test
cd tests/benchmark && bun run smoke.ts
```

## Usage (JS / NAPI)

```typescript
import { init, transpile, build } from "@zts/core";
init();

// 단일 파일 트랜스파일
const { code } = transpile(source, { jsx: "automatic", target: "es2022" });

// 번들링 (플러그인 지원)
const result = await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  format: "esm",
  platform: "browser",
  plugins: [/* esbuild/Vite/Rollup 스타일 훅 */],
});
```

Vite 어댑터: `vite-plugin-zts` — Vite의 esbuild transform을 ZTS로 교체.

## Documentation

- [CLAUDE.md](./CLAUDE.md) — 프로젝트 요약 + Dev workflow
- [docs/STRUCTURE.md](./docs/STRUCTURE.md) — 디렉토리 구조
- [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) — 파이프라인 / 메모리 / 설계 결정 요약
- [docs/ROADMAP.md](./docs/ROADMAP.md) — Phase 현황, 성능, 미지원 기능
- [docs/TESTING.md](./docs/TESTING.md) — Test262, 유닛/통합/스모크 테스트
- [docs/BUNDLER.md](./docs/BUNDLER.md) — 번들러 상세 설계
- [docs/PLUGINS.md](./docs/PLUGINS.md) — 플러그인 시스템 + 로더
- [docs/HMR.md](./docs/HMR.md) — Dev 서버 + HMR
- [docs/FLOW.md](./docs/FLOW.md) — Flow 지원 전략
- [docs/DECISIONS.md](./docs/DECISIONS.md) — 설계 결정 로그
- [docs/BACKLOG.md](./docs/BACKLOG.md), [docs/ISSUES.md](./docs/ISSUES.md) — 백로그 / 미해결 이슈

## References

- [Bun JS Parser](https://github.com/oven-sh/bun) (Zig, MIT)
- [oxc](https://github.com/oxc-project/oxc) (Rust, MIT)
- [SWC](https://github.com/swc-project/swc) (Rust, Apache-2.0)
- [esbuild](https://github.com/evanw/esbuild) (Go, MIT)
- [Rolldown](https://github.com/rolldown/rolldown) (Rust, MIT)
- [Hermes](https://github.com/facebook/hermes) (C++, MIT) — Flow 파서
- [Metro](https://github.com/facebook/metro) (JS, MIT) — React Native 번들러 참고
- [Test262](https://github.com/tc39/test262)

## License

MIT
