---
"@zntc/core": patch
---

`**` 좌변 괄호 계약을 **사후조건으로 강제** (#4482 후속).

`binaryChildLevels` 는 "괄호가 필요하다" 를 자식 level 을 올리는 것으로 표현하는데, 실제 괄호를 치는 쪽(`exprNeedsParens`)이 그 노드 종류를 모르면 **level 이 그냥 버려진다** — 이게 `-2**2` / `void 0**2` 가 방출되던 정확한 기전이었다. 두 목록이 어긋나도 아무도 안 잡아줬다.

이제 `**` 좌변이 prefix 단항으로 시작한다고 판정했는데 방출된 첫 바이트가 `(` 가 아니면 runtime_safety 빌드(테스트·CI)에서 즉시 panic 한다. 이 사후조건이 켜지자마자 남아 있던 불일치를 하나 더 찾았다 — `powLeftNeedsParen` 이 **모든** numeric literal 에 true 를 반환하는데 `exprNeedsParens` 는 **음수만** 괄호를 쳐서, 양수 리터럴(`2**3`)은 level 만 올라가고 wrap 은 안 걸리고 있었다 (동작은 우연히 맞았다). 양쪽을 정확히 맞췄다.
