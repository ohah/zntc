---
'@zntc/core': patch
---

Fix ES5 bundles where block-level bindings of strict modules (block functions under Annex B, and `let`/`const`/`class` lowered to `var`) overwrote another module's top-level binding or shadowed an import in scope-hoisted or wrapped output (including React Native).
