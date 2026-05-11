# Release & Versioning Strategy

ZNTC monorepo 의 publish 정책. **무엇이 어떤 버전으로 올라가는가** 와 **언제 / 어떻게 올라가는가** 의 결정 기준.

절차 (명령 / hook / pre-release-check 등) 는 [PUBLISH.md](./PUBLISH.md) 참조. 이 문서는 **정책 only**.

## 1. Lockstep version (단일 trunk)

publishable main 패키지 **7개** 는 항상 **동일한 version** 으로 출시된다.

| 패키지 | 역할 |
|---|---|
| `@zntc/core` | NAPI binding + CLI + 트랜스파일 / 번들 / 트리쉐이크 / 코드젠 |
| `@zntc/web` | dev server + HMR + postcss/sass pipeline |
| `@zntc/vite-plugin` | Vite 의 esbuild transform 교체 |
| `@zntc/rspack-loader` | Rspack / Webpack loader |
| `@zntc/react-native` | RN preset + Metro 호환 dev server |
| `@zntc/init` | `npx @zntc/init` |
| `@zntc/wasm` | WASM 빌드 |

### 규칙
- 한 패키지만 patch 가 있어도 7개 전부 함께 bump.
- 예: `@zntc/web` 의 HMR 버그 fix 한 줄만 들어가도 `@zntc/core` / `@zntc/vite-plugin` / `@zntc/wasm` 까지 0.1.0 → 0.1.1 동일 bump.

### 근거
- **사용자 마찰 0.** `@zntc/core@0.2.0` 인데 `@zntc/web@0.1.x` 면 NAPI ABI / HMR protocol / option JSON 호환성 검증을 사용자가 짊어진다. lockstep 이면 "버전만 맞추면 끝" 보장.
- **NAPI ABI / HMR protocol 이 한 trunk 에서 진화.** core 의 transpile-options JSON schema 가 minor 마다 변하는데 web/RN 이 별 cadence 면 drift 가 침묵으로 깨진다.
- **changelog 한 곳에서 추적.** 사용자가 "0.2.0 에서 뭐 바뀌었지" 한 번에 본다.
- **단일 trunk 컨벤션.** Bun / Rolldown / Biome / Vite (v5 부터) 동일 방식. esbuild 처럼 단일 패키지인 경우는 자명하게 lockstep.

### 구현
`.changeset/config.json` 의 `fixed` 그룹으로 강제. 어느 패키지 대상 changeset 이 들어와도 그룹 전원이 동시 bump:

```jsonc
"fixed": [[
  "@zntc/core",
  "@zntc/web",
  "@zntc/vite-plugin",
  "@zntc/rspack-loader",
  "@zntc/react-native",
  "@zntc/init",
  "@zntc/wasm"
]]
```

`linked` (구버전 changesets 옵션) 가 아니라 `fixed` 사용 — `linked` 는 "올라가면 같이 올라가지만 시작 version 은 달라도 됨" 이고, `fixed` 는 "version 자체가 항상 동일" 강제.

### Platform sub-package (9개)

`@zntc/core-darwin-arm64` 등 NAPI binary sub-package 9종은 `fixed` 그룹에 **포함시키지 않는다**. 이유:

- `@zntc/core` 의 `optionalDependencies` 가 `"@zntc/core-darwin-arm64": "0.1.0"` 처럼 **hard-pin** → core 와 같은 version 으로 자동 강제됨
- changesets 가 sub-package 단위 changeset 을 받으면 노이즈만 늘어남 (platform 빌드는 사람이 결정하는 일 아님)
- 실제 동기화 책임: `release.yml` matrix 빌드 + `scripts/release.ts` 의 publish 순서 (platform 먼저 → core 마지막)

요약하면 platform sub-package 의 version 동기화는 **changesets 가 아닌 release pipeline** 이 보장한다.

### `@zntc/server` (private)

`private: true` 라 npm 발행 안 됨. web / RN 빌드 시 dist 에 inline. version 은 의미 없음 — 그래도 monorepo 일관성을 위해 main 그룹과 동일 version 유지 권장 (어차피 publish 안 되므로 자유).

## 2. semver 의미 — 무엇이 어느 bump 인가

### Major (1.0 이후 기준)

- `@zntc/core` JS API 시그니처 변경 — `transpile` / `build` / `buildSync` / `watch` / `init`
- `TranspileOptions` / `BuildOptions` 의 **기본값 변경** 또는 필드 제거
- CLI flag 제거 / 의미 변경 (alias 추가는 minor)
- plugin hook 시그니처 변경 — `resolveId` / `load` / `transform` / `renderChunk` / `generateBundle` / `buildStart` / `buildEnd` / `closeBundle`
- emit 결과 변경 중 **ECMAScript semantics 가 달라지는 경우** (예: TDZ 처리 / hoisting 순서 변경 → 사용자 코드 동작이 달라지면 major)
- error code 의 **의미 변경** (코드 추가는 minor, 코드 reuse 도 major)
- tsconfig `extends` / paths 해석 정책 변경
- 지원 매트릭스 상향 — Node / Bun / RN / Hermes 최소 version 올림
- workspace 패키지 분리 / 통합 / 이름 변경

### Minor

- 새 옵션 추가 (default 가 기존 동작 유지)
- 새 CLI flag, 새 환경변수, 새 dotenv prefix
- 새 error code 추가
- 새 platform 지원 (예: `linux-riscv64`, `android-arm64`)
- 새 plugin hook, 새 plugin API surface (`this.parse`, `this.emitFile` 추가 등)
- 새 transpile target / 새 jsx runtime / 새 ECMAScript proposal
- 기존 옵션의 새 enum value (예: `format: 'iife'` 추가)
- 1st-party transform 추가 (`compiler.styledComponents` 같은 새 키)

### Patch

- 버그 fix — 의도된 동작과 실제 동작의 gap 메움. **호환 사용자에게는 영향 0.**
- 성능 개선 — output byte-identical 또는 의미 동등
- 문서 / type stub / 메타데이터 / keywords 변경
- 에러 메시지 문구 개선 (code 는 동일)
- 의존성 patch bump (lightningcss / core-js 등)
- LICENSE / README 갱신

### Gray zone — output 변경이 patch 인가 minor 인가

원칙: **ES semantics 가 동일하면 patch, 변하면 major.**

| 시나리오 | bump |
|---|---|
| `2 + 2` → `4` 같은 정적 fold 추가 | patch (의미 동등) |
| dead code elim 강화 — 더 많이 제거 | patch (side-effect 없는 경우만; 있으면 major) |
| `__esm` wrapper 의 변수명 변경 | patch (외부 식별자 변화 없음) |
| dynamic import 호출 형태 변경 — `Promise.resolve().then(...)` → `await Promise.resolve()` | minor (사용자 sourcemap / debug stack 영향) |
| sourcemap mapping 알고리즘 변경 (정확도 향상) | minor |
| top-level `var` 가 `let` 으로 출력 | major (TDZ / hoisting / `typeof` 동작 변화) |

판단 어려우면 **상향 분류** — 사용자가 안 깨졌는데 minor 였던 게 patch 였던 것보다 낫다.

## 3. 0.x 단계 정책 (현재)

ZNTC 는 현재 **0.1.0 (public preview)** — 1.0 stable 진입 전까지 다음 관례:

- **`0.x → 0.(x+1)`** 에 breaking 허용. npm/semver 0.x 관례 그대로.
  - 예: `0.1.0` → `0.2.0` 시 plugin API 시그니처를 갈아엎어도 됨
  - 단 changelog 의 breaking 섹션 + 마이그레이션 가이드 link 의무
- **`0.x.y` → `0.x.z`** 는 항상 호환 (patch only). 사용자가 `^0.1.0` 으로 깔아둔 게 자동으로 깨지면 안 됨.

### 1.0 진입 조건 (목표)

- Test262 / npm 144 스모크 / RN 0.74 회귀 안정
- 핵심 API 표면 (`@zntc/core` 의 JS API, plugin hook, CLI flag) 6개월 이상 churn 없음
- 외부 production 사용자 ≥ 1 (자체 dogfooding 외)
- 1.0 차단 항목은 GitHub milestone `1.0` 로 추적

1.0 이후로는 일반 semver 엄격 적용 (breaking = major 만).

## 4. Release cadence

- **Patch (`0.1.x`)** — 누적 changeset 1개 이상이면 임의 시점 release 가능. 보통 **1–2 주 batch** 권장
- **Minor (`0.x → 0.y`)** — 한 달 또는 누적 breaking changeset 이 차면. 사전 **RC 1 주 cycle** 권장 (`0.2.0-rc.1` → 검증 → `0.2.0`)
- **Hotfix** — 보안 / 데이터 손실 / 빌드 broken 류만 immediate. main 에서 cut, **release branch 안 만듦** (single-trunk 유지)

batch release 가 default. "PR 머지 = 자동 publish" 같은 continuous release 는 안 함 (단 canary 채널 예외, §5).

## 5. Pre-release channels (`npm dist-tag`)

| dist-tag | 의미 | 누가 / 언제 |
|---|---|---|
| `latest` | stable release | release.ts 기본값. `0.1.0`, `0.1.1`, ... |
| `next` | 다음 minor 의 RC | release.ts `--tag next`. `0.2.0-rc.1` 같은 형태 |
| `canary` | main 의 매 commit 자동 publish | 별도 `release-canary.yml` workflow (미구현) |

채널 변경: `npm dist-tag add @zntc/core@0.2.0 latest` — release.ts 가 RC → stable 승격 시 사용.

사용자 install:
```bash
bun add -D @zntc/core@next   # RC 받기
bun add -D @zntc/core@canary # 매일 빌드 받기
```

## 6. Breaking change 절차

1. **Changeset 의무** — `### Breaking` 섹션 명시. 마이그레이션 한 줄 + 자세한 link.
2. **마이그레이션 가이드** — `documents/src/content/docs/guides/migration.md` 에 누적. 1.0 진입 시 통합 정리.
3. **Deprecation period** — 가능하면 한 minor 동안 console.warn 또는 `@deprecated` JSDoc 으로 사전 공지. 그 다음 minor 에 제거.
4. **GitHub Release notes** — 상단에 ⚠️ Breaking changes 섹션 + 영향 패키지 목록.
5. **공지 채널** — repo Discussions 또는 README 의 status 섹션 업데이트.

deprecation 이 의미 없는 경우 (예: 보안 hotfix 로 인한 API 제거) 는 곧바로 제거 가능 — 단 명확히 표기.

## 7. Provenance / 보안

- **npm provenance** — `npm publish --provenance` (OIDC 기반, GitHub Actions 가 publish 실행 시 자동). 사용자가 npm 페이지에서 빌드 출처 검증 가능.
- **2FA** — `@zntc/*` scope 의 모든 publish 에 2FA 필수. maintainer 추가 시 동일.
- **Token 관리** — `NPM_TOKEN` 은 GHA repository secret. 로컬 publish 는 `npm login` 으로 — token 평문 저장 / 공유 금지.
- **SECURITY.md** — 1.0 전까지 작성 예정. 보안 보고 채널 + embargo 정책.

## 8. 머지 정책

- **`main` 직접 push 금지** (`branch protection` 으로 강제 권장)
- **PR → rebase merge → branch 자동 삭제**:
  ```bash
  gh pr merge <num> --rebase --auto --delete-branch
  ```
- **squash / merge commit 금지** — history 1직선 유지 (bisect / log 분석 비용 낮춤)
- **force push to main 금지** — 절대

## 9. 의사결정 / 책임

| 결정 | 0.x 단계 | 1.0 이후 |
|---|---|---|
| Patch release 시점 | repo owner 단독 | 동일 |
| Minor release 시점 | repo owner 단독 + Discussions 공지 | RFC 1주 + 머지 |
| Breaking 도입 (minor → 다음 minor) | repo owner 단독 + changelog | RFC issue 1 주 공개 |
| 보안 hotfix | SECURITY.md 절차 (미작성) | 동일 |
| Public API 변경 | discussions 권장 | RFC 의무 |

`ohah` = current sole maintainer. 추가 maintainer 가 생기면 `MAINTAINERS.md` 로 분리.

## 10. 관련 문서

- [PUBLISH.md](./PUBLISH.md) — release 실행 절차 (명령 / hook / pre-release-check)
- [ROADMAP.md](./ROADMAP.md) — 1.0 차단 항목 / Phase 현황
- [DECISIONS.md](./DECISIONS.md) — API / 아키텍처 의사결정 누적
- [CLAUDE.md](../CLAUDE.md) — PR / commit / 머지 컨벤션
- [INVARIANTS.md](./INVARIANTS.md) — release 와 무관하게 항상 지켜야 할 invariant
