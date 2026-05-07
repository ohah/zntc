---
title: Tree-shaking
description: ZNTC bundler tree-shaking strategy — module-level fixpoint analysis, statement-level reachability BFS, and type-only import elision.
---

The ZNTC bundler runs tree-shaking in two passes. **Module-level** narrows the set of reachable modules and exports through fixpoint iteration. **Statement-level** then decides which top-level statements survive inside each module via symbol-graph BFS.

The goal is Rollup/Rolldown accuracy with esbuild-class speed. ZNTC reuses the index-based AST and the semantic analyzer's scope/symbol tables to get both.

## At a glance

```bash
# Tree-shaking is on by default in bundle mode — no flag needed.
zntc --bundle src/index.ts -o dist/bundle.js

# package.json sideEffects is honored automatically.
# @__PURE__ / @__NO_SIDE_EFFECTS__ comments are recognized.
# Add user-supplied pure hints:
zntc --bundle src/index.ts -o dist/bundle.js --pure=myUtil --pure=invariant
```

## Stage 1 — Module level

Starting from entry points, fixpoint iteration narrows reachable modules and exports (max 100 iterations, typically converges in 2–3).

### Used-export tracking

Each module records `(module_idx, export_name)` keys in a `used_exports` map.

- **Entry points + dynamic-import targets**: outside static analysis, conservatively marked as using all exports (the `*` sentinel).
- **Import-specifier scan in included modules**: registers which exports are imported under which local names.
- **Re-export chain cascade**: `export * from './a'` and `export { X } from './a'` propagate upstream usage to downstream modules.

```ts
// a.ts
export const used = 1;
export const unused = 2;  // unreachable → removal candidate

// entry.ts
import { used } from './a';
console.log(used);
```

### Side-effect verdict

A module can be dropped entirely only if all of these hold:

- No entries in `used_exports`
- Not an entry point
- Evaluating the module itself has no side effects (every top-level statement is pure)

### `package.json sideEffects`

```json
{
  "name": "my-lib",
  "sideEffects": false
}
```

When a library declares `sideEffects: false`, ZNTC is free to drop unused imports. Glob patterns are also supported:

```json
{
  "sideEffects": ["*.css", "./src/polyfills.ts"]
}
```

:::caution
The `sideEffects` policy is applied **monotonically** — once a file is marked `false`, it cannot be flipped back to `true`. This is intentional: it forces library authors to make their intent explicit.
:::

### Auto-purity inference

Even without `sideEffects` in `package.json`, ZNTC infers `side_effects = false` for non-entry modules whose top-level is entirely pure.

### Performance milestones

| Optimization | Effect |
|---|---|
| Fixpoint oscillation fix (#1558) | 100 iters → 2 iters; tree-shake 238ms → 51ms |
| `has_direct_used_export` O(1) array (#917) | Module-level used-export lookup is O(1) |
| Pre-built StmtInfo (#1558) | tree-shake 29.8ms → 5.6ms (-81%); transpile total -31% |
| `re_export_star_targets` bitset (#1928) | Avoids O(M·E) `tryMarkReExportNsSubset` scan |

## Stage 2 — Statement level

Once a module is kept, ZNTC decides which top-level statements are actually reachable. The semantic analyzer's symbol_id mapping is reused to build a per-statement symbol graph.

### StmtInfo

Each top-level statement records the symbols it **declares** and the symbols it **references**:

```zig
pub const StmtInfo = struct {
    node_idx: u32,
    has_side_effects: bool,
    declared_symbols: []const u32,    // symbols this stmt declares
    referenced_symbols: []const u32,  // references (excluding declared)
};
```

From this, ZNTC builds reverse indices: `symbol_to_stmt`, `sym_to_referencing_stmts`, `sym_to_writer_stmts`.

### Reachability BFS

```
Seed:
  - side-effectful statements
  - declaring statements of used exports
  - non-declaring writer statements (TS-emit pattern: var _a; ... _a = AST;)

Propagate:
  - referenced_symbols → enqueue dependent stmts via symbol_to_stmt
  - only statements reachable inside the module survive
```

### Example

```ts
// utils.ts
export function used() { return 1; }
export function unused() { return 2; }

const helper = () => 'helper';   // referenced only by unused → unreachable
function unused() { return helper(); }
```

Both `unused` and `helper` are removed in the output — they are disconnected from `used`'s reachability graph.

## Purity analysis

`@__PURE__` / `@__NO_SIDE_EFFECTS__` annotations combined with a builtin allow-list drive expression-level purity (recursion limit: 128).

### `@__PURE__` annotation

```ts
const x = /* @__PURE__ */ createComponent();  // dropped if x is unused
```

The lexer sets `is_pure` on the next call/new node; the tree-shaker then ignores it for side-effect purposes.

### `@__NO_SIDE_EFFECTS__` annotation

```ts
// @__NO_SIDE_EFFECTS__
function compute(x) { return x * 2; }

const a = compute(1);  // if a is unused, the call itself is removed
const b = compute(2);
```

Marking the function declaration treats every call site as pure.

### Builtin pure constructors

The following are auto-pure when bound to an unresolved global (no user redefinition):

| Constructor | Constraint |
|---|---|
| `Set`, `Map`, `WeakSet`, `WeakMap` | `new` only; arg must be empty / `null` / `undefined` / ArrayExpression (avoids iterator-protocol side effects) |
| `Array`, `Date`, `String` | Args must be recursively pure |
| `Error` family | Must statically prove the message arg is not a Symbol |
| `Object.freeze`, `Object.assign` | Fresh-literal constraint (special case) |

### User-supplied pure hints

Mark functions as pure via CLI or build options:

```bash
zntc --bundle entry.ts --pure=invariant --pure=warning
```

```ts
import { invariant } from 'tiny-invariant';

invariant(condition, "msg");  // call is removable when condition is statically truthy
```

## Type-only import elision

TypeScript's `import type` and inline `type` modifier produce no runtime bindings.

```ts
import type { User } from './types';        // fully removed
import { type Config, helper } from './x';  // type Config removed, helper kept based on usage
```

ZNTC performs elision via two paths:

- **Bundler path**: `binding_scanner.zig` checks the `SPEC_FLAG_TYPE_ONLY` flag and skips creating a BindingRecord altogether.
- **Transpile fast path** (BindingLite): without running full semantic analysis, BindingLite tracks value-use of named imports and removes only the truly-unused ones.

:::note
`default` and `namespace` imports are **not** elided — JSX pragmas and CSS-in-JS implicit-use risks make automatic removal unsafe. They are conservatively preserved.
:::

### `verbatimModuleSyntax`

When `tsconfig.json` has `"verbatimModuleSyntax": true`, ZNTC removes only `import type` and leaves regular imports intact (matching TypeScript's standard behavior).

## Limitations

:::caution[CJS-wrapped asset modules]
CJS modules wrapped via `require()` keep their `require_X()` calls, which count as side effects — even unused ones survive. esbuild's `NoSideEffects_PureData` marking is not yet applied in ZNTC.

JSON modules sidestep this by being converted to an ESM AST — they support per-named-export tree-shaking.
:::

:::caution[Namespace barrels]
`import * as X; export { X }` style namespace re-exports are hard to track via symbols and are classified as local exports. lazyBarrel refinement is in progress.
:::

:::caution[Getter / Proxy / Global side effects]
Deep DCE for runtime-time side effects (getters, Proxy, global mutation) is not yet implemented (lower priority).
:::

## Further reading

- Contributor implementation guide: [`docs/BUNDLER.md` § Tree-shaking 구현](https://github.com/ohah/zntc/blob/main/docs/BUNDLER.md#tree-shaking-%EA%B5%AC%ED%98%84-%EB%AA%A8%EB%93%88-%EC%88%98%EC%A4%80--statement-%EC%88%98%EC%A4%80) — data structures, file:line citations, algorithm pseudocode
- Architecture overview: [`docs/ARCHITECTURE.md` § Tree-shaking Design](https://github.com/ohah/zntc/blob/main/docs/ARCHITECTURE.md)
- Related PRs: #458, #460 (stage 1), #1558 (statement-level), #1791 (type-only elision), #1928 (re-export optimization)
