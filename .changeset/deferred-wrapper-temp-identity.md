---
'@zntc/core': patch
---

ES5 async/generator 상태 기계 안의 `using` lowering이 만든 wrapper temp와 참조를 생성 시점의 exact binding handle로 연결합니다 (#4819).
