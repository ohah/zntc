---
"@zntc/core": patch
---

tsconfig `paths` 가 node_modules 안 의존 패키지의 import 에도 적용되던 문제를 고쳤다 (#4607).

catch-all `"*": ["src/*"]` 을 쓰면 의존 패키지가 자기 의존성 대신 앱 소스를 먹었다 — 그 파일에
해당 export 가 없으면 런타임 TypeError, 있으면 조용히 다른 모듈이 번들됐다. tsc 는 `paths` 를
그 tsconfig 의 program 에 속한 파일에만 적용하고 기본 `exclude` 가 node_modules 다.
esbuild·rolldown 실측도 동일하다.

이제 importer 디렉토리가 `node_modules` 세그먼트 아래면 `paths` 를 적용하지 않는다. 워크스페이스
패키지처럼 node_modules 에 **심링크만** 걸린 경우는 실제 경로가 밖이라 종전대로 `paths` 를 받는다.
