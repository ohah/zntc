---
'@zntc/core': patch
---

Keep callback-local temp bindings connected to their producer through hoisting.

- The transformer now carries the exact binding node by allocator slot instead of finding it later by matching a name span.
- This keeps callback reference identity intact when class-super and object-home temps are hoisted.
