---
"@zntc/core": patch
---

`--splitting` 에서 **다른 청크의 CJS 모듈을 직접 import** 하면 실행이 `ReferenceError` 로 죽던 버그 수정 (#4494).

```
shared/single.cjs : module.exports = { tag: "singleton" };
shared/same.js    : import single from "./single.cjs";   // 공통 청크에 안착
a.js              : import single from "./single.cjs";   // 별도 동적 청크
```

→ `ReferenceError: require_single is not defined`. 빌드는 exit 0, 산출물도 전부 파싱을 통과하고 **실행만** 실패했다 (named import 도 동일).

소비자 청크가 per-importer interop preamble(`var single = require_single();`)을 냈는데, `require_X` 썽크는 provider 청크에만 있고 export 되지도 않는다(minify 후엔 이름도 다름).

**원인** — 직접 CJS import 가 cross-chunk 심볼로 등록되지 않았다. CJS 는 정적 export 가 없어 `resolveExportChain` 이 null → resolved binding 이 없고, `computeCrossChunkLinks` 가 그 바인딩을 통째로 skip 했다. 그래서 provider 는 interop 값을 export 하지 않았고 #4120 의 "cross-chunk CJS-interop 소비 억제" 게이트도 전역 공개명을 못 찾아 발화하지 않았다(re-export 경유 `export {default} from './a.cjs'` 만 등록돼 정상 동작). 이제 직접 import 도 canonical(CJS)+export 명으로 등록해, provider 청크가 interop 값을 materialize/export 하고 소비자는 일반 cross-chunk import 로 받는다.

같이 고친 것 (멤버명이 cross-chunk 공개명이 되면서 드러난 인접 결함들):

- **CJS 공개명을 합성명으로** (`default$single` / `named$second`). 예전엔 멤버명을 그대로 청크 top-level 식별자로 썼는데, 그러면 `exports.Buffer` 같은 멤버가 청크 안의 진짜 전역 `Buffer` 를 가리고(`Buffer.from is not a function`), 동명 청크 로컬(`const named`)과 `var`↔`const` 재선언 SyntaxError 를 냈다.
- **CJS owner 는 항상 materialize**. 예전엔 "동명 로컬이 있으면 interop 불요" 로 판단했는데, 그 로컬은 `__commonJS` 클로저 *안* 심볼이었다 — minify 시 `export { o as tag }` 로 클로저 스코프 이름을 노출해 `SyntaxError: Export 'o' is not defined`. (#4120 re-export 경로에도 있던 선재 버그.)
- dev/lazy 의 cross-chunk 전역명 override 가 CJS 클로저 내부 심볼을 개명하던 문제.

provider 가 실제로 materialize 하지 못하는 구성(preserve-modules, 비-ESM 포맷 + provider 가 entry 청크)에서는 **등록하지 않는다** — 소비자만 preamble 을 억제하면 값이 조용히 `undefined` 가 되어, 기존의 시끄러운 ReferenceError 보다 나빠지기 때문이다.
