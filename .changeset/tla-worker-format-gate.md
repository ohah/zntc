---
"@zntc/core": patch
---

#4598 TLA 위임의 구멍 두 개를 막았다.

**1) code splitting 청크가 파싱조차 안 되던 회귀.** splitting 의 IIFE 청크는 async factory 가
아니라 `__zntc_register({"m.js": function(exports, module, require) {...}})` — plain function
이다. 위임하면 `await` 가 그 안에 그대로 들어가 **청크 전체가 SyntaxError** 였다. splitting 은
위임 대상에서 뺀다. 모듈 단위 래핑은 #4598 로 여전히 깨져 있지만 최소한 파싱은 된다.

**2) worker 서브빌드가 부모 format 으로 판정하던 문제.** worker 는 부모가 esm/cjs/umd 여도
자신은 iife 로 방출된다. 부모 format 으로 판정하면 같은 worker 파일이 부모에 따라 깨졌다 안
깨졌다 했다 — `const val = v + 1;` 이 async 래퍼 밖에 남아 `ReferenceError: v is not defined`.
이제 worker 는 자기 방출 format(`workerFormat()`)으로 판정한다.
