---
title: 플러그인
description: ZNTC 플러그인 시스템 사용법을 알아봅니다.
---

## 개요

ZNTC 플러그인은 Rollup/Vite 호환 인터페이스로, `@zntc/core`의 NAPI를 통해 in-process로 실행됩니다.

## 호환성 요약

### 플러그인 작성 surface

| Surface | 상태 | 비고 |
| ------- | ---- | --- |
| **JavaScript (NAPI)** — Node.js / Bun in-process | ✅ 지원 | 가장 일반적. Rollup/Vite/esbuild plugin 그대로 또는 어댑터 경유 |
| **네이티브 Zig** plugin (`*.zig` → 정적 링크) | ❌ 추후 지원 예정 | NAPI overhead 없이 in-engine 호출 — frontend/transform 핫패스 가속용 |
| **WASM** plugin (`*.wasm` 동적 로드) | ❌ 추후 지원 예정 | 언어 자유 + 격리 (Rust / AssemblyScript / Go 등) |

### Plugin hook 호환성

| Surface | 상태 | 사용 경로 |
| ------- | ---- | -------- |
| esbuild-style `setup(build)` | 부분 지원 | `build.onResolve`, `build.onLoad`, `build.onTransform`, `build.onResolveContext`, `build.onAstFunction` |
| Rollup/Vite-style `resolveId` / `load` / `transform` | 지원 | `vitePlugin()` wrapper 또는 config plugin |
| **Vite 4+ hook object** `{ filter, handler }` | 지원 | `vitePlugin()` 가 `handler` 자동 추출 (`filter` 는 native 가 무시) |
| **Plugin sourcemap object** (`RawSourceMap`) | 지원 | wrapper 가 V3 검증 + stringify. invalid 시 drop + warn |
| output hook `renderChunk` / `generateBundle` | 부분 지원 | chunk 후처리, output 목록 접근 |
| lifecycle `buildStart` / `buildEnd` / `closeBundle` | 지원 | `build()`와 `watch()` 초기 build/rebuild마다 호출 |
| Plugin context `this.error()` / `this.warn()` | 지원 | `warn` 은 `@zntc/core [name]:` prefix |
| Plugin context `this.addWatchFile()` | no-op | 호출 가능하지만 native watcher 에 전파 X (SFC `<style src="..."/>` 외부 dep stale 가능) |
| Plugin context `this.resolve()` / `this.emitFile()` | ❌ 미지원 | 호출 시 informative Error throw — graph mutation surface 부재 |
| **프레임워크 SFC** (`.vue` / `.svelte`) | ❌ 미지원 | virtual module ID + `?vue&type=style&lang.css` query sub-import 인식 필요 — 별도 follow-up |
| `buildSync()` + JS plugin | 미지원 | async `build()` / `watch()` 사용 |

ZNTC native worker는 module을 만날 때 NAPI threadsafe function으로 JS hook을 호출하고 응답을 기다립니다. 따라서 hook filter를 좁게 잡고, 단순 확장자 처리는 `loader` 옵션을 먼저 쓰는 편이 빠릅니다.

## 실행 순서

```text
buildStart
  -> resolveId / onResolve
  -> load / onLoad
  -> transform / onTransform
  -> native link / tree-shake / emit
  -> renderChunk
  -> generateBundle
buildEnd
write
closeBundle
```

`watch()`에서는 같은 순서가 초기 build와 매 rebuild마다 반복되고, `buildEnd` 이후 `onReady` 또는 `onRebuild` callback이 실행됩니다.

### 다중 플러그인일 때 hook 별 선택 정책

두 개 이상의 플러그인이 같은 hook 을 등록하면 어떻게 합쳐지는지가 hook 마다 다릅니다.

| Hook | 정책 | 설명 |
|---|---|---|
| `resolveId` / `onResolve` | **first-match** | 첫 non-null 반환이 우승. 뒤 플러그인은 호출되지 않음 |
| `load` / `onLoad` | **first-match** | 첫 non-null 반환이 우승 |
| `transform` / `onTransform` | **chaining** | 등록 순서대로 모두 호출. 앞 hook 의 출력 → 뒤 hook 의 입력 |
| `renderChunk` | **chaining** | 등록 순서대로 모두 호출 (chunk code 변환) |
| `generateBundle` | **all-run, sequential** | 모두 실행 (반환값 무시 — observation only) |
| `buildStart` / `buildEnd` / `closeBundle` | **all-run, sequential** | 모두 실행. lifecycle 신호 |

**플러그인 순서가 결과에 영향을 주는 경우:**
- `resolveId` / `load` — 앞에 등록된 플러그인이 매칭되면 뒤 플러그인은 기회 없음. virtual module / alias 처리는 일반 resolver 보다 앞에 두어야 함.
- `transform` — 변환 chain 의 순서. 예: ENV 치환 → 코드 minify 순서가 뒤바뀌면 결과가 달라짐.

**watch 모드 lifecycle 반복:**

```text
초기 build:    buildStart → resolveId/load/transform → buildEnd → write → onReady → closeBundle
파일 변경 시:  buildStart → ... → buildEnd → onRebuild → closeBundle
```

매 rebuild 마다 `buildStart` / `closeBundle` 이 다시 호출되므로, **연결 재사용 (DB/소켓 등) 이 필요하면 build 외부 (모듈 로드 시점) 에서 한 번만 초기화** 하세요.

**`buildEnd` / `closeBundle` 의 에러 swallow:**

이 두 hook 에서 플러그인이 throw 해도 build/rebuild 결과는 정상 반환됩니다 (후처리 실패가 사용자 빌드를 가리지 않도록). 실패 감지가 필요하면 별도 flag/log 로 노출하세요:

```typescript
let lastBuildOk = true;
const myPlugin = {
  name: 'after-build',
  buildEnd(err) {
    if (err) { lastBuildOk = false; return; }
    try {
      runPostProcess();   // 실패해도 swallow 됨
    } catch (e) {
      lastBuildOk = false;
      console.error('[after-build] failed:', e);
    }
  },
};
```

## 처음부터 만들기 — 5 단계

ZNTC 플러그인은 **JavaScript 로 작성**하고, ZNTC 의 NAPI 바인딩이 native worker 에서 호출합니다 (별도 컴파일 단계 없음). 가장 단순한 형태부터 출발해 hook 을 하나씩 더해가는 방식이 안전합니다.

### 1. 빈 plugin 스켈레톤

```typescript
// my-plugin.ts
import type { ZntcPlugin } from "@zntc/core";

export function myPlugin(): ZntcPlugin {
  return {
    name: "my-plugin",
    setup(build) {
      // 여기에 hook 을 등록
    },
  };
}
```

`name` 은 진단 메시지(`Plugin "<name>" failed ...`) 에 그대로 노출되므로 사용자가 식별 가능한 형태로 짓습니다.

### 2. `resolveId` — 가상 모듈 / 별칭 처리

```typescript
build.onResolve({ filter: /^virtual:settings$/ }, () => ({
  path: "\0virtual:settings",
}));
```

`\0` prefix 는 esbuild/Rollup 관례로 "실제 파일이 아닌 가상 ID" 를 의미합니다. ZNTC 의 native resolver 가 해당 ID 를 디스크에서 찾지 않습니다.

### 3. `load` — 모듈 본문 만들기

```typescript
build.onLoad({ filter: /^\0virtual:settings$/ }, () => ({
  contents: `export const apiUrl = ${JSON.stringify(process.env.API_URL ?? "")};`,
  loader: "ts", // 또는 "js" / "json"
}));
```

`loader` 를 지정해두면 native 가 어떤 parser 로 파싱할지 즉시 알 수 있습니다.

### 4. `transform` — 기존 모듈 코드 변환

```typescript
build.onTransform({ filter: /\.tsx?$/ }, (args) => {
  if (!args.code.includes("__BUILD_TIME__")) return null; // 변경 없음
  return {
    code: args.code.replace(/__BUILD_TIME__/g, JSON.stringify(new Date().toISOString())),
  };
});
```

변경이 없으면 `null` 을 반환하세요 — ZNTC 가 원본을 그대로 사용합니다 (불필요한 sourcemap 재생성 회피).

### 5. 등록 + 사용

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";
import { myPlugin } from "./my-plugin";

export default defineConfig({
  entryPoints: ["src/index.ts"],
  outdir: "dist",
  plugins: [myPlugin()],
});
```

`build()` API 로 직접 호출 시에도 동일한 `plugins: [...]` 배열을 넘기면 됩니다.

### Tip — 디버깅

- `console.warn` 으로 출력하되, 메시지에 plugin 이름 prefix 를 넣으세요 — `[my-plugin] ...` 처럼. `this.warn(msg)` 를 쓰면 `@zntc/core [name]:` 가 자동으로 붙습니다.
- transform/load 가 **모듈마다 한 번씩** 호출되므로 hot-path 에서 동기 큰 작업(파일 시스템 동기 읽기 등) 은 피하세요.
- 에러는 `this.error(new Error(...))` 로 throw 하면 ZNTC 가 plugin 이름 + 파일 위치를 진단에 같이 출력합니다.

## NAPI 플러그인

```typescript
import { init, build, vitePlugin } from "@zntc/core";
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

프로젝트 루트에 `zntc.config.ts` (또는 `.js`, `.mjs`, `.mts`, `.cjs`, `.cts`)를 생성합니다.
npm 배포 CLI(`zntc` 명령)가 자동으로 감지해 `@zntc/core`로 in-process 실행합니다.

```typescript
// zntc.config.ts
import { defineConfig } from "@zntc/core";

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

#### `disabled` 반환 — empty module fallback

반환 객체에 `disabled: true` 를 포함하면 해당 모듈을 빈 객체(`module.exports = {}`) 로 대체. Metro `resolveRequest` 가 `{ type: 'empty' }` 반환하거나 webpack `resolve.fallback` 이 `false` 일 때의 escape hatch.

```typescript
{
  name: 'stub-node-builtins',
  resolveId(source) {
    if (source === 'fs' || source === 'path') {
      return { disabled: true };
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

지원 loader: `file` / `copy` / `dataurl` / `base64` / `text` / `binary` / `empty` / `json` / `css` / `js` / `jsx` / `ts` / `tsx`.

`js` / `jsx` / `ts` / `tsx` 는 `onLoad` 가 반환한 `contents` 를 해당 parser mode 로 강제 해석 — 확장자 없는 virtual module 이나 다른 확장자로 위장된 소스를 강제 파싱할 때 사용.

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

### onResolveContext

`require.context(dir, recursive, filter, mode)` 의 매칭 결과를 호스트 런타임에서 채운다. ZNTC 는 자체 regex executor 가 없어 host 의 RegExp (Node V8 / Bun JSC) 에 위임.

콜백 인자:
- `dir` — `require.context` 의 첫 인자.
- `recursive` — 두 번째 인자.
- `filter` — 정규식 본문 (slashes 없이).
- `flags` — 정규식 플래그.
- `importer` — 호출한 모듈 경로.

콜백 반환:
- `{ context: string[] }` — 매칭된 파일 경로 배열 (빈 배열 = empty context).
- `null` / `undefined` — 다음 plugin 시도. 모든 plugin 이 null 이면 graph 가 `require_context_no_handler` diagnostic.

```typescript
import { readdirSync } from "node:fs";
import { join } from "node:path";

{
  name: 'require-context',
  setup(build) {
    build.onResolveContext({ filter: /^\.\/app/ }, ({ dir, filter, flags, importer }) => {
      const re = new RegExp(filter ?? '.', flags ?? '');
      const root = join(importer, '..', dir);
      const files = readdirSync(root).filter((f) => re.test(f)).map((f) => join(root, f));
      return { context: files };
    });
  },
}
```

### onAstFunction

고출력 AST 훅. `filter` 매칭된 파일 안 함수 단위로 `AstFunctionInfo` 를 받아, `stripDirective` 로 디렉티브 제거 + `trailingCode` 로 함수 뒤에 코드를 추가할 수 있다.

```typescript
interface AstFunctionInfo {
  name: string | null;
  directives: string[];        // 함수 본문 prologue directive 들
  closureVars: string[];       // 외부 식별자 참조 목록
  params: string[];
  sourcePath: string;
  bodyText: string;
  flags: { async: boolean; generator: boolean };
}

interface AstFunctionResult {
  stripDirective?: string;     // 본문 prologue 에서 제거할 directive
  trailingCode?: string[];     // 함수 정의 뒤 삽입할 statement 들
}
```

Reanimated worklet (`"worklet"` 디렉티브 함수에 hash/closure/initData 주입) 같은 1st-party transform 의 외부 구현 surface — 일반 transform 으로는 어려운 함수-스코프 메타데이터 접근이 필요한 경우에만 쓸 것.

```typescript
{
  name: 'mark-worklets',
  setup(build) {
    build.onAstFunction({ filter: /\.tsx?$/ }, (info) => {
      if (!info.directives.includes('worklet')) return null;
      return {
        stripDirective: 'worklet',
        trailingCode: [`${info.name}.__hash = ${JSON.stringify(info.bodyText.length)};`],
      };
    });
  },
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
import { build } from "@zntc/core";

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
