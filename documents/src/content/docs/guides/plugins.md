---
title: 플러그인
description: ZTS 플러그인 시스템 사용법을 알아봅니다.
---

## 개요

ZTS 플러그인은 Rollup/Vite 호환 인터페이스로, `@zts/core`의 NAPI를 통해 in-process로 실행됩니다.

## NAPI 플러그인

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

## 설정 파일

프로젝트 루트에 `zts.config.ts` (또는 `.js`, `.mjs`, `.mts`, `.cjs`, `.cts`)를 생성합니다.
npm 배포 CLI(`zts` 명령)가 자동으로 감지해 `@zts/core`로 in-process 실행합니다.

```typescript
// zts.config.ts
import { defineConfig } from "@zts/core";

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

#### `loader` 옵션 — asset 로더 override (#2157)

`load` 가 반환하는 객체에 `loader` 를 명시하면 graph 가 그 값으로 module loader 를 override 합니다 (확장자 추론 무시). esbuild `onLoad` callback 의 `loader: 'text' | 'binary' | ...` 와 동일.

```typescript
{
  name: 'md-as-text',
  load(id) {
    if (id.endsWith('.md')) {
      return {
        contents: readFileSync(id, 'utf-8'),
        loader: 'text',     // 파일 내용을 string default export 로 처리
      };
    }
    return null;
  }
}
```

지원 loader: `text` / `dataurl` / `base64` / `binary` / `empty` / `javascript` / `json` / `css`.

#### `contents` binary 지원 (#2157 follow-up)

`contents` 는 `string` 또는 `Uint8Array` / Node.js `Buffer` 모두 받습니다 — PNG/JPG 등 utf-8 invalid bytes 도 손실 없이 forward.

```typescript
{
  name: 'png-as-dataurl',
  load(id) {
    if (id.endsWith('.png')) {
      return {
        contents: readFileSync(id),  // Buffer / Uint8Array — binary safe
        loader: 'dataurl',
      };
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

### buildStart / buildEnd / closeBundle (#2156)

Bundle lifecycle hook. esbuild `onStart` / `onEnd` / `onDispose`, Rollup/Vite/rolldown `buildStart` / `buildEnd` / `closeBundle` 호환.

| Hook | 호출 시점 | 인자 |
|---|---|---|
| `buildStart` | bundle 시작 직후 1회 (watch 모드는 초기 build와 매 rebuild) | 없음 |
| `buildEnd` | output contents 결정 직후 | `error?: Error` (build 실패 시 fatal diagnostic 의 message) |
| `closeBundle` | output 파일 write 완료 후 | 없음 |

```typescript
{
  name: 'lifecycle',
  buildStart() { console.log('build started'); },
  buildEnd(err) {
    if (err) console.error('build failed:', err.message);
    else console.log('output ready');
  },
  closeBundle() { console.log('write done'); },
}
```

`build()` 호출 순서: `buildStart → onLoad / onTransform → buildEnd → write → closeBundle`.
`watch()` 호출 순서: `buildStart → onLoad / onTransform → buildEnd → onReady/onRebuild → closeBundle`.
다중 plugin 시 모두 순차 실행. `buildEnd` / `closeBundle` 의 plugin 에러는 swallow — 본 build/rebuild 결과를 가리지 않음.

## Build API

```typescript
import { build } from "@zts/core";

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
| `allowOverwrite` | `boolean` | 입력 파일과 같은 출력 경로를 명시적으로 허용 |
| `bundle` | `boolean` | 번들 모드 |
| `format` | `"esm" \| "cjs" \| "iife" \| "umd" \| "amd"` | 모듈 포맷 |
| `platform` | `"browser" \| "node" \| "neutral" \| "react-native"` | 타겟 플랫폼 |
| `target` | `string \| string[]` | ES 버전(`"es2020"`) 또는 엔진(`["chrome80","safari14"]`) |
| `minify` | `boolean` | 압축 (전체) |
| `minifyWhitespace` / `minifySyntax` / `minifyIdentifiers` | `boolean` | 세분화 토글 |
| `sourcemap` | `boolean` | 소스맵 |
| `splitting` | `boolean` | 코드 스플리팅 |
| `write` | `boolean` | `false`면 메모리 반환 |
