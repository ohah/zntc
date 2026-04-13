---
title: Babel → ZTS 이관 가이드
description: Metro babel.config.js를 ZTS로 옮길 때 각 플러그인/프리셋을 어떻게 대응하는지 정리합니다.
---

Metro 기반 `babel.config.js`를 ZTS로 옮길 때 각 플러그인/프리셋의 대응을 정리합니다.

## 대응 매트릭스

| Babel 설정 | ZTS 대응 | 비고 |
|---|---|---|
| `@react-native/babel-preset` | `platform: "react-native"` | JSX/Flow/class props 자동 |
| `@babel/preset-env` | `target: "es2020"` 등 | engine 타겟도 가능 (`chrome80` 등) |
| `@babel/plugin-transform-flow-strip-types` | `flow: true` 또는 RN 프리셋 | `.js.flow`/`@flow` pragma 자동 |
| `@babel/plugin-proposal-decorators { legacy }` | `experimentalDecorators: true` | Stage 3도 별도 지원 |
| `@babel/plugin-transform-class-properties { loose }` | `useDefineForClassFields: false` | tsconfig와 동기화 |
| `@babel/plugin-transform-private-methods { loose }` | target 자동 다운레벨 | 별도 옵션 불필요 |
| `@babel/plugin-proposal-optional-chaining` | target 자동 다운레벨 | ES2020 내장 |
| `babel-plugin-root-import` | `alias: { "~/": "./src" }` | tsconfig `paths`로도 가능 |
| `react-native-worklets/plugin` | 내장 worklet 플러그인 | `platform: "react-native"`로 자동 |
| `babel-plugin-lodash` | `alias: { lodash: "lodash-es" }` | ESM tree-shaking이 대체 |
| `transform-remove-console` | `drop: ["console"]` | |
| `transform-react-remove-prop-types` | `pure: ["PropTypes.*"]` + DCE | React 19+에선 불필요 |
| 커스텀 Babel 플러그인 | **Babel bridge** (아래 섹션) | 또는 ZTS 플러그인 포팅 |

## 기본 이관 예시

### Before — `babel.config.js`

```js
module.exports = {
  presets: ["module:@react-native/babel-preset"],
  plugins: [
    ["babel-plugin-root-import", { rootPathSuffix: "./src", rootPathPrefix: "~/" }],
    "@babel/plugin-transform-flow-strip-types",
    ["@babel/plugin-proposal-decorators", { version: "legacy" }],
    ["@babel/plugin-transform-class-properties", { loose: true }],
    ["@babel/plugin-transform-private-methods", { loose: true }],
    ["react-native-worklets/plugin"],
  ],
  env: {
    production: {
      plugins: ["transform-remove-console"],
    },
  },
};
```

### After — `zts.config.ts`

```ts
import { defineConfig } from "@zts/core";

export default defineConfig({
  platform: "react-native",
  target: "es2020",
  alias: { "~/": "./src" },
  experimentalDecorators: true,
  useDefineForClassFields: false,
  drop: process.env.NODE_ENV === "production" ? ["console"] : [],
});
```

플러그인 배열이 0줄로 줄어듭니다. RN 프리셋 + worklet + Flow는 `platform: "react-native"`에 전부 포함됩니다.

## Babel bridge — 커스텀 Babel 플러그인 재사용

내장으로 대체할 수 없는 커스텀 Babel 플러그인(예: 사내 preset, testID 자동 주입, AppRegistry 래핑 등)은 **Babel을 통째로 transform 훅에서 호출**해 재사용할 수 있습니다.

### 설치

```bash
bun add -D @babel/core
```

### `zts.config.ts`

```ts
import { defineConfig } from "@zts/core";
import * as babel from "@babel/core";
import mcpPreset from "@ohah/react-native-mcp-server/babel-preset";

export default defineConfig({
  platform: "react-native",
  plugins: [
    {
      name: "babel-bridge",
      transform: {
        filter: /\.(jsx?|tsx?)$/,
        handler(code, id) {
          const out = babel.transformSync(code, {
            filename: id,
            presets: [[mcpPreset, { renderHighlight: true }]],
            plugins: [
              // 여기에 그 외 커스텀 Babel 플러그인
            ],
            babelrc: false,
            configFile: false,
            sourceMaps: true,
          });
          if (!out) return null;
          return { code: out.code ?? code, map: out.map ?? undefined };
        },
      },
    },
  ],
});
```

**핵심 포인트**:
- `babelrc: false, configFile: false` — 프로젝트 `babel.config.js`를 재귀적으로 읽지 않도록 명시. ZTS 설정과 이중 변환 방지
- `filter` — 필요한 확장자만. `node_modules` 제외 원하면 `filter` 함수에 `!/node_modules/.test(id)` 추가
- `sourceMaps: true` — 소스맵 체이닝. ZTS가 이후 단계에서 병합
- 반환 형식: `{ code, map? }`. `null` 반환 시 ZTS 기본 파이프라인으로 폴백

### 성능 고려

각 모듈마다 Babel을 한 번 돌리므로 **개발 중 dev server 웜업은 느려집니다**. 프로덕션 번들은 ZTS 본체보다 `@babel/core` 호출 비용이 지배적. 다음 중 하나로 완화:

1. `filter`를 좁혀 Babel이 꼭 필요한 파일만 통과 (예: `src/**/*.tsx`만)
2. 자주 쓰는 플러그인은 **ZTS 플러그인으로 포팅** (아래 섹션)
3. dev는 Babel bridge, prod는 ZTS 네이티브로 분기

## ZTS 플러그인으로 포팅

Babel bridge는 간편하지만 느립니다. 성능이 중요하거나 빌드 횟수가 많다면 ZTS 플러그인 API로 재작성하는 게 정답입니다.

Rollup/Vite 스타일 훅(`resolveId`, `load`, `transform`)으로 커스텀 플러그인 직접 작성:

```ts
// zts.config.ts
import { defineConfig } from "@zts/core";

export default defineConfig({
  plugins: [
    {
      name: "inject-testid",
      transform: {
        filter: /\.tsx?$/,
        handler(code, id) {
          // JSX elements에 testID prop 주입 등
          // 자세한 AST 훅은 플러그인 가이드 참조
          return null;
        },
      },
    },
  ],
});
```

자세한 플러그인 작성법: 플러그인 가이드, 플러그인 레시피.

## 자주 묻는 케이스

### Q. `babel-plugin-lodash`는 꼭 필요한가?

Metro에선 tree-shaking이 약해 `import { debounce } from 'lodash'` 시 lodash 전체(~70KB)가 번들됨 → 이 플러그인으로 cherry-pick 필수였음.

ZTS는 ESM tree-shaking이 정상 동작하므로:
- `lodash-es` 사용 → 자동 cherry-pick (최적)
- `lodash` 유지 → `alias: { lodash: "lodash-es" }` 한 줄로 해결
- 즉 플러그인 포팅 불필요

### Q. `transform-react-remove-prop-types`는?

React 19+는 PropTypes API 자체를 제거. TypeScript 사용 중이면 PropTypes 자체가 없을 것.

남은 PropTypes 코드 제거가 필요하면:

```ts
pure: ["PropTypes.string", "PropTypes.number", /* ... */]
```

+ dead code elimination으로 상당 부분 제거. 완벽히는 커스텀 플러그인 필요.

### Q. `env.production.plugins` 분기는?

ZTS에선 `NODE_ENV` 기반 분기를 `defineConfig` 내부에서:

```ts
const isProd = process.env.NODE_ENV === "production";
export default defineConfig({
  drop: isProd ? ["console", "debugger"] : [],
  plugins: isProd ? [minifyPlugin] : [],
});
```

### Q. babel `overrides` (파일별 규칙)는?

`plugins[].transform.filter`로 파일 패턴별 변환을 분리:

```ts
plugins: [
  { name: "a", transform: { filter: /\.tsx$/, handler: ... } },
  { name: "b", transform: { filter: /\/legacy\//, handler: ... } },
]
```

## 점진적 이관 전략

한 번에 Babel 전체를 걷어내지 않아도 됩니다:

1. **Stage 1** — `platform: "react-native"` + alias 기본 설정 + Babel bridge로 기존 플러그인 전부 유지
2. **Stage 2** — Babel 플러그인을 하나씩 내장 기능으로 치환하거나 ZTS 플러그인으로 포팅 → bridge에서 제거
3. **Stage 3** — bridge 자체 제거. `@babel/core` 의존성 삭제

각 단계가 독립적으로 배포 가능합니다.

## 관련

- 플러그인 가이드
- 플러그인 레시피
- React Native 가이드
- 마이그레이션 가이드 (esbuild/Vite/webpack)
