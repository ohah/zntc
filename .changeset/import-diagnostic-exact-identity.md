---
'@zntc/core': patch
---

누락된 import의 값 사용 진단을 로컬 AST anchor의 정확한 SymbolId로 판정합니다. 손상된 이름별 scope map이나 이전 참조가 다른 바인딩의 진단을 숨기거나 잘못 발생시키지 않도록 합니다.
