---
title: 플러그인
description: ZTS 플러그인 시스템 사용법을 알아봅니다.
---

## 개요

ZTS는 두 가지 플러그인 실행 방식을 제공합니다:

1. **NAPI (권장)**: `@zts/core`의 `build()` API로 in-process 실행. 최고 성능.
2. **Subprocess**: CLI `--plugin` 옵션으로 JSON IPC 통신. Node.js 없이도 동작.

## NAPI 플러그인 (권장)

```typescript
import { init, build, vitePlugin } from "@zts/core";
init();

// esbuild 스타일
const result = await build({
  entryPoints: ["src/index.ts"],
  plugins: [{
    name: "css-loader",
    setup(build) {
      build.onResolve({ filter: /\.css$/ }, (args) => ({ path: resolve(args.path) }));
      build.onLoad({ filter: /\.css$/ }, () => ({ contents: 'export default "red";' }));
      build.onTransform({ filter: /\.ts$/ }, (args) => ({
        code: args.code.replace("__VERSION__", '"1.0"'),
      }));
    },
  }],
});

// Vite/Rollup 플러그인 어댑터
const result2 = await build({
  entryPoints: ["src/index.ts"],
  plugins: [
    vitePlugin({
      name: "json-loader",
      resolveId(source) { if (source.endsWith(".json")) return resolve(source); },
      load(id) { if (id.endsWith(".json")) return `export default ${readFileSync(id)}`; },
      transform(code) { return code.replace("import.meta.env.MODE", '"production"'); },
    }),
  ],
});
```

> **참고**: `buildSync()`에서는 JS 플러그인을 사용할 수 없습니다 (메인 스레드 데드락). `build()` (async)에서만 지원됩니다.

## Subprocess 플러그인 (CLI)

## 설정 파일

프로젝트 루트에 `zts.config.ts` (또는 `.js`, `.mjs`, `.mts`, `.cjs`, `.cts`)를 생성합니다.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/plugin";

export default defineConfig({
  plugins: [
    {
      name: "my-plugin",
      load(id) {
        if (id.endsWith(".txt")) {
          const fs = require("fs");
          return { contents: `export default ${JSON.stringify(fs.readFileSync(id, "utf8"))}` };
        }
        return null;
      },
    },
  ],
});
```

## 플러그인 훅

### resolveId

모듈 경로를 커스텀으로 해석합니다 (first-match).

```typescript
{
  name: 'virtual-module',
  resolveId(source) {
    if (source === 'virtual:config') {
      return { path: '\0virtual:config' };
    }
    return null;
  }
}
```

### load

모듈 내용을 커스텀으로 로드합니다 (first-match).

```typescript
{
  name: 'virtual-module',
  load(id) {
    if (id === '\0virtual:config') {
      return { contents: 'export const version = "1.0.0";' };
    }
    return null;
  }
}
```

### transform

모듈 코드를 변환합니다 (chaining — 모든 플러그인 순서대로 적용).

```typescript
{
  name: 'env-replace',
  transform(code, id) {
    if (id.endsWith('.ts') || id.endsWith('.js')) {
      return code.replace(/__APP_VERSION__/g, '"1.0.0"');
    }
    return null;
  }
}
```

### renderChunk

청크 출력 전 코드를 후처리합니다 (chaining).

```typescript
{
  name: 'banner',
  renderChunk(code, chunkName) {
    return `/* chunk: ${chunkName} */\n${code}`;
  }
}
```

### generateBundle

번들 생성 완료 후 호출됩니다.

```typescript
{
  name: 'notify',
  generateBundle(outputs) {
    console.log(`Built ${outputs.length} files`);
  }
}
```

## Build API

```typescript
import { build } from "@zts/plugin";

const result = await build({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  bundle: true,
  minify: true,
  sourcemap: true,
});

if (result.errors.length > 0) {
  console.error(result.errors);
}
```

### BuildOptions

| 옵션 | 타입 | 설명 |
|------|------|------|
| `entryPoints` | `string[]` | 엔트리 파일 |
| `outdir` | `string` | 출력 디렉토리 |
| `outfile` | `string` | 출력 파일 (단일) |
| `bundle` | `boolean` | 번들 모드 |
| `format` | `"esm" \| "cjs" \| "iife" \| "umd" \| "amd"` | 모듈 포맷 |
| `platform` | `"browser" \| "node" \| "neutral" \| "react-native"` | 타겟 플랫폼 |
| `target` | `string \| string[]` | ES 버전(`"es2020"`) 또는 엔진(`["chrome80","safari14"]`) |
| `minify` | `boolean` | 압축 (전체) |
| `minifyWhitespace` / `minifySyntax` / `minifyIdentifiers` | `boolean` | 세분화 토글 |
| `sourcemap` | `boolean` | 소스맵 |
| `splitting` | `boolean` | 코드 스플리팅 |
| `write` | `boolean` | `false`면 메모리 반환 |
