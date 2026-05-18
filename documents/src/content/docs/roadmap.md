---
title: 로드맵
description: ZNTC 가 다음에 추가할 기능과 현재 지원되지 않는 항목을 정리합니다.
---

이 페이지는 사용자가 직접 마주치는 기능 단위로만 정리합니다. 내부 단계·진행률·구현 디테일은 GitHub 저장소를 참고하시기 바랍니다.

## 예정 기능

### 번들러

#### WASM 공개 AST API

브라우저 / Node 외부에서 ZNTC 의 AST 를 읽고 변환할 수 있도록 WASM 모듈로 노출합니다. 현재 Playground 와 Metafile Analyze 페이지가 내부적으로 사용하는 WASM 빌드를 사용자 API 로 안정화 후 공개합니다. AST 스키마 안정화가 선행 조건입니다.

#### 외부 Zig 플러그인

지금은 worklet · Fast Refresh 같은 빌트인 트랜스폼만 Zig 함수 포인터 기반 플러그인으로 동작합니다. 사용자가 작성한 Zig 모듈을 빌드 시 정적 링크해 in-process 로 호출하는 경로를 공개 예정입니다. NAPI 플러그인이 갖는 JS↔Native 직렬화 비용이 없는 대신, 빌드 시점에 Zig 컴파일러를 함께 사용해야 합니다.

#### Rollup plugin context API 확장 (ESTree AST)

`vitePlugin()` 어댑터로 `resolveId` · `load` · `transform` · `renderChunk` · `generateBundle` 같은 주요 Rollup hook 과 `getModuleInfo()` 의 대부분 필드를 지원합니다. 남은 항목은 plugin context API 의 일부 (`this.parse()` · `this.resolve()` · `this.emitFile()` · `ModuleInfo.meta`) 와 `ModuleInfo.ast` — 모듈의 **ESTree 호환 AST** 를 plugin 에서 직접 읽을 수 있게 하는 ESTree adapter 입니다. ZNTC 내부 AST 를 ESTree 스펙 형태로 변환해 노출하는 작업이 선행됩니다.

#### 청크별 CSS 분리

`import './style.css'` 자동 emit, `@import` 인라이닝, Lightning CSS minify 까지는 지원합니다. 코드 스플리팅 시 CSS 도 청크별로 분리해 emit 하는 항목이 후순위로 잡혀 있습니다. (`.module.css` 클래스명 해싱·scope 는 앱 모드에서 이미 빌트인 지원입니다 — [Plugin Recipes 의 CSS Modules](/zntc/guides/plugin-recipes/#css-modules) 참조.)

#### 정밀 dead-code elimination (innerGraph 확장)

순수 local 변수의 straight-line dead store 는 제거합니다. branch / loop / try 같은 control-flow 안의 변수 할당 추적은 진행 중입니다.

#### lazyBarrel 정밀화

barrel re-export (`export * from`, `export { X } from`, `import * as X; export { X }`) 의 컴파일 생략은 순수·local·namespace 패턴에서 동작합니다. wrapper barrel 안에서 imported binding 을 mutate 하는 패턴(예: lodash-es 의 `lodash.default.js`) 은 현재 보수적으로 lazy 를 통째로 비활성화합니다. mutation 영역만 부분 lazy 로 적용하는 정밀화가 남아 있습니다. 현재 동작 한계는 [Tree-shaking](/zntc/guides/tree-shaking/) 참조.

#### mangleProps

cross-module property 난독화입니다. esbuild 와 유사한 기준이며 아직 미구현입니다.

#### Module Concatenation 고도화

rspack / rolldown 수준의 scope hoisting 입니다.

#### Persistent disk cache

현재는 watch / serve 세션 내 in-memory 파싱 캐시 + resolve 캐시만 사용합니다. 디스크 기반 영구 캐시로 cold rebuild 시간을 더 줄이는 항목이 후순위로 잡혀 있습니다.

#### Lazy compilation

dev 모드에서 모듈을 온디맨드로 컴파일해 시작 시간을 줄이는 항목입니다. 미구현.

### Transpiler

#### `.d.ts` 생성 (isolatedDeclarations)

지금은 `tsc` 에 위임합니다. 향후 isolatedDeclarations 기반의 emit 을 자체적으로 지원할 예정입니다.

### Dev Server

#### 단일 Zig dev server 로 수렴

현재는 두 dev server 가 공존합니다.

- **Zig 네이티브** (`zntc serve` / `zntc dev`) — Node 미설치 환경에서도 standalone 동작.
- **JS** (`zntc dev <root>` app 모드) — postcss / sass 같은 JS 생태계 플러그인 위임용.

장기 목표는 BoringSSL 통합 + 플러그인 호스트 추상화를 거쳐 Zig 단일 서버로 수렴하는 것입니다 (Bun 모델 참조). 우선순위는 안정성·CSS·생태계 항목 모두 이후입니다.

### 생태계

#### 플러그인 예제

PostCSS · Tailwind · SVG · YAML 같은 자주 쓰이는 케이스를 레퍼런스 플러그인으로 정리합니다.

#### 마이그레이션 가이드

esbuild → ZNTC, Vite → ZNTC 설정 대응표를 확장합니다. 일부 가이드는 이미 [Migration](/zntc/guides/migration/) 에서 다룹니다.

#### 프레임워크 통합 (Next.js · Remix · SvelteKit · Expo)

각 프레임워크가 번들러를 내장하고 있어, 어댑터는 사실상 해당 프레임워크 compiler 의 부분 재구현을 의미합니다. 가장 마지막 단계로 잡혀 있습니다.

- **Expo**: React Native 위에 얹힌 메타 프레임워크. 일반 React Native 앱은 이미 `--platform=react-native` 로 빌드 가능하지만, Expo Router 의 파일시스템 라우팅 manifest, Expo CLI 의 prebuild, EAS 빌드 파이프라인과의 통합은 별도 어댑터가 필요합니다.

#### NativeWind (React Native + Tailwind)

React Native 에서 Tailwind 클래스(`className`)를 스타일로 변환하는 NativeWind 는 현재 `nativewind/babel` 을 사용자 Babel 플러그인으로 그대로 통과시켜 동작합니다 (`--platform=react-native` 빌드 경로). 1급 지원으로는 ① 레퍼런스 예제 + RN 빌드 E2E 회귀 가드, ② Tailwind CSS 컴파일을 플러그인 API 뒤로 통합 (`global.css` 의 `@tailwind` 디렉티브 → RN 엔트리), ③ `package.json` 에 `nativewind` 가 있으면 RN 프리셋이 자동 배선하는 zero-config 를 예정하고 있습니다. `className` → style 변환을 Babel 없이 ZNTC 트랜스포머에서 직접 수행하는 경로는 이득 실측 후 결정합니다.

#### React Native CLI + MCP

React Native 빌드는 이미 ZNTC 코어 네이티브 엔진이 수행합니다 (`--platform=react-native`). 추가될 것은 별도 번들러가 아니라 `react-native.config.js` 의 command plugin 진입점 하나입니다 — 이 플러그인만 추가하면 기존 `react-native start`/`react-native bundle` 이 Metro 대신 ZNTC 를 경유합니다 (인자 매핑 + 기존 RN dev server 기동). 범용 `zntc` CLI 는 RN 의존성에 오염되지 않도록 이 진입점을 `@zntc/react-native` 에 둡니다. 또한 ZNTC dev server 에 이미 있는 MCP(JSON-RPC) 에 RN 빌드·리로드 제어 도구를 추가해, LLM 에이전트가 RN 빌드를 직접 구동할 수 있게 할 예정입니다.

#### Chrome CDP 번들 검증 (MCP / CLI)

지금도 내부 테스트는 Chrome DevTools Protocol 로 번들을 실제 브라우저에서 실행해 sourcemap·런타임 에러를 검증합니다. 이 경로를 사용자 CLI 명령과 MCP 도구로 승격해, 빌드 결과를 헤드리스 Chrome 에서 실행하고 console error·uncaught·sourcemap 해석 결과를 리포트하도록 할 예정입니다 (Playwright 는 optional dependency). 에이전트가 빌드 → 브라우저 런타임 검증을 한 루프로 돌릴 수 있습니다.

#### Vite 호환 모드

`vite.config.js` 를 직접 읽어 마이그레이션 비용을 제로화하는 장기 목표입니다.

## 현재 한계

### Next.js / Remix 직접 빌드 불가

두 프레임워크는 번들러가 RSC payload 직렬화, 파일시스템 routing manifest, loader/action 서버-클라이언트 분리 등 프레임워크 일부로 고정돼 있어 일반 번들러로 대체할 수 없습니다. 일반 React · Vue · Svelte SPA 와 React Native (Metro 호환 출력) 는 지원합니다.

### core `--bundle` 모드에서 `.module.css` 자동 변환

앱 모드 (`zntc dev` · `zntc build`) 에서는 `.module.css` 의 클래스명 해싱·scope 변환을 빌트인으로 지원합니다 ([Plugin Recipes 의 CSS Modules](/zntc/guides/plugin-recipes/#css-modules) 참조). core `--bundle` 모드에서는 자동 변환을 하지 않으므로 Vite 어댑터 또는 사용자 플러그인 (PostCSS Modules / Lightning CSS Modules) 을 거쳐야 합니다.

### 청크별 CSS 분리

code splitting 시 CSS 는 단일 산출물로 emit 됩니다. 청크별 CSS 분리는 후순위.

### Persistent disk cache · Lazy compilation · mangleProps

위 "예정 기능" 의 미구현 항목들입니다.

### control-flow 기반 일반 dead store

`if` / `for` / `try` 내부에서 다시 덮어쓰여 의미가 없는 변수 할당은 일부 보존됩니다. straight-line dead store 만 제거합니다.

### wrapper barrel mutation 패턴

barrel 모듈이 imported binding 을 mutate 하는 경우 (lodash-es 등 일부 라이브러리) lazy barrel 최적화가 통째로 꺼집니다. 결과의 정확성은 보장되지만 번들 사이즈가 더 클 수 있습니다.

### tsconfig `paths` 매우 많을 때 (수백 개 이상)

첫 resolve 만 선형 스캔이고 이후는 resolve 캐시가 흡수합니다. 일반 프로젝트 규모에서는 실측 영향이 없습니다.

### WASM 공개 AST API

`@zntc/wasm` 의 `transpile()` · `build()` · `buildChunks()` · `VirtualFileSystem` 은 사용자 `import` 용으로 제공됩니다. 사용법은 [설치 가이드](/zntc/guides/installation/) 의 WASM 섹션 참조. 모듈 단위 ESTree 호환 AST 를 plugin 에서 직접 읽고 변환하는 surface 는 위 "예정 기능 > WASM 공개 AST API" 항목 — AST 스키마 안정화가 선행됩니다.
