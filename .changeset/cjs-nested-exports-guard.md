---
'@zntc/core': patch
---

Keep CommonJS `exports.X` assignments that are only read through `exports` or `module.exports` inside functions after CJS wrapper parameters gained symbol identities (fixes bundling `mime-types`).
