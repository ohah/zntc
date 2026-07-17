---
"@zntc/core": patch
---

`--splitting` 에서 `import * as ns` 의 멤버(`ns.channel`)가 **다른 청크**에 있고 named-import 소비자가 없을 때 cross-chunk 등록이 누락돼 `ReferenceError` 나던 것 수정 (#4560).

```js
// pkg/channel.js:  export const channel = (c, ch) => ...;   // 공통 청크로 분리
// diagram1.js (lazy):
import * as k from "./pkg/channel.js";
function fade(c) { return k.channel(c, "r"); }   // 각 다이어그램이 자체 정의(중복)
export const d1 = () => fade({ r: 1 });
// entry.js:  Promise.all([import("./diagram1.js"), import("./diagram2.js")])
// 버그: diagram 청크서 bare `channel` → ReferenceError (mermaid.render() 크래시)
```

## 근본 원인

`k.channel` 은 linker(`registerNamespaceRewrites`)가 bare `channel` 로 **평탄화**하는데, direct leaf `import * as k` 의 멤버는 `computeCrossChunkLinks` 의 어느 경로도 소비자 청크 `imports_from` 에 등록하지 않는다. `import_bindings` 루프는 namespace binding 에 canonical 이 없어 skip, consumer-side 루프는 namespace **re-export**(`imported="*"`)만 잡는다. 그리고 그 멤버(`channel`)를 **named-import 로 소비하는 청크가 하나도 없으면**(오직 namespace 멤버 접근만) 아무도 cross-chunk 등록을 트리거하지 않는다 → 소비자 청크서 bare `channel` = 선언 없는 자유 변수 → `ReferenceError`.

실제 mermaid 에서 각 다이어그램(`flowDiagram-*.mjs` 등)이 `fade` 를 자체 정의하고 그 안에서 공통 청크의 `khroma.channel` 을 namespace 멤버로 부르는데, `channel` 은 오직 namespace 접근으로만 쓰여 lazy 다이어그램 청크에 bare 로 남았고 `mermaid.render()` 가 크래시했다.

rolldown 은 사용된 심볼의 `canonical_ref` 기반(symbol-usage) 이라 평탄화된 namespace 멤버도 자연히 cross-chunk 에 포함된다. zntc 는 import-binding 기반이라 이 표면을 놓쳤다.

## 수정

`computeCrossChunkLinks` 의 consumer-side namespace 루프 — #4532 증상2 에서 preserve-modules 용으로 넣은 **direct leaf namespace fan-out 브랜치**를 splitting 에도 발화시킨다. `nsReExportTarget` 이 null 인 direct `import * as ns` 이고 dep 가 다른 청크면 `fanOutModuleExports(chunk, dep)` 로 dep 의 export 를 `imports_from`/`exports_to` 에 등록 → 뒤이은 `computeCrossChunkGlobalNames` + provider export + 소비자 import·평탄화 rewrite 가 발화한다.

게이트: `const ns_fanout_ok = if (preserve_modules) pm_xchunk_naming else true;`
- **splitting**: 항상 (이 수정).
- **preserve-modules**: `pm_xchunk_naming`(ESM·non-minify·non-dev) 한정 — #4532 와 동일.
- CJS dep 은 cjsNs interop 별경로라 제외, `seen_ns_target` 로 같은 dep 반복 DFS dedup.

## 범위 / 한계 (code-review max 반영)

- **dedup 도메인 분리**: fan-out 은 `fanOutModuleExports` 만 하는 **부분 작업**이라, 풀 작업(`markNsCrossChunk`+`ensureSharedNsVar`+ns-객체 등록)을 하는 `linkNamespaceCrossChunk` 와 dedup set(`seen_ns_target`)을 공유하면 안 된다 — 공유 시 fan-out 이 먼저 dep 를 넣어 같은 청크의 뒤이은 `export * as ns`(re-export)·값-사용용 `linkNamespaceCrossChunkOnce` 를 조기 return 시켜 ns 객체 합성이 누락된다. **별도 `seen_ns_fanout` set** 으로 격리(fanOut 은 `seen_static` 으로 멱등이라 이중 호출 안전).
- **`!dev_mode` 게이트**: splitting 항도 dev 제외(`else !graph.dev_mode`). dev 는 namespace member rewrite 가 wrapped local 을 써 negotiated 전역명 경로를 안 타므로 preserve-modules 게이트(`pm_xchunk_naming` 이 이미 `!dev_mode`)와 동일하게 제외.
- **과등록(correctness-neutral)**: `linkReExportName` 이 `crossChunkExportIsShaken` 으로 **전역 dead export** 는 거르지만 "이 소비자가 실제 쓰는 멤버" 까지 추리진 않아 dep 의 live export 를 통째로 등록한다 → rolldown 의 per-usage canonical-ref 보다 약간 과등록(mermaid 실측 **~0.08% dead import**, 무해). per-consumer 정밀 등록은 후속.
- 회귀 가드: `split-runtime-smoke.test.ts` 에 `#4560` 실행 가드 — namespace 멤버가 다른 청크에 있고 named-import 소비자가 없는 구조를 dynamic import 로 node 실행(`d1:2,4 / d2:6,8`). 런타임뿐 아니라 **크로스-청크 경계**(diagram 청크가 `import{channel}from"./chunk-*"`)를 `readFileSync` 로 실제 검증 — 청킹 휴리스틱이 dep 를 복제해 fix 를 우회하면 fail.
