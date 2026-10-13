---
'@zntc/core': patch
---

Worklet 메서드 이름과 캡처 변수 이름이 Unicode escape 표기만 다르게 같은 JavaScript 식별자인 경우, factory 지역 변수가 캡처를 가리지 않도록 했습니다. 합성 이름의 충돌 검사도 escaped 표기와 일반 표기를 같은 식별자로 비교합니다.
