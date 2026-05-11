---
title: 도구 비교
description: ZNTC와 Rolldown, esbuild, SWC, Rspack, Vite의 기능 범위를 비교합니다.
---

ZNTC는 **TypeScript/Flow 트랜스파일러 + library/app 번들러 + dev server**를 한 바이너리/패키지에서 제공하는 쪽에 초점을 둡니다. Vite 전체 생태계나 webpack loader/plugin universe를 그대로 복제하는 것이 목표는 아닙니다.

## 상태 표기

| 표기 | 의미 |
| ---- | ---- |
| 지원 | 문서화된 public surface와 회귀 테스트가 있음 |
| 부분 | 핵심 경로는 지원하지만 일부 옵션, hook, format, edge case가 제한됨 |
| 정책 차이 | 의도적으로 다른 의미론을 선택함 |
| 미지원 | 현재 public surface 없음 |

## 번들러/트랜스파일 기능

| 영역 | ZNTC | Rolldown | esbuild | SWC | Rspack/Vite |
| ---- | --- | -------- | ------- | --- | ----------- |
| TS/JSX/Flow 단일 파일 변환 | 지원 | 부분 | TS/JSX 지원, Flow 미지원 | 지원 | loader/plugin 조합 |
| library bundling | 지원 | 지원 | 지원 | spack/swcpack은 v2에서 제거 예정 | Rspack 지원, Vite는 Rollup/Rolldown 사용 |
| app builder (`index.html`, env, public) | 지원 | Vite 통합 경로 권장 | serve/build primitive 중심 | 미지원 | Vite/Rspack 강점 |
| code splitting | 지원 | 지원 | 지원 | 제한적 | 지원 |
| manual chunks | 지원 (`config`/API) | 지원 | 미지원 | 미지원 | 지원 |
| runtime core-js polyfills | 지원 | 외부 plugin/사용자 처리 | 미지원 | `env` 중심 | Rspack/SWC loader 계층 |
| React Native preset | 지원 | 미지원 | 미지원 | transformer로 사용 가능 | Metro/Rspack 별도 |
| WASM playground | 지원 | WASM build 제공 | browser build 제공 | wasm package 제공 | 도구별 상이 |

## Plugin/API 호환성

| 영역 | ZNTC 상태 | 비고 |
| ---- | -------- | ---- |
| esbuild-style `setup(build)` | 부분 | `onResolve`, `onLoad`, `onTransform`, `onResolveContext`, `onAstFunction` 중심 |
| Rollup/Vite-style `resolveId` / `load` / `transform` | 지원 | `vitePlugin()` wrapper 사용 |
| output hooks (`renderChunk`, `generateBundle`) | 부분 | 일반 후처리 가능. 모든 Rollup hook을 지원하지는 않음 |
| lifecycle (`buildStart`, `buildEnd`, `closeBundle`) | 지원 | `watch()`에서도 초기 build와 rebuild마다 호출 |
| `this.resolve()` / `this.emitFile()` | 미지원 | graph mutation surface로 별도 설계 필요 |
| `buildSync()` + JS plugin | 미지원 | native worker가 JS callback을 기다리는 구조와 충돌 |
| plugin hook filter | 부분 | esbuild-style filter는 지원. Rolldown object-hook filter와 완전 동일하지 않음 |

## CLI와 분석 도구

| 영역 | ZNTC | 비교 |
| ---- | --- | ---- |
| CLI/JS API/config 옵션 | 대부분 대응 | [옵션 매트릭스](/zntc/reference/options-matrix/)에서 surface별 확인 |
| `metafile` JSON | 지원 | esbuild 호환 basic format |
| interactive bundle analyzer | 지원 | [/analyze/](/zntc/analyze/)에서 `meta.json` 업로드 |
| `--analyze` tree 출력 | 부분 | 현재 JSON 중심. CLI tree format은 후속 |
| profile/benchmark | 지원 | `--profile*`, `zntc bench`, JS `benchmark()` |
| diagnostic docs URL | 지원 | `ZNTCxxxx` 에러 코드 문서와 연결 |

## Vite/Rspack 대비 앱 기능

| 기능 | ZNTC | 비고 |
| ---- | --- | ---- |
| `zntc dev` / `zntc build` / `zntc preview` | 지원 | dev/build/preview 의미를 맞추는 방향 |
| HTML entry rewrite | 지원 | `<script type="module" src>` 엔트리 처리 |
| `.env*` / `import.meta.env.*` | 지원 | `--env-dir`, `--env-prefix` |
| `public/` 복사 | 지원 | `--public-dir` |
| CSS Modules | 지원 | app mode |
| PostCSS / Tailwind v4 | 지원 | `@tailwindcss/postcss` 설정 |
| Sass/SCSS | 지원 | 선택 의존성 `sass` 필요 |
| Less/Stylus | 미지원 | 사전 컴파일 또는 plugin 처리 |
| CSS-only HMR | 지원 | PostCSS dependency watch 포함 |
| error overlay | 지원 | build/runtime error overlay, sourcemap remap |
| `import.meta.glob` | 미지원 | Vite 호환 surface로 후속 후보 |
| SSR build | 미지원 | 현재 product boundary 밖 |
| dev proxy | 지원 | `--proxy /api=http://...` |

## 의도적인 정책 차이

| 항목 | ZNTC 정책 |
| ---- | -------- |
| import attributes loader override | `with { type }`은 pass-through metadata. loader 선택은 확장자/loader 옵션 기준 |
| physical device runtime target | `iPhone 8` 같은 물리 디바이스 이름은 받지 않음. Browserslist query를 사용 |
| auto node polyfill | 자동 polyfill 묶음은 제공하지 않음. `fallback`, `alias`, plugin으로 명시 |
| property mangle | public API 안정성과 디버깅 비용 때문에 우선순위 낮음 |
| SSR | Vite/Rspack과 달리 현재 앱 빌더의 핵심 범위가 아님 |

## 관련 공식 문서

- [esbuild API](https://esbuild.github.io/api/)
- [esbuild Bundle Size Analyzer](https://esbuild.github.io/analyze/)
- [Rolldown Getting Started](https://rolldown.rs/guide/getting-started)
- [Rolldown Plugin API](https://rolldown.rs/apis/plugin-api)
- [SWC Getting Started](https://swc.rs/docs/getting-started)
- [SWC Bundling (swcpack)](https://swc.rs/docs/usage/bundling)
- [SWC Plugin Guide](https://swc.rs/docs/plugin/ecmascript/getting-started)
