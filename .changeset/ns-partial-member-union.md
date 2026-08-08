---
"@zntc/core": patch
---

namespace 멤버 분석이 **부분** 집합을 반환할 때 `binding_scanner` union 을 덮어써 export 가
누락될 수 있던 문제를 고쳤다 (#4600).

기존 가드는 결과가 **정확히 비었을 때만** 이전 결과를 유지했다. symbol-aware 분석이 일부만
잡으면 union 에만 있던 멤버가 tree-shake 돼 namespace getter 가 dangling 됐다 — `counter$4`
계열 증상의 부분 케이스. 이제 두 결과를 합친다.

번들 크기 영향은 실측 0 (합성 픽스처 전체 동일, axios·chalk·clsx `--minify` 각 +0 B).
