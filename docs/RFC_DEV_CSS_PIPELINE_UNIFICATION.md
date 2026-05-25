# RFC: dev CSS pipeline 통일 — cssPlugin vs dev-controller 역할 정리

상태: **재설계 필요 (PR-3a revert + A-1 회수)** · 분류: XL · 선행: #2538 4-4 PR-3a (revert #3838), PR-3b attempt, A-1 attempt
관련: `project_2538_4_4_in_progress` · Vite resolvePlugins · `feedback_race_dont_mitigate`

## 0. 변경 이력

| Rev | 시점 | 변화 |
|---|---|---|
| v1 | 초안 | PR-3b verify 4 finding 정리 + 옵션 A/B/C 비교. 권장 A + 6-단계 sub-PR |
| v2 | A-1 attempt 후 | **A-1 PR /code-review max 가 새 finding #4 발견 → PR-3a 자체가 dead code 확정**. 옵션 A 의 전제 (cssPlugin 이 build path 에서 동작) 가 무효. RFC 재설계 필요. 옵션 A/B/C 모두 sync/async dispatcher 충돌 미고려 |

## 1. 배경 (PR-3b attempt)

#2538 4-4 PR-3a (fb2b04af, **revert #3838**) 는 `zntc build --app` 가 사용자 explicit plugin 없어도 `@zntc/web/css` 를 자동 prepend 하도록 함 (Vite `vite:css` 패턴). PR-3b 는 같은 패턴을 `zntc dev` (runAppDev → runServe) 로 확장 시도. `/code-review max` Phase 2 verify 에서 **4개 CONFIRMED finding**:

| # | 위치 | 영향 |
|---|---|---|
| **1** | `zntc.mjs:1936, 2146` — graphChanged / sass-rebuild 의 `runBundle(opts, config)` 가 cssPlugin 미전달 | cold-start vs rebuild 사이 plugin drift |
| **2** | dev-controller `prepare()` 가 이미 tempRoot 의 모든 `.css` 에 PostCSS 처리 + cssPlugin onLoad 가 같은 파일에 또 처리 | **PR-3b 신규 회귀 — `zntc dev` + postcss config 모든 사용자에게 PostCSS 이중처리** |
| **3** | `css/index.ts:78` 가 `process.env.NODE_ENV` / `process.cwd()`, dev-controller 가 `configEnv.mode` / `root` | monorepo + `--mode staging` 에서 postcss config env divergence |
| **4** | `resolveAppPlugins` 가 dedup 안 함 (PR-3a 부터) | 사용자가 `css({...})` 명시해도 default 또 prepend |

v1 RFC 는 #2 를 근본 차단으로 보고 dev-controller 슬림화 (옵션 A) 권장. 하지만 v2 가 더 큰 문제 발견.

## 1.5. A-1 attempt 의 추가 finding (v2 추가)

A-1 (옵션 A 첫 sub-PR — cssPlugin filter 확장 + module CSS 처리) 시도 중 `/code-review max` 가 **PR-3a 자체를 무효화하는 finding #4** 발견:

> **`buildAppSync` (`packages/core/index.ts:2780`) 가 sync dispatcher 강제** — `resolveDispatcher(opts, 'sync')` → `driveDispatchSync`. async function 인 cssOnLoad (`packages/web/src/css/index.ts:71-126`, async arrow) 가 Promise 반환 → 즉시 `syncPluginPromiseFailure` (`packages/core/index.ts:2206-2225`) 로 plugin failure 변환. = **PR-3a 의 default cssPlugin 이 `zntc build app` 의 native path 에서 dead code**.
>
> PostCSS 가 실제로 작동하는 이유 = `prepareAppCssPipelineRoot` (`dev-controller.ts:267`) 가 tempRoot 의 .css 를 별도로 PostCSS 처리해 결과를 `buildAppSync` 가 read. 통합테스트 `[postcss] processed 1 CSS file` 단언의 출처도 dev-controller path (`packages/web/src/style/postcss.ts:73`) — cssPlugin 동작과 무관.

A-1 attempt 의 추가 architectural finding (활성화 시 발화):
- **a1-#1** proxy 의 `./X.module.zntc.css` import 는 source tree 옆 resolve, emitFile asset 은 outdir → 다른 namespace. A-3 활성 시 빌드 실패
- **a1-#3** 다른 dir 의 같은 basename `.module.css` → outdir 의 같은 파일에 emit → silent overwrite
- **a1-#2** `mapping = {}` prototype shadowing (`.constructor`/`.toString` class 시 매핑 누락 + CSS garbage) — css-modules.ts:236-241 도 사전 존재
- **a1-#5** `options.root ?? process.cwd()` → cwd 의존 hash → scoped class name 비결정적

**결정**: PR-3a revert (#3838) + A-1 attempt 회수 (branch 폐기) + #3837 hot-fix (resolveAppPlugins dedup) close.

v1 RFC 의 옵션 A/B/C 는 모두 sync/async dispatcher 충돌 미고려 → **v2 부터 재설계의 핵심 axis 는 sync/async dispatcher**.

## 1.6. v2-A (D1a 구현 시도) 의 회귀 — v3 추가

PR #3839 (close) 가 v2-A D1a (`runAppBuild` 가 async `buildApp` 호출 + Zig 측 `napiBuildApp` 진입점 신설) 구현 시도. CI + local 재현으로 **명확한 회귀** 발견:

**증상** (Tailwind v4 fixture 로 재현):
- main baseline (PR-3a revert + JS only, Zig 미적용): `[postcss] processed 1 CSS file(s)` 정상 + `n.buildApp is not a function` (예상, native 미구현)
- v2-A (Zig + JS 다 적용): `[postcss] processed 1 CSS file(s)` 정상 + **native bundler 가 raw `@import "tailwindcss";` 를 받아 JS parser 로 시도 → `parse_error` → BundleFailed**

즉 `prepareAppCssPipelineRoot` 가 tempRoot 의 `.css` 를 PostCSS 처리하는데, **async worker thread 의 `buildApp` 이 그 결과를 못 보고 raw CSS 사용**. CI 의 6 styles tests (`PostCSS`/`Sass`/`CSS Modules basics`/`build collisions`) 모두 동일 패턴 fail.

**가능한 근본 원인** (추가 조사 필요):
- worker thread fs cache (POSIX 무관일 수 있으나 검증 필요)
- async `buildApp` 의 옵션 파싱이 `buildAppSync` 와 미세 차이 (예: mode/define/jsx 누락 → 다른 분기 진입)
- prepare 와 buildApp 의 root path 처리 미세 차이
- `prepareAppCssPipelineRoot` 가 PostCSS 결과를 in-place write 대신 별도 결과 객체 반환하는데, sync caller 는 그것 사용하고 async caller 는 못 받는 가능성

**결정**: v2-A revert. D1a 단순 구현이 회귀 → 대안 design 검토.

### 대안 design 후보 (v3)

| 대안 | 설명 | 비용 | trade-off |
|---|---|---|---|
| **D1a' — prepare 결과 명시 전달** | `prepareAppCssPipelineRoot` 가 결과를 explicit hash/manifest 로 반환. `buildApp` 가 그것을 namedArg 로 받아 worker thread 에서 fs view 보정. async worker 에서도 동일 결과 보장 | M+ — prepare API 변경 + buildApp 옵션 확장 + native side 동기화 |
| **D1d — sync+async variant** | 기존 `buildAppSync` 유지 + 새 `buildApp` async = sync 의 thin wrapper (정확한 same call, 단 Promise 로 wrap). worker thread 사용 안 함. CLI 만 새 async path. plugin 의 async hook 은 caller 측에서 await 후 sync dispatcher 로 main thread blocking — sync dispatcher × async hook 충돌 여전 미해결 | S — wrapper 만. 단 핵심 문제 (PR-3a dead-code 원인) 해결 못 함 — design 무효 |
| **D1a'' — buildAppSync 호출 path 안에 plugin pre-warm** | `runAppBuild` 가 prepare 후, plugin 의 async hook 을 별도 pass (예: PostCSS 호출 main thread async) 로 실행해 결과를 tempRoot 에 commit. 그 후 buildAppSync 호출 — sync dispatcher 안전 | L — 새 pre-warm 단계 + plugin 의 async hook 우회 호출 protocol |
| **D1c — cssOnLoad sync 강제 + caller 측 async pre-warm** | cssPlugin 의 onLoad 가 sync 만 (PostCSS sync 호출만 — async plugin 없을 때만 동작). PostCSS 의 async 처리는 사용자가 `runAppBuild` 호출 전 별도 단계로 | S — cssPlugin 단순화. 단 async plugin 사용자 (tailwind v4 등) 미지원 |

D1a' 가 가장 정합 (worker thread 가 prepare 결과를 명시 받음 — fs side-effect 의존 제거). 단 native side 변경 더 큼. 구현 spike 필요.

## 2. 핵심 문제 — sass→postcss→css-modules invariant

`dev-controller.ts:351-357` 주석 (통합테스트 `Sass output flows through PostCSS before CSS Modules scoping` 이 가드):

```
파이프라인 순서 (유지 필수):
 1. Sass: *.scss/.sass → *.css (.module.scss 면 .module.css 가 새로 생김)
 2. PostCSS: 모든 *.css 에 변환 적용 (Tailwind 등이 @apply 같은 룰 주입)
 3. CSS Modules: postcss 가 주입한 .injected 같은 selector 까지 scoping
순서가 바뀌면 postcss 가 추가한 selector 가 scoped 안 되거나 sass 미컴파일 상태로
postcss 가 돌아 깨진다.
```

cssPlugin onLoad 의 filter 는 `(?<!\.module)\.css$` — module CSS 는 건너뜀. 따라서 단순 "dev-controller 의 postcss 단계만 제거 + cssPlugin 이 모든 .css 담당" 은:

- `*.module.css` → CSS Modules 입력에서 PostCSS 결과 사라짐 → Tailwind `@apply` 가 module CSS 안에서 작동 안 함
- `.module.scss` 의 sass output → 마찬가지

Vite 와 ZNTC 의 본질적 차이:
- **Vite**: `vite:css` 가 dev/build 양쪽의 **유일한** CSS 처리자. sass/css-modules/postcss 전부 한 plugin 안.
- **ZNTC**: dev 에 별도 dev-controller pipeline 이 sass/css-modules/postcss 를 sequencing. cssPlugin 은 build 의 단일 처리자였으나 dev path 진입 시 dev-controller 와 책임 중첩.

= PR-3b 의 "Vite 식 dev/build 통일" 은 dev-controller 의 존재 자체를 재검토하지 않으면 달성 불가.

## 3. 재설계 핵심 axis — dispatcher mode

v1 옵션 A/B/C 는 모두 cssPlugin 이 `buildAppSync` 안에서 정상 호출된다는 잘못된 가정. 실은 sync dispatcher 에서 async onLoad = dead. **dispatcher mode 결정이 모든 옵션의 선행 조건**.

### Axis 1 — buildAppSync 가 async hook 을 허용할까?

| 옵션 | 설명 | 비용 | 결과 |
|---|---|---|---|
| **D1a** (Recommended) | `runAppBuild` 가 async `build` 호출로 전환. `buildAppSync` 는 **thin sync wrapper 로 유지**하고 async-only plugin 감지 시 throw — public NAPI API 보존 + semver 0.x 안전. v2-A 가 변경하는 건 caller (runAppBuild) 만 | M — caller side (runAppBuild + dispatch 분기 2 호출처). `buildAppSync` export 유지, internal-only deprecation 주석 | dev/build 양쪽 async 단일 entry — async onLoad 자유 |
| **D1b** | `buildAppSync` 내부에서 async hook 도 wait — Node JS single-thread event loop 위에서 sync 호출 안 async wait 는 **deadlock 확실** (`Atomics.wait` on main thread 만 가능, JS callback 은 macrotask 라 영영 발화 안 됨). | **Infeasible — Node JS single-thread 모델 위반** | (포함만, 완성도 위해) |
| **D1c** | `cssOnLoad` 를 sync 로 — PostCSS sync 호출 (postcss.parse + plugins 동기 실행). PostCSS 자체가 plugin 의 async 호환이라 모든 plugin 이 sync 라는 보장 없음. tailwind v4 = async plugin | S — onLoad 내부 변경. 단 사용자 postcss plugin 이 async 면 fail. 실용성 매우 낮음 | 단기 hack, 장기 미래 X |
| **D1d** | sync/async 두 가지 cssPlugin variant — `cssSync()` + `cssAsync()`. caller 가 dispatcher mode 에 맞춰 선택 | M — factory 2개, 사용자 선택 부담. D1a 가 가능하면 불필요 | dev = cssAsync, build = cssSync. 사용자 cognitive load 증가 |

**잠정 권장 = D1a + buildAppSync 보존**. `runAppBuild` 가 async `build` 호출로 전환하되 `buildAppSync` export 자체는 thin sync wrapper 로 유지 — Vite adapter build mode / NAPI 직접 호출 사용자 영향 0. CLI (`zntc build app`) 만 async path 진입.

### Axis 2 — cssPlugin 의 CSS Modules 처리 모델 (a1 finding 들 흡수)

A-1 attempt 에서 발견된 architectural flaw 들 (proxy import path vs emit path namespace, basename collision, prototype shadowing, cwd-leak):

| 옵션 | 설명 | a1 finding 해결 | 실현성 |
|---|---|---|---|
| **D2a** (장기 목표) | Vite/esbuild 식 onResolve 로 `.module.css` 를 virtual id namespace 로 변환 + 두 번째 onLoad 가 그 virtual id 에서 scoped CSS 반환. proxy 가 그 virtual id 를 import | a1-#1 ✅, a1-#3 ✅, a1-#5 (root 명시로 해결) | **선행 조건 미충족** — `packages/core/index.ts` 의 plugin onResolve/onLoad 가 filter-only (regex on path). namespace 필드 부재. namespace infra 추가가 별도 epic (XL) |
| **D2b** (Recommended) | emitFile 의 fileName 을 `cssModuleGeneratedCssPath(args.path)` (절대경로 또는 source-tree relative) 로 변경 + EmitStore 가 절대/relative 받도록. proxy 의 `./X.module.zntc.css` import 가 그 source tree 위치에 resolve | a1-#1 ✅ (proxy resolve 가능), a1-#3 ✅ (각 dir 별 다른 file), a1-#5 별도 fix | **today's filter-only plugin 모델 위에서 즉시 구현 가능** |
| **D2c** | proxy 안에 scoped CSS 를 inline import (`import 'data:text/css;base64,...'` 또는 side-effect import) | 복잡, base64 size 부담 | 비효율 |

**잠정 권장 = D2b (절대경로 emit)**. D2a 는 plugin namespace infra 별도 epic 의존 → v2-B 에서 D2b 채택, D2a 는 future work 로 분리. ZTS plugin types 확인: `packages/core/index.ts` 의 onResolve/onLoad 가 `{filter: RegExp}` 만 — namespace 필드 없음.

### Axis 3 — dev-controller 의 책임 분리 (v1 옵션 A/B/C 표 inline)

v1 §3 옵션을 v2 self-contained 로 inline (v1 commit ccdd9991 참조 없이 v2 만으로 판단 가능):

| 옵션 | 설명 | Pros | Cons |
|---|---|---|---|
| **A** | dev-controller `prepare()` 슬림화 — sass 만 유지. cssPlugin 이 PostCSS/css-modules 단독 처리 | Vite parity 완전 / 책임 일원화 | cssPlugin 비대화, sass↔dev-controller state 통신 필요 |
| **B** | dev-controller 가 sequencing 안에서 cssPlugin 의 onLoad 직접 호출 (plugin 추상화 위반) | invariant 유지 / cssPlugin build 동작 무변경 | 결합도 폭증 |
| **C** | 2-pass + marker dedup — dev-controller 가 처리한 파일에 marker, cssPlugin onLoad 가 marker 보면 skip | 최소 변경 | fragile, PR-3b 의 dev path 가 사실상 dead |

v2 의 axis 1/2 결정 후 재평가. axis 1 = D1a + axis 2 = D2b 채택 시 옵션 A 가 자연스러움.

### Axis 4 — 사용자 explicit `css({...})` dedup

이슈 #3836 의 dedup 동작. PR-3a 사라지면 `resolveAppPlugins` helper 자체 없음 → 새 RFC 의 plugin auto-prepend 메커니즘 일부로 흡수. v2-E 가 새 helper 도입 + dedup.

## 4. 권장 sub-PR 분해 (v2)

각 sub-PR 의 게이트 = `/code-review max` 통과 + **정확한 통합테스트 list** + measure-first.

| # | scope | 통합테스트 gating list |
|---|---|---|
| **v2-A** | D1a — `runAppBuild` 가 async `build` 호출로 전환. `buildAppSync` 는 thin sync wrapper 로 유지 (export 보존). dispatch 분기 (`runAppBuild`/dev mode 진입점) 변경 | `tests/integration/app-builder/build-basics`, `styles/postcss`, `styles/sass`, `styles/css-modules-basic` (회귀 0 필수) |
| **v2-B** | 새 cssPlugin 재설계 — D2b (절대경로 emit) 로 module CSS 처리. PostCSS 도 async 호출. unit test full coverage. caller (`runAppBuild`/`runAppDev`) 가 root/mode 명시 의무화 (#3835 흡수) | `css.test.ts` 신규 module branch unit + 기존 `styles/css-modules-basic`/`-postcss` 회귀 가드 |
| **v2-C** | dev-controller `prepare()` slim down (axis 3 옵션 A, sass 만 유지) + cssPlugin 으로 PostCSS/css-modules 위임. sass→postcss→css-modules invariant 통합테스트 유지 | `Sass output flows through PostCSS before CSS Modules scoping` (dev-controller.ts:351-357 가드), `styles/dev`, `styles/sass`, `styles/css-modules-postcss` |
| **v2-D** | runAppDev wiring + 이슈 #3834 (runBundle cssPlugin forward). watch+HMR rebuild 의 cssPlugin chain 일관성 | `dev-hmr/comprehensive-e2e`, `dev-server/restart`, `styles/dev` |
| **v2-E** | 새 dedup helper 도입 (이슈 #3836). user explicit `css({...})` 시 default skip. `resolveAppPlugins` 또는 다른 이름 — RFC v1 의 `app-default-plugins` 와 의미 동일하나 sync/async dispatcher 안전 | `app-default-plugins.test.ts` 신규 (dedup edge case 6+) |

## 5. 미해결 finding 의 별도 트래킹 (v2 갱신)

PR-3b verify 의 finding (#1 / #3 / #4) 와 A-1 attempt 의 finding (a1-#1 ~ a1-#5) 의 v2 재평가:

| finding | v2 처리 | acceptance criterion |
|---|---|---|
| #1 runBundle cssPlugin forward (이슈 #3834) | **v2-D 단계 (dev wiring)** — async dispatcher 라면 cssPlugin 자체가 다시 의미 가짐 (axis 1 D1a 후 활성) | v2-D 머지 시 dev mode 의 cold-start + graphChanged + sass-rebuild 가 모두 동일 cssPlugin chain 사용 (e2e test 추가) |
| #3 NODE_ENV vs configEnv.mode (이슈 #3835) | **v2-B 의 hard-bind acceptance** — caller (`runAppBuild`/`runAppDev`) 가 `css({ root, mode })` 명시 전달 의무. v2-B descope 시 별도 standalone hot-fix 트랙으로 분리 | v2-B PR test 가 caller 가 `root`+`mode` 명시한 case + 미명시 시 default fallback (warn) 검증. v2-B 가 미머지면 #3835 가 standalone hot-fix 로 진행 |
| #4 dedup (이슈 #3836, hot-fix #3837 close) | **v2-E 단계** | v2-E PR test 가 user explicit `css()` 시 default skip + name 정확 일치 |
| a1-#1 proxy namespace mismatch | **axis 2 (D2b 채택, source-tree 절대경로 emit)** 로 자동 해소 | v2-B 의 PR test 가 다른 dir 의 module CSS 2개 + proxy resolve 검증 |
| a1-#2 prototype shadowing | css-modules.ts:236-241 사전 존재 — RFC 와 **무관 별도 hot-fix** (`Object.create(null)` 또는 `Object.hasOwn` 가드). RFC 머지 wait 없이 즉시 가능 | standalone PR — `Object.hasOwn` 가드 + `.constructor` class test |
| a1-#3 basename collision | **axis 2 (D2b)** 로 자동 해소 (각 dir 별 다른 source-tree 절대경로) | v2-B PR test |
| a1-#5 cwd-leaked hash | **v2-B caller 가 root 명시로 흡수** | v2-B test 가 `process.cwd()` 변경에 대해 결정성 검증 |

## 6. 결정 가이드 (v2) — 머지 전 합의 항목

본 RFC v2 PR (#3833) 머지 전 다음 결정:

1. **axis 1**: D1a + buildAppSync 보존 채택 여부 (CLI 만 async path, public NAPI 보존 — semver 0.x 안전)
2. **axis 2**: **D2b (절대경로 emit) 권장** — D2a (virtual id) 는 plugin namespace infra 별도 epic 의존, future work
3. **axis 3**: 옵션 A (dev-controller slim down) — axis 1+2 결정 후 자연스러움. v2-C 에서 진행
4. v2-A ~ v2-E sub-PR 순서 + 각 게이트 (위 §4 표) 동의 여부
5. **a1-#2 (prototype shadowing)** standalone hot-fix 분리 여부 — RFC 무관, 즉시 가능

---

**Refs**:
- PR-3a fb2b04af (revert PR #3838)
- PR-3b (보류, push 안 됨)
- A-1 attempt (보류, branch 폐기)
- #3837 hot-fix dedup (close — PR-3a revert 와 함께)
- Vite `resolvePlugins` (dist/node/chunks/dep-*)
- esbuild plugin namespace (`onResolve({ filter, namespace })`) — ZTS 미지원
- ZNTC dev-controller `prepareAppCssPipelineRoot` 351-357 (sass→postcss→css-modules invariant)
- ZNTC plugin types: `packages/core/index.ts` onResolve/onLoad = `{filter: RegExp}` only (namespace 부재)
