---
'@zntc/web': patch
'@zntc/server': patch
---

dev 컨트롤러에서 호출자가 없는 `injectBundleCssLinksFromOutdir` 를 제거하고, HMR `css-update` 메시지의 `href` 타입을 실제 동작에 맞췄습니다 (#4680, #4681).

`href` 는 "어느 stylesheet 를 갱신할지" 를 가리키는데, 단정할 수 없을 때는 `null` 을 보내 **모든 stylesheet 를 갱신**하게 합니다. 타입은 `string` 으로만 선언돼 있어 실제와 어긋나 있었습니다.

`@zntc/web` 의 `AppDevController` 인터페이스에서 메서드 하나가 빠집니다. dev 컨트롤러를 직접 임베드해 그 메서드를 호출하던 코드가 있다면 영향을 받습니다 — 저장소 안에는 호출자가 없었습니다.
