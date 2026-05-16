# RFC: CJS/IIFE Code Splitting (P3)

> 상태: **Draft (설계 고정 — 구현은 후속 다회 PR)**
> 범위: 비-ESM(`format=cjs`/`iife`) 출력에서의 code splitting / preserve-modules
> 백로그: 일반 청크 #3321 의 P3. **MF RFC `docs/RFC_MODULE_FEDERATION.md` 와 런타임 레지스트리를 공유** — 본 문서는 그 통합 지점을 명시한다.
> 결정 모드: P0-3(C/JSI 로더) RFC 와 동일하게 *설계를 먼저 고정*. XL 이라 단일 PR 로 구현하지 않는다.

---

## 1. 배경 & 현재 제약

`src/bundler/emitter/chunks.zig:65-73`:

```zig
if (options.format != .esm) {
    return if (options.preserve_modules)
        error.PreserveModulesRequiresESM
    else
        error.CodeSplittingRequiresESM;
}
```

→ **code splitting / preserve-modules 는 ESM 출력에서만 동작**. 이유: 청크 간 동적 로딩을 현재 **네이티브 `import()` 재작성**(`rewriteDynamicImports`, `chunks.zig:961-1071`)으로만 구현하기 때문. CJS/IIFE 에는 네이티브 `import()` 가 없고 `Promise.resolve().then(()=>require(x))` 는 specifier 가 정적 string 이어야 해 동적 청크 로딩이 불가.

비-ESM **단일 번들**은 정상(스코프 호이스팅 + `__commonJS`/IIFE wrapper, `runtime_helpers.zig`). 없는 것은 **청크 경계를 넘는 런타임 모듈 해석**이다.

참고: esbuild 도 **IIFE code splitting 미지원**(의도적, `docs/design/CODE_SPLITTING.md:46,227`). webpack 은 `__webpack_require__` 런타임 로더로 지원. Rollup 은 사실상 ESM 권장.

---

## 2. 기술 격차 (P3 가 신설해야 하는 것)

| # | 격차 | 현황 |
|---|---|---|
| G1 | **런타임 require 레지스트리** (모듈 id → factory, 캐시) | 없음 (`runtime_helpers.zig` 에 `__commonJS/__toESM/__esm` 만, registry 없음) |
| G2 | **청크 동적 로더** (청크 fetch/주입 → 레지스트리 등록 → require) | 없음 (ESM 은 native import() 재작성으로 회피) |
| G3 | **안정 모듈 ID** | ESM 청크 내부는 스코프 호이스팅으로 ID 소거. preserve-modules(1:1 파일) 또는 cross-chunk require 에는 결정적 ID 필요 |
| G4 | **청크 출력 포맷 표준화** | ESM 청크는 `export`/`import`. CJS/IIFE 청크는 레지스트리에 자기 모듈을 등록하는 wrapper 필요 |

핵심: **G1(런타임 레지스트리)** 이 본질. ESM 은 런타임이 브라우저(native import())라 레지스트리가 불필요했고, 비-ESM 은 그 런타임을 우리가 생성해야 한다.

---

## 3. MF RFC 와의 겹침 (중복 구현 방지 — 본 RFC 의 핵심)

`docs/RFC_MODULE_FEDERATION.md` §6.1:

> `module registry / container 런타임`: ❌ `runtime_helpers.zig` 에 `__commonJS/__toESM/__esm` 만, 청크 로더/registry 없음 → **신규**: MF2 호환 container/registry 헬퍼

**P3 의 G1(런타임 require 레지스트리)·G2(청크 로더)·G3(안정 모듈 ID)는 MF RFC 가 "신규 필요"로 식별한 바로 그 인프라와 동일하다.** 따로 만들면 한쪽이 버려진다.

| 인프라 | P3 요구 | MF 요구 | 통합 방침 |
|---|---|---|---|
| 안정 모듈 ID | cross-chunk require / preserve-modules 경계 | 연합 경계 모듈 ID (MF P1, RFC §4.1) | **공유** — 동일한 "경계 안정 ID" 메커니즘. 내부 청크는 양쪽 다 호이스팅 유지 |
| 런타임 모듈 레지스트리 | CJS/IIFE require 캐시 | MF2 container/shared scope (RFC §4.1) | **계층 분리·공유**: 하위 = 최소 require 레지스트리(P3), 상위 = MF container 가 그 레지스트리 위에 shared scope 얹음 |
| 청크 로더 | 비-ESM 청크 fetch/주입 | RN: ScriptManager(별도) / 웹: ESM or script | **인터페이스 공유**: `__zntc_load_chunk(id)` 추상화. P3 는 CJS/IIFE 구현, MF/RN 은 다른 구현 주입 |

**P3 고유(MF 무관)**: CJS/IIFE wrapper 포맷, preserve-modules 의 파일별 모듈 ID, Node `module.exports` 상호운용.

**결론**: P3 의 레지스트리/모듈ID 는 **MF RFC §4.1 의 "연합 경계 안정 모듈 ID + 레지스트리"와 같은 하위 인프라로 설계**한다. P3-Alpha 가 그 하위 인프라(최소 require 레지스트리)를 먼저 만들고, MF P1 의 container 가 그 위에 얹히도록 인터페이스를 맞춘다.

---

## 4. 설계

### 4.1 런타임 require 레지스트리 (G1, MF 와 공유 하위 계층)

번들/엔트리 청크에 1회 주입되는 최소 런타임:

```js
var __zntc_mods = {};                 // id -> factory(exports, module, require)
var __zntc_cache = {};                // id -> { exports }
function __zntc_require(id) {
  var c = __zntc_cache[id]; if (c) return c.exports;
  var m = { exports: {} }; __zntc_cache[id] = m;
  (0, __zntc_mods[id])(m.exports, m, __zntc_require);
  return m.exports;
}
function __zntc_register(map) { for (var k in map) __zntc_mods[k] = map[k]; }
```

- 내부 청크 모듈은 **여전히 스코프 호이스팅** — 레지스트리는 *청크 경계*에서만 사용(over-bundling/크기 회귀 방지, MF RFC 의 "내부 호이스팅 유지, 경계만 레지스트리" 원칙과 동일).
- MF container 는 이 레지스트리 위에 shared scope/버전 협상을 얹는 상위 계층(별도 RFC §4.1).

### 4.2 청크 출력 포맷 (G4)

각 비-ESM 청크는 자기 모듈을 레지스트리에 등록하는 self-registering wrapper:

```js
// chunk-<hash>.js  (cjs/iife 공통, 환경 가드)
(function(g){ g.__zntc_register({ "<id>": function(exports, module, require){ /* hoisted */ } }); })(
  typeof globalThis!=="undefined"?globalThis:this
);
// cjs 환경에선 module.exports 로도 노출(상호운용)
```

cross-chunk static import → `__zntc_require("<id>")` 호출로 재작성(현재 ESM `import {x} from "./c.js"` 재작성 자리, `chunks.zig:222-321` 대응).

### 4.3 청크 동적 로더 (G2)

`import("./page")` (CJS/IIFE 출력) 재작성 →
```js
__zntc_load_chunk("chunk-<hash>.js").then(function(){ return __zntc_require("<entry-id-of-chunk>"); })
```
`__zntc_load_chunk` 는 추상 — 환경별 구현 주입:
- **CJS/Node**: `Promise.resolve().then(()=>require("./chunk-<hash>.js"))` (정적 string OK)
- **IIFE/브라우저**: `<script>` 주입 또는 `import()`(가능 시) — 페이로드는 self-register 라 평가만 하면 등록됨
- **MF/RN**: ScriptManager 등 별도 구현이 같은 인터페이스로 주입(§3 표)

### 4.4 안정 모듈 ID (G3) — **확정: relative-path 기반**

- 청크 경계/preserve-modules 모듈에만 결정적 ID 부여. 내부 호이스팅 모듈은 ID 없음.
- **스킴 확정(§7): relative-path 기반** — root(공통 조상 또는 preserve-modules-root) 상대경로, posix 정규화, 소스 확장자→논리 `.js` 치환(출력 포맷/확장자 무관 안정 → MF 계약 핀 안정). content-hash 대비 디버깅·스택트레이스 가독성·MF expose 키 자연 호환 우위.
- **MF RFC §4.1 "연합 경계 안정 모듈 ID"와 동일 메커니즘** — 한 번 구현해 양쪽이 사용.
- **구현: `src/bundler/module_id.zig`** (P3-B PR1, emit 비의존 하위 인프라). `moduleId(abs_path, root)` + `commonAncestorDir(paths)`. MF P1 container 가 이 위에 얹힌다(중복 구현 금지).

---

## 5. 단계 분해

| Phase | 내용 | MF 관계 |
|---|---|---|
| **P3-A** | preserve-modules + CJS 만: 파일=모듈ID(결정적), self-register wrapper, `__zntc_require`. 동적 로더 불필요(전부 빌드타임 known). 최소·저위험 진입 | 레지스트리 하위 계층 = MF P1 의 토대 |
| **P3-B** | CJS/IIFE + code splitting: 동적 청크 + `__zntc_load_chunk` 추상 로더, cross-chunk require 재작성 | 로더 인터페이스 = MF/RN 과 공유 |
| **P3-C** | MF P1 과 레지스트리 통합 — container/shared scope 가 P3 레지스트리 위에 얹히도록 인터페이스 수렴 | **MF RFC §7 P1 과 합류** |

P3-A 를 먼저(작고 안전, esbuild 도 안 하는 영역의 최소 가치), P3-B/C 는 MF P1 과 보조 맞춰 진행.

**P3-B PR 분해(워크플로 "1 PR=1 기능"):**

| PR | 내용 | 상태 |
|---|---|---|
| **P3-B PR1** | 하위 인프라만 — `module_id.zig`(relative-path 안정 ID) + `runtime_helpers.zig` 레지스트리 상수(`__zntc_mods`/`__zntc_require`/`__zntc_register`/`__zntc_load_chunk`, normal+min). 유닛테스트. emit 미연결·가드 불변(무동작 회귀 0). **MF §4.1 공유 계층** | 본 PR |
| **P3-B PR2** | emit 연결(CJS) — 가드 완화(`format==.cjs`+splitting), cross-chunk static→`const{x}=require("./chunk.js")`, common 청크 CJS `exports.x`(emitCjsEntryExports 미도달 보완), `import()`→`Promise.resolve().then(()=>require("./chunk.js"))`. **CJS/Node 는 네이티브 require 가 곧 레지스트리**(RFC §4.3) — PR1 의 `__zntc_*` 레지스트리는 IIFE/MF 추상 로더 계층(PR3)으로 미사용 대기. Node 실행 검증(통합 테스트), pm_cjs/ESM/smoke 무회귀 | **완료** |
| **P3-B PR3** | **IIFE** splitting: PR1 `__zntc_*` 레지스트리 활성화 — 자기설치형 `__zntc_register`(모든 청크 멱등 prelude) + entry 전용 해석 계층(`__zntc_require`+브라우저 `<script>` 로더+`__zntc_public_path`) + 청크별 self-register factory(안정 모듈 ID 키, common 은 청크 stem) + cross-chunk static→`const{x}=__zntc_require("<id>")` + `import()`→`__zntc_load_chunk("<f>").then(()=>__zntc_require("<id>"))`. entry/dynamic 청크는 emitCjsEntryExports(factory-bound, default/__esModule). 브라우저 시뮬 Node 실행 검증. esm/cjs/pm/smoke 무회귀 | **완료** |
| **P3-B PR4** | UMD/AMD splitting + 비-DOM(worker/Deno) 로더 폴백 + RSC 디렉티브×IIFE-factory + CSP nonce/public-path 옵션. (PR3 한계 §7) | 후속 |

---

## 6. 디리스크 스파이크

> 스파이크: 손수 작성한 self-register 청크 2개 + 최소 `__zntc_require`/`__zntc_load_chunk`(CJS) 로, cross-chunk require + 동적 청크 로드가 Node(cjs)에서 동작함을 증명. 통과 시 P3-B 진행, 실패 시 설계 재검토.

(P0-3 스파이크 0 패턴과 동일 — 위험한 5% 먼저 증명.)

**결과: PASS (2026-05-16).** Node 24 CJS 에서 (1) 런타임 레지스트리·캐시, (2) 정적 cross-chunk require, (3) 동적 청크 로드(`__zntc_load_chunk`→`Promise.resolve().then(()=>require(static))`), (4) 동적 로드 청크의 shared 모듈 캐시 재사용(상태 보존 count 1→2→3) 모두 동작 확인.
**스파이크가 잡은 설계 제약**: 모듈 factory 의 `require` 인자는 `__zntc_require`(모듈ID 레지스트리)다. sibling 청크 *파일* eager 로드는 청크 **최상위**에서 Node `require("./chunk.js")`(정적 string)로 해야 한다 — 청크파일 로드 ≠ 모듈ID require. PR2 의 정적 cross-chunk 재작성은 이 분리를 따른다(§4.2 의도와 일치).

**IIFE 브라우저 스파이크: PASS (2026-05-16).** `<script>` 주입 로더 + self-register factory 청크 2개를 동기 `document` 스텁으로 시뮬레이션 → (1) 레지스트리/캐시 (2) 정적 cross-chunk `__zntc_require` (3) `<script>` 주입 동적 로드 (4) 동적 청크가 common 캐시 재사용(상태 보존 count 1→2→3) 모두 동작.
**IIFE 스파이크가 잡은 설계 제약**: 정적 dep 청크가 entry(레지스트리 코어)보다 먼저 평가되면 `__zntc_register` 미존재로 실패. → **등록/해석 계층 분리**: `__zntc_register` 는 **자기설치형**(`g.__zntc_register||(g.__zntc_register=function(map){...g.__zntc_mods...})`, mods 맵만 필요, 모든 청크가 멱등 prelude 로 보유), `__zntc_require`+로더는 entry 전용(멱등). 그러면 load-order 요구가 "entry 가 정적 dep 들 뒤(마지막) 평가" 하나로 축소된다(호스트 책임 — RFC §5/§7 한계 기록). PR3 의 self-register wrapper·레지스트리 코어는 이 분리를 따른다.

**UMD/AMD splitting 스파이크: PASS (2026-05-16).** UMD 보편 wrapper(`(function(root,factory){define.amd?define([],factory):module.exports?module.exports=factory():root.X=factory()})(self||this,function(){...})`)로 entry 청크를 감싸고 factory 안에 PR3 iife_split 그대로(env-detect 해석 계층+self-register+`return __zntc_require(entryId)`) 배치, dynamic 청크는 IIFE-split 과 동일 self-register. 손수 작성본을 (a) CJS `require()` (b) global script (c) AMD `define` 로 소비 → 3모드 모두 entry exports 반환 + 동적 청크 로드(env-loader Node `import()` 경로) 동작. → **UMD/AMD splitting = PR3 iife_split 기계 불변 + entry 청크만 format_wrapper 보편 패턴으로 감싸고 bootstrap 을 `return __zntc_require(entryId)` 로**. 비-entry 청크는 IIFE-split 과 동일. 저위험.

---

## 7. 미해결 / 결정 필요

- **[결정됨 2026-05-16] 모듈 ID 스킴 = relative-path 기반.** content-hash·숫자 인덱스 대비: 디버깅/스택트레이스 가독성, MF expose 키 자연 호환, 빌드 결정성, 내용 변경에도 ID 불변(MF 계약 핀 안정). MF RFC §4.1/§6.1(모듈 안정 런타임 ID) 과 **공동 결정** — 동일 `module_id.zig` 공유. (트레이드오프: 소스 디렉터리 구조가 ID 로 노출 — 수용.)
- **[결정됨 2026-05-16] IIFE 브라우저 동적 로더 = `<script>` 주입** (webpack jsonp 방식): `document.createElement("script")`+onload/onerror Promise, src=`__zntc_public_path`+청크파일. self-register payload 라 평가만 하면 `__zntc_register` 호출. 조건부 import() 대비: 클래식 스크립트 환경 포함 최대 호환, IIFE 포맷과 무충돌, public_path 자연 연동. (트레이드오프: CSP `script-src` 영향 — public_path/nonce 는 후속 옵션.) worker/Deno 등 non-DOM 폴백은 PR3 범위 외(필요 시 후속).
- preserve-modules CJS 의 Node `__esModule`/interop 경계(default/namespace).
- **[수정됨 2026-05-16, 후속 버그픽스]** same-chunk 동적 import(manualChunks/auto 가 동적 대상을 importer 청크에 병합) 시 raw `import("./x")` 가 미재작성돼 런타임 `ERR_MODULE_NOT_FOUND`(별도 파일 부재). 잘못된 `inline_dynamic_imports` 게이트 제거 → same-chunk 는 항상 재작성, `.none`(스코프호이스팅)은 `.local` export 를 namespace 객체로 스냅샷(`Promise.resolve().then(()=>({...}))`, esbuild 동일 값복사). **한계(문서화)**: 병합된 동적 대상이 *타 청크* 심볼을 re-export 하면 그 이름은 스냅샷에서 제외(이 청크 로컬 미바인딩 → ReferenceError 방지). live-binding 아닌 값 스냅샷.
- **[PR3 한계, 문서화]** IIFE 정적 cross-chunk 는 dep 청크 `<script>` 가 entry 보다 먼저 평가돼야 함(`__zntc_require`가 동기) — 호스트가 dep 스크립트를 entry 앞에 배치하거나 동적 `import()`(로드 await)만 사용. self-installing register 로 load-order 요구는 "entry 마지막" 하나로 축소(RFC §6). preserve-modules+iife·RSC 디렉티브×factory·CSP nonce 는 PR4 후속.
- **[수정됨 2026-05-16, PR4 UMD/AMD]** umd/amd + splitting 지원. PR3 iife_split 레지스트리/self-register/env-loader 기계 불변, 가드 완화(reg_ok=iife|umd|amd, `iife_split`→`reg_split`), entry 청크만 `format_wrapper.emitFormatPrologue/Epilogue`(보편 wrapper) 로 감싸고 bootstrap 을 `return globalThis.__zntc_require(id)` 로(iife 는 기존 bare/var 유지). 비-entry 청크는 IIFE-split 과 동일. CJS `require()`/AMD `define`/global 3모드 + 동적 청크 로드 Node 실행 검증. **한계(문서화)**: ① 정적 cross-chunk dep 가 있는 entry 는 single require/define 소비 시 sibling common 청크 미로드 → 동적-import 분할만 single-consume 안전(IIFE load-order 제약의 단일소비판). ② externals 는 split wrapper 시그니처에 미연결(빈 `define([])`). ③ dotted global_name·RSC×factory 는 단일파일 UMD 한계 상속.
- **[수정됨 2026-05-16, PR4 비-DOM 로더]** PR3 `__zntc_load_chunk` 는 `document.createElement` 만 써 worker/Deno/Node-ESM 에서 `document is not defined` → 동적 청크 로드 실패. 환경 감지 폴백: DOM→`<script>` / Web Worker(`importScripts`)→`importScripts(url)` / 그 외→동적 `import(url)`. 베이스라인 = 동적 import 지원(webpack/rollup/esbuild splitting 과 동일 전제). 비-DOM 은 public_path 절대/URL 필수(호스트 책임). DOM·worker·import() 3환경 Node 실행 검증.
- **[선재 한계, cjs/iife 공통]** entry 모듈이 `wrap_kind==.cjs`(자체 CJS 모듈)면 emitModule 이 final_exports 블록 전에 early-return → `iife_split_factory`/cjs entry-export 경로 미적용(factory-bound exports 누락 가능). PR2/PR3 공통, 신규 회귀 아님. 후속.
- **[수정됨 2026-05-16]** cross-chunk re-export(`export {x} from "./y"`, y 별도 청크) → 심볼 미바인딩 ReferenceError. 근본원인 (a) `computeCrossChunkLinks` 가 re-export `export_bindings` 미처리 (b) 심볼 canonical 청크가 직접 의존이 아니면 `cross_chunk_imports` 누락 → emitter named import 못 냄. 둘 다 수정(esm/cjs/iife, Node 실행 검증).
- **[수정됨 2026-05-16, 후속]** `export * from "./y"`(re_export_star, y 별도 청크) → 재-exporter 가 side-effect import 만 받아 inner 전체 export 미바인딩(link error). `collectExportsRecursive` 로 소스 effective export(nested/diamond 포함) 전부 열거, `linkReExportName`(named·star 공용 추출 헬퍼)로 canonical 다른 청크면 cross-chunk named 바인딩+재노출. esm/cjs Node 실행 검증. **`export * as ns from`(re_export_namespace, namespace 객체 합성) 및 `import * as P` 로 star-re-export 모듈을 namespace 소비**하는 경로는 emit-side namespace 객체 합성 필요 — 여전 별도 후속(미처리).
- **[수정됨 2026-05-16, PR4 버그 B]** ESM entry/dynamic 청크에서 `Duplicate export` SyntaxError — codegen 이 entry 모듈 소스 `export {}`(re-export 포함, cross-chunk 바인딩으로 로컬화)를 //#region 에 내는데 xchunk_exports 블록이 같은 이름(`chunk.exports_to`)을 또 냄. cjs/iife 는 `entry_mod_idx != null` break 로 회피, ESM 무게이트였음. 수정: ESM 일 때 entry 모듈이 export 하는 이름(kind 무관)을 xchunk 에서 제거(codegen 담당), 비-entry cross-chunk 심볼만 남겨 정확 1회 emit, 전부 제거 시 블록 생략. common/manual(entry_mod_idx==null) 무영향 → #3350 re-export 무회귀. Node 실행 검증.
- P3-A 가치 대비 비용: esbuild 미지원 영역. 수요(누가 CJS/IIFE+splitting 을 원하나) 확인 후 P3-B 착수 여부 게이트.

---

## 8. 권고

P3 는 단일 PR 기능이 아니라 **MF 런타임 레지스트리와 같은 하위 인프라를 공유하는 에픽**이다. 따라서:

1. 본 RFC 로 설계·통합 지점 고정(완료).
2. **P3-A(preserve-modules+CJS, 동적 로더 없는 최소)** 를 작은 PR 시리즈로 먼저.
3. **레지스트리/모듈ID 는 MF RFC §4.1 과 한 설계로** — MF P1 착수 시 P3-C 로 수렴(중복 구현 금지).

`docs/RFC_MODULE_FEDERATION.md` 와 상호 참조. 구현 착수 전 §7 결정·§6 스파이크 선행.

## 부록: 참고 코드

- 제약: `src/bundler/emitter/chunks.zig:65-73`
- 동적 import 재작성: `chunks.zig:961-1071` / cross-chunk import: `chunks.zig:222-321`
- 런타임 헬퍼: `src/bundler/runtime_helpers.zig`, `src/runtime_helper_modules.zig`
- Format enum: `src/bundler/types.zig` (Format), `src/main.zig` --format
- 비교/원칙: `docs/design/CODE_SPLITTING.md:46,227,313,434`
- MF 통합: `docs/RFC_MODULE_FEDERATION.md` §4.1, §6.1, §7
