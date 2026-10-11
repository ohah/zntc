---
'@zntc/core': patch
---

Keep runtime helpers that other helper bodies reference on their fixed names when minifying identifiers, so a shortened helper name can no longer be shadowed by a helper-local variable (fixes async generators throwing `Right-hand side of 'instanceof' is not callable`).
