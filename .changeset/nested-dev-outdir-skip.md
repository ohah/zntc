---
'@zntc/web': patch
---

하위 디렉토리에 `zntc dev` 산출물(`.zntc-dev`)이 남아 있으면 `zntc build` 가 같은 CSS Module 을 두 번 처리하던 문제를 고쳤습니다 (#4678).

dev 산출 디렉토리에는 서빙용으로 **소스 CSS 가 그대로 미러**돼 있습니다. 예전에는 앱 루트의 `.zntc-dev` 만 걸러내서, 하위 앱이 dev 를 돌려 남긴 `sub/.zntc-dev` 가 소스로 취급됐습니다. 출력은 같았지만 빌드가 느려졌습니다.

⚠️ `--outdir` 로 이름을 바꾼 dev 산출물은 여전히 걸러지지 않습니다. `zntc build` 는 직전 `zntc dev` 가 어떤 outdir 을 썼는지 알 방법이 없습니다 — 알려진 한계로 #4678 에 남겨 둡니다.
