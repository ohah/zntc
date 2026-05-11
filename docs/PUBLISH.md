# Publishing

ZNTC monorepo 의 publish 절차 + 자동 검증 chain.

## 검증 인프라

publish 안전을 위한 5 layer (CI publish-smoke job 에서도 모두 실행):

| Layer | 명령 | 검증 항목 |
|---|---|---|
| **Build** | `bun run build:publishable` | 모든 publishable 패키지 dist 생성 |
| **publish-smoke** | `bun run test:publish-smoke` | tarball layout / files / metadata / private dep leak / sensitive 파일 누수 |
| **publint** | `bun run test:publint` | npm 표준 모범 사례 (exports order / file extension 정합성 등) |
| **sherif** | `bun run test:sherif` | workspace metadata 일관성 (license / packageManager / types-in-deps) |
| **publish-install** | `bun run test:publish-install` | 실제 `npm install <tarball>` + dynamic ESM import |

## 단일 명령: pre-release-check

publish 직전 위 5 layer 를 한 번에:

```bash
bun run pre-release-check
```

통과해야 publish 시도 권장.

## 자동 안전망: prepublishOnly

각 publishable 패키지의 `package.json` 에 `prepublishOnly` 가 등록되어 있어, 실수로 검증 안 한 채 `npm publish` / `bun publish` 호출해도 npm/bun 이 자동으로:

```jsonc
"prepublishOnly": "bun run build && bunx publint --strict --level error ."
```

→ build + publint 가 통과해야 실제 publish 진행. 실패 시 publish 중단.

이 hook 은 **publish 명령을 명시 호출했을 때만** 실행 — `bun install` / `bun run dev` 등에는 영향 0.

## 권장 publish 절차 — `bun run release`

`scripts/release.ts` 가 토폴로지 순서로 publish + 안전 가드를 모두 처리:

```bash
# 1. dry-run (실제 publish 안 함 — 변경 없음)
bun run release:dry-run
# → pre-release-check 실행 + 패키지 목록 + npm registry 가용성 표시

# 2. 실제 publish — confirm prompt 거쳐서만 진행
bun run release:publish
# → 위 1번 + "yes" 입력 후에만 sequential publish
# → 이미 registry 에 같은 version 이 있으면 그 패키지는 자동 skip (idempotent)
```

옵션:
- `--tag <name>`: dist-tag (예: `next` / `beta`) 명시
- `--access public`: 자동 (scoped package 의 default)

순서: platform sub-package 9개 (`@zntc/core-{darwin,linux,win32}-{x64,arm64,...}` — main 의 optionalDependencies 가 reference 하므로 먼저) → `core` → `web` → `react-native` → `@zntc/vite-plugin` → `@zntc/rspack-loader` → `wasm` → `init` (server 는 private skip). 정확한 순서는 `scripts/release.ts` 의 `PUBLISH_ORDER` 가 single source of truth.

## 수동 publish (필요 시)

```bash
cd packages/core
bun publish      # prepublishOnly 가 자동 build + publint 검증
```

스크립트 우회. 단일 패키지 hotfix 등에 유용.

## Changesets — version bump + changelog 자동화

`@changesets/cli` 도입. PR 단위로 변경 의도를 markdown 으로 기록 → release 시 일괄 version bump + CHANGELOG.md 자동 생성.

> `release.ts` 와 역할 분리: **changesets = version bump + changelog**, **release.ts = pre-release-check + sequential publish**. `changeset publish` 는 사용 안 함 (release.ts 가 더 다중 가드).

### 일상 워크플로

```bash
# 1. PR 작성 중 — 변경 의도 기록
bun run changeset
#   → 변경된 패키지 선택 (space)
#   → bump 종류 선택 (patch / minor / major)
#   → 변경 사유 입력
#   → .changeset/<random-name>.md 생성됨 → commit
```

### Release 시점

```bash
# 2. main 에 누적된 .changeset/*.md 적용 (로컬 / release PR 전용)
bun run changeset:version
#   → 각 패키지 package.json version bump
#   → CHANGELOG.md 생성/업데이트
#   → workspace internal deps 자동 sync (^X.Y.Z)
#   → bun install 자동 실행 (--no-frozen-lockfile, lockfile 갱신)
#   → 결과 git diff 확인 후 commit + PR

# 3. version bump PR 머지 후 — 실제 publish
bun run release:publish
#   → release.ts 가 pre-release-check + confirm + sequential publish
```

> `changeset:version` 은 lockfile 갱신 위해 `--no-frozen-lockfile` 사용. **로컬 또는 release PR 작업 환경 전용** — CI 의 일반 install (`bun install --frozen-lockfile`) 과 충돌하지 않음 (CI 는 이 script 호출 안 함).

### 빠른 확인

```bash
bun run changeset:status   # 누적된 changeset 보기 (어느 패키지가 어떤 bump)
```

### 설정

- `.changeset/config.json`:
  - `access: "public"` — scoped `@zntc/*` 와 unscoped `@zntc/vite-plugin` 모두 public publish (default 가 모든 package 에 적용)
  - `ignore: ["documents"]` — `documents` 는 publishable name 인데 publish 의도 없음. private 인 server / examples / tests 는 `private: true` 로 자동 skip
  - `baseBranch: "main"`
  - `fixed`: main 패키지 7개 (`@zntc/core` / `web` / `vite-plugin` / `rspack-loader` / `react-native` / `init` / `wasm`) 를 한 그룹으로 묶어 **lockstep version** 강제. 어느 패키지 changeset 이 와도 7개 모두 같은 version 으로 bump. 정책 / 근거는 [RELEASE_STRATEGY.md](./RELEASE_STRATEGY.md) 참조
- changesets 의 bump 대상 = release.ts 의 publish 대상 = `packages/*` 중 non-private 7개 (core / web / react-native / @zntc/vite-plugin / @zntc/rspack-loader / wasm / init) + platform sub-package 9개. 불일치 시 release.ts `PUBLISH_ORDER` 도 동기화 필요. platform sub-package 는 `fixed` 에 안 들어가도 core 의 `optionalDependencies` hard-pin 으로 자동 동기화

## 관련 PR

- publish-smoke (#2798), composite action (#2799)
- publint + types-first (#2801), publint --strict + .cjs (#2802)
- sherif + vite-plugin peer fix (#2810)
- publish-install (#2811)
- prepublishOnly + pre-release-check (이번 PR)
