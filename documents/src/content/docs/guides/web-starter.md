---
title: Web (standalone)
description: Vite / Rspack 없이 ZNTC 만으로 새 웹 프로젝트를 시작하는 방법입니다.
---

`zntc-init web` 은 기존 도구 없이 ZNTC 만으로 동작하는 새 웹 프로젝트를 빈 디렉토리에 scaffold 합니다. Vite / Rspack 위에 얹는 overlay 모드와 달리 starter 템플릿을 통째로 생성합니다.

## 명령

```bash
# React 스타터 (기본)
npx @zntc/init web --framework=react

# Vanilla TS 스타터
npx @zntc/init web --framework=vanilla
```

옵션:

| 옵션                       | 설명                                                            |
| -------------------------- | --------------------------------------------------------------- |
| `--name <pkg-name>`        | `package.json` 의 `name` 필드. 기본값: 디렉토리 이름.            |
| `--framework <react\|vanilla>` | 스타터 템플릿. 기본값: `react`.                              |
| `--root <dir>`             | 프로젝트 루트. 기본값: 현재 디렉터리.                            |
| `--zntc-version <range>`   | `@zntc/*` 패키지 버전 범위. 기본값: `latest`.                    |
| `--force`                  | 기존 파일 덮어쓰기.                                              |

## 산출물

### React 템플릿

```text
my-app/
├── index.html              # <div id="root"> + <script type="module" src="/src/main.tsx">
├── package.json            # react@^19, react-dom@^19, @zntc/core, typescript
├── tsconfig.json           # jsx: react-jsx, strict, isolatedModules, moduleResolution: Bundler
├── zntc.config.ts          # defineConfig: entryPoints / outdir / platform=browser / target=es2022 / jsx=automatic / sourcemap
└── src/
    ├── main.tsx            # createRoot(...).render(<App />)
    └── App.tsx
```

생성된 `zntc.config.ts`:

```ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["src/main.tsx"],
  outdir: "dist",
  format: "esm",
  platform: "browser",
  target: "es2022",
  jsx: "automatic",
  sourcemap: true,
});
```

### Vanilla 템플릿

```text
my-app/
├── index.html              # <div id="app"> + <script type="module" src="/src/main.ts">
├── package.json            # @zntc/core + typescript 만
├── tsconfig.json           # strict, isolatedModules — JSX 미사용
├── zntc.config.ts          # entryPoints: ["src/main.ts"]
└── src/
    └── main.ts
```

## 개발 명령

자동 생성된 `package.json` 의 scripts:

```jsonc
{
  "scripts": {
    "dev": "zntc dev",
    "build": "zntc build",
    "preview": "zntc preview"
  }
}
```

```bash
# init 출력 힌트의 패키지 매니저 (bun / npm / pnpm / yarn) 사용
bun install
bun run dev          # ZNTC dev server (HMR)
bun run build        # 프로덕션 번들 dist/
bun run preview      # dist/ 미리보기
```

## 언제 web 모드를 쓸까

| 상황                                       | 권장 모드                                                  |
| ------------------------------------------ | ---------------------------------------------------------- |
| 새 프로젝트 시작 (도구 선택 없음)          | **`zntc-init web`** — ZNTC 만으로 동작.                     |
| 기존 Vite 프로젝트가 있음                  | [`zntc-init vite`](/zntc/guides/vite/)                      |
| 기존 Rspack / Webpack 프로젝트가 있음      | [`zntc-init rspack`](/zntc/guides/rspack/)                  |
| 기존 React Native CLI 프로젝트가 있음      | [`zntc-init react-native`](/zntc/guides/react-native/)      |

## 관련 문서

- [Dev Server](/zntc/guides/dev-server/) — `zntc dev` 의 SSE / Live Reload 동작.
- [Config File](/zntc/guides/config-file/) — `zntc.config.ts` 의 전체 옵션과 함수형 config.
- [Plugin Recipes](/zntc/guides/plugin-recipes/) — CSS / PostCSS / Tailwind / SVG 같은 자주 쓰는 plugin 패턴.
