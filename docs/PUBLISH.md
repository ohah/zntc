# Publishing

ZNTC monorepo 를 npm 에 올리는 **절차**. version / breaking 정책 (무엇이 어느 bump 인지, lockstep 이유 등) 은 [RELEASE_STRATEGY.md](./RELEASE_STRATEGY.md) 참조 — 이 문서는 **how**, 그쪽이 **what / why**.

## TL;DR — 한 번 release 하려면

```bash
# 0. (각 PR 에 changeset 이 들어있어야 함 — 아래 §5)

# 1. 누적 changeset 적용 → version bump + CHANGELOG. "Release vX.Y.Z" PR 생성·머지
bun run changeset:version
git add -A && git commit -m "chore: release vX.Y.Z" && gh pr create ... && gh pr merge --rebase ...

# 2. main 에서 tag push → GitHub Actions (release.yml) 가 빌드 + publish 전부
git checkout main && git pull
git tag vX.Y.Z
git push origin vX.Y.Z
```

`v*` 태그가 push 되면 `release.yml` 이 9개 platform NAPI/CLI 빌드 + `release.ts --publish` + GitHub Release 까지 자동. 사람이 직접 `npm publish` 칠 일은 hotfix fallback (§7) 뿐.

> **첫 `0.1.0` publish** 는 changeset 없이 진행 — version 이 이미 `0.1.0` 이므로 §1 (`changeset:version`) 을 건너뛰고 바로 `git tag v0.1.0 && git push origin v0.1.0`. CHANGELOG.md 는 다음 patch 부터 changesets 가 자동 생성.

---

## 1. 검증 인프라 — pre-release-check

publish 안전을 위한 5 layer. `release.ts` 가 publish 전 자동 실행하고, CI 의 publish-smoke job 에서도 모두 돈다:

| Layer | 명령 | 검증 항목 |
|---|---|---|
| **Build** | `bun run build:publishable` | 모든 publishable 패키지 dist 생성 |
| **publish-smoke** | `bun run test:publish-smoke` | tarball layout / files / metadata / private dep leak / sensitive 파일 누수 |
| **publint** | `bun run test:publint` | npm 표준 모범 사례 (exports order / file extension 정합성 등) |
| **sherif** | `bun run test:sherif` | workspace metadata 일관성 (license / packageManager / types-in-deps) |
| **publishable-deps** | `bun run test:publishable-deps` | publishable 패키지가 private workspace 패키지에 런타임 의존하지 않는지 |
| **publish-install** | `bun run test:publish-install` | 실제 `npm install <tarball>` + dynamic ESM import |

한 번에:

```bash
bun run pre-release-check    # 위 전부 — 통과해야 publish 권장
```

### 자동 안전망: prepublishOnly

각 publishable `package.json` 에 등록되어 있어, 검증 안 한 채 `npm publish` / `bun publish` 를 직접 쳐도 npm/bun 이 자동으로 막는다:

```jsonc
"prepublishOnly": "bun run build && bunx publint --strict --level error ."
```

build + publint 통과 못 하면 publish 중단. **publish 명령을 명시 호출했을 때만** 실행 — `bun install` / `bun run dev` 등에는 영향 0.

platform sub-package (`@zntc/core-*`) 의 prepublishOnly 는 다름 — `node ../../scripts/check-platform-binary.mjs` 로 `zntc.node` 가 비어있지 않은 정상 binary 인지 검증. 빈 placeholder publish 차단.

---

## 2. GitHub Actions 자동 release (`.github/workflows/release.yml`)

**트리거**: `git push` 의 `v*` 태그 (`v0.1.0`, `v0.2.0-rc.1`, ...).

### Job 흐름

```
build-napi (9 platform 매트릭스)          build-cli (9 target 매트릭스)
  zig build napi -Dtarget=...               zig build -Dtarget=...
  → zntc.node artifact 업로드                → zig-out/bin/ artifact 업로드
        │                                          │
        ▼                                          │
  publish-npm  ← needs: build-napi                 │
    1. NAPI artifact 9개 다운로드                    │
    2. packages/core-<platform>/zntc.node 에 분배   │
    3. packages/core/zntc.node 에도 배치             │
       (main 의 prepublishOnly self-host 빌드용 —   │
        publish 산출물엔 안 들어감)                  │
    4. tag 에서 dist-tag 자동 감지                   │
       v0.1.0 → latest / v0.2.0-rc.1 → rc          │
    5. bun scripts/release.ts --publish --yes \     │
         --tag <dist-tag>                           │
        │                                          │
        └──────────────┬───────────────────────────┘
                       ▼
              github-release  ← needs: [build-cli, publish-npm]
                CLI binary 9종을 .tar.gz 로 묶어 GitHub Release 에 첨부
                + auto-generated release notes
```

### dist-tag 자동 감지

태그 이름에서 prerelease identifier 를 추출:

| 태그 | dist-tag |
|---|---|
| `v0.1.0` | `latest` |
| `v0.2.0-rc.1` | `rc` |
| `v0.2.0-beta.3` | `beta` |
| `v0.3.0-next.5` | `next` |

`release.ts --tag <name>` 으로 전달됨.

### 인증 — NPM_TOKEN → OIDC

- **현재**: `secrets.NPM_TOKEN` 으로 publish. workflow 는 `id-token: write` 권한도 이미 켜둠 (OIDC 준비).
- **향후**: npm 의 trusted publisher 에 이 repo + workflow 등록 → `NPM_TOKEN` secret 삭제 → OIDC 만으로 publish + `--provenance` 자동 부착. 사용자가 npm 페이지에서 빌드 출처 검증 가능.

### 부분 실패

`fail-fast: false` — 9개 platform 중 하나 (예: `windows-11-arm` preview runner flaky) 가 실패해도 나머지 8개는 완주. 단 `publish-npm` 은 `needs: build-napi` 전체 성공을 요구하므로, 한 platform 이 깨지면 publish 자체는 안 됨 → 그 platform 만 재실행 (`Re-run failed jobs`).

---

## 3. End-to-end 절차 (자동 경로)

```bash
# ── ① 기능 PR 들 (각각 changeset 포함) 머지 ──
# (PR 작성 시 `bun run changeset` 으로 .changeset/*.md 동봉 — §5)

# ── ② version bump PR ──
git checkout main && git pull
bun run changeset:version
#   → 누적 .changeset/*.md 소비
#   → main 7개 패키지 package.json version 동시 bump (lockstep — fixed 그룹)
#   → 각 패키지 CHANGELOG.md 생성/갱신
#   → workspace internal deps 자동 sync
#   → bun install (--no-frozen-lockfile) 으로 lockfile 갱신
git switch -c chore/release-vX.Y.Z
git add -A && git commit -m "chore: release vX.Y.Z"
git push -u origin chore/release-vX.Y.Z
gh pr create --title "chore: release vX.Y.Z" --label "documentation" --assignee "ohah" --body "..."
gh pr merge <num> --rebase --auto --delete-branch

# ── ③ tag push → release.yml 자동 실행 ──
git checkout main && git pull
git tag vX.Y.Z
git push origin vX.Y.Z
#   → release.yml: build-napi(9) + build-cli(9) + publish-npm + github-release
#   → npm 에 7개 main + 9개 platform sub-package 출시, GitHub Release 생성

# ── ④ 확인 ──
npm view @zntc/core version            # 새 version 떴는지
npm view @zntc/core dist-tags          # latest 가 새 version 가리키는지
gh release view vX.Y.Z                 # CLI tarball 9종 첨부됐는지
```

### Prerelease (RC) 경로

```bash
# version 을 prerelease 모드로 bump
bun run changeset pre enter rc          # .changeset/pre.json 생성
bun run changeset:version               # X.Y.Z-rc.0
# ... PR 머지 ...
git tag vX.Y.Z-rc.0 && git push origin vX.Y.Z-rc.0
#   → release.yml 이 dist-tag 'rc' 로 publish (latest 안 건드림)

# RC 검증 끝나면 stable 로
bun run changeset pre exit
bun run changeset:version               # X.Y.Z
git tag vX.Y.Z && git push origin vX.Y.Z
#   → 'latest' 로 publish
```

`rc.0` → `rc.1` 추가 changeset 으로 반복. 채널 정책은 [RELEASE_STRATEGY.md §5](./RELEASE_STRATEGY.md).

---

## 4. `scripts/release.ts` — publish 엔진

`release.yml` 이 내부적으로 호출하는 스크립트. 로컬 수동 publish (§7) 에도 동일하게 쓰임.

```bash
bun run release:dry-run     # = release.ts            (변경 없음)
bun run release:publish     # = release.ts --publish  (confirm 후 실제 publish)
```

동작:
1. `pre-release-check` 강제 실행 — 실패 시 중단
2. publishable 패키지 목록 + 각각의 npm registry 가용성 표시 (🟢 available / 🟡 taken / ⚪ unknown)
3. dry-run 이면 여기서 종료
4. publish 모드면 `'yes'` confirm (CI 는 `--yes` 로 우회)
5. platform sub-package 의 `zntc.node` 무결성 재검증 (defense-in-depth)
6. **토폴로지 순서**로 sequential `bun publish --access public [--tag <name>]`

### publish 순서 (`PUBLISH_ORDER`)

```
platform sub-package 9개 (@zntc/core-{linux,darwin,win32}-*)   ← main 의 optionalDependencies 가 reference, 먼저
  → @zntc/core
  → @zntc/web
  → @zntc/react-native
  → @zntc/vite-plugin
  → @zntc/rspack-loader
  → @zntc/wasm
  → @zntc/init
```

`@zntc/server` 는 `private: true` 라 자동 skip. 정확한 순서는 `scripts/release.ts` 의 `PUBLISH_ORDER` 가 single source of truth — changesets 의 bump 대상 / `release.yml` 매트릭스와 어긋나면 안 됨.

### idempotent

registry 에 이미 같은 version 이 있는 패키지는 자동 skip. publish 중간에 실패 후 재실행해도 안전 (§6).

---

## 5. Changesets — version bump + changelog

`@changesets/cli`. PR 단위로 변경 의도를 markdown 으로 기록 → release 시 일괄 version bump + CHANGELOG.md 자동 생성.

> 역할 분리: **changesets = version bump + changelog**, **release.ts = pre-release-check + sequential publish**. `changeset publish` 는 사용 안 함 (release.ts 가 가드가 더 많음).

### PR 작성 중 — 변경 의도 기록

```bash
bun run changeset
#   → 변경된 패키지 선택 (space)  ※ lockstep 이라 1개만 골라도 fixed 그룹 7개 전부 bump
#   → bump 종류 (patch / minor / major)
#   → 변경 사유 입력 → .changeset/<random>.md 생성 → commit
```

breaking 이 있으면 changeset 본문에 `### Breaking` 섹션 + 마이그레이션 한 줄 필수 ([RELEASE_STRATEGY.md §6](./RELEASE_STRATEGY.md)).

### Release 시점 — version 적용

```bash
bun run changeset:version
#   → 각 패키지 package.json version bump (lockstep)
#   → CHANGELOG.md 생성/업데이트
#   → workspace internal deps 자동 sync (^X.Y.Z)
#   → bun install (--no-frozen-lockfile) — lockfile 갱신
#   → git diff 확인 후 commit + "Release vX.Y.Z" PR
```

> `changeset:version` 은 lockfile 갱신 위해 `--no-frozen-lockfile`. **로컬 / release PR 작업 환경 전용** — CI 의 일반 install (`--frozen-lockfile`) 과 충돌하지 않음 (CI 는 이 script 호출 안 함).

### 빠른 확인

```bash
bun run changeset:status   # 누적 changeset — 어느 패키지가 어떤 bump 인지
```

### `.changeset/config.json`

- `access: "public"` — `@zntc/*` 와 unscoped `@zntc/vite-plugin` 모두 public publish
- `ignore: ["documents"]` — `documents` 는 publishable name 인데 publish 의도 없음. private 인 server / examples / tests 는 `private: true` 로 자동 skip
- `baseBranch: "main"`
- `fixed`: main 7개 (`@zntc/core` / `web` / `vite-plugin` / `rspack-loader` / `react-native` / `init` / `wasm`) 를 한 그룹으로 묶어 **lockstep version** 강제. 어느 패키지 changeset 이 와도 7개 전부 같은 version. platform sub-package 9개는 `fixed` 에 안 들어가도 core 의 `optionalDependencies` hard-pin 으로 자동 동기화. 근거는 [RELEASE_STRATEGY.md §1](./RELEASE_STRATEGY.md)

---

## 6. 실패 / 롤백

### release.yml 중간 실패

- **build-napi 한 platform 실패** → 그 platform job 만 `Re-run failed jobs`. 다른 8개 artifact 는 보존 (retention 1일).
- **publish-npm 중간 실패** (예: 3번째 패키지에서 네트워크 끊김) → 앞 패키지는 이미 npm 에 올라간 상태. workflow 재실행 시 `release.ts` 가 registry 가용성 확인 → 이미 올라간 건 자동 skip, 안 올라간 것만 publish. **idempotent.**
- **태그는 그대로** — 같은 태그 push 는 안 되므로, 재실행은 GitHub UI 의 `Re-run jobs` 로.

### 잘못 publish 했을 때

- **npm unpublish 는 사실상 불가** — publish 후 72h 이내 + dependents 없을 때만, 그것도 정책상 강하게 비추천. 대신 `npm deprecate @zntc/core@X.Y.Z "사유"` 로 표시하고 patch 를 새로 올린다.
- **dist-tag 잘못 가리킴** (예: RC 가 `latest` 됨) → `npm dist-tag add @zntc/core@<good-version> latest` 로 정정. 7개 패키지 각각.
- **일부 패키지만 올라가고 나머지 실패** → 나머지를 같은 version 으로 마저 올린다 (`release.ts` 재실행 또는 §7 수동). lockstep 이 깨진 채로 두지 말 것.

### CHANGELOG / version 잘못

`changeset:version` 결과를 PR 머지 **전**에 잡는 게 최선. 머지 후 발견하면 그 자체로 또 patch — `chore: fix vX.Y.Z changelog` PR.

---

## 7. 수동 publish (hotfix fallback)

release.yml 우회. CI 가 막혔거나 단일 패키지 hotfix 일 때만.

```bash
# 전체 — 로컬에 platform binary 가 채워져 있어야 함 (보통 안 됨 → 비추천)
bun run release:publish

# 단일 패키지 — prepublishOnly 가 자동 build + publint
cd packages/web
bun publish --access public
```

> 수동 전체 publish 는 9개 platform binary 를 로컬에서 cross-compile 해 `packages/core-*/zntc.node` 에 채워야 한다 (`release.yml` 의 build-napi 매트릭스가 하는 일). 단일 머신에서 전 platform cross-compile 은 번거로우니, 전체 release 는 항상 태그 push → release.yml 경로를 쓴다. 수동은 platform binary 가 필요 없는 단일 JS 패키지 hotfix 정도에만.

lockstep 정책상 단일 패키지만 올리는 건 예외 상황 — 올렸으면 곧바로 나머지 6개도 같은 version 으로 맞춰야 한다.

---

## 8. Release 직전 체크리스트

- [ ] `bun run pre-release-check` 통과 (또는 `release:dry-run` 으로 확인)
- [ ] 누적 changeset 검토 — `bun run changeset:status` 의 bump 종류가 의도와 일치 (특히 minor/major 혼입 여부)
- [ ] `changeset:version` 결과 diff 검토 — 7개 패키지 version 이 **모두 동일** (lockstep 깨지지 않음), CHANGELOG.md 의 breaking 섹션 정확
- [ ] `main` 이 머지 완료 상태 + 로컬 `git pull` 으로 최신
- [ ] 태그 이름이 `package.json` version 과 일치 (`v0.1.1` ↔ `0.1.1`), prerelease 면 identifier 형식 (`v0.2.0-rc.1`)
- [ ] (prerelease 면) `latest` 를 안 건드리는지 — dist-tag 자동 감지가 `rc`/`beta`/`next` 로 잡히는지
- [ ] release.yml 완료 후 `npm view @zntc/core dist-tags` + `gh release view <tag>` 로 결과 확인

---

## 관련 PR

- publish-smoke (#2798), composite action (#2799)
- publint + types-first (#2801), publint --strict + .cjs (#2802)
- sherif + vite-plugin peer fix (#2810)
- publish-install (#2811)
- prepublishOnly + pre-release-check, 패키지 메타데이터 정비 (#3058)
- lockstep `fixed` 그룹 + RELEASE_STRATEGY.md (#3060)
