---
'@zntc/core': patch
---

`--target=es5` 번들이 ES5 엔진에서 파싱되지 않던 문제를 고쳤습니다 (#4630).

사용자 코드 다운레벨(arrow→function, class→IIFE, spread→`Object.assign`)은 정상이었지만, 번들러가 직접 붙이는 **interop 표면 네 곳**이 타겟을 보지 않고 항상 ES6 문법을 냈습니다.

- **런타임 헬퍼** — `__commonJS` `__esm` `__copyProps` `__toESM` `__export` `__toCommonJS` 의 화살표
- **모듈 래퍼 헤더** — `__commonJS({ "id"(exports, module) { … } })` 의 객체 단축 메서드
- **`__export` getter** — `name: () => value`
- **동적 import 재작성** — `Promise.resolve().then(() => …)`

원인은 ES5 변종 선택이 `configurable_exports`(React Native/Hermes 플래그)에 얹혀 있던 것입니다. RN preset 이 `target: 'es5'` 를 하드코딩해 실무상 es5 ⟺ RN 이었기 때문인데, **RN 이 아닌 es5 사용자**에겐 화살표가 그대로 나갔습니다. 이제 문법 축(`unsupported.arrow` / `unsupported.object_extensions`)과 의미 축(`configurable_exports`)을 분리하고, 빠져 있던 조합(function 문법 + non-configurable)의 헬퍼 변종을 채웠습니다.

React Native 산출물은 **바이트가 동일**합니다(실측 확인) — RN 은 `configurable_exports` 로 이미 function 문법 변종을 쓰고 있었습니다. es2015 이상 타겟의 산출물도 그대로입니다.
