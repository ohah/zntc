---
title: Web (standalone)
description: Start a new web project with ZNTC alone — no Vite or Rspack.
---

`zntc-init web` scaffolds a new web project that runs on ZNTC alone, into an empty directory. Unlike the Vite / Rspack overlay modes, it generates a full starter template from scratch.

## Command

```bash
# React starter (default)
npx @zntc/init web --framework=react

# Vanilla TS starter
npx @zntc/init web --framework=vanilla
```

Options:

| Option                          | Description                                                       |
| ------------------------------- | ----------------------------------------------------------------- |
| `--name <pkg-name>`             | `package.json`'s `name` field. Defaults to the directory name.    |
| `--framework <react\|vanilla>`  | Starter template. Defaults to `react`.                            |
| `--root <dir>`                  | Project root. Defaults to cwd.                                    |
| `--zntc-version <range>`        | Version range for `@zntc/*` packages. Defaults to `latest`.       |
| `--force`                       | Overwrite existing files.                                         |

## Generated files

### React template

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

Generated `zntc.config.ts`:

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

### Vanilla template

```text
my-app/
├── index.html              # <div id="app"> + <script type="module" src="/src/main.ts">
├── package.json            # @zntc/core + typescript only
├── tsconfig.json           # strict, isolatedModules — no JSX
├── zntc.config.ts          # entryPoints: ["src/main.ts"]
└── src/
    └── main.ts
```

## Dev commands

The generated `package.json` scripts:

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
# use the package manager hint printed by init (bun / npm / pnpm / yarn)
bun install
bun run dev          # ZNTC dev server (HMR)
bun run build        # production bundle into dist/
bun run preview      # preview dist/
```

Images, fonts, and media imported from `src/` — or referenced from CSS `url()` —
are hashed into `dist/` with no loader configuration needed, and anything at or
below 4 KB is inlined as a `data:` URL. To override the defaults, `zntc dev` /
`zntc build` accept `--loader:.ext=type`, `--asset-names`, and
`--asset-inline-limit`. See [Bundling — Assets](/zntc/en/guides/bundling/#assets).

## When to use web mode

| Situation                                              | Recommended mode                                              |
| ------------------------------------------------------ | ------------------------------------------------------------- |
| Starting from scratch (no tooling chosen yet)          | **`zntc-init web`** — ZNTC only.                              |
| Existing Vite project                                  | [`zntc-init vite`](/zntc/en/guides/vite/)                     |
| Existing Rspack / Webpack project                      | [`zntc-init rspack`](/zntc/en/guides/rspack/)                 |
| Existing React Native CLI project                      | [`zntc-init react-native`](/zntc/en/guides/react-native/)     |

## See also

- [Dev Server](/zntc/en/guides/dev-server/) — `zntc dev` SSE / Live Reload behavior.
- [Config File](/zntc/en/guides/config-file/) — full `zntc.config.ts` options and functional config.
- [Plugin Recipes](/zntc/en/guides/plugin-recipes/) — CSS / PostCSS / Tailwind / SVG plugin patterns.
