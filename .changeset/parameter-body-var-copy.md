---
'@zntc/core': patch
---

Fix ES5 lowering of functions with parameter expressions and a same-named body `var`: the body variable now starts with the parameter's value (it was `undefined`), and `function f(x = 3) { var x; }` no longer crashes with `DuplicateBinding`.
