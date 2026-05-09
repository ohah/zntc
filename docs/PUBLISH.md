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

순서: `core → web / react-native / vite-plugin-zntc / wasm / init` (server 는 private skip).

## 수동 publish (필요 시)

```bash
cd packages/core
bun publish      # prepublishOnly 가 자동 build + publint 검증
```

스크립트 우회. 단일 패키지 hotfix 등에 유용.

## 후속 release 자동화

`changesets` (https://github.com/changesets/changesets) 도입 시 version bump + changelog + sequential publish 가 한 번에. 현재는 release.ts 가 sequential publish + version bump 는 수동.

## 관련 PR

- publish-smoke (#2798), composite action (#2799)
- publint + types-first (#2801), publint --strict + .cjs (#2802)
- sherif + vite-plugin peer fix (#2810)
- publish-install (#2811)
- prepublishOnly + pre-release-check (이번 PR)
