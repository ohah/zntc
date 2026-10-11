---
'@zntc/core': patch
---

Keep late-named ES5 helpers (`_super`, `_state`, `_newTarget`) correct when the source already declares the same name: the internal staging spelling now avoids source bindings, fixing runtime errors in lowered static `super` calls and generator loops, a `DuplicateBinding` crash in constructors, and restoring distinct final names for `new.target` captures.
