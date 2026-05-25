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

> **`buildAppSync` (`packages/core/index.ts:2780`) 가 sync dispatcher 강제** — `resolveDispatcher(opts, 'sync')` → `driveDispatchSync`. async function 인 cssOnLoad (`packages/web/src/css/index.ts:82`) 가 Promise 반환 → 즉시 `syncPluginPromiseFailure` (`packages/core/index.ts:2206-2225`) 로 plugin failure 변환. = **PR-3a 의 default cssPlugin 이 `zntc build app` 의 native path 에서 dead code**.
>
> PostCSS 가 실제로 작동하는 이유 = `prepareAppCssPipelineRoot` (`dev-controller.ts:267`) 가 tempRoot 의 .css 를 별도로 PostCSS 처리해 결과를 `buildAppSync` 가 read. 통합테스트 `[postcss] processed 1 CSS file` 단언의 출처도 dev-controller path (`packages/web/src/style/postcss.ts:73`) — cssPlugin 동작과 무관.

A-1 attempt 의 추가 architectural finding (활성화 시 발화):
- **a1-#1** proxy 의 `./X.module.zntc.css` import 는 source tree 옆 resolve, emitFile asset 은 outdir → 다른 namespace. A-3 활성 시 빌드 실패
- **a1-#3** 다른 dir 의 같은 basename `.module.css` → outdir 의 같은 파일에 emit → silent overwrite
- **a1-#2** `mapping = {}` prototype shadowing (`.constructor`/`.toString` class 시 매핑 누락 + CSS garbage) — css-modules.ts:236-241 도 사전 존재
- **a1-#5** `options.root ?? process.cwd()` → cwd 의존 hash → scoped class name 비결정적

**결정**: PR-3a revert (#3838) + A-1 attempt 회수 (branch 폐기) + #3837 hot-fix (resolveAppPlugins dedup) close.

v1 RFC 의 옵션 A/B/C 는 모두 sync/async dispatcher 충돌 미고려 → **v2 부터 재설계의 핵심 axis 는 sync/async dispatcher**.

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
| **D1a** | `buildAppSync` 를 폐기 / 모든 caller (runAppBuild) 를 async `build` 로 마이그레이션 | M — caller side. sync 호출처 모두 await 추가. `prepareAppCssPipelineRoot` 이후의 `await build(...)` 가능하나 sync API 사용자 (NAPI 직접 호출 / Vite adapter 의 build mode) 가 영향 | dev/build 양쪽 async 단일 entry — async onLoad 자유 |
| **D1b** | `buildAppSync` 가 sync entry 유지하되 내부적으로 async hook 도 wait — Tokio 식 blocking_on 또는 Zig 측 thread-per-hook 으로 dispatcher 가 sync 컨텍스트에서 async hook 대기 | XL — Zig 측 NAPI 호출 모델 변경. blocking on JS event loop 가 sync 호출 안에서 deadlock 위험. 매우 위험 | dev/build async 통일 가능, 하지만 비용 too high |
| **D1c** | `cssOnLoad` 를 sync 로 — PostCSS sync 호출 (postcss.parse + plugins 동기 실행). PostCSS 자체가 plugin 의 async 호환이라 모든 plugin 이 sync 라는 보장 없음. tailwind v4 = async plugin | S — onLoad 내부 변경. 단 사용자 postcss plugin 이 async 면 fail. 실용성 매우 낮음 | 단기 hack, 장기 미래 X |
| **D1d** (Recommended) | sync/async 두 가지 cssPlugin variant — `cssSync()` (sync onLoad, PostCSS-only with sync plugin list) + `cssAsync()` (async, full). caller 가 dispatcher mode 에 맞춰 선택 | M — factory 2개, 사용자 선택. RFC 본 옵션과 함께 D1a 마이그레이션 병행하면 cssSync deprecated path | dev (async build) = cssAsync, build 의 buildAppSync = cssSync (PostCSS only, sass/css-modules 는 dev-controller 가 처리 — 즉 build 도 dev-controller 식 prepareAppCssPipelineRoot 가 필요) |

**잠정 권장 = D1a (runAppBuild 가 async `build` 호출).** buildAppSync 의 존재 이유 = NAPI 직접 호출 또는 Vite adapter 의 build mode 일 뿐, `zntc build app` CLI 자체는 async 가 자연. 비용 가장 낮음.

### Axis 2 — cssPlugin 의 CSS Modules 처리 모델 (a1 finding 들 흡수)

A-1 attempt 에서 발견된 architectural flaw 들 (proxy import path vs emit path namespace, basename collision, prototype shadowing, cwd-leak):

| 옵션 | 설명 | a1 finding 해결 |
|---|---|---|
| **D2a** (Vite/esbuild 모델) | onResolve 로 `.module.css` 를 virtual id (`\0zntc:module-css:<absPath>`) 로 변환 + 두 번째 onLoad 가 그 virtual id 에서 scoped CSS 반환. proxy 가 그 virtual id 를 import. emitFile 미사용 — 모든 CSS 가 graph 의 일반 module 로 들어감 | a1-#1 (namespace mismatch) ✅, a1-#3 (basename collision) ✅ (virtual id 가 path-keyed), a1-#5 (cwd hash) — caller 가 root 명시하면 해결 |
| **D2b** | emitFile 의 fileName 을 `cssModuleGeneratedCssPath(args.path)` (절대경로) 로 변경 + EmitStore 가 절대경로도 받도록 | a1-#1 (proxy resolve 가능), a1-#3 (각 dir 별 다른 file), a1-#5 별도 fix |
| **D2c** | proxy 안에 scoped CSS 를 inline import (`import 'data:text/css;base64,...'` 또는 side-effect `import './x.module.zntc.css'` 를 별도 plugin 으로 등록) | 복잡, base64 size 부담 |

**잠정 권장 = D2a (Vite/esbuild virtual id 모델).** 단 ZTS plugin 의 onResolve / onLoad 가 namespace prefix 지원 여부 확인 필요 (esbuild 의 `namespace` 필드).

### Axis 3 — dev-controller 의 책임 분리

v1 옵션 A 그대로 — dev-controller slim down (sass 만 유지) 또는 옵션 B (cssPlugin 호출) 또는 옵션 C (marker dedup). v2 에서는 axis 1/2 결정 후 재평가.

### Axis 4 — 사용자 explicit `css({...})` dedup

이슈 #3836 의 dedup 동작. PR-3a 사라지면 `resolveAppPlugins` helper 자체 없음 → 새 RFC 의 plugin auto-prepend 메커니즘 일부로 흡수.

## 4. 권장 sub-PR 분해 (v2)

**v2-A**: D1a — `runAppBuild` 를 async `build` 로 전환 + `buildAppSync` 의 caller 정리 (이 단계까지는 cssPlugin 미관여, 인프라만)

**v2-B**: 새 cssPlugin 재설계 — D2a (virtual id 모델) 로 module CSS 처리. PostCSS 도 async 호출. unit test full coverage. build path 만 활성, dev path 는 dev-controller 유지

**v2-C**: dev-controller slim down (sass 만 유지) + cssPlugin 으로 PostCSS/css-modules 위임. 통합테스트 가드 — sass→postcss→css-modules invariant 유지

**v2-D**: runAppDev wiring + finding #1 (runBundle cssPlugin forward)

**v2-E**: 사용자 dedup helper 재도입 (PR-3a 의 resolveAppPlugins 대체)

각 단계마다 `/code-review max` 통과 + 통합테스트 + measure-first.

## 4.5. 결정 가이드

RFC v2 머지 전 합의:
- **axis 1**: D1a 채택 여부 (runAppBuild async 전환)
- **axis 2**: D2a (virtual id) vs D2b (절대경로 emit) — ZTS plugin namespace 지원 확인 후
- v2-A ~ v2-E sub-PR 순서 + 각 게이트
- 통합테스트 회귀 0 / measure-first (cold-start 시간 vs main)

## 5. 미해결 finding 의 별도 트래킹 (v2 갱신)

PR-3b verify 의 finding (#1 / #3 / #4) 와 A-1 attempt 의 finding (a1-#1 ~ a1-#5) 의 v2 재평가:

| finding | v2 처리 |
|---|---|
| #1 runBundle cssPlugin forward (이슈 #3834) | v2-D 단계 (dev wiring). 단 axis 1 결정 후 — async dispatcher 라면 cssPlugin 자체가 다시 의미 가짐 |
| #3 NODE_ENV vs configEnv.mode (이슈 #3835) | v2-B 의 새 cssPlugin 설계에 caller 가 root/mode 명시 의무화로 흡수 |
| #4 dedup (이슈 #3836, hot-fix #3837 close) | v2-E 단계 |
| a1-#1 proxy namespace mismatch | axis 2 (D2a 채택) 로 자동 해소 |
| a1-#2 prototype shadowing | css-modules.ts:236-241 사전 존재 — RFC 와 무관 별도 hot-fix 가능 (`Object.create(null)`) |
| a1-#3 basename collision | axis 2 (D2a) 로 자동 해소 |
| a1-#5 cwd-leaked hash | v2-B caller 가 root 명시로 흡수 |

## 6. 결정 가이드 (v2)

본 RFC v2 머지 전:
- **axis 1**: D1a (runAppBuild → async build) 채택 여부 → 비용 측정 (NAPI sync caller 영향)
- **axis 2**: D2a (virtual id) vs D2b (절대경로 emit) — ZTS plugin namespace 지원 확인 후
- v2-A ~ v2-E sub-PR 순서 + 각 게이트 (회귀 size / 통합테스트 / measure-first)
- a1-#2 (prototype shadowing) 즉시 hot-fix 분리 여부 — RFC 와 무관

---

**Refs**:
- PR-3a fb2b04af (revert PR #3838)
- PR-3b (보류, push 안 됨)
- A-1 attempt (보류, branch 폐기)
- #3837 hot-fix dedup (close — PR-3a revert 와 함께)
- Vite `resolvePlugins` (dist/node/chunks/dep-*)
- esbuild plugin namespace (`onResolve({ filter, namespace })`)
- ZNTC dev-controller `prepareAppCssPipelineRoot` 351-357 (sass→postcss→css-modules invariant)
