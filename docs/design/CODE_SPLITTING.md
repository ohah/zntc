# ZNTC Code Splitting Design Document

## 1. Background

### Current ZNTC State (B1 + Linker Complete)

The ZNTC bundler currently produces **a single output file**. Key infrastructure already in place:

- **`Module.dynamic_imports`** — `std.ArrayList(ModuleIndex)` already separates dynamic imports from static dependencies. `graph.zig` line 312-313 stores dynamic imports via `addDynamicImport()` when `record.kind == .dynamic_import`.
- **`ImportKind.dynamic_import`** — already defined in `types.zig`.
- **`exec_index`** — DFS post-order for ESM execution ordering.
- **Linker** — scope hoisting with skip_nodes + renames metadata (no AST mutation).
- **TreeShaker** — module-level tree shaking with fixpoint analysis.
- **Emitter** — single-bundle output, exec_index sorted, format-aware (ESM/CJS/IIFE).
- **`BundleResult`** currently returns a single `output: []const u8`.

### What Code Splitting Solves

Without code splitting, `import("./page")` is either:
1. Left as-is (external) -- breaks in bundled output
2. Inlined into the main bundle -- defeats lazy loading

Code splitting creates multiple output chunks so dynamic imports load on demand.

---

## 2. Research Summary

### 2.1 esbuild's Approach (Simplest Correct)

**Core algorithm: BitSet-based chunk assignment.**

1. **Entry point expansion**: Dynamic imports are promoted to entry points alongside user-specified ones. Each entry point gets a bit index.

2. **Reachability marking** (`markFileReachableForCodeSplitting`): For each entry point bit `i`, DFS through static imports (NOT dynamic imports) setting `file.EntryBits.SetBit(i)`. Dynamic imports are treated as chunk boundaries -- traversal stops there.

3. **Chunk creation** (`computeChunks`): Files with identical `EntryBits` are grouped into the same chunk. The BitSet string becomes the chunk's key.
   - Entry point chunk: `EntryBits = {0}` (only reachable from entry 0)
   - Shared chunk: `EntryBits = {0, 2}` (reachable from entries 0 and 2)
   - The algorithm naturally creates common chunks without special logic.

4. **Cross-chunk dependencies** (`computeCrossChunkDependencies`): For each chunk, scan all symbol uses. If a symbol is declared in a different chunk, generate cross-chunk import/export statements.

5. **Dynamic import rewriting**: In the printer, dynamic `import()` calls to internal modules are rewritten to point to the chunk file path (using `uniqueKey` placeholder, later substituted with the final hash-based filename).

**Key insight**: esbuild does NOT have a runtime loader. It relies on the browser's native `import()` for ESM output, and `Promise.resolve().then(() => require())` for CJS/IIFE.

### 2.2 Rollup/Rolldown's Approach (More Optimized)

Same BitSet core, but with additional optimizations:

- **Dynamic entry optimization**: If module B is only dynamically imported from entry A, and B's static dependencies overlap with A's, those shared modules stay in A's chunk (not extracted into a separate common chunk). Rollup computes "already loaded" sets per dynamic entry.
- **Chunk merging**: Small chunks below `minChunkSize` are merged into larger ones.
- **Manual chunks**: Users can force modules into named chunks via `manualChunks`.
- **`preserveModules`**: One chunk per module (for library builds).

### 2.3 Key Differences

| Aspect | esbuild | Rollup/Rolldown |
|--------|---------|-----------------|
| Chunk algorithm | Simple BitSet grouping | BitSet + optimization passes |
| Common chunks | Automatic from BitSet | Automatic + merge optimization |
| Runtime loader | None (native import()) | None (native import()) |
| Manual chunks | No | Yes |
| Min chunk size | No | Yes |
| Complexity | ~200 lines core | ~800 lines core |

**Recommendation**: Start with esbuild's approach. It's correct and simple. Optimization (Rolldown-style) can be added later without architectural changes.

---

## 3. Chunk Determination Algorithm

### 3.1 Overview

```
Phase 1: Tree shaking (existing)
Phase 2: Entry point expansion (NEW — promote dynamic imports to entries)
Phase 3: Reachability marking (NEW — BitSet per file)
Phase 4: Chunk grouping (NEW — identical BitSets = same chunk)
Phase 5: Cross-chunk linking (NEW — inter-chunk imports/exports)
Phase 6: Emit multiple files (MODIFY emitter)
```

### 3.2 Step-by-Step

**Step 1: Expand entry points.**

Dynamic import targets become additional entry points. Each entry point (user-specified + dynamic) gets a unique bit index.

```
User entries:       [main.ts]        -> bit 0
Dynamic imports:    [page.ts]        -> bit 1
                    [dialog.ts]      -> bit 2
Total entry points: 3, BitSet size = 3
```

**Step 2: Mark reachability.**

For each entry point `i`, DFS through static dependencies only. At each visited file, set bit `i` in that file's `EntryBits`. Dynamic imports are NOT traversed (they are separate entry points).

```
main.ts imports: utils.ts (static), page.ts (dynamic)
page.ts imports: utils.ts (static), widget.ts (static)

After marking:
  main.ts:   bits = {0}
  utils.ts:  bits = {0, 1}    <- reachable from both main and page
  page.ts:   bits = {1}
  widget.ts: bits = {1}
```

**Step 3: Group into chunks.**

Files with identical EntryBits form a chunk:

```
Chunk A (entry, bit={0}):   [main.ts]
Chunk B (entry, bit={1}):   [page.ts, widget.ts]
Chunk C (shared, bit={0,1}): [utils.ts]
```

**Step 4: Cross-chunk linking.**

For each chunk, find symbols used from other chunks. Generate:
- Export statements in the source chunk
- Import statements in the consuming chunk

**Step 5: Emit.**

Each chunk becomes a separate output file. Dynamic `import("./page")` is rewritten to `import("./page-[hash].js")`.

### 3.3 Common Chunk Extraction

Common chunks emerge automatically from the BitSet algorithm. No special logic needed:

- A module reachable from entries {0, 1, 2} gets `bits = {0,1,2}`
- If no other module has the same bits, it forms its own chunk
- If multiple modules share `bits = {0,1,2}`, they group together

This is exactly how esbuild does it, and it handles arbitrary sharing patterns correctly.

---

## 4. Data Structures

### 4.1 New: BitSet on Module

```
Module (existing) gets new field:
  entry_bits: BitSet          // which entry points can reach this module
  distance_from_entry: u32    // min hops from any entry (for tie-breaking)
```

BitSet implementation: `std.DynamicBitSet` (already used for tree shaking's `included` set).

### 4.2 New: Chunk struct

```
Chunk:
  index: ChunkIndex           // position in chunk array
  entry_bits: BitSet           // which entries this chunk serves
  modules: ArrayList(ModuleIndex)  // modules in this chunk, exec_index sorted
  is_entry_point: bool         // true for user + dynamic entry chunks
  entry_module: ?ModuleIndex   // if entry point, which module

  // Cross-chunk linking
  imports_from_chunks: HashMap(ChunkIndex, []CrossChunkImport)
  exports_to_chunks: HashMap(SymbolRef, []const u8)  // symbol -> exported name

  // Output
  file_name: []const u8        // e.g., "chunk-abc123.js"
```

### 4.3 New: ChunkGraph

```
ChunkGraph:
  chunks: ArrayList(Chunk)
  module_to_chunk: []ChunkIndex   // module index -> chunk index
```

### 4.4 Modified: BundleResult

Currently returns single `output: []const u8`. Change to:

```
BundleResult:
  outputs: []OutputFile        // multiple files

OutputFile:
  file_name: []const u8       // relative path (e.g., "main.js", "chunk-abc.js")
  contents: []const u8
  is_entry: bool
```

---

## 5. Runtime Loader

### 5.1 ESM Output (Primary Target)

**No runtime loader needed.** The browser/Node.js natively supports `import()`:

```js
// Input
const page = await import("./page");

// Output (after code splitting)
const page = await import("./page-abc123.js");
```

The only transformation is path rewriting. This is by far the simplest approach and what both esbuild and Rollup do.

### 5.2 CJS Output

Wrap in `Promise.resolve().then(() => require())`:

```js
// ESM input
const page = await import("./page");

// CJS output
const page = await Promise.resolve().then(() => require("./page-abc123.js"));
```

### 5.3 IIFE Output

Code splitting is NOT supported for IIFE format. This matches esbuild's behavior. If the user requests IIFE + code splitting, emit a diagnostic error.

### 5.4 `import.meta.url` / `new URL()` Considerations

For relative chunk paths to resolve correctly, the emitter must compute the relative path from the importing chunk to the imported chunk. Since all chunks are in the same output directory (initially), this is simply `"./" + chunk_filename`.

---

## 6. Output Format

### 6.1 File Naming

Entry point chunks: preserve the original filename (e.g., `main.js`).
Shared/dynamic chunks: `chunk-[HASH].js` where HASH is a content hash.

The hash ensures cache-busting. Initially, use a simple hash (e.g., first 8 chars of the chunk content's xxhash or std.hash).

### 6.2 Cross-Chunk Import/Export Syntax

Entry chunk (`main.js`):
```js
import { utils_fn } from "./chunk-abc123.js";
// ... main code using utils_fn ...
```

Shared chunk (`chunk-abc123.js`):
```js
// ... utils code ...
export { utils_fn };
```

Dynamic entry chunk (`page-def456.js`):
```js
import { utils_fn } from "./chunk-abc123.js";
// ... page code using utils_fn ...
```

### 6.3 Manifest (Deferred)

A `manifest.json` mapping original paths to output filenames. Not needed for MVP -- add when plugin system or framework integration demands it.

---

## 7. Edge Cases

### 7.1 Circular Dynamic Imports

```js
// a.js
const b = await import("./b");
// b.js
const a = await import("./a");
```

Both become entry points. Each gets its own chunk. The native `import()` handles circular loading (modules are cached after first evaluation). No special handling needed in the bundler.

### 7.2 Static + Dynamic Import of Same Module

```js
import { x } from "./utils";        // static
const utils = await import("./utils"); // dynamic
```

The static import makes `utils` part of the current chunk. The dynamic import is redundant but valid. esbuild handles this by checking `isExternalDynamicImport` -- if the target is in the same chunk, the dynamic import resolves to the already-loaded module (via `Promise.resolve()` + direct reference).

For ZNTC: if the dynamic import target is in the same chunk as the importer, rewrite it to:
```js
Promise.resolve().then(() => utils_exports)
```

### 7.3 Shared State Across Chunks

Module-level variables are shared because each module is evaluated exactly once (ESM guarantee). Chunks that both import the same module from a shared chunk will see the same state. No special handling needed.

### 7.4 CSS (Deferred)

CSS code splitting follows a similar pattern but requires a separate CSS chunk per JS entry chunk. This is a significant feature on its own and should be implemented after JS code splitting works. For now, CSS files can be treated as external.

### 7.5 Side-Effect-Only Modules in Shared Chunks

A module with side effects but no exports (e.g., polyfills) must be included in the correct chunk. The BitSet algorithm handles this naturally -- the module's EntryBits determines which chunk it belongs to. The entry chunk must ensure these chunks are loaded (via import statement without bindings).

### 7.6 `--bundle` Without `--splitting`

Code splitting should be opt-in via a `--splitting` flag (matching esbuild). Without it, dynamic imports are left as-is (external) or, if the target is in the graph, inlined into the main bundle. This preserves backward compatibility with the current single-file output.

---

## 8. Integration with Existing Systems

### 8.1 Linker Changes

The current Linker operates on a flat module list. With code splitting:
- Linker still computes scope hoisting (renames, skip_nodes) for all modules
- A new `ChunkLinker` step adds cross-chunk import/export generation
- Cross-chunk exports need unique names (deconfliction within each chunk)

### 8.2 TreeShaker Changes

TreeShaker currently marks modules as included/excluded. With code splitting:
- Entry points for tree shaking must include dynamic import targets
- Per-chunk tree shaking is more precise but not needed for MVP -- module-level shaking is sufficient initially

### 8.3 Emitter Changes

The biggest change. Current emitter produces one `[]const u8`. New emitter:
- Takes a `ChunkGraph` instead of a flat module list
- Iterates chunks, emitting each as a separate file
- Adds cross-chunk import preamble and export suffix per chunk
- Rewrites dynamic import paths to chunk filenames

---

## 9. Implementation Order (PR Breakdown)

### PR 1: BitSet + Entry Point Expansion (~200 lines)
- Add `entry_bits: ?std.DynamicBitSet` and `distance_from_entry: u32` to `Module`
- Add `--splitting` flag to `BundleOptions`
- Promote dynamic import targets to entry points in `graph.build()`
- Unit tests: BitSet assignment for simple cases

### PR 2: Chunk Data Structures (~150 lines)
- New file: `src/bundler/chunk.zig` with `Chunk`, `ChunkIndex`, `ChunkGraph`
- `computeChunks()` function: group modules by identical EntryBits
- `module_to_chunk` mapping
- Unit tests: chunk grouping for various dependency patterns

### PR 3: Reachability Marking (~100 lines)
- `markReachableForCodeSplitting()` in `graph.zig`
- DFS through static deps only, stopping at dynamic import boundaries
- Track `DistanceFromEntryPoint` for tie-breaking
- Unit tests: reachability with mixed static/dynamic imports

### PR 4: Cross-Chunk Linking (~300 lines)
- `computeCrossChunkDependencies()` in new `chunk_linker.zig` or extension of `linker.zig`
- For each chunk, find symbols used from other chunks
- Generate cross-chunk import/export metadata
- Unit tests: symbol crossing chunk boundaries

### PR 5: Multi-File Emitter (~250 lines)
- Change `BundleResult` from single output to `[]OutputFile`
- Modify emitter to iterate chunks
- Add cross-chunk import preamble per chunk
- Add export suffix per chunk
- Rewrite dynamic import() paths to chunk filenames
- Content hashing for chunk filenames
- Integration tests with fixture files

### PR 6: CLI + Polish (~100 lines)
- `--splitting` flag in CLI
- Validate: splitting requires ESM output format
- `--outdir` required when splitting (can't write multiple files to stdout)
- Error diagnostics for invalid combinations

### Total Estimate: ~1100 lines, 6 PRs

---

## 10. Testing Strategy

### Unit Tests (Per PR)
- **BitSet assignment**: Given a module graph, verify correct EntryBits
- **Chunk grouping**: Given EntryBits, verify correct chunk assignment
- **Cross-chunk symbols**: Given chunks, verify correct import/export lists
- **Path rewriting**: Verify dynamic import paths point to correct chunks

### Fixture Tests
```
tests/bundler/fixtures/splitting/
  basic/           -- single dynamic import
  shared/          -- shared dependency between entry and dynamic
  multiple/        -- multiple dynamic imports from one entry
  chain/           -- A => B => C (chain of dynamic imports)
  circular/        -- A => B, B => A
  static-dynamic/  -- same module imported both statically and dynamically
  no-shared/       -- dynamic import with no shared deps
```

Each fixture has:
- Input files (`.ts`)
- Expected output file list
- Expected output content (or at least expected chunk count + which modules in which chunk)

### Execution Tests (Post-MVP)
- Bundle, then run the output in Node.js
- Verify dynamic imports resolve and execute correctly
- Compare output behavior with esbuild's output

---

## 11. Non-Goals (Explicitly Deferred)

1. **Manual chunks** (`manualChunks` option) -- Rollup feature, add later
2. **Chunk merging / minChunkSize** -- optimization, add after correctness
3. **CSS code splitting** -- separate feature
4. **Chunk manifest.json** -- add when plugin system needs it
5. **Content hash in filename** -- can start with simple counter, add hash later
6. **Source maps per chunk** -- add after single-file source maps work with splitting
7. **IIFE code splitting** -- not supported (same as esbuild)
8. **Parallel chunk emission** -- optimize later with thread pool

---

## 12. Open Questions

1. **Hash algorithm**: Use `std.hash.XxHash3` (fast, good distribution) or simpler? esbuild uses its own xxhash. Recommendation: xxhash, 8 hex chars.

2. **Chunk filename template**: Start with `chunk-[hash].js` or allow customization (`[name]-[hash].js`)? Recommendation: start simple, add template later.

3. **Should `--splitting` imply `--format=esm`?** esbuild requires ESM for splitting. Recommendation: yes, error if format != esm with splitting enabled.

4. **How to handle `--splitting` without `--outdir`?** Multiple files can't go to stdout. Recommendation: require `--outdir` when splitting is on.
