---
'@zntc/core': patch
---

generator/async 함수 안 구조분해의 rest(`const { a, ...rest } = o`, `const [x, ...rest] = arr`)가 es5·Hermes 에서 `undefined` 로 남던 문제를 고쳤습니다 (#4750).

상태 기계는 구조분해 선언을 대입으로 낮추는데, 그 경로가 rest 를 처리하지 않았습니다. Hermes 는 #4712 이후 이 경로를 타면서 회귀했습니다.
