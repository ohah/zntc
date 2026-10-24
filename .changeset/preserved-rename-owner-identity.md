---
'@zntc/core': patch
---

HMR의 rename 스냅샷을 동일한 semantic 소유권에서만 정확한 SymbolId로 재사용합니다. 재파싱된 모듈은 이름으로 이전 심볼을 추측하지 않고 rename 계산을 다시 실행합니다.
