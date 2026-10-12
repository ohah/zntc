---
'@zntc/core': patch
---

ES5 bundling now keeps the exact semantic graph for audited `new.target` lowering, including lexical arrow captures. Modules with direct `eval` still use semantic reanalysis.
