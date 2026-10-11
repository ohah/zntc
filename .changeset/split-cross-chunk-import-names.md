---
'@zntc/core': patch
---

Fix code-splitting imports that could capture a same-named free global in the consuming chunk, and imports of same-named exports from entry chunks that failed with `does not provide an export named 'v$1'`.
