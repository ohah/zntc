---
'@zntc/core': patch
---

ES5 class declaration과 class expression의 generated `_super` parameter에 exact `SymbolId`와 사용 위치별 reference scope를 연결합니다. `_super`라는 사용자 변수와 겹치는 별칭에서도 번들러 rename과 semantic reference graph가 같은 parameter를 가리킵니다 (#4819).
