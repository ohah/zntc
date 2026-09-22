---
'@zntc/core': patch
---

다운레벨된 async generator 의 세 가지 의미론 결함을 고쳤습니다 (#4705).

1. **`finally` 안에 `await` 가 있으면 `.return()`/`for await … break` 때 finally 의 나머지가 실행되지 않던 문제** — #4700 이 넣은 "return 인 채로 재개" 규칙이 `yield*` 위임용 await 뿐 아니라 평범한 `await` 에도 적용된 탓입니다. 리소스 해제·락 반납 같은 cleanup 이 조용히 건너뛰어졌습니다. 위임이 없어도 재현됩니다.
2. **IteratorResult 키 순서** — `{done, value}` → `{value, done}` (스펙 CreateIterResultObject).
3. **`yield <promise>` 가 await 되지 않던 문제(기존 결함)** — `yield Promise.resolve(1)` 이 Promise 를 그대로 내보내고, 거부되면 generator 안 `catch` 로 잡히지 않고 프로세스가 죽었습니다.

세 건 모두 `__asyncGenerator` 의 `step()` 한 곳에서 비롯됩니다. es2018 이상 타겟의 산출물은 그대로입니다.
