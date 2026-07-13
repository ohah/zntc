---
"@zntc/core": patch
---

argless `new` 의 optional callee 뒤에 tagged template + trailing `?.` 가 붙으면 `ZNTC0623 (Invalid optional chain in 'new' expression)` 진단이 **2번** 나오던 문제 수정 (#4048).

```js
new a?.b`x`?.c    // ZNTC0623 × 2 → × 1
new a?.b.c`x`?.d  // ZNTC0623 × 2 → × 1
```

파서에 623 을 내는 지점이 둘이다 — callee 의 `?.` 를 잡는 `parseNewCallee` 와, argless new 를 base 로 하는 trailing `?.` 를 잡는 postfix 루프. 각자 자기 함수의 로컬 플래그로만 중복을 막고 있어서, 두 지점이 *같은 new* 를 보고하는 위 조합에서 서로를 모른 채 2번 발행했다. `parseNewCallee` 가 복구를 위해 `?.` 를 비-optional 멤버로 소비해버려 AST 구조만으로는 "callee 에 optional 이 있었다" 를 알 수 없는 것이 근본 원인.

new 노드에 `CallFlags.callee_optional_chain` 비트를 남겨 그 잃어버린 사실을 전파하고, postfix 루프가 이미 보고된 new 면 재보고하지 않게 했다. 진단 개수만 줄어들 뿐 수용/거부 동작은 그대로이며(입력은 여전히 SyntaxError), 서로 다른 new 두 개(`new (new a?.b)\`x\`?.c`)나 다른 코드의 진단(ZNTC0607)은 그대로 보고된다.
