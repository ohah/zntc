---
"@zntc/core": patch
---

IIFE 번들에서 top-level await + `--target < es2022` 가 `ReferenceError` 를 내던 문제를
고쳤다 (#4598 부분).

TLA 다운레벨을 모듈 단위 래핑 대신 **청크 레벨 async factory** 에 위임한다. 모듈 단위로 감싸면
`export` 가 래퍼 밖에 남아 스코프가 갈리고, 같은 번들 소비자도 래퍼 밖 최상위에 놓여 값을 못
본다(scope-hoisted 출력이라 live binding 이 없다).

⚠️ **IIFE + async 지원 타겟에만** 적용한다. UMD/AMD/CJS 는 async factory 를 만들지 않고,
es5 는 factory 가 generator 여야 하는데 `for await` 다운레벨과 충돌한다.
