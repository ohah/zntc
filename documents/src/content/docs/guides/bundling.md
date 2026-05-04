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

## Banner / Footer

```bash
zts --bundle entry.ts -o bundle.js \
  --banner:js="/* MIT License */" \
  --footer:js="/* End of bundle */"
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

## Watch 모드

```bash
zts --bundle entry.ts -o bundle.js --watch
zts --bundle entry.ts -o bundle.js --watch-json  # NDJSON 이벤트 출력
```
