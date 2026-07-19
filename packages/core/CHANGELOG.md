# @zntc/core

## 0.1.4

### Patch Changes

- 4cd691e: CJS interop 잔여 결함 3건 수정 (#4510). #4494(크로스-청크 CJS 의 **직접** named/default import)가 못 덮은 표면들로, 셋 다 별개 루트커즈다.
  1. **크로스-청크 `import * as ns from './x.cjs'`** — namespace 합성 경로는 #4494 의 크로스-청크 심볼 등록 기계를 타지 않아 소비자 청크에서 `require_X` 썽크가 undefined 였다. 합성 ns 도 provider 청크의 썽크를 크로스-청크 심볼로 등록한다.

  2. **비-식별자 멤버명** — `import { 'foo-bar' as x } from './x.cjs'` 가 `require_x()."foo-bar"` 로 방출돼 **문법 오류**였다. splitting 없이도 실패하는 preamble-writer 버그로, bracket 표기(`["foo-bar"]`)로 수정.

  3. **동적 import 의 `.default`** — `(await import('./x.cjs')).default` 가 undefined 였다. 동적 경로가 `__toESM` 의 default 합성을 거치지 않았다.

  전부 빌드 exit 0 · 파싱 통과 · **실행만** 실패하는 계열이라 실행 스모크로 가드했다.

  추가(코드리뷰): 2번(비-식별자 멤버명) 수정으로 quoted 이름이 CJS interop 배선을 타게 되면서 **새 구멍**이 드러났다.
  - `import { "default" as d } from './x.cjs'` — ES2022 arbitrary module namespace name. binding_scanner 는 이름을 **따옴표째** 저장하는데(`"\"default\""`) default 판정 3곳이 bare `"default"` 와만 비교해서, 이 형태가 default-interop 을 통째로 비껴가 `require_x()["default"]` = **undefined** 가 됐다. 수정 전에는 `require_x()."default"` 라는 **문법 오류**(loud)였는데 2번 수정이 그걸 valid-but-wrong 으로 바꿨다. 판정을 `preamble_writer.isDefaultExportName` 단일 소스로 묶었다 (node/esbuild 는 `import d from` 과 동일 취급).
  - cross-chunk 공개명 sanitize 가 **CJS owner 분기에만** 걸려 있었다. ESM 재-export 로 로컬명이 없으면 quoted export 명이 그대로 전역 이름이 되어 `var "a-b"` — 파싱 불가. 비-CJS 분기에도 적용했다.
  - 새 `preamble_writer_test.zig` 가 **어디서도 import 되지 않아** Zig 테스트 discovery 에 안 잡혔다(회귀 가드 5건이 CI 에서 아예 안 돌고 있었다). `bundler/mod.zig` 에 등록.

- 345d2cc: `--splitting --format=cjs --minify`(및 iife/umd/amd) 에서 **여러 entry 가 공유하는 `--run-before-main`** 이 common 청크로 갈 때, 그 wrapper init 명(`init_setup`)이 mangle 돼 `TypeError: init_setup is not a function` 나던 것 수정 (#4586).

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

- d916ea3: `--minify` 시 CJS 모듈이 많으면 **모듈 게터가 CJS 래퍼 파라미터에 섀도잉되어** 런타임에 죽던 버그 수정 (#4491).

  ```
  TypeError: $m is not a function
  ```

  CJS 래퍼는 고정 파라미터 이름을 쓴다 — `$c(($e, $m) => { /* 모듈 본문 */ })`. 그런데 mangler 가 `$m` 을 예약하지 않아, 모듈이 많아져 이름 풀이 `$` 영역까지 내려오면 **모듈 게터에 `$m` 을 배정**했다. 그 게터를 다른 CJS 래퍼 안에서 참조하면 래퍼의 `$m` 파라미터(= module 객체)가 게터를 가린다.

  `highlight.js@11` 은 언어 모듈이 190개 이상이라 자연히 이 조건에 걸렸다. **빌드 exit 0 + 산출물 파싱 통과 + 실행만 실패** 라, 산출물 재파싱 게이트로도 못 잡히는 계열이다 — 번들을 실제로 실행하는 스모크 게이트를 함께 추가했다.

- 43245e6: `--splitting` 에서 **다른 청크의 CJS 모듈을 직접 import** 하면 실행이 `ReferenceError` 로 죽던 버그 수정 (#4494).

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
  - **CJS owner 는 항상 materialize**. 예전엔 "동명 로컬이 있으면 interop 불요" 로 판단했는데, 그 로컬은 `__commonJS` 클로저 _안_ 심볼이었다 — minify 시 `export { o as tag }` 로 클로저 스코프 이름을 노출해 `SyntaxError: Export 'o' is not defined`. (#4120 re-export 경로에도 있던 선재 버그.)
  - dev/lazy 의 cross-chunk 전역명 override 가 CJS 클로저 내부 심볼을 개명하던 문제.

  provider 가 실제로 materialize 하지 못하는 구성(preserve-modules, 비-ESM 포맷 + provider 가 entry 청크)에서는 **등록하지 않는다** — 소비자만 preamble 을 억제하면 값이 조용히 `undefined` 가 되어, 기존의 시끄러운 ReferenceError 보다 나빠지기 때문이다.

- c0cc120: 코드 스플리팅 + `--minify` 에서 **같은 청크 안의 참조가 자유 변수로 남아** 런타임에 죽던 버그 수정 (#4492).

  ```
  ReferenceError: second is not defined
  ```

  크로스-청크 전역 일관 네이밍(#4101)이 import 참조를 재작성할 때, **소비자가 provider 와 다른 청크인지 검사하지 않았다.** 전역명 맵은 `(canonical module, export)` 키라 "다른 **어떤** 청크가 이 심볼을 소비하는가" 만 말해준다 — 누가 묻는지는 모른다. 그래서 provider 와 **같은 청크**에 있는 소비자까지 그 청크 바깥에서만 존재하는 공개명(`exports.second` 의 좌변)으로 본문을 재작성했다. `minify_identifiers` 로 로컬이 `n` 으로 mangle 되면 `second` 는 선언이 없는 자유 변수가 된다.

  형제 호출부(CJS interop / entry exports)는 이미 `isCrossChunkConsumer` 로 게이트하고 있었다. 게이트가 빠진 곳은 **세 곳** — named import 의 본문 참조 rename, `importBindingName`(CJS/wrapped preamble), 그리고 `import * as ns` 의 멤버 재작성이다.

  materialize 된 ns 객체의 **getter** 에도 같은 결함이 남아 있지만 이번 수정에 포함하지 않았다 — 그 경로는 참조 이름이 아직 deconflict 되기 전이라 전역명을 그 대리물로 쓰고 있어, 순진하게 게이트하면 동명 const 두 개가 collapse 된다 (#4101 회귀). 별도 이슈(#4502)로 분리.

  `mermaid` 를 `--minify` 로 번들하면 d3-time 의 `second` 가 정확히 이 형태로 깨졌다. **빌드 exit 0 + 산출물 104개 전부 파싱 통과 + 실행만 실패**라 재파싱 게이트로는 못 잡힌다 — 번들을 실제로 실행하는 스모크를 함께 추가했다.

- 5b8b6b2: `--splitting` 에서 raw `require("./x.cjs")` 한 CJS 가 common chunk 에 안착하면 그 `require_X` 썽크가 cross-chunk 미노출돼 `ReferenceError` 나던 버그 수정 (#4541).

  ## 증상

  raw `require("./x.cjs")` 로 다른 청크의 CJS 를 참조하면, 소비자 청크는 `import "./chunk"`(side-effect)만 하고 `require_X()` 를 **import 없이** 참조 → provider 청크에만 있는 `require_X` = free variable → `ReferenceError: require_X is not defined`. 빌드 exit 0 · 파싱 통과 · 실행만 실패.

  ## 루트커즈

  `computeCrossChunkLinks`(chunk.zig)는 cross-chunk 심볼을 **`import_bindings` 순회**로만 등록한다. raw `require()` 는 ImportBinding 이 없어(`kind=.require`) `require_X` 가 `exports_to`/`imports_from` 에 안 들어간다(chunk-level 의존 edge=side-effect import 만 생성). `import` 경로(#4494/#4522)는 provider 가 interop 값을 materialize+export 하지만, raw-require 는 그 경로를 안 탄다. wrapper 심볼(`require_X`, scope_id=.none)은 rename 풀에도 없어 심볼 기계가 구조적으로 못 본다.

  ## 수정

  esbuild/rolldown 동형 — provider 가 썽크를 **export**, 소비자가 **import** 후 `require_X()`. raw `require` 는 **lazy**(호출 시점 평가)라 import-path 의 eager materialize(`default$X=require_X()`)를 재사용하지 않고 썽크 자체를 넘긴다.
  - `Chunk.wrapper_cross_exports`/`wrapper_cross_imports` 필드 추가 — import-path 의 exports_to/imports_from(export명 키) 기계와 분리(래퍼는 export명이 없음).
  - `computeCrossChunkLinks` 에 raw-require 루프: `kind==.require` + CJS 타겟 + 다른 청크면 provider 에 export 표시·소비자에 import 표시.
  - provider emit: `export { <로컬> as require_X }`(esm) / `exports.require_X = <로컬>`(cjs). ⚠️ `--minify` 는 provider 본문 선언을 mangle(`r`)하나 소비자는 canonical `require_X` 로 import·호출 → **로컬(mangled)→공개(canonical) aliasing** 으로 3자 일치.
  - 소비자 emit: `import { require_X }`(esm, live binding) / cjs 는 **lazy forwarding**(`require("...");` side-effect + `const require_X = function(){ return require("...").require_X.apply(this,arguments); }`) — `const{require_X}=require(...)` 구조분해는 CJS↔CJS cross-chunk 순환에서 로드 시점 스냅샷(undefined 박제) 위험이라 호출 시점 조회로 지연 복원(#4526 계열).
  - `buildRequireRewrites` 는 `require_X()` 그대로(변경 불요).

  ## 범위

  esm·cjs 포맷. **preserve-modules 는 #4524 가 자체 wrapper 기계로 담당**하므로 제외(게이트). **iife/umd/amd(reg_split)는 registry 모델이라 후속.**

  검증: zig 6227/6227 · split-cjs-cross-chunk #4541 가드 esm/cjs × plain/minify 4종(node 실행) · 인접 splitting/preserve-modules 152 pass · effect/zod/three byte-identical.

  Closes #4541

  ## code-review 반영
  - **[r0] cjs 순환 lazy forwarding**: cjs 소비자가 `const{require_X}=require(...)` 로 로드 시점 구조분해하면 CJS↔CJS cross-chunk 순환에서 provider 의 `exports.require_X` 미할당 시점을 스냅샷 → TypeError(#4526 계열). require_X 는 함수라 `const require_X = function(){ return require("...").require_X.apply(this,arguments); }` **호출 시점 조회**로 지연 복원. esm 은 live binding 이라 named import 유지. 순환 가드 추가.
  - **[r1] reset 멱등**: `computeCrossChunkLinks` reset 루프에 새 `wrapper_cross_exports`/`wrapper_cross_imports` clear 추가(재실행/HMR re-link 시 stale export 방지).

- 3400ae1: CSS `url(logo.png)` 처럼 `./` 가 없는 bare 상대 지정자도 자산으로 재작성한다 (#4485).

  CSS 스펙상 `url()` 의 상대 참조는 **스타일시트 자신의 URL** 이 base 다. 그래서 `"logo.png"` 와 `"./logo.png"` 는 같은 파일을 가리켜야 한다. 그런데 지금까지 zntc 는 `./` 가 붙은 것만 재작성하고, bare 형태는 npm 패키지 이름으로 보고 `node_modules` 를 뒤졌다 → resolve 실패 → 경고만 남기고 원문 그대로 방출 → **런타임 404**.

  ```css
  .a {
    background: url(./logo.png);
  } /* → url("./logo-1c4d8b20.png") ✅ */
  .b {
    background: url(logo.png);
  } /* → url(logo.png) ❌ 404 */
  ```

  #4483(worker 지정자)과 같은 루트커즈이며, 같은 처방을 `url()` 에 확장했다. resolve 레이어에서 **기존 해석을 먼저 시도하고, 못 찾았을 때만** `./` 를 붙여 재시도한다.
  - `url(imgpkg/pic.png)` 처럼 지금 `node_modules` 패키지로 해석되던 bare url() 은 **그대로 패키지가 이긴다** (기존 동작 보존 — "패키지 우선 + 상대 폴백").
  - `--platform=node` 에서 `url(path/logo.png)` / `url(url/x.png)` 처럼 첫 세그먼트가 Node 빌트인 이름과 겹치던 자산 디렉토리가 external 로 빠져 원문 방출되던 것도 함께 고쳤다 — CSS 의 `url()` 은 파일 참조지 모듈 지정자가 아니다 (worker 도 동일).
  - scheme 있는 절대 URL(`https:` / `data:` / `blob:`), protocol-relative(`//cdn/x.png`), root-absolute(`/logo.png`), `url(#blur)` 는 그대로 둔다.
  - `?query` / `#fragment` suffix 는 종전처럼 보존된다 (`url(f.eot?#iefix)`).
  - 알려진 한계: `--packages=external` 을 켜면 bare url() 은 여전히 패키지로 간주돼 external 로 빠진다(원문 방출). 이 경우 `url(./logo.png)` 로 쓰면 정상 재작성된다.

- 5886863: `--minify` 의 **dead-store 제거가 살아 있는 대입문을 삭제**하던 무성 오컴파일 수정 (#4503).

  ```js
  let buf = '';
  function flush() {
    out.push(buf);
  } // ← buf 를 클로저로 읽는다
  function emit(t) {
    buf = t; // ← dead 가 아니다. 사이의 flush() 가 읽는다.
    flush();
    buf = '';
  }
  ```

  `buf = t` 가 통째로 삭제됐다. **빌드 exit 0 · 산출물 파싱 통과 · 런타임 에러 0 · 값만 틀림** — 기존 게이트를 전부 통과하는 계열이다. `highlight.js@11` 코어의 `emitMultiClass` 가 정확히 이 패턴이라, 하이라이팅 결과가 `functionfunction f f(a)` 처럼 깨져 나왔다.

  **원인.** DSE 는 두 store 사이에 read 가 있는지를 `Reference` 배열의 위치, 즉 **소스 순서**로 판정한다. 그런데 소스 순서가 실행 순서와 같은 것은 *한 함수의 한 활성화 안에서 straight-line 으로 흐를 때뿐*이다. 이 가정이 깨지는 세 경우를 모두 놓치고 있었다:
  1. **클로저 읽기** — 클로저 안의 read 는 소스 위치가 두 store 밖이라 안 보이지만, 실제로는 사이의 호출 시점에 일어난다.
  2. **재진입** — read/write 가 같은 함수 안이어도 변수가 함수 **밖** 에 선언됐으면 호출이 겹칠 때 바인딩을 공유한다. 사이의 호출이 재귀하거나 `await` 로 인터리빙되면 _다른 활성화_ 가 앞 store 의 값을 읽는다.
  3. **abrupt completion** — `x = 1; if (c) break lbl; x = 2;` 처럼 사이에서 흐름이 끊기면 뒤 store 가 실행되지 않아 앞 store 가 살아남는다.

  **처방.** 판정이 불확실하면 항상 "유지"(보수적)로 간다.
  - read 가 write 와 **다른 실행 단위**(함수/클래스 본문)에 하나라도 있으면 제거 금지.
  - 변수의 **선언 실행 단위 ≠ write 실행 단위** 면 제거 금지 (재진입 차단).
  - 두 store 사이 statement 가 **바깥 흐름을 끊으면** 제거 금지. 단, 그 사이에 _완전히 포함된_ loop/switch 에 묶이는 라벨 없는 `break`/`continue` 와 중첩 함수·메서드의 `return` 은 바깥 흐름과 무관하므로 계속 제거 대상이다.

  진짜 dead store(함수 지역변수를 그 함수 안에서 덮어쓰는, DSE 수익의 대부분)는 그대로 제거된다. 대표 라이브러리 11종 실측 size 영향은 **+11 B / 847 KB (+0.0013%)** 이고, 그 +11 B 는 highlight.js 에서 되살아난 대입문 자체다.

- 51ff984: dead-store 제거가 **평가 부수효과까지 삭제**하던 무성 오컴파일 수정 (#4514).

  ```js
  let x = obj.p; // obj.p 가 getter 면 평가 자체가 부수효과
  x = 2; // 버그: `x = obj.p` 삭제 → getter 미호출

  let y = a.b.c; // a.b 가 undefined 면 TypeError
  y = 2; // 버그: 삭제 → TypeError 안 던짐

  let z = undeclaredGlobal; // ReferenceError
  z = 2; // 버그: 삭제 → 안 던짐
  ```

  근본 원인: dead-store 가 **tree-shaking 용** purity 판정(`purity.isExprPure`)을 썼다. 그건 "이 **선언을 안 만들어도** 되는가" 기준이라 member access 와 미해결 식별자를 pure 로 친다(esbuild 동일). 하지만 dead-store 는 **이미 실행되기로 확정된 표현식을 삭제**하는 패스라, 문 자리 DCE 와 같은 엄격 술어를 써야 한다. 두 패스가 이제 `purity.isRemovableAtStmtPos` 하나를 공유한다.

  함께 수정: 비엄격 함수의 **파라미터** 는 `arguments` 객체와 양방향 aliasing (mapped arguments) 이라 `arguments[0]` 읽기가 참조 배열에 안 잡힌다 — 파라미터 store 는 제거하지 않는다.

  진짜 dead store(부수효과 없는 리터럴·지역 식별자·순수 연산)는 계속 제거된다. 대표 라이브러리 12종 `--minify` 산출물은 **byte-identical**(size 영향 0).

  추가(코드리뷰): 통합한 술어를 **쓰지 않던 두 호출부**가 남아 있었다. `isStmtRemovable(operand)` 은 "이 표현식의 **평가**를 없애도 되는가" 를 답하는데, 강제 변환 연산에서는 operand 의 **값이 관측**된다 — 술어를 잘못된 질문에 쓴 것이다.
  - `rewriteBinaryUnused` 가 `+`/`==`/`<`/`in`/`instanceof` 까지 "양쪽 operand 가 removable 이면 전체 removable" 로 봤다. `({valueOf(){…}}) + 1;` 이 통째로 삭제돼 **valueOf 가 안 불린다**. 강제 변환이 전혀 없는 `===`/`!==` 만 손대도록 좁혔다 (esbuild 도 `1 < foo()` 를 건드리지 않는다).
  - `rewriteObjectUnused` 가 computed key 표현식을 drop 했다. key 는 평가만 되는 게 아니라 그 **값에 ToPropertyKey** 가 걸려 `toString` 이 불린다. computed key 가 있으면 객체를 통째로 유지한다 (esbuild 는 `foo() + ""` 로 강제 변환을 보존한 채 추출한다 — zntc 는 그 합성 대신 보존을 택했다).

  기존 minify 테스트 3건이 이 불건전한 축약을 **박제**하고 있어 함께 갱신했다(node 정본으로 확인 — 셋 다 부수효과가 실제로 호출된다).

- 07eb2ba: `--minify` 시 **구조분해 할당의 shorthand + 기본값** 프로퍼티에서 리네임이 누락돼 런타임에 죽던 버그 수정 (#4493).

  ```
  ReferenceError: stackWeight is not defined
  ```

  `({ position: pos, options: { stack, stackWeight = 1 } } = box)` 가 이렇게 방출됐다.

  ```js
  var t, n, r;
  ({
    position: t,
    options: { stack: n, stackWeight: stackWeight = 1 },
  } = box); // ← value 가 원본 이름
  ```

  `stack`(기본값 없는 shorthand)은 `stack:n` 으로 제대로 확장되는데, `stackWeight`(기본값 있는 shorthand)만 value 위치가 **원본 이름 그대로** 남았다. 결과적으로 미선언 전역에 대입되고(strict ESM → `ReferenceError`), 진짜 지역 변수 `r` 은 영영 대입되지 않는다.

  원인: `({x = 1} = o)` 는 cover grammar 로 `assignment_target_property_identifier`(left=바인딩, right=기본값)가 된다. 이걸 longhand `key:value=default` 로 펼칠 때 **value 위치를 원본 span 으로 복사**해 mangler 리네임과 namespace 치환을 통째로 건너뛰었다. key(프로퍼티 이름)는 원본을 보존하되 value(바인딩)는 치환을 따라가도록 고쳤다.

  선언형(`let {x = 1} = o`)이 아니라 **할당형**(`({x = 1} = o)`)이기만 하면 중첩 여부와 무관하게(최상위 포함) 샜다. `chart.js@4` 의 `buildStacks` 가 정확히 이 패턴을 써서 차트를 렌더할 때 죽었다.

  같은 리네임 누락이 두 곳 더 있어 함께 고쳤다.
  - **es5 다운레벨**: es5 에서는 codegen 이 아니라 transformer 가 구조분해를 풀어낸다. 이때 합성한 대입 타겟 노드에 symbol_id 를 물려주지 않아, 같은 버그가 다른 emit 경로로 재현됐다.
  - **TS namespace**: `namespace N { export let x; ({x = 1} = o); }` 가 `({x:x=1}=o)` 로 방출돼 `N.x` 가 아니라 자유 변수(전역)에 대입됐다 — `--minify` 와 무관하게 값이 조용히 틀리던 표면이다.

  **빌드 exit 0 + 산출물 파싱 통과 + 모듈 평가까지 통과**하고 해당 함수를 **호출할 때만** 터지는 계열이라, 번들을 실제로 실행해 값을 확인하는 스모크 게이트를 함께 추가했다. non-strict 포맷에서는 같은 코드가 조용히 전역을 만들고 지역 변수는 `undefined` 로 남는 **무성 오염**이 된다.

- 20b3d1f: code-split 된 **동적 CJS import** 가 named 멤버를 잃던 무성 오컴파일 수정 (#4522).

  ```js
  // legacy.cjs
  module.exports = {
    foo() {
      return 'FOO';
    },
    bar: 42,
  };

  const m = await import('./legacy.cjs');
  m.foo();
  ```

  |                   | code-split 시 `keys` | `m.foo()`      |
  | ----------------- | -------------------- | -------------- |
  | node (정본)       | `default, foo`       | ✅             |
  | zntc (버그)       | `default`            | ❌ `TypeError` |
  | rolldown / rspack | named 포함           | ✅             |

  **같은 소스가 청킹 설정에 따라 런타임 값이 갈렸다** — 인라인(단일 번들)은 정상, `--splitting` 만 깨졌다. 빌드 exit 0 · 파싱 통과 · 실행만 실패.

  근본 원인: 동적 CJS entry 청크가 CJS↔ESM interop 결과(namespace)를 **`default` 슬롯 하나로 좁혀서** 내보냈다. CJS 는 정적 export 가 없어 named 멤버를 ESM `export` 문법으로 **표현할 수 없으므로** 그대로 유실된다. 같은-청크 경로는 `import()` **호출 자체**를 `__toESM(require_x())` 표현식으로 치환하니 namespace 가 통째로 살아남아서, 두 경로가 갈렸다.

  처방(rolldown 동형): 청크가 **namespace 를 통째로** 실어 보내고(`export default __toESM(require_x())`), 소비자가 `.default` 로 한 겹 벗긴다. esm / cjs / iife·umd·amd 세 형식 모두 동일하게 적용된다. 이제 인라인과 splitting 이 **같은 값**을 만든다.

  함께 수정: 동적 entry 청크의 `__toESM` 헬퍼 주입 조건에서 `can_skip_cjs_default_interop` 예외를 제거했다. 그 예외는 "`default` 값 하나만 내보내던" 시절의 것으로, namespace 를 보내는 지금은 shape 와 무관하게 항상 헬퍼가 필요하다(안 그러면 `ReferenceError: __toESM is not defined`).

  추가(코드리뷰): 첫 수정이 **하드 회귀 4건**을 만들었고 전부 잡았다.
  - 소비자 재작성을 `rewriteImportCallToWrapper`(첫 `indexOf` 1회 + import attributes 미지원)로 바꾼 탓에, **앞선 문자열 리터럴 occurrence** 나 `import("./x.cjs", { with: {} })` 에서 specifier 가 통째로 미치환 → `ERR_MODULE_NOT_FOUND`. #4295 가 고쳤던 바로 그 miscompile 이다. 같은 positional walk 를 쓰되 호출 끝을 **괄호 균형**으로 찾는 재작성기로 다시 썼다.
  - provider 는 `linker orelse break` 로 bail 하는데 consumer 는 `linker` 를 안 봐서, `scopeHoist: false`(linker null)에서 export 가 없는 값을 `.default` 로 벗겨 **TypeError**. provider/consumer/헬퍼 3곳의 복붙 술어를 `dynamicCjsNamespaceEntry` 단일 소스로 합쳤다.
  - federation expose / plugin `emitFile({type:'chunk'})` 도 **같은 dynamic entry 모양**이라 provider 만 바뀌고 그쪽 소비자(container factory / 사용자 코드)는 안 벗긴다 → `default` 슬롯 의미가 조용히 바뀐다. entry 에 `is_import_call` 을 달아 **진짜 `import()` 대상만** namespace 로 가고, 그 둘은 기존 계약을 그대로 유지한다.

- 4cd691e: 인라인되는 dynamic import 의 모듈 방출 순서가 **의존성 역순**이라 TDZ `ReferenceError` 가 나던 버그 수정 (#4520).

  ```
  entry → a → b → barrel → prov       ← 방출 순서 (버그)
  ReferenceError: Cannot access 'second' before initialization
  ```

  정적 import 는 post-order(의존성 먼저)로 방출 순서를 정하는데, **인라인되는 dynamic import 는 그 계산에 참여하지 않고** 발견 순서로 뒤에 붙었다. 그래서 동적 진입점 아래 서브그래프가 통째로 역순이 됐다. splitting 과 무관하게 **단일 번들**에서 재현된다.

  인라인 dynamic import 를 정적 간선과 같은 방출-순서 계산에 넣어 해결. 빌드 exit 0 · 파싱 통과 · **실행만** 실패하는 계열이라 실행 스모크로 가드했다.

- 5a20552: `--target=es2015` / `es2016` 에서 `for await` 를 쓰면 방출된 코드가 **파싱조차 되지 않던** 버그 수정 (#4488).

  ```js
  async function f(xs) {
    for await (const x of xs) use(x);
  }
  ```

  → `function f(xs){ return __async(function*(){ ... await _a.next() ... }); }` — generator 안에 `await` 가 남아 `'await' is not allowed in non-async function`.

  `for await` 다운레벨이 만드는 `await` 노드는 body 를 **방문하는 도중에** 생겨서, 이미 지나간 async lowering 의 방문(`await` → `yield`)을 받지 못했다. `async function` / `async function*` / `async` 화살표 세 경로 모두 해당. async lowering 이 body 를 visit 한 뒤 남은 await 를 정리하는 post-pass 를 추가했다.

- 8f0a320: manualChunks 로 relocate 된 CJS/ESM-wrapped user entry 가 `--splitting` 에서 호출되지 않아 본문이 실행되지 않던 버그 수정 (#4542, #4537 하위케이스).

  ## 증상

  `manualChunks` 로 user entry 모듈을 manual 청크로 relocate 하면 `var require_entry = __commonJS(...)` 선언만 남고 `require_entry();` 호출이 없어 entry 본문 미실행. `node manual-entry-*.js` 무출력.

  ## 루트커즈

  청크 배정(chunk.zig:1163)은 **manualChunks 우선 정책**상 user entry 모듈을 manual 청크에 **의도적으로 그대로 둔다** → 그 manual 청크가 곧 그 entry 의 출력(node 가 실행하는 파일)이다. 그런데 #4537 의 entry-invoke 가 "entry 출력 청크"를 `chunk_is_user_entry`(= `chunk.kind == .entry_point`)라는 **프록시**로 판정한다. relocate 되면 청크 kind 가 `.manual` 이라 이 프록시가 실패 → 호출이 안 나온다. 즉 근본은 "entry 가 어느 청크에 있든 그 청크가 그 entry 의 출력"인데 emit 이 chunk.kind 프록시만 봐 놓친 것.

  ## 수정

  `chunk.kind == .entry_point` 라는 **프록시** 대신 "이 청크가 **프로그램 entry 출력**(node 가 직접 실행)인가" 라는 근본 신호를 쓴다. 기존 `chunk_is_user_entry`(비-dynamic `.entry_point`) 에 relocate 목적지인 `.manual` 을 더한 것이 곧 그 신호 — 분류 규칙을 단일 소스로 재사용한다:

  ```
  const chunk_is_entry_output = chunk_is_user_entry or chunk.kind == .manual;
  ```

  그 출력 청크 안에서 `is_entry_point` 인 모듈(build_flow 가 user/emitted entry 에만 설정, **dynamic-import 대상은 false**)을 호출한다. 이렇게 하면:
  - **relocate 된 entry**(`.manual`) → 호출 ✓ (#4542)
  - **dynamic-import 대상 / plugin `emitFile` on-demand 청크**(dynamic `.entry_point`) → 제외 ✓
  - **common 청크** → 제외 ✓ (user entry 는 애초에 안 남음)
  - **user entry ∧ emitFile'd 동시**(both-case): `addDynamicEntry` 가 "이미 non-dynamic user-entry면 skip" → 단일 비-dynamic `.entry_point` 청크로 남음 → 호출 ✓ (정확히 1회)

  ⚠️ on-demand 여부는 **청크** 단위 사실이라, 모듈 플래그 `is_emitted_chunk_entry` 로 제외하면 both-case(user entry 이면서 emitFile 된 모듈)를 **잘못 뺀다**. 그래서 제외를 청크 kind 로 한다. "entry 를 그것이 든 출력 청크에서 호출"이라는 #4537 규칙을 chunk.kind 무관하게 일반화한 것 — 방어 게이트 없이 근본 신호만 사용. reg_split(bootstrap)·preserve-modules(pm_entry_call) 는 각자 담당하므로 게이트 제외.

  ## 범위 / 후속

  이 PR 은 **esm/cjs 경로만** 일반화한다. `/code-review max` 에서 같은 `chunk_is_user_entry` 프록시가 다른 emit site 에도 쓰임이 드러났고, 각자 별도 기계에 묶여 별도 수정이 필요하므로 형제 이슈로 분리:
  - **#4548 (reg_split)**: iife/umd/amd 의 invoke(1644)+bootstrap(1676) 도 같은 프록시 게이트 — relocate entry 무출력. factory registry(reg_ids)·federation bootstrapSpan 강결합 동반.
  - **#4549 (run_before_main)**: RBM polyfill(477/1021/1093) 도 같은 프록시 — relocate entry 가 polyfill 없이 실행. cross-chunk RBM import·closure 이관 필요. RN/Metro 전용·극드문 조합(#4542 이전엔 entry 미실행이라 가려져 있었음).

  ⚠️ manualChunks 가 user entry 를 다른 entry 의 dep 와 **같은 청크로 묶으면** 그 청크 로드 시 entry 본문이 실행된다("자기 출력 청크에서 호출"의 일관된 결과, #4537 과 동일 성질) — 비정상 config 의 예측 가능한 귀결.

  검증: zig 통과 · manual-chunks #4542 relocate 가드(require_entry() 호출 + node 실행) · 인접 splitting/manualchunks/RN 218 pass. RN fixture 재커밋 금지 준수.

  Closes #4542

- 7d55d86: minify 시 `if (c) ({a} = o)` 를 `c && ({a} = o)` 로 접을 때 **필수 괄호가 사라지던** 버그 수정 (#4481).

  `&&` 는 `=` 보다 우선순위가 높아 `c && {a} = o` 는 `(c && {a}) = o` 로 파싱된다 — `SyntaxError: Invalid left-hand side in assignment`. 빌드는 exit 0 인데 산출물이 파싱조차 되지 않았다 (monaco-editor `ts.worker`, codemirror).

  원인은 `if` → `&&`/`?:` 폴딩 경로가 피연산자를 `emitNode`(= precedence level `.lowest`)로 방출해, 방출 단계의 공통 괄호 로직(`exprNeedsParens`)을 우회한 것이다. 폴딩된 피연산자를 실제 자리의 level(`&&` 의 좌/우, `?:` 의 test/분기)로 방출하도록 바꿔 필요한 괄호가 재유도되게 했다. 같은 뿌리의 아래 케이스도 함께 고쳐진다.
  - `if ((m = f())) g(m)` → `m=f()&&g(m)` (파싱은 되지만 `m = (f() && g(m))` 로 **의미가 바뀌던** silent miscompile) → `(m=f())&&g(m)`
  - `if (c) (a(), b()); else d()` → `c?a(),b():d()` (SyntaxError) → `c?(a(),b()):d()`
  - `if ({}.x) g()` → `{}.x&&g()` (SyntaxError) → `({}).x&&g()`
  - `if ((m = f())) return A; return B;` → `return m=f()?A:B` (의미 변경) → `return (m=f())?A:B`

  아래 두 건은 같은 뿌리(#4042 괄호 투명화)에서 온 것으로 code-review 에서 확인돼 함께 고쳤다.
  - `return ( /* c */ g() )` 가 `return /* c */⏎ g()` 로 방출돼 **ASI 로 undefined 를 반환**하던 버그 (`throw` 는 `Illegal newline after throw`). minify 없이도 발생.
  - `if (let[0]) g()` (sloppy `var let`) 를 `let[0] && g()` 로 접으면 statement 가 `let [` 로 시작해 lexical 선언으로 오파싱 → SyntaxError. 이 경우 폴딩을 포기한다.

- 00b5b66: 방출 단계에서 **단항 연산자 토큰이 병합**되거나 **`**` 좌변 괄호가 사라지던\*\* 버그 수정 (#4482).

  ```js
  f(-(--t)); // 버그: f(---t)        → SyntaxError
  f(-(-t))(
    // 버그: f(--t)         → t 를 감소시키는 silent miscompile
    -a,
  ) **
    b(
      // 버그: -2**2          → SyntaxError
      -a,
    ).toString(); // 버그: -2 .toString() → 문자열 "-2" 가 아니라 숫자 -2 (silent)
  true.toString(); // 버그: !0.toString()  → SyntaxError
  undefined ** 2; // 버그: void 0**2      → SyntaxError
  ```

  원인은 둘이다.
  1. 단항 `-`/`+` 의 **피연산자 슬롯에 토큰 병합 방지 공백 가드가 없었다**. 이항 RHS 슬롯에는 있었지만 단항에는 대응물이 없어 `-` + `--t` 가 `---t` 로 붙었다. minify 와 무관하게 발생한다.
  2. `binaryChildLevels` 가 `**` 좌변의 level 을 올려도, `exprNeedsParens` 에 `numeric_literal`/`boolean_literal` case 가 없어 그 level 이 그냥 버려졌다. 미니파이어가 `-a` 를 `numeric_literal("-2")` 로, `true` 를 `!0` 으로 바꾸는 순간 `.unary_expression` 매칭을 빠져나간다.

  `d3@7` (`d3-ease` 의 elastic) 이 `tpmt(-(--t))` 를 써서 `import * as d3 from "d3"` 를 `--minify` 로 번들하면 산출물이 파싱되지 않았다.

  `/code-review max` 가 같은 계열의 구멍 3건을 더 찾아 함께 고쳤다 (셋 다 `--minify` 없이 번들만 해도 발생).

  ```js
  // flags.js: export const U = undefined; export const ON = true;
  U **
    (2(
      // 버그: void 0**2      → SyntaxError
      ON && -1,
    ) **
      k); // 버그: -1 ** k        → SyntaxError
  x -
    (ON ? -1 : 1) - // 버그: x--1           → SyntaxError
    (ON ? -t : t); // 버그: --t            → t 를 감소시키는 silent miscompile
  ```

  원인은 하나다 — 괄호/공백 판정이 **AST 태그**를 봤는데, codegen 은 emit 시점에 노드를 갈아치운다(상수 인라인, 상수 단락/조건 fold). 그래서 fold 로 사라질 분기를 보고 판단했다.

  처방도 하나다. 토큰 병합 방지를 **출력 바이트 기준**(esbuild `prevOp`/`prevOpEnd`)으로 바꿨다 — 어느 노드가 emit 되든 직전에 나간 바이트를 보므로 fold 와 무관하게 정확하다. AST 룩어헤드(`leadingSignChar`)는 제거했다. `**` 좌변 괄호 판정은 emit 시점의 fold/치환 결정을 그대로 따라 내려가도록 고쳤다.

  덤으로 과잉 공백도 사라졌다: `-(-a - b)` 는 피연산자가 이미 괄호로 감싸이므로 공백이 불필요한데 AST 룩어헤드는 그걸 몰랐다 → 이제 esbuild 와 바이트 동일(`-(-a-b)`).

- 2a926ba: 함수-로컬 `const x` 가 import 참조를 shadow 해 self-TDZ(`const c = c.set(...)`) 나던 것을 **cross-chunk splitting** / **preserve-modules** / **dev-split** 세 토폴로지에서 모두 수정 (#4566, #4563 후속).

  ```js
  // s.js:  const c = new C(); export default c;   // 싱글톤
  // u.js:
  import _c from './s.js';
  export const f = (r) => {
    const c = _c.set(r);
    return c;
  }; // 함수-로컬 c 가 import c 를 shadow
  // 버그: const c = c.set(r) → ReferenceError: Cannot access 'c' before initialization
  ```

  #4563 은 싱글톤과 소비자가 **같은 청크**(target canonical 을 `c$1` 로 rename)인 경우만 고쳤다. 잔여 토폴로지 — (A) cross-chunk splitting(싱글톤이 다른 청크로 hoist), (B) preserve-modules(import 를 문으로 보존, 로컬명이 export 명으로 rename 돼 함수-로컬과 충돌), (C) dev-split(same-chunk 인데 cross-chunk-export 도 돼 lazy override 가 target-rename 을 revert) — 은 target 의 canonical 을 이 청크서 못 건드려 self-TDZ 가 남았다.

  ## 수정

  `resolveNestedShadowForModule` 을 분기: target 이 소비자와 **같은 청크 & cross-chunk-export 아님**이면 target canonical 을 rename(#4563), 아니면(다른 청크 / 파일경계 / cross-chunk-export) target 을 못/안 건드리므로 **소비자의 nested(scope 1+) 바인딩**을 rename. 소비자 로컬은 토폴로지 무관하게 항상 rename 가능하므로 세 케이스를 통합 해소한다.

  ### `/code-review max` 반영
  - **참조 이름은 same-chunk 면 canonical local, cross-chunk 면 전역 공개명**: same-chunk 소비자는 로컬명으로 참조하므로 전역명으로 shadow 를 찾으면(local!=global) 놓쳐 #4563 이 회귀. `target_same_chunk` 판정 후 ref_name 결정.
  - **eval/`with` 가드**: consumer-rename 는 `resolveWrapperConsumerShadows` 와 동일하게 `blocksMangling()` 모듈 skip(동적 이름 참조 → 리네임 시 ReferenceError). minify 도 skip(mangler 담당).
  - **공유 헬퍼 `renameConsumerScopeBindings`**: consumer-nested-rename 루프를 `deconflictConsumerShadows`(#4533)와 공유 — 드리프트 제거(가드/scope 처리 단일 출처).
  - 회귀 가드 cross-chunk 구조 검증에 `fChunk` 정의 확인 추가(undefined 시 vacuous 통과 방지).

  ## 검증
  - (A) cross-chunk splitting: `import { c }` + `const c$1 = c.set(...)`, 실행 `f:6 / 6`.
  - (B) preserve-modules: `import { default as c }` + `const c$1 = c.set(...)`, 실행 `f:6`.
  - (#4563) same-chunk(non-cross-export): `channels$1`(target rename) 유지, `rgba:10`.
  - 실제 mermaid: minify·non-minify **양쪽 9종 다이어그램 브라우저 렌더 성공**.
  - 회귀 가드: `split-runtime-smoke.test.ts` `#4566(A)`/`#4566(B)`. zig 전체 + 통합(4272) 무회귀 — per-chunk 리네이머는 모든 splitting/preserve-modules 빌드 코어라 전량 검증.

- b99caca: `new` callee 파싱이 member 체인 / tagged template 을 흡수하지 못해 **진단 없이 잘못된 코드를 방출**하던 버그 3건 수정 (#4500).

  ```js
  new new Inner().C(); // 방출: new new Inner()().C()  → TypeError: (intermediate value) is not a constructor
  new tag`x`.B(); // 방출: new tag()`x`.B()       → TypeError: (intermediate value) is not a function
  ```

  ECMAScript 는 `MemberExpression: new MemberExpression Arguments` 이므로 중첩 `new` 뒤의 `.C`/`[k]` 와 callee 안의 `` `tpl` `` 은 **바깥 new 의 callee** 에 속한다(`new (new Inner().C)()`). 그런데 `parseNewCallee` 가 중첩 new 를 만들고 **즉시 return** 해서 뒤의 member 체인 루프에 도달하지 못했고, 그 루프엔 tagged template arm 자체가 없었다. 그 결과 체인이 바깥 new *밖*으로 새어나가고, argless 로 끝난 바깥 new 에 codegen 이 `()` 를 다시 붙여 원본과 다른 프로그램이 됐다.

  파이프라인 **idempotency** 도 함께 깨져 있었다 — zntc 가 `new (new A().b)()` 를 `new new A().b()` 로 방출하고, 그 출력을 zntc 가 다시 읽으면 `new new A()()` + `.b()` 로 잘못 재해석했다(2-pass/번들 시 위험).

  세 번째로, TS 타입 래퍼가 argless-new head 를 가려 SyntaxError 를 놓치던 accept-invalid 도 고쳤다 — `new a\`x\`!?.b`는 타입 소거 후`new a\`x\`?.b`와 같은 SyntaxError 인데`!`/`as T`/`<T>x`래퍼를 walk 가 안 넘어가 exit 0 으로 수용했다(ZNTC0623 정상 발생). Flow 의`(x: T)`cast 는 **괄호 자체**라 통과시키면 안 된다(유효한`(new a: any)?.b`오거부) —`isParenFreeTypeWrapper` 로 분리했다.

  "tagged template 이 new 의 callee" 라는 AST 모양이 처음 생기면서 그 모양을 못 다루던 하류 3곳도 함께 고쳤다:
  - **codegen**: callee 안의 call 에 괄호를 안 붙여 `` new (f())`x` `` → ``new f()`x`()`` (f 가 *생성*되고 template 결과가 *호출*됨). member 의 object 처럼 tagged template 의 tag 에도 `forbid_call` 을 전파.
  - **es5/es2015 다운레벨**: `lowerSpreadNew` 가 callee 를 identifier 로 가정해 `new a.b(...args)` 가 **컴파일러 crash** 였다(기존 버그). temp 캡처로 callee 를 1회만 평가하도록 수정 — `new ((_a = a.b).bind.apply(_a, ...))()` (tsc 동형).
  - **minify**: `` (0, o.tag)`x` `` 의 sequence 를 풀어 tag 가 `this=o` 로 호출되던 것 방지.

- 4cd691e: TS 접미사(`!` non-null / `<T>` 타입인자)가 `new` 의 callee **밖으로 새던** 무성 오컴파일 수정 (#4505).

  ```ts
  const b = new tag<number>`${'hello'} ${'world'}`(100, 200);
  // 방출(버그): new tag()`${"hello"} ${"world"}`(100, 200)
  //             → tag 를 *생성*한 뒤 그 인스턴스를 태그 호출 (완전히 다른 프로그램)
  // 방출(정상): new tag`${"hello"} ${"world"}`(100, 200)   ← tsc 동일
  ```

  ECMAScript 문법상 `MemberExpression TemplateLiteral` 은 그 자체가 MemberExpression 이라 tagged template 은 **바깥 new 의 callee** 에 속한다. 그런데 `parseNewCallee` 가 member 체인 루프를 **다 돈 뒤에** TS 접미사를 처리해서, 타입인자가 붙는 순간 callee 가 거기서 끊기고 뒤따르는 template 이 new 밖으로 새어나갔다. argless 로 끝난 바깥 new 에 codegen 이 `()` 를 다시 붙여 `new tag()` 가 됐다.

  타입인자 speculation 을 member 루프 **안으로** 옮겨 해결. #4500(같은 함수의 `kw_new` 분기가 즉시 return) 과 같은 파일, 다른 루트커즈다.

  TSC 컨퍼먼스 스냅샷(`taggedTemplatesWithTypeArguments2`)이 이 오컴파일을 **박제**하고 있어 함께 갱신했다 — 갱신 후 tsc 정본 emit 과 일치한다.

- 6222bf2: `new a?.b\`x\`?.c`처럼 argless`new`의 optional callee 와 trailing`?.` 가 겹칠 때 진단 ZNTC0623 이 **2번** 발행되던 문제 수정 (#4048).

  두 검사 지점이 **같은 `new`** 를 각각 보고하고 있었다. 복구 경로가 callee 의 `?.` 를 비-optional 멤버로 소비해 버려서, AST 에 "이 new 의 callee 는 optional 이었다" 는 사실이 남지 않았던 게 원인이다. dedup 필터로 뭉개는 대신 그 사실을 `new` 노드에 비트로 복원해, 뒤따르는 검사가 같은 new 를 다시 보고하지 않게 했다.

  **같은 new 안에서만** 접는다 — 서로 다른 `new` 두 개는 각자의 위반이므로 그대로 2건이 나온다 (`new new a?.b\`x\`?.c`, `new (new a?.b)\`x\`?.c`). 다른 진단(ZNTC0607 tagged template on optional chain)도 억제되지 않는다.

- 77409b1: `manualChunks` 가 user entry 모듈을 manual 청크로 **relocate 하지 않도록** 변경 — user entry 는 항상 자기 entry_point 청크에 유지된다(rollup/esbuild 불변식). `--splitting` + `manualChunks` 로 entry 를 옮기면 실행이 깨지던 버그 계열(#4542/#4548/#4549/#4551)을 **근본 원인**에서 제거.

  ## 배경 — 왜 화수분이었나

  예전엔 `manualChunks` 패턴이 entry 를 매칭하면 그 entry **모듈 자체**를 manual 청크 안에 넣었다(chunk.zig 의 "manual 우선" 정책). 그런데 emit 파이프라인의 **십수 개 site** 가 "user entry 는 자기 `.entry_point` 청크에 산다"는 불변식(`chunk_is_user_entry` / `entry_mod_idx`)에 의존한다: 표준 entry-invoke, reg_split bootstrap·보편 wrapper, `"use client"` directive 호이스팅, `run_before_main` polyfill, dev HMR runtime, dev_split 선-init… entry 를 옮기면 이 전제를 쓰는 모든 곳이 하나씩 깨졌고, 파이프라인 전역에 흩어져 있어 **고칠수록 다른 코너에서 새 버그가 나왔다**(리뷰 라운드마다 서로 다른 서브시스템). rollup/esbuild 는 애초에 entry 를 relocate 하지 않아 이 버그 클래스가 존재하지 않는다.

  ## 수정 — entry 는 옮기지 않는다

  chunk.zig 의 manual 청크 배정에서 **user(비-dynamic) entry 를 제외**한다 — dynamic import 대상(#1848/#1849)이 이미 제외되는 것과 정확히 같은 방식:
  - **manual seed 수집**(resolver·record 경로): user entry 는 seed 로 안 넣는다. resolver 함수는 **여전히 호출**해 `getModuleInfo` 등 inspection hook 부작용은 보존하되, entry 의 배정 결과만 무시한다.
  - **Phase 2.5 BFS 전파**: user entry 에는 manual bit 를 안 세운다(vendor seed 의 transitive dep 로 도달해도 차단, entry 를 통한 dep 전파도 중단).
  - **Phase 4 강제 이동**: user entry 는 위 seed/전파에서 manual bit 를 못 받으므로 애초에 manual 청크에 배정되지 않는다 → Phase 4 에서 자기 entry_point 청크로 이동. (Phase 4 의 "manual 이면 그대로 유지" 예외는 **유지** — 이제 그건 dynamic import 대상이 manual seed 의 static dep 로 전파돼 흡수된 경우만 보호. 그걸 도로 빼내면 cross-chunk ReferenceError.)
  - **warn**: `manualChunks` 가 entry 를 매칭하면 "entry 는 relocate 되지 않고 자기 청크에 유지됩니다" 경고(rollup 관례).

  matched 된 **non-entry** 모듈은 종전대로 manual 청크로 간다. entry 만 매칭한 manual 청크는 비어서 생성되지 않는다.

  ## 효과
  - `--format esm|cjs|iife|umd|amd --splitting` + `manualChunks` 가 entry 를 매칭해도 entry 는 표준 경로로 정상 실행(무출력/SyntaxError 없음).
  - #4542(esm/cjs relocate 미실행), #4548(reg_split relocate 미실행), #4549(RBM 미emit), #4551(umd export 값) 이 **전부 해소** — entry 가 안 움직이니 인프라가 흩어질 일이 없다. #4552(reg_split RBM cross-chunk ESM import)는 relocate 와 무관한 pre-existing 이라 별도.
  - #4542 가 도입했던 emit-side 일반화(`chunk_is_entry_output` +manual 스캔)는 이제 불필요 → `chunk_is_user_entry` 로 원복(both-case 처리 위한 is_entry_point 스캔만 유지).

  ## 참조 번들러

  rollup/esbuild 모두 `manualChunks`/`splitting` 에서 entry 모듈을 relocate 하지 않는다(entry 는 항상 자기 출력 파일). 이 변경으로 zntc 도 동일 불변식을 따른다.

  검증: zig test(chunk_test #4553 유닛 가드 + 전체) · manual-chunks/splitting/reg_split/MF integration · esm/cjs/iife/umd/amd × (entry-only 매칭 / entry+vendor 매칭) `node` 실행 · 통합 4255 pass.

  (#4542 는 PR #4550 으로 이미 close — 이 변경은 그 emit-side 접근을 원복하고 근본을 chunk.zig 로 옮긴다.)

  Closes #4553
  Closes #4548
  Closes #4549
  Closes #4551

- 53ab25e: 코드 스플리팅 + `--minify` 에서 **materialize 된 namespace 객체의 getter** 가 같은 청크 소비자에게도 크로스-청크 전역 공개명을 써서 런타임에 죽던 버그 수정 (#4502, #4492 의 네 번째 표면).

  ```
  ReferenceError: second is not defined
  ```

  `import * as ns` 를 **값으로** 쓰면(`const o = ns`) 정적 멤버 재작성이 불가능해 객체가 materialize 된다. 그 리터럴은 **정의자 청크** preamble 로 들어가는데, getter 본문이 크로스-청크 전역 공개명을 쓰고 있었다:

  ```js
  // 공유 청크 — 선언은 여기 있다
  let n = { label: 'second' },
    r = { label: 'other' };
  var ns_ns = {
    get second() {
      return second;
    },
    get other() {
      return r;
    },
  };
  //                          ^^^^^^ 이 청크엔 `second` 선언이 없다 → ReferenceError
  ```

  `other` 는 크로스-청크로 안 나가서 chunk-local `r` 을 올바르게 쓰는데, `second` 는 **다른 청크가 소비해서 전역 공개명이 등록됐다는 이유만으로** 그 이름을 썼다.

  **왜 순진한 게이트로는 못 고치는가.** getter 생성 지점(`buildInlineObjectStr`)을 "같은 청크면 로컬 이름" 으로 게이트하면 #4101 이 회귀한다. 그 시점엔 **per-chunk rename 이 아직 안 돌아서** 로컬 이름이 미-deconflict 원본 이름이기 때문이다 — 서로 다른 모듈의 동명 `const k` 두 개가 한 청크에서 `k` / `k$1` 로 갈려야 하는데 둘 다 `k` 로 collapse 된다(`e1 XK YK XK YK` → `e1 XK YK XK XK`). 코드가 전역 공개명을 쓰고 있던 건 그것이 **"확정된 이름의 대리물"** 이었기 때문이다.

  **처방은 게이트가 아니라 타이밍.** 공유 ns preamble 생성을 청크 emit 루프의 `computeRenamesForModules` **뒤** 로 옮겨(출력 위치는 `insertSlice` 로 종전과 동일하게 유지) chunk-local 이름이 확정된 뒤에 리터럴을 만든다. 그러면 getter 가 (같은 청크 선언 → 확정된 chunk-local 이름 / 다른 청크 선언 → 크로스-청크 전역 공개명) 을 정확히 고른다. `ns_inline_cache` 도 소비자 청크마다 문자열이 달라지므로 `(emitter 청크, target)` 복합 키로 re-key 했다.

  빌드 exit 0 + 산출물 파싱 통과 + **실행만 실패**하는 계열이라, 번들을 실제로 실행하는 스모크 테스트를 함께 추가했다.

- 4cd691e: 깊게 중첩된 **Flow 타입**과 **식**에서 재귀-하강 파서가 스택 오버플로우(SIGSEGV)로 죽던 것 수정 (#4518, #4519).

  ```js
  ((((( ... 10000 ... 1 ... )))))     // 식
  type T = ((((( ... A ... )))));     // Flow 타입
  ```

  #4146 이 TS 타입 파서에 깊이 가드를 넣었지만 **Flow 타입 파서**와 **식 파서**에는 없었다. 중첩 식/타입은 진짜 트리라 재귀 자체를 없앨 수는 없고, 처방은 참조 구현들과 동일하게 **크래시 → 진단**이다 (esbuild `Expression too deeply nested`, tsc TS1128, oxc 동일).

  식 쪽에 새 진단 `ZNTC0920 expr_too_deeply_nested` 를 추가했다. 정상 코드가 닿을 수 없는 깊이에서만 발동한다.

- d5f026b: 깊게 중첩된 **TypeScript 타입 구문**에서 파서가 스택 오버플로우(SIGSEGV)로 죽던 버그 수정 (#4146).
  (Flow 타입 파서 `flow.zig` 는 독립 구현이라 같은 계열의 크래시가 남아 있다 — 별도 이슈로 추적.)

  ```ts
  type X = /* … 수천 겹 … */ T; // 그 전엔 프로세스가 SIGSEGV (exit 134)
  ```

  타입 파서는 상호재귀 하강(`parseType` → 유니온 → … → primary → 괄호/조건부/함수/제네릭/튜플/객체 → 다시 `parseType`)이라 **중첩 1단계마다 파서 스택이 한 겹씩** 쌓인다. 배열 postfix(`T[]`, 반복 루프)나 유니온(flat list)과 달리 이 형태들은 바깥 노드가 안쪽 타입 전체를 자식으로 갖는 진짜 트리라 단일 루프로 평탄화되지 않는다.

  이제 타입 중첩 깊이 상한(256)을 두고, 초과 시 크래시 대신 **`ZNTC0919` 진단 1건**으로 우아하게 실패한다. 상한은 양쪽에서 실측해 잡았다 — 실제 코드(node_modules + 저장소 소스 94,403 파일)의 타입 중첩은 32 단계에도 못 미치고, 안전 쪽으로는 1MB 급 스레드 스택에서도 여유가 있다. 정상 코드의 파싱 결과는 바뀌지 않는다(실파일 3,000개 출력 바이트 동일 확인).

  덤으로 `a < a < a < …` 같은 **유효한 비교 연산 체인**이 수천 항에서 죽던 크래시도 함께 사라진다 — 식 파서가 `ident <` 를 타입 인자로 speculative 파싱하며 같은 재귀를 타던 경로였다.

- 7ad3022: `**` 좌변 괄호 계약을 **사후조건으로 강제** (#4482 후속).

  `binaryChildLevels` 는 "괄호가 필요하다" 를 자식 level 을 올리는 것으로 표현하는데, 실제 괄호를 치는 쪽(`exprNeedsParens`)이 그 노드 종류를 모르면 **level 이 그냥 버려진다** — 이게 `-2**2` / `void 0**2` 가 방출되던 정확한 기전이었다. 두 목록이 어긋나도 아무도 안 잡아줬다.

  이제 `**` 좌변이 prefix 단항으로 시작한다고 판정했는데 방출된 첫 바이트가 `(` 가 아니면 runtime_safety 빌드(테스트·CI)에서 즉시 panic 한다. 이 사후조건이 켜지자마자 남아 있던 불일치를 하나 더 찾았다 — `powLeftNeedsParen` 이 **모든** numeric literal 에 true 를 반환하는데 `exprNeedsParens` 는 **음수만** 괄호를 쳐서, 양수 리터럴(`2**3`)은 level 만 올라가고 wrap 은 안 걸리고 있었다 (동작은 우연히 맞았다). 양쪽을 정확히 맞췄다.

- 6c292a3: `--preserve-modules`(ESM 출력)에서 **익명 `export default class {}` / `function(){}`** 를 낸 모듈이 ESM-wrap 되면 `SyntaxError: Export '_default' is not defined` 로 모듈이 로드되지 않던 것 수정 (#4573).

  ```js
  // b.js:  export default class { greet(){ return "hi"; } }
  // a.cjs: module.exports = require("./b.js");   // b 를 ESM-wrap 강제
  // entry: import D from "./b.js"; import "./a.cjs"; console.log(new D().greet());
  ```

  ## 근본 원인

  ESM-wrap lowering(`esm_wrap.zig`)은 export 를 `__esm(() => {…})` 클로저 밖 top-level 로 hoist 한다(`var X;` 선언 + 클로저 안 `X = …` 할당). `.class_declaration` 분기는 **클래스 이름이 있을 때만** 그 이름을 hoist 했다. 익명 default class 는 이름이 없어 synthetic `_default` 의 `var _default;` 가 hoist 되지 않았고, codegen 은 클로저 안에서 `_default = class {…}` 로 할당 + top-level `export { _default }` 를 방출 → 미선언 참조.

  value/arrow default(`export default expr` / `() => …`)는 `effective_tag` 가 선언이 아니라 `else` 분기가 이미 `_default` 를 hoist 했고, named class·function, 익명 function 도 정상이었다.

  ## 수정

  익명이고 `export default` 면 `default_export_name`(`_default`)을 hoist 한다:
  - `.class_declaration` 분기(`class_name_idx.isNone()`) — 익명 default class.
  - `.function_declaration` strict_execution_order 분기(`fn_name_idx.isNone()`) — 익명 default function. `/code-review max` 적발: RN 프리셋(strict)에서 codegen 이 `_default = function(){}` 로 할당해 class 와 동일 버그. 5곳으로 중복돼 있던 default 이름 파생을 `defaultExportName` 헬퍼로 통합.

  ## 검증
  - 회귀 스위트 `preserve-modules-default-export.test.ts`: default 형태(익명 class/function/arrow/extends, named class/function, value) × esm/cjs × plain/minify + **익명 function RN(strict)** — 전부 통과(익명 class ESM·익명 function RN 이 수정 전 실패).
  - 방출: `var _default;` top-level 선언 + 클로저 안 `_default = class {…}`/`_default = function(){}` + `export { _default }` 일관.
  - zig 전체 test, 통합 스위트 무회귀.

  ## 별개 잔여 (이 PR 범위 밖)
  - **RN downlevel class 헬퍼 중복**(#4574): `--preserve-modules --platform=react-native` 에서 class 를 export 하면 다운레벨 헬퍼(`__classCallCheck`/`__extends`)가 import + hoisted var 로 이중 선언 → SyntaxError. 익명·named·default 무관(class 다운레벨 특정).

  Refs #4573

- cb58f6f: `--preserve-modules --format=cjs` 순환 import 에서 **function 선언 export** 가 소비자 로드 중 `undefined` 로 잡혀 `TypeError` 나던 것 수정 (#4532 증상4).

  ```js
  // e1.js: import { b } from "./e2.js"; export function a(){ return "A"; }
  // e2.js: import { a } from "./e1.js"; export function b(){}  a();  // ← 로드 중 e1.a() 호출
  ```

  ## 근본

  cjs 는 `exports.a = a` 를 모듈 본문 **끝**(require 뒤)에 방출한다. 순환에서 e2 가 e1 을 require 하는 시점엔 e1 의 `exports.a = a` 가 아직 실행 전 → e2 의 `require("./e1.js").a` = undefined. ESM 은 function 선언이 hoisting 돼 live-binding 으로 항상 함수(`typeof a === "function"`). esm 출력은 정상이라 **cjs 전용**.

  ## 수정

  unwrapped preserve-modules cjs 모듈의 **named function 선언 export** 를 `exports.<fn> = <local>;` 로 require 블록 **앞**에 hoist(function 은 스코프 상단으로 hoisting 되므로 참조 가능) + bottom 방출에서 제외(중복 방지).
  - 판정 `exportBindingIsHoistableFn`: 직접 `.local` 선언 + semantic `decl_flags.is_function`. re-export 는 소스가 자기 것 hoist 하므로 제외. default 는 `module.exports`/`exports.default` 모드 로직과 충돌해 제외.
  - 삽입은 `computeRenamesForModules` 후(리네임명 확정), `ns_preamble` insert 앞(위치 shift 방지). `ns_preamble_pos`/insertSlice 선례를 따름.
  - bottom 제외는 `emitCjsEntryExports` 에 hoisted-이름 집합 전달(같은 predicate 공유 → 발산 없음).
  - live getter(#4532 증상3 서 엣지 다수로 드롭)를 피하고 값 hoist 로 처리.

  ## 검증
  - 회귀 스위트 `preserve-modules-cjs-circular-fn.test.ts` 6종: 다중-entry 순환 function 호출(esm/cjs × plain/minify)·default 병존 named 순환·non-circular(hoist 무해).
  - preserve-modules 189·cross-chunk/splitting/wrapper 186 통합 + zig 전체 무회귀.

  ## `/code-review max` 반영
  - **[0]** hoist 게이트가 `output_exports` 를 안 봐 `--output-exports=none`/`default_` 에서도 `exports.fn=fn` 이 새던 것 → `.auto`/`.named` 로 게이트(hoist·skip 양쪽).
  - **[1][2]** `exports.X=X` 방출을 `appendCjsExportBinding(live=false, min=false)` 재사용으로 단일화 — 같은-파일 bottom(emitCjsEntryExports, minify 무시 `=`/`;\n`)과 형식 일치.

  ## 한계 (별개, 이 fix 범위 밖)
  - **소비자 자신의 import 가 TDZ**: 순환 중 paused 모듈의 `const { b } = require(...)` 는 아직 미초기화라, 그 모듈의 함수가 자기 import 를 참조하면 TDZ. 소비자-측 lazy 참조 필요(별개 층).
  - **const/let/class export** 는 hoisting 불가·ESM 도 순환서 TDZ 라 대상 아님.
  - **default 의 순환 접근** 은 `module.exports` bind-whole + partial 로 별개.

- 7242aa5: `--preserve-modules` + `--format=cjs` 에서 **CJS↔CJS 순환**이 로드 시 `TypeError` 로 죽던 것 수정 (#4526).

  ```js
  // a.cjs
  const b = require('./b.cjs');
  exports.a = function a() {
    return 'A+' + b.b();
  };
  // b.cjs
  const a = require('./a.cjs');
  exports.b = function b() {
    return 'B';
  };
  ```

  node 정본은 `A+B` (require 가 lazy 라 순환 정상 처리). `--format=esm` 도 정상. `--format=cjs` 만 `TypeError: require_a is not a function`.

  근본 원인: cjs 소비자가 래퍼 심볼을 **구조분해**했다.

  ```js
  const { require_b } = require('./b.js'); // ← 로드 시점에 값을 **복사**
  ```

  순환에서 b.js 가 **아직 평가 중인** a.js 를 require 하면 `exports.require_a` 가 미할당이라 **undefined 를 박제**한다. ESM 은 live binding 이라 나중에 할당된 값을 보고, node 자신은 `require()` 가 partial exports **객체**를 돌려주고 그걸 참조로 들고 있으므로 무사하다 — 구조분해가 그 지연을 깨뜨린다.

  처방: 래퍼 심볼(`require_X` / `init_X`)은 **함수**라 호출 시점에 조회하도록 lazy forwarding 으로 바인딩한다.

  ```js
  require('./b.js'); // side-effect: 실행/등록 순서 보장
  const require_b = function () {
    return require('./b.js').require_b.apply(this, arguments);
  };
  ```

  실제 호출은 모듈이 완전히 평가된 뒤에 일어나므로(`entry` → `require_a()` → a 본문 → `require_b()` → …) 그때는 provider 의 `exports.require_X` 가 이미 채워져 있다.

  ⚠️ **holder 변수(`const __zntc_w0 = require(...)`)를 두면 안 된다.** 우리가 이름을 지어 top-level 에 깔면 그 이름은 deconflict 를 안 거쳐서 사용자 코드의 동명 top-level 심볼과 **중복 선언**(`SyntaxError: Identifier '__zntc_w0' has already been declared`)이 난다. `require()` 는 node 가 memoize 하므로 forwarding 안에서 다시 불러도 싸다 — holder 자체가 불필요하다.

  추가(코드리뷰): **`exports_X` 도 lazy 여야 한다.** 첫 수정은 함수형 래퍼(`require_X`/`init_X`)만 lazy 로 만들고 `exports_X`(ESM-wrap dep 의 exports 객체)는 eager 복사로 남겼다. 그러면 순환에서 dep 이 **아직 평가 중**일 때 provider 의 `exports.exports_X = …` 가 아직 안 깔려 **undefined 를 박제**하고, 나중에 `__toCommonJS(undefined)` → `TypeError: Cannot convert undefined or null to object` 로 죽는다 — **#4526 이 고치려던 바로 그 결함이 절반만 고쳐진** 것이다.

  `exports_X` 는 객체라 forwarding 으로 감쌀 수 없지만, 소비자의 사용처가 **항상** `(init_X(), __toCommonJS(exports_X))` — `init_X()` 가 먼저 평가되는 순차식이다. 그래서 `let` 으로 선언하고 **init forwarding 안에서 갱신**한다.

- 45a783c: `--preserve-modules --format=cjs` 에서 **default-only 모듈**(default export 만) 을 default import 하면 `TypeError: X is not a function` 로 실패하던 것 수정 (#4580).

  ```js
  // m1.js: export default function foo(){ return "D1"; }
  // entry: import a from "./m1.js"; console.log(a());
  ```

  ## 근본

  default-only 모듈은 `module.exports = X`(default = exports **전체**) 로 방출된다(named 이 섞이면 `exports.default = X` + `__esModule`). 그런데 소비자 import 블록(chunks.zig)은 **항상** `const { default: foo } = require("./m1.js")` 로 `.default` 를 구조분해했다 — `module.exports = foo` 는 `.default` 가 없으니 `foo`=undefined → TypeError. ESM 출력은 Node 네이티브 interop 으로 정상이라 **cjs 전용**.

  ## 수정

  소비자가 dep 이 **default-only**(→ provider 가 `module.exports = X` 방출) 이고 default 단일 import 면, `require()` 결과 **전체**를 바인딩한다: `const foo = require("./m1.js")`. rollup/esbuild 의 런타임 interop 헬퍼(`getDefaultExportFromCjs`/`__toESM`) 대신, preserve-modules 는 provider shape 를 정적으로 알 수 있어 헬퍼 없이 형태를 맞춘다(더 깨끗).
  - default-only 판정 `cjsDepDefaultOnly`: dep 청크 모듈에 default 있고 named 없음. `export *`(ESM 스펙상 default 제외, named 확장) 는 **소스로 재귀 flatten**(`moduleHasAnyNamedExport`)해 provider 의 `collectExportsRecursive` 와 판정을 맞춘다 — star 가 named 0 개면 provider 는 `module.exports = X` 이므로 소비자도 전체 바인딩해야 한다. 미해결/external star 는 보수적으로 구조분해.
  - `.auto`/`.default_` OutputExports 게이트(`.named` 은 `exports.default` 라 구조분해가 맞음). dep 이 완전 unwrapped(래퍼 경로 아님)일 때만.
  - deconflict/전역명/lazy 로컬 처리는 심볼 블록과 동일 경로 재사용(#4576 `mintConsumerLocal`).

  ## 검증
  - 회귀 스위트 `preserve-modules-cjs-default-interop.test.ts` 6종: default-only(전체 바인딩)·default+named(구조분해 유지)·re-export 배럴·mixed 배럴·**동명 default 2개(#4576 deconflict + #4580 interop 협업 → 실행 `12`)**·named-only(무영향).
  - #4576 cjs 동명 default 테스트를 emit-only → **런타임 검증**으로 승격(이 fix 로 실제 실행됨).
  - preserve-modules 171·cross-chunk/splitting/wrapper 137 통합 + zig 전체 무회귀.

  ## `/code-review max` 반영
  - **[0]** `cjsDepDefaultOnly` 가 `export *` 를 무조건 named 로 봐, provider 가 star flatten 후 named 0 → `module.exports = X` 인데 소비자는 구조분해 → TypeError 잔존(재현). → star 를 재귀 flatten(`moduleHasAnyNamedExport`)해 provider 와 일치.
  - **[2]** bind_whole 의 dead `lazy_local_keys`(pm_cjs 라 항상 false) 제거 + 불필요한 `if (preserve_modules)` 가드 제거.
  - **[1]** symbol-level·bind_whole 의 로컬 발급+정합 로직을 `deconflictedConsumerLocal` 헬퍼로 통합(정책 발산 방지).

  ## 한계
  - `--minify-identifiers`(따라서 `--minify`)는 별개 선행 mangler 버그(#4579 계열)로 소비자 default import 로컬과 body 참조가 발산해 실패한다 — 이 fix·구조분해/전체바인딩 무관하며 main 도 동일(단일 default 포함 광범위). #4579 에서 처리.

- 33fcbb0: `--preserve-modules`(CJS/ESM)에서 **소비자가 re-export 배럴 경유로 ESM-wrap dep 을 import** 하면 `undefined` 를 잡아 `TypeError: X is not a function` 나던 것 수정 (#4532 증상3).

  ```js
  // b.js:  export const CONST = 42; export function fn(){ return "F"; }
  // a.cjs: module.exports = require("./b.js");   // b 를 ESM-wrap 강제
  // r.js:  export { CONST, fn } from "./b.js";   // re-export 배럴
  // entry: import { CONST, fn } from "./r.js"; import "./a.cjs"; console.log(CONST + "|" + fn());
  // 버그(CJS/minify): TypeError: fn is not a function
  ```

  ## 근본 원인

  ESM 소비자가 배럴 경유로 import 하면 re-export 체인이 wrap dep(b.js)로 직접 해석돼, 소비자 preamble 이 forwarding 썽크(`let X; const init_X = ...`)의 `init_X()` 를 호출해야 X 가 채워진다("소비자는 심볼을 쓰기 전 init_X() 를 부른다"는 계약). 그런데 init 주입 게이트가 **직접 import 대상**(`canonical_m_opt` = 배럴, non-wrap)만 봐서 막혀 `init_X()` 를 안 깔았다 → 소비자가 undefined X 를 참조.

  ## 수정

  소비자 init 주입에서, 직접 대상이 non-wrap 이어도 **`resolved.canonical`(re-export 체인 끝)이 ESM-wrap 이면 그 wrap dep 의 `init_X()` 를 소비자 preamble 에 주입**한다. `esm_init_set` 로 중복 방지, tree-shake 가드 유지.

  `/code-review max` 반영:
  - **preserve-modules 한정**: 각 모듈이 별도 파일이라 forwarding 썽크(init_X)가 소비자 파일에 로컬 정의된다. splitting 은 init_X 가 cross-chunk 라 이 청크서 undefined 일 수 있어(그쪽은 cross-chunk 네이밍이 별도 처리) 제외.

  ## 검증
  - CJS/ESM × plain/minify **전부** `42|F` (수정 전 CJS/minify 는 `TypeError`).
  - splitting(비-preserve-modules)은 게이트로 미적용 — 자체 경로로 정상(`42|F`), 무회귀.
  - 회귀 가드: `preserve-modules-cjs.test.ts` 에 증상3 실행 가드(node 실제 실행).
  - zig 전체 test + 통합 스위트 무회귀.

  ## 잔여 (#4532 epic)
  - 배럴 **자체** exports 를 CJS 로 직접 `require("./r.js").X` 하는 경로는 별도(live getter 필요 — `__export`/minify 이름·default·wrapped 포맷·accessor 시맨틱 엣지 다수라 별도 설계). 증상 1(동명 붕괴 `BB`) CJS, 증상 4(순환) 도 별개 근본. 후속.

- c06a4e9: `--preserve-modules`(CJS)에서 **서로 다른 wrap dep 이 동명 export 를 내고 한 소비자가 둘 다 import** 하면, 소비자 본문이 한 이름으로 붕괴해 잘못된 값을 조용히 방출하던 것 수정 (#4532 증상1).

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

- 311e32d: `--preserve-modules` × CJS 가 통째로 깨지던 것 수정 (#4524).

  ```js
  // legacy.cjs
  module.exports = {
    foo() {
      return 'FOO';
    },
    bar: 42,
  };

  // entry.js
  import d, { foo } from './legacy.cjs'; // ReferenceError: require_legacy is not defined
  const m = await import('./legacy.cjs'); // keys: []  (빈 namespace)
  ```

  근본 원인: **CJS 는 정적 export 가 없어 파일 경계를 넘을 수단이 `require_X` 썽크뿐인데**, preserve-modules 가 그걸 export 하지 않았다. 소비자는 그 썽크를 **렉시컬 참조**했는데 그건 다른 파일의 지역변수다. 즉 preserve-modules 는 CJS 상호작용 **배선 자체가 없었다** — 정적 import 조차 못 썼다.

  **루트커즈**: wrap 된 모듈(CJS `__commonJS` / ESM `__esm`)은 본문이 클로저 안이라 파일 top-level 에 남는 게 **래퍼 심볼뿐**이다 — CJS 는 `require_X`, ESM-wrap 은 `init_X` / `exports_X`. preserve-modules 가 그걸 export 하지 않아 소비자가 **다른 파일의 지역변수**를 렉시컬 참조했다.

  처방: wrap 된 모듈 파일이 래퍼 심볼을 export 하고 소비자가 import 한다. 실제 interop 은 소비자가 자기 preamble(`var d = require_X()` / `(init_b(), __toCommonJS(exports_b))`)로 이미 하고 있으므로 **이름만 건너오면** 그대로 동작한다.

  동적 import 는 소비자가 `.then((m) => __toESM(m.default))` 로 namespace 를 합성한다 — provider 의 `default` 는 **raw `module.exports`** 여야 하므로(방출 파일을 단독 import 했을 때의 node CJS↔ESM 계약) namespace 를 실을 수 없기 때문이다. splitting(#4522)이 provider 에 namespace 를 싣는 것과 대비된다.

  함께 수정: 청크 런타임 헬퍼 주입 게이트가 `needs_cjs_runtime or needs_esm_wrap_runtime` 이라 **`__toESM` 만 필요한 청크를 통째로 건너뛰었다**. preserve-modules 의 소비자는 CJS 도 ESM-wrap 도 없는 순수 ESM 파일이라 `ReferenceError: __toESM is not defined` 가 났다.

  추가: provider(export emit)에만 `format == .esm` 조건이 있어 **`--format=cjs` 에서 어긋났다** — 소비자는 `const { require_X } = require("./x.js")` 를 내는데 provider 는 아무것도 안 깔아 `require_X is not a function`. 두 곳이 `preserveModulesCjsThunkChunk` 단일 술어를 보게 하고, cjs 형식은 `exports.require_X = require_X` 로 깐다.

  추가(코드리뷰): 첫 수정은 `require_X` **절반만** 배선했고 회귀도 하나 만들었다.
  - **CJS 가 ESM 형제를 `require()`** 하면 여전히 깨졌다 — 소비자가 `init_b`/`exports_b`/`__toCommonJS` 를 렉시컬 참조. 가장 흔한 레거시 interop 모양이다. 래퍼 심볼 전반(ESM-wrap 포함)으로 일반화했다.
  - **`export default require_X();` 로 래퍼를 호출하면 안 된다.** CJS 본문이 provider 파일 **평가 시점**에 실행돼 (a) CJS↔CJS 순환이 `TypeError: require_a is not a function` 으로 죽고 (b) 조건부 `require` 의 부수효과가 무조건 시작 시 실행된다. node 는 require 가 lazy 라 순환을 정상 처리한다. 래퍼 **선언만** 내보내 호출 시점을 소비자에게 남겼다(rolldown 은 eager 호출이라 같은 순환 위험을 안는다).
  - **CJS 로부터의 named re-export** 가 `SyntaxError: Identifier 'foo' has already been declared` 였다 — `imports_from` 에 등록된 export 명을 심볼 분기가 먼저 가져갔다. 래퍼 분기를 **먼저** 보게 했다.
  - ⚠️ **헬퍼 게이트 회귀**: `needs_to_esm_runtime` 단독 통과를 허용했더니 일반 `--splitting` 이 깨졌다 — `needsRequireShimForChunk` 가 순수 ESM 청크에서도 돌아 `import { createRequire }` 를 중복으로 깔았다(**파싱 불가**). preserve-modules 로 좁히고 `__toESM` 만 내도록 수정.

- 67bfbe5: `--preserve-modules`(ESM 출력)에서 서로 다른 wrap 된 파일의 **동명 심볼이 소비자 본문에서 붕괴**하던 조용한 오컴파일 수정 (#4532 증상1).

  `--splitting` 에는 있는 파일 간 심볼 네이밍 인프라(`computeCrossChunkGlobalNames` + 소비자 본문 참조 rewrite)가 preserve-modules 에선 `code_splitting and !preserve_modules` 로 꺼져 있었다. 그래서 두 wrap 된 dep 이 각각 `tag` 를 export 하고 소비자가 둘 다 참조하면:

  ```js
  // b.js (a.cjs 가 require 해 ESM-wrap): export function tag(){ return "B"; }
  // c.js (동일):                          export function tag(){ return "C"; }
  // entry.js:
  import { tag } from './b.js';
  import { tag as tag2 } from './c.js';
  console.log(tag() + tag2());
  ```

  |                                | 결과                                     |
  | ------------------------------ | ---------------------------------------- |
  | node 정본 · `--splitting`      | `BC`                                     |
  | `--preserve-modules` (수정 전) | **`BB`** ❌ (두 참조가 한 이름으로 붕괴) |
  | `--preserve-modules` (수정 후) | `BC` ✅                                  |

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

- 20a894d: `--preserve-modules --minify`(또는 `--minify-identifiers`)에서 소비자의 **default import** body 참조가 발산해 `foo is not defined`/`TypeError` 로 실패하던 것 수정 (#4579).

  ```js
  // m1.js: export default function foo(){ return "D1"; }
  // entry: import a from "./m1.js"; console.log(a());
  // (minify) → const t = require("./m1.js"); console.log(foo());  // ← import=t, body=foo 발산
  ```

  ## 근본 (per-chunk rename_table 타이밍)

  import 문 로컬명과 body 참조 둘 다 `resolveToLocalName(provider,"default")` → `rename_table` 을 읽는다. 그런데 `computeRenamesForModules` 는 **청크마다** 맨 처음 `clearCanonicalNames()` 로 `rename_table` 을 비우고 현재 청크만 다시 mangle 한다.
  - **import 블록**은 그 clear **전**에 방출돼 provider(m1) 청크의 mangle `foo→t` 를 본다 → `t`.
  - **body 참조**(effective_target)는 소비자 청크 emit 중(clear **후**)에 계산돼 m1 의 mangle 이 wipe된 stale `rename_table` 을 읽는다 → 원본 `foo`.

  default 는 안정된 public export 명이 없어(`module.exports = X`) provider 의 **로컬명**을 써야 하므로 특히 발산한다(named import 는 public 명 `exports.foo` 라 무영향). splitting 은 cross-chunk 전역명이 있어 무영향.

  ## 수정

  import 블록은 rename_table 이 유효한 시점에 이미 올바른 provider-mangled 로컬(`t`)을 구한다. 이를 `deconflictedConsumerLocal` 에서 **무조건** `consumer_import_local`(#4576) 에 기록하도록 바꿔(기존엔 deconflict `local != binding` 일 때만), body 의 effective_target 이 그 값을 읽어 정합시킨다. import 문이 body 참조의 유일 권위. write 는 read(metadata.zig)와 같은 `preserve_modules` 게이트라 splitting 은 생략(낭비 방지).

  이 fix 로 #4576(동명 default)·#4580(default interop) 의 `--minify` 도 함께 풀린다(그 PR 들이 남긴 minify 한계 해소).

  ## 검증
  - 회귀 스위트 `preserve-modules-minify-default-ref.test.ts` **16종**: 단일 default·동명 default 2개·default+named·default class × esm/cjs × **minify/non-minify**(always-write 가 non-minify 도 건드리므로 양쪽 가드).
  - preserve-modules·cross-chunk·splitting·wrapper 통합 326 + zig 전체 무회귀.

  ## `/code-review max` 반영
  - **[3]** 무조건 write 를 `preserve_modules` 게이트로(splitting 은 read 가 gated 라 write 도 낭비 → 생략).
  - **[0]** 테스트에 non-minify 케이스 추가. **[1]** dead stderr 단언 제거(runNode 가 non-zero exit 시 throw → stdout 단언+throw 가 실제 가드). **[2]** 실패 경로 temp-dir 누수 → try/finally.

- 41abf90: `--preserve-modules --minify`(ESM/CJS)에서 서로 다른 wrap dep 의 동명 export 가 붕괴하던 것 수정 (#4532 증상1 minify 잔여). preserve-modules 의 minify 를 splitting 과 **동일한 per-chunk mangle + 전역명 브리지 모델로 통합**한다.

  ```js
  // b.js: export function tag(){ return "B"; }
  // c.js: export function tag(){ return "C"; }
  // a.cjs: module.exports = require("./b.js"); require("./c.js");
  // entry: import { tag } from "./b.js"; import { tag as tag2 } from "./c.js"; import "./a.cjs";
  //        console.log(tag() + tag2());
  // node canonical: "BC"
  // 버그(--minify): "BB"  ← 전역명 게이트가 `!minify_identifiers` 로 닫혀 동명 붕괴
  ```

  ## 배경

  증상1(#4570)이 non-minify 만 고쳤다. minify 는 cross-file 네이밍 게이트(`pm_xchunk_naming`)가 `!minify_identifiers` 로 닫혀 여전히 `BB`. 게이트를 그냥 열면(band-aid) 소비자 함수의 mangled nested 로컬이 전역명(예 aliased import 의 `te`)과 충돌해 shadow → `te is not a function`(silent miscompile, `/code-review max` CONFIRMED). preserve-modules 는 mangle 를 finalize 에서 먼저 하고 전역명은 chunk phase(mangle 이후)에 negotiate 하는데, mangler 가 전역명을 미리 알 방법이 없기 때문.

  ## 수정 (Approach 3 — splitting 과 메커니즘 통일)
  1. **`computeChunkMangling` 을 preserve-modules 에도 오픈**(linker.zig): splitting 처럼 chunk phase(전역명 negotiate **후**)에 per-chunk mangle 을 돌린다. `occupied_names`(= imports_from 의 `crossChunkBindingName` = 전역명 + 별칭)를 예약하므로 mangled nested 로컬이 소비 전역명을 shadow 하지 않는다.
  2. **`pm_xchunk_naming` 을 minify 에도 오픈**(bundler.zig, `!minify_identifiers` 제거): 전역명 브리지가 mangled 이름을 파일 경계 너머로 조율한다. provider 는 `export { mangled_local as public }`(ESM)·forwarding read(CJS)로 브리지 → top-level 을 mangle 해도 소비자는 공개명으로 import 한다(공개 API 계약 유지).
  3. **래퍼 심볼(`exports_X`/`init_X`/`require_X`)을 preserve-modules mangle 후보에서 제외**(linker.zig `collectUnifiedInput`): preserve-modules 는 `preserveModulesWrapperChunk`(#4528)가 wrapper export/declaration 을 **canonical(미-mangle)** 로 직접 찍는다. mangle 하면 본문(codegen rename)은 `var n={}`·`__export(n,…)` 인데 wrapper export 는 canonical `exports_b` 라 undefined. splitting 은 wrapper 를 rename_table 경유 브리지라 mangle 해도 일관돼 제외하지 않는다.

  추가로 `/code-review max` 반영:
  - **이중 mangle 제거**(bundler.zig): preserve-modules 는 per-chunk mangle(모든 모듈이 자기 청크)이 전담하므로 finalize 의 전역 mangle 은 중복 — `compute_mangling` 에 `!preserve_modules` 를 걸어 낭비되는 full-graph mangle 을 끈다(computeRenames 는 유지).
  - **helper virtual module 래퍼도 제외**(linker.zig `is_helper_module` 브랜치): 수정 3 의 가드가 main synthetic 루프에만 있어, wrapped 헬퍼 모듈이 자기 청크가 되면 래퍼가 mangle 되던 갭을 대칭으로 닫음.

  ## 결과
  - preserve-modules minify 도 이제 **top-level 을 mangle**(rollup+terser 모델과 동일) — 공개 export 명은 브리지로 보존, 내부 로컬만 축약. 부수적 size 이점.
  - **ESM-wrap dep 의 동명 export**(a.cjs 가 require 로 wrap 강제) 붕괴·aliased 충돌·reserved default named import·배럴·ns 가 minify 에서 정상.

  ## 검증
  - 새 회귀 스위트 `preserve-modules-minify.test.ts` 38종(esm/cjs × plain/minify): 동명 붕괴 BC, aliased-import 충돌 가드(70 로컬→`te` mangle 강제), reserved default, 배럴, 4-way, cross-file 참조, ns, default 값, CJS require_X 래퍼 — 전부 통과.
  - 충돌 repro: 수정 전 `TypeError` → 후 정상.
  - zig 전체 test 통과, 통합 스위트 무회귀. splitting 무회귀(모든 변경 preserve_modules 게이트).

  ## 잔여 (#4532 epic — 이 PR 범위 밖, non-minify 에도 존재하는 별개 근본)
  - **비-ESM-wrap 동명 export 붕괴**: 동명 provider 가 CJS-flatten(a.cjs) 을 안 거치고 entry 만 import 하면(즉 ESM-wrap 이 아니면) 전역명이 안 붙어 여전히 붕괴(`T1T2T1`). 전역명이 ESM-wrap owner 로 한정돼 있어(chunk.zig, #4559 의도) 비-wrap owner 는 별도. minify·non-minify 동일.
  - **익명 `export default class{}`/`function(){}`** in ESM-wrap 모듈: 선언이 top-level 이 아니라 `__esm` 클로저 안에 assign → `export{X}` 가 미선언 참조(SyntaxError). codegen 문제로 minify·non-minify 동일. 별개 근본.
  - 증상4(multi-entry 순환), 배럴 자체 exports CJS 직접 `require("./r.js").X`(live getter).

- 1e48739: `--preserve-modules`(ESM/CJS)에서 **비-ESM-wrap** 동명 export 를 한 소비자가 여러 파일에서 import 하면 붕괴하던 것 수정 (#4572).

  ```js
  // m1.js/m2.js/m3.js: 각각 export function tag(){ return "T1/T2/T3"; }
  // a.cjs: module.exports = require("./m1.js"); require("./m2.js");   // m1·m2 만 ESM-wrap
  // entry: import { tag as t1 } from "./m1.js"; import { tag as t2 } from "./m2.js";
  //        import { tag as t3 } from "./m3.js"; import "./a.cjs";
  //        console.log(t1() + t2() + t3());
  // node canonical: "T1T2T3"
  // 버그: "T1T2T1"  ← t3 이 m1 의 tag 로 붕괴
  ```

  ## 근본 원인

  소비자 import 블록(emitter, `chunks.zig`)은 같은 export 명이 여러 dep 에서 오면 `import { tag as tag$3 }` 로 **소비자-로컬** deconflict 하는데(provider public 명 `export { tag }` 은 유지 — external API 계약), 소비자 **body 참조**(linker `effective_target`)는 `crossChunkBindingName` = `tag`(m1 과 충돌) 로 붕괴한다. 전역명이 ESM-wrap owner 로 한정(#4559)돼 non-wrap 은 전역명이 없고, import 블록의 `$N` deconflict 는 body 와 공유되지 않았다(코드 주석도 이 divergence 를 인정).

  ## 수정 (rollup 식 — provider public 명 보존)

  전역명을 non-wrap 에 확장하면 provider public export 가 리네임돼 external consumer 가 깨진다(preserve-modules 계약 위반). 대신 **소비자-로컬 deconflict 를 body 와 공유**한다:
  - import 블록이 body codegen(`buildMetadataForAst`)보다 **먼저** 방출되므로, `$N` deconflict 로 정한 소비자-로컬명(`tag$3`)을 `consumer_import_local`(per-chunk transient, `canonical module → export명 → 로컬명`)에 적어 둔다(linker.zig).
  - `effective_target` 가 전역명이 없는 cross-chunk 참조에서 이 맵을 읽어 body 를 같은 이름(`tag$3`)으로 맞춘다. import 문·body 가 일치하고 provider 는 `export { tag }` 그대로다.

  `/code-review max` 반영:
  - **explicit preserve-modules 게이트**: `consumer_import_local` 의 write(chunks.zig)·read(effective_target)를 `preserve_modules` 로 명시 게이트(암묵적 `!has_global` 대신). splitting 은 전역명이 있어 이 경로를 안 타므로 무영향이 코드에 드러난다.
  - **borrowed `loc` UAF 회피 명시**: map 은 non-wrap(.none) canonical 에서만 채워지므로, per-chunk 수명 borrowed `loc` 이 esm-wrap 전용 `export_getter_overrides` 경로로 안 흘러감을 주석에 못박음(renames 경로는 이미 dupe).

  ## 검증
  - 회귀 스위트 `preserve-modules-nonwrap-samename.test.ts` 24종(esm/cjs × plain/minify): 혼합(wrap+non-wrap), 순수 non-wrap, 동명 const, re-export 배럴, 다단계 re-export 체인, 2-consumer — 전부 통과(수정 전 전부 붕괴).
  - provider public 명(`export { tag }`)·entry 자체 export 자연명 유지 확인.
  - zig 전체 test, 통합 스위트 무회귀. splitting·단일 번들 무영향(write/read 모두 preserve_modules 게이트).

  ## 잔여 (별개 근본 — #4576)
  - **동명 `export default` / `export { foo as tag }`**(export 명 ≠ 소비자 로컬명): import 블록의 `key != binding` 분기가 `$N` deconflict·map 기록을 안 해 로컬명 중복(default esm=SyntaxError·minify=silent ND1ND1·cjs 별도). binding-keyed deconflict + cjs/minify emit 경로별 처리 필요. #4572 인프라(`consumer_import_local`)를 확장하는 후속.

- de1e03c: `--preserve-modules`(ESM 출력)에서 `import * as ns` (ESM-wrap dep) 의 멤버 접근이 `ReferenceError` 나던 것 수정 (#4532 증상2).

  ```js
  // dep.js:  export const val = 42; export function greet(){ return "G"; }
  // wrap.cjs: module.exports = require("./dep.js");   // dep 를 ESM-wrap 강제
  // entry.js:
  import * as ns from './dep.js';
  import './wrap.cjs';
  console.log(ns.val + '|' + ns.greet()); // 버그: ReferenceError: val is not defined
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

- e66329b: `--preserve-modules --platform=react-native`(+`--preserve-modules-root`)에서 **class 를 export** 하면 로드 실패하던 것 수정 (#4574).

  ```js
  // b.js:  export class Bar { greet(){ return "bar"; } }
  // a.cjs: module.exports = require("./b.js");   // b 를 ESM-wrap 강제
  // entry: import { Bar } from "./b.js"; import "./a.cjs"; console.log(new Bar().greet());
  ```

  RN 다운레벨은 class 를 `__classCallCheck`/`__extends` 헬퍼로 낮추고 그 헬퍼를 runtime helper **virtual module** 에서 import 한다. 두 버그가 겹쳐 있었다:

  ## 버그 1 — 헬퍼 이름 이중 선언 (SyntaxError)

  transform 이 헬퍼를 `var __classCallCheck = function(){…}` 로 인라인한다. 링커가 그 헬퍼를 별도 모듈에서 `import { __classCallCheck }` 로도 가져오면, 인라인 initializer 는 elide 되지만 ESM-wrap hoisting 이 수집한 **이름**이 import 와 이중 선언(`var __classCallCheck` + `import { __classCallCheck }` → `Identifier '__classCallCheck' has already been declared`).

  **수정**: `emitEsmWrappedModule`(esm_wrap.zig)에서 **helper-module import 로컬명을 hoisted var 에서 제외** — import 문이 그 바인딩을 선언하므로 진짜 소스. 단:
  - **`preserve_modules` 로 게이트** — non-preserve 는 헬퍼를 별도 모듈에서 import 하지 않고 **inline** 하며(is_helper hoist 의 `var __extends; __extends = …` assign-only preamble, #1209), 그 var 는 필요하다. 제외 필터를 non-preserve 에 걸면 회귀하므로 preserve-modules 로 한정.
  - **키는 `getCanonicalByRef`**(rename 반영) — hoisted 이름이 resolveNodeName 이라 raw 로 매칭하면 minify/deconflict 시 놓친다.
  - **필터 후 남은 이름이 0 이면 `var` emit 자체를 건너뜀** — 모든 hoisted 이름이 helper import 인 모듈에서 `var ;`(SyntaxError)가 되던 것 방지.

  ## 버그 2 — 헬퍼 모듈 import 경로 오류 (ERR_MODULE_NOT_FOUND)

  virtual helper 모듈은 outdir **최상위**에 놓이는데(bare sanitize id `runtime-class-call-check`), `computeRelativeImportPath` 가 root 아래가 아닌 그 bare id 를 소스의 **원본 절대 dir** 기준으로 상대 계산해 `../../../../runtime-…` 가 됐다.

  **수정**: dep 이 bare id(virtual helper)면 outdir 최상위 파일로 취급해 상대 계산. src 가 root 아래면 src_rel dir 에서, **src 도 root 밖이면**(RN 모노레포 hoisted dep) stem-only 로 최상위에 놓이므로 형제 `./runtime-…` 로.

  ## 검증
  - 회귀 스위트 `preserve-modules-rn-class.test.ts` 8종:
    - 4종(esm/cjs × plain/minify): named/익명 default/`extends`/plain function class + 헬퍼 import → `NDPE-B` (수정 전 SyntaxError·ERR_MODULE_NOT_FOUND).
    - `[0]` 2종: non-preserve ESM-wrap × RN downlevel 이 헬퍼 var 를 보존하며 정상 실행(`E-B`).
    - `[1]` 2종: out-of-root 소스의 헬퍼 경로가 `./runtime-…` 로 정상(`W`).
  - zig 전체 test, preserve/wrapper/cross-chunk 통합 스위트 무회귀.

  ## 한계
  - `--preserve-modules-root` 미지정 시 virtual helper 경로 계산은 출력 base 추론과 어긋나 여전히 부정확(RN/Metro 는 project root 를 주므로 실사용 영향 없음). 별도 base-추론 이슈로 후속.
  - out-of-root **non-helper 모듈**의 entry→module 지정자(같은 dir 이 아닐 때)는 이 PR 범위 밖의 일반 base-추론 문제로 남는다.

- 62eef66: `--preserve-modules` 에서 서로 다른 파일이 **같은 로컬명으로 `export default`** 하고 한 소비자가 둘 다 default import 하면 `SyntaxError: Identifier 'foo' has already been declared` 로 파싱 실패하던 것 수정 (#4576).

  ```js
  // m1.js: export default function foo(){ return "D1"; }
  // m2.js: export default function foo(){ return "D2"; }
  // entry: import a from "./m1.js"; import b from "./m2.js"; console.log(a() + b());
  ```

  방출(esm) 이 `import { default as foo }` 를 두 번 내 `foo` 중복 선언으로 깨졌다.

  ## 근본

  소비자 import 블록(chunks.zig)의 `$N` deconflict 는 **`key == binding`**(export 명 == 로컬명) 분기에서만 했다. default 는 key=`default`, binding=`foo`(익명은 `_default`)라 **`key != binding` 분기**로 가는데 그 분기가 deconflict 를 안 해 로컬명이 여러 dep 에서 중복됐다. #4572(named 동명)와 같은 계열이지만 emit 분기가 다르다.

  ## 수정

  **선언되는 소비자-로컬은 항상 binding** 이므로, esbuild/rollup 리네이머처럼 **소비자 청크의 "이미 쓰인 로컬명" 집합(`used_locals`)으로 유일 이름을 발급**한다(`mintConsumerLocal`): 비었으면 binding 그대로, 이미 쓰였으면 `binding$N`(N=2,3,… 중 `used_locals`·다른 binding 의 자연명 집합에 없는 첫 이름). 두 emit 분기(`key==binding` 축약 / `key!=binding` alias)와 ESM-wrap dep 의 `let X;` forwarding 사이트(#4528)가 **같은 `used_locals` 를 공유**한다. deconflict 된 이름은 `consumer_import_local`(#4572) 맵에 기록해 body 참조(effective_target)를 맞춘다.

  핵심은 **per-binding 카운터가 아니라 집합 기반 유일성**이다 — 카운터는 한 그룹의 `foo$2` 가 다른 심볼의 자연명 `foo$2`(또는 사용자 심볼)와 충돌할 수 있다(아래 검증 [0]). 이름이 고정된 심볼(전역명 `has_global`·lazy)은 pre-pass 로 `used_locals` 에 먼저 예약해, 동명 plain 로컬이 그 이름과 충돌하면 순서와 무관하게 deconflict 된다(아래 [1]). `export const foo` + `export default function foo` 같은 cross-branch 충돌도 같은 집합으로 해소된다.

  ## 검증
  - 회귀 스위트 `preserve-modules-samename-default.test.ts`: named/익명 default·cross-branch·3-way + **[0]** dedup 이름이 자연 `foo$2` 심볼과 충돌 회피(→`foo$3`)·**[1]** 전역명 고정 default + plain 동명(import 순서 무관 `PW`) — esm plain/whitespace/syntax minify. cjs 는 중복 로컬 선언이 없고 deconflict 됨을 emit 으로 확인.
  - preserve-modules 160·cross-chunk/splitting/wrapper 186 통합 + zig 전체 test 무회귀.

  ## `/code-review max` 반영

  max 리뷰가 초기 커밋(per-binding 카운터)에서 두 correctness 회귀를 짚어 집합 기반(`used_locals`)으로 재설계했다:
  - **[0]** dedup `binding$N` 이 다른 binding 의 자연 `$N` 명과 충돌(재현) → `used_locals`+자연명 집합으로 유일성 판정.
  - **[1]** `!has_global` 게이트가 전역명 default 를 dedup 에서 제외해 순서-의존 중복(재현) → 고정명 pre-pass 예약.
  - **[2]** 중복 alias 분기 → `key != local` 단일 분기로 병합. **[3]** cjs 테스트 vacuous → positive 단언 추가.

  ## 별개 선행 버그(별도 후속)
  - **`--minify-identifiers`**: mangler 가 소비자 default import 의 로컬은 개명하는데 body 참조는 다른 심볼로 취급해 발산(silent). 이 fix 유무와 무관하게 main 도 동일 — mangler 심볼-정체성 문제로 별도.
  - **cjs default interop**: `module.exports = foo` provider 를 소비자가 `{ default: foo }` 로 구조분해해 `foo is not a function`. 단일 default 도 실패(중복과 무관). 이 fix 로 중복선언 SyntaxError 는 제거되지만 interop 오류는 별도.

- 40e3d82: `--preserve-modules` × wrap 된 모듈의 남은 결함 3건 수정 (#4528). 셋 다 빌드 exit 0 · 실행만 실패였다.

  ## 1. wrap 된 ESM dep 의 named import 가 아예 바인딩되지 않았다

  ```js
  // b.js  (CJS 가 require 하므로 ESM-wrap 됨)
  export function tag(){ ... }
  // entry.js
  import { tag } from "./b.js";   // → ReferenceError: tag is not defined
  ```

  **wrap 종류마다 규칙이 다르다** — 이걸 놓쳤다.
  - **CJS**: 본문 **전체**가 `__commonJS` 클로저 안 → 파일 top-level 에 export 명이 없다(래퍼뿐). 그래서 심볼을 import 하면 provider 가 내지도 않는 이름을 가져와 SyntaxError.
  - **ESM-wrap**: 클로저에 들어가는 건 **부수효과 문장뿐**이고 `function tag(){}` 같은 **선언은 파일 top-level 에 남는다**. 소비자도 bare 로 참조한다(단일 번들과 동일).

  CJS dep 만 심볼 목록을 버리고, ESM-wrap dep 은 래퍼 **와 함께** 심볼도 가져오도록 했다. provider 쪽도 두 군데 전제가 거짓이었다 — "codegen 이 entry 모듈의 `export {}` 를 이미 낸다"(ESM) / "emitCjsEntryExports 가 이미 깐다"(cjs) — wrap 된 모듈은 둘 다 안 한다(`__export(exports_X, …)` 로 들어간다).

  ## 2. `--minify` 에서 래퍼 이름이 3자 불일치

  ```js
  // b.js (소비자)          // a.js (provider)
  import{o}from"./a.js"     export{require_a}
  var a = require_a();      // ← 본문은 또 다른 이름
  ```

  `rename_table` 이 **청크별**이라 provider emit 시점과 consumer emit 시점에 같은 심볼이 다른 이름으로 해석됐다. 래퍼 선언은 emitter 가 **직접** 찍어서 codegen 의 rename 대상이 아니다(= 본문은 canonical 을 쓴다) → **canonical 하나로 통일**하면 본문·provider·consumer 3자가 항상 일치한다.

  ## 3. CJS user entry 가 본문을 실행하지 않았다

  wrap 된 CJS 진입점은 아무도 `require_X()` 를 부르지 않아 **본문이 아예 실행되지 않았다**(`console.log` 조차 안 찍힘). 진입점만 직접 호출한다 — dep 는 여전히 lazy 다(eager 호출은 CJS 순환을 죽인다, #4526).

  ⚠️ preserve-modules 는 **모든 모듈이 자기 `entry_point` 청크**라 청크 종류로는 진입점을 못 가른다 — 모듈의 `is_entry_point` 플래그를 봐야 한다.

  추가(코드리뷰): 첫 수정이 **회귀 4건**을 만들었다.
  - **`module.exports = require_X()` 가 exports 객체를 교체**해, 바로 위에서 깐 `exports.require_X` 를 지웠다 → 이 entry 를 import 하는 다른 파일의 forwarding 썽크가 `undefined.apply` 로 죽는다. 교체 뒤 **재부착**.
  - **`pm_entry_call` 이 `.cjs` 만 봐서** ESM-wrap user entry 는 여전히 본문 미실행이었다(같은 결함의 절반). `isWrapped()` 로 넓혔다.
  - **cjs 의 `exports.X = X` 는 값 스냅샷**인데 ESM-wrap 모듈의 `const`/`class` 는 `__esm` 클로저(=`init_X()`) 안에서 **늦게 대입**된다 → 파일 top-level 스냅샷은 **undefined**(함수 선언만 hoisting 으로 우연히 살아남아 버그가 가려졌다). provider 는 **getter** 로 노출, 소비자는 **init 시점 갱신**. ⚠️ 선-init 은 답이 아니다 — ESM-wrap 끼리 순환하면 아직 미평가인 상대의 `init_Y`(undefined)를 부른다.
  - **회귀 가드가 무력했다** — `buildPm` 에 `minify` 파라미터를 넣는 편집이 조용히 실패해 `--minify` 테스트가 minify 없이 돌고 있었다. 이제 esm/cjs × plain/minify 매트릭스를 실제로 돈다.

  추가(코드리뷰 3차): 앞선 수정이 **실제로는 동작하지 않았다.**
  - **소비자 forwarding 이 심볼 갱신을 `init_X()` 호출 _전에_** 했다 → 값이 `__esm` 클로저 안에서 대입되므로 **여전히 undefined** 였다(init 은 memoize 라 재갱신 기회도 없다). **함수 선언만 hoisting 으로 살아남아** 테스트가 통과했고, 그 테스트는 **import 순서 덕에 provider 의 init 이 먼저 돌아** 버그를 가리고 있었다 — 내가 "제거했다" 고 주장한 바로 그 은폐 패턴이다. init 을 먼저 돌리고 그 다음 갱신하도록 고쳤다.
  - **동명 심볼을 내는 wrap 된 dep 이 둘이면 `let tag;` 가 중복 선언**돼 파싱 불가였다. 심볼 분기와 같은 `$N` deconflict 를 적용했다.

- 9593983: 증분 emit 캐시가 provider 의 graph-derived emit 상태 변경을 놓쳐 stale 바이트를 재사용하던 버그 수정 (#4535, emit-캐시 층).

  ## 증상

  non-dev 증분 빌드(dev server / NAPI `rebuild()`)에서 **provider 모듈 변경이 소비자의 방출 바이트를 바꿔야 하는데** 소비자가 cache-hit 으로 **옛 바이트를 재사용** → 조용한 오컴파일. 예: 소비자가 import 한 CJS 가 다른 모듈이 `require()` 를 추가해 `wrap_kind` 가 flip 돼도, 소비자 source/mtime 은 그대로라 interop emit 이 옛 형태로 박제. re-export barrel 을 통해 origin 이 심볼을 rename 하면 소비자가 옛 이름을 참조해 `ReferenceError`.

  ## 루트커즈

  `compiled_cache.computeInputHash` 는 소비자 자신의 상태(mtime/source/options/used_exports/import path)만 해시하고, **provider(및 그 전이 dep)의 post-link emit-영향 상태**(wrap_kind·exports_kind·canonical 이름·래퍼명·상수값·export 순서 등)는 안 본다. import record 는 "어디로 resolve 됐나(path)"만 보고 "그 대상이 어떤 wrap/export 인가"는 안 본다.

  ## 수정 — Merkle deep-fold
  - `Linker.emitFingerprint(m)` = 모듈의 **local** emit-영향 상태 해시: Module 필드(wrap*kind·exports_kind·has_cjs_export_signal·can_skip_cjs_default_interop·uses_top_level_await·isInCycle) + 래퍼명(require*/init*/exports*/synthetic) + export 별(exported_name·자기 canonical·자기 const 값), **order-dependent**(export 순서가 소비자 inline namespace object 순서를 바꾸므로).
  - `Linker.emitDeepFingerprint(M)` = `local(M) *31 +% Σ deep(dep)` (Merkle) — `import_records` 재귀(require.context 대상은 `rec.context_resolved_paths`→`path_to_module` 로 해석). **re-export barrel 을 통한 origin 의 전이 상태(이름·wrap·star `export *`)를 자동 흡수**한다.
  - `computeInputHash` 가 각 resolved import 대상(+ 모듈 **자신**)의 **deep** fingerprint 를 키에 접어 provider 변경 시 소비자 cache miss 를 유발.
  - **자신의 fingerprint 도 접음**: 다른 모듈이 `require()` 를 추가해 이 모듈의 wrap_kind 가 flip 되면 자기 source 불변이어도 자기 emit 이 바뀌므로.
  - **non-dev 전용**: dev 는 모듈을 registry(path-id)로 래핑해 provider 변경이 소비자 바이트를 안 바꾸므로 stale 재사용이 정답(HMR 핫패스 보호 — emit_fps 빈 slice).
  - 사이클: on-stack 재방문 시 local 만 반환해 무한재귀 차단. 깊이 상한(4096)으로 매우 깊은 선형 체인의 native stack overflow 방어.
  - `is_included`(tree-shaking)는 증분 경로에서 빌드 간 비결정적이라 fingerprint 제외(provider dead/alive 는 used_export_names + path-set clear 로 커버).

  ## 범위 / 분리 (별도 이슈)
  - **커버**: wrap_kind flip · exports_kind · canonical/래퍼 이름 · export 재정렬 · **named/star re-export barrel 통한 origin rename**. warm≡cold 회귀 가드 4종(wrap_kind flip · named barrel rename · export reorder · star barrel rename).
  - **require.context 확장 대상**: `context_resolved_paths`→`path_to_module` 로 fold(구조적 커버). ⚠️ live warm≡cold 가드는 플러그인이 context_resolved_paths 를 채워야 가능해 유닛으로는 미검증(#4538 과 동일 제약) — emitter/forEachWrapperImportTarget 와 동일 해석 경로라 구조적 정확.
  - (provider const 값도 local fp 에 접히나, 상수 인라이닝의 실제 stale 는 대개 #4544 AST-mutation 층이 지배 — 그쪽에서 종결.)
  - **#4544 (const-materialize AST-mutation)**: `export const N=42` 류 인라이닝은 tree_shaker 가 소비자 AST 를 파괴적 in-place mutation(`z`→`1`)하고 그게 `module_store` 에 남는 **두 번째 캐시 층**. Merkle 이 소비자를 정확히 miss 시켜도 재emit 이 mutated AST 를 써서 여전히 stale — emit-캐시 fp 범위 밖.
  - **잔여(비-회귀, 후속)**: 사이클 back-edge 로만 도달하는 전이 provider(완전 정확엔 SCC 축약 필요, #4545); node/babel interop mode(provider 의 importer 방향 의존)·shared-ns var 이름. 모두 **단조 안전**(fp 는 해시 입력을 추가만 → 새 false-hit 불가; 미해시분은 fp 미도입 시와 동일 stale, 회귀 아님).

  검증: zig build test 6231/6231 · effect/zod/three cold 빌드 byte-identical(fp 는 compiled_cache 경로 전용) · integration 4247 pass(known flake 2종 제외).

- 9433f96: reg_split(iife/umd/amd)·cjs 에서 **여러 entry 가 공유하는 `--run-before-main`** 이 common 청크로 갈 때 entry 가 그 init 을 잘못된 형태로 가져와 실패하던 것 수정 (#4555).

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

- 7916018: `--format iife|umd|amd --splitting` 에서 `run_before_main` 모듈이 `manualChunks` 로 다른 청크에 분리되면 entry 청크에 ESM `import` 를 방출해 SyntaxError 나던 버그 수정 (#4552). RBM 모듈을 entry 청크에 **co-locate** 한다.

  ## 증상

  `--format iife --splitting` + `runBeforeMain: ['./setup.js']` + `manualChunks` 로 setup.js 를 별도 청크로 빼면, entry 청크에 `import { init_setup } from "./rbm-chunk.js";` 가 나온다. reg_split 청크는 `(function(g){...})` self-register IIFE 라 top-level ESM import = `SyntaxError: Unexpected token '{'`. 빌드 exit 0 · 실행만 실패.

  ## 루트커즈

  reg_split(iife/umd/amd)은 registry 모델(`__zntc_require`)이라 다른 청크의 RBM 을 근본적으로 실행할 수 없다: 그 RBM 은 `var init_X = __esm({...})` (lazy)로 감싸지고 init 심볼이 factory 스코프 밖으로 안 나온다. 그래서 entry 청크가 (a) ESM `import`(IIFE 서 무효 문법) (b) `__zntc_require`(factory 실행하나 RBM body 미실행) (c) scope 밖 `init_X()` 호출 — 셋 다 깨진다. RBM 은 **entry 앞에서 실행돼야 하므로 애초에 split 되면 안 된다**(Metro 도 runBeforeMainModule 을 번들 최상단에 두고 split 하지 않음).

  ## 수정 — RBM co-location (reg_split 한정)

  chunk.zig 의 manual 청크 배정에서 **run_before_main 클로저를 제외**한다 — dynamic import 대상(#1848/#1849)·user entry(#4553)가 이미 제외되는 것과 같은 방식. `GenerateOptions.run_before_main` + `reg_split` 로 받아 `rbm_modules` set 을 만들고, manual seed 수집(resolver·record)·Phase 2.5 BFS 전파에서 skip. RBM 은 entry 의 dep 로 링크돼 있어(build_flow linkExecutionRoots) 제외되면 entry 청크에 자연히 co-locate 된다. 매칭된 **non-RBM** 모듈은 종전대로 manual 로.
  - **reg_split 한정**(iife/umd/amd): esm/cjs 는 cross-chunk RBM 이 valid ESM `import` 로 동작하므로 사용자의 manualChunks 배치를 **존중**(강제 co-locate 안 함). reg_split 아닐 땐 `rbm_modules` 가 비어 exclusion no-op.
  - **최상위 RBM 만이 아니라 클로저 전체**: RBM 이 import 한 모듈(transitive static dep)이 manual 로 빠지면 entry prelude(emitter `collectRunBeforeMainClosure`)가 그걸 cross-chunk 참조해 똑같이 깨진다 → RBM 클로저 전체를 제외.
  - manual 미설정이면 스캔 자체를 skip.

  ## 범위 / 후속
  - **단일 entry**(RN 전형, RBM 의 실사용): 완전 해결(공유 없음 → RBM 은 entry 청크에만).
  - **여러 entry 가 같은 RBM 공유**: RBM 이 `common` 청크로 가는데, zntc 는 1 모듈 = 1 청크라 각 entry 청크로 **복제(co-locate)가 불가** → registry-native(common 청크 eager-run) 필요 → **#4555 후속**. main 에서도 pre-existing(이 수정이 회귀 아님).
  - **degenerate 조합**(같은 co-location 한계, #4555 영역): (a) manual 청크의 라이브러리가 app 의 RBM 을 import(entry 스코프 init 심볼 미도달), (b) RBM 이 동시에 `import()` 대상/federation-expose 라 Phase 1b 에서 자기 dynamic 청크가 됨. 둘 다 reg_split 에서 cross-chunk 참조 → 실사용 거의 없음.

  참조: Metro `getModulesRunBeforeMainModule` = 번들별 최상단 co-locate(split 안 함). rollup/esbuild 는 run_before_main 개념 없음.

  ## code-review 반영
  - **[reg_split 게이트]**: RBM co-location 은 **reg_split 한정** — esm/cjs 는 cross-chunk RBM 이 valid ESM import 로 동작(테스트가 `node` 실행으로 확인). 처음엔 무조건 제외라 esm/cjs 의 사용자 manualChunks 배치를 무성 무효화했다.
  - **[클로저]**: 최상위 RBM 만이 아니라 **transitive static 클로저** 를 제외(emitter `collectRunBeforeMainClosure` 가 prelude 로 끌어오는 것과 일치) — RBM 이 import 한 모듈이 manual 로 빠지면 여전히 cross-chunk break.
  - **[DRY]**: `reg_split = (iife|umd|amd) and !preserve_modules` 를 하드코딩하던 4곳(bundler + emitter 3)을 기존 미사용 헬퍼 `Format.isWrappedFormat()` 로 통일 — 청커 게이트와 방출부가 어긋나 초록 빌드로 버그 재발하는 드리프트 차단.
  - manual 미설정이면 rbm_modules 빌드 skip.

  검증: zig test(chunk_test #4552 co-locate 유닛) · esm/cjs/iife/umd/amd × manualChunks-RBM `node` 실행(`ENTRY sees DEV_SET`, ESM import·별도청크 없음) · 클로저·esm-존중 가드 · 인접 polyfill-rbm/manual-chunks/splitting 통과.

  Closes #4552

- 6881eb0: #4533(주입된 래퍼 참조가 소비자 스코프 바인딩에 가려짐)의 **edge 모드** 커버 (#4538).

  #4533 은 cold 공통 케이스를 닫았고, 근본 원인(zntc non-minify 리네이머가 scope-0 중심)의 잔여 edge 를 여기서 메운다.

  ## 1. 런타임 헬퍼명 shadow — ESM 소비자 **scope 0**(top-level)

  ESM 소비자가 CJS 를 import 하면 `__toESM(require_x())` 가 소비자 scope 0 에 주입되는데, 예전엔 스캔이 ESM 소비자의 scope 0 을 건너뛰어(래퍼명은 #4530 예약이 담당) 사용자의 top-level `function __toESM(){}` 이 가려졌다 → `TypeError`. 이제 소비자 **전 스코프**(0 포함)를 대조한다 — 래퍼명은 skip-guard(#4530 이 이미 개명)로 no-op, 헬퍼명만 새로 커버.

  ## 2. `require.context` 로 도달하는 래퍼

  소비자 스캔이 `rec.resolved` 만 따라가 `require.context` 매치 모듈(`context_resolved_paths` 로 해석, `rec.resolved`=none)을 빠뜨렸다. 이제 emitter 와 **동일 경로**(`context_resolved_paths`→`path_to_module`→`getModule`)로 그 래퍼도 검사한다.

  ## 3. HMR/incremental warm 재빌드 fingerprint

  `resolveWrapperConsumerShadows`(#4533)는 CJS 소비자의 scope 0(클로저 지역)도 개명하는데, `moduleFingerprint`(G2)는 CJS scope-0 사용자 로컬을 제외한다 → warm 재빌드에서 scope-0 shadow 바인딩이 새로 생겨도 fingerprint 불변 → stale snapshot 재사용 → shadow 재출현. CJS scope-0 이름을 fingerprint(G5)에 접어 넣어 그 변화를 잡는다.

  ## 범위
  - 커버: 위 3종(전부 code-review max CONFIRMED). ESM scope-0 헬퍼는 통합 가드, fingerprint 는 renameReuseGuard 단위 가드(둘 다 비-공허 확인).
  - **미해결(장기)**: HMR rename-reuse 스냅샷이 nested rename 시 통째 폐기돼 warm 이 full 재계산으로 떨어지는 **perf** 저하(정확성 유지). 근본 처방=non-minify 에도 mangler급 scope-aware 리네이머(#4538 원 이슈에 기록).

  검증: zig build test 6226/6226 · effect/zod/three --minify byte-identical(size 0).

  ## code-review 반영 (2차)
  - **[0] fingerprint 상쇄 버그**: CJS scope-0 fold 를 nested(0xc0)와 **다른 seed(0xc1)** 로 — 같은 seed·같은 누산기면 이름이 scope-0↔nested 로 **이동**할 때 상쇄돼 fingerprint 불변(stale reuse). unit 가드 추가(비-공허 확인).
  - **[3] fold 과잉무효화**: `moduleImportsWrapped` 게이트 추가 — wrapped import 가 있는 CJS 모듈만 scope-0 을 fold(안 그러면 shadow 불가능한 CJS 편집마다 warm reuse 상실).
  - **[1] require.context per-chunk 예약**: computeRenamesForModules 의 참조측 예약이 `require_context` 레코드(rec.resolved=none)를 빠뜨려 pickConsumerShadowName 후보가 형제 래퍼와 겹칠 수 있던 것 — context_resolved_paths 도 reserveWrapperNames.
  - **[5] require.context \_\_toESM 과잉**: emitter 는 context 자리에 \_\_toESM 을 안 주입 → deconflictConsumerShadows 에 `inject_to_esm` 플래그로 제외.
  - **[4]** forEachNestedBindingName docstring 갱신(fold 로 G5 가 상위집합인 게 의도임을 명시).

  ⚠️ require.context 경로는 **플러그인이 매치를 해석**(context_resolved_paths)해야 채워져 플러그인 없는 통합 테스트로는 라이브 검증 불가. fix 는 emitter.zig 의 주입 경로와 **대칭**(동일 context_resolved_paths→path_to_module→getModule)이라 정확성은 구조적으로 보장.

  ## code-review 반영 (3차)
  - **[0] require.context `__toCommonJS` shadow**: dev 단일번들 require.context codegen 은 대상 wrap_kind 무관하게 매치마다 `(__zntc_modules[id].fn(), __toCommonJS(__zntc_modules[id].exports))` 를 찍어 `__toCommonJS` 를 **항상** 주입한다. names 배열은 `__toCommonJS` 를 esm 에만 넣어 CJS require.context 대상의 `__toCommonJS` shadow 를 놓쳤다 → `via_context` 플래그로 context 자리엔 `__toCommonJS` 항상(·`__toESM` 제외).
  - **[1] 중복 walk 통합**: require.context 대상 열거가 fingerprint 게이트·shadow rename·per-chunk 예약 3곳에 복붙돼 있던 것을 `forEachWrapperImportTarget` **단일 iterator** 로 묶음(드리프트 방지 — 이 레포 단골 루트커즈).

  ## code-review 반영 (4차, 최종)
  - **죽은 방어 가드 제거**: `deconflictConsumerShadows` 진입부의 `.none && synthetic==null` 재검사는 유일 호출 경로인 `forEachWrapperImportTarget`(위 [1] iterator)가 이미 pre-filter 하므로 항상 false → 제거하고 `.none` 판단을 iterator 한 곳으로 통일(통합 목적과 정합). 동작 무변경.

- 4cd691e: 구조분해/객체리터럴 shorthand 의 값 치환이 **프로퍼티 이름까지 바꾸던** 버그와 `undefined` peephole 의 섀도잉 오적용 수정 (#4515).

  shorthand `{x}` 는 노드 **하나**가 프로퍼티 이름(키)이자 값이다. 그런데 파서는 `({x} = o)` 의 `x` 도 늘 `identifier_reference` 로 태그하므로, codegen 이 이걸 그냥 값으로 방출하면 값 치환(mangler rename / 상수 인라인 / `undefined`→`void 0`)이 **키까지 같이** 바꾼다.

  ```js
  {exports}    → {$e}          // CJS 래퍼 안에서 키가 바뀜
  {undefined}  → {void 0}      // SyntaxError
  ```

  치환이 일어날 자리면 longhand(`이름: 값`)로 펼치도록 했다. 자리(값 / 대입대상)는 호출자가 `ShorthandSlot` 으로 알려준다 — 파서에서 태그를 바꾸면 `makeRestExcludeKey` 같은 태그 스위치 소비자들이 조용히 깨진다.

  함께 수정:
  - **패턴 프로퍼티의 computed key 를 semantic 이 방문하지 않았다** — `({[k]: t = d} = o)` 의 `k` 가 읽기 참조로 안 잡혀 rename/DCE 에서 누락됐다.
  - **`undefined` → `void 0` peephole 이 섀도잉된 지역 바인딩에도 발동**했다. 가드가 `sym_id == null` 하나였는데 `sym_id` 는 linking metadata(= 번들 모드)가 있을 때만 채워진다 — transpile 모드엔 metadata 가 없어 **항상 null** 이라 "unbound global" 판정이 무조건 참이었다.

    ```js
    function f(x) {
      let undefined = x;
      return { undefined };
    }
    f(5); // node: {"undefined":5}   zntc(버그): {}   ← 문법 유효, 값만 틀림
    ```

    섀도잉이 없으면 그대로 치환하므로 size 회귀는 없다.

  - `({[k] = 1} = o)` 처럼 computed key 에 default 를 붙인 **invalid 문법을 accept** 하던 것도 거부.

  추가(코드리뷰): **import 바인딩도 섀도잉으로 봐야 한다.** `import { v as undefined }` 의 local 은 별도 `binding_identifier` 노드가 아니라 `import_specifier` 의 오른쪽 자식이고 태그가 `identifier_reference` 다. 그래서 바인딩 스캔이 놓쳤고, 그 local 이름 **자신**이 peephole 을 맞아 `import { v as void 0 }` — **파싱 불가** 산출물이 나왔다. `import undefined from` / `import * as undefined` 도 같다. 또 `targetIdentSafeToEmit` 이 술어를 이름으로 재구현하고 있어 섀도잉 검사를 건너뛰었다 — `Codegen.undefinedPeepholeApplies` 로 위임했다.

- 16f1fda: `--splitting` 에서 CJS/ESM-wrapped **user entry** 모듈이 호출되지 않아 본문이 실행되지 않던 버그 수정 (#4537).

  ## 증상

  entry 가 `require()` 를 써서 `__commonJS` 로 래핑되면(`var require_entry = __commonJS({...})`), `--splitting` 빌드에서 **아무도 `require_entry()` 를 부르지 않아** entry 본문이 통째로 미실행이었다. 빌드 exit 0 · 파싱 통과 · **실행만** 무동작(`node out/entry.js` 가 아무것도 출력 안 함).

  ## 루트커즈

  wrapped entry 호출 emit 이 세 경로의 게이트에 전부 걸려 표준 splitting 에서 어디서도 안 나왔다:
  - `dev_split_chunk` — `reg_split`(iife/umd/amd) 한정 + entry 자신은 skip
  - `preserveModulesWrapperChunk` — `preserve_modules` 한정
  - `reg_split` bootstrap(`__zntc_require`) — iife/umd/amd 한정

  단일번들은 맨 끝에서 `require_X()`/`init_X()` 로 entry 를 실행하고(`emitter.zig`), preserve-modules·reg_split 도 각자 호출하는데, **표준 `--splitting`(esm/cjs, 비-preserve-modules)만** 그 호출을 빠뜨렸다.

  ## 수정

  `chunks.zig` 청크 조립부에 단일번들과 대칭인 호출을 추가 — `!reg_split and !preserve_modules and chunk_is_user_entry` 이고 entry 모듈이 wrapped 이면 body 끝에서 `appendModuleCall` 로 호출. reg_split·preserve-modules 는 각자 담당하므로 게이트로 제외(이중호출 방지, `__commonJS`/`__esm` memoize 라 설령 중복돼도 본문은 1회). CJS-format 청크의 TLA(.esm+top-level await) entry 만 제외(top-level await 불가).

  esbuild/rolldown 은 entry 를 아예 wrap 하지 않고 scope-hoist 인라인 실행하지만, zntc 는 "entry wrap + 호출" 모델(단일번들·preserve-modules·reg_split 전부)이라 그 모델과 일관되게 splitting 도 호출하도록 맞춘 것 — wrap_kind 분류를 바꾸는 광범위 변경(#4522-4538 campaign 전체)을 피한 저위험 root-cause 수정.

  검증: zig 6227/6227 · split-cjs-cross-chunk 19 pass(esm/cjs 가드 2종 추가, 빈 dist 실행 non-vacuous) · 인접 splitting/wrap 145 pass · effect/zod/three --minify byte-identical.

  ## code-review 반영
  - **[3] --minify 변형 추가**: 회귀 가드에 esm/cjs × plain/minify 4종. 호출은 `appendModuleCall` 이 rename_table 로 이름을 풀어 선언측과 일치(minify 래퍼명 `require_entry`→`$c` 축약도 실측 정상). 파일 규약(minify-only 회귀 방지).
  - **[4] TLA 가드 통합**: `wrap_kind==.esm and uses_top_level_await` 술어가 세 entry-invoke 지점(dev_split·reg_split·표준 splitting)에 복붙돼 있던 것을 `isTlaEsmModule` helper 로 단일화(각 지점의 컨텍스트별 await-합법성 게이트는 유지).
  - **[0] known limitation (범위 밖·무회귀)**: wrapped-CJS entry 를 외부에서 `require()` 로 소비하면 exports 가 청크 module.exports 에 노출되지 않는다(호출 반환값 discard). **단일번들 `--format=cjs` 도 동일**(실측 `result=undefined`) — zntc "wrap entry+호출" 모델의 선재 한계이지 이 수정의 회귀가 아니다. `module.exports=require_X()` 확장은 pm 블록이 경고한 손상 위험이 있어 별도 이슈 #4542.
  - **[2] known limitation (범위 밖·무회귀)**: CJS-format + ESM-wrap + top-level await entry 는 top-level await 불가로 침묵 미실행(additive 라 pre-fix 대비 무회귀). esbuild식 async-IIFE 래핑은 별도 기능.

  ## code-review 반영 (2차)
  - **[3] non-vacuity 가드 강화**: `toMatch(/__commonJS|\$c/)` 는 helper 정의·형제 `require_legacy` 래퍼와도 매칭돼 scope-hoist entry 를 진공 통과시켰다. plain 변형에서 entry **자기** 래퍼 `var require_entry =` **선언 + `require_entry();` 호출**을 직접 확인(회귀 시 실패)으로 교체.
  - **[4] multi-chunk 가드**: `.js` 파일 >1 assert 추가(청킹 붕괴 시 진공 방지).
  - **[1] 별도 선재 버그 발견(범위 밖)**: entry(또는 임의 청크)가 raw `require("./x.cjs")` 하고 그 CJS 가 common chunk 에 안착하면, 소비자 청크가 common chunk 를 side-effect import 만 하고 `require_X` 를 **import 도 export 도 안 해** `ReferenceError: require_X is not defined`. **entry 를 미-wrap 시켜 이 수정을 끈 상태에서도 동적 import 된 비-entry 청크가 동일 크래시** → 내 수정과 독립인 #4494/#4522 계열 raw-require 변종. 별도 이슈 #4541.
  - **[2] manualChunks 로 relocate 된 entry(범위 밖)**: entry 모듈을 manual 청크로 옮기면 `chunk_is_user_entry`=false 라 미호출(선재 #4537 하위케이스, 회귀 아님). 리뷰의 "선언/호출 분리 → ReferenceError"는 재현 안 됨(entry 청크 자체가 없어짐). 별도 이슈.

  ## code-review 반영 (3차, 최종)
  - **entry_error_guard parity**: 표준 splitting entry 호출을 `appendModuleCall`→`appendGuardedModuleCall` 로 교체 — 단일번들과 동일하게 `entry_error_guard`(RN/Metro) 활성 시 `__zntc_guarded(require_X)` 로 wrap. guard 비활성(기본)엔 `shouldGuard`=false 라 `appendModuleCall` 로 fallback → **출력 byte-identical**(repro 확인). reg_split/dev_split 은 factory/bootstrap 자체 error 처리라 그대로.
  - **테스트 주석 정정**: minify rename 회귀는 `runNode` 가 non-zero exit 시 throw 하므로 "빈 stdout"이 아니라 thrown error 로 드러남.
    검증: zig 6227/6227 · split/iife/umd/pm/dev/RN(es5-rn) 인접 127 pass · guard-off byte-identical.

- 9a26e88: `--splitting` 에서 **선언이 tree-shake 된 심볼이 청크의 `export {}` 에 남아** node 가 모듈 로드를 거부하던 버그 수정 (#4495).

  ```
  SyntaxError: Export 'extra' is not defined in module
  ```

  크로스-청크 export/import 목록(`chunk.exports_to` / `chunk.imports_from`)은 **스캐너 시점 메타데이터**(`import_bindings` / `export_bindings`)만 보고 만들어졌다. 그런데 그 뒤에 tree-shaker 가 선언을 지우는 경로가 두 가지 있다.
  - **크로스-모듈 const-inline**: `export const extra = 1` 은 소비자 AST 에 리터럴 `1` 로 박히므로 참조가 0 → 선언 statement 가 DCE.
  - **미사용 named import**: `import { unused } from "./barrel"` 를 실제로 안 쓰면 참조가 애초에 0 → 마찬가지로 DCE.

  두 경우 모두 provider 청크는 선언 없이 `export { extra };` 를 내보내고, 소비자 청크는 `import { extra } from "./chunk-X.js"` 를 그대로 유지했다. **빌드 exit 0 + 모든 청크 파싱 통과** 라 산출물 재파싱 게이트로는 잡히지 않고, node 가 모듈을 **링크**할 때 거부한다.

  이제 크로스-청크 심볼 등록 지점(`addCrossChunkSymbol`)이 canonical 선언의 생존 여부를 확인해, DCE 된 심볼은 provider 의 `export {}` 와 소비자의 `import {}` 양쪽에서 함께 빠진다. emitter 가 statement DCE 를 건너뛰는 모듈(래핑 모듈 / `export *` 소스 / 청크 entry + non-minify / tree-shaker 비활성)은 선언이 그대로 남으므로 보수적으로 유지한다.

  번들을 실제로 **실행**하는 스모크 스위트(`split-runtime-smoke`)를 함께 추가했다.

- 8685326: `--splitting` 에서 함수-로컬 `const x` 가 import 가 해석되는 module-level `const x` 를 shadow 할 때, 초기화식이 로컬 자신을 참조하는 **self-TDZ**(`const channels = channels.set(...)`)가 되던 것 수정 (#4563).

  ```js
  // reusable.js:  const channels = new Channels(...); export default channels;   // 싱글톤
  // rgba.js:
  import _channels from './reusable.js';
  const rgba = (r) => {
    const channels = _channels.set({ r }); // 로컬 channels 가 싱글톤 channels 를 shadow
    return channels;
  };
  // 버그(splitting): const channels = channels.set(...) → ReferenceError: Cannot access 'channels' before initialization
  ```

  실제 mermaid 를 `--format=esm`(minify 없이)로 빌드하면 khroma(rgba 등)가 이 위상으로 인라인돼 `channels` self-TDZ 로 `mermaid.render()` 가 크래시했다. (#4560/#4564 로 **minify** 경로는 이미 렌더됐고, 이건 **non-minify** 경로 블로커.)

  ## 근본 원인

  zntc 가 import 참조 `_channels` 를 싱글톤 canonical `channels` 로 해석하면 함수-로컬 `channels` 와 충돌한다. **비-splitting**(글로벌 `computeRenames`)은 `resolveNestedShadowConflicts` 로 이 충돌을 감지해 싱글톤 canonical 을 `channels$1` 로 리네임하는데, **splitting** 의 per-chunk 리네이머(`computeRenamesForModules`)엔 그 패스가 빠져 있었다 → splitting 에서만 로컬이 싱글톤을 가려 self-TDZ.

  ## 수정

  `computeRenamesForModules`(per-chunk)에 `resolveNestedShadowConflicts` 를 추가한다(글로벌 경로와 동일 위치). `only: ?[]const ModuleIndex` 파라미터로 청크 모듈 한정, **target(정의)이 consumer 와 같은 청크일 때만** 리네임.

  `/code-review max` 반영:
  - **preserve-modules(module_to_chunk==null) 제외**: null 이면 `chunkOfModule` 이 전부 `.none` → same-chunk 가드가 `.none != .none`=false 로 fail-open 해 cross-module target 을 over-rename(별도 출력 파일이 원명 export → ReferenceError). preserve-modules 는 import 를 hoisting 안 해 이 shadow 자체가 없으므로 `if (module_to_chunk != null)` 로 skip. same-chunk 가드도 `.none` 이면 skip(isCrossChunkConsumer 와 동형).
  - **nested-binding 캐시를 `calculateRenames` 전 + `defer clearNestedBindingCache()`**: 3 소비처(calculateRenames/resolveNestedShadowConflicts/resolveWrapperConsumerShadows) 공용 O(1), 에러 경로 해제.

  ## 범위 / 후속

  **same-chunk splitting** 한정(mermaid khroma 는 same-chunk 인라인이라 커버). 같은 클래스의 잔여 토폴로지 — (A) cross-chunk splitting(싱글톤이 다른 청크), (B) preserve-modules(import 로컬명 shadow), (C) dev-split override revert — 는 근본이 **cross-chunk/파일경계 네이밍이 소비자 nested binding 미회피**로 별개 처방 필요. 셋 다 #4563 이전부터 있던 pre-existing gap(이 PR 이 회귀시키지 않음) → **#4566** 로 추적.

  ## 검증
  - 실제 mermaid `--format=esm`(non-minify): flowchart/sequence/gantt/class/state/pie/er/journey/git **9종 전부 headless 브라우저 렌더 성공**. 산출물 self-referencing const 0. (minify 경로도 여전히 9종 렌더 — #4560/#4564.)
  - 회귀 가드: `split-runtime-smoke.test.ts` `#4563` — reusable 싱글톤 + import alias + 함수-로컬 동명 구조를 splitting 으로 node 실행(`rgba:10`), self-referencing const 부재 확인. 수정 전 self-TDZ `ReferenceError` 재현.
  - zig 전체 test + 통합 스위트(4268) 무회귀 — per-chunk 리네이머는 모든 splitting 빌드가 타는 코어 경로라 전량 검증.

- e2026d6: `--splitting` 에서 `import * as ns` 의 멤버(`ns.max`)가 **재-export 배럴**을 통해 오고 그 멤버가 다른 lib 와 전역 충돌해 `max$1` 로 deconflict 될 때, 소비자 본문이 bare `max` 로 남아 `ReferenceError` 나던 것 수정 (#4564).

  ```js
  // libA.js:  export const max = (arr) => ...;   // 다른 lib 의 max 와 전역 충돌 → max$1
  // barrel.js: export * from "./libA.js";         // 재-export만 (lodash-es 배럴 위상)
  // diagram.js (lazy):
  import * as _ from './barrel.js';
  export const d = () => _.max([3, 1, 4]); // 버그: ReferenceError: max is not defined
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

- 8c5b013: `--splitting` 에서 `import * as ns` 의 멤버(`ns.channel`)가 **다른 청크**에 있고 named-import 소비자가 없을 때 cross-chunk 등록이 누락돼 `ReferenceError` 나던 것 수정 (#4560).

  ```js
  // pkg/channel.js:  export const channel = (c, ch) => ...;   // 공통 청크로 분리
  // diagram1.js (lazy):
  import * as k from './pkg/channel.js';
  function fade(c) {
    return k.channel(c, 'r');
  } // 각 다이어그램이 자체 정의(중복)
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

- eba909b: `zig build test` 가 seed 에 따라 SIGSEGV 로 죽던 flake 수정.

  `TsconfigCache.clear()` 는 arena 를 reset 하는데, 테스트가 그 **뒤에** clear 이전 결과 슬라이스를 그대로 읽고 있었다 (use-after-free). `retain_capacity` 라 대개는 우연히 살아 읽혀 통과했고, 메모리가 재사용/poison 되는 실행에서만 터졌다.

  프로덕션 코드가 아니라 **테스트 자체의 버그**였지만, `pre-push` 훅이 `zig build test` 를 돌리기 때문에 **clean main 에서도 push 가 막히는** 상태였다.

- 2f6adc9: `new URL("x.worker.js", import.meta.url)` 처럼 `./` 가 없는 worker 지정자도 재작성한다 (#4483).

  `new URL(spec, import.meta.url)` 의 `spec` 은 **URL 상대 참조**다. base 가 모듈 자신의 URL 이므로 `"x.worker.js"` 와 `"./x.worker.js"` 는 같은 파일을 가리킨다. 그런데 지금까지 zntc 는 `./` 가 붙은 것만 재작성하고, `./` 없는 bare 형태는 npm 패키지 이름으로 보고 `node_modules` 를 뒤졌다 → resolve 실패 → 경고만 남기고 원문 그대로 방출 → 해시된 산출물 이름과 어긋나 **런타임 404**.

  ```js
  new Worker(new URL('./dbl.worker.js', import.meta.url)); // → new URL("./dbl.worker-1c4d8b20.js", …) ✅
  new Worker(new URL('dbl.worker.js', import.meta.url)); // → new URL("dbl.worker.js", …) ❌ 404
  ```

  `monaco-editor` 의 `cssMode.js` / `tsMode.js` 등이 정확히 이 형태(`new Worker(new URL("css.worker.js", import.meta.url), { type: "module" })`)를 써서, Monaco 기본 워커 해석에 의존하는 앱이 그대로 깨졌다.

  resolve 레이어에서 worker 지정자가 bare 상대 참조면 `./` 를 붙여 해석한다. `--packages=external` 이 bare worker 지정자를 external **패키지**로 오인하던 부수 버그도 함께 해소된다.
  - 스킴이 있는 절대 URL(`https:` / `data:` / `blob:` / `chrome-extension:`), protocol-relative(`//cdn/w.js`), root-absolute(`/abs.js`) 는 그대로 둔다 — origin 기준 참조라 `./` 를 붙이면 의미가 깨진다.
  - 형제 파일이 없으면 원문 그대로 한 번 더 해석한다 — `new Worker(new URL("monaco-editor/esm/vs/editor/editor.worker.js", import.meta.url))` 같은 **패키지 경로 worker** 가 예전처럼 `node_modules` 로 해석된다 (Vite 도 양쪽을 지원).
  - `--external:x.worker.js` 처럼 사용자가 원문 철자로 건 external 패턴도 그대로 존중한다.

  `/code-review max` 가 첫 구현의 회귀 3건을 잡아내 설계를 바로잡았다.
  - **정규화를 먼저 시도한 게 잘못이었다.** `--alias` / tsconfig `paths` 로 매핑되던 worker 지정자가 같은 이름의 형제 파일에 조용히 가려졌다. → **기존 해석을 먼저 시도하고, 못 찾았을 때만 `./` 를 붙인다.** 기존에 resolve 되던 것은 하나도 바뀌지 않는다.
  - `?worker` 등 query 가 붙은 bare 지정자를 정규화하면 worker 본문이 아니라 **WorkerWrapper 팩토리** 청크가 만들어져 워커가 영영 응답하지 않았다. → query/fragment 가 붙은 지정자는 정규화 대상에서 제외.
  - codegen 이 `new URL(spec, base)` 의 **base 인자를 확인하지 않아**, 같은 문자열을 다른 base 로 쓴 무관한 `new URL("x.worker.js", "https://cdn/")` 까지 worker 청크로 재작성됐다 (scan 단계는 base 를 검사한다). → codegen 도 `import.meta.url` 인지 확인.

  함께 고친 것:
  - `--packages=external` 의 "bare = npm 패키지" 자동 규칙을 worker 에는 적용하지 않는다 (사용자가 명시한 `--external:` 패턴은 그대로 존중).
  - external 로 분류된 worker 가 UMD/AMD **의존성 배열**에 딸려 들어가 AMD 로더가 워커 스크립트를 메인 번들의 모듈 의존성으로 실행하려 들던 문제 (`.css_url` 과 같은 carve-out 적용).

- f115678: 주입된 래퍼 참조(`require_x()`)가 **소비자의 스코프 바인딩**에 가려져 무성 TypeError 가 나던 것 수정 (#4533).

  ```js
  function load() {
    function require_legacy() {
      return 'SHADOW';
    } // 소비자의 바인딩
    return require('./legacy.cjs').foo(); // → require_legacy().foo() → 가려짐
  }
  ```

  `require("./legacy.cjs")` 는 emit 시 그 자리에서 `require_legacy()` 로 재작성되는데, 그 지점 스코프 체인에 동명 바인딩이 있으면 그게 래퍼를 가린다 → `require_legacy(...).foo is not a function`. 빌드 exit 0 · 파싱 통과 · **실행만** 실패.

  ## 처방 (esbuild/rolldown 방식)

  **가리는 사용자 바인딩을 리네임**한다 — 래퍼 이름은 절대 안 건드린다. 래퍼 이름은 cross-chunk 전역명·preserve-modules 공개 export·mangler 등 **여러 서브시스템이 공유**하는 값이라 그걸 바꾸면 파급이 크다(래퍼를 리네임하는 접근은 cross-chunk desync / preserve-modules export 불일치 / mangler 무효화를 연쇄로 낳았다). 소비자의 지역 바인딩은 그 모듈 안에서만 참조되므로 리네임이 **로컬**하다.
  - `Linker.resolveWrapperConsumerShadows` — 각 소비자의 `import_records` 로 참조하는 래퍼 이름을 모아, 소비자 스코프(중첩; CJS 소비자는 클로저 안이라 scope 0 포함)에서 동명 바인딩을 찾아 `rename_table` 로 개명(`require_legacy$1`). `findAvailableCandidate` 로 owner/reserved/canonical/기존 중첩바인딩과 안 겹치는 이름 선택.
  - `buildMetadataForAst` 에 nested(scope 1+) rename 반영 추가 — module-scope self-rename 루프는 `scope_maps[0]` 만 봤다. **non-minify 전용**: minify 는 mangler(Phase B)가 nested 를 담당하고 scope-aware 라 shadow 를 자연히 피한다.
  - 단일 번들 / code-splitting(`computeRenamesForModules`) 양 경로에 배선.

  ## 곁다리로 닫히는 것
  - **#4530**(래퍼 vs 사용자 **top-level** 심볼): main 의 `reserved_globals` 예약이 그대로 담당(이 PR 은 안 건드림).
  - **#4536**(asset/disabled 래퍼): 리네임 대상이 래퍼가 아니라 **소비자 바인딩**이라 래퍼에 심볼 테이블이 없어도 커버된다 — `wrapper_name_synthetic` 도 매칭 대상에 포함.

  정본 대조: node / esbuild / rspack / **rolldown** 전부 이 방식(소비자 바인딩 리네임). effect/zod/three `--minify` byte-identical(size 0).

  ## code-review 반영 (2차)
  - 개명 후보가 CJS 소비자의 **scope-0(클로저 지역) 바인딩**과도 안 겹치게 `pickConsumerShadowName` 추가(`findAvailableCandidate` 는 scope 1+ 만 봄 → `require_legacy$1` 이 이미 있으면 거기 개명하던 재선언 결함).
  - 주입 이름 집합에 런타임 헬퍼 `__toCommonJS`/`__toESM` 포함(ESM-wrap interop `(init_x(), __toCommonJS(exports_x))`).
  - **minify 는 pass 전체 skip** — mangler 가 모든 바인딩을 유일명으로 개명해 섀도가 원천 불가(검증됨). non-minify 만 metadata nested 스캔.
  - `captureRenamesToPending` 에 nested(scope 1+) rename 의 `declaration_span` 재매칭 추가 — AST 변형(const-materialize) 후에도 소비자 shadow-rename 이 살아남게(방어적: module-scope rename 도 있는 소비자가 변형될 때만 발동).

  ## code-review 반영 (3차) + 범위
  - **[3] splitting**: per-chunk 경로(`computeRenamesForModules`)의 `reserved_globals` 가 wrapper 이름·global_identifiers 를 안 예약해 형제 래퍼(`require_x$1`)와 겹치는 후보를 고르던 것 수정 — collectReservedGlobals 와 동일 예약.
  - **[2] incremental carryover**: `captureRenamesToPending` 이 scope 0/nested 동명 시 nested rename 을 scope-0 심볼에 오귀속하던 것 수정(old 심볼이 실제 module-scope 일 때만 그 경로).

  ⚠️ **범위(#4538 epic 로 분리)**: 아래 **드문 edge** 는 이 PR 범위 밖 — cold 공통 케이스는 유지되고 main 대비 regression 아님.
  - 런타임 헬퍼(`__toESM`/`__toCommonJS`, `--minify-whitespace` 의 `$tE`/`$tC`)를 지역 변수로 shadow (사용자가 그렇게 이름 짓는 건 사실상 없음).
  - `require.context` 로 도달하는 래퍼.
  - HMR/incremental warm 재빌드에서 CJS scope-0 shadow 를 **나중에** 추가할 때 stale reuse (dev-only).

  ## code-review 반영 (4차, 수렴)
  - **[0] eval/`with` 가드**: 소비자 스코프에 direct `eval`/`with` 가 있으면(=`blocksMangling()`) 개명하지 않는다 — 그 안의 동적 조회가 바인딩을 **이름 문자열**로 참조할 수 있어 리네임이 그걸 깬다. zntc mangler 도 같은 이유로 그런 모듈을 skip(#1258), esbuild 도 direct-eval 스코프를 deopt. (⚠️ eval+shadow 동시 케이스의 잔여 shadow 는 근본적으로 해결 불가한 엣지 — esbuild 도 동일하게 둔다.)
  - **[1] per-chunk 예약 축소**: 전 모듈 래퍼를 예약하던 것을 **이 청크가 실제 import 하는 래퍼**만으로 좁힘 — 무관한 다른 청크의 동명 사용자 심볼이 불필요하게 리네임돼 content-hash 파일명이 흔들리던 것 방지.
  - **[perf]** metadata nested 스캔을 `has_nonminify_nested_shadow`(scope 1+ 개명이 실제로 있을 때만 true)로 게이트 — 섀도 없는 절대다수 빌드에서 O(전 모듈 nested 바인딩) 스캔 제거.

  ## code-review 반영 (5차, 수렴)
  - **[2] splitting 선언측 #4530**: per-chunk reserved 를 참조측(import 하는 래퍼)뿐 아니라 **선언측**(이 청크에 놓이는 wrapped 모듈 자신의 래퍼)까지 예약 — 래퍼 선언(`var require_X=__commonJS`)과 동명인 co-chunk 사용자 top-level 이 중복 선언되던 것(main 의 splitting #4530 갭) 수정.
  - **[perf]** metadata nested 스캔 게이트를 전역 bool → **개명된 모듈 index 집합**으로 — 스캔이 영향 모듈에만 비례.
  - **[cleanup]** 래퍼 예약을 `reserveWrapperNames(module)` 단일 헬퍼로(collectReservedGlobals + per-chunk 공유). 코드 주석의 외부 출처 표기 제거(컨벤션).

  ⚠️ **알려진 HMR perf**(#4538): nested shadow-rename 이 있으면 HMR rename-reuse 스냅샷이 폐기돼 warm 재빌드가 full 재계산으로 떨어진다(정확성 유지, shadow 있는 프로젝트만). symbolLocalName 이 nested SymbolID 를 못 역매핑하기 때문 — reuse 를 nested rename 까지 확장하는 건 #4538.

  ## code-review 반영 (6차, 수렴 — correctness 잔여 0)
  - **[0] --minify-whitespace 헬퍼명**: interop 헬퍼 shadow 매칭에 축약명(`$tE`/`$tC`, NAMES.TOESM_MIN/TOCOMMONJS_MIN)도 추가 — emit 은 `--minify-whitespace` 에서 축약명을 쓰는데 full 이름만 매칭해 그 조합에서만 nested 헬퍼 shadow 를 놓치던 것 수정. names 배열↔reserveWrapperNames 동기화 주석 추가.

- 07dd074: 생성된 **래퍼 심볼**이 사용자 top-level 심볼과 deconflict 되지 않아 **파싱 불가** 산출물이 나오던 것 수정 (#4530).

  ```js
  // entry.js
  function require_legacy() {
    return 'USER';
  } // ← 사용자 심볼
  import d from './legacy.cjs';
  ```

  방출:

  ```js
  var require_legacy = __commonJS({ ... });     // ← emitter 가 찍은 래퍼
  function require_legacy(){ return "USER"; }   // ← 사용자 코드
  // → SyntaxError: Identifier 'require_legacy' has already been declared
  ```

  **단일 번들에서도** 재현된다 — 번들 스코프에 모든 모듈의 top-level 이 호이스팅되기 때문이다.

  근본 원인: 래퍼 심볼(`extendSymbol`)은 `scope_id = .none` 으로 만들어져 **`scope_maps` 에 들어가지 않는다** → linker 의 rename 풀(`name_to_owners`)이 **못 본다**. 그래서 사용자 심볼과 이름이 겹쳐도 아무도 못 막았다. CJS 의 `require_X` 뿐 아니라 ESM-wrap 의 `init_X` / `exports_X` 도 같았다.

  처방: 래퍼 이름을 linker 의 **`reserved_globals` 에 예약**한다 → 충돌하는 **사용자 심볼**이 리네임된다.

  ⚠️ **래퍼 쪽 이름을 바꾸는 방식으로 풀면 안 된다.** graph finalize 의 `used_names` 와 linker 의 `$N` 할당기는 **서로를 못 보는 두 개의 독립 풀**이라, 한 단계 위에서 다시 충돌한다(양쪽이 각각 `require_legacy$2` 를 발급). 예약해서 사용자 심볼을 리네임시키면 할당기가 **하나로 모인다**. 부수 효과로:
  - 래퍼가 자연스러운 이름을 유지 → size 회귀 0 (effect/zod/three `--minify` byte-identical).
  - `computeRenames` 는 **매 빌드 실행**되므로 **watch/incremental 재빌드**도 커버된다 (래퍼 이름은 한 번 정해지면 캐시되므로, finalize 쪽 seed 는 warm 에서 아예 발동하지 않았다).

## 0.1.3

### Patch Changes

- c608d1b: 동명 basename 자산의 `require_X` 래퍼 이름이 충돌해 **다른 자산의 URL 을 돌려주던** 버그 수정 (#4475).

  ```js
  import x from './a/logo.png'; // 내용이 서로 다른 파일
  import y from './b/logo.png';
  console.log(x, y);
  // 전: ./logo-efdc71e4.png ./logo-efdc71e4.png   ← 둘 다 같은 URL
  // 후: ./logo-22fcfd0d.png ./logo-efdc71e4.png
  ```

  자산 파일은 둘 다 올바른 해시로 방출되는데, 번들 JS 가 `var require_logo` 를 **두 번 선언**해서 두 번째가 첫 번째를 가렸다. 결과적으로 `a/logo.png` 는 번들에서 도달 불가능해지고 `x` 가 `b/logo.png` 의 URL 을 받았다 — 빌드는 성공하는 조용한 오컴파일.

  근본 원인: `registerWrapperSymbols` 가 래퍼 이름을 `uniqueName()` 으로 deconflict 하는데, 그 앞에 `if (m.semantic) |*s| s else continue` 가드가 있다. asset 모듈은 JS 파싱을 거치지 않아 `semantic` 이 null 이라 **등록을 통째로 건너뛰었고**, emit 은 basename 기반 fallback(`makeRequireVarName`)으로 떨어졌다. 그 fallback 은 충돌을 모른다.

  semantic 이 없어도 이름 deconflict 는 할 수 있으므로 전용 슬롯(`Module.wrapper_name_synthetic`)에 담는다. `disabled` / `optional-missing` 모듈도 같은 fallback 을 타고 있었으므로 함께 보호된다.

- b0d6898: class static block 을 소스 원문 복사가 아니라 AST 로 출력한다 (#4468).

  `emitStaticBlock` 이 non-minify 경로에서 `writeNodeSpan` 으로 **소스 바이트를 그대로 복사**하고 있었다. 그래서 static block 안에서만 AST 에 가해진 변형이 통째로 유실됐다 — 조용한 오컴파일.

  ### 유실되던 것들
  - **deconflict rename**: `class Node` 가 `Node$1` 로 rename 돼도 블록 안의 자기참조 `new Node(...)` 는 옛 이름으로 남았다. 번들에 `Node` 선언이 없으니 그 참조는 **전역 바인딩을 탈취**한다 — 브라우저에서 `new Node()` 는 DOM `Node` 를 잡아 `TypeError: Illegal constructor` 로 죽는다. `monaco-editor` 의 `vs/base/common/linkedList.js` 가 정확히 이 패턴이라, `zntc build` 로 번들한 monaco 는 **에디터가 아예 뜨지 않았다**.
  - **TypeScript strip**: `static { getX = (obj: C) => obj.#x; }` 의 타입 주석 `: C` 가 그대로 남아 **문법적으로 깨진 JS** 가 나왔다.
  - **`--define` 치환**: `static { this.mode = __MODE__; }` 의 `__MODE__` 가 그대로 남아 런타임 `ReferenceError`.
  - 주석이 클래스 밖으로 중복 출력되고, 들여쓰기가 원본 소스 것과 codegen 것으로 뒤섞였다.

  minify 경로는 이미 AST 로 출력하고 있었고 그쪽은 정상이었다 — 즉 AST 출력은 이미 검증된 경로였고, 원문 복사 지름길만 그걸 건너뛰고 있었다. 그 지름길을 제거했다.

  ### 출력 변화

  static block 이 다른 블록과 동일하게 포맷된다. `minify_syntax` 가 꺼진 상태에서는 statement 종결 `;` 가 붙는다 (다른 모든 블록과 같은 규칙).

  ```js
  // 이전 (소스 원문 복사 — 들여쓰기가 뒤섞임)
  class C {
    static {
      const a = 1;
    }
  }

  // 이후 (AST 출력)
  class C {
    static {
      const a = 1;
    }
  }
  ```

- b91fc85: CSS `url()` 로 참조된 자산을 방출하고 url 을 재작성한다 (#4466).

  지금까지 CSS 본문의 `url(./font.ttf)` 는 완전히 무시됐다 — 자산이 `dist` 에 나오지 않고 CSS 는 원문 경로를 그대로 들고 있어 런타임 404 였다 (dangling 참조). `monaco-editor` 를 번들하면 `codicon.ttf` 가 빠져 에디터 아이콘이 전부 깨지는 식이다.

  이제 `url()` / `image-set()` 참조를 JS `import` 자산과 동일하게 해시 방출 + url 재작성한다.
  - **적용 대상**: `@font-face { src: url(...) }`, `background`/`background-image`, `border-image`, `cursor`, `mask-image`, `list-style-image`, CSS 커스텀 속성, `image-set()` / `-webkit-image-set()`.
  - **suffix 보존**: `url(./f.eot?#iefix)` → `url("./f-a1b2c3d4.eot?#iefix")` (IE9 훅), `url(./i.svg#icon)` 의 fragment 유지.
  - **손대지 않는 것**: `url(#gradient)` (SVG filter/gradient 참조 — 파일이 아니다), `url(/abs.png)` (public 디렉토리 규약), `url(https://…)` / `url(//cdn…)` / `url(data:…)` / `url(blob:…)`.
  - **확장자 무관**: `url()` 대상은 기본 확장자 테이블에 없어도(`.cur` 등) 파일 자산으로 처리한다 — 하드 에러로 빌드를 세우지 않는다.
  - **해석 실패 시 경고 후 원문 유지** — 빌드를 세우지 않는다. 배포 스크립트가 나중에 채워 넣는 자산이 흔하기 때문.
  - suffix 가 붙은 참조(`#icon` / `?#iefix`)의 대상은 인라인하지 않는다 — data URL 뒤엔 suffix 를 붙일 자리가 없다. 작은 SVG 스프라이트도 파일로 방출된다.
  - JS 와 CSS 가 같은 자산을 참조하면 파일 하나로 dedup 되고, CSS 에서만 참조된 자산은 JS 번들에 죽은 `__commonJS` 래퍼로 실리지 않는다.
  - `zntc dev` 도 방출 자산을 서빙한다 (예전엔 dev 에서만 404). 자산은 **메모리에서** 서빙 — 번들 산출물을 소스 디렉토리에 쓰지 않는다.

  ### 기본 asset 로더

  폰트/이미지/미디어 확장자에 기본 `.file` 로더가 붙는다 — 예전엔 전부 `No loader is configured` 에러였다 (Vite/rspack parity).
  - 이미지 `.png .jpg .jpeg .jfif .pjpeg .pjp .gif .svg .ico .webp .avif .bmp`
  - 폰트 `.woff .woff2 .eot .ttf .otf`
  - 미디어 `.mp4 .webm .ogg .mp3 .wav .flac .aac .opus .mov .m4a .vtt`
  - 기타 `.webmanifest .pdf`

  목록 밖의 확장자는 여전히 `--loader` 명시가 필요하다. `zntc build` / `zntc dev` 도 이제 `--loader:.ext=type` / `--asset-names` / `--asset-inline-limit` 을 받는다 (예전엔 `unknown option` 으로 거부).

  ### `--asset-inline-limit` (신규, 기본 4096)

  이 크기 이하의 자산은 별도 파일 대신 data URL 로 인라인한다 (Vite `assetsInlineLimit` 상당). `0` 이면 항상 파일로 방출. JS API / config 키는 `assetInlineLimit`.

  확장자 기본 테이블로 `.file` 이 된 자산에만 적용된다 — `--loader:.png=file` 처럼 **명시** 지정한 로더, `copy` 로더, RN asset-registry 모드는 인라인하지 않는다.

  ### 동작 변화 (기존 사용자와 호환)
  - 알려진 이미지/폰트/미디어 확장자를 `--loader` 없이 import 하면, 예전엔 **빌드 에러**였지만 이제 성공한다 (4KB 이하는 data URL, 초과는 해시 파일). 에러가 성공으로 바뀌는 것이라 깨질 코드가 없다.
  - `--loader:.png=file` 처럼 로더를 **명시**한 설정은 인라인 대상에서 제외돼 기존 출력이 그대로 유지된다.
  - CSS `url()` 의 상대 경로가 재작성된다. 이전엔 자산이 방출되지 않아 런타임 404 였으므로 그 출력에 의존하던 동작은 존재할 수 없었다. 다만 출력 CSS 의 `url()` 을 문자열로 비교하는 스냅샷 테스트가 있다면 갱신이 필요하다.

- 872bf64: `--jsx=preserve` 가 JSX 를 소스 원문 복사가 아니라 AST 로 출력한다 (#4470).

  preserve 모드는 JSX 를 변환하지 않고 downstream tool 에 위임한다. 그런데 그 "그대로" 를 **소스 span 통째 복사**로 구현하고 있어서, JSX 안에서만 AST 변형이 전부 무시됐다.

  ### 고쳐진 것

  **1. 번들 deconflict rename 누수 → `ReferenceError`**

  ```jsx
  import { Widget as A } from './a.jsx';
  export const q = <A.Panel />;
  ```

  scope hoisting 후 실제 심볼은 `Widget` 인데 태그는 `A` 를 그대로 들고 있었다. 번들에 `A` 선언이 없으므로 downstream 변환 결과는 `ReferenceError: A is not defined`. 이제 `<Widget.Panel />` 로 나간다.

  **2. JSX 안의 TypeScript 어노테이션 미strip**

  `<Foo prop={value as Type} />` 의 `as Type` 이 남아 JS 로 파싱 불가였다. (기존 코드가 "알려진 제약" 으로 주석에 명시해 두던 항목.)

  **3. `--define` 치환 미적용**

  `<Foo x={__MODE__} />` 의 `__MODE__` 가 그대로 남았다.

  **4. 깨진 JSX 출력**

  transformer 가 element/fragment 는 `shouldLowerJsx()`(preserve 존중)로, 자식(expression container / text / spread)은 `jsx_transform` 으로 게이트해서 **preserve 모드인데 자식만 lowering** 됐다. 그 결과 `<div>{x}</div>` 가 `<div>"..."x</div>` 처럼 텍스트에 따옴표가 붙고 중괄호가 사라진 채로 나갔다. 두 게이트를 통일했다.

  ### 안전 장치
  - **속성 이름은 절대 rename 되지 않는다.** semantic analyzer 가 `jsx_attribute` 의 value 만 방문하고 name 은 방문하지 않으므로 심볼이 붙을 수 없고, codegen 도 name 을 원문 경로로 낸다.
  - **원본 소스의 attribute string 은 원문 보존.** JSX attribute string 은 JS string 과 escaping 규칙이 다르다(backslash escape 없음, HTML entity 사용) — `c="a&amp;b"` 가 그대로 나간다.
  - **합성된 string 은 `{}` 로 감싼다.** `--define` 치환 결과처럼 따옴표가 든 값을 attribute string 자리에 그대로 내면 `d="a\"b"` 가 되는데 JSX 는 그 백슬래시를 escape 로 읽지 않는다. `d={"a\"b"}` 로 낸다.

- f91a98b: minify 시 `if (c) { ({a} = o); g(); }` 를 콤마 시퀀스로 접을 때 **필수 괄호가 사라지던** 버그 수정 (#4472).

  `--minify`(= `minify_whitespace` + `minify_syntax`)는 블록 안의 expression statement 들을 `if(c) a,b;` 처럼 콤마 시퀀스로 접는다. 이 경로가 statement-start 를 표시하지 않아, 시퀀스 **첫 원소**가 object destructuring 할당이면 괄호가 빠졌다:

  ```js
  // 입력
  if (href) { ({ href, dimensions } = cleanUrl(href)); out.push(href); }

  // 잘못된 출력
  if(n){href:n,dimensions:r}=t(n),i.push(n);
  //    ^ 브라우저는 `{` 를 블록으로, `href:` 를 라벨로 읽는다 → SyntaxError

  // 고쳐진 출력
  if(n)({href:n,dimensions:r}=t(n)),i.push(n);
  ```

  **빌드는 exit 0 으로 성공하는데 산출물이 런타임에 죽는** silent miscompile 이었다 — `monaco-editor`(marked 의 image 렌더러)를 번들하면 `SyntaxError: Unexpected token ':'` 로 페이지 전체가 실행되지 않았다.

  단일 문장 본문(`if (c) ({a} = o);`)은 `emitExpressionStatement` 를 타서 정상이었고, 여러 문장을 접는 경로만 그 마킹을 건너뛰고 있었다. object literal 선두(`({}).toString()`)도 같은 원인으로 깨졌고 함께 고쳐진다. 배열 구조분해(`[a,b] = arr`)는 `[` 가 블록으로 오파싱되지 않으므로 괄호가 붙지 않는다.

- 1f92385: Vite 식 query-suffix import 지원 — `?raw` / `?url` / `?inline` / `?worker` (#4467).

  Vite 생태계 문서·레시피가 널리 쓰는 관용구인데 zntc 가 resolve 하지 못해 `ZNTC0100 Cannot resolve module` 이 났다. 라이브러리 문서 다수가 이 형태를 전제해서 마이그레이션 마찰이 됐다.

  | suffix          | 동작                                                                                                                                                       |
  | --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | `?raw`          | 파일 내용을 문자열로 인라인 (`text` 로더)                                                                                                                  |
  | `?url`          | 자산으로 방출하고 URL 문자열을 export. **`--asset-inline-limit` 을 무시**한다 — 사용자가 URL 을 명시 요청한 것이므로 작은 파일도 data URL 로 바뀌지 않는다 |
  | `?inline`       | data URL 로 인라인 (`dataurl` 로더). 크기와 무관하게 항상 인라인                                                                                           |
  | `?worker`       | Worker 생성 함수를 default export — `new W()` 로 Worker 를 만든다                                                                                          |
  | `?sharedworker` | SharedWorker 생성 함수를 default export                                                                                                                    |

  ```js
  import txt from './data.txt?raw'; // "hello raw content"
  import u from './icon.png?url'; // "./icon-a1b2c3d4.png"
  import i from './icon.png?inline'; // "data:image/png;base64,..."
  import W from './x.worker.js?worker';
  const w = new W();
  ```

  같은 파일도 query 마다 다른 모듈이다 (`x.png` 는 자산, `x.png?raw` 는 문자열).

  `?worker` 는 새 인프라를 만들지 않고 **표준 worker 패턴을 합성**해 기존 기계를 재사용한다:

  ```js
  export default function WorkerWrapper(options) {
    return new Worker(new URL('./x.worker.js', import.meta.url), options);
  }
  ```

  `{ type: "module" }` 을 붙이지 **않는다.** zntc 는 worker entry 를 항상 classic script(IIFE)로 방출하므로, module worker 로 로드하면 strict mode / `importScripts` 부재 같은 다른 semantics 가 걸려 classic 번들이 터질 수 있다. Vite 도 worker 출력이 `es` 일 때만 붙인다.

  `?vue&type=style&lang.css` 같은 **알려지지 않은 query 는 건드리지 않는다** — 그쪽은 플러그인이 가상 경로로 처리하는 기존 관용구다.

## 0.1.2

### Patch Changes

- ab2c450: 내부 실험 기능(MCP) 정리 — 0.1.1 이후 개발 중 추가됐던 미동작 MCP epic(`zntc mcp` / `/mcp` endpoint / `mcpStdioServe` 등) 제거. 게시본(0.1.0/0.1.1)에 포함된 적 없어 사용자 영향 없음.
