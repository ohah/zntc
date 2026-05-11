---
title: 설정 파일 (zntc.config.json)
description: ZNTC CLI가 자동 로드하는 zntc.config.json 사용법과 에디터 자동완성
---

ZNTC CLI는 현재 디렉토리의 `zntc.config.json`을 자동으로 로드합니다. VSCode / IntelliJ / Zed 등 JSON-schema-aware 에디터에서 `$schema` 참조로 **자동완성 + 타입 검증**을 받을 수 있습니다.

## 빠른 시작

```json
{
  "$schema": "https://ohah.github.io/zntc/schemas/transpile-options.schema.json",
  "target": "es2022",
  "sourcemap": true,
  "minifySyntax": true,
  "platform": "browser"
}
```

파일을 저장하면 같은 디렉토리의 `zntc input.ts` 실행 시 자동으로 위 옵션이 적용됩니다.

```bash
zntc input.ts               # config.json 값 사용
zntc input.ts --quotes=double  # CLI 인자가 config 덮어씀 (CLI > config)
```

## 옵션 우선순위

ZNTC는 다음 순서로 옵션을 병합합니다 (**뒤가 우선**):

1. Zig 기본값
2. `zntc.config.json`
3. `tsconfig.json` (`compilerOptions.target` 등 일부 필드)
4. CLI 인자

CLI 인자로 `zntc.config.json`의 값을 덮어쓸 수 있지만, 반대는 불가능합니다. config 파일을 일시 비활성화하려면 파일을 이름 변경하거나 삭제하세요.

## 고급 머지 규칙

대부분의 옵션은 단순히 "위가 이긴다" 지만, 몇 가지는 사용자가 자주 함정에 빠지는 비대칭/특수 동작이 있습니다.

### Boolean 옵션의 비대칭 머지

`--minify` 같은 boolean flag 는 CLI 가 "안 줬을 때" 와 "false 로 줬을 때" 를 구분하지 못합니다. 그래서 다음 비대칭이 적용됩니다.

```json
// zntc.config.json
{ "minify": true, "sourcesContent": false }
```

```bash
zntc --bundle entry.ts            # CLI 에 --minify, --sources-content 둘 다 안 줌
# → minify=true            (default=false 이므로 config 의 true 적용)
# → sourcesContent=false   (default=true 이므로 config 의 false 적용)
```

규칙: **default 와 반대 방향으로 설정된 config 값만 효과를 가집니다.**

| Default | config=true | config=false |
|---|---|---|
| `false` | ✅ 적용됨 | (무시 — 이미 false) |
| `true` | (무시 — 이미 true) | ✅ 적용됨 |

CLI 와 config 모두 정밀하게 제어하고 싶다면 함수형 config 의 `command`/`mode` 분기를 사용하세요.

```ts
defineConfig(({ command, mode }) => ({
  minify: command === 'bundle' && mode === 'production',
}));
```

### `plugins` 는 concat (다른 배열과 다름)

```ts
// zntc.config.ts
defineConfig({ plugins: [a, b] });
```

```bash
zntc --bundle --plugin ./c.js --plugin ./d.js entry.ts
# → plugins = [a, b, c, d]   (config + CLI concat)
```

다른 배열 옵션 (`external`, `inject`, `drop`, ...) 은 **CLI 가 비어있지 않으면 CLI 만 사용** (덮어쓰기) 인 반면, `plugins` 는 합쳐집니다. 순서가 hook 결과에 영향을 주므로 ([플러그인 가이드](/zntc/guides/plugins/) 의 first-match / chaining 정책 참고) 등록 순서를 의식해서 작성하세요.

### `--tsconfig-raw` JSON 직접 주입

CLI 에서 tsconfig 내용을 JSON 문자열로 직접 전달할 수 있습니다 — 파일 기반 `-p path` 와 자동 탐색을 모두 우회합니다.

```bash
zntc --bundle entry.ts --tsconfig-raw='{"compilerOptions":{"jsx":"preserve"}}'
```

CI / Docker 환경에서 tsconfig 파일을 새로 만들지 않고 동적으로 옵션을 주입할 때 유용합니다. 우선순위는 `--tsconfig-raw` > `-p path` > 자동 탐색 순.

### tsconfig + `zntc.config` + CLI 3-way (`jsx` 예시)

같은 옵션이 세 곳에 정의되면 우선순위에 따라 가장 위가 이깁니다.

```json
// tsconfig.json
{ "compilerOptions": { "jsx": "preserve" } }
```

```ts
// zntc.config.ts
export default defineConfig({ jsx: 'automatic' });
```

```bash
zntc --bundle --jsx=transform App.tsx
# → jsx=transform   (CLI 우선)
# → config 의 automatic, tsconfig 의 preserve 둘 다 무시
```

`zntc.config` 만 있고 CLI 가 없으면 `automatic` 이 적용되고, `zntc.config` 도 없으면 tsconfig 의 `preserve` 가 fallback 됩니다.

## $schema 에디터 설정

### VSCode

`$schema` 필드가 있으면 **추가 설정 없이** 자동 작동합니다. JSON 파일에서 바로 자동완성과 hover 설명이 나타납니다.

### 로컬 schema 참조 (오프라인)

온라인 schema 대신 로컬 파일을 쓰려면:

```bash
# 프로젝트 루트에 schema 파일 생성
zig build schema
```

(ZNTC 레포 내부에서만 사용 가능. npm 패키지 사용자는 URL 방식 권장.)

## 지원 필드

`zntc.config.json`에서 사용할 수 있는 모든 필드는 [Transpile 옵션 레퍼런스](/zntc/reference/options/)를 참조하세요. `TranspileOptions`와 동일합니다.

**주의**: bundler 전용 옵션(`external`, `alias`, `define` 등)은 현재 `zntc.config.json`에서 제한적으로 지원됩니다. bundler 설정이 많다면 `zntc.config.ts` (TypeScript 설정 파일, 플러그인 지원)를 사용하세요.

### config 파일 모양 — 자주 쓰는 객체 옵션

다음 옵션은 CLI flag 가 없거나 제한적인 객체 형태로, config 파일에서 주로 다룹니다.

#### `server` — dev server 기본값

`zntc dev` / `zntc --serve` 가 사용하는 기본값. CLI flag (`--port` / `--host` / `--open`) 가 항상 우선합니다.

```ts
// zntc.config.ts
export default defineConfig({
  server: {
    port: 5173,
    host: true,         // true → 0.0.0.0 (Vite 동일)
    strictPort: false,  // true 면 포트 충돌 시 다음 포트 시도하지 않고 종료
    open: false,
  },
});
```

| 필드 | 타입 | 비고 |
| ---- | ---- | ---- |
| `port` | `number` | CLI `--port` override |
| `host` | `string \| boolean` | `true` = `0.0.0.0`. CLI `--host` override |
| `strictPort` | `boolean` | 충돌 시 fallback 금지 |
| `open` | `boolean` | 시작 후 브라우저 자동 오픈. CLI `--open` override |

#### `alias` — Object 또는 Array (Vite 호환)

`alias` 는 두 형태를 지원합니다:

```ts
// 1. Object 형태 (esbuild 호환): exact + prefix
defineConfig({ alias: { react: 'preact/compat' } });

// 2. Array 형태 (Vite resolve.alias): RegExp find 지원
defineConfig({
  alias: [{ find: /^@\/(.*)$/, replacement: './src/$1' }],
});
```

- `zntc.config.ts` / `.js` — 두 형태 모두 사용 가능
- `zntc.config.json` — Object 형태만 (JSON 은 RegExp 직렬화가 없음)
- `buildSync` — Array 형태 미지원 (RegExp 매칭이 host runtime 에 위임되어 async `build()` / `watch()` 만)

#### `compiler` — 라이브러리별 1st-party transform

`@next/swc` 의 `compiler` 와 호환되는 surface. styled-components / emotion 1st-party transform 옵션을 받습니다.

```ts
defineConfig({
  compiler: {
    styledComponents: true,
    emotion: { autoLabel: 'dev-only' },
  },
});
```

전체 옵션 목록은 [Babel 마이그레이션 가이드](/zntc/guides/babel-migration/)를 참조하세요.

#### `index.html` 안의 환경변수 — EJS 토큰

`index.html` 본문에 `<%= ZNTC_KEY %>` 형태로 토큰을 쓰면, `dev` / `build` 양쪽에서 자동으로 `.env` 의 값으로 치환됩니다. JS 측 `import.meta.env.X` 와는 별개 경로 — HTML 안에서 직접 사용 가능합니다.

```html
<!DOCTYPE html>
<html>
  <head>
    <title><%= ZNTC_APP_TITLE %></title>
    <meta name="version" content="<%= ZNTC_BUILD_VERSION %>" />
  </head>
  <body><div id="root"></div></body>
</html>
```

```bash
# .env
ZNTC_APP_TITLE=My App
ZNTC_BUILD_VERSION=2026.05
```

**Spec**:

- 토큰 양식: `<%= KEY %>` (delimiter 양쪽 공백 허용 — `<%=KEY%>` / `<%=   KEY   %>` 모두 OK).
- 키 prefix 는 **`ZNTC_` 만** 허용. JS 측 `envPrefixes` 가 `VITE_*` 까지 허용해도 HTML 본문에는 노출 안 됨 — secret 누설 방지.
- 다른 prefix 키 (`<%= VITE_API_KEY %>`) 는 **원본 보존 + warning** (token 이 사이트에 그대로 노출되므로 즉시 감지 가능).
- 미발견 키 (`<%= ZNTC_UNDEFINED %>`) 는 **빈 문자열 + warning** (Vite / CRA 와 동일).
- expression 평가 (`<%= mode === 'prod' ? '/' : '/dev/' %>`) 는 **미지원** — key-only.

#### 함수형 config 의 `ConfigEnv.command`

`zntc.config.ts` 에서 `defineConfig(({ command, mode, env }) => ...)` 형태를 쓸 때 `command` 가 받을 수 있는 값:

| `command` | 발생 조건 |
| --------- | --------- |
| `"bundle"` | `zntc build` / 그 외 (default) |
| `"serve"`  | `zntc dev` / `zntc preview` / `--serve` |
| `"watch"`  | `--watch` |

Vite (`"build" \| "serve"`) 와 다르게 ZNTC 는 `"bundle"` 과 `"watch"` 를 별도로 분리합니다.

## zntc.config.ts vs zntc.config.json

| | `zntc.config.ts` | `zntc.config.json` |
|---|---|---|
| 플러그인 | ✅ 전체 지원 | ❌ |
| 동적 값 | ✅ (함수, import) | ❌ |
| JSON schema 자동완성 | ❌ | ✅ |
| CLI 자동 탐색 | bundle/serve만 | **모든 명령** |
| 학습 비용 | 중 | 낮음 |

**권장**:
- 단순 트랜스파일 / 작은 프로젝트 → `zntc.config.json`
- 플러그인 / 동적 설정 / 번들 → `zntc.config.ts`

두 파일이 동시에 있으면 `zntc.config.ts`가 우선합니다 (번들 경로).

## 스키마 재생성

ZNTC 버전을 업그레이드하면 schema URL은 동일하지만 내부 옵션 목록이 갱신됐을 수 있습니다. VSCode에서 JSON 캐시를 강제로 새로고침하려면 워크스페이스를 다시 열거나 "JSON: Clear Schema Cache" 명령을 실행하세요.

ZNTC 저장소 내부 개발자는:

```bash
zig build schema
```

로 `documents/public/schemas/transpile-options.schema.json`을 재생성합니다 — `src/transpile.zig`의 `TranspileOptionsDto` struct가 변경되면 반드시 실행.
