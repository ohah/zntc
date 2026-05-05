---
title: 설정 파일 (zts.config.json)
description: ZTS CLI가 자동 로드하는 zts.config.json 사용법과 에디터 자동완성
---

ZTS CLI는 현재 디렉토리의 `zts.config.json`을 자동으로 로드합니다. VSCode / IntelliJ / Zed 등 JSON-schema-aware 에디터에서 `$schema` 참조로 **자동완성 + 타입 검증**을 받을 수 있습니다.

## 빠른 시작

```json
{
  "$schema": "https://ohah.github.io/zts/schemas/transpile-options.schema.json",
  "target": "es2022",
  "sourcemap": true,
  "minifySyntax": true,
  "platform": "browser"
}
```

파일을 저장하면 같은 디렉토리의 `zts input.ts` 실행 시 자동으로 위 옵션이 적용됩니다.

```bash
zts input.ts               # config.json 값 사용
zts input.ts --quotes=double  # CLI 인자가 config 덮어씀 (CLI > config)
```

## 옵션 우선순위

ZTS는 다음 순서로 옵션을 병합합니다 (**뒤가 우선**):

1. Zig 기본값
2. `zts.config.json`
3. `tsconfig.json` (`compilerOptions.target` 등 일부 필드)
4. CLI 인자

CLI 인자로 `zts.config.json`의 값을 덮어쓸 수 있지만, 반대는 불가능합니다. config 파일을 일시 비활성화하려면 파일을 이름 변경하거나 삭제하세요.

## $schema 에디터 설정

### VSCode

`$schema` 필드가 있으면 **추가 설정 없이** 자동 작동합니다. JSON 파일에서 바로 자동완성과 hover 설명이 나타납니다.

### 로컬 schema 참조 (오프라인)

온라인 schema 대신 로컬 파일을 쓰려면:

```bash
# 프로젝트 루트에 schema 파일 생성
zig build schema
```

(ZTS 레포 내부에서만 사용 가능. npm 패키지 사용자는 URL 방식 권장.)

## 지원 필드

`zts.config.json`에서 사용할 수 있는 모든 필드는 [Transpile 옵션 레퍼런스](/zts/reference/options/)를 참조하세요. `TranspileOptions`와 동일합니다.

**주의**: bundler 전용 옵션(`external`, `alias`, `define` 등)은 현재 `zts.config.json`에서 제한적으로 지원됩니다. bundler 설정이 많다면 `zts.config.ts` (TypeScript 설정 파일, 플러그인 지원)를 사용하세요.

### config 파일 모양 — 자주 쓰는 객체 옵션

다음 옵션은 CLI flag 가 없거나 제한적인 객체 형태로, config 파일에서 주로 다룹니다.

#### `server` — dev server 기본값

`zts dev` / `zts --serve` 가 사용하는 기본값. CLI flag (`--port` / `--host` / `--open`) 가 항상 우선합니다.

```ts
// zts.config.ts
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

- `zts.config.ts` / `.js` — 두 형태 모두 사용 가능
- `zts.config.json` — Object 형태만 (JSON 은 RegExp 직렬화가 없음)
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

전체 옵션 목록은 [Babel 마이그레이션 가이드](/zts/guides/babel-migration/)를 참조하세요.

#### 함수형 config 의 `ConfigEnv.command`

`zts.config.ts` 에서 `defineConfig(({ command, mode, env }) => ...)` 형태를 쓸 때 `command` 가 받을 수 있는 값:

| `command` | 발생 조건 |
| --------- | --------- |
| `"bundle"` | `zts build` / 그 외 (default) |
| `"serve"`  | `zts dev` / `zts preview` / `--serve` |
| `"watch"`  | `--watch` |

Vite (`"build" \| "serve"`) 와 다르게 ZTS 는 `"bundle"` 과 `"watch"` 를 별도로 분리합니다.

## zts.config.ts vs zts.config.json

| | `zts.config.ts` | `zts.config.json` |
|---|---|---|
| 플러그인 | ✅ 전체 지원 | ❌ |
| 동적 값 | ✅ (함수, import) | ❌ |
| JSON schema 자동완성 | ❌ | ✅ |
| CLI 자동 탐색 | bundle/serve만 | **모든 명령** |
| 학습 비용 | 중 | 낮음 |

**권장**:
- 단순 트랜스파일 / 작은 프로젝트 → `zts.config.json`
- 플러그인 / 동적 설정 / 번들 → `zts.config.ts`

두 파일이 동시에 있으면 `zts.config.ts`가 우선합니다 (번들 경로).

## 스키마 재생성

ZTS 버전을 업그레이드하면 schema URL은 동일하지만 내부 옵션 목록이 갱신됐을 수 있습니다. VSCode에서 JSON 캐시를 강제로 새로고침하려면 워크스페이스를 다시 열거나 "JSON: Clear Schema Cache" 명령을 실행하세요.

ZTS 저장소 내부 개발자는:

```bash
zig build schema
```

로 `documents/public/schemas/transpile-options.schema.json`을 재생성합니다 — `src/transpile.zig`의 `TranspileOptionsDto` struct가 변경되면 반드시 실행.
