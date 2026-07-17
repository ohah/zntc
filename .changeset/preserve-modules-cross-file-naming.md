---
"@zntc/core": patch
---

`--preserve-modules`(ESM 출력)에서 서로 다른 wrap 된 파일의 **동명 심볼이 소비자 본문에서 붕괴**하던 조용한 오컴파일 수정 (#4532 증상1).

`--splitting` 에는 있는 파일 간 심볼 네이밍 인프라(`computeCrossChunkGlobalNames` + 소비자 본문 참조 rewrite)가 preserve-modules 에선 `code_splitting and !preserve_modules` 로 꺼져 있었다. 그래서 두 wrap 된 dep 이 각각 `tag` 를 export 하고 소비자가 둘 다 참조하면:

```js
// b.js (a.cjs 가 require 해 ESM-wrap): export function tag(){ return "B"; }
// c.js (동일):                          export function tag(){ return "C"; }
// entry.js:
import { tag } from "./b.js";
import { tag as tag2 } from "./c.js";
console.log(tag() + tag2());
```

| | 결과 |
|---|---|
| node 정본 · `--splitting` | `BC` |
| `--preserve-modules` (수정 전) | **`BB`** ❌ (두 참조가 한 이름으로 붕괴) |
| `--preserve-modules` (수정 후) | `BC` ✅ |

## 수정

두 게이트를 preserve-modules(ESM 출력)에도 연다:
- **`module_to_chunk` 대여**(`isCrossChunkConsumer` 의 숨은 스위치) — 없으면 소비자 본문 rewrite 가 죽는다.
- **`computeCrossChunkGlobalNames`** — 단 **ESM-wrap owner 로 한정**. non-wrap ESM 은 자연명 export, CJS owner 는 re-export barrel 배선(증상3)이 아직 없어, 전역명을 붙이면 provider/consumer 가 어긋난다. ESM-wrap owner 만 provider emit(`pm_wrapped_esm_provider`, #4528)이 전역명을 노출해 양측이 합의된다.

## 범위

- **ESM 출력 + non-minify 한정**:
  - CJS 출력은 소비자가 bare 전역명을 bind 못 해(`require` 라 `var tag$1 = require_c().tag$1` materialize 필요) → 후속.
  - minify 는 identifier mangler 가 전역명을 예약하지 않아(`computeChunkMangling` 은 `code_splitting` 게이트라 preserve-modules 서 skip) 대형 빌드서 mangled local 과 충돌 위험 → 후속.
  - 게이트(`(code_splitting and !preserve_modules) or (preserve_modules and format==.esm and !minify_identifiers)`)로 splitting·CJS-format·minify 는 모두 pre-existing 동작 유지(회귀 없음).
- 증상 2(`import * as ns` 미바인딩) / 증상 3(re-export barrel 스냅샷) / 증상 4(multi-entry 순환)는 네이밍이 자리잡은 뒤 후속 (#4532 잔여).
- 회귀 가드: `preserve-modules-cjs.test.ts` 에 동명 심볼 실행 가드(`BC`) + 네이밍 경로 pin(`tag$1` 방출) 추가 — node 로 실제 실행.
