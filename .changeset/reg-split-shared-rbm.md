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

## `/code-review max` 반영

- **[3]** cjs-wrap RBM 이 청크에서 raw-require 되면 메인 cross-chunk 블록(#4541)이 `const require_X =
  function(){…}` forwarding 으로 이미 바인딩 → RBM cross-import 가 또 `const {require_X}=require()` 를
  내면 **이중 선언 SyntaxError**(재현). 청크가 raw-require 하면 cross-import skip(메인 바인딩 재사용),
  안 하면(run_before_main 만) 유지. esm-wrap 은 항상 유지.
- **[4]** dep 경로에서 `explicit_file_name` 을 `preserve_modules` 보다 먼저 검사(메인 블록·파일명
  생성부와 동일 순서). **[2][5]** importer_dir·결합 형태를 루프 밖으로. **[0][1]** 테스트에 minify·
  `node --check` 파싱 검증·umd 런타임·cjs-wrap 두 케이스 추가.

## 검증

- 회귀 스위트 `reg-split-shared-rbm.test.ts` 13종: iife/umd/amd(ESM import 없음+파싱 유효, minify 포함)·
  iife/umd 로드-순서 실행·cjs 직접 실행(`SETUP_DONE`)·esm 회귀·cjs-wrap RBM(import함/안함)·cjs minify 파싱.
- polyfill-rbm 8·splitting·preserve-modules-cjs·manual-chunks 175 통합 + zig 전체 무회귀.

## 한계

- **cjs `--minify` RBM**: common 청크가 wrapper 명 `init_X` 를 mangle(`n`)하는데 entry 는 미mangle
  `init_setup` 참조 → `init_setup is not a function`. #4579 계열 per-chunk rename_table 발산으로 이 fix
  범위 밖(non-minify·reg_split 은 정상). RBM 이 wrapper init 을 **명시 호출·cross-chunk 바인딩**하는
  유일 케이스라 일반 side-effect import(init 미호출)엔 없음. 별도 후속.

- iife/umd/amd multi-chunk 는 청크가 **로드 순서대로**(common → entry) 등록돼야 `__zntc_require` 가 동작한다(브라우저 script 태그 순서). 이는 RBM 이 아닌 **일반 cross-chunk 도 동일한 기존 제약** — 이 fix 로 RBM 이 그 메커니즘과 parity 가 된 것이고, Node 직접 실행의 common-청크 미로드는 별개 층. cjs/esm 은 require/import 가 청크를 로드하므로 직접 실행도 정상.
