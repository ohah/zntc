---
title: 플러그인 레시피
description: 자주 사용되는 ZNTC 플러그인 예제 모음입니다.
---

실전에서 바로 사용할 수 있는 플러그인 예제입니다. 모든 플러그인은 `zntc.config.ts`에 작성하고 `--plugin zntc.config.ts`로 사용합니다.

## CSS — Lightning CSS

[Lightning CSS](https://lightningcss.dev/)로 CSS를 트랜스파일하고 번들합니다. CSS Modules, 벤더 프리픽스, 중첩 문법을 지원합니다.

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
zntc --bundle src/index.ts --plugin zntc.config.ts -o dist/bundle.js
```

## CSS Modules

CSS Modules를 Lightning CSS로 처리하여 클래스 이름을 해싱합니다.

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

`zntc dev` / `zntc build` 앱 모드는 `postcss.config.*`를 자동으로 읽고 dev 서버에서
CSS-only HMR까지 처리합니다. Tailwind v4는 `@tailwindcss/postcss` 플러그인을
사용합니다.

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

앱 모드의 CSS Modules(`.module.css`)는 별도 플러그인 없이 scoped class map으로
변환됩니다. default export와 유효한 식별자 형태의 named export를 사용할 수 있습니다.

CSS를 JS 플러그인에서 직접 주입해야 하는 라이브러리 빌드는 다음처럼 `load` 훅에서
PostCSS를 실행할 수 있습니다.

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

## SVG → React 컴포넌트

SVG 파일을 React 컴포넌트로 변환합니다.

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

## GraphQL 로더

`.graphql` / `.gql` 파일을 문자열로 import합니다.

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

## 환경 변수 (dotenv)

`.env` 파일의 값을 빌드 타임에 주입합니다.

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

## Virtual Module

런타임 정보를 virtual module로 주입합니다.

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
// 사용법
import { buildTime, gitHash } from "virtual:build-info";
console.log(`Built at ${buildTime} (${gitHash})`);
```


## 프레임워크 SFC (Vue / Svelte) — 현재 미지원

`@vitejs/plugin-vue@6.x` / `@sveltejs/vite-plugin-svelte@7.x` 같은 공식 vite plugin 을 `vitePlugin()` 어댑터로 감싸 적용하면 **plugin hook 자체는 호출되지만 빌드는 완전히 통과하지 못한다**. ZNTC native resolver/loader 가 SFC 가 의존하는 다음 두 surface 를 아직 인식하지 않기 때문이다:

1. **Virtual module ID** — vue plugin 이 `\0plugin-vue:export-helper` 같은 가상 ID 를 반환.
2. **Query parameter sub-import** — 단일 `.vue` 파일이 SFC compile 후 `App.vue?vue&type=script&setup=true&lang.ts`, `App.vue?vue&type=style&index=0&scoped=...&lang.css` 처럼 query 가 붙은 sub-import 로 쪼개짐. ZNTC 는 query 의 `lang.X` 를 보고 parser/loader 를 분기시키는 로직이 없다.

### 현재 시도 시 동작

```typescript
// zntc.config.ts
import { defineConfig, vitePlugin } from "@zntc/core";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  entryPoints: ["main.ts"],
  bundler: true,
  platform: "browser",
  loader: { ".vue": "js" }, // .vue 진입 자체는 통과
  plugins: [vitePlugin(vue())],
});
```

minimal `App.vue` + `main.ts` 빌드 결과:

```
✓ Plugin hook 호출 성공 (hook object format / sourcemap object 지원됨)
✗ Cannot resolve module App.vue?vue&type=style&index=0&scoped=...&lang.css
✗ Expression expected — CSS sub-module 을 JS 파서가 처리
✗ TypeScript type annotations are not allowed when parsing as JavaScript
  — ?vue&type=script&setup=true&lang.ts 가 JS 로 처리됨
```

### 대안 (현재 시점)

- **컴파일된 Vue / Svelte 컴포넌트만 사용**: SFC 가 빌드 시점이 아닌 *별도 단계* 에서 미리 컴파일된 `.js` + `.css` 산출물로 바뀌어 있으면 ZNTC 는 일반 JS 라이브러리로 처리 가능 (실제 벤치 결과 `vue 1MB`, `svelte` ESM API 빌드 정상 동작).
- **Vue/Svelte 라이브러리 자체의 JS API 사용**: `vue` 의 `createApp`/`ref` 같은 런타임 import 와 `svelte/store` 같은 라이브러리는 정상 동작 — 단지 `.vue` / `.svelte` 파일 자체의 SFC 컴파일이 미지원.
- 위 두 surface (virtual module + query sub-import) 가 native 에 추가되면 plugin 그대로 동작할 예정. 현재 wrapper(`vitePlugin()`)는 이미 vite 4+ 신형 hook object 와 plugin sourcemap object 를 모두 받을 수 있다.

자세한 내부 동작 차이는 [번들러 구조와 동작 원리 → 모듈 해석 (Resolver)](/zntc/guides/bundler-deep-dive/#1-모듈-해석-resolver) 섹션 참조.
