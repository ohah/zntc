---
"@zntc/core": patch
---

`--preserve-modules`(ESM 출력)에서 `import * as ns` (ESM-wrap dep) 의 멤버 접근이 `ReferenceError` 나던 것 수정 (#4532 증상2).

```js
// dep.js:  export const val = 42; export function greet(){ return "G"; }
// wrap.cjs: module.exports = require("./dep.js");   // dep 를 ESM-wrap 강제
// entry.js:
import * as ns from "./dep.js";
import "./wrap.cjs";
console.log(ns.val + "|" + ns.greet());   // 버그: ReferenceError: val is not defined
```

## 근본 원인

`ns.val`/`ns.greet()` 는 linker 가 bare `val`/`greet` 로 **평탄화**(namespace member rewrite)하는데, direct leaf `import * as ns` 의 멤버는 `computeCrossChunkLinks` 의 어느 경로도 소비자 청크 `imports_from` 에 등록하지 않는다(namespace binding 은 canonical 이 없어 import_bindings 루프서 skip, consumer-side 루프는 namespace **re-export**(`imported="*"`)만 잡음). 그래서 `computeCrossChunkGlobalNames` 가 그 멤버를 못 보고 → 전역명 없음 → 평탄화가 bare local 로 폴백 → provider 도 export 안 함 → 소비자 청크서 미정의.

## 수정

`computeCrossChunkLinks` 의 consumer-side namespace 루프에 **direct leaf namespace import 브랜치**를 추가: `nsReExportTarget`(namespace re-export)이 null 인 direct `import * as ns` 이고 dep 가 다른 청크면 `fanOutModuleExports(chunk, dep)` 로 dep 의 export 를 `imports_from`/`exports_to` 에 등록한다. 그러면 증상1이 켠 인프라가 그대로 발화 — `computeCrossChunkGlobalNames`(wrap 은 전역명, non-wrap ESM 은 자연명), provider export, 소비자 import·바인딩, 평탄화 rewrite. member-only(`ns.val`)·value-use(`Object.keys(ns)`) 둘 다 커버(후자는 소비자가 imported 멤버로 ns 객체 합성).

## 범위 (code-review 반영)

- 게이트 = 증상1 공유(`chunk_graph.pm_xchunk_naming` = preserve-modules + ESM + non-minify **+ non-dev**) + dep `wrap_kind != .cjs`.
  - **non-wrap ESM(.none)도 등록**: plain ESM dep(가장 흔함)도 같은 평탄화라 wrap-only 게이트면 똑같이 깨진다. CJS dep 은 cjsNs interop 별경로라 제외.
  - **`!dev_mode` 추가**: dev 는 namespace member rewrite 가 wrapped local 을 써 negotiated 전역명 경로를 안 탄다.
  - `seen_ns_target` dedup 으로 같은 dep 반복 DFS 방지. splitting·CJS·minify·dev 는 pre-existing 유지.
- 회귀 가드: `preserve-modules-cjs.test.ts` 에 실행 가드 3종 — wrap-ESM dep(`42|G`)·plain non-wrap ESM dep(`7|P`)·value-use `Object.keys(ns)`(`greet,val|42`), + fan-out 경로 pin(멤버 cross-chunk import 확인). node 로 실제 실행.
- 잔여(#4532): 증상 3(re-export barrel) / 4(multi-entry 순환) / CJS·minify / barrel-namespace 전역명 collision(비-.esm owner).
