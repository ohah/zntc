---
title: 번들링
description: ZTS의 번들링 기능을 자세히 알아봅니다.
---

## 기본 번들링

```bash
zts --bundle entry.ts -o bundle.js
```

## 출력 디렉토리

```bash
zts --bundle entry.ts --outdir dist/
```

## 코드 스플리팅

동적 import와 공유 모듈을 별도 청크로 분리합니다.

```bash
zts --bundle entry.ts --splitting --outdir dist/
```

## Preserve Modules

라이브러리 빌드 시 원본 디렉토리 구조를 유지합니다 (Rollup/Rolldown 호환).

```bash
zts --bundle src/index.ts --preserve-modules --outdir dist/
zts --bundle src/index.ts --preserve-modules --preserve-modules-root=src --outdir dist/
```

## 플랫폼

```bash
zts --bundle entry.ts --platform=browser   # 기본, IIFE 래핑
zts --bundle entry.ts --platform=node      # Node 내장 모듈 external
zts --bundle entry.ts --platform=react-native  # RN 프리셋
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
zts --bundle entry.ts --external react --external react-dom
```

## Alias

```bash
zts --bundle entry.ts --alias:react=preact/compat
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
zts --bundle entry.ts --loader:.png=file --loader:.svg=dataurl
```

지원 로더: `js`, `ts`, `json`, `text`, `css`, `file`, `dataurl`, `binary`, `copy`, `empty`

## 파일명 패턴

```bash
zts --bundle entry.ts --outdir dist/ \
  --entry-names="[name]-[hash]" \
  --chunk-names="chunks/[name]-[hash]" \
  --asset-names="assets/[name]-[hash]"
```

## Banner / Footer / Intro / Outro

`banner` / `footer` 는 format wrapper **밖**의 최상단/최하단에 텍스트를 삽입합니다 (라이선스 헤더, shebang 등). `intro` / `outro` 는 wrapper **안쪽**, 번들 코드 앞/뒤에 삽입합니다 (Rollup `output.intro`/`output.outro` 호환). IIFE/UMD 같은 wrapper format 에서 차이가 명확합니다.

```bash
zts --bundle entry.ts -o bundle.js \
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
zts --bundle entry.ts -o bundle.js --metafile=meta.json
zts --bundle entry.ts -o bundle.js --analyze
```

## Minify

```bash
zts --bundle entry.ts -o bundle.js --minify  # 세 가지 모두

# 세분화 (esbuild 호환) — 개별 토글
zts --bundle entry.ts -o bundle.js --minify-whitespace
zts --bundle entry.ts -o bundle.js --minify-syntax
zts --bundle entry.ts -o bundle.js --minify-identifiers
```

## 코드 제거

```bash
zts --bundle entry.ts --drop=console --drop=debugger
zts --bundle entry.ts --drop-labels=DEV,TEST
```

`--drop-labels`는 지정한 labeled statement 전체를 제거한다. 예를 들어
`DEV: { console.log("dev only"); }`는 `--drop-labels=DEV`에서 번들에 남지 않는다.

## ES 타겟

```bash
# ES 버전 (es2015~esnext)
zts --bundle entry.ts -o bundle.js --target=es2020

# 엔진 타겟 — feature-level 다운레벨링
zts --bundle entry.ts -o bundle.js --target=chrome80,safari14
zts --bundle entry.ts -o bundle.js --target=node18
zts --bundle entry.ts -o bundle.js --target=hermes0.70
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

`--target`은 문법을 낮추고, `--runtime-polyfills`는 타겟 런타임에 없는 API를 `core-js`로 보강합니다. `String.prototype.replaceAll`, `Array.prototype.at`, `Object.hasOwn`, `Promise`, `Map`, `Set`, `structuredClone` 같은 API가 번들 그래프에서 감지되면 필요한 `core-js/modules/*.js` prelude가 엔트리보다 먼저 실행됩니다.

```bash
bun add core-js core-js-compat

zts --bundle entry.ts -o bundle.js \
  --target=es5 \
  --runtime-polyfills=auto \
  --runtime-target="ios_saf 12" \
  --core-js=3.49
```

모드는 네 가지입니다.

| 모드 | 동작 |
|---|---|
| `off` | 기본값. `core-js-compat` 로드와 graph collector를 실행하지 않음 |
| `auto` | 실제 번들 그래프에서 감지된 API 중 타겟이 지원하지 않는 `core-js` 모듈만 주입 |
| `usage` | `auto`와 동일한 graph usage 모드 alias |
| `entry` | 사용 여부와 무관하게 타겟에 필요한 `core-js` ES/Web 모듈 전체를 엔트리 prelude로 주입 |

`auto`/`usage`는 JS wrapper의 Babel pre-scan이 아니라 resolve, package exports, alias, plugin load/transform 이후 만들어진 native graph 기준으로 동작합니다. dependency 내부 코드도 감지 대상이며, 코드 스플리팅을 켠 경우에도 runtime prelude가 user entry보다 먼저 실행되도록 graph root로 포함됩니다.

Config/API에서는 object 형태로 `include`/`exclude`를 세밀하게 지정할 수 있습니다.

```ts
import { build } from "@zts/core";

await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  outfile: "dist/index.js",
  target: "es5",
  runtimePolyfills: {
    mode: "auto",
    targets: ["safari 12", "ios_saf 12"],
    coreJs: "3.49",
    include: ["es.array.at"],
    exclude: ["web.url"],
  },
});
```

`include`는 강제 주입, `exclude`는 target/usage 계산 이후 최종 제거입니다. 값은 `es.string.replace-all` 또는 `core-js/modules/es.string.replace-all.js` 형식을 사용할 수 있습니다.

Runtime target은 Rspack/SWC `env.targets`와 같은 Browserslist query입니다. `ios_saf 12`, `safari 12`, `node 18`처럼 명시적으로 쓰고, `ios12`, `node18` 같은 compact shorthand나 `"iPhone 8"` 같은 physical device name은 사용하지 않습니다. React Native 기본 Hermes 타겟은 `--platform=react-native`로 선택합니다.

감지는 정적 AST 기반이므로 전역을 가리는 local binding/import는 제외되고, `obj["replaceAll"]()`처럼 동적 computed access는 추론하지 않습니다. 이런 코드는 `include` 또는 `entry` 모드로 보완합니다.

실행 순서는 기존 수동 polyfill과 entry hook을 보존합니다.

```text
manual polyfills / inject roots -> runtime core-js prelude -> runBeforeMain -> user entry
```

`runBeforeMain` 은 엔트리 모듈 직전에 실행할 모듈 경로 배열입니다. 번들 그래프에 포함되어 prelude 로 emit되며, manual polyfills / runtime polyfill 다음, user entry 직전에 실행됩니다. React Native 폴리플로우(`InitializeCore` 등) 처럼 entry 직전 환경 셋업 코드를 끼울 때 사용합니다. 단순 폴리필 주입은 `polyfills` (번들 시작 시 즉시 실행) 를 쓰세요.

```ts
defineConfig({
  runBeforeMain: ["./src/setup-env.ts"],
});
```

디버깅이 필요하면 runtime polyfill debug category와 graph profile을 함께 켭니다.

```bash
ZTS_DEBUG=runtime_polyfills zts --bundle entry.ts \
  --runtime-polyfills=auto \
  --runtime-target="safari 12" \
  --profile=graph \
  --profile-level=detailed \
  --profile-format=json
```

## 출력 포맷

```bash
zts --bundle entry.ts --format=esm    # ESM (기본)
zts --bundle entry.ts --format=cjs    # CommonJS
zts --bundle entry.ts --format=iife --global-name=MyLib  # IIFE
zts --bundle entry.ts --format=umd --global-name=MyLib   # UMD
zts --bundle entry.ts --format=amd                       # AMD
```

### IIFE/UMD external → 전역 매핑 (`globals`)

Rollup `output.globals` 호환. IIFE/UMD 출력에서 `external` 로 빠진 specifier 를 런타임 전역 변수로 치환합니다.

```bash
zts --bundle entry.ts -o bundle.js --format=umd --global-name=MyLib \
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
zts --bundle entry.ts -o bundle.js --watch
zts --bundle entry.ts -o bundle.js --watch-json  # NDJSON 이벤트 출력
```
