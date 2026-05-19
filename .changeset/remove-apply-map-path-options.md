---
"@zntc/react-native": minor
---

deprecated `applyMapPathOptions` 제거 (dead code 전수조사 결과 — 내부 사용 0, deprecated 별칭)

### Breaking

`@zntc/react-native` 의 `applyMapPathOptions(rawJson, options)` export 가 제거되었습니다. 이 함수는 `postProcessSourceMap` 로 그대로 위임하던 deprecated 별칭이었습니다.

마이그레이션: `applyMapPathOptions(rawJson, opts)` → `postProcessSourceMap(rawJson, opts)` (시그니처 동일).
