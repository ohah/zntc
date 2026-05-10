---
title: Flow Support
description: ZNTC's Flow type stripping — React Native core compatibility, how to enable it, and the supported syntax list.
---

ZNTC parses and strips Facebook Flow type annotations directly. Because React Native core and many Meta libraries are written in Flow, this is effectively required for RN bundling.

## When to use it

- **React Native bundling** — RN core, `react-native`, and many `react-native-*` packages use Flow. Auto-enabled by `--platform=react-native`.
- **Meta-ecosystem libraries** — Hermes runs Flow natively, but other runtimes (Node, browsers, V8) need stripping.
- **Flow-only legacy codebases** — replaces `@babel/preset-flow`.

## How to enable it

Three mechanisms work; precedence is: pragma > extension > CLI/config.

### `// @flow` pragma auto-detection

```ts
// @flow
const x: number = 1;
```

A pragma at the top of the file switches the parser to Flow mode for that file. Mixing TypeScript syntax in the same file is then an error.

### `.js.flow` extension

```ts
// types.js.flow
export type User = { id: number; name: string };
```

The `.js.flow` extension marks a file as Flow type definitions and is parsed in Flow mode automatically (analogous to TypeScript's `.d.ts`).

### CLI / config

```bash
zntc --bundle entry.js --flow -o bundle.js
```

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  flow: true,
});
```

`--platform=react-native` turns on `flow: true` automatically.

## Supported syntax

### Basic type annotations

```ts
// @flow
const n: number = 1;
const s: ?string = null;          // nullable
const m: mixed = anything;
const arr: number[] = [1, 2, 3];
const arr2: Array<string> = ['a'];

function add(a: number, b: number): number {
  return a + b;
}
```

Supported: `string`, `number`, `boolean`, `bool`, `mixed`, `empty`, `void`, `null`, `?Type` (nullable), `T[]`, `Array<T>`.

### Generics

```ts
// @flow
function identity<T>(x: T): T { return x; }
function map<T, U>(arr: T[], fn: (x: T) => U): U[] { /* ... */ }

class Box<T> {
  value: T;
  constructor(v: T) { this.value = v; }
}
```

### Union / Intersection

```ts
// @flow
type Result = 'ok' | 'error' | 'pending';
type WithMeta<T> = T & { meta: Meta };
```

### Variance

```ts
// @flow
type ReadOnly = { +name: string };   // covariant (read-only)
type WriteOnly = { -name: string };  // contravariant (write-only)
```

### Type alias / Opaque type

```ts
// @flow
type Point = { x: number; y: number };

opaque type UserId = string;                      // string is invisible outside
opaque type Email: string = string;               // supertype constraint — string-compatible outside
```

### Interface

```ts
// @flow
interface Comparable<T> {
  compareTo(other: T): number;
}

interface Sortable extends Comparable<Sortable> {
  sort(): void;
}
```

### Import / Export type

```ts
// @flow
import type { User } from './types';
import typeof UserClass from './User';

export type Result = { ok: boolean };
export type { User } from './types';
```

### Declare

```ts
// @flow
declare class Logger { log(msg: string): void }
declare function debug(msg: string): void;
declare var __DEV__: boolean;

declare module 'some-untyped-lib' {
  declare module.exports: { foo: () => void };
}

declare export function exported(): void;
```

### Type cast

```ts
// @flow
const x = (value: string);              // parenthesized cast
const y = obj as User;                  // as cast
```

### Exact object type

```ts
// @flow
type ExactUser = {| id: number, name: string |};   // additional fields disallowed
```

### Predicate function

```ts
// @flow
function isString(x: mixed): boolean %checks {
  return typeof x === 'string';
}
```

### Comment types

```ts
// @flow
const x /*: number */ = 1;            // inline
/*::
type Internal = { secret: string };
*/
```

Used to add types while keeping JS-compatibility. ZNTC recognizes and strips both forms.

## Unsupported syntax

The following constructs are not used by Metro / RN core, so they're not yet supported. If you need any of them, please open an issue with your use case at [GitHub Issues](https://github.com/ohah/zntc/issues).

| Syntax | Introduced | Status |
|---|---|---|
| `component` declaration | Flow 2023 | unsupported |
| `hook` declaration | Flow 2023 | unsupported |
| `match` expression | Flow 2024 | unsupported |

## Validation

All `@flow` files in `react-native` 0.74 (410 files) parse and strip cleanly. Regression tests keep this guarantee permanent.

```bash
# Reproduce locally
git clone https://github.com/facebook/react-native
zntc --bundle react-native/Libraries/react-native/index.js --platform=react-native -o /tmp/rn.js
```

## Using it with React Native

`--platform=react-native` enables several things in addition to Flow.

- Platform-specific extensions tried automatically — `.ios.tsx`, `.ios.ts`, `.ios.jsx`, `.ios.js`, `.native.*`, ...
- `react-native` prepended to `main-fields`
- Hermes target (`--target=hermes0.70`) forced
- `process.env.NODE_ENV` define
- Metro-compatible block list (`__tests__/`, iOS/Android build folders)

To configure manually:

```ts
defineConfig({
  flow: true,
  platform: "react-native",
  resolveExtensions: [
    ".ios.tsx", ".ios.ts", ".ios.jsx", ".ios.js",
    ".native.tsx", ".native.ts", ".native.jsx", ".native.js",
    ".tsx", ".ts", ".jsx", ".js",
  ],
  mainFields: ["react-native", "browser", "module", "main"],
});
```

For full RN integration see the [React Native guide](/zntc/en/guides/react-native/); for porting from a Babel-based RN setup see [Babel Migration](/zntc/en/guides/babel-migration/).

## Mixing with TypeScript

Flow files and TypeScript files in the same project are supported — the mode is decided per file (pragma / extension / `--flow` fallback).

Mixing the two syntaxes within the **same file** is not supported — the TypeScript compiler has the same restriction.

## Further reading

- Contributor design doc: [`docs/FLOW.md`](https://github.com/ohah/zntc/blob/main/docs/FLOW.md) — Flow implementation decisions, Metro source analysis, prioritization of unsupported syntax
- [React Native guide](/zntc/en/guides/react-native/) — full RN integration flow
- [Babel migration](/zntc/en/guides/babel-migration/) — porting an existing Babel + Flow setup to ZNTC
