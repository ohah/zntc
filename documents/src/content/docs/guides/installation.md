---
title: 설치
description: ZTS를 설치하는 방법을 알아봅니다.
---

## 빌드 (소스)

ZTS는 현재 소스에서 빌드해야 합니다.

### 사전 요구사항

- **Zig 0.15.2** ([mise](https://mise.jdx.dev/)로 설치 권장)
- **Git**

### 빌드

```bash
git clone https://github.com/ohah/zts.git
cd zts
zig build -Doptimize=ReleaseFast
```

빌드된 바이너리는 `zig-out/bin/zts`에 생성됩니다.

### PATH에 추가

```bash
# ~/.zshrc 또는 ~/.bashrc
export PATH="$PATH:/path/to/zts/zig-out/bin"
```

## WASM (브라우저/Node.js)

```bash
bun add @zts/wasm
```

```typescript
import { init, transpile } from "@zts/wasm";

await init();
const result = transpile("const x: number = 1;");
console.log(result.code); // "const x = 1;"
```

## NAPI (Node.js/Bun — 권장)

```bash
bun add @zts/core
```

```typescript
import { init, transpile, build, buildSync, vitePlugin } from "@zts/core";

init();

// 트랜스파일
const { code } = transpile("const x: number = 1;");

// 동기 번들링
const result = buildSync({
  entryPoints: ["src/index.ts"],
  format: "esm",
  minify: true,
});

// 비동기 번들링 + JS 플러그인
const result2 = await build({
  entryPoints: ["src/index.ts"],
  define: { "process.env.NODE_ENV": '"production"' },
  plugins: [{
    name: "css-plugin",
    setup(build) {
      build.onLoad({ filter: /\.css$/ }, () => ({
        contents: 'export default "red";',
      }));
    },
  }],
});

// Vite/Rollup 플러그인 어댑터
const result3 = await build({
  entryPoints: ["src/index.ts"],
  plugins: [
    vitePlugin({
      name: "env-replace",
      transform(code) {
        return code.replace("import.meta.env.MODE", '"production"');
      },
    }),
  ],
});
```

## JS Plugin API (subprocess 방식)

```bash
bun add @zts/plugin
```

```typescript
import { build } from "@zts/plugin";

const result = await build({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  bundle: true,
});
```
