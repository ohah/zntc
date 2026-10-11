---
'@zntc/core': patch
---

Attribute transform-generated references (such as a classic JSX factory call) to their top-level statement during tree shaking, so a module-local JSX factory like `const h = ...` is no longer removed from non-entry modules.
