# @zntc/rspack-loader

Rspack / Webpack 5 의 swc-loader / esbuild-loader / babel-loader 자리를 ZNTC (Zig 기반 트랜스파일러) 로 교체하는 loader. TypeScript / JSX / Flow / decorators 변환을 ZNTC 가 담당.

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
{
  transpileOptions?: {
    target?: 'es5' | 'es2015' | ... | 'es2024';
    jsx?: 'preserve' | 'classic' | 'automatic';
    // ... ZNTC TranspileOptions 전체 (filename 제외 — loader 가 자동 채움)
  };
  tsconfigCache?: boolean; // default: true
}
```

- `transpileOptions` — `@zntc/core` 의 `TranspileOptions` 와 동일 (단 `filename` 은 loader 가 `this.resourcePath` 로 자동 세팅).
- `tsconfigCache` — tsconfig autodiscover walk 결과를 worker 별로 캐시. dev/watch 세션에서 동일 워크스페이스 안 파일은 한 번만 walk → file 당 5–10 fs syscall 절약. `tsconfigPath`/`tsconfigRaw` 명시 시 자동 무시.

## peer

- `@rspack/core >= 0.7.0` (optional)
- `webpack >= 5.0.0` (optional)

둘 중 하나만 설치돼있어도 됨.

## 라이센스

MIT.
