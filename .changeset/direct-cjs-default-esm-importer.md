---
'@zntc/core': patch
---

`module.exports = <값>` 한 형태의 CJS 를 default import 할 때 `__toESM` 래퍼 한 겹을
걷어내는 최적화가 **ESM importer 에서는 적용되지 않던 것**을 고쳤다.

그 shape(`exports.x` 없음 · `__esModule` 없음)에서는 Babel 모드든 Node 모드든 `.default` 가
`module.exports` 자신이라 `require_x()` 와 값이 같다. 그런데 importer 가 ESM 이면 축약을
막고 있었다 — 그 조건은 "Babel 모드인가" 의 대용이었고(예전엔 interop 판정이 `isEsm()` 과
동치였다) 축약의 유효 조건은 아니었다.

실제 npm 패키지 58개를 번들해 보면 29개가 작아지고(패키지당 −17~−51 바이트) 실행 결과는
전부 동일하다.
