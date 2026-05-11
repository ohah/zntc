---
title: Rspack / Webpack
description: Rspack 또는 Webpack 프로젝트에서 ZNTC 로 swc-loader / babel-loader 를 교체하는 방법입니다.
---

ZNTC 는 `@zntc/rspack-loader` 로 Rspack / Webpack 의 `swc-loader` / `babel-loader` 자리에 들어갑니다. Rspack / Webpack 의 entry / plugins / output / dev server 는 그대로 두고 `.ts` / `.tsx` / `.jsx` 변환만 ZNTC 가 담당합니다.

## 프로젝트 구조

```text
my-rspack-app/
├── rspack.config.mjs       # 또는 webpack.config.mjs
├── src/
│   ├── index.ts
│   └── ...
└── package.json
```

## 자동 적용 (`zntc-init rspack`)

```bash
# Rspack — package.json 의 @rspack/* 의존성 자동 감지
npx @zntc/init rspack

# Webpack — 명시적으로 강제
npx @zntc/init rspack --bundler=webpack
```

수행 작업:

- `package.json` 의 `@rspack/core` / `@rspack/cli` 또는 `webpack` / `webpack-cli` 의존성을 보고 bundler 를 자동 감지합니다 (없으면 `--bundler` 로 강제).
- `@zntc/core`, `@zntc/rspack-loader` 개발 의존성을 추가합니다.
- `rspack.config.mjs` (또는 `webpack.config.mjs`) 가 없으면 기본 config 를 생성합니다.
- 기존 config 가 있으면 manual patch 안내를 출력합니다. `--force` 로 덮어쓰기 가능.

기본 생성 config (Rspack):

```js
// rspack.config.mjs
export default {
  module: {
    rules: [
      {
        test: /\.(?:tsx?|jsx?)$/,
        exclude: /node_modules/,
        loader: "@zntc/rspack-loader",
        options: {
          transpileOptions: { target: "es2020", jsx: "automatic" },
        },
      },
    ],
  },
};
```

Webpack 도 동일한 rule 형태 — header 주석만 다릅니다.

## 수동 적용

기존 `rspack.config` / `webpack.config` 의 `module.rules` 에 다음 rule 을 추가합니다.

```js
{
  test: /\.(?:tsx?|jsx?)$/,
  exclude: /node_modules/,
  loader: "@zntc/rspack-loader",
  options: {
    transpileOptions: { target: "es2020", jsx: "automatic" },
  },
},
```

기존의 `swc-loader` / `babel-loader` / `ts-loader` rule 은 제거하시면 됩니다 — ZNTC loader 가 그 자리를 차지합니다.

## 명령

기존 Rspack / Webpack CLI 를 그대로 사용합니다.

```bash
# Rspack
bun rspack build
bun rspack serve

# Webpack
bun webpack build
bun webpack serve
```

## 옵션 / 사용 예시

`@zntc/rspack-loader` 의 `transpileOptions`, `define`, `tsconfig`, `flow` 등 자세한 옵션과 예시는 [`@zntc/rspack-loader` reference](/zntc/guides/rspack-loader/) 를 참조하세요.

자주 쓰는 옵션 요약:

- `target` — `es2015` ~ `esnext`, 또는 엔진 타겟 (`chrome80`, `node18` 등).
- `jsx` — `automatic` (React 17+) / `classic` / `automatic-dev`.
- `define` — `process.env.NODE_ENV` 같은 컴파일 타임 치환.
- `tsconfigCache` — 같은 디렉토리 트리에서 tsconfig 재사용 (기본 활성).

## 알려진 한계

- ZNTC loader 는 transpile / parse 시점에만 동작합니다. Rspack / Webpack 의 chunk splitting / asset module / dev server 동작은 호스트 번들러가 결정합니다 — ZNTC 의 번들러 옵션 (`manualChunks`, `tree-shaking` 등) 은 이 모드에서 효과가 없습니다.
- 동일 프로젝트에서 ZNTC native bundler (`zntc --bundle`) 와 Rspack/Webpack 을 혼용하면 출력이 일치하지 않을 수 있습니다. 한 가지 빌드 경로를 선택해 사용하세요.

## 관련 문서

- [`@zntc/rspack-loader` reference](/zntc/guides/rspack-loader/) — loader 옵션 / peerDependency / `define` 환경변수 치환 / Flow 사용 예시.
