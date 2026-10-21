---
'@zntc/core': patch
---

Keep callback-local temporary bindings isolated from nested bindings that reuse the same name span.

- The callback handoff now relies on the producer's exact binding identity instead of scanning live AST bindings by span.
- Nested function bindings and their references retain their own SymbolId and ScopeId.
