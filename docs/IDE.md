# IDE setup

ZNTC monorepo 를 IDE 에서 효과적으로 다루기 위한 권장 설정.

## TypeScript Project References (root `tsconfig.json`)

PR #2805 ~ #2808 에서 도입. 7 publishable workspace package 를 단일 TS program 으로 묶음:

- `packages/{core,server,web,react-native,vite-plugin-zntc,init,wasm}/tsconfig.json` 가 `composite: true`
- root `/tsconfig.json` (solution-style) 이 모두 `references` 로 묶음
- 각 package 가 독립 `tsBuildInfoFile` (`<pkg>/.tsbuildinfo`)

이 구조에서 IDE 가 자동으로 root tsconfig 를 발견하면:
- 모든 패키지를 단일 program 으로 인식
- cross-package go-to-definition / find-references / rename 정확
- `.d.ts` rebuild 없이 `src` 직접 navigate (composite 의 incremental 추적)

### VSCode

특별한 설정 없이 root tsconfig.json 을 자동 발견. 최적화:

```jsonc
// .vscode/settings.json
{
  "typescript.tsdk": "node_modules/typescript/lib",
  "typescript.tsserver.experimental.enableProjectDiagnostics": true,
  // Project References 사용 시 빠른 type-check
  "typescript.referencesCodeLens.enabled": true
}
```

레포 root 의 `.vscode/settings.json` 을 commit 하면 contributor 모두 동일.

### JetBrains (WebStorm / IntelliJ)

- **Settings → Languages & Frameworks → TypeScript → TypeScript language service**: enabled
- **TypeScript LSP service**: 4.0+ 권장 (Project References 정확)
- root `tsconfig.json` 을 default 로 인식

### Neovim / Helix (typescript-language-server / tsgo)

- `typescript-language-server` 0.7+ 가 Project References 인식
- root `tsconfig.json` 을 lspconfig root pattern 에 추가:

```lua
-- lazy.nvim 예시
require("lspconfig").ts_ls.setup({
  root_dir = require("lspconfig.util").root_pattern("tsconfig.json", "package.json"),
})
```

#### tsgo (실험적)

VSCode 의 `typescript.tsserver.experimental.useTsgo: true` 옵션은 Go 로 재작성된 차세대 tsserver. composite + references 와 호환되며 cold start 가 ~3x 빠름. 단 일부 quick-fix / refactor 가 미구현 — 적극 사용은 stable 후.

## 빠른 명령

| 명령 | 효과 |
|---|---|
| `bun run build:dts:all` | 전체 monorepo `.d.ts` 토폴로지 빌드 (`tsc -b`) |
| `bun run type-check` | 변경 없이 status check (`tsc -b --dry`) |
| `bun run --cwd packages/X build:dts` | 단일 package + 의존 references 만 빌드 |

incremental cache (`<pkg>/.tsbuildinfo`) 가 활성화되어 있어 두 번째 호출부터 ~50ms.

## 관련 PR

- TS Project References Phase 1 (#2805): server/core composite
- Phase 2 (#2806): consumer references
- Phase 3 (#2807): root solution-style + npm scripts
- Phase 4 (#2808): init/wasm 합류
