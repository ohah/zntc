---
"@zntc/core": patch
---

동명 basename 자산의 `require_X` 래퍼 이름이 충돌해 **다른 자산의 URL 을 돌려주던** 버그 수정 (#4475).

```js
import x from "./a/logo.png";   // 내용이 서로 다른 파일
import y from "./b/logo.png";
console.log(x, y);
// 전: ./logo-efdc71e4.png ./logo-efdc71e4.png   ← 둘 다 같은 URL
// 후: ./logo-22fcfd0d.png ./logo-efdc71e4.png
```

자산 파일은 둘 다 올바른 해시로 방출되는데, 번들 JS 가 `var require_logo` 를 **두 번 선언**해서 두 번째가 첫 번째를 가렸다. 결과적으로 `a/logo.png` 는 번들에서 도달 불가능해지고 `x` 가 `b/logo.png` 의 URL 을 받았다 — 빌드는 성공하는 조용한 오컴파일.

근본 원인: `registerWrapperSymbols` 가 래퍼 이름을 `uniqueName()` 으로 deconflict 하는데, 그 앞에 `if (m.semantic) |*s| s else continue` 가드가 있다. asset 모듈은 JS 파싱을 거치지 않아 `semantic` 이 null 이라 **등록을 통째로 건너뛰었고**, emit 은 basename 기반 fallback(`makeRequireVarName`)으로 떨어졌다. 그 fallback 은 충돌을 모른다.

semantic 이 없어도 이름 deconflict 는 할 수 있으므로 전용 슬롯(`Module.wrapper_name_synthetic`)에 담는다. `disabled` / `optional-missing` 모듈도 같은 fallback 을 타고 있었으므로 함께 보호된다.
