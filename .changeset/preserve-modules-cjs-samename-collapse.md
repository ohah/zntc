---
"@zntc/core": patch
---

`--preserve-modules`(CJS)에서 **서로 다른 wrap dep 이 동명 export 를 내고 한 소비자가 둘 다 import** 하면, 소비자 본문이 한 이름으로 붕괴해 잘못된 값을 조용히 방출하던 것 수정 (#4532 증상1).

```js
// b.js:    export function tag(){ return "B"; }
// c.js:    export function tag(){ return "C"; }
// a.cjs:   module.exports = require("./b.js"); require("./c.js");   // b·c 를 ESM-wrap 강제
// entry:   import { tag } from "./b.js"; import { tag as tag2 } from "./c.js"; import "./a.cjs";
//          console.log(tag() + tag2());
// node canonical: "BC"
// 버그(CJS): "BB"  ← console.log(tag() + tag()) 로 붕괴 (에러 없는 조용한 오컴파일)
```

## 근본 원인

동명 심볼을 파일 경계 너머로 구분하는 cross-file 네이밍(`computeCrossChunkGlobalNames`)이 preserve-modules 에서 **ESM 출력만** 켜져 있었다(`pm_xchunk_naming` 게이트에 `format == .esm`). CJS 출력에선:

- **forwarding 썽크**(emitter, chunks.zig)는 `name_seen_count` 로컬 dedup 으로 `let tag$1` 을 만드는데,
- **본문 참조**(linker, metadata.zig)는 `resolveToLocalName(canonical)` = `tag` 로 rename 한다.

두 경로가 **공유 맵 없이 독립 계산**해 발산 → forwarding var `tag$1` 은 죽고 본문은 `tag`(b 의 canonical) 를 두 번 참조 → `BB`. ESM 은 전역명 맵을 provider·consumer·본문 셋이 공유해 일치한다.

## 수정

1. `pm_xchunk_naming` 게이트를 **CJS 출력에도** 오픈(`format == .esm or format == .cjs`). 전역명 맵이 채워져 본문 참조·forwarding var 가 같은 `tag$1` 에 합의한다.
2. CJS forwarding 썽크의 **read** 를 전역명으로 정렬(chunks.zig): provider(ESM-wrap)는 `pm_wrapped_esm_provider`(#4528)로 `exports.tag$1` 을 내므로, `let tag$1; tag$1 = m.tag$1` 이 되도록 read 도 `crossChunkBindingName`(=provider export 키)로 읽는다. 예전 `m.tag`(자연명)는 undefined → `tag$1 is not a function`.

`pm_esm_wrap_dep_syms`(chunks.zig)는 **preserve-modules × CJS 출력 × ESM-wrap dep** 에서만 채워지므로 read 변경은 이 경로에 정밀 스코프된다.

`/code-review max` 반영:
- **reserved-name(`default`) read 회귀 수정**: read 를 `crossChunkBindingName` 으로 쓰면 reserved-name 이 전역명 없을 때(minify/dev) provider **로컬**(`foo`)을 반환해 `exports.default` 과 어긋난다(`m.foo` undefined → TypeError). read = **`전역명 orelse export명`**(provider export 키)으로 정정하고, 첫 루프에서 `pm_reads` 배열에 캡처해 재계산도 제거.
- **stale 주석 갱신**(chunk.zig): `pm_xchunk_naming` 이 CJS 를 포함하게 됐으므로 `import * as ns` fan-out(증상2) 게이트 주석을 `ESM/CJS` 로 갱신. CJS non-minify `import * as ns` 도 이제 동작(`1|hi`) — 부수 개선.

## 검증

- 증상1: CJS `BC`(수정 전 `BB`), ESM `BC`(무회귀).
- splitting+preserve+cjs `BC`, 증상3 배럴 `42|F`(CJS/ESM×plain/minify), pure-CJS 동명 `BC` — 무회귀.
- 회귀 가드: `preserve-modules-cjs.test.ts` 증상1 실행 가드(esm+cjs, node 실행 + 전역명 `tag$1` 방출 pin — 자연명 fallback 과 구분).
- preserve-modules(-cjs) 39+ pass, splitting 77 pass, zig 전체 test 통과.

## 잔여 (#4532 epic)

- **minify 증상1**: `!minify_identifiers` 로 제외 유지 — identifier mangler(`computeChunkMangling`)가 preserve-modules 서 skip 이라 전역명 미예약 → mangled local ↔ 전역명 충돌 위험. mangler 전역명 예약 후속(ESM-minify 도 동일하게 BB 인 기존 잔여).
- 증상4(multi-entry 순환), 배럴 자체 exports CJS 직접 `require("./r.js").X`(live getter) 도 별개 근본.
