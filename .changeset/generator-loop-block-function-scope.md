---
'@zntc/core': patch
---

Fix a crash (`invalid transform semantic edit: InvalidScope`) when lowering a generator or async function to ES5 whose extracted loop body declares a strict-mode block function that is referenced outside itself.
