---
"@zntc/core": patch
---

`--splitting --format=cjs --minify`(및 iife/umd/amd) 에서 **여러 entry 가 공유하는 `--run-before-main`** 이 common 청크로 갈 때, 그 wrapper init 명(`init_setup`)이 mangle 돼 `TypeError: init_setup is not a function` 나던 것 수정 (#4586).

```js
// common chunk (minify): var n = __esm({...}); exports.n = n;   // init_setup → n 으로 mangle
// entry a.js:            const { init_setup } = require("./chunk.js"); init_setup();  // ← undefined
```

## 근본

per-chunk mangler 가 common 청크에서 RBM 의 wrapper init(`esm_init`)을 짧은 이름(`n`)으로 mangle 하는데, entry 청크의 RBM cross-import(`emitRunBeforeMainCrossImports`)는 **canonical `init_setup`** 을 참조한다. RBM 은 entry 가 cross-chunk 로 그 init 을 참조하는 유일 케이스인데, 일반 cross-chunk export 처럼 `exported` 집합에 등록되지 않아 mangle 후보 제외에서 빠졌다(#4579 계열 per-chunk rename_table 타이밍).

## 수정

`collectUnifiedInput`(mangle 후보 수집)에서 **run_before_main 모듈의 wrapper init/require 를 mangle 후보에서 제외**(canonical 유지) — require_X 가 canonical 로 남는 것과 동형. RBM 은 드물어(RN 전용) canonical 유지의 size 비용은 무시 가능. `isRunBeforeMainModule`(graph.run_before_main_files 조회)로 판정.

## 검증

- `reg-split-shared-rbm.test.ts`: cjs `--minify` 직접 실행·iife `--minify` 로드-순서 실행이 `SETUP_DONE`(이전엔 파싱만 검증).
- splitting(cjs/iife/umd/amd)·polyfill-rbm·preserve-modules-minify·manual-chunks 136 통합 + zig 전체 무회귀.
