---
'@zntc/core': patch
---

minify 산출물에서 `__publicField` / `__asyncDelegator` 가 축약명을 쓰도록 고쳤습니다.

`__publicField` 는 **class field 하나마다 한 번씩** 호출되는데 축약 테이블에 빠져 있어, 필드 수 × 13자가 그대로 실렸습니다. 클래스 200개 규모의 앱을 `--target=es2017 --minify` 로 빌드하면 **8,283 bytes(−15.6%)** 가 줄고, esbuild 대비 크기 비가 **1.26x → 1.06x** 가 됩니다.

동작 변화는 없습니다(식별자 이름만 바뀜). 낮추지 않는 타겟(esnext/es2022)의 산출물도 그대로입니다.
