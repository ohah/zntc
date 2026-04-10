---
title: 플러그인 레시피
description: 자주 사용되는 ZTS 플러그인 예제 모음입니다.
---

실전에서 바로 사용할 수 있는 플러그인 예제입니다. 모든 플러그인은 `zts.config.ts`에 작성하고 `--plugin zts.config.ts`로 사용합니다.

## CSS — Lightning CSS

[Lightning CSS](https://lightningcss.dev/)로 CSS를 트랜스파일하고 번들합니다. CSS Modules, 벤더 프리픽스, 중첩 문법을 지원합니다.

```bash
npm install lightningcss
```

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";
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
        // CSS를 JS 모듈로 변환 — style 태그 삽입
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

CSS Modules를 Lightning CSS로 처리하여 클래스 이름을 해싱합니다.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";
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
        // 클래스 이름 매핑 객체 생성
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
// 사용법
import styles from './Button.module.css';
const el = document.createElement('div');
el.className = styles.container; // → 해싱된 클래스명
```

## PostCSS + Tailwind CSS

PostCSS로 Tailwind CSS를 처리합니다.

```bash
npm install postcss tailwindcss @tailwindcss/postcss
```

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";
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

## SVG → React 컴포넌트

SVG 파일을 React 컴포넌트로 변환합니다.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";
import { readFileSync } from "fs";

export default defineConfig({
  plugins: [
    {
      name: "svg-react",
      load(id) {
        if (!id.endsWith(".svg")) return null;
        const svg = readFileSync(id, "utf8");
        // SVG를 React 컴포넌트로 변환
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
// 사용법
import Logo from './logo.svg';
const App = () => <Logo width={32} height={32} />;
```

## YAML 로더

YAML 파일을 JSON으로 변환하여 import합니다.

```bash
npm install yaml
```

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";
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

## GraphQL 로더

`.graphql` / `.gql` 파일을 문자열로 import합니다.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";
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

## 환경 변수 (dotenv)

`.env` 파일의 값을 빌드 타임에 주입합니다.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";
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

## Virtual Module

런타임 정보를 virtual module로 주입합니다.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";

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
// 사용법
import { buildTime, gitHash } from "virtual:build-info";
console.log(`Built at ${buildTime} (${gitHash})`);
```
