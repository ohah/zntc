---
title: 라이브러리 빌드
description: tsup / tsdown / bunup 처럼 ZNTC 로 npm 패키지(라이브러리)를 빌드하는 방법입니다.
---

ZNTC 는 앱·웹서버 번들링뿐 아니라 **배포용 npm 패키지(라이브러리) 빌드**에도 쓸 수 있습니다. `tsup` / `tsdown` / `bunup` 이 하는 일 — entry 번들링, ESM/CJS 출력, 의존성 external, sourcemap, minify, watch — 을 동일하게 수행합니다.

> **타입 선언(`.d.ts`)**: ZNTC 는 현재 `.d.ts` emit 을 지원하지 않습니다 ([로드맵](/zntc/guides/introduction/) 기준 `tsc` 위임). 아래 레시피는 `tsc --emitDeclarationOnly` 를 병행하는 표준 구성을 씁니다.

## 프로젝트 구조

```text
my-lib/
├── package.json           # exports/main/module/types + build 스크립트
├── tsconfig.json          # declaration: true, emitDeclarationOnly 로 .d.ts 만
├── zntc.config.ts         # 라이브러리 빌드 설정 (선택 — CLI 만으로도 가능)
└── src/
    └── index.ts           # 패키지 entry
```

## 빌드 설정

라이브러리 빌드의 핵심은 **의존성을 번들에 넣지 않는 것**(external)과 **소비자가 고를 수 있는 포맷 출력**입니다.

```ts
// zntc.config.ts
import { defineConfig } from "@zntc/core";

export default defineConfig({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  format: "esm",
  // neutral: Node/브라우저 가정 없이 — 라이브러리 기본 권장.
  // Node 전용이면 platform: "node".
  platform: "neutral",
  // 모든 bare import(react, lodash 등)를 external 처리 — node_modules 를
  // 번들에 넣지 않는다. esbuild `--packages=external` 와 동일.
  packagesExternal: true,
  target: "es2022",
  sourcemap: true,
  minify: true,
});
```

`clean`(출력 디렉터리 비우기)은 CLI 전용 플래그(`--clean`)입니다 — config 키가 아니므로 아래 CLI 예시에서 사용합니다.

CLI 만으로도 동일하게:

```bash
zntc --bundle src/index.ts --outdir dist \
  --format=esm --platform=neutral --packages=external \
  --target=es2022 --sourcemap --minify --clean
```

## ESM + CJS 동시 출력

한 번의 `build()` / `zntc build` 는 **한 포맷만** 냅니다. 듀얼 포맷은 빌드를 두 번 실행합니다.

`package.json` 스크립트로:

```jsonc
{
  "scripts": {
    "build:esm": "zntc --bundle src/index.ts --outdir dist --out-extension:.js=.mjs --format=esm --platform=neutral --packages=external --sourcemap --minify",
    "build:cjs": "zntc --bundle src/index.ts --outdir dist --out-extension:.js=.cjs --format=cjs --platform=neutral --packages=external --sourcemap --minify",
    "build:types": "tsc --emitDeclarationOnly --declaration --outDir dist",
    "build": "zntc --bundle src/index.ts --outdir dist --clean --format=esm && bun run build:cjs && bun run build:types"
  }
}
```

JS API 로 한 스크립트에서 두 포맷 + 타입을 묶으려면:

```ts
// scripts/build.ts
import { build } from "@zntc/core";
import { execFileSync } from "node:child_process";

const common = {
  entryPoints: ["src/index.ts"],
  platform: "neutral" as const,
  packagesExternal: true,
  sourcemap: true,
  minify: true,
};

await build({ ...common, format: "esm", outdir: "dist", outExtension: ".mjs" });
await build({ ...common, format: "cjs", outdir: "dist", outExtension: ".cjs" });

// 타입 선언은 tsc 에 위임 (ZNTC 는 .d.ts emit 미지원).
execFileSync("tsc", ["--emitDeclarationOnly", "--declaration", "--outDir", "dist"], {
  stdio: "inherit",
});
```

```bash
zntc src/build.ts --platform=node && node dist/build.js   # 빌드 스크립트 자체도 ZNTC 로
# 또는 bun run scripts/build.ts
```

## tsconfig (타입 선언 전용)

```jsonc
{
  "compilerOptions": {
    "declaration": true,
    "emitDeclarationOnly": true,
    "outDir": "dist",
    "moduleResolution": "Bundler",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

`tsc` 는 `.d.ts` 만, ZNTC 는 `.js`(.mjs/.cjs) + sourcemap 만 — 역할이 겹치지 않습니다.

## package.json 필드 권장

소비자가 ESM/CJS/타입을 올바르게 해석하도록 `exports` 를 명시합니다.

```jsonc
{
  "name": "my-lib",
  "type": "module",
  "main": "./dist/index.cjs",
  "module": "./dist/index.mjs",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "import": "./dist/index.mjs",
      "require": "./dist/index.cjs"
    }
  },
  "files": ["dist"],
  "sideEffects": false
}
```

`"sideEffects": false` 는 소비자 번들러의 tree-shaking 을 돕습니다(부수효과가 없을 때만).

## 모듈 구조 보존 (선택)

단일 파일 번들 대신 `src/` 구조를 그대로 `dist/` 에 유지하려면(소비자 측 tree-shaking·부분 import 에 유리) `preserveModules`:

```bash
zntc --bundle src/index.ts --outdir dist \
  --format=esm --platform=neutral --packages=external \
  --preserve-modules --preserve-modules-root=src
```

Rollup `output.preserveModules` 와 동일하게 각 소스 모듈이 1:1 출력 파일로 남습니다.

## watch 모드 개발

라이브러리 코드 변경 시 자동 재빌드(번들만 — HMR 아님):

```bash
zntc --bundle src/index.ts --outdir dist --format=esm --packages=external --watch
```

타입 선언도 같이 보려면 별도 터미널에서 `tsc -w --emitDeclarationOnly`.

## tsup / tsdown / bunup 대비

| 기능 | ZNTC | 비고 |
| --- | --- | --- |
| ESM / CJS 출력 | ✅ | 포맷당 빌드 1회 (스크립트로 묶음) |
| 의존성 external | ✅ | `packagesExternal` / `--packages=external` |
| sourcemap / minify | ✅ | `sourcemap` / `minify` |
| tree-shaking | ✅ | 기본 활성 ([Tree Shaking](/zntc/guides/tree-shaking/)) |
| code splitting | ✅ | `splitting: true` |
| preserveModules | ✅ | `--preserve-modules` |
| watch | ✅ | `--watch` |
| 다중 entry | ✅ | `entryPoints: [...]` |
| **`.d.ts` 생성** | ❌ | **`tsc --emitDeclarationOnly` 병행** (위 레시피) |

`.d.ts` 외 대부분의 라이브러리 빌드 시나리오를 커버합니다. 타입 선언 자체 emit 은 향후 `isolatedDeclarations` 기반으로 예정되어 있습니다.

## 관련 문서

- [Config File](/zntc/guides/config-file/) — `zntc.config.ts` 전체 옵션과 함수형 config.
- [Tree Shaking](/zntc/guides/tree-shaking/) — 라이브러리 번들의 dead code 제거 동작.
- [NAPI / JS API](/zntc/reference/napi/) — `build()` 프로그래머블 사용.
- [다른 도구에서 이관](/zntc/guides/migration/) — tsup/tsdown 등에서의 이관 매핑.
