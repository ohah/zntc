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

`collectUnifiedInput`(mangle 후보 수집)에서 **run_before_main 모듈의 wrapper init/require 를 mangle 후보에서 제외**(canonical 유지) — require_X 가 canonical 로 남는 것과 동형. RBM 은 드물어(RN 전용) canonical 유지의 size 비용은 무시 가능.

추가로, `--runtime-polyfills=auto`(core-js) 로 주입되는 폴리필 RBM 도 같은 발산이 있었다:
`graph.run_before_main_files` 미러가 폴리필 merge **전** 에 스냅샷돼(bundler.zig 1323) 폴리필 root 를 놓쳤고, mangle 제외가 stale 미러를 봐서 `require_core_js_modules_es_array_at is not a function` 로 터졌다.
폴리필 merge 지점에서 **미러를 merged 리스트로 동기화**해 근본 해소. 제외 판정은 RBM 인덱스 집합을 **루프 전 1회** 구축해 O(1) 조회(findModuleByPath 를 per-symbol 재계산하던 O(mod×sym×rbm×N) 제거).

## 검증

- `reg-split-shared-rbm.test.ts`: cjs/umd/iife `--minify` 직접·로드-순서 실행이 `SETUP_DONE`(이전엔 파싱만 검증).
- 폴리필 RBM: 2-entry `--splitting --format=cjs --minify --runtime-polyfills=auto --runtime-target='safari 5'` 직접 실행(수정 전 `require_core_js_... is not a function` → 수정 후 정상).
- splitting(cjs/iife/umd/amd)·polyfill-rbm·preserve-modules-minify·manual-chunks 통합 + zig 전체 무회귀.
