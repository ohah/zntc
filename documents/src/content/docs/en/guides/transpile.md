---
title: Transpile
description: A detailed guide to ZTS transpilation features.
---

## Basic Usage

```bash
zts input.ts              # Output to stdout
zts input.ts -o output.js # Output to file
zts src/ --outdir dist/   # Recursive directory transpile
echo "const x: number = 1" | zts -  # stdin input
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
zts --jsx=classic app.tsx

# Automatic (react/jsx-runtime)
zts --jsx=automatic app.tsx

# Development mode (jsxDEV + source info)
zts --jsx=automatic-dev app.tsx

# Custom factory
zts --jsx-factory=h --jsx-fragment=Fragment app.tsx
```

### Decorators

```bash
# Legacy (experimentalDecorators)
zts --experimental-decorators app.ts

# Move class fields to constructor
zts --use-define-for-class-fields=false app.ts
```

### Flow

```bash
# Automatic @flow pragma detection
zts --flow app.js
```

## Output Options

### Module Format

```bash
zts --format=esm app.ts   # ESM (default)
zts --format=cjs app.ts   # CommonJS
```

### Minify

```bash
zts --minify app.ts  # Whitespace + identifiers + syntax
```

### Source Maps

```bash
zts --sourcemap app.ts -o app.js
# Generates app.js + app.js.map
```

### Quote Style

```bash
zts --quotes=single app.ts   # Single quotes
zts --quotes=double app.ts   # Double quotes (default)
zts --quotes=preserve app.ts # Preserve original
```

### ASCII Only

```bash
zts --ascii-only app.ts  # Escape non-ASCII to \uXXXX
```

## Define

```bash
zts --define:DEBUG=false --define:VERSION='"1.0.0"' app.ts
```

## Drop

```bash
zts --drop=console app.ts     # Remove console.* calls
zts --drop=debugger app.ts    # Remove debugger statements
```
