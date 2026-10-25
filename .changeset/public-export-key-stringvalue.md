---
"@zntc/core": patch
---

Keep escaped public export keys distinct from private initializer and namespace transports by reserving and comparing their JavaScript StringValue exactly once.
