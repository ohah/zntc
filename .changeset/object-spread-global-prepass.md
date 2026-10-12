---
'@zntc/core': patch
---

Require a bundler identity pre-pass for object-spread lowering so generated `Object.assign` references cannot be captured by source bindings (#4819).
