---
title: 플러그인
description: ZTS 플러그인 시스템 사용법을 알아봅니다.
---

## 개요

ZTS는 Rollup/Vite 호환 플러그인 인터페이스를 제공합니다. 플러그인은 JS/TS로 작성하며, subprocess JSON IPC로 통신합니다.

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
| `format` | `"esm" \| "cjs" \| "iife"` | 모듈 포맷 |
| `platform` | `"browser" \| "node" \| "react-native"` | 타겟 플랫폼 |
| `minify` | `boolean` | 압축 |
| `sourcemap` | `boolean` | 소스맵 |
| `splitting` | `boolean` | 코드 스플리팅 |
| `write` | `boolean` | `false`면 메모리 반환 |
