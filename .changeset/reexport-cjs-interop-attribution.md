---
'@zntc/core': patch
---

re-export 체인을 거쳐 온 CJS default 바인딩의 interop 모드를 **그 `export ... from` 문을 쓴
모듈** 기준으로 판정하도록 고쳤다 (#4659 파생).

`export { default as x } from '<CJS>'` 의 `x` 가 무엇인지는 그 문장을 쓴 모듈의 형식이
정하는데, linker 가 re-export 체인을 평탄화하면서 중간 모듈을 버리고 **최종 소비자** 기준으로
판정하고 있었다. `.mjs` 앱이 `"module"` 필드 패키지의 re-export 를 소비하면 Babel 이어야 할
자리에 Node 모드가 박혀 default 가 함수 대신 네임스페이스 객체가 됐다.

같은 CJS 를 서로 다른 형식이 import 하는 경우도 각자 제 모드를 받는다 — re-export 경유분은
Babel, 직접 import 분은 Node. esbuild · rolldown · rspack 과 결과가 일치한다.
