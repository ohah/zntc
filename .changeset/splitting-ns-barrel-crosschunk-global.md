---
"@zntc/core": patch
---

`--splitting` 에서 `import * as ns` 의 멤버(`ns.max`)가 **재-export 배럴**을 통해 오고 그 멤버가 다른 lib 와 전역 충돌해 `max$1` 로 deconflict 될 때, 소비자 본문이 bare `max` 로 남아 `ReferenceError` 나던 것 수정 (#4564).

```js
// libA.js:  export const max = (arr) => ...;   // 다른 lib 의 max 와 전역 충돌 → max$1
// barrel.js: export * from "./libA.js";         // 재-export만 (lodash-es 배럴 위상)
// diagram.js (lazy):
import * as _ from "./barrel.js";
export const d = () => _.max([3, 1, 4]);         // 버그: ReferenceError: max is not defined
```

실제 mermaid: dagre 가 `import * as _ from "lodash-es"; _.max(...)` 하는데, lodash-es 는 `max` 를 재-export만 하고 `max` 는 d3 등 다른 lib 의 `max` 와 전역 충돌해 `max$1` 로 deconflict → `mermaid.render()` 가 `max is not defined` 로 크래시했다. (#4560 `channel` 을 고친 뒤 드러난 다음 블로커.)

## 근본 원인

`_.max` 는 linker 의 `registerNamespaceRewrites` 가 bare 멤버로 **평탄화**하며 cross-chunk 전역 공개명을 붙여야 하는데, 전역명을 **namespace 소스(`target_mod_idx` = 배럴)** 키로 조회한다. 배럴은 `max` 를 **정의하지 않고 재-export만** 하므로 `(배럴, "max")` 전역명 키가 없다 → miss → `exp.local`(`max`) fallback. 그런데 cross-chunk import 는 **canonical(libA) 기준** 전역명 `max$1` 을 노출한다 → 본문 `max` vs import `max$1` 불일치 → `ReferenceError`. 전역명은 `(canonical_module, export_name)` 키로 등록·소비되는데(import 등록은 체인 끝 canonical 사용) 본문 평탄화만 배럴(중간) 키로 조회해 발산했다.

## 수정

namespace 멤버 전역명 해석을 `crossChunkNsMemberName` 헬퍼로 통합:

1. **canonical 기준 게이트+조회**: source(배럴) 키 조회가 miss 면 `resolveExportChain(source, member)` 으로 canonical(정의 모듈)을 해석해 **그 키**로 재조회한다(체인 끝 = import 등록과 동일 키). `isCrossChunkConsumer` 게이트도 **각 키의 정의 모듈** 기준 — 배럴이 소비자와 같은 청크여도 정의 모듈이 다른 청크로 split 되면 전역명이 필요하기 때문(import rename 경로 `metadata.zig` 와 canonical 기준으로 일치).
2. **네 개의 형제 사이트에 모두 적용** (code-review max 반영): main 평탄화 / `allocNamespaceMemberRewriteValue`(init-식 `(init(), member)`) / `buildInlineObjectStr` getter(value-namespace) / `allocNamespaceGetterValue`. 모두 같은 canonical 해석을 쓴다.
3. **synthetic_named_exports**: canonical 이 컨테이너 export 를 가리키고 실제 멤버는 `synthetic_member` 면 `<global>.<member>` 로 접근(전체 축약 금지).

## 검증

- 실제 mermaid: flowchart/sequence/gantt/class/state/pie/er/journey/git **9종 전부 headless 브라우저 렌더 성공**(`--splitting --minify --format=esm`). 산출물에 bare `max` 잔여 0.
- 회귀 가드: `split-runtime-smoke.test.ts` 에 `#4564` 실행 가드 — 재-export 배럴 경유 namespace 멤버 + 전역 충돌을 dynamic import 로 node 실행(`5|A:d1 / 9|A:d2 / 2 / 1`) + cross-chunk 구조를 minify-robust 마커(문자열 `"A:"`)로 확인. 수정 전 bare `max` → `ReferenceError` 재현 확인.
- zig 전체 test + 통합 스위트(4267) 무회귀.
