---
title: Plugin Recipes
description: A collection of commonly used ZTS plugin examples.
---

Ready-to-use plugin examples for real-world scenarios. All plugins are written in `zts.config.ts` and used with `--plugin zts.config.ts`.

## CSS — Lightning CSS

Transpile and bundle CSS with [Lightning CSS](https://lightningcss.dev/). Supports CSS Modules, vendor prefixes, and nesting syntax.

```bash
npm install lightningcss
```

```typescript
// zts.config.ts
import { defineConfig } from "@zts/core";
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
zts --bundle src/index.ts --plugin zts.config.ts -o dist/bundle.js
```

## CSS Modules

Process CSS Modules with Lightning CSS to hash class names.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/core";
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

Process Tailwind CSS via PostCSS.

```bash
npm install postcss tailwindcss @tailwindcss/postcss
```

```typescript
// zts.config.ts
import { defineConfig } from "@zts/core";
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
// zts.config.ts
import { defineConfig } from "@zts/core";
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
// zts.config.ts
import { defineConfig } from "@zts/core";
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
// zts.config.ts
import { defineConfig } from "@zts/core";
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
// zts.config.ts
import { defineConfig } from "@zts/core";
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
// zts.config.ts
import { defineConfig } from "@zts/core";

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
