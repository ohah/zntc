---
'@zntc/core': patch
---

CommonJS 래퍼의 `exports`/`module` 매개변수와 자유 참조에 semantic `SymbolId`를 연결합니다. 최상위 `var exports`/`var module` 재선언은 같은 ID를 공유해 축약 빌드에서도 Node의 CommonJS 동작을 유지합니다 (#4819).
