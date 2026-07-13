---
"@zntc/core": patch
---

`new a?.b\`x\`?.c` 처럼 argless `new` 의 optional callee 와 trailing `?.` 가 겹칠 때 진단 ZNTC0623 이 **2번** 발행되던 문제 수정 (#4048).

두 검사 지점이 **같은 `new`** 를 각각 보고하고 있었다. 복구 경로가 callee 의 `?.` 를 비-optional 멤버로 소비해 버려서, AST 에 "이 new 의 callee 는 optional 이었다" 는 사실이 남지 않았던 게 원인이다. dedup 필터로 뭉개는 대신 그 사실을 `new` 노드에 비트로 복원해, 뒤따르는 검사가 같은 new 를 다시 보고하지 않게 했다.

**같은 new 안에서만** 접는다 — 서로 다른 `new` 두 개는 각자의 위반이므로 그대로 2건이 나온다 (`new new a?.b\`x\`?.c`, `new (new a?.b)\`x\`?.c`). 다른 진단(ZNTC0607 tagged template on optional chain)도 억제되지 않는다.
