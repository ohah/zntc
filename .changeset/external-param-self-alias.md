---
'@zntc/core': patch
---

Stop emitting `var React$1 = React;` style aliases in UMD/AMD/IIFE bundles when a default or namespace import of an external already has the factory parameter's name.
