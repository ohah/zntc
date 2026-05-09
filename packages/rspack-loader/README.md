# @zntc/rspack-loader

Rspack / Webpack 5 의 `swc-loader` / `esbuild-loader` / `babel-loader` 자리를 ZNTC (Zig 기반 트랜스파일러) 로 교체하는 loader. TypeScript / JSX / Flow / decorators 변환을 ZNTC 가 담당.

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

`builtin:swc-loader` 를 쓰던 자리에 그대로 대체 가능.

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

loader API 가 webpack/rspack 공통이라 동일 코드로 양쪽 동작.

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

`@zntc/core` 의 `TranspileOptions` 와 동일 (`filename` 만 loader 가 `this.resourcePath` 로 자동 채움).

#### Target / 모듈

| 옵션           | 타입                                                 | 설명                                           |
| -------------- | ---------------------------------------------------- | ---------------------------------------------- |
| `target`       | `'es5' \| 'es2015' \| ... \| 'es2024' \| 'esnext'`   | ES 다운레벨 타겟                               |
| `browserslist` | `string \| string[]`                                 | browserslist 쿼리 (지정 시 `target` 보다 우선) |
| `platform`     | `'browser' \| 'node' \| 'neutral' \| 'react-native'` | 타겟 플랫폼                                    |
| `format`       | `'esm' \| 'cjs'`                                     | 모듈 포맷                                      |

#### JSX

| 옵션              | 타입                                          | 설명                                            |
| ----------------- | --------------------------------------------- | ----------------------------------------------- |
| `jsx`             | `'classic' \| 'automatic' \| 'automatic-dev'` | JSX 런타임                                      |
| `jsxFactory`      | `string`                                      | classic factory (default `React.createElement`) |
| `jsxFragment`     | `string`                                      | classic Fragment (default `React.Fragment`)     |
| `jsxImportSource` | `string`                                      | automatic import source (default `react`)       |
| `jsxInJs`         | `boolean`                                     | `.js` 에서도 JSX 허용                           |

#### TypeScript / Flow / Decorator

| 옵션                      | 타입      | 설명                                                               |
| ------------------------- | --------- | ------------------------------------------------------------------ |
| `tsconfigPath`            | `string`  | tsconfig.json 경로 (파일 또는 디렉토리). compilerOptions 자동 머지 |
| `tsconfigRaw`             | `string`  | inline tsconfig JSON 문자열 (esbuild 와 동일 의미)                 |
| `verbatimModuleSyntax`    | `boolean` | TS 5.0+: 미사용 import elide 안 함                                 |
| `useDefineForClassFields` | `boolean` | class field → constructor `this.x = v` 변환 (default: `true`)      |
| `flow`                    | `boolean` | Flow 타입 스트리핑                                                 |
| `experimentalDecorators`  | `boolean` | legacy decorator 변환                                              |
| `emitDecoratorMetadata`   | `boolean` | decorator metadata emit                                            |

#### 소스맵

| 옵션                | 타입      | 설명                             |
| ------------------- | --------- | -------------------------------- |
| `sourcemap`         | `boolean` | 소스맵 생성                      |
| `sourcemapDebugIds` | `boolean` | Sentry 호환 Debug ID             |
| `sourcesContent`    | `boolean` | 원본 소스 포함 (default: `true`) |
| `sourceRoot`        | `string`  | 소스맵 sourceRoot 필드           |

#### Minify

| 옵션                | 타입      | 설명                                   |
| ------------------- | --------- | -------------------------------------- |
| `minify`            | `boolean` | whitespace + identifiers + syntax 전체 |
| `minifyWhitespace`  | `boolean` | 공백 축소만                            |
| `minifyIdentifiers` | `boolean` | 식별자 축소만                          |
| `minifySyntax`      | `boolean` | 구문 축소만                            |
| `dropConsole`       | `boolean` | `console.*` 호출 제거                  |
| `dropDebugger`      | `boolean` | `debugger` 문 제거                     |

#### 기타

| 옵션          | 타입                                                          | 설명                                   |
| ------------- | ------------------------------------------------------------- | -------------------------------------- |
| `define`      | `Array<{ key: string; value: string }>`                       | 식별자 치환 (`value` 는 raw JSON)      |
| `quotes`      | `'double' \| 'single' \| 'preserve'`                          | 문자열 따옴표 스타일                   |
| `asciiOnly`   | `boolean`                                                     | non-ASCII → `\uXXXX` 이스케이프        |
| `charsetUtf8` | `boolean`                                                     | non-ASCII 이스케이프 안 함             |
| `stopAfter`   | `'scan' \| 'parse' \| 'semantic' \| 'transform' \| 'codegen'` | 디버그/프로파일 — 해당 phase 이후 skip |

전체 옵션 정의는 [`@zntc/core` TranspileOptions](https://github.com/ohah/zntc/blob/main/packages/shared/index.ts) 참고.

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

## 예시 — Flow 코드

```js
{
  test: /\.js$/,
  loader: '@zntc/rspack-loader',
  options: { transpileOptions: { flow: true, jsx: 'automatic' } },
}
```

## 예시 — tsconfig 명시 + decorator

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

- `@rspack/core >= 1.0.0` (optional, rspack 1.x / 2.x 모두 지원)
- `webpack >= 5.0.0` (optional)

둘 중 하나만 설치돼있어도 됨.

## 라이센스

MIT.
