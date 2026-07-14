---
"@zntc/core": patch
---

CJS interop 잔여 결함 3건 수정 (#4510). #4494(크로스-청크 CJS 의 **직접** named/default import)가 못 덮은 표면들로, 셋 다 별개 루트커즈다.

1. **크로스-청크 `import * as ns from './x.cjs'`** — namespace 합성 경로는 #4494 의 크로스-청크 심볼 등록 기계를 타지 않아 소비자 청크에서 `require_X` 썽크가 undefined 였다. 합성 ns 도 provider 청크의 썽크를 크로스-청크 심볼로 등록한다.

2. **비-식별자 멤버명** — `import { 'foo-bar' as x } from './x.cjs'` 가 `require_x()."foo-bar"` 로 방출돼 **문법 오류**였다. splitting 없이도 실패하는 preamble-writer 버그로, bracket 표기(`["foo-bar"]`)로 수정.

3. **동적 import 의 `.default`** — `(await import('./x.cjs')).default` 가 undefined 였다. 동적 경로가 `__toESM` 의 default 합성을 거치지 않았다.

전부 빌드 exit 0 · 파싱 통과 · **실행만** 실패하는 계열이라 실행 스모크로 가드했다.
