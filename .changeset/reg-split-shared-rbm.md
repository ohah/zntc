---
"@zntc/core": patch
---

reg_split(iife/umd/amd)·cjs 에서 **여러 entry 가 공유하는 `--run-before-main`** 이 common 청크로 갈 때 entry 가 그 init 을 잘못된 형태로 가져와 실패하던 것 수정 (#4555).

```js
// zntc --bundle a.js b.js --splitting --format=iife --run-before-main=setup.js
// (a·b 공유라 setup → common chunk)
```

## 근본

`emitRunBeforeMainCrossImports` 가 **포맷 무관하게 ESM `import { init_setup } from "chunk"`** 를 냈다:
- iife/umd/amd: 그 import 가 factory 함수 **안**이라 `SyntaxError`.
- cjs: CommonJS 출력에 ESM import → 로드 불가.
- esm 만 top-level import 라 유일하게 정상이었다.

메인 cross-chunk import 블록은 포맷별로 다르게 내는데(reg_split=`__zntc_require`, cjs=`require`, esm=`import`), RBM cross-import 만 그 분기를 안 타 항상 ESM 이었다.

## 수정

`emitRunBeforeMainCrossImports` 를 **포맷-aware** 로 — 메인 import 블록과 동일한 결합:
- reg_split → `const { init_setup } = __zntc_require("<reg_id>");` (레지스트리)
- cjs → `const { init_setup } = require("<path>");`
- esm → `import { init_setup } from "<path>";` (기존)

`reg_ids` 를 호출부에서 넘겨 dep 청크의 레지스트리 id 를 조회한다.

## 검증

- 회귀 스위트 `reg-split-shared-rbm.test.ts` 6종: iife/umd/amd(ESM import 없음=SyntaxError 제거)·iife 로드-순서 실행·cjs 직접 실행(`SETUP_DONE`)·esm 회귀 방지.
- polyfill-rbm 8·splitting(iife/umd/amd/cjs)·manual-chunks 85 통합 + zig 전체 무회귀.

## 한계

- iife/umd/amd multi-chunk 는 청크가 **로드 순서대로**(common → entry) 등록돼야 `__zntc_require` 가 동작한다(브라우저 script 태그 순서). 이는 RBM 이 아닌 **일반 cross-chunk 도 동일한 기존 제약** — 이 fix 로 RBM 이 그 메커니즘과 parity 가 된 것이고, Node 직접 실행의 common-청크 미로드는 별개 층. cjs/esm 은 require/import 가 청크를 로드하므로 직접 실행도 정상.
