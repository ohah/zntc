# RFC: dev CSS pipeline 통일 — cssPlugin vs dev-controller 역할 정리

상태: **Draft (조사 완료, 설계 미확정)** · 분류: L · 선행: #2538 4-4 PR-3a (fb2b04af), PR-3b attempt
관련: `project_2538_4_4_in_progress` · Vite resolvePlugins · `feedback_race_dont_mitigate`

## 1. 배경

#2538 4-4 PR-3a (fb2b04af) 는 `zntc build --app` 가 사용자 explicit plugin 없어도 `@zntc/web/css` 를 자동 prepend 하도록 함 (Vite `vite:css` 패턴). PR-3b 는 같은 패턴을 `zntc dev` (runAppDev → runServe) 로 확장 시도. `/code-review max` Phase 2 verify 에서 **4개 CONFIRMED finding**:

| # | 위치 | 영향 |
|---|---|---|
| **1** | `zntc.mjs:1936, 2146` — graphChanged / sass-rebuild 의 `runBundle(opts, config)` 가 cssPlugin 미전달 | cold-start vs rebuild 사이 plugin drift |
| **2** | dev-controller `prepare()` 가 이미 tempRoot 의 모든 `.css` 에 PostCSS 처리 + cssPlugin onLoad 가 같은 파일에 또 처리 | **PR-3b 신규 회귀 — `zntc dev` + postcss config 모든 사용자에게 PostCSS 이중처리** |
| **3** | `css/index.ts:78` 가 `process.env.NODE_ENV` / `process.cwd()`, dev-controller 가 `configEnv.mode` / `root` | monorepo + `--mode staging` 에서 postcss config env 분기 divergence |
| **4** | `resolveAppPlugins` 가 dedup 안 함 (PR-3a 부터, PR-3b 가 amplify) | 사용자가 `css({...})` 명시해도 default 또 prepend → silent shadow 또는 double-run |

본 RFC 는 **#2 가 PR-3b 디자인의 근본 차단** 이라는 인식 하에, dev mode CSS pipeline 의 책임 분담을 재설계하기 위한 옵션을 정리한다. #1/#3/#4 는 본 epic 으로 흡수 또는 별도 이슈로 분리.

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

## 3. 재설계 옵션

### A. cssPlugin 이 module CSS 도 처리 (filter 확장 + 책임 일원화)

cssPlugin onLoad filter 를 `\.css$` 로 확장 → module CSS 도 cssPlugin 이 처리. dev-controller 의 PostCSS 단계 제거. CSS Modules scoping 은 cssPlugin onLoad 가 sequencing 책임 (sass → postcss → css-modules 가 한 onLoad 안에서).

**Pros**:
- Vite parity 완전 달성, dev/build 단일 처리자
- dev-controller `prepare()` 가 sass 컴파일만 담당 (역할 단순화)

**Cons**:
- cssPlugin 비대화 — sass/css-modules 의존성을 css/index.ts 로 이동 필요
- `mirrorPipelineCssToOutdir` / `injectAppDevPipelineCssLinks` 같은 dev-controller 특수 path 가 cssPlugin emit 결과로 대체돼야 — dev splitting=false 의 CSS asset 부재 문제 우회 메커니즘 필요
- sass `loadedUrls` 기반 `recordSassReverseDep` (#71) 가 plugin 경계 넘어 dev-controller state 와 통신해야 함
- 통합테스트 대규모 회귀 가능성 — sass dev fast-path, CSS Modules dev, postcss dev 전부 재검증

### B. dev-controller 가 cssPlugin 을 sequencing 안에서 호출

dev-controller `prepare()` 가 PostCSS 단계에서 cssPlugin 의 onLoad 핸들러를 직접 호출. cssPlugin 은 bundler chain 에서 dev mode 시 no-op (또는 marker 기반 skip). 단일 PostCSS pass.

**Pros**:
- dev-controller 의 sequencing invariant 유지 (sass → postcss → css-modules)
- cssPlugin 의 build-side 동작 변경 0

**Cons**:
- 결합도 폭증 — dev-controller 가 plugin 내부 (onLoad) 를 직접 호출, plugin 추상화 위반
- cssPlugin 이 두 가지 invocation context (bundler chain / dev-controller direct call) 모두 처리 → 분기 복잡도
- 사용자 override (`plugins: [css({...})]`) 시 두 곳 모두에서 옵션 적용 보장 어려움

### C. 2-pass 유지 + marker dedup

dev-controller 가 prepare 단계에서 처리한 `.css` 파일에 marker (예: 파일 끝 주석 `/* @zntc-postcss-done */` 또는 tempRoot 안 sibling `.zntc-processed` 파일) 추가. cssPlugin onLoad 가 marker 발견 시 PostCSS skip.

**Pros**:
- 최소 변경 — cssPlugin / dev-controller 양쪽 거의 그대로
- finding #2 해결, finding #3 (mode divergence) 도 자동 해소 (cssPlugin 이 skip 하므로)

**Cons**:
- marker 기반 dedup 은 fragile — 사용자 plugin 이 marker 제거 / 재기록 시 silent breakage
- 본질적으로 finding #2 의 ad-hoc 우회. 의미적으로 "두 처리자가 있으나 한 쪽이 skip" → PR-3b 의 dev path 자체가 사실상 dead code
- "Vite 식 dev/build 통일" 의도 실현 못함 — dev 는 여전히 dev-controller 가 사실상 단독 처리

### 옵션 비교

| | A. filter 확장 | B. dev-controller 직접 호출 | C. marker dedup |
|---|---|---|---|
| Vite parity | ✅ 완전 | 🟡 부분 | ❌ 없음 |
| 변경 범위 | XL (cssPlugin 재설계) | L (dev-controller + cssPlugin 양쪽) | S (양쪽 ad-hoc 1단계) |
| 통합테스트 회귀 | 큼 | 중 | 작음 |
| 결합도 | 낮음 (책임 일원화) | 높음 (plugin 내부 호출) | 중 (marker 규약) |
| finding #2 해결 | ✅ | ✅ | ✅ |
| finding #3 해결 | ✅ (단일 처리자) | 🟡 (caller 가 mode 통일) | ✅ (skip 으로 자동) |
| 미래 확장성 | ✅ (Vite plugin 호환 단계 진입) | 🟡 | ❌ (PR-3b 자체가 무효화) |

## 4. 권장 (잠정)

옵션 A (filter 확장 + cssPlugin 책임 일원화) 가 장기적으로 유일하게 정합적. **단** 변경 범위가 커서 단일 PR 불가능 — sub-PR 분해 필수:

1. **A-0**: 본 RFC 머지 + finding GitHub 이슈화 (이 PR)
2. **A-1**: cssPlugin filter 를 `\.css$` 로 확장 + module CSS 처리 추가 (build path 만 활성, dev path 는 dev-controller 가 여전히 1차)
3. **A-2**: cssPlugin onLoad 안에서 sass→postcss→css-modules sequencing — 통합테스트 가드 그대로 통과 확인
4. **A-3**: dev-controller `prepare()` 에서 PostCSS / css-modules 단계 제거, sass 만 유지 (cssPlugin 으로 위임)
5. **A-4**: runAppDev → runServe → buildBundleOptions cssPlugin wiring (= 원래 PR-3b 의 의도, 단 finding #1 까지 cover 한 형태)
6. **A-5**: finding #4 dedup (사용자 explicit `css()` 감지 시 default skip)

각 단계마다 통합테스트 + 회귀 가드. measure-first (CSS bundle size / dev cold-start 시간 대비 main).

## 5. 미해결 finding 의 별도 트래킹

- **#1 runBundle cssPlugin forward** (build path 영향 0, dev path 만) — A-4 와 함께 처리. 별도 이슈 불필요.
- **#3 NODE_ENV vs configEnv.mode divergence** — A 채택 시 단일 처리자라 자동 해소. C 채택 시 별도 이슈.
- **#4 no dedup when user explicit css()** — A-5 로 처리. 또는 본 RFC 와 무관한 hot-fix 로 즉시 가능 (PR-3a 부터 존재).

## 6. 결정 가이드

본 RFC 머지 전 다음 합의:
- 옵션 A/B/C 중 채택 안 (권장: A)
- A 채택 시 sub-PR 순서 + 각 PR 의 게이트 (회귀 size/통합테스트)
- finding #4 (dedup) 즉시 hot-fix 분리 여부

---

**Refs**: PR-3a fb2b04af · PR-3b (보류, push 안 됨) · Vite `resolvePlugins` (dist/node/chunks/dep-*) · ZNTC dev-controller `prepareAppCssPipelineRoot` 351-357
