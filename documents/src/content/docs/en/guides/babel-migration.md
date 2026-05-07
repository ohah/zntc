---
title: Babel → ZNTC Migration Guide
description: How to map each plugin/preset when migrating a Metro babel.config.js to ZNTC.
---

A guide to mapping each plugin/preset when migrating a Metro-based `babel.config.js` to ZNTC.

## Mapping table

| Babel config | ZNTC equivalent | Note |
|---|---|---|
| `@react-native/babel-preset` | `platform: "react-native"` | JSX/Flow/class props automatic |
| `@babel/preset-env` | `target: "es2020"` etc. | engine targets also supported (`chrome80` etc.) |
| `@babel/plugin-transform-flow-strip-types` | `flow: true` or RN preset | `.js.flow`/`@flow` pragma automatic |
| `@babel/plugin-proposal-decorators { legacy }` | `experimentalDecorators: true` | Stage 3 also supported |
| `@babel/plugin-transform-class-properties { loose }` | `useDefineForClassFields: false` | Synced with tsconfig |
| `@babel/plugin-transform-private-methods { loose }` | target-based auto-downlevel | No separate option needed |
| `@babel/plugin-proposal-optional-chaining` | target-based auto-downlevel | Built into ES2020 |
| `babel-plugin-root-import` | `alias: { "~/": "./src" }` | tsconfig `paths` also works |
| `react-native-worklets/plugin` | Built-in worklet plugin | Auto with `platform: "react-native"` |
| `babel-plugin-lodash` | `moduleSpecifierMap: { lodash: "lodash/{name}" }` | Cherry-pick split. `alias: { lodash: "lodash-es" }` also works (uses ESM tree-shaking) |
| `babel-plugin-styled-components` | `compiler.styledComponents` | 1st-party transform (see below) |
| `@emotion/babel-plugin` | `compiler.emotion` | 1st-party transform (see below) |
| `transform-remove-console` | `drop: ["console"]` | |
| `transform-react-remove-prop-types` | `pure: ["PropTypes.*"]` + DCE | Unnecessary with React 19+ |
| Custom Babel plugins | **Babel bridge** (see below) | Or port to ZNTC plugin |

## Basic migration example

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

### After — `zntc.config.ts`

```ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  platform: "react-native",
  target: "es2020",
  alias: { "~/": "./src" },
  experimentalDecorators: true,
  useDefineForClassFields: false,
  drop: process.env.NODE_ENV === "production" ? ["console"] : [],
});
```

The plugin array goes to zero. RN preset + worklet + Flow are all included in `platform: "react-native"`.

### When RegExp matching is needed — `alias` array form

The default object form supports only exact + prefix matching. If you need regex (like `babel-plugin-module-resolver` `regExp`), use the array form (compatible with Vite `resolve.alias`).

```ts
defineConfig({
  alias: [
    { find: /^@\/(.*)$/, replacement: "./src/$1" },
    { find: /^~components\/(.*)$/, replacement: "./src/components/$1" },
  ],
});
```

The first matching entry wins. `find` as a string is prefix matching; as a RegExp the host runtime matches and substitutes via `replacement`.

Caveat: the array form is `build()` (async) only. `buildSync()` cannot delegate RegExp matching through plugin hooks — use `Record<string, string>` object form, or switch to `build()`.

## styled-components — `compiler.styledComponents`

ZNTC 1st-party equivalent of `babel-plugin-styled-components`. No plugin registration — just enable the option.

```ts
defineConfig({
  compiler: {
    styledComponents: {
      displayName: true,             // devtools labels (default: NODE_ENV !== "production")
      ssr: true,                     // deterministic componentId hash (default: true)
      fileName: true,                // include filename in componentId (default: true)
      minify: true,                  // CSS whitespace minify (default: true)
      transpileTemplateLiterals: true, // recognize downleveled templates (default: true)
      pure: false,                   // hint that styled.X is side-effect free (default: false)
      namespace: "my-app",           // displayName/componentId namespace prefix
      topLevelImportPaths: ["@my-org/styled"], // recognize vendored forks
      cssProp: false,                // extract `<div css={...}>` into a module-level styled component (default: false)
    },
  },
});
```

`compiler.styledComponents: true` enables defaults in one shot.

## emotion — `compiler.emotion`

ZNTC 1st-party equivalent of `@emotion/babel-plugin`.

```ts
defineConfig({
  compiler: {
    emotion: {
      autoLabel: "dev-only",   // "always" | "dev-only" | "never" | boolean (default: "dev-only")
      labelFormat: "[local]",  // tokens: [local] / [filename] / [dirname] (default: "[local]")
      sourceMap: true,          // emit sourceMap (default: true)
      importMap: {              // import alias for forks / vendored emotion
        "@my-org/styled": {
          styled: { canonicalImport: ["@emotion/styled", "default"] },
        },
      },
    },
  },
});
```

`jsxImportSource` is set as a separate top-level `BuildOptions` field (e.g. `jsxImportSource: "@emotion/react"`).

## Babel bridge — reusing custom Babel plugins

For custom Babel plugins that can't be replaced by built-ins (e.g. in-house presets, testID auto-injection, AppRegistry wrapping), you can **run Babel entirely inside the transform hook** to reuse them.

### Install

```bash
bun add -D @babel/core
```

### `zntc.config.ts`

```ts
import { defineConfig } from "@zntc/core";
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
              // add other custom Babel plugins here
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

**Key points**:
- `babelrc: false, configFile: false` — explicitly prevents reading the project's `babel.config.js` recursively. Avoids double transformation with ZNTC config.
- `filter` — only required file patterns. To skip `node_modules`, add `!/node_modules/.test(id)` to the filter function.
- `sourceMaps: true` — chains source maps. ZNTC merges them in a later step.
- Return format: `{ code, map? }`. Returning `null` falls back to the default ZNTC pipeline.

### Performance considerations

Running Babel for every module **slows down dev server warm-up**. For production bundles, `@babel/core` calls dominate over ZNTC itself. Mitigations:

1. Narrow the `filter` so only files that actually need Babel pass through (e.g. only `src/**/*.tsx`)
2. **Port frequently used plugins** to ZNTC plugins (see below)
3. Split — use Babel bridge for dev, native ZNTC for prod

## Porting to ZNTC plugins

The Babel bridge is convenient but slow. If performance matters or you build often, rewrite with the ZNTC plugin API.

Write custom plugins directly using Rollup/Vite-style hooks (`resolveId`, `load`, `transform`):

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  plugins: [
    {
      name: "inject-testid",
      transform: {
        filter: /\.tsx?$/,
        handler(code, id) {
          // Inject testID prop into JSX elements, etc.
          // See the plugin guide for detailed AST hooks
          return null;
        },
      },
    },
  ],
});
```

See: Plugin Guide, Plugin Recipes.

## FAQ

### Q. Is `babel-plugin-lodash` really necessary?

In Metro, tree-shaking is weak, so `import { debounce } from 'lodash'` pulls in all of lodash (~70KB) → this plugin was required for cherry-picking.

ZNTC has working ESM tree-shaking, so:
- Use `lodash-es` → automatic cherry-picking (optimal)
- Keep `lodash` → one-line `alias: { lodash: "lodash-es" }` solves it
- Keep `lodash` + force path import → `moduleSpecifierMap: { lodash: "lodash/{name}" }` (only converts named specifiers without aliases; falls back to original import otherwise)
- Plugin port is unnecessary

### Q. What about `transform-react-remove-prop-types`?

React 19+ removes the PropTypes API entirely. If you're on TypeScript, you probably don't use PropTypes at all.

If you need to strip leftover PropTypes code:

```ts
pure: ["PropTypes.string", "PropTypes.number", /* ... */]
```

+ dead code elimination removes most of it. For a perfect strip, a custom plugin is still needed.

### Q. What about `env.production.plugins` (conditional plugins)?

Branch on `NODE_ENV` inside `defineConfig`:

```ts
const isProd = process.env.NODE_ENV === "production";
export default defineConfig({
  drop: isProd ? ["console", "debugger"] : [],
  plugins: isProd ? [minifyPlugin] : [],
});
```

### Q. What about Babel `overrides` (file-specific rules)?

Use `plugins[].transform.filter` to split transforms per file pattern:

```ts
plugins: [
  { name: "a", transform: { filter: /\.tsx$/, handler: ... } },
  { name: "b", transform: { filter: /\/legacy\//, handler: ... } },
]
```

## Gradual migration strategy

You don't have to rip out Babel all at once:

1. **Stage 1** — `platform: "react-native"` + alias + Babel bridge to keep all existing plugins working
2. **Stage 2** — Replace Babel plugins one by one with built-in features or ZNTC plugin ports → remove from bridge
3. **Stage 3** — Remove the bridge itself. Drop the `@babel/core` dependency.

Each stage is independently deployable.

## See also

- Plugin Guide
- Plugin Recipes
- React Native Guide
- Migration Guide (esbuild/Vite/webpack)
