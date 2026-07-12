---
title: Vite
description: Replace Vite's esbuild transform with ZNTC in an existing Vite project.
---

ZNTC slots into Vite's esbuild-transform position via `@zntc/vite-plugin`. Vite's dev server, HMR, and plugin ecosystem keep working as-is — ZNTC only handles `.ts` / `.tsx` / `.jsx` transformations.

## Project layout

```text
my-vite-app/
├── index.html
├── vite.config.ts          # registers @zntc/vite-plugin
├── src/
│   ├── main.tsx
│   └── App.tsx
└── package.json
```

## Automatic setup (`zntc-init vite`)

The fastest way to add ZNTC to a project that already depends on `vite`. If `vite` isn't installed, use `zntc-init web` for a standalone scaffold ([Web (standalone)](/zntc/en/guides/web-starter/)).

```bash
npx @zntc/init vite
```

What it does:

- Adds `@zntc/core` and `@zntc/vite-plugin` to dev dependencies.
- Writes a default `vite.config.ts` (or `.mts` / `.js` / `.mjs`) if missing.
- If a config already exists, prints manual-patch instructions. Use `--force` to overwrite.

Generated default config:

```ts
// vite.config.ts
import { defineConfig } from "vite";
import { zntc } from "@zntc/vite-plugin";

export default defineConfig({
  plugins: [zntc()],
  esbuild: false,
});
```

## Manual setup

To wire it into an existing `vite.config.ts` yourself:

```ts
import { defineConfig } from "vite";
import { zntc } from "@zntc/vite-plugin";

export default defineConfig({
  plugins: [
    zntc(), // place near the front (esbuild's old slot)
    // ...your existing plugins
  ],
  esbuild: false, // disable Vite's esbuild transform
});
```

`esbuild: false` is required — if Vite still transforms `.ts` / `.tsx` with esbuild, you'll get double-transformed output.

## Commands

Use Vite's regular CLI:

```bash
bun vite           # dev server (Vite HMR)
bun vite build     # production build
bun vite preview   # preview the build output
```

## Vite vs ZNTC's own dev server

- `bun vite` — Vite dev server + ZNTC transform. You keep Vite's HMR and plugin ecosystem.
- `zntc dev <root>` — ZNTC's standalone dev server. Vite is not involved; only the ZNTC plugin API is available (see [Dev Server](/zntc/en/guides/dev-server/)).

Pick whichever fits your project. If you already use Vite, sticking with Vite + `@zntc/vite-plugin` is the natural choice.

## Query-suffix imports

ZNTC's own bundler understands the Vite query-suffix idiom, so source that already uses it keeps building when you move a bundle or a worker setup over to `zntc --bundle` / `zntc build`:

| Suffix                      | Behavior                                                                                                       |
| --------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `?raw`                      | File contents inlined as a string                                                                              |
| `?url`                      | Emitted as an asset, URL string exported (`--asset-inline-limit` is ignored — an explicit URL request wins)     |
| `?inline`                   | Inlined as a `data:` URL, regardless of size                                                                    |
| `?worker` / `?sharedworker` | Default-exports a Worker constructor function (`new W()`), built as its own chunk                              |

```js
import txt from "./data.txt?raw";
import u from "./icon.png?url";
import W from "./x.worker.js?worker";
const w = new W();
```

Unknown queries (`./Comp.vue?vue&type=style&lang.css`) are passed through untouched, so plugins that use virtual paths keep working. See [Bundling — Query suffixes](/zntc/en/guides/bundling/#query-suffixes-raw--url--inline--worker).

## How it works

`@zntc/vite-plugin`'s `zntc()` attaches to these Vite hooks:

- `resolveId` / `load` — mirrors your ZNTC plugin's `resolveId` / `load` into Vite.
- `transform` — converts `.ts` / `.tsx` / `.jsx` / `.mts` / `.cts` / `.flow.js` through ZNTC and returns a sourcemap object (compatible with Vite 4+).
- `renderChunk` / `generateBundle` — forwards your plugin's lifecycle hooks.

If a `defineConfig({...})` is present, `zntc()` picks up its options automatically.

## Known limitations

- SFC transformations from Vite-specific plugins (e.g. `@vitejs/plugin-vue`) are out of scope for ZNTC. Keep using the SFC plugin; ZNTC only handles the `<script lang="ts">` block.
- Rollup plugins that call `this.parse()` get partial ESTree adapter coverage — see the Rollup ModuleInfo Phase C entry in the [Roadmap](/zntc/en/roadmap/).

## See also

- [Plugin Recipes](/zntc/en/guides/plugin-recipes/) — PostCSS, Tailwind, SVG, GraphQL recipes that pair with `@zntc/vite-plugin`.
- [Web (standalone)](/zntc/en/guides/web-starter/) — start fresh without Vite.
