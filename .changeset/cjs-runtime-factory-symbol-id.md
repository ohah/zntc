---
'@zntc/core': patch
---

CommonJS runtime factory 선언과 wrapper 호출이 같은 graph-level semantic `SymbolId`를 사용합니다. 최종 이름은 linker rename table에서 공유합니다 (#4819).
