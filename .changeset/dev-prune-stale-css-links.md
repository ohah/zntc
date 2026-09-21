---
'@zntc/web': patch
'@zntc/core': patch
---

`zntc dev` 에서 CSS import 를 지워도 스타일이 계속 적용되던 문제를 고쳤습니다 (#4671).

링크 주입기가 추가만 하고 지우지 않아, JS 에서 `import './styles.css'` 를 없애도 `<link>` 가 HTML 에 남아 있었습니다. 이제 매 rebuild 마다 실제로 필요한 링크 집합에 맞춰 남은 링크를 지웁니다.

주입한 링크에만 표시를 달아 구분하므로, `index.html` 에 직접 적어 둔 `<link>` 는 그대로 유지됩니다.
