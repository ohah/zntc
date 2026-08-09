---
"@zntc/core": patch
---

worker 서브빌드의 top-level await 다운레벨이 **부모 번들의 format 에 따라 깨졌다 안 깨졌다**
하던 문제를 고쳤다 (#4598 후속).

worker 는 부모가 esm/cjs/umd 여도 자기 자신은 iife 로 방출된다. 그런데 #4598 의 위임 판정이
부모 format 을 보고 있어, 부모가 iife 가 아니면 위임이 꺼진 채로 iife 청크가 방출됐다. 결과적으로
같은 worker 파일이 `const val = v + 1;` 을 async 래퍼 밖에 남겨 `ReferenceError: v is not
defined` 를 냈다. 이제 worker 는 자기 방출 format(`workerFormat()`)으로 판정한다.

같은 원인의 두 번째 구멍도 함께 막았다. multi-format(`output: [...]`)은 **하나의 그래프를 여러
format 으로** 방출하므로 "async factory 가 생긴다"는 위임의 전제가 성립하지 않는다. 방출 format
이 하나로 확정되지 않으면 위임하지 않고 모듈 단위 래핑에 맡긴다.
