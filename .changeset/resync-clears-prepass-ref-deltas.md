---
'@zntc/core': patch
---

Fix syntax minification dropping live top-level declarations in some CommonJS packages (e.g. Vue's `DOMTransitionPropsValidators`, causing `ReferenceError`) when a module was re-analyzed after the pre-pass minifier ran.
