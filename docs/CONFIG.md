# Configuration

ZTS 의 설정 시스템 — `zts.config.{ts,js,json}`, `tsconfig.json`, `.env`, CLI flag, 함수형 config 의 우선순위 / 머지 / 차이점 정리.

## 우선순위 흐름

```
사용자 CLI flag           ─┐  (가장 우선)
                            │
zts.config.{ts,js,json}    ─┤
                            │
.env / .env.{mode} 파일    ─┤  (define 자동 주입)
                            │
tsconfig.json              ─┤
                            │
ZTS defaults               ─┘  (최후 fallback)
```

CLI > config > tsconfig > defaults. 같은 옵션이 여러 곳에 정의되면 위쪽이 이긴다.

## 옵션별 source 매핑

| 옵션 | CLI flag | zts.config | tsconfig | 비고 |
|---|:---:|:---:|:---:|---|
| `entryPoints` | positional | ✅ | ❌ | CLI 가 비어있으면 config 사용 |
| `outdir` / `outfile` | `--outdir` `-o` | ✅ | ❌ | scalar override |
| `format` | `--format=esm` | ✅ | ❌ | esm/cjs/iife/umd/amd |
| `platform` | `--platform=node` | ✅ | ❌ | node/browser/react-native |
| `target` | `--target=es2020` | ✅ | `target` | tsconfig fallback |
| `jsx` | `--jsx=automatic` | ✅ | `jsx` | preserve/transform/automatic |
| `jsxFactory` / `jsxFragment` | flag | ✅ | `jsxFactory` 등 | tsconfig fallback |
| `external` | `--external:lib` | ✅ | ❌ | 배열 — CLI 비어있으면 config |
| `alias` | `--alias:K=V` | ✅ | tsconfig `paths` | 객체 머지: 키 단위 CLI override |
| `define` | `--define:K=V` | ✅ | ❌ | 객체 머지: 키 단위 CLI override |
| `loader` | `--loader:.ext=type` | ✅ | ❌ | 객체 머지 |
| `minify` / `minifyWhitespace` 등 | `--minify` 등 | ✅ | ❌ | boolean — CLI default(false) 시 config=true 만 적용 |
| `sourcemap` | `--sourcemap` | ✅ | `sourceMap` | tsconfig fallback |
| `sourcesContent` | `--sources-content=false` | ✅ | ❌ | default=true; CLI true 시 config=false 만 적용 |
| `treeShaking` | (없음) | ✅ | ❌ | default=true |
| `experimentalDecorators` | flag | ✅ | `experimentalDecorators` | tsconfig fallback |
| `useDefineForClassFields` | flag | ✅ | `useDefineForClassFields` | default=true |
| `verbatimModuleSyntax` | (없음) | ✅ | `verbatimModuleSyntax` | tsconfig fallback |
| `tsconfigPath` | `-p path` `--project=path` | ❌ | (자기 자신) | tsconfig 위치 명시 |
| `plugins` | `--plugin path` (plugins 배열만) | ✅ | ❌ | concat — config plugins + `--plugin` plugins |
| `banner` / `footer` | `--banner:js=` 등 | ✅ | ❌ | scalar |
| `entryNames` / `chunkNames` / `assetNames` | flag | ✅ | ❌ | scalar |
| `globalName` | `--global-name=` | ✅ | ❌ | iife/umd 시 사용 |
| `publicPath` | `--public-path=` | ✅ | ❌ | asset URL prefix |
| `inject` | `--inject=path` | ✅ | ❌ | 배열 |
| `drop` | `--drop=console` 등 | ✅ | ❌ | 배열 |
| `keepNames` | `--keep-names` | ✅ | ❌ | boolean |
| `shimMissingExports` | `--shim-missing-exports` | ✅ | ❌ | boolean |
| `flow` | `--flow` | ✅ | ❌ | Flow 타입 스트리핑 |
| `quotes` | `--quotes=double` | ✅ | ❌ | single/double |
| `splitting` | `--splitting` | ✅ | ❌ | code splitting |
| `preserveModules` / `preserveModulesRoot` | flag | ✅ | ❌ | Rollup 호환 |
| `legalComments` | `--legal-comments=` | ✅ | ❌ | none/inline/eof |
| `metafile` | `--metafile` | ✅ | ❌ | esbuild 호환 |
| `resolveExtensions` | `--resolve-extensions=` | ✅ | (간접) | tsconfig 의 paths 와 별개 |
| `mainFields` | `--main-fields=` | ✅ | ❌ | package.json field 우선순위 |
| `manualChunks` | (없음) | ✅ (record / function) | ❌ | Rollup 호환. function form 은 zts.config.{ts,js} 만 |
| `inlineDynamicImports` | (없음) | ✅ | ❌ | Rollup 호환 |
| `import.meta.env.*` | `--define:import.meta.env.X="..."` | (없음 — `.env` 파일 자동 로드) | ❌ | `.env`/`.env.local`/`.env.${mode}`/`.env.${mode}.local` 4단계 머지 |

## 함수형 config 의 ConfigEnv

```ts
defineConfig(({ command, mode, env }) => ({
  format: command === "bundle" ? "esm" : "cjs",
  minify: mode === "production",
}));
```

| 필드 | 결정 규칙 |
|---|---|
| `command` | `--serve` → `"serve"`, `--watch` → `"watch"`, 그 외 → `"bundle"` |
| `mode` | `--mode <name>` 명시값. 미지정 시 command 기본 (`serve`/`watch` → `"development"`, 그 외 → `"production"`) |
| `env` | `process.env` + `.env*` 머지 (shell env 가 `.env` 를 override — Vite/dotenv 16+ 일치) |

## `.env` 파일 자동 로드

CLI 가 항상 자동 호출 (별도 flag 불필요).

```
.env                         # 기본 — committed
.env.local                   # 로컬 override — gitignored
.env.${mode}                 # mode 별 — committed
.env.${mode}.local           # mode 별 로컬 override — gitignored (가장 우선)
```

기본 prefix `["VITE_", "ZTS_"]` 매칭 키만 노출. `--env-prefix=NEXT_PUBLIC_,CUSTOM_` 으로 변경.

```ts
console.log(import.meta.env.VITE_API);  // bundle-time 정적 치환
console.log(import.meta.env.MODE);        // 자동 주입: "production"/"development"/...
console.log(import.meta.env.PROD);        // mode === "production"
console.log(import.meta.env.DEV);         // mode !== "production"
console.log(import.meta.env.SSR);         // 항상 false (SSR 미지원)
```

자세한 내용은 `loadEnv` API (`packages/core/src/load-env.ts`) 참조.

## tsconfig 통합

- `compilerOptions.target/jsx/jsxFactory/jsxFragment/jsxImportSource/experimentalDecorators/useDefineForClassFields/verbatimModuleSyntax/sourceMap` — config 미지정 시 tsconfig 값 사용.
- `compilerOptions.paths` / `baseUrl` — alias 로 변환되어 resolver 에 주입. CLI `--alias:` 가 같은 키를 override.
- `-p path` / `--project=path` 로 명시 지정. 미지정 시 entry 부모 디렉토리부터 cwd 까지 탐색.

## conflict 케이스 (실측 예시)

### 1. `format` — CLI override
```bash
# zts.config.json: { "format": "iife", "globalName": "MyLib" }
# CLI 가 명시:
zts --bundle --format=esm entry.ts
# → format=esm 적용 (CLI 우선). globalName 은 config 그대로 — 단 esm 에서는 무시.
```

### 2. `define` — 객체 키 단위 override
```ts
// zts.config.ts
export default defineConfig({
  define: {
    __VER__: '"v1.0"',
    __BUILD__: '"production"',
  },
});
```
```bash
zts --bundle --define:__BUILD__='"staging"' entry.ts
# → __VER__: "v1.0" (config 그대로), __BUILD__: "staging" (CLI override)
```

### 3. `boolean` 머지의 비대칭
```json
// zts.config.json
{ "minify": true, "sourcesContent": false }
```
```bash
# CLI default 그대로 (--minify 안 줌, --sources-content 안 줌):
zts --bundle entry.ts
# → minify=true (default false → config true 적용)
#    sourcesContent=false (default true → config false 적용)
```
주의: CLI 가 default 값을 명시적으로 줬는지 (예: `--no-minify`) 구분하지 못한다. `boolean default=false → config true 가 적용 / default=true → config false 가 적용` 의 비대칭 머지. 정밀 제어는 함수형 config 의 `command/mode` 분기로.

### 4. `external` — 배열 정책
```json
// zts.config.json
{ "external": ["node:fs", "node:path"] }
```
```bash
zts --bundle entry.ts                              # → ["node:fs", "node:path"] (config)
zts --bundle --external=react entry.ts             # → ["react"] (CLI 가 비어있지 않으면 CLI 만 사용 — concat 안 함)
```

### 5. `tsconfig` + `zts.config` + CLI 3-way (jsx)
```json
// tsconfig.json
{ "compilerOptions": { "jsx": "preserve" } }
```
```ts
// zts.config.ts
export default defineConfig({ jsx: "automatic" });
```
```bash
zts --bundle --jsx=transform App.tsx
# → jsx=transform (CLI 우선). config 의 automatic / tsconfig 의 preserve 모두 무시.
```

### 6. `.env` shell override
```env
# .env
VITE_HOST=production-default.example.com
```
```bash
VITE_HOST=staging.example.com zts --bundle entry.ts
# → import.meta.env.VITE_HOST = "staging.example.com" (shell 우선)
# → CI / 컨테이너 환경에서 .env 수정 없이 override 가능.
```

### 7. `--config <path>` 명시 vs 자동 탐색
```bash
zts --bundle --config ./configs/prod.config.ts entry.ts
# → 자동 탐색 우회 (cwd 의 zts.config.* 무시).
# → 함수형 config 의 command='bundle', mode 는 --mode 또는 default.
```

## 다른 번들러와의 차이

### Vite
- ZTS: `defineConfig(fn | obj)` 동일.
- ZTS: `--mode` / `--config <path>` 동일.
- ZTS: `.env*` 4단계 우선순위 동일. prefix default 만 차이 (Vite `["VITE_"]`, ZTS `["VITE_", "ZTS_"]`).
- ZTS: `import.meta.env.MODE/PROD/DEV/SSR` 자동 주입 동일. `BASE_URL` 미지원.
- ZTS: `defineConfig(({ command }))` 의 command 값이 다름 — Vite 는 `"build"|"serve"`, ZTS 는 `"bundle"|"serve"|"watch"`.

### esbuild
- esbuild: `zts.config.*` 같은 명시 config 파일 미지원 (JS API 만). ZTS 는 양쪽.
- esbuild: tsconfig 통합 (paths/jsx) 동일.
- esbuild: `define` / `external` / `alias` 의미 동일. 에러 메시지·flag 형식만 차이.

### Rolldown
- Rolldown: `rolldown.config.{ts,js}` + `defineConfig`. ZTS 와 거의 동일.
- Rolldown: 함수형 config 미지원 (객체 only). ZTS 는 양쪽.
- Rolldown: `manualChunks` 의 record / function form 동일.

## 디버깅

### 어떤 config 가 실제로 적용됐는지
- 자동 탐색: `findConfigPath(cwd)` 가 가장 위 우선순위 매치를 반환. 우선순위는 `.ts > .mts > .cts > .mjs > .js > .cjs > .json`.
- watch 모드: config / `.env*` 변경 시 자동 process restart (`--watch-json` 의 경우 `{type: "restart", reason: "..."}` 이벤트 emit).

### typo 감지
현재는 unknown 키 silent 무시. Levenshtein 기반 "did you mean?" 은 [#2109](https://github.com/ohah/zts/issues/2109) 에서 추가 예정.

## 참고 이슈
- 에픽: [#2099](https://github.com/ohah/zts/issues/2099)
- Phase 1: #2113 / #2114 / #2115 (loader / 자동 탐색 / BuildOptions 머지)
- Phase 2-1: #2119 (함수형 config + `--config` + `--mode`)
- Phase 2-4: #2120 (`.env` 자동 로드)
- Phase 2-5: #2123 (watch hot reload)
- Phase 3-2: #2109 (typo "did you mean?")
- Phase 3-5: #2112 (TS BuildOptions ↔ Zig TranspileOptions schema sync)
