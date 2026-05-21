import { createRequire } from "node:module";
import { rspack } from "@rspack/core";

// @zntc/rspack-loader 를 rspack 의 .tsx/.ts loader 로 사용한다. zntc 가 TS strip +
// JSX automatic runtime 변환을 담당하고, rspack 이 모듈 그래프·번들·HMR·dev server 를
// 맡는다 (swc/babel loader 자리에 zntc 를 끼우는 구성).
const require = createRequire(import.meta.url);
const zntcLoader = require.resolve("@zntc/rspack-loader");

export default {
  mode: "development",
  // zntc-loader 의 소스맵(원본 .tsx → 변환 JS)을 rspack 이 이어붙이게 한다.
  // 미지정 시 DevTools 가 변환 결과(_jsx(...))를 원본으로 보여준다.
  devtool: "source-map",
  entry: "./src/main.tsx",
  resolve: {
    extensions: [".tsx", ".ts", ".jsx", ".js"],
  },
  module: {
    rules: [
      {
        test: /\.[jt]sx?$/,
        loader: zntcLoader,
        options: {
          transpileOptions: {
            target: "es2022",
            jsx: "automatic",
            // loader 가 result.map 을 rspack 에 넘기려면 zntc 가 map 을 생성해야 한다.
            sourcemap: true,
          },
        },
      },
    ],
  },
  plugins: [new rspack.HtmlRspackPlugin({ template: "./index.html" })],
  devServer: {
    host: "0.0.0.0",
    port: 12308,
  },
};
