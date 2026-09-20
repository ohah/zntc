---
'@zntc/core': patch
---

`zntc dev` 에서 JS 가 import 한 CSS 가 HTML 에 연결되지 않던 문제를 고쳤다 (#4660).

CSS 파일은 outdir 에 정상 생성되고 HTTP 로도 서빙되는데, dev HTML 에
`<link rel="stylesheet">` 가 붙지 않아 스타일이 적용되지 않았다.

네이티브 watch 의 ready/rebuild 이벤트가 산출 경로 목록(`outputs`)에 JS 만 싣고
`asset_outputs`(CSS bundle · worker chunk · file-loader 산출물)를 빠뜨린 것이 원인이다.
일반 `build()` 경로는 이 둘을 합쳐서 돌려주는데 watch 경로만 빠져 있었다. dev 서버는 그
목록을 보고 `<link>` 를 주입하므로, 목록에 없으면 파일이 디스크에 있어도 페이지에
연결되지 않는다.

이제 watch 경로도 `asset_outputs` 를 outdir 에 쓰고 이벤트 목록에 함께 싣는다.
