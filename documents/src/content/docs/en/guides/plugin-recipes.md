---
title: Plugin Recipes
description: A collection of commonly used ZNTC plugin examples.
---

Ready-to-use plugin examples for real-world scenarios. All plugins are written in `zntc.config.ts` and used with `--plugin zntc.config.ts`.

## CSS — Lightning CSS

Transpile and bundle CSS with [Lightning CSS](https://lightningcss.dev/). Supports CSS Modules, vendor prefixes, and nesting syntax.

```bash
npm install lightningcss
```

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";
import { transform, bundleAsync } from "lightningcss";
import { readFileSync } from "fs";

export default defineConfig({
  plugins: [
    {
      name: "lightningcss",
      load(id) {
        if (!id.endsWith(".css")) return null;
        const code = readFileSync(id);
        const result = transform({
          filename: id,
          code,
          minify: true,
          targets: { chrome: 80 << 16 }, // chrome 80+
        });
        const css = result.code.toString();
        // Convert CSS to JS module — inject style tag
        return {
          contents: `
const style = document.createElement('style');
style.textContent = ${JSON.stringify(css)};
document.head.appendChild(style);
export default ${JSON.stringify(css)};
`,
        };
      },
    },
  ],
});
```

```bash
zntc --bundle src/index.ts --plugin zntc.config.ts -o dist/bundle.js
```

## CSS Modules

Process CSS Modules with Lightning CSS to hash class names.

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";
import { transformStyleAttribute, transform } from "lightningcss";
import { readFileSync } from "fs";

export default defineConfig({
  plugins: [
    {
      name: "css-modules",
      load(id) {
        if (!id.endsWith(".module.css")) return null;
        const code = readFileSync(id);
        const result = transform({
          filename: id,
          code,
          minify: true,
          cssModules: true,
        });
        const css = result.code.toString();
        const exports = result.exports ?? {};
        // Build class name mapping object
        const classMap = Object.fromEntries(
          Object.entries(exports).map(([k, v]) => [k, v.name])
        );
        return {
          contents: `
const style = document.createElement('style');
style.textContent = ${JSON.stringify(css)};
document.head.appendChild(style);
export default ${JSON.stringify(classMap)};
`,
        };
      },
    },
  ],
});
```

```typescript
// Usage
import styles from './Button.module.css';
const el = document.createElement('div');
el.className = styles.container; // → hashed class name
```

## PostCSS + Tailwind CSS

The `zntc dev` / `zntc build` app mode reads `postcss.config.*` automatically and
handles CSS-only HMR in the dev server. Tailwind v4 uses the
`@tailwindcss/postcss` plugin.

```bash
npm install postcss tailwindcss @tailwindcss/postcss
```

```typescript
// postcss.config.mjs
export default {
  plugins: {
    "@tailwindcss/postcss": {},
  },
};
```

```css
/* src/style.css */
@import "tailwindcss";
```

```html
<!-- index.html -->
<link rel="stylesheet" href="/src/style.css" />
<script type="module" src="/src/main.ts"></script>
```

```bash
zntc dev
zntc build
```

App-mode CSS Modules (`.module.css`) are transformed into scoped class maps
without a separate plugin. You can use the default export and valid named
exports.

For library builds that need to inject CSS from a JS plugin, run PostCSS from a
`load` hook:

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";
import postcss from "postcss";
import tailwindcss from "@tailwindcss/postcss";
import { readFileSync } from "fs";

export default defineConfig({
  plugins: [
    {
      name: "postcss-tailwind",
      async load(id) {
        if (!id.endsWith(".css")) return null;
        const css = readFileSync(id, "utf8");
        const result = await postcss([tailwindcss()]).process(css, {
          from: id,
        });
        return {
          contents: `
const style = document.createElement('style');
style.textContent = ${JSON.stringify(result.css)};
document.head.appendChild(style);
export default ${JSON.stringify(result.css)};
`,
        };
      },
    },
  ],
});
```

## SVG → React component

Convert SVG files to React components.

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";
import { readFileSync } from "fs";

export default defineConfig({
  plugins: [
    {
      name: "svg-react",
      load(id) {
        if (!id.endsWith(".svg")) return null;
        const svg = readFileSync(id, "utf8");
        // Convert SVG attributes to React props
        const component = svg
          .replace(/class=/g, "className=")
          .replace(/fill-rule=/g, "fillRule=")
          .replace(/clip-rule=/g, "clipRule=")
          .replace(/stroke-width=/g, "strokeWidth=")
          .replace(/stroke-linecap=/g, "strokeLinecap=")
          .replace(/stroke-linejoin=/g, "strokeLinejoin=");
        return {
          contents: `
export default function SvgIcon(props) {
  return ${component.replace(/<svg/, "<svg {...props}")};
}
export const src = ${JSON.stringify(svg)};
`,
        };
      },
    },
  ],
});
```

```tsx
// Usage
import Logo from './logo.svg';
const App = () => <Logo width={32} height={32} />;
```

## YAML loader

Import YAML files as parsed JSON.

```bash
npm install yaml
```

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";
import { parse } from "yaml";
import { readFileSync } from "fs";

export default defineConfig({
  plugins: [
    {
      name: "yaml",
      load(id) {
        if (!id.endsWith(".yaml") && !id.endsWith(".yml")) return null;
        const text = readFileSync(id, "utf8");
        const data = parse(text);
        return {
          contents: `export default ${JSON.stringify(data)};`,
        };
      },
    },
  ],
});
```

## GraphQL loader

Import `.graphql` / `.gql` files as strings.

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";
import { readFileSync } from "fs";

export default defineConfig({
  plugins: [
    {
      name: "graphql",
      load(id) {
        if (!id.endsWith(".graphql") && !id.endsWith(".gql")) return null;
        const query = readFileSync(id, "utf8");
        return {
          contents: `export default ${JSON.stringify(query)};`,
        };
      },
    },
  ],
});
```

## Environment variables (dotenv)

Inject `.env` values at build time.

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";
import { readFileSync, existsSync } from "fs";

function loadEnv(path = ".env"): Record<string, string> {
  if (!existsSync(path)) return {};
  const content = readFileSync(path, "utf8");
  const env: Record<string, string> = {};
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const [key, ...rest] = trimmed.split("=");
    env[key.trim()] = rest.join("=").trim().replace(/^["']|["']$/g, "");
  }
  return env;
}

export default defineConfig({
  plugins: [
    {
      name: "dotenv",
      transform(code, id) {
        if (!id.endsWith(".ts") && !id.endsWith(".js")) return null;
        if (!code.includes("import.meta.env")) return null;
        const env = loadEnv();
        let result = code;
        for (const [key, value] of Object.entries(env)) {
          result = result.replaceAll(
            `import.meta.env.${key}`,
            JSON.stringify(value)
          );
        }
        return result;
      },
    },
  ],
});
```

## Virtual module

Inject runtime info as a virtual module.

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  plugins: [
    {
      name: "virtual-build-info",
      resolveId(source) {
        if (source === "virtual:build-info") {
          return { path: "\0virtual:build-info" };
        }
        return null;
      },
      load(id) {
        if (id === "\0virtual:build-info") {
          return {
            contents: `
export const buildTime = ${JSON.stringify(new Date().toISOString())};
export const nodeVersion = ${JSON.stringify(process.version)};
export const gitHash = ${JSON.stringify(
              require("child_process")
                .execSync("git rev-parse --short HEAD")
                .toString()
                .trim()
            )};
`,
          };
        }
        return null;
      },
    },
  ],
});
```

```typescript
// Usage
import { buildTime, gitHash } from "virtual:build-info";
console.log(`Built at ${buildTime} (${gitHash})`);
```

## Framework SFC (Vue / Svelte) — currently unsupported

Wrapping official vite plugins like `@vitejs/plugin-vue@6.x` / `@sveltejs/vite-plugin-svelte@7.x` with `vitePlugin()` makes **the plugin hooks themselves run, but the build still does not complete**. ZNTC's native resolver/loader does not yet recognise two surfaces that SFC builds rely on:

1. **Virtual module IDs** — plugin-vue returns IDs like `\0plugin-vue:export-helper`.
2. **Query-parameter sub-imports** — a single `.vue` file is split during SFC compile into sub-imports such as `App.vue?vue&type=script&setup=true&lang.ts` and `App.vue?vue&type=style&index=0&scoped=...&lang.css`. ZNTC has no logic that reads the `lang.X` query and routes to a different parser/loader.

### What happens today

```typescript
// zntc.config.ts
import { defineConfig, vitePlugin } from "@zntc/core";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  entryPoints: ["main.ts"],
  bundler: true,
  platform: "browser",
  loader: { ".vue": "js" }, // the .vue entry itself is fine
  plugins: [vitePlugin(vue())],
});
```

Building a minimal `App.vue` + `main.ts` produces:

```
✓ Plugin hooks invoked (hook object format / sourcemap object both accepted)
✗ Cannot resolve module App.vue?vue&type=style&index=0&scoped=...&lang.css
✗ Expression expected — CSS sub-module went through the JS parser
✗ TypeScript type annotations are not allowed when parsing as JavaScript
  — ?vue&type=script&setup=true&lang.ts was treated as JS
```

### Workarounds (today)

- **Pre-compiled Vue / Svelte components**: if SFCs are compiled in a separate step into plain `.js` + `.css` artifacts, ZNTC handles them as ordinary JS libraries (real benchmarks confirm `vue 1MB` and `svelte` ESM APIs bundle correctly).
- **JS APIs of Vue / Svelte themselves**: runtime imports like `createApp` / `ref` from `vue` and stores from `svelte/store` work — only single-file `.vue` / `.svelte` *compilation* is missing.
- Once the two surfaces above land in native, the plugins should work as-is. The `vitePlugin()` adapter already accepts vite 4+ hook objects and plugin sourcemap objects.

See [Bundler architecture & internals](/zntc/en/guides/bundler-deep-dive/) → Module Resolution for the underlying differences.
