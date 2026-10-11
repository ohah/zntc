---
'@zntc/core': patch
---

Only add a file-level `"use strict"` to `--format=cjs` bundles when every bundled module is strict, so sloppy CommonJS dependencies (e.g. using `with`) keep working, and warn (ZNTC0800) when a `with` statement ends up in ESM output.
