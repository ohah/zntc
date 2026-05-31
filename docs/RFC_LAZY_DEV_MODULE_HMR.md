# RFC: Lazy dev — split 청크 모듈별 HMR (리로드 없이 상태 보존, #4038 재해결)

상태: **DRAFT · 설계 · 미착수** · 분류: dev UX / bundler / HMR
관련: `src/bundler/runtime_helpers.zig`, `src/bundler/graph/finalize.zig`, `src/bundler/linker.zig`, `src/bundler/linker/metadata.zig`, `src/bundler/emitter.zig`, `src/bundler/emitter/chunks.zig`, `src/bundler/types.zig`, `src/bundler/bundler.zig`, `src/bundler/incremental.zig`, `packages/web/runtime/dev-overlay-client.raw.js`
선행: `RFC_LAZY_DEV_MATERIALIZE.md`(materialize 완결) · 이슈 #4038 · #4079

## 1. 배경 — 무엇이 남았나

`zntc dev --lazy` 는 materialize(#4079)로 깊은 편집을 *감지·rebuild* 하게 됐고, 직후 fix(#4085)로 그 변경을 **full reload** 로 화면에 반영한다. 그러나 full reload 는:
- 앱 상태(스크롤·폼·메모리 state) 소실,
- 안 보는 라우트의 파일을 편집해도 전체 페이지 리로드,
- main 번들 dev 가 누리는 **모듈별 hot-replace + React Fast Refresh 상태 보존**을 lazy 라우트는 못 누림.

이상적 목표: **lazy 청크 안 모듈을 편집해도 그 모듈만 hot-replace + 상태 보존**(main 번들 HMR 과 동급).

## 2. 근본 원인 (조사 확정)

main 번들 dev HMR 은 모듈을 `__zntc_modules[dev_id]` 로 **개별 주소화**해 교체한다(runtime_helpers.zig:1092 `__zntc_apply_update`, types.zig:874 `fmtDevRequireExpr` = `__zntc_modules["id"].fn()`). 그런데 splitting 에선 이 dev 경로가 **3곳에서 `dev_mode and !code_splitting` 게이트로 꺼지고**(finalize.zig:108 wrap-all, linker.zig:71 require, emitter.zig:1874/1964), production IIFE registry(`__zntc_register`/`__zntc_mods`/`__zntc_require`)로 fallback 한다.

**왜 꺼졌나 (#4038):**
1. `__zntc_modules` 는 번들 IIFE-로컬 `var`(runtime_helpers.zig:961)이고 HMR_RUNTIME 은 entry 번들에만 주입된다 → split 청크엔 `__zntc_modules` 자체가 없다. cross-chunk `__zntc_modules["dep_id"].fn()` 은 `undefined.fn()` TypeError(회귀 가드 splitting_dev.zig:2638).
2. entry 미실행(BUG2) — split 청크엔 dev wrap-all entry 를 호출하는 부트스트랩이 없었다.

**부수**: lazy 청크 모듈의 dev code 는 **수집조차 안 된다**. module_dev_codes 는 단일번들 `emitWithTreeShaking`(emitter.zig:713)에서만 채워지고, `emitChunks`(chunks.zig:622)는 청크를 통째 concat 한다 → onRebuild.updates = 0.

**production IIFE registry 는 재활용 불가**: `__zntc_mods["<chunk_id>"]` = 청크당 factory 1개, 모듈은 그 closure 안에 scope-hoist(chunks.zig:193/297) → 모듈 개별 핸들 없음.

→ 이상적 fix 는 #4038 의 두 버그를 **split 컨텍스트에서 정면으로 다시 푸는** 작업 = 에픽.

## 3. 설계 — 글로벌 per-module dev 레지스트리

핵심 전환: `__zntc_modules` 를 **번들-로컬 var → globalThis-backed 공유 레지스트리**로 바꾸고, **모든 청크(entry+lazy+shared)가 자기 모듈을 그 글로벌 레지스트리에 per-module 등록**한다. 그러면 cross-chunk `__zntc_modules["dep_id"].fn()` 이 *로드된* 청크의 모듈을 찾는다(#4038 BUG1 해소).

- `g.__zntc_modules = g.__zntc_modules || {}` (idempotent, 청크 평가 순서 무관).
- 각 청크 IIFE 가 dev wrap-all(per-module factory)로 자기 모듈을 `g.__zntc_modules[dev_id] = {fn, exports, reset}` 등록. lazy 청크는 `__zntc_load_chunk` 로 로드될 때 등록.
- HMR_RUNTIME(`__zntc_apply_update`/`__zntc_make_hot`/`__zntc_hot_cbs`)은 entry 번들에 1회. lazy 청크 모듈도 글로벌 레지스트리에 있으니 그대로 hot-replace 가능(클라이언트 변경 0 또는 최소).
- **cross-chunk static dep 순서**(#4038 BUG1 의 핵심 risk): 모듈 M(청크 A)이 모듈 N(shared 청크 B)을 정적 import 하면, M 실행 전 B 가 로드·등록돼야 한다. splitting 런타임의 청크 로드 순서가 이를 보장하는지 PR-2 에서 검증(미보장 시 shared 청크 eager preload 또는 lazy 동적 lookup 로 fallback).
- **entry 부트스트랩**(BUG2): entry 청크가 자기 모듈 등록 후 entry fn 실행.

이는 production IIFE registry(`__zntc_register`, on-demand 로딩용)와 **공존**한다 — `__zntc_load_chunk` 는 그대로 청크를 fetch·평가하고, 평가 시 dev wrap-all 이 글로벌 dev 레지스트리에 등록. 즉 "청크 로딩=production, 모듈 교체=dev 레지스트리" 하이브리드.

## 4. PR 시퀀스 (TDD)

### PR-1: split/lazy emit 가 module_dev_codes 수집
`emitChunks` 가 per-module dev code 를 incremental 에 노출(또는 청크별 module list). TDD: lazy 빌드 watch 의 onRebuild 가 lazy 청크 모듈 편집 시 `updates` 에 그 모듈을 포함(현재 0). 클라이언트 적용은 PR-3 이후라 이 PR 만으론 화면 변화 없음(수집 인프라).

### PR-2 (코어): split/lazy dev wrap-all + 글로벌 `__zntc_modules`
finalize.zig:108 / linker.zig:71 / emitter.zig 게이트를 `dev_split` 에서 dev wrap-all 켜되 `__zntc_modules` 글로벌화 + 청크별 등록 + entry 부트스트랩. **#4038 회귀 가드(splitting_dev.zig)를 글로벌 모델로 갱신**. cross-chunk static dep 순서 검증. byte-identical: non-dev/non-split 0 영향.

### PR-3: 클라이언트 — cross-chunk 모듈 hot-replace + 신규 모듈 lazy 청크 re-fetch
`__zntc_apply_update` 가 글로벌 레지스트리 모듈 교체(대개 이미 동작). 새 동적 import 추가 등 신규 모듈은 lazy 청크 re-fetch.

### PR-4: dev 서버가 lazy 도 module update broadcast (full reload 갈음 제거)
#4085 의 lazy full-reload 폴백을, updates 가 있으면 module HMR 로 전환(updates 없을 때만 full reload). React 컴포넌트는 PR-5 의 Fast Refresh accept 로 상태 보존.

### PR-5: lazy 청크 컴포넌트 Fast Refresh accept (상태 보존)
emitter.zig:1980 의 `__zntc_make_hot(id).accept()` 자동 주입을 split 청크에도(dev_id 세팅 후). 이게 "상태 보존"의 마지막 조각.

## 5. 수용 기준 (acceptance test, TDD 의 최종 red→green)

브라우저 e2e: lazy 라우트 방문 후 그 안 컴포넌트의 state(예: 카운터)를 올린 뒤 그 컴포넌트 파일을 편집 → (a) 변경이 화면에 반영되고 (b) **페이지 리로드 없이**(window marker 생존) (c) **state 보존**(카운터 값 유지). 현재 full reload 라 (b)(c) 실패 = red. 에픽 완료 시 green.

## 6. 리스크

- **cross-chunk static dep 로드 순서**(#4038 BUG1 의 본질) — 가장 큰 risk. shared 청크가 dependent 전에 로드·등록되는지. 미보장 시 eager preload or 동적 lookup fallback 필요.
- **#4038 회귀** — 일부러 끈 영역. 회귀 가드(splitting_dev.zig) 갱신 + 광범위 e2e 필수.
- **production 0 영향** — 모든 게이트는 dev_mode 한정. byte-identical 가드.
- **번들 크기/오버헤드** — dev wrap-all(per-module factory)이 split 청크를 키운다. dev 전용이라 수용.

## 7. 비목표

- production 빌드 변경 없음. lazy 전용 dev.
- full reload 폴백 제거는 PR-4 까지 유지(updates 없으면 여전히 full reload — 안전망).
