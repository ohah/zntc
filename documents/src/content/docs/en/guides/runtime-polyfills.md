---
title: Runtime Polyfills (core-js)
description: ZNTC's core-js runtime API polyfills — auto/usage/entry modes, --runtime-polyfills / --runtime-target / --core-js, the runtimePolyfills config object, and the @babel/preset-env useBuiltIns mapping.
---

`--target` (or `browserslist`) lowers **syntax** — arrow functions → function expressions, `async`/`await` → state machines, class fields, etc. But `Promise`, `Map`, `Set`, `Object.values`, `String.prototype.replaceAll`, `Array.prototype.at`, `Object.hasOwn`, `structuredClone` and friends are **runtime APIs** — older engines simply don't have those functions/objects, so syntax transforms alone can't help. `--runtime-polyfills` fills that gap (the same job as `@babel/preset-env`'s `useBuiltIns` + `core-js`).

## Usage

`core-js` and `core-js-compat` are optional dependencies — install them only in projects that turn polyfills on.

```bash
bun add core-js core-js-compat   # or npm i core-js core-js-compat
```

```bash
zntc --bundle entry.ts -o bundle.js \
  --target=es5 \
  --runtime-polyfills=auto \
  --runtime-target="ios_saf 12" \
  --core-js=3.49
```

Of the APIs detected in the bundle graph, ZNTC picks the ones `--runtime-target` doesn't support and injects the required `core-js/modules/*.js` as a prelude that runs **before** the user entry.

| CLI flag | Description |
|---|---|
| `--runtime-polyfills=off\|auto\|usage\|entry` | Polyfill injection mode (default `off`) |
| `--runtime-target=<query>` | Browserslist query passed to `core-js-compat`. Repeatable (`--runtime-target="ios_saf 12" --runtime-target="safari 12"`) |
| `--core-js=<version>` | core-js version used by `core-js-compat`. Defaults to the installed `core-js/package.json` version |

## Modes

| Mode | Behavior | `@babel/preset-env` equivalent |
|---|---|---|
| `off` | Default. Loads neither `core-js-compat` nor the graph collector | `useBuiltIns: false` |
| `auto` | Inject only the `core-js` modules for APIs **actually used** in the bundle graph that the target doesn't support | `useBuiltIns: "usage"` |
| `usage` | Alias of `auto` | `useBuiltIns: "usage"` |
| `entry` | Inject **all** `core-js` ES/Web modules the target needs, used or not, as an entry prelude | `useBuiltIns: "entry"` (but ZNTC needs no `import "core-js"` in your entry — the flag is enough) |

`auto`/`usage` operate on the **native graph AST** — after resolve, package exports, alias, and plugin load/transform — not a Babel pre-scan in the JS wrapper. Code inside dependencies is in scope, and with code splitting enabled the runtime prelude is still pulled in as a graph root so it runs before the user entry.

Detection is static AST-based, so it (a) excludes globals shadowed by a local binding/import and (b) does not infer dynamic computed access like `obj["replaceAll"]()`. Force-inject such cases via `include`, or use `entry` mode.

## Config object (`runtimePolyfills`)

The config file / JS API gives you fine-grained control via an object.

```ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["src/index.ts"],
  bundle: true,
  target: "es5",
  runtimePolyfills: {
    mode: "auto",
    targets: ["safari 12", "ios_saf 12"],
    coreJs: "3.49",
    include: ["es.array.at"],
    exclude: ["web.url"],
  },
});
```

| Field | Type | Description |
|---|---|---|
| `mode` | `"auto" \| "usage" \| "entry"` | See the modes table above |
| `provider` | `"core-js"` | Only `core-js` for now |
| `targets` | `string \| string[]` | Browserslist query for `core-js-compat` (same format as Rspack/SWC `env.targets`) |
| `coreJs` | `string` | core-js version hint. Defaults to the installed version |
| `include` | `string[]` | Modules to always inject. `es.array.at` or `core-js/modules/es.array.at.js` form |
| `exclude` | `string[]` | Modules to drop after target/usage resolution |
| `proposals` | `boolean` | Include proposals in the `core-js-compat` query |

`runtimePolyfills: "auto"` (a string) is shorthand for `{ mode: "auto" }`.

`targets` queries are plain Browserslist syntax — write `ios_saf 12`, `safari 12`, `node 18` explicitly; don't use compact shorthand like `ios12` / `node18` or physical device names like `"iPhone 8"`. React Native's default Hermes target is selected automatically by `--platform=react-native`, so `--runtime-target` is optional there.

```ts
runtimePolyfills: {
  mode: "auto",
  targets: ["chrome >= 87", "edge >= 88", "firefox >= 78", "safari >= 14"],
}
```

## Execution order

The runtime polyfill prelude slots between the existing manual polyfills / entry hook.

```text
manual polyfills (`polyfills`) / inject roots  →  runtime core-js prelude  →  `runBeforeMain`  →  user entry
```

- `polyfills` — modules that run immediately at bundle start (always before app code).
- `runBeforeMain` — modules that run right before the entry (environment setup — e.g. RN's `InitializeCore`). Included in the bundle graph and emitted as a prelude, **after** the runtime polyfill, **before** the user entry.

```ts
defineConfig({
  runBeforeMain: ["./src/setup-env.ts"],
});
```

## Debugging

```bash
ZNTC_DEBUG=runtime_polyfills zntc --bundle entry.ts \
  --runtime-polyfills=auto \
  --runtime-target="safari 12" \
  --profile=graph --profile-level=detailed --profile-format=json
```

The `runtime_polyfills` debug category prints the candidate computation / graph usage tally / final injection list, and `--profile=graph` shows graph-phase timing.

## See also

- [Bundler overview — ES target](/zntc/en/guides/bundling/#es-target) — syntax downleveling via `--target` / `browserslist`
- [Babel Migration (RN)](/zntc/en/guides/babel-migration/) — porting `@babel/preset-env` + `core-js` config to ZNTC
- [Transpile Options — `runtimePolyfills`](/zntc/en/reference/options/) / [CLI Reference](/zntc/en/reference/cli/)
