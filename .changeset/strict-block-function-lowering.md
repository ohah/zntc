---
'@zntc/core': patch
---

Lower block-level function declarations of strict (ESM) modules to block-scoped `let` bindings when the bundle runs them in sloppy mode (iife/umd/amd output, `__esm` wrappers, dev HMR), so Annex B hoisting can no longer overwrite another module's binding. Targets without `let` (ES5) are unchanged.
