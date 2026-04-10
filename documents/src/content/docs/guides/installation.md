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

## JS Build API

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
