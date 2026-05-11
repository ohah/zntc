---
title: Transpile
description: A detailed guide to ZNTC transpilation features.
---

## Basic Usage

```bash
zntc input.ts              # Output to stdout
zntc input.ts -o output.js # Output to file
zntc src/ --outdir dist/   # Recursive directory transpile
echo "const x: number = 1" | zntc -  # stdin input
```

## Supported Transforms

### TypeScript

- Type annotation removal
- Interface/type declaration removal
- Enum to object + IIFE conversion
- Namespace conversion
- `as` / `satisfies` expressions

### JSX

```bash
# Classic (React.createElement)
zntc --jsx=classic app.tsx

# Automatic (react/jsx-runtime)
zntc --jsx=automatic app.tsx

# Development mode (jsxDEV + source info)
zntc --jsx=automatic-dev app.tsx

# Custom factory
zntc --jsx-factory=h --jsx-fragment=Fragment app.tsx
```

### Decorators

```bash
# Legacy (experimentalDecorators)
zntc --experimental-decorators app.ts

# Move class fields to constructor
zntc --use-define-for-class-fields=false app.ts
```

### Flow

```bash
# Automatic @flow pragma detection
zntc --flow app.js
```

### Import attributes (ES2024)

`with { type: "json" }` is preserved as a round-trip across every import/export form.
Legacy `assert` on static imports is auto-migrated to `with` (Node 20+ deprecates `assert`).

```ts
// static
import data from "./data.json" with { type: "json" };

// dynamic — the second argument is preserved too
const mod = await import("./data.json", { with: { type: "json" } });

// re-export
export { default as data } from "./data.json" with { type: "json" };
export * from "./data.json" with { type: "json" };
export * as ns from "./data.json" with { type: "json" };
```

> Local JSON imports are already inlined during bundling based on extension. `with { type }` matters when the bundle output runs on Node as ESM, or when emitting sources that require spec-compliant JSON module syntax.
>
> **Behavior**: `with { type }` is round-trip metadata. Loader selection is purely **extension-based** — attrs will not force a loader (`.txt` → JSON) nor error on unknown type values.

## Output Options

### Module Format

```bash
zntc --format=esm app.ts   # ESM (default)
zntc --format=cjs app.ts   # CommonJS
zntc --format=iife app.ts  # Immediately Invoked Function Expression
zntc --format=umd app.ts   # UMD (browser + Node)
zntc --format=amd app.ts   # AMD (RequireJS)
```

### ES Target / Engine Target

```bash
# ES version target — es2015 ~ esnext
zntc --target=es2020 app.ts

# Engine version target — feature-level downleveling
zntc --target=chrome80,safari14 app.ts
zntc --target=node18 app.ts
zntc --target=hermes0.70 app.ts   # React Native (Hermes)
```

Engine targets only emit the transformations required by each engine's compatibility table.

### Minify

```bash
zntc --minify app.ts  # All three

# Granular (esbuild-compatible)
zntc --minify-whitespace app.ts    # Whitespace/semicolons/newlines (debuggable)
zntc --minify-syntax app.ts        # true→!0, paren removal, constant folding, drop unreferenced class expression names
zntc --minify-identifiers app.ts   # Shorten local identifiers
```

Combine flags freely — e.g. enable only `--minify-whitespace` for dev builds to get a debuggable, smaller output.

### Source Maps

```bash
zntc --sourcemap app.ts -o app.js
# Generates app.js + app.js.map
```

### Quote Style

```bash
zntc --quotes=single app.ts   # Single quotes
zntc --quotes=double app.ts   # Double quotes (default)
zntc --quotes=preserve app.ts # Preserve original
```

### ASCII Only

```bash
zntc --ascii-only app.ts  # Escape non-ASCII to \uXXXX
```

## Define

```bash
zntc --define:DEBUG=false --define:VERSION='"1.0.0"' app.ts
```

Values must be **JavaScript literals**. Watch out for missing quotes.

```bash
# ✗ Wrong — admin becomes an identifier, producing unintended code
zntc --define:USERNAME=admin app.ts

# ✓ Right — quote it so it becomes a string literal
zntc --define:USERNAME='"admin"' app.ts

# ✓ Numbers / booleans / null are literals as-is
zntc --define:DEBUG=false --define:MAX=100 --define:USER=null app.ts

# ✓ Object / array work too if they're valid JSON literals
zntc --define:ENV='{"mode":"prod"}' app.ts
```

Shell quoting gotcha: in bash/zsh you need to wrap the double quotes in single quotes to keep them.

## Drop

Three independent removal options that can be combined.

```bash
# Remove console.* calls
zntc --drop=console app.ts

# Remove debugger statements
zntc --drop=debugger app.ts

# Remove labeled blocks entirely — comma-separated labels
zntc --drop-labels=DEV,TEST app.ts

# All three at once
zntc --drop=console --drop=debugger --drop-labels=DEV,TEST app.ts
```

`--drop-labels` example:

```ts
// Source
DEV: {
  console.log("debug only");
  attachDevtools();
}

// --drop-labels=DEV → the whole block disappears in the output
```

Wrap dev-only debug code in a label and you can strip it all in one switch for production builds.
