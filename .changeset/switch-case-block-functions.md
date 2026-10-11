---
'@zntc/core': patch
---

Lower function declarations inside `switch` cases of strict modules to block-scoped `let` bindings in sloppy bundle output, so they no longer overwrite another module's binding, and stay callable after a jump past their case.
