---
'@zntc/web': patch
'@zntc/core': patch
---

`zntc dev` 에서 CSS Module / SCSS 와 plain `.css` 를 함께 import 하면 plain CSS 가 적용되지 않던 문제를 고쳤습니다 (#4675).

dev 는 SCSS / CSS Modules 의 생성 CSS 만 페이지에 연결했습니다. plain `.css` 는 디스크에 미러돼 서빙까지 되는데 `<link>` 가 없어 도달하지 못했습니다.

이제 **번들러가 실제로 따라간 CSS 목록**으로 링크를 겁니다. 디렉토리를 훑어 붙이면 import 하지도 않은 CSS 까지 적용되므로, 모듈 그래프에 들어온 것만 연결합니다. 같은 내용의 합본인 번들 CSS 는 중복이라 이 경우 연결하지 않습니다.

CSS 를 고칠 때 해당 링크 하나만 정확히 갱신되는 것도 함께 고쳐집니다 — 예전에는 plain CSS 가 링크에 없어 "어느 링크인지 모름" 으로 떨어져 모든 stylesheet 를 다시 받았습니다.
