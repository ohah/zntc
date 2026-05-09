---
title: Rspack / Webpack 통합
description: '@zntc/rspack-loader — Rspack 과 Webpack 5 의 swc-loader / esbuild-loader / babel-loader 자리를 ZNTC 로 교체.'
---

## 개요

`@zntc/rspack-loader` 는 Rspack 과 Webpack 5 의 loader API 로 동작하는 변환기다. `swc-loader`, `esbuild-loader`, `babel-loader` 자리에 그대로 끼워 ZNTC (Zig 기반 트랜스파일러) 로 TypeScript / JSX / Flow / decorator 변환을 처리한다.

`builtin:swc-loader` 자리에 그대로 대체할 수 있으며 (loader API 가 webpack/rspack 공통이라) 동일 코드로 양쪽 번들러에서 동작한다.

## 설치

```bash
bun add -D @zntc/rspack-loader @zntc/core
# 또는
npm i -D @zntc/rspack-loader @zntc/core
```

`@zntc/core` 가 dependency 로 함께 따라옴 (NAPI binary 포함).

## 사용 — Rspack

```js
// rspack.config.mjs
export default {
  module: {
    rules: [
      {
        test: /\.(?:tsx?|jsx?)$/,
        exclude: /node_modules/,
        loader: '@zntc/rspack-loader',
        options: {
          transpileOptions: { target: 'es2020', jsx: 'automatic' },
        },
      },
    ],
  },
};
```

## 사용 — Webpack 5

```js
// webpack.config.mjs
export default {
  module: {
    rules: [
      {
        test: /\.(?:tsx?|jsx?)$/,
        exclude: /node_modules/,
        use: {
          loader: '@zntc/rspack-loader',
          options: {
            transpileOptions: { target: 'es2020', jsx: 'automatic' },
          },
        },
      },
    ],
  },
};
```

## 옵션

```ts
interface ZntcLoaderOptions {
  transpileOptions?: Omit<TranspileOptions, 'filename'>;
  tsconfigCache?: boolean;
}
```

### `tsconfigCache` (default: `true`)

tsconfig autodiscover walk 결과를 worker 별로 캐시. dev/watch 세션에서 같은 워크스페이스 안 파일은 한 번만 walk → file 당 5–10 fs syscall 절약. `transpileOptions.tsconfigPath` / `tsconfigRaw` 명시 시 자동 무시.

### `transpileOptions`

`@zntc/core` 의 `TranspileOptions` 와 동일 (`filename` 만 loader 가 `this.resourcePath` 로 자동 채움). 전체 옵션은 [Transpile 옵션 레퍼런스](/zntc/reference/options/) 또는 [`@zntc/core`](https://github.com/ohah/zntc/blob/main/packages/shared/index.ts) 참고.

자주 쓰는 옵션:

| 옵션                                               | 타입                                                 | 설명                                           |
| -------------------------------------------------- | ---------------------------------------------------- | ---------------------------------------------- |
| `target`                                           | `'es5' \| 'es2015' \| ... \| 'esnext'`               | ES 다운레벨 타겟                               |
| `browserslist`                                     | `string \| string[]`                                 | browserslist 쿼리 (지정 시 `target` 보다 우선) |
| `platform`                                         | `'browser' \| 'node' \| 'neutral' \| 'react-native'` | 타겟 플랫폼                                    |
| `format`                                           | `'esm' \| 'cjs'`                                     | 모듈 포맷                                      |
| `jsx`                                              | `'classic' \| 'automatic' \| 'automatic-dev'`        | JSX 런타임                                     |
| `jsxImportSource`                                  | `string`                                             | automatic import source (default `react`)      |
| `tsconfigPath`                                     | `string`                                             | tsconfig.json 경로                             |
| `tsconfigRaw`                                      | `string`                                             | inline tsconfig JSON                           |
| `flow`                                             | `boolean`                                            | Flow 타입 스트리핑                             |
| `experimentalDecorators` / `emitDecoratorMetadata` | `boolean`                                            | legacy decorator                               |
| `define`                                           | `Array<{ key, value }>`                              | 식별자 치환 (`value` 는 raw JSON)              |
| `sourcemap`                                        | `boolean`                                            | 소스맵 생성                                    |
| `minify` / `dropConsole` / `dropDebugger`          | `boolean`                                            | 산출물 축소                                    |

## 예시 — `define` 으로 환경변수 치환

```js
{
  loader: '@zntc/rspack-loader',
  options: {
    transpileOptions: {
      define: [
        { key: 'process.env.NODE_ENV', value: '"production"' },
        { key: '__DEV__', value: 'false' },
      ],
    },
  },
}
```

## 예시 — Flow

```js
{
  test: /\.js$/,
  loader: '@zntc/rspack-loader',
  options: { transpileOptions: { flow: true, jsx: 'automatic' } },
}
```

## 예시 — tsconfig + decorator

```js
{
  loader: '@zntc/rspack-loader',
  options: {
    transpileOptions: {
      tsconfigPath: './tsconfig.json',
      experimentalDecorators: true,
      emitDecoratorMetadata: true,
    },
  },
}
```

## peer

- `@rspack/core >= 1.0.0` (optional, rspack 1.x / 2.x 지원)
- `webpack >= 5.0.0` (optional)

둘 중 하나만 설치돼있어도 동작.

## 빌드인 loader 와의 관계

Rspack 의 `builtin:swc-loader` 는 Rust 로 컴파일돼 rspack core 안에 들어 있어 외부 패키지가 같은 prefix 로 등록할 수 없다. `@zntc/rspack-loader` 는 esbuild-loader 와 동일한 일반 JS loader 모델로 NAPI 를 통해 ZNTC native binary 를 호출한다.

## 관련 문서

- [Vite 어댑터](/zntc/guides/dev-server/) — `vite-plugin-zntc`
- [Transpile 옵션](/zntc/reference/options/) — 전체 `TranspileOptions` 레퍼런스
- [도구 비교](/zntc/guides/comparison/)
