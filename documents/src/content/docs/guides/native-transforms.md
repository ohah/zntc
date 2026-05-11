---
title: 네이티브 트랜스폼 (Babel 없이)
description: styled-components / emotion / Reanimated worklets / Flow — ZNTC 가 Babel 플러그인 없이 직접 처리하는 1st-party transform 사용법.
---

다른 번들러에서 Babel 플러그인 / preset 으로 따로 묶어야 했던 변환들을 ZNTC 는 **본체에 내장**되어 있습니다. 옵션만 켜면 동작하므로 별도 `@babel/core` 의존성, plugin 등록, 사전 컴파일 단계가 필요 없습니다.

이 페이지는 네 가지 1st-party transform 의 사용법을 정리합니다.

- [styled-components](#styled-components) — `compiler.styledComponents`
- [emotion](#emotion) — `compiler.emotion`
- [Reanimated worklets](#reanimated-worklets) — `"worklet"` 디렉티브 자동 변환
- [Flow](#flow) — 타입 어노테이션 스트리핑

> esbuild / rolldown / rspack 에서 이들을 사용하려면 각각 별도의 Babel 단계 또는 transform plugin 을 추가해야 합니다. ZNTC 는 같은 단일 패스 안에서 처리합니다.

## styled-components

`babel-plugin-styled-components` 대응. plugin 등록 없이 `compiler.styledComponents` 옵션만 켜면 동일한 결과 (`displayName`, deterministic `componentId`, SSR hydration mismatch 방지) 를 얻습니다.

### 켜기

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  compiler: {
    styledComponents: true,   // 기본 옵션으로 모두 활성
  },
});
```

### 옵션 풀 셋

```ts
defineConfig({
  compiler: {
    styledComponents: {
      displayName: true,               // devtools 표시 (default: NODE_ENV !== "production")
      ssr: true,                       // 결정론적 componentId hash (default: true)
      fileName: true,                  // componentId 에 파일명 포함 (default: true)
      minify: true,                    // CSS whitespace minify (default: true)
      transpileTemplateLiterals: true, // 다운레벨된 템플릿 인식 (default: true)
      pure: false,                     // styled.X 부수효과 없음 hint (default: false)
      namespace: "my-app",             // displayName/componentId namespace prefix
      topLevelImportPaths: ["@my-org/styled"], // vendored fork 인식
      cssProp: false,                  // `<div css={...}>` 를 module-level styled component 로 추출
    },
  },
});
```

### 동작 예시

```tsx
// 입력
import styled from "styled-components";
const Button = styled.button`color: red;`;
```

```tsx
// 출력 (development)
const Button = styled.button.withConfig({
  displayName: "Button",
  componentId: "sc-1a2b3c4d-0",
})`color: red;`;
```

`fileName: true` 면 `displayName` 이 `app__Button` 처럼 prefix 되어 동일 이름이 다른 파일에 있을 때도 구분됩니다.

## emotion

`@emotion/babel-plugin` 대응. 자동 label 부여 + sourceMap 인라이닝 + `importMap` 을 통한 vendored fork 인식까지 포함합니다.

### 켜기

```ts
defineConfig({
  jsxImportSource: "@emotion/react",   // JSX runtime 분리 (별도 옵션)
  compiler: {
    emotion: true,
  },
});
```

`jsxImportSource` 는 `BuildOptions` 의 동명 옵션입니다. `compiler.emotion` 과 직교 — JSX runtime 설정은 emotion 옵션 안에 두지 마세요.

### 옵션 풀 셋

```ts
defineConfig({
  compiler: {
    emotion: {
      autoLabel: "dev-only",   // "always" | "dev-only" | "never" | boolean (default: "dev-only")
      labelFormat: "[local]",  // tokens: [local] / [filename] / [dirname] (default: "[local]")
      sourceMap: true,         // 인라인 sourceMap (default: true)
      importMap: {
        // fork / vendored emotion 사용 시 import alias
        "@my-org/styled": {
          styled: { canonicalImport: ["@emotion/styled", "default"] },
        },
        "@my-org/css": {
          css: { canonicalImport: ["@emotion/react", "css"] },
        },
      },
    },
  },
});
```

### 동작 예시

```tsx
// 입력
import { css } from "@emotion/react";
const headerStyles = css`color: red;`;
```

```tsx
// 출력 (development, autoLabel: "dev-only", labelFormat: "[local]")
const headerStyles = /*#__PURE__*/ css`color: red;label:headerStyles;`;
```

`labelFormat` 에 `[filename]` / `[dirname]` 토큰을 쓰면 라벨에 파일/디렉토리명을 함께 새깁니다.

## Reanimated worklets

`react-native-worklets/plugin` 대응. `platform: "react-native"` 면 **자동 활성**되므로 RN 프로젝트에서는 추가 설정이 거의 필요 없습니다.

### 자동 활성

```ts
defineConfig({
  platform: "react-native",
  // workletTransform: true 이미 켜진 상태
});
```

### `"worklet"` 디렉티브

```ts
import { useAnimatedStyle, useSharedValue } from "react-native-reanimated";

function Card() {
  const offset = useSharedValue(0);
  const style = useAnimatedStyle(() => {
    "worklet";
    return { transform: [{ translateX: offset.value }] };
  });
  // ...
}
```

`"worklet"` 디렉티브가 있는 함수에는 자동으로 다음 메타데이터가 주입됩니다.

- `__workletHash` — 함수 본문의 결정론적 해시
- `__closure` — 캡처된 식별자 객체
- `__initData` — `{ code, location, sourceMap, version }` (UI runtime injection 용)

### 옵션

```ts
defineConfig({
  platform: "react-native",
  workletTransform: true,             // RN 에서 자동, 수동 강제 시 true
  workletPluginVersion: "0.2.4",      // package.json 의 react-native-worklets 버전과 일치
});
```

`workletPluginVersion` 은 사용 중인 `react-native-worklets` 패키지 버전과 일치시키세요. 불일치 시 UI runtime 이 `__pluginVersion mismatch` 런타임 에러를 발생시킵니다.

### 어떤 함수가 worklet 으로 인식되는가

- `"worklet"` 디렉티브가 첫 문장인 함수 (function declaration / arrow / method)
- `useAnimatedStyle`, `useAnimatedScrollHandler`, `useAnimatedGestureHandler` 등 Reanimated 의 worklet-only hook 콜백
  - hook 이름 매칭이 아니라 RN preset 의 builtin 플러그인이 디렉티브 자동 주입을 수행

### 플랫폼 외에서 강제 활성

`platform: "react-native"` 가 아닌 환경에서 worklet 을 쓰는 케이스 (스토리북, 노드 테스트, web target Reanimated) 는 다음과 같이 켭니다.

```ts
defineConfig({
  platform: "browser",
  workletTransform: true,
  workletPluginVersion: "0.2.4",
});
```

## Flow

`@babel/preset-flow` 의 ZNTC 대응. 타입 어노테이션을 **파싱 단계에서 직접 처리** 하므로 별도 strip 단계가 없습니다.

### 자동 활성 조건 (우선순위: pragma > 확장자 > config)

```ts
// @flow
const x: number = 1;          // pragma 자동 감지
```

```ts
// types.js.flow             // 확장자 자동 감지
export type User = { id: number };
```

```ts
defineConfig({
  flow: true,                 // 명시적 활성
});

// platform: "react-native" 이면 자동으로 flow: true
```

### 지원 구문 (전체 목록)

- 기본 타입 / nullable / `mixed` / `empty` / 제네릭
- Union / Intersection / Type alias / Opaque type
- Interface / Variance (`+T` / `-T`) / Exact object (`{| ... |}`)
- Import/Export type / `import typeof` / `export type *`
- Declare class / function / var / module / export
- Type cast `(value: T)` / `as T`
- Predicate function `%checks`
- Inline / block comment 타입 (`/*: T */`, `/*:: type X = ... */`)

자세한 동작과 검증 매트릭스는 [Flow 지원](/zntc/guides/flow-support/) 참고.

### React Native 와 함께

```ts
defineConfig({
  platform: "react-native",   // flow: true 자동, RN core (410개 @flow 파일) 회귀 통과
});
```

`react-native` 0.74 의 모든 `@flow` 파일에 대해 회귀 테스트가 영구 보존됩니다.

## 한 번에 모두 켜기

RN + styled-components + emotion + Reanimated 를 모두 쓰는 프로젝트는 다음 한 블록으로 끝납니다.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  platform: "react-native",      // flow / worklets / RN preset 자동
  jsxImportSource: "@emotion/react",
  compiler: {
    styledComponents: true,
    emotion: {
      autoLabel: "dev-only",
      labelFormat: "[local]",
    },
  },
});
```

대응하는 Babel 설정은 보통 다음과 같습니다 — 전체가 ZNTC 한 패스로 흡수됩니다.

```js
// babel.config.js (대체됨)
module.exports = {
  presets: ["module:@react-native/babel-preset"],
  plugins: [
    "@babel/plugin-transform-flow-strip-types",
    "react-native-worklets/plugin",
    ["babel-plugin-styled-components", { ssr: true, displayName: true }],
    ["@emotion/babel-plugin", { autoLabel: "dev-only", labelFormat: "[local]" }],
  ],
};
```

## 함께 보기

- [Babel → ZNTC 이관 가이드](/zntc/guides/babel-migration/) — 기존 Babel 설정에서 옮겨오는 단계별 절차 + Babel bridge 사용법
- [React Native 가이드](/zntc/guides/react-native/) — RN dev server / asset / blockList / Hermes
- [Flow 지원](/zntc/guides/flow-support/) — 지원 구문 전체 목록 / Metro 호환 / 검증
- [설정 파일](/zntc/guides/config-file/) — `defineConfig`, 우선순위, 함수형 config
