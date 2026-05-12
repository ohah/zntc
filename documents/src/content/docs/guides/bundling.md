---
title: 번들링
description: ZNTC의 번들링 기능을 자세히 알아봅니다.
---

## 기본 번들링

```bash
zntc --bundle entry.ts -o bundle.js
```

## 출력 디렉토리

```bash
zntc --bundle entry.ts --outdir dist/
```

## 코드 스플리팅

동적 import와 공유 모듈을 별도 청크로 분리합니다.

```bash
zntc --bundle entry.ts --splitting --outdir dist/
```

## Preserve Modules

라이브러리 빌드 시 원본 디렉토리 구조를 유지합니다 (Rollup/Rolldown 호환).

```bash
zntc --bundle src/index.ts --preserve-modules --outdir dist/
zntc --bundle src/index.ts --preserve-modules --preserve-modules-root=src --outdir dist/
```

## 플랫폼

```bash
zntc --bundle entry.ts --platform=browser   # 기본, IIFE 래핑
zntc --bundle entry.ts --platform=node      # Node 내장 모듈 external
zntc --bundle entry.ts --platform=react-native  # RN 프리셋
```

### browser (기본)

- `--format` 미지정 시 IIFE 자동 설정
- `process.env.NODE_ENV` → `"production"` 자동 define
- Node 내장 모듈 빈 모듈로 대체

### node

- Node 내장 모듈 + 서브패스 자동 external

### react-native

- `.native.*` / `.ios.*` / `.android.*` 확장자 자동 resolve
- `main-fields`: `react-native, browser, module, main`
- Flow 자동 활성화

## External

```bash
zntc --bundle entry.ts --external react --external react-dom
```

## Alias

```bash
zntc --bundle entry.ts --alias:react=preact/compat
```

config 에서는 두 가지 형태를 지원합니다 (esbuild / Vite 호환).

```ts
// Object 형태 — exact + prefix 매칭 (esbuild alias)
defineConfig({
  alias: { react: "preact/compat", "@/": "./src/" },
});

// Array 형태 — RegExp 지원 (Vite resolve.alias). build() 만 지원, buildSync 미지원.
defineConfig({
  alias: [
    { find: /^@\/(.*)$/, replacement: "./src/$1" },
    { find: "lodash", replacement: "lodash-es" },
  ],
});
```

`alias` 는 일반 해석 **전에 무조건** 치환됩니다. 실패 시에만 적용하려면 `fallback` 을 사용하세요. 자세한 babel-plugin-module-resolver 매핑은 Babel 마이그레이션 가이드 참고.

## Fallback

webpack `resolve.fallback` / Metro `resolver.extraNodeModules` 호환. 일반 해석이 **실패했을 때만** 적용. 브라우저 타겟에서 Node 내장을 polyfill 로 swap 할 때 주로 사용합니다.

```ts
defineConfig({
  fallback: {
    fs: false,                       // 빈 모듈로 대체
    crypto: "crypto-browserify",
    stream: "stream-browserify",
  },
});
```

값이 문자열이면 해당 specifier 로 재해석, `false` 면 빈 모듈로 대체.

## Block List

Metro `resolver.blockList` / webpack `IgnorePlugin` 호환. 매칭되는 절대 경로는 resolver 가 해석 실패시켜 번들 그래프에 포함되지 않습니다.

```ts
defineConfig({
  blockList: [
    /\/__mocks__\//,
    /\.test\.tsx?$/,
    "/private-internal/.*",
  ],
});
```

- `RegExp`: `.source` 를 추출해 패턴으로 사용
- `string`: regex 문자열 그대로 사용
- 지원 구문: 리터럴, `.*`, `^`, `$`, `\x` 이스케이프. `|`, `[]`, `()`, `+?`, `\w\d` 는 미지원
- `platform: "react-native"` 시 Metro 기본 패턴(`__tests__`, iOS/Android 빌드 폴더 등)이 자동 prepend 되며 사용자 패턴은 그 뒤에 append

## Loader

```bash
zntc --bundle entry.ts --loader:.png=file --loader:.svg=dataurl
```

지원 로더: `js`, `jsx`, `ts`, `tsx`, `json`, `css`, `text`, `file`, `dataurl`, `base64`, `binary`, `copy`, `empty`

## Web Worker

`new Worker(new URL("./worker.ts", import.meta.url))` 패턴을 자동 감지해 워커 엔트리를 **별도 IIFE 번들** 로 분리합니다. 사용자가 빌드 설정이나 entry 옵션을 추가할 필요가 없습니다.

```ts
// src/main.ts
const worker = new Worker(new URL("./worker.ts", import.meta.url));
worker.postMessage({ task: "compute", n: 1000 });
worker.onmessage = (e) => console.log(e.data);

// src/worker.ts
self.onmessage = (e) => {
  const { task, n } = e.data;
  if (task === "compute") {
    let sum = 0;
    for (let i = 0; i < n; i++) sum += i;
    self.postMessage({ sum });
  }
};
```

`SharedWorker` 도 동일한 패턴 (`new SharedWorker(new URL(...))`) 으로 자동 감지됩니다.

### 출력

워커 엔트리는 메인 번들의 import dependency 가 아닌 **별도 chunk** 로 생성됩니다. 파일명은 `<원본파일명>-<crc32 hex>.js` 고정 형식이며 (`--chunk-names` 패턴 미적용), 메인 번들의 `new Worker(new URL(...))` 호출부는 빌드된 워커 파일 URL 로 자동 치환됩니다. 워커 chunk 의 모듈 포맷은 항상 IIFE 입니다 (Node CJS 타겟 빌드에서는 CJS).

### 한계

- `new Worker(new URL(...))` / `new SharedWorker(new URL(...))` 의 **정확한 정적 패턴** 만 자동 감지합니다. 다음 형태는 미감지:
  - 변수에 담긴 URL: `const url = new URL(...); new Worker(url);`
  - 동적 경로: `new Worker(new URL(\`./${name}.ts\`, import.meta.url))`
  - 별도 별칭 변수: `const W = Worker; new W(new URL(...))`
- 두 번째 인수 옵션 객체 (`{ type: "module" }` 등) 는 무시되고 항상 IIFE 로 번들됩니다. ESM module worker 가 필요하면 별도 entry 로 빌드하고 URL 을 직접 지정하세요.
- `ServiceWorker` 는 자동 감지하지 않습니다. 별도 entry 로 빌드한 뒤 사용자가 직접 URL 을 지정하세요.

## 파일명 패턴

```bash
zntc --bundle entry.ts --outdir dist/ \
  --entry-names="[name]-[hash]" \
  --chunk-names="chunks/[name]-[hash]" \
  --asset-names="assets/[name]-[hash]"
```

## Banner / Footer / Intro / Outro

`banner` / `footer` 는 format wrapper **밖**의 최상단/최하단에 텍스트를 삽입합니다 (라이선스 헤더, shebang 등). `intro` / `outro` 는 wrapper **안쪽**, 번들 코드 앞/뒤에 삽입합니다 (Rollup `output.intro`/`output.outro` 호환). IIFE/UMD 같은 wrapper format 에서 차이가 명확합니다.

```bash
zntc --bundle entry.ts -o bundle.js \
  --banner:js="/* MIT License */" \
  --footer:js="/* End of bundle */" \
  --intro="'use strict';" \
  --outro="globalThis.__BUILD_OK__ = true;"
```

```ts
defineConfig({
  banner: "/* MIT License */",
  footer: "/* End of bundle */",
  intro: "'use strict';",
  outro: "globalThis.__BUILD_OK__ = true;",
});
```

## Metafile

```bash
zntc --bundle entry.ts -o bundle.js --metafile=meta.json
zntc --bundle entry.ts -o bundle.js --analyze
```

`meta.json`은 [Metafile 분석](/zntc/analyze/) 페이지에 업로드해 output 크기, input 크기, import graph를 확인할 수 있습니다.

### 어떤 메트릭을 보고 무엇을 결정하나

| 메트릭 | 무엇을 보는가 | 행동 |
|---|---|---|
| **bytesInOutput per chunk** | 청크 사이즈 분포 | 한 청크가 비대해지면 `--splitting` 또는 `manualChunks` |
| **inputs[].imports** | 어떤 모듈이 어디서 import 됐는지 | 의도치 않은 deep import (예: `lodash` 전체) → named import 로 변경 |
| **inputs[].bytes vs bytesInOutput** | 입력 vs 출력 크기 비율 | 비율이 1 에 가까우면 트리쉐이킹이 거의 없음 — `sideEffects` / `@__PURE__` 검토 |
| **outputs[].imports** | 청크 간 의존 관계 | preload/prefetch 우선순위 결정 |
| **entry pointer chain** | entry → 첫 사용 모듈까지 거리 | 초기 로딩 critical path 단축 후보 |

## `allowOverwrite`

기본적으로 입력 파일을 덮어쓰는 출력 경로는 안전을 위해 거부됩니다. `in-place` 트랜스파일이 의도라면 명시 허용하세요.

```bash
zntc --bundle src/index.ts -o src/index.ts --allow-overwrite
```

```ts
defineConfig({
  entryPoints: ["src/index.ts"],
  outfile: "src/index.ts",
  allowOverwrite: true,
});
```

소스맵을 켠 채 같은 경로에 덮어쓰면 두 번째 빌드의 sourcemap reference 가 첫 빌드의 출력을 가리키게 되므로 주의 — 가능하면 별도 출력 디렉토리를 권장합니다.

## Minify

```bash
zntc --bundle entry.ts -o bundle.js --minify  # 세 가지 모두

# 세분화 (esbuild 호환) — 개별 토글
zntc --bundle entry.ts -o bundle.js --minify-whitespace
zntc --bundle entry.ts -o bundle.js --minify-syntax
zntc --bundle entry.ts -o bundle.js --minify-identifiers
```

## 코드 제거

```bash
zntc --bundle entry.ts --drop=console --drop=debugger
zntc --bundle entry.ts --drop-labels=DEV,TEST
```

`--drop-labels`는 지정한 labeled statement 전체를 제거합니다. 예를 들어
`DEV: { console.log("dev only"); }`는 `--drop-labels=DEV`에서 번들에 남지 않습니다.

## ES 타겟

```bash
# ES 버전 (es2015~esnext)
zntc --bundle entry.ts -o bundle.js --target=es2020

# 엔진 타겟 — feature-level 다운레벨링
zntc --bundle entry.ts -o bundle.js --target=chrome80,safari14
zntc --bundle entry.ts -o bundle.js --target=node18
zntc --bundle entry.ts -o bundle.js --target=hermes0.70
```

### `browserslist`

`target` 대신 Browserslist 쿼리 문자열(또는 string 배열)로 다운레벨 매트릭스를 지정할 수 있습니다. 지정 시 `target` 보다 **우선**합니다. `platform: "react-native"` 에서는 Hermes 매트릭스가 강제되므로 `browserslist` 를 전달할 수 없습니다 (런타임에서도 무시).

```ts
defineConfig({
  browserslist: "> 0.5%, last 2 versions, not dead",
  // 또는
  // browserslist: ["chrome >= 80", "safari >= 14"],
});
```

CSS 후처리(Lightning CSS) 와도 매트릭스를 공유합니다.

## Runtime Polyfills (core-js)

`--target` 은 문법을 낮추고, `--runtime-polyfills` 는 타겟 런타임에 없는 API (`Promise`, `Map`, `String.prototype.replaceAll`, `Array.prototype.at`, `structuredClone` 등) 를 `core-js` 로 보강합니다. 번들 그래프에서 감지된 API 중 타겟이 지원하지 않는 `core-js/modules/*.js` 가 엔트리보다 먼저 실행되도록 prelude 로 들어갑니다.

```bash
bun add core-js core-js-compat
zntc --bundle entry.ts -o bundle.js --target=es5 --runtime-polyfills=auto --runtime-target="ios_saf 12"
```

모드(`auto`/`usage`/`entry`/`off`), `runtimePolyfills` 설정 객체, `@babel/preset-env useBuiltIns` 대응, 실행 순서 등 전체 내용은 → **[런타임 폴리필 (core-js)](/zntc/guides/runtime-polyfills/)**.
## 출력 포맷

```bash
zntc --bundle entry.ts --format=esm    # ESM (기본)
zntc --bundle entry.ts --format=cjs    # CommonJS
zntc --bundle entry.ts --format=iife --global-name=MyLib  # IIFE
zntc --bundle entry.ts --format=umd --global-name=MyLib   # UMD
zntc --bundle entry.ts --format=amd                       # AMD
```

### IIFE/UMD external → 전역 매핑 (`globals`)

Rollup `output.globals` 호환. IIFE/UMD 출력에서 `external` 로 빠진 specifier 를 런타임 전역 변수로 치환합니다.

```bash
zntc --bundle entry.ts -o bundle.js --format=umd --global-name=MyLib \
  --external react --external react-dom \
  --global:react=React --global:react-dom=ReactDOM
```

```ts
defineConfig({
  format: "umd",
  globalName: "MyLib",
  external: ["react", "react-dom"],
  globals: { react: "React", "react-dom": "ReactDOM" },
});
```

## Watch 모드

```bash
zntc --bundle entry.ts -o bundle.js --watch
zntc --bundle entry.ts -o bundle.js --watch-json  # NDJSON 이벤트 출력
```

## 디버깅 — 알아두면 좋은 한계

번들 결과가 의도와 다르게 나올 때 가장 자주 부딪히는 케이스들입니다.

### CJS 래퍼 모듈은 트리쉐이킹되지 않음

```ts
// my-lib (CJS)
const featureA = require('./feature-a');
const featureB = require('./feature-b');
module.exports = { featureA, featureB };
```

```ts
// entry.ts
import { featureA } from 'my-lib';   // featureB 도 번들에 포함됨
```

`require_X()` 호출은 사이드이펙트로 간주되므로, 미사용 named import 라도 CJS wrap 모듈 전체가 보존됩니다. 가능하면 라이브러리를 ESM 으로 마이그레이션하거나, 직접 deep import 하세요.

```ts
import featureA from 'my-lib/feature-a';  // 필요한 것만
```

JSON 모듈은 ESM AST 로 변환되어 named export 단위 트리쉐이킹이 동작합니다.

### 글로벌과 같은 이름의 변수는 자동 rename

```ts
const document = createVirtualDocument();
document.title = "Hi";
```

번들 결과에서 `document` → `document$1` 처럼 rename 됩니다 — TDZ 또는 shadowing 사고를 피하기 위한 자동 보호. sourcemap 으로 원본 이름은 그대로 추적됩니다. 어떤 이름이 보호 대상인지는 타겟 환경(`browser` / `node` / `react-native`) 에 따라 다릅니다.

### Namespace re-export 는 트리쉐이킹 정밀도가 낮아짐

```ts
// barrel.ts
import * as utils from './utils';
export { utils };
```

이 패턴은 `utils` 의 모든 export 가 사용된 것으로 간주됩니다. 가능하면 명시적 re-export 로 바꾸세요:

```ts
export { foo, bar } from './utils';
```

### `--define` 값은 JavaScript 리터럴이어야 함

```bash
# ✗ 틀림 — admin 이 식별자로 처리되어 의도와 다른 코드가 생성됨
zntc --bundle entry.ts --define:USERNAME=admin

# ✓ 맞음 — 큰따옴표를 포함해 문자열 리터럴
zntc --bundle entry.ts --define:USERNAME='"admin"'

# ✓ 숫자/불리언/null 은 그대로 리터럴
zntc --bundle entry.ts --define:DEBUG=false --define:MAX=100
```

쉘 quoting 함정 — bash/zsh 에서 큰따옴표를 보존하려면 작은따옴표로 감싸야 합니다.
