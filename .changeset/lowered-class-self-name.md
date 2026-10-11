---
'@zntc/core': patch
---

Keep the inner constructor name of ES5-lowered classes when the outer class binding is renamed in a bundle (e.g. `--global-identifier`), regardless of whether the module uses a define.
