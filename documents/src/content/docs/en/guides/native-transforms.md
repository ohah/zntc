---
title: Native Transforms (No Babel)
description: styled-components / emotion / Reanimated worklets / Flow — 1st-party transforms that ZNTC handles directly without Babel plugins.
---

Transformations that other bundlers ship as separate Babel plugins or presets are **built into ZNTC**. Flipping an option is enough — no `@babel/core` dependency, no plugin registration, no pre-compile step.

This page covers the four 1st-party transforms.

- [styled-components](#styled-components) — `compiler.styledComponents`
- [emotion](#emotion) — `compiler.emotion`
- [Reanimated worklets](#reanimated-worklets) — automatic `"worklet"` directive transform
- [Flow](#flow) — type annotation stripping

> esbuild / rolldown / rspack each need a separate Babel step or transform plugin to do these. ZNTC handles them in the same single pass.

## styled-components

Equivalent to `babel-plugin-styled-components`. Enabling `compiler.styledComponents` is enough to get the same output (`displayName`, deterministic `componentId`, SSR hydration mismatch prevention) without registering a plugin.

### Enable

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  compiler: {
    styledComponents: true,   // all defaults on
  },
});
```

### Full options

```ts
defineConfig({
  compiler: {
    styledComponents: {
      displayName: true,               // devtools labels (default: NODE_ENV !== "production")
      ssr: true,                       // deterministic componentId hash (default: true)
      fileName: true,                  // include filename in componentId (default: true)
      minify: true,                    // strip CSS whitespace (default: true)
      transpileTemplateLiterals: true, // recognise down-leveled templates (default: true)
      pure: false,                     // hint that styled.X has no side effects
      namespace: "my-app",             // displayName/componentId namespace prefix
      topLevelImportPaths: ["@my-org/styled"], // recognise vendored forks
      cssProp: false,                  // hoist `<div css={...}>` into a module-level styled component
    },
  },
});
```

### Example

```tsx
// in
import styled from "styled-components";
const Button = styled.button`color: red;`;
```

```tsx
// out (development)
const Button = styled.button.withConfig({
  displayName: "Button",
  componentId: "sc-1a2b3c4d-0",
})`color: red;`;
```

With `fileName: true`, `displayName` becomes `app__Button` — useful when the same name appears in multiple files.

## emotion

Equivalent to `@emotion/babel-plugin`. Includes auto-labeling, inline source maps, and `importMap` for vendored forks.

### Enable

```ts
defineConfig({
  jsxImportSource: "@emotion/react",   // JSX runtime (separate option)
  compiler: {
    emotion: true,
  },
});
```

`jsxImportSource` is a top-level `BuildOptions` field. It is orthogonal to `compiler.emotion` — do not put the JSX runtime under the emotion block.

### Full options

```ts
defineConfig({
  compiler: {
    emotion: {
      autoLabel: "dev-only",   // "always" | "dev-only" | "never" | boolean (default: "dev-only")
      labelFormat: "[local]",  // tokens: [local] / [filename] / [dirname] (default: "[local]")
      sourceMap: true,         // inline source map (default: true)
      importMap: {
        // alias vendored / forked emotion entry points
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

### Example

```tsx
// in
import { css } from "@emotion/react";
const headerStyles = css`color: red;`;
```

```tsx
// out (development, autoLabel: "dev-only", labelFormat: "[local]")
const headerStyles = /*#__PURE__*/ css`color: red;label:headerStyles;`;
```

`labelFormat` supports `[filename]` and `[dirname]` tokens to include path info in the label.

## Reanimated worklets

Equivalent to `react-native-worklets/plugin`. **Automatically enabled** when `platform: "react-native"` — RN projects almost never need extra setup.

### Auto-enabled

```ts
defineConfig({
  platform: "react-native",
  // workletTransform: true already on
});
```

### The `"worklet"` directive

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

Functions containing the `"worklet"` directive get the following metadata injected:

- `__workletHash` — deterministic hash of the function body
- `__closure` — captured identifier object
- `__initData` — `{ code, location, sourceMap, version }` for UI runtime injection

### Options

```ts
defineConfig({
  platform: "react-native",
  workletTransform: true,             // auto-on for RN; set true to force on other platforms
  workletPluginVersion: "0.2.4",      // must match the installed react-native-worklets version
});
```

Keep `workletPluginVersion` aligned with your `react-native-worklets` package version. A mismatch triggers a `__pluginVersion mismatch` error at runtime.

### Which functions are treated as worklets

- Functions whose first statement is the `"worklet"` directive (function declarations, arrow functions, methods)
- Reanimated worklet-only hook callbacks (`useAnimatedStyle`, `useAnimatedScrollHandler`, `useAnimatedGestureHandler`, …)
  - The RN preset injects the directive automatically — not via hook-name matching

### Forcing it on outside React Native

For environments using Reanimated outside of `platform: "react-native"` — Storybook, Node tests, web-target Reanimated — flip it on explicitly:

```ts
defineConfig({
  platform: "browser",
  workletTransform: true,
  workletPluginVersion: "0.2.4",
});
```

## Flow

ZNTC's answer to `@babel/preset-flow`. Type annotations are **handled in the parser** — there is no separate strip pass.

### Enable (priority: pragma > extension > config)

```ts
// @flow
const x: number = 1;          // pragma auto-detect
```

```ts
// types.js.flow             // extension auto-detect
export type User = { id: number };
```

```ts
defineConfig({
  flow: true,                 // explicit
});

// platform: "react-native" implies flow: true
```

### Supported syntax (full list)

- Primitive types / nullable / `mixed` / `empty` / generics
- Union / Intersection / Type alias / Opaque type
- Interface / Variance (`+T` / `-T`) / Exact object (`{| ... |}`)
- Import/Export type / `import typeof` / `export type *`
- Declare class / function / var / module / export
- Type cast `(value: T)` / `as T`
- Predicate function `%checks`
- Inline / block comment types (`/*: T */`, `/*:: type X = ... */`)

See [Flow Support](/zntc/en/guides/flow-support/) for the detailed behavior and verification matrix.

### With React Native

```ts
defineConfig({
  platform: "react-native",   // flow: true auto; passes all 410 @flow files in react-native 0.74
});
```

A regression test pins all `@flow` files from `react-native` 0.74.

## All at once

A project that uses RN + styled-components + emotion + Reanimated reduces to a single block.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  platform: "react-native",      // flow / worklets / RN preset all auto
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

The corresponding Babel setup typically looks like the below — all of it is absorbed into a single ZNTC pass.

```js
// babel.config.js (replaced)
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

## See also

- [Babel → ZNTC migration](/zntc/en/guides/babel-migration/) — step-by-step migration + Babel bridge for custom plugins
- [React Native guide](/zntc/en/guides/react-native/) — RN dev server / assets / blockList / Hermes
- [Flow Support](/zntc/en/guides/flow-support/) — full syntax list / Metro compat / verification
- [Config File](/zntc/en/guides/config-file/) — `defineConfig`, priority, functional config
